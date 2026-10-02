defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false
  @linear_endpoint "https://api.linear.app/graphql"
  @linear_active_states ["Todo", "In Progress"]
  @linear_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string)
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:provider, :map, default: %{})
      field(:secret_environment_names, {:array, :string}, default: [])
      field(:required_labels, {:array, :string}, default: [])
      field(:required_any_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string})
      field(:terminal_states, {:array, :string})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :provider,
          :required_labels,
          :required_any_labels,
          :active_states,
          :terminal_states
        ],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
      |> update_change(:required_any_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_change(:command, fn :command, command ->
        if command != "" and String.trim(command) == "" do
          [command: "can't be blank"]
        else
          []
        end
      end)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Factory do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:database, :string)
      field(:scope, :string, default: "assigned-jira-work")
      field(:dispatcher_id, :string)
      field(:controller_codex_project_id, :string)
      field(:task_transport, :string, default: "app_server")
      field(:native_session_discovery_enabled, :boolean, default: false)
      field(:native_source_attachment_enabled, :boolean, default: false)
      field(:branch_prefix, :string, default: "ai")
      field(:lease_seconds, :integer, default: 240)
      field(:controller_required_mcp_servers, {:array, :string}, default: [])
      field(:controller_mcp_startup_timeout_ms, :integer, default: 60_000)
      field(:maximum_specifiers, :integer, default: 2)
      field(:specification_authorization_mode, :string, default: "auto_after_critic")
      field(:maximum_writers, :integer, default: 2)
      field(:maximum_validators, :integer, default: 2)
      field(:writer_disk_gb, :integer, default: 20)
      field(:maximum_implementation_iterations, :integer, default: 8)
      field(:maximum_code_repair_rounds, :integer, default: 2)
      field(:maximum_validation_repair_rounds, :integer, default: 2)
      field(:controller_writer_stale_minutes, :integer, default: 15)
      field(:stale_task_minutes, :integer, default: 90)
      field(:queue, :map, default: %{})
      field(:cleanup, :map, default: %{})
      field(:hibernation, :map, default: %{})
      field(:review_feedback, :map, default: %{})
      field(:manual_validation, :map, default: %{})
      field(:ticket_supervisor, :map, default: %{"enabled" => false, "pilot_issue_keys" => []})
      field(:models, :map, default: %{})
      field(:repositories, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :database,
          :scope,
          :dispatcher_id,
          :controller_codex_project_id,
          :task_transport,
          :native_session_discovery_enabled,
          :native_source_attachment_enabled,
          :branch_prefix,
          :lease_seconds,
          :controller_required_mcp_servers,
          :controller_mcp_startup_timeout_ms,
          :maximum_specifiers,
          :specification_authorization_mode,
          :maximum_writers,
          :maximum_validators,
          :writer_disk_gb,
          :maximum_implementation_iterations,
          :maximum_code_repair_rounds,
          :maximum_validation_repair_rounds,
          :controller_writer_stale_minutes,
          :stale_task_minutes,
          :queue,
          :cleanup,
          :hibernation,
          :review_feedback,
          :manual_validation,
          :ticket_supervisor,
          :models,
          :repositories
        ],
        empty_values: []
      )
      |> update_change(:controller_required_mcp_servers, fn servers ->
        servers
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end)
      |> validate_number(:lease_seconds, greater_than: 0)
      |> validate_number(:controller_mcp_startup_timeout_ms, greater_than: 0)
      |> validate_number(:maximum_specifiers, greater_than: 0)
      |> validate_inclusion(:specification_authorization_mode, ["auto_after_critic", "human_confirmation"])
      |> validate_number(:maximum_writers, greater_than: 0)
      |> validate_number(:maximum_validators, greater_than: 0)
      |> validate_number(:writer_disk_gb, greater_than: 0)
      |> validate_number(:maximum_implementation_iterations, greater_than: 0)
      |> validate_number(:maximum_code_repair_rounds, greater_than_or_equal_to: 0)
      |> validate_number(:maximum_validation_repair_rounds, greater_than_or_equal_to: 0)
      |> validate_number(:controller_writer_stale_minutes, greater_than: 0)
      |> validate_number(:stale_task_minutes, greater_than: 0)
      |> validate_inclusion(:task_transport, ["app_server", "desktop_broker"])
      |> validate_factory_required_fields()
    end

    defp validate_factory_required_fields(changeset) do
      if get_field(changeset, :enabled) do
        validate_required(changeset, [
          :database,
          :scope,
          :dispatcher_id,
          :controller_codex_project_id
        ])
      else
        changeset
      end
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:factory, Factory, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          state_name |> to_string() |> String.trim() == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:factory, with: &Factory.changeset/2)
  end

  defp finalize_settings(settings) do
    provider = normalize_optional_map(settings.tracker.provider) || %{}

    {api_key, assignee, provider, secret_environment_names} =
      case settings.tracker.kind do
        "linear" ->
          linear_provider =
            provider
            |> Map.put_new("endpoint", settings.tracker.endpoint || @linear_endpoint)
            |> Map.put_new("api_key", settings.tracker.api_key)
            |> Map.put_new("project_slug", settings.tracker.project_slug)
            |> Map.put_new("assignee", settings.tracker.assignee)

          resolved_api_key =
            resolve_secret_setting(linear_provider["api_key"], System.get_env("LINEAR_API_KEY"))

          resolved_assignee =
            resolve_secret_setting(linear_provider["assignee"], System.get_env("LINEAR_ASSIGNEE"))

          {
            resolved_api_key,
            resolved_assignee,
            linear_provider,
            ["LINEAR_API_KEY" | env_reference_names([linear_provider["api_key"]])]
          }

        _ ->
          {settings.tracker.api_key, settings.tracker.assignee, provider, []}
      end

    {active_states, terminal_states} =
      case settings.tracker.kind do
        kind when kind in ["linear", "memory"] ->
          {
            settings.tracker.active_states || @linear_active_states,
            settings.tracker.terminal_states || @linear_terminal_states
          }

        _ ->
          {settings.tracker.active_states, settings.tracker.terminal_states}
      end

    tracker = %{
      settings.tracker
      | endpoint: Map.get(provider, "endpoint", settings.tracker.endpoint),
        api_key: api_key,
        project_slug: Map.get(provider, "project_slug", settings.tracker.project_slug),
        assignee: assignee,
        provider: provider,
        secret_environment_names: Enum.uniq(secret_environment_names),
        active_states: active_states,
        terminal_states: terminal_states
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    factory = %{
      settings.factory
      | database: resolve_optional_path_value(settings.factory.database),
        models: normalize_keys(settings.factory.models),
        repositories: normalize_keys(settings.factory.repositories),
        queue: normalize_keys(settings.factory.queue),
        cleanup: normalize_keys(settings.factory.cleanup),
        hibernation: normalize_keys(settings.factory.hibernation),
        manual_validation: normalize_keys(settings.factory.manual_validation),
        ticket_supervisor: normalize_keys(settings.factory.ticket_supervisor)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex, factory: factory}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value), do: drop_nil_values(value, false)

  defp drop_nil_values(value, preserve_nulls) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      preserve_nested_nulls = preserve_nulls or key == "ticket_supervisor"

      case drop_nil_values(nested, preserve_nested_nulls) do
        nil when preserve_nested_nulls -> Map.put(acc, key, nil)
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value, preserve_nulls) when is_list(value), do: Enum.map(value, &drop_nil_values(&1, preserve_nulls))
  defp drop_nil_values(value, _preserve_nulls), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_secret_setting(value, _fallback), do: value

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_optional_path_value(nil), do: nil

  defp resolve_optional_path_value(value) do
    case resolve_path_value(value, nil) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp env_reference_names(values) when is_list(values) do
    Enum.flat_map(values, fn value ->
      case env_reference_name(value) do
        {:ok, env_name} -> [env_name]
        :error -> []
      end
    end)
  end

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
