defmodule SymphonyElixir.FactoryPushRequalificationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{RunLedger, Store, TicketPush, TicketPushRequalification}

  setup do
    root = Path.join(System.tmp_dir!(), "push-requalification-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    database = Path.join(root, "factory.sqlite")
    store = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm_rf!(root) end)
    %{store: store, database: database}
  end

  @tag push_empty_authorization: true
  test "public push without a configured authorization preserves the ordinary stage gate", ctx do
    assert {:ok, _} = RunLedger.register(ctx.store, %{run_id: "run", issue_key: "PPL-123", kind: "DELIVERY", state: "WRITING"})
    assert {:error, :ticket_push_stage_invalid} = TicketPush.step(ctx.store, "run", %{}, [])
    assert Store.query!(ctx.store, "SELECT * FROM ticket_push_prepared_requalifications").rows == []
  end

  test "schema 53 adds a separate immutable one-use prepared requalification journal", ctx do
    assert Store.one!(ctx.store, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 54
    assert Store.query!(ctx.store, "SELECT * FROM ticket_push_prepared_requalifications").rows == []
    triggers = Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'push_prepared_requalification_%' ORDER BY name").rows
    assert length(triggers) == 3
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'push_prepared_requalification_%' ORDER BY name").rows == triggers
    assert {:ok, read_only} = Store.start_read_only(database: ctx.database)
    GenServer.stop(read_only)
  end

  test "journal grammar rejects coherently rehashed authorization and issuance substitutions" do
    row = journal_fixture()
    assert :ok = TicketPushRequalification.validate(row)

    for {field, value} <- [
          {"maximum_implementation_iterations", 0},
          {"maximum_implementation_iterations", true},
          {"maximum_code_repair_rounds", 11},
          {"maximum_code_repair_rounds", true},
          {"spec_revision", 0},
          {"candidate_sha", String.duplicate("z", 40)},
          {"contract_sha256", "wrong"},
          {"authorization_reference", ""},
          {"authorization_reference", String.duplicate("x", 1025)}
        ] do
      authorization = Jason.decode!(row["authorization_json"]) |> Map.put(field, value)
      proof = Jason.decode!(row["proof_json"])
      limits = Map.take(authorization, ~w(maximum_implementation_iterations maximum_code_repair_rounds))
      changed = row |> encoded_field("authorization", authorization) |> encoded_field("proof", Map.put(proof, "configured_limits", limits))

      assert {:error, :push_requalification_journal_unproven} =
               TicketPushRequalification.validate(changed),
             inspect({field, value})
    end

    for {field, value} <- [{"phase", "PUSH_UNCERTAIN"}, {"helper_pid", 123}, {"execution_json", "{}"}, {"receipt_json", "{}"}, {"remote_sha", String.duplicate("a", 40)}] do
      original = Jason.decode!(row["original_envelope"]) |> Map.put(field, value)
      raw = Jason.encode!(original)
      changed = Map.merge(row, %{"original_envelope" => raw, "original_sha256" => digest(raw)})
      assert {:error, :push_requalification_journal_unproven} = TicketPushRequalification.validate(changed)
    end

    for key <- ["", String.duplicate("é", 129)] do
      assert {:error, :push_requalification_journal_unproven} = TicketPushRequalification.validate(Map.put(row, "authorization_key", key))
    end
  end

  test "populated schema 52 migrates once without changing existing rowids or bytes", ctx do
    assert {:ok, _} = RunLedger.register(ctx.store, %{run_id: "retained", issue_key: "PPL-123", kind: "DELIVERY", state: "WRITING"})
    before = Store.query!(ctx.store, "SELECT rowid,* FROM runs ORDER BY rowid").rows
    schema_52(ctx.store)
    tasks = for _ <- 1..2, do: Task.async(fn -> Store.initialize(ctx.store) end)
    for task <- tasks, do: assert(:ok = Task.await(task, 30_000))
    assert Store.query!(ctx.store, "SELECT rowid,* FROM runs ORDER BY rowid").rows == before
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations WHERE version=53").rows == [[53]]
    assert :ok = Store.initialize(ctx.store)
  end

  test "independent history grammar refuses coherent invalid authorizations without executing", ctx do
    row = journal_fixture()
    assert :ok = TicketPushRequalification.validate(row)
    path = Path.join(Path.dirname(ctx.database), "physical-grammar.json")
    File.write!(path, Jason.encode!(row))

    script = """
    import importlib.util,json,pathlib,sqlite3,sys
    spec=importlib.util.spec_from_file_location('history',sys.argv[1]);history=importlib.util.module_from_spec(spec);spec.loader.exec_module(history)
    history.subprocess.run=lambda *args,**kwargs: (_ for _ in ()).throw(AssertionError('child issuance forbidden'))
    row=json.loads(pathlib.Path(sys.argv[2]).read_text());original=json.loads(row['original_envelope']);binding=json.loads(row['successor_binding_json']);proof=json.loads(row['proof_json'])
    connection=sqlite3.connect(':memory:');connection.row_factory=sqlite3.Row
    connection.execute('CREATE TABLE ticket_push_prepared_requalifications ('+','.join(key+' TEXT' for key in row)+')')
    connection.execute('INSERT INTO ticket_push_prepared_requalifications VALUES ('+','.join('?' for _ in row)+')',list(row.values()))
    saved=proof['original_access'];old=dict(saved,released_at=row['created_at'],release_receipt_json=row['proof_json'])
    new=dict(saved,reservation_key=row['successor_reservation_key'],request_key=row['successor_reservation_key'],generation=43)
    connection.execute('CREATE TABLE workspace_access ('+','.join(key+(' INTEGER' if key=='generation' else ' TEXT') for key in saved)+')')
    for access in (old,new):connection.execute('INSERT INTO workspace_access VALUES ('+','.join('?' for _ in saved)+')',[access[key] for key in saved])
    execution=dict(proof['spool'],invocation=row['successor_nonce'],intent_json=row['successor_binding_json'],intent_sha256=row['successor_binding_sha256'])
    history.validate_prepared_requalification(connection,execution,binding,{'run_id':'run'})
    retired=dict(execution,invocation=row['original_nonce'],intent_json=original['binding_json'],intent_sha256=original['binding_sha256'])
    try:history.validate_prepared_requalification(connection,retired,json.loads(original['binding_json']),{'run_id':'run'})
    except ValueError:pass
    else:raise AssertionError('retired original nonce accepted')
    for field,value in [('maximum_implementation_iterations',0),('maximum_implementation_iterations',True),('maximum_code_repair_rounds',11),('maximum_code_repair_rounds',True),('spec_revision',0),('authorization_reference',''),('candidate_sha','z'*40)]:
        authorization=json.loads(row['authorization_json']);authorization[field]=value
        changed=json.loads(row['proof_json']);changed['configured_limits']={key:authorization[key] for key in ('maximum_implementation_iterations','maximum_code_repair_rounds')}
        encoded=json.dumps(authorization,separators=(',',':'));encoded_proof=json.dumps(changed,separators=(',',':'))
        connection.execute('UPDATE ticket_push_prepared_requalifications SET authorization_json=?,authorization_sha256=?,proof_json=?,proof_sha256=?',(encoded,history.sha(encoded.encode()),encoded_proof,history.sha(encoded_proof.encode())))
        connection.execute('UPDATE workspace_access SET release_receipt_json=? WHERE reservation_key=?',(encoded_proof,old['reservation_key']))
        try:history.validate_prepared_requalification(connection,execution,binding,{'run_id':'run'})
        except (ValueError,KeyError,TypeError):pass
        else:raise AssertionError('accepted invalid '+field)
    print('PHYSICAL_GRAMMAR_OK_NO_CHILD')
    """

    assert {"PHYSICAL_GRAMMAR_OK_NO_CHILD\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v10.py"), path], stderr_to_stdout: true)
  end

  test "schema 53 creation failure atomically preserves schema 52", ctx do
    schema_52(ctx.store)
    Store.query!(ctx.store, "CREATE VIEW ticket_push_prepared_requalifications AS SELECT 'collision' AS authorization_key")
    assert_raise Exqlite.Error, fn -> Store.initialize(ctx.store) end
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations WHERE version=53").rows == []
    assert Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'push_prepared_requalification_%'").rows == []
    assert Store.one!(ctx.store, "SELECT type FROM sqlite_master WHERE name='ticket_push_prepared_requalifications'")["type"] == "view"
  end

  test "schema recognition refuses a same-name trigger with a weakened body", ctx do
    Store.query!(ctx.store, "DROP TRIGGER push_prepared_requalification_update")
    Store.query!(ctx.store, "CREATE TRIGGER push_prepared_requalification_update BEFORE UPDATE ON ticket_push_prepared_requalifications BEGIN SELECT 1; END")
    assert_raise RuntimeError, "Prepared push requalification schema invalid", fn -> Store.initialize(ctx.store) end
  end

  defp schema_52(store) do
    Store.query!(store, "DELETE FROM factory_schema_migrations WHERE version=53")
    for trigger <- ~w(update delete schema_rollback), do: Store.query!(store, "DROP TRIGGER push_prepared_requalification_#{trigger}")
    Store.query!(store, "DROP TABLE ticket_push_prepared_requalifications")
  end

  defp journal_fixture do
    binding = %{"run_id" => "run", "state" => "PUSHING", "candidate_sha" => String.duplicate("a", 40), "spec_revision" => 3, "contract_sha256" => String.duplicate("b", 64)}
    encoded = Jason.encode!(binding)

    original = %{
      "version" => 1,
      "kind" => "TICKET_PUSH",
      "phase" => "PREPARED",
      "binding_json" => encoded,
      "binding_sha256" => digest(encoded),
      "reservation_key" => "ticket-push:" <> digest(encoded),
      "reservation_generation" => 42,
      "owner_nonce" => String.duplicate("c", 64)
    }

    original = Enum.reduce(~w(helper_pid execution_json receipt_json receipt_sha256 remote_sha), original, &Map.put(&2, &1, nil))
    raw = Jason.encode!(original)
    limits = %{"maximum_implementation_iterations" => 25, "maximum_code_repair_rounds" => 10}

    authorization =
      Map.merge(Map.take(binding, ~w(run_id candidate_sha spec_revision contract_sha256)), limits)
      |> Map.merge(%{"original_nonce" => original["owner_nonce"], "original_envelope_sha256" => digest(raw), "authorization_reference" => "Synthetic grammar fixture"})

    reference = %{"authorization_key" => "fixture", "original_sha256" => digest(raw), "attempt" => 1}
    fresh = Map.put(binding, "prepared_requalification", reference)

    access = %{
      "run_id" => "run",
      "reservation_key" => original["reservation_key"],
      "generation" => 42,
      "task_key" => nil,
      "request_key" => original["reservation_key"],
      "mode" => "MAINTENANCE",
      "released_at" => nil,
      "release_receipt_json" => nil,
      "canonical_path" => "/synthetic/source",
      "git_dir" => "/synthetic/git",
      "common_dir" => "/synthetic/git"
    }

    spool = Map.new(~w(database root spool spool_device spool_inode companion_path companion_sha256), &{&1, "/synthetic/" <> &1})

    proof = %{
      "version" => 1,
      "kind" => "NEVER_ISSUED_PREPARED_REQUALIFICATION_V1",
      "original_access" => access,
      "spool" => spool,
      "tick" => %{"scope" => "scope", "dispatcher_id" => "dispatcher", "generation" => 1, "tick_id" => "tick"},
      "configured_limits" => limits
    }

    %{
      "authorization_key" => "fixture",
      "run_id" => "run",
      "original_nonce" => original["owner_nonce"],
      "original_envelope" => raw,
      "original_sha256" => digest(raw),
      "successor_nonce" => String.duplicate("d", 64),
      "created_at" => "2026-10-20T00:00:00Z"
    }
    |> encoded_field("authorization", authorization)
    |> encoded_field("proof", proof)
    |> encoded_field("successor_binding", fresh)
    |> then(&Map.put(&1, "successor_reservation_key", "ticket-push:" <> &1["successor_binding_sha256"]))
  end

  defp encoded_field(row, field, object) do
    raw = Jason.encode!(object)
    Map.merge(row, %{(field <> "_json") => raw, (field <> "_sha256") => digest(raw)})
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
