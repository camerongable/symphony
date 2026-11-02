defmodule SymphonyElixir.FactoryTicketCheckoutTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{Capacity, RunLedger, Store, TicketCheckout, TicketCheckoutIO, TicketWorkerRunner}
  alias SymphonyElixir.Factory.TicketPush
  alias SymphonyElixir.Factory.{WorkspaceAccess, Worktree}

  setup context do
    ctx = setup_fixture(context)
    bind_parent(ctx)
    Store.query!(ctx.store, "DELETE FROM factory_tasks WHERE run_id = 'run'")
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER", worktree: nil, candidate_sha: nil, branch: "cgable/new-initial"})
    snapshot = run["snapshot_json"] |> Jason.decode!() |> Map.merge(%{"labels" => ["ai-ready"], "status" => "To Do"})
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    options = opts(ctx) ++ [workspace_root: Path.join(ctx.root, "workspaces"), base_sha: ctx.sha]
    Map.merge(ctx, %{run: run, snapshot: snapshot, authorization: authorization, options: options})
  end

  test "one immutable intent survives duplicate concurrent reservations and reopening without Git mutation", ctx do
    assert {:ok, intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    assert intent["phase"] == "PREPARED"
    refute File.exists?(intent["canonical_path"])

    for task <- for(_ <- 1..3, do: Task.async(fn -> TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options) end)) do
      assert Task.await(task) == {:ok, intent}
    end

    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^intent} = TicketCheckout.reserve(reopened, "run", ctx.authorization, ctx.options)
    after
      GenServer.stop(reopened)
    end

    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_checkout_intents")["count"] == 1
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    changed = Keyword.put(ctx.options, :base_sha, String.duplicate("0", 40))
    assert {:error, :ticket_checkout_intent_changed} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, changed)
    assert {:ok, ^intent} = TicketCheckout.get(ctx.store, "run")
  end

  test "fresh checkout admission survives a bootstrap acknowledgement arriving after preparation", ctx do
    {:ok, parent} = SymphonyElixir.Factory.TicketChat.bound_for_run(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status='THREAD_RECORDED',turn_id=NULL,output_json=NULL WHERE request_key=?", [parent["create_request_key"]])
    assert {:ok, intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    binding = Jason.decode!(intent["binding_json"])
    refute Enum.any?(~w(status turn_id output_json target_observation_json), &Map.has_key?(binding["bootstrap"], &1))

    assert {:ok, _} =
             SymphonyElixir.Factory.DesktopRequest.complete(ctx.store, parent["create_request_key"], %{
               thread_id: parent["thread_id"],
               turn_id: "later-bootstrap",
               output: %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}
             })

    assert {:ok, %{status: "CHECKOUT_ADMITTED"}} = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, completed} = TicketCheckout.get(ctx.store, "run")
    assert completed["binding_json"] == intent["binding_json"]
    assert completed["binding_sha256"] == intent["binding_sha256"]
  end

  test "retained checkout field sets remain byte-exact through reservation replay and an uncertain claim", ctx do
    assert {:ok, fresh} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    {:ok, parent} = SymphonyElixir.Factory.TicketChat.bound_for_run(ctx.store, "run")
    {:ok, bootstrap} = SymphonyElixir.Factory.DesktopRequest.get(ctx.store, parent["create_request_key"])

    legacy =
      Map.take(bootstrap, ~w(target_kind target_key action status payload_json payload_sha256 metadata_json output_json target_observation_json thread_id turn_id verified_cwd verified_project_id))

    raw = Jason.decode!(fresh["binding_json"]) |> Map.put("bootstrap", legacy) |> Jason.encode!()
    digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_checkout_intents SET binding_json=?,binding_sha256=? WHERE run_id='run'", [raw, digest])
    assert {:ok, retained} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    assert retained["binding_json"] == raw and retained["binding_sha256"] == digest
    assert {:ok, claimed} = TicketCheckout.claim(ctx.store, "run", ctx.authorization, ctx.options)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^claimed} = TicketCheckout.get(reopened, "run")
      assert {:error, :ticket_checkout_already_claimed} = TicketCheckout.claim(reopened, "run", ctx.authorization, ctx.options)
      assert claimed["binding_json"] == raw and claimed["binding_sha256"] == digest
      refute File.exists?(claimed["canonical_path"])
    after
      GenServer.stop(reopened)
    end
  end

  test "low disk and expired authorization reject before intent or base pin and leave source unchanged", ctx do
    assert {:error, :insufficient_writer_capacity} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, Keyword.put(ctx.options, :free_bytes, 19_999_999_999))
    {:ok, expired} = TicketWorkerRunner.authorization(ctx.run, ctx.snapshot, DateTime.add(DateTime.utc_now(), -61))
    assert {:error, :ticket_authorization_expired} = TicketCheckout.reserve(ctx.store, "run", expired, ctx.options)

    for snapshot <- ["not json", "[]", "true"] do
      Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run'", [snapshot])
      assert {:error, :ticket_chat_snapshot_invalid} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
      assert Store.one!(ctx.store, "SELECT snapshot_json FROM runs WHERE run_id = 'run'")["snapshot_json"] == snapshot
    end

    Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run'", [ctx.run["snapshot_json"]])
    assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows == []
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "pending intent occupies shared capacity without double-counting replay", ctx do
    policy = put_in(ctx.options[:capacity_policy], ["capacity", "maximum_writers"], 1)
    options = Keyword.put(ctx.options, :capacity_policy, policy)
    assert {:ok, intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, options)
    assert {:ok, snapshot} = Capacity.snapshot(ctx.store, policy, "grail", free_bytes: 21_000_000_000)
    assert snapshot.available_writer_slots == 0
    assert {:ok, ^intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, options)
    assert {:ok, ^snapshot} = Capacity.snapshot(ctx.store, policy, "grail", free_bytes: 21_000_000_000)

    for phase <- ~w(MUTATING_UNCERTAIN RECONCILE_REQUIRED) do
      Store.query!(ctx.store, "UPDATE ticket_checkout_intents SET phase = ? WHERE run_id = 'run'", [phase])
      assert {:ok, ^snapshot} = Capacity.snapshot(ctx.store, policy, "grail", free_bytes: 21_000_000_000)
    end

    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    refute File.exists?(intent["canonical_path"])
  end

  test "one mutation claim wins and restart does not reissue an uncertain operation", ctx do
    assert {:ok, _} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    tasks = for _ <- 1..3, do: Task.async(fn -> TicketCheckout.claim(ctx.store, "run", ctx.authorization, ctx.options) end)
    results = Enum.map(tasks, &Task.await/1)
    assert [{:ok, claimed}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :ticket_checkout_already_claimed})) == 2
    assert claimed["phase"] == "MUTATING_UNCERTAIN"
    assert byte_size(claimed["owner_nonce"]) == 64
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:error, :ticket_checkout_already_claimed} = TicketCheckout.claim(reopened, "run", ctx.authorization, ctx.options)
    after
      GenServer.stop(reopened)
    end

    assert {:ok, ^claimed} = TicketCheckout.get(ctx.store, "run")
    refute File.exists?(claimed["canonical_path"])
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
  end

  test "a path claimed after reservation blocks the owned Git claim", ctx do
    assert {:ok, intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    bases = Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows
    File.mkdir_p!(intent["canonical_path"])

    assert {:error, :ticket_checkout_path_or_branch_owned} =
             TicketCheckout.claim(ctx.store, "run", ctx.authorization, ctx.options)

    assert {:ok, ^intent} = TicketCheckout.get(ctx.store, "run")
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows == bases
  end

  test "pending checkout holds its disk budget even when concurrency permits another writer", ctx do
    assert {:ok, _} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, snapshot} = Capacity.snapshot(ctx.store, ctx.options[:capacity_policy], "grail", free_bytes: 21_000_000_000)
    assert snapshot.maximum_writers == 2
    assert snapshot.available_writer_slots == 0
    assert snapshot.free_bytes == 21_000_000_000
    assert {:ok, own} = Capacity.snapshot(ctx.store, ctx.options[:capacity_policy], "grail", free_bytes: 21_000_000_000, exclude_writer_issue_key: ctx.run["issue_key"])
    assert own.available_writer_slots == 1
  end

  test "capacity repository mismatch and source-contained root reject before reservation", ctx do
    policy = put_in(ctx.options[:capacity_policy], ["repositories", "grail", "path"], ctx.root)
    assert {:error, :ticket_checkout_binding_unproven} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, Keyword.put(ctx.options, :capacity_policy, policy))
    assert {:error, :ticket_checkout_binding_unproven} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, Keyword.put(ctx.options, :workspace_root, ctx.repo))
    assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows == []
  end

  test "checkout refuses to run its controller program inside the application priv root", ctx do
    {:ok, priv_root} = SymphonyElixir.PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    options = Keyword.put(ctx.options, :workspace_root, priv_root)
    assert {:ok, intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, options)
    assert intent["phase"] == "PREPARED"
    assert String.starts_with?(intent["canonical_path"], priv_root <> "/")
    refute File.exists?(intent["canonical_path"])

    protected_tables = ~w(runs factory_tasks workspace_access worker_evidence events desktop_requests ticket_review_bases)
    protected_before = Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end)
    {:ok, run_before} = RunLedger.get(ctx.store, "run")
    source_file = Path.join(ctx.path, "fixture.txt")
    source_index = Path.join(String.trim(git(ctx.path, ["rev-parse", "--absolute-git-dir"])), "index")
    source_bytes = File.read!(source_file)
    index_bytes = File.read!(source_index)

    assert {:error, :ticket_push_history_unproven} =
             TicketPush.validate_historical_completed_preimage(ctx.store, run_before)

    assert {:error, %Jason.DecodeError{}} =
             TicketPush.validate_historical_completed_preimage(
               ctx.store,
               Map.put(run_before, "candidate_handoff", "{")
             )

    assert {:error, :controller_program_in_source} = TicketCheckout.create(ctx.store, "run", ctx.authorization, options)

    assert {:ok, failed} = TicketCheckout.get(ctx.store, "run")
    assert failed["phase"] == "RECONCILE_REQUIRED"
    assert failed["last_error"] == inspect(:controller_program_in_source)
    assert is_binary(failed["owner_nonce"])
    assert failed["helper_pid"] == nil
    assert failed["execution_json"] == nil
    assert failed["receipt_json"] == nil
    assert {:error, :ticket_checkout_already_claimed} = TicketCheckout.create(ctx.store, "run", ctx.authorization, options)
    assert {:ok, ^failed} = TicketCheckout.get(ctx.store, "run")
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end) == protected_before
    assert File.read!(source_file) == source_bytes
    assert File.read!(source_index) == index_bytes
    refute File.exists?(intent["canonical_path"])
  end

  test "ignored helper PID persistence leaves checkout execution unreconciled and nonretryable", ctx do
    assert {:ok, intent} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    refute File.exists?(intent["canonical_path"])

    protected_tables = ~w(runs factory_tasks workspace_access worker_evidence events desktop_requests ticket_review_bases)
    protected_before = Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end)
    {:ok, run_before} = RunLedger.get(ctx.store, "run")
    source_file = Path.join(ctx.path, "fixture.txt")
    source_index = Path.join(String.trim(git(ctx.path, ["rev-parse", "--absolute-git-dir"])), "index")
    source_bytes = File.read!(source_file)
    index_bytes = File.read!(source_index)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER ignore_ticket_checkout_helper_pid BEFORE UPDATE OF helper_pid ON ticket_checkout_intents WHEN OLD.run_id = 'run' AND NEW.helper_pid IS NOT NULL BEGIN SELECT RAISE(IGNORE); END"
    )

    try do
      assert {:error, :ticket_checkout_execution_unproven} = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    after
      Store.query!(ctx.store, "DROP TRIGGER ignore_ticket_checkout_helper_pid")
    end

    assert {:ok, failed} = TicketCheckout.get(ctx.store, "run")
    assert failed["phase"] == "RECONCILE_REQUIRED"
    assert failed["last_error"] == inspect(:ticket_checkout_execution_unproven)
    assert is_binary(failed["owner_nonce"])
    assert failed["helper_pid"] == nil
    assert failed["execution_json"] == nil
    assert failed["receipt_json"] == nil
    assert {:error, :ticket_checkout_already_claimed} = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:error, :ticket_checkout_execution_unproven} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, ^failed} = TicketCheckout.get(ctx.store, "run")
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end) == protected_before
    assert File.read!(source_file) == source_bytes
    assert File.read!(source_index) == index_bytes
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run'").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run'").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM desktop_requests WHERE target_key = 'run'").rows == []
    refute File.exists?(intent["canonical_path"])
    assert git(ctx.repo, ["branch", "--list", ctx.run["branch"]]) == ""
  end

  test "another linked repository cannot reserve the same common Git branch", ctx do
    register(ctx, "other", "PPL-124", "other-writer")
    {:ok, identity} = Worktree.repository_identity(ctx.path)
    binding = Jason.encode!(%{"repository_identity" => identity})

    Store.query!(ctx.store, "INSERT INTO ticket_checkout_intents(run_id, canonical_path, repo_path, branch, binding_json, binding_sha256, phase) VALUES (?, ?, ?, ?, ?, ?, 'PREPARED')", [
      "other",
      Path.join(ctx.root, "other-writer"),
      ctx.path,
      ctx.run["branch"],
      binding,
      String.duplicate("a", 64)
    ])

    assert {:error, :ticket_checkout_path_or_branch_owned} = TicketCheckout.reserve(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:error, :ticket_checkout_intent_missing} = TicketCheckout.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows == []
  end

  test "owned Git creates one exact checkout and admits planning without model or worker effects", ctx do
    outcome = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    {:ok, observed} = TicketCheckout.get(ctx.store, "run")
    {:ok, raw} = TicketCheckoutIO.readback(observed)
    output = raw |> Jason.decode!() |> Map.fetch!("output_base64") |> Base.decode64!()
    assert match?({:ok, _}, outcome), output
    {:ok, result} = outcome
    assert result.status == "CHECKOUT_ADMITTED"
    assert result.run["state"] == "PLANNING"
    assert result.run["candidate_sha"] == nil
    assert {:ok, intent} = TicketCheckout.get(ctx.store, "run")
    assert intent["phase"] == "READY"
    assert File.read!(Path.join(intent["canonical_path"], "fixture.txt")) == "base\n"
    assert String.trim(git(intent["canonical_path"], ["rev-parse", "HEAD"])) == ctx.sha
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert {:error, :ticket_checkout_not_initial} = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, %{status: "CHECKOUT_ALREADY_AVAILABLE"}} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
  end

  test "restart after Git completion adopts the original receipt without another creation", ctx do
    intent = execute_without_adoption(ctx)
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, result} = TicketCheckout.reconcile(reopened, "run", ctx.authorization, ctx.options)
      assert result.run["state"] == "PLANNING"
      assert {:ok, ready} = TicketCheckout.get(reopened, "run")
      assert ready["owner_nonce"] == intent["owner_nonce"]
      assert ready["helper_pid"] == intent["helper_pid"]
      assert ready["execution_json"] == intent["execution_json"]
      assert ready["phase"] == "READY"
      assert Store.query!(reopened, "SELECT * FROM factory_tasks").rows == []
    after
      GenServer.stop(reopened)
    end
  end

  test "hard-killed controller VM recovers completed checkout from the original durable receipt", ctx do
    support = Path.expand("../support", __DIR__)
    packet = Jason.encode!(%{"authorization" => ctx.authorization, "opts" => Map.new(ctx.options)}) |> Base.encode64()

    args = [
      "-I",
      "-S",
      "-B",
      Path.join(support, "file_io_vm_crash.py"),
      System.find_executable("elixir"),
      Path.expand("_build/test/lib"),
      Path.join(support, "checkout_controller.exs"),
      ctx.database,
      packet
    ]

    {output, 0} = System.cmd("/usr/bin/python3", args)
    observed = Jason.decode!(output)
    assert observed["observed_terminal_helper"] == true, observed["output"]
    assert observed["executing_vm_pid"] == observed["controller_pid"]
    assert observed["controller_returncode"] == -9
    {:ok, intent} = TicketCheckout.get(ctx.store, "run")
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, %{run: recovered}} = TicketCheckout.reconcile(reopened, "run", ctx.authorization, ctx.options)
      assert recovered["state"] == "PLANNING"
      {:ok, ready} = TicketCheckout.get(reopened, "run")
      assert ready["owner_nonce"] == intent["owner_nonce"]
      assert ready["helper_pid"] == intent["helper_pid"]
      assert Store.query!(reopened, "SELECT * FROM factory_tasks").rows == []
    after
      GenServer.stop(reopened)
    end
  end

  test "missing terminal receipt retains the ownership fence and never starts Git", ctx do
    assert {:ok, intent} = TicketCheckout.claim(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, execution} = TicketCheckoutIO.prepare(ctx.store, intent, ctx.authorization)
    failed_start = fn _pid, _encoded -> raise "synthetic startup callback failure" end
    assert {:error, :ticket_checkout_transport_unproven} = TicketCheckoutIO.execute(execution, failed_start)
    assert {:error, :ticket_checkout_execution_unproven} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, current} = TicketCheckout.get(ctx.store, "run")
    assert current["phase"] == "RECONCILE_REQUIRED"
    assert current["owner_nonce"] == intent["owner_nonce"]
    assert current["helper_pid"] == nil
    assert {:error, :ticket_checkout_already_claimed} = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    refute File.exists?(intent["canonical_path"])
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert run == ctx.run
  end

  test "Git failure is terminal evidence but never checkout admission or branch deletion", ctx do
    git(ctx.repo, ["branch", ctx.run["branch"], ctx.sha])
    assert {:error, :ticket_checkout_git_failed} = TicketCheckout.create(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, intent} = TicketCheckout.get(ctx.store, "run")
    assert intent["phase"] == "RECONCILE_REQUIRED"
    assert {:ok, raw} = TicketCheckoutIO.readback(intent)
    assert TicketCheckoutIO.receipt_valid?(raw, intent)
    refute TicketCheckoutIO.receipt_valid?(raw, Map.put(intent, "helper_pid", intent["helper_pid"] + 1))

    for field <- ~w(owner_nonce run_id binding_json binding_sha256) do
      refute TicketCheckoutIO.receipt_valid?(raw, Map.put(intent, field, "foreign"))
    end

    refute TicketCheckoutIO.receipt_valid?("{}", intent)
    refute TicketCheckoutIO.receipt_valid?(nil, intent)
    refute TicketCheckoutIO.receipt_valid?(String.duplicate("x", 262_145), intent)

    receipt = Jason.decode!(raw)

    for invalid <- [
          Map.put(receipt, "termination", %{"kind" => "running"}),
          Map.put(receipt, "termination", %{"kind" => "exited", "code" => 256}),
          Map.put(receipt, "termination", %{"kind" => "signaled", "signal" => 65}),
          Map.put(receipt, "termination", %{"kind" => "exited", "code" => 0, "extra" => true}),
          Map.put(receipt, "output_sha256", String.duplicate("0", 64)),
          Map.put(receipt, "output_base64", "not base64"),
          Map.put(receipt, "child_pid", 0)
        ] do
      refute TicketCheckoutIO.receipt_valid?(Jason.encode!(invalid), intent)
    end

    refute File.exists?(intent["canonical_path"])
    assert String.trim(git(ctx.repo, ["rev-parse", ctx.run["branch"]])) == ctx.sha
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert run == ctx.run
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
  end

  test "dirty completed checkout remains protected and is not admitted", ctx do
    intent = execute_without_adoption(ctx)
    File.write!(Path.join(intent["canonical_path"], "untracked.txt"), "keep me\n")
    assert {:error, _} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    assert File.read!(Path.join(intent["canonical_path"], "untracked.txt")) == "keep me\n"
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert run == ctx.run
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
  end

  test "expired authorization and low capacity defer adoption of the same completed operation", ctx do
    intent = execute_without_adoption(ctx)
    {:ok, expired} = TicketWorkerRunner.authorization(ctx.run, ctx.snapshot, DateTime.add(DateTime.utc_now(), -61))
    assert {:error, :ticket_authorization_expired} = TicketCheckout.reconcile(ctx.store, "run", expired, ctx.options)
    assert {:error, :insufficient_writer_capacity} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, Keyword.put(ctx.options, :free_bytes, 19_999_999_999))
    assert {:ok, %{run: recovered}} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    assert recovered["state"] == "PLANNING"
    assert {:ok, ready} = TicketCheckout.get(ctx.store, "run")
    assert ready["owner_nonce"] == intent["owner_nonce"]
    assert ready["helper_pid"] == intent["helper_pid"]
  end

  test "pending checkout denies foreign source and review access and unresolved activity blocks adoption", ctx do
    intent = execute_without_adoption(ctx)
    register(ctx, "other", "PPL-124", "other-writer", intent["canonical_path"], ctx.run["branch"])
    access = attrs(ctx) |> Map.merge(%{"run_id" => "other", "task_key" => "other-writer", "reservation_key" => "foreign", "request_key" => "foreign:request"})

    for mode <- ~w(SOURCE REVIEW) do
      assert {:error, :workspace_checkout_creation_pending} = WorkspaceAccess.acquire(ctx.store, Map.put(access, "mode", mode), ctx.options)
    end

    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert {:error, :workspace_activity_unresolved} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    assert {:ok, unchanged} = RunLedger.get(ctx.store, "run")
    assert unchanged == ctx.run
    Store.query!(ctx.store, "UPDATE factory_tasks SET status = 'COMPLETE' WHERE task_key = 'other-writer'")
    {:ok, observed} = Worktree.checkout_identity(%{"path" => ctx.repo}, intent["canonical_path"], detached: false, expected_branch: ctx.run["branch"], expected_sha: ctx.sha)

    Store.query!(
      ctx.store,
      "INSERT INTO workspace_access(reservation_key, run_id, request_key, mode, generation, canonical_path, git_dir, common_dir, binding_json, acquired_at) VALUES ('foreign', 'other', 'foreign:request', 'REVIEW', 1, ?, ?, ?, '{}', 'fixture')",
      [observed.path, observed.git_dir, observed.common_dir]
    )

    assert {:error, :workspace_busy} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    Store.query!(ctx.store, "UPDATE workspace_access SET released_at = 'fixture' WHERE reservation_key = 'foreign'")
    assert {:ok, %{run: recovered}} = TicketCheckout.reconcile(ctx.store, "run", ctx.authorization, ctx.options)
    assert recovered["state"] == "PLANNING"
    assert {:ok, ready} = TicketCheckout.get(ctx.store, "run")
    assert ready["helper_pid"] == intent["helper_pid"]
    assert ready["owner_nonce"] == intent["owner_nonce"]
  end

  test "helper refuses changed manual validation or bootstrap before any Git spawn", ctx do
    for change <- [:manual_validation, :bootstrap] do
      ctx =
        if change == :bootstrap do
          Store.query!(ctx.store, "DELETE FROM ticket_checkout_intents WHERE run_id = 'run'")
          Store.query!(ctx.store, "UPDATE runs SET manual_validation_required = 0 WHERE run_id = 'run'")
          ctx
        else
          ctx
        end

      {:ok, intent} = TicketCheckout.claim(ctx.store, "run", ctx.authorization, ctx.options)
      {:ok, execution} = TicketCheckoutIO.prepare(ctx.store, intent, ctx.authorization)

      assert {:error, :ticket_checkout_transport_unproven} =
               TicketCheckoutIO.execute(execution, fn pid, encoded ->
                 Store.query!(ctx.store, "UPDATE ticket_checkout_intents SET helper_pid = ?, execution_json = ? WHERE run_id = 'run'", [pid, encoded])

                 case change do
                   :manual_validation -> Store.query!(ctx.store, "UPDATE runs SET manual_validation_required = 1 WHERE run_id = 'run'")
                   :bootstrap -> Store.query!(ctx.store, "UPDATE desktop_requests SET verified_cwd = '/foreign-parent' WHERE target_kind = 'TICKET_CHAT'")
                 end

                 TicketCheckout.get(ctx.store, "run")
               end)

      refute File.exists?(intent["canonical_path"])
      assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    end
  end

  defp execute_without_adoption(ctx) do
    {:ok, intent} = TicketCheckout.claim(ctx.store, "run", ctx.authorization, ctx.options)
    {:ok, execution} = TicketCheckoutIO.prepare(ctx.store, intent, ctx.authorization)

    assert {:ok, _raw} =
             TicketCheckoutIO.execute(execution, fn pid, encoded ->
               Store.query!(ctx.store, "UPDATE ticket_checkout_intents SET helper_pid = ?, execution_json = ? WHERE run_id = 'run' AND helper_pid IS NULL", [pid, encoded])
               TicketCheckout.get(ctx.store, "run")
             end)

    {:ok, current} = TicketCheckout.get(ctx.store, "run")
    current
  end
end
