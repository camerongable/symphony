defmodule SymphonyElixir.FactoryWorktreeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Worktree

  setup do
    root = Path.join(System.tmp_dir!(), "factory-worktree-#{System.unique_integer([:positive])}")
    bare = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    workspace_root = Path.join(root, "workspaces")
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

    on_exit(fn -> File.rm_rf(root) end)
    %{repo: repo, route: route}
  end

  test "uses the established user, Jira key, and summary branch convention" do
    assert Worktree.branch_name("ppl-123", "Add ZIP & array handling!", "cgable") ==
             "cgable/PPL-123-add-zip-array-handling"
  end

  test "creates one writer, verifies from a detached worktree, and pushes the exact SHA", %{route: route, repo: repo} do
    assert {:ok, writer} = Worktree.ensure_writer(route, "PPL-123", "run-12345678")
    refute writer.branch in ["main", "master"]

    File.write!(Path.join(writer.path, "feature.txt"), "done\n")
    cmd!(writer.path, ["add", "feature.txt"])
    cmd!(writer.path, ["commit", "--no-verify", "-m", "PPL-123: implement feature"])

    assert {:ok, candidate} = Worktree.candidate(writer.path, "master")
    assert Worktree.reachable?(route, candidate)

    assert {:ok, verification_path} =
             Worktree.create_detached(route, "PPL-123", "run-12345678", "verify-1", candidate)

    assert String.trim(cmd!(verification_path, ["rev-parse", "HEAD"])) == candidate
    assert :ok = Worktree.remove_detached(route, verification_path)

    assert {:ok, %{sha: ^candidate}} =
             Worktree.push_exact(route, writer.path, writer.branch, candidate)

    remote = cmd!(repo, ["ls-remote", "origin", "refs/heads/#{writer.branch}"])
    assert String.starts_with?(remote, candidate)
  end

  defp cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end
end
