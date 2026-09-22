defmodule SymphonyElixir.FactorySchedulerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Contract, RunLedger, Scheduler, Store, TaskLedger}

  defmodule FakeControllerTask do
    @spec run(map(), Path.t(), map(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_factory, _workspace, _issue, prompt, _schema, _opts) do
      send(self(), {:controller_prompt, prompt})

      case Process.get(:factory_controller_responses) do
        [response | rest] ->
          Process.put(:factory_controller_responses, rest)
          {:ok, response}

        _other ->
          {:ok, Process.get(:factory_controller_response)}
      end
    end
  end

  defmodule FakeTaskLauncher do
    @spec launch(term(), term(), map(), map(), Path.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def launch(store, _supervisor, run, _issue, workspace, prompt, _schema, opts) do
      attrs = %{
        task_key: opts[:task_key],
        run_id: run["run_id"],
        stage: opts[:stage],
        role: opts[:role],
        status: "RUNNING",
        model_provider: "codex",
        model_class: "test",
        model: "gpt-test",
        reasoning_effort: "medium",
        routing_reason: "test",
        codex_project_id: opts[:project_id],
        codex_section_id: opts[:section_id],
        prompt_sha256: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
      }

      case TaskLedger.get(store, opts[:task_key]) do
        {:ok, _task} ->
          TaskLedger.update(store, opts[:task_key], Map.put(attrs, :output_json, nil))

        {:error, :unknown_task} ->
          TaskLedger.register(store, attrs)
      end

      send(self(), {:stage_launch, run["run_id"], workspace, prompt, opts})
      pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: pid, ref: make_ref(), task_key: opts[:task_key], route: %{}}}
    end
  end

  defmodule FakeCleanup do
    @spec ensure_capacity(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def ensure_capacity(_store, _policy, repo_key, _opts \\ []) do
      {:ok, %{repo_key: repo_key, available_writer_slots: 1, cleaned: []}}
    end

    @spec hibernate(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def hibernate(_store, _policy, run_id, _opts \\ []) do
      send(self(), {:hibernate, run_id})
      {:ok, %{result: "SKIPPED", run_id: run_id, reason: "test"}}
    end
  end

  defmodule FakeWorktree do
    @candidate String.duplicate("a", 40)

    @spec base_sha(map()) :: {:ok, String.t()}
    def base_sha(_route), do: {:ok, String.duplicate("b", 40)}

    @spec ensure_writer(map(), String.t(), String.t()) :: {:ok, map()}
    def ensure_writer(route, issue_key, run_id) do
      path = Path.join(route["workspace_root"], "#{issue_key}-#{run_id}-writer")
      File.mkdir_p!(path)
      send(self(), {:ensure_writer, route, issue_key, run_id})
      {:ok, %{path: path, branch: route["branch"], base_branch: "master", head: @candidate}}
    end

    @spec candidate(Path.t(), String.t()) :: {:ok, String.t()}
    def candidate(_path, _base), do: {:ok, @candidate}

    @spec create_detached(map(), String.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()}
    def create_detached(route, _issue_key, run_id, stage, _sha) do
      path = Path.join(route["workspace_root"], "#{run_id}-#{stage}")
      File.mkdir_p!(path)
      {:ok, path}
    end

    @spec remove_detached(map(), Path.t()) :: :ok
    def remove_detached(_route, _path), do: :ok

    @spec reachable?(map(), String.t()) :: boolean()
    def reachable?(_route, @candidate), do: true

    @spec push_exact(map(), Path.t(), String.t(), String.t()) :: {:ok, map()}
    def push_exact(_route, _writer, branch, @candidate) do
      send(self(), {:push_exact, branch, @candidate})
      {:ok, %{branch: branch, sha: @candidate}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "factory-scheduler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    database = Path.join(root, "factory.sqlite")
    {:ok, store} = Store.start_link(database: database)

    factory = %{
      enabled: true,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-1",
      branch_prefix: "cgable",
      queue: %{
        "assignee" => "currentUser()",
        "statuses" => ["READY", "TO DO"],
        "factory_labels" => ["spec-needed", "ai-ready", "ai-running", "ai-testing"],
        "projects" => [],
        "epics" => []
      },
      repositories: %{
        "grail" => %{
          "path" => root,
          "base_branch" => "master",
          "codex_project_id" => "project-grail",
          "gitlab_project" => "grailbio/grail",
          "route_labels" => ["repo-grail"]
        }
      },
      models: %{},
      cleanup: %{},
      hibernation: %{},
      manual_validation: %{
        "enabled" => true,
        "allowed_environments" => ["cpp-test"],
        "require_slack_coordination" => true,
        "required_apps" => ["polaris-app"],
        "startup_timeout_ms" => 45_000,
        "allow_production" => false,
        "allow_database_ddl" => false
      },
      maximum_specifiers: 2,
      maximum_writers: 2,
      maximum_validators: 2,
      writer_disk_gb: 1,
      maximum_implementation_iterations: 8,
      maximum_code_repair_rounds: 2,
      maximum_validation_repair_rounds: 2,
      stale_task_minutes: 90
    }

    context = %{
      factory: factory,
      store: store,
      task_supervisor: self(),
      control_server: self(),
      active_task_keys: MapSet.new(),
      recipient: self(),
      workspace_root: root
    }

    on_exit(fn -> File.rm_rf(root) end)
    %{context: context, store: store, root: root}
  end

  test "registers and launches an assignee-wide specification task", %{context: context, store: store} do
    snapshot = snapshot(["spec-needed", "repo-grail"])

    Process.put(:factory_controller_response, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([snapshot])
    })

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert [%{task_key: task_key, pid: pid}] = result.launches
    assert task_key =~ ":specification-author"
    assert_receive {:controller_prompt, prompt}
    assert prompt =~ "assignee = currentUser()"
    assert_receive {:stage_launch, run_id, _workspace, stage_prompt, stage_opts}
    assert stage_prompt =~ "specify-work"
    assert stage_opts[:role] == "specification-author"
    assert stage_opts[:project_id] == "project-grail"
    assert stage_opts[:thread_name] == "PPL-123 · Specification Author"

    assert {:ok, run} = RunLedger.get(store, run_id)
    assert run["kind"] == "SPECIFICATION"
    assert run["state"] == "SPEC_DRAFTING"
    Process.exit(pid, :kill)
  end

  test "runs two-phase Jira spec write, independent critique, and exact human authorization", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [author]}} = tick(context)

    markdown =
      "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"

    complete_task(store, author.task_key, %{
      "status" => "DRAFTED",
      "contract_markdown" => markdown,
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    })

    Process.exit(author.pid, :kill)
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, _result} = tick(context)

    [run] = RunLedger.list(store)
    assert {:ok, %{"state" => "SPEC_WRITING"} = drafted} = RunLedger.get(store, run["run_id"])
    contract = Contract.bind("PPL-123", 1, markdown)
    assert drafted["contract_sha256"] == contract.sha256

    readback_snapshot = Map.put(snapshot, "comments", [%{"id" => "10", "text" => Contract.draft_comment(contract)}])

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["spec-needed", "repo-grail"], contract.marker),
      %{"status" => "PASS", "issue_key" => "PPL-123", "snapshot_json" => Jason.encode!(readback_snapshot)}
    ])

    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "SPEC_REVIEW"}} = RunLedger.get(store, run["run_id"])

    Process.put(:factory_controller_response, intake_response(readback_snapshot))
    assert {:ok, %{launches: [critic]}} = tick(context)
    assert critic.task_key =~ "specification-critic"

    complete_task(store, critic.task_key, %{
      "status" => "PASS",
      "findings" => [],
      "required_questions" => []
    })

    Process.exit(critic.pid, :kill)
    Process.put(:factory_controller_response, intake_response(readback_snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "SPEC_READY_WRITE"}} = RunLedger.get(store, run["run_id"])

    Process.put(:factory_controller_responses, [
      intake_response(readback_snapshot),
      jira_write_response(["spec-needed", "repo-grail"], Contract.ready_marker(contract))
    ])

    assert {:ok, ready_result} = tick(context)
    assert Enum.any?(ready_result.events, &(&1.event == "HUMAN_CONFIRMATION_REQUIRED"))
    assert {:ok, %{"state" => "AWAITING_CONFIRMATION"}} = RunLedger.get(store, run["run_id"])

    confirmed_snapshot =
      Map.update!(readback_snapshot, "comments", fn comments ->
        comments ++ [%{"id" => "11", "text" => Contract.confirmation_marker(contract)}]
      end)

    Process.put(:factory_controller_responses, [
      intake_response(confirmed_snapshot),
      jira_write_response(["ai-ready", "repo-grail"], Contract.authorization_marker(contract, "11"))
    ])

    assert {:ok, authorized_result} = tick(context)
    assert Enum.any?(authorized_result.events, &(&1.event == "SPECIFICATION_AUTHORIZED"))
    assert {:ok, authorized} = RunLedger.get(store, run["run_id"])
    assert authorized["state"] == "DELIVERED"
    assert authorized["confirmation_comment_id"] == "11"
  end

  test "requires an exact authorization record before launching delivery", %{context: context, store: store} do
    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"
      )

    authorized =
      snapshot(["ai-ready", "repo-grail"])
      |> Map.put("comments", [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
        %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
      ])

    Process.put(:factory_controller_response, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([authorized])
    })

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert [%{task_key: task_key, pid: pid}] = result.launches
    assert task_key =~ ":feature-planner"
    assert_receive {:stage_launch, run_id, _workspace, prompt, opts}
    assert prompt =~ "plan-feature"
    assert opts[:role] == "feature-planner"
    assert opts[:project_id] == "project-grail"
    assert opts[:thread_name] == "PPL-123 · Feature Planner"

    assert {:ok, run} = RunLedger.get(store, run_id)
    assert run["kind"] == "DELIVERY"
    assert run["contract_sha256"] == contract.sha256
    assert run["manual_validation_required"] == 0
    Process.exit(pid, :kill)
  end

  test "asks bound Jira questions and resumes only after matching human input", %{context: context, store: store} do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, %{launches: [launch]}} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    [run] = RunLedger.list(store)
    questions = ["Which compatibility behavior is required?"]

    TaskLedger.update(store, launch.task_key, %{
      status: "COMPLETE",
      output_json:
        Jason.encode!(%{
          "status" => "BLOCKED",
          "contract_markdown" => "",
          "questions" => questions,
          "risk" => "unknown",
          "risk_signals" => [],
          "manual_validation_required" => false
        })
    })

    digest = Contract.questions_digest(questions)

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "issue_key" => "PPL-123",
        "operation" => "comment",
        "comment_id" => "20",
        "labels" => ["spec-needed", "needs-decision", "repo-grail"],
        "readback_text" => digest
      }
    ])

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Enum.any?(result.events, &(&1.event == "SPECIFICATION_INPUT_REQUIRED"))
    assert {:ok, waiting} = RunLedger.get(store, run["run_id"])
    assert waiting["state"] == "AWAITING_SPEC_INPUT"

    marker = Contract.input_marker("PPL-123", digest)
    answered = Map.put(snapshot, "comments", [%{"id" => "21", "text" => marker <> "\nKeep old clients compatible."}])
    Process.put(:factory_controller_response, intake_response(answered))

    assert {:ok, resumed} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Enum.any?(resumed.events, &(&1.event == "SPECIFICATION_INPUT_RECEIVED"))
    assert {:ok, resumed_run} = RunLedger.get(store, run["run_id"])
    assert resumed_run["state"] == "SPEC_DRAFTING"
    Process.exit(launch.pid, :kill)
  end

  test "re-reads active issues outside the intake query and cancels safely when status leaves scope", %{
    context: context,
    store: store
  } do
    ready = snapshot(["spec-needed", "repo-grail"])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "run-active",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "AWAITING_SPEC_INPUT",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ready),
               last_input_marker: String.duplicate("a", 64)
             })

    done = Map.put(ready, "status", "DONE")

    Process.put(:factory_controller_responses, [
      %{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => "[]"},
      %{"status" => "PASS", "issue_key" => "ACTIVE_RUNS", "snapshot_json" => Jason.encode!([done])}
    ])

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Enum.any?(result.events, &(&1.event == "RUN_CANCELLED"))
    assert {:ok, cancelled} = RunLedger.get(store, run["run_id"])
    assert cancelled["state"] == "CANCELLED"
    assert cancelled["last_error"] =~ "jira_status_left_factory_scope"
  end

  test "runs planning, one writer pass, mandatory detached verification, exact push, and draft MR", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)

    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"
      )

    snapshot = authorized_snapshot(contract, ["ai-ready", "repo-grail"])
    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, %{launches: [planner]}} = tick(context)
    complete_task(store, planner.task_key, %{"status" => "PLANNED", "plan_markdown" => "Implement AC-1", "blockers" => []})
    Process.exit(planner.pid, :kill)

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, _result} = tick(context)
    [run] = RunLedger.list(store)
    assert {:ok, %{"state" => "ADMITTING_WRITER"}} = RunLedger.get(store, run["run_id"])

    running_snapshot = %{snapshot | "labels" => ["ai-running", "repo-grail"]}

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["ai-running", "repo-grail"], "ai-running")
    ])

    assert {:ok, _result} = tick(context)

    assert {:ok, %{"state" => "WRITING", "branch" => "cgable/PPL-123-factory-work"}} =
             RunLedger.get(store, run["run_id"])

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, %{launches: [writer]}} = tick(context)

    complete_task(store, writer.task_key, %{
      "status" => "COMPLETE",
      "summary" => "implemented",
      "commit_sha" => candidate,
      "remaining_criteria" => [],
      "blockers" => [],
      "checks" => ["unit tests passed"]
    })

    Process.exit(writer.pid, :kill)

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "VERIFYING"}} = RunLedger.get(store, run["run_id"])
    refute_received {:push_exact, _branch, _sha}

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, %{launches: [verifier]}} = tick(context)
    assert verifier.task_key =~ "change-verifier"

    complete_task(store, verifier.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "findings" => [],
      "checks" => ["all acceptance criteria passed"]
    })

    Process.exit(verifier.pid, :kill)

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "PUSHING"}} = RunLedger.get(store, run["run_id"])
    refute_received {:push_exact, _branch, _sha}

    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/7"

    Process.put(:factory_controller_responses, [
      intake_response(running_snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 7,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "sha" => candidate,
        "draft" => true,
        "reviewers_count" => 0,
        "state" => "opened"
      },
      jira_write_response(["ai-review", "repo-grail"], mr_url)
    ])

    assert {:ok, final} = tick(context)
    run_id = run["run_id"]
    assert_received {:push_exact, "cgable/PPL-123-factory-work", ^candidate}
    assert_received {:hibernate, ^run_id}
    assert Enum.any?(final.events, &(&1.event == "READY_FOR_REVIEW"))
    assert Enum.any?(final.events, &(&1.event == "HIBERNATION_SKIPPED"))

    assert {:ok, delivered} = RunLedger.get(store, run["run_id"])
    assert delivered["state"] == "READY_FOR_REVIEW"
    assert delivered["candidate_sha"] == candidate
    assert delivered["mr_url"] == mr_url
  end

  test "runs Slack-coordinated exact-SHA manual validation before human review", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)
    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/8"

    contract =
      Contract.bind(
        "PPL-123",
        1,
        """
        # Contract

        ## Acceptance Criteria
        - AC-1: works

        ## Manual Validation
        - Required: yes
        - Environment: cpp-test
        - Service: doc-extract
        - Cases: MV-1
        - Synthetic data: required
        - Evidence: command output
        - Teardown: remove synthetic resources; no DDL
        """
      )

    snapshot = authorized_snapshot(contract, ["ai-testing", "repo-grail"])
    writer_path = Path.join(context.workspace_root, "parent-writer")
    File.mkdir_p!(writer_path)

    assert {:ok, %{run: parent}} =
             RunLedger.register(store, %{
               run_id: "parent-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "AWAITING_VALIDATION",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: true,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: writer_path,
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               mr_url: mr_url,
               mr_iid: 8,
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [validator]}} = tick(context)
    assert validator.task_key =~ "manual-validator"
    assert_receive {:stage_launch, validation_run_id, _workspace, _prompt, stage_opts}
    assert is_binary(validation_run_id)
    assert stage_opts[:required_apps] == ["polaris-app"]
    assert stage_opts[:required_mcp_servers] == []
    assert stage_opts[:mcp_startup_timeout_ms] == 45_000

    complete_task(store, validator.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "evidence_markdown" => "MV-1 passed with attached command output.",
      "findings" => [],
      "human_action" => nil,
      "environment" => "cpp-test",
      "slack_claim_ts" => "1710000000.000001",
      "slack_release_confirmed" => true,
      "teardown_confirmed" => true,
      "synthetic_data_only" => true
    })

    Process.exit(validator.pid, :kill)

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 8,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "sha" => candidate,
        "draft" => true,
        "reviewers_count" => 0,
        "state" => "opened"
      },
      jira_write_response(["ai-review", "repo-grail"], candidate)
    ])

    assert {:ok, result} = tick(context)
    assert Enum.any?(result.events, &(&1.event == "VALIDATION_PASSED"))

    [validation] = Enum.filter(RunLedger.list(store), &(&1["kind"] == "VALIDATION"))
    assert validation["state"] == "READY_FOR_REVIEW"
    assert validation["validation_attempt"] == 1
    assert {:ok, %{"state" => "READY_FOR_REVIEW"}} = RunLedger.get(store, parent["run_id"])
  end

  test "rehydrates the retained branch and exact candidate before a repair writer resumes", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)

    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"
      )

    snapshot = authorized_snapshot(contract, ["ai-running", "repo-grail"])
    missing_worktree = Path.join(context.workspace_root, "removed-writer")

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "repair-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "REPAIRING",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: false,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: missing_worktree,
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               plan_markdown: "Repair AC-1",
               snapshot_json: Jason.encode!(snapshot),
               workspace_state: "HIBERNATED"
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [writer]} = result} = tick(context)

    assert_receive {:ensure_writer, route, "PPL-123", "repair-delivery"}
    assert route["branch"] == "cgable/PPL-123-factory-work"
    assert route["expected_sha"] == candidate
    assert Enum.any?(result.events, &(&1.event == "WORKTREE_REHYDRATED"))

    assert {:ok, materialized} = RunLedger.get(store, run["run_id"])
    assert materialized["workspace_state"] == "MATERIALIZED"
    assert File.dir?(materialized["worktree"])
    Process.exit(writer.pid, :kill)
  end

  defp intake_response(snapshot) do
    %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([snapshot])
    }
  end

  defp authorized_snapshot(contract, labels) do
    snapshot(labels)
    |> Map.put("comments", [
      %{"id" => "1", "text" => Contract.draft_comment(contract)},
      %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
      %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
    ])
  end

  defp jira_write_response(labels, readback) do
    %{
      "status" => "PASS",
      "issue_key" => "PPL-123",
      "operation" => "test",
      "comment_id" => nil,
      "labels" => labels,
      "readback_text" => readback
    }
  end

  defp complete_task(store, task_key, output) do
    assert {:ok, _task} =
             TaskLedger.update(store, task_key, %{
               status: "COMPLETE",
               output_json: Jason.encode!(output)
             })
  end

  defp tick(context) do
    Scheduler.tick(context,
      controller_task: FakeControllerTask,
      task_launcher: FakeTaskLauncher,
      cleanup: FakeCleanup,
      worktree: FakeWorktree
    )
  end

  defp snapshot(labels) do
    %{
      "id" => "100",
      "key" => "PPL-123",
      "summary" => "Factory work",
      "description" => "Do the work",
      "status" => "READY",
      "labels" => labels,
      "assignee" => "cgable",
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => ["doc-extract"],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-09-21T00:00:00Z",
      "comments" => []
    }
  end
end
