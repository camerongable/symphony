defmodule SymphonyElixir.FactoryTaskLauncherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLauncher, TaskLedger}
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
           "required_mcp_servers" => opts[:required_mcp_servers],
           "mcp_startup_timeout_ms" => opts[:mcp_startup_timeout_ms]
         }
       }}
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
        state: "PLANNING"
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
end
