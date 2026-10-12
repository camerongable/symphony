defmodule SymphonyElixir.FactoryDesktopRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, DesktopRequest, RunLedger, StageSchemas, Store, TaskLedger}
  alias SymphonyElixir.PathSafety

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "factory-desktop-request-#{token}.sqlite")
    {:ok, store} = Store.start_link(database: database)

    {:ok, _run} =
      RunLedger.register(store, %{
        run_id: "run-1",
        issue_key: "PPL-123",
        kind: "SPECIFICATION",
        state: "DRAFTING"
      })

    {:ok, _task} =
      TaskLedger.register(store, %{
        task_key: "run-1:author",
        run_id: "run-1",
        stage: "DRAFTING",
        role: "specification-author",
        status: "STARTING",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "role-policy",
        codex_project_id: "project-grail",
        prompt_sha256: String.duplicate("a", 64)
      })

    Control.initialize(store, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-1"})

    %{store: store, database: database}
  end

  test "identical enqueue is idempotent while changed payload and competing target fail closed", %{store: store} do
    request = task_request()

    assert {:ok, first} = DesktopRequest.enqueue(store, request)
    assert first["status"] == "PENDING"
    assert first["codex_project_id"] == "project-grail"
    assert first["schema_json"] == ~s({"properties":{"a":{"type":"string"},"b":{"type":"number"}},"type":"object"})

    assert {:ok, duplicate} =
             DesktopRequest.enqueue(
               store,
               put_in(request, [:schema, "properties"], %{
                 "b" => %{"type" => "number"},
                 "a" => %{"type" => "string"}
               })
             )

    assert duplicate["payload_sha256"] == first["payload_sha256"]
    assert duplicate["request_key"] == first["request_key"]

    assert {:error, :request_key_conflict} =
             DesktopRequest.enqueue(store, %{request | prompt: "different prompt"})

    assert {:error, :target_has_unresolved_request} =
             DesktopRequest.enqueue(store, %{request | request_key: "another-create"})

    assert [%{"request_key" => "run-1:author:create"}] = DesktopRequest.list_pending(store)
  end

  test "a claimed create remains uncertain after reopening and cannot authorize duplicate creation", context do
    assert {:ok, _pending} = DesktopRequest.enqueue(context.store, task_request())
    assert {:ok, claimed} = DesktopRequest.claim(context.store, "run-1:author:create")
    assert claimed["status"] == "CREATE_UNCERTAIN"
    assert is_binary(claimed["claimed_at"])
    assert DesktopRequest.list_pending(context.store) == []

    GenServer.stop(context.store)
    {:ok, reopened} = Store.start_link(database: context.database)

    assert {:ok, %{"status" => "CREATE_UNCERTAIN"}} =
             DesktopRequest.get(reopened, "run-1:author:create")

    assert {:error, {:not_claimable, "CREATE_UNCERTAIN"}} =
             DesktopRequest.claim(reopened, "run-1:author:create")

    assert {:error, :target_has_unresolved_request} =
             DesktopRequest.enqueue(reopened, %{task_request() | request_key: "replacement-create"})

    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "claimed_at" => claimed_at}} =
             DesktopRequest.fail(reopened, "run-1:author:create", "BROKER_INTERRUPTED")

    assert claimed_at == claimed["claimed_at"]

    assert [%{"request_key" => "run-1:author:create"}] = DesktopRequest.list_reconciliation(reopened)
    assert DesktopRequest.list_pending(reopened) == []
  end

  test "a reconciliation request does not hide the next independent pending request", %{store: store} do
    assert {:ok, _pending} = DesktopRequest.enqueue(store, task_request())
    assert {:ok, _claimed} = DesktopRequest.claim(store, "run-1:author:create")

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} =
             DesktopRequest.fail(store, "run-1:author:create", "BROKER_INTERRUPTED")

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "run-2",
               issue_key: "PPL-124",
               kind: "SPECIFICATION",
               state: "DRAFTING"
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "run-2:author",
               run_id: "run-2",
               stage: "DRAFTING",
               role: "specification-author",
               status: "STARTING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("b", 64)
             })

    second_request = %{
      task_request()
      | request_key: "run-2:author:create",
        target_key: "run-2:author",
        title: "PPL-124 · Specification Author",
        prompt: "Specify PPL-124"
    }

    assert {:ok, _pending} = DesktopRequest.enqueue(store, second_request)

    assert [%{"request_key" => "run-2:author:create", "status" => "PENDING"}] =
             DesktopRequest.list_pending(store)

    assert [%{"request_key" => "run-1:author:create", "status" => "RECONCILE_REQUIRED"}] =
             DesktopRequest.list_reconciliation(store)

    assert {:error, :target_has_unresolved_request} =
             DesktopRequest.enqueue(store, %{task_request() | request_key: "run-1:author:duplicate"})
  end

  test "project-local contract chat binds its project and prompt without a worktree", %{store: store} do
    repo = "/tmp/grail"
    prompt = "Factory request ID: local-create\n\nDiscuss the revised contract"
    prompt_sha = digest("Discuss the revised contract")

    assert {:ok, _run} =
             RunLedger.update(store, "run-1", %{
               state: "CONTRACT_DISCUSSING",
               parent_run_id: "failed-delivery"
             })

    Store.query!(store, "UPDATE runs SET repo_path = ?, base_branch = ? WHERE run_id = ?", [repo, "master", "run-1"])

    assert {:ok, _task} =
             TaskLedger.update(store, "run-1:author", %{
               stage: "CONTRACT_DISCUSSING",
               prompt_sha256: prompt_sha
             })

    request = %{
      task_request()
      | request_key: "local-create",
        cwd: repo,
        branch: nil,
        prompt: prompt,
        schema: %{
          "type" => "object",
          "required" => ["status"],
          "properties" => %{"status" => %{"type" => "string", "enum" => ["DRAFTED"]}}
        },
        metadata: %{
          "workspace_mode" => "CODEX_PROJECT_LOCAL",
          "issue_key" => "PPL-123",
          "expected_sha" => nil,
          "stage_prompt_sha256" => prompt_sha,
          "previous_turn_id" => nil
        }
    }

    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)

    assert {:error, :project_local_route_proof_required} =
             DesktopRequest.record_thread(store, request.request_key, "local-thread", "project-grail")

    assert {:error, :project_local_path_mismatch} =
             DesktopRequest.record_thread(store, request.request_key, "local-thread", "project-grail", %{cwd: "/tmp/elsewhere"})

    assert {:ok, %{"verified_cwd" => ^repo, "verified_head_sha" => nil}} =
             DesktopRequest.record_thread(store, request.request_key, "local-thread", "project-grail", %{cwd: repo})

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "local-thread",
               turn_id: "local-turn-1",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "local-turn-1", "workspace" => nil, "workspace_sha" => nil}} =
             TaskLedger.get(store, "run-1:author")

    assert {:ok, %{"worktree" => nil}} = RunLedger.get(store, "run-1")

    followup_prompt = "Factory request ID: local-followup\n\nRefine the revised contract"
    followup_sha = digest("Refine the revised contract")
    assert {:ok, _task} = TaskLedger.update(store, "run-1:author", %{status: "RETRY_PENDING", prompt_sha256: followup_sha})

    followup =
      request
      |> Map.merge(%{
        request_key: "local-followup",
        action: "FOLLOWUP",
        existing_thread_id: "local-thread",
        prompt: followup_prompt,
        metadata:
          Map.merge(request.metadata, %{
            "stage_prompt_sha256" => followup_sha,
            "previous_turn_id" => "local-turn-1"
          })
      })

    assert {:ok, _pending} = DesktopRequest.enqueue(store, followup)
    assert {:ok, _claimed} = DesktopRequest.claim(store, followup.request_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, followup.request_key, "local-thread", "project-grail", %{cwd: repo})

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "local-thread",
               turn_id: "local-turn-2",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "local-turn-2", "workspace" => nil}} =
             TaskLedger.get(store, "run-1:author")
  end

  test "normalizes the review skill's exact critic JSON only when provenance matches", %{store: store} do
    digest = String.duplicate("b", 64)

    assert {:ok, _run} =
             RunLedger.update(store, "run-1", %{
               state: "SPEC_REVIEW",
               spec_revision: 2,
               contract_sha256: digest,
               snapshot_json: Jason.encode!(%{"updated" => "2026-09-24 21:37:39 PDT"})
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "run-1:specification-critic:1",
               run_id: "run-1",
               stage: "SPEC_REVIEW",
               role: "specification-critic",
               status: "STARTING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               thread_id: "critic-thread",
               prompt_sha256: String.duplicate("a", 64)
             })

    request =
      task_request()
      |> Map.put(:request_key, "run-1:critic:followup")
      |> Map.put(:target_key, "run-1:specification-critic:1")
      |> Map.put(:action, "FOLLOWUP")
      |> Map.put(:existing_thread_id, "critic-thread")
      |> Map.put(:schema, StageSchemas.for_stage(:specification_critic))

    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request.request_key, "critic-thread", "project-grail")

    review = %{
      "verdict" => "NEEDS_DECISION",
      "issue_key" => "PPL-123",
      "spec_revision" => 2,
      "jira_update_marker" => "2026-09-24 21:37:39 PDT",
      "contract_sha256" => digest,
      "dimension_results" => [%{"dimension" => "acceptance", "pass" => false, "evidence" => "AC-7 conflicts"}],
      "blocking_issues" => ["Revise AC-7"],
      "questions" => ["Which incomplete-scan notice should appear?"],
      "recommended_default" => "Use a distinct notice"
    }

    assert {:error, :invalid_specification_critic_review} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "critic-thread",
               turn_id: "critic-turn",
               output: broker_output(%{review | "contract_sha256" => String.duplicate("0", 64)})
             })

    assert {:ok, %{"status" => "SUCCEEDED", "output_json" => output_json}} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "critic-thread",
               turn_id: "critic-turn",
               output: broker_output(review)
             })

    assert Jason.decode!(output_json)["result"] == %{
             "status" => "BLOCK",
             "findings" => ["Revise AC-7"],
             "required_questions" => ["Which incomplete-scan notice should appear?"]
           }
  end

  test "reconciles a completed change verifier report into one repair result", %{store: store} do
    workspace = Path.join(System.tmp_dir!(), "verifier-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    git!(workspace, ["init", "-b", "master"])
    git!(workspace, ["config", "user.email", "factory@example.com"])
    git!(workspace, ["config", "user.name", "Factory test"])
    File.write!(Path.join(workspace, "README.md"), "base\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "--no-verify", "-m", "base"])
    base_sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
    git!(workspace, ["update-ref", "refs/remotes/origin/master", base_sha])
    File.write!(Path.join(workspace, "README.md"), "candidate\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "--no-verify", "-m", "candidate"])
    sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
    contract_sha = String.duplicate("b", 64)
    prompt_sha = String.duplicate("c", 64)
    request_key = "delivery-run:verifier:followup"
    task_key = "delivery-run:change-verifier:1"

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "delivery-run",
               issue_key: "PPL-10035",
               kind: "DELIVERY",
               state: "VERIFYING",
               spec_revision: 2,
               contract_sha256: contract_sha,
               candidate_sha: sha,
               base_branch: "master",
               branch: "cgable/PPL-10035-feature",
               manual_validation_required: false
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: task_key,
               run_id: "delivery-run",
               stage: "VERIFYING",
               role: "change-verifier",
               status: "RUNNING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               thread_id: "verifier-thread",
               turn_id: "previous-turn",
               workspace: workspace,
               workspace_sha: sha,
               prompt_sha256: prompt_sha
             })

    assert {:ok, _task} = TaskLedger.update(store, task_key, %{turn_id: "previous-turn"})

    request =
      %{
        task_request()
        | request_key: request_key,
          target_key: task_key,
          action: "FOLLOWUP",
          reasoning_effort: "xhigh",
          prompt: "Factory request ID: #{request_key}\n\nReview candidate",
          schema: StageSchemas.for_stage(:change_verifier),
          cwd: workspace,
          branch: "cgable/PPL-10035-feature",
          base_branch: "master",
          metadata: %{
            "workspace_mode" => "CODEX_NATIVE",
            "expected_sha" => sha,
            "previous_turn_id" => "previous-turn",
            "stage_prompt_sha256" => prompt_sha,
            "required_tool_calls" => []
          }
      }
      |> Map.put(:existing_thread_id, "verifier-thread")

    assert {:ok, _request} = DesktopRequest.enqueue(store, request)
    assert {:ok, _request} = DesktopRequest.claim(store, request_key)

    Store.query!(
      store,
      "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED', thread_id = ?, verified_project_id = ?, verified_cwd = ?, verified_head_sha = ?, failure_code = 'FINAL_OUTPUT_SCHEMA_MISMATCH' WHERE request_key = ?",
      ["verifier-thread", "project-grail", workspace, sha, request_key]
    )

    review = %{
      "verdict" => "REPAIR",
      "issue_key" => "PPL-10035",
      "spec_revision" => 2,
      "contract_sha256" => contract_sha,
      "base_ref" => base_sha,
      "head_sha" => sha,
      "review_worktree" => workspace,
      "acceptance" => [
        %{"id" => "AC-1", "result" => "PASS", "evidence" => "source path:10"},
        %{"id" => "AC-2", "result" => "FAIL", "evidence" => "DB and worker test absent"}
      ],
      "checks" => [
        %{"command_or_pipeline" => "git diff --check", "result" => "PASS", "scope" => "feature diff"},
        %{"command_or_pipeline" => "focused Bazel test", "result" => "NOT_RUN", "scope" => "sandbox denied"}
      ],
      "manual_validation" => %{"required" => false, "plan_ready" => true, "case_ids" => [], "blockers" => []},
      "risks" => ["Runtime behavior remains untested"],
      "reviewer_tracked_changes" => [],
      "blocking_issues" => ["AC-2 lacks combined evidence"],
      "required_repairs" => ["Add DB-backed worker test with different defaults"]
    }

    for invalid <- [
          %{review | "head_sha" => String.duplicate("0", 40)},
          %{review | "base_ref" => String.duplicate("0", 40)},
          %{review | "contract_sha256" => String.duplicate("0", 64)},
          put_in(review, ["manual_validation", "required"], true),
          %{review | "required_repairs" => []}
        ] do
      assert {:error, :invalid_change_verifier_review} =
               DesktopRequest.complete(store, request_key, %{
                 thread_id: "verifier-thread",
                 turn_id: "completed-turn",
                 output: broker_output(invalid)
               })
    end

    assert {:ok, %{"status" => "SUCCEEDED", "output_json" => output_json}} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "verifier-thread",
               turn_id: "completed-turn",
               output:
                 Map.put(broker_output(review), "completed_tool_calls", [
                   %{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed"}
                 ])
             })

    assert Jason.decode!(output_json)["result"] == %{
             "status" => "REPAIR",
             "candidate_sha" => sha,
             "findings" => ["AC-2 lacks combined evidence", "Add DB-backed worker test with different defaults"],
             "checks" => ["PASS: git diff --check [feature diff]", "NOT_RUN: focused Bazel test [sandbox denied]"]
           }

    assert Jason.decode!(output_json)["completed_tool_calls"] == [
             %{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed"}
           ]

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "completed-turn"}} = TaskLedger.get(store, task_key)
  end

  test "losslessly adapts one legacy native writer slice manifest to its persisted schema", %{store: store} do
    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "delivery-run",
               issue_key: "PPL-9723",
               kind: "DELIVERY",
               state: "WRITING"
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "delivery-run:feature-writer",
               run_id: "delivery-run",
               stage: "WRITING",
               role: "feature-writer-high-risk",
               status: "RUNNING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               routing_reason: "risk-escalation",
               codex_project_id: "project-grail",
               thread_id: "writer-thread",
               prompt_sha256: digest("Write one slice")
             })

    legacy_schema =
      StageSchemas.for_stage(:native_feature_writer)
      |> Map.update!("required", &(&1 ++ ["summary", "remaining_criteria"]))
      |> update_in(["properties"], &Map.delete(&1, "next_slice"))

    request =
      %{
        task_request()
        | request_key: "delivery-run:writer:followup",
          target_key: "delivery-run:feature-writer",
          action: "FOLLOWUP",
          reasoning_effort: "xhigh",
          prompt: "Factory request ID: delivery-run:writer:followup\n\nWrite one slice",
          schema: legacy_schema
      }
      |> Map.put(:existing_thread_id, "writer-thread")

    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request.request_key, "writer-thread", "project-grail")

    raw = %{
      "status" => "CONTINUE",
      "changed_paths" => ["go/src/grail.com/doc-extract/server/service/ai/base/BUILD"],
      "commit_message" => "feat(PPL-9723): add PDF visual findings contract and shared parse",
      "checks" => ["Focused tests passed"],
      "blockers" => [],
      "next_slice" => "Implement bounded visual scanning"
    }

    assert {:error, :factory_stage_output_schema_mismatch} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "writer-thread",
               turn_id: "writer-turn",
               output: broker_output(Map.delete(raw, "checks"))
             })

    assert {:ok, %{"status" => "SUCCEEDED", "output_json" => output_json}} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "writer-thread",
               turn_id: "writer-turn",
               output: broker_output(raw)
             })

    assert Jason.decode!(output_json)["result"] ==
             raw
             |> Map.delete("next_slice")
             |> Map.put("summary", raw["commit_message"])
             |> Map.put("remaining_criteria", [raw["next_slice"]])
  end

  test "a native project task cannot bind from a project ID assertion alone", %{store: store} do
    request = put_in(task_request(), [:metadata], %{"issue_key" => "PPL-123", "workspace_mode" => "CODEX_NATIVE"})
    assert {:ok, _request} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)

    assert {:error, :native_workspace_proof_required} =
             DesktopRequest.record_thread(store, request.request_key, "thread-1", "project-grail")

    assert {:ok, %{"thread_id" => nil, "status" => "CREATE_UNCERTAIN"}} =
             DesktopRequest.get(store, request.request_key)
  end

  test "a native task cannot bind without a configured repository route", %{store: store} do
    sha = String.duplicate("a", 40)

    request =
      put_in(task_request(), [:metadata], %{
        "issue_key" => "PPL-123",
        "workspace_mode" => "CODEX_NATIVE",
        "expected_sha" => sha
      })

    assert {:ok, _request} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)

    assert {:error, :native_repository_route_missing} =
             DesktopRequest.record_thread(store, request.request_key, "thread-1", "project-grail", %{
               cwd: "/tmp/unknown-native-worktree",
               head_sha: sha
             })

    assert {:ok, %{"thread_id" => nil, "status" => "CREATE_UNCERTAIN"}} =
             DesktopRequest.get(store, request.request_key)
  end

  test "a native project task binds only a registered checkout at the pinned base and follows up there", %{
    store: store,
    database: database
  } do
    root = Path.join(System.tmp_dir!(), "factory-native-request-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    checkout = Path.join(root, "native")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    git!(root, ["init", "--bare", origin])
    git!(root, ["clone", origin, repo])
    git!(repo, ["config", "user.email", "factory@example.test"])
    git!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "--no-verify", "-m", "base"])
    git!(repo, ["branch", "-M", "master"])
    git!(repo, ["push", "--no-verify", "origin", "master"])
    git!(repo, ["worktree", "add", "--detach", checkout, "HEAD"])
    sha = String.trim(git!(repo, ["rev-parse", "HEAD"]))
    {:ok, canonical_checkout} = PathSafety.canonicalize(checkout)

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "native-run",
               issue_key: "PPL-456",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               repo_key: "grail",
               repo_path: repo,
               base_branch: "master",
               factory_owned: false
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "native-run:author",
               run_id: "native-run",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "STARTING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("a", 64)
             })

    request = %{
      task_request()
      | request_key: "native-run:author:create",
        target_key: "native-run:author",
        cwd: repo,
        branch: nil,
        metadata: %{"issue_key" => "PPL-456", "workspace_mode" => "CODEX_NATIVE", "expected_sha" => sha}
    }

    assert {:ok, _request} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)

    assert {:error, :native_workspace_proof_incomplete} =
             DesktopRequest.record_thread(store, request.request_key, "native-thread", "project-grail", %{
               cwd: checkout
             })

    assert {:error, :native_workspace_sha_mismatch} =
             DesktopRequest.record_thread(store, request.request_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: String.duplicate("a", 40)
             })

    assert {:error, :native_worktree_missing} =
             DesktopRequest.record_thread(store, request.request_key, "native-thread", "project-grail", %{
               cwd: Path.join(root, "missing"),
               head_sha: sha
             })

    assert {:ok, %{"verified_cwd" => ^canonical_checkout, "verified_head_sha" => ^sha}} =
             DesktopRequest.record_thread(store, request.request_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, %{"thread_id" => "native-thread", "workspace" => ^canonical_checkout, "workspace_sha" => ^sha}} =
             TaskLedger.get(store, "native-run:author")

    assert {:ok, %{"worktree" => ^canonical_checkout, "workspace_state" => "CODEX_NATIVE"}} =
             RunLedger.get(store, "native-run")

    assert {:ok, _completed} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "native-thread",
               turn_id: "turn-1",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "STARTING", "turn_id" => nil}} =
             TaskLedger.get(store, "native-run:author")

    assert {:ok, %{"status" => "SUCCEEDED", "thread_id" => "native-thread"}} =
             DesktopRequest.record_thread(store, request.request_key, "native-thread", "project-grail")

    assert {:error, :thread_already_exists} =
             DesktopRequest.enqueue(store, %{request | request_key: "replacement-create"})

    followup =
      request
      |> Map.put(:request_key, "native-run:author:followup")
      |> Map.put(:action, "FOLLOWUP")
      |> Map.put(:existing_thread_id, "native-thread")
      |> Map.put(:prompt, "Factory request ID: native-run:author:followup\n\nContinue the same task")
      |> Map.put(:metadata, %{
        "issue_key" => "PPL-456",
        "workspace_mode" => "CODEX_NATIVE",
        "expected_sha" => sha,
        "previous_turn_id" => "turn-1",
        "stage_prompt_sha256" => digest("Continue the same task")
      })

    assert {:ok, _task} =
             TaskLedger.update(store, "native-run:author", %{prompt_sha256: digest("Continue the same task")})

    assert {:ok, _request} = DesktopRequest.enqueue(store, followup)
    assert {:ok, _claimed} = DesktopRequest.claim(store, followup.request_key)

    assert {:ok, %{"thread_id" => "native-thread", "verified_cwd" => ^canonical_checkout}} =
             DesktopRequest.record_thread(store, followup.request_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, _task} = TaskLedger.update(store, "native-run:author", %{status: "WAITING_FOR_BROKER"})

    assert {:error, :invalid_broker_output} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "native-thread",
               turn_id: "turn-2",
               output: %{"result" => "not structured", "completed_tool_calls" => []}
             })

    assert {:ok, %{"status" => "WAITING_FOR_BROKER", "turn_id" => nil}} =
             TaskLedger.get(store, "native-run:author")

    assert {:ok, _completed} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "native-thread",
               turn_id: "turn-2",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "turn-2", "output_json" => output_json}} =
             TaskLedger.get(store, "native-run:author")

    assert Jason.decode!(output_json) == %{"status" => "DRAFTED"}

    {:ok, reopened} = Store.start_link(database: database)

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "turn-2", "output_json" => ^output_json}} =
             TaskLedger.get(reopened, "native-run:author")

    assert {:ok, _task} = TaskLedger.update(store, "native-run:author", %{status: "CONSUMED"})

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "native-thread",
               turn_id: "turn-2",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "CONSUMED", "turn_id" => "turn-2"}} =
             TaskLedger.get(store, "native-run:author")

    assert {:ok, _task} =
             TaskLedger.update(store, "native-run:author", %{status: "RETRY_PENDING", output_json: nil})

    assert {:ok, _v1} = RunLedger.register(store, %{run_id: "newer-supervisor", issue_key: "PPL-456", kind: "DELIVERY", state: "READY_FOR_REVIEW", execution_mode: "TICKET_SUPERVISOR_V1"})
    quarantined_task = Store.query!(store, "SELECT * FROM factory_tasks WHERE task_key = 'native-run:author'").rows
    quarantined_request = Store.query!(store, "SELECT * FROM desktop_requests WHERE request_key = ?", [followup.request_key]).rows

    assert :ok = DesktopRequest.reconcile_native_successes(store)

    assert {:ok, %{"status" => "RETRY_PENDING", "turn_id" => "turn-2", "output_json" => nil}} =
             TaskLedger.get(store, "native-run:author")

    assert Store.query!(store, "SELECT * FROM factory_tasks WHERE task_key = 'native-run:author'").rows == quarantined_task
    assert Store.query!(store, "SELECT * FROM desktop_requests WHERE request_key = ?", [followup.request_key]).rows == quarantined_request
    Store.query!(store, "UPDATE runs SET issue_key = 'PPL-457' WHERE run_id = 'newer-supervisor'")

    assert {:ok, _task} =
             TaskLedger.update(store, "native-run:author", %{
               status: "WAITING_FOR_BROKER",
               output_json: nil,
               turn_id: nil
             })

    legacy_metadata = Map.delete(followup.metadata, "stage_prompt_sha256") |> Jason.encode!()

    Store.query!(store, "UPDATE desktop_requests SET metadata_json = ? WHERE request_key = ?", [
      legacy_metadata,
      followup.request_key
    ])

    assert :ok = DesktopRequest.reconcile_native_successes(store)

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "turn-2", "output_json" => ^output_json}} =
             TaskLedger.get(store, "native-run:author")

    File.write!(Path.join(checkout, "UNEXPECTED.md"), "drift\n")
    git!(checkout, ["add", "UNEXPECTED.md"])
    git!(checkout, ["commit", "--no-verify", "-m", "unexpected drift"])
    drifted_sha = String.trim(git!(checkout, ["rev-parse", "HEAD"]))

    drifted_followup = %{
      followup
      | request_key: "native-run:author:drifted-followup",
        prompt: "Continue after drift",
        metadata: Map.put(followup.metadata, "previous_turn_id", "turn-2")
    }

    assert {:ok, _request} = DesktopRequest.enqueue(store, drifted_followup)
    assert {:ok, _claimed} = DesktopRequest.claim(store, drifted_followup.request_key)

    assert {:error, {:native_worktree_sha_mismatch, ^sha, ^drifted_sha}} =
             DesktopRequest.record_thread(store, drifted_followup.request_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: drifted_sha
             })
  end

  test "thread readback binds one worker and follow-ups preserve its exact identity", %{store: store} do
    assert {:ok, _request} = DesktopRequest.enqueue(store, task_request())
    assert {:ok, _claimed} = DesktopRequest.claim(store, "run-1:author:create")

    assert {:error, {:missing_field, :thread_id}} =
             DesktopRequest.record_thread(store, "run-1:author:create", "", "project-grail")

    assert {:error, :project_route_mismatch} =
             DesktopRequest.record_thread(store, "run-1:author:create", "thread-1", "projectless")

    assert {:ok, %{"status" => "THREAD_RECORDED", "thread_id" => "thread-1"}} =
             DesktopRequest.record_thread(store, "run-1:author:create", "thread-1", "project-grail")

    assert {:ok, %{"thread_id" => "thread-1"}} = TaskLedger.get(store, "run-1:author")

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(store, "run-1:author:create", %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.record_thread(store, "run-1:author:create", "thread-1", "project-grail")

    followup =
      task_request()
      |> Map.put(:request_key, "run-1:author:followup:2")
      |> Map.put(:action, "FOLLOWUP")
      |> Map.put(:existing_thread_id, "thread-1")
      |> Map.put(:prompt, "Continue the same specification")
      |> Map.put(:metadata, %{"previous_turn_id" => "turn-1"})

    assert {:ok, %{"existing_thread_id" => "thread-1"}} = DesktopRequest.enqueue(store, followup)

    assert {:ok, %{"status" => "FOLLOWUP_UNCERTAIN"}} =
             DesktopRequest.claim(store, followup.request_key)

    assert {:error, :thread_route_mismatch} =
             DesktopRequest.record_thread(store, followup.request_key, "thread-2", "project-grail")

    assert {:ok, %{"status" => "THREAD_RECORDED"}} =
             DesktopRequest.record_thread(store, followup.request_key, "thread-1", "project-grail")

    assert {:error, :turn_replayed} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:error, :turn_id_missing} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "thread-1",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:error, :thread_route_mismatch} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "thread-2",
               turn_id: "turn-2",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "SUCCEEDED", "thread_id" => "thread-1"}} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-2",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    later_followup =
      followup
      |> Map.put(:request_key, "run-1:author:followup:3")
      |> Map.put(:metadata, %{"previous_turn_id" => "turn-2"})

    assert {:ok, _request} = DesktopRequest.enqueue(store, later_followup)
    assert {:ok, _claimed} = DesktopRequest.claim(store, later_followup.request_key)

    assert {:ok, %{"status" => "THREAD_RECORDED"}} =
             DesktopRequest.record_thread(
               store,
               later_followup.request_key,
               "thread-1",
               "project-grail"
             )

    assert {:error, :turn_replayed} =
             DesktopRequest.complete(store, later_followup.request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(store, later_followup.request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-3",
               output: broker_output(%{"status" => "DRAFTED"})
             })
  end

  test "project, model, effort and thread mismatches are rejected before enqueue", %{store: store} do
    request = task_request()

    assert {:error, :project_route_mismatch} =
             DesktopRequest.enqueue(store, %{request | codex_project_id: "project-other"})

    assert {:error, :model_route_mismatch} =
             DesktopRequest.enqueue(store, %{request | model: "gpt-6-luna"})

    assert {:error, :effort_route_mismatch} =
             DesktopRequest.enqueue(store, %{request | reasoning_effort: "low"})

    assert {:error, :thread_route_mismatch} =
             DesktopRequest.enqueue(
               store,
               request |> Map.put(:action, "FOLLOWUP") |> Map.put(:existing_thread_id, "unknown-thread")
             )

    assert DesktopRequest.list_pending(store) == []
  end

  test "controller operations bind to the control scope without a factory task", %{store: store} do
    request = %{
      request_key: "controller:read-jira:1",
      target_kind: "CONTROLLER",
      target_key: "assigned-jira-work",
      action: "CREATE",
      codex_project_id: "project-factory",
      model: "gpt-6-sol",
      reasoning_effort: "medium",
      title: "FACTORY Orchestrator",
      prompt: "Read Jira intake",
      schema: %{"type" => "object"},
      cwd: "/tmp/factory-controller",
      branch: nil,
      metadata: %{"issue_key" => "PPL-123"}
    }

    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request.request_key, "controller-thread", "project-factory")

    assert %{
             "controller_thread_id" => "controller-thread",
             "controller_codex_project_id" => "project-factory",
             "controller_model" => "gpt-6-sol",
             "controller_reasoning_effort" => "medium"
           } = Control.status(store, "assigned-jira-work")

    assert {:ok, %{"status" => "SUCCEEDED"}} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "controller-thread",
               turn_id: "turn-1",
               output: broker_output(%{"issues" => []})
             })

    followup =
      request
      |> Map.put(:request_key, "controller:read-jira:2")
      |> Map.put(:action, "FOLLOWUP")
      |> Map.put(:existing_thread_id, "controller-thread")

    assert {:ok, %{"existing_thread_id" => "controller-thread"}} =
             DesktopRequest.enqueue(store, followup)

    assert {:ok, %{"status" => "FOLLOWUP_UNCERTAIN"}} =
             DesktopRequest.claim(store, followup.request_key)

    assert {:ok, _same_thread} =
             DesktopRequest.record_thread(store, followup.request_key, "controller-thread", "project-factory")

    assert {:ok, _completed} =
             DesktopRequest.complete(store, followup.request_key, %{
               thread_id: "controller-thread",
               turn_id: "turn-2",
               output: broker_output(%{"issues" => []})
             })

    assert {:error, :project_route_mismatch} =
             DesktopRequest.enqueue(store, %{followup | request_key: "controller:wrong-project", codex_project_id: "other"})

    next_role =
      followup
      |> Map.put(:request_key, "controller:write-jira:3")
      |> Map.put(:model, "gpt-6-luna")
      |> Map.put(:reasoning_effort, "low")

    assert {:ok, %{"model" => "gpt-6-luna", "reasoning_effort" => "low"}} =
             DesktopRequest.enqueue(store, next_role)
  end

  test "an unissued V1 feedback controller request is hidden from and rejected by the broker", %{store: store} do
    assert {:ok, _v1} = RunLedger.register(store, %{run_id: "supervisor", issue_key: "PPL-900", kind: "DELIVERY", state: "READY_FOR_REVIEW", execution_mode: "TICKET_SUPERVISOR_V1"})

    request = %{
      request_key: "v1-feedback-request",
      target_kind: "CONTROLLER",
      target_key: "assigned-jira-work",
      action: "CREATE",
      codex_project_id: "project-factory",
      model: "gpt-6-sol",
      reasoning_effort: "medium",
      title: "Feedback",
      prompt: "Read feedback",
      schema: %{"type" => "object"},
      cwd: "/tmp/factory-controller",
      metadata: %{"issue_key" => "PPL-900"}
    }

    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)

    Store.query!(store, """
    INSERT INTO mr_feedback_notes (feedback_key, run_id, project, mr_iid, discussion_id, note_id,
      note_updated_at, author_id, body_sha256, status, request_key, created_at, updated_at)
    VALUES ('v1-note', 'supervisor', 'grailbio/grail', 900, 'discussion-900', 901,
      '2026-10-01T00:00:00Z', 12, '#{String.duplicate("a", 64)}', 'CLAIMED',
      'v1-feedback-request', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')
    """)

    assert DesktopRequest.list_pending(store) == []
    assert {:error, :request_run_quarantined} = DesktopRequest.claim(store, "v1-feedback-request")
    assert {:ok, %{"status" => "PENDING"}} = DesktopRequest.get(store, "v1-feedback-request")
    assert not DesktopRequest.controller_busy?(store, "assigned-jira-work")

    Store.query!(store, "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN' WHERE request_key = ?", [request.request_key])
    assert_quarantined_mutations(store, request.request_key, request.codex_project_id)
    Store.query!(store, "UPDATE desktop_requests SET status = 'PENDING' WHERE request_key = ?", [request.request_key])

    for {field, value} <- [
          {"status", "FOLLOWUP_UNCERTAIN"},
          {"thread_id", "observed-thread"},
          {"turn_id", "observed-turn"},
          {"target_observation_json", "{}"},
          {"verified_cwd", "/tmp/observed"},
          {"output_json", "{}"}
        ] do
      Store.query!(store, "UPDATE desktop_requests SET #{field} = ? WHERE request_key = ?", [value, request.request_key])
      assert DesktopRequest.controller_busy?(store, "assigned-jira-work")
      assert not DesktopRequest.controller_busy?(store, "other-scope")
      reset = if field == "status", do: "PENDING", else: nil
      Store.query!(store, "UPDATE desktop_requests SET #{field} = ? WHERE request_key = ?", [reset, request.request_key])
    end

    Store.query!(store, "UPDATE mr_feedback_notes SET run_id = 'run-1' WHERE feedback_key = 'v1-note'")
    assert DesktopRequest.controller_busy?(store)
    Store.query!(store, "DELETE FROM mr_feedback_notes WHERE feedback_key = 'v1-note'")
    assert DesktopRequest.controller_busy?(store)
  end

  test "V1 task requests are hidden from all broker queues and direct claims", %{store: store} do
    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "supervisor-task-run",
               issue_key: "PPL-901",
               kind: "SPECIFICATION",
               state: "DRAFTING",
               execution_mode: "TICKET_SUPERVISOR_V1"
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "supervisor-task-run:author",
               run_id: "supervisor-task-run",
               stage: "DRAFTING",
               role: "specification-author",
               status: "WAITING_FOR_BROKER",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("c", 64)
             })

    request = %{task_request() | request_key: "supervisor-task-run:author:create", target_key: "supervisor-task-run:author", metadata: %{"issue_key" => "PPL-901"}}
    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)
    assert DesktopRequest.list_pending(store) == []
    assert {:error, :request_run_quarantined} = DesktopRequest.claim(store, request.request_key)

    Store.query!(store, "UPDATE desktop_requests SET status = 'CREATE_UNCERTAIN' WHERE request_key = ?", [request.request_key])
    assert DesktopRequest.list_reconciliation(store) == []
    assert {:ok, %{"status" => "CREATE_UNCERTAIN"}} = DesktopRequest.get(store, request.request_key)
    assert_quarantined_mutations(store, request.request_key, request.codex_project_id)
  end

  defp assert_quarantined_mutations(store, request_key, project_id) do
    tables = ~w(runs factory_tasks desktop_requests mr_feedback_notes events)
    before = Enum.map(tables, &Store.query!(store, "SELECT * FROM #{&1} ORDER BY rowid").rows)
    assert {:error, :request_run_quarantined} = DesktopRequest.record_thread(store, request_key, "new-thread", project_id)

    assert {:error, :request_run_quarantined} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "new-thread",
               turn_id: "new-turn",
               output: broker_output(%{"status" => "DRAFTED"})
             })

    assert {:error, :request_run_quarantined} = DesktopRequest.fail(store, request_key, "BROKER_INTERRUPTED")
    assert Enum.map(tables, &Store.query!(store, "SELECT * FROM #{&1} ORDER BY rowid").rows) == before
  end

  test "a bound controller request can complete a proven turn after output reconciliation", %{store: store} do
    control = %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-1"}
    Control.record_controller_task(store, control, "controller-thread", nil, %{project_id: "projectless"})

    request = %{
      request_key: "controller:intake:recovery",
      target_kind: "CONTROLLER",
      target_key: "assigned-jira-work",
      action: "FOLLOWUP",
      existing_thread_id: "controller-thread",
      codex_project_id: "projectless",
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      title: "FACTORY · assigned-jira-work · Orchestrator",
      prompt: "Factory request ID: controller:intake:recovery\n\nRead Jira",
      schema: put_in(StageSchemas.for_stage(:jira_snapshot), ["properties", "snapshot_json"], %{"type" => "string"}),
      cwd: "/tmp/factory-controller",
      metadata: %{"issue_key" => "QUEUE"}
    }

    assert {:ok, _pending} = DesktopRequest.enqueue(store, request)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request.request_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, request.request_key, "controller-thread", "projectless")

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} =
             DesktopRequest.fail(store, request.request_key, "OUTPUT_SCHEMA_INVALID_SNAPSHOT_JSON_TYPE")

    assert DesktopRequest.list_pending(store) == []

    assert [%{"request_key" => "controller:intake:recovery", "status" => "RECONCILE_REQUIRED"}] =
             DesktopRequest.list_reconciliation(store)

    assert {:error, :target_has_unresolved_request} =
             DesktopRequest.enqueue(store, %{request | request_key: "controller:intake:duplicate"})

    assert {:ok, %{"status" => "SUCCEEDED", "failure_code" => nil}} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "controller-thread",
               turn_id: "readback-turn",
               output: broker_output(%{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => [%{}]})
             })

    assert {:ok, completed} = DesktopRequest.get(store, request.request_key)
    assert %{"result" => %{"snapshot_json" => "[{}]"}} = Jason.decode!(completed["output_json"])

    assert {:error, :completion_conflict} =
             DesktopRequest.complete(store, request.request_key, %{
               thread_id: "controller-thread",
               turn_id: "different-turn",
               output: broker_output(%{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => [%{}]})
             })
  end

  defp task_request do
    %{
      request_key: "run-1:author:create",
      target_kind: "TASK",
      target_key: "run-1:author",
      action: "CREATE",
      codex_project_id: "project-grail",
      model: "gpt-6-sol",
      reasoning_effort: "high",
      title: "PPL-123 · Specification Author",
      prompt: "Specify work",
      schema: %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "number"}}
      },
      cwd: "/tmp/grail-worktree",
      branch: "cgable/PPL-123-spec",
      base_branch: "master",
      metadata: %{"issue_key" => "PPL-123"}
    }
  end

  defp broker_output(result), do: %{"result" => result, "completed_tool_calls" => []}

  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
