defmodule SymphonyElixir.FactoryControllerTaskTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, ControllerTask, ControlServer, DesktopRequest, Store}
  alias SymphonyElixir.Tracker.Issue

  defmodule ActiveWriterStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:error, term()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      send(self(), {:stage_runner_opts, opts})

      {:error, {:response_error, %{"code" => -32_600, "message" => "thread existing-thread already has an active writer"}}}
    end
  end

  defmodule SuccessfulStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      send(self(), {:stage_runner_opts, opts})
      opts[:on_thread_created].("existing-thread")

      {:ok,
       %{
         thread_id: "existing-thread",
         turn_id: "next-turn",
         output: %{"status" => "PASS"}
       }}
    end
  end

  defmodule FailedReadinessStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:error, term()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      opts[:on_thread_created].("existing-thread")
      {:error, {:required_mcp_server_failed, "Jira", %{}}}
    end
  end

  defmodule CreatedThenFailedStageRunner do
    @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:error, term()}
    def run(_workspace, _issue, _prompt, _schema, opts) do
      opts[:on_thread_created].("new-controller-thread")
      {:error, {:required_mcp_server_failed, "Jira", %{}}}
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
      controller_writer_stale_minutes: 15,
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240,
      models: %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"fast" => "gpt-test-fast", "balanced" => "gpt-test"}},
        "roles" => %{
          "orchestrator" => %{
            "model_class" => "balanced",
            "reasoning_effort" => "medium"
          },
          "orchestrator-intake" => %{
            "model_class" => "fast",
            "reasoning_effort" => "low"
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

  test "a resumed task retains its saved identity when connector readiness fails", context do
    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    assert {:error, {:required_mcp_server_failed, "Jira", %{}}} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: FailedReadinessStageRunner
             )

    control = ControlServer.status(context.control_name)
    assert control["controller_thread_id"] == "existing-thread"
    assert control["controller_turn_id"] == "existing-turn"
  end

  test "a newly created controller task is saved before connector readiness fails", context do
    Store.query!(
      context.store,
      "UPDATE control SET controller_thread_id = NULL, controller_turn_id = NULL WHERE scope = ?",
      [context.factory.scope]
    )

    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    assert {:error, {:required_mcp_server_failed, "Jira", %{}}} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: CreatedThenFailedStageRunner
             )

    control = ControlServer.status(context.control_name)
    assert control["controller_thread_id"] == "new-controller-thread"
    assert is_nil(control["controller_turn_id"])
  end

  test "missing identity after an existing controller task fails closed", context do
    Store.query!(
      context.store,
      "UPDATE control SET controller_thread_id = NULL WHERE scope = ?",
      [context.factory.scope]
    )

    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    assert {:error, :controller_identity_missing} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: SuccessfulStageRunner
             )

    refute_received {:stage_runner_opts, _opts}
  end

  test "repeated stale-writer conflicts never authorize a new controller task", context do
    started_at = ~U[2026-09-22 17:00:00Z]

    assert %{result: "CONTROLLER_WRITER_CONFLICT_RECORDED"} =
             Control.record_controller_writer_conflict(
               context.store,
               %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id},
               "existing-thread",
               now: started_at
             )

    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    for minutes <- [16, 21] do
      assert {:error, {:controller_active_writer, _reason}} =
               ControllerTask.run(
                 context.factory,
                 "/tmp/factory-controller",
                 issue,
                 "Read Jira",
                 %{},
                 control_server: context.control_name,
                 stage_runner: ActiveWriterStageRunner,
                 now: DateTime.add(started_at, minutes, :minute)
               )

      assert_received {:stage_runner_opts, opts}
      assert opts[:resume_thread_id] == "existing-thread"
      assert opts[:fork_on_active_writer] == false
      assert opts[:archive_forked_thread] == false
    end

    control = ControlServer.status(context.control_name)
    assert control["controller_thread_id"] == "existing-thread"
    assert control["controller_writer_conflict_count"] == 3
    assert control["controller_writer_conflict_since"] == DateTime.to_iso8601(started_at)
  end

  test "routes read-only controller intake without changing the persistent task", context do
    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}

    assert {:ok, %{"status" => "PASS"}} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: SuccessfulStageRunner,
               model_role: "orchestrator-intake"
             )

    assert_received {:stage_runner_opts, opts}
    assert opts[:resume_thread_id] == "existing-thread"
    assert opts[:model] == "gpt-test-fast"
    assert opts[:reasoning_effort] == "low"

    control = ControlServer.status(context.control_name)
    assert control["controller_thread_id"] == "existing-thread"
    assert control["controller_model_role"] == "orchestrator-intake"
    assert control["controller_model"] == "gpt-test-fast"
  end

  test "desktop transport resumes the controller through one durable broker request", context do
    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}
    factory = Map.put(context.factory, :task_transport, "desktop_broker")

    schema = %{
      "type" => "object",
      "required" => ["status"],
      "properties" => %{"status" => %{"type" => "string"}}
    }

    call =
      Task.async(fn ->
        ControllerTask.run(
          factory,
          "/tmp/factory-controller",
          issue,
          "Read Jira",
          schema,
          control_server: context.control_name,
          store: context.store,
          required_tool_calls: [%{server: "Jira", tool: "jira_search"}]
        )
      end)

    request = wait_pending_request(context.store)
    assert request["target_kind"] == "CONTROLLER"
    assert request["action"] == "FOLLOWUP"
    assert request["existing_thread_id"] == "existing-thread"
    assert request["prompt"] =~ "return exactly one raw JSON object"
    assert request["prompt"] =~ Jason.encode!(schema)
    assert Jason.decode!(request["metadata_json"])["format_repair_attempts"] == 1

    assert {:ok, _claimed} = DesktopRequest.claim(context.store, request["request_key"])

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(context.store, request["request_key"], "existing-thread", "project-grail")

    assert {:ok, _completed} =
             DesktopRequest.complete(context.store, request["request_key"], %{
               thread_id: "existing-thread",
               turn_id: "next-controller-turn",
               output: %{
                 "result" => %{"status" => "PASS"},
                 "completed_tool_calls" => [%{"server" => "Jira", "tool" => "jira_search", "status" => "completed"}]
               }
             })

    assert {:ok, %{"status" => "PASS"}} = Task.await(call, 2_000)
    assert ControlServer.status(context.control_name)["controller_thread_id"] == "existing-thread"
    assert ControlServer.status(context.control_name)["controller_turn_id"] == "next-controller-turn"
    assert [] == DesktopRequest.list_pending(context.store)
  end

  test "desktop transport will not create an unbound replacement controller", context do
    Store.query!(
      context.store,
      "UPDATE control SET controller_thread_id = NULL, controller_turn_id = NULL WHERE scope = ?",
      [context.factory.scope]
    )

    issue = %Issue{id: "factory", identifier: "FACTORY-CONTROLLER", title: "Controller"}
    factory = Map.put(context.factory, :task_transport, "desktop_broker")

    assert {:error, :desktop_controller_thread_unbound} =
             ControllerTask.run(
               factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               store: context.store
             )

    assert [] == DesktopRequest.list_pending(context.store)
  end

  test "desktop transport rejects scoped Jira writes before enqueueing", context do
    issue = %Issue{id: "issue-720", identifier: "MT-720", title: "Controller"}
    factory = Map.put(context.factory, :task_transport, "desktop_broker")

    assert {:error, :controller_approval_transport_unavailable} =
             ControllerTask.run(
               factory,
               "/tmp/factory-controller",
               issue,
               "Post exact comment",
               %{},
               control_server: context.control_name,
               store: context.store,
               approval_policy: "on-request",
               allowed_mcp_tool_approvals: [
                 %{server: "Jira", tool: "jira_add_comment", issue_key: "MT-720", body_equals: "Approved marker"}
               ]
             )

    assert [] == DesktopRequest.list_pending(context.store)
  end

  defp wait_pending_request(store, attempts \\ 100)

  defp wait_pending_request(store, 0), do: flunk("controller request was not enqueued: #{inspect(DesktopRequest.list_pending(store))}")

  defp wait_pending_request(store, attempts) do
    case DesktopRequest.list_pending(store) do
      [request] ->
        request

      [] ->
        Process.sleep(10)
        wait_pending_request(store, attempts - 1)
    end
  end

  test "only the write controller can request one exact Jira comment approval", context do
    issue = %Issue{id: "issue-720", identifier: "MT-720", title: "Controller"}

    approval = %{
      server: "Jira",
      tool: "jira_add_comment",
      issue_key: "MT-720",
      body_equals: "Approved marker-720"
    }

    assert {:ok, %{"status" => "PASS"}} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Post exact comment",
               %{},
               control_server: context.control_name,
               stage_runner: SuccessfulStageRunner,
               approval_policy: "on-request",
               allowed_mcp_tool_approvals: [approval]
             )

    assert_received {:stage_runner_opts, opts}
    assert opts[:approval_policy] == "on-request"
    assert opts[:allowed_mcp_tool_approvals] == [approval]

    assert {:error, :invalid_controller_jira_approval} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Wrong issue",
               %{},
               control_server: context.control_name,
               stage_runner: SuccessfulStageRunner,
               approval_policy: "on-request",
               allowed_mcp_tool_approvals: [%{approval | issue_key: "MT-721"}]
             )

    refute_received {:stage_runner_opts, _opts}

    assert {:error, :controller_approval_for_non_write_role} =
             ControllerTask.run(
               context.factory,
               "/tmp/factory-controller",
               issue,
               "Read Jira",
               %{},
               control_server: context.control_name,
               stage_runner: SuccessfulStageRunner,
               model_role: "orchestrator-intake",
               approval_policy: "on-request",
               allowed_mcp_tool_approvals: [approval]
             )

    refute_received {:stage_runner_opts, _opts}
  end

  test "controller accepts only issue-bound label approvals and one exact comment alongside them", context do
    issue = %Issue{id: "issue-720", identifier: "MT-720", title: "Controller"}

    labels = %{
      server: "Jira",
      tool: "jira_update_issue",
      issue_key: "MT-720",
      labels_equals: ["ai-ready", "repo-grail"]
    }

    comment = %{
      server: "Jira",
      tool: "jira_add_comment",
      issue_key: "MT-720",
      body_equals: "Approved marker-720"
    }

    for approvals <- [[labels], [comment, labels]] do
      assert {:ok, %{"status" => "PASS"}} =
               ControllerTask.run(
                 context.factory,
                 "/tmp/factory-controller",
                 issue,
                 "Update exact issue fields",
                 %{},
                 control_server: context.control_name,
                 stage_runner: SuccessfulStageRunner,
                 approval_policy: "on-request",
                 allowed_mcp_tool_approvals: approvals
               )

      assert_received {:stage_runner_opts, opts}
      assert opts[:allowed_mcp_tool_approvals] == approvals
    end

    for approvals <- [[%{labels | issue_key: "MT-721"}], [labels, labels], [%{labels | labels_equals: []}]] do
      assert {:error, :invalid_controller_jira_approval} =
               ControllerTask.run(
                 context.factory,
                 "/tmp/factory-controller",
                 issue,
                 "Reject unscoped fields",
                 %{},
                 control_server: context.control_name,
                 stage_runner: SuccessfulStageRunner,
                 approval_policy: "on-request",
                 allowed_mcp_tool_approvals: approvals
               )

      refute_received {:stage_runner_opts, _opts}
    end
  end
end
