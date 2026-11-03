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
    TaskLedger,
    TicketContext
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

  test "workflow titles use their bound saved Jira snapshot even without intake membership", context do
    assert {:ok, _} = RunLedger.register(context.store, %{run_id: "saved-title", issue_key: "PPL-125", kind: "DELIVERY", state: "WRITING", repo_key: "symphony"})
    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server]
    title = "Freeze versioned submission configuration <and> separate \"outcomes\""

    for {snapshot, expected} <- [
          {Jason.encode!(%{"key" => "PPL-125", "summary" => title}), title},
          {Jason.encode!(%{"key" => "PPL-125", "summary" => "  Saved title  "}), "Saved title"},
          {Jason.encode!(%{"key" => "PPL-125", "summary" => " \n "}), nil},
          {Jason.encode!(%{"key" => "PPL-125", "summary" => nil}), nil},
          {Jason.encode!(%{"key" => "PPL-125", "summary" => ["not a title"]}), nil},
          {Jason.encode!(%{"key" => "PPL-126", "summary" => "Other ticket"}), nil},
          {Jason.encode!(%{"summary" => "Unbound title"}), nil},
          {"[]", nil},
          {"null", nil},
          {"invalid JSON", nil},
          {nil, nil}
        ] do
      Store.query!(context.store, "UPDATE runs SET snapshot_json=? WHERE run_id='saved-title'", [snapshot])
      projected = Observability.snapshot(options)
      assert projected.intake.issues == []
      assert [%{issue_key: "PPL-125", summary: ^expected, state: "WRITING"}] = projected.current_runs
      assert [%{issue_key: "PPL-125", summary: ^expected}] = projected.runs
    end
  end

  test "a current admitted run supersedes the saved intake rejection", context do
    snapshot = %{"key" => "PPL-125", "summary" => "Prior rejected intake", "status" => "To Do", "labels" => ["ai-ready", "repo-symphony"]}
    assert {:ok, saved} = IntakeLedger.replace(context.store, context.factory.scope, [snapshot])
    assert :ok = IntakeLedger.record_blocked(context.store, context.factory.scope, snapshot, saved.observed_at, :manual_validation_contract_missing)
    assert {:ok, _} = RunLedger.register(context.store, %{run_id: "admitted-current", issue_key: "PPL-125", kind: "DELIVERY", state: "WRITING", repo_key: "symphony"})
    projected = Observability.snapshot(settings: %{factory: context.factory}, store: context.store, control_server: context.control_server)
    assert [%{local_state: "WRITING", admission_error: nil}] = projected.intake.issues
    assert projected.overview.by_issue["PPL-125"] == "ACTIVE"
  end

  test "push deferrals explain prepared and uncertain work without leaking another operation's failure", context do
    intent = %{"kind" => "TICKET_PUSH", "version" => 1, "phase" => "PREPARED", "binding_sha256" => "binding", "owner_nonce" => "nonce", "reservation_key" => "ticket-push:binding"}

    assert {:ok, _} =
             RunLedger.register(context.store, %{run_id: "push-deferral", issue_key: "PPL-125", kind: "DELIVERY", state: "PUSHING", repo_key: "symphony", candidate_handoff: Jason.encode!(intent)})

    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server]
    project = fn -> hd(Observability.snapshot(options).current_runs) end
    before = project.()
    refute before.attention && before.attention.source == "PUSH"

    for key <- ["ticket-push:binding:old-nonce", "ticket-push:binding:nonce"] do
      payload = Jason.encode!(%{operation: "PUSH", operation_key: key, status: "DEFERRED", reason: "ticket_authorization_expired"})

      Store.query!(context.store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_RECOVERY_OUTCOME','push-deferral',?)", [
        DateTime.to_iso8601(DateTime.utc_now()),
        payload
      ])

      if key == "ticket-push:binding:old-nonce" do
        refute project.().attention && project.().attention.source == "PUSH"
      end
    end

    assert %{source: "PUSH", phase: "PREPARED", blocking: true, reason: prepared_reason} = project.().attention
    assert prepared_reason =~ "execution has not been authorized"
    assert prepared_reason =~ "ticket_authorization_expired"
    {:ok, _} = RunLedger.update(context.store, "push-deferral", %{candidate_handoff: Jason.encode!(Map.put(intent, "phase", "PUSH_UNCERTAIN"))})
    assert %{source: "PUSH", phase: "PUSH_UNCERTAIN", reason: uncertain_reason} = project.().attention
    assert uncertain_reason =~ "Push outcome is not confirmed"
    assert uncertain_reason =~ "ticket_authorization_expired"
  end

  test "native execution uses canonical latest evidence even outside the task display limit", context do
    {options, key} = execution_fixture(context)
    project = fn -> hd(Observability.snapshot(options).current_runs).worker_execution end
    assert project.().status == "WAITING"
    Store.query!(context.store, "UPDATE factory_tasks SET status='RUNNING', turn_id='old-task-turn' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='TURN_BOUND', thread_id='exact-thread', turn_id='exact-new-turn' WHERE task_key=?", [key])
    assert %{status: "TURN_BOUND", turn_id: "exact-new-turn", thread_id: "exact-thread", running_proven: false} = project.()
    Store.query!(context.store, "UPDATE worker_evidence SET owner_stopped_at='2026-10-20T20:59:30Z' WHERE task_key=?", [key])
    assert project.().status == "STOPPED"
    Store.query!(context.store, "UPDATE factory_tasks SET status='COMPLETE' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='RESULT_RECORDED' WHERE task_key=?", [key])
    assert %{status: "STOPPED", running_proven: false} = project.()
    Store.query!(context.store, "UPDATE factory_tasks SET status='RUNNING' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='RECONCILE_REQUIRED' WHERE task_key=?", [key])
    assert project.().status == "RECONCILE_REQUIRED"
    Store.query!(context.store, "UPDATE worker_evidence SET status='CONSUMED' WHERE task_key=?", [key])
    assert %{status: "WAITING", turn_id: nil} = project.()
    RunLedger.update(context.store, "execution", %{state: "CI_WAITING"})
    assert project.().status == "NOT_APPLICABLE"
  end

  test "malformed stale future or mismatched native bindings never imply current execution", context do
    {options, key} = execution_fixture(context)
    Store.query!(context.store, "UPDATE factory_tasks SET status='RUNNING' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='TURN_BOUND', thread_id='exact-thread', turn_id='exact-turn' WHERE task_key=?", [key])

    for timestamp <- [nil, "bad-time", "2026-10-21T00:00:00Z", "2026-10-19T00:00:00Z"] do
      Store.query!(context.store, "UPDATE worker_evidence SET created_at=? WHERE task_key=?", [timestamp || "", key])
      assert hd(Observability.snapshot(options).current_runs).worker_execution.status == "UNKNOWN"
    end

    Store.query!(context.store, "UPDATE worker_evidence SET created_at='2026-10-20T20:59:00Z', binding_sha256='wrong' WHERE task_key=?", [key])
    assert hd(Observability.snapshot(options).current_runs).worker_execution.status == "UNKNOWN"
  end

  test "scheduler observation distinguishes stale success and a newer pending tick", context do
    assert {:ok, _} = ControlServer.activate(context.factory.dispatcher_id, context.control_server)
    options = [settings: %{factory: context.factory, polling: %{interval_ms: 30_000}}, store: context.store, control_server: context.control_server]
    :ok = ControlServer.record_tick(:succeeded, context.control_server)
    assert Observability.snapshot(options).control.tick_observation.status == "FRESH"
    future = DateTime.add(DateTime.utc_now(), 300, :second)
    assert Observability.snapshot(Keyword.put(options, :now, future)).control.tick_observation.status == "STALE"
    :ok = ControlServer.record_tick(:started, context.control_server)
    assert Observability.snapshot(options).control.tick_observation.status == "IN_PROGRESS"
    assert Observability.snapshot(Keyword.put(options, :now, future)).control.tick_observation.status == "STALE"
    assert Observability.snapshot(Keyword.put(options, :now, ~U[2020-01-01 00:00:00Z])).control.tick_observation.status == "UNKNOWN"
  end

  test "implementation iteration exhaustion blocks dispatch independently of CI repair budget", context do
    {options, key} = execution_fixture(context)
    factory = Map.merge(context.factory, %{maximum_code_repair_rounds: 10, maximum_implementation_iterations: 20})
    options = Keyword.put(options, :settings, %{factory: factory})
    RunLedger.update(context.store, "execution", %{implementation_iteration: 20})
    projected = Observability.snapshot(options)
    assert projected.overview.by_issue["PPL-9881"] == "NEEDS_ATTENTION"
    assert hd(projected.current_runs).attention.phase == "implementation_iteration_limit"
    assert hd(projected.current_runs).attention.reason =~ "20/20"
    assert hd(projected.current_runs).implementation_iteration_limit == 20
    Store.query!(context.store, "UPDATE factory_tasks SET status='RUNNING' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='TURN_BOUND', thread_id='current',turn_id='current' WHERE task_key=?", [key])
    refute Enum.any?(hd(Observability.snapshot(options).current_runs).attention_signals, &(&1.source == "IMPLEMENTATION_BUDGET"))
    RunLedger.update(context.store, "execution", %{implementation_iteration: 19})
    refute Enum.any?(hd(Observability.snapshot(options).current_runs).attention_signals, &(&1.source == "IMPLEMENTATION_BUDGET"))
  end

  defp execution_fixture(context) do
    {:ok, _} =
      RunLedger.register(context.store, %{
        run_id: "execution",
        issue_key: "PPL-9881",
        kind: "DELIVERY",
        state: "REPAIRING",
        repo_key: "symphony",
        execution_mode: "TICKET_SUPERVISOR_V1",
        spec_revision: 1,
        contract_sha256: String.duplicate("a", 64),
        candidate_sha: String.duplicate("b", 40)
      })

    {:ok, run} = RunLedger.get(context.store, "execution")
    key = "execution:feature-writer"

    {:ok, task} =
      TaskLedger.register(context.store, %{
        task_key: key,
        run_id: "execution",
        stage: "REPAIRING",
        role: "feature-writer",
        status: "CONSUMED",
        model_provider: "codex",
        model_class: "deep",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "fixture",
        prompt_sha256: "prompt"
      })

    binding =
      Map.take(task, ~w(task_key run_id role stage prompt_sha256))
      |> Map.merge(Map.take(run, ~w(spec_revision contract_sha256)))
      |> Map.merge(%{"expected_sha" => run["candidate_sha"], "reservation_key" => "execution-access", "reservation_generation" => 1, "mode" => "SOURCE"})

    raw = Jason.encode!(binding)
    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    Store.query!(
      context.store,
      "INSERT INTO workspace_access(reservation_key,run_id,task_key,request_key,mode,generation,canonical_path,git_dir,common_dir,binding_json,acquired_at) VALUES('execution-access','execution',?,'execution-request','SOURCE',1,'/fixture/execution','/fixture/execution/.git','/fixture/common','{}','2026-10-20T20:59:00Z')",
      [key]
    )

    Store.query!(
      context.store,
      "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,owner_id,created_at) VALUES('execution-request',?,'execution','execution-access',?,?,'CONSUMED','fixture','2026-10-20T20:59:00Z')",
      [key, raw, sha]
    )

    {[settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, task_limit: 0, now: ~U[2026-10-20 21:00:00Z]], key}
  end

  test "review writing and admitted starts do not pretend to need another iteration", context do
    {options, key} = execution_fixture(context)
    options = Keyword.put(options, :settings, %{factory: Map.put(context.factory, :maximum_implementation_iterations, 20)})
    RunLedger.update(context.store, "execution", %{state: "REVIEW_WRITING", implementation_iteration: 20})
    Store.query!(context.store, "UPDATE factory_tasks SET stage='REVIEW_WRITING',status='RUNNING' WHERE task_key=?", [key])
    rewrite_execution_binding(context.store, %{"stage" => "REVIEW_WRITING"})

    for phase <- ~w(START_SENT THREAD_BOUND TURN_BOUND) do
      Store.query!(context.store, "UPDATE worker_evidence SET status=?,thread_id='current-thread',turn_id='current-turn' WHERE task_key=?", [phase, key])
      run = hd(Observability.snapshot(options).current_runs)
      assert run.worker_execution.status == if(phase == "TURN_BOUND", do: "TURN_BOUND", else: "STARTING")
      refute Enum.any?(run.attention_signals, &(&1.source == "IMPLEMENTATION_BUDGET"))
    end

    Store.query!(context.store, "UPDATE worker_evidence SET status='RESERVED' WHERE task_key=?", [key])
    assert hd(Observability.snapshot(options).current_runs).attention.source == "IMPLEMENTATION_BUDGET"
  end

  test "initial planner and writer bind the retained base when no candidate exists", context do
    {options, key} = execution_fixture(context)
    base = String.duplicate("c", 40)
    Store.query!(context.store, "INSERT INTO ticket_review_bases(run_id,base_ref,base_sha,bound_at) VALUES('execution','main',?,'2026-10-20T20:58:00Z')", [base])
    RunLedger.update(context.store, "execution", %{candidate_sha: nil})

    for {stage, role, mode} <- [{"WRITING", "feature-writer", "SOURCE"}, {"PLANNING", "feature-planner", "REVIEW"}] do
      next_key = "execution:" <> role
      Store.query!(context.store, "PRAGMA defer_foreign_keys=ON")

      Store.transaction!(context.store, fn tx ->
        Store.query!(tx, "PRAGMA defer_foreign_keys=ON")
        Store.query!(tx, "UPDATE factory_tasks SET task_key=?,stage=?,role=?,status='RUNNING' WHERE run_id='execution'", [next_key, stage, role])
        Store.query!(tx, "UPDATE workspace_access SET task_key=?,mode=? WHERE run_id='execution'", [next_key, mode])
        Store.query!(tx, "UPDATE worker_evidence SET task_key=?,status='TURN_BOUND',thread_id='current-thread',turn_id='current-turn' WHERE run_id='execution'", [next_key])
      end)

      RunLedger.update(context.store, "execution", %{state: stage})
      rewrite_execution_binding(context.store, %{"task_key" => next_key, "stage" => stage, "role" => role, "mode" => mode, "expected_sha" => base})
      assert hd(Observability.snapshot(options).current_runs).worker_execution.status == "TURN_BOUND"
    end

    assert key == "execution:feature-writer"
  end

  test "released or mismatched reservations cannot hide the iteration cap", context do
    {options, key} = execution_fixture(context)
    options = Keyword.put(options, :settings, %{factory: Map.put(context.factory, :maximum_implementation_iterations, 20)})
    RunLedger.update(context.store, "execution", %{implementation_iteration: 20})
    Store.query!(context.store, "UPDATE factory_tasks SET status='RUNNING' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='TURN_BOUND',thread_id='current',turn_id='current' WHERE task_key=?", [key])

    for {column, invalid, original} <- [{"released_at", "2026-10-20T20:59:30Z", nil}, {"request_key", "foreign-request", "execution-request"}, {"generation", 2, 1}, {"mode", "REVIEW", "SOURCE"}] do
      Store.query!(context.store, "UPDATE workspace_access SET #{column}=? WHERE reservation_key='execution-access'", [invalid])
      run = hd(Observability.snapshot(options).current_runs)
      assert run.worker_execution.status == "UNKNOWN"
      assert Enum.any?(run.attention_signals, &(&1.source == "IMPLEMENTATION_BUDGET"))
      Store.query!(context.store, "UPDATE workspace_access SET #{column}=? WHERE reservation_key='execution-access'", [original])
    end

    rewrite_execution_binding(context.store, %{"reservation_key" => "foreign-access"})
    assert hd(Observability.snapshot(options).current_runs).worker_execution.status == "UNKNOWN"
    Store.query!(context.store, "UPDATE worker_evidence SET status='RECONCILE_REQUIRED' WHERE task_key=?", [key])
    run = hd(Observability.snapshot(options).current_runs)
    assert run.attention.source == "NATIVE_WORKER"
    assert Enum.any?(run.attention_signals, &(&1.source == "IMPLEMENTATION_BUDGET"))
  end

  defp rewrite_execution_binding(store, changes) do
    evidence = Store.one!(store, "SELECT binding_json FROM worker_evidence WHERE run_id='execution'")
    raw = evidence["binding_json"] |> Jason.decode!() |> Map.merge(changes) |> Jason.encode!()
    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    Store.query!(store, "UPDATE worker_evidence SET binding_json=?,binding_sha256=? WHERE run_id='execution'", [raw, sha])
  end

  test "canonical worker failure remains attention when task history display is empty", context do
    {options, key} = execution_fixture(context)
    Store.query!(context.store, "UPDATE factory_tasks SET status='FAILED',failure_code='exact-worker-failure' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='TURN_BOUND',thread_id='current',turn_id='current' WHERE task_key=?", [key])
    run = hd(Observability.snapshot(options).current_runs)
    assert run.tasks == []
    assert run.worker_execution.status == "UNKNOWN"
    assert run.attention.source == "TASK"
    assert run.attention.reason == "exact-worker-failure"
    assert Observability.snapshot(options).overview.by_issue["PPL-9881"] == "NEEDS_ATTENTION"
  end

  test "deferred snapshot remains coherent while another WAL connection advances the run", context do
    {options, key} = execution_fixture(context)
    Store.query!(context.store, "UPDATE factory_tasks SET status='RUNNING' WHERE task_key=?", [key])
    Store.query!(context.store, "UPDATE worker_evidence SET status='TURN_BOUND', thread_id='thread', turn_id='turn' WHERE task_key=?", [key])
    database = Store.query!(context.store, "PRAGMA database_list").rows |> Enum.find(fn [_, name, _] -> name == "main" end) |> List.last()
    writer = start_supervised!({Store, database: database}, id: :snapshot_writer)
    owner = self()

    callback = fn tx, run_id ->
      send(owner, {:snapshot_paused, self()})
      receive do: (:continue_snapshot -> :ok)
      TicketContext.context(tx, run_id)
    end

    pending = Task.async(fn -> Observability.snapshot(Keyword.put(options, :ticket_context, callback)) end)
    assert_receive {:snapshot_paused, reader}, 5_000

    Store.transaction!(writer, fn tx ->
      Store.query!(tx, "UPDATE runs SET state='VERIFYING' WHERE run_id='execution'")
      Store.query!(tx, "UPDATE factory_tasks SET status='CONSUMED' WHERE task_key=?", [key])
      Store.query!(tx, "UPDATE worker_evidence SET status='CONSUMED' WHERE task_key=?", [key])
    end)

    send(reader, :continue_snapshot)
    assert [%{state: "REPAIRING", worker_execution: %{status: "TURN_BOUND"}}] = Task.await(pending, 5_000).current_runs
    assert [%{state: "VERIFYING", worker_execution: %{status: "WAITING"}}] = Observability.snapshot(options).current_runs
  end

  test "uncertain push overrides active workflow and exposes bounded operation evidence", context do
    register_run(context.store, "uncertain-push", "PPL-123", "CI_PUSHING")

    envelope = %{
      kind: "TICKET_PUSH",
      phase: "PUSH_UNCERTAIN",
      reservation_key: "push-exact",
      binding_json: Jason.encode!(%{run_id: "uncertain-push", state: "CI_PUSHING"}),
      execution_json: Jason.encode!(%{authorization: %{observed_at: "2026-10-13T20:00:00Z"}})
    }

    {:ok, _} = RunLedger.update(context.store, "uncertain-push", %{candidate_handoff: Jason.encode!(envelope)})
    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server]
    snapshot = Observability.snapshot(options)
    assert snapshot.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert snapshot.overview.needs_attention == 1
    assert snapshot.overview.active == 0
    [run] = snapshot.current_runs
    assert run.state == "CI_PUSHING"
    assert run.attention.phase == "PUSH_UNCERTAIN"
    assert run.attention.source == "PUSH"
    assert run.attention.evidence_at == "2026-10-13T20:00:00Z"
    assert run.attention.reason =~ "not confirmed"
    assert run.attention.next_action =~ "Reconcile"
    {:ok, _} = RunLedger.update(context.store, "uncertain-push", %{candidate_handoff: nil})
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
  end

  test "current failed and aged native tasks outrank healthy scheduler but consumed history clears", context do
    register_run(context.store, "task-attention", "PPL-123", "WRITING")
    Store.query!(context.store, "UPDATE runs SET execution_mode = 'TICKET_SUPERVISOR_V1' WHERE run_id = 'task-attention'")
    key = "task-attention:feature-writer"

    {:ok, _} =
      TaskLedger.register(context.store, %{
        task_key: key,
        run_id: "task-attention",
        stage: "WRITING",
        role: "feature-writer",
        status: "FAILED",
        model_provider: "codex",
        model_class: "deep",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        routing_reason: "fixture",
        prompt_sha256: String.duplicate("a", 64)
      })

    {:ok, _} = TaskLedger.update(context.store, key, %{failure_code: "provider_quota_exceeded"})
    :ok = ControlServer.record_tick(:succeeded, context.control_server)
    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, now: ~U[2026-10-14 00:00:00Z]]
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert Observability.snapshot(options).control.tick_health.status == "HEALTHY"
    {:ok, _} = TaskLedger.update(context.store, key, %{status: "RUNNING", failure_code: nil})
    Store.query!(context.store, "UPDATE factory_tasks SET updated_at = '2026-10-13T20:00:00Z' WHERE task_key = ?", [key])
    stale = Observability.snapshot(options)
    assert hd(stale.current_runs).attention.phase == "PROGRESS_STALE"
    assert stale.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    Store.query!(context.store, "UPDATE factory_tasks SET updated_at = '2026-10-13T23:59:00Z' WHERE task_key = ?", [key])
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
    {:ok, _} = TaskLedger.update(context.store, key, %{status: "CONSUMED", failure_code: "old quota error"})
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
  end

  test "nonterminal stage progress ages independently of ticks while fresh CI wait remains active", context do
    register_run(context.store, "stage-attention", "PPL-123", "VERIFYING")
    Store.query!(context.store, "UPDATE runs SET updated_at = '2026-10-13T20:00:00Z' WHERE run_id = 'stage-attention'")
    :ok = ControlServer.record_tick(:succeeded, context.control_server)
    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, now: ~U[2026-10-14 00:00:00Z]]
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert hd(Observability.snapshot(options).current_runs).attention.phase == "PROGRESS_STALE"
    Store.query!(context.store, "UPDATE runs SET state = 'CI_WAITING', ci_last_checked_at = '2026-10-13T23:59:00Z' WHERE run_id = 'stage-attention'")
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
    {:ok, _} = RunLedger.update(context.store, "stage-attention", %{state: "READY_FOR_REVIEW"})
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "REVIEW_READY"
  end

  test "checkout and Jira uncertainty are visible independently of the recorded stage", context do
    register_run(context.store, "journal-attention", "PPL-123", "ADMITTING_WRITER")

    Store.query!(
      context.store,
      "INSERT INTO ticket_checkout_intents(run_id, canonical_path, repo_path, branch, binding_json, binding_sha256, phase, last_error) VALUES ('journal-attention', '/fixture/checkout', '/fixture/repo', 'fixture', '{}', 'digest', 'RECONCILE_REQUIRED', 'checkout helper termination unknown')"
    )

    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server]
    checkout = Observability.snapshot(options)
    assert checkout.available
    assert hd(checkout.current_runs).attention.source == "CHECKOUT"
    assert hd(checkout.current_runs).attention.reason =~ "termination unknown"

    Store.query!(
      context.store,
      "INSERT INTO ticket_jira_effects(operation_key, run_id, operation, binding_json, binding_sha256, effects_json, effects_sha256, phase, created_at, updated_at) VALUES ('jira-exact', 'journal-attention', 'START_IMPLEMENTATION', '{}', 'digest', '[]', 'digest', 'FIRST_UNCERTAIN', '2026-10-13T20:00:00Z', '2026-10-13T20:00:00Z')"
    )

    simultaneous = Observability.snapshot(options)
    assert Enum.map(hd(simultaneous.current_runs).attention_signals, & &1.source) == ["CHECKOUT", "JIRA"]
    Store.query!(context.store, "UPDATE ticket_checkout_intents SET phase = 'READY', last_error = NULL")
    jira = Observability.snapshot(options)
    assert hd(jira.current_runs).attention.source == "JIRA"
    assert jira.overview.needs_attention == 1
    Store.query!(context.store, "UPDATE ticket_jira_effects SET phase = 'COMPLETE'")
    assert Observability.snapshot(options).overview.needs_attention == 0
  end

  @tag :mr_preclaim_attention
  test "a rejected unclaimed MR handoff appears in ticket and broker attention until it is claimed", context do
    config = Map.take(context.factory, [:scope, :dispatcher_id, :lease_seconds])
    %{result: "CONTROLLER_TASK_RECORDED"} = Control.record_controller_task(context.store, config, "controller", nil, %{project_id: "projectless", model: "gpt-6-sol", reasoning_effort: "high"})
    register_run(context.store, "mr-admission", "PPL-123", "CI_MR_CREATING")
    {:ok, %{run: run}} = RunLedger.update(context.store, "mr-admission", %{candidate_sha: String.duplicate("c", 40), spec_revision: 1, contract_sha256: String.duplicate("d", 64)})
    binding = Map.take(run, ~w(run_id issue_key candidate_sha spec_revision contract_sha256)) |> Map.merge(%{"stage" => run["state"], "version" => 2, "operation" => "CREATE_OR_REUSE_DRAFT_MR"})

    {:ok, request} =
      DesktopRequest.enqueue(context.store, %{
        request_key: "mr-pending",
        target_kind: "CONTROLLER",
        target_key: context.factory.scope,
        action: "FOLLOWUP",
        codex_project_id: "projectless",
        existing_thread_id: "controller",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        title: "fixture",
        prompt: "fixture",
        cwd: "/fixture",
        schema: %{type: "object"},
        metadata: %{delivery_operation: binding}
      })

    options = [settings: %{factory: Map.put(context.factory, :task_transport, "desktop_broker")}, store: context.store, control_server: context.control_server]
    assert Observability.snapshot(options).overview.needs_attention == 0

    evidence =
      Map.take(binding, ~w(run_id candidate_sha spec_revision contract_sha256 stage))
      |> Map.merge(%{
        "version" => 1,
        "request_key" => request["request_key"],
        "payload_sha256" => request["payload_sha256"],
        "action" => "claim",
        "phase" => "READER",
        "reason_code" => "MR_READER_PROTOCOL_REJECTED"
      })

    Store.query!(context.store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,?,?,?)", [
      DateTime.to_iso8601(DateTime.utc_now()),
      "MR_OWNER_PRECLAIM_FAILED",
      run["run_id"],
      Jason.encode!(evidence)
    ])

    blocked = Observability.snapshot(options)
    assert blocked.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert blocked.broker.blocking_attention == 1
    assert hd(blocked.current_runs).attention.source == "BROKER"
    {:ok, reopened} = Store.start_link(database: context.store |> Store.query!("PRAGMA database_list") |> Map.fetch!(:rows) |> Enum.find_value(fn [_, name, path] -> if name == "main", do: path end))

    try do
      assert Observability.snapshot(Keyword.put(options, :store, reopened)).broker.blocking_attention == 1
    after
      GenServer.stop(reopened)
    end

    {:ok, _} = RunLedger.update(context.store, run["run_id"], %{candidate_sha: String.duplicate("e", 40)})
    refute Enum.any?(hd(Observability.snapshot(options).current_runs).attention_signals, &(&1.source == "BROKER"))
    {:ok, _} = RunLedger.update(context.store, run["run_id"], %{candidate_sha: run["candidate_sha"]})
    assert Observability.snapshot(options).broker.blocking_attention == 1
    Store.query!(context.store, "UPDATE desktop_requests SET status='FOLLOWUP_UNCERTAIN',claimed_at=? WHERE request_key=?", [DateTime.to_iso8601(DateTime.utc_now()), request["request_key"]])
    issued = Observability.snapshot(options)
    refute Enum.any?(hd(issued.current_runs).attention_signals, &(&1.source == "BROKER"))
  end

  test "current controller handoff and run errors outrank active status but old candidate errors do not", context do
    config = Map.take(context.factory, [:scope, :dispatcher_id, :lease_seconds])
    %{result: "CONTROLLER_TASK_RECORDED"} = Control.record_controller_task(context.store, config, "controller", nil, %{project_id: "projectless", model: "gpt-6-sol", reasoning_effort: "high"})
    register_run(context.store, "controller-attention", "PPL-123", "CI_MR_CREATING")
    {:ok, run} = RunLedger.get(context.store, "controller-attention")
    binding = Map.take(run, ~w(run_id issue_key candidate_sha spec_revision contract_sha256)) |> Map.put("stage", run["state"])

    {:ok, request} =
      DesktopRequest.enqueue(context.store, %{
        request_key: "controller-current",
        target_kind: "CONTROLLER",
        target_key: context.factory.scope,
        action: "FOLLOWUP",
        codex_project_id: "projectless",
        existing_thread_id: "controller",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        title: "fixture",
        prompt: "fixture",
        cwd: "/fixture",
        schema: %{type: "object"},
        metadata: %{delivery_operation: binding}
      })

    Store.query!(context.store, "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN' WHERE request_key = ?", [request["request_key"]])
    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server]
    assert hd(Observability.snapshot(options).current_runs).attention.source == "CONTROLLER"
    Store.query!(context.store, "UPDATE desktop_requests SET status = 'FAILED', failure_code = 'provider_quota_exceeded' WHERE request_key = ?", [request["request_key"]])
    assert hd(Observability.snapshot(options).current_runs).attention.reason == "provider_quota_exceeded"

    Store.query!(context.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [
      Jason.encode!(%{delivery_operation: Map.put(binding, "candidate_sha", "old")}),
      request["request_key"]
    ])

    assert Observability.snapshot(options).overview.needs_attention == 0
    {:ok, _} = RunLedger.update(context.store, "controller-attention", %{failure_code: "current_stage_error"})
    assert hd(Observability.snapshot(options).current_runs).attention.reason == "current_stage_error"
    {:ok, _} = RunLedger.update(context.store, "controller-attention", %{failure_code: nil, last_error: "current failure detail"})
    assert hd(Observability.snapshot(options).current_runs).attention.reason == "current failure detail"
    {:ok, _} = RunLedger.update(context.store, "controller-attention", %{last_error: nil})
    Store.query!(context.store, "UPDATE desktop_requests SET metadata_json = '{}' WHERE request_key = ?", [request["request_key"]])
    :ok = ControlServer.record_tick(:succeeded, context.control_server)
    global = Observability.snapshot(options)
    assert global.control.tick_health.status == "HEALTHY"
    assert global.control.handoff_attention.reason == "provider_quota_exceeded"
    assert global.control.handoff_attention.category == "HISTORY"
    refute global.control.handoff_attention.blocking
    assert global.overview.needs_attention == 0
    Store.query!(context.store, "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL WHERE request_key = ?", [request["request_key"]])
    assert Observability.snapshot(options).control.handoff_attention == nil
  end

  test "controller check timeout and native errors remain visible while task status is running", context do
    register_run(context.store, "check-attention", "PPL-123", "WRITING")
    key = "check-attention:feature-writer"

    {:ok, _} =
      TaskLedger.register(context.store, %{
        task_key: key,
        run_id: "check-attention",
        stage: "WRITING",
        role: "feature-writer",
        status: "RUNNING",
        model_provider: "codex",
        model_class: "deep",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "fixture",
        prompt_sha256: "digest"
      })

    Store.query!(
      context.store,
      "INSERT INTO workspace_access(reservation_key, run_id, task_key, request_key, mode, generation, canonical_path, git_dir, common_dir, binding_json, acquired_at) VALUES ('check-access', 'check-attention', ?, 'worker-current', 'SOURCE', 1, '/fixture/check', '/fixture/check/.git', '/fixture/common', '{}', '2026-10-13T23:59:00Z')",
      [key]
    )

    Store.query!(
      context.store,
      "INSERT INTO worker_evidence(request_key, task_key, run_id, reservation_key, binding_json, binding_sha256, status, owner_id, created_at) VALUES ('worker-current', ?, 'check-attention', 'check-access', '{}', 'digest', 'TURN_BOUND', 'fixture', '2026-10-13T23:59:00Z')",
      [key]
    )

    Store.query!(
      context.store,
      "INSERT INTO controller_checks(check_key, worker_request_key, reservation_key, binding_json, binding_sha256, phase, error) VALUES ('check-current', 'worker-current', 'check-access', '{}', 'digest', 'RUNNING', 'helper transport timed out')"
    )

    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, now: ~U[2026-10-14 00:00:00Z]]
    assert hd(Observability.snapshot(options).current_runs).attention.source == "CONTROLLER_CHECK"
    Store.query!(context.store, "UPDATE controller_checks SET phase = 'COMPLETE', error = NULL, receipt_json = '{\"result\":\"FAIL\",\"timed_out\":true}'")
    assert hd(Observability.snapshot(options).current_runs).attention.phase == "TIMED_OUT"
    {:ok, _} = RunLedger.update(context.store, "check-attention", %{state: "READY_FOR_REVIEW"})
    assert hd(Observability.snapshot(options).current_runs).attention.phase == "TIMED_OUT"
    assert Observability.snapshot(options).overview.needs_attention == 1
    {:ok, _} = RunLedger.update(context.store, "check-attention", %{state: "WRITING"})
    Store.query!(context.store, "UPDATE controller_checks SET receipt_json = '{\"result\":\"PASS\"}'")
    Store.query!(context.store, "UPDATE worker_evidence SET status = 'RECONCILE_REQUIRED', failure_code = 'native turn transport failed'")
    native = Observability.snapshot(options)
    assert native.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert hd(native.current_runs).attention.reason == "native turn transport failed"
    Store.query!(context.store, "UPDATE worker_evidence SET status = 'CONSUMED'")
    {:ok, _} = TaskLedger.update(context.store, key, %{status: "CONSUMED"})
    assert Observability.snapshot(options).overview.needs_attention == 0
  end

  @tag broker_attention_classification: true
  test "stale parent synchronization remains separate after proven push recovery completes", context do
    register_run(context.store, "parent-attention", "PPL-123", "CI_PUSHING")

    Store.query!(
      context.store,
      "INSERT INTO ticket_chats(chat_key,scope_key,issue_id,issue_key,repo_key,route,generation,create_request_key,directory_name,cwd,model,reasoning_effort,context_sequence,presentation_request_key,created_at,updated_at) VALUES ('parent-chat','fixture','issue','PPL-123','symphony','desktop_owned_ticket_chat_v1',1,'create-exact','fixture-parent','/fixture/parent','gpt-6-sol','high',1,'parent-notice','2026-10-13T20:00:00Z','2026-10-13T20:00:00Z')"
    )

    Store.query!(context.store, "INSERT INTO ticket_chat_runs(run_id,chat_key,created_at) VALUES ('parent-attention','parent-chat','2026-10-13T20:00:00Z')")

    Store.query!(context.store, "UPDATE ticket_chats SET thread_id = 'parent-thread' WHERE chat_key = 'parent-chat'")
    chat = Store.one!(context.store, "SELECT * FROM ticket_chats WHERE chat_key = 'parent-chat'")

    assert {:ok, _} =
             DesktopRequest.enqueue(context.store, %{
               request_key: "parent-notice",
               target_kind: "TICKET_CHAT",
               target_key: "parent-chat",
               action: "FOLLOWUP",
               codex_project_id: nil,
               model: "gpt-6-sol",
               reasoning_effort: "high",
               existing_thread_id: "parent-thread",
               title: "fixture",
               prompt: "Controller-observed AS-OF presentation only; not human input or source authority.",
               schema: %{type: "object", properties: %{acknowledged: %{type: "boolean"}}, required: ["acknowledged"], additionalProperties: false},
               cwd: "/fixture/parent",
               metadata: SymphonyElixir.Factory.TicketChat.request_metadata(chat)
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN', claimed_at = '2026-10-13T20:00:00Z', created_at = '2026-10-13T20:00:00Z', updated_at = '2026-10-13T20:00:00Z' WHERE request_key = 'parent-notice'"
    )

    options = [settings: %{factory: Map.put(context.factory, :task_transport, "desktop_broker")}, store: context.store, control_server: context.control_server, now: ~U[2026-10-14 00:00:00Z]]
    envelope = %{kind: "TICKET_PUSH_CAS_RECOVERY", phase: "PUSH_UNCERTAIN", old_outcome: "UNKNOWN", original_envelope: "sensitive_nonce_marker"}
    {:ok, _} = RunLedger.update(context.store, "parent-attention", %{candidate_handoff: Jason.encode!(envelope)})
    snapshot = Observability.snapshot(options)
    assert hd(snapshot.current_runs).attention.source == "PUSH"
    assert Enum.any?(hd(snapshot.current_runs).attention_signals, &(&1.source == "PARENT_SYNC" and &1.phase == "FOLLOWUP_UNCERTAIN"))
    refute Jason.encode!(snapshot) =~ "sensitive_nonce_marker"
    assert hd(snapshot.current_runs).handoff.previous_outcome == "UNKNOWN"
    {:ok, run} = RunLedger.get(context.store, "parent-attention")
    binding = Map.take(run, ~w(run_id issue_key candidate_sha spec_revision contract_sha256)) |> Map.put("stage", run["state"])

    Store.query!(
      context.store,
      "INSERT INTO desktop_requests(request_key,target_kind,target_key,action,status,payload_sha256,codex_project_id,model,reasoning_effort,existing_thread_id,title,prompt,schema_json,cwd,metadata_json,claimed_at,created_at,updated_at) VALUES ('controller-notice','CONTROLLER','fixture','FOLLOWUP','FOLLOWUP_UNCERTAIN','digest','projectless','gpt-6-sol','high','controller-thread','fixture','fixture','{}','/fixture/controller',?,'2026-10-13T23:59:00Z','2026-10-13T23:59:00Z','2026-10-13T23:59:00Z')",
      [Jason.encode!(%{delivery_operation: binding})]
    )

    simultaneous = hd(Observability.snapshot(options).current_runs).attention_signals
    assert Enum.any?(simultaneous, &(&1.source == "CONTROLLER"))
    assert Enum.any?(simultaneous, &(&1.source == "PARENT_SYNC"))
    Store.query!(context.store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE request_key = 'controller-notice'")
    Store.query!(context.store, "UPDATE ticket_chats SET thread_id = 'parent-thread' WHERE chat_key = 'parent-chat'")
    {:ok, _} = RunLedger.update(context.store, "parent-attention", %{candidate_handoff: Jason.encode!(Map.put(envelope, :phase, "COMPLETED"))})
    completed = Observability.snapshot(options)
    assert hd(completed.current_runs).attention.source == "PARENT_SYNC"
    assert hd(completed.current_runs).handoff.previous_outcome == "UNKNOWN"
    assert completed.overview.needs_attention == 0
    assert completed.overview.active == 1
    assert completed.overview.delivery_blocked == 0
    assert completed.overview.communication_attention == 1
    Store.query!(context.store, "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED' WHERE request_key = 'parent-notice'")
    communication = Observability.snapshot(options)
    assert communication.broker.communication_warnings == 1
    assert communication.broker.blocking_attention == 0
    assert communication.broker.needs_reconciliation == 1
    saved_payload_hash = Store.one!(context.store, "SELECT payload_sha256 FROM desktop_requests WHERE request_key = 'parent-notice'")["payload_sha256"]
    Store.query!(context.store, "UPDATE desktop_requests SET payload_sha256 = 'broken' WHERE request_key = 'parent-notice'")
    unclassified = Observability.snapshot(options)
    assert unclassified.broker.communication_warnings == 0
    assert unclassified.broker.blocking_attention == 1
    Store.query!(context.store, "UPDATE desktop_requests SET payload_sha256 = ? WHERE request_key = 'parent-notice'", [saved_payload_hash])
    assert hd(completed.current_runs).attention.blocking == false

    for changed <- [
          "UPDATE desktop_requests SET action = 'CREATE' WHERE request_key = 'parent-notice'",
          "UPDATE desktop_requests SET existing_thread_id = 'foreign' WHERE request_key = 'parent-notice'"
        ] do
      Store.query!(context.store, changed)
      guarded = Observability.snapshot(options)
      assert guarded.overview.delivery_blocked == 1
      Store.query!(context.store, "UPDATE desktop_requests SET action = 'FOLLOWUP', existing_thread_id = 'parent-thread' WHERE request_key = 'parent-notice'")
    end

    sha = String.duplicate("a", 40)
    mr_url = "https://gitlab.example/group/repo/-/merge_requests/1"

    evidence = %{
      "status" => "BLOCK",
      "sha" => sha,
      "iid" => 1,
      "mr_url" => mr_url,
      "pipeline_id" => 99,
      "pipeline_sha" => sha,
      "pipeline_url" => "https://gitlab.example/group/repo/-/pipelines/99",
      "source_binding" => %{"kind" => "HEAD", "candidate_sha" => sha},
      "failed_jobs" => [
        %{"name" => "bazel", "status" => "failed", "web_url" => "https://gitlab.example/group/repo/-/jobs/100"},
        %{"name" => "foreign", "status" => "failed", "web_url" => "https://secret@foreign.example/job"}
      ]
    }

    evidence = Map.merge(evidence, %{"pipeline_source" => "merge_request_event", "pipeline_ref" => "refs/merge-requests/1/head"})

    {:ok, _} =
      RunLedger.update(context.store, "parent-attention", %{
        state: "CI_WAITING",
        candidate_sha: sha,
        ci_preflight_sha: sha,
        mr_iid: 1,
        mr_url: mr_url,
        ci_pipeline_id: 99,
        ci_pipeline_url: evidence["pipeline_url"],
        ci_evidence_json: Jason.encode!(evidence)
      })

    blocked_ci = Observability.snapshot(options)
    assert hd(blocked_ci.current_runs).attention.source == "CI"
    assert hd(blocked_ci.current_runs).attention.pipeline_url == evidence["pipeline_url"]
    assert hd(blocked_ci.current_runs).attention.failed_jobs |> Enum.map(& &1.url) == ["https://gitlab.example/group/repo/-/jobs/100", nil]
    assert blocked_ci.overview.delivery_blocked == 1 and blocked_ci.overview.communication_attention == 1
    assert hd(blocked_ci.current_runs).primary_next_action =~ "independent verification remains gated"
    Store.query!(context.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES ('repairable','parent-attention',?,99,'{}','fixture','{}','fixture','REPAIRABLE','2026-10-13T23:59:00Z')", [sha])
    repair_options = Keyword.put(options, :settings, %{factory: Map.put(context.factory, :ticket_supervisor, %{"enabled" => true, "all_eligible_tickets" => true, "ci_repair" => "native_bounded_v1"})})
    repairable = Observability.snapshot(repair_options)
    assert repairable.overview.needs_attention == 0
    assert hd(repairable.current_runs).attention.blocking == false
    assert hd(repairable.current_runs).primary_next_action =~ "repair"
    {:ok, _} = RunLedger.update(context.store, "parent-attention", %{ci_evidence_json: Jason.encode!(Map.put(evidence, "sha", String.duplicate("b", 40)))})
    assert hd(Observability.snapshot(options).current_runs).attention.source == "PARENT_SYNC"
    {:ok, _} = RunLedger.update(context.store, "parent-attention", %{ci_evidence_json: nil})

    for {stage, bucket} <- [{"READY_FOR_REVIEW", "REVIEW_READY"}, {"AWAITING_VALIDATION", "VALIDATION_PENDING"}] do
      {:ok, _} = RunLedger.update(context.store, "parent-attention", %{state: stage})
      ready = Observability.snapshot(options)
      assert hd(ready.current_runs).state == stage
      assert hd(ready.current_runs).attention.source == "PARENT_SYNC"
      assert ready.overview.by_issue["PPL-123"] == bucket
      assert ready.overview.needs_attention == 0
      assert ready.presentation_attention_count == 1
      if stage == "READY_FOR_REVIEW", do: assert(ready.overview.review_ready == 1)
      if stage == "AWAITING_VALIDATION", do: assert(ready.overview.validation_pending == 1)
    end

    {:ok, _} = RunLedger.update(context.store, "parent-attention", %{state: "READY_FOR_REVIEW", candidate_handoff: Jason.encode!(envelope)})
    inconsistent = Observability.snapshot(options)
    assert inconsistent.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert inconsistent.overview.review_ready == 0
    assert inconsistent.overview.needs_attention == 1
    {:ok, _} = RunLedger.update(context.store, "parent-attention", %{candidate_handoff: Jason.encode!(Map.put(envelope, :phase, "COMPLETED"))})

    Store.query!(context.store, "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL WHERE request_key = 'parent-notice'")
    assert Observability.snapshot(options).overview.needs_attention == 0
  end

  test "a stopped blocked writer needs attention despite retaining its writing stage", context do
    {:ok, _} =
      RunLedger.register(context.store, %{run_id: "blocked-initial-writer", issue_key: "PPL-123", kind: "DELIVERY", state: "WRITING", execution_mode: "TICKET_SUPERVISOR_V1", repo_key: "symphony"})

    packet = %{
      identity: %{"thread_id" => "ticket-parent"},
      run: %{"candidate_sha" => nil, "spec_revision" => 1},
      ci: %{},
      manual_validation: %{},
      open_questions: [],
      next_action: "Resume only after fixing the recorded blocker.",
      tasks: [],
      writer_disposition: %{
        status: "BLOCKED",
        request_key: "blocked-writer-request",
        blockers: ["The pinned Cadence test harness exceeds the required attempt count."],
        next_action: "Correct the test harness without changing the production retry policy."
      }
    }

    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, ticket_context: fn _, _ -> {:ok, packet} end]
    snapshot = Observability.snapshot(options)
    assert snapshot.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert snapshot.overview.active == 0
    assert snapshot.overview.needs_attention == 1
    assert hd(snapshot.current_runs).state == "WRITING"
    assert hd(snapshot.current_runs).ticket_context.writer_disposition == packet.writer_disposition
    assert hd(snapshot.current_runs).attention.source == "WORKER_RESULT"
    assert hd(snapshot.current_runs).attention.phase == "WRITER_BLOCKED"
    assert hd(snapshot.current_runs).attention.blocking
    assert hd(snapshot.current_runs).attention.reason =~ "pinned Cadence test harness"
    assert hd(snapshot.current_runs).primary_next_action == packet.writer_disposition.next_action

    cleared = Keyword.put(options, :ticket_context, fn _, _ -> {:ok, Map.put(packet, :writer_disposition, nil)} end)
    assert Observability.snapshot(cleared).overview.by_issue["PPL-123"] == "ACTIVE"
  end

  test "native current-stage failures need attention without a Desktop request or usable context", context do
    register_run(context.store, "native-rejected", "PPL-123", "WRITING")
    Store.query!(context.store, "UPDATE runs SET execution_mode = 'TICKET_SUPERVISOR_V1' WHERE run_id = 'native-rejected'")
    key = "native-rejected:feature-writer"

    assert {:ok, _} =
             TaskLedger.register(context.store, %{
               task_key: key,
               run_id: "native-rejected",
               stage: "WRITING",
               role: "feature-writer",
               status: "STALE",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6.1-sol",
               reasoning_effort: "high",
               routing_reason: "fixture",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _} = TaskLedger.update(context.store, key, %{failure_code: "already has an active writer"})
    options = [settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, ticket_context: fn _, _ -> {:error, :context_identity_exceeds_budget} end]
    snapshot = Observability.snapshot(options)
    assert snapshot.overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
    assert hd(snapshot.current_runs).handoff_attention.reason =~ "already has an active writer"
    assert hd(snapshot.current_runs).handoff_attention.label == "Native worker needs attention"
    assert snapshot.broker == nil
    assert {:ok, _} = TaskLedger.update(context.store, key, %{status: "CONSUMED"})
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
    assert {:ok, _} = TaskLedger.update(context.store, key, %{status: "STALE", stage: "PLANNING"})
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
    Store.query!(context.store, "UPDATE runs SET state = 'VERIFYING', verifier_round = 1 WHERE run_id = 'native-rejected'")

    for {round, status} <- [{0, "STALE"}, {1, "RUNNING"}] do
      task_key = "native-rejected:change-verifier:#{round}"

      assert {:ok, _} =
               TaskLedger.register(context.store, %{
                 task_key: task_key,
                 run_id: "native-rejected",
                 stage: "VERIFYING",
                 role: "change-verifier",
                 status: status,
                 model_provider: "codex",
                 model_class: "deep",
                 model: "gpt-6.1-sol",
                 reasoning_effort: "high",
                 routing_reason: "fixture",
                 prompt_sha256: String.duplicate("a", 64)
               })

      assert {:ok, _} = TaskLedger.update(context.store, task_key, %{failure_code: "old failure"})
    end

    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "ACTIVE"
    assert {:ok, _} = TaskLedger.update(context.store, "native-rejected:change-verifier:1", %{status: "STALE"})
    assert Observability.snapshot(options).overview.by_issue["PPL-123"] == "NEEDS_ATTENTION"
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
             control_server_started_at: started_at,
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

  test "returns explicit disabled state without consulting the runtime" do
    disabled =
      Observability.snapshot(
        settings: %{factory: %{enabled: false}},
        store: :must_not_be_used,
        control_server: :must_not_be_used
      )

    assert disabled.disabled
    refute disabled.enabled
    refute disabled.available
    assert disabled.error == nil
    assert %{disabled: true} = Observability.snapshot(settings: :not_a_settings_map, store: :must_not_be_used)
  end

  test "current workflows outside the recent-run window remain projected once", context do
    assert {:ok, _} = RunLedger.register(context.store, %{run_id: "older-active", issue_key: "PPL-OLD", kind: "DELIVERY", state: "VERIFYING"}, now: ~U[2026-09-01 00:00:00Z])
    assert {:ok, _} = RunLedger.register(context.store, %{run_id: "newer-run", issue_key: "PPL-NEW", kind: "DELIVERY", state: "IMPLEMENTING"}, now: ~U[2026-09-02 00:00:00Z])

    snapshot = Observability.snapshot(settings: %{factory: context.factory}, store: context.store, control_server: context.control_server, run_limit: 1)

    assert Enum.map(snapshot.runs, & &1.run_id) == ["newer-run"]
    assert Enum.map(snapshot.current_runs, & &1.run_id) == ["newer-run", "older-active"]
    assert Enum.count(snapshot.current_runs, &(&1.run_id == "older-active")) == 1
  end

  @tag broker_attention_classification: true
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
             uncertain: 0,
             awaiting_result: 0,
             needs_reconciliation: 0,
             blocking_attention: 0,
             communication_warnings: 0,
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

    assert %{pending: 0, claimed_unverified: 1, uncertain: 1, awaiting_result: 0, needs_reconciliation: 0} =
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
        now: ~U[2026-09-29 11:30:00Z],
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
             delivery_blocked: 2,
             communication_attention: 0,
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
        now: ~U[2026-10-01 19:02:00Z],
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
