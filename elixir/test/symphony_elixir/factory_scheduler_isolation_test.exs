defmodule SymphonyElixir.FactorySchedulerIsolationTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketWorkerFixture

  alias SymphonyElixir.DesktopTicketLifecycleFixture.{NativeReader, WorkerServer}
  alias SymphonyElixir.Factory.{Contract, Controller, ControlServer, IntakeLedger, Observability, Policy, RunLedger, Scheduler, Store, TicketWorkerRunner, WorkerEvidence}

  defmodule JiraReader do
    def search(_query, _opts), do: {:ok, Process.get(:isolation_queue, [])}

    def issue(key, opts) do
      case Enum.find(Process.get(:isolation_queue, []), &(&1["key"] == key)) do
        nil ->
          {:ok, run} = RunLedger.get(opts[:store], "run")
          {:ok, active_snapshot(run)}

        snapshot ->
          {:ok, snapshot}
      end
    end

    def active_snapshot(run), do: run["snapshot_json"] |> Jason.decode!() |> Map.merge(%{"labels" => ["ai-running", "repo-grail"], "status" => "In Dev"})
  end

  defmodule UnavailableJiraReader do
    def search(_query, _opts), do: {:error, :provider_unavailable}
  end

  setup :setup_fixture

  setup ctx do
    SymphonyElixir.TicketChatFixture.runtime_fixture(ctx.root)
    bind_parent(ctx)
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    Store.query!(ctx.store, "DELETE FROM factory_tasks WHERE task_key = 'writer'")
    supervisor = start_supervised!(Task.Supervisor)
    roles = ~w(orchestrator orchestrator-intake specification-author specification-critic feature-planner feature-writer change-verifier manual-validator explorer failure-triager)

    models = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"fast" => "gpt-6-luna"}},
      "roles" => Map.new(roles, &{&1, %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "medium"}})
    }

    factory =
      SymphonyElixir.Config.settings!().factory
      |> Map.merge(%{
        enabled: true,
        scope: "scope",
        dispatcher_id: "fixture-dispatcher",
        task_transport: "desktop_broker",
        models: models,
        manual_validation: %{},
        maximum_implementation_iterations: 20,
        maximum_writers: 2,
        maximum_validators: 2,
        maximum_specifiers: 2,
        writer_disk_gb: 20,
        stale_task_minutes: 90,
        cleanup: %{},
        ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123", "PPL-124"]},
        queue: %{"assignee" => "currentUser()", "statuses" => ["To Do", "In Dev"], "factory_labels" => ["ai-ready", "ai-running"]},
        repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master", "route_labels" => ["repo-grail"], "gitlab_project" => "fixture/source", "codex_project_id" => "fixture-project"}}
      })

    assert :ok = Policy.validate(factory)
    options = Keyword.merge(opts(ctx), workspace_root: Path.join(ctx.root, "workspaces"), app_server: WorkerServer, jira_reader: JiraReader, ticket_chat_reader: NativeReader)
    controller = %{store: ctx.store, task_supervisor: supervisor, recipient: self(), workspace_root: Path.join(ctx.root, "workspaces"), factory: factory, ticket_options: options}
    Map.merge(ctx, %{controller: controller, options: options})
  end

  test "provider and queue failures preserve unconsumed active evidence", ctx do
    request = finish_worker(ctx)
    assert {:error, :provider_unavailable} = Scheduler.tick(ctx.controller, jira_reader: UnavailableJiraReader)
    invalid = %{ctx.controller | factory: %{ctx.controller.factory | queue: %{}}}
    assert {:error, _} = Scheduler.tick(invalid, jira_reader: JiraReader)
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 0}} = RunLedger.get(ctx.store, "run")
    assert {:ok, nil} = IntakeLedger.get(ctx.store, "scope")
  end

  test "a real denial-write failure fails the tick without consuming active evidence", ctx do
    request = finish_worker(ctx)
    Process.put(:isolation_queue, [newcomer("## Manual Validation\n- Required: yes\n- Environment: cpp-test")])
    Store.query!(ctx.store, "CREATE TRIGGER reject_denial BEFORE UPDATE OF decisions_json ON intake_snapshots BEGIN SELECT RAISE(ABORT, 'synthetic denial failure'); END")
    assert_raise Exqlite.Error, fn -> Scheduler.tick(ctx.controller, jira_reader: JiraReader) end
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
    assert {:ok, %{decisions: %{}}} = IntakeLedger.get(ctx.store, "scope")
    assert [%{"issue_key" => "PPL-123"}] = RunLedger.list(ctx.store)
  end

  test "a changed stored intake observation remains fatal", ctx do
    Process.put(:isolation_queue, [newcomer("## Manual Validation\n- Required: yes\n- Environment: cpp-test")])
    Store.query!(ctx.store, "CREATE TRIGGER change_observation AFTER INSERT ON intake_snapshots BEGIN UPDATE intake_snapshots SET snapshot_json = '[]' WHERE scope = NEW.scope; END")
    assert {:error, :intake_observation_changed} = Scheduler.tick(ctx.controller, jira_reader: JiraReader)
    assert {:ok, %{snapshots: [], decisions: %{}}} = IntakeLedger.get(ctx.store, "scope")
    assert [%{"issue_key" => "PPL-123"}] = RunLedger.list(ctx.store)
  end

  for failure <- [:provider, :runtime, :configuration, :denial_write] do
    @tag capture_log: true, failure_mode: failure
    test "real Controller records FAILED health for #{failure} failure", %{failure_mode: mode} = ctx do
      snapshot = newcomer("## Manual Validation\n- Required: #{if mode == :runtime, do: "no", else: "yes\n- Environment: cpp-test"}")
      configure_controller_transport(ctx, snapshot, mode)

      policy =
        Map.merge(ctx.controller.factory.ticket_supervisor, %{
          "parent_output_root" => ctx.root,
          "broker_thread_id" => "019fa5b7-27fa-7660-ab47-7c3abb867c91",
          "ticket_cli_root" => File.cwd!(),
          "ticket_workflow" => SymphonyElixir.Workflow.workflow_file_path()
        })

      factory = Map.put(ctx.controller.factory, :ticket_supervisor, policy)
      factory = if mode == :configuration, do: Map.put(factory, :queue, %{}), else: factory

      if mode == :denial_write do
        Store.query!(ctx.store, "CREATE TRIGGER reject_controller_denial BEFORE UPDATE OF decisions_json ON intake_snapshots BEGIN SELECT RAISE(ABORT, 'synthetic controller denial failure'); END")
      end

      control = start_supervised!({ControlServer, store: ctx.store, factory: factory, name: nil})
      assert {:ok, _} = ControlServer.activate(factory.dispatcher_id, control)
      settings = %{factory: factory, polling: %{interval_ms: 60_000}}
      controller = start_supervised!({Controller, settings: settings, store: ctx.store, control_server: control, task_supervisor: ctx.controller.task_supervisor, name: nil})
      assert :ok = Controller.reconcile_now(controller)
      health = await_failed_health(control)
      assert health.consecutive_failures >= 1

      expected = %{
        provider: "mcp_tool_error",
        runtime: "delivery_registration_failed:worker_runtime_identity_unproven",
        configuration: "missing_queue_setting:tick_failed",
        denial_write: "Exqlite.Error"
      }

      assert health.last_error == expected[mode]
      assert [%{"issue_key" => "PPL-123"}] = RunLedger.list(ctx.store)
      assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 0}} = RunLedger.get(ctx.store, "run")
      assert ControlServer.status(control)["tick_id"] == nil
    end
  end

  for order <- [:newcomer_first, :active_first] do
    test "default disabled validation denies the newcomer while consuming active evidence with #{order}", ctx do
      assert ctx.controller.factory.manual_validation == %{}
      request = finish_worker(ctx)
      assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, request)
      {:ok, run} = RunLedger.get(ctx.store, "run")
      newcomer = newcomer("## Manual Validation\n- Required: yes\n- Environment: cpp-test")
      active = JiraReader.active_snapshot(run)
      queue = if unquote(order) == :newcomer_first, do: [newcomer, active], else: [active, newcomer]
      Process.put(:isolation_queue, queue)
      before = admission_rows(ctx.store)

      assert {:ok, %{launches: [], events: events}} = Scheduler.tick(ctx.controller, jira_reader: JiraReader)
      assert Enum.any?(events, &(&1.issue_key == "PPL-124" and &1.event == "INTAKE_BLOCKED" and &1.detail == :manual_validation_disabled))
      assert Enum.any?(events, &(&1.issue_key == "PPL-123" and &1.event == "TICKET_ADOPTED"))
      assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.get(ctx.store, request)
      assert {:ok, %{"state" => "VERIFYING", "implementation_iteration" => 1}} = RunLedger.get(ctx.store, "run")
      assert [%{"issue_key" => "PPL-123"}] = RunLedger.list(ctx.store)
      assert admission_rows(ctx.store) == before
      assert Store.query!(ctx.store, "SELECT DISTINCT run_id FROM factory_tasks").rows == [["run"]]
      assert Store.query!(ctx.store, "SELECT DISTINCT run_id FROM workspace_access").rows == [["run"]]
      assert {:ok, %{decisions: %{"PPL-124" => %{"code" => "manual_validation_disabled"}}}} = IntakeLedger.get(ctx.store, "scope")
      control = start_supervised!({ControlServer, store: ctx.store, factory: ctx.controller.factory, name: nil})
      visible = Observability.snapshot(settings: %{factory: ctx.controller.factory}, store: ctx.store, control_server: control)
      assert Enum.any?(visible.intake.issues, &(&1.issue_key == "PPL-124" and &1.local_state == "INTAKE_BLOCKED" and &1.admission_error.code == "manual_validation_disabled"))
    end
  end

  defp finish_worker(ctx) do
    assert {:ok, %{status: "LAUNCHED", launch: launch}} = Scheduler.ticket_step(ctx.controller, "run", ctx.options)
    key = launch.task_key
    assert_receive {:factory_task_started, ^key, _}, 15_000
    assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000
    [evidence] = WorkerEvidence.pending(ctx.store, "run")
    evidence["request_key"]
  end

  defp newcomer(markdown) do
    contract = Contract.bind("PPL-124", 1, markdown)

    %{
      "key" => "PPL-124",
      "id" => "issue-124",
      "summary" => "Synthetic newcomer",
      "description" => "",
      "project_key" => "PPL",
      "status" => "To Do",
      "labels" => ["ai-ready", "repo-grail"],
      "comments" => [%{"text" => Contract.draft_comment(contract)}, %{"text" => Contract.specification_skill_authorization_marker(contract)}]
    }
  end

  defp configure_controller_transport(ctx, snapshot, mode) do
    command = Path.join(ctx.root, "controller-runtime")
    issue = Map.update!(snapshot, "comments", &Enum.with_index(&1, fn comment, n -> Map.put(comment, "id", "comment-#{n}") end))
    tool = fn data -> Jason.encode!(%{"id" => 14, "result" => %{"structuredContent" => data}}) end
    search = if mode == :provider, do: Jason.encode!(%{"id" => 14, "result" => %{"isError" => true}}), else: tool.(%{"issues" => [issue]})

    initialize =
      if mode == :runtime,
        do: %{},
        else: %{
          "codexHome" => System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
          "platformFamily" => "unix",
          "platformOs" => "macos",
          "userAgent" => "symphony-orchestrator/0.160.0 (fixture)"
        }

    File.write!(command, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '#{Jason.encode!(%{"id" => 1, "result" => initialize})}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"synthetic-controller"}}}'; printf '%s\\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"Jira","status":"ready"}}' ;;
        *'"method":"mcpServer/tool/call"'*'"tool":"jira_search"'*) printf '%s\\n' '#{search}' ;;
        *'"method":"mcpServer/tool/call"'*) printf '%s\\n' '#{tool.(issue)}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
    done
    """)

    File.chmod!(command, 0o700)
    workflow = SymphonyElixir.Workflow.workflow_file_path()
    SymphonyElixir.TestSupport.write_workflow_file!(workflow, codex_command: "#{command} app-server", workspace_root: Path.join(ctx.root, "workspaces"), codex_read_timeout_ms: 1_000)
    {:ok, loaded} = SymphonyElixir.Workflow.load(workflow)
    config = Map.put(loaded.config, "factory", %{"database" => ctx.database})
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic controller transport.\n")
    SymphonyElixir.Workflow.set_workflow_file_path(workflow)
  end

  defp await_failed_health(control, attempts \\ 1_000)
  defp await_failed_health(_control, 0), do: flunk("Controller did not record failed tick health")

  defp await_failed_health(control, attempts) do
    case ControlServer.status(control)["tick_health"] do
      %{status: "FAILED"} = health ->
        health

      _ ->
        receive do
        after
          10 -> await_failed_health(control, attempts - 1)
        end
    end
  end

  defp admission_rows(store) do
    [
      Store.query!(store, "SELECT chat_key, issue_key, cwd, thread_id FROM ticket_chats").rows,
      Store.query!(store, "SELECT * FROM ticket_chat_runs").rows,
      Store.query!(store, "SELECT * FROM desktop_requests WHERE action = 'CREATE'").rows,
      Store.query!(store, "SELECT * FROM ticket_checkout_intents").rows
    ]
  end
end
