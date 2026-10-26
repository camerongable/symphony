defmodule SymphonyElixir.FactoryTicketJiraOperationTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, Scheduler, Store, TaskLedger, TicketJiraOperation}

  defmodule Reader do
    def issue(key, _opts) do
      count = Process.get(:jira_reads, 0) + 1
      Process.put(:jira_reads, count)
      if hook = Process.get(:jira_before_read), do: hook.(count)
      snapshot = Process.get(:jira_snapshot)
      if snapshot["key"] != key, do: raise("foreign Jira issue")
      {:ok, snapshot}
    end
  end

  defmodule Connector do
    def call_list("jira_get_transitions", %{"issue_key" => "PPL-123"}, _opts), do: {:ok, Process.get(:jira_transitions)}

    def validate_call(tool, args, opts) do
      if opts[:mcp_session] != %{thread_id: "jira-fixture"}, do: raise("missing owned Jira scope")
      if args["issue_key"] != "PPL-123", do: raise("foreign write")

      Process.get(:jira_capability, :ok)
      |> tap(fn _ -> send(self(), {:capability, tool}) end)
    end

    def call(tool, args, _opts) do
      Process.put(:jira_calls, Process.get(:jira_calls) ++ [{tool, args}])

      case {tool, Process.get(:jira_mode)} do
        {"jira_transition_issue", :lost_before_apply} ->
          {:error, :timeout}

        {"jira_transition_issue", :lost_after_apply} ->
          Process.put(:jira_snapshot, Map.put(Process.get(:jira_snapshot), "status", "In Dev"))
          {:error, :timeout}

        {"jira_transition_issue", _} ->
          Process.put(:jira_snapshot, Map.put(Process.get(:jira_snapshot), "status", "In Dev"))
          {:ok, %{}}

        {"jira_update_factory_labels", _} ->
          snapshot = Process.get(:jira_snapshot)
          labels = (snapshot["labels"] -- args["remove_labels"]) ++ args["add_labels"]
          Process.put(:jira_snapshot, Map.put(snapshot, "labels", Enum.uniq(labels)))
          if hook = Process.get(:jira_after_labels), do: hook.()
          {:ok, %{"mutation_requested" => true}}
      end
    end
  end

  setup context do
    ctx = setup_fixture(context)
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)
    bind_parent(ctx)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "COMPLETE"})
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER", candidate_sha: nil})
    Store.query!(ctx.store, "INSERT INTO ticket_review_bases VALUES ('run', 'master', ?, ?)", [ctx.sha, DateTime.to_iso8601(DateTime.utc_now())])
    snapshot = Jason.decode!(run["snapshot_json"]) |> Map.merge(%{"status" => "To Do", "labels" => ~w(ai-ready repo-grail human-label)})
    Process.put(:jira_snapshot, snapshot)
    Process.put(:jira_calls, [])
    Process.put(:jira_transitions, [%{"id" => "11", "to_status" => "In Dev"}])

    scope = fn _workspace, operation ->
      send(self(), :jira_scope_open)

      try do
        operation.(%{thread_id: "jira-fixture"})
      after
        send(self(), :jira_scope_closed)
      end
    end

    File.mkdir_p!(Path.join(ctx.root, "control"))

    options = opts(ctx) ++ [workspace: Path.join(ctx.root, "control"), workspace_root: Path.join(ctx.root, "workspaces"), jira_session: scope, jira_reader: Reader, jira_connector: Connector]
    Map.merge(ctx, %{run: run, options: options})
  end

  test "one bounded handoff observes both effects and admits the writer without creating source work", ctx do
    tasks = Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows
    assert {:ok, %{status: "WRITER_ADMITTED", run: run, model_invoked: false}} = step(ctx)
    assert run["state"] == "WRITING" and run["candidate_sha"] == nil
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == tasks

    assert Process.get(:jira_calls) == [
             {"jira_transition_issue", %{"issue_key" => "PPL-123", "transition_id" => "11"}},
             {"jira_update_factory_labels", %{"issue_key" => "PPL-123", "add_labels" => ["ai-running"], "remove_labels" => ~w(ai-ready ai-verifying)}}
           ]

    assert Process.get(:jira_snapshot)["labels"] == ~w(repo-grail human-label ai-running)
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "COMPLETE"
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access WHERE mode = 'MAINTENANCE'")["released_at"] != nil
    assert_received :jira_scope_open
    assert_received :jira_scope_closed
    assert {:error, :ticket_writer_admission_changed} = step(ctx)
    assert length(Process.get(:jira_calls)) == 2
  end

  test "scheduler opens initial Jira effects in its controller workspace rather than the ticket parent", ctx do
    context = %{store: ctx.store, workspace_root: ctx.options[:workspace_root], factory: %{scope: "scope"}}
    expected = Path.join([context.workspace_root, "factory-controller", "scope"])
    File.mkdir_p!(expected)

    scope = fn workspace, _operation ->
      send(self(), {:initial_jira_workspace, workspace})
      {:error, :workspace_probe_finished}
    end

    assert {:error, :workspace_probe_finished} = Scheduler.ticket_step(context, "run", Keyword.put(ctx.options, :jira_session, scope))
    assert_received {:initial_jira_workspace, ^expected}
    assert Process.get(:jira_calls) == []
    assert {:ok, %{"state" => "ADMITTING_WRITER"}} = RunLedger.get(ctx.store, "run")
  end

  test "Jira ownership uses a bounded monorepo budget on the actual outer transaction", ctx do
    test_pid = self()
    tracer = spawn_link(fn -> trace_jira_transactions(test_pid) end)
    :erlang.trace_pattern({Exqlite, :transaction, 3}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, %{status: "WRITER_ADMITTED"}} = step(ctx)
      assert_receive {:jira_outer_transaction, store, opts}, 1000
      assert store == ctx.store
      assert Keyword.fetch!(opts, :timeout) == 60_000
      assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "COMPLETE"
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Exqlite, :transaction, 3}, false, [:local])
      send(tracer, :stop)
    end
  end

  defp trace_jira_transactions(test_pid) do
    receive do
      {:trace, _pid, :call, {Exqlite, :transaction, [store, fun, opts]}} when is_pid(store) ->
        if :erlang.fun_info(fun, :module) == {:module, TicketJiraOperation}, do: send(test_pid, {:jira_outer_transaction, store, opts})
        trace_jira_transactions(test_pid)

      :stop ->
        :ok

      _ ->
        trace_jira_transactions(test_pid)
    end
  end

  test "unqualified runtime prevents a pending Jira effect from becoming uncertain or admitting a writer", ctx do
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, %{})
    assert {:error, :worker_runtime_identity_unproven} = step(ctx)
    assert Process.get(:jira_calls) == []
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "FIRST_PENDING"
    assert {:error, :ticket_jira_recovery_unissued} = TicketJiraOperation.reconcile(ctx.store, "run", ctx.options)
  end

  test "a human block observed after runtime initialization prevents the pending Jira mutation", ctx do
    marker = Path.join(ctx.root, "runtime-ready")
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root, :supported, "touch '#{marker}'")

    Process.put(:jira_before_read, fn _count ->
      if File.exists?(marker) do
        Process.put(:jira_snapshot, Map.update!(Process.get(:jira_snapshot), "labels", &["ai-blocked" | &1]))
      end
    end)

    assert {:error, :ticket_jira_not_dispatchable} = step(ctx)
    assert File.exists?(marker)
    assert Process.get(:jira_calls) == []
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "FIRST_PENDING"
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
  end

  test "source repository and checkout aliases cannot open a Jira controller session", ctx do
    for workspace <- [nil, ""] do
      assert {:error, :ticket_jira_controller_cwd_required} = TicketJiraOperation.start_implementation(ctx.store, "run", Keyword.put(ctx.options, :workspace, workspace))
    end

    alias_path = Path.join(ctx.root, "source-alias")
    File.ln_s!(ctx.path, alias_path)

    for workspace <- [ctx.path, ctx.repo, alias_path] do
      assert {:error, :ticket_mr_controller_source_overlap} = TicketJiraOperation.start_implementation(ctx.store, "run", Keyword.put(ctx.options, :workspace, workspace))
    end

    refute_received :jira_scope_open
    assert Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
  end

  test "missing checkout and malformed session fail before any Jira read or mutation", ctx do
    invalid_scope = fn _workspace, callback -> callback.(nil) end
    assert {:error, :ticket_jira_session_unproven} = TicketJiraOperation.start_implementation(ctx.store, "run", Keyword.put(ctx.options, :jira_session, invalid_scope))
    assert Process.get(:jira_reads, 0) == 0
    {:ok, _} = RunLedger.update(ctx.store, "run", %{worktree: nil})
    assert {:error, :ticket_source_checkout_not_admitted} = step(ctx)
    assert Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
  end

  test "lost result is reconciled across restart and never blindly repeats an unobserved transition", ctx do
    assert {:error, :ticket_jira_operation_missing} = TicketJiraOperation.reconcile(ctx.store, "run", ctx.options)
    refute_received :jira_scope_open
    Process.put(:jira_mode, :lost_before_apply)
    assert {:error, :ticket_jira_effect_not_observed} = step(ctx)
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "FIRST_UNCERTAIN"
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access")["released_at"] == nil
    trace = Path.join(ctx.root, "runtime-fixture.trace")
    observation = File.read!(trace)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, %{launches: [], events: deferred}} = recover(%{ctx | store: reopened})
      assert Enum.any?(deferred, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_jira_effect_not_observed"))
      assert {:error, :ticket_jira_effect_not_observed} = TicketJiraOperation.reconcile(reopened, "run", ctx.options)
      assert File.read!(trace) == observation
      assert length(Process.get(:jira_calls)) == 1
      Process.put(:jira_snapshot, Map.put(Process.get(:jira_snapshot), "status", "In Dev"))
      assert {:error, :ticket_jira_effect_not_observed} = TicketJiraOperation.reconcile(reopened, "run", ctx.options)
      assert Store.one!(reopened, "SELECT phase FROM ticket_jira_effects")["phase"] == "SECOND_PENDING"
      assert {:ok, unchanged} = RunLedger.get(reopened, "run")
      assert unchanged == ctx.run
      assert length(Process.get(:jira_calls)) == 1
      assert File.read!(trace) == observation
      assert {:ok, %{status: "WRITER_ADMITTED"}} = step(%{ctx | store: reopened})
      assert length(Process.get(:jira_calls)) == 2
      assert Enum.count(Process.get(:jira_calls), fn {tool, _} -> tool == "jira_transition_issue" end) == 1
    after
      GenServer.stop(reopened)
    end
  end

  test "lost acknowledgement after application and already observed state both avoid repeat mutations", ctx do
    Process.put(:jira_mode, :lost_after_apply)
    assert {:ok, %{status: "WRITER_ADMITTED", run: admitted}} = step(ctx)
    assert admitted["workspace_state"] == "MATERIALIZED"
    assert length(Process.get(:jira_calls)) == 2
  end

  test "already In Dev and ai-running requires no transition or label tool", ctx do
    original = Process.get(:jira_snapshot)
    Process.put(:jira_snapshot, Map.put(original, "status", "In Dev"))

    Process.put(:jira_before_read, fn count ->
      if count == 2, do: Process.put(:jira_snapshot, Map.put(Process.get(:jira_snapshot), "status", "To Do"))
    end)

    assert {:error, :ticket_jira_status_changed} = step(ctx)
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "FIRST_PENDING"
    assert Process.get(:jira_calls) == []
    assert {:ok, unchanged} = RunLedger.get(ctx.store, "run")
    assert unchanged == ctx.run
    Process.delete(:jira_before_read)
    Process.put(:jira_snapshot, Map.merge(Process.get(:jira_snapshot), %{"status" => "In Dev", "labels" => ~w(ai-running repo-grail)}))
    Process.put(:jira_transitions, [])
    assert {:ok, %{status: "WRITER_ADMITTED"}} = step(ctx)
    assert Process.get(:jira_calls) == []
  end

  test "the installed Jira transition shape admits the observed In Dev action with a numeric ID", ctx do
    Process.put(:jira_transitions, [%{"id" => 21, "name" => "To Do"}, %{"id" => 31, "name" => "In Dev"}])
    assert {:ok, %{status: "WRITER_ADMITTED"}} = step(ctx)
    assert [{"jira_transition_issue", %{"issue_key" => "PPL-123", "transition_id" => "31"}}, {"jira_update_factory_labels", _}] = Process.get(:jira_calls)
    assert Process.get(:jira_snapshot)["status"] == "In Dev"
  end

  test "explicit transition destinations override names and ambiguous or invalid IDs remain unissued", ctx do
    for transitions <- [
          [%{"id" => 31, "name" => "In Dev", "to_status" => "Done"}],
          [%{"id" => 31, "name" => "In Dev"}, %{"id" => 32, "name" => "In Dev"}],
          [%{"id" => 0, "name" => "In Dev"}],
          [%{"id" => "31/invalid", "name" => "In Dev"}]
        ] do
      Process.put(:jira_transitions, transitions)
      assert {:error, :ticket_jira_in_dev_transition_unproven} = step(ctx)
      assert Process.get(:jira_calls) == []
    end
  end

  test "an ignored first-effect observation retains maintenance ownership until exact retry", ctx do
    Process.put(:jira_snapshot, Map.merge(Process.get(:jira_snapshot), %{"status" => "In Dev", "labels" => ~w(ai-running repo-grail)}))
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    tasks_before = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows
    source_file = Path.join(ctx.path, "fixture.txt")
    {git_dir, 0} = System.cmd("git", ["-C", ctx.path, "rev-parse", "--absolute-git-dir"])
    git_dir = String.trim(git_dir)
    source_bytes = File.read!(source_file)
    index_bytes = File.read!(Path.join(git_dir, "index"))

    protected_state = fn ->
      %{
        runs: Store.query!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'").rows,
        tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
        evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
        access: Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows,
        journal: Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE run_id = 'run' ORDER BY operation_key").rows,
        review_bases: Store.query!(ctx.store, "SELECT * FROM ticket_review_bases WHERE run_id = 'run' ORDER BY run_id").rows,
        checkout_intents: Store.query!(ctx.store, "SELECT * FROM ticket_checkout_intents WHERE run_id = 'run' ORDER BY run_id").rows,
        desktop_requests: Store.query!(ctx.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
        commands: Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
        inputs: Store.query!(ctx.store, "SELECT * FROM ticket_chat_inputs ORDER BY input_key").rows,
        questions: Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows,
        events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
      }
    end

    Store.query!(
      ctx.store,
      "CREATE TRIGGER u11_ignore_first_effect_observation BEFORE UPDATE OF phase ON ticket_jira_effects WHEN OLD.run_id = 'run' AND OLD.operation = 'START_IMPLEMENTATION' AND OLD.phase = 'FIRST_PENDING' AND NEW.phase = 'SECOND_PENDING' BEGIN SELECT RAISE(IGNORE); END"
    )

    try do
      assert {:error, :ticket_jira_effect_limit} = step(ctx)
      assert Process.get(:jira_calls) == []
      assert Process.get(:jira_snapshot)["status"] == "In Dev"
      assert Process.get(:jira_snapshot)["labels"] == ~w(ai-running repo-grail)
      assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
      assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == tasks_before
      assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows == evidence_before
      assert File.read!(source_file) == source_bytes
      assert File.read!(Path.join(git_dir, "index")) == index_bytes

      pending = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE run_id = 'run'")
      assert pending["phase"] == "FIRST_PENDING"
      assert is_nil(pending["first_receipt_json"])
      assert is_nil(pending["second_receipt_json"])
      access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' AND mode = 'MAINTENANCE'")
      assert is_map(access)
      assert is_nil(access["released_at"])
      assert_received :jira_scope_open
      assert_received :jira_scope_closed

      prepared_state = protected_state.()
      assert {:error, :ticket_jira_effect_limit} = step(ctx)
      assert protected_state.() == prepared_state
      assert Process.get(:jira_calls) == []
      assert File.read!(source_file) == source_bytes
      assert File.read!(Path.join(git_dir, "index")) == index_bytes
      assert_received :jira_scope_open
      assert_received :jira_scope_closed
    after
      Store.query!(ctx.store, "DROP TRIGGER u11_ignore_first_effect_observation")
    end

    assert {:ok, %{status: "WRITER_ADMITTED", run: admitted, model_invoked: false}} = step(ctx)
    assert admitted["state"] == "WRITING"
    assert Process.get(:jira_calls) == []
    assert Process.get(:jira_snapshot)["status"] == "In Dev"
    assert Process.get(:jira_snapshot)["labels"] == ~w(ai-running repo-grail)
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == tasks_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows == evidence_before
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects WHERE run_id = 'run'")["phase"] == "COMPLETE"
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access WHERE run_id = 'run' AND mode = 'MAINTENANCE'")["released_at"] != nil
    assert File.read!(source_file) == source_bytes
    assert File.read!(Path.join(git_dir, "index")) == index_bytes
  end

  test "ambiguous transitions and missing capability reject before any uncertain claim", ctx do
    Process.put(:jira_transitions, [%{"id" => "11", "to_status" => "In Dev"}, %{"id" => "12", "to_status" => "In Dev"}])
    assert {:error, :ticket_jira_in_dev_transition_unproven} = step(ctx)
    assert Store.query!(ctx.store, "SELECT * FROM ticket_jira_effects").rows == []
    Process.put(:jira_transitions, [%{"id" => "11", "to_status" => "In Dev"}])
    Process.put(:jira_capability, {:error, :missing_capability})
    assert {:error, :missing_capability} = step(ctx)
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "FIRST_PENDING"
    assert Process.get(:jira_calls) == []
  end

  test "human block after effects prevents admission and retains the reservation", ctx do
    Process.put(:jira_after_labels, fn ->
      snapshot = Process.get(:jira_snapshot)
      Process.put(:jira_snapshot, Map.put(snapshot, "labels", ["ai-blocked" | snapshot["labels"]]))
    end)

    assert {:error, :ticket_jira_not_dispatchable} = step(ctx)
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access")["released_at"] == nil
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "SECOND_UNCERTAIN"
  end

  test "capacity lost after Jira effects rolls back admission and retries without repeating effects", ctx do
    options = Keyword.update!(ctx.options, :capacity_policy, &put_in(&1["capacity"]["maximum_writers"], 1))
    ctx = %{ctx | options: options}
    tasks = Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows

    Process.put(:jira_after_labels, fn ->
      {:ok, _} = RunLedger.register(ctx.store, %{run_id: "competing", issue_key: "PPL-456", kind: "DELIVERY", state: "WRITING", repo_key: "grail", repo_path: ctx.repo})
    end)

    assert {:error, :insufficient_writer_capacity} = step(ctx)
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    journal = Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE run_id = 'run'")
    access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'")
    assert journal["phase"] == "COMPLETE"
    assert is_nil(access["released_at"])
    calls = Process.get(:jira_calls)
    assert length(calls) == 2
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == tasks

    Store.query!(ctx.store, "CREATE TRIGGER fail_recovery_release BEFORE UPDATE OF released_at ON workspace_access BEGIN SELECT RAISE(ABORT, 'fixture recovery release failure'); END")
    assert_raise Exqlite.Error, ~r/fixture recovery release failure/, fn -> TicketJiraOperation.reconcile(ctx.store, "run", options) end
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'") == access
    assert {:ok, ^current} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "DROP TRIGGER fail_recovery_release")
    stale = Map.merge(journal, %{"operation_key" => "historical:" <> journal["operation_key"], "created_at" => "2000-01-01T00:00:00Z"})
    columns = Map.keys(stale)
    placeholders = Enum.map_join(columns, ",", fn _ -> "?" end)
    Store.query!(ctx.store, "INSERT INTO ticket_jira_effects(#{Enum.join(columns, ",")}) VALUES (#{placeholders})", Enum.map(columns, &stale[&1]))
    assert {:ok, %{launches: [], events: skipped}} = recover(%{ctx | options: options})
    assert Enum.any?(skipped, &(&1.event == "TICKET_DEFERRED" and &1.detail == ":ticket_recovery_operation_changed"))
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'") == access
    {:ok, reopened} = Store.start_link(database: ctx.database)

    recovered =
      try do
        assert {:ok, %{launches: [], events: events}} = recover(%{ctx | store: reopened, options: options})
        events
      after
        GenServer.stop(reopened)
      end

    assert Enum.any?(recovered, &(&1.event == "TICKET_JIRA_OPERATION_RECONCILED"))
    Store.query!(ctx.store, "DELETE FROM ticket_jira_effects WHERE operation_key = ?", [stale["operation_key"]])
    assert {:ok, reconciled} = RunLedger.get(ctx.store, "run")
    assert reconciled == ctx.run
    assert Process.get(:jira_calls) == calls
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == tasks
    released_once = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'")
    assert is_binary(released_once["released_at"])
    assert {:ok, %{run: ^reconciled}} = TicketJiraOperation.reconcile(ctx.store, "run", options)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'") == released_once
    assert {:ok, %{launches: [], events: []}} = recover(%{ctx | options: options})
    {:ok, _} = RunLedger.update(ctx.store, "competing", %{state: "FAILED"})
    assert {:ok, %{status: "WRITER_ADMITTED", model_invoked: false}} = step(ctx)
    assert Process.get(:jira_calls) == calls
    assert Store.one!(ctx.store, "SELECT * FROM ticket_jira_effects WHERE run_id = 'run'") == journal
    released = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run'")
    assert released["generation"] == access["generation"]
    assert is_binary(released["released_at"])
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == tasks
  end

  test "fresh final observation must still contain both target effects even when ordinary authority remains valid", ctx do
    Process.put(:jira_before_read, fn count ->
      if count == 6 do
        Process.put(:jira_snapshot, Map.merge(Process.get(:jira_snapshot), %{"status" => "To Do", "labels" => ~w(ai-ready repo-grail)}))
      end
    end)

    assert {:error, :ticket_jira_target_state_changed} = step(ctx)
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_jira_effects")["phase"] == "COMPLETE"
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access")["released_at"] == nil
    assert length(Process.get(:jira_calls)) == 2
    Process.delete(:jira_before_read)
    assert {:error, :ticket_jira_effect_not_observed} = TicketJiraOperation.reconcile(ctx.store, "run", ctx.options)
    assert Store.one!(ctx.store, "SELECT released_at FROM workspace_access")["released_at"] == nil
    assert length(Process.get(:jira_calls)) == 2
  end

  defp step(ctx), do: TicketJiraOperation.start_implementation(ctx.store, "run", ctx.options)

  defp recover(ctx) do
    context = %{
      store: ctx.store,
      workspace_root: ctx.options[:workspace_root],
      factory: %{scope: "scope", ticket_supervisor: %{"enabled" => false}}
    }

    expected = Path.join([context.workspace_root, "factory-controller", "scope"])

    File.mkdir_p!(expected)

    scope = fn workspace, operation ->
      assert workspace == expected
      ctx.options[:jira_session].(workspace, operation)
    end

    options = [jira_reader: Reader, jira_connector: Connector, ticket_options: Keyword.put(ctx.options, :jira_session, scope)]
    Scheduler.reconcile_ticket_jira(context, options)
  end
end
