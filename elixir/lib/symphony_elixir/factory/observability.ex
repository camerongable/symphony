defmodule SymphonyElixir.Factory.Observability do
  @moduledoc """
  Read-only factory state projected for the dashboard and JSON API.

  The projection deliberately reads the same SQLite ledger and controller used
  for dispatch. It never infers ownership from processes or Jira labels.
  """

  alias SymphonyElixir.Config

  alias SymphonyElixir.Factory.{
    Capacity,
    ControlServer,
    IntakeLedger,
    NativeWorkspaceMaintenance,
    Queue,
    ReviewProtocol,
    RunLedger,
    Store,
    Supervisor,
    TaskLedger,
    TicketChatOutbox,
    TicketChat,
    DesktopRequest,
    TicketContext
  }

  @terminal_states ~w(READY_FOR_REVIEW DELIVERED AWAITING_VALIDATION CANCELLED FAILED)
  @review_states ~w(READY_FOR_REVIEW AWAITING_VALIDATION)
  @overview_review_states ~w(READY_FOR_REVIEW)
  @active_task_statuses ~w(STARTING RUNNING)
  @overview_hidden_states ~w(DELIVERED CANCELLED)

  @doc "Returns the bounded factory projection, including an explicit state when the factory is disabled."
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    factory = value(settings, :factory, %{})

    feature_flags = %{
      ordinary_factory_enabled: value(factory, :enabled, false),
      ticket_supervisor_enabled: value(value(factory, :ticket_supervisor, %{}), :enabled, false)
    }

    if value(factory, :enabled, false) do
      default_store = if Process.whereis(Supervisor.read_store_name()), do: Supervisor.read_store_name(), else: Supervisor.store_name()
      store = Keyword.get(opts, :store, default_store)
      control_server = Keyword.get(opts, :control_server, Supervisor.control_name())
      opts = Keyword.put_new(opts, :polling_interval_ms, value(value(settings, :polling, %{}), :interval_ms, 30_000))
      build_snapshot(factory, store, control_server, opts) |> Map.merge(feature_flags)
    else
      %{
        enabled: false,
        available: false,
        disabled: true,
        error: nil,
        runs: [],
        current_runs: [],
        tasks: [],
        recent_events: [],
        counts: empty_counts(),
        overview: empty_overview(),
        intake: %{available: false, observed_at: nil, count: 0, issues: [], error: nil},
        capacity: []
      }
      |> Map.merge(feature_flags)
    end
  rescue
    error -> unavailable(Exception.message(error))
  catch
    :exit, reason -> unavailable(inspect(reason))
  end

  defp build_snapshot(factory, store, control_server, opts) do
    control = ControlServer.status(control_server)
    control_observed_at = DateTime.to_iso8601(DateTime.utc_now())
    capacity = capacities(store, factory, opts)
    capacity_observed_at = DateTime.to_iso8601(DateTime.utc_now())

    Store.transaction!(
      store,
      fn tx ->
        ledger_snapshot(factory, tx, control, opts)
        |> Map.merge(%{capacity: capacity, capacity_observed_at: capacity_observed_at, control_observed_at: control_observed_at})
      end,
      mode: :deferred
    )
  end

  defp ledger_snapshot(factory, store, control_status, opts) do
    run_limit = Keyword.get(opts, :run_limit, 50)
    current_run_limit = Keyword.get(opts, :current_run_limit, max(run_limit, 50))
    event_limit = Keyword.get(opts, :event_limit, 20)
    task_limit = Keyword.get(opts, :task_limit, 100)

    all_runs = RunLedger.list_recent(store, run_limit)
    current_runs = RunLedger.list_current(store, current_run_limit)
    runs = Enum.reject(all_runs, &hidden_from_dashboard?/1)
    current_runs = Enum.reject(current_runs, &hidden_from_dashboard?/1)
    tasks = if task_limit == 0, do: [], else: TaskLedger.list_recent(store, task_limit)
    handoffs = attention_handoffs(store)
    tasks_by_run = Enum.group_by(tasks, & &1["run_id"])
    issue_by_run = Map.new(all_runs ++ current_runs, &{&1["run_id"], &1["issue_key"]})

    combined_runs = Enum.uniq_by(runs ++ current_runs, & &1["run_id"])

    enriched_runs =
      project_runs(combined_runs, tasks_by_run, issue_by_run, handoffs)
      |> enrich_ci_attempts(store, factory)
      |> enrich_ticket_context(store, opts)
      |> enrich_worker_execution(store, combined_runs, factory, opts)
      |> enrich_attention(store, combined_runs, factory, opts)

    enriched_by_id = Map.new(enriched_runs, &{&1.run_id, &1})
    projected_runs = Enum.map(runs, &Map.fetch!(enriched_by_id, &1["run_id"]))
    projected_current_runs = Enum.map(current_runs, &Map.fetch!(enriched_by_id, &1["run_id"]))

    projected_tasks = Enum.map(tasks, &project_task(&1, issue_by_run, handoffs))
    intake = project_intake(IntakeLedger.get(store, value(factory, :scope, "default")), factory, current_runs)
    control = project_control(control_status)
    control = Map.put(control, :tick_observation, tick_observation(control, factory, opts))
    control = Map.put(control, :handoff_attention, controller_request_attention(store, factory, control, opts))
    intake = Map.put(intake, :stale, control.status == "PAUSED")
    stalled_run_ids = stalled_native_run_ids(store, current_runs, control)

    %{
      enabled: true,
      available: true,
      control: control,
      broker: project_broker(store, factory),
      workspace_maintenance: NativeWorkspaceMaintenance.snapshot(store),
      counts: counts(current_runs, tasks, handoffs, enriched_by_id),
      overview: overview(projected_current_runs, projected_tasks, intake, stalled_run_ids),
      presentation_attention_count: Enum.count(projected_current_runs, &Enum.any?(&1.attention_signals, fn signal -> signal.source == "PARENT_SYNC" end)),
      intake: intake,
      ledger_observed_at: DateTime.to_iso8601(DateTime.utc_now()),
      current_runs: projected_current_runs,
      runs: projected_runs,
      tasks: projected_tasks,
      recent_events: Enum.map(RunLedger.recent_events(store, event_limit), &project_event/1)
    }
  end

  defp enrich_ci_attempts(runs, store, factory) do
    configured = value(factory, :maximum_code_repair_rounds, nil)
    limit = if is_integer(configured) and configured > 0, do: min(configured, 10)

    Enum.map(runs, fn run ->
      run
      |> Map.put(:ci_repair_attempts_used, SymphonyElixir.Factory.TicketCiRepairSuccessor.attempts_used(store, run.run_id))
      |> Map.put(:ci_repair_attempt_limit, limit)
      |> Map.put(:implementation_iteration_limit, value(factory, :maximum_implementation_iterations))
      |> Map.put(:implementation_budget_status, implementation_budget_status(run, factory))
    end)
  end

  defp controller_request_attention(store, factory, control, opts) do
    request =
      Store.one!(
        store,
        "SELECT * FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND target_key = ? AND json_type(CASE WHEN json_valid(metadata_json) THEN metadata_json ELSE '{}' END, '$.delivery_operation') IS NULL ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [value(factory, :scope, "default")]
      )

    if request && request["existing_thread_id"] == control.controller_thread_id do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      stale =
        request["status"] in ~w(PENDING CREATE_UNCERTAIN FOLLOWUP_UNCERTAIN THREAD_RECORDED) and
          aged?(request["claimed_at"] || request["created_at"], now, value(factory, :stale_task_minutes, 90) * 60)

      if request["status"] in ~w(FAILED RECONCILE_REQUIRED) or stale do
        signal =
          notice(
            "CONTROLLER",
            request["status"],
            request["request_key"],
            bounded_reason(request["failure_code"] || "Controller handoff completion has not been confirmed."),
            request["updated_at"],
            "Reconcile the existing controller handoff; healthy scheduler ticks do not prove its native turn succeeded."
          )

        if request["status"] == "FAILED",
          do:
            signal
            |> Map.put(:recorded_phase, signal.phase)
            |> Map.put(:blocking, false)
            |> Map.put(:category, "HISTORY")
            |> Map.put(:next_action, "Retain this terminal failed record. It does not fence the current controller and is not proof of recovery or success. Do not resend this handoff."),
          else: signal
      end
    end
  end

  defp enrich_worker_execution(runs, store, recorded, factory, opts) do
    recorded = Map.new(recorded, &{&1["run_id"], &1})
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    budget = value(factory, :stale_task_minutes, 90) * 60
    Enum.map(runs, &Map.put(&1, :worker_execution, worker_execution(store, recorded[&1.run_id], now, budget)))
  end

  defp worker_execution(store, run, now, budget) do
    role = canonical_worker_role(run)
    task = canonical_worker_task(store, run, role)
    evidence = if task, do: Store.one!(store, "SELECT * FROM worker_evidence WHERE task_key=? ORDER BY rowid DESC LIMIT 1", [task["task_key"]])
    status = worker_status(store, run, role, task, evidence, now, budget)

    %{
      status: status,
      running_proven: false,
      admission_proven: worker_admission_proven?(status, evidence),
      task_key: if(task, do: task["task_key"]),
      request_key: if(evidence, do: evidence["request_key"]),
      evidence_at: if(evidence, do: evidence["created_at"]),
      thread_id: if(status == "TURN_BOUND", do: evidence["thread_id"]),
      turn_id: if(status == "TURN_BOUND", do: evidence["turn_id"])
    }
  end

  defp canonical_worker_role(run) do
    case run["state"] do
      "PLANNING" -> "feature-planner"
      stage when stage in ~w(WRITING REPAIRING REVIEW_WRITING) -> "feature-writer"
      "VERIFYING" -> "change-verifier:#{run["verifier_round"] || 0}"
      "TESTING" -> "manual-validator"
      _ -> nil
    end
  end

  defp canonical_worker_task(_store, _run, nil), do: nil

  defp canonical_worker_task(store, run, role),
    do: Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=? AND run_id=?", [run["run_id"] <> ":" <> role, run["run_id"]])

  defp worker_status(_, %{"execution_mode" => mode}, _, _, _, _, _) when mode != "TICKET_SUPERVISOR_V1", do: "NOT_APPLICABLE"
  defp worker_status(_, _, nil, _, _, _, _), do: "NOT_APPLICABLE"
  defp worker_status(_, _, _, nil, _, _, _), do: "WAITING"
  defp worker_status(_, _, _, %{"status" => status}, _, _, _) when status in ~w(COMPLETE CONSUMED), do: "WAITING"
  defp worker_status(_, _, _, _, %{"status" => "CONSUMED"}, _, _), do: "WAITING"
  defp worker_status(_, _, _, _, nil, _, _), do: "UNKNOWN"

  defp worker_status(store, run, _role, task, evidence, now, budget) do
    cond do
      task["stage"] != run["state"] -> "UNKNOWN"
      evidence["status"] == "RECONCILE_REQUIRED" -> "RECONCILE_REQUIRED"
      present?(evidence["owner_stopped_at"]) or evidence["status"] == "RESULT_RECORDED" -> "STOPPED"
      task["status"] in ~w(FAILED STALE CANCELLED) -> "UNKNOWN"
      not worker_binding_current?(store, task, evidence, run) -> "UNKNOWN"
      not fresh_timestamp?(evidence["created_at"], now, budget) -> "UNKNOWN"
      true -> bound_worker_status(evidence)
    end
  end

  defp bound_worker_status(%{"status" => "TURN_BOUND"} = evidence) do
    if present?(evidence["thread_id"]) and present?(evidence["turn_id"]), do: "TURN_BOUND", else: "UNKNOWN"
  end

  defp bound_worker_status(%{"status" => phase}) when phase in ~w(RESERVED START_SENT THREAD_BOUND), do: "STARTING"
  defp bound_worker_status(_evidence), do: "UNKNOWN"
  defp worker_admission_proven?("TURN_BOUND", _evidence), do: true
  defp worker_admission_proven?("STARTING", %{"status" => phase}), do: phase in ~w(START_SENT THREAD_BOUND)
  defp worker_admission_proven?(_status, _evidence), do: false

  defp worker_binding_current?(store, task, evidence, run) do
    raw = evidence["binding_json"]
    binding = decode_map(raw)
    digest = if is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    access = Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=? AND released_at IS NULL", [evidence["reservation_key"]])
    expected_sha = worker_expected_sha(store, run)

    evidence["run_id"] == run["run_id"] and digest == evidence["binding_sha256"] and
      Enum.all?(~w(task_key run_id role stage prompt_sha256), &(binding[&1] == task[&1])) and
      Enum.all?(~w(spec_revision contract_sha256), &(binding[&1] == run[&1])) and
      present?(expected_sha) and binding["expected_sha"] == expected_sha and worker_reservation_current?(access, binding, evidence)
  end

  defp worker_expected_sha(_store, %{"candidate_sha" => sha}) when is_binary(sha), do: sha

  defp worker_expected_sha(store, run) do
    case Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id=?", [run["run_id"]]) do
      %{"base_sha" => sha} -> sha
      _ -> nil
    end
  end

  defp worker_reservation_current?(nil, _binding, _evidence), do: false

  defp worker_reservation_current?(access, binding, evidence) do
    Enum.all?(~w(reservation_key run_id task_key request_key), &(access[&1] == evidence[&1])) and
      binding["reservation_key"] == access["reservation_key"] and binding["reservation_generation"] == access["generation"] and
      binding["mode"] == access["mode"]
  end

  defp fresh_timestamp?(timestamp, now, budget) do
    case timestamp_age(timestamp, now) do
      age when is_integer(age) -> age >= 0 and age <= budget
      _ -> false
    end
  end

  defp timestamp_age(timestamp, now) do
    with true <- is_binary(timestamp), {:ok, parsed, _} <- DateTime.from_iso8601(timestamp) do
      age = DateTime.diff(now, parsed, :microsecond)
      if age < 0, do: -1, else: div(age, 1_000_000)
    else
      _ -> nil
    end
  end

  defp tick_observation(control, factory, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    budget = max(div(Keyword.get(opts, :polling_interval_ms, 30_000) * 3, 1_000), value(factory, :lease_seconds, 240))
    health = control.tick_health || %{}
    started = timestamp_age(health[:last_started_at], now)
    completed = timestamp_age(health[:last_completed_at], now)
    invalid = Enum.any?([{health[:last_started_at], started}, {health[:last_completed_at], completed}], &invalid_tick_timestamp?/1)

    status =
      cond do
        control.status == "PAUSED" -> "PAUSED"
        invalid -> "UNKNOWN"
        pending_tick?(started, completed, health) -> if(started <= budget, do: "IN_PROGRESS", else: "STALE")
        is_integer(completed) -> if(completed <= budget, do: "FRESH", else: "STALE")
        true -> "UNKNOWN"
      end

    %{status: status, budget_seconds: budget, observed_at: DateTime.to_iso8601(now)}
  end

  defp invalid_tick_timestamp?({nil, _age}), do: false
  defp invalid_tick_timestamp?({_raw, age}), do: is_nil(age) or age < 0

  defp pending_tick?(started, completed, health),
    do: is_integer(started) and (is_nil(completed) or tick_started_after_completion?(health))

  defp tick_started_after_completion?(health) do
    {:ok, started, _} = DateTime.from_iso8601(health.last_started_at)
    {:ok, completed, _} = DateTime.from_iso8601(health.last_completed_at)
    DateTime.compare(started, completed) == :gt
  end

  defp enrich_attention(runs, store, recorded_runs, factory, opts) do
    recorded = Map.new(recorded_runs, &{&1["run_id"], &1})
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    stale_seconds = value(factory, :stale_task_minutes, 90) * 60

    Enum.map(runs, fn run ->
      source = recorded[run.run_id]
      review_stop = ReviewProtocol.status(store, source)
      historical_failure = superseded_exhaustion(store, source)
      canonical = canonical_worker_task(store, source, canonical_worker_role(source))
      current_tasks = if canonical, do: Enum.uniq_by([project_task(canonical, %{}, %{}) | run.tasks], & &1.task_key), else: run.tasks

      signals =
        if run.state not in @overview_hidden_states do
          [
            if(is_nil(historical_failure), do: review_stop_attention(source, review_stop)),
            report_attention(store, source),
            ci_attention(source),
            operation_attention(store, source),
            journal_attention(store, source),
            request_attention(store, source, now, stale_seconds),
            check_attention(store, source, now, stale_seconds),
            worker_attention(store, source),
            task_attention(source, current_tasks, now, stale_seconds),
            handoff_attention(run),
            implementation_attention(source, factory, run.worker_execution),
            progress_attention(source, run.tasks, now, stale_seconds)
          ]
          |> List.flatten()
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(&{&1.source, &1.request_key})
        else
          []
        end

      primary = Enum.find(signals, & &1.blocking) || List.first(signals)
      projected = if historical_failure, do: %{run | failure_code: nil, last_error: nil}, else: run

      projected
      |> Map.put(:historical_failure, historical_failure)
      |> Map.put(:review_stop, review_stop)
      |> Map.put(:attention, primary)
      |> Map.put(:attention_signals, signals)
      |> Map.put(:primary_next_action, primary_action(projected, primary))
    end)
  end

  defp implementation_budget_status(run, factory) do
    limit = value(factory, :maximum_implementation_iterations)

    cond do
      not is_integer(limit) or not is_integer(run.implementation_iteration) -> "UNKNOWN"
      run.implementation_iteration >= limit -> "EXHAUSTED"
      true -> "AVAILABLE"
    end
  end

  defp report_attention(store, run) do
    case ReviewProtocol.pending_status(store, run) do
      nil ->
        nil

      pending ->
        notice(
          "WORKER_RESULT",
          "REPORT_REJECTED",
          pending.request_key,
          "The worker has stopped, but the factory rejected its returned report (#{pending.reason}). Further adoption is paused; preserve the existing result and edits.",
          pending.evidence_at,
          pending.next_action
        )
    end
  end

  defp implementation_attention(run, factory, execution) do
    limit = value(factory, :maximum_implementation_iterations)
    used = run["implementation_iteration"]

    if run["execution_mode"] == "TICKET_SUPERVISOR_V1" and run["state"] in ~w(WRITING REPAIRING REVIEW_WRITING) and is_integer(limit) and is_integer(used) and used >= limit and
         not execution.admission_proven do
      notice(
        "IMPLEMENTATION_BUDGET",
        "implementation_iteration_limit",
        run["run_id"],
        "Implementation iterations exhausted: #{used}/#{limit}; this budget is separate from CI repair attempts.",
        run["updated_at"],
        "Requester decision required; no worker can launch under the current iteration policy. Do not reset counters or retry this as a transport failure."
      )
    end
  end

  defp superseded_exhaustion(store, %{"failure_code" => "CI_REPAIR_EXHAUSTED"} = run) do
    row = Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE run_id=? ORDER BY attempt_index DESC LIMIT 1", [run["run_id"]])

    with true <- run["state"] != "FAILED" and not String.contains?(run["state"], "BLOCK"),
         %{"successor_key" => key} <- row,
         {:ok, entry} <- SymphonyElixir.Factory.TicketCiRepairSuccessor.applied(store, key),
         prior = entry.proof["run"],
         true <- Map.take(prior, ~w(run_id spec_revision contract_sha256 failure_code last_error)) == Map.take(run, ~w(run_id spec_revision contract_sha256 failure_code last_error)) do
      notice(
        "WORKFLOW",
        "SUPERSEDED_EXHAUSTION",
        key,
        bounded_reason(prior["last_error"]),
        prior["updated_at"],
        "Retain the old exhaustion record; the controller admitted a later evidence successor."
      )
      |> Map.merge(%{blocking: false, category: "HISTORY"})
    else
      _ -> nil
    end
  end

  defp superseded_exhaustion(_store, _run), do: nil

  defp run_failure_attention(run) do
    if run["state"] == "FAILED" or present?(run["failure_code"]) or present?(run["last_error"]) do
      notice(
        "WORKFLOW",
        run["state"],
        run["run_id"],
        bounded_reason(run["last_error"] || run["failure_code"] || "The recorded workflow failed."),
        run["updated_at"],
        "Inspect the recorded failure and reconcile the existing workflow before resuming."
      )
    end
  end

  defp review_stop_attention(run, nil), do: run_failure_attention(run)

  defp review_stop_attention(run, stop) do
    notice("VERIFICATION", "STOPPED", run["run_id"], stop.title <> ". " <> stop.explanation, stop.evidence_at, stop.next_action)
    |> Map.put(:category, if(stop.kind == "VERIFICATION", do: "VERIFICATION", else: "POLICY"))
  end

  defp operation_attention(store, run) do
    intent = decode_map(run["candidate_handoff"])

    if push_operation?(run, intent) and present?(run["candidate_handoff"]) do
      phase = intent["phase"] || "UNREADABLE"
      recovery = push_recovery_outcome(store, run, intent)
      unfinished_push_notice(run, intent, phase, recovery)
    end
  end

  defp push_operation?(run, intent) do
    late_unfinished = run["state"] in @review_states and intent["kind"] in ~w(TICKET_PUSH TICKET_PUSH_CAS_RECOVERY)
    run["state"] in ~w(PUSHING CI_PUSHING) or late_unfinished
  end

  defp unfinished_push_notice(run, intent, phase, recovery) do
    if phase not in ~w(COMPLETE COMPLETED) and (phase != "PREPARED" or recovery.at != nil) do
      execution = decode_map(intent["execution_json"])

      reason =
        if phase == "PREPARED",
          do: "Push preparation was deferred; execution has not been authorized.",
          else: "Push outcome is not confirmed; the recorded workflow stage does not prove a successful remote push."

      next_action =
        if phase == "PREPARED",
          do: "The controller may retry preparation after refreshing its authorization and evidence.",
          else: "Reconcile the existing push and its exact remote/receipt evidence before any retry."

      notice(
        "PUSH",
        phase,
        intent["reservation_key"],
        reason <> push_failure(intent) <> recovery.reason,
        recovery.at || get_in(intent, ["failure", "evidence_at"]) || intent["issued_at"] || get_in(execution, ["authorization", "observed_at"]) || run["updated_at"],
        next_action
      )
    end
  end

  defp push_recovery_outcome(store, run, intent) do
    key = Enum.join(["ticket-push", intent["binding_sha256"], intent["owner_nonce"]], ":")

    row =
      Store.one!(
        store,
        "SELECT occurred_at,payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_RECOVERY_OUTCOME' AND json_extract(payload_json,'$.operation_key') = ? ORDER BY id DESC LIMIT 1",
        [run["run_id"], key]
      )

    payload = if row, do: decode_map(row["payload_json"]), else: %{}

    if payload["status"] == "DEFERRED",
      do: %{reason: " Recovery deferred: " <> bounded_reason(payload["reason"]), at: row["occurred_at"]},
      else: %{reason: "", at: nil}
  end

  defp push_failure(%{"failure" => failure}) when is_map(failure), do: " Recorded failure: " <> bounded_reason(failure["code"] || failure["kind"] || "unknown")
  defp push_failure(_intent), do: ""

  defp handoff_summary(run) do
    intent = decode_map(run["candidate_handoff"])

    if intent["kind"] in ~w(TICKET_PUSH TICKET_PUSH_CAS_RECOVERY) do
      %{
        kind: intent["kind"],
        phase: intent["phase"],
        evidence_at: intent["completed_at"] || intent["issued_at"] || intent["prepared_at"],
        previous_outcome: intent["old_outcome"] || intent["original_outcome"]
      }
    end
  end

  defp journal_attention(store, run) do
    stage = run["state"]

    checkout =
      if stage == "ADMITTING_WRITER" do
        Store.one!(store, "SELECT run_id AS operation_key, phase, last_error FROM ticket_checkout_intents WHERE run_id = ? AND phase IN ('MUTATING_UNCERTAIN','RECONCILE_REQUIRED')", [run["run_id"]])
      end

    jira =
      if stage in ~w(ADMITTING_WRITER MR_CREATING CI_MR_CREATING) do
        operation = if stage == "ADMITTING_WRITER", do: "START_IMPLEMENTATION", else: "REVIEW_READY"

        Store.one!(
          store,
          "SELECT operation_key, phase, updated_at FROM ticket_jira_effects WHERE run_id = ? AND operation = ? AND phase IN ('FIRST_UNCERTAIN','SECOND_UNCERTAIN') ORDER BY updated_at DESC LIMIT 1",
          [run["run_id"], operation]
        )
      end

    [{"CHECKOUT", checkout}, {"JIRA", jira}]
    |> Enum.flat_map(fn
      {_source, nil} ->
        []

      {source, row} ->
        [
          notice(
            source,
            row["phase"],
            row["operation_key"],
            bounded_reason(row["last_error"] || "An issued operation has an unconfirmed outcome."),
            row["updated_at"] || run["updated_at"],
            "Reconcile the existing operation and its recorded receipt; do not issue a replacement."
          )
        ]
    end)
  end

  defp request_attention(store, run, now, stale_seconds) do
    requests =
      Store.query!(
        store,
        """
        SELECT request.* FROM desktop_requests AS request
        WHERE json_type(CASE WHEN json_valid(request.metadata_json) THEN request.metadata_json ELSE '{}' END, '$.maintenance_operation') IS NULL
          AND (EXISTS (SELECT 1 FROM factory_tasks AS task WHERE request.target_kind = 'TASK' AND task.task_key = request.target_key AND task.run_id = ? AND task.stage = ? AND task.status NOT IN ('COMPLETE','CONSUMED') AND #{current_task_sql()})
            OR (request.target_kind = 'CONTROLLER' AND json_extract(CASE WHEN json_valid(request.metadata_json) THEN request.metadata_json ELSE '{}' END, '$.delivery_operation.run_id') = ?)
            OR EXISTS (SELECT 1 FROM ticket_chat_runs AS link JOIN ticket_chats AS chat ON chat.chat_key = link.chat_key WHERE link.run_id = ? AND request.request_key = chat.presentation_request_key))
          AND NOT EXISTS (SELECT 1 FROM desktop_requests AS newer WHERE newer.target_kind = request.target_kind AND newer.target_key = request.target_key
            AND json_type(CASE WHEN json_valid(newer.metadata_json) THEN newer.metadata_json ELSE '{}' END, '$.maintenance_operation') IS NULL
            AND (newer.created_at > request.created_at OR (newer.created_at = request.created_at AND newer.rowid > request.rowid)))
        ORDER BY request.created_at DESC, request.rowid DESC LIMIT 10
        """,
        [run["run_id"], run["state"], run["run_id"], run["run_id"]]
      )

    Enum.flat_map(requests.rows, fn row ->
      request = Map.new(Enum.zip(requests.columns, row))
      binding = get_in(decode_map(request["metadata_json"]), ["delivery_operation"])
      current = request["target_kind"] != "CONTROLLER" or current_binding?(binding, run)
      phase = request["status"]
      failed = phase in ~w(FAILED RECONCILE_REQUIRED)
      uncertain = phase in ~w(CREATE_UNCERTAIN FOLLOWUP_UNCERTAIN THREAD_RECORDED)
      stale = phase in ~w(PENDING CREATE_UNCERTAIN FOLLOWUP_UNCERTAIN THREAD_RECORDED) and aged?(request["claimed_at"] || request["created_at"], now, stale_seconds)

      if current and (failed or stale or (uncertain and request["target_kind"] == "CONTROLLER")) do
        source = if request["target_kind"] == "TICKET_CHAT", do: "PARENT_SYNC", else: request["target_kind"]

        reason =
          if present?(request["failure_code"]),
            do: bounded_reason(request["failure_code"]),
            else: "The existing Desktop handoff has not been confirmed#{if stale, do: " within the progress budget", else: ""}."

        signal = notice(source, phase, request["request_key"], reason, request["updated_at"], "Reconcile the existing bound Desktop request; do not resend or create a replacement.")
        communication = presentation_request?(store, run, request)
        [if(communication, do: %{signal | blocking: false, category: "COMMUNICATION"}, else: signal)]
      else
        []
      end
    end)
  end

  defp presentation_request?(store, run, request) do
    chat =
      Store.one!(store, "SELECT chat.* FROM ticket_chat_runs AS link JOIN ticket_chats AS chat ON chat.chat_key = link.chat_key WHERE link.run_id = ? AND chat.presentation_request_key = ?", [
        run["run_id"],
        request["request_key"]
      ])

    is_map(chat) and request["target_kind"] == "TICKET_CHAT" and request["action"] == "FOLLOWUP" and
      request["target_key"] == chat["chat_key"] and is_binary(chat["thread_id"]) and request["existing_thread_id"] == chat["thread_id"] and
      Enum.all?(~w(cwd model reasoning_effort), &(request[&1] == chat[&1])) and chat["context_sequence"] > 0 and
      TicketChat.validate_request(store, request) == :ok and DesktopRequest.payload_intact?(request) and
      is_binary(request["prompt"]) and String.contains?(request["prompt"], "Controller-observed AS-OF presentation only; not human input or source authority.")
  end

  defp ci_attention(run) do
    evidence = decode_map(run["ci_evidence_json"])

    if run["state"] == "CI_WAITING" and evidence["status"] == "BLOCK" and is_binary(run["candidate_sha"]) and
         run["ci_preflight_sha"] == run["candidate_sha"] and evidence["sha"] == run["candidate_sha"] and
         {evidence["iid"], evidence["mr_url"], evidence["pipeline_id"]} == {run["mr_iid"], run["mr_url"], run["ci_pipeline_id"]} and
         is_integer(evidence["pipeline_id"]) and evidence["pipeline_id"] > 0 and
         evidence["pipeline_source"] == "merge_request_event" and evidence["pipeline_url"] == run["ci_pipeline_url"] and
         get_in(evidence, ["source_binding", "candidate_sha"]) == run["candidate_sha"] and
         ((get_in(evidence, ["source_binding", "kind"]) == "HEAD" and evidence["pipeline_sha"] == run["candidate_sha"] and evidence["pipeline_ref"] == "refs/merge-requests/#{run["mr_iid"]}/head") or
            (get_in(evidence, ["source_binding", "kind"]) == "MERGE" and get_in(evidence, ["source_binding", "merge_sha"]) == evidence["pipeline_sha"] and
               evidence["pipeline_ref"] == "refs/merge-requests/#{run["mr_iid"]}/merge")) do
      jobs = evidence["failed_jobs"] || []
      jobs = if is_list(jobs), do: jobs, else: []
      jobs = jobs |> Enum.filter(&is_map/1) |> Enum.map(fn job -> %{name: bounded_reason(job["name"]), status: bounded_reason(job["status"]), url: safe_ci_url(job["web_url"], run["mr_url"])} end)

      notice(
        "CI",
        "BLOCK",
        Integer.to_string(evidence["pipeline_id"]),
        "The recorded exact-candidate pipeline did not pass.",
        run["ci_last_checked_at"],
        "Inspect the bound failed pipeline and jobs; independent verification remains gated on CI passing."
      )
      |> Map.merge(%{pipeline_url: safe_ci_url(evidence["pipeline_url"], run["mr_url"]), failed_jobs: jobs})
    end
  end

  defp safe_ci_url(url, mr_url) when is_binary(url) and is_binary(mr_url) do
    case {URI.parse(url), URI.parse(mr_url)} do
      {%URI{scheme: "https", host: host, userinfo: nil}, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp safe_ci_url(_url, _mr_url), do: nil

  defp primary_action(_run, %{blocking: true, next_action: action}), do: action
  defp primary_action(%{state: "CI_MR_CREATING"}, _signal), do: "Adopt the exact pushed candidate into the recorded draft MR, then qualify its pipeline."
  defp primary_action(%{state: "CI_WAITING"}, _signal), do: "Qualify the current MR pipeline; independent verification waits for CI to pass."
  defp primary_action(%{state: "READY_FOR_REVIEW"}, _signal), do: "Review the recorded draft MR."
  defp primary_action(%{state: "AWAITING_VALIDATION"}, _signal), do: "Complete the contracted validation for the exact candidate."
  defp primary_action(run, _signal), do: get_in(run, [:ticket_context, :next_action]) || "Continue the recorded delivery stage through its existing controller operation."

  defp check_attention(store, run, now, stale_seconds) do
    row =
      Store.one!(
        store,
        """
        SELECT check_run.check_key, check_run.phase, check_run.error, check_run.receipt_json, task.updated_at
        FROM controller_checks AS check_run JOIN worker_evidence AS evidence ON evidence.request_key = check_run.worker_request_key
        JOIN factory_tasks AS task ON task.task_key = evidence.task_key
        WHERE task.run_id = ? AND (task.stage = ? OR (? IN ('READY_FOR_REVIEW','AWAITING_VALIDATION') AND EXISTS (SELECT 1 FROM workspace_access AS access WHERE access.reservation_key = check_run.reservation_key AND access.released_at IS NULL)))
          AND task.status NOT IN ('COMPLETE','CONSUMED') AND evidence.status != 'CONSUMED' AND #{current_task_sql()}
        ORDER BY check_run.rowid DESC LIMIT 1
        """,
        [run["run_id"], run["state"], run["state"]]
      )

    if row do
      receipt = decode_map(row["receipt_json"])
      failed = receipt["result"] == "FAIL" or receipt["timed_out"] == true or present?(row["error"])
      stale = row["phase"] in ~w(PREPARED RUNNING) and aged?(row["updated_at"], now, stale_seconds)

      if failed or stale or row["phase"] == "RECONCILE_REQUIRED" do
        phase = if receipt["timed_out"] == true, do: "TIMED_OUT", else: if(failed and row["phase"] == "COMPLETE", do: "FAILED", else: row["phase"])

        notice(
          "CONTROLLER_CHECK",
          phase,
          row["check_key"],
          bounded_reason(row["error"] || "Controller check failed or lacks confirmed completion."),
          row["updated_at"],
          "Reconcile the existing controller check before admitting more work."
        )
      end
    end
  end

  defp worker_attention(store, run) do
    row =
      Store.one!(
        store,
        """
        SELECT evidence.request_key, evidence.status, evidence.failure_code, task.updated_at
        FROM worker_evidence AS evidence JOIN factory_tasks AS task ON task.task_key = evidence.task_key
        WHERE evidence.run_id = ? AND task.stage = ? AND task.status NOT IN ('COMPLETE','CONSUMED') AND #{current_task_sql()}
          AND evidence.status = 'RECONCILE_REQUIRED'
          AND NOT EXISTS (SELECT 1 FROM worker_evidence AS newer WHERE newer.task_key = evidence.task_key AND newer.rowid > evidence.rowid)
        ORDER BY evidence.rowid DESC LIMIT 1
        """,
        [run["run_id"], run["state"]]
      )

    if row,
      do:
        notice(
          "NATIVE_WORKER",
          row["status"],
          row["request_key"],
          bounded_reason(row["failure_code"] || "The current native worker outcome is unconfirmed."),
          row["updated_at"],
          "Reconcile the existing native/provider attempt before resuming."
        )
  end

  defp task_attention(run, tasks, now, stale_seconds) do
    tasks
    |> Enum.filter(&current_task?(&1, run))
    |> Enum.find_value(fn task ->
      cond do
        task.status in ~w(FAILED STALE) or (task.status == "RETRY_PENDING" and present?(task.failure_code)) ->
          notice(
            "TASK",
            task.status,
            task.task_key,
            bounded_reason(task.failure_code || "The current worker is stopped or awaiting recovery."),
            task.updated_at,
            "Inspect the recorded worker failure and reconcile this same attempt before resuming."
          )

        task.status in ~w(STARTING RUNNING WAITING_FOR_BROKER WAITING_FOR_WRITER RETRY_PENDING) and aged?(task.updated_at, now, stale_seconds) ->
          notice(
            "TASK",
            "PROGRESS_STALE",
            task.task_key,
            "No recorded worker progress within the configured progress budget; the native/provider outcome is unknown.",
            task.updated_at,
            "Inspect and reconcile the existing native worker; age alone does not authorize a replacement."
          )

        true ->
          nil
      end
    end)
  end

  defp current_task?(task, run) do
    expected =
      case task.role do
        "change-verifier" -> "#{run["run_id"]}:change-verifier:#{run["verifier_round"] || 0}"
        role -> "#{run["run_id"]}:#{role}"
      end

    task.stage == run["state"] and task.status not in ~w(COMPLETE CONSUMED) and
      (run["execution_mode"] != "TICKET_SUPERVISOR_V1" or task.task_key == expected)
  end

  defp current_task_sql do
    """
    EXISTS (SELECT 1 FROM runs AS owner WHERE owner.run_id = task.run_id AND
      (COALESCE(owner.execution_mode, 'LEGACY') != 'TICKET_SUPERVISOR_V1' OR task.task_key = CASE task.role
        WHEN 'change-verifier' THEN owner.run_id || ':change-verifier:' || COALESCE(owner.verifier_round, 0)
        ELSE owner.run_id || ':' || task.role END))
    """
  end

  defp handoff_attention(%{handoff_attention: attention}) when is_map(attention),
    do: notice("TASK", "RECONCILE_REQUIRED", attention.request_key, attention.reason, nil, "Reconcile the existing worker handoff before retrying.")

  defp handoff_attention(_run), do: nil

  defp progress_attention(run, tasks, now, stale_seconds) do
    recent_worker = Enum.any?(tasks, &(current_task?(&1, run) and &1.status in @active_task_statuses and not aged?(&1.updated_at, now, stale_seconds)))
    evidence_at = if run["state"] == "CI_WAITING", do: run["ci_last_checked_at"] || run["updated_at"], else: run["updated_at"]

    if not recent_worker and run["state"] not in (@terminal_states ++ ["AWAITING_CONTRACT_INPUT"]) and aged?(evidence_at, now, stale_seconds) do
      notice(
        "WORKFLOW",
        "PROGRESS_STALE",
        run["run_id"],
        "No recorded stage progress within the configured progress budget; successful scheduler ticks do not prove this ticket advanced.",
        evidence_at,
        "Inspect the recorded stage and reconcile its existing operation before retrying."
      )
    end
  end

  defp current_binding?(binding, run) when is_map(binding),
    do: Enum.all?(~w(run_id issue_key stage candidate_sha spec_revision contract_sha256), fn field -> binding[field] == run[if(field == "stage", do: "state", else: field)] end)

  defp current_binding?(_binding, _run), do: false

  defp aged?(timestamp, now, seconds) do
    with value when is_binary(value) <- timestamp, {:ok, at, _} <- DateTime.from_iso8601(value), do: DateTime.diff(now, at, :second) > seconds, else: (_ -> false)
  end

  defp notice(source, phase, key, reason, at, next_action),
    do: %{source: source, phase: phase, request_key: key, reason: reason, evidence_at: at, next_action: next_action, blocking: true, category: "DELIVERY"}

  defp bounded_reason(reason), do: String.slice(to_string(reason), 0, 512)

  defp decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_map(_json), do: %{}

  defp enrich_ticket_context(runs, store, opts) do
    context_reader = Keyword.get(opts, :ticket_context, &TicketContext.context/2)
    synchronization_reader = Keyword.get(opts, :ticket_synchronization, &TicketChatOutbox.synchronization/2)

    Enum.map(runs, &enrich_ticket_context_run(&1, store, context_reader, synchronization_reader))
  end

  defp enrich_ticket_context_run(run, store, context_reader, synchronization_reader) do
    case safe_read(fn -> context_reader.(store, run.run_id) end) do
      {:ok, context} ->
        synchronization = read_ticket_synchronization(store, run.run_id, synchronization_reader)
        parent_thread_id = get_in(context, [:identity, "thread_id"]) || get_in(context, [:identity, :thread_id])

        Map.put(run, :ticket_context, %{
          available: true,
          parent_thread_id: parent_thread_id,
          codex_thread_url: codex_thread_url(parent_thread_id),
          source_stage: run.state,
          candidate_sha: get_in(context, [:run, "candidate_sha"]),
          contract_revision: get_in(context, [:run, "spec_revision"]),
          ci: context.ci,
          validation: context.manual_validation,
          questions: Enum.map(context.open_questions || [], &Map.take(&1, ~w(question_key opened_at binding body answers))),
          actionable_question_count: Enum.count(context.open_questions || [], &(Map.get(&1, "binding") == "CURRENT")),
          next_action: context.next_action,
          writer_disposition: Map.take(Map.get(context, :writer_disposition) || %{}, [:status]),
          worker_tasks: context.tasks || [],
          attributed_usage: %{status: "UNKNOWN", tokens: nil, cost: nil, reason: "Per-run and per-turn factory token usage and cost are not recorded."},
          checkout_count: checkout_evidence(store, run.run_id),
          synchronization: synchronization_projection(synchronization)
        })

      {:error, reason} ->
        Map.put(run, :ticket_context, %{
          available: false,
          error: inspect(reason),
          parent_thread_id: nil,
          codex_thread_url: nil,
          source_stage: run.state,
          next_action: nil,
          questions: [],
          synchronization: %{status: "UNKNOWN"},
          attributed_usage: %{status: "UNKNOWN", tokens: nil, cost: nil}
        })
    end
  end

  defp read_ticket_synchronization(store, run_id, synchronization_reader) do
    safe_read(fn -> synchronization_reader.(store, run_id) end)
  end

  defp codex_thread_url(thread_id) when is_binary(thread_id), do: "codex://threads/#{URI.encode(thread_id)}"
  defp codex_thread_url(_thread_id), do: nil

  defp checkout_evidence(store, run_id) do
    count = Store.one!(store, "SELECT COUNT(*) AS total FROM ticket_checkout_intents WHERE run_id = ?", [run_id])["total"]
    %{physical_checkouts: %{status: "UNKNOWN", count: nil}, recorded_intents: %{status: "RECORDED", count: count}}
  end

  defp synchronization_projection({:ok, synchronization}) do
    request_status = get_in(synchronization, [:request, "status"])
    status = if is_binary(request_status), do: request_status, else: Map.get(synchronization, :status, "UNKNOWN")
    Map.put(synchronization, :status, status)
  end

  defp synchronization_projection({:error, reason}), do: %{status: "UNAVAILABLE", error: inspect(reason)}

  defp safe_read(read) do
    read.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp project_runs(runs, tasks_by_run, issue_by_run, handoffs) do
    Enum.map(runs, fn run ->
      run
      |> project_run()
      |> Map.put(
        :tasks,
        tasks_by_run
        |> Map.get(run["run_id"], [])
        |> Enum.map(&project_task(&1, issue_by_run, handoffs))
      )
      |> Map.put(:handoff_attention, handoffs |> Map.values() |> Enum.find(&(&1.run_id == run["run_id"])))
    end)
  end

  defp attention_handoffs(store) do
    Store.query!(store, """
    SELECT request.request_key, request.target_key, request.action, request.failure_code, task.run_id, task.role
    FROM desktop_requests AS request
    JOIN factory_tasks AS task ON task.task_key = request.target_key
    WHERE request.target_kind = 'TASK' AND request.status IN ('RECONCILE_REQUIRED', 'FAILED')
      AND json_type(request.metadata_json, '$.maintenance_operation') IS NULL
      AND task.status IN ('STARTING', 'RUNNING', 'WAITING_FOR_BROKER', 'WAITING_FOR_WRITER', 'RETRY_PENDING', 'STALE')
      AND NOT EXISTS (
        SELECT 1 FROM desktop_requests AS newer
        WHERE newer.target_kind = request.target_kind AND newer.target_key = request.target_key
          AND json_type(newer.metadata_json, '$.maintenance_operation') IS NULL
          AND (newer.created_at > request.created_at
            OR (newer.created_at = request.created_at AND newer.rowid > request.rowid))
      )
    ORDER BY request.created_at DESC, request.rowid DESC
    """).rows
    |> Enum.reduce(%{}, fn [request_key, task_key, action, failure, run_id, role], acc ->
      Map.put_new(acc, task_key, %{
        request_key: request_key,
        run_id: run_id,
        label: handoff_label(role, action, failure),
        reason: handoff_reason(failure)
      })
    end)
    |> native_task_attention(store)
  end

  defp native_task_attention(handoffs, store) do
    Store.query!(store, """
    SELECT task.task_key, task.run_id, task.failure_code,
      (SELECT request_key FROM worker_evidence WHERE task_key = task.task_key
        AND status = 'RECONCILE_REQUIRED' ORDER BY created_at DESC LIMIT 1)
    FROM factory_tasks AS task
    JOIN runs AS run ON run.run_id = task.run_id
    WHERE run.execution_mode = 'TICKET_SUPERVISOR_V1' AND task.stage = run.state
      AND task.task_key = CASE task.role
        WHEN 'feature-planner' THEN run.run_id || ':feature-planner'
        WHEN 'feature-writer' THEN run.run_id || ':feature-writer'
        WHEN 'change-verifier' THEN run.run_id || ':change-verifier:' || COALESCE(run.verifier_round, 0)
        WHEN 'manual-validator' THEN run.run_id || ':manual-validator'
      END
      AND task.status IN ('STALE', 'RETRY_PENDING', 'WAITING_FOR_WRITER')
      AND task.failure_code IS NOT NULL AND task.failure_code != ''
    """).rows
    |> Enum.reduce(handoffs, fn [task_key, run_id, failure, request_key], acc ->
      Map.put_new(acc, task_key, %{
        request_key: request_key || task_key,
        run_id: run_id,
        label: "Native worker needs attention",
        reason: "Reconcile the existing native worker before retrying. Reason: #{String.slice(failure, 0, 512)}"
      })
    end)
  end

  defp handoff_label("change-verifier", "CREATE", "CREATE_THREAD_INVALID_ARGUMENTS"), do: "Verifier creation failed"
  defp handoff_label(_role, "CREATE", "CREATE_THREAD_INVALID_ARGUMENTS"), do: "Worker creation failed"
  defp handoff_label("change-verifier", "CREATE", _failure), do: "Verifier creation needs attention"
  defp handoff_label(_role, "CREATE", _failure), do: "Worker creation needs attention"
  defp handoff_label(_role, _action, _failure), do: "Worker handoff needs attention"

  defp handoff_reason("CREATE_THREAD_INVALID_ARGUMENTS"),
    do: "Desktop rejected the creation arguments. Correct them and recover this same request."

  defp handoff_reason(failure),
    do: "Reconcile this Desktop request before retrying. Reason: #{failure || "unknown"}"

  defp project_control(control) do
    %{
      status: control["status"],
      scope: control["scope"],
      dispatcher_id: control["dispatcher_id"],
      generation: control["generation"],
      tick_id: control["tick_id"],
      lease_expires_at: control["lease_expires_at"],
      updated_at: control["updated_at"],
      controller_thread_id: control["controller_thread_id"],
      controller_turn_id: control["controller_turn_id"],
      controller_codex_project_id: control["controller_codex_project_id"],
      controller_model: control["controller_model"],
      controller_reasoning_effort: control["controller_reasoning_effort"],
      controller_writer_conflict_since: control["controller_writer_conflict_since"],
      controller_writer_conflict_count: control["controller_writer_conflict_count"] || 0,
      runtime_identity: control["runtime_identity"],
      tick_health: control["tick_health"]
    }
  end

  defp project_broker(store, factory) do
    if value(factory, :task_transport) == "desktop_broker" do
      summary =
        Store.one!(
          store,
          """
          SELECT
            COUNT(CASE WHEN status = 'PENDING' THEN 1 END) AS pending,
            COUNT(CASE WHEN status IN ('CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED') THEN 1 END) AS claimed_unverified,
            COUNT(CASE WHEN status IN ('CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN') THEN 1 END) AS uncertain,
            COUNT(CASE WHEN status = 'THREAD_RECORDED' THEN 1 END) AS awaiting_result,
            COUNT(CASE WHEN status = 'RECONCILE_REQUIRED' THEN 1 END) AS needs_reconciliation,
            MAX(CASE WHEN status = 'SUCCEEDED' THEN updated_at END) AS last_completed_at
          FROM desktop_requests
          """
        )

      %{
        pending: summary["pending"],
        claimed_unverified: summary["claimed_unverified"],
        uncertain: summary["uncertain"],
        awaiting_result: summary["awaiting_result"],
        needs_reconciliation: summary["needs_reconciliation"],
        last_completed_at: summary["last_completed_at"]
      }
    end
  end

  defp project_intake({:ok, nil}, _factory, _runs) do
    %{available: false, observed_at: nil, count: 0, issues: [], error: nil}
  end

  defp project_intake({:ok, intake}, factory, runs) do
    run_by_issue =
      Enum.reduce(runs, %{}, fn run, acc ->
        Map.put_new(acc, run["issue_key"], run)
      end)

    issues =
      Enum.map(intake.snapshots, fn snapshot ->
        project_intake_issue(snapshot, value(factory, :repositories, %{}), run_by_issue, intake.decisions)
      end)
      |> Enum.reject(&hidden_status?(&1.status))

    %{
      available: true,
      observed_at: intake.observed_at,
      count: length(issues),
      issues: issues,
      error: nil
    }
  end

  defp project_intake({:error, reason}, _factory, _runs) do
    %{
      available: false,
      observed_at: nil,
      count: 0,
      issues: [],
      error: %{code: "intake_snapshot_unavailable", message: inspect(reason)}
    }
  end

  defp project_intake_issue(snapshot, repositories, run_by_issue, decisions) do
    issue_key = value(snapshot, :key)
    route = project_route(Queue.route(snapshot, repositories))
    run = run_by_issue[issue_key]
    rejection = if run, do: nil, else: decisions[issue_key]
    admission_error = if rejection, do: %{code: rejection["code"], message: rejection["message"]}, else: nil

    %{
      issue_key: issue_key,
      issue_url: safe_external_url(value(snapshot, :url) || value(snapshot, :self)),
      summary: text_value(value(snapshot, :summary), "Untitled Jira issue"),
      status: status_name(value(snapshot, :status)),
      labels: labels(value(snapshot, :labels, [])),
      project_key: text_value(value(snapshot, :project_key), nil),
      updated_at: text_value(value(snapshot, :updated), nil),
      classification: classification(Queue.classify(snapshot)),
      routing_status: route.status,
      repo_key: route.repo_key,
      admission_error: admission_error,
      local_state:
        cond do
          run -> run["state"]
          rejection -> "INTAKE_BLOCKED"
          true -> "QUEUED"
        end
    }
  end

  defp project_route({:ok, route}), do: %{status: "ROUTED", repo_key: route["repo_key"]}
  defp project_route({:error, :routing_required}), do: %{status: "ROUTING_REQUIRED", repo_key: nil}

  defp project_route({:error, :ambiguous_repository_route}),
    do: %{status: "AMBIGUOUS", repo_key: nil}

  defp project_route({:error, {:incomplete_repository_route, _missing}}),
    do: %{status: "INVALID_ROUTE", repo_key: nil}

  defp classification(:specification), do: "SPECIFICATION"
  defp classification(:delivery), do: "DELIVERY"
  defp classification(:reconcile), do: "RECONCILE"
  defp classification(:ignore), do: "IGNORED"
  defp classification({:error, _reason}), do: "BLOCKED"

  defp status_name(%{"name" => name}), do: text_value(name, "Unknown")
  defp status_name(status), do: text_value(status, "Unknown")

  defp labels(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"name" => name} -> text_value(name, nil)
      value -> text_value(value, nil)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp labels(_values), do: []

  defp text_value(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp text_value(_value, default), do: default

  defp project_run(run) do
    %{
      run_id: run["run_id"],
      issue_key: run["issue_key"],
      summary: run_summary(run),
      issue_url: issue_url(run["snapshot_json"]),
      kind: run["kind"],
      state: run["state"],
      jira_status: run_status(run),
      repo_key: run["repo_key"],
      branch: run["branch"],
      worktree: run["worktree"],
      workspace_state: run["workspace_state"],
      hibernated_at: run["hibernated_at"],
      candidate_sha: run["candidate_sha"],
      mr_url: safe_external_url(run["mr_url"]),
      mr_iid: run["mr_iid"],
      model: run["model"],
      reasoning_effort: run["reasoning_effort"],
      implementation_iteration: run["implementation_iteration"],
      code_repair_round: run["code_repair_round"] || 0,
      validation_repair_round: run["validation_repair_round"] || 0,
      last_error: run["last_error"],
      failure_code: run["failure_code"],
      handoff: handoff_summary(run),
      updated_at: run["updated_at"]
    }
  end

  defp hidden_from_dashboard?(run), do: hidden_status?(run_status(run))

  defp run_summary(run) do
    issue_key = run["issue_key"]

    case Jason.decode(run["snapshot_json"] || "") do
      {:ok, %{"key" => ^issue_key, "summary" => summary}} -> text_value(summary, nil)
      _other -> nil
    end
  end

  defp run_status(run) do
    case Jason.decode(run["snapshot_json"] || "") do
      {:ok, snapshot} when is_map(snapshot) -> status_name(value(snapshot, :status, "Unknown"))
      _other -> "Unknown"
    end
  end

  defp hidden_status?(status) when is_binary(status) do
    String.upcase(String.trim(status)) in ["IN TESTING", "DONE"]
  end

  defp hidden_status?(_status), do: false

  defp project_task(task, issue_by_run, handoffs) do
    %{
      task_key: task["task_key"],
      run_id: task["run_id"],
      issue_key: issue_by_run[task["run_id"]],
      stage: task["stage"],
      role: task["role"],
      status: task["status"],
      thread_id: task["thread_id"],
      turn_id: task["turn_id"],
      codex_project_id: task["codex_project_id"],
      model: task["model"],
      reasoning_effort: task["reasoning_effort"],
      failure_code: task["failure_code"],
      handoff_attention: handoffs[task["task_key"]],
      updated_at: task["updated_at"]
    }
  end

  defp project_event(event) do
    %{
      id: event["id"],
      occurred_at: event["occurred_at"],
      event_type: event["event_type"],
      run_id: event["run_id"],
      issue_key: event["issue_key"]
    }
  end

  defp counts(runs, tasks, handoffs, enriched_by_id) do
    current_runs = Enum.uniq_by(runs, & &1["issue_key"])

    attention_run_ids =
      (handoffs |> Map.values() |> Enum.map(& &1.run_id)) ++
        (enriched_by_id |> Map.values() |> Enum.filter(&Enum.any?(&1.attention_signals, fn signal -> signal.blocking end)) |> Enum.map(& &1.run_id))

    %{
      total_runs: length(current_runs),
      in_progress: Enum.count(current_runs, &(&1["state"] not in @terminal_states and &1["run_id"] not in attention_run_ids)),
      review_ready: Enum.count(current_runs, &(&1["state"] in @review_states)),
      blocked: Enum.count(current_runs, &(projected_run_blocked?(enriched_by_id[&1["run_id"]]) or &1["run_id"] in attention_run_ids)),
      hibernated: Enum.count(current_runs, &(&1["workspace_state"] == "HIBERNATED")),
      visible_tasks: Enum.count(tasks, &present?(&1["thread_id"])),
      by_state: Enum.frequencies_by(current_runs, & &1["state"])
    }
  end

  defp overview(runs, tasks, intake, stalled_run_ids) do
    current_runs = Enum.uniq_by(runs, & &1.issue_key)
    run_by_issue = Map.new(current_runs, &{&1.issue_key, &1})
    tasks_by_run = Enum.group_by(tasks, & &1.run_id)
    issue_by_key = Map.new(intake.issues, &{&1.issue_key, &1})

    issue_keys =
      intake.issues
      |> Enum.reject(fn issue -> terminal_current_run?(run_by_issue[issue.issue_key]) end)
      |> Enum.map(& &1.issue_key)
      |> Kernel.++(
        current_runs
        |> Enum.reject(&(&1.state in @overview_hidden_states))
        |> Enum.map(& &1.issue_key)
      )
      |> Enum.uniq()

    Enum.reduce(
      issue_keys,
      %{active: 0, queued: 0, review_ready: 0, needs_attention: 0, delivery_blocked: 0, communication_attention: 0, by_issue: %{}},
      fn issue_key, acc ->
        run = run_by_issue[issue_key]
        run_tasks = if run, do: Map.get(tasks_by_run, run.run_id, []), else: []
        state = overview_state(issue_by_key[issue_key], run, run_tasks, stalled_run_ids)

        acc
        |> Map.update(overview_count_key(state), 1, &(&1 + 1))
        |> Map.update!(:delivery_blocked, &(&1 + if(state == "NEEDS_ATTENTION", do: 1, else: 0)))
        |> Map.update!(:communication_attention, &(&1 + if(run && Enum.any?(run.attention_signals, fn signal -> signal.category == "COMMUNICATION" end), do: 1, else: 0)))
        |> put_in([:by_issue, issue_key], state)
      end
    )
  end

  defp overview_state(issue, run, tasks, stalled_run_ids) do
    cond do
      run && presentation_only_attention?(run) && run.state == "READY_FOR_REVIEW" -> "REVIEW_READY"
      run && presentation_only_attention?(run) && run.state == "AWAITING_VALIDATION" -> "VALIDATION_PENDING"
      run && communication_only_attention?(run) -> overview_unblocked_state(issue, run, tasks)
      run && Map.get(run, :attention) -> "NEEDS_ATTENTION"
      projected_run_blocked?(run) -> "NEEDS_ATTENTION"
      run && run.handoff_attention -> "NEEDS_ATTENTION"
      run && run.state == "AWAITING_CONTRACT_INPUT" -> "NEEDS_ATTENTION"
      run && run.run_id in stalled_run_ids -> "NEEDS_ATTENTION"
      true -> overview_unblocked_state(issue, run, tasks)
    end
  end

  defp presentation_only_attention?(run), do: communication_only_attention?(run)

  defp communication_only_attention?(run),
    do: run.attention != nil and Enum.all?(run.attention_signals, &(&1.category == "COMMUNICATION" and not &1.blocking)) and not projected_run_blocked?(run) and is_nil(run.handoff_attention)

  defp overview_unblocked_state(issue, run, tasks) do
    cond do
      review_run?(run) -> "REVIEW_READY"
      run && run.state == "AWAITING_VALIDATION" -> "VALIDATION_PENDING"
      active_tasks?(tasks) -> "ACTIVE"
      attention_issue?(issue) -> "NEEDS_ATTENTION"
      active_run?(run) -> "ACTIVE"
      true -> "QUEUED"
    end
  end

  defp stalled_native_run_ids(_store, _runs, %{status: status}) when status != "PAUSED", do: []
  defp stalled_native_run_ids(_store, [], _control), do: []

  defp stalled_native_run_ids(store, runs, _control) do
    run_ids = Enum.map(runs, & &1["run_id"])
    placeholders = Enum.map_join(run_ids, ", ", fn _id -> "?" end)

    Store.query!(
      store,
      """
      SELECT DISTINCT task.run_id
      FROM desktop_requests AS request
      JOIN factory_tasks AS task ON task.task_key = request.target_key
      WHERE request.target_kind = 'TASK'
        AND (
          request.status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')
          OR (request.action = 'CREATE' AND request.status = 'SUCCEEDED' AND task.status = 'STARTING')
        )
        AND task.run_id IN (#{placeholders})
      """,
      run_ids
    ).rows
    |> Enum.map(&hd/1)
  end

  defp overview_count_key("ACTIVE"), do: :active
  defp overview_count_key("QUEUED"), do: :queued
  defp overview_count_key("REVIEW_READY"), do: :review_ready
  defp overview_count_key("NEEDS_ATTENTION"), do: :needs_attention
  defp overview_count_key("VALIDATION_PENDING"), do: :validation_pending

  defp review_run?(%{state: state}), do: state in @overview_review_states
  defp review_run?(_run), do: false

  defp active_run?(%{state: state}), do: state not in @terminal_states
  defp active_run?(_run), do: false

  defp terminal_current_run?(%{state: state}), do: state in @overview_hidden_states
  defp terminal_current_run?(_run), do: false

  defp projected_run_blocked?(%{} = run) do
    state = run.state || ""

    state == "FAILED" or String.contains?(state, "BLOCK") or present?(run.last_error) or
      get_in(run, [:ticket_context, :writer_disposition, :status]) == "BLOCKED"
  end

  defp projected_run_blocked?(_run), do: false

  defp active_tasks?(tasks), do: Enum.any?(tasks, &(&1.status in @active_task_statuses))

  defp attention_issue?(nil), do: false

  defp attention_issue?(issue) do
    issue.classification == "BLOCKED" or issue.routing_status != "ROUTED" or issue.local_state == "INTAKE_BLOCKED"
  end

  defp capacities(store, factory, opts) do
    repositories = value(factory, :repositories, %{})
    capacity_opts = Keyword.get(opts, :capacity_opts, [])

    repositories
    |> Enum.sort_by(fn {repo_key, _route} -> repo_key end)
    |> Enum.map(fn {repo_key, _route} ->
      case Capacity.snapshot(store, factory, repo_key, capacity_opts) do
        {:ok, capacity} -> capacity
        {:error, reason} -> %{repo_key: repo_key, result: "UNAVAILABLE", error: inspect(reason)}
      end
    end)
  end

  defp issue_url(nil), do: nil

  defp issue_url(snapshot_json) when is_binary(snapshot_json) do
    case Jason.decode(snapshot_json) do
      {:ok, snapshot} when is_map(snapshot) ->
        safe_external_url(snapshot["url"] || snapshot["self"])

      _other ->
        nil
    end
  end

  defp safe_external_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.trim(url)

      _other ->
        nil
    end
  end

  defp safe_external_url(_url), do: nil

  defp unavailable(reason) do
    %{
      enabled: true,
      available: false,
      error: %{code: "factory_snapshot_unavailable", message: reason},
      control: nil,
      counts: empty_counts(),
      overview: empty_overview(),
      intake: %{available: false, observed_at: nil, count: 0, issues: [], error: nil},
      capacity: [],
      current_runs: [],
      runs: [],
      tasks: [],
      recent_events: []
    }
  end

  defp empty_counts do
    %{
      total_runs: 0,
      in_progress: 0,
      review_ready: 0,
      blocked: 0,
      hibernated: 0,
      visible_tasks: 0,
      by_state: %{}
    }
  end

  defp empty_overview do
    %{active: 0, queued: 0, review_ready: 0, needs_attention: 0, delivery_blocked: 0, communication_attention: 0, by_issue: %{}}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp value(_map, _key, default), do: default
end
