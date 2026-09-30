defmodule SymphonyElixir.FactoryDesktopStageRunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, DesktopRequest, DesktopStageRunner, RunLedger, Store, TaskLedger, Worktree}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Tracker.Issue

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["status"],
    "properties" => %{"status" => %{"type" => "string", "enum" => ["DRAFTED"]}}
  }

  setup do
    token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    database = Path.join(System.tmp_dir!(), "factory-desktop-runner-#{token}.sqlite")

    {:ok, store} = Store.start_link(database: database)
    Control.initialize(store, %{scope: "assigned-jira-work", dispatcher_id: "dispatcher-1"})

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

    %{store: store}
  end

  test "one native task creation is persisted and its result is validated", %{store: store} do
    parent = self()
    runner = Task.async(fn -> DesktopStageRunner.run("/tmp/grail", issue(), "Specify", @schema, opts(store, parent)) end)
    request_key = opts(store, parent)[:request_key]

    assert {:ok, %{"status" => "PENDING", "action" => "CREATE", "prompt" => queued_prompt}} =
             wait_request(store, request_key)

    assert String.starts_with?(queued_prompt, "Factory request ID: #{request_key}\n\nSpecify")
    assert {:ok, %{"status" => "CREATE_UNCERTAIN"}} = DesktopRequest.claim(store, request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request_key, "thread-1", "project-grail")

    assert {:ok, _complete} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: %{
                 "result" => %{"status" => "DRAFTED"},
                 "completed_tool_calls" => []
               }
             })

    assert {:ok, %{thread_id: "thread-1", turn_id: "turn-1", output: %{"status" => "DRAFTED"}}} =
             Task.await(runner)

    assert_receive {:thread_started, "thread-1"}
    refute_receive {:thread_started, "thread-1"}

    followup_opts =
      opts(store, parent)
      |> Keyword.put(:request_key, DesktopStageRunner.request_key("run-1:author", "turn-1", "Refine"))
      |> Keyword.put(:previous_turn_id, "turn-1")
      |> Keyword.put(:resume_thread_id, "thread-1")

    followup =
      Task.async(fn -> DesktopStageRunner.run("/tmp/grail", issue(), "Refine", @schema, followup_opts) end)

    followup_key = followup_opts[:request_key]

    assert {:ok, %{"action" => "FOLLOWUP", "existing_thread_id" => "thread-1"}} =
             wait_request(store, followup_key)

    assert {:ok, %{"status" => "FOLLOWUP_UNCERTAIN"}} = DesktopRequest.claim(store, followup_key)
    assert {:ok, _same_thread} = DesktopRequest.record_thread(store, followup_key, "thread-1", "project-grail")

    assert {:ok, _complete} =
             DesktopRequest.complete(store, followup_key, %{
               thread_id: "thread-1",
               turn_id: "turn-2",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "thread-1", turn_id: "turn-2"}} = Task.await(followup)
  end

  test "project-local contract chat creates no worktree bootstrap and resumes the same thread", %{store: store} do
    repo = "/tmp/grail"
    Store.query!(store, "UPDATE runs SET repo_path = ?, base_branch = ? WHERE run_id = ?", [repo, "master", "run-1"])
    assert {:ok, _run} = RunLedger.update(store, "run-1", %{state: "CONTRACT_DISCUSSING", parent_run_id: "failed-run"})

    assert {:ok, _task} =
             TaskLedger.update(store, "run-1:author", %{
               stage: "CONTRACT_DISCUSSING",
               prompt_sha256: digest("Specify")
             })

    opts =
      opts(store, self())
      |> Keyword.put(:workspace_mode, "CODEX_PROJECT_LOCAL")
      |> Keyword.put(:base_branch, "master")

    create = Task.async(fn -> DesktopStageRunner.run(repo, issue(), "Specify", @schema, opts) end)
    key = opts[:request_key]

    assert {:ok, %{"action" => "CREATE"}} = wait_request(store, key)
    assert {:error, :unknown_request} = DesktopRequest.get(store, key <> ":bootstrap")
    assert {:ok, _claimed} = DesktopRequest.claim(store, key)
    assert {:ok, _bound} = DesktopRequest.record_thread(store, key, "local-thread", "project-grail", %{cwd: repo})

    assert {:ok, _complete} =
             DesktopRequest.complete(store, key, %{
               thread_id: "local-thread",
               turn_id: "first-turn",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "local-thread", turn_id: "first-turn"}} = Task.await(create)

    assert {:ok, %{"status" => "COMPLETE", "workspace" => nil, "turn_id" => "first-turn"}} =
             TaskLedger.get(store, "run-1:author")

    assert {:ok, _task} =
             TaskLedger.update(store, "run-1:author", %{
               status: "RETRY_PENDING",
               prompt_sha256: digest("Refine")
             })

    followup = Task.async(fn -> DesktopStageRunner.run(repo, issue(), "Refine", @schema, opts) end)
    followup_key = DesktopStageRunner.request_key("run-1:author", "first-turn", "Refine")

    assert {:ok, %{"action" => "FOLLOWUP", "existing_thread_id" => "local-thread"}} =
             wait_request(store, followup_key)

    assert {:ok, _claimed} = DesktopRequest.claim(store, followup_key)

    assert {:ok, _bound} =
             DesktopRequest.record_thread(store, followup_key, "local-thread", "project-grail", %{cwd: repo})

    assert {:ok, _complete} =
             DesktopRequest.complete(store, followup_key, %{
               thread_id: "local-thread",
               turn_id: "second-turn",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "local-thread", turn_id: "second-turn"}} = Task.await(followup)
    assert {:ok, %{"workspace" => nil, "turn_id" => "second-turn"}} = TaskLedger.get(store, "run-1:author")
  end

  test "an uncertain creation is resumed through the same request, never enqueued twice", %{store: store} do
    opts = Keyword.put(opts(store, self()), :wait_timeout_ms, 3_000)
    request_key = opts[:request_key]

    first = Task.async(fn -> DesktopStageRunner.run("/tmp/grail", issue(), "Specify", @schema, opts) end)
    assert {:ok, _pending} = wait_request(store, request_key)
    assert {:ok, %{"status" => "CREATE_UNCERTAIN"}} = DesktopRequest.claim(store, request_key)
    assert {:error, {:desktop_request_pending, "CREATE_UNCERTAIN", ^request_key}} = Task.await(first)
    assert DesktopRequest.list_pending(store) == []

    resumed =
      Task.async(fn ->
        DesktopStageRunner.run("/tmp/grail", issue(), "Specify", @schema, Keyword.put(opts, :wait_timeout_ms, 1_000))
      end)

    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request_key, "thread-1", "project-grail")

    assert {:ok, _complete} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "thread-1"}} = Task.await(resumed)

    assert [%{"request_key" => ^request_key}] =
             Store.query!(store, "SELECT request_key FROM desktop_requests").rows
             |> Enum.map(fn [key] -> %{"request_key" => key} end)
  end

  test "native broker output still needs schema and tool evidence", %{store: store} do
    opts = Keyword.put(opts(store, self()), :required_tool_calls, [%{server: "Jira", tool: "jira_search"}])
    runner = Task.async(fn -> DesktopStageRunner.run("/tmp/grail", issue(), "Specify", @schema, opts) end)
    request_key = opts[:request_key]
    assert {:ok, _pending} = wait_request(store, request_key)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request_key)
    assert {:ok, _recorded} = DesktopRequest.record_thread(store, request_key, "thread-1", "project-grail")

    assert {:error, :factory_stage_output_schema_mismatch} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: %{"result" => %{"status" => "UNKNOWN"}, "completed_tool_calls" => []}
             })

    assert {:error, {:required_tool_calls_missing, [%{"server" => "Jira", "tool" => "jira_search"}]}} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:error, {:required_tool_calls_missing, [%{"server" => "Jira", "tool" => "jira_search"}]}} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: %{
                 "result" => %{"status" => "DRAFTED"},
                 "completed_tool_calls" => [%{"server" => "Jira", "tool" => "jira_search", "status" => "failed"}]
               }
             })

    assert {:ok, %{"status" => "THREAD_RECORDED"}} = DesktopRequest.get(store, request_key)

    assert {:ok, _complete} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               output: %{
                 "result" => %{"status" => "DRAFTED"},
                 "completed_tool_calls" => [%{"server" => "Jira", "tool" => "jira_search", "status" => "completed"}]
               }
             })

    assert {:ok, %{output: %{"status" => "DRAFTED"}}} = Task.await(runner)
  end

  test "an interrupted native bootstrap resumes the same project task before ticket work", %{store: store} do
    %{repo: repo, checkout: checkout, sha: sha, canonical_checkout: canonical_checkout} = native_repo_fixture()

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "native-run",
               issue_key: "PPL-456",
               kind: "SPECIFICATION",
               state: "DRAFTING",
               repo_path: repo,
               base_branch: "master"
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "native-run:author",
               run_id: "native-run",
               stage: "DRAFTING",
               role: "specification-author",
               status: "STARTING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: digest("Specify")
             })

    request_key = DesktopStageRunner.request_key("native-run:author", nil, "Specify")
    bootstrap_key = request_key <> ":bootstrap"

    opts =
      opts(store, self())
      |> Keyword.put(:target_key, "native-run:author")
      |> Keyword.put(:request_key, request_key)
      |> Keyword.put(:issue_key, "PPL-456")
      |> Keyword.put(:workspace_mode, "CODEX_NATIVE")
      |> Keyword.put(:expected_sha, sha)
      |> Keyword.put(:wait_timeout_ms, 100)

    runner =
      Task.async(fn ->
        DesktopStageRunner.run(repo, %Issue{id: "456", identifier: "PPL-456", title: "Spec"}, "Specify", @schema, opts)
      end)

    assert {:ok, %{"action" => "CREATE", "prompt" => bootstrap_prompt, "title" => bootstrap_title} = bootstrap_request} =
             wait_request(store, bootstrap_key)

    assert bootstrap_title == "PPL-123 · Specification Author"
    assert Jason.decode!(bootstrap_request["metadata_json"])["display_title"] == "PPL-123 · Specification Author"
    assert String.contains?(bootstrap_prompt, "Factory request ID: #{bootstrap_key}")
    assert String.contains?(bootstrap_prompt, "read-only checkout verification")
    assert String.contains?(bootstrap_prompt, "git rev-parse HEAD")
    assert String.contains?(bootstrap_prompt, "Do not run `git status`")
    refute String.contains?(bootstrap_prompt, "\n\nSpecify")
    assert {:ok, _claimed} = DesktopRequest.claim(store, bootstrap_key)

    assert {:error, {:desktop_request_pending, "CREATE_UNCERTAIN", ^bootstrap_key}} = Task.await(runner)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, bootstrap_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, _completed} =
             DesktopRequest.complete(store, bootstrap_key, %{
               thread_id: "native-thread",
               turn_id: "bootstrap-turn",
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    updated_prompt = "Specify with the latest Jira snapshot"
    updated_key = DesktopStageRunner.request_key("native-run:author", nil, updated_prompt)

    assert {:ok, _task} =
             TaskLedger.update(store, "native-run:author", %{prompt_sha256: digest(updated_prompt)})

    runner =
      Task.async(fn ->
        DesktopStageRunner.run(
          repo,
          %Issue{id: "456", identifier: "PPL-456", title: "Spec"},
          updated_prompt,
          @schema,
          opts
          |> Keyword.put(:request_key, updated_key)
          |> Keyword.put(:resume_thread_id, "native-thread")
          |> Keyword.put(:wait_timeout_ms, 3_000)
        )
      end)

    assert {:ok,
            %{
              "action" => "FOLLOWUP",
              "existing_thread_id" => "native-thread",
              "cwd" => ^canonical_checkout,
              "prompt" => stage_prompt
            }} = wait_request(store, updated_key)

    assert String.contains?(stage_prompt, "\n\n#{updated_prompt}")
    assert {:ok, _claimed} = DesktopRequest.claim(store, updated_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, updated_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, _completed} =
             DesktopRequest.complete(store, updated_key, %{
               thread_id: "native-thread",
               turn_id: "spec-turn",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "native-thread", turn_id: "spec-turn"}} = Task.await(runner)

    assert {:ok, %{"title" => ^bootstrap_title}} = DesktopRequest.get(store, bootstrap_key)
    assert {:ok, %{"status" => "SUCCEEDED", "turn_id" => "spec-turn"}} = DesktopRequest.get(store, updated_key)

    assert {:ok, %{"status" => "COMPLETE", "turn_id" => "spec-turn"}} =
             TaskLedger.get(store, "native-run:author")

    clarified_prompt = "Specify after Jira clarification"
    stale_key = DesktopStageRunner.request_key("native-run:author", nil, clarified_prompt)
    clarified_key = DesktopStageRunner.request_key("native-run:author", "spec-turn", clarified_prompt)

    assert {:ok, _task} =
             TaskLedger.update(store, "native-run:author", %{
               status: "RETRY_PENDING",
               prompt_sha256: digest(clarified_prompt),
               output_json: nil
             })

    clarified =
      Task.async(fn ->
        DesktopStageRunner.run(
          repo,
          %Issue{id: "456", identifier: "PPL-456", title: "Spec"},
          clarified_prompt,
          @schema,
          opts
          |> Keyword.put(:request_key, stale_key)
          |> Keyword.put(:resume_thread_id, "native-thread")
          |> Keyword.put(:wait_timeout_ms, 3_000)
        )
      end)

    assert {:ok, %{"action" => "FOLLOWUP", "existing_thread_id" => "native-thread"}} =
             wait_request(store, clarified_key)

    assert {:ok, _claimed} = DesktopRequest.claim(store, clarified_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, clarified_key, "native-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, _completed} =
             DesktopRequest.complete(store, clarified_key, %{
               thread_id: "native-thread",
               turn_id: "clarified-turn",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "native-thread", turn_id: "clarified-turn"}} = Task.await(clarified)

    assert {:ok, %{"workspace" => ^canonical_checkout, "thread_id" => "native-thread"}} =
             TaskLedger.get(store, "native-run:author")

    assert {:error, :unknown_request} = DesktopRequest.get(store, request_key)

    assert [[1]] =
             Store.query!(store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows

    assert [[2]] =
             Store.query!(store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'FOLLOWUP'").rows
  end

  test "a proven branch recovery reuses the bootstrap thread on the run-specific branch", %{store: store} do
    %{repo: repo, checkout: checkout, sha: sha, canonical_checkout: canonical_checkout} = native_repo_fixture()
    old_branch = "factory/PPL-456-writer"
    new_branch = "#{old_branch}-run-12345678"
    run_id = "run-12345678"
    task_key = "#{run_id}:feature-writer"
    thread_id = "writer-thread"

    File.write!(Path.join(repo, "prior.txt"), "prior candidate\n")
    git!(repo, ["add", "prior.txt"])
    git!(repo, ["commit", "--no-verify", "-m", "prior candidate"])
    git!(repo, ["branch", old_branch])
    git!(repo, ["switch", "--detach", sha])

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: run_id,
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "WRITING",
               repo_key: "grail",
               repo_path: repo,
               base_branch: "master",
               branch: old_branch,
               workspace_state: "UNMATERIALIZED"
             })

    assert {:ok, _prior_run} =
             RunLedger.register(store, %{
               run_id: "prior-run",
               issue_key: "PPL-456",
               kind: "DELIVERY",
               state: "FAILED",
               repo_path: repo,
               base_branch: "master",
               branch: old_branch
             })

    prompt = "Implement the authorized PPL-456 slice"

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: task_key,
               run_id: run_id,
               stage: "WRITING",
               role: "feature-writer-high-risk",
               status: "STARTING",
               model_provider: "codex",
               model_class: "deep",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               routing_reason: "risk-escalation",
               prompt_sha256: digest(prompt),
               codex_project_id: "project-grail"
             })

    bootstrap_key = DesktopStageRunner.request_key(task_key, nil, prompt) <> ":bootstrap"

    bootstrap_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["status"],
      "properties" => %{"status" => %{"type" => "string", "enum" => ["WORKSPACE_READY"]}}
    }

    assert {:ok, _bootstrap} =
             DesktopRequest.enqueue(store, %{
               request_key: bootstrap_key,
               target_kind: "TASK",
               target_key: task_key,
               action: "CREATE",
               codex_project_id: "project-grail",
               model: "gpt-6-sol",
               reasoning_effort: "xhigh",
               title: "PPL-456 · Feature Writer",
               prompt: "Factory request ID: #{bootstrap_key}\n\nVerify the workspace",
               schema: bootstrap_schema,
               cwd: repo,
               branch: old_branch,
               base_branch: "master",
               metadata: %{"issue_key" => "PPL-456", "workspace_mode" => "CODEX_NATIVE", "expected_sha" => sha}
             })

    assert {:ok, _claimed} = DesktopRequest.claim(store, bootstrap_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, bootstrap_key, thread_id, "project-grail", %{
               cwd: canonical_checkout,
               head_sha: sha
             })

    assert {:ok, _completed} =
             DesktopRequest.complete(store, bootstrap_key, %{
               thread_id: thread_id,
               turn_id: "bootstrap-turn",
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    assert {:error, {:native_branch_sha_mismatch, ^old_branch, ^sha, _prior_sha}} =
             Worktree.attach_native_branch(%{"path" => repo}, checkout, old_branch, sha)

    assert {:ok, _run} = RunLedger.update(store, run_id, %{branch: new_branch})

    assert {:ok, _task} =
             TaskLedger.update(store, task_key, %{
               status: "RETRY_PENDING",
               thread_id: thread_id,
               workspace: canonical_checkout,
               workspace_sha: sha
             })

    Store.query!(
      store,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [
        DateTime.utc_now() |> DateTime.to_iso8601(),
        "NATIVE_BRANCH_MISMATCH_RECOVERED",
        run_id,
        Jason.encode!(%{
          run_id: run_id,
          task_key: task_key,
          prior_run_id: "prior-run",
          previous_branch: old_branch,
          new_branch: new_branch,
          reused_thread_id: thread_id
        })
      ]
    )

    request_key = DesktopStageRunner.request_key(task_key, nil, prompt)

    runner_opts =
      opts(store, self())
      |> Keyword.put(:target_key, task_key)
      |> Keyword.put(:request_key, request_key)
      |> Keyword.put(:issue_key, "PPL-456")
      |> Keyword.put(:thread_name, "PPL-456 · Feature Writer")
      |> Keyword.put(:model, "gpt-6-sol")
      |> Keyword.put(:reasoning_effort, "xhigh")
      |> Keyword.put(:workspace_mode, "CODEX_NATIVE")
      |> Keyword.put(:expected_sha, sha)
      |> Keyword.put(:branch, new_branch)
      |> Keyword.put(:base_branch, "master")
      |> Keyword.put(:wait_timeout_ms, 1)

    for {field, value, mismatch} <- [
          {:project_id, "different-project", "codex_project_id"},
          {:model, "different-model", "model"},
          {:reasoning_effort, "low", "reasoning_effort"},
          {:base_branch, "develop", "base_branch"}
        ] do
      assert {:error, {:native_bootstrap_route_mismatch, fields}} =
               DesktopStageRunner.run(repo, issue(), prompt, @schema, Keyword.put(runner_opts, field, value))

      assert mismatch in fields
    end

    assert [[1]] = Store.query!(store, "SELECT COUNT(*) FROM factory_tasks WHERE task_key = ?", [task_key]).rows
    assert String.trim(git!(checkout, ["branch", "--show-current"])) == ""

    event = Store.one!(store, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'NATIVE_BRANCH_MISMATCH_RECOVERED'", [run_id])
    invalid_payload = event["payload_json"] |> Jason.decode!() |> Map.put("task_key", "another-task")
    Store.query!(store, "UPDATE events SET payload_json = ? WHERE run_id = ? AND event_type = 'NATIVE_BRANCH_MISMATCH_RECOVERED'", [Jason.encode!(invalid_payload), run_id])

    assert {:error, {:native_bootstrap_route_mismatch, [:branch_recovery_binding]}} =
             DesktopStageRunner.run(repo, issue(), prompt, @schema, runner_opts)

    Store.query!(store, "UPDATE events SET payload_json = ? WHERE run_id = ? AND event_type = 'NATIVE_BRANCH_MISMATCH_RECOVERED'", [event["payload_json"], run_id])

    legacy_recovery = %{
      task_key: task_key,
      turn_id: nil,
      new_branch: new_branch,
      prior_candidate_sha: sha,
      prior_run_id: "prior-run",
      prior_task_key: "prior-run:feature-writer",
      reused_thread_id: thread_id
    }

    Store.query!(
      store,
      "UPDATE events SET payload_json = ? WHERE run_id = ? AND event_type = 'NATIVE_BRANCH_MISMATCH_RECOVERED'",
      [Jason.encode!(legacy_recovery), run_id]
    )

    assert {:error, {:native_bootstrap_route_mismatch, [:branch_recovery_binding]}} =
             DesktopStageRunner.run(repo, issue(), prompt, @schema, runner_opts)

    Store.query!(
      store,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [
        DateTime.utc_now() |> DateTime.to_iso8601(),
        "NATIVE_BOOTSTRAP_RECOVERED",
        run_id,
        Jason.encode!(%{
          request_key: bootstrap_key,
          completed_turn_id: "bootstrap-turn",
          branch: new_branch,
          workspace_sha: sha,
          task_key: task_key
        })
      ]
    )

    assert {:ok, _starting_task} = TaskLedger.update(store, task_key, %{status: "STARTING"})

    assert {:error, {:desktop_request_pending, "PENDING", ^request_key}} =
             DesktopStageRunner.run(repo, issue(), prompt, @schema, runner_opts)

    assert {:ok,
            %{
              "action" => "FOLLOWUP",
              "branch" => ^new_branch,
              "existing_thread_id" => ^thread_id
            }} = DesktopRequest.get(store, request_key)

    assert String.trim(git!(checkout, ["branch", "--show-current"])) == new_branch
    assert [[1]] = Store.query!(store, "SELECT COUNT(*) FROM desktop_requests WHERE target_key = ? AND action = 'CREATE'", [task_key]).rows
    assert [[1]] = Store.query!(store, "SELECT COUNT(*) FROM factory_tasks WHERE task_key = ?", [task_key]).rows
    assert File.read!(Path.join(checkout, "README.md")) == "base\n"
  end

  test "high-risk native writer binds its checkout and attaches the exact branch before follow-up", %{store: store} do
    %{repo: repo, checkout: checkout, sha: sha, canonical_checkout: canonical_checkout} = native_repo_fixture()
    branch = "factory/PPL-789-writer"

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "writer-run",
               issue_key: "PPL-789",
               kind: "DELIVERY",
               state: "IMPLEMENTING",
               repo_path: repo,
               base_branch: "master",
               branch: branch,
               factory_owned: false
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "writer-run:feature-writer",
               run_id: "writer-run",
               stage: "IMPLEMENTING",
               role: "feature-writer-high-risk",
               status: "STARTING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: digest("Implement")
             })

    request_key = DesktopStageRunner.request_key("writer-run:feature-writer", nil, "Implement")
    bootstrap_key = request_key <> ":bootstrap"

    opts =
      opts(store, self())
      |> Keyword.put(:target_key, "writer-run:feature-writer")
      |> Keyword.put(:request_key, request_key)
      |> Keyword.put(:issue_key, "PPL-789")
      |> Keyword.put(:branch, branch)
      |> Keyword.put(:workspace_mode, "CODEX_NATIVE")
      |> Keyword.put(:expected_sha, sha)
      |> Keyword.put(:wait_timeout_ms, 3_000)

    runner =
      Task.async(fn ->
        DesktopStageRunner.run(
          repo,
          %Issue{id: "789", identifier: "PPL-789", title: "Writer"},
          "Implement",
          @schema,
          opts
        )
      end)

    assert {:ok, %{"action" => "CREATE"}} = wait_request(store, bootstrap_key)
    assert {:ok, _claimed} = DesktopRequest.claim(store, bootstrap_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, bootstrap_key, "writer-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, %{"worktree" => ^canonical_checkout, "workspace_state" => "CODEX_NATIVE"}} =
             RunLedger.get(store, "writer-run")

    assert {:ok, _completed} =
             DesktopRequest.complete(store, bootstrap_key, %{
               thread_id: "writer-thread",
               turn_id: "bootstrap-turn",
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{"action" => "FOLLOWUP", "cwd" => ^canonical_checkout}} = wait_request(store, request_key)
    assert String.trim(git!(checkout, ["branch", "--show-current"])) == branch

    changed_prompt = "Implement updated Jira snapshot"
    changed_key = DesktopStageRunner.request_key("writer-run:feature-writer", nil, changed_prompt)

    assert {:error, :native_stage_already_submitted} =
             DesktopStageRunner.run(
               repo,
               %Issue{id: "789", identifier: "PPL-789", title: "Writer"},
               changed_prompt,
               @schema,
               Keyword.put(opts, :request_key, changed_key)
             )

    assert {:error, :unknown_request} = DesktopRequest.get(store, changed_key)
    assert {:ok, _claimed} = DesktopRequest.claim(store, request_key)

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, request_key, "writer-thread", "project-grail", %{
               cwd: checkout,
               head_sha: sha
             })

    assert {:ok, _completed} =
             DesktopRequest.complete(store, request_key, %{
               thread_id: "writer-thread",
               turn_id: "writer-turn",
               output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
             })

    assert {:ok, %{thread_id: "writer-thread", turn_id: "writer-turn"}} = Task.await(runner)
    assert [[1]] = Store.query!(store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows
  end

  test "a terminal unclaimed native bootstrap failure gets a fresh request on the next specification attempt", %{
    store: store
  } do
    %{repo: repo, sha: sha} = native_repo_fixture()
    prompt = "Specify the ticket"
    task_key = "retry-run:author"
    request_key = DesktopStageRunner.request_key(task_key, nil, prompt)
    bootstrap_key = request_key <> ":bootstrap"

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "retry-run",
               issue_key: "PPL-456",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               repo_path: repo,
               base_branch: "master",
               runtime: "codex-desktop-broker",
               factory_owned: false
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: task_key,
               run_id: "retry-run",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "STARTING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: digest(prompt)
             })

    runner_opts =
      opts(store, self())
      |> Keyword.put(:target_key, task_key)
      |> Keyword.put(:request_key, request_key)
      |> Keyword.put(:issue_key, "PPL-456")
      |> Keyword.put(:workspace_mode, "CODEX_NATIVE")
      |> Keyword.put(:expected_sha, sha)
      |> Keyword.put(:wait_timeout_ms, 200)

    first =
      Task.async(fn ->
        DesktopStageRunner.run(repo, %Issue{id: "456", identifier: "PPL-456", title: "Spec"}, prompt, @schema, runner_opts)
      end)

    assert {:ok, %{"status" => "PENDING"}} = wait_request(store, bootstrap_key)
    assert {:ok, %{"status" => "FAILED"}} = DesktopRequest.fail(store, bootstrap_key, "startup_failed")
    assert {:error, {:desktop_request_failed, "startup_failed"}} = Task.await(first)

    assert {:ok, _run} = RunLedger.update(store, "retry-run", %{state: "FAILED"})
    assert {:ok, _task} = TaskLedger.update(store, task_key, %{status: "FAILED"})
    assert {:ok, _run} = RunLedger.update(store, "retry-run", %{state: "SPEC_DRAFTING", attempt: 2})
    assert {:ok, _task} = TaskLedger.update(store, task_key, %{status: "RETRY_PENDING"})

    assert {:error, {:desktop_request_pending, "PENDING", fresh_bootstrap}} =
             DesktopStageRunner.run(
               repo,
               %Issue{id: "456", identifier: "PPL-456", title: "Spec"},
               prompt,
               @schema,
               runner_opts
             )

    refute fresh_bootstrap == bootstrap_key
    assert {:ok, %{"action" => "CREATE", "status" => "PENDING"}} = DesktopRequest.get(store, fresh_bootstrap)
    assert [[2]] = Store.query!(store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows
  end

  test "a terminal unclaimed native follow-up failure can retry in the same task after a prior turn", %{store: store} do
    %{repo: repo, sha: sha} = native_repo_fixture()
    task_key = "followup-retry-run:author"
    prompt = "Refine the specification"
    old_key = DesktopStageRunner.request_key(task_key, "prior-turn", prompt)

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "followup-retry-run",
               issue_key: "PPL-456",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               repo_path: repo,
               base_branch: "master",
               runtime: "codex-desktop-broker",
               factory_owned: false
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: task_key,
               run_id: "followup-retry-run",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "RETRY_PENDING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               thread_id: "native-thread",
               workspace_sha: sha,
               prompt_sha256: digest(prompt)
             })

    assert {:ok, _task} = TaskLedger.update(store, task_key, %{turn_id: "prior-turn"})

    runner_opts =
      opts(store, self())
      |> Keyword.put(:target_key, task_key)
      |> Keyword.put(:request_key, old_key)
      |> Keyword.put(:issue_key, "PPL-456")
      |> Keyword.put(:workspace_mode, "CODEX_NATIVE")
      |> Keyword.put(:resume_thread_id, "native-thread")
      |> Keyword.put(:previous_turn_id, "prior-turn")
      |> Keyword.put(:expected_sha, sha)
      |> Keyword.put(:wait_timeout_ms, 100)

    first =
      Task.async(fn ->
        DesktopStageRunner.run(repo, %Issue{id: "456", identifier: "PPL-456", title: "Spec"}, prompt, @schema, runner_opts)
      end)

    assert {:ok, %{"status" => "PENDING"}} = wait_request(store, old_key)
    assert {:ok, %{"status" => "FAILED"}} = DesktopRequest.fail(store, old_key, "not_sent")
    assert {:error, {:desktop_request_failed, "not_sent"}} = Task.await(first)
    assert {:ok, _run} = RunLedger.update(store, "followup-retry-run", %{attempt: 2})

    assert {:error, {:desktop_request_pending, "PENDING", fresh_key}} =
             DesktopStageRunner.run(repo, %Issue{id: "456", identifier: "PPL-456", title: "Spec"}, prompt, @schema, runner_opts)

    refute fresh_key == old_key

    assert {:ok, %{"action" => "FOLLOWUP", "existing_thread_id" => "native-thread", "status" => "PENDING"}} =
             DesktopRequest.get(store, fresh_key)

    assert [[0]] = Store.query!(store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows
  end

  defp issue, do: %Issue{id: "123", identifier: "PPL-123", title: "Spec"}

  defp opts(store, parent) do
    [
      store: store,
      target_kind: "TASK",
      target_key: "run-1:author",
      request_key: DesktopStageRunner.request_key("run-1:author", nil, "Specify"),
      project_id: "project-grail",
      model: "gpt-6-sol",
      reasoning_effort: "high",
      thread_name: "PPL-123 · Specification Author",
      issue_key: "PPL-123",
      poll_ms: 5,
      wait_timeout_ms: 1_000,
      on_thread_started: fn thread_id -> send(parent, {:thread_started, thread_id}) end
    ]
  end

  defp wait_request(store, request_key, tries \\ 100)
  defp wait_request(_store, _request_key, 0), do: {:error, :request_not_enqueued}

  defp wait_request(store, request_key, tries) do
    case DesktopRequest.get(store, request_key) do
      {:ok, request} ->
        {:ok, request}

      {:error, :unknown_request} ->
        Process.sleep(5)
        wait_request(store, request_key, tries - 1)
    end
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp native_repo_fixture do
    root = Path.join(System.tmp_dir!(), "factory-native-runner-#{System.unique_integer([:positive])}")
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
    %{repo: repo, checkout: checkout, sha: sha, canonical_checkout: canonical_checkout}
  end
end
