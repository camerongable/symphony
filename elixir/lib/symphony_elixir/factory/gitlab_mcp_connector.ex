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
  def call_list("list_pipeline_jobs" = tool, arguments, opts) when is_map(arguments) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, AppServer)

    with {:ok, response} <- call_tool(app_server, Keyword.get(opts, :mcp_session), workspace, tool, arguments),
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
