defmodule SymphonyElixir.Factory.CiCollection do
  @moduledoc "Bounded read-only CI collection on an existing controller MCP session."
  alias SymphonyElixir.Factory.GitLabMcpConnector

  @mr_fields ~w(iid project_id web_url sha diff_refs source_branch target_branch draft reviewers assignees state head_pipeline)
  @mr_delivery_fields @mr_fields -- ["head_pipeline"]
  @calls [
    {"get_merge_request", %{"project_id" => "string", "merge_request_iid" => "string", "include_summaries" => "boolean"}},
    {"get_pipeline", %{"project_id" => "string", "pipeline_id" => "string"}},
    {"list_pipeline_jobs", %{"project_id" => "string", "pipeline_id" => "string", "page" => "number", "per_page" => "number", "include_retried" => "boolean"}},
    {"get_commit", %{"project_id" => "string", "sha" => "string", "stats" => "boolean"}}
  ]

  @doc "Reads only MR identity and human state, without collecting CI or opening a session."
  @spec collect_mr(map(), pos_integer() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def collect_mr(_run, pin, _opts) when not is_integer(pin) or pin <= 0, do: {:error, :mr_project_pin_required}

  def collect_mr(run, pin, opts) do
    connector = Keyword.get(opts, :connector, GitLabMcpConnector)

    with %{} <- Keyword.get(opts, :mcp_session) || {:error, :gitlab_catalog_session_required},
         true <- (is_integer(run["mr_iid"]) and run["mr_iid"] > 0) or {:error, :mr_iid_required},
         {:ok, catalog} <- connector.catalog(opts),
         :ok <- schemas(catalog, Enum.take(@calls, 1)),
         args = %{"project_id" => Integer.to_string(pin), "merge_request_iid" => Integer.to_string(run["mr_iid"]), "include_summaries" => false},
         {:ok, first} <- read(connector, "get_merge_request", args, opts),
         first = Map.take(normalize_mr(first), @mr_delivery_fields),
         true <- (first["project_id"] == pin and first["iid"] == run["mr_iid"]) or {:error, :mr_project_binding_mismatch},
         {:ok, last} <- read(connector, "get_merge_request", args, opts),
         true <- first == Map.take(normalize_mr(last), @mr_delivery_fields) or {:error, :mr_changed_during_collection} do
      {:ok, first}
    end
  end

  @spec collect(map(), pos_integer() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def collect(_run, pin, _opts) when not is_integer(pin) or pin <= 0, do: {:error, :ci_project_pin_required}

  def collect(run, pin, opts) do
    connector = Keyword.get(opts, :connector, GitLabMcpConnector)

    with %{} <- Keyword.get(opts, :mcp_session) || {:error, :gitlab_catalog_session_required},
         {:ok, catalog} <- connector.catalog(opts),
         :ok <- schemas(catalog),
         args = %{"project_id" => Integer.to_string(pin), "merge_request_iid" => to_string(run["mr_iid"]), "include_summaries" => false},
         {:ok, first} <- read(connector, "get_merge_request", args, opts),
         true <- Map.has_key?(first, "head_pipeline") or {:error, :ci_head_pipeline_not_observable},
         first = normalize_mr(first),
         true <- (first["project_id"] == pin and first["iid"] == run["mr_iid"]) or {:error, :ci_mr_binding_mismatch},
         {:ok, pipeline, jobs, commit} <- pipeline(first["head_pipeline"], run, pin, connector, opts),
         {:ok, last} <- read(connector, "get_merge_request", args, opts),
         true <- Map.has_key?(last, "head_pipeline") or {:error, :ci_head_pipeline_not_observable},
         true <- Map.take(first, @mr_fields) == Map.take(normalize_mr(last), @mr_fields) or {:error, :ci_mr_changed_during_collection} do
      {:ok, %{"mr" => first, "pipeline" => pipeline, "jobs" => jobs, "merge_commit" => commit}}
    end
  end

  defp read(connector, tool, args, opts) do
    case connector.call(tool, args, opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, _} = error -> error
      _ -> {:error, :gitlab_tool_result_invalid}
    end
  end

  defp schemas(catalog, calls \\ @calls)

  defp schemas(catalog, calls) when is_map(catalog) do
    Enum.reduce_while(calls, :ok, fn {name, fields}, :ok ->
      if schema?(catalog[name], name, fields),
        do: {:cont, :ok},
        else: {:halt, {:error, {:ci_tool_schema_unavailable, name}}}
    end)
  end

  defp schemas(_catalog, _calls), do: {:error, :ci_catalog_invalid}

  defp schema?(%{"name" => name, "annotations" => %{"readOnlyHint" => true}, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required}}, name, fields)
       when is_map(properties) and is_list(required) do
    Enum.all?(fields, fn {key, type} -> match?(%{"type" => ^type}, properties[key]) end) and
      Enum.all?(required, &Map.has_key?(fields, &1))
  end

  defp schema?(_schema, _name, _fields), do: false

  defp pipeline(nil, _run, _pin, _connector, _opts), do: {:ok, nil, [], nil}

  defp pipeline(%{"id" => id}, run, pin, connector, opts) when is_integer(id) and id > 0 do
    args = %{"project_id" => Integer.to_string(pin), "pipeline_id" => Integer.to_string(id)}

    with {:ok, pipeline} <- read(connector, "get_pipeline", args, opts),
         {:ok, jobs} <- jobs(connector, args, opts),
         {:ok, commit} <- merge_commit(pipeline, run, pin, connector, opts) do
      {:ok, normalize_ids(pipeline, ~w(id project_id)), Enum.map(jobs, &normalize_job/1), commit}
    end
  end

  defp pipeline(_selector, _run, _pin, _connector, _opts), do: {:error, :ci_pipeline_id_invalid}

  defp jobs(connector, args, opts) do
    args = Map.merge(args, %{"page" => 1, "per_page" => 100, "include_retried" => false})

    with {:ok, jobs} <- connector.call_list("list_pipeline_jobs", args, opts),
         true <- (is_list(jobs) and length(jobs) <= 100 and Enum.all?(jobs, &is_map/1)) or {:error, :ci_jobs_limit_or_shape},
         :ok <- final_page(jobs, connector, args, opts) do
      {:ok, jobs}
    end
  end

  defp final_page(_jobs, connector, args, opts) do
    case connector.call_list("list_pipeline_jobs", Map.put(args, "page", 2), opts) do
      {:ok, []} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :ci_jobs_limit_or_shape}
    end
  end

  defp merge_commit(pipeline, run, pin, connector, opts) do
    if pipeline["ref"] == "refs/merge-requests/#{run["mr_iid"]}/merge" do
      read(connector, "get_commit", %{"project_id" => Integer.to_string(pin), "sha" => pipeline["sha"], "stats" => false}, opts)
    else
      {:ok, nil}
    end
  end

  defp normalize_mr(mr) do
    mr
    |> normalize_ids(~w(iid project_id))
    |> Map.update("assignees", nil, &people/1)
    |> Map.update("reviewers", nil, &people/1)
    |> Map.update("head_pipeline", nil, &normalize_ids(&1, ~w(id project_id)))
  end

  defp people(list) when is_list(list), do: Enum.map(list, &normalize_ids(&1, ~w(id)))
  defp people(other), do: other

  defp normalize_job(job), do: job |> normalize_ids(~w(id)) |> Map.update("pipeline", nil, &normalize_ids(&1, ~w(id project_id)))

  defp normalize_ids(map, fields) when is_map(map) do
    Enum.reduce(fields, map, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &numeric_id/1), else: acc
    end)
  end

  defp normalize_ids(other, _fields), do: other

  defp numeric_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> if Integer.to_string(id) == value, do: id, else: value
      _ -> value
    end
  end

  defp numeric_id(value), do: value
end
