defmodule SymphonyElixir.FactoryGitLabMrWriterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.GitLabMrWriter
  alias SymphonyElixir.TicketWorkerFixture.PublicationMcpServer, as: FakeAppServer

  setup do
    catalog = __DIR__ |> Path.join("../support/gitlab_mr_schemas.json") |> File.read!() |> Jason.decode!()
    Process.put(:mr_catalog, Map.delete(catalog, "create_merge_request"))
    scope = %{"project_id" => 33_747_681, "project" => "grailbio/grail", "source_branch" => "cgable/PPL-123", "target_branch" => "master"}
    {:ok, scope: scope, catalog: catalog, opts: [app_server: FakeAppServer, mcp_session: %{thread_id: "connector"}, per_page: 2, max_pages: 2]}
  end

  test "discovery reads every state and completes pagination without requiring write capability", ctx do
    items = [Map.merge(ctx.scope, %{"iid" => 7, "state" => "closed"}), Map.merge(ctx.scope, %{"iid" => 8, "state" => "opened", "draft" => false, "reviewers" => [%{"id" => 9}]})]
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => items}}, {:ok, %{"content" => [%{"type" => "text", "text" => "[]"}]}}])

    catalog =
      Process.get(:mr_catalog) |> put_in(["list_merge_requests", "inputSchema", "properties", "harmless_optional"], %{"type" => "string", "description" => "Additional optional provider input"})

    Process.put(:mr_catalog, Map.put(catalog, "unrelated_tool", %{"name" => "unrelated_tool"}))

    assert {:ok, ^items} = GitLabMrWriter.discover(ctx.scope, ctx.opts)

    for page <- [1, 2] do
      assert_receive {:mr_call, "list_merge_requests",
                      %{"project_id" => "33747681", "source_branch" => "cgable/PPL-123", "target_branch" => "master", "state" => "all", "scope" => "all", "page" => ^page, "per_page" => 2}}
    end

    refute_received {:mr_call, "create_merge_request", _}
  end

  test "creation uses only the admitted draft arguments and refuses unsupported required inputs", ctx do
    intent = Map.merge(ctx.scope, %{"title" => "Draft: feat(PPL-123): preserve fixture", "description" => "## Summary\nSynthetic contract.\n\n## Test plan\n- Exact fixture checks."})
    result = Map.merge(ctx.scope, %{"iid" => 42, "draft" => true})
    Process.put(:mr_catalog, ctx.catalog)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => result}}])

    assert :ok = GitLabMrWriter.creation_capability(intent, ctx.opts)
    assert {:ok, ^result} = GitLabMrWriter.create(intent, ctx.opts)

    expected =
      Map.take(intent, ~w(title description source_branch target_branch))
      |> Map.merge(%{"project_id" => "33747681", "draft" => true, "reviewer_ids" => [], "assignee_ids" => [11_599_766], "remove_source_branch" => false})

    assert_receive {:mr_call, "create_merge_request", ^expected}
    Process.put(:mr_catalog, put_in(ctx.catalog, ["create_merge_request", "inputSchema", "required"], ["new_mandatory_input"]))
    assert {:error, :gitlab_mr_capability_incompatible} = GitLabMrWriter.creation_capability(intent, ctx.opts)
    refute_received {:mr_call, _, _}
  end

  test "incomplete pagination and explicit connector refusals never fall back to a model", ctx do
    items = for iid <- [7, 8], do: Map.put(ctx.scope, "iid", iid)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => items}}, {:ok, %{"structuredContent" => items}}])
    assert {:error, :gitlab_mr_discovery_incomplete} = GitLabMrWriter.discover(ctx.scope, ctx.opts)
    assert_receive {:mr_call, "list_merge_requests", _}
    assert_receive {:mr_call, "list_merge_requests", _}
    Process.put(:mr_responses, [{:error, :mcp_tool_approval_required}])
    assert {:error, :mcp_tool_approval_required} = GitLabMrWriter.fetch(ctx.scope, 7, ctx.opts)
    assert_receive {:mr_call, "get_merge_request", %{"project_id" => "33747681", "merge_request_iid" => "7"}}
    refute_received {:mr_call, _, _}
    assert {:error, :gitlab_mr_pagination_invalid} = GitLabMrWriter.discover(ctx.scope, Keyword.put(ctx.opts, :per_page, 101))
    assert {:error, :gitlab_mr_pagination_invalid} = GitLabMrWriter.discover(ctx.scope, Keyword.put(ctx.opts, :max_pages, 0))
  end

  test "actual provider string IDs and native source-removal flags are normalized without coercing booleans", ctx do
    raw = Map.merge(ctx.scope, %{"project_id" => "33747681", "iid" => "42", "draft" => true, "should_remove_source_branch" => false, "force_remove_source_branch" => false})
    Process.put(:mr_responses, [{:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(raw)}]}}])
    assert {:ok, mr} = GitLabMrWriter.fetch(ctx.scope, 42, ctx.opts)
    assert mr["project_id"] == 33_747_681 and mr["iid"] == 42 and mr["remove_source_branch"] == false
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => Map.put(raw, "should_remove_source_branch", "false")}}])
    assert {:error, :gitlab_mr_result_invalid} = GitLabMrWriter.fetch(ctx.scope, 42, ctx.opts)

    for flags <- [
          %{},
          %{"should_remove_source_branch" => nil, "force_remove_source_branch" => false},
          %{"should_remove_source_branch" => false},
          %{"should_remove_source_branch" => false, "force_remove_source_branch" => nil}
        ] do
      value = raw |> Map.drop(~w(should_remove_source_branch force_remove_source_branch)) |> Map.merge(flags)
      Process.put(:mr_responses, [{:ok, %{"structuredContent" => value}}])
      assert {:ok, unknown} = GitLabMrWriter.fetch(ctx.scope, 42, ctx.opts)
      assert unknown["remove_source_branch"] == nil
    end

    Process.put(:mr_responses, [{:ok, %{"structuredContent" => Map.put(raw, "force_remove_source_branch", true)}}])
    assert {:ok, %{"remove_source_branch" => true}} = GitLabMrWriter.fetch(ctx.scope, 42, ctx.opts)

    for {key, value} <- [{"iid", "43"}, {"project_id", "99"}, {"source_branch", "cgable/foreign"}, {"target_branch", "foreign"}] do
      Process.put(:mr_responses, [{:ok, %{"structuredContent" => Map.put(raw, key, value)}}])
      assert {:error, :gitlab_mr_remote_identity_mismatch} = GitLabMrWriter.fetch(ctx.scope, 42, ctx.opts)
    end
  end
end
