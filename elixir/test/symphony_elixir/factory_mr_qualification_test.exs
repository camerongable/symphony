defmodule SymphonyElixir.FactoryMrQualificationTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketChatFixture
  alias SymphonyElixir.Factory.{Store, TicketMrQualification}

  test "schema46 is additive, repeatable, and required by read-only consumers" do
    ctx = setup_fixture(%{})
    for name <- ~w(mr_qualification_update mr_qualification_delete mr_qualification_schema_rollback), do: Store.query!(ctx.store, "DROP TRIGGER #{name}")
    Store.query!(ctx.store, "DROP TABLE ticket_mr_qualifications")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=46")
    original = Store.query!(ctx.store, "SELECT * FROM runs").rows
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    migrations = Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == schema
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT * FROM runs").rows == original
    assert Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations WHERE version<>46 ORDER BY version").rows == migrations
    new_schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    assert length(new_schema -- schema) == 6
    assert schema -- new_schema == []
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == new_schema
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert Store.query!(reader, "SELECT * FROM ticket_mr_qualifications").rows == []
    GenServer.stop(reader)
  end

  test "qualification storage is once-only and append-only, never a mutable result replacement" do
    ctx = setup_fixture(%{})
    key = ctx.chat["create_request_key"]
    original = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE request_key=?", [key])
    values = ["qualification", key, "run", "candidate", "contract", 1, "CI_MR_CREATING", "push", "request", "output", "binding", "{}", "preimage", "{}", "observation", "now", "MR_OBSERVATION_V1"]
    sql = "INSERT INTO ticket_mr_qualifications VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    Store.query!(ctx.store, sql, values)
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql, List.replace_at(values, 0, "other")) end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "UPDATE ticket_mr_qualifications SET observation_json='{}'") end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM ticket_mr_qualifications") end
    assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=46") end
    assert Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE request_key=?", [key]) == original
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert Store.one!(reader, "SELECT COUNT(*) AS count FROM ticket_mr_qualifications")["count"] == 1
    GenServer.stop(reader)
  end

  test "qualification cannot begin remote observation inside a transaction" do
    ctx = setup_fixture(%{})
    assert {:error, :workspace_observation_inside_transaction} = Store.transaction!(ctx.store, fn tx -> TicketMrQualification.prepare(tx, %{}, %{}, %{}, %{}, "scope") end)
  end
end
