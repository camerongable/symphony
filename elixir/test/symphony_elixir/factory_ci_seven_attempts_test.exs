defmodule SymphonyElixir.FactoryCiSevenAttemptsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.Store

  test "new physical validator preserves archived V1 and V2 ceilings while V3 permits ten" do
    program = Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v8.py")

    script = """
    import importlib.util,os,stat,sys
    spec=importlib.util.spec_from_file_location('physical',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    run={'worktree':'/fixture/source','repo_key':'grail'}
    base={'workflow_path':'/fixture/WORKFLOW.md','workflow_sha256':'a'*64,'workflow_stat':{'inode':1,'device':1,'rdev':0,'size':1,'mtime_seconds':1,'uid':os.geteuid(),'mode':stat.S_IFREG|0o600},'configured_limit':10,'scope':'scope','dispatcher_id':'owner','repo_key':'grail','cached_policy_sha256':'b'*64}
    for version,cap in ((1,5),(2,7),(3,10)):
        receipt=dict(base,version=version,kind='CI_REPAIR_POLICY_V'+str(version),effective_limit=cap)
        if version>1: receipt['scope_extension']=None
        assert module.policy_shape(receipt,run)==cap
        bad=dict(receipt,effective_limit=cap+1)
        try: module.policy_shape(bad,run)
        except ValueError: pass
        else: raise AssertionError('policy ceiling reinterpreted')
    unknown=dict(base,version=4,kind='CI_REPAIR_POLICY_V4',effective_limit=10,scope_extension=None)
    try: module.policy_shape(unknown,run)
    except ValueError: pass
    else: raise AssertionError('unknown policy admitted')
    print('V1=5 V2=7 V3=10; coherent cap tamper and unknown version refused')
    """

    assert {output, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, program], stderr_to_stdout: true)
    assert output =~ "V1=5 V2=7 V3=10"
  end

  test "populated schema50 migrates once preserving every old rowid byte and rolls back atomically" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})

    for round <- 1..7 do
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,'{\"kept\": \"raw\"}','preimage','{}','diagnosis','REPAIRABLE','old-time')", [
        "old-diagnosis-#{round}",
        "run",
        "candidate-#{round}",
        round
      ])

      Store.query!(
        ctx.store,
        "INSERT INTO ticket_ci_repair_claims(rowid,claim_key,diagnosis_key,run_id,round,claim_json,claim_sha256,created_at) VALUES (?,?,?,?,?,'{\"kept\": \"receipt\"}','claim','old-time')",
        [round * 3, "old-claim-#{round}", "old-diagnosis-#{round}", "run", round]
      )
    end

    legacy50(ctx.store)
    legacy_triggers = Store.query!(ctx.store, "SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name IN ('ticket_ci_repair_claims','ticket_ci_repair_evidence_successors')").rows
    assert Enum.any?(legacy_triggers, fn [sql] -> sql =~ ">= 7" end)
    refute Enum.any?(legacy_triggers, fn [sql] -> sql =~ ">= 10" end)
    before = protected_rows(ctx.store)
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    Store.query!(ctx.store, "CREATE TRIGGER fixture_reject51 BEFORE INSERT ON factory_schema_migrations WHEN NEW.version=51 BEGIN SELECT RAISE(ABORT,'fixture_migration_failure'); END")
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").rows
    assert_raise Exqlite.Error, fn -> Store.initialize(ctx.store) end
    assert protected_rows(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").rows == schema
    assert Store.one!(ctx.store, "PRAGMA foreign_keys") == %{"foreign_keys" => 1}
    assert Store.one!(ctx.store, "PRAGMA legacy_alter_table") == %{"legacy_alter_table" => 0}
    Store.query!(ctx.store, "DROP TRIGGER fixture_reject51")
    assert :ok = Store.initialize(ctx.store)
    assert protected_rows(ctx.store) == before
    repeated = for _ <- 1..2, do: Task.async(fn -> Store.initialize(ctx.store) end)
    assert Enum.map(repeated, &Task.await(&1, 30_000)) == [:ok, :ok]
    assert protected_rows(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..54, &[&1])
    assert :ok = Store.initialize(ctx.store)
    assert protected_rows(ctx.store) == before
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=51") end
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert protected_rows(reader) == before
    GenServer.stop(reader)
  end

  defp protected_rows(store) do
    Store.query!(
      store,
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('factory_schema_migrations','ticket_ordinary_generation_intents','ticket_ordinary_generation_events','ticket_mr_presend_consumptions','ticket_push_prepared_requalifications') ORDER BY name"
    ).rows
    |> Map.new(fn [table] -> {table, Store.query!(store, "SELECT rowid,* FROM #{table} ORDER BY rowid").rows} end)
  end

  defp legacy50(store) do
    DBConnection.run(store, fn connection ->
      Store.query!(connection, "PRAGMA foreign_keys=OFF")
      Store.query!(connection, "PRAGMA legacy_alter_table=ON")

      Store.transaction!(connection, fn tx ->
        Store.query!(tx, "DROP TRIGGER ci_round_identity_schema_rollback")
        Store.query!(tx, "DELETE FROM factory_schema_migrations WHERE version=54")

        Enum.each(
          ~w(ci_ten_attempt_schema_rollback ordinary_generation_source_hold ordinary_generation_source_delete),
          &Store.query!(tx, "DROP TRIGGER #{&1}")
        )

        Store.query!(tx, "DROP TABLE ticket_ordinary_generation_events")
        Store.query!(tx, "DROP TABLE ticket_ordinary_generation_intents")
        Store.query!(tx, "DROP TRIGGER mr_presend_schema_rollback")
        Store.query!(tx, "DROP TABLE ticket_mr_presend_consumptions")
        Enum.each(~w(update delete schema_rollback), &Store.query!(tx, "DROP TRIGGER push_prepared_requalification_#{&1}"))
        Store.query!(tx, "DROP TABLE ticket_push_prepared_requalifications")
        Store.query!(tx, "DELETE FROM factory_schema_migrations WHERE version=53")
        Store.query!(tx, "DELETE FROM factory_schema_migrations WHERE version=52")
        Store.query!(tx, "DELETE FROM factory_schema_migrations WHERE version=51")

        Enum.each(~w(ticket_ci_repair_claims ticket_ci_repair_evidence_successors), &legacy50_table(tx, &1))
      end)

      Store.query!(connection, "PRAGMA legacy_alter_table=OFF")
      Store.query!(connection, "PRAGMA foreign_keys=ON")
    end)
  end

  defp legacy50_table(tx, table) do
    sql = Store.one!(tx, "SELECT sql FROM sqlite_master WHERE name=?", [table])["sql"]
    objects = Store.query!(tx, "SELECT sql FROM sqlite_master WHERE tbl_name=? AND sql IS NOT NULL AND type IN ('index','trigger')", [table]).rows

    create =
      Regex.replace(~r/\A(CREATE TABLE\s+)["`]?#{table}["`]?/, sql, "\\1#{table}_legacy50", global: false)
      |> String.replace("BETWEEN 1 AND 10", "BETWEEN 1 AND 7")
      |> String.replace("round >= 1", "round BETWEEN 1 AND 7")
      |> String.replace("BETWEEN 2 AND 10", "BETWEEN 2 AND 7")

    Store.query!(tx, create)
    columns = Store.query!(tx, "PRAGMA table_info(#{table})").rows |> Enum.map_join(",", &Enum.at(&1, 1))
    Store.query!(tx, "INSERT INTO #{table}_legacy50(rowid,#{columns}) SELECT rowid,#{columns} FROM #{table}")
    Store.query!(tx, "DROP TABLE #{table}")
    Store.query!(tx, "ALTER TABLE #{table}_legacy50 RENAME TO #{table}")
    for [statement] <- objects, do: Store.query!(tx, String.replace(statement, ">= 10", ">= 7"))
  end

  test "ten immutable claims are admitted and the eleventh is denied without resetting history" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})

    for round <- 1..11 do
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,'{}','preimage','{}','diagnosis','REPAIRABLE','now')", ["diagnosis-#{round}", "run", "candidate-#{round}", round])

      insert = fn -> Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,?,?,'{}','claim','now')", ["claim-#{round}", "diagnosis-#{round}", "run", round]) end

      if round <= 10, do: insert.(), else: assert_raise(Exqlite.Error, insert)
    end

    assert Store.query!(ctx.store, "SELECT round FROM ticket_ci_repair_claims ORDER BY round").rows == Enum.map(1..10, &[&1])
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "UPDATE ticket_ci_repair_claims SET claim_json='changed'") end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM ticket_ci_repair_claims") end
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    GenServer.stop(reader)
  end
end
