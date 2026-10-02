defmodule SymphonyElixir.Factory.JiraMcpConnector do
  @moduledoc """
  Provides the controller's Jira MCP tools through a short-lived Codex app-server connection.

  Tool approval or elicitation is never answered automatically. The caller must
  treat an unproven result as blocked and reconcile from Jira before retrying.
  """

  alias SymphonyElixir.Codex.AppServer

  @allowed_tools ~w(jira_search jira_get_issue jira_add_comment jira_update_issue)

  @doc "Calls one Jira tool and returns only a decoded structured result."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(tool, arguments, opts) when tool in @allowed_tools and is_map(arguments) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, AppServer)

    with {:ok, response} <- call_tool(app_server, Keyword.get(opts, :mcp_session), workspace, tool, arguments) do
      cond do
        response["isError"] == true -> {:error, :jira_tool_error}
        tool in ["jira_search", "jira_get_issue"] -> decode_result(response)
        true -> {:ok, %{}}
      end
    end
  end

  def call(_tool, _arguments, _opts), do: {:error, :jira_tool_not_allowed}

  defp call_tool(app_server, nil, workspace, tool, arguments),
    do: app_server.call_mcp_tool(workspace, "Jira", tool, arguments)

  defp call_tool(app_server, session, _workspace, tool, arguments),
    do: app_server.call_mcp_tool_in_session(session, "Jira", tool, arguments)

  defp decode_result(%{"structuredContent" => %{"result" => result}}) when is_binary(result),
    do: decode_json_map(result)

  defp decode_result(%{"structuredContent" => %{} = result}), do: {:ok, result}

  defp decode_result(%{"content" => [%{"type" => "text", "text" => text}]}) when is_binary(text) do
    decode_json_map(text)
  end

  defp decode_result(_response), do: {:error, :jira_tool_result_invalid}

  defp decode_json_map(text) do
    case Jason.decode(text) do
      {:ok, %{} = result} -> {:ok, result}
      _other -> {:error, :jira_tool_result_invalid}
    end
  end
end
