defmodule SymphonyElixir.FactoryCleanupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Cleanup, RunLedger, Scheduler, Store, Worktree}

  defmodule SweepController do
    def run(_factory, _workspace, _issue, _prompt, schema, _opts) do
      if Map.has_key?(schema["properties"], "snapshot_json") do
        {:ok, %{"status" => "PASS", "snapshot_json" => "[]"}}
      else
        {:ok,
         %{
           "status" => "PASS",
           "candidates" => [%{"run_id" => "run-cleanup", "issue_key" => "PPL-123", "jira_status" => "DONE", "mr_state" => "opened"}]
         }}
      end
    end
  end

  defmodule SweepCleanup do
    alias SymphonyElixir.Factory.Cleanup

    defdelegate authorization_candidates(store, policy, repo_key), to: Cleanup
    defdelegate authorize(store, policy, run_id, jira_status, mr_state), to: Cleanup

    def apply(store, policy, run_id, opts) do
      runner = fn _executable, args, _opts ->
        send(self(), {:scheduler_reclaim, args})
        {Jason.encode!(%{"reclaimed_bytes" => 123}), 0}
      end

      failure = fn boundary ->
        if boundary == Process.get(:scheduler_cleanup_failure), do: {:error, :injected_crash}, else: :ok
      end

      Cleanup.apply(store, policy, run_id, opts ++ [command_runner: runner, failure_injector: failure])
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "factory-cleanup-#{System.unique_integer([:positive])}")
    bare = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    workspace_root = Path.join(root, "workspaces")
    database = Path.join(root, "factory.sqlite")
    File.mkdir_p!(root)

    cmd!(root, ["init", "--bare", bare])
    cmd!(root, ["clone", bare, repo])
    cmd!(repo, ["config", "user.email", "factory@example.test"])
    cmd!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    cmd!(repo, ["add", "README.md"])
    cmd!(repo, ["commit", "-m", "base"])
    cmd!(repo, ["branch", "-M", "master"])
    cmd!(repo, ["push", "origin", "master"])
    cmd!(repo, ["fetch", "origin"])

    route = %{
      "path" => repo,
      "base_branch" => "master",
      "gitlab_project" => "example/repo",
      "workspace_root" => workspace_root
    }

    {:ok, writer} = Worktree.ensure_writer(route, "PPL-123", "run-cleanup")
    File.write!(Path.join(writer.path, "feature.txt"), "done\n")
    cmd!(writer.path, ["add", "feature.txt"])
    cmd!(writer.path, ["commit", "--no-verify", "-m", "PPL-123: done"])
    {:ok, candidate} = Worktree.candidate(writer.path, "master")
    {:ok, _pushed} = Worktree.push_exact(route, writer.path, writer.branch, candidate)
    cmd!(repo, ["fetch", "origin"])

    {:ok, store} = Store.start_link(database: database)

    {:ok, _run} =
      RunLedger.register(store, %{
        run_id: "run-cleanup",
        issue_key: "PPL-123",
        kind: "DELIVERY",
        state: "READY_FOR_REVIEW",
        repo_key: "grail",
        repo_path: repo,
        base_branch: "master",
        worktree: writer.path,
        branch: writer.branch,
        candidate_sha: candidate,
        mr_state: "opened"
      })

    policy = %{
      "cleanup" => %{
        "enabled" => true,
        "authorization_max_age_minutes" => 60,
        "allowed_jira_statuses" => ["DONE", "IN TESTING", "TESTING"],
        "allowed_mr_states" => ["merged"],
        "allowed_run_states" => ["READY_FOR_REVIEW", "DELIVERED"],
        "allowed_worktree_roots" => [workspace_root],
        "reclaim_script" => "/fake/reclaim.py"
      }
    }

    on_exit(fn -> File.rm_rf(root) end)

    %{
      store: store,
      database: database,
      policy: policy,
      writer: writer,
      route: route,
      repo: repo,
      candidate: candidate,
      workspace_root: workspace_root
    }
  end

  test "hibernates a published writer, retains its local branch, and rehydrates it", context do
    policy =
      Map.put(context.policy, "hibernation", %{
        "enabled" => true,
        "allowed_run_states" => ["READY_FOR_REVIEW"],
        "reclaim_script" => "/fake/reclaim.py"
      })

    command_runner = fn _executable, _args, _opts ->
      {Jason.encode!(%{"reclaimed_bytes" => 456}), 0}
    end

    assert {:ok, %{result: "HIBERNATED", branch: branch}} =
             Cleanup.hibernate(context.store, policy, "run-cleanup",
               command_runner: command_runner,
               active_workspace: context.workspace_root
             )

    refute File.exists?(context.writer.path)
    assert String.trim(cmd!(context.repo, ["rev-parse", "refs/heads/#{branch}"])) == context.candidate

    assert {:ok, %{"workspace_state" => "HIBERNATED", "hibernated_at" => hibernated_at}} =
             RunLedger.get(context.store, "run-cleanup")

    assert is_binary(hibernated_at)

    rehydrate_route =
      context.route
      |> Map.put("branch", branch)
      |> Map.put("expected_sha", context.candidate)

    assert {:ok, rehydrated} = Worktree.ensure_writer(rehydrate_route, "PPL-123", "run-cleanup")
    assert rehydrated.path == context.writer.path
    assert rehydrated.head == context.candidate
  end

  test "refuses to hibernate dirty writer state", context do
    policy =
      Map.put(context.policy, "hibernation", %{
        "enabled" => true,
        "allowed_run_states" => ["READY_FOR_REVIEW"],
        "reclaim_script" => "/fake/reclaim.py"
      })

    File.write!(Path.join(context.writer.path, "preserve-me.txt"), "uncommitted\n")

    assert {:error, :hibernation_worktree_dirty} =
             Cleanup.hibernate(context.store, policy, "run-cleanup", active_workspace: context.workspace_root)

    assert File.dir?(context.writer.path)
    assert File.read!(Path.join(context.writer.path, "preserve-me.txt")) == "uncommitted\n"
  end

  test "removes only a freshly authorized, clean, remotely recoverable terminal worktree", context do
    assert {:ok, authorized} =
             Cleanup.authorize(context.store, context.policy, "run-cleanup", "DONE", "opened")

    assert authorized["cleanup_authorized"] == 1
    assert %{eligible: true} = Cleanup.preflight(context.store, context.policy, authorized)

    parent = self()

    command_runner = fn executable, args, _opts ->
      send(parent, {:reclaim, executable, args})
      {Jason.encode!(%{"reclaimed_bytes" => 123}), 0}
    end

    assert {:ok, %{result: "CLEANED"}} =
             Cleanup.apply(context.store, context.policy, "run-cleanup",
               command_runner: command_runner,
               active_workspace: context.workspace_root
             )

    refute File.exists?(context.writer.path)
    assert_received {:reclaim, "python3", args}
    assert "--bazel-for-sources" in args
    assert context.writer.path in args
  end

  test "dirty terminal work remains protected", context do
    File.write!(Path.join(context.writer.path, "untracked.txt"), "preserve\n")
    assert {:ok, authorized} = Cleanup.authorize(context.store, context.policy, "run-cleanup", "TESTING", nil)
    assert %{eligible: false, reasons: reasons} = Cleanup.preflight(context.store, context.policy, authorized)
    assert "worktree is dirty or has untracked files" in reasons
  end

  test "Jira In Review can authorize a clean published candidate when explicitly configured", context do
    policy =
      put_in(context.policy, ["cleanup", "allowed_jira_statuses"], ["IN REVIEW", "IN TESTING", "DONE"])

    assert {:error, :external_state_not_terminal} =
             Cleanup.authorize(context.store, policy, "run-cleanup", "In Dev", "opened")

    assert {:error, :external_state_not_terminal} =
             Cleanup.authorize(context.store, policy, "run-cleanup", "ai-review", "opened")

    assert {:ok, authorized} =
             Cleanup.authorize(context.store, policy, "run-cleanup", "In Review", "opened")

    assert %{eligible: true} = Cleanup.preflight(context.store, policy, authorized)
  end

  test "resumes after worktree removal without attempting removal again", context do
    assert {:ok, _} = Cleanup.authorize(context.store, context.policy, "run-cleanup", "DONE", "opened")

    fail = fn
      :after_worktree_remove -> {:error, :injected_crash}
      _boundary -> :ok
    end

    assert {:error, :injected_crash} =
             Cleanup.apply(context.store, context.policy, "run-cleanup",
               command_runner: fn _executable, _args, _opts ->
                 {Jason.encode!(%{"reclaimed_bytes" => 0}), 0}
               end,
               failure_injector: fail,
               active_workspace: context.workspace_root
             )

    refute File.exists?(context.writer.path)

    assert {:ok, %{result: "CLEANED"}} =
             Cleanup.apply(context.store, context.policy, "run-cleanup",
               command_runner: fn _executable, _args, _opts ->
                 {Jason.encode!(%{"reclaimed_bytes" => 0}), 0}
               end,
               active_workspace: context.workspace_root
             )

    assert {:ok, run} = RunLedger.get(context.store, "run-cleanup")
    assert run["cleaned_at"]
  end

  test "resumes after Bazel reclamation and before the ledger update", context do
    assert {:ok, _} = Cleanup.authorize(context.store, context.policy, "run-cleanup", "DONE", "opened")
    parent = self()

    runner = fn _executable, args, _opts ->
      send(parent, {:reclaim, args})
      {Jason.encode!(%{"reclaimed_bytes" => 123}), 0}
    end

    fail = fn
      :before_ledger_update -> {:error, :injected_ledger_failure}
      _boundary -> :ok
    end

    assert {:error, :injected_ledger_failure} =
             Cleanup.apply(context.store, context.policy, "run-cleanup",
               command_runner: runner,
               failure_injector: fail,
               active_workspace: context.workspace_root
             )

    assert_received {:reclaim, _args}
    assert {:ok, run} = RunLedger.get(context.store, "run-cleanup")
    assert is_nil(run["cleaned_at"])

    assert {:ok, %{result: "CLEANED"}} =
             Cleanup.apply(context.store, context.policy, "run-cleanup",
               command_runner: runner,
               active_workspace: context.workspace_root
             )

    refute_received {:reclaim, _args}
    assert {:ok, run} = RunLedger.get(context.store, "run-cleanup")
    assert run["cleaned_at"]
  end

  test "lists only complete terminal identities for fresh external authorization", context do
    assert [candidate] = Cleanup.authorization_candidates(context.store, context.policy, "grail")
    assert candidate["run_id"] == "run-cleanup"
    assert candidate["issue_key"] == "PPL-123"
    assert candidate["candidate_sha"]

    assert [] == Cleanup.authorization_candidates(context.store, context.policy, "other")
  end

  test "scheduler cleanup protects dirty live and unpublished work then resumes removal across SQLite reopen", context do
    scope = "cleanup-sweep"

    factory = %{
      scope: scope,
      dispatcher_id: "dispatcher-1",
      queue: %{"assignee" => "currentUser()", "statuses" => ["READY"], "factory_labels" => ["ai-ready"], "projects" => [], "epics" => []},
      repositories: %{"grail" => context.route},
      cleanup: context.policy["cleanup"],
      hibernation: %{},
      review_feedback: %{"enabled" => false},
      maximum_specifiers: 1,
      maximum_writers: 1,
      maximum_validators: 1,
      writer_disk_gb: 1,
      stale_task_minutes: 90
    }

    scheduler = %{factory: factory, store: context.store, workspace_root: context.workspace_root, control_server: self()}
    tick = fn scheduler -> Scheduler.tick(scheduler, controller_task: SweepController, cleanup: SweepCleanup) end
    dirty = Path.join(context.writer.path, "preserve.txt")
    File.write!(dirty, "uncommitted\n")
    assert {:ok, %{launches: []}} = tick.(scheduler)
    assert File.read!(dirty) == "uncommitted\n"
    refute_received {:scheduler_reclaim, _}
    File.rm!(dirty)

    live = Path.join([context.workspace_root, "factory-controller", scope])
    File.rmdir!(live)
    cmd!(context.repo, ["worktree", "move", context.writer.path, live])
    assert {:ok, _} = RunLedger.update(context.store, "run-cleanup", %{worktree: live})
    assert {:ok, %{launches: []}} = tick.(scheduler)
    assert File.exists?(Path.join(live, "feature.txt"))
    assert {:ok, live_run} = RunLedger.get(context.store, "run-cleanup")

    assert %{eligible: false, reasons: ["worktree is the live workspace"]} =
             Cleanup.preflight(context.store, context.policy, live_run, active_workspace: live)

    refute_received {:scheduler_reclaim, _}
    cmd!(context.repo, ["worktree", "move", live, context.writer.path])
    assert {:ok, _} = RunLedger.update(context.store, "run-cleanup", %{worktree: context.writer.path})

    File.write!(Path.join(context.writer.path, "unpublished.txt"), "local only\n")
    cmd!(context.writer.path, ["add", "unpublished.txt"])
    cmd!(context.writer.path, ["commit", "--no-verify", "-m", "local candidate"])
    candidate = String.trim(cmd!(context.writer.path, ["rev-parse", "HEAD"]))
    assert {:ok, _} = RunLedger.update(context.store, "run-cleanup", %{candidate_sha: candidate})
    assert {:ok, %{launches: []}} = tick.(scheduler)
    assert File.exists?(Path.join(context.writer.path, "unpublished.txt"))
    assert {:ok, unpublished_run} = RunLedger.get(context.store, "run-cleanup")
    assert %{eligible: false, reasons: reasons} = Cleanup.preflight(context.store, context.policy, unpublished_run)
    assert "candidate is not remotely recoverable" in reasons
    refute_received {:scheduler_reclaim, _}
    assert {:ok, _} = Worktree.push_exact(context.route, context.writer.path, context.writer.branch, candidate)

    Process.put(:scheduler_cleanup_failure, :after_worktree_remove)
    assert {:ok, %{launches: []}} = tick.(scheduler)
    refute File.exists?(context.writer.path)
    assert {:ok, %{"cleaned_at" => nil}} = RunLedger.get(context.store, "run-cleanup")
    refute_received {:scheduler_reclaim, _}

    GenServer.stop(context.store)
    {:ok, reopened_store} = Store.start_link(database: context.database)
    Process.delete(:scheduler_cleanup_failure)
    scheduler = %{scheduler | store: reopened_store}
    assert {:ok, %{launches: []}} = tick.(scheduler)
    assert_received {:scheduler_reclaim, args}
    assert context.writer.path in args
    assert "--bazel-for-sources" in args
    assert {:ok, cleaned} = RunLedger.get(reopened_store, "run-cleanup")
    assert is_binary(cleaned["cleaned_at"])
    assert cleaned["candidate_sha"] == candidate
    assert {:ok, %{launches: []}} = tick.(scheduler)
    refute_received {:scheduler_reclaim, _}

    route = context.route |> Map.put("branch", context.writer.branch) |> Map.put("expected_sha", candidate)
    assert {:ok, rehydrated} = Worktree.ensure_writer(route, "PPL-123", "run-cleanup")
    assert rehydrated.head == candidate
    assert rehydrated.path == context.writer.path
    assert File.read!(Path.join(rehydrated.path, "unpublished.txt")) == "local only\n"
  end

  defp cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end
end
