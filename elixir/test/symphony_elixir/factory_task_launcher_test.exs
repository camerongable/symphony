defmodule SymphonyElixir.FactoryTaskLauncherTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{DesktopRequest, RunLedger, Store, TaskLauncher, TaskLedger}
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      opts[:on_thread_started].("thread-visible")

      {:ok,
       %{
         thread_id: "thread-visible",
         turn_id: "turn-1",
         output: %{
           "status" => "PLANNED",
           "plan_markdown" => "plan",
           "blockers" => [],
           "required_apps" => opts[:required_apps],
           "project_root" => opts[:project_root],
           "required_mcp_servers" => opts[:required_mcp_servers],
           "mcp_startup_timeout_ms" => opts[:mcp_startup_timeout_ms]
         }
       }}
    end
  end

  defmodule BlockingStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      opts[:on_thread_started].("thread-visible")

      receive do
        :release ->
          {:ok, %{thread_id: "thread-visible", turn_id: "turn-1", output: %{"status" => "PLANNED"}}}
      end
    end
  end

  defmodule ConsumedBeforeReturnStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      opts[:on_thread_started].("thread-visible")
      {:ok, _task} = TaskLedger.update(opts[:store], opts[:target_key], %{status: "CONSUMED"})
      {:ok, %{thread_id: "thread-visible", turn_id: "turn-1", output: %{"status" => "PLANNED"}}}
    end
  end

  defmodule ReconciliationStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:error, term()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      opts[:on_thread_started].("thread-visible")
      {:error, {:desktop_request_reconciliation_required, "COMPLETED_TURN_EMPTY_NO_SCHEMA_RESULT"}}
    end
  end

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "factory-launcher-#{token}.sqlite")
    {:ok, store} = Store.start_link(database: database)
    {:ok, supervisor} = Task.Supervisor.start_link()

    {:ok, %{run: run}} =
      RunLedger.register(store, %{
        run_id: "run-1",
        issue_key: "PPL-123",
        kind: "DELIVERY",
        state: "PLANNING",
        repo_path: "/tmp/grail"
      })

    policy = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"deep" => "gpt-test"}},
      "roles" => %{
        "feature-planner" => %{
          "provider" => "codex",
          "model_class" => "deep",
          "reasoning_effort" => "high"
        }
      }
    }

    %{store: store, supervisor: supervisor, run: run, policy: policy}
  end

  test "records the exact model route before launching a visible task", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Plan work"}

    assert {:ok, launch} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "plan it",
               %{"type" => "object"},
               task_key: "run-1:planner:1",
               stage: "PLANNING",
               role: "feature-planner",
               model_policy: context.policy,
               recipient: self(),
               project_id: "project-grail",
               project_root: "/tmp/grail",
               section_id: "section-factory",
               thread_name: "PPL-123 planning",
               required_apps: ["polaris-app"],
               required_mcp_servers: ["deployment-mcp"],
               mcp_startup_timeout_ms: 45_000,
               stage_runner: FakeStageRunner
             )

    assert launch.route.model == "gpt-test"
    assert_receive {:factory_task_started, "run-1:planner:1", "thread-visible"}

    assert_receive {:factory_task_finished, "run-1:planner:1", {:ok, result}}
    assert result.output["status"] == "PLANNED"
    assert result.output["required_apps"] == ["polaris-app"]
    assert result.output["project_root"] == "/tmp/grail"
    assert result.output["required_mcp_servers"] == ["deployment-mcp"]
    assert result.output["mcp_startup_timeout_ms"] == 45_000

    assert {:ok, task} = TaskLedger.get(context.store, "run-1:planner:1")
    assert task["status"] == "COMPLETE"
    assert task["thread_id"] == "thread-visible"
    assert task["model"] == "gpt-test"
    assert task["codex_project_id"] == "project-grail"
    assert task["codex_section_id"] == "section-factory"

    assert [%{"event_type" => "MODEL_ROUTE_RECORDED"} | _rest] =
             RunLedger.events(context.store, "run-1") |> Enum.drop(1)
  end

  test "an uncertain Desktop result keeps the same task waiting for broker reconciliation", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Plan work"}
    task_key = "run-1:planner:reconcile"

    assert {:ok, _launch} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "plan it",
               %{"type" => "object"},
               task_key: task_key,
               stage: "PLANNING",
               role: "feature-planner",
               model_policy: context.policy,
               recipient: self(),
               project_id: "project-grail",
               project_root: "/tmp/grail",
               thread_name: "PPL-123 planning",
               stage_runner: ReconciliationStageRunner
             )

    assert_receive {:factory_task_finished, ^task_key, {:error, {:desktop_request_reconciliation_required, "COMPLETED_TURN_EMPTY_NO_SCHEMA_RESULT"}}}

    assert {:ok, %{"status" => "WAITING_FOR_BROKER", "thread_id" => "thread-visible"}} =
             TaskLedger.get(context.store, task_key)
  end

  test "re-resolves and records the route before each persistent follow-up", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Implement work"}
    task_key = "run-1:writer"

    launch_opts = [
      task_key: task_key,
      stage: "WRITING",
      role: "feature-planner",
      model_policy: context.policy,
      recipient: self(),
      project_id: "project-grail",
      project_root: "/tmp/grail",
      section_id: "section-factory",
      thread_name: "PPL-123 writer",
      stage_runner: FakeStageRunner,
      resume_terminal: true
    ]

    assert {:ok, first} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "first pass",
               %{"type" => "object"},
               launch_opts
             )

    assert_receive {:factory_task_finished, ^task_key, {:ok, _output}}
    Process.demonitor(first.ref, [:flush])

    updated_policy = put_in(context.policy, ["providers", "codex", "deep"], "gpt-test-2")

    assert {:ok, second} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "second pass",
               %{"type" => "object"},
               Keyword.put(launch_opts, :model_policy, updated_policy)
             )

    assert_receive {:factory_task_finished, ^task_key, {:ok, _output}}
    Process.demonitor(second.ref, [:flush])

    assert {:ok, task} = TaskLedger.get(context.store, task_key)
    assert task["model"] == "gpt-test-2"
    assert task["prompt_sha256"] != nil

    assert 2 ==
             context.store
             |> RunLedger.events("run-1")
             |> Enum.count(&(&1["event_type"] == "MODEL_ROUTE_RECORDED"))
  end

  test "a controller restart cannot launch a second turn while the first worker is live", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Plan work"}

    opts = [
      task_key: "run-1:planner:live",
      stage: "PLANNING",
      role: "feature-planner",
      model_policy: context.policy,
      recipient: self(),
      project_id: "project-grail",
      project_root: "/tmp/grail",
      thread_name: "PPL-123 planning",
      stage_runner: BlockingStageRunner,
      active_task_keys: MapSet.new(),
      resume_terminal: true
    ]

    assert {:ok, first} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "first pass",
               %{"type" => "object"},
               opts
             )

    assert_receive {:factory_task_started, "run-1:planner:live", "thread-visible"}
    assert TaskLauncher.active_owner("run-1:planner:live") == first.pid

    assert {:already_running, %{"thread_id" => "thread-visible"}} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "second pass",
               %{"type" => "object"},
               opts
             )

    assert {:ok, %{"status" => "RUNNING", "output_json" => nil}} =
             TaskLedger.get(context.store, "run-1:planner:live")

    send(first.pid, :release)
    assert_receive {:factory_task_finished, "run-1:planner:live", {:ok, _result}}
    assert_receive {:DOWN, ref, :process, pid, :normal}
    assert ref == first.ref
    assert pid == first.pid
    assert TaskLauncher.active_owner("run-1:planner:live") == nil
  end

  test "a late child result cannot resurrect a task consumed by the scheduler", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Plan work"}

    assert {:ok, launch} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "plan it",
               %{"type" => "object"},
               task_key: "run-1:planner:consumed",
               stage: "PLANNING",
               role: "feature-planner",
               model_policy: context.policy,
               recipient: self(),
               project_id: "project-grail",
               project_root: "/tmp/grail",
               thread_name: "PPL-123 planner",
               stage_runner: ConsumedBeforeReturnStageRunner
             )

    assert_receive {:factory_task_finished, "run-1:planner:consumed", {:ok, _result}}
    Process.demonitor(launch.ref, [:flush])

    assert {:ok, %{"status" => "CONSUMED", "output_json" => nil}} =
             TaskLedger.get(context.store, "run-1:planner:consumed")
  end

  test "an unresolved native request keeps the same prompt lineage across a scheduler retry", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Plan work"}
    task_key = "run-1:planner:pending"

    opts = [
      task_key: task_key,
      stage: "PLANNING",
      role: "feature-planner",
      model_policy: context.policy,
      recipient: self(),
      project_id: "project-grail",
      project_root: "/tmp/grail",
      thread_name: "PPL-123 planner",
      stage_runner: FakeStageRunner,
      resume_terminal: true
    ]

    assert {:ok, first} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "original prompt",
               %{"type" => "object"},
               opts
             )

    assert_receive {:factory_task_finished, ^task_key, {:ok, _result}}
    Process.demonitor(first.ref, [:flush])
    assert {:ok, original} = TaskLedger.get(context.store, task_key)

    assert {:ok, _request} =
             DesktopRequest.enqueue(context.store, %{
               request_key: "pending-followup",
               target_kind: "TASK",
               target_key: task_key,
               action: "FOLLOWUP",
               codex_project_id: "project-grail",
               model: "gpt-test",
               reasoning_effort: "high",
               title: "PPL-123 · Planner",
               prompt: "original prompt",
               cwd: "/tmp/workspace",
               existing_thread_id: "thread-visible",
               schema: %{"type" => "object"},
               metadata: %{"workspace_mode" => "CODEX_NATIVE"}
             })

    assert {:already_running, _task} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "changed prompt",
               %{"type" => "object"},
               Keyword.put(opts, :task_transport, "desktop_broker")
             )

    assert {:ok, %{"prompt_sha256" => prompt_sha256, "turn_id" => "turn-1"}} =
             TaskLedger.get(context.store, task_key)

    assert prompt_sha256 == original["prompt_sha256"]
  end

  test "a resumed task cannot be silently rebound to another Codex project or repository", context do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Plan work"}

    opts = [
      task_key: "run-1:planner:route",
      stage: "PLANNING",
      role: "feature-planner",
      model_policy: context.policy,
      recipient: self(),
      project_id: "project-grail",
      project_root: "/tmp/grail",
      thread_name: "PPL-123 planning",
      stage_runner: FakeStageRunner,
      resume_terminal: true
    ]

    assert {:ok, first} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "first pass",
               %{"type" => "object"},
               opts
             )

    assert_receive {:factory_task_finished, "run-1:planner:route", {:ok, _result}}
    Process.demonitor(first.ref, [:flush])

    assert {:error, :factory_task_route_mismatch} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "second pass",
               %{"type" => "object"},
               Keyword.put(opts, :project_id, "project-other")
             )

    assert {:error, :factory_run_repository_route_mismatch} =
             TaskLauncher.launch(
               context.store,
               context.supervisor,
               context.run,
               issue,
               "/tmp/workspace",
               "second pass",
               %{"type" => "object"},
               Keyword.put(opts, :project_root, "/tmp/other")
             )

    assert {:ok, %{"status" => "COMPLETE", "codex_project_id" => "project-grail", "thread_id" => "thread-visible"}} =
             TaskLedger.get(context.store, "run-1:planner:route")
  end
end
