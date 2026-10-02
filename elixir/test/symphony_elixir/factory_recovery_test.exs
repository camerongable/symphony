defmodule SymphonyElixir.FactoryRecoveryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{
    Admin,
    Contract,
    Control,
    DesktopRequest,
    Recovery,
    RunLedger,
    Store,
    TaskLedger,
    Worktree
  }

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-recovery-#{token}.sqlite")
    factory = %{enabled: true, database: database, scope: "assigned-jira-work", dispatcher_id: "dispatcher-a"}
    {:ok, store} = Store.start_link(database: database)
    Control.initialize(store, %{scope: factory.scope, dispatcher_id: factory.dispatcher_id})

    task_key = "run-1:specification-author"
    request_key = "desktop:recover-spec"
    digest = String.duplicate("a", 64)
    task_failure = inspect({:desktop_request_reconciliation_required, "COMPLETED_TURN_EMPTY_NO_SCHEMA_RESULT"})
    run_failure = inspect({:task_failed, task_failure, :not_applicable}) |> String.slice(0, 200)

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "run-1",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               worktree: "/tmp/grail-spec-worktree",
               dispatcher_id: factory.dispatcher_id
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: task_key,
               run_id: "run-1",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "RUNNING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               prompt_sha256: digest,
               thread_id: "author-thread",
               codex_project_id: "grail-project",
               workspace: "/tmp/grail-spec-worktree"
             })

    assert {:ok, _request} =
             DesktopRequest.enqueue(store, %{
               request_key: request_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "FOLLOWUP",
               codex_project_id: "grail-project",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               existing_thread_id: "author-thread",
               title: "PPL-123 Specification Author",
               prompt: "Factory request ID: #{request_key}\n\nSpecify PPL-123",
               schema: %{"type" => "object"},
               cwd: "/tmp/grail-spec-worktree",
               metadata: %{"workspace_mode" => "CODEX_NATIVE", "stage_prompt_sha256" => digest}
             })

    assert {:ok, _claimed} = DesktopRequest.claim(store, request_key)

    Store.query!(
      store,
      "UPDATE desktop_requests SET thread_id = ?, verified_project_id = ?, verified_cwd = ?, status = 'RECONCILE_REQUIRED', failure_code = ? WHERE request_key = ?",
      ["author-thread", "grail-project", "/tmp/grail-spec-worktree", "COMPLETED_TURN_EMPTY_NO_SCHEMA_RESULT", request_key]
    )

    assert {:ok, _task} = TaskLedger.update(store, task_key, %{status: "FAILED", failure_code: task_failure})
    assert {:ok, _run} = RunLedger.update(store, "run-1", %{state: "FAILED", failure_code: run_failure})

    on_exit(fn -> File.rm(database) end)

    %{store: store, factory: factory, task_key: task_key, request_key: request_key}
  end

  test "adopts one completed prior-revision author without another task turn", context do
    output = %{
      "status" => "DRAFTED",
      "contract_markdown" => "## Ticket Delivery Contract\n\n**Spec revision:** 5\n\nAC-1: Preserve revision 5 wording.\n\n## Manual Validation\n- Required: no",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    }

    completed_revision_fixture(context, output)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.adopt_failed_specification_revision(context.factory, context.request_key, "completed-revision-turn")

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "SPECIFICATION_REVISION_ADOPTED"}} =
             Admin.adopt_failed_specification_revision(context.factory, context.request_key, "completed-revision-turn")

    assert {:ok, run} = RunLedger.get(context.store, "run-1")
    assert run["state"] == "SPEC_WRITING"
    assert Contract.declared_revision(run["contract_markdown"]) == {:ok, 6}
    assert run["contract_markdown"] =~ "AC-1: Preserve revision 5 wording."
    assert run["contract_sha256"] == Contract.digest(run["contract_markdown"])

    assert {:ok, %{"status" => "CONSUMED", "turn_id" => "completed-revision-turn"}} =
             TaskLedger.get(context.store, context.task_key)

    assert {:error, :specification_revision_not_recoverable} =
             Admin.adopt_failed_specification_revision(context.factory, context.request_key, "completed-revision-turn")
  end

  test "CI preflight recovery requires a paused factory, an exact clean candidate, and a CI-only verifier block", context do
    writer = native_writer_fixture(context)

    assert {:ok, _workspace} =
             Worktree.attach_native_branch(%{"path" => writer.repo}, writer.checkout, writer.branch, writer.parent_sha)

    File.write!(Path.join(writer.checkout, "candidate.txt"), "candidate\n")
    git!(writer.checkout, ["add", "candidate.txt"])
    git!(writer.checkout, ["commit", "--no-verify", "-m", "feat(PPL-456): candidate"])
    candidate = writer.checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "FAILED",
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               candidate_sha: candidate,
               verifier_round: 2,
               failure_code: inspect({:verification_blocked, ["Required runtime evidence unavailable; no candidate CI result was available."]})
             })

    verifier_output = %{
      "status" => "BLOCK",
      "candidate_sha" => candidate,
      "findings" => ["Required runtime evidence unavailable; no candidate CI result was available."],
      "checks" => ["PASS: static checks", "NOT_RUN: candidate CI [no pipeline]"]
    }

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: "#{writer.run_id}:change-verifier:2",
               run_id: writer.run_id,
               stage: "VERIFYING",
               role: "change-verifier",
               status: "COMPLETE",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               routing_reason: "test",
               prompt_sha256: String.duplicate("d", 64),
               output_json: Jason.encode!(verifier_output)
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, "#{writer.run_id}:change-verifier:2", %{
               output_json: Jason.encode!(verifier_output),
               turn_id: "verifier-turn-2"
             })

    Store.query!(context.store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE request_key = ?", [writer.request_key])
    factory = Map.put(context.factory, :repositories, %{"grail" => %{"path" => writer.repo, "base_branch" => "master", "ci_preflight" => "draft_mr"}})

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.resume_failed_ci_preflight(factory, writer.run_id, candidate)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

    assert {:error, :ci_preflight_recovery_not_proven} =
             Admin.resume_failed_ci_preflight(factory, "missing-run", candidate)

    assert {:error, :ci_preflight_recovery_not_proven} =
             Admin.resume_failed_ci_preflight(factory, writer.run_id, writer.parent_sha)

    assert {:ok, _task} =
             TaskLedger.update(context.store, "#{writer.run_id}:change-verifier:2", %{output_json: "{"})

    assert {:error, :ci_preflight_recovery_not_proven} =
             Admin.resume_failed_ci_preflight(factory, writer.run_id, candidate)

    assert {:ok, _task} =
             TaskLedger.update(context.store, "#{writer.run_id}:change-verifier:2", %{
               output_json: Jason.encode!(verifier_output)
             })

    assert {:ok, %{result: "CI_PREFLIGHT_RECOVERED", candidate_sha: ^candidate}} =
             Admin.resume_failed_ci_preflight(factory, writer.run_id, candidate)

    assert {:ok, %{"state" => "CI_PUSHING", "candidate_sha" => ^candidate}} =
             RunLedger.get(context.store, writer.run_id)

    assert {:error, :ci_preflight_recovery_not_proven} =
             Admin.resume_failed_ci_preflight(factory, writer.run_id, candidate)
  end

  test "rearms a controller-owned delivery handoff without rerunning its completed writer", context do
    writer = native_writer_fixture(context)
    route = %{"path" => writer.repo, "base_branch" => "master", "ci_preflight" => "draft_mr"}
    factory = Map.put(context.factory, :repositories, %{"grail" => route})

    assert {:ok, _workspace} =
             Worktree.attach_native_branch(route, writer.checkout, writer.branch, writer.parent_sha)

    File.write!(Path.join(writer.checkout, "candidate.txt"), "candidate\n")
    git!(writer.checkout, ["add", "candidate.txt"])
    git!(writer.checkout, ["commit", "--no-verify", "-m", "feat(PPL-456): candidate"])
    previous = writer.checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(writer.checkout, "candidate.txt"), "repaired\n")
    git!(writer.checkout, ["add", "candidate.txt"])
    git!(writer.checkout, ["commit", "--no-verify", "-m", "fix(PPL-456): repair candidate"])
    candidate = writer.checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    blocker = "Controller-owned delivery work remains: MR !42 points to #{previous}, behind clean local HEAD #{candidate}."
    output = %{"status" => "BLOCKED", "blockers" => [blocker], "checks" => [], "changed_paths" => []}

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "FAILED",
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               candidate_sha: candidate,
               ci_preflight_sha: previous,
               mr_url: "https://gitlab.example.test/group/repo/-/merge_requests/42",
               mr_iid: 42,
               failure_code: inspect({:writer_blocked, [blocker]}) |> String.slice(0, 200),
               last_error: inspect({:writer_blocked, [blocker]})
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               stage: "REPAIRING",
               status: "COMPLETE",
               workspace_sha: candidate,
               output_json: Jason.encode!(output),
               turn_id: "writer-repair-turn"
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', turn_id = ?, output_json = ?, verified_cwd = ?, verified_head_sha = ?, thread_id = ?, verified_project_id = ? WHERE request_key = ?",
      [
        "writer-repair-turn",
        Jason.encode!(%{
          "result" => output,
          "completed_tool_calls" => [%{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed"}]
        }),
        writer.canonical_checkout,
        candidate,
        "writer-thread",
        "grail-project",
        writer.request_key
      ]
    )

    assert {:error, :recovery_requires_paused_unleased_control} =
             (
               Admin.activate(factory)
               Admin.resume_controller_owned_delivery(factory, writer.run_id, candidate)
             )

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

    assert {:ok, %{result: "CONTROLLER_DELIVERY_REARMED", candidate_sha: ^candidate}} =
             Admin.resume_controller_owned_delivery(factory, writer.run_id, candidate)

    assert {:ok, %{"state" => "CI_PUSHING", "candidate_sha" => ^candidate, "failure_code" => nil}} =
             RunLedger.get(context.store, writer.run_id)

    assert {:error, :controller_delivery_recovery_not_proven} =
             Admin.resume_controller_owned_delivery(factory, writer.run_id, candidate)
  end

  for recovery_mode <- [:manual, :automatic] do
    @tag recovery_mode: recovery_mode
    test "#{recovery_mode} recovery requeues only an unbound verifier CREATE rejected before task creation", context do
      recovery_mode = context.recovery_mode
      writer = native_writer_fixture(context)
      route = %{"path" => writer.repo, "base_branch" => "master", "codex_project_id" => "grail-project"}
      factory = Map.put(context.factory, :repositories, %{"grail" => route})
      task_key = "#{writer.run_id}:change-verifier:2"
      request_key = "desktop:rejected-verifier-create:bootstrap"

      assert {:ok, _run} =
               RunLedger.update(context.store, writer.run_id, %{
                 state: "VERIFYING",
                 workspace_state: "CODEX_NATIVE",
                 candidate_sha: writer.parent_sha,
                 verifier_round: 2
               })

      assert {:ok, _task} =
               TaskLedger.register(context.store, %{
                 task_key: task_key,
                 run_id: writer.run_id,
                 stage: "VERIFYING",
                 role: "change-verifier",
                 status: "WAITING_FOR_BROKER",
                 model_provider: "codex",
                 model_class: "deep",
                 model: "gpt-6-sol",
                 reasoning_effort: "xhigh",
                 routing_reason: "test",
                 prompt_sha256: String.duplicate("e", 64),
                 codex_project_id: "grail-project",
                 workspace_sha: writer.parent_sha
               })

      assert {:ok, _request} =
               DesktopRequest.enqueue(context.store, %{
                 request_key: request_key,
                 target_kind: "TASK",
                 target_key: task_key,
                 action: "CREATE",
                 codex_project_id: "grail-project",
                 model: "gpt-6-sol",
                 reasoning_effort: "xhigh",
                 title: "PPL-456 · R2 · Change Verifier",
                 prompt: "Factory request ID: #{request_key}\n\nVerify the checkout",
                 schema: %{"type" => "object"},
                 cwd: writer.repo,
                 branch: writer.branch,
                 base_branch: "master",
                 metadata: %{"workspace_mode" => "CODEX_NATIVE", "expected_sha" => writer.parent_sha}
               })

      assert {:ok, _claimed} = DesktopRequest.claim(context.store, request_key)

      assert {:error, :definitive_create_rejection_evidence_required} =
               DesktopRequest.fail(context.store, request_key, "CREATE_THREAD_INVALID_ARGUMENTS")

      assert {:error, :definitive_create_rejection_evidence_required} =
               DesktopRequest.fail(context.store, request_key, "CREATE_THREAD_INVALID_ARGUMENTS",
                 rejected_tool_call_id: "exec-a1b2",
                 tool_error: "create_thread timed out"
               )

      assert {:ok, _failed} =
               DesktopRequest.fail(context.store, request_key, "CREATE_THREAD_INVALID_ARGUMENTS",
                 rejected_tool_call_id: "exec-a1b2",
                 tool_error: "create_thread received invalid arguments"
               )

      assert {:ok, %{"rejected_tool_call_id" => "exec-a1b2", "failure_code" => "CREATE_THREAD_INVALID_ARGUMENTS"}} =
               DesktopRequest.get(context.store, request_key)

      assert {:error, :definitive_create_rejection_evidence_required} =
               DesktopRequest.fail(context.store, request_key, "CREATE_THREAD_INVALID_ARGUMENTS",
                 rejected_tool_call_id: "exec-deadbeef",
                 tool_error: "create_thread received invalid arguments"
               )

      if recovery_mode == :manual do
        assert {:ok, %{result: "ACTIVE"}} = Admin.activate(factory)

        assert {:error, :recovery_requires_paused_unleased_control} =
                 Admin.resume_rejected_native_create(factory, request_key, "exec-a1b2")

        assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

        assert {:error, :rejected_create_not_proven} =
                 Admin.resume_rejected_native_create(factory, request_key, "not-a-tool-call")

        assert {:error, :rejected_create_not_proven} =
                 Admin.resume_rejected_native_create(factory, request_key, "exec-deadbeef")

        assert {:ok, %{result: "REJECTED_NATIVE_CREATE_REARMED"}} =
                 Admin.resume_rejected_native_create(factory, request_key, "exec-a1b2")
      else
        assert {:error, :recovery_requires_active_control} =
                 Recovery.retry_rejected_native_create(context.store, factory, request_key)

        assert {:ok, %{result: "ACTIVE"}} = Admin.activate(factory)

        assert {:ok, %{result: "REJECTED_NATIVE_CREATE_REARMED"}} =
                 Recovery.retry_rejected_native_create(context.store, factory, request_key)
      end

      assert {:ok, %{"status" => "PENDING", "claimed_at" => nil, "failure_code" => nil}} =
               DesktopRequest.get(context.store, request_key)

      assert [[1]] = Store.query!(context.store, "SELECT COUNT(*) FROM factory_tasks WHERE task_key = ?", [task_key]).rows
      assert [[1]] = Store.query!(context.store, "SELECT COUNT(*) FROM desktop_requests WHERE target_key = ? AND action = 'CREATE'", [task_key]).rows

      if recovery_mode == :manual do
        assert {:error, :rejected_create_not_proven} =
                 Admin.resume_rejected_native_create(factory, request_key, "exec-a1b2")
      else
        {:ok, reopened} = Store.start_link(database: context.factory.database)
        assert {:ok, _claimed} = DesktopRequest.claim(reopened, request_key)

        assert {:ok, _failed} =
                 DesktopRequest.fail(reopened, request_key, "CREATE_THREAD_INVALID_ARGUMENTS",
                   rejected_tool_call_id: "exec-beef",
                   tool_error: "create_thread received invalid arguments"
                 )

        assert {:error, :rejected_create_retry_exhausted} =
                 Recovery.retry_rejected_native_create(reopened, factory, request_key)

        assert {:ok, %{"status" => "RECONCILE_REQUIRED", "rejected_tool_call_id" => "exec-beef"}} =
                 DesktopRequest.get(reopened, request_key)
      end
    end
  end

  test "recovers a completed native bootstrap by attaching its exact run branch without creating another task", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    assert {:error, :native_bootstrap_route_not_proven} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, "different-bootstrap-turn")

    assert String.trim(git!(bootstrap.checkout, ["branch", "--show-current"])) == ""

    assert {:ok, %{result: "NATIVE_BOOTSTRAP_RECOVERED", run_id: run_id, task_key: task_key}} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)

    assert run_id == bootstrap.run_id
    assert task_key == bootstrap.task_key
    assert String.trim(git!(bootstrap.checkout, ["branch", "--show-current"])) == bootstrap.run_branch
    assert String.trim(git!(bootstrap.checkout, ["rev-parse", "HEAD"])) == bootstrap.sha
    assert String.trim(git!(bootstrap.previous_checkout, ["branch", "--show-current"])) == bootstrap.base_branch

    assert {:ok, run} = RunLedger.get(context.store, bootstrap.run_id)
    assert run["state"] == "WRITING"
    assert run["worktree"] == bootstrap.canonical_checkout
    assert run["workspace_state"] == "CODEX_NATIVE"
    assert run["implementation_iteration"] == 1
    assert run["failure_code"] == nil

    assert {:ok, task} = TaskLedger.get(context.store, bootstrap.task_key)
    assert task["status"] == "RETRY_PENDING"
    assert task["thread_id"] == bootstrap.thread_id
    assert task["turn_id"] == nil
    assert task["workspace"] == bootstrap.canonical_checkout
    assert task["workspace_sha"] == bootstrap.sha

    assert {:ok, request} = DesktopRequest.get(context.store, bootstrap.request_key)
    assert request["status"] == "SUCCEEDED"
    assert request["action"] == "CREATE"
    assert request["turn_id"] == bootstrap.turn_id
    assert request["branch"] == bootstrap.base_branch
  end

  test "native bootstrap recovery is idempotent after its run branch is already attached", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    assert {:ok, _first_recovery} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)

    failure = inspect({:native_bootstrap_route_mismatch, [:branch_recovery_binding]})

    assert {:ok, _task} =
             TaskLedger.update(context.store, bootstrap.task_key, %{status: "FAILED", failure_code: failure})

    assert {:ok, _run} =
             RunLedger.update(context.store, bootstrap.run_id, %{
               state: "FAILED",
               failure_code: failure,
               workspace_state: "CODEX_NATIVE"
             })

    assert {:ok, %{result: "NATIVE_BOOTSTRAP_RECOVERED", run_id: run_id, task_key: task_key}} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)

    assert run_id == bootstrap.run_id
    assert task_key == bootstrap.task_key
    assert String.trim(git!(bootstrap.checkout, ["branch", "--show-current"])) == bootstrap.run_branch
    assert String.trim(git!(bootstrap.checkout, ["rev-parse", "HEAD"])) == bootstrap.sha
  end

  test "native bootstrap recovery fails closed on an occupied run branch", context do
    bootstrap = native_bootstrap_failure_fixture(context)
    occupied_checkout = Path.join(Path.dirname(bootstrap.checkout), "occupied-run-branch")
    git!(bootstrap.repo, ["branch", bootstrap.run_branch, bootstrap.sha])
    git!(bootstrap.repo, ["worktree", "add", occupied_checkout, bootstrap.run_branch])
    {:ok, canonical_occupied_checkout} = SymphonyElixir.PathSafety.canonicalize(occupied_checkout)

    assert {:error, {:native_branch_checked_out_elsewhere, branch, path}} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)

    assert branch == bootstrap.run_branch
    assert path == canonical_occupied_checkout
    assert String.trim(git!(bootstrap.checkout, ["branch", "--show-current"])) == ""

    assert {:ok, run} = RunLedger.get(context.store, bootstrap.run_id)
    assert run["state"] == "FAILED"
    assert {:ok, task} = TaskLedger.get(context.store, bootstrap.task_key)
    assert task["status"] == "FAILED"
    assert {:ok, request} = DesktopRequest.get(context.store, bootstrap.request_key)
    assert request["status"] == "SUCCEEDED"
  end

  test "native bootstrap recovery refuses an unbound request", context do
    factory = Map.put(context.factory, :repositories, %{"grail" => %{"path" => "/tmp/grail", "base_branch" => "master"}})

    assert {:error, :native_bootstrap_recovery_not_proven} =
             Admin.recover_native_bootstrap(factory, "desktop:missing:bootstrap", "bootstrap-turn")
  end

  test "native bootstrap recovery refuses a superseded run", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    assert {:ok, _newer_run} =
             RunLedger.register(context.store, %{
               run_id: "newer-run",
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "FAILED",
               dispatcher_id: context.factory.dispatcher_id
             })

    assert {:error, :native_bootstrap_recovery_not_latest} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)
  end

  test "native bootstrap recovery refuses another active run for the issue", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    assert {:ok, _active_run} =
             RunLedger.register(context.store, %{
               run_id: "other-active-run",
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "WRITING",
               dispatcher_id: context.factory.dispatcher_id
             })

    Store.query!(
      context.store,
      "UPDATE runs SET created_at = '0001-01-01T00:00:00Z' WHERE run_id = ?",
      ["other-active-run"]
    )

    assert {:error, :native_bootstrap_recovery_has_other_active_run} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)
  end

  test "native bootstrap recovery refuses unresolved sibling requests", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    Store.query!(context.store, "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED' WHERE request_key = ?", [
      "desktop:recover-writer"
    ])

    assert {:error, :native_bootstrap_recovery_has_unresolved_request} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)
  end

  test "native bootstrap recovery refuses duplicate create history", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    Store.query!(context.store, "UPDATE desktop_requests SET action = 'FOLLOWUP' WHERE request_key = ?", [
      bootstrap.request_key
    ])

    assert {:error, :native_bootstrap_recovery_duplicate_create} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)
  end

  test "native bootstrap recovery requires the specific bootstrap failure", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    Store.query!(context.store, "UPDATE factory_tasks SET failure_code = 'different failure' WHERE task_key = ?", [
      bootstrap.task_key
    ])

    assert {:error, :native_bootstrap_failure_not_proven} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)
  end

  test "native bootstrap recovery refuses a candidate or merge request", context do
    bootstrap = native_bootstrap_failure_fixture(context)

    Store.query!(context.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = ?", [
      bootstrap.sha,
      bootstrap.run_id
    ])

    assert {:error, :native_bootstrap_failure_not_proven} =
             Admin.recover_native_bootstrap(bootstrap.factory, bootstrap.request_key, bootstrap.turn_id)
  end

  test "native bootstrap recovery rejects malformed bootstrap metadata", context do
    malformed = native_bootstrap_failure_fixture(context)

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET metadata_json = 'not-json' WHERE request_key = ?",
      [malformed.request_key]
    )

    assert {:error, :native_bootstrap_recovery_not_proven} =
             Admin.recover_native_bootstrap(malformed.factory, malformed.request_key, malformed.turn_id)
  end

  test "native bootstrap recovery rejects mismatched bootstrap metadata", context do
    mismatched = native_bootstrap_failure_fixture(context)

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET metadata_json = json_set(metadata_json, '$.workspace_mode', 'PROJECT_WORKSPACE') WHERE request_key = ?",
      [mismatched.request_key]
    )

    assert {:error, :native_bootstrap_route_not_proven} =
             Admin.recover_native_bootstrap(mismatched.factory, mismatched.request_key, mismatched.turn_id)
  end

  test "recovers a verifier whose existing CREATE is proven by its completed bootstrap", context do
    verifier = native_verifier_create_failure_fixture(context)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(verifier.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.recover_native_verifier_create(verifier.factory, verifier.request_key, verifier.turn_id)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(verifier.factory)

    assert {:error, :native_verifier_create_recovery_not_proven} =
             Admin.recover_native_verifier_create(verifier.factory, verifier.request_key, "wrong-bootstrap-turn")

    assert {:ok, %{result: "NATIVE_VERIFIER_CREATE_RECOVERED", run_id: run_id, task_key: task_key}} =
             Admin.recover_native_verifier_create(verifier.factory, verifier.request_key, verifier.turn_id)

    assert run_id == verifier.run_id
    assert task_key == verifier.task_key
    assert {:ok, run} = RunLedger.get(context.store, verifier.run_id)
    assert run["state"] == "VERIFYING"
    assert run["failure_code"] == nil
    assert run["candidate_sha"] == verifier.sha
    assert run["mr_url"] == "https://gitlab.example.test/grail/-/merge_requests/47489"

    assert {:ok, task} = TaskLedger.get(context.store, verifier.task_key)
    assert task["status"] == "RETRY_PENDING"
    assert task["thread_id"] == verifier.thread_id
    assert task["workspace"] == verifier.review_workspace
    assert task["workspace_sha"] == verifier.sha

    assert {:ok, request} = DesktopRequest.get(context.store, verifier.request_key)
    assert request["status"] == "SUCCEEDED"
    assert request["turn_id"] == verifier.turn_id
    assert request["action"] == "CREATE"
  end

  test "restarts a failed native writer on a run-specific branch without touching the prior dirty checkout", context do
    writer = native_writer_fixture(context)

    assert {:ok, _workspace} =
             Worktree.attach_native_branch(%{"path" => writer.repo}, writer.checkout, writer.branch, writer.parent_sha)

    File.write!(Path.join(writer.checkout, "prior-candidate.txt"), "committed\n")
    git!(writer.checkout, ["add", "prior-candidate.txt"])
    git!(writer.checkout, ["commit", "--no-verify", "-m", "feat(PPL-456): prior visual scan slice"])
    prior_sha = writer.checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(writer.checkout, "in-progress.txt"), "keep this dirty edit\n")

    prior_markdown =
      "# Contract\n\n**Spec revision:** 4\n\n## Acceptance Criteria\n- AC-1: prior behavior\n\n## Manual Validation\n- Required: no\n"

    prior_contract = Contract.bind("PPL-456", 4, prior_markdown)

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "FAILED",
               failure_code: inspect({:writer_blocked, ["Old acceptance criteria conflict; this needs a contract decision."]}),
               spec_revision: 4,
               contract_markdown: prior_contract.markdown,
               contract_sha256: prior_contract.sha256,
               candidate_sha: prior_sha,
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE"
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "COMPLETE",
               turn_id: "prior-writer-turn",
               workspace_sha: prior_sha,
               output_json: Jason.encode!(%{"status" => "COMPLETE", "commit_sha" => prior_sha})
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL WHERE request_key = ?",
      [writer.request_key]
    )

    next_checkout = Path.join(Path.dirname(writer.checkout), "retry-checkout")
    git!(writer.repo, ["worktree", "add", "--detach", next_checkout, writer.parent_sha])
    {:ok, canonical_next_checkout} = SymphonyElixir.PathSafety.canonicalize(next_checkout)

    contract =
      Contract.bind(
        "PPL-456",
        7,
        "# Contract\n\n**Spec revision:** 7\n\n## Acceptance Criteria\n- AC-1: revised behavior\n\n## Manual Validation\n- Required: no\n"
      )

    snapshot = %{
      "key" => "PPL-456",
      "status" => "TO DO",
      "labels" => ["ai-running", "repo-grail"],
      "comments" => [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
        %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
      ]
    }

    mismatch = {:native_branch_sha_mismatch, writer.branch, writer.parent_sha, prior_sha}
    latest_run_id = "writer-run-latest"
    latest_task_key = "#{latest_run_id}:feature-writer"

    assert {:ok, _run} =
             RunLedger.register(context.store, %{
               run_id: latest_run_id,
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "FAILED",
               dispatcher_id: context.factory.dispatcher_id,
               spec_revision: contract.revision,
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               manual_validation_required: false,
               repo_key: "grail",
               repo_path: writer.repo,
               base_branch: "master",
               worktree: canonical_next_checkout,
               branch: writer.branch,
               workspace_state: "CODEX_NATIVE",
               snapshot_json: Jason.encode!(snapshot),
               failure_code: inspect({:task_failed, mismatch, :not_applicable})
             })

    assert {:ok, _run} =
             RunLedger.update(context.store, latest_run_id, %{failure_code: inspect({:task_failed, mismatch, :not_applicable})})

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: latest_task_key,
               run_id: latest_run_id,
               stage: "WRITING",
               role: "feature-writer-high-risk",
               status: "FAILED",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               routing_reason: "risk-escalation",
               prompt_sha256: String.duplicate("e", 64),
               thread_id: "failed-setup-thread",
               codex_project_id: "grail-project",
               workspace: canonical_next_checkout,
               workspace_sha: writer.parent_sha,
               failure_code: inspect(mismatch)
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, latest_task_key, %{failure_code: inspect(mismatch)})

    factory =
      Map.put(context.factory, :repositories, %{
        "grail" => %{"path" => writer.repo, "base_branch" => "master", "codex_project_id" => "grail-project"}
      })

    assert Contract.authorized?(snapshot, contract)
    assert {:ok, latest_record} = RunLedger.get(context.store, latest_run_id)
    assert {:ok, prior_record} = RunLedger.get(context.store, writer.run_id)
    assert latest_record["spec_revision"] > prior_record["spec_revision"]
    assert latest_record["failure_code"] =~ "native_branch_sha_mismatch"
    assert prior_record["failure_code"] =~ "writer_blocked"
    assert latest_record["branch"] == prior_record["branch"]
    assert latest_record["repo_path"] == prior_record["repo_path"]

    assert {:error, :native_branch_mismatch_recovery_not_proven} =
             Admin.resume_native_branch_sha_mismatch(factory, "missing-run", writer.run_id)

    assert {:error, :native_branch_mismatch_run_pair_invalid} =
             Admin.resume_native_branch_sha_mismatch(factory, latest_run_id, latest_run_id)

    assert {:ok, _run} = RunLedger.update(context.store, latest_run_id, %{snapshot_json: "{"})

    assert {:error, :native_branch_mismatch_contract_not_authorized} =
             Admin.resume_native_branch_sha_mismatch(factory, latest_run_id, writer.run_id)

    assert {:ok, _run} = RunLedger.update(context.store, latest_run_id, %{snapshot_json: Jason.encode!(snapshot)})

    assert {:ok, _run} = RunLedger.update(context.store, latest_run_id, %{snapshot_json: nil})

    assert {:error, :native_branch_mismatch_contract_not_authorized} =
             Admin.resume_native_branch_sha_mismatch(factory, latest_run_id, writer.run_id)

    assert {:ok, _run} = RunLedger.update(context.store, latest_run_id, %{snapshot_json: Jason.encode!(snapshot)})

    assert {:ok, _run} = RunLedger.update(context.store, latest_run_id, %{contract_markdown: nil})

    assert {:error, :native_branch_mismatch_contract_digest_mismatch} =
             Admin.resume_native_branch_sha_mismatch(factory, latest_run_id, writer.run_id)

    assert {:ok, _run} =
             RunLedger.update(context.store, latest_run_id, %{contract_markdown: contract.markdown})

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

    assert {:ok, %{result: "NATIVE_BRANCH_MISMATCH_RECOVERED", branch: recovered_branch}} =
             Admin.resume_native_branch_sha_mismatch(factory, latest_run_id, writer.run_id)

    assert recovered_branch == "#{writer.branch}-#{String.slice(latest_run_id, 0, 8)}"

    recovery_details =
      Store.one!(
        context.store,
        "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'NATIVE_BRANCH_MISMATCH_RECOVERED'",
        [latest_run_id]
      )
      |> Map.fetch!("payload_json")
      |> Jason.decode!()

    assert recovery_details["previous_branch"] == writer.branch
    assert recovery_details["new_branch"] == recovered_branch

    assert {:ok, %{"state" => "WRITING", "candidate_sha" => nil, "worktree" => ^canonical_next_checkout}} =
             RunLedger.get(context.store, latest_run_id)

    assert {:ok,
            %{
              "status" => "RETRY_PENDING",
              "thread_id" => "failed-setup-thread",
              "workspace" => ^canonical_next_checkout,
              "workspace_sha" => base_sha
            }} = TaskLedger.get(context.store, latest_task_key)

    assert base_sha == writer.parent_sha
    assert String.trim(git!(writer.checkout, ["rev-parse", "HEAD"])) == prior_sha
    assert File.read!(Path.join(writer.checkout, "in-progress.txt")) == "keep this dirty edit\n"
    assert File.read!(Path.join(writer.checkout, "prior-candidate.txt")) == "committed\n"
  end

  test "revision adoption rejects wrong, blocked, and unbound author output", context do
    output = %{
      "status" => "DRAFTED",
      "contract_markdown" => "## Ticket Delivery Contract\n\n**Spec revision:** 4\n\n## Manual Validation\n- Required: no",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    }

    completed_revision_fixture(context, output)

    assert {:error, :contract_revision_mismatch} =
             Admin.adopt_failed_specification_revision(context.factory, context.request_key, "completed-revision-turn")

    blocked = %{output | "status" => "BLOCKED", "contract_markdown" => "", "questions" => ["Need a decision"]}
    replace_completed_revision_output(context, blocked)

    assert {:error, :specification_revision_not_recoverable} =
             Admin.adopt_failed_specification_revision(context.factory, context.request_key, "completed-revision-turn")

    assert {:error, :completed_recovery_request_not_proven} =
             Admin.adopt_failed_specification_revision(context.factory, "desktop:missing", "completed-revision-turn")

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, "run-1")
  end

  test "reopens a failed repair for exact adoption of its existing clean commit", context do
    writer = native_writer_fixture(context)
    parent = String.trim(git!(writer.checkout, ["rev-parse", "HEAD"]))
    message = "test(PPL-456): cover repaired behavior"

    assert {:ok, _workspace} =
             Worktree.attach_native_branch(%{"path" => writer.repo}, writer.checkout, writer.branch, parent)

    File.write!(Path.join(writer.checkout, "repair.txt"), "repaired\n")

    assert {:ok, %{sha: committed}} =
             Worktree.commit_native_slice(
               %{"path" => writer.repo},
               writer.checkout,
               writer.branch,
               parent,
               ["repair.txt"],
               message
             )

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "FAILED",
               failure_code: ":native_writer_slice_state_changed",
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               candidate_sha: parent,
               code_repair_round: 1,
               implementation_iteration: 6
             })

    output = %{
      "status" => "COMPLETE",
      "changed_paths" => ["repair.txt"],
      "commit_message" => message,
      "checks" => [],
      "blockers" => [],
      "summary" => "Repair covered."
    }

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               stage: "REPAIRING",
               status: "COMPLETE",
               turn_id: "completed-repair-turn",
               output_json: Jason.encode!(output)
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL, turn_id = ?, output_json = ? WHERE request_key = ?",
      ["completed-repair-turn", Jason.encode!(%{"result" => output, "completed_tool_calls" => []}), writer.request_key]
    )

    wrong_output = %{output | "commit_message" => "test(PPL-456): wrong slice"}
    assert {:ok, _task} = TaskLedger.update(context.store, writer.task_key, %{output_json: Jason.encode!(wrong_output)})

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET output_json = ? WHERE request_key = ?",
      [Jason.encode!(%{"result" => wrong_output, "completed_tool_calls" => []}), writer.request_key]
    )

    assert {:error, :native_slice_message_mismatch} =
             Admin.adopt_failed_native_repair_slice(context.factory, writer.request_key, "completed-repair-turn")

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, writer.run_id)
    assert String.trim(git!(writer.checkout, ["rev-parse", "HEAD"])) == committed

    assert {:ok, _task} = TaskLedger.update(context.store, writer.task_key, %{output_json: Jason.encode!(output)})

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET output_json = ? WHERE request_key = ?",
      [Jason.encode!(%{"result" => output, "completed_tool_calls" => []}), writer.request_key]
    )

    assert {:ok, %{result: "NATIVE_REPAIR_SLICE_ADOPTION_READY", candidate_sha: ^committed}} =
             Admin.adopt_failed_native_repair_slice(context.factory, writer.request_key, "completed-repair-turn")

    assert {:ok, %{"state" => "REPAIRING", "candidate_sha" => ^parent, "code_repair_round" => 1}} =
             RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "completed-repair-turn"}} =
             TaskLedger.get(context.store, writer.task_key)

    assert {:ok, %{sha: ^committed}} =
             Worktree.commit_native_slice(
               %{"path" => writer.repo},
               writer.checkout,
               writer.branch,
               parent,
               ["repair.txt"],
               message
             )

    assert String.trim(git!(writer.checkout, ["rev-list", "--count", "#{parent}..HEAD"])) == "1"
  end

  test "restores the same failed run and author only when control is paused", context do
    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.recover_specification_readback(context.factory, context.request_key, "completed-turn")

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "SPECIFICATION_BROKER_READBACK_RECOVERED", run_id: "run-1", task_key: task_key}} =
             Admin.recover_specification_readback(context.factory, context.request_key, "completed-turn")

    assert task_key == context.task_key
    assert {:ok, %{"state" => "SPEC_DRAFTING", "failure_code" => nil}} = RunLedger.get(context.store, "run-1")

    assert {:ok, %{"status" => "WAITING_FOR_BROKER", "failure_code" => nil, "thread_id" => "author-thread"}} =
             TaskLedger.get(context.store, context.task_key)

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} = DesktopRequest.get(context.store, context.request_key)

    assert {:error, :task_not_recoverable} =
             Admin.recover_specification_readback(context.factory, context.request_key, "completed-turn")
  end

  test "rejects a changed failure while preserving the terminal audit", context do
    Store.query!(context.store, "UPDATE desktop_requests SET failure_code = ? WHERE request_key = ?", [
      "OTHER_FAILURE",
      context.request_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.recover_specification_readback(context.factory, context.request_key, "completed-turn")

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, "run-1")
    assert {:ok, %{"status" => "FAILED"}} = TaskLedger.get(context.store, context.task_key)
  end

  test "rejects a missing request without touching the failed task", context do
    assert {:error, :request_not_recoverable} =
             Admin.recover_specification_readback(context.factory, "desktop:missing", "completed-turn")

    assert {:ok, %{"status" => "FAILED"}} = TaskLedger.get(context.store, context.task_key)
  end

  test "rejects missing native prompt provenance", context do
    Store.query!(context.store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [
      Jason.encode!(%{"workspace_mode" => "CODEX_NATIVE"}),
      context.request_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.recover_specification_readback(context.factory, context.request_key, "completed-turn")

    assert {:ok, %{"status" => "FAILED"}} = TaskLedger.get(context.store, context.task_key)
  end

  test "authorizes one same-task planner format repair only for the exact stale bound request", context do
    expected_sha = String.duplicate("b", 40)
    planner_key = "run-1:feature-planner"

    Store.query!(context.store, "UPDATE runs SET kind = 'DELIVERY', state = 'PLANNING', failure_code = NULL WHERE run_id = ?", [
      "run-1"
    ])

    Store.query!(
      context.store,
      "UPDATE factory_tasks SET task_key = ?, role = 'feature-planner', stage = 'PLANNING', status = 'STALE', failure_code = 'stale task exceeded 90 minutes' WHERE task_key = ?",
      [planner_key, context.task_key]
    )

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET target_key = ?, failure_code = 'FINAL_OUTPUT_INVALID_JSON', verified_head_sha = ?, metadata_json = ? WHERE request_key = ?",
      [
        planner_key,
        expected_sha,
        Jason.encode!(%{
          "workspace_mode" => "CODEX_NATIVE",
          "stage_prompt_sha256" => String.duplicate("a", 64),
          "expected_sha" => expected_sha,
          "format_repair_attempts" => 0,
          "required_tool_calls" => []
        }),
        context.request_key
      ]
    )

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.authorize_planner_format_repair(context.factory, context.request_key, "completed-turn")

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "PLANNER_FORMAT_REPAIR_AUTHORIZED", task_key: task_key}} =
             Admin.authorize_planner_format_repair(context.factory, context.request_key, "completed-turn")

    assert task_key == planner_key

    assert {:ok, %{"status" => "WAITING_FOR_BROKER", "thread_id" => "author-thread"}} =
             TaskLedger.get(context.store, task_key)

    assert {:ok, request} = DesktopRequest.get(context.store, context.request_key)
    assert Jason.decode!(request["metadata_json"])["format_repair_attempts"] == 0

    assert {:error, :repair_requires_active_control} =
             Admin.claim_planner_format_repair(context.factory, context.request_key)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    Store.query!(context.store, "UPDATE factory_tasks SET codex_project_id = 'wrong-project' WHERE task_key = ?", [task_key])

    assert {:error, :repair_binding_changed} =
             Admin.claim_planner_format_repair(context.factory, context.request_key)

    Store.query!(context.store, "UPDATE factory_tasks SET codex_project_id = 'grail-project' WHERE task_key = ?", [task_key])

    assert {:ok, %{result: "PLANNER_FORMAT_REPAIR_CLAIMED", completed_turn_id: "completed-turn"}} =
             Admin.claim_planner_format_repair(context.factory, context.request_key)

    assert {:error, :repair_already_claimed} =
             Admin.claim_planner_format_repair(context.factory, context.request_key)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:error, :task_not_recoverable} =
             Admin.authorize_planner_format_repair(context.factory, context.request_key, "completed-turn")
  end

  test "planner repair refuses missing request and grant", context do
    assert {:error, :request_not_recoverable} =
             Admin.authorize_planner_format_repair(context.factory, "desktop:absent", "completed-turn")

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :request_not_recoverable} =
             Admin.claim_planner_format_repair(context.factory, "desktop:absent")

    Store.query!(context.store, "UPDATE desktop_requests SET failure_code = 'FINAL_OUTPUT_INVALID_JSON' WHERE request_key = ?", [
      context.request_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.claim_planner_format_repair(context.factory, context.request_key)
  end

  test "planner repair refuses malformed metadata and a missing task", context do
    Store.query!(
      context.store,
      "UPDATE desktop_requests SET failure_code = 'FINAL_OUTPUT_INVALID_JSON', metadata_json = '[]' WHERE request_key = ?",
      [context.request_key]
    )

    assert {:error, :request_not_recoverable} =
             Admin.authorize_planner_format_repair(context.factory, context.request_key, "completed-turn")

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET target_key = 'run-1:missing-task', metadata_json = ? WHERE request_key = ?",
      [
        Jason.encode!(%{
          "workspace_mode" => "CODEX_NATIVE",
          "stage_prompt_sha256" => String.duplicate("a", 64),
          "expected_sha" => String.duplicate("b", 40),
          "format_repair_attempts" => 0,
          "required_tool_calls" => []
        }),
        context.request_key
      ]
    )

    Store.query!(context.store, "UPDATE desktop_requests SET verified_head_sha = ? WHERE request_key = ?", [
      String.duplicate("b", 40),
      context.request_key
    ])

    assert {:error, :task_not_recoverable} =
             Admin.authorize_planner_format_repair(context.factory, context.request_key, "completed-turn")
  end

  test "authorizes one tool-free controller format repair for the exact malformed turn", context do
    repair = controller_format_repair_fixture(context)
    original = DesktopRequest.get(context.store, repair.request_key)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.authorize_controller_format_repair(context.factory, repair.request_key, repair.completed_turn_id)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "CONTROLLER_FORMAT_REPAIR_AUTHORIZED"}} =
             Admin.authorize_controller_format_repair(context.factory, repair.request_key, repair.completed_turn_id)

    assert {:error, :repair_already_authorized} =
             Admin.authorize_controller_format_repair(context.factory, repair.request_key, repair.completed_turn_id)

    assert {:ok, unchanged} = DesktopRequest.get(context.store, repair.request_key)
    assert DesktopRequest.payload_intact?(unchanged)
    assert unchanged["payload_sha256"] == elem(original, 1)["payload_sha256"]
    assert unchanged["prompt"] == elem(original, 1)["prompt"]

    assert {:error, :controller_format_repair_not_claimed} =
             DesktopRequest.complete(context.store, repair.request_key, %{
               thread_id: repair.thread_id,
               turn_id: "format-repair-turn",
               output: %{"result" => %{"status" => "PASS"}, "completed_tool_calls" => []}
             })

    assert {:error, :repair_requires_active_control} =
             Admin.claim_controller_format_repair(context.factory, repair.request_key)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:ok, grant} = Admin.claim_controller_format_repair(context.factory, repair.request_key)
    assert grant.result == "CONTROLLER_FORMAT_REPAIR_CLAIMED"
    assert grant.completed_turn_id == repair.completed_turn_id
    assert grant.thread_id == repair.thread_id
    assert grant.codex_project_id == "projectless"
    assert grant.repair_prompt =~ "Factory request ID: #{repair.request_key}"
    assert grant.repair_prompt =~ "Factory format repair attempt: 1"
    assert grant.repair_prompt =~ "Do not call tools"

    assert {:error, :repair_already_claimed} = Admin.claim_controller_format_repair(context.factory, repair.request_key)

    assert {:error, :controller_format_repair_turn_replayed} =
             DesktopRequest.complete(context.store, repair.request_key, %{
               thread_id: repair.thread_id,
               turn_id: repair.completed_turn_id,
               output: %{"result" => %{"status" => "PASS"}, "completed_tool_calls" => []}
             })

    assert {:error, :controller_format_repair_tool_calls_forbidden} =
             DesktopRequest.complete(context.store, repair.request_key, %{
               thread_id: repair.thread_id,
               turn_id: "format-repair-turn",
               output: %{
                 "result" => %{"status" => "PASS"},
                 "completed_tool_calls" => [%{"tool" => "jira_transition_issue", "status" => "completed"}]
               }
             })

    assert {:ok, %{"status" => "SUCCEEDED", "turn_id" => "format-repair-turn"}} =
             DesktopRequest.complete(context.store, repair.request_key, %{
               thread_id: repair.thread_id,
               turn_id: "format-repair-turn",
               output: %{"result" => %{"status" => "PASS"}, "completed_tool_calls" => []}
             })

    assert {:error, :repair_already_claimed} = Admin.claim_controller_format_repair(context.factory, repair.request_key)
  end

  test "controller format repair authorization rejects external tool permissions", context do
    repair = controller_format_repair_fixture(context)

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET metadata_json = json_set(metadata_json, '$.allowed_mcp_tool_approvals', json('[{\"tool\":\"jira_add_comment\"}]')) WHERE request_key = ?",
      [repair.request_key]
    )

    assert {:error, :request_not_recoverable} =
             Admin.authorize_controller_format_repair(context.factory, repair.request_key, repair.completed_turn_id)
  end

  test "controller format repair authorization rejects a missing request and malformed metadata", context do
    assert {:error, :request_not_recoverable} =
             Admin.authorize_controller_format_repair(context.factory, "desktop:missing-controller", "completed-turn")

    repair = controller_format_repair_fixture(context)

    Store.query!(context.store, "UPDATE desktop_requests SET metadata_json = '[]' WHERE request_key = ?", [
      repair.request_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.authorize_controller_format_repair(context.factory, repair.request_key, repair.completed_turn_id)
  end

  test "controller format repair claim requires both its request and authorization", context do
    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :request_not_recoverable} =
             Admin.claim_controller_format_repair(context.factory, "desktop:missing-controller")

    repair = controller_format_repair_fixture(context)

    assert {:error, :request_not_recoverable} =
             Admin.claim_controller_format_repair(context.factory, repair.request_key)
  end

  test "controller format repair rejects a request whose durable payload changes after claim", context do
    repair = controller_format_repair_fixture(context)

    assert {:ok, _authorized} =
             Admin.authorize_controller_format_repair(context.factory, repair.request_key, repair.completed_turn_id)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)
    assert {:ok, _claimed} = Admin.claim_controller_format_repair(context.factory, repair.request_key)

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET prompt = prompt || ' changed' WHERE request_key = ?",
      [repair.request_key]
    )

    assert {:error, :controller_format_repair_binding_changed} =
             DesktopRequest.complete(context.store, repair.request_key, %{
               thread_id: repair.thread_id,
               turn_id: "format-repair-turn",
               output: %{"result" => %{"status" => "PASS"}, "completed_tool_calls" => []}
             })
  end

  test "recovers the same high-risk writer after a blocked detached-worktree turn", context do
    writer = native_writer_fixture(context)
    expected_checkout = writer.canonical_checkout

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.recover_native_writer(context.factory, writer.request_key, "blocked-turn")

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "NATIVE_WRITER_RECOVERED", task_key: task_key}} =
             Admin.recover_native_writer(context.factory, writer.request_key, "blocked-turn")

    assert task_key == writer.task_key

    assert {:ok,
            %{
              "state" => "WRITING",
              "worktree" => ^expected_checkout,
              "workspace_state" => "CODEX_NATIVE",
              "implementation_iteration" => 1,
              "failure_code" => nil
            }} = RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "RETRY_PENDING", "turn_id" => "blocked-turn", "thread_id" => "writer-thread"}} =
             TaskLedger.get(context.store, writer.task_key)

    assert {:ok, %{"status" => "FAILED", "turn_id" => "blocked-turn"}} =
             DesktopRequest.get(context.store, writer.request_key)

    assert String.trim(git!(writer.checkout, ["branch", "--show-current"])) == writer.branch

    assert {:error, :request_not_recoverable} =
             Admin.recover_native_writer(context.factory, writer.request_key, "blocked-turn")
  end

  test "refuses writer recovery when the checkout contains edits", context do
    writer = native_writer_fixture(context)
    File.write!(Path.join(writer.checkout, "README.md"), "changed\n")

    assert {:error, :worktree_dirty} =
             Admin.recover_native_writer(context.factory, writer.request_key, "blocked-turn")

    assert {:ok, %{"state" => "FAILED", "worktree" => nil}} = RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} =
             DesktopRequest.get(context.store, writer.request_key)
  end

  test "refuses writer recovery when the request branch differs from the run", context do
    writer = native_writer_fixture(context)

    Store.query!(context.store, "UPDATE desktop_requests SET branch = ? WHERE request_key = ?", [
      "factory/PPL-456-wrong-branch",
      writer.request_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.recover_native_writer(context.factory, writer.request_key, "blocked-turn")

    assert String.trim(git!(writer.checkout, ["branch", "--show-current"])) == ""
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, writer.run_id)
  end

  test "refuses writer recovery without a recorded request", context do
    assert {:error, :request_not_recoverable} =
             Admin.recover_native_writer(context.factory, "desktop:missing-writer", "blocked-turn")
  end

  test "resumes an interrupted native writer in the same dirty checkout and task", context do
    writer = interrupted_native_writer_fixture(context)
    checkout = writer.canonical_checkout

    assert {:ok, %{result: "INTERRUPTED_NATIVE_WRITER_RESUMED", task_key: task_key}} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")

    assert task_key == writer.task_key

    assert {:ok, %{"state" => "WRITING", "failure_code" => nil, "worktree" => ^checkout}} =
             RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "RUNNING", "thread_id" => "writer-thread", "turn_id" => "interrupted-turn"}} =
             TaskLedger.get(context.store, writer.task_key)

    assert {:ok, %{"status" => "FAILED", "turn_id" => "interrupted-turn", "failure_code" => "RECOVERED_INTERRUPTED_NATIVE_WRITER"}} =
             DesktopRequest.get(context.store, writer.request_key)

    assert File.read!(Path.join(writer.checkout, "README.md")) == "partial implementation\n"

    assert {:error, :request_not_recoverable} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")
  end

  test "refuses interrupted writer recovery when its bound branch moved", context do
    writer = interrupted_native_writer_fixture(context)
    git!(writer.checkout, ["switch", "-c", "unexpected-branch"])

    assert {:error, {:native_worktree_branch_mismatch, _, _}} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, writer.run_id)
  end

  test "refuses interrupted writer recovery without a recorded request", context do
    assert {:error, :request_not_recoverable} =
             Admin.resume_interrupted_native_writer(context.factory, "desktop:missing-interrupted-writer", "interrupted-turn")
  end

  test "refuses interrupted writer recovery for an unrelated request failure", context do
    writer = interrupted_native_writer_fixture(context)

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET failure_code = 'UNRELATED_FAILURE' WHERE request_key = ?",
      [writer.request_key]
    )

    assert {:error, :request_not_recoverable} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")
  end

  test "refuses interrupted writer recovery without a valid prior turn binding", context do
    writer = interrupted_native_writer_fixture(context)
    Store.query!(context.store, "UPDATE factory_tasks SET turn_id = '' WHERE task_key = ?", [writer.task_key])

    assert {:error, :request_not_recoverable} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")
  end

  test "resumes an interrupted first writer pass without losing its edits or creating a task", context do
    writer = interrupted_native_writer_fixture(context)

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "WRITING",
               failure_code: nil,
               implementation_iteration: 0
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{status: "RUNNING", turn_id: nil})

    Store.query!(
      context.store,
      """
      INSERT INTO desktop_requests (
        request_key, target_kind, target_key, action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, existing_thread_id, thread_id,
        verified_project_id, verified_cwd, verified_head_sha, turn_id, title,
        prompt, schema_json, cwd, branch, base_branch, metadata_json, created_at, updated_at
      )
      SELECT 'desktop:writer-bootstrap', target_kind, target_key, 'CREATE', 'SUCCEEDED', payload_sha256,
        codex_project_id, model, reasoning_effort, NULL, 'writer-thread',
        verified_project_id, verified_cwd, verified_head_sha, 'bootstrap-turn', title,
        'Factory request ID: desktop:writer-bootstrap' || char(10) || char(10) || 'Bootstrap PPL-456',
        schema_json, cwd, branch, base_branch, metadata_json, created_at, updated_at
      FROM desktop_requests WHERE request_key = ?
      """,
      [writer.request_key]
    )

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET failure_code = 'TURN_INTERRUPTED_NO_FINAL', metadata_json = json_set(metadata_json, '$.previous_turn_id', 'bootstrap-turn') WHERE request_key = ?",
      [writer.request_key]
    )

    assert {:ok, %{result: "INTERRUPTED_NATIVE_WRITER_RESUMED"}} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-first-turn")

    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 0, "failure_code" => nil}} =
             RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "RUNNING", "turn_id" => "interrupted-first-turn"}} =
             TaskLedger.get(context.store, writer.task_key)

    assert File.read!(Path.join(writer.checkout, "README.md")) == "partial implementation\n"
  end

  test "resumes an interrupted later writer pass on the same task and candidate", context do
    writer = interrupted_native_writer_fixture(context)

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "WRITING",
               failure_code: nil,
               candidate_sha: writer.parent_sha,
               implementation_iteration: 8
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{status: "RUNNING", turn_id: "previous-turn"})

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET failure_code = 'TURN_INTERRUPTED_NO_FINAL' WHERE request_key = ?",
      [writer.request_key]
    )

    assert {:ok, %{result: "INTERRUPTED_NATIVE_WRITER_RESUMED", task_key: task_key}} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-pass-nine")

    assert task_key == writer.task_key

    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 8, "candidate_sha" => candidate_sha}} =
             RunLedger.get(context.store, writer.run_id)

    assert candidate_sha == writer.parent_sha

    assert {:ok, %{"status" => "RUNNING", "turn_id" => "interrupted-pass-nine"}} =
             TaskLedger.get(context.store, writer.task_key)

    assert {:ok, %{"status" => "FAILED", "turn_id" => "interrupted-pass-nine"}} =
             DesktopRequest.get(context.store, writer.request_key)

    assert File.read!(Path.join(writer.checkout, "README.md")) == "partial implementation\n"
  end

  test "refuses later-pass recovery when the saved candidate differs from the bound worktree", context do
    writer = interrupted_native_writer_fixture(context)

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "WRITING",
               failure_code: nil,
               candidate_sha: String.duplicate("f", 40),
               implementation_iteration: 8
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{status: "RUNNING", turn_id: "previous-turn"})

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET failure_code = 'TURN_INTERRUPTED_NO_FINAL' WHERE request_key = ?",
      [writer.request_key]
    )

    assert {:error, :run_not_recoverable} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-pass-nine")

    assert {:ok, %{"state" => "WRITING", "candidate_sha" => candidate_sha}} =
             RunLedger.get(context.store, writer.run_id)

    assert candidate_sha == String.duplicate("f", 40)
  end

  test "reopens a false dirty failure after the original writer result is read back", context do
    writer = interrupted_native_writer_fixture(context)

    result = %{
      "status" => "CONTINUE",
      "changed_paths" => ["README.md"],
      "commit_message" => "feat(PPL-456): add first slice",
      "blockers" => [],
      "checks" => ["focused test passed"]
    }

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "COMPLETE",
               turn_id: "valid-writer-turn",
               output_json: Jason.encode!(result)
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL, turn_id = 'valid-writer-turn', output_json = ? WHERE request_key = ?",
      [Jason.encode!(%{"result" => result, "completed_tool_calls" => []}), writer.request_key]
    )

    Store.query!(context.store, "UPDATE desktop_requests SET verified_cwd = '/tmp/wrong' WHERE request_key = ?", [
      writer.request_key
    ])

    assert {:error, :writer_result_not_recoverable} =
             Admin.reopen_factory_blocked_delivery(context.factory, writer.run_id)

    Store.query!(context.store, "UPDATE desktop_requests SET verified_cwd = ? WHERE request_key = ?", [
      writer.canonical_checkout,
      writer.request_key
    ])

    assert {:ok, %{result: "FACTORY_BLOCKED_DELIVERY_REOPENED", task_key: task_key}} =
             Admin.reopen_factory_blocked_delivery(context.factory, writer.run_id)

    assert task_key == writer.task_key
    assert {:ok, %{"state" => "WRITING", "failure_code" => nil}} = RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "valid-writer-turn"}} =
             TaskLedger.get(context.store, writer.task_key)

    assert {:error, :run_not_recoverable} = Admin.reopen_factory_blocked_delivery(context.factory, writer.run_id)
  end

  test "reopens a writer result rejected only because perf commits were not allowed", context do
    writer = interrupted_native_writer_fixture(context)
    {:ok, task} = TaskLedger.get(context.store, writer.task_key)

    result = %{
      "status" => "CONTINUE",
      "changed_paths" => ["README.md"],
      "commit_message" => "perf(PPL-456): reduce scan allocations",
      "next_slice" => "Continue with the remaining criterion",
      "blockers" => [],
      "checks" => ["focused test passed"]
    }

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               failure_code: ":native_slice_intent_invalid",
               candidate_sha: task["workspace_sha"]
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "COMPLETE",
               turn_id: "valid-perf-writer-turn",
               output_json: Jason.encode!(result)
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL, turn_id = 'valid-perf-writer-turn', verified_head_sha = ?, output_json = ? WHERE request_key = ?",
      [task["workspace_sha"], Jason.encode!(%{"result" => result, "completed_tool_calls" => []}), writer.request_key]
    )

    assert {:ok, %{result: "FACTORY_BLOCKED_DELIVERY_REOPENED", task_key: task_key}} =
             Admin.reopen_factory_blocked_delivery(context.factory, writer.run_id)

    assert task_key == writer.task_key

    assert {:ok, %{"state" => "WRITING", "failure_code" => nil, "candidate_sha" => sha}} =
             RunLedger.get(context.store, writer.run_id)

    assert sha == task["workspace_sha"]
  end

  test "reopens a cancelled delivery only after the same writer was recovered and factory-blocked", context do
    writer = interrupted_native_writer_fixture(context)

    assert {:ok, _result} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "CANCELLED",
               failure_code: ":delivery_labels_removed",
               snapshot_json: Jason.encode!(%{"labels" => ["ai-blocked", "repo-grail"]})
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "CANCELLED",
               failure_code: "run cancelled during reconciliation"
             })

    assert {:ok, %{result: "FACTORY_BLOCKED_DELIVERY_REOPENED"}} =
             Admin.reopen_factory_blocked_delivery(context.factory, writer.run_id)

    assert {:ok, %{"state" => "WRITING", "failure_code" => nil}} = RunLedger.get(context.store, writer.run_id)

    assert {:ok, %{"status" => "RUNNING", "turn_id" => "interrupted-turn"}} =
             TaskLedger.get(context.store, writer.task_key)
  end

  test "refuses a cancelled delivery when its blocked label is not proven", context do
    writer = interrupted_native_writer_fixture(context)

    assert {:ok, _result} =
             Admin.resume_interrupted_native_writer(context.factory, writer.request_key, "interrupted-turn")

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "CANCELLED",
               failure_code: ":delivery_labels_removed",
               snapshot_json: Jason.encode!(%{"labels" => ["repo-grail"]})
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "CANCELLED",
               failure_code: "run cancelled during reconciliation"
             })

    assert {:error, :writer_result_not_recoverable} =
             Admin.reopen_factory_blocked_delivery(context.factory, writer.run_id)
  end

  test "refuses to reopen an absent delivery run", context do
    assert {:error, :run_not_recoverable} =
             Admin.reopen_factory_blocked_delivery(context.factory, "missing-run")
  end

  test "rearms one authentication-failed verifier in its existing detached task", context do
    verifier = authentication_failed_verifier_fixture(context)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.resume_authentication_failed_verifier(context.factory, verifier.request_key, "failed-turn")

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "AUTHENTICATION_FAILED_VERIFIER_REARMED", task_key: task_key}} =
             Admin.resume_authentication_failed_verifier(context.factory, verifier.request_key, "failed-turn")

    assert task_key == verifier.task_key

    assert {:ok, %{"state" => "VERIFYING", "verifier_round" => 1, "code_repair_round" => 0}} =
             RunLedger.get(context.store, verifier.run_id)

    assert {:ok, %{"status" => "RETRY_PENDING", "thread_id" => "verifier-thread", "turn_id" => "failed-turn"}} =
             TaskLedger.get(context.store, verifier.task_key)

    assert {:ok, %{"status" => "FAILED", "turn_id" => "failed-turn", "failure_code" => "RECOVERED_CODEX_AUTHENTICATION_FAILED"}} =
             DesktopRequest.get(context.store, verifier.request_key)

    assert {:error, :request_not_recoverable} =
             Admin.resume_authentication_failed_verifier(context.factory, verifier.request_key, "failed-turn")
  end

  test "verifier recovery refuses a changed candidate checkout", context do
    verifier = authentication_failed_verifier_fixture(context)
    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    Store.query!(context.store, "UPDATE factory_tasks SET workspace_sha = ? WHERE task_key = ?", [
      String.duplicate("0", 40),
      verifier.task_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.resume_authentication_failed_verifier(context.factory, verifier.request_key, "failed-turn")

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} = DesktopRequest.get(context.store, verifier.request_key)
  end

  test "verifier recovery refuses a missing request", context do
    assert {:error, :request_not_recoverable} =
             Admin.resume_authentication_failed_verifier(context.factory, "desktop:missing-verifier", "failed-turn")
  end

  test "rearms one blocked native writer investigation in the same dirty checkout", context do
    writer = blocked_native_writer_fixture(context)

    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(context.factory)

    assert {:error, :recovery_requires_paused_unleased_control} =
             Admin.resume_blocked_native_writer_investigation(context.factory, writer.request_key, writer.turn_id)

    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:ok, %{result: "BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED", task_key: task_key}} =
             Admin.resume_blocked_native_writer_investigation(context.factory, writer.request_key, writer.turn_id)

    assert task_key == writer.task_key

    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 6, "candidate_sha" => sha}} =
             RunLedger.get(context.store, writer.run_id)

    assert sha == writer.sha

    assert {:ok,
            %{
              "status" => "CONSUMED",
              "thread_id" => "writer-thread",
              "turn_id" => turn_id,
              "failure_code" => "BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED"
            }} =
             TaskLedger.get(context.store, writer.task_key)

    assert turn_id == writer.turn_id
    assert {:ok, %{"status" => "SUCCEEDED"}} = DesktopRequest.get(context.store, writer.request_key)
    assert String.trim(git!(writer.checkout, ["status", "--porcelain"])) == "M README.md"

    assert {:error, :request_not_recoverable} =
             Admin.resume_blocked_native_writer_investigation(context.factory, writer.request_key, writer.turn_id)
  end

  test "blocked writer investigation refuses a changed candidate SHA", context do
    writer = blocked_native_writer_fixture(context)
    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    Store.query!(context.store, "UPDATE factory_tasks SET workspace_sha = ? WHERE task_key = ?", [
      String.duplicate("0", 40),
      writer.task_key
    ])

    assert {:error, :request_not_recoverable} =
             Admin.resume_blocked_native_writer_investigation(context.factory, writer.request_key, writer.turn_id)

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, writer.run_id)
  end

  test "blocked writer investigation refuses a missing request", context do
    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    assert {:error, :request_not_recoverable} =
             Admin.resume_blocked_native_writer_investigation(
               context.factory,
               "desktop:missing-writer",
               "missing-turn"
             )
  end

  test "blocked writer investigation refuses a snapshot without active writer labels", context do
    writer = blocked_native_writer_fixture(context)
    assert {:ok, %{result: "PAUSED"}} = Admin.pause(context.factory)

    Store.query!(context.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = ?", [
      Jason.encode!(%{"status" => "To Do"}),
      writer.run_id
    ])

    assert {:error, :request_not_recoverable} =
             Admin.resume_blocked_native_writer_investigation(context.factory, writer.request_key, writer.turn_id)

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(context.store, writer.run_id)
  end

  defp blocked_native_writer_fixture(context) do
    writer = interrupted_native_writer_fixture(context)
    sha = String.trim(git!(writer.checkout, ["rev-parse", "HEAD"]))
    turn_id = "blocked-writer-turn"
    blockers = ["AC-11 golden fixture reports near-white-text; investigate without weakening the contract"]

    result = %{
      "status" => "BLOCKED",
      "changed_paths" => ["README.md"],
      "commit_message" => "feat(PPL-456): inspect visual false positive",
      "checks" => ["FAIL: six-PDF gate"],
      "blockers" => blockers,
      "next_slice" => "Investigate the false positive"
    }

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "FAILED",
               failure_code: inspect({:writer_blocked, blockers}) |> String.slice(0, 200),
               last_error: inspect({:writer_blocked, blockers}),
               candidate_sha: sha,
               implementation_iteration: 6,
               snapshot_json: Jason.encode!(%{"status" => "To Do", "labels" => ["ai-running", "repo-grail"]})
             })

    Store.query!(context.store, "UPDATE runs SET factory_owned = 0 WHERE run_id = ?", [writer.run_id])

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "COMPLETE",
               turn_id: turn_id,
               output_json: Jason.encode!(result),
               workspace_sha: sha,
               failure_code: nil
             })

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', turn_id = ?, failure_code = NULL, output_json = ?, verified_head_sha = ? WHERE request_key = ?",
      [turn_id, Jason.encode!(%{"completed_tool_calls" => [], "result" => result}), sha, writer.request_key]
    )

    Map.merge(writer, %{turn_id: turn_id, sha: sha})
  end

  defp authentication_failed_verifier_fixture(context) do
    writer = native_writer_fixture(context)
    {:ok, run} = RunLedger.get(context.store, writer.run_id)
    candidate = String.trim(git!(writer.checkout, ["rev-parse", "HEAD"]))
    review = writer.checkout <> "-review"
    git!(writer.checkout, ["worktree", "add", "--detach", review, candidate])
    git!(writer.checkout, ["switch", "-c", writer.branch])
    {:ok, canonical_review} = SymphonyElixir.PathSafety.canonicalize(review)
    verifier_key = "#{writer.run_id}:change-verifier:1"

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "VERIFYING",
               failure_code: nil,
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               candidate_sha: candidate,
               implementation_iteration: 1,
               verifier_round: 1
             })

    Store.query!(
      context.store,
      "UPDATE factory_tasks SET task_key = ?, stage = 'VERIFYING', role = 'change-verifier', status = 'STALE', failure_code = 'stale task exceeded 90 minutes', thread_id = 'verifier-thread', workspace = ?, workspace_sha = ? WHERE task_key = ?",
      [verifier_key, canonical_review, candidate, writer.task_key]
    )

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET target_key = ?, existing_thread_id = 'verifier-thread', thread_id = 'verifier-thread', verified_cwd = ?, cwd = ?, verified_head_sha = ?, status = 'RECONCILE_REQUIRED', failure_code = 'CODEX_AUTHENTICATION_FAILED', metadata_json = json_set(metadata_json, '$.expected_sha', ?, '$.previous_turn_id', 'bootstrap-turn') WHERE request_key = ?",
      [verifier_key, canonical_review, canonical_review, candidate, candidate, writer.request_key]
    )

    %{run_id: run["run_id"], task_key: verifier_key, request_key: writer.request_key}
  end

  defp interrupted_native_writer_fixture(context) do
    writer = native_writer_fixture(context)
    git!(writer.checkout, ["switch", "-c", writer.branch])
    File.write!(Path.join(writer.checkout, "README.md"), "partial implementation\n")

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               failure_code: ":worktree_dirty",
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               implementation_iteration: 1
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{turn_id: "previous-turn"})

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET failure_code = 'FINAL_OUTPUT_SCHEMA_MISMATCH', metadata_json = json_set(metadata_json, '$.previous_turn_id', 'previous-turn') WHERE request_key = ?",
      [writer.request_key]
    )

    writer
  end

  defp native_writer_fixture(context) do
    root = Path.join(System.tmp_dir!(), "symphony-native-writer-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    checkout = Path.join(root, "checkout")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    git!(root, ["init", repo])
    git!(repo, ["config", "user.email", "factory@example.test"])
    git!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "--no-verify", "-m", "base"])
    git!(repo, ["branch", "-M", "master"])
    git!(repo, ["worktree", "add", "--detach", checkout, "HEAD"])
    sha = String.trim(git!(repo, ["rev-parse", "HEAD"]))
    {:ok, canonical_checkout} = SymphonyElixir.PathSafety.canonicalize(checkout)

    run_id = "writer-run"
    task_key = "#{run_id}:feature-writer"
    request_key = "desktop:recover-writer"
    branch = "factory/PPL-456-writer"
    digest = String.duplicate("c", 64)

    assert {:ok, _run} =
             RunLedger.register(context.store, %{
               run_id: run_id,
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "FAILED",
               failure_code: ":native_run_workspace_conflict",
               workspace_state: "UNMATERIALIZED",
               repo_key: "grail",
               repo_path: repo,
               base_branch: "master",
               branch: branch,
               dispatcher_id: context.factory.dispatcher_id
             })

    assert {:ok, _run} =
             RunLedger.update(context.store, run_id, %{failure_code: ":native_run_workspace_conflict"})

    assert {:ok, _task} =
             TaskLedger.register(context.store, %{
               task_key: task_key,
               run_id: run_id,
               stage: "WRITING",
               role: "feature-writer-high-risk",
               status: "WAITING_FOR_BROKER",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               routing_reason: "risk-escalation",
               prompt_sha256: digest,
               thread_id: "writer-thread",
               codex_project_id: "grail-project",
               workspace: canonical_checkout,
               workspace_sha: sha
             })

    assert {:ok, _request} =
             DesktopRequest.enqueue(context.store, %{
               request_key: request_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "FOLLOWUP",
               codex_project_id: "grail-project",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               existing_thread_id: "writer-thread",
               title: "PPL-456 · Feature Writer",
               prompt: "Factory request ID: #{request_key}\n\nImplement PPL-456",
               schema: %{"type" => "object"},
               cwd: canonical_checkout,
               branch: branch,
               base_branch: "master",
               metadata: %{
                 "workspace_mode" => "CODEX_NATIVE",
                 "stage_prompt_sha256" => digest,
                 "expected_sha" => sha,
                 "required_tool_calls" => []
               }
             })

    assert {:ok, _claimed} = DesktopRequest.claim(context.store, request_key)

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET thread_id = ?, verified_project_id = ?, verified_cwd = ?, verified_head_sha = ?, status = 'RECONCILE_REQUIRED', failure_code = 'FINAL_OUTPUT_INVALID_JSON' WHERE request_key = ?",
      ["writer-thread", "grail-project", canonical_checkout, sha, request_key]
    )

    %{
      run_id: run_id,
      task_key: task_key,
      request_key: request_key,
      branch: branch,
      checkout: checkout,
      canonical_checkout: canonical_checkout,
      repo: repo,
      parent_sha: sha
    }
  end

  defp native_verifier_create_failure_fixture(context) do
    writer = native_writer_fixture(context)
    git!(writer.checkout, ["switch", "-c", writer.branch])
    File.write!(Path.join(writer.checkout, "candidate.txt"), "verified candidate\n")
    git!(writer.checkout, ["add", "candidate.txt"])
    git!(writer.checkout, ["commit", "--no-verify", "-m", "feat(PPL-456): candidate"])
    sha = String.trim(git!(writer.checkout, ["rev-parse", "HEAD"]))
    review = writer.checkout <> "-review"
    git!(writer.checkout, ["worktree", "add", "--detach", review, sha])
    {:ok, canonical_review} = SymphonyElixir.PathSafety.canonicalize(review)

    run_id = writer.run_id
    task_key = "#{run_id}:change-verifier:3"
    request_key = "desktop:verifier-create:bootstrap"
    thread_id = "verified-verifier-thread"
    turn_id = "verified-bootstrap-turn"
    project_id = "grail-project"
    digest = String.duplicate("f", 64)
    failure = inspect({:native_verifier_create_uncertain, :task_identity_unproven})

    assert {:ok, _run} =
             RunLedger.update(context.store, run_id, %{
               state: "FAILED",
               failure_code: failure,
               last_error:
                 "Round-3 change-verifier CREATE request #{request_key} has no proven task or turn. " <>
                   "Recover or diagnose queued Codex client thread client-new-thread:queued; prove the exact task ID.",
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               candidate_sha: sha,
               implementation_iteration: 7,
               verifier_round: 3,
               mr_url: "https://gitlab.example.test/grail/-/merge_requests/47489"
             })

    Store.query!(
      context.store,
      "UPDATE factory_tasks SET task_key = ?, stage = 'VERIFYING', role = 'change-verifier', status = 'STALE', failure_code = 'stale task exceeded 90 minutes', thread_id = NULL, codex_project_id = ?, workspace = NULL, workspace_sha = NULL, prompt_sha256 = ? WHERE task_key = ?",
      [task_key, project_id, digest, writer.task_key]
    )

    assert {:ok, _request} =
             DesktopRequest.enqueue(context.store, %{
               request_key: request_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "CREATE",
               codex_project_id: project_id,
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               title: "PPL-456 · R3 · Change Verifier",
               prompt:
                 "Factory request ID: #{request_key}\n\n" <>
                   "Factory workspace bootstrap ID: #{request_key}\n\nPrepare the workspace.",
               schema: %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "required" => ["status"],
                 "properties" => %{"status" => %{"type" => "string", "enum" => ["WORKSPACE_READY"]}}
               },
               cwd: writer.repo,
               branch: writer.branch,
               base_branch: "master",
               metadata: %{
                 "workspace_mode" => "CODEX_NATIVE",
                 "stage_prompt_sha256" => digest,
                 "expected_sha" => sha,
                 "required_tool_calls" => []
               }
             })

    assert {:ok, _claimed} = DesktopRequest.claim(context.store, request_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(context.store, request_key, thread_id, project_id, %{
               cwd: canonical_review,
               head_sha: sha
             })

    assert {:ok, _completed} =
             DesktopRequest.complete(context.store, request_key, %{
               thread_id: thread_id,
               turn_id: turn_id,
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    assert {:ok, _task} = TaskLedger.update(context.store, task_key, %{thread_id: thread_id})

    factory =
      Map.put(context.factory, :repositories, %{
        "grail" => %{"path" => writer.repo, "base_branch" => "master", "codex_project_id" => project_id}
      })

    Map.merge(writer, %{
      factory: factory,
      run_id: run_id,
      task_key: task_key,
      request_key: request_key,
      review_workspace: canonical_review,
      thread_id: thread_id,
      turn_id: turn_id,
      sha: sha
    })
  end

  defp native_bootstrap_failure_fixture(context) do
    writer = native_writer_fixture(context)
    base_branch = writer.branch
    previous_checkout = Path.join(Path.dirname(writer.checkout), "previous-stable-branch")
    git!(writer.repo, ["branch", base_branch, writer.parent_sha])
    git!(writer.repo, ["worktree", "add", previous_checkout, base_branch])
    {:ok, canonical_previous_checkout} = SymphonyElixir.PathSafety.canonicalize(previous_checkout)
    {:ok, run_branch} = Worktree.branch_for_run(%{"path" => writer.repo}, base_branch, writer.run_id)

    Store.query!(context.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [writer.request_key])

    Store.query!(
      context.store,
      "UPDATE factory_tasks SET status = 'STARTING', thread_id = NULL, turn_id = NULL, output_json = NULL, failure_code = NULL, workspace = NULL, workspace_sha = NULL WHERE task_key = ?",
      [writer.task_key]
    )

    Store.query!(
      context.store,
      "UPDATE runs SET state = 'FAILED', failure_code = ?, worktree = NULL, workspace_state = 'UNMATERIALIZED', branch = ?, implementation_iteration = 0 WHERE run_id = ?",
      [inspect({:task_failed, ":native_bootstrap_route_mismatch", :not_applicable}), run_branch, writer.run_id]
    )

    bootstrap_key = "desktop:#{writer.run_id}:bootstrap"
    prompt_digest = String.duplicate("e", 64)

    assert {:ok, _request} =
             DesktopRequest.enqueue(context.store, %{
               request_key: bootstrap_key,
               target_kind: "TASK",
               target_key: writer.task_key,
               action: "CREATE",
               codex_project_id: "grail-project",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               title: "PPL-456 · Feature Writer",
               prompt: "Factory request ID: #{bootstrap_key}\n\nFactory workspace bootstrap ID: #{bootstrap_key}\n\nPrepare the workspace.",
               schema: %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "required" => ["status"],
                 "properties" => %{"status" => %{"type" => "string", "enum" => ["WORKSPACE_READY"]}}
               },
               cwd: writer.repo,
               branch: base_branch,
               base_branch: "master",
               metadata: %{
                 "workspace_mode" => "CODEX_NATIVE",
                 "stage_prompt_sha256" => prompt_digest,
                 "expected_sha" => writer.parent_sha,
                 "required_tool_calls" => []
               }
             })

    assert {:ok, _claimed} = DesktopRequest.claim(context.store, bootstrap_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(
               context.store,
               bootstrap_key,
               "writer-thread",
               "grail-project",
               %{cwd: writer.canonical_checkout, head_sha: writer.parent_sha}
             )

    assert {:ok, _completed} =
             DesktopRequest.complete(context.store, bootstrap_key, %{
               thread_id: "writer-thread",
               turn_id: "bootstrap-turn",
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    failure = inspect({:native_bootstrap_route_mismatch, [:branch_recovery_binding]})

    assert {:ok, _task} =
             TaskLedger.update(context.store, writer.task_key, %{
               status: "FAILED",
               thread_id: "writer-thread",
               workspace: writer.canonical_checkout,
               workspace_sha: writer.parent_sha,
               failure_code: failure
             })

    assert {:ok, _run} =
             RunLedger.update(context.store, writer.run_id, %{
               state: "FAILED",
               failure_code: inspect({:task_failed, failure, :not_applicable}),
               repo_path: writer.repo,
               base_branch: "master",
               branch: run_branch,
               worktree: writer.canonical_checkout,
               workspace_state: "CODEX_NATIVE",
               implementation_iteration: 0
             })

    route = %{"path" => writer.repo, "base_branch" => "master", "codex_project_id" => "grail-project"}

    %{
      run_id: writer.run_id,
      task_key: writer.task_key,
      request_key: bootstrap_key,
      turn_id: "bootstrap-turn",
      thread_id: "writer-thread",
      repo: writer.repo,
      checkout: writer.checkout,
      canonical_checkout: writer.canonical_checkout,
      previous_checkout: canonical_previous_checkout,
      base_branch: base_branch,
      run_branch: run_branch,
      sha: writer.parent_sha,
      factory: Map.put(context.factory, :repositories, %{"grail" => route})
    }
  end

  defp controller_format_repair_fixture(context) do
    thread_id = "controller-thread"
    request_key = "desktop:controller-format-repair"
    completed_turn_id = "malformed-controller-turn"
    control = %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id}

    Control.record_controller_task(context.store, control, thread_id, "prior-controller-turn", %{
      project_id: "projectless",
      resolved_role: "orchestrator",
      provider: "codex",
      model_class: "deep",
      model: "gpt-6-sol",
      reasoning_effort: "high",
      routing_reason: "explicit-role"
    })

    assert {:ok, _request} =
             DesktopRequest.enqueue(context.store, %{
               request_key: request_key,
               target_kind: "CONTROLLER",
               target_key: context.factory.scope,
               action: "FOLLOWUP",
               codex_project_id: "projectless",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               existing_thread_id: thread_id,
               title: "FACTORY Orchestrator",
               prompt: "Factory request ID: #{request_key}\n\nRead Jira and GitLab state.",
               schema: %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "required" => ["status"],
                 "properties" => %{"status" => %{"type" => "string", "enum" => ["PASS"]}}
               },
               cwd: "/tmp/factory-controller",
               metadata: %{
                 "issue_key" => "PPL-10035",
                 "previous_turn_id" => "prior-controller-turn",
                 "format_repair_attempts" => 0,
                 "required_tool_calls" => [],
                 "required_mcp_servers" => ["Jira", "GitLab"],
                 "allowed_mcp_tool_approvals" => []
               }
             })

    assert {:ok, _claimed} = DesktopRequest.claim(context.store, request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(context.store, request_key, thread_id, "projectless")

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED', failure_code = 'FINAL_OUTPUT_INVALID_JSON' WHERE request_key = ?",
      [request_key]
    )

    %{request_key: request_key, completed_turn_id: completed_turn_id, thread_id: thread_id}
  end

  defp completed_revision_fixture(context, output) do
    snapshot = %{"key" => "PPL-123", "description" => "## Ticket Delivery Contract\n\n**Spec revision:** 5", "comments" => []}

    assert {:ok, _run} =
             RunLedger.update(context.store, "run-1", %{
               state: "FAILED",
               failure_code: ":contract_revision_mismatch",
               spec_revision: 6,
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, _task} =
             TaskLedger.update(context.store, context.task_key, %{
               status: "COMPLETE",
               turn_id: "completed-revision-turn",
               failure_code: nil,
               output_json: Jason.encode!(output)
             })

    replace_completed_revision_output(context, output)
  end

  defp replace_completed_revision_output(context, output) do
    assert {:ok, _task} = TaskLedger.update(context.store, context.task_key, %{output_json: Jason.encode!(output)})

    Store.query!(
      context.store,
      "UPDATE desktop_requests SET status = 'SUCCEEDED', failure_code = NULL, turn_id = ?, output_json = ? WHERE request_key = ?",
      ["completed-revision-turn", Jason.encode!(%{"result" => output, "completed_tool_calls" => []}), context.request_key]
    )
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
