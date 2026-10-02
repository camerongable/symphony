defmodule SymphonyElixir.FactoryFullLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{
    Contract,
    Control,
    DesktopRequest,
    DesktopToolArgs,
    JiraMcpConnector,
    MrFeedback,
    MrFeedbackLedger,
    Recovery,
    RunLedger,
    Scheduler,
    StageSchemas,
    Store,
    TaskLauncher,
    TaskLedger
  }

  @candidate String.duplicate("a", 40)

  defmodule Controller do
    alias SymphonyElixir.Factory.RunLedger

    @spec run(map(), Path.t(), map(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_factory, _workspace, issue, prompt, schema, opts) do
      properties = schema["properties"]

      cond do
        Map.has_key?(properties, "snapshot_json") -> snapshot(issue)
        Map.has_key?(properties, "readback_text") -> write_jira(issue, prompt, opts)
        Map.has_key?(properties, "pipeline_status") -> ci_status(issue)
        Map.has_key?(properties, "mr_url") -> create_mr(issue)
      end
    end

    defp snapshot(issue) do
      ticket = Process.get(:full_lifecycle_ticket) |> sync_fake_mcp_comment()
      json = if issue.identifier == "FACTORY", do: Jason.encode!([ticket]), else: Jason.encode!(ticket)
      {:ok, %{"status" => "PASS", "issue_key" => issue.identifier, "snapshot_json" => json}}
    end

    defp sync_fake_mcp_comment(ticket) do
      trace = Process.get(:mcp_shell_trace)
      comment = Process.get(:mcp_shell_comment)

      if is_binary(trace) and is_binary(comment) and File.exists?(trace) and
           String.contains?(File.read!(trace), ~s("tool":"jira_add_comment")) and ticket["comments"] == [] do
        updated = Map.put(ticket, "comments", [%{"id" => "1", "text" => comment}])
        Process.put(:full_lifecycle_ticket, updated)
        updated
      else
        ticket
      end
    end

    defp write_jira(issue, prompt, opts) do
      if Process.get(:forbid_controller_jira_write), do: raise("native Jira write must use the connector")

      approvals = Keyword.fetch!(opts, :allowed_mcp_tool_approvals)
      comment = Enum.find(approvals, &(&1.tool == "jira_add_comment"))
      labels = Enum.find(approvals, &(&1.tool == "jira_update_issue"))
      ticket = Process.get(:full_lifecycle_ticket)

      {ticket, comment_id} =
        case comment do
          nil ->
            {ticket, nil}

          %{body_equals: body} ->
            id = Integer.to_string(length(ticket["comments"]) + 1)
            {Map.update!(ticket, "comments", &(&1 ++ [%{"id" => id, "text" => body}])), id}
        end

      ticket = if labels, do: Map.put(ticket, "labels", labels.labels_equals), else: ticket
      Process.put(:full_lifecycle_ticket, ticket)
      send(self(), {:synthetic_jira_write, issue.identifier, comment && comment.body_equals, ticket["labels"]})

      {:ok,
       %{
         "status" => "PASS",
         "issue_key" => issue.identifier,
         "operation" => prompt,
         "comment_id" => comment_id,
         "labels" => ticket["labels"],
         "readback_text" => if(comment, do: comment.body_equals, else: prompt)
       }}
    end

    defp ci_status(issue) do
      run = Process.get(:full_lifecycle_store) |> RunLedger.list() |> Enum.find(&(&1["issue_key"] == issue.identifier))
      [status | remaining] = Process.get(:full_lifecycle_ci_statuses)
      Process.put(:full_lifecycle_ci_statuses, remaining)
      {remote_head, 0} = System.cmd("git", ["rev-parse", "refs/heads/#{run["branch"]}"], cd: Process.get(:full_lifecycle_origin))
      if String.trim(remote_head) != run["candidate_sha"], do: raise("CI cannot report on an unpublished candidate")

      {:ok,
       %{
         "status" => status,
         "mr_url" => run["mr_url"],
         "iid" => run["mr_iid"],
         "source_branch" => run["branch"],
         "target_branch" => run["base_branch"],
         "sha" => run["candidate_sha"],
         "draft" => true,
         "reviewers_count" => 0,
         "assignee_id" => 11_599_766,
         "mr_state" => "opened",
         "pipeline_id" => if(status == "REPAIR", do: 99, else: 100),
         "pipeline_url" => "https://gitlab.example/pipelines/100",
         "pipeline_sha" => run["candidate_sha"],
         "pipeline_ref" => "refs/merge-requests/#{run["mr_iid"]}/head",
         "pipeline_source" => "merge_request_event",
         "pipeline_status" => if(status == "REPAIR", do: "failed", else: "success"),
         "required_jobs" => [%{"id" => 88, "name" => "bazel", "status" => if(status == "REPAIR", do: "failed", else: "success")}],
         "findings" => if(status == "REPAIR", do: ["repair the deterministic test"], else: [])
       }}
    end

    defp create_mr(issue) do
      run =
        Process.get(:full_lifecycle_store)
        |> RunLedger.list()
        |> Enum.find(&(&1["kind"] == "DELIVERY" and &1["issue_key"] == issue.identifier))

      send(self(), {:synthetic_mr, run["branch"], run["candidate_sha"]})

      {:ok,
       %{
         "status" => "PASS",
         "mr_url" => "https://gitlab.example/grail/-/merge_requests/42",
         "iid" => 42,
         "source_branch" => run["branch"],
         "target_branch" => run["base_branch"],
         "sha" => run["candidate_sha"],
         "draft" => true,
         "reviewers_count" => 0,
         "assignee_id" => 11_599_766,
         "state" => "opened"
       }}
    end
  end

  defmodule JiraConnector do
    alias SymphonyElixir.FactoryFullLifecycleTest.Tickets
    @spec call(String.t(), map(), keyword()) :: {:ok, map()}
    def call("jira_get_issue", %{"issue_key" => issue_key, "include" => "comments"}, _opts) do
      ticket = Tickets.get(issue_key)
      if ticket["key"] != issue_key, do: raise("wrong Jira issue")

      ticket =
        if Process.get(:jira_connector_override_labels),
          do: Map.put(ticket, "labels", Process.get(:jira_connector_override_labels)),
          else: ticket

      ticket =
        if Process.get(:jira_connector_override_status),
          do: Map.put(ticket, "status", Process.get(:jira_connector_override_status)),
          else: ticket

      {:ok, ticket}
    end

    def call("jira_add_comment", %{"issue_key" => issue_key, "body" => body}, _opts) do
      ticket = Tickets.get(issue_key)
      if ticket["key"] != issue_key, do: raise("wrong Jira issue")
      id = Integer.to_string(length(ticket["comments"]) + 1)
      Tickets.put(Map.update!(ticket, "comments", &(&1 ++ [%{"id" => id, "text" => body}])))
      send(self(), {:synthetic_jira_comment, issue_key, body})
      {:ok, %{"id" => id}}
    end

    def call("jira_update_issue", %{"issue_key" => issue_key, "fields" => fields}, _opts) when is_binary(fields) do
      %{"labels" => labels} = Jason.decode!(fields)
      ticket = Tickets.get(issue_key)
      if ticket["key"] != issue_key, do: raise("wrong Jira issue")
      Tickets.put(Map.put(ticket, "labels", labels))
      send(self(), {:synthetic_jira_labels, issue_key, labels})
      {:ok, %{}}
    end
  end

  defmodule JiraReader do
    alias SymphonyElixir.FactoryFullLifecycleTest.Tickets
    @spec search(String.t(), keyword()) :: {:ok, [map()]}
    def search(_jql, _opts), do: {:ok, [Process.get(:full_lifecycle_ticket) | Process.get(:additional_lifecycle_tickets, [])]}

    @spec issue(String.t(), keyword()) :: {:ok, map()}
    def issue(issue_key, _opts) do
      ticket = Tickets.get(issue_key)
      trace = Process.get(:mcp_shell_trace)
      comment = Process.get(:mcp_shell_comment)

      ticket =
        if is_binary(trace) and is_binary(comment) and File.exists?(trace) and
             String.contains?(File.read!(trace), ~s("tool":"jira_add_comment")) and ticket["comments"] == [] do
          Map.put(ticket, "comments", [%{"id" => "1", "text" => comment}])
        else
          ticket
        end

      Tickets.put(ticket)
      {:ok, ticket}
    end
  end

  defmodule Tickets do
    def get(issue_key) do
      [Process.get(:full_lifecycle_ticket) | Process.get(:additional_lifecycle_tickets, [])]
      |> Enum.find(&(&1["key"] == issue_key))
    end

    def put(ticket) do
      if Process.get(:full_lifecycle_ticket)["key"] == ticket["key"] do
        Process.put(:full_lifecycle_ticket, ticket)
      else
        Process.put(
          :additional_lifecycle_tickets,
          Enum.map(Process.get(:additional_lifecycle_tickets), &replace(&1, ticket))
        )
      end
    end

    defp replace(current, ticket), do: if(current["key"] == ticket["key"], do: ticket, else: current)
  end

  defmodule FakeMcpAppServer do
    @spec call_mcp_tool(Path.t(), String.t(), String.t(), map()) :: {:ok, map()}
    def call_mcp_tool(_workspace, "Jira", "jira_get_issue", %{"issue_key" => issue_key, "include" => "comments", "comment_limit" => 100}) do
      ticket = Process.get(:full_lifecycle_ticket)
      if ticket["key"] != issue_key, do: raise("wrong Jira issue")

      response = %{"content" => [], "structuredContent" => %{"result" => Jason.encode!(ticket)}}
      {:ok, if(Process.get(:mcp_jira_issue_error), do: Map.put(response, "isError", true), else: response)}
    end

    def call_mcp_tool(_workspace, "Jira", "jira_add_comment", %{"issue_key" => issue_key, "body" => body}) do
      ticket = Process.get(:full_lifecycle_ticket)
      if ticket["key"] != issue_key, do: raise("wrong Jira issue")
      id = Integer.to_string(length(ticket["comments"]) + 1)
      Process.put(:full_lifecycle_ticket, Map.update!(ticket, "comments", &(&1 ++ [%{"id" => id, "text" => body}])))
      send(self(), {:mcp_jira_comment, issue_key, body})
      {:ok, %{"content" => [%{"type" => "text", "text" => "comment added"}]}}
    end
  end

  defmodule GitlabReader do
    def fetch(route, run, _opts) do
      mr = Process.get(:full_lifecycle_mr)
      {head, 0} = System.cmd("git", ["rev-parse", "refs/heads/#{mr["source_branch"]}"], cd: Process.get(:full_lifecycle_origin))
      mr = Map.put(mr, "sha", String.trim(head))

      if route["gitlab_project"] == mr["project"] and run["mr_iid"] == mr["iid"] and
           run["mr_url"] == mr["web_url"] and run["branch"] == mr["source_branch"] and run["candidate_sha"] == mr["sha"] do
        {:ok, %{mr: mr, discussions: Process.get(:full_lifecycle_discussions)}}
      else
        {:error, :gitlab_feedback_mr_mismatch}
      end
    end
  end

  defmodule Worktree do
    @candidate String.duplicate("a", 40)
    @base String.duplicate("b", 40)

    @spec base_sha(map()) :: {:ok, String.t()}
    def base_sha(_route), do: {:ok, @base}

    @spec create_detached(map(), String.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()}
    def create_detached(route, _issue_key, run_id, stage, _sha) do
      path = Path.join(route["workspace_root"], "#{run_id}-#{stage}")
      File.mkdir_p!(path)
      {:ok, path}
    end

    @spec create_detached_pinned(map(), String.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()}
    def create_detached_pinned(route, issue_key, run_id, stage, sha),
      do: create_detached(route, issue_key, run_id, stage, sha)

    @spec validate_detached(map(), Path.t()) :: {:ok, map()}
    def validate_detached(_route, path), do: {:ok, %{path: path, sha: @base}}

    @spec remove_detached(map(), Path.t()) :: :ok
    def remove_detached(_route, path) do
      File.rm_rf!(path)
      :ok
    end

    @spec ensure_writer(map(), String.t(), String.t()) :: {:ok, map()}
    def ensure_writer(route, issue_key, run_id) do
      path = Path.join(route["workspace_root"], "#{run_id}-#{issue_key}-writer")
      File.mkdir_p!(path)
      {:ok, %{path: path, branch: route["branch"], base_branch: "master", head: @candidate}}
    end

    @spec candidate(Path.t(), String.t()) :: {:ok, String.t()}
    def candidate(_path, _base), do: {:ok, @candidate}

    @spec reachable?(map(), String.t()) :: boolean()
    def reachable?(_route, @candidate), do: true
    def reachable?(_route, _sha), do: false

    @spec push_exact(map(), Path.t(), String.t(), String.t()) :: {:ok, map()}
    def push_exact(_route, _path, branch, @candidate) do
      send(self(), {:synthetic_push, branch, @candidate})
      {:ok, %{branch: branch, sha: @candidate}}
    end
  end

  defmodule Cleanup do
    @spec ensure_capacity(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def ensure_capacity(_store, _policy, repo_key, _opts \\ []) do
      {:ok, %{repo_key: repo_key, available_writer_slots: 1, cleaned: []}}
    end

    @spec hibernate(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def hibernate(_store, _policy, run_id, _opts \\ []) do
      {:ok, %{result: "SKIPPED", run_id: run_id, reason: "synthetic test"}}
    end
  end

  defmodule Launcher do
    @spec launch(term(), term(), map(), map(), Path.t(), String.t(), map(), keyword()) :: term()
    def launch(store, supervisor, run, issue, workspace, prompt, schema, opts),
      do: TaskLauncher.launch(store, supervisor, run, issue, workspace, prompt, schema, opts)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "factory-full-lifecycle-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "grail")
    binary = Path.join(root, "fake-codex")
    trace = Path.join(root, "requests.jsonl")
    database = Path.join(root, "factory.sqlite")
    File.mkdir_p!(repo)
    File.write!(binary, fake_codex_script(trace, repo))
    File.chmod!(binary, 0o755)

    previous_trace = System.get_env("SYMP_TEST_FULL_LIFECYCLE_TRACE")
    System.put_env("SYMP_TEST_FULL_LIFECYCLE_TRACE", trace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, codex_command: "#{binary} app-server")

    {:ok, store} = Store.start_link(database: database)
    {:ok, supervisor} = Task.Supervisor.start_link()
    Process.put(:full_lifecycle_store, store)
    Process.put(:full_lifecycle_ticket, ticket())

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
        "providers" => %{"codex" => %{"deep" => "gpt-6-sol"}},
        "roles" =>
          Map.new(
            ~w(specification-author specification-critic feature-planner feature-writer change-verifier),
            &{&1, %{"provider" => "codex", "model_class" => "deep", "reasoning_effort" => "high"}}
          )
      },
      cleanup: %{},
      review_feedback: %{"enabled" => false},
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
      if previous_trace,
        do: System.put_env("SYMP_TEST_FULL_LIFECYCLE_TRACE", previous_trace),
        else: System.delete_env("SYMP_TEST_FULL_LIFECYCLE_TRACE")

      File.rm_rf(root)
    end)

    %{context: context, store: store, trace: trace, database: database}
  end

  test "a ticket crosses specification confirmation, one resumed writer, verification and draft MR delivery", state do
    context = Map.update!(state.context, :factory, &Map.put(&1, :specification_authorization_mode, "human_confirmation"))
    state = %{state | context: context}

    assert {:ok, %{launches: [author]}} = tick(state.context)
    finish(author)
    assert state_for(state.store, "SPECIFICATION") == "SPEC_DRAFTING"

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "SPEC_WRITING"

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "SPEC_REVIEW"
    draft = hd(Process.get(:full_lifecycle_ticket)["comments"])["text"]
    assert draft =~ "AI FACTORY CONTRACT BEGIN issue-hex=50504C2D313233 revision=1"

    assert {:ok, %{launches: [critic]}} = tick(state.context)
    finish(critic)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "SPEC_READY_WRITE"
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "AWAITING_CONFIRMATION"
    refute "ai-ready" in Process.get(:full_lifecycle_ticket)["labels"]

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "AWAITING_CONFIRMATION"

    spec_run = run_for(state.store, "SPECIFICATION")
    contract = Contract.bind("PPL-123", spec_run["spec_revision"], spec_run["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)

    Process.put(
      :full_lifecycle_ticket,
      Map.update!(ticket, "comments", &(&1 ++ [%{"id" => "3", "text" => Contract.confirmation_marker(contract)}]))
    )

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "DELIVERED"
    assert "ai-ready" in Process.get(:full_lifecycle_ticket)["labels"]
    assert {:ok, ^contract} = Contract.authorized_from_snapshot(Process.get(:full_lifecycle_ticket), "PPL-123")

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "WRITING"

    assert {:ok, %{launches: [first_writer]}} = tick(state.context)
    finish(first_writer)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert %{state: "WRITING", iteration: 1} = delivery_state(state.store)

    assert {:ok, %{launches: [second_writer]}} = tick(state.context)
    assert second_writer.task_key == first_writer.task_key
    finish(second_writer)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "VERIFYING"

    assert {:ok, %{launches: [verifier]}} = tick(state.context)
    finish(verifier)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "PUSHING"

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "READY_FOR_REVIEW"
    assert "ai-review" in Process.get(:full_lifecycle_ticket)["labels"]
    assert_received {:synthetic_push, _, @candidate}
    assert_received {:synthetic_mr, _, @candidate}

    delivery = run_for(state.store, "DELIVERY")
    assert delivery["candidate_sha"] == @candidate
    assert delivery["mr_url"] == "https://gitlab.example/grail/-/merge_requests/42"

    writer_tasks =
      state.store
      |> TaskLedger.list_for_run(delivery["run_id"])
      |> Enum.filter(&(&1["role"] == "feature-writer"))

    assert [%{"codex_project_id" => "project-grail", "thread_id" => writer_id}] = writer_tasks

    calls = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    writer_resumes = Enum.filter(calls, &(&1["method"] == "thread/resume"))
    assert [resume] = writer_resumes
    assert get_in(resume, ["params", "threadId"]) == writer_id
    refute Enum.any?(calls, &(&1["method"] == "thread/fork"))

    starts = Enum.filter(calls, &(&1["method"] == "thread/start"))
    assert length(starts) == 4

    bindings = Enum.filter(calls, &(&1["method"] == "thread/metadata/update"))
    assert length(bindings) == 5
    assert Enum.all?(bindings, &(get_in(&1, ["params", "projectId"]) == "project-grail"))
  end

  test "native Codex tasks stay in the routed project and one writer reaches a draft MR", state do
    Process.put(:forbid_controller_jira_write, true)
    repo = state.context.factory.repositories["grail"]["path"]
    origin = Path.join(state.context.workspace_root, "origin.git")
    initialize_native_repository!(repo, origin)
    high_risk_role = %{"provider" => "codex", "model_class" => "deep", "reasoning_effort" => "high"}

    context =
      Map.update!(state.context, :factory, fn factory ->
        models =
          factory.models
          |> Map.update!("roles", &Map.put(&1, "feature-writer-high-risk", high_risk_role))
          |> Map.put("delivery_routing", %{
            "default_role" => "feature-writer",
            "high_risk_role" => "feature-writer-high-risk",
            "high_risk_values" => ["high"],
            "unknown_risk_is_high" => true
          })

        factory |> Map.put(:task_transport, "desktop_broker") |> Map.put(:models, models)
      end)

    worktree = SymphonyElixir.Factory.Worktree

    assert {:ok, %{launches: [author]}} = tick(context, worktree)
    complete_native_stage(state.store, author, fn _path -> Map.put(author_output(), "risk", "high") end)
    finish(author)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: []}} = tick(context, worktree)

    assert {:ok, %{launches: [critic]}} = tick(context, worktree)

    complete_native_stage(state.store, critic, fn _path ->
      %{"status" => "PASS", "findings" => [], "required_questions" => []}
    end)

    finish(critic)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "SPECIFICATION") == "DELIVERED"

    spec_run = run_for(state.store, "SPECIFICATION")
    contract = Contract.bind("PPL-123", spec_run["spec_revision"], spec_run["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    assert "ai-ready" in ticket["labels"]
    assert Contract.authorized?(ticket, contract)
    assert Enum.any?(ticket["comments"], &String.contains?(&1["text"], "mode=automatic"))
    refute Enum.any?(ticket["comments"], &String.contains?(&1["text"], "AI FACTORY CONFIRM "))

    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "WRITING"

    assert {:ok, %{launches: [first_writer]}} = tick(context, worktree)
    assert {:ok, %{"role" => "feature-writer-high-risk"}} = TaskLedger.get(state.store, first_writer.task_key)

    first_thread =
      complete_native_stage(state.store, first_writer, fn path ->
        File.write!(Path.join(path, "first.txt"), "first\n")

        %{
          "status" => "CONTINUE",
          "summary" => "first coherent slice",
          "changed_paths" => ["first.txt"],
          "commit_message" => "feat(PPL-123): add first slice",
          "remaining_criteria" => ["AC-1"],
          "blockers" => [],
          "checks" => ["unit tests passed"]
        }
      end)

    finish(first_writer)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert %{state: "WRITING", iteration: 1} = delivery_state(state.store)

    assert {:ok, %{launches: [second_writer]}} = tick(context, worktree)
    assert second_writer.task_key == first_writer.task_key

    second_thread =
      complete_native_stage(state.store, second_writer, fn path ->
        File.write!(Path.join(path, "second.txt"), "second\n")

        %{
          "status" => "COMPLETE",
          "summary" => "second coherent slice",
          "changed_paths" => ["second.txt"],
          "commit_message" => "feat(PPL-123): add second slice",
          "remaining_criteria" => [],
          "blockers" => [],
          "checks" => ["unit tests passed"]
        }
      end)

    assert second_thread == first_thread
    finish(second_writer)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "VERIFYING"

    delivery = run_for(state.store, "DELIVERY")
    assert String.trim(git!(repo, ["rev-list", "--count", "origin/master..#{delivery["branch"]}"])) == "2"

    candidate = delivery["candidate_sha"]
    assert {:ok, %{launches: [verifier]}} = tick(context, worktree)

    complete_native_stage(state.store, verifier, fn path ->
      assert String.trim(git!(path, ["rev-parse", "HEAD"])) == candidate
      %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => ["unit tests passed"]}
    end)

    finish(verifier)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "PUSHING"
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "READY_FOR_REVIEW"
    assert "ai-review" in Process.get(:full_lifecycle_ticket)["labels"]
    assert_received {:synthetic_jira_comment, "PPL-123", _body}
    assert_received {:synthetic_jira_labels, "PPL-123", ["ai-review", "repo-grail"]}
    assert_received {:synthetic_mr, _, ^candidate}

    delivery = run_for(state.store, "DELIVERY")
    assert String.trim(git!(origin, ["rev-parse", "refs/heads/#{delivery["branch"]}"])) == candidate

    assert [%{"thread_id" => ^first_thread, "codex_project_id" => "project-grail", "role" => "feature-writer-high-risk"}] =
             Enum.filter(TaskLedger.list_for_run(state.store, delivery["run_id"]), &TaskLedger.source_writer?/1)

    assert [[4]] = Store.query!(state.store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows
  end

  test "authorized ai-ready work uses the default writer and survives SQLite reopen before verifier dispatch", state do
    Process.put(:forbid_controller_jira_write, true)
    repo = state.context.factory.repositories["grail"]["path"]
    origin = Path.join(state.context.workspace_root, "origin.git")
    initialize_native_repository!(repo, origin)
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"] <> "\n\nRisk: low")

    Process.put(
      :full_lifecycle_ticket,
      ticket()
      |> Map.put("labels", ["repo-grail", "ai-ready"])
      |> Map.put("comments", [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
        %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
      ])
    )

    context =
      Map.update!(state.context, :factory, fn factory ->
        models =
          factory.models
          |> put_in(["providers", "codex", "fast"], "gpt-6-luna")
          |> put_in(["roles", "feature-writer"], %{
            "provider" => "codex",
            "model_class" => "fast",
            "reasoning_effort" => "medium"
          })

        factory |> Map.put(:task_transport, "desktop_broker") |> Map.put(:models, models)
      end)

    worktree = SymphonyElixir.Factory.Worktree
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "WRITING"
    refute run_for(state.store, "SPECIFICATION")

    assert {:ok, %{launches: [first_writer]}} = tick(context, worktree)

    assert {:ok, %{"role" => "feature-writer", "model_class" => "fast", "model" => "gpt-6-luna"}} =
             TaskLedger.get(state.store, first_writer.task_key)

    writer_thread =
      complete_native_stage(state.store, first_writer, fn path ->
        File.write!(Path.join(path, "first.txt"), "first\n")

        %{
          "status" => "CONTINUE",
          "summary" => "first slice",
          "changed_paths" => ["first.txt"],
          "commit_message" => "feat(PPL-123): add first slice",
          "remaining_criteria" => ["AC-1"],
          "blockers" => [],
          "checks" => ["synthetic check"]
        }
      end)

    finish(first_writer)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: [second_writer]}} = tick(context, worktree)
    assert second_writer.task_key == first_writer.task_key

    assert complete_native_stage(state.store, second_writer, fn path ->
             File.write!(Path.join(path, "second.txt"), "second\n")

             %{
               "status" => "COMPLETE",
               "summary" => "candidate complete",
               "changed_paths" => ["second.txt"],
               "commit_message" => "feat(PPL-123): complete candidate",
               "remaining_criteria" => [],
               "blockers" => [],
               "checks" => ["synthetic check"]
             }
           end) == writer_thread

    finish(second_writer)
    assert %{state: "WRITING", iteration: 1} = delivery_state(state.store)
    assert {:ok, completed_task} = TaskLedger.get(state.store, second_writer.task_key)

    completed_requests_sql = """
    SELECT request_key, thread_id, turn_id, output_json FROM desktop_requests
    WHERE target_key = ? AND status = 'SUCCEEDED' ORDER BY request_key
    """

    completed_requests = Store.query!(state.store, completed_requests_sql, [second_writer.task_key]).rows

    assert length(completed_requests) == 3
    GenServer.stop(state.store)
    {:ok, reopened_store} = Store.start_link(database: state.database)
    Process.put(:full_lifecycle_store, reopened_store)
    context = %{context | store: reopened_store}

    assert {:ok, ^completed_task} = TaskLedger.get(reopened_store, second_writer.task_key)

    assert Store.query!(reopened_store, completed_requests_sql, [second_writer.task_key]).rows == completed_requests

    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(reopened_store, "DELIVERY") == "VERIFYING"
    delivery = run_for(reopened_store, "DELIVERY")
    candidate = delivery["candidate_sha"]
    assert String.trim(git!(repo, ["rev-list", "--count", "origin/master..#{delivery["branch"]}"])) == "2"
    refute_received {:synthetic_mr, _, _}

    assert {:ok, %{launches: [verifier]}} = tick(context, worktree)
    assert {:ok, verifier_task} = TaskLedger.get(reopened_store, verifier.task_key)
    assert verifier_task["role"] == "change-verifier"
    assert verifier_task["model_class"] == "deep"
    bootstrap = await_native_request(reopened_store, verifier.task_key)
    assert bootstrap["action"] == "CREATE"
    assert %{result: "INITIALIZED"} = Control.initialize(reopened_store, context.factory)
    assert {:ok, _} = Control.activate(reopened_store, context.factory, context.factory.dispatcher_id)
    assert {:ok, _} = DesktopRequest.claim(reopened_store, bootstrap["request_key"])

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} =
             DesktopRequest.fail(reopened_store, bootstrap["request_key"], "CREATE_THREAD_INVALID_ARGUMENTS",
               rejected_tool_call_id: "exec-1234abcd",
               tool_error: "create_thread received invalid arguments"
             )

    verifier_key = verifier.task_key
    rejection_error = {:desktop_request_reconciliation_required, "CREATE_THREAD_INVALID_ARGUMENTS"}
    assert_receive {:factory_task_finished, ^verifier_key, {:error, ^rejection_error}}, 5_000
    Process.demonitor(verifier.ref, [:flush])
    assert {:ok, %{"status" => "WAITING_FOR_BROKER"}} = TaskLedger.get(reopened_store, verifier_key)

    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, recovered} = DesktopRequest.get(reopened_store, bootstrap["request_key"])
    assert recovered["status"] == "PENDING"
    assert recovered["payload_sha256"] == bootstrap["payload_sha256"]
    assert recovered["target_key"] == verifier.task_key

    assert [[1]] =
             Store.query!(
               reopened_store,
               """
               SELECT COUNT(*) FROM events WHERE event_type = 'REJECTED_NATIVE_CREATE_REARMED'
               AND json_extract(payload_json, '$.request_key') = ?
               """,
               [bootstrap["request_key"]]
             ).rows

    complete_native_bootstrap(reopened_store, recovered)
    Store.query!(reopened_store, "UPDATE factory_tasks SET updated_at = ? WHERE task_key = ?", ["2020-01-01T00:00:00Z", verifier_key])
    assert {:ok, %{launches: [resumed_verifier]}} = tick(context, worktree)
    assert resumed_verifier.task_key == verifier_key

    verifier_thread =
      complete_native_stage(reopened_store, resumed_verifier, fn path ->
        assert String.trim(git!(path, ["rev-parse", "HEAD"])) == candidate
        assert String.trim(git!(path, ["rev-parse", "--abbrev-ref", "HEAD"])) == "HEAD"
        assert path != completed_task["workspace"]
        %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => ["synthetic check"]}
      end)

    refute verifier_thread == writer_thread
    finish(resumed_verifier)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(reopened_store, "DELIVERY") == "PUSHING"
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(reopened_store, "DELIVERY") == "READY_FOR_REVIEW"
    delivered = run_for(reopened_store, "DELIVERY")
    assert delivered["candidate_sha"] == candidate
    assert {:ok, consumed_writer} = TaskLedger.get(reopened_store, second_writer.task_key)
    assert consumed_writer["workspace_sha"] == candidate
    assert consumed_writer["turn_id"] == completed_task["turn_id"]
    assert consumed_writer["output_json"] == completed_task["output_json"]
    assert delivered["mr_url"] == "https://gitlab.example/grail/-/merge_requests/42"
    assert String.trim(git!(origin, ["rev-parse", "refs/heads/#{delivered["branch"]}"])) == candidate
    assert_received {:synthetic_mr, _, ^candidate}

    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert run_for(reopened_store, "DELIVERY")["mr_url"] == delivered["mr_url"]
    refute_received {:synthetic_mr, _, _}
    assert [[2]] = Store.query!(reopened_store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows

    tasks = TaskLedger.list_for_run(reopened_store, delivery["run_id"])
    assert Enum.sort(Enum.map(tasks, & &1["role"])) == ["change-verifier", "feature-writer"]
    assert [%{"thread_id" => ^writer_thread}] = Enum.filter(tasks, &TaskLedger.source_writer?/1)
    refute run_for(reopened_store, "SPECIFICATION")

    route = context.factory.repositories["grail"] |> Map.put("repo_key", "grail")

    mr = %{
      "project" => route["gitlab_project"],
      "iid" => delivered["mr_iid"],
      "web_url" => delivered["mr_url"],
      "source_branch" => delivered["branch"],
      "sha" => candidate,
      "state" => "opened"
    }

    note = %{
      "id" => 51,
      "body" => "@Symphony please update the first slice",
      "updated_at" => "2026-10-01T00:00:00Z",
      "author" => %{"id" => 11_599_766}
    }

    discussion = %{"id" => "discussion-51", "notes" => [note]}
    Process.put(:full_lifecycle_mr, mr)
    Process.put(:full_lifecycle_origin, origin)
    Process.put(:full_lifecycle_discussions, [discussion])
    receipt_key = classify_review_edit(reopened_store, context, delivered, route, mr, discussion, note)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(reopened_store, "DELIVERY") == "REVIEW_WRITING"

    assert {:ok, %{"status" => "RETRY_PENDING", "thread_id" => ^writer_thread, "output_json" => nil}} =
             TaskLedger.get(reopened_store, second_writer.task_key)

    assert {:ok, %{launches: [review_writer]}} = tick(context, worktree)
    assert review_writer.task_key == second_writer.task_key
    review_request = await_native_request(reopened_store, review_writer.task_key)
    assert review_request["action"] == "FOLLOWUP"
    assert review_request["existing_thread_id"] == writer_thread
    refute Enum.any?(completed_requests, &(hd(&1) == review_request["request_key"]))
    assert String.trim(git!(origin, ["rev-parse", "refs/heads/#{delivered["branch"]}"])) == candidate

    assert complete_native_stage(reopened_store, review_writer, fn path ->
             File.write!(Path.join(path, "first.txt"), "reviewed\n")

             %{
               "status" => "COMPLETE",
               "summary" => "addressed review request",
               "changed_paths" => ["first.txt"],
               "commit_message" => "fix(PPL-123): address review feedback",
               "remaining_criteria" => [],
               "blockers" => [],
               "checks" => ["synthetic check"]
             }
           end) == writer_thread

    finish(review_writer)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    reworked = run_for(reopened_store, "DELIVERY")
    assert reworked["state"] == "VERIFYING"
    assert reworked["verifier_round"] == delivered["verifier_round"] + 1
    assert reworked["implementation_iteration"] == delivered["implementation_iteration"] + 1
    review_candidate = reworked["candidate_sha"]
    refute review_candidate == candidate
    assert {:ok, reworked_writer} = TaskLedger.get(reopened_store, review_writer.task_key)
    assert reworked_writer["workspace_sha"] == review_candidate
    assert reworked_writer["thread_id"] == writer_thread
    assert String.trim(git!(origin, ["rev-parse", "refs/heads/#{delivered["branch"]}"])) == candidate
    assert {:ok, %{launches: [review_verifier]}} = tick(context, worktree)
    refute review_verifier.task_key == verifier_key

    fresh_thread =
      complete_native_stage(reopened_store, review_verifier, fn path ->
        assert String.trim(git!(path, ["rev-parse", "HEAD"])) == review_candidate
        assert String.trim(git!(path, ["rev-parse", "--abbrev-ref", "HEAD"])) == "HEAD"
        %{"status" => "PASS", "candidate_sha" => review_candidate, "findings" => [], "checks" => ["synthetic check"]}
      end)

    refute fresh_thread in [writer_thread, verifier_thread]
    finish(review_verifier)
    assert {:ok, completed_verifier} = TaskLedger.get(reopened_store, review_verifier.task_key)
    assert completed_verifier["status"] == "COMPLETE"
    verifier_requests = Store.query!(reopened_store, completed_requests_sql, [review_verifier.task_key]).rows
    assert length(verifier_requests) == 2
    GenServer.stop(reopened_store)
    {:ok, restored_store} = Store.start_link(database: state.database)
    context = %{context | store: restored_store}
    Process.put(:full_lifecycle_store, restored_store)
    assert {:ok, ^completed_verifier} = TaskLedger.get(restored_store, review_verifier.task_key)
    assert Store.query!(restored_store, completed_requests_sql, [review_verifier.task_key]).rows == verifier_requests
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(restored_store, "DELIVERY") == "REVIEW_PUSHING"
    assert String.trim(git!(origin, ["rev-parse", "refs/heads/#{delivered["branch"]}"])) == candidate
    assert {:ok, %{launches: []}} = tick(context, worktree)
    reviewed = run_for(restored_store, "DELIVERY")
    assert reviewed["state"] == "READY_FOR_REVIEW"
    assert reviewed["mr_url"] == delivered["mr_url"]
    assert reviewed["mr_iid"] == delivered["mr_iid"]
    assert reviewed["candidate_sha"] == review_candidate
    assert String.trim(git!(origin, ["rev-parse", "refs/heads/#{delivered["branch"]}"])) == review_candidate

    assert %{"status" => "PENDING", "reply_phase" => 1} =
             Store.one!(restored_store, "SELECT status, reply_phase FROM mr_feedback_notes WHERE feedback_key = ?", [receipt_key])

    refute_received {:synthetic_mr, _, _}
    assert [[3]] = Store.query!(restored_store, "SELECT COUNT(*) FROM desktop_requests WHERE action = 'CREATE'").rows

    assert [%{"thread_id" => ^writer_thread}] =
             Enum.filter(TaskLedger.list_for_run(restored_store, delivery["run_id"]), &TaskLedger.source_writer?/1)
  end

  test "an approval-blocked writer and CI repair preserve unrelated dispatch and exact verification", state do
    repo = state.context.factory.repositories["grail"]["path"]
    origin = Path.join(state.context.workspace_root, "origin.git")
    initialize_native_repository!(repo, origin)
    Process.put(:full_lifecycle_origin, origin)
    Process.put(:full_lifecycle_ticket, authorized_delivery_ticket("PPL-123"))

    context =
      Map.update!(state.context, :factory, fn factory ->
        factory
        |> Map.put(:task_transport, "desktop_broker")
        |> put_in([:repositories, "grail", "ci_preflight"], "draft_mr")
      end)

    assert %{result: "INITIALIZED"} = Control.initialize(state.store, context.factory)
    assert {:ok, _} = Control.activate(state.store, context.factory, context.factory.dispatcher_id)
    worktree = SymphonyElixir.Factory.Worktree
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: [first]}} = tick(context, worktree)
    writer_thread = complete_native_stage(state.store, first, &native_test_slice(&1, "CONTINUE", "initial"))
    finish(first)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: [denied]}} = tick(context, worktree)
    blocked_request = await_native_request(state.store, denied.task_key)

    complete_native_stage(state.store, denied, fn _path ->
      %{
        "status" => "BLOCKED",
        "summary" => "approval denied",
        "changed_paths" => [],
        "commit_message" => nil,
        "remaining_criteria" => ["AC-1"],
        "blockers" => ["required approval denied"],
        "checks" => []
      }
    end)

    finish(denied)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    failed = run_for(state.store, "DELIVERY")
    assert failed["state"] == "FAILED"
    assert failed["candidate_sha"] != nil
    assert failed["mr_url"] == nil
    assert {:ok, denied_request} = DesktopRequest.get(state.store, blocked_request["request_key"])
    refute_received {:synthetic_mr, _, _}
    assert Enum.all?(TaskLedger.list_for_run(state.store, failed["run_id"]), &(&1["role"] != "change-verifier"))

    Process.put(:additional_lifecycle_tickets, [authorized_delivery_ticket("PPL-124")])
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: [unrelated]}} = tick(context, worktree)
    assert {:ok, unrelated_task} = TaskLedger.get(state.store, unrelated.task_key)
    assert {:ok, unrelated_run} = RunLedger.get(state.store, unrelated_task["run_id"])
    assert unrelated_run["issue_key"] == "PPL-124"
    assert unrelated_run["state"] == "WRITING"
    assert await_native_request(state.store, unrelated.task_key)["action"] == "CREATE"
    assert :ok = Task.Supervisor.terminate_child(context.task_supervisor, unrelated.pid)
    Process.demonitor(unrelated.ref, [:flush])
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(state.store, failed["run_id"])

    assert {:ok, _} = Control.pause(state.store, context.factory, context.factory.dispatcher_id)
    blocked_key = denied_request["request_key"]
    blocked_turn = denied_request["turn_id"]

    assert {:ok, %{result: "BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED"}} =
             Recovery.resume_blocked_native_writer_investigation(state.store, context.factory, blocked_key, blocked_turn)

    Process.put(:full_lifecycle_ticket, Map.put(Process.get(:full_lifecycle_ticket), "labels", ["repo-grail", "ai-running"]))
    assert {:ok, _} = Control.activate(state.store, context.factory, context.factory.dispatcher_id)
    assert {:ok, %{launches: [resumed]}} = tick(context, worktree)
    assert resumed.task_key == first.task_key
    assert complete_native_stage(state.store, resumed, &native_test_slice(&1, "COMPLETE", "approval resolved")) == writer_thread
    finish(resumed)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "CI_PUSHING"
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "CI_WAITING"
    preflight = run_for(state.store, "DELIVERY")
    assert_received {:synthetic_mr, _, _}
    assert Enum.all?(TaskLedger.list_for_run(state.store, failed["run_id"]), &(&1["role"] != "change-verifier"))

    Process.put(:full_lifecycle_ci_statuses, ["REPAIR", "PASS"])
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "REPAIRING"
    assert {:ok, %{launches: [ci_repair]}} = tick(context, worktree)
    assert ci_repair.task_key == first.task_key
    assert complete_native_stage(state.store, ci_repair, &native_test_slice(&1, "COMPLETE", "CI repaired")) == writer_thread
    finish(ci_repair)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    repaired = run_for(state.store, "DELIVERY")
    assert repaired["state"] == "CI_WAITING"
    assert repaired["mr_iid"] == preflight["mr_iid"]
    assert repaired["mr_url"] == preflight["mr_url"]
    refute repaired["candidate_sha"] == preflight["candidate_sha"]
    assert_received {:synthetic_mr, _, _}
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "VERIFYING"
    candidate = run_for(state.store, "DELIVERY")["candidate_sha"]
    assert {:ok, %{launches: [verifier]}} = tick(context, worktree)
    request = await_native_request(state.store, verifier.task_key)
    complete_native_bootstrap(state.store, request)
    request = await_native_request(state.store, verifier.task_key)
    assert request["action"] == "FOLLOWUP"
    assert request["prompt"] =~ candidate
    assert request["prompt"] =~ "bazel"

    complete_native_stage(state.store, verifier, fn path ->
      assert String.trim(git!(path, ["rev-parse", "HEAD"])) == candidate
      %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => ["CI bazel passed"]}
    end)

    finish(verifier)
    assert {:ok, %{launches: []}} = tick(context, worktree)
    assert state_for(state.store, "DELIVERY") == "MR_CREATING"
    assert {:ok, %{launches: []}} = tick(context, worktree)
    delivered = run_for(state.store, "DELIVERY")
    assert delivered["state"] == "READY_FOR_REVIEW"
    assert delivered["mr_iid"] == preflight["mr_iid"]
    assert delivered["mr_url"] == preflight["mr_url"]
    assert delivered["candidate_sha"] == candidate
    assert delivered["ci_preflight_sha"] == candidate
    assert delivered["ci_pipeline_id"] == 100
    assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(state.store, unrelated_run["run_id"])
  end

  test "a concurrent Jira label change blocks the native write without overwriting it", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    Process.put(:jira_connector_override_labels, ["repo-grail", "spec-needed", "human-hold"])
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "stale-jira-labels",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ticket)
             })

    assert {:ok, %{launches: []}} = tick(context)

    assert {:ok, %{"state" => "FAILED", "failure_code" => ":jira_write_stale_labels"}} =
             RunLedger.get(state.store, run["run_id"])

    refute_received {:synthetic_jira_comment, _, _}
    refute_received {:synthetic_jira_labels, _, _}
    assert Process.get(:full_lifecycle_ticket) == ticket
  end

  test "a native spec write resumes after an uncertain comment without duplicating it", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    original = Process.get(:full_lifecycle_ticket)
    comment = Contract.draft_comment(contract)
    ticket = Map.put(original, "comments", [%{"id" => "42", "text" => comment}])
    Process.put(:full_lifecycle_ticket, ticket)
    Process.put(:forbid_controller_jira_write, true)
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "uncertain-jira-comment",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(original)
             })

    assert {:ok, %{launches: []}} = tick(context)

    assert {:ok, %{"state" => "SPEC_REVIEW", "spec_comment_id" => "42"}} =
             RunLedger.get(state.store, run["run_id"])

    refute_received {:synthetic_jira_comment, _, _}
    assert Process.get(:full_lifecycle_ticket) == ticket
  end

  test "a ticket closed after intake cannot receive a native specification comment", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    Process.put(:jira_connector_override_status, "DONE")
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "closed-after-intake",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ticket)
             })

    assert {:ok, %{launches: []}} = tick(context)

    assert {:ok, %{"state" => "FAILED", "failure_code" => ":jira_write_stale_status"}} =
             RunLedger.get(state.store, run["run_id"])

    refute_received {:synthetic_jira_comment, _, _}
    refute_received {:synthetic_jira_labels, _, _}
    assert Process.get(:full_lifecycle_ticket) == ticket
  end

  test "a native spec write accepts the Jira MCP result envelope and proves the comment", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    Process.put(:forbid_controller_jira_write, true)
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "mcp-envelope",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ticket)
             })

    assert {:ok, %{launches: []}} =
             Scheduler.tick(context,
               controller_task: Controller,
               jira_reader: JiraReader,
               jira_connector: JiraMcpConnector,
               jira_app_server: FakeMcpAppServer,
               task_launcher: Launcher,
               cleanup: Cleanup,
               worktree: Worktree
             )

    assert {:ok, %{"state" => "SPEC_REVIEW", "spec_comment_id" => "1"}} =
             RunLedger.get(state.store, run["run_id"])

    assert_received {:mcp_jira_comment, "PPL-123", body}
    assert body == Contract.draft_comment(contract)
    assert Process.get(:full_lifecycle_ticket)["comments"] == [%{"id" => "1", "text" => body}]
  end

  test "an error-marked Jira MCP issue cannot authorize a native comment", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    Process.put(:mcp_jira_issue_error, true)
    Process.put(:forbid_controller_jira_write, true)
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "mcp-error-envelope",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ticket)
             })

    assert {:ok, %{launches: []}} =
             Scheduler.tick(context,
               controller_task: Controller,
               jira_reader: JiraReader,
               jira_connector: JiraMcpConnector,
               jira_app_server: FakeMcpAppServer,
               task_launcher: Launcher,
               cleanup: Cleanup,
               worktree: Worktree
             )

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(state.store, run["run_id"])
    refute_received {:mcp_jira_comment, _, _}
    assert Process.get(:full_lifecycle_ticket) == ticket
  end

  test "a native Jira write crosses the offline app-server protocol without a persistent task", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    Process.put(:mcp_shell_trace, state.trace)
    Process.put(:mcp_shell_comment, Contract.draft_comment(contract))
    Process.put(:forbid_controller_jira_write, true)
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))
    fake_command = Path.join(Path.dirname(state.trace), "fake-codex") <> " app-server"
    assert SymphonyElixir.Config.settings!().codex.command == fake_command

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "mcp-protocol",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ticket)
             })

    assert {:ok, %{launches: []}} =
             Scheduler.tick(context,
               controller_task: Controller,
               jira_reader: JiraReader,
               jira_connector: JiraMcpConnector,
               jira_app_server: SymphonyElixir.Codex.AppServer,
               task_launcher: Launcher,
               cleanup: Cleanup,
               worktree: Worktree
             )

    assert {:ok, %{"state" => "SPEC_REVIEW", "spec_comment_id" => "1"}} =
             RunLedger.get(state.store, run["run_id"])

    calls = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    mcp_calls = Enum.filter(calls, &(&1["method"] == "mcpServer/tool/call"))
    assert Enum.count(mcp_calls, &(get_in(&1, ["params", "tool"]) == "jira_add_comment")) == 1
    assert Enum.count(mcp_calls, &(get_in(&1, ["params", "tool"]) == "jira_get_issue")) == 2

    assert Enum.all?(mcp_calls, fn call ->
             get_in(call, ["params", "tool"]) != "jira_get_issue" or
               get_in(call, ["params", "arguments", "comment_limit"]) <= 100
           end)

    assert Enum.all?(Enum.filter(calls, &(&1["method"] == "thread/start")), &(get_in(&1, ["params", "ephemeral"]) == true))
    refute Enum.any?(calls, &(&1["method"] == "turn/start"))
  end

  test "a Jira MCP approval request leaves the native ticket unchanged", state do
    contract = Contract.bind("PPL-123", 1, author_output()["contract_markdown"])
    ticket = Process.get(:full_lifecycle_ticket)
    Process.put(:forbid_controller_jira_write, true)
    File.touch!(state.trace <> ".approval")
    context = Map.update!(state.context, :factory, &Map.put(&1, :task_transport, "desktop_broker"))
    fake_command = Path.join(Path.dirname(state.trace), "fake-codex") <> " app-server"
    assert SymphonyElixir.Config.settings!().codex.command == fake_command

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "mcp-approval",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               runtime: "codex-desktop-broker",
               factory_owned: 0,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ticket)
             })

    assert {:ok, %{launches: []}} =
             Scheduler.tick(context,
               controller_task: Controller,
               jira_reader: JiraReader,
               jira_connector: JiraMcpConnector,
               jira_app_server: SymphonyElixir.Codex.AppServer,
               task_launcher: Launcher,
               cleanup: Cleanup,
               worktree: Worktree
             )

    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(state.store, run["run_id"])
    assert Process.get(:full_lifecycle_ticket) == ticket
    calls = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    refute Enum.any?(calls, &(&1["id"] == 99))
    refute Enum.any?(calls, &(&1["method"] == "turn/start"))
  end

  test "an invalid specification output cannot authorize or deliver the ticket", state do
    File.touch!(state.trace <> ".invalid-author")

    assert {:ok, %{launches: [author]}} = tick(state.context)
    task_key = author.task_key
    assert_receive {:factory_task_started, ^task_key, _thread_id}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:error, :factory_stage_output_schema_mismatch}}, 5_000
    Process.demonitor(author.ref, [:flush])

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "SPECIFICATION") == "FAILED"

    ticket = Process.get(:full_lifecycle_ticket)
    refute "ai-ready" in ticket["labels"]
    assert "ai-blocked" in ticket["labels"]
    refute Enum.any?(ticket["comments"], &String.contains?(&1["text"], "AI FACTORY CONTRACT BEGIN"))
    refute run_for(state.store, "DELIVERY")

    calls = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(calls, &(&1["method"] == "thread/start")) == 1
    assert Enum.count(calls, &(&1["method"] == "turn/start")) == 2
    refute Enum.any?(calls, &(&1["method"] == "thread/fork"))
  end

  test "an active writer refusal waits on the same task and gates delivery until retry succeeds", state do
    markdown =
      "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"

    contract = Contract.bind("PPL-123", 1, markdown)

    authorized_ticket =
      ticket()
      |> Map.put("labels", ["repo-grail", "ai-running"])
      |> Map.put("comments", [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
        %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
      ])

    Process.put(:full_lifecycle_ticket, authorized_ticket)
    writer_path = Path.join(state.context.workspace_root, "writer")
    File.mkdir_p!(writer_path)

    assert {:ok, %{run: run}} =
             RunLedger.register(state.store, %{
               run_id: "writer-conflict",
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
               worktree: writer_path,
               branch: "cgable/PPL-123-factory-work",
               plan_markdown: "Implement AC-1",
               snapshot_json: Jason.encode!(authorized_ticket),
               workspace_state: "MATERIALIZED"
             })

    assert {:ok, %{launches: [first]}} = tick(state.context)
    finish(first)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert %{state: "WRITING", iteration: 1} = delivery_state(state.store)

    task_key = first.task_key
    assert {:ok, %{"thread_id" => writer_id}} = TaskLedger.get(state.store, task_key)
    File.touch!(state.trace <> ".active-writer")

    assert {:ok, %{launches: [refused]}} = tick(state.context)
    assert refused.task_key == task_key

    assert_receive {:factory_task_finished, ^task_key, {:error, {:response_error, %{"message" => message}}}}, 5_000
    assert message =~ "active writer"
    Process.demonitor(refused.ref, [:flush])

    assert {:ok, %{"status" => "WAITING_FOR_WRITER", "thread_id" => ^writer_id}} =
             TaskLedger.get(state.store, task_key)

    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "WRITING"
    refute_received {:synthetic_push, _, _}
    refute_received {:synthetic_mr, _, _}

    Store.query!(state.store, "UPDATE factory_tasks SET updated_at = ? WHERE task_key = ?", [
      "2020-01-01T00:00:00Z",
      task_key
    ])

    File.rm!(state.trace <> ".active-writer")
    assert {:ok, %{launches: [retry]}} = tick(state.context)
    assert retry.task_key == task_key
    finish(retry)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "VERIFYING"

    assert {:ok, %{launches: [verifier]}} = tick(state.context)
    finish(verifier)
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "PUSHING"
    assert {:ok, %{launches: []}} = tick(state.context)
    assert state_for(state.store, "DELIVERY") == "READY_FOR_REVIEW"
    assert_received {:synthetic_push, _, @candidate}
    assert_received {:synthetic_mr, _, @candidate}

    calls = state.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(calls, &(&1["method"] == "thread/start")) == 2

    resumes = Enum.filter(calls, &(&1["method"] == "thread/resume"))
    assert length(resumes) == 2
    assert Enum.all?(resumes, &(get_in(&1, ["params", "threadId"]) == writer_id))
    refute Enum.any?(calls, &(&1["method"] == "thread/fork"))
    assert [%{"thread_id" => ^writer_id}] = Enum.filter(TaskLedger.list_for_run(state.store, run["run_id"]), &(&1["role"] == "feature-writer"))
  end

  defp ticket do
    %{
      "id" => "100",
      "key" => "PPL-123",
      "summary" => "Factory work",
      "description" => "A scoped Jira ticket awaiting a delivery contract",
      "status" => "TO DO",
      "labels" => ["repo-grail", "spec-needed"],
      "assignee" => "cgable",
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => ["doc-extract"],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-09-23T00:00:00Z",
      "comments" => []
    }
  end

  defp tick(context, worktree \\ Worktree) do
    Scheduler.tick(context,
      controller_task: Controller,
      jira_reader: JiraReader,
      jira_connector: JiraConnector,
      gitlab_reader: GitlabReader,
      task_launcher: Launcher,
      cleanup: Cleanup,
      worktree: worktree
    )
  end

  defp finish(launch) do
    task_key = launch.task_key
    assert_receive {:factory_task_started, ^task_key, _thread_id}, 5_000
    assert_receive {:factory_task_finished, ^task_key, {:ok, _result}}, 5_000
    Process.demonitor(launch.ref, [:flush])
  end

  defp classify_review_edit(store, context, run, route, mr, discussion, note) do
    jira = Process.get(:full_lifecycle_ticket)
    assert {:ok, candidate} = MrFeedback.candidate(run, route, jira, mr, discussion, note, [11_599_766], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(store, candidate)
    key = "feedback-classification:#{candidate.feedback_key}"
    Control.record_controller_task(store, context.factory, "feedback-controller", "previous-feedback-turn", %{project_id: "projectless"})

    assert {:ok, _} =
             DesktopRequest.enqueue(store, %{
               request_key: key,
               target_kind: "CONTROLLER",
               target_key: context.factory.scope,
               action: "FOLLOWUP",
               existing_thread_id: "feedback-controller",
               codex_project_id: "projectless",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               title: "Classify review edit",
               prompt: "Classify the explicit review edit",
               cwd: context.workspace_root,
               schema: StageSchemas.for_stage(:gitlab_feedback_reply)
             })

    assert {:ok, _} = MrFeedbackLedger.claim(store, candidate.feedback_key, key, "previous-feedback-turn")
    assert {:ok, _} = DesktopRequest.claim(store, key)
    assert {:ok, _} = DesktopRequest.record_thread(store, key, "feedback-controller", "projectless")

    assert {:ok, _} =
             DesktopRequest.complete(store, key, %{
               thread_id: "feedback-controller",
               turn_id: "feedback-classified",
               output: %{
                 "result" => %{
                   "status" => "CHANGE_REQUEST",
                   "feedback_key" => candidate.feedback_key,
                   "reply_id" => nil,
                   "reply_body" => nil,
                   "reason" => "explicit edit"
                 },
                 "completed_tool_calls" => []
               }
             })

    assert :ok = MrFeedbackLedger.finish(store, candidate.feedback_key, key, "CHANGE_REQUEST", nil, "explicit edit")
    candidate.feedback_key
  end

  defp authorized_delivery_ticket(issue_key) do
    contract = Contract.bind(issue_key, 1, author_output()["contract_markdown"])

    ticket()
    |> Map.put("key", issue_key)
    |> Map.put("labels", ["repo-grail", "ai-ready"])
    |> Map.put("comments", [
      %{"id" => "1", "text" => Contract.draft_comment(contract)},
      %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
      %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
    ])
  end

  defp native_test_slice(path, status, text) do
    File.write!(Path.join(path, "feature.txt"), text <> "\n")

    %{
      "status" => status,
      "summary" => text,
      "changed_paths" => ["feature.txt"],
      "commit_message" => "fix(PPL-123): #{text}",
      "remaining_criteria" => if(status == "CONTINUE", do: ["AC-1"], else: []),
      "blockers" => [],
      "checks" => ["synthetic check"]
    }
  end

  defp run_for(store, kind), do: Enum.find(RunLedger.list(store), &(&1["kind"] == kind))
  defp state_for(store, kind), do: run_for(store, kind)["state"]

  defp delivery_state(store) do
    run = run_for(store, "DELIVERY")
    %{state: run["state"], iteration: run["implementation_iteration"]}
  end

  defp author_output do
    %{
      "status" => "DRAFTED",
      "contract_markdown" => "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    }
  end

  defp complete_native_stage(store, launch, output) do
    task_key = launch.task_key
    request = await_native_request(store, task_key)

    {request, thread_id, path} =
      if request["action"] == "CREATE" do
        {thread_id, path} = complete_native_bootstrap(store, request)
        {await_native_request(store, task_key), thread_id, path}
      else
        {:ok, task} = TaskLedger.get(store, task_key)
        {request, task["thread_id"], task["workspace"]}
      end

    assert request["action"] == "FOLLOWUP"
    assert request["existing_thread_id"] == thread_id
    assert request["codex_project_id"] == "project-grail"
    assert {:ok, canonical_path} = SymphonyElixir.PathSafety.canonicalize(path)
    assert request["cwd"] == canonical_path
    assert {:ok, _claimed} = DesktopRequest.claim(store, request["request_key"])

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, request["request_key"], thread_id, "project-grail", %{
               cwd: path,
               head_sha: String.trim(git!(path, ["rev-parse", "HEAD"]))
             })

    if String.ends_with?(task_key, ":specification-author") do
      metadata = Jason.decode!(request["metadata_json"])
      assert metadata["format_repair_attempts"] == 1

      assert {:error, :factory_stage_output_schema_mismatch} =
               DesktopRequest.complete(store, request["request_key"], %{
                 thread_id: thread_id,
                 turn_id: "malformed-#{task_key}",
                 output: %{"result" => %{"status" => "DRAFTED"}, "completed_tool_calls" => []}
               })

      assert {:ok, %{"status" => "THREAD_RECORDED"}} = DesktopRequest.get(store, request["request_key"])
    end

    assert {:ok, _completed} =
             DesktopRequest.complete(store, request["request_key"], %{
               thread_id: thread_id,
               turn_id: "stage-#{System.unique_integer([:positive])}",
               output: %{"result" => output.(path), "completed_tool_calls" => []}
             })

    thread_id
  end

  defp complete_native_bootstrap(store, request) do
    assert String.ends_with?(request["request_key"], ":bootstrap")
    metadata = Jason.decode!(request["metadata_json"])
    sha = metadata["expected_sha"]
    assert {:ok, create_arguments} = DesktopToolArgs.create_thread(store, request["request_key"])
    refute Map.has_key?(create_arguments, "projectId")
    assert get_in(create_arguments, ["target", "projectId"]) == "project-grail"
    assert get_in(create_arguments, ["target", "environment", "startingState", "branchName"]) == sha
    path = Path.join(Path.dirname(request["cwd"]), "native-#{System.unique_integer([:positive])}")
    git!(request["cwd"], ["worktree", "add", "--detach", path, sha])
    thread_id = "thread-#{request["target_key"]}"
    assert {:ok, _claimed} = DesktopRequest.claim(store, request["request_key"])

    assert {:ok, _recorded} =
             DesktopRequest.record_thread(store, request["request_key"], thread_id, "project-grail", %{cwd: path, head_sha: sha})

    assert {:ok, _completed} =
             DesktopRequest.complete(store, request["request_key"], %{
               thread_id: thread_id,
               turn_id: "bootstrap-#{request["target_key"]}",
               output: %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []}
             })

    {thread_id, path}
  end

  defp await_native_request(store, task_key, attempts \\ 200)
  defp await_native_request(_store, task_key, 0), do: flunk("no pending native request for #{task_key}")

  defp await_native_request(store, task_key, attempts) do
    case Enum.find(DesktopRequest.list_pending(store), &(&1["target_key"] == task_key)) do
      nil ->
        Process.sleep(10)
        await_native_request(store, task_key, attempts - 1)

      request ->
        request
    end
  end

  defp initialize_native_repository!(repo, origin) do
    git!(Path.dirname(repo), ["init", "--bare", origin])
    git!(repo, ["init", "-b", "master"])
    git!(repo, ["config", "user.email", "factory@example.test"])
    git!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "--no-verify", "-m", "base"])
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "--no-verify", "origin", "master"])
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end

  defp fake_codex_script(trace, repo) do
    contract =
      "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"

    initial_ticket = ticket()
    final_ticket = Map.put(initial_ticket, "comments", [%{"id" => "1", "text" => Contract.draft_comment(Contract.bind("PPL-123", 1, contract))}])
    initial_issue_response = Jason.encode!(%{"id" => 14, "result" => %{"content" => [], "structuredContent" => %{"result" => Jason.encode!(initial_ticket)}}})
    final_issue_response = Jason.encode!(%{"id" => 14, "result" => %{"content" => [], "structuredContent" => %{"result" => Jason.encode!(final_ticket)}}})

    outputs = %{
      "Specification Author" => %{
        "status" => "DRAFTED",
        "contract_markdown" => contract,
        "questions" => [],
        "risk" => "low",
        "risk_signals" => [],
        "manual_validation_required" => false
      },
      "Specification Critic" => %{"status" => "PASS", "findings" => [], "required_questions" => []},
      "Feature Planner" => %{"status" => "PLANNED", "plan_markdown" => "Implement AC-1", "blockers" => []},
      "Feature Writer Continue" => %{
        "status" => "CONTINUE",
        "summary" => "first coherent slice",
        "commit_sha" => @candidate,
        "remaining_criteria" => ["AC-1"],
        "blockers" => [],
        "checks" => ["unit tests passed"]
      },
      "Feature Writer Complete" => %{
        "status" => "COMPLETE",
        "summary" => "second coherent slice",
        "commit_sha" => @candidate,
        "remaining_criteria" => [],
        "blockers" => [],
        "checks" => ["unit tests passed"]
      },
      "Change Verifier" => %{"status" => "PASS", "candidate_sha" => @candidate, "findings" => [], "checks" => ["unit tests passed"]}
    }

    invalid_author_event =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "agentMessage", "phase" => "final_answer", "text" => ~s({"status":"DRAFTED"})}}
      })

    events =
      Map.new(outputs, fn {key, output} ->
        {key, Jason.encode!(%{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "phase" => "final_answer", "text" => Jason.encode!(output)}}})}
      end)

    """
    #!/bin/sh
    role=''
    thread_id=''
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "#{trace}"
      case "$line" in
        *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"method":"project/list"'*) printf '%s\n' '{"id":12,"result":{"data":[{"id":"project-grail","roots":[{"path":"#{repo}"}]}],"nextCursor":null}}' ;;
        *'"method":"thread/start"'*)
          starts=$(grep -c '"method":"thread/start"' "#{trace}")
          thread_id="thread-$starts"
          printf '%s\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"Jira","status":"ready"}}'
          printf '{"id":2,"result":{"thread":{"id":"%s"}}}\n' "$thread_id"
          ;;
        *'"method":"mcpServer/tool/call"'*)
          case "$line" in
            *'"tool":"jira_get_issue"'*)
              if grep -q '"tool":"jira_add_comment"' "#{trace}"; then
                printf '%s\n' '#{final_issue_response}'
              else
                printf '%s\n' '#{initial_issue_response}'
              fi
              ;;
            *'"tool":"jira_add_comment"'*)
              if [ -f '#{trace}.approval' ]; then
                printf '%s\n' '{"id":99,"method":"tool/requestUserInput","params":{"questions":[]}}'
              else
                printf '%s\n' '{"id":14,"result":{"content":[{"type":"text","text":"comment added"}]}}'
              fi
              ;;
          esac
          ;;
        *'"method":"thread/resume"'*)
          thread_id=$(printf '%s\n' "$line" | awk -F '"threadId":"' '{print $2}' | cut -d '"' -f 1)
          if [ -f '#{trace}.active-writer' ]; then
            printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"thread already has an active writer"}}'
          else
            printf '{"id":2,"result":{"thread":{"id":"%s"}}}\n' "$thread_id"
          fi
          ;;
        *'"method":"thread/name/set"'*)
          case "$line" in
            *'Specification Author'*) role='Specification Author' ;;
            *'Specification Critic'*) role='Specification Critic' ;;
            *'Feature Planner'*) role='Feature Planner' ;;
            *'Feature Writer'*) role='Feature Writer' ;;
            *'Change Verifier'*) role='Change Verifier' ;;
          esac
          printf '%s\n' '{"id":4,"result":{}}'
          ;;
        *'"method":"thread/metadata/update"'*) printf '{"id":7,"result":{"thread":{"id":"%s","projectId":"project-grail"}}}\n' "$thread_id" ;;
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
          case "$role" in
            'Specification Author')
              if [ -f '#{trace}.invalid-author' ]; then
                printf '%s\n' '#{invalid_author_event}'
              else
                printf '%s\n' '#{events["Specification Author"]}'
              fi
              ;;
            'Specification Critic') printf '%s\n' '#{events["Specification Critic"]}' ;;
            'Feature Planner') printf '%s\n' '#{events["Feature Planner"]}' ;;
            'Feature Writer')
              if [ -f '#{trace}.writer-count' ]; then writer_count=$(cat '#{trace}.writer-count'); else writer_count=0; fi
              writer_count=$((writer_count + 1))
              printf '%s\n' "$writer_count" > '#{trace}.writer-count'
              if [ "$writer_count" -eq 1 ]; then
                printf '%s\n' '#{events["Feature Writer Continue"]}'
              else
                printf '%s\n' '#{events["Feature Writer Complete"]}'
              fi
              ;;
            'Change Verifier') printf '%s\n' '#{events["Change Verifier"]}' ;;
          esac
          printf '%s\n' '{"method":"turn/completed"}'
          ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
    done
    """
  end
end
