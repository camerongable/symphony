defmodule SymphonyElixir.Factory.TicketAmendmentCritic do
  @moduledoc "Runs and durably records one isolated critic turn for a published ticket amendment."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{StageRunner, TicketAmendmentJiraOperation, TicketContractAmendment, TicketMrOperation}
  alias SymphonyElixir.Tracker.Issue

  @spec execute(GenServer.server(), String.t(), map(), Path.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(store, command_key, controller_context, control_workspace, model_policy, opts \\ []) do
    with {:ok, validated, _amendment} <-
           TicketContractAmendment.validate_current(store, command_key, controller_context),
         {:ok, attempt} <- TicketContractAmendment.get_critic_attempt(store, command_key, model_policy),
         {:ok, receipt} <- TicketAmendmentJiraOperation.readback(store, command_key),
         true <- attempt["snapshot_json"] == receipt["readback_json"] or {:error, :amendment_readback_receipt_mismatch},
         {:ok, canonical_workspace} <- validate_workspace(control_workspace, validated.run) do
      dispatch_attempt(
        store,
        command_key,
        controller_context,
        attempt,
        validated,
        canonical_workspace,
        model_policy,
        opts
      )
    else
      {:error, _} = error -> error
    end
  end

  defp dispatch_attempt(_store, _command_key, _context, %{"phase" => "RESULT_RECORDED", "result_json" => raw}, _validated, _workspace, _policy, _opts),
    do: {:ok, Jason.decode!(raw)}

  defp dispatch_attempt(_store, _command_key, _context, %{"phase" => "INVOKING"}, _validated, _workspace, _policy, _opts),
    do: {:error, :critic_attempt_pending_unproven}

  defp dispatch_attempt(_store, _command_key, _context, %{"phase" => "RECONCILE_REQUIRED"}, _validated, _workspace, _policy, _opts),
    do: {:error, :critic_attempt_reconcile_required}

  defp dispatch_attempt(store, command_key, context, %{"phase" => "PREPARED"}, validated, workspace, policy, opts) do
    with {:ok, claimed} <- TicketContractAmendment.claim_critic(store, command_key, context, policy) do
      run_claimed(store, command_key, context, claimed, validated.chat["thread_id"], workspace, opts)
    end
  end

  defp dispatch_attempt(_store, _command_key, _context, _attempt, _validated, _workspace, _policy, _opts),
    do: {:error, :invalid_critic_attempt}

  defp validate_workspace(workspace, run) do
    case TicketMrOperation.controller_cwd(workspace, run["repo_path"], run["worktree"] || run["repo_path"]) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _} = error -> error
    end
  end

  defp run_claimed(store, command_key, context, attempt, parent_thread, workspace, opts) do
    snapshot = Jason.decode!(attempt["snapshot_json"])
    issue = issue_from_snapshot(snapshot)
    route = Jason.decode!(attempt["route_json"])
    schema = Jason.decode!(attempt["schema_json"])
    runner = Keyword.get(opts, :stage_runner, StageRunner)
    app_server = Keyword.get(opts, :app_server, AppServer)

    run_opts = [
      app_server: app_server,
      ephemeral: true,
      include_evidence: true,
      event_scope: :exact_turn,
      worker_access: "REVIEW",
      format_repair_attempts: 0,
      model: route["model"],
      reasoning_effort: route["reasoning_effort"],
      on_session_ready: fn session ->
        evidence = session_evidence(session)

        unless evidence["owner_cwd"] == workspace do
          raise "critic session workspace differs from canonical control workspace"
        end

        case TicketContractAmendment.record_critic_session(store, command_key, context, evidence) do
          :ok -> :ok
          {:error, reason} -> raise "critic session evidence rejected: #{inspect(reason)}"
        end
      end,
      on_message: fn
        %{event: :session_started, thread_id: thread_id, turn_id: turn_id} when thread_id != parent_thread ->
          case TicketContractAmendment.record_critic_turn(store, command_key, context, thread_id, turn_id) do
            :ok -> :ok
            {:error, reason} -> raise "critic turn evidence rejected: #{inspect(reason)}"
          end

        %{event: :session_started} ->
          raise "critic parent thread rejected"

        _event ->
          :ok
      end
    ]

    case runner.run(workspace, issue, attempt["prompt"], schema, run_opts) do
      {:ok, evidence} ->
        persist_result(store, command_key, context, attempt, evidence)

      {:error, reason} ->
        reconcile(store, command_key, context, reason, %{})
    end
  rescue
    error -> reconcile(store, command_key, context, {:critic_execution_failed, Exception.message(error)}, %{})
  catch
    kind, reason -> reconcile(store, command_key, context, {:critic_execution_exit, kind, inspect(reason)}, %{})
  end

  defp persist_result(store, command_key, context, attempt, evidence) do
    receipt = %{
      "task_key" => attempt["task_key"],
      "attempt_binding_sha256" =>
        digest(
          Jason.encode!(
            Map.take(
              attempt,
              ~w(command_key run_id task_key chat_key generation input_key input_sha256 draft_comment_id prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256 prompt_sha256 schema_sha256 snapshot_sha256 route_sha256)
            )
          )
        ),
      "thread_id" => evidence.thread_id,
      "turn_id" => evidence.turn_id,
      "item_id" => evidence.item_id,
      "output" => evidence.output,
      "policy" => evidence.policy,
      "owner_stop" => stringify(evidence.owner_stop),
      "qualifies" => evidence.output["status"] == "PASS" and evidence.output["findings"] == [] and evidence.output["required_questions"] == []
    }

    case TicketContractAmendment.record_critic_result(store, command_key, context, receipt) do
      {:ok, _attempt} ->
        {:ok, receipt}

      {:error, reason} ->
        observation = %{
          "item_id" => evidence.item_id,
          "thread_id" => evidence.thread_id,
          "turn_id" => evidence.turn_id
        }

        reconcile(store, command_key, context, {:critic_result_receipt_rejected, reason}, observation)
    end
  end

  defp reconcile(store, command_key, context, reason, observation) do
    case TicketContractAmendment.reconcile_critic(store, command_key, context, reason, observation) do
      {:ok, _row} -> {:error, {:critic_attempt_reconcile_required, reason}}
      {:error, reconcile_reason} -> {:error, {:critic_attempt_unproven, reason, reconcile_reason}}
    end
  end

  defp session_evidence(session) do
    metadata = Map.get(session, :metadata, %{})

    %{
      "thread_id" => session.thread_id,
      "worker_policy_json" => Jason.encode!(session.worker_policy),
      "owner_pid" => metadata[:codex_app_server_pid] || metadata["codex_app_server_pid"],
      "invocation_nonce" => session.worker_invocation,
      "owner_cwd" => session.worker_policy["cwd"]
    }
  end

  defp issue_from_snapshot(snapshot) do
    %Issue{
      id: snapshot["id"],
      native_ref: %{"id" => snapshot["id"], "key" => snapshot["key"]},
      identifier: snapshot["key"],
      title: snapshot["summary"],
      description: snapshot["description"],
      state: snapshot["status"],
      url: snapshot["url"],
      labels: snapshot["labels"] || [],
      dispatchable: false
    }
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
