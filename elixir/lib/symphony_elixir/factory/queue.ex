defmodule SymphonyElixir.Factory.Queue do
  @moduledoc """
  Assignee-scoped Jira intake, factory label classification, and repository routing.
  """

  @spec jql(map()) :: {:ok, String.t()} | {:error, term()}
  def jql(queue) when is_map(queue) do
    with {:ok, assignee} <- required_string(queue, "assignee"),
         {:ok, statuses} <- required_strings(queue, "statuses"),
         {:ok, labels} <- required_strings(queue, "factory_labels") do
      clauses = [
        "assignee = #{assignee}",
        "status IN (#{quoted_list(statuses)})",
        "labels IN (#{quoted_list(labels)})"
      ]

      clauses = optional_in_clause(clauses, "project", value(queue, "projects", []))
      clauses = optional_in_clause(clauses, "parent", value(queue, "epics", []))
      {:ok, Enum.join(clauses, " AND ") <> " ORDER BY priority DESC, created ASC"}
    end
  end

  @doc "Classifies a factory-labelled Jira snapshot for the next run kind."
  @spec classify(map()) :: :specification | :delivery | :reconcile | :ignore | {:error, term()}
  def classify(snapshot) do
    labels = normalized_values(value(snapshot, "labels", []))
    classify_labels(label_flags(labels))
  end

  @spec label_flags([String.t()]) :: map()
  defp label_flags(labels) do
    %{
      terminal: member_any?(labels, ["ai-blocked", "ai-review"]),
      active: member_any?(labels, ["ai-running", "ai-verifying", "ai-testing"]),
      ready: "ai-ready" in labels,
      specification: member_any?(labels, ["spec-needed", "needs-decision"])
    }
  end

  defp classify_labels(%{terminal: true}), do: :ignore
  defp classify_labels(%{active: true}), do: :reconcile
  defp classify_labels(%{ready: true, specification: true}), do: {:error, :ambiguous_factory_labels}
  defp classify_labels(%{ready: true}), do: :delivery
  defp classify_labels(%{specification: true}), do: :specification
  defp classify_labels(_flags), do: :ignore

  @spec member_any?([String.t()], [String.t()]) :: boolean()
  defp member_any?(labels, names), do: Enum.any?(names, &(&1 in labels))

  @doc "Returns the single configured repository route proven by Jira metadata."
  @spec route(map(), map()) :: {:ok, map()} | {:error, term()}
  def route(snapshot, repositories) when is_map(repositories) do
    matches =
      repositories
      |> Enum.flat_map(fn {repo_key, repository} ->
        if route_matches?(snapshot, repository) do
          [Map.put(repository, "repo_key", to_string(repo_key))]
        else
          []
        end
      end)

    case matches do
      [route] -> validate_route(route)
      [] -> {:error, :routing_required}
      _many -> {:error, :ambiguous_repository_route}
    end
  end

  @spec route_matches?(map(), map()) :: boolean()
  defp route_matches?(snapshot, repository) do
    labels = normalized_values(value(snapshot, "labels", []))
    components = normalized_values(value(snapshot, "components", []))
    project = value(snapshot, "project_key") |> normalize()

    required_labels = repository |> value("route_labels", []) |> normalized_values()
    route_components = repository |> value("jira_components", []) |> normalized_values()
    route_projects = repository |> value("jira_projects", []) |> normalized_values()

    required_labels != [] and Enum.all?(required_labels, &(&1 in labels)) and
      optional_match?(route_components, components) and
      optional_scalar_match?(route_projects, project)
  end

  defp validate_route(route) do
    missing =
      ["repo_key", "path", "base_branch", "gitlab_project"]
      |> Enum.reject(&present?(value(route, &1)))

    if missing == [], do: {:ok, route}, else: {:error, {:incomplete_repository_route, missing}}
  end

  @spec optional_match?([String.t()], [String.t()]) :: boolean()
  defp optional_match?(configured, actual) do
    configured == [] or Enum.any?(configured, &(&1 in actual))
  end

  @spec optional_scalar_match?([String.t()], String.t()) :: boolean()
  defp optional_scalar_match?(configured, actual) do
    configured == [] or actual in configured
  end

  defp optional_in_clause(clauses, _field, []), do: clauses

  defp optional_in_clause(clauses, field, values) when is_list(values) do
    clauses ++ ["#{field} IN (#{quoted_list(values)})"]
  end

  defp required_string(map, key) do
    case value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_queue_setting, key}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, {:missing_queue_setting, key}}
    end
  end

  defp required_strings(map, key) do
    values = value(map, key, [])

    if is_list(values) and values != [] and Enum.all?(values, &present?/1) do
      {:ok, Enum.map(values, &String.trim/1)}
    else
      {:error, {:missing_queue_setting, key}}
    end
  end

  defp quoted_list(values), do: Enum.map_join(values, ", ", &quote_value/1)

  defp quote_value(value) do
    escaped = value |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  @spec normalized_values(term()) :: [String.t()]
  defp normalized_values(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"name" => name} -> normalize(name)
      %{name: name} -> normalize(name)
      value -> normalize(value)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_values(_values), do: []

  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

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
