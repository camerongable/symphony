defmodule SymphonyElixir.Factory.ControlServer do
  @moduledoc """
  Serialized runtime access to the durable dispatcher control record.
  """

  use GenServer

  alias SymphonyElixir.Factory.Control

  @type state :: %{
          store: DBConnection.conn(),
          config: Control.config()
        }

  @doc """
  Starts the control server and initializes its durable row.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current durable control row.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Records observed tick health separately from dispatch authorization and lease activity."
  @spec record_tick(:reset | :started | :succeeded | {:failed, String.t()}, GenServer.server()) ::
          :ok | {:error, :unavailable}
  def record_tick(result, server \\ __MODULE__) do
    GenServer.call(server, {:record_tick, result})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Persists the visible controller Codex task identity."
  @spec record_controller_task(String.t(), String.t() | nil, map(), GenServer.server()) :: map()
  def record_controller_task(thread_id, turn_id, route \\ %{}, server \\ __MODULE__),
    do: GenServer.call(server, {:record_controller_task, thread_id, turn_id, route})

  @doc "Records an active-writer conflict for the current controller task."
  @spec record_controller_writer_conflict(String.t(), GenServer.server()) :: map()
  def record_controller_writer_conflict(thread_id, server \\ __MODULE__),
    do: GenServer.call(server, {:record_controller_writer_conflict, thread_id})

  @doc "Clears active-writer conflict state after a successful controller resume."
  @spec clear_controller_writer_conflict(String.t(), GenServer.server()) :: map()
  def clear_controller_writer_conflict(thread_id, server \\ __MODULE__),
    do: GenServer.call(server, {:clear_controller_writer_conflict, thread_id})

  @doc """
  Activates the supplied dispatcher if no live tick lease exists.
  """
  @spec activate(String.t(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def activate(dispatcher_id, server \\ __MODULE__), do: GenServer.call(server, {:activate, dispatcher_id})

  @doc """
  Pauses the supplied dispatcher if no live tick lease exists.
  """
  @spec pause(String.t(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def pause(dispatcher_id, server \\ __MODULE__), do: GenServer.call(server, {:pause, dispatcher_id})

  @doc """
  Acquires one scheduler tick for the supplied dispatcher.
  """
  @spec acquire_tick(String.t(), GenServer.server()) :: map()
  def acquire_tick(dispatcher_id, server \\ __MODULE__),
    do: GenServer.call(server, {:acquire_tick, dispatcher_id})

  @doc "Acquires an exclusive recovery-only tick without activating the factory."
  @spec acquire_recovery_tick(String.t(), GenServer.server()) :: map()
  def acquire_recovery_tick(dispatcher_id, server \\ __MODULE__),
    do: GenServer.call(server, {:acquire_recovery_tick, dispatcher_id})

  @doc "Renews the exact recovery tick without activating the factory."
  @spec renew_recovery_tick(String.t(), String.t(), GenServer.server(), pos_integer()) :: map()
  def renew_recovery_tick(dispatcher_id, tick_id, server \\ __MODULE__, timeout \\ 5_000)
      when is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(server, {:renew_recovery_tick, dispatcher_id, tick_id, deadline}, timeout)
  end

  @doc "Renews the exact tick held by the supplied dispatcher."
  @spec renew_tick(String.t(), String.t(), GenServer.server(), pos_integer()) :: map()
  def renew_tick(dispatcher_id, tick_id, server \\ __MODULE__, timeout \\ 5_000)
      when is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(server, {:renew_tick, dispatcher_id, tick_id, deadline}, timeout)
  end

  @doc """
  Releases the exact tick held by the supplied dispatcher.
  """
  @spec release_tick(String.t(), String.t(), GenServer.server()) :: map()
  def release_tick(dispatcher_id, tick_id, server \\ __MODULE__),
    do: GenServer.call(server, {:release_tick, dispatcher_id, tick_id})

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    factory = Keyword.fetch!(opts, :factory)

    config = %{
      scope: factory.scope,
      dispatcher_id: factory.dispatcher_id,
      lease_seconds: factory.lease_seconds
    }

    Control.initialize(store, config)

    {:ok,
     %{
       store: store,
       read_store: Keyword.get(opts, :read_store, store),
       config: config,
       tick_health: empty_tick_health(),
       runtime_identity: %{
         control_server_started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         beam_started_at: beam_started_at(),
         beam_start_source: "erlang.system_info(start_time) + System.time_offset",
         os_pid: System.pid(),
         factory_beam_fingerprint: factory_beam_fingerprint(),
         factory_beam_fingerprint_source: "code-path object bytes at control-server initialization; not deployment proof",
         factory_beam_module_count: factory_beam_modules() |> length()
       }
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      Control.status(state.read_store, state.config.scope)
      |> Map.put("runtime_identity", state.runtime_identity)
      |> Map.put("tick_health", state.tick_health)

    {:reply, status, state}
  end

  def handle_call({:record_tick, result}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    health =
      case result do
        :reset ->
          empty_tick_health()

        :started ->
          %{state.tick_health | last_started_at: now}

        :succeeded ->
          %{state.tick_health | status: "HEALTHY", last_completed_at: now, last_success_at: now, consecutive_failures: 0, last_error: nil}

        {:failed, code} ->
          %{state.tick_health | status: "FAILED", last_completed_at: now, consecutive_failures: state.tick_health.consecutive_failures + 1, last_error: String.slice(code, 0, 240)}
      end

    {:reply, :ok, %{state | tick_health: health}}
  end

  def handle_call({:record_controller_task, thread_id, turn_id, route}, _from, state) do
    {:reply, Control.record_controller_task(state.store, state.config, thread_id, turn_id, route), state}
  end

  def handle_call({:record_controller_writer_conflict, thread_id}, _from, state) do
    {:reply, Control.record_controller_writer_conflict(state.store, state.config, thread_id), state}
  end

  def handle_call({:clear_controller_writer_conflict, thread_id}, _from, state) do
    {:reply, Control.clear_controller_writer_conflict(state.store, state.config, thread_id), state}
  end

  def handle_call({:activate, dispatcher_id}, _from, state) do
    {:reply, Control.activate(state.store, state.config, dispatcher_id), state}
  end

  def handle_call({:pause, dispatcher_id}, _from, state) do
    {:reply, Control.pause(state.store, state.config, dispatcher_id), state}
  end

  def handle_call({:acquire_tick, dispatcher_id}, _from, state) do
    {:reply, Control.acquire_tick(state.store, state.config, dispatcher_id), state}
  end

  def handle_call({:acquire_recovery_tick, dispatcher_id}, _from, state) do
    {:reply, Control.acquire_recovery_tick(state.store, state.config, dispatcher_id), state}
  end

  def handle_call({:renew_recovery_tick, dispatcher_id, tick_id, deadline}, from, state) do
    start_renewal(state, dispatcher_id, tick_id, deadline, &Control.renew_recovery_tick/5, from)
  end

  def handle_call({:renew_tick, dispatcher_id, tick_id, deadline}, from, state) do
    start_renewal(state, dispatcher_id, tick_id, deadline, &Control.renew_tick/5, from)
  end

  def handle_call({:release_tick, dispatcher_id, tick_id}, _from, state) do
    {:reply, Control.release_tick(state.store, state.config, dispatcher_id, tick_id), state}
  end

  @impl true
  def handle_info({:renewal_result, pid, result}, %{renewal: %{pid: pid, ref: ref, from: from}} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, result)
    {:noreply, Map.delete(state, :renewal)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{renewal: %{pid: pid, ref: ref, from: from}} = state) do
    GenServer.reply(from, %{result: "RENEWAL_DATABASE_UNAVAILABLE"})
    {:noreply, Map.delete(state, :renewal)}
  end

  @impl true
  def terminate(_reason, state) do
    if state[:renewal], do: Process.exit(state.renewal.pid, :kill)
    :ok
  end

  defp start_renewal(%{renewal: _pending} = state, _dispatcher_id, _tick_id, _deadline, _renew, _from) do
    {:reply, %{result: "RENEWAL_BUSY"}, state}
  end

  defp start_renewal(state, dispatcher_id, tick_id, deadline, renew, from) do
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = renew_with_deadline(state, dispatcher_id, tick_id, deadline, renew, owner)
        send(owner, {:renewal_result, self(), result})
      end)

    {:noreply, Map.put(state, :renewal, %{pid: pid, ref: ref, from: from})}
  end

  defp renew_with_deadline(state, dispatcher_id, tick_id, deadline, renew, owner) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      %{result: "RENEWAL_TIMEOUT"}
    else
      try do
        renew.(state.store, state.config, dispatcher_id, tick_id, timeout: remaining, renewal_deadline: deadline, renewal_owner: owner)
      rescue
        error in DBConnection.ConnectionError ->
          # Queue rejection happens before transaction execution; no lease mutation is replayed.
          cond do
            System.monotonic_time(:millisecond) >= deadline ->
              %{result: "RENEWAL_TIMEOUT"}

            error.reason == :queue_timeout ->
              Process.sleep(min(100, max(0, deadline - System.monotonic_time(:millisecond))))
              renew_with_deadline(state, dispatcher_id, tick_id, deadline, renew, owner)

            true ->
              %{result: "RENEWAL_DATABASE_UNAVAILABLE"}
          end
      end
    end
  end

  defp empty_tick_health do
    %{
      status: "UNKNOWN",
      last_started_at: nil,
      last_completed_at: nil,
      last_success_at: nil,
      consecutive_failures: 0,
      last_error: nil
    }
  end

  defp beam_started_at do
    :erlang.system_info(:start_time)
    |> System.convert_time_unit(:native, :millisecond)
    |> Kernel.+(System.time_offset(:millisecond))
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp factory_beam_modules do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.SymphonyElixir.Factory."))
    |> Enum.sort()
  end

  defp factory_beam_fingerprint do
    module_digests =
      Enum.map(factory_beam_modules(), fn module ->
        digest =
          case :code.get_object_code(module) do
            {^module, binary, _path} -> :crypto.hash(:sha256, binary)
            _other -> <<>>
          end

        {Atom.to_string(module), digest}
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(module_digests))
    |> Base.encode16(case: :lower)
  end
end
