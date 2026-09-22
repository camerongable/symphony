defmodule SymphonyElixir.Factory.Supervisor do
  @moduledoc """
  Supervises the durable factory control plane when enabled by `WORKFLOW.md`.
  """

  use Supervisor

  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.{ControlServer, Store}

  @store_name SymphonyElixir.Factory.Store
  @control_name SymphonyElixir.Factory.ControlServer

  @doc """
  Starts the optional factory supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    if settings.factory.enabled do
      name = Keyword.get(opts, :name, __MODULE__)
      Supervisor.start_link(__MODULE__, settings.factory, name: name)
    else
      :ignore
    end
  end

  @impl true
  def init(factory) do
    children = [
      {Store, database: factory.database, name: @store_name},
      {ControlServer, store: @store_name, factory: factory, name: @control_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the registered durable-store connection name.
  """
  @spec store_name() :: module()
  def store_name, do: @store_name

  @doc """
  Returns the registered durable-control server name.
  """
  @spec control_name() :: module()
  def control_name, do: @control_name
end
