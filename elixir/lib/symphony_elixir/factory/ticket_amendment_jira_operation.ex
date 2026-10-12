defmodule SymphonyElixir.Factory.TicketAmendmentJiraOperation do
  @moduledoc "Publishes and reads back one exact ticket-contract amendment draft comment."

  alias Exqlite
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{Contract, JiraMcpConnector, JiraMcpReader, Store, TicketContractAmendment}

  @effect_identity_fields ~w(command_key run_id chat_key generation input_key input_sha256 prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_markdown proposed_contract_sha256 issue_key issue_id draft_body draft_body_sha256 source_preimage_json source_preimage_sha256 publication_preimage_json preflight_json preflight_sha256)

  @spec publish_draft(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_draft(store, command_key, controller_context, opts) do
    workspace = Keyword.get(opts, :workspace)
    session = Keyword.get(opts, :jira_session, &AppServer.with_jira_controller_session/2)

    if is_binary(workspace) and is_function(session, 2) do
      session.(workspace, fn
        %{thread_id: thread_id} = mcp_session when is_binary(thread_id) and thread_id != "" ->
          scoped = Keyword.put(opts, :mcp_session, mcp_session)
          publish_in_session(store, command_key, controller_context, scoped)

        _ ->
          {:error, :amendment_jira_session_unproven}
      end)
    else
      {:error, :amendment_jira_session_unproven}
    end
  end

  @spec readback(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def readback(store, command_key) do
    with {:ok, validated, amendment} <- TicketContractAmendment.validate_current(store, command_key),
         row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key]),
         :ok <- validate_effect(row, validated, amendment),
         true <- row["phase"] == "READ_BACK" or {:error, :amendment_jira_readback_not_recorded},
         :ok <- valid_readback(row["readback_json"], row["publication_preimage_json"], validated, amendment),
         {:ok, comment_id} <- readback_comment_id(row["readback_json"], row["publication_preimage_json"], validated, amendment),
         true <- row["comment_id"] == comment_id or {:error, :amendment_jira_receipt_corrupt},
         true <-
           (row["readback_sha256"] == digest(row["readback_json"]) and row["observed_json"] == row["readback_json"] and
              row["observed_sha256"] == row["readback_sha256"]) or {:error, :amendment_jira_receipt_corrupt} do
      {:ok, row}
    else
      nil -> {:error, :amendment_jira_effect_missing}
      {:error, _} = error -> error
    end
  end

  @spec publish_authorization(Store.connection(), String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def publish_authorization(store, command_key, controller_context, model_policy, opts) do
    workspace = Keyword.get(opts, :workspace)
    session = Keyword.get(opts, :jira_session, &AppServer.with_jira_controller_session/2)

    if is_binary(workspace) and is_function(session, 2) do
      session.(workspace, fn
        %{thread_id: thread_id} = mcp_session when is_binary(thread_id) and thread_id != "" ->
          scoped = Keyword.put(opts, :mcp_session, mcp_session)
          publish_authorization_in_session(store, command_key, controller_context, model_policy, scoped)

        _ ->
          {:error, :amendment_jira_session_unproven}
      end)
    else
      {:error, :amendment_jira_session_unproven}
    end
  end

  @spec readback_authorization(Store.connection(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def readback_authorization(store, command_key, controller_context, model_policy) do
    with {:ok, binding} <- current_authorization_binding(store, command_key, controller_context, model_policy),
         row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key]),
         :ok <- validate_authorization_effect(row, binding),
         true <- row["phase"] == "READ_BACK" or {:error, :amendment_authorization_readback_not_recorded},
         true <- row["readback_sha256"] == digest(row["readback_json"]) or {:error, :amendment_authorization_receipt_corrupt},
         true <- (row["observed_json"] == row["readback_json"] and row["observed_sha256"] == row["readback_sha256"]) or {:error, :amendment_authorization_receipt_corrupt},
         {:ok, comment_id} <- validate_authorization_readback(row["readback_json"], binding),
         true <- row["comment_id"] == comment_id or {:error, :amendment_authorization_receipt_corrupt} do
      {:ok, row}
    else
      nil -> {:error, :amendment_authorization_effect_missing}
      {:error, _} = error -> error
    end
  end

  defp publish_authorization_in_session(store, command_key, context, policy, opts) do
    with {:ok, binding} <- current_authorization_binding(store, command_key, context, policy),
         {:ok, source_json} <- read_issue(binding.validated.run, opts),
         {:ok, effect} <- prepare_authorization_effect(store, command_key, context, policy, binding, source_json) do
      advance_authorization(store, command_key, context, policy, effect, source_json, opts)
    end
  end

  defp current_authorization_binding(store, command_key, context, model_policy) do
    with {:ok, validated, amendment} <- TicketContractAmendment.validate_current(store, command_key, context),
         true <- amendment["phase"] == "RESERVED" or {:error, :invalid_contract_amendment},
         {:ok, draft} <- readback(store, command_key),
         {:ok, attempt} <- TicketContractAmendment.get_critic_attempt(store, command_key, model_policy),
         true <- attempt["phase"] == "RESULT_RECORDED" or {:error, :critic_result_not_recorded},
         true <- attempt["snapshot_json"] == draft["readback_json"] or {:error, :amendment_readback_receipt_mismatch},
         {:ok, result} <- Jason.decode(attempt["result_json"]),
         output when is_map(output) <- result["output"],
         true <-
           (output["status"] == "PASS" and output["findings"] == [] and output["required_questions"] == [] and
              result["qualifies"] == true) or {:error, :critic_not_authorizing},
         proposed <- Contract.bind(validated.run["issue_key"], amendment["proposed_revision"], amendment["proposed_contract_markdown"]),
         {:ok, false} <- Contract.manual_validation_required(proposed.markdown),
         {:ok, snapshot} <- decode_snapshot(draft["readback_json"]),
         true <- not Contract.authorized?(snapshot, proposed) or {:error, :amendment_already_authorized} do
      output_sha256 = digest(Jason.encode!(output))
      body = Contract.automatic_authorization_marker(proposed, attempt["task_key"], output_sha256)

      {:ok,
       %{
         validated: validated,
         amendment: amendment,
         draft: draft,
         attempt: attempt,
         result: result,
         output: output,
         proposed: proposed,
         output_sha256: output_sha256,
         body: body,
         binding: authorization_binding(validated, amendment, draft, attempt, output_sha256, body)
       }}
    else
      {:ok, true} -> {:error, :manual_validation_required}
      {:error, _} = error -> error
      _ -> {:error, :critic_not_authorizing}
    end
  end

  defp authorization_binding(validated, amendment, draft, attempt, output_sha256, body) do
    %{
      "command_key" => amendment["command_key"],
      "run_id" => amendment["run_id"],
      "chat_key" => amendment["chat_key"],
      "generation" => amendment["generation"],
      "input_key" => amendment["input_key"],
      "input_sha256" => amendment["input_sha256"],
      "prior_revision" => amendment["prior_revision"],
      "prior_contract_sha256" => amendment["prior_contract_sha256"],
      "candidate_sha" => amendment["candidate_sha"],
      "proposed_revision" => amendment["proposed_revision"],
      "proposed_contract_markdown" => amendment["proposed_contract_markdown"],
      "proposed_contract_sha256" => amendment["proposed_contract_sha256"],
      "issue_key" => validated.run["issue_key"],
      "issue_id" => draft["issue_id"],
      "critic_task_key" => attempt["task_key"],
      "critic_result_sha256" => attempt["result_sha256"],
      "critic_output_sha256" => output_sha256,
      "draft_comment_id" => draft["comment_id"],
      "draft_readback_json" => draft["readback_json"],
      "draft_readback_sha256" => draft["readback_sha256"],
      "authorization_body" => body,
      "authorization_body_sha256" => digest(body)
    }
  end

  defp prepare_authorization_effect(store, command_key, context, policy, binding, source_json) do
    transaction(store, fn tx ->
      with {:ok, current} <- current_authorization_binding(tx, command_key, context, policy),
           true <- current.binding == binding.binding or {:error, :amendment_authorization_binding_changed} do
        existing = Store.one!(tx, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key])
        prepare_authorization_row(tx, existing, command_key, binding, source_json)
      end
    end)
  end

  defp prepare_authorization_row(store, nil, _command_key, binding, source_json) do
    with {:ok, source} <- decode_snapshot(source_json),
         :ok <- validate_authorization_preflight(source_json, source, binding) do
      insert_authorization_effect(store, binding.binding)
    end
  end

  defp prepare_authorization_row(_store, existing, _command_key, binding, _source_json) do
    with :ok <- validate_authorization_effect(existing, binding), do: {:ok, existing}
  end

  defp insert_authorization_effect(store, binding) do
    at = now()
    fields = Map.keys(binding)
    columns = Enum.join(fields, ", ")
    placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)

    Store.query!(
      store,
      "INSERT INTO ticket_amendment_authorization_effects(#{columns}, phase, created_at, updated_at) VALUES (#{placeholders}, 'PENDING', ?, ?)",
      Enum.map(fields, &Map.fetch!(binding, &1)) ++ [at, at]
    )

    {:ok, Store.one!(store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [binding["command_key"]])}
  end

  defp advance_authorization(store, command_key, context, policy, %{"phase" => "READ_BACK"}, _source, _opts),
    do: readback_authorization(store, command_key, context, policy)

  defp advance_authorization(store, command_key, context, policy, %{"phase" => phase} = effect, source_json, opts)
       when phase in ["PENDING", "UNCERTAIN"] do
    with {:ok, binding} <- current_authorization_binding(store, command_key, context, policy) do
      case validate_authorization_readback(source_json, binding) do
        {:ok, comment_id} ->
          record_authorization_readback(store, command_key, context, policy, effect, source_json, comment_id)

        {:error, reason} ->
          handle_unverified_authorization_source(
            store,
            command_key,
            context,
            policy,
            effect,
            source_json,
            opts,
            reason
          )
      end
    end
  end

  defp advance_authorization(_store, _command_key, _context, _policy, _effect, _source, _opts),
    do: {:error, :amendment_authorization_effect_invalid}

  defp handle_unverified_authorization_source(store, command_key, context, policy, effect, source_json, opts, reason) do
    if effect["phase"] == "UNCERTAIN" do
      record_authorization_observation(store, command_key, context, policy, effect, source_json, reason)

      if source_json == effect["draft_readback_json"],
        do: {:error, :amendment_authorization_outcome_uncertain},
        else: {:error, :amendment_authorization_reconciliation_required}
    else
      if source_json == effect["draft_readback_json"] do
        perform_authorization_write(store, command_key, context, policy, effect, source_json, opts)
      else
        record_authorization_observation(store, command_key, context, policy, effect, source_json, reason)
        {:error, :amendment_authorization_preimage_changed}
      end
    end
  end

  defp perform_authorization_write(store, command_key, context, policy, effect, source_json, opts) do
    connector = Keyword.get(opts, :jira_connector, JiraMcpConnector)
    args = %{"issue_key" => effect["issue_key"], "body" => effect["authorization_body"]}

    with :ok <- connector.validate_call("jira_add_comment", args, opts),
         :ok <- AppServer.check_ticket_runtime(opts[:workspace]),
         {:ok, _claimed} <- claim_authorization(store, command_key, context, policy, effect, source_json) do
      _write_result = call_write(connector, "jira_add_comment", args, opts)
      finish_authorization_write(store, command_key, context, policy, effect, opts)
    end
  end

  defp claim_authorization(store, command_key, context, policy, _effect, source_json) do
    transaction(store, fn tx ->
      with {:ok, binding} <- current_authorization_binding(tx, command_key, context, policy),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_authorization_effect(current, binding),
           true <-
             authorization_identity_matches?(current, binding) or
               {:error, :amendment_authorization_effect_changed},
           true <- current["phase"] == "PENDING" or {:error, :amendment_authorization_outcome_uncertain},
           true <- source_json == binding.draft["readback_json"] or {:error, :amendment_authorization_preimage_changed} do
        claim_authorization_write(tx, command_key, source_json)
      end
    end)
  end

  defp claim_authorization_write(store, command_key, source_json) do
    Store.query!(
      store,
      "UPDATE ticket_amendment_authorization_effects SET phase = 'UNCERTAIN', claimed_at = ?, observed_json = ?, observed_sha256 = ?, last_error = NULL, updated_at = ? WHERE command_key = ? AND phase = 'PENDING'",
      [now(), source_json, digest(source_json), now(), command_key]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] == 1,
      do: {:ok, Store.one!(store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key])},
      else: Exqlite.rollback(store, :amendment_authorization_outcome_uncertain)
  end

  defp finish_authorization_write(store, command_key, context, policy, effect, opts) do
    case read_issue(%{"issue_key" => effect["issue_key"]}, opts) do
      {:ok, source_json} ->
        with {:ok, binding} <- current_authorization_binding(store, command_key, context, policy),
             {:ok, comment_id} <- validate_authorization_readback(source_json, binding),
             {:ok, receipt} <-
               record_authorization_readback(store, command_key, context, policy, effect, source_json, comment_id) do
          {:ok, receipt}
        else
          {:error, reason} ->
            record_authorization_observation(store, command_key, context, policy, effect, source_json, reason)
            {:error, :amendment_authorization_outcome_uncertain}
        end

      {:error, reason} ->
        record_authorization_error(store, command_key, context, policy, effect, reason)
        {:error, :amendment_authorization_readback_unavailable}
    end
  end

  defp record_authorization_readback(store, command_key, context, policy, _effect, source_json, comment_id) do
    transaction(store, fn tx ->
      with {:ok, binding} <- current_authorization_binding(tx, command_key, context, policy),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_authorization_effect(current, binding),
           true <-
             authorization_identity_matches?(current, binding) or
               {:error, :amendment_authorization_effect_changed},
           true <- current["phase"] in ["PENDING", "UNCERTAIN"] or {:error, :amendment_authorization_effect_changed},
           {:ok, current_comment_id} <- validate_authorization_readback(source_json, binding),
           true <- current_comment_id == comment_id or {:error, :amendment_authorization_comment_changed} do
        persist_authorization_readback(tx, command_key, source_json, comment_id)
      end
    end)
  end

  defp persist_authorization_readback(store, command_key, source_json, comment_id) do
    Store.query!(
      store,
      "UPDATE ticket_amendment_authorization_effects SET phase = 'READ_BACK', observed_json = ?, observed_sha256 = ?, readback_json = ?, readback_sha256 = ?, comment_id = ?, last_error = NULL, updated_at = ? WHERE command_key = ? AND phase IN ('PENDING', 'UNCERTAIN')",
      [source_json, digest(source_json), source_json, digest(source_json), comment_id, now(), command_key]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] == 1,
      do: {:ok, Store.one!(store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key])},
      else: Exqlite.rollback(store, :amendment_authorization_effect_changed)
  end

  defp record_authorization_observation(store, command_key, context, policy, _effect, source_json, reason) do
    transaction(store, fn tx ->
      with {:ok, binding} <- current_authorization_binding(tx, command_key, context, policy),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_authorization_effect(current, binding),
           true <-
             authorization_identity_matches?(current, binding) or
               {:error, :amendment_authorization_effect_changed},
           true <- current["phase"] in ["PENDING", "UNCERTAIN"] or {:error, :amendment_authorization_effect_changed} do
        Store.query!(
          tx,
          "UPDATE ticket_amendment_authorization_effects SET observed_json = ?, observed_sha256 = ?, last_error = ?, updated_at = ? WHERE command_key = ? AND phase IN ('PENDING', 'UNCERTAIN')",
          [source_json, digest(source_json), inspect(reason), now(), command_key]
        )

        :ok
      end
    end)
  end

  defp record_authorization_error(store, command_key, context, policy, _effect, reason) do
    transaction(store, fn tx ->
      with {:ok, binding} <- current_authorization_binding(tx, command_key, context, policy),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_authorization_effect(current, binding),
           true <-
             (authorization_identity_matches?(current, binding) and current["phase"] == "UNCERTAIN") or
               {:error, :amendment_authorization_effect_changed} do
        Store.query!(
          tx,
          "UPDATE ticket_amendment_authorization_effects SET last_error = ?, updated_at = ? WHERE command_key = ? AND phase = 'UNCERTAIN'",
          [inspect(reason), now(), command_key]
        )

        :ok
      end
    end)
  end

  defp validate_authorization_preflight(source_json, source, binding) do
    with true <- source["key"] == binding.validated.run["issue_key"] or {:error, :amendment_jira_issue_mismatch},
         true <- source["id"] == binding.draft["issue_id"] or {:error, :amendment_jira_issue_mismatch},
         true <- source_json == binding.draft["readback_json"] or {:error, :amendment_authorization_preimage_changed} do
      :ok
    end
  end

  defp validate_authorization_readback(raw, binding) do
    with {:ok, snapshot} <- decode_snapshot(raw),
         {:ok, baseline} <- decode_snapshot(binding.draft["readback_json"]),
         true <-
           (snapshot["key"] == binding.validated.run["issue_key"] and snapshot["id"] == baseline["id"]) or
             {:error, :amendment_jira_issue_mismatch},
         true <-
           (is_binary(snapshot["updated"]) and
              Map.drop(snapshot, ["comments", "updated"]) == Map.drop(baseline, ["comments", "updated"])) or
             {:error, :amendment_authorization_preimage_changed},
         {:ok, comment_id} <- added_authorization_comment(snapshot, baseline, binding.body),
         {:ok, authorized} <- Contract.authorized_from_snapshot(snapshot, binding.validated.run["issue_key"]),
         true <- authorized == binding.proposed or {:error, :amendment_authorization_contract_mismatch},
         {:ok, proof} <- Contract.automatic_authorization_proof(snapshot, binding.proposed),
         true <-
           proof == %{critic_task_key: binding.attempt["task_key"], critic_output_sha256: binding.output_sha256} or
             {:error, :amendment_authorization_proof_mismatch} do
      {:ok, comment_id}
    else
      {:error, _} = error -> error
      _ -> {:error, :amendment_authorization_readback_invalid}
    end
  end

  defp added_authorization_comment(snapshot, baseline, body) do
    current = snapshot["comments"]
    prior = baseline["comments"]
    added = current -- prior
    matches = Enum.filter(added, &(is_map(&1) and &1["text"] == body and is_binary(&1["id"]) and &1["id"] != ""))

    if length(added) == 1 and length(matches) == 1 and
         comment_fingerprints(current -- matches) == comment_fingerprints(prior),
       do: {:ok, hd(matches)["id"]},
       else: {:error, :amendment_authorization_comment_mismatch}
  end

  defp validate_authorization_effect(row, binding) do
    expected = binding.binding

    if Map.take(row, Map.keys(expected)) == expected and row["phase"] in ["PENDING", "UNCERTAIN", "READ_BACK"] and
         valid_hash?(row["critic_result_sha256"]) and row["critic_result_sha256"] == expected["critic_result_sha256"] and
         row["critic_output_sha256"] == expected["critic_output_sha256"] and
         row["draft_readback_sha256"] == digest(row["draft_readback_json"]) and
         row["authorization_body_sha256"] == digest(row["authorization_body"]) do
      :ok
    else
      {:error, :amendment_authorization_effect_corrupt}
    end
  end

  defp authorization_identity_matches?(row, binding),
    do: Map.take(row, Map.keys(binding.binding)) == binding.binding

  defp publish_in_session(store, command_key, controller_context, opts) do
    with {:ok, validated, amendment} <- current_amendment(store, command_key, controller_context),
         {:ok, source} <- read_issue(validated.run, opts),
         {:ok, row} <- prepare_effect(store, command_key, controller_context, source, validated, amendment) do
      advance(store, command_key, controller_context, row, source, opts)
    end
  end

  defp advance(store, command_key, _context, %{"phase" => "READ_BACK"}, _source, _opts),
    do: readback(store, command_key)

  defp advance(store, command_key, context, %{"phase" => "UNCERTAIN"} = row, source, _opts) do
    case validate_observed_readback(source, row["publication_preimage_json"], row, command_key) do
      {:ok, comment_id} ->
        record_readback(store, command_key, context, source, comment_id, row)

      {:error, :amendment_jira_draft_not_observed} ->
        record_observation(store, command_key, context, source, :amendment_jira_draft_not_observed)
        {:error, :amendment_jira_outcome_uncertain}

      {:error, reason} ->
        record_observation(store, command_key, context, source, reason)
        {:error, :amendment_jira_reconciliation_required}
    end
  end

  defp advance(store, command_key, context, %{"phase" => "PENDING"} = row, source, opts) do
    case validate_observed_readback(source, row["publication_preimage_json"], row, command_key) do
      {:ok, comment_id} ->
        record_readback(store, command_key, context, source, comment_id, row)

      {:error, :amendment_jira_draft_not_observed} ->
        perform_pending_write(store, command_key, context, row, source, opts)

      {:error, reason} ->
        record_observation(store, command_key, context, source, reason)
        {:error, :amendment_jira_preimage_changed}
    end
  end

  defp advance(_store, _command_key, _context, _row, _source, _opts),
    do: {:error, :amendment_jira_effect_invalid}

  defp perform_pending_write(store, command_key, context, row, source, opts) do
    {tool, args} = effect_call(row)
    connector = Keyword.get(opts, :jira_connector, JiraMcpConnector)

    with :ok <- connector.validate_call(tool, args, opts),
         :ok <- AppServer.check_ticket_runtime(opts[:workspace]),
         {:ok, _claimed} <- claim(store, command_key, context, row, source) do
      _write_result = call_write(connector, tool, args, opts)
      finish_claimed_write(store, command_key, context, row, opts)
    end
  end

  defp finish_claimed_write(store, command_key, context, row, opts) do
    case read_issue(%{"issue_key" => row["issue_key"]}, opts) do
      {:ok, source} ->
        case validate_observed_readback(source, row["publication_preimage_json"], row, command_key) do
          {:ok, comment_id} ->
            record_readback(store, command_key, context, source, comment_id, row)

          {:error, reason} ->
            record_observation(store, command_key, context, source, reason)
            {:error, :amendment_jira_outcome_uncertain}
        end

      {:error, reason} ->
        record_observation_error(store, command_key, context, row, reason)
        {:error, :amendment_jira_readback_unavailable}
    end
  end

  defp call_write(connector, tool, args, opts) do
    connector.call(tool, args, opts)
  rescue
    error -> {:error, {:amendment_jira_connector_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:amendment_jira_connector_exit, kind, inspect(reason)}}
  end

  defp read_issue(run, opts) do
    reader = Keyword.get(opts, :jira_reader, JiraMcpReader)
    reader_opts = Keyword.put(opts, :connector, Keyword.get(opts, :jira_connector, JiraMcpConnector))

    with {:ok, snapshot} <- reader.issue(run["issue_key"], reader_opts),
         true <- snapshot["key"] == run["issue_key"] or {:error, :amendment_jira_issue_mismatch} do
      {:ok, Jason.encode!(snapshot)}
    end
  end

  defp current_amendment(store, command_key, controller_context) do
    transaction(store, fn tx ->
      with {:ok, validated, amendment} <- TicketContractAmendment.validate_current(tx, command_key, controller_context),
           true <- amendment["phase"] == "RESERVED" or {:error, :invalid_contract_amendment} do
        {:ok, validated, amendment}
      end
    end)
  end

  defp prepare_effect(store, command_key, context, source_json, validated, amendment) do
    transaction(store, fn tx ->
      with {:ok, current, current_amendment} <- current_amendment(tx, command_key, context),
           true <- (current == validated and current_amendment == amendment) or {:error, :amendment_binding_changed},
           {:ok, source} <- decode_snapshot(source_json) do
        expected = effect_binding(source_json, source, validated, amendment)
        existing = Store.one!(tx, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key])

        prepare_effect_row(tx, existing, source, expected, validated, amendment)
      end
    end)
  end

  defp prepare_effect_row(store, nil, source, expected, validated, amendment) do
    with :ok <- validate_source_preimage(source, expected["publication_preimage_json"], validated.run["issue_key"], amendment),
         do: insert_effect(store, expected)
  end

  defp prepare_effect_row(_store, row, _source, _expected, validated, amendment) do
    with :ok <- validate_effect(row, validated, amendment), do: {:ok, row}
  end

  defp effect_binding(source_json, source, validated, amendment) do
    proposed = Contract.bind(validated.run["issue_key"], amendment["proposed_revision"], amendment["proposed_contract_markdown"])

    %{
      "command_key" => amendment["command_key"],
      "run_id" => amendment["run_id"],
      "chat_key" => amendment["chat_key"],
      "generation" => amendment["generation"],
      "input_key" => amendment["input_key"],
      "input_sha256" => amendment["input_sha256"],
      "prior_revision" => amendment["prior_revision"],
      "prior_contract_sha256" => amendment["prior_contract_sha256"],
      "candidate_sha" => amendment["candidate_sha"],
      "proposed_revision" => amendment["proposed_revision"],
      "proposed_contract_markdown" => amendment["proposed_contract_markdown"],
      "proposed_contract_sha256" => amendment["proposed_contract_sha256"],
      "issue_key" => validated.run["issue_key"],
      "issue_id" => source["id"],
      "draft_body" => Contract.draft_comment(proposed),
      "draft_body_sha256" => digest(Contract.draft_comment(proposed)),
      "source_preimage_json" => validated.run["snapshot_json"],
      "source_preimage_sha256" => digest(validated.run["snapshot_json"]),
      "publication_preimage_json" => publication_preimage(amendment, validated.run),
      "preflight_json" => source_json,
      "preflight_sha256" => digest(source_json)
    }
  end

  defp publication_preimage(%{"supersession_json" => nil}, run), do: run["snapshot_json"]

  defp publication_preimage(amendment, _run) do
    with {:ok, link} <- Jason.decode(amendment["supersession_json"]),
         baseline when is_binary(baseline) <- link["predecessor_draft_readback_json"],
         true <- digest(baseline) == link["predecessor_draft_readback_sha256"] do
      baseline
    else
      _ -> "invalid"
    end
  end

  defp insert_effect(store, expected) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    fields = Map.keys(expected)
    columns = Enum.join(fields, ", ")
    placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)

    Store.query!(
      store,
      "INSERT INTO ticket_amendment_jira_effects(#{columns}, phase, created_at, updated_at) VALUES (#{placeholders}, 'PENDING', ?, ?)",
      Enum.map(fields, &Map.fetch!(expected, &1)) ++ [at, at]
    )

    {:ok, Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [expected["command_key"]])}
  end

  defp validate_effect(row, validated, amendment) do
    expected = effect_binding(row["preflight_json"], decode_snapshot!(row["preflight_json"]), validated, amendment)

    if effect_identity_valid?(row, expected, validated, amendment) and row["phase"] in ~w(PENDING UNCERTAIN READ_BACK) do
      case validate_source_preimage(decode_snapshot!(row["preflight_json"]), row["publication_preimage_json"], row["issue_key"], amendment) do
        :ok -> :ok
        {:error, _} -> {:error, :amendment_jira_effect_corrupt}
      end
    else
      {:error, :amendment_jira_effect_corrupt}
    end
  rescue
    _ -> {:error, :amendment_jira_effect_corrupt}
  end

  defp effect_identity_valid?(row, expected, validated, amendment) do
    source_preimage_valid? =
      row["source_preimage_json"] == validated.run["snapshot_json"] and
        row["source_preimage_sha256"] == digest(row["source_preimage_json"]) and
        row["publication_preimage_json"] == publication_preimage(amendment, validated.run)

    source_preimage_valid? and Map.take(row, Map.keys(expected)) |> then(&(&1 == expected)) and
      valid_hash?(row["preflight_sha256"]) and row["preflight_sha256"] == digest(row["preflight_json"])
  end

  defp claim(store, command_key, context, row, source_json) do
    transaction(store, fn tx ->
      with {:ok, validated, amendment} <- current_amendment(tx, command_key, context),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_effect(current, validated, amendment),
           true <- effect_identity_matches?(current, row) or {:error, :amendment_jira_effect_changed},
           true <- current["phase"] == "PENDING" or {:error, :amendment_jira_outcome_uncertain},
           {:ok, source} <- decode_snapshot(source_json),
           :ok <- validate_source_preimage(source, current["publication_preimage_json"], current["issue_key"], current) do
        claim_pending_effect(tx, command_key, source_json)
      end
    end)
  end

  defp claim_pending_effect(store, command_key, source_json) do
    Store.query!(
      store,
      "UPDATE ticket_amendment_jira_effects SET phase = 'UNCERTAIN', claimed_at = ?, observed_json = ?, observed_sha256 = ?, last_error = NULL, updated_at = ? WHERE command_key = ? AND phase = 'PENDING'",
      [now(), source_json, digest(source_json), now(), command_key]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] == 1,
      do: {:ok, Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key])},
      else: Exqlite.rollback(store, :amendment_jira_outcome_uncertain)
  end

  defp record_readback(store, command_key, context, source_json, comment_id, row) do
    transaction(store, fn tx ->
      with {:ok, validated, amendment} <- current_amendment(tx, command_key, context),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_effect(current, validated, amendment),
           true <- effect_identity_matches?(current, row) or {:error, :amendment_jira_effect_changed},
           true <- current["phase"] in ~w(PENDING UNCERTAIN) or {:error, :amendment_jira_effect_changed},
           {:ok, current_comment_id} <- readback_comment_id(source_json, current["publication_preimage_json"], validated, amendment),
           true <- current_comment_id == comment_id or {:error, :amendment_jira_comment_changed} do
        persist_readback(tx, command_key, source_json, comment_id)
      end
    end)
  end

  defp persist_readback(store, command_key, source_json, comment_id) do
    Store.query!(
      store,
      "UPDATE ticket_amendment_jira_effects SET phase = 'READ_BACK', observed_json = ?, observed_sha256 = ?, readback_json = ?, readback_sha256 = ?, comment_id = ?, last_error = NULL, updated_at = ? WHERE command_key = ? AND phase IN ('PENDING', 'UNCERTAIN')",
      [source_json, digest(source_json), source_json, digest(source_json), comment_id, now(), command_key]
    )

    if Store.one!(store, "SELECT changes() AS count")["count"] == 1,
      do: {:ok, Store.one!(store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key])},
      else: Exqlite.rollback(store, :amendment_jira_effect_changed)
  end

  defp record_observation(store, command_key, context, source_json, reason) do
    transaction(store, fn tx ->
      with {:ok, validated, amendment} <- current_amendment(tx, command_key, context),
           row when is_map(row) <- Store.one!(tx, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_effect(row, validated, amendment),
           true <- row["phase"] in ~w(PENDING UNCERTAIN) or {:error, :amendment_jira_effect_changed} do
        Store.query!(
          tx,
          "UPDATE ticket_amendment_jira_effects SET observed_json = ?, observed_sha256 = ?, last_error = ?, updated_at = ? WHERE command_key = ? AND phase IN ('PENDING', 'UNCERTAIN')",
          [source_json, digest(source_json), to_string(reason), now(), command_key]
        )

        :ok
      end
    end)
  end

  defp record_observation_error(store, command_key, context, row, reason) do
    transaction(store, fn tx ->
      with {:ok, validated, amendment} <- current_amendment(tx, command_key, context),
           current when is_map(current) <- Store.one!(tx, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command_key]),
           :ok <- validate_effect(current, validated, amendment),
           true <-
             (effect_identity_matches?(current, row) and current["phase"] == "UNCERTAIN") or
               {:error, :amendment_jira_effect_changed} do
        Store.query!(
          tx,
          "UPDATE ticket_amendment_jira_effects SET last_error = ?, updated_at = ? WHERE command_key = ? AND phase = 'UNCERTAIN'",
          [inspect(reason), now(), command_key]
        )

        :ok
      end
    end)
  end

  defp effect_identity_matches?(left, right),
    do: Map.take(left, @effect_identity_fields) == Map.take(right, @effect_identity_fields)

  defp valid_readback(raw, preimage_json, validated, amendment) do
    case readback_comment_id(raw, preimage_json, validated, amendment) do
      {:ok, _comment_id} -> :ok
      {:error, _} = error -> error
    end
  end

  defp readback_comment_id(raw, preimage_json, validated, amendment) do
    row = %{
      "issue_key" => validated.run["issue_key"],
      "issue_id" => decode_snapshot!(preimage_json)["id"],
      "proposed_revision" => amendment["proposed_revision"],
      "proposed_contract_markdown" => amendment["proposed_contract_markdown"],
      "draft_body" => draft_body(validated.run["issue_key"], amendment)
    }

    validate_readback_snapshot(raw, preimage_json, row)
  end

  defp validate_observed_readback(raw, preimage_json, row, _command_key) do
    case validate_readback_snapshot(raw, preimage_json, row) do
      {:ok, _comment_id} = valid ->
        valid

      {:error, :amendment_jira_draft_not_observed} ->
        with {:ok, source} <- decode_snapshot(raw),
             {:ok, preimage} <- decode_snapshot(preimage_json),
             :ok <- validate_unmodified_preimage(source, preimage, row["issue_key"]) do
          {:error, :amendment_jira_draft_not_observed}
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_readback_snapshot(raw, preimage_json, row) do
    with {:ok, baseline} <- decode_snapshot(preimage_json),
         {:ok, snapshot} <- decode_snapshot(raw),
         true <-
           (snapshot["key"] == row["issue_key"] and snapshot["id"] == row["issue_id"]) or
             {:error, :amendment_jira_issue_mismatch},
         true <- unchanged_issue_fields?(snapshot, baseline) or {:error, :amendment_jira_preimage_changed},
         {:ok, proposed} <- Contract.normalize_draft_revision(row["proposed_contract_markdown"], row["proposed_revision"]),
         contract <- Contract.bind(row["issue_key"], row["proposed_revision"], proposed),
         true <- Contract.draft_read_back?(snapshot, contract) or {:error, :amendment_jira_draft_not_observed},
         true <-
           Contract.next_revision(snapshot) == contract.revision + 1 or
             {:error, :amendment_jira_proposed_revision_not_latest},
         true <-
           not Contract.authorized?(snapshot, contract) or
             {:error, :amendment_jira_proposed_contract_already_authorized},
         {:ok, comment_id} <- added_comment_id(snapshot, baseline, row["draft_body"]) do
      {:ok, comment_id}
    else
      {:error, _} = error -> error
    end
  end

  defp validate_source_preimage(source, baseline_json, issue_key, amendment) do
    baseline = decode_snapshot!(baseline_json)

    row = %{
      "issue_key" => issue_key,
      "issue_id" => baseline["id"],
      "proposed_revision" => amendment["proposed_revision"],
      "proposed_contract_markdown" => amendment["proposed_contract_markdown"],
      "draft_body" => draft_body(issue_key, amendment)
    }

    case validate_readback_snapshot(Jason.encode!(source), baseline_json, row) do
      {:ok, _comment_id} -> :ok
      {:error, :amendment_jira_draft_not_observed} -> validate_unmodified_preimage(source, baseline, issue_key)
      {:error, _} = error -> error
    end
  end

  defp validate_unmodified_preimage(source, baseline, issue_key) do
    if source["key"] == issue_key and source["id"] == baseline["id"] and is_binary(source["updated"]) and
         unchanged_issue_fields?(source, baseline) and exact_comments?(source["comments"], baseline["comments"]),
       do: :ok,
       else: {:error, :amendment_jira_preimage_changed}
  end

  defp unchanged_issue_fields?(snapshot, baseline),
    do: Map.drop(snapshot, ["comments", "updated"]) == Map.drop(baseline, ["comments", "updated"])

  defp exact_comments?(current, baseline) when is_list(current) and is_list(baseline),
    do: comment_fingerprints(current) == comment_fingerprints(baseline)

  defp exact_comments?(_, _), do: false

  defp comment_fingerprints(comments),
    do: Enum.map(comments, &{&1["id"], &1["text"]}) |> Enum.sort()

  defp added_comment_id(snapshot, baseline, expected_body) do
    new = snapshot["comments"] -- baseline["comments"]
    matching = Enum.filter(new, &(is_map(&1) and &1["text"] == expected_body and is_binary(&1["id"]) and &1["id"] != ""))

    if length(new) == 1 and length(matching) == 1 and
         comment_fingerprints(snapshot["comments"] -- matching) == comment_fingerprints(baseline["comments"]),
       do: {:ok, hd(matching)["id"]},
       else: {:error, :amendment_jira_comment_mismatch}
  end

  defp draft_body(issue_key, amendment) do
    amendment
    |> then(&Contract.bind(issue_key, &1["proposed_revision"], &1["proposed_contract_markdown"]))
    |> Contract.draft_comment()
  end

  defp effect_call(row), do: {"jira_add_comment", %{"issue_key" => row["issue_key"], "body" => row["draft_body"]}}

  defp decode_snapshot(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      _ -> {:error, :amendment_jira_snapshot_invalid}
    end
  end

  defp decode_snapshot(_), do: {:error, :amendment_jira_snapshot_invalid}
  defp decode_snapshot!(raw), do: Jason.decode!(raw)

  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]+\z/, value)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp transaction(store, fun) do
    case Exqlite.transaction(store, &rollback_error(&1, fun.(&1))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result
end
