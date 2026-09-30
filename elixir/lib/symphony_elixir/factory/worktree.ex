defmodule SymphonyElixir.Factory.Worktree do
  @moduledoc """
  Factory-owned Git worktrees and exact-SHA delivery operations.

  The module never removes dirty worktrees and never pushes from the source
  checkout. Verification and validation use detached worktrees separate from
  the sole writer.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @doc "Fetches and returns the exact current remote base SHA for a repository route."
  @spec base_sha(map()) :: {:ok, String.t()} | {:error, term()}
  def base_sha(route) do
    repo = Path.expand(Map.fetch!(route, "path"))
    base = Map.fetch!(route, "base_branch")

    with :ok <- validate_repository(repo),
         {:ok, _output} <-
           git(repo, ["fetch", "--no-tags", "origin", "+refs/heads/#{base}:refs/remotes/origin/#{base}"]) do
      rev_parse(repo, "refs/remotes/origin/#{base}")
    end
  end

  @doc "Returns the stable human-readable factory branch for one Jira issue."
  @spec branch_name(String.t(), String.t() | nil, String.t()) :: String.t()
  def branch_name(issue_key, summary, prefix) do
    issue = issue_key |> String.upcase() |> String.replace(~r/[^A-Z0-9._-]/, "-")

    slug =
      (summary || "")
      |> String.normalize(:nfd)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 56)
      |> String.trim("-")

    suffix = if slug == "", do: issue, else: "#{issue}-#{slug}"
    "#{prefix}/#{suffix}"
  end

  @doc "Keeps a later run off a local issue branch left by an earlier run."
  @spec branch_for_run(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def branch_for_run(route, branch, run_id) when is_binary(branch) and is_binary(run_id) do
    repo = route |> Map.fetch!("path") |> Path.expand()

    with :ok <- validate_native_branch(repo, branch) do
      choose_branch_for_run(repo, branch, run_id)
    end
  end

  def branch_for_run(_route, _branch, _run_id), do: {:error, :invalid_factory_branch_identity}

  defp choose_branch_for_run(repo, branch, run_id) do
    if branch_exists?(repo, branch), do: suffixed_branch(repo, branch, run_id), else: {:ok, branch}
  end

  defp suffixed_branch(repo, branch, run_id) do
    candidate = "#{branch}-#{String.slice(run_id, 0, 8)}"

    case validate_native_branch(repo, candidate) do
      :ok ->
        if branch_exists?(repo, candidate),
          do: {:error, {:factory_branch_collision, candidate}},
          else: {:ok, candidate}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Creates or validates the sole source-writing worktree for a run."
  @spec ensure_writer(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_writer(route, issue_key, run_id) do
    repo = Path.expand(Map.fetch!(route, "path"))
    base = Map.fetch!(route, "base_branch")

    branch =
      Map.get(route, "branch") ||
        branch_name(issue_key, Map.get(route, "issue_summary"), Map.get(route, "branch_prefix", "ai"))

    expected_sha = Map.get(route, "expected_sha")
    path = stage_path(route, issue_key, run_id, "writer")

    with :ok <- validate_repository(repo),
         :ok <- validate_stage_path(path, route),
         {:ok, _output} <-
           git(repo, ["fetch", "--no-tags", "origin", "+refs/heads/#{base}:refs/remotes/origin/#{base}"]),
         :ok <- ensure_base_ref(repo, base),
         :ok <- prepare_branch_refs(repo, branch, expected_sha),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- ensure_writer_path(repo, path, branch, base, expected_sha),
         {:ok, head} <- rev_parse(path, "HEAD") do
      {:ok, %{path: path, branch: branch, base_branch: base, head: head}}
    end
  end

  @doc "Creates a fresh detached worktree for independent verification or validation."
  @spec create_detached(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_detached(route, issue_key, run_id, stage, sha) do
    repo = Path.expand(Map.fetch!(route, "path"))
    path = stage_path(route, issue_key, run_id, stage)

    with :ok <- validate_repository(repo),
         :ok <- validate_stage_path(path, route),
         :ok <- object_exists(repo, sha),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- ensure_detached_path(repo, path, sha),
         {:ok, ^sha} <- rev_parse(path, "HEAD") do
      {:ok, path}
    end
  end

  @doc "Reuses a clean specification-critic checkout at its original SHA after the remote base advances."
  @spec create_detached_pinned(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_detached_pinned(route, issue_key, run_id, stage, sha) do
    with true <- String.match?(stage, ~r/^specification-critic-\d+$/) or {:error, :pinned_detached_stage_not_allowed},
         repo = Path.expand(Map.fetch!(route, "path")),
         path = stage_path(route, issue_key, run_id, stage),
         :ok <- validate_repository(repo),
         :ok <- validate_stage_path(path, route) do
      reuse_or_create_pinned(route, issue_key, run_id, stage, sha, path)
    end
  end

  defp reuse_or_create_pinned(route, issue_key, run_id, stage, sha, path) do
    if File.dir?(path) do
      case validate_detached(route, path) do
        {:ok, _pinned} -> {:ok, path}
        {:error, _reason} = error -> error
      end
    else
      create_detached(route, issue_key, run_id, stage, sha)
    end
  end

  @doc "Validates a recorded factory detached checkout before a task resumes in it."
  @spec validate_detached(map(), Path.t()) :: {:ok, %{path: Path.t(), sha: String.t()}} | {:error, term()}
  def validate_detached(route, path) do
    repo = Path.expand(Map.fetch!(route, "path"))

    with :ok <- validate_repository(repo),
         :ok <- validate_stage_path(path, route),
         :ok <- require_registered(repo, path),
         :ok <- require_clean(path),
         {:ok, ""} <- trimmed_git(path, ["branch", "--show-current"]),
         {:ok, sha} <- rev_parse(path, "HEAD"),
         :ok <- object_exists(repo, sha) do
      {:ok, %{path: path, sha: sha}}
    else
      {:ok, _other} -> {:error, :detached_worktree_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validates a Codex-managed worktree from this repository before adopting it for a task."
  @spec validate_native(map(), Path.t()) ::
          {:ok, %{path: Path.t(), sha: String.t()}} | {:error, term()}
  def validate_native(route, path), do: validate_native(route, path, [])

  @spec validate_native(map(), Path.t(), keyword()) ::
          {:ok, %{path: Path.t(), sha: String.t()}} | {:error, term()}
  def validate_native(_route, path, _opts) when not is_binary(path), do: {:error, :native_worktree_invalid_path}

  def validate_native(route, path, opts) do
    repo = route |> Map.fetch!("path") |> Path.expand()
    expanded = Path.expand(path)

    with :ok <- validate_repository(repo),
         :ok <- require_existing_directory(expanded),
         {:ok, canonical_path} <- PathSafety.canonicalize(expanded),
         :ok <- require_nonprimary(repo, canonical_path),
         :ok <- require_worktree_root(canonical_path),
         :ok <- require_registered(repo, canonical_path),
         :ok <- require_shared_git_common_dir(repo, canonical_path),
         :ok <- maybe_require_clean(canonical_path, Keyword.get(opts, :clean, true)),
         :ok <- maybe_require_detached(canonical_path, Keyword.get(opts, :detached, true)),
         :ok <- require_expected_branch(canonical_path, Keyword.get(opts, :expected_branch)),
         {:ok, sha} <- rev_parse(canonical_path, "HEAD"),
         :ok <- require_expected_sha(sha, Keyword.get(opts, :expected_sha)),
         :ok <- object_exists(repo, sha) do
      {:ok, %{path: canonical_path, sha: sha}}
    end
  end

  @doc "Attaches a clean, pinned native worktree to its exact factory branch."
  @spec attach_native_branch(map(), Path.t(), String.t(), String.t()) ::
          {:ok, %{path: Path.t(), sha: String.t()}} | {:error, term()}
  def attach_native_branch(route, path, branch, expected_sha) do
    repo = route |> Map.fetch!("path") |> Path.expand()

    with :ok <- validate_native_branch(repo, branch),
         :ok <- validate_native_expected_sha(expected_sha),
         {:ok, %{path: canonical_path}} <-
           validate_native(route, path, detached: false, expected_sha: expected_sha),
         {:ok, current_branch} <- trimmed_git(canonical_path, ["branch", "--show-current"]),
         :ok <- attach_native_branch_at_head(repo, canonical_path, current_branch, branch, expected_sha) do
      validate_native(route, canonical_path,
        detached: false,
        expected_branch: branch,
        expected_sha: expected_sha
      )
    end
  end

  @doc "Commits one declared native writer slice, or adopts its exact prior commit after a restart."
  @spec commit_native_slice(map(), Path.t(), String.t(), String.t(), [String.t()], String.t()) ::
          {:ok, %{sha: String.t()}} | {:error, term()}
  def commit_native_slice(route, path, branch, parent_sha, paths, message) do
    with :ok <- validate_native_branch(Map.fetch!(route, "path"), branch),
         :ok <- validate_native_expected_sha(parent_sha),
         :ok <- validate_slice_intent(paths, message),
         {:ok, workspace} <- validate_native(route, path, clean: false, detached: false, expected_branch: branch) do
      if workspace.sha == parent_sha do
        commit_new_native_slice(workspace.path, parent_sha, paths, message)
      else
        adopt_native_slice(workspace.path, workspace.sha, parent_sha, paths, message)
      end
    end
  end

  defp validate_slice_intent(paths, message) when is_list(paths) and is_binary(message) do
    valid_message? =
      byte_size(message) <= 120 and
        String.match?(message, ~r/\A(?:feat|fix|chore|refactor|test|docs|perf)\([A-Z]+-\d+\): [^\r\n\x00]+\z/)

    if valid_slice_paths?(paths) and valid_message?, do: :ok, else: {:error, :native_slice_intent_invalid}
  end

  defp validate_slice_intent(_paths, _message), do: {:error, :native_slice_intent_invalid}

  defp valid_slice_paths?(paths) do
    paths != [] and Enum.uniq(paths) == paths and Enum.all?(paths, &valid_slice_path?/1)
  end

  defp valid_slice_path?(path) when is_binary(path) do
    path != "" and not String.starts_with?(path, "/") and
      not String.contains?(path, ["\n", "\r", "\0"]) and
      Enum.all?(Path.split(path), &(&1 not in ["", ".", "..", ".git"]))
  end

  defp valid_slice_path?(_path), do: false

  defp commit_new_native_slice(path, parent_sha, paths, message) do
    with {:ok, staged} <- git_paths(path, ["diff", "--cached", "--name-only", "-z", "--no-renames"]),
         {:ok, unstaged} <- git_paths(path, ["diff", "--name-only", "-z", "--no-renames"]),
         {:ok, untracked} <- git_paths(path, ["ls-files", "--others", "--exclude-standard", "-z"]),
         :ok <- validate_native_slice_changes(staged, unstaged, untracked, paths),
         :ok <- maybe_stage_native_slice(path, staged, paths),
         {:ok, staged_after} <- git_paths(path, ["diff", "--cached", "--name-only", "-z", "--no-renames"]),
         true <- sorted_paths(staged_after) == sorted_paths(paths) or {:error, :native_slice_stage_mismatch},
         {:ok, _output} <- git(path, ["commit", "--no-verify", "-m", message]),
         {:ok, sha} <- rev_parse(path, "HEAD") do
      adopt_native_slice(path, sha, parent_sha, paths, message)
    end
  end

  defp validate_native_slice_changes([], unstaged, untracked, paths) do
    if sorted_paths(unstaged ++ untracked) == sorted_paths(paths),
      do: :ok,
      else: {:error, :native_slice_paths_mismatch}
  end

  defp validate_native_slice_changes(staged, [], [], paths) do
    if sorted_paths(staged) == sorted_paths(paths),
      do: :ok,
      else: {:error, :native_slice_pre_staged_changes}
  end

  defp validate_native_slice_changes(_staged, _unstaged, _untracked, _paths),
    do: {:error, :native_slice_pre_staged_changes}

  defp maybe_stage_native_slice(_path, [_ | _], _paths), do: :ok

  defp maybe_stage_native_slice(path, [], paths) do
    literal_paths = Enum.map(paths, &(":(literal)" <> &1))

    case git(path, ["add", "--" | literal_paths]) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp adopt_native_slice(path, sha, parent_sha, paths, message) do
    with {:ok, actual_parent} <- rev_parse(path, "HEAD^"),
         true <- actual_parent == parent_sha or {:error, :native_slice_parent_mismatch},
         {:ok, actual_paths} <- git_paths(path, ["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--no-renames", "HEAD"]),
         true <- sorted_paths(actual_paths) == sorted_paths(paths) or {:error, :native_slice_paths_mismatch},
         {:ok, actual_message} <- trimmed_git(path, ["show", "-s", "--format=%s", "HEAD"]),
         true <- actual_message == message or {:error, :native_slice_message_mismatch},
         :ok <- require_clean(path) do
      {:ok, %{sha: sha}}
    end
  end

  defp git_paths(path, args) do
    case git(path, args) do
      {:ok, output} -> {:ok, String.split(output, "\0", trim: true)}
      {:error, _reason} = error -> error
    end
  end

  defp sorted_paths(paths), do: Enum.sort(paths)

  @doc "Removes a clean detached factory worktree and prunes Git metadata."
  @spec remove_detached(map(), Path.t()) :: :ok | {:error, term()}
  def remove_detached(route, path) do
    repo = Path.expand(Map.fetch!(route, "path"))

    with :ok <- validate_stage_path(path, route),
         :ok <- require_registered(repo, path),
         :ok <- require_clean(path),
         {:ok, _output} <- git(repo, ["worktree", "remove", path]),
         {:ok, _output} <- git(repo, ["worktree", "prune"]) do
      :ok
    end
  end

  @doc "Returns a clean candidate SHA from the writer worktree."
  @spec candidate(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def candidate(path, base_branch) do
    with :ok <- require_clean(path),
         {:ok, head} <- rev_parse(path, "HEAD"),
         {:ok, count_text} <- git(path, ["rev-list", "--count", "origin/#{base_branch}..#{head}"]),
         {count, ""} when count > 0 <- Integer.parse(String.trim(count_text)) do
      {:ok, head}
    else
      {0, ""} -> {:error, :candidate_has_no_commits}
      :error -> {:error, :invalid_candidate_commit_count}
      {:error, _reason} = error -> error
    end
  end

  @doc "Pushes exactly one verified SHA to its factory branch and reads it back."
  @spec push_exact(map(), Path.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def push_exact(route, writer_path, branch, sha) do
    repo = Path.expand(Map.fetch!(route, "path"))
    base = Map.fetch!(route, "base_branch")

    with :ok <- forbid_protected_branch(branch, base),
         :ok <- require_clean(writer_path),
         {:ok, ^sha} <- rev_parse(writer_path, "HEAD"),
         :ok <- object_exists(repo, sha),
         {:ok, _output} <-
           git(writer_path, ["push", "--no-verify", "origin", "#{sha}:refs/heads/#{branch}"]),
         {:ok, output} <- git(repo, ["ls-remote", "origin", "refs/heads/#{branch}"]),
         {:ok, ^sha} <- parse_ls_remote(output, branch) do
      {:ok, %{sha: sha, branch: branch}}
    end
  end

  @doc "Returns true only when a commit exists in the controller-readable object store."
  @spec reachable?(map(), String.t()) :: boolean()
  def reachable?(route, sha) do
    route
    |> Map.fetch!("path")
    |> Path.expand()
    |> object_exists(sha)
    |> Kernel.==(:ok)
  end

  defp stage_path(route, issue_key, run_id, stage) do
    safe_issue = String.replace(issue_key, ~r/[^a-zA-Z0-9._-]/, "_")
    safe_run = String.replace(run_id, ~r/[^a-zA-Z0-9._-]/, "_")

    (Map.get(route, "workspace_root") || Config.local_workspace_root())
    |> Path.expand()
    |> Path.join("factory")
    |> Path.join("#{safe_issue}-#{safe_run}")
    |> Path.join(stage)
  end

  defp validate_repository(repo) do
    case git(repo, ["rev-parse", "--show-toplevel"]) do
      {:ok, output} ->
        if canonical(String.trim(output)) == canonical(repo),
          do: :ok,
          else: {:error, :repository_path_not_toplevel}

      {:error, _reason} = error ->
        error
    end
  end

  defp canonical(path) do
    case PathSafety.canonicalize(path) do
      {:ok, realpath} -> realpath
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp validate_stage_path(path, route) do
    root =
      (Map.get(route, "workspace_root") || Config.local_workspace_root())
      |> Path.expand()
      |> Path.join("factory")

    expanded = Path.expand(path)

    if String.starts_with?(expanded <> "/", root <> "/") do
      :ok
    else
      {:error, {:worktree_outside_factory_root, expanded}}
    end
  end

  defp ensure_base_ref(repo, base) do
    object_exists(repo, "refs/remotes/origin/#{base}^{commit}")
  end

  defp prepare_branch_refs(repo, branch, expected_sha) do
    with {:ok, remote_sha} <- remote_branch_sha(repo, branch),
         :ok <- fetch_remote_branch(repo, branch, remote_sha),
         :ok <- ensure_local_branch(repo, branch, remote_sha) do
      validate_expected_branch(repo, branch, expected_sha)
    end
  end

  defp fetch_remote_branch(_repo, _branch, nil), do: :ok

  defp fetch_remote_branch(repo, branch, _remote_sha) do
    case git(repo, ["fetch", "--no-tags", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"]) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ensure_local_branch(_repo, _branch, nil), do: :ok

  defp ensure_local_branch(repo, branch, remote_sha) do
    if branch_exists?(repo, branch) do
      with {:ok, local_sha} <- rev_parse(repo, "refs/heads/#{branch}"),
           true <-
             local_sha == remote_sha or
               {:error, {:local_remote_branch_mismatch, branch, local_sha, remote_sha}} do
        :ok
      end
    else
      case git(repo, ["branch", branch, "refs/remotes/origin/#{branch}"]) do
        {:ok, _output} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp validate_expected_branch(_repo, _branch, nil), do: :ok

  defp validate_expected_branch(repo, branch, expected_sha) do
    with true <- branch_exists?(repo, branch) or {:error, {:expected_branch_missing, branch}},
         {:ok, actual_sha} <- rev_parse(repo, "refs/heads/#{branch}"),
         true <- actual_sha == expected_sha or {:error, {:writer_branch_sha_mismatch, expected_sha, actual_sha}} do
      :ok
    end
  end

  defp ensure_writer_path(repo, path, branch, base, expected_sha) do
    cond do
      File.dir?(path) ->
        with :ok <- require_registered(repo, path),
             {:ok, current_branch} <- git(path, ["branch", "--show-current"]),
             true <- String.trim(current_branch) == branch or {:error, :writer_branch_mismatch} do
          validate_worktree_head(path, expected_sha)
        end

      File.exists?(path) ->
        {:error, {:worktree_path_occupied, path}}

      branch_exists?(repo, branch) ->
        with {:ok, _output} <- git(repo, ["worktree", "add", path, branch]) do
          validate_worktree_head(path, expected_sha)
        end

      is_nil(expected_sha) ->
        with {:ok, _output} <-
               git(repo, ["worktree", "add", "-b", branch, path, "refs/remotes/origin/#{base}"]) do
          :ok
        end

      true ->
        {:error, {:expected_branch_missing, branch}}
    end
  end

  defp validate_worktree_head(_path, nil), do: :ok

  defp validate_worktree_head(path, expected_sha) do
    case rev_parse(path, "HEAD") do
      {:ok, ^expected_sha} -> :ok
      {:ok, actual_sha} -> {:error, {:writer_worktree_sha_mismatch, expected_sha, actual_sha}}
      {:error, _reason} = error -> error
    end
  end

  defp branch_exists?(repo, branch) do
    match?({:ok, _output}, git(repo, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp remote_branch_sha(repo, branch) do
    case git(repo, ["ls-remote", "origin", "refs/heads/#{branch}"]) do
      {:ok, output} -> parse_optional_ls_remote(output, branch)
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_ls_remote(output, branch) do
    case String.split(String.trim(output), ~r/\s+/, trim: true) do
      [] -> {:ok, nil}
      [sha, "refs/heads/" <> ^branch] -> {:ok, sha}
      _other -> {:error, {:unexpected_remote_branch_readback, branch, String.trim(output)}}
    end
  end

  defp ensure_detached_path(repo, path, sha) do
    cond do
      File.dir?(path) ->
        with :ok <- require_registered(repo, path),
             :ok <- require_clean(path),
             {:ok, ""} <- trimmed_git(path, ["branch", "--show-current"]),
             {:ok, ^sha} <- rev_parse(path, "HEAD") do
          :ok
        else
          {:ok, _other} -> {:error, :detached_worktree_mismatch}
          {:error, _reason} = error -> error
        end

      File.exists?(path) ->
        {:error, {:worktree_path_occupied, path}}

      true ->
        case git(repo, ["worktree", "add", "--detach", path, sha]) do
          {:ok, _output} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp require_clean(path) do
    case git(path, ["status", "--porcelain"]) do
      {:ok, output} -> if String.trim(output) == "", do: :ok, else: {:error, :worktree_dirty}
      {:error, _reason} = error -> error
    end
  end

  defp require_existing_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :native_worktree_missing}
  end

  defp require_nonprimary(repo, path) do
    if canonical(repo) == path, do: {:error, :native_worktree_primary_checkout}, else: :ok
  end

  defp require_worktree_root(path) do
    case trimmed_git(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, toplevel} ->
        if canonical(toplevel) == path, do: :ok, else: {:error, :native_worktree_root_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp require_shared_git_common_dir(repo, path) do
    with {:ok, repo_common_dir} <- git_common_dir(repo),
         {:ok, path_common_dir} <- git_common_dir(path) do
      if repo_common_dir == path_common_dir,
        do: :ok,
        else: {:error, :native_git_common_dir_mismatch}
    end
  end

  defp git_common_dir(path) do
    with {:ok, common_dir} <- trimmed_git(path, ["rev-parse", "--git-common-dir"]) do
      PathSafety.canonicalize(Path.expand(common_dir, path))
    end
  end

  defp maybe_require_clean(path, true), do: require_clean(path)
  defp maybe_require_clean(_path, false), do: :ok

  defp maybe_require_detached(path, true) do
    case trimmed_git(path, ["symbolic-ref", "--quiet", "HEAD"]) do
      {:ok, _branch} -> {:error, :native_worktree_not_detached}
      {:error, {:git_failed, 1, _args, _output}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_require_detached(_path, false), do: :ok

  defp require_expected_branch(_path, nil), do: :ok

  defp require_expected_branch(path, expected_branch) do
    case trimmed_git(path, ["branch", "--show-current"]) do
      {:ok, ^expected_branch} -> :ok
      {:ok, actual_branch} -> {:error, {:native_worktree_branch_mismatch, expected_branch, actual_branch}}
      {:error, _reason} = error -> error
    end
  end

  defp require_expected_sha(_sha, nil), do: :ok
  defp require_expected_sha(sha, sha), do: :ok

  defp require_expected_sha(actual_sha, expected_sha) do
    {:error, {:native_worktree_sha_mismatch, expected_sha, actual_sha}}
  end

  defp validate_native_branch(_repo, branch) when not is_binary(branch), do: {:error, :native_branch_invalid}
  defp validate_native_branch(_repo, branch) when branch in ["main", "master"], do: {:error, :native_branch_protected}

  defp validate_native_branch(repo, branch) do
    case git(repo, ["check-ref-format", "--branch", branch]) do
      {:ok, output} -> if(String.trim(output) == branch, do: :ok, else: {:error, :native_branch_invalid})
      {:error, _reason} -> {:error, :native_branch_invalid}
    end
  end

  defp validate_native_expected_sha(sha) when is_binary(sha) do
    if String.match?(sha, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/),
      do: :ok,
      else: {:error, :native_worktree_invalid_expected_sha}
  end

  defp validate_native_expected_sha(_sha), do: {:error, :native_worktree_invalid_expected_sha}

  defp attach_native_branch_at_head(_repo, _path, branch, branch, _sha), do: :ok

  defp attach_native_branch_at_head(repo, path, "", branch, sha) do
    with {:ok, existing_branch?} <- require_native_branch_sha(repo, branch, sha),
         :ok <- require_native_branch_available(repo, path, branch),
         args <- if(existing_branch?, do: ["switch", "--no-guess", branch], else: ["switch", "-c", branch]),
         {:ok, _output} <- git(path, args) do
      :ok
    end
  end

  defp attach_native_branch_at_head(_repo, _path, actual_branch, expected_branch, _sha) do
    {:error, {:native_worktree_branch_mismatch, expected_branch, actual_branch}}
  end

  defp require_native_branch_sha(repo, branch, expected_sha) do
    if branch_exists?(repo, branch) do
      case rev_parse(repo, "refs/heads/#{branch}") do
        {:ok, ^expected_sha} -> {:ok, true}
        {:ok, actual_sha} -> {:error, {:native_branch_sha_mismatch, branch, expected_sha, actual_sha}}
        {:error, _reason} = error -> error
      end
    else
      {:ok, false}
    end
  end

  defp require_native_branch_available(repo, path, branch) do
    case git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        occupied_path =
          output
          |> String.split("\n\n", trim: true)
          |> Enum.find_value(&branch_checkout_path(&1, branch, path))

        if occupied_path,
          do: {:error, {:native_branch_checked_out_elsewhere, branch, occupied_path}},
          else: :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp branch_checkout_path(entry, branch, path) do
    lines = String.split(entry, "\n", trim: true)

    registered_path =
      Enum.find_value(lines, fn
        "worktree " <> registered_path -> registered_path
        _line -> nil
      end)

    if "branch refs/heads/#{branch}" in lines and is_binary(registered_path) and
         canonical(registered_path) != path,
       do: canonical(registered_path)
  end

  defp require_registered(repo, path) do
    case git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        registered =
          output
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "worktree "))
          |> Enum.map(&(String.replace_prefix(&1, "worktree ", "") |> canonical()))

        if canonical(path) in registered, do: :ok, else: {:error, :worktree_not_registered}

      {:error, _reason} = error ->
        error
    end
  end

  defp object_exists(repo, object) do
    case git(repo, ["cat-file", "-e", object]) do
      {:ok, _output} -> :ok
      {:error, _reason} -> {:error, {:git_object_unreachable, object}}
    end
  end

  defp rev_parse(path, ref) do
    case git(path, ["rev-parse", ref]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} = error -> error
    end
  end

  defp trimmed_git(path, args) do
    case git(path, args) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} = error -> error
    end
  end

  defp forbid_protected_branch(branch, base) do
    if branch in [base, "main", "master"], do: {:error, :protected_branch_push}, else: :ok
  end

  defp parse_ls_remote(output, branch) do
    case String.split(String.trim(output), ~r/\s+/, parts: 2) do
      [sha, "refs/heads/" <> ^branch] -> {:ok, sha}
      _other -> {:error, :remote_branch_readback_mismatch}
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, args, String.trim(output)}}
    end
  end
end
