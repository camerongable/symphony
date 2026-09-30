defmodule SymphonyElixir.FactoryAdminTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Admin, Control, DesktopRequest, RunLedger, Store}

  test "controls a factory through short-lived local database connections" do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-admin-#{token}.sqlite")

    factory = %{
      enabled: true,
      database: database,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240
    }

    assert {:ok, %{"status" => "PAUSED"}} = Admin.status(factory)
    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(factory)
    assert {:ok, %{"status" => "ACTIVE"}} = Admin.status(factory)

    assert {:ok, %{control: %{"status" => "ACTIVE"}, runs: [], tasks: []}} =
             Admin.overview(factory)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

    on_exit(fn -> File.rm(database) end)
  end

  test "fails closed when factory control is disabled" do
    assert {:error, :factory_disabled} = Admin.status(%{enabled: false})
  end

  test "one-shot retry preserves failed-run audit and refuses a live tick lease" do
    database = Path.join(System.tmp_dir!(), "symphony-retry-#{System.unique_integer([:positive])}.sqlite")

    factory = %{
      enabled: true,
      database: database,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240
    }

    {:ok, store} = Store.start_link(database: database)
    Control.initialize(store, %{scope: factory.scope, dispatcher_id: factory.dispatcher_id})
    Admin.activate(factory)

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "failed-spec",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED"
             })

    RunLedger.update(store, "failed-spec", %{failure_code: "factory_stage_output_invalid_json"})

    %{result: "ACQUIRED", tick_id: tick_id} =
      Control.acquire_tick(store, %{scope: factory.scope, dispatcher_id: factory.dispatcher_id}, factory.dispatcher_id)

    assert {:error, :live_tick_lease} = Admin.retry_specification(factory, "PPL-123")
    Control.release_tick(store, %{scope: factory.scope, dispatcher_id: factory.dispatcher_id}, factory.dispatcher_id, tick_id)

    assert {:ok, %{run_id: "failed-spec"}} = Admin.retry_specification(factory, "PPL-123")
    assert {:ok, failed} = RunLedger.get(store, "failed-spec")
    assert failed["failure_code"] == "factory_stage_output_invalid_json"
    assert {:error, :retry_already_requested} = Admin.retry_specification(factory, "PPL-123")

    GenServer.stop(store)
    on_exit(fn -> File.rm(database) end)
  end

  test "replaces only a paused controller with one proven no-Jira-call failure" do
    database = Path.join(System.tmp_dir!(), "symphony-controller-replace-#{System.unique_integer([:positive])}.sqlite")

    factory = %{
      enabled: true,
      database: database,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240
    }

    {:ok, store} = Store.start_link(database: database)
    config = %{scope: factory.scope, dispatcher_id: factory.dispatcher_id}
    Control.initialize(store, config)

    Control.record_controller_task(store, config, "old-controller", "old-turn", %{
      project_id: "projectless",
      model: "gpt-6-luna",
      reasoning_effort: "medium"
    })

    request_key = "desktop:failed-jira-read"

    assert {:ok, _pending} =
             DesktopRequest.enqueue(store, %{
               request_key: request_key,
               target_kind: "CONTROLLER",
               target_key: factory.scope,
               action: "FOLLOWUP",
               codex_project_id: "projectless",
               model: "gpt-6-luna",
               reasoning_effort: "medium",
               existing_thread_id: "old-controller",
               title: "FACTORY Orchestrator",
               prompt: "Read Jira",
               schema: %{"type" => "object"},
               cwd: "/tmp/factory-controller",
               metadata: %{"issue_key" => "QUEUE"}
             })

    assert {:ok, _claimed} = DesktopRequest.claim(store, request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request_key, "old-controller", "projectless")

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} =
             DesktopRequest.fail(store, request_key, "COMPLETED_TURN_EMPTY_NO_REQUIRED_JIRA_CALL")

    assert {:error, :controller_request_not_proven_safe_to_retire} =
             Admin.replace_controller(factory, "old-controller", "new-controller", "new-turn", "wrong-key")

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(factory)

    assert {:error, :controller_replacement_requires_paused_unleased_control} =
             Admin.replace_controller(factory, "old-controller", "new-controller", "new-turn", request_key)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

    assert {:ok, %{result: "CONTROLLER_REPLACED", control: control}} =
             Admin.replace_controller(factory, "old-controller", "new-controller", "new-turn", request_key)

    assert control["controller_thread_id"] == "new-controller"
    assert control["controller_turn_id"] == "new-turn"
    assert control["status"] == "PAUSED"

    assert {:ok, %{"status" => "FAILED", "failure_code" => "CONTROLLER_REPLACED_AFTER_PROVEN_NO_JIRA_CALL"}} =
             DesktopRequest.get(store, request_key)

    assert {:error, :controller_route_mismatch} =
             Admin.replace_controller(factory, "old-controller", "another-controller", "another-turn", request_key)

    GenServer.stop(store)
    on_exit(fn -> File.rm(database) end)
  end
end
