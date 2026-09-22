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
    {:ok, %{store: store, config: config}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Control.status(state.store, state.config.scope), state}
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

  def handle_call({:release_tick, dispatcher_id, tick_id}, _from, state) do
    {:reply, Control.release_tick(state.store, state.config, dispatcher_id, tick_id), state}
  end
end
