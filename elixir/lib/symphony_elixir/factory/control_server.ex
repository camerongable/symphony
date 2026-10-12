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
  @spec renew_recovery_tick(String.t(), String.t(), GenServer.server()) :: map()
  def renew_recovery_tick(dispatcher_id, tick_id, server \\ __MODULE__),
    do: GenServer.call(server, {:renew_recovery_tick, dispatcher_id, tick_id})

  @doc "Renews the exact tick held by the supplied dispatcher."
  @spec renew_tick(String.t(), String.t(), GenServer.server()) :: map()
  def renew_tick(dispatcher_id, tick_id, server \\ __MODULE__),
    do: GenServer.call(server, {:renew_tick, dispatcher_id, tick_id})

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
       config: config,
       runtime_identity: %{
         process_started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         factory_beam_fingerprint: factory_beam_fingerprint(),
         factory_beam_module_count: factory_beam_modules() |> length()
       }
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = Control.status(state.store, state.config.scope) |> Map.put("runtime_identity", state.runtime_identity)
    {:reply, status, state}
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

  def handle_call({:renew_recovery_tick, dispatcher_id, tick_id}, _from, state) do
    {:reply, Control.renew_recovery_tick(state.store, state.config, dispatcher_id, tick_id), state}
  end

  def handle_call({:renew_tick, dispatcher_id, tick_id}, _from, state) do
    {:reply, Control.renew_tick(state.store, state.config, dispatcher_id, tick_id), state}
  end

  def handle_call({:release_tick, dispatcher_id, tick_id}, _from, state) do
    {:reply, Control.release_tick(state.store, state.config, dispatcher_id, tick_id), state}
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
