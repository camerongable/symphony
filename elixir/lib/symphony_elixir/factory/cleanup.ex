defmodule SymphonyElixir.Factory.Cleanup do
  @moduledoc """
  Fresh-read authorization and fail-closed reclamation for factory worktrees.

  Automatic cleanup is limited to factory-owned terminal worktrees whose exact
  candidate is remotely recoverable. It never touches dirty, active, blocked,
  manual, or live-workspace state. Bazel cleanup is delegated to the shared
  `reclaim-disk-space` helper for the exact removed source path.
  """

  alias SymphonyElixir.Factory.{Capacity, RunLedger, Store}
  alias SymphonyElixir.PathSafety

  @doc "Lists terminal factory runs that could be freshly authorized for cleanup."
  @spec authorization_candidates(Store.connection(), map(), String.t()) :: [map()]
  def authorization_candidates(connection, policy, repo_key) do
    cleanup = value(policy, "cleanup", %{})
    allowed_states = value(cleanup, "allowed_run_states", [])

    if value(cleanup, "enabled", false) and allowed_states != [] do
      placeholders = Enum.map_join(allowed_states, ", ", fn _state -> "?" end)

      result =
        Store.query!(
          connection,
          """
          SELECT run_id, issue_key, repo_key, repo_path, base_branch, worktree,
                 branch, candidate_sha, mr_url, mr_iid, state
          FROM runs
          WHERE repo_key = ? AND state IN (#{placeholders})
            AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY'
            AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
            AND factory_owned = 1 AND cleaned_at IS NULL
            AND worktree IS NOT NULL AND branch IS NOT NULL
            AND candidate_sha IS NOT NULL
          ORDER BY updated_at ASC
          """,
          [repo_key | allowed_states]
        )

      Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    else
      []
    end
  end

  @doc "Authorizes one terminal run from freshly read Jira or GitLab state."
  @spec authorize(Store.connection(), map(), String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def authorize(connection, policy, run_id, jira_status, mr_state, opts \\ []) do
    cleanup = value(policy, "cleanup", %{})

    with true <- value(cleanup, "enabled", false) or {:error, :cleanup_disabled},
         {:ok, run} <- RunLedger.get(connection, run_id),
         :ok <- require_legacy_issue(connection, run),
         true <- run["state"] in value(cleanup, "allowed_run_states", []) or {:error, :run_not_terminal},
         true <- run["factory_owned"] == 1 or {:error, :not_factory_owned},
         true <-
           (present?(run["worktree"]) and present?(run["candidate_sha"]) and present?(run["branch"])) or
             {:error, :incomplete_cleanup_identity},
         true <- external_state_allows?(cleanup, jira_status, mr_state) or {:error, :external_state_not_terminal} do
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()

      Store.query!(
        connection,
        """
        UPDATE runs
        SET jira_status = ?, mr_state = ?, cleanup_authorized = 1,
            cleanup_authorized_at = ?, updated_at = ?
        WHERE run_id = ?
        """,
        [jira_status, mr_state, now, now, run_id]
      )

      record_event(connection, run_id, "CLEANUP_AUTHORIZED", %{
        jira_status: jira_status,
        mr_state: mr_state
      })

      RunLedger.get(connection, run_id)
    else
      {:error, _reason} = error -> error
    end
  end

  defp require_legacy_issue(connection, run) do
    if run["execution_mode"] in [nil, "LEGACY"] and not v1_issue_owned?(connection, run["issue_key"]),
      do: :ok,
      else: {:error, :run_quarantined}
  end

  @doc "Returns the preflight result for one authorized cleanup candidate."
  @spec preflight(Store.connection(), map(), map(), keyword()) :: map()
  def preflight(connection, policy, run, opts \\ []) do
    cleanup = value(policy, "cleanup", %{})
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    reasons = []
    worktree = expanded(run["worktree"])
    repo = expanded(run["repo_path"])

    reasons = require_flag(reasons, run["cleanup_authorized"] == 1, "cleanup is not authorized")
    reasons = require_flag(reasons, run["execution_mode"] in [nil, "LEGACY"], "run is quarantined")
    reasons = require_flag(reasons, not v1_issue_owned?(connection, run["issue_key"]), "issue is quarantined")

    reasons =
      require_flag(
        reasons,
        fresh?(run["cleanup_authorized_at"], now, value(cleanup, "authorization_max_age_minutes", 60)),
        "cleanup authorization is stale"
      )

    reasons =
      require_flag(
        reasons,
        run["state"] in value(cleanup, "allowed_run_states", []),
        "run is active, blocked, or not cleanup-eligible"
      )

    reasons = require_flag(reasons, run["factory_owned"] == 1, "worktree is not factory-owned")
    reasons = require_flag(reasons, present?(worktree) and present?(repo), "worktree or repository is missing")
    reasons = require_flag(reasons, worktree != repo, "main checkout is protected")
    reasons = require_flag(reasons, allowed_root?(worktree, cleanup), "worktree is outside configured roots")
    reasons = require_flag(reasons, not live_workspace?(worktree, opts), "worktree is the live workspace")
    reasons = require_flag(reasons, not active_task?(connection, run["run_id"]), "run still has an active task")

    reasons =
      if reasons == [] do
        reasons ++ git_reasons(repo, worktree, run)
      else
        reasons
      end

    %{
      eligible: reasons == [],
      run_id: run["run_id"],
      issue_key: run["issue_key"],
      worktree: worktree,
      candidate_sha: run["candidate_sha"],
      reasons: reasons
    }
  end

  @doc "Lists all authorized cleanup candidates with full preflight evidence."
  @spec plan(Store.connection(), map(), keyword()) :: [map()]
  def plan(connection, policy, opts \\ []) do
    result =
      Store.query!(
        connection,
        """
        SELECT * FROM runs
        WHERE cleanup_authorized = 1 AND cleaned_at IS NULL
        ORDER BY cleanup_authorized_at ASC
        """
      )

    Enum.map(result.rows, fn row ->
      run = Map.new(Enum.zip(result.columns, row))
      preflight(connection, policy, run, opts)
    end)
  end

  @doc "Removes one eligible worktree and only its matching/orphaned Bazel bases."
  @spec apply(Store.connection(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(connection, policy, run_id, opts \\ []) do
    with {:ok, run} <- RunLedger.get(connection, run_id),
         true <- run["execution_mode"] in [nil, "LEGACY"] or {:error, :run_quarantined},
         true <- not v1_issue_owned?(connection, run["issue_key"]) or {:error, :run_quarantined},
         :ok <- already_cleaned(run),
         %{eligible: true} = check <- resumable_preflight(connection, policy, run, opts),
         :ok <- remove_worktree(connection, run, check, opts),
         :ok <- prune_worktrees(connection, run, check, opts),
         {:ok, reclaim} <- reclaim_bazel_resumably(connection, policy, run, check, opts),
         :ok <- checkpoint(opts, :before_ledger_update),
         :ok <- mark_cleaned(connection, run, check, reclaim, opts) do
      {:ok, %{result: "CLEANED", run_id: run_id, worktree: check.worktree, reclaim: reclaim}}
    else
      %{eligible: false} = check -> {:error, {:cleanup_blocked, check}}
      {:error, _reason} = error -> error
    end
  end

  defp already_cleaned(%{"cleaned_at" => value}) when is_binary(value), do: {:error, :already_cleaned}
  defp already_cleaned(_run), do: :ok

  defp resumable_preflight(connection, policy, run, opts) do
    check = preflight(connection, policy, run, opts)

    if check.eligible or recovery_readback?(connection, run, check.worktree) do
      if check.eligible, do: check, else: preflight_after_removal(connection, policy, run, check, opts)
    else
      check
    end
  end

  defp preflight_after_removal(connection, policy, run, check, opts) do
    cleanup = value(policy, "cleanup", %{})
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    reasons =
      []
      |> require_flag(run["cleanup_authorized"] == 1, "cleanup is not authorized")
      |> require_flag(fresh?(run["cleanup_authorized_at"], now, value(cleanup, "authorization_max_age_minutes", 60)), "cleanup authorization is stale")
      |> require_flag(run["state"] in value(cleanup, "allowed_run_states", []), "run is active, blocked, or not cleanup-eligible")
      |> require_flag(run["factory_owned"] == 1, "worktree is not factory-owned")
      |> require_flag(not active_task?(connection, run["run_id"]), "run still has an active task")
      |> require_flag(not live_workspace?(check.worktree, opts), "worktree is the live workspace")
      |> require_flag(allowed_root?(check.worktree, cleanup), "worktree is outside configured roots")
      |> require_flag(not File.exists?(check.worktree) and not registered?(run["repo_path"], check.worktree), "removed worktree readback is unsafe")
      |> require_flag(remote_identity_exact?(run), "candidate is not remotely recoverable")
      |> require_flag(recovery_readback?(connection, run, check.worktree), "no matching removal checkpoint")

    %{check | eligible: reasons == [], reasons: reasons}
  end

  defp remove_worktree(connection, run, check, opts) do
    if event?(connection, run, "WORKTREE_REMOVAL_STARTED", check.worktree) do
      remove_started_worktree(connection, run, check, opts)
    else
      with :ok <- checkpoint(opts, :before_worktree_removal_event),
           :ok <- record_event(connection, run["run_id"], "WORKTREE_REMOVAL_STARTED", identity_payload(run, check)) do
        remove_started_worktree(connection, run, check, opts)
      end
    end
  end

  defp remove_started_worktree(connection, run, check, opts) do
    if File.exists?(check.worktree) do
      with :ok <- checkpoint(opts, :before_worktree_remove),
           {:ok, _} <- git(run["repo_path"], ["worktree", "remove", check.worktree]),
           :ok <- checkpoint(opts, :after_worktree_remove) do
        record_event(connection, run["run_id"], "WORKTREE_REMOVED", %{worktree: check.worktree})
      end
    else
      :ok
    end
  end

  defp prune_worktrees(connection, run, check, opts) do
    if event?(connection, run, "WORKTREE_PRUNED", check.worktree) do
      :ok
    else
      with :ok <- checkpoint(opts, :before_worktree_prune),
           {:ok, _} <- git(run["repo_path"], ["worktree", "prune"]),
           :ok <- checkpoint(opts, :after_worktree_prune) do
        record_event(connection, run["run_id"], "WORKTREE_PRUNED", %{worktree: check.worktree})
      end
    end
  end

  defp reclaim_bazel_resumably(connection, policy, run, check, opts) do
    case latest_event_payload(connection, run["run_id"], "BAZEL_RECLAIMED", check.worktree) do
      %{"reclaim" => reclaim} ->
        {:ok, reclaim}

      _ ->
        with :ok <- ensure_event(connection, run, "BAZEL_RECLAIM_STARTED", check),
             :ok <- checkpoint(opts, :before_bazel_reclaim),
             {:ok, reclaim} <- reclaim_bazel(policy, check.worktree, run["repo_path"], opts),
             :ok <- checkpoint(opts, :after_bazel_reclaim),
             :ok <- record_event(connection, run["run_id"], "BAZEL_RECLAIMED", %{worktree: check.worktree, reclaim: reclaim}) do
          {:ok, reclaim}
        end
    end
  end

  defp mark_cleaned(connection, run, check, reclaim, opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    with :ok <- checkpoint(opts, :before_ledger_update) do
      Store.query!(connection, "UPDATE runs SET cleanup_authorized = 0, cleaned_at = ?, updated_at = ? WHERE run_id = ?", [now, now, run["run_id"]])
      checkpoint(opts, :after_ledger_update)
      record_event(connection, run["run_id"], "WORKTREE_CLEANED", %{worktree: check.worktree, reclaim: reclaim})
      :ok
    end
  end

  defp ensure_event(connection, run, type, check) do
    if event?(connection, run, type, check.worktree),
      do: :ok,
      else: record_event(connection, run["run_id"], type, identity_payload(run, check))
  end

  defp identity_payload(run, check), do: %{worktree: check.worktree, branch: run["branch"], candidate_sha: run["candidate_sha"], repo_path: expanded(run["repo_path"])}

  defp event?(connection, run, type, worktree), do: latest_event_payload(connection, run["run_id"], type, worktree) != nil

  defp latest_event_payload(connection, run_id, type, worktree) do
    RunLedger.events(connection, run_id)
    |> Enum.reverse()
    |> Enum.find_value(&matching_event_payload(&1, type, worktree))
  end

  defp matching_event_payload(%{"event_type" => type, "payload_json" => json}, type, worktree) do
    case Jason.decode(json) do
      {:ok, %{"worktree" => ^worktree} = payload} -> payload
      _ -> nil
    end
  end

  defp matching_event_payload(_event, _type, _worktree), do: nil

  defp recovery_readback?(connection, run, worktree) do
    case latest_event_payload(connection, run["run_id"], "WORKTREE_REMOVAL_STARTED", worktree) do
      %{"branch" => branch, "candidate_sha" => sha, "repo_path" => repo} ->
        branch == run["branch"] and sha == run["candidate_sha"] and repo == expanded(run["repo_path"])

      _ ->
        false
    end
  end

  defp remote_identity_exact?(run) do
    remote_branch_exact?(expanded(run["repo_path"]), run["branch"], run["candidate_sha"]) or
      (String.downcase(run["mr_state"] || "") == "merged" and present?(run["base_branch"]) and
         match?({:ok, _}, git(expanded(run["repo_path"]), ["merge-base", "--is-ancestor", run["candidate_sha"], "refs/remotes/origin/#{run["base_branch"]}"])))
  end

  defp checkpoint(opts, boundary) do
    case Keyword.get(opts, :failure_injector) do
      fun when is_function(fun, 1) -> fun.(boundary)
      _ -> :ok
    end
  end

  @doc "Reclaims eligible terminal worktrees until a new writer has capacity."
  @spec ensure_capacity(Store.connection(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_capacity(connection, policy, repo_key, opts \\ []) do
    case Capacity.snapshot(connection, policy, repo_key, opts) do
      {:ok, %{available_writer_slots: slots} = snapshot} when slots > 0 ->
        {:ok, Map.put(snapshot, :cleaned, [])}

      {:ok, _snapshot} ->
        reclaim_until_available(connection, policy, repo_key, plan(connection, policy, opts), [], opts)

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Hibernates a published writer while retaining its exact local branch."
  @spec hibernate(Store.connection(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def hibernate(connection, policy, run_id, opts \\ []) do
    hibernation = value(policy, "hibernation", %{})

    if value(hibernation, "enabled", false) do
      with {:ok, run} <- RunLedger.get(connection, run_id) do
        hibernate_run(connection, policy, hibernation, run, opts)
      end
    else
      {:ok, %{result: "SKIPPED", run_id: run_id, reason: "hibernation_disabled"}}
    end
  end

  defp reclaim_until_available(connection, policy, repo_key, candidates, cleaned, opts) do
    case Capacity.snapshot(connection, policy, repo_key, opts) do
      {:ok, %{available_writer_slots: slots} = snapshot} when slots > 0 ->
        {:ok, Map.put(snapshot, :cleaned, Enum.reverse(cleaned))}

      {:ok, _snapshot} ->
        apply_next_candidate(connection, policy, repo_key, candidates, cleaned, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_next_candidate(_connection, _policy, _repo_key, [], cleaned, _opts) do
    {:error, {:insufficient_writer_capacity, Enum.reverse(cleaned)}}
  end

  defp apply_next_candidate(connection, policy, repo_key, [candidate | rest], cleaned, opts) do
    if candidate.eligible do
      case apply(connection, policy, candidate.run_id, opts) do
        {:ok, result} -> reclaim_until_available(connection, policy, repo_key, rest, [result | cleaned], opts)
        {:error, _reason} -> reclaim_until_available(connection, policy, repo_key, rest, cleaned, opts)
      end
    else
      reclaim_until_available(connection, policy, repo_key, rest, cleaned, opts)
    end
  end

  defp hibernate_run(connection, policy, hibernation, run, opts) do
    worktree = expanded(run["worktree"])
    repo = expanded(run["repo_path"])

    cond do
      run["workspace_state"] == "HIBERNATED" and is_binary(worktree) and not File.exists?(worktree) and
          local_branch_exact?(repo, run["branch"], run["candidate_sha"]) ->
        {:ok, %{result: "ALREADY_HIBERNATED", run_id: run["run_id"], branch: run["branch"]}}

      run["state"] not in value(hibernation, "allowed_run_states", []) ->
        {:error, {:hibernation_state_not_allowed, run["state"]}}

      run["factory_owned"] != 1 ->
        {:error, :hibernation_not_factory_owned}

      active_task?(connection, run["run_id"]) ->
        {:error, :hibernation_task_still_active}

      true ->
        hibernate_materialized_run(connection, policy, hibernation, run, repo, worktree, opts)
    end
  end

  defp hibernate_materialized_run(connection, policy, hibernation, run, repo, worktree, opts) do
    cleanup = value(policy, "cleanup", %{})

    with :ok <- validate_hibernation_identity(repo, worktree, run),
         :ok <- validate_hibernation_workspace(repo, worktree, cleanup, opts),
         :ok <- validate_hibernation_candidate(repo, worktree, run),
         {:ok, _output} <- git(repo, ["worktree", "remove", worktree]),
         {:ok, _output} <- git(repo, ["worktree", "prune"]),
         :ok <- validate_retained_branch(repo, run) do
      persist_hibernation(connection, hibernation, run, repo, worktree, opts)
    end
  end

  defp validate_hibernation_identity(repo, worktree, run) do
    identity = [repo, worktree, run["branch"], run["candidate_sha"]]

    cond do
      not Enum.all?(identity, &present?/1) -> {:error, :incomplete_hibernation_identity}
      worktree == repo -> {:error, :main_checkout_protected}
      true -> :ok
    end
  end

  defp validate_hibernation_workspace(repo, worktree, cleanup, opts) do
    cond do
      not allowed_root?(worktree, cleanup) -> {:error, :hibernation_path_not_allowed}
      live_workspace?(worktree, opts) -> {:error, :hibernation_live_workspace}
      not registered?(repo, worktree) -> {:error, :hibernation_worktree_not_registered}
      not clean?(worktree) -> {:error, :hibernation_worktree_dirty}
      true -> :ok
    end
  end

  defp validate_hibernation_candidate(repo, worktree, run) do
    cond do
      not branch_matches?(worktree, run["branch"]) ->
        {:error, :hibernation_branch_mismatch}

      not head_matches?(worktree, run["candidate_sha"]) ->
        {:error, :hibernation_sha_mismatch}

      not no_unpushed_commits?(worktree) ->
        {:error, :hibernation_unpushed_commits}

      not remote_branch_exact?(repo, run["branch"], run["candidate_sha"]) ->
        {:error, :hibernation_remote_sha_mismatch}

      true ->
        :ok
    end
  end

  defp validate_retained_branch(repo, run) do
    if local_branch_exact?(repo, run["branch"], run["candidate_sha"]),
      do: :ok,
      else: {:error, :hibernation_local_branch_lost}
  end

  defp persist_hibernation(connection, hibernation, run, repo, worktree, opts) do
    reclaim = reclaim_bazel_policy(hibernation, worktree, repo, opts)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    with {:ok, _updated} <-
           RunLedger.update(connection, run["run_id"], %{
             workspace_state: "HIBERNATED",
             hibernated_at: now
           }) do
      payload = %{
        worktree: worktree,
        branch: run["branch"],
        candidate_sha: run["candidate_sha"],
        reclaim: event_reclaim(reclaim)
      }

      record_event(connection, run["run_id"], "WORKTREE_HIBERNATED", payload)

      {:ok,
       %{
         result: "HIBERNATED",
         run_id: run["run_id"],
         worktree: worktree,
         branch: run["branch"],
         candidate_sha: run["candidate_sha"],
         reclaim: reclaim
       }}
    end
  end

  defp git_reasons(repo, worktree, run) do
    if File.dir?(worktree) do
      []
      |> command_reason(registered?(repo, worktree), "path is not a registered worktree")
      |> command_reason(clean?(worktree), "worktree is dirty or has untracked files")
      |> command_reason(branch_matches?(worktree, run["branch"]), "recorded branch does not match")
      |> command_reason(head_matches?(worktree, run["candidate_sha"]), "candidate SHA does not match HEAD")
      |> command_reason(remote_recoverable?(repo, worktree, run), "candidate is not remotely recoverable")
    else
      ["worktree path no longer exists"]
    end
  end

  defp registered?(repo, worktree) do
    case git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        output
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "worktree "))
        |> Enum.map(&(String.replace_prefix(&1, "worktree ", "") |> canonical()))
        |> Enum.member?(canonical(worktree))

      _other ->
        false
    end
  end

  defp clean?(worktree), do: match?({:ok, output} when output == "", trimmed_git(worktree, ["status", "--porcelain"]))

  defp branch_matches?(worktree, branch) do
    match?({:ok, ^branch}, trimmed_git(worktree, ["branch", "--show-current"]))
  end

  defp head_matches?(worktree, sha), do: match?({:ok, ^sha}, trimmed_git(worktree, ["rev-parse", "HEAD"]))

  defp remote_recoverable?(repo, worktree, run) do
    candidate_sha = run["candidate_sha"]

    unpushed? = match?({:ok, "0"}, trimmed_git(worktree, ["rev-list", "--count", "HEAD", "--not", "--remotes=origin"]))

    remote_exact? =
      match?(
        {:ok, value} when value == candidate_sha,
        trimmed_git(repo, ["rev-parse", "refs/remotes/origin/#{run["branch"]}"])
      )

    merged? =
      String.downcase(run["mr_state"] || "") == "merged" and present?(run["base_branch"]) and
        match?({:ok, _output}, git(repo, ["merge-base", "--is-ancestor", run["candidate_sha"], "refs/remotes/origin/#{run["base_branch"]}"]))

    unpushed? and (remote_exact? or merged?)
  end

  defp no_unpushed_commits?(worktree) do
    match?({:ok, "0"}, trimmed_git(worktree, ["rev-list", "--count", "HEAD", "--not", "--remotes=origin"]))
  end

  defp local_branch_exact?(repo, branch, sha) do
    present?(repo) and present?(branch) and present?(sha) and
      match?({:ok, ^sha}, trimmed_git(repo, ["rev-parse", "refs/heads/#{branch}"]))
  end

  defp remote_branch_exact?(repo, branch, sha) do
    case trimmed_git(repo, ["ls-remote", "origin", "refs/heads/#{branch}"]) do
      {:ok, output} -> String.split(output, ~r/\s+/, trim: true) == [sha, "refs/heads/#{branch}"]
      {:error, _reason} -> false
    end
  end

  defp reclaim_bazel(policy, worktree, repo, opts) do
    cleanup = value(policy, "cleanup", %{})
    reclaim_bazel_policy(cleanup, worktree, repo, opts)
  end

  defp reclaim_bazel_policy(reclaim_policy, worktree, repo, opts) do
    runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case value(reclaim_policy, "reclaim_script") do
      script when is_binary(script) and script != "" ->
        args = [
          script,
          "--apply",
          "--targets",
          "bazel-orphans",
          "--bazel-for-sources",
          worktree,
          "--json"
        ]

        case runner.("python3", args, cd: repo, stderr_to_stdout: true) do
          {output, 0} -> Jason.decode(output)
          {output, status} -> {:error, {:bazel_reclaim_failed, status, String.trim(output)}}
        end

      _other ->
        {:ok, %{"result" => "SKIPPED", "reason" => "reclaim_script_not_configured"}}
    end
  end

  defp event_reclaim({:ok, value}), do: value
  defp event_reclaim({:error, reason}), do: %{"result" => "FAILED", "reason" => inspect(reason)}

  defp active_task?(connection, run_id) do
    row =
      Store.one!(
        connection,
        """
        SELECT COUNT(*) AS count FROM factory_tasks
        WHERE run_id = ? AND status IN ('STARTING', 'RUNNING')
        """,
        [run_id]
      )

    row["count"] > 0
  end

  defp external_state_allows?(cleanup, jira_status, mr_state) do
    jira = normalize_upper(jira_status)
    mr = normalize_lower(mr_state)
    allowed_jira = cleanup |> value("allowed_jira_statuses", []) |> Enum.map(&normalize_upper/1)
    allowed_mr = cleanup |> value("allowed_mr_states", []) |> Enum.map(&normalize_lower/1)
    jira in allowed_jira or mr in allowed_mr
  end

  defp allowed_root?(nil, _cleanup), do: false

  defp allowed_root?(worktree, cleanup) do
    Enum.any?(value(cleanup, "allowed_worktree_roots", []), fn root ->
      root = root |> Path.expand() |> canonical()
      path = canonical(worktree)
      path == root or String.starts_with?(path <> "/", root <> "/")
    end)
  end

  defp live_workspace?(worktree, opts) do
    active = opts |> Keyword.get(:active_workspace, File.cwd!()) |> Path.expand() |> canonical()
    canonical(worktree) == active
  end

  defp fresh?(nil, _now, _minutes), do: false

  defp fresh?(timestamp, now, minutes) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, value, _offset} -> DateTime.compare(value, DateTime.add(now, -minutes * 60, :second)) in [:gt, :eq]
      _other -> false
    end
  end

  defp command_reason(reasons, true, _reason), do: reasons
  defp command_reason(reasons, false, reason), do: reasons ++ [reason]
  defp require_flag(reasons, true, _reason), do: reasons
  defp require_flag(reasons, false, reason), do: reasons ++ [reason]

  defp record_event(connection, run_id, event_type, payload) do
    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [DateTime.utc_now() |> DateTime.to_iso8601(), event_type, run_id, Jason.encode!(payload)]
    )

    :ok
  end

  defp trimmed_git(path, args) do
    case git(path, args) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} = error -> error
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, args, String.trim(output)}}
    end
  end

  defp canonical(path) do
    case PathSafety.canonicalize(path) do
      {:ok, realpath} -> realpath
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp expanded(value) when is_binary(value), do: Path.expand(value)
  defp expanded(_value), do: nil
  defp normalize_upper(nil), do: nil
  defp normalize_upper(value), do: value |> to_string() |> String.split() |> Enum.join(" ") |> String.upcase()
  defp normalize_lower(nil), do: nil
  defp normalize_lower(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp v1_issue_owned?(connection, issue_key) do
    Store.one!(connection, "SELECT run_id FROM runs WHERE issue_key = ? AND execution_mode = 'TICKET_SUPERVISOR_V1' LIMIT 1", [issue_key]) != nil
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, default)
  end
end
