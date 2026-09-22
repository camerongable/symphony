defmodule SymphonyElixir.FactoryControllerTaskTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, ControllerTask, ControlServer, Store}
  alias SymphonyElixir.Tracker.Issue

  defmodule ActiveWriterStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:error, term()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      send(self(), {:stage_runner_opts, opts})

      {:error, {:response_error, %{"code" => -32_600, "message" => "thread existing-thread already has an active writer"}}}
    end
  end

  defmodule RecoveredStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      send(self(), {:stage_runner_opts, opts})
      opts[:on_thread_started].("replacement-thread")

      {:ok,
       %{
         thread_id: "replacement-thread",
         turn_id: "replacement-turn",
         output: %{"status" => "PASS"}
       }}
    end
  end

  setup do
    suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-controller-task-#{suffix}.sqlite")
    store = start_supervised!({Store, database: database})
    control_name = Module.concat(__MODULE__, "Control#{suffix}")

    factory = %{
      controller_codex_project_id: "project-grail",
      controller_mcp_startup_timeout_ms: 60_000,
      controller_required_mcp_servers: ["Jira", "GitLab"],
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240,
      models: %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"balanced" => "gpt-test"}},
        "roles" => %{
          "orchestrator" => %{
            "model_class" => "balanced",
            "reasoning_effort" => "medium"
          }
        }
      },
      scope: "assigned-jira-work",
      stale_task_minutes: 90
    }

    start_supervised!({ControlServer, store: store, factory: factory, name: control_name})

    ControlServer.record_controller_task(
      "existing-thread",
      "existing-turn",
      %{},
      control_name
    )

    on_exit(fn -> File.rm(database) end)
    %{control_name: control_name, factory: factory, store: store}
  end

  test "does not fork on the first active-writer conflict", context do
    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    assert {:error, _reason} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: ActiveWriterStageRunner
             )

    assert_received {:stage_runner_opts, opts}
    assert opts[:resume_thread_id] == "existing-thread"
    assert opts[:fork_on_active_writer] == false

    control = ControlServer.status(context.control_name)
    assert control["controller_writer_conflict_count"] == 1
    assert is_binary(control["controller_writer_conflict_since"])
  end

  test "allows one inactive stale-writer recovery and clears its conflict window", context do
    started_at = ~U[2026-09-22 17:00:00Z]

    assert %{result: "CONTROLLER_WRITER_CONFLICT_RECORDED"} =
             Control.record_controller_writer_conflict(
               context.store,
               %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id},
               "existing-thread",
               now: started_at
             )

    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    assert {:ok, %{"status" => "PASS"}} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: RecoveredStageRunner,
               now: DateTime.add(started_at, 91, :minute)
             )

    assert_received {:stage_runner_opts, opts}
    assert opts[:fork_on_active_writer] == true
    assert opts[:archive_forked_thread] == true

    control = ControlServer.status(context.control_name)
    assert control["controller_thread_id"] == "replacement-thread"
    assert control["controller_writer_conflict_count"] == 0
    assert control["controller_writer_conflict_since"] == nil
  end
end
