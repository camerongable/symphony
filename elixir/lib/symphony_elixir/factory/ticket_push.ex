defmodule SymphonyElixir.Factory.TicketPush do
  @moduledoc "Once-only controller push, retained source ownership and exact stopped-process recovery."
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChat, TicketPushIO, TicketWorkerRunner}
  alias SymphonyElixir.Factory.{WorkspaceAccess, Worktree}

  @spec prepare(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(store, run_id, authorization, opts) do
    transaction(store, &prepare_transaction(&1, run_id, authorization, opts))
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
          prepare_new(store, run, authorization, opts, raw)
        end

      _ ->
        validate_existing(store, run, raw, authorization, opts)
    end
  end

  @doc "Reads the retained stopped push receipt for the current candidate and contract without mutations."
  @spec completed_proof(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def completed_proof(store, run_id) do
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
    with true <- run["state"] in ~w(PUSHING CI_PUSHING) or {:error, :ticket_push_stage_invalid},
         {:ok, admitted} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         true <- previous_checkout?(previous, admitted.checkout) or {:error, :ticket_push_checkout_changed},
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         binding = binding(store, run, admitted, parent, origin),
         encoded = Jason.encode!(binding),
         key = "ticket-push:" <> digest(encoded),
         true <- previous_key?(previous, key) or {:error, :ticket_push_binding_already_completed},
         {:ok, access} <-
           WorkspaceAccess.acquire(store, %{
             "reservation_key" => key,
             "run_id" => run["run_id"],
             "task_key" => nil,
             "request_key" => key,
             "mode" => "MAINTENANCE",
             "allowed_root" => opts[:workspace_root],
             "expected_sha" => run["candidate_sha"]
           }),
         intent = %{
           "version" => 1,
           "kind" => "TICKET_PUSH",
           "phase" => "PREPARED",
           "binding_json" => encoded,
           "binding_sha256" => digest(encoded),
           "reservation_key" => key,
           "reservation_generation" => access["generation"],
           "owner_nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
           "helper_pid" => nil,
           "execution_json" => nil,
           "receipt_json" => nil,
           "receipt_sha256" => nil,
           "remote_sha" => nil
         },
         :ok <- persist(store, run, previous, intent) do
      {:ok, intent}
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
    with {:ok, intent} <- prepare(store, run_id, authorization, opts),
         {:ok, invoked} <- execute_once(store, run_id, intent, authorization, opts) do
      complete_issued(store, run_id, invoked, authorization, opts)
    end
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
         true <- sha == binding["candidate_sha"] or {:error, :ticket_push_remote_mismatch} do
      finalize(store, run_id, invoked, raw, sha, authorization, opts)
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

  defp execute_once(store, run_id, %{"phase" => "PREPARED"}, authorization, opts) do
    with {:ok, claimed} <- claim(store, run_id, authorization, opts),
         {:ok, execution} <- TicketPushIO.prepare(store, claimed, authorization),
         {:ok, _} <-
           TicketPushIO.execute(execution, fn pid, encoded ->
             attach_execution(store, run_id, pid, encoded, authorization, opts)
           end),
         {:ok, run} <- RunLedger.get(store, run_id) do
      Jason.decode(run["candidate_handoff"])
    end
  end

  defp execute_once(_store, _run_id, intent, _authorization, _opts), do: {:ok, intent}

  defp finalize(store, run_id, original, raw, sha, authorization, opts) do
    transaction(store, fn tx ->
      with {:ok, run} <- RunLedger.get(tx, run_id),
           true <- is_binary(run["candidate_handoff"]) or {:error, :ticket_push_intent_changed},
           {:ok, intent} <- validate_existing(tx, run, run["candidate_handoff"], authorization, opts),
           true <- intent == original or {:error, :ticket_push_intent_changed},
           complete = Map.merge(intent, %{"phase" => "COMPLETED", "receipt_json" => raw, "receipt_sha256" => digest(raw), "remote_sha" => sha}),
           :ok <- persist(tx, run, run["candidate_handoff"], complete),
           {:ok, _} <- WorkspaceAccess.release_push(tx, run_id, complete["reservation_key"], complete["reservation_generation"]),
           updates = push_transition(run, sha),
           {:ok, %{run: updated}} <- RunLedger.update(tx, run_id, updates) do
        {:ok, %{status: "PUSH_COMPLETED", run: updated, model_invoked: false}}
      end
    end)
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
  def attach_execution(store, run_id, pid, encoded, authorization, opts) when is_integer(pid) and pid > 0 do
    transaction(store, fn tx ->
      with {:ok, intent} <- prepare(tx, run_id, authorization, opts),
           true <- intent["phase"] == "PUSH_UNCERTAIN" or {:error, :ticket_push_not_claimed},
           true <-
             (is_nil(intent["helper_pid"]) and is_nil(intent["execution_json"])) or
               {:error, :ticket_push_execution_already_bound},
           {:ok, execution} <- Jason.decode(encoded),
           {:ok, expected} <- TicketPushIO.prepare(tx, intent, authorization),
           true <- execution == expected or {:error, :ticket_push_execution_changed},
           {:ok, run} <- RunLedger.get(tx, run_id),
           bound = Map.merge(intent, %{"helper_pid" => pid, "execution_json" => encoded}),
           :ok <- persist(tx, run, run["candidate_handoff"], bound) do
        {:ok, bound}
      end
    end)
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

    if bootstrap["status"] == "FAILED" do
      recovery = Store.one!(store, "SELECT * FROM desktop_requests WHERE request_key = ?", [parent["create_request_key"] <> ":bootstrap-recovery:1"])
      Map.put(result, "bootstrap_recovery", recovery)
    else
      result
    end
  end

  defp validate_existing(store, run, raw, authorization, opts) do
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
         expected = binding(store, run, admitted, parent, origin),
         expected = if(Map.has_key?(stored_binding, "bootstrap_recovery"), do: expected, else: Map.delete(expected, "bootstrap_recovery")),
         true <- stored_binding == expected or {:error, :ticket_push_binding_changed} do
      {:ok, intent}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_push_intent_invalid}
    end
  end

  @doc "Claims issuance once; an uncertain operation can only be reconciled, never claimed again."
  @spec claim(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(store, run_id, authorization, opts) do
    transaction(store, fn tx ->
      with {:ok, intent} <- prepare(tx, run_id, authorization, opts),
           true <- intent["phase"] == "PREPARED" or {:error, :ticket_push_already_issued},
           {:ok, run} <- RunLedger.get(tx, run_id),
           claimed = Map.put(intent, "phase", "PUSH_UNCERTAIN"),
           :ok <- persist(tx, run, run["candidate_handoff"], claimed) do
        {:ok, claimed}
      end
    end)
  end

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
    do: is_integer(pid) and pid > 0 and is_binary(raw) and byte_size(raw) <= 262_144

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
