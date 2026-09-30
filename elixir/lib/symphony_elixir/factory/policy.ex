defmodule SymphonyElixir.Factory.Policy do
  @moduledoc """
  Fail-closed startup validation for the complete factory control plane.
  """

  alias SymphonyElixir.Factory.{ModelRouter, Queue}

  @explicit_roles ~w(
    orchestrator orchestrator-intake specification-author specification-critic feature-planner
    change-verifier manual-validator explorer failure-triager
  )

  @doc "Validates every capability needed before an enabled controller starts."
  @spec validate(struct() | map()) :: :ok | {:error, term()}
  def validate(factory) do
    with {:ok, _jql} <- Queue.jql(value(factory, "queue", %{})),
         :ok <- validate_specification_authorization(value(factory, "specification_authorization_mode", "auto_after_critic")),
         :ok <- validate_branch_prefix(value(factory, "branch_prefix", "ai")),
         :ok <- validate_repositories(value(factory, "repositories", %{})),
         :ok <- validate_models(value(factory, "models", %{})),
         :ok <- validate_cleanup(value(factory, "cleanup", %{})),
         :ok <- validate_hibernation(value(factory, "hibernation", %{})) do
      validate_manual_validation(value(factory, "manual_validation", %{}))
    end
  end

  defp validate_specification_authorization(mode) when mode in ["auto_after_critic", "human_confirmation"], do: :ok
  defp validate_specification_authorization(_mode), do: {:error, :invalid_specification_authorization_mode}

  defp validate_branch_prefix(prefix) when is_binary(prefix) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, prefix), do: :ok, else: {:error, :invalid_branch_prefix}
  end

  defp validate_branch_prefix(_prefix), do: {:error, :invalid_branch_prefix}

  defp validate_repositories(repositories) when is_map(repositories) and map_size(repositories) > 0 do
    Enum.reduce_while(repositories, :ok, fn {repo_key, route}, :ok ->
      missing =
        ["path", "base_branch", "gitlab_project", "codex_project_id"]
        |> Enum.reject(&present?(value(route, &1)))

      route_labels = value(route, "route_labels", [])

      cond do
        missing != [] ->
          {:halt, {:error, {:incomplete_repository_route, to_string(repo_key), missing}}}

        not is_list(route_labels) or route_labels == [] or not Enum.all?(route_labels, &present?/1) ->
          {:halt, {:error, {:repository_route_labels_required, to_string(repo_key)}}}

        value(route, "ci_preflight") not in [nil, "draft_mr"] ->
          {:halt, {:error, {:invalid_ci_preflight_route, to_string(repo_key)}}}

        not File.dir?(Path.expand(value(route, "path"))) ->
          {:halt, {:error, {:repository_path_missing, to_string(repo_key), value(route, "path")}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_repositories(_repositories), do: {:error, :repository_routes_required}

  defp validate_models(models) do
    with :ok <- resolve_roles(models, @explicit_roles),
         {:ok, _normal_writer} <- ModelRouter.resolve(models, "feature-writer", risk: "low"),
         {:ok, _high_risk_writer} <- ModelRouter.resolve(models, "feature-writer", risk: "high") do
      :ok
    end
  end

  defp resolve_roles(models, roles) do
    Enum.reduce_while(roles, :ok, fn role, :ok ->
      case ModelRouter.resolve(models, role) do
        {:ok, _route} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:model_route_unavailable, role, reason}}}
      end
    end)
  end

  defp validate_cleanup(cleanup) do
    if value(cleanup, "enabled", false) do
      roots = value(cleanup, "allowed_worktree_roots", [])

      cond do
        not is_list(roots) or roots == [] -> {:error, :cleanup_roots_required}
        not Enum.all?(roots, &present?/1) -> {:error, :invalid_cleanup_root}
        not present?(value(cleanup, "reclaim_script")) -> {:error, :cleanup_reclaim_script_required}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp validate_hibernation(policy) do
    if value(policy, "enabled", false) do
      states = value(policy, "allowed_run_states", [])

      cond do
        states == [] or not valid_string_list?(states) -> {:error, :hibernation_states_required}
        not present?(value(policy, "reclaim_script")) -> {:error, :hibernation_reclaim_script_required}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp validate_manual_validation(policy) do
    if value(policy, "enabled", false) do
      environments = value(policy, "allowed_environments", []) |> Enum.map(&normalize/1)

      with :ok <- validate_manual_environments(environments),
           :ok <- validate_manual_safety(policy),
           :ok <- validate_manual_capabilities(policy) do
        validate_manual_startup_timeout(value(policy, "startup_timeout_ms", 60_000))
      end
    else
      :ok
    end
  end

  defp validate_manual_environments([]), do: {:error, :manual_validation_environments_required}

  defp validate_manual_environments(environments) do
    if Enum.any?(environments, &(&1 in ["staging", "production", "prod"])) do
      {:error, :production_validation_forbidden}
    else
      :ok
    end
  end

  defp validate_manual_safety(policy) do
    cond do
      value(policy, "allow_production", false) -> {:error, :production_validation_forbidden}
      value(policy, "allow_database_ddl", false) -> {:error, :database_ddl_validation_forbidden}
      not value(policy, "require_slack_coordination", true) -> {:error, :slack_coordination_required}
      true -> :ok
    end
  end

  defp validate_manual_capabilities(policy) do
    required_apps = value(policy, "required_apps", [])
    required_mcp_servers = value(policy, "required_mcp_servers", [])

    cond do
      not valid_string_list?(required_apps) or not valid_string_list?(required_mcp_servers) ->
        {:error, :invalid_manual_validation_capability_requirements}

      required_apps == [] and required_mcp_servers == [] ->
        {:error, :manual_validation_slack_provider_required}

      true ->
        :ok
    end
  end

  defp validate_manual_startup_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_manual_startup_timeout(_timeout), do: {:error, :invalid_manual_validation_startup_timeout}

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp valid_string_list?(values) when is_list(values), do: Enum.all?(values, &present?/1)
  defp valid_string_list?(_values), do: false

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, maybe_existing_atom(key), default))
  end

  defp value(_map, _key, default), do: default

  defp maybe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing_factory_key__
  end
end
