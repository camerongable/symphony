defmodule SymphonyElixir.FactoryControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, Store}

  @now ~U[2026-09-21 20:00:00Z]
  @config %{
    scope: "assigned-jira-work",
    dispatcher_id: "dispatcher-a",
    lease_seconds: 240
  }

  setup do
    database = Path.join(System.tmp_dir!(), "symphony-factory-#{System.unique_integer([:positive])}.sqlite")
    connection = start_supervised!({Store, database: database})
    Control.initialize(connection, @config, now: @now)
    on_exit(fn -> File.rm(database) end)
    %{connection: connection}
  end

  test "initialization is idempotent and begins paused", %{connection: connection} do
    assert %{result: "INITIALIZED", control: control} =
             Control.initialize(connection, @config, now: DateTime.add(@now, 5, :second))

    assert control["status"] == "PAUSED"
    assert control["dispatcher_id"] == "dispatcher-a"
    assert control["generation"] == 0
  end

  test "only the active dispatcher acquires a serialized lease", %{connection: connection} do
    assert {:ok, %{result: "ACTIVE"}} = Control.activate(connection, @config, "dispatcher-a", now: @now)

    assert %{
             result: "ACQUIRED",
             tick_id: "tick-a",
             generation: 2,
             lease_expires_at: "2026-09-21T20:04:00Z"
           } =
             Control.acquire_tick(connection, @config, "dispatcher-a", now: @now, tick_id: "tick-a")

    assert %{result: "LEASE_HELD", tick_id: "tick-a"} =
             Control.acquire_tick(connection, @config, "dispatcher-a",
               now: DateTime.add(@now, 1, :second),
               tick_id: "tick-b"
             )

    assert %{result: "DISPATCHER_CONFLICT", active_dispatcher_id: "dispatcher-a"} =
             Control.acquire_tick(connection, @config, "dispatcher-b", now: DateTime.add(@now, 1, :second))
  end

  test "an expired lease can be replaced", %{connection: connection} do
    assert {:ok, _activated} = Control.activate(connection, @config, "dispatcher-a", now: @now)

    assert %{result: "ACQUIRED"} =
             Control.acquire_tick(connection, @config, "dispatcher-a", now: @now, tick_id: "expired")

    takeover_time = DateTime.add(@now, 241, :second)

    assert %{result: "ACQUIRED", tick_id: "replacement", generation: 3} =
             Control.acquire_tick(connection, @config, "dispatcher-a",
               now: takeover_time,
               tick_id: "replacement"
             )
  end

  test "release requires the exact dispatcher and tick", %{connection: connection} do
    assert {:ok, _activated} = Control.activate(connection, @config, "dispatcher-a", now: @now)

    assert %{result: "ACQUIRED"} =
             Control.acquire_tick(connection, @config, "dispatcher-a", now: @now, tick_id: "tick-a")

    assert %{result: "LEASE_MISMATCH"} =
             Control.release_tick(connection, @config, "dispatcher-a", "other", now: @now)

    assert %{result: "LEASE_MISMATCH"} =
             Control.release_tick(connection, @config, "dispatcher-b", "tick-a", now: @now)

    assert %{result: "RELEASED", tick_id: "tick-a", generation: 3} =
             Control.release_tick(connection, @config, "dispatcher-a", "tick-a", now: @now)

    assert Control.status(connection, @config.scope)["tick_id"] == nil
  end

  test "a live lease prevents dispatcher handoff", %{connection: connection} do
    assert {:ok, _activated} = Control.activate(connection, @config, "dispatcher-a", now: @now)

    assert %{result: "ACQUIRED"} =
             Control.acquire_tick(connection, @config, "dispatcher-a", now: @now, tick_id: "tick-a")

    assert {:error, :live_tick_lease} =
             Control.activate(connection, @config, "dispatcher-b", now: DateTime.add(@now, 1, :second))

    assert {:ok, %{result: "ACTIVE", control: control}} =
             Control.activate(connection, @config, "dispatcher-b", now: DateTime.add(@now, 241, :second))

    assert control["dispatcher_id"] == "dispatcher-b"
    assert control["tick_id"] == nil
  end
end
