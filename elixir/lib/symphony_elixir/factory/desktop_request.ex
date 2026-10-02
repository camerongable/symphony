defmodule SymphonyElixir.Factory.DesktopRequest do
  @moduledoc """
  Durable handoff requests for a Codex Desktop-owned task broker.

  Claiming a request moves it to an uncertain state before any external call.
  A broker must reconcile that state with Codex rather than issuing a second
  create or follow-up after an interrupted attempt.
  """

  alias SymphonyElixir.Factory.NativeMaintenanceEvidence
  alias SymphonyElixir.Factory.{NativeSourceBinding, NativeWorktreeProbe, RunLedger, StageSchemas}
  alias SymphonyElixir.Factory.{Store, TaskLauncher, TaskLedger, Worktree}

  @required_strings ~w(
    request_key target_kind target_key action codex_project_id model
    reasoning_effort title prompt cwd
  )
  @optional_fields ~w(existing_thread_id branch base_branch schema metadata)
  @request_fields @required_strings ++ @optional_fields
  @unresolved_statuses ~w(
    PENDING CREATE_UNCERTAIN FOLLOWUP_UNCERTAIN THREAD_RECORDED RECONCILE_REQUIRED
  )
  @native_stage_in_flight ~w(STARTING RUNNING WAITING_FOR_BROKER WAITING_FOR_WRITER STALE RETRY_PENDING)

  @doc "Enqueues one request, returning an identical existing request by stable key."
  @spec enqueue(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def enqueue(connection, attrs) when is_map(attrs) do
    with {:ok, payload} <- normalize(attrs),
         :ok <- NativeWorktreeProbe.validate_request(connection, payload) do
      Store.transaction!(connection, fn transaction -> enqueue_transaction(transaction, payload) end)
    end
  end

  @doc "Atomically claims a pending request; claims are never automatically reissued."
  @spec claim(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def claim(connection, request_key) do
    Store.transaction!(connection, &claim_transaction(&1, request_key))
  end

  @doc "Binds a verified Codex thread to the request and its task or controller."
  @spec record_thread(Store.connection(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def record_thread(connection, request_key, thread_id, verified_project_id)
      when is_binary(thread_id) and is_binary(verified_project_id) do
    record_thread(connection, request_key, thread_id, verified_project_id, nil)
  end

  @doc "Binds a native project task only after workspace readback is supplied."
  @spec record_thread(Store.connection(), String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def record_thread(connection, request_key, thread_id, verified_project_id, proof)
      when is_binary(thread_id) and is_binary(verified_project_id) do
    Store.transaction!(connection, fn transaction ->
      record_thread_transaction(transaction, request_key, thread_id, verified_project_id, proof)
    end)
  end

  @doc "Records a broker-verified result for the exact bound thread."
  @spec complete(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def complete(connection, request_key, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    Store.transaction!(connection, fn transaction ->
      with {:ok, request} <- get(transaction, request_key),
           {:ok, attrs} <- NativeMaintenanceEvidence.attach(transaction, request, attrs),
           {:ok, attrs} <- NativeSourceBinding.attach(transaction, request, attrs),
           {:ok, output} <- normalize_legacy_controller_snapshot(request, Map.get(attrs, "output")),
           {:ok, output} <- normalize_specification_critic_review(transaction, request, output),
           {:ok, output} <- normalize_change_verifier_review(transaction, request, output),
           {:ok, output} <- normalize_legacy_native_writer_slice(transaction, request, output),
           {:ok, output_json} <- encode_json(output) do
        complete_transaction(transaction, request_key, Map.put(attrs, "output", output), output_json)
      end
    end)
  end

  defp normalize_legacy_controller_snapshot(
         %{"target_kind" => "CONTROLLER", "schema_json" => schema_json},
         %{"result" => %{"snapshot_json" => snapshot} = result} = output
       )
       when is_list(snapshot) or is_map(snapshot) do
    case Jason.decode(schema_json) do
      {:ok, %{"properties" => %{"snapshot_json" => %{"type" => "string"}}}} ->
        {:ok, Map.put(output, "result", Map.put(result, "snapshot_json", canonical_json(snapshot)))}

      _other ->
        {:ok, output}
    end
  end

  defp normalize_legacy_controller_snapshot(_request, output), do: {:ok, output}

  defp normalize_specification_critic_review(
         connection,
         %{"target_kind" => "TASK", "action" => "FOLLOWUP", "target_key" => task_key},
         %{"result" => %{"verdict" => verdict, "dimension_results" => _dimensions} = review} = output
       ) do
    with {:ok, %{"role" => "specification-critic", "run_id" => run_id}} <- TaskLedger.get(connection, task_key),
         {:ok, run} <- RunLedger.get(connection, run_id),
         {:ok, snapshot} <- Jason.decode(run["snapshot_json"]),
         :ok <- validate_specification_critic_review(review, run, snapshot),
         {:ok, status} <- factory_critic_status(verdict) do
      {:ok,
       Map.put(output, "result", %{
         "status" => status,
         "findings" => review["blocking_issues"],
         "required_questions" => review["questions"]
       })}
    else
      _other -> {:error, :invalid_specification_critic_review}
    end
  end

  defp normalize_specification_critic_review(_connection, _request, output), do: {:ok, output}

  defp normalize_change_verifier_review(
         connection,
         %{"target_kind" => "TASK", "action" => "FOLLOWUP", "target_key" => task_key} = request,
         %{"result" => %{"verdict" => verdict} = review, "completed_tool_calls" => tool_calls} = output
       )
       when is_list(tool_calls) do
    with {:ok, %{"role" => "change-verifier", "run_id" => run_id} = task} <- TaskLedger.get(connection, task_key),
         {:ok, %{"kind" => "DELIVERY", "state" => "VERIFYING"} = run} <- RunLedger.get(connection, run_id),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- schema == StageSchemas.for_stage(:change_verifier),
         true <- valid_change_verifier_provenance?(review, request, task, run),
         true <- valid_change_verifier_report?(review, run),
         true <- valid_change_verifier_verdict?(review) do
      findings = Enum.uniq(review["blocking_issues"] ++ review["required_repairs"])
      checks = Enum.map(review["checks"], &format_change_verifier_check/1)

      {:ok,
       Map.put(output, "result", %{
         "status" => verdict,
         "candidate_sha" => run["candidate_sha"],
         "findings" => findings,
         "checks" => checks
       })}
    else
      _other -> {:error, :invalid_change_verifier_review}
    end
  end

  defp normalize_change_verifier_review(_connection, _request, output), do: {:ok, output}

  defp valid_change_verifier_provenance?(review, request, task, run) do
    valid_change_verifier_checkout?(review, request, task, run) and
      valid_change_verifier_contract?(review, run)
  end

  defp valid_change_verifier_contract?(review, run) do
    review["issue_key"] == run["issue_key"] and
      review["spec_revision"] == run["spec_revision"] and
      review["contract_sha256"] == run["contract_sha256"] and
      valid_change_verifier_base?(review, run)
  end

  defp valid_change_verifier_base?(review, run) do
    base_ref = review["base_ref"]

    cond do
      base_ref in [run["base_branch"], "origin/#{run["base_branch"]}"] ->
        true

      not is_binary(base_ref) or not Regex.match?(~r/\A[0-9a-f]{40}\z/, base_ref) ->
        false

      not File.dir?(review["review_worktree"]) ->
        false

      true ->
        case System.cmd("git", ["merge-base", "refs/remotes/origin/#{run["base_branch"]}", run["candidate_sha"]], cd: review["review_worktree"], stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha) == base_ref
          _other -> false
        end
    end
  end

  defp valid_change_verifier_checkout?(review, request, task, run) do
    review["head_sha"] == run["candidate_sha"] and
      review["review_worktree"] == task["workspace"] and
      task["workspace"] == request["verified_cwd"] and
      task["workspace_sha"] == run["candidate_sha"] and
      request["verified_head_sha"] == run["candidate_sha"] and
      task["thread_id"] == request["thread_id"] and
      task["codex_project_id"] == request["verified_project_id"]
  end

  defp valid_change_verifier_report?(review, run) do
    Enum.sort(Map.keys(review)) ==
      Enum.sort(
        ~w(verdict issue_key spec_revision contract_sha256 base_ref head_sha review_worktree acceptance checks manual_validation risks reviewer_tracked_changes blocking_issues required_repairs)
      ) and
      valid_change_verifier_evidence?(review) and
      is_map(review["manual_validation"]) and
      valid_change_verifier_manual?(review["manual_validation"], run) and
      valid_change_verifier_findings?(review)
  end

  defp valid_change_verifier_evidence?(review) do
    is_list(review["acceptance"]) and review["acceptance"] != [] and
      Enum.all?(review["acceptance"], &valid_change_verifier_acceptance?/1) and
      is_list(review["checks"]) and Enum.all?(review["checks"], &valid_change_verifier_check?/1)
  end

  defp valid_change_verifier_findings?(review) do
    valid_review_strings?(review["risks"]) and
      review["reviewer_tracked_changes"] == [] and
      valid_review_strings?(review["blocking_issues"]) and
      valid_review_strings?(review["required_repairs"])
  end

  defp valid_change_verifier_acceptance?(%{"id" => id, "result" => result, "evidence" => evidence} = item) do
    Enum.sort(Map.keys(item)) == ~w(evidence id result) and
      is_binary(id) and String.match?(id, ~r/^AC-\d+$/) and
      result in ~w(PASS FAIL) and is_binary(evidence) and String.trim(evidence) != ""
  end

  defp valid_change_verifier_acceptance?(_item), do: false

  defp valid_change_verifier_check?(%{"command_or_pipeline" => command, "result" => result, "scope" => scope} = item) do
    Enum.sort(Map.keys(item)) == ~w(command_or_pipeline result scope) and
      is_binary(command) and String.trim(command) != "" and
      result in ~w(PASS FAIL NOT_RUN) and is_binary(scope) and String.trim(scope) != ""
  end

  defp valid_change_verifier_check?(_item), do: false

  defp valid_change_verifier_manual?(manual, run) do
    Enum.sort(Map.keys(manual)) == ~w(blockers case_ids plan_ready required) and
      manual["required"] == (run["manual_validation_required"] == 1) and
      is_boolean(manual["plan_ready"]) and
      valid_review_strings?(manual["case_ids"]) and
      valid_review_strings?(manual["blockers"])
  end

  defp valid_change_verifier_verdict?(%{"verdict" => "PASS"} = review) do
    Enum.all?(review["acceptance"], &(&1["result"] == "PASS")) and
      Enum.all?(review["checks"], &(&1["result"] != "FAIL")) and
      review["risks"] == [] and review["blocking_issues"] == [] and
      review["required_repairs"] == [] and
      (not review["manual_validation"]["required"] or
         (review["manual_validation"]["plan_ready"] and review["manual_validation"]["blockers"] == []))
  end

  defp valid_change_verifier_verdict?(%{"verdict" => "REPAIR"} = review) do
    review["required_repairs"] != [] and
      Enum.any?(review["acceptance"], &(&1["result"] == "FAIL"))
  end

  defp valid_change_verifier_verdict?(%{"verdict" => "BLOCK"} = review),
    do: review["blocking_issues"] != []

  defp valid_change_verifier_verdict?(_review), do: false

  defp format_change_verifier_check(check) do
    "#{check["result"]}: #{check["command_or_pipeline"]} [#{check["scope"]}]"
  end

  defp normalize_legacy_native_writer_slice(
         connection,
         %{"target_kind" => "TASK", "action" => "FOLLOWUP", "target_key" => task_key} = request,
         %{"result" => %{"status" => "CONTINUE"} = result, "completed_tool_calls" => []} = output
       ) do
    with {:ok, task} <- TaskLedger.get(connection, task_key),
         true <- TaskLedger.source_writer?(task),
         {:ok, %{"kind" => "DELIVERY"}} <- RunLedger.get(connection, task["run_id"]),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- legacy_native_writer_schema?(schema),
         true <- legacy_native_writer_slice?(result) do
      normalized =
        result
        |> Map.delete("next_slice")
        |> Map.put("summary", result["commit_message"])
        |> Map.put("remaining_criteria", [result["next_slice"]])

      {:ok, Map.put(output, "result", normalized)}
    else
      _other -> {:ok, output}
    end
  end

  defp normalize_legacy_native_writer_slice(_connection, _request, output), do: {:ok, output}

  defp legacy_native_writer_schema?(schema) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    Enum.all?(~w(status summary changed_paths commit_message remaining_criteria blockers checks), &(&1 in required)) and
      not Map.has_key?(properties, "next_slice")
  end

  defp legacy_native_writer_slice?(result) do
    Enum.sort(Map.keys(result)) == Enum.sort(~w(status changed_paths commit_message checks blockers next_slice)) and
      is_binary(result["commit_message"]) and is_binary(result["next_slice"])
  end

  defp validate_specification_critic_review(review, run, snapshot) do
    findings = review["blocking_issues"]
    questions = review["questions"]
    dimensions = review["dimension_results"]

    valid? =
      valid_review_provenance?(review, run, snapshot) and
        valid_review_payload?(review, findings, questions, dimensions) and
        valid_review_verdict?(review["verdict"], findings, questions, dimensions)

    if valid?, do: :ok, else: {:error, :invalid_specification_critic_review}
  end

  defp valid_review_provenance?(review, run, snapshot) do
    review["issue_key"] == run["issue_key"] and
      review["spec_revision"] == run["spec_revision"] and
      review["contract_sha256"] == run["contract_sha256"] and
      is_binary(snapshot["updated"]) and review["jira_update_marker"] == snapshot["updated"]
  end

  defp valid_review_payload?(review, findings, questions, dimensions) do
    valid_review_strings?(findings) and valid_review_strings?(questions) and
      is_list(dimensions) and dimensions != [] and Enum.all?(dimensions, &valid_review_dimension?/1) and
      (is_nil(review["recommended_default"]) or is_binary(review["recommended_default"]))
  end

  defp valid_review_strings?(values) when is_list(values),
    do: Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))

  defp valid_review_strings?(_values), do: false

  defp valid_review_dimension?(%{"dimension" => dimension, "pass" => passed?, "evidence" => evidence}) do
    is_binary(dimension) and dimension != "" and is_boolean(passed?) and is_binary(evidence) and evidence != ""
  end

  defp valid_review_dimension?(_dimension), do: false

  defp valid_review_verdict?("PASS", [], [], dimensions), do: Enum.all?(dimensions, & &1["pass"])
  defp valid_review_verdict?("FAIL", findings, _questions, _dimensions), do: findings != []
  defp valid_review_verdict?("NEEDS_DECISION", _findings, questions, _dimensions), do: questions != []
  defp valid_review_verdict?(_verdict, _findings, _questions, _dimensions), do: false

  defp factory_critic_status("PASS"), do: {:ok, "PASS"}
  defp factory_critic_status("FAIL"), do: {:ok, "REPAIR"}
  defp factory_critic_status("NEEDS_DECISION"), do: {:ok, "BLOCK"}
  defp factory_critic_status(_verdict), do: {:error, :invalid_critic_verdict}

  @doc "Marks an unclaimed failure terminal, or a claimed failure for reconciliation."
  @spec fail(Store.connection(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fail(connection, request_key, reason, opts \\ []) when is_binary(reason) do
    Store.transaction!(connection, &fail_transaction(&1, request_key, reason, opts))
  end

  @doc "Returns the durable request by stable key."
  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, :unknown_request}
  def get(connection, request_key) do
    case Store.one!(connection, "SELECT * FROM desktop_requests WHERE request_key = ?", [request_key]) do
      nil -> {:error, :unknown_request}
      request -> {:ok, request}
    end
  end

  @doc false
  @spec payload_intact?(map()) :: boolean()
  def payload_intact?(request) when is_map(request) do
    payload =
      request
      |> Map.take(@required_strings ++ ~w(existing_thread_id branch base_branch))
      |> Map.put("existing_thread_id", request["existing_thread_id"])
      |> Map.put("branch", request["branch"])
      |> Map.put("base_branch", request["base_branch"])
      |> Map.put("schema_json", request["schema_json"])
      |> Map.put("metadata_json", request["metadata_json"])

    request["payload_sha256"] == digest(payload)
  rescue
    _error -> false
  end

  def payload_intact?(_request), do: false

  @doc "Lists only requests safe to issue exactly once through the Desktop broker."
  @spec list_pending(Store.connection(), pos_integer()) :: [map()]
  def list_pending(connection, limit \\ 50) when is_integer(limit) and limit > 0 do
    list_by_status(connection, "status = 'PENDING'", limit)
  end

  @doc "Lists interrupted or ambiguous requests that need Codex readback."
  @spec list_reconciliation(Store.connection(), pos_integer()) :: [map()]
  def list_reconciliation(connection, limit \\ 50) when is_integer(limit) and limit > 0 do
    list_by_status(
      connection,
      "status IN ('CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')",
      limit
    )
  end

  @doc "Repairs pre-atomic native stage successes whose task result was never recorded."
  @spec reconcile_native_successes(Store.connection(), pos_integer()) :: :ok | {:error, term()}
  def reconcile_native_successes(connection, limit \\ 100) when is_integer(limit) and limit > 0 do
    rows =
      Store.query!(
        connection,
        """
        SELECT request_key FROM desktop_requests AS request
        JOIN factory_tasks AS task ON task.task_key = request.target_key
        WHERE request.target_kind = 'TASK' AND request.action = 'FOLLOWUP'
          AND request.status = 'SUCCEEDED' AND task.output_json IS NULL
          AND (task.turn_id IS NULL OR task.turn_id != request.turn_id)
          AND json_extract(request.metadata_json, '$.workspace_mode') = 'CODEX_NATIVE'
          AND json_type(request.metadata_json, '$.maintenance_operation') IS NULL
          AND task.status IN ('STARTING', 'RUNNING', 'WAITING_FOR_BROKER', 'WAITING_FOR_WRITER', 'STALE', 'RETRY_PENDING')
          AND request.request_key = (
            SELECT latest.request_key FROM desktop_requests AS latest
            WHERE latest.target_kind = 'TASK' AND latest.target_key = request.target_key
              AND latest.action = 'FOLLOWUP'
              AND json_type(latest.metadata_json, '$.maintenance_operation') IS NULL
            ORDER BY latest.updated_at DESC, latest.request_key DESC LIMIT 1
          )
        ORDER BY request.updated_at DESC LIMIT ?
        """,
        [limit]
      ).rows

    Enum.reduce_while(rows, :ok, &reconcile_native_success_row(connection, &1, &2))
  end

  defp reconcile_native_success_row(connection, [request_key], :ok) do
    case get(connection, request_key) do
      {:ok, request} -> reconcile_native_success_request(connection, request)
      {:error, _reason} -> {:cont, :ok}
    end
  end

  defp reconcile_native_success_request(connection, request) do
    request_key = request["request_key"]

    if is_nil(TaskLauncher.active_owner(request["target_key"])) do
      case Store.transaction!(connection, &reconcile_native_success(&1, request_key)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, {:error, {:native_success_reconciliation_failed, request_key, error}}}
      end
    else
      {:cont, :ok}
    end
  end

  defp claim_transaction(connection, request_key) do
    with {:ok, request} <- get(connection, request_key),
         :ok <- require_status(request, "PENDING") do
      status = if request["action"] == "CREATE", do: "CREATE_UNCERTAIN", else: "FOLLOWUP_UNCERTAIN"
      timestamp = now()

      Store.query!(
        connection,
        "UPDATE desktop_requests SET status = ?, claimed_at = ?, updated_at = ? WHERE request_key = ? AND status = 'PENDING'",
        [status, timestamp, timestamp, request_key]
      )

      get(connection, request_key)
    end
  end

  defp record_thread_transaction(connection, request_key, thread_id, verified_project_id, proof) do
    with :ok <- require_nonempty(thread_id, :thread_id),
         :ok <- require_nonempty(verified_project_id, :verified_project_id),
         {:ok, request} <- get(connection, request_key),
         :ok <- verify_project(request, verified_project_id),
         :ok <- require_recordable(request, thread_id) do
      bind_recorded_thread(connection, request, thread_id, verified_project_id, proof)
    end
  end

  defp bind_recorded_thread(_connection, %{"status" => status} = request, _thread_id, _project_id, _proof)
       when status in ["THREAD_RECORDED", "SUCCEEDED"],
       do: {:ok, request}

  defp bind_recorded_thread(connection, request, thread_id, project_id, proof) do
    case NativeWorktreeProbe.operation(request) do
      {:ok, nil} ->
        bind_standard_thread(connection, request, thread_id, project_id, proof)

      {:ok, _operation} ->
        with {:ok, workspace} <- NativeWorktreeProbe.record(connection, request, thread_id, proof) do
          maybe_record_thread(connection, request, thread_id, project_id, workspace)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp bind_standard_thread(connection, request, thread_id, project_id, proof) do
    proof = if is_map(proof), do: proof |> stringify_keys() |> Map.put("thread_id", thread_id), else: proof

    with {:ok, workspace} <- verify_native_workspace(connection, request, proof),
         :ok <- bind_target_thread(connection, request, thread_id),
         :ok <- bind_native_workspace(connection, request, workspace) do
      maybe_record_thread(connection, request, thread_id, project_id, workspace)
    end
  end

  defp verify_native_workspace(connection, request, proof) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]) do
      case {request["target_kind"], metadata["workspace_mode"]} do
        {"TASK", "CODEX_NATIVE"} -> verify_native_task_workspace(connection, request, metadata, proof)
        {"TASK", "CODEX_PROJECT_LOCAL"} -> verify_project_local_task(connection, request, metadata, proof)
        {"TASK", nil} -> {:ok, nil}
        {"CONTROLLER", _mode} -> {:ok, nil}
        _other -> {:error, :unsupported_task_workspace_mode}
      end
    end
  end

  defp verify_project_local_task(_connection, _request, _metadata, proof) when not is_map(proof),
    do: {:error, :project_local_route_proof_required}

  defp verify_project_local_task(connection, request, metadata, proof) do
    proof = stringify_keys(proof)

    with {:ok, task} <- TaskLedger.get(connection, request["target_key"]),
         {:ok, run} <- RunLedger.get(connection, task["run_id"]),
         :ok <- require_project_local_identity(run, task),
         :ok <- require_project_local_record_route(request, metadata, proof, run) do
      {:ok, %{path: request["cwd"], sha: nil, mode: :project_local}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp require_project_local_identity(run, task) do
    cond do
      run["kind"] != "SPECIFICATION" or run["state"] != "CONTRACT_DISCUSSING" ->
        {:error, :project_local_run_mismatch}

      task["stage"] != "CONTRACT_DISCUSSING" or task["role"] != "specification-author" ->
        {:error, :project_local_task_mismatch}

      not project_local_checkout_empty?(run, task) ->
        {:error, :project_local_checkout_not_empty}

      true ->
        :ok
    end
  end

  defp project_local_checkout_empty?(run, task) do
    present?(run["parent_run_id"]) and not present?(run["worktree"]) and
      not present?(task["workspace"]) and not present?(task["workspace_sha"])
  end

  defp require_project_local_record_route(request, metadata, proof, run) do
    cond do
      not present?(run["repo_path"]) ->
        {:error, :project_local_route_mismatch}

      request["cwd"] != Path.expand(run["repo_path"]) or proof["cwd"] != request["cwd"] ->
        {:error, :project_local_path_mismatch}

      request["base_branch"] != run["base_branch"] or not is_nil(request["branch"]) or
        not is_nil(metadata["expected_sha"]) or metadata["issue_key"] != run["issue_key"] ->
        {:error, :project_local_route_mismatch}

      true ->
        :ok
    end
  end

  defp verify_native_task_workspace(_connection, _request, _metadata, proof) when not is_map(proof),
    do: {:error, :native_workspace_proof_required}

  defp verify_native_task_workspace(connection, request, metadata, proof) do
    proof = stringify_keys(proof)

    if NativeSourceBinding.bootstrap?(request) do
      NativeSourceBinding.record(connection, request, proof["thread_id"], proof)
    else
      verify_standard_native_workspace(connection, request, metadata, proof)
    end
  end

  defp verify_standard_native_workspace(connection, request, metadata, proof) do
    cwd = proof["cwd"]
    head_sha = proof["head_sha"]

    with :ok <- require_native_proof_fields(cwd, head_sha),
         {:ok, task} <- TaskLedger.get(connection, request["target_key"]),
         {:ok, run} <- RunLedger.get(connection, task["run_id"]),
         :ok <- require_native_repo_path(run),
         :ok <- require_native_base(request, metadata),
         {:ok, workspace} <-
           Worktree.validate_native(%{"path" => run["repo_path"]}, cwd,
             expected_sha: native_expected_sha(request, metadata, head_sha),
             expected_branch: native_expected_branch(request, task, run),
             clean: not TaskLedger.source_writer?(task) or request["action"] == "CREATE",
             detached: request["action"] == "CREATE" or not TaskLedger.source_writer?(task)
           ),
         :ok <- require_native_workspace_identity(request, task, run, workspace, head_sha) do
      {:ok, workspace}
    end
  end

  defp require_native_repo_path(%{"repo_path" => path}) when is_binary(path) and path != "", do: :ok
  defp require_native_repo_path(_run), do: {:error, :native_repository_route_missing}

  defp require_native_proof_fields(cwd, head_sha) do
    if present?(cwd) and is_binary(head_sha) and String.match?(head_sha, ~r/\A[0-9a-f]{40}\z/),
      do: :ok,
      else: {:error, :native_workspace_proof_incomplete}
  end

  defp require_native_base(%{"action" => "CREATE"}, metadata) do
    if present?(metadata["expected_sha"]), do: :ok, else: {:error, :native_base_sha_required}
  end

  defp require_native_base(_request, _metadata), do: :ok

  defp native_expected_sha(%{"action" => "CREATE"}, metadata, _head_sha), do: metadata["expected_sha"]
  defp native_expected_sha(_request, %{"expected_sha" => sha}, _head_sha) when is_binary(sha) and sha != "", do: sha
  defp native_expected_sha(_request, _metadata, head_sha), do: head_sha

  defp native_expected_branch(%{"action" => "FOLLOWUP"}, task, run) do
    if TaskLedger.source_writer?(task), do: run["branch"], else: nil
  end

  defp native_expected_branch(_request, _task, _run), do: nil

  defp require_native_workspace_identity(request, task, run, workspace, head_sha) do
    with :ok <- require_native_sha(workspace, head_sha),
         :ok <- require_native_followup_path(request, task, workspace) do
      require_native_create_path(request, task, run)
    end
  end

  defp require_native_sha(%{sha: sha}, sha), do: :ok
  defp require_native_sha(_workspace, _head_sha), do: {:error, :native_workspace_sha_mismatch}

  defp require_native_followup_path(%{"action" => "FOLLOWUP"}, task, workspace) do
    if task["workspace"] == workspace.path, do: :ok, else: {:error, :native_workspace_route_mismatch}
  end

  defp require_native_followup_path(_request, _task, _workspace), do: :ok

  defp require_native_create_path(%{"action" => "CREATE"}, task, run) do
    cond do
      present?(task["workspace"]) ->
        {:error, :native_workspace_already_bound}

      (task["role"] == "specification-author" or TaskLedger.source_writer?(task)) and
          present?(run["worktree"]) ->
        {:error, :native_run_workspace_conflict}

      true ->
        :ok
    end
  end

  defp require_native_create_path(_request, _task, _run), do: :ok

  defp bind_native_workspace(_connection, _request, nil), do: :ok
  defp bind_native_workspace(_connection, _request, %{mode: :project_local}), do: :ok

  defp bind_native_workspace(connection, request, workspace) do
    with {:ok, task} <-
           TaskLedger.update(connection, request["target_key"], %{
             workspace: workspace.path,
             workspace_sha: workspace.sha
           }) do
      bind_run_workspace(connection, request, task, workspace)
    end
  end

  defp bind_run_workspace(connection, %{"action" => "CREATE"}, task, workspace) do
    if task["role"] == "specification-author" or TaskLedger.source_writer?(task) do
      case RunLedger.update(connection, task["run_id"], %{
             worktree: workspace.path,
             workspace_state: "CODEX_NATIVE"
           }) do
        {:ok, _run} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp bind_run_workspace(_connection, _request, _task, _workspace), do: :ok

  defp maybe_record_thread(connection, request, thread_id, verified_project_id, workspace) do
    Store.query!(
      connection,
      "UPDATE desktop_requests SET thread_id = ?, verified_project_id = ?, verified_cwd = ?, verified_head_sha = ?, status = 'THREAD_RECORDED', updated_at = ? WHERE request_key = ?",
      [thread_id, verified_project_id, workspace && workspace.path, workspace && workspace.sha, now(), request["request_key"]]
    )

    get(connection, request["request_key"])
  end

  defp verify_project(request, verified_project_id) do
    if request["codex_project_id"] == verified_project_id and
         request["verified_project_id"] in [nil, verified_project_id] do
      :ok
    else
      {:error, :project_route_mismatch}
    end
  end

  defp complete_transaction(connection, request_key, attrs, output_json) do
    with {:ok, request} <- get(connection, request_key),
         :ok <- require_completion(request, attrs, output_json),
         :ok <- require_unseen_turn(connection, request, attrs),
         :ok <- validate_output(request, attrs),
         :ok <- NativeWorktreeProbe.validate_completion(connection, request, attrs),
         :ok <- NativeSourceBinding.validate_completion(connection, request, attrs),
         :ok <- require_controller_format_repair_completion(connection, request, attrs, output_json),
         {:ok, completed} <- maybe_complete(connection, request, attrs, output_json),
         :ok <- finish_controller_format_repair(connection, request, attrs, output_json) do
      {:ok, completed}
    end
  end

  defp require_controller_format_repair_completion(
         connection,
         %{
           "target_kind" => "CONTROLLER",
           "status" => "RECONCILE_REQUIRED",
           "failure_code" => "FINAL_OUTPUT_INVALID_JSON"
         } = request,
         attrs,
         output_json
       ) do
    grant =
      Store.one!(
        connection,
        "SELECT * FROM controller_format_repairs WHERE request_key = ?",
        [request["request_key"]]
      )

    control =
      Store.one!(
        connection,
        "SELECT controller_thread_id, controller_codex_project_id, controller_model, controller_reasoning_effort FROM control WHERE scope = ?",
        [request["target_key"]]
      )

    output = attrs["output"]

    cond do
      is_nil(grant) ->
        {:error, :controller_format_repair_not_authorized}

      grant["status"] == "AUTHORIZED" ->
        {:error, :controller_format_repair_not_claimed}

      not controller_format_repair_route_matches?(control, request) ->
        {:error, :controller_format_repair_binding_changed}

      grant["status"] == "SUCCEEDED" ->
        validate_succeeded_controller_repair(grant, request, attrs, output_json)

      grant["status"] == "CLAIMED" ->
        validate_claimed_controller_repair(grant, request, attrs, output)

      true ->
        {:error, :controller_format_repair_already_used}
    end
  end

  defp require_controller_format_repair_completion(_connection, _request, _attrs, _output_json), do: :ok

  defp validate_succeeded_controller_repair(grant, request, attrs, output_json) do
    if payload_intact?(request) and grant["request_payload_sha256"] == request["payload_sha256"] and
         grant["thread_id"] == request["thread_id"] and grant["repair_turn_id"] == attrs["turn_id"] and
         grant["repair_output_sha256"] == sha256(output_json),
       do: :ok,
       else: {:error, :controller_format_repair_already_used}
  end

  defp validate_claimed_controller_repair(grant, request, attrs, output) do
    cond do
      not payload_intact?(request) or grant["request_payload_sha256"] != request["payload_sha256"] or
          grant["thread_id"] != request["thread_id"] ->
        {:error, :controller_format_repair_binding_changed}

      grant["completed_turn_id"] == attrs["turn_id"] ->
        {:error, :controller_format_repair_turn_replayed}

      not is_map(output) or output["completed_tool_calls"] != [] ->
        {:error, :controller_format_repair_tool_calls_forbidden}

      true ->
        :ok
    end
  end

  defp controller_format_repair_route_matches?(control, request) do
    expected = %{
      "controller_thread_id" => request["thread_id"],
      "controller_codex_project_id" => "projectless",
      "controller_model" => request["model"],
      "controller_reasoning_effort" => request["reasoning_effort"]
    }

    is_map(control) and Map.take(control, Map.keys(expected)) == expected
  end

  defp finish_controller_format_repair(connection, request, attrs, output_json) do
    if request["target_kind"] == "CONTROLLER" and
         request["failure_code"] == "FINAL_OUTPUT_INVALID_JSON" do
      Store.query!(
        connection,
        "UPDATE controller_format_repairs SET status = 'SUCCEEDED', repair_turn_id = ?, repair_output_sha256 = ? WHERE request_key = ? AND status = 'CLAIMED'",
        [attrs["turn_id"], sha256(output_json), request["request_key"]]
      )

      repaired =
        Store.one!(
          connection,
          "SELECT status, repair_turn_id, repair_output_sha256 FROM controller_format_repairs WHERE request_key = ?",
          [request["request_key"]]
        )

      if repaired["status"] == "SUCCEEDED" and repaired["repair_turn_id"] == attrs["turn_id"] and
           repaired["repair_output_sha256"] == sha256(output_json),
         do: :ok,
         else: {:error, :controller_format_repair_already_used}
    else
      :ok
    end
  end

  defp sha256(value) when is_binary(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp reconcile_native_success(connection, request_key) do
    with {:ok, request} <- get(connection, request_key),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- metadata["workspace_mode"] == "CODEX_NATIVE" or {:error, :not_native_stage},
         {:ok, output} <- Jason.decode(request["output_json"]),
         attrs <- %{"thread_id" => request["thread_id"], "turn_id" => request["turn_id"], "output" => output},
         :ok <- validate_output(request, attrs),
         {:ok, metadata} <- stage_prompt_metadata(request, metadata) do
      complete_native_task_stage(connection, request, metadata, attrs)
    end
  end

  defp stage_prompt_metadata(_request, %{"stage_prompt_sha256" => digest} = metadata)
       when is_binary(digest) and byte_size(digest) == 64,
       do: {:ok, metadata}

  defp stage_prompt_metadata(request, metadata) do
    prefix = "Factory request ID: #{request["request_key"]}\n\n"

    if String.starts_with?(request["prompt"], prefix) do
      prompt = String.replace_prefix(request["prompt"], prefix, "")
      digest = :sha256 |> :crypto.hash(prompt) |> Base.encode16(case: :lower)
      {:ok, Map.put(metadata, "stage_prompt_sha256", digest)}
    else
      {:error, :native_stage_prompt_unrecoverable}
    end
  end

  defp require_unseen_turn(connection, request, attrs) do
    case Store.one!(
           connection,
           "SELECT request_key FROM desktop_requests WHERE thread_id = ? AND turn_id = ? AND status = 'SUCCEEDED' AND request_key != ?",
           [attrs["thread_id"], attrs["turn_id"], request["request_key"]]
         ) do
      nil -> :ok
      _existing -> {:error, :turn_replayed}
    end
  end

  defp validate_output(request, %{"output" => %{"result" => result, "completed_tool_calls" => calls}})
       when is_map(result) and is_list(calls) do
    with {:ok, schema} <- Jason.decode(request["schema_json"]),
         :ok <- StageSchemas.validate(result, schema),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         :ok <- validate_required_calls(Map.get(metadata, "required_tool_calls", []), calls) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_output(_request, _attrs), do: {:error, :invalid_broker_output}

  defp validate_required_calls(required, calls) when is_list(required) do
    missing =
      Enum.reject(required, fn expected ->
        Enum.any?(calls, fn actual ->
          same_field?(field(actual, "tool"), field(expected, "tool")) and
            (is_nil(field(expected, "server")) or
               same_field?(field(actual, "server"), field(expected, "server"))) and
            field(actual, "status") == "completed" and
            field(actual, "isError") != true and is_nil(field(actual, "error"))
        end)
      end)

    if missing == [], do: :ok, else: {:error, {:required_tool_calls_missing, missing}}
  end

  defp validate_required_calls(_required, _calls), do: {:error, :invalid_required_tool_calls}

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp field(_value, _key), do: nil

  defp same_field?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_field?(_left, _right), do: false

  defp maybe_complete(_connection, %{"status" => "SUCCEEDED"} = request, _attrs, _output_json),
    do: {:ok, request}

  defp maybe_complete(connection, request, attrs, output_json) do
    with :ok <- complete_native_stage(connection, request, attrs) do
      Store.query!(
        connection,
        "UPDATE desktop_requests SET status = 'SUCCEEDED', turn_id = ?, output_json = ?, failure_code = NULL, updated_at = ? WHERE request_key = ?",
        [Map.get(attrs, "turn_id"), output_json, now(), request["request_key"]]
      )

      get(connection, request["request_key"])
    end
  end

  defp complete_native_stage(connection, %{"target_kind" => "TASK", "action" => "FOLLOWUP"} = request, attrs) do
    case Jason.decode(request["metadata_json"]) do
      {:ok, %{"maintenance_operation" => _operation}} ->
        :ok

      {:ok, %{"workspace_mode" => "CODEX_NATIVE"} = metadata} ->
        complete_native_task_stage(connection, request, metadata, attrs)

      {:ok, %{"workspace_mode" => "CODEX_PROJECT_LOCAL"} = metadata} ->
        complete_project_local_stage(connection, request, metadata, attrs)

      {:ok, _metadata} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp complete_native_stage(connection, %{"target_kind" => "TASK", "action" => "CREATE"} = request, attrs) do
    case Jason.decode(request["metadata_json"]) do
      {:ok, %{"workspace_mode" => "CODEX_PROJECT_LOCAL"} = metadata} ->
        complete_project_local_stage(connection, request, metadata, attrs)

      {:ok, _metadata} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp complete_native_stage(_connection, _request, _attrs), do: :ok

  defp complete_project_local_stage(connection, request, metadata, attrs) do
    with {:ok, task} <- TaskLedger.get(connection, request["target_key"]),
         {:ok, run} <- RunLedger.get(connection, task["run_id"]),
         :ok <- require_project_local_identity(run, task),
         :ok <- require_project_local_completion_route(request, attrs, run, task),
         true <-
           task["prompt_sha256"] == metadata["stage_prompt_sha256"] or
             {:error, :project_local_prompt_mismatch},
         true <-
           project_local_turn_matches?(request, task, metadata) or
             {:error, :project_local_turn_mismatch},
         {:ok, inner_json} <- encode_json(attrs["output"]["result"]),
         {:ok, _task} <-
           TaskLedger.update_if_current(
             connection,
             request["target_key"],
             metadata["stage_prompt_sha256"],
             @native_stage_in_flight,
             %{status: "COMPLETE", turn_id: attrs["turn_id"], output_json: inner_json, failure_code: nil}
           ) do
      :ok
    else
      {:skipped, _task} -> {:error, :project_local_task_changed}
      {:error, _reason} = error -> error
    end
  end

  defp require_project_local_completion_route(request, attrs, run, task) do
    cond do
      task["status"] not in @native_stage_in_flight ->
        {:error, :project_local_task_changed}

      not present?(run["repo_path"]) ->
        {:error, :project_local_route_mismatch}

      task["thread_id"] != request["thread_id"] or task["thread_id"] != attrs["thread_id"] or
        task["codex_project_id"] != request["verified_project_id"] or
          request["verified_cwd"] != Path.expand(run["repo_path"]) ->
        {:error, :project_local_binding_mismatch}

      true ->
        :ok
    end
  end

  defp project_local_turn_matches?(%{"action" => "CREATE"}, task, metadata),
    do: is_nil(task["turn_id"]) and is_nil(metadata["previous_turn_id"])

  defp project_local_turn_matches?(%{"action" => "FOLLOWUP"}, task, metadata),
    do: present?(task["turn_id"]) and task["turn_id"] == metadata["previous_turn_id"]

  defp project_local_turn_matches?(_request, _task, _metadata), do: false

  defp complete_native_task_stage(connection, request, metadata, attrs) do
    with {:ok, task} <- TaskLedger.get(connection, request["target_key"]),
         :ok <- require_native_stage_task(connection, request, metadata, task, attrs),
         {:ok, inner_json} <- encode_json(attrs["output"]["result"]),
         {:ok, _task} <-
           TaskLedger.update_if_current(
             connection,
             request["target_key"],
             metadata["stage_prompt_sha256"],
             @native_stage_in_flight,
             %{status: "COMPLETE", turn_id: attrs["turn_id"], output_json: inner_json, failure_code: nil}
           ) do
      :ok
    else
      {:skipped, _task} -> {:error, :native_stage_task_changed}
      {:error, _reason} = error -> error
    end
  end

  defp require_native_stage_task(connection, request, metadata, task, attrs) do
    with :ok <- require_native_stage_route(request, task, attrs),
         :ok <- require_native_stage_prompt(metadata, task),
         :ok <- require_native_stage_status(task) do
      require_native_stage_lineage(connection, request, metadata, task)
    end
  end

  defp require_native_stage_route(request, task, attrs) do
    if task["thread_id"] == request["thread_id"] and task["thread_id"] == attrs["thread_id"] and
         task["codex_project_id"] == request["codex_project_id"] and
         task["workspace"] == request["verified_cwd"],
       do: :ok,
       else: {:error, :native_stage_task_route_mismatch}
  end

  defp require_native_stage_prompt(metadata, task) do
    if is_binary(metadata["stage_prompt_sha256"]) and task["prompt_sha256"] == metadata["stage_prompt_sha256"],
      do: :ok,
      else: {:error, :native_stage_prompt_mismatch}
  end

  defp require_native_stage_status(task) do
    if task["status"] in @native_stage_in_flight,
      do: :ok,
      else: {:error, :native_stage_task_not_in_flight}
  end

  defp require_native_stage_lineage(connection, request, metadata, task) do
    cond do
      not present?(metadata["previous_turn_id"]) -> {:error, :native_stage_lineage_missing}
      task["turn_id"] == metadata["previous_turn_id"] -> :ok
      is_nil(task["turn_id"]) and first_native_stage?(connection, request, metadata) -> :ok
      true -> {:error, :native_stage_lineage_mismatch}
    end
  end

  defp first_native_stage?(connection, request, metadata) do
    prior_stage =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'FOLLOWUP' AND status = 'SUCCEEDED' AND request_key != ?",
        [request["target_key"], request["request_key"]]
      )

    bootstrap =
      Store.one!(
        connection,
        "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'CREATE' AND status = 'SUCCEEDED' AND thread_id = ? AND turn_id = ?",
        [request["target_key"], request["thread_id"], metadata["previous_turn_id"]]
      )

    prior_stage["count"] == 0 and not is_nil(bootstrap)
  end

  defp fail_transaction(connection, request_key, reason, opts) do
    with :ok <- require_nonempty(reason, :failure_code),
         {:ok, request} <- get(connection, request_key),
         :ok <- require_failable(request),
         :ok <- require_definitive_create_rejection(request, reason, opts) do
      status = if request["status"] == "PENDING", do: "FAILED", else: "RECONCILE_REQUIRED"
      rejected_tool_call_id = Keyword.get(opts, :rejected_tool_call_id)

      Store.query!(
        connection,
        "UPDATE desktop_requests SET status = ?, failure_code = ?, rejected_tool_call_id = COALESCE(rejected_tool_call_id, ?), updated_at = ? WHERE request_key = ?",
        [status, reason, rejected_tool_call_id, now(), request_key]
      )

      if reason == "CREATE_THREAD_INVALID_ARGUMENTS" do
        Store.query!(
          connection,
          "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
          [now(), "NATIVE_CREATE_PRECREATION_REJECTED", nil, Jason.encode!(%{request_key: request_key, rejected_tool_call_id: rejected_tool_call_id})]
        )
      end

      get(connection, request_key)
    end
  end

  defp require_definitive_create_rejection(request, "CREATE_THREAD_INVALID_ARGUMENTS", opts) do
    call_id = Keyword.get(opts, :rejected_tool_call_id)

    if unbound_claimed_create?(request) and
         is_binary(call_id) and Regex.match?(~r/\Aexec-[0-9a-f-]+\z/, call_id) and
         Keyword.get(opts, :tool_error) == "create_thread received invalid arguments" do
      :ok
    else
      {:error, :definitive_create_rejection_evidence_required}
    end
  end

  defp require_definitive_create_rejection(_request, _reason, opts) do
    if opts == [], do: :ok, else: {:error, :unexpected_failure_evidence}
  end

  defp unbound_claimed_create?(request) do
    request["action"] == "CREATE" and request["target_kind"] == "TASK" and
      request["status"] == "CREATE_UNCERTAIN" and is_nil(request["rejected_tool_call_id"]) and
      is_nil(request["thread_id"]) and is_nil(request["turn_id"])
  end

  defp enqueue_transaction(connection, payload) do
    case get(connection, payload["request_key"]) do
      {:ok, existing} ->
        if existing["payload_sha256"] == payload["payload_sha256"],
          do: {:ok, existing},
          else: {:error, :request_key_conflict}

      {:error, :unknown_request} ->
        with :ok <- NativeWorktreeProbe.validate_request(connection, payload),
             :ok <- validate_target(connection, payload),
             :ok <- validate_target_available(connection, payload) do
          timestamp = now()

          Store.query!(
            connection,
            """
            INSERT INTO desktop_requests(
              request_key, target_kind, target_key, action, status,
              payload_sha256, codex_project_id, model, reasoning_effort,
              existing_thread_id, title, prompt, schema_json, cwd, branch,
              base_branch, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, 'PENDING', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
              payload["request_key"],
              payload["target_kind"],
              payload["target_key"],
              payload["action"],
              payload["payload_sha256"],
              payload["codex_project_id"],
              payload["model"],
              payload["reasoning_effort"],
              payload["existing_thread_id"],
              payload["title"],
              payload["prompt"],
              payload["schema_json"],
              payload["cwd"],
              payload["branch"],
              payload["base_branch"],
              payload["metadata_json"],
              timestamp,
              timestamp
            ]
          )

          get(connection, payload["request_key"])
        end
    end
  end

  defp normalize(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- validate_fields(attrs),
         :ok <- validate_action(attrs),
         :ok <- validate_existing_thread(attrs),
         :ok <- validate_cwd(attrs) do
      normalize_json_fields(attrs)
    end
  end

  defp validate_fields(attrs) do
    unknown = Map.keys(attrs) -- @request_fields
    missing = Enum.reject(@required_strings, &present?(Map.get(attrs, &1)))

    cond do
      unknown != [] -> {:error, {:unknown_request_fields, Enum.sort(unknown)}}
      missing != [] -> {:error, {:missing_request_fields, missing}}
      attrs["target_kind"] not in ["TASK", "CONTROLLER"] -> {:error, :invalid_target_kind}
      true -> :ok
    end
  end

  defp validate_action(%{"action" => action}) when action in ["CREATE", "FOLLOWUP"], do: :ok
  defp validate_action(_attrs), do: {:error, :invalid_action}

  defp validate_existing_thread(attrs) do
    cond do
      attrs["action"] == "CREATE" and present?(attrs["existing_thread_id"]) ->
        {:error, :unexpected_existing_thread}

      attrs["action"] == "FOLLOWUP" and not present?(attrs["existing_thread_id"]) ->
        {:error, :missing_existing_thread}

      true ->
        :ok
    end
  end

  defp validate_cwd(%{"cwd" => cwd}) do
    if Path.type(cwd) == :absolute, do: :ok, else: {:error, :cwd_must_be_absolute}
  end

  defp normalize_json_fields(attrs) do
    with {:ok, schema} <- normalize_schema(Map.get(attrs, "schema", %{})),
         metadata when is_map(metadata) <- Map.get(attrs, "metadata", %{}),
         {:ok, schema_json} <- encode_json(schema),
         {:ok, metadata_json} <- encode_json(metadata) do
      payload =
        attrs
        |> Map.take(@required_strings ++ ~w(existing_thread_id branch base_branch))
        |> Map.put("existing_thread_id", Map.get(attrs, "existing_thread_id"))
        |> Map.put("branch", Map.get(attrs, "branch"))
        |> Map.put("base_branch", Map.get(attrs, "base_branch"))
        |> Map.put("schema_json", schema_json)
        |> Map.put("metadata_json", metadata_json)

      {:ok, Map.put(payload, "payload_sha256", digest(payload))}
    else
      _other -> {:error, :invalid_request_json}
    end
  end

  defp validate_target(connection, %{"target_kind" => "TASK"} = payload) do
    case Store.one!(connection, "SELECT * FROM factory_tasks WHERE task_key = ?", [payload["target_key"]]) do
      nil ->
        {:error, :unknown_target_task}

      task ->
        with :ok <- NativeWorktreeProbe.validate_request(connection, payload),
             :ok <- NativeSourceBinding.validate_request(connection, payload),
             {:ok, operation} <- NativeWorktreeProbe.operation(payload) do
          validate_task_route(task, payload, operation || source_bootstrap_operation(payload))
        end
    end
  end

  defp validate_target(connection, %{"target_kind" => "CONTROLLER"} = payload) do
    case Store.one!(connection, "SELECT * FROM control WHERE scope = ?", [payload["target_key"]]) do
      nil -> {:error, :unknown_controller_scope}
      control -> validate_route_and_thread(control, payload, "controller_codex_project_id", "controller_thread_id")
    end
  end

  defp source_bootstrap_operation(payload) do
    if NativeSourceBinding.bootstrap?(payload), do: :source_bootstrap
  end

  defp validate_task_route(task, payload, nil),
    do: validate_route_and_thread(task, payload, "codex_project_id", "thread_id")

  defp validate_task_route(task, payload, _maintenance_operation) do
    with :ok <- validate_project_route(task, payload, "codex_project_id") do
      validate_thread_route(task, payload, "thread_id")
    end
  end

  defp validate_route_and_thread(target, payload, project_field, thread_field) do
    with :ok <- validate_project_route(target, payload, project_field),
         :ok <- validate_model_route(target, payload, project_field) do
      validate_thread_route(target, payload, thread_field)
    end
  end

  defp validate_project_route(target, payload, project_field) do
    bound_project = target[project_field]

    cond do
      bound_project not in [nil, payload["codex_project_id"]] ->
        {:error, :project_route_mismatch}

      project_field == "codex_project_id" and is_nil(bound_project) ->
        {:error, :project_route_unbound}

      true ->
        :ok
    end
  end

  defp validate_model_route(_target, _payload, "controller_codex_project_id"), do: :ok

  defp validate_model_route(target, payload, "codex_project_id") do
    cond do
      target["model"] not in [nil, payload["model"]] -> {:error, :model_route_mismatch}
      target["reasoning_effort"] not in [nil, payload["reasoning_effort"]] -> {:error, :effort_route_mismatch}
      true -> :ok
    end
  end

  defp validate_thread_route(target, payload, thread_field) do
    cond do
      payload["action"] == "CREATE" and present?(target[thread_field]) ->
        {:error, :thread_already_exists}

      payload["action"] == "FOLLOWUP" and target[thread_field] != payload["existing_thread_id"] ->
        {:error, :thread_route_mismatch}

      true ->
        :ok
    end
  end

  defp validate_target_available(connection, payload) do
    placeholders = Enum.map_join(@unresolved_statuses, ", ", fn _ -> "?" end)

    case Store.one!(
           connection,
           "SELECT request_key FROM desktop_requests WHERE target_kind = ? AND target_key = ? AND status IN (#{placeholders})",
           [payload["target_kind"], payload["target_key"] | @unresolved_statuses]
         ) do
      nil -> :ok
      _existing -> {:error, :target_has_unresolved_request}
    end
  end

  defp require_status(%{"status" => expected}, expected), do: :ok
  defp require_status(%{"status" => actual}, _expected), do: {:error, {:not_claimable, actual}}

  defp require_recordable(%{"status" => "SUCCEEDED", "thread_id" => thread_id}, thread_id),
    do: :ok

  defp require_recordable(%{"status" => "THREAD_RECORDED", "thread_id" => thread_id}, thread_id),
    do: :ok

  defp require_recordable(%{"status" => status, "thread_id" => bound} = request, thread_id)
       when status in ["CREATE_UNCERTAIN", "FOLLOWUP_UNCERTAIN", "RECONCILE_REQUIRED"] do
    cond do
      present?(bound) and bound != thread_id ->
        {:error, :thread_route_mismatch}

      request["action"] == "FOLLOWUP" and request["existing_thread_id"] != thread_id ->
        {:error, :thread_route_mismatch}

      true ->
        :ok
    end
  end

  defp require_recordable(%{"status" => status}, _thread_id), do: {:error, {:not_recordable, status}}

  defp bind_target_thread(connection, %{"target_kind" => "TASK"} = request, thread_id) do
    with :ok <- validate_target_route_for_record(connection, request) do
      task = Store.one!(connection, "SELECT thread_id FROM factory_tasks WHERE task_key = ?", [request["target_key"]])

      if task["thread_id"] in [nil, thread_id] do
        Store.query!(
          connection,
          "UPDATE factory_tasks SET thread_id = ?, updated_at = ? WHERE task_key = ?",
          [thread_id, now(), request["target_key"]]
        )

        :ok
      else
        {:error, :thread_route_mismatch}
      end
    end
  end

  defp bind_target_thread(connection, %{"target_kind" => "CONTROLLER"} = request, thread_id) do
    with :ok <- validate_target_route_for_record(connection, request) do
      Store.query!(
        connection,
        """
        UPDATE control
        SET controller_thread_id = ?,
            controller_codex_project_id = COALESCE(controller_codex_project_id, ?),
            controller_model = ?,
            controller_reasoning_effort = ?,
            updated_at = ?
        WHERE scope = ?
        """,
        [
          thread_id,
          request["codex_project_id"],
          request["model"],
          request["reasoning_effort"],
          now(),
          request["target_key"]
        ]
      )

      :ok
    end
  end

  defp validate_target_route_for_record(connection, request) do
    payload =
      request
      |> Map.take(~w(target_kind target_key action codex_project_id model reasoning_effort existing_thread_id))
      |> Map.put("action", "FOLLOWUP")
      |> Map.put("existing_thread_id", request["thread_id"] || request["existing_thread_id"])

    case request["action"] do
      "CREATE" -> validate_creation_route_for_record(connection, request)
      "FOLLOWUP" -> validate_target(connection, payload)
    end
  end

  defp validate_creation_route_for_record(connection, request) do
    payload = Map.put(request, "action", "CREATE")

    case validate_target(connection, payload) do
      {:error, :thread_already_exists} ->
        target_thread =
          case request["target_kind"] do
            "TASK" ->
              Store.one!(connection, "SELECT thread_id FROM factory_tasks WHERE task_key = ?", [request["target_key"]])[
                "thread_id"
              ]

            "CONTROLLER" ->
              Store.one!(connection, "SELECT controller_thread_id FROM control WHERE scope = ?", [request["target_key"]])[
                "controller_thread_id"
              ]
          end

        if target_thread == request["thread_id"] and present?(target_thread), do: :ok, else: {:error, :thread_route_mismatch}

      other ->
        other
    end
  end

  defp require_completion(%{"status" => "SUCCEEDED"} = request, attrs, output_json) do
    if request["thread_id"] == attrs["thread_id"] and
         request["turn_id"] == attrs["turn_id"] and request["output_json"] == output_json,
       do: :ok,
       else: {:error, :completion_conflict}
  end

  defp require_completion(%{"status" => "THREAD_RECORDED"} = request, attrs, _output_json) do
    case require_matching_thread(request, attrs) do
      :ok -> require_fresh_turn(request, attrs)
      {:error, _reason} = error -> error
    end
  end

  defp require_completion(%{"status" => "RECONCILE_REQUIRED", "claimed_at" => claimed_at} = request, attrs, _output_json)
       when is_binary(claimed_at) do
    case require_matching_thread(request, attrs) do
      :ok -> require_fresh_turn(request, attrs)
      {:error, _reason} = error -> error
    end
  end

  defp require_completion(request, _attrs, _output_json), do: {:error, {:not_completable, request["status"]}}

  defp require_matching_thread(request, attrs) do
    if present?(attrs["thread_id"]) and attrs["thread_id"] == request["thread_id"],
      do: :ok,
      else: {:error, :thread_route_mismatch}
  end

  defp require_fresh_turn(request, attrs) do
    cond do
      not present?(attrs["turn_id"]) -> {:error, :turn_id_missing}
      attrs["turn_id"] == previous_turn_id(request) -> {:error, :turn_replayed}
      true -> :ok
    end
  end

  defp previous_turn_id(%{"metadata_json" => metadata_json}) do
    case Jason.decode(metadata_json) do
      {:ok, %{"previous_turn_id" => turn_id}} -> turn_id
      _other -> nil
    end
  end

  defp require_failable(%{"status" => "SUCCEEDED"}), do: {:error, :already_succeeded}
  defp require_failable(%{"status" => "FAILED"}), do: {:error, :already_failed}
  defp require_failable(_request), do: :ok

  defp list_by_status(connection, predicate, limit) do
    result =
      Store.query!(
        connection,
        "SELECT * FROM desktop_requests WHERE #{predicate} ORDER BY created_at ASC, request_key ASC LIMIT ?",
        [limit]
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp normalize_schema(schema) when is_map(schema) or is_list(schema), do: {:ok, schema}
  defp normalize_schema(schema) when is_binary(schema), do: Jason.decode(schema)
  defp normalize_schema(_schema), do: {:error, :invalid_schema}

  defp encode_json(value) do
    {:ok, canonical_json(value)}
  rescue
    _error -> {:error, :invalid_json}
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> canonical_json(item) end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp digest(payload),
    do: :sha256 |> :crypto.hash(canonical_json(payload)) |> Base.encode16(case: :lower)

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
  defp require_nonempty(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp require_nonempty(_value, field), do: {:error, {:missing_field, field}}
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
