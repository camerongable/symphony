defmodule SymphonyElixir.FactoryLifecycleIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Contract, Control, RunLedger, Scheduler, StageSchemas, Store, TaskLauncher, TaskLedger}

  @candidate String.duplicate("a", 40)

  defmodule Controller do
    @spec run(map(), Path.t(), map(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_factory, _workspace, _issue, _prompt, _schema, _opts) do
      {:ok, Process.get(:factory_lifecycle_intake)}
    end
  end

  defmodule Worktree do
    @candidate String.duplicate("a", 40)

    @spec base_sha(map()) :: {:ok, String.t()}
    def base_sha(_route), do: {:ok, @candidate}

    @spec create_detached(map(), String.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()}
    def create_detached(route, _issue_key, run_id, _stage, _sha) do
      path = Path.join(route["workspace_root"], "#{run_id}-specification")
      File.mkdir_p!(path)
      {:ok, path}
    end

    @spec validate_detached(map(), Path.t()) :: {:ok, map()}
    def validate_detached(_route, path), do: {:ok, %{path: path, sha: @candidate}}

    @spec remove_detached(map(), Path.t()) :: :ok
    def remove_detached(_route, _path), do: :ok

    @spec candidate(Path.t(), String.t()) :: {:ok, String.t()}
    def candidate(_path, _base), do: {:ok, @candidate}

    @spec reachable?(map(), String.t()) :: boolean()
    def reachable?(_route, @candidate), do: true
  end

  defmodule Cleanup do
    @spec ensure_capacity(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def ensure_capacity(_store, _policy, repo_key, _opts \\ []) do
      {:ok, %{repo_key: repo_key, available_writer_slots: 1, cleaned: []}}
    end
  end

  defmodule Launcher do
    @spec launch(term(), term(), map(), map(), Path.t(), String.t(), map(), keyword()) :: term()
    def launch(store, supervisor, run, issue, workspace, prompt, schema, opts) do
      TaskLauncher.launch(store, supervisor, run, issue, workspace, prompt, schema, opts)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "factory-lifecycle-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "grail")
    workspace = Path.join(root, "writer")
    binary = Path.join(root, "fake-codex")
    trace = Path.join(root, "requests.jsonl")
    database = Path.join(root, "factory.sqlite")
    File.mkdir_p!(repo)
    File.mkdir_p!(workspace)
    File.write!(binary, fake_codex_script(trace, repo))
    File.chmod!(binary, 0o755)

    previous_trace = System.get_env("SYMP_TEST_LIFECYCLE_TRACE")
    previous_mode = System.get_env("SYMP_TEST_LIFECYCLE_MODE")
    System.put_env("SYMP_TEST_LIFECYCLE_TRACE", trace)
    System.put_env("SYMP_TEST_LIFECYCLE_MODE", "normal")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, codex_command: "#{binary} app-server")

    {:ok, store} = Store.start_link(database: database)
    {:ok, supervisor} = Task.Supervisor.start_link()

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
          "path" => repo,
          "base_branch" => "master",
          "codex_project_id" => "project-grail",
          "gitlab_project" => "grailbio/grail",
          "route_labels" => ["repo-grail"]
        }
      },
      models: %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"deep" => "gpt-test"}},
        "roles" => %{
          "feature-writer" => %{
            "provider" => "codex",
            "model_class" => "deep",
            "reasoning_effort" => "high"
          },
          "specification-author" => %{
            "provider" => "codex",
            "model_class" => "deep",
            "reasoning_effort" => "high"
          }
        }
      },
      cleanup: %{},
      hibernation: %{},
      manual_validation: %{},
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
      task_supervisor: supervisor,
      control_server: self(),
      active_task_keys: MapSet.new(),
      recipient: self(),
      workspace_root: root
    }

    on_exit(fn ->
      restore_env("SYMP_TEST_LIFECYCLE_TRACE", previous_trace)
      restore_env("SYMP_TEST_LIFECYCLE_MODE", previous_mode)
      File.rm_rf(root)
    end)

    %{
      context: context,
      store: store,
      supervisor: supervisor,
      workspace: workspace,
      repo: repo,
      database: database,
      trace: trace
    }
  end

  test "delivery writer continues then completes in one Grail task without a fork", state do
    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"
      )

    snapshot = %{
      "id" => "100",
      "key" => "PPL-123",
      "summary" => "Factory work",
      "description" => "Do the work",
      "status" => "READY",
      "labels" => ["ai-running", "repo-grail"],
      "assignee" => "cgable",
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => ["doc-extract"],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-09-21T00:00:00Z",
      "comments" => [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
        %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
      ]
    }

    Process.put(:factory_lifecycle_intake, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([snapshot])
    })

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "delivery-lifecycle",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "WRITING",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: false,
               repo_key: "grail",
               repo_path: state.context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: state.workspace,
               branch: "cgable/PPL-123-factory-work",
               plan_markdown: "Implement AC-1",
               snapshot_json: Jason.encode!(snapshot),
               workspace_state: "MATERIALIZED"
             })

    assert {:ok, %{launches: [first]}} = tick(state.context)
    task_key = first.task_key
    assert_receive {:factory_task_started, ^task_key, "thread-writer"}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:ok, %{output: %{"status" => "CONTINUE"}}}}, 5_000
    Process.demonitor(first.ref, [:flush])

    assert {:ok, %{launches: []}} = tick(state.context)

    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 1}} =
             RunLedger.get(state.store, run["run_id"])

    assert {:ok, %{launches: [second]}} = tick(state.context)
    assert second.task_key == task_key
    assert_receive {:factory_task_started, ^task_key, "thread-writer"}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:ok, %{output: %{"status" => "COMPLETE"}}}}, 5_000
    Process.demonitor(second.ref, [:flush])

    assert {:ok, %{launches: []}} = tick(state.context)
    assert {:ok, %{"state" => "VERIFYING"}} = RunLedger.get(state.store, run["run_id"])

    assert [%{"task_key" => ^task_key, "thread_id" => "thread-writer", "codex_project_id" => "project-grail"}] =
             TaskLedger.list_for_run(state.store, run["run_id"])

    payloads = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    starts = Enum.filter(payloads, &(&1["method"] == "thread/start"))
    resumes = Enum.filter(payloads, &(&1["method"] == "thread/resume"))
    assert length(starts) == 1
    assert length(resumes) == 1
    assert get_in(hd(resumes), ["params", "threadId"]) == "thread-writer"
    refute Enum.any?(payloads, &(&1["method"] == "thread/fork"))

    bindings = Enum.filter(payloads, &(&1["method"] == "thread/metadata/update"))
    assert length(bindings) == 2
    assert Enum.all?(bindings, &(get_in(&1, ["params", "projectId"]) == "project-grail"))
  end

  test "a failed specification retry resumes its original author task", state do
    snapshot = %{
      "id" => "100",
      "key" => "PPL-123",
      "summary" => "Factory work",
      "description" => "Do the work",
      "status" => "READY",
      "labels" => ["spec-needed", "repo-grail"],
      "assignee" => "cgable",
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => ["doc-extract"],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-09-21T00:00:00Z",
      "comments" => []
    }

    Process.put(:factory_lifecycle_intake, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([snapshot])
    })

    Control.initialize(state.store, %{
      scope: state.context.factory.scope,
      dispatcher_id: state.context.factory.dispatcher_id
    })

    assert {:ok, _} =
             RunLedger.register(state.store, %{
               run_id: "failed-specification",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: state.context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: state.workspace,
               snapshot_json: Jason.encode!(snapshot)
             })

    old_task_key = "failed-specification:specification-author"

    assert {:ok, _} =
             TaskLedger.register(state.store, %{
               task_key: old_task_key,
               run_id: "failed-specification",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "FAILED",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-test",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _} = TaskLedger.update(state.store, old_task_key, %{thread_id: "thread-writer"})

    assert {:ok, %{run_id: "failed-specification"}} =
             RunLedger.request_specification_retry(
               state.store,
               "PPL-123",
               state.context.factory.scope
             )

    assert {:ok, %{launches: [author]}} = tick(state.context)
    assert_receive {:factory_task_started, _, _}, 5_000

    assert_receive {:factory_task_finished, _, {:ok, %{output: %{"status" => "DRAFTED", "contract_markdown" => markdown}}}},
                   5_000

    assert markdown =~ "## Manual Validation"
    Process.demonitor(author.ref, [:flush])

    assert {:ok, %{launches: []}} = tick(state.context)

    assert [%{"run_id" => "failed-specification", "state" => "SPEC_WRITING"}] = RunLedger.list(state.store)
    assert author.task_key == old_task_key

    payloads = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    refute Enum.any?(payloads, &(&1["method"] == "thread/start"))

    assert [resume] = Enum.filter(payloads, &(&1["method"] == "thread/resume"))
    assert get_in(resume, ["params", "threadId"]) == "thread-writer"
    refute Enum.any?(payloads, &(&1["method"] == "thread/fork"))
    assert [binding] = Enum.filter(payloads, &(&1["method"] == "thread/metadata/update"))
    assert get_in(binding, ["params", "projectId"]) == "project-grail"

    assert {:ok, %{"thread_id" => "thread-writer", "codex_project_id" => "project-grail"}} =
             TaskLedger.get(state.store, author.task_key)

    assert {:ok, %{"thread_id" => "thread-writer"}} = TaskLedger.get(state.store, old_task_key)
  end

  test "an active writer conflict retains the specification author identity without starting or forking", state do
    snapshot = specification_snapshot()

    Process.put(:factory_lifecycle_intake, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([snapshot])
    })

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "locked-specification",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               dispatcher_id: "dispatcher-1",
               repo_key: "grail",
               repo_path: state.repo,
               base_branch: "master",
               worktree: state.workspace,
               snapshot_json: Jason.encode!(snapshot),
               workspace_state: "MATERIALIZED"
             })

    task_key = "locked-specification:specification-author"
    seed_task(state.store, run, task_key, "specification-author", "thread-writer")
    assert {:ok, _task} = TaskLedger.update(state.store, task_key, %{status: "STALE"})

    System.put_env("SYMP_TEST_LIFECYCLE_MODE", "active-writer")

    assert {:ok, %{launches: [first]}} = tick(state.context)
    assert_receive {:factory_task_finished, ^task_key, {:error, {:response_error, %{"message" => message}}}}, 5_000
    assert message =~ "active writer"
    Process.demonitor(first.ref, [:flush])

    assert {:ok, %{launches: []}} = tick(state.context)
    assert {:ok, %{"state" => "SPEC_DRAFTING"}} = RunLedger.get(state.store, run["run_id"])

    assert {:ok, %{"thread_id" => "thread-writer", "status" => "WAITING_FOR_WRITER"}} =
             TaskLedger.get(state.store, task_key)

    Store.query!(
      state.store,
      "UPDATE factory_tasks SET updated_at = ? WHERE task_key = ?",
      ["2020-01-01T00:00:00Z", task_key]
    )

    System.put_env("SYMP_TEST_LIFECYCLE_MODE", "normal")
    assert {:ok, %{launches: [second]}} = tick(state.context)
    assert_receive {:factory_task_started, ^task_key, "thread-writer"}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:ok, %{thread_id: "thread-writer"}}}, 5_000
    Process.demonitor(second.ref, [:flush])

    payloads = trace_payloads(state.trace)
    assert Enum.count(payloads, &(&1["method"] == "thread/resume")) == 2

    assert Enum.all?(
             Enum.filter(payloads, &(&1["method"] == "thread/resume")),
             &(get_in(&1, ["params", "threadId"]) == "thread-writer")
           )

    refute Enum.any?(payloads, &(&1["method"] in ["thread/start", "thread/fork"]))
    assert [binding] = Enum.filter(payloads, &(&1["method"] == "thread/metadata/update"))
    assert get_in(binding, ["params", "projectId"]) == "project-grail"
  end

  test "a wrong Grail project ID fails before a Codex thread is created", state do
    run = register_stage_run(state, "wrong-project", "SPECIFICATION", "SPEC_DRAFTING")
    task_key = "wrong-project:specification-author"

    assert {:ok, launch} =
             launch_stage(state, run, task_key, "specification-author", project_id: "other-project")

    assert_receive {:factory_task_finished, ^task_key, {:error, {:project_id_mismatch, "other-project", "project-grail"}}},
                   5_000

    Process.demonitor(launch.ref, [:flush])
    assert {:ok, %{"status" => "FAILED", "thread_id" => nil}} = TaskLedger.get(state.store, task_key)

    payloads = trace_payloads(state.trace)
    assert Enum.any?(payloads, &(&1["method"] == "project/list"))
    refute Enum.any?(payloads, &(&1["method"] in ["thread/start", "thread/resume", "thread/fork"]))
  end

  test "a restarted launcher resumes the persisted writer task ID", state do
    run = register_stage_run(state, "restart-writer", "DELIVERY", "WRITING")
    task_key = "restart-writer:feature-writer"

    assert {:ok, first} = launch_stage(state, run, task_key, "feature-writer")
    assert_receive {:factory_task_started, ^task_key, "thread-writer"}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:ok, %{thread_id: "thread-writer"}}}, 5_000
    Process.demonitor(first.ref, [:flush])

    {:ok, reopened_store} = Store.start_link(database: state.database)
    {:ok, restarted_supervisor} = Task.Supervisor.start_link()
    restarted = %{state | store: reopened_store, supervisor: restarted_supervisor}

    assert {:ok, %{"status" => "COMPLETE", "thread_id" => "thread-writer"}} =
             TaskLedger.get(reopened_store, task_key)

    assert {:ok, second} = launch_stage(restarted, run, task_key, "feature-writer")
    assert_receive {:factory_task_started, ^task_key, "thread-writer"}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:ok, %{thread_id: "thread-writer"}}}, 5_000
    Process.demonitor(second.ref, [:flush])

    assert {:ok, %{"thread_id" => "thread-writer", "codex_project_id" => "project-grail"}} =
             TaskLedger.get(reopened_store, task_key)

    payloads = trace_payloads(state.trace)
    assert Enum.count(payloads, &(&1["method"] == "thread/start")) == 1
    assert [resume] = Enum.filter(payloads, &(&1["method"] == "thread/resume"))
    assert get_in(resume, ["params", "threadId"]) == "thread-writer"
    refute Enum.any?(payloads, &(&1["method"] == "thread/fork"))
  end

  defp tick(context) do
    Scheduler.tick(context,
      controller_task: Controller,
      task_launcher: Launcher,
      cleanup: Cleanup,
      worktree: Worktree
    )
  end

  defp register_stage_run(state, run_id, kind, stage) do
    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: run_id,
               issue_key: "PPL-123",
               kind: kind,
               state: stage,
               dispatcher_id: "dispatcher-1",
               repo_key: "grail",
               repo_path: state.repo,
               base_branch: "master",
               worktree: state.workspace,
               snapshot_json: Jason.encode!(%{"key" => "PPL-123", "status" => "READY"})
             })

    run
  end

  defp specification_snapshot do
    %{
      "id" => "100",
      "key" => "PPL-123",
      "summary" => "Factory work",
      "description" => "Do the work",
      "status" => "READY",
      "labels" => ["spec-needed", "repo-grail"],
      "assignee" => "cgable",
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => ["doc-extract"],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-09-21T00:00:00Z",
      "comments" => []
    }
  end

  defp seed_task(store, run, task_key, role, thread_id) do
    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: task_key,
               run_id: run["run_id"],
               stage: run["state"],
               role: role,
               status: "FAILED",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-test",
               reasoning_effort: "high",
               routing_reason: "explicit-role",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _task} = TaskLedger.update(store, task_key, %{thread_id: thread_id})
  end

  defp launch_stage(state, run, task_key, role, overrides \\ []) do
    issue = %Issue{id: "100", identifier: "PPL-123", title: "Factory work"}
    schema = StageSchemas.for_stage(if role == "feature-writer", do: :feature_writer, else: :specification_author)

    opts = [
      task_key: task_key,
      stage: run["state"],
      role: role,
      model_policy: state.context.factory.models,
      recipient: self(),
      project_id: "project-grail",
      project_root: state.repo,
      thread_name: "PPL-123 · #{role}",
      resume_terminal: true
    ]

    TaskLauncher.launch(
      state.store,
      state.supervisor,
      run,
      issue,
      state.workspace,
      "one bounded pass",
      schema,
      Keyword.merge(opts, overrides)
    )
  end

  defp trace_payloads(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp fake_codex_script(trace, repo) do
    specification_output =
      Jason.encode!(%{
        "status" => "DRAFTED",
        "contract_markdown" => "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests",
        "questions" => [],
        "risk" => "low",
        "risk_signals" => [],
        "manual_validation_required" => false
      })

    continue_output =
      Jason.encode!(%{
        "status" => "CONTINUE",
        "summary" => "first pass",
        "commit_sha" => @candidate,
        "remaining_criteria" => ["AC-1"],
        "blockers" => [],
        "checks" => []
      })

    complete_output =
      Jason.encode!(%{
        "status" => "COMPLETE",
        "summary" => "implemented",
        "commit_sha" => @candidate,
        "remaining_criteria" => [],
        "blockers" => [],
        "checks" => ["unit tests passed"]
      })

    continue_event = Jason.encode!(%{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => continue_output}}})
    complete_event = Jason.encode!(%{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => complete_output}}})
    specification_event = Jason.encode!(%{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => specification_output}}})

    """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"project/list"'*) printf '%s\\n' '{"id":12,"result":{"data":[{"id":"project-grail","roots":[{"path":"#{repo}"}]}],"nextCursor":null}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-writer"}}}' ;;
        *'"method":"thread/resume"'*)
          if [ "${SYMP_TEST_LIFECYCLE_MODE:-normal}" = "active-writer" ]; then
            printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"thread thread-writer already has an active writer"}}'
          else
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-writer"}}}'
          fi
          ;;
        *'"method":"thread/name/set"'*) printf '%s\\n' '{"id":4,"result":{}}' ;;
        *'"method":"thread/metadata/update"'*) printf '%s\\n' '{"id":7,"result":{"thread":{"id":"thread-writer","projectId":"project-grail"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-writer"}}}'
          turns=$(grep -c '"method":"turn/start"' "#{trace}")
          case "$line" in
            *'"contract_markdown"'*) printf '%s\\n' '#{specification_event}' ;;
            *)
              if [ "$turns" -eq 1 ]; then
                printf '%s\\n' '#{continue_event}'
              else
                printf '%s\\n' '#{complete_event}'
              fi
              ;;
          esac
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
    done
    """
  end
end
