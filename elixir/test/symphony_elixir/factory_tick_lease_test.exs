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
