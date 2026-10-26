defmodule SymphonyElixir.Factory.TicketMrCwdCorrection do
  @moduledoc "Audited native-actor cwd pins, separate from the controller connector workspace."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{BrokerRuntime, Control, DesktopRequest, RunLedger, TicketChat, TicketMrGuard, TicketMrOperation, TicketWorkerRunner, Store}
  @unissued ~w(claimed_at thread_id turn_id target_observation_json verified_cwd verified_project_id verified_head_sha output_json rejected_tool_call_id failure_code superseded_by)
  @tick ~w(generation tick_id lease_expires_at updated_at)

  @spec correct(Store.connection(), String.t(), String.t(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def correct(%DBConnection{}, _, _, _, _, _, _), do: {:error, :mr_actor_observation_inside_transaction}

  def correct(store, key, expected_sha, factory, broker, owner, opts) do
    with {:ok, request} <- DesktopRequest.get(store, key),
         true <- request["payload_sha256"] == expected_sha or {:error, :mr_actor_request_changed},
         :ok <- unissued(store, request),
         {:ok, observed, run, authorization} <- TicketMrOperation.read_claim_authorization(store, key, factory, opts),
         true <- observed == request or {:error, :mr_actor_request_changed},
         {:ok, _} <- TicketMrOperation.check_new_request(store, key, authorization, factory, opts),
         {:ok, admitted} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         {:ok, parent} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- broker == parent["broker_thread_id"] or {:error, :mr_guard_broker_mismatch},
         control = Control.status(store, factory.scope),
         :ok <- pending_inputs(store, run["run_id"]),
         {:ok, native} <- AppServer.read_native_thread(request["existing_thread_id"], workspace: request["cwd"], include_turns: false, include_latest_turn: true, include_queue: true),
         {:ok, actor} <- actor_proof(request, run, broker, owner, native),
         proof = Map.merge(actor, %{"control" => control, "parent" => parent, "authorization" => authorization}),
         :ok <- no_claim_exchange(store, key),
         {:ok, current} <- DesktopRequest.get(store, key),
         true <- current == request or {:error, :mr_actor_request_changed} do
      Store.transaction!(store, fn tx ->
        with :ok <- unissued(tx, request),
             {:ok, current_run} <- RunLedger.get(tx, run["run_id"]),
             true <- (current_run == run and fence(Control.status(tx, factory.scope)) == fence(control)) or {:error, :mr_actor_inputs_changed},
             {:ok, ^parent} <- TicketChat.ready_for_run(tx, run["run_id"]),
             :ok <- pending_inputs(tx, run["run_id"]),
             :ok <- TicketWorkerRunner.recheck_delivery_admission(tx, run, authorization, opts, admitted),
             {:ok, _} <- fresh_proof(request, proof),
             {:ok, pinned} <- record(tx, request, proof, "CORRECTED") do
          {:ok, %{status: "MR_ACTOR_CWD_CORRECTED", request_key: key, payload_sha256: pinned["payload_sha256"], original_payload_sha256: expected_sha}}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_actor_binding_unproven}
    end
  end

  @doc false
  @spec finalize_owner_admission(Store.connection(), SymphonyElixir.Factory.TicketMrOwnerAdmission.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def finalize_owner_admission(store, context, owner, native) do
    with true <- (BrokerRuntime.owner_admission_active?(context) and context.action == :correct) or {:error, :mr_owner_service_authority_required},
         request = context.prepared.request,
         {:ok, actor} <- actor_proof(request, context.prepared.run, context.broker, owner, native),
         proof = Map.merge(actor, %{"control" => context.prepared.control, "parent" => context.prepared.parent, "authorization" => context.prepared.authorization}),
         :ok <- no_claim_exchange(store, context.key) do
      Store.transaction!(store, fn tx ->
        with :ok <- SymphonyElixir.Factory.TicketMrOwnerAdmission.recheck(tx, context, context.factory),
             :ok <- unissued(tx, request),
             {:ok, pinned} <- record(tx, request, proof, "CORRECTED") do
          {:ok, %{status: "MR_ACTOR_CWD_CORRECTED", request_key: context.key, payload_sha256: pinned["payload_sha256"], original_payload_sha256: request["payload_sha256"]}}
        end
      end)
    end
  end

  @doc false
  @spec observe_preparation(Store.connection(), map(), map(), String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def observe_preparation(%DBConnection{}, _, _, _, _), do: {:error, :mr_actor_observation_inside_transaction}

  def observe_preparation(store, run, factory, cwd, opts) do
    if factory.controller_codex_project_id == "projectless" do
      observe_projectless(store, run, factory, cwd, opts)
    else
      {:ok, nil}
    end
  end

  defp observe_projectless(store, run, factory, cwd, opts) do
    control = Control.status(store, factory.scope)
    reader = Keyword.get(opts, :mr_app_server, AppServer)

    with true <- (is_map(control) and control["controller_codex_project_id"] == "projectless") or {:error, :mr_actor_projectless_required},
         {:ok, native} <- reader.read_native_thread(control["controller_thread_id"], workspace: cwd, include_turns: false, include_latest_turn: true, include_queue: true),
         true <- (native["id"] == control["controller_thread_id"] and TicketMrGuard.native_project_matches?(native, control["controller_codex_project_id"])) or {:error, :mr_actor_identity_changed},
         {:ok, actor} <- TicketMrOperation.controller_cwd(native["cwd"], run["repo_path"], run["worktree"]),
         true <- actor == native["cwd"] or {:error, :mr_actor_cwd_not_canonical},
         %{"data" => [%{"id" => previous}]} when is_binary(previous) and byte_size(previous) > 0 <- get_in(native, ["latest_turn_observation", "raw_response"]) do
      proof = %{"controller_native_cwd" => actor, "native" => native, "control" => control, "connector_cwd" => cwd, "run" => run, "checked_at" => DateTime.to_iso8601(DateTime.utc_now())}

      request = %{
        "existing_thread_id" => control["controller_thread_id"],
        "codex_project_id" => "projectless",
        "cwd" => cwd,
        "metadata_json" => Jason.encode!(%{"previous_turn_id" => previous, "delivery_operation" => %{"controller_native_cwd" => actor}})
      }

      with :ok <- TicketMrGuard.native_receipt(request, native, DateTime.utc_now()), do: {:ok, proof}
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_actor_binding_unproven}
    end
  end

  @doc false
  @spec record(Store.connection(), map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def record(%DBConnection{} = store, request, proof, operation) when operation in ["PREPARED", "CORRECTED"] do
    with :ok <- unissued(store, request),
         :ok <- admission_proof(request, proof, operation),
         true <- Store.one!(store, "SELECT request_key FROM ticket_mr_actor_bindings WHERE request_key = ?", [request["request_key"]]) == nil or {:error, :mr_actor_already_pinned},
         {:ok, pinned} <- DesktopRequest.pin_unissued_mr_actor(store, request, proof["controller_native_cwd"]) do
      original = Jason.encode!(request)
      evidence = Jason.encode!(proof)

      Store.query!(
        store,
        "INSERT INTO ticket_mr_actor_bindings(request_key, operation, original_request_json, original_request_sha256, original_payload_sha256, pinned_payload_sha256, proof_json, proof_sha256, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
        [request["request_key"], operation, original, sha(original), request["payload_sha256"], pinned["payload_sha256"], evidence, sha(evidence), DateTime.to_iso8601(DateTime.utc_now())]
      )

      {:ok, pinned}
    end
  end

  def record(_store, _request, _proof, _operation), do: {:error, :mr_actor_audit_transaction_required}

  @doc false
  @spec preparation_current(Store.connection(), map(), map() | nil) :: :ok | {:error, atom()}
  def preparation_current(_store, _request, nil), do: :ok

  def preparation_current(store, request, proof) do
    with true <- fence(Control.status(store, proof["control"]["scope"])) == fence(proof["control"]),
         :ok <- admission_proof(request, proof, "PREPARED") do
      :ok
    else
      _ -> {:error, :mr_actor_inputs_changed}
    end
  end

  defp admission_proof(request, proof, "CORRECTED") do
    case fresh_proof(request, proof) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp admission_proof(request, proof, "PREPARED") do
    {:ok, metadata} = Jason.decode(request["metadata_json"])
    proposed = Map.put(request, "metadata_json", Jason.encode!(put_in(metadata, ["delivery_operation", "controller_native_cwd"], proof["controller_native_cwd"])))
    with :ok <- prepared_anchor(metadata, proof), do: TicketMrGuard.native_receipt(proposed, proof["native"], DateTime.utc_now())
  end

  @doc false
  @spec validate(Store.connection(), map()) :: :ok | {:error, atom()}
  def validate(store, request) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"] do
      cond do
        Map.has_key?(binding, "controller_native_cwd") -> validate_pin(store, request, metadata)
        Map.has_key?(metadata, "controller_ledger_turn_id") -> {:error, :mr_actor_audit_unproven}
        is_nil(Store.one!(store, "SELECT request_key FROM ticket_mr_actor_bindings WHERE request_key = ?", [request["request_key"]])) -> :ok
        true -> {:error, :mr_actor_audit_unproven}
      end
    else
      _ -> {:error, :mr_actor_audit_unproven}
    end
  end

  @doc "Reads a validated immutable actor-pin audit without issuing or authorizing work."
  @spec readback(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def readback(store, key) do
    with {:ok, request} <- DesktopRequest.get(store, key),
         audit when is_map(audit) <- Store.one!(store, "SELECT * FROM ticket_mr_actor_bindings WHERE request_key = ?", [key]),
         :ok <- validate(store, request),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]) do
      {:ok,
       %{
         status: "MR_ACTOR_AUDIT_VALIDATED",
         request_key: key,
         operation: audit["operation"],
         created_at: audit["created_at"],
         original_request_sha256: audit["original_request_sha256"],
         original_payload_sha256: audit["original_payload_sha256"],
         payload_sha256: audit["pinned_payload_sha256"],
         proof_sha256: audit["proof_sha256"],
         controller_cwd: request["cwd"],
         controller_native_cwd: metadata["delivery_operation"]["controller_native_cwd"],
         controller_thread_id: request["existing_thread_id"],
         candidate_sha: metadata["delivery_operation"]["candidate_sha"]
       }}
    else
      nil -> {:error, :mr_actor_audit_not_recorded}
      {:error, _} = error -> error
    end
  end

  defp validate_pin(store, request, metadata) do
    with audit when is_map(audit) <- Store.one!(store, "SELECT * FROM ticket_mr_actor_bindings WHERE request_key = ?", [request["request_key"]]),
         true <- not Map.has_key?(metadata, "controller_ledger_turn_id") or audit["operation"] == "PREPARED",
         true <- sha(audit["original_request_json"]) == audit["original_request_sha256"] and sha(audit["proof_json"]) == audit["proof_sha256"],
         {:ok, original} <- Jason.decode(audit["original_request_json"]),
         true <- DesktopRequest.payload_intact?(original) and original["payload_sha256"] == audit["original_payload_sha256"],
         true <- request["payload_sha256"] == audit["pinned_payload_sha256"] and DesktopRequest.payload_intact?(request),
         {:ok, old_metadata} <- Jason.decode(original["metadata_json"]),
         {:ok, proof} <- Jason.decode(audit["proof_json"]),
         true <- Map.delete(metadata["delivery_operation"], "controller_native_cwd") == old_metadata["delivery_operation"],
         true <- Map.delete(metadata, "delivery_operation") == Map.delete(old_metadata, "delivery_operation"),
         true <- metadata["delivery_operation"]["controller_native_cwd"] == proof["controller_native_cwd"],
         :ok <- stored_proof(original, request, proof, audit["operation"]),
         true <- Map.drop(request, @unissued ++ ~w(status metadata_json payload_sha256 updated_at)) == Map.drop(original, @unissued ++ ~w(status metadata_json payload_sha256 updated_at)) do
      :ok
    else
      _ -> {:error, :mr_actor_audit_unproven}
    end
  end

  defp fresh_proof(request, proof) do
    {:ok, metadata} = Jason.decode(request["metadata_json"])
    proposed = Map.put(request, "metadata_json", Jason.encode!(put_in(metadata, ["delivery_operation", "controller_native_cwd"], proof["controller_native_cwd"])))
    TicketMrGuard.receipt(proposed, proof, proof["source_thread_id"], DateTime.utc_now())
  end

  defp stored_proof(original, request, proof, "CORRECTED") do
    with %{"source_thread_id" => broker, "owner" => %{"observed_at" => at}, "native" => _native} <- proof,
         {:ok, now, _} <- DateTime.from_iso8601(proof["checked_at"]),
         {:ok, observed, _} <- DateTime.from_iso8601(at),
         true <- abs(DateTime.diff(now, observed, :microsecond)) <= 10_000_000,
         {:ok, _} <- TicketMrGuard.receipt(request, proof, broker, now),
         true <- proof["connector_cwd"] == original["cwd"] and proof["run"]["run_id"] == Jason.decode!(original["metadata_json"])["delivery_operation"]["run_id"],
         true <- proof["parent"]["broker_thread_id"] == broker and proof["control"]["controller_thread_id"] == original["existing_thread_id"] do
      :ok
    else
      _ -> {:error, :mr_actor_audit_unproven}
    end
  end

  defp stored_proof(original, request, proof, "PREPARED") do
    with {:ok, now, _} <- DateTime.from_iso8601(proof["checked_at"]),
         {:ok, metadata} <- Jason.decode(original["metadata_json"]),
         :ok <- prepared_anchor(metadata, proof),
         :ok <- TicketMrGuard.native_receipt(request, proof["native"], now),
         true <- proof["connector_cwd"] == original["cwd"] and proof["control"]["controller_thread_id"] == original["existing_thread_id"],
         true <- proof["run"]["run_id"] == Jason.decode!(original["metadata_json"])["delivery_operation"]["run_id"] do
      :ok
    else
      _ -> {:error, :mr_actor_audit_unproven}
    end
  end

  defp stored_proof(_original, _request, _proof, _operation), do: {:error, :mr_actor_audit_unproven}

  defp prepared_anchor(metadata, proof) do
    if Map.has_key?(metadata, "controller_ledger_turn_id") do
      anchor = metadata["controller_ledger_turn_id"]
      if is_binary(anchor) and byte_size(anchor) > 0 and anchor == get_in(proof, ["control", "controller_turn_id"]), do: :ok, else: {:error, :mr_actor_audit_unproven}
    else
      :ok
    end
  end

  defp actor_proof(request, run, broker, owner, native) do
    with true <- request["codex_project_id"] == "projectless" or {:error, :mr_actor_projectless_required},
         {:ok, actor} <- TicketMrOperation.controller_cwd(native["cwd"], run["repo_path"], run["worktree"]),
         true <- actor == native["cwd"] or {:error, :mr_actor_cwd_not_canonical},
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         proposed = Map.put(request, "metadata_json", Jason.encode!(put_in(metadata, ["delivery_operation", "controller_native_cwd"], actor))),
         guard = %{"source_thread_id" => broker, "owner" => owner, "native" => native},
         {:ok, receipt} <- TicketMrGuard.receipt(proposed, guard, broker, DateTime.utc_now()) do
      {:ok, Map.merge(guard, %{"controller_native_cwd" => actor, "connector_cwd" => request["cwd"], "run" => run, "checked_at" => receipt["checked_at"]})}
    else
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec check_native_actor(map(), map(), map()) :: :ok | {:error, term()}
  def check_native_actor(request, run, native) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         expected = metadata["delivery_operation"]["controller_native_cwd"] || request["cwd"],
         true <- native["cwd"] == expected or {:error, :mr_guard_identity_mismatch},
         {:ok, canonical} <- TicketMrOperation.controller_cwd(native["cwd"], run["repo_path"], run["worktree"]),
         true <- canonical == native["cwd"] or {:error, :mr_actor_cwd_not_canonical} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp unissued(store, request) do
    with {:ok, current} <- DesktopRequest.get(store, request["request_key"]),
         true <- current == request and current["status"] == "PENDING" and TicketMrOperation.typed_request?(request),
         true <- Enum.all?(@unissued, &is_nil(current[&1])) and DesktopRequest.payload_intact?(current),
         true <- Store.one!(store, "SELECT request_key FROM ticket_mr_claims WHERE request_key = ?", [request["request_key"]]) == nil,
         {:ok, metadata} <- Jason.decode(current["metadata_json"]),
         true <- metadata["delivery_operation"]["version"] == 2 and not Map.has_key?(metadata["delivery_operation"], "controller_native_cwd") do
      :ok
    else
      _ -> {:error, :mr_actor_requires_unissued_request}
    end
  end

  defp no_claim_exchange(store, key) do
    %{rows: databases} = Store.query!(store, "PRAGMA database_list")

    with [_, "main", database] <- Enum.find(databases, fn [_, name, _] -> name == "main" end),
         {:ok, root} <- BrokerRuntime.root(database),
         {:ok, names} <- File.ls(root) do
      Enum.reduce_while(names, :ok, fn name, _ ->
        if String.ends_with?(name, [".pending", ".running"]) do
          with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(Path.join(root, name)),
               true <- size <= 131_072,
               {:ok, bytes} <- File.read(Path.join(root, name)),
               {:ok, %{"args" => args}} when is_list(args) <- Jason.decode(bytes) do
            case args do
              [command, ^key | _] when command in ["claim", "claim-ticket-mr-owner", "claim-ticket-mr", "claim-ticket-mr-interactive", "finalize-ticket-mr-claim"] ->
                {:halt, {:error, :mr_actor_claim_exchange_unresolved}}

              _ ->
                {:cont, :ok}
            end
          else
            _ -> {:halt, {:error, :mr_actor_exchange_unproven}}
          end
        else
          {:cont, :ok}
        end
      end)
    else
      _ -> {:error, :mr_actor_exchange_unproven}
    end
  end

  defp pending_inputs(store, run) do
    command = Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING','ACCEPTED') LIMIT 1", [run])
    amendment = Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase NOT IN ('APPLIED','SUPERSEDED','REJECTED') LIMIT 1", [run])
    if is_nil(command) and is_nil(amendment), do: :ok, else: {:error, :mr_actor_pending_input}
  end

  defp fence(control) when is_map(control), do: Map.drop(control, @tick)
  defp fence(control), do: control
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
