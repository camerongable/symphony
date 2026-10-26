defmodule SymphonyElixir.FactoryGitLabMcpConnectorTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.GitLabMcpConnector
  alias SymphonyElixir.FactoryGitLabMcpConnectorTest.FakeAppServer

  test "branch heads require the exact readonly catalog and caller-owned session" do
    opts = [workspace: "/tmp/controller", app_server: FakeAppServer, mcp_session: %{thread_id: "controller"}]

    schema = %{
      "name" => "get_branch",
      "annotations" => %{"readOnlyHint" => true},
      "inputSchema" => %{"type" => "object", "required" => ~w(project_id branch_name), "properties" => Map.new(~w(project_id branch_name), &{&1, %{"type" => "string"}})}
    }

    sha = String.duplicate("a", 40)
    Process.put(:gitlab_mcp_catalog, {:ok, %{"get_branch" => schema}})

    Process.put(
      :gitlab_mcp_response,
      {:ok,
       %{
         "structuredContent" => %{
           "name" => "feature/exact",
           "web_url" => "https://gitlab.com/grailbio/grail/-/tree/feature/exact",
           "commit" => %{"id" => sha, "web_url" => "https://gitlab.com/grailbio/grail/-/commit/#{sha}"}
         }
       }}
    )

    assert {:ok, ^sha} = GitLabMcpConnector.branch_head(33_747_681, "grailbio/grail", "feature/exact", opts)
    assert_received {:mcp_session_call, _, "GitLab", "get_branch", %{"project_id" => "33747681", "branch_name" => "feature/exact"}}
    assert {:error, :gitlab_branch_scope_required} = GitLabMcpConnector.branch_head(33_747_681, "grailbio/grail", "feature/exact", Keyword.delete(opts, :mcp_session))
    refute_received {:mcp_session_call, _, _, _, _}

    for bad <- [
          put_in(schema, ["annotations", "readOnlyHint"], false),
          put_in(schema, ["inputSchema", "properties", "branch_name", "type"], "number"),
          put_in(schema, ["inputSchema", "required"], ~w(project_id branch)),
          Map.put(schema, "name", "get_commit")
        ] do
      Process.put(:gitlab_mcp_catalog, {:ok, %{"get_branch" => bad}})
      assert {:error, :gitlab_branch_schema_unavailable} = GitLabMcpConnector.branch_head(33_747_681, "grailbio/grail", "feature/exact", opts)
      refute_received {:mcp_session_call, _, _, _, _}
    end

    Process.put(:gitlab_mcp_catalog, {:ok, %{"get_branch" => schema}})

    result = %{
      "name" => "feature/exact",
      "web_url" => "https://gitlab.com/grailbio/grail/-/tree/feature/exact",
      "commit" => %{"id" => sha, "web_url" => "https://gitlab.com/grailbio/grail/-/commit/#{sha}"}
    }

    for bad <- [
          Map.put(result, "name", "feature/foreign"),
          Map.put(result, "project_id", 7),
          Map.put(result, "project_id", %{}),
          Map.put(result, "web_url", "https://gitlab.com/foreign/project/-/tree/feature/exact"),
          put_in(result, ["commit", "id"], String.duplicate("b", 39)),
          put_in(result, ["commit", "web_url"], "https://gitlab.com/foreign/project/-/commit/#{sha}"),
          Map.put(result, "commit", nil)
        ] do
      Process.put(:gitlab_mcp_response, {:ok, %{"structuredContent" => bad}})
      assert {:error, :gitlab_branch_result_invalid} = GitLabMcpConnector.branch_head(33_747_681, "grailbio/grail", "feature/exact", opts)
      assert_received {:mcp_session_call, _, "GitLab", "get_branch", _}
    end

    Process.put(:gitlab_mcp_response, {:ok, %{"isError" => true, "content" => []}})
    assert {:error, :gitlab_branch_result_invalid} = GitLabMcpConnector.branch_head(33_747_681, "grailbio/grail", "feature/exact", opts)
    assert_received {:mcp_session_call, _, "GitLab", "get_branch", _}
    Process.put(:gitlab_mcp_response, {:error, :mcp_tool_read_timeout})
    assert {:error, :mcp_tool_read_timeout} = GitLabMcpConnector.branch_head(33_747_681, "grailbio/grail", "feature/exact", opts)
    assert_received {:mcp_session_call, _, "GitLab", "get_branch", _}
  end

  test "artifact directory reads retain exact job session and readonly capability guards" do
    opts = [workspace: "/tmp/controller", app_server: FakeAppServer, mcp_session: %{thread_id: "controller"}]
    args = %{"project_id" => "33747681", "job_id" => "17239341490", "path" => "build-artifacts/tests", "recursive" => true}
    properties = Map.new(~w(project_id job_id path), &{&1, %{"type" => "string"}}) |> Map.put("recursive", %{"type" => "boolean"})
    schema = %{"name" => "list_job_artifacts", "annotations" => %{"readOnlyHint" => true}, "inputSchema" => %{"type" => "object", "required" => ~w(project_id job_id), "properties" => properties}}
    Process.put(:gitlab_mcp_catalog, {:ok, %{"list_job_artifacts" => schema}})
    Process.put(:gitlab_mcp_response, {:ok, %{"content" => [%{"type" => "text", "text" => "[]"}]}})
    assert {:ok, []} = GitLabMcpConnector.job_artifacts("list_job_artifacts", args, opts)
    assert_received {:mcp_session_call, _, "GitLab", "list_job_artifacts", ^args}

    for path <- ["/absolute", "../outside", "a/../b", "a//b", "C:/drive", "a\\b", "a\nsecret", "a/b/c/d/e", "trailing/"] do
      assert {:error, :ci_artifact_scope_required} = GitLabMcpConnector.job_artifacts("list_job_artifacts", Map.put(args, "path", path), opts)
    end

    assert {:error, :ci_artifact_scope_required} = GitLabMcpConnector.job_artifacts("list_job_artifacts", Map.put(args, "job_id", "../7"), opts)
    assert {:error, :ci_artifact_scope_required} = GitLabMcpConnector.job_artifacts("list_job_artifacts", args, Keyword.delete(opts, :mcp_session))
    Process.put(:gitlab_mcp_catalog, {:ok, %{"list_job_artifacts" => put_in(schema, ["annotations", "readOnlyHint"], false)}})
    assert {:error, :ci_artifact_schema_unavailable} = GitLabMcpConnector.job_artifacts("list_job_artifacts", args, opts)
    refute_received {:mcp_session_call, _, _, _, _}
  end

  test "discussion pages require exact unfiltered owner session scope and fresh readonly capability" do
    opts = [workspace: "/tmp/controller", app_server: FakeAppServer, mcp_session: %{thread_id: "controller"}]
    args = %{"project_id" => "33747681", "merge_request_iid" => "47818", "page" => 1, "per_page" => 100}
    properties = Map.new(~w(project_id merge_request_iid), &{&1, %{"type" => "string"}}) |> Map.merge(Map.new(~w(page per_page), &{&1, %{"type" => "number"}}))

    schema = %{
      "name" => "mr_discussions",
      "annotations" => %{"readOnlyHint" => true},
      "inputSchema" => %{"type" => "object", "required" => ~w(project_id merge_request_iid), "properties" => properties}
    }

    Process.put(:gitlab_mcp_catalog, {:ok, %{"mr_discussions" => schema}})
    response = %{"items" => [], "pagination" => %{"x_next_page" => nil}}
    Process.put(:gitlab_mcp_response, {:ok, %{"structuredContent" => response}})
    assert {:ok, ^response} = GitLabMcpConnector.discussion_page(args, opts)
    assert_received {:mcp_session_call, _, "GitLab", "mr_discussions", ^args}

    for changed <- [Map.put(args, "jmespath", "items"), Map.put(args, "page", 4), Map.put(args, "per_page", 20), Map.put(args, "project_id", "foreign/path")] do
      assert {:error, :ci_discussion_scope_required} = GitLabMcpConnector.discussion_page(changed, opts)
    end

    Process.put(:gitlab_mcp_catalog, {:ok, %{"mr_discussions" => put_in(schema, ["annotations", "readOnlyHint"], false)}})
    assert {:error, :ci_discussion_schema_unavailable} = GitLabMcpConnector.discussion_page(args, opts)
    assert {:error, :ci_discussion_scope_required} = GitLabMcpConnector.discussion_page(args, Keyword.delete(opts, :mcp_session))
    refute_received {:mcp_session_call, _, _, _, _}
  end

  test "CI traces require exact bounded arguments a fresh read-only schema and a single text result" do
    opts = [workspace: "/tmp/controller", app_server: FakeAppServer, mcp_session: %{thread_id: "controller"}]
    args = %{"project_id" => "33747681", "job_id" => "77", "limit" => 1000, "offset" => 0}
    fields = Map.new(~w(project_id job_id), &{&1, %{"type" => "string"}}) |> Map.merge(Map.new(~w(limit offset), &{&1, %{"type" => "number"}}))
    schema = %{"name" => "get_pipeline_job_output", "annotations" => %{"readOnlyHint" => true}, "inputSchema" => %{"type" => "object", "required" => ~w(project_id job_id), "properties" => fields}}
    Process.put(:gitlab_mcp_catalog, {:ok, %{"get_pipeline_job_output" => schema}})
    Process.put(:gitlab_mcp_response, {:ok, %{"content" => [%{"type" => "text", "text" => "trace"}]}})
    assert {:ok, "trace"} = GitLabMcpConnector.job_output(args, opts)
    assert_received {:mcp_session_call, _, "GitLab", "get_pipeline_job_output", ^args}

    for offset <- [1000, 2000, 3000, 4000] do
      page = Map.put(args, "offset", offset)
      assert {:ok, "trace"} = GitLabMcpConnector.job_output(page, opts)
      assert_received {:mcp_session_call, _, "GitLab", "get_pipeline_job_output", ^page}
    end

    for changed <- [Map.put(args, "jmespath", "@"), Map.put(args, "offset", 5000), Map.put(args, "limit", 2000), Map.put(args, "job_id", "../77")] do
      assert {:error, :ci_trace_scope_required} = GitLabMcpConnector.job_output(changed, opts)
    end

    Process.put(:gitlab_mcp_catalog, {:ok, %{"get_pipeline_job_output" => put_in(schema, ["annotations", "readOnlyHint"], false)}})
    assert {:error, :ci_trace_schema_unavailable} = GitLabMcpConnector.job_output(args, opts)
    assert {:error, :ci_trace_scope_required} = GitLabMcpConnector.job_output(args, Keyword.delete(opts, :mcp_session))
    refute_received {:mcp_session_call, _, _, _, _}
  end

  test "MR pipeline lists require an exact unfiltered bounded scope and the existing session" do
    opts = [workspace: "/tmp/controller", app_server: SymphonyElixir.FactoryGitLabMcpConnectorTest.FakeAppServer, mcp_session: %{thread_id: "controller"}]
    arguments = %{"project_id" => "33747681", "merge_request_iid" => "47818", "page" => 1, "per_page" => 100}
    Process.put(:gitlab_mcp_response, {:ok, %{"structuredContent" => []}})
    assert {:ok, []} = GitLabMcpConnector.call_list("list_merge_request_pipelines", arguments, opts)
    assert_received {:mcp_session_call, _, "GitLab", "list_merge_request_pipelines", ^arguments}

    for changed <- [
          Map.put(arguments, "status", "success"),
          Map.put(arguments, "jmespath", "[?status=='success']"),
          Map.put(arguments, "page", 3),
          Map.put(arguments, "per_page", 20),
          Map.put(arguments, "project_id", "foreign/path")
        ] do
      assert {:error, :gitlab_mr_pipeline_scope_required} = GitLabMcpConnector.call_list("list_merge_request_pipelines", changed, opts)
    end

    assert {:error, :gitlab_mr_pipeline_scope_required} = GitLabMcpConnector.call_list("list_merge_request_pipelines", arguments, Keyword.delete(opts, :mcp_session))
    refute_received {:mcp_call, _, _, _, _}
    refute_received {:mcp_session_call, _, _, _, _}
    assert {:error, :gitlab_tool_not_allowed} = GitLabMcpConnector.call("list_merge_request_pipelines", arguments, opts)
  end

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
