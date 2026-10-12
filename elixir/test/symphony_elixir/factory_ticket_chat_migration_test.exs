defmodule SymphonyElixir.FactoryTicketChatMigrationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Store

  test "rebuild preserves legacy bytes, repair foreign keys and indexes across reopen" do
    database = Path.join(System.tmp_dir!(), "ticket-chat-migration-#{System.unique_integer([:positive])}.sqlite")
    on_exit(fn -> File.rm(database) end)
    {:ok, store} = Store.start_link(database: database)
    legacy_table(store)
    insert_request(store, "legacy-task", "TASK", "CREATE_UNCERTAIN", "project")
    insert_request(store, "legacy-controller", "CONTROLLER", "SUCCEEDED", "projectless")
    Store.query!(store, "INSERT INTO planner_format_repairs VALUES ('legacy-task', 'turn-plan', 'AUTHORIZED', 'old-plan', NULL)")

    Store.query!(store, """
    INSERT INTO controller_format_repairs(request_key, completed_turn_id, request_payload_sha256, thread_id, status, authorized_at)
    VALUES ('legacy-controller', 'turn-controller', 'original-hash', 'original-thread', 'AUTHORIZED', 'old-controller')
    """)

    Store.query!(store, "CREATE INDEX legacy_request_model_index ON desktop_requests(model)")
    Store.query!(store, "CREATE TABLE migration_audit(message TEXT)")
    Store.query!(store, "CREATE TRIGGER legacy_request_updated AFTER UPDATE ON desktop_requests BEGIN INSERT INTO migration_audit VALUES ('updated'); END")
    before = snapshot(store)
    assert :ok = Store.initialize(store)
    assert snapshot(store) == before
    assert Store.query!(store, "PRAGMA foreign_key_check").rows == []
    assert Store.one!(store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.one!(store, "SELECT name FROM sqlite_master WHERE name = 'legacy_request_model_index'") != nil
    assert Store.one!(store, "SELECT name FROM sqlite_master WHERE name = 'one_unresolved_desktop_request_per_target'") != nil
    assert :ok = Store.initialize(store)
    assert snapshot(store) == before
    GenServer.stop(store)

    {:ok, reopened} = Store.start_link(database: database)

    try do
      assert snapshot(reopened) == before
      assert Store.query!(reopened, "PRAGMA foreign_key_check").rows == []
      assert Store.one!(reopened, "SELECT applied_at FROM factory_schema_migrations WHERE version = 17") != nil
      insert_request(reopened, "ticket", "TICKET_CHAT", "PENDING", nil)
      insert_request(reopened, "other-ticket", "TICKET_CHAT", "PENDING", nil)

      assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
        Store.query!(reopened, "UPDATE desktop_requests SET target_key = 'ticket' WHERE request_key = 'other-ticket'")
      end

      Store.query!(reopened, "UPDATE desktop_requests SET title = 'Updated' WHERE request_key = 'ticket'")
      assert Store.query!(reopened, "SELECT message FROM migration_audit").rows == [["updated"]]

      for {kind, project} <- [{"TASK", nil}, {"CONTROLLER", nil}, {"TICKET_CHAT", "project"}] do
        assert_raise Exqlite.Error, ~r/CHECK constraint failed/, fn ->
          insert_request(reopened, "invalid-#{kind}", kind, "PENDING", project)
        end
      end
    after
      GenServer.stop(reopened)
    end
  end

  test "foreign-key failure after drop and rename restores the original schema and receipts" do
    store = start_supervised!({Store, database: ":memory:"})
    legacy_table(store)
    insert_request(store, "legacy-task", "TASK", "PENDING", "project")

    DBConnection.run(store, fn leased ->
      Store.query!(leased, "PRAGMA foreign_keys = OFF")
      Store.query!(leased, "INSERT INTO planner_format_repairs VALUES ('missing-request', 'turn', 'AUTHORIZED', 'old', NULL)")
      Store.query!(leased, "PRAGMA foreign_keys = ON")
    end)

    before = snapshot(store)
    original_sql = Store.one!(store, "SELECT sql FROM sqlite_master WHERE name = 'desktop_requests'")["sql"]
    assert_raise RuntimeError, ~r/foreign-key validation/, fn -> Store.initialize(store) end
    assert snapshot(store) == before
    assert Store.one!(store, "SELECT sql FROM sqlite_master WHERE name = 'desktop_requests'")["sql"] == original_sql
    assert Store.one!(store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.one!(store, "SELECT name FROM sqlite_master WHERE name = 'desktop_requests_upgrade'") == nil
  end

  test "a partial target-kind upgrade cannot skip the project-nullability migration" do
    store = start_supervised!({Store, database: ":memory:"})
    legacy_table(store)
    sql = Store.one!(store, "SELECT sql FROM sqlite_master WHERE name = 'desktop_requests'")["sql"]
    sql = String.replace(sql, "'TASK', 'CONTROLLER'", "'TASK', 'CONTROLLER', 'TICKET_CHAT'")
    Store.query!(store, "DROP TABLE desktop_requests")
    Store.query!(store, sql)
    assert :ok = Store.initialize(store)
    insert_request(store, "ticket", "TICKET_CHAT", "PENDING", nil)
  end

  test "failed rebuild rolls back parent and child rows and restores foreign-key enforcement" do
    store = start_supervised!({Store, database: ":memory:"})
    legacy_table(store)
    insert_request(store, "legacy-task", "TASK", "PENDING", "project")
    Store.query!(store, "INSERT INTO planner_format_repairs VALUES ('legacy-task', 'turn', 'AUTHORIZED', 'old', NULL)")
    Store.query!(store, "ALTER TABLE desktop_requests ADD COLUMN unsupported_future_column TEXT")
    before = snapshot(store)

    assert_raise Exqlite.Error, ~r/unsupported_future_column/, fn -> Store.initialize(store) end
    assert snapshot(store) == before
    assert Store.one!(store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.query!(store, "PRAGMA foreign_key_check").rows == []
    assert Store.one!(store, "SELECT name FROM sqlite_master WHERE name = 'desktop_requests_upgrade'") == nil
    assert Store.one!(store, "SELECT version FROM factory_schema_migrations WHERE version = 17") == nil
  end

  defp legacy_table(store) do
    sql = Store.one!(store, "SELECT sql FROM sqlite_master WHERE name = 'desktop_requests'")["sql"]
    sql = String.replace(sql, "'TASK', 'CONTROLLER', 'TICKET_CHAT'", "'TASK', 'CONTROLLER'")
    sql = Regex.replace(~r/codex_project_id TEXT CHECK\(.*?\),/s, sql, "codex_project_id TEXT NOT NULL,")
    Store.query!(store, "DROP TABLE desktop_requests")
    Store.query!(store, sql)
    Store.query!(store, "DELETE FROM factory_schema_migrations WHERE version = 17")
  end

  defp insert_request(store, key, kind, status, project) do
    Store.query!(
      store,
      """
      INSERT INTO desktop_requests(request_key, target_kind, target_key, action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, title, prompt, schema_json, cwd, metadata_json, created_at, updated_at)
      VALUES (?, ?, ?, 'CREATE', ?, 'original-hash', ?, 'gpt-test', 'low', 'Title', 'Exact original prompt', '{}', '/tmp/chat', '{}', 'old-created', 'old-updated')
      """,
      [key, kind, key, status, project]
    )
  end

  defp snapshot(store) do
    for table <- ~w(desktop_requests planner_format_repairs controller_format_repairs), into: %{} do
      {table, Store.query!(store, "SELECT * FROM #{table} ORDER BY request_key").rows}
    end
  end
end
