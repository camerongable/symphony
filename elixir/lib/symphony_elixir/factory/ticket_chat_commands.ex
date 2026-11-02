defmodule SymphonyElixir.Factory.TicketChatCommands do
  @moduledoc "Staged interpretations acquire authority only from completed, independently read native inputs."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{Contract, DesktopRequest, RunLedger, Store, TicketChat, TicketContext, TicketReworkRecovery, WorkerEvidence}
  alias SymphonyElixir.Factory.TicketContractAmendment

  @binding ~w(generation spec_revision contract_sha256 candidate_sha)
  @fields @binding ++ ~w(proposal_id body operations)

  @doc "Reads durable product controls; unavailable chat history is neither a hold nor proof that a staged command was accepted."
  @spec control_state(Store.connection(), String.t()) :: map()
  def control_state(store, run_id) do
    records =
      Store.query!(
        store,
        """
        SELECT 'COMMAND' AS kind, command_key AS key, status FROM ticket_chat_commands WHERE run_id=? AND status IN ('PENDING','ACCEPTED')
        UNION ALL SELECT 'QUESTION', question_key, status FROM ticket_chat_questions WHERE run_id=? AND status='OPEN'
        UNION ALL SELECT 'AMENDMENT', command_key, phase FROM ticket_contract_amendments WHERE run_id=? AND active_owner=1
        ORDER BY kind, key
        """,
        [run_id, run_id, run_id]
      ).rows
      |> Enum.map(fn [kind, key, status] -> %{kind: kind, key: key, status: status} end)

    %{held: records != [], records: records}
  end

  @spec progress_allowed(Store.connection(), String.t()) :: :ok | {:error, atom()}
  def progress_allowed(store, run_id) do
    if control_state(store, run_id).held, do: {:error, :ticket_control_pending}, else: :ok
  end

  @doc false
  @spec rework_body?(term()) :: boolean()
  def rework_body?(body) when is_binary(body),
    do: normalize(body) in ["please rework the current candidate", "rework the current candidate"]

  def rework_body?(_body), do: false

  @doc false
  @spec rework_payload?(term()) :: boolean()
  def rework_payload?(operations) when is_list(operations) do
    operations == [%{"operation" => "request_rework"}] or
      (length(operations) in 2..4 and List.last(operations) == %{"operation" => "request_rework"} and
         Enum.all?(Enum.drop(operations, -1), &answer_operation?/1) and
         length(Enum.map(Enum.drop(operations, -1), & &1["question_key"])) ==
           length(Enum.uniq(Enum.map(Enum.drop(operations, -1), & &1["question_key"]))))
  end

  def rework_payload?(_operations), do: false

  @spec open_question(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def open_question(store, run_id, attrs) do
    atomic(store, &open_question_transaction(&1, run_id, attrs))
  end

  defp open_question_transaction(store, run_id, attrs) do
    with {:ok, chat, run} <- bound(store, run_id), :ok <- question_valid(attrs) do
      key = attrs["question_key"]
      existing = question(store, key)
      values = [key, chat["chat_key"], run_id, encode(binding(chat, run)), attrs["body"], encode(attrs["answers"])]

      cond do
        existing == nil ->
          Store.query!(
            store,
            "INSERT INTO ticket_chat_questions(question_key, chat_key, run_id, binding_json, body, answers_json, opened_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, 'OPEN')",
            values ++ [System.system_time(:millisecond) / 1000]
          )

          {:ok, question(store, key)}

        Enum.map(~w(question_key chat_key run_id binding_json body answers_json), &existing[&1]) == values ->
          {:ok, existing}

        true ->
          {:error, :question_identity_conflict}
      end
    end
  end

  @spec stage(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def stage(store, run_id, attrs) do
    atomic(store, &stage_transaction(&1, run_id, attrs))
  end

  defp stage_transaction(store, run_id, attrs) do
    with {:ok, chat, run} <- bound(store, run_id),
         :ok <- validate_stage(attrs),
         true <- Map.take(attrs, @binding) == binding(chat, run) or {:error, :stale_command_binding},
         {:ok, operations} <- bind_questions(store, chat, run, attrs["operations"]) do
      key = "TCMD-" <> digest(encode([chat["chat_key"], run_id, binding(chat, run), attrs["proposal_id"]]))
      payload = encode(operations)
      expected = [chat["chat_key"], run_id, encode(binding(chat, run)), digest(attrs["body"]), payload, digest(payload), attrs["proposal_id"]]

      reuse_or_stage(store, key, expected)
    end
  end

  defp bind_questions(store, chat, run, operations) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, bound} ->
      case bind_question(store, chat, run, operation) do
        {:ok, op} -> {:cont, {:ok, bound ++ [op]}}
        error -> {:halt, error}
      end
    end)
  end

  defp bind_question(store, %{"chat_key" => key} = chat, %{"run_id" => id} = run, %{"operation" => "answer_question"} = operation) do
    case question(store, operation["question_key"]) do
      %{"chat_key" => ^key, "run_id" => ^id} = question ->
        if question["binding_json"] == encode(binding(chat, run)), do: {:ok, Map.put(operation, "question_digest", question_digest(question))}, else: {:error, :stale_question}

      _ ->
        {:error, :question_not_in_ticket}
    end
  end

  defp bind_question(_store, _chat, _run, operation), do: {:ok, operation}
  defp question_digest(question), do: digest(encode(Map.take(question, ~w(body answers_json opened_at binding_json))))

  defp reuse_or_stage(store, key, expected) do
    case get(store, key) do
      {:ok, old} ->
        fields = ~w(chat_key run_id binding_json body_sha256 payload_json payload_sha256 proposal_id)
        if Enum.map(fields, &old[&1]) == expected, do: {:ok, old}, else: {:error, :proposal_identity_conflict}

      {:error, :unknown_ticket_command} ->
        insert_stage(store, key, expected)
    end
  end

  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(store, key) do
    case Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [key]) do
      nil -> {:error, :unknown_ticket_command}
      command -> {:ok, command}
    end
  end

  @doc "Validates one accepted direct-origin contract proposal without applying it."
  @spec validate_contract_amendment(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_contract_amendment(store, command_key) do
    with {:ok, command} <- get(store, command_key),
         true <- command["status"] == "ACCEPTED" or {:error, :ticket_command_not_accepted},
         {:ok, chat, run} <- bound(store, command["run_id"]),
         association when is_map(association) <- Store.one!(store, "SELECT * FROM ticket_chat_runs WHERE run_id = ?", [run["run_id"]]),
         true <-
           (association["chat_key"] == chat["chat_key"] and command["chat_key"] == chat["chat_key"]) or
             {:error, :ticket_chat_run_association_mismatch},
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         :ok <- current_command(chat, run, command),
         {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- (admission["status"] == "ACCEPTED" and admission["input_key"] == command["input_key"]) or {:error, :accepted_receipt_mismatch},
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         :ok <- native_input_matches(command, chat, input),
         {:ok, operations} <- Jason.decode(command["payload_json"]),
         true <- amendment_operations?(operations) or {:error, :invalid_amendment_operations},
         [%{"operation" => "propose_contract_revision", "markdown" => markdown} = proposal] <- [List.last(operations)],
         true <- map_size(proposal) == 2 or {:error, :invalid_amendment_operations},
         {:ok, parsed} <- parse(store, chat, run, input, command),
         true <- encode(parsed) == command["payload_json"] or {:error, :native_intent_mismatch},
         {:ok, questions} <- current_questions(store, chat, run, input, Enum.drop(operations, -1)),
         {:ok, current_contract} <- current_contract(run),
         {:ok, proposed_revision, supersedes} <- proposal_revision(store, run, command),
         {:ok, proposed} <- proposed_contract(run, current_contract, markdown, proposed_revision),
         {:ok, disposition} <- amendment_disposition(store, run) do
      {:ok,
       %{
         command: command,
         chat: chat,
         association: association,
         run: run,
         input: input,
         answer_questions: questions,
         admission: admission,
         current_contract: current_contract,
         proposed_contract: proposed,
         supersedes: supersedes,
         disposition: disposition
       }}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_amendment_binding}
      nil -> {:error, :native_input_missing}
      _ -> {:error, :invalid_amendment_proposal}
    end
  rescue
    _error -> {:error, :invalid_amendment_proposal}
  end

  defp current_contract(run) do
    with {:ok, snapshot} <- decode_object(run["snapshot_json"]),
         {:ok, contract} <- Contract.authorized_from_snapshot(snapshot, run["issue_key"]),
         true <- installed_contract_matches?(contract, run) or {:error, :installed_contract_binding_mismatch} do
      {:ok, contract}
    else
      {:error, _} = error -> error
    end
  end

  defp installed_contract_matches?(contract, run),
    do:
      contract.revision == run["spec_revision"] and contract.sha256 == run["contract_sha256"] and
        contract.markdown == run["contract_markdown"]

  defp proposal_revision(store, run, command) do
    command_key = command["command_key"]

    case Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND active_owner = 1", [run["run_id"]]) do
      nil ->
        {:ok, run["spec_revision"] + 1, nil}

      %{"command_key" => ^command_key} ->
        case Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_key]) do
          amendment when is_map(amendment) ->
            {:ok, amendment["proposed_revision"], existing_supersession(amendment)}

          _ ->
            {:ok, run["spec_revision"] + 1, nil}
        end

      %{"command_key" => key} ->
        correction_revision(store, run, key)
    end
  end

  defp correction_revision(store, run, key) do
    case reserved_owner_conflict(store, run, key) do
      :reservation_conflict ->
        {:error, :amendment_reservation_conflict}

      :not_conflict ->
        with {:ok, correction} <- TicketContractAmendment.correction_revision(store, run, key) do
          {:ok, correction.revision, correction}
        end

      {:error, _} = error ->
        error
    end
  end

  defp reserved_owner_conflict(store, run, command_key) do
    case TicketContractAmendment.get(store, command_key) do
      {:ok, amendment} ->
        active_unpublished_owner? =
          amendment["run_id"] == run["run_id"] and amendment["phase"] == "RESERVED" and amendment["active_owner"] == 1 and
            is_nil(Store.one!(store, "SELECT command_key FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key]))

        if active_unpublished_owner?, do: :reservation_conflict, else: :not_conflict

      {:error, :unknown_contract_amendment} ->
        :not_conflict

      {:error, _} = error ->
        error
    end
  end

  defp existing_supersession(%{"supersession_json" => nil}), do: nil

  defp existing_supersession(amendment) do
    case Jason.decode(amendment["supersession_json"]) do
      {:ok, link} ->
        %{
          predecessor_command_key: link["predecessor_command_key"],
          input_key: link["predecessor_input_key"],
          input_sha256: link["predecessor_input_sha256"],
          payload_sha256: link["predecessor_payload_sha256"],
          proposed_contract_sha256: link["predecessor_proposed_contract_sha256"],
          draft_comment_id: link["predecessor_draft_comment_id"],
          draft_body_sha256: link["predecessor_draft_body_sha256"],
          draft_effect_sha256: link["predecessor_draft_effect_sha256"],
          draft_readback_json: link["predecessor_draft_readback_json"],
          draft_readback_sha256: link["predecessor_draft_readback_sha256"],
          critic_task_key: link["predecessor_critic_task_key"],
          critic_attempt_sha256: link["predecessor_critic_attempt_sha256"],
          critic_result_sha256: link["predecessor_critic_result_sha256"]
        }

      _ ->
        nil
    end
  end

  defp proposed_contract(run, _current, markdown, revision) do
    with {:ok, normalized} <- Contract.normalize_draft_revision(markdown, revision),
         {:ok, false} <- Contract.manual_validation_required(normalized) do
      contract = Contract.bind(run["issue_key"], revision, normalized)
      {:ok, contract}
    else
      {:ok, true} -> {:error, :manual_validation_required}
      {:error, _} = error -> error
    end
  end

  defp amendment_disposition(_store, %{"state" => "READY_FOR_REVIEW"}), do: {:ok, nil}

  defp amendment_disposition(store, %{"state" => "WRITING"} = run) do
    case historical_blocked_disposition(store, run) do
      {:ok, disposition} -> {:ok, disposition}
      {:error, _} -> current_blocked_disposition(store, run)
    end
  end

  defp amendment_disposition(_store, _run), do: {:error, :amendment_run_state_not_admitted}

  defp current_blocked_disposition(store, run) do
    with {:ok, context} <- TicketContext.context(store, run["run_id"]),
         %{
           status: "BLOCKED",
           request_key: request_key,
           output_sha256: output_sha,
           artifact: %{artifact_ref: ref}
         } <- context.writer_disposition,
         {:ok, proof} <- WorkerEvidence.completed_result(store, request_key),
         true <- (proof.run == run and proof.output["status"] == "BLOCKED" and proof.evidence["output_sha256"] == output_sha) or {:error, :stopped_blocked_writer_not_proven},
         {:ok, disposition} <- blocked_disposition(run, request_key, output_sha, ref, proof) do
      {:ok, disposition}
    else
      _ -> {:error, :stopped_blocked_writer_not_proven}
    end
  end

  defp historical_blocked_disposition(store, run) do
    with {:ok, %{amendment: amendment}} <- TicketContractAmendment.blocked_predecessor_for_installed_run(store, run),
         {:ok, predecessor} <- decode_object(amendment["predecessor_json"]),
         true <- predecessor["status"] == "BLOCKED" and predecessor["run_id"] == run["run_id"] do
      {:ok, predecessor}
    else
      _ -> {:error, :stopped_blocked_writer_not_proven}
    end
  end

  defp blocked_disposition(run, request_key, output_sha, ref, proof) do
    disposition = %{
      "status" => "BLOCKED",
      "run_id" => run["run_id"],
      "request_key" => request_key,
      "output_sha256" => output_sha,
      "artifact_ref" => ref,
      "task_key" => proof.task["task_key"],
      "reservation_key" => proof.access["reservation_key"],
      "binding_sha256" => proof.evidence["binding_sha256"],
      "owner_stop_sha256" => digest(proof.evidence["owner_stop_json"]),
      "task_sha256" => digest(encode(proof.task)),
      "evidence_sha256" => digest(encode(proof.evidence)),
      "access_sha256" => digest(encode(proof.access))
    }

    if is_nil(run["candidate_sha"]) do
      with {:ok, head} <- WorkerEvidence.checkout_head(proof.access) do
        {:ok, Map.put(disposition, "checkout_head_sha", head)}
      end
    else
      {:ok, disposition}
    end
  end

  @spec apply_accepted(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply_accepted(store, command_key, controller_context) do
    atomic(store, &apply_accepted_transaction(&1, command_key, controller_context))
  end

  @spec recover_declared_answer(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def recover_declared_answer(store, rejected_key, controller_context) do
    atomic(store, &recover_declared_answer_transaction(&1, rejected_key, controller_context))
  end

  defp recover_declared_answer_transaction(store, rejected_key, controller_context) do
    case Store.one!(store, "SELECT * FROM ticket_chat_answer_recoveries WHERE predecessor_command_key = ?", [rejected_key]) do
      recovery when is_map(recovery) -> replay_declared_answer(store, recovery, controller_context)
      nil -> apply_declared_answer_recovery(store, rejected_key, controller_context)
    end
  end

  defp apply_declared_answer_recovery(store, rejected_key, controller_context) do
    with {:ok, command} <- get(store, rejected_key),
         :ok <- validate_answer_recovery_predecessor(command),
         {:ok, chat, run} <- bound(store, command["run_id"]),
         true <- controller_context_matches?(controller_context, chat, run) or {:error, :stale_controller_context},
         :ok <- current_command(chat, run, command),
         {:ok, question_key, body_phrase, question_digest_value, input} <- answer_recovery_input(store, command, chat),
         {:ok, original, answer} <-
           answer_recovery_question(store, command, chat, run, input, question_key, question_digest_value, body_phrase),
         result <- persist_declared_answer(store, command, input, original, answer) do
      result
    else
      {:error, _} = error -> error
    end
  end

  defp validate_answer_recovery_predecessor(command) do
    with true <- (command["status"] == "REJECTED" and is_nil(command["application_receipt_json"])) or {:error, :answer_recovery_predecessor_invalid},
         {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- (admission["status"] == "REJECTED" and admission["reason"] == "native_intent_mismatch") or {:error, :answer_recovery_predecessor_invalid},
         true <-
           (is_binary(command["input_key"]) and admission["input_key"] == command["input_key"]) or
             {:error, :answer_recovery_predecessor_invalid} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp answer_recovery_input(store, command, chat) do
    with {:ok, operations} <- Jason.decode(command["payload_json"]),
         [%{"operation" => "answer_question", "question_key" => question_key, "value" => phrase, "question_digest" => question_digest_value} = operation] <- operations,
         true <- (map_size(operation) == 4 and is_binary(phrase)) or {:error, :answer_recovery_predecessor_invalid},
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         :ok <- native_input_matches(command, chat, input),
         {:ok, ^question_key, body_phrase} <- declared_phrase(input["body"], question_key),
         true <- body_phrase == phrase or {:error, :answer_recovery_value_mismatch} do
      {:ok, question_key, body_phrase, question_digest_value, input}
    else
      {:error, _} = error -> error
      _ -> {:error, :answer_recovery_evidence_invalid}
    end
  end

  defp answer_recovery_question(store, command, chat, run, input, question_key, question_digest_value, body_phrase) do
    with original when is_map(original) <- question(store, question_key),
         true <-
           answer_recovery_question_matches?(original, command, chat, run, input) or
             {:error, :answer_recovery_question_changed},
         true <- question_digest_value == question_digest(original) or {:error, :answer_recovery_question_changed},
         {:ok, answers} <- Jason.decode(original["answers_json"]),
         true <-
           (answers_valid?(answers) and is_map(answers) and not Map.has_key?(answers, "type")) or
             {:error, :answer_recovery_value_mismatch},
         {:ok, answer} <- Map.fetch(answers, normalize(body_phrase)) do
      {:ok, original, answer}
    else
      {:error, _} = error -> error
      _ -> {:error, :answer_recovery_evidence_invalid}
    end
  end

  defp answer_recovery_question_matches?(question, command, chat, run, input) do
    question["status"] == "OPEN" and question["chat_key"] == chat["chat_key"] and question["run_id"] == run["run_id"] and
      question["binding_json"] == command["binding_json"] and question["opened_at"] <= input["started_at"]
  end

  defp declared_phrase(body, question_key) do
    patterns = [~r/\AAnswer ([A-Za-z0-9:._-]+): ([^`\r\n]+)\n?\z/, ~r/\A`Answer ([A-Za-z0-9:._-]+): ([^`\r\n]+)`\n?\z/]

    case Enum.find_value(patterns, &Regex.run(&1, body || "")) do
      [_, ^question_key, phrase] -> {:ok, question_key, phrase}
      _ -> {:error, :answer_recovery_body_invalid}
    end
  end

  defp persist_declared_answer(store, command, input, question, answer) do
    preimage = encode(question)
    recovery_key = "TAR-" <> digest(encode([command["command_key"], input["input_key"]]))

    proof = %{
      "predecessor_command_key" => command["command_key"],
      "input_key" => input["input_key"],
      "binding_sha256" => digest(command["binding_json"]),
      "command_payload_sha256" => command["payload_sha256"],
      "command_payload_json_sha256" => digest(command["payload_json"]),
      "command_receipt_sha256" => digest(command["receipt_json"]),
      "input_body_sha256" => input["body_sha256"],
      "native_readback_sha256" => input["readback_sha256"],
      "staging_receipts_sha256" => digest(input["staging_receipts_json"]),
      "question_preimage_sha256" => digest(preimage),
      "answer_sha256" => digest(encode(answer))
    }

    proof_json = encode(proof)

    Store.query!(
      store,
      "UPDATE ticket_chat_questions SET status = 'ANSWERED', answer_json = ?, input_key = ? WHERE question_key = ? AND status = 'OPEN' AND chat_key = ? AND run_id = ? AND binding_json = ? AND body = ? AND answers_json = ? AND opened_at = ?",
      [
        encode(answer),
        input["input_key"],
        question["question_key"],
        question["chat_key"],
        question["run_id"],
        question["binding_json"],
        question["body"],
        question["answers_json"],
        question["opened_at"]
      ]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] != 1, do: Exqlite.rollback(store, :answer_recovery_question_changed)

    Store.query!(
      store,
      "INSERT INTO ticket_chat_answer_recoveries(recovery_key, predecessor_command_key, input_key, chat_key, run_id, " <>
        "question_key, question_preimage_json, answer_json, proof_json, proof_sha256, created_at) VALUES (?, ?, ?, ?, ?, " <>
        "?, ?, ?, ?, ?, ?)",
      [
        recovery_key,
        command["command_key"],
        input["input_key"],
        command["chat_key"],
        command["run_id"],
        question["question_key"],
        preimage,
        encode(answer),
        proof_json,
        digest(proof_json),
        now()
      ]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] != 1, do: Exqlite.rollback(store, :answer_recovery_insert_conflict)

    receipt = %{
      "status" => "APPLIED",
      "kind" => "DECLARED_ANSWER_RECOVERY",
      "recovery_key" => recovery_key,
      "predecessor_command_key" => command["command_key"],
      "input_key" => input["input_key"],
      "question_key" => question["question_key"],
      "answer_sha256" => digest(encode(answer)),
      "proof_sha256" => digest(proof_json)
    }

    Store.query!(store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('TICKET_ANSWER_RECOVERED', ?, ?, ?)", [command["run_id"], encode(receipt), now()])
    if Store.one!(store, "SELECT changes() AS count")["count"] != 1, do: Exqlite.rollback(store, :answer_recovery_event_conflict)
    {:ok, receipt}
  end

  defp replay_declared_answer(store, recovery, controller_context) do
    current = question(store, recovery["question_key"])
    proof = recovery["proof_json"]

    with true <- digest(proof) == recovery["proof_sha256"],
         {:ok, decoded} <- Jason.decode(proof),
         true <- replay_answer_proof_identity?(decoded, recovery),
         {:ok, command} <- replay_answer_command(store, recovery, decoded),
         {:ok, chat, input} <- replay_answer_context(store, recovery, command, decoded, controller_context),
         {:ok, question_key, phrase, question_digest_value} <- replay_answer_input(command, recovery, input),
         {:ok, original, _answer} <-
           replay_answer_value(recovery, decoded, command, chat, input, question_key, phrase, question_digest_value),
         true <- replay_answer_current_question?(current, recovery, original) do
      {:ok,
       %{
         "status" => "APPLIED",
         "kind" => "DECLARED_ANSWER_RECOVERY",
         "recovery_key" => recovery["recovery_key"],
         "predecessor_command_key" => recovery["predecessor_command_key"],
         "input_key" => recovery["input_key"],
         "question_key" => recovery["question_key"],
         "answer_sha256" => decoded["answer_sha256"],
         "proof_sha256" => recovery["proof_sha256"]
       }}
    else
      _ -> {:error, :answer_recovery_replay_unproven}
    end
  end

  defp replay_answer_proof_identity?(decoded, recovery) do
    decoded["predecessor_command_key"] == recovery["predecessor_command_key"] and
      decoded["input_key"] == recovery["input_key"]
  end

  defp replay_answer_command(store, recovery, decoded) do
    with {:ok, command} <- get(store, recovery["predecessor_command_key"]),
         true <- command["status"] == "REJECTED" and is_nil(command["application_receipt_json"]) and command["input_key"] == recovery["input_key"],
         true <-
           command["payload_sha256"] == decoded["command_payload_sha256"] and digest(command["payload_json"]) == decoded["command_payload_json_sha256"] and
             digest(command["receipt_json"]) == decoded["command_receipt_sha256"],
         true <- digest(command["binding_json"]) == decoded["binding_sha256"],
         {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- admission["status"] == "REJECTED" and admission["reason"] == "native_intent_mismatch" and admission["input_key"] == command["input_key"] do
      {:ok, command}
    else
      _ -> {:error, :answer_recovery_replay_unproven}
    end
  end

  defp replay_answer_context(store, recovery, command, decoded, controller_context) do
    with {:ok, chat, run} <- bound(store, command["run_id"]),
         true <- controller_context_matches?(controller_context, chat, run),
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         true <-
           input["input_key"] == recovery["input_key"] and input["chat_key"] == recovery["chat_key"] and input["body_sha256"] == decoded["input_body_sha256"] and
             input["readback_sha256"] == decoded["native_readback_sha256"] and digest(input["staging_receipts_json"]) == decoded["staging_receipts_sha256"] and
             digest(input["body"]) == input["body_sha256"],
         :ok <- native_input_matches(command, chat, input) do
      {:ok, chat, input}
    else
      _ -> {:error, :answer_recovery_replay_unproven}
    end
  end

  defp replay_answer_input(command, recovery, input) do
    with {:ok, operations} <- Jason.decode(command["payload_json"]),
         [%{"operation" => "answer_question", "question_key" => question_key, "value" => phrase, "question_digest" => question_digest_value}] <- operations,
         true <- question_key == recovery["question_key"],
         {:ok, ^question_key, body_phrase} <- declared_phrase(input["body"], question_key) do
      {:ok, question_key, {phrase, body_phrase}, question_digest_value}
    else
      _ -> {:error, :answer_recovery_replay_unproven}
    end
  end

  defp replay_answer_value(recovery, decoded, command, chat, input, question_key, {phrase, body_phrase}, question_digest_value) do
    with true <- digest(recovery["question_preimage_json"]) == decoded["question_preimage_sha256"],
         {:ok, original} <- Jason.decode(recovery["question_preimage_json"]),
         true <- original["status"] == "OPEN" and original["binding_json"] == command["binding_json"],
         {:ok, historical_binding} <- Jason.decode(command["binding_json"]),
         true <- historical_binding["generation"] == chat["generation"] and input["generation"] == chat["generation"],
         true <- phrase == body_phrase and question_digest_value == question_digest(original),
         {:ok, answers} <- Jason.decode(original["answers_json"]),
         true <- answers_valid?(answers) and is_map(answers) and not Map.has_key?(answers, "type"),
         {:ok, answer} <- Map.fetch(answers, normalize(body_phrase)),
         true <- replay_answer_receipt_matches?(command, recovery, input, question_key, decoded, answer) do
      {:ok, original, answer}
    else
      _ -> {:error, :answer_recovery_replay_unproven}
    end
  end

  defp replay_answer_receipt_matches?(command, recovery, input, question_key, decoded, answer) do
    encode(answer) == recovery["answer_json"] and digest(encode(answer)) == decoded["answer_sha256"] and
      recovery["recovery_key"] == "TAR-" <> digest(encode([command["command_key"], input["input_key"]])) and
      {recovery["chat_key"], recovery["run_id"], recovery["question_key"]} == {command["chat_key"], command["run_id"], question_key}
  end

  defp replay_answer_current_question?(current, recovery, original) do
    is_map(current) and current["status"] == "ANSWERED" and current["input_key"] == recovery["input_key"] and current["answer_json"] == recovery["answer_json"] and
      Enum.all?(~w(question_key chat_key run_id binding_json body answers_json opened_at), &(current[&1] == original[&1]))
  end

  @doc false
  @spec preflight_rework_transfer(Store.connection(), String.t()) :: :ok | {:error, term()}
  def preflight_rework_transfer(store, command_key) do
    case get(store, command_key) do
      {:ok, command} ->
        case rework_plan(store, command) do
          {:ok, _operations, _questions, _input} -> :ok
          {:error, _} = error -> error
        end

      error ->
        error
    end
  end

  @doc false
  @spec validate_ready_rework(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_ready_rework(store, command_key) do
    with {:ok, command} <- get(store, command_key),
         {:ok, operations, questions, input} <- rework_plan(store, command),
         {:ok, chat, run} <- bound(store, command["run_id"]),
         true <- (run["state"] == "READY_FOR_REVIEW" and is_binary(run["candidate_sha"])) or {:error, :ready_rework_not_current},
         :ok <- ready_rework_fences(store, chat, run, command, operations) do
      {:ok, %{command: command, chat: chat, run: run, input: input, operations: operations, questions: questions}}
    else
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec record_ready_rework(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_ready_rework(store, command_key, transfer) do
    with {:ok, command} <- get(store, command_key),
         {:ok, operations, questions, input} <- rework_plan(store, command),
         {:ok, chat, run} <- bound(store, command["run_id"]),
         true <- run["state"] == "REVIEW_WRITING" or {:error, :ready_rework_not_current},
         :ok <- ready_rework_fences(store, chat, run, command, operations),
         true <-
           valid_ready_rework_transfer?(transfer, run, command, input) or {:error, :ready_rework_transfer_unproven},
         :ok <- apply_rework_answers(store, operations, questions, input),
         receipt = %{
           "status" => "APPLIED",
           "kind" => "READY_WRITER_REWORK",
           "command_key" => command_key,
           "run_id" => run["run_id"],
           "input_key" => input["input_key"],
           "candidate_sha" => run["candidate_sha"],
           "request_key" => transfer["request_key"],
           "reservation_key" => transfer["reservation_key"],
           "reservation_generation" => transfer["reservation_generation"],
           "prior_request_key" => transfer["prior_request_key"],
           "prior_evidence_sha256" => transfer["prior_evidence_sha256"],
           "prior_access_sha256" => transfer["prior_access_sha256"],
           "prior_evidence_json" => transfer["prior_evidence_json"],
           "prior_access_json" => transfer["prior_access_json"],
           "prior_run_json" => transfer["prior_run_json"],
           "prior_run_sha256" => transfer["prior_run_sha256"],
           "prior_verifier_task_json" => transfer["prior_verifier_task_json"],
           "prior_verifier_evidence_json" => transfer["prior_verifier_evidence_json"],
           "prior_candidate_handoff" => transfer["prior_candidate_handoff"],
           "prior_push_envelope_sha256" => transfer["prior_push_envelope_sha256"],
           "answered_question_keys" => Enum.map(questions, & &1["question_key"]),
           "answer_proof_sha256" => answer_proof(questions, input)
         },
         {:ok, applied} <- persist_application(store, command, "APPLIED", receipt) do
      {:ok, applied}
    else
      {:error, _} = error -> error
    end
  end

  defp valid_ready_rework_transfer?(transfer, run, command, input) when is_map(transfer) do
    ready_rework_transfer_reservation_valid?(transfer) and
      ready_rework_transfer_history_valid?(transfer) and
      ready_rework_transfer_binding_valid?(transfer, run, command, input)
  end

  defp valid_ready_rework_transfer?(_transfer, _run, _command, _input), do: false

  defp ready_rework_transfer_reservation_valid?(transfer) do
    transfer["request_key"] not in [nil, false] and transfer["reservation_key"] not in [nil, false] and
      transfer["prior_request_key"] not in [nil, false] and transfer["request_key"] != transfer["prior_request_key"] and
      is_integer(transfer["reservation_generation"]) and transfer["reservation_generation"] > 0
  end

  defp ready_rework_transfer_history_valid?(transfer) do
    is_binary(transfer["prior_evidence_sha256"]) and is_binary(transfer["prior_access_sha256"]) and
      is_binary(transfer["prior_evidence_json"]) and is_binary(transfer["prior_access_json"]) and
      valid_prior_run_digest?(transfer) and is_binary(transfer["prior_verifier_task_json"]) and
      is_binary(transfer["prior_verifier_evidence_json"]) and is_binary(transfer["prior_candidate_handoff"]) and
      is_binary(transfer["prior_push_envelope_sha256"])
  end

  defp valid_prior_run_digest?(transfer) do
    is_binary(transfer["prior_run_json"]) and transfer["prior_run_sha256"] == digest(transfer["prior_run_json"])
  end

  defp ready_rework_transfer_binding_valid?(transfer, run, command, input) do
    transfer["command_key"] == command["command_key"] and transfer["input_key"] == input["input_key"] and
      transfer["candidate_sha"] == run["candidate_sha"]
  end

  defp ready_rework_fences(store, chat, run, command, operations) do
    actionable =
      Store.query!(
        store,
        """
        SELECT command_key, status FROM ticket_chat_commands
        WHERE chat_key = ? AND run_id = ?
          AND (status = 'ACCEPTED' OR
            (status = 'PENDING' AND (input_key IS NOT NULL OR receipt_json IS NOT NULL)))
        ORDER BY command_key
        """,
        [chat["chat_key"], run["run_id"]]
      ).rows

    open_questions =
      Store.query!(
        store,
        "SELECT question_key FROM ticket_chat_questions WHERE chat_key = ? AND run_id = ? AND status = 'OPEN' ORDER BY question_key",
        [chat["chat_key"], run["run_id"]]
      ).rows
      |> Enum.map(fn [key] -> key end)

    selected_questions =
      operations
      |> Enum.filter(&(&1["operation"] == "answer_question"))
      |> Enum.map(& &1["question_key"])
      |> Enum.sort()

    active_amendment =
      Store.one!(
        store,
        "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND active_owner = 1 LIMIT 1",
        [run["run_id"]]
      )

    cond do
      not is_nil(active_amendment) -> {:error, :active_contract_amendment}
      actionable != [[command["command_key"], "ACCEPTED"]] -> {:error, :competing_ticket_command}
      open_questions != selected_questions -> {:error, :unrelated_open_question}
      true -> :ok
    end
  end

  @doc false
  @spec validate_ready_rework_replay(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_ready_rework_replay(store, command_key) do
    with {:ok, %{"status" => "APPLIED", "application_receipt_json" => raw} = command} <- get(store, command_key),
         {:ok, receipt} <- decode_object(raw),
         true <- (receipt["kind"] == "READY_WRITER_REWORK" and receipt["command_key"] == command_key) or {:error, :ready_rework_receipt_invalid},
         true <- digest(command["payload_json"] || "") == command["payload_sha256"] or {:error, :ticket_command_payload_changed},
         {:ok, operations} <- Jason.decode(command["payload_json"]),
         true <- rework_payload?(operations) or {:error, :ticket_rework_transfer_unproven},
         :ok <- validate_answer_replay(store, command, receipt, Enum.drop(operations, -1)),
         {:ok, input} <- historical_rework_input(store, command, receipt),
         true <-
           (receipt["input_key"] == input["input_key"] and receipt["candidate_sha"] == binding_candidate(command)) or
             {:error, :ready_rework_receipt_invalid},
         :ok <- validate_ready_rework_application_origin(store, command, receipt),
         :ok <- ready_rework_history_matches(store, receipt) do
      {:ok, %{command: command, receipt: receipt, input: input}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ready_rework_receipt_invalid}
    end
  end

  defp validate_ready_rework_application_origin(store, command, receipt) do
    with {:ok, binding} <- decode_object(command["binding_json"]),
         {:ok, prior_run} <- decode_object(receipt["prior_run_json"]),
         :ok <- validate_ready_rework_application_binding(command, receipt, binding, prior_run),
         true <-
           ready_rework_application_event_matches?(store, command, receipt) or
             {:error, :ready_rework_application_event_unproven} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_ready_rework_application_binding(command, receipt, binding, prior_run) do
    if command["input_key"] == receipt["input_key"] and command["run_id"] == receipt["run_id"] and
         prior_run["run_id"] == command["run_id"] and prior_run["candidate_sha"] == binding["candidate_sha"] and
         prior_run["spec_revision"] == binding["spec_revision"] and prior_run["contract_sha256"] == binding["contract_sha256"],
       do: :ok,
       else: {:error, :ready_rework_application_event_unproven}
  end

  defp ready_rework_application_event_matches?(store, command, receipt) do
    events = Store.query!(store, "SELECT payload_json FROM events WHERE event_type = 'TICKET_COMMAND_APPLIED' AND run_id = ?", [command["run_id"]]).rows
    Enum.count(events, &ready_rework_application_event?(&1, command, receipt)) == 1
  end

  defp ready_rework_application_event?([raw], command, receipt) do
    case decode_object(raw) do
      {:ok, %{"command_key" => key, "input_key" => input_key, "application_receipt_json" => event_receipt}} ->
        key == command["command_key"] and input_key == command["input_key"] and event_receipt == receipt

      _ ->
        false
    end
  end

  defp ready_rework_history_matches(store, receipt) do
    with {:ok, history} <- decode_ready_rework_history(receipt),
         :ok <- validate_ready_rework_history_fields(receipt, history),
         :ok <- validate_ready_rework_history_rows(store, receipt, history) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp decode_ready_rework_history(receipt) do
    with {:ok, prior_run} <- decode_object(receipt["prior_run_json"]),
         {:ok, evidence} <- decode_object(receipt["prior_evidence_json"]),
         {:ok, access} <- decode_object(receipt["prior_access_json"]),
         {:ok, verifier_task} <- decode_object(receipt["prior_verifier_task_json"]),
         {:ok, verifier_evidence} <- decode_object(receipt["prior_verifier_evidence_json"]) do
      {:ok,
       %{
         prior_run: prior_run,
         evidence: evidence,
         access: access,
         verifier_task: verifier_task,
         verifier_evidence: verifier_evidence
       }}
    end
  end

  defp validate_ready_rework_history_fields(receipt, history) do
    prior_run = history.prior_run
    evidence = history.evidence
    access = history.access

    with true <- digest(receipt["prior_run_json"] || "") == receipt["prior_run_sha256"] or {:error, :ready_rework_history_changed},
         :ok <- validate_ready_rework_prior_run(receipt, prior_run),
         :ok <- validate_ready_rework_prior_digests(receipt, evidence, access) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_ready_rework_prior_run(receipt, prior_run) do
    if prior_run["state"] == "READY_FOR_REVIEW" and prior_run["candidate_sha"] == receipt["candidate_sha"] and
         prior_run["candidate_handoff"] == receipt["prior_candidate_handoff"] and is_integer(prior_run["mr_iid"]) and is_binary(prior_run["mr_url"]),
       do: :ok,
       else: {:error, :ready_rework_history_changed}
  end

  defp validate_ready_rework_prior_digests(receipt, evidence, access) do
    with true <-
           digest(receipt["prior_candidate_handoff"] || "") == receipt["prior_push_envelope_sha256"] or
             {:error, :ready_rework_history_changed},
         true <-
           (digest(encode(evidence)) == receipt["prior_evidence_sha256"] and digest(encode(access)) == receipt["prior_access_sha256"]) or
             {:error, :ready_rework_history_changed} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_ready_rework_history_rows(store, receipt, history) do
    evidence = history.evidence
    access = history.access
    verifier_task = history.verifier_task
    verifier_evidence = history.verifier_evidence

    with true <-
           Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [evidence["request_key"]]) == evidence or
             {:error, :ready_rework_history_changed},
         true <-
           Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [access["reservation_key"]]) == access or
             {:error, :ready_rework_history_changed},
         true <-
           Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [verifier_task["task_key"]]) == verifier_task or
             {:error, :ready_rework_history_changed},
         true <-
           Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [verifier_evidence["request_key"]]) == verifier_evidence or
             {:error, :ready_rework_history_changed},
         {:ok, verifier_output} <- decode_object(verifier_evidence["output_json"]),
         {:ok, verifier_binding} <- decode_object(verifier_evidence["binding_json"]),
         true <-
           verifier_history_passes?(verifier_output, verifier_binding, receipt) or
             {:error, :ready_rework_history_changed} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp verifier_history_passes?(output, binding, receipt) do
    output["status"] == "PASS" and output["candidate_sha"] == receipt["candidate_sha"] and
      binding["expected_sha"] == receipt["candidate_sha"]
  end

  defp binding_candidate(command) do
    case Jason.decode(command["binding_json"] || "null") do
      {:ok, binding} when is_map(binding) -> binding["candidate_sha"]
      _ -> nil
    end
  end

  @doc false
  @spec validate_rework_replay(Store.connection(), String.t()) :: :ok | {:error, term()}
  def validate_rework_replay(store, command_key) do
    with {:ok, %{"status" => "APPLIED", "application_receipt_json" => raw} = command} <- get(store, command_key),
         {:ok, receipt} <- decode_object(raw),
         true <- receipt["status"] == "APPLIED" and receipt["kind"] == "BLOCKED_WRITER_RESUMED" and receipt["command_key"] == command_key,
         true <- digest(command["payload_json"] || "") == command["payload_sha256"],
         {:ok, operations} <- Jason.decode(command["payload_json"]),
         true <- rework_payload?(operations) do
      validate_rework_replay_proof(store, command, receipt, operations)
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_resume_answer_replay_unproven}
    end
  end

  defp validate_rework_replay_proof(store, command, receipt, [%{"operation" => "request_rework"}]) do
    if Map.has_key?(receipt, "answered_question_keys") or Map.has_key?(receipt, "answer_proof_sha256") do
      case validate_answer_replay(store, command, receipt, []) do
        :ok -> :ok
        _ -> {:error, :blocked_resume_answer_replay_unproven}
      end
    else
      validate_legacy_singleton_rework_replay(store, command, receipt)
    end
  end

  defp validate_rework_replay_proof(store, command, receipt, operations),
    do: validate_answer_replay(store, command, receipt, Enum.drop(operations, -1))

  defp validate_answer_replay(store, command, receipt, answer_operations) do
    with true <- Map.has_key?(receipt, "answered_question_keys") and Map.has_key?(receipt, "answer_proof_sha256"),
         keys when is_list(keys) <- receipt["answered_question_keys"],
         true <- keys == Enum.uniq(keys),
         true <- keys == Enum.map(answer_operations, & &1["question_key"]),
         {:ok, input} <- historical_rework_input(store, command, receipt),
         questions <- Enum.map(keys, &question(store, &1)),
         true <- Enum.all?(questions, &is_map/1),
         true <- Enum.zip(questions, answer_operations) |> Enum.all?(fn {current, operation} -> historical_answer_matches?(current, operation, command, input) end),
         true <- receipt["answer_proof_sha256"] == answer_proof(questions, input) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_resume_answer_replay_unproven}
    end
  end

  defp historical_rework_input(store, command, receipt) do
    with true <- is_binary(command["input_key"]) and receipt["input_key"] == command["input_key"],
         {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- admission["status"] == "ACCEPTED" and admission["input_key"] == command["input_key"],
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         true <- input["chat_key"] == command["chat_key"],
         true <- input["origin"] == "NATIVE_CLIENT_INPUT" and input["generation"] == binding_generation(command),
         true <- input["body_sha256"] == command["body_sha256"] and digest(input["body"] || "") == command["body_sha256"],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, input["readback_sha256"] || ""),
         true <- historical_rework_proven?(store, command, input) do
      {:ok, input}
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_resume_native_input_unproven}
    end
  end

  defp historical_rework_proven?(store, command, input) do
    if historical_staging_matches?(command, input) and command_created_during_input?(command, input) do
      true
    else
      case TicketChat.for_run(store, command["run_id"]) do
        {:ok, chat} -> TicketReworkRecovery.valid?(command, input, chat)
        _ -> false
      end
    end
  end

  defp historical_staging_matches?(command, input) do
    with {:ok, receipts} when is_map(receipts) <- Jason.decode(input["staging_receipts_json"] || "null"),
         staged when is_map(staged) <- receipts[command["command_key"]] do
      historical_staging_receipt_matches?(command, input, staged)
    else
      _ -> false
    end
  end

  defp historical_staging_receipt_matches?(command, input, %{"attrs" => attrs, "run_id" => run_id, "payload_sha256" => sha} = staged) do
    case Jason.decode(command["binding_json"] || "null") do
      {:ok, binding} when is_map(binding) ->
        historical_staging_command_matches?(command, attrs, staged, run_id, sha) and
          historical_staging_input_matches?(command, input, attrs, binding)

      _ ->
        false
    end
  end

  defp historical_staging_receipt_matches?(_command, _input, _staged), do: false

  defp historical_staging_command_matches?(command, attrs, staged, run_id, sha) do
    run_id == command["run_id"] and sha == command["payload_sha256"] and
      staged["payload_sha256"] == command["payload_sha256"] and original_operations_match?(command, attrs)
  end

  defp historical_staging_input_matches?(command, input, attrs, binding) do
    attrs["proposal_id"] == command["proposal_id"] and attrs["body"] == input["body"] and
      encode(Map.take(attrs, @binding)) == command["binding_json"] and
      binding["generation"] == input["generation"]
  end

  defp binding_generation(command) do
    case Jason.decode(command["binding_json"] || "null") do
      {:ok, %{"generation" => generation}} -> generation
      _ -> nil
    end
  end

  defp historical_answer_matches?(current, operation, command, input) when is_map(current) do
    current["status"] == "ANSWERED" and current["input_key"] == input["input_key"] and
      current["chat_key"] == command["chat_key"] and current["run_id"] == command["run_id"] and
      current["binding_json"] == command["binding_json"] and
      current["opened_at"] <= input["started_at"] and
      operation["question_digest"] == question_digest(current) and
      current["answer_json"] == encode(operation["value"]) and
      answer_matches_schema?(current["answers_json"], operation["value"])
  end

  defp historical_answer_matches?(_current, _operation, _command, _input), do: false

  defp answer_matches_schema?(raw_schema, value) do
    case Jason.decode(raw_schema || "null") do
      {:ok, schema} ->
        answer_matches_decoded_schema?(schema, value)

      _ ->
        false
    end
  end

  defp answer_matches_decoded_schema?(%{"type" => "text", "max_bytes" => limit} = answers, value),
    do: answers_valid?(answers) and is_binary(value) and String.valid?(value) and byte_size(value) <= limit

  defp answer_matches_decoded_schema?(%{"type" => "integer", "min" => low, "max" => high} = answers, value),
    do: answers_valid?(answers) and is_integer(value) and value >= low and value <= high

  defp answer_matches_decoded_schema?(answers, value) when is_map(answers),
    do: answers_valid?(answers) and Enum.any?(Map.values(answers), &(&1 === value))

  defp answer_matches_decoded_schema?(_schema, _value), do: false

  defp validate_legacy_singleton_rework_replay(store, command, receipt) do
    with {:ok, input} <- historical_rework_input(store, command, receipt),
         true <- receipt["input_key"] == input["input_key"],
         true <- receipt["prior_request_key"] |> is_binary(),
         true <- receipt["request_key"] |> is_binary(),
         true <- receipt["reservation_key"] |> is_binary() do
      :ok
    else
      _ -> {:error, :blocked_resume_answer_replay_unproven}
    end
  end

  @doc false
  @spec record_rework_transfer(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_rework_transfer(store, command_key, transfer) do
    with {:ok, command} <- get(store, command_key),
         {:ok, operations, questions, input} <- rework_plan(store, command),
         :ok <- apply_rework_answers(store, operations, questions, input),
         receipt = %{
           status: "APPLIED",
           kind: "BLOCKED_WRITER_RESUMED",
           command_key: command_key,
           input_key: command["input_key"],
           disposition_key: transfer["disposition_key"],
           prior_request_key: transfer["old_request_key"],
           request_key: transfer["new_request_key"],
           reservation_key: transfer["new_reservation_key"],
           reservation_generation: transfer["new_generation"],
           output_sha256: transfer["output_sha256"],
           amendment_command_key: transfer["amendment_command_key"],
           checkout_head_sha: transfer["checkout_head_sha"],
           answered_question_keys: Enum.map(questions, & &1["question_key"]),
           answer_proof_sha256: answer_proof(questions, input)
         },
         {:ok, applied} <- persist_application(store, command, "APPLIED", receipt) do
      {:ok, applied}
    else
      {:error, _} = error -> error
    end
  end

  defp rework_plan(store, %{"status" => "ACCEPTED"} = command) do
    with true <- digest(command["payload_json"] || "") == command["payload_sha256"] or {:error, :ticket_command_payload_changed},
         {:ok, operations} <- Jason.decode(command["payload_json"]),
         true <- rework_payload?(operations) or {:error, :ticket_rework_transfer_unproven},
         {:ok, chat, run} <- bound(store, command["run_id"]),
         :ok <- current_command(chat, run, command),
         {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- (admission["status"] == "ACCEPTED" and admission["input_key"] == command["input_key"]) or {:error, :accepted_receipt_mismatch},
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         :ok <- native_input_matches(command, chat, input),
         {:ok, parsed} <- parse(store, chat, run, input, command),
         true <- encode(parsed) == command["payload_json"] or {:error, :native_intent_mismatch},
         answers = Enum.drop(operations, -1),
         {:ok, questions} <- current_questions(store, chat, run, input, answers) do
      {:ok, operations, questions, input}
    else
      {:ok, _command} -> {:error, :ticket_command_not_accepted}
      {:error, _} = error -> error
      false -> {:error, :stale_application_binding}
      nil -> {:error, :native_input_missing}
      _ -> {:error, :ticket_rework_transfer_unproven}
    end
  end

  defp rework_plan(_store, _command), do: {:error, :ticket_command_not_accepted}

  defp apply_rework_answers(_store, [%{"operation" => "request_rework"}], _questions, _input), do: :ok

  defp apply_rework_answers(store, operations, questions, input) do
    Enum.zip(Enum.drop(operations, -1), questions)
    |> Enum.each(fn {operation, question} ->
      Store.query!(
        store,
        "UPDATE ticket_chat_questions SET status = 'ANSWERED', answer_json = ?, input_key = ? WHERE question_key = ? AND status = 'OPEN' AND chat_key = ? AND run_id = ? AND binding_json = ? AND body = ? AND answers_json = ? AND opened_at = ?",
        [
          encode(operation["value"]),
          input["input_key"],
          question["question_key"],
          question["chat_key"],
          question["run_id"],
          question["binding_json"],
          question["body"],
          question["answers_json"],
          question["opened_at"]
        ]
      )

      if Store.one!(store, "SELECT changes() AS count")["count"] != 1,
        do: Exqlite.rollback(store, :stale_question)
    end)

    :ok
  end

  defp answer_proof([], _input), do: nil

  defp answer_proof(questions, input) do
    digest(encode(%{"input_key" => input["input_key"], "questions" => Enum.map(questions, &%{"question_key" => &1["question_key"], "question_digest" => question_digest(&1)})}))
  end

  defp apply_accepted_transaction(store, command_key, controller_context) do
    case get(store, command_key) do
      {:ok, %{"status" => "APPLIED"} = command} ->
        terminal_replay(store, command)

      {:ok, %{"status" => "REJECTED"} = command} ->
        terminal_replay(store, command)

      {:ok, %{"status" => "ACCEPTED"} = command} ->
        apply_accepted_command(store, command, controller_context)

      {:ok, command} ->
        {:ok, command}

      error ->
        error
    end
  end

  defp apply_accepted_command(store, command, controller_context) do
    if unsupported_accepted_command?(command) do
      {:ok, command}
    else
      case application_plan(store, command, controller_context) do
        {:ok, questions, input} -> apply_answers(store, command, questions, input)
        {:error, reason} -> reject_application(store, command, reason)
      end
    end
  end

  defp unsupported_accepted_command?(command) do
    if digest(command["payload_json"] || "") == command["payload_sha256"] do
      case Jason.decode(command["payload_json"]) do
        {:ok, operations} -> valid_operations?(operations) and not answer_only?(operations)
        _ -> false
      end
    else
      false
    end
  end

  defp valid_operations?(operations) when is_list(operations) and operations != [],
    do: length(operations) <= 4 and Enum.all?(operations, &persisted_operation_valid?/1)

  defp valid_operations?(_operations), do: false

  defp persisted_operation_valid?(%{"operation" => "answer_question", "question_key" => key, "value" => _value, "question_digest" => digest} = operation),
    do: map_size(operation) == 4 and text?(key, 128) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp persisted_operation_valid?(operation), do: operation_valid?(operation)

  defp terminal_replay(store, command) do
    with {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- is_binary(command["input_key"]) and admission["input_key"] == command["input_key"],
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         :ok <- terminal_receipt_matches(store, command, admission) do
      {:ok, command}
    else
      _ -> {:error, :invalid_application_receipt}
    end
  end

  defp terminal_receipt_matches(_store, %{"status" => "APPLIED"} = command, %{"status" => "ACCEPTED"} = admission) do
    with {:ok, receipt} <- decode_object(command["application_receipt_json"]),
         true <- receipt["status"] == "APPLIED" and receipt["command_key"] == command["command_key"] and receipt["input_key"] == command["input_key"],
         true <- admission["input_key"] == command["input_key"] do
      :ok
    else
      _ -> {:error, :invalid_application_receipt}
    end
  end

  defp terminal_receipt_matches(_store, %{"status" => "REJECTED", "application_receipt_json" => nil}, %{"status" => "REJECTED"} = admission) do
    if admission["input_key"] == nil, do: {:error, :invalid_admission_receipt}, else: :ok
  end

  defp terminal_receipt_matches(store, %{"status" => "REJECTED"} = command, %{"status" => "ACCEPTED"} = admission) do
    with {:ok, receipt} <- decode_object(command["application_receipt_json"]),
         true <-
           receipt["status"] == "REJECTED" and receipt["command_key"] == command["command_key"] and
             receipt["input_key"] == command["input_key"] and admission["input_key"] == command["input_key"],
         :ok <- validate_rejected_terminal_reason(store, command, receipt) do
      :ok
    else
      _ -> {:error, :invalid_application_receipt}
    end
  end

  defp terminal_receipt_matches(_store, _command, _admission), do: {:error, :invalid_application_receipt}

  defp validate_rejected_terminal_reason(store, command, receipt) do
    supersession_owner? = canonical_supersession_owner?(store, command["command_key"])

    cond do
      supersession_owner? and receipt["reason"] == "SUPERSEDED_BY_CORRECTED_PROPOSAL" ->
        validate_superseded_terminal_receipt(store, command, receipt)

      supersession_owner? ->
        {:error, :invalid_supersession_receipt}

      receipt["reason"] == "SUPERSEDED_BY_CORRECTED_PROPOSAL" ->
        {:error, :invalid_supersession_receipt}

      true ->
        :ok
    end
  end

  defp canonical_supersession_owner?(store, command_key) do
    amendment = Store.one!(store, "SELECT phase FROM ticket_contract_amendments WHERE command_key = ?", [command_key])
    link = Store.one!(store, "SELECT predecessor_command_key FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command_key])

    match?(%{"phase" => "SUPERSEDED"}, amendment) or is_map(link)
  end

  defp validate_superseded_terminal_receipt(store, command, receipt) do
    with true <- receipt["reason"] == "SUPERSEDED_BY_CORRECTED_PROPOSAL",
         {:ok, amendment} <- TicketContractAmendment.get(store, command["command_key"]),
         true <- amendment["phase"] == "SUPERSEDED",
         {:ok, link} <- decode_object(amendment["receipt_json"]),
         true <- receipt["successor_command_key"] == link["successor_command_key"],
         true <- receipt["supersession_link_sha256"] == digest(amendment["receipt_json"]) do
      :ok
    else
      _ -> {:error, :invalid_supersession_receipt}
    end
  end

  defp decode_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, object} when is_map(object) -> {:ok, object}
      _ -> {:error, :invalid_receipt}
    end
  end

  defp decode_object(_value), do: {:error, :invalid_receipt}

  defp application_plan(store, command, controller_context) do
    with {:ok, chat, run} <- bound(store, command["run_id"]),
         true <- controller_context_matches?(controller_context, chat, run) or {:error, :stale_controller_context},
         :ok <- current_command(chat, run, command),
         {:ok, admission} <- decode_object(command["receipt_json"]),
         true <- (admission["status"] == "ACCEPTED" and admission["input_key"] == command["input_key"]) or {:error, :accepted_receipt_mismatch},
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         :ok <- native_input_matches(command, chat, input),
         {:ok, operations} <- Jason.decode(command["payload_json"]),
         true <- answer_only?(operations) or {:error, :invalid_accepted_operations},
         {:ok, parsed} <- parse(store, chat, run, input, command),
         true <- encode(parsed) == command["payload_json"] or {:error, :native_intent_mismatch},
         {:ok, questions} <- current_questions(store, chat, run, input, operations) do
      {:ok, questions, input}
    else
      {:error, _} = error -> error
      false -> {:error, :stale_application_binding}
      nil -> {:error, :native_input_missing}
      _ -> {:error, :application_evidence_invalid}
    end
  end

  defp controller_context_matches?(context, chat, run),
    do: context == %{"chat_key" => chat["chat_key"], "run_id" => run["run_id"], "binding" => binding(chat, run)}

  defp native_input_matches(command, chat, input) do
    receipt = staging_receipt_for(input, command)

    valid =
      native_route_matches?(chat, input) and native_body_matches?(command, input) and
        ((valid_staging_evidence?(command, input, receipt) and command_created_during_input?(command, input)) or
           TicketReworkRecovery.valid?(command, input, chat))

    if valid, do: :ok, else: {:error, :native_input_evidence_mismatch}
  end

  defp staging_receipt_for(input, command) do
    case Jason.decode(input["staging_receipts_json"]) do
      {:ok, receipts} when is_map(receipts) ->
        case receipts[command["command_key"]] do
          receipt when is_map(receipt) -> receipt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp native_route_matches?(chat, input),
    do:
      input["origin"] == "NATIVE_CLIENT_INPUT" and input["chat_key"] == chat["chat_key"] and
        input["generation"] == chat["generation"] and input["thread_id"] == chat["thread_id"]

  defp native_body_matches?(command, input),
    do:
      digest(input["body"] || "") == input["body_sha256"] and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, input["readback_sha256"] || "") and
        (input["body_sha256"] == command["body_sha256"] or match?({:ok, _body}, formatted_staged_answer_body(command, input)))

  defp valid_staging_evidence?(command, input, receipt) when is_map(receipt) do
    attrs = receipt["attrs"]

    formatted_matches? =
      case formatted_staged_answer_body(command, input, receipt) do
        {:ok, body} when is_map(attrs) -> body == attrs["body"]
        _ -> false
      end

    is_map(attrs) and receipt["run_id"] == command["run_id"] and
      receipt["payload_sha256"] == command["payload_sha256"] and attrs["proposal_id"] == command["proposal_id"] and
      (attrs["body"] == input["body"] or formatted_matches?) and
      matching_staging_receipt?(command, receipt)
  end

  defp valid_staging_evidence?(_command, _input, _receipt), do: false

  defp command_created_during_input?(command, input) do
    case DateTime.from_iso8601(command["created_at"] || "") do
      {:ok, at, _} ->
        created_at = DateTime.to_unix(at, :microsecond) / 1_000_000
        created_at >= input["started_at"] and created_at < input["completed_at"] + 1

      _ ->
        false
    end
  end

  defp answer_only?(operations) when is_list(operations) and operations != [],
    do: length(operations) <= 4 and Enum.all?(operations, &answer_operation?/1)

  defp answer_only?(_operations), do: false

  defp answer_operation?(%{"operation" => "answer_question", "question_key" => key, "value" => _value, "question_digest" => digest} = operation),
    do: map_size(operation) == 4 and text?(key, 128) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp answer_operation?(_operation), do: false

  defp current_questions(store, chat, run, input, operations) do
    chat_key = chat["chat_key"]
    run_id = run["run_id"]

    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      validate_current_question(store, chat, run, input, operation, acc, chat_key, run_id)
    end)
    |> case do
      {:ok, questions} -> {:ok, Enum.reverse(questions)}
      error -> error
    end
  end

  defp validate_current_question(store, chat, run, input, operation, acc, chat_key, run_id) do
    case question(store, operation["question_key"]) do
      %{"status" => "OPEN", "chat_key" => ^chat_key, "run_id" => ^run_id} = current ->
        if current_question?(chat, run, input, operation, current) do
          {:cont, {:ok, [current | acc]}}
        else
          {:halt, {:error, :stale_question}}
        end

      _ ->
        {:halt, {:error, :stale_question}}
    end
  end

  defp current_question?(chat, run, input, operation, question),
    do:
      question["binding_json"] == encode(binding(chat, run)) and question["opened_at"] <= input["started_at"] and
        operation["question_digest"] == question_digest(question)

  defp apply_answers(store, command, questions, input) do
    operations = Jason.decode!(command["payload_json"])

    Enum.zip(operations, questions)
    |> Enum.each(fn {operation, question} ->
      Store.query!(store, "UPDATE ticket_chat_questions SET status = 'ANSWERED', answer_json = ?, input_key = ? WHERE question_key = ? AND status = 'OPEN'", [
        encode(operation["value"]),
        input["input_key"],
        question["question_key"]
      ])

      if Store.one!(store, "SELECT changes() AS count")["count"] != 1,
        do: Exqlite.rollback(store, :stale_question)
    end)

    persist_application(store, command, "APPLIED", %{status: "APPLIED", command_key: command["command_key"], input_key: input["input_key"]})
  end

  defp reject_application(store, command, reason) do
    receipt = %{status: "REJECTED", reason: to_string(reason), command_key: command["command_key"], input_key: command["input_key"]}
    persist_application(store, command, "REJECTED", receipt)
  end

  defp persist_application(store, command, status, receipt) do
    Store.query!(store, "UPDATE ticket_chat_commands SET status = ?, application_receipt_json = ?, updated_at = ? WHERE command_key = ? AND status = 'ACCEPTED'", [
      status,
      encode(receipt),
      now(),
      command["command_key"]
    ])

    if Store.one!(store, "SELECT changes() AS count")["count"] != 1,
      do: Exqlite.rollback(store, :command_application_conflict)

    persist_event(store, command, status, receipt, "application_receipt_json")
    get(store, command["command_key"])
  end

  @spec collect(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def collect(store, run_id, opts \\ []) do
    native_reader = Keyword.get(opts, :native_reader, AppServer)

    with {:ok, chat, _run} <- bound(store, run_id),
         {:ok, request} <- DesktopRequest.get(store, chat["create_request_key"]),
         {:ok, proof} <- Jason.decode(request["target_observation_json"] || "null"),
         {:ok, _request} <- TicketChat.record_thread(store, request, chat["thread_id"], proof),
         {:ok, native} <- read_parent_history(native_reader, chat),
         {:ok, collected} <- admit_readback(store, run_id, native),
         {:ok, recovery} <- recover_failed_preparation(store, run_id, native) do
      {:ok, %{collected | receipts: collected.receipts ++ recovery}}
    end
  end

  defp read_parent_history(reader, chat) do
    case reader.read_native_thread(chat["thread_id"], workspace: chat["cwd"]) do
      {:ok, native} when is_map(native) -> {:ok, native}
      {:error, _} = error -> error
      _ -> {:error, :native_parent_read_unavailable}
    end
  rescue
    _ -> {:error, :native_parent_read_unavailable}
  catch
    :exit, _ -> {:error, :native_parent_read_unavailable}
  end

  @doc false
  @spec recover_failed_preparation(Store.connection(), String.t(), map()) :: {:ok, list()} | {:error, term()}
  def recover_failed_preparation(store, run_id, native) do
    atomic(store, fn tx ->
      with {:ok, chat, run} <- bound(tx, run_id),
           {:ok, context} <- TicketContext.context(tx, run_id),
           {:ok, proof} <- TicketReworkRecovery.prepare(native, chat, run, context),
           key <- "TIN-" <> digest(encode([chat["chat_key"], chat["generation"], proof["turn"]["id"], proof["human_item_id"]])),
           input when is_map(input) <- Store.one!(tx, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [key]),
           nil <- Store.one!(tx, "SELECT command_key FROM ticket_chat_commands WHERE chat_key = ? AND run_id = ? LIMIT 1", [chat["chat_key"], run_id]),
           proof <- TicketReworkRecovery.bind_input(proof, input),
           attrs <-
             Map.merge(proof["binding"], %{"proposal_id" => "recovered-" <> digest(encode([key, proof["binding"]])), "body" => input["body"], "operations" => [%{"operation" => "request_rework"}]}),
           {:ok, command} <- stage_transaction(tx, run_id, attrs) do
        receipt = %{status: "ACCEPTED", input_key: key, worker_started: false, external_changes_applied: false, recovery_evidence: proof, recovery_sha256: digest(encode(proof))}

        with {:ok, accepted} <- persist_decision(tx, command, key, receipt),
             true <- TicketReworkRecovery.valid?(accepted, input, chat) or {:error, :rework_recovery_evidence_invalid} do
          {:ok, [accepted]}
        end
      else
        _ -> {:ok, []}
      end
    end)
  end

  @doc false
  @spec admit_readback(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def admit_readback(store, run_id, native) do
    atomic(store, &admit_transaction(&1, run_id, native))
  end

  defp admit_transaction(store, run_id, native) do
    with {:ok, chat, run} <- bound(store, run_id),
         {:ok, inputs} <- extract(native, chat),
         :ok <- unique_native_identities(inputs),
         :ok <- unique_staged_interpretations(store, chat, run, inputs) do
      inputs
      |> Enum.reduce_while({:ok, []}, &consume_next(store, chat, run, &1, &2))
      |> admission_result()
    end
  end

  defp consume_next(store, chat, run, input, {:ok, receipts}) do
    case consume(store, chat, run, input) do
      {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
      error -> {:halt, error}
    end
  end

  defp admission_result({:ok, receipts}), do: {:ok, %{receipts: Enum.reverse(receipts), worker_started: false}}
  defp admission_result(error), do: error

  defp bound(store, run_id) do
    with {:ok, chat} <- TicketChat.for_run(store, run_id),
         {:ok, run} <- RunLedger.get(store, run_id),
         true <- is_binary(chat["thread_id"]) or {:error, :ticket_parent_not_bound} do
      {:ok, chat, run}
    end
  end

  defp question_valid(attrs) when is_map(attrs) do
    answers = attrs["answers"]

    valid =
      Map.keys(attrs) -- ~w(question_key body answers) == [] and text?(attrs["question_key"], 128) and
        text?(attrs["body"], 2048) and answers_valid?(answers)

    if valid, do: :ok, else: {:error, :invalid_ticket_question}
  end

  defp question_valid(_attrs), do: {:error, :invalid_ticket_question}

  defp answers_valid?(%{"type" => "text", "max_bytes" => limit} = answers),
    do: map_size(answers) == 2 and is_integer(limit) and limit in 1..2048

  defp answers_valid?(%{"type" => "integer", "min" => low, "max" => high} = answers),
    do:
      map_size(answers) == 3 and is_integer(low) and is_integer(high) and low <= high and
        low >= -1_000_000_000 and high <= 1_000_000_000

  defp answers_valid?(answers) when is_map(answers) do
    not Map.has_key?(answers, "type") and map_size(answers) in 1..16 and byte_size(encode(answers)) <= 2048 and
      Enum.all?(answers, fn {phrase, _value} -> text?(phrase, 128) and phrase == normalize(phrase) end)
  end

  defp answers_valid?(_answers), do: false

  defp validate_stage(attrs) when is_map(attrs) do
    valid = Map.keys(attrs) |> Enum.sort() == Enum.sort(@fields)
    operations = attrs["operations"]

    valid =
      valid and text?(attrs["proposal_id"], 128) and text?(attrs["body"], 12_288) and is_list(operations) and
        length(operations) in 1..4 and Enum.all?(operations, &operation_valid?/1) and byte_size(encode(operations)) <= 12_288

    if valid, do: :ok, else: {:error, :invalid_ticket_command}
  end

  defp validate_stage(_attrs), do: {:error, :invalid_ticket_command}

  defp operation_valid?(%{"operation" => "answer_question", "question_key" => key, "value" => _} = op), do: map_size(op) == 3 and text?(key, 128)
  defp operation_valid?(%{"operation" => "request_rework"} = op), do: map_size(op) == 1
  defp operation_valid?(%{"operation" => "propose_contract_revision", "markdown" => markdown} = op), do: map_size(op) == 2 and text?(markdown, 10_240)
  defp operation_valid?(_op), do: false

  defp insert_stage(store, key, expected) do
    count = Store.one!(store, "SELECT COUNT(*) AS count FROM ticket_chat_commands WHERE chat_key = ? AND status = 'PENDING'", [hd(expected)])["count"]

    if count >= 8 do
      {:error, :pending_commands_limit}
    else
      Store.query!(
        store,
        "INSERT INTO ticket_chat_commands(command_key, chat_key, run_id, binding_json, body_sha256, payload_json, payload_sha256, proposal_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)",
        [key] ++ expected ++ [now(), now()]
      )

      get(store, key)
    end
  end

  defp extract(%{"id" => id, "cwd" => cwd, "turns" => turns} = native, chat) when is_list(turns) do
    if id == chat["thread_id"] and cwd == chat["cwd"] and Map.has_key?(native, "projectId") and
         native["projectId"] == nil and length(turns) <= 10_000 do
      readback_digest = digest(encode(native))

      with {:ok, inputs} <- collect_direct_inputs(turns, readback_digest, []),
           true <- length(inputs) <= 1000 or {:error, :native_input_read_budget_exceeded} do
        {:ok, Enum.sort_by(inputs, & &1["started_at"])}
      else
        {:error, _} = error -> error
      end
    else
      {:error, :native_input_route_mismatch}
    end
  end

  defp extract(_native, _chat), do: {:error, :native_input_history_invalid}

  defp collect_direct_inputs([], _digest, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_direct_inputs([turn | rest], digest, acc) do
    case direct_input(turn, digest) do
      {:ok, inputs} -> collect_direct_inputs(rest, digest, Enum.reverse(inputs, acc))
      {:error, _} = error -> error
    end
  end

  defp direct_input(
         %{"id" => turn_id, "status" => "completed", "startedAt" => started, "completedAt" => completed, "items" => items},
         readback_digest
       )
       when is_number(started) and is_number(completed) and completed >= started and is_list(items) do
    users = Enum.filter(items, &(is_map(&1) and &1["type"] == "userMessage"))

    if users == [] do
      {:ok, []}
    else
      collect_direct_user_inputs(users, turn_id, started, completed, items, readback_digest)
    end
  end

  defp direct_input(_turn, _digest), do: {:ok, []}

  defp collect_direct_user_inputs(users, turn_id, started, completed, items, readback_digest) do
    case Enum.reduce_while(users, {:ok, []}, fn user, {:ok, acc} ->
           direct_user_input_step(user, acc, turn_id, started, completed, items, readback_digest)
         end) do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp direct_user_input_step(user, acc, turn_id, started, completed, items, readback_digest) do
    case direct_user_input(user, turn_id, started, completed, items, readback_digest) do
      {:ok, input} -> {:cont, {:ok, [input | acc]}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp direct_user_input(%{"id" => item, "clientId" => client, "content" => content}, turn_id, started, completed, items, readback_digest) do
    direct_body(turn_id, item, client, content, {started, completed, items}, readback_digest)
  end

  defp direct_user_input(_user, _turn_id, _started, _completed, _items, _readback_digest), do: {:error, :native_input_history_invalid}

  defp direct_body(turn_id, item, client, content, {started, completed, items}, readback_digest) do
    valid = Enum.all?([turn_id, item, client], &text?(&1, 256)) and text_content?(content)
    body = if valid, do: Enum.map_join(content, & &1["text"]), else: ""

    if text?(body, 12_288) do
      {:ok,
       %{
         "turn_id" => turn_id,
         "item_id" => item,
         "client_id" => client,
         "body" => body,
         "body_sha256" => digest(body),
         "started_at" => started,
         "completed_at" => completed,
         "staging_receipts_json" => encode(staging_receipts(items)),
         "readback_sha256" => readback_digest
       }}
    else
      {:error, :native_input_history_invalid}
    end
  end

  defp unique_native_identities(inputs) do
    item_ids = Enum.map(inputs, & &1["item_id"])
    client_ids = Enum.map(inputs, & &1["client_id"])

    if length(item_ids) == length(Enum.uniq(item_ids)) and length(client_ids) == length(Enum.uniq(client_ids)),
      do: :ok,
      else: {:error, :duplicate_native_input_identity}
  end

  defp unique_staged_interpretations(_store, _chat, _run, []), do: :ok

  defp unique_staged_interpretations(store, chat, run, inputs) do
    pending =
      rows(store, "SELECT * FROM ticket_chat_commands WHERE chat_key = ? AND run_id = ? AND status = 'PENDING' ORDER BY created_at, command_key LIMIT 9", [
        chat["chat_key"],
        run["run_id"]
      ])

    matches =
      Enum.flat_map(inputs, fn input ->
        Enum.filter(pending, &(staged_in_turn?(&1, input) and native_body_matches?(&1, input)))
        |> Enum.map(& &1["command_key"])
      end)

    if length(matches) == length(Enum.uniq(matches)), do: :ok, else: {:error, :ambiguous_staged_interpretations}
  end

  defp text_content?(content) when is_list(content) and content != [], do: Enum.all?(content, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1))
  defp text_content?(_content), do: false

  defp staging_receipts(items) do
    Enum.reduce(items, %{}, fn item, receipts ->
      case staging_receipt(item) do
        {:ok, key, receipt} -> Map.put(receipts, key, receipt)
        :none -> receipts
      end
    end)
  end

  defp staging_receipt(%{"type" => "commandExecution", "status" => "completed", "exitCode" => 0, "command" => command, "aggregatedOutput" => output}) when is_binary(command) and is_binary(output) do
    with {:ok, run_id, attrs} <- staging_invocation(command),
         {:ok, %{"command_key" => key, "payload_sha256" => sha, "status" => "PENDING"}} <- Jason.decode(output),
         true <- text?(key, 128) and text?(sha, 64) do
      {:ok, key, %{"payload_sha256" => sha, "run_id" => run_id, "attrs" => attrs}}
    else
      _ -> :none
    end
  end

  defp staging_receipt(_item), do: :none

  @doc false
  @spec staging_invocation(String.t()) :: {:ok, String.t(), map()} | :none
  def staging_invocation(command) do
    case shell_words(command) do
      {:ok, ["/bin/zsh", "-lc", script]} ->
        wrapped_staging_invocation(script, command)

      {:ok, arguments} ->
        if Regex.match?(~r/[$`;|&<>#\n\r]/, command), do: :none, else: arguments |> unwrap_shell() |> staging_arguments()

      :error ->
        :none
    end
  rescue
    _error in [ArgumentError, RuntimeError] -> :none
  end

  defp wrapped_staging_invocation(script, original_command) do
    case String.split(script, "\n") do
      [single_command] ->
        single_staging_invocation(single_command)

      [assignment, consumer] ->
        wrapped_staging_assignment(assignment, consumer, original_command)

      _ ->
        :none
    end
  end

  defp single_staging_invocation(command) do
    if Regex.match?(~r/[$\x60;|&<>#\n\r]/, command),
      do: :none,
      else: with({:ok, arguments} <- shell_words(command), do: staging_arguments(arguments))
  end

  defp wrapped_staging_assignment(assignment, consumer, original_command) do
    with {:ok, bytes, attrs} <- payload_assignment(assignment),
         {:ok, arguments} <- shell_words(consumer),
         {:ok, run_id, workflow} <- wrapped_staging_arguments(arguments, Base.encode64(bytes)),
         true <- bytes == canonical_stage_json(attrs),
         true <- original_command == render_python_stage_command(run_id, workflow, bytes) do
      {:ok, run_id, attrs}
    else
      _ -> :none
    end
  end

  defp payload_assignment(assignment) do
    prefix = "ticket_payload_b64=$(python3 -c "

    if String.starts_with?(assignment, prefix) and String.ends_with?(assignment, ")") do
      python_source = binary_part(assignment, byte_size(prefix), byte_size(assignment) - byte_size(prefix) - 1)

      with {:ok, [python_source]} <- shell_words(python_source),
           {:ok, bytes} <- python_payload(python_source),
           true <- byte_size(bytes) <= 24_576,
           {:ok, attrs} <- Jason.decode(bytes),
           :ok <- validate_stage(attrs) do
        {:ok, bytes, attrs}
      else
        _ -> :error
      end
    else
      :error
    end
  end

  defp python_payload(source) do
    prefix = "import base64; print(base64.b64encode(b\""
    suffix = "\").decode())"

    if String.starts_with?(source, prefix) and String.ends_with?(source, suffix) do
      literal = binary_part(source, byte_size(prefix), byte_size(source) - byte_size(prefix) - byte_size(suffix))
      decode_python_bytes(literal)
    else
      :error
    end
  end

  defp decode_python_bytes(literal), do: decode_python_bytes(literal, [])
  defp decode_python_bytes(<<>>, bytes), do: {:ok, bytes |> Enum.reverse() |> IO.iodata_to_binary()}
  defp decode_python_bytes(<<?\\, ?\\, ?\", rest::binary>>, bytes), do: decode_python_bytes(rest, [<<?\">> | bytes])

  defp decode_python_bytes(<<char, rest::binary>>, bytes)
       when char in 0x20..0x7E and char not in [?\", ?\\, ?$, 96, ?', ?;, ?|, ?&, ?<, ?>, ?#, ?(, ?)] do
    decode_python_bytes(rest, [<<char>> | bytes])
  end

  defp decode_python_bytes(_literal, _bytes), do: :error

  defp wrapped_staging_arguments(["mise", "exec", "--", "mix", "factory.ticket", "stage", run_id, "--payload-base64", "$ticket_payload_b64", "--workflow", workflow], encoded) do
    with true <- safe_shell_literal?(run_id),
         true <- safe_shell_literal?(workflow) and Path.type(workflow) == :absolute,
         {:ok, ^run_id, _attrs} <- staging_arguments(["mix", "factory.ticket", "stage", run_id, "--payload-base64", encoded, "--workflow", workflow]),
         do: {:ok, run_id, workflow}
  end

  defp wrapped_staging_arguments(_arguments, _encoded), do: :none

  defp safe_shell_literal?(value) when is_binary(value), do: Regex.match?(~r{\A[A-Za-z0-9_./-]+\z}, value)

  defp canonical_stage_json(attrs) do
    "{\"proposal_id\":" <>
      Jason.encode!(attrs["proposal_id"]) <>
      ",\"body\":" <>
      Jason.encode!(attrs["body"]) <>
      ",\"operations\":" <>
      Jason.encode!(attrs["operations"]) <>
      ",\"generation\":" <>
      Integer.to_string(attrs["generation"]) <>
      ",\"spec_revision\":" <>
      Integer.to_string(attrs["spec_revision"]) <>
      ",\"contract_sha256\":" <>
      Jason.encode!(attrs["contract_sha256"]) <>
      ",\"candidate_sha\":" <> Jason.encode!(attrs["candidate_sha"]) <> "}"
  end

  defp render_python_stage_command(run_id, workflow, bytes) do
    escaped_json =
      bytes
      |> :binary.bin_to_list()
      |> Enum.map(fn
        ?\" -> <<?\\, ?\\, ?\\, ?\">>
        byte -> <<byte>>
      end)
      |> IO.iodata_to_binary()

    ~S|/bin/zsh -lc 'ticket_payload_b64=$(python3 -c '"'import base64; print(base64.b64encode(b\"| <>
      escaped_json <>
      ~S|\").decode())')| <>
      "\nmise exec -- mix factory.ticket stage #{run_id} --payload-base64 \\\"\"'$ticket_payload_b64\" --workflow #{workflow}'"
  end

  defp shell_words(command) when is_binary(command) do
    {:ok, OptionParser.split(command)}
  rescue
    _error in [ArgumentError, RuntimeError] -> :error
  end

  defp unwrap_shell([shell, "-lc", command]) when shell in ~w(/bin/zsh /bin/bash zsh bash),
    do: OptionParser.split(command)

  defp unwrap_shell(arguments), do: arguments
  defp staging_arguments(["mise", "exec", "--", "./scripts/factory-broker" | _arguments]), do: :none
  defp staging_arguments(["mise", "exec", "--" | arguments]), do: staging_arguments(arguments)

  defp staging_arguments(["elixir", "-pa", "_build/dev/lib/*/ebin", "-S", "./scripts/factory-broker" | _arguments]), do: :none
  defp staging_arguments(["elixir", "-pa", "_build/dev/lib/*/ebin", "-S" | arguments]), do: staging_arguments(arguments)

  defp staging_arguments(["./scripts/factory-broker", "ticket", "stage", run_id, "--payload-base64", payload, "--workflow", workflow]),
    do: staging_arguments(["mix", "factory.ticket", "stage", run_id, "--payload-base64", payload, "--workflow", workflow])

  defp staging_arguments(["mix", "factory.ticket", "stage", run_id | arguments]) do
    {opts, rest, invalid} = OptionParser.parse(arguments, strict: [workflow: :string, payload_base64: :string])

    with true <- rest == [] and invalid == [] and Enum.sort(Keyword.keys(opts)) == [:payload_base64, :workflow],
         true <- Path.type(opts[:workflow]) == :absolute and byte_size(opts[:payload_base64]) <= 32_768,
         {:ok, json} <- Base.decode64(opts[:payload_base64]),
         {:ok, attrs} <- Jason.decode(json),
         :ok <- validate_stage(attrs) do
      {:ok, run_id, attrs}
    else
      _ -> :none
    end
  end

  defp staging_arguments(_arguments), do: :none

  defp consume(store, chat, run, input) do
    key = "TIN-" <> digest(encode([chat["chat_key"], chat["generation"], input["turn_id"], input["item_id"]]))

    previous =
      rows(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ? OR (chat_key = ? AND generation = ? AND client_id = ?)", [key, chat["chat_key"], chat["generation"], input["client_id"]])

    old = List.first(previous)

    fields = ~w(turn_id item_id client_id body_sha256 started_at completed_at staging_receipts_json)

    cond do
      length(previous) > 1 or (old != nil and (old["input_key"] != key or Map.take(old, fields) != Map.take(input, fields))) ->
        {:error, :native_input_changed}

      old != nil ->
        admit_matching(store, chat, run, key, input)

      true ->
        Store.query!(
          store,
          "INSERT INTO ticket_chat_inputs(input_key, chat_key, generation, thread_id, turn_id, item_id, client_id, body, body_sha256, started_at, completed_at, staging_receipts_json, readback_sha256, origin, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'NATIVE_CLIENT_INPUT', ?)",
          [
            key,
            chat["chat_key"],
            chat["generation"],
            chat["thread_id"],
            input["turn_id"],
            input["item_id"],
            input["client_id"],
            input["body"],
            input["body_sha256"],
            input["started_at"],
            input["completed_at"],
            input["staging_receipts_json"],
            input["readback_sha256"],
            now()
          ]
        )

        admit_matching(store, chat, run, key, input)
    end
  end

  defp admit_matching(store, chat, run, input_key, input) do
    consumed = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE input_key = ?", [input_key])

    pending =
      rows(store, "SELECT * FROM ticket_chat_commands WHERE chat_key = ? AND run_id = ? AND status = 'PENDING' ORDER BY created_at, command_key LIMIT 9", [
        chat["chat_key"],
        run["run_id"]
      ])

    pending = Enum.filter(pending, &(staged_in_turn?(&1, input) and native_body_matches?(&1, input)))

    cond do
      consumed != nil -> {:ok, consumed}
      pending == [] -> {:ok, %{input_key: input_key, status: "OBSERVED", worker_started: false}}
      length(pending) > 1 -> {:error, :ambiguous_staged_interpretations}
      true -> decide(store, chat, run, hd(pending), input_key, input)
    end
  end

  defp staged_in_turn?(command, input) do
    {:ok, created_at, _offset} = DateTime.from_iso8601(command["created_at"])
    staged_at = DateTime.to_unix(created_at, :microsecond) / 1_000_000
    receipt = Jason.decode!(input["staging_receipts_json"])[command["command_key"]]

    matching_staging_receipt?(command, receipt) and staged_at >= input["started_at"] and
      staged_at < input["completed_at"] + 1
  end

  defp matching_staging_receipt?(command, %{"attrs" => attrs, "run_id" => run_id, "payload_sha256" => sha}) do
    expected = {command["run_id"], command["payload_sha256"], command["proposal_id"], command["body_sha256"], command["binding_json"]}
    actual = {run_id, sha, attrs["proposal_id"], digest(attrs["body"]), encode(Map.take(attrs, @binding))}
    expected == actual and original_operations_match?(command, attrs)
  end

  defp matching_staging_receipt?(_command, _receipt), do: false

  defp formatted_staged_answer_body(command, input, receipt \\ nil) do
    receipt = receipt || staging_receipt_for(input, command)

    with true <- single_answer_command?(command),
         true <- digest(input["body"] || "") == input["body_sha256"],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, input["readback_sha256"] || ""),
         {:ok, body} <- single_answer_code_span(input["body"]),
         %{"attrs" => attrs} when is_map(attrs) <- receipt,
         true <- attrs["body"] == body,
         true <- matching_staging_receipt?(command, receipt),
         true <- command_created_during_input?(command, input) do
      {:ok, body}
    else
      _ -> :error
    end
  end

  defp single_answer_command?(command) do
    digest(command["payload_json"] || "") == command["payload_sha256"] and
      case Jason.decode(command["payload_json"] || "") do
        {:ok, [operation]} -> answer_operation?(operation)
        _ -> false
      end
  end

  defp single_answer_code_span(raw) when is_binary(raw) do
    formatted = String.trim(raw)

    candidate =
      if byte_size(formatted) >= 2 and String.starts_with?(formatted, "`") and String.ends_with?(formatted, "`") do
        body = binary_part(formatted, 1, byte_size(formatted) - 2)
        body
      else
        formatted
      end

    if Regex.match?(~r/\AAnswer [A-Za-z0-9:._-]+: [^\r\n`]+\z/i, candidate), do: {:ok, candidate}, else: :error
  end

  defp single_answer_code_span(_raw), do: :error

  defp original_operations_match?(command, attrs) do
    case digest(command["payload_json"]) == command["payload_sha256"] do
      true -> original_operations_match_json(command["payload_json"], attrs["operations"])
      false -> true
    end
  end

  defp original_operations_match_json(payload_json, supplied_operations) do
    case Jason.decode(payload_json) do
      {:ok, original} when is_list(original) ->
        original = Enum.map(original, &if(is_map(&1), do: Map.delete(&1, "question_digest"), else: &1))
        encode(original) == encode(supplied_operations)

      _ ->
        false
    end
  end

  defp decide(store, chat, run, command, input_key, input) do
    result =
      with :ok <- current_command(chat, run, command),
           {:ok, operations} <- parse(store, chat, run, input, command),
           true <- encode(operations) == command["payload_json"] or {:error, :native_intent_mismatch} do
        {:ok, operations}
      end

    case result do
      {:ok, _operations} ->
        receipt = %{status: "ACCEPTED", worker_started: false, external_changes_applied: false, input_key: input_key}
        persist_decision(store, command, input_key, receipt)

      {:error, reason} ->
        receipt = %{status: "REJECTED", reason: to_string(reason), worker_started: false, input_key: input_key}
        persist_decision(store, command, input_key, receipt)
    end
  end

  defp current_command(chat, run, command) do
    cond do
      digest(command["payload_json"]) != command["payload_sha256"] -> {:error, :command_payload_corrupt}
      command["binding_json"] != encode(binding(chat, run)) -> {:error, :stale_command_binding}
      true -> :ok
    end
  end

  defp parse(store, chat, run, input, command) do
    body =
      case formatted_staged_answer_body(command, input) do
        {:ok, staged_body} -> staged_body
        :error -> input["body"]
      end

    parsed_input = Map.put(input, "body", body)

    separator = "--- FACTORY CONTRACT REVISION ---\n"

    cond do
      String.starts_with?(body, "Revise the contract:\n") ->
        parse_legacy_revision(body)

      mixed_contract_separator?(body, separator) ->
        parse_answer_contract_revision(store, chat, run, parsed_input, separator)

      true ->
        parse_authorized_answer(store, chat, run, parsed_input, body)
    end
  end

  defp parse_legacy_revision(body) do
    with :ok <- authorization_prefix_valid?(body) do
      markdown = String.replace_prefix(body, "Revise the contract:\n", "")

      if text?(markdown, 10_240),
        do: {:ok, [%{"operation" => "propose_contract_revision", "markdown" => markdown}]},
        else: {:error, :invalid_contract_revision}
    end
  end

  defp parse_authorized_answer(store, chat, run, input, body) do
    with :ok <- authorization_prefix_valid?(body),
         do: parse_answer_or_rework(store, chat, run, input, body)
  end

  defp parse_answer_or_rework(store, chat, run, input, body) do
    case rework_body?(body) do
      true -> {:ok, [%{"operation" => "request_rework"}]}
      false -> parse_answers(store, chat, run, input)
    end
  end

  defp authorization_prefix_valid?(text) do
    cond do
      Regex.match?(~r/(?:\A|\n)(?: {4}|\t)/, text) -> {:error, :quoted_code_not_authorization}
      Regex.match?(~r/[\x00-\x08\x0B-\x1F\x7F\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u, text) -> {:error, :unsupported_control_characters}
      true -> :ok
    end
  end

  defp mixed_contract_separator?(body, separator) do
    case :binary.match(body, separator) do
      {index, _length} when index > 0 -> binary_part(body, index - 1, 1) == "\n"
      :nomatch -> false
      _ -> false
    end
  end

  defp parse_answer_contract_revision(store, chat, run, input, separator) do
    [preamble, markdown] = String.split(input["body"], separator, parts: 2)
    answer_lines = String.split(String.replace_suffix(preamble, "\n", ""), "\n")
    answer_lines = if List.last(answer_lines) == "", do: Enum.drop(answer_lines, -1), else: answer_lines

    with :ok <- authorization_prefix_valid?(preamble),
         true <- length(answer_lines) in 1..3,
         true <- Enum.all?(answer_lines, &(String.trim(&1) != "")) or {:error, :invalid_mixed_contract_revision},
         true <- (text?(markdown, 10_240) and String.trim(markdown) != "") or {:error, :invalid_contract_revision},
         {:ok, answers} <- parse_answer_lines(store, chat, run, input, answer_lines),
         keys <- Enum.map(answers, & &1["question_key"]),
         true <- length(keys) == length(Enum.uniq(keys)) or {:error, :duplicate_or_excessive_actions} do
      {:ok, answers ++ [%{"operation" => "propose_contract_revision", "markdown" => markdown}]}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_mixed_contract_revision}
    end
  end

  defp parse_answer_lines(store, chat, run, input, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, operations} ->
      case parse_answer(store, chat, run, input, line) do
        {:ok, answer} -> {:cont, {:ok, operations ++ [answer]}}
        error -> {:halt, error}
      end
    end)
  end

  defp amendment_operations?(operations) when is_list(operations) and length(operations) in 1..4 do
    case List.last(operations) do
      %{"operation" => "propose_contract_revision", "markdown" => markdown} = proposal ->
        map_size(proposal) == 2 and text?(markdown, 10_240) and
          Enum.all?(Enum.drop(operations, -1), &answer_operation?/1) and
          length(Enum.map(Enum.drop(operations, -1), & &1["question_key"])) ==
            length(Enum.uniq(Enum.map(Enum.drop(operations, -1), & &1["question_key"])))

      _ ->
        false
    end
  end

  defp amendment_operations?(_operations), do: false

  @doc false
  @spec apply_amendment_answers(Store.connection(), map()) :: {:ok, map() | nil} | {:error, term()}
  def apply_amendment_answers(_store, %{answer_questions: []}), do: {:ok, nil}

  def apply_amendment_answers(store, validated) do
    questions = validated.answer_questions
    operations = validated.command["payload_json"] |> Jason.decode!() |> Enum.drop(-1)

    with :ok <- apply_amendment_answer_rows(store, operations, questions, validated.input) do
      {:ok,
       %{
         "question_keys" => Enum.map(questions, & &1["question_key"]),
         "input_key" => validated.input["input_key"],
         "original_questions" => questions,
         "answer_proof_sha256" => answer_proof(questions, validated.input)
       }}
    end
  end

  defp apply_amendment_answer_rows(store, operations, questions, input) do
    Enum.zip(operations, questions)
    |> Enum.each(&apply_amendment_answer_row(store, &1, input))

    :ok
  end

  defp apply_amendment_answer_row(store, {operation, question}, input) do
    Store.query!(
      store,
      "UPDATE ticket_chat_questions SET status = 'ANSWERED', answer_json = ?, input_key = ? WHERE question_key = ? AND status = 'OPEN' AND chat_key = ? AND run_id = ? AND binding_json = ? AND body = ? AND answers_json = ? AND opened_at = ?",
      [
        encode(operation["value"]),
        input["input_key"],
        question["question_key"],
        question["chat_key"],
        question["run_id"],
        question["binding_json"],
        question["body"],
        question["answers_json"],
        question["opened_at"]
      ]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] != 1,
      do: Exqlite.rollback(store, :stale_question)
  end

  @doc false
  @spec validate_amendment_answer_replay(Store.connection(), map(), term()) :: :ok | {:error, term()}
  def validate_amendment_answer_replay(store, command, proof) do
    with {:ok, operations} <- Jason.decode(command["payload_json"] || "null"),
         true <- amendment_operations?(operations) or {:error, :amendment_answer_replay_unproven},
         answers <- Enum.drop(operations, -1),
         :ok <- validate_amendment_answer_history(store, command, proof, answers) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_amendment_answer_history(_store, _command, nil, []), do: :ok

  defp validate_amendment_answer_history(store, command, proof, operations) when is_map(proof) and operations != [] do
    with keys <- Enum.map(operations, & &1["question_key"]),
         true <- proof["question_keys"] == keys,
         true <- proof["input_key"] == command["input_key"],
         originals when is_list(originals) <- proof["original_questions"],
         true <- Enum.map(originals, & &1["question_key"]) == keys,
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
         true <- proof["answer_proof_sha256"] == answer_proof(originals, input),
         true <- digest(command["payload_json"]) == command["payload_sha256"],
         true <- input["body_sha256"] == command["body_sha256"] and digest(input["body"] || "") == command["body_sha256"],
         true <- historical_staging_matches?(command, input),
         true <- Enum.zip(originals, operations) |> Enum.all?(fn {original, operation} -> amendment_answer_row_matches?(store, command, input, original, operation) end) do
      :ok
    else
      _ -> {:error, :amendment_answer_replay_unproven}
    end
  end

  defp validate_amendment_answer_history(_store, _command, _proof, _operations),
    do: {:error, :amendment_answer_replay_unproven}

  defp amendment_answer_row_matches?(store, command, input, original, operation) do
    current = question(store, original["question_key"])

    original_question_matches?(original, command, input, operation) and
      answered_question_matches?(current, original, input, operation)
  end

  defp original_question_matches?(original, command, input, operation),
    do:
      original["status"] == "OPEN" and original["chat_key"] == command["chat_key"] and
        original["run_id"] == command["run_id"] and original["binding_json"] == command["binding_json"] and
        original["opened_at"] <= input["started_at"] and operation["question_digest"] == question_digest(original)

  defp answered_question_matches?(current, original, input, operation) when is_map(current),
    do:
      current["status"] == "ANSWERED" and current["answer_json"] == encode(operation["value"]) and
        current["input_key"] == input["input_key"] and
        Enum.all?(~w(question_key chat_key run_id binding_json body answers_json opened_at), &(current[&1] == original[&1])) and
        answer_matches_schema?(original["answers_json"], operation["value"])

  defp answered_question_matches?(_current, _original, _input, _operation), do: false

  defp parse_answers(store, chat, run, input) do
    lines = String.split(input["body"], "\n")

    Enum.reduce_while(lines, {:ok, []}, &parse_line(store, chat, run, input, &1, &2))
    |> case do
      {:ok, operations} ->
        keys = Enum.map(operations, & &1["question_key"])
        if length(operations) <= 4 and length(Enum.uniq(keys)) == length(keys), do: {:ok, operations}, else: {:error, :duplicate_or_excessive_actions}

      error ->
        error
    end
  end

  defp parse_line(store, chat, run, input, line, {:ok, operations}) do
    if normalize(line) == "rework: current candidate" and operations != [] do
      {:cont, {:ok, operations ++ [%{"operation" => "request_rework"}]}}
    else
      case parse_answer(store, chat, run, input, line) do
        {:ok, answer} -> {:cont, {:ok, operations ++ [answer]}}
        error -> {:halt, error}
      end
    end
  end

  defp parse_answer(store, chat, run, input, line) do
    {question_key, phrase} =
      case Regex.run(~r/\AAnswer ([A-Za-z0-9:._-]+): (.+)\z/i, line) do
        [_, key, phrase] -> {key, phrase}
        _ -> {nil, line}
      end

    questions = rows(store, "SELECT * FROM ticket_chat_questions WHERE chat_key = ? AND run_id = ? AND status = 'OPEN' LIMIT 17", [chat["chat_key"], run["run_id"]])
    eligible = Enum.filter(questions, &eligible_question?(&1, question_key, binding(chat, run), input))

    case eligible do
      [question] ->
        parse_question_value(question, phrase)

      [] ->
        {:error, :no_current_question}

      _ ->
        {:error, :ambiguous_question}
    end
  end

  defp parse_question_value(question, phrase) do
    with {:ok, answers} <- Jason.decode(question["answers_json"]),
         true <- answers_valid?(answers) do
      case answer_value(answers, phrase) do
        {:ok, answer} -> {:ok, %{"operation" => "answer_question", "question_key" => question["question_key"], "value" => answer, "question_digest" => question_digest(question)}}
        :error -> {:error, :unsupported_answer_phrase}
      end
    else
      _ -> {:error, :question_schema_invalid}
    end
  end

  defp answer_value(%{"type" => "text", "max_bytes" => limit}, phrase) do
    if text?(phrase, limit), do: {:ok, phrase}, else: :error
  end

  defp answer_value(%{"type" => "integer", "min" => low, "max" => high}, phrase) do
    case Integer.parse(normalize(phrase)) do
      {value, ""} when value >= low and value <= high -> {:ok, value}
      _ -> :error
    end
  end

  defp answer_value(answers, phrase), do: Map.fetch(answers, normalize(phrase))

  defp eligible_question?(question, key, binding, input),
    do:
      question["binding_json"] == encode(binding) and input["started_at"] >= question["opened_at"] and
        (key == nil or question["question_key"] == key)

  defp persist_decision(store, command, input_key, receipt) do
    Store.query!(store, "UPDATE ticket_chat_commands SET status = ?, input_key = ?, receipt_json = ?, updated_at = ? WHERE command_key = ? AND status = 'PENDING'", [
      receipt.status,
      input_key,
      encode(receipt),
      now(),
      command["command_key"]
    ])

    persist_event(store, command, receipt.status, receipt, "receipt_json")

    get(store, command["command_key"])
  end

  defp persist_event(store, command, status, receipt, receipt_field) do
    Store.query!(store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES (?, ?, ?, ?)", [
      "TICKET_COMMAND_#{status}",
      command["run_id"],
      encode(Map.merge(%{command_key: command["command_key"], input_key: command["input_key"]}, %{receipt_field => receipt})),
      now()
    ])
  end

  defp binding(chat, run), do: Map.take(run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", chat["generation"])
  defp question(store, key), do: Store.one!(store, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [key])
  defp normalize(text), do: text |> String.trim() |> String.downcase(:ascii) |> String.replace(~r/[.!]\z/, "")
  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
  defp encode(value), do: value |> Jason.encode!()
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp rows(store, sql, params) do
    %{columns: columns, rows: rows} = Store.query!(store, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp atomic(store, fun) do
    case Exqlite.transaction(store, &rollback_error(&1, fun.(&1))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(transaction, {:error, reason}), do: Exqlite.rollback(transaction, reason)
  defp rollback_error(_transaction, result), do: result
end
