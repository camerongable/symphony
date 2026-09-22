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
