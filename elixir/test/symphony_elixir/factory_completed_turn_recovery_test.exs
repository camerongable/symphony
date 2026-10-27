defmodule SymphonyElixir.FactoryCompletedTurnRecoveryTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, Scheduler, StageSchemas, Store, TaskLedger, TicketWorkerRunner, WorkerEvidence, WorkspaceAccess}
  setup :setup_fixture

  test "a completed native result survives a lost terminal acknowledgement without another execution", ctx do
    {prompt, options} = prepare(ctx)
    trace = configure_server(ctx)
    schema = StageSchemas.for_stage(:native_feature_writer)

    assert {:ok, observed} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, schema, options)
    assert observed.output == output()
    assert {observed.thread_id, observed.turn_id, observed.item_id} == {"completed-worker", "completed-turn", "completed-final"}
    assert {:ok, evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert evidence["status"] == "RESULT_RECORDED"
    assert WorkerEvidence.owner_stopped?(ctx.store, evidence)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "turn/start")) == 1
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 1
    refute Enum.any?(requests, &(&1["method"] in ~w(thread/resume thread/fork)))
  end

  test "reopened scheduler adopts a recorded native completion once without another turn", ctx do
    git(ctx.path, ["commit", "--no-verify", "--allow-empty", "-m", "prior candidate"])
    candidate = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: candidate})
    ctx = Map.put(ctx, :candidate_sha, candidate)
    {prompt, options} = prepare(ctx)
    trace = configure_server(Map.put(ctx, :deny_read, true))
    assert {:error, {:port_exit, 7}} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)
    {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert failed["status"] == "RECONCILE_REQUIRED"
    assert WorkerEvidence.owner_stopped?(ctx.store, failed)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING", status: "STALE", thread_id: failed["thread_id"], turn_id: failed["turn_id"], failure_code: failed["failure_code"]})
    File.rm!(trace <> ".deny-read")
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      factory = %{
        enabled: true,
        scope: "fixture",
        dispatcher_id: "fixture",
        lease_seconds: 240,
        maximum_code_repair_rounds: 2,
        maximum_implementation_iterations: 25,
        repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master"}}
      }

      context = %{store: reopened, factory: factory, workspace_root: ctx.root}
      assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", opts(ctx))
      assert run["state"] == "VERIFYING"
      {:ok, recorded} = WorkerEvidence.get(reopened, "reservation:request")
      assert recorded["status"] == "CONSUMED"
      [proof] = recovery_events(reopened)
      assert proof["failure_code"] == failed["failure_code"]
      assert proof["owner_stop_json"] == failed["owner_stop_json"]
      refute Jason.encode!(proof) =~ "agentMessage"
      assert length(recovery_events(reopened)) == 1
      assert execution_count(trace) == 1
    after
      GenServer.stop(reopened)
    end
  end

  test "committed recovery is an exact readback without another native read or stop rewrite", ctx do
    {trace, failed} = failed_attempt(ctx)
    assert {:ok, observed} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    {:ok, recorded} = WorkerEvidence.get(ctx.store, "reservation:request")
    events = recovery_events(ctx.store)
    requests = File.read!(trace)
    File.write!(trace <> ".deny-read", "unavailable")
    assert {:ok, ^observed} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    assert {:ok, ^recorded} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert recorded["owner_stop_json"] == failed["owner_stop_json"]
    assert recorded["owner_stopped_at"] == failed["owner_stopped_at"]
    assert recovery_events(ctx.store) == events
    assert length(events) == 1
    assert File.read!(trace) == requests
  end

  test "native completion records a bounded typed receipt while retaining the genuine nonzero stop", ctx do
    {trace, failed} = failed_attempt(ctx)
    assert {:ok, _} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    assert {:ok, recorded} = WorkerEvidence.get(ctx.store, "reservation:request")
    [proof] = recovery_events(ctx.store)
    assert proof["kind"] == "NATIVE_COMPLETION_RECEIPT_V1"
    assert proof["version"] === 1

    assert Enum.sort(Map.keys(proof)) ==
             Enum.sort(
               ~w(kind version request_key task_key run_id reservation_key reservation_generation owner_id owner_stopped_at binding_sha256 failure_code owner_stop_json native_parsed_json_sha256 native_completion native_observation thread_id turn_id item_id output_sha256)
             )

    binding = Jason.decode!(failed["binding_json"])

    assert Map.take(proof, ~w(request_key task_key run_id reservation_key owner_id owner_stopped_at binding_sha256 failure_code owner_stop_json thread_id turn_id)) ==
             Map.take(failed, ~w(request_key task_key run_id reservation_key owner_id owner_stopped_at binding_sha256 failure_code owner_stop_json thread_id turn_id))

    assert proof["reservation_generation"] == binding["reservation_generation"]
    assert proof["item_id"] == recorded["item_id"] and proof["output_sha256"] == recorded["output_sha256"]
    assert proof["native_completion"] == %{"status" => "completed", "error" => nil}
    assert proof["owner_stop_json"] == failed["owner_stop_json"]
    assert Jason.decode!(proof["owner_stop_json"])["exit_status"] == 7
    assert recorded["owner_stop_json"] == failed["owner_stop_json"] and recorded["owner_stopped_at"] == failed["owner_stopped_at"]
    assert byte_size(Jason.encode!(proof)) <= 32_768
    refute Jason.encode!(proof) =~ "agentMessage"
    assert execution_count(trace) == 1
  end

  @tag timeout: 180_000
  test "atomic receipt insertion rejects fabricated or altered metadata without changing the failed preimage", ctx do
    {trace, failed} = failed_attempt(ctx)
    binding = Jason.decode!(failed["binding_json"])
    {:ok, run} = RunLedger.get(ctx.store, failed["run_id"])
    {:ok, task} = TaskLedger.get(ctx.store, failed["task_key"])
    {:ok, access} = WorkspaceAccess.get(ctx.store, failed["reservation_key"])
    stop = Jason.decode!(failed["owner_stop_json"])
    before = %{evidence: failed, binding: binding, run: run, task: task, access: access, stop: stop}
    copy_path = Path.join(ctx.root, "before-native-completion.sqlite")
    assert {_, 0} = System.cmd("sqlite3", [ctx.database, ".backup '#{copy_path}'"])
    copy = start_supervised!({Store, database: copy_path}, id: :receipt_copy)
    assert {:ok, _observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    [proof] = recovery_events(ctx.store)
    missing = for key <- Map.keys(proof), do: fn result -> update_in(result, [:native_recovery], &Map.delete(&1, key)) end

    changes = [
      {["version"], true},
      {["kind"], "UNKNOWN"},
      {["request_key"], "foreign"},
      {["task_key"], "foreign"},
      {["run_id"], "foreign"},
      {["reservation_key"], "foreign"},
      {["reservation_generation"], 1.0},
      {["owner_id"], "foreign"},
      {["owner_stopped_at"], "2020-01-01T00:00:00Z"},
      {["binding_sha256"], String.duplicate("f", 64)},
      {["failure_code"], ":unknown"},
      {["owner_stop_json"], "{}"},
      {["native_parsed_json_sha256"], "not-a-hash"},
      {["thread_id"], "foreign"},
      {["turn_id"], "foreign"},
      {["item_id"], "foreign"},
      {["output_sha256"], String.duplicate("f", 64)},
      {["native_completion"], %{"status" => "completed"}},
      {["native_completion", "error"], %{}},
      {["native_observation", "thread", "cwd"], ctx.repo},
      {["native_observation", "thread", "id"], "foreign"},
      {["native_observation", "thread", "updatedAt"], -1},
      {["native_observation", "thread", "status"], %{"type" => "active"}},
      {["native_observation", "latest", "mode"], "UNKNOWN"},
      {["native_observation", "latest", "parameters", "limit"], 1.0},
      {["native_observation", "latest", "updated_at"], false},
      {["native_observation", "latest", "sha256"], "INVALID"},
      {["native_observation", "confirmation", "sha256"], "INVALID"},
      {["native_observation", "queue", "sha256"], "INVALID"},
      {["native_observation", "queue", "empty_complete"], false},
      {["native_observation", "queue", "count_lower_bound"], 0.0},
      {["native_observation", "queue", "has_more"], true},
      {["native_observation", "queue", "thread_id"], "foreign"}
    ]

    altered = for {path, value} <- changes, do: fn result -> put_in(result, [:native_recovery | path], value) end

    extra =
      for path <- [
            ["native_observation"],
            ["native_observation", "thread"],
            ["native_observation", "thread", "status"],
            ["native_observation", "latest"],
            ["native_observation", "latest", "parameters"],
            ["native_observation", "confirmation"],
            ["native_observation", "queue"]
          ],
          do: fn result -> update_in(result, [:native_recovery | path], &Map.put(&1, "unknown", true)) end

    times =
      for field <- ~w(latest confirmation queue),
          timestamp <- ["2020-01-01T00:00:00Z", "2999-01-01T00:00:00Z", "2026-10-27T00:00:00+00:00", nil],
          do: fn result -> put_in(result, [:native_recovery, "native_observation", field, "observed_at"], timestamp) end

    cases = missing ++ altered ++ extra ++ times ++ [&Map.delete(&1, :reconciliation_preimage)]

    # Fresh source-validated observations keep expiry from explaining a negative.
    for batch <- Enum.chunk_every(cases, 5) do
      reset_receipt_fixture(ctx.store, failed)
      assert {:ok, observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
      [fresh] = recovery_events(ctx.store)
      recovered = observed |> Map.put(:reconciliation_preimage, before) |> Map.put(:native_recovery, fresh)

      for mutate <- batch do
        assert {:error, _} = WorkerEvidence.reconcile_completed(copy, failed["request_key"], failed["owner_id"], mutate.(recovered), stop)
        assert {:ok, ^failed} = WorkerEvidence.get(copy, failed["request_key"])
        assert recovery_events(copy) == []
      end

      assert {:ok, _} = WorkerEvidence.reconcile_completed(copy, failed["request_key"], failed["owner_id"], recovered, stop)
      assert length(recovery_events(copy)) == 1
      reset_receipt_fixture(copy, failed)
    end

    assert {:ok, ^failed} = WorkerEvidence.get(copy, failed["request_key"])
    assert execution_count(trace) == 1
  end

  defp reset_receipt_fixture(store, failed) do
    Store.query!(store, "DELETE FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED' AND run_id=?", [failed["run_id"]])
    keys = ~w(status item_id output_json output_sha256 failure_code)
    Store.query!(store, "UPDATE worker_evidence SET " <> Enum.map_join(keys, ",", &(&1 <> "=?")) <> " WHERE request_key=?", Enum.map(keys, &failed[&1]) ++ [failed["request_key"]])
    assert {:ok, ^failed} = WorkerEvidence.get(store, failed["request_key"])
  end

  test "rejected result persistence rolls back the recovery event with the result", ctx do
    {trace, failed} = failed_attempt(ctx)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER reject_recovered_result BEFORE UPDATE OF status ON worker_evidence WHEN NEW.status='RESULT_RECORDED' BEGIN SELECT RAISE(ABORT,'synthetic result persistence failure'); END"
    )

    assert_raise Exqlite.Error, ~r/synthetic result persistence failure/, fn -> TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request") end
    assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert recovery_events(ctx.store) == []
    Store.query!(ctx.store, "DROP TRIGGER reject_recovered_result")
    assert {:ok, _} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    assert length(recovery_events(ctx.store)) == 1
    assert execution_count(trace) == 1
  end

  test "incomplete, foreign, duplicate, malformed and oversized native histories never recover", ctx do
    {trace, failed} = failed_attempt(ctx)
    original = Jason.decode!(File.read!(trace <> ".state"))
    turn = ["turns", Access.at(0)]
    item = turn ++ ["items", Access.at(0)]

    cases = [
      {"running", put_in(original, turn ++ ["status"], "inProgress")},
      {"failed", put_in(original, turn ++ ["status"], "failed")},
      {"interrupted", put_in(original, turn ++ ["status"], "interrupted")},
      {"missing error", update_in(original, turn, &Map.delete(&1, "error"))},
      {"native error", put_in(original, turn ++ ["error"], %{"message" => "fixture error"})},
      {"duplicate finals", update_in(original, turn ++ ["items"], &(&1 ++ &1))},
      {"no final", put_in(original, turn ++ ["items"], [])},
      {"commentary", put_in(original, item ++ ["phase"], "commentary")},
      {"missing phase", update_in(original, item, &Map.delete(&1, "phase"))},
      {"missing item ID", update_in(original, item, &Map.delete(&1, "id"))},
      {"empty result", put_in(original, item ++ ["text"], " ")},
      {"invalid JSON", put_in(original, item ++ ["text"], "not-json")},
      {"invalid schema", put_in(original, item ++ ["text"], "{}")},
      {"newer turn", put_in(original, turn ++ ["id"], "newer-turn")},
      {"foreign thread", put_in(original, ["id"], "foreign")},
      {"foreign cwd", put_in(original, ["cwd"], ctx.repo)},
      {"active actor", put_in(original, ["status", "type"], "active")},
      {"oversized", put_in(original, item ++ ["text"], String.duplicate("x", 2_097_153))}
    ]

    for {label, native} <- cases do
      File.write!(trace <> ".state", Jason.encode!(native))
      assert {:error, _} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request"), label
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request"), label
      assert recovery_events(ctx.store) == [], label
    end

    File.write!(trace <> ".state", Jason.encode!(original))
    assert {:ok, _} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    assert execution_count(trace) == 1
  end

  test "native version, confirmation and queue changes retain uncertainty", ctx do
    {trace, failed} = failed_attempt(ctx)

    for suffix <- ~w(.version-drift .confirmation-drift .queued) do
      File.write!(trace <> suffix, "changed")
      assert {:error, _} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
      assert recovery_events(ctx.store) == []
      File.rm!(trace <> suffix)
    end

    assert execution_count(trace) == 1
  end

  @tag :malformed_observation
  test "malformed native status shapes are explicit denials preserving the original failure", ctx do
    {trace, failed} = failed_attempt(ctx)
    native = Jason.decode!(File.read!(trace <> ".state"))

    for status <- [nil, "invalid", [], ["idle"], 7, false] do
      File.write!(trace <> ".state", Jason.encode!(Map.put(native, "status", status)))
      assert {:error, :completed_turn_native_unproven} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
      assert recovery_events(ctx.store) == []
    end

    assert execution_count(trace) == 1
  end

  @tag :malformed_observation
  test "immediate and scheduler recovery preserve a malformed provider response as uncertainty", ctx do
    {prompt, options} = prepare(ctx)
    trace = configure_server(Map.put(ctx, :native_status, "invalid"))
    assert {:error, {:port_exit, 7}} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)
    {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert failed["failure_code"] == inspect({:port_exit, 7})
    assert WorkerEvidence.owner_stopped?(ctx.store, failed)
    factory = %{enabled: true, scope: "fixture", dispatcher_id: "fixture", lease_seconds: 240, repositories: %{}}
    context = %{store: ctx.store, factory: factory, workspace_root: ctx.root}
    assert {:error, _} = Scheduler.ticket_step(context, "run", opts(ctx))
    assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert recovery_events(ctx.store) == []
    assert execution_count(trace) == 1
  end

  defmodule ObservationReader do
    def read_native_thread(thread, opts) do
      with {:ok, observed} <- SymphonyElixir.Codex.AppServer.read_native_thread(thread, opts),
           {:ok, raw} <- File.read(Path.join(opts[:workspace], ".observation-shape")),
           {:ok, %{"path" => path, "value" => value}} <- Jason.decode(raw) do
        {:ok, put_in(observed, path, value)}
      end
    end
  end

  @tag :malformed_observation
  test "malformed adapter observation containers and timestamps cannot become completion proof", ctx do
    {_trace, failed} = failed_attempt(ctx)
    containers = [["latest_turn_observation"], ["latest_turn_observation", "confirmation"], ["queue_observation"]]
    timestamps = [["latest_turn_observation", "observed_at"], ["latest_turn_observation", "confirmation", "observed_at"], ["queue_observation", "observed_at"]]
    cases = for path <- containers, value <- [nil, "invalid", [], 7], do: {path, value}
    cases = cases ++ for(path <- timestamps, value <- [nil, "not-a-time", 7, []], do: {path, value})

    for {path, value} <- cases do
      File.write!(Path.join(ctx.path, ".observation-shape"), Jason.encode!(%{path: path, value: value}))
      assert {:error, :completed_turn_native_unproven} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request", native_reader: ObservationReader)
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
      assert recovery_events(ctx.store) == []
    end
  end

  test "missing stop, wrong process, changed generation and changed inputs cannot recover", ctx do
    {trace, failed} = failed_attempt(ctx)
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    {:ok, task} = TaskLedger.get(ctx.store, "writer")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    stop = Jason.decode!(failed["owner_stop_json"])

    cases = [
      {"UPDATE worker_evidence SET owner_stop_json=? WHERE request_key='reservation:request'", [nil], [failed["owner_stop_json"]]},
      {"UPDATE worker_evidence SET owner_stop_json=? WHERE request_key='reservation:request'", [Jason.encode!(Map.put(stop, "pid", "99999999"))], [failed["owner_stop_json"]]},
      {"UPDATE worker_evidence SET owner_stop_json=? WHERE request_key='reservation:request'", [Jason.encode!(Map.put(stop, "invocation_nonce", String.duplicate("0", 64)))],
       [failed["owner_stop_json"]]},
      {"UPDATE worker_evidence SET failure_code=? WHERE request_key='reservation:request'", [inspect({:worker_turn_error, "fixture"})], [failed["failure_code"]]},
      {"UPDATE workspace_access SET generation=? WHERE reservation_key='reservation'", [access["generation"] + 1], [access["generation"]]},
      {"UPDATE factory_tasks SET prompt_sha256=? WHERE task_key='writer'", [String.duplicate("0", 64)], [task["prompt_sha256"]]},
      {"UPDATE runs SET candidate_sha=? WHERE run_id='run'", [String.duplicate("0", 40)], [run["candidate_sha"]]},
      {"UPDATE runs SET state=? WHERE run_id='run'", ["VERIFYING"], [run["state"]]},
      {"UPDATE runs SET branch=? WHERE run_id='run'", ["cgable/foreign"], [run["branch"]]}
    ]

    for {sql, changed, original} <- cases do
      Store.query!(ctx.store, sql, changed)
      assert {:error, _} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
      assert recovery_events(ctx.store) == []
      Store.query!(ctx.store, sql, original)
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    end

    assert execution_count(trace) == 1
  end

  test "changed durable state during the native read aborts without result or proof", ctx do
    {trace, failed} = failed_attempt(ctx)
    File.write!(trace <> ".barrier", "wait")
    recovery = Task.async(fn -> TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request") end)
    wait_for_file(trace <> ".ready", 500)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING"})
    File.write!(trace <> ".release", "continue")
    assert {:error, :completed_turn_inputs_changed} = Task.await(recovery, 10_000)
    assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert recovery_events(ctx.store) == []
    assert execution_count(trace) == 1
  end

  defp wait_for_file(path, remaining) when remaining > 0 do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for_file(path, remaining - 1)
        )
  end

  defp wait_for_file(_path, 0), do: flunk("synthetic native read did not reach barrier")

  defp failed_attempt(ctx) do
    {prompt, options} = prepare(ctx)
    trace = configure_server(Map.put(ctx, :deny_read, true))
    assert {:error, {:port_exit, 7}} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)
    {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    File.rm!(trace <> ".deny-read")
    {trace, failed}
  end

  defp output, do: %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => []}
  defp execution_count(trace), do: trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.count(&(&1["method"] == "turn/start"))

  defp recovery_events(store),
    do: Store.query!(store, "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'").rows |> Enum.map(fn [raw] -> Jason.decode!(raw) end)

  defp prepare(ctx) do
    bind_parent(ctx)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    sha = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    candidate = ctx[:candidate_sha] || ctx.sha
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: sha, workspace_sha: candidate})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx, "SOURCE"), "expected_sha", candidate), opts(ctx))

    options = [
      store: ctx.store,
      target_key: "writer",
      request_key: "reservation:request",
      reservation_key: "reservation",
      owner_id: "owned-invocation",
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      review_base_sha: ctx.sha
    ]

    {prompt, options}
  end

  defp configure_server(ctx) do
    trace = Path.join(ctx.root, "completed.trace")
    if ctx[:deny_read], do: File.write!(trace <> ".deny-read", "unavailable")
    if Map.has_key?(ctx, :native_status), do: File.write!(trace <> ".native-status", Jason.encode!(ctx.native_status))
    binary = Path.join(ctx.root, "completed-server")
    server = Path.expand("../support/completed_turn_server.py", __DIR__)
    File.write!(binary, "#!/bin/sh\nexec /usr/bin/python3 -I -S -B '#{server}' '#{trace}'\n")
    File.chmod!(binary, 0o755)

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

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.root, codex_command: "#{binary} app-server", codex_turn_timeout_ms: 5_000, codex_read_timeout_ms: 5_000)
    trace
  end
end
