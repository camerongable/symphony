defmodule SymphonyElixir.FactoryCiRepairRoundsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{Control, Store, TicketCiRepair}

  defmodule ReviewBoundary do
    def discussion_page(_arguments, _opts) do
      send(self(), :review_boundary)
      {:error, :review_boundary}
    end
  end

  test "five total rounds reach unchanged review gates, sixth and lower configured caps deny" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    config = %{scope: "cap-test", dispatcher_id: "fixture"}
    Control.initialize(ctx.store, config)
    Store.query!(ctx.store, "UPDATE control SET status='ACTIVE' WHERE scope='cap-test'")

    for {prior_round, limit, allowed} <- [
          {2, 5, true},
          {3, 5, true},
          {4, 5, true},
          {5, 5, false},
          {5, 99, false},
          {2, 2, false},
          {0, 0, false},
          {2, nil, true}
        ] do
      Store.query!(ctx.store, "UPDATE runs SET code_repair_round=?,mr_iid=1 WHERE run_id='run'", [prior_round])
      run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'")
      pipeline = prior_round * 100 + (limit || 1) + 1
      collected = %{"evidence" => %{"status" => "BLOCK", "pipeline_id" => pipeline}, "snapshots" => %{"mr" => %{"project_id" => 123}}}
      diagnosis = Jason.encode!(%{"status" => "REPAIRABLE", "allowed_writer_paths" => [], "required_generated_paths" => []})
      preimage = Jason.encode!(%{"run" => run, "ci_snapshots" => collected["snapshots"]})
      key = "ci-repair:" <> hash(Jason.encode!(["run", run["candidate_sha"], pipeline]))

      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,?,?,?,?,?,?)", [
        key,
        "run",
        run["candidate_sha"],
        pipeline,
        preimage,
        hash(preimage),
        diagnosis,
        hash(diagnosis),
        "REPAIRABLE",
        "now"
      ])

      result = TicketCiRepair.prepare_diagnosis(ctx.store, run, collected, 123, ci_repair_policy: "native_bounded_v1", ci_repair_limit: limit, ci_repair_scope: "cap-test", connector: ReviewBoundary)

      if allowed do
        assert result == {:error, :review_boundary}
        assert_received :review_boundary
      else
        assert {:ok, persist} = result
        assert is_function(persist, 2)
        assert {:ok, exhausted} = Store.transaction!(ctx.store, &persist.(&1, run))
        assert exhausted["failure_code"] == "CI_REPAIR_EXHAUSTED"
        assert exhausted["last_error"] =~ "#{prior_round} total cycles used"
        assert exhausted["last_error"] =~ "configured limit #{min(limit || 5, 5)}"
        assert exhausted["state"] == run["state"]
        refute_received :review_boundary
      end

      assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_repair_claims").rows == []
      assert Store.one!(ctx.store, "SELECT code_repair_round FROM runs WHERE run_id='run'")["code_repair_round"] == prior_round
    end
  end

  test "schema permits exactly five total immutable claims" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})

    for round <- 1..5 do
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,'{}','preimage','{}','diagnosis','REPAIRABLE','now')", ["diagnosis-#{round}", "run", "candidate-#{round}", round])
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,?,?,'{}','claim','now')", ["claim-#{round}", "diagnosis-#{round}", "run", round])
    end

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES ('sixth','run','candidate6',6,'{}','preimage','{}','diagnosis','REPAIRABLE','now')")
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('sixth','sixth','run',6,'{}','claim','now')") end
    assert Store.query!(ctx.store, "SELECT round FROM ticket_ci_repair_claims ORDER BY round").rows == Enum.map(1..5, &[&1])
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "UPDATE ticket_ci_repair_claims SET claim_json='changed'") end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM ticket_ci_repair_claims") end
  end

  test "populated legacy claims retain exact rowids, bytes, dependents, FKs and guards on concurrent migration" do
    ctx = legacy_fixture()
    seed_references(ctx)
    before = protected_rows(ctx.store)
    objects = Store.query!(ctx.store, "SELECT name,sql FROM sqlite_master WHERE type IN ('trigger','index') AND sql IS NOT NULL ORDER BY name").rows
    fks = foreign_keys(ctx.store)
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert protected_rows(ctx.store) == before
    options = [database: ctx.database, foreign_keys: :on, busy_timeout: 30_000, default_transaction_mode: :deferred]
    {:ok, second} = Exqlite.start_link(options)
    tasks = for connection <- [ctx.store, second], do: Task.async(fn -> Store.initialize(connection) end)
    assert Enum.map(tasks, &Task.await(&1, 30_000)) == [:ok, :ok]
    assert protected_rows(ctx.store) == before
    assert foreign_keys(ctx.store) == fks
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert Store.one!(ctx.store, "PRAGMA foreign_keys") == %{"foreign_keys" => 1}
    assert objects -- Store.query!(ctx.store, "SELECT name,sql FROM sqlite_master WHERE type IN ('trigger','index') AND sql IS NOT NULL ORDER BY name").rows == []
    assert :ok = Store.initialize(ctx.store)
    assert protected_rows(ctx.store) == before
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=47") end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "UPDATE ticket_ci_repair_claims SET claim_json='changed'") end
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert protected_rows(reader) == before
    GenServer.stop(reader)
    GenServer.stop(second)
  end

  test "migration rollback restores exact schema and receipts plus original connection pragmas" do
    ctx = legacy_fixture()
    seed_references(ctx)
    Store.query!(ctx.store, "CREATE TRIGGER fixture_reject47 BEFORE INSERT ON factory_schema_migrations WHEN NEW.version=47 BEGIN SELECT RAISE(ABORT,'fixture_migration_failure'); END")
    before = protected_rows(ctx.store)
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").rows
    assert_raise Exqlite.Error, fn -> Store.initialize(ctx.store) end
    assert protected_rows(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").rows == schema
    assert Store.one!(ctx.store, "PRAGMA foreign_keys") == %{"foreign_keys" => 1}
    assert Store.one!(ctx.store, "PRAGMA legacy_alter_table") == %{"legacy_alter_table" => 0}
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    Store.query!(ctx.store, "DROP TRIGGER fixture_reject47")
    assert :ok = Store.initialize(ctx.store)
    assert protected_rows(ctx.store) == before
  end

  test "migration refuses transaction-local FK disabling without changing the ledger" do
    ctx = legacy_fixture()
    before = protected_rows(ctx.store)
    assert_raise RuntimeError, ~r/outer connection checkout/, fn -> Store.transaction!(ctx.store, &Store.initialize/1) end
    assert protected_rows(ctx.store) == before
    assert Store.one!(ctx.store, "PRAGMA foreign_keys") == %{"foreign_keys" => 1}
  end

  defp legacy_fixture do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})

    DBConnection.run(ctx.store, fn connection ->
      Store.query!(connection, "PRAGMA foreign_keys=OFF")
      Store.query!(connection, "PRAGMA legacy_alter_table=ON")

      Store.transaction!(connection, &legacy_claim_table/1)

      Store.query!(connection, "PRAGMA legacy_alter_table=OFF")
      Store.query!(connection, "PRAGMA foreign_keys=ON")
    end)

    ctx
  end

  defp legacy_claim_table(tx) do
    sql = Store.one!(tx, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"]
    objects = Store.query!(tx, "SELECT sql FROM sqlite_master WHERE tbl_name='ticket_ci_repair_claims' AND sql IS NOT NULL AND type IN ('index','trigger')").rows
    create = sql |> String.replace(~s("ticket_ci_repair_claims"), "ticket_ci_repair_claims_legacy", global: false) |> String.replace("BETWEEN 1 AND 5", "BETWEEN 1 AND 2")
    Store.query!(tx, create)
    Store.query!(tx, "DROP TABLE ticket_ci_repair_claims")
    Store.query!(tx, "ALTER TABLE ticket_ci_repair_claims_legacy RENAME TO ticket_ci_repair_claims")
    for [statement] <- objects, do: Store.query!(tx, statement)
    Store.query!(tx, "DROP TRIGGER ci_repair_five_rounds_schema_rollback")
    Store.query!(tx, "DELETE FROM factory_schema_migrations WHERE version=47")
  end

  defp seed_references(ctx) do
    for {round, rowid} <- [{1, 3}, {2, 9}] do
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,'{\"raw\": \"preimage\"}','p','{\"raw\":\"diagnosis\"}','d','REPAIRABLE','old-time')", [
        "diagnosis#{round}",
        "run",
        "candidate#{round}",
        round
      ])

      Store.query!(
        ctx.store,
        "INSERT INTO ticket_ci_repair_claims(rowid,claim_key,diagnosis_key,run_id,round,claim_json,claim_sha256,created_at) VALUES (?,?,?,'run',?,'{\"raw\": \"claim\"}','hash','old-time')",
        [rowid, "claim#{round}", "diagnosis#{round}", round]
      )
    end

    Store.query!(
      ctx.store,
      "INSERT INTO workspace_access(reservation_key,run_id,task_key,request_key,mode,generation,canonical_path,git_dir,common_dir,binding_json,acquired_at) VALUES('access','run','writer','attempt','SOURCE',1,'/fixture/source','/fixture/git','/fixture/git','{}','old-time')"
    )

    Store.query!(
      ctx.store,
      "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,owner_id,created_at) VALUES('attempt','writer','run','access','{}','hash','RESERVED','owner','old-time')"
    )

    Store.query!(ctx.store, "INSERT INTO ticket_ci_generation_intents VALUES('generation','run','claim1','attempt','GOFMT_DIFF','{\"raw\": \"binding\"}','hash','old-time')")
    Store.query!(ctx.store, "INSERT INTO ticket_ci_generation_events VALUES('event','generation','EXECUTION_PREPARED','path',NULL,'{\"raw\": \"receipt\"}','hash','old-time')")

    Store.query!(
      ctx.store,
      "INSERT INTO ticket_push_rejection_retirements VALUES('retirement','run','candidate',2,'claim2','nonce','original','hash','{}','hash','successor','hash','successor-reservation','old-time')"
    )
  end

  defp protected_rows(store) do
    tables = Store.query!(store, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name!='factory_schema_migrations' ORDER BY name").rows
    Map.new(tables, fn [name] -> {name, Store.query!(store, "SELECT rowid,* FROM #{name} ORDER BY rowid").rows} end)
  end

  defp foreign_keys(store) do
    tables = ~w(ticket_ci_repair_claims ticket_ci_generation_intents ticket_push_rejection_retirements)
    Map.new(tables, &{&1, Store.query!(store, "PRAGMA foreign_key_list(#{&1})").rows})
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
