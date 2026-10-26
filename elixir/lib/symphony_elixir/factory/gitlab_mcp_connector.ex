defmodule SymphonyElixir.Factory.GitLabMcpConnector do
  @moduledoc """
  Calls the existing authenticated GitLab MCP tools without a model turn.
  """

  alias SymphonyElixir.Codex.AppServer

  @allowed_tools ~w(get_merge_request get_merge_request_discussion mr_discussions whoami get_pipeline get_commit)
  @max_bytes 1_048_576

  @doc "Reads schemas from an existing controller session without opening a thread or granting tool access."
  @spec catalog(keyword()) :: {:ok, map()} | {:error, term()}
  def catalog(opts) do
    case Keyword.get(opts, :mcp_session) do
      %{} = session ->
        app_server = Keyword.get(opts, :app_server, AppServer)
        app_server.mcp_tool_catalog_in_session(session, "GitLab")

      _ ->
        {:error, :gitlab_catalog_session_required}
    end
  end

  @doc "Reads one exact configured branch head on an existing readonly connector session."
  @spec branch_head(pos_integer(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def branch_head(project_id, project, branch, opts) do
    types = %{"project_id" => "string", "branch_name" => "string"}

    with true <- branch_scope?(project_id, project, branch, opts) or {:error, :gitlab_branch_scope_required},
         {:ok, tools} when is_map(tools) <- catalog(opts),
         schema = tools["get_branch"],
         true <- branch_schema?(schema, types) or {:error, :gitlab_branch_schema_unavailable},
         arguments = %{"project_id" => Integer.to_string(project_id), "branch_name" => branch},
         {:ok, response} when is_map(response) <- call_tool(Keyword.get(opts, :app_server, AppServer), opts[:mcp_session], opts[:workspace], "get_branch", arguments),
         false <- response["isError"] == true,
         {:ok, result} when is_map(result) <- decode_result(response),
         commit when is_map(commit) <- result["commit"],
         sha when is_binary(sha) <- commit["id"],
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
         true <- result["name"] == branch and result["project_id"] in [nil, project_id, Integer.to_string(project_id)],
         true <- result["web_url"] == "https://gitlab.com/#{project}/-/tree/#{branch}",
         true <- commit["web_url"] == "https://gitlab.com/#{project}/-/commit/#{sha}" do
      {:ok, sha}
    else
      {:error, _} = error -> error
      _ -> {:error, :gitlab_branch_result_invalid}
    end
  end

  defp branch_schema?(%{"name" => "get_branch", "annotations" => %{"readOnlyHint" => true}, "inputSchema" => %{"type" => "object", "required" => required, "properties" => properties}}, types)
       when is_list(required) and is_map(properties) do
    Enum.sort(required) == Enum.sort(Map.keys(types)) and
      Enum.all?(types, fn {key, type} -> properties[key] == %{"type" => type} or (is_map(properties[key]) and properties[key]["type"] == type) end)
  end

  defp branch_schema?(_, _), do: false

  defp branch_scope?(project_id, project, branch, opts) do
    is_integer(project_id) and project_id > 0 and is_map(opts[:mcp_session]) and
      branch_project?(project) and branch_name?(branch)
  end

  defp branch_project?(project) do
    is_binary(project) and byte_size(project) <= 512 and Regex.match?(~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/, project)
  end

  defp branch_name?(branch) do
    is_binary(branch) and byte_size(branch) in 1..1024 and String.valid?(branch) and
      branch not in ~w(main master) and not Regex.match?(~r/[\x00-\x20\x7f\\]/u, branch)
  end

  @doc "Reads only a bounded job trace page; provider framing remains data for the complete-trace collector to validate."
  @spec job_output(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def job_output(arguments, opts) when is_map(arguments) do
    with :ok <- trace_scope(arguments, opts),
         {:ok, tools} <- catalog(opts),
         :ok <- trace_schema(tools),
         {:ok, response} <- call_tool(Keyword.get(opts, :app_server, AppServer), opts[:mcp_session], opts[:workspace], "get_pipeline_job_output", arguments),
         false <- response["isError"] == true,
         %{"content" => [%{"type" => "text", "text" => text}]} when is_binary(text) <- response,
         true <- byte_size(text) <= 262_144 and String.valid?(text) do
      {:ok, text}
    else
      {:error, _} = error -> error
      true -> {:error, :gitlab_tool_error}
      _ -> {:error, :ci_trace_result_invalid}
    end
  end

  def job_output(_arguments, _opts), do: {:error, :ci_trace_scope_required}

  @doc "Reads artifact metadata or downloads one exact job archive into a controller-chosen private directory. No URL mode is accepted."
  @spec job_artifacts(String.t(), map(), keyword()) :: {:ok, map() | [map()]} | {:error, term()}
  def job_artifacts(tool, args, opts) when tool in ~w(list_job_artifacts download_job_artifacts) and is_map(args) do
    types =
      if tool == "list_job_artifacts",
        do: %{"project_id" => "string", "job_id" => "string", "path" => "string", "recursive" => "boolean"},
        else: %{"project_id" => "string", "job_id" => "string", "local_path" => "string"}

    with true <- (is_map(opts[:mcp_session]) and Enum.sort(Map.keys(args)) == Enum.sort(Map.keys(types))) or {:error, :ci_artifact_scope_required},
         true <- Enum.all?(~w(project_id job_id), &(is_binary(args[&1]) and Regex.match?(~r/\A[1-9][0-9]*\z/, args[&1]))) or {:error, :ci_artifact_scope_required},
         :ok <- artifact_scope(tool, args),
         {:ok, tools} <- catalog(opts),
         schema = tools[tool],
         true <- artifact_schema?(schema, tool, types) or {:error, :ci_artifact_schema_unavailable},
         {:ok, response} <- call_tool(Keyword.get(opts, :app_server, AppServer), opts[:mcp_session], opts[:workspace], tool, args),
         false <- response["isError"] == true,
         {:ok, result} <- decode_result(response) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_artifact_result_invalid}
    end
  end

  def job_artifacts(_tool, _args, _opts), do: {:error, :ci_artifact_scope_required}

  defp artifact_scope("list_job_artifacts", %{"path" => path, "recursive" => true}) when is_binary(path) do
    components = String.split(path, "/")

    if path == "" or
         (byte_size(path) <= 1024 and String.valid?(path) and length(components) <= 4 and
            not Regex.match?(~r/[\x00-\x1f\x7f\\:]/u, path) and Enum.all?(components, &(&1 not in ["", ".", ".."]))),
       do: :ok,
       else: {:error, :ci_artifact_scope_required}
  end

  defp artifact_scope("download_job_artifacts", %{"local_path" => path}) when is_binary(path) do
    if Regex.match?(~r/\A\.factory-ci-artifacts-[0-9a-f]{32}\z/, path), do: :ok, else: {:error, :ci_artifact_scope_required}
  end

  defp artifact_scope(_, _), do: {:error, :ci_artifact_scope_required}

  defp artifact_schema?(schema, name, types) when is_map(schema) do
    required = get_in(schema, ["inputSchema", "required"])

    schema["name"] == name and get_in(schema, ["annotations", "readOnlyHint"]) == true and
      get_in(schema, ["inputSchema", "type"]) == "object" and is_list(required) and
      Enum.all?(~w(project_id job_id), &(&1 in required)) and Enum.all?(required, &Map.has_key?(types, &1)) and
      Enum.all?(types, fn {field, type} -> get_in(schema, ["inputSchema", "properties", field, "type"]) == type end)
  end

  defp artifact_schema?(_, _, _), do: false

  @doc "Reads one exact unfiltered discussion page on an existing read-only session."
  @spec discussion_page(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def discussion_page(args, opts) when is_map(args) do
    types = %{"project_id" => "string", "merge_request_iid" => "string", "page" => "number", "per_page" => "number"}

    with true <-
           (is_map(opts[:mcp_session]) and Enum.sort(Map.keys(args)) == ~w(merge_request_iid page per_page project_id) and
              args["page"] in 1..3 and args["per_page"] == 100 and
              Enum.all?(~w(project_id merge_request_iid), &(is_binary(args[&1]) and Regex.match?(~r/\A[1-9][0-9]*\z/, args[&1])))) or {:error, :ci_discussion_scope_required},
         {:ok, tools} <- catalog(opts),
         schema = tools["mr_discussions"],
         true <-
           (is_map(schema) and schema["name"] == "mr_discussions" and get_in(schema, ["annotations", "readOnlyHint"]) == true and
              get_in(schema, ["inputSchema", "type"]) == "object" and is_list(get_in(schema, ["inputSchema", "required"])) and
              Enum.all?(~w(project_id merge_request_iid), &(&1 in get_in(schema, ["inputSchema", "required"]))) and
              Enum.all?(get_in(schema, ["inputSchema", "required"]), &Map.has_key?(types, &1)) and
              Enum.all?(types, fn {key, type} -> get_in(schema, ["inputSchema", "properties", key, "type"]) == type end)) or {:error, :ci_discussion_schema_unavailable},
         {:ok, %{"items" => items, "pagination" => pagination} = result} <- call("mr_discussions", args, opts),
         true <- (is_list(items) and length(items) <= 100 and is_map(pagination)) or {:error, :ci_discussion_result_invalid} do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_discussion_result_invalid}
    end
  end

  def discussion_page(_args, _opts), do: {:error, :ci_discussion_scope_required}

  defp trace_scope(args, opts) do
    if is_map(opts[:mcp_session]) and Enum.sort(Map.keys(args)) == ~w(job_id limit offset project_id) and
         args["limit"] == 1000 and args["offset"] in [0, 1000, 2000, 3000, 4000] and
         Enum.all?(~w(project_id job_id), &(is_binary(args[&1]) and Regex.match?(~r/\A[1-9][0-9]*\z/, args[&1]))),
       do: :ok,
       else: {:error, :ci_trace_scope_required}
  end

  defp trace_schema(tools) when is_map(tools) do
    schema = tools["get_pipeline_job_output"]
    types = %{"project_id" => "string", "job_id" => "string", "limit" => "number", "offset" => "number"}

    if is_map(schema) and schema["name"] == "get_pipeline_job_output" and get_in(schema, ["annotations", "readOnlyHint"]) == true and
         get_in(schema, ["inputSchema", "type"]) == "object" and is_list(get_in(schema, ["inputSchema", "required"])) and
         Enum.all?(~w(project_id job_id), &(&1 in get_in(schema, ["inputSchema", "required"]))) and
         Enum.all?(get_in(schema, ["inputSchema", "required"]), &Map.has_key?(types, &1)) and
         Enum.all?(types, fn {field, type} -> get_in(schema, ["inputSchema", "properties", field, "type"]) == type end),
       do: :ok,
       else: {:error, :ci_trace_schema_unavailable}
  end

  @doc "Returns one decoded read-only GitLab tool result."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(tool, arguments, opts) when tool in @allowed_tools and is_map(arguments) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, AppServer)

    with {:ok, response} <- call_tool(app_server, Keyword.get(opts, :mcp_session), workspace, tool, arguments),
         false <- response["isError"] == true,
         {:ok, %{} = result} <- decode_result(response) do
      {:ok, result}
    else
      true -> {:error, :gitlab_tool_error}
      {:error, _reason} = error -> error
      _ -> {:error, :gitlab_tool_result_invalid}
    end
  end

  def call(_tool, _arguments, _opts), do: {:error, :gitlab_tool_not_allowed}

  @doc "Reads a bounded unfiltered pipeline-job page; no write tools or arbitrary array calls are admitted."
  @spec call_list(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def call_list(tool, arguments, opts) when tool in ~w(list_pipeline_jobs list_merge_request_pipelines) and is_map(arguments) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, AppServer)

    with :ok <- list_scope(tool, arguments, opts),
         {:ok, response} <- call_tool(app_server, Keyword.get(opts, :mcp_session), workspace, tool, arguments),
         false <- response["isError"] == true,
         {:ok, result} when is_list(result) <- decode_result(response),
         true <- length(result) <= 100 and Enum.all?(result, &is_map/1) do
      {:ok, result}
    else
      {:error, _} = error -> error
      true -> {:error, :gitlab_tool_error}
      _ -> {:error, :gitlab_tool_result_invalid}
    end
  end

  def call_list(_tool, _arguments, _opts), do: {:error, :gitlab_tool_not_allowed}

  defp list_scope("list_pipeline_jobs", _arguments, _opts), do: :ok

  defp list_scope("list_merge_request_pipelines", arguments, opts) do
    if is_map(opts[:mcp_session]) and Enum.sort(Map.keys(arguments)) == ~w(merge_request_iid page per_page project_id) and
         arguments["page"] in [1, 2] and arguments["per_page"] == 100 and
         Enum.all?(~w(project_id merge_request_iid), &(is_binary(arguments[&1]) and Regex.match?(~r/\A[1-9][0-9]*\z/, arguments[&1]))),
       do: :ok,
       else: {:error, :gitlab_mr_pipeline_scope_required}
  end

  defp call_tool(app_server, nil, workspace, tool, arguments),
    do: app_server.call_mcp_tool(workspace, "GitLab", tool, arguments)

  defp call_tool(app_server, session, _workspace, tool, arguments),
    do: app_server.call_mcp_tool_in_session(session, "GitLab", tool, arguments)

  defp decode_result(%{"structuredContent" => %{"result" => result}}) when is_binary(result),
    do: decode_json(result)

  defp decode_result(%{"structuredContent" => %{} = result}), do: bounded(result)
  defp decode_result(%{"structuredContent" => result}) when is_list(result), do: bounded(result)

  defp decode_result(%{"content" => [%{"type" => "text", "text" => text}]}) when is_binary(text),
    do: decode_json(text)

  defp decode_result(_response), do: {:error, :gitlab_tool_result_invalid}

  defp decode_json(text) when byte_size(text) <= @max_bytes do
    case Jason.decode(text) do
      {:ok, result} when is_map(result) or is_list(result) -> {:ok, result}
      _other -> {:error, :gitlab_tool_result_invalid}
    end
  end

  defp decode_json(_text), do: {:error, :gitlab_tool_result_too_large}

  defp bounded(result) do
    if byte_size(Jason.encode!(result)) <= @max_bytes,
      do: {:ok, result},
      else: {:error, :gitlab_tool_result_too_large}
  end
end
