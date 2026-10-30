defmodule SymphonyElixir.FactoryFailedTurnRecoveryTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketWorkerFixture
  alias __MODULE__.{QueueReader, RetryServer}

  alias SymphonyElixir.Factory.{
    FailedTurnRecovery,
    NativeQueueReadback,
    RunLedger,
    Scheduler,
    StageSchemas,
    Store,
    TaskLauncher,
    TaskLedger,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerFileTools,
    WorkspaceAccess
  }

  setup :setup_fixture

  @tag :native_worker_binding
  test "failed retry inherits the recorded history origin and refuses a changed origin before transfer", ctx do
    descriptor = %{"version" => 1, "codex_home" => Path.join(ctx.root, "failed-codex"), "sqlite_home" => Path.join(ctx.root, "failed-sqlite")}

    for path <- [descriptor["codex_home"], descriptor["sqlite_home"]] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    {:ok, route} = SymphonyElixir.Factory.NativeRuntimeRoute.validate(descriptor)
    {old, _, options} = failed(Map.put(ctx, :native_runtime, route))
    original = Jason.decode!(old["binding_json"])
    assert {:ok, proof} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", Keyword.delete(options, :native_history))
    assert {:ok, successor} = WorkerEvidence.get(ctx.store, proof["new_request_key"])
    binding = Jason.decode!(successor["binding_json"])
    assert binding["binding_version"] === 2
    assert binding["native_runtime"] === original["native_runtime"]
    assert FailedTurnRecovery.superseded?(ctx.store, old)
    assert :ok = FailedTurnRecovery.start_preflight(ctx.store, proof, Keyword.delete(options, :native_history))
    File.rename!(route.sqlite_home.path, route.sqlite_home.path <> "-original")
    File.mkdir!(route.sqlite_home.path)
    File.chmod!(route.sqlite_home.path, 0o700)
    assert {:error, _} = FailedTurnRecovery.start_preflight(ctx.store, proof, Keyword.delete(options, :native_history))
    assert FailedTurnRecovery.superseded?(ctx.store, old)
    assert {:ok, ^successor} = WorkerEvidence.get(ctx.store, proof["new_request_key"])
  end

  test "preflight diagnostics identify only the failed guard without exposing proof or changing state", ctx do
    {old, _, options} = failed(ctx)
    {:ok, proof} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    assert ExUnit.CaptureLog.capture_log(fn -> assert :ok = FailedTurnRecovery.start_preflight(ctx.store, proof, options) end) == ""
    secret = "sensitive-proof-sentinel"
    invalid = Map.put(proof, "unexpected", secret)
    before = Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY created_at").rows
    log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight_observed(ctx.store, invalid, options) end)
    assert log =~ "guard=applied_receipt"
    assert log =~ "reason=predicate_false"
    refute log =~ secret
    refute log =~ ctx.path
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY created_at").rows == before
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_file_operations")["n"] == 0
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: String.duplicate("b", 64)})
    log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight_observed(ctx.store, proof, options) end)
    assert log =~ "guard=task_binding"
    refute log =~ String.duplicate("b", 64)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: proof["new_prompt_sha256"]})
    missing = Path.join(ctx.root, "sensitive-missing-history.sqlite")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight_observed(ctx.store, proof, Keyword.put(options, :native_history, missing))
      end)

    assert log =~ "guard=native_terminal"
    assert log =~ "reason=failed_retry_native_turn_unproven"
    refute log =~ missing
  end

  test "an explicitly recovered closed-connection exception preserves partial edits and the old failure", ctx do
    {old, _, options} = interrupted(ctx, true)
    reason = {:worker_exception, :error, inspect(%DBConnection.ConnectionError{message: "connection is closed because of an error, disconnect or timeout", severity: :error, reason: :error})}
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, old["request_key"], reason)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{failure_code: inspect(reason)})
    {:ok, original} = WorkerEvidence.get(ctx.store, old["request_key"])

    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    assert proof["kind"] == "INTERRUPTED_TURN_QUIESCENCE"
    assert proof["quiescence_is_owned_stop"] == false
    assert {:ok, ^original} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial\n"
    assert :ok = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
    assert {:ok, ^proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
  end

  test "initial interrupted writers recover without inventing a candidate commit", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil, implementation_iteration: 0})
    {old, _, options} = interrupted(ctx, true)
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    assert proof["run"]["candidate_sha"] == nil
    assert :ok = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
  end

  test "a missing candidate after implementation has begun cannot authorize recovery", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil, implementation_iteration: 1})
    {old, _, options} = interrupted(ctx)
    assert {:error, :failed_retry_head_changed} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
  end

  test "other database exceptions and mismatched failure reports cannot authorize recovery", ctx do
    {old, _, options} = interrupted(ctx)
    closed = {:worker_exception, :error, inspect(%DBConnection.ConnectionError{message: "connection is closed because of an error, disconnect or timeout", severity: :error, reason: :error})}
    other = {:worker_exception, :error, inspect(%DBConnection.ConnectionError{message: "connection not available", severity: :error, reason: :error})}
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, old["request_key"], other)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{failure_code: inspect(other)})
    assert {:error, :failed_retry_not_eligible} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, old["request_key"], closed)
    assert {:error, :failed_retry_not_eligible} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{failure_code: inspect(closed)})
    assert {:error, _} = FailedTurnRecovery.prepare_automatic(ctx.store, old["request_key"], "failed-turn", Keyword.delete(options, :manual_interrupted))
  end

  test "persisted queue revision detects even an enqueue-delete roundtrip before start", ctx do
    {old, _, options} = interrupted(ctx)
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {_, 0} = System.cmd("sqlite3", [options[:native_queue_database], "INSERT INTO queued_items VALUES('one','worker','{}',1,1,1); DELETE FROM queued_items;"])
    assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
  end

  test "a genuine exclusive native writer lock rejects recovery without changing ownership", ctx do
    {old, _, options} = interrupted(ctx)
    lock = Path.join([options[:native_home], "thread-writer-locks", "worker.lock"])
    script = "import os,sys,fcntl; fd=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(fd,fcntl.LOCK_EX); print('held',flush=True); sys.stdin.read(); os.close(fd)"
    port = Port.open({:spawn_executable, System.find_executable("python3")}, [:binary, :exit_status, args: ["-c", script, lock]])

    try do
      assert_receive {^port, {:data, "held\n"}}, 5000
      assert {:error, :interrupted_native_writer_lock_unproven} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
      assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 1
      assert File.read!(lock) == ""
    after
      Port.close(port)
    end
  end

  test "native shutdown may remove its lock but anchored absence remains exact quiescence", ctx do
    {old, _, options} = interrupted(ctx)
    lock = Path.join([options[:native_home], "thread-writer-locks", "worker.lock"])
    File.rm!(lock)
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    assert proof["native_queue"]["writer_lock"]["status"] == "absent"
    assert proof["quiescence_is_owned_stop"] == false
    refute File.exists?(lock)
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert :ok = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
    File.write!(lock, "")
    assert {:error, _} = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
  end

  test "missing or changed native lock parent and symlink or nonregular paths remain denied", ctx do
    {old, _, options} = interrupted(ctx)
    home = options[:native_home]
    parent = Path.join(home, "thread-writer-locks")
    lock = Path.join(parent, "worker.lock")
    File.rm!(lock)
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    File.rename!(parent, parent <> ".original")
    assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(home, "worker")
    File.mkdir!(parent)
    assert {:error, _} = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
    File.rmdir!(parent)
    File.ln_s!(parent <> ".original", parent)
    assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(home, "worker")
    File.rm!(parent)
    File.rename!(parent <> ".original", parent)
    File.ln_s!(Path.join(ctx.root, "missing"), lock)
    assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(home, "worker")
    File.rm!(lock)
    File.mkdir!(lock)
    assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(home, "worker")
    File.rmdir!(lock)
    {_, 0} = System.cmd("/usr/bin/mkfifo", [lock])
    assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(home, "worker")
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
  end

  test "permission failures are not mistaken for an absent native lock", ctx do
    {_, _, options} = interrupted(ctx)
    parent = Path.join(options[:native_home], "thread-writer-locks")
    lock = Path.join(parent, "worker.lock")
    File.chmod!(lock, 0o000)

    try do
      assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(options[:native_home], "worker")
    after
      File.chmod!(lock, 0o600)
    end

    File.chmod!(parent, 0o000)

    try do
      assert {:error, :interrupted_native_writer_lock_unproven} = NativeQueueReadback.writer_unlocked(options[:native_home], "worker")
    after
      File.chmod!(parent, 0o700)
    end
  end

  test "missing persisted queue or revision triggers rejects interruption proof", ctx do
    {old, _, options} = interrupted(ctx)
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", Keyword.put(options, :native_queue_database, Path.join(ctx.root, "missing.sqlite")))
    {_, 0} = System.cmd("sqlite3", [options[:native_queue_database], "DROP TRIGGER queued_items_revision_after_delete;"])
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 1
  end

  test "owned prestart rejects late native finals, active actors and changed persisted inputs before IO", ctx do
    {old, _, options} = interrupted(ctx, true)
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {:ok, current} = WorkerEvidence.get(ctx.store, proof["new_request_key"])
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, current["request_key"])
    policy = Jason.decode!(current["binding_json"])["policy"]
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, current["request_key"], "worker", policy)
    nonce = String.duplicate("c", 64)
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, current["request_key"], %{"pid" => "99999999", "invocation_nonce" => nonce})
    session = %{thread_id: "worker", workspace: ctx.path, metadata: %{codex_app_server_pid: "99999999"}, worker_invocation: nonce}
    options = Keyword.put(options, :app_server, RetryServer)
    Process.sleep(11_000)
    assert :ok = FailedTurnRecovery.owned_session_preflight(ctx.store, proof, session, options)

    Process.put(:queue_turn_transform, fn response -> update_in(response, ["data", Access.at(0), "items"], &(&1 ++ [%{"id" => "late", "type" => "agentMessage", "phase" => "final"}])) end)
    assert {:error, :interrupted_owned_session_preflight_failed} = FailedTurnRecovery.owned_session_preflight(ctx.store, proof, session, options)
    Process.delete(:queue_turn_transform)
    Process.put(:queue_read_transform, &put_in(&1, ["status", "type"], "active"))
    assert {:error, :interrupted_owned_session_preflight_failed} = FailedTurnRecovery.owned_session_preflight(ctx.store, proof, session, options)
    Process.delete(:queue_read_transform)
    {_, 0} = System.cmd("sqlite3", [options[:native_queue_database], "INSERT INTO queued_items VALUES('one','worker','{}',1,1,1); DELETE FROM queued_items;"])
    assert {:error, :interrupted_owned_session_preflight_failed} = FailedTurnRecovery.owned_session_preflight(ctx.store, proof, session, options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_file_operations WHERE request_key=?", [current["request_key"]])["n"] == 0
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial\n"
  end

  defp failed(ctx, edit \\ false) do
    task_key = Map.get(ctx, :writer_key, "writer")
    bind_parent(ctx)
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, packet} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    hash = :crypto.hash(:sha256, packet) |> Base.encode16(case: :lower)
    {:ok, _} = TaskLedger.update(ctx.store, task_key, %{stage: "WRITING", prompt_sha256: hash})
    {:ok, access} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx), "task_key", task_key), opts(ctx))
    {:ok, task} = TaskLedger.get(ctx.store, task_key)

    attributes = %{
      "request_key" => "reservation:request",
      "task_key" => task_key,
      "reservation_key" => "reservation",
      "input_sha256" => task["prompt_sha256"],
      "owner_id" => "owned",
      "schema" => StageSchemas.for_stage(:native_feature_writer),
      "policy" => TicketWorkerRunner.policy("SOURCE", ctx.path)
    }

    attributes = if ctx[:native_runtime], do: Map.put(attributes, "native_runtime", ctx.native_runtime), else: attributes
    {:ok, evidence} = WorkerEvidence.reserve(ctx.store, attributes)

    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, evidence["request_key"])
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "worker", Jason.decode!(evidence["binding_json"])["policy"])
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, evidence["request_key"], %{"pid" => "99999999", "invocation_nonce" => String.duplicate("a", 64)})
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "worker", "failed-turn")

    if edit do
      {:ok, cap} = WorkerFileTools.bind(ctx.store, evidence["request_key"], "owned")

      for {before, after_bytes, call} <- [{"base\n", "first\n", "one"}, {"first\n", "partial\n", "two"}] do
        sha = :crypto.hash(:sha256, before) |> Base.encode16(case: :lower)
        identity = %{"threadId" => "worker", "turnId" => "failed-turn", "callId" => call, "tool" => "repo_write"}
        result = WorkerFileTools.execute(cap, "repo_write", %{"path" => "fixture.txt", "expected_sha256" => sha, "content" => after_bytes}, identity)
        assert result["success"] == true
      end
    end

    error = %{"codexErrorInfo" => "serverOverloaded", "message" => "Selected model is at capacity. Please try a different model.", "additionalDetails" => nil, "misalignment" => nil}
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, evidence["request_key"], {:worker_turn_error, error})
    {:ok, _} = TaskLedger.update(ctx.store, task_key, %{status: "STALE", thread_id: "worker", turn_id: "prior-turn", failure_code: inspect({:worker_turn_error, error})})
    history = if ctx[:native_runtime], do: Path.join(ctx.native_runtime.sqlite_home.path, "thread_history_1.sqlite"), else: Path.join(ctx.root, "history.sqlite")

    {_, 0} =
      System.cmd("sqlite3", [
        history,
        "CREATE TABLE thread_turns(thread_id,turn_id,rollout_ordinal,status,error_json,completed_at,final_agent_item_id); INSERT INTO thread_turns VALUES('worker','failed-turn',1,'failed','#{Jason.encode!(error)}',1,NULL);"
      ])

    {:ok, original} = WorkerEvidence.get(ctx.store, evidence["request_key"])
    {original, access, Keyword.put(opts(ctx), :native_history, history)}
  end

  test "two proven partial writes on one path survive transfer and start preflight", ctx do
    {old, _access, options} = failed(ctx, true)
    operations = Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows
    assert {:ok, receipt} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    assert length(receipt["files"]) == 1
    assert :ok = FailedTurnRecovery.start_preflight(ctx.store, receipt, options)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial\n"
    assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == operations
    File.write!(Path.join(ctx.path, "fixture.txt"), "changed\n")
    assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight(ctx.store, receipt, options)
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
  end

  defp interrupted(ctx, edit \\ false) do
    {old, access, options} = failed(ctx, edit)
    closed = "connection is closed because of an error, disconnect or timeout"
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, old["request_key"], closed)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{failure_code: inspect(:worker_observation_failed)})
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "UPDATE thread_turns SET status='interrupted', error_json=NULL WHERE turn_id='failed-turn';"])
    {:ok, old} = WorkerEvidence.get(ctx.store, old["request_key"])
    {:ok, packet} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    File.write!(options[:native_history] <> ".input", packet)
    File.write!(options[:native_history] <> ".cwd", ctx.path)
    queue_database = Path.join(ctx.root, "queue.sqlite")

    schema =
      "CREATE TABLE queued_items (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL, queue_order INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL); CREATE TABLE queued_thread_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL UNIQUE);"

    triggers =
      Enum.map_join([{"insert", "NEW"}, {"update", "NEW"}, {"delete", "OLD"}], fn {event, row} ->
        "CREATE TRIGGER queued_items_revision_after_#{event} AFTER #{String.upcase(event)} ON queued_items BEGIN INSERT INTO queued_thread_revisions (thread_id) VALUES (#{row}.thread_id) ON CONFLICT(thread_id) DO UPDATE SET revision = (SELECT COALESCE(MAX(revision),0)+1 FROM queued_thread_revisions); END;"
      end)

    {_, 0} = System.cmd("sqlite3", [queue_database, schema <> triggers])
    native_home = Path.join(ctx.root, "native-home")
    File.mkdir_p!(Path.join(native_home, "thread-writer-locks"))
    File.write!(Path.join([native_home, "thread-writer-locks", "worker.lock"]), "")

    {old, access,
     options |> Keyword.put(:manual_interrupted, true) |> Keyword.put(:native_reader, QueueReader) |> Keyword.put(:native_queue_database, queue_database) |> Keyword.put(:native_home, native_home)}
  end

  defmodule QueueReader do
    def read_native_thread(thread, options) do
      if probe = Process.get(:queue_read_probe), do: probe.()
      history = options[:native_history]
      {raw, 0} = System.cmd("sqlite3", ["-readonly", "-json", history, "SELECT turn_id,status,error_json FROM thread_turns ORDER BY rollout_ordinal DESC LIMIT 1;"])
      [turn] = Jason.decode!(raw)
      items = [%{"id" => "original", "type" => "userMessage", "content" => [%{"type" => "text", "text" => File.read!(history <> ".input")}]}]
      response = %{"data" => [%{"id" => turn["turn_id"], "status" => turn["status"], "error" => Jason.decode!(turn["error_json"] || "null"), "items" => items}], "nextCursor" => nil}
      response = if transform = Process.get(:queue_turn_transform), do: transform.(response), else: response
      empty = %{"data" => [], "nextCursor" => nil}
      at = DateTime.to_iso8601(DateTime.utc_now())

      latest = %{
        "mode" => "LATEST_DESC",
        "parameters" => %{"threadId" => thread, "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
        "raw_response" => response,
        "sha256" => digest(response),
        "updated_at" => 1,
        "observed_at" => at,
        "confirmation" => %{"raw_response" => response, "sha256" => digest(response), "observed_at" => at}
      }

      queue = %{"thread_id" => thread, "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false, "raw_response" => empty, "sha256" => digest(empty), "observed_at" => at}
      native = %{"id" => thread, "cwd" => File.read!(history <> ".cwd"), "status" => %{"type" => "idle"}, "updatedAt" => 1, "latest_turn_observation" => latest, "queue_observation" => queue}
      {:ok, if(transform = Process.get(:queue_read_transform), do: transform.(native), else: native)}
    end

    defp digest(raw), do: :crypto.hash(:sha256, Jason.encode!(raw)) |> Base.encode16(case: :lower)
  end

  test "interrupted native queues, stale versions, extra user inputs and missing readbacks deny recovery", ctx do
    {old, _, options} = interrupted(ctx)

    transforms = [
      &put_in(&1, ["queue_observation", "empty_complete"], false),
      &put_in(&1, ["queue_observation", "raw_response", "data"], [%{"id" => "queued"}]),
      &put_in(&1, ["latest_turn_observation", "updated_at"], 0),
      &put_in(&1, ["latest_turn_observation", "confirmation", "sha256"], "changed"),
      &put_in(&1, ["queue_observation", "observed_at"], "2000-01-01T00:00:00Z"),
      &Map.delete(&1, "latest_turn_observation")
    ]

    for transform <- transforms do
      Process.put(:queue_read_transform, transform)
      assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
      assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    end

    Process.delete(:queue_read_transform)

    for phase <- [nil, "final", "unknown"] do
      Process.put(:queue_turn_transform, fn raw ->
        update_in(raw, ["data", Access.at(0), "items"], &(&1 ++ [%{"id" => "late-final", "type" => "agentMessage", "phase" => phase}]))
      end)

      assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    end

    Process.put(:queue_turn_transform, fn raw ->
      update_in(raw, ["data", Access.at(0), "items"], &(&1 ++ [%{"id" => "human-queued", "type" => "userMessage", "content" => [%{"type" => "text", "text" => "new input"}]}]))
    end)

    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    Process.delete(:queue_turn_transform)
    File.write!(options[:native_history] <> ".input", "a different human input")
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 1
  end

  test "administrative native queue read holds no database checkout and idle is guarded at transfer", ctx do
    {old, _, options} = interrupted(ctx)

    factory = %{
      enabled: true,
      database: ctx.database,
      scope: "recovery-idle",
      dispatcher_id: "dispatcher",
      lease_seconds: 240,
      repositories: options[:capacity_policy]["repositories"],
      cleanup: %{},
      writer_disk_gb: 20,
      maximum_writers: 2,
      maximum_specifiers: 2,
      maximum_validators: 2
    }

    SymphonyElixir.Factory.Control.initialize(ctx.store, factory)

    Process.put(:queue_read_probe, fn -> Store.query!(ctx.store, "UPDATE control SET tick_id='active' WHERE scope='recovery-idle'") end)
    assert {:error, :live_tick_lease} = SymphonyElixir.Factory.Admin.recover_interrupted_writer(factory, old["request_key"], "failed-turn", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 1

    Process.put(:queue_read_probe, fn ->
      write = Task.async(fn -> Store.query!(ctx.store, "UPDATE control SET tick_id=NULL WHERE scope='recovery-idle'") end)
      assert {:ok, _} = Task.yield(write, 1000)
    end)

    assert {:ok, proof} = SymphonyElixir.Factory.Admin.recover_interrupted_writer(factory, old["request_key"], "failed-turn", options)
    assert proof["kind"] == "INTERRUPTED_TURN_QUIESCENCE"
    Store.query!(ctx.store, "UPDATE control SET tick_id='active' WHERE scope='recovery-idle'")
    assert {:error, :live_tick_lease} = SymphonyElixir.Factory.Admin.recover_interrupted_writer(factory, old["request_key"], "failed-turn", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 2
  end

  test "exact interrupted connection-loss recovery is explicit quiescence, not an owned stop", ctx do
    {old, access, options} = interrupted(ctx, true)
    assert {:error, _} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", Keyword.delete(options, :manual_interrupted))
    assert {:error, _} = FailedTurnRecovery.prepare_automatic(ctx.store, old["request_key"], "failed-turn", Keyword.delete(options, :manual_interrupted))
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", Keyword.delete(options, :manual_interrupted))
    assert proof["kind"] == "INTERRUPTED_TURN_QUIESCENCE"
    assert proof["native"]["status"] == "interrupted"
    assert proof["old_task_failure_code"] == inspect(:worker_observation_failed)
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    refute WorkerEvidence.owner_stopped?(ctx.store, old)
    assert {:ok, next} = WorkerEvidence.get(ctx.store, proof["new_request_key"])
    assert next["thread_id"] == nil and next["status"] == "RESERVED"
    assert {:ok, current} = WorkspaceAccess.get(ctx.store, next["reservation_key"])
    assert current["generation"] > access["generation"]
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial\n"
    assert :ok = FailedTurnRecovery.start_preflight(ctx.store, proof, Keyword.delete(options, :manual_interrupted))
  end

  test "interrupted terminal recovery rejects completion, unbound errors, newer turns and active owners", ctx do
    {old, _, options} = interrupted(ctx)

    probes = [
      {"status='inProgress',completed_at=NULL", "status='interrupted',completed_at=1"},
      {"status='completed',final_agent_item_id='final'", "status='interrupted',final_agent_item_id=NULL"},
      {"error_json='{}'", "error_json=NULL"},
      {"completed_at=NULL", "completed_at=1"}
    ]

    for {invalid, restore} <- probes do
      {_, 0} = System.cmd("sqlite3", [options[:native_history], "UPDATE thread_turns SET #{invalid};"])
      assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
      assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
      {_, 0} = System.cmd("sqlite3", [options[:native_history], "UPDATE thread_turns SET #{restore};"])
    end

    {_, 0} = System.cmd("sqlite3", [options[:native_history], "INSERT INTO thread_turns VALUES('worker','newer',2,'interrupted',NULL,2,NULL);"])
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "DELETE FROM thread_turns WHERE turn_id='newer';"])
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{failure_code: inspect(:different_failure)})
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{failure_code: inspect(:worker_observation_failed)})
    File.write!(Path.join(ctx.path, "fixture.txt"), "not journaled\n")
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    File.write!(Path.join(ctx.path, "fixture.txt"), "base\n")
    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status, cd: String.to_charlist(ctx.path)])

    try do
      assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    after
      Port.close(port)
    end

    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 1
  end

  test "interrupted retry replay survives reopening but a second interruption is not rearmed", ctx do
    {old, _, options} = interrupted(ctx)
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^proof} = FailedTurnRecovery.prepare_interrupted(reopened, old["request_key"], "failed-turn", options)
      assert :ok = FailedTurnRecovery.start_preflight(reopened, proof, Keyword.delete(options, :manual_interrupted))
    after
      GenServer.stop(reopened)
    end

    {:ok, next} = WorkerEvidence.get(ctx.store, proof["new_request_key"])
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, next["request_key"])
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, next["request_key"], "worker", Jason.decode!(next["binding_json"])["policy"])
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, next["request_key"], Jason.decode!(old["owner_process_json"]))
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, next["request_key"], "worker", "again")
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, next["request_key"], "connection is closed because of an error, disconnect or timeout")
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STALE", failure_code: inspect(:worker_observation_failed)})
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "INSERT INTO thread_turns VALUES('worker','again',2,'interrupted',NULL,2,NULL);"])
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, next["request_key"], "again", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 2
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
  end

  test "interrupted start rechecks native completion and refuses a changed committed HEAD", ctx do
    {old, _, options} = interrupted(ctx)
    {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "UPDATE thread_turns SET status='completed',final_agent_item_id='late-final';"])
    assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "UPDATE thread_turns SET status='interrupted',final_agent_item_id=NULL;"])
    File.write!(Path.join(ctx.path, "fixture.txt"), "committed elsewhere\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "unrelated completion"])
    assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight(ctx.store, proof, options)
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() != ctx.sha
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
  end

  test "interrupted recovery accepts genuine bound stop but rejects incomplete and tampered receipts", ctx do
    {old, _, options} = interrupted(ctx)
    old = stopped(ctx, old)
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json=NULL WHERE request_key=?", [old["request_key"]])
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    receipt = Jason.decode!(old["owner_stop_json"]) |> Map.put("invocation_nonce", String.duplicate("b", 64)) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json=? WHERE request_key=?", [receipt, old["request_key"]])
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json=? WHERE request_key=?", [old["owner_stop_json"], old["request_key"]])
    assert {:ok, proof} = FailedTurnRecovery.prepare_interrupted(ctx.store, old["request_key"], "failed-turn", options)
    assert proof["quiescence_is_owned_stop"] == false
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert WorkerEvidence.owner_stopped?(ctx.store, old)
  end

  defmodule RetryServer do
    def start_session(workspace, opts) do
      {:ok, session} = SymphonyElixir.DesktopTicketLifecycleFixture.WorkerServer.start_session(workspace, opts)
      {:ok, Map.merge(session, %{native_recovery: opts[:native_recovery], recovery_preflight: opts[:recovery_preflight]})}
    end

    def run_turn(session, prompt, issue, opts) do
      with :ok <- guarded(session) do
        SymphonyElixir.DesktopTicketLifecycleFixture.WorkerServer.run_turn(session, Jason.encode!(Jason.decode!(prompt)["base_packet"]), issue, opts)
      end
    end

    defp guarded(%{native_recovery: proof, recovery_preflight: callback} = session) when is_map(proof), do: callback.(session)
    defp guarded(_), do: :ok

    def read_owned_native_thread(session) do
      history = Path.join(Path.dirname(Path.dirname(session.workspace)), "history.sqlite")
      QueueReader.read_native_thread(session.thread_id, native_history: history)
    end

    def stop_session(session), do: SymphonyElixir.DesktopTicketLifecycleFixture.WorkerServer.stop_session(session)
  end

  defmodule ConnectionLossServer do
    alias SymphonyElixir.DesktopTicketLifecycleFixture.WorkerServer
    alias SymphonyElixir.Factory.{Store, Worktree}
    def start_session(workspace, options), do: WorkerServer.start_session(workspace, options)
    def stop_session(session), do: WorkerServer.stop_session(session)

    def run_turn(session, _prompt, _issue, options) do
      options[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: "db-lost-turn"})
      probe = Process.get(:connection_loss_probe)

      Exqlite.transaction(
        probe.store,
        fn tx ->
          Store.query!(tx, "SELECT 1")
          Process.sleep(50)
          {:ok, _} = Worktree.validate_native(%{"path" => probe.repo}, probe.path, detached: false)
          Store.query!(tx, "SELECT 1")
        end,
        timeout: 10
      )
    end
  end

  test "real checkout expiry across filesystem validation retains a bound failed stop without inventing output", ctx do
    bind_parent(ctx)
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    digest = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING", prompt_sha256: digest})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    Process.put(:connection_loss_probe, ctx)

    options = [
      store: ctx.store,
      target_key: "writer",
      request_key: "reservation:request",
      reservation_key: "reservation",
      owner_id: "owned",
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      app_server: ConnectionLossServer,
      review_base_sha: ctx.sha
    ]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:worker_exception, :error, reason}} =
                 TicketWorkerRunner.run(ctx.path, %SymphonyElixir.Tracker.Issue{identifier: "PPL-123"}, prompt, StageSchemas.for_stage(:native_feature_writer), options)

        assert reason =~ "connection is closed because of an error, disconnect or timeout"
      end)

    assert log =~ "client"
    {:ok, evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert evidence["status"] == "RECONCILE_REQUIRED" and evidence["turn_id"] == "db-lost-turn"
    assert is_nil(evidence["output_json"]) and is_nil(evidence["item_id"])
    assert WorkerEvidence.owner_stopped?(ctx.store, evidence)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:error, _} = FailedTurnRecovery.prepare_interrupted(ctx.store, evidence["request_key"], "db-lost-turn", opts(ctx))
  end

  defmodule RecoveryJiraReader do
    def issue(_key, options) do
      {:ok, run} = RunLedger.get(options[:store], "run")
      {:ok, Map.merge(Jason.decode!(run["snapshot_json"]), %{"status" => "In Dev", "labels" => ["ai-running"]})}
    end
  end

  test "scheduler prepares an exact failed attempt and its next ordinary step launches it", ctx do
    Store.query!(ctx.store, "UPDATE factory_tasks SET task_key='run:feature-writer' WHERE task_key='writer'")
    ctx = Map.put(ctx, :writer_key, "run:feature-writer")
    {old, _, options} = failed(ctx, true)
    old = stopped(ctx, old)
    supervisor = start_supervised!(Task.Supervisor)

    models = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"fast" => "gpt-6-luna"}},
      "roles" => %{"feature-writer" => %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "medium"}}
    }

    context = %{
      store: ctx.store,
      workspace_root: Path.join(ctx.root, "workspaces"),
      task_supervisor: supervisor,
      recipient: self(),
      ticket_options: [],
      factory: %{scope: "scope", models: models, maximum_implementation_iterations: 20}
    }

    options = Keyword.merge(options, app_server: RetryServer, jira_reader: RecoveryJiraReader, now: DateTime.from_unix!(301))
    assert {:ok, %{status: "RECOVERY_PREPARED"}} = Scheduler.ticket_step(context, "run", options)
    assert {:ok, %{status: "LAUNCHED"}} = Scheduler.ticket_step(context, "run", options)
    assert_receive {:factory_task_started, "run:feature-writer", "worker"}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 30_000
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert length(WorkerEvidence.pending(ctx.store, "run")) == 1
  end

  for recovery_mode <- [:capacity, :interrupted] do
    @tag recovery_mode: recovery_mode
    test "prepared #{recovery_mode} retry launches once on the original native thread through the controller", ctx do
      {old, _access, options} = if ctx.recovery_mode == :interrupted, do: interrupted(ctx, true), else: failed(ctx, true)
      prepare = if ctx.recovery_mode == :interrupted, do: &FailedTurnRecovery.prepare_interrupted/4, else: &FailedTurnRecovery.prepare/4
      assert {:ok, receipt} = prepare.(ctx.store, old["request_key"], "failed-turn", options)
      {:ok, run} = RunLedger.get(ctx.store, "run")
      {:ok, snapshot} = Jason.decode(run["snapshot_json"])
      snapshot = Map.merge(snapshot, %{"status" => "In Dev", "labels" => ["ai-running"]})
      {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
      supervisor = start_supervised!(Task.Supervisor)

      policy = %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"fast" => "gpt-6-luna"}},
        "roles" => %{"feature-writer" => %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "medium"}}
      }

      options =
        Keyword.merge(options,
          project_id: nil,
          project_root: ctx.repo,
          thread_name: "writer",
          workspace_root: Path.join(ctx.root, "workspaces"),
          app_server: RetryServer,
          task_key: "writer",
          stage: "WRITING",
          role: "feature-writer",
          recipient: self(),
          authorization: authorization,
          model_policy: policy,
          review_base_sha: ctx.sha,
          expected_sha: ctx.sha,
          failed_turn_recovery: receipt
        )

      issue = %SymphonyElixir.Tracker.Issue{identifier: "PPL-123", id: "issue-id"}

      Process.put(:queue_read_probe, fn ->
        read = Task.async(fn -> Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence") end)
        assert {:ok, _} = Task.yield(read, 1000)
      end)

      assert {:ok, _} = TaskLauncher.launch(ctx.store, supervisor, run, issue, ctx.path, receipt["prompt"], StageSchemas.for_stage(:native_feature_writer), options)
      assert_receive {:factory_task_started, "writer", "worker"}, 15_000
      assert_receive {:factory_task_finished, "writer", {:ok, _}}, 30_000
      assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
      assert {:ok, retry} = WorkerEvidence.get(ctx.store, receipt["new_request_key"])
      assert retry["thread_id"] == "worker" and retry["turn_id"] != "failed-turn"
      assert WorkerEvidence.owner_stopped?(ctx.store, retry)
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 2
    end
  end

  test "manual failed-turn recovery preserves old attempt and gives one distinct same-chat reservation", ctx do
    {old, access, options} = failed(ctx)
    assert {:ok, receipt} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    assert receipt["kind"] == "FAILED_TURN_QUIESCENCE"
    assert receipt["new_request_key"] != old["request_key"]
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert {:ok, new} = WorkerEvidence.get(ctx.store, receipt["new_request_key"])
    assert new["status"] == "RESERVED"
    assert Jason.decode!(new["binding_json"])["expected_sha"] == ctx.sha
    assert {:ok, task} = TaskLedger.get(ctx.store, "writer")
    assert task["thread_id"] == "worker" and task["model"] == "gpt-6-luna"
    assert {:ok, new_access} = WorkspaceAccess.get(ctx.store, new["reservation_key"])
    assert new_access["canonical_path"] == access["canonical_path"] and new_access["generation"] > access["generation"]
    assert WorkerEvidence.pending(ctx.store, "run") == [new]
    assert {:ok, ^receipt} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_evidence")["n"] == 2
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM ticket_chat_inputs")["n"] == 0
  end

  test "later native turn or unjournaled dirty bytes cannot be retried", ctx do
    {old, _access, options} = failed(ctx)
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "INSERT INTO thread_turns VALUES('worker','later',2,'inProgress',NULL,NULL,NULL);"])
    assert {:error, _} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    {_, 0} = System.cmd("sqlite3", [options[:native_history], "DELETE FROM thread_turns WHERE turn_id='later';"])
    File.write!(Path.join(ctx.path, "fixture.txt"), "preserve this\n")
    assert {:error, _} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "preserve this\n"
  end

  test "a live owner, pending human input, changed allocation or ambiguous IO remains protected", ctx do
    {old, _access, options} = failed(ctx)

    probes = [
      {fn ->
         Store.query!(ctx.store, "UPDATE worker_evidence SET owner_process_json = ? WHERE request_key = ?", [
           Jason.encode!(%{"pid" => System.pid(), "invocation_nonce" => String.duplicate("a", 64)}),
           old["request_key"]
         ])
       end, fn -> Store.query!(ctx.store, "UPDATE worker_evidence SET owner_process_json = ? WHERE request_key = ?", [old["owner_process_json"], old["request_key"]]) end},
      {fn -> TaskLedger.update(ctx.store, "writer", %{model: "different"}) end, fn -> TaskLedger.update(ctx.store, "writer", %{model: "gpt-6-luna"}) end},
      {fn ->
         Store.query!(
           ctx.store,
           "INSERT INTO worker_file_operations(request_key,call_id,arguments_sha256,path,before_sha256,after_sha256,phase,io_pending) VALUES(?,'pending','hash','fixture.txt','before','after','PREPARED',1)",
           [old["request_key"]]
         )
       end, fn -> Store.query!(ctx.store, "DELETE FROM worker_file_operations WHERE request_key=? AND call_id='pending'", [old["request_key"]]) end}
    ]

    for {probe, restore} <- probes do
      probe.()
      before = Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows
      assert {:error, _} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
      assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == before
      restore.()
    end

    SymphonyElixir.Factory.TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-retry", "body" => "Proceed?", "answers" => %{"yes" => true}})
    assert {:error, :failed_retry_human_input_pending} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
  end

  test "a differently named process in the source cwd blocks recovery", ctx do
    {old, _access, options} = failed(ctx)
    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status, cd: String.to_charlist(ctx.path)])

    try do
      assert {:error, :failed_retry_owner_or_io_active} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
      assert {:ok, ^old} = WorkerEvidence.get(ctx.store, old["request_key"])
    after
      Port.close(port)
    end
  end

  test "tampered applied receipt cannot authorize changed bytes", ctx do
    {old, _access, options} = failed(ctx, true)
    {:ok, proof} = FailedTurnRecovery.prepare(ctx.store, old["request_key"], "failed-turn", options)
    File.write!(Path.join(ctx.path, "fixture.txt"), "tampered\n")
    sha = :crypto.hash(:sha256, "tampered\n") |> Base.encode16(case: :lower)
    altered = Map.put(proof, "files", Enum.map(proof["files"], &Map.put(&1, "after_sha256", sha)))
    Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE event_type='TICKET_FAILED_TURN_RECOVERY_APPLIED'", [Jason.encode!(altered)])
    refute FailedTurnRecovery.superseded?(ctx.store, old)
    assert {:error, :failed_retry_start_unproven} = FailedTurnRecovery.start_preflight(ctx.store, altered, options)
  end

  defp stopped(ctx, old) do
    process = Jason.decode!(old["owner_process_json"])

    observed = %{
      thread_id: old["thread_id"],
      turn_id: old["turn_id"],
      policy: Jason.decode!(old["policy_json"]),
      owner_stop: Map.merge(process, %{"transport" => "owned_app_server", "thread_id" => old["thread_id"], "exit_status" => 0, "cwd" => ctx.path})
    }

    assert {:ok, updated} = WorkerEvidence.record_failed_stop(ctx.store, old["request_key"], observed)
    updated
  end

  test "automatic recovery requires genuine shutdown and persists cooldown and bounded lineage", ctx do
    {old, _, options} = failed(ctx, true)
    assert {:error, _} = FailedTurnRecovery.prepare_automatic(ctx.store, old["request_key"], "failed-turn", options)
    old = stopped(ctx, old)
    assert {:error, :failed_retry_cooldown} = FailedTurnRecovery.prepare_automatic(ctx.store, old["request_key"], "failed-turn", Keyword.put(options, :now, DateTime.from_unix!(300)))
    assert {:ok, first} = FailedTurnRecovery.prepare_automatic(ctx.store, old["request_key"], "failed-turn", Keyword.put(options, :now, DateTime.from_unix!(301)))
    assert first["retry_policy"]["automatic_attempt"] == 1
    assert {:ok, ^first} = FailedTurnRecovery.prepare_automatic(ctx.store, old["request_key"], "failed-turn", options)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^first} = FailedTurnRecovery.prepare_automatic(reopened, old["request_key"], "failed-turn", options)
    after
      GenServer.stop(reopened)
    end

    Enum.reduce(2..4, first, fn number, receipt ->
      {:ok, next} = WorkerEvidence.get(ctx.store, receipt["new_request_key"])
      policy = Jason.decode!(next["binding_json"])["policy"]
      turn = "failed-#{number}"
      {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, next["request_key"])
      {:ok, _} = WorkerEvidence.bind_thread(ctx.store, next["request_key"], "worker", policy)
      {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, next["request_key"], Jason.decode!(old["owner_process_json"]))
      {:ok, _} = WorkerEvidence.bind_turn(ctx.store, next["request_key"], "worker", turn)
      {:ok, capability} = WorkerFileTools.bind(ctx.store, next["request_key"], next["owner_id"])
      before_bytes = File.read!(Path.join(ctx.path, "fixture.txt"))
      bytes = "partial #{number}\n"
      before_sha = :crypto.hash(:sha256, before_bytes) |> Base.encode16(case: :lower)

      assert WorkerFileTools.execute(capability, "repo_write", %{"path" => "fixture.txt", "expected_sha256" => before_sha, "content" => bytes}, %{
               "threadId" => "worker",
               "turnId" => turn,
               "callId" => "retry-write-#{number}",
               "tool" => "repo_write"
             })["success"]

      error = Jason.decode!(first["native"]["error_json"])
      {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, next["request_key"], {:worker_turn_error, error})
      {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STALE", turn_id: turn, failure_code: inspect({:worker_turn_error, error})})
      {:ok, failed_attempt} = WorkerEvidence.get(ctx.store, next["request_key"])
      failed_attempt = stopped(ctx, failed_attempt)
      {_, 0} = System.cmd("sqlite3", [options[:native_history], "INSERT INTO thread_turns VALUES('worker','#{turn}',#{number},'failed','#{Jason.encode!(error)}',1,NULL);"])
      options = Keyword.put(options, :now, DateTime.from_unix!(1801))

      if number < 4 do
        assert {:ok, transfer} = FailedTurnRecovery.prepare_automatic(ctx.store, next["request_key"], turn, options)
        assert transfer["retry_policy"]["automatic_attempt"] == number
        assert transfer["retry_policy"]["root_request_key"] == old["request_key"]
        assert :ok = FailedTurnRecovery.start_preflight(ctx.store, transfer, options)
        assert File.read!(Path.join(ctx.path, "fixture.txt")) == bytes
        transfer
      else
        assert {:error, :failed_retry_budget_exhausted} = FailedTurnRecovery.prepare_automatic(ctx.store, next["request_key"], turn, options)
        assert {:ok, ^failed_attempt} = WorkerEvidence.get(ctx.store, next["request_key"])
        assert File.read!(Path.join(ctx.path, "fixture.txt")) == bytes
        receipt
      end
    end)
  end
end
