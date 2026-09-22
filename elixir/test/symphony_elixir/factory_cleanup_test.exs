defmodule SymphonyElixir.FactoryCleanupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Cleanup, RunLedger, Store, Worktree}

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

  test "lists only complete terminal identities for fresh external authorization", context do
    assert [candidate] = Cleanup.authorization_candidates(context.store, context.policy, "grail")
    assert candidate["run_id"] == "run-cleanup"
    assert candidate["issue_key"] == "PPL-123"
    assert candidate["candidate_sha"]

    assert [] == Cleanup.authorization_candidates(context.store, context.policy, "other")
  end

  defp cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end
end
