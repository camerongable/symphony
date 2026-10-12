defmodule SymphonyElixir.FactoryTickLeaseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, ControlServer, Store, TickLease}

  setup do
    suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-tick-#{suffix}.sqlite")
    store = start_supervised!({Store, database: database})
    control_name = Module.concat(__MODULE__, "Control#{suffix}")

    factory = %{
      enabled: true,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240
    }

    start_supervised!({ControlServer, store: store, factory: factory, name: control_name})
    on_exit(fn -> File.rm(database) end)
    %{control_name: control_name, factory: factory, store: store}
  end

  test "paused control is a quiet no-op", context do
    ref = make_ref()

    assert {:skipped, "PAUSED"} =
             TickLease.run(context.factory, fn -> send(self(), ref) end, control_server: context.control_name)

    refute_received ^ref
  end

  test "runs under a lease and releases the exact tick", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)

    assert {:ran, :completed} =
             TickLease.run(context.factory, fn -> :completed end, control_server: context.control_name)

    assert %{"tick_id" => nil, "status" => "ACTIVE"} =
             Control.status(context.store, context.factory.scope)
  end

  defmodule NoQueueRead do
    def search(_query, _opts), do: raise("recovery must not poll the queue")
    def issue(_key, _opts), do: raise("an empty recovery set must not read Jira")
  end

  test "paused recovery runs only the fixed readback entrypoint and releases without activating", context do
    recovery_context = %{store: context.store, factory: context.factory}
    options = [control_server: context.control_name, scheduler_options: [jira_reader: NoQueueRead]]
    assert {:ran, {:ok, %{launches: [], events: []}}} = TickLease.reconcile(recovery_context, options)
    assert %{"status" => "PAUSED", "tick_id" => nil} = ControlServer.status(context.control_name)
    assert {:skipped, "PAUSED"} = TickLease.run(context.factory, fn -> raise "must not run" end, control_server: context.control_name, recovery_only: true)
  end

  test "recovery obeys dispatcher identity and excludes competing leases while paused", context do
    wrong = %{store: context.store, factory: %{context.factory | dispatcher_id: "other"}}
    assert {:skipped, "DISPATCHER_CONFLICT"} = TickLease.reconcile(wrong, control_server: context.control_name)
    assert %{result: "ACQUIRED", tick_id: tick} = ControlServer.acquire_recovery_tick("dispatcher-a", context.control_name)
    assert %{result: "LEASE_HELD"} = ControlServer.acquire_recovery_tick("dispatcher-a", context.control_name)
    assert %{result: "LEASE_MISMATCH"} = ControlServer.renew_recovery_tick("other", tick, context.control_name)
    assert %{result: "LEASE_RENEWED"} = ControlServer.renew_recovery_tick("dispatcher-a", tick, context.control_name)
    recovery_context = %{store: context.store, factory: context.factory}
    assert {:skipped, "LEASE_HELD"} = TickLease.reconcile(recovery_context, control_server: context.control_name)
    assert {:error, :live_tick_lease} = ControlServer.activate("dispatcher-a", context.control_name)
    assert %{result: "RELEASED"} = ControlServer.release_tick("dispatcher-a", tick, context.control_name)
    assert %{result: "LEASE_MISMATCH"} = ControlServer.renew_recovery_tick("dispatcher-a", tick, context.control_name)
    assert %{"status" => "PAUSED", "tick_id" => nil} = ControlServer.status(context.control_name)
  end

  test "releases the lease when the bounded tick raises", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)

    assert_raise RuntimeError, "boom", fn ->
      TickLease.run(context.factory, fn -> raise "boom" end, control_server: context.control_name)
    end

    assert %{"tick_id" => nil} = Control.status(context.store, context.factory.scope)
  end

  test "a long tick renews its lease before it expires", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    task =
      Task.async(fn ->
        TickLease.run(
          context.factory,
          fn ->
            send(parent, :long_tick_started)
            Process.sleep(250)
            :completed
          end,
          control_server: context.control_name,
          renewal_interval_ms: 50
        )
      end)

    assert_receive :long_tick_started
    Process.sleep(120)

    assert %{result: "LEASE_HELD"} =
             ControlServer.acquire_tick("dispatcher-a", context.control_name)

    assert {:ran, :completed} = Task.await(task)
    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end
end
