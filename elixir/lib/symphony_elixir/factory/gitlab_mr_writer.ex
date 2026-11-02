defmodule SymphonyElixir.Factory.GitLabMrWriter do
  @moduledoc "Fixed merge-request operations on a caller-owned GitLab connector session."
  alias SymphonyElixir.Codex.AppServer

  @max_bytes 1_048_576

  @spec with_session(Path.t(), keyword(), (keyword() -> term())) :: term()
  def with_session(workspace, opts, operation) do
    if is_map(opts[:mcp_session]) do
      operation.(opts)
    else
      app_server = Keyword.get(opts, :app_server, AppServer)
      app_server.with_gitlab_read_session(workspace, fn session -> operation.(Keyword.put(opts, :mcp_session, session)) end)
    end
  end

  @spec fetch(map(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(scope, iid, opts) do
    with :ok <- scope_valid(scope, opts),
         true <- (is_integer(iid) and iid > 0) or {:error, :gitlab_mr_scope_required},
         {:ok, result} when is_map(result) <- call("get_merge_request", %{"project_id" => Integer.to_string(scope["project_id"]), "merge_request_iid" => Integer.to_string(iid)}, opts),
         true <-
           (result["iid"] == iid and Map.take(result, ~w(project_id source_branch target_branch)) == Map.take(scope, ~w(project_id source_branch target_branch))) or
             {:error, :gitlab_mr_remote_identity_mismatch} do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :gitlab_mr_result_invalid}
    end
  end

  @spec creation_capability(map(), keyword()) :: :ok | {:error, term()}
  def creation_capability(intent, opts) do
    with {:ok, args} <- create_arguments(intent, opts),
         {:ok, catalog} <- Keyword.get(opts, :app_server, AppServer).mcp_tool_catalog_in_session(opts[:mcp_session], "GitLab") do
      compatible(catalog["create_merge_request"], "create_merge_request", args)
    end
  end

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(intent, opts) do
    admission =
      with {:ok, args} <- create_arguments(intent, opts),
           {:ok, catalog} <- Keyword.get(opts, :app_server, AppServer).mcp_tool_catalog_in_session(opts[:mcp_session], "GitLab"),
           :ok <- compatible(catalog["create_merge_request"], "create_merge_request", args),
           do: {:ok, args}

    case admission do
      {:ok, args} ->
        case invoke("create_merge_request", args, opts) do
          {:error, :mcp_tool_approval_required} -> {:error, {:gitlab_mr_not_issued, :mcp_tool_approval_required}}
          result -> result
        end

      {:error, reason} ->
        {:error, {:gitlab_mr_not_issued, reason}}
    end
  end

  defp create_arguments(intent, opts) do
    with :ok <- scope_valid(intent, opts),
         title when is_binary(title) <- intent["title"],
         true <- String.starts_with?(title, "Draft: ") and byte_size(title) in 8..256 and not Regex.match?(~r/[\x00-\x1f\x7f]/, title),
         description when is_binary(description) and byte_size(description) <= 262_144 <- intent["description"] do
      {:ok,
       Map.take(intent, ~w(title description source_branch target_branch))
       |> Map.merge(%{"project_id" => Integer.to_string(intent["project_id"]), "draft" => true, "assignee_ids" => [11_599_766], "reviewer_ids" => [], "remove_source_branch" => false})}
    else
      _ -> {:error, :gitlab_mr_scope_required}
    end
  end

  @spec discover(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def discover(scope, opts) do
    size = Keyword.get(opts, :per_page, 100)
    pages = Keyword.get(opts, :max_pages, 10)

    with :ok <- scope_valid(scope, opts),
         true <- (is_integer(size) and size in 1..100 and is_integer(pages) and pages in 1..100) or {:error, :gitlab_mr_pagination_invalid} do
      discover_page(scope, opts, 1, size, pages, [])
    end
  end

  defp discover_page(scope, opts, page, size, remaining, accumulated) do
    args =
      Map.take(scope, ~w(source_branch target_branch)) |> Map.merge(%{"project_id" => Integer.to_string(scope["project_id"]), "state" => "all", "scope" => "all", "page" => page, "per_page" => size})

    with {:ok, items} when is_list(items) <- call("list_merge_requests", args, opts),
         true <- (length(items) <= size and Enum.all?(items, &is_map/1)) or {:error, :gitlab_mr_result_invalid},
         true <-
           Enum.all?(items, &(Map.take(&1, ~w(project_id source_branch target_branch)) == Map.take(scope, ~w(project_id source_branch target_branch)))) or {:error, :gitlab_mr_remote_identity_mismatch} do
      cond do
        length(items) < size -> {:ok, accumulated ++ items}
        remaining > 1 -> discover_page(scope, opts, page + 1, size, remaining - 1, accumulated ++ items)
        true -> {:error, :gitlab_mr_discovery_incomplete}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :gitlab_mr_result_invalid}
    end
  end

  defp scope_valid(scope, opts) do
    if is_map(scope) and is_integer(scope["project_id"]) and scope["project_id"] > 0 and
         is_binary(scope["project"]) and Regex.match?(~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/, scope["project"]) and
         Enum.all?(~w(source_branch target_branch), &(is_binary(scope[&1]) and byte_size(scope[&1]) in 1..1024 and not Regex.match?(~r/[\x00-\x20\x7f\\]/u, scope[&1]))) and
         scope["source_branch"] != scope["target_branch"] and scope["source_branch"] not in ~w(main master) and is_map(opts[:mcp_session]),
       do: :ok,
       else: {:error, :gitlab_mr_scope_required}
  end

  defp call(name, args, opts) do
    app_server = Keyword.get(opts, :app_server, AppServer)

    with {:ok, catalog} <- app_server.mcp_tool_catalog_in_session(opts[:mcp_session], "GitLab"), :ok <- compatible(catalog[name], name, args), do: invoke(name, args, opts)
  end

  defp invoke(name, args, opts) do
    with {:ok, response} <- Keyword.get(opts, :app_server, AppServer).call_mcp_tool_in_session(opts[:mcp_session], "GitLab", name, args),
         false <- response["isError"] == true,
         {:ok, result} <- decode(response) do
      normalize_result(result)
    else
      {:error, _} = error -> error
      _ -> {:error, :gitlab_mr_tool_error}
    end
  end

  defp normalize_result(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_result(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp normalize_result(item) when is_map(item) do
    with {:ok, normalized} <-
           Enum.reduce_while(~w(id iid project_id), {:ok, item}, fn key, {:ok, acc} ->
             case Map.fetch(acc, key) do
               :error ->
                 {:cont, {:ok, acc}}

               {:ok, value} ->
                 case positive_id(value) do
                   {:ok, id} -> {:cont, {:ok, Map.put(acc, key, id)}}
                   error -> {:halt, error}
                 end
             end
           end),
         true <- Enum.all?(~w(should_remove_source_branch force_remove_source_branch remove_source_branch), &(is_nil(item[&1]) or is_boolean(item[&1]))) do
      removal = if Map.has_key?(item, "should_remove_source_branch") or Map.has_key?(item, "force_remove_source_branch"), do: removal_setting(item), else: item["remove_source_branch"]
      {:ok, if(is_nil(removal), do: Map.delete(normalized, "remove_source_branch"), else: Map.put(normalized, "remove_source_branch", removal))}
    else
      _ -> {:error, :gitlab_mr_result_invalid}
    end
  end

  defp normalize_result(_), do: {:error, :gitlab_mr_result_invalid}
  defp positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> if(Integer.to_string(id) == value, do: {:ok, id}, else: {:error, :gitlab_mr_result_invalid})
      _ -> {:error, :gitlab_mr_result_invalid}
    end
  end

  defp positive_id(_), do: {:error, :gitlab_mr_result_invalid}

  defp removal_setting(item) do
    cond do
      item["should_remove_source_branch"] == true or item["force_remove_source_branch"] == true -> true
      item["should_remove_source_branch"] == false and item["force_remove_source_branch"] == false -> false
      true -> nil
    end
  end

  defp compatible(%{"name" => name, "inputSchema" => %{"type" => "object", "properties" => properties} = schema}, name, args) when is_map(properties) do
    required = Map.get(schema, "required", [])

    if is_list(required) and Enum.all?(required, &Map.has_key?(args, &1)) and Enum.all?(args, fn {key, value} -> accepts?(properties[key], value) end),
      do: :ok,
      else: {:error, :gitlab_mr_capability_incompatible}
  end

  defp compatible(nil, _name, _args), do: {:error, :gitlab_mr_capability_unavailable}
  defp compatible(_schema, _name, _args), do: {:error, :gitlab_mr_capability_incompatible}

  defp accepts?(%{"type" => types} = schema, value) do
    Enum.any?(List.wrap(types), &type?(&1, value)) and (not Map.has_key?(schema, "enum") or value in schema["enum"]) and
      (not is_list(value) or Enum.all?(value, &accepts?(schema["items"], &1)))
  end

  defp accepts?(_, _), do: false
  defp type?("string", value), do: is_binary(value)
  defp type?("number", value), do: is_number(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("array", value), do: is_list(value)
  defp type?(_, _), do: false

  defp decode(%{"structuredContent" => %{"result" => raw}}) when is_binary(raw), do: decode_json(raw)
  defp decode(%{"structuredContent" => value}) when is_map(value) or is_list(value), do: bounded(value)
  defp decode(%{"content" => [%{"type" => "text", "text" => raw}]}) when is_binary(raw), do: decode_json(raw)
  defp decode(_), do: {:error, :gitlab_mr_result_invalid}
  defp decode_json(raw) when byte_size(raw) <= @max_bytes, do: Jason.decode(raw)
  defp decode_json(_), do: {:error, :gitlab_mr_result_too_large}
  defp bounded(value), do: if(byte_size(Jason.encode!(value)) <= @max_bytes, do: {:ok, value}, else: {:error, :gitlab_mr_result_too_large})
end
