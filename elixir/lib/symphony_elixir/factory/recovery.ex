defmodule SymphonyElixir.Factory.Recovery do
  @moduledoc """
  Proof-bound recovery of native factory tasks and their durable runs.
  """

  alias SymphonyElixir.Factory.{
    Contract,
    Control,
    DesktopRequest,
    DesktopToolArgs,
    StageSchemas,
    Store,
    TaskLedger,
    Worktree
  }

  @readback_failure "COMPLETED_TURN_EMPTY_NO_SCHEMA_RESULT"

  @doc "Reopens an exact verifier-blocked delivery for an opted-in controller CI preflight."
  @spec resume_failed_ci_preflight(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_failed_ci_preflight(connection, config, run_id, candidate_sha)
      when is_binary(run_id) and is_binary(candidate_sha) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      run = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [run_id])
      route = get_in(config.repositories, [run && run["repo_key"]])
      verifier_key = if run, do: "#{run_id}:change-verifier:#{run["verifier_round"]}"
      verifier = if verifier_key, do: Store.one!(transaction, "SELECT * FROM factory_tasks WHERE task_key = ?", [verifier_key])

      with :ok <- require_paused_control(control, config),
           :ok <- require_ci_preflight_recovery(transaction, run, verifier, route, candidate_sha),
           {:ok, workspace} <-
             Worktree.validate_native(route, run["worktree"],
               expected_branch: run["branch"],
               expected_sha: candidate_sha,
               clean: true,
               detached: false
             ),
           true <-
             (workspace.sha == candidate_sha and Worktree.reachable?(route, candidate_sha)) or
               {:error, :ci_preflight_candidate_unreachable} do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE runs SET state = 'CI_PUSHING', failure_code = NULL, last_error = NULL, ci_preflight_sha = NULL, ci_pipeline_id = NULL, ci_pipeline_url = NULL, ci_evidence_json = NULL, ci_last_checked_at = NULL, updated_at = ? WHERE run_id = ?",
          [timestamp, run_id]
        )

        record_recovery_event(transaction, timestamp, "CI_PREFLIGHT_RECOVERED", run, verifier)
        {:ok, %{result: "CI_PREFLIGHT_RECOVERED", run_id: run_id, candidate_sha: candidate_sha}}
      end
    end)
  end

  defp require_ci_preflight_recovery(_transaction, run, verifier, route, _sha)
       when not is_map(run) or not is_map(verifier) or not is_map(route),
       do: {:error, :ci_preflight_recovery_not_proven}

  defp require_ci_preflight_recovery(transaction, run, verifier, route, sha) do
    latest = Store.one!(transaction, "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", [run["issue_key"]])

    other_active =
      Store.one!(transaction, "SELECT run_id FROM runs WHERE issue_key = ? AND state NOT IN ('READY_FOR_REVIEW','DELIVERED','AWAITING_VALIDATION','CANCELLED','FAILED') LIMIT 1", [run["issue_key"]])

    unresolved =
      Store.one!(
        transaction,
        "SELECT request_key FROM desktop_requests WHERE target_key IN (SELECT task_key FROM factory_tasks WHERE run_id = ?) AND status IN ('PENDING','CLAIMED','RECONCILE_REQUIRED') LIMIT 1",
        [run["run_id"]]
      )

    output =
      case Jason.decode(verifier["output_json"] || "") do
        {:ok, decoded} -> decoded
        _other -> %{}
      end

    if ci_run_recovery_scope?(run, route, latest, other_active, sha) and
         is_nil(unresolved) and ci_only_verifier_block?(run, verifier, output, sha),
       do: :ok,
       else: {:error, :ci_preflight_recovery_not_proven}
  end

  defp ci_run_recovery_scope?(run, route, latest, other_active, sha) do
    ci_preflight_route?(route, run) and failed_candidate_matches?(run, sha) and
      latest["run_id"] == run["run_id"] and is_nil(other_active)
  end

  defp ci_preflight_route?(route, run) do
    route["ci_preflight"] == "draft_mr" and route["path"] == run["repo_path"]
  end

  defp failed_candidate_matches?(run, sha) do
    run["kind"] == "DELIVERY" and run["state"] == "FAILED" and
      is_binary(run["failure_code"]) and String.starts_with?(run["failure_code"], "{:verification_blocked,") and
      run["candidate_sha"] == sha and is_nil(run["mr_url"])
  end

  @doc "Returns a completed repair candidate to controller-owned CI and MR delivery."
  @spec resume_controller_owned_delivery(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_controller_owned_delivery(connection, config, run_id, candidate_sha)
      when is_binary(run_id) and is_binary(candidate_sha) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      run = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [run_id])
      task = Store.one!(transaction, "SELECT * FROM factory_tasks WHERE task_key = ?", ["#{run_id}:feature-writer"])
      route = get_in(config.repositories, [run && run["repo_key"]])

      with :ok <- require_paused_control(control, config),
           :ok <- require_controller_delivery_handoff(transaction, run, task, route, candidate_sha),
           {:ok, workspace} <-
             Worktree.validate_native(route, run["worktree"],
               expected_branch: run["branch"],
               expected_sha: candidate_sha,
               clean: true,
               detached: false
             ),
           true <-
             (workspace.sha == candidate_sha and Worktree.reachable?(route, candidate_sha)) or
               {:error, :controller_delivery_candidate_unreachable} do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE runs SET state = 'CI_PUSHING', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state = 'FAILED'",
          [timestamp, run_id]
        )

        record_recovery_event(transaction, timestamp, "CONTROLLER_DELIVERY_REARMED", run, task, %{
          candidate_sha: candidate_sha,
          prior_ci_sha: run["ci_preflight_sha"],
          mr_iid: run["mr_iid"]
        })

        {:ok, %{result: "CONTROLLER_DELIVERY_REARMED", run_id: run_id, candidate_sha: candidate_sha}}
      end
    end)
  end

  defp require_controller_delivery_handoff(_connection, run, task, route, _sha)
       when not is_map(run) or not is_map(task) or not is_map(route),
       do: {:error, :controller_delivery_recovery_not_proven}

  defp require_controller_delivery_handoff(connection, run, task, route, sha) do
    latest =
      Store.one!(connection, "SELECT run_id FROM runs WHERE issue_key = ? AND kind = 'DELIVERY' ORDER BY created_at DESC, rowid DESC LIMIT 1", [run["issue_key"]])

    latest_specification =
      Store.one!(
        connection,
        "SELECT parent_run_id, spec_revision, contract_sha256 FROM runs WHERE issue_key = ? AND kind = 'SPECIFICATION' ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    other_active =
      Store.one!(connection, "SELECT run_id FROM runs WHERE issue_key = ? AND run_id != ? AND state NOT IN ('READY_FOR_REVIEW','DELIVERED','AWAITING_VALIDATION','CANCELLED','FAILED') LIMIT 1", [
        run["issue_key"],
        run["run_id"]
      ])

    request = latest_writer_request(connection, task)
    output = decode_recovery_json(task["output_json"])
    request_output = decode_recovery_json(request && request["output_json"])
    blockers = output["blockers"]
    expected_failure = if is_list(blockers), do: inspect({:writer_blocked, blockers})
    recorded_calls = request_output["completed_tool_calls"]

    proven? =
      controller_delivery_run_proven?(route, run, latest, latest_specification, other_active, sha) and
        controller_delivery_task_proven?(task, run, sha) and
        controller_delivery_blocker_proven?(run, output, blockers, expected_failure, sha) and
        controller_delivery_request_proven?(request, task, request_output, output, recorded_calls, sha)

    if proven? and require_no_unresolved_writer_requests(connection, task) == :ok,
      do: :ok,
      else: {:error, :controller_delivery_recovery_not_proven}
  end

  defp controller_delivery_run_proven?(route, run, latest, specification, other_active, sha) do
    ci_preflight_route?(route, run) and latest["run_id"] == run["run_id"] and is_nil(other_active) and
      controller_delivery_specification_proven?(specification, run) and
      controller_delivery_run_fields_proven?(run, sha)
  end

  defp controller_delivery_specification_proven?(nil, _run), do: true

  defp controller_delivery_specification_proven?(specification, run) do
    Map.take(specification, ["parent_run_id", "spec_revision", "contract_sha256"]) == %{
      "parent_run_id" => run["run_id"],
      "spec_revision" => run["spec_revision"],
      "contract_sha256" => run["contract_sha256"]
    }
  end

  defp controller_delivery_run_fields_proven?(run, sha) do
    Map.take(run, ["kind", "state", "workspace_state", "candidate_sha"]) == %{
      "kind" => "DELIVERY",
      "state" => "FAILED",
      "workspace_state" => "CODEX_NATIVE",
      "candidate_sha" => sha
    } and
      run["ci_preflight_sha"] != sha and is_binary(run["ci_preflight_sha"]) and
      is_binary(run["mr_url"]) and is_integer(run["mr_iid"]) and run["mr_iid"] > 0
  end

  defp controller_delivery_task_proven?(task, run, sha) do
    task["run_id"] == run["run_id"] and TaskLedger.source_writer?(task) and task["stage"] == "REPAIRING" and
      task["status"] == "COMPLETE" and task["workspace"] == run["worktree"] and task["workspace_sha"] == sha
  end

  defp controller_delivery_blocker_proven?(run, output, blockers, expected_failure, sha) do
    output["status"] == "BLOCKED" and match?([_ | _], blockers) and Enum.all?(blockers, &is_binary/1) and
      Enum.any?(blockers, fn blocker ->
        String.contains?(blocker, "Controller-owned delivery work remains") and
          String.contains?(blocker, "MR !#{run["mr_iid"]}") and
          String.contains?(blocker, run["ci_preflight_sha"]) and String.contains?(blocker, sha)
      end) and
      run["failure_code"] == String.slice(expected_failure, 0, 200) and run["last_error"] == expected_failure
  end

  defp controller_delivery_request_proven?(request, task, request_output, output, recorded_calls, sha) do
    is_map(request) and
      Map.take(request, ["status", "action", "thread_id", "turn_id", "verified_cwd", "verified_head_sha", "verified_project_id"]) == %{
        "status" => "SUCCEEDED",
        "action" => "FOLLOWUP",
        "thread_id" => task["thread_id"],
        "turn_id" => task["turn_id"],
        "verified_cwd" => task["workspace"],
        "verified_head_sha" => sha,
        "verified_project_id" => task["codex_project_id"]
      } and
      request_output["result"] == output and controller_delivery_readonly_calls?(recorded_calls)
  end

  defp decode_recovery_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp decode_recovery_json(_value), do: %{}

  defp controller_delivery_readonly_calls?(calls) when is_list(calls) do
    Enum.all?(calls, fn
      %{"server" => "GitLab", "tool" => tool, "status" => "completed"}
      when tool in ["get_merge_request", "get_merge_request_notes"] ->
        true

      _other ->
        false
    end)
  end

  defp controller_delivery_readonly_calls?(_calls), do: false

  @doc "Requeues a native verifier CREATE rejected before task creation by invalid arguments."
  @spec resume_rejected_native_create(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_rejected_native_create(connection, config, request_key, rejected_tool_call_id)
      when is_binary(request_key) and is_binary(rejected_tool_call_id) do
    rearm_rejected_native_create(connection, config, request_key, rejected_tool_call_id, :manual)
  end

  @doc "Retries one proven pre-creation verifier rejection once while dispatch is active."
  @spec retry_rejected_native_create(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def retry_rejected_native_create(connection, config, request_key) do
    case DesktopRequest.get(connection, request_key) do
      {:ok, %{"rejected_tool_call_id" => call_id}} when is_binary(call_id) ->
        rearm_rejected_native_create(connection, config, request_key, call_id, :automatic)

      _other ->
        {:error, :rejected_create_not_proven}
    end
  end

  defp rearm_rejected_native_create(connection, config, request_key, rejected_tool_call_id, mode) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = if request, do: Store.one!(transaction, "SELECT * FROM factory_tasks WHERE task_key = ?", [request["target_key"]])
      run = if task, do: Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [task["run_id"]])
      route = get_in(config.repositories, [run && run["repo_key"]])

      with :ok <- require_rejected_create_control(control, config, mode),
           :ok <- require_rejected_native_create(transaction, request, task, run, route, rejected_tool_call_id),
           :ok <- require_rejected_create_retry(transaction, request, rejected_tool_call_id, mode),
           true <- Worktree.reachable?(route, run["candidate_sha"]) or {:error, :rejected_create_candidate_unreachable} do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE desktop_requests SET status = 'PENDING', claimed_at = NULL, failure_code = NULL, updated_at = ? WHERE request_key = ? AND status = 'RECONCILE_REQUIRED'",
          [timestamp, request_key]
        )

        reset_rejected_create_receipt(transaction, request_key, mode)

        TaskLedger.update(transaction, task["task_key"], %{failure_code: nil})

        record_recovery_event(transaction, timestamp, "REJECTED_NATIVE_CREATE_REARMED", run, task, %{
          request_key: request_key,
          rejected_tool_call_id: rejected_tool_call_id,
          candidate_sha: run["candidate_sha"],
          recovery_mode: mode
        })

        {:ok, %{result: "REJECTED_NATIVE_CREATE_REARMED", request_key: request_key, task_key: task["task_key"]}}
      end
    end)
  end

  defp reset_rejected_create_receipt(transaction, request_key, :automatic) do
    Store.query!(transaction, "UPDATE desktop_requests SET rejected_tool_call_id = NULL WHERE request_key = ?", [request_key])
  end

  defp reset_rejected_create_receipt(_transaction, _request_key, :manual), do: :ok

  defp require_rejected_create_control(control, config, :manual), do: require_paused_control(control, config)

  defp require_rejected_create_control(control, config, :automatic) do
    if control["status"] == "ACTIVE" and control["dispatcher_id"] == config.dispatcher_id,
      do: :ok,
      else: {:error, :recovery_requires_active_control}
  end

  defp require_rejected_create_retry(_connection, _request, _call_id, :manual), do: :ok

  defp require_rejected_create_retry(connection, request, call_id, :automatic) do
    rejection =
      Store.one!(
        connection,
        "SELECT id FROM events WHERE event_type = 'NATIVE_CREATE_PRECREATION_REJECTED' AND json_extract(payload_json, '$.request_key') = ? AND json_extract(payload_json, '$.rejected_tool_call_id') = ? LIMIT 1",
        [request["request_key"], call_id]
      )

    prior_retry =
      Store.one!(
        connection,
        "SELECT id FROM events WHERE event_type = 'REJECTED_NATIVE_CREATE_REARMED' AND json_extract(payload_json, '$.request_key') = ? LIMIT 1",
        [request["request_key"]]
      )

    with true <- not is_nil(rejection) or {:error, :rejected_create_not_proven},
         true <- is_nil(prior_retry) or {:error, :rejected_create_retry_exhausted},
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt},
         {:ok, _arguments} <- DesktopToolArgs.create_thread(request) do
      :ok
    end
  end

  defp require_rejected_native_create(_connection, request, task, run, route, _call_id)
       when not is_map(request) or not is_map(task) or not is_map(run) or not is_map(route),
       do: {:error, :rejected_create_not_proven}

  defp require_rejected_native_create(connection, request, task, run, route, call_id) do
    metadata = decode_recovery_json(request["metadata_json"])

    latest =
      Store.one!(connection, "SELECT run_id FROM runs WHERE issue_key = ? AND kind = 'DELIVERY' ORDER BY created_at DESC, rowid DESC LIMIT 1", [run["issue_key"]])

    other_create =
      Store.one!(connection, "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'CREATE' AND request_key != ? LIMIT 1", [
        task["task_key"],
        request["request_key"]
      ])

    other_unresolved =
      Store.one!(
        connection,
        "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND request_key != ? AND status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED') LIMIT 1",
        [task["task_key"], request["request_key"]]
      )

    proven? =
      rejected_create_request_proven?(request, call_id) and
        rejected_create_task_proven?(task, request, run) and
        rejected_create_run_proven?(run, route, request, latest, other_create, other_unresolved, metadata)

    if proven?, do: :ok, else: {:error, :rejected_create_not_proven}
  end

  defp rejected_create_request_proven?(request, call_id) do
    Regex.match?(~r/\Aexec-[0-9a-f-]+\z/, call_id) and
      request["rejected_tool_call_id"] == call_id and
      Map.take(request, ["target_kind", "action", "status", "failure_code", "thread_id", "turn_id", "output_json", "verified_project_id", "verified_cwd", "verified_head_sha"]) == %{
        "target_kind" => "TASK",
        "action" => "CREATE",
        "status" => "RECONCILE_REQUIRED",
        "failure_code" => "CREATE_THREAD_INVALID_ARGUMENTS",
        "thread_id" => nil,
        "turn_id" => nil,
        "output_json" => nil,
        "verified_project_id" => nil,
        "verified_cwd" => nil,
        "verified_head_sha" => nil
      } and
      is_binary(request["claimed_at"]) and
      String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n")
  end

  defp rejected_create_task_proven?(task, request, run) do
    task["task_key"] == request["target_key"] and task["run_id"] == run["run_id"] and
      task["role"] == "change-verifier" and task["stage"] == "VERIFYING" and
      task["status"] == "WAITING_FOR_BROKER" and is_nil(task["thread_id"]) and is_nil(task["turn_id"]) and
      task["workspace_sha"] == run["candidate_sha"] and task["codex_project_id"] == request["codex_project_id"]
  end

  defp rejected_create_run_proven?(run, route, request, latest, other_create, other_unresolved, metadata) do
    metadata["workspace_mode"] == "CODEX_NATIVE" and metadata["expected_sha"] == run["candidate_sha"] and
      route["codex_project_id"] == request["codex_project_id"] and route["path"] == run["repo_path"] and
      Map.take(run, ["kind", "state", "workspace_state"]) == %{
        "kind" => "DELIVERY",
        "state" => "VERIFYING",
        "workspace_state" => "CODEX_NATIVE"
      } and
      latest["run_id"] == run["run_id"] and is_nil(other_create) and is_nil(other_unresolved)
  end

  @doc "Rearms a failed native writer on a run-specific branch when a prior failed run owns the stable branch."
  @spec resume_native_branch_sha_mismatch(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_native_branch_sha_mismatch(connection, config, run_id, prior_run_id)
      when is_binary(run_id) and is_binary(prior_run_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      run = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [run_id])
      prior = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [prior_run_id])
      current_task = task_for_run(transaction, run)
      prior_task = task_for_run(transaction, prior)
      route = get_in(config.repositories, [run && run["repo_key"]])

      with :ok <- require_paused_control(control, config),
           :ok <- require_native_branch_mismatch_recovery(transaction, run, prior, current_task, prior_task, route),
           {:ok, _current_workspace} <-
             Worktree.validate_native(route, current_task["workspace"],
               clean: true,
               detached: true,
               expected_sha: current_task["workspace_sha"]
             ),
           {:ok, prior_workspace} <-
             Worktree.validate_native(route, prior_task["workspace"],
               clean: false,
               detached: false,
               expected_branch: run["branch"]
             ),
           true <- prior_workspace.sha == prior["candidate_sha"] or {:error, :native_branch_owner_changed},
           {:ok, branch} <- Worktree.branch_for_run(route, run["branch"], run_id) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE runs SET state = 'WRITING', branch = ?, worktree = ?, candidate_sha = NULL, workspace_state = 'CODEX_NATIVE', implementation_iteration = 0, verifier_round = 0, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ?",
          [branch, current_task["workspace"], timestamp, run_id]
        )

        TaskLedger.update(transaction, current_task["task_key"], %{
          stage: "WRITING",
          status: "RETRY_PENDING",
          failure_code: nil,
          output_json: nil
        })

        record_recovery_event(transaction, timestamp, "NATIVE_BRANCH_MISMATCH_RECOVERED", run, current_task, %{
          run_id: run_id,
          prior_run_id: prior_run_id,
          prior_task_key: prior_task["task_key"],
          prior_candidate_sha: prior["candidate_sha"],
          previous_branch: run["branch"],
          new_branch: branch,
          reused_thread_id: current_task["thread_id"]
        })

        {:ok, %{result: "NATIVE_BRANCH_MISMATCH_RECOVERED", run_id: run_id, branch: branch}}
      else
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc "Reattaches one completed native bootstrap to the exact branch already recorded for its failed writer."
  @spec recover_native_bootstrap(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def recover_native_bootstrap(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)
      route = get_in(config.repositories, [run && run["repo_key"]])

      with :ok <- require_paused_control(control, config),
           :ok <- require_native_bootstrap_recovery(transaction, request, task, run, route, completed_turn_id),
           {:ok, workspace} <- reattach_native_bootstrap(route, task, run) do
        recover_native_bootstrap_records(transaction, request, task, run, workspace)
      end
    end)
  end

  defp reattach_native_bootstrap(route, task, run) do
    opts = [expected_sha: task["workspace_sha"], clean: true]

    case Worktree.validate_native(route, task["workspace"], Keyword.put(opts, :detached, true)) do
      {:ok, _detached_workspace} ->
        Worktree.attach_native_branch(route, task["workspace"], run["branch"], task["workspace_sha"])

      {:error, :native_worktree_not_detached} ->
        Worktree.validate_native(
          route,
          task["workspace"],
          Keyword.merge(opts, detached: false, expected_branch: run["branch"])
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp require_native_bootstrap_recovery(_connection, request, task, run, route, _turn_id)
       when not is_map(request) or not is_map(task) or not is_map(run) or not is_map(route),
       do: {:error, :native_bootstrap_recovery_not_proven}

  defp require_native_bootstrap_recovery(connection, request, task, run, route, completed_turn_id) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    other_active =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? AND run_id != ? AND state NOT IN ('READY_FOR_REVIEW','DELIVERED','AWAITING_VALIDATION','CANCELLED','FAILED') LIMIT 1",
        [run["issue_key"], run["run_id"]]
      )

    other_unresolved =
      Store.one!(
        connection,
        "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND request_key != ? AND status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED') LIMIT 1",
        [task["task_key"], request["request_key"]]
      )

    create_requests =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'CREATE'",
        [task["task_key"]]
      )

    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, output} <- Jason.decode(request["output_json"] || ""),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         :ok <- require_unique_bootstrap_owner(latest, other_active, other_unresolved, create_requests, run),
         :ok <-
           require_native_bootstrap_payload(
             request,
             task,
             run,
             route,
             metadata,
             output,
             schema,
             completed_turn_id
           ),
         :ok <- require_native_bootstrap_failed_state(task, run) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :native_bootstrap_recovery_not_proven}
    end
  end

  defp require_unique_bootstrap_owner(latest, other_active, other_unresolved, create_requests, run) do
    cond do
      latest["run_id"] != run["run_id"] -> {:error, :native_bootstrap_recovery_not_latest}
      not is_nil(other_active) -> {:error, :native_bootstrap_recovery_has_other_active_run}
      not is_nil(other_unresolved) -> {:error, :native_bootstrap_recovery_has_unresolved_request}
      create_requests["count"] != 1 -> {:error, :native_bootstrap_recovery_duplicate_create}
      true -> :ok
    end
  end

  defp require_native_bootstrap_payload(request, task, run, route, metadata, output, schema, completed_turn_id) do
    if native_bootstrap_request_matches?(request, task, run, route, completed_turn_id) and
         native_bootstrap_metadata_matches?(metadata, task) and
         native_bootstrap_output_matches?(output, schema) and
         native_bootstrap_task_matches?(task, run, route, request) and
         native_bootstrap_run_matches?(run, route),
       do: :ok,
       else: {:error, :native_bootstrap_route_not_proven}
  end

  defp native_bootstrap_request_matches?(request, task, run, route, completed_turn_id) do
    run_id = run["run_id"]
    requested_branch = request["branch"]
    expected_run_branch = "#{requested_branch}-#{String.slice(run_id, 0, 8)}"

    request_fields = %{
      "target_kind" => "TASK",
      "target_key" => task["task_key"],
      "action" => "CREATE",
      "status" => "SUCCEEDED",
      "turn_id" => completed_turn_id,
      "thread_id" => task["thread_id"],
      "verified_project_id" => route["codex_project_id"],
      "codex_project_id" => route["codex_project_id"],
      "cwd" => Path.expand(route["path"]),
      "verified_cwd" => task["workspace"],
      "verified_head_sha" => task["workspace_sha"],
      "base_branch" => route["base_branch"],
      "model" => task["model"],
      "reasoning_effort" => task["reasoning_effort"]
    }

    Map.take(request, Map.keys(request_fields)) == request_fields and
      String.ends_with?(request["request_key"], ":bootstrap") and
      String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n") and
      request["prompt"] =~ "Factory workspace bootstrap ID: #{request["request_key"]}" and
      request["branch"] != run["branch"] and run["branch"] == expected_run_branch
  end

  defp native_bootstrap_metadata_matches?(metadata, task) do
    metadata_fields = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => task["workspace_sha"],
      "required_tool_calls" => []
    }

    Map.take(metadata, Map.keys(metadata_fields)) == metadata_fields and
      is_binary(metadata["stage_prompt_sha256"]) and byte_size(metadata["stage_prompt_sha256"]) == 64
  end

  defp native_bootstrap_output_matches?(output, schema) do
    output == %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []} and
      schema == native_bootstrap_schema()
  end

  defp native_bootstrap_task_matches?(task, run, route, request) do
    TaskLedger.source_writer?(task) and task["run_id"] == run["run_id"] and
      task["stage"] == "WRITING" and task["codex_project_id"] == route["codex_project_id"] and
      task["workspace"] == run["worktree"] and task["workspace_sha"] == request["verified_head_sha"]
  end

  defp native_bootstrap_run_matches?(run, route) do
    run["kind"] == "DELIVERY" and run["repo_key"] == "grail" and run["repo_path"] == route["path"] and
      run["base_branch"] == route["base_branch"]
  end

  defp native_bootstrap_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["status"],
      "properties" => %{"status" => %{"type" => "string", "enum" => ["WORKSPACE_READY"]}}
    }
  end

  defp native_bootstrap_failure?(task, run) do
    native_bootstrap_task_failed?(task) and native_bootstrap_run_failed?(run, task)
  end

  defp native_bootstrap_task_failed?(task) do
    task["status"] == "FAILED" and is_nil(task["turn_id"]) and is_nil(task["output_json"]) and
      is_binary(task["failure_code"]) and String.contains?(task["failure_code"], "native_bootstrap_route_mismatch")
  end

  defp native_bootstrap_run_failed?(run, task) do
    run["state"] == "FAILED" and is_binary(run["failure_code"]) and
      String.contains?(run["failure_code"], "native_bootstrap_route_mismatch") and
      run["workspace_state"] == "CODEX_NATIVE" and run["worktree"] == task["workspace"] and
      is_nil(run["candidate_sha"]) and is_nil(run["mr_url"])
  end

  defp require_native_bootstrap_failed_state(task, run) do
    if native_bootstrap_failure?(task, run),
      do: :ok,
      else: {:error, :native_bootstrap_failure_not_proven}
  end

  defp recover_native_bootstrap_records(connection, request, task, run, workspace) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'RETRY_PENDING', failure_code = NULL, workspace = ?, workspace_sha = ?, updated_at = ? WHERE task_key = ? AND status = 'FAILED'",
      [workspace.path, workspace.sha, timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "UPDATE runs SET state = 'WRITING', worktree = ?, workspace_state = 'CODEX_NATIVE', implementation_iteration = 1, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state = 'FAILED'",
      [workspace.path, timestamp, run["run_id"]]
    )

    record_recovery_event(connection, timestamp, "NATIVE_BOOTSTRAP_RECOVERED", run, task, %{
      request_key: request["request_key"],
      completed_turn_id: request["turn_id"],
      branch: run["branch"],
      workspace_sha: workspace.sha
    })

    {:ok, %{result: "NATIVE_BOOTSTRAP_RECOVERED", run_id: run["run_id"], task_key: task["task_key"]}}
  end

  defp require_native_branch_mismatch_recovery(_transaction, run, prior, current_task, prior_task, route)
       when not is_map(run) or not is_map(prior) or not is_map(current_task) or not is_map(prior_task) or
              not is_map(route),
       do: {:error, :native_branch_mismatch_recovery_not_proven}

  defp require_native_branch_mismatch_recovery(transaction, run, prior, current_task, prior_task, route) do
    latest = Store.one!(transaction, "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", [run["issue_key"]])

    unresolved =
      Store.one!(transaction, "SELECT request_key FROM desktop_requests WHERE target_key IN (?, ?) AND status IN ('PENDING','CLAIMED','RECONCILE_REQUIRED') LIMIT 1", [
        current_task["task_key"],
        prior_task["task_key"]
      ])

    snapshot = decode_json(run["snapshot_json"], %{})
    contract = bound_delivery_contract(run)

    with true <-
           (is_map(contract) and run["contract_sha256"] == contract.sha256) or
             {:error, :native_branch_mismatch_contract_digest_mismatch},
         true <-
           latest["run_id"] == run["run_id"] or {:error, :native_branch_mismatch_recovery_not_latest},
         true <- is_nil(unresolved) or {:error, :native_branch_mismatch_recovery_has_pending_request},
         true <- native_mismatch_run_pair?(run, prior, route) or {:error, :native_branch_mismatch_run_pair_invalid},
         true <-
           native_mismatch_tasks?(run, prior, current_task, prior_task, route) or
             {:error, :native_branch_mismatch_task_binding_invalid},
         true <-
           Contract.authorized?(snapshot, contract) or
             {:error, :native_branch_mismatch_contract_not_authorized} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp bound_delivery_contract(%{
         "issue_key" => issue_key,
         "spec_revision" => revision,
         "contract_markdown" => markdown
       })
       when is_binary(issue_key) and is_integer(revision) and is_binary(markdown) do
    Contract.bind(issue_key, revision, markdown)
  end

  defp bound_delivery_contract(_run), do: nil

  defp native_mismatch_run_pair?(run, prior, route) do
    same_route = same_delivery_route?(run, prior, route)
    newer_delivery = newer_failed_delivery?(run, prior)
    matching_failure = native_branch_failure_pair?(run, prior)
    same_route and newer_delivery and matching_failure
  end

  defp same_delivery_route?(run, prior, route) do
    route_matches = route["path"] == run["repo_path"]

    identity_matches =
      Enum.all?(["issue_key", "repo_key", "repo_path", "base_branch", "branch"], &(run[&1] == prior[&1]))

    delivery_runs = run["kind"] == "DELIVERY" and prior["kind"] == "DELIVERY"
    route_matches and identity_matches and delivery_runs
  end

  defp newer_failed_delivery?(run, prior) do
    run["state"] == "FAILED" and prior["state"] == "FAILED" and
      is_integer(run["spec_revision"]) and is_integer(prior["spec_revision"]) and
      run["spec_revision"] > prior["spec_revision"] and is_nil(run["candidate_sha"]) and
      is_binary(prior["candidate_sha"]) and is_nil(run["mr_url"]) and is_nil(prior["mr_url"])
  end

  defp native_branch_failure_pair?(run, prior) do
    String.contains?(run["failure_code"] || "", "native_branch_sha_mismatch") and
      String.starts_with?(prior["failure_code"] || "", "{:writer_blocked,")
  end

  defp native_mismatch_tasks?(run, prior, current_task, prior_task, route) do
    current_binding = failed_bootstrap_task?(run, current_task, prior, route)
    prior_binding = completed_prior_writer?(prior, prior_task, route)
    mismatch_binding = mismatch_mentions_old_branch?(run, prior, current_task)
    current_binding and prior_binding and mismatch_binding
  end

  defp failed_bootstrap_task?(run, task, prior, route) do
    is_binary(task["workspace_sha"]) and is_binary(task["thread_id"]) and
      is_binary(task["workspace"]) and TaskLedger.source_writer?(task) and
      task["run_id"] == run["run_id"] and task["status"] == "FAILED" and is_nil(task["turn_id"]) and
      task["codex_project_id"] == route["codex_project_id"] and
      task["workspace_sha"] != prior["candidate_sha"]
  end

  defp completed_prior_writer?(prior, task, route) do
    TaskLedger.source_writer?(task) and task["run_id"] == prior["run_id"] and
      task["status"] == "COMPLETE" and is_binary(task["turn_id"]) and
      is_binary(task["thread_id"]) and task["workspace"] == prior["worktree"] and
      task["workspace_sha"] == prior["candidate_sha"] and task["codex_project_id"] == route["codex_project_id"]
  end

  defp mismatch_mentions_old_branch?(run, prior, task) do
    mismatch = task["failure_code"] || ""

    is_binary(mismatch) and is_binary(run["branch"]) and is_binary(prior["candidate_sha"]) and
      String.contains?(mismatch, run["branch"]) and String.contains?(mismatch, task["workspace_sha"]) and
      String.contains?(mismatch, prior["candidate_sha"])
  end

  defp ci_only_verifier_block?(run, verifier, output, sha) do
    valid_output? = StageSchemas.validate(output, StageSchemas.for_stage(:change_verifier)) == :ok

    verifier["run_id"] == run["run_id"] and verifier["role"] == "change-verifier" and
      verifier["status"] == "COMPLETE" and valid_output? and output["status"] == "BLOCK" and
      output["candidate_sha"] == sha and only_missing_ci?(output)
  end

  defp only_missing_ci?(output) do
    findings = output["findings"]
    checks = output["checks"]

    match?([_], findings) and String.contains?(hd(findings), "no candidate CI result was available") and
      Enum.any?(checks, &String.starts_with?(&1, "NOT_RUN: candidate CI")) and
      Enum.all?(checks, &(String.starts_with?(&1, "PASS:") or String.starts_with?(&1, "NOT_RUN:")))
  end

  @doc "Adopts a completed author draft rejected only for carrying forward the prior revision."
  @spec adopt_failed_specification_revision(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def adopt_failed_specification_revision(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_completed_recovery_request(transaction, request, task, run, completed_turn_id),
           :ok <- require_failed_specification_revision(run, task),
           {:ok, %{contract: contract, output: output, manual_required: required}} <-
             completed_specification_contract(request, task, run) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE runs SET state = 'SPEC_WRITING', contract_markdown = ?, contract_sha256 = ?, manual_validation_required = ?, risk = ?, risk_signals_json = ?, repair_findings_json = '[]', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ?",
          [contract.markdown, contract.sha256, if(required, do: 1, else: 0), output["risk"], Jason.encode!(output["risk_signals"]), timestamp, run["run_id"]]
        )

        Store.query!(transaction, "UPDATE factory_tasks SET status = 'CONSUMED', updated_at = ? WHERE task_key = ?", [timestamp, task["task_key"]])
        record_recovery_event(transaction, timestamp, "SPECIFICATION_REVISION_ADOPTED", run, task)
        {:ok, %{result: "SPECIFICATION_REVISION_ADOPTED", run_id: run["run_id"], task_key: task["task_key"], contract_sha256: contract.sha256}}
      end
    end)
  end

  defp require_failed_specification_revision(run, task) do
    expected_run = %{
      "kind" => "SPECIFICATION",
      "state" => "FAILED",
      "failure_code" => ":contract_revision_mismatch",
      "contract_markdown" => nil
    }

    expected_task = %{"role" => "specification-author", "status" => "COMPLETE"}

    if Map.take(run, Map.keys(expected_run)) == expected_run and
         Map.take(task, Map.keys(expected_task)) == expected_task,
       do: :ok,
       else: {:error, :specification_revision_not_recoverable}
  end

  defp completed_specification_contract(request, task, run) do
    with {:ok, snapshot} <- Jason.decode(run["snapshot_json"]),
         true <- run["spec_revision"] == Contract.next_revision(snapshot) or {:error, :specification_revision_changed},
         {:ok, %{"result" => output, "completed_tool_calls" => []}} <- Jason.decode(request["output_json"]),
         {:ok, ^output} <- Jason.decode(task["output_json"]),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:specification_author)),
         %{"status" => "DRAFTED", "contract_markdown" => markdown} <- output,
         {:ok, normalized} <- Contract.normalize_draft_revision(markdown, run["spec_revision"]),
         true <-
           Contract.declared_revision(normalized) == {:ok, run["spec_revision"]} or
             {:error, :specification_revision_not_recoverable},
         {:ok, required} <- Contract.manual_validation_required(normalized),
         true <- required == output["manual_validation_required"] or {:error, :manual_validation_decision_mismatch} do
      {:ok, %{contract: Contract.bind(run["issue_key"], run["spec_revision"], normalized), output: output, manual_required: required}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :specification_revision_not_recoverable}
    end
  end

  @doc "Reopens a failed repair slice only when its exact controller commit can be adopted."
  @spec adopt_failed_native_repair_slice(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def adopt_failed_native_repair_slice(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_completed_recovery_request(transaction, request, task, run, completed_turn_id),
           :ok <- require_failed_native_repair(run, task),
           {:ok, output} <- completed_repair_output(request, task),
           {:ok, sha} <- verify_existing_repair_commit(run, task, output) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        Store.query!(transaction, "UPDATE runs SET state = 'REPAIRING', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ?", [timestamp, run["run_id"]])
        record_recovery_event(transaction, timestamp, "NATIVE_REPAIR_SLICE_ADOPTION_READY", run, task)
        {:ok, %{result: "NATIVE_REPAIR_SLICE_ADOPTION_READY", run_id: run["run_id"], task_key: task["task_key"], candidate_sha: sha}}
      end
    end)
  end

  defp require_failed_native_repair(run, task) do
    expected_run = %{
      "kind" => "DELIVERY",
      "state" => "FAILED",
      "failure_code" => ":native_writer_slice_state_changed",
      "workspace_state" => "CODEX_NATIVE",
      "mr_url" => nil
    }

    expected_task = %{"stage" => "REPAIRING", "status" => "COMPLETE"}

    if Map.take(run, Map.keys(expected_run)) == expected_run and
         Map.take(task, Map.keys(expected_task)) == expected_task and
         run["code_repair_round"] > 0 and TaskLedger.source_writer?(task),
       do: :ok,
       else: {:error, :native_repair_not_recoverable}
  end

  defp completed_repair_output(request, task) do
    with {:ok, %{"result" => output, "completed_tool_calls" => []}} <- Jason.decode(request["output_json"]),
         {:ok, ^output} <- Jason.decode(task["output_json"]),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:native_feature_writer)),
         true <- output["status"] in ["CONTINUE", "COMPLETE"] do
      {:ok, output}
    else
      _other -> {:error, :native_repair_not_recoverable}
    end
  end

  defp verify_existing_repair_commit(run, task, output) do
    route = %{"path" => run["repo_path"]}

    with true <-
           (task["workspace_sha"] == run["candidate_sha"] and task["workspace"] == run["worktree"]) or
             {:error, :native_repair_workspace_mismatch},
         {:ok, workspace} <-
           Worktree.validate_native(route, run["worktree"],
             expected_branch: run["branch"],
             clean: true,
             detached: false
           ),
         true <- workspace.sha != run["candidate_sha"] or {:error, :native_repair_commit_missing},
         {:ok, %{sha: sha}} <-
           Worktree.commit_native_slice(
             route,
             run["worktree"],
             run["branch"],
             run["candidate_sha"],
             output["changed_paths"],
             output["commit_message"]
           ),
         true <- sha == workspace.sha or {:error, :native_repair_commit_changed} do
      {:ok, sha}
    end
  end

  defp require_completed_recovery_request(_connection, request, task, run, _turn_id)
       when not is_map(request) or not is_map(task) or not is_map(run),
       do: {:error, :completed_recovery_request_not_proven}

  defp require_completed_recovery_request(connection, request, task, run, completed_turn_id) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- completed_request_identity?(request, task, completed_turn_id),
         true <- completed_request_route?(request, task, run, latest, metadata),
         :ok <- require_no_other_unresolved_request(connection, request) do
      :ok
    else
      _other -> {:error, :completed_recovery_request_not_proven}
    end
  end

  defp completed_request_identity?(request, task, completed_turn_id) do
    expected = %{
      "status" => "SUCCEEDED",
      "action" => "FOLLOWUP",
      "target_kind" => "TASK",
      "target_key" => task["task_key"],
      "turn_id" => completed_turn_id,
      "thread_id" => task["thread_id"],
      "existing_thread_id" => task["thread_id"]
    }

    Map.take(request, Map.keys(expected)) == expected and task["turn_id"] == completed_turn_id and
      is_binary(request["prompt"]) and
      String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n")
  end

  defp completed_request_route?(request, task, run, latest, metadata) do
    expected = %{
      "verified_project_id" => task["codex_project_id"],
      "codex_project_id" => task["codex_project_id"],
      "verified_cwd" => task["workspace"],
      "cwd" => task["workspace"],
      "verified_head_sha" => task["workspace_sha"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"],
      "model" => task["model"],
      "reasoning_effort" => task["reasoning_effort"]
    }

    is_map(latest) and Map.take(request, Map.keys(expected)) == expected and
      metadata["workspace_mode"] == "CODEX_NATIVE" and
      metadata["stage_prompt_sha256"] == task["prompt_sha256"] and
      task["run_id"] == run["run_id"] and latest["run_id"] == run["run_id"]
  end

  defp record_recovery_event(connection, timestamp, event_type, run, task, details \\ %{}) do
    Store.query!(connection, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)", [
      timestamp,
      event_type,
      run["run_id"],
      Jason.encode!(Map.merge(%{task_key: task["task_key"], turn_id: task["turn_id"]}, details))
    ])
  end

  @doc "Restores the exact failed author and run to await broker completion."
  @spec restore_specification(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def restore_specification(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_request(request, completed_turn_id),
           :ok <- require_task(task, request),
           :ok <- require_run(transaction, run, task),
           :ok <- require_no_other_unresolved_request(transaction, request) do
        restore(transaction, request, task, run, completed_turn_id)
      end
    end)
  end

  @doc "Restores an approval-blocked native writer after its completed turn is read back."
  @spec restore_native_writer(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def restore_native_writer(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_native_writer_request(request, task, run, completed_turn_id),
           :ok <- require_native_writer_run(transaction, run, task),
           :ok <- require_no_other_unresolved_request(transaction, request),
           {:ok, workspace} <-
             Worktree.attach_native_branch(
               %{"path" => run["repo_path"]},
               task["workspace"],
               run["branch"],
               task["workspace_sha"]
             ) do
        restore_native_writer_records(transaction, request, task, run, workspace, completed_turn_id)
      end
    end)
  end

  @doc "Resumes a stopped native writer without discarding its uncommitted source edits."
  @spec resume_interrupted_native_writer(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_interrupted_native_writer(connection, config, request_key, interrupted_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_interrupted_writer_binding(transaction, request, task, run, interrupted_turn_id),
           :ok <- require_interrupted_writer_run(transaction, run, task),
           :ok <- require_no_other_unresolved_request(transaction, request),
           {:ok, %{path: path, sha: sha}} <-
             Worktree.validate_native(%{"path" => run["repo_path"]}, task["workspace"],
               expected_branch: run["branch"],
               expected_sha: task["workspace_sha"],
               clean: false,
               detached: false
             ),
           true <-
             (path == run["worktree"] and sha == task["workspace_sha"]) or
               {:error, :native_workspace_route_mismatch} do
        resume_interrupted_writer_records(transaction, request, task, run, interrupted_turn_id)
      end
    end)
  end

  @doc "Rearms one authentication-failed verifier in its existing detached Codex task."
  @spec resume_authentication_failed_verifier(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_authentication_failed_verifier(connection, config, request_key, failed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_authentication_failed_verifier(transaction, request, task, run, failed_turn_id),
           :ok <- require_no_other_unresolved_request(transaction, request),
           {:ok, %{path: path, sha: sha}} <-
             Worktree.validate_native(%{"path" => run["repo_path"]}, task["workspace"],
               expected_sha: run["candidate_sha"],
               clean: true,
               detached: true
             ),
           true <-
             (path == task["workspace"] and sha == run["candidate_sha"]) or
               {:error, :verifier_workspace_route_mismatch} do
        rearm_authentication_failed_verifier(transaction, request, task, run, failed_turn_id)
      end
    end)
  end

  @doc "Rearms one verifier after its previously uncertain CREATE is proven by a completed bootstrap."
  @spec recover_native_verifier_create(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def recover_native_verifier_create(connection, config, request_key, bootstrap_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)
      route = get_in(config.repositories, [run && run["repo_key"]])

      with :ok <- require_paused_control(control, config),
           :ok <-
             require_native_verifier_create_recovery(
               transaction,
               request,
               task,
               run,
               route,
               bootstrap_turn_id
             ),
           {:ok, workspace} <-
             Worktree.validate_native(route, task["workspace"],
               expected_sha: run["candidate_sha"],
               clean: true,
               detached: true
             ),
           true <-
             (workspace.path == task["workspace"] and workspace.sha == run["candidate_sha"]) or
               {:error, :verifier_workspace_route_mismatch} do
        recover_native_verifier_create_records(transaction, request, task, run)
      end
    end)
  end

  defp require_native_verifier_create_recovery(_connection, request, task, run, route, _turn_id)
       when not is_map(request) or not is_map(task) or not is_map(run) or not is_map(route),
       do: {:error, :native_verifier_create_recovery_not_proven}

  defp require_native_verifier_create_recovery(connection, request, task, run, route, bootstrap_turn_id) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    other_active =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? AND run_id != ? AND state NOT IN ('READY_FOR_REVIEW','DELIVERED','AWAITING_VALIDATION','CANCELLED','FAILED') LIMIT 1",
        [run["issue_key"], run["run_id"]]
      )

    other_unresolved =
      Store.one!(
        connection,
        "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND request_key != ? AND status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED') LIMIT 1",
        [task["task_key"], request["request_key"]]
      )

    create_requests =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'CREATE'",
        [task["task_key"]]
      )

    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, output} <- Jason.decode(request["output_json"] || ""),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- latest["run_id"] == run["run_id"],
         true <- is_nil(other_active),
         true <- is_nil(other_unresolved),
         true <- create_requests["count"] == 1,
         :ok <- native_verifier_create_binding(request, task, run, route, metadata, output, schema, bootstrap_turn_id),
         :ok <- native_verifier_create_run_binding(run, task, request),
         :ok <- native_verifier_create_task_binding(task, run, route) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :native_verifier_create_recovery_not_proven}
    end
  end

  defp native_verifier_create_binding(request, task, run, route, metadata, output, schema, bootstrap_turn_id) do
    expected_request = %{
      "target_kind" => "TASK",
      "target_key" => task["task_key"],
      "action" => "CREATE",
      "status" => "SUCCEEDED",
      "failure_code" => nil,
      "turn_id" => bootstrap_turn_id,
      "thread_id" => task["thread_id"],
      "codex_project_id" => route["codex_project_id"],
      "verified_project_id" => route["codex_project_id"],
      "verified_cwd" => task["workspace"],
      "verified_head_sha" => run["candidate_sha"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"]
    }

    expected_metadata = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => run["candidate_sha"],
      "required_tool_calls" => []
    }

    valid? =
      native_verifier_bootstrap_proven?(request, output, schema) and
        Map.take(request, Map.keys(expected_request)) == expected_request and
        Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata and
        is_binary(metadata["stage_prompt_sha256"]) and byte_size(metadata["stage_prompt_sha256"]) == 64

    if valid?, do: :ok, else: {:error, :native_verifier_create_recovery_not_proven}
  end

  defp native_verifier_bootstrap_proven?(request, output, schema) do
    output == %{"result" => %{"status" => "WORKSPACE_READY"}, "completed_tool_calls" => []} and
      schema == native_bootstrap_schema() and request["claimed_at"] != nil and
      String.ends_with?(request["request_key"], ":bootstrap") and
      String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n") and
      String.contains?(request["prompt"], "Factory workspace bootstrap ID: #{request["request_key"]}")
  end

  defp native_verifier_create_run_binding(run, task, request) do
    failure = run["failure_code"] || ""
    last_error = run["last_error"] || ""

    run_bound =
      Map.take(run, ["kind", "state", "workspace_state", "candidate_sha"]) == %{
        "kind" => "DELIVERY",
        "state" => "FAILED",
        "workspace_state" => "CODEX_NATIVE",
        "candidate_sha" => task["workspace_sha"]
      } and
        String.starts_with?(failure, "{:native_verifier_create_uncertain, :task_identity_unproven}") and
        String.contains?(last_error, request["request_key"]) and
        String.contains?(last_error, "CREATE request") and String.contains?(last_error, "no proven task or turn") and
        is_binary(run["mr_url"])

    if run_bound, do: :ok, else: {:error, :native_verifier_create_run_not_proven}
  end

  defp native_verifier_create_task_binding(task, run, route) do
    expected_task = %{
      "run_id" => run["run_id"],
      "stage" => "VERIFYING",
      "role" => "change-verifier",
      "status" => "STALE",
      "failure_code" => "stale task exceeded 90 minutes",
      "turn_id" => nil,
      "output_json" => nil,
      "workspace_sha" => run["candidate_sha"],
      "codex_project_id" => route["codex_project_id"]
    }

    if Map.take(task, Map.keys(expected_task)) == expected_task and is_binary(task["thread_id"]) and
         task["thread_id"] != "" and task["workspace"] != run["worktree"] and run["verifier_round"] > 0,
       do: :ok,
       else: {:error, :native_verifier_create_task_not_proven}
  end

  defp recover_native_verifier_create_records(connection, request, task, run) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'RETRY_PENDING', failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'STALE'",
      [timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "UPDATE runs SET state = 'VERIFYING', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state = 'FAILED'",
      [timestamp, run["run_id"]]
    )

    record_recovery_event(connection, timestamp, "NATIVE_VERIFIER_CREATE_RECOVERED", run, task, %{
      request_key: request["request_key"],
      bootstrap_turn_id: request["turn_id"],
      thread_id: task["thread_id"],
      candidate_sha: run["candidate_sha"]
    })

    {:ok, %{result: "NATIVE_VERIFIER_CREATE_RECOVERED", run_id: run["run_id"], task_key: task["task_key"]}}
  end

  defp require_authentication_failed_verifier(_connection, nil, _task, _run, _turn_id),
    do: {:error, :request_not_recoverable}

  defp require_authentication_failed_verifier(connection, request, task, run, failed_turn_id) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- is_map(task) and is_map(run),
         latest <-
           Store.one!(
             connection,
             "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
             [run["issue_key"]]
           ),
         true <- is_map(latest),
         true <- is_binary(failed_turn_id) and failed_turn_id != "" and failed_turn_id != metadata["previous_turn_id"],
         true <- request["claimed_at"] != nil,
         true <- String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n"),
         true <- verifier_request_bound?(request, task, run, metadata),
         true <- verifier_task_and_run_bound?(task, run, latest) do
      :ok
    else
      _other -> {:error, :request_not_recoverable}
    end
  end

  defp verifier_request_bound?(request, task, run, metadata) do
    expected_request = %{
      "target_kind" => "TASK",
      "target_key" => task["task_key"],
      "action" => "FOLLOWUP",
      "status" => "RECONCILE_REQUIRED",
      "failure_code" => "CODEX_AUTHENTICATION_FAILED",
      "turn_id" => nil,
      "output_json" => nil,
      "thread_id" => task["thread_id"],
      "existing_thread_id" => task["thread_id"],
      "codex_project_id" => task["codex_project_id"],
      "verified_project_id" => task["codex_project_id"],
      "cwd" => task["workspace"],
      "verified_cwd" => task["workspace"],
      "verified_head_sha" => run["candidate_sha"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"]
    }

    expected_metadata = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => run["candidate_sha"],
      "stage_prompt_sha256" => task["prompt_sha256"],
      "required_tool_calls" => []
    }

    Map.take(request, Map.keys(expected_request)) == expected_request and
      Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata and
      is_binary(metadata["previous_turn_id"]) and metadata["previous_turn_id"] != ""
  end

  defp verifier_task_and_run_bound?(task, run, latest) do
    expected_task = %{
      "run_id" => run["run_id"],
      "stage" => "VERIFYING",
      "role" => "change-verifier",
      "status" => "STALE",
      "failure_code" => "stale task exceeded 90 minutes",
      "turn_id" => nil,
      "output_json" => nil,
      "workspace_sha" => run["candidate_sha"]
    }

    expected_run = %{
      "kind" => "DELIVERY",
      "state" => "VERIFYING",
      "workspace_state" => "CODEX_NATIVE",
      "mr_url" => nil
    }

    Map.take(task, Map.keys(expected_task)) == expected_task and
      Map.take(run, Map.keys(expected_run)) == expected_run and
      run["verifier_round"] > 0 and latest["run_id"] == run["run_id"] and
      run["worktree"] != task["workspace"]
  end

  defp rearm_authentication_failed_verifier(connection, request, task, run, failed_turn_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE desktop_requests SET status = 'FAILED', turn_id = ?, failure_code = 'RECOVERED_CODEX_AUTHENTICATION_FAILED', updated_at = ? WHERE request_key = ? AND status = 'RECONCILE_REQUIRED'",
      [failed_turn_id, timestamp, request["request_key"]]
    )

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'RETRY_PENDING', turn_id = ?, failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'STALE'",
      [failed_turn_id, timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [timestamp, "AUTHENTICATION_FAILED_VERIFIER_REARMED", run["run_id"], Jason.encode!(%{request_key: request["request_key"], failed_turn_id: failed_turn_id})]
    )

    {:ok, %{result: "AUTHENTICATION_FAILED_VERIFIER_REARMED", run_id: run["run_id"], task_key: task["task_key"]}}
  end

  @doc "Allows one bounded investigation after a source writer blocks on a failed contract check."
  @spec resume_blocked_native_writer_investigation(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resume_blocked_native_writer_investigation(connection, config, request_key, blocked_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           {:ok, blockers} <-
             require_blocked_writer_investigation(
               transaction,
               config,
               request,
               task,
               run,
               blocked_turn_id
             ),
           :ok <- require_no_other_unresolved_request(transaction, request),
           {:ok, %{path: path, sha: sha}} <-
             Worktree.validate_native(%{"path" => run["repo_path"]}, task["workspace"],
               expected_branch: run["branch"],
               expected_sha: run["candidate_sha"],
               clean: false,
               detached: false
             ),
           true <-
             (path == run["worktree"] and sha == run["candidate_sha"]) or
               {:error, :native_workspace_route_mismatch} do
        rearm_blocked_writer_investigation(transaction, request, task, run, blockers)
      end
    end)
  end

  defp require_blocked_writer_investigation(_connection, _config, nil, _task, _run, _turn_id),
    do: {:error, :request_not_recoverable}

  defp require_blocked_writer_investigation(connection, config, request, task, run, blocked_turn_id) do
    with true <- is_map(task) and is_map(run),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, task_output} <- Jason.decode(task["output_json"]),
         {:ok, %{"result" => ^task_output}} <- Jason.decode(request["output_json"]),
         %{"status" => "BLOCKED", "blockers" => blockers} <- task_output,
         true <- is_list(blockers) and blockers != [] and Enum.all?(blockers, &is_binary/1),
         true <- blocked_writer_request_bound?(request, task, run, metadata, blocked_turn_id),
         true <- blocked_writer_run_bound?(connection, config, request, task, run, blockers),
         :ok <- require_no_previous_blocked_writer_investigation(connection, run["run_id"]) do
      {:ok, blockers}
    else
      _other -> {:error, :request_not_recoverable}
    end
  end

  defp blocked_writer_request_bound?(request, task, run, metadata, blocked_turn_id) do
    expected_request = %{
      "target_kind" => "TASK",
      "target_key" => task["task_key"],
      "action" => "FOLLOWUP",
      "status" => "SUCCEEDED",
      "failure_code" => nil,
      "turn_id" => blocked_turn_id,
      "thread_id" => task["thread_id"],
      "existing_thread_id" => task["thread_id"],
      "codex_project_id" => task["codex_project_id"],
      "verified_project_id" => task["codex_project_id"],
      "cwd" => task["workspace"],
      "verified_cwd" => task["workspace"],
      "verified_head_sha" => run["candidate_sha"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"]
    }

    expected_metadata = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => run["candidate_sha"],
      "stage_prompt_sha256" => task["prompt_sha256"],
      "required_tool_calls" => []
    }

    request["claimed_at"] != nil and is_binary(blocked_turn_id) and blocked_turn_id != "" and
      task["turn_id"] == blocked_turn_id and
      String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n") and
      Map.take(request, Map.keys(expected_request)) == expected_request and
      Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata
  end

  defp blocked_writer_run_bound?(connection, config, request, task, run, blockers) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    latest_request =
      Store.one!(
        connection,
        "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'FOLLOWUP' ORDER BY created_at DESC, request_key DESC LIMIT 1",
        [task["task_key"]]
      )

    expected_failure = inspect({:writer_blocked, blockers})

    expected_task = %{
      "run_id" => run["run_id"],
      "stage" => "WRITING",
      "status" => "COMPLETE",
      "failure_code" => nil,
      "workspace" => run["worktree"],
      "workspace_sha" => run["candidate_sha"]
    }

    expected_run = %{
      "kind" => "DELIVERY",
      "state" => "FAILED",
      "failure_code" => String.slice(expected_failure, 0, 200),
      "last_error" => expected_failure,
      "factory_owned" => 0,
      "workspace_state" => "CODEX_NATIVE",
      "mr_url" => nil
    }

    is_map(latest) and is_map(latest_request) and latest["run_id"] == run["run_id"] and
      latest_request["request_key"] == request["request_key"] and
      TaskLedger.source_writer?(task) and Map.take(task, Map.keys(expected_task)) == expected_task and
      Map.take(run, Map.keys(expected_run)) == expected_run and
      run["implementation_iteration"] < Map.get(config, :maximum_implementation_iterations, 8) and
      active_writer_labels?(run["snapshot_json"])
  end

  defp active_writer_labels?(snapshot_json) do
    case Jason.decode(snapshot_json || "") do
      {:ok, %{"labels" => labels}} when is_list(labels) ->
        "ai-running" in labels and "ai-blocked" not in labels

      _other ->
        false
    end
  end

  defp require_no_previous_blocked_writer_investigation(connection, run_id) do
    row =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS count FROM events WHERE run_id = ? AND event_type = 'BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED'",
        [run_id]
      )

    if row["count"] == 0, do: :ok, else: {:error, :investigation_already_rearmed}
  end

  defp rearm_blocked_writer_investigation(connection, request, task, run, blockers) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'CONSUMED', failure_code = 'BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED', updated_at = ? WHERE task_key = ? AND status = 'COMPLETE'",
      [timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "UPDATE runs SET state = 'WRITING', failure_code = NULL, last_error = NULL, repair_findings_json = ?, updated_at = ? WHERE run_id = ? AND state = 'FAILED'",
      [Jason.encode!(blockers), timestamp, run["run_id"]]
    )

    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [timestamp, "BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED", run["run_id"], Jason.encode!(%{request_key: request["request_key"], task_key: task["task_key"]})]
    )

    {:ok, %{result: "BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED", run_id: run["run_id"], task_key: task["task_key"]}}
  end

  defp require_interrupted_writer_binding(_connection, nil, _task, _run, _turn_id),
    do: {:error, :request_not_recoverable}

  defp require_interrupted_writer_binding(connection, request, task, run, interrupted_turn_id) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- is_map(task) and is_map(run) and TaskLedger.source_writer?(task),
         true <-
           is_binary(interrupted_turn_id) and interrupted_turn_id != "" and
             interrupted_turn_id != task["turn_id"],
         true <- String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n"),
         true <- interrupted_writer_bound?(request, task, run, metadata),
         :ok <- require_previous_writer_turn(connection, task, metadata) do
      :ok
    else
      _other -> {:error, :request_not_recoverable}
    end
  end

  defp interrupted_writer_bound?(request, task, run, metadata) do
    expected_request = %{
      "target_kind" => "TASK",
      "action" => "FOLLOWUP",
      "status" => "RECONCILE_REQUIRED",
      "turn_id" => nil,
      "output_json" => nil,
      "target_key" => task["task_key"],
      "thread_id" => task["thread_id"],
      "existing_thread_id" => task["thread_id"],
      "verified_project_id" => task["codex_project_id"],
      "codex_project_id" => task["codex_project_id"],
      "verified_cwd" => task["workspace"],
      "cwd" => task["workspace"],
      "verified_head_sha" => task["workspace_sha"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"]
    }

    expected_metadata = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => task["workspace_sha"],
      "stage_prompt_sha256" => task["prompt_sha256"],
      "required_tool_calls" => []
    }

    expected_task = %{
      "stage" => "WRITING",
      "output_json" => nil,
      "workspace" => run["worktree"]
    }

    request["claimed_at"] != nil and Map.take(request, Map.keys(expected_request)) == expected_request and
      Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata and
      Map.take(task, Map.keys(expected_task)) == expected_task and
      interrupted_writer_state?(request, task, run)
  end

  defp interrupted_writer_state?(request, task, run) do
    case {run["state"], run["failure_code"], run["implementation_iteration"], task["status"], request["failure_code"]} do
      {"FAILED", ":worktree_dirty", 1, "WAITING_FOR_BROKER", "FINAL_OUTPUT_SCHEMA_MISMATCH"} ->
        true

      {"WRITING", nil, iteration, "RUNNING", "TURN_INTERRUPTED_NO_FINAL"}
      when is_integer(iteration) and iteration >= 0 ->
        true

      _other ->
        false
    end
  end

  defp require_previous_writer_turn(_connection, %{"turn_id" => turn_id}, %{"previous_turn_id" => turn_id})
       when is_binary(turn_id) and turn_id != "",
       do: :ok

  defp require_previous_writer_turn(connection, %{"turn_id" => nil, "task_key" => task_key}, metadata) do
    bootstrap =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS request_count, MAX(turn_id) AS turn_id FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'CREATE' AND status = 'SUCCEEDED'",
        [task_key]
      )

    if bootstrap["request_count"] == 1 and is_binary(bootstrap["turn_id"]) and
         bootstrap["turn_id"] == metadata["previous_turn_id"],
       do: :ok,
       else: {:error, :previous_writer_turn_unbound}
  end

  defp require_previous_writer_turn(_connection, _task, _metadata),
    do: {:error, :previous_writer_turn_unbound}

  defp require_interrupted_writer_run(connection, run, task) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    expected_run = %{
      "kind" => "DELIVERY",
      "run_id" => task["run_id"],
      "worktree" => task["workspace"],
      "workspace_state" => "CODEX_NATIVE",
      "mr_url" => nil
    }

    candidate_is_current = is_nil(run["candidate_sha"]) or run["candidate_sha"] == task["workspace_sha"]

    if Map.take(run, Map.keys(expected_run)) == expected_run and candidate_is_current and
         latest["run_id"] == run["run_id"],
       do: :ok,
       else: {:error, :run_not_recoverable}
  end

  defp resume_interrupted_writer_records(connection, request, task, run, interrupted_turn_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE desktop_requests SET status = 'FAILED', turn_id = ?, failure_code = 'RECOVERED_INTERRUPTED_NATIVE_WRITER', updated_at = ? WHERE request_key = ? AND status = 'RECONCILE_REQUIRED'",
      [interrupted_turn_id, timestamp, request["request_key"]]
    )

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'RUNNING', turn_id = ?, failure_code = NULL, updated_at = ? WHERE task_key = ? AND status IN ('WAITING_FOR_BROKER', 'RUNNING')",
      [interrupted_turn_id, timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "UPDATE runs SET state = 'WRITING', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state IN ('FAILED', 'WRITING')",
      [timestamp, run["run_id"]]
    )

    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [timestamp, "INTERRUPTED_NATIVE_WRITER_RESUMED", run["run_id"], Jason.encode!(%{request_key: request["request_key"], interrupted_turn_id: interrupted_turn_id})]
    )

    {:ok, %{result: "INTERRUPTED_NATIVE_WRITER_RESUMED", run_id: run["run_id"], task_key: task["task_key"]}}
  end

  @doc "Reopens a factory-blocked delivery after its original native writer is proven recoverable."
  @spec reopen_factory_blocked_delivery(Store.connection(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reopen_factory_blocked_delivery(connection, config, run_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      run = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [run_id])
      task = Store.one!(transaction, "SELECT * FROM factory_tasks WHERE task_key = ?", ["#{run_id}:feature-writer"])

      with :ok <- require_paused_control(control, config),
           :ok <- require_reopenable_delivery(transaction, run, task),
           :ok <- require_no_unresolved_writer_requests(transaction, task),
           :ok <- require_reopenable_writer_result(transaction, run, task),
           {:ok, %{path: path, sha: sha}} <-
             Worktree.validate_native(%{"path" => run["repo_path"]}, task["workspace"],
               expected_branch: run["branch"],
               expected_sha: task["workspace_sha"],
               clean: false,
               detached: false
             ),
           true <-
             (path == run["worktree"] and sha == task["workspace_sha"]) or
               {:error, :native_workspace_route_mismatch} do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE runs SET state = 'WRITING', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state IN ('FAILED', 'CANCELLED')",
          [timestamp, run_id]
        )

        restore_cancelled_writer_task(transaction, run, task, timestamp)

        Store.query!(
          transaction,
          "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
          [timestamp, "FACTORY_BLOCKED_DELIVERY_REOPENED", run_id, Jason.encode!(%{previous_state: run["state"], previous_failure: run["failure_code"], task_key: task["task_key"]})]
        )

        {:ok, %{result: "FACTORY_BLOCKED_DELIVERY_REOPENED", run_id: run_id, task_key: task["task_key"]}}
      end
    end)
  end

  defp restore_cancelled_writer_task(connection, %{"state" => "CANCELLED"}, task, timestamp) do
    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'RUNNING', failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'CANCELLED'",
      [timestamp, task["task_key"]]
    )
  end

  defp restore_cancelled_writer_task(_connection, _run, _task, _timestamp), do: :ok

  defp require_reopenable_delivery(_connection, nil, _task), do: {:error, :run_not_recoverable}

  defp require_reopenable_delivery(connection, run, task) do
    latest_delivery =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? AND kind = 'DELIVERY' ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    latest_specification =
      Store.one!(
        connection,
        "SELECT parent_run_id, spec_revision, contract_sha256 FROM runs WHERE issue_key = ? AND kind = 'SPECIFICATION' ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    specification_matches? = controller_delivery_specification_proven?(latest_specification, run)

    expected = %{
      "kind" => "DELIVERY",
      "workspace_state" => "CODEX_NATIVE",
      "worktree" => task && task["workspace"],
      "candidate_sha" => if(run["failure_code"] == ":native_slice_intent_invalid", do: task && task["workspace_sha"], else: nil),
      "mr_url" => nil
    }

    if reopenable_delivery?(run, task, latest_delivery, specification_matches?, expected),
      do: :ok,
      else: {:error, :run_not_recoverable}
  end

  defp reopenable_delivery?(run, task, latest_delivery, specification_matches?, expected) do
    reopenable_writer_task?(task, run) and latest_delivery_for_run?(latest_delivery, run) and
      specification_matches? and Map.take(run, Map.keys(expected)) == expected and
      reopenable_writer_state?(run, task)
  end

  defp reopenable_writer_task?(task, run) do
    is_map(task) and TaskLedger.source_writer?(task) and task["run_id"] == run["run_id"]
  end

  defp latest_delivery_for_run?(latest_delivery, run) do
    is_map(latest_delivery) and latest_delivery["run_id"] == run["run_id"]
  end

  defp reopenable_writer_state?(%{"state" => "FAILED", "failure_code" => ":worktree_dirty"}, %{
         "status" => "COMPLETE"
       }),
       do: true

  defp reopenable_writer_state?(%{"state" => "FAILED", "failure_code" => ":native_slice_intent_invalid"}, %{
         "status" => "COMPLETE"
       }),
       do: true

  defp reopenable_writer_state?(%{"state" => "CANCELLED", "failure_code" => ":delivery_labels_removed"}, %{
         "status" => "CANCELLED"
       }),
       do: true

  defp reopenable_writer_state?(_run, _task), do: false

  defp require_no_unresolved_writer_requests(connection, task) do
    count =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS request_count FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')",
        [task["task_key"]]
      )

    if count["request_count"] == 0, do: :ok, else: {:error, :other_task_request_unresolved}
  end

  defp require_reopenable_writer_result(connection, %{"state" => "FAILED"}, task) do
    request = latest_writer_request(connection, task)

    with %{"status" => "SUCCEEDED", "turn_id" => turn_id, "output_json" => request_json} <- request,
         true <- turn_id == task["turn_id"] and request["thread_id"] == task["thread_id"],
         true <-
           request["verified_cwd"] == task["workspace"] and
             request["verified_project_id"] == task["codex_project_id"],
         {:ok, %{"result" => output, "completed_tool_calls" => []}} <- Jason.decode(request_json),
         {:ok, ^output} <- Jason.decode(task["output_json"]),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:native_feature_writer)) do
      :ok
    else
      _other -> {:error, :writer_result_not_recoverable}
    end
  end

  defp require_reopenable_writer_result(connection, %{"state" => "CANCELLED"} = run, task) do
    request = latest_writer_request(connection, task)

    with %{"status" => "FAILED", "failure_code" => "RECOVERED_INTERRUPTED_NATIVE_WRITER", "turn_id" => turn_id} <- request,
         true <- turn_id == task["turn_id"] and request["thread_id"] == task["thread_id"],
         true <- task["output_json"] == nil and request["verified_cwd"] == task["workspace"],
         {:ok, %{"labels" => labels}} <- Jason.decode(run["snapshot_json"]),
         true <- "ai-blocked" in labels and "repo-grail" in labels do
      :ok
    else
      _other -> {:error, :writer_result_not_recoverable}
    end
  end

  defp latest_writer_request(connection, task) do
    Store.one!(
      connection,
      "SELECT * FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'FOLLOWUP' ORDER BY created_at DESC, rowid DESC LIMIT 1",
      [task["task_key"]]
    )
  end

  defp require_native_writer_request(nil, _task, _run, _turn_id), do: {:error, :request_not_recoverable}

  defp require_native_writer_request(request, task, run, completed_turn_id) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- is_map(task) and is_map(run) and TaskLedger.source_writer?(task),
         true <- is_binary(completed_turn_id) and completed_turn_id != "",
         true <- String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n"),
         true <- native_writer_request_bound?(request, task, run, metadata) do
      :ok
    else
      _other -> {:error, :request_not_recoverable}
    end
  end

  defp native_writer_request_bound?(request, task, run, metadata) do
    expected_request = %{
      "target_kind" => "TASK",
      "action" => "FOLLOWUP",
      "status" => "RECONCILE_REQUIRED",
      "failure_code" => "FINAL_OUTPUT_INVALID_JSON",
      "turn_id" => nil,
      "output_json" => nil,
      "target_key" => task["task_key"],
      "thread_id" => task["thread_id"],
      "existing_thread_id" => task["thread_id"],
      "verified_project_id" => task["codex_project_id"],
      "codex_project_id" => task["codex_project_id"],
      "verified_cwd" => task["workspace"],
      "cwd" => task["workspace"],
      "verified_head_sha" => task["workspace_sha"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"]
    }

    expected_metadata = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => task["workspace_sha"],
      "stage_prompt_sha256" => task["prompt_sha256"],
      "required_tool_calls" => []
    }

    expected_task = %{
      "stage" => "WRITING",
      "status" => "WAITING_FOR_BROKER",
      "turn_id" => nil,
      "output_json" => nil
    }

    request["claimed_at"] != nil and Map.take(request, Map.keys(expected_request)) == expected_request and
      Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata and
      Map.take(task, Map.keys(expected_task)) == expected_task
  end

  defp require_native_writer_run(connection, run, task) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    expected_run = %{
      "kind" => "DELIVERY",
      "state" => "FAILED",
      "failure_code" => ":native_run_workspace_conflict",
      "run_id" => task["run_id"],
      "worktree" => nil,
      "workspace_state" => "UNMATERIALIZED",
      "implementation_iteration" => 0,
      "candidate_sha" => nil,
      "mr_url" => nil
    }

    if Map.take(run, Map.keys(expected_run)) == expected_run and latest["run_id"] == run["run_id"],
      do: :ok,
      else: {:error, :run_not_recoverable}
  end

  defp restore_native_writer_records(connection, request, task, run, workspace, completed_turn_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE desktop_requests SET status = 'FAILED', turn_id = ?, failure_code = 'RECOVERED_BLOCKED_NATIVE_WRITER', updated_at = ? WHERE request_key = ? AND status = 'RECONCILE_REQUIRED'",
      [completed_turn_id, timestamp, request["request_key"]]
    )

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'RETRY_PENDING', turn_id = ?, failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'WAITING_FOR_BROKER'",
      [completed_turn_id, timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "UPDATE runs SET state = 'WRITING', worktree = ?, workspace_state = 'CODEX_NATIVE', implementation_iteration = 1, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state = 'FAILED'",
      [workspace.path, timestamp, run["run_id"]]
    )

    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [timestamp, "NATIVE_WRITER_RECOVERED", run["run_id"], Jason.encode!(%{request_key: request["request_key"], completed_turn_id: completed_turn_id})]
    )

    {:ok, %{result: "NATIVE_WRITER_RECOVERED", run_id: run["run_id"], task_key: task["task_key"]}}
  end

  @doc "Authorizes one schema-only follow-up in an existing stale planner task."
  @spec authorize_planner_format_repair(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def authorize_planner_format_repair(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)
      run = run_for_task(transaction, task)

      with :ok <- require_paused_control(control, config),
           :ok <- require_planner_request(request, completed_turn_id),
           :ok <- require_planner_task(task, request),
           :ok <- require_planner_run(transaction, run, task),
           :ok <- require_no_other_unresolved_request(transaction, request) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "INSERT INTO planner_format_repairs(request_key, completed_turn_id, status, authorized_at) VALUES (?, ?, 'AUTHORIZED', ?)",
          [request_key, completed_turn_id, timestamp]
        )

        Store.query!(
          transaction,
          "UPDATE factory_tasks SET status = 'WAITING_FOR_BROKER', failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'STALE'",
          [timestamp, task["task_key"]]
        )

        Store.query!(
          transaction,
          "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
          [timestamp, "PLANNER_FORMAT_REPAIR_AUTHORIZED", run["run_id"], Jason.encode!(%{request_key: request_key, completed_turn_id: completed_turn_id})]
        )

        {:ok, %{result: "PLANNER_FORMAT_REPAIR_AUTHORIZED", run_id: run["run_id"], task_key: task["task_key"]}}
      end
    end)
  end

  @doc "Claims an authorized planner repair before sending its one allowed turn."
  @spec claim_planner_format_repair(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def claim_planner_format_repair(connection, config, request_key) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      grant = Store.one!(transaction, "SELECT * FROM planner_format_repairs WHERE request_key = ?", [request_key])
      task = task_for_request(transaction, request)

      with :ok <- require_active_repair_control(control, config),
           :ok <- require_claimable_planner_request(request, grant),
           :ok <- require_planner_claim_binding(request, task) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE planner_format_repairs SET status = 'CLAIMED', claimed_at = ? WHERE request_key = ? AND status = 'AUTHORIZED'",
          [timestamp, request_key]
        )

        Store.query!(
          transaction,
          "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
          [timestamp, "PLANNER_FORMAT_REPAIR_CLAIMED", task["run_id"], Jason.encode!(%{request_key: request_key})]
        )

        {:ok, %{result: "PLANNER_FORMAT_REPAIR_CLAIMED", completed_turn_id: grant["completed_turn_id"], request_key: request_key}}
      end
    end)
  end

  @doc "Authorizes one tool-free receipt repair in the existing projectless controller task."
  @spec authorize_controller_format_repair(Store.connection(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def authorize_controller_format_repair(connection, config, request_key, completed_turn_id) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      existing_grant = Store.one!(transaction, "SELECT status FROM controller_format_repairs WHERE request_key = ?", [request_key])

      with :ok <- require_paused_control(control, config),
           :ok <- require_controller_format_repair_request(transaction, control, request, config, completed_turn_id),
           :ok <- require_new_controller_format_repair(existing_grant) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "INSERT INTO controller_format_repairs(request_key, completed_turn_id, request_payload_sha256, thread_id, status, authorized_at) VALUES (?, ?, ?, ?, 'AUTHORIZED', ?)",
          [request_key, completed_turn_id, request["payload_sha256"], request["thread_id"], timestamp]
        )

        record_controller_repair_event(transaction, timestamp, "CONTROLLER_FORMAT_REPAIR_AUTHORIZED", request, %{
          completed_turn_id: completed_turn_id
        })

        {:ok, %{result: "CONTROLLER_FORMAT_REPAIR_AUTHORIZED", request_key: request_key}}
      end
    end)
  end

  defp require_new_controller_format_repair(nil), do: :ok
  defp require_new_controller_format_repair(_grant), do: {:error, :repair_already_authorized}

  @doc "Claims an authorized controller receipt repair before the broker sends its single turn."
  @spec claim_controller_format_repair(Store.connection(), map(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def claim_controller_format_repair(connection, config, request_key) do
    Store.transaction!(connection, fn transaction ->
      control = Control.status(transaction, config.scope)
      request = Store.one!(transaction, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key])
      grant = Store.one!(transaction, "SELECT * FROM controller_format_repairs WHERE request_key = ?", [request_key])

      with :ok <- require_active_repair_control(control, config),
           :ok <- require_claimable_controller_repair(request, grant),
           :ok <- require_controller_repair_binding(control, request, grant, config),
           {:ok, schema} <- Jason.decode(request["schema_json"]) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        Store.query!(
          transaction,
          "UPDATE controller_format_repairs SET status = 'CLAIMED', claimed_at = ? WHERE request_key = ? AND status = 'AUTHORIZED'",
          [timestamp, request_key]
        )

        record_controller_repair_event(transaction, timestamp, "CONTROLLER_FORMAT_REPAIR_CLAIMED", request, %{})

        {:ok,
         %{
           result: "CONTROLLER_FORMAT_REPAIR_CLAIMED",
           request_key: request_key,
           completed_turn_id: grant["completed_turn_id"],
           thread_id: request["thread_id"],
           codex_project_id: "projectless",
           model: request["model"],
           reasoning_effort: request["reasoning_effort"],
           repair_prompt: controller_format_repair_prompt(request_key, schema)
         }}
      end
    end)
  end

  defp require_controller_format_repair_request(_connection, _control, nil, _config, _turn_id),
    do: {:error, :request_not_recoverable}

  defp require_controller_format_repair_request(connection, control, request, config, completed_turn_id) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- is_map(schema),
         :ok <- controller_format_metadata(metadata),
         true <- is_binary(completed_turn_id) and completed_turn_id != "",
         true <- completed_turn_id != metadata["previous_turn_id"],
         :ok <- controller_format_request_fields(request, control, config),
         :ok <- require_no_other_unresolved_controller_request(connection, request) do
      :ok
    else
      _other -> {:error, :request_not_recoverable}
    end
  end

  defp controller_format_request_fields(request, control, config) do
    expected = %{
      "target_kind" => "CONTROLLER",
      "target_key" => config.scope,
      "action" => "FOLLOWUP",
      "status" => "RECONCILE_REQUIRED",
      "failure_code" => "FINAL_OUTPUT_INVALID_JSON",
      "turn_id" => nil,
      "output_json" => nil,
      "thread_id" => control["controller_thread_id"],
      "existing_thread_id" => control["controller_thread_id"],
      "verified_project_id" => "projectless",
      "codex_project_id" => "projectless",
      "model" => control["controller_model"],
      "reasoning_effort" => control["controller_reasoning_effort"]
    }

    valid =
      is_binary(request["claimed_at"]) and request["thread_id"] not in [nil, ""] and
        DesktopRequest.payload_intact?(request) and
        String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n") and
        Map.take(request, Map.keys(expected)) == expected

    if valid, do: :ok, else: {:error, :request_not_recoverable}
  end

  defp controller_format_metadata(metadata) when is_map(metadata) do
    expected = %{
      "format_repair_attempts" => 0,
      "required_tool_calls" => [],
      "allowed_mcp_tool_approvals" => []
    }

    if Map.take(metadata, Map.keys(expected)) == expected and is_binary(metadata["issue_key"]) and
         is_binary(metadata["previous_turn_id"]),
       do: :ok,
       else: {:error, :request_not_recoverable}
  end

  defp controller_format_metadata(_metadata), do: {:error, :request_not_recoverable}

  defp require_no_other_unresolved_controller_request(connection, request) do
    row =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND target_key = ? AND request_key != ? AND status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED')",
        [request["target_key"], request["request_key"]]
      )

    if row["count"] == 0, do: :ok, else: {:error, :request_not_recoverable}
  end

  defp require_claimable_controller_repair(nil, _grant), do: {:error, :request_not_recoverable}
  defp require_claimable_controller_repair(_request, nil), do: {:error, :request_not_recoverable}

  defp require_claimable_controller_repair(request, grant) do
    cond do
      grant["status"] != "AUTHORIZED" ->
        {:error, :repair_already_claimed}

      request["status"] != "RECONCILE_REQUIRED" or request["failure_code"] != "FINAL_OUTPUT_INVALID_JSON" ->
        {:error, :request_not_recoverable}

      true ->
        :ok
    end
  end

  defp require_controller_repair_binding(control, request, grant, config) do
    expected_control = %{
      "status" => "ACTIVE",
      "dispatcher_id" => config.dispatcher_id,
      "controller_thread_id" => request["thread_id"],
      "controller_codex_project_id" => "projectless",
      "controller_model" => request["model"],
      "controller_reasoning_effort" => request["reasoning_effort"]
    }

    expected_grant = %{
      "request_payload_sha256" => request["payload_sha256"],
      "thread_id" => request["thread_id"]
    }

    if DesktopRequest.payload_intact?(request) and Map.take(control, Map.keys(expected_control)) == expected_control and
         Map.take(grant, Map.keys(expected_grant)) == expected_grant,
       do: :ok,
       else: {:error, :repair_binding_changed}
  end

  defp controller_format_repair_prompt(request_key, schema) do
    """
    Factory request ID: #{request_key}
    Factory format repair attempt: 1

    The preceding controller turn completed, but its final response was not
    valid JSON. Use only evidence and completed operations already present in
    this task's history. Do not call tools, repeat operations, or make external
    changes. Return only one raw JSON object matching this schema:

    #{Jason.encode!(schema)}
    """
  end

  defp record_controller_repair_event(connection, timestamp, event_type, request, details) do
    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, NULL, ?)",
      [timestamp, event_type, Jason.encode!(Map.merge(%{request_key: request["request_key"]}, details))]
    )
  end

  defp require_active_repair_control(control, config) do
    if control["status"] == "ACTIVE" and control["dispatcher_id"] == config.dispatcher_id,
      do: :ok,
      else: {:error, :repair_requires_active_control}
  end

  defp require_claimable_planner_request(nil, _grant), do: {:error, :request_not_recoverable}
  defp require_claimable_planner_request(_request, nil), do: {:error, :request_not_recoverable}

  defp require_claimable_planner_request(request, grant) do
    cond do
      request["status"] != "RECONCILE_REQUIRED" or request["failure_code"] != "FINAL_OUTPUT_INVALID_JSON" ->
        {:error, :request_not_recoverable}

      grant["status"] != "AUTHORIZED" ->
        {:error, :repair_already_claimed}

      true ->
        :ok
    end
  end

  defp require_planner_claim_binding(request, task) do
    expected = %{
      "status" => "WAITING_FOR_BROKER",
      "role" => "feature-planner",
      "stage" => "PLANNING",
      "turn_id" => nil,
      "output_json" => nil,
      "thread_id" => request["thread_id"],
      "codex_project_id" => request["codex_project_id"],
      "workspace" => request["verified_cwd"]
    }

    if is_map(task) and Map.take(task, Map.keys(expected)) == expected,
      do: :ok,
      else: {:error, :repair_binding_changed}
  end

  defp require_planner_request(nil, _completed_turn_id), do: {:error, :request_not_recoverable}

  defp require_planner_request(request, completed_turn_id) do
    with :ok <- require_planner_request_identity(request, completed_turn_id),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         :ok <- require_planner_metadata(metadata, request) do
      :ok
    else
      _other -> {:error, :request_not_recoverable}
    end
  end

  defp require_planner_request_identity(request, completed_turn_id) do
    expected = %{
      "target_kind" => "TASK",
      "action" => "FOLLOWUP",
      "status" => "RECONCILE_REQUIRED",
      "failure_code" => "FINAL_OUTPUT_INVALID_JSON",
      "turn_id" => nil,
      "output_json" => nil,
      "thread_id" => request["existing_thread_id"],
      "verified_project_id" => request["codex_project_id"]
    }

    if is_binary(completed_turn_id) and completed_turn_id != "" and
         Map.take(request, Map.keys(expected)) == expected and
         String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n"),
       do: :ok,
       else: {:error, :request_not_recoverable}
  end

  defp require_planner_metadata(metadata, request) when is_map(metadata) do
    expected = %{
      "workspace_mode" => "CODEX_NATIVE",
      "format_repair_attempts" => 0,
      "required_tool_calls" => [],
      "expected_sha" => request["verified_head_sha"]
    }

    if Map.take(metadata, Map.keys(expected)) == expected and is_binary(metadata["stage_prompt_sha256"]) and
         byte_size(metadata["stage_prompt_sha256"]) == 64 and is_binary(request["verified_cwd"]),
       do: :ok,
       else: {:error, :request_not_recoverable}
  end

  defp require_planner_metadata(_metadata, _request), do: {:error, :request_not_recoverable}

  defp require_planner_task(nil, _request), do: {:error, :task_not_recoverable}

  defp require_planner_task(task, request) do
    {:ok, metadata} = Jason.decode(request["metadata_json"])

    expected = %{
      "task_key" => "#{task["run_id"]}:feature-planner",
      "role" => "feature-planner",
      "stage" => "PLANNING",
      "status" => "STALE",
      "turn_id" => nil,
      "output_json" => nil,
      "thread_id" => request["thread_id"],
      "codex_project_id" => request["codex_project_id"],
      "workspace" => request["verified_cwd"],
      "prompt_sha256" => metadata["stage_prompt_sha256"]
    }

    if Map.take(task, Map.keys(expected)) == expected,
      do: :ok,
      else: {:error, :task_not_recoverable}
  end

  defp require_planner_run(connection, run, task) do
    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run && run["issue_key"]]
      )

    if is_map(run) and run["kind"] == "DELIVERY" and run["state"] == "PLANNING" and
         run["run_id"] == task["run_id"] and latest["run_id"] == run["run_id"],
       do: :ok,
       else: {:error, :run_not_recoverable}
  end

  defp task_for_request(_connection, nil), do: nil

  defp task_for_request(connection, request) do
    Store.one!(connection, "SELECT * FROM factory_tasks WHERE task_key = ?", [request["target_key"]])
  end

  defp task_for_run(_connection, nil), do: nil

  defp task_for_run(connection, run) do
    Store.one!(connection, "SELECT * FROM factory_tasks WHERE task_key = ?", ["#{run["run_id"]}:feature-writer"])
  end

  defp decode_json(value, fallback) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_value, fallback), do: fallback

  defp run_for_task(_connection, nil), do: nil

  defp run_for_task(connection, task) do
    Store.one!(connection, "SELECT * FROM runs WHERE run_id = ?", [task["run_id"]])
  end

  defp require_paused_control(control, config) do
    if control["status"] == "PAUSED" and control["tick_id"] == nil and
         control["dispatcher_id"] == config.dispatcher_id,
       do: :ok,
       else: {:error, :recovery_requires_paused_unleased_control}
  end

  defp require_request(request, completed_turn_id) do
    with :ok <- require_request_identity(request, completed_turn_id),
         :ok <- require_request_reconciliation(request) do
      require_request_metadata(request)
    end
  end

  defp require_request_identity(request, completed_turn_id) do
    if is_map(request) and request["target_kind"] == "TASK" and request["target_key"] not in [nil, ""] and
         request["action"] == "FOLLOWUP" and is_binary(completed_turn_id) and completed_turn_id != "" and
         request["turn_id"] == nil and request["prompt"] =~ "Factory request ID: #{request["request_key"]}",
       do: :ok,
       else: {:error, :request_not_recoverable}
  end

  defp require_request_reconciliation(request) do
    if request["status"] == "RECONCILE_REQUIRED" and request["failure_code"] == @readback_failure and
         request["thread_id"] == request["existing_thread_id"] and
         request["verified_project_id"] == request["codex_project_id"],
       do: :ok,
       else: {:error, :request_not_recoverable}
  end

  defp require_request_metadata(request) do
    case Jason.decode(request["metadata_json"]) do
      {:ok, %{"workspace_mode" => "CODEX_NATIVE", "stage_prompt_sha256" => digest}}
      when is_binary(digest) and byte_size(digest) == 64 ->
        if request["verified_cwd"] != nil, do: :ok, else: {:error, :request_not_recoverable}

      _other ->
        {:error, :request_not_recoverable}
    end
  end

  defp require_task(task, request) do
    expected_failure = inspect({:desktop_request_reconciliation_required, @readback_failure})

    if is_map(task) and task["role"] == "specification-author" and task["stage"] == "SPEC_DRAFTING" and
         task["status"] == "FAILED" and task["failure_code"] == expected_failure and task["output_json"] == nil and
         task["turn_id"] == nil,
       do: require_task_route(task, request),
       else: {:error, :task_not_recoverable}
  end

  defp require_task_route(task, request) do
    if task["thread_id"] == request["thread_id"] and task["codex_project_id"] == request["codex_project_id"] and
         task["workspace"] == request["verified_cwd"] and prompt_matches?(task, request),
       do: :ok,
       else: {:error, :task_not_recoverable}
  end

  defp prompt_matches?(task, request) do
    {:ok, %{"stage_prompt_sha256" => digest}} = Jason.decode(request["metadata_json"])
    task["prompt_sha256"] == digest
  end

  defp require_run(connection, run, task) do
    expected_failure = inspect({:task_failed, task["failure_code"], :not_applicable}) |> String.slice(0, 200)

    latest =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run && run["issue_key"]]
      )

    if is_map(run) and run["kind"] == "SPECIFICATION" and run["state"] == "FAILED" and
         run["failure_code"] == expected_failure and run["run_id"] == task["run_id"] and
         run["worktree"] == task["workspace"] and latest["run_id"] == run["run_id"],
       do: :ok,
       else: {:error, :run_not_recoverable}
  end

  defp require_no_other_unresolved_request(connection, request) do
    row =
      Store.one!(
        connection,
        """
        SELECT COUNT(*) AS request_count FROM desktop_requests
        WHERE target_kind = 'TASK' AND target_key = ? AND request_key != ?
          AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')
        """,
        [request["target_key"], request["request_key"]]
      )

    if row["request_count"] == 0, do: :ok, else: {:error, :other_task_request_unresolved}
  end

  defp restore(connection, request, task, run, completed_turn_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      connection,
      "UPDATE factory_tasks SET status = 'WAITING_FOR_BROKER', failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'FAILED'",
      [timestamp, task["task_key"]]
    )

    Store.query!(
      connection,
      "UPDATE runs SET state = 'SPEC_DRAFTING', failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state = 'FAILED'",
      [timestamp, run["run_id"]]
    )

    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [
        timestamp,
        "SPECIFICATION_BROKER_READBACK_RECOVERED",
        run["run_id"],
        Jason.encode!(%{request_key: request["request_key"], completed_turn_id: completed_turn_id})
      ]
    )

    {:ok, %{result: "SPECIFICATION_BROKER_READBACK_RECOVERED", run_id: run["run_id"], task_key: task["task_key"]}}
  end
end
