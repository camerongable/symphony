defmodule SymphonyElixir.FactoryInitialWriterReworkTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture

  alias SymphonyElixir.Factory.{
    Control,
    ControlServer,
    RunLedger,
    Scheduler,
    StageSchemas,
    Store,
    TaskLedger,
    TicketCapabilityRecovery,
    TicketChatCommands,
    TicketReworkRecovery,
    TicketWorkerRunner,
    TickLease,
    WorkerCheckIO,
    WorkerEvidence,
    WorkspaceAccess
  }

  setup :setup_fixture

  defmodule CapabilityJiraReader do
    def issue(_key, _opts) do
      if hook = Process.delete(:capability_jira_hook), do: hook.()
      {:ok, SymphonyElixir.TicketChatFixture.authorized_contract("PPL-123", "issue-id") |> elem(1) |> Map.merge(%{"labels" => ["ai-running"], "status" => "In Dev"})}
    end
  end

  defmodule CapabilityNativeReader do
    def read_native_thread(_thread, _opts) do
      if hook = Process.delete(:capability_native_hook), do: hook.()
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      native = Process.get(:capability_native)
      native = put_in(native, ["latest_turn_observation", "observed_at"], now)
      native = put_in(native, ["latest_turn_observation", "confirmation", "observed_at"], now)
      {:ok, put_in(native, ["queue_observation", "observed_at"], now)}
    end
  end

  @tag :capability_recovery
  test "capability recovery requires explicit operator authority without changing stopped source", ctx do
    body = TicketCapabilityRecovery.body()
    assert body =~ ".symphony-base/" and body =~ "blocked_writer_context"
    refute body =~ "fax"
    refute body =~ "logging"

    for action <- ["go-test", "bazel-test", "shell", "test", "exec"] do
      assert {:error, :controller_check_action_not_authorized} = WorkerCheckIO.policy(action, ctx.path)
    end

    blocked = blocked_initial_writer(ctx, :io)
    before = Store.query!(ctx.store, "SELECT * FROM worker_file_operations WHERE request_key = 'reservation:request'")

    assert {:error, :capability_recovery_authorization_invalid} =
             TicketCapabilityRecovery.stage(ctx.store, %{"run_id" => "run"}, %{}, [])

    assert {:ok, unchanged} = WorkspaceAccess.get(ctx.store, "reservation")
    assert unchanged == blocked.access
    assert WorkerEvidence.get(ctx.store, "reservation:request") == {:ok, blocked.evidence}
    assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations WHERE request_key = 'reservation:request'") == before
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial implementation\n"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type LIKE 'TICKET_CAPABILITY_RECOVERY_%'")["count"] == 0
  end

  for scenario <- [:idle, :completed_tick_during_jira, :active_tick_during_jira] do
    @tag :capability_recovery
    @tag timeout: 120_000
    @tag capability_scenario: scenario
    test "operator capability approval preserves repeated writes with #{scenario}", ctx do
      for path <- ["second.txt", "third.txt"], do: File.write!(Path.join(ctx.path, path), "base\n")
      git(ctx.path, ["add", "second.txt", "third.txt"])
      git(ctx.path, ["commit", "--no-verify", "-m", "fixture base files"])
      ctx = ctx |> Map.put(:base_sha, ctx.sha) |> Map.put(:sha, git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim())
      {:ok, _} = TaskLedger.update(ctx.store, "writer", %{workspace_sha: ctx.sha})
      blocked = blocked_initial_writer(ctx, :capability)
      {:ok, run} = RunLedger.get(ctx.store, "run")
      binding = Jason.decode!(blocked.evidence["binding_json"])

      factory = %{
        enabled: true,
        lease_seconds: 240,
        scope: "scope",
        dispatcher_id: "dispatcher",
        maximum_implementation_iterations: 25,
        maximum_code_repair_rounds: 10,
        writer_disk_gb: 1,
        maximum_writers: 1,
        maximum_specifiers: 3,
        maximum_validators: 4,
        ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]},
        repositories: %{"grail" => %{"path" => ctx.repo}}
      }

      factory =
        if ctx.capability_scenario == :idle do
          struct!(SymphonyElixir.Config.Schema.Factory, factory)
        else
          factory
        end

      Control.initialize(ctx.store, factory)
      Control.activate(ctx.store, factory, "dispatcher")
      control = start_supervised!({ControlServer, store: ctx.store, factory: factory, name: nil})

      input = %{
        "authorization_key" => "operator-one",
        "authorization_reference" => "local-operator:fixture",
        "authorization_body" => "Resume this exact stopped slice after restoring contract-base reads.",
        "run_id" => "run",
        "request_key" => "reservation:request",
        "turn_id" => "turn",
        "output_sha256" => blocked.evidence["output_sha256"],
        "binding_sha256" => blocked.evidence["binding_sha256"],
        "candidate_sha" => ctx.sha,
        "spec_revision" => run["spec_revision"],
        "contract_sha256" => run["contract_sha256"],
        "base_sha" => binding["base_sha"],
        "base_paths" => ["fixture.txt"]
      }

      {native, options} = capability_observation(ctx, blocked)
      Process.put(:capability_native, native)
      options = Keyword.merge(options, jira_reader: CapabilityJiraReader, native_reader: CapabilityNativeReader, workspace: ctx.root, free_bytes: 40_000_000_000)
      rows = Store.query!(ctx.store, "SELECT rowid,* FROM worker_file_operations ORDER BY rowid")
      assert length(rows.rows) == 4

      assert {:error, :capability_recovery_authorization_invalid} = TicketCapabilityRecovery.stage(ctx.store, input, factory, options)
      assert {:ok, description} = TicketCapabilityRecovery.describe(ctx.store, input, factory, options)
      assert description["runtime"]["pid"] == System.pid()

      expected_modules = [
        SymphonyElixir.Factory.TicketCapabilityRecovery,
        SymphonyElixir.Codex.AppServer,
        SymphonyElixir.Factory.BrokerRuntime,
        SymphonyElixir.Factory.Scheduler,
        SymphonyElixir.Factory.TaskLauncher,
        SymphonyElixir.Factory.WorkspaceAccess,
        SymphonyElixir.Factory.WorkerEvidence,
        SymphonyElixir.Factory.TicketWorkerRunner,
        SymphonyElixir.Factory.TicketPushIO,
        SymphonyElixir.Factory.TicketPush,
        SymphonyElixir.Factory.TicketPushOrdinaryRejection,
        SymphonyElixir.Factory.TicketPushPreissuanceRejection,
        SymphonyElixir.Factory.TicketPushRecoveryIO,
        SymphonyElixir.Factory.TicketPushWorkerHistory,
        SymphonyElixir.Factory.TicketInfrastructureRecovery,
        Mix.Tasks.Factory.Ticket
      ]

      assert Enum.sort(Map.keys(description["runtime"]["modules"])) == Enum.sort(Enum.map(expected_modules, &Atom.to_string/1))

      for module <- expected_modules do
        assert description["runtime"]["modules"][Atom.to_string(module)] == %{
                 "md5" => module.module_info(:md5) |> Base.encode16(case: :lower),
                 "compile_source" => module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string(),
                 "code_path" => module |> :code.which() |> to_string(),
                 "loaded_path" => module |> :code.is_loaded() |> elem(1) |> to_string()
               }
      end

      grant_root = Path.join(ctx.root, "operator-grants")
      File.mkdir!(grant_root)
      File.chmod!(grant_root, 0o700)

      grant = %{
        "version" => 1,
        "kind" => "CONTRACT_BASE_CAPABILITY_OPERATOR_GRANT_V1",
        "grant_id" => "grant-one",
        "nonce" => String.duplicate("a", 64),
        "purpose" => "RESUME_EXACT_BASE_PREIMAGE_BLOCKED_WRITER",
        "capability_blockers" => Jason.decode!(blocked.evidence["output_json"])["blockers"],
        "base_paths" => input["base_paths"],
        "authorization_sha256" => description["authorization_sha256"],
        "binding_sha256" => description["binding_sha256"],
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "expires_at" => DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
      }

      grant_bytes = Jason.encode!(grant)
      grant_path = Path.join(grant_root, "grant-one.json")
      File.write!(grant_path, grant_bytes)
      File.chmod!(grant_path, 0o600)
      input = Map.merge(input, %{"grant_id" => "grant-one", "grant_sha256" => :crypto.hash(:sha256, grant_bytes) |> Base.encode16(case: :lower)})
      options = Keyword.put(options, :grant_root, grant_root)

      if ctx.capability_scenario == :idle do
        assert_capability_denials(ctx, input, factory, options, grant_path, grant)
        assert_expiry_under_write_lock(ctx, input, factory, options, grant_path, grant)
      end

      install_capability_tick_hook(ctx, factory, control)

      assert {:ok, receipt} = TicketCapabilityRecovery.stage(ctx.store, input, factory, options)
      finish_capability_tick_hook()
      assert receipt.status == "CAPABILITY_RECOVERY_AUTHORIZED"
      proof = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED'")["payload_json"] |> Jason.decode!()

      assert Map.take(proof["policy"], ~w(writer_disk_gb maximum_writers maximum_specifiers maximum_validators)) == %{
               "writer_disk_gb" => 1,
               "maximum_writers" => 1,
               "maximum_specifiers" => 3,
               "maximum_validators" => 4
             }

      assert {:ok, ^receipt} = TicketCapabilityRecovery.stage(ctx.store, input, factory, options)
      assert Store.query!(ctx.store, "SELECT rowid,* FROM worker_file_operations ORDER BY rowid") == rows
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial implementation\n"
      assert {:ok, unchanged} = WorkspaceAccess.get(ctx.store, "reservation")
      assert unchanged == blocked.access
      assert File.read!(Path.join(ctx.path, "second.txt")) == "second partial\n"
      assert File.read!(Path.join(ctx.path, "third.txt")) == "third partial\n"
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs")["count"] == 0
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence")["count"] == 1

      assert {:error, :capability_recovery_tick_unproven} = TicketCapabilityRecovery.prepare(ctx.store, input["request_key"], factory, options)

      assert {:ran, {:ok, checked}} =
               TickLease.run(
                 factory,
                 fn tick ->
                   Process.put(:capability_native, native)
                   assert is_binary(tick["tick_id"]) and tick["tick_id"] != ""
                   checked_opts = Keyword.merge(options, operator_tick: tick, capability_prompt: "A fixed controller recovery packet")
                   assert {:error, _} = TicketCapabilityRecovery.prepare(ctx.store, input["request_key"], %{factory | maximum_writers: 2}, checked_opts)
                   assert {:ok, descriptor} = TicketCapabilityRecovery.prepare(ctx.store, input["request_key"], factory, checked_opts)
                   assert {:ok, verified} = Store.transaction!(ctx.store, &TicketCapabilityRecovery.checked(&1, descriptor))
                   target = verified.checked["destination"]
                   transfer_capability_fixture(ctx, blocked, descriptor, target)
                   {:ok, descriptor}
                 end,
                 control_server: control
               )

      assert {:error, _} = TicketCapabilityRecovery.checked(ctx.store, checked)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial implementation\n"
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence")["count"] == 2
      assert {:ok, application} = TicketCapabilityRecovery.applied(ctx.store, receipt.recovery_key)
      assert WorkerEvidence.superseded_blocked_attempt?(ctx.store, blocked.evidence)
      assert {:ok, retained} = WorkerEvidence.get(ctx.store, "reservation:request")
      assert retained == blocked.evidence
      assert Store.query!(ctx.store, "SELECT rowid,* FROM worker_file_operations ORDER BY rowid") == rows

      assert {:ran, :ok} =
               TickLease.run(
                 factory,
                 fn tick ->
                   Process.put(:capability_native, native)
                   fresh = Keyword.merge(options, operator_tick: tick, capability_prompt: "A fixed controller recovery packet")
                   assert {:ok, prepared} = TicketCapabilityRecovery.prepare(ctx.store, input["request_key"], factory, fresh)
                   assert prepared["prepared_request_key"] == application["request_key"]

                   assert {:ok, _} =
                            Store.transaction!(ctx.store, fn tx ->
                              assert {:ok, _} = TicketCapabilityRecovery.prepared_access(tx, prepared)
                              TicketCapabilityRecovery.admit_prepared(tx, prepared)
                            end)

                   assert {:error, _} = Store.transaction!(ctx.store, &TicketCapabilityRecovery.admit_prepared(&1, prepared))
                   :ok
                 end,
                 control_server: control
               )

      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_APPLIED'")["count"] == 1
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access")["count"] == 2
      if ctx.capability_scenario == :idle, do: assert_archived_capability_codec(ctx, blocked, application)
    end
  end

  defp assert_archived_capability_codec(ctx, blocked, application) do
    binding = Jason.decode!(blocked.evidence["binding_json"])
    assert {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, application["request_key"])
    assert {:ok, _} = WorkerEvidence.bind_thread(ctx.store, application["request_key"], blocked.evidence["thread_id"], binding["policy"])
    program = Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v12.py")

    script = ~S"""
    import sys,sqlite3,json,importlib.util,copy
    sys.dont_write_bytecode=True
    database,program,encoded=sys.argv[1:]
    spec=importlib.util.spec_from_file_location('capability_archive',program)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    source=sqlite3.connect('file:'+database+'?mode=ro',uri=True); source.row_factory=sqlite3.Row
    worker=json.loads(encoded)
    def validate(db):
        events=[dict(row) for row in db.execute('SELECT * FROM events ORDER BY id')]
        access=dict(db.execute('SELECT * FROM workspace_access WHERE reservation_key=?',(worker['reservation_key'],)).fetchone())
        transfer=json.loads(access['release_receipt_json'])
        target=dict(db.execute('SELECT * FROM worker_evidence WHERE request_key=?',(transfer['new_request_key'],)).fetchone())
        current=dict(db.execute('SELECT * FROM workspace_access WHERE reservation_key=?',(target['reservation_key'],)).fetchone())
        module.capability_transfer(db,events,worker,access,target,current,transfer,encoded.encode())
    validate(source)
    def denied(sql,args=()):
        db=sqlite3.connect(':memory:');db.row_factory=sqlite3.Row;source.backup(db)
        db.execute(sql,args)
        try:validate(db)
        except (ValueError,KeyError,TypeError):pass
        else:raise AssertionError('tampered capability authority accepted')
        db.close()
    denied("DELETE FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED'")
    denied("DELETE FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_CHECKED'")
    denied("DELETE FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_APPLIED'")
    denied("INSERT INTO events(event_type,run_id,payload_json,occurred_at) SELECT event_type,run_id,payload_json,occurred_at FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED'")
    denied("INSERT INTO events(event_type,run_id,payload_json,occurred_at) SELECT event_type,run_id,payload_json,occurred_at FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_APPLIED'")
    denied("UPDATE events SET event_type='TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED' WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED'")
    denied("UPDATE events SET payload_json=json_set(payload_json,'$.authorization.request_key','foreign') WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED'")
    denied("UPDATE events SET payload_json=json_set(payload_json,'$.checked_sha256',?) WHERE event_type='TICKET_CAPABILITY_RECOVERY_APPLIED'",('0'*64,))
    denied("UPDATE workspace_access SET generation=generation+1 WHERE released_at IS NULL")
    denied("UPDATE worker_file_operations SET before_sha256=? WHERE request_key=?",('0'*64,worker['request_key']))
    access=dict(source.execute('SELECT * FROM workspace_access WHERE reservation_key=?',(worker['reservation_key'],)).fetchone())
    row=dict(source.execute('SELECT rowid AS journal_rowid,* FROM worker_file_operations WHERE request_key=? ORDER BY rowid LIMIT 1',(worker['request_key'],)).fetchone())
    for field,value in [('exit_status',1),('nonce','0'*64),('transport','forged'),('cleanup',{})]:
        changed=copy.deepcopy(row);receipt=json.loads(changed['io_receipt_json']);receipt[field]=value;changed['io_receipt_json']=json.dumps(receipt)
        try:module.capability_receipt(changed,worker,access)
        except (ValueError,KeyError,TypeError):pass
        else:raise AssertionError('tampered receipt accepted')
    print('archived TCAP transfer PASS; 14 tamper cases denied; no issuer executed')
    """

    assert {output, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, ctx.database, program, Jason.encode!(blocked.evidence)], stderr_to_stdout: true)
    assert output =~ "archived TCAP transfer PASS"
  end

  defp assert_capability_denials(ctx, input, factory, opts, path, grant) do
    alias SymphonyElixir.Factory.TicketCapabilityRecovery
    original = File.read!(path)

    assert_no_authority = fn ->
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM events WHERE event_type LIKE 'TICKET_CAPABILITY_RECOVERY_%'")["n"] == 0
    end

    native = Process.get(:capability_native)
    messages = get_in(native, ["latest_turn_observation", "raw_response", "data"]) |> hd() |> Map.fetch!("items")
    final = List.last(messages)

    for changed <- [
          messages ++ [final],
          messages ++ [Map.put(final, "text", Jason.encode!(%{"status" => "PASS"}))],
          Enum.drop(messages, -1),
          messages ++ [%{"type" => "agentMessage", "phase" => "final_answer", "text" => "An unstructured trailing answer"}]
        ] do
      raw = put_in(native["latest_turn_observation"]["raw_response"], ["data", Access.at(0), "items"], changed)
      confirmation = %{"raw_response" => raw, "sha256" => capability_hash(Jason.encode!(raw)), "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()}

      bad =
        native
        |> put_in(["latest_turn_observation", "raw_response"], raw)
        |> put_in(["latest_turn_observation", "sha256"], confirmation["sha256"])
        |> put_in(["latest_turn_observation", "confirmation"], confirmation)

      Process.put(:capability_native, bad)
      assert {:error, :capability_recovery_native_unproven} = TicketCapabilityRecovery.describe(ctx.store, input |> Map.drop(~w(grant_id grant_sha256)), factory, opts)
      assert_no_authority.()
    end

    Process.put(:capability_native, native)

    for mutation <- [
          &Map.put(&1, "binding_sha256", String.duplicate("0", 64)),
          &Map.put(&1, "authorization_sha256", String.duplicate("0", 64)),
          &Map.put(&1, "expires_at", DateTime.utc_now() |> DateTime.add(-1) |> DateTime.to_iso8601()),
          &Map.put(&1, "created_at", DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601() |> String.replace_suffix("Z", "+01:00")),
          &Map.put(&1, "expires_at", DateTime.utc_now() |> DateTime.add(4200) |> DateTime.to_iso8601() |> String.replace_suffix("Z", "+01:00")),
          fn value ->
            created = DateTime.utc_now()
            Map.merge(value, %{"created_at" => DateTime.to_iso8601(created), "expires_at" => created |> DateTime.add(900_000_001, :microsecond) |> DateTime.to_iso8601()})
          end,
          &Map.put(&1, "created_at", DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601())
        ] do
      raw = Jason.encode!(mutation.(grant))
      File.write!(path, raw)
      changed = Map.put(input, "grant_sha256", capability_hash(raw))
      assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, changed, factory, opts)
      assert_no_authority.()
    end

    File.write!(path, original)

    File.rename!(path, path <> ".saved")
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    File.ln_s!(path <> ".saved", path)
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    File.rm!(path)
    File.rename!(path <> ".saved", path)
    File.ln!(path, path <> ".hardlink")
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    File.rm!(path <> ".hardlink")
    File.chmod!(path, 0o644)
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    File.chmod!(path, 0o600)
    File.chmod!(Path.dirname(path), 0o755)
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    File.chmod!(Path.dirname(path), 0o700)
    File.ln_s!(Path.dirname(path), path <> ".directory-alias")
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, Keyword.put(opts, :grant_root, path <> ".directory-alias"))
    File.rm!(path <> ".directory-alias")

    for field <- ~w(candidate_sha contract_sha256 base_sha request_key output_sha256) do
      assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, Map.put(input, field, String.duplicate("0", byte_size(input[field]))), factory, opts)
    end

    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, %{factory | maximum_validators: 5}, opts)

    for {table, key, field, changed} <- [
          {"runs", "run_id", "branch", "foreign/branch"},
          {"runs", "run_id", "spec_revision", 99},
          {"runs", "run_id", "contract_sha256", String.duplicate("0", 64)},
          {"factory_tasks", "task_key", "status", "RUNNING"}
        ] do
      identity = if table == "runs", do: "run", else: "writer"
      saved = Store.one!(ctx.store, "SELECT #{field} FROM #{table} WHERE #{key}=?", [identity])[field]
      Store.query!(ctx.store, "UPDATE #{table} SET #{field}=? WHERE #{key}=?", [changed, identity])
      assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
      Store.query!(ctx.store, "UPDATE #{table} SET #{field}=? WHERE #{key}=?", [saved, identity])
    end

    [first, second | _] = Store.query!(ctx.store, "SELECT rowid,before_sha256 FROM worker_file_operations ORDER BY rowid").rows

    for {rowid, hash} <- [first, second] do
      Store.query!(ctx.store, "UPDATE worker_file_operations SET before_sha256=? WHERE rowid=?", [String.duplicate("0", 64), rowid])
      assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
      Store.query!(ctx.store, "UPDATE worker_file_operations SET before_sha256=? WHERE rowid=?", [hash, rowid])
    end

    [rowid, _] = first
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase='PREPARED' WHERE rowid=?", [rowid])
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase='APPLIED' WHERE rowid=?", [rowid])
    file = Path.join(ctx.path, "fixture.txt")
    bytes = File.read!(file)
    File.write!(file, "unrecorded change\n")
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    File.write!(file, bytes)

    name = {SymphonyElixir.Factory.TaskLauncher, :active, "writer"}
    parent = self()

    owner =
      spawn_link(fn ->
        assert :yes = :global.register_name(name, self())
        send(parent, :capability_foreign_owner_registered)

        receive do
          :release -> :global.unregister_name(name)
        end

        send(parent, :capability_foreign_owner_released)
      end)

    assert_receive :capability_foreign_owner_registered
    assert {:error, :capability_recovery_stage_owner_active} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    send(owner, :release)
    assert_receive :capability_foreign_owner_released

    queue = opts[:native_queue_database]
    assert {_, 0} = System.cmd("/usr/bin/sqlite3", [queue, "INSERT INTO queued_items VALUES('human','worker','{}',1,1,1)"])
    assert {:error, _} = TicketCapabilityRecovery.stage(ctx.store, input, factory, opts)
    assert {_, 0} = System.cmd("/usr/bin/sqlite3", [queue, "DELETE FROM queued_items"])
    assert_no_authority.()
    assert File.read!(path) == original
  end

  defp capability_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp assert_expiry_under_write_lock(ctx, input, factory, opts, path, grant) do
    original = File.read!(path)
    expires = DateTime.add(DateTime.utc_now(), 15)
    raw = grant |> Map.put("created_at", DateTime.to_iso8601(DateTime.utc_now())) |> Map.put("expires_at", DateTime.to_iso8601(expires)) |> Jason.encode!()
    File.write!(path, raw)
    changed = Map.put(input, "grant_sha256", capability_hash(raw))
    {:ok, other} = Store.start_link(database: ctx.database)

    Process.put(:capability_native_hook, fn ->
      Process.sleep(max(DateTime.diff(expires, DateTime.utc_now(), :millisecond) - 6000, 0))
      parent = self()

      task =
        Task.async(fn -> hold_capability_write(other, parent, expires) end)

      assert_receive :capability_sql_writer_held, 1000
      Process.put(:capability_sql_writer, task)
    end)

    assert {:error, :capability_recovery_grant_expired} = TicketCapabilityRecovery.stage(ctx.store, changed, factory, opts)
    assert :ok = Task.await(Process.delete(:capability_sql_writer), 1000)
    GenServer.stop(other)
    File.write!(path, original)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED'")["n"] == 0
  end

  defp hold_capability_write(store, parent, expires) do
    Store.transaction!(store, fn _ ->
      send(parent, :capability_sql_writer_held)
      Process.sleep(max(DateTime.diff(expires, DateTime.utc_now(), :millisecond) + 150, 0))
      :ok
    end)
  end

  defp install_capability_tick_hook(%{capability_scenario: :idle}, _, _), do: :ok

  defp install_capability_tick_hook(ctx, factory, control) do
    Process.put(:capability_jira_hook, fn ->
      parent = self()
      scenario = ctx.capability_scenario

      task =
        Task.async(fn -> TickLease.run(factory, &capability_tick_callback(&1, parent, scenario), control_server: control) end)

      if scenario == :completed_tick_during_jira do
        assert_receive :capability_tick_observed, 5_000
        assert Task.await(task, 5_000) == {:ran, :ok}
      else
        assert_receive {:capability_tick_held, holder}, 5_000
        Process.put(:capability_tick_task, {task, holder})
      end
    end)
  end

  defp capability_tick_callback(tick, parent, :completed_tick_during_jira) do
    assert is_binary(tick["tick_id"])

    :global.trans({{Scheduler, :ticket_stage, "run"}, self()}, fn ->
      send(parent, :capability_tick_observed)
      :ok
    end)
  end

  defp capability_tick_callback(tick, parent, :active_tick_during_jira) do
    assert is_binary(tick["tick_id"])
    send(parent, {:capability_tick_held, self()})

    receive do
      :finish_capability_tick -> :ok
    after
      15_000 -> flunk("fixture tick was not released")
    end
  end

  defp finish_capability_tick_hook do
    case Process.delete(:capability_tick_task) do
      {task, holder} ->
        send(holder, :finish_capability_tick)
        assert Task.await(task, 5_000) == {:ran, :ok}

      nil ->
        :ok
    end
  end

  defp transfer_capability_fixture(ctx, blocked, descriptor, target) do
    proof =
      Map.merge(descriptor, %{
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "reservation_generation" => blocked.access["generation"],
        "output_sha256" => blocked.evidence["output_sha256"],
        "new_prompt_sha256" => target["prompt_sha256"],
        "checkout_head_sha" => ctx.sha
      })

    attributes = attrs(ctx) |> Map.merge(%{"reservation_key" => target["reservation_key"], "request_key" => target["request_key"]})

    assert {:ok, _} =
             Store.transaction!(ctx.store, fn tx ->
               assert {:ok, access} = WorkspaceAccess.transfer_capability_source(tx, "reservation", blocked.access["generation"], attributes, proof)
               assert {:ok, _} = TaskLedger.update(tx, "writer", %{status: "STARTING", prompt_sha256: target["prompt_sha256"], output_json: nil, failure_code: nil})
               binding = Jason.decode!(blocked.evidence["binding_json"])

               assert {:ok, _} =
                        WorkerEvidence.reserve_capability(
                          tx,
                          %{
                            "request_key" => target["request_key"],
                            "reservation_key" => target["reservation_key"],
                            "task_key" => "writer",
                            "input_sha256" => target["prompt_sha256"],
                            "owner_id" => "owner:" <> target["request_key"],
                            "schema" => binding["schema"],
                            "policy" => binding["policy"]
                          },
                          descriptor
                        )

               transfer = %{
                 "kind" => "BLOCKED_SOURCE_TRANSFER",
                 "old_request_key" => blocked.evidence["request_key"],
                 "old_reservation_key" => "reservation",
                 "new_request_key" => target["request_key"],
                 "new_reservation_key" => target["reservation_key"],
                 "new_generation" => access["generation"],
                 "disposition_key" => descriptor["disposition_key"],
                 "output_sha256" => blocked.evidence["output_sha256"],
                 "amendment_command_key" => nil,
                 "operational_recovery_key" => descriptor["operational_recovery_key"],
                 "checkout_head_sha" => ctx.sha
               }

               TicketCapabilityRecovery.transferred(tx, descriptor, transfer)
             end)
  end

  test "reconciled file IO recovery transfers the same writer without manufacturing human input", ctx do
    blocked = blocked_initial_writer(ctx, :io)
    alias SymphonyElixir.Factory.TicketInfrastructureRecovery
    assert {:ok, proof} = TicketInfrastructureRecovery.authorize(ctx.store, "reservation:request")
    assert {:ok, ^proof} = TicketInfrastructureRecovery.authorize(ctx.store, "reservation:request")
    assert :ok = TicketInfrastructureRecovery.preflight(ctx.store, proof["recovery_key"])
    assert {:ok, resume} = TicketInfrastructureRecovery.resume(ctx.store, "reservation:request")
    transfer_proof = Map.merge(blocked.proof, resume)
    assert {:ok, access} = WorkspaceAccess.transfer_blocked_source(ctx.store, "reservation", blocked.access["generation"], blocked.attrs, transfer_proof)
    assert access["canonical_path"] == ctx.path
    assert access["generation"] == blocked.access["generation"] + 1
    previous = blocked.evidence
    assert {:ok, ^previous} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "partial implementation\n"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs")["count"] == 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
  end

  test "infrastructure recovery rejects product blockers and changed reconciled files", ctx do
    alias SymphonyElixir.Factory.TicketInfrastructureRecovery
    _blocked = blocked_initial_writer(ctx, :unstaged)
    assert {:error, :infrastructure_recovery_not_eligible} = TicketInfrastructureRecovery.authorize(ctx.store, "reservation:request")
  end

  test "infrastructure recovery rechecks exact partial bytes before transferring", ctx do
    alias SymphonyElixir.Factory.TicketInfrastructureRecovery
    blocked = blocked_initial_writer(ctx, :io)
    assert {:ok, proof} = TicketInfrastructureRecovery.authorize(ctx.store, "reservation:request")
    File.write!(Path.join(ctx.path, "fixture.txt"), "unrelated changed content\n")
    assert {:error, :infrastructure_recovery_file_changed} = TicketInfrastructureRecovery.preflight(ctx.store, proof["recovery_key"])
    previous = blocked.access
    assert {:ok, ^previous} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "infrastructure recovery protects unjournaled partial files", ctx do
    alias SymphonyElixir.Factory.TicketInfrastructureRecovery
    blocked = blocked_initial_writer(ctx, :io)
    assert {:ok, proof} = TicketInfrastructureRecovery.authorize(ctx.store, "reservation:request")
    File.write!(Path.join(ctx.path, "unrelated.txt"), "keep this file\n")
    assert {:error, :infrastructure_recovery_files_unproven} = TicketInfrastructureRecovery.preflight(ctx.store, proof["recovery_key"])
    previous = blocked.access
    assert {:ok, ^previous} = WorkspaceAccess.get(ctx.store, "reservation")
    assert File.read!(Path.join(ctx.path, "unrelated.txt")) == "keep this file\n"
  end

  test "reserved operational recovery replays after reopening and rejects changed HEAD or files", ctx do
    alias SymphonyElixir.Factory.TicketInfrastructureRecovery
    blocked = blocked_initial_writer(ctx, :io)
    {:ok, proof} = TicketInfrastructureRecovery.authorize(ctx.store, "reservation:request")
    {:ok, resume} = TicketInfrastructureRecovery.resume(ctx.store, "reservation:request")
    prompt_hash = :crypto.hash(:sha256, "recovery packet") |> Base.encode16(case: :lower)
    transfer_proof = Map.merge(blocked.proof, resume) |> Map.put("new_prompt_sha256", prompt_hash) |> Map.put("checkout_head_sha", ctx.sha)
    {:ok, access} = WorkspaceAccess.transfer_blocked_source(ctx.store, "reservation", blocked.access["generation"], blocked.attrs, transfer_proof)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STARTING", prompt_sha256: prompt_hash, output_json: nil})

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "resumed:request",
        "task_key" => "writer",
        "reservation_key" => "resumed",
        "input_sha256" => prompt_hash,
        "owner_id" => "new-owner",
        "schema" => StageSchemas.for_stage(:native_feature_writer),
        "policy" => TicketWorkerRunner.policy("SOURCE", ctx.path)
      })

    transfer =
      Store.one!(ctx.store, "SELECT release_receipt_json FROM workspace_access WHERE reservation_key = 'reservation'")["release_receipt_json"]
      |> Jason.decode!()
      |> Map.put("new_generation", access["generation"])

    {:ok, receipt} = TicketInfrastructureRecovery.record_transfer(ctx.store, proof["recovery_key"], transfer)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^receipt} = TicketInfrastructureRecovery.applied(reopened, proof["recovery_key"])
      {:ok, attempt} = WorkerEvidence.get(reopened, "resumed:request")
      assert {:ok, descriptor} = TicketInfrastructureRecovery.prepared(reopened, attempt, transfer)
      assert descriptor["prepared_request_key"] == "resumed:request"
      {:ok, _} = TicketChatCommands.open_question(reopened, "run", %{"question_key" => "Q-new", "body" => "New decision?", "answers" => %{"yes" => true}})
      assert {:error, :infrastructure_recovery_human_input_pending} = TicketInfrastructureRecovery.applied(reopened, proof["recovery_key"])
      Store.query!(reopened, "UPDATE ticket_chat_questions SET status = 'INVALIDATED' WHERE question_key = 'Q-new'")
      File.write!(Path.join(ctx.path, "fixture.txt"), "changed after transfer\n")
      assert {:error, :infrastructure_recovery_file_changed} = TicketInfrastructureRecovery.applied(reopened, proof["recovery_key"])
      File.write!(Path.join(ctx.path, "fixture.txt"), "partial implementation\n")
      git(ctx.path, ["commit", "--no-verify", "--allow-empty", "-m", "unrelated head advance"])
      assert {:error, :infrastructure_recovery_head_changed} = TicketInfrastructureRecovery.applied(reopened, proof["recovery_key"])
      assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
    after
      GenServer.stop(reopened)
    end
  end

  test "accepted native rework transfers a stopped first writer at its exact initial base", ctx do
    blocked = blocked_initial_writer(ctx)
    assert {:ok, transferred} = transfer(ctx, blocked)
    assert transferred["generation"] == blocked.access["generation"] + 1
    assert transferred["canonical_path"] == ctx.path
    assert transferred["released_at"] == nil
    assert {:ok, old} = WorkspaceAccess.get(ctx.store, "reservation")
    assert is_binary(old["released_at"])
    assert Jason.decode!(old["release_receipt_json"])["kind"] == "BLOCKED_SOURCE_TRANSFER"
    assert {:ok, evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert evidence == blocked.evidence
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert {run["candidate_sha"], run["implementation_iteration"]} == {nil, 0}
  end

  test "controller recovers a denied direct native preparation without forging a stage receipt", ctx do
    blocked = blocked_initial_writer(ctx, :unstaged)
    native = denied_native_preparation(ctx, blocked.chat)
    native = update_in(native, ["turns", Access.at(0), "items", Access.at(0), "content", Access.at(0)], &Map.put(&1, "text_elements", []))
    {:ok, current_chat} = SymphonyElixir.Factory.TicketChat.for_run(ctx.store, "run")
    {:ok, current_run} = RunLedger.get(ctx.store, "run")
    {:ok, current_context} = SymphonyElixir.Factory.TicketContext.context(ctx.store, "run")
    assert {:ok, _proof} = TicketReworkRecovery.prepare(native, current_chat, current_run, current_context)
    assert {:ok, %{receipts: [%{status: "OBSERVED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    native = Map.put(native, "status", %{"type" => "notLoaded"})
    assert {:ok, [command]} = TicketChatCommands.recover_failed_preparation(ctx.store, "run", native)
    assert command["status"] == "ACCEPTED"
    receipt = Jason.decode!(command["receipt_json"])
    assert receipt["recovery_evidence"]["kind"] == "CONTROLLER_NATIVE_REWORK_RECOVERY"
    input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    assert input["staging_receipts_json"] == "{}"
    assert TicketReworkRecovery.valid?(command, input, current_chat)

    legacy_receipt = legacy_recovery_receipt(receipt)
    legacy_command = Map.put(command, "receipt_json", Jason.encode!(legacy_receipt))
    historical = legacy_receipt["recovery_evidence"]
    legacy_chat = Map.put(current_chat, "context_reader_json", Jason.encode!(historical["locator"]))
    refute File.exists?(historical["locator"]["cwd"])
    assert TicketReworkRecovery.valid?(legacy_command, input, legacy_chat)
    historical_native = %{native | "turns" => [historical["turn"]]}
    assert :none = TicketReworkRecovery.prepare(historical_native, legacy_chat, current_run, current_context)
    assert {:ok, ^command} = TicketChatCommands.get(ctx.store, command["command_key"])

    for altered <- [Map.put(input, "client_id", "other"), Map.put(input, "body", "Different intent"), Map.put(input, "readback_sha256", "wrong")] do
      refute TicketReworkRecovery.valid?(command, altered, current_chat)
    end

    for raw <- ["{", "null", Jason.encode!(put_in(receipt, ["recovery_evidence", "turn"], nil))] do
      refute TicketReworkRecovery.valid?(Map.put(command, "receipt_json", raw), input, current_chat)
    end

    assert {:ok, []} = TicketChatCommands.recover_failed_preparation(ctx.store, "run", native)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 1
    proof = Map.merge(blocked.proof, %{"command_key" => command["command_key"], "input_key" => command["input_key"]})
    assert {:ok, transferred} = transfer(ctx, %{blocked | proof: proof})
    assert transferred["canonical_path"] == ctx.path
    {:ok, retired} = WorkspaceAccess.get(ctx.store, "reservation")
    transfer_receipt = Jason.decode!(retired["release_receipt_json"]) |> Map.put("new_generation", transferred["generation"])
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.record_rework_transfer(ctx.store, command["command_key"], transfer_receipt)
    assert :ok = TicketChatCommands.validate_rework_replay(ctx.store, command["command_key"])
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = '{}' WHERE command_key = ?", [command["command_key"]])
    assert {:error, _} = TicketChatCommands.validate_rework_replay(ctx.store, command["command_key"])
  end

  test "denied preparation cannot recover stale delegated or competing input", ctx do
    blocked = blocked_initial_writer(ctx, :unstaged)
    valid = denied_native_preparation(ctx, blocked.chat)
    [turn] = valid["turns"]

    for changed <- [
          put_in(valid, ["turns", Access.at(0), "status"], "inProgress"),
          update_in(valid, ["turns", Access.at(0), "items"], &(&1 ++ [%{"type" => "functionCallOutput", "name" => "send_message_to_thread"}])),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(1), "exitCode"], 1),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(2), "aggregatedOutput"], "Some unrelated permission denial"),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(0), "content"], [%{"type" => "text", "text" => "Please infer my intent"}]),
          Map.put(valid, "turns", [turn, %{turn | "id" => "newer", "startedAt" => turn["completedAt"] + 1, "status" => "inProgress"}])
        ] do
      assert {:ok, []} = TicketChatCommands.recover_failed_preparation(ctx.store, "run", changed)
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
    end

    assert {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", valid)
    {:ok, _} = SymphonyElixir.TicketChatFixture.stage(ctx, "competing", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    assert {:ok, []} = TicketChatCommands.recover_failed_preparation(ctx.store, "run", valid)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{implementation_iteration: 1})
    assert {:ok, []} = TicketChatCommands.recover_failed_preparation(ctx.store, "run", valid)
  end

  for drift <- [:head, :base, :binding, :iteration, :unstopped, :competing, :native_input, :new_expected_sha] do
    test "initial blocked transfer rejects #{drift} drift without releasing source", ctx do
      blocked = blocked_initial_writer(ctx)
      blocked = drift(ctx, blocked, unquote(drift))
      assert {:error, _} = transfer(ctx, blocked)
      assert {:ok, unchanged} = WorkspaceAccess.get(ctx.store, "reservation")
      assert unchanged == blocked.access
      assert {:error, :unknown_workspace_reservation} = WorkspaceAccess.get(ctx.store, "resumed")
    end
  end

  test "malformed and non-object source bindings reject transfer without retiring ownership", ctx do
    blocked = blocked_initial_writer(ctx)

    for raw <- ["{", "[]", "null", "42"] do
      Store.query!(ctx.store, "UPDATE workspace_access SET binding_json = ? WHERE reservation_key = 'reservation'", [raw])
      {:ok, before} = WorkspaceAccess.get(ctx.store, "reservation")
      assert {:error, _} = transfer(ctx, blocked)
      assert {:ok, ^before} = WorkspaceAccess.get(ctx.store, "reservation")
      assert {:error, :unknown_workspace_reservation} = WorkspaceAccess.get(ctx.store, "resumed")
    end
  end

  defp blocked_initial_writer(ctx, mode \\ :staged) do
    chat = bind_parent(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: if(mode == :capability, do: ctx.sha, else: nil)})
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx[:base_sha] || ctx.sha)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})
    {:ok, access} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
    {:ok, task} = TaskLedger.get(ctx.store, "writer")

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "reservation:request",
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "input_sha256" => task["prompt_sha256"],
        "owner_id" => "owned-invocation",
        "schema" => StageSchemas.for_stage(:native_feature_writer),
        "policy" => policy
      })

    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, "reservation:request")
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, "reservation:request", "worker", policy)
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, "reservation:request", process_receipt())
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, "reservation:request", "worker", "turn")
    output = blocked_output(ctx, mode)
    {:ok, _} = WorkerEvidence.record_result(ctx.store, "reservation:request", %{thread_id: "worker", turn_id: "turn", item_id: "final", output: output})
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, "reservation:request", "owned-invocation", stop_receipt(ctx))
    {:ok, _} = WorkerEvidence.adopt_completed(ctx.store, "reservation:request")
    context = %{store: ctx.store, workspace_root: Path.join(ctx.root, "workspaces"), factory: %{ticket_supervisor: %{}}}
    assert {:ok, %{status: "BLOCKED"}} = Scheduler.ticket_step(context, "run", opts(ctx))
    disposition = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE run_id = 'run' AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'") |> Map.fetch!("payload_json") |> Jason.decode!()

    if mode in [:unstaged, :io, :capability] do
      %{access: access, evidence: WorkerEvidence.get(ctx.store, "reservation:request") |> elem(1), proof: disposition, attrs: attrs(ctx, "SOURCE", "resumed"), chat: chat}
    else
      body = "Rework the current candidate."
      {:ok, command} = SymphonyElixir.TicketChatFixture.stage(ctx, "initial-rework", body, [%{"operation" => "request_rework"}])
      readback = SymphonyElixir.TicketChatFixture.native(Map.merge(ctx, %{cwd: chat["cwd"], chat: chat}), [body])
      assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
      {:ok, command} = TicketChatCommands.get(ctx.store, command["command_key"])
      disposition = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE run_id = 'run' AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'") |> Map.fetch!("payload_json") |> Jason.decode!()
      {:ok, evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
      proof = Map.merge(disposition, %{"command_key" => command["command_key"], "input_key" => command["input_key"]})
      %{access: access, evidence: evidence, proof: proof, attrs: attrs(ctx, "SOURCE", "resumed")}
    end
  end

  defp blocked_output(ctx, :io) do
    alias SymphonyElixir.Factory.WorkerFileTools
    {:ok, cap} = WorkerFileTools.bind(ctx.store, "reservation:request", "owned-invocation")
    hash = :crypto.hash(:sha256, "base\n") |> Base.encode16(case: :lower)
    identity = %{"threadId" => "worker", "turnId" => "turn", "callId" => "write", "tool" => "repo_write"}
    assert %{"success" => true} = WorkerFileTools.execute(cap, "repo_write", %{"path" => "fixture.txt", "expected_sha256" => hash, "content" => "partial implementation\n"}, identity)
    %{"status" => "BLOCKED", "changed_paths" => ["fixture.txt"], "commit_message" => nil, "blockers" => ["file_worker_helper_exit_unproven; file_worker_edit_reconciliation_required"], "checks" => []}
  end

  defp blocked_output(ctx, :capability) do
    alias SymphonyElixir.Factory.WorkerFileTools
    {:ok, cap} = WorkerFileTools.bind(ctx.store, "reservation:request", "owned-invocation")

    for {call, path, before, after_text} <- [
          {"first", "fixture.txt", "base\n", "intermediate\n"},
          {"second", "fixture.txt", "intermediate\n", "partial implementation\n"},
          {"third", "second.txt", "base\n", "second partial\n"},
          {"fourth", "third.txt", "base\n", "third partial\n"}
        ] do
      hash = :crypto.hash(:sha256, before) |> Base.encode16(case: :lower)
      identity = %{"threadId" => "worker", "turnId" => "turn", "callId" => call, "tool" => "repo_write"}
      assert %{"success" => true} = WorkerFileTools.execute(cap, "repo_write", %{"path" => path, "expected_sha256" => hash, "content" => after_text}, identity)
    end

    %{
      "status" => "BLOCKED",
      "changed_paths" => ["fixture.txt", "second.txt", "third.txt"],
      "commit_message" => nil,
      "blockers" => ["Exact contract-base contents are unavailable through the permitted repository tools."],
      "checks" => []
    }
  end

  defp blocked_output(_ctx, _mode), do: %{"status" => "BLOCKED", "changed_paths" => [], "commit_message" => nil, "blockers" => ["Instruction access unavailable"], "checks" => []}

  defp capability_observation(ctx, blocked) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    raw = %{
      "data" => [
        %{
          "id" => "turn",
          "status" => "completed",
          "error" => nil,
          "items" => [
            %{"type" => "agentMessage", "phase" => "final_answer", "text" => "The permitted tools cannot read the required contract-base files."},
            %{"type" => "agentMessage", "phase" => "final_answer", "text" => blocked.evidence["output_json"]}
          ]
        }
      ]
    }

    hash = fn value -> :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower) end
    queue_raw = %{"data" => [], "nextCursor" => nil}

    native = %{
      "id" => "worker",
      "cwd" => ctx.path,
      "status" => %{"type" => "idle"},
      "updatedAt" => 10,
      "latest_turn_observation" => %{
        "mode" => "LATEST_DESC",
        "parameters" => %{"threadId" => "worker", "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
        "updated_at" => 10,
        "raw_response" => raw,
        "sha256" => hash.(raw),
        "observed_at" => now,
        "confirmation" => %{"raw_response" => raw, "sha256" => hash.(raw), "observed_at" => now}
      },
      "queue_observation" => %{
        "thread_id" => "worker",
        "empty_complete" => true,
        "count_lower_bound" => 0,
        "has_more" => false,
        "raw_response" => queue_raw,
        "sha256" => hash.(queue_raw),
        "observed_at" => now
      }
    }

    database = Path.join(ctx.root, "queue.sqlite")

    schema =
      "CREATE TABLE queued_items (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL, queue_order INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);CREATE TABLE queued_thread_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL UNIQUE);"

    triggers =
      Enum.map_join([{"insert", "NEW"}, {"update", "NEW"}, {"delete", "OLD"}], fn {event, row} ->
        "CREATE TRIGGER queued_items_revision_after_#{event} AFTER #{String.upcase(event)} ON queued_items BEGIN INSERT INTO queued_thread_revisions (thread_id) VALUES (#{row}.thread_id) ON CONFLICT(thread_id) DO UPDATE SET revision = (SELECT COALESCE(MAX(revision),0)+1 FROM queued_thread_revisions); END;"
      end)

    {_, 0} = System.cmd("/usr/bin/sqlite3", [database, schema <> triggers])
    home = Path.join(ctx.root, "native-home")
    File.mkdir_p!(Path.join(home, "thread-writer-locks"))
    {native, [native_queue_database: database, native_home: home]}
  end

  defp denied_native_preparation(ctx, chat) do
    workflow = Path.join(ctx.root, "WORKFLOW-reader.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\n")
    {:ok, locator_json} = SymphonyElixir.Factory.TicketContextReader.bind(ctx.store, "run", ticket_cli_root: File.cwd!(), ticket_workflow: workflow)
    Store.query!(ctx.store, "UPDATE ticket_chats SET context_reader_json = ? WHERE chat_key = ?", [locator_json, chat["chat_key"]])
    {:ok, chat} = SymphonyElixir.Factory.TicketChat.for_run(ctx.store, "run")
    locator = Jason.decode!(locator_json)
    {:ok, context} = SymphonyElixir.Factory.TicketContext.context(ctx.store, "run")
    started = System.system_time(:millisecond) / 1000 - 10
    item = %{"type" => "userMessage", "id" => "direct-human", "clientId" => "direct-client", "content" => [%{"type" => "text", "text" => "Rework the current candidate."}]}

    refresh = %{
      "id" => "refresh",
      "type" => "commandExecution",
      "status" => "completed",
      "exitCode" => 0,
      "cwd" => locator["cwd"],
      "commandActions" => [%{"type" => "unknown", "command" => locator["command"]}],
      "aggregatedOutput" => Jason.encode!(context)
    }

    failed = %{
      "id" => "failed-prepare",
      "type" => "commandExecution",
      "status" => "failed",
      "exitCode" => 1,
      "cwd" => locator["cwd"],
      "commandActions" => [%{"type" => "unknown", "command" => "#{SymphonyElixir.Factory.TicketContextReader.cli_prefix()} prepare-stage run --workflow #{workflow}"}],
      "aggregatedOutput" => "Error: Operation not permitted (os error 1)\n** (Mix) Ticket operation failed: {:port_exit, 1}"
    }

    %{
      "id" => chat["thread_id"],
      "cwd" => chat["cwd"],
      "projectId" => nil,
      "turns" => [%{"id" => "failed-human-turn", "status" => "completed", "startedAt" => started, "completedAt" => started + 1, "items" => [item, refresh, failed]}]
    }
  end

  defp legacy_recovery_receipt(receipt) do
    proof = receipt["recovery_evidence"]
    locator = proof["locator"] |> Map.update!("cwd", &Path.join(&1, "retired-reader"))
    encoded = locator["arguments"] |> Jason.encode!() |> Base.encode64()
    refresh = "mise exec -- elixir -pa \"_build/dev/lib/*/ebin\" -e 'Mix.start(); Mix.Tasks.Factory.Ticket.run(Jason.decode!(Base.decode64!(\"#{encoded}\")))'"
    prefix = "mise exec -- elixir -pa \"_build/dev/lib/*/ebin\" -S mix factory.ticket"

    items =
      Enum.map(proof["turn"]["items"], fn
        %{"id" => "refresh"} = item ->
          %{item | "cwd" => locator["cwd"], "commandActions" => [%{"type" => "unknown", "command" => refresh}]}

        %{"id" => "failed-prepare"} = item ->
          %{item | "cwd" => locator["cwd"], "commandActions" => [%{"type" => "unknown", "command" => "#{prefix} prepare-stage run --workflow #{locator["workflow"]}"}]}

        item ->
          item
      end)

    legacy = proof |> Map.put("locator", Map.put(locator, "command", refresh)) |> put_in(["turn", "items"], items)
    receipt |> Map.put("recovery_evidence", legacy) |> Map.put("recovery_sha256", :crypto.hash(:sha256, Jason.encode!(legacy)) |> Base.encode16(case: :lower))
  end

  defp transfer(ctx, blocked), do: WorkspaceAccess.transfer_blocked_source(ctx.store, "reservation", blocked.access["generation"], blocked.attrs, blocked.proof)

  defp drift(ctx, blocked, :head) do
    tree = git(ctx.path, ["write-tree"]) |> String.trim()
    sha = git(ctx.path, ["commit-tree", tree, "-p", ctx.sha, "-m", "drift"]) |> String.trim()
    git(ctx.path, ["update-ref", "HEAD", sha])
    blocked
  end

  defp drift(ctx, blocked, :base) do
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha = ? WHERE run_id = 'run'", [String.duplicate("f", 40)])
    blocked
  end

  defp drift(ctx, blocked, :binding) do
    binding = Jason.decode!(blocked.evidence["binding_json"]) |> Map.put("base_sha", String.duplicate("f", 40)) |> Jason.encode!()

    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = ?, binding_sha256 = ? WHERE request_key = 'reservation:request'", [
      binding,
      :crypto.hash(:sha256, binding) |> Base.encode16(case: :lower)
    ])

    blocked
  end

  defp drift(ctx, blocked, :iteration) do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{implementation_iteration: 1})
    blocked
  end

  defp drift(ctx, blocked, :unstopped) do
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at = NULL WHERE request_key = 'reservation:request'")
    blocked
  end

  defp drift(ctx, blocked, :competing) do
    register(ctx, "other", "PPL-124", "other-writer", ctx.path)
    blocked
  end

  defp drift(ctx, blocked, :native_input) do
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET thread_id = 'foreign-parent' WHERE input_key = ?", [blocked.proof["input_key"]])
    blocked
  end

  defp drift(_ctx, blocked, :new_expected_sha), do: %{blocked | attrs: Map.put(blocked.attrs, "expected_sha", String.duplicate("f", 40))}
end
