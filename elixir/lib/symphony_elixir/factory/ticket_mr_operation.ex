defmodule SymphonyElixir.Factory.TicketMrOperation do
  @moduledoc "Exact ordinary-delivery MR authority and a controller-turn-independent request identity."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{CiCollection, Control, ControllerTask, DesktopRequest, DesktopStageRunner}
  alias SymphonyElixir.Factory.{JiraMcpReader, ModelRouter, Prompt}
  alias SymphonyElixir.Factory.{RunLedger, StageSchemas, Store, TicketChat, TicketMrGuard, TicketPush}
  alias SymphonyElixir.Factory.{TicketWorkerRunner, Worktree}
  alias SymphonyElixir.PathSafety

  @fields ~w(version operation run_id issue_key stage candidate_sha contract_sha256 spec_revision ci_preflight
             repo_key repo_path source_workspace source_branch target_branch gitlab_project gitlab_project_id scope controller_project_id
             controller_cwd controller_thread_id completed_push_sha256)
  @identity ~w(version operation run_id stage candidate_sha contract_sha256 spec_revision ci_preflight)
  @identity_v2 @identity ++ ~w(completed_push_sha256)
  @operation "CREATE_OR_REUSE_DRAFT_MR"
  @required_calls [%{"server" => "GitLab", "tool" => "get_merge_request"}]
  @type owner_reader :: (map() -> {:ok, map()} | {:error, term()})

  @doc "Adopts the original MR receipt only after current read-only qualification; never issues or finalizes Jira."
  @spec adopt_result(Store.connection(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt_result(store, run_id, authorization, factory, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, stage} <- adoption_stage(run),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, key, request, binding} <- select_current_request(store, run, stage, push),
         true <-
           is_nil(opts[:expected_request_key]) or key == opts[:expected_request_key] or
             {:error, :ticket_mr_request_changed},
         true <- is_map(request) or {:error, :unknown_request} do
      adopt_request(store, run, request, binding, stage, authorization, factory, opts)
    else
      {:error, _} = error -> error
    end
  end

  @doc "Qualifies the original adopted ordinary MR without granting dispatch or external-write authority."
  @spec current_delivery_receipt(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def current_delivery_receipt(store, run_id, factory, opts) do
    with {:ok, %{"state" => "MR_CREATING", "mr_iid" => iid, "mr_url" => url} = run} <- RunLedger.get(store, run_id),
         true <- (is_integer(iid) and iid > 0 and present?(url)) or {:error, :ticket_mr_recorded_identity_missing},
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, delivery_opts} <- TicketWorkerRunner.delivery_review_options(store, run, opts),
         {:ok, key, %{"status" => "SUCCEEDED"} = request, binding} <- select_current_request(store, run, "MR_CREATING", push),
         :ok <- authorize_readback(store, request),
         :ok <- validate_request(binding, request),
         {:ok, facts} <- TicketWorkerRunner.delivery_facts(store, run, delivery_opts),
         {:ok, fresh} <- bind_proven_push(store, run, facts, factory, request["cwd"], "MR_CREATING", push, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, output} <- ControllerTask.read_request_result(factory, key, StageSchemas.for_stage(:gitlab_mr), Keyword.put(opts, :store, store)),
         {:ok, fields} <- result_fields(run, output),
         :ok <- original_mr_identity(run, fields),
         mr_read_started_at = DateTime.utc_now(),
         {:ok, mr} <- collect_current_mr(run, fields, binding, opts),
         :ok <- current_mr(run, fields, binding, mr),
         {:ok, current_request} <- DesktopRequest.get(store, key),
         true <- current_request == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, current_request),
         {:ok, current_facts} <- TicketWorkerRunner.delivery_facts(store, run, delivery_opts),
         {:ok, current_binding} <-
           rebind_admitted(
             store,
             run,
             current_facts,
             factory,
             request["cwd"],
             "MR_CREATING",
             push,
             binding["version"]
           ),
         true <- current_binding == binding or {:error, :ticket_mr_request_binding_mismatch} do
      receipt = %{run: run, request: request, binding: binding, mr: mr, fields: fields, push_proof: push}
      receipt = Map.put(receipt, :observed_at, DateTime.to_iso8601(mr_read_started_at))
      {:ok, Map.put(receipt, :qualified_at, DateTime.to_iso8601(DateTime.utc_now()))}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_recorded_receipt_unproven}
    end
  end

  @doc false
  @spec validate_retained_mr_history(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_retained_mr_history(store, run) do
    with :ok <- TicketPush.validate_historical_completed_preimage(store, run),
         stage = if(run["state"] == "CI_WAITING", do: "CI_MR_CREATING", else: "MR_CREATING"),
         {:ok, request, binding} <- historical_request_for_push(store, run, stage, hash(run["candidate_handoff"])),
         true <- request["status"] == "SUCCEEDED",
         :ok <- authorize_readback(store, request),
         :ok <- validate_request(binding, request),
         true <- binding["completed_push_sha256"] == hash(run["candidate_handoff"]) or {:error, :ticket_mr_original_push_changed},
         {:ok, %{"result" => output, "completed_tool_calls" => calls}} <- Jason.decode(request["output_json"]),
         true <- is_map(output) and is_list(calls),
         true <- Enum.any?(calls, &(&1["server"] == "GitLab" and &1["tool"] == "get_merge_request" and &1["status"] == "completed")),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:gitlab_mr)),
         {:ok, fields} <- result_fields(run, output),
         :ok <- original_mr_identity(run, fields) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_original_history_unproven}
    end
  end

  @doc "Rechecks an in-memory qualified MR receipt's current bindings; it is not dispatch authorization."
  @spec validate_delivery_receipt(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def validate_delivery_receipt(store, %{run: run, request: request, binding: binding, mr: mr, fields: fields, observed_at: at, push_proof: push}, factory, opts) do
    with {:ok, observed, _} <- DateTime.from_iso8601(at),
         true <- DateTime.diff(DateTime.utc_now(), observed, :millisecond) in 0..60_000 or {:error, :ticket_mr_readback_expired},
         {:ok, current_request} <- DesktopRequest.get(store, request["request_key"]),
         true <- current_request == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, current_request),
         {:ok, facts} <- TicketWorkerRunner.delivery_facts(store, run, opts),
         {:ok, fresh} <- rebind_admitted(store, run, facts, factory, request["cwd"], "MR_CREATING", push, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         :ok <- original_mr_identity(run, fields) do
      current_mr(run, fields, binding, mr)
    end
  end

  def validate_delivery_receipt(_store, _receipt, _factory, _opts), do: {:error, :ticket_mr_readback_unproven}

  defp adoption_stage(%{"state" => state}) when state in ~w(MR_CREATING CI_MR_CREATING), do: {:ok, state}

  defp adoption_stage(%{"state" => "CI_WAITING", "mr_iid" => iid, "mr_url" => url}) when is_integer(iid) and iid > 0 and is_binary(url) and url != "",
    do: {:ok, "CI_MR_CREATING"}

  defp adoption_stage(_run), do: {:error, :ticket_mr_stage_invalid}

  defp adopt_request(store, run, %{"status" => "SUCCEEDED"} = request, binding, stage, authorization, factory, opts) do
    with :ok <- authorize_readback(store, request),
         {:ok, fresh} <- bind_current(store, run, authorization, factory, request["cwd"], stage, opts, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, output} <- ControllerTask.read_request_result(factory, request["request_key"], StageSchemas.for_stage(:gitlab_mr), Keyword.put(opts, :store, store)),
         {:ok, fields} <- result_fields(run, output),
         :ok <- original_mr_identity(run, fields),
         {:ok, mr} <- collect_current_mr(run, fields, binding, opts),
         :ok <- current_mr(run, fields, binding, mr) do
      case Exqlite.transaction(store, &adopt_transaction(&1, run, request, fields, authorization, opts)) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp adopt_request(_store, _run, %{"status" => state} = request, _binding, _stage, _authorization, _factory, _opts)
       when state in ~w(PENDING FOLLOWUP_UNCERTAIN THREAD_RECORDED RECONCILE_REQUIRED),
       do: {:ok, %{status: "MR_WAITING_FOR_RESULT", request_key: request["request_key"]}}

  defp adopt_request(_store, _run, _request, _binding, _stage, _authorization, _factory, _opts), do: {:error, :ticket_mr_request_failed}

  defp result_fields(run, output) do
    expected = %{
      "status" => "PASS",
      "sha" => run["candidate_sha"],
      "source_branch" => run["branch"],
      "target_branch" => run["base_branch"],
      "draft" => true,
      "reviewers_count" => 0,
      "assignee_id" => 11_599_766,
      "state" => "opened"
    }

    if Map.take(output, Map.keys(expected)) == expected and is_integer(output["iid"]) and output["iid"] > 0 and present?(output["mr_url"]) do
      {:ok, %{"mr_url" => output["mr_url"], "mr_iid" => output["iid"], "mr_state" => output["state"]}}
    else
      {:error, :ticket_mr_result_mismatch}
    end
  end

  defp original_mr_identity(run, fields) do
    current = Map.take(run, Map.keys(fields))

    if current == fields or (run["state"] != "CI_WAITING" and Enum.all?(current, fn {_key, value} -> is_nil(value) end)),
      do: :ok,
      else: {:error, :ticket_mr_recorded_identity_mismatch}
  end

  defp bound_read_session(binding, opts) do
    case Keyword.get(opts, :mcp_session) do
      session when is_map(session) ->
        if (session[:thread_id] || session["thread_id"]) == binding["controller_thread_id"],
          do: :ok,
          else: {:error, :ticket_mr_read_session_mismatch}

      _ ->
        {:error, :gitlab_catalog_session_required}
    end
  end

  defp collect_current_mr(run, fields, binding, opts) do
    with_read_session(binding, opts, fn read_opts ->
      CiCollection.collect_mr(Map.merge(run, fields), binding["gitlab_project_id"], read_opts)
    end)
  end

  defp with_read_session(binding, opts, operation) do
    read_opts = Keyword.put(opts, :workspace, binding["controller_cwd"])

    if Keyword.get(opts, :ticket_mr_ephemeral_read, false) == true and is_nil(Keyword.get(opts, :mcp_session)) do
      AppServer.with_gitlab_read_session(binding["controller_cwd"], fn session ->
        operation.(Keyword.put(read_opts, :mcp_session, session))
      end)
    else
      with :ok <- bound_read_session(binding, opts) do
        operation.(read_opts)
      end
    end
  end

  @doc "Adopts exact preflight CI evidence once without launching a verifier or writing Jira."
  @spec adopt_ci(Store.connection(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt_ci(store, run_id, authorization, factory, opts) do
    with {:ok, %{"state" => "CI_WAITING"} = run} <- RunLedger.get(store, run_id),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, key, request, binding} <- select_current_request(store, run, "CI_MR_CREATING", push),
         :ok <- authorize_readback(store, request),
         {:ok, fresh} <- bind_current(store, run, authorization, factory, request["cwd"], "CI_MR_CREATING", opts, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, output} <- ControllerTask.read_request_result(factory, key, StageSchemas.for_stage(:gitlab_mr), Keyword.put(opts, :store, store)),
         {:ok, fields} <- result_fields(run, output),
         :ok <- original_mr_identity(run, fields),
         {:ok, collected} <-
           with_read_session(binding, opts, fn read_opts ->
             TicketWorkerRunner.collect_ci(store, run_id, binding["gitlab_project_id"], read_opts)
           end) do
      case Exqlite.transaction(store, &adopt_ci_transaction(&1, run, request, collected, authorization, opts)) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_ci_stage_invalid}
    end
  end

  defp adopt_ci_transaction(store, run, request, collected, authorization, opts) do
    with {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_ci_candidate_changed},
         {:ok, observed} <- DesktopRequest.get(store, request["request_key"]),
         true <- observed == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, observed),
         {:ok, admission} <- TicketWorkerRunner.delivery_admission(store, current, authorization, opts),
         {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]),
         :ok <- validate_push(push.binding, current, admission.checkout) do
      evidence = collected["evidence"]

      updates = %{
        "ci_pipeline_id" => evidence["pipeline_id"],
        "ci_pipeline_url" => evidence["pipeline_url"],
        "ci_evidence_json" => Jason.encode!(evidence),
        "ci_last_checked_at" => collected["observed_at"]
      }

      updates =
        if evidence["status"] == "PASS",
          do: Map.merge(updates, %{"state" => "VERIFYING", "verifier_round" => current["verifier_round"] + 1}),
          else: updates

      case RunLedger.update(store, run["run_id"], updates) do
        {:ok, %{run: updated}} -> {:ok, %{status: "CI_" <> evidence["status"], run: updated}}
        {:error, reason} -> Exqlite.rollback(store, reason)
      end
    else
      {:error, reason} -> Exqlite.rollback(store, reason)
    end
  end

  defp current_mr(run, fields, binding, mr) do
    expected = %{
      "project_id" => binding["gitlab_project_id"],
      "iid" => fields["mr_iid"],
      "web_url" => fields["mr_url"],
      "source_branch" => run["branch"],
      "target_branch" => run["base_branch"],
      "sha" => run["candidate_sha"]
    }

    with true <- Map.take(mr, Map.keys(expected)) == expected or {:error, :ticket_mr_remote_binding_mismatch},
         true <- (mr["draft"] == true and mr["state"] == "opened" and mr["reviewers"] == []) or {:error, :ticket_mr_human_state_changed},
         people when is_list(people) <- mr["assignees"],
         true <- matching_assignee?(people) or {:error, :ticket_mr_assignee_mismatch},
         true <- is_nil(mr["diff_refs"]) or is_map(mr["diff_refs"]) or {:error, :ticket_mr_remote_binding_mismatch},
         true <- get_in(mr, ["diff_refs", "head_sha"]) in [nil, run["candidate_sha"]] or {:error, :ticket_mr_remote_binding_mismatch} do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_remote_binding_mismatch}
    end
  end

  defp matching_assignee?(people), do: Enum.all?(people, &is_map/1) and Enum.any?(people, &(&1["id"] == 11_599_766))

  defp adopt_transaction(store, run, request, fields, authorization, opts) do
    with {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_mr_candidate_changed},
         {:ok, observed} <- DesktopRequest.get(store, request["request_key"]),
         true <- observed == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, observed),
         {:ok, admission} <- TicketWorkerRunner.delivery_admission(store, current, authorization, opts),
         {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]),
         :ok <- validate_push(push.binding, current, admission.checkout),
         :ok <- original_mr_identity(current, fields) do
      updates = if current["state"] == "CI_MR_CREATING", do: Map.put(fields, "state", "CI_WAITING"), else: fields

      with {:ok, result} <- persist_mr_fields(store, current, request["request_key"], updates) do
        advance_original_controller_turn(store, request)
        {:ok, result}
      end
    else
      {:error, reason} -> Exqlite.rollback(store, reason)
    end
  end

  defp persist_mr_fields(store, run, key, updates) do
    if Map.take(run, Map.keys(updates)) == updates do
      {:ok, %{status: "MR_ALREADY_ADOPTED", run: run, request_key: key}}
    else
      case RunLedger.update(store, run["run_id"], updates) do
        {:ok, %{run: updated}} -> {:ok, %{status: "MR_ADOPTED", run: updated, request_key: key}}
        {:error, reason} -> Exqlite.rollback(store, reason)
      end
    end
  end

  defp advance_original_controller_turn(store, request) do
    metadata = Jason.decode!(request["metadata_json"])

    Store.query!(
      store,
      """
      UPDATE control SET controller_turn_id = ?
      WHERE scope = ? AND controller_thread_id = ? AND controller_codex_project_id = ? AND controller_turn_id = ?
      """,
      [request["turn_id"], request["target_key"], request["existing_thread_id"], request["codex_project_id"], metadata["previous_turn_id"]]
    )

    :ok
  end

  @spec typed_request?(map()) :: boolean()
  def typed_request?(%{"target_kind" => "CONTROLLER", "metadata_json" => json}) when is_binary(json) do
    match?({:ok, %{"delivery_operation" => %{}}}, Jason.decode(json))
  end

  def typed_request?(_request), do: false

  @doc "Qualifies discovery only; fresh Jira and native guard evidence are still required to claim."
  @spec authorize_discovery(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def authorize_discovery(store, request, factory) do
    with true <- unissued?(request) or {:error, :ticket_mr_request_already_issued},
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- validate_request(binding, request),
         {:ok, run} <- RunLedger.get(store, binding["run_id"]),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         :ok <- require_new_admission(factory, run["issue_key"]),
         :ok <- unchanged_request_context(store, run, binding, factory, request["cwd"]),
         :ok <- exclusive_mr_owner(store, request) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  @doc "Returns send arguments once, only after the exact request is durably claimed uncertain."
  @spec claim_followup_args(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_followup_args(store, key, admission, opts) do
    DesktopRequest.claim_mr_followup(store, key, admission, opts)
  end

  @doc "Reads fresh Jira authority before claiming; broker input supplies guard evidence, never Jira bytes."
  @spec claim_from_jira(Store.connection(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_from_jira(store, key, factory, guard, opts) do
    with {:ok, _request, _run, authorization} <- read_claim_authorization(store, key, factory, opts) do
      claim_followup_args(store, key, %{factory: factory, authorization: authorization, guard: guard}, opts)
    end
  end

  @doc "Retains Jira authority in memory while the broker obtains its fresh owner observation."
  @spec claim_with_owner(Store.connection(), String.t(), map(), String.t(), owner_reader(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def claim_with_owner(store, key, factory, broker, observe_owner, opts) do
    app_server = Keyword.get(opts, :mr_app_server, AppServer)

    with {:ok, request, run, authorization} <- read_claim_authorization(store, key, factory, opts),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- broker == parent["broker_thread_id"] or {:error, :mr_guard_broker_mismatch},
         {:ok, owner} <- observe_owner.(request),
         native_opts = [workspace: request["cwd"], include_turns: false, include_latest_turn: true, include_queue: true],
         {:ok, native} <- app_server.read_native_thread(request["existing_thread_id"], native_opts) do
      guard = %{"source_thread_id" => broker, "owner" => owner, "native" => native}
      claim_followup_args(store, key, %{factory: factory, authorization: authorization, guard: guard}, opts)
    end
  end

  @doc "Reads current request/run and fresh Jira authority without claiming or dispatching work."
  @spec read_claim_authorization(Store.connection(), String.t(), map(), keyword()) ::
          {:ok, map(), map(), map()} | {:error, term()}
  def read_claim_authorization(store, key, factory, opts) do
    reader = Keyword.get(opts, :jira_reader, JiraMcpReader)

    with {:ok, request} <- DesktopRequest.get(store, key),
         :ok <- authorize_discovery(store, request, factory),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- validate_request(binding, request),
         {:ok, run} <- RunLedger.get(store, binding["run_id"]),
         {:ok, snapshot} <- reader.issue(run["issue_key"], workspace: binding["controller_cwd"], store: store),
         {:ok, authorization} <-
           TicketWorkerRunner.delivery_authorization(store, run, snapshot, DateTime.utc_now(), opts) do
      {:ok, request, run, authorization}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  @doc "Produces claim evidence only for the original wholly unissued request."
  @spec claim_receipt(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_receipt(store, request, admission, opts) when is_map(admission) do
    with %{factory: factory, authorization: authorization, guard: proof} <- admission,
         {:ok, binding} <- check_new_request(store, request["request_key"], authorization, factory, opts),
         {:ok, current} <- DesktopRequest.get(store, request["request_key"]),
         true <- current == request or {:error, :ticket_mr_request_changed},
         false <- competing_controller?(store, request["request_key"]),
         {:ok, parent} <- TicketChat.ready_for_run(store, binding["run_id"]),
         {:ok, guard} <- TicketMrGuard.receipt(request, proof, parent["broker_thread_id"], DateTime.utc_now()),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]) do
      {:ok,
       %{
         "version" => 1,
         "request_key" => request["request_key"],
         "payload_sha256" => request["payload_sha256"],
         "binding" => binding,
         "previous_turn_id" => metadata["previous_turn_id"],
         "guard" => guard,
         "proof" => proof
       }}
    else
      {:error, _} = error -> error
      true -> {:error, :ticket_mr_controller_busy}
      _ -> {:error, :ticket_mr_claim_authority_required}
    end
  end

  def claim_receipt(_store, _request, _admission, _opts), do: {:error, :ticket_mr_claim_authority_required}

  defp competing_controller?(store, key) do
    Store.one!(
      store,
      "SELECT request_key FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND request_key != ? AND status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED') LIMIT 1",
      [key]
    ) != nil
  end

  @doc "Validates only immutable issued-request evidence, never permission to send again."
  @spec authorize_readback(Store.connection(), map()) :: :ok | {:error, term()}
  def authorize_readback(store, request) do
    with {:ok, current} <- DesktopRequest.get(store, request["request_key"]),
         true <- current == request,
         true <- request["status"] in ~w(FOLLOWUP_UNCERTAIN THREAD_RECORDED RECONCILE_REQUIRED SUCCEEDED),
         :ok <- exclusive_mr_owner(store, request),
         row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [request["request_key"]]),
         true <- hash(row["receipt_json"]) == row["receipt_sha256"],
         {:ok, receipt} when is_map(receipt) <- Jason.decode(row["receipt_json"]),
         true <-
           Map.take(receipt, ~w(version request_key payload_sha256 claimed_at)) == %{
             "version" => 1,
             "request_key" => request["request_key"],
             "payload_sha256" => request["payload_sha256"],
             "claimed_at" => request["claimed_at"]
           },
         true <- row["claimed_at"] == request["claimed_at"],
         :ok <- validate_request(receipt["binding"], request),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- metadata["previous_turn_id"] == receipt["previous_turn_id"] and metadata["required_tool_calls"] == @required_calls,
         :ok <- validate_claim_guard(request, receipt) do
      :ok
    else
      _ -> {:error, :ticket_mr_claim_unproven}
    end
  end

  defp validate_claim_guard(request, receipt) do
    with %{"checked_at" => checked, "source_thread_id" => broker} = guard when is_binary(checked) and is_binary(broker) <- receipt["guard"],
         true <- is_binary(receipt["claimed_at"]),
         {:ok, now, _} <- DateTime.from_iso8601(checked),
         {:ok, claimed, _} <- DateTime.from_iso8601(receipt["claimed_at"]),
         true <- DateTime.diff(claimed, now, :microsecond) in 0..10_000_000,
         {:ok, ^guard} <- TicketMrGuard.receipt(request, receipt["proof"], broker, now) do
      :ok
    else
      _ -> {:error, :ticket_mr_claim_unproven}
    end
  end

  @doc "Rechecks a wholly unissued request; this preflight does not claim or authorize native transport."
  @spec check_new_request(Store.connection(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def check_new_request(store, key, authorization, factory, opts) do
    with {:ok, request} <- DesktopRequest.get(store, key),
         true <- unissued?(request) or {:error, :ticket_mr_request_already_issued},
         :ok <- exclusive_mr_owner(store, request),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- validate_request(binding, request),
         {:ok, run} <- RunLedger.get(store, binding["run_id"]),
         true <- run["state"] == binding["stage"] or {:error, :ticket_mr_stage_invalid},
         true <- metadata["required_tool_calls"] == @required_calls or {:error, :ticket_mr_request_binding_mismatch},
         :ok <- require_new_admission(factory, binding["issue_key"]),
         control = Control.status(store, factory.scope),
         true <- metadata["previous_turn_id"] == control["controller_turn_id"] or {:error, :ticket_mr_controller_turn_changed},
         {:ok, fresh} <- bind_version(store, binding["run_id"], authorization, factory, request["cwd"], opts, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, current} <- DesktopRequest.get(store, key),
         true <- (current == request and Control.status(store, factory.scope) == control) or {:error, :ticket_mr_request_changed} do
      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  defp exclusive_mr_owner(store, request) do
    case Store.one!(store, "SELECT feedback_key FROM mr_feedback_notes WHERE request_key = ? LIMIT 1", [request["request_key"]]) do
      nil -> :ok
      _ -> {:error, :ticket_mr_request_ownership_conflict}
    end
  end

  defp unissued?(request) do
    fields = ~w(claimed_at thread_id turn_id target_observation_json verified_project_id verified_cwd verified_head_sha output_json)
    request["status"] == "PENDING" and Enum.all?(fields, &is_nil(request[&1]))
  end

  defp require_new_admission(factory, issue_key) do
    policy = Map.get(factory, :ticket_supervisor, %{})

    cond do
      Map.get(factory, :task_transport) != "desktop_broker" -> {:error, :ticket_mr_transport_mismatch}
      policy["enabled"] != true -> {:error, :ticket_mr_new_admission_disabled}
      issue_key not in (policy["pilot_issue_keys"] || []) -> {:error, :ticket_mr_new_admission_disabled}
      true -> :ok
    end
  end

  @doc "Finds the original semantic request first; queues new work only after fresh ordinary admission."
  @spec prepare(Store.connection(), String.t(), map(), map(), Path.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(store, run_id, authorization, factory, cwd, description, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- run["state"] in ~w(MR_CREATING CI_MR_CREATING) or {:error, :ticket_mr_stage_invalid},
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, key, request, binding} <- select_current_request(store, run, run["state"], push) do
      if is_map(request),
        do: reuse_request(store, run, request, binding, factory, cwd),
        else: prepare_new(store, run, key, authorization, factory, cwd, description, opts)
    end
  end

  defp operation_identity(run, stage, version \\ 1, push_sha \\ nil) do
    run
    |> Map.take(~w(run_id candidate_sha contract_sha256 spec_revision))
    |> Map.merge(%{"version" => version, "operation" => @operation, "stage" => stage, "ci_preflight" => stage == "CI_MR_CREATING"})
    |> then(fn identity -> if version == 2, do: Map.put(identity, "completed_push_sha256", push_sha), else: identity end)
  end

  defp select_current_request(store, run, stage, push) do
    push_sha = push.envelope_sha256
    v2_key = identity_key(operation_identity(run, stage, 2, push_sha))

    case DesktopRequest.get(store, v2_key) do
      {:ok, request} ->
        with {:ok, binding} <- request_binding(request),
             :ok <- validate_request(binding, request),
             true <- binding["completed_push_sha256"] == push_sha or {:error, :ticket_mr_request_binding_mismatch} do
          {:ok, v2_key, request, binding}
        end

      {:error, :unknown_request} ->
        select_v1_or_rollover(store, run, stage, push_sha, v2_key)
    end
  end

  defp select_v1_or_rollover(store, run, stage, push_sha, v2_key) do
    v1_key = identity_key(operation_identity(run, stage))

    case DesktopRequest.get(store, v1_key) do
      {:error, :unknown_request} ->
        {:ok, v2_key, nil, nil}

      {:ok, request} ->
        select_v1_request(store, run, request, v1_key, v2_key, push_sha)
    end
  end

  defp select_v1_request(store, run, request, v1_key, v2_key, push_sha) do
    with {:ok, binding} <- request_binding(request),
         :ok <- validate_request(binding, request) do
      select_v1_binding(store, run, request, binding, v1_key, v2_key, push_sha)
    end
  end

  defp select_v1_binding(store, run, request, binding, v1_key, v2_key, push_sha) do
    if binding["completed_push_sha256"] == push_sha,
      do: {:ok, v1_key, request, binding},
      else: rollover_v1_request(store, run, request, v2_key)
  end

  defp rollover_v1_request(store, run, request, v2_key) do
    case terminal_v1_request(store, run, request) do
      :ok -> {:ok, v2_key, nil, nil}
      result -> result
    end
  end

  defp historical_request_for_push(store, run, stage, push_sha) do
    v2_key = identity_key(operation_identity(run, stage, 2, push_sha))

    case DesktopRequest.get(store, v2_key) do
      {:ok, request} ->
        with {:ok, binding} <- request_binding(request),
             :ok <- validate_request(binding, request),
             do: {:ok, request, binding}

      {:error, :unknown_request} ->
        v1_key = identity_key(operation_identity(run, stage))

        with {:ok, request} <- DesktopRequest.get(store, v1_key),
             {:ok, binding} <- request_binding(request),
             :ok <- validate_request(binding, request),
             true <- binding["completed_push_sha256"] == push_sha or {:error, :ticket_mr_original_push_changed} do
          {:ok, request, binding}
        end
    end
  end

  defp terminal_v1_request(store, run, %{"status" => "SUCCEEDED"} = request) do
    with true <-
           (is_integer(run["mr_iid"]) and run["mr_iid"] > 0 and present?(run["mr_url"])) or
             {:error, :ticket_mr_v1_predecessor_unproven},
         :ok <- authorize_readback(store, request),
         {:ok, %{"result" => output, "completed_tool_calls" => calls}} <- Jason.decode(request["output_json"]),
         true <- is_map(output) and is_list(calls),
         true <- Enum.any?(calls, &(&1["server"] == "GitLab" and &1["tool"] == "get_merge_request" and &1["status"] == "completed")),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:gitlab_mr)),
         {:ok, fields} <- result_fields(run, output),
         :ok <- original_mr_identity(run, fields) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_v1_predecessor_unproven}
    end
  end

  defp terminal_v1_request(_store, _run, _request), do: {:error, :ticket_mr_v1_predecessor_unresolved}

  defp request_binding(request) do
    with {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"] do
      {:ok, binding}
    else
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  defp reuse_request(store, run, request, binding, factory, cwd) do
    with :ok <- validate_request(binding, request),
         :ok <- unchanged_request_context(store, run, binding, factory, cwd),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         true <- metadata["required_tool_calls"] == @required_calls or {:error, :ticket_mr_request_binding_mismatch} do
      {:ok, %{status: "EXISTING_REQUEST", request: request}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  defp unchanged_request_context(store, run, binding, factory, cwd) do
    expected = %{
      "run_id" => run["run_id"],
      "issue_key" => run["issue_key"],
      "stage" => run["state"],
      "candidate_sha" => run["candidate_sha"],
      "contract_sha256" => run["contract_sha256"],
      "spec_revision" => run["spec_revision"],
      "repo_key" => run["repo_key"],
      "repo_path" => run["repo_path"],
      "source_workspace" => run["worktree"],
      "source_branch" => run["branch"],
      "target_branch" => run["base_branch"],
      "scope" => factory.scope,
      "controller_project_id" => factory.controller_codex_project_id,
      "completed_push_sha256" => hash(run["candidate_handoff"] || "")
    }

    with true <- Map.take(binding, Map.keys(expected)) == expected,
         route when is_map(route) <- factory.repositories[run["repo_key"]],
         true <- route["gitlab_project"] == binding["gitlab_project"] and route["path"] == run["repo_path"] and route["base_branch"] == run["base_branch"],
         {:ok, pin} <- project_pin(route),
         true <- pin == binding["gitlab_project_id"],
         control when is_map(control) <- Control.status(store, factory.scope),
         true <- control["controller_thread_id"] == binding["controller_thread_id"] and control["controller_codex_project_id"] == binding["controller_project_id"],
         {:ok, canonical} <- controller_cwd(cwd, run["repo_path"], run["worktree"]),
         true <- canonical == binding["controller_cwd"],
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run do
      :ok
    else
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  defp prepare_new(store, run, key, authorization, factory, cwd, description, opts) do
    with :ok <- require_new_admission(factory, run["issue_key"]),
         {:ok, binding} <- bind_version(store, run["run_id"], authorization, factory, cwd, opts, 2),
         {:ok, ^key} <- request_key(binding),
         control = Control.status(store, factory.scope),
         true <- present?(control["controller_turn_id"]) or {:error, :ticket_mr_controller_turn_unproven},
         {:ok, route} <- ModelRouter.resolve(factory.models, "orchestrator") do
      attributes = request_attributes(store, run, binding, key, control, route, factory, description)
      enqueue_transaction(store, run, control, attributes, factory.scope)
    end
  end

  defp enqueue_transaction(store, run, control, attributes, scope) do
    case Exqlite.transaction(store, fn tx -> enqueue_current(tx, run, control, attributes, scope) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_current(store, run, control, attrs, scope) do
    with {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- (current == run and Control.status(store, scope) == control) or {:error, :ticket_mr_candidate_changed},
         false <- DesktopRequest.controller_busy?(store),
         {:ok, request} <- DesktopRequest.enqueue(store, attrs) do
      {:ok, %{status: "REQUEST_PREPARED", request: request}}
    else
      {:error, reason} -> Exqlite.rollback(store, reason)
      _ -> Exqlite.rollback(store, :ticket_mr_controller_busy)
    end
  end

  defp request_attributes(store, run, binding, key, control, model, factory, description) do
    route = factory.repositories[run["repo_key"]]
    schema = StageSchemas.for_stage(:gitlab_mr)
    operation = if binding["ci_preflight"], do: :ci_preflight, else: :delivery
    prompt = Prompt.gitlab_mr(route, run["issue_key"], run["branch"], run["base_branch"], run["candidate_sha"], description, operation: operation)

    options = [
      store: store,
      request_key: key,
      target_kind: "CONTROLLER",
      target_key: factory.scope,
      project_id: factory.controller_codex_project_id,
      model: model.model,
      reasoning_effort: model.reasoning_effort,
      thread_name: "FACTORY · #{factory.scope} · Orchestrator",
      issue_key: run["issue_key"],
      previous_turn_id: control["controller_turn_id"],
      required_tool_calls: @required_calls,
      required_mcp_servers: ["GitLab"],
      format_repair_attempts: 1,
      delivery_operation: binding
    ]

    formatted = ControllerTask.structured_output_prompt(prompt, schema)
    DesktopStageRunner.request_attrs(binding["controller_cwd"], formatted, schema, options, key, binding["controller_thread_id"])
  end

  @spec bind(Store.connection(), String.t(), map(), map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bind(store, run_id, authorization, factory, cwd, opts) do
    bind_version(store, run_id, authorization, factory, cwd, opts, 1)
  end

  defp bind_version(store, run_id, authorization, factory, cwd, opts, version) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- run["state"] in ~w(MR_CREATING CI_MR_CREATING) or {:error, :ticket_mr_stage_invalid} do
      bind_current(store, run, authorization, factory, cwd, run["state"], opts, version)
    end
  end

  defp bind_current(store, run, authorization, factory, cwd, stage, opts, version) do
    with {:ok, admission} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts) do
      bind_admitted(store, run, admission, factory, cwd, stage, version)
    end
  end

  defp bind_admitted(store, run, admission, factory, cwd, stage, version) do
    with {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]) do
      bind_proven_push(store, run, admission, factory, cwd, stage, push, version)
    end
  end

  defp rebind_admitted(store, run, admission, factory, cwd, stage, push, version) do
    with :ok <- TicketPush.validate_completed_proof(store, run["run_id"], push),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == push.binding["origin"] or {:error, :ticket_push_history_unproven} do
      bind_proven_push(store, run, admission, factory, cwd, stage, push, version)
    end
  end

  defp bind_proven_push(store, run, admission, factory, cwd, stage, push, version) do
    run_id = run["run_id"]

    with :ok <- TicketPush.validate_completed_proof(store, run_id, push),
         :ok <- validate_push(push.binding, run, admission.checkout),
         {:ok, parent} <- TicketChat.ready_for_run(store, run_id),
         true <- parent["scope_key"] == factory.scope or {:error, :ticket_mr_scope_mismatch},
         route when is_map(route) <- Map.get(factory.repositories, run["repo_key"]),
         {:ok, pin} <- project_pin(route),
         true <- {route["path"], route["base_branch"]} == {run["repo_path"], run["base_branch"]} or {:error, :ticket_mr_repository_mismatch},
         control when is_map(control) <- Control.status(store, factory.scope),
         true <- control["controller_codex_project_id"] == factory.controller_codex_project_id or {:error, :ticket_mr_controller_mismatch},
         {:ok, canonical} <- controller_cwd(cwd, run["repo_path"], admission.checkout.path),
         {:ok, remote_sha} <- Worktree.read_remote_branch(%{"path" => run["repo_path"]}, run["branch"]),
         true <- remote_sha == run["candidate_sha"] or {:error, :ticket_mr_remote_candidate_changed},
         binding = %{
           "version" => version,
           "operation" => @operation,
           "run_id" => run_id,
           "issue_key" => run["issue_key"],
           "stage" => stage,
           "candidate_sha" => run["candidate_sha"],
           "contract_sha256" => run["contract_sha256"],
           "spec_revision" => run["spec_revision"],
           "ci_preflight" => stage == "CI_MR_CREATING",
           "repo_key" => run["repo_key"],
           "repo_path" => run["repo_path"],
           "source_workspace" => run["worktree"],
           "source_branch" => run["branch"],
           "target_branch" => run["base_branch"],
           "gitlab_project" => route["gitlab_project"],
           "gitlab_project_id" => pin,
           "scope" => factory.scope,
           "controller_project_id" => factory.controller_codex_project_id,
           "controller_cwd" => canonical,
           "controller_thread_id" => control["controller_thread_id"],
           "completed_push_sha256" => push.envelope_sha256
         },
         {:ok, _} <- request_key(binding),
         {:ok, current} <- RunLedger.get(store, run_id),
         true <- current == run or {:error, :ticket_mr_candidate_changed} do
      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_binding_unproven}
    end
  end

  defp project_pin(%{"gitlab_project_id" => pin}) when is_integer(pin) and pin > 0, do: {:ok, pin}

  defp project_pin(%{"gitlab_project_id" => pin}) when is_binary(pin) do
    case Integer.parse(pin) do
      {id, ""} when id > 0 ->
        if Integer.to_string(id) == pin, do: {:ok, id}, else: {:error, :ticket_mr_project_pin_required}

      _ ->
        {:error, :ticket_mr_project_pin_required}
    end
  end

  defp project_pin(_route), do: {:error, :ticket_mr_project_pin_required}

  @doc "Proves a controller directory is physically outside repository and writer roots, including aliases."
  @spec controller_cwd(Path.t(), Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def controller_cwd(cwd, repository, source) do
    with {:ok, canonical} <- PathSafety.canonicalize(cwd),
         true <- File.dir?(canonical) or {:error, :ticket_mr_controller_cwd_invalid},
         {:ok, repository} <- PathSafety.canonicalize(repository),
         {:ok, source} <- PathSafety.canonicalize(source),
         true <- outside_source?(canonical, [repository, source]) or {:error, :ticket_mr_controller_source_overlap} do
      {:ok, canonical}
    end
  end

  defp validate_push(binding, run, checkout) do
    expected = if run["state"] == "MR_CREATING", do: "PUSHING", else: "CI_PUSHING"

    with true <- same_candidate?(binding, run) or {:error, :ticket_mr_candidate_changed},
         true <- binding["checkout"] == stringify(checkout) or {:error, :ticket_mr_checkout_changed},
         true <- binding["state"] == expected or {:error, :ticket_mr_push_stage_mismatch} do
      :ok
    end
  end

  @spec request_key(map()) :: {:ok, String.t()} | {:error, term()}
  def request_key(binding) when is_map(binding) do
    if valid_binding?(binding) do
      {:ok, identity_key(binding)}
    else
      {:error, :ticket_mr_binding_invalid}
    end
  end

  def request_key(_binding), do: {:error, :ticket_mr_binding_invalid}

  defp identity_key(binding) do
    fields = if binding["version"] == 2, do: @identity_v2, else: @identity
    encoded = Jason.encode!(Enum.map(fields, &binding[&1]))
    DesktopStageRunner.request_key("ticket-mr:" <> hash(encoded), nil, @operation)
  end

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  @doc "Validates the exact stored request without adopting its result or authorizing another send."
  @spec validate_request(map(), map()) :: :ok | {:error, term()}
  def validate_request(binding, request) do
    with {:ok, key} <- request_key(binding),
         true <- DesktopRequest.payload_intact?(request),
         true <-
           {request["request_key"], request["target_kind"], request["target_key"], request["action"], request["codex_project_id"], request["cwd"], request["existing_thread_id"]} ==
             {key, "CONTROLLER", binding["scope"], "FOLLOWUP", binding["controller_project_id"], binding["controller_cwd"], binding["controller_thread_id"]},
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- schema == StageSchemas.for_stage(:gitlab_mr),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         true <- metadata["delivery_operation"] == binding,
         true <- metadata["issue_key"] == binding["issue_key"],
         true <- present?(metadata["previous_turn_id"]),
         true <- is_nil(request["thread_id"]) or request["thread_id"] == binding["controller_thread_id"] do
      :ok
    else
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  defp valid_binding?(binding) do
    strings = @fields -- ~w(version spec_revision ci_preflight gitlab_project_id)

    Enum.sort(Map.keys(binding)) == Enum.sort(@fields) and
      binding["version"] in [1, 2] and binding["operation"] == @operation and
      binding["stage"] in ~w(MR_CREATING CI_MR_CREATING) and
      positive_integer?(binding["gitlab_project_id"]) and
      positive_integer?(binding["spec_revision"]) and
      binding["ci_preflight"] == (binding["stage"] == "CI_MR_CREATING") and
      Enum.all?(strings, &present?(binding[&1])) and
      valid_hashes?(binding)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_hashes?(binding) do
    String.match?(binding["candidate_sha"], ~r/\A[0-9a-f]{40}\z/) and
      Enum.all?(~w(contract_sha256 completed_push_sha256), &String.match?(binding[&1], ~r/\A[0-9a-f]{64}\z/))
  end

  defp outside_source?(cwd, roots), do: Enum.all?(roots, &(cwd != &1 and not String.starts_with?(cwd, &1 <> "/")))

  defp same_candidate?(binding, run) do
    fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)
    Map.take(binding, fields) == Map.take(run, fields)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
