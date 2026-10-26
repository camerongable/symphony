defmodule SymphonyElixir.Factory.TicketPush do
  @moduledoc "Once-only controller push, retained source ownership and exact stopped-process recovery."
  alias SymphonyElixir.Factory.{
    RepairObligations,
    RunLedger,
    Store,
    TicketChat,
    TicketCiRepairSuccessor,
    TicketHumanEmptyCommitImport,
    TicketPushIO,
    TicketPushOrdinaryRejection,
    TicketPushPreissuanceRejection,
    TicketPushRequalification,
    TicketWorkerRunner,
    WorkspaceAccess,
    Worktree
  }

  @spec prepare(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%DBConnection{}, _run_id, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, run_id, authorization, opts) do
    prepare_transaction(store, run_id, authorization, opts)
  end

  defp prepare_transaction(store, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id) do
      case run["candidate_handoff"] do
        nil -> prepare_new(store, run, authorization, opts, nil)
        raw -> prepare_existing(store, run, raw, authorization, opts)
      end
    end
  end

  defp prepare_existing(store, run, raw, authorization, opts) do
    case Jason.decode(raw) do
      {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "UNISSUABLE"} = intent} ->
        with {:ok, proof} <- TicketPushIO.unissuable_v1_proof(intent),
             true <-
               (proof == intent["receipt_json"] and digest(proof) == intent["receipt_sha256"]) or
                 {:error, :ticket_push_disposition_changed},
             {:ok, access} <- WorkspaceAccess.get(store, intent["reservation_key"]),
             true <- (access["released_at"] != nil and access["release_receipt_json"] == raw) or {:error, :ticket_push_disposition_changed} do
          prepare_new(store, run, authorization, opts, raw)
        end

      {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = intent} ->
        with {:ok, _access} <- completed_history(store, run, raw, intent) do
          binding = Jason.decode!(intent["binding_json"])
          fields = ~w(run_id candidate_sha spec_revision contract_sha256 verifier_round)

          if Map.has_key?(binding, "verified_ci_rollover") and Map.take(binding, fields) == Map.take(run, fields),
            do: {:ok, intent},
            else: prepare_new(store, run, authorization, opts, raw)
        end

      {:ok, %{"kind" => "TICKET_PUSH_CAS_RECOVERY", "phase" => "COMPLETED", "binding_json" => encoded}} when is_binary(encoded) ->
        fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)

        with {:ok, binding} when is_map(binding) <- Jason.decode(encoded),
             prior = Map.merge(run, Map.take(binding, fields)),
             :ok <- validate_historical_completed_preimage(store, prior) do
          prepare_new(store, run, authorization, opts, raw)
        else
          {:error, _} = error -> error
          _ -> {:error, :ticket_push_history_unproven}
        end

      {:ok, %{"kind" => "HUMAN_EMPTY_COMMIT_IMPORT_V1", "binding_json" => encoded}} ->
        with {:ok, binding} <- Jason.decode(encoded),
             prior = Map.merge(run, Map.take(binding, ~w(candidate_sha verifier_round code_repair_round))),
             {:ok, _} <- TicketHumanEmptyCommitImport.historical_proof(store, prior) do
          prepare_new(store, run, authorization, opts, raw)
        end

      _ ->
        validate_existing(store, run, raw, authorization, opts)
    end
  end

  @doc "Reads the retained stopped push receipt for the current candidate and contract without mutations."
  @spec completed_proof(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def completed_proof(store, run_id) do
    with {:ok, run} <- RunLedger.get(store, run_id) do
      case Jason.decode(run["candidate_handoff"] || "null") do
        {:ok, %{"kind" => "TICKET_PUSH_CAS_RECOVERY"}} -> SymphonyElixir.Factory.TicketPushRecovery.completed_proof(store, run_id)
        {:ok, %{"kind" => "HUMAN_EMPTY_COMMIT_IMPORT_V1"}} -> TicketHumanEmptyCommitImport.completed_proof(store, run_id)
        _ -> ordinary_completed_proof(store, run_id)
      end
    end
  end

  defp ordinary_completed_proof(store, run_id) do
    fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)

    with {:ok, run} <- RunLedger.get(store, run_id),
         raw when is_binary(raw) <- run["candidate_handoff"],
         {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = intent} <- Jason.decode(raw),
         {:ok, access} <- completed_history(store, run, raw, intent),
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <- Map.take(binding, fields) == Map.take(run, fields) or {:error, :ticket_push_current_candidate_unproven} do
      proof =
        %{intent: intent, binding: binding, envelope: raw, envelope_sha256: digest(raw)}
        |> Map.put(:released_access, access)
        |> Map.put(:run, run)

      with :ok <- validate_completed_proof(store, run_id, proof), do: {:ok, proof}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_completion_unproven}
    end
  end

  @doc "Revalidates a call-local stopped-push proof against exact current ledger ownership; grants no delivery authority."
  @spec validate_completed_proof(Store.connection(), String.t(), map()) :: :ok | {:error, term()}
  def validate_completed_proof(store, run_id, %{intent: %{"kind" => "TICKET_PUSH_CAS_RECOVERY"}} = proof),
    do: SymphonyElixir.Factory.TicketPushRecovery.validate_completed_proof(store, run_id, proof)

  def validate_completed_proof(store, run_id, %{intent: %{"kind" => "HUMAN_EMPTY_COMMIT_IMPORT_V1"}} = proof),
    do: TicketHumanEmptyCommitImport.validate_completed_proof(store, run_id, proof)

  def validate_completed_proof(store, run_id, %{intent: intent, binding: binding, envelope: raw, envelope_sha256: sha, released_access: captured, run: expected}) do
    with true <- is_binary(raw),
         {:ok, run} <- RunLedger.get(store, run_id),
         true <- run == expected and run["candidate_handoff"] == raw,
         true <- digest(raw) == sha,
         {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = decoded} <- Jason.decode(raw),
         true <- decoded == intent,
         {:ok, historical, access} <- completed_history_binding(store, run, raw, decoded),
         true <- historical == binding and access == captured,
         fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round),
         true <- Map.take(historical, fields) == Map.take(run, fields),
         receipt when is_binary(receipt) <- decoded["receipt_json"],
         true <- digest(receipt) == decoded["receipt_sha256"],
         true <- TicketPushIO.receipt_valid?(receipt, decoded) do
      :ok
    else
      _ -> {:error, :ticket_push_proof_changed}
    end
  end

  def validate_completed_proof(_store, _run_id, _proof), do: {:error, :ticket_push_proof_unproven}

  @doc false
  @spec validate_historical_completed_preimage(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_historical_completed_preimage(store, run) do
    case Jason.decode(run["candidate_handoff"] || "null") do
      {:ok, %{"kind" => "TICKET_PUSH_CAS_RECOVERY", "phase" => "COMPLETED"}} ->
        SymphonyElixir.Factory.TicketPushRecovery.validate_historical_completed_preimage(store, run)

      {:ok, %{"kind" => "HUMAN_EMPTY_COMMIT_IMPORT_V1"}} ->
        case TicketHumanEmptyCommitImport.historical_proof(store, run) do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        ordinary_historical_completed_preimage(store, run)
    end
  end

  @doc false
  @spec observe_historical_completed_preimage(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def observe_historical_completed_preimage(%DBConnection{}, _prior), do: {:error, :workspace_observation_inside_transaction}

  def observe_historical_completed_preimage(store, prior) when is_map(prior) do
    case Jason.decode(prior["candidate_handoff"] || "null") do
      {:ok, %{"kind" => "TICKET_PUSH_CAS_RECOVERY"}} ->
        SymphonyElixir.Factory.TicketPushRecovery.observe_historical_completed_preimage(store, prior)

      {:ok, %{"kind" => "HUMAN_EMPTY_COMMIT_IMPORT_V1"}} ->
        with {:ok, current} <- RunLedger.get(store, prior["run_id"]),
             {:ok, imported} <- TicketHumanEmptyCommitImport.historical_proof(store, prior),
             {:ok, ^current} <- RunLedger.get(store, prior["run_id"]) do
          {:ok, %{kind: :human_empty_import, current: current, prior: prior, imported: imported, observed_at: System.monotonic_time(:millisecond)}}
        end

      {:ok, %{"kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = intent} ->
        started = System.monotonic_time(:millisecond)

        with {:ok, current} <- RunLedger.get(store, prior["run_id"]),
             :ok <- ordinary_historical_completed_preimage(store, prior),
             {:ok, binding, access} <- completed_history_binding(store, prior, prior["candidate_handoff"], intent),
             {:ok, ^current} <- RunLedger.get(store, prior["run_id"]) do
          {:ok, %{kind: :ordinary, prior: prior, current: current, intent: intent, binding: binding, access: access, observed_at: started}}
        end

      _ ->
        {:error, :ticket_push_history_unproven}
    end
  end

  def observe_historical_completed_preimage(_store, _prior), do: {:error, :ticket_push_history_unproven}

  @doc false
  @spec recheck_historical_completed_preimage(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def recheck_historical_completed_preimage(store, prior, %{kind: :cas} = proof),
    do: SymphonyElixir.Factory.TicketPushRecovery.recheck_historical_completed_preimage(store, prior, proof)

  def recheck_historical_completed_preimage(store, prior, %{kind: :human_empty_import, prior: prior, current: current, imported: imported, observed_at: at}) do
    with true <- (System.monotonic_time(:millisecond) - at) in 0..60_000,
         {:ok, ^current} <- RunLedger.get(store, prior["run_id"]),
         {:ok, ^imported} <- TicketHumanEmptyCommitImport.historical_proof(store, prior) do
      :ok
    else
      _ -> {:error, :empty_import_history_changed}
    end
  end

  def recheck_historical_completed_preimage(store, prior, %{kind: :ordinary, prior: prior, current: expected, intent: intent, binding: captured_binding, access: captured_access, observed_at: at}) do
    with true <- is_integer(at) and (System.monotonic_time(:millisecond) - at) in 0..60_000,
         {:ok, ^expected} <- RunLedger.get(store, prior["run_id"]),
         {:ok, ^intent} <- Jason.decode(prior["candidate_handoff"]),
         {:ok, ^captured_binding, ^captured_access} <- completed_history_binding(store, prior, prior["candidate_handoff"], intent),
         fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round),
         true <- Map.take(captured_binding, fields) == Map.take(prior, fields),
         receipt when is_binary(receipt) <- intent["receipt_json"],
         true <- digest(receipt) == intent["receipt_sha256"] and TicketPushIO.receipt_valid?(receipt, intent) do
      :ok
    else
      _ -> {:error, :ticket_push_history_changed}
    end
  end

  def recheck_historical_completed_preimage(_store, _prior, _proof), do: {:error, :ticket_push_history_unproven}

  defp ordinary_historical_completed_preimage(store, run) do
    raw = run["candidate_handoff"]

    with true <- is_binary(raw),
         {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = intent} <- Jason.decode(raw),
         {:ok, _access} <- completed_history(store, run, raw, intent),
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round),
         true <- Map.take(binding, fields) == Map.take(run, fields) or {:error, :ticket_push_history_unproven} do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_history_unproven}
    end
  end

  defp completed_history(store, run, raw, intent) do
    with {:ok, historical, access} <- completed_history_binding(store, run, raw, intent),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == historical["origin"],
         {:ok, receipt} <- TicketPushIO.readback(intent),
         true <- receipt == intent["receipt_json"] and digest(receipt) == intent["receipt_sha256"],
         true <- TicketPushIO.receipt_valid?(receipt, intent) do
      {:ok, access}
    else
      _ -> {:error, :ticket_push_history_unproven}
    end
  end

  defp completed_history_binding(store, run, raw, intent) do
    identity = ~w(run_id issue_key repo_path worktree branch base_branch)
    checkout_fields = ~w(path git_dir common_dir root_device root_inode)
    unfinished = Map.merge(intent, %{"receipt_json" => nil, "receipt_sha256" => nil, "remote_sha" => nil})

    with true <- valid_intent?(unfinished),
         {:ok, historical} when is_map(historical) <- Jason.decode(intent["binding_json"]),
         :ok <- TicketPushRequalification.current_binding(store, run, intent, historical),
         {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || "null"),
         true <- digest(intent["binding_json"]) == intent["binding_sha256"],
         true <- intent["reservation_key"] == "ticket-push:" <> intent["binding_sha256"],
         true <- Map.take(historical, identity) == Map.take(run, identity),
         true <- intent["remote_sha"] == historical["candidate_sha"],
         true <-
           {execution["run_id"], execution["intent_json"], execution["intent_sha256"], execution["invocation"]} ==
             {run["run_id"], intent["binding_json"], intent["binding_sha256"], intent["owner_nonce"]},
         {:ok, access} <- WorkspaceAccess.get(store, intent["reservation_key"]),
         true <-
           {access["generation"], access["run_id"], access["mode"], access["task_key"], access["request_key"]} ==
             {intent["reservation_generation"], run["run_id"], "MAINTENANCE", nil, intent["reservation_key"]},
         true <- not is_nil(access["released_at"]) and access["release_receipt_json"] == raw,
         {:ok, owned} when is_map(owned) <- Jason.decode(access["binding_json"]),
         checkout when is_map(checkout) <- historical["checkout"],
         true <- Map.take(checkout, checkout_fields) == Map.take(owned, checkout_fields),
         true <- owned["expected_sha"] == historical["candidate_sha"] do
      {:ok, historical, access}
    else
      _ -> {:error, :ticket_push_history_unproven}
    end
  end

  defp prepare_new(store, run, authorization, opts, previous) do
    with {:ok, plan} <- observe_preparation(store, run, authorization, opts, previous, nil) do
      WorkspaceAccess.acquire_with(store, plan.attrs, opts, fn tx, access ->
        with :ok <- recheck_preparation(tx, run, authorization, opts, plan, access) do
          store_preparation(tx, run, previous, plan, access, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
        end
      end)
    end
  end

  @doc false
  @spec observe_preparation(Store.connection(), map(), map(), keyword(), String.t() | nil, map() | nil) ::
          {:ok, map()} | {:error, term()}
  def observe_preparation(%DBConnection{}, _run, _authorization, _opts, _previous, _identity), do: {:error, :workspace_observation_inside_transaction}

  def observe_preparation(store, run, authorization, opts, previous, identity) do
    with true <- run["state"] in ~w(PUSHING CI_PUSHING) or {:error, :ticket_push_stage_invalid},
         :ok <- ci_claim_binding_valid(store, run),
         {:ok, admitted} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         {:ok, successor_context} <- TicketCiRepairSuccessor.push_context(store, run, opts),
         {:ok, imports} <- TicketHumanEmptyCommitImport.history(store, run["run_id"]),
         successor_context = if(imports == [], do: successor_context, else: Map.put(successor_context, "human_empty_commit_imports", Enum.map(imports, &Map.take(&1, ~w(import_key proof_sha256))))),
         admitted = Map.put(admitted, :ci_successor_context, successor_context),
         admitted = if(is_nil(identity), do: admitted, else: Map.put(admitted, :prepared_requalification, identity)),
         true <- previous_checkout?(previous, admitted.checkout) or {:error, :ticket_push_checkout_changed},
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         binding = binding(store, run, admitted, parent, origin),
         encoded = Jason.encode!(binding),
         key = "ticket-push:" <> digest(encoded),
         true <- previous_key?(previous, key) or {:error, :ticket_push_binding_already_completed} do
      attrs = %{
        "reservation_key" => key,
        "run_id" => run["run_id"],
        "task_key" => nil,
        "request_key" => key,
        "mode" => "MAINTENANCE",
        "allowed_root" => opts[:workspace_root],
        "expected_sha" => run["candidate_sha"]
      }

      {:ok,
       %{
         admitted: admitted,
         successor_context: successor_context,
         imports: imports,
         parent: parent,
         origin: origin,
         binding: binding,
         encoded: encoded,
         key: key,
         attrs: attrs,
         policy_store: store,
         owner: self()
       }}
    end
  end

  @doc false
  @spec recheck_preparation(Store.connection(), map(), map(), keyword(), map(), map()) :: :ok | {:error, term()}
  def recheck_preparation(tx, run, authorization, opts, plan, access) do
    with true <- plan.owner == self() or {:error, :ticket_push_preparation_owner_changed},
         :ok <- ci_claim_binding_valid(tx, run),
         :ok <- TicketCiRepairSuccessor.recheck_push_context(tx, run, Map.delete(plan.successor_context, "human_empty_commit_imports"), plan.policy_store),
         {:ok, imports} <- TicketHumanEmptyCommitImport.history(tx, run["run_id"]),
         true <- imports == plan.imports or {:error, :ticket_push_import_history_changed},
         :ok <- TicketWorkerRunner.recheck_delivery_admission(tx, run, authorization, opts, plan.admitted),
         {:ok, access_binding} <- Jason.decode(access["binding_json"]),
         true <- Map.take(access_binding, ~w(path git_dir common_dir root_device root_inode)) == stringify(plan.admitted.checkout) or {:error, :ticket_push_checkout_changed},
         {:ok, current_parent} <- TicketChat.for_run(tx, run["run_id"]),
         true <- current_parent == plan.parent or {:error, :ticket_push_parent_changed},
         true <- binding(tx, run, plan.admitted, current_parent, plan.origin) == plan.binding or {:error, :ticket_push_binding_changed} do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_preparation_changed}
    end
  end

  @doc false
  @spec store_preparation(Store.connection(), map(), String.t() | nil, map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def store_preparation(tx, run, previous, plan, access, nonce) do
    with true <- plan.owner == self() or {:error, :ticket_push_preparation_owner_changed},
         intent = %{
           "version" => 1,
           "kind" => "TICKET_PUSH",
           "phase" => "PREPARED",
           "binding_json" => plan.encoded,
           "binding_sha256" => digest(plan.encoded),
           "reservation_key" => plan.key,
           "reservation_generation" => access["generation"],
           "owner_nonce" => nonce,
           "helper_pid" => nil,
           "execution_json" => nil,
           "receipt_json" => nil,
           "receipt_sha256" => nil,
           "remote_sha" => nil
         },
         :ok <- persist(tx, run, previous, intent) do
      {:ok, intent}
    end
  end

  defp ci_claim_binding_valid(store, run) do
    case SymphonyElixir.Factory.TicketCiRepair.retained_preimage(store, run) do
      {:ok, _prior} ->
        case RepairObligations.ordinary_preflight(store, run) do
          {:ok, _} ->
            :ok

          _ ->
            case SymphonyElixir.Factory.TicketCiRepair.input_snapshot(store, run["run_id"]) do
              {:ok, _inputs} -> :ok
              {:error, _} = error -> error
            end
        end

      {:error, :ci_repair_history_absent} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp previous_checkout?(nil, _checkout), do: true

  defp previous_checkout?(raw, checkout) do
    previous = raw |> Jason.decode!() |> Map.fetch!("binding_json") |> Jason.decode!()
    previous["checkout"] == stringify(checkout)
  end

  defp previous_key?(nil, _key), do: true

  defp previous_key?(raw, key), do: Jason.decode!(raw)["reservation_key"] != key

  @doc "Executes a prepared push once or reconciles only its original terminal receipt."
  @spec step(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def step(store, run_id, authorization, opts) do
    lock = {{__MODULE__, run_id}, self()}

    case :global.trans(lock, fn -> push_step(store, run_id, authorization, opts) end) do
      :aborted -> {:error, :ticket_push_lock_unavailable}
      result -> result
    end
  end

  defp push_step(store, run_id, authorization, opts) do
    case TicketPushRequalification.maybe_requalify(store, run_id, authorization, opts) do
      {:ok, :not_applicable} -> ordinary_push_step(store, run_id, authorization, opts)
      result -> result
    end
  end

  defp ordinary_push_step(store, run_id, authorization, opts) do
    with {:ok, %{intent: intent} = preparation} <- ordinary_preparation(store, run_id, authorization, opts) do
      if intent["phase"] == "COMPLETED" and Map.has_key?(Jason.decode!(intent["binding_json"]), "verified_ci_rollover") do
        with {:ok, proof} <- completed_proof(store, run_id),
             :ok <- TicketWorkerRunner.validate_authorization(proof.run, authorization) do
          {:ok, %{status: "PUSH_ALREADY_COMPLETED", run: proof.run, model_invoked: false}}
        end
      else
        result =
          with {:ok, invoked} <- execute_once(store, run_id, intent, authorization, opts, preparation.observed) do
            complete_issued(store, run_id, invoked.intent, invoked.authorization, opts)
          end

        retain_publication_outcome(store, run_id, intent, result)
      end
    end
  end

  defp ordinary_preparation(store, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id) do
      case Jason.decode(run["candidate_handoff"] || "null") do
        {:ok, %{"kind" => "TICKET_PUSH", "phase" => "PREPARED"} = intent} ->
          observe_prepared(store, run_id, intent, authorization, opts)

        _ ->
          with {:ok, intent} <- prepare(store, run_id, authorization, opts),
               do: {:ok, %{intent: intent, observed: nil}}
      end
    end
  end

  defp observe_prepared(store, run_id, intent, authorization, opts) do
    result =
      with {:ok, observed} <- owned_observation(store, run_id, authorization, opts),
           do: {:ok, %{intent: observed.intent, observed: observed}}

    retain_publication_outcome(store, run_id, intent, result)
  end

  defp retain_publication_outcome(store, run_id, intent, {:error, reason} = error) do
    key = Enum.join(["ticket-push", intent["binding_sha256"], intent["owner_nonce"]], ":")
    code = if is_atom(reason), do: Atom.to_string(reason), else: "ticket_push_publication_failed"
    payload = Jason.encode!(%{operation_key: key, operation: "PUSH", status: "DEFERRED", reason: code})

    transaction(store, fn tx ->
      with {:ok, run} <- RunLedger.get(tx, run_id),
           {:ok, current} when is_map(current) <- Jason.decode(run["candidate_handoff"] || "null"),
           true <- Map.take(current, ~w(kind binding_sha256 owner_nonce)) == Map.take(intent, ~w(kind binding_sha256 owner_nonce)) do
        persist_publication_outcome(tx, run_id, payload)
      else
        _ -> :ok
      end
    end)

    error
  end

  defp retain_publication_outcome(_store, _run_id, _intent, result), do: result

  defp persist_publication_outcome(tx, run_id, payload) do
    previous = Store.one!(tx, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_RECOVERY_OUTCOME' ORDER BY id DESC LIMIT 1", [run_id])

    unless previous && previous["payload_json"] == payload do
      Store.query!(tx, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_RECOVERY_OUTCOME',?,?)", [DateTime.to_iso8601(DateTime.utc_now()), run_id, payload])
    end

    :ok
  end

  @doc "Reconciles only the original uncertain push receipt; never prepares, executes or rolls over a push."
  @spec reconcile(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, run_id, authorization, opts) do
    lock = {{__MODULE__, run_id}, self()}

    case :global.trans(lock, fn -> reconcile_issued(store, run_id, authorization, opts) end) do
      :aborted -> {:error, :ticket_push_lock_unavailable}
      result -> result
    end
  end

  @doc "Explicitly retires only an audited impossible v1 issuance; preserves its envelope and never executes it."
  @spec recover_unissuable_v1(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_unissuable_v1(store, run_id, authorization, opts) do
    :global.trans({{__MODULE__, run_id}, self()}, fn ->
      transaction(store, &recover_unissuable_transaction(&1, run_id, authorization, opts))
    end)
  end

  defp recover_unissuable_transaction(tx, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(tx, run_id),
         original when is_binary(original) <- run["candidate_handoff"],
         {:ok, %{"phase" => "PUSH_UNCERTAIN"} = intent} <- Jason.decode(original),
         {:ok, ^intent} <- validate_existing(tx, run, original, authorization, opts),
         {:ok, proof} <- TicketPushIO.unissuable_v1_proof(intent),
         disposition = Map.merge(intent, %{"phase" => "UNISSUABLE", "receipt_json" => proof, "receipt_sha256" => digest(proof)}),
         :ok <- persist(tx, run, original, disposition),
         {:ok, _} <- WorkspaceAccess.release_unissuable_push(tx, run_id, disposition["reservation_key"], disposition["reservation_generation"]) do
      Store.query!(tx, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)", [
        DateTime.to_iso8601(DateTime.utc_now()),
        "TICKET_PUSH_UNISSUABLE_V1",
        run_id,
        Jason.encode!(%{"original_envelope" => original, "controller_disposition" => proof})
      ])

      {:ok, %{status: "UNISSUABLE_RECORDED", run_id: run_id}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_unissuable_v1_unproven}
    end
  end

  defp reconcile_issued(store, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         raw when is_binary(raw) <- run["candidate_handoff"],
         true <-
           is_nil(opts[:expected_envelope]) or raw == opts[:expected_envelope] or
             {:error, :ticket_push_intent_changed},
         {:ok, %{"phase" => "PUSH_UNCERTAIN"}} <- Jason.decode(raw),
         {:ok, invoked} <- validate_existing(store, run, raw, authorization, opts) do
      complete_issued(store, run_id, invoked, authorization, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_recovery_unissued}
    end
  end

  defp complete_issued(store, run_id, invoked, authorization, opts) do
    with {:ok, raw} <- TicketPushIO.readback(invoked),
         :ok <- issued_receipt(raw, invoked),
         binding = Jason.decode!(invoked["binding_json"]),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => binding["repo_path"]}, binding["worktree"]),
         true <- origin == binding["origin"] or {:error, :ticket_push_destination_changed},
         {:ok, sha} <- Worktree.read_remote_branch(%{"path" => binding["repo_path"]}, binding["branch"]),
         true <- sha == binding["candidate_sha"] or {:error, :ticket_push_remote_mismatch},
         {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, fresh} <- refresh_push_authorization(run, authorization, opts) do
      finalize(store, run_id, invoked, raw, sha, fresh, opts)
    end
  end

  defp issued_receipt(raw, invoked) do
    if TicketPushIO.receipt_valid?(raw, invoked) do
      :ok
    else
      case TicketPushIO.rejection_reason(raw, invoked) do
        {:ok, reason} -> {:error, {:ticket_push_rejected_before_issuance, reason}}
        _ -> {:error, :ticket_push_receipt_unproven}
      end
    end
  end

  @doc "Prepares a read-only, exact-envelope input retirement; grants no retry authority."
  @spec prepare_input_retirement(Store.connection(), String.t(), String.t(), String.t(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_input_retirement(%DBConnection{}, _run_id, _nonce, _envelope_sha, _receipt, _receipt_sha, _authorization, _opts),
    do: {:error, :workspace_observation_inside_transaction}

  def prepare_input_retirement(store, run_id, nonce, envelope_sha, receipt, receipt_sha, authorization, opts) do
    with {:ok, _tick} <- SymphonyElixir.Factory.TicketPushRecovery.tick_binding(store, opts),
         {:ok, proof} <- TicketPushIO.input_fence_proof(receipt, receipt_sha, Keyword.fetch!(opts, :input_fence_guard)),
         {:ok, observed} <- owned_observation(store, run_id, authorization, opts),
         true <- (observed.intent["owner_nonce"] == nonce and digest(observed.run["candidate_handoff"]) == envelope_sha) or {:error, :input_retirement_envelope_changed},
         operation = proof["operation"],
         true <- (operation["run_id"] == run_id and operation["nonce"] == nonce and operation["envelope_sha256"] == envelope_sha) or {:error, :input_retirement_proof_changed},
         true <-
           (observed.intent["phase"] == "PUSH_UNCERTAIN" and Enum.all?(~w(helper_pid execution_json receipt_json receipt_sha256 remote_sha), &is_nil(observed.intent[&1]))) or
             {:error, :input_retirement_issuance_unproven},
         true <- input_fence_snapshot(store, run_id) == proof["snapshot"] or {:error, :input_retirement_snapshot_changed},
         true <- input_fence_schema(store) == proof["schema"] or {:error, :input_retirement_schema_changed},
         nil <- Store.one!(store, "SELECT retirement_key FROM ticket_push_input_retirements LIMIT 1"),
         {:ok, _preflight} <- prepare_input(store, observed.intent, authorization, opts, nil),
         {:ok, _tick} <- SymphonyElixir.Factory.TicketPushRecovery.tick_binding(store, opts) do
      proof_json = proof |> Map.delete("snapshot") |> Jason.encode!()
      key = "input-retirement:" <> digest(envelope_sha <> ":" <> receipt_sha)
      identity = %{"retirement_key" => key, "original_sha256" => envelope_sha, "attempt" => 1}
      encoded = observed.binding |> Map.put("input_retirement", identity) |> Jason.encode!()

      plan = %{
        "version" => 1,
        "kind" => "INPUT_NOT_ISSUED",
        "retirement_key" => key,
        "run_id" => run_id,
        "code_repair_round" => observed.run["code_repair_round"],
        "original_nonce" => nonce,
        "original_envelope" => observed.run["candidate_handoff"],
        "original_sha256" => envelope_sha,
        "proof_json" => proof_json,
        "proof_sha256" => digest(proof_json),
        "snapshot_sha256" => digest(Jason.encode!(proof["snapshot"])),
        "schema_sha256" => digest(Jason.encode!(proof["schema"])),
        "successor_nonce" => digest(key <> ":successor:1"),
        "successor_binding_sha256" => digest(encoded),
        "successor_reservation_key" => "ticket-push:" <> digest(encoded),
        "successor_binding_json" => encoded
      }

      {:ok, Map.put(plan, "plan_sha256", digest(Jason.encode!(plan)))}
    else
      {:error, _} = error -> error
      _ -> {:error, :input_retirement_already_used_or_unproven}
    end
  end

  @doc "Atomically records one explicit exact-v3 retirement and fresh successor; never sends a helper input."
  @spec execute_input_retirement(Store.connection(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_input_retirement(%DBConnection{}, _run_id, _nonce, _envelope_sha, _receipt, _receipt_sha, _plan_sha, _authorization, _opts),
    do: {:error, :workspace_observation_inside_transaction}

  def execute_input_retirement(store, run_id, nonce, envelope_sha, receipt, receipt_sha, plan_sha, authorization, opts) do
    :global.trans({{__MODULE__, run_id}, self()}, fn ->
      with {:ok, plan} <- prepare_input_retirement(store, run_id, nonce, envelope_sha, receipt, receipt_sha, authorization, opts),
           true <- plan["plan_sha256"] == plan_sha or {:error, :input_retirement_plan_changed},
           {:ok, observed} <- owned_observation(store, run_id, authorization, opts),
           snapshot = input_fence_snapshot(store, run_id),
           true <- digest(Jason.encode!(snapshot)) == plan["snapshot_sha256"] or {:error, :input_retirement_snapshot_changed},
           schema = input_fence_schema(store),
           true <- digest(Jason.encode!(schema)) == plan["schema_sha256"] or {:error, :input_retirement_schema_changed} do
        WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
          with {:ok, _tick} <- SymphonyElixir.Factory.TicketPushRecovery.tick_binding(tx, opts),
               :ok <- owned_current(tx, observed, access, authorization, opts),
               true <- (input_fence_snapshot(tx, run_id) == snapshot and observed.run["candidate_handoff"] == plan["original_envelope"]) or {:error, :input_retirement_snapshot_changed},
               true <- input_fence_schema(tx) == schema or {:error, :input_retirement_schema_changed},
               nil <- Store.one!(tx, "SELECT retirement_key FROM ticket_push_input_retirements LIMIT 1"),
               {:ok, _tick} <- SymphonyElixir.Factory.TicketPushRecovery.tick_binding(tx, opts) do
            fields =
              ~w(retirement_key run_id code_repair_round original_nonce original_envelope original_sha256 proof_json proof_sha256 successor_nonce successor_binding_sha256 successor_reservation_key)

            Store.query!(
              tx,
              "INSERT INTO ticket_push_input_retirements(#{Enum.join(fields, ",")},created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
              Enum.map(fields, &plan[&1]) ++ [DateTime.to_iso8601(DateTime.utc_now())]
            )

            retirement = Store.one!(tx, "SELECT * FROM ticket_push_input_retirements WHERE retirement_key = ?", [plan["retirement_key"]])

            with {:ok, successor} <- WorkspaceAccess.transfer_input_retirement(tx, retirement, access, opts),
                 intent =
                   Map.merge(observed.intent, %{
                     "phase" => "PREPARED",
                     "owner_nonce" => plan["successor_nonce"],
                     "binding_json" => plan["successor_binding_json"],
                     "binding_sha256" => plan["successor_binding_sha256"],
                     "reservation_key" => successor["reservation_key"],
                     "reservation_generation" => successor["generation"]
                   }),
                 :ok <- persist(tx, observed.run, plan["original_envelope"], intent) do
              {:ok, %{status: "INPUT_NOT_ISSUED_RETIRED", run_id: run_id, successor_nonce: intent["owner_nonce"], reservation_key: intent["reservation_key"]}}
            end
          else
            {:error, _} = error -> error
            _ -> {:error, :input_retirement_already_used}
          end
        end)
      end
    end)
  end

  defp input_fence_snapshot(store, run_id) do
    rows = fn sql, args ->
      result = Store.query!(store, sql, args)
      Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    end

    request = "desktop:ef1be3712383c1c7628b3a5135c82af75cfa603a80bf2adfbf4f8a6f19eb97fe"
    mr = "desktop:c634fd01f6bdbc7dab875cddda848ad5fe1ca65086e1684dafc7957b7a351962"

    result = %{
      "run" => Store.one!(store, "SELECT * FROM runs WHERE run_id=?", [run_id]),
      "mr_actor_audits" => rows.("SELECT * FROM ticket_mr_actor_bindings ORDER BY request_key", []),
      "mr_claims" => rows.("SELECT * FROM ticket_mr_claims ORDER BY request_key", []),
      "claimed_mr_request" => Store.one!(store, "SELECT * FROM desktop_requests WHERE request_key=?", [mr]),
      "access" => rows.("SELECT * FROM workspace_access WHERE run_id=? ORDER BY reservation_key", [run_id]),
      "held_global" => rows.("SELECT * FROM workspace_access WHERE released_at IS NULL ORDER BY reservation_key", []),
      "historical_UNKNOWN_CAS_events" => rows.("SELECT * FROM events WHERE run_id=? AND event_type IN ('TICKET_PUSH_UNKNOWN_HAZARD','TICKET_PUSH_CAS_ATTEMPT') ORDER BY id", [run_id]),
      "worker_desktop_request" => rows.("SELECT * FROM desktop_requests WHERE request_key=?", [request])
    }

    result =
      Enum.reduce(~w(factory_tasks worker_evidence native_source_bindings native_workspace_maintenance), result, fn table, acc ->
        Map.put(acc, table, rows.("SELECT * FROM #{table} WHERE run_id=? ORDER BY rowid", [run_id]))
      end)

    result =
      Map.put(
        result,
        "worker_file_operations",
        rows.("SELECT * FROM worker_file_operations WHERE request_key IN (SELECT request_key FROM worker_evidence WHERE run_id=?) ORDER BY request_key,call_id", [run_id])
      )

    result = Map.put(result, "ticket_chats", rows.("SELECT * FROM ticket_chats WHERE issue_key='PPL-9881' ORDER BY chat_key", []))

    result =
      Enum.reduce(~w(ticket_chat_inputs ticket_chat_commands ticket_chat_questions ticket_chat_runs), result, fn table, acc ->
        Map.put(acc, table, rows.("SELECT * FROM #{table} WHERE chat_key IN (SELECT chat_key FROM ticket_chats WHERE issue_key='PPL-9881') ORDER BY rowid", []))
      end)

    result =
      Map.put(
        result,
        "parent_claims",
        rows.("SELECT * FROM ticket_parent_claims WHERE request_key IN (SELECT create_request_key FROM ticket_chats WHERE issue_key='PPL-9881') ORDER BY request_key", [])
      )

    result =
      Map.put(
        result,
        "desktop_requests",
        rows.(
          "SELECT * FROM desktop_requests WHERE target_key=? OR target_key IN (SELECT task_key FROM factory_tasks WHERE run_id=?) OR target_key IN (SELECT chat_key FROM ticket_chats WHERE issue_key='PPL-9881') ORDER BY request_key",
          [run_id, run_id]
        )
      )

    Map.put(
      result,
      "repair",
      Map.new(~w(ticket_ci_generation_events ticket_ci_generation_intents ticket_ci_repair_claims ticket_ci_repair_diagnoses), &{&1, rows.("SELECT * FROM #{&1} ORDER BY rowid", [])})
    )
  end

  defp input_fence_schema(store) do
    Map.new(
      [
        {"objects", "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"},
        {"migrations", "SELECT * FROM factory_schema_migrations ORDER BY version"}
      ],
      fn {name, sql} ->
        result = Store.query!(store, sql)
        {name, Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))}
      end
    )
  end

  defp execute_once(store, run_id, %{"phase" => "PREPARED"} = intent, authorization, opts, captured) do
    with {:ok, observed} <- captured_observation(store, run_id, authorization, opts, captured),
         true <- observed.intent == intent or {:error, :ticket_push_intent_changed},
         {:ok, prepared} <- prepare_input(store, intent, authorization, opts, "BEFORE_CLAIM", true),
         {:ok, fresh} <- refresh_push_authorization(observed.run, authorization, opts),
         execution = Map.put(prepared.execution, "authorization", fresh),
         true <- TicketPushIO.transport_admissible?(execution) or {:error, :ticket_push_input_too_large},
         prepared = %{prepared | execution: execution},
         {:ok, _} <-
           TicketPushIO.execute(execution, fn pid, encoded ->
             publish_prepared_execution(store, observed, prepared, pid, encoded, fresh, opts)
           end),
         {:ok, run} <- RunLedger.get(store, run_id) do
      with {:ok, bound} <- Jason.decode(run["candidate_handoff"]), do: {:ok, %{intent: bound, authorization: fresh}}
    end
  end

  defp execute_once(_store, _run_id, intent, authorization, _opts, _captured), do: {:ok, %{intent: intent, authorization: authorization}}

  defp captured_observation(store, run_id, authorization, opts, nil), do: owned_observation(store, run_id, authorization, opts)
  defp captured_observation(_store, _run_id, _authorization, _opts, captured), do: {:ok, captured}

  defp refresh_push_authorization(run, authorization, opts) do
    result =
      case opts[:push_authorization_reader] do
        reader when is_function(reader, 2) -> reader.(run, authorization)
        nil -> {:ok, authorization}
        _ -> {:error, :ticket_authorization_required}
      end

    with {:ok, proof} <- result,
         true <- Map.get(proof, "delivery_review") == Map.get(authorization, "delivery_review") or {:error, :ticket_authorization_changed},
         validation_run = if(proof["delivery_review"], do: Map.put(run, "state", "REVIEW_WRITING"), else: run),
         :ok <- TicketWorkerRunner.validate_authorization(validation_run, proof) do
      {:ok, proof}
    end
  end

  defp publish_prepared_execution(store, observed, prepared, pid, encoded, authorization, opts) do
    with true <- encoded == Jason.encode!(prepared.execution) or {:error, :ticket_push_execution_changed} do
      WorkspaceAccess.acquire_with_observation(
        store,
        observed.attrs,
        opts,
        fn -> TicketPushIO.observe_issuance_source(store, prepared, opts) end,
        fn tx, access, captured -> bind_prepared_execution(tx, observed, captured, access, pid, encoded, authorization, opts) end
      )
    end
  end

  defp bind_prepared_execution(tx, observed, prepared, access, pid, encoded, authorization, opts) do
    with :ok <- TicketPushIO.recheck_issuance(tx, prepared),
         :ok <- owned_current(tx, observed, access, authorization, opts),
         :ok <- TicketPushIO.recheck_issuance_freshness(tx, prepared),
         true <- observed.intent["phase"] == "PREPARED" or {:error, :ticket_push_already_issued},
         bound = Map.merge(observed.intent, %{"phase" => "PUSH_UNCERTAIN", "helper_pid" => pid, "execution_json" => encoded}),
         :ok <- persist(tx, observed.run, observed.run["candidate_handoff"], bound) do
      {:ok, bound}
    end
  end

  defp prepare_input(store, intent, authorization, opts, phase, capture \\ false) do
    result =
      try do
        if capture,
          do: TicketPushIO.prepare_issuance(store, intent, authorization, opts),
          else: TicketPushIO.prepare(store, intent, authorization, opts)
      rescue
        error -> {:error, {:ticket_push_input_prepare_exception, error.__struct__}}
      catch
        kind, _ -> {:error, {:ticket_push_input_prepare_aborted, kind}}
      end

    case result do
      {:ok, _} = success ->
        success

      {:error, _} = error when is_nil(phase) ->
        error

      {:error, reason} = error ->
        run_id = Jason.decode!(intent["binding_json"])["run_id"]

        envelope_sha =
          case RunLedger.get(store, run_id) do
            {:ok, current} ->
              case Jason.decode(current["candidate_handoff"] || "null") do
                {:ok, ^intent} -> digest(current["candidate_handoff"])
                _ -> nil
              end

            _ ->
              nil
          end

        Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,?,?,?)", [
          DateTime.to_iso8601(DateTime.utc_now()),
          "TICKET_PUSH_INPUT_PREPARE_FAILED",
          run_id,
          Jason.encode!(%{
            "owner_nonce" => intent["owner_nonce"],
            "envelope_sha256" => envelope_sha,
            "binding_sha256" => intent["binding_sha256"],
            "phase" => phase,
            "reason" => reason |> inspect(limit: 10, printable_limit: 512) |> String.slice(0, 1024)
          })
        ])

        error
    end
  end

  defp finalize(store, run_id, original, raw, sha, authorization, opts) do
    with {:ok, observed} <- owned_observation(store, run_id, authorization, opts) do
      WorkspaceAccess.acquire_with_push_receipt(store, observed.attrs, opts, original, fn tx, access, current_receipt, release ->
        with :ok <- owned_current(tx, observed, access, authorization, opts),
             run = observed.run,
             intent = observed.intent,
             true <- (intent == original and current_receipt == raw) or {:error, :ticket_push_intent_changed},
             complete = Map.merge(intent, %{"phase" => "COMPLETED", "receipt_json" => raw, "receipt_sha256" => digest(raw), "remote_sha" => sha}),
             :ok <- persist(tx, run, run["candidate_handoff"], complete),
             {:ok, _} <- release.(),
             updates = push_transition(run, sha),
             {:ok, %{run: updated}} <- RunLedger.update(tx, run_id, updates) do
          {:ok, %{status: "PUSH_COMPLETED", run: updated, model_invoked: false}}
        end
      end)
    end
  end

  defp push_transition(%{"state" => "CI_PUSHING"}, sha),
    do: %{
      state: "CI_MR_CREATING",
      ci_preflight_sha: sha,
      ci_pipeline_id: nil,
      ci_pipeline_url: nil,
      ci_evidence_json: nil,
      ci_last_checked_at: nil
    }

  defp push_transition(_run, _sha), do: %{state: "MR_CREATING"}

  @doc "Binds the original owned helper before it receives execution input."
  @spec attach_execution(Store.connection(), String.t(), pos_integer(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def attach_execution(%DBConnection{}, _run_id, _pid, _encoded, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  def attach_execution(store, run_id, pid, encoded, authorization, opts) when is_integer(pid) and pid > 0 do
    with {:ok, intent} <- prepare(store, run_id, authorization, opts),
         true <- intent["phase"] == "PUSH_UNCERTAIN" or {:error, :ticket_push_not_claimed},
         true <-
           (is_nil(intent["helper_pid"]) and is_nil(intent["execution_json"])) or
             {:error, :ticket_push_execution_already_bound},
         {:ok, execution} <- Jason.decode(encoded),
         {:ok, expected} <- prepare_input(store, intent, authorization, opts, "BEFORE_INPUT_ATTACH"),
         true <- execution == expected or {:error, :ticket_push_execution_changed} do
      with_owned_intent(store, run_id, authorization, opts, fn tx, run, current ->
        with true <- current == intent or {:error, :ticket_push_intent_changed},
             bound = Map.merge(intent, %{"helper_pid" => pid, "execution_json" => encoded}),
             :ok <- persist(tx, run, run["candidate_handoff"], bound) do
          {:ok, bound}
        end
      end)
    end
  end

  defp binding(store, run, admitted, parent, origin) do
    bootstrap = Store.one!(store, "SELECT * FROM desktop_requests WHERE request_key = ?", [parent["create_request_key"]])

    result =
      Map.take(run, ~w(run_id issue_key state repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round))
      |> Map.merge(%{
        "checkout" => stringify(admitted.checkout),
        "origin" => origin,
        "parent" => Map.take(parent, ~w(chat_key generation thread_id create_request_key observation_json)),
        "bootstrap" => Map.take(bootstrap, ~w(status request_key target_kind target_key action codex_project_id model
                                            reasoning_effort title prompt cwd existing_thread_id branch base_branch
                                            thread_id turn_id payload_sha256 output_json verified_cwd verified_project_id
                                            target_observation_json schema_json metadata_json)),
        "verifier" => Map.take(admitted.verifier || %{}, ~w(request_key task_key thread_id binding_json binding_sha256
                                                        output_sha256 turn_id owner_stopped_at owner_stop_json consumed_at))
      })

    result =
      case SymphonyElixir.Factory.TicketCiRepair.retained_preimage(store, run) do
        {:ok, _prior} ->
          claim = Store.one!(store, "SELECT claim_key, claim_sha256 FROM ticket_ci_repair_claims WHERE run_id = ? AND round = ?", [run["run_id"], run["code_repair_round"]])

          if claim do
            result
            |> Map.put("code_repair_round", run["code_repair_round"])
            |> Map.put("ci_repair", %{"claim_key" => claim["claim_key"], "claim_sha256" => claim["claim_sha256"], "round" => run["code_repair_round"]})
          else
            result
          end

        {:error, _} ->
          result
      end

    result =
      case Store.one!(store, "SELECT * FROM ticket_push_input_retirements WHERE run_id = ? AND code_repair_round = ?", [run["run_id"], run["code_repair_round"]]) do
        nil ->
          result

        retirement ->
          prior = retirement["original_envelope"] |> Jason.decode!() |> Map.fetch!("binding_json") |> Jason.decode!()

          if prior["candidate_sha"] == run["candidate_sha"] do
            Map.put(result, "input_retirement", %{"retirement_key" => retirement["retirement_key"], "original_sha256" => retirement["original_sha256"], "attempt" => 1})
          else
            result
          end
      end

    successor_context = Map.get(admitted, :ci_successor_context, %{})
    result = result |> Map.merge(successor_context)
    result = Map.put(result, "code_repair_round", run["code_repair_round"])
    result = if map_size(successor_context) > 0 and run["state"] == "PUSHING", do: Map.delete(result, "ci_repair"), else: result

    result =
      if bootstrap["status"] == "FAILED" do
        recovery = Store.one!(store, "SELECT * FROM desktop_requests WHERE request_key = ?", [parent["create_request_key"] <> ":bootstrap-recovery:1"])
        Map.put(result, "bootstrap_recovery", recovery)
      else
        result
      end

    result = TicketPushRequalification.bind(store, run, result, Map.get(admitted, :prepared_requalification))
    result = TicketPushPreissuanceRejection.bind(store, run, result)
    TicketPushOrdinaryRejection.bind(store, run, result)
  end

  defp validate_existing(store, run, raw, authorization, opts) do
    with {:ok, observation} <- observe_existing(store, run, raw, authorization, opts), do: {:ok, observation.intent}
  end

  defp observe_existing(store, run, raw, authorization, opts) do
    with {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => phase} = intent} <- Jason.decode(raw),
         true <- valid_intent?(intent) or {:error, :ticket_push_intent_invalid},
         true <- phase in ~w(PREPARED PUSH_UNCERTAIN) or {:error, :ticket_push_phase_invalid},
         true <- digest(intent["binding_json"]) == intent["binding_sha256"] or {:error, :ticket_push_binding_corrupt},
         true <-
           intent["reservation_key"] == "ticket-push:" <> intent["binding_sha256"] or
             {:error, :ticket_push_reservation_changed},
         owned_opts = Keyword.put(opts, :reservation, %{key: intent["reservation_key"], generation: intent["reservation_generation"]}),
         {:ok, admitted} <- TicketWorkerRunner.delivery_admission(store, run, authorization, owned_opts),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         {:ok, stored_binding} <- Jason.decode(intent["binding_json"]),
         :ok <- TicketPushRequalification.current_binding(store, run, intent, stored_binding),
         {:ok, successor_context} <- retained_successor_context(store, run, stored_binding),
         admitted = Map.put(admitted, :ci_successor_context, successor_context),
         :ok <- input_retirement_current(store, run, intent, stored_binding),
         :ok <- TicketPushPreissuanceRejection.current(store, run, intent, stored_binding),
         :ok <- TicketPushOrdinaryRejection.current(store, run, intent, stored_binding),
         expected = binding(store, run, admitted, parent, origin),
         expected = if(Map.has_key?(stored_binding, "bootstrap_recovery"), do: expected, else: Map.delete(expected, "bootstrap_recovery")),
         expected = if(Map.has_key?(stored_binding, "code_repair_round"), do: expected, else: Map.delete(expected, "code_repair_round")),
         true <- stored_binding == expected or {:error, :ticket_push_binding_changed} do
      {:ok, %{intent: intent, run: run, admitted: admitted, origin: origin, parent: parent, binding: stored_binding, policy_store: store}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_intent_invalid}
    end
  end

  defp retained_successor_context(store, run, %{"ci_evidence_successor" => _} = binding) do
    retained_repair_context(store, run, binding)
  end

  defp retained_successor_context(store, run, %{"ordinary_verifier_repair" => _} = binding) do
    retained_repair_context(store, run, binding)
  end

  defp retained_successor_context(_, _, _), do: {:ok, %{}}

  defp retained_repair_context(store, run, binding) do
    context = Map.take(binding, ~w(ci_evidence_successor ci_repair_policy_receipt verified_ci_rollover human_empty_commit_imports ordinary_verifier_repair))

    with {:ok, expected} <- TicketCiRepairSuccessor.push_context(store, run),
         true <- Map.drop(context, ["verified_ci_rollover", "human_empty_commit_imports"]) == expected,
         :ok <- recheck_import_context(store, run, context),
         :ok <- TicketCiRepairSuccessor.recheck_push_context(store, run, Map.delete(context, "human_empty_commit_imports"), store) do
      {:ok, context}
    else
      _ -> {:error, :ci_successor_push_context_changed}
    end
  end

  defp recheck_import_context(store, run, context) do
    with {:ok, rows} <- TicketHumanEmptyCommitImport.history(store, run["run_id"]),
         expected = if(rows == [], do: nil, else: Enum.map(rows, &Map.take(&1, ~w(import_key proof_sha256)))),
         true <- context["human_empty_commit_imports"] == expected do
      :ok
    else
      _ -> {:error, :empty_import_history_changed}
    end
  end

  defp input_retirement_current(store, run, intent, %{"input_retirement" => identity}) do
    with row when is_map(row) <-
           Store.one!(store, "SELECT * FROM ticket_push_input_retirements WHERE retirement_key = ? AND run_id = ? AND code_repair_round = ?", [
             identity["retirement_key"],
             run["run_id"],
             run["code_repair_round"]
           ]),
         true <- identity == %{"retirement_key" => row["retirement_key"], "original_sha256" => row["original_sha256"], "attempt" => 1},
         true <- {intent["owner_nonce"], intent["binding_sha256"], intent["reservation_key"]} == {row["successor_nonce"], row["successor_binding_sha256"], row["successor_reservation_key"]},
         true <- digest(row["original_envelope"]) == row["original_sha256"] and digest(row["proof_json"]) == row["proof_sha256"],
         {:ok, original} <- Jason.decode(row["original_envelope"]),
         {:ok, proof} <- Jason.decode(row["proof_json"]),
         true <- proof["kind"] == "INPUT_NOT_ISSUED" and proof["operation"]["nonce"] == row["original_nonce"] and original["owner_nonce"] == row["original_nonce"],
         {:ok, access} <- WorkspaceAccess.get(store, original["reservation_key"]),
         true <- not is_nil(access["released_at"]),
         {:ok, release} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- release == %{"kind" => "INPUT_NOT_ISSUED", "retirement_key" => row["retirement_key"], "original_envelope" => row["original_envelope"], "proof_sha256" => row["proof_sha256"]} do
      :ok
    else
      _ -> {:error, :input_retirement_lineage_changed}
    end
  end

  defp input_retirement_current(_store, _run, _intent, _binding), do: :ok

  @doc "Claims issuance once; an uncertain operation can only be reconciled, never claimed again."
  @spec claim(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(%DBConnection{}, _run_id, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  def claim(store, run_id, authorization, opts) do
    with {:ok, intent} <- prepare(store, run_id, authorization, opts),
         true <- intent["phase"] == "PREPARED" or {:error, :ticket_push_already_issued} do
      with_owned_intent(store, run_id, authorization, opts, fn tx, run, current ->
        with true <- current == intent or {:error, :ticket_push_intent_changed},
             claimed = Map.put(intent, "phase", "PUSH_UNCERTAIN"),
             :ok <- persist(tx, run, run["candidate_handoff"], claimed) do
          {:ok, claimed}
        end
      end)
    end
  end

  defp with_owned_intent(%DBConnection{}, _run_id, _authorization, _opts, _commit), do: {:error, :workspace_observation_inside_transaction}

  defp with_owned_intent(store, run_id, authorization, opts, commit) do
    with {:ok, observed} <- owned_observation(store, run_id, authorization, opts) do
      WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
        with :ok <- owned_current(tx, observed, access, authorization, opts), do: commit.(tx, observed.run, observed.intent)
      end)
    end
  end

  defp owned_observation(%DBConnection{}, _run_id, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  defp owned_observation(store, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, observed} <- observe_existing(store, run, run["candidate_handoff"], authorization, opts),
         {:ok, access} <- WorkspaceAccess.get(store, observed.intent["reservation_key"]),
         {:ok, saved} <- Jason.decode(access["binding_json"]) do
      {:ok, Map.merge(observed, %{access: access, attrs: Map.take(saved, ~w(reservation_key run_id task_key request_key mode allowed_root expected_sha))})}
    end
  end

  defp owned_current(tx, observed, access, authorization, opts) do
    run = observed.run

    with {:ok, current} <- RunLedger.get(tx, run["run_id"]),
         true <- current == run or {:error, :ticket_push_intent_changed},
         :ok <- ci_claim_binding_valid(tx, run),
         context = Map.get(observed.admitted, :ci_successor_context, %{}),
         :ok <- recheck_import_context(tx, run, context),
         :ok <- TicketCiRepairSuccessor.recheck_push_context(tx, run, Map.delete(context, "human_empty_commit_imports"), observed.policy_store),
         true <- access == observed.access or {:error, :ticket_push_reservation_changed},
         :ok <- TicketWorkerRunner.recheck_delivery_admission(tx, run, authorization, opts, observed.admitted),
         {:ok, parent} <- TicketChat.for_run(tx, run["run_id"]),
         true <- parent == observed.parent or {:error, :ticket_push_parent_changed},
         expected = binding(tx, run, observed.admitted, parent, observed.origin),
         expected = if(Map.has_key?(observed.binding, "bootstrap_recovery"), do: expected, else: Map.delete(expected, "bootstrap_recovery")),
         true <- expected == observed.binding or {:error, :ticket_push_binding_changed} do
      :ok
    end
  end

  @doc false
  @spec recovery_observation(Store.connection(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recovery_observation(store, run_id, original_raw, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, observed} <- observe_existing(store, run, original_raw, authorization, opts),
         {:ok, access} <- WorkspaceAccess.get(store, observed.intent["reservation_key"]),
         {:ok, saved} <- Jason.decode(access["binding_json"]),
         true <- is_nil(access["released_at"]) or {:error, :push_recovery_lease_released} do
      {:ok, Map.merge(observed, %{access: access, attrs: Map.take(saved, ~w(reservation_key run_id task_key request_key mode allowed_root expected_sha))})}
    end
  end

  @doc false
  @spec recheck_recovery_observation(Store.connection(), map(), map(), map(), keyword()) :: :ok | {:error, term()}
  def recheck_recovery_observation(tx, observed, access, authorization, opts), do: owned_current(tx, observed, access, authorization, opts)

  defp valid_intent?(intent) do
    fields = ~w(version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce
                helper_pid execution_json receipt_json receipt_sha256 remote_sha)

    Map.keys(intent) |> Enum.sort() == Enum.sort(fields) and
      Enum.all?(~w(binding_json binding_sha256 reservation_key owner_nonce), &(is_binary(intent[&1]) and intent[&1] != "")) and
      is_integer(intent["reservation_generation"]) and intent["reservation_generation"] > 0 and
      Enum.all?(~w(receipt_json receipt_sha256 remote_sha), &is_nil(intent[&1])) and
      valid_execution?(intent) and
      String.match?(intent["owner_nonce"], ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_execution?(%{"helper_pid" => nil, "execution_json" => nil}), do: true

  defp valid_execution?(%{"helper_pid" => pid, "execution_json" => raw}),
    do: is_integer(pid) and pid > 0 and TicketPushIO.execution_size_valid?(raw)

  defp persist(store, run, previous, intent) do
    rows =
      Store.query!(
        store,
        "UPDATE runs SET candidate_handoff = ? WHERE run_id = ? AND candidate_handoff IS ? AND state = ? AND candidate_sha = ? AND contract_sha256 = ? AND spec_revision = ? RETURNING run_id",
        [Jason.encode!(intent), run["run_id"], previous, run["state"], run["candidate_sha"], run["contract_sha256"], run["spec_revision"]]
      ).rows

    if rows == [[run["run_id"]]], do: :ok, else: {:error, :ticket_push_intent_changed}
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp digest(raw) when is_binary(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
  defp digest(_), do: nil

  defp transaction(store, operation) do
    case Exqlite.transaction(store, fn tx -> rollback_error(tx, operation.(tx)) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result
end
