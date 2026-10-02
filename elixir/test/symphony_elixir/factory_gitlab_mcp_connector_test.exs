defmodule SymphonyElixir.FactoryGitLabMcpConnectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.GitLabMcpConnector

  defmodule FakeAppServer do
    @spec call_mcp_tool(Path.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
    def call_mcp_tool(workspace, server, tool, args) do
      send(self(), {:mcp_call, workspace, server, tool, args})
      Process.get(:gitlab_mcp_response)
    end

    @spec call_mcp_tool_in_session(map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
    def call_mcp_tool_in_session(session, server, tool, args) do
      send(self(), {:mcp_session_call, session, server, tool, args})
      Process.get(:gitlab_mcp_response)
    end
  end

  test "decodes each supported read-only GitLab response envelope" do
    for response <- [
          %{"structuredContent" => %{"result" => ~s({"iid":"42"})}},
          %{"structuredContent" => %{"iid" => "42"}},
          %{"content" => [%{"type" => "text", "text" => ~s({"iid":"42"})}]}
        ] do
      Process.put(:gitlab_mcp_response, {:ok, response})

      assert {:ok, %{"iid" => "42"}} =
               GitLabMcpConnector.call("get_merge_request", %{"merge_request_iid" => "42"},
                 workspace: "/tmp/controller",
                 app_server: FakeAppServer
               )

      assert_received {:mcp_call, "/tmp/controller", "GitLab", "get_merge_request", %{"merge_request_iid" => "42"}}
    end
  end

  test "permits read-only authenticated identity lookup" do
    Process.put(:gitlab_mcp_response, {:ok, %{"content" => [%{"type" => "text", "text" => ~s({"id":"11599766"})}]}})

    assert {:ok, %{"id" => "11599766"}} =
             GitLabMcpConnector.call("whoami", %{}, workspace: "/tmp/controller", app_server: FakeAppServer)

    assert_received {:mcp_call, "/tmp/controller", "GitLab", "whoami", %{}}
  end

  test "uses the caller-owned session for repeated reads" do
    Process.put(:gitlab_mcp_response, {:ok, %{"structuredContent" => %{"result" => ~s({"iid":"42"})}}})
    session = %{thread_id: "one-ephemeral-thread"}

    for _ <- 1..2 do
      assert {:ok, %{"iid" => "42"}} =
               GitLabMcpConnector.call("get_merge_request", %{"merge_request_iid" => "42"},
                 workspace: "/tmp/controller",
                 app_server: FakeAppServer,
                 mcp_session: session
               )
    end

    assert_received {:mcp_session_call, ^session, "GitLab", "get_merge_request", _}
    assert_received {:mcp_session_call, ^session, "GitLab", "get_merge_request", _}
    refute_received {:mcp_call, _, _, _, _}
  end

  test "rejects tool failures, malformed results, and writes" do
    for {response, expected} <- [
          {{:ok, %{"isError" => true}}, :gitlab_tool_error},
          {{:ok, %{"content" => [%{"type" => "text", "text" => "not json"}]}}, :gitlab_tool_result_invalid},
          {{:ok, %{"content" => []}}, :gitlab_tool_result_invalid},
          {{:error, :offline}, :offline}
        ] do
      Process.put(:gitlab_mcp_response, response)

      assert {:error, ^expected} =
               GitLabMcpConnector.call("mr_discussions", %{}, workspace: "/tmp/controller", app_server: FakeAppServer)
    end

    assert {:error, :gitlab_tool_not_allowed} =
             GitLabMcpConnector.call("create_merge_request_note", %{}, workspace: "/tmp/controller", app_server: FakeAppServer)
  end
end
