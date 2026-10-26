defmodule SymphonyElixir.Factory.TicketWorkerRunner do
  @moduledoc """
  Controller-owned role turns in one reserved checkout, separate from the Desktop parent.
  """
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{CiCollection, Contract, ControllerCi, ReviewProtocol, RunLedger}
  alias SymphonyElixir.Factory.{SpecialistErrorNotice, StageRunner, Store, TaskLedger}

  alias SymphonyElixir.Factory.{
    TicketCapabilityRecovery,
    TicketChat,
    TicketChatCommands,
    TicketCiGeneratedScope,
    TicketCiRepair,
    TicketCompletionConfirmation,
    TicketContractAmendment,
    TicketMrOperation,
    WorkerCheckIO,
    WorkerEvidence
  }

  alias SymphonyElixir.Factory.TicketJiraJournal
  alias SymphonyElixir.Factory.{WorkerFileTools, WorkerInstructions, WorkspaceAccess}
  alias SymphonyElixir.Factory.Worktree
  alias SymphonyElixir.Tracker.Issue

  @doc "Admits a writer in the existing pinned checkout; does not launch or allocate source work."
  @spec admit_writer(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit_writer(store, run, authorization, opts) do
    Store.transaction!(store, &admit_writer_transaction(&1, run, authorization, opts))
  end

  defp admit_writer_transaction(store, run, authorization, opts) do
    with {:ok, %{run: current}} <- writer_admission_facts(store, run, Keyword.delete(opts, :reservation)),
         :ok <- WorkspaceAccess.source_capacity(store, current, opts),
         :ok <- validate_authorization(current, authorization),
         {:ok, %{run: admitted}} <- RunLedger.update(store, run["run_id"], %{state: "WRITING", workspace_state: "MATERIALIZED"}) do
      {:ok, %{status: "WRITER_ADMITTED", run: admitted, model_invoked: false}}
    end
  end

  @doc "Reads pinned initial-writer facts only; it grants neither source admission nor Jira mutation authority."
  @spec writer_admission_facts(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def writer_admission_facts(store, run, opts) do
    with {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- (current == run and current["state"] == "ADMITTING_WRITER") or {:error, :ticket_writer_admission_changed},
         :ok <- TicketChat.ordinary_delivery_eligibility(current),
         {:ok, _} <- TicketChat.ready_for_run(store, run["run_id"]),
         %{"base_sha" => base} <- Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]]),
         true <- is_binary(run["worktree"]) or {:error, :ticket_source_checkout_not_admitted},
         {:ok, root} <- Keyword.fetch(opts, :workspace_root),
         {:ok, checkout} <- bound_checkout(store, run, run["candidate_sha"] || base, root, opts),
         {:ok, after_check} <- RunLedger.get(store, current["run_id"]),
         true <- after_check == current or {:error, :ticket_writer_admission_changed} do
      {:ok, %{run: current, checkout: checkout, expected_sha: run["candidate_sha"] || base}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_writer_admission_unproven}
    end
  end

  @doc "Checks exact stopped source and verification evidence before controller delivery."
  @spec delivery_admission(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delivery_admission(store, run, authorization, opts) do
    with {:ok, delivery_opts} <- delivery_review_options(store, run, opts),
         {:ok, history} <- observe_delivery_authorization(store, run, authorization, delivery_opts),
         {:ok, facts} <- delivery_facts(store, run, delivery_opts),
         :ok <- recheck_observed_authorization(store, facts.run, authorization, history) do
      {:ok, Map.put(facts, :retained_mr_history, history)}
    end
  end

  @doc false
  @spec delivery_authorization(Store.connection(), map(), map(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delivery_authorization(store, run, snapshot, observed_at, opts) do
    case authorization(run, snapshot, observed_at) do
      {:error, :ticket_jira_not_dispatchable} ->
        with {:ok, delivery_opts} <- delivery_review_options(store, run, opts),
             do: retained_mr_delivery_authorization(store, run, snapshot, observed_at, delivery_opts)

      result ->
        result
    end
  end

  @doc false
  @spec refresh_delivery_authorization(map(), map(), DateTime.t(), map()) :: {:ok, map()} | {:error, term()}
  def refresh_delivery_authorization(run, snapshot, observed_at, prior) do
    fields = ~w(run_id issue_key spec_revision contract_sha256)
    review? = prior["delivery_review"] == true
    authorized_run = if review?, do: Map.put(run, "state", "REVIEW_WRITING"), else: run

    with true <- Map.take(run, fields) == Map.take(prior, fields) or {:error, :ticket_authorization_changed},
         {:ok, proof} <- authorization(authorized_run, snapshot, observed_at) do
      {:ok, if(review?, do: Map.put(proof, "delivery_review", true), else: proof)}
    end
  end

  @doc false
  @spec delivery_review_options(Store.connection(), map(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def delivery_review_options(store, %{"state" => "MR_CREATING"} = run, opts) do
    with {:ok, selection} <- TicketJiraJournal.select_review_operation(store, run["run_id"]) do
      selection_delivery_review_options(store, selection, run, opts)
    end
  end

  def delivery_review_options(_store, _run, opts), do: {:ok, opts}

  defp selection_delivery_review_options(_store, %{disposition: :new}, _run, opts) do
    if is_nil(opts[:reservation]), do: {:ok, opts}, else: {:error, :ticket_delivery_reservation_invalid}
  end

  defp selection_delivery_review_options(store, %{disposition: :reuse, operation_key: key}, run, opts) do
    reuse_delivery_review_options(store, key, run, opts)
  end

  defp reuse_delivery_review_options(store, key, run, opts) do
    with {:ok, access} <- WorkspaceAccess.get(store, key),
         {:ok, access} <- WorkspaceAccess.validate(store, key, access["generation"]),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {run["run_id"], "MAINTENANCE", key, nil} or {:error, :ticket_delivery_reservation_invalid},
         reservation = %{key: key, generation: access["generation"]},
         true <-
           is_nil(opts[:reservation]) or opts[:reservation] == reservation or
             {:error, :ticket_delivery_reservation_invalid} do
      {:ok, Keyword.put(opts, :reservation, reservation)}
    else
      {:error, _} = error -> error
    end
  end

  defp retained_mr_delivery_authorization(store, %{"state" => state, "mr_iid" => iid, "mr_url" => url} = run, snapshot, observed_at, opts)
       when state in ~w(PUSHING MR_CREATING CI_PUSHING CI_MR_CREATING CI_WAITING) and is_integer(iid) and is_binary(url) do
    review_run = Map.put(run, "state", "REVIEW_WRITING")

    with :ok <- retained_ci_route(store, run, opts),
         {:ok, proof} <- authorization(review_run, snapshot, observed_at),
         {:ok, _facts} <- delivery_facts(store, run, opts),
         {:ok, prior} <- retained_review_preimage(store, run),
         true <- {prior["mr_iid"], prior["mr_url"]} == {iid, url} or {:error, :ticket_delivery_mr_history_unproven},
         :ok <- TicketMrOperation.validate_retained_mr_history(store, prior) do
      {:ok, Map.put(proof, "delivery_review", true)}
    else
      {:error, :ticket_delivery_review_history_absent} -> {:error, :ticket_jira_not_dispatchable}
      {:error, _} = error -> error
    end
  end

  defp retained_mr_delivery_authorization(_store, _run, _snapshot, _observed_at, _opts), do: {:error, :ticket_jira_not_dispatchable}

  defp retained_ci_route(store, %{"state" => state} = run, opts) when state in ~w(CI_PUSHING CI_MR_CREATING CI_WAITING) do
    with true <- opts[:ci_preflight_authorized] == true or {:error, :ticket_ci_preflight_not_authorized},
         {:ok, _prior} <- SymphonyElixir.Factory.TicketCiRepair.retained_preimage(store, run) do
      :ok
    end
  end

  defp retained_ci_route(_store, _run, _opts), do: :ok

  @doc false
  @spec retained_review_preimage(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def retained_review_preimage(store, run) do
    case SymphonyElixir.Factory.TicketCiRepair.retained_preimage(store, run) do
      {:ok, prior} -> {:ok, prior}
      {:error, :ci_repair_history_absent} -> human_review_preimage(store, run)
      {:error, _} = error -> error
    end
  end

  defp human_review_preimage(store, run) do
    reworks =
      Store.query!(store, "SELECT command_key, payload_json, application_receipt_json FROM ticket_chat_commands WHERE run_id = ? AND status = 'APPLIED' ORDER BY created_at DESC", [run["run_id"]]).rows
      |> Enum.map(fn [command_key, payload_json, receipt_json] -> %{"command_key" => command_key, "payload_json" => payload_json, "application_receipt_json" => receipt_json} end)

    case Enum.find_value(reworks, &ready_rework_history(store, &1)) do
      {:ok, prior} -> {:ok, prior}
      {:error, _} = error -> error
      nil -> amendment_review_preimage(store, run)
    end
  end

  defp amendment_review_preimage(store, run) do
    case Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase = 'APPLIED' ORDER BY updated_at DESC LIMIT 1", [run["run_id"]]) do
      nil ->
        {:error, :ticket_delivery_review_history_absent}

      amendment ->
        amendment_review_preimage_record(store, amendment["command_key"])
    end
  end

  defp amendment_review_preimage_record(store, command_key) do
    with {:ok, record} <- TicketContractAmendment.get(store, command_key),
         {:ok, receipt} when is_map(receipt) <- Jason.decode(record["receipt_json"]),
         {:ok, prior} when is_map(prior) <- Jason.decode(receipt["prior_run_json"]) do
      cond do
        is_nil(prior["mr_iid"]) and is_nil(prior["mr_url"]) -> {:error, :ticket_delivery_review_history_absent}
        is_integer(prior["mr_iid"]) and is_binary(prior["mr_url"]) -> {:ok, prior}
        true -> {:error, :ticket_delivery_mr_history_unproven}
      end
    else
      _ -> {:error, :ticket_delivery_mr_history_unproven}
    end
  end

  defp ready_rework_history(store, %{"command_key" => key} = row) do
    case ready_rework_kind(row) do
      :not_applicable ->
        nil

      :ready ->
        validate_ready_rework_history(store, key)

      :blocked ->
        case TicketChatCommands.validate_rework_replay(store, key) do
          :ok -> nil
          {:error, _} -> {:error, :ticket_delivery_blocked_rework_history_corrupt}
        end

      :corrupt_ready ->
        {:error, :ticket_delivery_ready_rework_history_corrupt}

      :unknown ->
        {:error, :ticket_delivery_ready_rework_history_unclassified}
    end
  end

  defp ready_rework_kind(row) do
    payload = Jason.decode(row["payload_json"] || "null")
    receipt = Jason.decode(row["application_receipt_json"] || "null")

    receipt_kind =
      case receipt do
        {:ok, %{"kind" => "READY_WRITER_REWORK"}} -> :ready
        {:ok, %{"kind" => "BLOCKED_WRITER_RESUMED"}} -> :blocked
        _ -> :unknown
      end

    case receipt_kind do
      :ready ->
        :ready

      :blocked ->
        :blocked

      _ ->
        classify_unknown_rework_payload(payload)
    end
  end

  defp classify_unknown_rework_payload({:ok, operations}) when is_list(operations), do: classify_unknown_rework_operations(operations)
  defp classify_unknown_rework_payload(_payload), do: :unknown

  defp classify_unknown_rework_operations(operations) do
    if Enum.any?(operations, &match?(%{"operation" => "request_rework"}, &1)), do: :corrupt_ready, else: :not_applicable
  end

  defp validate_ready_rework_history(store, key) do
    with {:ok, %{receipt: receipt}} <- TicketChatCommands.validate_ready_rework_replay(store, key),
         {:ok, prior} when is_map(prior) <- Jason.decode(receipt["prior_run_json"]),
         true <- is_integer(prior["mr_iid"]) and is_binary(prior["mr_url"]) do
      {:ok, prior}
    else
      _ -> {:error, :ticket_delivery_ready_rework_history_corrupt}
    end
  end

  defp observe_delivery_authorization(store, run, %{"delivery_review" => true} = proof, _opts) do
    with :ok <- validate_authorization(Map.put(run, "state", "REVIEW_WRITING"), Map.delete(proof, "delivery_review")),
         {:ok, prior} <- retained_review_preimage(store, run),
         true <- {prior["mr_iid"], prior["mr_url"]} == {run["mr_iid"], run["mr_url"]} or {:error, :ticket_delivery_mr_history_unproven} do
      TicketMrOperation.observe_retained_mr_history(store, prior)
    end
  end

  defp observe_delivery_authorization(_store, run, proof, _opts) do
    with :ok <- validate_authorization(run, proof), do: {:ok, nil}
  end

  defp recheck_observed_authorization(store, run, %{"delivery_review" => true} = proof, history) when is_map(history) do
    with :ok <- validate_authorization(Map.put(run, "state", "REVIEW_WRITING"), Map.delete(proof, "delivery_review")),
         {:ok, prior} <- retained_review_preimage(store, run),
         true <- {prior["mr_iid"], prior["mr_url"]} == {run["mr_iid"], run["mr_url"]} or {:error, :ticket_delivery_mr_history_unproven} do
      TicketMrOperation.recheck_retained_mr_history(store, prior, history)
    end
  end

  defp recheck_observed_authorization(_store, _run, %{"delivery_review" => true}, _history), do: {:error, :ticket_delivery_mr_history_unproven}
  defp recheck_observed_authorization(_store, run, proof, nil), do: validate_authorization(run, proof)
  defp recheck_observed_authorization(_store, _run, _proof, _history), do: {:error, :ticket_delivery_mr_history_unproven}

  @doc "Reads exact stopped delivery evidence without granting dispatch or external-write authority."
  @spec delivery_facts(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delivery_facts(store, run, opts) do
    with {:ok, facts} <- delivery_ledger_facts(store, run, opts),
         current = facts.run,
         {:ok, _} <- TicketChat.ready_for_run(store, current["run_id"]),
         {:ok, root} <- Keyword.fetch(opts, :workspace_root),
         {:ok, checkout} <- bound_checkout(store, current, current["candidate_sha"], root, opts),
         {:ok, after_check} <- RunLedger.get(store, current["run_id"]),
         true <- after_check == current or {:error, :ticket_delivery_binding_changed} do
      {:ok, Map.put(facts, :checkout, checkout)}
    else
      :error -> {:error, :ticket_delivery_workspace_root_required}
      {:error, _} = error -> error
    end
  end

  @doc "Rechecks captured delivery ledger facts without repeating physical checkout observation."
  @spec recheck_delivery_facts(Store.connection(), map(), keyword(), map()) :: :ok | {:error, term()}
  def recheck_delivery_facts(store, run, opts, captured) when is_map(captured) do
    with {:ok, facts} <- delivery_ledger_facts(store, run, opts),
         true <- facts == Map.take(captured, [:run, :verifier]) or {:error, :ticket_delivery_binding_changed} do
      :ok
    end
  end

  def recheck_delivery_facts(_store, _run, _opts, _captured), do: {:error, :ticket_delivery_binding_changed}

  @doc false
  @spec recheck_delivery_admission(Store.connection(), map(), map(), keyword(), map()) :: :ok | {:error, term()}
  def recheck_delivery_admission(store, run, authorization, opts, admitted) do
    with {:ok, delivery_opts} <- delivery_review_options(store, run, opts),
         :ok <- recheck_observed_authorization(store, run, authorization, admitted[:retained_mr_history]),
         {:ok, facts} <- delivery_ledger_facts(store, run, delivery_opts),
         true <- facts == Map.take(admitted, [:run, :verifier]) or {:error, :ticket_delivery_binding_changed} do
      :ok
    end
  end

  defp delivery_ledger_facts(store, run, opts) do
    with {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_delivery_binding_changed},
         true <- current["state"] in ~w(PUSHING MR_CREATING CI_PUSHING CI_MR_CREATING CI_WAITING) or {:error, :ticket_delivery_stage_not_admitted},
         :ok <- TicketChat.ordinary_delivery_eligibility(current),
         true <- is_binary(current["candidate_sha"]) or {:error, :ticket_delivery_candidate_missing},
         :ok <- stopped_delivery_evidence(store, current),
         {:ok, verifier} <- delivery_verifier(store, current, opts) do
      {:ok, %{run: current, verifier: verifier}}
    else
      {:error, _} = error -> error
    end
  end

  defp bound_checkout(store, run, sha, root, opts) do
    case opts[:reservation] do
      nil -> WorkspaceAccess.checkout_admission(store, run, sha, root)
      %{key: key, generation: generation} -> owned_delivery_checkout(store, run, sha, root, key, generation)
      _ -> {:error, :ticket_delivery_reservation_invalid}
    end
  end

  defp owned_delivery_checkout(store, run, sha, root, key, generation) do
    with {:ok, access} <- WorkspaceAccess.validate(store, key, generation),
         ownership = {access["mode"], access["run_id"], access["task_key"]},
         true <- ownership == {"MAINTENANCE", run["run_id"], nil} or {:error, :ticket_delivery_reservation_invalid},
         true <- access["request_key"] == key or {:error, :ticket_delivery_reservation_invalid},
         {:ok, binding} <- Jason.decode(access["binding_json"]),
         expected = {sha, root},
         true <-
           {binding["expected_sha"], binding["allowed_root"]} == expected or
             {:error, :ticket_delivery_reservation_invalid} do
      {:ok,
       %{
         path: access["canonical_path"],
         git_dir: access["git_dir"],
         common_dir: access["common_dir"],
         root_device: binding["root_device"],
         root_inode: binding["root_inode"]
       }}
    end
  end

  defp stopped_delivery_evidence(store, run) do
    pending = WorkerEvidence.pending(store, run["run_id"]) |> List.first()

    files =
      Store.one!(
        store,
        "SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence worker ON worker.request_key = op.request_key WHERE worker.run_id = ? AND (op.phase = 'PREPARED' OR op.io_pending = 1) LIMIT 1",
        [run["run_id"]]
      )

    reservations = Store.query!(store, "SELECT DISTINCT reservation_key FROM worker_evidence WHERE run_id = ?", [run["run_id"]]).rows

    with true <- is_nil(pending) or {:error, :ticket_delivery_worker_unconsumed},
         true <- is_nil(files) or {:error, :ticket_delivery_file_io_unreconciled} do
      with :ok <- delivery_checks_stopped(store, reservations) do
        completed_candidate_check(store, run)
      end
    end
  end

  defp delivery_checks_stopped(store, reservations) do
    Enum.reduce_while(reservations, :ok, fn [key], :ok ->
      case WorkerEvidence.checks_stopped(store, key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  @spec delivery_candidate_check(Store.connection(), map()) :: :ok | {:error, term()}
  def delivery_candidate_check(store, run), do: completed_candidate_check(store, run)

  defp completed_candidate_check(store, run) do
    rows =
      Store.query!(
        store,
        "SELECT check_row.binding_json, check_row.receipt_json FROM controller_checks check_row JOIN worker_evidence worker ON worker.request_key = check_row.worker_request_key WHERE worker.run_id = ? AND worker.status = 'CONSUMED' AND check_row.phase = 'COMPLETE'",
        [run["run_id"]]
      ).rows

    fields = ~w(run_id candidate_sha spec_revision contract_sha256)

    proven =
      Enum.any?(rows, fn [raw, receipt] ->
        with {:ok, binding} <- Jason.decode(raw),
             {:ok, %{"result" => "PASS", "candidate_sha" => sha}} <- Jason.decode(receipt) do
          Map.take(binding, fields) == Map.take(run, fields) and sha == run["candidate_sha"]
        else
          _ -> false
        end
      end)

    cond do
      proven -> :ok
      match?({:ok, %{"kind" => "HUMAN_EMPTY_COMMIT_IMPORT_V1"}}, Jason.decode(run["candidate_handoff"] || "null")) -> SymphonyElixir.Factory.TicketHumanEmptyCommitImport.source_equivalence(store, run)
      true -> {:error, :ticket_delivery_candidate_check_unproven}
    end
  end

  defp delivery_verifier(_store, %{"state" => state} = run, opts) when state in ~w(CI_PUSHING CI_MR_CREATING CI_WAITING) do
    cond do
      opts[:ci_preflight_authorized] != true -> {:error, :ticket_ci_preflight_not_authorized}
      state != "CI_PUSHING" and run["ci_preflight_sha"] != run["candidate_sha"] -> {:error, :ticket_ci_preflight_candidate_unproven}
      true -> {:ok, nil}
    end
  end

  defp delivery_verifier(store, run, _opts) do
    key = "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}"

    with {:ok, %{"status" => "CONSUMED"} = task} <- TaskLedger.get(store, key),
         {:ok, %{"status" => "CONSUMED"} = evidence} <- WorkerEvidence.verifier_receipt(store, run, task),
         {:ok, %{"status" => "PASS", "candidate_sha" => sha}} <- Jason.decode(evidence["output_json"]),
         true <- sha == run["candidate_sha"] do
      {:ok, evidence}
    else
      _ -> {:error, :ticket_delivery_verifier_pass_unproven}
    end
  end

  @doc "Checks CI readback data against the current candidate; does not attest transport or advance delivery."
  @spec ci_binding(Store.connection(), String.t(), map(), pos_integer() | nil) :: {:ok, map()} | {:error, term()}
  def ci_binding(store, run_id, snapshots, expected_project_id \\ nil) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- exact_contract(run) do
      ControllerCi.bind(run, snapshots, expected_project_id)
    end
  end

  @doc "Collects bounded remote reads outside a ledger transaction, then rechecks local candidate/contract identity."
  @spec collect_ci(Store.connection(), String.t(), pos_integer() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def collect_ci(store, run_id, expected_project_id, opts) do
    with {:ok, before} <- RunLedger.get(store, run_id),
         :ok <- exact_contract(before),
         {:ok, snapshots} <- CiCollection.collect(before, expected_project_id, opts),
         {:ok, after_read} <- RunLedger.get(store, run_id),
         true <- ci_scope(before) == ci_scope(after_read) or {:error, :ci_local_binding_changed},
         :ok <- exact_contract(after_read),
         {:ok, evidence} <- ControllerCi.bind(after_read, snapshots, expected_project_id) do
      {:ok, %{"snapshots" => snapshots, "evidence" => evidence, "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}
    end
  end

  defp ci_scope(run), do: Map.take(run, ~w(run_id state candidate_sha ci_preflight_sha mr_iid mr_url branch base_branch contract_sha256 spec_revision))

  @doc "Binds the controller's fresh Jira readback to an ordinary run revision for one admission."
  @spec authorization(map(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def authorization(run, snapshot, observed_at) when is_map(snapshot) do
    fresh = Map.put(run, "snapshot_json", Jason.encode!(snapshot))

    with :ok <- TicketChat.ordinary_delivery_eligibility(fresh),
         true <- snapshot["id"] == Jason.decode!(run["snapshot_json"])["id"] or {:error, :ticket_authorization_identity_changed},
         true <- authorized_jira_state?(snapshot, run) or {:error, :ticket_jira_not_dispatchable} do
      {:ok,
       Map.take(run, ~w(run_id issue_key spec_revision contract_sha256))
       |> Map.merge(%{"snapshot_json" => fresh["snapshot_json"], "observed_at" => DateTime.to_iso8601(observed_at)})}
    end
  end

  @doc false
  @spec ready_rework_authorization(map(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def ready_rework_authorization(%{"state" => "READY_FOR_REVIEW"} = run, snapshot, observed_at) do
    review_run = Map.put(run, "state", "REVIEW_WRITING")

    with true <- (is_list(snapshot["labels"]) and "ai-review" in snapshot["labels"]) or {:error, :ticket_jira_not_dispatchable},
         true <- String.downcase(snapshot["status"] || "") in ["in review", "in dev", "in progress"] or {:error, :ticket_jira_not_dispatchable} do
      authorization(review_run, snapshot, observed_at)
    else
      {:error, _} = error -> error
    end
  end

  def ready_rework_authorization(_run, _snapshot, _observed_at), do: {:error, :ticket_command_run_state_changed}

  @doc false
  @spec ready_rework_packet(String.t(), String.t(), String.t()) :: String.t()
  def ready_rework_packet(base_packet, command_key, input_body) do
    base_packet
    |> Jason.decode!()
    |> Map.put("direct_ticket_rework", %{"command_key" => command_key, "native_body" => input_body})
    |> Jason.encode!()
  end

  defp authorized_jira_state?(%{"labels" => labels, "status" => status}, run) when is_list(labels) and is_binary(status) do
    review? = run["state"] in ~w(REVIEW_WRITING VERIFYING)
    allowed = if review?, do: ~w(ai-review ai-running ai-verifying), else: ~w(ai-ready ai-running ai-verifying)
    statuses = if review?, do: ["in dev", "in progress", "in review"], else: ["to do", "in dev", "in progress"]

    Enum.any?(allowed, &(&1 in labels)) and "ai-blocked" not in labels and "spec-needed" not in labels and
      String.downcase(status) in statuses
  end

  defp authorized_jira_state?(_snapshot, _run), do: false

  @doc "Rechecks admission freshness and exact run binding before task or reservation writes."
  @spec validate_authorization(map(), term()) :: :ok | {:error, term()}
  def validate_authorization(run, %{"observed_at" => at, "snapshot_json" => raw} = proof) when is_binary(at) and is_binary(raw) do
    fields = ~w(run_id issue_key spec_revision contract_sha256)

    with true <- Map.take(run, fields) == Map.take(proof, fields) or {:error, :ticket_authorization_changed},
         {:ok, observed, _} <- DateTime.from_iso8601(at),
         age = DateTime.diff(DateTime.utc_now(), observed, :second),
         true <- age in -5..60 or {:error, :ticket_authorization_expired},
         {:ok, snapshot} when is_map(snapshot) <- Jason.decode(raw),
         {:ok, _} <- authorization(run, snapshot, observed) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_authorization_invalid}
    end
  end

  def validate_authorization(_run, _proof), do: {:error, :ticket_authorization_required}

  @doc "Prepares exact stopped role evidence for controller adoption; writer checks keep source reserved."
  @spec adoption(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def adoption(store, key) do
    with {:ok, bound} <- Store.transaction!(store, &adoption_inputs(&1, key), timeout: 60_000),
         {:ok, _} <- adoption_role(store, bound.run, bound.task, bound.evidence, bound.output),
         {:ok, current} <- RunLedger.get(store, bound.run["run_id"]) do
      {:ok, %{bound | run: current}}
    end
  end

  defp adoption_inputs(store, key) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         {:ok, run} <- RunLedger.get(store, task["run_id"]),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, _} <- TicketChat.ready_for_run(store, run["run_id"]),
         :ok <- admitted_stage(run, task["role"]),
         true <- task["stage"] == run["state"] or {:error, :ticket_worker_stage_changed},
         {:ok, output} <- Jason.decode(evidence["output_json"] || "null"),
         :ok <- adoption_output_shape(evidence, output),
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         :ok <- ReviewProtocol.validate_result(store, task, binding, output),
         {:ok, task} <- WorkerEvidence.adopt_completed(store, key) do
      {:ok, %{run: run, task: task, evidence: evidence, output: output}}
    end
  end

  defp adoption_output_shape(%{"status" => status}, nil) when status in ~w(START_SENT THREAD_BOUND TURN_BOUND),
    do: {:error, :worker_not_ready_for_consumption}

  defp adoption_output_shape(_evidence, output) when is_map(output), do: :ok
  defp adoption_output_shape(_evidence, _output), do: {:error, :worker_output_invalid}

  @doc "Checks the ordinary role's exact controller stage before any worker or commit."
  @spec admitted_stage(map(), String.t()) :: :ok | {:error, atom()}
  def admitted_stage(%{"state" => "PLANNING"}, "feature-planner"), do: :ok
  def admitted_stage(%{"state" => state}, "feature-writer") when state in ~w(WRITING REPAIRING REVIEW_WRITING), do: :ok
  def admitted_stage(%{"state" => "VERIFYING"}, "change-verifier"), do: :ok
  def admitted_stage(_run, _role), do: {:error, :ticket_role_stage_not_admitted}

  defp adoption_role(store, run, %{"role" => "change-verifier"} = task, evidence, output) do
    with {:ok, verifier} <- WorkerEvidence.verifier_receipt(store, run, task),
         :ok <- verifier_controller_check(store, run, evidence, output) do
      {:ok, verifier}
    end
  end

  defp adoption_role(_store, _run, %{"role" => "feature-planner"}, evidence, _output), do: {:ok, evidence}

  defp adoption_role(store, run, %{"role" => "feature-writer"}, evidence, output) do
    with :ok <- WorkerFileTools.reconcile(store, evidence["request_key"]),
         {:ok, _} <- TicketChat.ready_for_run(store, run["run_id"]),
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_writer_adoption_changed},
         {:ok, effective} <- SymphonyElixir.Factory.TicketCiGeneration.complete(store, evidence["request_key"], run, output),
         :ok <- SymphonyElixir.Factory.TicketCiRepair.writer_result(store, run, output, effective["changed_paths"]),
         {:ok, candidate} <- writer_candidate(run, evidence, effective),
         :ok <- persist_writer_candidate(store, run, evidence, candidate),
         {:ok, check} <- check(store, evidence["request_key"], "git-diff-check"),
         {:ok, %{"result" => "PASS", "candidate_sha" => ^candidate}} <- Jason.decode(check["receipt_json"]) do
      {:ok, candidate}
    else
      {:ok, _} -> {:error, :controller_writer_check_failed}
      {:error, _} = error -> error
    end
  end

  defp verifier_controller_check(_store, _run, _evidence, %{"status" => status}) when status != "PASS", do: :ok

  defp verifier_controller_check(store, run, evidence, %{"status" => "PASS"}) do
    with {:ok, check} <- check(store, evidence["request_key"], "git-diff-check"),
         true <- check["phase"] == "COMPLETE" or {:error, :controller_verifier_check_incomplete},
         {:ok, %{"result" => "PASS", "candidate_sha" => sha}} <- Jason.decode(check["receipt_json"]),
         {:ok, binding} when is_map(binding) <- Jason.decode(check["binding_json"]),
         true <-
           {sha, Map.take(binding, ~w(run_id candidate_sha spec_revision contract_sha256))} ==
             {run["candidate_sha"], Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256))} or
             {:error, :controller_verifier_check_binding_mismatch},
         :ok <- WorkerEvidence.checks_stopped(store, evidence["reservation_key"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :controller_verifier_check_failed}
    end
  end

  defp writer_candidate(run, evidence, %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil}) do
    parent = Jason.decode!(evidence["binding_json"])["expected_sha"]

    with true <- (is_binary(run["candidate_sha"]) and run["candidate_sha"] == parent) or {:error, :writer_candidate_missing} do
      case Worktree.candidate(run["worktree"], run["base_branch"]) do
        {:ok, ^parent} -> {:ok, parent}
        _ -> {:error, :writer_candidate_mismatch}
      end
    end
  end

  defp writer_candidate(run, evidence, %{"status" => status, "changed_paths" => paths, "commit_message" => message})
       when status in ~w(CONTINUE COMPLETE) do
    parent = Jason.decode!(evidence["binding_json"])["expected_sha"]
    route = %{"path" => run["repo_path"]}

    with {:ok, %{sha: candidate}} <- Worktree.commit_native_slice(route, run["worktree"], run["branch"], parent, paths, message),
         {:ok, ^candidate} <- Worktree.candidate(run["worktree"], run["base_branch"]) do
      {:ok, candidate}
    end
  end

  defp writer_candidate(_run, _evidence, _output), do: {:error, :ticket_writer_blocked}

  defp persist_writer_candidate(store, run, evidence, candidate) do
    SymphonyElixir.Factory.TicketPushHazard.with_descendant(store, run["run_id"], candidate, fn tx ->
      {:ok, current} = RunLedger.get(tx, run["run_id"])
      parent = Jason.decode!(evidence["binding_json"])["expected_sha"]
      fields = ~w(state implementation_iteration spec_revision contract_sha256 worktree branch)

      cond do
        Map.take(current, fields) != Map.take(run, fields) or current["candidate_sha"] not in [parent, nil, candidate] ->
          {:error, :ticket_writer_adoption_changed}

        current["candidate_sha"] == candidate ->
          :ok

        true ->
          {:ok, _} = RunLedger.update(tx, run["run_id"], %{candidate_sha: candidate})
          :ok
      end
    end)
  end

  @doc "Runs only a controller-selected catalog action; recovery reads the same durable invocation."
  @spec check(Store.connection(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def check(store, worker_request, action) do
    with {:ok, row} <- WorkerEvidence.prepare_check(store, worker_request, action) do
      case row["phase"] do
        "COMPLETE" -> {:ok, row}
        "PREPARED" -> execute_check(store, row)
        _ -> reconcile_check(store, row)
      end
    end
  end

  defp execute_check(store, row) do
    started = fn pid -> WorkerEvidence.start_check(store, row["check_key"], pid) end

    case WorkerCheckIO.execute(row, started) do
      {:ok, raw} -> finish_check(store, row, raw)
      {:error, {:controller_check_not_started, reason}} -> {:error, reason}
      {:error, :controller_check_already_started} -> {:error, :controller_check_in_progress}
      {:error, reason} -> WorkerEvidence.uncertain_check(store, row["check_key"], reason)
    end
  end

  defp reconcile_check(store, row) do
    case WorkerCheckIO.readback(row) do
      {:ok, raw} -> finish_check(store, row, raw)
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_check(store, row, raw) do
    case WorkerEvidence.finish_check(store, row["check_key"], raw) do
      {:ok, _} = result -> result
      {:error, reason} -> WorkerEvidence.uncertain_check(store, row["check_key"], reason)
    end
  end

  @doc "Pins the controller-observed remote base once, before worker admission."
  @spec bind_base(Store.connection(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def bind_base(store, run_id, sha) do
    Store.transaction!(store, &bind_base_transaction(&1, run_id, sha))
  end

  @doc "Reads the existing remote-tracking base without fetching or changing refs."
  @spec observed_base(map()) :: {:ok, String.t()} | {:error, term()}
  def observed_base(%{"base_branch" => branch, "repo_path" => repo}) when is_binary(branch) and is_binary(repo),
    do: git_read(repo, ["rev-parse", "--verify", "refs/remotes/origin/" <> branch <> "^{commit}"])

  def observed_base(_run), do: {:error, :ticket_review_base_missing}

  defp bind_base_transaction(store, run_id, sha) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- is_binary(run["base_branch"]) or {:error, :ticket_review_base_missing},
         ref = "refs/remotes/origin/" <> run["base_branch"],
         {:ok, observed} <- git_read(run["repo_path"], ["rev-parse", "--verify", ref <> "^{commit}"]),
         true <- observed == sha or {:error, :ticket_review_base_mismatch} do
      persist_base(store, run_id, ref, sha)
    end
  end

  defp persist_base(store, run_id, ref, sha) do
    existing = Store.one!(store, "SELECT * FROM ticket_review_bases WHERE run_id = ?", [run_id])

    cond do
      existing == nil ->
        Store.query!(store, "INSERT INTO ticket_review_bases(run_id, base_ref, base_sha, bound_at) VALUES (?, ?, ?, ?)", [run_id, ref, sha, DateTime.utc_now() |> DateTime.to_iso8601()])
        {:ok, Store.one!(store, "SELECT * FROM ticket_review_bases WHERE run_id = ?", [run_id])}

      existing["base_sha"] == sha and existing["base_ref"] == ref ->
        {:ok, existing}

      true ->
        {:error, :ticket_review_base_immutable}
    end
  end

  @doc "Admits immutable instructions for the current exact packet; may append one snapshot, never launch a worker."
  @spec packet(Store.connection(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def packet(store, run_id, role, base_sha) do
    Store.transaction!(store, &instruction_packet(&1, run_id, role, base_sha, :admit))
  end

  @doc "Revalidates current packet facts using admitted instruction bytes only; never reads shared files or writes snapshots."
  @spec read_packet(Store.connection(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_packet(store, run_id, role, base_sha) do
    instruction_packet(store, run_id, role, base_sha, :read)
  end

  @doc "Revalidates facts and reuses predecessor-admitted bytes without admitting or authorizing a turn."
  @spec retained_packet(Store.connection(), binary(), binary(), binary(), map()) :: {:ok, binary()} | {:error, term()}
  def retained_packet(store, run_id, role, base_sha, predecessor) do
    instruction_packet(store, run_id, role, base_sha, {:retained, predecessor})
  end

  defp instruction_packet(store, run_id, role, base_sha, mode) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- role in ~w(feature-writer feature-planner change-verifier manual-validator) or {:error, :ticket_worker_role_unsupported},
         :ok <- exact_contract(run),
         :ok <- validator_candidate(role, run["candidate_sha"]),
         :ok <- proven_base(store, run, base_sha) do
      packet = %{
        "run_id" => run_id,
        "stage" => instruction_stage(role, run["state"]),
        "implementation_iteration" => run["implementation_iteration"],
        "code_repair_round" => run["code_repair_round"],
        "validation_repair_round" => run["validation_repair_round"],
        "verifier_round" => run["verifier_round"],
        "instruction_bundle_version" => 1,
        "role" => role,
        "issue_key" => run["issue_key"],
        "spec_revision" => run["spec_revision"],
        "contract_sha256" => run["contract_sha256"],
        "contract" => run["contract_markdown"],
        "jira_snapshot" => run["snapshot_json"],
        "base_sha" => base_sha,
        "candidate_sha" => run["candidate_sha"],
        "tools" =>
          "Local source inspection and commands only. Use /Library/Developer/CommandLineTools/usr/bin/git for read-only Git inspection, not /usr/bin/git or an ambient alias. No connectors, delegation, permission changes, Git writes, pushes or merge requests. Return the supplied structured result."
      }

      packet =
        if role == "feature-writer",
          do:
            Map.merge(packet, %{
              "plan" => run["plan_markdown"],
              "repair_findings" => run["repair_findings_json"],
              "output_rules" => %{
                "changed_slice" => "For CONTINUE or COMPLETE with changed_paths, commit_message must be a nonempty conventional message for the controller; never null.",
                "commit_message" => "One line, at most 120 UTF-8 bytes, formatted as feat(#{run["issue_key"]}): short summary (or fix, chore, refactor, test, docs, perf).",
                "no_edit_completion" => "For no-edit completion, use COMPLETE, changed_paths [], and commit_message null; preserve the existing candidate.",
                "blocked" => "For BLOCKED, report actual changed_paths and blockers; commit_message may be null. Never claim a completed slice."
              },
              "tools" =>
                "Use repo_list and repo_read to inspect this checkout, repo_write with its exact file SHA-256 to edit the smallest authorized slice, repo_delete with its exact SHA-256 to remove a regular source file, and repo_mkdir to create one directory under an existing parent. Use repo_read_binary/repo_write_binary for bounded canonical-base64 fixtures. To read exact preimages from this task's pinned contract base, use repo_read or repo_read_binary with path .symphony-base/<relative-path>; this is a read-only virtual namespace, not a physical directory, and accepts no revision argument. Before restoring a preimage, read its ordinary current path and use that current SHA for write CAS, never the historical SHA. Never write to .symphony-base/. Your process is read-only: no native patch or shell, connectors, delegation, permission changes or Git writes. Controller alone runs approved checks, commits, pushes and manages MRs. Report all unrun checks honestly; file edits are not verification."
            }),
          else: packet

      with {:ok, packet} <- ci_repair_packet(store, run, packet, role),
           {:ok, packet} <- validation_packet(store, packet, run, role),
           {:ok, packet} <- SymphonyElixir.Factory.RepairObligations.attach(store, packet),
           packet = TicketCompletionConfirmation.attach(store, packet),
           {:ok, packet} <- shared_instructions(store, packet, role, mode, run) do
        {:ok, Jason.encode!(packet)}
      end
    end
  end

  defp ci_repair_packet(store, run, packet, "feature-writer") do
    with {:ok, repair} <- SymphonyElixir.Factory.TicketCiRepair.writer_packet(store, run),
         {:ok, packet} <- SymphonyElixir.Factory.TicketCiRepairSuccessor.supplemental_packet(store, run, if(is_nil(repair), do: packet, else: Map.put(packet, "ci_repair", repair))),
         {:ok, scope} <- TicketCiRepair.writer_scope(store, run) do
      TicketCiGeneratedScope.attach(packet, scope)
    end
  end

  defp ci_repair_packet(_store, _run, packet, _role), do: {:ok, packet}

  defp instruction_stage("feature-writer", "READY_FOR_REVIEW"), do: "REVIEW_WRITING"
  defp instruction_stage(_role, state), do: state

  defp shared_instructions(store, packet, role, mode, run) do
    instruction_role = if role == "feature-writer" and is_map(packet["ci_repair"]), do: "ci-repair-writer", else: role

    result =
      case mode do
        :admit -> admit_instructions(store, packet, instruction_role, run)
        :read -> WorkerInstructions.read(store, packet, instruction_role)
        {:retained, predecessor} -> retained_instructions(store, packet, instruction_role, predecessor)
      end

    with {:ok, instructions} <- result do
      {:ok, Map.merge(packet, instructions)}
    end
  end

  defp admit_instructions(store, packet, role, run) do
    case WorkerInstructions.admit(store, packet, role, Path.join(System.user_home!(), ".agents")) do
      {:error, :worker_instruction_snapshot_not_admitted} -> inherit_amendment_instructions(store, packet, role, run)
      result -> result
    end
  end

  defp retained_instructions(store, packet, role, predecessor) do
    with true <- predecessor["run_id"] == packet["run_id"] and predecessor["role"] == packet["role"],
         {:ok, mapping} <- WorkerInstructions.task_binding(store, predecessor),
         row when is_map(row) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(row["binding_json"]) == mapping["instruction_binding_sha256"],
         {:ok, retained} <- Jason.decode(row["binding_json"]),
         true <- Map.drop(retained, ["tools"]) == Map.drop(packet, ["tools"]),
         {:ok, bundle} <- WorkerInstructions.read(store, retained, role) do
      {:ok, Map.merge(retained, bundle)}
    else
      _ -> {:error, :worker_instruction_retained_packet_unproven}
    end
  end

  defp inherit_amendment_instructions(store, packet, "feature-writer", run) do
    with {:ok, predecessor_proof} <- TicketContractAmendment.blocked_predecessor_for_installed_run(store, run),
         %{receipt: receipt, amendment: amendment} = predecessor_proof,
         :ok <- WorkspaceAccess.validate_blocked_amendment_predecessor(store, receipt),
         {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, task} <- Jason.decode(predecessor["task_json"]),
         {:ok, prior} <- TicketContractAmendment.blocked_source_preimage(store, amendment["command_key"]) do
      expected = Map.take(prior, ~w(run_id spec_revision contract_sha256 candidate_sha)) |> Map.merge(%{"role" => "feature-writer", "base_sha" => packet["base_sha"]})
      WorkerInstructions.inherit(store, packet, "feature-writer", task, expected)
    else
      _ -> {:error, :worker_instruction_snapshot_not_admitted}
    end
  end

  defp inherit_amendment_instructions(_store, _packet, _role, _run), do: {:error, :worker_instruction_snapshot_not_admitted}

  @doc false
  @spec blocked_resume_packet(String.t(), String.t(), map()) :: String.t()
  def blocked_resume_packet(base_packet, native_body, disposition) do
    Jason.encode!(%{
      "base_packet" => Jason.decode!(base_packet),
      "explicit_native_rework" => native_body,
      "blocked_writer_context" => disposition
    })
  end

  defp validation_packet(_store, packet, run, "manual-validator") do
    case Contract.manual_validation_definition(run["contract_markdown"]) do
      {:ok, nil} -> {:error, :manual_validation_not_required}
      {:ok, definition} -> {:ok, Map.merge(packet, %{"validation_definition" => definition, "validation_evidence" => "DECLARATIONS_ONLY"})}
      {:error, _} = error -> error
    end
  end

  defp validation_packet(store, packet, %{"ci_evidence_json" => json} = run, "change-verifier") when is_binary(json) do
    candidate = run["candidate_sha"]
    preflight = run["ci_preflight_sha"]
    pipeline_id = run["ci_pipeline_id"]

    case Jason.decode(json) do
      {:ok, %{"status" => "PASS", "sha" => sha, "pipeline_id" => pipeline} = evidence}
      when is_integer(pipeline) and pipeline > 0 and sha == candidate and sha == preflight and pipeline == pipeline_id ->
        {:ok, Map.put(packet, "ci_evidence", evidence)}

      {:ok, %{"status" => "PASS", "sha" => sha, "pipeline_id" => pipeline}}
      when is_binary(sha) and sha == preflight and sha != candidate and is_integer(pipeline) and pipeline > 0 and pipeline == pipeline_id ->
        with true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
             :ok <- ordinary_writer_candidate(store, run) do
          {:ok, packet}
        else
          _ -> {:error, :ticket_verifier_ci_evidence_mismatch}
        end

      _ ->
        {:error, :ticket_verifier_ci_evidence_mismatch}
    end
  end

  defp validation_packet(_store, packet, _run, _role), do: {:ok, packet}

  defp ordinary_writer_candidate(store, run) do
    key = run["run_id"] <> ":feature-writer"

    with {:ok, task} <- TaskLedger.get(store, key),
         true <- task["run_id"] == run["run_id"] and task["role"] == "feature-writer" and task["status"] == "CONSUMED" and task["stage"] in ~w(WRITING REVIEW_WRITING),
         worker when is_map(worker) <-
           Store.one!(store, "SELECT * FROM worker_evidence WHERE task_key=? AND run_id=? AND thread_id=? AND turn_id=? AND output_json=? AND status='CONSUMED'", [
             key,
             run["run_id"],
             task["thread_id"],
             task["turn_id"],
             task["output_json"]
           ]),
         {:ok, bound} <- retained_object(worker["binding_json"], worker["binding_sha256"]),
         {:ok, %{"status" => "COMPLETE"}} <- retained_object(worker["output_json"], worker["output_sha256"]),
         true <- Map.take(bound, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         true <- Map.take(bound, ~w(task_key role stage model reasoning_effort prompt_sha256)) == Map.take(task, ~w(task_key role stage model reasoning_effort prompt_sha256)),
         true <- bound["mode"] == "SOURCE" and bound["input_sha256"] == task["prompt_sha256"] and is_map(bound["policy"]) and bound["policy"]["cwd"] == run["worktree"],
         true <- WorkerEvidence.owner_stopped?(store, worker),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         {:ok, original} <- retained_object(snapshot["binding_json"], mapping["instruction_binding_sha256"]),
         {:ok, _} <- WorkerInstructions.read(store, original, "feature-writer"),
         true <- Map.take(original, ~w(run_id spec_revision contract_sha256 role stage)) == Map.take(bound, ~w(run_id spec_revision contract_sha256 role stage)),
         true <- original["candidate_sha"] == bound["expected_sha"] and not Map.has_key?(original, "ci_repair"),
         :ok <- ordinary_writer_check(store, run, worker, bound) do
      :ok
    else
      _ -> {:error, :ticket_verifier_ci_evidence_mismatch}
    end
  end

  defp ordinary_writer_check(store, run, worker, bound) do
    with access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [worker["reservation_key"]]),
         true <- bound["reservation_key"] == worker["reservation_key"] and bound["reservation_key"] == access["reservation_key"],
         true <-
           access["mode"] == "SOURCE" and access["run_id"] == run["run_id"] and access["task_key"] == worker["task_key"] and access["request_key"] == worker["request_key"] and
             access["generation"] == bound["reservation_generation"] and access["canonical_path"] == run["worktree"] and is_binary(access["released_at"]),
         {:ok, release} when is_map(release) <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- release == Map.take(worker, ~w(request_key binding_sha256 output_sha256 consumed_at owner_stopped_at)),
         :ok <- WorkerEvidence.checks_stopped(store, access["reservation_key"]),
         check when is_map(check) <-
           Store.one!(store, "SELECT * FROM controller_checks WHERE worker_request_key=? AND reservation_key=? AND phase='COMPLETE' AND json_extract(binding_json,'$.action')='git-diff-check'", [
             worker["request_key"],
             access["reservation_key"]
           ]),
         {:ok, binding} <- retained_object(check["binding_json"], check["binding_sha256"]),
         {:ok, receipt} <- retained_object(check["receipt_json"], check["receipt_sha256"]),
         true <- Map.take(binding, ~w(run_id candidate_sha spec_revision contract_sha256)) == Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256)),
         true <-
           binding["worker_request_key"] == worker["request_key"] and binding["worker_binding_sha256"] == worker["binding_sha256"] and binding["worker_output_sha256"] == worker["output_sha256"] and
             binding["worker_stop_sha256"] == digest(worker["owner_stop_json"]),
         true <-
           binding["reservation_key"] == access["reservation_key"] and binding["generation"] == access["generation"] and binding["workspace_binding_sha256"] == digest(access["binding_json"]) and
             binding["cwd"] == run["worktree"],
         true <- receipt["result"] == "PASS" and receipt["candidate_sha"] == run["candidate_sha"] do
      :ok
    else
      _ -> {:error, :ticket_verifier_ci_evidence_mismatch}
    end
  end

  defp retained_object(raw, sha) when is_binary(raw) and byte_size(raw) <= 2_097_152 do
    with true <- digest(raw) == sha, {:ok, value} when is_map(value) <- Jason.decode(raw), do: {:ok, value}
  end

  defp retained_object(_, _), do: {:error, :retained_object_unproven}

  defp validator_candidate("manual-validator", nil), do: {:error, :manual_validation_candidate_missing}

  defp validator_candidate("manual-validator", candidate_sha) do
    if is_binary(candidate_sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, candidate_sha),
      do: :ok,
      else: {:error, :manual_validation_candidate_invalid}
  end

  defp validator_candidate(_role, _candidate_sha), do: :ok

  defp proven_base(store, run, sha) do
    pin = Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])

    with true <- (is_binary(sha) and (pin || %{})["base_sha"] == sha) or {:error, :ticket_review_base_missing},
         {:ok, ^sha} <- git_read(run["repo_path"], ["rev-parse", "--verify", sha <> "^{commit}"]),
         :ok <- base_ancestor(run, sha) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_review_base_mismatch}
    end
  end

  defp base_ancestor(%{"candidate_sha" => nil}, _sha), do: :ok

  defp base_ancestor(run, sha) do
    case git_read(run["repo_path"], ["merge-base", "--is-ancestor", sha, run["candidate_sha"]]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :ticket_review_base_not_ancestor}
    end
  end

  defp git_read(path, args) when is_binary(path) do
    case System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", path | args], stderr_to_stdout: true, env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]) do
      {result, 0} -> {:ok, String.trim(result)}
      {_result, status} -> {:error, {:ticket_git_read_failed, status}}
    end
  end

  defp git_read(_path, _args), do: {:error, :ticket_review_repository_missing}

  @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, %Issue{} = issue, prompt, schema, opts) do
    store = Keyword.fetch!(opts, :store)
    task_key = Keyword.fetch!(opts, :target_key)
    key = Keyword.fetch!(opts, :request_key)

    with {:ok, task} <- TaskLedger.get(store, task_key),
         {:ok, run} <- RunLedger.get(store, task["run_id"]),
         {:ok, chat} <- TicketChat.for_run(store, run["run_id"]),
         :ok <- prerequisites(run, task, chat, issue, workspace, prompt, opts),
         :ok <- ReviewProtocol.validate_admission(prompt, schema),
         {:ok, access} <- WorkspaceAccess.get(store, Keyword.fetch!(opts, :reservation_key)),
         {:ok, _} <- WorkspaceAccess.validate(store, access["reservation_key"], access["generation"]),
         true <- access["mode"] == if(task["role"] == "feature-writer", do: "SOURCE", else: "REVIEW") or {:error, :ticket_worker_access_mismatch},
         {:ok, resume} <- resume_writer(store, task, opts),
         policy = policy(access["mode"], access["canonical_path"]),
         :ok <- SymphonyElixir.Factory.TicketCiRepairSuccessor.issuance_check(store, run, opts),
         {:ok, attempt} <-
           WorkerEvidence.reserve(store, %{
             "request_key" => key,
             "task_key" => task_key,
             "reservation_key" => access["reservation_key"],
             "input_sha256" => digest(prompt),
             "owner_id" => Keyword.fetch!(opts, :owner_id),
             "schema" => schema,
             "policy" => policy
           }),
         {:ok, _} <- WorkerEvidence.mark_start_sent(store, key) do
      execute(store, attempt, policy, issue, prompt, schema, Keyword.put(opts, :resume_thread_id, resume))
    end
  end

  defp prerequisites(run, task, chat, issue, workspace, prompt, opts) do
    with :ok <- bound_route(Keyword.fetch!(opts, :store), run, chat),
         :ok <- scoped_input(run, task, issue, workspace, prompt, opts),
         :ok <- role_input(run, task, prompt, opts) do
      exact_contract(run)
    end
  end

  defp bound_route(store, run, chat) do
    valid = {run["execution_mode"], chat["route"]} == {"TICKET_SUPERVISOR_V1", "desktop_owned_ticket_chat_v1"}

    if valid and is_binary(chat["thread_id"]) do
      case TicketChat.ready_for_run(store, run["run_id"]) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :ticket_worker_route_not_bound}
    end
  end

  defp scoped_input(run, task, issue, workspace, prompt, opts) do
    scope = {issue.identifier, workspace, workspace}
    expected_scope = {run["issue_key"], task["workspace"], run["worktree"]}
    input = {digest(prompt), opts[:model], opts[:reasoning_effort]}
    expected_input = {task["prompt_sha256"], task["model"], task["reasoning_effort"]}

    cond do
      scope != expected_scope -> {:error, :ticket_worker_scope_mismatch}
      input != expected_input -> {:error, :ticket_worker_input_mismatch}
      true -> :ok
    end
  end

  defp role_input(run, %{"role" => "feature-writer"} = task, prompt, opts),
    do: packet_for_review(run, task, prompt, opts)

  defp role_input(run, %{"role" => role} = task, prompt, opts) when role in ~w(change-verifier feature-planner) do
    cond do
      is_binary(task["thread_id"]) -> {:error, :ticket_review_worker_must_be_fresh}
      packet_for_review(run, task, prompt, opts) != :ok -> {:error, :ticket_worker_blind_packet_mismatch}
      true -> :ok
    end
  end

  defp role_input(_run, %{"role" => "manual-validator"}, _prompt, _opts), do: {:error, :ticket_validator_authorized_transport_required}
  defp role_input(_run, _task, _prompt, _opts), do: {:error, :ticket_worker_role_unsupported}

  defp packet_for_review(run, task, prompt, opts) do
    if is_map(opts[:failed_turn_recovery]) do
      with {:ok, base} <- read_packet(Keyword.fetch!(opts, :store), run["run_id"], task["role"], opts[:review_base_sha]),
           {:ok, receipt} <- SymphonyElixir.Factory.FailedTurnRecovery.prepared(Keyword.fetch!(opts, :store), run["run_id"], base),
           true <- receipt == opts[:failed_turn_recovery] and prompt == receipt["prompt"] do
        :ok
      else
        _ -> {:error, :failed_retry_packet_changed}
      end
    else
      packet_without_failed_recovery(run, task, prompt, opts)
    end
  end

  defp packet_without_failed_recovery(run, task, prompt, opts) do
    case {opts[:ready_rework], opts[:blocked_resume_prompt], task["role"]} do
      {%{command_key: command_key}, nil, "feature-writer"} ->
        with {:ok, %{receipt: receipt, input: input}} <-
               TicketChatCommands.validate_ready_rework_replay(Keyword.fetch!(opts, :store), command_key),
             {:ok, base_packet} <- read_packet(Keyword.fetch!(opts, :store), run["run_id"], task["role"], opts[:review_base_sha]),
             expected = ready_rework_packet(base_packet, command_key, input["body"]),
             true <-
               (receipt["request_key"] == opts[:request_key] and expected == prompt) or
                 {:error, :ready_rework_packet_mismatch} do
          :ok
        end

      {nil, ^prompt, "feature-writer"} ->
        :ok

      {nil, nil, _} ->
        if(read_packet(Keyword.fetch!(opts, :store), run["run_id"], task["role"], opts[:review_base_sha]) == {:ok, prompt}, do: :ok, else: {:error, :blind_packet_required})

      _ ->
        {:error, :blocked_resume_packet_mismatch}
    end
  end

  defp resume_writer(_store, %{"thread_id" => nil}, _opts), do: {:ok, nil}

  defp resume_writer(store, task, opts) do
    if is_map(opts[:failed_turn_recovery]), do: resume_failed_writer(store, task, opts), else: resume_completed_writer(store, task, opts)
  end

  defp resume_failed_writer(store, task, opts) do
    receipt = opts[:failed_turn_recovery]

    with :ok <- SymphonyElixir.Factory.FailedTurnRecovery.start_preflight(store, receipt, opts),
         true <- (receipt["new_request_key"] == opts[:request_key] and receipt["thread_id"] == task["thread_id"]) or {:error, :failed_retry_binding_changed} do
      {:ok, task["thread_id"]}
    end
  end

  defp resume_completed_writer(store, task, opts) do
    previous =
      Store.one!(
        store,
        "SELECT * FROM worker_evidence WHERE task_key = ? AND thread_id = ? AND status IN ('CONSUMED', 'RESULT_RECORDED') AND owner_stopped_at IS NOT NULL ORDER BY created_at DESC LIMIT 1",
        [
          task["task_key"],
          task["thread_id"]
        ]
      )

    valid =
      previous != nil and WorkerEvidence.owner_stopped?(store, previous) and digest(previous["binding_json"]) == previous["binding_sha256"] and
        digest(previous["output_json"]) == previous["output_sha256"] and resume_policy_matches?(previous, task) and
        (previous["status"] == "CONSUMED" or blocked_transfer_matches?(store, previous, opts) or SymphonyElixir.Factory.TicketCiRepairSuccessor.resume_matches?(store, previous, opts))

    if valid,
      do: {:ok, previous["thread_id"]},
      else: {:error, :ticket_worker_resume_unproven}
  end

  defp blocked_transfer_matches?(store, previous, opts) do
    resume = opts[:blocked_resume] || %{}
    access = Store.one!(store, "SELECT release_receipt_json FROM workspace_access WHERE reservation_key = ?", [previous["reservation_key"]])

    with {:ok, transfer} <- Jason.decode((access || %{})["release_receipt_json"] || "null") do
      transfer_matches?(transfer, previous, resume, opts) and blocked_application_matches?(store, previous, resume, opts)
    else
      _ -> false
    end
  end

  defp blocked_application_matches?(store, previous, %{"operational_recovery_key" => "TCAP-" <> _ = key}, opts) do
    case TicketCapabilityRecovery.applied(store, key) do
      {:ok, application} ->
        application["prior_request_key"] == previous["request_key"] and application["request_key"] == opts[:request_key] and application["output_sha256"] == previous["output_sha256"]

      _ ->
        false
    end
  end

  defp blocked_application_matches?(store, previous, %{"operational_recovery_key" => key}, opts) when is_binary(key) do
    case SymphonyElixir.Factory.TicketInfrastructureRecovery.applied(store, key) do
      {:ok, application} ->
        application["prior_request_key"] == previous["request_key"] and application["request_key"] == opts[:request_key] and application["output_sha256"] == previous["output_sha256"]

      _ ->
        false
    end
  end

  defp blocked_application_matches?(store, previous, resume, opts) do
    with {:ok, command} <- TicketChatCommands.get(store, resume["command_key"]),
         true <- command["status"] == "APPLIED",
         {:ok, application} <- Jason.decode(command["application_receipt_json"] || "null") do
      application_matches?(application, previous, opts)
    else
      _ -> false
    end
  end

  defp transfer_matches?(transfer, previous, resume, opts) do
    transfer["kind"] == "BLOCKED_SOURCE_TRANSFER" and transfer["old_request_key"] == previous["request_key"] and
      transfer["new_request_key"] == opts[:request_key] and transfer["new_reservation_key"] == opts[:reservation_key] and
      transfer["disposition_key"] == resume["disposition_key"]
  end

  defp application_matches?(application, previous, opts) do
    application["kind"] == "BLOCKED_WRITER_RESUMED" and application["prior_request_key"] == previous["request_key"] and
      application["request_key"] == opts[:request_key] and application["output_sha256"] == previous["output_sha256"]
  end

  defp resume_policy_matches?(previous, task) do
    case Jason.decode(previous["binding_json"]) do
      {:ok, %{"policy" => prior}} -> prior == policy("SOURCE", task["workspace"])
      _ -> false
    end
  end

  defp execute(store, attempt, policy, issue, prompt, schema, opts) do
    key = attempt["request_key"]
    downstream = opts[:on_thread_started]

    on_thread = fn thread ->
      require_resumed_thread!(thread, opts[:resume_thread_id])

      {:ok, _} = WorkerEvidence.bind_thread(store, key, thread, policy)
      if is_function(downstream, 1), do: downstream.(thread)
    end

    on_message = fn
      %{event: :session_started, thread_id: thread, turn_id: turn} ->
        {:ok, _} = WorkerEvidence.bind_turn(store, key, thread, turn)

      message ->
        SpecialistErrorNotice.observe(store, key, message)
        :ok
    end

    on_ready = fn session ->
      true = session.worker_policy == policy
      require_resumed_thread!(session.thread_id, opts[:resume_thread_id])
      process = %{"pid" => session.metadata.codex_app_server_pid, "invocation_nonce" => session.worker_invocation}
      {:ok, _} = WorkerEvidence.bind_owner_process(store, key, process)
    end

    runner_opts = [
      app_server: Keyword.get(opts, :app_server, AppServer),
      event_scope: :exact_turn,
      worker_access: policy["mode"],
      include_evidence: true,
      model: opts[:model],
      reasoning_effort: opts[:reasoning_effort],
      resume_thread_id: opts[:resume_thread_id],
      on_thread_started: on_thread,
      on_session_ready: on_ready,
      on_message: on_message,
      thread_name: opts[:thread_name],
      thread_source: "symphonyTicketWorker",
      service_name: "symphony-ticket-worker",
      blocked_resume_prompt: opts[:blocked_resume_prompt],
      ready_rework: opts[:ready_rework]
    ]

    runner_opts =
      if guarded_failed_recovery?(opts[:failed_turn_recovery]) do
        Keyword.merge(runner_opts,
          native_recovery: opts[:failed_turn_recovery],
          recovery_preflight: fn session -> SymphonyElixir.Factory.FailedTurnRecovery.owned_session_preflight(store, opts[:failed_turn_recovery], session, opts) end
        )
      else
        runner_opts
      end

    runner_opts = capability_runner_options(runner_opts, store, opts)

    runner_opts =
      if policy["mode"] == "FILE_SOURCE" do
        {:ok, files} = WorkerFileTools.bind(store, key, attempt["owner_id"])
        Keyword.put(runner_opts, :worker_files, files)
      else
        runner_opts
      end

    result = StageRunner.run(policy["cwd"], issue, prompt, schema, runner_opts)

    case result do
      {:error, {:worker_failed, reason, observed}} ->
        WorkerEvidence.reconcile_required(store, key, reason, observed)
        {:error, reason}

      {:ok, observed} ->
        finish_result(store, attempt, observed)

      {:error, {:worker_shutdown_unproven, stopped, observed}} = error ->
        if observed.policy == policy, do: WorkerEvidence.record_result(store, key, observed)
        WorkerEvidence.reconcile_required(store, key, {:worker_shutdown_unproven, stopped})
        error

      {:error, reason} = error ->
        WorkerEvidence.reconcile_required(store, key, reason)
        error
    end
  rescue
    exception ->
      WorkerEvidence.reconcile_required(store, attempt["request_key"], Exception.message(exception))
      {:error, :worker_observation_failed}
  end

  defp guarded_failed_recovery?(%{"kind" => "INTERRUPTED_TURN_QUIESCENCE"}), do: true
  defp guarded_failed_recovery?(%{"schema_confirmation" => %{"kind" => "SOURCE_COMPLETION_SCHEMA_REJECTION_V1"}}), do: true
  defp guarded_failed_recovery?(_), do: false

  defp capability_runner_options(runner_opts, store, opts) do
    case opts[:blocked_resume] do
      %{"operational_recovery_key" => "TCAP-" <> _} = resume ->
        preflight = &TicketCapabilityRecovery.owned_session_preflight(store, resume, &1, opts)

        Keyword.merge(runner_opts,
          native_recovery: resume,
          recovery_preflight: preflight
        )

      _ ->
        runner_opts
    end
  end

  defp require_resumed_thread!(_observed, nil), do: :ok
  defp require_resumed_thread!(expected, expected), do: :ok
  defp require_resumed_thread!(_observed, _expected), do: raise("resumed ticket worker opened a different thread")

  defp finish_result(store, attempt, observed) do
    key = attempt["request_key"]

    result =
      with {:ok, _} <- WorkerEvidence.record_result(store, key, observed),
           {:ok, receipt} <- WorkerEvidence.record_owner_stopped(store, key, attempt["owner_id"], observed.owner_stop) do
        {:ok, Map.put(observed, :worker_request_key, receipt["request_key"])}
      end

    case result do
      {:error, reason} ->
        WorkerEvidence.reconcile_required(store, key, reason)
        result

      success ->
        success
    end
  end

  defp exact_contract(run) do
    if is_binary(run["contract_markdown"]) and is_integer(run["spec_revision"]) and Contract.bind(run["issue_key"], run["spec_revision"], run["contract_markdown"]).sha256 == run["contract_sha256"],
      do: :ok,
      else: {:error, :ticket_worker_contract_unproven}
  end

  @doc false
  @spec policy(String.t(), Path.t()) :: map()
  def policy("SOURCE", workspace), do: AppServer.worker_policy("FILE_SOURCE", workspace)
  @spec policy(String.t(), Path.t()) :: map()
  def policy(mode, workspace), do: AppServer.worker_policy(mode, workspace)

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
