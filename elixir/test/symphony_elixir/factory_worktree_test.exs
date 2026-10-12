defmodule SymphonyElixir.FactoryWorktreeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Worktree
  alias SymphonyElixir.PathSafety

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

  test "pinned writer creation keeps the recorded commit after the base advances and reuses only its clean checkout", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    File.mkdir_p!(route["workspace_root"])
    {:ok, root} = PathSafety.canonicalize(route["workspace_root"])
    route = route |> Map.put("workspace_root", root) |> Map.put("branch", "cgable/PPL-123-pinned")
    File.write!(Path.join(repo, "NEXT.md"), "next\n")
    cmd!(repo, ["add", "NEXT.md"])
    cmd!(repo, ["commit", "--no-verify", "-m", "advance base"])
    advanced = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    cmd!(repo, ["update-ref", "refs/remotes/origin/master", advanced])
    marker = Path.join(Path.dirname(repo), "checkout-hook-ran")
    hook = Path.join(repo, ".git/hooks/post-checkout")
    File.write!(hook, "#!/bin/sh\n: > '#{marker}'\n")
    File.chmod!(hook, 0o755)

    assert {:ok, writer} = Worktree.ensure_writer_pinned(route, "PPL-123", "pinned-run", sha)
    refute File.exists?(marker)
    assert writer.head == sha
    assert writer.path == Worktree.writer_path(route, "PPL-123", "pinned-run")
    assert {:ok, ^writer} = Worktree.ensure_writer_pinned(route, "PPL-123", "pinned-run", sha)
    assert String.trim(cmd!(repo, ["rev-parse", "refs/remotes/origin/master"])) == advanced
    File.write!(Path.join(writer.path, "UNTRACKED.md"), "preserve\n")
    assert {:error, :worktree_dirty} = Worktree.ensure_writer_pinned(route, "PPL-123", "pinned-run", sha)
    assert File.read!(Path.join(writer.path, "UNTRACKED.md")) == "preserve\n"
    assert String.trim(cmd!(writer.path, ["rev-parse", "HEAD"])) == sha
  end

  test "pinned writer rejects protected branches, branch collisions and aliased roots without overwriting refs", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    File.mkdir_p!(route["workspace_root"])
    {:ok, root} = PathSafety.canonicalize(route["workspace_root"])
    route = Map.put(route, "workspace_root", root)
    assert {:error, :native_branch_protected} = Worktree.ensure_writer_pinned(Map.put(route, "branch", "master"), "PPL-123", "protected", sha)
    cmd!(repo, ["branch", "cgable/existing"])
    existing = Map.put(route, "branch", "cgable/existing")
    assert {:error, {:pinned_writer_branch_already_exists, "cgable/existing"}} = Worktree.ensure_writer_pinned(existing, "PPL-123", "collision", sha)
    refute File.exists?(Worktree.writer_path(existing, "PPL-123", "collision"))
    assert String.trim(cmd!(repo, ["rev-parse", "cgable/existing"])) == sha
    alias_root = root <> "-alias"
    File.ln_s!(root, alias_root)
    aliased = route |> Map.put("workspace_root", alias_root) |> Map.put("branch", "cgable/alias")
    assert {:error, :pinned_writer_root_unproven} = Worktree.ensure_writer_pinned(aliased, "PPL-123", "alias", sha)
    refute File.exists?(Worktree.writer_path(route, "PPL-123", "alias"))
    cmd!(repo, ["tag", "-a", "annotated", "-m", "not a commit object"])
    tag_sha = String.trim(cmd!(repo, ["rev-parse", "annotated"]))
    tagged = Map.put(route, "branch", "cgable/tagged")
    assert {:error, :pinned_writer_commit_required} = Worktree.ensure_writer_pinned(tagged, "PPL-123", "tag", tag_sha)
    refute File.exists?(Worktree.writer_path(tagged, "PPL-123", "tag"))
    {_, status} = System.cmd("git", ["-C", repo, "show-ref", "--verify", "refs/heads/cgable/tagged"], stderr_to_stdout: true)
    assert status != 0
  end

  test "pinned creation ignores redirected Git environment instead of mutating a foreign repository", %{route: route, repo: repo} do
    File.mkdir_p!(route["workspace_root"])
    {:ok, root} = PathSafety.canonicalize(route["workspace_root"])
    route = route |> Map.put("workspace_root", root) |> Map.put("branch", "cgable/PPL-123-env")
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    foreign = Path.join(Path.dirname(repo), "foreign")
    cmd!(Path.dirname(repo), ["clone", "--no-hardlinks", repo, foreign])
    arguments = Enum.map_join([route, "PPL-123", "environment", sha], ", ", &inspect/1)
    code = "IO.inspect(SymphonyElixir.Factory.Worktree.ensure_writer_pinned(#{arguments}))"
    args = ["run", "--no-compile", "--no-start", "-e", code]
    {output, status} = System.cmd(System.find_executable("mix"), args, env: [{"MIX_ENV", "test"}, {"GIT_DIR", Path.join(foreign, ".git")}, {"GIT_WORK_TREE", repo}], stderr_to_stdout: true)
    assert status == 0
    assert output =~ "{:ok,"
    writer = Worktree.writer_path(route, "PPL-123", "environment")
    proof_opts = [detached: false, expected_branch: route["branch"], expected_sha: sha]
    assert {:ok, _} = Worktree.validate_native(route, writer, proof_opts)
    {_, status} = System.cmd("git", ["-C", foreign, "show-ref", "--verify", "refs/heads/" <> route["branch"]], stderr_to_stdout: true)
    assert status != 0
    refute cmd!(foreign, ["worktree", "list", "--porcelain"]) =~ writer
  end

  test "assigns a run suffix when a prior run left the stable issue branch", %{route: route, repo: repo} do
    branch = Worktree.branch_name("PPL-123", "Add ZIP handling", "cgable")
    cmd!(repo, ["branch", branch])
    fresh_branch = Worktree.branch_name("PPL-124", "Different issue", "cgable")

    suffixed_branch = "#{branch}-abcdef12"
    assert {:ok, ^suffixed_branch} = Worktree.branch_for_run(route, branch, "abcdef12-3456-7890-abcd-ef1234567890")
    assert {:ok, ^fresh_branch} = Worktree.branch_for_run(route, fresh_branch, "bcdef123-4567-890a-bcde-f12345678901")
    cmd!(repo, ["branch", suffixed_branch])

    assert {:error, {:factory_branch_collision, ^suffixed_branch}} =
             Worktree.branch_for_run(route, branch, "abcdef12-3456-7890-abcd-ef1234567890")

    assert {:error, :invalid_factory_branch_identity} = Worktree.branch_for_run(route, nil, "run-123")
    assert {:error, :native_branch_invalid} = Worktree.branch_for_run(route, "invalid branch", "run-123")
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

  test "remote branch recovery reads the exact branch without changing local refs, source or worktrees", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    branch = "cgable/PPL-123-recovery"
    cmd!(repo, ["push", "--no-verify", "origin", "#{sha}:refs/heads/#{branch}"])
    refs = cmd!(repo, ["show-ref"])
    status = cmd!(repo, ["status", "--porcelain", "--untracked-files=all"])
    worktrees = cmd!(repo, ["worktree", "list", "--porcelain"])
    assert {:ok, ^sha} = Worktree.read_remote_branch(route, branch)
    assert {:error, :remote_branch_readback_mismatch} = Worktree.read_remote_branch(route, branch <> "-missing")
    assert {:error, :native_branch_invalid} = Worktree.read_remote_branch(route, branch <> "*")
    assert {:error, :native_branch_protected} = Worktree.read_remote_branch(route, "master")
    assert cmd!(repo, ["show-ref"]) == refs
    assert cmd!(repo, ["status", "--porcelain", "--untracked-files=all"]) == status
    assert cmd!(repo, ["worktree", "list", "--porcelain"]) == worktrees
  end

  test "origin identity requires one matching destination and never exposes credential-bearing URLs", %{route: route, repo: repo} do
    assert {:ok, %{"destination_sha256" => hash}} = Worktree.origin_identity(route, repo)
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
    secret = "https://fixture-user:fixture-secret@example.invalid/repository.git"
    cmd!(repo, ["config", "remote.origin.pushurl", secret])
    assert {:error, :origin_destination_unproven} = Worktree.origin_identity(route, repo)
    cmd!(repo, ["config", "remote.origin.url", secret])
    assert {:ok, pinned} = Worktree.origin_identity(route, repo)
    assert Map.keys(pinned) == ["destination_sha256"]
    refute inspect(pinned) =~ "fixture-secret"
    cmd!(repo, ["config", "--add", "remote.origin.pushurl", "https://other.invalid/repo.git"])
    assert {:error, :origin_destination_unproven} = Worktree.origin_identity(route, repo)

    for {destination, allowed} <- [
          {"https://example.invalid/team/repo.git", true},
          {"ssh://git@example.invalid/team/repo.git", true},
          {"git@example.invalid:team/repo.git", true},
          {"file:///private/tmp/fixture-origin.git", true},
          {"/private/tmp/fixture-origin.git", true},
          {"file:relative-origin.git", false},
          {"ext::echo fixture", false},
          {"../origin.git", false}
        ] do
      cmd!(repo, ["config", "--replace-all", "remote.origin.url", destination])
      cmd!(repo, ["config", "--replace-all", "remote.origin.pushurl", destination])
      assert match?({:ok, _}, Worktree.origin_identity(route, repo)) == allowed
    end
  end

  test "equal relative origin strings do not prove matching destinations across linked checkout directories", %{route: route, repo: repo} do
    assert {:ok, writer} = Worktree.ensure_writer(route, "PPL-123", "relative-origin")
    cmd!(repo, ["config", "remote.origin.url", "../origin.git"])
    assert cmd!(repo, ["remote", "get-url", "origin"]) == cmd!(writer.path, ["remote", "get-url", "--push", "origin"])
    refute Path.expand("../origin.git", repo) == Path.expand("../origin.git", writer.path)
    assert {:error, :origin_destination_unproven} = Worktree.origin_identity(route, writer.path)
  end

  test "reuses a clean critic checkout at its pinned SHA but keeps exact-SHA creation strict", %{route: route, repo: repo} do
    original = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))

    assert {:ok, critic_path} =
             Worktree.create_detached_pinned(route, "PPL-123", "run-12345678", "specification-critic-1", original)

    File.write!(Path.join(repo, "NEXT.md"), "next\n")
    cmd!(repo, ["add", "NEXT.md"])
    cmd!(repo, ["commit", "-m", "advance base"])
    advanced = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))

    assert {:ok, ^critic_path} =
             Worktree.create_detached_pinned(route, "PPL-123", "run-12345678", "specification-critic-1", advanced)

    assert String.trim(cmd!(critic_path, ["rev-parse", "HEAD"])) == original

    assert {:error, :detached_worktree_mismatch} =
             Worktree.create_detached(route, "PPL-123", "run-12345678", "specification-critic-1", advanced)

    assert {:error, :pinned_detached_stage_not_allowed} =
             Worktree.create_detached_pinned(route, "PPL-123", "run-12345678", "verify-1", advanced)
  end

  test "preserves a dirty detached checkout instead of reclaiming it", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    assert {:ok, path} = Worktree.create_detached(route, "PPL-123", "run-12345678", "specification", sha)
    File.write!(Path.join(path, "UNTRACKED.md"), "preserve me\n")

    assert {:error, :worktree_dirty} = Worktree.validate_detached(route, path)
    assert {:error, :worktree_dirty} = Worktree.remove_detached(route, path)
    assert File.read!(Path.join(path, "UNTRACKED.md")) == "preserve me\n"
  end

  test "validates a clean native detached worktree at the expected commit", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-task")
    cmd!(repo, ["worktree", "add", "--detach", path, sha])
    {:ok, canonical_path} = PathSafety.canonicalize(path)

    assert {:ok, %{path: ^canonical_path, sha: ^sha}} =
             Worktree.validate_native(route, path, expected_sha: sha)

    wrong_sha = String.duplicate("0", 40)

    assert {:error, {:native_worktree_sha_mismatch, ^wrong_sha, ^sha}} =
             Worktree.validate_native(route, path, expected_sha: wrong_sha)
  end

  test "rejects missing, primary, nested, and foreign native checkout paths", %{route: route, repo: repo} do
    assert {:error, :native_worktree_invalid_path} = Worktree.validate_native(route, nil)

    assert {:error, :native_worktree_missing} =
             Worktree.validate_native(route, Path.join(Path.dirname(repo), "missing-task"))

    assert {:error, :native_worktree_primary_checkout} = Worktree.validate_native(route, repo)

    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-task")
    cmd!(repo, ["worktree", "add", "--detach", path, sha])
    File.mkdir_p!(Path.join(path, "nested"))

    assert {:error, :native_worktree_root_mismatch} =
             Worktree.validate_native(route, Path.join(path, "nested"))

    foreign = Path.join(Path.dirname(repo), "foreign-clone")
    cmd!(Path.dirname(repo), ["clone", repo, foreign])
    assert {:error, :worktree_not_registered} = Worktree.validate_native(route, foreign)
  end

  test "native read-only stage rejects dirty and branch-attached checkouts", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-task")
    cmd!(repo, ["worktree", "add", "--detach", path, sha])
    {:ok, canonical_path} = PathSafety.canonicalize(path)
    File.write!(Path.join(path, "UNTRACKED.md"), "preserve me\n")

    assert {:error, :worktree_dirty} = Worktree.validate_native(route, path)
    assert {:ok, %{path: ^canonical_path, sha: ^sha}} = Worktree.validate_native(route, path, clean: false)

    File.rm!(Path.join(path, "UNTRACKED.md"))
    cmd!(path, ["switch", "-c", "native-task-branch"])

    assert {:error, :native_worktree_not_detached} = Worktree.validate_native(route, path)
    assert {:ok, %{path: ^canonical_path, sha: ^sha}} = Worktree.validate_native(route, path, detached: false)

    assert {:ok, %{path: ^canonical_path, sha: ^sha}} =
             Worktree.validate_native(route, path, detached: false, expected_branch: "native-task-branch")

    assert {:error, {:native_worktree_branch_mismatch, "different-branch", "native-task-branch"}} =
             Worktree.validate_native(route, path, detached: false, expected_branch: "different-branch")
  end

  test "attaches a pinned detached native checkout and is idempotent", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-writer")
    branch = "factory/native-writer"
    cmd!(repo, ["worktree", "add", "--detach", path, sha])
    {:ok, canonical_path} = PathSafety.canonicalize(path)

    assert {:ok, %{path: ^canonical_path, sha: ^sha}} =
             Worktree.attach_native_branch(route, path, branch, sha)

    assert String.trim(cmd!(path, ["branch", "--show-current"])) == branch
    assert String.trim(cmd!(repo, ["rev-parse", "refs/heads/#{branch}"])) == sha

    assert {:ok, %{path: ^canonical_path, sha: ^sha}} =
             Worktree.attach_native_branch(route, path, branch, sha)

    assert {:error, {:native_worktree_branch_mismatch, "factory/other", ^branch}} =
             Worktree.attach_native_branch(route, path, "factory/other", sha)

    assert String.trim(cmd!(repo, ["branch", "--list", "factory/other"])) == ""
    assert String.trim(cmd!(path, ["branch", "--show-current"])) == branch
  end

  test "controller commits only the writer-declared native files and adopts the same commit after a retry", %{
    route: route,
    repo: repo
  } do
    parent = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-commit")
    branch = "factory/native-commit"
    message = "feat(PPL-123): add verified slice"
    cmd!(repo, ["worktree", "add", "--detach", path, parent])
    assert {:ok, _workspace} = Worktree.attach_native_branch(route, path, branch, parent)
    File.write!(Path.join(path, "feature.txt"), "done\n")

    assert {:ok, %{sha: candidate}} =
             Worktree.commit_native_slice(route, path, branch, parent, ["feature.txt"], message)

    assert candidate == String.trim(cmd!(path, ["rev-parse", "HEAD"]))
    assert parent == String.trim(cmd!(path, ["rev-parse", "HEAD^"]))
    assert message == String.trim(cmd!(path, ["show", "-s", "--format=%s", "HEAD"]))
    assert String.trim(cmd!(path, ["status", "--porcelain"])) == ""

    assert {:ok, %{sha: ^candidate}} =
             Worktree.commit_native_slice(route, path, branch, parent, ["feature.txt"], message)

    assert String.trim(cmd!(path, ["rev-list", "--count", "#{parent}..HEAD"])) == "1"
  end

  test "controller accepts a performance commit for a native writer slice", %{route: route, repo: repo} do
    parent = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-perf-commit")
    branch = "factory/native-perf-commit"
    message = "perf(PPL-123): reduce scan allocations"
    cmd!(repo, ["worktree", "add", "--detach", path, parent])
    assert {:ok, _workspace} = Worktree.attach_native_branch(route, path, branch, parent)
    File.write!(Path.join(path, "performance.txt"), "optimized\n")

    assert {:ok, %{sha: candidate}} =
             Worktree.commit_native_slice(route, path, branch, parent, ["performance.txt"], message)

    assert message == String.trim(cmd!(path, ["show", "-s", "--format=%s", "HEAD"]))
    assert candidate == String.trim(cmd!(path, ["rev-parse", "HEAD"]))
  end

  test "controller refuses a native slice with an unrelated or staged file", %{route: route, repo: repo} do
    parent = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-unsafe-slice")
    branch = "factory/native-unsafe-slice"
    message = "feat(PPL-123): add verified slice"
    cmd!(repo, ["worktree", "add", "--detach", path, parent])
    assert {:ok, _workspace} = Worktree.attach_native_branch(route, path, branch, parent)
    File.write!(Path.join(path, "feature.txt"), "done\n")
    File.write!(Path.join(path, "unrelated.txt"), "preserve\n")

    assert {:error, :native_slice_paths_mismatch} =
             Worktree.commit_native_slice(route, path, branch, parent, ["feature.txt"], message)

    File.rm!(Path.join(path, "unrelated.txt"))
    File.write!(Path.join(path, "README.md"), "changed\n")
    cmd!(path, ["add", "README.md"])

    assert {:error, :native_slice_pre_staged_changes} =
             Worktree.commit_native_slice(route, path, branch, parent, ["feature.txt"], message)

    assert String.trim(cmd!(path, ["rev-parse", "HEAD"])) == parent
    assert File.read!(Path.join(path, "feature.txt")) == "done\n"
  end

  test "controller finishes an exact slice staged before a restart", %{route: route, repo: repo} do
    parent = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-staged-slice")
    branch = "factory/native-staged-slice"
    message = "feat(PPL-123): add staged slice"
    cmd!(repo, ["worktree", "add", "--detach", path, parent])
    assert {:ok, _workspace} = Worktree.attach_native_branch(route, path, branch, parent)
    File.write!(Path.join(path, "staged.txt"), "done\n")
    cmd!(path, ["add", "--", "staged.txt"])

    assert {:ok, %{sha: sha}} =
             Worktree.commit_native_slice(route, path, branch, parent, ["staged.txt"], message)

    assert sha == String.trim(cmd!(path, ["rev-parse", "HEAD"]))
    assert String.trim(cmd!(path, ["status", "--porcelain"])) == ""
  end

  test "controller refuses a native slice on the wrong branch or parent", %{route: route, repo: repo} do
    parent = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-wrong-parent")
    branch = "factory/native-wrong-parent"
    cmd!(repo, ["worktree", "add", "--detach", path, parent])
    assert {:ok, _workspace} = Worktree.attach_native_branch(route, path, branch, parent)
    File.write!(Path.join(path, "feature.txt"), "done\n")
    message = "feat(PPL-123): add verified slice"

    assert {:error, {:native_worktree_branch_mismatch, "factory/other", ^branch}} =
             Worktree.commit_native_slice(route, path, "factory/other", parent, ["feature.txt"], message)

    wrong_parent = String.duplicate("0", 40)

    assert {:error, _reason} =
             Worktree.commit_native_slice(route, path, branch, wrong_parent, ["feature.txt"], message)

    assert String.trim(cmd!(path, ["rev-parse", "HEAD"])) == parent
  end

  test "attaches an existing branch only at the pinned SHA", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-writer")
    branch = "factory/existing"
    cmd!(repo, ["branch", branch, sha])
    cmd!(repo, ["worktree", "add", "--detach", path, sha])

    assert {:ok, %{sha: ^sha}} = Worktree.attach_native_branch(route, path, branch, sha)
    assert String.trim(cmd!(path, ["branch", "--show-current"])) == branch
  end

  test "rejects invalid, dirty, unpinned, and conflicting native branch attachment without switching", %{
    route: route,
    repo: repo
  } do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-writer")
    cmd!(repo, ["worktree", "add", "--detach", path, sha])

    assert {:error, :native_branch_invalid} = Worktree.attach_native_branch(route, path, "bad..branch", sha)
    assert {:error, :native_branch_protected} = Worktree.attach_native_branch(route, path, "master", sha)

    assert {:error, :native_worktree_invalid_expected_sha} =
             Worktree.attach_native_branch(route, path, "factory/writer", nil)

    wrong_sha = String.duplicate("0", 40)

    assert {:error, {:native_worktree_sha_mismatch, ^wrong_sha, ^sha}} =
             Worktree.attach_native_branch(route, path, "factory/writer", wrong_sha)

    File.write!(Path.join(path, "UNTRACKED.md"), "preserve me\n")
    assert {:error, :worktree_dirty} = Worktree.attach_native_branch(route, path, "factory/writer", sha)
    assert File.read!(Path.join(path, "UNTRACKED.md")) == "preserve me\n"
    File.rm!(Path.join(path, "UNTRACKED.md"))

    File.write!(Path.join(repo, "NEXT.md"), "next\n")
    cmd!(repo, ["add", "NEXT.md"])
    cmd!(repo, ["commit", "-m", "advance base"])
    advanced_sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    cmd!(repo, ["branch", "factory/writer", advanced_sha])

    assert {:error, {:native_branch_sha_mismatch, "factory/writer", ^sha, ^advanced_sha}} =
             Worktree.attach_native_branch(route, path, "factory/writer", sha)

    assert String.trim(cmd!(path, ["branch", "--show-current"])) == ""
    assert String.trim(cmd!(path, ["rev-parse", "HEAD"])) == sha
    assert String.trim(cmd!(repo, ["rev-parse", "refs/heads/factory/writer"])) == advanced_sha
  end

  test "does not steal a factory branch checked out by another worktree", %{route: route, repo: repo} do
    sha = String.trim(cmd!(repo, ["rev-parse", "HEAD"]))
    path = Path.join(Path.dirname(repo), "native-writer")
    occupied_path = Path.join(Path.dirname(repo), "other-writer")
    branch = "factory/occupied"
    cmd!(repo, ["worktree", "add", "--detach", path, sha])
    cmd!(repo, ["worktree", "add", "-b", branch, occupied_path, sha])
    {:ok, canonical_occupied_path} = PathSafety.canonicalize(occupied_path)

    assert {:error, {:native_branch_checked_out_elsewhere, ^branch, ^canonical_occupied_path}} =
             Worktree.attach_native_branch(route, path, branch, sha)

    assert String.trim(cmd!(path, ["branch", "--show-current"])) == ""
    assert String.trim(cmd!(occupied_path, ["branch", "--show-current"])) == branch
  end

  defp cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end
end
