defmodule SymphonyElixir.FactoryControllerChecksTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, StageSchemas, Store, TaskLedger, TicketWorkerRunner}
  alias SymphonyElixir.Factory.{WorkerCheckIO, WorkerEvidence, WorkerFileIO, WorkspaceAccess}
  setup :setup_fixture

  defp stopped_writer(ctx, stop \\ true) do
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "reservation:request",
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "input_sha256" => String.duplicate("p", 64),
        "owner_id" => "owned-invocation",
        "schema" => StageSchemas.for_stage(:native_feature_writer),
        "policy" => policy
      })

    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, "reservation:request")
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, "reservation:request", "worker", policy)
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, "reservation:request", process_receipt())
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, "reservation:request", "worker", "turn")
    output = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => "fixture", "blockers" => [], "checks" => []}
    {:ok, _} = WorkerEvidence.record_result(ctx.store, "reservation:request", %{thread_id: "worker", turn_id: "turn", item_id: "final", output: output})
    if stop, do: WorkerEvidence.record_owner_stopped(ctx.store, "reservation:request", "owned-invocation", stop_receipt(ctx))
  end

  test "a controller check executes on the exact clean candidate and replays without another process", ctx do
    stopped_writer(ctx)
    File.write!(Path.join(ctx.path, "fixture.txt"), "candidate\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "controller candidate"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    {:ok, task_before} = TaskLedger.get(ctx.store, "writer")
    {:ok, run_before} = RunLedger.get(ctx.store, "run")

    assert {:ok, check} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert check["phase"] == "COMPLETE"
    receipt = Jason.decode!(check["receipt_json"])
    assert receipt["result"] == "PASS"
    assert receipt["candidate_sha"] == sha
    assert receipt["base_sha"] == ctx.sha
    assert receipt["cwd"] == ctx.path
    assert is_integer(receipt["pid"]) and receipt["pid"] > 0
    assert receipt["termination"] == %{"kind" => "exited", "code" => 0}
    assert {:ok, ^check} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, ^task_before} = TaskLedger.get(ctx.store, "writer")
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a failed check retains its actual failure and never becomes a verifier pass", ctx do
    stopped_writer(ctx)
    sha = candidate(ctx, "trailing whitespace \n")
    assert {:ok, row} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    receipt = Jason.decode!(row["receipt_json"])
    assert receipt["result"] == "FAIL"
    assert receipt["candidate_sha"] == sha
    assert receipt["termination"] == %{"kind" => "exited", "code" => 2}
    assert Base.decode64!(receipt["output_base64"]) =~ "trailing whitespace"
    assert {:ok, ^row} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "oversized Git diagnostics are bounded and retain actual stopped-child failure", ctx do
    stopped_writer(ctx)
    candidate(ctx, String.duplicate("bad \n", 45_000))
    assert {:ok, row} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    receipt = Jason.decode!(row["receipt_json"])
    assert receipt["result"] == "FAIL"
    assert receipt["overflow"] == true
    assert byte_size(Base.decode64!(receipt["output_base64"])) == 1_048_576
    assert receipt["termination"] == %{"kind" => "signaled", "signal" => 9}
    assert {:ok, ^row} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a restart recovers the committed child receipt without launching the check again", ctx do
    stopped_writer(ctx)
    {:ok, reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    {:ok, raw} = WorkerCheckIO.execute(reserved, &WorkerEvidence.start_check(ctx.store, reserved["check_key"], &1))
    receipt = Jason.decode!(raw)
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, database: ctx.database})
    assert {:ok, row} = TicketWorkerRunner.check(store, "reservation:request", "git-diff-check")
    assert row["phase"] == "COMPLETE"
    assert Jason.decode!(row["receipt_json"]) == receipt
    assert {:ok, ^row} = TicketWorkerRunner.check(store, "reservation:request", "git-diff-check")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(store, "reservation")
  end

  test "a missing receipt does not retry the command or release source ownership", ctx do
    stopped_writer(ctx)
    {:ok, reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    {:ok, _raw} = WorkerCheckIO.execute(reserved, &WorkerEvidence.start_check(ctx.store, reserved["check_key"], &1))
    {:ok, running} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    binding = Jason.decode!(running["binding_json"])
    File.rm!(Path.join(binding["spool"], binding["invocation"] <> ".check-receipt"))
    assert {:error, :controller_check_transport_unproven} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, ^running} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "unknown actions cannot run worker-supplied commands", ctx do
    stopped_writer(ctx)
    assert {:error, :controller_check_action_not_authorized} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git status; touch escaped")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    refute File.exists?(Path.join(ctx.path, "escaped"))
  end

  test "a stale candidate cannot reuse the old check receipt", ctx do
    stopped_writer(ctx)
    {:ok, old} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    sha = candidate(ctx, "a newer candidate\n")
    assert {:ok, current} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    refute current["check_key"] == old["check_key"]
    assert Jason.decode!(current["receipt_json"])["candidate_sha"] == sha
  end

  test "uncommitted source is rejected before check admission", ctx do
    stopped_writer(ctx)
    File.write!(Path.join(ctx.path, "fixture.txt"), "unfinished\n")
    assert {:error, _} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "an unstopped worker cannot admit controller checks", ctx do
    stopped_writer(ctx, false)
    assert {:error, :worker_not_ready_for_consumption} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a prepared file operation blocks checks even without an in-flight helper", ctx do
    stopped_writer(ctx)

    Store.query!(ctx.store, "INSERT INTO worker_file_operations(request_key, call_id, arguments_sha256, path, before_sha256, after_sha256, phase) VALUES (?, ?, ?, ?, ?, ?, 'PREPARED')", [
      "reservation:request",
      "unfinished",
      String.duplicate("a", 64),
      "fixture.txt",
      "before",
      "after"
    ])

    assert {:error, :worker_file_edits_unreconciled} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
  end

  test "a completed row without its receipt cannot replay or release the checkout", ctx do
    stopped_writer(ctx)
    {:ok, row} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    Store.query!(ctx.store, "UPDATE controller_checks SET receipt_json = NULL, receipt_sha256 = NULL WHERE check_key = ?", [row["check_key"]])
    assert {:error, :controller_check_binding_changed} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a proven pre-launch rejection leaves the original request retryable", ctx do
    stopped_writer(ctx)
    {:ok, reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    binding = Jason.decode!(reserved["binding_json"]) |> Map.put("helper_path", "/unproven/helper.py")
    changed = Map.put(reserved, "binding_json", Jason.encode!(binding))

    assert {:error, {:controller_check_not_started, :controller_check_program_changed}} =
             WorkerCheckIO.execute(changed, fn _ -> flunk("rejected transport must not bind a process") end)

    assert {:ok, ^reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"phase" => "COMPLETE"}} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
  end

  test "a persisted stale helper path rejects before launch and keeps source reserved", ctx do
    stopped_writer(ctx)
    {:ok, prepared} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    binding = Jason.decode!(prepared["binding_json"]) |> Map.put("helper_path", Path.join(ctx.root, "old-helper.py"))
    raw = Jason.encode!(binding)
    Store.query!(ctx.store, "UPDATE controller_checks SET binding_json = ?, binding_sha256 = ? WHERE check_key = ?", [raw, digest(raw), prepared["check_key"]])

    assert {:error, :controller_check_program_changed} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, current} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert current["phase"] == "PREPARED"
    assert current["helper_pid"] == nil
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "a lost controller spool quarantines the started check without replaying creation", ctx do
    stopped_writer(ctx)
    {:ok, prepared} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    binding = Jason.decode!(prepared["binding_json"]) |> Map.put("spool", Path.join(ctx.root, "lost-spool"))
    raw = Jason.encode!(binding)
    Store.query!(ctx.store, "UPDATE controller_checks SET binding_json = ?, binding_sha256 = ? WHERE check_key = ?", [raw, digest(raw), prepared["check_key"]])

    assert {:error, :controller_check_transport_unproven} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, uncertain} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert uncertain["phase"] == "RECONCILE_REQUIRED"
    assert is_integer(uncertain["helper_pid"]) and uncertain["helper_pid"] > 0
    assert {:error, :controller_check_transport_unproven} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, ^uncertain} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "corrupted durable diagnostics remain quarantined until exact readback is restored", ctx do
    stopped_writer(ctx)
    {:ok, prepared} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    {:ok, raw} = WorkerCheckIO.execute(prepared, &WorkerEvidence.start_check(ctx.store, prepared["check_key"], &1))
    actual = Jason.decode!(raw)
    binding = Jason.decode!(prepared["binding_json"])
    path = Path.join(binding["spool"], binding["invocation"] <> ".check-receipt")
    File.write!(path, "not-json")

    assert {:error, :controller_check_receipt_unproven} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, uncertain} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert uncertain["phase"] == "RECONCILE_REQUIRED"
    assert uncertain["helper_pid"] == actual["helper_pid"]
    assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    File.write!(path, raw)

    assert {:ok, recovered} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert recovered["phase"] == "COMPLETE"
    assert Jason.decode!(recovered["receipt_json"]) == actual
    assert {:ok, ^recovered} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "a truncated successful-exit transport frame cannot finish or release the owned check", ctx do
    stopped_writer(ctx)
    {:ok, prepared} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")

    assert {:error, :controller_check_transport_unproven} =
             WorkerCheckIO.execute(prepared, fn pid ->
               {:ok, active} = WorkerEvidence.start_check(ctx.store, prepared["check_key"], pid)

               port =
                 Enum.find(Port.list(), fn port ->
                   Port.info(port, :os_pid) == {:os_pid, pid} and Port.info(port, :connected) == {:connected, self()}
                 end)

               assert is_port(port)
               send(self(), {port, {:data, <<4::unsigned-big-32, "bad">>}})
               send(self(), {port, {:exit_status, 0}})
               send(self(), {:malformed_check_frame_injected, port, pid, Port.info(port, :connected)})
               {:ok, active}
             end)

    assert_receive {:malformed_check_frame_injected, port, pid, {:connected, owner}}
    assert is_port(port) and owner == self()
    assert {:ok, active} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert active["helper_pid"] == pid
    assert active["phase"] == "RUNNING"
    assert active["receipt_json"] == nil
    assert owned_child_absent?(active["helper_pid"])
    assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "lost transport ownership reaches the outer deadline without releasing the original check", ctx do
    stopped_writer(ctx)
    {:ok, prepared} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    owner = self()
    collector = spawn(fn -> collect_lost_check_transport(owner) end)
    monitor = Process.monitor(collector)
    started_at = System.monotonic_time(:millisecond)

    try do
      assert {:error, :controller_check_transport_unproven} =
               WorkerCheckIO.execute(prepared, fn pid ->
                 {:ok, active} = WorkerEvidence.start_check(ctx.store, prepared["check_key"], pid)
                 port = Enum.find(Port.list(), &(Port.info(&1, :os_pid) == {:os_pid, pid} and Port.info(&1, :connected) == {:connected, owner}))
                 true = Port.connect(port, collector)
                 send(owner, {:lost_check_transport_bound, port, pid})
                 {:ok, active}
               end)

      assert System.monotonic_time(:millisecond) - started_at >= 29_000
      assert_receive {:lost_check_transport_bound, port, pid}
      assert_receive {:lost_check_output, ^port, bytes}
      assert is_binary(bytes) and byte_size(bytes) > 0
      assert_receive {:lost_check_exit, ^port, 0}
      assert {:ok, active} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
      assert active["phase"] == "RUNNING"
      assert active["helper_pid"] == pid
      assert active["receipt_json"] == nil
      assert owned_child_absent?(pid)
      assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    after
      send(collector, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}
    end
  end

  defp collect_lost_check_transport(owner) do
    receive do
      {port, {:data, bytes}} ->
        send(owner, {:lost_check_output, port, bytes})
        collect_lost_check_transport(owner)

      {port, {:exit_status, status}} ->
        send(owner, {:lost_check_exit, port, status})
        collect_lost_check_transport(owner)

      :stop ->
        :ok
    end
  end

  test "an actual stopped helper timeout retains the original process and checkout reservation", ctx do
    stopped_writer(ctx)
    {:ok, prepared} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    pid_key = {:check_timeout_owner, prepared["check_key"]}

    try do
      assert {:error, :controller_check_transport_unproven} =
               WorkerCheckIO.execute(prepared, fn pid ->
                 Process.put(pid_key, pid)
                 {:ok, active} = WorkerEvidence.start_check(ctx.store, prepared["check_key"], pid)
                 assert {_, 0} = System.cmd("/bin/kill", ["-STOP", Integer.to_string(pid)], stderr_to_stdout: true)
                 {:ok, active}
               end)

      assert {:ok, active} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
      assert active["phase"] == "RUNNING"
      assert active["helper_pid"] == Process.get(pid_key)
      assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    after
      if pid = Process.delete(pid_key) do
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        assert owned_child_absent?(pid)
      end
    end
  end

  test "case aliases cannot place the controller helper inside source", ctx do
    source = Application.app_dir(:symphony_elixir, "priv") |> Path.expand()
    alias_path = String.upcase(source)
    assert {:ok, _} = File.stat(alias_path)
    assert {:error, :controller_program_in_source} = WorkerCheckIO.prepare(ctx.store, alias_path)
  end

  test "unresolved or aliased executable ancestors cannot prove isolation from source", ctx do
    alias_path = Path.join(ctx.root, "source-alias")
    File.ln_s!(ctx.path, alias_path)
    nondirectory = Path.join(ctx.root, "not-a-directory")
    File.write!(nondirectory, "synthetic")

    for path <- [Path.join(ctx.root, "missing/helper.py"), Path.join(alias_path, "helper.py"), Path.join(nondirectory, "helper.py")] do
      assert {:error, :file_io_program_boundary_unproven} = WorkerFileIO.program_outside_source(path, ctx.path)
    end

    assert {:error, :controller_program_in_source} = WorkerFileIO.program_outside_source(Path.join(ctx.path, "helper.py"), ctx.path)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "malformed receipts cannot replace the actual process evidence", ctx do
    stopped_writer(ctx)
    {:ok, reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    {:ok, raw} = WorkerCheckIO.execute(reserved, &WorkerEvidence.start_check(ctx.store, reserved["check_key"], &1))
    receipt = Jason.decode!(raw)

    invalid_fields = [
      {"pid", 0},
      {"helper_pid", 0},
      {"termination", nil},
      {"candidate_sha", String.duplicate("0", 40)},
      {"output_sha256", String.duplicate("0", 64)},
      {"output_base64", nil},
      {"result", "FAIL"}
    ]

    for {field, value} <- invalid_fields do
      changed = Jason.encode!(Map.put(receipt, field, value))
      assert {:error, :controller_check_receipt_unproven} = WorkerEvidence.finish_check(ctx.store, reserved["check_key"], changed)
    end

    assert {:error, :controller_checks_unreconciled} = WorkerEvidence.consume(ctx.store, "reservation:request")
    assert {:ok, %{"phase" => "COMPLETE"}} = WorkerEvidence.finish_check(ctx.store, reserved["check_key"], raw)
  end

  test "check completion is immutable and requires a recorded launch", ctx do
    stopped_writer(ctx)
    {:ok, reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    {:ok, raw} = WorkerCheckIO.execute(reserved, &WorkerEvidence.start_check(ctx.store, reserved["check_key"], &1))
    Store.query!(ctx.store, "UPDATE controller_checks SET phase = 'PREPARED' WHERE check_key = ?", [reserved["check_key"]])
    assert {:error, :controller_check_not_started} = WorkerEvidence.finish_check(ctx.store, reserved["check_key"], raw)
    Store.query!(ctx.store, "UPDATE controller_checks SET phase = 'RUNNING' WHERE check_key = ?", [reserved["check_key"]])
    assert {:ok, complete} = WorkerEvidence.finish_check(ctx.store, reserved["check_key"], raw)
    assert {:ok, ^complete} = WorkerEvidence.finish_check(ctx.store, reserved["check_key"], raw)
    output = "changed diagnostics"
    changed = raw |> Jason.decode!() |> Map.merge(%{"output_base64" => Base.encode64(output), "output_sha256" => digest(output)}) |> Jason.encode!()
    assert {:error, :controller_check_receipt_conflict} = WorkerEvidence.finish_check(ctx.store, reserved["check_key"], changed)
    assert {:error, :unknown_controller_check} = WorkerEvidence.finish_check(ctx.store, "unknown", raw)
    assert {:ok, ^complete} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "missing review-base evidence and malformed check transport cannot authorize execution", ctx do
    stopped_writer(ctx)
    Store.query!(ctx.store, "DELETE FROM ticket_review_bases WHERE run_id = ?", ["run"])
    assert {:error, :ticket_review_base_missing} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:error, :controller_check_transport_unproven} = WorkerCheckIO.readback(%{"binding_json" => "not-json"})
    refute WorkerCheckIO.receipt_valid?(nil, %{}, 123)
    refute WorkerCheckIO.receipt_valid?("not-json", %{}, 123)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "simultaneous ticks converge on one owned check instead of retrying creation", ctx do
    stopped_writer(ctx)
    tasks = for _ <- 1..3, do: Task.async(fn -> TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check") end)
    results = Enum.map(tasks, &Task.await(&1, 30_000))
    assert {:ok, completed} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert Enum.any?(results, &(&1 == {:ok, completed}))

    for result <- results do
      case result do
        {:ok, row} -> assert row == completed
        {:error, reason} -> assert reason in ~w(controller_check_in_progress controller_check_transport_unproven)a
      end
    end

    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a changed contract invalidates controller check admission", ctx do
    stopped_writer(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{spec_revision: 2})
    assert {:error, :worker_inputs_changed} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
  end

  test "an unresolved old-candidate check prevents a second candidate admission", ctx do
    stopped_writer(ctx)
    {:ok, reserved} = WorkerEvidence.prepare_check(ctx.store, "reservation:request", "git-diff-check")
    assert {:error, :lost_reply} = WorkerEvidence.uncertain_check(ctx.store, reserved["check_key"], :lost_reply)
    candidate(ctx, "new candidate\n")
    assert {:error, :controller_checks_unreconciled} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "Git checks do not invoke repository-configured fsmonitor or diff drivers", ctx do
    stopped_writer(ctx)
    marker = Path.join(ctx.root, "driver-ran")
    script = Path.join(ctx.root, "driver.sh")
    File.write!(script, "#!/bin/sh\nprintf ran > '" <> marker <> "'\ncat \"$1\"\n")
    File.chmod!(script, 0o700)
    git(ctx.path, ["config", "diff.fixture.textconv", script])
    git(ctx.path, ["config", "diff.external", script])
    git(ctx.path, ["config", "core.fsmonitor", script])
    File.write!(Path.join(ctx.path, ".gitattributes"), "fixture.txt diff=fixture\n")
    git(ctx.path, ["-c", "core.fsmonitor=false", "add", ".gitattributes"])
    git(ctx.path, ["-c", "core.fsmonitor=false", "commit", "--no-verify", "-m", "attributes"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    System.cmd(script, [Path.join(ctx.path, "fixture.txt")])
    assert File.read!(marker) == "ran"
    File.rm!(marker)
    assert {:ok, row} = TicketWorkerRunner.check(ctx.store, "reservation:request", "git-diff-check")
    assert Jason.decode!(row["receipt_json"])["result"] == "PASS"
    refute File.exists?(marker)
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp owned_child_absent?(pid) do
    Enum.reduce_while(1..100, false, fn _, _ ->
      case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(10)
          {:cont, false}

        _ ->
          {:halt, true}
      end
    end)
  end

  defp candidate(ctx, content) do
    File.write!(Path.join(ctx.path, "fixture.txt"), content)
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "controller candidate"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    sha
  end
end
