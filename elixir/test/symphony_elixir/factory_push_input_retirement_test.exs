defmodule SymphonyElixir.FactoryPushInputRetirementTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{Control, Store, TicketPush, TicketPushIO}

  test "retirement CLI rejects an existing schema41 ledger without initializing or migrating it" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    for trigger <- ~w(push_input_retirement_update push_input_retirement_delete push_input_retirement_schema_rollback), do: Store.query!(ctx.store, "DROP TRIGGER #{trigger}")
    Store.query!(ctx.store, "DROP TABLE ticket_push_input_retirements")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=42")
    before = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    migrations = Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows
    controls = Store.query!(ctx.store, "SELECT * FROM control").rows
    workflow = Path.join(ctx.root, "retirement-WORKFLOW.md")

    File.write!(
      workflow,
      "---\n" <>
        Jason.encode!(%{"factory" => %{"enabled" => true, "database" => ctx.database, "scope" => "schema41", "dispatcher_id" => "fixture", "controller_codex_project_id" => "projectless"}}) <>
        "\n---\nFixture\n"
    )

    hash = String.duplicate("a", 64)

    assert_raise Mix.Error, ~r/factory_ledger_schema_not_current/, fn ->
      Mix.Tasks.Factory.run(["prepare-push-input-retirement", "run", hash, hash, "/nonexistent", hash, "/nonexistent", "--workflow", workflow])
    end

    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == before
    assert Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows == migrations
    assert Store.query!(ctx.store, "SELECT * FROM control").rows == controls
  end

  test "native proof cannot run from an unactivated build environment" do
    original = System.get_env("MIX_BUILD_PATH")

    try do
      System.put_env("MIX_BUILD_PATH", "/not-the-loaded-artifact")
      assert {:error, :input_fence_current_artifact_unproven} = TicketPushIO.input_fence_proof("/nonexistent", String.duplicate("a", 64), "/nonexistent")
    after
      if original, do: System.put_env("MIX_BUILD_PATH", original), else: System.delete_env("MIX_BUILD_PATH")
    end
  end

  test "public input retirement requires the exact active nonexpired operator lease before any proof IO" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    config = %{scope: "retirement-fixture", dispatcher_id: "fixture", lease_seconds: 240}
    Control.initialize(ctx.store, config)
    assert {:ok, _} = Control.activate(ctx.store, config, config.dispatcher_id)
    assert %{result: "ACQUIRED"} = Control.acquire_tick(ctx.store, config, config.dispatcher_id)
    tick = Control.status(ctx.store, config.scope) |> Map.take(~w(scope dispatcher_id generation tick_id))
    protected = fn -> Enum.map(~w(runs workspace_access ticket_push_input_retirements), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) end
    before = protected.()

    assert {:ok, :ok} =
             Exqlite.transaction(ctx.store, fn tx ->
               assert {:error, :workspace_observation_inside_transaction} = TicketPush.prepare_input_retirement(tx, "run", "nonce", "sha", "/nonexistent", "sha", %{}, [])
               assert {:error, :workspace_observation_inside_transaction} = TicketPush.execute_input_retirement(tx, "run", "nonce", "sha", "/nonexistent", "sha", "plan", %{}, [])
               :ok
             end)

    for stale <- [nil, Map.put(tick, "tick_id", "replaced"), Map.put(tick, "generation", tick["generation"] + 1), Map.put(tick, "dispatcher_id", "foreign")] do
      opts = [operator_tick: stale, input_fence_guard: "/nonexistent"]
      assert {:error, :push_recovery_operator_tick_unproven} = TicketPush.prepare_input_retirement(ctx.store, "run", "nonce", "sha", "/nonexistent", "sha", %{}, opts)
      assert {:error, :push_recovery_operator_tick_unproven} = TicketPush.execute_input_retirement(ctx.store, "run", "nonce", "sha", "/nonexistent", "sha", "plan", %{}, opts)
      assert protected.() == before
    end

    Store.query!(ctx.store, "UPDATE control SET lease_expires_at='2000-01-01T00:00:00Z' WHERE scope=?", [config.scope])
    assert {:error, :push_recovery_operator_tick_unproven} = TicketPush.prepare_input_retirement(ctx.store, "run", "nonce", "sha", "/nonexistent", "sha", %{}, operator_tick: tick)
    assert protected.() == before
  end

  test "schema 42 adds one append-only retirement and bounds successors by run round and original nonce" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    assert Store.one!(ctx.store, "SELECT MAX(version) AS v FROM factory_schema_migrations")["v"] == 45
    values = ["retirement", "run", 1, "old-nonce", "original-bytes", "original-hash", "{}", "proof-hash", "new-nonce", "new-binding", "new-reservation", "fixture"]
    Store.query!(ctx.store, "INSERT INTO ticket_push_input_retirements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", values)

    for sql <- [
          "UPDATE ticket_push_input_retirements SET proof_json='changed'",
          "DELETE FROM ticket_push_input_retirements",
          "DELETE FROM factory_schema_migrations WHERE version=42",
          "INSERT INTO ticket_push_input_retirements SELECT 'other',run_id,code_repair_round,original_nonce,original_envelope,original_sha256,proof_json,proof_sha256,'other-nonce',successor_binding_sha256,'other-reservation',created_at FROM ticket_push_input_retirements"
        ] do
      assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql) end
    end

    before = Store.query!(ctx.store, "SELECT * FROM ticket_push_input_retirements").rows
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT * FROM ticket_push_input_retirements").rows == before
    {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert Store.query!(reader, "SELECT * FROM ticket_push_input_retirements").rows == before
    GenServer.stop(reader)
  end
end
