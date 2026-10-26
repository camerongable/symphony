defmodule SymphonyElixir.FactoryHumanEmptyImportMigrationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.Store

  test "schema 49 upgrades additively and readonly opening does not migrate" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})
    before = snapshot(ctx.store)
    Store.query!(ctx.store, "DROP TRIGGER human_empty_import_update")
    Store.query!(ctx.store, "DROP TRIGGER human_empty_import_delete")
    Store.query!(ctx.store, "DROP TRIGGER human_empty_import_schema_rollback")
    Store.query!(ctx.store, "DROP TABLE ticket_human_empty_commit_imports")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=50")
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert snapshot(ctx.store) == before
    assert :ok = Store.initialize(ctx.store)
    assert snapshot(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..50, &[&1])
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert :ok = Store.initialize(ctx.store)
    assert snapshot(ctx.store) == before
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert snapshot(reader) == before
    GenServer.stop(reader)
  end

  test "forged caller capsules cannot invoke a mutation entry point" do
    refute function_exported?(SymphonyElixir.Factory.TicketHumanEmptyCommitImport, :apply, 2)
    refute function_exported?(SymphonyElixir.Factory.TicketHumanEmptyCommitImport, :apply_prepared, 4)
  end

  defp snapshot(store) do
    Store.query!(store, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN ('factory_schema_migrations','ticket_human_empty_commit_imports') ORDER BY name").rows
    |> Map.new(fn [table] -> {table, Store.query!(store, "SELECT rowid,* FROM #{table} ORDER BY rowid").rows} end)
  end
end
