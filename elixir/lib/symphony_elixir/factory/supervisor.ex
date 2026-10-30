defmodule SymphonyElixir.Factory.Supervisor do
  @moduledoc """
  Supervises the durable factory control plane when enabled by `WORKFLOW.md`.
  """

  use Supervisor

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.{Controller, ControlServer, NativeRuntimeCompatibility, Policy, Store}

  @store_name SymphonyElixir.Factory.Store
  @read_store_name SymphonyElixir.Factory.ReadStore
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
      case NativeRuntimeCompatibility.check_factory(settings.factory) do
        :ok -> :ignore
        {:error, reason} -> {:error, {:invalid_factory_policy, reason}}
      end
    end
  end

  @impl true
  def init(settings) do
    factory = settings.factory

    case validate_startup(factory) do
      :ok ->
        memory_database = factory.database in [:memory, ":memory:"]
        read_store = if memory_database, do: @store_name, else: @read_store_name
        reader_children = if memory_database, do: [], else: [%{id: @read_store_name, start: {Store, :start_read_only, [[database: Path.expand(factory.database), name: @read_store_name]]}}]

        controller_options = [
          settings: settings,
          store: @store_name,
          control_server: @control_name,
          task_supervisor: @task_supervisor_name
        ]

        children =
          [{Store, database: factory.database, name: @store_name}] ++
            reader_children ++
            [
              {ControlServer, store: @store_name, read_store: read_store, factory: factory, name: @control_name},
              Supervisor.child_spec(
                {Task.Supervisor, name: @task_supervisor_name},
                id: @task_supervisor_name
              ),
              {Controller, controller_options}
            ]

        children =
          if factory.task_transport == "desktop_broker" and factory.ticket_supervisor["enabled"] == true do
            children ++ [{SymphonyElixir.Factory.BrokerRuntime, factory: factory, store: @store_name}]
          else
            children
          end

        Supervisor.init(children, strategy: :one_for_one)

      {:error, reason} ->
        exit({:invalid_factory_policy, reason})
    end
  end

  defp validate_startup(factory) do
    with :ok <- NativeRuntimeCompatibility.check_factory(factory),
         :ok <- Policy.validate(factory) do
      policy = Map.get(factory, "ticket_supervisor", Map.get(factory, :ticket_supervisor, %{}))
      enabled = Map.get(policy, "enabled", Map.get(policy, :enabled, false))

      if enabled do
        root = Map.get(policy, "parent_output_root", Map.get(policy, :parent_output_root))
        dated = is_binary(root) and String.contains?(root, "{date}")
        root = if is_binary(root), do: SymphonyElixir.Factory.TicketChat.output_root(root), else: root
        if dated, do: File.mkdir_p!(root)
        AppServer.check_ticket_startup(root)
      else
        :ok
      end
    end
  end

  @doc """
  Returns the registered durable-store connection name.
  """
  @spec store_name() :: module()
  def store_name, do: @store_name

  @doc "Returns the separate read-only connection used for factory status."
  @spec read_store_name() :: module()
  def read_store_name, do: @read_store_name

  @doc """
  Returns the registered durable-control server name.
  """
  @spec control_name() :: module()
  def control_name, do: @control_name

  @doc "Returns the registered factory task-supervisor name."
  @spec task_supervisor_name() :: module()
  def task_supervisor_name, do: @task_supervisor_name
end
