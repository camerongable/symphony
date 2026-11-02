defmodule SymphonyElixir.FactoryCiRoundIdentityTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{Store, TicketCiRepairSuccessor}

  test "repair identities above ten do not consume extra CI attempts or remove the total budget" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})

    for round <- 11..20 do
      insert_diagnosis(ctx.store, round)
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,?,?,'{}','claim','now')", ["claim-#{round}", "diagnosis-#{round}", "run", round])
    end

    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 10
    insert_diagnosis(ctx.store, 21)

    assert_raise Exqlite.Error, ~r/CI repair attempt budget exhausted/, fn ->
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim-21','diagnosis-21','run',21,'{}','claim','now')")
    end

    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "UPDATE ticket_ci_repair_claims SET round=99 WHERE round=11") end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM ticket_ci_repair_claims WHERE round=11") end

    before = Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows == before
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert Store.query!(reader, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows == before
    GenServer.stop(reader)
  end

  defp insert_diagnosis(store, round) do
    Store.query!(store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,'{}','preimage','{}','diagnosis','REPAIRABLE','now')", ["diagnosis-#{round}", "run", "candidate-#{round}", round])
  end

  test "seven CI claims and two evidence successors leave exactly one attempt at global round eleven" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})

    for round <- 1..7 do
      insert_diagnosis(ctx.store, round)
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,?,?,'{}','claim','now')", ["claim-#{round}", "diagnosis-#{round}", "run", round])
    end

    for index <- 8..9 do
      Store.query!(
        ctx.store,
        "INSERT INTO workspace_access(reservation_key,run_id,task_key,request_key,mode,generation,canonical_path,git_dir,common_dir,binding_json,acquired_at) VALUES(?,'run','writer',?,'REVIEW',1,?,?,'/fixture/common','{}','now')",
        ["access-#{index}", "prior-#{index}", "/fixture/#{index}", "/fixture/git-#{index}"]
      )

      Store.query!(
        ctx.store,
        "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,owner_id,created_at) VALUES(?,'writer','run',?,'{}','hash','RESERVED','owner','now')",
        ["prior-#{index}", "access-#{index}"]
      )

      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_evidence_successors VALUES (?,'run','claim-1',?,NULL,?,10,?,'{}','evidence','{}','proof',?,?,'now')", [
        "successor-#{index}",
        "prior-#{index}",
        index,
        "content-#{index}",
        "next-#{index}",
        "next-access-#{index}"
      ])
    end

    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 9
    before = protected_rows(ctx.store)
    insert_diagnosis(ctx.store, 11)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim-11','diagnosis-11','run',11,'{}','claim','now')")
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 10
    insert_diagnosis(ctx.store, 12)

    assert_raise Exqlite.Error, ~r/CI repair attempt budget exhausted/, fn ->
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim-12','diagnosis-12','run',12,'{}','claim','now')")
    end

    for {table, rows} <- before do
      assert Enum.take(protected_rows(ctx.store)[table], length(rows)) == rows
    end
  end

  test "populated schema53 migration preserves rows and foreign keys and rolls back atomically" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})

    for round <- 1..7 do
      insert_diagnosis(ctx.store, round)

      Store.query!(
        ctx.store,
        "INSERT INTO ticket_ci_repair_claims(rowid,claim_key,diagnosis_key,run_id,round,claim_json,claim_sha256,created_at) VALUES (?,?,?,'run',?,'{\"raw\": \"preserve\"}','claim','old-time')",
        [round * 3, "claim-#{round}", "diagnosis-#{round}", round]
      )
    end

    legacy53(ctx.store)
    before = protected_rows(ctx.store)
    fks = Store.query!(ctx.store, "PRAGMA foreign_key_list(ticket_ci_repair_claims)").rows
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    Store.query!(ctx.store, "CREATE TRIGGER fixture_reject54 BEFORE INSERT ON factory_schema_migrations WHEN NEW.version=54 BEGIN SELECT RAISE(ABORT,'fixture_migration_failure'); END")
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    assert_raise Exqlite.Error, ~r/fixture_migration_failure/, fn -> Store.initialize(ctx.store) end
    assert protected_rows(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == schema
    assert Store.one!(ctx.store, "PRAGMA foreign_keys") == %{"foreign_keys" => 1}
    assert Store.one!(ctx.store, "PRAGMA legacy_alter_table") == %{"legacy_alter_table" => 0}
    Store.query!(ctx.store, "DROP TRIGGER fixture_reject54")
    assert :ok = Store.initialize(ctx.store)
    assert protected_rows(ctx.store) == before
    assert Store.query!(ctx.store, "PRAGMA foreign_key_list(ticket_ci_repair_claims)").rows == fks
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=54") end

    insert_diagnosis(ctx.store, 11)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim-11','diagnosis-11','run',11,'{}','claim','now')")
    repeated = for _ <- 1..2, do: Task.async(fn -> Store.initialize(ctx.store) end)
    assert Enum.map(repeated, &Task.await(&1, 30_000)) == [:ok, :ok]
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 8
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..55, &[&1])
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert Store.one!(reader, "SELECT round FROM ticket_ci_repair_claims WHERE claim_key='claim-11'") == %{"round" => 11}
    GenServer.stop(reader)
  end

  defp protected_rows(store) do
    Store.query!(store, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name!='factory_schema_migrations' ORDER BY name").rows
    |> Map.new(fn [table] -> {table, Store.query!(store, "SELECT rowid,* FROM #{table} ORDER BY rowid").rows} end)
  end

  test "read-only admission refuses a missing round-identity rollback guard without repairing it" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})
    Store.query!(ctx.store, "DROP TRIGGER ci_round_identity_schema_rollback")
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == schema
  end

  test "round identity migration refuses an outer transaction without changing schema or receipts" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})
    legacy53(ctx.store)
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    before = protected_rows(ctx.store)

    assert_raise RuntimeError, ~r/outer connection checkout/, fn ->
      Store.transaction!(ctx.store, &Store.initialize/1)
    end

    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == schema
    assert protected_rows(ctx.store) == before
    assert Store.one!(ctx.store, "PRAGMA foreign_keys") == %{"foreign_keys" => 1}
  end

  defp legacy53(store) do
    DBConnection.run(store, fn connection ->
      Store.query!(connection, "PRAGMA foreign_keys=OFF")
      Store.query!(connection, "PRAGMA legacy_alter_table=ON")

      Store.transaction!(connection, fn tx ->
        sql = Store.one!(tx, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"]
        objects = Store.query!(tx, "SELECT sql FROM sqlite_master WHERE tbl_name='ticket_ci_repair_claims' AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY name").rows
        create = Regex.replace(~r/\ACREATE TABLE (?:"ticket_ci_repair_claims"|ticket_ci_repair_claims)/, sql, "CREATE TABLE claims_schema53") |> String.replace("round >= 1", "round BETWEEN 1 AND 10")
        Store.query!(tx, create)
        Store.query!(tx, "INSERT INTO claims_schema53(rowid,claim_key,diagnosis_key,run_id,round,claim_json,claim_sha256,created_at) SELECT rowid,* FROM ticket_ci_repair_claims")
        Store.query!(tx, "DROP TABLE ticket_ci_repair_claims")
        Store.query!(tx, "ALTER TABLE claims_schema53 RENAME TO ticket_ci_repair_claims")
        for [statement] <- objects, do: Store.query!(tx, statement)
        Store.query!(tx, "DROP TRIGGER ci_round_identity_schema_rollback")
        Store.query!(tx, "DELETE FROM factory_schema_migrations WHERE version=54")
      end)

      Store.query!(connection, "PRAGMA legacy_alter_table=OFF")
      Store.query!(connection, "PRAGMA foreign_keys=ON")
    end)
  end
end
