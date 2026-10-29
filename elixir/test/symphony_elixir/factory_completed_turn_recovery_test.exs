defmodule SymphonyElixir.FactoryCompletedTurnRecoveryTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, Scheduler, StageSchemas, Store, TaskLedger}
  alias SymphonyElixir.Factory.{TicketWorkerRunner, WorkerEvidence, WorkspaceAccess}
  alias SymphonyElixir.Factory.{DesktopRequest, DesktopToolArgs, TicketChat, TicketChatOutbox}
  setup :setup_fixture

  defmodule UntrustedRecoveryReader do
    def read_native_thread(_thread, _opts), do: raise("routed recovery must not call an injected reader")
  end

  @tag :native_worker_recovery
  test "a routed pending result refuses copied proof without genuine observation authority", ctx do
    route = recovery_route(ctx)
    {_trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    observed = %{thread_id: failed["thread_id"], turn_id: failed["turn_id"], item_id: "completed-final", output: output()}
    before = Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
    assert {:error, :completed_turn_receipt_unproven} = WorkerEvidence.reconcile_completed(ctx.store, failed["request_key"], failed["owner_id"], observed, Jason.decode!(failed["owner_stop_json"]))
    assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, failed["request_key"])
    assert Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows == before
  end

  @tag :native_worker_recovery
  @tag :native_notice_scalar
  test "routed completion reads the bound store and committed readback needs neither roots nor another read", ctx do
    for raw <- ["null", "[]", "1", "\"scalar\""] do
      Store.query!(ctx.store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES ('SPECIALIST_ERROR_RECORDED','run',?,?)", [raw, DateTime.to_iso8601(DateTime.utc_now())])
    end

    route = recovery_route(ctx)
    {trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    assert File.regular?(Path.join(route.sqlite_home.path, "completed-state.json"))
    refute File.exists?(trace <> ".state")
    default_state = Path.join(route.sqlite_home.path, "completed-state.json") |> File.read!() |> Jason.decode!()
    default_state = put_in(default_state, ["turns", Access.at(0), "items", Access.at(0), "text"], Jason.encode!(Map.put(output(), "checks", ["wrong-default-store-A"])))
    File.write!(trace <> ".state", Jason.encode!(default_state))
    default_bytes = File.read!(trace <> ".state")
    assert {:ok, observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"], native_reader: UntrustedRecoveryReader)
    assert observed.output == output()
    [proof] = recovery_events(ctx.store)
    assert proof["kind"] == "NATIVE_COMPLETION_RECEIPT_V2"
    assert proof["version"] === 2
    assert proof["native_runtime"] === Jason.decode!(failed["binding_json"])["native_runtime"]
    assert proof["native_runtime_sha256"] == hash_json(proof["native_runtime"])
    requests = File.read!(trace)
    File.rename!(route.codex_home.path, route.codex_home.path <> "-unavailable")
    File.rename!(route.sqlite_home.path, route.sqlite_home.path <> "-unavailable")
    assert {:ok, ^observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    assert File.read!(trace) == requests
    assert length(recovery_events(ctx.store)) == 1
    assert execution_count(trace) == 1
    assert File.read!(trace <> ".state") == default_bytes
  end

  @tag :native_worker_recovery
  test "pending routed recovery refuses unavailable or unsafe roots before any native read", ctx do
    route = recovery_route(ctx)
    {trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    requests = File.read!(trace)
    File.chmod!(route.sqlite_home.path, 0o755)
    assert {:error, :native_runtime_storage_unsafe} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    assert File.read!(trace) == requests
    File.chmod!(route.sqlite_home.path, 0o700)
    File.rename!(route.sqlite_home.path, route.sqlite_home.path <> "-original")
    File.mkdir!(route.sqlite_home.path)
    File.chmod!(route.sqlite_home.path, 0o700)
    assert {:error, :native_runtime_storage_changed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    assert File.read!(trace) == requests
    assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, failed["request_key"])
    assert recovery_events(ctx.store) == []
  end

  @tag :native_worker_recovery
  test "a valid copied V2 receipt cannot replace process-private observation authority", ctx do
    route = recovery_route(ctx)
    {trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    binding = Jason.decode!(failed["binding_json"])
    {:ok, run} = RunLedger.get(ctx.store, failed["run_id"])
    {:ok, task} = TaskLedger.get(ctx.store, failed["task_key"])
    {:ok, access} = WorkspaceAccess.get(ctx.store, failed["reservation_key"])
    stop = Jason.decode!(failed["owner_stop_json"])
    before = %{evidence: failed, binding: binding, run: run, task: task, access: access, stop: stop}
    assert {:ok, observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    [proof] = recovery_events(ctx.store)
    reset_receipt_fixture(ctx.store, failed)
    recovered = Map.take(observed, [:thread_id, :turn_id, :item_id, :output]) |> Map.merge(%{reconciliation_preimage: before, native_recovery: proof})
    assert :ok = SymphonyElixir.Factory.CompletedTurnRecovery.validate_receipt(proof, before, recovered, DateTime.to_iso8601(DateTime.utc_now()))
    events = Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
    requests = File.read!(trace)

    for result <- [recovered, Map.put(recovered, :native_observation_authority, make_ref()), Map.put(recovered, :native_observation_authority, %{"native_runtime" => binding["native_runtime"]})] do
      assert {:error, :completed_turn_receipt_unproven} = WorkerEvidence.reconcile_completed(ctx.store, failed["request_key"], failed["owner_id"], result, stop)
      assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, failed["request_key"])
      assert Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows == events
    end

    refute Enum.any?(Process.get_keys(), &match?({SymphonyElixir.Factory.CompletedTurnRecovery, :observation, _}, &1))
    assert File.read!(trace) == requests
  end

  @tag :native_worker_recovery
  test "committed V2 receipt tampering refuses without replaying native observation", ctx do
    route = recovery_route(ctx)
    {trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    assert {:ok, observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    [proof] = recovery_events(ctx.store)
    [[id, raw, occurred_at]] = Store.query!(ctx.store, "SELECT id,payload_json,occurred_at FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'").rows
    requests = File.read!(trace)
    altered_origin = put_in(proof["native_runtime"], ["sqlite_home", "inode"], proof["native_runtime"]["sqlite_home"]["inode"] + 1)

    changes = [
      Map.put(proof, "version", 2.0),
      Map.put(proof, "version", true),
      Map.put(proof, "kind", "NATIVE_COMPLETION_RECEIPT_V1"),
      Map.put(proof, "native_runtime_sha256", String.duplicate("f", 64)),
      Map.merge(proof, %{"native_runtime" => altered_origin, "native_runtime_sha256" => hash_json(altered_origin)}),
      Map.put(proof, "output_sha256", String.duplicate("f", 64)),
      Map.put(proof, "owner_stop_json", "{}"),
      Map.put(proof, "failure_code", ":turn_timeout"),
      put_in(proof, ["native_observation", "latest", "observed_at"], "2999-01-01T00:00:00Z"),
      Map.delete(proof, "native_runtime"),
      Map.put(proof, "unknown", true)
    ]

    for changed <- Enum.map(changes, &Jason.encode!/1) ++ ["{", "null"] do
      Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE id=?", [changed, id])
      assert {:error, :completed_turn_receipt_unproven} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
      assert File.read!(trace) == requests
    end

    Store.query!(ctx.store, "UPDATE events SET payload_json=?,occurred_at=? WHERE id=?", [raw, "2020-01-01T00:00:00Z", id])
    assert {:error, :completed_turn_receipt_unproven} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    Store.query!(ctx.store, "UPDATE events SET occurred_at=? WHERE id=?", [occurred_at, id])
    Store.query!(ctx.store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES ('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED',?,?,?)", [failed["run_id"], raw, occurred_at])
    assert {:error, :completed_turn_receipt_unproven} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    Store.query!(ctx.store, "DELETE FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED' AND id<>?", [id])
    Process.sleep(11_000)
    assert {:ok, ^observed} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    assert File.read!(trace) == requests
    assert execution_count(trace) == 1
  end

  defp recovery_route(ctx) do
    runtime_root = ctx.root <> "-runtime"
    File.mkdir!(runtime_root)
    on_exit(fn -> File.rm_rf!(runtime_root) end)
    descriptor = %{"version" => 1, "codex_home" => Path.join(runtime_root, "codex"), "sqlite_home" => Path.join(runtime_root, "sqlite")}

    for path <- [descriptor["codex_home"], descriptor["sqlite_home"]] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    {:ok, route} = SymphonyElixir.Factory.NativeRuntimeRoute.validate(descriptor)
    route
  end

  @tag :native_worker_recovery
  test "routed result rollback closes its observation authority and leaves the failed preimage intact", ctx do
    route = recovery_route(ctx)
    {trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    Store.query!(ctx.store, "CREATE TRIGGER reject_routed_result BEFORE UPDATE OF status ON worker_evidence WHEN NEW.status='RESULT_RECORDED' BEGIN SELECT RAISE(ABORT,'routed rollback fixture'); END")
    assert_raise Exqlite.Error, ~r/routed rollback fixture/, fn -> TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"]) end
    assert {:ok, ^failed} = WorkerEvidence.get(ctx.store, failed["request_key"])
    assert recovery_events(ctx.store) == []
    refute Enum.any?(Process.get_keys(), &match?({SymphonyElixir.Factory.CompletedTurnRecovery, :observation, _}, &1))
    Store.query!(ctx.store, "DROP TRIGGER reject_routed_result")
    assert {:ok, _} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    assert length(recovery_events(ctx.store)) == 1
    assert execution_count(trace) == 1
  end

  defp hash_json(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  @tag :notice_metadata_regression
  test "reopened completed result reaches its original parent once with the recorded error notice", ctx do
    {trace, failed} = failed_attempt(ctx)
    assert WorkerEvidence.owner_stopped?(ctx.store, failed)
    assert {:ok, original_parent} = TicketChat.for_run(ctx.store, "run")
    reopened = start_supervised!({Store, database: ctx.database}, id: :notice_recovery_reopen)

    assert {:ok, recovered} = TicketWorkerRunner.reconcile_completed(reopened, "reservation:request")
    assert recovered.output == output()
    assert recovered.owner_stop == Jason.decode!(failed["owner_stop_json"])
    assert {:ok, _task} = WorkerEvidence.adopt_completed(reopened, "reservation:request")
    assert {:ok, %{request_key: key, status: "PENDING"}} = TicketChatOutbox.publish(reopened, "run")
    assert {:ok, request} = DesktopRequest.get(reopened, key)
    assert request["existing_thread_id"] == original_parent["thread_id"]
    assert Map.has_key?(Jason.decode!(request["metadata_json"]), "specialist_notice_ids")
    assert DesktopRequest.payload_intact?(request)
    assert :ok = TicketChat.validate_request(reopened, request)
    assert {:ok, arguments} = DesktopToolArgs.followup(request)
    assert arguments["threadId"] == original_parent["thread_id"]

    native_requests = File.read!(trace)
    assert {:ok, ^recovered} = TicketWorkerRunner.reconcile_completed(reopened, "reservation:request")

    for _ <- 1..2 do
      assert {:ok, %{status: "SYNC_LAG", request_key: ^key, model_invoked: false}} = TicketChatOutbox.publish(reopened, "run")
      assert {:ok, ^request} = DesktopRequest.get(reopened, key)
    end

    assert File.read!(trace) == native_requests
    assert execution_count(trace) == 1
    assert length(recovery_events(reopened)) == 1
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM events WHERE event_type='SPECIALIST_ERROR_QUEUED'")["count"] == 1
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind='TICKET_CHAT' AND action='FOLLOWUP'")["count"] == 1
    assert {:ok, final} = WorkerEvidence.get(reopened, "reservation:request")
    assert final["owner_stop_json"] == failed["owner_stop_json"]
    assert final["owner_stopped_at"] == failed["owner_stopped_at"]
    assert final["output_json"] == Jason.encode!(output())
  end

  @tag :native_worker_recovery
  test "reopened V2 completion is read back before adoption and reaches its original master exactly once", ctx do
    route = recovery_route(ctx)
    {trace, failed} = failed_attempt(Map.put(ctx, :native_runtime, route))
    assert {:ok, parent} = TicketChat.for_run(ctx.store, "run")
    assert {:ok, recovered} = TicketWorkerRunner.reconcile_completed(ctx.store, failed["request_key"])
    requests = File.read!(trace)
    [proof] = recovery_events(ctx.store)
    assert proof["kind"] == "NATIVE_COMPLETION_RECEIPT_V2"
    File.rename!(route.codex_home.path, route.codex_home.path <> "-retained")
    File.rename!(route.sqlite_home.path, route.sqlite_home.path <> "-retained")
    reopened = start_supervised!({Store, database: ctx.database}, id: :routed_recovery_reopen)
    Process.sleep(1100)
    assert {:ok, ^recovered} = TicketWorkerRunner.reconcile_completed(reopened, failed["request_key"])
    assert recovery_events(reopened) == [proof]
    assert File.read!(trace) == requests
    assert {:ok, task} = WorkerEvidence.adopt_completed(reopened, failed["request_key"])
    assert {:ok, ^task} = WorkerEvidence.adopt_completed(reopened, failed["request_key"])
    assert {:ok, %{request_key: key, status: "PENDING"}} = TicketChatOutbox.publish(reopened, "run")
    assert {:ok, request} = DesktopRequest.get(reopened, key)
    assert request["existing_thread_id"] == parent["thread_id"]
    assert DesktopRequest.payload_intact?(request)
    assert :ok = TicketChat.validate_request(reopened, request)
    assert {:ok, arguments} = DesktopToolArgs.followup(request)
    assert arguments["threadId"] == parent["thread_id"]

    for _ <- 1..2 do
      assert {:ok, %{status: "SYNC_LAG", request_key: ^key, model_invoked: false}} = TicketChatOutbox.publish(reopened, "run")
      assert {:ok, ^request} = DesktopRequest.get(reopened, key)
    end

    assert Store.one!(reopened, "SELECT COUNT(*) AS n FROM desktop_requests WHERE target_kind='TICKET_CHAT' AND action='FOLLOWUP'")["n"] == 1
    assert Store.one!(reopened, "SELECT COUNT(*) AS n FROM events WHERE event_type='SPECIALIST_ERROR_QUEUED'")["n"] == 1
    assert recovery_events(reopened) == [proof]
    assert File.read!(trace) == requests
    assert execution_count(trace) == 1
    assert {:ok, final} = WorkerEvidence.get(reopened, failed["request_key"])
    assert final["owner_stop_json"] == failed["owner_stop_json"]
    assert final["output_json"] == Jason.encode!(output())
  end

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

  @tag :native_worker_recovery
  test "committed legacy recovery refuses a V2 receipt without another native read or stop rewrite", ctx do
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
    [proof] = events
    route = recovery_route(ctx)
    assert {:ok, origin} = SymphonyElixir.Factory.NativeRuntimeRoute.origin(route)
    v2 = Map.merge(proof, %{"kind" => "NATIVE_COMPLETION_RECEIPT_V2", "version" => 2, "native_runtime" => origin, "native_runtime_sha256" => hash_json(origin)})
    Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'", [Jason.encode!(v2)])
    altered = Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
    assert {:error, :completed_turn_receipt_unproven} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    assert {:ok, ^recorded} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows == altered
    assert File.read!(trace) == requests
    Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'", [Jason.encode!(proof)])
    assert {:ok, ^observed} = TicketWorkerRunner.reconcile_completed(ctx.store, "reservation:request")
    assert recovery_events(ctx.store) == events
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
    alias SymphonyElixir.Codex.AppServer

    def read_native_thread(thread, opts) do
      with {:ok, observed} <- AppServer.read_native_thread(thread, opts),
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

    options = if ctx[:native_runtime], do: Keyword.put(options, :native_runtime, ctx.native_runtime), else: options
    {prompt, options}
  end

  defp configure_server(ctx) do
    trace = Path.join(ctx.root, "completed.trace")
    if ctx[:deny_read], do: File.write!(trace <> ".deny-read", "unavailable")
    if Map.has_key?(ctx, :native_status), do: File.write!(trace <> ".native-status", Jason.encode!(ctx.native_status))
    binary = Path.join(ctx.root, "completed-server")
    server = Path.expand("../support/completed_turn_server.py", __DIR__)
    File.write!(binary, "#!/bin/sh\nexec /usr/bin/python3 -I -S -B '#{server}' '#{trace}' \"$@\"\n")
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
