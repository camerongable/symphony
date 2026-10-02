defmodule SymphonyElixir.FactoryObservabilityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{
    Control,
    ControlServer,
    DesktopRequest,
    IntakeLedger,
    Observability,
    RunLedger,
    Store,
    TaskLedger
  }

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-observability-#{token}.sqlite")
    store = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)

    factory = %{
      enabled: true,
      scope: "factory-test-#{token}",
      dispatcher_id: "dispatcher-#{token}",
      lease_seconds: 240,
      maximum_specifiers: 2,
      maximum_writers: 2,
      maximum_validators: 2,
      writer_disk_gb: 20,
      repositories: %{
        "symphony" => %{
          "path" => "/Users/cgable/Repos/symphony",
          "base_branch" => "main",
          "gitlab_project" => "example/symphony",
          "route_labels" => ["repo-symphony"]
        }
      }
    }

    control_server_name = {:global, {:factory_observability_control, token}}

    control_server =
      start_supervised!({ControlServer, store: store, factory: factory, name: control_server_name})

    %{store: store, control_server: control_server, factory: factory}
  end

  test "projects durable controller, run, task, capacity, and event state", context do
    config = %{
      scope: context.factory.scope,
      dispatcher_id: context.factory.dispatcher_id,
      lease_seconds: context.factory.lease_seconds
    }

    assert {:ok, _result} = Control.activate(context.store, config, context.factory.dispatcher_id)

    Control.record_controller_task(
      context.store,
      config,
      "thread-controller",
      "turn-controller",
      %{
        model: "gpt-5.6-terra",
        reasoning_effort: "medium"
      }
    )

    Control.record_controller_writer_conflict(
      context.store,
      config,
      "thread-controller",
      now: ~U[2026-09-22 20:00:00Z]
    )

    intake = [
      %{
        "key" => "PPL-124",
        "summary" => "Specify dashboard queue",
        "status" => %{"name" => "To Do"},
        "labels" => [%{"name" => "repo-symphony"}, "spec-needed"],
        "project_key" => "PPL",
        "url" => "https://jira.example/PPL-124",
        "updated" => "2026-09-22T19:59:00Z"
      }
    ]

    assert {:ok, _intake} =
             IntakeLedger.replace(context.store, context.factory.scope, intake, now: ~U[2026-09-22 20:01:00Z])

    assert {:ok, _result} =
             RunLedger.register(context.store, %{
               run_id: "run-1",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "VERIFYING",
               repo_key: "symphony",
               branch: "cgable/PPL-123-dashboard",
               workspace_state: "MATERIALIZED",
               candidate_sha: String.duplicate("a", 40),
               snapshot_json: Jason.encode!(%{"url" => "https://jira.example/PPL-123"}),
               model: "gpt-5.6-sol",
               reasoning_effort: "high"
             })

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: "run-1:change-verifier:1",
               run_id: "run-1",
               stage: "VERIFYING",
               role: "change-verifier",
               status: "RUNNING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-5.6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: String.duplicate("b", 64)
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, "run-1:change-verifier:1", %{
               thread_id: "thread-verifier",
               turn_id: "turn-verifier"
             })

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.enabled
    assert snapshot.available
    assert snapshot.control.status == "ACTIVE"
    assert snapshot.control.controller_thread_id == "thread-controller"
    assert snapshot.control.controller_writer_conflict_count == 1

    assert %{
             process_started_at: started_at,
             factory_beam_fingerprint: fingerprint,
             factory_beam_module_count: module_count
           } = snapshot.control.runtime_identity

    assert {:ok, _, _} = DateTime.from_iso8601(started_at)
    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert module_count > 0
    assert snapshot.control.controller_writer_conflict_since == "2026-09-22T20:00:00Z"
    assert snapshot.counts.in_progress == 1
    assert snapshot.counts.visible_tasks == 1

    assert snapshot.intake.available
    assert snapshot.intake.observed_at == "2026-09-22T20:01:00Z"
    assert snapshot.intake.count == 1

    assert [queued] = snapshot.intake.issues
    assert queued.issue_key == "PPL-124"
    assert queued.status == "To Do"
    assert queued.classification == "SPECIFICATION"
    assert queued.routing_status == "ROUTED"
    assert queued.repo_key == "symphony"
    assert queued.local_state == "QUEUED"

    assert [%{repo_key: "symphony", free_gb: 45.0, available_writer_slots: 1}] = snapshot.capacity

    assert [run] = snapshot.runs
    assert run.issue_key == "PPL-123"
    assert run.issue_url == "https://jira.example/PPL-123"
    assert run.branch == "cgable/PPL-123-dashboard"
    assert [%{thread_id: "thread-verifier", issue_key: "PPL-123"}] = run.tasks

    assert [%{thread_id: "thread-verifier", role: "change-verifier"}] = snapshot.tasks
    assert Enum.any?(snapshot.recent_events, &(&1.event_type == "RUN_REGISTERED"))
  end

  test "returns nil when the factory is disabled" do
    assert Observability.snapshot(settings: %{factory: %{enabled: false}}) == nil
    assert Observability.snapshot(settings: :not_a_settings_map) == nil
  end

  test "broker projection distinguishes queued, claimed, and reconciliation requests without claiming liveness", context do
    factory = Map.put(context.factory, :task_transport, "desktop_broker")

    snapshot =
      Observability.snapshot(
        settings: %{factory: factory},
        store: context.store,
        control_server: context.control_server
      )

    assert snapshot.broker == %{
             pending: 0,
             claimed_unverified: 0,
             needs_reconciliation: 0,
             last_completed_at: nil
           }

    request = %{
      request_key: "broker-projection-1",
      target_kind: "CONTROLLER",
      target_key: context.factory.scope,
      action: "CREATE",
      codex_project_id: "project-factory",
      model: "gpt-6-sol",
      reasoning_effort: "medium",
      title: "Factory controller",
      prompt: "Process one request",
      schema: %{"type" => "object"},
      cwd: "/tmp/factory-controller"
    }

    assert {:ok, _request} = DesktopRequest.enqueue(context.store, request)

    assert %{pending: 1, claimed_unverified: 0, needs_reconciliation: 0} =
             Observability.snapshot(
               settings: %{factory: factory},
               store: context.store,
               control_server: context.control_server
             ).broker

    assert {:ok, _request} = DesktopRequest.claim(context.store, request.request_key)

    assert %{pending: 0, claimed_unverified: 1, needs_reconciliation: 0} =
             Observability.snapshot(
               settings: %{factory: factory},
               store: context.store,
               control_server: context.control_server
             ).broker

    assert {:ok, _request} = DesktopRequest.fail(context.store, request.request_key, "BROKER_INTERRUPTED")

    assert %{pending: 0, claimed_unverified: 0, needs_reconciliation: 1} =
             Observability.snapshot(
               settings: %{factory: factory},
               store: context.store,
               control_server: context.control_server
             ).broker

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', updated_at = ? WHERE request_key = ?",
      ["2026-09-24T12:00:00Z", request.request_key]
    )

    assert %{pending: 0, claimed_unverified: 0, needs_reconciliation: 0, last_completed_at: "2026-09-24T12:00:00Z"} =
             Observability.snapshot(
               settings: %{factory: factory},
               store: context.store,
               control_server: context.control_server
             ).broker
  end

  test "summary counts use only the latest run for each ticket", context do
    assert {:ok, _run} =
             RunLedger.register(context.store, %{
               run_id: "run-old",
               issue_key: "PPL-400",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "symphony",
               last_error: "old attempt failed"
             })

    Process.sleep(1)

    assert {:ok, _run} =
             RunLedger.register(context.store, %{
               run_id: "run-current",
               issue_key: "PPL-400",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               repo_key: "symphony"
             })

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.counts.total_runs == 1
    assert snapshot.counts.in_progress == 1
    assert snapshot.counts.blocked == 0
    assert snapshot.counts.by_state == %{"SPEC_DRAFTING" => 1}
  end

  test "housekeeping on an old failed specification does not replace the current delivery", context do
    issue_key = "PPL-414"

    assert {:ok, _old} =
             RunLedger.register(
               context.store,
               %{
                 run_id: "run-old-specification",
                 issue_key: issue_key,
                 kind: "SPECIFICATION",
                 state: "FAILED",
                 last_error: "old specification failed"
               },
               now: ~U[2026-09-29 10:00:00Z]
             )

    assert {:ok, _current} =
             RunLedger.register(
               context.store,
               %{
                 run_id: "run-current-delivery",
                 issue_key: issue_key,
                 kind: "DELIVERY",
                 state: "READY_FOR_REVIEW"
               },
               now: ~U[2026-09-29 11:00:00Z]
             )

    assert {:ok, _old} =
             RunLedger.update(
               context.store,
               "run-old-specification",
               %{workspace_state: "CLEANED"},
               now: ~U[2026-09-29 12:00:00Z]
             )

    assert {:ok, _intake} =
             IntakeLedger.replace(context.store, context.factory.scope, [
               jira_snapshot(issue_key, ["repo-symphony", "ai-review"])
             ])

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        run_limit: 1,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert [%{run_id: "run-current-delivery"}] = snapshot.runs
    assert snapshot.counts.by_state == %{"READY_FOR_REVIEW" => 1}
    assert snapshot.counts.blocked == 0
    assert snapshot.overview.by_issue == %{issue_key => "REVIEW_READY"}
    assert [%{local_state: "READY_FOR_REVIEW"}] = snapshot.intake.issues
  end

  test "an active child specification is current until it completes, then its parent delivery is current", context do
    issue_key = "PPL-415"

    assert {:ok, _old} =
             RunLedger.register(
               context.store,
               %{run_id: "old-spec", issue_key: issue_key, kind: "SPECIFICATION", state: "FAILED"},
               now: ~U[2026-09-29 09:00:00Z]
             )

    assert {:ok, _parent} =
             RunLedger.register(
               context.store,
               %{run_id: "delivery-parent", issue_key: issue_key, kind: "DELIVERY", state: "FAILED"},
               now: ~U[2026-09-29 10:00:00Z]
             )

    assert {:ok, _child} =
             RunLedger.register(
               context.store,
               %{
                 run_id: "contract-child",
                 issue_key: issue_key,
                 kind: "SPECIFICATION",
                 state: "CONTRACT_DISCUSSING",
                 parent_run_id: "delivery-parent"
               },
               now: ~U[2026-09-29 11:00:00Z]
             )

    assert {:ok, _intake} =
             IntakeLedger.replace(context.store, context.factory.scope, [
               jira_snapshot(issue_key, ["repo-symphony", "ai-running"])
             ])

    active =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        run_limit: 1,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert [%{run_id: "contract-child"}] = active.current_runs
    assert active.overview.by_issue == %{issue_key => "ACTIVE"}

    assert {:ok, _child} =
             RunLedger.update(context.store, "contract-child", %{state: "DELIVERED"}, now: ~U[2026-09-29 12:00:00Z])

    assert {:ok, _parent} =
             RunLedger.update(
               context.store,
               "delivery-parent",
               %{state: "READY_FOR_REVIEW"},
               now: ~U[2026-09-29 12:01:00Z]
             )

    assert {:ok, _old} =
             RunLedger.update(context.store, "old-spec", %{workspace_state: "CLEANED"}, now: ~U[2026-09-29 13:00:00Z])

    assert {:ok, _intake} =
             IntakeLedger.replace(context.store, context.factory.scope, [
               jira_snapshot(issue_key, ["repo-symphony", "ai-review"])
             ])

    review =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        run_limit: 1,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert [%{run_id: "delivery-parent", state: "READY_FOR_REVIEW"}] = review.current_runs
    assert review.counts.review_ready == 1
    assert review.counts.blocked == 0
    assert review.overview.by_issue == %{issue_key => "REVIEW_READY"}
    assert [%{local_state: "READY_FOR_REVIEW"}] = review.intake.issues
  end

  test "a failed child remains visible until its parent reaches review", context do
    issue_key = "PPL-416"

    assert {:ok, _parent} =
             RunLedger.register(
               context.store,
               %{run_id: "validation-parent", issue_key: issue_key, kind: "DELIVERY", state: "AWAITING_VALIDATION"},
               now: ~U[2026-09-29 10:00:00Z]
             )

    assert {:ok, _child} =
             RunLedger.register(
               context.store,
               %{
                 run_id: "validation-child",
                 issue_key: issue_key,
                 kind: "VALIDATION",
                 state: "FAILED",
                 parent_run_id: "validation-parent",
                 last_error: "validation failed"
               },
               now: ~U[2026-09-29 11:00:00Z]
             )

    blocked =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert [%{run_id: "validation-child"}] = blocked.current_runs
    assert blocked.counts.blocked == 1
    assert blocked.overview.by_issue == %{issue_key => "NEEDS_ATTENTION"}

    assert {:ok, _parent} =
             RunLedger.update(context.store, "validation-parent", %{state: "READY_FOR_REVIEW"})

    recovered =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert [%{run_id: "validation-parent"}] = recovered.current_runs
    assert recovered.overview.by_issue == %{issue_key => "REVIEW_READY"}
  end

  test "overview partitions each current ticket into one lifecycle bucket", context do
    intake = [
      jira_snapshot("PPL-401", ["repo-symphony", "spec-needed"]),
      jira_snapshot("PPL-402", ["repo-symphony", "spec-needed"]),
      jira_snapshot("PPL-403", ["repo-symphony", "ai-ready"]),
      jira_snapshot("PPL-404", ["spec-needed"]),
      jira_snapshot("PPL-405", ["repo-symphony", "spec-needed"])
    ]

    assert {:ok, _intake} = IntakeLedger.replace(context.store, context.factory.scope, intake)

    register_run(context.store, "run-active", "PPL-402", "SPEC_DRAFTING")
    register_run(context.store, "run-review", "PPL-403", "READY_FOR_REVIEW")
    register_run(context.store, "run-blocked", "PPL-405", "FAILED", "human decision required")

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: "run-active:specification-author:1",
               run_id: "run-active",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "RUNNING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-5.6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: String.duplicate("d", 64)
             })

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.overview == %{
             active: 1,
             queued: 1,
             review_ready: 1,
             needs_attention: 2,
             by_issue: %{
               "PPL-401" => "QUEUED",
               "PPL-402" => "ACTIVE",
               "PPL-403" => "REVIEW_READY",
               "PPL-404" => "NEEDS_ATTENTION",
               "PPL-405" => "NEEDS_ATTENTION"
             }
           }

    assert Enum.sum([
             snapshot.overview.active,
             snapshot.overview.queued,
             snapshot.overview.review_ready,
             snapshot.overview.needs_attention
           ]) == 5
  end

  test "latest run state wins over active task labels and terminal runs leave current overview", context do
    assert {:ok, _intake} =
             IntakeLedger.replace(context.store, context.factory.scope, [
               jira_snapshot("PPL-410", ["repo-symphony", "ai-running"]),
               jira_snapshot("PPL-411", ["repo-symphony", "ai-ready"]),
               jira_snapshot("PPL-412", ["repo-symphony", "ai-running"]),
               jira_snapshot("PPL-413", ["repo-symphony", "ai-running"])
             ])

    register_run(context.store, "run-failed-latest", "PPL-410", "FAILED", "latest run failed")
    register_run(context.store, "run-review", "PPL-411", "READY_FOR_REVIEW")
    register_run(context.store, "run-delivered", "PPL-412", "DELIVERED")
    register_run(context.store, "run-cancelled", "PPL-413", "CANCELLED")

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: "run-failed-latest:writer",
               run_id: "run-failed-latest",
               stage: "IMPLEMENTING",
               role: "writer",
               status: "RUNNING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: String.duplicate("f", 64)
             })

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.overview.by_issue == %{
             "PPL-410" => "NEEDS_ATTENTION",
             "PPL-411" => "REVIEW_READY"
           }

    assert snapshot.overview.needs_attention == 1
    assert snapshot.overview.review_ready == 1

    assert Enum.map(snapshot.runs, & &1.state) |> Enum.sort() ==
             ["CANCELLED", "DELIVERED", "FAILED", "READY_FOR_REVIEW"]
  end

  test "a specification remains active after its author completes while controller gates are pending", context do
    assert {:ok, _intake} =
             IntakeLedger.replace(context.store, context.factory.scope, [
               jira_snapshot("PPL-402", ["repo-symphony", "spec-needed"])
             ])

    register_run(context.store, "run-author-complete", "PPL-402", "SPEC_DRAFTING")

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: "run-author-complete:specification-author",
               run_id: "run-author-complete",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "COMPLETE",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: String.duplicate("e", 64)
             })

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.overview.active == 1
    assert snapshot.overview.queued == 0
    assert snapshot.overview.by_issue == %{"PPL-402" => "ACTIVE"}
  end

  test "paused bootstrap stays in needs attention before and after local recovery", context do
    assert ControlServer.status(context.control_server)["status"] == "PAUSED"
    register_run(context.store, "run-uncertain", "PPL-406", "SPEC_DRAFTING")

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: "run-uncertain:specification-author",
               run_id: "run-uncertain",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "STARTING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               codex_project_id: "project-symphony",
               prompt_sha256: String.duplicate("a", 64)
             })

    request_key = "run-uncertain:specification-author:create"

    assert {:ok, _request} =
             DesktopRequest.enqueue(context.store, %{
               request_key: request_key,
               target_kind: "TASK",
               target_key: "run-uncertain:specification-author",
               action: "CREATE",
               codex_project_id: "project-symphony",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               title: "PPL-406 · Specification Author",
               prompt: "Verify checkout",
               schema: %{"type" => "object", "properties" => %{}},
               cwd: "/tmp/symphony-worktree",
               metadata: %{"issue_key" => "PPL-406"}
             })

    assert {:ok, %{"status" => "CREATE_UNCERTAIN"}} = DesktopRequest.claim(context.store, request_key)

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.overview.active == 0
    assert snapshot.overview.needs_attention == 1
    assert snapshot.overview.by_issue == %{"PPL-406" => "NEEDS_ATTENTION"}

    assert {:ok, %{"status" => "THREAD_RECORDED"}} =
             DesktopRequest.record_thread(context.store, request_key, "thread-author", "project-symphony")

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(context.store, request_key, %{
               thread_id: "thread-author",
               turn_id: "turn-bootstrap",
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{"status" => "STARTING", "turn_id" => nil}} =
             TaskLedger.get(context.store, "run-uncertain:specification-author")

    recovered_snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert recovered_snapshot.overview.active == 0
    assert recovered_snapshot.overview.needs_attention == 1
    assert recovered_snapshot.overview.by_issue == %{"PPL-406" => "NEEDS_ATTENTION"}
  end

  test "rejected verifier creation needs attention while the controller is active and clears on same-request recovery", context do
    config = Map.take(context.factory, [:scope, :dispatcher_id, :lease_seconds])
    assert {:ok, _} = Control.activate(context.store, config, context.factory.dispatcher_id)
    register_run(context.store, "run-verifier", "PPL-9723", "VERIFYING")
    task_key = "run-verifier:change-verifier:3"
    request_key = "#{task_key}:create"

    assert {:ok, _} =
             TaskLedger.register(context.store, %{
               task_key: task_key,
               run_id: "run-verifier",
               codex_project_id: "project-symphony",
               stage: "VERIFYING",
               role: "change-verifier",
               status: "WAITING_FOR_BROKER",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _} =
             DesktopRequest.enqueue(context.store, %{
               request_key: request_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "CREATE",
               codex_project_id: "project-symphony",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               title: "PPL-9723 · Verifier",
               prompt: "Verify candidate",
               schema: %{"type" => "object"},
               cwd: "/tmp/symphony-verifier"
             })

    snapshot = fn ->
      Observability.snapshot(
        settings: %{factory: Map.put(context.factory, :task_transport, "desktop_broker")},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )
    end

    assert snapshot.().overview.active == 1
    assert snapshot.().overview.needs_attention == 0
    assert {:ok, _} = DesktopRequest.claim(context.store, request_key)
    assert snapshot.().overview.active == 1

    assert {:ok, _} =
             DesktopRequest.fail(context.store, request_key, "CREATE_THREAD_INVALID_ARGUMENTS",
               rejected_tool_call_id: "exec-a1b2",
               tool_error: "create_thread received invalid arguments"
             )

    failed = snapshot.()
    assert failed.control.status == "ACTIVE"
    assert failed.overview.by_issue == %{"PPL-9723" => "NEEDS_ATTENTION"}
    assert failed.overview.active == 0
    assert failed.overview.needs_attention == 1
    assert failed.counts.in_progress == 0
    assert failed.counts.blocked == 1
    assert failed.broker.needs_reconciliation == 1
    assert [run] = failed.current_runs
    assert run.handoff_attention.label == "Verifier creation failed"
    assert run.handoff_attention.reason =~ "Correct them and recover this same request"
    assert run.handoff_attention.request_key == request_key
    assert [task] = failed.tasks
    assert task.handoff_attention == run.handoff_attention
    assert task.thread_id == nil

    Store.query!(context.store, "UPDATE desktop_requests SET failure_code = 'BROKER_INTERRUPTED' WHERE request_key = ?", [request_key])
    ambiguous = snapshot.()
    assert ambiguous.overview.needs_attention == 1
    assert hd(ambiguous.current_runs).handoff_attention.label == "Verifier creation needs attention"
    assert hd(ambiguous.current_runs).handoff_attention.reason =~ "Reconcile this Desktop request before retrying"

    Store.query!(context.store, "UPDATE desktop_requests SET action = 'FOLLOWUP', failure_code = 'FOLLOWUP_TURN_REPLAYED' WHERE request_key = ?", [request_key])
    assert hd(snapshot.().current_runs).handoff_attention.label == "Worker handoff needs attention"
    Store.query!(context.store, "UPDATE desktop_requests SET action = 'CREATE', failure_code = 'CREATE_THREAD_INVALID_ARGUMENTS' WHERE request_key = ?", [request_key])

    assert {:ok, _} = TaskLedger.update(context.store, task_key, %{status: "CONSUMED"})
    assert snapshot.().overview.active == 1
    assert hd(snapshot.().current_runs).handoff_attention == nil
    assert {:ok, _} = TaskLedger.update(context.store, task_key, %{status: "WAITING_FOR_BROKER"})

    Store.query!(context.store, "UPDATE desktop_requests SET status = 'PENDING', failure_code = NULL WHERE request_key = ?", [request_key])
    recovered = snapshot.()
    assert recovered.overview.active == 1
    assert recovered.overview.needs_attention == 0
    assert recovered.counts.in_progress == 1
    assert recovered.counts.blocked == 0
    assert hd(recovered.current_runs).handoff_attention == nil
    assert hd(recovered.tasks).handoff_attention == nil
  end

  test "persistent writer recovery projects only its newest created handoff despite old failure updates", context do
    config = Map.take(context.factory, [:scope, :dispatcher_id, :lease_seconds])
    assert {:ok, _} = Control.activate(context.store, config, context.factory.dispatcher_id)
    register_run(context.store, "run-writer", "PPL-9723", "WRITING")
    task_key = "run-writer:feature-writer"

    assert {:ok, _} =
             TaskLedger.register(context.store, %{
               task_key: task_key,
               run_id: "run-writer",
               codex_project_id: "project-symphony",
               stage: "WRITING",
               role: "feature-writer",
               status: "STARTING",
               thread_id: "thread-persistent-writer",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: String.duplicate("a", 64)
             })

    request = %{
      request_key: "desktop:951c9f-old",
      target_kind: "TASK",
      target_key: task_key,
      action: "FOLLOWUP",
      existing_thread_id: "thread-persistent-writer",
      codex_project_id: "project-symphony",
      model: "gpt-6-sol",
      reasoning_effort: "high",
      title: "PPL-9723 · Writer",
      prompt: "Repair candidate",
      schema: %{"type" => "object"},
      cwd: "/tmp/symphony-writer"
    }

    assert {:ok, _} = DesktopRequest.enqueue(context.store, request)
    assert {:ok, _} = DesktopRequest.fail(context.store, request.request_key, "RECOVERED_INTERRUPTED_NATIVE_WRITER")
    newer_request = %{request | request_key: "desktop:4da673-new"}
    assert {:ok, _} = DesktopRequest.enqueue(context.store, newer_request)

    snapshot = fn ->
      Observability.snapshot(
        settings: %{factory: Map.put(context.factory, :task_transport, "desktop_broker")},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )
    end

    for {old_created_at, new_created_at} <- [
          {"2026-10-01T19:00:00Z", "2026-10-01T19:01:00Z"},
          {"2026-10-01T19:01:00Z", "2026-10-01T19:01:00Z"}
        ] do
      Store.query!(context.store, "UPDATE desktop_requests SET created_at = ?, updated_at = '2026-10-01T20:00:00Z' WHERE request_key = ?", [old_created_at, request.request_key])
      Store.query!(context.store, "UPDATE desktop_requests SET created_at = ?, updated_at = '2026-10-01T19:01:00Z' WHERE request_key = ?", [new_created_at, newer_request.request_key])

      for status <- ~w(PENDING FOLLOWUP_UNCERTAIN THREAD_RECORDED SUCCEEDED) do
        Store.query!(context.store, "UPDATE desktop_requests SET status = ?, failure_code = NULL WHERE request_key = ?", [status, newer_request.request_key])
        recovered = snapshot.()
        assert recovered.available
        assert recovered.overview.by_issue == %{"PPL-9723" => "ACTIVE"}
        assert recovered.overview.active == 1
        assert recovered.overview.needs_attention == 0
        assert recovered.counts.in_progress == 1
        assert recovered.counts.blocked == 0
        assert hd(recovered.current_runs).handoff_attention == nil
        assert hd(recovered.tasks).handoff_attention == nil
      end

      for status <- ~w(FAILED RECONCILE_REQUIRED) do
        Store.query!(context.store, "UPDATE desktop_requests SET status = ?, failure_code = 'LATEST_HANDOFF_FAILED' WHERE request_key = ?", [status, newer_request.request_key])
        failed = snapshot.()
        assert failed.overview.by_issue == %{"PPL-9723" => "NEEDS_ATTENTION"}
        assert failed.overview.active == 0
        assert failed.overview.needs_attention == 1
        assert failed.counts.in_progress == 0
        assert failed.counts.blocked == 1
        assert hd(failed.current_runs).handoff_attention.request_key == newer_request.request_key
        assert hd(failed.tasks).handoff_attention.reason =~ "LATEST_HANDOFF_FAILED"
      end
    end
  end

  test "informational maintenance neither creates nor suppresses writer handoff attention", context do
    config = Map.take(context.factory, [:scope, :dispatcher_id, :lease_seconds])
    assert {:ok, _} = Control.activate(context.store, config, context.factory.dispatcher_id)
    register_run(context.store, "maintenance-run", "PPL-9723", "WRITING")
    key = "maintenance-run:feature-writer"

    assert {:ok, _} =
             TaskLedger.register(context.store, %{
               task_key: key,
               run_id: "maintenance-run",
               codex_project_id: "project",
               stage: "WRITING",
               role: "feature-writer",
               status: "CONSUMED",
               thread_id: "writer",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "test",
               prompt_sha256: String.duplicate("a", 64)
             })

    attrs = %{
      request_key: "probe",
      target_kind: "TASK",
      target_key: key,
      action: "FOLLOWUP",
      existing_thread_id: "writer",
      codex_project_id: "project",
      model: "gpt-6-sol",
      reasoning_effort: "high",
      title: "Probe",
      prompt: "Read-only probe",
      cwd: "/tmp/writer"
    }

    assert {:ok, _} = DesktopRequest.enqueue(context.store, attrs)

    Store.query!(
      context.store,
      """
      UPDATE desktop_requests SET metadata_json = ?, status = 'FAILED', failure_code = 'PROBE_UNAVAILABLE'
      WHERE request_key = 'probe'
      """,
      [Jason.encode!(%{"maintenance_operation" => "NATIVE_WORKTREE_PROBE"})]
    )

    snapshot = fn -> Observability.snapshot(settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, capacity_opts: [free_bytes: 45_000_000_000]) end
    assert snapshot.().overview.needs_attention == 0
    assert {:ok, _} = TaskLedger.update(context.store, key, %{status: "RETRY_PENDING"})
    active = snapshot.()
    assert active.overview.needs_attention == 0
    assert hd(active.tasks).handoff_attention == nil

    assert {:ok, _} = DesktopRequest.enqueue(context.store, %{attrs | request_key: "source-failed"})
    assert {:ok, _} = DesktopRequest.fail(context.store, "source-failed", "SOURCE_FAILED")
    Store.query!(context.store, "UPDATE desktop_requests SET created_at = '2020-01-01T00:00:00Z' WHERE request_key = 'source-failed'")
    Store.query!(context.store, "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL WHERE request_key = 'probe'")
    attention = snapshot.()
    assert attention.overview.needs_attention == 1
    assert hd(attention.tasks).handoff_attention.request_key == "source-failed"
    assert hd(attention.current_runs).handoff_attention.request_key == "source-failed"
  end

  test "fails closed when the configured ledger is unavailable", context do
    assert %{available: false, error: %{code: "factory_snapshot_unavailable"}} =
             Observability.snapshot(
               settings: %{factory: context.factory},
               store: Module.concat(__MODULE__, :MissingStore),
               control_server: context.control_server
             )
  end

  test "keeps the dashboard usable when intake history is corrupt", context do
    Store.query!(
      context.store,
      "INSERT INTO intake_snapshots(scope, observed_at, snapshot_json) VALUES (?, ?, ?)",
      [context.factory.scope, "2026-09-22T20:00:00Z", "{invalid"]
    )

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert snapshot.available
    refute snapshot.intake.available
    assert snapshot.intake.error.code == "intake_snapshot_unavailable"
  end

  test "projects blocked classification and unresolved repository routing", context do
    snapshots = [
      %{
        "key" => "PPL-300",
        "summary" => "Ambiguous labels",
        "status" => "TO DO",
        "labels" => ["ai-ready", "spec-needed"],
        "url" => "javascript:alert(1)"
      },
      %{
        "key" => "PPL-301",
        "summary" => " ",
        "status" => nil,
        "labels" => "spec-needed",
        "updated" => 123
      },
      %{
        "key" => "PPL-302",
        "summary" => "Delivery",
        "status" => "READY",
        "labels" => ["ai-ready", "repo-symphony"]
      },
      %{
        "key" => "PPL-303",
        "summary" => "In progress",
        "status" => "READY",
        "labels" => ["ai-running", "repo-symphony"]
      },
      %{
        "key" => "PPL-304",
        "summary" => "Terminal",
        "status" => "READY",
        "labels" => ["ai-review", "repo-symphony"]
      }
    ]

    assert {:ok, _intake} = IntakeLedger.replace(context.store, context.factory.scope, snapshots)

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    [blocked, unmapped, delivery, reconcile, ignored] = snapshot.intake.issues
    assert blocked.classification == "BLOCKED"
    assert blocked.routing_status == "ROUTING_REQUIRED"
    assert is_nil(blocked.issue_url)
    assert unmapped.status == "Unknown"
    assert unmapped.routing_status == "ROUTING_REQUIRED"
    assert unmapped.summary == "Untitled Jira issue"
    assert unmapped.labels == []
    assert is_nil(unmapped.updated_at)
    assert delivery.classification == "DELIVERY"
    assert reconcile.classification == "RECONCILE"
    assert ignored.classification == "IGNORED"

    ambiguous_factory = %{
      context.factory
      | repositories:
          Map.put(
            context.factory.repositories,
            "duplicate",
            Map.put(context.factory.repositories["symphony"], "path", "/tmp/duplicate")
          )
    }

    ambiguous =
      Observability.snapshot(
        settings: %{factory: ambiguous_factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert Enum.find(ambiguous.intake.issues, &(&1.issue_key == "PPL-302")).routing_status == "AMBIGUOUS"

    invalid_factory = %{
      context.factory
      | repositories: %{"symphony" => Map.delete(context.factory.repositories["symphony"], "gitlab_project")}
    }

    invalid =
      Observability.snapshot(
        settings: %{factory: invalid_factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: 45_000_000_000]
      )

    assert Enum.find(invalid.intake.issues, &(&1.issue_key == "PPL-302")).routing_status == "INVALID_ROUTE"
  end

  test "fails closed when projection configuration raises", context do
    invalid_factory = %{context.factory | repositories: :not_a_repository_map}

    assert %{available: false, error: %{code: "factory_snapshot_unavailable"}} =
             Observability.snapshot(
               settings: %{factory: invalid_factory},
               store: context.store,
               control_server: context.control_server
             )
  end

  defp jira_snapshot(issue_key, labels) do
    %{
      "key" => issue_key,
      "summary" => "Ticket #{issue_key}",
      "status" => %{"name" => "To Do"},
      "labels" => labels,
      "project_key" => "PPL",
      "url" => "https://jira.example/#{issue_key}"
    }
  end

  defp register_run(store, run_id, issue_key, state, last_error \\ nil) do
    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: run_id,
               issue_key: issue_key,
               kind: "SPECIFICATION",
               state: state,
               repo_key: "symphony",
               last_error: last_error
             })
  end

  test "reports unavailable capacity and rejects unsafe external URLs", context do
    runs = [
      %{
        run_id: "run-no-snapshot",
        issue_key: "PPL-201",
        snapshot_json: nil,
        mr_url: "file:///tmp/unsafe"
      },
      %{
        run_id: "run-invalid-snapshot",
        issue_key: "PPL-202",
        snapshot_json: "{invalid",
        mr_url: nil
      },
      %{
        run_id: "run-unsafe-issue-url",
        issue_key: "PPL-203",
        snapshot_json: Jason.encode!(%{"url" => "javascript:alert(1)"}),
        mr_url: nil
      }
    ]

    Enum.each(runs, fn run ->
      assert {:ok, _result} =
               RunLedger.register(
                 context.store,
                 Map.merge(
                   %{
                     kind: "DELIVERY",
                     state: "READY_FOR_REVIEW",
                     repo_key: "symphony"
                   },
                   run
                 )
               )
    end)

    snapshot =
      Observability.snapshot(
        settings: %{factory: context.factory},
        store: context.store,
        control_server: context.control_server,
        capacity_opts: [free_bytes: -1]
      )

    assert [%{result: "UNAVAILABLE", error: error}] = snapshot.capacity
    assert error =~ "invalid_free_bytes"
    assert Enum.all?(snapshot.runs, &is_nil(&1.issue_url))
    assert Enum.all?(snapshot.runs, &is_nil(&1.mr_url))
  end
end
