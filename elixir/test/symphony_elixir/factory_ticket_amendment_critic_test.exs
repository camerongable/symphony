defmodule SymphonyElixir.FactoryTicketAmendmentCriticTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture

  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.Factory.{
    Contract,
    RunLedger,
    Store,
    TicketAmendmentCritic,
    TicketAmendmentJiraOperation,
    TicketAmendmentJiraOperation,
    TicketChatCommands,
    TicketContractAmendment
  }

  alias SymphonyElixir.Tracker.Issue

  defmodule JiraReader do
    def issue(key, opts) do
      if opts[:mcp_session] != %{thread_id: "jira-fixture"}, do: raise("missing Jira session")
      reads = Process.get(:critic_jira_reads, 0) + 1
      Process.put(:critic_jira_reads, reads)
      snapshot = Process.get(:critic_jira_snapshot)
      if snapshot["key"] != key, do: raise("wrong issue")

      if Process.get(:critic_jira_read_error_on) == reads,
        do: {:error, :test_postwrite_authorization_read_unavailable},
        else: {:ok, snapshot}
    end
  end

  defmodule JiraConnector do
    def validate_call("jira_add_comment", %{"issue_key" => "PPL-123", "body" => body}, opts) do
      if opts[:mcp_session] != %{thread_id: "jira-fixture"}, do: raise("missing Jira session")
      expected = Process.get(:critic_jira_expected_body, Process.get(:critic_draft_body))
      if body != expected, do: raise("wrong Jira comment")
      Process.get(:critic_auth_capability, :ok)
    end

    def call("jira_add_comment", %{"body" => body}, _opts) do
      Process.put(:critic_auth_writes, Process.get(:critic_auth_writes, 0) + 1)
      send(self(), {:jira_write, %{"issue_key" => "PPL-123", "body" => body}})

      case Process.get(:critic_auth_mode, :apply) do
        :lost_before_apply ->
          {:error, :timeout}

        mode when mode in [:apply, :lost_after_apply, :apply_without_updated] ->
          snapshot = Process.get(:critic_jira_snapshot)
          id = if body == Process.get(:critic_draft_body), do: "draft-comment", else: "authorization-comment"
          comment = %{"id" => id, "text" => body}
          updated = if mode == :apply_without_updated, do: nil, else: "2026-10-07T12:01:00Z"
          Process.put(:critic_jira_snapshot, snapshot |> Map.update!("comments", &(&1 ++ [comment])) |> Map.put("updated", updated))
          if mode == :lost_after_apply, do: {:error, :timeout}, else: {:ok, %{"comment_id" => id}}
      end
    end
  end

  defmodule ThrowingStageRunner do
    def run(_workspace, _issue, _prompt, _schema, _opts), do: throw(:injected_critic_exit)
  end

  defmodule CriticAppServer do
    alias SymphonyElixir.Factory.{Store, TicketContractAmendment}

    def start_session(workspace, opts) do
      send(self(), {:critic_session_started, opts})
      policy = Map.merge(AppServer.worker_policy("REVIEW", workspace), Process.get(:critic_policy_override, %{}))

      {:ok,
       %{
         thread_id: "critic-thread",
         worker_policy: policy,
         metadata: %{codex_app_server_pid: "12345"},
         worker_invocation: Process.get(:critic_nonce_override, String.duplicate("a", 64)),
         workspace: workspace
       }}
    end

    def run_turn(session, _prompt, %Issue{} = issue, opts) do
      send(self(), {:critic_issue, issue})

      if invocation = Process.get(:critic_reentrant_invocation) do
        {store, command_key, context, workspace, policy} = invocation

        send(
          self(),
          {:critic_reentrant_result,
           TicketAmendmentCritic.execute(
             store,
             command_key,
             context,
             workspace,
             policy,
             app_server: __MODULE__
           )}
        )
      end

      event_thread = Process.get(:critic_event_thread, session.thread_id)
      opts[:on_message].(%{event: :session_started, thread_id: event_thread, turn_id: "critic-turn"})
      output = Process.get(:critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []})
      item = %{"type" => "agentMessage", "id" => "critic-item", "text" => Jason.encode!(output)}
      opts[:on_message].(%{payload: %{"method" => "item/completed", "params" => %{"threadId" => session.thread_id, "turnId" => "critic-turn", "item" => item}}})

      case Process.get(:critic_reconcile_before_completion) do
        {store, command_key, context} ->
          result =
            TicketContractAmendment.reconcile_critic(
              store,
              command_key,
              context,
              :late_critic_result_expected,
              %{"callback" => "turn-output-received"}
            )

          Process.put(:critic_public_reconcile_result, result)

        _ ->
          :ok
      end

      {:ok, %{turn_id: "critic-turn"}}
    end

    def stop_session(session) do
      send(self(), :critic_session_stopped)

      stop = %{
        "transport" => "owned_app_server",
        "thread_id" => session.thread_id,
        "pid" => "12345",
        "invocation_nonce" => session.worker_invocation,
        "cwd" => session.workspace,
        "exit_status" => 0
      }

      case Process.get(:critic_delayed_result_attempt) do
        {store, command_key, context, policy} ->
          {:ok, attempt} = TicketContractAmendment.get_critic_attempt(store, command_key, policy)

          fields =
            ~w(command_key run_id task_key chat_key generation input_key input_sha256 draft_comment_id prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256 prompt_sha256 schema_sha256 snapshot_sha256 route_sha256)

          output = Process.get(:critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []})

          result = %{
            "task_key" => attempt["task_key"],
            "attempt_binding_sha256" => :crypto.hash(:sha256, Jason.encode!(Map.take(attempt, fields))) |> Base.encode16(case: :lower),
            "thread_id" => session.thread_id,
            "turn_id" => "critic-turn",
            "item_id" => "critic-item",
            "output" => output,
            "policy" => session.worker_policy,
            "owner_stop" => stop,
            "qualifies" => output["status"] == "PASS" and output["findings"] == [] and output["required_questions"] == []
          }

          attempt_before = Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key])
          task_before = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])
          record_result = TicketContractAmendment.record_critic_result(store, command_key, context, result)
          attempt_after = Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key])
          task_after = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])

          Process.put(:critic_delayed_result_capture, %{
            result: record_result,
            attempt_before: attempt_before,
            attempt_after: attempt_after,
            task_before: task_before,
            task_after: task_after
          })

        _ ->
          :ok
      end

      case Process.get(:critic_stop_result) do
        {:error, _} = error -> error
        _ -> {:ok, Map.merge(stop, Process.get(:critic_stop_override, %{}))}
      end
    end
  end

  setup test_context do
    ctx = setup_fixture(%{})
    runtime_fixture(ctx.root)
    source = normalized_source(ctx)
    source = if test_context[:same_updated], do: Map.put(source, "updated", "2026-10-07T12:01:00Z"), else: source
    Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run'", [Jason.encode!(source)])
    {:ok, _run} = RunLedger.get(ctx.store, "run")
    command = if test_context[:mixed_amendment], do: accept_mixed_proposal(ctx), else: accept_proposal(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    context = amendment_context(ctx, run)
    {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    body = Contract.draft_comment(Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"]))
    Process.put(:critic_jira_snapshot, source)
    Process.put(:critic_draft_body, body)

    jira_opts = [
      workspace: Path.join(ctx.root, "control"),
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    File.mkdir_p!(Path.join(ctx.root, "control"))
    assert {:ok, published} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, jira_opts)
    {:ok, _attempt} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, published["readback_json"], critic_policy())
    {:ok, ctx: ctx, command: command, context: context, control: Path.join(ctx.root, "control")}
  end

  test "unbound staged proposals do not fence an independently authorized amendment", %{ctx: ctx, command: command, context: context, control: control} do
    {:ok, orphan} = stage(ctx, "unbound-old-proposal", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    assert orphan["status"] == "PENDING" and is_nil(orphan["input_key"])
    {:ok, critic} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    {:ok, amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    proposed = Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"])
    output_sha = :crypto.hash(:sha256, Jason.encode!(critic["output"])) |> Base.encode16(case: :lower)
    Process.put(:critic_jira_expected_body, Contract.automatic_authorization_marker(proposed, critic["task_key"], output_sha))

    opts = [
      workspace: control,
      jira_session: fn _cwd, callback -> callback.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET status = 'ACCEPTED' WHERE command_key = ?", [orphan["command_key"]])
    assert {:error, :amendment_competing_current_work} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET status = 'PENDING' WHERE command_key = ?", [orphan["command_key"]])
    assert {:ok, _} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    assert {:ok, retained} = TicketChatCommands.get(ctx.store, orphan["command_key"])
    assert retained["status"] == "PENDING" and is_nil(retained["input_key"])
  end

  test "critic routes compare semantic fields across JSON key order", %{ctx: ctx, command: command, context: context} do
    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    reordered = Jason.encode!(%Jason.OrderedObject{values: attempt["route_json"] |> Jason.decode!() |> Enum.to_list() |> Enum.reverse()})
    digest = :crypto.hash(:sha256, reordered) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET route_json = ?, route_sha256 = ? WHERE command_key = ?", [reordered, digest, command["command_key"]])
    assert {:ok, found} = TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())
    assert found["route_json"] == reordered
    assert {:ok, claimed} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, critic_policy())
    assert claimed["route_json"] == reordered
  end

  @tag same_updated: true
  test "an exact new draft comment qualifies even when Jira timestamps share a value", %{ctx: ctx, command: command} do
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, effect} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    baseline = Jason.decode!(run["snapshot_json"])
    readback = Jason.decode!(effect["readback_json"])
    assert baseline["updated"] == readback["updated"]
    assert length(readback["comments"] -- baseline["comments"]) == 1
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])["phase"] == "PREPARED"
  end

  test "default critic entry rejects the source checkout before dispatch", %{ctx: ctx, command: command, context: context} do
    {:ok, run} = RunLedger.get(ctx.store, "run")
    File.mkdir_p!(run["repo_path"])
    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])
    before = delivery_state(ctx)

    assert {:error, :ticket_mr_controller_source_overlap} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, run["repo_path"], critic_policy())
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == attempt
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]]) == task
    assert delivery_state(ctx) == before
    refute_received {:critic_session_started, _}
  end

  test "a schema-valid BLOCK result is retained without qualifying authorization", %{ctx: ctx, command: command, context: context, control: control} do
    Process.put(:critic_output, %{"status" => "BLOCK", "findings" => [], "required_questions" => ["Clarify the acceptance boundary"]})

    assert {:ok, result} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    refute result["qualifies"]
    assert result["output"]["status"] == "BLOCK"
    assert Store.one!(ctx.store, "SELECT status FROM factory_tasks WHERE task_key = ?", [result["task_key"]])["status"] == "RESULT_RECORDED"
  end

  test "critic model drift preserves a prepared attempt and recorded results cannot be prepared again", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    prepared = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task_before = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [prepared["task_key"]])
    events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    delivery_before = delivery_state(ctx)
    changed_policy = put_in(critic_policy(), ["providers", "openai", "standard"], "replacement-model")

    assert {:error, :critic_attempt_binding_conflict} =
             TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, prepared["snapshot_json"], changed_policy)

    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == prepared
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [prepared["task_key"]]) == task_before
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before
    assert delivery_state(ctx) == delivery_before

    assert {:ok, result} = run_critic(ctx, command, context, control)
    assert_received {:critic_session_started, _}
    assert_received :critic_session_stopped
    recorded = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    recorded_task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [recorded["task_key"]])
    recorded_events = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    recorded_delivery = delivery_state(ctx)

    assert {:error, :invalid_critic_attempt} =
             TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, prepared["snapshot_json"], critic_policy())

    refute_received {:critic_session_started, _}
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == recorded
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [recorded["task_key"]]) == recorded_task
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == recorded_events
    assert delivery_state(ctx) == recorded_delivery
    assert result["thread_id"] == "critic-thread"
  end

  test "public prepared critic reads reject malformed snapshots without repairing rows", %{
    ctx: ctx,
    command: command
  } do
    original = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])

    malformed_comments =
      original["snapshot_json"]
      |> Jason.decode!()
      |> Map.put("comments", 1)
      |> Jason.encode!()

    corruptions = [{"array snapshot", "[]"}, {"comments are not a list", malformed_comments}]

    for {label, snapshot_json} <- corruptions do
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET snapshot_json = ? WHERE command_key = ?", [snapshot_json, command["command_key"]])
      before_read = critic_fixture_state(ctx, command, original["task_key"])

      assert {:error, :invalid_critic_attempt} =
               TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy()),
             label

      assert critic_fixture_state(ctx, command, original["task_key"]) == before_read, label
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET snapshot_json = ? WHERE command_key = ?", [original["snapshot_json"], command["command_key"]])
      assert {:ok, ^original} = TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy()), label
    end
  end

  test "unknown amendment APIs return exact errors without changing ticket state", %{ctx: ctx, context: context} do
    before = %{
      delivery: delivery_state(ctx),
      amendments: Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key").rows,
      effects: Store.query!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects ORDER BY command_key").rows,
      authorizations: Store.query!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects ORDER BY command_key").rows
    }

    assert {:error, :unknown_contract_amendment} = TicketContractAmendment.get(ctx.store, "missing-amendment")

    assert {:error, :unknown_contract_amendment} =
             TicketContractAmendment.apply_authorized(ctx.store, "missing-amendment", context, critic_policy())

    assert {:error, :unknown_contract_amendment} = TicketContractAmendment.blocked_source_preimage(ctx.store, "missing-amendment")

    assert %{
             delivery: delivery_state(ctx),
             amendments: Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key").rows,
             effects: Store.query!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects ORDER BY command_key").rows,
             authorizations: Store.query!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects ORDER BY command_key").rows
           } == before
  end

  test "public amendment reads reject independently corrupted reserved bindings without repairing rows", %{
    ctx: ctx,
    command: command
  } do
    original = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    prior_binding = original["prior_binding_json"] |> Jason.decode!() |> Map.put("state", "WRITING") |> Jason.encode!()

    corruptions = [
      {"array prior binding", [{"prior_binding_json", "[]"}]},
      {"missing candidate", [{"candidate_sha", nil}]},
      {"malformed supersession", [{"supersession_json", "{"}]},
      {"WRITING state without predecessor", [{"prior_binding_json", prior_binding}]},
      {"malformed predecessor in WRITING ancestry", [{"prior_binding_json", prior_binding}, {"predecessor_json", "[]"}]}
    ]

    for {label, changes} <- corruptions do
      for {field, value} <- changes do
        Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET #{field} = ? WHERE command_key = ?", [value, command["command_key"]])
      end

      before_read = critic_fixture_state(ctx, command, attempt["task_key"])

      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"]), label
      assert critic_fixture_state(ctx, command, attempt["task_key"]) == before_read, label

      for {field, _value} <- changes do
        Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET #{field} = ? WHERE command_key = ?", [original[field], command["command_key"]])
      end

      assert {:ok, ^original} = TicketContractAmendment.get(ctx.store, command["command_key"]), label
    end
  end

  test "blocked source preimage rejects an unissued amendment without mutating delivery", %{ctx: ctx, command: command} do
    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    before_read = critic_fixture_state(ctx, command, attempt["task_key"])

    assert {:error, :blocked_amendment_ancestry_invalid} = TicketContractAmendment.blocked_source_preimage(ctx.store, command["command_key"])
    assert critic_fixture_state(ctx, command, attempt["task_key"]) == before_read
  end

  test "ignored critic claim updates roll back both rows before dispatch", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task_key = attempt["task_key"]

    ignored_updates = [
      {"attempt", "CREATE TRIGGER ignore_critic_attempt_claim BEFORE UPDATE OF phase ON ticket_contract_critic_attempts WHEN NEW.phase = 'INVOKING' BEGIN SELECT RAISE(IGNORE); END"},
      {"task", "CREATE TRIGGER ignore_critic_task_claim BEFORE UPDATE OF status ON factory_tasks WHEN NEW.status = 'INVOKING' AND NEW.task_key = '#{task_key}' BEGIN SELECT RAISE(IGNORE); END"}
    ]

    for {label, trigger_sql} <- ignored_updates do
      before_claim = critic_fixture_state(ctx, command, task_key)
      Store.query!(ctx.store, trigger_sql)

      assert {:error, :critic_attempt_not_authorized} =
               TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), stage_runner: ThrowingStageRunner),
             label

      Store.query!(ctx.store, "DROP TRIGGER ignore_critic_#{if label == "attempt", do: "attempt", else: "task"}_claim")
      assert critic_fixture_state(ctx, command, task_key) == before_claim, label
      refute_received {:critic_session_started, _}
    end
  end

  test "a thrown local critic runner is reconciled without recording a result", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    attempt_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    protected_before = critic_fixture_state(ctx, command, attempt_before["task_key"])

    assert {:error, {:critic_attempt_reconcile_required, {:critic_execution_exit, :throw, ":injected_critic_exit"}}} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), stage_runner: ThrowingStageRunner)

    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt_before["task_key"]])
    protected_after = critic_fixture_state(ctx, command, attempt_before["task_key"])
    assert attempt["phase"] == "RECONCILE_REQUIRED"
    assert attempt["last_error"] =~ "critic_execution_exit"
    assert attempt["result_json"] == nil
    assert attempt["result_sha256"] == nil
    assert attempt["worker_thread_id"] == nil
    assert task["status"] == "RECONCILE_REQUIRED"
    assert Map.drop(task, ["status", "updated_at"]) == Map.drop(protected_before.task, ["status", "updated_at"])
    assert Map.drop(protected_after, [:attempt, :task, :tasks]) == Map.drop(protected_before, [:attempt, :task, :tasks])

    assert Enum.reject(protected_after.tasks, &(&1["task_key"] == attempt_before["task_key"])) ==
             Enum.reject(protected_before.tasks, &(&1["task_key"] == attempt_before["task_key"]))

    assert protected_after.authorization_effects == []
    refute_received {:critic_session_started, _}
  end

  test "a stopped non-PASS draft can be superseded by an explicit corrected native proposal", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    original_attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])

    full_state = fn store ->
      fixture = %{ctx | store: store}

      Map.merge(critic_fixture_state(fixture, command, original_attempt["task_key"]), %{
        amendments: Store.query!(store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key").rows,
        supersessions: Store.query!(store, "SELECT * FROM ticket_contract_amendment_supersessions ORDER BY predecessor_command_key").rows,
        critic_attempts: Store.query!(store, "SELECT * FROM ticket_contract_critic_attempts ORDER BY command_key").rows,
        draft_effects: Store.query!(store, "SELECT * FROM ticket_amendment_jira_effects ORDER BY command_key").rows,
        authorization_effects: Store.query!(store, "SELECT * FROM ticket_amendment_authorization_effects ORDER BY command_key").rows,
        chats: Store.query!(store, "SELECT * FROM ticket_chats ORDER BY chat_key").rows,
        links: Store.query!(store, "SELECT * FROM ticket_chat_runs ORDER BY chat_key, run_id").rows,
        commands: Store.query!(store, "SELECT * FROM ticket_chat_commands ORDER BY command_key").rows,
        inputs: Store.query!(store, "SELECT * FROM ticket_chat_inputs ORDER BY input_key").rows,
        questions: Store.query!(store, "SELECT * FROM ticket_chat_questions ORDER BY question_key").rows,
        desktop_requests: Store.query!(store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
        controller_checks: Store.query!(store, "SELECT * FROM controller_checks ORDER BY rowid").rows
      })
    end

    checkout_paths = Store.one!(ctx.store, "SELECT repo_path, worktree FROM runs WHERE run_id = 'run'")

    checkout_state = fn ->
      [checkout_paths["repo_path"], checkout_paths["worktree"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn path ->
        git_dir =
          if File.dir?(path) do
            case System.cmd("git", ["-C", path, "rev-parse", "--absolute-git-dir"], stderr_to_stdout: true) do
              {directory, 0} -> String.trim(directory)
              _ -> nil
            end
          end

        source_file = Path.join(path, "fixture.txt")
        source_bytes = if File.regular?(source_file), do: File.read!(source_file)
        index_file = if git_dir, do: Path.join(git_dir, "index")
        index_bytes = if index_file && File.regular?(index_file), do: File.read!(index_file)
        untracked_file = Path.join(path, "untracked-resume-fixture.txt")
        untracked_bytes = if File.regular?(untracked_file), do: File.read!(untracked_file)

        git_read = fn args ->
          if git_dir do
            case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
              {value, 0} -> String.trim_trailing(value)
              _ -> nil
            end
          end
        end

        git_read_raw = fn args ->
          if git_dir do
            case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
              {value, 0} -> value
              _ -> nil
            end
          end
        end

        head = git_read.(["rev-parse", "HEAD"])
        head_ref = git_read.(["symbolic-ref", "HEAD"])
        branch = git_read.(["branch", "--show-current"])
        status = git_read_raw.(["status", "--porcelain=v1"])
        staged_bytes = git_read_raw.(["show", ":fixture.txt"])

        {path,
         %{
           path_exists: File.exists?(path),
           path_is_dir: File.dir?(path),
           source_bytes: source_bytes,
           index_bytes: index_bytes,
           untracked_bytes: untracked_bytes,
           head: head,
           head_ref: head_ref,
           branch: branch,
           status: status,
           staged_bytes: staged_bytes
         }}
      end)
    end

    schema_catalog = fn store ->
      Store.query!(store, "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name").rows
    end

    initial_state = full_state.(ctx.store)
    initial_checkout = checkout_state.()
    original_input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    assert {:ok, %{"phase" => "RESERVED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    assert {:error, :u11_reserved_input_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [original_input["body"] <> " input fault", command["input_key"]])
               corrupted_state = full_state.(tx)
               assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(tx, command["command_key"])
               assert full_state.(tx) == corrupted_state
               Exqlite.rollback(tx, :u11_reserved_input_probe_rolled_back)
             end)

    assert full_state.(ctx.store) == initial_state
    assert checkout_state.() == initial_checkout
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]) == original_input
    assert {:ok, %{"phase" => "RESERVED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    Process.put(:critic_output, %{"status" => "BLOCK", "findings" => [], "required_questions" => ["Clarify the boundary"]})
    assert {:ok, _} = run_critic(ctx, command, context, control)

    {:ok, current_run} = RunLedger.get(ctx.store, "run")
    assert {:ok, correction} = TicketContractAmendment.correction_revision(ctx.store, current_run, command["command_key"])
    schema_before = schema_catalog.(ctx.store)
    full_state_before = full_state.(ctx.store)
    checkout_before = checkout_state.()
    amendment_rows_before = Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key").rows
    renamed_amendment_table = "ticket_contract_amendments_u11_unavailable_probe"
    refute Enum.any?(schema_before, fn [_type, name, _table, _sql] -> name == renamed_amendment_table end)
    {:ok, owned_schema_store} = Store.start_link(database: ctx.database)

    try do
      assert schema_catalog.(owned_schema_store) == schema_before

      assert {:error, :u11_correction_schema_rollback} =
               Exqlite.transaction(owned_schema_store, fn tx ->
                 Store.query!(tx, "ALTER TABLE ticket_contract_amendments RENAME TO #{renamed_amendment_table}")
                 fault_schema = schema_catalog.(tx)
                 fault_amendments = Store.query!(tx, "SELECT * FROM #{renamed_amendment_table} ORDER BY command_key").rows
                 fault_rows = sqlite_table_rows(tx, fault_schema)
                 fault_checkout = checkout_state.()
                 assert fault_amendments == amendment_rows_before

                 assert {:error, :amendment_correction_not_proven} =
                          TicketContractAmendment.correction_revision(tx, current_run, command["command_key"])

                 assert schema_catalog.(tx) == fault_schema
                 assert sqlite_table_rows(tx, fault_schema) == fault_rows
                 assert checkout_state.() == fault_checkout
                 assert Store.query!(tx, "SELECT * FROM #{renamed_amendment_table} ORDER BY command_key").rows == fault_amendments
                 assert Store.query!(tx, "SELECT 1 AS healthy").rows == [[1]]
                 Exqlite.rollback(tx, :u11_correction_schema_rollback)
               end)
    after
      if Process.alive?(owned_schema_store), do: GenServer.stop(owned_schema_store)
    end

    assert {:ok, readonly_schema_store} = Store.start_read_only(database: ctx.database)

    try do
      assert schema_catalog.(readonly_schema_store) == schema_before
      assert full_state.(readonly_schema_store) == full_state_before
      assert checkout_state.() == checkout_before
      assert Store.query!(readonly_schema_store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key").rows == amendment_rows_before

      assert {:ok, ^correction} =
               TicketContractAmendment.correction_revision(readonly_schema_store, current_run, command["command_key"])
    after
      GenServer.stop(readonly_schema_store)
    end

    markdown = "Corrected contract\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    first_body = "Revise the contract:\nSpec revision: 1\n\nRevised contract\n\n## Manual Validation\n- Required: no"
    {:ok, staged} = stage(ctx, "corrected-critic-proposal", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}, %{"status" => "ACCEPTED"}]}} =
             TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, body]))

    assert {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, staged["command_key"], context)
    assert amendment["proposed_revision"] == 3
    assert amendment["active_owner"] == 1

    assert {:ok, %{"phase" => "SUPERSEDED", "active_owner" => 0}} =
             TicketContractAmendment.get(ctx.store, command["command_key"])

    assert {:ok, %{"phase" => "RESERVED", "active_owner" => 1}} =
             TicketContractAmendment.get(ctx.store, staged["command_key"])

    probe_incoming_supersession = fn command_key ->
      before_probe = full_state.(ctx.store)
      checkout_before_probe = checkout_state.()
      original = Store.one!(ctx.store, "SELECT supersession_json FROM ticket_contract_amendments WHERE command_key = ?", [command_key])
      supersession = Jason.decode!(original["supersession_json"]) |> Map.put("predecessor_command_key", %{})
      corrupted = Jason.encode!(supersession)

      try do
        Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET supersession_json = ? WHERE command_key = ?", [corrupted, command_key])
        fault_state = full_state.(ctx.store)
        assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command_key)
        assert full_state.(ctx.store) == fault_state
        assert checkout_state.() == checkout_before_probe
      after
        Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET supersession_json = ? WHERE command_key = ?", [original["supersession_json"], command_key])
      end

      assert full_state.(ctx.store) == before_probe
      assert checkout_state.() == checkout_before_probe
    end

    probe_incoming_supersession.(staged["command_key"])

    assert {:ok, %{"phase" => "SUPERSEDED", "active_owner" => 0}} =
             TicketContractAmendment.get(ctx.store, command["command_key"])

    assert {:ok, %{"phase" => "RESERVED", "active_owner" => 1}} =
             TicketContractAmendment.get(ctx.store, staged["command_key"])

    before_authorization = delivery_state(ctx)

    original_input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [original_input["body"] <> " tampered", command["input_key"]])
    corrupted_input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    original_amendment = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]]) == corrupted_input
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == original_amendment
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [original_input["body"], command["input_key"]])

    original_task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", ["run:contract-amendment-critic:" <> command["command_key"]])
    original_attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    Store.query!(ctx.store, "UPDATE factory_tasks SET model = 'tampered-model' WHERE task_key = ?", [original_task["task_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    Store.query!(ctx.store, "UPDATE factory_tasks SET model = ? WHERE task_key = ?", [original_task["model"], original_task["task_key"]])

    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = '{}' WHERE task_key = ?", [original_task["task_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = ? WHERE task_key = ?", [original_task["output_json"], original_task["task_key"]])

    for {field, value} <- [
          {"owner_stop_json", "{}"},
          {"route_json", "{}"},
          {"result_json", "{}"}
        ] do
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET #{field} = ? WHERE command_key = ?", [value, command["command_key"]])
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
      assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET #{field} = ? WHERE command_key = ?", [original_attempt[field], command["command_key"]])
    end

    assert {:ok, _} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert delivery_state(ctx) == before_authorization

    assert {:ok, %{"phase" => "SUPERSEDED", "active_owner" => 0}} =
             TicketContractAmendment.get(ctx.store, command["command_key"])

    superseded_before = %{
      delivery: delivery_state(ctx),
      predecessor: Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]),
      successor: Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [staged["command_key"]]),
      link: Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]])
    }

    historical_state = fn store ->
      {critic_fixture_state(%{ctx | store: store}, command, original_attempt["task_key"]),
       Store.query!(store, "SELECT * FROM ticket_contract_amendment_supersessions ORDER BY predecessor_command_key").rows}
    end

    intact_history = historical_state.(ctx.store)
    intact_full_state = full_state.(ctx.store)
    intact_checkout_state = checkout_state.()

    for sql <- [
          "DELETE FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?",
          "UPDATE ticket_chat_commands SET application_receipt_json = '[]' WHERE command_key = ?",
          "UPDATE ticket_chat_commands SET receipt_json = NULL WHERE command_key = ?",
          "DELETE FROM ticket_contract_critic_attempts WHERE command_key = ?"
        ] do
      assert {:error, :historical_probe_complete} =
               Exqlite.transaction(ctx.store, fn tx ->
                 Store.query!(tx, sql, [command["command_key"]])
                 corrupted_history = historical_state.(tx)
                 corrupted_full_state = full_state.(tx)
                 corrupted_checkout_state = checkout_state.()
                 assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(tx, command["command_key"])
                 assert historical_state.(tx) == corrupted_history
                 assert full_state.(tx) == corrupted_full_state
                 assert checkout_state.() == corrupted_checkout_state
                 Exqlite.rollback(tx, :historical_probe_complete)
               end)

      assert historical_state.(ctx.store) == intact_history
      assert full_state.(ctx.store) == intact_full_state
      assert checkout_state.() == intact_checkout_state
      assert {:ok, %{"phase" => "SUPERSEDED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert {:ok, _} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    end

    assert {:error, :invalid_contract_amendment} =
             TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())

    assert delivery_state(ctx) == superseded_before.delivery
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == superseded_before.predecessor
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [staged["command_key"]]) == superseded_before.successor
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]]) == superseded_before.link

    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET supersession_json = '{}' WHERE command_key = ?", [staged["command_key"]])
    corrupted_successor = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [staged["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [staged["command_key"]]) == corrupted_successor
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET supersession_json = ? WHERE command_key = ?", [superseded_before.successor["supersession_json"], staged["command_key"]])

    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_json = '{}' WHERE predecessor_command_key = ?", [command["command_key"]])
    corrupted_link = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]]) == corrupted_link
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_json = ? WHERE predecessor_command_key = ?", [superseded_before.link["link_json"], command["command_key"]])
    assert delivery_state(ctx) == superseded_before.delivery
    assert {:ok, %{"phase" => "SUPERSEDED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    proposed = Contract.bind("PPL-123", 3, markdown)
    draft_body = Contract.draft_comment(proposed)
    Process.put(:critic_draft_body, draft_body)
    Process.put(:critic_jira_expected_body, draft_body)

    jira_opts = [
      workspace: control,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    assert {:ok, draft} = TicketAmendmentJiraOperation.publish_draft(ctx.store, staged["command_key"], context, jira_opts)
    assert draft["phase"] == "READ_BACK"
    assert draft["publication_preimage_json"] =~ "revision=2"
    assert delivery_state(ctx) == before_authorization

    assert {:ok, _attempt} =
             TicketContractAmendment.prepare_critic(
               ctx.store,
               staged["command_key"],
               context,
               draft["readback_json"],
               critic_policy()
             )

    Process.put(:critic_output, %{"status" => "REPAIR", "findings" => ["Clarify a requirement"], "required_questions" => []})
    assert {:ok, repair_receipt} = run_critic(ctx, staged, context, control)
    refute repair_receipt["qualifies"]

    markdown_four = "Final corrected contract\n\n## Manual Validation\n- Required: no"
    body_four = "Revise the contract:\n" <> markdown_four

    {:ok, staged_four} =
      stage(ctx, "second-corrected-critic-proposal", body_four, [%{"operation" => "propose_contract_revision", "markdown" => markdown_four}])

    assert {:ok, %{receipts: receipts}} =
             TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, body, body_four]))

    assert Enum.map(receipts, & &1["status"]) == ["REJECTED", "ACCEPTED", "ACCEPTED"]
    assert {:ok, amendment_four} = TicketContractAmendment.reserve(ctx.store, staged_four["command_key"], context)
    assert amendment_four["proposed_revision"] == 4
    assert {:ok, %{"phase" => "SUPERSEDED"}} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert {:ok, %{"phase" => "SUPERSEDED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    probe_incoming_supersession.(staged["command_key"])

    assert {:ok, %{"phase" => "SUPERSEDED", "active_owner" => 0}} =
             TicketContractAmendment.get(ctx.store, staged["command_key"])

    assert {:ok, %{"phase" => "RESERVED", "active_owner" => 1}} =
             TicketContractAmendment.get(ctx.store, staged_four["command_key"])

    assert {:ok, %{"phase" => "SUPERSEDED", "active_owner" => 0}} =
             TicketContractAmendment.get(ctx.store, command["command_key"])

    proposed_four = Contract.bind("PPL-123", 4, markdown_four)
    draft_body_four = Contract.draft_comment(proposed_four)
    Process.put(:critic_draft_body, draft_body_four)
    Process.put(:critic_jira_expected_body, draft_body_four)
    assert {:ok, draft_four} = TicketAmendmentJiraOperation.publish_draft(ctx.store, staged_four["command_key"], context, jira_opts)
    assert draft_four["publication_preimage_json"] =~ "revision=3"

    assert {:ok, _attempt} =
             TicketContractAmendment.prepare_critic(
               ctx.store,
               staged_four["command_key"],
               context,
               draft_four["readback_json"],
               critic_policy()
             )

    Process.put(:critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []})
    assert {:ok, critic_receipt} = run_critic(ctx, staged_four, context, control)
    {_authorization_body, authorization_opts} = authorization_opts(ctx, staged_four, critic_receipt, control)

    assert {:ok, _effect} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               staged_four["command_key"],
               context,
               critic_policy(),
               authorization_opts
             )

    assert_delivery_rows_preserved(ctx, before_authorization)
    assert {:ok, receipt} = TicketContractAmendment.apply_authorized(ctx.store, staged_four["command_key"], context, critic_policy())
    assert receipt["proposed_revision"] == 4
    assert {:ok, replay} = TicketContractAmendment.apply_authorized(ctx.store, staged_four["command_key"], context, critic_policy())
    assert replay == receipt
    assert {:ok, old_terminal} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    assert old_terminal["status"] == "REJECTED"
    assert {:ok, middle_terminal} = TicketChatCommands.apply_accepted(ctx.store, staged["command_key"], context)
    assert middle_terminal["status"] == "REJECTED"
    assert {:ok, %{"phase" => "SUPERSEDED"}} = TicketContractAmendment.get(ctx.store, staged["command_key"])

    link = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]])
    old_receipt = Store.one!(ctx.store, "SELECT application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])["application_receipt_json"]

    downgraded_receipt = Jason.encode!(Map.put(Jason.decode!(old_receipt), "reason", "native_intent_mismatch"))
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [downgraded_receipt, command["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_sha256 = ? WHERE predecessor_command_key = ?", [String.duplicate("0", 64), command["command_key"]])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_sha256 = ? WHERE predecessor_command_key = ?", [link["link_sha256"], command["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [old_receipt, command["command_key"]])

    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_json = '{}' WHERE predecessor_command_key = ?", [command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_json = ? WHERE predecessor_command_key = ?", [link["link_json"], command["command_key"]])

    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_sha256 = ? WHERE predecessor_command_key = ?", [String.duplicate("0", 64), command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_sha256 = ? WHERE predecessor_command_key = ?", [link["link_sha256"], command["command_key"]])

    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET successor_command_key = ? WHERE predecessor_command_key = ?", [command["command_key"], command["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET successor_command_key = ? WHERE predecessor_command_key = ?", [link["successor_command_key"], command["command_key"]])

    receipt = Jason.decode!(old_receipt)
    terminal_reference = Jason.encode!(Map.put(receipt, "supersession_link_sha256", String.duplicate("0", 64)))
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [terminal_reference, command["command_key"]])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [old_receipt, command["command_key"]])

    terminal_successor = Jason.encode!(Map.put(receipt, "successor_command_key", staged_four["command_key"]))
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [terminal_successor, command["command_key"]])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [old_receipt, command["command_key"]])

    staged_link = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [staged["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_sha256 = ? WHERE predecessor_command_key = ?", [String.duplicate("0", 64), staged["command_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, staged["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendment_supersessions SET link_sha256 = ? WHERE predecessor_command_key = ?", [staged_link["link_sha256"], staged["command_key"]])

    after_application_state = delivery_state(ctx)
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [original_input["body"] <> " tampered", command["input_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged_four["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [original_input["body"], command["input_key"]])

    Store.query!(ctx.store, "UPDATE factory_tasks SET model = 'tampered-model' WHERE task_key = ?", [original_task["task_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged_four["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE factory_tasks SET model = ? WHERE task_key = ?", [original_task["model"], original_task["task_key"]])

    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = '{}' WHERE task_key = ?", [original_task["task_key"]])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, staged_four["command_key"])
    assert {:error, :invalid_application_receipt} = TicketChatCommands.apply_accepted(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = ? WHERE task_key = ?", [original_task["output_json"], original_task["task_key"]])
    assert delivery_state(ctx) == after_application_state
  end

  test "version 35 rebuild preserves amendment receipts and all three child foreign keys", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_output, %{"status" => "BLOCK", "findings" => [], "required_questions" => ["Clarify the acceptance boundary"]})
    assert {:ok, blocked_receipt} = run_critic(ctx, command, context, control)
    refute blocked_receipt["qualifies"]

    corrected_markdown = "Corrected version-35 fixture contract\n\n## Manual Validation\n- Required: no"
    corrected_body = "Revise the contract:\n" <> corrected_markdown
    {:ok, successor} = stage(ctx, "version-35-corrected-proposal", corrected_body, [%{"operation" => "propose_contract_revision", "markdown" => corrected_markdown}])
    original_input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}, %{"status" => "ACCEPTED"}]}} =
             TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [original_input["body"], corrected_body]))

    assert {:ok, _} = TicketContractAmendment.reserve(ctx.store, successor["command_key"], context)
    assert {:ok, %{"phase" => "SUPERSEDED", "active_owner" => 0}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    successor_markdown = Contract.bind("PPL-123", 3, corrected_markdown)
    successor_draft_body = Contract.draft_comment(successor_markdown)
    Process.put(:critic_draft_body, successor_draft_body)
    Process.put(:critic_jira_expected_body, successor_draft_body)

    jira_opts = [
      workspace: control,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    assert {:ok, successor_draft} = TicketAmendmentJiraOperation.publish_draft(ctx.store, successor["command_key"], context, jira_opts)
    assert {:ok, _} = TicketContractAmendment.prepare_critic(ctx.store, successor["command_key"], context, successor_draft["readback_json"], critic_policy())
    Process.put(:critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []})
    assert {:ok, successor_critic} = run_critic(ctx, successor, context, control)
    {_body, opts} = authorization_opts(ctx, successor, successor_critic, control)

    assert {:ok, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               successor["command_key"],
               context,
               critic_policy(),
               opts
             )

    migration_command = successor
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [migration_command["command_key"]])
    superseded_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    supersession_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]])
    child_tables = ~w(ticket_contract_critic_attempts ticket_amendment_jira_effects ticket_amendment_authorization_effects)
    children_before = Map.new(child_tables, &{&1, Store.one!(ctx.store, "SELECT * FROM #{&1} WHERE command_key = ?", [migration_command["command_key"]])})
    migrate_amendments_to_v35(ctx.store)

    for table <- ["ticket_contract_amendments" | child_tables] do
      candidate = Store.query!(ctx.store, "PRAGMA table_info(#{table})").rows |> Enum.find(&(Enum.at(&1, 1) == "candidate_sha"))
      assert Enum.at(candidate, 3) == 1
    end

    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..35, &[&1])
    assert Store.one!(ctx.store, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ticket_contract_amendments'")["sql"] =~ "SUPERSEDED"
    assert Enum.any?(Store.query!(ctx.store, "PRAGMA table_info(ticket_contract_amendments)").rows, &(Enum.at(&1, 1) == "supersession_json"))

    Store.query!(ctx.store, "PRAGMA foreign_keys = OFF")
    Store.query!(ctx.store, "DELETE FROM ticket_contract_amendments WHERE command_key = ?", [migration_command["command_key"]])
    Store.query!(ctx.store, "PRAGMA foreign_keys = ON")
    orphaned_schema = Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows != []

    assert_raise RuntimeError, ~r/nullable amendment candidate migration failed foreign-key validation/, fn ->
      Store.initialize(ctx.store)
    end

    assert Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows == orphaned_schema
    assert Store.one!(ctx.store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows != []

    columns = Store.query!(ctx.store, "PRAGMA table_info(ticket_contract_amendments)").rows |> Enum.map(&Enum.at(&1, 1))
    column_sql = Enum.join(columns, ", ")
    placeholders = Enum.map_join(columns, ", ", fn _ -> "?" end)
    Store.query!(ctx.store, "INSERT INTO ticket_contract_amendments (#{column_sql}) VALUES (#{placeholders})", Enum.map(columns, &amendment_before[&1]))
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []

    amendment_tables = ["ticket_contract_amendments" | child_tables] ++ ["ticket_contract_amendment_supersessions"]
    rows_before_upgrade = amendment_table_rows(ctx.store, amendment_tables)
    indexes_before_upgrade = Store.query!(ctx.store, "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name").rows
    schema_before_read_only = Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows
    migrations_before_upgrade = Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows
    assert Store.one!(ctx.store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.one!(ctx.store, "PRAGMA legacy_alter_table")["legacy_alter_table"] == 0

    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows == schema_before_read_only
    assert amendment_table_rows(ctx.store, amendment_tables) == rows_before_upgrade
    assert Store.query!(ctx.store, "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name").rows == indexes_before_upgrade
    assert Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows == migrations_before_upgrade

    assert :ok = Store.initialize(ctx.store)
    migrated = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [migration_command["command_key"]])
    assert migrated["command_key"] == amendment_before["command_key"]
    assert migrated["supersession_json"] == amendment_before["supersession_json"]

    for table <- child_tables do
      assert Store.one!(ctx.store, "SELECT * FROM #{table} WHERE command_key = ?", [migration_command["command_key"]]) == children_before[table]
      assert Store.query!(ctx.store, "PRAGMA foreign_key_list(#{table})").rows |> Enum.any?(&(Enum.at(&1, 2) == "ticket_contract_amendments"))
    end

    for table <- ["ticket_contract_amendments" | child_tables] do
      candidate = Store.query!(ctx.store, "PRAGMA table_info(#{table})").rows |> Enum.find(&(Enum.at(&1, 1) == "candidate_sha"))
      assert Enum.at(candidate, 3) == 0
    end

    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert amendment_table_rows(ctx.store, amendment_tables) == rows_before_upgrade
    assert Store.query!(ctx.store, "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' ORDER BY name").rows == indexes_before_upgrade
    assert Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations WHERE version <= 35 ORDER BY version").rows == migrations_before_upgrade
    assert Store.one!(ctx.store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.one!(ctx.store, "PRAGMA legacy_alter_table")["legacy_alter_table"] == 0
    assert Store.one!(ctx.store, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 37
    assert Store.one!(ctx.store, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'one_active_contract_amendment_per_run'") != nil
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, migration_command["command_key"])
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == superseded_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendment_supersessions WHERE predecessor_command_key = ?", [command["command_key"]]) == supersession_before
    assert {:ok, %{"phase" => "SUPERSEDED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    GenServer.stop(reader)

    force_amendment_candidates_not_null(ctx.store)
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version = 36")
    Store.query!(ctx.store, "PRAGMA foreign_keys = OFF")
    Store.query!(ctx.store, "DELETE FROM ticket_contract_amendments WHERE command_key = ?", [migration_command["command_key"]])
    Store.query!(ctx.store, "PRAGMA foreign_keys = ON")
    invalid_schema = Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows
    invalid_rows = amendment_table_rows(ctx.store, amendment_tables)
    invalid_migrations = Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows

    assert_raise RuntimeError, ~r/nullable amendment candidate migration failed foreign-key validation/, fn ->
      Store.initialize(ctx.store)
    end

    assert Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows == invalid_schema
    assert amendment_table_rows(ctx.store, amendment_tables) == invalid_rows
    assert Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows == invalid_migrations
    assert Store.one!(ctx.store, "PRAGMA foreign_keys")["foreign_keys"] == 1
    assert Store.one!(ctx.store, "PRAGMA legacy_alter_table")["legacy_alter_table"] == 0
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows != []
  end

  test "correction admission rejects answer-only, uncertain, invoking, reconciling, and authorized predecessors", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_output, %{"status" => "BLOCK", "findings" => [], "required_questions" => ["Clarify the boundary"]})
    assert {:ok, _} = run_critic(ctx, command, context, control)

    corrected_markdown = "Corrected contract\n\n## Manual Validation\n- Required: no"
    corrected_body = "Revise the contract:\n" <> corrected_markdown
    first_body = "Revise the contract:\nSpec revision: 1\n\nRevised contract\n\n## Manual Validation\n- Required: no"
    {:ok, corrected} = stage(ctx, "fenced-correction", corrected_body, [%{"operation" => "propose_contract_revision", "markdown" => corrected_markdown}])
    {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, corrected_body]))

    effect = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])

    Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET phase = 'UNCERTAIN' WHERE command_key = ?", [command["command_key"]])
    assert {:error, _} = TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET phase = 'READ_BACK' WHERE command_key = ?", [command["command_key"]])

    for phase <- ["INVOKING", "RECONCILE_REQUIRED"] do
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET phase = ? WHERE command_key = ?", [phase, command["command_key"]])
      assert {:error, _} = TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET phase = 'RESULT_RECORDED' WHERE command_key = ?", [command["command_key"]])
    end

    result = Jason.decode!(attempt["result_json"])
    output_sha = digest(Jason.encode!(result["output"]))

    Store.query!(
      ctx.store,
      """
      INSERT INTO ticket_amendment_authorization_effects (
        command_key, run_id, chat_key, generation, input_key, input_sha256, prior_revision,
        prior_contract_sha256, candidate_sha, proposed_revision, proposed_contract_markdown,
        proposed_contract_sha256, issue_key, issue_id, critic_task_key, critic_result_sha256,
        critic_output_sha256, draft_comment_id, draft_readback_json, draft_readback_sha256,
        authorization_body, authorization_body_sha256, phase, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)
      """,
      [
        command["command_key"],
        command["run_id"],
        command["chat_key"],
        1,
        command["input_key"],
        effect["input_sha256"],
        effect["prior_revision"],
        effect["prior_contract_sha256"],
        effect["candidate_sha"],
        effect["proposed_revision"],
        effect["proposed_contract_markdown"],
        effect["proposed_contract_sha256"],
        effect["issue_key"],
        effect["issue_id"],
        attempt["task_key"],
        attempt["result_sha256"],
        output_sha,
        effect["comment_id"],
        effect["readback_json"],
        effect["readback_sha256"],
        "unused",
        digest("unused"),
        "old",
        "old"
      ]
    )

    authorization_guard_tables = ~w(ticket_chat_commands ticket_contract_amendments ticket_contract_amendment_supersessions ticket_amendment_jira_effects ticket_amendment_authorization_effects)
    before_authorization_rejection = Map.new(authorization_guard_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)

    assert {:error, :amendment_authorization_effect_exists} =
             TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)

    after_authorization_rejection = Map.new(authorization_guard_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)
    assert after_authorization_rejection == before_authorization_rejection

    for phase <- ["PENDING", "UNCERTAIN", "READ_BACK"] do
      Store.query!(ctx.store, "UPDATE ticket_amendment_authorization_effects SET phase = ? WHERE command_key = ?", [phase, command["command_key"]])
      assert {:error, _} = TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)
    end

    Store.query!(ctx.store, "DELETE FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])

    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "answer-only", "body" => "Keep this contract?", "answers" => %{"yes" => true}})
    answer_body = "yes"
    {:ok, answer_only} = stage(ctx, "answer-only-correction", answer_body, [%{"operation" => "answer_question", "question_key" => "answer-only", "value" => true}])
    {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, corrected_body, answer_body]))
    assert {:error, _} = TicketContractAmendment.reserve(ctx.store, answer_only["command_key"], context)

    second_markdown = "Competing corrected contract\n\n## Manual Validation\n- Required: no"
    second_body = "Revise the contract:\n" <> second_markdown
    {:ok, competing} = stage(ctx, "competing-correction", second_body, [%{"operation" => "propose_contract_revision", "markdown" => second_markdown}])
    {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, corrected_body, answer_body, second_body]))

    atomic_tables = [
      "ticket_chat_commands",
      "ticket_contract_amendments",
      "ticket_contract_amendment_supersessions",
      "ticket_amendment_jira_effects",
      "ticket_amendment_authorization_effects"
    ]

    before_failed_insert = Map.new(atomic_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER abort_successor_insert BEFORE INSERT ON ticket_contract_amendments WHEN NEW.command_key = '#{corrected["command_key"]}' BEGIN SELECT RAISE(ABORT, 'injected successor insert failure'); END"
    )

    assert {:error, :amendment_reservation_conflict} = TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)

    Store.query!(ctx.store, "DROP TRIGGER abort_successor_insert")
    after_failed_successor_insert = Map.new(atomic_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)
    assert after_failed_successor_insert == before_failed_insert

    Store.query!(ctx.store, "CREATE TRIGGER abort_supersession_link BEFORE INSERT ON ticket_contract_amendment_supersessions BEGIN SELECT RAISE(ABORT, 'injected successor-link failure'); END")

    assert_raise Exqlite.Error, ~r/injected successor-link failure/, fn ->
      TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)
    end

    Store.query!(ctx.store, "DROP TRIGGER abort_supersession_link")
    after_failed_insert = Map.new(atomic_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)
    assert after_failed_insert == before_failed_insert

    injected_link_corruptions = [
      {
        "predecessor binding",
        "CREATE TRIGGER corrupt_predecessor_after_link AFTER INSERT ON ticket_contract_amendment_supersessions BEGIN UPDATE ticket_contract_amendments SET prior_binding_json = '[]' WHERE command_key = NEW.predecessor_command_key; END",
        {:error, :amendment_supersession_link_invalid}
      },
      {
        "inserted link checksum",
        "CREATE TRIGGER corrupt_link_checksum_after_insert AFTER INSERT ON ticket_contract_amendment_supersessions BEGIN UPDATE ticket_contract_amendment_supersessions SET link_sha256 = '0000000000000000000000000000000000000000000000000000000000000000' WHERE predecessor_command_key = NEW.predecessor_command_key; END",
        {:error, :invalid_contract_amendment}
      }
    ]

    for {label, trigger_sql, expected_error} <- injected_link_corruptions do
      before_link_validation = %{
        tables: Map.new(atomic_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end),
        tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
        events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows,
        delivery: delivery_state(ctx)
      }

      trigger_name = if label == "predecessor binding", do: "corrupt_predecessor_after_link", else: "corrupt_link_checksum_after_insert"
      Store.query!(ctx.store, trigger_sql)
      result = TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)
      Store.query!(ctx.store, "DROP TRIGGER #{trigger_name}")

      assert result == expected_error, label

      after_link_validation = %{
        tables: Map.new(atomic_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end),
        tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
        events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows,
        delivery: delivery_state(ctx)
      }

      assert after_link_validation == before_link_validation, label
    end

    assert {:ok, _} = TicketContractAmendment.reserve(ctx.store, corrected["command_key"], context)
    tables = atomic_tables
    before = Map.new(tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)
    assert {:error, _} = TicketContractAmendment.reserve(ctx.store, competing["command_key"], context)
    after_reservation = Map.new(tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1", []).rows} end)
    assert after_reservation == before
    assert Store.one!(ctx.store, "SELECT active_owner FROM ticket_contract_amendments WHERE command_key = ?", [corrected["command_key"]])["active_owner"] == 1
  end

  test "a nonqualifying PASS cannot authorize correction supersession", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_output, %{"status" => "PASS", "findings" => ["Unresolved ambiguity"], "required_questions" => []})
    assert {:ok, receipt} = run_critic(ctx, command, context, control)
    refute receipt["qualifies"]

    markdown = "Corrected contract\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    first_body = "Revise the contract:\nSpec revision: 1\n\nRevised contract\n\n## Manual Validation\n- Required: no"
    {:ok, correction} = stage(ctx, "nonqualifying-pass-correction", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, body]))

    before = Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key", []).rows
    assert {:error, _} = TicketContractAmendment.reserve(ctx.store, correction["command_key"], context)
    assert Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments ORDER BY command_key", []).rows == before
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_commands WHERE command_key = ?", [correction["command_key"]])["status"] == "ACCEPTED"
  end

  test "a PASS with findings is retained but never qualifies", %{ctx: ctx, command: command, context: context, control: control} do
    Process.put(:critic_output, %{"status" => "PASS", "findings" => ["Unresolved ambiguity"], "required_questions" => []})

    assert {:ok, result} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    refute result["qualifies"]
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])["phase"] == "RESULT_RECORDED"
  end

  test "an owner-stop PID mismatch is retained as reconciliation evidence", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_stop_override, %{"pid" => "54321"})

    assert_owner_stop_mismatch(ctx, command, context, control)

    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    assert attempt["phase"] == "RECONCILE_REQUIRED"
    assert Jason.decode!(attempt["last_observation_json"])["thread_id"] == "critic-thread"
  end

  test "an owner-stop nonce mismatch is retained as reconciliation evidence", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_stop_override, %{"invocation_nonce" => String.duplicate("b", 64)})

    assert_owner_stop_mismatch(ctx, command, context, control)
  end

  test "an owner-stop cwd mismatch is retained as reconciliation evidence", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_stop_override, %{"cwd" => ctx.root})

    assert_owner_stop_mismatch(ctx, command, context, control)
  end

  test "a mismatched REVIEW policy cannot reach the turn", %{ctx: ctx, command: command, context: context, control: control} do
    Process.put(:critic_policy_override, %{"network" => true})

    assert {:error, {:critic_attempt_reconcile_required, {:critic_execution_failed, _}}} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    assert_received :critic_session_stopped
    refute_received {:critic_issue, _}
  end

  test "recorded critic result rejects nil and self-loop owner cwd without mutation", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, _result} = run_critic(ctx, command, context, control)
    original = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task_before = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [original["task_key"]])
    events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    delivery_before = delivery_state(ctx)
    self_link = Path.join(ctx.root, "critic-owner-self-link")
    assert :ok = File.ln_s(self_link, self_link)

    for invalid_cwd <- [nil, self_link] do
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET owner_cwd = ? WHERE command_key = ?", [invalid_cwd, command["command_key"]])
      tampered_attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])

      assert {:error, :invalid_critic_attempt} =
               TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())

      assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == tampered_attempt
      assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [original["task_key"]]) == task_before
      assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before
      assert delivery_state(ctx) == delivery_before
      Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET owner_cwd = ? WHERE command_key = ?", [original["owner_cwd"], command["command_key"]])
      assert {:ok, ^original} = TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())
    end
  end

  test "missing prepared attempt cannot register a replacement task or critic session", %{
    ctx: ctx,
    command: command,
    context: context
  } do
    prepared = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task_before = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [prepared["task_key"]])
    events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    delivery_before = delivery_state(ctx)
    Store.query!(ctx.store, "DELETE FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [prepared["task_key"]]) == task_before

    {:ok, run} = RunLedger.get(ctx.store, "run")
    assert {:error, :amendment_correction_not_proven} = TicketContractAmendment.correction_revision(ctx.store, run, command["command_key"])

    assert {:error, {:task_register_failed, %Exqlite.Error{}}} =
             TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, prepared["snapshot_json"], critic_policy())

    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == nil
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [prepared["task_key"]]) == task_before
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before
    assert delivery_state(ctx) == delivery_before
    refute_received {:critic_session_started, _}
    refute_received {:critic_issue, _}
  end

  test "a malformed public session receipt is rejected without changing the claimed attempt", %{
    ctx: ctx,
    command: command,
    context: context
  } do
    assert {:ok, _claimed} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, critic_policy())
    attempt_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task_before = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt_before["task_key"]])
    events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows

    assert {:error, :critic_session_evidence_invalid} =
             TicketContractAmendment.record_critic_session(ctx.store, command["command_key"], context, %{})

    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == attempt_before
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt_before["task_key"]]) == task_before
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before
  end

  test "public critic reconciliation replays its default observation once and rejects stale controller context", %{
    ctx: ctx,
    command: command,
    context: context
  } do
    assert {:ok, %{"phase" => "INVOKING"}} =
             TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, critic_policy())

    assert {:ok, reconciled} =
             TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], context, :owner_stop_missing)

    assert reconciled["phase"] == "RECONCILE_REQUIRED"
    assert reconciled["last_observation_json"] == "{}"
    attempt_after_reconcile = reconciled
    task_after_reconcile = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [reconciled["task_key"]])
    events_after_reconcile = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    delivery_after_reconcile = delivery_state(ctx)

    assert {:ok, ^attempt_after_reconcile} =
             TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], context, :owner_stop_missing)

    stale_context = put_in(context, ["binding", "generation"], context["binding"]["generation"] + 1)

    assert {:error, :stale_controller_context} =
             TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], stale_context, :owner_stop_missing)

    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == attempt_after_reconcile
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [reconciled["task_key"]]) == task_after_reconcile
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_after_reconcile
    assert delivery_state(ctx) == delivery_after_reconcile
    refute_received {:critic_session_started, _}

    before_rejected_claim = critic_fixture_state(ctx, command, reconciled["task_key"])
    assert {:error, :invalid_critic_attempt} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, critic_policy())
    assert critic_fixture_state(ctx, command, reconciled["task_key"]) == before_rejected_claim
  end

  test "a genuine completed result cannot overwrite a prior public reconciliation", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_reconcile_before_completion, {ctx.store, command["command_key"], context})
    Process.put(:critic_delayed_result_attempt, {ctx.store, command["command_key"], context, critic_policy()})

    expected_error =
      {:error,
       {
         :critic_attempt_unproven,
         {:critic_result_receipt_rejected, :critic_result_not_adoptable},
         :critic_reconciliation_conflict
       }}

    assert run_critic(ctx, command, context, control) == expected_error

    assert {:ok, %{"phase" => "RECONCILE_REQUIRED"} = reconciled} = Process.get(:critic_public_reconcile_result)
    assert Process.get(:critic_delayed_result_capture).result == {:error, :critic_result_not_adoptable}

    capture = Process.get(:critic_delayed_result_capture)
    assert capture.attempt_after == capture.attempt_before
    assert capture.task_after == capture.task_before
    assert reconciled["result_json"] == nil
    assert reconciled["worker_item_id"] == nil
    assert reconciled["owner_stop_json"] == nil
    assert Store.one!(ctx.store, "SELECT status FROM factory_tasks WHERE task_key = ?", [reconciled["task_key"]])["status"] == "RECONCILE_REQUIRED"
    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]) == nil
    assert_received :critic_session_stopped
  end

  test "a critic owner cwd outside the canonical control workspace is stopped and durably reconciled", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_policy_override, AppServer.worker_policy("REVIEW", ctx.root))
    before = delivery_state(ctx)

    assert {:error, {:critic_attempt_reconcile_required, {:critic_execution_failed, _}}} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])
    assert attempt["phase"] == "RECONCILE_REQUIRED"
    assert attempt["worker_thread_id"] == nil
    assert task["status"] == "RECONCILE_REQUIRED"
    assert_received {:critic_session_started, _}
    assert_received :critic_session_stopped
    refute_received {:critic_issue, _}
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])["count"] == 0
    after_failure = delivery_state(ctx)
    assert after_failure.run == before.run
    assert after_failure.evidence == before.evidence
  end

  test "parent-thread callback stops and durably reconciles the claimed attempt", %{ctx: ctx, command: command, context: context, control: control} do
    parent_thread = Store.one!(ctx.store, "SELECT thread_id FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])["thread_id"]
    Process.put(:critic_event_thread, parent_thread)

    assert {:error, {:critic_attempt_reconcile_required, reason = {:critic_execution_failed, _}}} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])
    events = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    assert attempt["phase"] == "RECONCILE_REQUIRED"
    assert attempt["worker_thread_id"] == "critic-thread"
    assert attempt["worker_turn_id"] == nil
    assert attempt["last_error"] =~ "critic_execution_failed"
    assert attempt["last_error"] =~ "critic parent thread rejected"
    assert_received {:critic_session_started, _}
    assert {:ok, attempt} == TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], context, reason, %{})

    assert {:error, :critic_reconciliation_conflict} =
             TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], context, reason, %{"thread_id" => "critic-thread"})

    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == attempt
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]]) == task
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events

    assert {:error, :critic_attempt_reconcile_required} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    refute_received {:critic_session_started, _}
    assert_received :critic_session_stopped
  end

  test "foreign-thread callback stops and durably reconciles the claimed attempt", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    Process.put(:critic_event_thread, "foreign-thread")

    assert {:error, {:critic_attempt_reconcile_required, {:critic_execution_failed, _}}} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    assert attempt["phase"] == "RECONCILE_REQUIRED"
    assert attempt["worker_thread_id"] == "critic-thread"
    assert attempt["worker_turn_id"] == nil
    assert attempt["last_error"] =~ "critic_execution_failed"
    assert_received :critic_session_stopped
  end

  test "version 31 migration preserves a populated prepared attempt", %{ctx: ctx, command: command} do
    before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    Store.query!(ctx.store, "DROP TABLE ticket_contract_critic_attempts")

    Store.query!(ctx.store, """
    CREATE TABLE ticket_contract_critic_attempts (
      command_key TEXT PRIMARY KEY REFERENCES ticket_contract_amendments(command_key), run_id TEXT NOT NULL REFERENCES runs(run_id),
      task_key TEXT NOT NULL UNIQUE REFERENCES factory_tasks(task_key), chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      generation INTEGER NOT NULL, input_key TEXT NOT NULL REFERENCES ticket_chat_inputs(input_key), input_sha256 TEXT NOT NULL,
      draft_comment_id TEXT NOT NULL, prior_revision INTEGER NOT NULL, prior_contract_sha256 TEXT NOT NULL, candidate_sha TEXT NOT NULL,
      proposed_revision INTEGER NOT NULL, proposed_contract_sha256 TEXT NOT NULL, prompt TEXT NOT NULL, prompt_sha256 TEXT NOT NULL,
      schema_json TEXT NOT NULL, schema_sha256 TEXT NOT NULL, snapshot_json TEXT NOT NULL, snapshot_sha256 TEXT NOT NULL,
      route_json TEXT NOT NULL, route_sha256 TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('PREPARED', 'INVOKING')),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    legacy_fields =
      ~w(command_key run_id task_key chat_key generation input_key input_sha256 draft_comment_id prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256 prompt prompt_sha256 schema_json schema_sha256 snapshot_json snapshot_sha256 route_json route_sha256 phase created_at updated_at)

    placeholders = Enum.map_join(legacy_fields, ", ", fn _ -> "?" end)
    Store.query!(ctx.store, "INSERT INTO ticket_contract_critic_attempts(#{Enum.join(legacy_fields, ", ")}) VALUES (#{placeholders})", Enum.map(legacy_fields, &before[&1]))

    assert :ok = Store.initialize(ctx.store)
    after_migration = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    assert Map.take(after_migration, legacy_fields) == Map.take(before, legacy_fields)
    assert after_migration["worker_thread_id"] == nil
    assert after_migration["result_json"] == nil
    assert Store.one!(ctx.store, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 37
  end

  test "a PASS receipt cannot be adopted before the exact turn callback is persisted", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, attempt} =
             TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, critic_policy())

    policy = AppServer.worker_policy("REVIEW", control)
    nonce = String.duplicate("a", 64)

    assert :ok =
             TicketContractAmendment.record_critic_session(ctx.store, command["command_key"], context, %{
               "thread_id" => "critic-thread",
               "worker_policy_json" => Jason.encode!(policy),
               "owner_pid" => "12345",
               "invocation_nonce" => nonce,
               "owner_cwd" => control
             })

    receipt = %{
      "task_key" => attempt["task_key"],
      "attempt_binding_sha256" => attempt_binding_sha256(attempt),
      "thread_id" => "critic-thread",
      "turn_id" => nil,
      "item_id" => "critic-item",
      "output" => %{"status" => "PASS", "findings" => [], "required_questions" => []},
      "policy" => policy,
      "owner_stop" => %{
        "transport" => "owned_app_server",
        "thread_id" => "critic-thread",
        "pid" => "12345",
        "invocation_nonce" => nonce,
        "cwd" => control,
        "exit_status" => 0
      },
      "qualifies" => true
    }

    assert {:error, :critic_result_binding_mismatch} =
             TicketContractAmendment.record_critic_result(ctx.store, command["command_key"], context, receipt)

    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])["phase"] == "INVOKING"
  end

  test "a self-checksummed result cannot authorize a tampered network-enabled REVIEW policy", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, _receipt} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    attempt = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    policy = attempt["worker_policy_json"] |> Jason.decode!() |> Map.put("network", true)
    result = attempt["result_json"] |> Jason.decode!() |> Map.put("policy", policy)
    raw_result = Jason.encode!(result)
    result_sha = :crypto.hash(:sha256, raw_result) |> Base.encode16(case: :lower)

    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET worker_policy_json = ?, result_json = ?, result_sha256 = ? WHERE command_key = ?", [
      Jason.encode!(policy),
      raw_result,
      result_sha,
      command["command_key"]
    ])

    assert {:error, :invalid_critic_attempt} =
             TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())
  end

  test "recorded result replay rejects child-task thread and turn drift", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, _receipt} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    task_key = Store.one!(ctx.store, "SELECT task_key FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])["task_key"]
    task = Store.one!(ctx.store, "SELECT thread_id, turn_id FROM factory_tasks WHERE task_key = ?", [task_key])

    Store.query!(ctx.store, "UPDATE factory_tasks SET thread_id = 'foreign-thread' WHERE task_key = ?", [task_key])

    assert {:error, :invalid_critic_attempt} =
             TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())

    Store.query!(ctx.store, "UPDATE factory_tasks SET thread_id = ?, turn_id = 'foreign-turn' WHERE task_key = ?", [task["thread_id"], task_key])

    assert {:error, :invalid_critic_attempt} =
             TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())
  end

  test "runs one owned exact-turn critic and replays its persisted receipt without relaunch", %{ctx: ctx, command: command, context: context, control: control} do
    Process.put(:critic_reentrant_invocation, {ctx.store, command["command_key"], context, control, critic_policy()})
    assert {:ok, result} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    Process.delete(:critic_reentrant_invocation)
    assert_received {:critic_reentrant_result, {:error, :critic_attempt_pending_unproven}}
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])["phase"] == "RESULT_RECORDED"
    assert result["thread_id"] == "critic-thread"
    assert result["turn_id"] == "critic-turn"
    assert result["item_id"] == "critic-item"
    assert result["qualifies"]
    assert result["owner_stop"]["transport"] == "owned_app_server"
    assert_received {:critic_session_started, session_opts}
    assert session_opts[:ephemeral]
    assert session_opts[:worker_access] == "REVIEW"
    assert session_opts[:model] == "critic-model-v1"
    assert_received {:critic_issue, %Issue{identifier: "PPL-123", title: "Existing summary", description: "Existing description"}}
    assert_received :critic_session_stopped

    assert {:ok, stored} = TicketContractAmendment.get_critic_attempt(ctx.store, command["command_key"], critic_policy())
    assert {:ok, replayed} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    assert replayed == result
    assert Jason.encode!(replayed) == stored["result_json"]

    attempt_before_replay = Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    task_before_replay = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [stored["task_key"]])
    events_before_replay = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows

    session_identity = %{
      "thread_id" => attempt_before_replay["worker_thread_id"],
      "worker_policy_json" => attempt_before_replay["worker_policy_json"],
      "owner_pid" => attempt_before_replay["owner_pid"],
      "invocation_nonce" => attempt_before_replay["invocation_nonce"],
      "owner_cwd" => attempt_before_replay["owner_cwd"]
    }

    assert :ok = TicketContractAmendment.record_critic_session(ctx.store, command["command_key"], context, session_identity)
    assert :ok = TicketContractAmendment.record_critic_turn(ctx.store, command["command_key"], context, result["thread_id"], result["turn_id"])
    assert {:ok, ^attempt_before_replay} = TicketContractAmendment.record_critic_result(ctx.store, command["command_key"], context, result)

    assert {:error, :critic_session_identity_conflict} =
             TicketContractAmendment.record_critic_session(
               ctx.store,
               command["command_key"],
               context,
               Map.put(session_identity, "owner_pid", "54321")
             )

    assert {:error, :critic_turn_identity_conflict} =
             TicketContractAmendment.record_critic_turn(ctx.store, command["command_key"], context, result["thread_id"], "different-turn")

    changed_output = Map.put(result["output"], "findings", ["changed result"])
    changed_result = result |> Map.put("output", changed_output) |> Map.put("qualifies", false)
    assert {:error, :critic_result_conflict} = TicketContractAmendment.record_critic_result(ctx.store, command["command_key"], context, changed_result)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == attempt_before_replay
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [stored["task_key"]]) == task_before_replay
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before_replay

    assert {:error, :critic_result_already_recorded} =
             TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], context, :discard_recorded_result, %{})

    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]) == attempt_before_replay
    assert Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [stored["task_key"]]) == task_before_replay
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before_replay

    conflicting = Map.put(replayed, "item_id", "forged-item")
    conflicting_json = Jason.encode!(conflicting)
    conflicting_sha = :crypto.hash(:sha256, conflicting_json) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET result_json = ?, result_sha256 = ? WHERE command_key = ?", [conflicting_json, conflicting_sha, command["command_key"]])
    assert {:error, :invalid_critic_attempt} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET result_json = ?, result_sha256 = ? WHERE command_key = ?", [
      stored["result_json"],
      stored["result_sha256"],
      command["command_key"]
    ])

    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET result_sha256 = ? WHERE command_key = ?", [String.duplicate("0", 64), command["command_key"]])
    assert {:error, :invalid_critic_attempt} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    refute_received {:critic_session_started, _}
  end

  test "publishes and reads back automatic authorization from the persisted critic result", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} =
             TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)

    assert {:ok, draft_before} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])

    protected_before = %{
      run: Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'"),
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      leases: Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows
    }

    output_sha256 = :crypto.hash(:sha256, Jason.encode!(critic_receipt["output"])) |> Base.encode16(case: :lower)
    proposed = Contract.bind("PPL-123", 2, "Spec revision: 2\n\nRevised contract\n\n## Manual Validation\n- Required: no")
    body = Contract.automatic_authorization_marker(proposed, critic_receipt["task_key"], output_sha256)
    Process.put(:critic_jira_expected_body, body)

    jira_opts = [
      workspace: control,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "authorization-comment"} = effect} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               jira_opts
             )

    assert effect["authorization_body"] == body
    assert effect["critic_task_key"] == critic_receipt["task_key"]
    assert effect["critic_output_sha256"] == output_sha256

    assert {:ok, readback} =
             TicketAmendmentJiraOperation.readback_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy()
             )

    assert readback["readback_json"] == effect["readback_json"]
    snapshot = Jason.decode!(readback["readback_json"])
    assert {:ok, authorized} = Contract.authorized_from_snapshot(snapshot, "PPL-123")
    assert authorized == proposed
    assert {:ok, proof} = Contract.automatic_authorization_proof(snapshot, proposed)
    assert proof == %{critic_task_key: critic_receipt["task_key"], critic_output_sha256: output_sha256}
    assert {:ok, draft} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    assert draft["readback_json"] == draft_before["readback_json"]
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == protected_before.run
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == protected_before.tasks
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows == protected_before.leases
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}
  end

  test "ignored draft claim keeps a PENDING intent without writing a comment", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    next = prepare_next_amendment(ctx, command, context, control)
    key = next.command["command_key"]
    before = critic_fixture_state(ctx, next.command, nil)
    source_before = Process.get(:critic_jira_snapshot)
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_writes, 0)

    Store.query!(ctx.store, """
    CREATE TRIGGER u11_ignore_draft_claim
    BEFORE UPDATE OF phase ON ticket_amendment_jira_effects
    WHEN OLD.command_key = '#{key}' AND OLD.phase = 'PENDING' AND NEW.phase = 'UNCERTAIN'
    BEGIN SELECT RAISE(IGNORE); END
    """)

    try do
      assert {:error, :amendment_jira_outcome_uncertain} =
               TicketAmendmentJiraOperation.publish_draft(ctx.store, key, next.context, next.jira_opts)
    after
      Store.query!(ctx.store, "DROP TRIGGER u11_ignore_draft_claim")
    end

    effect = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [key])
    assert effect["phase"] == "PENDING"
    assert effect["claimed_at"] == nil and effect["readback_json"] == nil and effect["comment_id"] == nil
    assert {:error, :amendment_jira_readback_not_recorded} = TicketAmendmentJiraOperation.readback(ctx.store, key)
    after_fault = critic_fixture_state(ctx, next.command, nil)
    assert Map.drop(after_fault, [:jira_effects]) == Map.drop(before, [:jira_effects])
    assert length(after_fault.jira_effects) == 1
    assert query_rows_as_maps(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [key]) == [effect]
    assert Process.get(:critic_jira_snapshot) == source_before
    assert Process.get(:critic_jira_reads) == reads_before + 1
    assert Process.get(:critic_auth_writes) == 0
    refute_received {:jira_write, _}

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "draft-comment"}} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, key, next.context, next.jira_opts)

    assert Process.get(:critic_auth_writes) == 1
    assert length(Enum.filter(Process.get(:critic_jira_snapshot)["comments"], &(&1["text"] == next.draft_body))) == 1
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => body}}
    assert body == next.draft_body
  end

  test "ignored authorization claim keeps a PENDING intent without publishing", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert_received {:jira_write, %{"body" => draft_body}}
    assert draft_body == Process.get(:critic_draft_body)
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    before = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    source_before = Process.get(:critic_jira_snapshot)
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_writes, 0)
    key = command["command_key"]

    Store.query!(ctx.store, """
    CREATE TRIGGER u11_ignore_authorization_claim
    BEFORE UPDATE OF phase ON ticket_amendment_authorization_effects
    WHEN OLD.command_key = '#{key}' AND OLD.phase = 'PENDING' AND NEW.phase = 'UNCERTAIN'
    BEGIN SELECT RAISE(IGNORE); END
    """)

    try do
      assert {:error, :amendment_authorization_outcome_uncertain} =
               TicketAmendmentJiraOperation.publish_authorization(ctx.store, key, context, critic_policy(), opts)
    after
      Store.query!(ctx.store, "DROP TRIGGER u11_ignore_authorization_claim")
    end

    effect = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [key])
    assert effect["phase"] == "PENDING"
    assert effect["claimed_at"] == nil and effect["observed_json"] == nil and effect["readback_json"] == nil

    assert {:error, :amendment_authorization_readback_not_recorded} =
             TicketAmendmentJiraOperation.readback_authorization(ctx.store, key, context, critic_policy())

    after_fault = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    assert Map.drop(after_fault, [:authorization_effects]) == Map.drop(before, [:authorization_effects])
    assert query_rows_as_maps(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [key]) == [effect]
    assert Process.get(:critic_jira_snapshot) == source_before
    assert Process.get(:critic_jira_reads) == reads_before + 1
    assert Process.get(:critic_auth_writes) == 0
    refute_received {:jira_write, %{"body" => ^body}}

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "authorization-comment"}} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, key, context, critic_policy(), opts)

    assert Process.get(:critic_auth_writes) == 1
    assert length(Enum.filter(Process.get(:critic_jira_snapshot)["comments"], &(&1["text"] == body))) == 1
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}
  end

  test "ignored draft readback remains UNCERTAIN and retries without another write", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    next = prepare_next_amendment(ctx, command, context, control)
    key = next.command["command_key"]
    before = critic_fixture_state(ctx, next.command, nil)
    protected_before = protected_delivery_rows(ctx)
    delivery_before = delivery_state(ctx)
    source_before = Process.get(:critic_jira_snapshot)
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_writes, 0)

    Store.query!(ctx.store, """
    CREATE TRIGGER u11_ignore_draft_readback
    BEFORE UPDATE OF phase ON ticket_amendment_jira_effects
    WHEN OLD.command_key = '#{key}' AND NEW.phase = 'READ_BACK'
    BEGIN SELECT RAISE(IGNORE); END
    """)

    try do
      assert {:error, :amendment_jira_effect_changed} =
               TicketAmendmentJiraOperation.publish_draft(ctx.store, key, next.context, next.jira_opts)
    after
      Store.query!(ctx.store, "DROP TRIGGER u11_ignore_draft_readback")
    end

    effect = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [key])
    assert effect["phase"] == "UNCERTAIN"
    assert is_binary(effect["claimed_at"])
    assert effect["readback_json"] == nil and effect["readback_sha256"] == nil and effect["comment_id"] == nil
    assert {:error, :amendment_jira_readback_not_recorded} = TicketAmendmentJiraOperation.readback(ctx.store, key)
    after_fault = critic_fixture_state(ctx, next.command, nil)
    assert Map.drop(after_fault, [:jira_effects]) == Map.drop(before, [:jira_effects])
    assert query_rows_as_maps(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [key]) == [effect]
    assert protected_delivery_rows(ctx) == protected_before
    assert delivery_state(ctx) == delivery_before
    source_after = Process.get(:critic_jira_snapshot)
    assert Enum.filter(source_after["comments"], &(&1["text"] == next.draft_body)) == [%{"id" => "draft-comment", "text" => next.draft_body}]
    assert Map.drop(source_after, ["comments", "updated"]) == Map.drop(source_before, ["comments", "updated"])
    assert Process.get(:critic_jira_reads) == reads_before + 2
    assert Process.get(:critic_auth_writes) == 1
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => body}}
    assert body == next.draft_body

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "draft-comment"}} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, key, next.context, next.jira_opts)

    assert Process.get(:critic_auth_writes) == 1
    assert Process.get(:critic_jira_reads) == reads_before + 3
    assert length(Enum.filter(Process.get(:critic_jira_snapshot)["comments"], &(&1["text"] == next.draft_body))) == 1
    refute_received {:jira_write, _}
  end

  test "ignored authorization readback remains UNCERTAIN and retries without another write", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert_received {:jira_write, %{"body" => draft_body}}
    assert draft_body == Process.get(:critic_draft_body)
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    before = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    protected_before = protected_delivery_rows(ctx)
    delivery_before = delivery_state(ctx)
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_writes, 0)
    key = command["command_key"]

    Store.query!(ctx.store, """
    CREATE TRIGGER u11_ignore_authorization_readback
    BEFORE UPDATE OF phase ON ticket_amendment_authorization_effects
    WHEN OLD.command_key = '#{key}' AND NEW.phase = 'READ_BACK'
    BEGIN SELECT RAISE(IGNORE); END
    """)

    try do
      assert {:error, :amendment_authorization_outcome_uncertain} =
               TicketAmendmentJiraOperation.publish_authorization(ctx.store, key, context, critic_policy(), opts)
    after
      Store.query!(ctx.store, "DROP TRIGGER u11_ignore_authorization_readback")
    end

    effect = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [key])
    assert effect["phase"] == "UNCERTAIN"
    assert is_binary(effect["claimed_at"])
    assert effect["readback_json"] == nil and effect["readback_sha256"] == nil and effect["comment_id"] == nil

    assert {:error, :amendment_authorization_readback_not_recorded} =
             TicketAmendmentJiraOperation.readback_authorization(ctx.store, key, context, critic_policy())

    after_fault = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    assert Map.drop(after_fault, [:authorization_effects]) == Map.drop(before, [:authorization_effects])
    assert query_rows_as_maps(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [key]) == [effect]
    assert protected_delivery_rows(ctx) == protected_before
    assert delivery_state(ctx) == delivery_before
    observed = Jason.decode!(effect["observed_json"])
    assert Enum.filter(observed["comments"], &(&1["text"] == body)) == [%{"id" => "authorization-comment", "text" => body}]
    assert Process.get(:critic_jira_reads) == reads_before + 2
    assert Process.get(:critic_auth_writes) == 1
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "authorization-comment"}} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, key, context, critic_policy(), opts)

    assert Process.get(:critic_auth_writes) == 1
    assert Process.get(:critic_jira_reads) == reads_before + 3
    assert length(Enum.filter(Process.get(:critic_jira_snapshot)["comments"], &(&1["text"] == body))) == 1
    refute_received {:jira_write, _}
  end

  test "authorization readback reports a missing effect without creating one", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert_received {:jira_write, %{"body" => draft_body}}
    assert draft_body == Process.get(:critic_draft_body)
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    before = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    source_before = Process.get(:critic_jira_snapshot)
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_writes, 0)

    assert {:error, :amendment_authorization_effect_missing} =
             TicketAmendmentJiraOperation.readback_authorization(ctx.store, command["command_key"], context, critic_policy())

    assert critic_fixture_state(ctx, command, critic_receipt["task_key"]) == before
    assert Process.get(:critic_jira_snapshot) == source_before
    assert Process.get(:critic_jira_reads) == reads_before
    assert Process.get(:critic_auth_writes) == 0
    refute_received {:jira_write, _}

    {body, opts} = authorization_opts(ctx, command, critic_receipt, control)

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "authorization-comment"}} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    assert {:ok, %{"phase" => "READ_BACK"}} =
             TicketAmendmentJiraOperation.readback_authorization(ctx.store, command["command_key"], context, critic_policy())

    assert Process.get(:critic_auth_writes) == 1
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}
  end

  test "authorization write with missing update timestamp stays UNCERTAIN until readback recovers", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert_received {:jira_write, %{"body" => draft_body}}
    assert draft_body == Process.get(:critic_draft_body)
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    source_before = Process.get(:critic_jira_snapshot)
    protected_before = protected_delivery_rows(ctx)
    delivery_before = delivery_state(ctx)
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_mode, :apply_without_updated)
    Process.put(:critic_auth_writes, 0)

    assert {:error, :amendment_authorization_outcome_uncertain} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    uncertain = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])
    assert uncertain["phase"] == "UNCERTAIN"
    assert uncertain["readback_json"] == nil and uncertain["readback_sha256"] == nil and uncertain["comment_id"] == nil
    observed = Jason.decode!(uncertain["observed_json"])
    assert observed["updated"] == nil
    assert Enum.filter(observed["comments"], &(&1["text"] == body)) == [%{"id" => "authorization-comment", "text" => body}]
    source_after_write = Process.get(:critic_jira_snapshot)
    assert source_after_write["updated"] == nil
    assert Enum.filter(source_after_write["comments"], &(&1["text"] == body)) == [%{"id" => "authorization-comment", "text" => body}]
    assert Map.drop(source_after_write, ["comments", "updated"]) == Map.drop(source_before, ["comments", "updated"])
    assert protected_delivery_rows(ctx) == protected_before
    assert delivery_state(ctx) == delivery_before
    assert Process.get(:critic_jira_reads) == reads_before + 2
    assert Process.get(:critic_auth_writes) == 1
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}

    Process.put(:critic_jira_snapshot, Map.put(source_after_write, "updated", source_before["updated"]))

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "authorization-comment"}} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    assert Process.get(:critic_jira_snapshot)["updated"] == source_before["updated"]
    assert Process.get(:critic_jira_reads) == reads_before + 3
    assert Process.get(:critic_auth_writes) == 1
    assert length(Enum.filter(Process.get(:critic_jira_snapshot)["comments"], &(&1["text"] == body))) == 1
    assert protected_delivery_rows(ctx) == protected_before
    assert delivery_state(ctx) == delivery_before
    refute_received {:jira_write, _}
  end

  test "lost authorization acknowledgement is reconciled by reads only and survives ledger reopen", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    Process.put(:critic_auth_mode, :lost_after_apply)
    Process.put(:critic_auth_writes, 0)

    assert {:ok, %{"phase" => "READ_BACK"} = effect} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Process.get(:critic_auth_writes) == 1
    assert {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, replayed} =
               TicketAmendmentJiraOperation.publish_authorization(
                 reopened,
                 command["command_key"],
                 context,
                 critic_policy(),
                 opts
               )

      assert replayed["readback_json"] == effect["readback_json"]
      assert Process.get(:critic_auth_writes) == 1
      assert {:ok, draft} = TicketAmendmentJiraOperation.readback(reopened, command["command_key"])
      assert draft["readback_json"] != effect["readback_json"]
    after
      GenServer.stop(reopened)
    end
  end

  test "post-write authorization readback failure remains UNCERTAIN and retry is read-only", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert_received {:jira_write, %{"body" => draft_body}}
    assert draft_body == Process.get(:critic_draft_body)
    protected_before = protected_delivery_rows(ctx)
    delivery_before = delivery_state(ctx)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    reads_before = Process.get(:critic_jira_reads, 0)
    Process.put(:critic_auth_mode, :apply)
    Process.put(:critic_auth_writes, 0)
    Process.put(:critic_jira_read_error_on, reads_before + 2)

    assert {:error, :amendment_authorization_readback_unavailable} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    uncertain =
      Store.one!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])

    assert uncertain["phase"] == "UNCERTAIN"
    assert uncertain["last_error"] == ":test_postwrite_authorization_read_unavailable"
    assert Process.get(:critic_auth_writes) == 1
    assert Process.get(:critic_jira_reads) == reads_before + 2
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}

    assert {:ok, %{"phase" => "READ_BACK"} = readback} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert readback["readback_json"] == readback["observed_json"]
    assert Process.get(:critic_auth_writes) == 1
    assert Process.get(:critic_jira_reads) == reads_before + 3
    assert protected_delivery_rows(ctx) == protected_before
    assert delivery_state(ctx) == delivery_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
    refute_received {:jira_write, _}
  end

  test "lost authorization write remains UNCERTAIN and retry never appends again", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    Process.put(:critic_auth_mode, :lost_before_apply)
    Process.put(:critic_auth_writes, 0)

    assert {:error, :amendment_authorization_outcome_uncertain} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])["phase"] == "UNCERTAIN"
    Process.put(:critic_auth_mode, :apply)

    assert {:error, :amendment_authorization_outcome_uncertain} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Process.get(:critic_auth_writes) == 1
    refute Enum.any?(Process.get(:critic_jira_snapshot)["comments"], &String.starts_with?(&1["text"], "AI FACTORY AUTHORIZED issue-hex=" <> Base.encode16("PPL-123", case: :lower) <> " revision=2"))
  end

  test "capability denial leaves one PENDING intent which can be claimed only after capability returns", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    Process.put(:critic_auth_capability, {:error, :missing_comment_capability})
    Process.put(:critic_auth_writes, 0)

    assert {:error, :missing_comment_capability} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])["phase"] == "PENDING"
    assert Process.get(:critic_auth_writes) == 0
    Process.put(:critic_auth_capability, :ok)

    assert {:ok, %{"phase" => "READ_BACK"}} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Process.get(:critic_auth_writes) == 1
  end

  test "fresh Jira drift and a competing revision are rejected before authorization claim", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    baseline = Process.get(:critic_jira_snapshot)
    Process.put(:critic_auth_writes, 0)
    Process.put(:critic_jira_snapshot, Map.put(baseline, "summary", "unrelated Jira edit"))

    assert {:error, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]) == nil

    competing = Contract.bind("PPL-123", 3, "Competing revision\n\n## Manual Validation\n- Required: no")
    competing_comment = %{"id" => "competing-draft", "text" => Contract.draft_comment(competing)}
    Process.put(:critic_jira_snapshot, Map.update!(baseline, "comments", &(&1 ++ [competing_comment])))

    assert {:error, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Process.get(:critic_auth_writes) == 0
  end

  test "unrelated pre-read drift leaves a PENDING authorization unclaimed and unapplied", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert_received {:jira_write, %{"body" => draft_body}}
    assert draft_body == Process.get(:critic_draft_body)

    protected_before = protected_delivery_rows(ctx)
    delivery_before = delivery_state(ctx)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    Process.put(:critic_auth_capability, {:error, :missing_comment_capability})
    Process.put(:critic_auth_writes, 0)

    assert {:error, :missing_comment_capability} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    pending = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])
    assert pending["phase"] == "PENDING"
    draft_readback = Process.get(:critic_jira_snapshot)
    drifted = Map.put(draft_readback, "description", "unrelated source edit")
    Process.put(:critic_jira_snapshot, drifted)

    assert {:error, :amendment_authorization_preimage_changed} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    observed = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])
    assert observed["phase"] == "PENDING"
    assert observed["last_error"] == ":amendment_authorization_preimage_changed"
    assert observed["observed_json"] == Jason.encode!(drifted)
    assert Process.get(:critic_auth_writes) == 0
    assert protected_delivery_rows(ctx) == protected_before
    assert delivery_state(ctx) == delivery_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before

    assert Store.one!(ctx.store, "SELECT status, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == %{
             "status" => "ACCEPTED",
             "application_receipt_json" => nil
           }

    refute_received {:jira_write, %{"body" => ^body}}
  end

  test "candidate, native input, model route and tampered critic result all fence authorization", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    Process.put(:critic_auth_writes, 0)
    original_candidate = Store.one!(ctx.store, "SELECT candidate_sha FROM runs WHERE run_id = 'run'")["candidate_sha"]
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert {:error, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [original_candidate])

    amendment = Store.one!(ctx.store, "SELECT input_key FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    input = Store.one!(ctx.store, "SELECT body FROM ticket_chat_inputs WHERE input_key = ?", [amendment["input_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = 'tampered input' WHERE input_key = ?", [amendment["input_key"]])
    assert {:error, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [input["body"], amendment["input_key"]])

    changed_policy = put_in(critic_policy(), ["providers", "openai", "standard"], "different-model")
    assert {:error, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, changed_policy, opts)

    attempt = Store.one!(ctx.store, "SELECT result_json FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])
    forged = attempt["result_json"] |> Jason.decode!() |> Map.put("qualifies", false)
    raw = Jason.encode!(forged)
    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET result_json = ?, result_sha256 = ? WHERE command_key = ?", [raw, sha, command["command_key"]])
    assert {:error, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    assert Process.get(:critic_auth_writes) == 0
    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]) == nil
  end

  test "self-checksummed authorization receipt tampering fails its exact marker proof", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert {:ok, effect} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    forged_snapshot = Jason.decode!(effect["readback_json"])
    comments = List.update_at(forged_snapshot["comments"], -1, &Map.put(&1, "text", "forged authorization marker"))
    raw = Jason.encode!(Map.put(forged_snapshot, "comments", comments))
    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    Store.query!(ctx.store, "UPDATE ticket_amendment_authorization_effects SET readback_json = ?, readback_sha256 = ?, observed_json = ?, observed_sha256 = ? WHERE command_key = ?", [
      raw,
      sha,
      raw,
      sha,
      command["command_key"]
    ])

    assert {:error, _} =
             TicketAmendmentJiraOperation.readback_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy()
             )
  end

  test "READY_FOR_REVIEW authorization applies once to VERIFYING without changing candidate or source allocations", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)

    assert {:ok, %{"phase" => "READ_BACK"}} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    tasks_before = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows
    leases_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows

    assert {:ok, receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    applied = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    assert applied["state"] == "VERIFYING"
    assert applied["spec_revision"] == 2
    assert applied["contract_sha256"] == Contract.bind("PPL-123", 2, "Spec revision: 2\n\nRevised contract\n\n## Manual Validation\n- Required: no").sha256
    assert applied["candidate_sha"] == run_before["candidate_sha"]
    assert applied["verifier_round"] == run_before["verifier_round"] + 1
    assert applied["snapshot_json"] == receipt["authorization_readback_json"]
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == tasks_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows == leases_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows == evidence_before

    assert Store.one!(ctx.store, "SELECT status, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == %{
             "status" => "APPLIED",
             "application_receipt_json" => Jason.encode!(receipt)
           }

    assert Store.one!(ctx.store, "SELECT phase, active_owner, receipt_json FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == %{
             "phase" => "APPLIED",
             "active_owner" => 0,
             "receipt_json" => Jason.encode!(receipt)
           }

    assert {:ok, replayed} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    assert replayed == receipt
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == applied

    accepted_command = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])
    intact_application = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = NULL WHERE command_key = ?", [command["command_key"]])
    missing_admission = critic_fixture_state(ctx, command, critic_receipt["task_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert critic_fixture_state(ctx, command, critic_receipt["task_key"]) == missing_admission
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = ? WHERE command_key = ?", [accepted_command["receipt_json"], command["command_key"]])
    assert critic_fixture_state(ctx, command, critic_receipt["task_key"]) == intact_application
    assert {:ok, %{"phase" => "APPLIED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    protected_state = fn store ->
      fixture = %{ctx | store: store}

      Map.merge(critic_fixture_state(fixture, command, critic_receipt["task_key"]), %{
        chat: Store.one!(store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]]),
        links: Store.query!(store, "SELECT * FROM ticket_chat_runs WHERE chat_key = ? ORDER BY run_id", [ctx.chat["chat_key"]]).rows,
        commands: Store.query!(store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
        questions: Store.query!(store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows,
        inputs: Store.query!(store, "SELECT * FROM ticket_chat_inputs WHERE chat_key = ? ORDER BY input_key", [ctx.chat["chat_key"]]).rows,
        desktop_requests: Store.query!(store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
        supersessions: Store.query!(store, "SELECT * FROM ticket_contract_amendment_supersessions ORDER BY predecessor_command_key").rows,
        controller_checks: Store.query!(store, "SELECT * FROM controller_checks ORDER BY rowid").rows
      })
    end

    schema_catalog = fn store ->
      Store.query!(store, "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name").rows
    end

    checkout_paths = Store.one!(ctx.store, "SELECT repo_path, worktree FROM runs WHERE run_id = 'run'")

    checkout_state = fn ->
      [checkout_paths["repo_path"], checkout_paths["worktree"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn path ->
        git_dir =
          if File.dir?(path) do
            case System.cmd("git", ["-C", path, "rev-parse", "--absolute-git-dir"], stderr_to_stdout: true) do
              {directory, 0} -> String.trim(directory)
              _ -> nil
            end
          end

        source_file = Path.join(path, "fixture.txt")
        source_bytes = if File.regular?(source_file), do: File.read!(source_file)
        index_file = if git_dir, do: Path.join(git_dir, "index")
        index_bytes = if index_file && File.regular?(index_file), do: File.read!(index_file)
        untracked_file = Path.join(path, "untracked-resume-fixture.txt")
        untracked_bytes = if File.regular?(untracked_file), do: File.read!(untracked_file)

        git_read = fn args ->
          if git_dir do
            case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
              {value, 0} -> String.trim_trailing(value)
              _ -> nil
            end
          end
        end

        git_read_raw = fn args ->
          if git_dir do
            case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
              {value, 0} -> value
              _ -> nil
            end
          end
        end

        head = git_read.(["rev-parse", "HEAD"])
        head_ref = git_read.(["symbolic-ref", "HEAD"])
        branch = git_read.(["branch", "--show-current"])
        status = git_read_raw.(["status", "--porcelain=v1"])
        staged_bytes = git_read_raw.(["show", ":fixture.txt"])

        {path,
         %{
           path_exists: File.exists?(path),
           path_is_dir: File.dir?(path),
           source_bytes: source_bytes,
           index_bytes: index_bytes,
           head: head,
           head_ref: head_ref,
           branch: branch,
           status: status,
           staged_bytes: staged_bytes,
           untracked_bytes: untracked_bytes
         }}
      end)
    end

    canonical_state = protected_state.(ctx.store)
    canonical_amendment = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    decoded_prior_binding = Jason.decode!(canonical_amendment["prior_binding_json"])

    assert {:error, :u11_binding_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE ticket_contract_amendments SET prior_binding_json = ? WHERE command_key = ?", [canonical_amendment["prior_binding_json"] <> "\n", command["command_key"]])
               corrupted_state = protected_state.(tx)

               assert Jason.decode!(Store.one!(tx, "SELECT prior_binding_json FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])["prior_binding_json"]) ==
                        decoded_prior_binding

               assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(tx, command["command_key"])
               assert protected_state.(tx) == corrupted_state
               Exqlite.rollback(tx, :u11_binding_probe_rolled_back)
             end)

    assert protected_state.(ctx.store) == canonical_state
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == canonical_amendment
    assert {:ok, %{"phase" => "APPLIED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    assert {:error, :u11_revision_probe_rolled_back} =
             Exqlite.transaction(ctx.store, fn tx ->
               Store.query!(tx, "UPDATE ticket_contract_amendments SET prior_revision = 'not-a-revision' WHERE command_key = ?", [command["command_key"]])
               assert Store.one!(tx, "SELECT typeof(prior_revision) AS value FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])["value"] == "text"
               corrupted_state = protected_state.(tx)
               assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(tx, command["command_key"])
               assert protected_state.(tx) == corrupted_state
               Exqlite.rollback(tx, :u11_revision_probe_rolled_back)
             end)

    assert protected_state.(ctx.store) == canonical_state
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == canonical_amendment
    assert {:ok, %{"phase" => "APPLIED"}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    assert {:error, :blocked_amendment_ancestry_invalid} =
             TicketContractAmendment.blocked_source_preimage(ctx.store, command["command_key"])

    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == applied

    schema_before = schema_catalog.(ctx.store)
    full_state_before = protected_state.(ctx.store)
    checkout_before = checkout_state.()
    jira_effects_before = Store.query!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects ORDER BY command_key").rows
    renamed_effect_table = "ticket_amendment_jira_effects_u11_unavailable_probe"
    refute Enum.any?(schema_before, fn [_type, name, _table, _sql] -> name == renamed_effect_table end)
    {:ok, owned_schema_store} = Store.start_link(database: ctx.database)

    try do
      assert schema_catalog.(owned_schema_store) == schema_before

      assert {:error, :u11_effect_schema_rollback} =
               Exqlite.transaction(owned_schema_store, fn tx ->
                 Store.query!(tx, "ALTER TABLE ticket_amendment_jira_effects RENAME TO #{renamed_effect_table}")
                 fault_schema = schema_catalog.(tx)
                 fault_effects = Store.query!(tx, "SELECT * FROM #{renamed_effect_table} ORDER BY command_key").rows
                 fault_rows = sqlite_table_rows(tx, fault_schema)
                 fault_checkout = checkout_state.()
                 assert fault_effects == jira_effects_before
                 assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(tx, command["command_key"])
                 assert schema_catalog.(tx) == fault_schema
                 assert sqlite_table_rows(tx, fault_schema) == fault_rows
                 assert checkout_state.() == fault_checkout
                 assert Store.query!(tx, "SELECT * FROM #{renamed_effect_table} ORDER BY command_key").rows == fault_effects
                 assert Store.query!(tx, "SELECT 1 AS healthy").rows == [[1]]
                 Exqlite.rollback(tx, :u11_effect_schema_rollback)
               end)
    after
      if Process.alive?(owned_schema_store), do: GenServer.stop(owned_schema_store)
    end

    assert {:ok, readonly_schema_store} = Store.start_read_only(database: ctx.database)

    try do
      assert schema_catalog.(readonly_schema_store) == schema_before
      assert protected_state.(readonly_schema_store) == full_state_before
      assert {:ok, ^canonical_amendment} = TicketContractAmendment.get(readonly_schema_store, command["command_key"])
      assert checkout_state.() == checkout_before
      assert Store.query!(readonly_schema_store, "SELECT * FROM ticket_amendment_jira_effects ORDER BY command_key").rows == jira_effects_before
      assert {:ok, %{"phase" => "APPLIED"}} = TicketContractAmendment.get(readonly_schema_store, command["command_key"])
    after
      GenServer.stop(readonly_schema_store)
    end
  end

  @tag mixed_amendment: true
  test "mixed authorized amendment closes selected answer atomically and replays after reopen", %{ctx: ctx, command: command, context: context, control: control} do
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")["status"] == "OPEN"
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    question = Store.one!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")

    for {field, changed} <- [
          {"body", "Changed after authorization?"},
          {"answers_json", Jason.encode!(%{"no" => false})},
          {"opened_at", question["opened_at"] + 1},
          {"binding_json", "{}"}
        ] do
      Store.query!(ctx.store, "UPDATE ticket_chat_questions SET #{field} = ? WHERE question_key = 'Q-mixed'", [changed])
      assert {:error, _} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
      Store.query!(ctx.store, "UPDATE ticket_chat_questions SET #{field} = ? WHERE question_key = 'Q-mixed'", [question[field]])
    end

    Store.query!(ctx.store, "UPDATE ticket_chats SET generation = generation + 1 WHERE chat_key = ?", [ctx.chat["chat_key"]])
    assert {:error, _} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    Store.query!(ctx.store, "UPDATE ticket_chats SET generation = ? WHERE chat_key = ?", [ctx.chat["generation"], ctx.chat["chat_key"]])
    Store.query!(ctx.store, "UPDATE runs SET contract_sha256 = ? WHERE run_id = 'run'", [String.duplicate("d", 64)])
    assert {:error, _} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    Store.query!(ctx.store, "UPDATE runs SET contract_sha256 = ? WHERE run_id = 'run'", [ctx.contract.sha256])

    Store.query!(ctx.store, "INSERT INTO ticket_chat_questions(question_key, chat_key, run_id, binding_json, body, answers_json, opened_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, 'OPEN')", [
      "Q-unrelated",
      ctx.chat["chat_key"],
      "run",
      Jason.encode!(context["binding"] |> Map.put("run_id", "run")),
      "Unrelated?",
      Jason.encode!(%{"yes" => true}),
      System.system_time(:millisecond) / 1000
    ])

    assert {:error, :amendment_competing_current_work} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")["status"] == "OPEN"
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET status = 'ANSWERED' WHERE question_key = 'Q-unrelated'")
    protected_before = protected_delivery_rows(ctx)
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    question_before = Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows
    command_before = Store.one!(ctx.store, "SELECT status, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])
    amendment_before = Store.one!(ctx.store, "SELECT phase, active_owner, receipt_json, application_receipt_sha256 FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])

    Store.query!(
      ctx.store,
      "CREATE TRIGGER reject_mixed_terminal BEFORE UPDATE OF phase ON ticket_contract_amendments WHEN NEW.phase = 'APPLIED' BEGIN SELECT RAISE(ABORT, 'injected mixed terminal failure'); END"
    )

    assert_raise Exqlite.Error, ~r/injected mixed terminal failure/, fn ->
      TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    end

    Store.query!(ctx.store, "DROP TRIGGER reject_mixed_terminal")
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows == question_before
    assert Store.one!(ctx.store, "SELECT status, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == command_before

    assert Store.one!(ctx.store, "SELECT phase, active_owner, receipt_json, application_receipt_sha256 FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) ==
             amendment_before

    assert protected_delivery_rows(ctx) == protected_before

    candidate_before = run_before["candidate_sha"]
    worktree_before = run_before["worktree"]
    iteration_before = run_before["implementation_iteration"]
    assert {:ok, receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    applied_run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    assert applied_run["candidate_sha"] == candidate_before
    assert applied_run["worktree"] == worktree_before
    assert applied_run["implementation_iteration"] == iteration_before
    assert protected_delivery_rows(ctx) == protected_before
    assert receipt["answer_application_proof"]["question_keys"] == ["Q-mixed"]

    assert Store.one!(ctx.store, "SELECT status, answer_json, input_key FROM ticket_chat_questions WHERE question_key = 'Q-mixed'") == %{
             "status" => "ANSWERED",
             "answer_json" => "true",
             "input_key" => command["input_key"]
           }

    GenServer.stop(ctx.store)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^receipt} = TicketContractAmendment.apply_authorized(reopened, command["command_key"], context, critic_policy())
      assert Store.one!(reopened, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")["status"] == "ANSWERED"
      Store.query!(reopened, "UPDATE runs SET state = 'READY_FOR_REVIEW', candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("c", 40)])
      advanced = Store.one!(reopened, "SELECT * FROM runs WHERE run_id = 'run'")
      assert {:ok, ^receipt} = TicketContractAmendment.apply_authorized(reopened, command["command_key"], context, critic_policy())
      assert Store.one!(reopened, "SELECT * FROM runs WHERE run_id = 'run'") == advanced

      input = Store.one!(reopened, "SELECT body FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
      Store.query!(reopened, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [input["body"] <> "tamper", command["input_key"]])
      assert {:error, _} = TicketContractAmendment.apply_authorized(reopened, command["command_key"], context, critic_policy())
      Store.query!(reopened, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [input["body"], command["input_key"]])

      payload = Store.one!(reopened, "SELECT payload_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])["payload_json"]
      Store.query!(reopened, "UPDATE ticket_chat_commands SET payload_json = '[]' WHERE command_key = ?", [command["command_key"]])
      assert {:error, _} = TicketContractAmendment.apply_authorized(reopened, command["command_key"], context, critic_policy())
      Store.query!(reopened, "UPDATE ticket_chat_commands SET payload_json = ? WHERE command_key = ?", [payload, command["command_key"]])

      Store.query!(reopened, "UPDATE ticket_chat_questions SET answer_json = 'false' WHERE question_key = 'Q-mixed'")
      assert {:error, _} = TicketContractAmendment.apply_authorized(reopened, command["command_key"], context, critic_policy())
      Store.query!(reopened, "UPDATE ticket_chat_questions SET answer_json = 'true' WHERE question_key = 'Q-mixed'")

      tampered = put_in(receipt, ["answer_application_proof", "original_questions", Access.at(0), "body"], "forged question")
      tampered_raw = Jason.encode!(tampered)
      tampered_sha = :crypto.hash(:sha256, tampered_raw) |> Base.encode16(case: :lower)
      Store.query!(reopened, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [tampered_raw, tampered_sha, command["command_key"]])
      Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [tampered_raw, command["command_key"]])
      assert {:error, _} = TicketContractAmendment.apply_authorized(reopened, command["command_key"], context, critic_policy())
      receipt_raw = Jason.encode!(receipt)
      receipt_sha = :crypto.hash(:sha256, receipt_raw) |> Base.encode16(case: :lower)
      Store.query!(reopened, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [receipt_raw, receipt_sha, command["command_key"]])
      Store.query!(reopened, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [receipt_raw, command["command_key"]])
    after
      GenServer.stop(reopened)
    end
  end

  @tag mixed_amendment: true
  test "mixed answer remains open after a recorded non-PASS critic result", %{ctx: ctx, command: command, context: context, control: control} do
    Process.put(:critic_output, %{"status" => "BLOCK", "findings" => [], "required_questions" => ["Clarify the acceptance boundary"]})
    assert {:ok, receipt} = run_critic(ctx, command, context, control)
    refute receipt["qualifies"]
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")["status"] == "OPEN"
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])["status"] == "ACCEPTED"
    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]) == nil
  end

  @tag mixed_amendment: true
  test "mixed answer remains open while authorization outcome is uncertain", %{ctx: ctx, command: command, context: context, control: control} do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    Process.put(:critic_auth_mode, :lost_before_apply)

    assert {:error, :amendment_authorization_outcome_uncertain} =
             TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")["status"] == "OPEN"
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])["status"] == "ACCEPTED"
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]])["phase"] == "UNCERTAIN"
  end

  test "APPLIED replay remains historical after legitimate live run advancement", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    assert {:ok, receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())

    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW', snapshot_json = ?, model = ?, verifier_round = verifier_round + 1, candidate_sha = ? WHERE run_id = 'run'", [
      Jason.encode!(%{"key" => "PPL-123", "summary" => "later source snapshot"}),
      "later-model-route",
      String.duplicate("c", 40)
    ])

    advanced = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")

    assert {:ok, ^receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == advanced
    assert {:ok, %{"phase" => "APPLIED", "active_owner" => 0}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    stale_context = put_in(context, ["binding", "candidate_sha"], String.duplicate("d", 40))
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    command_before = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]])
    assert {:error, :stale_controller_context} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], stale_context, critic_policy())
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == advanced
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == command_before
  end

  test "self-checksummed run-image tampering cannot rewrite the historical application", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    assert {:ok, receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())

    corruptions = [
      fn original -> mutate_run_image(original, "prior_run_json", &Map.put(&1, "state", "WRITING")) end,
      fn original -> mutate_run_image(original, "prior_run_json", &Map.put(&1, "implementation_iteration", 999)) end,
      fn original -> mutate_run_image(original, "applied_run_json", &Map.put(&1, "snapshot_json", Jason.encode!(%{"key" => "PPL-123", "description" => "forged"}))) end
    ]

    for corrupt <- corruptions do
      forged = corrupt.(receipt)
      forged = reseal_run_image(forged, "prior_run_json", "prior_run_sha256")
      forged = reseal_run_image(forged, "applied_run_json", "applied_run_sha256")
      raw = Jason.encode!(forged)
      sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [raw, sha, command["command_key"]])
      Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [raw, command["command_key"]])

      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())

      original = Jason.encode!(receipt)
      original_sha = :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = ?, application_receipt_sha256 = ? WHERE command_key = ?", [original, original_sha, command["command_key"]])
      Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [original, command["command_key"]])
      assert {:ok, _} = TicketContractAmendment.get(ctx.store, command["command_key"])
    end
  end

  test "a failed terminal write rolls back the run transition and both receipts", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")

    Store.query!(
      ctx.store,
      "CREATE TRIGGER reject_amendment_terminal BEFORE UPDATE OF phase ON ticket_contract_amendments WHEN NEW.phase = 'APPLIED' BEGIN SELECT RAISE(ABORT, 'injected terminal failure'); END"
    )

    assert_raise Exqlite.Error, ~r/injected terminal failure/, fn ->
      TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    end

    Store.query!(ctx.store, "DROP TRIGGER reject_amendment_terminal")

    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before

    assert Store.one!(ctx.store, "SELECT status, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == %{
             "status" => "ACCEPTED",
             "application_receipt_json" => nil
           }

    assert Store.one!(ctx.store, "SELECT phase, active_owner, application_receipt_sha256 FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == %{
             "phase" => "RESERVED",
             "active_owner" => 1,
             "application_receipt_sha256" => nil
           }

    Store.query!(
      ctx.store,
      "CREATE TRIGGER corrupt_amendment_terminal AFTER UPDATE OF phase ON ticket_contract_amendments WHEN NEW.phase = 'APPLIED' BEGIN UPDATE ticket_contract_amendments SET receipt_json = '{}' WHERE command_key = NEW.command_key; END"
    )

    assert {:error, :invalid_contract_amendment} =
             TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())

    Store.query!(ctx.store, "DROP TRIGGER corrupt_amendment_terminal")
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before

    assert Store.one!(ctx.store, "SELECT status, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]) == %{
             "status" => "ACCEPTED",
             "application_receipt_json" => nil
           }

    assert Store.one!(ctx.store, "SELECT phase, active_owner, receipt_json, application_receipt_sha256 FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == %{
             "phase" => "RESERVED",
             "active_owner" => 1,
             "receipt_json" => nil,
             "application_receipt_sha256" => nil
           }
  end

  test "a completed amendment releases the run for a distinct later amendment", %{
    ctx: ctx,
    command: command,
    context: context,
    control: control
  } do
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, critic_receipt, control)
    assert {:ok, _} = TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)
    assert {:ok, _} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())

    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    next_context = amendment_context(ctx, run)
    markdown = "Second revision\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    {:ok, staged} = stage(ctx, "second-amendment", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    first_body = "Revise the contract:\nSpec revision: 1\n\nRevised contract\n\n## Manual Validation\n- Required: no"

    assert {:ok, %{receipts: [%{"status" => "APPLIED"}, %{"status" => "ACCEPTED"}]}} =
             TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, body]))

    assert {:ok, next_amendment} = TicketContractAmendment.reserve(ctx.store, staged["command_key"], next_context)
    assert next_amendment["prior_revision"] == 2
    assert next_amendment["active_owner"] == 1
    assert {:ok, %{"phase" => "APPLIED", "active_owner" => 0}} = TicketContractAmendment.get(ctx.store, command["command_key"])

    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET receipt_json = '{}' WHERE command_key = ?", [command["command_key"]])
    assert {:error, _} = TicketContractAmendment.reserve(ctx.store, staged["command_key"], next_context)
  end

  test "BLOCK output cannot publish authorization", %{ctx: ctx, command: command, context: context, control: control} do
    assert_no_authorization_for_output(ctx, command, context, control, %{
      "status" => "BLOCK",
      "findings" => [],
      "required_questions" => ["Resolve the acceptance boundary"]
    })
  end

  test "REPAIR output cannot publish authorization", %{ctx: ctx, command: command, context: context, control: control} do
    assert_no_authorization_for_output(ctx, command, context, control, %{
      "status" => "REPAIR",
      "findings" => ["Clarify the deployment constraint"],
      "required_questions" => []
    })
  end

  test "PASS with findings cannot publish authorization", %{ctx: ctx, command: command, context: context, control: control} do
    assert_no_authorization_for_output(ctx, command, context, control, %{
      "status" => "PASS",
      "findings" => ["Unresolved ambiguity"],
      "required_questions" => []
    })
  end

  test "unproven critic stop cannot publish authorization", %{ctx: ctx, command: command, context: context, control: control} do
    Process.put(:critic_stop_result, {:error, :shutdown_unproven})
    Process.put(:critic_auth_writes, 0)

    assert {:error, {:critic_attempt_reconcile_required, _}} = run_critic(ctx, command, context, control)
    {_body, opts} = authorization_opts(ctx, command, %{"task_key" => "unused", "output" => %{}}, control)

    assert {:error, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Process.get(:critic_auth_writes) == 0
    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]) == nil
  end

  test "stale current candidate, published readback, and reserved child-task bindings fail closed", %{ctx: ctx, command: command, context: context, control: control} do
    original_candidate = Store.one!(ctx.store, "SELECT candidate_sha FROM runs WHERE run_id = 'run'")["candidate_sha"]
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert {:error, _} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [original_candidate])

    effect = Store.one!(ctx.store, "SELECT readback_json FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET readback_json = '{}' WHERE command_key = ?", [command["command_key"]])
    assert {:error, _} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET readback_json = ? WHERE command_key = ?", [effect["readback_json"], command["command_key"]])

    task_key = Store.one!(ctx.store, "SELECT task_key FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]])["task_key"]
    Store.query!(ctx.store, "UPDATE factory_tasks SET status = 'RECONCILE_REQUIRED' WHERE task_key = ?", [task_key])
    assert {:error, :invalid_critic_attempt} = TicketAmendmentCritic.execute(ctx.store, command["command_key"], context, control, critic_policy(), app_server: CriticAppServer)
    refute_received {:critic_session_started, _}
  end

  defp prepare_next_amendment(ctx, command, context, control) do
    initial_draft_body = Process.get(:critic_draft_body)
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^initial_draft_body}}
    assert {:ok, critic_receipt} = run_critic(ctx, command, context, control)
    {authorization_body, authorization_opts} = authorization_opts(ctx, command, critic_receipt, control)

    assert {:ok, %{"phase" => "READ_BACK"}} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               authorization_opts
             )

    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^authorization_body}}
    assert {:ok, first_receipt} = TicketContractAmendment.apply_authorized(ctx.store, command["command_key"], context, critic_policy())
    assert first_receipt["proposed_revision"] == 2
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    next_context = amendment_context(ctx, run)
    markdown = "Second recovery amendment\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    {:ok, next_command} = stage(ctx, "second-amendment-recovery", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    first_body = "Revise the contract:\nSpec revision: 1\n\nRevised contract\n\n## Manual Validation\n- Required: no"

    assert {:ok, %{receipts: [%{"status" => "APPLIED"}, %{"status" => "ACCEPTED"}]}} =
             TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [first_body, body]))

    assert {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, next_command["command_key"], next_context)
    draft_body = Contract.draft_comment(Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"]))
    Process.put(:critic_draft_body, draft_body)
    Process.put(:critic_jira_expected_body, draft_body)
    Process.put(:critic_auth_mode, :apply)
    Process.put(:critic_auth_writes, 0)

    jira_opts = [
      workspace: control,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    %{command: next_command, context: next_context, body: body, draft_body: draft_body, jira_opts: jira_opts}
  end

  defp accept_proposal(ctx) do
    markdown = "Spec revision: 1\n\nRevised contract\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    operations = [%{"operation" => "propose_contract_revision", "markdown" => markdown}]
    {:ok, staged} = stage(ctx, "critic-proposal", body, operations)
    native = native(ctx, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
  end

  defp accept_mixed_proposal(ctx) do
    source = normalized_source(ctx)
    Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run'", [Jason.encode!(source)])
    markdown = "Mixed amendment contract\n\n## Manual Validation\n- Required: no"
    body = "Answer Q-mixed: yes\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-mixed", "body" => "Keep candidate?", "answers" => %{"yes" => true}})

    operations = [
      %{"operation" => "answer_question", "question_key" => "Q-mixed", "value" => true},
      %{"operation" => "propose_contract_revision", "markdown" => markdown}
    ]

    {:ok, staged} = stage(ctx, "critic-mixed-proposal", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
  end

  defp migrate_amendments_to_v35(store) do
    Store.query!(store, "PRAGMA foreign_keys = OFF")
    Store.query!(store, "PRAGMA legacy_alter_table = ON")

    for table <- ~w(ticket_contract_amendments ticket_contract_critic_attempts ticket_amendment_jira_effects ticket_amendment_authorization_effects) do
      sql = Store.one!(store, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])["sql"]
      fixture = table <> "_v35_fixture"
      create = Regex.replace(~r/CREATE TABLE "?#{table}"?/, sql, "CREATE TABLE #{fixture}")
      create = String.replace(create, "candidate_sha TEXT,", "candidate_sha TEXT NOT NULL,")
      columns = Store.query!(store, "PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1))
      names = Enum.join(columns, ", ")
      Store.query!(store, create)
      Store.query!(store, "INSERT INTO #{fixture}(#{names}) SELECT #{names} FROM #{table}")
      Store.query!(store, "DROP TABLE #{table}")
      Store.query!(store, "ALTER TABLE #{fixture} RENAME TO #{table}")
    end

    Store.query!(store, "CREATE UNIQUE INDEX one_active_contract_amendment_per_run ON ticket_contract_amendments(run_id) WHERE active_owner = 1")
    Store.query!(store, "DELETE FROM factory_schema_migrations WHERE version IN (36, 37)")
    Store.query!(store, "PRAGMA legacy_alter_table = OFF")
    Store.query!(store, "PRAGMA foreign_keys = ON")
  end

  defp amendment_table_rows(store, tables) do
    Map.new(tables, fn table ->
      rows = Store.query!(store, "SELECT * FROM #{table}").rows |> Enum.sort()
      {table, rows}
    end)
  end

  defp force_amendment_candidates_not_null(store) do
    Store.query!(store, "PRAGMA foreign_keys = OFF")
    Store.query!(store, "PRAGMA legacy_alter_table = ON")

    for table <- ~w(ticket_contract_amendments ticket_contract_critic_attempts ticket_amendment_jira_effects ticket_amendment_authorization_effects) do
      sql = Store.one!(store, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])["sql"]
      upgrade = table <> "_not_null_again"
      create = Regex.replace(~r/CREATE TABLE "?#{table}"?/, sql, "CREATE TABLE #{upgrade}")
      create = String.replace(create, "candidate_sha TEXT,", "candidate_sha TEXT NOT NULL,")
      columns = Store.query!(store, "PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1))
      names = Enum.join(columns, ", ")
      Store.query!(store, create)
      Store.query!(store, "INSERT INTO #{upgrade}(#{names}) SELECT #{names} FROM #{table}")
      Store.query!(store, "DROP TABLE #{table}")
      Store.query!(store, "ALTER TABLE #{upgrade} RENAME TO #{table}")
    end

    Store.query!(store, "CREATE UNIQUE INDEX one_active_contract_amendment_per_run ON ticket_contract_amendments(run_id) WHERE active_owner = 1")
    Store.query!(store, "PRAGMA legacy_alter_table = OFF")
    Store.query!(store, "PRAGMA foreign_keys = ON")
  end

  defp delivery_state(ctx) do
    %{
      run: Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'"),
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows
    }
  end

  defp critic_fixture_state(ctx, command, task_key) do
    %{
      amendment: Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]),
      attempt: Store.one!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command["command_key"]]),
      command: Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [command["command_key"]]),
      task: Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key]),
      tasks: query_rows_as_maps(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key", []),
      run: Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'"),
      events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows,
      worker_evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
      workspace_access: Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows,
      review_bases: Store.query!(ctx.store, "SELECT * FROM ticket_review_bases WHERE run_id = 'run' ORDER BY run_id").rows,
      checkouts: Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'run' ORDER BY run_id").rows,
      jira_effects: Store.query!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]).rows,
      authorization_effects: Store.query!(ctx.store, "SELECT * FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]).rows
    }
  end

  defp query_rows_as_maps(store, sql, params) do
    %{columns: columns, rows: rows} = Store.query!(store, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp protected_delivery_rows(ctx) do
    %{
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
      access: Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows,
      checkouts: Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'run' ORDER BY run_id").rows
    }
  end

  defp assert_delivery_rows_preserved(ctx, before) do
    current = delivery_state(ctx)
    assert current.run == before.run
    assert current.evidence == before.evidence
    assert Enum.all?(before.tasks, &(&1 in current.tasks))
  end

  defp normalized_source(ctx) do
    snapshot = ctx.store |> Store.one!("SELECT snapshot_json FROM runs WHERE run_id = 'run'") |> then(&Jason.decode!(&1["snapshot_json"]))

    Map.merge(snapshot, %{
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
      "comments" => Enum.with_index(snapshot["comments"], 1) |> Enum.map(fn {comment, index} -> Map.put_new(comment, "id", "old-comment-#{index}") end)
    })
  end

  defp amendment_context(ctx, run) do
    chat = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])

    %{
      "chat_key" => chat["chat_key"],
      "run_id" => run["run_id"],
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run["spec_revision"], "contract_sha256" => run["contract_sha256"], "candidate_sha" => run["candidate_sha"]}
    }
  end

  defp critic_policy do
    %{
      "default_provider" => "openai",
      "providers" => %{"openai" => %{"standard" => "critic-model-v1"}},
      "roles" => %{"specification-critic" => %{"provider" => "openai", "model_class" => "standard", "reasoning_effort" => "high"}}
    }
  end

  defp assert_owner_stop_mismatch(ctx, command, context, control) do
    assert {:error, {:critic_attempt_reconcile_required, reason}} =
             TicketAmendmentCritic.execute(
               ctx.store,
               command["command_key"],
               context,
               control,
               critic_policy(),
               app_server: CriticAppServer
             )

    assert reason == {:critic_result_receipt_rejected, :critic_owner_stop_mismatch}
  end

  defp run_critic(ctx, command, context, control) do
    TicketAmendmentCritic.execute(
      ctx.store,
      command["command_key"],
      context,
      control,
      critic_policy(),
      app_server: CriticAppServer
    )
  end

  defp assert_no_authorization_for_output(ctx, command, context, control, output) do
    Process.put(:critic_output, output)
    assert {:ok, receipt} = run_critic(ctx, command, context, control)
    refute receipt["qualifies"]
    {_body, opts} = authorization_opts(ctx, command, receipt, control)
    Process.put(:critic_auth_writes, 0)

    assert {:error, _} =
             TicketAmendmentJiraOperation.publish_authorization(
               ctx.store,
               command["command_key"],
               context,
               critic_policy(),
               opts
             )

    assert Process.get(:critic_auth_writes) == 0
    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_amendment_authorization_effects WHERE command_key = ?", [command["command_key"]]) == nil
  end

  defp authorization_opts(ctx, command, critic_receipt, control) do
    {:ok, amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    proposed = Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"])
    output_sha256 = :crypto.hash(:sha256, Jason.encode!(critic_receipt["output"])) |> Base.encode16(case: :lower)
    body = Contract.automatic_authorization_marker(proposed, critic_receipt["task_key"], output_sha256)
    Process.put(:critic_jira_expected_body, body)

    opts = [
      workspace: control,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    ]

    {body, opts}
  end

  defp attempt_binding_sha256(attempt) do
    fields =
      ~w(command_key run_id task_key chat_key generation input_key input_sha256 draft_comment_id prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256 prompt_sha256 schema_sha256 snapshot_sha256 route_sha256)

    raw = Jason.encode!(Map.take(attempt, fields))
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp mutate_run_image(receipt, image_key, mutate) do
    receipt
    |> Map.update!(image_key, fn raw -> raw |> Jason.decode!() |> mutate.() |> Jason.encode!() end)
  end

  defp reseal_run_image(receipt, image_key, digest_key) do
    raw = Map.fetch!(receipt, image_key)
    Map.put(receipt, digest_key, :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower))
  end

  defp sqlite_table_rows(store, catalog) do
    catalog
    |> Enum.filter(fn [type, _name, _table_name, _sql] -> type == "table" end)
    |> Map.new(fn [_type, name, _table_name, _sql] ->
      quoted_name = "\"" <> String.replace(name, "\"", "\"\"") <> "\""
      {name, Store.query!(store, "SELECT * FROM #{quoted_name}").rows |> Enum.sort()}
    end)
  end
end
