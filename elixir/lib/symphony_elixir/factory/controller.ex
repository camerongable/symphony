defmodule SymphonyElixir.Factory.Controller do
  @moduledoc """
  Local OTP owner for recurring factory reconciliation and visible stage tasks.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Factory}
  alias SymphonyElixir.Factory.{Scheduler, TickLease}

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

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_cast(:reconcile_now, state), do: {:noreply, schedule(state, 0)}

  @impl true
  def handle_info(:tick, %State{tick_pid: nil} = state) do
    parent = self()
    context = scheduler_context(state, parent)

    case start_tick(state, parent, context) do
      {:ok, pid} ->
        {:noreply, %{state | tick_pid: pid, tick_ref: Process.monitor(pid), timer_ref: nil}}

      {:error, reason} ->
        Logger.error("Unable to start factory tick: #{inspect(reason)}")
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
          fn -> Scheduler.tick(context) end,
          control_server: state.control_server
        )

      result =
        case result do
          {:skipped, "PAUSED"} -> TickLease.reconcile(context, control_server: state.control_server)
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
    Enum.reduce(result.launches, state, fn launch, current ->
      ref = Process.monitor(launch.pid)
      put_in(current.active_tasks[launch.task_key], %{pid: launch.pid, ref: ref})
    end)
  end

  defp integrate_tick_result(state, {:ran, {:error, reason}}) do
    Logger.error("Factory reconciliation failed: #{inspect(reason)}")
    state
  end

  defp integrate_tick_result(state, {:skipped, _quiet_reason}), do: state

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
