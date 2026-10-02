defmodule SymphonyElixir.FactoryPilotReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{DesktopRequest, PilotReport, RunLedger, Store, TaskLedger}

  setup do
    store = start_supervised!({Store, database: ":memory:"})
    {:ok, _} = RunLedger.register(store, %{run_id: "run", issue_key: "PPL-123", kind: "DELIVERY", state: "IMPLEMENTING"}, now: ~U[2026-10-01 00:00:00Z])
    RunLedger.update(store, "run", %{state: "VERIFYING", candidate_sha: String.duplicate("a", 40), mr_url: "https://gitlab.example/mr/1"}, now: ~U[2026-10-01 00:01:00Z])
    Store.query!(store, "UPDATE events SET occurred_at = ? WHERE event_type = 'RUN_REGISTERED'", ["2026-10-01T00:00:00Z"])
    Store.query!(store, "UPDATE events SET occurred_at = ? WHERE event_type = 'RUN_UPDATED'", ["2026-10-01T00:01:00Z"])

    {:ok, _} =
      TaskLedger.register(store, %{
        task_key: "verify",
        run_id: "run",
        stage: "VERIFYING",
        role: "change-verifier",
        status: "WAITING_FOR_BROKER",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "role-policy",
        codex_project_id: "project-grail",
        prompt_sha256: String.duplicate("a", 64)
      })

    {:ok, _} =
      DesktopRequest.enqueue(store, %{
        request_key: "verify:create",
        target_key: "verify",
        target_kind: "TASK",
        action: "CREATE",
        codex_project_id: "project-grail",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        title: "Verify",
        prompt: "Verify candidate",
        cwd: "/tmp/repo"
      })

    Store.query!(store, "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED', failure_code = 'CREATE_THREAD_INVALID_ARGUMENTS', created_at = ?, claimed_at = ?, updated_at = ?", [
      "2026-10-01T00:01:00Z",
      "2026-10-01T00:01:10Z",
      "2026-10-01T00:01:20Z"
    ])

    event(store, "NATIVE_CREATE_PRECREATION_REJECTED", nil, %{request_key: "verify:create"})
    event(store, "NATIVE_CREATE_REQUEST_RESUMED", nil, %{request_key: "verify:create"})
    event(store, "WORKTREE_HIBERNATED", "run", %{candidate_sha: String.duplicate("a", 40), result: "HIBERNATED"})

    RunLedger.record_model_route(
      store,
      "run",
      "verification",
      %{
        requested_role: "change-verifier",
        resolved_role: "change-verifier",
        provider: "codex",
        model_class: "standard",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "role-policy"
      },
      task_id: "verify"
    )

    %{store: store}
  end

  test "reports elapsed stages, handoff waits, exact identity and receipts", %{store: store} do
    report = PilotReport.snapshot(store, issue: "PPL-123", now: ~U[2026-10-01 00:02:00Z])
    assert [run] = report.runs
    assert run.identity["candidate_sha"] == String.duplicate("a", 40)
    assert run.identity["mr_url"] == "https://gitlab.example/mr/1"
    assert run.counts == %{tasks: 1, create_requests: 1, followup_requests: 0, recovery_events: 1}
    assert [%{state: "IMPLEMENTING", elapsed_seconds: 60}, %{state: "VERIFYING", elapsed_seconds: 60}] = run.stages
    assert [task] = run.tasks
    assert task["role"] == "change-verifier"
    assert task["model"] == "gpt-6-sol"
    assert [%{"requested_role" => "change-verifier", "model" => "gpt-6-sol", "task_id" => "verify"}] = run.model_routes
    assert run.latest_unresolved_request["failure_code"] == "CREATE_THREAD_INVALID_ARGUMENTS"
    assert run.latest_unresolved_request["queue_elapsed_seconds"] == 10
    assert run.latest_unresolved_request["in_flight_elapsed_seconds"] == 50
    assert [%{event_type: "NATIVE_CREATE_REQUEST_RESUMED"}] = run.recovery_receipts
    assert [%{event_type: "WORKTREE_HIBERNATED", payload: %{"result" => "HIBERNATED"}}] = run.cleanup_receipts
    assert report.unavailable.tokens == "Not stored per run"
    assert report.unavailable.human_interventions =~ "not intervention totals"
  end

  test "filters exact run identity and leaves request and event history untouched", %{store: store} do
    before = Store.query!(store, "SELECT * FROM desktop_requests").rows
    events_before = Store.query!(store, "SELECT * FROM events").rows
    assert [_] = PilotReport.snapshot(store, run: "run").runs
    assert [] = PilotReport.snapshot(store, run: "missing").runs
    assert [] = PilotReport.snapshot(store, issue: "PPL-999").runs
    assert before == Store.query!(store, "SELECT * FROM desktop_requests").rows
    assert events_before == Store.query!(store, "SELECT * FROM events").rows
  end

  test "settled requests stop accumulating in-flight time and no stall is inferred", %{store: store} do
    Store.query!(store, "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL")
    assert [run] = PilotReport.snapshot(store, now: ~U[2026-10-01 01:00:00Z]).runs
    assert run.latest_unresolved_request == nil
    assert [request] = run.requests
    assert request["in_flight_elapsed_seconds"] == 10
  end

  test "a SQL state change without an event exposes incomplete history instead of fabricated residency", %{store: store} do
    event(store, "RUN_UPDATED", "run", %{state: "READY_FOR_REVIEW"})
    Store.query!(store, "UPDATE runs SET state = 'VERIFYING', updated_at = ? WHERE run_id = 'run'", ["2026-10-01T00:01:30Z"])

    assert [run] = PilotReport.snapshot(store, now: ~U[2026-10-01 03:00:00Z]).runs
    assert run.identity["state"] == "VERIFYING"
    assert run.stage_history.status == "INCOMPLETE"
    assert run.stage_history.latest_recorded_state == "READY_FOR_REVIEW"
    assert run.stage_history.unavailable =~ "not recorded"
    assert %{state: "READY_FOR_REVIEW", current: false, ended_at: nil, elapsed_seconds: nil} = List.last(run.stages)
    refute Enum.any?(run.stages, & &1.current)
  end

  test "missing state snapshots do not turn ordinary update receipts into inferred stages", %{store: store} do
    Store.query!(store, "DELETE FROM events WHERE event_type IN ('RUN_REGISTERED', 'RUN_UPDATED')")
    event(store, "RUN_UPDATED", "run", %{candidate_sha: String.duplicate("a", 40)})

    assert [run] = PilotReport.snapshot(store).runs
    assert run.identity["state"] == "VERIFYING"
    assert run.stages == []
    assert run.stage_history.status == "INCOMPLETE"
    assert run.stage_history.latest_recorded_state == nil
    assert run.stage_history.current_state == "VERIFYING"
    assert run.stage_history.unavailable =~ "not recorded"
  end

  defp event(store, type, run_id, payload) do
    Store.query!(store, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)", ["2026-10-01T00:01:20Z", type, run_id, Jason.encode!(payload)])
  end
end
