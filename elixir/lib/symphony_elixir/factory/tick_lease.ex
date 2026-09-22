defmodule SymphonyElixir.Factory.TickLease do
  @moduledoc """
  Executes one bounded scheduler tick under the durable factory lease.
  """

  require Logger

  alias SymphonyElixir.Factory.ControlServer

  @doc """
  Runs a function when factory control is disabled or when the exact dispatcher
  acquires the lease. The acquired tick is always released in an `after` path.
  """
  @spec run(struct() | map(), (-> result), keyword()) :: {:ran, result} | {:skipped, String.t()}
        when result: var
  def run(factory, fun, opts \\ []) when is_function(fun, 0) do
    if Map.get(factory, :enabled, false) do
      run_controlled(factory, fun, opts)
    else
      {:ran, fun.()}
    end
  end

  defp run_controlled(factory, fun, opts) do
    control_server = Keyword.get(opts, :control_server, ControlServer)
    dispatcher_id = Map.fetch!(factory, :dispatcher_id)

    case call_control(fn -> ControlServer.acquire_tick(dispatcher_id, control_server) end) do
      %{result: "ACQUIRED", tick_id: tick_id} ->
        try do
          run_with_renewal(factory, fun, control_server, dispatcher_id, tick_id, opts)
        after
          release_tick(control_server, dispatcher_id, tick_id)
        end

      %{result: result} when result in ["PAUSED", "LEASE_HELD", "DISPATCHER_CONFLICT"] ->
        {:skipped, result}

      {:error, reason} ->
        Logger.error("Factory tick control unavailable: #{inspect(reason)}")
        {:skipped, "CONTROL_UNAVAILABLE"}

      unexpected ->
        Logger.error("Factory tick acquisition returned an unexpected result: #{inspect(unexpected)}")
        {:skipped, "CONTROL_UNAVAILABLE"}
    end
  end

  defp run_with_renewal(factory, fun, control_server, dispatcher_id, tick_id, opts) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        outcome =
          try do
            {:returned, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(caller, {result_ref, outcome})
      end)

    lease_seconds = Map.get(factory, :lease_seconds, 240)

    renewal_interval_ms =
      Keyword.get(opts, :renewal_interval_ms, max(div(lease_seconds * 1_000, 3), 100))

    await_result(
      pid,
      monitor_ref,
      result_ref,
      renewal_interval_ms,
      control_server,
      dispatcher_id,
      tick_id
    )
  end

  defp await_result(
         pid,
         monitor_ref,
         result_ref,
         renewal_interval_ms,
         control_server,
         dispatcher_id,
         tick_id
       ) do
    receive do
      {^result_ref, {:returned, result}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ran, result}

      {^result_ref, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(monitor_ref, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        exit(reason)
    after
      renewal_interval_ms ->
        case renew_tick(control_server, dispatcher_id, tick_id) do
          %{result: "LEASE_RENEWED"} ->
            await_result(
              pid,
              monitor_ref,
              result_ref,
              renewal_interval_ms,
              control_server,
              dispatcher_id,
              tick_id
            )

          reason ->
            Process.exit(pid, :kill)
            await_down(monitor_ref, pid)
            {:ran, {:error, {:tick_lease_lost, reason}}}
        end
    end
  end

  defp renew_tick(control_server, dispatcher_id, tick_id) do
    call_control(fn -> ControlServer.renew_tick(dispatcher_id, tick_id, control_server) end)
  end

  defp await_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp release_tick(control_server, dispatcher_id, tick_id) do
    case call_control(fn -> ControlServer.release_tick(dispatcher_id, tick_id, control_server) end) do
      %{result: "RELEASED"} ->
        :ok

      result ->
        Logger.error("Factory tick release failed for tick_id=#{tick_id}: #{inspect(result)}")
        :error
    end
  end

  defp call_control(fun) do
    fun.()
  catch
    :exit, reason -> {:error, reason}
  end
end
