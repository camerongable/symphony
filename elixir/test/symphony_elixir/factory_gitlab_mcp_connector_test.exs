defmodule SymphonyElixir.FactoryGitLabMcpConnectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.GitLabMcpConnector

  defmodule FakeAppServer do
    @spec mcp_tool_catalog_in_session(map(), String.t()) :: {:ok, map()} | {:error, term()}
    def mcp_tool_catalog_in_session(session, server) do
      send(self(), {:mcp_catalog_call, session, server})
      Process.get(:gitlab_mcp_catalog)
    end

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

  test "catalog discovery stays on the existing controller session and does not authorize calls" do
    session = %{thread_id: "one-ephemeral-thread"}
    tools = %{"get_pipeline" => %{"name" => "get_pipeline", "inputSchema" => %{"type" => "object"}}}
    Process.put(:gitlab_mcp_catalog, {:ok, tools})

    assert {:ok, ^tools} = GitLabMcpConnector.catalog(app_server: FakeAppServer, mcp_session: session)
    assert_received {:mcp_catalog_call, ^session, "GitLab"}
    assert {:error, :gitlab_tool_not_allowed} = GitLabMcpConnector.call("retry_pipeline_job", %{}, app_server: FakeAppServer, mcp_session: session)
    refute_received {:mcp_call, _, _, _, _}
    refute_received {:mcp_session_call, _, _, _, _}
  end

  test "CI read tools decode objects and job arrays without admitting other collections" do
    opts = [workspace: "/tmp/controller", app_server: FakeAppServer, mcp_session: %{thread_id: "controller"}]

    for tool <- ~w(get_pipeline get_commit) do
      Process.put(:gitlab_mcp_response, {:ok, %{"structuredContent" => %{"id" => "99"}}})
      assert {:ok, %{"id" => "99"}} = GitLabMcpConnector.call(tool, %{}, opts)
    end

    for response <- [
          %{"content" => [%{"type" => "text", "text" => ~s([{"id":"100"}])}]},
          %{"structuredContent" => %{"result" => ~s([{"id":"100"}])}},
          %{"structuredContent" => [%{"id" => "100"}]}
        ] do
      Process.put(:gitlab_mcp_response, {:ok, response})
      assert {:ok, [%{"id" => "100"}]} = GitLabMcpConnector.call_list("list_pipeline_jobs", %{}, opts)
      assert {:error, :gitlab_tool_result_invalid} = GitLabMcpConnector.call("get_pipeline", %{}, opts)
    end

    assert {:error, :gitlab_tool_not_allowed} = GitLabMcpConnector.call_list("list_pipelines", %{}, opts)

    for response <- [
          %{"structuredContent" => %{"id" => "99"}},
          %{"structuredContent" => [nil]},
          %{"structuredContent" => List.duplicate(%{}, 101)},
          %{"content" => [%{"type" => "text", "text" => "null"}]}
        ] do
      Process.put(:gitlab_mcp_response, {:ok, response})
      assert {:error, :gitlab_tool_result_invalid} = GitLabMcpConnector.call_list("list_pipeline_jobs", %{}, opts)
    end

    Process.put(:gitlab_mcp_response, {:ok, %{"isError" => true}})
    assert {:error, :gitlab_tool_error} = GitLabMcpConnector.call_list("list_pipeline_jobs", %{}, opts)
    Process.put(:gitlab_mcp_response, {:error, :offline})
    assert {:error, :offline} = GitLabMcpConnector.call_list("list_pipeline_jobs", %{}, opts)

    for response <- [
          %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 1_048_577)}]},
          %{"structuredContent" => %{"large" => String.duplicate("x", 1_048_577)}}
        ] do
      Process.put(:gitlab_mcp_response, {:ok, response})
      assert {:error, :gitlab_tool_result_too_large} = GitLabMcpConnector.call_list("list_pipeline_jobs", %{}, opts)
    end
  end

  test "unavailable catalogs and absent sessions cannot fall back to a new session or REST credentials" do
    options = [app_server: FakeAppServer, workspace: "/tmp/controller"]
    assert {:error, :gitlab_catalog_session_required} = GitLabMcpConnector.catalog(options)
    refute_received {:mcp_catalog_call, _, _}
    Process.put(:gitlab_mcp_catalog, {:error, :mcp_tool_catalog_unavailable})
    options = [app_server: FakeAppServer, mcp_session: %{thread_id: "existing"}]
    assert {:error, :mcp_tool_catalog_unavailable} = GitLabMcpConnector.catalog(options)
    refute_received {:mcp_call, _, _, _, _}
    refute_received {:mcp_session_call, _, _, _, _}
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
