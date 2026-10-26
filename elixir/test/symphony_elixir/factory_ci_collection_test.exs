defmodule SymphonyElixir.FactoryCiCollectionTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{CiCollection, GitLabMcpConnector, RunLedger, TicketWorkerRunner}
  alias SymphonyElixir.FactoryCiCollectionTest.Connector

  setup :setup_fixture

  test "missing provider head field selects the newest MR pipeline before status filtering", ctx do
    {mr, pipeline, jobs} = prepare(ctx)
    pipeline = Map.merge(pipeline, %{"created_at" => "2026-10-14T20:01:43Z", "status" => "failed"})
    older = Map.merge(pipeline, %{"id" => "101", "created_at" => "2026-10-13T20:01:43Z", "status" => "success"})
    jobs = Enum.map(jobs, &Map.put(&1, "status", "failed"))
    fallback_reads(Map.delete(mr, "head_pipeline"), pipeline, jobs, [older, pipeline])
    {:ok, before} = RunLedger.get(ctx.store, "run")
    assert {:ok, collected} = collect(ctx)
    assert collected["evidence"]["status"] == "BLOCK"
    assert collected["evidence"]["pipeline_id"] == 99
    assert [%{"id" => 100, "name" => "bazel", "status" => "failed"}] = Enum.map(collected["evidence"]["failed_jobs"], &Map.take(&1, ~w(id name status)))
    refute Map.has_key?(collected["snapshots"]["mr"], "head_pipeline")
    assert collected["snapshots"]["pipeline_selector"]["selected_pipeline_id"] == 99
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert_received {:ci_read, "list_merge_request_pipelines", %{"project_id" => "33747681", "merge_request_iid" => "42", "page" => 1, "per_page" => 100}}
    assert_received {:ci_read, "list_merge_request_pipelines", %{"page" => 2, "per_page" => 100}}
  end

  defp fallback_reads(mr, pipeline, jobs, listed, last_listed \\ nil) do
    name = "list_merge_request_pipelines"
    fields = %{"project_id" => "string", "merge_request_iid" => "string", "page" => "number", "per_page" => "number"}

    schema = %{
      "name" => name,
      "annotations" => %{"readOnlyHint" => true},
      "inputSchema" => %{"type" => "object", "required" => ~w(project_id merge_request_iid), "properties" => Map.new(fields, fn {key, type} -> {key, %{"type" => type}} end)}
    }

    Process.put(:ci_catalog, Map.put(Process.get(:ci_catalog), name, schema))
    pipeline_reads = if is_nil(pipeline), do: [], else: [{"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:ok, jobs}}, {"list_pipeline_jobs", {:ok, []}}]

    Process.put(
      :ci_reads,
      [
        {"get_merge_request", {:ok, mr}},
        {name, {:ok, listed}},
        {name, {:ok, []}}
      ] ++
        pipeline_reads ++
        [
          {"get_merge_request", {:ok, mr}},
          {name, {:ok, last_listed || listed}},
          {name, {:ok, []}}
        ]
    )
  end

  test "missing head fallback rejects ambiguous timestamps duplicate rows incomplete pages and listing drift", ctx do
    {mr, pipeline, jobs} = prepare(ctx)
    mr = Map.delete(mr, "head_pipeline")
    pipeline = Map.put(pipeline, "created_at", "2026-10-14T20:01:43Z")

    for rows <- [
          [Map.delete(pipeline, "created_at")],
          [Map.put(pipeline, "created_at", "invalid")],
          [pipeline, pipeline],
          [pipeline, Map.put(pipeline, "id", "101")],
          [Map.put(pipeline, "project_id", "1")]
        ] do
      fallback_reads(mr, pipeline, jobs, rows)
      assert {:error, :ci_mr_pipeline_selector_unproven} = collect(ctx)
    end

    for bad_page <- [List.duplicate(pipeline, 101), [nil]] do
      fallback_reads(mr, pipeline, jobs, bad_page)
      assert {:error, :ci_mr_pipelines_limit_or_shape} = collect(ctx)
    end

    fallback_reads(mr, pipeline, jobs, [pipeline])
    Process.put(:ci_reads, List.replace_at(Process.get(:ci_reads), 2, {"list_merge_request_pipelines", {:ok, [pipeline]}}))
    assert {:error, :ci_mr_pipelines_limit_or_shape} = collect(ctx)
    fallback_reads(mr, pipeline, jobs, [pipeline], [Map.put(pipeline, "status", "failed")])
    assert {:error, :ci_mr_pipeline_changed_during_collection} = collect(ctx)
  end

  test "newest wrong candidate branch or source cannot fall back to an older successful MR pipeline", ctx do
    {mr, pipeline, jobs} = prepare(ctx)
    mr = Map.delete(mr, "head_pipeline")
    pipeline = Map.put(pipeline, "created_at", "2026-10-14T20:01:43Z")
    older = Map.merge(pipeline, %{"id" => "101", "created_at" => "2026-10-13T20:01:43Z"})

    for {changed, reason} <- [
          {Map.put(pipeline, "sha", String.duplicate("b", 40)), :ci_pipeline_candidate_mismatch},
          {Map.put(pipeline, "ref", "cgable/fixture"), :ci_pipeline_candidate_mismatch},
          {Map.put(pipeline, "source", "push"), :ci_pipeline_scope_mismatch}
        ] do
      fallback_reads(mr, changed, jobs, [older, changed])
      assert {:error, ^reason} = collect(ctx)
    end
  end

  test "complete empty MR listings wait without inventing a raw head or a successful pipeline", ctx do
    {mr, _, _} = prepare(ctx)
    fallback_reads(Map.delete(mr, "head_pipeline"), nil, [], [])
    assert {:ok, %{"evidence" => %{"status" => "WAIT", "pipeline_id" => nil}, "snapshots" => snapshots}} = collect(ctx)
    refute Map.has_key?(snapshots["mr"], "head_pipeline")
    assert snapshots["pipeline_selector"]["before"] == [] and snapshots["pipeline_selector"]["after"] == []
  end

  test "pure binder refuses altered selector provenance selected older records or invented provider heads", ctx do
    {mr, pipeline, jobs} = prepare(ctx)
    pipeline = Map.put(pipeline, "created_at", "2026-10-14T20:01:43Z")
    older = Map.merge(pipeline, %{"id" => "101", "created_at" => "2026-10-13T20:01:43Z"})
    fallback_reads(Map.delete(mr, "head_pipeline"), pipeline, jobs, [older, pipeline])
    assert {:ok, %{"snapshots" => snapshots}} = collect(ctx)

    for changed <- [
          put_in(snapshots, ["pipeline_selector", "selected_pipeline_id"], 101),
          put_in(snapshots, ["pipeline_selector", "complete_pages"], [1]),
          put_in(snapshots, ["pipeline_selector", "project_id"], 1),
          put_in(snapshots, ["pipeline_selector", "after"], []),
          put_in(snapshots, ["pipeline_selector", "caller_authorized"], true),
          put_in(snapshots, ["mr", "head_pipeline"], pipeline)
        ] do
      assert {:error, :ci_mr_pipeline_selector_unproven} = TicketWorkerRunner.ci_binding(ctx.store, "run", changed, 33_747_681)
    end
  end

  test "MR-only collection preserves explicit branch retention and normalizes only the provider setting", ctx do
    {mr, _, _} = prepare(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    opts = [connector: Connector, mcp_session: %{thread_id: "controller"}]

    for flags <- [%{"remove_source_branch" => false}, %{"force_remove_source_branch" => false}, %{"remove_source_branch" => false, "force_remove_source_branch" => false}] do
      observed = Map.merge(mr, flags)
      Process.put(:ci_reads, [{"get_merge_request", {:ok, observed}}, {"get_merge_request", {:ok, observed}}])
      assert {:ok, readback} = CiCollection.collect_mr(run, 33_747_681, opts)
      assert readback["remove_source_branch"] == false
      if Map.has_key?(flags, "force_remove_source_branch"), do: assert(readback["force_remove_source_branch"] == false)
    end
  end

  test "MR-only collection never infers retention from missing malformed conflicting or merge-time settings", ctx do
    {mr, _, _} = prepare(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    opts = [connector: Connector, mcp_session: %{thread_id: "controller"}]

    for flags <- [
          %{},
          %{"should_remove_source_branch" => false},
          %{"force_remove_source_branch" => nil},
          %{"force_remove_source_branch" => "false"},
          %{"force_remove_source_branch" => true},
          %{"remove_source_branch" => nil, "force_remove_source_branch" => false},
          %{"remove_source_branch" => "false", "force_remove_source_branch" => false},
          %{"remove_source_branch" => true, "force_remove_source_branch" => false},
          %{"remove_source_branch" => false, "force_remove_source_branch" => true},
          %{"remove_source_branch" => false, "force_remove_source_branch" => nil}
        ] do
      observed = Map.merge(mr, flags)
      Process.put(:ci_reads, [{"get_merge_request", {:ok, observed}}, {"get_merge_request", {:ok, observed}}])
      assert {:ok, readback} = CiCollection.collect_mr(run, 33_747_681, opts)
      refute readback["remove_source_branch"] == false
    end
  end

  test "MR-only collection detects provider retention changes between reads", ctx do
    {mr, _, _} = prepare(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    first = Map.put(mr, "force_remove_source_branch", false)
    last = Map.put(first, "force_remove_source_branch", true)
    Process.put(:ci_reads, [{"get_merge_request", {:ok, first}}, {"get_merge_request", {:ok, last}}])
    assert {:error, :mr_changed_during_collection} = CiCollection.collect_mr(run, 33_747_681, connector: Connector, mcp_session: %{thread_id: "controller"})
  end

  test "MR-only collection needs just its read-only catalog and ignores unrelated pipeline changes", ctx do
    {mr, _pipeline, _jobs} = prepare(ctx)
    Process.put(:ci_catalog, Map.take(Process.get(:ci_catalog), ["get_merge_request"]))
    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_merge_request", {:ok, Map.put(mr, "head_pipeline", nil)}}])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    opts = [connector: Connector, mcp_session: %{thread_id: "controller"}]
    assert {:ok, readback} = CiCollection.collect_mr(run, 33_747_681, opts)
    assert readback["project_id"] == 33_747_681 and readback["iid"] == 42
    refute Map.has_key?(readback, "head_pipeline")
    assert_received {:ci_read, "get_merge_request", %{"project_id" => "33747681", "merge_request_iid" => "42", "include_summaries" => false}}
    assert_received {:ci_read, "get_merge_request", _}
    refute_received {:ci_read, _, _}
  end

  test "MR-only collection refuses missing session, pin, unsafe catalog, wrong project and changing human state", ctx do
    {mr, _pipeline, _jobs} = prepare(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    opts = [connector: Connector, mcp_session: %{thread_id: "controller"}]
    assert {:error, :mr_project_pin_required} = CiCollection.collect_mr(run, nil, opts)
    assert {:error, :gitlab_catalog_session_required} = CiCollection.collect_mr(run, 33_747_681, connector: Connector)
    assert {:error, :mr_iid_required} = CiCollection.collect_mr(Map.put(run, "mr_iid", 0), 33_747_681, opts)
    catalog = Process.get(:ci_catalog)
    Process.put(:ci_catalog, put_in(catalog, ["get_merge_request", "annotations", "readOnlyHint"], false))
    assert {:error, {:ci_tool_schema_unavailable, "get_merge_request"}} = CiCollection.collect_mr(run, 33_747_681, opts)
    refute_received {:ci_read, _, _}
    Process.put(:ci_catalog, catalog)
    Process.put(:ci_reads, [{"get_merge_request", {:ok, Map.put(mr, "project_id", 1)}}])
    assert {:error, :mr_project_binding_mismatch} = CiCollection.collect_mr(run, 33_747_681, opts)
    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_merge_request", {:ok, Map.put(mr, "draft", false)}}])
    assert {:error, :mr_changed_during_collection} = CiCollection.collect_mr(run, 33_747_681, opts)
  end

  defmodule Connector do
    @spec catalog(keyword()) :: {:ok, map()}
    def catalog(_opts), do: {:ok, Process.get(:ci_catalog)}

    @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def call(tool, args, _opts), do: response(tool, args)

    @spec call_list(String.t(), map(), keyword()) :: {:ok, list()} | {:error, term()}
    def call_list(tool, args, _opts), do: response(tool, args)

    defp response(tool, args) do
      send(self(), {:ci_read, tool, args})
      [{^tool, result} | rest] = Process.get(:ci_reads)
      Process.put(:ci_reads, rest)

      case result do
        callback when is_function(callback, 0) -> callback.()
        value -> value
      end
    end
  end

  defp prepare(ctx) do
    url = "https://gitlab.com/grailbio/grail/-/merge_requests/42"
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "CI_WAITING", mr_iid: 42, mr_url: url, ci_preflight_sha: ctx.sha})

    pipeline = %{
      "id" => "99",
      "project_id" => "33747681",
      "sha" => ctx.sha,
      "ref" => "refs/merge-requests/42/head",
      "source" => "merge_request_event",
      "status" => "success",
      "web_url" => "https://gitlab.com/grailbio/grail/-/pipelines/99"
    }

    mr = %{
      "iid" => "42",
      "project_id" => "33747681",
      "web_url" => url,
      "sha" => ctx.sha,
      "source_branch" => "cgable/fixture",
      "target_branch" => "master",
      "draft" => true,
      "reviewers" => [],
      "assignees" => [%{"id" => "11599766"}],
      "state" => "opened",
      "head_pipeline" => pipeline
    }

    jobs = [
      %{
        "id" => "100",
        "name" => "bazel",
        "status" => "success",
        "allow_failure" => false,
        "web_url" => "https://gitlab.com/grailbio/grail/-/jobs/100",
        "pipeline" => Map.take(pipeline, ~w(id project_id sha))
      }
    ]

    catalog =
      Map.new(
        [
          {"get_merge_request", %{"project_id" => "string", "merge_request_iid" => "string", "include_summaries" => "boolean"}, ~w(project_id merge_request_iid)},
          {"get_pipeline", %{"project_id" => "string", "pipeline_id" => "string"}, ~w(project_id pipeline_id)},
          {"list_pipeline_jobs", %{"project_id" => "string", "pipeline_id" => "string", "page" => "number", "per_page" => "number", "include_retried" => "boolean"}, ~w(project_id pipeline_id)},
          {"get_commit", %{"project_id" => "string", "sha" => "string", "stats" => "boolean"}, ~w(project_id sha)}
        ],
        fn {name, fields, required} ->
          {name,
           %{
             "name" => name,
             "annotations" => %{"readOnlyHint" => true},
             "inputSchema" => %{"type" => "object", "required" => required, "properties" => Map.new(fields, fn {key, type} -> {key, %{"type" => type}} end)}
           }}
        end
      )

    Process.put(:ci_catalog, catalog)

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, mr}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, jobs}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request", {:ok, mr}}
    ])

    {mr, pipeline, jobs}
  end

  defp collect(ctx, extra \\ []) do
    TicketWorkerRunner.collect_ci(ctx.store, "run", 33_747_681, Keyword.merge([connector: Connector, workspace: ctx.root, mcp_session: %{thread_id: "controller"}], extra))
  end

  test "collects on an existing controller session, normalizes provider IDs and rereads the current MR", ctx do
    prepare(ctx)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{"evidence" => %{"status" => "PASS"}, "observed_at" => observed, "snapshots" => snapshots}} = collect(ctx)
    assert {:ok, _, _} = DateTime.from_iso8601(observed)
    assert snapshots["pipeline"]["id"] == 99
    assert Process.get(:ci_reads) == []
    assert_received {:ci_read, "get_merge_request", %{"project_id" => "33747681", "merge_request_iid" => "42", "include_summaries" => false}}
    assert_received {:ci_read, "list_pipeline_jobs", %{"project_id" => "33747681", "pipeline_id" => "99", "page" => 1, "per_page" => 100, "include_retried" => false}}
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
  end

  test "missing provider selector is not treated as an absent pipeline or replaced by latest success", ctx do
    {mr, _, _} = prepare(ctx)
    Process.put(:ci_reads, [{"get_merge_request", {:ok, Map.delete(mr, "head_pipeline")}}])
    assert {:error, {:ci_tool_schema_unavailable, "list_merge_request_pipelines"}} = collect(ctx)
    refute_received {:ci_read, "get_pipeline", _}
  end

  test "explicit absent pipeline waits only after matching MR reread", ctx do
    {mr, _, _} = prepare(ctx)
    mr = Map.put(mr, "head_pipeline", nil)
    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_merge_request", {:ok, mr}}])
    assert {:ok, %{"evidence" => %{"status" => "WAIT"}}} = collect(ctx)
    refute_received {:ci_read, "list_pipeline_jobs", _}
  end

  test "remote head drift or local candidate drift during IO cannot be adopted", ctx do
    {mr, pipeline, jobs} = prepare(ctx)
    changed = put_in(mr, ["head_pipeline", "id"], "101")

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, mr}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, jobs}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request", {:ok, changed}}
    ])

    assert {:error, :ci_mr_changed_during_collection} = collect(ctx)
    prepare(ctx)

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, mr}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, jobs}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request",
       fn ->
         {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: String.duplicate("c", 40)})
         {:ok, mr}
       end}
    ])

    assert {:error, :ci_local_binding_changed} = collect(ctx)
  end

  test "rejects missing sessions and changed tool schemas before calls", ctx do
    prepare(ctx)
    assert {:error, :gitlab_catalog_session_required} = collect(ctx, mcp_session: nil)
    Process.put(:ci_catalog, put_in(Process.get(:ci_catalog), ["list_pipeline_jobs", "annotations", "readOnlyHint"], false))
    assert {:error, {:ci_tool_schema_unavailable, "list_pipeline_jobs"}} = collect(ctx)
    refute_received {:ci_read, _, _}
  end

  test "rejects oversized and malformed job collections", ctx do
    {mr, pipeline, [job]} = prepare(ctx)

    for result <- [List.duplicate(job, 101), [nil]] do
      Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:ok, result}}])
      assert {:error, :ci_jobs_limit_or_shape} = collect(ctx)
    end

    jobs = for id <- 1..100, do: Map.merge(job, %{"id" => Integer.to_string(id), "name" => "lint"})
    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:ok, jobs}}, {"list_pipeline_jobs", {:ok, [job]}}])
    assert {:error, :ci_jobs_limit_or_shape} = collect(ctx)
  end

  test "the second page establishes complete pagination, without filtered or retried jobs", ctx do
    {mr, pipeline, [job]} = prepare(ctx)
    jobs = for id <- 1..100, do: Map.merge(job, %{"id" => Integer.to_string(id), "name" => if(id == 1, do: "bazel", else: "lint")})

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, mr}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, jobs}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request", {:ok, mr}}
    ])

    assert {:ok, %{"evidence" => %{"status" => "PASS"}}} = collect(ctx)
    assert_received {:ci_read, "list_pipeline_jobs", %{"page" => 2}}
  end

  test "a provider page-size cap cannot hide a later failed job behind a short first page", ctx do
    {mr, pipeline, [job]} = prepare(ctx)
    failed = Map.merge(job, %{"id" => "101", "name" => "lint", "status" => "failed"})
    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:ok, [job]}}, {"list_pipeline_jobs", {:ok, [failed]}}])
    assert {:error, :ci_jobs_limit_or_shape} = collect(ctx)
    refute_received {:ci_read, "get_commit", _}
  end

  test "collector never broadens the connector's read-only tool allowlist", _ctx do
    assert {:error, :gitlab_tool_not_allowed} = GitLabMcpConnector.call_list("retry_pipeline_job", %{}, [])
  end

  test "second-page transport loss leaves the run unchanged and never assumes complete CI", ctx do
    {mr, pipeline, jobs} = prepare(ctx)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:ok, jobs}}, {"list_pipeline_jobs", {:error, :offline}}])
    assert {:error, :offline} = collect(ctx)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Process.get(:ci_reads) == []
    refute_received {:ci_read, "get_commit", _}
  end

  test "native integer IDs are retained without changing strict evidence types", ctx do
    {mr, pipeline, [job]} = prepare(ctx)
    pipeline = Map.merge(pipeline, %{"id" => 99, "project_id" => 33_747_681})
    mr = Map.merge(mr, %{"iid" => 42, "project_id" => 33_747_681, "assignees" => [%{"id" => 11_599_766}], "head_pipeline" => pipeline})
    job = Map.merge(job, %{"id" => 100, "pipeline" => Map.take(pipeline, ~w(id project_id sha))})

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, mr}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, [job]}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request", {:ok, mr}}
    ])

    assert {:ok, %{"evidence" => %{"status" => "PASS"}, "snapshots" => %{"jobs" => [%{"allow_failure" => false}]}}} = collect(ctx)
  end

  test "malformed provider IDs and non-list people cannot become delivery evidence", ctx do
    {mr, pipeline, jobs} = prepare(ctx)

    for value <- ["bad", "0", "-1", "99x", nil, false] do
      changed = put_in(mr, ["head_pipeline", "id"], value)
      Process.put(:ci_reads, [{"get_merge_request", {:ok, changed}}])
      assert {:error, :ci_pipeline_id_invalid} = collect(ctx)
      assert Process.get(:ci_reads) == []
    end

    for key <- ~w(assignees reviewers), value <- [nil, %{}, "invalid"] do
      changed = Map.put(mr, key, value)

      Process.put(:ci_reads, [
        {"get_merge_request", {:ok, changed}},
        {"get_pipeline", {:ok, pipeline}},
        {"list_pipeline_jobs", {:ok, jobs}},
        {"list_pipeline_jobs", {:ok, []}},
        {"get_merge_request", {:ok, changed}}
      ])

      assert {:error, _} = collect(ctx)
    end
  end

  test "schema drift, malformed selector and connector errors stop further reads", ctx do
    {mr, pipeline, _} = prepare(ctx)

    assert {:error, :ci_project_pin_required} = TicketWorkerRunner.collect_ci(ctx.store, "run", nil, connector: Connector)

    for catalog <- [nil, Map.delete(Process.get(:ci_catalog), "get_commit"), put_in(Process.get(:ci_catalog), ["get_commit", "inputSchema", "required"], ["unexpected"])] do
      Process.put(:ci_catalog, catalog)
      assert {:error, _} = collect(ctx)
    end

    prepare(ctx)

    for {response, expected} <- [
          {{:error, :offline}, :offline},
          {{:ok, []}, :gitlab_tool_result_invalid},
          {{:ok, Map.put(mr, "project_id", "123")}, :ci_mr_binding_mismatch},
          {{:ok, Map.put(mr, "head_pipeline", "invalid")}, :ci_pipeline_id_invalid},
          {{:ok, put_in(mr, ["head_pipeline", "id"], "099")}, :ci_pipeline_id_invalid}
        ] do
      Process.put(:ci_reads, [{"get_merge_request", response}])
      assert {:error, ^expected} = collect(ctx)
    end

    Process.put(:ci_reads, [{"get_merge_request", {:ok, mr}}, {"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:error, :offline}}])
    assert {:error, :offline} = collect(ctx)
  end

  test "merged-result readbacks require the exact source parent before producing PASS", ctx do
    {mr, pipeline, [job]} = prepare(ctx)
    merged_sha = String.duplicate("b", 40)
    pipeline = Map.merge(pipeline, %{"sha" => merged_sha, "ref" => "refs/merge-requests/42/merge"})
    mr = Map.put(mr, "head_pipeline", pipeline)
    job = put_in(job, ["pipeline", "sha"], merged_sha)
    commit = %{"id" => merged_sha, "parent_ids" => [String.duplicate("a", 40), ctx.sha]}

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, mr}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, [job]}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_commit", {:ok, commit}},
      {"get_merge_request", {:ok, mr}}
    ])

    assert {:ok, %{"evidence" => %{"status" => "PASS", "source_binding" => %{"kind" => "MERGE"}}}} = collect(ctx)
    assert_received {:ci_read, "get_commit", %{"project_id" => "33747681", "sha" => ^merged_sha, "stats" => false}}
  end
end
