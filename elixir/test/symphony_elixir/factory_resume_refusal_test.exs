defmodule SymphonyElixir.FactoryResumeRefusalTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{StageSchemas, Store, TaskLauncher, TaskLedger, TicketWorkerRunner, WorkerEvidence, WorkspaceAccess}
  setup :setup_fixture

  test "correlated resume refusal retains requested identity and exact raw error without another execution", ctx do
    raw = %{"code" => -32_600, "message" => "Thread already has an active writer.", "data" => %{"extra" => [1, true, nil], "reason" => "writer_present"}}
    trace = configure_server(ctx, raw)

    assert {:error, {:native_resume_refused, refusal}} = AppServer.start_session(ctx.path, resume_thread_id: "existing-thread", fork_on_active_writer: false)
    assert refusal == %{"version" => 1, "method" => "thread/resume", "requested_thread_id" => "existing-thread", "classification" => "active_writer", "raw_error" => raw}
    requests = requests(trace)
    assert Enum.count(requests, &(&1["method"] == "thread/resume")) == 1
    refute Enum.any?(requests, &(&1["method"] in ~w(thread/start thread/fork turn/start)))
  end

  for message <- ["thread existing-thread already has an active writer", "Already has an active writer.", "Cannot resume: another active writer exists"] do
    @refusal_message message
    test "typed refusal survives reopen and retries the same thread: #{@refusal_message}", ctx do
      {prompt, options} = prepare_resume(ctx)
      raw = %{"code" => -32_600, "message" => @refusal_message, "data" => %{"opaque" => [true, nil, %{"code" => "writer_present"}]}}
      trace = configure_server(ctx, raw)
      configure_worker(trace)
      assert {:error, {:native_resume_refused, refusal} = reason} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)
      assert refusal["raw_error"] == raw
      assert TaskLauncher.retryable_writer_conflict?(reason)
      {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STALE", failure_code: inspect(reason)})
      {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
      assert failed["status"] == "RECONCILE_REQUIRED"
      assert Enum.all?(~w(thread_id turn_id item_id output_json policy_json owner_process_json owner_stop_json), &is_nil(failed[&1]))
      assert {:error, :worker_resume_retry_not_due} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
      Store.query!(ctx.store, "UPDATE factory_tasks SET updated_at='2026-01-01T00:00:00Z' WHERE task_key='writer'")
      {:ok, reopened} = Store.start_link(database: ctx.database)

      try do
        observed = Store.one!(reopened, "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_RESUME_FAILURE_OBSERVED'") |> Map.fetch!("payload_json") |> Jason.decode!()
        assert observed["refusal"] == refusal
        assert observed["input_sha256"] == Jason.decode!(failed["binding_json"])["input_sha256"]
        assert {:ok, %{"status" => "RESERVED"}} = WorkerEvidence.rearm_rejected_resume(reopened, "reservation:request")
        File.write!(trace <> ".allow", "writer released")
        assert {:ok, resumed} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), Keyword.put(options, :store, reopened))
        assert resumed.thread_id == "existing-thread" and resumed.turn_id == "resumed-turn"
        assert {:ok, current} = WorkerEvidence.get(reopened, "reservation:request")
        assert current["binding_json"] == failed["binding_json"]
        assert WorkerEvidence.owner_stopped?(reopened, current)
        methods = Enum.map(requests(trace), & &1["method"])
        assert Enum.count(methods, &(&1 == "thread/resume")) == 2
        assert Enum.count(methods, &(&1 == "turn/start")) == 1
        refute Enum.any?(methods, &(&1 in ~w(thread/start thread/fork)))
      after
        GenServer.stop(reopened)
      end
    end
  end

  test "other RPC methods, foreign responses and port loss never become factory retry evidence", ctx do
    raw = %{"code" => -32_600, "message" => "thread existing-thread already has an active writer"}
    trace = configure_server(ctx, raw)

    for method <- ~w(initialize thread/start) do
      File.write!(trace <> ".method", method)
      assert {:error, {:response_error, ^raw} = reason} = AppServer.start_session(ctx.path)
      refute TaskLauncher.retryable_writer_conflict?(reason)
      assert TaskLauncher.legacy_controller_writer_conflict?(reason)
    end

    File.write!(trace <> ".method", "thread/resume")
    File.write!(trace <> ".foreign-id", "wrong response")
    assert {:error, reason} = AppServer.start_session(ctx.path, resume_thread_id: "existing-thread")
    refute TaskLauncher.retryable_writer_conflict?(reason)
    File.rm!(trace <> ".foreign-id")
    File.write!(trace <> ".exit", "lost transport")
    assert {:error, {:port_exit, 17} = reason} = AppServer.start_session(ctx.path, resume_thread_id: "existing-thread")
    refute TaskLauncher.retryable_writer_conflict?(reason)
    refute Enum.any?(requests(trace), &(&1["method"] in ~w(thread/fork turn/start)))
  end

  test "new unclassified failures cannot impersonate the exact stored legacy message", ctx do
    {_prompt, _options} = prepare_resume(ctx)
    reserve_current(ctx)
    reason = {:response_error, %{"code" => -32_600, "message" => "thread existing-thread already has an active writer"}}
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, "reservation:request", reason)
    stale(ctx, reason)
    assert {:error, :worker_resume_rejection_unproven} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
    [observed] = outcomes(ctx.store)
    assert is_nil(observed["refusal"])
    assert observed["failure_code"] == inspect(reason)
  end

  test "turn-start errors with identical wording remain bound uncertain sessions, not resume refusals", ctx do
    {prompt, options} = prepare_resume(ctx)
    raw = %{"code" => -32_600, "message" => "thread existing-thread already has an active writer", "data" => %{"extra" => true}}
    trace = configure_server(ctx, raw)
    configure_worker(trace)
    File.write!(trace <> ".method", "turn/start")
    File.write!(trace <> ".allow", "resume only")
    assert {:error, {:response_error, ^raw} = reason} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)
    refute TaskLauncher.retryable_writer_conflict?(reason)
    stale(ctx, reason)
    {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert failed["thread_id"] == "existing-thread"
    assert is_binary(failed["owner_process_json"])
    assert {:error, :worker_resume_rejection_unproven} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
    [observed] = outcomes(ctx.store)
    assert observed["refusal"] == nil
    methods = Enum.map(requests(trace), & &1["method"])
    assert Enum.count(methods, &(&1 == "turn/start")) == 1
    refute Enum.any?(methods, &(&1 in ~w(thread/start thread/fork)))
  end

  test "unknown error code or unsupported wording preserves raw errors without typed retry", ctx do
    for raw <- [
          %{"code" => -32_602, "message" => "Already has an active writer."},
          %{"code" => -32_600, "message" => "No active writer exists."},
          %{"code" => -32_600, "message" => "permission denied", "data" => %{"extra" => [1, false]}}
        ] do
      configure_server(ctx, raw)
      assert {:error, {:response_error, ^raw} = reason} = AppServer.start_session(ctx.path, resume_thread_id: "existing-thread")
      refute TaskLauncher.retryable_writer_conflict?(reason)
    end
  end

  test "historical exact legacy failures remain readable without granting wording variants a retry", ctx do
    {_prompt, _options} = prepare_resume(ctx)
    reserve_current(ctx)
    exact = inspect({:response_error, %{"code" => -32_600, "message" => "thread existing-thread already has an active writer"}})
    Store.query!(ctx.store, "UPDATE worker_evidence SET status='RECONCILE_REQUIRED',failure_code=? WHERE request_key='reservation:request'", [exact])
    Store.query!(ctx.store, "UPDATE factory_tasks SET status='STALE',failure_code=?,updated_at='2026-01-01T00:00:00Z' WHERE task_key='writer'", [exact <> "."])
    assert {:error, :worker_resume_rejection_unproven} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
    Store.query!(ctx.store, "UPDATE factory_tasks SET failure_code=? WHERE task_key='writer'", [exact])
    assert outcomes(ctx.store) == []
    assert {:ok, %{"status" => "RESERVED"}} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
  end

  test "typed event and unchanged pre-session ownership guards are both required", ctx do
    {prompt, options} = prepare_resume(ctx)
    raw = %{"code" => -32_600, "message" => "Already has an active writer.", "data" => %{"opaque" => true}}
    trace = configure_server(ctx, raw)
    configure_worker(trace)
    assert {:error, reason} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)
    stale(ctx, reason)
    {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    [event] = outcomes(ctx.store)

    bad_events = [
      [],
      nil,
      7,
      put_in(event, ["refusal", "raw_error", "data", "opaque"], false),
      put_in(event, ["refusal", "method"], "turn/start"),
      put_in(event, ["refusal", "requested_thread_id"], "foreign"),
      put_in(event, ["refusal", "version"], 2),
      put_in(event, ["refusal", "raw_error", "code"], -1),
      Map.put(event, "input_sha256", "foreign"),
      Map.put(event, "reservation_generation", 99),
      Map.put(event, "binding_sha256", "foreign"),
      Map.put(event, "failure_sha256", "foreign")
    ]

    for changed <- bad_events do
      Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE event_type='TICKET_WORKER_RESUME_FAILURE_OBSERVED'", [Jason.encode!(changed)])
      assert {:error, :worker_resume_rejection_unproven} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    end

    Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE event_type='TICKET_WORKER_RESUME_FAILURE_OBSERVED'", [Jason.encode!(event)])

    for field <- ~w(thread_id turn_id item_id output_json output_sha256 policy_json owner_process_json owner_stopped_at owner_stop_json) do
      Store.query!(ctx.store, "UPDATE worker_evidence SET #{field}=? WHERE request_key='reservation:request'", ["bound"])
      assert {:error, _} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
      Store.query!(ctx.store, "UPDATE worker_evidence SET #{field}=NULL WHERE request_key='reservation:request'")
    end

    Store.query!(
      ctx.store,
      "INSERT INTO worker_file_operations(request_key,call_id,arguments_sha256,path,before_sha256,after_sha256,phase) VALUES ('reservation:request','unexpected','hash','fixture.txt','before','after','PREPARED')"
    )

    assert {:error, :worker_resume_rejection_unproven} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
    Store.query!(ctx.store, "DELETE FROM worker_file_operations WHERE call_id='unexpected'")
    assert {:ok, %{"status" => "RESERVED"}} = WorkerEvidence.rearm_rejected_resume(ctx.store, "reservation:request")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  defp stale(ctx, reason) do
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STALE", failure_code: inspect(reason)})
    Store.query!(ctx.store, "UPDATE factory_tasks SET updated_at='2026-01-01T00:00:00Z' WHERE task_key='writer'")
  end

  defp outcomes(store),
    do: Store.query!(store, "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_RESUME_FAILURE_OBSERVED' ORDER BY id").rows |> Enum.map(fn [raw] -> Jason.decode!(raw) end)

  defp reserve_current(ctx) do
    {:ok, task} = TaskLedger.get(ctx.store, "writer")

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "reservation:request",
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "input_sha256" => task["prompt_sha256"],
        "owner_id" => "owned-invocation",
        "schema" => StageSchemas.for_stage(:native_feature_writer),
        "policy" => TicketWorkerRunner.policy("SOURCE", ctx.path)
      })

    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, "reservation:request")
  end

  defp prepare_resume(ctx) do
    bind_parent(ctx)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    hash = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: hash})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "prior"), opts(ctx))
    schema = StageSchemas.for_stage(:native_feature_writer)
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "prior:request",
        "task_key" => "writer",
        "reservation_key" => "prior",
        "input_sha256" => hash,
        "owner_id" => "prior-owner",
        "schema" => schema,
        "policy" => policy
      })

    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, "prior:request")
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, "prior:request", "existing-thread", policy)
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, "prior:request", process_receipt())
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, "prior:request", "existing-thread", "prior-turn")
    output = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => []}
    observed = %{thread_id: "existing-thread", turn_id: "prior-turn", item_id: "prior-final", output: output}
    {:ok, _} = WorkerEvidence.record_result(ctx.store, "prior:request", observed)
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, "prior:request", "prior-owner", stop_receipt(ctx, "existing-thread"))
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: "existing-thread", turn_id: "prior-turn", output_json: Jason.encode!(output)})
    {:ok, _} = WorkerEvidence.consume(ctx.store, "prior:request")
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STARTING"})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE"), opts(ctx))

    {prompt,
     [
       store: ctx.store,
       target_key: "writer",
       request_key: "reservation:request",
       reservation_key: "reservation",
       owner_id: "owned-invocation",
       model: "gpt-6-luna",
       reasoning_effort: "medium",
       review_base_sha: ctx.sha
     ]}
  end

  defp configure_worker(trace) do
    flags =
      Map.new(~w(shell_tool unified_exec apps multi_agent browser_use browser_use_external computer_use image_generation request_permissions_tool hooks), &{&1, false})
      |> Map.put("code_mode_host", true)

    File.write!(trace <> ".config", Jason.encode!(%{"config" => %{"mcp_servers" => %{}, "plugins" => %{}, "features" => flags, "web_search" => "disabled"}}))

    File.write!(
      trace <> ".initialize",
      Jason.encode!(%{
        "codexHome" => System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
        "platformFamily" => "unix",
        "platformOs" => "macos",
        "userAgent" => "symphony-orchestrator/0.163.0-alpha.11 (fixture)"
      })
    )
  end

  defp configure_server(ctx, error) do
    trace = Path.join(ctx.root, "resume.trace")
    binary = Path.join(ctx.root, "resume-server")
    script = Path.expand("../support/resume_refusal_server.py", __DIR__)
    File.write!(binary, "#!/bin/sh\nexec /usr/bin/python3 -I -S -B '#{script}' '#{trace}'\n")
    File.chmod!(binary, 0o755)
    File.write!(trace <> ".error", Jason.encode!(error))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.root, codex_command: "#{binary} app-server", codex_turn_timeout_ms: 5_000, codex_read_timeout_ms: 5_000)
    trace
  end

  defp requests(trace), do: trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
