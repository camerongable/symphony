defmodule SymphonyElixir.Factory.TickLease do
  @moduledoc """
  Executes one bounded scheduler tick under the durable factory lease.
  """

  require Logger

  alias SymphonyElixir.Factory.{ControlServer, Scheduler}

  @doc """
  Runs a function when factory control is disabled or when the exact dispatcher
  acquires the lease. The acquired tick is always released in an `after` path.
  """
  @spec run(struct() | map(), (-> result) | (map() | nil -> result), keyword()) :: {:ran, result} | {:skipped, String.t()}
        when result: var
  def run(factory, fun, opts \\ []) when is_function(fun, 0) or is_function(fun, 1) do
    if Map.get(factory, :enabled, false) do
      run_controlled(factory, fun, Keyword.delete(opts, :recovery_only))
    else
      {:ran, invoke(fun, nil)}
    end
  end

  @doc "Runs only the bounded Jira readback entrypoint under an exclusive lease, including while paused."
  @spec reconcile(map(), keyword()) :: {:ran, term()} | {:skipped, String.t()}
  def reconcile(context, opts \\ []) do
    callback = fn -> Scheduler.reconcile_ticket_jira(context, Keyword.get(opts, :scheduler_options, [])) end
    run_controlled(context.factory, callback, Keyword.put(opts, :recovery_only, true))
  end

  defp run_controlled(factory, fun, opts) do
    control_server = Keyword.get(opts, :control_server, ControlServer)
    dispatcher_id = Map.fetch!(factory, :dispatcher_id)

    acquire = if opts[:recovery_only], do: &ControlServer.acquire_recovery_tick/2, else: &ControlServer.acquire_tick/2

    case call_control(fn -> acquire.(dispatcher_id, control_server) end) do
      %{result: "ACQUIRED", tick_id: tick_id, generation: generation} ->
        binding = if opts[:recovery_only], do: nil, else: %{"scope" => factory.scope, "dispatcher_id" => dispatcher_id, "generation" => generation, "tick_id" => tick_id}

        try do
          run_with_renewal(factory, fn -> invoke(fun, binding) end, control_server, dispatcher_id, tick_id, opts)
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

  defp invoke(fun, binding) when is_function(fun, 1), do: fun.(binding)
  defp invoke(fun, _binding), do: fun.()

  defp run_with_renewal(factory, fun, control_server, dispatcher_id, tick_id, opts) do
    lease_ms = Map.get(factory, :lease_seconds, 240) * 1_000
    renewal_interval_ms = Keyword.get(opts, :renewal_interval_ms, max(div(lease_ms, 3), 100))

    if is_integer(renewal_interval_ms) and renewal_interval_ms > 0 and renewal_interval_ms < lease_ms - 1 do
      # Adoption can hold the shared connection for 60s; both waits must fit before lease expiry.
      renewal_timeout_ms = min(65_000, min(div(lease_ms, 3), lease_ms - renewal_interval_ms - 1))
      run_tick(fun, control_server, dispatcher_id, tick_id, opts[:recovery_only] == true, renewal_interval_ms, renewal_timeout_ms)
    else
      {:ran, {:error, :invalid_tick_renewal_interval}}
    end
  end

  defp run_tick(fun, control_server, dispatcher_id, tick_id, recovery, renewal_interval_ms, renewal_timeout_ms) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        bind_callback_owner(caller)

        outcome =
          try do
            {:returned, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(caller, {result_ref, outcome})
      end)

    renewer = fn -> renew_tick(control_server, dispatcher_id, tick_id, recovery, renewal_timeout_ms) end

    await_result(
      pid,
      monitor_ref,
      result_ref,
      renewal_interval_ms,
      renewer
    )
  end

  defp bind_callback_owner(owner) do
    callback = self()
    armed = make_ref()

    # The renewing owner must stay monitor-only: renewal loss deliberately kills the callback.
    guard =
      spawn_link(fn ->
        owner_ref = Process.monitor(owner)
        callback_ref = Process.monitor(callback)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(callback, :kill)
        after
          0 ->
            send(callback, {armed, self()})

            receive do
              {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(callback, :kill)
              {:DOWN, ^callback_ref, :process, ^callback, _reason} -> :ok
            end
        end
      end)

    receive do
      {^armed, ^guard} -> :ok
    end
  end

  defp await_result(
         pid,
         monitor_ref,
         result_ref,
         renewal_interval_ms,
         renewer
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
        case renewer.() do
          %{result: "LEASE_RENEWED"} ->
            await_result(
              pid,
              monitor_ref,
              result_ref,
              renewal_interval_ms,
              renewer
            )

          reason ->
            Process.exit(pid, :kill)
            await_down(monitor_ref, pid)
            {:ran, {:error, {:tick_lease_lost, reason}}}
        end
    end
  end

  defp renew_tick(control_server, dispatcher_id, tick_id, recovery, timeout) do
    renew = if recovery, do: &ControlServer.renew_recovery_tick/4, else: &ControlServer.renew_tick/4
    call_control(fn -> renew.(dispatcher_id, tick_id, control_server, timeout) end)
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
