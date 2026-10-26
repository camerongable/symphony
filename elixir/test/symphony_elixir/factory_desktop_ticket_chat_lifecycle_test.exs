defmodule SymphonyElixir.FactoryDesktopTicketChatLifecycleTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 180_000
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.DesktopTicketLifecycleFixture, as: Fixture
  alias SymphonyElixir.DesktopTicketLifecycleFixture.{JiraConnector, JiraReader, MrReader, WorkerServer}

  alias SymphonyElixir.Factory.{
    Control,
    DesktopRequest,
    DesktopToolArgs,
    RunLedger,
    Scheduler,
    Store,
    TaskLedger,
    TicketMrOperation
  }

  alias SymphonyElixir.Factory.{
    TaskLauncher,
    TicketAmendmentCritic,
    TicketAmendmentJiraOperation,
    TicketContractAmendment,
    WorkspaceAccess
  }

  alias SymphonyElixir.Factory.{
    TicketChat,
    TicketChatCommands,
    TicketChatOutbox,
    TicketJiraJournal,
    TicketPush,
    TicketWorkerRunner
  }

  alias SymphonyElixir.Factory.Worktree
  alias SymphonyElixir.TicketChatFixture

  defmodule FixtureCleanup do
    @moduledoc false

    alias SymphonyElixir.Factory.Cleanup

    def ensure_capacity(store, policy, repo_key, opts),
      do: Cleanup.ensure_capacity(store, policy, repo_key, Keyword.put_new(opts, :free_bytes, 50_000_000_000))

    def hibernate(store, policy, run_id, opts), do: Cleanup.hibernate(store, policy, run_id, opts)

    def authorization_candidates(store, policy, repo_key),
      do: Cleanup.authorization_candidates(store, policy, repo_key)

    def authorize(store, policy, run_id, jira_status, mr_state),
      do: Cleanup.authorize(store, policy, run_id, jira_status, mr_state)

    def apply(store, policy, run_id, opts), do: Cleanup.apply(store, policy, run_id, opts)
  end

  defmodule AdmissionWorkspaceReader do
    def issue(_key, opts) do
      send(self(), {:admission_connector_workspace, opts[:workspace]})
      {:error, :diagnostic_read_finished}
    end
  end

  defmodule FailingNativeReader do
    def read_native_thread(_thread_id, _opts), do: {:error, {:native_read_failed, "private-error-payload"}}
  end

  setup context do
    ordinary_ticket_intake? = context[:ordinary_ticket_intake] == true
    fixture_context = context |> Map.put(:broker_thread_id, "019fa5b7-27fa-7660-ab47-7c3abb867c91") |> Map.put(:unregistered, ordinary_ticket_intake?)
    ctx = setup_fixture(fixture_context)
    Process.put(:lifecycle_broker_thread_id, ctx[:broker_thread_id])

    snapshot =
      if ordinary_ticket_intake? do
        {_contract, snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-id")
        snapshot
      else
        bind_parent(ctx)
        {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER", worktree: nil, candidate_sha: nil, branch: "cgable/combined"})
        Store.query!(ctx.store, "DELETE FROM factory_tasks WHERE task_key = 'writer'")
        {:ok, run} = RunLedger.get(ctx.store, "run")
        Jason.decode!(run["snapshot_json"])
      end

    comments = snapshot["comments"] |> Enum.with_index() |> Enum.map(fn {c, i} -> Map.put(c, "id", "history-#{i}") end)

    Process.put(
      :lifecycle_jira,
      Map.merge(snapshot, %{
        "comments" => comments,
        "summary" => "Factory work",
        "description" => "Do the work",
        "status" => "To Do",
        "labels" => ~w(ai-ready repo-grail human-label),
        "assignee" => "cgable",
        "project_key" => "PPL",
        "parent_key" => nil,
        "components" => ["doc-extract"],
        "url" => "https://jira.example/PPL-123",
        "updated" => "2026-10-07T12:00:00Z"
      })
    )

    Process.put(:lifecycle_jira_search, if(ordinary_ticket_intake?, do: [Process.get(:lifecycle_jira)], else: []))

    remote = Path.join(ctx.root, "combined-origin.git")
    git(ctx.root, ["init", "--bare", remote])
    git(ctx.repo, ["remote", "add", "origin", remote])
    ctx
  end

  test "writer admission reads Jira from the controller directory rather than the source workspace root", ctx do
    context = controller(ctx)
    expected = Path.join([context.workspace_root, "factory-controller", context.factory.scope])
    File.mkdir_p!(expected)
    before = Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows

    assert {:error, :diagnostic_read_finished} =
             Scheduler.ticket_step(context, "run", Keyword.put(context.ticket_options, :jira_reader, AdmissionWorkspaceReader))

    assert_received {:admission_connector_workspace, ^expected}
    refute expected == context.workspace_root
    assert Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents").rows == before
  end

  test "ticket deferral diagnostics expose error tags without native error payloads", ctx do
    context = controller(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, result} =
                 Scheduler.tick(context,
                   jira_reader: JiraReader,
                   jira_connector: JiraConnector,
                   cleanup: FixtureCleanup,
                   ticket_options: [ticket_chat_reader: FailingNativeReader]
                 )

        assert Enum.any?(result.events, &(&1.event == "TICKET_DEFERRED"))
      end)

    assert log =~ "Factory ticket deferred"
    assert log =~ "native_read_failed"
    refute log =~ "private-error-payload"
  end

  @tag timeout: 600_000
  @tag ordinary_ticket_intake: true
  test "one uninterrupted ordinary run reaches review-ready through normal ticks and synthetic broker readback", ctx do
    context = controller(ctx)

    tick_opts = [
      jira_reader: JiraReader,
      jira_connector: JiraConnector,
      ticket_chat_reader: Fixture.NativeReader,
      cleanup: FixtureCleanup
    ]

    assert RunLedger.list(ctx.store) == []
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chats").rows == []

    assert {:ok, %{launches: [], events: intake_events}} = Scheduler.tick(context, tick_opts)
    assert Process.get(:lifecycle_jira_search_calls, 0) > 0
    assert Process.get(:lifecycle_jira_search) |> length() == 1
    assert Enum.any?(intake_events, &(&1.event == "DELIVERY_REGISTERED"))
    [registered] = RunLedger.list(ctx.store)
    run_id = registered["run_id"]
    ctx = Map.put(ctx, :run_id, run_id)
    assert registered["execution_mode"] == "TICKET_SUPERVISOR_V1"
    assert registered["manual_validation_required"] == 0
    assert registered["state"] == "ADMITTING_WRITER"
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_checkout_intents")["count"] == 0
    parent_request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND action = 'CREATE'")
    assert parent_request["status"] == "PENDING"
    complete_ticket_parent(ctx, context, parent_request, run_id)
    {:ok, parent_before} = TicketChat.for_run(ctx.store, run_id)

    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_CHECKOUT_ADMITTED"))
    {:ok, checkout} = RunLedger.get(ctx.store, registered["run_id"])
    assert checkout["state"] == "PLANNING"
    path = checkout["worktree"]

    {ctx, context} =
      Enum.reduce(["ADMITTING_WRITER", "WRITING", "VERIFYING", "PUSHING"], {ctx, context}, fn expected, {ctx, context} ->
        assert {:ok, %{launches: [launch]}} = Scheduler.tick(context, tick_opts)
        key = launch.task_key
        assert_receive {:factory_task_started, ^key, _}, 15_000
        assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000

        {ctx, context} =
          if expected == "WRITING" do
            completed_evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? AND status = 'RESULT_RECORDED'", [key])
            completed_task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [key])
            GenServer.stop(ctx.store)
            {:ok, reopened_store} = Store.start_link(database: ctx.database)
            on_exit(fn -> if Process.alive?(reopened_store), do: GenServer.stop(reopened_store) end)
            reopened_ctx = %{ctx | store: reopened_store}
            reopened_context = %{context | store: reopened_store}
            assert Store.one!(reopened_store, "SELECT * FROM worker_evidence WHERE request_key = ?", [completed_evidence["request_key"]]) == completed_evidence
            assert Store.one!(reopened_store, "SELECT * FROM factory_tasks WHERE task_key = ?", [key]) == completed_task
            {reopened_ctx, reopened_context}
          else
            {ctx, context}
          end

        assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
        assert {:ok, %{"state" => ^expected, "worktree" => ^path}} = RunLedger.get(ctx.store, registered["run_id"])

        if expected == "ADMITTING_WRITER" do
          assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
          assert Process.get(:lifecycle_jira)["status"] == "In Dev"
        end

        {ctx, context}
      end)

    assert {:ok, %{launches: [], events: pushed_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(pushed_events, &(&1.event == "TICKET_PUSH_COMPLETED"))
    assert {:ok, %{"state" => "MR_CREATING"} = pushed} = RunLedger.get(ctx.store, registered["run_id"])
    assert {:ok, remote_sha} = Worktree.read_remote_branch(%{"path" => ctx.repo}, pushed["branch"])
    assert remote_sha == pushed["candidate_sha"]
    assert {:ok, %{launches: [], events: prepared}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(prepared, &(&1.event == "TICKET_REQUEST_PREPARED"))
    request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND status = 'PENDING'")
    assert {:ok, summary} = TicketChatOutbox.publish(ctx.store, run_id)
    assert summary.status == "PENDING"
    {:ok, summary_request} = DesktopRequest.get(ctx.store, summary.request_key)
    GenServer.stop(ctx.store)
    {:ok, summary_reopened_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(summary_reopened_store), do: GenServer.stop(summary_reopened_store) end)
    ctx = %{ctx | store: summary_reopened_store}
    context = %{context | store: summary_reopened_store}
    assert {:ok, %{status: "UNCHANGED", model_invoked: false}} = TicketChatOutbox.publish(summary_reopened_store, run_id)
    assert {:ok, ^summary_request} = DesktopRequest.get(summary_reopened_store, summary.request_key)
    complete_synthetic_broker(ctx, context, request, pushed, false)
    assert {:ok, %{launches: [], events: adopted}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(adopted, &(&1.event == "TICKET_MR_ADOPTED"))
    refute Enum.any?(adopted, &(&1.event == "TICKET_REVIEW_READY"))
    assert {:ok, %{"state" => "MR_CREATING"}} = RunLedger.get(ctx.store, registered["run_id"])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects WHERE phase = 'COMPLETE'")["count"] == 1
    writer_rows = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows
    initial_ready_tick = Scheduler.tick(context, tick_opts)

    assert {:ok, %{launches: [], events: ready_events}} = initial_ready_tick,
           "initial review finalization tick failed: #{inspect(initial_ready_tick)}"

    assert Enum.any?(ready_events, &(&1.event == "TICKET_REVIEW_READY"))
    assert {:ok, ready} = RunLedger.get(ctx.store, registered["run_id"])

    assert Map.take(ready, ~w(state candidate_sha mr_iid mr_url)) == %{
             "state" => "READY_FOR_REVIEW",
             "candidate_sha" => remote_sha,
             "mr_iid" => 1,
             "mr_url" => "https://fixture.invalid/repository/-/merge_requests/1"
           }

    assert ready["worktree"] == path and ready["candidate_sha"] == remote_sha
    assert ready["candidate_handoff"] == pushed["candidate_handoff"]
    assert {:ok, parent_after} = TicketChat.for_run(ctx.store, run_id)
    identity = ~w(chat_key scope_key issue_id issue_key repo_key generation thread_id cwd create_request_key)
    assert Map.take(parent_after, identity) == Map.take(parent_before, identity)
    assert Store.query!(ctx.store, "SELECT DISTINCT workspace FROM factory_tasks").rows == [[path]]
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == writer_rows
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE released_at IS NULL")["count"] == 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_checkout_intents")["count"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects WHERE phase = 'COMPLETE'")["count"] == 2
    calls = Process.get(:lifecycle_jira_calls)
    assert Enum.map(calls, &elem(&1, 0)) == ~w(jira_transition_issue jira_update_factory_labels jira_add_comment jira_update_factory_labels)
    assert Process.get(:lifecycle_jira)["labels"] |> Enum.sort() == ~w(ai-review human-label repo-grail)
    assert {:ok, %{launches: [], events: idle_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(idle_events, &(&1.event == "TICKET_READY_IDLE"))
    assert Process.get(:lifecycle_jira_calls) == calls
    assert {:ok, ^ready} = RunLedger.get(ctx.store, registered["run_id"])

    markdown = "Revised acceptance boundary\n\n## Manual Validation\n- Required: no"
    {:ok, source_run} = RunLedger.get(ctx.store, run_id)
    assert Jason.decode!(source_run["snapshot_json"]) == Process.get(:lifecycle_jira)
    body = "Revise the contract:\n" <> markdown
    assert {:ok, blocked_command} = TicketChatFixture.stage(ctx, "ready-amendment", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    {:ok, parent} = TicketChat.for_run(ctx.store, run_id)
    Process.put(:lifecycle_native, TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [body]))
    Process.put(:lifecycle_critic_invocations, 0)
    Process.put(:lifecycle_critic_output, %{"status" => "BLOCK", "findings" => [], "required_questions" => ["Clarify the revised acceptance boundary"]})
    Process.put(:lifecycle_stale_draft_readback, true)
    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}

    assert {:ok, %{launches: [], events: uncertain_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(uncertain_events, &(&1.event == "TICKET_AMENDMENT_DEFERRED"))
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_jira_effects WHERE command_key = ?", [blocked_command["command_key"]])["phase"] == "UNCERTAIN"
    assert Process.get(:lifecycle_critic_invocations) == 0

    previous_jira_calls = Process.get(:lifecycle_jira_calls)
    GenServer.stop(ctx.store)
    {:ok, reopened_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened_store), do: GenServer.stop(reopened_store) end)
    ctx = %{ctx | store: reopened_store}
    context = %{context | store: reopened_store}
    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}

    assert {:ok, %{launches: [], events: blocked_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(blocked_events, &(&1.event == "TICKET_AMENDMENT_DEFERRED"))
    assert Store.one!(reopened_store, "SELECT phase FROM ticket_amendment_jira_effects WHERE command_key = ?", [blocked_command["command_key"]])["phase"] == "READ_BACK"
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [blocked_command["command_key"]])["phase"] == "RESULT_RECORDED"
    assert Process.get(:lifecycle_critic_invocations) == 1

    assert {:ok, %{launches: [], events: replay_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(replay_events, &(&1.event == "TICKET_AMENDMENT_DEFERRED"))
    assert Store.one!(reopened_store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [blocked_command["command_key"]])["phase"] == "RESULT_RECORDED"
    assert Process.get(:lifecycle_critic_invocations) == 1
    assert Process.get(:lifecycle_jira_calls) == previous_jira_calls

    corrected_markdown = markdown <> "\n\nClarification: keep the review gate on the retained candidate."
    corrected_body = "Revise the contract:\n" <> corrected_markdown
    assert {:ok, corrected_command} = TicketChatFixture.stage(ctx, "ready-correction", corrected_body, [%{"operation" => "propose_contract_revision", "markdown" => corrected_markdown}])
    Process.put(:lifecycle_native, TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [body, corrected_body]))
    Process.put(:lifecycle_critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []})

    assert {:ok, _collected} = TicketChatCommands.collect(ctx.store, run_id, native_reader: Fixture.NativeReader)
    {:ok, correction_run} = RunLedger.get(ctx.store, run_id)
    {:ok, correction_chat} = TicketChat.for_run(ctx.store, run_id)

    controller_context = %{
      "chat_key" => correction_chat["chat_key"],
      "run_id" => correction_run["run_id"],
      "binding" => Map.take(correction_run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", correction_chat["generation"])
    }

    control_workspace = Path.join(context.workspace_root, Path.join("factory-controller", context.factory.scope))
    File.mkdir_p!(control_workspace)
    jira_options = Keyword.merge(context.ticket_options, workspace: control_workspace, jira_reader: JiraReader, jira_connector: JiraConnector)
    assert {:ok, _amendment} = TicketContractAmendment.reserve(ctx.store, corrected_command["command_key"], controller_context)
    assert {:ok, _published} = TicketAmendmentJiraOperation.publish_draft(ctx.store, corrected_command["command_key"], controller_context, jira_options)
    assert {:ok, draft} = TicketAmendmentJiraOperation.readback(ctx.store, corrected_command["command_key"])
    assert {:ok, _attempt} = TicketContractAmendment.prepare_critic(ctx.store, corrected_command["command_key"], controller_context, draft["readback_json"], context.factory.models)
    assert {:ok, critique} = TicketAmendmentCritic.execute(ctx.store, corrected_command["command_key"], controller_context, control_workspace, context.factory.models, app_server: Fixture.CriticServer)
    assert critique["qualifies"] == true
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [corrected_command["command_key"]])["phase"] == "RESULT_RECORDED"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_amendment_authorization_effects WHERE command_key = ?", [corrected_command["command_key"]])["count"] == 0
    assert Process.get(:lifecycle_critic_invocations) == 2

    GenServer.stop(ctx.store)
    {:ok, preauthorization_reopened_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(preauthorization_reopened_store), do: GenServer.stop(preauthorization_reopened_store) end)
    ctx = %{ctx | store: preauthorization_reopened_store}
    context = %{context | store: preauthorization_reopened_store}
    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}
    Process.put(:lifecycle_stale_auth_readback, true)

    assert {:ok, %{launches: [], events: auth_uncertain_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(auth_uncertain_events, &(&1.event == "TICKET_AMENDMENT_DEFERRED"))
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [corrected_command["command_key"]])["phase"] == "RESULT_RECORDED"
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_authorization_effects WHERE command_key = ?", [corrected_command["command_key"]])["phase"] == "UNCERTAIN"
    assert Process.get(:lifecycle_critic_invocations) == 2

    auth_writes =
      Process.get(:lifecycle_jira_calls)
      |> Enum.count(fn
        {"jira_add_comment", args} -> String.contains?(args["body"], "mode=automatic critic-task-key=")
        _ -> false
      end)

    assert auth_writes == 1

    GenServer.stop(ctx.store)
    {:ok, authorization_reopened_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(authorization_reopened_store), do: GenServer.stop(authorization_reopened_store) end)
    ctx = %{ctx | store: authorization_reopened_store}
    context = %{context | store: authorization_reopened_store}
    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}

    assert {:ok, %{launches: [], events: amendment_events}} = Scheduler.tick(critic_context, tick_opts)

    assert Enum.any?(amendment_events, &(&1.event == "TICKET_AMENDMENT_APPLIED"))

    assert {:ok, %{"state" => "VERIFYING", "candidate_sha" => ^remote_sha, "worktree" => ^path}} = RunLedger.get(authorization_reopened_store, run_id)
    assert {:ok, %{"status" => "REJECTED"}} = TicketChatCommands.get(authorization_reopened_store, blocked_command["command_key"])
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(authorization_reopened_store, corrected_command["command_key"])
    assert Store.one!(authorization_reopened_store, "SELECT phase FROM ticket_amendment_authorization_effects WHERE command_key = ?", [corrected_command["command_key"]])["phase"] == "READ_BACK"
    assert Process.get(:lifecycle_critic_invocations) == 2

    assert Enum.count(Process.get(:lifecycle_jira_calls), fn
             {"jira_add_comment", args} -> String.contains?(args["body"], "mode=automatic critic-task-key=")
             _ -> false
           end) == 1

    assert {:ok, %{launches: [verification]}} = Scheduler.tick(context, tick_opts)
    assert verification.task_key =~ "change-verifier"
    {:ok, verifier_run} = RunLedger.get(ctx.store, run_id)
    verifier_context = Map.take(verifier_run, ~w(run_id state spec_revision contract_sha256 candidate_sha verifier_round))
    assert_receive {:factory_task_started, verifier_key, _}, 15_000
    assert verifier_key == verification.task_key
    assert_receive {:factory_task_finished, ^verifier_key, verifier_result}, 60_000

    assert match?({:ok, _}, verifier_result),
           "verifier failed for #{inspect(verifier_context)}: #{inspect(verifier_result)}"

    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    {:ok, pre_push_run} = RunLedger.get(ctx.store, run_id)
    push_result = Scheduler.tick(context, tick_opts)
    assert {:ok, %{launches: [], events: push_events}} = push_result

    assert Enum.any?(push_events, &(&1.event == "TICKET_PUSH_COMPLETED")),
           "post-amendment push did not complete for #{pre_push_run["run_id"]}: #{inspect(push_result)}"

    {:ok, pushed_after_amendment} = RunLedger.get(ctx.store, run_id)
    assert {:ok, %{launches: [], events: prepared_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(prepared_events, &(&1.event == "TICKET_REQUEST_PREPARED"))
    pending_mr_request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND status = 'PENDING'")
    legacy_metadata = Jason.decode!(pending_mr_request["metadata_json"])
    legacy_binding = Map.put(legacy_metadata["delivery_operation"], "version", 1)
    {:ok, legacy_key} = TicketMrOperation.request_key(legacy_binding)
    legacy_metadata = Map.put(legacy_metadata, "delivery_operation", legacy_binding)

    legacy_request_attrs =
      pending_mr_request
      |> Map.take(~w(target_kind target_key action codex_project_id existing_thread_id model reasoning_effort title prompt cwd))
      |> Map.put("request_key", legacy_key)
      |> Map.put("schema", Jason.decode!(pending_mr_request["schema_json"]))
      |> Map.put("metadata", legacy_metadata)

    Store.query!(ctx.store, "DELETE FROM desktop_requests WHERE request_key = ?", [pending_mr_request["request_key"]])
    assert {:ok, mr_request} = DesktopRequest.enqueue(ctx.store, legacy_request_attrs)
    assert legacy_binding["version"] == 1
    assert legacy_binding["completed_push_sha256"] == Base.encode16(:crypto.hash(:sha256, pushed_after_amendment["candidate_handoff"]), case: :lower)
    complete_synthetic_broker(ctx, context, mr_request, pushed_after_amendment, true)
    amendment_adoption_tick = Scheduler.tick(context, tick_opts)

    assert {:ok, %{launches: [], events: amendment_adoption_events}} = amendment_adoption_tick,
           "post-amendment MR adoption tick failed: #{inspect(amendment_adoption_tick)}"

    amendment_finalization_tick = Scheduler.tick(context, tick_opts)

    assert {:ok, %{launches: [], events: amendment_finalization_events}} = amendment_finalization_tick,
           "post-amendment review finalization tick failed: #{inspect(amendment_finalization_tick)}"

    {:ok, ready_after_amendment} = RunLedger.get(ctx.store, run_id)

    assert Map.take(ready_after_amendment, ~w(state candidate_sha mr_iid mr_url)) == %{
             "state" => "READY_FOR_REVIEW",
             "candidate_sha" => pushed_after_amendment["candidate_sha"],
             "mr_iid" => 1,
             "mr_url" => "https://fixture.invalid/repository/-/merge_requests/1"
           },
           "post-amendment MR did not return to READY: ticks=#{inspect([amendment_adoption_events, amendment_finalization_events])}, run=#{inspect(Map.take(ready_after_amendment, ~w(state candidate_sha verifier_round mr_iid mr_url last_error)))}"

    prior_v2_review = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE run_id = ? AND operation = 'REVIEW_READY' ORDER BY updated_at DESC LIMIT 1", [run_id])
    prior_v2_binding = Jason.decode!(prior_v2_review["binding_json"])
    assert prior_v2_review["phase"] == "COMPLETE"
    assert prior_v2_binding["identity_version"] == 2
    prior_v2_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [prior_v2_review["operation_key"]])
    assert not is_nil(prior_v2_access["released_at"])

    direct_question_key = "Q-ready-direct"

    assert {:ok, _} =
             TicketChatCommands.open_question(ctx.store, run_id, %{
               "question_key" => direct_question_key,
               "body" => "Keep the current candidate?",
               "answers" => %{"yes" => true}
             })

    direct_body = "Answer Q-ready-direct: yes\nRework: current candidate."

    direct_operations = [
      %{"operation" => "answer_question", "question_key" => direct_question_key, "value" => true},
      %{"operation" => "request_rework"}
    ]

    assert {:ok, direct_command} = TicketChatFixture.stage(ctx, "ready-direct-rework", direct_body, direct_operations)
    {:ok, direct_parent} = TicketChat.for_run(ctx.store, run_id)

    direct_readback =
      TicketChatFixture.native(Map.put(ctx, :cwd, direct_parent["cwd"]), [direct_body])
      |> put_in(["turns", Access.at(0), "id"], "ready-direct-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "ready-direct-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "ready-direct-client")

    Process.put(:lifecycle_native, direct_readback)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, run_id, direct_readback)
    protected_tables = ~w(runs factory_tasks workspace_access worker_evidence ticket_chat_commands ticket_chat_inputs ticket_chat_questions events model_routes)
    protected_snapshot = fn -> Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end) end
    protected_before_rework_attempt = protected_snapshot.()
    checkout_head_before_rework_attempt = git(path, ["rev-parse", "HEAD"]) |> String.trim()

    low_capacity_context = %{context | ticket_options: Keyword.put(context.ticket_options, :free_bytes, 19_999_999_999)}
    low_capacity_attempt = Scheduler.tick(low_capacity_context, tick_opts)

    assert {:ok, %{launches: [], events: capacity_events}} = low_capacity_attempt,
           "low-capacity READY rework was not deferred: #{inspect(low_capacity_attempt)}"

    assert Enum.any?(capacity_events, &(&1.event == "TICKET_DEFERRED" and String.contains?(&1.detail, "insufficient_writer_capacity")))
    assert {:ok, %{"status" => "ACCEPTED"}} = TicketChatCommands.get(ctx.store, direct_command["command_key"])
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [direct_question_key]) == %{"status" => "OPEN", "answer_json" => nil}
    {:ok, capacity_run} = RunLedger.get(ctx.store, run_id)
    assert Map.take(capacity_run, ~w(state candidate_sha)) == %{"state" => "READY_FOR_REVIEW", "candidate_sha" => ready_after_amendment["candidate_sha"]}
    assert protected_snapshot.() == protected_before_rework_attempt
    assert git(path, ["rev-parse", "HEAD"]) |> String.trim() == checkout_head_before_rework_attempt
    refute_receive {:factory_task_started, _, _}

    Store.query!(
      ctx.store,
      "CREATE TRIGGER fail_ready_command_event BEFORE INSERT ON events WHEN NEW.event_type = 'TICKET_COMMAND_APPLIED' BEGIN SELECT RAISE(ABORT, 'simulated READY event failure'); END"
    )

    event_failure_attempt = Scheduler.tick(context, tick_opts)

    assert {:ok, %{launches: [], events: event_failure_events}} = event_failure_attempt,
           "READY terminal-event failure was not deferred: #{inspect(event_failure_attempt)}"

    assert Enum.any?(event_failure_events, &(&1.event == "TICKET_DEFERRED"))
    assert {:ok, %{"status" => "ACCEPTED"}} = TicketChatCommands.get(ctx.store, direct_command["command_key"])
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [direct_question_key]) == %{"status" => "OPEN", "answer_json" => nil}
    {:ok, event_failure_run} = RunLedger.get(ctx.store, run_id)
    assert Map.take(event_failure_run, ~w(state candidate_sha)) == %{"state" => "READY_FOR_REVIEW", "candidate_sha" => ready_after_amendment["candidate_sha"]}
    assert protected_snapshot.() == protected_before_rework_attempt
    assert git(path, ["rev-parse", "HEAD"]) |> String.trim() == checkout_head_before_rework_attempt
    refute_receive {:factory_task_started, _, _}
    Store.query!(ctx.store, "DROP TRIGGER fail_ready_command_event")

    base_context = context
    preflight_context = put_in(context, [:factory, :repositories, "grail", "ci_preflight"], "draft_mr")
    context = preflight_context

    direct_task_key = run_id <> ":feature-writer"

    interrupted_attempt =
      try do
        Scheduler.tick(%{preflight_context | task_supervisor: nil}, tick_opts)
      catch
        :exit, reason -> {:exit, reason}
      end

    assert match?({:ok, %{launches: []}}, interrupted_attempt) or match?({:exit, _}, interrupted_attempt)

    {:ok, direct_after_retry} = TicketChatCommands.get(ctx.store, direct_command["command_key"])
    {:ok, run_after_retry} = RunLedger.get(ctx.store, run_id)
    {:ok, task_after_retry} = TaskLedger.get(ctx.store, direct_task_key)

    assert direct_after_retry["status"] == "APPLIED",
           "READY rework preparation did not apply: command=#{inspect(Map.take(direct_after_retry, ~w(status application_receipt_json)))} tick=#{inspect(interrupted_attempt)} run=#{inspect(Map.take(run_after_retry, ~w(state last_error)))} task_route=#{inspect(Map.take(task_after_retry, ~w(run_id role codex_project_id codex_section_id status prompt_sha256)))}"

    application_raw = direct_after_retry["application_receipt_json"]

    application = Jason.decode!(application_raw)
    assert application["answered_question_keys"] == [direct_question_key]
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, application["answer_proof_sha256"] || "")
    assert application["input_key"] == direct_after_retry["input_key"]

    assert Store.one!(ctx.store, "SELECT status, answer_json, input_key FROM ticket_chat_questions WHERE question_key = ?", [direct_question_key]) == %{
             "status" => "ANSWERED",
             "answer_json" => "true",
             "input_key" => application["input_key"]
           }

    assert {:ok, replay} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])
    assert replay.input["input_key"] == application["input_key"]
    prepared_request = application["request_key"]
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request]) == %{"status" => "RESERVED"}
    assert {:ok, task_before_reopen} = TaskLedger.get(ctx.store, direct_task_key)
    assert task_before_reopen["status"] == "STARTING"
    assert {:ok, prepared_run} = RunLedger.get(ctx.store, run_id)
    assert prepared_run["worktree"] == path
    prepared_access = Store.one!(ctx.store, "SELECT request_key, canonical_path FROM workspace_access WHERE reservation_key = ?", [application["reservation_key"]])
    assert prepared_access == %{"request_key" => prepared_request, "canonical_path" => prepared_run["worktree"]}

    original_head = git(path, ["rev-parse", "HEAD"]) |> String.trim()
    branch = git(path, ["branch", "--show-current"]) |> String.trim()
    git(path, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "test: transient READY checkout drift"])
    drifted_head = git(path, ["rev-parse", "HEAD"]) |> String.trim()
    assert drifted_head != original_head

    GenServer.stop(ctx.store)
    {:ok, reopened_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened_store), do: GenServer.stop(reopened_store) end)
    ctx = %{ctx | store: reopened_store}
    context = %{context | store: reopened_store}
    {:ok, resumed_supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(resumed_supervisor), do: Supervisor.stop(resumed_supervisor) end)

    restarted_context = %{
      context
      | store: reopened_store,
        task_supervisor: resumed_supervisor,
        ticket_options: Keyword.put(preflight_context.ticket_options, :app_server, Fixture.HeldResumeWorkerServer)
    }

    try do
      git(path, ["update-ref", "refs/heads/" <> branch, original_head])
      assert git(path, ["rev-parse", "HEAD"]) |> String.trim() == original_head
      prepared_access_full = Store.one!(reopened_store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [application["reservation_key"]])
      prepared_evidence_full = Store.one!(reopened_store, "SELECT * FROM worker_evidence WHERE request_key = ?", [prepared_request])
      prepared_run_full = RunLedger.get(reopened_store, run_id)
      prepared_task_full = TaskLedger.get(reopened_store, direct_task_key)
      prepared_command_full = TicketChatCommands.get(reopened_store, direct_command["command_key"])
      Store.query!(reopened_store, "UPDATE workspace_access SET generation = generation + 1 WHERE reservation_key = ?", [application["reservation_key"]])

      try do
        generation_attempt = Scheduler.tick(restarted_context, tick_opts)

        assert {:ok, %{launches: [], events: generation_events}} = generation_attempt,
               "changed READY reservation generation was not deferred: #{inspect(generation_attempt)}"

        assert Enum.any?(generation_events, &(&1.event == "TICKET_DEFERRED"))

        assert Enum.any?(generation_events, &(&1.event == "TICKET_DEFERRED" and String.contains?(&1.detail, "ready_rework_access_changed"))),
               "generation drift had the wrong typed rejection: #{inspect(generation_events)}"

        assert Store.one!(reopened_store, "SELECT * FROM worker_evidence WHERE request_key = ?", [prepared_request]) == prepared_evidence_full
        assert RunLedger.get(reopened_store, run_id) == prepared_run_full
        assert TaskLedger.get(reopened_store, direct_task_key) == prepared_task_full
        assert TicketChatCommands.get(reopened_store, direct_command["command_key"]) == prepared_command_full
        drifted_access = Store.one!(reopened_store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [application["reservation_key"]])
        assert drifted_access == Map.put(prepared_access_full, "generation", prepared_access_full["generation"] + 1)
        refute_receive {:ticket_resume_start_sent, _, _}
      after
        Store.query!(reopened_store, "UPDATE workspace_access SET generation = ? WHERE reservation_key = ?", [prepared_access_full["generation"], application["reservation_key"]])
      end

      assert Store.one!(reopened_store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [application["reservation_key"]]) == prepared_access_full
      git(path, ["update-ref", "refs/heads/" <> branch, drifted_head])
      assert git(path, ["rev-parse", "HEAD"]) |> String.trim() == drifted_head

      head_drift_attempt = Scheduler.tick(restarted_context, tick_opts)

      assert {:ok, %{launches: [], events: head_drift_events}} = head_drift_attempt,
             "drifted READY checkout was not deferred: #{inspect(head_drift_attempt)}"

      assert Enum.any?(head_drift_events, &(&1.event == "TICKET_DEFERRED"))
      assert Store.one!(reopened_store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request]) == %{"status" => "RESERVED"}
      refute_receive {:factory_task_started, ^direct_task_key, _}
    after
      git(path, ["update-ref", "refs/heads/" <> branch, original_head])
    end

    assert git(path, ["rev-parse", "HEAD"]) |> String.trim() == original_head
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

    assert {:ok, %{launches: [direct_writer]}} = Scheduler.tick(restarted_context, tick_opts)
    assert direct_writer.task_key == direct_task_key
    assert_receive {:ticket_resume_start_sent, resumed_thread, starter}, 15_000
    assert resumed_thread == task_before_reopen["thread_id"]
    assert :ets.lookup(:ticket_resume_start_counter, :count) == [{:count, 1}]
    assert Store.one!(reopened_store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request]) == %{"status" => "START_SENT"}

    {:ok, restart_observer_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(restart_observer_store), do: GenServer.stop(restart_observer_store) end)
    observer_context = %{restarted_context | store: restart_observer_store}
    held_poll = Scheduler.tick(observer_context, tick_opts)

    assert {:ok, %{launches: [], events: held_events}} = held_poll,
           "START_SENT READY resume was not held after reopen: #{inspect(held_poll)}"

    assert Enum.any?(held_events, &(&1.event == "TICKET_DEFERRED"))
    assert :ets.lookup(:ticket_resume_start_counter, :count) == [{:count, 1}]
    assert Store.one!(restart_observer_store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request]) == %{"status" => "START_SENT"}
    refute_receive {:ticket_resume_start_sent, _, _}
    refute_receive {:factory_task_started, ^direct_task_key, _}

    send(starter, :continue_ticket_resume)
    assert_receive {:factory_task_started, ^direct_task_key, ^resumed_thread}, 15_000
    assert_receive {:factory_task_finished, ^direct_task_key, {:ok, _}}, 60_000
    assert :ets.lookup(:ticket_resume_start_counter, :count) == [{:count, 1}]
    ctx = %{ctx | store: restart_observer_store}
    context = %{observer_context | task_supervisor: resumed_supervisor}
    assert {:ok, %{"state" => "REVIEW_WRITING", "candidate_sha" => prior_candidate}} = RunLedger.get(ctx.store, run_id)
    assert prior_candidate == ready_after_amendment["candidate_sha"]
    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => application_raw}} = TicketChatCommands.get(ctx.store, direct_command["command_key"])
    application = Jason.decode!(application_raw)
    assert application["kind"] == "READY_WRITER_REWORK"
    assert application["prior_candidate_handoff"] == ready_after_amendment["candidate_handoff"]
    assert application["request_key"] != application["prior_request_key"]

    assert {:ok, _} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])

    replay_state = fn ->
      for table <- ~w(runs factory_tasks worker_evidence workspace_access ticket_chat_commands ticket_chat_inputs ticket_chat_questions events), into: %{} do
        {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows}
      end
    end

    retained_verifier = Jason.decode!(application["prior_verifier_task_json"])
    intact_state = replay_state.()
    Store.query!(ctx.store, "UPDATE factory_tasks SET failure_code = 'injected-live-verifier-drift' WHERE task_key = ?", [retained_verifier["task_key"]])
    drifted_state = replay_state.()
    assert {:error, :ready_rework_history_changed} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])
    assert replay_state.() == drifted_state
    Store.query!(ctx.store, "UPDATE factory_tasks SET failure_code = ? WHERE task_key = ?", [retained_verifier["failure_code"], retained_verifier["task_key"]])
    assert replay_state.() == intact_state
    assert {:ok, _} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])

    Store.query!(ctx.store, "INSERT INTO events (occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_COMMAND_APPLIED', ?, '[]')", [DateTime.to_iso8601(DateTime.utc_now()), run_id])
    unrelated_event_id = Store.one!(ctx.store, "SELECT last_insert_rowid() AS id")["id"]
    unrelated_event_state = replay_state.()
    assert {:ok, _} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])
    assert replay_state.() == unrelated_event_state
    Store.query!(ctx.store, "DELETE FROM events WHERE id = ?", [unrelated_event_id])
    assert replay_state.() == intact_state

    prior_run = Jason.decode!(application["prior_run_json"])
    tampered_prior_run = Map.put(prior_run, "mr_url", "https://fixture.invalid/foreign/99")
    tampered_prior_json = Jason.encode!(tampered_prior_run)
    tampered_receipt = application |> Map.put("prior_run_json", tampered_prior_json) |> Map.put("prior_run_sha256", Base.encode16(:crypto.hash(:sha256, tampered_prior_json), case: :lower))
    task_rows_before_replay_tamper = Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows
    event_rows_before_replay_tamper = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = ? ORDER BY id", [run_id]).rows
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [Jason.encode!(tampered_receipt), direct_command["command_key"]])
    assert {:error, :ready_rework_application_event_unproven} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks ORDER BY task_key").rows == task_rows_before_replay_tamper
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = ? ORDER BY id", [run_id]).rows == event_rows_before_replay_tamper
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [application_raw, direct_command["command_key"]])
    assert {:ok, _} = TicketChatCommands.validate_ready_rework_replay(ctx.store, direct_command["command_key"])

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM workspace_access WHERE run_id = ? AND mode = 'SOURCE' AND released_at IS NULL", [run_id])["count"] == 1
    post_rework_tick = Scheduler.tick(context, tick_opts)
    assert match?({:ok, %{launches: []}}, post_rework_tick), "unexpected post-rework launches: #{inspect(post_rework_tick)}"
    {:ok, post_rework_run} = RunLedger.get(ctx.store, run_id)
    post_rework_evidence = Store.one!(ctx.store, "SELECT status, output_json, output_sha256, binding_sha256 FROM worker_evidence WHERE request_key = ?", [application["request_key"]])
    post_rework_task = Store.one!(ctx.store, "SELECT status, role, stage, failure_code FROM factory_tasks WHERE task_key = ?", [direct_task_key])

    output_summary =
      case Jason.decode(post_rework_evidence["output_json"] || "null") do
        {:ok, output} when is_map(output) -> Map.take(output, ~w(status changed_paths commit_message))
        _ -> nil
      end

    assert post_rework_run["state"] == "VERIFYING",
           "direct READY writer did not advance: tick=#{inspect(case post_rework_tick do
             {:ok, result} -> Map.take(result, [:events, :launches])
             other -> other
           end)} run=#{inspect(Map.take(post_rework_run, ~w(state verifier_round last_error candidate_sha review_base_sha)))} evidence=#{inspect(Map.take(post_rework_evidence, ~w(status output_sha256 binding_sha256)))} output=#{inspect(output_summary)} task=#{inspect(post_rework_task)}"

    fresh_round = post_rework_run["verifier_round"]
    context = %{base_context | store: restart_observer_store, task_supervisor: resumed_supervisor}
    assert fresh_round > ready_after_amendment["verifier_round"]
    assert {:ok, %{launches: [fresh_verifier]}} = Scheduler.tick(context, tick_opts)
    assert fresh_verifier.task_key == run_id <> ":change-verifier:" <> Integer.to_string(fresh_round)
    assert_receive {:factory_task_started, fresh_verifier_key, _}, 15_000
    assert fresh_verifier_key == fresh_verifier.task_key
    assert_receive {:factory_task_finished, ^fresh_verifier_key, fresh_verifier_result}, 60_000

    assert match?({:ok, _}, fresh_verifier_result),
           "fresh rework verifier failed for #{run_id} candidate #{prior_candidate}: #{inspect(fresh_verifier_result)}"

    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    rework_push_result = Scheduler.tick(context, tick_opts)
    assert {:ok, %{launches: [], events: rework_push_events}} = rework_push_result

    history_diagnostics =
      if Enum.any?(rework_push_events, &(&1.event == "TICKET_PUSH_COMPLETED")) do
        :not_needed
      else
        {:ok, push_run} = RunLedger.get(ctx.store, run_id)

        case TicketWorkerRunner.retained_review_preimage(ctx.store, push_run) do
          {:ok, prior} ->
            intent = Jason.decode!(prior["candidate_handoff"])
            binding = Jason.decode!(intent["binding_json"])

            %{
              retained_run: Map.take(prior, ~w(state candidate_sha contract_sha256 spec_revision verifier_round branch worktree mr_iid mr_url)),
              push_binding: Map.take(binding, ~w(candidate_sha contract_sha256 spec_revision verifier_round branch worktree)),
              push_history: TicketPush.validate_historical_completed_preimage(ctx.store, prior),
              retained_mr_history: TicketMrOperation.validate_retained_mr_history(ctx.store, prior)
            }

          {:error, reason} ->
            %{retained_preimage_error: reason}
        end
      end

    assert Enum.any?(rework_push_events, &(&1.event == "TICKET_PUSH_COMPLETED")),
           "direct READY rework push did not complete for #{run_id}: #{inspect(rework_push_result)} history=#{inspect(history_diagnostics)}"

    {:ok, direct_pushed} = RunLedger.get(ctx.store, run_id)
    assert direct_pushed["candidate_sha"] == prior_candidate
    refute direct_pushed["candidate_handoff"] == pushed_after_amendment["candidate_handoff"]
    assert direct_pushed["verifier_round"] > prior_v2_binding["verifier_round"]
    assert {:ok, direct_selection} = TicketJiraJournal.select_review_operation(ctx.store, run_id)
    assert direct_selection.identity_version == 2 and direct_selection.disposition == :new
    assert direct_selection.operation_key != prior_v2_review["operation_key"]
    assert Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE operation_key = ?", [prior_v2_review["operation_key"]]) == prior_v2_review
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [prior_v2_review["operation_key"]]) == prior_v2_access

    assert {:ok, %{launches: [], events: rework_mr_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(rework_mr_events, &(&1.event == "TICKET_REQUEST_PREPARED"))
    rework_mr_request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND status = 'PENDING'")
    {:ok, rework_metadata} = Jason.decode(rework_mr_request["metadata_json"])
    rework_binding = rework_metadata["delivery_operation"]
    assert rework_binding["version"] == 2
    assert rework_binding["completed_push_sha256"] == Base.encode16(:crypto.hash(:sha256, direct_pushed["candidate_handoff"]), case: :lower)
    assert rework_mr_request["request_key"] != legacy_key

    complete_synthetic_broker(ctx, context, rework_mr_request, direct_pushed, true)
    direct_mr_adoption_tick = Scheduler.tick(context, tick_opts)

    assert {:ok, %{launches: [], events: direct_mr_adoption_events}} = direct_mr_adoption_tick,
           "direct-rework MR adoption tick failed: #{inspect(direct_mr_adoption_tick)}"

    direct_mr_finalization_tick = Scheduler.tick(context, tick_opts)

    assert {:ok, %{launches: [], events: direct_mr_finalization_events}} = direct_mr_finalization_tick,
           "direct-rework review finalization tick failed: #{inspect(direct_mr_finalization_tick)}"

    {:ok, direct_ready} = RunLedger.get(ctx.store, run_id)

    assert Map.take(direct_ready, ~w(state candidate_sha mr_iid mr_url)) == %{
             "state" => "READY_FOR_REVIEW",
             "candidate_sha" => prior_candidate,
             "mr_iid" => 1,
             "mr_url" => "https://fixture.invalid/repository/-/merge_requests/1"
           },
           "direct-rework delivery did not return to READY: ticks=#{inspect([direct_mr_adoption_events, direct_mr_finalization_events])}, run=#{inspect(Map.take(direct_ready, ~w(state candidate_sha verifier_round mr_iid mr_url last_error)))}"

    assert {:ok, legacy_succeeded} = DesktopRequest.get(ctx.store, legacy_key)
    {:ok, retained_legacy_metadata} = Jason.decode(legacy_succeeded["metadata_json"])
    assert retained_legacy_metadata["delivery_operation"]["version"] == 1
    assert retained_legacy_metadata["delivery_operation"]["completed_push_sha256"] == legacy_binding["completed_push_sha256"]
    direct_v2_review = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE operation_key = ?", [direct_selection.operation_key])
    direct_v2_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [direct_selection.operation_key])
    assert direct_v2_review["phase"] == "COMPLETE"
    assert not is_nil(direct_v2_access["released_at"])

    previous_writer_mode = Application.get_env(:symphony_elixir, :lifecycle_writer_mode)
    Application.put_env(:symphony_elixir, :lifecycle_writer_mode, :edited)

    on_exit(fn ->
      if previous_writer_mode do
        Application.put_env(:symphony_elixir, :lifecycle_writer_mode, previous_writer_mode)
      else
        Application.delete_env(:symphony_elixir, :lifecycle_writer_mode)
      end
    end)

    edited_body = "Rework the current candidate."
    assert {:ok, edited_command} = TicketChatFixture.stage(ctx, "ready-edited-rework", edited_body, [%{"operation" => "request_rework"}])
    {:ok, edited_parent} = TicketChat.for_run(ctx.store, run_id)

    edited_readback =
      TicketChatFixture.native(Map.merge(ctx, %{cwd: edited_parent["cwd"], chat: edited_parent}), [edited_body], edited_command["command_key"])
      |> put_in(["turns", Access.at(0), "id"], "ready-edited-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "ready-edited-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "ready-edited-client")

    Process.put(:lifecycle_native, edited_readback)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED", "input_key" => edited_input_key}]}} =
             TicketChatCommands.admit_readback(ctx.store, run_id, edited_readback)

    {:ok, edited_accepted} = TicketChatCommands.get(ctx.store, edited_command["command_key"])
    assert edited_accepted["status"] == "ACCEPTED" and edited_accepted["input_key"] == edited_input_key
    edited_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.WorkerServer)}
    assert {:ok, %{launches: [edited_writer]}} = Scheduler.tick(edited_context, tick_opts)
    assert_receive {:factory_task_started, edited_writer_key, _}, 15_000
    assert edited_writer_key == edited_writer.task_key
    assert_receive {:factory_task_finished, ^edited_writer_key, edited_writer_result}, 60_000
    assert match?({:ok, _}, edited_writer_result), "edited READY writer failed: #{inspect(edited_writer_result)}"
    assert {:ok, %{launches: []}} = Scheduler.tick(edited_context, tick_opts)
    {:ok, edited_run} = RunLedger.get(ctx.store, run_id)
    assert edited_run["state"] == "VERIFYING"
    assert edited_run["candidate_sha"] != direct_ready["candidate_sha"]
    assert edited_run["verifier_round"] > direct_ready["verifier_round"]
    assert File.read!(Path.join(edited_run["worktree"], "fixture.txt")) == "edited direct READY rework\n"

    edited_round = edited_run["verifier_round"]
    assert {:ok, %{launches: [edited_verifier]}} = Scheduler.tick(edited_context, tick_opts)
    assert edited_verifier.task_key == run_id <> ":change-verifier:" <> Integer.to_string(edited_round)
    assert_receive {:factory_task_started, edited_verifier_key, _}, 15_000
    assert edited_verifier_key == edited_verifier.task_key
    assert_receive {:factory_task_finished, ^edited_verifier_key, edited_verifier_result}, 60_000
    assert match?({:ok, _}, edited_verifier_result), "edited READY verifier failed: #{inspect(edited_verifier_result)}"
    assert {:ok, %{launches: []}} = Scheduler.tick(edited_context, tick_opts)
    edited_push_tick = Scheduler.tick(edited_context, tick_opts)
    assert {:ok, %{launches: [], events: edited_push_events}} = edited_push_tick
    assert Enum.any?(edited_push_events, &(&1.event == "TICKET_PUSH_COMPLETED")), "edited READY push did not complete: #{inspect(edited_push_tick)}"
    {:ok, edited_pushed} = RunLedger.get(ctx.store, run_id)
    assert edited_pushed["candidate_sha"] == edited_run["candidate_sha"]
    assert {:ok, edited_selection} = TicketJiraJournal.select_review_operation(ctx.store, run_id)
    assert edited_selection.identity_version == 2 and edited_selection.disposition == :new
    assert edited_selection.operation_key != direct_selection.operation_key
    assert edited_pushed["verifier_round"] > Jason.decode!(direct_v2_review["binding_json"])["verifier_round"]
    assert Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE operation_key = ?", [direct_selection.operation_key]) == direct_v2_review
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [direct_selection.operation_key]) == direct_v2_access

    assert {:ok, %{launches: [], events: edited_mr_events}} = Scheduler.tick(edited_context, tick_opts)
    assert Enum.any?(edited_mr_events, &(&1.event == "TICKET_REQUEST_PREPARED"))
    edited_mr_request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND status = 'PENDING'")
    complete_synthetic_broker(ctx, edited_context, edited_mr_request, edited_pushed, true)
    assert {:ok, %{launches: []}} = Scheduler.tick(edited_context, tick_opts)
    assert {:ok, %{launches: []}} = Scheduler.tick(edited_context, tick_opts)
    {:ok, edited_ready} = RunLedger.get(ctx.store, run_id)
    assert edited_ready["state"] == "READY_FOR_REVIEW"
    assert edited_ready["candidate_sha"] == edited_pushed["candidate_sha"]

    loss_body = "Rework the current candidate."
    assert {:ok, loss_command} = TicketChatFixture.stage(ctx, "ready-owner-loss", loss_body, [%{"operation" => "request_rework"}])
    {:ok, loss_parent} = TicketChat.for_run(ctx.store, run_id)

    loss_readback =
      TicketChatFixture.native(Map.merge(ctx, %{cwd: loss_parent["cwd"], chat: loss_parent}), [loss_body], loss_command["command_key"])
      |> put_in(["turns", Access.at(0), "id"], "ready-owner-loss-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "ready-owner-loss-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "ready-owner-loss-client")

    Process.put(:lifecycle_native, loss_readback)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, run_id, loss_readback)
    loss_context = %{edited_context | ticket_options: Keyword.put(edited_context.ticket_options, :app_server, Fixture.HeldResumeWorkerServer)}
    assert {:ok, %{launches: [loss_writer]}} = Scheduler.tick(loss_context, tick_opts)
    assert_receive {:ticket_resume_start_sent, loss_thread, loss_starter}, 15_000
    {:ok, loss_task_before} = TaskLedger.get(ctx.store, loss_writer.task_key)
    assert loss_thread == loss_task_before["thread_id"]
    loss_owner = TaskLauncher.active_owner(loss_writer.task_key)
    assert loss_owner == loss_writer.pid
    {:ok, loss_applied} = TicketChatCommands.get(ctx.store, loss_command["command_key"])
    loss_application = Jason.decode!(loss_applied["application_receipt_json"])
    loss_evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [loss_application["request_key"]])
    loss_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [loss_application["reservation_key"]])
    loss_task = TaskLedger.get(ctx.store, loss_writer.task_key)
    loss_run = RunLedger.get(ctx.store, run_id)
    loss_request = TicketChatCommands.get(ctx.store, loss_command["command_key"])
    loss_counter = :ets.lookup(:ticket_resume_start_counter, :count)
    owner_monitor = Process.monitor(loss_owner)
    assert :ok = Task.Supervisor.terminate_child(resumed_supervisor, loss_owner)
    assert_receive {:DOWN, ^owner_monitor, :process, ^loss_owner, _}, 15_000

    if loss_starter != loss_owner and Process.alive?(loss_starter) do
      starter_monitor = Process.monitor(loss_starter)
      Process.exit(loss_starter, :kill)
      assert_receive {:DOWN, ^starter_monitor, :process, ^loss_starter, _}, 15_000
    end

    assert TaskLauncher.active_owner(loss_writer.task_key) == nil
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ?", [loss_application["request_key"]]) == %{"status" => "START_SENT"}
    GenServer.stop(ctx.store)
    {:ok, loss_reopened_store} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(loss_reopened_store), do: GenServer.stop(loss_reopened_store) end)
    {:ok, loss_supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(loss_supervisor), do: Supervisor.stop(loss_supervisor) end)
    loss_context = %{loss_context | store: loss_reopened_store, task_supervisor: loss_supervisor}
    loss_poll = Scheduler.tick(loss_context, tick_opts)
    assert {:ok, %{launches: [], events: loss_events}} = loss_poll, "START_SENT owner-loss poll failed: #{inspect(loss_poll)}"

    assert Enum.any?(loss_events, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":worker_not_ready_for_consumption")),
           "unexpected START_SENT owner-loss classification: #{inspect(loss_events)}"

    assert Store.one!(loss_reopened_store, "SELECT * FROM worker_evidence WHERE request_key = ?", [loss_application["request_key"]]) == loss_evidence
    assert Store.one!(loss_reopened_store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [loss_application["reservation_key"]]) == loss_access
    assert TaskLedger.get(loss_reopened_store, loss_writer.task_key) == loss_task
    assert RunLedger.get(loss_reopened_store, run_id) == loss_run
    assert TicketChatCommands.get(loss_reopened_store, loss_command["command_key"]) == loss_request
    assert :ets.lookup(:ticket_resume_start_counter, :count) == loss_counter
    assert TaskLauncher.active_owner(loss_writer.task_key) == nil
    refute_receive {:ticket_resume_start_sent, _, _}
  end

  test "normal polling applies a blocked-writer amendment and keeps its SOURCE lease held", ctx do
    previous_writer_mode = Application.get_env(:symphony_elixir, :lifecycle_writer_mode)
    Application.delete_env(:symphony_elixir, :lifecycle_writer_mode)

    on_exit(fn ->
      if previous_writer_mode do
        Application.put_env(:symphony_elixir, :lifecycle_writer_mode, previous_writer_mode)
      else
        Application.delete_env(:symphony_elixir, :lifecycle_writer_mode)
      end
    end)

    context = controller(ctx)
    tick_opts = [jira_reader: JiraReader, jira_connector: JiraConnector]

    assert {:ok, %{launches: [], events: checkout_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(checkout_events, &(&1.event == "TICKET_CHECKOUT_ADMITTED"))

    assert {:ok, %{launches: [planner]}} = Scheduler.tick(context, tick_opts)
    assert_receive {:factory_task_started, planner_key, _}, 15_000
    assert planner_key == planner.task_key
    assert_receive {:factory_task_finished, ^planner_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{"state" => "ADMITTING_WRITER"}} = RunLedger.get(ctx.store, "run")

    assert {:ok, %{launches: [], events: admission_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(admission_events, &(&1.event == "TICKET_WRITER_ADMITTED"))
    assert {:ok, %{launches: [writer]}} = Scheduler.tick(context, tick_opts)
    assert_receive {:factory_task_started, writer_key, _}, 15_000
    assert writer_key == writer.task_key
    assert_receive {:factory_task_finished, ^writer_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{"state" => "WRITING", "candidate_sha" => candidate}} = RunLedger.get(ctx.store, "run")

    Application.put_env(:symphony_elixir, :lifecycle_writer_mode, :blocked)
    assert {:ok, %{launches: [blocked_writer]}} = Scheduler.tick(context, tick_opts)
    assert_receive {:factory_task_started, blocked_writer_key, _}, 15_000
    assert blocked_writer_key == blocked_writer.task_key
    assert_receive {:factory_task_finished, ^blocked_writer_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{"state" => "WRITING", "candidate_sha" => ^candidate}} = RunLedger.get(ctx.store, "run")

    {:ok, blocked_run} = RunLedger.get(ctx.store, "run")
    {:ok, parent} = TicketChat.for_run(ctx.store, "run")
    source_access = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' AND released_at IS NULL ORDER BY generation").rows

    assert source_access != []

    {:ok, _} = RunLedger.update(ctx.store, "run", %{snapshot_json: Jason.encode!(Process.get(:lifecycle_jira))})
    markdown = "Retained blocked-writer scope\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    assert {:ok, command} = TicketChatFixture.stage(ctx, "blocked-amendment", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    Process.put(:lifecycle_native, TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [body]))
    Process.put(:lifecycle_critic_invocations, 0)
    Process.put(:lifecycle_critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []})
    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}

    assert {:ok, %{launches: [], events: amendment_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(amendment_events, &(&1.event == "TICKET_AMENDMENT_APPLIED"))
    assert {:ok, held_run} = RunLedger.get(ctx.store, "run")
    assert held_run["state"] == "WRITING"
    assert held_run["worktree"] == blocked_run["worktree"]
    assert held_run["candidate_sha"] == blocked_run["candidate_sha"]
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' AND released_at IS NULL ORDER BY generation").rows == source_access
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(ctx.store, command["command_key"])
    assert Process.get(:lifecycle_critic_invocations) == 1

    assert {:ok, %{launches: [], events: held_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(held_events, &(&1.event == "TICKET_SOURCE_HELD"))
    assert Process.get(:lifecycle_critic_invocations) == 1
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' AND released_at IS NULL ORDER BY generation").rows == source_access
  end

  test "normal polling does not invent a candidate for a first-writer amendment", ctx do
    previous_writer_mode = Application.get_env(:symphony_elixir, :lifecycle_writer_mode)
    Application.put_env(:symphony_elixir, :lifecycle_writer_mode, :blocked)

    on_exit(fn ->
      if previous_writer_mode do
        Application.put_env(:symphony_elixir, :lifecycle_writer_mode, previous_writer_mode)
      else
        Application.delete_env(:symphony_elixir, :lifecycle_writer_mode)
      end
    end)

    context = controller(ctx)
    tick_opts = [jira_reader: JiraReader, jira_connector: JiraConnector]
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{launches: [planner]}} = Scheduler.tick(context, tick_opts)
    assert_receive {:factory_task_started, planner_key, _}, 15_000
    assert planner_key == planner.task_key
    assert_receive {:factory_task_finished, ^planner_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{launches: [], events: admission_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(admission_events, &(&1.event == "TICKET_WRITER_ADMITTED"))
    assert {:ok, %{launches: [writer]}} = Scheduler.tick(context, tick_opts)
    assert_receive {:factory_task_started, writer_key, _}, 15_000
    assert writer_key == writer.task_key
    assert_receive {:factory_task_finished, ^writer_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{"state" => "WRITING", "candidate_sha" => nil}} = RunLedger.get(ctx.store, "run")

    {:ok, blocked_run} = RunLedger.get(ctx.store, "run")
    source = blocked_run["worktree"]
    original_expected_sha = String.trim(git(source, ["rev-parse", "HEAD"]))
    original_tree = String.trim(git(source, ["write-tree"]))
    measured_base_sha = String.trim(git(source, ["commit-tree", original_tree, "-p", original_expected_sha, "-m", "first writer HEAD measurement fixture"]))
    git(source, ["update-ref", "HEAD", measured_base_sha])
    assert original_expected_sha != measured_base_sha
    File.write!(Path.join(source, "fixture.txt"), "staged first-writer bytes\n")
    git(source, ["add", "fixture.txt"])
    File.write!(Path.join(source, "fixture.txt"), "fixture dirty state\n")
    File.write!(Path.join(source, "untracked-resume-fixture.txt"), "preserve for resume\n")
    source_status = git(source, ["status", "--porcelain=v1"])
    staged_bytes = git(source, ["show", ":fixture.txt"])
    unstaged_bytes = File.read!(Path.join(source, "fixture.txt"))
    untracked_bytes = File.read!(Path.join(source, "untracked-resume-fixture.txt"))

    {:ok, parent} = TicketChat.for_run(ctx.store, "run")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{snapshot_json: Jason.encode!(Process.get(:lifecycle_jira))})
    markdown = "Initial blocked writer scope\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    assert {:ok, command} = TicketChatFixture.stage(ctx, "initial-blocked-amendment", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    Process.put(:lifecycle_native, TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [body]))

    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}
    assert {:ok, %{launches: [], events: events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(events, &(&1.event == "TICKET_AMENDMENT_APPLIED"))
    assert {:ok, %{"candidate_sha" => nil, "state" => "WRITING"}} = RunLedger.get(ctx.store, "run")
    assert {:ok, amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert is_nil(amendment["candidate_sha"])
    sealed_predecessor = Jason.decode!(amendment["predecessor_json"])
    assert sealed_predecessor["checkout_head_sha"] =~ ~r/\A[0-9a-f]{40}\z/
    stopped_access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [sealed_predecessor["reservation_key"]])
    access_json = Jason.encode!(stopped_access)
    access_sha = :crypto.hash(:sha256, access_json) |> Base.encode16(case: :lower)
    assert access_sha == sealed_predecessor["access_sha256"]
    stopped_access_binding = Jason.decode!(stopped_access["binding_json"])
    assert stopped_access_binding["expected_sha"] == ctx.sha
    assert stopped_access_binding["expected_sha"] != sealed_predecessor["checkout_head_sha"]
    assert {:ok, held_receipt} = TicketContractAmendment.blocked_predecessor_for_request(ctx.store, sealed_predecessor["request_key"])
    assert Jason.decode!(held_receipt["blocked_predecessor_json"])["checkout_head_sha"] == sealed_predecessor["checkout_head_sha"]
    assert :ok = WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)

    source_index = Path.join(String.trim(git(source, ["rev-parse", "--absolute-git-dir"])), "index")
    source_file = Path.join(source, "fixture.txt")
    untracked_file = Path.join(source, "untracked-resume-fixture.txt")
    head_ref = String.trim(git(source, ["symbolic-ref", "HEAD"]))
    original_head = String.trim(git(source, ["rev-parse", "HEAD"]))
    existing_head_tree = String.trim(git(source, ["rev-parse", "HEAD^{tree}"]))

    protected_tables =
      ~w(runs factory_tasks workspace_access worker_evidence ticket_chat_commands ticket_chat_inputs ticket_chat_questions ticket_contract_amendments ticket_contract_amendment_supersessions ticket_contract_critic_attempts ticket_amendment_jira_effects ticket_amendment_authorization_effects controller_checks ticket_checkout_intents events desktop_requests)

    protected_rows = fn ->
      Map.new(protected_tables, fn table ->
        {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows}
      end)
    end

    protected_before_head_drift = protected_rows.()
    source_status_before_head_drift = git(source, ["status", "--porcelain=v1"])
    source_index_before_head_drift = File.read!(source_index)
    source_staged_before_head_drift = git(source, ["show", ":fixture.txt"])
    source_bytes_before_head_drift = File.read!(source_file)
    untracked_bytes_before_head_drift = File.read!(untracked_file)

    corrupted_predecessor = sealed_predecessor |> Map.put("checkout_head_sha", stopped_access_binding["expected_sha"]) |> Jason.encode!()
    assert corrupted_predecessor != amendment["predecessor_json"]

    try do
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET predecessor_json = ? WHERE command_key = ?", [corrupted_predecessor, command["command_key"]])
      fault_rows = protected_rows.()
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert protected_rows.() == fault_rows
      assert String.trim(git(source, ["symbolic-ref", "HEAD"])) == head_ref
      assert String.trim(git(source, ["rev-parse", "HEAD"])) == original_head
      assert git(source, ["status", "--porcelain=v1"]) == source_status_before_head_drift
      assert File.read!(source_index) == source_index_before_head_drift
      assert git(source, ["show", ":fixture.txt"]) == source_staged_before_head_drift
      assert File.read!(source_file) == source_bytes_before_head_drift
      assert File.read!(untracked_file) == untracked_bytes_before_head_drift
    after
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET predecessor_json = ? WHERE command_key = ?", [amendment["predecessor_json"], command["command_key"]])
    end

    assert protected_rows.() == protected_before_head_drift
    assert String.trim(git(source, ["symbolic-ref", "HEAD"])) == head_ref
    assert String.trim(git(source, ["rev-parse", "HEAD"])) == original_head
    assert git(source, ["status", "--porcelain=v1"]) == source_status_before_head_drift
    assert File.read!(source_index) == source_index_before_head_drift
    assert git(source, ["show", ":fixture.txt"]) == source_staged_before_head_drift
    assert File.read!(source_file) == source_bytes_before_head_drift
    assert File.read!(untracked_file) == untracked_bytes_before_head_drift
    assert {:ok, %{"phase" => "APPLIED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(ctx.store, command["command_key"])
    assert {:ok, ^held_receipt} = TicketContractAmendment.blocked_predecessor_for_request(ctx.store, sealed_predecessor["request_key"])
    assert :ok = WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)

    synthetic_head =
      String.trim(git(source, ["commit-tree", existing_head_tree, "-p", original_head, "-m", "synthetic held-amendment HEAD drift"]))

    git(source, ["update-ref", head_ref, synthetic_head, original_head])

    try do
      assert {:error, :blocked_amendment_checkout_head_changed} =
               WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)

      assert String.trim(git(source, ["symbolic-ref", "HEAD"])) == head_ref
      assert String.trim(git(source, ["rev-parse", "HEAD"])) == synthetic_head
      assert protected_rows.() == protected_before_head_drift
      assert git(source, ["status", "--porcelain=v1"]) == source_status_before_head_drift
      assert File.read!(source_index) == source_index_before_head_drift
      assert git(source, ["show", ":fixture.txt"]) == source_staged_before_head_drift
      assert File.read!(source_file) == source_bytes_before_head_drift
      assert File.read!(untracked_file) == untracked_bytes_before_head_drift
    after
      git(source, ["update-ref", head_ref, original_head, synthetic_head])
    end

    assert String.trim(git(source, ["symbolic-ref", "HEAD"])) == head_ref
    assert String.trim(git(source, ["rev-parse", "HEAD"])) == original_head
    assert :ok = WorkspaceAccess.validate_blocked_amendment_predecessor(ctx.store, held_receipt)
    assert protected_rows.() == protected_before_head_drift
    assert git(source, ["status", "--porcelain=v1"]) == source_status_before_head_drift
    assert File.read!(source_index) == source_index_before_head_drift
    assert git(source, ["show", ":fixture.txt"]) == source_staged_before_head_drift
    assert File.read!(source_file) == source_bytes_before_head_drift
    assert File.read!(untracked_file) == untracked_bytes_before_head_drift
    assert {:ok, %{"status" => "APPLIED"}} = TicketChatCommands.get(ctx.store, command["command_key"])
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' AND mode = 'SOURCE' AND released_at IS NULL").rows != []
    assert git(source, ["status", "--porcelain=v1"]) == source_status
    assert git(source, ["show", ":fixture.txt"]) == staged_bytes
    assert File.read!(Path.join(source, "fixture.txt")) == unstaged_bytes
    assert File.read!(Path.join(source, "untracked-resume-fixture.txt")) == untracked_bytes
    {:ok, held_writer} = TaskLedger.get(ctx.store, writer_key)
    held_thread = held_writer["thread_id"]
    assert is_binary(held_thread)

    rework_body = "Rework the current candidate."
    assert {:ok, staged_rework} = TicketChatFixture.stage(ctx, "first-writer-explicit-resume", rework_body, [%{"operation" => "request_rework"}])
    appended = TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [body, rework_body])["turns"] |> List.last()
    prior_native = Process.get(:lifecycle_native)
    Process.put(:lifecycle_native, Map.update!(prior_native, "turns", &(&1 ++ [appended])))

    assert {:ok, %{receipts: admitted_receipts}} =
             TicketChatCommands.admit_readback(ctx.store, "run", Process.get(:lifecycle_native))

    assert Enum.any?(admitted_receipts, &(&1["command_key"] == staged_rework["command_key"] and &1["status"] == "ACCEPTED"))

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

    resume_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.HeldResumeWorkerServer)}
    failed_context = %{resume_context | task_supervisor: nil}

    interrupted =
      try do
        Scheduler.tick(failed_context, tick_opts)
      catch
        :exit, reason -> {:exit, reason}
      end

    assert match?({:exit, _reason}, interrupted)

    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => application}} =
             TicketChatCommands.get(ctx.store, staged_rework["command_key"])

    prepared_receipt = Jason.decode!(application)
    prepared_request = prepared_receipt["request_key"]
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ?", [prepared_request])["status"] == "RESERVED"
    assert {:ok, prepared_task} = TaskLedger.get(ctx.store, writer_key)
    assert prepared_task["status"] == "STARTING"

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    resumed_context = %{resume_context | store: reopened, task_supervisor: supervisor}

    prepared_access = Store.one!(reopened, "SELECT * FROM workspace_access WHERE request_key = ?", [prepared_request])
    prepared_evidence = Store.one!(reopened, "SELECT * FROM worker_evidence WHERE request_key = ?", [prepared_request])
    Store.query!(reopened, "UPDATE workspace_access SET generation = generation + 1 WHERE request_key = ?", [prepared_request])
    assert {:ok, %{launches: [], events: owner_events}} = Scheduler.tick(resumed_context, tick_opts)
    assert Enum.any?(owner_events, &(&1.event == "TICKET_DEFERRED"))
    refute_receive {:ticket_resume_start_sent, _, _}
    assert Store.one!(reopened, "SELECT * FROM worker_evidence WHERE request_key = ?", [prepared_request]) == prepared_evidence
    assert TaskLedger.get(reopened, writer_key) == {:ok, prepared_task}
    Store.query!(reopened, "UPDATE workspace_access SET generation = ? WHERE request_key = ?", [prepared_access["generation"], prepared_request])
    assert Store.one!(reopened, "SELECT * FROM workspace_access WHERE request_key = ?", [prepared_request]) == prepared_access

    original_head = String.trim(git(source, ["rev-parse", "HEAD"]))
    tree = String.trim(git(source, ["write-tree"]))
    drifted_head = String.trim(git(source, ["commit-tree", tree, "-p", original_head, "-m", "prepared resume HEAD drift fixture"]))
    git(source, ["update-ref", "HEAD", drifted_head])
    assert {:ok, %{launches: [], events: drift_events}} = Scheduler.tick(resumed_context, tick_opts)
    assert Enum.any?(drift_events, &(&1.event == "TICKET_DEFERRED"))
    refute_receive {:ticket_resume_start_sent, _, _}
    assert Store.one!(reopened, "SELECT * FROM workspace_access WHERE request_key = ?", [prepared_request]) == prepared_access
    assert Store.one!(reopened, "SELECT * FROM worker_evidence WHERE request_key = ?", [prepared_request]) == prepared_evidence
    assert TaskLedger.get(reopened, writer_key) == {:ok, prepared_task}
    git(source, ["update-ref", "HEAD", original_head])

    assert {:ok, %{launches: [resumed_writer]}} = Scheduler.tick(resumed_context, tick_opts)
    assert resumed_writer.task_key == writer_key
    assert_receive {:ticket_resume_start_sent, resumed_thread, starter}, 15_000
    assert resumed_thread == held_thread
    assert :ets.lookup(:ticket_resume_start_counter, :count) == [{:count, 1}]
    send(starter, :continue_ticket_resume)
    assert_receive {:factory_task_started, ^writer_key, ^held_thread}, 15_000
    assert_receive {:factory_task_finished, ^writer_key, resume_result}, 60_000
    assert match?({:ok, _}, resume_result)
    assert {:ok, %{launches: [], events: adoption_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(adoption_events, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":native_slice_pre_staged_changes"))
    assert {:ok, %{"candidate_sha" => nil, "state" => "WRITING"}} = RunLedger.get(ctx.store, "run")

    resumed_evidence =
      Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE task_key = ? AND request_key != ?", [writer_key, sealed_predecessor["request_key"]])

    assert resumed_evidence["status"] == "RESULT_RECORDED"
    assert git(source, ["status", "--porcelain=v1"]) == source_status
    assert git(source, ["show", ":fixture.txt"]) == staged_bytes
    assert File.read!(Path.join(source, "fixture.txt")) == unstaged_bytes
    assert File.read!(Path.join(source, "untracked-resume-fixture.txt")) == untracked_bytes
    [[resume_access]] = Store.query!(ctx.store, "SELECT binding_json FROM workspace_access WHERE run_id = 'run' AND mode = 'SOURCE' AND released_at IS NULL ORDER BY generation DESC LIMIT 1").rows
    assert Jason.decode!(resume_access)["expected_sha"] == sealed_predecessor["checkout_head_sha"]

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    assert {:ok, %{launches: [], events: replay_events}} = Scheduler.tick(%{critic_context | store: reopened}, tick_opts)
    assert Enum.any?(replay_events, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":native_slice_pre_staged_changes"))
    assert Store.one!(reopened, "SELECT status FROM worker_evidence WHERE request_key = ?", [resumed_evidence["request_key"]])["status"] == "RESULT_RECORDED"
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [writer_key])["count"] == 2
    assert {:ok, %{"candidate_sha" => nil, "state" => "WRITING"}} = RunLedger.get(reopened, "run")
  end

  test "normal polling adopts a valid unstaged nil-candidate amended resume once", ctx do
    previous_writer_mode = Application.get_env(:symphony_elixir, :lifecycle_writer_mode)
    Application.put_env(:symphony_elixir, :lifecycle_writer_mode, :blocked)

    on_exit(fn ->
      if previous_writer_mode do
        Application.put_env(:symphony_elixir, :lifecycle_writer_mode, previous_writer_mode)
      else
        Application.delete_env(:symphony_elixir, :lifecycle_writer_mode)
      end
    end)

    context = controller(ctx)
    tick_opts = [jira_reader: JiraReader, jira_connector: JiraConnector]
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{launches: [planner]}} = Scheduler.tick(context, tick_opts)
    assert planner.task_key == "run:feature-planner"
    assert_receive {:factory_task_started, planner_key, _}, 15_000
    assert_receive {:factory_task_finished, ^planner_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{launches: [], events: admission_events}} = Scheduler.tick(context, tick_opts)
    assert Enum.any?(admission_events, &(&1.event == "TICKET_WRITER_ADMITTED"))
    assert {:ok, %{launches: [writer]}} = Scheduler.tick(context, tick_opts)
    assert writer.task_key == "run:feature-writer"
    assert_receive {:factory_task_started, writer_key, _}, 15_000
    assert_receive {:factory_task_finished, ^writer_key, {:ok, _}}, 60_000
    assert {:ok, %{launches: []}} = Scheduler.tick(context, tick_opts)
    assert {:ok, %{"state" => "WRITING", "candidate_sha" => nil}} = RunLedger.get(ctx.store, "run")

    {:ok, blocked_run} = RunLedger.get(ctx.store, "run")
    {:ok, parent} = TicketChat.for_run(ctx.store, "run")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{snapshot_json: Jason.encode!(Process.get(:lifecycle_jira))})
    markdown = "Valid nil-candidate recovery scope\n\n## Manual Validation\n- Required: no"
    proposal_body = "Revise the contract:\n" <> markdown
    assert {:ok, proposal} = TicketChatFixture.stage(ctx, "valid-nil-amendment", proposal_body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    Process.put(:lifecycle_native, TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [proposal_body]))
    critic_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.CriticServer)}
    assert {:ok, %{launches: [], events: amendment_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(amendment_events, &(&1.event == "TICKET_AMENDMENT_APPLIED"))
    assert {:ok, %{"candidate_sha" => nil, "state" => "WRITING"}} = RunLedger.get(ctx.store, "run")
    assert {:ok, amendment} = TicketContractAmendment.get(ctx.store, proposal["command_key"])
    sealed_predecessor = Jason.decode!(amendment["predecessor_json"])

    rework_body = "Rework the current candidate."
    assert {:ok, rework} = TicketChatFixture.stage(ctx, "valid-nil-explicit-resume", rework_body, [%{"operation" => "request_rework"}])
    old_native = Process.get(:lifecycle_native)
    new_turn = TicketChatFixture.native(Map.put(ctx, :cwd, parent["cwd"]), [proposal_body, rework_body])["turns"] |> List.last()
    Process.put(:lifecycle_native, Map.update!(old_native, "turns", &(&1 ++ [new_turn])))
    assert {:ok, %{receipts: receipts}} = TicketChatCommands.admit_readback(ctx.store, "run", Process.get(:lifecycle_native))
    assert Enum.any?(receipts, &(&1["command_key"] == rework["command_key"] and &1["status"] == "ACCEPTED"))
    {:ok, held_task} = TaskLedger.get(ctx.store, writer_key)

    resume_context = %{context | ticket_options: Keyword.put(context.ticket_options, :app_server, Fixture.WorkerServer)}
    assert {:ok, %{launches: [launch]}} = Scheduler.tick(resume_context, tick_opts)
    assert launch.task_key == writer_key
    assert_receive {:factory_task_started, ^writer_key, held_thread}, 15_000
    assert held_thread == held_task["thread_id"]
    assert_receive {:factory_task_finished, ^writer_key, {:ok, _}}, 60_000

    assert {:ok, %{"status" => "APPLIED", "application_receipt_json" => resume_application}} =
             TicketChatCommands.get(ctx.store, rework["command_key"])

    resume_receipt = Jason.decode!(resume_application)
    assert resume_receipt["amendment_command_key"] == proposal["command_key"]
    assert resume_receipt["checkout_head_sha"] == sealed_predecessor["checkout_head_sha"]

    assert {:ok, %{launches: [], events: adoption_events}} = Scheduler.tick(critic_context, tick_opts)
    assert Enum.any?(adoption_events, &(&1.event == "TICKET_ADOPTED"))
    assert {:ok, %{"state" => "VERIFYING", "candidate_sha" => adopted_sha}} = RunLedger.get(ctx.store, "run")
    assert is_binary(adopted_sha) and adopted_sha != sealed_predecessor["checkout_head_sha"]
    assert adopted_sha == String.trim(git(blocked_run["worktree"], ["rev-parse", "HEAD"]))
    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key = ? AND task_key = ?", [resume_receipt["request_key"], writer_key])["status"] == "CONSUMED"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [writer_key])["count"] == 2

    {:ok, reopened} = Store.start_link(database: ctx.database)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    assert {:ok, %{launches: [verification], events: replay_events}} = Scheduler.tick(%{context | store: reopened}, tick_opts)
    assert verification.task_key == "run:change-verifier:1"
    assert Enum.any?(replay_events, &(&1.event == "TICKET_LAUNCHED"))
    refute Enum.any?(replay_events, &(&1.event == "TICKET_ADOPTED"))
    assert_receive {:factory_task_started, "run:change-verifier:1", _}, 15_000
    assert_receive {:factory_task_finished, "run:change-verifier:1", {:ok, _}}, 60_000
    refute_receive {:factory_task_started, "run:feature-writer", _}
    assert {:ok, %{"candidate_sha" => ^adopted_sha, "state" => "VERIFYING"}} = RunLedger.get(reopened, "run")
    assert Store.one!(reopened, "SELECT status FROM worker_evidence WHERE request_key = ? AND task_key = ?", [resume_receipt["request_key"], writer_key])["status"] == "CONSUMED"
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_evidence WHERE task_key = ?", [writer_key])["count"] == 2
  end

  defp controller(ctx) do
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)

    models = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"fast" => "gpt-6-luna", "deep" => "gpt-6.1-sol"}},
      "roles" =>
        Map.new(~w(feature-planner feature-writer change-verifier specification-critic orchestrator orchestrator-intake), fn role ->
          {role,
           %{
             "provider" => "codex",
             "model_class" => if(role == "change-verifier", do: "deep", else: "fast"),
             "reasoning_effort" => if(role in ["orchestrator", "orchestrator-intake"], do: "low", else: "medium")
           }}
        end)
    }

    factory = %{
      enabled: true,
      scope: "scope",
      dispatcher_id: "fixture",
      task_transport: "desktop_broker",
      controller_codex_project_id: "project-grail",
      maximum_implementation_iterations: 20,
      maximum_code_repair_rounds: 2,
      stale_task_minutes: 90,
      maximum_specifiers: 2,
      maximum_writers: 2,
      maximum_validators: 2,
      writer_disk_gb: 20,
      cleanup: %{},
      models: models,
      ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]},
      queue: %{"assignee" => "currentUser()", "statuses" => ["To Do", "In Dev"], "factory_labels" => ["ai-ready", "ai-running"]},
      manual_validation: %{"enabled" => false, "allowed_environments" => [], "require_slack_coordination" => true, "allow_production" => false, "allow_database_ddl" => false},
      repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master", "gitlab_project" => "fixture/repository", "gitlab_project_id" => "1000", "route_labels" => ["repo-grail"]}}
    }

    Control.initialize(ctx.store, factory)
    Control.record_controller_task(ctx.store, factory, "controller-thread", "original-turn", %{project_id: "project-grail"})
    {:ok, _} = Control.activate(ctx.store, factory, "fixture")
    expected_jira_workspace = Path.join([ctx.root, "workspaces", "factory-controller", "scope"])

    scope = fn cwd, callback ->
      assert cwd == expected_jira_workspace
      callback.(%{thread_id: "jira-fixture"})
    end

    parent_output_root = Path.join(ctx.root, "ticket-parents")
    File.mkdir_p!(parent_output_root)
    ticket_workflow = Path.join(ctx.root, "ticket-workflow.md")
    File.write!(ticket_workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\nFixture")

    options =
      Keyword.merge(opts(ctx),
        workspace_root: Path.join(ctx.root, "workspaces"),
        parent_output_root: parent_output_root,
        broker_thread_id: ctx[:broker_thread_id],
        ticket_cli_root: File.cwd!(),
        ticket_workflow: ticket_workflow,
        app_server: WorkerServer,
        jira_reader: JiraReader,
        jira_connector: JiraConnector,
        jira_session: scope,
        connector: MrReader,
        mcp_session: %{thread_id: "controller-thread"}
      )

    %{
      store: ctx.store,
      factory: factory,
      ticket_options: Keyword.put(options, :ticket_chat_reader, Fixture.NativeReader),
      jira_reader: JiraReader,
      jira_connector: JiraConnector,
      workspace_root: Path.join(ctx.root, "workspaces"),
      task_supervisor: start_supervised!(Task.Supervisor),
      recipient: self()
    }
  end

  defp complete_ticket_parent(ctx, context, request, run_id) do
    {:ok, chat} = TicketChat.for_run(ctx.store, run_id)
    parent_ctx = Map.merge(ctx, %{cwd: chat["cwd"], chat: chat})
    ticket_policy = context.factory.ticket_supervisor
    guard = TicketChatFixture.parent_guard(parent_ctx)
    options = [ticket_policy: ticket_policy, parent_guard: guard]
    {:ok, claimed} = DesktopRequest.claim(ctx.store, request["request_key"], options)
    {:ok, args} = DesktopToolArgs.create_thread(claimed)
    File.mkdir_p!(claimed["cwd"])

    proof = %{
      "request_key" => claimed["request_key"],
      "payload_sha256" => claimed["payload_sha256"],
      "generation" => chat["generation"],
      "thread_id" => "parent",
      "project_id" => nil,
      "cwd" => claimed["cwd"],
      "tool_arguments" => args,
      "worktree_attachments" => []
    }

    assert {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, claimed["request_key"], proof)
    output = %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}
    assert {:ok, _} = DesktopRequest.complete(ctx.store, claimed["request_key"], %{thread_id: "parent", turn_id: "parent-bootstrap", output: output})
  end

  defp complete_synthetic_broker(ctx, context, request, run, expected_delivery_review?) do
    claim_options = context.ticket_options |> Keyword.put(:workspace_root, context.workspace_root) |> Keyword.put(:jira_reader, JiraReader)
    assert {:ok, ^request, current_run, authorization} = TicketMrOperation.read_claim_authorization(ctx.store, request["request_key"], context.factory, claim_options)
    assert current_run["state"] == "MR_CREATING"

    if expected_delivery_review? do
      assert authorization["delivery_review"] == true
    else
      refute authorization["delivery_review"]
    end

    admission = %{factory: context.factory, authorization: authorization, guard: Fixture.mr_guard(request)}
    claim_options = Keyword.put(claim_options, :ticket_mr_admission, admission)
    assert {:ok, _} = DesktopRequest.claim(ctx.store, request["request_key"], claim_options)
    assert {:ok, _} = DesktopRequest.record_thread(ctx.store, request["request_key"], "controller-thread", "project-grail")

    result = %{
      "status" => "PASS",
      "mr_url" => "https://fixture.invalid/repository/-/merge_requests/1",
      "iid" => 1,
      "source_branch" => run["branch"],
      "target_branch" => run["base_branch"],
      "sha" => run["candidate_sha"],
      "draft" => true,
      "reviewers_count" => 0,
      "assignee_id" => 11_599_766,
      "state" => "opened"
    }

    output = %{"result" => result, "completed_tool_calls" => [%{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed"}]}
    assert {:ok, _} = DesktopRequest.complete(ctx.store, request["request_key"], %{thread_id: "controller-thread", turn_id: "mr-completion-" <> request["request_key"], output: output})

    mr = %{
      "project_id" => "1000",
      "iid" => "1",
      "web_url" => result["mr_url"],
      "sha" => run["candidate_sha"],
      "source_branch" => run["branch"],
      "target_branch" => run["base_branch"],
      "draft" => true,
      "state" => "opened",
      "reviewers" => [],
      "assignees" => [%{"id" => "11599766"}],
      "diff_refs" => %{"head_sha" => run["candidate_sha"]}
    }

    Process.put(:lifecycle_mr, mr)
    Process.put(:lifecycle_mr_cwd, request["cwd"])
  end
end
