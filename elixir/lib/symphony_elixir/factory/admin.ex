defmodule SymphonyElixir.Factory.Admin do
  @moduledoc """
  Local administrative operations for the durable factory control plane.

  These operations open a short-lived SQLite connection, so they can pause,
  activate, or inspect a running Symphony instance without using Jira as a
  control channel.
  """

  alias SymphonyElixir.Factory.{Control, Recovery, RunLedger, Store}
  alias SymphonyElixir.Factory.TicketPushUnattachedRetirement

  @doc """
  Reads the local control record.
  """
  @spec status(struct() | map()) :: {:ok, map()} | {:error, term()}
  def status(factory) do
    with_read_store(factory, fn connection, config ->
      {:ok, Control.status(connection, config.scope)}
    end)
  end

  @doc "Returns local control, run, and reopenable Codex-task state for diagnostics."
  @spec overview(struct() | map()) :: {:ok, map()} | {:error, term()}
  def overview(factory) do
    with_read_store(factory, fn connection, config ->
      runs = rows(connection, "SELECT * FROM runs ORDER BY updated_at DESC LIMIT 100")

      tasks =
        rows(
          connection,
          """
          SELECT task_key, run_id, stage, role, status, thread_id, turn_id, codex_project_id,
                 model, reasoning_effort, failure_code, updated_at
          FROM factory_tasks
          ORDER BY updated_at DESC LIMIT 200
          """
        )

      {:ok,
       %{
         control: Control.status(connection, config.scope),
         runs: runs,
         tasks: tasks
       }}
    end)
  end

  @doc """
  Activates a dispatcher using the configured identity unless overridden.
  """
  @spec activate(struct() | map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def activate(factory, dispatcher_id \\ nil) do
    change_status(factory, dispatcher_id, &Control.activate/4)
  end

  @doc """
  Pauses a dispatcher using the configured identity unless overridden.
  """
  @spec pause(struct() | map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pause(factory, dispatcher_id \\ nil) do
    change_status(factory, dispatcher_id, &Control.pause/4)
  end

  @doc "Requests one local retry of the latest failed specification for an exact Jira issue."
  @spec retry_specification(struct() | map(), String.t()) :: {:ok, map()} | {:error, term()}
  def retry_specification(factory, issue_key) when is_binary(issue_key) do
    with_store(factory, fn connection, config ->
      RunLedger.request_specification_retry(connection, String.trim(issue_key), config.scope)
    end)
  end

  @doc "Reopens one legacy failed native author after its exact completed turn is proven."
  @spec recover_specification_readback(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def recover_specification_readback(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.restore_specification(connection, config, request_key, completed_turn_id)
    end)
  end

  @doc "Adopts a completed specification draft carrying the previous revision."
  @spec adopt_failed_specification_revision(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def adopt_failed_specification_revision(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.adopt_failed_specification_revision(connection, config, request_key, completed_turn_id)
    end)
  end

  @doc "Reopens an exact committed native repair slice for same-turn adoption."
  @spec adopt_failed_native_repair_slice(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def adopt_failed_native_repair_slice(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.adopt_failed_native_repair_slice(connection, config, request_key, completed_turn_id)
    end)
  end

  @doc "Rearms an exact verifier-blocked delivery for a controller-owned CI preflight."
  @spec resume_failed_ci_preflight(struct() | map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume_failed_ci_preflight(factory, run_id, candidate_sha)
      when is_binary(run_id) and is_binary(candidate_sha) do
    with_store(factory, fn connection, config ->
      Recovery.resume_failed_ci_preflight(
        connection,
        Map.put(config, :repositories, Map.get(factory, :repositories, %{})),
        run_id,
        candidate_sha
      )
    end)
  end

  @doc "Rearms a native writer after a prior failed run left its stable branch at another SHA."
  @spec resume_native_branch_sha_mismatch(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_native_branch_sha_mismatch(factory, run_id, prior_run_id)
      when is_binary(run_id) and is_binary(prior_run_id) do
    with_store(factory, fn connection, config ->
      Recovery.resume_native_branch_sha_mismatch(
        connection,
        Map.put(config, :repositories, Map.get(factory, :repositories, %{})),
        run_id,
        prior_run_id
      )
    end)
  end

  @doc "Recovers one blocked native writer in its existing task and exact branch."
  @spec recover_native_writer(struct() | map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recover_native_writer(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.restore_native_writer(connection, config, request_key, completed_turn_id)
    end)
  end

  @doc "Recovers an exact completed writer bootstrap without creating or messaging a replacement task."
  @spec recover_native_bootstrap(struct() | map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recover_native_bootstrap(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.recover_native_bootstrap(
        connection,
        Map.put(config, :repositories, Map.get(factory, :repositories, %{})),
        request_key,
        completed_turn_id
      )
    end)
  end

  @doc "Resumes one interrupted native writer with its existing uncommitted source edits."
  @spec resume_interrupted_native_writer(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_interrupted_native_writer(factory, request_key, interrupted_turn_id)
      when is_binary(request_key) and is_binary(interrupted_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.resume_interrupted_native_writer(connection, config, request_key, interrupted_turn_id)
    end)
  end

  @doc "Rearms one authentication-failed verifier without replacing its task or review checkout."
  @spec resume_authentication_failed_verifier(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_authentication_failed_verifier(factory, request_key, failed_turn_id)
      when is_binary(request_key) and is_binary(failed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.resume_authentication_failed_verifier(connection, config, request_key, failed_turn_id)
    end)
  end

  @doc "Rearms an exact verifier after its uncertain CREATE is proven by the completed bootstrap turn."
  @spec recover_native_verifier_create(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def recover_native_verifier_create(factory, request_key, bootstrap_turn_id)
      when is_binary(request_key) and is_binary(bootstrap_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.recover_native_verifier_create(
        connection,
        Map.put(config, :repositories, Map.get(factory, :repositories, %{})),
        request_key,
        bootstrap_turn_id
      )
    end)
  end

  @doc "Rearms one blocked native writer for a bounded, same-task contract-check investigation."
  @spec resume_blocked_native_writer_investigation(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_blocked_native_writer_investigation(factory, request_key, blocked_turn_id)
      when is_binary(request_key) and is_binary(blocked_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.resume_blocked_native_writer_investigation(connection, config, request_key, blocked_turn_id)
    end)
  end

  @doc "Reopens one factory-blocked delivery with its original bound native writer."
  @spec reopen_factory_blocked_delivery(struct() | map(), String.t()) :: {:ok, map()} | {:error, term()}
  def reopen_factory_blocked_delivery(factory, run_id) when is_binary(run_id) do
    with_store(factory, fn connection, config ->
      Recovery.reopen_factory_blocked_delivery(connection, config, run_id)
    end)
  end

  @doc "Rearms a completed repair commit for controller-owned CI and MR delivery."
  @spec resume_controller_owned_delivery(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_controller_owned_delivery(factory, run_id, candidate_sha)
      when is_binary(run_id) and is_binary(candidate_sha) do
    with_store(factory, fn connection, config ->
      Recovery.resume_controller_owned_delivery(
        connection,
        Map.put(config, :repositories, Map.get(factory, :repositories, %{})),
        run_id,
        candidate_sha
      )
    end)
  end

  @doc "Requeues a native verifier CREATE after a proven invalid-arguments rejection."
  @spec resume_rejected_native_create(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_rejected_native_create(factory, request_key, rejected_tool_call_id)
      when is_binary(request_key) and is_binary(rejected_tool_call_id) do
    with_store(factory, fn connection, config ->
      Recovery.resume_rejected_native_create(
        connection,
        Map.put(config, :repositories, Map.get(factory, :repositories, %{})),
        request_key,
        rejected_tool_call_id
      )
    end)
  end

  @doc "Grants one repair turn in a proven stale planner task without changing its request payload."
  @spec authorize_planner_format_repair(struct() | map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def authorize_planner_format_repair(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.authorize_planner_format_repair(connection, config, request_key, completed_turn_id)
    end)
  end

  @doc "Claims one previously authorized planner repair before the broker sends it."
  @spec claim_planner_format_repair(struct() | map(), String.t()) :: {:ok, map()} | {:error, term()}
  def claim_planner_format_repair(factory, request_key) when is_binary(request_key) do
    with_store(factory, fn connection, config ->
      Recovery.claim_planner_format_repair(connection, config, request_key)
    end)
  end

  @doc "Authorizes one tool-free receipt repair in the exact existing controller task."
  @spec authorize_controller_format_repair(struct() | map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def authorize_controller_format_repair(factory, request_key, completed_turn_id)
      when is_binary(request_key) and is_binary(completed_turn_id) do
    with_store(factory, fn connection, config ->
      Recovery.authorize_controller_format_repair(connection, config, request_key, completed_turn_id)
    end)
  end

  @doc "Authorizes one exact failed writer retry at an idle tick boundary without fabricating human input."
  @spec recover_failed_writer(struct() | map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recover_failed_writer(factory, request, turn) do
    recover_writer(factory, request, turn, :capacity)
  end

  @doc "Authorizes one exact interrupted writer retry at an idle boundary without inventing an exit receipt."
  @spec recover_interrupted_writer(struct() | map(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_interrupted_writer(factory, request, turn, opts \\ []) do
    with_store(factory, fn connection, config ->
      recovery_opts = opts |> Keyword.put(:capacity_policy, factory) |> Keyword.put(:idle_scope, config.scope)
      SymphonyElixir.Factory.FailedTurnRecovery.prepare_interrupted(connection, request, turn, recovery_opts)
    end)
  end

  @doc "Explicit same-candidate CAS reconciliation of a lost push outcome, with a fresh controller Jira read."
  @spec recover_push_cas(struct() | map(), String.t(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def recover_push_cas(factory, run_id, expected_nonce, action) when action in [:prepare, :execute, :reconcile] do
    with_store(factory, fn connection, config ->
      with {:ok, run} <- RunLedger.get(connection, run_id),
           {:ok, intent} <- Jason.decode(run["candidate_handoff"] || "null"),
           true <- (is_map(intent) and intent["owner_nonce"] == expected_nonce) or {:error, :push_recovery_nonce_changed} do
        recover_push_leased(connection, config, factory, run_id, expected_nonce, action)
      end
    end)
  end

  @doc "Explicit exact-envelope input-fence preparation or one leased retirement; never issues a push."
  @spec retire_push_input(struct() | map(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def retire_push_input(factory, run_id, nonce, envelope_sha, receipt, receipt_sha, guard, plan_sha) do
    with :ok <- existing_retirement_ledger(factory) do
      with_store(factory, fn connection, config ->
        recover_push_leased(connection, config, factory, run_id, nonce, {:input_fence, envelope_sha, receipt, receipt_sha, guard, plan_sha})
      end)
    end
  end

  @spec retire_unattached_push(struct() | map(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def retire_unattached_push(factory, run_id, nonce, envelope_sha, receipt, receipt_sha, plan_sha) do
    with :ok <- existing_retirement_ledger(factory) do
      with_store(factory, fn connection, config ->
        recover_push_leased(connection, config, factory, run_id, nonce, {:unattached, envelope_sha, receipt, receipt_sha, plan_sha})
      end)
    end
  end

  @spec retire_preissuance_push(struct() | map(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def retire_preissuance_push(factory, run_id, nonce, envelope_sha, receipt, receipt_sha, plan_sha) do
    with :ok <- existing_retirement_ledger(factory) do
      with_store(factory, fn connection, config ->
        recover_push_leased(connection, config, factory, run_id, nonce, {:preissuance, envelope_sha, receipt, receipt_sha, plan_sha})
      end)
    end
  end

  defp existing_retirement_ledger(factory) do
    with :ok <- validate_factory(factory),
         {:ok, reader} <- Store.start_read_only(database: Map.fetch!(factory, :database)) do
      try do
        if is_map(Control.status(reader, factory.scope)), do: :ok, else: {:error, :existing_factory_control_required}
      after
        GenServer.stop(reader)
      end
    end
  end

  defp recover_push_leased(connection, config, factory, run_id, expected_nonce, action) do
    name = {:global, {__MODULE__, :push_cas_lease, make_ref()}}
    factory = Map.put_new(factory, :lease_seconds, config.lease_seconds)

    with {:ok, server} <- SymphonyElixir.Factory.ControlServer.start_link(store: connection, factory: factory, name: name) do
      try do
        result =
          SymphonyElixir.Factory.TickLease.run(
            factory,
            fn ->
              tick = Control.status(connection, config.scope) |> Map.take(~w(scope dispatcher_id generation tick_id))
              recover_push_action(connection, config, factory, run_id, expected_nonce, action, tick)
            end,
            control_server: server
          )

        case result do
          {:ran, value} -> value
          {:skipped, reason} -> {:error, {:push_recovery_lease_unavailable, reason}}
        end
      after
        GenServer.stop(server)
      end
    end
  end

  defp recover_push_action(connection, config, factory, run_id, expected_nonce, action, tick) do
    root = SymphonyElixir.Config.local_workspace_root()
    workspace = Path.join([root, "factory-controller", String.replace(config.scope, ~r/[^A-Za-z0-9._-]/, "-")])

    with {:ok, run} <- RunLedger.get(connection, run_id),
         {:ok, route} <- Map.fetch(factory.repositories, run["repo_key"]),
         opts = [workspace_root: root, capacity_policy: factory, ci_preflight_authorized: route["ci_preflight"] == "draft_mr", operator_tick: tick],
         {:ok, snapshot} <- SymphonyElixir.Factory.JiraMcpReader.issue(run["issue_key"], workspace: workspace, store: connection),
         {:ok, authorization} <- SymphonyElixir.Factory.TicketWorkerRunner.delivery_authorization(connection, run, snapshot, DateTime.utc_now(), opts) do
      result =
        case action do
          {:unattached, envelope_sha, receipt, receipt_sha, plan_sha} ->
            input_opts = Keyword.put(opts, :workspace, workspace)
            operation = %{run_id: run_id, nonce: expected_nonce, envelope_sha256: envelope_sha}
            shutdown_receipt = %{path: receipt, sha256: receipt_sha}

            if is_nil(plan_sha) do
              with {:ok, plan} <- TicketPushUnattachedRetirement.prepare(connection, operation, shutdown_receipt, authorization, input_opts) do
                {:ok, %{status: "UNATTACHED_RETIREMENT_PREPARED", run_id: run_id, plan_sha256: plan.plan_sha256, successor_nonce: plan.successor["owner_nonce"]}}
              end
            else
              TicketPushUnattachedRetirement.execute(connection, operation, shutdown_receipt, plan_sha, authorization, input_opts)
            end

          {:preissuance, envelope_sha, receipt, receipt_sha, plan_sha} ->
            input_opts = Keyword.put(opts, :workspace, workspace)
            operation = %{run_id: run_id, nonce: expected_nonce, envelope_sha256: envelope_sha}
            shutdown_receipt = %{path: receipt, sha256: receipt_sha}

            if is_nil(plan_sha) do
              with {:ok, plan} <- TicketPushUnattachedRetirement.prepare_preissuance(connection, operation, shutdown_receipt, authorization, input_opts) do
                {:ok, %{status: "PREISSUANCE_RETIREMENT_PREPARED", run_id: run_id, plan_sha256: plan.plan_sha256, successor_nonce: plan.successor["owner_nonce"]}}
              end
            else
              TicketPushUnattachedRetirement.execute_preissuance(connection, operation, shutdown_receipt, plan_sha, authorization, input_opts)
            end

          {:input_fence, envelope_sha, receipt, receipt_sha, guard, plan_sha} ->
            input_opts = opts |> Keyword.put(:workspace, workspace) |> Keyword.put(:input_fence_guard, guard)

            if is_nil(plan_sha) do
              case SymphonyElixir.Factory.TicketPush.prepare_input_retirement(connection, run_id, expected_nonce, envelope_sha, receipt, receipt_sha, authorization, input_opts) do
                {:ok, plan} ->
                  {:ok,
                   %{
                     status: "INPUT_RETIREMENT_PREPARED",
                     run_id: run_id,
                     plan_sha256: plan["plan_sha256"],
                     original_sha256: envelope_sha,
                     successor_nonce: plan["successor_nonce"],
                     reservation_key: plan["successor_reservation_key"]
                   }}

                error ->
                  error
              end
            else
              SymphonyElixir.Factory.TicketPush.execute_input_retirement(connection, run_id, expected_nonce, envelope_sha, receipt, receipt_sha, plan_sha, authorization, input_opts)
            end

          _ ->
            apply(SymphonyElixir.Factory.TicketPushRecovery, action, [connection, run_id, expected_nonce, authorization, opts])
        end

      push_recovery_result(result, run_id)
    else
      :error -> {:error, :push_recovery_repository_unconfigured}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec push_recovery_result({:ok, map()} | {:error, term()}, String.t()) :: {:ok, map()} | {:error, term()}
  def push_recovery_result(result, run_id) do
    case result do
      {:ok, %{status: status} = result}
      when status in [
             "INPUT_RETIREMENT_PREPARED",
             "INPUT_NOT_ISSUED_RETIRED",
             "UNATTACHED_RETIREMENT_PREPARED",
             "UNATTACHED_PUSH_RETIRED",
             "PREISSUANCE_RETIREMENT_PREPARED",
             "PREISSUANCE_PUSH_RETIRED"
           ] ->
        {:ok, result}

      {:ok, %{"owner_nonce" => nonce} = intent} ->
        {:ok, %{status: "PUSH_RECOVERY_PREPARED", run_id: run_id, owner_nonce: nonce, recovery_attempt: intent["recovery_attempt"], old_outcome: "UNKNOWN"}}

      {:ok, %{status: status} = result} ->
        {:ok, Map.take(result, [:status, :old_outcome, :new_exit_code]) |> Map.merge(%{run_id: run_id, state: result.run["state"]}) |> Map.put(:status, status)}

      error ->
        error
    end
  end

  defp recover_writer(factory, request, turn, kind) do
    with_store(factory, fn connection, config ->
      transaction = fn tx ->
        case Control.status(tx, config.scope) do
          %{"tick_id" => nil} -> recover_writer_attempt(tx, request, turn, kind, factory)
          _ -> {:error, :live_tick_lease}
        end
      end

      Store.transaction!(connection, transaction, timeout: 60_000)
    end)
  end

  defp recover_writer_attempt(store, request, turn, :capacity, factory),
    do: SymphonyElixir.Factory.FailedTurnRecovery.prepare(store, request, turn, capacity_policy: factory)

  @doc "Claims a previously authorized controller receipt repair before the broker sends it."
  @spec claim_controller_format_repair(struct() | map(), String.t()) :: {:ok, map()} | {:error, term()}
  def claim_controller_format_repair(factory, request_key) when is_binary(request_key) do
    with_store(factory, fn connection, config ->
      Recovery.claim_controller_format_repair(connection, config, request_key)
    end)
  end

  @doc "Replaces a paused projectless controller after a proven no-tool-call Desktop failure."
  @spec replace_controller(struct() | map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def replace_controller(factory, old_thread_id, new_thread_id, new_turn_id, request_key)
      when is_binary(old_thread_id) and is_binary(new_thread_id) and is_binary(new_turn_id) and
             is_binary(request_key) do
    with_store(factory, fn connection, config ->
      Store.transaction!(connection, fn transaction ->
        replace_controller_transaction(transaction, config, old_thread_id, new_thread_id, new_turn_id, request_key)
      end)
    end)
  end

  defp replace_controller_transaction(transaction, config, old_thread_id, new_thread_id, new_turn_id, request_key) do
    control = Control.status(transaction, config.scope)
    request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])

    with :ok <- require_controller_ids(old_thread_id, new_thread_id, new_turn_id),
         :ok <- require_paused_controller(control),
         :ok <- require_controller_route(control, config, old_thread_id),
         :ok <- require_failed_controller_request(request, config.scope, old_thread_id),
         :ok <- require_sole_controller_request(transaction, config.scope, request_key) do
      persist_controller_replacement(transaction, config.scope, old_thread_id, new_thread_id, new_turn_id, request_key)
    end
  end

  defp require_controller_ids(old_thread_id, new_thread_id, new_turn_id) do
    cond do
      not Enum.all?([old_thread_id, new_thread_id, new_turn_id], &present_string?/1) ->
        {:error, :missing_controller_identity}

      old_thread_id == new_thread_id ->
        {:error, :controller_thread_unchanged}

      true ->
        :ok
    end
  end

  defp require_paused_controller(control) do
    if control["status"] == "PAUSED" and control["tick_id"] == nil,
      do: :ok,
      else: {:error, :controller_replacement_requires_paused_unleased_control}
  end

  defp require_controller_route(control, config, old_thread_id) do
    if control["dispatcher_id"] == config.dispatcher_id and control["controller_thread_id"] == old_thread_id and
         control["controller_codex_project_id"] == "projectless",
       do: :ok,
       else: {:error, :controller_route_mismatch}
  end

  defp require_failed_controller_request(request, scope, old_thread_id) do
    if is_map(request) and request["target_kind"] == "CONTROLLER" and request["target_key"] == scope and
         request["action"] == "FOLLOWUP" and request["thread_id"] == old_thread_id and
         request["existing_thread_id"] == old_thread_id,
       do: require_failed_controller_status(request),
       else: {:error, :controller_request_not_proven_safe_to_retire}
  end

  defp require_failed_controller_status(request) do
    if request["status"] == "RECONCILE_REQUIRED" and request["verified_project_id"] == "projectless" and
         request["failure_code"] == "COMPLETED_TURN_EMPTY_NO_REQUIRED_JIRA_CALL",
       do: :ok,
       else: {:error, :controller_request_not_proven_safe_to_retire}
  end

  defp persist_controller_replacement(transaction, scope, old_thread_id, new_thread_id, new_turn_id, request_key) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      transaction,
      "UPDATE desktop_requests SET status = 'FAILED', failure_code = ?, updated_at = ? WHERE request_key = ?",
      ["CONTROLLER_REPLACED_AFTER_PROVEN_NO_JIRA_CALL", timestamp, request_key]
    )

    Store.query!(
      transaction,
      """
      UPDATE control
      SET controller_thread_id = ?, controller_turn_id = ?, generation = generation + 1,
          controller_writer_conflict_since = NULL, controller_writer_conflict_count = 0,
          updated_at = ?
      WHERE scope = ?
      """,
      [new_thread_id, new_turn_id, timestamp, scope]
    )

    Store.query!(
      transaction,
      "INSERT INTO events(occurred_at, event_type, payload_json) VALUES (?, ?, ?)",
      [
        timestamp,
        "CONTROLLER_REPLACED",
        Jason.encode!(%{
          old_thread_id: old_thread_id,
          new_thread_id: new_thread_id,
          new_turn_id: new_turn_id,
          retired_request_key: request_key
        })
      ]
    )

    {:ok, %{result: "CONTROLLER_REPLACED", control: Control.status(transaction, scope)}}
  end

  defp require_sole_controller_request(connection, scope, request_key) do
    row =
      Store.one!(
        connection,
        """
        SELECT COUNT(*) AS request_count FROM desktop_requests
        WHERE target_kind = 'CONTROLLER' AND target_key = ?
          AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')
          AND request_key != ?
        """,
        [scope, request_key]
      )

    if row["request_count"] == 0, do: :ok, else: {:error, :other_controller_request_unresolved}
  end

  defp change_status(factory, dispatcher_id, operation) do
    with_store(factory, fn connection, config ->
      operation.(connection, config, dispatcher_id || config.dispatcher_id, [])
    end)
  end

  defp with_store(factory, operation) do
    with :ok <- validate_factory(factory),
         {:ok, connection} <- Store.start_link(database: Map.fetch!(factory, :database)) do
      try do
        config = control_config(factory)
        Control.initialize(connection, config)
        operation.(connection, config)
      after
        GenServer.stop(connection)
      end
    end
  end

  defp with_read_store(factory, operation) do
    with :ok <- validate_factory(factory) do
      database = Map.fetch!(factory, :database)

      if database == ":memory:" or not File.exists?(database) do
        with_store(factory, operation)
      else
        with {:ok, connection} <- Store.start_read_only(database: Path.expand(database)) do
          result =
            try do
              config = control_config(factory)

              if is_nil(Control.status(connection, config.scope)),
                do: :control_initialization_required,
                else: operation.(connection, config)
            after
              GenServer.stop(connection)
            end

          if result == :control_initialization_required, do: with_store(factory, operation), else: result
        end
      end
    end
  end

  defp validate_factory(factory) do
    cond do
      not Map.get(factory, :enabled, false) -> {:error, :factory_disabled}
      not present_string?(Map.get(factory, :database)) -> {:error, :missing_factory_database}
      not present_string?(Map.get(factory, :scope)) -> {:error, :missing_factory_scope}
      not present_string?(Map.get(factory, :dispatcher_id)) -> {:error, :missing_factory_dispatcher_id}
      true -> :ok
    end
  end

  defp control_config(factory) do
    %{
      scope: Map.fetch!(factory, :scope),
      dispatcher_id: Map.fetch!(factory, :dispatcher_id),
      lease_seconds: Map.get(factory, :lease_seconds, 240)
    }
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp rows(connection, statement) do
    result = Store.query!(connection, statement)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end
end
