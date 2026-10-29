defmodule SymphonyElixir.FactoryNativeRuntimeCompatibilityTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.Factory.NativeRuntimeCompatibility, as: Compatibility
  alias Exqlite.Sqlite3

  setup do
    root = Path.join(System.tmp_dir!(), "admission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @tag :native_v2_admission
  test "supported mixed history opens through both ledger boundaries without restoring historical roots", ctx do
    origin = %{
      "version" => 2,
      "codex_home" => %{"path" => "/historical/removed/codex", "device" => [1, 2], "inode" => 3, "uid" => 501},
      "sqlite_home" => %{"path" => "/historical/removed/sqlite", "device" => [1, 2], "inode" => 4, "uid" => 501}
    }

    binding = %{"binding_version" => 2, "native_runtime" => origin}
    database = fixture(ctx.root, "mixed-v2", binding)
    connection = Exqlite.start_link(database: database) |> elem(1)
    Store.query!(connection, "PRAGMA foreign_keys=OFF")
    proof = %{"kind" => "NATIVE_COMPLETION_RECEIPT_V2", "version" => 2, "native_runtime" => origin, "native_runtime_sha256" => digest(Jason.encode!(origin))}
    Store.query!(connection, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES ('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED','historical',?,'past')", [Jason.encode!(proof)])

    Store.query!(connection, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES ('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED','historical',?,'past')", [
      ~s({"kind":"NATIVE_COMPLETION_RECEIPT_V1","version":1})
    ])

    GenServer.stop(connection)
    before = data_digest(database)
    assert :ok = Compatibility.check_database(database)
    assert {:ok, :opened} = Store.start_link(database: database) |> close_open()
    assert {:ok, :opened} = Store.start_read_only(database: database) |> close_open()
    assert data_digest(database) == before
    assert :ok = Compatibility.check_factory(%{enabled: true, database: database, ticket_supervisor: %{}})
    factory = startup_factory(ctx.root, database, Path.join(ctx.root, "not-created/{date}")) |> Map.put(:branch_prefix, "bad prefix")

    result =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        SymphonyElixir.Factory.Supervisor.start_link(settings: %{factory: factory}, name: nil)
      end)
      |> Task.await()

    assert result == {:error, {:invalid_factory_policy, :invalid_branch_prefix}}
    refute File.exists?(Path.join(ctx.root, "not-created"))
  end

  @tag :native_v2_admission
  test "new compiled capabilities require an explicit matching declaration and refuse malformed origins", ctx do
    capabilities = %{"worker_binding_versions" => [1, 2], "completion_receipt_versions" => [1, 2]}
    assert Compatibility.supported_formats() === capabilities
    assert :ok = Compatibility.check_manifest(%{"native_runtime_formats" => capabilities})
    assert {:error, :unsupported_native_runtime_formats} = Compatibility.check_manifest(%{})
    assert {:error, :unsupported_native_runtime_formats} = Compatibility.check_manifest(%{"native_runtime_formats" => %{"worker_binding_versions" => [1], "completion_receipt_versions" => [1]}})

    origin = %{
      "version" => 2,
      "codex_home" => %{"path" => "/historical/codex", "device" => [1, 2], "inode" => 3, "uid" => 501},
      "sqlite_home" => %{"path" => "/historical/sqlite", "device" => [1, 2], "inode" => 4, "uid" => 501}
    }

    for malformed <- [Map.put(origin, "version", 2.0), Map.put(origin, "extra", true), put_in(origin, ["codex_home", "path"], "relative"), put_in(origin, ["sqlite_home", "inode"], true)] do
      database = raw_fixture(ctx.root, "invalid-v2-#{System.unique_integer([:positive])}", Jason.encode!(%{"binding_version" => 2, "native_runtime" => malformed}), nil)
      assert {:error, :unsupported_native_runtime_history} = Compatibility.check_database(database)
    end

    for path <- ["//double-leading", "/duplicate//slash", "/dot/./path", "/dot/../path", "/trailing/", "/control\u0085path"] do
      malformed = put_in(origin, ["codex_home", "path"], path)
      assert {:error, :native_runtime_origin_invalid} = SymphonyElixir.Factory.NativeRuntimeRoute.validate_origin_format(malformed)
    end

    for path <- ["/unicode/é", "/unicode/\u200D", "/unicode/\u2028", "/quoted/'\""] do
      valid = put_in(origin, ["codex_home", "path"], path)
      assert :ok = SymphonyElixir.Factory.NativeRuntimeRoute.validate_origin_format(valid)
      database = raw_fixture(ctx.root, "unicode-v2-#{System.unique_integer([:positive])}", Jason.encode!(%{"binding_version" => 2, "native_runtime" => valid}), nil)
      assert :ok = Compatibility.check_database(database)
    end

    for malformed <- [
          nil,
          false,
          [],
          %{},
          Map.delete(origin, "sqlite_home"),
          Map.put(origin, "version", true),
          put_in(origin, ["codex_home", "device"], [1.0, 2]),
          put_in(origin, ["codex_home", "device"], [1, false]),
          put_in(origin, ["codex_home", "inode"], 3.0),
          put_in(origin, ["codex_home", "uid"], true),
          put_in(origin, ["codex_home", "uid"], 501.0)
        ] do
      assert {:error, :native_runtime_origin_invalid} = SymphonyElixir.Factory.NativeRuntimeRoute.validate_origin_format(malformed)
    end

    common = put_in(origin, ["codex_home", "path"], "/historical/é")
    assert digest(Jason.encode!(common)) == "6d92c384eb7c1f38377a3ac0e8acf47e65d3a9c75024b164e181534ec96cc749"
    proof = %{"kind" => "NATIVE_COMPLETION_RECEIPT_V2", "version" => 2, "native_runtime" => common, "native_runtime_sha256" => "6d92c384eb7c1f38377a3ac0e8acf47e65d3a9c75024b164e181534ec96cc749"}
    database = raw_fixture(ctx.root, "common-origin-digest", "{}", Jason.encode!(proof))
    assert :ok = Compatibility.check_database(database)
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @tag :admission_paths
  test "SQLite URI inputs cannot bypass direct writer admission", ctx do
    database = fixture(ctx.root, "uri", %{"native_runtime" => nil})
    {:ok, connection} = Exqlite.start_link(database: database)
    Store.query!(connection, "DROP INDEX one_active_factory_run_per_issue")
    GenServer.stop(connection)
    before = data_digest(database)
    result = File.cd!(ctx.root, fn -> Store.start_link(database: "file:" <> database) |> close_open() end)
    assert data_digest(database) == before
    assert result == {:error, :native_runtime_history_unreadable}
  end

  @tag :admission_paths
  test "invalid relative and symlink reader paths refuse before acquiring SQLite metadata", ctx do
    for kind <- [:relative, :symlink] do
      database = Path.join(ctx.root, "#{kind}.sqlite")
      {:ok, writer} = Sqlite3.open(database)
      :ok = Sqlite3.execute(writer, "PRAGMA journal_mode=WAL; CREATE TABLE worker_evidence(binding_json TEXT); INSERT INTO worker_evidence VALUES('{}')")
      :ok = Sqlite3.close(writer)

      path =
        if kind == :symlink do
          alias_path = database <> "-alias"
          File.ln_s!(database, alias_path)
          alias_path
        else
          Path.join(List.duplicate("..", length(Path.split(File.cwd!())) - 1) ++ tl(Path.split(database)))
        end

      before = sidecars(database)
      assert Store.start_read_only(database: path) == {:error, :existing_factory_ledger_required}
      assert sidecars(database) == before
    end
  end

  @tag :admission_paths
  test "disabled factory ignores unsupported or corrupt unused ledgers without opening them", ctx do
    unsupported = Path.join(ctx.root, "disabled-wal.sqlite")
    {:ok, writer} = Sqlite3.open(unsupported)
    :ok = Sqlite3.execute(writer, "PRAGMA journal_mode=WAL; CREATE TABLE worker_evidence(binding_json TEXT); INSERT INTO worker_evidence VALUES('{\"native_runtime\":null}')")
    :ok = Sqlite3.close(writer)
    corrupt = Path.join(ctx.root, "disabled-corrupt.sqlite")
    File.write!(corrupt, "unreadable as SQLite")

    for database <- [unsupported, corrupt] do
      before = {File.read!(database), sidecars(database)}
      factory = %{enabled: false, database: database, ticket_supervisor: %{}}
      assert :ignore = SymphonyElixir.Factory.Supervisor.start_link(settings: %{factory: factory})
      workflow = Path.join(ctx.root, "disabled-#{System.unique_integer([:positive])}.md")
      File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  enabled: false\n  database: #{Jason.encode!(database)}\n---\nSynthetic\n")
      assert :ok = Compatibility.check_workflow(workflow)
      assert {File.read!(database), sidecars(database)} == before
    end
  end

  test "finite native formats admit legacy maps and strict V1 receipts without rewriting bytes", ctx do
    for {binding, receipt} <- [
          {"{}", ~s({"kind":"NATIVE_COMPLETION_RECEIPT_V1","version":1})},
          {~s({ "unknown_legacy_field" : "retained" }), ~s({ "kind":"NATIVE_COMPLETION_RECEIPT_V1", "version":1, "legacy_extra":true })}
        ] do
      database = raw_fixture(ctx.root, "legacy-#{System.unique_integer([:positive])}", binding, receipt)
      before = data_digest(database)
      assert :ok = Compatibility.check_database(database)
      assert data_digest(database) == before
    end

    assert Compatibility.supported_formats() == %{"worker_binding_versions" => [1, 2], "completion_receipt_versions" => [1, 2]}
    assert {:error, :unsupported_native_runtime_formats} = Compatibility.check_manifest(%{})
    assert :ok = Compatibility.check_manifest(%{"native_runtime_formats" => Compatibility.supported_formats()})

    for bad <- [
          nil,
          [],
          %{},
          %{"worker_binding_versions" => [1], "completion_receipt_versions" => [2]},
          %{"worker_binding_versions" => [true], "completion_receipt_versions" => [1]},
          %{"worker_binding_versions" => [1.0], "completion_receipt_versions" => [1]},
          Map.put(Compatibility.supported_formats(), "extra", [1])
        ] do
      assert {:error, :unsupported_native_runtime_formats} = Compatibility.check_manifest(%{"native_runtime_formats" => bad})
    end
  end

  test "every explicitly versioned routed malformed or scalar historical binding refuses", ctx do
    values = [nil, false, 1, 2, 2.0, "future", %{}]
    bindings = for key <- ~w(binding_version native_runtime), value <- values, do: Jason.encode!(%{key => value})

    for json <- bindings ++ ["null", "[]", "42", "{malformed"] do
      database = raw_fixture(ctx.root, "binding-#{System.unique_integer([:positive])}", json, nil)
      before = data_digest(database)
      assert {:error, :unsupported_native_runtime_history} = Compatibility.check_database(database)
      assert data_digest(database) == before
    end
  end

  test "receipt-only history requires strict integer V1 identity and no downgraded runtime fields", ctx do
    valid = %{"kind" => "NATIVE_COMPLETION_RECEIPT_V1", "version" => 1}
    receipts = for version <- [nil, true, 1.0, 2, 2.0, "1"], do: Jason.encode!(Map.put(valid, "version", version))

    receipts =
      receipts ++ Enum.map([%{}, Map.put(valid, "kind", "NATIVE_COMPLETION_RECEIPT_V2"), Map.put(valid, "native_runtime", nil), Map.put(valid, "native_runtime_sha256", nil)], &Jason.encode!/1)

    for json <- receipts ++ ["null", "[]", "false", "{malformed"] do
      database = raw_fixture(ctx.root, "receipt-#{System.unique_integer([:positive])}", nil, json)
      before = data_digest(database)
      assert {:error, :unsupported_native_runtime_history} = Compatibility.check_database(database)
      assert data_digest(database) == before
    end
  end

  test "absent empty and older ledgers are admitted but unreadable or incomplete existing history refuses", ctx do
    assert :ok = Compatibility.check_database(:memory)
    assert :ok = Compatibility.check_database(":memory:")
    missing = Path.join(ctx.root, "not-created/new.sqlite")
    assert :ok = Compatibility.check_database(missing)
    refute File.exists?(Path.dirname(missing))
    empty = Path.join(ctx.root, "empty.sqlite")
    File.write!(empty, "")
    assert :ok = Compatibility.check_database(empty)
    assert File.read!(empty) == ""

    for {name, sql, expected} <- [
          {"older", "CREATE TABLE old_history(value TEXT)", :ok},
          {"unrelated", "CREATE TABLE events(event_type TEXT,payload_json TEXT); INSERT INTO events VALUES('UNRELATED','{not-json')", :ok},
          {"binding-columns", "CREATE TABLE worker_evidence(status TEXT)", {:error, :native_runtime_history_unreadable}},
          {"event-columns", "CREATE TABLE events(event_type TEXT)", {:error, :native_runtime_history_unreadable}},
          {"view", "CREATE VIEW worker_evidence AS SELECT '{}' AS binding_json", {:error, :native_runtime_history_unreadable}}
        ] do
      database = Path.join(ctx.root, name <> ".sqlite")
      {:ok, writer} = Sqlite3.open(database)
      :ok = Sqlite3.execute(writer, sql)
      :ok = Sqlite3.close(writer)
      before = data_digest(database)
      assert Compatibility.check_database(database) == expected
      assert data_digest(database) == before
    end

    assert {:error, :native_runtime_history_unreadable} = Compatibility.check_database(ctx.root)
    corrupt = Path.join(ctx.root, "corrupt.sqlite")
    File.write!(corrupt, "not a SQLite database")
    assert {:error, :native_runtime_history_unreadable} = Compatibility.check_database(corrupt)
    assert File.read!(corrupt) == "not a SQLite database"
  end

  test "SQLite case-insensitive object names cannot hide native history", ctx do
    for {table, index} <- Enum.with_index(["WORKER_EVIDENCE", "WoRkEr_EvIdEnCe", "EVENTS", "EvEnTs"]) do
      database = Path.join(ctx.root, "case-#{index}.sqlite")
      {:ok, writer} = Sqlite3.open(database)

      sql =
        if String.downcase(table) == "worker_evidence" do
          "CREATE TABLE #{table}(binding_json TEXT); INSERT INTO #{table} VALUES('{\"native_runtime\":null}')"
        else
          "CREATE TABLE #{table}(event_type TEXT,payload_json TEXT); INSERT INTO #{table} VALUES('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED','{\"kind\":\"NATIVE_COMPLETION_RECEIPT_V2\",\"version\":2}')"
        end

      :ok = Sqlite3.execute(writer, sql)
      :ok = Sqlite3.close(writer)
      before = data_digest(database)
      assert {:error, :unsupported_native_runtime_history} = Compatibility.check_database(database)
      assert data_digest(database) == before
    end
  end

  test "reserved runtime configuration refuses false null and malformed values before any factory effect", ctx do
    for reserved <- [false, nil, true, %{}, [], "future"] do
      policy = %{"enabled" => true, "native_runtime" => reserved, "parent_output_root" => Path.join(ctx.root, "dated/{date}")}
      factory = %{enabled: false, database: Path.join(ctx.root, "absent/ledger.sqlite"), ticket_supervisor: policy}
      assert {:error, {:invalid_factory_policy, :unsupported_native_runtime_configuration}} = SymphonyElixir.Factory.Supervisor.start_link(settings: %{factory: factory})
      assert {:error, :unsupported_native_runtime_configuration} = Compatibility.check_factory(%{factory | ticket_supervisor: %{native_runtime: reserved}})
      workflow = Path.join(ctx.root, "selected-#{System.unique_integer([:positive])}.md")
      File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  enabled: false\n  ticket_supervisor:\n    native_runtime: #{Jason.encode!(reserved)}\n---\nSynthetic\n")
      assert {:error, :unsupported_native_runtime_configuration} = Compatibility.check_workflow(workflow)
    end

    refute File.exists?(Path.join(ctx.root, "dated"))
    refute File.exists?(Path.join(ctx.root, "absent"))
    assert :ignore = SymphonyElixir.Factory.Supervisor.start_link(settings: %{factory: %{enabled: false, database: nil, ticket_supervisor: %{}}})
  end

  test "current unsupported history committed only in WAL is refused without main or WAL-payload mutation", ctx do
    database = Path.join(ctx.root, "held-wal.sqlite")
    {:ok, writer} = Sqlite3.open(database)

    try do
      :ok = Sqlite3.execute(writer, "PRAGMA journal_mode=WAL; CREATE TABLE worker_evidence(binding_json TEXT,status TEXT); INSERT INTO worker_evidence VALUES('{\"native_runtime\":null}','CONSUMED')")
      assert File.read!(database <> "-wal") =~ "native_runtime"
      refute File.read!(database) =~ "native_runtime"
      before = data_digest(database)
      metadata_before = sidecars(database)
      assert {:error, :unsupported_native_runtime_history} = Compatibility.check_database(database)
      assert data_digest(database) == before
      IO.puts(Jason.encode!(%{fixture: "held-wal", lock_metadata_before: metadata_before, lock_metadata_after: sidecars(database), ledger_payload_unchanged: true}))
    after
      :ok = Sqlite3.close(writer)
    end
  end

  test "closed WAL-mode legacy database permits SQLite locking metadata without logical writes", ctx do
    database = Path.join(ctx.root, "closed-wal.sqlite")
    {:ok, writer} = Sqlite3.open(database)
    :ok = Sqlite3.execute(writer, "PRAGMA journal_mode=WAL; CREATE TABLE worker_evidence(binding_json TEXT); INSERT INTO worker_evidence VALUES('{}')")
    :ok = Sqlite3.close(writer)
    refute File.exists?(database <> "-wal")
    refute File.exists?(database <> "-shm")
    before = File.read!(database)
    assert :ok = Compatibility.check_database(database)
    assert File.read!(database) == before
    if File.exists?(database <> "-wal"), do: assert(File.stat!(database <> "-wal").size == 0)
    IO.puts(Jason.encode!(%{fixture: "closed-wal", lock_metadata_after: sidecars(database), ledger_payload_unchanged: true}))
  end

  for {kind, payload} <- [
        {"consumed-binding", %{"native_runtime" => nil}},
        {"historical-receipt", %{"kind" => "NATIVE_COMPLETION_RECEIPT_V2", "version" => 2}}
      ] do
    @tag :admission_boundary
    test "writable ledger opening refuses #{kind} before initialization can change schema", ctx do
      database = fixture(ctx.root, unquote(kind), unquote(Macro.escape(payload)))
      {:ok, connection} = Exqlite.start_link(database: database)
      Store.query!(connection, "DROP INDEX one_active_factory_run_per_issue")
      GenServer.stop(connection)
      before = data_digest(database)
      result = Store.start_link(database: database) |> close_open()
      assert data_digest(database) == before
      assert result == {:error, :unsupported_native_runtime_history}
    end
  end

  @tag :admission_boundary
  test "read-only opening rejects consumed unsupported history before a broker continuation", ctx do
    database = fixture(ctx.root, "read-only", %{"native_runtime" => nil})
    owner = self()

    result =
      case Store.start_read_only(database: database) do
        {:ok, connection} ->
          send(owner, :broker_continued)
          GenServer.stop(connection)
          {:ok, :opened}

        error ->
          error
      end

    assert result == {:error, :unsupported_native_runtime_history}
    refute_received :broker_continued
  end

  @tag :admission_boundary
  test "factory startup rejects unsupported history before dated-directory and native-probe effects", ctx do
    database = fixture(ctx.root, "startup", %{"native_runtime" => nil})
    sentinel = Path.join(ctx.root, "probe-started")
    probe = Path.join(ctx.root, "fake-probe")
    File.write!(probe, "#!/bin/sh\nprintf 'started' > '#{sentinel}'\nexit 7\n")
    File.chmod!(probe, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.root, codex_command: "#{probe} app-server")
    dated = Path.join(ctx.root, "must-not-exist/{date}")
    factory = startup_factory(ctx.root, database, dated)
    before = data_digest(database)

    result =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        SymphonyElixir.Factory.Supervisor.start_link(settings: %{factory: factory}, name: nil)
      end)
      |> Task.await()

    assert result == {:error, {:invalid_factory_policy, :unsupported_native_runtime_history}}
    refute File.exists?(sentinel)
    refute File.exists?(Path.join(ctx.root, "must-not-exist"))
    assert data_digest(database) == before
  end

  defp fixture(root, name, payload) do
    database = Path.join(root, name <> ".sqlite")
    connection = start_supervised!({Store, database: database}, id: {:fixture, name})
    Store.query!(connection, "PRAGMA foreign_keys=OFF")

    if Map.has_key?(payload, "kind") do
      Store.query!(connection, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED','historical',?,'past')", [Jason.encode!(payload)])
    else
      Store.query!(
        connection,
        "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,owner_id,created_at) VALUES('old','old','historical','old',?,'retained','CONSUMED','stopped','past')",
        [Jason.encode!(payload)]
      )
    end

    database
  end

  defp raw_fixture(root, name, binding, receipt) do
    database = Path.join(root, name <> ".sqlite")
    {:ok, writer} = Sqlite3.open(database)

    if binding do
      :ok = Sqlite3.execute(writer, "CREATE TABLE worker_evidence(binding_json TEXT,status TEXT)")
      :ok = Sqlite3.execute(writer, "INSERT INTO worker_evidence VALUES('" <> String.replace(binding, "'", "''") <> "','CONSUMED')")
    end

    if receipt do
      :ok = Sqlite3.execute(writer, "CREATE TABLE events(event_type TEXT,payload_json TEXT)")
      :ok = Sqlite3.execute(writer, "INSERT INTO events VALUES('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED','" <> String.replace(receipt, "'", "''") <> "')")
    end

    :ok = Sqlite3.close(writer)
    database
  end

  defp sidecars(database) do
    Map.new(["-wal", "-shm"], fn suffix ->
      path = database <> suffix

      {suffix,
       case File.read(path) do
         {:ok, bytes} -> %{bytes: byte_size(bytes), sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
         {:error, :enoent} -> nil
       end}
    end)
  end

  defp data_digest(database) do
    Map.new([database, database <> "-wal"], fn path ->
      {Path.basename(path), if(File.exists?(path), do: :crypto.hash(:sha256, File.read!(path)), else: nil)}
    end)
  end

  defp startup_factory(root, database, dated) do
    roles =
      ~w(orchestrator orchestrator-intake specification-author specification-critic feature-planner feature-writer feature-writer-high-risk change-verifier manual-validator explorer failure-triager)

    %{
      enabled: true,
      database: database,
      branch_prefix: "fixture",
      queue: %{"assignee" => "currentUser()", "statuses" => ["READY"], "factory_labels" => ["ai-ready"]},
      repositories: %{"fixture" => %{"path" => root, "base_branch" => "master", "codex_project_id" => "fixture", "gitlab_project" => "fixture/repo", "route_labels" => ["fixture"]}},
      models: %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"test" => "gpt-test"}},
        "roles" => Map.new(roles, &{&1, %{"provider" => "codex", "model_class" => "test", "reasoning_effort" => "medium"}}),
        "delivery_routing" => %{"default_role" => "feature-writer", "high_risk_role" => "feature-writer-high-risk", "high_risk_values" => ["high"], "unknown_risk_is_high" => true}
      },
      cleanup: %{},
      hibernation: %{},
      manual_validation: %{
        "enabled" => true,
        "allowed_environments" => ["cpp-test"],
        "require_slack_coordination" => true,
        "allow_production" => false,
        "allow_database_ddl" => false,
        "required_apps" => ["fixture-app"]
      },
      ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"], "parent_output_root" => dated}
    }
  end

  defp close_open({:ok, connection}) do
    GenServer.stop(connection)
    {:ok, :opened}
  end

  defp close_open(error), do: error
end
