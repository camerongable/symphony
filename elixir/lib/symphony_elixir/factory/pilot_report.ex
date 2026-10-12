defmodule SymphonyElixir.Factory.PilotReport do
  @moduledoc "Read-only pilot evidence from ledger timestamps and receipts, not inferred agent usage."

  alias SymphonyElixir.Factory.Store

  @terminal_states ~w(READY_FOR_REVIEW DELIVERED CANCELLED FAILED)
  @settled_requests ~w(SUCCEEDED FAILED)
  @request_attention ~w(PENDING CREATE_UNCERTAIN FOLLOWUP_UNCERTAIN THREAD_RECORDED RECONCILE_REQUIRED)
  @active_task_statuses ~w(STARTING RUNNING WAITING_FOR_BROKER WAITING_FOR_WRITER RETRY_PENDING STALE)

  @spec snapshot(Store.connection(), keyword()) :: map()
  def snapshot(store, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    {where, params} = filter(opts)
    runs = rows(store, "SELECT * FROM runs #{where} ORDER BY created_at DESC, run_id DESC LIMIT ?", params ++ [Keyword.get(opts, :limit, 20)])

    %{
      observed_at: DateTime.to_iso8601(now),
      source: "local SQLite ledger",
      duration_semantics:
        "Run intervals are wall-clock gaps between recorded state snapshots and may include unrecorded transitions. Task lifecycle elapsed time runs from creation to its last recorded update, or report observation while active; neither proves active model time. Queue and in-flight waits may overlap across tasks.",
      unavailable: %{
        tokens: "Not stored per run or turn",
        costs: "Not stored per run or turn",
        human_interventions: "Not stored; recovery events are not intervention totals",
        disk_growth_bytes: "Not stored"
      },
      runs: Enum.map(runs, &project_run(store, &1, now))
    }
  end

  defp filter(opts) do
    cond do
      is_binary(opts[:run]) -> {"WHERE run_id = ?", [opts[:run]]}
      is_binary(opts[:issue]) -> {"WHERE issue_key = ?", [opts[:issue]]}
      true -> {"", []}
    end
  end

  defp project_run(store, run, now) do
    tasks = rows(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY created_at, task_key", [run["run_id"]])

    requests =
      rows(
        store,
        """
        SELECT request.* FROM desktop_requests request
        JOIN factory_tasks task ON request.target_kind = 'TASK' AND task.task_key = request.target_key
        WHERE task.run_id = ? ORDER BY request.created_at, request.request_key
        """,
        [run["run_id"]]
      )

    events =
      rows(
        store,
        """
        SELECT * FROM events WHERE run_id = ? OR json_extract(payload_json, '$.request_key') IN (
          SELECT request.request_key FROM desktop_requests request
          JOIN factory_tasks task ON request.target_kind = 'TASK' AND task.task_key = request.target_key
          WHERE task.run_id = ?
        ) ORDER BY occurred_at, id
        """,
        [run["run_id"], run["run_id"]]
      )

    recovery_events = Enum.filter(events, &Regex.match?(~r/RECOVER|RESUM|RETRY/, &1["event_type"]))
    latest = requests |> Enum.filter(&(&1["status"] in @request_attention)) |> Enum.max_by(&{&1["updated_at"], &1["request_key"]}, fn -> nil end)
    {stages, stage_history} = stage_intervals(run, events, now)

    %{
      identity: Map.take(run, ~w(run_id issue_key kind state created_at updated_at candidate_sha mr_url mr_iid branch workspace_state hibernated_at failure_code last_error)),
      counts: %{
        tasks: length(tasks),
        create_requests: Enum.count(requests, &(&1["action"] == "CREATE")),
        followup_requests: Enum.count(requests, &(&1["action"] == "FOLLOWUP")),
        recovery_events: length(recovery_events)
      },
      stages: stages,
      stage_history: stage_history,
      tasks: Enum.map(tasks, &project_task(&1, now)),
      checkout_evidence: %{
        recorded_intents: Store.one!(store, "SELECT COUNT(*) AS total FROM ticket_checkout_intents WHERE run_id = ?", [run["run_id"]])["total"],
        physical_checkouts: %{status: "UNKNOWN", count: nil, reason: "An intent receipt does not prove a physical checkout exists."}
      },
      model_routes:
        rows(
          store,
          "SELECT occurred_at, task_id, usage_context, requested_role, resolved_role, provider, model, reasoning_effort, routing_reason FROM model_routes WHERE run_id = ? ORDER BY occurred_at, id",
          [run["run_id"]]
        ),
      requests: Enum.map(requests, &project_request(&1, now)),
      latest_unresolved_request: if(latest, do: project_request(latest, now)),
      recovery_receipts: Enum.map(recovery_events, &receipt/1),
      cleanup_receipts: events |> Enum.filter(&Regex.match?(~r/CLEANUP|HIBERN|WORKTREE_REMOVED/, &1["event_type"])) |> Enum.map(&receipt/1)
    }
  end

  defp project_task(task, now) do
    active? = task["status"] in @active_task_statuses
    ended_at = if active?, do: DateTime.to_iso8601(now), else: task["updated_at"]

    task
    |> Map.take(~w(task_key stage role status model_provider model reasoning_effort failure_code created_at updated_at))
    |> Map.put("lifecycle_elapsed_seconds", seconds(task["created_at"], ended_at))
    |> Map.put("lifecycle_elapsed_through", if(active?, do: "report_observed_at", else: "last_recorded_update"))
    |> Map.put("lifecycle_semantics", "Recorded task wall-clock lifecycle, not active-model time.")
  end

  defp state_changes(events) do
    events
    |> Enum.filter(&(&1["event_type"] in ~w(RUN_REGISTERED RUN_UPDATED)))
    |> Enum.flat_map(fn event ->
      case Jason.decode(event["payload_json"]) do
        {:ok, %{"state" => state}} -> [{state, event["occurred_at"]}]
        _other -> []
      end
    end)
    |> Enum.reduce([], fn {state, _time} = change, acc ->
      if acc != [] and elem(hd(acc), 0) == state, do: acc, else: [change | acc]
    end)
    |> Enum.reverse()
  end

  defp stage_intervals(run, events, now) do
    changes = state_changes(events)

    latest_recorded_state =
      case List.last(changes) do
        {state, _time} -> state
        nil -> nil
      end

    matches_current? = latest_recorded_state == run["state"]

    boundary = stage_boundary(run, matches_current?, now)

    intervals =
      changes
      |> Enum.with_index()
      |> Enum.map(fn {{state, started_at}, index} ->
        ended_at =
          case Enum.at(changes, index + 1) do
            nil -> boundary
            {_state, time} -> time
          end

        %{
          state: state,
          started_at: started_at,
          ended_at: ended_at,
          elapsed_seconds: seconds(started_at, ended_at),
          waiting_state: Regex.match?(~r/WAIT|BLOCK|PAUS/, state),
          current: matches_current? and index == length(changes) - 1
        }
      end)

    history = %{
      status: if(matches_current?, do: "NO_DETECTED_GAP", else: "INCOMPLETE"),
      latest_recorded_state: latest_recorded_state,
      current_state: run["state"],
      unavailable: if(matches_current?, do: nil, else: "Current state transition was not recorded; last snapshot end and current-state duration are unavailable.")
    }

    {intervals, history}
  end

  defp stage_boundary(_run, false, _now), do: nil

  defp stage_boundary(run, true, now) do
    if run["state"] in @terminal_states, do: run["updated_at"], else: DateTime.to_iso8601(now)
  end

  defp project_request(request, now) do
    observed = DateTime.to_iso8601(now)
    finished = if request["status"] in @settled_requests, do: request["updated_at"], else: observed

    request
    |> Map.take(~w(request_key target_key action status failure_code rejected_tool_call_id created_at claimed_at updated_at))
    |> Map.put("queue_elapsed_seconds", seconds(request["created_at"], request["claimed_at"] || finished))
    |> Map.put("in_flight_elapsed_seconds", seconds(request["claimed_at"], finished))
  end

  defp seconds(from, to) when is_binary(from) and is_binary(to) do
    with {:ok, start, _} <- DateTime.from_iso8601(from), {:ok, finish, _} <- DateTime.from_iso8601(to) do
      max(DateTime.diff(finish, start), 0)
    else
      _other -> nil
    end
  end

  defp seconds(_from, _to), do: nil

  defp receipt(event) do
    %{event_type: event["event_type"], occurred_at: event["occurred_at"], payload: Jason.decode!(event["payload_json"])}
  end

  defp rows(store, sql, params) do
    result = Store.query!(store, sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end
end
