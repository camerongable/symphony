defmodule SymphonyElixir.Factory.Controller do
  require DBConnection.Holder

  @moduledoc """
  Local OTP owner for recurring factory reconciliation and visible stage tasks.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Factory}
  alias SymphonyElixir.Factory.{ControlServer, Scheduler, Store, TickLease}

  defmodule State do
    @moduledoc false
    defstruct [
      :factory,
      :poll_interval_ms,
      :store,
      :control_server,
      :task_supervisor,
      :tick_pid,
      :tick_ref,
      :timer_ref,
      active_tasks: %{}
    ]
  end

  @doc "Starts the local factory controller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Requests one near-term bounded tick without waiting for the normal cadence."
  @spec reconcile_now(GenServer.server()) :: :ok
  def reconcile_now(server \\ __MODULE__), do: GenServer.cast(server, :reconcile_now)

  @doc "Reads only the genuine controller owner's cached CI-generation policy and one repository route."
  @spec cached_generation_policy(Store.connection(), String.t()) :: {:ok, map()} | {:error, atom()}
  def cached_generation_policy(store, repo_key) when is_binary(repo_key) do
    with owner when is_pid(owner) <- Process.whereis(__MODULE__),
         true <- owner != self() and :proc_lib.translate_initial_call(owner) == {__MODULE__, :init, 1},
         store_pid when is_pid(store_pid) <- store_identity(store) do
      GenServer.call(owner, {:cached_generation_policy, store_pid, repo_key}, 1000)
    else
      _ -> {:error, :controller_generation_policy_unavailable}
    end
  catch
    :exit, _ -> {:error, :controller_generation_policy_unavailable}
  end

  def cached_generation_policy(_, _), do: {:error, :controller_generation_policy_unavailable}

  @impl true
  def init(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    state = %State{
      factory: settings.factory,
      poll_interval_ms: settings.polling.interval_ms,
      store: Keyword.get(opts, :store, Factory.Supervisor.store_name()),
      control_server: Keyword.get(opts, :control_server, Factory.Supervisor.control_name()),
      task_supervisor: Keyword.get(opts, :task_supervisor, Factory.TaskSupervisor)
    }

    ControlServer.record_tick(:reset, state.control_server)
    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call({:cached_generation_policy, store_pid, repo_key}, _from, state) do
    result =
      with true <- store_identity(state.store) == store_pid,
           %{} = route <- Map.get(state.factory.repositories, repo_key) do
        supervisor = Map.get(state.factory, :ticket_supervisor, %{})

        {:ok,
         %{
           "enabled" => state.factory.enabled,
           "scope" => state.factory.scope,
           "dispatcher_id" => state.factory.dispatcher_id,
           "maximum_code_repair_rounds" => Map.get(state.factory, :maximum_code_repair_rounds),
           "ci_repair_scope_extensions" => Map.get(state.factory, :ci_repair_scope_extensions, %{}),
           "ticket_supervisor_enabled" => supervisor["enabled"],
           "ci_repair" => supervisor["ci_repair"],
           "pilot_issue_keys" => supervisor["pilot_issue_keys"],
           "ticket_selection" => Map.take(supervisor, ~w(enabled all_eligible_tickets pilot_issue_keys)),
           "repo_key" => repo_key,
           "route" => Map.take(route, ~w(path base_branch gitlab_project gitlab_project_id))
         }}
      else
        _ -> {:error, :controller_generation_policy_unavailable}
      end

    {:reply, result, state}
  end

  defp store_identity(store) when is_pid(store) or is_atom(store) do
    case GenServer.whereis(store) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp store_identity(%DBConnection{pool_ref: DBConnection.Holder.pool_ref(pool: pool)}) when is_pid(pool), do: store_identity(pool)
  defp store_identity(_), do: nil

  @impl true
  def handle_cast(:reconcile_now, state), do: {:noreply, schedule(state, 0)}

  @impl true
  def handle_info(:tick, %State{tick_pid: nil} = state) do
    parent = self()
    context = scheduler_context(state, parent)

    case start_tick(state, parent, context) do
      {:ok, pid} ->
        ControlServer.record_tick(:started, state.control_server)
        {:noreply, %{state | tick_pid: pid, tick_ref: Process.monitor(pid), timer_ref: nil}}

      {:error, reason} ->
        Logger.error("Unable to start factory tick: #{inspect(reason)}")
        record_tick_failure(state, reason)
        {:noreply, schedule(%{state | timer_ref: nil}, state.poll_interval_ms)}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:factory_tick_finished, pid, result}, %State{tick_pid: pid} = state) do
    state = clear_tick_monitor(state)
    state = integrate_tick_result(state, result)
    {:noreply, schedule(state, state.poll_interval_ms)}
  end

  def handle_info({:factory_task_started, task_key, thread_id}, state) do
    Logger.info("Factory task started task_key=#{task_key} thread_id=#{thread_id}")
    {:noreply, state}
  end

  def handle_info({:factory_task_finished, task_key, result}, state) do
    Logger.info("Factory task finished task_key=#{task_key} result=#{result_label(result)}")
    state = drop_active_task(state, task_key)
    delay = if writer_conflict?(result), do: state.poll_interval_ms, else: 0
    {:noreply, schedule(state, delay)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tick_ref: ref} = state) do
    unless reason in [:normal, :shutdown] do
      Logger.error("Factory tick process exited: #{inspect(reason)}")
    end

    record_tick_failure(state, reason)

    state = %{state | tick_pid: nil, tick_ref: nil}
    {:noreply, schedule(state, state.poll_interval_ms)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.active_tasks, fn {_key, value} -> value.ref == ref end) do
      {task_key, _entry} ->
        unless reason in [:normal, :shutdown] do
          Logger.warning("Factory stage process exited task_key=#{task_key} reason=#{inspect(reason)}")
        end

        {:noreply, state |> drop_active_task(task_key) |> schedule(0)}

      nil ->
        {:noreply, state}
    end
  end

  defp start_tick(state, parent, context) do
    Task.Supervisor.start_child(state.task_supervisor, fn ->
      result =
        TickLease.run(
          state.factory,
          fn owned_tick -> Scheduler.tick(context, ticket_options: [operator_tick: owned_tick]) end,
          control_server: state.control_server
        )

      result =
        case result do
          {:skipped, "PAUSED"} -> {:recovery, TickLease.reconcile(context, control_server: state.control_server)}
          other -> other
        end

      send(parent, {:factory_tick_finished, self(), result})
    end)
  end

  defp scheduler_context(state, recipient) do
    %{
      factory: state.factory,
      store: state.store,
      control_server: state.control_server,
      task_supervisor: state.task_supervisor,
      active_task_keys: state.active_tasks |> Map.keys() |> MapSet.new(),
      active_tasks: state.active_tasks,
      recipient: recipient,
      workspace_root: Config.local_workspace_root()
    }
  end

  defp integrate_tick_result(state, {:ran, {:ok, result}}) do
    ControlServer.record_tick(:succeeded, state.control_server)
    track_launches(state, result)
  end

  defp integrate_tick_result(state, {:ran, {:error, reason}}) do
    Logger.error("Factory reconciliation failed: #{inspect(reason)}")
    record_tick_failure(state, reason)
    state
  end

  defp integrate_tick_result(state, {:recovery, {:ran, {:ok, result}}}), do: track_launches(state, result)

  defp integrate_tick_result(state, {:recovery, result}) do
    Logger.debug("Recovery-only tick finished: #{inspect(result, limit: 3)}")
    state
  end

  defp integrate_tick_result(state, {:skipped, "CONTROL_UNAVAILABLE"}) do
    record_tick_failure(state, :control_unavailable)
    state
  end

  defp integrate_tick_result(state, {:skipped, _quiet_reason}), do: state

  defp track_launches(state, result) do
    Enum.reduce(result.launches, state, fn launch, current ->
      ref = Process.monitor(launch.pid)
      put_in(current.active_tasks[launch.task_key], %{pid: launch.pid, ref: ref})
    end)
  end

  defp record_tick_failure(state, reason),
    do: ControlServer.record_tick({:failed, tick_failure_code(reason)}, state.control_server)

  defp tick_failure_code({%{__exception__: true, __struct__: type}, _stack}), do: inspect(type)
  defp tick_failure_code({tag, reason}) when is_atom(tag), do: "#{tag}:#{tick_failure_code(reason)}"
  defp tick_failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp tick_failure_code(_reason), do: "tick_failed"

  defp clear_tick_monitor(%State{tick_ref: nil} = state), do: %{state | tick_pid: nil}

  defp clear_tick_monitor(state) do
    Process.demonitor(state.tick_ref, [:flush])
    %{state | tick_pid: nil, tick_ref: nil}
  end

  defp drop_active_task(state, task_key) do
    case Map.pop(state.active_tasks, task_key) do
      {nil, _tasks} ->
        state

      {%{ref: ref}, tasks} ->
        Process.demonitor(ref, [:flush])
        %{state | active_tasks: tasks}
    end
  end

  defp schedule(%State{timer_ref: ref} = state, delay) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer_ref: Process.send_after(self(), :tick, delay)}
  end

  defp schedule(state, delay), do: %{state | timer_ref: Process.send_after(self(), :tick, delay)}

  defp result_label({:ok, _result}), do: "ok"
  defp result_label({:error, reason}), do: "error:#{inspect(reason)}"

  defp writer_conflict?({:error, reason}), do: Factory.TaskLauncher.retryable_writer_conflict?(reason)
  defp writer_conflict?(_result), do: false
end
