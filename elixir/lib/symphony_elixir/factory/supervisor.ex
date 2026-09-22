defmodule SymphonyElixir.Factory.Supervisor do
  @moduledoc """
  Supervises the durable factory control plane when enabled by `WORKFLOW.md`.
  """

  use Supervisor

  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.{Controller, ControlServer, Policy, Store}

  @store_name SymphonyElixir.Factory.Store
  @control_name SymphonyElixir.Factory.ControlServer
  @task_supervisor_name SymphonyElixir.Factory.TaskSupervisor

  @doc """
  Starts the optional factory supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    if settings.factory.enabled do
      name = Keyword.get(opts, :name, __MODULE__)
      Supervisor.start_link(__MODULE__, settings, name: name)
    else
      :ignore
    end
  end

  @impl true
  def init(settings) do
    factory = settings.factory

    case Policy.validate(factory) do
      :ok ->
        controller_options = [
          settings: settings,
          store: @store_name,
          control_server: @control_name,
          task_supervisor: @task_supervisor_name
        ]

        children = [
          {Store, database: factory.database, name: @store_name},
          {ControlServer, store: @store_name, factory: factory, name: @control_name},
          Supervisor.child_spec(
            {Task.Supervisor, name: @task_supervisor_name},
            id: @task_supervisor_name
          ),
          {Controller, controller_options}
        ]

        Supervisor.init(children, strategy: :one_for_one)

      {:error, reason} ->
        {:stop, {:invalid_factory_policy, reason}}
    end
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

  @doc "Returns the registered factory task-supervisor name."
  @spec task_supervisor_name() :: module()
  def task_supervisor_name, do: @task_supervisor_name
end
