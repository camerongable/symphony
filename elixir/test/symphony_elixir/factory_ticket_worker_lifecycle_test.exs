defmodule SymphonyElixir.FactoryTicketWorkerLifecycleTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 180_000
  import SymphonyElixir.TicketWorkerFixture

  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.Factory.{
    Contract,
    Control,
    DesktopRequest,
    DesktopStageRunner,
    DesktopToolArgs,
    RunLedger,
    Scheduler,
    StageSchemas,
    Store,
    TaskLedger,
    TicketAmendmentCritic,
    TicketAmendmentJiraOperation,
    TicketChat,
    TicketChatCommands,
    TicketCheckout,
    TicketCheckoutIO,
    TicketContext,
    TicketContractAmendment,
    TicketJiraFinalization,
    TicketJiraJournal,
    TicketMrOperation,
    TicketPush,
    TicketPushIO,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkspaceAccess,
    Worktree
  }

  setup :setup_fixture

  test "worker fixture registers the default ticket run", ctx do
    assert {:ok, _} = RunLedger.get(ctx.store, "run")
  end

  @tag unregistered: true
  test "worker fixture skips ticket registration only when explicitly requested", ctx do
    assert RunLedger.list(ctx.store) == []
  end

  test "Jira finalization rejects wrong stages and missing runs without preparing ownership", ctx do
    before = Enum.map(~w(runs workspace_access ticket_jira_effects), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    opts = [jira_session: fn _cwd, _callback -> flunk("a rejected run must not open a Jira session") end]
    assert {:error, :ticket_jira_recovery_not_admitted} = TicketJiraFinalization.reconcile(ctx.store, "run", %{}, opts)
    assert {:error, :ticket_jira_finalization_not_admitted} = TicketJiraFinalization.finish(ctx.store, "run", %{}, opts)
    assert {:error, _} = TicketJiraFinalization.finish(ctx.store, "missing", %{}, opts)
    assert Enum.map(~w(runs workspace_access ticket_jira_effects), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == before
  end

  test "MR handoff rejects wrong stages and incomplete authority without requests or reservations", ctx do
    bind_parent(ctx)
    tables = ~w(runs desktop_requests workspace_access ticket_mr_claims)
    before = Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    assert {:error, :ticket_mr_stage_invalid} = TicketMrOperation.adopt_result(ctx.store, "run", %{}, %{}, [])
    assert {:error, :ticket_mr_recorded_receipt_unproven} = TicketMrOperation.current_delivery_receipt(ctx.store, "run", %{}, [])

    for authority <- [nil, %{}, %{factory: %{}}] do
      assert {:error, :ticket_mr_claim_authority_required} = TicketMrOperation.claim_receipt(ctx.store, %{}, authority, [])
    end

    for receipt <- [nil, %{}, %{run: %{}}] do
      assert {:error, :ticket_mr_readback_unproven} = TicketMrOperation.validate_delivery_receipt(ctx.store, receipt, %{}, [])
    end

    assert {:error, :ticket_mr_binding_invalid} = TicketMrOperation.request_key(nil)
    assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == before
  end

  defmodule JiraReader do
    def search(_jql, _opts), do: {:ok, []}

    def issue(_key, opts) do
      {:ok, run} = RunLedger.get(opts[:store], "run")
      snapshot = Jason.decode!(run["snapshot_json"])
      marker = Process.get(:mr_jira_block_after_runtime)
      labels = if is_binary(marker) and File.exists?(marker), do: ["ai-blocked", "repo-grail"], else: ["ai-running", "repo-grail"]
      {:ok, Map.merge(snapshot, %{"labels" => labels, "status" => "In Dev"})}
    end
  end

  defmodule ParentPollJiraReader do
    def search(_jql, _opts), do: {:ok, []}
    def issue(key, opts), do: JiraReader.issue(key, opts)
  end

  defmodule BlockedJiraReader do
    def issue(key, opts) do
      {:ok, snapshot} = JiraReader.issue(key, opts)
      {:ok, Map.put(snapshot, "labels", ["ai-blocked", "repo-grail"])}
    end
  end

  defmodule AmendmentJiraReader do
    def issue("PPL-123", opts) do
      if opts[:mcp_session] != %{thread_id: "amendment-jira-fixture"}, do: raise("missing amendment Jira session")
      {:ok, Process.get(:blocked_amendment_jira_snapshot)}
    end
  end

  defmodule AmendmentJiraConnector do
    def validate_call("jira_add_comment", %{"issue_key" => "PPL-123", "body" => body}, opts) do
      if opts[:mcp_session] != %{thread_id: "amendment-jira-fixture"}, do: raise("missing amendment Jira session")
      if body != Process.get(:blocked_amendment_expected_body), do: raise("wrong amendment Jira comment")
      :ok
    end

    def call("jira_add_comment", %{"body" => body}, _opts) do
      send(self(), {:blocked_amendment_jira_write, body})
      snapshot = Process.get(:blocked_amendment_jira_snapshot)

      id =
        if body == Process.get(:blocked_amendment_draft_body),
          do: Process.get(:blocked_amendment_draft_id) || "blocked-draft",
          else: Process.get(:blocked_amendment_authorization_id) || "blocked-authorization"

      comment = %{"id" => id, "text" => body}
      Process.put(:blocked_amendment_jira_snapshot, snapshot |> Map.update!("comments", &(&1 ++ [comment])) |> Map.put("updated", Process.get(:blocked_amendment_updated) || "2026-10-07T12:01:00Z"))
      {:ok, %{"comment_id" => id}}
    end
  end

  defmodule AmendmentCriticAppServer do
    alias SymphonyElixir.Codex.AppServer
    alias SymphonyElixir.Tracker.Issue

    def start_session(workspace, _opts) do
      {:ok,
       %{
         thread_id: "blocked-critic-thread",
         worker_policy: AppServer.worker_policy("REVIEW", workspace),
         metadata: %{codex_app_server_pid: "34567"},
         worker_invocation: String.duplicate("b", 64),
         workspace: workspace
       }}
    end

    def run_turn(session, _prompt, %Issue{}, opts) do
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: "blocked-critic-turn"})
      item = %{"type" => "agentMessage", "id" => "blocked-critic-item", "text" => Jason.encode!(%{"status" => "PASS", "findings" => [], "required_questions" => []})}
      opts[:on_message].(%{payload: %{"method" => "item/completed", "params" => %{"threadId" => session.thread_id, "turnId" => "blocked-critic-turn", "item" => item}}})
      {:ok, %{turn_id: "blocked-critic-turn"}}
    end

    def stop_session(session) do
      {:ok,
       %{
         "transport" => "owned_app_server",
         "thread_id" => session.thread_id,
         "pid" => "34567",
         "invocation_nonce" => session.worker_invocation,
         "cwd" => session.workspace,
         "exit_status" => 0
       }}
    end
  end

  defmodule ParentNativeReader do
    def read_native_thread(thread_id, opts) do
      if thread_id != Process.get(:ticket_chat_parent_thread) or opts[:workspace] != Process.get(:ticket_chat_parent_workspace),
        do: raise("parent native read target changed")

      case Process.get(:ticket_chat_parent_readback) do
        {:error, reason} -> {:error, reason}
        readback when is_map(readback) -> {:ok, readback}
        _ -> {:error, :parent_native_readback_missing}
      end
    end
  end

  defmodule ForbiddenJiraConnector do
    def validate_call(_tool, _args, _opts), do: raise("blocked writer disposition must not call Jira")
    def call(_tool, _args, _opts), do: raise("blocked writer disposition must not call Jira")
  end

  defmodule CheckoutDriftReader do
    def issue(key, opts) do
      Store.query!(opts[:store], "UPDATE ticket_checkout_intents SET owner_nonce = ? WHERE run_id = 'run'", [String.duplicate("f", 64)])
      JiraReader.issue(key, opts)
    end
  end

  defmodule PushDriftReader do
    def issue(key, opts) do
      {:ok, run} = RunLedger.get(opts[:store], "run")
      intent = run["candidate_handoff"] |> Jason.decode!() |> Map.put("owner_nonce", String.duplicate("f", 64))
      Store.query!(opts[:store], "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [Jason.encode!(intent)])
      JiraReader.issue(key, opts)
    end
  end

  defmodule FinalJiraReader do
    def search(_jql, _opts), do: {:ok, []}

    def issue(_key, _opts) do
      if Process.delete(:final_fail_read_once), do: {:error, :jira_readback_unavailable}, else: {:ok, Process.get(:final_jira_snapshot)}
    end
  end

  defmodule FinalJiraConnector do
    def validate_call(_tool, _args, opts) do
      assert opts[:mcp_session] == %{thread_id: "final-jira"}
      :ok
    end

    def call(tool, args, _opts) do
      Process.put(:final_jira_calls, Process.get(:final_jira_calls) ++ [{tool, args}])
      snapshot = Process.get(:final_jira_snapshot)

      case {tool, Process.get(:final_jira_mode)} do
        {"jira_add_comment", :lost_before_apply} ->
          {:error, :timeout}

        {"jira_add_comment", _} ->
          comments = snapshot["comments"] ++ [%{"id" => "delivery-comment", "text" => args["body"]}]
          Process.put(:final_jira_snapshot, Map.put(snapshot, "comments", comments))
          {:error, :lost_ack_after_apply}

        {"jira_update_factory_labels", _} ->
          labels = Enum.uniq((snapshot["labels"] -- args["remove_labels"]) ++ args["add_labels"])
          Process.put(:final_jira_snapshot, Map.put(snapshot, "labels", labels))
          if Process.get(:final_jira_mode) == :lost_label_readback, do: Process.put(:final_fail_read_once, true)
          {:error, :lost_ack_after_apply}
      end
    end
  end

  defmodule MrReader do
    def catalog(opts) do
      if Path.basename(Keyword.fetch!(opts, :workspace)) != "control", do: raise("MR read is not bound to the controller directory")
      name = "get_merge_request"
      properties = Map.new(~w(project_id merge_request_iid), &{&1, %{"type" => "string"}}) |> Map.put("include_summaries", %{"type" => "boolean"})

      {:ok,
       %{name => %{"name" => name, "annotations" => %{"readOnlyHint" => true}, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => ~w(project_id merge_request_iid)}}}}
    end

    def call("get_merge_request", arguments, _opts) do
      send(self(), {:mr_read, arguments})
      [reply | rest] = Process.get(:mr_reads)
      Process.put(:mr_reads, rest)
      if is_function(reply, 0), do: reply.(), else: {:ok, reply}
    end
  end

  defmodule CiReader do
    def catalog(_opts) do
      specs = [
        {"get_merge_request", %{"project_id" => "string", "merge_request_iid" => "string", "include_summaries" => "boolean"}, ~w(project_id merge_request_iid)},
        {"get_pipeline", %{"project_id" => "string", "pipeline_id" => "string"}, ~w(project_id pipeline_id)},
        {"list_pipeline_jobs", %{"project_id" => "string", "pipeline_id" => "string", "page" => "number", "per_page" => "number", "include_retried" => "boolean"}, ~w(project_id pipeline_id)},
        {"get_commit", %{"project_id" => "string", "sha" => "string", "stats" => "boolean"}, ~w(project_id sha)}
      ]

      {:ok,
       Map.new(specs, fn {name, fields, required} ->
         {name,
          %{
            "name" => name,
            "annotations" => %{"readOnlyHint" => true},
            "inputSchema" => %{"type" => "object", "required" => required, "properties" => Map.new(fields, fn {key, type} -> {key, %{"type" => type}} end)}
          }}
       end)}
    end

    def call(tool, _args, opts) do
      assert Path.basename(opts[:workspace]) == "control"
      send(self(), {:ci_read, tool})
      [{^tool, value} | rest] = Process.get(:ci_reads)
      Process.put(:ci_reads, rest)
      if is_function(value, 0), do: value.(), else: value
    end

    def call_list(tool, args, opts), do: call(tool, args, opts)
  end

  defmodule MrNativeReader do
    def read_native_thread(thread, opts) do
      assert thread == "controller-thread"
      assert opts[:include_turns] == false and opts[:include_latest_turn] == true and opts[:include_queue] == true
      assert Path.basename(opts[:workspace]) == "control"
      {:ok, Process.get(:mr_native)}
    end
  end

  alias SymphonyElixir.DesktopTicketLifecycleFixture.WorkerServer

  defp controller(ctx) do
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)
    bind_parent(ctx)
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    Store.query!(ctx.store, "DELETE FROM factory_tasks WHERE task_key = 'writer'")
    supervisor = start_supervised!(Task.Supervisor)

    policy = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"fast" => "gpt-6-luna", "deep" => "gpt-6.1-sol"}},
      "roles" =>
        Map.new(~w(feature-planner feature-writer change-verifier), fn role ->
          {role, %{"provider" => "codex", "model_class" => if(role == "change-verifier", do: "deep", else: "fast"), "reasoning_effort" => "medium"}}
        end)
    }

    context = %{
      store: ctx.store,
      task_supervisor: supervisor,
      recipient: self(),
      workspace_root: Path.join(ctx.root, "workspaces"),
      factory: %{
        models: policy,
        maximum_implementation_iterations: 20,
        maximum_code_repair_rounds: 2,
        scope: "assigned-jira-work",
        dispatcher_id: "fixture-dispatcher",
        queue: %{"assignee" => "currentUser()", "statuses" => ["READY"], "factory_labels" => ["ai-ready"], "projects" => [], "epics" => []},
        repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master", "route_labels" => ["repo-grail"]}}
      },
      ticket_options: []
    }

    jira_scope = fn _workspace, callback -> callback.(%{thread_id: "jira-fixture"}) end
    options = Keyword.merge(opts(ctx), workspace_root: Path.join(ctx.root, "workspaces"), app_server: WorkerServer, jira_reader: JiraReader, jira_session: jira_scope)
    {context, options}
  end

  defp parent_reader_options(chat, readback) do
    Process.put(:ticket_chat_parent_thread, chat["thread_id"])
    Process.put(:ticket_chat_parent_workspace, chat["cwd"])
    Process.put(:ticket_chat_parent_readback, readback)
    {:ok, [ticket_chat_reader: ParentNativeReader]}
  end

  defp empty_parent_reader_options(store, run_id) do
    with {:ok, chat} <- TicketChat.ready_for_run(store, run_id) do
      empty_history = %{"id" => chat["thread_id"], "cwd" => chat["cwd"], "projectId" => nil, "turns" => []}
      parent_reader_options(chat, empty_history)
    end
  end

  defp normal_poll(context, options, parent_options) do
    {context, tick_options} = tick_controller(context, Keyword.merge(options, parent_options))
    Scheduler.tick(context, Keyword.put(tick_options, :jira_reader, ParentPollJiraReader))
  end

  defp complete_stage(context, options) do
    finish_worker(context, options)
    assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", options)
    run
  end

  defp finish_worker(context, options) do
    assert {:ok, %{status: "LAUNCHED", launch: launch}} = Scheduler.ticket_step(context, "run", options)
    key = launch.task_key
    assert_receive {:factory_task_started, ^key, _}, 15_000
    assert_receive {:factory_task_finished, ^key, finished}, 60_000
    assert {:ok, _} = finished
    [[request]] = Store.query!(context.store, "SELECT request_key FROM worker_evidence WHERE task_key = ? AND status != 'CONSUMED'", [key]).rows
    request
  end

  test "planner, resumed writer slices and blind verifier share one checkout and adopt exactly once", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "PLANNING", candidate_sha: nil})
    planned = complete_stage(context, options)
    assert planned["state"] == "ADMITTING_WRITER"
    assert {:ok, %{status: "WRITER_ADMITTED", model_invoked: false, run: admitted}} = Scheduler.ticket_step(context, "run", options)
    assert admitted["state"] == "WRITING" and admitted["worktree"] == ctx.path
    first = complete_stage(context, options)
    assert first["state"] == "WRITING" and first["implementation_iteration"] == 1
    second = complete_stage(context, options)
    assert second["state"] == "VERIFYING" and second["implementation_iteration"] == 2
    verified = complete_stage(context, options)
    assert verified["state"] == "PUSHING"
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == "2"
    assert Store.query!(ctx.store, "SELECT DISTINCT workspace FROM factory_tasks").rows == [[ctx.path]]
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TASK'")["count"] == 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE status = 'CONSUMED'")["count"] == 4
    assert {:ok, %{"status" => "CONSUMED", "thread_id" => writer_thread}} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert Store.query!(ctx.store, "SELECT DISTINCT thread_id FROM worker_evidence WHERE task_key = 'run:feature-writer'").rows == [[writer_thread]]
    refute_receive {:factory_task_started, _, _}
  end

  test "low capacity rolls back new writer task and reservation before any turn", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    assert {:error, :insufficient_writer_capacity} = Scheduler.ticket_step(context, "run", Keyword.put(options, :free_bytes, 19_999_999_999))
    assert {:error, :unknown_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access")["count"] == 0
    refute_receive {:factory_task_started, _, _}
  end

  test "writer completion without edits preserves the existing candidate and does not create another commit", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    first = complete_stage(context, options)
    assert first["state"] == "WRITING"
    candidate = first["candidate_sha"]
    assert is_binary(candidate)
    commits = git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"])
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "no-op"})
    request = finish_worker(context, options)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    access = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows
    base_ref = "refs/remotes/origin/" <> before["base_branch"]
    base_sha = git(ctx.path, ["rev-parse", base_ref]) |> String.trim()
    git(ctx.path, ["update-ref", base_ref, candidate, base_sha])

    try do
      assert {:error, :writer_candidate_mismatch} = TicketWorkerRunner.adoption(ctx.store, request)
      assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
      assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
      assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows == access
      assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) == commits
    after
      git(ctx.path, ["update-ref", base_ref, base_sha, candidate])
    end

    assert {:ok, %{status: "ADOPTED", run: complete}} = Scheduler.ticket_step(context, "run", options)
    assert complete["state"] == "VERIFYING"
    assert complete["candidate_sha"] == candidate
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) == commits
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
  end

  test "blocked writer disposition is stable and preserves the recorded result, candidate and dirty source", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    request = finish_worker(context, options)
    context = Map.put(context, :jira_connector, ForbiddenJiraConnector)
    {:ok, before_run} = RunLedger.get(ctx.store, "run")
    {:ok, before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    {:ok, evidence} = WorkerEvidence.get(ctx.store, request)
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows
    commits = git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim()

    # These are explicit fixture edits made after the synthetic result, not worker-authored output or native provenance.
    File.write!(Path.join(ctx.path, "fixture.txt"), "fixture dirty state\n")
    File.write!(Path.join(ctx.path, "untracked-blocked-fixture.txt"), "fixture untracked state\n")

    assert {:ok, %{status: "BLOCKED", blockers: ["Fixture decision unresolved"], request_key: ^request, model_invoked: false} = first} =
             Scheduler.ticket_step(context, "run", options)

    assert {:ok, %{status: "BLOCKED", blockers: ["Fixture decision unresolved"], request_key: ^request, model_invoked: false} = second} =
             Scheduler.ticket_step(context, "run", options)

    assert first.blockers == second.blockers and first.next_action == second.next_action

    disposition_events = Store.query!(ctx.store, "SELECT id, payload_json FROM events WHERE run_id = 'run' AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'").rows
    assert [[event_id, raw_payload]] = disposition_events
    payload = Jason.decode!(raw_payload)
    assert payload["request_key"] == request
    assert payload["output_json"] == evidence["output_json"]
    assert payload["output_sha256"] == evidence["output_sha256"]
    assert :crypto.hash(:sha256, payload["output_json"]) |> Base.encode16(case: :lower) == payload["output_sha256"]
    assert {:ok, ^evidence} = WorkerEvidence.get(ctx.store, request)
    assert {:ok, ^before_run} = RunLedger.get(ctx.store, "run")
    assert {:ok, ^before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows == access_before
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_questions WHERE run_id = 'run'")["count"] == 0
    assert String.trim(git(ctx.path, ["rev-parse", "HEAD"])) == ctx.sha
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == commits
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "fixture dirty state\n"
    assert File.read!(Path.join(ctx.path, "untracked-blocked-fixture.txt")) == "fixture untracked state\n"
    assert {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert packet.writer_disposition.status == "BLOCKED"
    assert packet.writer_disposition.request_key == request
    assert packet.writer_disposition.blockers == payload["blockers"]
    assert packet.summary =~ "BLOCKED"
    assert packet.next_action == payload["next_action"]
    assert event_id > 0
    Store.query!(ctx.store, "UPDATE runs SET implementation_iteration = 1 WHERE run_id = 'run'")
    assert {:ok, stale_packet} = TicketContext.context(ctx.store, "run")
    assert stale_packet.writer_disposition == nil
    refute stale_packet.summary =~ "BLOCKED"
    refute_receive {:factory_task_started, _, _}
  end

  test "an authorized held amendment explicitly resumes once with historical proof after reopen", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    {:ok, starting_run} = RunLedger.get(ctx.store, "run")
    source = normalized_amendment_source(starting_run["snapshot_json"])
    {:ok, _} = RunLedger.update(ctx.store, "run", %{snapshot_json: Jason.encode!(source)})
    request = finish_worker(context, options)
    assert {:ok, %{status: "BLOCKED", request_key: ^request}} = Scheduler.ticket_step(context, "run", options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    amendment_state = fn store -> blocked_amendment_complete_state(store, chat["chat_key"]) end
    git_dir = String.trim(git(ctx.path, ["rev-parse", "--absolute-git-dir"]))

    checkout_state = fn ->
      %{
        source: File.read!(Path.join(ctx.path, "fixture.txt")),
        index: File.read!(Path.join(git_dir, "index")),
        head: String.trim(git(ctx.path, ["rev-parse", "HEAD"])),
        branch: String.trim(git(ctx.path, ["branch", "--show-current"]))
      }
    end

    markdown = "A confirmed contract\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "blocked-amendment", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    native = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    {:ok, run} = RunLedger.get(ctx.store, "run")

    controller_context = %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run["spec_revision"], "contract_sha256" => run["contract_sha256"], "candidate_sha" => run["candidate_sha"]}
    }

    event = Store.one!(ctx.store, "SELECT id, payload_json FROM events WHERE run_id = 'run' AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'")
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request])

    protected = blocked_amendment_protected_rows(ctx.store, chat["chat_key"])

    Store.query!(ctx.store, "UPDATE events SET payload_json = '{}' WHERE id = ?", [event["id"]])
    assert {:error, :stopped_blocked_writer_not_proven} = TicketContractAmendment.reserve(ctx.store, command["command_key"], controller_context)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
    Store.query!(ctx.store, "UPDATE events SET payload_json = ? WHERE id = ?", [event["payload_json"], event["id"]])

    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json = '{}' WHERE request_key = ?", [request])
    assert {:error, :stopped_blocked_writer_not_proven} = TicketContractAmendment.reserve(ctx.store, command["command_key"], controller_context)
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json = ? WHERE request_key = ?", [evidence["owner_stop_json"], request])

    assert {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], controller_context)
    predecessor = Jason.decode!(amendment["predecessor_json"])
    assert predecessor["request_key"] == request
    assert predecessor["output_sha256"] == evidence["output_sha256"]
    assert predecessor["task_key"] == evidence["task_key"]
    assert amendment["active_owner"] == 1

    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == protected

    refute_receive {:factory_task_started, _, _}

    prior_run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    prior_task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'")
    prior_evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request])
    prior_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]])
    control_workspace = Path.join(ctx.root, "control")
    File.mkdir_p!(control_workspace)
    Process.put(:blocked_amendment_jira_snapshot, source)
    draft_body = Contract.draft_comment(Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"]))
    Process.put(:blocked_amendment_draft_body, draft_body)
    Process.put(:blocked_amendment_expected_body, draft_body)

    jira_opts = [
      workspace: control_workspace,
      jira_session: fn _workspace, callback -> callback.(%{thread_id: "amendment-jira-fixture"}) end,
      jira_reader: AmendmentJiraReader,
      jira_connector: AmendmentJiraConnector
    ]

    assert {:ok, published} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], controller_context, jira_opts)
    policy = critic_model_policy()
    assert {:ok, _} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], controller_context, published["readback_json"], policy)

    assert {:ok, critic} =
             TicketAmendmentCritic.execute(
               ctx.store,
               command["command_key"],
               controller_context,
               control_workspace,
               policy,
               app_server: AmendmentCriticAppServer
             )

    proposed = Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"])
    output_sha = :crypto.hash(:sha256, Jason.encode!(critic["output"])) |> Base.encode16(case: :lower)
    auth_body = Contract.automatic_authorization_marker(proposed, critic["task_key"], output_sha)
    Process.put(:blocked_amendment_expected_body, auth_body)
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], controller_context, policy, jira_opts)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER reject_blocked_amendment_terminal BEFORE UPDATE OF phase ON ticket_contract_amendments WHEN NEW.phase = 'APPLIED' BEGIN SELECT RAISE(ABORT, 'blocked application rollback'); END"
    )

    assert_raise Exqlite.Error, ~r/blocked application rollback/, fn ->
      TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], controller_context, policy)
    end

    Store.query!(ctx.store, "DROP TRIGGER reject_blocked_amendment_terminal")
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == prior_run
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access
    assert Store.one!(ctx.store, "SELECT phase, active_owner FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == %{"phase" => "RESERVED", "active_owner" => 1}
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == %{"status" => "ACCEPTED"}
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])

    reserved_before_probe = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    predecessor_json_before_probe = reserved_before_probe["predecessor_json"]
    state_before_probe = amendment_state.(ctx.store)
    checkout_before_probe = checkout_state.()
    git_status_before_probe = git(ctx.path, ["status", "--porcelain=v1"])

    try do
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET predecessor_json = ? WHERE command_key = ?", [predecessor_json_before_probe <> "\n", command["command_key"]])
      assert {:ok, %{"phase" => "RESERVED", "active_owner" => 1}} = TicketContractAmendment.get(ctx.store, command["command_key"])
      fault_state = amendment_state.(ctx.store)
      fault_checkout = checkout_state.()
      fault_git_status = git(ctx.path, ["status", "--porcelain=v1"])

      assert {:error, :amendment_predecessor_changed} =
               TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], controller_context, policy)

      assert amendment_state.(ctx.store) == fault_state
      assert checkout_state.() == fault_checkout
      assert git(ctx.path, ["status", "--porcelain=v1"]) == fault_git_status
    after
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET predecessor_json = ? WHERE command_key = ?", [predecessor_json_before_probe, command["command_key"]])
    end

    assert amendment_state.(ctx.store) == state_before_probe
    assert checkout_state.() == checkout_before_probe
    assert git(ctx.path, ["status", "--porcelain=v1"]) == git_status_before_probe
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == reserved_before_probe
    assert {:ok, ^reserved_before_probe} = TicketContractAmendment.get(ctx.store, command["command_key"])

    assert {:ok, receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], controller_context, policy)
    assert receipt["application_kind"] == "BLOCKED_WRITER_HELD"
    held = Jason.decode!(receipt["blocked_predecessor_json"])
    assert held["request_key"] == request
    assert held["output_sha256"] == predecessor["output_sha256"]

    first_amendment_row = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    original_predecessor_json = first_amendment_row["predecessor_json"]
    predecessor_record = Jason.decode!(original_predecessor_json)
    event_reference = predecessor_record["artifact_ref"] |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert event_reference["kind"] == "event"
    corrupted_reference = event_reference |> Map.put("id", %{}) |> Jason.encode!() |> Base.url_encode64(padding: false)
    corrupted_predecessor = predecessor_record |> Map.put("artifact_ref", corrupted_reference) |> Jason.encode!()
    first_probe_state = amendment_state.(ctx.store)
    first_probe_checkout = checkout_state.()

    try do
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET predecessor_json = ? WHERE command_key = ?", [corrupted_predecessor, command["command_key"]])
      fault_state = amendment_state.(ctx.store)
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert amendment_state.(ctx.store) == fault_state
    after
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET predecessor_json = ? WHERE command_key = ?", [original_predecessor_json, command["command_key"]])
    end

    assert amendment_state.(ctx.store) == first_probe_state
    assert checkout_state.() == first_probe_checkout
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])

    applied_run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    assert applied_run["state"] == "WRITING"
    assert applied_run["spec_revision"] == 2
    assert applied_run["candidate_sha"] == prior_run["candidate_sha"]
    assert applied_run["worktree"] == prior_run["worktree"]
    assert {:error, :ticket_delivery_review_history_absent} = TicketWorkerRunner.retained_review_preimage(ctx.store, applied_run)
    {:ok, applied_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = '{}' WHERE command_key = ?", [command["command_key"]])

    try do
      assert {:error, :ticket_delivery_mr_history_unproven} = TicketWorkerRunner.retained_review_preimage(ctx.store, applied_run)
    after
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = ? WHERE command_key = ?", [applied_amendment["receipt_json"], command["command_key"]])
    end

    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access

    source_r2 = Jason.decode!(applied_run["snapshot_json"])
    markdown_r3 = "A second confirmed contract\n\n## Manual Validation\n- Required: no"
    body_r3 = "Revise the contract:\n" <> markdown_r3

    {:ok, staged_r3} =
      SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "blocked-amendment-r3", body_r3, [
        %{"operation" => "propose_contract_revision", "markdown" => markdown_r3}
      ])

    native_r3 =
      SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, ["earlier input", body_r3])
      |> Map.update!("turns", fn turns -> [List.last(turns)] end)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native_r3)
    command_r3 = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged_r3["command_key"]])
    {:ok, run_r2} = RunLedger.get(ctx.store, "run")

    controller_context_r2 = %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run_r2["spec_revision"], "contract_sha256" => run_r2["contract_sha256"], "candidate_sha" => run_r2["candidate_sha"]}
    }

    assert {:ok, first_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert first_amendment["proposed_revision"] == run_r2["spec_revision"]
    assert first_amendment["proposed_contract_sha256"] == run_r2["contract_sha256"]
    assert first_amendment["proposed_contract_markdown"] == run_r2["contract_markdown"]
    assert first_amendment["candidate_sha"] == run_r2["candidate_sha"]
    assert run_r2["state"] == "WRITING"
    assert first_amendment["proposed_revision"] == first_amendment["prior_revision"] + 1
    assert {:ok, first_receipt} = Jason.decode(first_amendment["receipt_json"])
    assert first_receipt["application_kind"] == "BLOCKED_WRITER_HELD"
    assert {:ok, first_predecessor} = Jason.decode(first_receipt["blocked_predecessor_json"])
    assert Jason.decode!(first_predecessor["evidence_json"])["run_id"] == run_r2["run_id"]
    assert {:ok, _} = TicketContractAmendment.blocked_predecessor_for_installed_run(ctx.store, run_r2)
    assert {:ok, _} = TicketChatCommands.validate_contract_amendment(ctx.store, command_r3["command_key"])
    assert {:ok, second_amendment} = TicketContractAmendment.reserve(ctx.store, command_r3["command_key"], controller_context_r2)
    assert Jason.decode!(second_amendment["predecessor_json"]) == predecessor
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access
    refute_receive {:factory_task_started, _, _}

    Process.put(:blocked_amendment_jira_snapshot, source_r2)
    draft_r3 = Contract.draft_comment(Contract.bind("PPL-123", 3, markdown_r3))
    Process.put(:blocked_amendment_draft_body, draft_r3)
    Process.put(:blocked_amendment_draft_id, "blocked-draft-r3")
    Process.put(:blocked_amendment_expected_body, draft_r3)
    Process.put(:blocked_amendment_updated, "2026-10-07T12:02:00Z")
    assert {:ok, published_r3} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command_r3["command_key"], controller_context_r2, jira_opts)
    assert {:ok, _} = TicketContractAmendment.prepare_critic(ctx.store, command_r3["command_key"], controller_context_r2, published_r3["readback_json"], policy)

    assert {:ok, critic_r3} =
             TicketAmendmentCritic.execute(
               ctx.store,
               command_r3["command_key"],
               controller_context_r2,
               control_workspace,
               policy,
               app_server: AmendmentCriticAppServer
             )

    proposed_r3 = Contract.bind("PPL-123", 3, markdown_r3)
    output_sha_r3 = :crypto.hash(:sha256, Jason.encode!(critic_r3["output"])) |> Base.encode16(case: :lower)
    auth_body_r3 = Contract.automatic_authorization_marker(proposed_r3, critic_r3["task_key"], output_sha_r3)
    Process.put(:blocked_amendment_expected_body, auth_body_r3)
    Process.put(:blocked_amendment_authorization_id, "blocked-authorization-r3")
    Process.put(:blocked_amendment_updated, "2026-10-07T12:03:00Z")
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command_r3["command_key"], controller_context_r2, policy, jira_opts)
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command_r3["command_key"])
    assert {:ok, _, %{"phase" => "RESERVED", "active_owner" => 1}} = TicketContractAmendment.validate_current(ctx.store, command_r3["command_key"], controller_context_r2)
    assert {:ok, %{"phase" => "RESULT_RECORDED"}} = TicketContractAmendment.get_critic_attempt(ctx.store, command_r3["command_key"], policy)
    assert {:ok, receipt_r3} = TicketContractAmendment.apply_authorized(ctx.store, command_r3["command_key"], controller_context_r2, policy)
    assert receipt_r3["application_kind"] == "BLOCKED_WRITER_HELD"
    assert {:ok, ^receipt_r3} = TicketContractAmendment.apply_authorized(ctx.store, command_r3["command_key"], controller_context_r2, policy)
    held_r3 = Jason.decode!(receipt_r3["blocked_predecessor_json"])
    assert held_r3["request_key"] == request
    assert {:ok, run_r3} = RunLedger.get(ctx.store, "run")
    assert run_r3["spec_revision"] == 3 and run_r3["candidate_sha"] == prior_run["candidate_sha"]
    assert run_r3["worktree"] == prior_run["worktree"]
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command_r3["command_key"])

    assert {:ok, _} = TicketContractAmendment.blocked_source_preimage(ctx.store, command_r3["command_key"])
    parent_before_probe = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    r3_before_probe = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_r3["command_key"]])
    r3_state_before_probe = amendment_state.(ctx.store)
    r3_checkout_before_probe = checkout_state.()
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET phase = 'SUPERSEDED' WHERE command_key = ?", [command["command_key"]])
    r3_fault_state = amendment_state.(ctx.store)

    try do
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.blocked_source_preimage(ctx.store, command_r3["command_key"])
      assert amendment_state.(ctx.store) == r3_fault_state
      assert checkout_state.() == r3_checkout_before_probe
    after
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET phase = ? WHERE command_key = ?", [parent_before_probe["phase"], command["command_key"]])
    end

    assert amendment_state.(ctx.store) == r3_state_before_probe
    assert checkout_state.() == r3_checkout_before_probe
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == parent_before_probe
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_r3["command_key"]]) == r3_before_probe
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command_r3["command_key"])
    assert {:ok, _} = TicketContractAmendment.blocked_source_preimage(ctx.store, command_r3["command_key"])

    child_before_probe = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_r3["command_key"]])
    r3_state_before_probe = amendment_state.(ctx.store)
    r3_checkout_before_probe = checkout_state.()
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET supersession_json = '[]' WHERE command_key = ?", [command_r3["command_key"]])
    r3_fault_state = amendment_state.(ctx.store)

    try do
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert amendment_state.(ctx.store) == r3_fault_state
      assert checkout_state.() == r3_checkout_before_probe
    after
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET supersession_json = ? WHERE command_key = ?", [child_before_probe["supersession_json"], command_r3["command_key"]])
    end

    assert amendment_state.(ctx.store) == r3_state_before_probe
    assert checkout_state.() == r3_checkout_before_probe
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command_r3["command_key"]]) == child_before_probe
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command_r3["command_key"])

    markdown_r4 = "A third confirmed contract\n\n## Manual Validation\n- Required: no"
    body_r4 = "Revise the contract:\n" <> markdown_r4

    {:ok, staged_r4} =
      SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "blocked-amendment-r4", body_r4, [
        %{"operation" => "propose_contract_revision", "markdown" => markdown_r4}
      ])

    native_r4 =
      SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, ["earlier input", "another earlier input", body_r4])
      |> Map.update!("turns", fn turns -> [List.last(turns)] end)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native_r4)
    command_r4 = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged_r4["command_key"]])
    {:ok, run_r3} = RunLedger.get(ctx.store, "run")

    controller_context_r3 = %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run_r3["spec_revision"], "contract_sha256" => run_r3["contract_sha256"], "candidate_sha" => run_r3["candidate_sha"]}
    }

    assert {:ok, third_amendment} = TicketContractAmendment.reserve(ctx.store, command_r4["command_key"], controller_context_r3)
    assert Jason.decode!(third_amendment["predecessor_json"]) == predecessor
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access
    refute_receive {:factory_task_started, _, _}

    Process.put(:blocked_amendment_jira_snapshot, Jason.decode!(run_r3["snapshot_json"]))
    draft_r4 = Contract.draft_comment(Contract.bind("PPL-123", 4, markdown_r4))
    Process.put(:blocked_amendment_draft_body, draft_r4)
    Process.put(:blocked_amendment_draft_id, "blocked-draft-r4")
    Process.put(:blocked_amendment_expected_body, draft_r4)
    Process.put(:blocked_amendment_updated, "2026-10-07T12:04:00Z")
    assert {:ok, published_r4} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command_r4["command_key"], controller_context_r3, jira_opts)
    assert {:ok, _} = TicketContractAmendment.prepare_critic(ctx.store, command_r4["command_key"], controller_context_r3, published_r4["readback_json"], policy)

    assert {:ok, critic_r4} =
             TicketAmendmentCritic.execute(
               ctx.store,
               command_r4["command_key"],
               controller_context_r3,
               control_workspace,
               policy,
               app_server: AmendmentCriticAppServer
             )

    proposed_r4 = Contract.bind("PPL-123", 4, markdown_r4)
    output_sha_r4 = :crypto.hash(:sha256, Jason.encode!(critic_r4["output"])) |> Base.encode16(case: :lower)
    auth_body_r4 = Contract.automatic_authorization_marker(proposed_r4, critic_r4["task_key"], output_sha_r4)
    Process.put(:blocked_amendment_expected_body, auth_body_r4)
    Process.put(:blocked_amendment_authorization_id, "blocked-authorization-r4")
    Process.put(:blocked_amendment_updated, "2026-10-07T12:05:00Z")
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command_r4["command_key"], controller_context_r3, policy, jira_opts)
    assert {:ok, receipt_r4} = TicketContractAmendment.apply_authorized(ctx.store, command_r4["command_key"], controller_context_r3, policy)
    assert receipt_r4["application_kind"] == "BLOCKED_WRITER_HELD"
    held_r4 = Jason.decode!(receipt_r4["blocked_predecessor_json"])
    assert {:ok, run_r4} = RunLedger.get(ctx.store, "run")
    assert run_r4["spec_revision"] == 4 and run_r4["candidate_sha"] == prior_run["candidate_sha"]
    assert run_r4["worktree"] == prior_run["worktree"]
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command_r3["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command_r4["command_key"])

    first_command = command
    command = command_r4

    assert {:ok, %{status: "BLOCKED", request_key: ^request, blockers: ["Fixture decision unresolved"], model_invoked: false} = first} =
             Scheduler.ticket_step(context, "run", options)

    assert {:ok, %{status: "BLOCKED", request_key: ^request, blockers: ["Fixture decision unresolved"], model_invoked: false} = second} =
             Scheduler.ticket_step(context, "run", options)

    assert first.next_action == second.next_action
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = 'run:feature-writer'") == prior_task
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == prior_access
    refute_receive {:factory_task_started, _, _}

    forged_model = "forged-model-allocation"
    held_task = held["task_json"] |> Jason.decode!() |> Map.put("model", forged_model)
    held_task_json = Jason.encode!(held_task)
    forged_held = Map.merge(held, %{"task_json" => held_task_json, "task_sha256" => :crypto.hash(:sha256, held_task_json) |> Base.encode16(case: :lower)})
    forged_receipt = Map.put(receipt, "blocked_predecessor_json", Jason.encode!(forged_held))
    forged_raw = Jason.encode!(forged_receipt)
    forged_sha = :crypto.hash(:sha256, forged_raw) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE factory_tasks SET model = ? WHERE task_key = ?", [forged_model, prior_task["task_key"]])
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [forged_raw, forged_sha, first_command["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [forged_raw, first_command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, first_command["command_key"])
    assert {:error, _} = Scheduler.ticket_step(context, "run", options)
    Store.query!(ctx.store, "UPDATE factory_tasks SET model = ? WHERE task_key = ?", [prior_task["model"], prior_task["task_key"]])
    original_raw = Jason.encode!(receipt)
    original_sha = :crypto.hash(:sha256, original_raw) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [original_raw, original_sha, first_command["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [original_raw, first_command["command_key"]])
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, first_command["command_key"])

    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert {:error, _} = Scheduler.ticket_step(context, "run", options)
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [applied_run["candidate_sha"]])

    Store.query!(ctx.store, "UPDATE factory_tasks SET prompt_sha256 = ? WHERE task_key = ?", [String.duplicate("c", 64), prior_task["task_key"]])
    assert {:error, _} = Scheduler.ticket_step(context, "run", options)
    Store.query!(ctx.store, "UPDATE factory_tasks SET prompt_sha256 = ? WHERE task_key = ?", [prior_task["prompt_sha256"], prior_task["task_key"]])

    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json = '{}' WHERE request_key = ?", [request])
    assert {:error, _} = Scheduler.ticket_step(context, "run", options)
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json = ? WHERE request_key = ?", [prior_evidence["owner_stop_json"], request])

    Store.query!(ctx.store, "UPDATE workspace_access SET released_at = ? WHERE reservation_key = ?", [DateTime.utc_now() |> DateTime.to_iso8601(), predecessor["reservation_key"]])
    assert {:error, _} = Scheduler.ticket_step(context, "run", options)
    Store.query!(ctx.store, "UPDATE workspace_access SET released_at = NULL WHERE reservation_key = ?", [predecessor["reservation_key"]])

    assert {:ok, %{status: "BLOCKED", request_key: ^request}} = Scheduler.ticket_step(context, "run", options)
    refute_receive {:factory_task_started, _, _}

    body = "Please rework the current candidate."
    File.write!(Path.join(ctx.path, "fixture.txt"), "fixture dirty state\n")
    File.write!(Path.join(ctx.path, "untracked-resume-fixture.txt"), "preserve for resume\n")

    {:ok, rework} =
      SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "amended-blocked-rework", body, [
        %{"operation" => "request_rework"}
      ])

    native =
      SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, ["earlier input", "another earlier input", "third earlier input", body])
      |> Map.update!("turns", fn turns -> [List.last(turns)] end)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    {:ok, parent_options} = parent_reader_options(chat, native)

    {:ok, held_receipt} = TicketContractAmendment.blocked_predecessor_for_request(ctx.store, request)
    assert :ok = WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)
    rejection_baseline = blocked_amendment_protected_rows(ctx.store, chat["chat_key"])
    source_file = Path.join(ctx.path, "fixture.txt")
    source_bytes = File.read!(source_file)
    source_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]])
    index_path = Path.join(source_access["git_dir"], "index")
    index_bytes = File.read!(index_path)

    assert {:error, :blocked_amendment_predecessor_unproven} =
             WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, Map.put(held_receipt, "command_key", %{}))

    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == rejection_baseline
    assert :ok = WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)

    original_branch = String.trim(git(ctx.path, ["branch", "--show-current"]))
    alternate_branch = original_branch <> "-workspace-access-check"
    git(ctx.path, ["switch", "-c", alternate_branch])

    try do
      assert {:error, {:native_worktree_branch_mismatch, ^original_branch, ^alternate_branch}} =
               WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)

      assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == rejection_baseline
    after
      git(ctx.path, ["switch", original_branch])
    end

    assert :ok = WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)
    assert File.read!(source_file) == source_bytes
    assert File.read!(index_path) == index_bytes
    source_binding = Jason.decode!(source_access["binding_json"])
    assert String.trim(git(ctx.path, ["rev-parse", "HEAD"])) == source_binding["expected_sha"]

    assert {:error, :blocked_amendment_receipt_invalid} =
             WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, Map.put(held_receipt, "application_kind", "READY_WRITER_REWORK"))

    assert {:error, :blocked_amendment_receipt_changed} =
             WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, Map.put(held_receipt, "blocked_predecessor_json", "{}"))

    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == rejection_baseline

    prior_binding = Jason.decode!(prior_evidence["binding_json"])
    rework_command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [rework["command_key"]])

    disposition =
      Store.query!(ctx.store, "SELECT payload_json FROM events WHERE run_id = 'run' AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'").rows
      |> Enum.map(fn [raw] -> Jason.decode!(raw) end)
      |> Enum.find(&(&1["request_key"] == request))

    transfer_proof = %{
      "command_key" => rework_command["command_key"],
      "input_key" => rework_command["input_key"],
      "request_key" => request,
      "output_sha256" => prior_evidence["output_sha256"],
      "task_key" => prior_evidence["task_key"],
      "reservation_key" => predecessor["reservation_key"],
      "reservation_generation" => prior_binding["reservation_generation"],
      "disposition_key" => disposition["disposition_key"],
      "new_prompt_sha256" => :crypto.hash(:sha256, "resume prompt") |> Base.encode16(case: :lower),
      "amendment_command_key" => "different-amendment-command",
      "checkout_head_sha" => String.trim(git(ctx.path, ["rev-parse", "HEAD"]))
    }

    transfer_attrs = %{
      "reservation_key" => "workspace:rejected-amendment-link",
      "run_id" => "run",
      "task_key" => prior_task["task_key"],
      "request_key" => "rejected-amendment-link",
      "mode" => "SOURCE",
      "allowed_root" => context.workspace_root,
      "expected_sha" => prior_run["candidate_sha"]
    }

    assert {:error, :blocked_amendment_receipt_changed} =
             WorkspaceAccess.transfer_blocked_source(
               ctx.store,
               predecessor["reservation_key"],
               prior_binding["reservation_generation"],
               transfer_attrs,
               transfer_proof
             )

    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == rejection_baseline
    assert File.read!(source_file) == source_bytes
    assert File.read!(index_path) == index_bytes

    assert {:ok, %{launches: [], events: capacity_events}} =
             normal_poll(context, Keyword.put(options, :free_bytes, 19_999_999_999), parent_options)

    assert Enum.any?(capacity_events, &(&1.event == "TICKET_DEFERRED"))

    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} =
             TicketChatCommands.get(ctx.store, rework["command_key"])

    assert {:ok, %{launches: [launch]}} = normal_poll(context, options, parent_options)
    assert launch.task_key == "run:feature-writer"
    expected_thread = prior_task["thread_id"]
    assert_receive {:factory_task_started, "run:feature-writer", ^expected_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    assert {:ok, %{launches: [], events: resumed_events}} = normal_poll(context, options, parent_options)
    assert Enum.any?(resumed_events, &(&1.event == "TICKET_ADOPTED"))

    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => application}} =
             TicketChatCommands.get(ctx.store, rework["command_key"])

    resume = Jason.decode!(application)
    assert resume["kind"] == "BLOCKED_WRITER_RESUMED"
    assert resume["prior_request_key"] == request
    assert resume["request_key"] != request
    assert resume["amendment_command_key"] == command["command_key"]
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert WorkerEvidence.superseded_blocked_attempt?(ctx.store, prior_evidence)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [prior_task["task_key"]])["count"] == 2

    amended_transfer_state = blocked_amendment_complete_state(ctx.store, chat["chat_key"])
    old_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]])

    assert {:error, :u11_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE workspace_access SET release_receipt_json = '[]' WHERE reservation_key = ?", [predecessor["reservation_key"]])
               corrupted_state = blocked_amendment_complete_state(tx, chat["chat_key"])
               assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(tx, command["command_key"])
               assert blocked_amendment_complete_state(tx, chat["chat_key"]) == corrupted_state
               Exqlite.rollback(tx, :u11_probe_rolled_back)
             end)

    assert blocked_amendment_complete_state(ctx.store, chat["chat_key"]) == amended_transfer_state
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == old_access
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])

    release_receipt = Jason.decode!(old_access["release_receipt_json"])
    assert release_receipt["amendment_command_key"] == command["command_key"]
    original_release_json = old_access["release_receipt_json"]
    corrupted_release = release_receipt |> Map.put("amendment_command_key", nil) |> Jason.encode!()
    transfer_probe_state = amendment_state.(ctx.store)
    transfer_probe_checkout = checkout_state.()

    try do
      Store.query!(ctx.store, "UPDATE workspace_access SET release_receipt_json = ? WHERE reservation_key = ?", [corrupted_release, predecessor["reservation_key"]])
      fault_state = amendment_state.(ctx.store)
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert amendment_state.(ctx.store) == fault_state
    after
      Store.query!(ctx.store, "UPDATE workspace_access SET release_receipt_json = ? WHERE reservation_key = ?", [original_release_json, predecessor["reservation_key"]])
    end

    assert amendment_state.(ctx.store) == transfer_probe_state
    assert checkout_state.() == transfer_probe_checkout
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [predecessor["reservation_key"]]) == old_access
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])

    transferred_baseline = blocked_amendment_protected_rows(ctx.store, chat["chat_key"])

    assert {:error, :blocked_amendment_predecessor_unproven} =
             WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)

    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == transferred_baseline

    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ?", [resume["request_key"]])["status"] == "CONSUMED"

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    assert {:ok, _} = TicketContractAmendment.get(reopened, command["command_key"])

    reopened_baseline = blocked_amendment_protected_rows(reopened, chat["chat_key"])

    assert {:error, :blocked_amendment_predecessor_unproven} =
             WorkspaceAccess.validate_blocked_amendment_predecessor(reopened, held_receipt)

    assert blocked_amendment_protected_rows(reopened, chat["chat_key"]) == reopened_baseline

    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => ^application}} =
             TicketChatCommands.get(reopened, rework["command_key"])

    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [prior_task["task_key"]])["count"] ==
             2

    {:ok, resumed_run} = RunLedger.get(reopened, "run")

    assert {:error, :ticket_delivery_review_history_absent} =
             TicketWorkerRunner.retained_review_preimage(reopened, resumed_run)

    command_row = Store.one!(reopened, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [rework["command_key"]])
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = '{}' WHERE command_key = ?", [rework["command_key"]])

    assert {:error, :ticket_delivery_ready_rework_history_corrupt} =
             TicketWorkerRunner.retained_review_preimage(reopened, resumed_run)

    assert Store.one!(reopened, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [rework["command_key"]])["application_receipt_json"] ==
             "{}"

    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [command_row["application_receipt_json"], rework["command_key"]])
    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => ^application}} = TicketChatCommands.get(reopened, rework["command_key"])

    {:ok, _} = RunLedger.update(reopened, "run", %{state: "READY_FOR_REVIEW"})
    {:ok, ready_run} = RunLedger.get(reopened, "run")
    assert ready_run["state"] == "READY_FOR_REVIEW"
    markdown_r5 = "A fourth confirmed contract\n\n## Manual Validation\n- Required: no"
    body_r5 = "Revise the contract:\n" <> markdown_r5

    {:ok, staged_r5} =
      SymphonyElixir.TicketChatFixture.stage(%{store: reopened}, "blocked-amendment-r5", body_r5, [
        %{"operation" => "propose_contract_revision", "markdown" => markdown_r5}
      ])

    native_r5 =
      SymphonyElixir.TicketChatFixture.native(%{store: reopened, cwd: chat["cwd"], root: ctx.root}, ["prior one", "prior two", "prior three", "prior four", body_r5])
      |> Map.update!("turns", fn turns -> [List.last(turns)] end)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(reopened, "run", native_r5)
    command_r5 = Store.one!(reopened, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged_r5["command_key"]])

    controller_context_r5 = %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{
        "generation" => chat["generation"],
        "spec_revision" => ready_run["spec_revision"],
        "contract_sha256" => ready_run["contract_sha256"],
        "candidate_sha" => ready_run["candidate_sha"]
      }
    }

    assert {:ok, _} = TicketContractAmendment.reserve(reopened, command_r5["command_key"], controller_context_r5)
    source_r5 = normalized_amendment_source(ready_run["snapshot_json"])
    Process.put(:blocked_amendment_jira_snapshot, Map.put(source_r5, "updated", "2026-10-07T12:06:00Z"))
    draft_r5 = Contract.draft_comment(Contract.bind("PPL-123", 5, markdown_r5))
    Process.put(:blocked_amendment_draft_body, draft_r5)
    Process.put(:blocked_amendment_draft_id, "blocked-draft-r5")
    Process.put(:blocked_amendment_expected_body, draft_r5)
    Process.put(:blocked_amendment_updated, "2026-10-07T12:06:00Z")

    assert {:ok, published_r5} =
             TicketAmendmentJiraOperation.publish_draft(reopened, command_r5["command_key"], controller_context_r5, jira_opts)

    assert {:ok, _} =
             TicketContractAmendment.prepare_critic(
               reopened,
               command_r5["command_key"],
               controller_context_r5,
               published_r5["readback_json"],
               policy
             )

    assert {:ok, critic_r5} =
             TicketAmendmentCritic.execute(
               reopened,
               command_r5["command_key"],
               controller_context_r5,
               control_workspace,
               policy,
               app_server: AmendmentCriticAppServer
             )

    proposed_r5 = Contract.bind("PPL-123", 5, markdown_r5)
    output_sha_r5 = :crypto.hash(:sha256, Jason.encode!(critic_r5["output"])) |> Base.encode16(case: :lower)
    auth_body_r5 = Contract.automatic_authorization_marker(proposed_r5, critic_r5["task_key"], output_sha_r5)
    Process.put(:blocked_amendment_expected_body, auth_body_r5)
    Process.put(:blocked_amendment_authorization_id, "blocked-authorization-r5")
    Process.put(:blocked_amendment_updated, "2026-10-07T12:07:00Z")

    assert {:ok, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               reopened,
               command_r5["command_key"],
               controller_context_r5,
               policy,
               jira_opts
             )

    assert {:ok, receipt_r5} =
             TicketContractAmendment.apply_authorized(reopened, command_r5["command_key"], controller_context_r5, policy)

    assert receipt_r5["application_kind"] == "READY_FOR_REVIEW"
    assert {:ok, run_r5} = RunLedger.get(reopened, "run")
    assert run_r5["state"] == "VERIFYING" and run_r5["spec_revision"] == 5
    assert {:ok, _} = TicketContractAmendment.get(reopened, first_command["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r3["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r4["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r5["command_key"])

    protected_after_r5 = blocked_amendment_protected_rows(reopened, chat["chat_key"])

    assert {:ok, ^receipt} =
             TicketContractAmendment.apply_authorized(reopened, first_command["command_key"], controller_context, policy)

    assert {:ok, ^receipt_r3} =
             TicketContractAmendment.apply_authorized(reopened, command_r3["command_key"], controller_context_r2, policy)

    assert {:ok, ^receipt_r4} =
             TicketContractAmendment.apply_authorized(reopened, command_r4["command_key"], controller_context_r3, policy)

    assert blocked_amendment_protected_rows(reopened, chat["chat_key"]) == protected_after_r5

    {:ok, _} = RunLedger.update(reopened, "run", %{state: "WRITING", plan_markdown: "blocked"})
    assert {:ok, %{status: "LAUNCHED", launch: launch_r6}} = Scheduler.ticket_step(context, "run", options)
    assert_receive {:factory_task_started, "run:feature-writer", _}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    [[request_r6]] = Store.query!(reopened, "SELECT request_key FROM worker_evidence WHERE task_key = ? ORDER BY created_at DESC LIMIT 1", [launch_r6.task_key]).rows
    assert {:ok, %{status: "BLOCKED", request_key: ^request_r6}} = Scheduler.ticket_step(context, "run", options)
    {:ok, run_r6} = RunLedger.get(reopened, "run")
    markdown_r6 = "A fifth confirmed contract\n\n## Manual Validation\n- Required: no"
    body_r6 = "Revise the contract:\n" <> markdown_r6

    {:ok, staged_r6} =
      SymphonyElixir.TicketChatFixture.stage(%{store: reopened}, "blocked-amendment-r6", body_r6, [
        %{"operation" => "propose_contract_revision", "markdown" => markdown_r6}
      ])

    native_r6 =
      SymphonyElixir.TicketChatFixture.native(%{store: reopened, cwd: chat["cwd"], root: ctx.root}, ["prior one", "prior two", "prior three", "prior four", "prior five", body_r6])
      |> Map.update!("turns", fn turns -> [List.last(turns)] end)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(reopened, "run", native_r6)
    command_r6 = Store.one!(reopened, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged_r6["command_key"]])

    controller_context_r6 = %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{
        "generation" => chat["generation"],
        "spec_revision" => run_r6["spec_revision"],
        "contract_sha256" => run_r6["contract_sha256"],
        "candidate_sha" => run_r6["candidate_sha"]
      }
    }

    assert {:ok, amendment_r6} = TicketContractAmendment.reserve(reopened, command_r6["command_key"], controller_context_r6)
    predecessor_r6 = Jason.decode!(amendment_r6["predecessor_json"])
    refute predecessor_r6["request_key"] == predecessor["request_key"]
    source_r6 = normalized_amendment_source(run_r6["snapshot_json"])
    Process.put(:blocked_amendment_jira_snapshot, Map.put(source_r6, "updated", "2026-10-07T12:08:00Z"))
    draft_r6 = Contract.draft_comment(Contract.bind("PPL-123", 6, markdown_r6))
    Process.put(:blocked_amendment_draft_body, draft_r6)
    Process.put(:blocked_amendment_draft_id, "blocked-draft-r6")
    Process.put(:blocked_amendment_expected_body, draft_r6)
    Process.put(:blocked_amendment_updated, "2026-10-07T12:08:00Z")

    assert {:ok, published_r6} =
             TicketAmendmentJiraOperation.publish_draft(reopened, command_r6["command_key"], controller_context_r6, jira_opts)

    assert {:ok, _} =
             TicketContractAmendment.prepare_critic(
               reopened,
               command_r6["command_key"],
               controller_context_r6,
               published_r6["readback_json"],
               policy
             )

    assert {:ok, critic_r6} =
             TicketAmendmentCritic.execute(
               reopened,
               command_r6["command_key"],
               controller_context_r6,
               control_workspace,
               policy,
               app_server: AmendmentCriticAppServer
             )

    proposed_r6 = Contract.bind("PPL-123", 6, markdown_r6)
    output_sha_r6 = :crypto.hash(:sha256, Jason.encode!(critic_r6["output"])) |> Base.encode16(case: :lower)
    auth_body_r6 = Contract.automatic_authorization_marker(proposed_r6, critic_r6["task_key"], output_sha_r6)
    Process.put(:blocked_amendment_expected_body, auth_body_r6)
    Process.put(:blocked_amendment_authorization_id, "blocked-authorization-r6")
    Process.put(:blocked_amendment_updated, "2026-10-07T12:09:00Z")

    assert {:ok, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               reopened,
               command_r6["command_key"],
               controller_context_r6,
               policy,
               jira_opts
             )

    assert {:ok, receipt_r6} =
             TicketContractAmendment.apply_authorized(reopened, command_r6["command_key"], controller_context_r6, policy)

    assert receipt_r6["application_kind"] == "BLOCKED_WRITER_HELD"
    assert {:ok, _} = TicketContractAmendment.get(reopened, first_command["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r3["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r4["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r5["command_key"])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command_r6["command_key"])

    evidence_r6 = Store.one!(reopened, "SELECT * FROM worker_evidence WHERE request_key = ?", [request_r6])
    Store.query!(reopened, "UPDATE worker_evidence SET owner_stop_json = '{}' WHERE request_key = ?", [request_r6])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(reopened, first_command["command_key"])
    Store.query!(reopened, "UPDATE worker_evidence SET owner_stop_json = ? WHERE request_key = ?", [evidence_r6["owner_stop_json"], request_r6])
    assert {:ok, _} = TicketContractAmendment.get(reopened, first_command["command_key"])

    attempt_r4 = Store.one!(reopened, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_r4["command_key"]])
    Store.query!(reopened, "UPDATE ticket_contract_critic_attempts SET result_json = '{}' WHERE command_key = ?", [command_r4["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(reopened, first_command["command_key"])
    Store.query!(reopened, "UPDATE ticket_contract_critic_attempts SET result_json = ? WHERE command_key = ?", [attempt_r4["result_json"], command_r4["command_key"]])
    assert {:ok, _} = TicketContractAmendment.get(reopened, first_command["command_key"])

    held_task = held_r4["task_json"] |> Jason.decode!() |> Map.put("model", "forged-model-allocation")
    forged_held = Map.put(held_r4, "task_json", Jason.encode!(held_task))
    forged_receipt = Map.put(receipt, "blocked_predecessor_json", Jason.encode!(forged_held))
    forged_raw = Jason.encode!(forged_receipt)
    forged_sha = :crypto.hash(:sha256, forged_raw) |> Base.encode16(case: :lower)

    Store.query!(reopened, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [forged_raw, forged_sha, first_command["command_key"]])
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [forged_raw, first_command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(reopened, first_command["command_key"])

    original_raw = Jason.encode!(receipt)
    original_sha = :crypto.hash(:sha256, original_raw) |> Base.encode16(case: :lower)
    Store.query!(reopened, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [original_raw, original_sha, first_command["command_key"]])
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [original_raw, first_command["command_key"]])
    assert {:ok, _} = TicketContractAmendment.get(reopened, command["command_key"])
  end

  defp normalized_amendment_source(snapshot_json) do
    snapshot = Jason.decode!(snapshot_json)

    Map.merge(snapshot, %{
      "key" => "PPL-123",
      "id" => "issue-id",
      "summary" => "Existing summary",
      "description" => "Existing description",
      "status" => "In Progress",
      "labels" => ["ai-ready"],
      "assignee" => nil,
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => [],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-10-07T12:00:00Z",
      "comments" => Enum.with_index(snapshot["comments"] || [], 1) |> Enum.map(fn {comment, index} -> Map.put_new(comment, "id", "old-comment-#{index}") end)
    })
  end

  defp critic_model_policy do
    %{
      "default_provider" => "openai",
      "providers" => %{"openai" => %{"standard" => "critic-model-v1"}},
      "roles" => %{"specification-critic" => %{"provider" => "openai", "model_class" => "standard", "reasoning_effort" => "high"}}
    }
  end

  defp blocked_amendment_protected_rows(store, chat_key) do
    %{
      run: Store.query!(store, "SELECT * FROM runs WHERE run_id = 'run'").rows,
      chat: Store.query!(store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [chat_key]).rows,
      links: Store.query!(store, "SELECT * FROM ticket_chat_runs WHERE chat_key = ? ORDER BY run_id", [chat_key]).rows,
      tasks: Store.query!(store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      evidence: Store.query!(store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
      access: Store.query!(store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows,
      commands: Store.query!(store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
      questions: Store.query!(store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows,
      inputs: Store.query!(store, "SELECT * FROM ticket_chat_inputs WHERE chat_key = ? ORDER BY input_key", [chat_key]).rows,
      events: Store.query!(store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows,
      outbox: Store.query!(store, "SELECT * FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND target_key = ? ORDER BY request_key", [chat_key]).rows
    }
  end

  defp blocked_amendment_complete_state(store, chat_key) do
    Map.merge(blocked_amendment_protected_rows(store, chat_key), %{
      amendments: Store.query!(store, "SELECT * FROM ticket_contract_amendments ORDER BY rowid").rows,
      critic_attempts: Store.query!(store, "SELECT * FROM ticket_contract_critic_attempts ORDER BY rowid").rows,
      jira_effects: Store.query!(store, "SELECT * FROM ticket_amendment_jira_effects ORDER BY rowid").rows,
      authorization_effects: Store.query!(store, "SELECT * FROM ticket_amendment_authorization_effects ORDER BY rowid").rows,
      supersessions: Store.query!(store, "SELECT * FROM ticket_contract_amendment_supersessions ORDER BY rowid").rows,
      controller_checks: Store.query!(store, "SELECT * FROM controller_checks ORDER BY rowid").rows,
      checkout_intents: Store.query!(store, "SELECT * FROM ticket_checkout_intents ORDER BY rowid").rows
    })
  end

  test "unstopped or stale blocked evidence cannot record a disposition", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    request = finish_worker(context, options)
    {:ok, evidence} = WorkerEvidence.get(ctx.store, request)
    {:ok, task_before} = TaskLedger.get(ctx.store, "run:feature-writer")
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at = NULL, owner_stop_json = NULL WHERE request_key = ?", [request])
    assert {:error, :worker_not_ready_for_consumption} = Scheduler.ticket_step(context, "run", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_NATIVE_WRITER_BLOCKED'")["count"] == 0
    assert {:ok, ^task_before} = TaskLedger.get(ctx.store, "run:feature-writer")

    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at = ?, owner_stop_json = ?, binding_json = '{}' WHERE request_key = ?", [
      evidence["owner_stopped_at"],
      evidence["owner_stop_json"],
      request
    ])

    assert {:error, :worker_evidence_corrupt} = Scheduler.ticket_step(context, "run", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_NATIVE_WRITER_BLOCKED'")["count"] == 0
    assert {:ok, ^task_before} = TaskLedger.get(ctx.store, "run:feature-writer")

    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = ? WHERE request_key = ?", [evidence["binding_json"], request])
    Store.query!(ctx.store, "UPDATE factory_tasks SET status = 'FAILED' WHERE task_key = 'run:feature-writer'")
    assert {:error, :worker_task_result_conflict} = Scheduler.ticket_step(context, "run", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_NATIVE_WRITER_BLOCKED'")["count"] == 0
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows == access_before
  end

  test "an accepted native rework request transfers the blocked writer to one same-thread attempt", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    prior_request = finish_worker(context, options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    File.write!(Path.join(ctx.path, "fixture.txt"), "fixture dirty state\n")
    File.write!(Path.join(ctx.path, "untracked-resume-fixture.txt"), "preserve for resume\n")
    assert {:ok, %{status: "BLOCKED", request_key: ^prior_request}} = Scheduler.ticket_step(context, "run", options)

    {:ok, _question} =
      TicketChatCommands.open_question(ctx.store, "run", %{
        "question_key" => "Q-resume",
        "body" => "Keep this candidate?",
        "answers" => %{"yes" => true}
      })

    body = "Answer Q-resume: yes\nRework: current candidate"

    {:ok, staged} =
      SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "blocked-rework", body, [
        %{"operation" => "answer_question", "question_key" => "Q-resume", "value" => true},
        %{"operation" => "request_rework"}
      ])

    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert :ok = TicketChatCommands.preflight_rework_transfer(ctx.store, staged["command_key"])
    {:ok, reader_options} = parent_reader_options(chat, readback)
    {:ok, previous_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    previous_thread = previous_task["thread_id"]
    {:ok, previous_evidence} = WorkerEvidence.get(ctx.store, prior_request)
    [[previous_access]] = Store.query!(ctx.store, "SELECT reservation_key FROM workspace_access WHERE request_key = ? AND released_at IS NULL", [prior_request]).rows

    assert {:ok, %{launches: [launch], events: events}} = normal_poll(context, options, reader_options)
    assert launch.task_key == "run:feature-writer"
    assert Enum.any?(events, &(&1.event == "TICKET_COMMAND_RESUMED"))
    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => app_receipt}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert Jason.decode!(app_receipt)["prior_request_key"] == prior_request
    assert :ok = TicketChatCommands.validate_rework_replay(ctx.store, staged["command_key"])

    assert Store.one!(ctx.store, "SELECT status, answer_json, input_key FROM ticket_chat_questions WHERE question_key = 'Q-resume'") == %{
             "status" => "ANSWERED",
             "answer_json" => "true",
             "input_key" => TicketChatCommands.get(ctx.store, staged["command_key"]) |> elem(1) |> Map.fetch!("input_key")
           }

    assert {:ok, ^previous_evidence} = WorkerEvidence.get(ctx.store, prior_request)
    assert %{"released_at" => released_at} = Store.one!(ctx.store, "SELECT released_at FROM workspace_access WHERE reservation_key = ?", [previous_access])
    assert is_binary(released_at)
    assert_receive {:factory_task_started, "run:feature-writer", ^previous_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000

    {:ok, resumed_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert resumed_task["thread_id"] == previous_task["thread_id"]
    assert resumed_task["turn_id"] != previous_task["turn_id"]
    assert resumed_task["prompt_sha256"] != previous_task["prompt_sha256"]
    assert Store.query!(ctx.store, "SELECT request_key, status FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [resumed_task["task_key"]]).rows |> length() == 2
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "fixture dirty state\n"
    assert File.read!(Path.join(ctx.path, "untracked-resume-fixture.txt")) == "preserve for resume\n"
    assert {:ok, %{launches: [], events: replay_events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(replay_events, &(&1.event == "TICKET_ADOPTED"))
    assert {:ok, ^previous_evidence} = WorkerEvidence.get(ctx.store, prior_request)
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key != ? AND task_key = ?", [prior_request, resumed_task["task_key"]])["status"] == "CONSUMED"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [resumed_task["task_key"]])["count"] == 2
    refute_receive {:factory_task_started, "run:feature-writer", _}

    {:ok, current_run} = RunLedger.get(ctx.store, "run")
    transferred_state = blocked_amendment_protected_rows(ctx.store, chat["chat_key"])
    assert WorkerEvidence.superseded_blocked_attempt?(ctx.store, previous_evidence)

    complete_transferred_state = blocked_amendment_complete_state(ctx.store, chat["chat_key"])
    original_command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    application = Jason.decode!(original_command["application_receipt_json"])
    assert application["request_key"] != previous_evidence["request_key"]

    assert {:error, :u11_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               corrupted_application = Map.put(application, "request_key", previous_evidence["request_key"])
               Store.query!(tx, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [Jason.encode!(corrupted_application), staged["command_key"]])
               corrupted_state = blocked_amendment_complete_state(tx, chat["chat_key"])
               refute WorkerEvidence.superseded_blocked_attempt?(tx, previous_evidence)
               assert blocked_amendment_complete_state(tx, chat["chat_key"]) == corrupted_state
               Exqlite.rollback(tx, :u11_probe_rolled_back)
             end)

    assert blocked_amendment_complete_state(ctx.store, chat["chat_key"]) == complete_transferred_state
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]]) == original_command
    assert WorkerEvidence.superseded_blocked_attempt?(ctx.store, previous_evidence)
    refute WorkerEvidence.superseded_blocked_attempt?(ctx.store, Map.put(previous_evidence, "task_key", "different-task"))
    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == transferred_state
    assert :ok = TicketChatCommands.validate_rework_replay(ctx.store, staged["command_key"])
    assert {:error, :ticket_delivery_review_history_absent} = TicketWorkerRunner.retained_review_preimage(ctx.store, current_run)

    command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    assert %{"kind" => "BLOCKED_WRITER_RESUMED"} = Jason.decode!(command["application_receipt_json"])
    post_tamper_state = fn store -> blocked_amendment_protected_rows(store, chat["chat_key"]) end

    assert {:error, :ticket_delivery_blocked_rework_history_corrupt} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE ticket_chat_commands SET receipt_json = '[]' WHERE command_key = ?", [staged["command_key"]])
               corrupted_state = post_tamper_state.(tx)
               assert {:error, :invalid_receipt} = TicketChatCommands.validate_rework_replay(tx, staged["command_key"])

               assert {:error, :ticket_delivery_blocked_rework_history_corrupt} =
                        TicketWorkerRunner.retained_review_preimage(tx, current_run)

               assert post_tamper_state.(tx) == corrupted_state
               Exqlite.rollback(tx, :ticket_delivery_blocked_rework_history_corrupt)
             end)

    assert blocked_amendment_protected_rows(ctx.store, chat["chat_key"]) == transferred_state
    assert :ok = TicketChatCommands.validate_rework_replay(ctx.store, staged["command_key"])
    assert {:error, :ticket_delivery_review_history_absent} = TicketWorkerRunner.retained_review_preimage(ctx.store, current_run)
  end

  test "a resumed worker rejects a different observed session thread", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "wrong-session-thread")
    resume_options = Keyword.put(options, :app_server, SymphonyElixir.DesktopTicketLifecycleFixture.WrongResumeThreadServer)

    assert {:ok, %{launches: [launch]}} = normal_poll(context, resume_options, blocked.reader_options)
    assert launch.task_key == "run:feature-writer"
    assert_receive {:factory_task_finished, "run:feature-writer", {:error, _}}, 60_000
    refute_receive {:factory_task_started, "run:feature-writer", _}

    attempts =
      Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? AND request_key != ?", [
        "run:feature-writer",
        blocked.prior_request
      ])

    assert [attempt] = Enum.map(attempts.rows, &Map.new(Enum.zip(attempts.columns, &1)))

    assert attempt["status"] == "RECONCILE_REQUIRED"
    assert attempt["thread_id"] == nil
    assert attempt["turn_id"] == nil
    assert {:ok, prior} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    assert prior == blocked.prior_evidence
    assert Store.one!(ctx.store, "SELECT candidate_sha FROM runs WHERE run_id = 'run'")["candidate_sha"] == ctx.sha
  end

  test "a resumed worker rejects an item result observed under another thread", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "wrong-result-thread")
    resume_options = Keyword.put(options, :app_server, SymphonyElixir.DesktopTicketLifecycleFixture.WrongResultThreadServer)

    assert {:ok, %{launches: [launch]}} = normal_poll(context, resume_options, blocked.reader_options)
    assert launch.task_key == "run:feature-writer"
    expected_thread = blocked.thread_id
    assert_receive {:factory_task_started, "run:feature-writer", ^expected_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:error, _}}, 60_000

    rows =
      Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? AND request_key != ?", [
        "run:feature-writer",
        blocked.prior_request
      ])

    assert [%{"status" => "RECONCILE_REQUIRED", "thread_id" => thread, "turn_id" => "new-resume-turn", "output_json" => nil}] =
             Enum.map(rows.rows, &Map.new(Enum.zip(rows.columns, &1)))

    assert thread == blocked.thread_id
    prior_evidence = blocked.prior_evidence
    assert {:ok, ^prior_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    assert Store.one!(ctx.store, "SELECT candidate_sha FROM runs WHERE run_id = 'run'")["candidate_sha"] == ctx.sha
  end

  test "a resumed writer cannot reuse its predecessor turn", ctx do
    {context, options} = controller(ctx)
    options = Keyword.put(options, :app_server, SymphonyElixir.DesktopTicketLifecycleFixture.ReusedTurnWorkerServer)
    blocked = stage_blocked_rework(ctx, context, options, "reused-turn")

    assert blocked.prior_task["turn_id"] == "reused-turn"
    assert {:ok, %{launches: [launch]}} = normal_poll(context, options, blocked.reader_options)
    assert launch.task_key == "run:feature-writer"
    expected_thread = blocked.thread_id
    assert_receive {:factory_task_started, "run:feature-writer", ^expected_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:error, _}}, 60_000

    rows =
      Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? AND request_key != ?", [
        "run:feature-writer",
        blocked.prior_request
      ])

    assert [%{"status" => "RECONCILE_REQUIRED", "thread_id" => thread, "turn_id" => nil}] =
             Enum.map(rows.rows, &Map.new(Enum.zip(rows.columns, &1)))

    assert thread == blocked.thread_id
    prior_evidence = blocked.prior_evidence
    assert {:ok, ^prior_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    assert Store.one!(ctx.store, "SELECT candidate_sha FROM runs WHERE run_id = 'run'")["candidate_sha"] == ctx.sha
  end

  test "a START_SENT resume is not started again after reopening and polling", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "start-sent-replay")
    :ets.new(:ticket_resume_start_counter, [:named_table, :public, :set])
    Process.register(self(), :ticket_resume_start_owner)

    on_exit(fn ->
      if :ets.whereis(:ticket_resume_start_counter) != :undefined do
        case :ets.lookup(:ticket_resume_start_counter, :starter) do
          [{:starter, starter}] -> send(starter, :continue_ticket_resume)
          _ -> :ok
        end
      end

      if Process.whereis(:ticket_resume_start_owner) == self(), do: Process.unregister(:ticket_resume_start_owner)
      if :ets.whereis(:ticket_resume_start_counter) != :undefined, do: :ets.delete(:ticket_resume_start_counter)
    end)

    resume_options = Keyword.put(options, :app_server, SymphonyElixir.DesktopTicketLifecycleFixture.HeldResumeWorkerServer)
    assert {:ok, %{launches: [launch]}} = normal_poll(context, resume_options, blocked.reader_options)
    assert launch.task_key == "run:feature-writer"
    assert_receive {:ticket_resume_start_sent, thread_id, starter}, 15_000
    assert thread_id == blocked.thread_id
    assert :ets.lookup(:ticket_resume_start_counter, :count) == [{:count, 1}]

    {:ok, %{"status" => "APPLIED", "application_receipt_json" => application}} =
      TicketChatCommands.get(ctx.store, blocked.staged["command_key"])

    prepared_request = Jason.decode!(application)["request_key"]
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request])["status"] == "START_SENT"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE request_key = ?", [prepared_request])["count"] == 1

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    reopened_context = %{context | store: reopened, task_supervisor: supervisor}

    assert {:ok, %{launches: [], events: events}} =
             normal_poll(reopened_context, resume_options, blocked.reader_options)

    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert :ets.lookup(:ticket_resume_start_counter, :count) == [{:count, 1}]
    assert Store.one!(reopened, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request])["status"] == "START_SENT"

    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => ^application}} =
             TicketChatCommands.get(reopened, blocked.staged["command_key"])

    refute_receive {:factory_task_started, "run:feature-writer", _}

    send(starter, :continue_ticket_resume)
    assert_receive {:factory_task_started, "run:feature-writer", ^thread_id}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
  end

  defp stage_blocked_rework(ctx, context, options, proposal, mixed? \\ false) do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    prior_request = finish_worker(context, options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    File.write!(Path.join(ctx.path, "fixture.txt"), "fixture dirty state\n")
    File.write!(Path.join(ctx.path, "untracked-resume-fixture.txt"), "preserve for resume\n")
    assert {:ok, %{status: "BLOCKED", request_key: ^prior_request}} = Scheduler.ticket_step(context, "run", options)

    question_keys = if mixed? == :two_answers, do: ["Q-#{proposal}", "Q-#{proposal}-2"], else: ["Q-#{proposal}"]

    if mixed? do
      Enum.each(question_keys, fn question_key ->
        {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "Keep this candidate?", "answers" => %{"yes" => true}})
      end)
    end

    body =
      if mixed? do
        Enum.map_join(question_keys, "\n", &"Answer #{&1}: yes") <> "\nRework: current candidate"
      else
        "Please rework the current candidate."
      end

    operations =
      if mixed? do
        Enum.map(question_keys, &%{"operation" => "answer_question", "question_key" => &1, "value" => true}) ++ [%{"operation" => "request_rework"}]
      else
        [%{"operation" => "request_rework"}]
      end

    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, proposal, body, operations)
    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, reader_options} = parent_reader_options(chat, readback)
    {:ok, prior_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    {:ok, prior_evidence} = WorkerEvidence.get(ctx.store, prior_request)

    %{
      prior_request: prior_request,
      prior_task: prior_task,
      prior_evidence: prior_evidence,
      thread_id: prior_task["thread_id"],
      staged: staged,
      question_key: if(mixed?, do: hd(question_keys)),
      question_keys: if(mixed?, do: question_keys, else: []),
      reader_options: reader_options
    }
  end

  test "a stale second mixed answer leaves the blocked source owner and all workspace state untouched", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "mixed-stale-second", :two_answers)
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    task_before = blocked.prior_task
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task_before["task_key"]]).rows
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task_before["run_id"]]).rows
    file_path = Path.join(ctx.path, "fixture.txt")
    index_path = Path.join(Store.one!(ctx.store, "SELECT git_dir FROM workspace_access WHERE request_key = ?", [blocked.prior_request])["git_dir"], "index")
    original_file = File.read!(file_path)
    original_index = File.read!(index_path)
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET body = 'Changed after input' WHERE question_key = ?", [List.last(blocked.question_keys)])

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert {:ok, unchanged_task} = TaskLedger.get(ctx.store, task_before["task_key"])
    assert unchanged_task == task_before
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task_before["task_key"]]).rows == evidence_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task_before["run_id"]]).rows == access_before

    assert Store.query!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key IN (?, ?) ORDER BY question_key", blocked.question_keys).rows == [
             ["OPEN", nil],
             ["OPEN", nil]
           ]

    assert File.read!(file_path) == original_file
    assert File.read!(index_path) == original_index
    refute_receive {:factory_task_started, "run:feature-writer", _}
  end

  test "an ignored second answer update rolls back the mixed transfer before one clean retry", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "mixed-ignored-second", :two_answers)
    command_before = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [blocked.staged["command_key"]])
    input_before = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command_before["input_key"]])
    questions_before = Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE question_key IN (?, ?) ORDER BY question_key", blocked.question_keys).rows
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    tasks_before = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY generation").rows
    checkouts_before = Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'run' ORDER BY run_id").rows
    stored_events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    second_question_key = List.last(blocked.question_keys)
    old_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request])
    file_path = Path.join(ctx.path, "fixture.txt")
    index_path = Path.join(old_access["git_dir"], "index")
    original_file = File.read!(file_path)
    original_index = File.read!(index_path)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER ignore_second_mixed_answer BEFORE UPDATE OF status ON ticket_chat_questions WHEN OLD.question_key = '#{second_question_key}' AND NEW.status = 'ANSWERED' BEGIN SELECT RAISE(IGNORE); END"
    )

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, blocked.reader_options)
    assert events == [%{issue_key: "PPL-123", event: "TICKET_DEFERRED", detail: ":stale_question"}]
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [blocked.staged["command_key"]]) == command_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command_before["input_key"]]) == input_before
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE question_key IN (?, ?) ORDER BY question_key", blocked.question_keys).rows == questions_before

    assert Store.query!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key IN (?, ?) ORDER BY question_key", blocked.question_keys).rows == [
             ["OPEN", nil],
             ["OPEN", nil]
           ]

    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == tasks_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows == evidence_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY generation").rows == access_before
    assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'run' ORDER BY run_id").rows == checkouts_before
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == stored_events_before
    assert File.read!(file_path) == original_file
    assert File.read!(index_path) == original_index
    refute_receive {:factory_task_started, "run:feature-writer", _}

    Store.query!(ctx.store, "DROP TRIGGER ignore_second_mixed_answer")

    assert {:ok, %{launches: [launch]}} = normal_poll(context, options, blocked.reader_options)
    assert launch.task_key == blocked.prior_task["task_key"]
    expected_thread = blocked.thread_id
    assert_receive {:factory_task_started, "run:feature-writer", ^expected_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000

    assert Store.query!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key IN (?, ?) ORDER BY question_key", blocked.question_keys).rows == [
             ["ANSWERED", "true"],
             ["ANSWERED", "true"]
           ]

    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [blocked.prior_task["task_key"]])["count"] == 2
  end

  test "mixed rework rejects capacity, candidate and blocked-owner drift without applying answers", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "mixed-resume-guards", true)
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    task_before = blocked.prior_task
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task_before["task_key"]]).rows
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task_before["run_id"]]).rows
    prior_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request])
    file_path = Path.join(prior_access["canonical_path"], "fixture.txt")
    index_path = Path.join(prior_access["git_dir"], "index")
    original_file = File.read!(file_path)
    original_index = File.read!(index_path)

    assert {:ok, %{launches: [], events: capacity_events}} = normal_poll(context, Keyword.put(options, :free_bytes, 19_999_999_999), blocked.reader_options)
    assert Enum.any?(capacity_events, &(&1.event == "TICKET_DEFERRED"))
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task_before["run_id"]]).rows == access_before

    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("f", 40)])
    assert {:ok, %{launches: [], events: candidate_events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(candidate_events, &(&1.event == "TICKET_DEFERRED"))
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [run_before["candidate_sha"]])

    Store.query!(ctx.store, "UPDATE workspace_access SET generation = generation + 1 WHERE request_key = ?", [blocked.prior_request])
    assert {:ok, %{launches: [], events: owner_events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(owner_events, &(&1.event == "TICKET_DEFERRED"))
    Store.query!(ctx.store, "UPDATE workspace_access SET generation = ? WHERE request_key = ?", [prior_access["generation"], blocked.prior_request])

    source = prior_access["canonical_path"]
    original_head = String.trim(git(source, ["rev-parse", "HEAD"]))
    tree = String.trim(git(source, ["write-tree"]))
    drifted_head = String.trim(git(source, ["commit-tree", tree, "-p", original_head, "-m", "mixed blocked-resume HEAD drift fixture"]))
    git(source, ["update-ref", "HEAD", drifted_head])

    try do
      assert {:ok, %{launches: [], events: head_events}} = normal_poll(context, options, blocked.reader_options)
      assert Enum.any?(head_events, &(&1.event == "TICKET_DEFERRED"))
      assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task_before["run_id"]]).rows == access_before
      assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task_before["task_key"]]).rows == evidence_before
      assert TaskLedger.get(ctx.store, task_before["task_key"]) == {:ok, task_before}
      assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key]) == %{"status" => "OPEN", "answer_json" => nil}
      assert File.read!(file_path) == original_file
      assert File.read!(index_path) == original_index
      refute_receive {:factory_task_started, "run:feature-writer", _}
    after
      git(source, ["update-ref", "HEAD", original_head])
    end

    assert {:ok, unchanged_task} = TaskLedger.get(ctx.store, task_before["task_key"])
    assert unchanged_task == task_before
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task_before["task_key"]]).rows == evidence_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task_before["run_id"]]).rows == access_before
    assert Store.query!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key]).rows == [["OPEN", nil]]
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    refute_receive {:factory_task_started, "run:feature-writer", _}
  end

  test "mixed rework rolls answers and source transfer back when its terminal receipt fails", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "mixed-recorder-failure", true)
    old_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request])
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    task_rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key", []).rows
    evidence_rows = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [blocked.prior_task["task_key"]]).rows
    access_rows = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY generation", []).rows
    file_path = Path.join(ctx.path, "fixture.txt")
    index_path = Path.join(old_access["git_dir"], "index")
    original_file = File.read!(file_path)
    original_index = File.read!(index_path)

    Store.query!(ctx.store, """
    CREATE TRIGGER fail_mixed_resume_receipt BEFORE INSERT ON events
    WHEN NEW.event_type = 'TICKET_COMMAND_APPLIED'
    BEGIN SELECT RAISE(ABORT, 'fixture terminal receipt failure'); END
    """)

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key]) == %{"status" => "OPEN", "answer_json" => nil}
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key", []).rows == task_rows
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [blocked.prior_task["task_key"]]).rows == evidence_rows
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY generation", []).rows == access_rows
    assert {:ok, unchanged_task} = TaskLedger.get(ctx.store, blocked.prior_task["task_key"])
    assert unchanged_task == blocked.prior_task
    assert {:ok, unchanged_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    assert unchanged_evidence == blocked.prior_evidence
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request]) == old_access
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [blocked.prior_task["task_key"]])["count"] == 1
    assert File.read!(file_path) == original_file
    assert File.read!(index_path) == original_index
    Store.query!(ctx.store, "DROP TRIGGER fail_mixed_resume_receipt")

    assert {:ok, %{launches: [launch]}} = normal_poll(context, options, blocked.reader_options)
    assert launch.task_key == blocked.prior_task["task_key"]
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key]) == %{"status" => "ANSWERED", "answer_json" => "true"}
  end

  test "a changed candidate cannot transfer a blocked writer lease", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    prior_request = finish_worker(context, options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    assert {:ok, %{status: "BLOCKED", request_key: ^prior_request}} = Scheduler.ticket_step(context, "run", options)
    body = "Please rework the current candidate."
    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "stale-candidate", body, [%{"operation" => "request_rework"}])
    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, reader_options} = parent_reader_options(chat, readback)
    {:ok, before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    before_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [prior_request])
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("f", 40)])

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert {:ok, ^before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [prior_request]) == before_access
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = 'run:feature-writer'")["count"] == 1
  end

  test "resume rejects stale disposition and generation, gates capacity, and rolls back transfer", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "resume-guards")
    old_task = blocked.prior_task
    old_evidence = blocked.prior_evidence
    old_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request])
    disposition = Store.one!(ctx.store, "SELECT id, payload_json FROM events WHERE event_type = 'TICKET_NATIVE_WRITER_BLOCKED'")

    current_run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [blocked.staged["command_key"]])
    input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])

    disposition_payload =
      Store.query!(ctx.store, "SELECT id, payload_json FROM events WHERE run_id = 'run' AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'").rows
      |> Enum.map(fn [id, payload_json] -> {id, payload_json, Jason.decode!(payload_json)} end)
      |> Enum.find_value(fn {id, payload_json, payload} ->
        if payload["request_key"] == blocked.prior_request, do: {id, payload_json, payload}
      end)

    assert {disposition_id, disposition_json, actual_disposition} = disposition_payload
    assert {:ok, base_packet} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", current_run["candidate_sha"])
    prompt = TicketWorkerRunner.blocked_resume_packet(base_packet, input["body"], actual_disposition)
    new_request = DesktopStageRunner.request_key(old_task["task_key"], old_task["turn_id"], prompt)
    new_reservation = "workspace:" <> new_request
    refute new_request == blocked.prior_request
    refute new_reservation == old_access["reservation_key"]

    transfer_attrs = %{
      "reservation_key" => new_reservation,
      "run_id" => "run",
      "task_key" => old_task["task_key"],
      "request_key" => new_request,
      "mode" => "SOURCE",
      "allowed_root" => context.workspace_root,
      "expected_sha" => current_run["candidate_sha"]
    }

    transfer_proof = %{
      "command_key" => command["command_key"],
      "input_key" => input["input_key"],
      "request_key" => old_evidence["request_key"],
      "output_sha256" => old_evidence["output_sha256"],
      "task_key" => old_task["task_key"],
      "reservation_key" => old_access["reservation_key"],
      "reservation_generation" => old_access["generation"],
      "disposition_key" => actual_disposition["disposition_key"],
      "new_prompt_sha256" => :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower),
      "checkout_head_sha" => String.trim(git(ctx.path, ["rev-parse", "HEAD"]))
    }

    canonical_rows = blocked_amendment_complete_state(ctx.store, input["chat_key"])
    source_file = Path.join(ctx.path, "fixture.txt")
    git_dir = ctx.path |> git(["rev-parse", "--absolute-git-dir"]) |> String.trim()
    index_file = Path.join(git_dir, "index")
    source_bytes = File.read!(source_file)
    index_bytes = File.read!(index_file)
    original_head = String.trim(git(ctx.path, ["rev-parse", "HEAD"]))
    original_branch = String.trim(git(ctx.path, ["branch", "--show-current"]))

    assert {:error, :u11_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               assert {:ok, _} =
                        WorkspaceAccess.transfer_blocked_source(
                          tx,
                          old_access["reservation_key"],
                          old_access["generation"],
                          transfer_attrs,
                          transfer_proof
                        )

               Exqlite.rollback(tx, :u11_probe_rolled_back)
             end)

    assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == canonical_rows
    assert File.read!(source_file) == source_bytes
    assert File.read!(index_file) == index_bytes
    assert String.trim(git(ctx.path, ["rev-parse", "HEAD"])) == original_head
    assert String.trim(git(ctx.path, ["branch", "--show-current"])) == original_branch

    invalid_input_proof = Map.put(transfer_proof, "input_key", "not-the-accepted-input")

    assert {:error, :blocked_resume_authority_unproven} =
             WorkspaceAccess.transfer_blocked_source(ctx.store, old_access["reservation_key"], old_access["generation"], transfer_attrs, invalid_input_proof)

    assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == canonical_rows

    missing_disposition_proof = Map.delete(transfer_proof, "disposition_key")

    assert {:error, :blocked_resume_authority_unproven} =
             WorkspaceAccess.transfer_blocked_source(ctx.store, old_access["reservation_key"], old_access["generation"], transfer_attrs, missing_disposition_proof)

    assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == canonical_rows

    Store.query!(ctx.store, "UPDATE events SET payload_json = '{' WHERE id = ?", [disposition_id])
    corrupted_event_rows = blocked_amendment_complete_state(ctx.store, input["chat_key"])

    try do
      assert {:error, :blocked_resume_authority_unproven} =
               WorkspaceAccess.transfer_blocked_source(ctx.store, old_access["reservation_key"], old_access["generation"], transfer_attrs, transfer_proof)

      assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == corrupted_event_rows
    after
      Store.query!(ctx.store, "UPDATE events SET payload_json = ? WHERE id = ?", [disposition_json, disposition_id])
    end

    assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == canonical_rows

    alternate_branch = "u11-lifecycle-branch-#{System.unique_integer([:positive])}"
    git(ctx.path, ["branch", alternate_branch, original_head])
    git(ctx.path, ["switch", alternate_branch])

    try do
      branch_rows = blocked_amendment_complete_state(ctx.store, input["chat_key"])

      assert {:error, {:native_worktree_branch_mismatch, ^original_branch, ^alternate_branch}} =
               WorkspaceAccess.transfer_blocked_source(ctx.store, old_access["reservation_key"], old_access["generation"], transfer_attrs, transfer_proof)

      assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == branch_rows
      assert String.trim(git(ctx.path, ["rev-parse", "HEAD"])) == original_head
    after
      git(ctx.path, ["switch", original_branch])
    end

    assert {:error, :u11_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               assert {:ok, _} =
                        WorkspaceAccess.transfer_blocked_source(
                          tx,
                          old_access["reservation_key"],
                          old_access["generation"],
                          transfer_attrs,
                          transfer_proof
                        )

               Exqlite.rollback(tx, :u11_probe_rolled_back)
             end)

    assert blocked_amendment_complete_state(ctx.store, input["chat_key"]) == canonical_rows
    assert File.read!(source_file) == source_bytes
    assert File.read!(index_file) == index_bytes
    assert String.trim(git(ctx.path, ["rev-parse", "HEAD"])) == original_head
    assert String.trim(git(ctx.path, ["branch", "--show-current"])) == original_branch

    assert {:ok, %{launches: [], events: capacity_events}} =
             normal_poll(context, Keyword.put(options, :free_bytes, 19_999_999_999), blocked.reader_options)

    assert Enum.any?(capacity_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert {:ok, ^old_task} = TaskLedger.get(ctx.store, old_task["task_key"])
    assert {:ok, ^old_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request]) == old_access

    Store.query!(ctx.store, "UPDATE events SET payload_json = '{}' WHERE id = ?", [disposition["id"]])
    assert {:ok, %{launches: [], events: disposition_events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(disposition_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert {:ok, ^old_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    Store.query!(ctx.store, "UPDATE events SET payload_json = ? WHERE id = ?", [disposition["payload_json"], disposition["id"]])

    Store.query!(ctx.store, "UPDATE workspace_access SET generation = generation + 1 WHERE request_key = ?", [blocked.prior_request])
    assert {:ok, %{launches: [], events: generation_events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(generation_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert {:ok, ^old_task} = TaskLedger.get(ctx.store, old_task["task_key"])
    assert {:ok, ^old_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    Store.query!(ctx.store, "UPDATE workspace_access SET generation = ? WHERE request_key = ?", [old_access["generation"], blocked.prior_request])

    Store.query!(ctx.store, """
    CREATE TRIGGER fail_blocked_resume_transfer BEFORE INSERT ON workspace_access
    WHEN NEW.run_id = 'run' AND NEW.mode = 'SOURCE'
    BEGIN SELECT RAISE(ABORT, 'fixture resume transfer failure'); END
    """)

    assert {:ok, %{launches: [], events: rollback_events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(rollback_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
    assert {:ok, ^old_task} = TaskLedger.get(ctx.store, old_task["task_key"])
    assert {:ok, ^old_evidence} = WorkerEvidence.get(ctx.store, blocked.prior_request)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [blocked.prior_request]) == old_access
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE run_id = 'run' AND released_at IS NULL")["count"] == 1
    Store.query!(ctx.store, "DROP TRIGGER fail_blocked_resume_transfer")

    assert {:ok, %{launches: [launch]}} = normal_poll(context, options, blocked.reader_options)
    assert launch.task_key == old_task["task_key"]
    expected_thread = blocked.thread_id
    assert_receive {:factory_task_started, "run:feature-writer", ^expected_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(ctx.store, blocked.staged["command_key"])
  end

  test "a prepared RESERVED resume reopens and starts the same request exactly once", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    prior_request = finish_worker(context, options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    File.write!(Path.join(ctx.path, "fixture.txt"), "fixture dirty state\n")
    File.write!(Path.join(ctx.path, "untracked-resume-fixture.txt"), "preserve for resume\n")
    assert {:ok, %{status: "BLOCKED", request_key: ^prior_request}} = Scheduler.ticket_step(context, "run", options)

    body = "Please rework the current candidate."
    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "restart-resume", body, [%{"operation" => "request_rework"}])
    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, reader_options} = parent_reader_options(chat, readback)

    failed_context = %{context | task_supervisor: nil}

    _interrupted =
      try do
        normal_poll(failed_context, options, reader_options)
      catch
        :exit, reason -> {:exit, reason}
      end

    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => application}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    receipt = Jason.decode!(application)
    prepared_request = receipt["request_key"]
    assert is_binary(prepared_request) and prepared_request != prior_request
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request])["status"] == "RESERVED"
    assert {:ok, task_before_reopen} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert task_before_reopen["status"] == "STARTING"

    prepared_state = blocked_amendment_complete_state(ctx.store, chat["chat_key"])
    prepared_command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    prepared_application = Jason.decode!(prepared_command["application_receipt_json"])
    assert prepared_application["answered_question_keys"] == []
    assert is_nil(prepared_application["answer_proof_sha256"])
    assert :ok = TicketChatCommands.validate_rework_replay(ctx.store, staged["command_key"])

    assert {:error, :u11_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               corrupted_application = Map.put(prepared_application, "answer_proof_sha256", String.duplicate("0", 64))
               Store.query!(tx, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [Jason.encode!(corrupted_application), staged["command_key"]])
               corrupted_state = blocked_amendment_complete_state(tx, chat["chat_key"])

               assert {:error, :blocked_resume_answer_replay_unproven} =
                        TicketChatCommands.validate_rework_replay(tx, staged["command_key"])

               assert blocked_amendment_complete_state(tx, chat["chat_key"]) == corrupted_state
               Exqlite.rollback(tx, :u11_probe_rolled_back)
             end)

    assert blocked_amendment_complete_state(ctx.store, chat["chat_key"]) == prepared_state
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]]) == prepared_command
    assert :ok = TicketChatCommands.validate_rework_replay(ctx.store, staged["command_key"])

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    reopened_context = %{context | store: reopened, task_supervisor: supervisor}
    resumed_thread = task_before_reopen["thread_id"]

    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = '{}' WHERE command_key = ?", [staged["command_key"]])

    assert {:ok, %{launches: [], events: invalid_transfer_events}} =
             normal_poll(reopened_context, options, reader_options)

    assert Enum.any?(invalid_transfer_events, &(&1.event == "TICKET_DEFERRED"))
    assert Store.one!(reopened, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request])["status"] == "RESERVED"
    refute_receive {:factory_task_started, "run:feature-writer", _}

    legacy_application =
      application
      |> Jason.decode!()
      |> Map.drop(["answered_question_keys", "answer_proof_sha256"])
      |> Jason.encode!()

    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [legacy_application, staged["command_key"]])

    assert {:ok, %{launches: [launch], events: events}} = normal_poll(reopened_context, options, reader_options)
    assert launch.task_key == "run:feature-writer"
    assert Enum.any?(events, &(&1.event == "TICKET_LAUNCHED"))
    assert_receive {:factory_task_started, "run:feature-writer", ^resumed_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [task_before_reopen["task_key"]])["count"] == 2
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_evidence WHERE request_key = ?", [prepared_request])["count"] == 1
    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => ^legacy_application}} = TicketChatCommands.get(reopened, staged["command_key"])
  end

  test "a prepared mixed RESERVED resume rejects tampered historical proof before one start", ctx do
    {context, options} = controller(ctx)
    blocked = stage_blocked_rework(ctx, context, options, "mixed-replay-tampering", true)

    _interrupted =
      try do
        normal_poll(%{context | task_supervisor: nil}, options, blocked.reader_options)
      catch
        :exit, reason -> {:exit, reason}
      end

    {:ok, %{"status" => "APPLIED", "application_receipt_json" => application}} =
      TicketChatCommands.get(ctx.store, blocked.staged["command_key"])

    prepared_receipt = Jason.decode!(application)
    prepared_request = prepared_receipt["request_key"]
    {:ok, task_before_reopen} = TaskLedger.get(ctx.store, blocked.prior_task["task_key"])
    assert task_before_reopen["status"] == "STARTING"
    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    reopened_context = %{context | store: reopened, task_supervisor: supervisor}
    command = Store.one!(reopened, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [blocked.staged["command_key"]])
    input = Store.one!(reopened, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    question = Store.one!(reopened, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key])
    access = Store.one!(reopened, "SELECT * FROM workspace_access WHERE request_key = ?", [prepared_request])
    evidence = Store.one!(reopened, "SELECT * FROM worker_evidence WHERE request_key = ?", [prepared_request])
    run = Store.one!(reopened, "SELECT * FROM runs WHERE run_id = 'run'")
    file_path = Path.join(access["canonical_path"], "fixture.txt")
    index_path = Path.join(access["git_dir"], "index")
    original_file = File.read!(file_path)
    original_index = File.read!(index_path)

    replay = %{
      context: reopened_context,
      options: options,
      blocked: blocked,
      task: task_before_reopen,
      request: prepared_request,
      run: run,
      access: access,
      evidence: evidence,
      original_file: original_file,
      index_path: index_path,
      original_index: original_index,
      file_path: file_path
    }

    assert prepared_receipt["answered_question_keys"] == [blocked.question_key]
    assert prepared_receipt["answer_proof_sha256"]

    Store.query!(reopened, "UPDATE ticket_chat_inputs SET body = 'Changed after acceptance' WHERE input_key = ?", [input["input_key"]])
    assert_prepared_mixed_replay_rejected(replay)
    Store.query!(reopened, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [input["body"], input["input_key"]])

    operations = Jason.decode!(command["payload_json"])
    bad_operations = List.update_at(operations, 0, &Map.put(&1, "question_digest", String.duplicate("f", 64)))
    bad_payload = Jason.encode!(bad_operations)
    bad_digest = :crypto.hash(:sha256, bad_payload) |> Base.encode16(case: :lower)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [bad_payload, bad_digest, command["command_key"]])
    assert_prepared_mixed_replay_rejected(replay)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [command["payload_json"], command["payload_sha256"], command["command_key"]])

    Store.query!(reopened, "UPDATE ticket_chat_questions SET answer_json = 'false' WHERE question_key = ?", [blocked.question_key])
    assert_prepared_mixed_replay_rejected(replay)
    Store.query!(reopened, "UPDATE ticket_chat_questions SET answer_json = ? WHERE question_key = ?", [question["answer_json"], blocked.question_key])

    bad_receipt = Map.put(prepared_receipt, "answer_proof_sha256", String.duplicate("0", 64)) |> Jason.encode!()
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [bad_receipt, command["command_key"]])
    assert_prepared_mixed_replay_rejected(replay)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [application, command["command_key"]])

    legacy_shaped_mixed_receipt = Map.drop(prepared_receipt, ["answered_question_keys", "answer_proof_sha256"]) |> Jason.encode!()
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [legacy_shaped_mixed_receipt, command["command_key"]])
    assert_prepared_mixed_replay_rejected(replay)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [application, command["command_key"]])

    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = '[]' WHERE command_key = ?", [command["command_key"]])
    assert_prepared_mixed_public_replay_rejected(replay, :invalid_receipt)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [application, command["command_key"]])
    assert :ok = TicketChatCommands.validate_rework_replay(reopened, command["command_key"])

    Store.query!(reopened, "UPDATE ticket_chat_commands SET receipt_json = '[]' WHERE command_key = ?", [command["command_key"]])
    assert_prepared_mixed_public_replay_rejected(replay, :invalid_receipt)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET receipt_json = ? WHERE command_key = ?", [command["receipt_json"], command["command_key"]])
    assert :ok = TicketChatCommands.validate_rework_replay(reopened, command["command_key"])

    staging_receipts = Jason.decode!(input["staging_receipts_json"])
    staged_receipt = Map.fetch!(staging_receipts, command["command_key"])
    malformed_staging = Map.put(staging_receipts, command["command_key"], Map.delete(staged_receipt, "run_id")) |> Jason.encode!()
    Store.query!(reopened, "UPDATE ticket_chat_inputs SET staging_receipts_json = ? WHERE input_key = ?", [malformed_staging, input["input_key"]])
    assert_prepared_mixed_public_replay_rejected(replay, :blocked_resume_native_input_unproven)
    Store.query!(reopened, "UPDATE ticket_chat_inputs SET staging_receipts_json = ? WHERE input_key = ?", [input["staging_receipts_json"], input["input_key"]])
    assert :ok = TicketChatCommands.validate_rework_replay(reopened, command["command_key"])

    command_binding = Jason.decode!(command["binding_json"])
    malformed_binding = Map.delete(command_binding, "generation") |> Jason.encode!()
    Store.query!(reopened, "UPDATE ticket_chat_commands SET binding_json = ? WHERE command_key = ?", [malformed_binding, command["command_key"]])
    assert_prepared_mixed_public_replay_rejected(replay, :blocked_resume_native_input_unproven)
    Store.query!(reopened, "UPDATE ticket_chat_commands SET binding_json = ? WHERE command_key = ?", [command["binding_json"], command["command_key"]])
    assert :ok = TicketChatCommands.validate_rework_replay(reopened, command["command_key"])

    assert {:ok, %{launches: [launch], events: events}} = normal_poll(reopened_context, options, blocked.reader_options)
    assert launch.task_key == blocked.prior_task["task_key"]
    assert Enum.any?(events, &(&1.event == "TICKET_LAUNCHED"))
    resumed_thread = task_before_reopen["thread_id"]
    assert_receive {:factory_task_started, "run:feature-writer", ^resumed_thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    assert Store.one!(reopened, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key])["answer_json"] == "true"

    assert Store.query!(reopened, "SELECT request_key FROM worker_evidence WHERE task_key = ?", [blocked.prior_task["task_key"]]).rows |> List.flatten() |> Enum.sort() ==
             Enum.sort([blocked.prior_request, prepared_request])

    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM workspace_access WHERE request_key = ?", [prepared_request])["count"] == 1
    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => ^application}} = TicketChatCommands.get(reopened, blocked.staged["command_key"])
  end

  defp assert_prepared_mixed_public_replay_rejected(replay, expected_error) do
    store = replay.context.store
    command_key = replay.blocked.staged["command_key"]
    command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command_key])
    input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])

    before_read = %{
      command: command,
      input: input,
      questions: Store.query!(store, "SELECT * FROM ticket_chat_questions WHERE chat_key = ? ORDER BY question_key", [command["chat_key"]]).rows,
      run: Store.one!(store, "SELECT * FROM runs WHERE run_id = ?", [command["run_id"]]),
      tasks: Store.query!(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key", [command["run_id"]]).rows,
      evidence: Store.query!(store, "SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key", [command["run_id"]]).rows,
      access: Store.query!(store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key", [command["run_id"]]).rows,
      checkouts: Store.query!(store, "SELECT * FROM ticket_checkout_intents WHERE run_id = ? ORDER BY run_id", [command["run_id"]]).rows,
      events: Store.query!(store, "SELECT * FROM events WHERE run_id = ? ORDER BY id", [command["run_id"]]).rows
    }

    assert {:error, ^expected_error} = TicketChatCommands.validate_rework_replay(store, command_key)

    after_read = %{
      command: Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command_key]),
      input: Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]),
      questions: Store.query!(store, "SELECT * FROM ticket_chat_questions WHERE chat_key = ? ORDER BY question_key", [command["chat_key"]]).rows,
      run: Store.one!(store, "SELECT * FROM runs WHERE run_id = ?", [command["run_id"]]),
      tasks: Store.query!(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key", [command["run_id"]]).rows,
      evidence: Store.query!(store, "SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key", [command["run_id"]]).rows,
      access: Store.query!(store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key", [command["run_id"]]).rows,
      checkouts: Store.query!(store, "SELECT * FROM ticket_checkout_intents WHERE run_id = ? ORDER BY run_id", [command["run_id"]]).rows,
      events: Store.query!(store, "SELECT * FROM events WHERE run_id = ? ORDER BY id", [command["run_id"]]).rows
    }

    assert after_read == before_read
    refute_receive {:factory_task_started, "run:feature-writer", _}
  end

  defp assert_prepared_mixed_replay_rejected(replay) do
    %{
      context: context,
      options: options,
      blocked: blocked,
      task: task,
      request: request,
      run: run,
      access: access,
      evidence: evidence,
      original_file: original_file,
      index_path: index_path,
      original_index: original_index,
      file_path: file_path
    } = replay

    store = context.store
    question_before = Store.one!(store, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key])
    access_rows = Store.query!(store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task["run_id"]]).rows
    evidence_rows = Store.query!(store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task["task_key"]]).rows
    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, blocked.reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, unchanged_task} = TaskLedger.get(store, task["task_key"])
    assert unchanged_task == task
    assert Store.one!(store, "SELECT * FROM runs WHERE run_id = 'run'") == run
    assert Store.one!(store, "SELECT * FROM workspace_access WHERE request_key = ?", [request]) == access
    assert Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [request]) == evidence
    assert Store.query!(store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY generation", [task["run_id"]]).rows == access_rows
    assert Store.query!(store, "SELECT * FROM worker_evidence WHERE task_key = ? ORDER BY created_at", [task["task_key"]]).rows == evidence_rows
    assert Store.one!(store, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [blocked.question_key]) == question_before
    assert File.read!(file_path) == original_file
    assert File.read!(index_path) == original_index
    refute_receive {:factory_task_started, "run:feature-writer", _}
  end

  test "an ordinary RESERVED writer restart retains its normal packet", ctx do
    {context, options} = controller(ctx)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    empty_history = %{"id" => chat["thread_id"], "cwd" => chat["cwd"], "projectId" => nil, "turns" => []}
    {:ok, reader_options} = parent_reader_options(chat, empty_history)

    _interrupted =
      try do
        normal_poll(%{context | task_supervisor: nil}, options, reader_options)
      catch
        :exit, reason -> {:exit, reason}
      end

    {:ok, before_reopen} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert before_reopen["status"] == "STARTING"
    prepared_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' AND task_key = ? AND released_at IS NULL", [before_reopen["task_key"]])
    assert prepared_access["mode"] == "SOURCE"
    assert {:ok, ordinary_packet} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    ordinary_digest = :crypto.hash(:sha256, ordinary_packet) |> Base.encode16(case: :lower)
    assert before_reopen["prompt_sha256"] == ordinary_digest
    source_policy = TicketWorkerRunner.policy("SOURCE", prepared_access["canonical_path"])

    assert {:ok, prepared_attempt} =
             WorkerEvidence.reserve(ctx.store, %{
               "request_key" => prepared_access["request_key"],
               "task_key" => before_reopen["task_key"],
               "reservation_key" => prepared_access["reservation_key"],
               "input_sha256" => ordinary_digest,
               "owner_id" => "owner:" <> prepared_access["request_key"],
               "schema" => StageSchemas.for_stage(:native_feature_writer),
               "policy" => source_policy
             })

    assert prepared_attempt["status"] == "RESERVED"

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    reopened_context = %{context | store: reopened, task_supervisor: supervisor}

    assert {:ok, %{launches: [launch]}} = normal_poll(reopened_context, options, reader_options)
    assert launch.task_key == "run:feature-writer"
    assert_receive {:factory_task_started, "run:feature-writer", _thread}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [before_reopen["task_key"]])["count"] == 1
    assert Store.one!(reopened, "SELECT request_key FROM worker_evidence WHERE task_key = ?", [before_reopen["task_key"]])["request_key"] == prepared_access["request_key"]
  end

  test "a corrupted stopped result cannot transfer the blocked writer lease", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    prior_request = finish_worker(context, options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    assert {:ok, %{status: "BLOCKED", request_key: ^prior_request}} = Scheduler.ticket_step(context, "run", options)
    body = "Please rework the current candidate."
    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "corrupt-result", body, [%{"operation" => "request_rework"}])
    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, reader_options} = parent_reader_options(chat, readback)
    {:ok, before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    {:ok, before_evidence} = WorkerEvidence.get(ctx.store, prior_request)
    before_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [prior_request])
    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_sha256 = ? WHERE request_key = ?", [String.duplicate("f", 64), prior_request])

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert {:ok, ^before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [prior_request]) == before_access
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = 'run:feature-writer'")["count"] == 1

    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_sha256 = ? WHERE request_key = ?", [before_evidence["binding_sha256"], prior_request])
    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = ? WHERE task_key = ?", [Jason.encode!(%{"status" => "COMPLETE"}), before_task["task_key"]])
    {:ok, corrupted_task} = TaskLedger.get(ctx.store, before_task["task_key"])
    assert {:ok, %{launches: [], events: task_events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(task_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert {:ok, ^corrupted_task} = TaskLedger.get(ctx.store, before_task["task_key"])
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [prior_request]) == before_access
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = 'run:feature-writer'")["count"] == 1

    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = ? WHERE task_key = ?", [before_task["output_json"], before_task["task_key"]])
    Store.query!(ctx.store, "UPDATE factory_tasks SET prompt_sha256 = ? WHERE task_key = ?", [String.duplicate("e", 64), before_task["task_key"]])
    {:ok, changed_inputs_task} = TaskLedger.get(ctx.store, before_task["task_key"])
    assert {:ok, %{launches: [], events: input_events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(input_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert {:ok, ^changed_inputs_task} = TaskLedger.get(ctx.store, before_task["task_key"])
    assert {:ok, ^before_evidence} = WorkerEvidence.get(ctx.store, prior_request)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE request_key = ?", [prior_request]) == before_access
  end

  test "ready-parent polling applies an accepted answer from an earlier collection without launching source work", ctx do
    {context, options} = controller(ctx)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-poll", "body" => "Keep this candidate?", "answers" => %{"yes" => true}})
    body = "Answer Q-poll: yes"
    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "poll-answer", body, [%{"operation" => "answer_question", "question_key" => "Q-poll", "value" => true}])
    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, before_run} = RunLedger.get(ctx.store, "run")
    {:ok, reader_options} = parent_reader_options(chat, readback)

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_COMMAND_APPLIED"))

    command_key = staged["command_key"]
    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => receipt}} = TicketChatCommands.get(ctx.store, command_key)
    assert receipt != nil
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = 'Q-poll'") == %{"status" => "ANSWERED", "answer_json" => "true"}
    assert {:ok, ^before_run} = RunLedger.get(ctx.store, "run")
    assert {:error, :unknown_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE run_id = 'run'")["count"] == 0
    refute_receive {:factory_task_started, _, _}

    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-fresh", "body" => "Keep again?", "answers" => %{"yes" => true}})
    fresh_body = "Answer Q-fresh: yes"
    {:ok, fresh} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "fresh-answer", fresh_body, [%{"operation" => "answer_question", "question_key" => "Q-fresh", "value" => true}])
    fresh_readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body, fresh_body])
    {:ok, reader_options} = parent_reader_options(chat, fresh_readback)
    assert {:ok, %{launches: [], events: fresh_events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(fresh_events, &(&1.event == "TICKET_COMMAND_APPLIED"))
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(ctx.store, fresh["command_key"])
    assert {:ok, ^before_run} = RunLedger.get(ctx.store, "run")
    refute_receive {:factory_task_started, _, _}

    assert {:ok, %{launches: launches}} = normal_poll(context, options, reader_options)
    assert [%{task_key: "run:feature-writer"}] = launches
  end

  test "mixed accepted commands and readback failures defer without authorizing source work; absent input advances normally", ctx do
    {context, options} = controller(ctx)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-mixed-poll", "body" => "Keep?", "answers" => %{"yes" => true}})
    mixed_body = "Answer Q-mixed-poll: yes\nRework: current candidate"

    {:ok, staged} =
      SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "mixed-poll", mixed_body, [
        %{"operation" => "answer_question", "question_key" => "Q-mixed-poll", "value" => true},
        %{"operation" => "request_rework"}
      ])

    mixed = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [mixed_body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", mixed)
    {:ok, mixed_options} = parent_reader_options(chat, mixed)
    assert {:ok, %{launches: [], events: _events}} = normal_poll(context, options, mixed_options)
    key = staged["command_key"]
    assert key == staged["command_key"]
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed-poll'")["status"] == "OPEN"
    assert {:error, :unknown_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    refute_receive {:factory_task_started, _, _}

    Process.put(:ticket_chat_parent_readback, {:error, :native_history_unavailable})
    assert {:ok, %{launches: [], events: _events}} = normal_poll(context, options, mixed_options)
    assert {:error, :unknown_task} = TaskLedger.get(ctx.store, "run:feature-writer")
  end

  test "ready-parent polling with no direct input retains normal role advancement", ctx do
    {context, options} = controller(ctx)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    empty = %{"id" => chat["thread_id"], "cwd" => chat["cwd"], "projectId" => nil, "turns" => []}
    {:ok, empty_options} = parent_reader_options(chat, empty)
    assert {:ok, %{launches: [launch]}} = normal_poll(context, options, empty_options)
    assert launch.task_key == "run:feature-writer"
    assert_receive {:factory_task_started, "run:feature-writer", _}, 15_000
    assert_receive {:factory_task_finished, "run:feature-writer", {:ok, _}}, 60_000
    [[request]] = Store.query!(ctx.store, "SELECT request_key FROM worker_evidence WHERE task_key = ?", [launch.task_key]).rows
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)

    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-history", "body" => "Keep?", "answers" => %{"yes" => true}})
    rejected_body = "Answer Q-history: no"

    {:ok, rejected} =
      SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "rejected-history", rejected_body, [%{"operation" => "answer_question", "question_key" => "Q-history", "value" => true}])

    history = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [rejected_body])
    {:ok, history_options} = parent_reader_options(chat, history)
    assert {:ok, %{launches: []}} = normal_poll(context, options, history_options)
    assert {:ok, %{"status" => "REJECTED"}} = TicketChatCommands.get(ctx.store, rejected["command_key"])
    assert {:ok, %{launches: [], events: replay_events}} = normal_poll(context, options, history_options)
    assert Enum.any?(replay_events, &(&1.event == "TICKET_ADOPTED"))
  end

  test "an answer applied to a blocked writer does not resume or adopt the source task", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "blocked"})
    request = finish_worker(context, options)
    {:ok, chat} = TicketChat.ready_for_run(ctx.store, "run")
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-blocked", "body" => "Continue later?", "answers" => %{"yes" => true}})
    body = "Answer Q-blocked: yes"
    {:ok, staged} = SymphonyElixir.TicketChatFixture.stage(%{store: ctx.store}, "blocked-answer", body, [%{"operation" => "answer_question", "question_key" => "Q-blocked", "value" => true}])
    readback = SymphonyElixir.TicketChatFixture.native(%{store: ctx.store, cwd: chat["cwd"], root: ctx.root}, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, before_run} = RunLedger.get(ctx.store, "run")
    {:ok, before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    {:ok, before_evidence} = WorkerEvidence.get(ctx.store, request)
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows
    {:ok, reader_options} = parent_reader_options(chat, readback)

    assert {:ok, %{launches: [], events: events}} = normal_poll(context, options, reader_options)
    assert Enum.any?(events, &(&1.event == "TICKET_COMMAND_APPLIED"))
    assert staged["command_key"]
    assert {:ok, ^before_run} = RunLedger.get(ctx.store, "run")
    assert {:ok, ^before_task} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert {:ok, ^before_evidence} = WorkerEvidence.get(ctx.store, request)
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE released_at IS NULL").rows == access_before
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_NATIVE_WRITER_BLOCKED'")["count"] == 0
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-blocked'")["status"] == "ANSWERED"
    refute_receive {:factory_task_started, _, _}
  end

  test "writer admission preserves the candidate and checkout when authority, capacity or root rejects", ctx do
    {context, options} = controller(ctx)
    {:ok, %{run: before}} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER"})

    Store.query!(ctx.store, "DELETE FROM ticket_review_bases WHERE run_id = 'run'")
    assert {:error, :ticket_writer_admission_unproven} = TicketWorkerRunner.writer_admission_facts(ctx.store, before, options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)

    cases = [
      {Keyword.put(options, :free_bytes, 19_999_999_999), :insufficient_writer_capacity},
      {Keyword.put(options, :jira_reader, BlockedJiraReader), :ticket_jira_not_dispatchable},
      {Keyword.put(options, :workspace_root, ctx.repo), :workspace_outside_allowed_root}
    ]

    for {rejected, reason} <- cases do
      assert {:error, ^reason} = Scheduler.ticket_step(context, "run", rejected)
      assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
      assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
      assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
      assert {:error, :unknown_task} = TaskLedger.get(ctx.store, "run:feature-writer")
      assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      refute_receive {:factory_task_started, _, _}
    end

    {:ok, snapshot} = JiraReader.issue("PPL-123", store: ctx.store)
    assert {:ok, expired} = TicketWorkerRunner.authorization(before, snapshot, DateTime.add(DateTime.utc_now(), -61))
    assert {:error, :ticket_authorization_expired} = TicketWorkerRunner.admit_writer(ctx.store, before, expired, options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    refute_receive {:factory_task_started, _, _}
  end

  test "initial checkout admission is a bounded scheduler step before planning and writing", ctx do
    {context, options} = initial_controller(ctx)
    capacity = options[:capacity_policy]["capacity"] |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    context = %{context | factory: Map.merge(context.factory, Map.put(capacity, :cleanup, %{}))}
    options = Keyword.drop(options, [:workspace_root, :capacity_policy])
    assert {:ok, %{status: "CHECKOUT_ADMITTED", model_invoked: false, run: admitted}} = Scheduler.ticket_step(context, "run", options)
    assert admitted["state"] == "PLANNING"
    assert admitted["candidate_sha"] == nil
    assert admitted["worktree"] != ctx.path
    assert git(admitted["worktree"], ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    refute_receive {:factory_task_started, _, _}
    planned = complete_stage(context, options)
    assert planned["state"] == "ADMITTING_WRITER"
    assert {:ok, %{status: "WRITER_ADMITTED", run: writer}} = Scheduler.ticket_step(context, "run", options)
    assert writer["worktree"] == admitted["worktree"]
    assert Store.query!(ctx.store, "SELECT DISTINCT workspace FROM factory_tasks").rows == [[admitted["worktree"]]]
    implemented = complete_stage(context, options)
    assert implemented["state"] == "WRITING"
    assert implemented["implementation_iteration"] == 1
    assert implemented["worktree"] == admitted["worktree"]
  end

  test "scheduler recovers completed initial creation using its pin despite changed caller base", ctx do
    {context, options} = initial_controller(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    {:ok, prepared} = TicketCheckout.reserve(ctx.store, "run", authorization, options)
    {recovery_context, tick_opts} = tick_controller(context, options)
    recovery_context = put_in(recovery_context, [:factory, :ticket_supervisor, "enabled"], false)
    assert {:ok, %{launches: [], events: []}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    assert {:ok, ^prepared} = TicketCheckout.get(ctx.store, "run")
    {:ok, intent} = TicketCheckout.claim(ctx.store, "run", authorization, options)
    {:ok, execution} = TicketCheckoutIO.prepare(ctx.store, intent, authorization)

    assert {:ok, _} =
             TicketCheckoutIO.execute(execution, fn pid, encoded ->
               Store.query!(ctx.store, "UPDATE ticket_checkout_intents SET helper_pid = ?, execution_json = ? WHERE run_id = 'run'", [pid, encoded])
               TicketCheckout.get(ctx.store, "run")
             end)

    {:ok, original} = TicketCheckout.get(ctx.store, "run")
    changed = Keyword.put(options, :base_sha, String.duplicate("0", 40))
    {:ok, reopened} = Store.start_link(database: ctx.database)

    admitted =
      try do
        recovery_context = %{recovery_context | store: reopened, ticket_options: changed}

        assert {:ok, %{launches: [], events: rejected}} =
                 Scheduler.reconcile_ticket_jira(recovery_context, Keyword.put(tick_opts, :jira_reader, CheckoutDriftReader))

        assert Enum.any?(rejected, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_checkout_intent_changed"))
        assert {:ok, ^run} = RunLedger.get(reopened, "run")
        Store.query!(reopened, "UPDATE ticket_checkout_intents SET owner_nonce = ? WHERE run_id = 'run'", [original["owner_nonce"]])
        assert {:ok, %{launches: [], events: events}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
        assert Enum.any?(events, &(&1.event == "TICKET_CHECKOUT_ADMITTED"))
        assert {:ok, admitted} = RunLedger.get(reopened, "run")
        assert {:ok, %{launches: [], events: []}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
        admitted
      after
        GenServer.stop(reopened)
      end

    assert admitted["state"] == "PLANNING"
    {:ok, ready} = TicketCheckout.get(ctx.store, "run")
    assert ready["owner_nonce"] == original["owner_nonce"]
    assert ready["helper_pid"] == original["helper_pid"]
    assert ready["execution_json"] == original["execution_json"]
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    refute_receive {:factory_task_started, _, _}
  end

  test "initial checkout rejection and missing receipt never dispatch source or retry creation", ctx do
    {context, options} = initial_controller(ctx)
    assert {:ok, before} = RunLedger.get(ctx.store, "run")
    bases = Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows

    cases = [
      {Keyword.put(options, :free_bytes, 19_999_999_999), :insufficient_writer_capacity},
      {Keyword.put(options, :jira_reader, BlockedJiraReader), :ticket_jira_not_dispatchable},
      {Keyword.put(options, :workspace_root, ctx.repo), :ticket_checkout_binding_unproven}
    ]

    for {rejected, reason} <- cases do
      assert {:error, ^reason} = Scheduler.ticket_step(context, "run", rejected)
      assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
      assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows == []
    end

    trace = SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, %{})
    assert {:error, :worker_runtime_identity_unproven} = Scheduler.ticket_step(context, "run", options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_review_bases").rows == bases
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)

    {:ok, snapshot} = JiraReader.issue(before["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(before, snapshot, DateTime.utc_now())
    {:ok, intent} = TicketCheckout.claim(ctx.store, "run", authorization, options)
    observations = File.read!(trace)

    for _ <- 1..2 do
      assert {:error, :ticket_checkout_execution_unproven} = Scheduler.ticket_step(context, "run", options)
      {:ok, current} = TicketCheckout.get(ctx.store, "run")
      assert current["owner_nonce"] == intent["owner_nonce"]
      assert current["helper_pid"] == nil
      refute File.exists?(current["canonical_path"])
      assert File.read!(trace) == observations
    end

    {recovery_context, tick_opts} = tick_controller(context, options)
    recovery_context = put_in(recovery_context, [:factory, :ticket_supervisor, "enabled"], false)
    assert {:ok, %{launches: [], events: events}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_checkout_execution_unproven"))
    assert {:ok, %{"phase" => "RECONCILE_REQUIRED", "owner_nonce" => owner}} = TicketCheckout.get(ctx.store, "run")
    assert owner == intent["owner_nonce"]
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert File.read!(trace) == observations

    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    refute_receive {:factory_task_started, _, _}
  end

  defp initial_controller(ctx) do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER", worktree: nil, candidate_sha: nil, branch: "cgable/new-initial"})
    {context, Keyword.put(options, :base_sha, ctx.sha)}
  end

  test "run drift during checkout runtime initialization cannot claim a new checkout", ctx do
    {context, options} = initial_controller(ctx)
    command = "/usr/bin/sqlite3 '#{ctx.database}' \"UPDATE runs SET state = 'BLOCKED' WHERE run_id = 'run'\" || exit 1"
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, :supported, command)
    assert {:error, :ticket_checkout_run_changed} = Scheduler.ticket_step(context, "run", options)
    assert {:ok, %{"state" => "BLOCKED", "worktree" => nil}} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows == []
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
    refute_receive {:factory_task_started, _, _}
  end

  defp tick_controller(context, options) do
    factory =
      Map.merge(context.factory, %{
        enabled: true,
        scope: "scope",
        task_transport: "desktop_broker",
        stale_task_minutes: 90,
        maximum_specifiers: 2,
        maximum_writers: 2,
        maximum_validators: 2,
        writer_disk_gb: 20,
        cleanup: %{},
        queue: %{"assignee" => "currentUser()", "statuses" => ["To Do", "In Dev"], "factory_labels" => ["ai-ready", "ai-running"]},
        ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}
      })

    context = Map.merge(context, %{factory: factory, ticket_options: options})
    {context, [jira_reader: JiraReader]}
  end

  test "normal ticks create one pinned checkout and advance planner, writer and verifier one action at a time", ctx do
    remote = Path.join(ctx.root, "tick-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {context, options} = initial_controller(ctx)
    Store.query!(ctx.store, "DELETE FROM ticket_review_bases WHERE run_id = 'run'")
    {context, tick_opts} = tick_controller(context, Keyword.delete(options, :base_sha))
    {:ok, parent_reader} = empty_parent_reader_options(ctx.store, "run")
    tick_opts = Keyword.merge(tick_opts, parent_reader)
    context = %{context | ticket_options: Keyword.merge(context.ticket_options, parent_reader)}
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_CHECKOUT_ADMITTED"))
    {:ok, checkout} = RunLedger.get(ctx.store, "run")
    assert checkout["state"] == "PLANNING"
    assert Store.one!(ctx.store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = 'run'")["base_sha"] == ctx.sha

    for expected <- ["ADMITTING_WRITER", "WRITING", "VERIFYING", "PUSHING"] do
      assert {:ok, %{launches: [launch]}} = Scheduler.tick(context, tick_opts)
      key = launch.task_key
      assert_receive {:factory_task_started, ^key, _}, 15_000
      assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000
      assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
      {:ok, run} = RunLedger.get(ctx.store, "run")
      assert run["state"] == expected

      if expected == "ADMITTING_WRITER" do
        assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
        assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(ctx.store, "run")
      end
    end

    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_PUSH_COMPLETED"))
    assert {:ok, %{"state" => "MR_CREATING", "worktree" => path} = pushed} = RunLedger.get(ctx.store, "run")
    assert {:ok, remote_sha} = Worktree.read_remote_branch(%{"path" => ctx.repo}, pushed["branch"])
    assert remote_sha == pushed["candidate_sha"]
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    assert path == checkout["worktree"]
    assert Store.query!(ctx.store, "SELECT DISTINCT workspace FROM factory_tasks").rows == [[path]]
    assert git(path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == "2"

    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    assert {:ok, %{run: ^run, verifier: evidence}} = TicketWorkerRunner.delivery_admission(ctx.store, run, authorization, context.ticket_options)
    assert evidence["status"] == "CONSUMED"
    frozen = Enum.map(~w(runs factory_tasks workspace_access worker_evidence events), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    assert {:ok, %{run: ^run, verifier: ^evidence}} = TicketWorkerRunner.delivery_facts(ctx.store, run, context.ticket_options)
    assert Enum.map(~w(runs factory_tasks workspace_access worker_evidence events), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen
    assert_unresolved_delivery_check(ctx, run, context.ticket_options, frozen)
    assert {:error, :ticket_authorization_required} = TicketWorkerRunner.delivery_admission(ctx.store, run, nil, context.ticket_options)
    review_readback = Map.put(snapshot, "labels", ~w(ai-review repo-grail))
    rejected = TicketWorkerRunner.authorization(run, review_readback, DateTime.utc_now())
    assert rejected == {:error, :ticket_jira_not_dispatchable}
    review_proof = Map.put(authorization, "snapshot_json", Jason.encode!(review_readback))
    assert {:error, :ticket_jira_not_dispatchable} = TicketWorkerRunner.delivery_admission(ctx.store, run, review_proof, context.ticket_options)

    for {proof, gate_opts, reason} <- [
          {Map.put(authorization, "observed_at", "2020-01-01T00:00:00Z"), context.ticket_options, :ticket_authorization_expired},
          {authorization, Keyword.delete(context.ticket_options, :workspace_root), :ticket_delivery_workspace_root_required},
          {authorization, Keyword.put(context.ticket_options, :reservation, %{}), :ticket_delivery_reservation_invalid},
          {authorization, Keyword.put(context.ticket_options, :workspace_root, ctx.repo), :workspace_outside_allowed_root}
        ] do
      assert {:error, ^reason} = TicketWorkerRunner.delivery_admission(ctx.store, run, proof, gate_opts)
    end

    Store.query!(ctx.store, "UPDATE worker_evidence SET status = 'RESULT_RECORDED' WHERE request_key = ?", [evidence["request_key"]])
    assert {:error, :ticket_delivery_worker_unconsumed} = TicketWorkerRunner.delivery_admission(ctx.store, run, authorization, context.ticket_options)
    Store.query!(ctx.store, "UPDATE worker_evidence SET status = 'CONSUMED' WHERE request_key = ?", [evidence["request_key"]])
    verifier_key = "run:change-verifier:#{run["verifier_round"]}"
    {:ok, _} = TaskLedger.update(ctx.store, verifier_key, %{status: "COMPLETE"})
    assert {:error, :ticket_delivery_verifier_pass_unproven} = TicketWorkerRunner.delivery_admission(ctx.store, run, authorization, context.ticket_options)
    {:ok, _} = TaskLedger.update(ctx.store, verifier_key, %{status: "CONSUMED"})
    dirty = Path.join(path, "untracked.txt")
    File.write!(dirty, "untracked\n")
    assert {:error, _} = TicketWorkerRunner.delivery_admission(ctx.store, run, authorization, context.ticket_options)
    File.rm!(dirty)
    assert {:ok, _} = TicketWorkerRunner.delivery_admission(ctx.store, run, authorization, context.ticket_options)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")

    {:ok, _} = TaskLedger.update(ctx.store, verifier_key, %{status: "COMPLETE"})
    {:ok, %{run: preflight}} = RunLedger.update(ctx.store, "run", %{state: "CI_PUSHING"})
    assert {:error, :ticket_ci_preflight_not_authorized} = TicketWorkerRunner.delivery_admission(ctx.store, preflight, authorization, context.ticket_options)
    preflight_opts = Keyword.put(context.ticket_options, :ci_preflight_authorized, true)
    assert {:ok, %{verifier: nil}} = TicketWorkerRunner.delivery_admission(ctx.store, preflight, authorization, preflight_opts)

    for state <- ~w(CI_MR_CREATING CI_WAITING) do
      {:ok, %{run: unpinned}} = RunLedger.update(ctx.store, "run", %{state: state, ci_preflight_sha: ctx.sha})
      assert {:error, :ticket_ci_preflight_candidate_unproven} = TicketWorkerRunner.delivery_admission(ctx.store, unpinned, authorization, preflight_opts)
      {:ok, %{run: pinned}} = RunLedger.update(ctx.store, "run", %{ci_preflight_sha: run["candidate_sha"]})
      assert {:ok, %{verifier: nil}} = TicketWorkerRunner.delivery_admission(ctx.store, pinned, authorization, preflight_opts)
    end

    {:ok, %{run: unchecked}} = RunLedger.update(ctx.store, "run", %{state: "CI_PUSHING", candidate_sha: ctx.sha})
    assert {:error, :ticket_delivery_candidate_check_unproven} = TicketWorkerRunner.delivery_admission(ctx.store, unchecked, authorization, preflight_opts)
  end

  defp assert_unresolved_delivery_check(ctx, run, options, frozen) do
    Store.query!(
      ctx.store,
      """
      INSERT INTO controller_checks (check_key, worker_request_key, reservation_key, binding_json, binding_sha256, phase)
      SELECT 'fixture-unresolved-check', worker_request_key, reservation_key, binding_json, binding_sha256, 'RUNNING'
      FROM controller_checks WHERE phase = 'COMPLETE' LIMIT 1
      """
    )

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM controller_checks WHERE check_key = 'fixture-unresolved-check'")["count"] == 1
    assert {:error, :controller_checks_unreconciled} = TicketWorkerRunner.delivery_facts(ctx.store, run, options)
    assert Enum.map(~w(runs factory_tasks workspace_access worker_evidence events), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen
    assert git(run["worktree"], ["rev-parse", "HEAD"]) |> String.trim() == run["candidate_sha"]
    Store.query!(ctx.store, "DELETE FROM controller_checks WHERE check_key = 'fixture-unresolved-check'")
    assert {:ok, _} = TicketWorkerRunner.delivery_facts(ctx.store, run, options)
  end

  test "disabled normal tick leaves completed worker evidence unconsumed and launches no next turn", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)
    {context, tick_opts} = tick_controller(context, options)
    disabled = put_in(context, [:factory, :ticket_supervisor, "enabled"], false)
    assert {:ok, %{launches: []}} = Scheduler.tick(disabled, tick_opts)
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
    assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(ctx.store, "run")
    refute_receive {:factory_task_started, _, _}
  end

  test "normal tick isolates an adoption exception and preserves evidence for retry", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)
    {context, tick_opts} = tick_controller(context, options)
    {:ok, parent_reader} = empty_parent_reader_options(ctx.store, "run")
    tick_opts = Keyword.merge(tick_opts, parent_reader)
    context = %{context | ticket_options: Keyword.merge(context.ticket_options, parent_reader)}
    Store.query!(ctx.store, "CREATE TRIGGER fail_tick_release BEFORE UPDATE OF released_at ON workspace_access BEGIN SELECT RAISE(ABORT, 'release failure'); END")
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED" and String.contains?(&1.detail, "Exqlite.Error")))
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 0}} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "DROP TRIGGER fail_tick_release")
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_ADOPTED"))
    assert {:ok, %{"state" => "VERIFYING", "implementation_iteration" => 1}} = RunLedger.get(ctx.store, "run")
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == "1"
  end

  @tag recovered_bootstrap: true
  test "explicit impossible-v1 recovery retains the original envelope and admits a new nonce", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "recovery-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    proof = push_authorization(ctx.store, run)
    {:ok, claimed} = TicketPush.claim(ctx.store, "run", proof, options)
    {:ok, execution} = TicketPushIO.prepare(ctx.store, claimed, proof)
    binding_json = claimed["binding_json"] |> Jason.decode!() |> Map.delete("bootstrap_recovery") |> Jason.encode!()
    binding_sha = Base.encode16(:crypto.hash(:sha256, binding_json), case: :lower)
    old_key = claimed["reservation_key"]
    historical_key = "ticket-push:" <> binding_sha
    access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [old_key])
    access_binding = access["binding_json"] |> Jason.decode!() |> Map.merge(%{"reservation_key" => historical_key, "request_key" => historical_key}) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE workspace_access SET reservation_key = ?, request_key = ?, binding_json = ? WHERE reservation_key = ?", [historical_key, historical_key, access_binding, old_key])
    claimed = Map.merge(claimed, %{"binding_json" => binding_json, "binding_sha256" => binding_sha, "reservation_key" => historical_key})
    legacy = Path.expand("../../priv/ticket_push_executor.py", __DIR__)

    execution =
      Map.merge(execution, %{
        "intent_json" => binding_json,
        "intent_sha256" => binding_sha,
        "helper_path" => legacy,
        "helper_sha256" => Base.encode16(:crypto.hash(:sha256, File.read!(legacy)), case: :lower)
      })

    original = claimed |> Map.merge(%{"helper_pid" => 123, "execution_json" => Jason.encode!(execution)}) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [original])
    intent = Jason.decode!(original)
    assert {:ok, attestation} = TicketPushIO.unissuable_v1_proof(intent)
    assert Jason.decode!(attestation)["kind"] == "CONTROLLER_UNISSUABLE_V1"
    refute TicketPushIO.receipt_valid?(attestation, intent)

    for invalid <- [put_in(intent, ["execution_json"], "{}"), Map.put(intent, "binding_json", "{}"), Map.put(intent, "owner_nonce", "invalid")] do
      assert {:error, :ticket_push_unissuable_v1_unproven} = TicketPushIO.unissuable_v1_proof(invalid)
    end

    conflict = Path.join(execution["spool"], intent["owner_nonce"] <> ".push-claim")
    File.write!(conflict, "contradictory fixture")
    assert {:error, :ticket_push_unissuable_v1_unproven} = TicketPushIO.unissuable_v1_proof(intent)
    File.rm!(conflict)
    assert {:ok, %{status: "UNISSUABLE_RECORDED"}} = TicketPush.recover_unissuable_v1(ctx.store, "run", proof, options)
    event = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE event_type = 'TICKET_PUSH_UNISSUABLE_V1'")
    assert Jason.decode!(event["payload_json"])["original_envelope"] == original
    {:ok, successor} = TicketPush.prepare(ctx.store, "run", proof, options)
    assert successor["owner_nonce"] != intent["owner_nonce"]
    assert {:ok, %{status: "PUSH_COMPLETED"}} = TicketPush.step(ctx.store, "run", proof, options)
    assert Worktree.read_remote_branch(%{"path" => ctx.repo}, run["branch"]) == {:ok, run["candidate_sha"]}
  end

  @tag recovered_bootstrap: true
  test "push intent owns one recovered-parent checkout and remains once-only across ledger restart", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "push-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    assert {:error, :ticket_push_recovery_unissued} = TicketPush.reconcile(ctx.store, "run", authorization, options)
    assert {:ok, prepared} = TicketPush.prepare(ctx.store, "run", authorization, options)
    assert prepared["phase"] == "PREPARED"
    assert {:error, :ticket_push_recovery_unissued} = TicketPush.reconcile(ctx.store, "run", authorization, options)
    {recovery_context, tick_opts} = tick_controller(context, options)
    recovery_context = put_in(recovery_context, [:factory, :ticket_supervisor, "enabled"], false)
    assert {:ok, %{launches: [], events: []}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    {:ok, prepared_run} = RunLedger.get(ctx.store, "run")

    for raw <- ["not json", "[]", "null", "{}"] do
      Store.query!(ctx.store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [raw])
      assert {:ok, %{launches: [], events: []}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
      assert Store.one!(ctx.store, "SELECT candidate_handoff FROM runs WHERE run_id = 'run'")["candidate_handoff"] == raw
    end

    Store.query!(ctx.store, "UPDATE runs SET candidate_handoff = 'null' WHERE run_id = 'run'")
    assert {:error, :ticket_push_intent_invalid} = TicketPush.prepare(ctx.store, "run", authorization, options)
    assert Store.one!(ctx.store, "SELECT candidate_handoff FROM runs WHERE run_id = 'run'")["candidate_handoff"] == "null"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1

    Store.query!(ctx.store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [prepared_run["candidate_handoff"]])
    assert {:ok, ^prepared} = TicketPush.prepare(ctx.store, "run", authorization, options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    assert {:error, :candidate_handoff_controller_owned} = RunLedger.update(ctx.store, "run", %{candidate_handoff: nil})
    assert {:ok, claimed} = TicketPush.claim(ctx.store, "run", authorization, options)
    assert claimed["phase"] == "PUSH_UNCERTAIN"
    assert {:error, :ticket_push_already_issued} = TicketPush.claim(ctx.store, "run", authorization, options)
    assert String.trim(git(ctx.repo, ["ls-remote", "origin", "refs/heads/" <> run["branch"]])) == ""
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, database: ctx.database})
    assert {:ok, ^claimed} = TicketPush.prepare(store, "run", authorization, options)
    assert {:error, :ticket_push_already_issued} = TicketPush.claim(store, "run", authorization, options)
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    assert {:ok, execution} = TicketPushIO.prepare(store, claimed, authorization)
    publication_failure = fn _pid, _encoded -> raise "fixture publication failed" end
    assert {:error, :ticket_push_transport_unproven} = TicketPushIO.execute(execution, publication_failure)
    assert {:ok, ^claimed} = TicketPush.prepare(store, "run", authorization, options)
    assert {:error, :ticket_push_already_issued} = TicketPush.claim(store, "run", authorization, options)
    assert String.trim(git(ctx.repo, ["ls-remote", "origin", "refs/heads/" <> run["branch"]])) == ""
    assert {:ok, after_restart} = RunLedger.get(store, "run")
    assert Map.take(after_restart, ~w(state candidate_sha worktree branch implementation_iteration)) == Map.take(run, ~w(state candidate_sha worktree branch implementation_iteration))
    assert String.trim(git(ctx.repo, ["ls-remote", "origin", "refs/heads/" <> run["branch"]])) == ""

    original = after_restart["candidate_handoff"]

    for {corrupt, reason} <- [
          {Map.put(claimed, "owner_nonce", "bad"), :ticket_push_intent_invalid},
          {Map.put(claimed, "binding_sha256", "bad"), :ticket_push_binding_corrupt},
          {Map.put(claimed, "reservation_key", "unrelated"), :ticket_push_reservation_changed},
          {Map.put(claimed, "phase", "SUCCEEDED"), :ticket_push_phase_invalid},
          {Map.put(claimed, "unexpected", true), :ticket_push_intent_invalid},
          {Map.put(claimed, "receipt_json", "premature"), :ticket_push_intent_invalid}
        ] do
      raw = Jason.encode!(corrupt)
      Store.query!(store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [raw])
      assert {:error, ^reason} = TicketPush.prepare(store, "run", authorization, options)
      assert Store.one!(store, "SELECT candidate_handoff FROM runs WHERE run_id = 'run'")["candidate_handoff"] == raw
      assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    end

    Store.query!(store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [original])
    git(ctx.repo, ["config", "remote.origin.url", "https://fixture.invalid/repository.git"])
    assert {:error, :ticket_push_binding_changed} = TicketPush.prepare(store, "run", authorization, options)
    git(ctx.repo, ["config", "remote.origin.url", remote])
    assert {:ok, ^claimed} = TicketPush.prepare(store, "run", authorization, options)

    Store.query!(store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [ctx.sha])
    assert {:error, _} = TicketPush.prepare(store, "run", authorization, options)
    assert Store.one!(store, "SELECT candidate_handoff FROM runs WHERE run_id = 'run'")["candidate_handoff"] == original
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    Store.query!(store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [run["candidate_sha"]])

    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: store)
    {:ok, authorization} = TicketWorkerRunner.authorization(after_restart, snapshot, DateTime.utc_now())
    assert {:ok, execution} = TicketPushIO.prepare(store, claimed, authorization)
    original_socket = System.get_env("SSH_AUTH_SOCK")
    socket = Path.join(ctx.root, "synthetic-auth-agent.sock")

    try do
      System.put_env("SSH_AUTH_SOCK", socket)
      assert {:ok, forwarded} = TicketPushIO.prepare(store, claimed, authorization)
      assert forwarded["git_environment"]["SSH_AUTH_SOCK"] == socket
      assert Map.delete(forwarded["git_environment"], "SSH_AUTH_SOCK") == Map.delete(execution["git_environment"], "SSH_AUTH_SOCK")
    after
      if original_socket, do: System.put_env("SSH_AUTH_SOCK", original_socket), else: System.delete_env("SSH_AUTH_SOCK")
    end

    assert {:ok, raw} =
             TicketPushIO.execute(execution, fn pid, encoded ->
               TicketPush.attach_execution(store, "run", pid, encoded, authorization, options)
             end)

    {:ok, executed} = RunLedger.get(store, "run")
    invoked = Jason.decode!(executed["candidate_handoff"])
    receipt = Jason.decode!(raw)
    diagnostic = Map.take(receipt, ~w(helper_pid child_pid termination timed_out overflow)) |> Map.put("execution_matches", receipt["execution_json"] == invoked["execution_json"])
    assert TicketPushIO.receipt_valid?(raw, invoked), inspect(diagnostic)

    for binding <- ["not json", "[]", "null", "{}"] do
      refute TicketPushIO.receipt_valid?(raw, Map.put(invoked, "binding_json", binding))
    end

    assert Jason.decode!(raw)["termination"] == %{"kind" => "exited", "code" => 0}
    assert {:ok, ^raw} = TicketPushIO.readback(invoked)

    assert {:error, :ticket_push_transport_unproven} =
             TicketPushIO.execute(execution, fn _pid, _encoded -> {:ok, %{}} end)

    assert {:ok, ^raw} = TicketPushIO.readback(invoked)
    assert {:ok, candidate} = Worktree.read_remote_branch(%{"path" => ctx.repo}, run["branch"])
    assert candidate == run["candidate_sha"]

    assert {:error, :ticket_push_execution_already_bound} =
             TicketPushIO.execute(execution, fn pid, encoded ->
               TicketPush.attach_execution(store, "run", pid, encoded, authorization, options)
             end)

    assert {:ok, ^raw} = TicketPushIO.readback(invoked)
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    completed = Map.merge(invoked, %{"phase" => "COMPLETED", "receipt_json" => raw, "receipt_sha256" => Base.encode16(:crypto.hash(:sha256, raw), case: :lower), "remote_sha" => run["candidate_sha"]})
    binding = Jason.decode!(invoked["binding_json"])

    for foreign <- [
          Map.put(binding, "run_id", "another-run"),
          Map.put(binding, "candidate_sha", String.duplicate("1", 40)),
          put_in(binding, ["checkout", "git_dir"], "/foreign/git")
        ] do
      forged = Map.put(completed, "binding_json", Jason.encode!(foreign))
      Store.query!(store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [Jason.encode!(forged)])

      assert {:error, :controller_push_binding_unproven} =
               WorkspaceAccess.release_push(store, "run", invoked["reservation_key"], invoked["reservation_generation"])

      assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    end

    execution_binding = Jason.decode!(invoked["execution_json"])

    for field <- ~w(run_id intent_json intent_sha256 invocation) do
      forged = put_in(completed, ["execution_json"], Jason.encode!(Map.put(execution_binding, field, "foreign")))
      Store.query!(store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [Jason.encode!(forged)])

      assert {:error, :controller_push_binding_unproven} =
               WorkspaceAccess.release_push(store, "run", invoked["reservation_key"], invoked["reservation_generation"])

      assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    end

    Store.query!(store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [executed["candidate_handoff"]])
    Store.query!(store, "CREATE TRIGGER fail_push_release BEFORE UPDATE OF released_at ON workspace_access WHEN OLD.mode = 'MAINTENANCE' BEGIN SELECT RAISE(ABORT, 'release failure'); END")
    assert_raise Exqlite.Error, fn -> TicketPush.reconcile(store, "run", authorization, options) end
    assert {:ok, %{"state" => "PUSHING", "candidate_handoff" => unchanged}} = RunLedger.get(store, "run")
    assert Jason.decode!(unchanged)["phase"] == "PUSH_UNCERTAIN"
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    Store.query!(store, "DROP TRIGGER fail_push_release")
    :ok = stop_supervised(Store)
    recovered = start_supervised!({Store, database: ctx.database})
    recovery_context = %{recovery_context | store: recovered}

    assert {:ok, %{launches: [], events: rejected}} =
             Scheduler.reconcile_ticket_jira(recovery_context, Keyword.put(tick_opts, :jira_reader, PushDriftReader))

    assert Enum.any?(rejected, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_push_intent_changed"))
    assert Store.one!(recovered, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    Store.query!(recovered, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [unchanged])
    assert {:ok, %{launches: [], events: events}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_PUSH_COMPLETED"))
    assert {:ok, delivered} = RunLedger.get(recovered, "run")
    assert delivered["state"] == "MR_CREATING" and delivered["candidate_sha"] == run["candidate_sha"]
    assert Store.one!(recovered, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    complete = Jason.decode!(delivered["candidate_handoff"])
    before_proof = Store.query!(recovered, "SELECT * FROM workspace_access ORDER BY reservation_key").rows
    assert {:error, :ticket_push_recovery_unissued} = TicketPush.reconcile(recovered, "run", authorization, options)
    assert {:ok, ^delivered} = RunLedger.get(recovered, "run")
    assert Store.query!(recovered, "SELECT * FROM workspace_access ORDER BY reservation_key").rows == before_proof
    assert {:ok, %{launches: [], events: []}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    Store.query!(recovered, "UPDATE runs SET candidate_handoff = 'null' WHERE run_id = 'run'")
    assert {:error, :ticket_push_completion_unproven} = TicketPush.completed_proof(recovered, "run")
    assert Store.one!(recovered, "SELECT candidate_handoff FROM runs WHERE run_id = 'run'")["candidate_handoff"] == "null"
    assert Store.query!(recovered, "SELECT * FROM workspace_access ORDER BY reservation_key").rows == before_proof
    Store.query!(recovered, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [delivered["candidate_handoff"]])
    proof = TicketPush.completed_proof(recovered, "run")
    assert {:ok, %{intent: ^complete, binding: proven, envelope_sha256: digest}} = proof
    assert proven["candidate_sha"] == delivered["candidate_sha"]
    assert digest == Base.encode16(:crypto.hash(:sha256, delivered["candidate_handoff"]), case: :lower)
    assert Store.query!(recovered, "SELECT * FROM workspace_access ORDER BY reservation_key").rows == before_proof
    {:ok, captured} = proof
    assert :ok = TicketPush.validate_completed_proof(recovered, "run", captured)

    for field <- [:intent, :binding, :envelope, :envelope_sha256, :released_access, :run] do
      assert {:error, :ticket_push_proof_changed} =
               TicketPush.validate_completed_proof(recovered, "run", Map.put(captured, field, nil))
    end

    assert {:error, :ticket_push_proof_unproven} = TicketPush.validate_completed_proof(recovered, "run", %{})
    access = captured.released_access
    Store.query!(recovered, "UPDATE workspace_access SET released_at = 'changed' WHERE reservation_key = ?", [access["reservation_key"]])
    assert {:error, :ticket_push_proof_changed} = TicketPush.validate_completed_proof(recovered, "run", captured)
    Store.query!(recovered, "UPDATE workspace_access SET released_at = ? WHERE reservation_key = ?", [access["released_at"], access["reservation_key"]])
    assert :ok = TicketPush.validate_completed_proof(recovered, "run", captured)
    Store.query!(recovered, "UPDATE runs SET spec_revision = spec_revision + 1 WHERE run_id = 'run'")
    assert {:error, :ticket_push_proof_changed} = TicketPush.validate_completed_proof(recovered, "run", captured)
    assert {:error, :ticket_push_current_candidate_unproven} = TicketPush.completed_proof(recovered, "run")
    Store.query!(recovered, "UPDATE runs SET spec_revision = spec_revision - 1 WHERE run_id = 'run'")
    assert complete["receipt_json"] == raw and complete["remote_sha"] == run["candidate_sha"]
    assert complete["owner_nonce"] == invoked["owner_nonce"] and complete["helper_pid"] == invoked["helper_pid"]
  end

  test "push helper rechecks bootstrap and verifier after attachment and rejects substituted execution authority", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "guard-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    {:ok, claimed} = TicketPush.claim(ctx.store, "run", authorization, options)
    {:ok, execution} = TicketPushIO.prepare(ctx.store, claimed, authorization)

    for substituted <- [Map.put(execution, "database", Path.join(ctx.root, "copied.sqlite")), Map.put(execution, "authorization", Map.put(authorization, "snapshot_json", "{}"))] do
      assert {:error, :ticket_push_execution_changed} =
               TicketPush.attach_execution(ctx.store, "run", 123, Jason.encode!(substituted), authorization, options)
    end

    {:ok, parent} = TicketChat.for_run(ctx.store, "run")
    verifier = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", ["run:change-verifier:#{run["verifier_round"]}"])
    verifier_evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ?", [verifier["task_key"]])
    access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [claimed["reservation_key"]])

    mutations = [
      {fn -> Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [parent["create_request_key"]]) end,
       fn -> Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE request_key = ?", [parent["create_request_key"]]) end},
      {fn -> Store.query!(ctx.store, "UPDATE desktop_requests SET action = 'FOLLOWUP' WHERE request_key = ?", [parent["create_request_key"]]) end,
       fn -> Store.query!(ctx.store, "UPDATE desktop_requests SET action = 'CREATE' WHERE request_key = ?", [parent["create_request_key"]]) end},
      {fn -> Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = '{}' WHERE task_key = ?", [verifier["task_key"]]) end,
       fn -> Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = ? WHERE task_key = ?", [verifier["output_json"], verifier["task_key"]]) end},
      {fn -> Store.query!(ctx.store, "UPDATE workspace_access SET git_dir = 'wrong-directory' WHERE reservation_key = ?", [claimed["reservation_key"]]) end,
       fn -> Store.query!(ctx.store, "UPDATE workspace_access SET git_dir = ? WHERE reservation_key = ?", [access["git_dir"], claimed["reservation_key"]]) end},
      {fn -> Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = '{}' WHERE request_key = ?", [verifier_evidence["request_key"]]) end,
       fn -> Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = ? WHERE request_key = ?", [verifier_evidence["binding_json"], verifier_evidence["request_key"]]) end}
    ]

    for {invalidate, restore} <- mutations do
      claimed = Map.put(claimed, "owner_nonce", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
      original = Jason.encode!(claimed)
      Store.query!(ctx.store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [original])
      {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
      {:ok, fresh} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
      {:ok, execution} = TicketPushIO.prepare(ctx.store, claimed, fresh)

      assert {:ok, rejected_raw} =
               TicketPushIO.execute(execution, fn pid, encoded ->
                 result = TicketPush.attach_execution(ctx.store, "run", pid, encoded, fresh, options)
                 assert {:ok, _} = result
                 invalidate.()
                 result
               end)

      {:ok, rejected_run} = RunLedger.get(ctx.store, "run")
      rejected_intent = Jason.decode!(rejected_run["candidate_handoff"])
      assert {:ok, reason} = TicketPushIO.rejection_reason(rejected_raw, rejected_intent)
      assert reason in ~w(bootstrap_changed verifier_pass_changed reservation_binding_changed verifier_binding_changed verifier_changed)
      refute TicketPushIO.receipt_valid?(rejected_raw, rejected_intent)
      assert {:ok, ^rejected_raw} = TicketPushIO.readback(rejected_intent)
      refute TicketPushIO.rejection_reason(rejected_raw, Map.put(rejected_intent, "helper_pid", -1)) == {:ok, reason}

      restore.()
      assert String.trim(git(ctx.repo, ["ls-remote", "origin", "refs/heads/" <> run["branch"]])) == ""
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
      Store.query!(ctx.store, "UPDATE runs SET candidate_handoff = ? WHERE run_id = 'run'", [original])
    end
  end

  test "owned push helper stops and reaps Git on termination and retains its immutable receipt", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "slow-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    marker = Path.join(ctx.root, "remote-hook-started")
    hook = Path.join(remote, "hooks/pre-receive")
    File.write!(hook, "#!/bin/sh\n: > '#{marker}'\nsleep 60\n")
    File.chmod!(hook, 0o755)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    {:ok, claimed} = TicketPush.claim(ctx.store, "run", authorization, options)
    {:ok, execution} = TicketPushIO.prepare(ctx.store, claimed, authorization)
    owner = self()

    task =
      Task.async(fn ->
        TicketPushIO.execute(execution, fn pid, encoded ->
          result = TicketPush.attach_execution(ctx.store, "run", pid, encoded, authorization, options)
          send(owner, {:push_helper, pid})
          result
        end)
      end)

    assert_receive {:push_helper, pid}, 10_000

    started =
      Enum.reduce_while(1..100, false, fn _, _ ->
        if File.exists?(marker),
          do: {:halt, true},
          else:
            (
              Process.sleep(50)
              {:cont, false}
            )
      end)

    assert started
    assert {_, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)])
    assert {:ok, raw} = Task.await(task, 10_000)
    {:ok, current} = RunLedger.get(ctx.store, "run")
    intent = Jason.decode!(current["candidate_handoff"])
    assert TicketPushIO.receipt_valid?(raw, intent)
    receipt = Jason.decode!(raw)
    assert receipt["timed_out"] == true
    assert receipt["termination"] == %{"kind" => "signaled", "signal" => 9}
    assert {:ok, ^raw} = TicketPushIO.readback(intent)
    assert {_, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(receipt["child_pid"])], stderr_to_stdout: true)
    assert status != 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
  end

  test "push helper cleans redirected transport descendants before publishing a stopped receipt", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    git(ctx.repo, ["remote", "add", "origin", "ssh://fixture.invalid/repository.git"])
    pid_file = Path.join(ctx.root, "push-descendants.pid")
    transport = Path.join(ctx.root, "push-transport")
    File.write!(transport, "#!/bin/sh\n/bin/sleep 60 </dev/null >/dev/null 2>&1 &\necho $! >> '#{pid_file}'\nexit 1\n")
    File.chmod!(transport, 0o700)
    git(ctx.repo, ["config", "core.sshCommand", transport])

    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    {:ok, claimed} = TicketPush.claim(ctx.store, "run", authorization, options)
    {:ok, execution} = TicketPushIO.prepare(ctx.store, claimed, authorization)

    assert {:ok, raw} =
             TicketPushIO.execute(execution, fn pid, encoded ->
               TicketPush.attach_execution(ctx.store, "run", pid, encoded, authorization, options)
             end)

    {:ok, current} = RunLedger.get(ctx.store, "run")
    intent = Jason.decode!(current["candidate_handoff"])
    assert TicketPushIO.receipt_valid?(raw, intent)
    assert Jason.decode!(raw)["timed_out"] == false
    assert Jason.decode!(raw)["termination"] == %{"kind" => "exited", "code" => 128}
    assert {:ok, ^raw} = TicketPushIO.readback(intent)

    for pid <- String.split(File.read!(pid_file), "\n", trim: true) do
      {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end

    assert current["state"] == "PUSHING"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "ordinary MR adoption qualifies current remote state without replay or Jira finalization", ctx do
    assert_mr_adoption(ctx)
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001", mr_preflight: true, verify_retained_history_corruption: true
  test "preflight MR adoption reaches CI waiting once and retains the same request on repetition", ctx do
    assert_mr_adoption(ctx)
  end

  test "unissued MR preflight rejects malformed stored delivery metadata without claiming the request", ctx do
    {factory, options, authorization, request, _pushed} = prepared_mr(ctx)
    key = request["request_key"]
    original_metadata = request["metadata_json"]

    for malformed_metadata <- ["[]", ~s({"required_tool_calls": []})] do
      {:ok, before_run} = RunLedger.get(ctx.store, "run")
      Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [malformed_metadata, key])
      {:ok, malformed_request} = DesktopRequest.get(ctx.store, key)

      assert {:error, :ticket_mr_request_binding_mismatch} =
               TicketMrOperation.authorize_discovery(ctx.store, malformed_request, factory)

      assert {:ok, ^before_run} = RunLedger.get(ctx.store, "run")

      assert {:error, :ticket_mr_request_binding_mismatch} =
               TicketMrOperation.check_new_request(ctx.store, key, authorization, factory, options)

      assert {:ok, ^before_run} = RunLedger.get(ctx.store, "run")

      assert {:ok, current} = DesktopRequest.get(ctx.store, key)
      assert current["status"] == "PENDING"
      assert Enum.all?(~w(claimed_at thread_id turn_id output_json), &is_nil(current[&1]))
      assert current["metadata_json"] == malformed_metadata

      Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [original_metadata, key])
      assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
      assert :ok = TicketMrOperation.authorize_discovery(ctx.store, request, factory)
    end
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001", finalize_jira: true
  @tag timeout: 450_000
  test "review-ready finalization recovers the same uncertain comment and issued ai-review labels", ctx do
    assert_mr_adoption(ctx)
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001", finalize_race: true
  test "review-ready finalization observes a concurrent comment before issuing it", ctx do
    assert_mr_adoption(ctx)
  end

  defp assert_mr_adoption(ctx), do: assert_mr_adoption(ctx, false)

  defp assert_mr_adoption(ctx, return_launch_context?) do
    {launch_context, {factory, options, authorization, request, pushed}} = prepared_mr(ctx, true)
    key = request["request_key"]
    assert {:ok, args} = DesktopToolArgs.followup(request)
    assert args == %{"threadId" => "controller-thread", "model" => request["model"], "thinking" => request["reasoning_effort"], "prompt" => request["prompt"]}

    for field <- ~w(claimed_at thread_id turn_id output_json) do
      value = if field == "thread_id", do: "controller-thread", else: "issued"
      assert {:error, :ticket_mr_request_already_issued} = DesktopToolArgs.followup(Map.put(request, field, value))
    end

    assert {:error, :ticket_mr_request_binding_mismatch} = DesktopToolArgs.followup(Map.put(request, "prompt", "changed"))
    assert {:error, :unsupported_followup_route} = DesktopToolArgs.followup(Map.put(request, "metadata_json", "{}"))
    read_opts = Keyword.merge(options, connector: MrReader, mcp_session: %{thread_id: "controller-thread"}, workspace: ctx.path)
    assert {:ok, %{status: "MR_WAITING_FOR_RESULT", request_key: ^key}} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    refute_received {:mr_read, _}
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [key])
    assert {:error, :ticket_mr_request_failed} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    refute_received {:mr_read, _}
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'PENDING' WHERE request_key = ?", [key])
    claim_guard = mr_guard(request)
    claim_started_at = DateTime.utc_now()
    claim_started_monotonic = System.monotonic_time(:millisecond)
    claim_opts = Keyword.put(options, :ticket_mr_admission, %{factory: factory, authorization: authorization, guard: claim_guard})
    claim_result = DesktopRequest.claim(ctx.store, key, claim_opts)
    claim_elapsed_ms = System.monotonic_time(:millisecond) - claim_started_monotonic
    claim_finished_at = DateTime.utc_now()

    assert {:ok, _} = claim_result,
           "MR claim failed after #{claim_elapsed_ms}ms (#{DateTime.to_iso8601(claim_started_at)}..#{DateTime.to_iso8601(claim_finished_at)}); " <>
             "guard owner observed_at=#{claim_guard["owner"]["observed_at"]}, queue observed_at=#{claim_guard["native"]["queue_observation"]["observed_at"]}, " <>
             "latest observed_at=#{claim_guard["native"]["latest_turn_observation"]["observed_at"]}, previous_turn_id=#{get_in(Jason.decode!(request["metadata_json"]), ["previous_turn_id"])}, " <>
             "native thread_id=#{claim_guard["native"]["id"]}, latest turn_id=#{get_in(claim_guard, ["native", "latest_turn_observation", "raw_response", "data", Access.at(0), "id"])}"

    assert {:ok, claimed} = DesktopRequest.get(ctx.store, key)
    assert {:error, :ticket_mr_request_already_issued} = DesktopToolArgs.followup(claimed)
    assert {:ok, _} = DesktopRequest.record_thread(ctx.store, key, "controller-thread", "project-grail")

    result = %{
      "status" => "PASS",
      "mr_url" => "https://fixture.invalid/repository/-/merge_requests/1",
      "iid" => 1,
      "source_branch" => pushed["branch"],
      "target_branch" => pushed["base_branch"],
      "sha" => pushed["candidate_sha"],
      "draft" => true,
      "reviewers_count" => 0,
      "assignee_id" => 11_599_766,
      "state" => "opened"
    }

    completion = %{
      thread_id: "controller-thread",
      turn_id: "mr-adoption-turn",
      output: %{"result" => result, "completed_tool_calls" => [%{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed"}]}
    }

    assert {:ok, completed} = DesktopRequest.complete(ctx.store, key, completion)
    claim = Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key])

    mr = %{
      "project_id" => "1000",
      "iid" => "1",
      "web_url" => result["mr_url"],
      "sha" => pushed["candidate_sha"],
      "source_branch" => pushed["branch"],
      "target_branch" => pushed["base_branch"],
      "draft" => true,
      "state" => "opened",
      "reviewers" => [],
      "assignees" => [%{"id" => "11599766"}],
      "diff_refs" => %{"head_sha" => pushed["candidate_sha"]}
    }

    before = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows
    Control.record_controller_task(ctx.store, factory, "controller-thread", "later-turn", %{project_id: "project-grail"})
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = '[]' WHERE request_key = ?", [key])
    assert {:error, :ticket_mr_request_binding_mismatch} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    refute_received {:mr_read, _}
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [completed["metadata_json"], key])
    assert {:error, :gitlab_catalog_session_required} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, Keyword.delete(read_opts, :mcp_session))
    assert {:error, :ticket_mr_read_session_mismatch} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, Keyword.put(read_opts, :mcp_session, %{thread_id: "foreign"}))
    assert {:error, :ticket_authorization_expired} = TicketMrOperation.adopt_result(ctx.store, "run", Map.put(authorization, "observed_at", "2020-01-01T00:00:00Z"), factory, read_opts)
    {:ok, current_run_for_pins} = RunLedger.get(ctx.store, "run")
    authorization = push_authorization(ctx.store, current_run_for_pins)
    unpinned = update_in(factory.repositories["grail"], &Map.delete(&1, "gitlab_project_id"))
    assert {:error, :ticket_mr_project_pin_required} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, unpinned, read_opts)

    assert_invalid_project_pins(ctx, factory, authorization, read_opts)

    foreign_pin = put_in(factory.repositories["grail"]["gitlab_project_id"], "1001")
    assert {:error, :ticket_mr_request_binding_mismatch} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, foreign_pin, read_opts)
    refute_received {:mr_read, _}

    for changed <- [Map.put(mr, "draft", false), Map.put(mr, "reviewers", [%{"id" => 5}]), Map.put(mr, "state", "merged")] do
      Process.put(:mr_reads, [changed, changed])
      assert {:error, :ticket_mr_human_state_changed} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
      assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    end

    Process.put(:mr_reads, [
      mr,
      fn ->
        Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_json = '{}' WHERE request_key = ?", [key])
        {:ok, mr}
      end
    ])

    assert {:error, :ticket_mr_claim_unproven} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_json = ? WHERE request_key = ?", [claim["receipt_json"], key])

    saved_path = Path.join(ctx.root, "workspaces/saved-source")
    original_inode = File.stat!(ctx.path).inode

    Process.put(:mr_reads, [
      mr,
      fn ->
        File.rename!(ctx.path, saved_path)
        File.mkdir!(ctx.path)
        Enum.each(File.ls!(saved_path), fn name -> File.cp_r!(Path.join(saved_path, name), Path.join(ctx.path, name)) end)
        assert File.stat!(ctx.path).inode != original_inode
        {:ok, mr}
      end
    ])

    assert {:error, :ticket_mr_checkout_changed} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    File.rename!(ctx.path, Path.join(ctx.root, "workspaces/replaced-source"))
    File.rename!(saved_path, ctx.path)

    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [ctx.sha])
    assert {:error, :ticket_push_current_candidate_unproven} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [pushed["candidate_sha"]])
    Process.put(:mr_reads, [mr, mr])
    context = %{store: ctx.store, workspace_root: Path.join(ctx.root, "workspaces"), factory: factory, task_supervisor: nil, recipient: self()}
    {context, tick_opts} = tick_controller(context, read_opts)
    assert {:ok, _} = Control.pause(ctx.store, factory, factory.dispatcher_id)
    control = Control.status(ctx.store, "scope")
    context = put_in(context.factory.ticket_supervisor["enabled"], false)
    assert_mr_recovery_faults(ctx, context, tick_opts, completed, pushed, mr)
    assert {:ok, %{launches: [], events: events}} = Scheduler.reconcile_ticket_jira(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_MR_ADOPTED"))
    assert {:ok, adopted} = RunLedger.get(ctx.store, "run")
    expected = if ctx[:mr_preflight], do: "CI_WAITING", else: "MR_CREATING"
    assert adopted["state"] == expected
    assert adopted["mr_iid"] == 1 and adopted["mr_url"] == result["mr_url"]
    assert adopted["candidate_handoff"] == pushed["candidate_handoff"]
    assert :ok = TicketMrOperation.validate_retained_mr_history(ctx.store, adopted)

    assert_retained_history_corruption(ctx, completed, key, adopted)

    assert {:error, _} = TicketMrOperation.validate_retained_mr_history(ctx.store, Map.put(adopted, "mr_iid", 2))
    authorization = push_authorization(ctx.store, adopted)
    Process.put(:mr_reads, [mr, mr])
    assert {:ok, %{status: "MR_ALREADY_ADOPTED", run: ^adopted}} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == before
    assert Control.status(ctx.store, "scope") == control
    assert {:ok, ^completed} = DesktopRequest.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == claim
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'CONTROLLER'")["count"] == 1
    assert {:ok, _} = Control.activate(ctx.store, factory, factory.dispatcher_id)

    if ctx[:mr_preflight] != true do
      assert_readonly_delivery_receipt(ctx, factory, read_opts, adopted, mr, key)
    end

    authorization = push_authorization(ctx.store, adopted)
    Control.record_controller_task(ctx.store, factory, "controller-thread", "original-turn", %{project_id: "project-grail"})
    original_control = Control.status(ctx.store, "scope")
    Process.put(:mr_reads, [mr, mr])
    assert {:ok, %{status: "MR_ALREADY_ADOPTED"}} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, factory, read_opts)
    assert Control.status(ctx.store, "scope") == Map.put(original_control, "controller_turn_id", "mr-adoption-turn")

    if ctx[:mr_preflight], do: assert_ci_progression(ctx, factory, read_opts, adopted, mr, key, claim)
    maybe_finalize_jira(ctx, factory, read_opts, adopted, mr)

    if return_launch_context?, do: {launch_context, options}, else: :ok
  end

  defp assert_retained_history_corruption(%{verify_retained_history_corruption: true} = ctx, completed, key, adopted) do
    original_output = completed["output_json"]
    Store.query!(ctx.store, "UPDATE desktop_requests SET output_json = '{}' WHERE request_key = ?", [key])

    assert {:error, :ticket_mr_original_history_unproven} =
             TicketMrOperation.validate_retained_mr_history(ctx.store, adopted)

    assert {:ok, ^adopted} = RunLedger.get(ctx.store, "run")

    assert Store.one!(ctx.store, "SELECT output_json FROM desktop_requests WHERE request_key = ?", [key])["output_json"] ==
             "{}"

    Store.query!(ctx.store, "UPDATE desktop_requests SET output_json = ? WHERE request_key = ?", [original_output, key])
    assert :ok = TicketMrOperation.validate_retained_mr_history(ctx.store, adopted)
  end

  defp assert_retained_history_corruption(_ctx, _completed, _key, _adopted), do: :ok

  defp maybe_finalize_jira(ctx, factory, options, run, mr) do
    cond do
      ctx[:finalize_jira] -> assert_jira_finalization(ctx, factory, options, run, mr)
      ctx[:finalize_race] -> assert_jira_finalization_race(ctx, factory, options, run, mr)
      true -> :ok
    end
  end

  defp assert_jira_finalization_race(ctx, factory, options, run, mr) do
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)

    snapshot =
      Map.update!(snapshot, "comments", fn comments ->
        comments |> Enum.with_index() |> Enum.map(fn {entry, index} -> Map.put(entry, "id", "history-#{index}") end)
      end)

    Process.put(:final_jira_snapshot, snapshot)
    Process.put(:final_jira_calls, [])
    Process.put(:final_jira_mode, :applied)
    request = Store.one!(ctx.store, "SELECT cwd FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND status = 'SUCCEEDED'")
    scope = fn _cwd, operation -> operation.(%{thread_id: "final-jira"}) end
    options = Keyword.merge(options, workspace: request["cwd"], jira_reader: FinalJiraReader, jira_connector: FinalJiraConnector, jira_session: scope)
    writer_rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows

    observe_comment = fn ->
      row = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE operation = 'REVIEW_READY'")
      assert row["phase"] == "FIRST_PENDING"
      [%{"kind" => "COMMENT", "body" => body}, _] = Jason.decode!(row["effects_json"])
      comment = %{"id" => "concurrent-delivery-comment", "text" => body}
      Process.put(:final_jira_snapshot, Map.update!(Process.get(:final_jira_snapshot), "comments", &(&1 ++ [comment])))
      {:ok, mr}
    end

    Process.put(:mr_reads, [mr, mr, observe_comment | List.duplicate(mr, 20)])
    assert {:ok, %{status: "REVIEW_READY", run: ready}} = TicketJiraFinalization.finish(ctx.store, "run", factory, options)
    assert ready["state"] == "READY_FOR_REVIEW" and ready["candidate_sha"] == run["candidate_sha"]
    assert Jason.decode!(ready["snapshot_json"]) == Process.get(:final_jira_snapshot)
    assert [{"jira_update_factory_labels", _}] = Process.get(:final_jira_calls)
    row = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE operation = 'REVIEW_READY'")
    assert row["phase"] == "COMPLETE"
    assert Jason.decode!(row["first_receipt_json"])["observation"]["issue"]["comments"] |> Enum.any?(&(&1["id"] == "concurrent-delivery-comment"))
    refute is_nil(Store.one!(ctx.store, "SELECT released_at FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])["released_at"])
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == writer_rows
  end

  defp assert_mr_recovery_faults(ctx, context, tick_opts, completed, pushed, mr) do
    key = completed["request_key"]
    copied = Map.merge(completed, %{"request_key" => "historical-mr-copy", "created_at" => "2000-01-01T00:00:00Z"})
    columns = copied |> Map.keys() |> Enum.sort()
    values = Enum.map(columns, &copied[&1])
    placeholders = Enum.map_join(columns, ",", fn _ -> "?" end)
    Store.query!(ctx.store, "INSERT INTO desktop_requests (#{Enum.join(columns, ",")}) VALUES (#{placeholders})", values)

    assert {:ok, %{events: deferred}} = Scheduler.reconcile_ticket_jira(context, tick_opts)
    assert Enum.any?(deferred, &(&1.event == "TICKET_DEFERRED" and &1.detail == inspect(:ticket_mr_request_changed)))
    assert Process.get(:mr_reads) == [mr, mr]
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "DELETE FROM desktop_requests WHERE request_key = ?", [copied["request_key"]])

    Process.put(:mr_reads, [
      mr,
      fn ->
        Store.query!(ctx.store, "UPDATE desktop_requests SET output_json = '{}' WHERE request_key = ?", [key])
        {:ok, mr}
      end
    ])

    assert {:ok, %{events: changed}} = Scheduler.reconcile_ticket_jira(context, tick_opts)
    assert Enum.any?(changed, &(&1.event == "TICKET_DEFERRED" and &1.detail == inspect(:ticket_mr_request_changed)))
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET output_json = ? WHERE request_key = ?", [completed["output_json"], key])
    Process.put(:mr_reads, [mr, mr])
  end

  defp assert_invalid_project_pins(ctx, factory, authorization, read_opts) do
    for pin <- ["01000", "not-an-id", 0] do
      invalid = put_in(factory.repositories["grail"]["gitlab_project_id"], pin)
      assert {:error, :ticket_mr_project_pin_required} = TicketMrOperation.adopt_result(ctx.store, "run", authorization, invalid, read_opts)
    end
  end

  defp assert_jira_finalization(ctx, factory, options, run, mr) do
    assert {:ok, _} = Control.activate(ctx.store, factory, factory.dispatcher_id)
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)

    snapshot =
      Map.update!(snapshot, "comments", fn comments ->
        comments |> Enum.with_index() |> Enum.map(fn {entry, index} -> Map.put(entry, "id", "history-#{index}") end)
      end)

    Process.put(:final_jira_snapshot, Map.update!(snapshot, "labels", &["human-label" | &1]))
    Process.put(:final_jira_calls, [])
    Process.put(:final_jira_mode, :lost_before_apply)
    Process.put(:mr_reads, List.duplicate(mr, 100))
    request = Store.one!(ctx.store, "SELECT cwd FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND status = 'SUCCEEDED'")
    scope = fn _cwd, operation -> operation.(%{thread_id: "final-jira"}) end
    options = Keyword.merge(options, workspace: request["cwd"], jira_reader: FinalJiraReader, jira_connector: FinalJiraConnector, jira_session: scope)
    writer_rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows

    comment_body =
      Enum.join(["Symphony: draft MR ready for review.", "MR: " <> run["mr_url"], "Candidate: " <> run["candidate_sha"], "Next: review the draft MR; transition Jira to In Review when ready."], "\n\n")

    {original_snapshot, disabled} = assert_jira_finalization_rejection_guards(ctx, factory, options, mr)

    observed_snapshot = Map.update!(original_snapshot, "comments", &(&1 ++ [%{"id" => "preexisting-review-comment", "text" => comment_body}]))
    Process.put(:final_jira_snapshot, observed_snapshot)
    Process.put(:final_jira_mode, :applied)
    Process.put(:final_jira_calls, [])
    Process.put(:mr_reads, List.duplicate(mr, 100))
    run_before_phase_probe = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    journal_before_phase_probe = Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects ORDER BY operation_key").rows
    access_before_phase_probe = Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows
    events_before_phase_probe = Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
    source_file = Path.join(ctx.path, "fixture.txt")
    source_index = Path.join(String.trim(git(ctx.path, ["rev-parse", "--absolute-git-dir"])), "index")
    source_bytes = File.read!(source_file)
    index_bytes = File.read!(source_index)

    Store.query!(ctx.store, """
    CREATE TRIGGER u11_ignore_review_advance
    BEFORE UPDATE OF phase ON ticket_jira_effects
    WHEN OLD.run_id = 'run' AND OLD.phase = 'FIRST_PENDING' AND NEW.phase = 'SECOND_PENDING'
    BEGIN SELECT RAISE(IGNORE); END
    """)

    try do
      assert {:error, :ticket_jira_effect_limit} = TicketJiraFinalization.finish(ctx.store, "run", factory, options)
    after
      Store.query!(ctx.store, "DROP TRIGGER u11_ignore_review_advance")
    end

    phase_blocked = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE run_id = 'run' AND operation = 'REVIEW_READY'")
    assert phase_blocked["phase"] == "FIRST_PENDING"
    assert phase_blocked["first_receipt_json"] == nil and phase_blocked["second_receipt_json"] == nil
    assert Process.get(:final_jira_calls) == []
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before_phase_probe
    assert Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects ORDER BY operation_key").rows == journal_before_phase_probe
    access_after_phase_probe = Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows
    assert access_after_phase_probe == access_before_phase_probe
    assert Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows == events_before_phase_probe
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == writer_rows
    assert File.read!(source_file) == source_bytes
    assert File.read!(source_index) == index_bytes
    Process.put(:final_jira_snapshot, original_snapshot)
    Process.put(:final_jira_mode, :lost_before_apply)
    Process.put(:final_jira_calls, [])
    Process.put(:mr_reads, List.duplicate(mr, 100))

    assert {:error, :ticket_jira_effect_not_observed} = TicketJiraFinalization.finish(ctx.store, "run", factory, options)
    row = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE operation = 'REVIEW_READY'")
    assert row["phase"] == "FIRST_UNCERTAIN"
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])["released_at"] == nil
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
    snapshot_before_session = Process.get(:final_jira_snapshot)

    session_snapshot =
      snapshot_before_session
      |> Map.update!("comments", &(&1 ++ [%{"id" => "observed-uncertain-comment", "text" => comment_body}]))
      |> Map.put("labels", ~w(ai-review human-label repo-grail))
      |> Map.put("status", "In Review")

    Process.put(:final_jira_snapshot, session_snapshot)
    Process.put(:mr_reads, List.duplicate(mr, 100))
    held_access_before_session = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])
    connector_calls_before_session = Process.get(:final_jira_calls)

    postfault_state = fn ->
      %{
        run: Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'"),
        journal: Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects ORDER BY operation_key").rows,
        access: Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows,
        tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows,
        evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY request_key").rows,
        requests: Store.query!(ctx.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
        events: Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
      }
    end

    session_with_released_owner = fn _workspace, callback ->
      Store.query!(ctx.store, "UPDATE workspace_access SET released_at = 'u11-session-ownership-drift' WHERE reservation_key = ?", [row["operation_key"]])
      Process.put(:u11_finalization_postfault_state, postfault_state.())
      callback.(%{thread_id: "final-jira"})
    end

    try do
      assert {:error, :stale_workspace_reservation} =
               TicketJiraFinalization.finish(ctx.store, "run", factory, Keyword.put(options, :jira_session, session_with_released_owner))

      assert postfault_state.() == Process.get(:u11_finalization_postfault_state)
      assert Process.get(:final_jira_calls) == connector_calls_before_session
    after
      Store.query!(ctx.store, "UPDATE workspace_access SET released_at = ? WHERE reservation_key = ?", [held_access_before_session["released_at"], row["operation_key"]])
      Process.put(:final_jira_snapshot, snapshot_before_session)
    end

    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]]) == held_access_before_session
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
    Process.put(:mr_reads, List.duplicate(mr, 100))

    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:error, :ticket_jira_effect_not_observed} = TicketJiraFinalization.finish(reopened, "run", disabled, options)
      assert length(Process.get(:final_jira_calls)) == 1
      held_before = Store.one!(reopened, "SELECT * FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])
      Store.query!(reopened, "UPDATE workspace_access SET released_at = 'fixture-release' WHERE reservation_key = ?", [row["operation_key"]])
      assert {:error, :stale_workspace_reservation} = TicketJiraFinalization.reconcile(reopened, "run", factory, options)
      assert {:ok, released} = WorkspaceAccess.get(reopened, row["operation_key"])
      assert released == Map.put(held_before, "released_at", "fixture-release")
      Store.query!(reopened, "UPDATE workspace_access SET released_at = NULL WHERE reservation_key = ?", [row["operation_key"]])
      recovery = TicketJiraFinalization.reconcile(reopened, "run", factory, options)
      assert recovery == {:error, :ticket_jira_effect_not_observed}
      assert length(Process.get(:final_jira_calls)) == 1
      [{"jira_add_comment", args}] = Process.get(:final_jira_calls)
      assert args["body"] =~ run["candidate_sha"] and args["body"] =~ run["mr_url"]
      assert args["body"] =~ "Symphony:" and args["body"] =~ "transition Jira to In Review"
      snapshot = Process.get(:final_jira_snapshot)
      delivered_comment = %{"id" => "delivery-comment", "text" => args["body"]}
      Process.put(:final_jira_snapshot, Map.update!(snapshot, "comments", &(&1 ++ [delivered_comment])))
      context = %{store: reopened, workspace_root: Path.join(ctx.root, "workspaces"), factory: factory, task_supervisor: nil, recipient: self()}
      {context, tick_opts} = tick_controller(context, options)
      tick_opts = Keyword.put(tick_opts, :jira_reader, FinalJiraReader)
      assert_pending_label_readback(context, tick_opts, row["operation_key"])
      assert length(Process.get(:final_jira_calls)) == 1
      Process.put(:final_jira_mode, :lost_label_readback)
      assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
      assert Enum.any?(events, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":jira_readback_unavailable"))
      current = Store.one!(reopened, "SELECT phase FROM ticket_jira_effects WHERE operation_key = ?", [row["operation_key"]])
      assert current["phase"] == "SECOND_UNCERTAIN"
      applied_snapshot = Process.get(:final_jira_snapshot)
      assert "ai-review" in applied_snapshot["labels"]

      assert {:ok, _} = Control.pause(reopened, factory, factory.dispatcher_id)

      revert_during_final_mr = fn ->
        Process.put(:final_jira_snapshot, Map.put(applied_snapshot, "labels", ~w(ai-running human-label repo-grail)))
        {:ok, mr}
      end

      Process.put(:mr_reads, [mr, mr, revert_during_final_mr, mr | List.duplicate(mr, 100)])
      result = TicketJiraFinalization.reconcile(reopened, "run", disabled, options)
      assert result == {:error, :ticket_jira_effect_not_observed}
      assert {:ok, ^run} = RunLedger.get(reopened, "run")
      held = Store.one!(reopened, "SELECT released_at FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])
      assert held["released_at"] == nil
      assert length(Process.get(:final_jira_calls)) == 2
      Process.put(:final_jira_snapshot, applied_snapshot)
      Process.put(:mr_reads, List.duplicate(mr, 100))
      recovery_context = %{context | factory: put_in(context.factory, [:ticket_supervisor, "enabled"], false)}

      Store.query!(reopened, """
      CREATE TRIGGER fixture_recovery_release BEFORE UPDATE OF released_at ON workspace_access
      WHEN NEW.released_at IS NOT NULL BEGIN SELECT RAISE(ABORT, 'fixture recovery release failure'); END
      """)

      assert {:ok, %{launches: [], events: failed}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
      assert Enum.any?(failed, &(&1.event == "TICKET_DEFERRED" and String.contains?(&1.detail, "Exqlite.Error")))
      assert {:ok, ^run} = RunLedger.get(reopened, "run")
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(reopened, row["operation_key"])
      assert length(Process.get(:final_jira_calls)) == 2
      assert_malformed_jira_checkout(reopened, row["operation_key"])
      assert_unrelated_parent_progress(ctx, context, tick_opts)
      Store.query!(reopened, "DROP TRIGGER fixture_recovery_release")
      assert {:ok, %{launches: [], events: recovered}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
      assert Enum.any?(recovered, &(&1.event == "TICKET_REVIEW_READY"))
      assert {:ok, ready} = RunLedger.get(reopened, "run")
      assert_jira_finalization_ready_run(ready, run)
      assert Store.one!(reopened, "SELECT phase FROM ticket_jira_effects WHERE operation_key = ?", [row["operation_key"]])["phase"] == "COMPLETE"
      assert Store.one!(reopened, "SELECT released_at FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])["released_at"] != nil
      assert_final_jira_readback()
      assert Store.query!(reopened, "SELECT * FROM factory_tasks ORDER BY task_key").rows == writer_rows
      assert Control.status(reopened, factory.scope)["status"] == "PAUSED"
      assert {:ok, %{launches: [], events: []}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
      rejected = TicketWorkerRunner.authorization(run, Process.get(:final_jira_snapshot), DateTime.utc_now())
      assert rejected == {:error, :ticket_jira_not_dispatchable}
    after
      GenServer.stop(reopened)
    end
  end

  defp assert_jira_finalization_rejection_guards(ctx, factory, options, mr) do
    disabled = put_in(factory, [:ticket_supervisor, "enabled"], false)
    not_allowlisted = put_in(factory, [:ticket_supervisor, "pilot_issue_keys"], ["PPL-999"])

    invalid_session = fn _cwd, callback -> callback.(%{thread_id: nil}) end
    result = TicketJiraFinalization.finish(ctx.store, "run", factory, Keyword.put(options, :jira_session, invalid_session))
    assert result == {:error, :ticket_jira_session_unproven}
    assert Process.get(:final_jira_calls) == []
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects")["count"] == 0

    assert {:error, :ticket_jira_operation_missing} = TicketJiraFinalization.reconcile(ctx.store, "run", factory, options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects")["count"] == 0

    for rejected_factory <- [disabled, not_allowlisted] do
      result = TicketJiraFinalization.finish(ctx.store, "run", rejected_factory, options)
      assert result == {:error, :ticket_jira_new_effect_not_admitted}
      assert Process.get(:final_jira_calls) == []
    end

    assert {:ok, _} = Control.pause(ctx.store, factory, factory.dispatcher_id)
    result = TicketJiraFinalization.finish(ctx.store, "run", factory, options)
    assert result == {:error, :ticket_jira_new_effect_not_admitted}
    assert Process.get(:final_jira_calls) == []
    assert {:ok, _} = Control.activate(ctx.store, factory, factory.dispatcher_id)
    assert {:error, :ticket_jira_recovery_unissued} = TicketJiraFinalization.reconcile(ctx.store, "run", factory, options)
    assert Process.get(:final_jira_calls) == []
    original_snapshot = Process.get(:final_jira_snapshot)
    Process.put(:final_jira_snapshot, Map.put(original_snapshot, "labels", ~w(ai-review repo-grail)))
    result = TicketJiraFinalization.finish(ctx.store, "run", factory, options)
    assert result == {:error, :ticket_jira_not_dispatchable}
    assert Process.get(:final_jira_calls) == []
    Process.put(:final_jira_snapshot, original_snapshot)

    block_during_mr = fn ->
      current = Process.get(:final_jira_snapshot)
      Process.put(:final_jira_snapshot, Map.update!(current, "labels", &["ai-blocked" | &1]))
      {:ok, mr}
    end

    Process.put(:mr_reads, [mr, mr, block_during_mr, mr | List.duplicate(mr, 100)])
    result = TicketJiraFinalization.finish(ctx.store, "run", factory, options)
    assert result == {:error, :ticket_jira_not_dispatchable}
    assert Process.get(:final_jira_calls) == []
    Process.put(:final_jira_snapshot, original_snapshot)
    Process.put(:mr_reads, List.duplicate(mr, 100))
    {original_snapshot, disabled}
  end

  defp assert_final_jira_readback do
    assert Process.get(:final_jira_snapshot)["labels"] |> Enum.sort() == ~w(ai-review human-label repo-grail)
    assert Enum.count(Process.get(:final_jira_calls), fn {tool, _} -> tool == "jira_add_comment" end) == 1
    assert Enum.count(Process.get(:final_jira_calls), fn {tool, _} -> tool == "jira_update_factory_labels" end) == 1
  end

  defp assert_jira_finalization_ready_run(ready, run) do
    assert ready["state"] == "READY_FOR_REVIEW" and ready["candidate_sha"] == run["candidate_sha"]
    assert ready["candidate_handoff"] == run["candidate_handoff"] and ready["mr_url"] == run["mr_url"]
  end

  defp assert_pending_label_readback(context, tick_opts, operation_key) do
    assert {:ok, %{events: observed}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(observed, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_jira_effect_not_observed"))
    assert Store.one!(context.store, "SELECT phase FROM ticket_jira_effects WHERE operation_key = ?", [operation_key])["phase"] == "SECOND_PENDING"
    disabled = put_in(context.factory.ticket_supervisor["enabled"], false)
    assert {:ok, %{launches: [], events: readonly}} = Scheduler.tick(disabled, tick_opts)
    assert Enum.any?(readonly, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_jira_effect_not_observed"))
    assert {:ok, _} = Control.pause(context.store, context.factory, context.factory.dispatcher_id)
    assert {:ok, %{launches: [], events: paused}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(paused, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_jira_effect_not_observed"))
    assert Store.one!(context.store, "SELECT phase FROM ticket_jira_effects WHERE operation_key = ?", [operation_key])["phase"] == "SECOND_PENDING"
    assert {:ok, _} = Control.activate(context.store, context.factory, context.factory.dispatcher_id)
  end

  defp assert_malformed_jira_checkout(store, key) do
    original = Store.one!(store, "SELECT * FROM ticket_jira_effects WHERE operation_key = ?", [key])
    assert original["phase"] == "COMPLETE"
    {:ok, access} = WorkspaceAccess.get(store, key)
    binding = original["binding_json"] |> Jason.decode!() |> Map.put("checkout", nil) |> Jason.encode!()
    hash = Base.encode16(:crypto.hash(:sha256, binding), case: :lower)
    receipts = Enum.map(~w(first_receipt_json second_receipt_json), &(original[&1] |> Jason.decode!() |> Map.put("binding_sha256", hash) |> Jason.encode!()))

    Store.query!(
      store,
      "UPDATE ticket_jira_effects SET binding_json = ?, binding_sha256 = ?, first_receipt_json = ?, second_receipt_json = ? WHERE operation_key = ?",
      [binding, hash] ++ receipts ++ [key]
    )

    try do
      assert {:error, :jira_workspace_binding_unproven} =
               WorkspaceAccess.release_jira(store, access["run_id"], key, access["generation"])

      assert {:ok, ^access} = WorkspaceAccess.get(store, key)
    after
      fields = ~w(binding_json binding_sha256 first_receipt_json second_receipt_json)

      Store.query!(
        store,
        "UPDATE ticket_jira_effects SET binding_json = ?, binding_sha256 = ?, first_receipt_json = ?, second_receipt_json = ? WHERE operation_key = ?",
        Enum.map(fields, &original[&1]) ++ [key]
      )
    end
  end

  defp assert_unrelated_parent_progress(ctx, context, tick_opts) do
    {contract, snapshot} = SymphonyElixir.TicketChatFixture.authorized_contract("PPL-456", "unrelated-issue")

    {:ok, _} =
      RunLedger.register(context.store, %{
        run_id: "unrelated",
        issue_key: "PPL-456",
        kind: "DELIVERY",
        state: "ADMITTING_WRITER",
        execution_mode: "TICKET_SUPERVISOR_V1",
        repo_key: "grail",
        repo_path: ctx.repo,
        base_branch: "master",
        branch: "cgable/unrelated",
        spec_revision: contract.revision,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        snapshot_json: Jason.encode!(snapshot),
        manual_validation_required: false
      })

    parents = Path.join(ctx.root, "recovery-parents")
    File.mkdir_p!(parents)
    workflow = Path.join(ctx.root, "recovery-workflow.md")
    File.write!(workflow, "---\nfactory:\n  database: #{ctx.database}\n---\nFixture")
    options = Keyword.merge(context.ticket_options, parent_output_root: parents, broker_thread_id: "019fa5b7-27fa-7660-ab47-7c3abb867c91", ticket_cli_root: File.cwd!(), ticket_workflow: workflow)
    context = %{context | ticket_options: options}
    context = put_in(context, [:factory, :ticket_supervisor, "pilot_issue_keys"], ["PPL-456"])
    context = put_in(context, [:factory, :models, "roles", "orchestrator-intake"], %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "low"})
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.issue_key == "PPL-123" and String.contains?(&1.detail, "Exqlite.Error")))
    assert Enum.any?(events, &(&1.issue_key == "PPL-456" and &1.event == "TICKET_PARENT_PENDING"))
    assert {:ok, %{"create_request_key" => key}} = TicketChat.for_run(context.store, "unrelated")
    assert {:ok, %{"status" => "PENDING"}} = DesktopRequest.get(context.store, key)
  end

  defp assert_readonly_delivery_receipt(ctx, factory, options, run, mr, key) do
    tables = ~w(runs factory_tasks desktop_requests ticket_mr_claims control workspace_access worker_evidence events)
    frozen = Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    review_snapshot = Map.put(snapshot, "labels", ~w(ai-review repo-grail))
    rejected = TicketWorkerRunner.authorization(run, review_snapshot, DateTime.utc_now())
    assert rejected == {:error, :ticket_jira_not_dispatchable}
    {:ok, current_authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    assert {:ok, _} = TicketWorkerRunner.delivery_admission(ctx.store, run, current_authorization, options)
    Process.put(:mr_reads, [mr, mr])
    readback = {TicketPushIO, :readback, 1}
    :erlang.trace_pattern(readback, true, [:call_count])

    {:ok, receipt} =
      try do
        result = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
        assert {:call_count, 2} = :erlang.trace_info(readback, :call_count)
        {:ok, qualified} = result
        assert {:ok, :ok} = Exqlite.transaction(ctx.store, &TicketMrOperation.validate_delivery_receipt(&1, qualified, factory, options))
        changed = put_in(qualified, [:push_proof, :envelope_sha256], "changed")
        assert {:error, :ticket_push_proof_changed} = TicketMrOperation.validate_delivery_receipt(ctx.store, changed, factory, options)
        assert {:call_count, 2} = :erlang.trace_info(readback, :call_count)
        result
      after
        :erlang.trace_pattern(readback, false, [:call_count])
      end

    assert receipt.run == run and receipt.request["request_key"] == key
    assert receipt.binding["candidate_sha"] == run["candidate_sha"]
    identity = ~w(project_id iid web_url source_branch target_branch sha draft state reviewers assignees diff_refs)
    normalized = Map.merge(mr, %{"project_id" => 1000, "iid" => 1, "assignees" => [%{"id" => 11_599_766}]})
    assert Map.take(receipt.mr, identity) == Map.take(normalized, identity)
    assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen

    missing_assignees = Map.put(mr, "assignees", nil)
    Process.put(:mr_reads, [missing_assignees, missing_assignees])
    assert {:error, :ticket_mr_remote_binding_mismatch} = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
    assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen
    Process.put(:mr_reads, [mr, mr])
    assert {:ok, _} = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
    assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen

    claim = Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key])
    Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_sha256 = 'corrupt' WHERE request_key = ?", [key])
    result = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
    assert result == {:error, :ticket_mr_claim_unproven}
    Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_sha256 = ? WHERE request_key = ?", [claim["receipt_sha256"], key])

    replaced = Path.join(ctx.root, "temporarily-retained-source")

    change_checkout = fn ->
      File.rename!(ctx.path, replaced)
      File.mkdir!(ctx.path)
      {:ok, mr}
    end

    Process.put(:mr_reads, [change_checkout, mr])
    assert {:error, _} = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
    File.rmdir!(ctx.path)
    File.rename!(replaced, ctx.path)

    change_candidate = fn ->
      Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [ctx.sha])
      {:ok, mr}
    end

    Process.put(:mr_reads, [change_candidate, mr])
    result = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
    assert result == {:error, :ticket_delivery_binding_changed}
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [run["candidate_sha"]])
    assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen

    for changed <- [Map.put(mr, "draft", false), Map.put(mr, "state", "closed"), Map.put(mr, "reviewers", [%{"id" => 1}])] do
      Process.put(:mr_reads, [changed, changed])
      result = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
      assert result == {:error, :ticket_mr_human_state_changed}
      assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen
    end

    mutate = fn ->
      Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [key])
      {:ok, mr}
    end

    Process.put(:mr_reads, [mutate, mr])
    result = TicketMrOperation.current_delivery_receipt(ctx.store, "run", factory, options)
    assert result == {:error, :ticket_mr_request_changed}
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE request_key = ?", [key])
    assert Enum.map(tables, &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == frozen
  end

  defp assert_ci_progression(ctx, factory, options, run, mr, key, claim) do
    options = Keyword.put(options, :connector, CiReader)
    authorization = push_authorization(ctx.store, run)
    protected_tables = ~w(runs factory_tasks desktop_requests ticket_mr_claims control workspace_access worker_evidence events ticket_jira_effects)
    protected_before_read_failure = Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end)
    Process.put(:ci_reads, [{"get_merge_request", {:error, :fixture_ci_read_unavailable}}])
    assert {:error, :fixture_ci_read_unavailable} = TicketMrOperation.adopt_ci(ctx.store, "run", authorization, factory, options)
    assert Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end) == protected_before_read_failure

    waiting_mr = Map.put(mr, "head_pipeline", nil)
    Process.put(:ci_reads, [{"get_merge_request", {:ok, waiting_mr}}, {"get_merge_request", {:ok, waiting_mr}}])
    assert {:ok, %{status: "CI_WAIT", run: waiting}} = TicketMrOperation.adopt_ci(ctx.store, "run", authorization, factory, options)
    assert waiting["state"] == "CI_WAITING" and waiting["verifier_round"] == run["verifier_round"]

    controller = %{
      store: ctx.store,
      task_supervisor: start_supervised!(Task.Supervisor, id: :post_ci_supervisor),
      recipient: self(),
      workspace_root: Path.join(ctx.root, "workspaces"),
      factory: factory
    }

    {context, tick_opts} = tick_controller(controller, options)
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_CI_POLL_WAIT"))
    assert Process.get(:ci_reads) == []

    pipeline = %{
      "id" => "99",
      "project_id" => "1000",
      "sha" => run["candidate_sha"],
      "ref" => "refs/merge-requests/1/head",
      "source" => "merge_request_event",
      "status" => "success",
      "web_url" => "https://fixture.invalid/pipelines/99"
    }

    passing_mr = Map.put(mr, "head_pipeline", pipeline)
    job = %{"id" => "100", "name" => "bazel", "status" => "success", "allow_failure" => false, "web_url" => "https://fixture.invalid/jobs/100", "pipeline" => Map.take(pipeline, ~w(id project_id sha))}
    reads = [{"get_merge_request", {:ok, passing_mr}}, {"get_pipeline", {:ok, pipeline}}, {"list_pipeline_jobs", {:ok, [job]}}, {"list_pipeline_jobs", {:ok, []}}]
    failed_pipeline = Map.put(pipeline, "status", "failed")
    failed_mr = Map.put(mr, "head_pipeline", failed_pipeline)
    failed_job = Map.put(job, "status", "failed")

    Process.put(:ci_reads, [
      {"get_merge_request", {:ok, failed_mr}},
      {"get_pipeline", {:ok, failed_pipeline}},
      {"list_pipeline_jobs", {:ok, [failed_job]}},
      {"list_pipeline_jobs", {:ok, []}},
      {"get_merge_request", {:ok, failed_mr}}
    ])

    assert {:ok, %{status: "CI_BLOCK", run: blocked}} = TicketMrOperation.adopt_ci(ctx.store, "run", authorization, factory, options)
    assert blocked["state"] == "CI_WAITING" and blocked["verifier_round"] == run["verifier_round"]
    assert Jason.decode!(blocked["ci_evidence_json"])["status"] == "BLOCK"
    assert {:error, :ticket_verifier_ci_evidence_mismatch} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)

    Process.put(
      :ci_reads,
      reads ++
        [
          {"get_merge_request",
           fn ->
             Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_json = '{}' WHERE request_key = ?", [key])
             {:ok, passing_mr}
           end}
        ]
    )

    assert {:error, :ticket_mr_claim_unproven} = TicketMrOperation.adopt_ci(ctx.store, "run", authorization, factory, options)
    assert {:ok, ^blocked} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_json = ? WHERE request_key = ?", [claim["receipt_json"], key])

    {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_last_checked_at: nil})
    Process.put(:ci_reads, reads ++ [{"get_merge_request", {:ok, passing_mr}}])
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_CI_PASS"))
    assert {:ok, verified} = RunLedger.get(ctx.store, "run")
    assert verified["state"] == "VERIFYING" and verified["verifier_round"] == run["verifier_round"] + 1
    assert {:error, :ticket_ci_stage_invalid} = TicketMrOperation.adopt_ci(ctx.store, "run", authorization, factory, options)
    assert {:ok, packet} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    assert Jason.decode!(packet)["ci_evidence"]["status"] == "PASS"
    assert Jason.decode!(packet)["ci_evidence"]["sha"] == run["candidate_sha"]
    assert {:ok, ^verified} = RunLedger.get(ctx.store, "run")

    assert complete_stage(context, options)["state"] == "PUSHING"
    {:ok, final} = RunLedger.get(ctx.store, "run")
    assert final["candidate_sha"] == run["candidate_sha"]
    assert {:ok, %{run: pushed}} = TicketPush.step(ctx.store, "run", push_authorization(ctx.store, final), options)
    assert pushed["state"] == "MR_CREATING" and pushed["candidate_sha"] == run["candidate_sha"]
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "typed MR claim survives restart and historical readback never rewrites newer controller state", ctx do
    {factory, options, authorization, request, pushed} = prepared_mr(ctx)
    key = request["request_key"]
    proof = mr_guard(request)
    admission = %{factory: factory, authorization: authorization, guard: proof}
    claim_options = Keyword.put(options, :ticket_mr_admission, admission)
    rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows

    protected_tables = ~w(runs desktop_requests ticket_mr_claims control factory_tasks workspace_access worker_evidence events ticket_jira_effects ticket_checkout_intents)

    protected_state = fn store ->
      Map.new(protected_tables, fn table ->
        {table, Store.query!(store, "SELECT * FROM #{table} ORDER BY 1").rows}
      end)
    end

    before_mr_probes = protected_state.(ctx.store)
    source_file = Path.join(ctx.path, "fixture.txt")
    git_dir = ctx.path |> git(["rev-parse", "--absolute-git-dir"]) |> String.trim()
    source_bytes = File.read!(source_file)
    source_index = File.read!(Path.join(git_dir, "index"))
    source_head = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()

    incomplete_guard = Map.take(proof, ["source_thread_id"])

    assert {:error, :mr_guard_evidence_invalid} =
             TicketMrOperation.claim_from_jira(
               ctx.store,
               key,
               factory,
               incomplete_guard,
               Keyword.put(options, :jira_reader, JiraReader)
             )

    assert protected_state.(ctx.store) == before_mr_probes
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == nil
    assert File.read!(source_file) == source_bytes
    assert File.read!(Path.join(git_dir, "index")) == source_index
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == source_head

    path_drift_factory = put_in(factory, [:repositories, "grail", "path"], Path.join(ctx.root, "different-source-path"))

    assert {:error, :ticket_mr_request_binding_mismatch} =
             TicketMrOperation.prepare(
               ctx.store,
               "run",
               authorization,
               path_drift_factory,
               request["cwd"],
               "Fixture description",
               options
             )

    assert protected_state.(ctx.store) == before_mr_probes
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert File.read!(source_file) == source_bytes
    assert File.read!(Path.join(git_dir, "index")) == source_index
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == source_head

    control_before = Store.one!(ctx.store, "SELECT * FROM control WHERE scope = ?", [factory.scope])

    assert {:error, :u11_mr_control_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "DELETE FROM control WHERE scope = ?", [factory.scope])
               removed_control_state = protected_state.(tx)

               assert {:error, :ticket_mr_binding_unproven} =
                        TicketMrOperation.bind(tx, "run", authorization, factory, request["cwd"], options)

               assert protected_state.(tx) == removed_control_state
               Exqlite.rollback(tx, :u11_mr_control_probe_rolled_back)
             end)

    assert protected_state.(ctx.store) == before_mr_probes
    assert Store.one!(ctx.store, "SELECT * FROM control WHERE scope = ?", [factory.scope]) == control_before
    assert File.read!(source_file) == source_bytes
    assert File.read!(Path.join(git_dir, "index")) == source_index
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == source_head

    assert {:ok, binding} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, request["cwd"], options)
    assert binding["run_id"] == "run"
    assert protected_state.(ctx.store) == before_mr_probes
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == nil

    assert {:error, :ticket_jira_not_dispatchable} =
             TicketMrOperation.claim_from_jira(ctx.store, key, factory, proof, Keyword.put(options, :jira_reader, BlockedJiraReader))

    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == nil

    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, %{})
    assert {:error, :worker_runtime_identity_unproven} = DesktopRequest.claim(ctx.store, key, claim_options)
    admission = %{admission | guard: mr_guard(request)}
    assert {:error, :worker_runtime_identity_unproven} = TicketMrOperation.claim_followup_args(ctx.store, key, admission, options)
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == nil
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)

    assert {:error, :mr_guard_evidence_required} = TicketMrOperation.claim_followup_args(ctx.store, key, %{admission | guard: nil}, options)
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert DesktopRequest.list_reconciliation(ctx.store) == []

    foreign = Map.put(proof, "source_thread_id", "foreign")
    assert {:error, :mr_guard_broker_mismatch} = TicketMrOperation.claim_followup_args(ctx.store, key, %{admission | guard: foreign}, options)

    add_mr_feedback_owner(ctx.store, key)
    assert {:error, :ticket_mr_request_ownership_conflict} = DesktopRequest.claim(ctx.store, key, claim_options)
    Store.query!(ctx.store, "DELETE FROM mr_feedback_notes WHERE feedback_key = 'mixed-mr-owner'")

    Control.initialize(ctx.store, %{factory | scope: "other-scope"})

    blocker_attrs =
      request
      |> Map.take(~w(request_key target_kind target_key action codex_project_id model reasoning_effort title prompt cwd))
      |> Map.merge(%{
        "request_key" => "other-controller",
        "target_key" => "other-scope",
        "action" => "CREATE",
        "schema" => StageSchemas.for_stage(:gitlab_mr),
        "metadata" => %{"issue_key" => "FACTORY-CONTROLLER"}
      })

    assert {:ok, _} = DesktopRequest.enqueue(ctx.store, blocker_attrs)
    assert {:error, :ticket_mr_controller_busy} = DesktopRequest.claim(ctx.store, key, claim_options)
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = 'other-controller'")

    proof = mr_guard(request)
    admission = %{admission | guard: proof}

    Store.query!(ctx.store, """
    CREATE TRIGGER reject_mr_claim AFTER INSERT ON ticket_mr_claims
    BEGIN SELECT RAISE(ABORT, 'fixture claim failure'); END
    """)

    assert_raise Exqlite.Error, ~r/fixture claim failure/, fn ->
      result = TicketMrOperation.claim_followup_args(ctx.store, key, admission, options)
      flunk("rollback trigger was not reached: #{inspect(result)}")
    end

    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == nil
    Store.query!(ctx.store, "DROP TRIGGER reject_mr_claim")

    Process.put(:mr_native, proof["native"])
    owner_opts = Keyword.merge(options, jira_reader: JiraReader, mr_app_server: MrNativeReader)
    assert {:error, :mr_guard_broker_mismatch} = TicketMrOperation.claim_with_owner(ctx.store, key, factory, "foreign", fn _ -> flunk("foreign broker reached owner read") end, owner_opts)

    proof = mr_guard(request)
    Process.put(:mr_native, proof["native"])

    assert {:error, :mr_guard_observation_expired} =
             TicketMrOperation.claim_with_owner(ctx.store, key, factory, proof["source_thread_id"], fn _ -> {:ok, Map.put(proof["owner"], "observed_at", "2020-01-01T00:00:00Z")} end, owner_opts)

    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)

    proof = mr_guard(request)
    Process.put(:mr_native, proof["native"])

    assert {:ok, %{request: claimed, arguments: args}} =
             TicketMrOperation.claim_with_owner(
               ctx.store,
               key,
               factory,
               proof["source_thread_id"],
               fn current ->
                 assert current == request
                 {:ok, proof["owner"]}
               end,
               owner_opts
             )

    assert args == %{"threadId" => request["existing_thread_id"], "model" => request["model"], "thinking" => request["reasoning_effort"], "prompt" => request["prompt"]}
    assert claimed["status"] == "FOLLOWUP_UNCERTAIN"
    original_claim = Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key])
    assert :ok = TicketMrOperation.authorize_readback(ctx.store, claimed)
    assert [^claimed] = DesktopRequest.list_reconciliation(ctx.store)
    assert {:error, :ticket_mr_request_already_issued} = DesktopRequest.claim(ctx.store, key, claim_options)
    assert {:error, :ticket_mr_request_already_issued} = TicketMrOperation.claim_followup_args(ctx.store, key, admission, options)
    assert {:error, :ticket_mr_request_already_issued} = DesktopRequest.authorize_issuance(ctx.store, claimed, claim_options)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == original_claim

    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:error, :ticket_mr_request_already_issued} = DesktopRequest.claim(reopened, key, claim_options)
      duplicate = TicketMrOperation.claim_followup_args(reopened, key, admission, options)
      assert {:error, :ticket_mr_request_already_issued} = duplicate
      assert :ok = TicketMrOperation.authorize_readback(reopened, claimed)
    after
      GenServer.stop(reopened)
    end

    Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_json = '{}' WHERE request_key = ?", [key])
    assert {:error, :ticket_mr_claim_unproven} = DesktopRequest.record_thread(ctx.store, key, "controller-thread", "project-grail")
    assert DesktopRequest.list_reconciliation(ctx.store) == []
    Store.query!(ctx.store, "UPDATE ticket_mr_claims SET receipt_json = ? WHERE request_key = ?", [original_claim["receipt_json"], key])
    Store.query!(ctx.store, "UPDATE runs SET execution_mode = 'LEGACY' WHERE run_id = 'run'")
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = '{}' WHERE request_key = ?", [key])
    assert {:error, :ticket_mr_claim_unproven} = DesktopRequest.record_thread(ctx.store, key, "controller-thread", "project-grail")
    assert DesktopRequest.list_reconciliation(ctx.store) == []
    assert DesktopRequest.list_pending(ctx.store) == []
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [request["metadata_json"], key])
    assert :ok = TicketMrOperation.authorize_readback(ctx.store, claimed)
    Store.query!(ctx.store, "UPDATE runs SET execution_mode = 'TICKET_SUPERVISOR_V1' WHERE run_id = 'run'")
    add_mr_feedback_owner(ctx.store, key)
    assert {:error, :ticket_mr_claim_unproven} = TicketMrOperation.authorize_readback(ctx.store, claimed)
    Store.query!(ctx.store, "DELETE FROM mr_feedback_notes WHERE feedback_key = 'mixed-mr-owner'")

    Control.record_controller_task(ctx.store, factory, "controller-thread", "newer-controller-turn", %{project_id: "project-grail"})
    Store.query!(ctx.store, "UPDATE control SET controller_model = 'gpt-6.1-sol', controller_reasoning_effort = 'high' WHERE scope = 'scope'")
    control = Control.status(ctx.store, "scope")
    assert {:error, :thread_route_mismatch} = DesktopRequest.record_thread(ctx.store, key, "foreign", "project-grail")
    assert {:ok, recorded} = DesktopRequest.record_thread(ctx.store, key, "controller-thread", "project-grail")
    assert recorded["status"] == "THREAD_RECORDED"
    assert Control.status(ctx.store, "scope") == control

    output = %{
      "result" => %{
        "status" => "PASS",
        "mr_url" => "https://fixture.invalid/mr/1",
        "iid" => 1,
        "source_branch" => pushed["branch"],
        "target_branch" => pushed["base_branch"],
        "sha" => pushed["candidate_sha"],
        "draft" => true,
        "reviewers_count" => 0,
        "assignee_id" => 11_599_766,
        "state" => "opened"
      },
      "completed_tool_calls" => [%{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed"}]
    }

    completion = %{thread_id: "controller-thread", turn_id: "mr-operation-turn", output: output}
    assert {:error, :turn_replayed} = DesktopRequest.complete(ctx.store, key, %{completion | turn_id: "original-turn"})
    assert {:ok, completed} = DesktopRequest.complete(ctx.store, key, completion)
    assert completed["status"] == "SUCCEEDED"
    assert {:ok, ^completed} = DesktopRequest.complete(ctx.store, key, completion)
    assert Control.status(ctx.store, "scope") == control
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == rows
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
  end

  defp add_mr_feedback_owner(store, key) do
    Store.query!(
      store,
      """
      INSERT INTO mr_feedback_notes(feedback_key, run_id, project, mr_iid, discussion_id, note_id, note_updated_at, author_id, body_sha256, status, request_key, created_at, updated_at)
      VALUES ('mixed-mr-owner','run','fixture/repository',1,'discussion',1,'now',11599766,'hash','PENDING',?,'now','now')
      """,
      [key]
    )
  end

  defp prepared_mr(ctx), do: elem(prepared_mr(ctx, false), 1)

  defp prepared_mr(ctx, return_context?) do
    {context, factory, options, authorization, cwd, pushed} = prepared_mr_context(ctx)
    assert {:ok, %{request: request}} = TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "Fixture description", options)
    result = {factory, options, authorization, request, pushed}
    if return_context?, do: {context, result}, else: {nil, result}
  end

  defp prepared_mr_context(ctx) do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "mr-claim-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, run} = RunLedger.get(ctx.store, "run")

    {run, options} =
      if ctx[:mr_preflight] do
        {:ok, %{run: preflight}} = RunLedger.update(ctx.store, "run", %{state: "CI_PUSHING"})
        {preflight, Keyword.put(options, :ci_preflight_authorized, true)}
      else
        {run, options}
      end

    assert {:ok, %{run: pushed}} = TicketPush.step(ctx.store, "run", push_authorization(ctx.store, run), options)

    factory =
      Map.merge(context.factory, %{
        scope: "scope",
        dispatcher_id: "fixture",
        controller_codex_project_id: "project-grail",
        task_transport: "desktop_broker",
        ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]},
        repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master", "gitlab_project" => "fixture/repository", "gitlab_project_id" => "1000"}}
      })

    factory = put_in(factory, [:models, "roles", "orchestrator"], %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "low"})
    factory = if ctx[:mr_preflight], do: put_in(factory.repositories["grail"]["ci_preflight"], "draft_mr"), else: factory
    Control.initialize(ctx.store, factory)
    Control.record_controller_task(ctx.store, factory, "controller-thread", "original-turn", %{project_id: "project-grail"})
    cwd = Path.join(ctx.root, "control")
    File.mkdir_p!(cwd)
    authorization = push_authorization(ctx.store, pushed)
    {context, factory, options, authorization, cwd, pushed}
  end

  test "concurrent MR preparation preserves and reuses the pending peer request", ctx do
    {_context, factory, options, authorization, cwd, pushed} = prepared_mr_context(ctx)
    key = "remote.origin.uploadpack"
    entered = Path.join(ctx.root, "outer-mr-prepare-entered")
    second_call = Path.join(ctx.root, "inner-mr-prepare-entered")
    release = Path.join(ctx.root, "release-outer-mr-prepare")
    upload = Path.join(ctx.root, "synchronized-upload-pack")
    git_executable = "/Library/Developer/CommandLineTools/usr/bin/git"
    repo = ctx.repo

    {previous_config, previous_status} =
      System.cmd(git_executable, ["-C", repo, "config", "--local", "--get-all", key], stderr_to_stdout: true)

    previous_values = if previous_status == 0, do: String.split(previous_config, "\n", trim: true), else: []

    protected_tables = ~w(runs control factory_tasks worker_evidence workspace_access events ticket_mr_claims desktop_requests ticket_checkout_intents ticket_jira_effects)

    protected_state = fn ->
      Map.new(protected_tables, fn table ->
        {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows}
      end)
    end

    remote = String.trim(git(repo, ["remote", "get-url", "origin"]))
    source_paths = [repo, pushed["worktree"]] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    source_state = fn ->
      path_state =
        Map.new(source_paths, fn path ->
          git_dir = String.trim(git(path, ["rev-parse", "--absolute-git-dir"]))
          source_file = Path.join(path, "fixture.txt")
          untracked_file = Path.join(path, "untracked-resume-fixture.txt")
          index_file = Path.join(git_dir, "index")

          {path,
           %{
             source_bytes: if(File.regular?(source_file), do: File.read!(source_file)),
             untracked_bytes: if(File.regular?(untracked_file), do: File.read!(untracked_file)),
             index_bytes: File.read!(index_file),
             head: String.trim(git(path, ["rev-parse", "HEAD"])),
             head_ref: String.trim(git(path, ["symbolic-ref", "HEAD"])),
             status: git(path, ["--no-optional-locks", "status", "--porcelain=v1"]),
             staged_bytes: git(path, ["show", ":fixture.txt"])
           }}
        end)

      remote_ref = String.trim(git(remote, ["rev-parse", "refs/heads/#{pushed["branch"]}"]))
      %{paths: path_state, remote_ref: remote_ref}
    end

    baseline_rows = protected_state.()
    baseline_source = source_state.()

    script = """
    #!/bin/sh
    if [ ! -e '#{entered}' ]; then
      : > '#{entered}'
      count=0
      while [ ! -e '#{release}' ]; do
        if [ "$count" -ge 100 ]; then exit 1; fi
        count=$((count + 1))
        sleep 0.05
      done
    else
      : > '#{second_call}'
    fi
    exec '#{git_executable}' upload-pack "$@"
    """

    File.write!(upload, script)
    File.chmod!(upload, 0o700)
    git(repo, ["config", "--local", "--replace-all", key, upload])

    outer_task =
      Task.async(fn ->
        TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "OUTER", options)
      end)

    try do
      marker_found =
        Enum.reduce_while(1..80, false, fn _, _ ->
          if File.exists?(entered) do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert marker_found, "outer Git upload-pack did not reach the synchronization marker within four seconds"
      assert protected_state.() == baseline_rows
      assert source_state.() == baseline_source

      assert {:ok, %{status: "REQUEST_PREPARED", request: inner_request}} =
               TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "INNER", options)

      assert File.exists?(second_call)
      assert inner_request["status"] == "PENDING"
      assert inner_request["target_kind"] == "CONTROLLER"
      assert inner_request["target_key"] == factory.scope
      pending_rows = protected_state.()
      pending_source = source_state.()
      assert {:error, :ticket_mr_claim_unproven} = DesktopRequest.fail(ctx.store, inner_request["request_key"], "U11 competing MR request failed")
      assert protected_state.() == pending_rows
      assert source_state.() == pending_source
      assert {:ok, ^inner_request} = DesktopRequest.get(ctx.store, inner_request["request_key"])
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE request_key = ?", [inner_request["request_key"]])["count"] == 1

      assert Store.query!(ctx.store, "SELECT request_key FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND target_key = ? AND status = 'PENDING' ORDER BY request_key", [factory.scope]).rows ==
               [[inner_request["request_key"]]]

      assert Store.query!(ctx.store, "SELECT request_key FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND target_key = ? AND status = 'FAILED' ORDER BY request_key", [factory.scope]).rows ==
               []

      assert Store.query!(ctx.store, "SELECT * FROM ticket_mr_claims ORDER BY request_key").rows == []

      pending_peer_rows = protected_state.()
      pending_peer_source = source_state.()
      File.write!(release, "release\n")

      assert {:error, :ticket_mr_controller_busy} = Task.await(outer_task, 10_000)
      assert protected_state.() == pending_peer_rows
      assert source_state.() == pending_peer_source

      assert {:ok, %{status: "EXISTING_REQUEST", request: ^inner_request}} =
               TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "INNER", options)

      assert protected_state.() == pending_peer_rows
      assert source_state.() == pending_peer_source
      assert {:ok, ^inner_request} = DesktopRequest.get(ctx.store, inner_request["request_key"])
    after
      File.write!(release, "release\n")
      if Process.alive?(outer_task.pid), do: Task.shutdown(outer_task, 5_000) || Task.shutdown(outer_task, :brutal_kill)
      git(repo, ["config", "--local", "--unset-all", key])

      for value <- previous_values do
        git(repo, ["config", "--local", "--add", key, value])
      end
    end
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "both MR claim entrypoints refresh Jira after the runtime probe without issuing a blocked request", ctx do
    {factory, options, authorization, request, _pushed} = prepared_mr(ctx)
    marker = Path.join(ctx.root, "block-after-runtime")
    Process.put(:mr_jira_block_after_runtime, marker)
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, :supported, "touch '#{marker}'")

    for entrypoint <- [:generic, :typed] do
      if File.exists?(marker), do: File.rm!(marker)
      admission = %{factory: factory, authorization: authorization, guard: mr_guard(request)}

      result =
        case entrypoint do
          :generic -> DesktopRequest.claim(ctx.store, request["request_key"], Keyword.put(options, :ticket_mr_admission, admission))
          :typed -> TicketMrOperation.claim_followup_args(ctx.store, request["request_key"], admission, options)
        end

      assert result == {:error, :ticket_jira_not_dispatchable}
      assert File.exists?(marker)
      assert {:ok, ^request} = DesktopRequest.get(ctx.store, request["request_key"])
      assert Store.query!(ctx.store, "SELECT * FROM ticket_mr_claims").rows == []
    end
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "MR claims reject request, run and controller drift during outside-transaction initialization", ctx do
    {factory, options, authorization, request, _pushed} = prepared_mr(ctx)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    control = Store.one!(ctx.store, "SELECT controller_thread_id FROM control WHERE scope = 'scope'")
    marker = Path.join(ctx.root, "mr-runtime-drift")
    key = request["request_key"]

    mutations = [
      "UPDATE runs SET updated_at = 'drifted' WHERE run_id = 'run'",
      "UPDATE desktop_requests SET title = 'changed' WHERE request_key = '#{key}'",
      "UPDATE control SET controller_thread_id = 'different' WHERE scope = 'scope'"
    ]

    for sql <- mutations do
      Store.query!(ctx.store, "UPDATE runs SET updated_at = ? WHERE run_id = 'run'", [before["updated_at"]])
      Store.query!(ctx.store, "UPDATE desktop_requests SET title = ? WHERE request_key = ?", [request["title"], key])
      Store.query!(ctx.store, "UPDATE control SET controller_thread_id = ? WHERE scope = 'scope'", [control["controller_thread_id"]])
      if File.exists?(marker), do: File.rm!(marker)
      command = "/usr/bin/sqlite3 '#{ctx.database}' \"#{sql}\" || exit 1; touch '#{marker}'"
      SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, :supported, command)
      admission = %{factory: factory, authorization: authorization, guard: mr_guard(request)}
      assert {:error, _reason} = TicketMrOperation.claim_followup_args(ctx.store, key, admission, options)
      assert File.exists?(marker)
      assert {:ok, unclaimed} = DesktopRequest.get(ctx.store, key)
      assert unclaimed["status"] == "PENDING" and unclaimed["claimed_at"] == nil
      assert Store.query!(ctx.store, "SELECT * FROM ticket_mr_claims").rows == []
    end
  end

  defp mr_guard(request), do: SymphonyElixir.DesktopTicketLifecycleFixture.mr_guard(request)

  test "MR operation binds exact completed delivery and keeps its key when the controller turn advances", ctx do
    repository_alias = Path.join(ctx.root, "repository-alias")
    File.ln_s!(ctx.repo, repository_alias)
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "mr-binding-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{run: pushed}} = TicketPush.step(ctx.store, "run", push_authorization(ctx.store, run), options)

    factory =
      Map.merge(context.factory, %{
        scope: "scope",
        dispatcher_id: "fixture",
        controller_codex_project_id: "project-grail",
        task_transport: "desktop_broker",
        ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]},
        repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master", "gitlab_project" => "fixture/repository", "gitlab_project_id" => "1000"}}
      })

    factory = put_in(factory, [:models, "roles", "orchestrator"], %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "low"})

    Control.initialize(ctx.store, factory)
    Control.record_controller_task(ctx.store, factory, "controller-thread", "original-turn", %{project_id: "project-grail"})
    cwd = Path.join([ctx.root, "workspaces", "factory-controller", "scope"])
    File.mkdir_p!(cwd)
    authorization = push_authorization(ctx.store, pushed)
    assert {:ok, binding} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, cwd, options)
    integer_factory = put_in(factory, [:repositories, "grail", "gitlab_project_id"], 1000)
    assert {:ok, ^binding} = TicketMrOperation.bind(ctx.store, "run", authorization, integer_factory, cwd, options)
    assert binding["gitlab_project_id"] == 1000
    assert {:ok, key} = TicketMrOperation.request_key(binding)
    assert {:ok, ^key} = TicketMrOperation.request_key(binding |> Enum.reverse() |> Map.new())
    assert binding["stage"] == "MR_CREATING" and binding["ci_preflight"] == false
    assert binding["completed_push_sha256"] == Base.encode16(:crypto.hash(:sha256, pushed["candidate_handoff"]), case: :lower)
    legacy_key = key

    assert {:error, :ticket_mr_new_admission_disabled} = TicketMrOperation.prepare(ctx.store, "run", authorization, Map.put(factory, :ticket_supervisor, %{}), cwd, "Fixture description", options)
    assert {:error, :ticket_mr_transport_mismatch} = TicketMrOperation.prepare(ctx.store, "run", authorization, Map.put(factory, :task_transport, "app_server"), cwd, "Fixture description", options)

    assert {:ok, blocker} =
             DesktopRequest.enqueue(ctx.store, %{
               request_key: "unrelated-controller",
               target_kind: "CONTROLLER",
               target_key: "scope",
               action: "FOLLOWUP",
               codex_project_id: "project-grail",
               existing_thread_id: "controller-thread",
               model: "gpt-6-luna",
               reasoning_effort: "low",
               title: "Fixture controller",
               prompt: "Unrelated fixture operation",
               cwd: cwd,
               schema: StageSchemas.for_stage(:gitlab_mr),
               metadata: %{"issue_key" => "FACTORY-CONTROLLER", "previous_turn_id" => "original-turn"}
             })

    assert {:error, :ticket_mr_controller_busy} = TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "Fixture description", options)
    assert {:error, :unknown_request} = DesktopRequest.get(ctx.store, key)
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [blocker["request_key"]])
    {tick_context, tick_opts} = tick_controller(%{context | factory: factory}, options)
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(tick_context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_REQUEST_PREPARED"))
    [request] = DesktopRequest.list_pending(ctx.store, 50, ticket_mr_factory: factory)
    key = request["request_key"]
    assert key != legacy_key
    {:ok, metadata} = Jason.decode(request["metadata_json"])
    binding = metadata["delivery_operation"]
    assert binding["version"] == 2
    assert binding["completed_push_sha256"] == Base.encode16(:crypto.hash(:sha256, pushed["candidate_handoff"]), case: :lower)
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert {:ok, %{launches: [], events: repeated}} = Scheduler.tick(tick_context, tick_opts)
    assert repeated == []
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, key)
    assert DesktopRequest.list_pending(ctx.store) == []
    assert [^request] = DesktopRequest.list_pending(ctx.store, 50, ticket_mr_factory: factory)
    assert DesktopRequest.list_pending(ctx.store, 50, ticket_mr_factory: Map.put(factory, :ticket_supervisor, %{})) == []
    assert request["request_key"] == key
    legacy_binding = Map.put(binding, "version", 1)
    {:ok, legacy_key} = TicketMrOperation.request_key(legacy_binding)
    legacy_metadata = Map.put(metadata, "delivery_operation", legacy_binding)

    request_attrs =
      request
      |> Map.take(~w(target_kind target_key action codex_project_id existing_thread_id model reasoning_effort title prompt cwd))
      |> Map.put("request_key", legacy_key)
      |> Map.put("schema", Jason.decode!(request["schema_json"]))
      |> Map.put("metadata", legacy_metadata)

    Store.query!(ctx.store, "DELETE FROM desktop_requests WHERE request_key = ?", [key])
    assert {:ok, legacy_request} = DesktopRequest.enqueue(ctx.store, request_attrs)
    assert {:ok, %{status: "EXISTING_REQUEST", request: ^legacy_request}} = TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "Ignored legacy prompt", options)

    Store.query!(ctx.store, "DELETE FROM desktop_requests WHERE request_key = ?", [legacy_key])
    mismatched_binding = Map.put(legacy_binding, "completed_push_sha256", String.duplicate("f", 64))
    mismatched_metadata = Map.put(metadata, "delivery_operation", mismatched_binding)
    mismatched_attrs = Map.put(request_attrs, "metadata", mismatched_metadata)
    assert {:ok, unresolved} = DesktopRequest.enqueue(ctx.store, mismatched_attrs)
    assert {:error, :ticket_mr_v1_predecessor_unresolved} = TicketMrOperation.prepare(ctx.store, "run", authorization, factory, cwd, "Do not roll over unresolved v1", options)
    assert {:error, :unknown_request} = DesktopRequest.get(ctx.store, key)
    Store.query!(ctx.store, "DELETE FROM desktop_requests WHERE request_key = ?", [unresolved["request_key"]])
    assert {:ok, request} = DesktopRequest.enqueue(ctx.store, Map.put(request_attrs, "request_key", key) |> Map.put("metadata", metadata))

    assert request["model"] == "gpt-6-luna" and request["reasoning_effort"] == "low"
    assert request["prompt"] =~ "return exactly one raw JSON object"
    assert request["prompt"] =~ "Before any mutation, read"
    assert request["prompt"] =~ "return BLOCK without changing it or creating a replacement"
    assert request["prompt"] =~ "even a\ndescription-only or assignee-only update"
    assert request["prompt"] =~ "never redraft or clear reviewers"

    assert :ok = TicketMrOperation.validate_request(binding, request)
    assert {:ok, ^binding} = TicketMrOperation.check_new_request(ctx.store, key, authorization, factory, options)
    assert {:error, :ticket_mr_new_admission_disabled} = TicketMrOperation.check_new_request(ctx.store, key, authorization, Map.put(factory, :ticket_supervisor, %{}), options)
    assert {:error, :ticket_authorization_expired} = TicketMrOperation.check_new_request(ctx.store, key, Map.put(authorization, "observed_at", "2020-01-01T00:00:00Z"), factory, options)

    for field <- ~w(claimed_at thread_id turn_id target_observation_json verified_project_id verified_cwd verified_head_sha output_json) do
      Store.query!(ctx.store, "UPDATE desktop_requests SET #{field} = 'unproven' WHERE request_key = ?", [key])
      assert {:error, :ticket_mr_request_already_issued} = TicketMrOperation.check_new_request(ctx.store, key, authorization, factory, options)
      Store.query!(ctx.store, "UPDATE desktop_requests SET #{field} = NULL WHERE request_key = ?", [key])
    end

    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN' WHERE request_key = ?", [key])
    assert {:error, :ticket_mr_request_already_issued} = TicketMrOperation.check_new_request(ctx.store, key, authorization, factory, options)
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'PENDING' WHERE request_key = ?", [key])
    assert {:error, :request_run_quarantined} = DesktopRequest.claim(ctx.store, key)
    original_rows = Store.query!(ctx.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows
    Control.record_controller_task(ctx.store, factory, "controller-thread", "later-turn", %{project_id: "project-grail"})
    assert {:error, :ticket_mr_controller_turn_changed} = TicketMrOperation.check_new_request(ctx.store, key, authorization, factory, options)
    assert {:ok, ^legacy_binding} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, cwd, options)
    recovery_factory = factory |> Map.put(:models, %{}) |> Map.put(:ticket_supervisor, %{})
    stale = Map.put(authorization, "observed_at", "2020-01-01T00:00:00Z")
    assert {:ok, %{status: "EXISTING_REQUEST", request: ^request}} = TicketMrOperation.prepare(ctx.store, "run", stale, recovery_factory, cwd, "Different prompt must not be reconstructed", options)
    Store.query!(ctx.store, "UPDATE runs SET manual_validation_required = 1 WHERE run_id = 'run'")
    assert {:error, _} = TicketMrOperation.prepare(ctx.store, "run", stale, recovery_factory, cwd, "Must remain ordinary", options)
    Store.query!(ctx.store, "UPDATE runs SET manual_validation_required = 0 WHERE run_id = 'run'")
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = '{}' WHERE request_key = ?", [key])
    assert {:error, :ticket_mr_request_binding_mismatch} = TicketMrOperation.prepare(ctx.store, "run", stale, recovery_factory, cwd, "Never replace corrupted original", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE request_key = ?", [key])["count"] == 1
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [request["metadata_json"], key])
    assert :ok = TicketMrOperation.validate_request(binding, request)
    assert Store.query!(ctx.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows == original_rows

    for changed <- [
          Map.put(binding, "candidate_sha", String.duplicate("1", 40)),
          Map.put(binding, "gitlab_project", "foreign/repository"),
          Map.put(binding, "controller_thread_id", "another-controller"),
          Map.put(binding, "completed_push_sha256", String.duplicate("1", 64)),
          Map.put(binding, "scope", "another-scope")
        ] do
      assert {:error, :ticket_mr_request_binding_mismatch} = TicketMrOperation.validate_request(changed, request)
    end

    assert {:error, :ticket_mr_binding_invalid} = TicketMrOperation.request_key(Map.put(binding, "operation", "WRITE_JIRA"))
    assert {:error, :ticket_mr_binding_invalid} = TicketMrOperation.request_key(Map.delete(binding, "completed_push_sha256"))
    assert {:error, :ticket_mr_controller_source_overlap} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, pushed["worktree"], options)
    assert {:error, :ticket_mr_controller_source_overlap} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, ctx.repo, options)
    directory = TicketMrOperation.controller_cwd(repository_alias, repository_alias, pushed["worktree"])
    assert {:error, :ticket_mr_controller_source_overlap} = directory
    git(remote, ["update-ref", "refs/heads/" <> pushed["branch"], ctx.sha])
    assert {:error, :ticket_mr_remote_candidate_changed} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, cwd, options)
    git(remote, ["update-ref", "refs/heads/" <> pushed["branch"], pushed["candidate_sha"]])
    upload = Path.join(ctx.root, "racing-upload-pack")
    marker = Path.join(ctx.root, "run-race-observed")

    File.write!(
      upload,
      "#!/bin/sh\n/usr/bin/sqlite3 '#{ctx.database}' \"UPDATE runs SET state = 'CI_MR_CREATING' WHERE run_id = 'run'\"\n: > '#{marker}'\nexec /Library/Developer/CommandLineTools/usr/bin/git upload-pack \"$@\"\n"
    )

    File.chmod!(upload, 0o700)
    git(ctx.repo, ["config", "remote.origin.uploadpack", upload])
    assert {:error, :ticket_mr_candidate_changed} = TicketMrOperation.bind(ctx.store, "run", authorization, factory, cwd, options)
    assert File.exists?(marker)
    git(ctx.repo, ["config", "--unset", "remote.origin.uploadpack"])
    Store.query!(ctx.store, "UPDATE runs SET state = 'MR_CREATING' WHERE run_id = 'run'")
    assert {:error, :ticket_authorization_expired} = TicketMrOperation.bind(ctx.store, "run", Map.put(authorization, "observed_at", "2020-01-01T00:00:00Z"), factory, cwd, options)
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [key])

    assert {:ok, historical_controller} =
             DesktopRequest.enqueue(ctx.store, %{
               request_key: "historical-untagged-controller",
               target_kind: "CONTROLLER",
               target_key: "scope",
               action: "FOLLOWUP",
               codex_project_id: "project-grail",
               existing_thread_id: "controller-thread",
               model: "gpt-6-luna",
               reasoning_effort: "low",
               title: "Fixture legacy controller",
               prompt: "Historical untagged fixture",
               cwd: cwd,
               schema: StageSchemas.for_stage(:gitlab_mr),
               metadata: %{"issue_key" => pushed["issue_key"], "previous_turn_id" => "later-turn"}
             })

    assert {:error, :request_run_quarantined} = DesktopRequest.claim(ctx.store, historical_controller["request_key"])
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "new current delivery cannot issue an unresolved v1 MR request with another push digest", ctx do
    {factory, options, authorization, pending_v2, pushed} = prepared_mr(ctx)
    Store.query!(ctx.store, "DELETE FROM desktop_requests WHERE request_key = ?", [pending_v2["request_key"]])
    metadata = Jason.decode!(pending_v2["metadata_json"])
    legacy_binding = metadata["delivery_operation"] |> Map.put("version", 1) |> Map.put("completed_push_sha256", String.duplicate("f", 64))
    {:ok, legacy_key} = TicketMrOperation.request_key(legacy_binding)
    legacy_metadata = Map.put(metadata, "delivery_operation", legacy_binding)

    legacy_attrs =
      pending_v2
      |> Map.take(~w(target_kind target_key action codex_project_id existing_thread_id model reasoning_effort title prompt cwd))
      |> Map.put("request_key", legacy_key)
      |> Map.put("schema", Jason.decode!(pending_v2["schema_json"]))
      |> Map.put("metadata", legacy_metadata)

    assert {:ok, legacy_pending} = DesktopRequest.enqueue(ctx.store, legacy_attrs)
    admission = %{factory: factory, authorization: authorization, guard: mr_guard(legacy_pending)}
    claim_opts = Keyword.put(options, :ticket_mr_admission, admission)
    assert {:error, :ticket_mr_request_binding_mismatch} = DesktopRequest.claim(ctx.store, legacy_key, claim_opts)
    assert {:ok, ^legacy_pending} = DesktopRequest.get(ctx.store, legacy_key)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_mr_claims WHERE request_key = ?", [legacy_key])["count"] == 0
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
  end

  test "a repaired candidate retains completed push history and reserves a new exact push", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "repair-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, original} = RunLedger.get(ctx.store, "run")
    proof = push_authorization(ctx.store, original)
    assert {:ok, %{run: delivered}} = TicketPush.step(ctx.store, "run", proof, options)
    historical = Jason.decode!(delivered["candidate_handoff"])
    {:ok, %{run: repeated}} = RunLedger.update(ctx.store, "run", %{state: "PUSHING"})
    assert {:error, :ticket_push_binding_already_completed} = TicketPush.prepare(ctx.store, "run", push_authorization(ctx.store, repeated), options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "REPAIRING", plan_markdown: "repair"})
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    {:ok, repaired} = RunLedger.get(ctx.store, "run")
    assert repaired["candidate_sha"] != delivered["candidate_sha"]
    proof = push_authorization(ctx.store, repaired)
    original_history = delivered["candidate_handoff"]
    key = historical["reservation_key"]

    for corruption <- [nil, "corrupt"] do
      Store.query!(ctx.store, "UPDATE workspace_access SET release_receipt_json = ? WHERE reservation_key = ?", [corruption, key])
      assert {:error, :ticket_push_history_unproven} = TicketPush.prepare(ctx.store, "run", proof, options)
      assert {:ok, ^repaired} = RunLedger.get(ctx.store, "run")
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    end

    Store.query!(ctx.store, "UPDATE workspace_access SET release_receipt_json = ? WHERE reservation_key = ?", [original_history, key])
    {:ok, old_access} = WorkspaceAccess.get(ctx.store, key)
    Store.query!(ctx.store, "UPDATE workspace_access SET released_at = NULL WHERE reservation_key = ?", [key])
    assert {:error, :ticket_push_history_unproven} = TicketPush.prepare(ctx.store, "run", proof, options)
    Store.query!(ctx.store, "UPDATE workspace_access SET released_at = ? WHERE reservation_key = ?", [old_access["released_at"], key])
    dirty = Path.join(repaired["worktree"], "untracked.txt")
    File.write!(dirty, "dirty\n")
    assert {:error, _} = TicketPush.prepare(ctx.store, "run", proof, options)
    assert {:ok, ^repaired} = RunLedger.get(ctx.store, "run")
    File.rm!(dirty)
    stale = Map.put(proof, "observed_at", "2020-01-01T00:00:00Z")
    assert {:error, :ticket_authorization_expired} = TicketPush.prepare(ctx.store, "run", stale, options)
    assert {:ok, ^repaired} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "CREATE TRIGGER fail_rollover BEFORE UPDATE OF candidate_handoff ON runs BEGIN SELECT RAISE(ABORT, 'rollover failure'); END")
    assert_raise Exqlite.Error, fn -> TicketPush.prepare(ctx.store, "run", proof, options) end
    assert {:ok, ^repaired} = RunLedger.get(ctx.store, "run")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    Store.query!(ctx.store, "DROP TRIGGER fail_rollover")
    assert {:ok, prepared} = TicketPush.prepare(ctx.store, "run", proof, options)
    assert prepared["reservation_key"] != key and prepared["owner_nonce"] != historical["owner_nonce"]
    assert {:ok, old_access} = WorkspaceAccess.get(ctx.store, key)
    assert old_access["release_receipt_json"] == original_history
    assert {:ok, %{run: completed}} = TicketPush.step(ctx.store, "run", proof, options)
    assert completed["state"] == "MR_CREATING"
    assert {:ok, remote_sha} = Worktree.read_remote_branch(%{"path" => ctx.repo}, repaired["branch"])
    assert remote_sha == repaired["candidate_sha"]
    assert {:ok, ^old_access} = WorkspaceAccess.get(ctx.store, key)
  end

  test "versioned REVIEW_READY identity reuses only the exact current completed push", ctx do
    {_context, _options, _authorization, _request, _pushed} = prepared_mr(ctx)
    {:ok, %{run: pushed}} = RunLedger.update(ctx.store, "run", %{state: "MR_CREATING", mr_url: "https://gitlab.example.test/project/-/merge_requests/1"})
    assert {:ok, selected} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert selected.identity_version == 2
    assert selected.disposition == :new
    assert String.starts_with?(selected.operation_key, "ticket-jira:v2:")
    assert {:ok, push} = TicketPush.completed_proof(ctx.store, "run")
    assert selected.push_sha256 == push.envelope_sha256

    {:ok, checkout} = Worktree.checkout_identity(%{"path" => ctx.repo}, ctx.path, clean: true, detached: false, expected_branch: pushed["branch"], expected_sha: pushed["candidate_sha"])
    checkout = Map.new(checkout, fn {key, value} -> {Atom.to_string(key), value} end)
    body = "Review candidate #{pushed["candidate_sha"]}: #{pushed["mr_url"]}"
    assert {:ok, row} = TicketJiraJournal.prepare_review(ctx.store, "run", body, checkout, selected)
    assert row["operation_key"] == selected.operation_key
    assert %{"identity_version" => 2, "review_push_sha256" => sha} = Jason.decode!(row["binding_json"])
    assert sha == selected.push_sha256

    before_access = %{
      journal: Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects ORDER BY operation_key").rows,
      access: Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows,
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows,
      requests: Store.query!(ctx.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
      events: Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
    }

    assert {:error, :unknown_workspace_reservation} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert {:error, :unknown_workspace_reservation} = TicketJiraJournal.prepare_review(ctx.store, "run", body, checkout, selected)
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")

    assert %{
             journal: Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects ORDER BY operation_key").rows,
             access: Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows,
             tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows,
             requests: Store.query!(ctx.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
             events: Store.query!(ctx.store, "SELECT * FROM events ORDER BY id").rows
           } == before_access

    assert {:ok, _access} =
             WorkspaceAccess.acquire(ctx.store, %{
               "reservation_key" => selected.operation_key,
               "run_id" => "run",
               "request_key" => selected.operation_key,
               "task_key" => nil,
               "mode" => "MAINTENANCE",
               "allowed_root" => ctx.root,
               "expected_sha" => pushed["candidate_sha"]
             })

    assert {:ok, reused} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert reused.disposition == :reuse
    assert reused.operation_key == selected.operation_key
    assert reused.push_sha256 == selected.push_sha256
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "matching active legacy REVIEW_READY identity reuses its exact current generation and rejects release", ctx do
    assert_mr_adoption(ctx)
    {:ok, pushed} = RunLedger.get(ctx.store, "run")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, checkout} = Worktree.checkout_identity(%{"path" => ctx.repo}, run["worktree"], clean: true, detached: false, expected_branch: run["branch"], expected_sha: run["candidate_sha"])
    checkout = Map.new(checkout, fn {key, value} -> {Atom.to_string(key), value} end)
    body = "Review candidate #{pushed["candidate_sha"]}: #{pushed["mr_url"]}"
    assert {:ok, legacy_row} = TicketJiraJournal.prepare(ctx.store, "run", "REVIEW_READY", body, checkout)
    assert String.starts_with?(legacy_row["operation_key"], "ticket-jira:")
    assert {:ok, ^legacy_row} = TicketJiraJournal.prepare(ctx.store, "run", "REVIEW_READY", body, checkout)

    legacy_state = fn store ->
      %{
        run: Store.one!(store, "SELECT * FROM runs WHERE run_id = 'run'"),
        journal: Store.query!(store, "SELECT * FROM ticket_jira_effects ORDER BY operation_key").rows,
        access: Store.query!(store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows,
        tasks: Store.query!(store, "SELECT * FROM factory_tasks ORDER BY task_key").rows,
        evidence: Store.query!(store, "SELECT * FROM worker_evidence ORDER BY request_key").rows,
        requests: Store.query!(store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
        events: Store.query!(store, "SELECT * FROM events ORDER BY id").rows
      }
    end

    before_legacy_ownership = legacy_state.(ctx.store)
    assert {:error, :unknown_workspace_reservation} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert legacy_state.(ctx.store) == before_legacy_ownership

    assert {:error, :ticket_jira_receipt_corrupt} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE ticket_jira_effects SET operation_key = 'ticket-jira:renamed-unissued' WHERE operation_key = ?", [legacy_row["operation_key"]])
               assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.select_review_operation(tx, "run")
               Exqlite.rollback(tx, :ticket_jira_receipt_corrupt)
             end)

    assert legacy_state.(ctx.store) == before_legacy_ownership
    assert {:ok, ^legacy_row} = TicketJiraJournal.get(ctx.store, legacy_row["operation_key"])

    assert {:ok, access} =
             WorkspaceAccess.acquire(
               ctx.store,
               %{
                 "reservation_key" => legacy_row["operation_key"],
                 "run_id" => "run",
                 "request_key" => legacy_row["operation_key"],
                 "task_key" => nil,
                 "mode" => "MAINTENANCE",
                 "allowed_root" => ctx.root,
                 "expected_sha" => pushed["candidate_sha"]
               }
             )

    assert {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {legacy_row["run_id"], "MAINTENANCE", legacy_row["operation_key"], nil},
           "legacy fixture workspace access does not own the exact operation: #{inspect(Map.take(access, ~w(run_id mode request_key task_key reservation_key)))}"

    assert {:ok, selected} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert selected.identity_version == 1 and selected.disposition == :reuse
    assert selected.operation_key == legacy_row["operation_key"]

    owned_legacy_state = legacy_state.(ctx.store)

    assert {:error, :ticket_jira_binding_changed} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE runs SET state = 'VERIFYING' WHERE run_id = 'run'")
               assert {:error, :ticket_jira_binding_changed} = TicketJiraJournal.select_review_operation(tx, "run")
               Exqlite.rollback(tx, :ticket_jira_binding_changed)
             end)

    assert legacy_state.(ctx.store) == owned_legacy_state
    assert {:ok, ^selected} = TicketJiraJournal.select_review_operation(ctx.store, "run")

    reservation = %{key: legacy_row["operation_key"], generation: access["generation"]}
    assert {:ok, delivery_options} = TicketWorkerRunner.delivery_review_options(ctx.store, pushed, reservation: reservation)
    assert delivery_options[:reservation] == reservation

    assert {:error, :ticket_delivery_reservation_invalid} =
             TicketWorkerRunner.delivery_review_options(ctx.store, pushed, reservation: %{reservation | generation: access["generation"] + 1})

    assert legacy_state.(ctx.store) == owned_legacy_state
    {:ok, push_proof} = TicketPush.completed_proof(ctx.store, "run")
    assert selected.push_sha256 == push_proof.envelope_sha256
    assert {:ok, ^legacy_row} = TicketJiraJournal.prepare_review(ctx.store, "run", body, checkout, selected)
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")

    complete_review_journal(ctx, legacy_row["operation_key"])
    assert {:ok, released} = WorkspaceAccess.release_jira(ctx.store, "run", legacy_row["operation_key"], access["generation"])
    assert not is_nil(released["released_at"])
    assert {:error, :ticket_jira_same_generation_released} = TicketJiraJournal.select_review_operation(ctx.store, "run")
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "released legacy review history survives a fresh verifier pass on the same candidate", ctx do
    {context, options} = assert_mr_adoption(ctx, true)
    {:ok, original} = RunLedger.get(ctx.store, "run")
    {legacy_row, _checkout} = prepare_legacy_review(ctx, original)

    assert {:ok, access} =
             WorkspaceAccess.acquire(ctx.store, %{
               "reservation_key" => legacy_row["operation_key"],
               "run_id" => "run",
               "request_key" => legacy_row["operation_key"],
               "task_key" => nil,
               "mode" => "MAINTENANCE",
               "allowed_root" => ctx.root,
               "expected_sha" => original["candidate_sha"]
             })

    complete_review_journal(ctx, legacy_row["operation_key"])
    assert {:ok, released} = WorkspaceAccess.release_jira(ctx.store, "run", legacy_row["operation_key"], access["generation"])
    {:ok, completed_review} = TicketJiraJournal.get(ctx.store, legacy_row["operation_key"])
    writer_rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE role = 'feature-writer' ORDER BY task_key").rows
    event_rows = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows

    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING", verifier_round: original["verifier_round"] + 1})
    verified = complete_stage(context, options)
    assert verified["state"] == "PUSHING"
    assert verified["candidate_sha"] == original["candidate_sha"]
    assert {:ok, %{run: pushed}} = TicketPush.step(ctx.store, "run", push_authorization(ctx.store, verified), options)
    assert pushed["state"] == "MR_CREATING"
    assert pushed["mr_url"] == original["mr_url"]
    before_selection = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    assert length(before_selection) >= length(event_rows)

    assert {:ok, selection} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert selection.identity_version == 2 and selection.disposition == :new
    assert selection.operation_key != legacy_row["operation_key"]
    assert {:ok, ^completed_review} = TicketJiraJournal.get(ctx.store, legacy_row["operation_key"])
    assert {:ok, ^released} = WorkspaceAccess.get(ctx.store, legacy_row["operation_key"])
    assert {:ok, ^pushed} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE role = 'feature-writer' ORDER BY task_key").rows == writer_rows
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == before_selection
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects WHERE operation = 'REVIEW_READY'")["count"] == 1
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "a released legacy REVIEW_READY generation permits a genuine later push and rejects corrupt history", ctx do
    {context, options} = assert_mr_adoption(ctx, true)
    {:ok, original} = RunLedger.get(ctx.store, "run")
    {legacy_row, _checkout} = prepare_legacy_review(ctx, original)

    assert {:ok, access} =
             WorkspaceAccess.acquire(ctx.store, %{
               "reservation_key" => legacy_row["operation_key"],
               "run_id" => "run",
               "request_key" => legacy_row["operation_key"],
               "task_key" => nil,
               "mode" => "MAINTENANCE",
               "allowed_root" => ctx.root,
               "expected_sha" => original["candidate_sha"]
             })

    complete_review_journal(ctx, legacy_row["operation_key"])
    assert {:ok, released} = WorkspaceAccess.release_jira(ctx.store, "run", legacy_row["operation_key"], access["generation"])
    assert not is_nil(released["released_at"])
    {:ok, old_row} = TicketJiraJournal.get(ctx.store, legacy_row["operation_key"])
    {:ok, old_access} = WorkspaceAccess.get(ctx.store, legacy_row["operation_key"])

    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "REPAIRING", plan_markdown: "repair"})
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    {:ok, repaired} = RunLedger.get(ctx.store, "run")
    assert repaired["candidate_sha"] != original["candidate_sha"]
    assert {:ok, %{run: delivered}} = TicketPush.step(ctx.store, "run", push_authorization(ctx.store, repaired), options)
    assert delivered["state"] == "MR_CREATING"

    assert {:ok, selected} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert selected.identity_version == 2 and selected.disposition == :new
    assert selected.operation_key != legacy_row["operation_key"]
    assert {:ok, ^old_row} = TicketJiraJournal.get(ctx.store, legacy_row["operation_key"])
    assert {:ok, ^old_access} = WorkspaceAccess.get(ctx.store, legacy_row["operation_key"])

    original_binding = old_row["binding_json"]
    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET binding_json = '{}' WHERE operation_key = ?", [legacy_row["operation_key"]])
    assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert {:ok, ^delivered} = RunLedger.get(ctx.store, "run")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects WHERE run_id = ? AND operation = 'REVIEW_READY'", ["run"])["count"] == 1
    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET binding_json = ? WHERE operation_key = ?", [original_binding, legacy_row["operation_key"]])
    assert {:ok, ^selected} = TicketJiraJournal.select_review_operation(ctx.store, "run")
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "a genuinely unresolved legacy REVIEW_READY predecessor blocks a later push generation", ctx do
    {context, options} = assert_mr_adoption(ctx, true)
    {:ok, original} = RunLedger.get(ctx.store, "run")
    {legacy_row, _checkout} = prepare_legacy_review(ctx, original)
    assert legacy_row["phase"] == "FIRST_PENDING"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE reservation_key = ?", [legacy_row["operation_key"]])["count"] == 0

    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "REPAIRING", plan_markdown: "repair"})
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    {:ok, repaired} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{run: delivered}} = TicketPush.step(ctx.store, "run", push_authorization(ctx.store, repaired), options)

    assert {:error, :ticket_jira_legacy_review_unresolved} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects WHERE run_id = ? AND operation = 'REVIEW_READY'", ["run"])["count"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    assert {:ok, ^delivered} = RunLedger.get(ctx.store, "run")
    assert {:ok, ^legacy_row} = TicketJiraJournal.get(ctx.store, legacy_row["operation_key"])
  end

  @tag broker_thread_id: "00000000-0000-0000-0000-000000000001"
  test "released current v2 REVIEW_READY generation cannot be reused", ctx do
    assert_mr_adoption(ctx)
    {:ok, pushed} = RunLedger.get(ctx.store, "run")
    {:ok, selected} = TicketJiraJournal.select_review_operation(ctx.store, "run")
    assert selected.identity_version == 2 and selected.disposition == :new
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, checkout} = Worktree.checkout_identity(%{"path" => ctx.repo}, run["worktree"], clean: true, detached: false, expected_branch: run["branch"], expected_sha: run["candidate_sha"])
    checkout = Map.new(checkout, fn {key, value} -> {Atom.to_string(key), value} end)
    body = "Review candidate #{pushed["candidate_sha"]}: #{pushed["mr_url"]}"
    assert {:ok, v2_row} = TicketJiraJournal.prepare_review(ctx.store, "run", body, checkout, selected)

    assert {:ok, access} =
             WorkspaceAccess.acquire(
               ctx.store,
               %{
                 "reservation_key" => v2_row["operation_key"],
                 "run_id" => "run",
                 "request_key" => v2_row["operation_key"],
                 "task_key" => nil,
                 "mode" => "MAINTENANCE",
                 "allowed_root" => ctx.root,
                 "expected_sha" => pushed["candidate_sha"]
               }
             )

    complete_review_journal(ctx, v2_row["operation_key"])
    assert {:ok, released} = WorkspaceAccess.release_jira(ctx.store, "run", v2_row["operation_key"], access["generation"])
    assert not is_nil(released["released_at"])
    assert {:error, :stale_workspace_reservation} = TicketJiraJournal.select_review_operation(ctx.store, "run")
  end

  test "CI preflight history requires fresh verifier PASS before a same-candidate delivery push", ctx do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    remote = Path.join(ctx.root, "preflight-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    {:ok, %{run: preflight}} = RunLedger.update(ctx.store, "run", %{state: "CI_PUSHING"})
    proof = push_authorization(ctx.store, preflight)
    authorized = Keyword.put(options, :ci_preflight_authorized, true)
    {:ok, claimed} = TicketPush.claim(ctx.store, "run", proof, authorized)
    {:ok, execution} = TicketPushIO.prepare(ctx.store, claimed, proof)
    assert {:ok, _} = TicketPushIO.execute(execution, &TicketPush.attach_execution(ctx.store, "run", &1, &2, proof, authorized))
    {recovery_context, tick_opts} = tick_controller(context, options)
    recovery_context = put_in(recovery_context, [:factory, :ticket_supervisor, "enabled"], false)
    assert {:ok, %{launches: [], events: denied}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    assert Enum.any?(denied, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_ci_preflight_not_authorized"))
    assert {:ok, %{"state" => "CI_PUSHING"}} = RunLedger.get(ctx.store, "run")
    recovery_context = put_in(recovery_context, [:factory, :repositories, "grail", "ci_preflight"], "draft_mr")
    assert {:ok, %{launches: [], events: recovered}} = Scheduler.reconcile_ticket_jira(recovery_context, tick_opts)
    assert Enum.any?(recovered, &(&1.event == "TICKET_PUSH_COMPLETED"))
    {:ok, ci_pushed} = RunLedger.get(ctx.store, "run")
    assert ci_pushed["state"] == "CI_MR_CREATING"
    history = Jason.decode!(ci_pushed["candidate_handoff"])
    assert ci_pushed["ci_preflight_sha"] == ci_pushed["candidate_sha"]
    {:ok, %{run: unverified}} = RunLedger.update(ctx.store, "run", %{state: "PUSHING"})
    proof = push_authorization(ctx.store, unverified)
    assert {:error, :ticket_delivery_verifier_pass_unproven} = TicketPush.prepare(ctx.store, "run", proof, options)
    assert {:ok, ^unverified} = RunLedger.get(ctx.store, "run")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING"})
    assert complete_stage(context, options)["state"] == "PUSHING"
    {:ok, verified} = RunLedger.get(ctx.store, "run")
    assert verified["candidate_sha"] == ci_pushed["candidate_sha"]
    proof = push_authorization(ctx.store, verified)
    assert {:ok, prepared} = TicketPush.prepare(ctx.store, "run", proof, options)
    assert prepared["reservation_key"] != history["reservation_key"]
    assert {:ok, %{run: final}} = TicketPush.step(ctx.store, "run", proof, options)
    assert final["state"] == "MR_CREATING"
    {:ok, previous} = WorkspaceAccess.get(ctx.store, history["reservation_key"])
    assert previous["release_receipt_json"] == ci_pushed["candidate_handoff"]
  end

  test "ordinary initial writer still enters CI preflight when the route enables it", ctx do
    {context, options} = controller(ctx)
    preflight_context = put_in(context, [:factory, :repositories, "grail", "ci_preflight"], "draft_mr")
    {:ok, before} = RunLedger.get(ctx.store, "run")
    adopted = complete_stage(preflight_context, options)
    assert adopted["state"] == "CI_PUSHING"
    assert adopted["verifier_round"] == before["verifier_round"]
    assert is_nil(adopted["ci_preflight_sha"])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence e JOIN factory_tasks t ON t.task_key = e.task_key WHERE e.run_id = 'run' AND t.role = 'change-verifier'")["count"] == 0
  end

  defp push_authorization(store, run) do
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: store)
    {:ok, proof} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    proof
  end

  for checkpoint <- ~w(before_attach after_attach receipt_before_finalize) do
    @checkpoint checkpoint
    test "hard-killed push controller at #{checkpoint} never repeats an uncertain push", ctx do
      assert_push_crash_recovery(ctx, @checkpoint)
    end
  end

  defp assert_push_crash_recovery(ctx, checkpoint) do
    {context, options} = controller(ctx)
    assert complete_stage(context, options)["state"] == "VERIFYING"
    assert complete_stage(context, options)["state"] == "PUSHING"
    remote = Path.join(ctx.root, "crash-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    counter = Path.join(ctx.root, "push-count")
    receiver = Path.join(ctx.root, "receive-pack")
    File.write!(receiver, "#!/bin/sh\necho push >> '#{counter}'\nexec /Library/Developer/CommandLineTools/usr/bin/git receive-pack \"$@\"\n")
    File.chmod!(receiver, 0o700)
    git(ctx.repo, ["config", "remote.origin.receivepack", receiver])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: ctx.store)
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    task_rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows
    evidence_rows = Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY request_key").rows
    source = File.read!(Path.join(run["worktree"], "fixture.txt"))
    support = Path.expand("../support", __DIR__)

    packet =
      Jason.encode!(%{"authorization" => authorization, "opts" => Map.new(Keyword.take(options, [:capacity_policy, :free_bytes, :workspace_root])), "checkpoint" => checkpoint}) |> Base.encode64()

    args = [
      "-I",
      "-S",
      "-B",
      Path.join(support, "file_io_vm_crash.py"),
      System.find_executable("elixir"),
      Path.expand("_build/test/lib"),
      Path.join(support, "push_controller.exs"),
      ctx.database,
      packet
    ]

    {output, 0} = System.cmd("/usr/bin/python3", args)
    observed = Jason.decode!(output)
    assert observed["observed_terminal_helper"] == true, observed["output"]
    assert File.read!(Path.join(ctx.root, "reply-withheld")) == checkpoint
    assert observed["executing_vm_pid"] == observed["controller_pid"]
    assert observed["controller_returncode"] == -9
    {:ok, before} = RunLedger.get(ctx.store, "run")
    intent = Jason.decode!(before["candidate_handoff"])
    assert intent["phase"] == "PUSH_UNCERTAIN"
    assert before["state"] == "PUSHING"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    if checkpoint == "before_attach", do: assert(is_nil(intent["helper_pid"]) and is_nil(intent["execution_json"]))
    if checkpoint != "before_attach", do: assert(is_integer(intent["helper_pid"]) and intent["helper_pid"] > 0 and is_binary(intent["execution_json"]))
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, database: ctx.database})
    {:ok, snapshot} = JiraReader.issue(run["issue_key"], store: store)
    {:ok, authorization} = TicketWorkerRunner.authorization(before, snapshot, DateTime.utc_now())

    if checkpoint == "receipt_before_finalize" do
      assert {:ok, original_receipt} = TicketPushIO.readback(intent)
      assert TicketPushIO.receipt_valid?(original_receipt, intent)
      assert {:ok, %{status: "PUSH_COMPLETED", run: recovered}} = TicketPush.step(store, "run", authorization, options)
      completed = Jason.decode!(recovered["candidate_handoff"])
      assert recovered["state"] == "MR_CREATING"
      fields = ~w(version kind binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json)
      assert Map.take(completed, fields) == Map.take(intent, fields)
      assert completed["receipt_json"] == original_receipt
      assert completed["receipt_sha256"] == Base.encode16(:crypto.hash(:sha256, original_receipt), case: :lower)
      assert {:ok, ^original_receipt} = TicketPushIO.readback(completed)
      assert {:ok, remote_sha} = Worktree.read_remote_branch(%{"path" => ctx.repo}, run["branch"])
      assert remote_sha == run["candidate_sha"]
      assert String.split(File.read!(counter), "\n", trim: true) == ["push"]
      assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    else
      for _ <- 1..2 do
        assert {:error, _} = TicketPush.step(store, "run", authorization, options)
        assert {:ok, ^before} = RunLedger.get(store, "run")
        assert Store.one!(store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
        refute File.exists?(counter)
      end
    end

    assert Store.query!(store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == task_rows
    assert Store.query!(store, "SELECT * FROM worker_evidence ORDER BY request_key").rows == evidence_rows
    assert File.read!(Path.join(run["worktree"], "fixture.txt")) == source
    assert String.trim(git(run["worktree"], ["rev-parse", "HEAD"])) == run["candidate_sha"]
  end

  test "one pending parent does not prevent another ticket's planner launch or recreate the pending request", ctx do
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "PLANNING", candidate_sha: nil})
    {context, tick_opts} = tick_controller(context, options)
    {:ok, parent_reader} = empty_parent_reader_options(ctx.store, "run")
    tick_opts = Keyword.merge(tick_opts, parent_reader)
    context = %{context | ticket_options: Keyword.merge(context.ticket_options, parent_reader)}
    {contract, snapshot} = SymphonyElixir.TicketChatFixture.authorized_contract("PPL-456", "pending-issue")
    parents = Path.join(ctx.root, "pending-parents")
    File.mkdir_p!(parents)
    workflow = Path.join(ctx.root, "tick-workflow.md")
    File.write!(workflow, "---\nfactory:\n  database: #{ctx.database}\n---\nFixture")
    options = Keyword.merge(options, parent_reader ++ [parent_output_root: parents, broker_thread_id: "019fa5b7-27fa-7660-ab47-7c3abb867c91", ticket_cli_root: File.cwd!(), ticket_workflow: workflow])
    context = %{context | ticket_options: options}
    context = put_in(context, [:factory, :ticket_supervisor, "pilot_issue_keys"], ["PPL-123", "PPL-456"])
    context = put_in(context, [:factory, :models, "roles", "orchestrator-intake"], %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "low"})

    assert {:ok, _} =
             RunLedger.register(ctx.store, %{
               run_id: "pending",
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "ADMITTING_WRITER",
               execution_mode: "TICKET_SUPERVISOR_V1",
               repo_key: "grail",
               repo_path: ctx.repo,
               base_branch: "master",
               branch: "cgable/pending",
               spec_revision: contract.revision,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               snapshot_json: Jason.encode!(snapshot),
               manual_validation_required: false
             })

    assert {:ok, %{status: "PARENT_PENDING", request_key: request}} = Scheduler.ticket_parent_step(context, "pending", options)
    pending_path = Path.join(ctx.root, "workspaces/pending")
    binding = Jason.encode!(%{"run_id" => "pending"})
    digest = Base.encode16(:crypto.hash(:sha256, binding), case: :lower)

    Store.query!(
      ctx.store,
      """
      INSERT INTO ticket_checkout_intents
        (run_id, canonical_path, repo_path, branch, binding_json, binding_sha256, phase, owner_nonce)
      VALUES ('pending', ?, ?, 'cgable/pending', ?, ?, 'MUTATING_UNCERTAIN', 'fixture-recovery')
      """,
      [pending_path, ctx.repo, binding, digest]
    )

    pending_intent = Store.one!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'pending'")
    assert {:ok, %{launches: [launch], events: events}} = Scheduler.tick(context, tick_opts)
    assert launch.task_key == "run:feature-planner"
    assert Enum.any?(events, &(&1.issue_key == "PPL-456" and &1.event == "TICKET_DEFERRED"))
    refute Enum.any?(events, &(&1.issue_key == "PPL-456" and &1.event == "TICKET_PARENT_PENDING"))
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.issue_key == "PPL-456" and &1.event == "TICKET_DEFERRED"))
    refute Enum.any?(events, &(&1.issue_key == "PPL-456" and &1.event == "TICKET_PARENT_PENDING"))
    assert {:ok, %{"state" => "ADMITTING_WRITER", "worktree" => nil}} = RunLedger.get(ctx.store, "pending")
    assert Store.one!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'pending'") == pending_intent
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM factory_tasks WHERE run_id = 'pending'")["count"] == 0
    refute File.exists?(pending_path)
    Store.query!(ctx.store, "DELETE FROM ticket_checkout_intents WHERE run_id = 'pending'")
    assert {:ok, %{events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.issue_key == "PPL-456" and &1.event == "TICKET_PARENT_PENDING"))
    assert {:ok, %{"create_request_key" => ^request, "chat_key" => chat_key}} = TicketChat.for_run(ctx.store, "pending")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE action = 'CREATE' AND target_kind = 'TICKET_CHAT' AND target_key = ?", [chat_key])["count"] == 1
    key = launch.task_key
    assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000
  end

  test "presentation failure after adoption never rolls back work and retries without source replay", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER fail_presentation BEFORE INSERT ON desktop_requests WHEN NEW.target_kind = 'TICKET_CHAT' AND NEW.action = 'FOLLOWUP' BEGIN SELECT RAISE(ABORT, 'fixture presentation failure'); END"
    )

    assert {:ok, %{status: "ADOPTED", run: adopted, presentation: %{status: "SYNC_ERROR"}}} = Scheduler.ticket_step(context, "run", options)
    assert adopted["state"] == "VERIFYING"
    assert adopted["implementation_iteration"] == 1
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.get(ctx.store, request)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    commit_count = git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim()
    assert commit_count == "1"
    Store.query!(ctx.store, "DROP TRIGGER fail_presentation")
    blocked = Keyword.put(options, :jira_reader, BlockedJiraReader)
    assert {:error, _} = Scheduler.ticket_step(context, "run", blocked)
    assert {:ok, ^adopted} = RunLedger.get(ctx.store, "run")
    presentations = Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND action = 'FOLLOWUP'")["count"]
    assert presentations == 2
    assert {:error, _} = Scheduler.ticket_step(context, "run", blocked)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND action = 'FOLLOWUP'")["count"] == presentations
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == commit_count
    refute_receive {:factory_task_started, _, _}
  end

  test "restart after controller commit adopts that commit once using its immutable parent", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)
    {:ok, evidence} = WorkerEvidence.get(ctx.store, request)
    output = Jason.decode!(evidence["output_json"])
    parent = Jason.decode!(evidence["binding_json"])["expected_sha"]
    assert {:ok, %{sha: committed}} = Worktree.commit_native_slice(%{"path" => ctx.repo}, ctx.path, "cgable/fixture", parent, output["changed_paths"], output["commit_message"])
    assert {:ok, %{"candidate_sha" => old}} = RunLedger.get(ctx.store, "run")
    assert old == ctx.sha
    :ok = stop_supervised(Store)
    store = start_supervised!({Store, database: ctx.database})
    context = %{context | store: store}
    assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", options)
    assert run["candidate_sha"] == committed and run["implementation_iteration"] == 1
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == "1"
    assert {:ok, _} = WorkerEvidence.consume(store, request)
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM controller_checks")["count"] == 1
  end

  test "failed final release rolls back stage and task adoption but retains candidate and check for retry", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)
    Store.query!(ctx.store, "CREATE TRIGGER fail_release BEFORE UPDATE OF released_at ON workspace_access BEGIN SELECT RAISE(ABORT, 'release failure'); END")
    assert_raise Exqlite.Error, fn -> Scheduler.ticket_step(context, "run", options) end
    {:ok, interrupted} = RunLedger.get(ctx.store, "run")
    assert interrupted["state"] == "WRITING" and interrupted["implementation_iteration"] == 0
    refute interrupted["candidate_sha"] == ctx.sha
    assert {:ok, %{"status" => "COMPLETE"}} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
    before_check = Store.query!(ctx.store, "SELECT * FROM controller_checks").rows
    Store.query!(ctx.store, "DROP TRIGGER fail_release")
    assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", options)
    assert run["candidate_sha"] == interrupted["candidate_sha"] and run["implementation_iteration"] == 1
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == before_check
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == "1"
  end

  test "failed owned check preserves candidate, stage and reservation without another commit or check", ctx do
    {context, options} = controller(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "whitespace"})
    finish_worker(context, options)
    assert {:error, :controller_writer_check_failed} = Scheduler.ticket_step(context, "run", options)
    {:ok, retained} = RunLedger.get(ctx.store, "run")
    assert retained["state"] == "WRITING" and retained["implementation_iteration"] == 0
    refute retained["candidate_sha"] == ctx.sha
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    before = Store.query!(ctx.store, "SELECT * FROM controller_checks").rows
    assert {:error, :controller_writer_check_failed} = Scheduler.ticket_step(context, "run", options)
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == before
    assert {:ok, ^retained} = RunLedger.get(ctx.store, "run")
  end

  test "changing stage before adoption rejects before controller commit", ctx do
    {context, options} = controller(ctx)
    finish_worker(context, options)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING"})
    assert {:error, :ticket_role_stage_not_admitted} = Scheduler.ticket_step(context, "run", options)
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "second\n"
  end

  test "stale parent admission leaves a lost task result untouched", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)
    {:ok, _} = TaskLedger.update(ctx.store, "run:feature-writer", %{status: "RUNNING", output_json: nil})
    before = Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE target_kind = 'TICKET_CHAT'")
    assert {:error, :ticket_chat_parent_not_ready} = TicketWorkerRunner.adoption(ctx.store, request)
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == before
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
  end

  test "new admission rereads Jira and rejects blocked labels or expired proof before mutations", ctx do
    {context, options} = controller(ctx)
    assert {:error, :ticket_jira_not_dispatchable} = Scheduler.ticket_step(context, "run", Keyword.put(options, :jira_reader, BlockedJiraReader))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM factory_tasks")["count"] == 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access")["count"] == 0
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, snapshot} = JiraReader.issue("PPL-123", store: ctx.store)
    {:ok, proof} = TicketWorkerRunner.authorization(run, snapshot, DateTime.add(DateTime.utc_now(), -61))
    assert {:error, :ticket_authorization_expired} = TicketWorkerRunner.validate_authorization(run, proof)
    assert {:error, :ticket_authorization_required} = TicketWorkerRunner.validate_authorization(run, nil)
    assert {:error, _} = TicketWorkerRunner.authorization(run, Map.put(snapshot, "comments", []), DateTime.utc_now())
    refute_receive {:factory_task_started, _, _}
  end

  test "RESERVED restart keeps saved allocation after router changes and issues one turn", ctx do
    {context, options} = controller(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    digest = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    key = "run:feature-writer"

    {:ok, _} =
      TaskLedger.register(ctx.store, %{
        task_key: key,
        run_id: "run",
        stage: "WRITING",
        role: "feature-writer",
        status: "STARTING",
        model_provider: "codex",
        model_class: "deep",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        routing_reason: "saved-attempt",
        workspace: ctx.path,
        workspace_sha: ctx.sha,
        prompt_sha256: digest
      })

    request = DesktopStageRunner.request_key(key, nil, prompt)
    reservation = "workspace:" <> request

    {:ok, _} =
      WorkspaceAccess.acquire(
        ctx.store,
        %{
          "reservation_key" => reservation,
          "request_key" => request,
          "run_id" => "run",
          "task_key" => key,
          "mode" => "SOURCE",
          "allowed_root" => Path.join(ctx.root, "workspaces"),
          "expected_sha" => ctx.sha
        },
        opts(ctx)
      )

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => request,
        "task_key" => key,
        "reservation_key" => reservation,
        "owner_id" => "owner:" <> request,
        "input_sha256" => digest,
        "schema" => StageSchemas.for_stage(:native_feature_writer),
        "policy" => TicketWorkerRunner.policy("SOURCE", ctx.path)
      })

    context = put_in(context, [:factory, :models], %{})
    assert {:ok, %{status: "LAUNCHED", launch: launch}} = Scheduler.ticket_step(context, "run", options)
    assert launch.route.model == "gpt-6.1-sol" and launch.route.reasoning_effort == "high"
    assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000
    assert {:ok, %{status: "ADOPTED"}} = Scheduler.ticket_step(context, "run", options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence")["count"] == 1
    assert {:ok, %{"model" => "gpt-6.1-sol", "reasoning_effort" => "high"}} = TaskLedger.get(ctx.store, key)
    assert run["candidate_sha"] == ctx.sha
  end

  test "parent invalidated after commit preflight prevents final transition and releases nothing", ctx do
    {context, options} = controller(ctx)
    request = finish_worker(context, options)

    Store.query!(ctx.store, """
    CREATE TRIGGER invalidate_parent AFTER UPDATE OF candidate_sha ON runs
    BEGIN UPDATE desktop_requests SET status = 'FAILED' WHERE target_kind = 'TICKET_CHAT'; END
    """)

    assert {:error, :ticket_chat_parent_not_ready} = Scheduler.ticket_step(context, "run", options)
    {:ok, retained} = RunLedger.get(ctx.store, "run")
    assert retained["state"] == "WRITING" and retained["implementation_iteration"] == 0
    assert {:ok, %{"status" => "COMPLETE"}} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 1
    Store.query!(ctx.store, "DROP TRIGGER invalidate_parent")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE target_kind = 'TICKET_CHAT'")
    assert {:ok, %{status: "ADOPTED", run: recovered}} = Scheduler.ticket_step(context, "run", options)
    assert recovered["candidate_sha"] == retained["candidate_sha"] and recovered["implementation_iteration"] == 1
    assert git(ctx.path, ["rev-list", "--count", ctx.sha <> "..HEAD"]) |> String.trim() == "1"
  end

  defp complete_review_journal(ctx, key) do
    {:ok, row} = TicketJiraJournal.get(ctx.store, key)
    effects = Jason.decode!(row["effects_json"])

    assert {:ok, %{"phase" => "FIRST_UNCERTAIN"}} = TicketJiraJournal.claim(ctx.store, key)
    first_body = Enum.at(effects, 0)["body"]
    comments = [%{"id" => "review-comment", "text" => first_body}]

    assert {:ok, %{"phase" => "SECOND_PENDING"}} =
             TicketJiraJournal.reconcile(ctx.store, key, jira_observation(%{"comments" => comments}))

    assert {:ok, %{"phase" => "SECOND_UNCERTAIN"}} = TicketJiraJournal.claim(ctx.store, key)
    labels = Enum.at(effects, 1)["add_labels"] ++ ["human-label"]
    assert {:ok, %{"phase" => "COMPLETE"}} = TicketJiraJournal.reconcile(ctx.store, key, jira_observation(%{"labels" => labels}))
  end

  defp prepare_legacy_review(ctx, run) do
    {:ok, checkout} = Worktree.checkout_identity(%{"path" => ctx.repo}, run["worktree"], clean: true, detached: false, expected_branch: run["branch"], expected_sha: run["candidate_sha"])
    checkout = Map.new(checkout, fn {key, value} -> {Atom.to_string(key), value} end)
    body = "Review candidate #{run["candidate_sha"]}: #{run["mr_url"]}"
    assert {:ok, row} = TicketJiraJournal.prepare(ctx.store, "run", "REVIEW_READY", body, checkout)
    {row, checkout}
  end

  defp jira_observation(issue) do
    %{
      "source" => "Jira/get_issue",
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "issue" => Map.put(issue, "key", "PPL-123")
    }
  end
end
