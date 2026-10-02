defmodule SymphonyElixir.Factory.GitLabMcpConnector do
  @moduledoc """
  Calls the existing authenticated GitLab MCP tools without a model turn.
  """

  alias SymphonyElixir.Codex.AppServer

  @allowed_tools ~w(get_merge_request get_merge_request_discussion mr_discussions whoami)

  @doc "Returns one decoded read-only GitLab tool result."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(tool, arguments, opts) when tool in @allowed_tools and is_map(arguments) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, AppServer)

    with {:ok, response} <- call_tool(app_server, Keyword.get(opts, :mcp_session), workspace, tool, arguments),
         false <- response["isError"] == true,
         {:ok, result} <- decode_result(response) do
      {:ok, result}
    else
      true -> {:error, :gitlab_tool_error}
      {:error, _reason} = error -> error
    end
  end

  def call(_tool, _arguments, _opts), do: {:error, :gitlab_tool_not_allowed}

  defp call_tool(app_server, nil, workspace, tool, arguments),
    do: app_server.call_mcp_tool(workspace, "GitLab", tool, arguments)

  defp call_tool(app_server, session, _workspace, tool, arguments),
    do: app_server.call_mcp_tool_in_session(session, "GitLab", tool, arguments)

  defp decode_result(%{"structuredContent" => %{"result" => result}}) when is_binary(result),
    do: decode_json_map(result)

  defp decode_result(%{"structuredContent" => %{} = result}), do: {:ok, result}

  defp decode_result(%{"content" => [%{"type" => "text", "text" => text}]}) when is_binary(text),
    do: decode_json_map(text)

  defp decode_result(_response), do: {:error, :gitlab_tool_result_invalid}

  defp decode_json_map(text) do
    case Jason.decode(text) do
      {:ok, %{} = result} -> {:ok, result}
      _other -> {:error, :gitlab_tool_result_invalid}
    end
  end
end
