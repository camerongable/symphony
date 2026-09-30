defmodule SymphonyElixir.Factory.RunLedger do
  @moduledoc """
  Durable issue, task, worktree, branch, candidate, and model-route ownership.
  """

  alias SymphonyElixir.Factory.{Contract, Control, StageSchemas, Store}

  @insert_columns ~w(
    run_id issue_key kind state dispatcher_id spec_revision contract_sha256
    repo_key repo_path base_branch worktree branch candidate_sha
    candidate_handoff ci_preflight_sha ci_pipeline_id ci_pipeline_url
    ci_evidence_json ci_last_checked_at attempt validation_attempt slack_claim_ts
    last_input_marker task_id mr_url jira_status mr_state runtime model_role model_provider model_class
    model reasoning_effort model_routing_reason factory_owned created_at updated_at
    parent_run_id snapshot_json contract_markdown plan_markdown
    repair_findings_json manual_validation_required implementation_iteration
    code_repair_round validation_repair_round verifier_round spec_comment_id
    confirmation_comment_id mr_iid last_error risk risk_signals_json
    workspace_state hibernated_at
  )

  @updatable_columns ~w(
    state dispatcher_id spec_revision contract_sha256 worktree branch
    candidate_sha candidate_handoff ci_preflight_sha ci_pipeline_id ci_pipeline_url
    ci_evidence_json ci_last_checked_at attempt validation_attempt slack_claim_ts
    last_input_marker task_id mr_url jira_status mr_state failure_code runtime
    model_role model_provider model_class model reasoning_effort
    model_routing_reason parent_run_id snapshot_json contract_markdown
    plan_markdown repair_findings_json manual_validation_required
    implementation_iteration code_repair_round validation_repair_round
    verifier_round spec_comment_id confirmation_comment_id mr_iid last_error
    risk risk_signals_json
    workspace_state hibernated_at
  )

  @doc """
  Registers a new factory run and its initial event.
  """
  @spec register(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register(connection, attrs, opts \\ []) do
    with :ok <- require_fields(attrs, ~w(run_id issue_key kind state)),
         :ok <- validate_kind(value(attrs, "kind")) do
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> iso()
      Store.transaction!(connection, &insert_run(&1, normalize_new_run(attrs, now)))
    end
  end

  defp normalize_new_run(attrs, now) do
    attrs
    |> stringify_keys()
    |> Map.put_new("attempt", 1)
    |> Map.put_new("validation_attempt", 0)
    |> Map.put_new("implementation_iteration", 0)
    |> Map.put_new("code_repair_round", 0)
    |> Map.put_new("validation_repair_round", 0)
    |> Map.put_new("verifier_round", 0)
    |> Map.put_new("factory_owned", true)
    |> Map.put_new("workspace_state", "UNMATERIALIZED")
    |> Map.put("created_at", now)
    |> Map.put("updated_at", now)
  end

  @doc "Requests one local retry of the latest failed specification without changing Jira."
  @spec request_specification_retry(Store.connection(), String.t(), String.t()) ::
          {:ok, %{run_id: String.t()}} | {:error, atom()}
  def request_specification_retry(connection, issue_key, scope)
      when is_binary(issue_key) and is_binary(scope) do
    Store.transaction!(connection, fn transaction ->
      with :ok <- require_no_live_lease(transaction, scope),
           :ok <- require_no_active_issue_run(transaction, issue_key),
           :ok <- require_no_active_specification_task(transaction, issue_key) do
        record_specification_retry(transaction, issue_key)
      end
    end)
  end

  defp record_specification_retry(transaction, issue_key) do
    case latest_issue_run(transaction, issue_key) do
      %{"run_id" => run_id, "kind" => "SPECIFICATION", "state" => "FAILED"} ->
        request_retry_for_failed_run(transaction, issue_key, run_id)

      _other ->
        {:error, :retry_requires_failed_latest_run}
    end
  end

  defp request_retry_for_failed_run(transaction, issue_key, run_id) do
    if specification_retry_pending?(transaction, run_id) do
      {:error, :retry_already_requested}
    else
      record_event!(transaction, "SPECIFICATION_RETRY_REQUESTED", run_id, %{issue_key: issue_key})
      {:ok, %{run_id: run_id}}
    end
  end

  @doc "Starts one native specification after an authorized retry of a failed app-server run."
  @spec restart_failed_specification_native(Store.connection(), String.t(), map(), map(), map(), atom()) ::
          {:ok, %{run: map()}} | {:error, term()}
  def restart_failed_specification_native(connection, old_run_id, snapshot, route, attrs, reason)
      when is_binary(old_run_id) and is_map(snapshot) and is_map(route) and is_map(attrs) and
             reason in [:local_retry, :jira_input_changed] do
    with :ok <- require_fields(attrs, ~w(run_id issue_key kind state)),
         :ok <- validate_kind(value(attrs, "kind")) do
      Store.transaction!(connection, fn transaction ->
        restart_failed_specification_native_transaction(transaction, old_run_id, snapshot, route, attrs, reason)
      end)
    end
  end

  defp restart_failed_specification_native_transaction(transaction, old_run_id, snapshot, route, attrs, reason) do
    with {:ok, %{"kind" => "SPECIFICATION", "state" => "FAILED"} = old} <- get(transaction, old_run_id),
         :ok <- validate_resume_reason(transaction, old_run_id, reason),
         :ok <- require_no_active_issue_run(transaction, old["issue_key"]),
         :ok <- require_no_active_specification_task(transaction, old["issue_key"]),
         true <- latest_issue_run(transaction, old["issue_key"])["run_id"] == old_run_id or {:error, :retry_not_latest},
         :ok <- validate_repository_retry_route(old, route),
         :ok <- require_native_replacement(old, snapshot, attrs),
         {:ok, %{run: new_run}} <- insert_run(transaction, normalize_new_run(attrs, iso(DateTime.utc_now()))) do
      if specification_retry_pending?(transaction, old_run_id) do
        record_event!(transaction, "SPECIFICATION_RETRY_CONSUMED", old_run_id, %{replacement_run_id: new_run["run_id"]})
      end

      record_event!(transaction, "SPECIFICATION_TRANSPORT_MIGRATED", old_run_id, %{replacement_run_id: new_run["run_id"]})
      {:ok, %{run: new_run}}
    else
      {:ok, _run} -> {:error, :retry_requires_failed_run}
      {:error, _reason} = error -> error
    end
  end

  defp require_native_replacement(old, snapshot, attrs) do
    expected = %{
      "factory_owned" => false,
      "runtime" => "codex-desktop-broker",
      "kind" => "SPECIFICATION",
      "state" => "SPEC_DRAFTING",
      "issue_key" => old["issue_key"],
      "repo_key" => old["repo_key"],
      "repo_path" => old["repo_path"],
      "base_branch" => old["base_branch"],
      "snapshot_json" => Jason.encode!(snapshot)
    }

    requested = attrs |> stringify_keys() |> Map.take(Map.keys(expected))

    if old["factory_owned"] == 1 and old["runtime"] in [nil, "codex-app-server"] and requested == expected do
      :ok
    else
      {:error, :invalid_native_specification_replacement}
    end
  end

  @doc "Reports whether a failed specification has one unconsumed local retry request."
  @spec specification_retry_pending?(Store.connection(), String.t()) :: boolean()
  def specification_retry_pending?(connection, failed_run_id) when is_binary(failed_run_id) do
    retry_event_count(connection, failed_run_id, "SPECIFICATION_RETRY_REQUESTED") >
      retry_event_count(connection, failed_run_id, "SPECIFICATION_RETRY_CONSUMED")
  end

  @doc "Reopens a failed specification in place so its existing Codex task can resume."
  @spec resume_failed_specification(Store.connection(), String.t(), map(), map(), non_neg_integer(), atom()) ::
          {:ok, %{run: map()}} | {:error, atom()}
  def resume_failed_specification(connection, run_id, snapshot, route, revision, reason)
      when is_binary(run_id) and is_map(snapshot) and is_map(route) and is_integer(revision) and revision >= 0 and
             reason in [:local_retry, :jira_input_changed] do
    Store.transaction!(connection, fn transaction ->
      resume_failed_specification_transaction(transaction, run_id, snapshot, route, revision, reason)
    end)
  end

  defp resume_failed_specification_transaction(transaction, run_id, snapshot, route, revision, reason) do
    with {:ok, %{"kind" => "SPECIFICATION", "state" => "FAILED"} = run} <- get(transaction, run_id),
         :ok <- validate_resume_reason(transaction, run_id, reason),
         :ok <- require_no_active_issue_run(transaction, run["issue_key"]),
         :ok <- require_no_active_specification_task(transaction, run["issue_key"]),
         true <- latest_issue_run(transaction, run["issue_key"])["run_id"] == run_id or {:error, :retry_not_latest},
         :ok <- validate_retry_route(transaction, run, route) do
      reopen_specification(transaction, run, snapshot, revision, reason)
    else
      {:ok, _run} -> {:error, :retry_requires_failed_run}
      {:error, _reason} = error -> error
    end
  end

  defp reopen_specification(transaction, run, snapshot, revision, reason) do
    reuse_draft? = reusable_written_draft?(run, snapshot, reason)
    state = if reuse_draft?, do: "SPEC_WRITING", else: "SPEC_DRAFTING"
    next_revision = if reuse_draft?, do: run["spec_revision"], else: revision

    Store.query!(
      transaction,
      "UPDATE runs SET state = ?, snapshot_json = ?, spec_revision = ?, attempt = attempt + 1, failure_code = NULL, last_error = NULL, repair_findings_json = NULL, updated_at = ? WHERE run_id = ?",
      [state, Jason.encode!(snapshot), next_revision, iso(DateTime.utc_now()), run["run_id"]]
    )

    unless reuse_draft? do
      Store.query!(
        transaction,
        "UPDATE factory_tasks SET status = 'RETRY_PENDING', failure_code = NULL, updated_at = ? WHERE task_key = ? AND status IN ('FAILED', 'COMPLETE', 'CONSUMED')",
        [iso(DateTime.utc_now()), "#{run["run_id"]}:specification-author"]
      )
    end

    if specification_retry_pending?(transaction, run["run_id"]) do
      record_event!(transaction, "SPECIFICATION_RETRY_CONSUMED", run["run_id"], %{resumed_run_id: run["run_id"]})
    end

    record_event!(transaction, "SPECIFICATION_RESUMED", run["run_id"], %{reason: reason, state: state})
    {:ok, %{run: get!(transaction, run["run_id"])}}
  end

  defp reusable_written_draft?(run, snapshot, :local_retry) do
    with true <- run["failure_code"] in [":jira_comment_readback_mismatch", ":jira_spec_readback_mismatch"],
         true <- is_integer(run["spec_revision"]) and run["spec_revision"] > 0,
         true <- is_binary(run["contract_markdown"]) and is_binary(run["contract_sha256"]),
         {:ok, previous} <- Jason.decode(run["snapshot_json"]),
         true <- same_specification_preimage?(previous, snapshot),
         contract <- Contract.bind(run["issue_key"], run["spec_revision"], run["contract_markdown"]),
         true <- contract.sha256 == run["contract_sha256"],
         true <- Contract.draft_read_back?(snapshot, contract),
         true <- Contract.next_revision(snapshot) == contract.revision + 1,
         true <- only_factory_write_comments_added?(previous, snapshot, contract) do
      true
    else
      _other -> false
    end
  end

  defp reusable_written_draft?(_run, _snapshot, _reason), do: false

  defp same_specification_preimage?(previous, current) do
    Enum.all?(~w(key summary description status labels project_key parent_key components), &(previous[&1] == current[&1])) and
      assignee_identity(previous["assignee"]) == assignee_identity(current["assignee"])
  end

  defp assignee_identity(%{"account_id" => account_id}) when is_binary(account_id), do: account_id
  defp assignee_identity(%{"accountId" => account_id}) when is_binary(account_id), do: account_id
  defp assignee_identity(value), do: value

  defp only_factory_write_comments_added?(previous, current, contract, allowed_authorization \\ nil) do
    old_comments = MapSet.new(Enum.map(previous["comments"] || [], &comment_identity/1))
    current_comments = MapSet.new(Enum.map(current["comments"] || [], &comment_identity/1))

    MapSet.subset?(old_comments, current_comments) and
      Enum.all?(MapSet.difference(current_comments, old_comments), fn {_id, text} ->
        Contract.draft_comment_equivalent?(Contract.draft_comment(contract), text, contract.issue_key) or
          (is_binary(allowed_authorization) and String.trim(text) == allowed_authorization) or
          Regex.match?(~r/\AAI factory blocked: :jira[*_]comment[*_]readback[*_]mismatch\z/, text) or
          Regex.match?(~r/\AAI factory blocked: :specification[*_]input[*_]changed[*_]during[*_]review\z/, text) or
          Regex.match?(~r/\AAI factory blocked: :independent[*_]critic[*_]pass[*_]not[*_]proven\z/, text)
      end)
  end

  defp comment_identity(comment) do
    {comment["id"] || comment[:id], comment["text"] || comment[:text] || comment["body"] || comment[:body]}
  end

  @doc "Restores a completed critic falsely marked stale after prompt-template drift."
  @spec recover_stale_specification_critic(Store.connection(), String.t(), map(), map()) ::
          {:ok, %{run: map()}} | {:error, term()}
  def recover_stale_specification_critic(connection, run_id, snapshot, route) do
    Store.transaction!(connection, fn transaction ->
      with {:ok, %{"kind" => "SPECIFICATION", "state" => "FAILED", "failure_code" => ":specification_input_changed_during_review"} = run} <-
             get(transaction, run_id),
           true <- latest_issue_run(transaction, run["issue_key"])["run_id"] == run_id,
           :ok <- validate_repository_retry_route(run, route),
           {:ok, task} <- critic_recovery_task(transaction, run, "STALE"),
           {:ok, request} <- critic_recovery_request(transaction, task),
           :ok <- prove_critic_recovery(run, task, request, snapshot) do
        Store.query!(
          transaction,
          "UPDATE runs SET state = 'SPEC_REVIEW', snapshot_json = ?, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ?",
          [Jason.encode!(snapshot), iso(DateTime.utc_now()), run_id]
        )

        Store.query!(
          transaction,
          "UPDATE factory_tasks SET status = 'COMPLETE', failure_code = NULL, updated_at = ? WHERE task_key = ? AND status = 'STALE'",
          [iso(DateTime.utc_now()), task["task_key"]]
        )

        record_event!(transaction, "SPECIFICATION_CRITIC_RECOVERED", run_id, %{task_key: task["task_key"]})
        {:ok, %{run: get!(transaction, run_id)}}
      else
        _other -> {:error, :critic_recovery_unproven}
      end
    end)
  end

  @doc "Restores a critic PASS blocked only by an obsolete prompt-byte authorization gate."
  @spec recover_stale_critic_authorization(Store.connection(), String.t(), map(), map()) ::
          {:ok, %{run: map()}} | {:error, term()}
  def recover_stale_critic_authorization(connection, run_id, snapshot, route) do
    Store.transaction!(connection, fn transaction ->
      with {:ok, %{"kind" => "SPECIFICATION", "state" => "FAILED", "failure_code" => ":independent_critic_pass_not_proven"} = run} <-
             get(transaction, run_id),
           true <- latest_issue_run(transaction, run["issue_key"])["run_id"] == run_id,
           :ok <- validate_repository_retry_route(run, route),
           {:ok, task} <- critic_recovery_task(transaction, run, "CONSUMED"),
           {:ok, %{"status" => "PASS", "findings" => [], "required_questions" => []}} <- Jason.decode(task["output_json"]),
           {:ok, request} <- critic_recovery_request(transaction, task),
           :ok <- prove_critic_recovery(run, task, request, snapshot) do
        Store.query!(
          transaction,
          "UPDATE runs SET state = 'SPEC_READY_WRITE', snapshot_json = ?, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ?",
          [Jason.encode!(snapshot), iso(DateTime.utc_now()), run_id]
        )

        record_event!(transaction, "SPECIFICATION_AUTHORIZATION_RECOVERED", run_id, %{task_key: task["task_key"]})
        {:ok, %{run: get!(transaction, run_id)}}
      else
        _other -> {:error, :critic_authorization_recovery_unproven}
      end
    end)
  end

  @doc "Resumes an interrupted Jira authorization using the completed critic result."
  @spec recover_unavailable_specification_authorization(Store.connection(), String.t(), map(), map()) ::
          {:ok, %{run: map()}} | {:error, term()}
  def recover_unavailable_specification_authorization(connection, run_id, snapshot, route) do
    Store.transaction!(connection, fn transaction ->
      with {:ok, %{"kind" => "SPECIFICATION", "state" => "FAILED", "failure_code" => failure} = run} <-
             get(transaction, run_id),
           true <- failure == inspect({:required_mcp_servers_unavailable, ["Jira"]}),
           true <- latest_issue_run(transaction, run["issue_key"])["run_id"] == run_id,
           :ok <- validate_repository_retry_route(run, route),
           {:ok, task} <- critic_recovery_task(transaction, run, "CONSUMED"),
           {:ok, %{"status" => "PASS", "findings" => [], "required_questions" => []}} <- Jason.decode(task["output_json"]),
           {:ok, request} <- critic_recovery_request(transaction, task),
           :ok <- prove_critic_recovery(run, task, request, snapshot, allow_authorization_marker: true) do
        Store.query!(
          transaction,
          "UPDATE runs SET state = 'SPEC_READY_WRITE', snapshot_json = ?, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ?",
          [Jason.encode!(snapshot), iso(DateTime.utc_now()), run_id]
        )

        record_event!(transaction, "SPECIFICATION_AUTHORIZATION_RECOVERED", run_id, %{task_key: task["task_key"]})
        {:ok, %{run: get!(transaction, run_id)}}
      else
        _other -> {:error, :critic_authorization_recovery_unproven}
      end
    end)
  end

  defp critic_recovery_task(connection, run, expected_status) do
    task_key = "#{run["run_id"]}:specification-critic:#{run["verifier_round"]}"

    case Store.one!(connection, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key]) do
      %{"role" => "specification-critic", "status" => ^expected_status, "output_json" => output} = task
      when is_binary(output) ->
        {:ok, task}

      _other ->
        {:error, :critic_task_not_recoverable}
    end
  end

  defp critic_recovery_request(connection, task) do
    request =
      Store.one!(
        connection,
        "SELECT * FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'FOLLOWUP' AND status = 'SUCCEEDED' ORDER BY updated_at DESC LIMIT 1",
        [task["task_key"]]
      )

    if is_map(request), do: {:ok, request}, else: {:error, :critic_request_not_proven}
  end

  defp prove_critic_recovery(run, task, request, snapshot, opts \\ []) do
    with true <- request["thread_id"] == task["thread_id"] and request["turn_id"] == task["turn_id"],
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- metadata["stage_prompt_sha256"] == task["prompt_sha256"],
         {:ok, %{"result" => reviewed_output}} <- Jason.decode(request["output_json"]),
         {:ok, task_output} <- Jason.decode(task["output_json"]),
         true <- reviewed_output == task_output,
         :ok <- StageSchemas.validate(reviewed_output, StageSchemas.for_stage(:specification_critic)),
         {:ok, reviewed_snapshot} <- critic_request_snapshot(request["prompt"]),
         true <- critic_request_contract?(request["prompt"], run),
         true <- same_specification_preimage?(reviewed_snapshot, snapshot),
         contract <- Contract.bind(run["issue_key"], run["spec_revision"], run["contract_markdown"]),
         true <- contract.sha256 == run["contract_sha256"],
         true <- Contract.draft_read_back?(snapshot, contract),
         true <- Contract.next_revision(snapshot) == contract.revision + 1,
         allowed_authorization <-
           if(Keyword.get(opts, :allow_authorization_marker, false),
             do: Contract.automatic_authorization_marker(contract, task["task_key"], Contract.digest(task["output_json"])),
             else: nil
           ),
         true <- only_factory_write_comments_added?(reviewed_snapshot, snapshot, contract, allowed_authorization) do
      :ok
    else
      _other -> {:error, :critic_recovery_unproven}
    end
  end

  defp critic_request_snapshot(prompt) when is_binary(prompt) do
    case Regex.run(~r/UNTRUSTED JIRA SNAPSHOT:\n(.*?)\n\nCONTRACT UNDER REVIEW:/s, prompt) do
      [_match, json] -> Jason.decode(json)
      _other -> {:error, :critic_snapshot_missing}
    end
  end

  defp critic_request_snapshot(_prompt), do: {:error, :critic_snapshot_missing}

  defp critic_request_contract?(prompt, run) do
    String.contains?(prompt, "Controller-computed contract SHA-256: #{run["contract_sha256"]}") and
      String.contains?(prompt, "CONTRACT UNDER REVIEW:\n#{run["contract_markdown"]}")
  end

  defp validate_resume_reason(connection, run_id, :local_retry) do
    if specification_retry_pending?(connection, run_id), do: :ok, else: {:error, :retry_not_pending}
  end

  defp validate_resume_reason(_connection, _run_id, :jira_input_changed), do: :ok

  defp validate_retry_route(connection, run, route) do
    task =
      Store.one!(
        connection,
        "SELECT codex_project_id FROM factory_tasks WHERE task_key = ?",
        ["#{run["run_id"]}:specification-author"]
      )

    with :ok <- validate_repository_retry_route(run, route) do
      if is_map(task) and task["codex_project_id"] != route["codex_project_id"],
        do: {:error, :retry_codex_project_mismatch},
        else: :ok
    end
  end

  defp validate_repository_retry_route(run, route) do
    if run["repo_key"] == route["repo_key"] and run["repo_path"] == route["path"] and
         run["base_branch"] == route["base_branch"],
       do: :ok,
       else: {:error, :retry_repository_route_mismatch}
  end

  @doc """
  Reads a run by its stable run ID.
  """
  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, :unknown_run}
  def get(connection, run_id) do
    case Store.one!(connection, "SELECT * FROM runs WHERE run_id = ?", [run_id]) do
      nil -> {:error, :unknown_run}
      run -> {:ok, run}
    end
  end

  @doc """
  Lists runs, optionally restricted to one state.
  """
  @spec list(Store.connection(), keyword()) :: [map()]
  def list(connection, opts \\ []) do
    {statement, params} =
      case Keyword.get(opts, :state) do
        nil -> {"SELECT * FROM runs ORDER BY updated_at DESC", []}
        state -> {"SELECT * FROM runs WHERE state = ? ORDER BY updated_at DESC", [state]}
      end

    result = Store.query!(connection, statement, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  @doc "Lists the newest runs by creation with a bounded result size."
  @spec list_recent(Store.connection(), pos_integer()) :: [map()]
  def list_recent(connection, limit \\ 50) when is_integer(limit) and limit > 0 do
    result = Store.query!(connection, "SELECT * FROM runs ORDER BY created_at DESC, rowid DESC LIMIT ?", [limit])
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  @doc "Lists the newest factory events with their Jira issue identity."
  @spec recent_events(Store.connection(), pos_integer()) :: [map()]
  def recent_events(connection, limit \\ 20) when is_integer(limit) and limit > 0 do
    result =
      Store.query!(
        connection,
        """
        SELECT events.id, events.occurred_at, events.event_type, events.run_id, runs.issue_key
        FROM events
        LEFT JOIN runs ON runs.run_id = events.run_id
        ORDER BY events.id DESC
        LIMIT ?
        """,
        [limit]
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  @doc """
  Updates only the allowlisted mutable fields and records the change event.
  """
  @spec update(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(connection, run_id, attrs, opts \\ []) do
    updates =
      attrs
      |> stringify_keys()
      |> Map.take(@updatable_columns)

    if map_size(updates) == 0 do
      {:error, :no_run_fields}
    else
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> iso()
      updates = Map.put(updates, "updated_at", now)
      columns = @updatable_columns |> Enum.filter(&Map.has_key?(updates, &1)) |> Kernel.++(["updated_at"])

      Store.transaction!(connection, &update_run(&1, run_id, updates, columns))
    end
  end

  @doc """
  Appends an auditable model route for a run and records the corresponding event.
  """
  @spec record_model_route(Store.connection(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :unknown_run}
  def record_model_route(connection, run_id, usage_context, route, opts \\ []) do
    Store.transaction!(connection, fn transaction ->
      case get(transaction, run_id) do
        {:error, :unknown_run} ->
          {:error, :unknown_run}

        {:ok, _run} ->
          occurred_at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> iso()
          task_id = Keyword.get(opts, :task_id)

          Store.query!(
            transaction,
            """
            INSERT INTO model_routes(
              occurred_at, run_id, task_id, usage_context, requested_role,
              resolved_role, provider, model_class, model, reasoning_effort,
              routing_reason
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
              occurred_at,
              run_id,
              task_id,
              usage_context,
              value(route, "requested_role"),
              value(route, "resolved_role"),
              value(route, "provider"),
              value(route, "model_class"),
              value(route, "model"),
              value(route, "reasoning_effort"),
              value(route, "routing_reason")
            ]
          )

          %{"id" => route_id} = Store.one!(transaction, "SELECT last_insert_rowid() AS id")

          payload = %{
            route_id: route_id,
            usage_context: usage_context,
            task_id: task_id,
            requested_role: value(route, "requested_role"),
            resolved_role: value(route, "resolved_role"),
            provider: value(route, "provider"),
            model_class: value(route, "model_class"),
            model: value(route, "model"),
            reasoning_effort: value(route, "reasoning_effort"),
            routing_reason: value(route, "routing_reason")
          }

          record_event!(transaction, "MODEL_ROUTE_RECORDED", run_id, payload)
          {:ok, payload}
      end
    end)
  end

  @doc """
  Lists append-only events for a run in occurrence order.
  """
  @spec events(Store.connection(), String.t()) :: [map()]
  def events(connection, run_id) do
    result =
      Store.query!(
        connection,
        "SELECT * FROM events WHERE run_id = ? ORDER BY id ASC",
        [run_id]
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp get!(connection, run_id) do
    {:ok, run} = get(connection, run_id)
    run
  end

  defp insert_run(transaction, normalized) do
    placeholders = Enum.map_join(@insert_columns, ", ", fn _column -> "?" end)
    values = Enum.map(@insert_columns, &database_value(Map.get(normalized, &1)))

    case Exqlite.query(
           transaction,
           "INSERT INTO runs(#{Enum.join(@insert_columns, ", ")}) VALUES (#{placeholders})",
           values
         ) do
      {:ok, _result} ->
        record_event!(transaction, "RUN_REGISTERED", normalized["run_id"], %{
          "state" => normalized["state"]
        })

        {:ok, %{result: "REGISTERED", run: get!(transaction, normalized["run_id"])}}

      {:error, error} ->
        {:error, {:register_failed, error}}
    end
  end

  defp latest_issue_run(connection, issue_key) do
    Store.one!(
      connection,
      "SELECT * FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
      [issue_key]
    )
  end

  defp require_no_live_lease(connection, scope) do
    case Control.status(connection, scope) do
      nil ->
        {:error, :factory_control_missing}

      %{"tick_id" => nil} ->
        :ok

      %{"lease_expires_at" => expires_at} when is_binary(expires_at) ->
        validate_tick_lease_expiry(expires_at)

      _other ->
        {:error, :invalid_tick_lease}
    end
  end

  defp validate_tick_lease_expiry(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expiry, _offset} ->
        if DateTime.compare(expiry, DateTime.utc_now()) == :gt,
          do: {:error, :live_tick_lease},
          else: :ok

      {:error, _reason} ->
        {:error, :invalid_tick_lease}
    end
  end

  defp require_no_active_issue_run(connection, issue_key) do
    case Store.one!(
           connection,
           """
           SELECT 1 AS present FROM runs
           WHERE issue_key = ? AND state NOT IN
             ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED')
           LIMIT 1
           """,
           [issue_key]
         ) do
      nil -> :ok
      _run -> {:error, :active_issue_run}
    end
  end

  defp require_no_active_specification_task(connection, issue_key) do
    task =
      Store.one!(
        connection,
        """
        SELECT 1 AS present FROM factory_tasks AS task
        JOIN runs AS run ON run.run_id = task.run_id
        WHERE run.issue_key = ? AND run.kind = 'SPECIFICATION'
          AND task.status IN ('STARTING', 'RUNNING', 'WAITING_FOR_WRITER', 'WAITING_FOR_BROKER', 'RETRY_PENDING', 'STALE')
        LIMIT 1
        """,
        [issue_key]
      )

    pending =
      Store.one!(
        connection,
        """
        SELECT 1 AS present FROM desktop_requests AS request
        JOIN factory_tasks AS task ON task.task_key = request.target_key
        JOIN runs AS run ON run.run_id = task.run_id
        WHERE request.target_kind = 'TASK' AND run.issue_key = ? AND run.kind = 'SPECIFICATION'
          AND request.status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN',
                                 'THREAD_RECORDED', 'RECONCILE_REQUIRED')
        LIMIT 1
        """,
        [issue_key]
      )

    if task == nil and pending == nil, do: :ok, else: {:error, :active_specification_task}
  end

  defp retry_event_count(connection, run_id, event_type) do
    Store.one!(
      connection,
      "SELECT COUNT(*) AS count FROM events WHERE run_id = ? AND event_type = ?",
      [run_id, event_type]
    )["count"]
  end

  defp update_run(transaction, run_id, updates, columns) do
    case get(transaction, run_id) do
      {:error, :unknown_run} ->
        {:error, :unknown_run}

      {:ok, _run} ->
        assignments = Enum.map_join(columns, ", ", &"#{&1} = ?")
        values = Enum.map(columns, &database_value(Map.fetch!(updates, &1))) ++ [run_id]
        Store.query!(transaction, "UPDATE runs SET #{assignments} WHERE run_id = ?", values)
        record_event!(transaction, "RUN_UPDATED", run_id, updates)
        {:ok, %{result: "UPDATED", run: get!(transaction, run_id)}}
    end
  end

  defp record_event!(connection, event_type, run_id, payload) do
    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [iso(DateTime.utc_now()), event_type, run_id, Jason.encode!(payload)]
    )

    :ok
  end

  defp require_fields(attrs, fields) do
    case Enum.reject(fields, &(is_binary(value(attrs, &1)) and String.trim(value(attrs, &1)) != "")) do
      [] -> :ok
      missing -> {:error, {:missing_run_fields, missing}}
    end
  end

  defp validate_kind(kind) when kind in ["SPECIFICATION", "DELIVERY", "VALIDATION"], do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_run_kind, kind}}

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, item} -> {to_string(key), item} end)
  end

  defp database_value(true), do: 1
  defp database_value(false), do: 0
  defp database_value(value), do: value

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> value_from_existing_atom(map, key)
    end
  end

  defp value(_map, _key), do: nil

  defp value_from_existing_atom(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp iso(value), do: DateTime.to_iso8601(value)
end
