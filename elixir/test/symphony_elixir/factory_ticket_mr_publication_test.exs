defmodule SymphonyElixir.FactoryTicketMrPublicationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChat, TicketMrOperation, TicketMrPublication}

  @tag timeout: 180_000
  test "a new publication creates one draft without a controller Desktop request" do
    ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture()
    opts = Keyword.merge(ctx.options, app_server: SymphonyElixir.TicketWorkerFixture.PublicationMcpServer, mcp_session: %{thread_id: "connector"})
    catalog = __DIR__ |> Path.join("../support/gitlab_mr_schemas.json") |> File.read!() |> Jason.decode!()
    Process.put(:mr_catalog, catalog)

    mr = %{
      "project_id" => 33_747_681,
      "iid" => 42,
      "web_url" => "https://gitlab.com/grailbio/grail/-/merge_requests/42",
      "source_branch" => ctx.publication_run["branch"],
      "target_branch" => "master",
      "sha" => ctx.publication_run["candidate_sha"],
      "state" => "opened",
      "draft" => true,
      "reviewers" => [],
      "assignees" => [%{"id" => 11_599_766}],
      "title" => "Draft: feat(PPL-123): fixture",
      "description" => "Synthetic content",
      "remove_source_branch" => false
    }

    Process.put(:mr_responses, [{:ok, %{"structuredContent" => []}}, {:ok, %{"structuredContent" => mr}}, {:ok, %{"structuredContent" => mr}}])
    before = Store.query!(ctx.store, "SELECT * FROM desktop_requests").rows

    assert {:ok, %{launches: [], events: events}} = SymphonyElixir.TicketWorkerFixture.publication_tick(ctx, opts)
    assert Enum.any?(events, &(&1.event == "TICKET_MR_PUBLISHED"))
    assert_receive {:mr_call, "create_merge_request", %{"draft" => true, "reviewer_ids" => [], "assignee_ids" => [11_599_766], "remove_source_branch" => false}}
    assert Store.query!(ctx.store, "SELECT * FROM desktop_requests").rows == before
    assert {:ok, published} = RunLedger.get(ctx.store, "run")
    assert {:ok, reopened} = Store.start_read_only(database: ctx.database)
    assert {:ok, %{status: "MR_ALREADY_PUBLISHED"}} = TicketMrPublication.step(reopened, "run", ctx.authorization, ctx.factory, ctx.root, "Synthetic content", opts)
    assert {:ok, ^published} = RunLedger.get(reopened, "run")
    GenServer.stop(reopened)
    assert {:ok, parent} = TicketChat.bound_for_run(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status='SUCCEEDED' WHERE target_kind='TICKET_CHAT' AND action='FOLLOWUP'")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status='THREAD_RECORDED',turn_id=NULL,output_json=NULL WHERE request_key=?", [parent["create_request_key"]])
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => mr}}])
    assert {:ok, receipt} = TicketMrOperation.current_delivery_receipt(ctx.store, "run", ctx.factory, opts)
    assert receipt.format == :direct_publication
    assert :ok = Store.transaction!(ctx.store, &TicketMrOperation.validate_delivery_receipt(&1, receipt, ctx.factory, opts))
    assert :ok = TicketMrOperation.validate_retained_mr_history(ctx.store, published)
    assert {:ok, retained} = TicketMrOperation.observe_retained_mr_history(ctx.store, published)
    assert :ok = Store.transaction!(ctx.store, &TicketMrOperation.recheck_retained_mr_history(&1, published, retained))
    {:ok, snapshot} = SymphonyElixir.TicketWorkerFixture.PublicationJiraReader.issue("PPL-123", store: ctx.store)

    Process.put(
      :publication_jira_snapshot,
      Map.update!(snapshot, "comments", fn comments -> Enum.with_index(comments) |> Enum.map(fn {entry, index} -> Map.put(entry, "id", "history-#{index}") end) end)
    )

    Process.put(:mr_responses, List.duplicate({:ok, %{"structuredContent" => mr}}, 25))

    final_opts =
      Keyword.merge(opts,
        workspace: ctx.root,
        gitlab_app_server: SymphonyElixir.TicketWorkerFixture.PublicationMcpServer,
        jira_reader: SymphonyElixir.TicketWorkerFixture.PublicationFinalJira,
        jira_connector: SymphonyElixir.TicketWorkerFixture.PublicationFinalJira,
        jira_session: fn _, callback -> callback.(%{thread_id: "final-jira"}) end
      )

    factory = Map.put(ctx.factory, :task_transport, "desktop_broker")
    assert {:ok, %{status: "REVIEW_READY", run: ready}} = SymphonyElixir.Factory.TicketJiraFinalization.finish(ctx.store, "run", factory, final_opts)
    assert ready["state"] == "READY_FOR_REVIEW"
    assert_receive {:publication_jira_write, "jira_add_comment", _}
    assert_receive {:publication_jira_write, "jira_update_factory_labels", _}
    refute_received {:publication_jira_write, _, _}
    assert_retained_rework_authorization(ctx, ready)
  end

  test "publication migration and readonly admission preserve schema54 atomically" do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..55, &[&1])
    assert Store.query!(ctx.store, "SELECT * FROM ticket_mr_publications").rows == []
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    GenServer.stop(reader)

    Store.query!(ctx.store, "DROP TRIGGER mr_publication_schema_rollback")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=55")
    Store.query!(ctx.store, "DROP TABLE ticket_mr_publications")
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    Store.query!(ctx.store, "CREATE TRIGGER fixture_fail55 BEFORE INSERT ON factory_schema_migrations WHEN NEW.version=55 BEGIN SELECT RAISE(ABORT,'fixture_fail55'); END")
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    runs = Store.query!(ctx.store, "SELECT * FROM runs").rows
    assert_raise Exqlite.Error, ~r/fixture_fail55/, fn -> Store.initialize(ctx.store) end
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == schema
    assert Store.query!(ctx.store, "SELECT * FROM runs").rows == runs
    Store.query!(ctx.store, "DROP TRIGGER fixture_fail55")
    assert :ok = Store.initialize(ctx.store)
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert Store.query!(reader, "SELECT * FROM runs").rows == runs
    GenServer.stop(reader)
  end

  test "lost create acknowledgement reconciles its original effect after candidate contract and cancellation changes" do
    ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture()
    {opts, mr} = remote_fixture(ctx)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => []}}, {:error, :mcp_tool_read_timeout}])
    assert {:ok, %{status: "MR_ISSUED_UNKNOWN"}} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Original content", opts)
    assert_receive {:mr_call, "create_merge_request", _}
    original = Store.one!(ctx.store, "SELECT * FROM ticket_mr_publications WHERE run_id='run'")
    assert original["phase"] == "ISSUED_UNKNOWN"
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "CANCELLED", candidate_sha: String.duplicate("b", 40), contract_sha256: String.duplicate("c", 64), spec_revision: 2})
    assert {:ok, held} = RunLedger.get(ctx.store, "run")
    Process.put(:mr_catalog, Map.delete(Process.get(:mr_catalog), "create_merge_request"))
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => [mr]}}, {:ok, %{"structuredContent" => mr}}])
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, %{status: "MR_PUBLICATION_SETTLED_HELD"}} = TicketMrPublication.step(reopened, "run", ctx.authorization, ctx.factory, ctx.root, "Changed content", opts)
      assert {:ok, ^held} = RunLedger.get(reopened, "run")
      assert {:ok, settled} = TicketMrPublication.get(reopened, original["operation_key"])
      assert settled["phase"] == "SUCCEEDED"
      assert settled["intent_json"] == original["intent_json"]
      assert Jason.decode!(settled["receipt_json"])["outcome"] == "RECONCILED_EXISTING"
      assert Jason.decode!(settled["receipt_json"])["mr"] == mr
      refute_received {:mr_call, "create_merge_request", _}
      assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM ticket_mr_publications")["count"] == 1
    after
      GenServer.stop(reopened)
    end
  end

  test "a compatible existing draft is reused unchanged without advertised creation capability" do
    ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture()
    {opts, mr} = remote_fixture(ctx)
    mr = Map.merge(mr, %{"title" => "Draft: human title", "description" => "The human's existing description", "assignees" => [%{"id" => 99}]})
    Process.put(:mr_catalog, Map.delete(Process.get(:mr_catalog), "create_merge_request"))
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => [mr]}}, {:ok, %{"structuredContent" => mr}}])
    assert {:ok, %{status: "MR_PUBLISHED"}} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Different generated description", opts)
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert {:ok, row} = TicketMrPublication.record_for_run(ctx.store, run)
    saved = Jason.decode!(row["receipt_json"])
    assert saved["outcome"] == "REUSED_EXISTING" and saved["content_origin"] == "OBSERVED_EXISTING"
    assert saved["mr"] == mr
    refute_received {:mr_call, "create_merge_request", _}
    refute_received {:mr_call, "update_merge_request", _}
  end

  test "direct preflight receipt survives restart and exact CI PASS admits an independent verifier" do
    ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture(%{ci_preflight: true})
    {opts, mr} = remote_fixture(ctx)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => []}}, {:ok, %{"structuredContent" => mr}}, {:ok, %{"structuredContent" => mr}}])
    assert {:ok, %{status: "MR_PUBLISHED", run: waiting}} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Preflight content", opts)
    assert_receive {:mr_call, "create_merge_request", _}
    assert waiting["state"] == "CI_WAITING"

    pipeline = %{
      "id" => "99",
      "project_id" => "33747681",
      "sha" => waiting["candidate_sha"],
      "ref" => "refs/merge-requests/42/head",
      "source" => "merge_request_event",
      "status" => "success",
      "web_url" => "https://gitlab.com/grailbio/grail/-/pipelines/99"
    }

    passing = Map.put(mr, "head_pipeline", pipeline)

    job = %{
      "id" => "100",
      "name" => "bazel",
      "status" => "success",
      "allow_failure" => false,
      "web_url" => "https://gitlab.com/grailbio/grail/-/jobs/100",
      "pipeline" => Map.take(pipeline, ~w(id project_id sha))
    }

    Process.put(:publication_ci_reads, [
      {"get_merge_request", {:ok, passing}},
      {"get_pipeline", {:ok, pipeline}},
      {"list_pipeline_jobs", {:ok, [job]}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request", {:ok, passing}}
    ])

    Process.put(:mr_responses, [{:ok, %{"structuredContent" => passing}}])
    opts = Keyword.put(opts, :connector, SymphonyElixir.TicketWorkerFixture.PublicationCiReader)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, %{status: "CI_PASS", run: verified}} = TicketMrOperation.adopt_ci(reopened, "run", ctx.authorization, ctx.factory, opts)
      assert verified["state"] == "VERIFYING" and verified["verifier_round"] == 1
      assert Process.get(:publication_ci_reads) == []
      context = %{ctx.worker_context | store: reopened}
      assert {:ok, %{status: "LAUNCHED", launch: launch}} = SymphonyElixir.Factory.Scheduler.ticket_step(context, "run", ctx.options)
      assert launch.task_key == "run:change-verifier:1"
      assert_receive {:factory_task_finished, _, {:ok, _}}, 60_000
      refute_received {:mr_call, "create_merge_request", _}
    after
      GenServer.stop(reopened)
    end
  end

  test "incomplete discovery incompatible capability and explicit approval denial issue no create" do
    ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture()
    {opts, mr} = remote_fixture(ctx)
    catalog = Process.get(:mr_catalog)
    Process.put(:mr_catalog, Map.delete(catalog, "create_merge_request"))
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => []}}])
    assert {:error, :gitlab_mr_capability_unavailable} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Content", opts)
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_mr_publications")["phase"] == "FAILED_BEFORE_ISSUANCE"
    refute_received {:mr_call, "create_merge_request", _}

    Process.put(:mr_catalog, put_in(catalog, ["create_merge_request", "inputSchema", "required"], ["unsupported_required"]))
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => []}}])
    assert {:error, :gitlab_mr_capability_incompatible} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Content", opts)
    Process.put(:mr_catalog, catalog)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => [mr, Map.put(mr, "iid", 43)]}}])
    assert {:error, :gitlab_mr_discovery_ambiguous} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Content", opts)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => [mr]}}, {:ok, %{"structuredContent" => Map.put(mr, "sha", String.duplicate("f", 40))}}])
    assert {:error, :gitlab_mr_remote_identity_mismatch} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Content", opts)
    refute_received {:mr_call, "create_merge_request", _}

    Process.put(:mr_responses, [
      fn ->
        assert {:ok, _} = SymphonyElixir.Factory.Control.pause(ctx.store, ctx.factory, ctx.factory.dispatcher_id)
        {:ok, %{"structuredContent" => []}}
      end
    ])

    assert {:error, :ticket_mr_control_unavailable} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Content", opts)
    refute_received {:mr_call, "create_merge_request", _}
    assert {:ok, _} = SymphonyElixir.Factory.Control.activate(ctx.store, ctx.factory, ctx.factory.dispatcher_id)
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => []}}, {:error, :mcp_tool_approval_required}])
    assert {:error, :mcp_tool_approval_required} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Content", opts)
    assert_receive {:mr_call, "create_merge_request", _}
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_mr_publications")["phase"] == "FAILED_BEFORE_ISSUANCE"
    assert {:ok, %{"mr_iid" => nil}} = RunLedger.get(ctx.store, "run")
    Process.put(:mr_responses, [])
    assert {:ok, %{status: "MR_PUBLICATION_NOT_ISSUED"}} = TicketMrPublication.step(ctx.store, "run", %{}, ctx.factory, ctx.root, "Content", Keyword.put(opts, :reconciliation_only, true))
    refute_received {:mr_call, "create_merge_request", _}
    refute_received {:mr_call, "update_merge_request", _}
  end

  defp assert_retained_rework_authorization(ctx, ready) do
    alias SymphonyElixir.Factory.{Scheduler, TicketChatCommands, TicketWorkerRunner}
    previous = Application.fetch_env(:symphony_elixir, :lifecycle_writer_mode)
    Application.put_env(:symphony_elixir, :lifecycle_writer_mode, :edited)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :lifecycle_writer_mode, value)
        :error -> Application.delete_env(:symphony_elixir, :lifecycle_writer_mode)
      end
    end)

    {:ok, chat} = TicketChat.bound_for_run(ctx.store, "run")
    body = "Please rework the current candidate"
    {:ok, command} = SymphonyElixir.TicketChatFixture.stage(ctx, "direct-publication-rework", body, [%{"operation" => "request_rework"}])
    native = SymphonyElixir.TicketChatFixture.native(Map.merge(ctx, %{cwd: chat["cwd"], chat: chat}), [body], command["command_key"])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    Process.put(:lifecycle_native, native)
    opts = Keyword.merge(ctx.options, jira_reader: SymphonyElixir.TicketWorkerFixture.PublicationFinalJira, ticket_chat_reader: SymphonyElixir.DesktopTicketLifecycleFixture.NativeReader)
    assert {:ok, %{launches: [launch]}} = SymphonyElixir.TicketWorkerFixture.publication_tick(ctx, opts)
    key = launch.task_key
    assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000
    assert {:ok, %{status: "ADOPTED", run: verifying}} = Scheduler.ticket_step(ctx.worker_context, "run", opts)
    assert verifying["state"] == "VERIFYING" and verifying["candidate_sha"] != ready["candidate_sha"]
    assert {:ok, %{status: "LAUNCHED", launch: review}} = Scheduler.ticket_step(ctx.worker_context, "run", opts)
    assert_receive {:factory_task_finished, _, {:ok, _}}, 60_000
    assert review.task_key != key
    assert {:ok, %{status: "ADOPTED", run: pushing}} = Scheduler.ticket_step(ctx.worker_context, "run", opts)
    assert pushing["state"] == "PUSHING"
    snapshot = Process.get(:publication_jira_snapshot)
    assert "ai-review" in snapshot["labels"] and "ai-running" not in snapshot["labels"]
    assert {:ok, authorization} = TicketWorkerRunner.delivery_authorization(ctx.store, pushing, snapshot, DateTime.utc_now(), opts)
    assert authorization["delivery_review"] == true
    assert {:ok, admission} = TicketWorkerRunner.delivery_admission(ctx.store, pushing, authorization, opts)
    assert admission.retained_mr_history.record.format == :direct_publication
    assert admission.retained_mr_history.prior["candidate_sha"] == ready["candidate_sha"]
    assert {:ok, retained} = TicketWorkerRunner.retained_review_preimage(ctx.store, pushing)
    assert {:ok, :direct_publication} = TicketMrPublication.receipt_format(ctx.store, retained)
    assert {:ok, :legacy} = TicketMrPublication.receipt_format(ctx.store, pushing)
  end

  test "human MR state and unsafe or unknown branch removal are preserved without any update" do
    ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture()
    {opts, mr} = remote_fixture(ctx)
    human = Map.merge(mr, %{"draft" => false, "title" => "Human-ready title", "reviewers" => [%{"id" => "9"}]})
    Process.put(:mr_catalog, Map.delete(Process.get(:mr_catalog), "create_merge_request"))
    Process.put(:mr_responses, [{:ok, %{"structuredContent" => [human]}}, {:ok, %{"structuredContent" => human}}])
    assert {:ok, %{status: "MR_HUMAN_STATE_PRESERVED"}} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Never overwrite", opts)
    saved = Store.one!(ctx.store, "SELECT * FROM ticket_mr_publications")
    assert Jason.decode!(saved["receipt_json"])["outcome"] == "PRESERVED_HUMAN_STATE"
    assert Jason.decode!(saved["receipt_json"])["mr"] == human

    for observed <- [
          Map.put(mr, "state", "closed"),
          Map.put(mr, "state", "merged"),
          Map.put(mr, "reviewers", [%{"id" => "9"}]),
          Map.put(mr, "remove_source_branch", true),
          Map.delete(mr, "remove_source_branch")
        ] do
      Process.put(:mr_responses, [{:ok, %{"structuredContent" => observed}}])
      assert {:ok, %{status: "MR_HUMAN_STATE_PRESERVED"}} = TicketMrPublication.step(ctx.store, "run", ctx.authorization, ctx.factory, ctx.root, "Never overwrite", opts)
      assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_publications") == saved
    end

    assert {:ok, %{"mr_iid" => nil}} = RunLedger.get(ctx.store, "run")
    refute_received {:mr_call, "create_merge_request", _}
    refute_received {:mr_call, "update_merge_request", _}
  end

  defp remote_fixture(ctx) do
    catalog = __DIR__ |> Path.join("../support/gitlab_mr_schemas.json") |> File.read!() |> Jason.decode!()
    Process.put(:mr_catalog, catalog)
    opts = Keyword.merge(ctx.options, app_server: SymphonyElixir.TicketWorkerFixture.PublicationMcpServer, mcp_session: %{thread_id: "connector"})

    mr = %{
      "project_id" => 33_747_681,
      "iid" => 42,
      "web_url" => "https://gitlab.com/grailbio/grail/-/merge_requests/42",
      "source_branch" => ctx.publication_run["branch"],
      "target_branch" => "master",
      "sha" => ctx.publication_run["candidate_sha"],
      "state" => "opened",
      "draft" => true,
      "reviewers" => [],
      "assignees" => [%{"id" => 11_599_766}],
      "title" => "Draft: feat(PPL-123): fixture",
      "description" => "Synthetic content",
      "remove_source_branch" => false
    }

    {opts, mr}
  end
end
