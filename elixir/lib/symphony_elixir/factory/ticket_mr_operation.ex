defmodule SymphonyElixir.Factory.TicketMrOperation do
  @moduledoc "Exact ordinary-delivery MR authority and a controller-turn-independent request identity."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{CiCollection, Control, ControllerTask, DesktopRequest, DesktopStageRunner}
  alias SymphonyElixir.Factory.{ControllerGitRead, GitLabMcpConnector, JiraMcpReader, ModelRouter, Prompt}
  alias SymphonyElixir.Factory.{RunLedger, StageSchemas, Store, TicketChat, TicketMrGuard, TicketPush}
  alias SymphonyElixir.Factory.{TicketCiRepair, TicketMrCwdCorrection, TicketMrPresendRecovery}
  alias SymphonyElixir.Factory.{TicketMrPublication, TicketMrQualification, TicketWorkerRunner, Worktree}
  alias SymphonyElixir.PathSafety

  @fields ~w(version operation run_id issue_key stage candidate_sha contract_sha256 spec_revision ci_preflight
             repo_key repo_path source_workspace source_branch target_branch gitlab_project gitlab_project_id scope controller_project_id
             controller_cwd controller_thread_id completed_push_sha256)
  @identity ~w(version operation run_id stage candidate_sha contract_sha256 spec_revision ci_preflight)
  @identity_v2 @identity ++ ~w(completed_push_sha256)
  @operation "CREATE_OR_REUSE_DRAFT_MR"
  @required_calls [%{"server" => "GitLab", "tool" => "get_merge_request"}]
  @tick_bookkeeping ~w(generation tick_id lease_expires_at updated_at)
  @type owner_reader :: (map() -> {:ok, map()} | {:error, term()})

  @doc "Adopts the original MR receipt only after current read-only qualification; never issues or finalizes Jira."
  @spec adopt_result(Store.connection(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt_result(%DBConnection{}, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

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
  def current_delivery_receipt(%DBConnection{}, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def current_delivery_receipt(store, run_id, factory, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, format} <- TicketMrPublication.receipt_format(store, run) do
      case format do
        :direct_publication -> TicketMrPublication.current_receipt(store, run_id, factory, opts)
        :legacy -> legacy_current_delivery_receipt(store, run_id, factory, opts)
      end
    end
  end

  defp legacy_current_delivery_receipt(store, run_id, factory, opts) do
    with {:ok, %{"state" => "MR_CREATING", "mr_iid" => iid, "mr_url" => url} = run} <- RunLedger.get(store, run_id),
         true <- (is_integer(iid) and iid > 0 and present?(url)) or {:error, :ticket_mr_recorded_identity_missing},
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, key, %{"status" => "SUCCEEDED"} = request, binding} <- select_current_request(store, run, "MR_CREATING", push),
         :ok <- authorize_readback(store, request),
         :ok <- validate_request(binding, request),
         :ok <- TicketMrCwdCorrection.validate(store, request) do
      with_read_session(binding, opts, fn read_opts ->
        delivery_receipt_in_session(store, run, factory, request, key, binding, push, read_opts)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_recorded_receipt_unproven}
    end
  end

  defp delivery_receipt_in_session(store, run, factory, request, key, binding, push, opts) do
    with {:ok, delivery_opts} <- TicketWorkerRunner.delivery_review_options(store, run, opts),
         :ok <- authorize_readback(store, request),
         :ok <- validate_request(binding, request),
         :ok <- TicketMrCwdCorrection.validate(store, request),
         {:ok, facts} <- TicketWorkerRunner.delivery_facts(store, run, delivery_opts),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         control = controller_claim_fence(Control.status(store, factory.scope)),
         claim = Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]),
         {:ok, fresh} <- bind_proven_push(store, run, facts, factory, request["cwd"], push, {"MR_CREATING", binding["version"]}, opts),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, output} <- ControllerTask.read_request_result(factory, key, StageSchemas.for_stage(:gitlab_mr), Keyword.put(opts, :store, store)),
         {:ok, fields} <- effective_fields(store, run, request, binding, output),
         :ok <- original_mr_identity(run, fields),
         mr_read_started_at = DateTime.utc_now(),
         {:ok, mr} <- collect_current_mr(run, fields, binding, opts),
         :ok <- current_mr(store, run, fields, binding, mr),
         {:ok, current_request} <- DesktopRequest.get(store, key),
         true <- current_request == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, current_request),
         {:ok, current_facts} <- TicketWorkerRunner.delivery_facts(store, run, delivery_opts),
         true <- current_facts == facts or {:error, :ticket_delivery_binding_changed},
         closing_at = DateTime.utc_now(),
         {:ok, current_binding} <-
           rebind_admitted(
             store,
             run,
             current_facts,
             factory,
             request["cwd"],
             push,
             {"MR_CREATING", binding["version"]},
             opts
           ),
         true <- current_binding == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, ^parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- controller_claim_fence(Control.status(store, factory.scope)) == control or {:error, :ticket_mr_request_changed},
         true <- Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [key]) == claim or {:error, :ticket_mr_request_changed} do
      receipt = %{run: run, request: request, binding: binding, mr: mr, fields: fields, push_proof: push}
      receipt = Map.merge(receipt, %{delivery_facts: facts, parent: parent, control: control, claim: claim, branch_observation: branch_snapshot(binding, closing_at)})
      receipt = Map.put(receipt, :observed_at, DateTime.to_iso8601(mr_read_started_at))
      {:ok, Map.put(receipt, :qualified_at, DateTime.to_iso8601(DateTime.utc_now()))}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_recorded_receipt_unproven}
    end
  end

  defp branch_snapshot(binding, at) do
    %{
      "project_id" => binding["gitlab_project_id"],
      "project" => binding["gitlab_project"],
      "branch" => binding["source_branch"],
      "sha" => binding["candidate_sha"],
      "observed_at" => DateTime.to_iso8601(at)
    }
  end

  @doc false
  @spec validate_retained_mr_history(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_retained_mr_history(store, run) do
    with :ok <- TicketPush.validate_historical_completed_preimage(store, run),
         {:ok, _record} <- retained_mr_record(store, run) do
      :ok
    end
  end

  @doc "Validates one exact recorded MR receipt against current or retained repair history; grants no delivery authority."
  @spec validate_retained_mr_request(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def validate_retained_mr_request(store, run, request) do
    binding = get_in(Jason.decode!(request["metadata_json"]), ["delivery_operation"])

    with {:ok, prior} <- matching_mr_preimage(store, run, binding),
         :ok <- TicketPush.validate_historical_completed_preimage(store, prior),
         {:ok, %{request: ^request}} <- retained_mr_record(store, prior) do
      :ok
    else
      _ -> {:error, :ticket_mr_original_history_unproven}
    end
  rescue
    _ -> {:error, :ticket_mr_original_history_unproven}
  end

  defp matching_mr_preimage(store, run, binding) when is_map(binding) do
    if mr_preimage_matches?(run, binding) do
      {:ok, run}
    else
      with {:ok, prior} <- TicketWorkerRunner.retained_review_preimage(store, run),
           true <- mr_preimage_matches?(prior, binding) do
        {:ok, prior}
      else
        _ -> {:error, :ticket_mr_original_history_unproven}
      end
    end
  end

  defp matching_mr_preimage(_store, _run, _binding), do: {:error, :ticket_mr_original_history_unproven}

  defp mr_preimage_matches?(run, binding),
    do: Enum.all?(~w(run_id candidate_sha contract_sha256 spec_revision), &(binding[&1] == run[&1])) and is_integer(run["mr_iid"]) and run["mr_iid"] > 0

  @doc false
  @spec observe_retained_mr_history(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def observe_retained_mr_history(%DBConnection{}, _prior), do: {:error, :workspace_observation_inside_transaction}

  def observe_retained_mr_history(store, prior) do
    with {:ok, push} <- TicketPush.observe_historical_completed_preimage(store, prior),
         {:ok, record} <- retained_mr_record(store, prior) do
      {:ok, %{prior: prior, push: push, record: record}}
    end
  end

  @doc false
  @spec recheck_retained_mr_history(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def recheck_retained_mr_history(store, prior, %{prior: prior, push: push, record: expected}) do
    with :ok <- TicketPush.recheck_historical_completed_preimage(store, prior, push),
         {:ok, ^expected} <- retained_mr_record(store, prior) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_original_history_changed}
    end
  end

  def recheck_retained_mr_history(_store, _prior, _proof), do: {:error, :ticket_mr_original_history_unproven}

  defp retained_mr_record(store, run) do
    with {:ok, format} <- TicketMrPublication.receipt_format(store, run), do: retained_mr_record(store, run, format)
  end

  defp retained_mr_record(store, run, :direct_publication) do
    with {:ok, row} <- TicketMrPublication.record_for_run(store, run),
         receipt = Jason.decode!(row["receipt_json"]),
         true <- receipt["outcome"] != "PRESERVED_HUMAN_STATE",
         true <- {receipt["mr"]["iid"], receipt["mr"]["web_url"]} == {run["mr_iid"], run["mr_url"]} do
      {:ok, %{format: :direct_publication, publication: row}}
    else
      _ -> {:error, :ticket_mr_original_history_unproven}
    end
  end

  defp retained_mr_record(store, run, :legacy), do: legacy_retained_mr_record(store, run)

  defp legacy_retained_mr_record(store, run) do
    with stage = if(run["state"] == "CI_WAITING", do: "CI_MR_CREATING", else: "MR_CREATING"),
         {:ok, request, binding} <- historical_request_for_push(store, run, stage, hash(run["candidate_handoff"])),
         true <- request["status"] == "SUCCEEDED",
         :ok <- authorize_readback(store, request),
         :ok <- validate_request(binding, request),
         true <- binding["completed_push_sha256"] == hash(run["candidate_handoff"]) or {:error, :ticket_mr_original_push_changed},
         {:ok, %{"result" => output, "completed_tool_calls" => calls}} <- Jason.decode(request["output_json"]),
         true <- is_map(output) and is_list(calls),
         true <- Enum.any?(calls, &(&1["server"] == "GitLab" and &1["tool"] == "get_merge_request" and &1["status"] == "completed")),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:gitlab_mr)),
         {:ok, fields} <- effective_fields(store, run, request, binding, output),
         :ok <- original_mr_identity(run, fields) do
      {:ok, %{request: request, binding: binding, claim: Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [request["request_key"]])}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_original_history_unproven}
    end
  end

  @doc "Rechecks an in-memory qualified MR receipt's current bindings; it is not dispatch authorization."
  @spec validate_delivery_receipt(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def validate_delivery_receipt(store, %{format: :direct_publication} = receipt, factory, opts),
    do: TicketMrPublication.validate_receipt(store, receipt, factory, opts)

  def validate_delivery_receipt(
        store,
        %{
          run: run,
          request: request,
          binding: binding,
          mr: mr,
          fields: fields,
          observed_at: at,
          push_proof: push,
          delivery_facts: facts,
          parent: parent,
          control: control,
          claim: claim,
          branch_observation: branch
        },
        factory,
        opts
      ) do
    with {:ok, observed, _} <- DateTime.from_iso8601(at),
         true <- DateTime.diff(DateTime.utc_now(), observed, :millisecond) in 0..60_000 or {:error, :ticket_mr_readback_expired},
         %{"observed_at" => branch_at} when is_binary(branch_at) <- branch,
         {:ok, branch_time, _} <- DateTime.from_iso8601(branch_at),
         true <- DateTime.diff(DateTime.utc_now(), branch_time, :millisecond) in 0..60_000 or {:error, :ticket_mr_readback_expired},
         true <- branch == branch_snapshot(binding, branch_time) or {:error, :ticket_mr_remote_candidate_changed},
         {:ok, current_request} <- DesktopRequest.get(store, request["request_key"]),
         true <- current_request == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, current_request),
         {:ok, ^parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- controller_claim_fence(Control.status(store, factory.scope)) == control or {:error, :ticket_mr_request_changed},
         true <- Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key = ?", [request["request_key"]]) == claim or {:error, :ticket_mr_request_changed},
         :ok <- TicketWorkerRunner.recheck_delivery_facts(store, run, opts, facts),
         %{checkout: checkout} when is_map(checkout) <- facts,
         {:ok, fresh} <- binding_from_facts(store, run, facts, factory, request["cwd"], "MR_CREATING", push, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         :ok <- original_mr_identity(run, fields) do
      current_mr(store, run, fields, binding, mr)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_readback_unproven}
    end
  end

  def validate_delivery_receipt(_store, _receipt, _factory, _opts), do: {:error, :ticket_mr_readback_unproven}

  defp adoption_stage(%{"state" => state}) when state in ~w(MR_CREATING CI_MR_CREATING), do: {:ok, state}

  defp adoption_stage(%{"state" => "CI_WAITING", "mr_iid" => iid, "mr_url" => url}) when is_integer(iid) and iid > 0 and is_binary(url) and url != "",
    do: {:ok, "CI_MR_CREATING"}

  defp adoption_stage(_run), do: {:error, :ticket_mr_stage_invalid}

  defp adopt_request(store, run, %{"status" => "SUCCEEDED"} = request, binding, stage, authorization, factory, opts) do
    reader = &observe_adoption(store, run, request, binding, stage, authorization, factory, &1)

    with :ok <- authorize_readback(store, request),
         {:ok, {fields, qualification, admission, push, branch_at}} <-
           with_read_session(binding, opts, reader) do
      opts = opts |> Keyword.put(:mr_qualification, {qualification, admission, push}) |> Keyword.put(:mr_branch_at, branch_at)

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

  defp observe_adoption(store, run, request, binding, stage, authorization, factory, opts) do
    with :ok <- authorize_readback(store, request),
         {:ok, fresh} <- bind_current(store, run, authorization, factory, request["cwd"], stage, opts, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, output} <- ControllerTask.read_request_result(factory, request["request_key"], StageSchemas.for_stage(:gitlab_mr), Keyword.put(opts, :store, store)),
         {:ok, fields, qualification} <- adoption_fields(store, run, request, binding, output, factory.scope),
         :ok <- original_mr_identity(run, fields),
         {:ok, admission} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]),
         started = DateTime.utc_now(),
         {:ok, mr} <- collect_current_mr(run, fields, binding, opts),
         :ok <- current_mr(store, run, fields, binding, mr),
         {:ok, qualification} <- qualify_observation(qualification, mr, started),
         {:ok, branch_at} <- observe_branch(binding, opts),
         {:ok, fresh_admission} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         true <- fresh_admission == admission or {:error, :ticket_delivery_binding_changed},
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == push.binding["origin"] or {:error, :ticket_push_history_unproven} do
      {:ok, {fields, qualification, admission, push, branch_at}}
    end
  end

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

  defp effective_fields(store, run, request, binding, output) do
    if Store.one!(store, "SELECT qualification_key FROM ticket_mr_qualifications WHERE request_key=?", [request["request_key"]]) do
      TicketMrQualification.resolve(store, run, request, binding, output)
    else
      result_fields(run, output)
    end
  end

  defp adoption_fields(store, run, request, binding, output, scope) do
    case effective_fields(store, run, request, binding, output) do
      {:ok, fields} ->
        {:ok, fields, nil}

      {:error, _} ->
        case TicketMrQualification.prepare(store, run, request, binding, output, scope) do
          {:ok, pending} -> {:ok, Map.take(run, ~w(mr_iid mr_url mr_state)), pending}
          {:error, :ticket_mr_qualification_ineligible} -> {:error, :ticket_mr_result_mismatch}
          error -> error
        end
    end
  end

  defp qualify_observation(nil, _mr, _started), do: {:ok, nil}
  defp qualify_observation(qualification, mr, started), do: TicketMrQualification.observe(qualification, mr, started)

  defp original_mr_identity(run, fields) do
    current = Map.take(run, Map.keys(fields))

    if current == fields or (run["state"] != "CI_WAITING" and Enum.all?(current, fn {_key, value} -> is_nil(value) end)),
      do: :ok,
      else: {:error, :ticket_mr_recorded_identity_mismatch}
  end

  defp bound_read_session(binding, opts) do
    case Keyword.get(opts, :mcp_session) do
      session when is_map(session) ->
        if (session[:thread_id] || session["thread_id"]) == binding["controller_thread_id"] or Process.get({__MODULE__, :owned_read_session}) === session,
          do: :ok,
          else: {:error, :ticket_mr_read_session_mismatch}

      _ ->
        {:error, :gitlab_catalog_session_required}
    end
  end

  defp collect_current_mr(run, fields, binding, opts) do
    CiCollection.collect_mr(Map.merge(run, fields), binding["gitlab_project_id"], opts)
  end

  defp with_read_session(binding, opts, operation) do
    read_opts = Keyword.put(opts, :workspace, binding["controller_cwd"])

    with {:ok, canonical} <- controller_cwd(binding["controller_cwd"], binding["repo_path"], binding["source_workspace"]),
         true <- canonical == binding["controller_cwd"] or {:error, :ticket_mr_controller_cwd_changed} do
      if Keyword.get(opts, :ticket_mr_ephemeral_read, true) == true and is_nil(Keyword.get(opts, :mcp_session)) do
        AppServer.with_gitlab_read_session(canonical, &using_read_session(&1, read_opts, operation))
      else
        with :ok <- bound_read_session(binding, opts) do
          operation.(read_opts)
        end
      end
    end
  end

  defp using_read_session(session, read_opts, operation) do
    scope = {__MODULE__, :owned_read_session}
    previous = Process.put(scope, session)

    try do
      operation.(Keyword.put(read_opts, :mcp_session, session))
    after
      restore_scope(scope, previous)
    end
  end

  defp restore_scope(scope, nil), do: Process.delete(scope)
  defp restore_scope(scope, previous), do: Process.put(scope, previous)

  @doc "Adopts exact preflight CI evidence once without launching a verifier or writing Jira."
  @spec adopt_ci(Store.connection(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt_ci(%DBConnection{}, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def adopt_ci(store, run_id, authorization, factory, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, format} <- TicketMrPublication.receipt_format(store, run) do
      case format do
        :direct_publication -> adopt_direct_ci(store, run_id, authorization, factory, opts)
        :legacy -> adopt_legacy_ci(store, run_id, authorization, factory, opts)
      end
    end
  end

  defp adopt_direct_ci(store, run_id, authorization, factory, opts) do
    with {:ok, %{"state" => "CI_WAITING"} = run} <- RunLedger.get(store, run_id),
         {:ok, row} <- TicketMrPublication.record_for_run(store, run),
         intent = Jason.decode!(row["intent_json"]) do
      SymphonyElixir.Factory.GitLabMrWriter.with_session(intent["workspace"], opts, fn scoped ->
        with {:ok, receipt} <- TicketMrPublication.current_receipt(store, run_id, factory, scoped),
             {:ok, admission} <- TicketWorkerRunner.delivery_admission(store, run, authorization, scoped),
             {:ok, collected} <- TicketWorkerRunner.collect_ci(store, run_id, intent["project_id"], scoped),
             repair_opts = Keyword.merge(scoped, ci_repair_limit: factory.maximum_code_repair_rounds, ci_repair_scope: factory.scope, ci_repair_policy: factory.ticket_supervisor["ci_repair"]),
             {:ok, persist} <- TicketCiRepair.prepare_diagnosis(store, run, collected, intent["project_id"], repair_opts),
             :ok <- TicketMrPublication.validate_receipt(store, receipt, factory, scoped) do
          options = Keyword.merge(scoped, ci_diagnosis_persist: persist, mr_branch_at: DateTime.from_iso8601(receipt.observed_at) |> elem(1), direct_ci_proof: {receipt, factory, admission})

          case Exqlite.transaction(store, &adopt_ci_transaction(&1, run, receipt, collected, authorization, options)) do
            {:ok, result} -> result
            {:error, reason} -> {:error, reason}
          end
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_ci_stage_invalid}
    end
  end

  defp adopt_legacy_ci(store, run_id, authorization, factory, opts) do
    with {:ok, %{"state" => "CI_WAITING"} = run} <- RunLedger.get(store, run_id),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, key, request, binding} <- select_current_request(store, run, "CI_MR_CREATING", push),
         :ok <- authorize_readback(store, request),
         reader = &observe_ci_adoption(store, run, request, key, binding, authorization, factory, &1),
         {:ok, {collected, persist_diagnosis, branch_at}} <-
           with_read_session(binding, opts, reader) do
      opts = opts |> Keyword.put(:ci_diagnosis_persist, persist_diagnosis) |> Keyword.put(:mr_branch_at, branch_at)

      case Exqlite.transaction(store, &adopt_ci_transaction(&1, run, request, collected, authorization, opts)) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_ci_stage_invalid}
    end
  end

  defp observe_ci_adoption(store, run, request, key, binding, authorization, factory, opts) do
    with {:ok, fresh} <- bind_current(store, run, authorization, factory, request["cwd"], "CI_MR_CREATING", opts, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, output} <- ControllerTask.read_request_result(factory, key, StageSchemas.for_stage(:gitlab_mr), Keyword.put(opts, :store, store)),
         {:ok, fields} <- effective_fields(store, run, request, binding, output),
         :ok <- original_mr_identity(run, fields),
         {:ok, collected} <- TicketWorkerRunner.collect_ci(store, run["run_id"], binding["gitlab_project_id"], opts),
         repair_opts =
           opts
           |> Keyword.put(:ci_repair_limit, factory.maximum_code_repair_rounds)
           |> Keyword.put(:ci_repair_scope, factory.scope)
           |> Keyword.put(:ci_repair_policy, factory.ticket_supervisor["ci_repair"]),
         {:ok, persist} <- TicketCiRepair.prepare_diagnosis(store, run, collected, binding["gitlab_project_id"], repair_opts),
         {:ok, branch_at} <- observe_branch(binding, opts) do
      {:ok, {collected, persist, branch_at}}
    end
  end

  defp adopt_ci_transaction(store, run, request, collected, authorization, opts) do
    with :ok <- recent_branch(opts[:mr_branch_at]),
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_ci_candidate_changed},
         :ok <- ci_receipt_current(store, request, opts),
         {:ok, admission} <- ci_admission_current(store, current, authorization, opts),
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
        if evidence["status"] == "PASS" do
          updates
          |> Map.merge(%{"state" => "VERIFYING", "verifier_round" => current["verifier_round"] + 1})
          |> supersede_repair_exhaustion(current)
        else
          updates
        end

      case RunLedger.update(store, run["run_id"], updates) do
        {:ok, %{run: updated}} ->
          case persist_ci_diagnosis(store, updated, opts[:ci_diagnosis_persist]) do
            {:ok, final} -> {:ok, %{status: if(final["state"] == "REPAIRING", do: "CI_REPAIR_CLAIMED", else: "CI_" <> evidence["status"]), run: final}}
            {:error, reason} -> Exqlite.rollback(store, reason)
          end

        {:error, reason} ->
          Exqlite.rollback(store, reason)
      end
    else
      {:error, reason} -> Exqlite.rollback(store, reason)
    end
  end

  defp ci_receipt_current(store, %{format: :direct_publication} = receipt, opts) do
    {^receipt, factory, _} = opts[:direct_ci_proof]
    TicketMrPublication.validate_receipt(store, receipt, factory, opts)
  end

  defp ci_receipt_current(store, request, _opts) do
    with {:ok, observed} <- DesktopRequest.get(store, request["request_key"]),
         true <- observed == request or {:error, :ticket_mr_request_changed} do
      authorize_readback(store, observed)
    end
  end

  defp ci_admission_current(store, run, authorization, opts) do
    case opts[:direct_ci_proof] do
      {_receipt, _factory, admission} ->
        with :ok <- TicketWorkerRunner.recheck_delivery_admission(store, run, authorization, opts, admission), do: {:ok, admission}

      _ ->
        TicketWorkerRunner.delivery_admission(store, run, authorization, opts)
    end
  end

  defp persist_ci_diagnosis(_store, run, nil), do: {:ok, run}
  defp persist_ci_diagnosis(store, run, callback) when is_function(callback, 2), do: callback.(store, run)

  defp supersede_repair_exhaustion(updates, %{"failure_code" => "CI_REPAIR_EXHAUSTED", "last_error" => message}) when is_binary(message) do
    owned_suffixes = [
      "Human investigation or a new authorized policy decision is required; no new writer or retry was issued.",
      "No new writer, push, or retry was issued."
    ]

    if String.starts_with?(message, "CI repair budget exhausted: ") and Enum.any?(owned_suffixes, &String.ends_with?(message, &1)),
      do: Map.merge(updates, %{"failure_code" => nil, "last_error" => nil}),
      else: updates
  end

  defp supersede_repair_exhaustion(updates, _run), do: updates

  defp current_mr(store, run, fields, binding, mr) do
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
         true <- not SymphonyElixir.Factory.TicketPushHazard.active?(store, run["run_id"]) or mr["remove_source_branch"] == false or {:error, :ticket_mr_source_branch_removal_unproven},
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
    with :ok <- recent_branch(opts[:mr_branch_at]),
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_mr_candidate_changed},
         {:ok, observed} <- DesktopRequest.get(store, request["request_key"]),
         true <- observed == request or {:error, :ticket_mr_request_changed},
         :ok <- authorize_readback(store, observed),
         {:ok, admission, push} <- adoption_proofs(store, current, authorization, opts),
         :ok <- validate_push(push.binding, current, admission.checkout),
         :ok <- original_mr_identity(current, fields),
         :ok <- persist_qualification(store, opts[:mr_qualification]) do
      updates = if current["state"] == "CI_MR_CREATING", do: Map.put(fields, "state", "CI_WAITING"), else: fields

      with {:ok, result} <- persist_mr_fields(store, current, request["request_key"], updates) do
        case advance_original_controller_turn(store, request) do
          :ok -> {:ok, result}
          {:error, reason} -> Exqlite.rollback(store, reason)
        end
      end
    else
      {:error, reason} -> Exqlite.rollback(store, reason)
    end
  end

  defp adoption_proofs(store, run, authorization, opts) do
    case opts[:mr_qualification] do
      {_qualification, admission, push} when is_map(admission) ->
        with :ok <- TicketWorkerRunner.recheck_delivery_admission(store, run, authorization, opts, admission),
             :ok <- TicketPush.validate_completed_proof(store, run["run_id"], push),
             do: {:ok, admission, push}

      _ ->
        with {:ok, admission} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
             {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]),
             do: {:ok, admission, push}
    end
  end

  defp recent_branch(%DateTime{} = at) do
    if DateTime.diff(DateTime.utc_now(), at, :millisecond) in 0..60_000,
      do: :ok,
      else: {:error, :ticket_mr_readback_expired}
  end

  defp recent_branch(_), do: {:error, :ticket_mr_readback_unproven}

  defp persist_qualification(store, {%{} = qualification, _admission, _push}), do: TicketMrQualification.persist(store, qualification)
  defp persist_qualification(_store, _qualification), do: :ok

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
      [request["turn_id"], request["target_key"], request["existing_thread_id"], request["codex_project_id"], controller_anchor(metadata)]
    )

    if not Map.has_key?(metadata, "controller_ledger_turn_id") or Store.one!(store, "SELECT changes() AS count")["count"] == 1 do
      :ok
    else
      control = Control.status(store, request["target_key"])

      if {control["controller_thread_id"], control["controller_codex_project_id"], control["controller_turn_id"]} == {request["existing_thread_id"], request["codex_project_id"], request["turn_id"]},
        do: :ok,
        else: {:error, :ticket_mr_controller_turn_changed}
    end
  end

  defp controller_anchor(metadata), do: Map.get(metadata, "controller_ledger_turn_id", metadata["previous_turn_id"])

  @spec typed_request?(map()) :: boolean()
  def typed_request?(%{"target_kind" => "CONTROLLER", "metadata_json" => json}) when is_binary(json) do
    match?({:ok, %{"delivery_operation" => %{}}}, Jason.decode(json))
  end

  def typed_request?(_request), do: false

  @doc "Qualifies discovery only; fresh Jira and native guard evidence are still required to claim."
  @spec authorize_discovery(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def authorize_discovery(store, request, factory) do
    with true <- unissued?(request) or {:error, :ticket_mr_request_already_issued} do
      authorize_request_context(store, request, factory)
    end
  end

  @doc false
  @spec authorize_recovery_discovery(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def authorize_recovery_discovery(store, request, factory) do
    with :ok <- TicketMrPresendRecovery.available(store, request) do
      authorize_request_context(store, request, factory)
    end
  end

  defp authorize_request_context(store, request, factory) do
    with {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- validate_request(binding, request),
         :ok <- TicketMrCwdCorrection.validate(store, request),
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
    DesktopRequest.with_mr_claim_preadmission(store, key, factory, opts, fn ->
      claim_with_fresh_owner(store, key, factory, broker, observe_owner, opts)
    end)
  end

  defp claim_with_fresh_owner(store, key, factory, broker, observe_owner, opts) do
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
    read_authorization(store, key, factory, opts, :claim)
  end

  defp read_authorization(store, key, factory, opts, mode) do
    reader = Keyword.get(opts, :jira_reader, JiraMcpReader)

    with {:ok, request} <- DesktopRequest.get(store, key),
         :ok <- authorization_context(mode, store, request, factory),
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

  defp authorization_context(:claim, store, request, factory), do: authorize_discovery(store, request, factory)
  defp authorization_context(:recover, store, request, factory), do: authorize_recovery_discovery(store, request, factory)

  @doc "Produces claim evidence only for the original wholly unissued request."
  @spec claim_receipt(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_receipt(store, request, %{owner_admission: context, guard: proof}, _opts) do
    with true <- SymphonyElixir.Factory.BrokerRuntime.owner_admission_active?(context) or {:error, :mr_owner_service_authority_required},
         true <- (context.action == :claim and request == context.prepared.request) or {:error, :mr_owner_admission_binding_mismatch},
         :ok <- SymphonyElixir.Factory.TicketMrOwnerAdmission.recheck(store, context, context.factory),
         false <- competing_controller?(store, request["request_key"]),
         {:ok, guard} <- TicketMrGuard.receipt(request, proof, context.broker, DateTime.utc_now()),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]) do
      {:ok,
       %{
         "version" => 1,
         "request_key" => request["request_key"],
         "payload_sha256" => request["payload_sha256"],
         "binding" => context.prepared.binding,
         "previous_turn_id" => metadata["previous_turn_id"],
         "guard" => guard,
         "proof" => proof
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_claim_authority_required}
    end
  end

  def claim_receipt(store, request, admission, opts) when is_map(admission) do
    with %{factory: factory, authorization: authorization, guard: proof} <- admission,
         {:ok, binding} <- claim_binding(store, request, authorization, factory, opts),
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

  defp claim_binding(store, request, authorization, factory, opts) do
    case DesktopRequest.mr_claim_preadmission(store, request, factory) do
      {:ok, prepared} ->
        with :ok <- recheck_owner_preadmission(store, prepared, factory, opts),
             true <- DateTime.diff(DateTime.utc_now(), prepared.remote_at, :millisecond) in 0..10_000 or {:error, :mr_owner_admission_expired},
             true <- DateTime.diff(DateTime.utc_now(), prepared.runtime_at, :millisecond) in 0..60_000 or {:error, :mr_owner_admission_expired},
             :ok <- TicketWorkerRunner.recheck_delivery_admission(store, prepared.run, authorization, opts, prepared.admitted),
             do: {:ok, prepared.binding}

      {:error, _} when is_struct(store, DBConnection) ->
        {:error, :ticket_mr_claim_preadmission_required}

      {:error, _} ->
        check_new_request(store, request["request_key"], authorization, factory, opts)
    end
  end

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
         :ok <- TicketMrCwdCorrection.validate(store, request),
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
  def check_new_request(%DBConnection{}, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def check_new_request(store, key, authorization, factory, opts) do
    with {:ok, request} <- DesktopRequest.get(store, key),
         true <- unissued?(request) or {:error, :ticket_mr_request_already_issued},
         :ok <- exclusive_mr_owner(store, request),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- validate_request(binding, request),
         :ok <- TicketMrCwdCorrection.validate(store, request),
         {:ok, run} <- RunLedger.get(store, binding["run_id"]),
         true <- run["state"] == binding["stage"] or {:error, :ticket_mr_stage_invalid},
         true <- metadata["required_tool_calls"] == @required_calls or {:error, :ticket_mr_request_binding_mismatch},
         :ok <- require_new_admission(factory, binding["issue_key"]),
         control = Control.status(store, factory.scope),
         true <- controller_anchor(metadata) == control["controller_turn_id"] or {:error, :ticket_mr_controller_turn_changed},
         {:ok, fresh} <- bind_version(store, binding["run_id"], authorization, factory, request["cwd"], opts, binding["version"]),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, current} <- DesktopRequest.get(store, key),
         true <- (current == request and controller_claim_fence(Control.status(store, factory.scope)) == controller_claim_fence(control)) or {:error, :ticket_mr_request_changed} do
      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  # Scheduler lease turnover is not a change to native controller claim authority.
  defp controller_claim_fence(control) when is_map(control), do: Map.drop(control, @tick_bookkeeping)
  defp controller_claim_fence(control), do: control

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
      not SymphonyElixir.Factory.Policy.ticket_selected?(policy, issue_key) -> {:error, :ticket_mr_new_admission_disabled}
      true -> :ok
    end
  end

  @doc "Finds the original semantic request first; queues new work only after fresh ordinary admission."
  @spec prepare(Store.connection(), String.t(), map(), map(), Path.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(%DBConnection{}, _, _, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

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
         {:ok, binding} <- request_binding(request),
         {:ok, fields} <- effective_fields(store, run, request, binding, output),
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
         {:ok, route} <- ModelRouter.resolve(factory.models, "orchestrator"),
         {:ok, actor_proof} <- TicketMrCwdCorrection.observe_preparation(store, run, factory, cwd, opts) do
      attributes = request_attributes(store, run, binding, key, control, route, factory, description)
      attributes = preparation_anchor(attributes, actor_proof, control)
      enqueue_transaction(store, run, control, attributes, factory.scope, actor_proof)
    end
  end

  defp enqueue_transaction(store, run, control, attributes, scope, actor_proof) do
    case Exqlite.transaction(store, fn tx -> enqueue_current(tx, run, control, attributes, scope, actor_proof) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_current(store, run, control, attrs, scope, actor_proof) do
    with true <- not TicketMrPublication.recorded?(store, run["run_id"]) or {:error, :ticket_mr_direct_publication_exists},
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- (current == run and Control.status(store, scope) == control) or {:error, :ticket_mr_candidate_changed},
         false <- DesktopRequest.controller_busy?(store),
         {:ok, request} <- DesktopRequest.enqueue(store, attrs),
         :ok <- TicketMrCwdCorrection.preparation_current(store, request, actor_proof),
         {:ok, request} <- record_prepared_actor(store, request, actor_proof) do
      {:ok, %{status: "REQUEST_PREPARED", request: request}}
    else
      {:error, reason} -> Exqlite.rollback(store, reason)
      _ -> Exqlite.rollback(store, :ticket_mr_controller_busy)
    end
  end

  defp record_prepared_actor(_store, request, nil), do: {:ok, request}
  defp record_prepared_actor(store, request, proof), do: TicketMrCwdCorrection.record(store, request, proof, "PREPARED")

  defp preparation_anchor(attributes, nil, _control), do: attributes

  defp preparation_anchor(attributes, proof, control) do
    [%{"id" => previous}] = get_in(proof, ["native", "latest_turn_observation", "raw_response", "data"])
    metadata = attributes.metadata |> Map.put("previous_turn_id", previous) |> Map.put("controller_ledger_turn_id", control["controller_turn_id"])
    %{attributes | metadata: metadata}
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
  def bind(%DBConnection{}, _, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

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
      bind_admitted(store, run, admission, factory, cwd, stage, version, opts)
    end
  end

  defp bind_admitted(store, run, admission, factory, cwd, stage, version, opts) do
    with {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]) do
      bind_proven_push(store, run, admission, factory, cwd, push, {stage, version}, opts)
    end
  end

  defp rebind_admitted(store, run, admission, factory, cwd, push, revision, opts) do
    with :ok <- TicketPush.validate_completed_proof(store, run["run_id"], push),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == push.binding["origin"] or {:error, :ticket_push_history_unproven} do
      bind_proven_push(store, run, admission, factory, cwd, push, revision, opts)
    end
  end

  defp bind_proven_push(store, run, admission, factory, cwd, push, revision, opts) do
    case bind_proven_push_observed(store, run, admission, factory, cwd, push, revision, opts) do
      {:ok, binding, _remote_at} -> {:ok, binding}
      {:error, _} = error -> error
    end
  end

  defp bind_proven_push_observed(%DBConnection{}, _, _, _, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  defp bind_proven_push_observed(store, run, admission, factory, cwd, push, {stage, version}, opts) do
    with {:ok, canonical} <- controller_cwd(cwd, run["repo_path"], admission.checkout.path),
         :ok <- branch_name(run),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == push.binding["origin"] or {:error, :ticket_push_history_unproven},
         :ok <- gitlab_origin(run, factory, origin),
         {:ok, binding} <- binding_from_facts(store, run, admission, factory, canonical, stage, push, version),
         {:ok, at} <- with_read_session(binding, opts, &observe_branch(binding, &1)),
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_mr_candidate_changed} do
      {:ok, binding, at}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_binding_unproven}
    end
  end

  defp gitlab_origin(run, factory, origin) do
    project = get_in(factory.repositories, [run["repo_key"], "gitlab_project"])

    with true <- is_binary(project),
         {:ok, output} <- ControllerGitRead.run(run["repo_path"], ["remote", "get-url", "--all", "origin"]),
         [destination] <- String.split(output, "\n", trim: true),
         true <- hash(destination) == origin["destination_sha256"],
         true <- destination in for(prefix <- ["git@gitlab.com:", "ssh://git@gitlab.com/", "https://gitlab.com/"], suffix <- ["", ".git"], do: prefix <> project <> suffix) do
      :ok
    else
      _ -> {:error, :ticket_mr_gitlab_origin_mismatch}
    end
  end

  defp branch_name(%{"branch" => branch}) when branch in ~w(main master), do: {:error, :native_branch_protected}

  defp branch_name(run) do
    case ControllerGitRead.run(run["repo_path"], ["check-ref-format", "--branch", run["branch"]]) do
      {:ok, output} -> if(String.trim(output) == run["branch"], do: :ok, else: {:error, :native_branch_invalid})
      _ -> {:error, :native_branch_invalid}
    end
  end

  defp observe_branch(binding, opts) do
    connector = Keyword.get(opts, :connector, GitLabMcpConnector)
    at = DateTime.utc_now()

    with {:ok, sha} <- connector.branch_head(binding["gitlab_project_id"], binding["gitlab_project"], binding["source_branch"], opts),
         true <- sha == binding["candidate_sha"] or {:error, :ticket_mr_remote_candidate_changed} do
      {:ok, at}
    end
  end

  defp binding_from_facts(store, run, admission, factory, canonical, stage, push, version) do
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
      retain_actor_pin(store, binding)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_binding_unproven}
    end
  end

  @doc false
  @spec owner_preadmission(Store.connection(), String.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def owner_preadmission(%DBConnection{}, _, _, _, _), do: {:error, :mr_actor_observation_inside_transaction}

  def owner_preadmission(store, key, factory, broker, opts) do
    prepare_claim_admission(store, key, factory, broker, 2, opts, :claim)
  end

  @doc false
  @spec owner_recovery_preadmission(Store.connection(), String.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def owner_recovery_preadmission(%DBConnection{}, _, _, _, _), do: {:error, :mr_actor_observation_inside_transaction}
  def owner_recovery_preadmission(store, key, factory, broker, opts), do: prepare_claim_admission(store, key, factory, broker, 2, opts, :recover)

  @doc false
  @spec claim_preadmission(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_preadmission(%DBConnection{}, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def claim_preadmission(store, key, factory, opts) do
    with {:ok, request} <- DesktopRequest.get(store, key),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         {:ok, parent} <- TicketChat.ready_for_run(store, binding["run_id"]) do
      prepare_claim_admission(store, key, factory, parent["broker_thread_id"], binding["version"], opts, :claim)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_binding_mismatch}
    end
  end

  defp prepare_claim_admission(store, key, factory, broker, version, opts, mode) do
    with {:ok, request, run, authorization} <- read_authorization(store, key, factory, opts, mode),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         binding = metadata["delivery_operation"],
         true <- binding["version"] == version or {:error, :mr_owner_version_required},
         :ok <- issuance_state(mode, store, request, broker),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- parent["broker_thread_id"] == broker or {:error, :mr_guard_broker_mismatch},
         control = Control.status(store, factory.scope),
         true <- controller_anchor(metadata) == control["controller_turn_id"] or {:error, :ticket_mr_controller_turn_changed},
         :ok <- AppServer.check_ticket_runtime(request["cwd"]),
         runtime_at = DateTime.utc_now(),
         {:ok, admitted} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]),
         {:ok, fresh, remote_at} <-
           bind_proven_push_observed(store, run, admitted, factory, request["cwd"], push, {binding["stage"], version}, opts),
         true <- fresh == binding or {:error, :ticket_mr_request_binding_mismatch},
         {:ok, ^request} <- DesktopRequest.get(store, key),
         true <- controller_claim_fence(Control.status(store, factory.scope)) == controller_claim_fence(control) or {:error, :ticket_mr_request_changed} do
      prepared_admission = %{
        request: request,
        run: run,
        authorization: authorization,
        admitted: admitted,
        binding: binding,
        parent: parent,
        control: control,
        remote_at: remote_at,
        runtime_at: runtime_at
      }

      {:ok, prepared_admission}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_request_changed}
    end
  end

  @doc false
  @spec recheck_owner_preadmission(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def recheck_owner_preadmission(store, prepared, factory, opts) do
    recheck_prepared(store, prepared, factory, opts, :claim)
  end

  @doc false
  @spec recheck_owner_recovery(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def recheck_owner_recovery(store, prepared, factory, opts), do: recheck_prepared(store, prepared, factory, opts, :recover)

  defp recheck_prepared(store, prepared, factory, opts, mode) do
    with {:ok, current} <- DesktopRequest.get(store, prepared.request["request_key"]),
         true <- current == prepared.request or {:error, :ticket_mr_request_changed},
         :ok <- issuance_state(mode, store, current, prepared.parent["broker_thread_id"]),
         :ok <- validate_request(prepared.binding, current),
         :ok <- TicketMrCwdCorrection.validate(store, current),
         :ok <- exclusive_mr_owner(store, current),
         :ok <- require_new_admission(factory, prepared.run["issue_key"]),
         {:ok, run} <- RunLedger.get(store, prepared.run["run_id"]),
         true <- (run == prepared.run and controller_claim_fence(Control.status(store, factory.scope)) == controller_claim_fence(prepared.control)) or {:error, :ticket_mr_request_changed},
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- parent == prepared.parent or {:error, :ticket_mr_request_changed},
         :ok <- TicketWorkerRunner.recheck_delivery_admission(store, run, prepared.authorization, opts, prepared.admitted) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp issuance_state(:claim, _store, request, _broker) do
    if unissued?(request), do: :ok, else: {:error, :ticket_mr_request_already_issued}
  end

  defp issuance_state(:recover, store, request, broker), do: TicketMrPresendRecovery.available(store, request, broker)

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

    valid_binding_fields?(binding) and
      binding["version"] in [1, 2] and binding["operation"] == @operation and
      binding["stage"] in ~w(MR_CREATING CI_MR_CREATING) and
      positive_integer?(binding["gitlab_project_id"]) and
      positive_integer?(binding["spec_revision"]) and
      binding["ci_preflight"] == (binding["stage"] == "CI_MR_CREATING") and
      Enum.all?(strings, &present?(binding[&1])) and
      valid_hashes?(binding)
  end

  defp valid_binding_fields?(binding) do
    keys = Enum.sort(Map.keys(binding))

    keys == Enum.sort(@fields) or
      (binding["version"] == 2 and keys == Enum.sort(@fields ++ ["controller_native_cwd"]) and
         is_binary(binding["controller_native_cwd"]) and String.starts_with?(binding["controller_native_cwd"], "/"))
  end

  defp retain_actor_pin(store, binding) do
    with {:ok, key} <- request_key(binding),
         {:ok, request} <- DesktopRequest.get(store, key),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         stored when is_map(stored) <- metadata["delivery_operation"],
         pin when is_binary(pin) <- stored["controller_native_cwd"] do
      with true <- Map.delete(stored, "controller_native_cwd") == binding or {:error, :mr_actor_inputs_changed},
           :ok <- TicketMrCwdCorrection.validate(store, request) do
        {:ok, Map.put(binding, "controller_native_cwd", pin)}
      end
    else
      {:error, :unknown_request} -> {:ok, binding}
      nil -> {:ok, binding}
      {:error, _} = error -> error
      _ -> {:error, :mr_actor_audit_unproven}
    end
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
