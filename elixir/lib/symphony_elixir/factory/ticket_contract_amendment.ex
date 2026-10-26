defmodule SymphonyElixir.Factory.TicketContractAmendment do
  @moduledoc "Immutable reservation of one accepted native ticket-contract proposal."

  alias Exqlite
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{Contract, ModelRouter, Prompt, RunLedger, StageSchemas, Store, TaskLedger}
  alias SymphonyElixir.Factory.SpecialistErrorNotice
  alias SymphonyElixir.Factory.{TicketAmendmentJiraOperation, TicketChatCommands, TicketMrOperation}
  alias SymphonyElixir.Factory.{WorkerEvidence, WorkspaceAccess}
  alias SymphonyElixir.PathSafety

  @immutable_fields ~w(command_key run_id chat_key generation prior_binding_json prior_revision prior_contract_markdown prior_contract_sha256 proposed_revision proposed_contract_markdown proposed_contract_sha256 candidate_sha input_key input_sha256 readback_sha256 admission_sha256 payload_sha256 predecessor_json supersession_json)
  @critic_binding_fields ~w(command_key run_id task_key chat_key generation input_key input_sha256 draft_comment_id prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256 prompt_sha256 schema_sha256 snapshot_sha256 route_sha256)

  @spec reserve(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def reserve(store, command_key, controller_context) do
    transaction(store, fn tx ->
      with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(tx, command_key) do
        reserve_transaction(tx, validated, controller_context)
      end
    end)
  end

  @spec get(Store.connection(), String.t()) ::
          {:ok, map()} | {:error, :unknown_contract_amendment | :invalid_contract_amendment}
  def get(store, command_key) do
    case Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_key]) do
      nil ->
        {:error, :unknown_contract_amendment}

      amendment ->
        if valid_record?(store, amendment) and valid_descendant_history?(store, amendment),
          do: {:ok, amendment},
          else: {:error, :invalid_contract_amendment}
    end
  end

  @spec correction_revision(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def correction_revision(store, run, predecessor_key) do
    with {:ok, amendment} <- get(store, predecessor_key),
         true <-
           (amendment["run_id"] == run["run_id"] and active_reserved?(amendment)) or
             {:error, :amendment_correction_owner_invalid},
         {:ok, validated} <- TicketChatCommands.validate_contract_amendment(store, predecessor_key),
         :ok <- current_rows_match(store, validated),
         {:ok, draft} <- TicketAmendmentJiraOperation.readback(store, predecessor_key),
         attempt when is_map(attempt) <- Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [predecessor_key]),
         true <- attempt["phase"] == "RESULT_RECORDED" or {:error, :critic_result_not_recorded},
         :ok <- validate_critic_attempt(store, attempt, validated, amendment),
         {:ok, result} <- Jason.decode(attempt["result_json"]),
         output when is_map(output) <- result["output"],
         true <- (output["status"] in ~w(BLOCK REPAIR) and result["qualifies"] == false) or {:error, :critic_not_correctable},
         nil <- Store.one!(store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [predecessor_key]),
         {:ok, snapshot} <- Jason.decode(draft["readback_json"]) do
      {:ok,
       %{
         predecessor_command_key: predecessor_key,
         revision: Contract.next_revision(snapshot),
         input_key: amendment["input_key"],
         input_sha256: amendment["input_sha256"],
         payload_sha256: amendment["payload_sha256"],
         proposed_contract_sha256: amendment["proposed_contract_sha256"],
         draft_comment_id: draft["comment_id"],
         draft_body_sha256: draft["draft_body_sha256"],
         draft_effect_sha256: digest(Jason.encode!(draft)),
         draft_readback_json: draft["readback_json"],
         draft_readback_sha256: draft["readback_sha256"],
         critic_task_key: attempt["task_key"],
         critic_attempt_sha256: digest(Jason.encode!(attempt)),
         critic_result_json: attempt["result_json"],
         critic_result_sha256: attempt["result_sha256"]
       }}
    else
      authorization_effect when is_map(authorization_effect) -> {:error, :amendment_authorization_effect_exists}
      {:error, _} = error -> error
      _ -> {:error, :amendment_correction_not_proven}
    end
  rescue
    _ -> {:error, :amendment_correction_not_proven}
  end

  defp valid_descendant_history?(store, amendment) do
    case amendment["phase"] do
      "RESERVED" ->
        valid_successor_supersession?(store, amendment)

      "APPLIED" ->
        with receipt when is_map(receipt) <- decode_object(amendment["receipt_json"]),
             children <- amendment_child_candidates(store, amendment),
             true <- length(children) <= 1,
             true <- Enum.all?(children, &valid_amendment_child_link?(store, amendment, receipt, &1)),
             true <- Enum.all?(children, &valid_descendant_history?(store, &1)) do
          true
        else
          _ -> false
        end

      "SUPERSEDED" ->
        with link when is_map(link) <- Store.one!(store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [amendment["command_key"]]),
             {:ok, successor} <- canonical_get(store, link["successor_command_key"]),
             true <- valid_supersession_link?(store, amendment, successor, link),
             true <- valid_descendant_history?(store, successor) do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @spec apply_authorized(Store.connection(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_authorized(store, command_key, controller_context, model_policy) do
    case get(store, command_key) do
      {:ok, %{"phase" => "APPLIED"} = amendment} -> replay_applied_amendment(store, amendment, controller_context)
      {:ok, %{"phase" => "RESERVED"}} -> apply_reserved_amendment(store, command_key, controller_context, model_policy)
      {:error, _} = error -> error
      _ -> {:error, :invalid_contract_amendment}
    end
  end

  @spec blocked_predecessor_for_request(Store.connection(), String.t()) ::
          {:ok, map()} | {:error, :blocked_amendment_predecessor_not_found}
  def blocked_predecessor_for_request(store, request_key) do
    rows =
      Store.query!(store, "SELECT command_key FROM ticket_contract_amendments WHERE phase = 'APPLIED' ORDER BY updated_at DESC", []).rows
      |> List.flatten()

    case Enum.find_value(rows, &blocked_receipt_for_request(store, &1, request_key)) do
      receipt when is_map(receipt) -> {:ok, receipt}
      nil -> {:error, :blocked_amendment_predecessor_not_found}
    end
  end

  @spec blocked_predecessor_for_installed_run(Store.connection(), map()) ::
          {:ok, map()} | {:error, :blocked_amendment_predecessor_not_found}
  def blocked_predecessor_for_installed_run(store, run) do
    rows = Store.query!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase = 'APPLIED'", [run["run_id"]]).rows |> List.flatten()

    case Enum.find_value(rows, &blocked_receipt_for_installed_run(store, &1, run)) do
      %{receipt: receipt, amendment: amendment} -> {:ok, %{receipt: receipt, amendment: amendment}}
      nil -> {:error, :blocked_amendment_predecessor_not_found}
    end
  end

  @spec blocked_source_preimage(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def blocked_source_preimage(store, command_key) do
    with {:ok, amendment} <- get(store, command_key),
         receipt when is_map(receipt) <- decode_object(amendment["receipt_json"]),
         true <- receipt["application_kind"] == "BLOCKED_WRITER_HELD",
         prior_run when is_map(prior_run) <- decode_object(receipt["prior_run_json"]),
         {:ok, source_run} <- amendment_source_preimage(store, amendment, prior_run, receipt) do
      {:ok, source_run}
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_amendment_ancestry_invalid}
    end
  end

  defp amendment_source_preimage(store, amendment, prior_run, receipt) do
    with predecessor when is_map(predecessor) <- decode_object(receipt["blocked_predecessor_json"]),
         evidence when is_map(evidence) <- decode_object(predecessor["evidence_json"]),
         binding when is_map(binding) <- decode_object(evidence["binding_json"]) do
      if binding["spec_revision"] == prior_run["spec_revision"] and binding["contract_sha256"] == prior_run["contract_sha256"] do
        {:ok, prior_run}
      else
        parent_source_preimage(store, amendment, prior_run, receipt)
      end
    else
      _ -> {:error, :blocked_amendment_ancestry_invalid}
    end
  end

  defp parent_source_preimage(store, amendment, prior_run, receipt) do
    parents =
      Store.query!(
        store,
        "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase = 'APPLIED' AND proposed_revision = ? AND command_key != ?",
        [amendment["run_id"], amendment["prior_revision"], amendment["command_key"]]
      ).rows
      |> List.flatten()

    case parents do
      [parent_key] ->
        with {:ok, parent} <- canonical_get(store, parent_key),
             true <- parent["proposed_contract_sha256"] == amendment["prior_contract_sha256"],
             true <- parent["proposed_contract_markdown"] == amendment["prior_contract_markdown"],
             true <- Map.take(parent, ~w(run_id chat_key generation candidate_sha)) == Map.take(amendment, ~w(run_id chat_key generation candidate_sha)),
             parent_receipt when is_map(parent_receipt) <- decode_object(parent["receipt_json"]),
             true <- parent_receipt["application_kind"] == "BLOCKED_WRITER_HELD",
             true <- parent_receipt["blocked_predecessor_json"] == receipt["blocked_predecessor_json"],
             source_run when is_map(source_run) <- decode_object(parent_receipt["prior_run_json"]),
             true <- source_run["spec_revision"] < prior_run["spec_revision"] do
          amendment_source_preimage(store, parent, source_run, parent_receipt)
        else
          _ -> {:error, :blocked_amendment_ancestry_invalid}
        end

      _ ->
        {:error, :blocked_amendment_ancestry_invalid}
    end
  end

  defp canonical_get(store, command_key) do
    case Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_key]) do
      amendment when is_map(amendment) ->
        if valid_record?(store, amendment), do: {:ok, amendment}, else: {:error, :invalid_contract_amendment}

      _ ->
        {:error, :unknown_contract_amendment}
    end
  end

  defp blocked_receipt_for_installed_run(store, command_key, run) do
    with {:ok, amendment} <- get(store, command_key),
         true <- run["state"] == "WRITING",
         true <- amendment["proposed_revision"] == amendment["prior_revision"] + 1,
         true <- amendment["proposed_revision"] == run["spec_revision"] and amendment["proposed_contract_sha256"] == run["contract_sha256"],
         true <- amendment["proposed_contract_markdown"] == run["contract_markdown"],
         true <- amendment["candidate_sha"] == run["candidate_sha"],
         receipt when is_map(receipt) <- decode_object(amendment["receipt_json"]),
         true <- receipt["application_kind"] == "BLOCKED_WRITER_HELD",
         predecessor when is_map(predecessor) <- decode_object(receipt["blocked_predecessor_json"]),
         evidence when is_map(evidence) <- decode_object(predecessor["evidence_json"]),
         true <- evidence["run_id"] == run["run_id"] do
      %{receipt: receipt, amendment: amendment}
    else
      _ -> nil
    end
  end

  defp blocked_receipt_for_request(store, command_key, request_key) do
    with {:ok, amendment} <- get(store, command_key),
         receipt when is_map(receipt) <- decode_object(amendment["receipt_json"]),
         true <- receipt["application_kind"] == "BLOCKED_WRITER_HELD",
         predecessor when is_map(predecessor) <- decode_object(receipt["blocked_predecessor_json"]),
         true <- predecessor["request_key"] == request_key do
      receipt
    else
      _ -> nil
    end
  end

  @spec validate_current(Store.connection(), String.t()) :: {:ok, map(), map()} | {:error, term()}
  def validate_current(store, command_key) do
    with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(store, command_key),
         :ok <- current_rows_match(store, validated),
         {:ok, amendment} <- get(store, command_key) do
      {:ok, validated, amendment}
    end
  end

  @spec validate_current(Store.connection(), String.t(), map()) :: {:ok, map(), map()} | {:error, term()}
  def validate_current(store, command_key, controller_context) do
    with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(store, command_key),
         :ok <- controller_context_matches(controller_context, validated),
         {:ok, current, amendment} <- validate_current(store, command_key),
         true <- current == validated or {:error, :amendment_identity_changed} do
      {:ok, validated, amendment}
    end
  end

  @spec prepare_critic(Store.connection(), String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_critic(store, command_key, controller_context, reviewed_snapshot_json, model_policy) do
    transaction(store, fn tx ->
      with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(tx, command_key),
           :ok <- current_rows_match(tx, validated),
           :ok <- controller_context_matches(controller_context, validated),
           {:ok, amendment} <- get(tx, command_key),
           true <- amendment["phase"] == "RESERVED" or {:error, :invalid_contract_amendment},
           {:ok, receipt} <- TicketAmendmentJiraOperation.readback(tx, command_key),
           true <- receipt["readback_json"] == reviewed_snapshot_json or {:error, :amendment_readback_receipt_mismatch},
           {:ok, route} <- ModelRouter.resolve(model_policy, "specification-critic"),
           {:ok, snapshot, draft_comment_id} <- reviewed_snapshot(reviewed_snapshot_json, validated, amendment) do
        prepare_critic_transaction(tx, validated, amendment, route, reviewed_snapshot_json, snapshot, draft_comment_id)
      else
        {:error, _} = error -> error
      end
    end)
  end

  @spec claim_critic(Store.connection(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def claim_critic(store, command_key, controller_context, model_policy) do
    transaction(store, fn tx ->
      with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(tx, command_key),
           :ok <- current_rows_match(tx, validated),
           :ok <- controller_context_matches(controller_context, validated),
           {:ok, amendment} <- get(tx, command_key),
           true <- amendment["phase"] == "RESERVED" or {:error, :invalid_contract_amendment},
           attempt when is_map(attempt) <- Store.one!(tx, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key]),
           :ok <- validate_critic_attempt(tx, attempt, validated, amendment),
           {:ok, route} <- ModelRouter.resolve(model_policy, "specification-critic"),
           true <- critic_route_matches?(attempt, route) or {:error, :critic_attempt_binding_conflict},
           :ok <- claim_prepared_attempt(tx, attempt) do
        {:ok, Store.one!(tx, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key])}
      else
        nil -> {:error, :critic_attempt_not_prepared}
        {:error, _} = error -> error
      end
    end)
  end

  @spec get_critic_attempt(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_critic_attempt(store, command_key, model_policy) do
    with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(store, command_key),
         :ok <- current_rows_match(store, validated),
         {:ok, amendment} <- get(store, command_key),
         attempt when is_map(attempt) <- Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key]),
         :ok <- validate_critic_attempt(store, attempt, validated, amendment),
         {:ok, route} <- ModelRouter.resolve(model_policy, "specification-critic"),
         true <- critic_route_matches?(attempt, route) or {:error, :critic_attempt_binding_conflict} do
      {:ok, attempt}
    else
      nil -> {:error, :critic_attempt_not_prepared}
      {:error, _} = error -> error
    end
  end

  @spec record_critic_session(Store.connection(), String.t(), map(), map()) :: :ok | {:error, term()}
  def record_critic_session(store, command_key, controller_context, session_evidence) do
    transaction(store, fn tx ->
      with {:ok, validated, _amendment, attempt} <- current_critic_attempt(tx, command_key, controller_context),
           :ok <- validate_session_evidence(session_evidence, validated.chat, attempt) do
        persist_session_evidence(tx, attempt, session_evidence)
      end
    end)
  end

  @spec record_critic_turn(Store.connection(), String.t(), map(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_critic_turn(store, command_key, controller_context, thread_id, turn_id) do
    transaction(store, fn tx ->
      with {:ok, _validated, _amendment, attempt} <- current_critic_attempt(tx, command_key, controller_context),
           true <- attempt["worker_thread_id"] == thread_id or {:error, :critic_turn_thread_mismatch},
           true <- (is_binary(turn_id) and turn_id != "") or {:error, :critic_turn_identity_missing} do
        persist_turn_identity(tx, attempt, turn_id)
      end
    end)
  end

  @spec record_critic_result(Store.connection(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def record_critic_result(store, command_key, controller_context, receipt) do
    transaction(store, fn tx ->
      with {:ok, validated, _amendment, attempt} <- current_critic_attempt(tx, command_key, controller_context),
           :ok <- validate_critic_result(receipt, attempt, validated) do
        persist_critic_result(tx, attempt, receipt)
      end
    end)
  end

  @spec reconcile_critic(Store.connection(), String.t(), map(), term(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_critic(store, command_key, controller_context, reason, observation \\ %{}) do
    transaction(store, fn tx ->
      with {:ok, _validated, _amendment, attempt} <- current_critic_attempt(tx, command_key, controller_context),
           true <- is_map(observation) or {:error, :critic_observation_invalid},
           {:ok, reconciled} <- persist_critic_reconciliation(tx, attempt, reason, observation),
           {:ok, _notice} <- SpecialistErrorNotice.record_critic(tx, command_key, reason) do
        {:ok, reconciled}
      end
    end)
  end

  defp current_critic_attempt(store, command_key, controller_context) do
    with {:ok, validated, amendment} <- validate_current(store, command_key, controller_context),
         true <- amendment["phase"] == "RESERVED" or {:error, :invalid_contract_amendment},
         {:ok, receipt} <- TicketAmendmentJiraOperation.readback(store, command_key),
         attempt when is_map(attempt) <- Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key]),
         :ok <- validate_critic_attempt(store, attempt, validated, amendment),
         true <- attempt["snapshot_json"] == receipt["readback_json"] or {:error, :amendment_readback_receipt_mismatch} do
      {:ok, validated, amendment, attempt}
    else
      nil -> {:error, :critic_attempt_not_prepared}
      {:error, _} = error -> error
    end
  end

  defp apply_reserved_amendment(store, command_key, controller_context, model_policy) do
    transaction(store, fn tx ->
      with {:ok, validated} <- TicketChatCommands.validate_contract_amendment(tx, command_key),
           :ok <- current_rows_match(tx, validated),
           :ok <- controller_context_matches(controller_context, validated),
           {:ok, amendment} <- get(tx, command_key),
           true <- active_reserved?(amendment) or {:error, :invalid_contract_amendment},
           {:ok, application_kind} <- admitted_application_kind(validated),
           :ok <- no_competing_current_work(tx, validated),
           {:ok, blocked_predecessor} <- blocked_predecessor_for_application(tx, validated, amendment),
           {:ok, draft} <- TicketAmendmentJiraOperation.readback(tx, command_key),
           {:ok, attempt} <- get_critic_attempt(tx, command_key, model_policy),
           {:ok, authorization} <-
             TicketAmendmentJiraOperation.readback_authorization(tx, command_key, controller_context, model_policy),
           :ok <- validate_ready_authority(validated, amendment, draft, attempt, authorization),
           {:ok, answer_proof} <- TicketChatCommands.apply_amendment_answers(tx, validated),
           {:ok, result} <-
             install_authorized_contract(
               tx,
               validated,
               amendment,
               attempt,
               authorization,
               application_kind,
               blocked_predecessor,
               answer_proof
             ) do
        persist_application_receipt(tx, command_key, result)
      else
        {:error, _} = error -> error
      end
    end)
  end

  defp admitted_application_kind(%{run: %{"state" => "READY_FOR_REVIEW"}, disposition: nil}), do: {:ok, "READY_FOR_REVIEW"}
  defp admitted_application_kind(%{run: %{"state" => "WRITING"}, disposition: %{"status" => "BLOCKED"}}), do: {:ok, "BLOCKED_WRITER_HELD"}
  defp admitted_application_kind(_validated), do: {:error, :amendment_application_state_not_admitted}

  defp blocked_predecessor_for_application(_store, %{disposition: nil}, _amendment), do: {:ok, nil}

  defp blocked_predecessor_for_application(store, %{disposition: disposition} = validated, amendment) do
    with true <- amendment["predecessor_json"] == Jason.encode!(disposition) or {:error, :amendment_predecessor_changed},
         :ok <- current_predecessor_matches(store, validated),
         {:ok, completed} <- completed_blocked_predecessor(store, validated, disposition),
         true <- (completed.run == validated.run and completed.output["status"] == "BLOCKED") or {:error, :stopped_blocked_writer_not_proven},
         true <- (completed.task["task_key"] == disposition["task_key"] and completed.access["reservation_key"] == disposition["reservation_key"]) or {:error, :stopped_blocked_writer_not_proven},
         event when is_map(event) <- blocked_disposition_event(store, disposition) do
      {:ok, encode_blocked_predecessor(completed, event, disposition)}
    else
      {:error, _} = error -> error
      _ -> {:error, :stopped_blocked_writer_not_proven}
    end
  end

  defp completed_blocked_predecessor(store, validated, disposition) do
    case historical_completed_blocked_predecessor(store, validated, disposition) do
      {:ok, completed} -> {:ok, completed}
      {:error, _} -> WorkerEvidence.completed_result(store, disposition["request_key"])
    end
  end

  defp historical_completed_blocked_predecessor(store, validated, disposition) do
    with {:ok, %{receipt: receipt}} <- blocked_predecessor_for_installed_run(store, validated.run),
         :ok <- WorkspaceAccess.validate_blocked_amendment_predecessor(store, receipt),
         predecessor when is_map(predecessor) <- decode_object(receipt["blocked_predecessor_json"]),
         true <- predecessor["request_key"] == disposition["request_key"],
         true <- predecessor["output_sha256"] == disposition["output_sha256"],
         evidence when is_map(evidence) <- decode_object(predecessor["evidence_json"]),
         task when is_map(task) <- decode_object(predecessor["task_json"]),
         access when is_map(access) <- decode_object(predecessor["access_json"]),
         output when is_map(output) <- decode_object(predecessor["output_json"]),
         true <- evidence["task_key"] == task["task_key"] and evidence["reservation_key"] == access["reservation_key"],
         true <- output["status"] == "BLOCKED" do
      {:ok, %{run: validated.run, output: output, evidence: evidence, task: task, access: access}}
    else
      _ -> {:error, :stopped_blocked_writer_not_proven}
    end
  end

  defp blocked_disposition_event(store, disposition) do
    with {:ok, reference} <- Base.url_decode64(disposition["artifact_ref"], padding: false),
         {:ok, %{"kind" => "event", "id" => event_id, "sha256" => sha}} <- Jason.decode(reference),
         event when is_map(event) <-
           Store.one!(store, "SELECT id, payload_json FROM events WHERE id = ? AND run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'", [event_id, disposition["run_id"]]),
         true <- digest(event["payload_json"]) == sha do
      event
    else
      _ -> nil
    end
  end

  defp encode_blocked_predecessor(completed, event, disposition) do
    evidence_json = Jason.encode!(completed.evidence)
    task_json = Jason.encode!(completed.task)
    access_json = Jason.encode!(completed.access)

    predecessor = %{
      "request_key" => completed.evidence["request_key"],
      "binding_sha256" => completed.evidence["binding_sha256"],
      "owner_stop_sha256" => digest(completed.evidence["owner_stop_json"]),
      "disposition_event_id" => event["id"],
      "disposition_json" => event["payload_json"],
      "disposition_sha256" => digest(event["payload_json"]),
      "evidence_json" => evidence_json,
      "evidence_sha256" => digest(evidence_json),
      "task_json" => task_json,
      "task_sha256" => digest(task_json),
      "access_json" => access_json,
      "access_sha256" => digest(access_json),
      "binding_json" => completed.evidence["binding_json"],
      "output_json" => completed.evidence["output_json"],
      "output_sha256" => completed.evidence["output_sha256"]
    }

    if is_nil(completed.run["candidate_sha"]) do
      Map.put(predecessor, "checkout_head_sha", disposition["checkout_head_sha"])
    else
      predecessor
    end
  end

  defp no_competing_current_work(store, validated) do
    command = validated.command

    pending_commands =
      Store.one!(
        store,
        """
        SELECT COUNT(*) AS count FROM ticket_chat_commands
        WHERE run_id = ? AND command_key != ?
          AND (status = 'ACCEPTED' OR
            (status = 'PENDING' AND (input_key IS NOT NULL OR receipt_json IS NOT NULL)))
        """,
        [command["run_id"], command["command_key"]]
      )["count"]

    selected = MapSet.new(Enum.map(validated.answer_questions, & &1["question_key"]))

    open_questions =
      Store.query!(store, "SELECT question_key FROM ticket_chat_questions WHERE run_id = ? AND status = 'OPEN'", [command["run_id"]]).rows
      |> List.flatten()
      |> Enum.count(&(not MapSet.member?(selected, &1)))

    other_owner =
      Store.one!(
        store,
        "SELECT COUNT(*) AS count FROM ticket_contract_amendments WHERE run_id = ? AND command_key != ? AND active_owner = 1",
        [command["run_id"], command["command_key"]]
      )["count"]

    if pending_commands == 0 and open_questions == 0 and other_owner == 0,
      do: :ok,
      else: {:error, :amendment_competing_current_work}
  end

  defp validate_ready_authority(validated, amendment, draft, attempt, authorization) do
    with true <- attempt["phase"] == "RESULT_RECORDED" or {:error, :critic_result_not_recorded},
         true <- attempt["snapshot_json"] == draft["readback_json"] or {:error, :amendment_readback_receipt_mismatch},
         true <- authorization["draft_readback_json"] == draft["readback_json"] or {:error, :amendment_authorization_draft_mismatch},
         {:ok, snapshot} <- Jason.decode(authorization["readback_json"]),
         proposed <- Contract.bind(validated.run["issue_key"], amendment["proposed_revision"], amendment["proposed_contract_markdown"]),
         {:ok, false} <- Contract.manual_validation_required(proposed.markdown),
         {:ok, authorized} <- Contract.authorized_from_snapshot(snapshot, validated.run["issue_key"]),
         true <- authorized == proposed or {:error, :amendment_authorization_contract_mismatch},
         {:ok, proof} <- Contract.automatic_authorization_proof(snapshot, proposed),
         true <-
           proof_matches_attempt?(proof, attempt, authorization) or {:error, :amendment_authorization_proof_mismatch} do
      :ok
    else
      {:ok, true} -> {:error, :manual_validation_required}
      {:error, _} = error -> error
      _ -> {:error, :amendment_authorization_invalid}
    end
  end

  defp active_reserved?(amendment), do: amendment["phase"] == "RESERVED" and amendment["active_owner"] == 1

  defp proof_matches_attempt?(proof, attempt, authorization),
    do: proof == %{critic_task_key: attempt["task_key"], critic_output_sha256: authorization["critic_output_sha256"]}

  defp install_authorized_contract(store, validated, amendment, attempt, authorization, application_kind, blocked_predecessor, answer_proof) do
    run = validated.run
    next_verifier_round = if application_kind == "READY_FOR_REVIEW", do: run["verifier_round"] + 1, else: run["verifier_round"]
    at = now()
    protected_rows_json = protected_rows_json(store, run["run_id"])

    install_authorized_run_binding(store, run, amendment, authorization, application_kind, next_verifier_round, at)
    {:ok, applied_run} = RunLedger.get(store, run["run_id"])
    draft_effect = Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [amendment["command_key"]])
    authorization_effect = Store.one!(store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [amendment["command_key"]])
    {:ok, critic_task} = TaskLedger.get(store, attempt["task_key"])

    prior_run_json = Jason.encode!(run)
    applied_run_json = Jason.encode!(applied_run)

    receipt = %{
      "status" => "APPLIED",
      "application_kind" => application_kind,
      "command_key" => amendment["command_key"],
      "run_id" => run["run_id"],
      "chat_key" => amendment["chat_key"],
      "generation" => amendment["generation"],
      "input_key" => amendment["input_key"],
      "input_sha256" => amendment["input_sha256"],
      "input_row_sha256" => digest(Jason.encode!(validated.input)),
      "readback_sha256" => amendment["readback_sha256"],
      "admission_sha256" => amendment["admission_sha256"],
      "payload_sha256" => amendment["payload_sha256"],
      "prior_binding_json" => amendment["prior_binding_json"],
      "prior_revision" => amendment["prior_revision"],
      "prior_contract_sha256" => amendment["prior_contract_sha256"],
      "proposed_revision" => amendment["proposed_revision"],
      "proposed_contract_markdown" => amendment["proposed_contract_markdown"],
      "proposed_contract_sha256" => amendment["proposed_contract_sha256"],
      "candidate_sha" => amendment["candidate_sha"],
      "answer_application_proof" => answer_proof,
      "controller_context_json" => Jason.encode!(controller_context(validated)),
      "prior_run_json" => prior_run_json,
      "prior_run_sha256" => digest(prior_run_json),
      "applied_run_json" => applied_run_json,
      "applied_run_sha256" => digest(applied_run_json),
      "verifier_round" => next_verifier_round,
      "draft_effect_json" => Jason.encode!(draft_effect),
      "draft_effect_sha256" => digest(Jason.encode!(draft_effect)),
      "critic_attempt_json" => Jason.encode!(attempt),
      "critic_attempt_sha256" => digest(Jason.encode!(attempt)),
      "critic_task_json" => Jason.encode!(critic_task),
      "critic_task_sha256" => digest(Jason.encode!(critic_task)),
      "authorization_effect_json" => Jason.encode!(authorization_effect),
      "authorization_effect_sha256" => digest(Jason.encode!(authorization_effect)),
      "authorization_readback_json" => authorization["readback_json"],
      "authorization_readback_sha256" => authorization["readback_sha256"],
      "blocked_predecessor_json" => if(blocked_predecessor, do: Jason.encode!(blocked_predecessor)),
      "protected_rows_json" => protected_rows_json,
      "protected_rows_sha256" => digest(protected_rows_json)
    }

    {:ok, receipt}
  end

  defp install_authorized_run_binding(store, run, amendment, authorization, "READY_FOR_REVIEW", next_round, at) do
    Store.query!(
      store,
      "UPDATE runs SET spec_revision = ?, contract_sha256 = ?, contract_markdown = ?, snapshot_json = ?, manual_validation_required = 0, state = 'VERIFYING', verifier_round = ?, updated_at = ? WHERE run_id = ? AND kind = 'DELIVERY' AND execution_mode = 'TICKET_SUPERVISOR_V1' AND state = 'READY_FOR_REVIEW' AND spec_revision = ? AND contract_sha256 = ? AND candidate_sha IS ? AND verifier_round = ?",
      [
        amendment["proposed_revision"],
        amendment["proposed_contract_sha256"],
        amendment["proposed_contract_markdown"],
        authorization["readback_json"],
        next_round,
        at,
        run["run_id"],
        amendment["prior_revision"],
        amendment["prior_contract_sha256"],
        amendment["candidate_sha"],
        run["verifier_round"]
      ]
    )

    require_one_change(store, :amendment_run_installation_conflict)
  end

  defp install_authorized_run_binding(store, run, amendment, authorization, "BLOCKED_WRITER_HELD", _next_round, at) do
    Store.query!(
      store,
      "UPDATE runs SET spec_revision = ?, contract_sha256 = ?, contract_markdown = ?, snapshot_json = ?, manual_validation_required = 0, updated_at = ? WHERE run_id = ? AND kind = 'DELIVERY' AND execution_mode = 'TICKET_SUPERVISOR_V1' AND state = 'WRITING' AND spec_revision = ? AND contract_sha256 = ? AND candidate_sha IS ? AND verifier_round = ?",
      [
        amendment["proposed_revision"],
        amendment["proposed_contract_sha256"],
        amendment["proposed_contract_markdown"],
        authorization["readback_json"],
        at,
        run["run_id"],
        amendment["prior_revision"],
        amendment["prior_contract_sha256"],
        amendment["candidate_sha"],
        run["verifier_round"]
      ]
    )

    require_one_change(store, :amendment_run_installation_conflict)
  end

  defp persist_application_receipt(store, command_key, receipt) do
    raw = Jason.encode!(receipt)
    sha = digest(raw)
    at = now()

    Store.query!(store, "UPDATE ticket_chat_commands SET status = 'APPLIED', application_receipt_json = ?, updated_at = ? WHERE command_key = ? AND status = 'ACCEPTED'", [raw, at, command_key])
    require_one_change(store, :amendment_command_application_conflict)

    Store.query!(
      store,
      "UPDATE ticket_contract_amendments SET phase = 'APPLIED', active_owner = 0, receipt_json = ?, application_receipt_sha256 = ?, updated_at = ? WHERE command_key = ? AND phase = 'RESERVED' AND active_owner = 1",
      [raw, sha, at, command_key]
    )

    require_one_change(store, :amendment_terminal_receipt_conflict)

    case get(store, command_key) do
      {:ok, _applied} -> {:ok, receipt}
      {:error, reason} -> Exqlite.rollback(store, reason)
    end
  end

  defp replay_applied_amendment(store, amendment, controller_context) do
    with receipt when is_map(receipt) <- decode_object(amendment["receipt_json"]),
         :ok <- controller_context_matches_historical(controller_context, receipt),
         true <- (amendment["receipt_json"] == Jason.encode!(receipt) and valid_applied_receipt?(store, amendment)) or {:error, :invalid_amendment_application_receipt} do
      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_amendment_application_receipt}
    end
  end

  defp controller_context(validated) do
    %{
      "chat_key" => validated.chat["chat_key"],
      "run_id" => validated.run["run_id"],
      "binding" => Map.take(validated.run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", validated.chat["generation"])
    }
  end

  defp protected_rows_json(store, run_id) do
    %{
      "tasks" => rows_as_maps(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key", [run_id]),
      "worker_evidence" => rows_as_maps(store, "SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key", [run_id]),
      "workspace_access" => rows_as_maps(store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key", [run_id]),
      "review_bases" => rows_as_maps(store, "SELECT * FROM ticket_review_bases WHERE run_id = ? ORDER BY run_id", [run_id]),
      "checkouts" => rows_as_maps(store, "SELECT * FROM ticket_checkout_intents WHERE run_id = ? ORDER BY run_id", [run_id])
    }
    |> Jason.encode!()
  end

  defp rows_as_maps(store, sql, params) do
    %{columns: columns, rows: rows} = Store.query!(store, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp controller_context_matches_historical(context, receipt) do
    if context == decode_object(receipt["controller_context_json"]), do: :ok, else: {:error, :stale_controller_context}
  end

  defp validate_session_evidence(evidence, chat, _attempt) do
    with true <- is_map(evidence) and Map.keys(evidence) |> Enum.sort() == ~w(invocation_nonce owner_cwd owner_pid thread_id worker_policy_json),
         thread when is_binary(thread) and thread != "" <- evidence["thread_id"],
         true <- thread != chat["thread_id"] or {:error, :critic_parent_thread_rejected},
         {:ok, policy} <- Jason.decode(evidence["worker_policy_json"]),
         cwd when is_binary(cwd) <- evidence["owner_cwd"],
         {:ok, ^cwd} <- PathSafety.canonicalize(cwd),
         true <- File.dir?(cwd),
         true <- policy == AppServer.worker_policy("REVIEW", cwd) or {:error, :critic_review_policy_mismatch},
         true <- policy["mode"] == "REVIEW" and policy["cwd"] == cwd,
         true <- evidence["owner_pid"] |> valid_pid?(),
         true <- valid_hash?(evidence["invocation_nonce"], 64) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :critic_session_evidence_invalid}
    end
  end

  defp persist_session_evidence(store, attempt, evidence) do
    case attempt["worker_thread_id"] do
      nil ->
        at = now()

        Store.query!(
          store,
          "UPDATE ticket_contract_critic_attempts SET worker_thread_id = ?, worker_policy_json = ?, owner_pid = ?, invocation_nonce = ?, owner_cwd = ?, updated_at = ? WHERE command_key = ? AND phase = 'INVOKING' AND worker_thread_id IS NULL",
          [
            evidence["thread_id"],
            evidence["worker_policy_json"],
            evidence["owner_pid"],
            evidence["invocation_nonce"],
            evidence["owner_cwd"],
            at,
            attempt["command_key"]
          ]
        )

        require_one_change(store, :critic_session_persistence_failed)

        Store.query!(store, "UPDATE factory_tasks SET thread_id = ?, updated_at = ? WHERE task_key = ? AND status = 'INVOKING' AND thread_id IS NULL", [evidence["thread_id"], at, attempt["task_key"]])
        require_one_change(store, :critic_task_session_persistence_failed)

      _existing ->
        fields = ~w(worker_thread_id worker_policy_json owner_pid invocation_nonce owner_cwd)

        expected = %{
          "worker_thread_id" => evidence["thread_id"],
          "worker_policy_json" => evidence["worker_policy_json"],
          "owner_pid" => evidence["owner_pid"],
          "invocation_nonce" => evidence["invocation_nonce"],
          "owner_cwd" => evidence["owner_cwd"]
        }

        if Map.take(attempt, fields) == expected, do: :ok, else: {:error, :critic_session_identity_conflict}
    end
  end

  defp persist_turn_identity(store, attempt, turn_id) do
    case attempt["worker_turn_id"] do
      nil ->
        at = now()

        Store.query!(
          store,
          "UPDATE ticket_contract_critic_attempts SET worker_turn_id = ?, updated_at = ? WHERE command_key = ? AND phase = 'INVOKING' AND worker_thread_id IS NOT NULL AND worker_turn_id IS NULL",
          [turn_id, at, attempt["command_key"]]
        )

        require_one_change(store, :critic_turn_persistence_failed)
        Store.query!(store, "UPDATE factory_tasks SET turn_id = ?, updated_at = ? WHERE task_key = ? AND status = 'INVOKING' AND turn_id IS NULL", [turn_id, at, attempt["task_key"]])
        require_one_change(store, :critic_task_turn_persistence_failed)

      ^turn_id ->
        :ok

      _other ->
        {:error, :critic_turn_identity_conflict}
    end
  end

  defp validate_critic_result(receipt, attempt, validated) do
    with true <- is_map(receipt) and map_size(receipt) == 9,
         true <- receipt["task_key"] == attempt["task_key"],
         true <- receipt["attempt_binding_sha256"] == digest(Jason.encode!(Map.take(attempt, @critic_binding_fields))),
         true <- nonempty_identity?(receipt["thread_id"]) and receipt["thread_id"] == attempt["worker_thread_id"],
         true <- nonempty_identity?(receipt["turn_id"]) and receipt["turn_id"] == attempt["worker_turn_id"],
         true <- is_binary(receipt["item_id"]) and receipt["item_id"] != "",
         true <- attempt["phase"] != "RESULT_RECORDED" or receipt["item_id"] == attempt["worker_item_id"],
         true <- receipt["thread_id"] != validated.chat["thread_id"] or {:error, :critic_parent_thread_rejected},
         {:ok, policy} <- Jason.decode(attempt["worker_policy_json"]),
         :ok <- validate_critic_owner(attempt, validated),
         true <- policy == AppServer.worker_policy("REVIEW", attempt["owner_cwd"]),
         true <- receipt["policy"] == policy,
         true <- attempt["phase"] != "RESULT_RECORDED" or Jason.encode!(receipt["owner_stop"]) == attempt["owner_stop_json"],
         :ok <- validate_owner_stop(receipt["owner_stop"], attempt),
         {:ok, schema} <- Jason.decode(attempt["schema_json"]),
         :ok <- StageSchemas.validate(receipt["output"], schema),
         true <- receipt["qualifies"] == critic_qualifies?(receipt["output"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :critic_result_binding_mismatch}
    end
  end

  defp validate_critic_owner(attempt, validated) do
    cwd = attempt["owner_cwd"]

    with true <- is_binary(cwd),
         {:ok, ^cwd} <- PathSafety.canonicalize(cwd),
         true <- File.dir?(cwd),
         {:ok, ^cwd} <- TicketMrOperation.controller_cwd(cwd, validated.run["repo_path"], validated.run["worktree"] || validated.run["repo_path"]),
         true <- valid_pid?(attempt["owner_pid"]),
         true <- valid_hash?(attempt["invocation_nonce"], 64) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :critic_owner_binding_invalid}
    end
  end

  defp validate_owner_stop(stop, attempt) do
    expected = %{
      "transport" => "owned_app_server",
      "thread_id" => attempt["worker_thread_id"],
      "pid" => attempt["owner_pid"],
      "invocation_nonce" => attempt["invocation_nonce"],
      "cwd" => attempt["owner_cwd"]
    }

    if is_map(stop) and map_size(stop) == 6 and Map.take(stop, Map.keys(expected)) == expected and is_integer(stop["exit_status"]),
      do: :ok,
      else: {:error, :critic_owner_stop_mismatch}
  end

  defp persist_critic_result(_store, %{"phase" => "RESULT_RECORDED"} = attempt, receipt) do
    if attempt["result_json"] == Jason.encode!(receipt) and attempt["result_sha256"] == digest(attempt["result_json"]),
      do: {:ok, attempt},
      else: {:error, :critic_result_conflict}
  end

  defp persist_critic_result(store, %{"phase" => "INVOKING"} = attempt, receipt) do
    raw = Jason.encode!(receipt)
    output = Jason.encode!(receipt["output"])
    at = now()

    Store.query!(
      store,
      "UPDATE ticket_contract_critic_attempts SET phase = 'RESULT_RECORDED', worker_item_id = ?, owner_stop_json = ?, result_json = ?, result_sha256 = ?, last_error = NULL, updated_at = ? WHERE command_key = ? AND phase = 'INVOKING'",
      [receipt["item_id"], Jason.encode!(receipt["owner_stop"]), raw, digest(raw), at, attempt["command_key"]]
    )

    require_one_change(store, :critic_result_persistence_failed)
    Store.query!(store, "UPDATE factory_tasks SET status = 'RESULT_RECORDED', output_json = ?, updated_at = ? WHERE task_key = ? AND status = 'INVOKING'", [output, at, attempt["task_key"]])
    require_one_change(store, :critic_task_result_persistence_failed)
    {:ok, Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [attempt["command_key"]])}
  end

  defp persist_critic_result(_store, _attempt, _receipt), do: {:error, :critic_result_not_adoptable}

  defp persist_critic_reconciliation(_store, %{"phase" => "RECONCILE_REQUIRED"} = attempt, reason, observation) do
    raw = Jason.encode!(observation)

    if attempt["last_error"] == inspect(reason) and attempt["last_observation_json"] == raw,
      do: {:ok, attempt},
      else: {:error, :critic_reconciliation_conflict}
  end

  defp persist_critic_reconciliation(store, %{"phase" => "INVOKING"} = attempt, reason, observation) do
    raw = Jason.encode!(observation)
    at = now()

    Store.query!(
      store,
      "UPDATE ticket_contract_critic_attempts SET phase = 'RECONCILE_REQUIRED', last_observation_json = ?, last_error = ?, updated_at = ? WHERE command_key = ? AND phase = 'INVOKING'",
      [raw, inspect(reason), at, attempt["command_key"]]
    )

    require_one_change(store, :critic_reconciliation_persistence_failed)
    Store.query!(store, "UPDATE factory_tasks SET status = 'RECONCILE_REQUIRED', updated_at = ? WHERE task_key = ? AND status = 'INVOKING'", [at, attempt["task_key"]])
    require_one_change(store, :critic_task_reconciliation_persistence_failed)
    {:ok, Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [attempt["command_key"]])}
  end

  defp persist_critic_reconciliation(_store, _attempt, _reason, _observation), do: {:error, :critic_result_already_recorded}

  defp require_one_change(store, reason) do
    if Store.one!(store, "SELECT changes() AS count")["count"] == 1, do: :ok, else: Exqlite.rollback(store, reason)
  end

  defp critic_qualifies?(%{"status" => "PASS", "findings" => [], "required_questions" => []}), do: true
  defp critic_qualifies?(_output), do: false

  defp valid_pid?(pid), do: is_binary(pid) and Regex.match?(~r/\A[1-9][0-9]*\z/, pid)

  defp critic_route_matches?(attempt, route),
    do: decode_object(attempt["route_json"]) == Map.new(route, fn {key, value} -> {to_string(key), value} end)

  defp prepare_critic_transaction(store, validated, amendment, route, snapshot_json, snapshot, draft_comment_id) do
    command = validated.command
    run = validated.run
    chat = validated.chat
    input = validated.input

    prompt =
      Prompt.specification_critic(
        snapshot,
        validated.proposed_contract.markdown,
        validated.proposed_contract.sha256
      )

    schema_json = StageSchemas.for_stage(:specification_critic) |> Jason.encode!()
    route_json = route |> Map.put(:result, "RESOLVED") |> Jason.encode!()
    task_key = "#{run["run_id"]}:contract-amendment-critic:#{command["command_key"]}"

    expected = %{
      "command_key" => command["command_key"],
      "run_id" => run["run_id"],
      "task_key" => task_key,
      "chat_key" => chat["chat_key"],
      "generation" => chat["generation"],
      "input_key" => input["input_key"],
      "input_sha256" => digest(Jason.encode!(input)),
      "draft_comment_id" => draft_comment_id,
      "prior_revision" => amendment["prior_revision"],
      "prior_contract_sha256" => amendment["prior_contract_sha256"],
      "candidate_sha" => amendment["candidate_sha"],
      "proposed_revision" => amendment["proposed_revision"],
      "proposed_contract_sha256" => amendment["proposed_contract_sha256"],
      "prompt" => prompt,
      "prompt_sha256" => digest(prompt),
      "schema_json" => schema_json,
      "schema_sha256" => digest(schema_json),
      "snapshot_json" => snapshot_json,
      "snapshot_sha256" => digest(snapshot_json),
      "route_json" => route_json,
      "route_sha256" => digest(route_json)
    }

    case Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) do
      nil ->
        insert_critic_attempt(store, expected, route)

      %{"phase" => "PREPARED"} = attempt ->
        with :ok <- validate_critic_attempt(store, attempt, validated, amendment),
             true <- Map.take(attempt, Map.keys(expected)) == expected or {:error, :critic_attempt_binding_conflict} do
          {:ok, attempt}
        else
          {:error, _} = error -> error
        end

      %{"phase" => "INVOKING"} ->
        {:error, :critic_attempt_not_authorized}

      _ ->
        {:error, :invalid_critic_attempt}
    end
  end

  defp insert_critic_attempt(store, expected, route) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    TaskLedger.register(store, %{
      task_key: expected["task_key"],
      run_id: expected["run_id"],
      stage: "contract-amendment-critic",
      role: route.resolved_role,
      status: "PREPARED",
      model_provider: route.provider,
      model_class: route.model_class,
      model: route.model,
      reasoning_effort: route.reasoning_effort,
      routing_reason: route.routing_reason,
      prompt_sha256: expected["prompt_sha256"]
    })
    |> case do
      {:ok, _task} ->
        fields = Map.keys(expected)
        columns = Enum.join(fields, ", ")
        placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)

        Store.query!(
          store,
          "INSERT INTO ticket_contract_critic_attempts(#{columns}, phase, created_at, updated_at) VALUES (#{placeholders}, 'PREPARED', ?, ?)",
          Enum.map(fields, &Map.fetch!(expected, &1)) ++ [at, at]
        )

        {:ok, Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [expected["command_key"]])}

      {:error, reason} ->
        Exqlite.rollback(store, reason)
    end
  end

  defp validate_critic_attempt(store, attempt, validated, amendment) do
    task = TaskLedger.get(store, attempt["task_key"])
    route = decode_object(attempt["route_json"])
    expected_schema = StageSchemas.for_stage(:specification_critic) |> Jason.encode!()
    reviewed = reviewed_snapshot(attempt["snapshot_json"], validated, amendment)

    {expected_prompt, draft_comment_id} =
      case reviewed do
        {:ok, snapshot, comment_id} -> {Prompt.specification_critic(snapshot, amendment["proposed_contract_markdown"], amendment["proposed_contract_sha256"]), comment_id}
        _ -> {nil, nil}
      end

    valid =
      attempt_binding_matches?(attempt, amendment, validated.input) and
        attempt_content_matches?(attempt, expected_prompt, expected_schema, draft_comment_id, route) and
        task_matches_attempt?(task, attempt, route)

    if valid and critic_attempt_lifecycle_valid?(store, attempt, validated),
      do: :ok,
      else: {:error, :invalid_critic_attempt}
  end

  defp critic_attempt_lifecycle_valid?(store, attempt, validated) do
    case TaskLedger.get(store, attempt["task_key"]) do
      {:ok, task} -> valid_critic_phase?(attempt, task, validated)
      _ -> false
    end
  end

  defp valid_critic_phase?(%{"phase" => "PREPARED"} = attempt, task, _validated),
    do:
      is_nil(attempt["worker_thread_id"]) and is_nil(attempt["worker_turn_id"]) and is_nil(attempt["result_json"]) and
        task_status_matches?(task, attempt) and task_worker_identity_matches?(task, attempt)

  defp valid_critic_phase?(%{"phase" => "INVOKING"} = attempt, task, _validated),
    do:
      is_nil(attempt["result_json"]) and task_status_matches?(task, attempt) and
        task_worker_identity_matches?(task, attempt)

  defp valid_critic_phase?(%{"phase" => "RESULT_RECORDED"} = attempt, task, validated),
    do: valid_recorded_critic_result?(attempt, task, validated)

  defp valid_critic_phase?(%{"phase" => "RECONCILE_REQUIRED"} = attempt, task, _validated),
    do:
      is_binary(attempt["last_error"]) and attempt["last_error"] != "" and task_status_matches?(task, attempt) and
        task_worker_identity_matches?(task, attempt)

  defp valid_critic_phase?(_attempt, _task, _validated), do: false

  defp valid_recorded_critic_result?(attempt, task, validated) do
    with {:ok, result} <- Jason.decode(attempt["result_json"]),
         true <- attempt["result_sha256"] == digest(attempt["result_json"]),
         true <- task_status_matches?(task, attempt),
         :ok <- validate_critic_result(result, attempt, validated),
         true <- task_worker_identity_matches?(task, attempt),
         true <- task["output_json"] == Jason.encode!(result["output"]) do
      true
    else
      _ -> false
    end
  end

  defp task_worker_identity_matches?(task, attempt) do
    task["thread_id"] == attempt["worker_thread_id"] and task["turn_id"] == attempt["worker_turn_id"] and
      (is_nil(attempt["worker_turn_id"]) or
         (nonempty_identity?(attempt["worker_thread_id"]) and nonempty_identity?(attempt["worker_turn_id"])))
  end

  defp nonempty_identity?(value), do: is_binary(value) and value != ""

  defp attempt_binding_matches?(attempt, amendment, input) do
    fields = ~w(command_key run_id chat_key generation input_key prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256)

    Map.take(attempt, fields) == Map.take(amendment, fields) and
      attempt["input_sha256"] == digest(Jason.encode!(input))
  end

  defp attempt_content_matches?(attempt, prompt, schema, comment_id, route) do
    valid_values = is_binary(prompt) and is_binary(comment_id) and is_map(route)

    if valid_values do
      attempt_payload_matches?(attempt, prompt, schema, comment_id) and attempt_digests_match?(attempt, prompt, schema)
    else
      false
    end
  end

  defp attempt_payload_matches?(attempt, prompt, schema, comment_id),
    do:
      attempt["draft_comment_id"] == comment_id and attempt["prompt"] == prompt and
        attempt["schema_json"] == schema

  defp attempt_digests_match?(attempt, prompt, schema),
    do:
      attempt["prompt_sha256"] == digest(prompt) and attempt["schema_sha256"] == digest(schema) and
        attempt["snapshot_sha256"] == digest(attempt["snapshot_json"]) and
        attempt["route_sha256"] == digest(attempt["route_json"])

  defp task_matches_attempt?({:ok, task}, attempt, route) do
    task_identity_matches?(task, attempt, route) and task_status_matches?(task, attempt)
  end

  defp task_matches_attempt?(_, _, _), do: false

  defp task_identity_matches?(task, attempt, route) do
    {task["run_id"], task["task_key"], task["stage"], task["role"], task["prompt_sha256"]} ==
      {attempt["run_id"], attempt["task_key"], "contract-amendment-critic", route["resolved_role"], attempt["prompt_sha256"]} and
      {task["model_provider"], task["model_class"], task["model"], task["reasoning_effort"], task["routing_reason"]} ==
        {route["provider"], route["model_class"], route["model"], route["reasoning_effort"], route["routing_reason"]}
  end

  defp task_status_matches?(task, %{"phase" => "PREPARED"}), do: task["status"] == "PREPARED"
  defp task_status_matches?(task, %{"phase" => "INVOKING"}), do: task["status"] == "INVOKING"
  defp task_status_matches?(task, %{"phase" => "RESULT_RECORDED"}), do: task["status"] == "RESULT_RECORDED"
  defp task_status_matches?(task, %{"phase" => "RECONCILE_REQUIRED"}), do: task["status"] == "RECONCILE_REQUIRED"
  defp task_status_matches?(_task, _attempt), do: false

  defp claim_prepared_attempt(store, %{"phase" => "PREPARED"} = attempt) do
    Store.query!(store, "UPDATE ticket_contract_critic_attempts SET phase = 'INVOKING', updated_at = ? WHERE command_key = ? AND phase = 'PREPARED'", [
      DateTime.utc_now() |> DateTime.to_iso8601(),
      attempt["command_key"]
    ])

    if Store.one!(store, "SELECT changes() AS count")["count"] != 1,
      do: Exqlite.rollback(store, :critic_attempt_not_authorized)

    Store.query!(store, "UPDATE factory_tasks SET status = 'INVOKING', updated_at = ? WHERE task_key = ? AND status = 'PREPARED'", [DateTime.utc_now() |> DateTime.to_iso8601(), attempt["task_key"]])

    if Store.one!(store, "SELECT changes() AS count")["count"] != 1,
      do: Exqlite.rollback(store, :critic_attempt_not_authorized)

    :ok
  end

  defp claim_prepared_attempt(_store, %{"phase" => "INVOKING"}), do: {:error, :critic_attempt_not_authorized}
  defp claim_prepared_attempt(_store, _attempt), do: {:error, :invalid_critic_attempt}

  defp decode_snapshot(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      _ -> {:error, :invalid_amendment_snapshot}
    end
  end

  defp decode_snapshot(_raw), do: {:error, :invalid_amendment_snapshot}

  defp reviewed_snapshot(raw, validated, amendment) when is_binary(raw) do
    with {:ok, snapshot} <- decode_snapshot(raw),
         {:ok, publication_baseline} <- amendment_publication_snapshot(amendment, validated.run),
         {:ok, prior} <-
           Contract.authorized_from_snapshot(
             decode_snapshot!(validated.run["snapshot_json"]),
             validated.run["issue_key"]
           ),
         true <- prior_matches_amendment?(prior, amendment) or {:error, :amendment_preimage_changed},
         proposed <- Contract.bind(validated.run["issue_key"], amendment["proposed_revision"], amendment["proposed_contract_markdown"]),
         {:ok, false} <- Contract.manual_validation_required(proposed.markdown),
         true <- Contract.draft_read_back?(snapshot, proposed) or {:error, :amendment_draft_not_read_back},
         true <- not Contract.authorized?(snapshot, proposed) or {:error, :amendment_proposal_already_authorized},
         true <-
           Contract.next_revision(snapshot) == proposed.revision + 1 or
             {:error, :amendment_draft_revision_mismatch},
         true <- same_issue?(snapshot, validated.run) or {:error, :amendment_readback_issue_mismatch},
         true <-
           unchanged_issue_preimage?(snapshot, decode_snapshot!(validated.run["snapshot_json"])) or
             {:error, :amendment_readback_preimage_changed},
         {:ok, comment_id} <-
           added_draft_comment_id(snapshot, publication_baseline, Contract.draft_comment(proposed)) do
      {:ok, snapshot, comment_id}
    else
      {:ok, true} -> {:error, :manual_validation_required}
      {:error, _} = error -> error
    end
  rescue
    _error -> {:error, :amendment_readback_mismatch}
  end

  defp reviewed_snapshot(_raw, _validated, _amendment), do: {:error, :amendment_readback_missing}

  defp amendment_publication_snapshot(%{"supersession_json" => nil}, run), do: decode_snapshot(run["snapshot_json"])

  defp amendment_publication_snapshot(amendment, _run) do
    with {:ok, link} <- Jason.decode(amendment["supersession_json"]),
         raw when is_binary(raw) <- link["predecessor_draft_readback_json"],
         true <- digest(raw) == link["predecessor_draft_readback_sha256"],
         {:ok, snapshot} <- decode_snapshot(raw) do
      {:ok, snapshot}
    else
      _ -> {:error, :amendment_supersession_baseline_invalid}
    end
  end

  defp prior_matches_amendment?(prior, amendment),
    do: prior.revision == amendment["prior_revision"] and prior.sha256 == amendment["prior_contract_sha256"]

  defp decode_snapshot!(raw) do
    case decode_snapshot(raw) do
      {:ok, snapshot} -> snapshot
      _ -> raise ArgumentError, "invalid snapshot"
    end
  end

  defp same_issue?(snapshot, run) do
    baseline = decode_snapshot!(run["snapshot_json"])
    snapshot["id"] == baseline["id"] and snapshot["key"] == run["issue_key"]
  end

  defp unchanged_issue_preimage?(snapshot, baseline) do
    Map.drop(snapshot, ["comments", "updated"]) == Map.drop(baseline, ["comments", "updated"]) and
      is_binary(snapshot["updated"])
  end

  defp added_draft_comment_id(snapshot, baseline, expected_body) do
    current_comments = snapshot["comments"]
    prior_comments = baseline["comments"]

    if is_list(current_comments) and is_list(prior_comments) do
      added = current_comments -- prior_comments
      matching = Enum.filter(added, &(is_map(&1) and &1["text"] == expected_body and is_binary(&1["id"]) and &1["id"] != ""))
      remaining = current_comments -- matching

      if length(matching) == 1 and length(added) == 1 and
           Enum.sort_by(remaining, &Jason.encode!/1) == Enum.sort_by(prior_comments, &Jason.encode!/1) do
        {:ok, hd(matching)["id"]}
      else
        {:error, :amendment_readback_comment_mismatch}
      end
    else
      {:error, :amendment_readback_comments_missing}
    end
  end

  defp reserve_transaction(store, validated, controller_context) do
    command = validated.command
    chat = validated.chat
    run = validated.run
    input = validated.input
    prior = validated.current_contract
    proposed = validated.proposed_contract
    predecessor = validated.disposition && Jason.encode!(validated.disposition)

    expected = %{
      "command_key" => command["command_key"],
      "run_id" => run["run_id"],
      "chat_key" => chat["chat_key"],
      "generation" => chat["generation"],
      "active_owner" => 1,
      "phase" => "RESERVED",
      "prior_binding_json" =>
        Jason.encode!(%{
          "run_id" => run["run_id"],
          "issue_key" => run["issue_key"],
          "kind" => run["kind"],
          "execution_mode" => run["execution_mode"],
          "state" => run["state"],
          "spec_revision" => run["spec_revision"],
          "contract_sha256" => run["contract_sha256"],
          "candidate_sha" => run["candidate_sha"],
          "implementation_iteration" => run["implementation_iteration"],
          "generation" => chat["generation"]
        }),
      "prior_revision" => prior.revision,
      "prior_contract_markdown" => prior.markdown,
      "prior_contract_sha256" => prior.sha256,
      "proposed_revision" => proposed.revision,
      "proposed_contract_markdown" => proposed.markdown,
      "proposed_contract_sha256" => proposed.sha256,
      "candidate_sha" => run["candidate_sha"],
      "input_key" => input["input_key"],
      "input_sha256" => digest(Jason.encode!(input)),
      "readback_sha256" => input["readback_sha256"],
      "admission_sha256" => digest(command["receipt_json"]),
      "payload_sha256" => command["payload_sha256"],
      "predecessor_json" => predecessor,
      "supersession_json" => supersession_json(validated, command)
    }

    with :ok <- current_rows_match(store, validated),
         :ok <- current_predecessor_matches(store, validated),
         :ok <- controller_context_matches(controller_context, validated) do
      existing_or_insert(store, command["command_key"], expected)
    end
  end

  defp supersession_json(%{supersedes: nil}, _command), do: nil

  defp supersession_json(%{supersedes: correction, input: input} = validated, command) do
    Jason.encode!(%{
      "predecessor_command_key" => correction.predecessor_command_key,
      "successor_command_key" => command["command_key"],
      "run_id" => validated.run["run_id"],
      "chat_key" => validated.chat["chat_key"],
      "generation" => validated.chat["generation"],
      "predecessor_input_key" => correction.input_key,
      "predecessor_input_sha256" => correction.input_sha256,
      "predecessor_payload_sha256" => correction.payload_sha256,
      "predecessor_proposed_contract_sha256" => correction.proposed_contract_sha256,
      "predecessor_draft_comment_id" => correction.draft_comment_id,
      "predecessor_draft_body_sha256" => correction.draft_body_sha256,
      "predecessor_draft_effect_sha256" => correction.draft_effect_sha256,
      "predecessor_draft_readback_json" => correction.draft_readback_json,
      "predecessor_draft_readback_sha256" => correction.draft_readback_sha256,
      "predecessor_critic_task_key" => correction.critic_task_key,
      "predecessor_critic_attempt_sha256" => correction.critic_attempt_sha256,
      "predecessor_critic_result_sha256" => correction.critic_result_sha256,
      "successor_input_key" => input["input_key"],
      "successor_input_sha256" => digest(Jason.encode!(input)),
      "successor_admission_sha256" => digest(command["receipt_json"]),
      "successor_readback_sha256" => input["readback_sha256"],
      "successor_payload_sha256" => command["payload_sha256"],
      "successor_proposed_revision" => validated.proposed_contract.revision,
      "successor_proposed_contract_markdown" => validated.proposed_contract.markdown,
      "successor_proposed_contract_sha256" => validated.proposed_contract.sha256
    })
  end

  defp current_predecessor_matches(_store, %{disposition: nil}), do: :ok

  defp current_predecessor_matches(store, %{disposition: predecessor}) do
    with {:ok, ref_json} <- Base.url_decode64(predecessor["artifact_ref"], padding: false),
         {:ok, %{"kind" => "event", "id" => event_id, "sha256" => event_sha}} <- Jason.decode(ref_json),
         event when is_map(event) <-
           Store.one!(store, "SELECT id, payload_json FROM events WHERE id = ? AND run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'", [event_id, predecessor["run_id"]]),
         true <- digest(event["payload_json"]) == event_sha,
         evidence when is_map(evidence) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [predecessor["request_key"]]),
         task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [predecessor["task_key"]]),
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]),
         true <- digest(Jason.encode!(evidence)) == predecessor["evidence_sha256"],
         true <- digest(Jason.encode!(task)) == predecessor["task_sha256"],
         true <- digest(Jason.encode!(access)) == predecessor["access_sha256"],
         :ok <- current_predecessor_head_matches(access, predecessor) do
      :ok
    else
      _ -> {:error, :amendment_predecessor_changed}
    end
  end

  defp current_predecessor_head_matches(access, %{"checkout_head_sha" => expected}) do
    with true <- valid_hash?(expected, 40),
         {:ok, ^expected} <- WorkerEvidence.checkout_head(access) do
      :ok
    else
      _ -> {:error, :amendment_checkout_head_changed}
    end
  end

  defp current_predecessor_head_matches(_access, %{"run_binding" => %{"candidate_sha" => nil}}),
    do: {:error, :amendment_checkout_head_unproven}

  defp current_predecessor_head_matches(_access, _predecessor), do: :ok

  defp current_rows_match(store, validated) do
    command = validated.command
    run = validated.run
    chat = validated.chat
    input = validated.input

    current_command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])
    current_run = RunLedger.get(store, run["run_id"])
    current_chat = Store.one!(store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [chat["chat_key"]])
    current_association = Store.one!(store, "SELECT * FROM ticket_chat_runs WHERE run_id = ?", [run["run_id"]])
    current_input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [input["input_key"]])

    if current_command == command and current_run == {:ok, run} and current_chat == chat and
         current_association == validated.association and current_input == input,
       do: :ok,
       else: {:error, :amendment_identity_changed}
  end

  defp existing_or_insert(store, command_key, expected) do
    rows = rows_for_run(store, expected["run_id"])

    cond do
      not Enum.all?(rows, &valid_record?(store, &1)) ->
        {:error, :invalid_contract_amendment}

      row = Enum.find(rows, &(&1["command_key"] == command_key)) ->
        if row["phase"] == "RESERVED" and row["active_owner"] == 1 and
             Map.take(row, @immutable_fields) == Map.take(expected, @immutable_fields),
           do: {:ok, row},
           else: {:error, :amendment_identity_conflict}

      active_owner = Enum.find(rows, &(&1["active_owner"] == 1)) ->
        reserve_against_active_owner(store, active_owner, command_key, expected)

      true ->
        insert(store, expected)
    end
  end

  defp reserve_against_active_owner(store, %{"command_key" => predecessor_key} = predecessor, command_key, expected) do
    case Store.one!(store, "SELECT status FROM ticket_chat_commands WHERE command_key = ?", [command_key]) do
      %{"status" => "ACCEPTED"} -> supersede_and_insert(store, predecessor, predecessor_key, command_key, expected)
      _ -> {:error, :amendment_reservation_conflict}
    end
  end

  defp supersede_and_insert(store, predecessor, predecessor_key, successor_key, expected) do
    with {:ok, run} <- RunLedger.get(store, predecessor["run_id"]),
         {:ok, correction} <- correction_revision(store, run, predecessor_key),
         :ok <- validate_supersession_binding(expected, correction, predecessor),
         nil <- Store.one!(store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [predecessor_key]) do
      persist_supersession(store, predecessor, predecessor_key, successor_key, expected)
    else
      authorization_effect when is_map(authorization_effect) -> {:error, :amendment_authorization_effect_exists}
      {:error, _} = error -> error
    end
  end

  defp validate_supersession_binding(expected, correction, predecessor) do
    same_run = expected["run_id"] == predecessor["run_id"] and expected["chat_key"] == predecessor["chat_key"]

    if expected["proposed_revision"] == correction.revision and same_run,
      do: :ok,
      else: {:error, :amendment_correction_binding_changed}
  end

  defp persist_supersession(store, predecessor, predecessor_key, successor_key, expected) do
    link_json = expected["supersession_json"]
    at = now()
    reject_superseded_command(store, predecessor, predecessor_key, successor_key, link_json, at)
    release_superseded_owner(store, predecessor_key, link_json, at)

    with {:ok, _successor} <- insert_raw(store, expected) do
      insert_supersession_link(store, predecessor_key, successor_key, link_json, at)
      verify_supersession_rows(store, predecessor_key, successor_key)
    end
  end

  defp reject_superseded_command(store, predecessor, predecessor_key, successor_key, link_json, at) do
    receipt = %{
      "status" => "REJECTED",
      "reason" => "SUPERSEDED_BY_CORRECTED_PROPOSAL",
      "command_key" => predecessor_key,
      "input_key" => predecessor["input_key"],
      "successor_command_key" => successor_key,
      "supersession_link_sha256" => digest(link_json)
    }

    Store.query!(store, "UPDATE ticket_chat_commands SET status = 'REJECTED', application_receipt_json = ?, updated_at = ? WHERE command_key = ? AND status = 'ACCEPTED'", [
      Jason.encode!(receipt),
      at,
      predecessor_key
    ])

    require_one_change(store, :amendment_supersession_command_conflict)
  end

  defp release_superseded_owner(store, predecessor_key, link_json, at) do
    Store.query!(
      store,
      "UPDATE ticket_contract_amendments SET phase = 'SUPERSEDED', active_owner = 0, receipt_json = ?, application_receipt_sha256 = ?, updated_at = ? WHERE command_key = ? AND phase = 'RESERVED' AND active_owner = 1",
      [link_json, digest(link_json), at, predecessor_key]
    )

    require_one_change(store, :amendment_supersession_owner_conflict)
  end

  defp insert_supersession_link(store, predecessor_key, successor_key, link_json, at) do
    Store.query!(store, "INSERT INTO ticket_contract_amendment_supersessions(predecessor_command_key, successor_command_key, link_json, link_sha256, created_at) VALUES (?, ?, ?, ?, ?)", [
      predecessor_key,
      successor_key,
      link_json,
      digest(link_json),
      at
    ])
  end

  defp verify_supersession_rows(store, predecessor_key, successor_key) do
    case get(store, successor_key) do
      {:ok, successor} ->
        predecessor =
          Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [predecessor_key])

        if valid_record?(store, predecessor),
          do: {:ok, successor},
          else: Exqlite.rollback(store, :amendment_supersession_link_invalid)

      {:error, reason} ->
        Exqlite.rollback(store, reason)
    end
  end

  defp rows_for_run(store, run_id) do
    Store.query!(store, "SELECT * FROM ticket_contract_amendments WHERE run_id = ? ORDER BY command_key", [run_id])
    |> then(fn %{columns: columns, rows: rows} -> Enum.map(rows, &Map.new(Enum.zip(columns, &1))) end)
  end

  defp valid_lifecycle?(%{"phase" => "RESERVED", "active_owner" => 1, "receipt_json" => nil, "application_receipt_sha256" => nil}), do: true
  defp valid_lifecycle?(%{"phase" => "APPLIED", "active_owner" => 0, "receipt_json" => receipt, "application_receipt_sha256" => sha}) when is_binary(receipt) and is_binary(sha), do: true
  defp valid_lifecycle?(%{"phase" => "SUPERSEDED", "active_owner" => 0, "receipt_json" => receipt, "application_receipt_sha256" => sha}) when is_binary(receipt) and is_binary(sha), do: true
  defp valid_lifecycle?(_amendment), do: false

  defp valid_record?(store, amendment) do
    with true <- valid_lifecycle?(amendment),
         true <- valid_amendment_binding?(amendment),
         true <- valid_lifecycle_references?(store, amendment) do
      true
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  defp valid_lifecycle_references?(store, %{"phase" => "RESERVED"} = amendment) do
    valid_references?(store, amendment) and valid_successor_supersession?(store, amendment) and
      valid_predecessor_supersession?(store, amendment)
  end

  defp valid_lifecycle_references?(store, %{"phase" => "APPLIED"} = amendment) do
    valid_applied_receipt?(store, amendment) and valid_successor_supersession?(store, amendment) and
      valid_predecessor_supersession?(store, amendment)
  end

  defp valid_lifecycle_references?(store, %{"phase" => "SUPERSEDED"} = amendment) do
    valid_superseded_record?(store, amendment) and valid_predecessor_supersession?(store, amendment)
  end

  defp valid_predecessor_supersession?(store, amendment),
    do: valid_predecessor_supersession?(store, amendment, MapSet.new([amendment["command_key"]]))

  defp valid_predecessor_supersession?(_store, %{"supersession_json" => nil}, _seen), do: true

  defp valid_predecessor_supersession?(store, amendment, seen) do
    with {:ok, body} <- Jason.decode(amendment["supersession_json"]),
         predecessor when is_map(predecessor) <- Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [body["predecessor_command_key"]]),
         false <- MapSet.member?(seen, predecessor["command_key"]),
         link when is_map(link) <- Store.one!(store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [body["predecessor_command_key"]]),
         true <- valid_supersession_link?(store, predecessor, amendment, link),
         true <- valid_predecessor_supersession?(store, predecessor, MapSet.put(seen, predecessor["command_key"])) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_successor_supersession?(_store, %{"supersession_json" => nil}), do: true

  defp valid_successor_supersession?(store, amendment) do
    with {:ok, link} <- Jason.decode(amendment["supersession_json"]),
         predecessor when is_map(predecessor) <- Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [link["predecessor_command_key"]]),
         recorded when is_map(recorded) <- Store.one!(store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [link["predecessor_command_key"]]),
         true <- recorded["successor_command_key"] == amendment["command_key"] and recorded["link_json"] == amendment["supersession_json"],
         true <- valid_supersession_link?(store, predecessor, amendment, recorded) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_superseded_record?(store, amendment) do
    case Store.one!(store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [amendment["command_key"]]) do
      link when is_map(link) ->
        case Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [link["successor_command_key"]]) do
          successor when is_map(successor) -> valid_supersession_link?(store, amendment, successor, link)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_supersession_link?(store, predecessor, successor, link) do
    command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [predecessor["command_key"]])
    successor_command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [successor["command_key"]])
    effect = Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [predecessor["command_key"]])
    attempt = Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [predecessor["command_key"]])

    with {:ok, body} <- Jason.decode(link["link_json"]),
         :ok <- valid_link_receipt(predecessor, command, successor, body, link),
         :ok <- valid_link_successor(successor, successor_command, body),
         :ok <- valid_link_predecessor(predecessor, body),
         :ok <- valid_link_draft(effect, body),
         :ok <- valid_link_native_input(store, command, predecessor, body),
         :ok <- valid_link_critic(store, attempt, body) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_link_native_input(store, command, amendment, body) do
    input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [amendment["input_key"]])
    chat = Store.one!(store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [amendment["chat_key"]])

    valid =
      is_map(input) and is_map(chat) and command["status"] == "REJECTED" and
        historical_native_identity_valid?(input, chat, command, amendment, body) and
        historical_native_body_valid?(input, command, amendment) and
        historical_staging_receipt_valid?(input, command, amendment)

    if valid, do: :ok, else: {:error, :supersession_native_input_invalid}
  rescue
    _ -> {:error, :supersession_native_input_invalid}
  end

  defp historical_native_identity_valid?(input, chat, command, amendment, body) do
    input["input_key"] == body["predecessor_input_key"] and digest(Jason.encode!(input)) == body["predecessor_input_sha256"] and
      input["origin"] == "NATIVE_CLIENT_INPUT" and input["chat_key"] == amendment["chat_key"] and
      input["generation"] == amendment["generation"] and input["thread_id"] == chat["thread_id"] and
      input["readback_sha256"] == amendment["readback_sha256"] and digest(command["receipt_json"]) == amendment["admission_sha256"]
  end

  defp historical_native_body_valid?(input, command, amendment) do
    with {:ok, markdown} <- historical_proposal_markdown(command, amendment),
         true <- input["body_sha256"] == command["body_sha256"],
         true <- digest(input["body"] || "") == input["body_sha256"],
         true <- input["body"] == "Revise the contract:\n" <> markdown,
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, input["readback_sha256"] || "") do
      true
    else
      _ -> false
    end
  end

  defp historical_staging_receipt_valid?(input, command, amendment) do
    with {:ok, receipts} when is_map(receipts) <- Jason.decode(input["staging_receipts_json"]),
         receipt when is_map(receipt) <- receipts[command["command_key"]],
         attrs when is_map(attrs) <- receipt["attrs"],
         {:ok, _markdown} <- historical_proposal_markdown(command, amendment) do
      receipt["run_id"] == amendment["run_id"] and receipt["payload_sha256"] == command["payload_sha256"] and
        attrs["proposal_id"] == command["proposal_id"] and attrs["body"] == input["body"]
    else
      _ -> false
    end
  end

  defp historical_proposal_markdown(command, amendment) do
    with true <- digest(command["payload_json"]) == command["payload_sha256"],
         true <- command["payload_sha256"] == amendment["payload_sha256"],
         {:ok, [%{"operation" => "propose_contract_revision", "markdown" => markdown} = operation]} <- Jason.decode(command["payload_json"]),
         true <- map_size(operation) == 2,
         {:ok, normalized} <- Contract.normalize_draft_revision(markdown, amendment["proposed_revision"]),
         true <- normalized == amendment["proposed_contract_markdown"],
         true <- Contract.digest(normalized) == amendment["proposed_contract_sha256"],
         {:ok, false} <- Contract.manual_validation_required(normalized) do
      {:ok, markdown}
    else
      _ -> {:error, :supersession_proposal_invalid}
    end
  end

  defp valid_link_receipt(predecessor, command, successor, body, link) do
    with true <- digest(link["link_json"]) == link["link_sha256"],
         true <- link["successor_command_key"] == successor["command_key"],
         true <- predecessor["receipt_json"] == link["link_json"] and predecessor["application_receipt_sha256"] == link["link_sha256"],
         true <- predecessor["phase"] == "SUPERSEDED" and predecessor["active_owner"] == 0,
         true <- command["status"] == "REJECTED" and body["predecessor_command_key"] == predecessor["command_key"],
         {:ok, application} <- Jason.decode(command["application_receipt_json"]),
         true <-
           application["status"] == "REJECTED" and application["reason"] == "SUPERSEDED_BY_CORRECTED_PROPOSAL" and
             application["successor_command_key"] == successor["command_key"],
         true <- application["supersession_link_sha256"] == link["link_sha256"] do
      :ok
    else
      _ -> {:error, :supersession_receipt_invalid}
    end
  end

  defp valid_link_successor(successor, command, body) do
    valid =
      command["input_key"] == body["successor_input_key"] and successor["input_sha256"] == body["successor_input_sha256"] and
        digest(command["receipt_json"]) == body["successor_admission_sha256"] and successor["readback_sha256"] == body["successor_readback_sha256"] and
        successor["payload_sha256"] == body["successor_payload_sha256"] and successor["proposed_revision"] == body["successor_proposed_revision"] and
        successor["proposed_contract_markdown"] == body["successor_proposed_contract_markdown"] and
        successor["proposed_contract_sha256"] == body["successor_proposed_contract_sha256"]

    if valid, do: :ok, else: {:error, :supersession_successor_invalid}
  end

  defp valid_link_predecessor(predecessor, body) do
    valid =
      body["predecessor_input_key"] == predecessor["input_key"] and body["predecessor_input_sha256"] == predecessor["input_sha256"] and
        predecessor["payload_sha256"] == body["predecessor_payload_sha256"] and
        predecessor["proposed_contract_sha256"] == body["predecessor_proposed_contract_sha256"]

    if valid, do: :ok, else: {:error, :supersession_predecessor_invalid}
  end

  defp valid_link_draft(effect, body) do
    valid =
      effect["phase"] == "READ_BACK" and effect["comment_id"] == body["predecessor_draft_comment_id"] and
        effect["draft_body_sha256"] == body["predecessor_draft_body_sha256"] and
        digest(Jason.encode!(effect)) == body["predecessor_draft_effect_sha256"] and
        effect["readback_sha256"] == body["predecessor_draft_readback_sha256"] and
        effect["readback_json"] == body["predecessor_draft_readback_json"]

    if valid, do: :ok, else: {:error, :supersession_draft_invalid}
  end

  defp valid_link_critic(store, attempt, body) do
    task = if is_map(attempt), do: Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])

    with true <- critic_attempt_task_binding_valid?(attempt, task, body),
         true <- critic_result_is_stopped_nonpass?(attempt) do
      :ok
    else
      _ -> {:error, :supersession_critic_invalid}
    end
  end

  defp critic_attempt_task_binding_valid?(attempt, task, body) when is_map(attempt) and is_map(task) do
    with true <- attempt["phase"] == "RESULT_RECORDED" and attempt["task_key"] == body["predecessor_critic_task_key"],
         true <- attempt["result_sha256"] == body["predecessor_critic_result_sha256"] and digest(attempt["result_json"]) == attempt["result_sha256"],
         true <- digest(Jason.encode!(attempt)) == body["predecessor_critic_attempt_sha256"],
         true <- digest(attempt["snapshot_json"]) == attempt["snapshot_sha256"] and digest(attempt["route_json"]) == attempt["route_sha256"],
         {:ok, route} <- Jason.decode(attempt["route_json"]),
         true <- task_identity_matches?(task, attempt, route) and task_status_matches?(task, attempt),
         {:ok, result} <- Jason.decode(attempt["result_json"]),
         true <- task["output_json"] == Jason.encode!(result["output"]) do
      true
    else
      _ -> false
    end
  end

  defp critic_attempt_task_binding_valid?(_attempt, _task, _body), do: false

  defp critic_result_is_stopped_nonpass?(attempt) do
    with {:ok, result} <- Jason.decode(attempt["result_json"]),
         {:ok, schema} <- Jason.decode(attempt["schema_json"]),
         :ok <- StageSchemas.validate(result["output"], schema),
         true <- result["output"]["status"] in ~w(BLOCK REPAIR) and result["qualifies"] == false,
         true <-
           result["task_key"] == attempt["task_key"] and result["thread_id"] == attempt["worker_thread_id"] and
             result["turn_id"] == attempt["worker_turn_id"] and result["item_id"] == attempt["worker_item_id"],
         {:ok, policy} <- Jason.decode(attempt["worker_policy_json"]),
         true <- policy == AppServer.worker_policy("REVIEW", attempt["owner_cwd"]) and result["policy"] == policy,
         {:ok, stop} <- Jason.decode(attempt["owner_stop_json"]),
         :ok <- validate_owner_stop(stop, attempt) do
      true
    else
      _ -> false
    end
  end

  defp valid_applied_receipt?(store, amendment) do
    command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [amendment["command_key"]])
    input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [amendment["input_key"]])
    association = Store.one!(store, "SELECT * FROM ticket_chat_runs WHERE run_id = ?", [amendment["run_id"]])
    current_run = RunLedger.get(store, amendment["run_id"])

    with receipt when is_map(receipt) <- decode_object(amendment["receipt_json"]),
         true <- digest(amendment["receipt_json"]) == amendment["application_receipt_sha256"],
         command when is_map(command) <- command,
         input when is_map(input) <- input,
         association when is_map(association) <- association,
         true <- command["status"] == "APPLIED" and command["application_receipt_json"] == amendment["receipt_json"],
         true <- valid_applied_receipt_binding?(receipt, amendment, command, input, association),
         :ok <- TicketChatCommands.validate_amendment_answer_replay(store, command, receipt["answer_application_proof"]),
         true <- applied_run_images_valid?(store, receipt, amendment, current_run),
         true <- applied_authority_chain_valid?(store, receipt, amendment),
         true <- blocked_predecessor_receipt_valid?(store, receipt, amendment),
         true <- digest(receipt["protected_rows_json"]) == receipt["protected_rows_sha256"] do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_applied_receipt_binding?(receipt, amendment, command, input, association) do
    with true <- receipt["status"] == "APPLIED",
         true <- receipt["command_key"] == amendment["command_key"] and receipt["run_id"] == amendment["run_id"],
         true <- receipt["chat_key"] == amendment["chat_key"] and receipt["generation"] == amendment["generation"],
         true <- receipt["input_key"] == amendment["input_key"] and receipt["input_sha256"] == amendment["input_sha256"],
         true <- receipt["input_row_sha256"] == digest(Jason.encode!(input)),
         true <- receipt["readback_sha256"] == amendment["readback_sha256"],
         true <- receipt["admission_sha256"] == amendment["admission_sha256"],
         true <- receipt["payload_sha256"] == amendment["payload_sha256"],
         true <- command_binding_matches?(command, amendment, receipt),
         true <- input_binding_matches?(input, amendment),
         true <- association["chat_key"] == amendment["chat_key"],
         true <- amendment_proposal_matches?(receipt, amendment) do
      true
    else
      _ -> false
    end
  end

  defp command_binding_matches?(command, amendment, receipt) do
    command["run_id"] == amendment["run_id"] and command["chat_key"] == amendment["chat_key"] and
      digest(command["receipt_json"]) == amendment["admission_sha256"] and
      digest(command["payload_json"]) == amendment["payload_sha256"] and command["payload_sha256"] == receipt["payload_sha256"]
  end

  defp input_binding_matches?(input, amendment),
    do: input["input_key"] == amendment["input_key"] and input["chat_key"] == amendment["chat_key"] and input["generation"] == amendment["generation"]

  defp amendment_proposal_matches?(receipt, amendment) do
    receipt["prior_binding_json"] == amendment["prior_binding_json"] and
      receipt["prior_revision"] == amendment["prior_revision"] and receipt["prior_contract_sha256"] == amendment["prior_contract_sha256"] and
      receipt["proposed_revision"] == amendment["proposed_revision"] and receipt["proposed_contract_sha256"] == amendment["proposed_contract_sha256"] and
      receipt["proposed_contract_markdown"] == amendment["proposed_contract_markdown"] and receipt["candidate_sha"] == amendment["candidate_sha"]
  end

  defp applied_run_images_valid?(_store, receipt, amendment, {:ok, current_run}) do
    case receipt["application_kind"] do
      "READY_FOR_REVIEW" -> ready_application_images_valid?(receipt, amendment, current_run)
      "BLOCKED_WRITER_HELD" -> blocked_application_images_valid?(receipt, amendment, current_run)
      _ -> false
    end
  end

  defp applied_run_images_valid?(_store, _receipt, _amendment, _run), do: false

  defp ready_application_images_valid?(receipt, amendment, current_run) do
    with {:ok, prior_run} <- Jason.decode(receipt["prior_run_json"]),
         true <- digest(receipt["prior_run_json"]) == receipt["prior_run_sha256"],
         {:ok, applied_run} <- Jason.decode(receipt["applied_run_json"]),
         true <- digest(receipt["applied_run_json"]) == receipt["applied_run_sha256"],
         true <- prior_run["state"] == "READY_FOR_REVIEW",
         true <- prior_run_matches_binding?(prior_run, amendment),
         true <- application_changes_only_authorized_fields?(prior_run, applied_run),
         true <- prior_run["run_id"] == amendment["run_id"] and prior_run["candidate_sha"] == amendment["candidate_sha"],
         true <- prior_run["spec_revision"] == amendment["prior_revision"] and prior_run["contract_sha256"] == amendment["prior_contract_sha256"],
         true <- applied_run["state"] == "VERIFYING" and applied_run["spec_revision"] == amendment["proposed_revision"],
         true <- applied_run["contract_markdown"] == amendment["proposed_contract_markdown"] and applied_run["contract_sha256"] == amendment["proposed_contract_sha256"],
         true <- applied_run["candidate_sha"] == amendment["candidate_sha"] and applied_run["verifier_round"] == receipt["verifier_round"],
         true <- applied_run["manual_validation_required"] == 0,
         true <- applied_run["snapshot_json"] == receipt["authorization_readback_json"],
         true <- digest(receipt["authorization_readback_json"]) == receipt["authorization_readback_sha256"],
         true <- Contract.digest(applied_run["contract_markdown"]) == applied_run["contract_sha256"],
         true <- receipt["verifier_round"] == prior_run["verifier_round"] + 1,
         true <- current_run["issue_key"] == applied_run["issue_key"] and current_run["repo_key"] == applied_run["repo_key"],
         true <- current_run["repo_path"] == applied_run["repo_path"] and current_run["branch"] == applied_run["branch"],
         true <- current_run["worktree"] == applied_run["worktree"],
         true <- current_run["spec_revision"] >= amendment["proposed_revision"],
         true <- current_run["verifier_round"] >= receipt["verifier_round"] do
      true
    else
      _ -> false
    end
  end

  defp blocked_application_images_valid?(receipt, amendment, current_run) do
    with {:ok, prior_run} <- Jason.decode(receipt["prior_run_json"]),
         true <- digest(receipt["prior_run_json"]) == receipt["prior_run_sha256"],
         {:ok, applied_run} <- Jason.decode(receipt["applied_run_json"]),
         true <- digest(receipt["applied_run_json"]) == receipt["applied_run_sha256"],
         true <- prior_run["state"] == "WRITING" and prior_run_matches_binding?(prior_run, amendment),
         true <- application_changes_only_authorized_fields?(prior_run, applied_run),
         true <- prior_run["run_id"] == amendment["run_id"] and prior_run["candidate_sha"] == amendment["candidate_sha"],
         true <- prior_run["spec_revision"] == amendment["prior_revision"] and prior_run["contract_sha256"] == amendment["prior_contract_sha256"],
         true <- applied_run["state"] == "WRITING" and applied_run["spec_revision"] == amendment["proposed_revision"],
         true <- applied_run["contract_markdown"] == amendment["proposed_contract_markdown"] and applied_run["contract_sha256"] == amendment["proposed_contract_sha256"],
         true <- applied_run["candidate_sha"] == amendment["candidate_sha"] and applied_run["verifier_round"] == prior_run["verifier_round"],
         true <- receipt["verifier_round"] == prior_run["verifier_round"],
         true <- applied_run["manual_validation_required"] == 0,
         true <- applied_run["snapshot_json"] == receipt["authorization_readback_json"],
         true <- digest(receipt["authorization_readback_json"]) == receipt["authorization_readback_sha256"],
         true <- Contract.digest(applied_run["contract_markdown"]) == applied_run["contract_sha256"],
         true <- current_run["issue_key"] == applied_run["issue_key"] and current_run["repo_key"] == applied_run["repo_key"],
         true <- current_run["repo_path"] == applied_run["repo_path"] and current_run["branch"] == applied_run["branch"],
         true <- current_run["worktree"] == applied_run["worktree"],
         true <- current_run["spec_revision"] >= amendment["proposed_revision"],
         true <- current_run["verifier_round"] >= receipt["verifier_round"] do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp prior_run_matches_binding?(prior_run, amendment) do
    case decode_object(amendment["prior_binding_json"]) do
      binding when is_map(binding) ->
        fields = ~w(run_id issue_key kind execution_mode state spec_revision contract_sha256 candidate_sha implementation_iteration)
        Map.take(prior_run, fields) == Map.take(binding, fields) and binding["generation"] == amendment["generation"]

      _ ->
        false
    end
  end

  defp application_changes_only_authorized_fields?(prior_run, applied_run) do
    authorized = ~w(spec_revision contract_sha256 contract_markdown snapshot_json manual_validation_required state verifier_round updated_at)
    Map.drop(prior_run, authorized) == Map.drop(applied_run, authorized)
  end

  defp blocked_predecessor_receipt_valid?(_store, %{"application_kind" => "READY_FOR_REVIEW", "blocked_predecessor_json" => nil}, amendment),
    do: amendment["predecessor_json"] == nil

  defp blocked_predecessor_receipt_valid?(store, %{"application_kind" => "BLOCKED_WRITER_HELD"} = receipt, amendment) do
    with predecessor when is_map(predecessor) <- decode_object(receipt["blocked_predecessor_json"]),
         original when is_map(original) <- decode_object(amendment["predecessor_json"]),
         evidence when is_map(evidence) <- decode_object(predecessor["evidence_json"]),
         task when is_map(task) <- decode_object(predecessor["task_json"]),
         access when is_map(access) <- decode_object(predecessor["access_json"]),
         true <- retained_rows_match_original_predecessor?(predecessor, original, evidence, task, access),
         true <- held_or_transferred_predecessor_valid?(store, receipt, predecessor, evidence, task, access),
         true <-
           blocked_disposition_receipt_valid?(
             store,
             receipt,
             amendment,
             predecessor,
             original,
             evidence,
             task,
             access
           ) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp blocked_predecessor_receipt_valid?(_store, _receipt, _amendment), do: false

  defp held_or_transferred_predecessor_valid?(store, receipt, predecessor, evidence, task, access) do
    held =
      row_equals_json?(store, "worker_evidence", "request_key", predecessor["request_key"], predecessor["evidence_json"], predecessor["evidence_sha256"]) and
        row_equals_json?(store, "factory_tasks", "task_key", task["task_key"], predecessor["task_json"], predecessor["task_sha256"]) and
        row_equals_json?(store, "workspace_access", "reservation_key", access["reservation_key"], predecessor["access_json"], predecessor["access_sha256"]) and
        evidence["status"] == "RESULT_RECORDED" and task["status"] == "COMPLETE" and access["released_at"] == nil and
        WorkerEvidence.owner_stopped?(store, evidence)

    held or transferred_predecessor_valid?(store, receipt, evidence, task, access)
  end

  defp transferred_predecessor_valid?(store, receipt, evidence, task, access) do
    live_access = Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [access["reservation_key"]])

    with true <- is_map(live_access) and live_access["released_at"] != nil,
         {:ok, transfer} <- Jason.decode(live_access["release_receipt_json"] || "null"),
         {:ok, command} <- TicketChatCommands.get(store, transfer["command_key"]),
         {:ok, application} <- Jason.decode(command["application_receipt_json"] || "null"),
         new_evidence when is_map(new_evidence) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [transfer["new_request_key"]]),
         true <- transfer_receipt_matches?(store, transfer, receipt, evidence, access),
         true <-
           transfer_command_matches?(
             store,
             transfer,
             command,
             application,
             receipt,
             evidence,
             task,
             new_evidence
           ),
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         true <- receipt["run_id"] == evidence["run_id"] do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp transfer_receipt_matches?(store, transfer, receipt, evidence, access) do
    transfer["kind"] == "BLOCKED_SOURCE_TRANSFER" and transfer["old_request_key"] == evidence["request_key"] and
      transfer["old_reservation_key"] == access["reservation_key"] and transfer["output_sha256"] == evidence["output_sha256"] and
      amendment_is_direct_successor?(store, receipt["command_key"], transfer["amendment_command_key"])
  end

  defp transfer_command_matches?(store, transfer, command, application, receipt, evidence, task, new_evidence) do
    applied_rework_matches?(store, transfer, command, application, receipt) and
      successor_link_matches?(application, receipt, evidence, task, new_evidence)
  end

  defp applied_rework_matches?(store, transfer, command, application, receipt) do
    command["status"] == "APPLIED" and application["kind"] == "BLOCKED_WRITER_RESUMED" and
      transfer["input_key"] == command["input_key"] and transfer["disposition_key"] == application["disposition_key"] and
      amendment_is_direct_successor?(store, receipt["command_key"], application["amendment_command_key"])
  end

  defp amendment_is_direct_successor?(_store, key, key) when is_binary(key), do: true

  defp amendment_is_direct_successor?(store, parent_key, child_key) when is_binary(parent_key) and is_binary(child_key),
    do: amendment_descends_from?(store, parent_key, child_key, %{})

  defp amendment_is_direct_successor?(_store, _parent_key, _child_key), do: false

  @spec amendment_descends_from?(
          Store.connection(),
          String.t(),
          String.t(),
          %{optional(String.t()) => true}
        ) :: boolean()
  defp amendment_descends_from?(store, parent_key, target_key, seen) do
    if Map.has_key?(seen, parent_key),
      do: false,
      else: next_amendment_descendant(store, parent_key, target_key, Map.put(seen, parent_key, true))
  rescue
    _ -> false
  end

  @spec next_amendment_descendant(
          Store.connection(),
          String.t(),
          String.t(),
          %{optional(String.t()) => true}
        ) :: boolean()
  defp next_amendment_descendant(store, parent_key, target_key, seen) do
    parent = Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [parent_key])

    with true <- is_map(parent) and parent["phase"] == "APPLIED" and parent["active_owner"] == 0,
         parent_receipt when is_map(parent_receipt) <- decode_object(parent["receipt_json"]),
         [child] <- amendment_children(store, parent, parent_receipt) do
      if child["command_key"] == target_key,
        do: true,
        else: amendment_descends_from?(store, child["command_key"], target_key, seen)
    else
      _ -> false
    end
  end

  defp amendment_children(store, parent, parent_receipt) do
    amendment_child_candidates(store, parent)
    |> Enum.filter(&valid_amendment_child_link?(store, parent, parent_receipt, &1))
  end

  defp amendment_child_candidates(store, parent) do
    %{columns: columns, rows: child_rows} =
      Store.query!(
        store,
        "SELECT * FROM ticket_contract_amendments WHERE run_id = ? AND phase = 'APPLIED' AND prior_revision = ? AND command_key != ?",
        [parent["run_id"], parent["proposed_revision"], parent["command_key"]]
      )

    Enum.map(child_rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp valid_amendment_child_link?(store, parent, parent_receipt, child) do
    command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [child["command_key"]])
    input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [child["input_key"]])
    association = Store.one!(store, "SELECT * FROM ticket_chat_runs WHERE run_id = ?", [child["run_id"]])
    current_run = RunLedger.get(store, child["run_id"])

    with true <- valid_lifecycle?(child),
         true <- valid_amendment_binding?(child),
         true <- is_map(command) and is_map(input) and is_map(association),
         child_receipt when is_map(child_receipt) <- decode_object(child["receipt_json"]),
         true <- digest(child["receipt_json"]) == child["application_receipt_sha256"],
         true <- command["status"] == "APPLIED" and command["application_receipt_json"] == child["receipt_json"],
         true <- valid_applied_receipt_binding?(child_receipt, child, command, input, association),
         true <- applied_run_images_valid?(store, child_receipt, child, current_run),
         true <- applied_authority_chain_valid?(store, child_receipt, child),
         true <-
           same_source_lineage?(parent, parent_receipt, child, child_receipt) or
             blocked_predecessor_receipt_valid?(store, child_receipt, child),
         true <- digest(child_receipt["protected_rows_json"]) == child_receipt["protected_rows_sha256"],
         true <- child["prior_contract_sha256"] == parent["proposed_contract_sha256"],
         true <- child["prior_contract_markdown"] == parent["proposed_contract_markdown"],
         true <- Map.take(child, ~w(run_id chat_key generation)) == Map.take(parent, ~w(run_id chat_key generation)),
         true <- valid_amendment_transition_link?(parent, parent_receipt, child, child_receipt),
         true <- amendment_proposal_matches?(child_receipt, child) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_amendment_transition_link?(parent, parent_receipt, child, child_receipt) do
    same_source_lineage? = same_source_lineage?(parent, parent_receipt, child, child_receipt)

    case {child_receipt["application_kind"], same_source_lineage?} do
      {"BLOCKED_WRITER_HELD", true} ->
        child["candidate_sha"] == parent["candidate_sha"] and
          child_source_preimage_matches_parent?(parent_receipt, child_receipt, child, false)

      {"BLOCKED_WRITER_HELD", false} ->
        child_source_preimage_matches_parent?(parent_receipt, child_receipt, child, true)

      {"READY_FOR_REVIEW", _} ->
        child_receipt["blocked_predecessor_json"] == nil

      _ ->
        false
    end
  end

  defp same_source_lineage?(parent, parent_receipt, child, child_receipt) do
    child["predecessor_json"] == parent["predecessor_json"] and
      child_receipt["blocked_predecessor_json"] == parent_receipt["blocked_predecessor_json"]
  end

  defp child_source_preimage_matches_parent?(parent_receipt, child_receipt, child, fresh_lineage?) do
    with parent_run when is_map(parent_run) <- decode_object(parent_receipt["applied_run_json"]),
         child_run when is_map(child_run) <- decode_object(child_receipt["prior_run_json"]),
         true <- child_run["run_id"] == child["run_id"],
         true <- child_run["spec_revision"] == parent_run["spec_revision"],
         true <- child_run["contract_sha256"] == parent_run["contract_sha256"],
         true <- child_run["contract_markdown"] == parent_run["contract_markdown"],
         true <- child_run["candidate_sha"] == child["candidate_sha"],
         true <-
           Map.take(child_run, ~w(run_id issue_key kind execution_mode repo_key repo_path worktree branch spec_revision contract_sha256 contract_markdown)) ==
             Map.take(parent_run, ~w(run_id issue_key kind execution_mode repo_key repo_path worktree branch spec_revision contract_sha256 contract_markdown)),
         true <- fresh_lineage? or child_run["candidate_sha"] == parent_run["candidate_sha"] do
      true
    else
      _ -> false
    end
  end

  defp successor_link_matches?(application, _receipt, evidence, task, new_evidence) do
    application["prior_request_key"] == evidence["request_key"] and application["request_key"] == new_evidence["request_key"] and
      application["reservation_key"] == new_evidence["reservation_key"] and new_evidence["task_key"] == task["task_key"] and
      new_evidence["run_id"] == evidence["run_id"] and application["output_sha256"] == evidence["output_sha256"]
  end

  defp retained_rows_match_original_predecessor?(predecessor, original, evidence, task, access) do
    retained_row_snapshots_match?(predecessor, original) and
      evidence["request_key"] == original["request_key"] and evidence["output_sha256"] == original["output_sha256"] and
      evidence["binding_json"] == predecessor["binding_json"] and evidence["binding_sha256"] == original["binding_sha256"] and
      digest(evidence["owner_stop_json"]) == original["owner_stop_sha256"] and
      task["task_key"] == original["task_key"] and access["reservation_key"] == original["reservation_key"]
  end

  defp retained_row_snapshots_match?(predecessor, original) do
    fields = ~w(request_key evidence_sha256 task_sha256 access_sha256 output_sha256)

    Map.take(predecessor, fields) == Map.take(original, fields) and
      retained_row_json_digests_match?(predecessor, original) and
      retained_head_matches?(predecessor, original)
  end

  defp retained_head_matches?(predecessor, original) do
    case {Map.fetch(original, "checkout_head_sha"), Map.fetch(predecessor, "checkout_head_sha")} do
      {{:ok, head}, {:ok, head}} when is_binary(head) -> valid_hash?(head, 40)
      {:error, :error} -> true
      _ -> false
    end
  end

  defp retained_row_json_digests_match?(predecessor, original) do
    Enum.all?([{"evidence_json", "evidence_sha256"}, {"task_json", "task_sha256"}, {"access_json", "access_sha256"}], fn {json_field, digest_field} ->
      digest(predecessor[json_field]) == original[digest_field]
    end)
  end

  defp blocked_disposition_receipt_valid?(store, receipt, amendment, predecessor, original, evidence, task, access) do
    with {:ok, reference} <- Base.url_decode64(original["artifact_ref"], padding: false),
         {:ok, %{"kind" => "event", "id" => event_id, "sha256" => event_sha}} <- Jason.decode(reference),
         prior_run when is_map(prior_run) <- decode_object(receipt["prior_run_json"]),
         {:ok, source_run} <- amendment_source_preimage(store, amendment, prior_run, receipt),
         event when is_map(event) <-
           Store.one!(store, "SELECT id, payload_json FROM events WHERE id = ? AND run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'", [event_id, amendment["run_id"]]),
         true <- event["payload_json"] == predecessor["disposition_json"] and digest(event["payload_json"]) == event_sha,
         true <- event["id"] == predecessor["disposition_event_id"] and digest(event["payload_json"]) == predecessor["disposition_sha256"],
         {:ok, disposition} <- Jason.decode(event["payload_json"]),
         true <- disposition["request_key"] == evidence["request_key"] and disposition["output_sha256"] == evidence["output_sha256"],
         true <- disposition["task_key"] == task["task_key"] and disposition["reservation_key"] == access["reservation_key"],
         true <- disposition["run_binding"] == Map.take(source_run, ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch)) do
      true
    else
      _ -> false
    end
  end

  defp row_equals_json?(store, table, key_column, key, raw, sha) do
    row = Store.one!(store, "SELECT * FROM #{table} WHERE #{key_column} = ?", [key])
    is_map(row) and Jason.encode!(row) == raw and digest(raw) == sha
  end

  defp applied_authority_chain_valid?(store, receipt, amendment) do
    draft = Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [amendment["command_key"]])
    authorization = Store.one!(store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [amendment["command_key"]])
    attempt = Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [amendment["command_key"]])

    with draft when is_map(draft) <- draft,
         authorization when is_map(authorization) <- authorization,
         attempt when is_map(attempt) <- attempt,
         true <- Jason.encode!(draft) == receipt["draft_effect_json"],
         true <- digest(receipt["draft_effect_json"]) == receipt["draft_effect_sha256"],
         true <- Jason.encode!(authorization) == receipt["authorization_effect_json"],
         true <- digest(receipt["authorization_effect_json"]) == receipt["authorization_effect_sha256"],
         true <- Jason.encode!(attempt) == receipt["critic_attempt_json"],
         true <- digest(receipt["critic_attempt_json"]) == receipt["critic_attempt_sha256"],
         task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]]),
         true <- Jason.encode!(task) == receipt["critic_task_json"],
         true <- digest(receipt["critic_task_json"]) == receipt["critic_task_sha256"],
         true <- draft["phase"] == "READ_BACK" and draft["readback_sha256"] == digest(draft["readback_json"]),
         true <- authorization["phase"] == "READ_BACK" and authorization["readback_json"] == receipt["authorization_readback_json"],
         true <- authorization["readback_sha256"] == receipt["authorization_readback_sha256"],
         true <- digest(authorization["readback_json"]) == authorization["readback_sha256"],
         true <- attempt["phase"] == "RESULT_RECORDED" and attempt["result_sha256"] == authorization["critic_result_sha256"],
         {:ok, result} <- Jason.decode(attempt["result_json"]),
         true <- digest(attempt["result_json"]) == attempt["result_sha256"],
         output when is_map(output) <- result["output"],
         true <- output["status"] == "PASS" and output["findings"] == [] and output["required_questions"] == [] and result["qualifies"] == true,
         output_sha <- digest(Jason.encode!(output)),
         true <- output_sha == authorization["critic_output_sha256"],
         binding when is_map(binding) <- decode_object(amendment["prior_binding_json"]),
         proposed <- Contract.bind(binding["issue_key"], amendment["proposed_revision"], amendment["proposed_contract_markdown"]),
         {:ok, false} <- Contract.manual_validation_required(proposed.markdown),
         {:ok, snapshot} <- Jason.decode(authorization["readback_json"]),
         {:ok, authorized} <- Contract.authorized_from_snapshot(snapshot, proposed.issue_key),
         true <- authorized == proposed,
         {:ok, proof} <- Contract.automatic_authorization_proof(snapshot, proposed),
         true <- proof == %{critic_task_key: attempt["task_key"], critic_output_sha256: output_sha} do
      validate_applied_draft_snapshot(draft, authorization, receipt, amendment, proposed, attempt)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp validate_applied_draft_snapshot(draft, authorization, receipt, amendment, proposed, attempt) do
    with {:ok, prior_run} <- Jason.decode(receipt["prior_run_json"]),
         {:ok, prior_snapshot} <- Jason.decode(prior_run["snapshot_json"]),
         {:ok, draft_snapshot} <- Jason.decode(draft["readback_json"]),
         {:ok, authorization_snapshot} <- Jason.decode(authorization["readback_json"]),
         true <- draft["source_preimage_json"] == prior_run["snapshot_json"],
         true <- draft["readback_json"] == authorization["draft_readback_json"],
         {:ok, publication_baseline} <- publication_snapshot(amendment, prior_snapshot),
         true <- draft["publication_preimage_json"] == Jason.encode!(publication_baseline),
         proposed_draft <- Contract.draft_comment(proposed),
         {:ok, draft_comment_id} <- exact_added_comment_id(draft_snapshot, publication_baseline, proposed_draft),
         true <- draft_comment_id == draft["comment_id"],
         true <- Contract.draft_read_back?(draft_snapshot, proposed),
         true <- Contract.next_revision(draft_snapshot) == proposed.revision + 1,
         true <- not Contract.authorized?(draft_snapshot, proposed),
         true <- Map.drop(authorization_snapshot, ["comments", "updated"]) == Map.drop(draft_snapshot, ["comments", "updated"]),
         auth_body <- Contract.automatic_authorization_marker(proposed, attempt["task_key"], authorization["critic_output_sha256"]),
         {:ok, auth_comment_id} <- exact_added_comment_id(authorization_snapshot, draft_snapshot, auth_body),
         true <- auth_comment_id == authorization["comment_id"] do
      is_binary(authorization_snapshot["updated"])
    else
      _ -> false
    end
  end

  defp publication_snapshot(%{"supersession_json" => nil}, prior_snapshot), do: {:ok, prior_snapshot}

  defp publication_snapshot(amendment, _prior_snapshot) do
    with {:ok, link} <- Jason.decode(amendment["supersession_json"]),
         raw when is_binary(raw) <- link["predecessor_draft_readback_json"],
         true <- digest(raw) == link["predecessor_draft_readback_sha256"],
         {:ok, snapshot} <- Jason.decode(raw) do
      {:ok, snapshot}
    else
      _ -> {:error, :amendment_supersession_baseline_invalid}
    end
  end

  defp exact_added_comment_id(snapshot, baseline, body) do
    current_comments = snapshot["comments"]
    baseline_comments = baseline["comments"]
    additions = current_comments -- baseline_comments
    matching = Enum.filter(additions, &(is_map(&1) and &1["text"] == body and is_binary(&1["id"]) and &1["id"] != ""))

    if length(additions) == 1 and length(matching) == 1 and
         comment_fingerprints(current_comments -- matching) == comment_fingerprints(baseline_comments),
       do: {:ok, hd(matching)["id"]},
       else: {:error, :amendment_historical_comment_mismatch}
  end

  defp comment_fingerprints(comments),
    do: Enum.map(comments, &{&1["id"], &1["text"]}) |> Enum.sort()

  defp valid_amendment_binding?(amendment) do
    with binding when is_map(binding) <- decode_object(amendment["prior_binding_json"]),
         true <- map_size(binding) == 10,
         true <- valid_contract_preimage?(amendment),
         true <- Enum.all?(~w(input_sha256 readback_sha256 admission_sha256 payload_sha256), &valid_hash?(amendment[&1], 64)),
         true <- binding_matches?(binding, amendment),
         true <- valid_predecessor?(amendment["predecessor_json"], binding["state"], amendment["candidate_sha"]) do
      true
    else
      _ -> false
    end
  end

  defp valid_contract_preimage?(amendment) do
    amendment["generation"] > 0 and valid_revision_transition?(amendment) and
      valid_candidate_binding?(amendment) and
      Contract.digest(amendment["prior_contract_markdown"]) == amendment["prior_contract_sha256"] and
      Contract.digest(amendment["proposed_contract_markdown"]) == amendment["proposed_contract_sha256"]
  end

  defp valid_revision_transition?(%{"supersession_json" => nil} = amendment),
    do: amendment["proposed_revision"] == amendment["prior_revision"] + 1

  defp valid_revision_transition?(amendment) do
    case Jason.decode(amendment["supersession_json"]) do
      {:ok, link} ->
        link["successor_command_key"] == amendment["command_key"] and
          link["successor_proposed_revision"] == amendment["proposed_revision"] and
          amendment["proposed_revision"] > amendment["prior_revision"] + 1

      _ ->
        false
    end
  end

  defp valid_references?(store, amendment) do
    command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [amendment["command_key"]])
    input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [amendment["input_key"]])
    association = Store.one!(store, "SELECT * FROM ticket_chat_runs WHERE run_id = ?", [amendment["run_id"]])

    with command when is_map(command) <- command,
         input when is_map(input) <- input,
         association when is_map(association) <- association,
         true <- valid_command_reference?(command, amendment),
         true <- valid_input_reference?(input, amendment),
         true <- association["chat_key"] == amendment["chat_key"] do
      true
    else
      _ -> false
    end
  end

  defp valid_command_reference?(command, amendment) do
    admission = decode_object(command["receipt_json"])

    command_binding_matches?(command, amendment) and admission_matches?(admission, command, amendment) and
      payload_matches?(command, amendment) and valid_payload_proposal?(command, amendment)
  end

  defp command_binding_matches?(command, amendment),
    do:
      command["status"] == "ACCEPTED" and command["run_id"] == amendment["run_id"] and
        command["chat_key"] == amendment["chat_key"] and command["input_key"] == amendment["input_key"]

  defp admission_matches?(admission, command, amendment),
    do:
      is_map(admission) and admission["status"] == "ACCEPTED" and admission["input_key"] == amendment["input_key"] and
        digest(command["receipt_json"]) == amendment["admission_sha256"]

  defp payload_matches?(command, amendment),
    do:
      digest(command["payload_json"]) == command["payload_sha256"] and
        command["payload_sha256"] == amendment["payload_sha256"]

  defp valid_payload_proposal?(command, amendment) do
    with {:ok, operations} <- Jason.decode(command["payload_json"]),
         [%{"operation" => "propose_contract_revision", "markdown" => markdown} = operation] <- [List.last(operations)],
         true <- map_size(operation) == 2 and length(operations) in 1..4,
         true <- Enum.all?(Enum.drop(operations, -1), &valid_answer_operation?/1),
         true <- length(Enum.map(Enum.drop(operations, -1), & &1["question_key"])) == length(Enum.uniq(Enum.map(Enum.drop(operations, -1), & &1["question_key"]))),
         {:ok, normalized} <- Contract.normalize_draft_revision(markdown, amendment["proposed_revision"]),
         true <- normalized == amendment["proposed_contract_markdown"],
         true <- Contract.digest(normalized) == amendment["proposed_contract_sha256"],
         {:ok, false} <- Contract.manual_validation_required(normalized) do
      true
    else
      _ -> false
    end
  end

  defp valid_answer_operation?(%{"operation" => "answer_question", "question_key" => key, "value" => _value, "question_digest" => sha} = operation),
    do: map_size(operation) == 4 and is_binary(key) and key != "" and is_binary(sha) and valid_hash?(sha, 64)

  defp valid_answer_operation?(_), do: false

  defp valid_input_reference?(input, amendment) do
    digest(Jason.encode!(input)) == amendment["input_sha256"] and
      input["readback_sha256"] == amendment["readback_sha256"] and input["chat_key"] == amendment["chat_key"] and
      input["generation"] == amendment["generation"]
  end

  defp binding_matches?(binding, amendment) do
    binding["run_id"] == amendment["run_id"] and binding["generation"] == amendment["generation"] and
      binding["kind"] == "DELIVERY" and binding["execution_mode"] == "TICKET_SUPERVISOR_V1" and
      binding["state"] in ~w(READY_FOR_REVIEW WRITING) and binding["spec_revision"] == amendment["prior_revision"] and
      binding["contract_sha256"] == amendment["prior_contract_sha256"] and binding["candidate_sha"] == amendment["candidate_sha"]
  end

  defp valid_candidate_binding?(%{"candidate_sha" => sha}) when is_binary(sha), do: valid_hash?(sha, 40)

  defp valid_candidate_binding?(%{"candidate_sha" => nil, "prior_binding_json" => raw}) do
    case Jason.decode(raw) do
      {:ok, %{"state" => "WRITING"}} -> true
      _ -> false
    end
  end

  defp valid_candidate_binding?(_), do: false

  defp valid_predecessor?(nil, "READY_FOR_REVIEW", _candidate_sha), do: true

  defp valid_predecessor?(raw, "WRITING", candidate_sha) when is_binary(raw) do
    with {:ok, predecessor} <- Jason.decode(raw),
         true <-
           is_map(predecessor) and
             (map_size(predecessor) == 12 or (is_nil(candidate_sha) and map_size(predecessor) == 13)),
         true <- predecessor["status"] == "BLOCKED",
         true <- Enum.all?(~w(output_sha256 binding_sha256 owner_stop_sha256 task_sha256 evidence_sha256 access_sha256), &valid_hash?(predecessor[&1], 64)),
         true <- (not is_nil(candidate_sha) and not Map.has_key?(predecessor, "checkout_head_sha")) or valid_hash?(predecessor["checkout_head_sha"], 40),
         true <- Enum.all?(~w(run_id request_key artifact_ref task_key reservation_key), &is_binary(predecessor[&1])) do
      true
    else
      _ -> false
    end
  end

  defp valid_predecessor?(_raw, _state, _candidate_sha), do: false

  defp decode_object(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, object} when is_map(object) -> object
      _ -> :error
    end
  end

  defp decode_object(_raw), do: :error

  defp valid_hash?(value, length),
    do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp insert(store, expected) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    fields = Map.keys(expected)
    columns = Enum.join(fields, ", ")
    placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)

    Store.query!(store, "INSERT INTO ticket_contract_amendments(#{columns}, created_at, updated_at) VALUES (#{placeholders}, ?, ?)", Enum.map(fields, &Map.fetch!(expected, &1)) ++ [at, at])

    get(store, expected["command_key"])
  rescue
    Exqlite.Error -> {:error, :amendment_reservation_conflict}
  end

  defp insert_raw(store, expected) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    fields = Map.keys(expected)
    columns = Enum.join(fields, ", ")
    placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)
    Store.query!(store, "INSERT INTO ticket_contract_amendments(#{columns}, created_at, updated_at) VALUES (#{placeholders}, ?, ?)", Enum.map(fields, &Map.fetch!(expected, &1)) ++ [at, at])
    {:ok, Store.one!(store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [expected["command_key"]])}
  rescue
    Exqlite.Error -> {:error, :amendment_reservation_conflict}
  end

  @spec controller_context_matches(map(), map()) :: :ok | {:error, :stale_controller_context}
  def controller_context_matches(context, validated) do
    expected = %{
      "chat_key" => validated.chat["chat_key"],
      "run_id" => validated.run["run_id"],
      "binding" => Map.take(validated.run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", validated.chat["generation"])
    }

    if context == expected, do: :ok, else: {:error, :stale_controller_context}
  end

  defp transaction(store, fun) do
    case Exqlite.transaction(store, &rollback_error(&1, fun.(&1))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
