defmodule SymphonyElixir.FactoryControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, ControlServer, Store}

  @now ~U[2026-09-21 20:00:00Z]
  @config %{
    scope: "assigned-jira-work",
    dispatcher_id: "dispatcher-a",
    lease_seconds: 240
  }

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-factory-#{token}.sqlite")
    connection = start_supervised!({Store, database: database})
    Control.initialize(connection, @config, now: @now)
    on_exit(fn -> File.rm(database) end)
    %{connection: connection, database: database}
  end

  test "control status remains readable while the dashboard connection is checked out", ctx do
    dashboard = start_supervised!(%{id: :dashboard_reader, start: {Store, :start_read_only, [[database: ctx.database]]}})
    control_reader = start_supervised!(%{id: :control_reader, start: {Store, :start_read_only, [[database: ctx.database]]}})
    control = start_supervised!({ControlServer, store: ctx.connection, read_store: control_reader, factory: @config, name: nil})
    parent = self()

    held =
      Task.async(fn ->
        Store.transaction!(
          dashboard,
          fn _ ->
            send(parent, :dashboard_checked_out)

            receive do
              :release_dashboard -> :ok
            end
          end,
          mode: :deferred
        )
      end)

    assert_receive :dashboard_checked_out

    try do
      assert ControlServer.status(control)["status"] == "PAUSED"
    after
      send(held.pid, :release_dashboard)
      Task.await(held)
    end
  end

  test "initialization is idempotent and begins paused", %{connection: connection} do
    assert %{result: "INITIALIZED", control: control} =
             Control.initialize(connection, @config, now: DateTime.add(@now, 5, :second))

    assert control["status"] == "PAUSED"
    assert control["dispatcher_id"] == "dispatcher-a"
    assert control["generation"] == 0
  end

  test "records the controller project with its reopenable task identity", %{connection: connection} do
    route = %{
      project_id: "project-grail",
      section_id: "section-factory",
      resolved_role: "orchestrator",
      provider: "codex",
      model_class: "balanced",
      model: "gpt-test",
      reasoning_effort: "medium",
      routing_reason: "exact role"
    }

    assert %{result: "CONTROLLER_TASK_RECORDED", control: control} =
             Control.record_controller_task(connection, @config, "thread-controller", "turn-1", route)

    assert control["controller_thread_id"] == "thread-controller"
    assert control["controller_codex_project_id"] == "project-grail"
    assert control["controller_codex_section_id"] == "section-factory"
  end

  test "durably tracks and clears consecutive controller writer conflicts", %{
    connection: connection
  } do
    Control.record_controller_task(connection, @config, "thread-controller", "turn-1")

    assert %{result: "CONTROLLER_WRITER_CONFLICT_RECORDED", control: first} =
             Control.record_controller_writer_conflict(
               connection,
               @config,
               "thread-controller",
               now: @now
             )

    assert first["controller_writer_conflict_since"] == "2026-09-21T20:00:00Z"
    assert first["controller_writer_conflict_count"] == 1

    assert %{result: "CONTROLLER_WRITER_CONFLICT_RECORDED", control: second} =
             Control.record_controller_writer_conflict(
               connection,
               @config,
               "thread-controller",
               now: DateTime.add(@now, 60, :second)
             )

    assert second["controller_writer_conflict_since"] == "2026-09-21T20:00:00Z"
    assert second["controller_writer_conflict_count"] == 2

    assert %{result: "STALE_CONTROLLER"} =
             Control.clear_controller_writer_conflict(
               connection,
               @config,
               "different-thread",
               now: @now
             )

    assert %{result: "CONTROLLER_WRITER_CONFLICT_CLEARED", control: cleared} =
             Control.clear_controller_writer_conflict(
               connection,
               @config,
               "thread-controller",
               now: DateTime.add(@now, 120, :second)
             )

    assert cleared["controller_writer_conflict_since"] == nil
    assert cleared["controller_writer_conflict_count"] == 0
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

  test "renewal extends only the exact active lease", %{connection: connection} do
    assert {:ok, _activated} = Control.activate(connection, @config, "dispatcher-a", now: @now)

    assert %{result: "ACQUIRED"} =
             Control.acquire_tick(connection, @config, "dispatcher-a", now: @now, tick_id: "tick-a")

    renewal_time = DateTime.add(@now, 120, :second)

    assert %{
             result: "LEASE_RENEWED",
             tick_id: "tick-a",
             lease_expires_at: "2026-09-21T20:06:00Z"
           } =
             Control.renew_tick(connection, @config, "dispatcher-a", "tick-a", now: renewal_time)

    assert %{result: "LEASE_MISMATCH"} =
             Control.renew_tick(connection, @config, "dispatcher-a", "other", now: renewal_time)

    assert %{result: "LEASE_HELD", tick_id: "tick-a"} =
             Control.acquire_tick(connection, @config, "dispatcher-a",
               now: DateTime.add(@now, 300, :second),
               tick_id: "replacement"
             )
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
