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
          {:ran, fun.()}
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
