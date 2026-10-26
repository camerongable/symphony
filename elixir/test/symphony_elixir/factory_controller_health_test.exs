defmodule SymphonyElixir.FactoryControllerHealthTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Controller, ControlServer, Observability, Store}

  setup do
    token = System.unique_integer([:positive])
    database = Path.join(System.tmp_dir!(), "factory-health-#{token}.sqlite")
    store = start_supervised!({Store, database: database})

    factory = %{
      enabled: true,
      scope: "health-#{token}",
      dispatcher_id: "dispatcher",
      lease_seconds: 240,
      repositories: %{}
    }

    options = [store: store, factory: factory, name: {:global, {:factory_health, token}}]
    server = start_supervised!({ControlServer, options})
    on_exit(fn -> File.rm(database) end)
    %{store: store, factory: factory, server: server}
  end

  test "a returned error and retry stay failed until an ordinary tick succeeds", c do
    assert health(c).status == "UNKNOWN"
    complete(c, {:ran, {:error, :mcp_tool_error}})
    assert %{status: "FAILED", consecutive_failures: 1, last_error: "mcp_tool_error"} = health(c)
    :ok = ControlServer.record_tick(:started, c.server)
    assert health(c).status == "FAILED"
    complete(c, {:skipped, "LEASE_HELD"})
    complete(c, {:recovery, {:ran, {:ok, %{launches: []}}}})
    assert health(c).status == "FAILED"

    snapshot = Observability.snapshot(settings: %{factory: c.factory}, store: c.store, control_server: c.server)
    assert snapshot.control.tick_health == health(c)

    complete(c, {:ran, {:ok, %{launches: []}}})
    assert %{status: "HEALTHY", consecutive_failures: 0, last_error: nil, last_success_at: success} = health(c)
    assert is_binary(success)
  end

  test "restarting a control server does not change the BEAM process identity", c do
    first = ControlServer.status(c.server)["runtime_identity"]
    assert first.os_pid == System.pid()
    assert first.beam_start_source =~ "start_time"
    assert first.factory_beam_fingerprint_source =~ "not deployment proof"
    refute Map.has_key?(first, :process_started_at)
    assert {:ok, beam, _} = DateTime.from_iso8601(first.beam_started_at)
    assert {:ok, server, _} = DateTime.from_iso8601(first.control_server_started_at)
    assert DateTime.compare(beam, server) in [:lt, :eq]
    next = start_supervised!({ControlServer, store: c.store, factory: c.factory, name: nil}, id: :second_control_server)
    second = ControlServer.status(next)["runtime_identity"]
    assert second.beam_started_at == first.beam_started_at
    assert second.os_pid == first.os_pid
    assert second.control_server_started_at != first.control_server_started_at
  end

  test "tick crashes and control unavailability are observable without exposing exception arguments", c do
    state = state(c)
    exception = %UndefinedFunctionError{module: SecretConfiguration, function: :fetch, arity: 2}
    message = {:DOWN, state.tick_ref, :process, self(), {exception, [:private_arguments]}}
    {:noreply, next} = Controller.handle_info(message, state)
    Process.cancel_timer(next.timer_ref)
    assert %{status: "FAILED", last_error: "UndefinedFunctionError"} = health(c)
    complete(c, {:skipped, "CONTROL_UNAVAILABLE"})
    assert %{status: "FAILED", consecutive_failures: 2, last_error: "control_unavailable"} = health(c)
  end

  test "failure to launch a tick is recorded", c do
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})
    state = %{state(c) | tick_pid: nil, tick_ref: nil, task_supervisor: supervisor}
    {:noreply, next} = Controller.handle_info(:tick, state)
    Process.cancel_timer(next.timer_ref)
    assert %{status: "FAILED", last_error: "max_children"} = health(c)
  end

  test "restarting the controller invalidates an earlier healthy observation", c do
    :ok = ControlServer.record_tick(:succeeded, c.server)
    assert health(c).status == "HEALTHY"
    {:ok, next} = Controller.init(settings: %{factory: c.factory, polling: %{interval_ms: 60_000}}, store: c.store, control_server: c.server)
    Process.cancel_timer(next.timer_ref)
    assert %{status: "UNKNOWN", last_success_at: nil} = health(c)
  end

  test "health reporting cannot crash the controller when its control server is unavailable", c do
    unavailable = {:global, {:absent_health_server, make_ref()}}
    assert {:error, :unavailable} = ControlServer.record_tick(:started, unavailable)
    state = %{state(c) | control_server: unavailable}

    for result <- [{:skipped, "CONTROL_UNAVAILABLE"}, {:ran, {:ok, %{launches: []}}}] do
      {:noreply, next} = Controller.handle_info({:factory_tick_finished, self(), result}, state)
      Process.cancel_timer(next.timer_ref)
      assert next.tick_pid == nil
    end
  end

  defp state(c), do: %Controller.State{factory: c.factory, store: c.store, control_server: c.server, poll_interval_ms: 60_000, tick_pid: self(), tick_ref: make_ref()}
  defp health(c), do: ControlServer.status(c.server)["tick_health"]

  defp complete(c, result) do
    {:noreply, next} = Controller.handle_info({:factory_tick_finished, self(), result}, state(c))
    Process.cancel_timer(next.timer_ref)
  end
end
