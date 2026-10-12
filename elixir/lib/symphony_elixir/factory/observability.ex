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
    RunLedger,
    Store,
    Supervisor,
    TaskLedger,
    TicketChatOutbox,
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
      store = Keyword.get(opts, :store, Supervisor.store_name())
      control_server = Keyword.get(opts, :control_server, Supervisor.control_name())
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
    run_limit = Keyword.get(opts, :run_limit, 50)
    current_run_limit = Keyword.get(opts, :current_run_limit, max(run_limit, 50))
    event_limit = Keyword.get(opts, :event_limit, 20)
    task_limit = Keyword.get(opts, :task_limit, 100)

    all_runs = RunLedger.list_recent(store, run_limit)
    current_runs = RunLedger.list_current(store, current_run_limit)
    runs = Enum.reject(all_runs, &hidden_from_dashboard?/1)
    current_runs = Enum.reject(current_runs, &hidden_from_dashboard?/1)
    tasks = TaskLedger.list_recent(store, task_limit)
    handoffs = attention_handoffs(store)
    tasks_by_run = Enum.group_by(tasks, & &1["run_id"])
    issue_by_run = Map.new(all_runs ++ current_runs, &{&1["run_id"], &1["issue_key"]})

    combined_runs = Enum.uniq_by(runs ++ current_runs, & &1["run_id"])

    enriched_runs =
      project_runs(combined_runs, tasks_by_run, issue_by_run, handoffs)
      |> enrich_ticket_context(store, opts)

    enriched_by_id = Map.new(enriched_runs, &{&1.run_id, &1})
    projected_runs = Enum.map(runs, &Map.fetch!(enriched_by_id, &1["run_id"]))
    projected_current_runs = Enum.map(current_runs, &Map.fetch!(enriched_by_id, &1["run_id"]))

    projected_tasks = Enum.map(tasks, &project_task(&1, issue_by_run, handoffs))
    intake = project_intake(IntakeLedger.get(store, value(factory, :scope, "default")), factory, current_runs)
    control = project_control(ControlServer.status(control_server))
    intake = Map.put(intake, :stale, control.status == "PAUSED")
    stalled_run_ids = stalled_native_run_ids(store, current_runs, control)

    %{
      enabled: true,
      available: true,
      control: control,
      broker: project_broker(store, factory),
      workspace_maintenance: NativeWorkspaceMaintenance.snapshot(store),
      counts: counts(current_runs, tasks, handoffs),
      overview: overview(projected_current_runs, projected_tasks, intake, stalled_run_ids),
      intake: intake,
      capacity: capacities(store, factory, opts),
      current_runs: projected_current_runs,
      runs: projected_runs,
      tasks: projected_tasks,
      recent_events: Enum.map(RunLedger.recent_events(store, event_limit), &project_event/1)
    }
  end

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
      runtime_identity: control["runtime_identity"]
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
            COUNT(CASE WHEN status = 'RECONCILE_REQUIRED' THEN 1 END) AS needs_reconciliation,
            MAX(CASE WHEN status = 'SUCCEEDED' THEN updated_at END) AS last_completed_at
          FROM desktop_requests
          """
        )

      %{
        pending: summary["pending"],
        claimed_unverified: summary["claimed_unverified"],
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
        project_intake_issue(snapshot, value(factory, :repositories, %{}), run_by_issue)
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

  defp project_intake_issue(snapshot, repositories, run_by_issue) do
    issue_key = value(snapshot, :key)
    route = project_route(Queue.route(snapshot, repositories))
    run = run_by_issue[issue_key]

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
      local_state: if(run, do: run["state"], else: "QUEUED")
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
      implementation_iteration: run["implementation_iteration"] || 0,
      code_repair_round: run["code_repair_round"] || 0,
      validation_repair_round: run["validation_repair_round"] || 0,
      last_error: run["last_error"],
      updated_at: run["updated_at"]
    }
  end

  defp hidden_from_dashboard?(run), do: hidden_status?(run_status(run))

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

  defp counts(runs, tasks, handoffs) do
    current_runs = Enum.uniq_by(runs, & &1["issue_key"])
    attention_run_ids = handoffs |> Map.values() |> Enum.map(& &1.run_id)

    %{
      total_runs: length(current_runs),
      in_progress: Enum.count(current_runs, &(&1["state"] not in @terminal_states and &1["run_id"] not in attention_run_ids)),
      review_ready: Enum.count(current_runs, &(&1["state"] in @review_states)),
      blocked: Enum.count(current_runs, &(blocked?(&1) or &1["run_id"] in attention_run_ids)),
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
      %{active: 0, queued: 0, review_ready: 0, needs_attention: 0, by_issue: %{}},
      fn issue_key, acc ->
        run = run_by_issue[issue_key]
        run_tasks = if run, do: Map.get(tasks_by_run, run.run_id, []), else: []
        state = overview_state(issue_by_key[issue_key], run, run_tasks, stalled_run_ids)

        acc
        |> Map.update!(overview_count_key(state), &(&1 + 1))
        |> put_in([:by_issue, issue_key], state)
      end
    )
  end

  defp overview_state(issue, run, tasks, stalled_run_ids) do
    cond do
      projected_run_blocked?(run) -> "NEEDS_ATTENTION"
      run && run.handoff_attention -> "NEEDS_ATTENTION"
      run && run.state == "AWAITING_CONTRACT_INPUT" -> "NEEDS_ATTENTION"
      run && run.run_id in stalled_run_ids -> "NEEDS_ATTENTION"
      true -> overview_unblocked_state(issue, run, tasks)
    end
  end

  defp overview_unblocked_state(issue, run, tasks) do
    cond do
      review_run?(run) -> "REVIEW_READY"
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

  defp review_run?(%{state: state}), do: state in @overview_review_states
  defp review_run?(_run), do: false

  defp active_run?(%{state: state}), do: state not in @terminal_states
  defp active_run?(_run), do: false

  defp terminal_current_run?(%{state: state}), do: state in @overview_hidden_states
  defp terminal_current_run?(_run), do: false

  defp projected_run_blocked?(%{} = run) do
    state = run.state || ""
    state == "FAILED" or String.contains?(state, "BLOCK") or present?(run.last_error)
  end

  defp projected_run_blocked?(_run), do: false

  defp active_tasks?(tasks), do: Enum.any?(tasks, &(&1.status in @active_task_statuses))

  defp attention_issue?(nil), do: false

  defp attention_issue?(issue) do
    issue.classification == "BLOCKED" or issue.routing_status != "ROUTED"
  end

  defp blocked?(run) do
    state = run["state"] || ""
    state == "FAILED" or String.contains?(state, "BLOCK") or present?(run["last_error"])
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
    %{active: 0, queued: 0, review_ready: 0, needs_attention: 0, by_issue: %{}}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp value(_map, _key, default), do: default
end
