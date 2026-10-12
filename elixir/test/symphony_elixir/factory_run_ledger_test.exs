defmodule SymphonyElixir.FactoryRunLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Contract, Control, DesktopRequest, RunLedger, StageSchemas, Store, TaskLedger}

  @now ~U[2026-09-21 21:00:00Z]

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-ledger-#{token}.sqlite")
    connection = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)
    %{connection: connection}
  end

  test "registers, reads, updates, and lists a run", %{connection: connection} do
    attrs = %{
      run_id: "run-1",
      issue_key: "PPL-100",
      kind: "DELIVERY",
      state: "WRITING",
      dispatcher_id: "dispatcher-a",
      branch: "factory/PPL-100",
      factory_owned: true
    }

    assert {:ok, %{result: "REGISTERED", run: run}} = RunLedger.register(connection, attrs, now: @now)
    assert run["run_id"] == "run-1"
    assert run["factory_owned"] == 1
    assert run["attempt"] == 1

    assert {:ok, %{result: "UPDATED", run: updated}} =
             RunLedger.update(connection, "run-1", %{state: "VERIFYING", candidate_sha: "abc123"}, now: DateTime.add(@now, 10, :second))

    assert updated["state"] == "VERIFYING"
    assert updated["candidate_sha"] == "abc123"
    assert [%{"run_id" => "run-1"}] = RunLedger.list(connection, state: "VERIFYING")

    assert Enum.map(RunLedger.events(connection, "run-1"), & &1["event_type"]) == [
             "RUN_REGISTERED",
             "RUN_UPDATED"
           ]
  end

  test "persists explicit execution modes and normalizes missing and null modes to legacy", %{connection: connection} do
    assert {:ok, %{run: defaulted}} =
             RunLedger.register(connection, %{
               run_id: "mode-default",
               issue_key: "PPL-101",
               kind: "DELIVERY",
               state: "WRITING"
             })

    assert defaulted["execution_mode"] == "LEGACY"

    assert {:ok, %{run: %{"execution_mode" => "LEGACY"}}} =
             RunLedger.register(connection, %{
               "run_id" => "mode-null",
               "issue_key" => "PPL-102",
               "kind" => "DELIVERY",
               "state" => "WRITING",
               "execution_mode" => nil
             })

    assert {:ok, %{run: explicit}} =
             RunLedger.register(connection, %{
               run_id: "mode-supervisor",
               issue_key: "PPL-103",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               execution_mode: "TICKET_SUPERVISOR_V1"
             })

    assert explicit["execution_mode"] == "TICKET_SUPERVISOR_V1"
  end

  test "rejects invalid execution modes before inserting a run or event", %{connection: connection} do
    attrs = %{run_id: "mode-invalid", issue_key: "PPL-104", kind: "DELIVERY", state: "WRITING"}
    events_before = Store.one!(connection, "SELECT COUNT(*) AS count FROM events")["count"]

    assert {:error, :invalid_execution_mode} =
             RunLedger.register(connection, Map.put(attrs, :execution_mode, "UNKNOWN"))

    assert {:error, :unknown_run} = RunLedger.get(connection, "mode-invalid")
    assert Store.one!(connection, "SELECT COUNT(*) AS count FROM events")["count"] == events_before
  end

  test "execution mode cannot be updated, including with a mixed mutable-field update", %{connection: connection} do
    assert {:ok, %{run: before}} =
             RunLedger.register(connection, %{run_id: "mode-immutable", issue_key: "PPL-105", kind: "DELIVERY", state: "WRITING"})

    events_before = RunLedger.events(connection, "mode-immutable")

    assert {:error, :execution_mode_immutable} =
             RunLedger.update(connection, "mode-immutable", %{execution_mode: "TICKET_SUPERVISOR_V1"})

    assert {:error, :execution_mode_immutable} =
             RunLedger.update(connection, "mode-immutable", %{"state" => "FAILED", "execution_mode" => nil})

    assert {:ok, after_rejected_updates} = RunLedger.get(connection, "mode-immutable")
    assert after_rejected_updates == before
    assert RunLedger.events(connection, "mode-immutable") == events_before
  end

  test "V1 push handoff is controller-owned while legacy handoff updates remain compatible", %{connection: connection} do
    for {id, issue, mode} <- [{"native-push", "PPL-106", "TICKET_SUPERVISOR_V1"}, {"legacy-push", "PPL-107", "LEGACY"}] do
      attrs = %{run_id: id, issue_key: issue, kind: "DELIVERY", state: "PUSHING", execution_mode: mode}
      assert {:ok, _} = RunLedger.register(connection, attrs)
    end

    events = RunLedger.events(connection, "native-push")
    assert {:error, :candidate_handoff_controller_owned} = RunLedger.update(connection, "native-push", %{candidate_handoff: "fake", state: "MR_CREATING"})
    assert {:ok, %{"candidate_handoff" => nil, "state" => "PUSHING"}} = RunLedger.get(connection, "native-push")
    assert RunLedger.events(connection, "native-push") == events
    assert {:ok, %{run: %{"candidate_handoff" => "legacy"}}} = RunLedger.update(connection, "legacy-push", %{candidate_handoff: "legacy"})
  end

  test "enforces one active run per issue and kind", %{connection: connection} do
    attrs = %{run_id: "run-1", issue_key: "PPL-100", kind: "DELIVERY", state: "WRITING"}
    assert {:ok, _registered} = RunLedger.register(connection, attrs, now: @now)

    assert {:error, {:register_failed, _error}} =
             RunLedger.register(connection, %{attrs | run_id: "run-2"}, now: @now)
  end

  test "records every specialized model route", %{connection: connection} do
    assert {:ok, _registered} =
             RunLedger.register(
               connection,
               %{run_id: "run-1", issue_key: "PPL-100", kind: "DELIVERY", state: "WRITING"},
               now: @now
             )

    route = %{
      requested_role: "feature-writer",
      resolved_role: "feature-writer-high-risk",
      provider: "codex",
      model_class: "deep",
      model: "gpt-5.6-sol",
      reasoning_effort: "xhigh",
      routing_reason: "risk:high"
    }

    assert {:ok, recorded} =
             RunLedger.record_model_route(connection, "run-1", "delivery-writer", route,
               task_id: "task-1",
               now: @now
             )

    assert recorded.resolved_role == "feature-writer-high-risk"
    assert recorded.task_id == "task-1"
    assert recorded.route_id == 1

    assert List.last(RunLedger.events(connection, "run-1"))["event_type"] ==
             "MODEL_ROUTE_RECORDED"
  end

  test "consumes a failed specification retry exactly once in the same run", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})
    route = %{"repo_key" => "grail", "path" => "/tmp/grail", "base_branch" => "master", "codex_project_id" => "project-grail"}

    assert {:ok, _registered} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: "/tmp/grail",
               base_branch: "master"
             })

    assert {:ok, %{run_id: "failed-spec"}} =
             RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")

    assert RunLedger.specification_retry_pending?(connection, "failed-spec")

    assert {:ok, %{run: %{"run_id" => "failed-spec", "attempt" => 2, "state" => "SPEC_DRAFTING"}}} =
             RunLedger.resume_failed_specification(
               connection,
               "failed-spec",
               %{"key" => "PPL-100"},
               route,
               1,
               :local_retry
             )

    refute RunLedger.specification_retry_pending?(connection, "failed-spec")
    assert [%{"run_id" => "failed-spec"}] = RunLedger.list(connection)

    assert {:error, :active_issue_run} =
             RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")

    assert Enum.map(RunLedger.events(connection, "failed-spec"), & &1["event_type"]) == [
             "RUN_REGISTERED",
             "SPECIFICATION_RETRY_REQUESTED",
             "SPECIFICATION_RETRY_CONSUMED",
             "SPECIFICATION_RESUMED"
           ]

    assert {:ok, _failed_again} = RunLedger.update(connection, "failed-spec", %{state: "FAILED"})
    assert {:ok, _retry_again} = RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")
    assert RunLedger.specification_retry_pending?(connection, "failed-spec")

    assert {:ok, %{run: %{"attempt" => 3, "state" => "SPEC_DRAFTING"}}} =
             RunLedger.resume_failed_specification(connection, "failed-spec", %{"key" => "PPL-100"}, route, 1, :local_retry)

    refute RunLedger.specification_retry_pending?(connection, "failed-spec")
  end

  test "recovers a Jira-rendered draft without reopening its completed author", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})
    contract = Contract.bind("PPL-100", 2, "## Ticket Delivery Contract\n\n- AC-1: preserve bytes")

    original = %{
      "key" => "PPL-100",
      "summary" => "Exact contract",
      "description" => "Original request",
      "status" => "To Do",
      "labels" => ["repo-grail", "spec-needed"],
      "assignee" => %{"account_id" => "user-1", "display_name" => "Old name"},
      "comments" => []
    }

    rendered =
      contract
      |> Contract.draft_comment()
      |> String.replace("\n```\n|", "\n\n```\n|")
      |> String.replace("\n```\nAI FACTORY CONTRACT END", "\n```\n\nAI FACTORY CONTRACT END")

    current = %{
      original
      | "assignee" => %{"account_id" => "user-1", "display_name" => "New name"},
        "comments" => [
          %{"id" => "10", "text" => rendered},
          %{"id" => "11", "text" => "AI factory blocked: :jira*comment*readback_mismatch"}
        ]
    }

    route = %{"repo_key" => "grail", "path" => "/tmp/grail", "base_branch" => "master", "codex_project_id" => "project-grail"}

    assert {:ok, _registered} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: "/tmp/grail",
               base_branch: "master",
               spec_revision: 2,
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               snapshot_json: Jason.encode!(original)
             })

    assert {:ok, _updated} = RunLedger.update(connection, "failed-spec", %{failure_code: ":jira_comment_readback_mismatch"})
    assert {:ok, _task} = register_author_task(connection, "CONSUMED")
    assert {:ok, _retry} = RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")

    assert {:ok, %{run: %{"state" => "SPEC_WRITING", "spec_revision" => 2}}} =
             RunLedger.resume_failed_specification(connection, "failed-spec", current, route, 3, :local_retry)

    assert {:ok, %{"status" => "CONSUMED"}} = TaskLedger.get(connection, "failed-spec:specification-author")
  end

  test "recovers a critic falsely marked stale when its reviewed input is unchanged", %{connection: connection} do
    contract = Contract.bind("PPL-100", 2, "## Ticket Delivery Contract\n\n- AC-1: preserve bytes")

    original = %{
      "key" => "PPL-100",
      "summary" => "Exact contract",
      "description" => "Original request",
      "status" => "To Do",
      "labels" => ["repo-grail", "spec-needed"],
      "comments" => [%{"id" => "10", "text" => Contract.draft_comment(contract)}]
    }

    current =
      update_in(original["comments"], &(&1 ++ [%{"id" => "11", "text" => "AI factory blocked: :specification*input*changed*during*review"}]))

    assert {:ok, _registered} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: "/tmp/grail",
               base_branch: "master",
               spec_revision: 2,
               verifier_round: 1,
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               snapshot_json: Jason.encode!(original)
             })

    assert {:ok, _updated} =
             RunLedger.update(connection, "failed-spec", %{failure_code: ":specification_input_changed_during_review"})

    stage_prompt =
      "Controller-computed contract SHA-256: #{contract.sha256}\n\nUNTRUSTED JIRA SNAPSHOT:\n#{Jason.encode!(original)}\n\nCONTRACT UNDER REVIEW:\n#{contract.markdown}"

    prompt_sha = :sha256 |> :crypto.hash(stage_prompt) |> Base.encode16(case: :lower)
    task_key = "failed-spec:specification-critic:1"

    assert {:ok, _task} =
             TaskLedger.register(connection, %{
               task_key: task_key,
               run_id: "failed-spec",
               stage: "SPEC_REVIEW",
               role: "specification-critic",
               status: "STARTING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "test",
               codex_project_id: "project-grail",
               thread_id: "critic-thread",
               prompt_sha256: prompt_sha
             })

    review = %{"status" => "BLOCK", "findings" => ["Revise AC-7"], "required_questions" => ["Which notice?"]}
    request_key = "critic-review"

    assert {:ok, _request} =
             DesktopRequest.enqueue(connection, %{
               request_key: request_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "FOLLOWUP",
               codex_project_id: "project-grail",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               title: "PPL-100 · R1 · Specification Critic",
               prompt: "Factory request ID: #{request_key}\n\n#{stage_prompt}",
               cwd: "/tmp/grail",
               existing_thread_id: "critic-thread",
               schema: StageSchemas.for_stage(:specification_critic),
               metadata: %{"stage_prompt_sha256" => prompt_sha}
             })

    assert {:ok, _claimed} = DesktopRequest.claim(connection, request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(connection, request_key, "critic-thread", "project-grail")

    assert {:ok, _completed} =
             DesktopRequest.complete(connection, request_key, %{
               thread_id: "critic-thread",
               turn_id: "critic-turn",
               output: %{"result" => review, "completed_tool_calls" => []}
             })

    assert {:ok, _stale} =
             TaskLedger.update(connection, task_key, %{
               status: "STALE",
               turn_id: "critic-turn",
               output_json: Jason.encode!(review)
             })

    route = %{"repo_key" => "grail", "path" => "/tmp/grail", "base_branch" => "master"}

    assert {:ok, %{run: %{"state" => "SPEC_REVIEW"}}} =
             RunLedger.recover_stale_specification_critic(connection, "failed-spec", current, route)

    assert {:ok, %{"status" => "COMPLETE"}} = TaskLedger.get(connection, task_key)

    pass_review = %{"status" => "PASS", "findings" => [], "required_questions" => []}
    pass_key = "critic-pass"

    assert {:ok, _pending_pass} =
             DesktopRequest.enqueue(connection, %{
               request_key: pass_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "FOLLOWUP",
               codex_project_id: "project-grail",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               title: "PPL-100 · R1 · Specification Critic",
               prompt: "Factory request ID: #{pass_key}\n\n#{stage_prompt}",
               cwd: "/tmp/grail",
               existing_thread_id: "critic-thread",
               schema: StageSchemas.for_stage(:specification_critic),
               metadata: %{"stage_prompt_sha256" => prompt_sha}
             })

    assert {:ok, _claimed_pass} = DesktopRequest.claim(connection, pass_key)
    assert {:ok, _recorded_pass} = DesktopRequest.record_thread(connection, pass_key, "critic-thread", "project-grail")

    assert {:ok, _completed_pass} =
             DesktopRequest.complete(connection, pass_key, %{
               thread_id: "critic-thread",
               turn_id: "critic-pass-turn",
               output: %{"result" => pass_review, "completed_tool_calls" => []}
             })

    assert {:ok, _consumed} =
             TaskLedger.update(connection, task_key, %{
               status: "CONSUMED",
               turn_id: "critic-pass-turn",
               output_json: Jason.encode!(pass_review)
             })

    assert {:ok, _failed_gate} =
             RunLedger.update(connection, "failed-spec", %{
               state: "FAILED",
               failure_code: ":independent_critic_pass_not_proven"
             })

    current_after_gate =
      update_in(current["comments"], &(&1 ++ [%{"id" => "12", "text" => "AI factory blocked: :independent*critic*pass*not*proven"}]))

    assert {:ok, %{run: %{"state" => "SPEC_READY_WRITE"}}} =
             RunLedger.recover_stale_critic_authorization(connection, "failed-spec", current_after_gate, route)

    assert {:ok, %{"status" => "CONSUMED"}} = TaskLedger.get(connection, task_key)

    assert {:ok, _failed_connector} =
             RunLedger.update(connection, "failed-spec", %{
               state: "FAILED",
               failure_code: inspect({:required_mcp_servers_unavailable, ["Jira"]})
             })

    authorization = Contract.automatic_authorization_marker(contract, task_key, Contract.digest(Jason.encode!(pass_review)))
    partially_written = update_in(current_after_gate["comments"], &(&1 ++ [%{"id" => "13", "text" => authorization}]))

    assert {:error, :critic_authorization_recovery_unproven} =
             RunLedger.recover_unavailable_specification_authorization(
               connection,
               "failed-spec",
               Map.put(partially_written, "description", "changed input"),
               route
             )

    assert {:ok, %{run: %{"state" => "SPEC_READY_WRITE"}}} =
             RunLedger.recover_unavailable_specification_authorization(connection, "failed-spec", partially_written, route)

    assert {:ok, %{"status" => "CONSUMED"}} = TaskLedger.get(connection, task_key)
  end

  test "native transport replacement is atomic, route-bound, and consumes one retry", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})
    snapshot = %{"key" => "PPL-100", "description" => "Confirmed ticket input"}

    route = %{
      "repo_key" => "grail",
      "path" => "/tmp/grail",
      "base_branch" => "master",
      "codex_project_id" => "project-grail"
    }

    assert {:ok, _old_run} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: "/tmp/grail",
               base_branch: "master",
               runtime: "codex-app-server",
               factory_owned: true
             })

    assert {:ok, _old_task} = register_author_task(connection, "FAILED")

    assert {:ok, _retry} = RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")

    attrs = %{
      run_id: "native-spec",
      issue_key: "PPL-100",
      kind: "SPECIFICATION",
      state: "SPEC_DRAFTING",
      repo_key: "grail",
      repo_path: "/tmp/grail",
      base_branch: "master",
      runtime: "codex-desktop-broker",
      factory_owned: false,
      snapshot_json: Jason.encode!(snapshot)
    }

    assert {:error, :retry_repository_route_mismatch} =
             RunLedger.restart_failed_specification_native(
               connection,
               "failed-spec",
               snapshot,
               %{route | "path" => "/tmp/other"},
               attrs,
               :local_retry
             )

    assert {:error, :invalid_native_specification_replacement} =
             RunLedger.restart_failed_specification_native(
               connection,
               "failed-spec",
               snapshot,
               route,
               %{attrs | factory_owned: true},
               :local_retry
             )

    assert RunLedger.specification_retry_pending?(connection, "failed-spec")
    assert [%{"run_id" => "failed-spec"}] = RunLedger.list(connection)

    assert {:ok, %{run: %{"run_id" => "native-spec", "factory_owned" => 0}}} =
             RunLedger.restart_failed_specification_native(
               connection,
               "failed-spec",
               snapshot,
               %{route | "codex_project_id" => "project-other"},
               attrs,
               :local_retry
             )

    refute RunLedger.specification_retry_pending?(connection, "failed-spec")
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(connection, "failed-spec")
    assert length(RunLedger.list(connection)) == 2

    assert {:error, :retry_not_pending} =
             RunLedger.restart_failed_specification_native(
               connection,
               "failed-spec",
               snapshot,
               route,
               %{attrs | run_id: "another-native-spec"},
               :local_retry
             )

    assert length(RunLedger.list(connection)) == 2
  end

  test "native transport replacement refuses a task that became active after retry approval", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})
    snapshot = %{"key" => "PPL-100"}
    route = %{"repo_key" => "grail", "path" => "/tmp/grail", "base_branch" => "master"}

    assert {:ok, _old_run} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: "/tmp/grail",
               base_branch: "master",
               runtime: "codex-app-server",
               factory_owned: true
             })

    assert {:ok, _retry} = RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")
    assert {:ok, _active_task} = register_author_task(connection, "RUNNING")

    attrs = %{
      run_id: "native-spec",
      issue_key: "PPL-100",
      kind: "SPECIFICATION",
      state: "SPEC_DRAFTING",
      repo_key: "grail",
      repo_path: "/tmp/grail",
      base_branch: "master",
      runtime: "codex-desktop-broker",
      factory_owned: false,
      snapshot_json: Jason.encode!(snapshot)
    }

    assert {:error, :active_specification_task} =
             RunLedger.restart_failed_specification_native(
               connection,
               "failed-spec",
               snapshot,
               route,
               attrs,
               :local_retry
             )

    assert {:ok, _task} = TaskLedger.update(connection, "failed-spec:specification-author", %{status: "STALE"})

    assert {:error, :active_specification_task} =
             RunLedger.restart_failed_specification_native(
               connection,
               "failed-spec",
               snapshot,
               route,
               attrs,
               :local_retry
             )

    assert RunLedger.specification_retry_pending?(connection, "failed-spec")
    assert [%{"run_id" => "failed-spec"}] = RunLedger.list(connection)
  end

  test "rejects a changed Codex project without consuming the retry", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})

    assert {:ok, _run} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: "/tmp/grail",
               base_branch: "master"
             })

    assert {:ok, _task} = register_author_task(connection, "FAILED")
    assert {:ok, _retry} = RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")

    assert {:error, :retry_codex_project_mismatch} =
             RunLedger.resume_failed_specification(
               connection,
               "failed-spec",
               %{"key" => "PPL-100"},
               %{"repo_key" => "grail", "path" => "/tmp/grail", "base_branch" => "master", "codex_project_id" => "project-other"},
               1,
               :local_retry
             )

    assert RunLedger.specification_retry_pending?(connection, "failed-spec")
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(connection, "failed-spec")
  end

  test "rejects a retry while the author task is still active", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})

    assert {:ok, _run} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED"
             })

    assert {:ok, _task} = register_author_task(connection, "RUNNING")

    assert {:error, :active_specification_task} =
             RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")
  end

  test "rejects a retry while a Desktop follow-up is unresolved", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})

    assert {:ok, _run} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED"
             })

    assert {:ok, _task} = register_author_task(connection, "FAILED")

    assert {:ok, %{"status" => "PENDING"}} =
             DesktopRequest.enqueue(connection, %{
               request_key: "pending-followup",
               target_kind: "TASK",
               target_key: "failed-spec:specification-author",
               action: "FOLLOWUP",
               codex_project_id: "project-grail",
               model: "gpt-test",
               reasoning_effort: "medium",
               title: "PPL-100 · Specification Author",
               prompt: "Resume the same task",
               cwd: "/tmp/grail-worktree",
               existing_thread_id: "existing-thread"
             })

    assert {:error, :active_specification_task} =
             RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")
  end

  test "refuses a retry while another run owns the issue", %{connection: connection} do
    Control.initialize(connection, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"})

    assert {:ok, _registered} =
             RunLedger.register(connection, %{
               run_id: "failed-spec",
               issue_key: "PPL-100",
               kind: "SPECIFICATION",
               state: "FAILED"
             })

    assert {:ok, _registered} =
             RunLedger.register(connection, %{
               run_id: "active-delivery",
               issue_key: "PPL-100",
               kind: "DELIVERY",
               state: "WRITING"
             })

    assert {:error, :active_issue_run} =
             RunLedger.request_specification_retry(connection, "PPL-100", "assigned-jira-work")
  end

  test "fails closed for unknown runs and invalid updates", %{connection: connection} do
    assert {:error, :unknown_run} = RunLedger.get(connection, "missing")
    assert {:error, :no_run_fields} = RunLedger.update(connection, "missing", %{unknown: "value"})

    assert {:error, :unknown_run} =
             RunLedger.record_model_route(connection, "missing", "explorer", %{})
  end

  defp register_author_task(connection, status) do
    TaskLedger.register(connection, %{
      task_key: "failed-spec:specification-author",
      run_id: "failed-spec",
      stage: "SPEC_DRAFTING",
      role: "specification-author",
      status: status,
      model_provider: "codex",
      model_class: "test",
      model: "gpt-test",
      reasoning_effort: "medium",
      routing_reason: "test",
      codex_project_id: "project-grail",
      thread_id: "existing-thread",
      prompt_sha256: String.duplicate("a", 64)
    })
  end
end
