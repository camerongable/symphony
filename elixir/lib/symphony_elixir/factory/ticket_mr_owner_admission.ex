defmodule SymphonyElixir.Factory.TicketMrOwnerAdmission do
  @moduledoc "Short-lived service-owned MR qualification; fresh owner evidence arrives only afterwards."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{BrokerRuntime, DesktopRequest, Store, TicketMrCwdCorrection, TicketMrGuard}
  alias SymphonyElixir.Factory.{TicketMrOperation, TicketMrPresendRecovery, TicketWorkerRunner}

  @type t :: %__MODULE__{}
  defstruct ~w(action key broker factory prepared opts inputs workflow_sha256 expires_at authority presend_recovery handle native_reader)a
  @unissued ~w(claimed_at thread_id turn_id target_observation_json verified_cwd verified_project_id verified_head_sha output_json rejected_tool_call_id failure_code superseded_by)

  @doc false
  @spec prepare(Store.connection(), String.t(), atom(), String.t() | nil, map(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(%DBConnection{}, _, _, _, _, _, _), do: {:error, :mr_actor_observation_inside_transaction}

  def prepare(store, key, action, expected_sha, factory, broker, opts)
      when action in [:correct, :claim, :recover] do
    with {:ok, request} <- DesktopRequest.get(store, key),
         true <- (action in [:claim, :recover] and is_nil(expected_sha)) or expected_sha == request["payload_sha256"] or {:error, :mr_actor_request_changed},
         :ok <- request_state(store, request, action, broker),
         :ok <- correctable(request, action),
         {:ok, inputs} <- input_snapshot(store, request),
         {:ok, workflow_sha} <- workflow_sha(factory),
         {:ok, recovery} <- observe_recovery(store, request, action, broker, opts),
         {:ok, reader} <- open_reader(action, request) do
      try do
        captured = {request, inputs, workflow_sha, recovery, reader}

        case prepare_context(store, key, action, factory, broker, opts, captured) do
          {:ok, _} = result ->
            result

          error ->
            close_reader(reader)
            error
        end
      rescue
        error ->
          close_reader(reader)
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          close_reader(reader)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp prepare_context(store, key, action, factory, broker, opts, captured) do
    {request, inputs, workflow_sha, recovery, reader} = captured

    with {:ok, prepared} <- prepare_authority(store, key, action, factory, broker, opts),
         true <- prepared.request == request or {:error, :ticket_mr_request_changed},
         {:ok, auth_at, _} <- DateTime.from_iso8601(prepared.authorization["observed_at"]),
         expiry = Enum.min_by([DateTime.add(auth_at, 60, :second), DateTime.add(prepared.runtime_at, 60, :second), DateTime.add(prepared.remote_at, 10, :second)], &DateTime.to_unix(&1, :microsecond)),
         context = %__MODULE__{
           action: action,
           key: key,
           broker: broker,
           factory: factory,
           prepared: prepared,
           opts: opts,
           inputs: inputs,
           workflow_sha256: workflow_sha,
           expires_at: expiry,
           authority: make_ref(),
           presend_recovery: recovery,
           native_reader: reader
         },
         :ok <- recheck(store, context, factory) do
      {:ok, context}
    else
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec finalize(Store.connection(), t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def finalize(store, %__MODULE__{} = context, factory, owner) do
    with true <- BrokerRuntime.owner_admission_active?(context) or {:error, :mr_owner_service_authority_required},
         :ok <- recheck(store, context, factory),
         request = context.prepared.request,
         {:ok, facts} <- TicketWorkerRunner.delivery_facts(store, context.prepared.run, context.opts),
         true <- facts == Map.delete(context.prepared.admitted, :retained_mr_history) or {:error, :ticket_delivery_binding_changed},
         {:ok, native} <- collect_native(context, request),
         :ok <- workflow_current(context),
         :ok <- recheck(store, context, factory) do
      case context.action do
        :correct -> TicketMrCwdCorrection.finalize_owner_admission(store, context, owner, native)
        :claim -> finalize_claim(store, context, owner, native)
        :recover -> TicketMrPresendRecovery.finalize(store, context, owner, native)
      end
    end
  after
    close(context)
  end

  defp open_reader(:recover, _request), do: {:ok, nil}
  defp open_reader(_action, request), do: AppServer.open_native_reader(request["cwd"])

  defp collect_native(%{action: :recover}, request) do
    options = [workspace: request["cwd"], include_turns: false, include_latest_turn: true, include_queue: true]
    AppServer.read_native_thread(request["existing_thread_id"], options)
  end

  defp collect_native(context, request) do
    remaining = DateTime.diff(context.expires_at, DateTime.utc_now(), :millisecond)
    options = [include_turns: false, include_latest_turn: true, include_queue: true, timeout_ms: remaining]
    AppServer.read_native_thread(context.native_reader, request["existing_thread_id"], options)
  end

  @doc false
  @spec close(t() | nil) :: :ok | {:error, term()}
  def close(%__MODULE__{native_reader: reader}), do: close_reader(reader)
  def close(nil), do: :ok

  defp close_reader(nil), do: :ok
  defp close_reader(reader), do: AppServer.close_native_reader(reader)

  defp finalize_claim(store, context, owner, native) do
    request = context.prepared.request
    proof = %{"source_thread_id" => context.broker, "owner" => owner, "native" => native}

    with :ok <- TicketMrCwdCorrection.check_native_actor(request, context.prepared.run, native),
         {:ok, _} <- TicketMrGuard.receipt(request, proof, context.broker, DateTime.utc_now()) do
      Store.transaction!(store, fn tx -> DesktopRequest.claim_mr_prequalified(tx, context, proof) end)
    end
  end

  @doc false
  @spec recheck(Store.connection(), t(), map()) :: :ok | {:error, term()}
  def recheck(store, %__MODULE__{} = context, factory) do
    with true <- factory == context.factory or {:error, :mr_owner_factory_changed},
         true <- DateTime.compare(DateTime.utc_now(), context.expires_at) != :gt or {:error, :mr_owner_admission_expired},
         :ok <- request_state(store, context.prepared.request, context.action, context.broker),
         {:ok, inputs} <- input_snapshot(store, context.prepared.request),
         true <- inputs == context.inputs or {:error, :mr_owner_input_changed},
         :ok <- recheck_authority(store, context, factory) do
      :ok
    end
  end

  @doc false
  @spec workflow_current(t()) :: :ok | {:error, term()}
  def workflow_current(%__MODULE__{} = context) do
    case workflow_sha(context.factory) do
      {:ok, sha} when sha == context.workflow_sha256 -> :ok
      _ -> {:error, :mr_owner_factory_changed}
    end
  end

  defp workflow_sha(factory) do
    with {:ok, bytes} <- File.read(factory.ticket_supervisor["ticket_workflow"]), do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp correctable(request, :correct) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         false <- Map.has_key?(metadata["delivery_operation"], "controller_native_cwd") do
      :ok
    else
      _ -> {:error, :mr_actor_requires_unissued_request}
    end
  end

  defp correctable(_request, :claim), do: :ok
  defp correctable(_request, :recover), do: :ok

  defp request_state(store, request, :recover, broker), do: TicketMrPresendRecovery.available(store, request, broker)
  defp request_state(store, request, _action, _broker), do: unissued(store, request)

  defp observe_recovery(store, request, :recover, broker, opts), do: TicketMrPresendRecovery.observe(store, request, broker, opts)
  defp observe_recovery(_store, _request, _action, _broker, _opts), do: {:ok, nil}

  defp prepare_authority(store, key, :recover, factory, broker, opts), do: TicketMrOperation.owner_recovery_preadmission(store, key, factory, broker, opts)
  defp prepare_authority(store, key, _action, factory, broker, opts), do: TicketMrOperation.owner_preadmission(store, key, factory, broker, opts)

  defp recheck_authority(store, %{action: :recover} = context, factory), do: TicketMrOperation.recheck_owner_recovery(store, context.prepared, factory, context.opts)
  defp recheck_authority(store, context, factory), do: TicketMrOperation.recheck_owner_preadmission(store, context.prepared, factory, context.opts)

  defp unissued(store, request) do
    with {:ok, current} <- DesktopRequest.get(store, request["request_key"]),
         true <- current == request and current["status"] == "PENDING" and Enum.all?(@unissued, &is_nil(current[&1])),
         true <- DesktopRequest.payload_intact?(current) and TicketMrOperation.typed_request?(current),
         true <- is_nil(Store.one!(store, "SELECT request_key FROM ticket_mr_claims WHERE request_key = ?", [request["request_key"]])) do
      :ok
    else
      _ -> {:error, :mr_actor_requires_unissued_request}
    end
  end

  defp input_snapshot(store, request) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]) do
      run = metadata["delivery_operation"]["run_id"]

      rows =
        Map.new(
          ~w(ticket_chat_commands ticket_contract_amendments workspace_access worker_evidence factory_tasks),
          &{&1, Store.query!(store, "SELECT * FROM #{&1} WHERE run_id = ? ORDER BY 1", [run]).rows}
        )

      rows =
        Map.put(
          rows,
          "ticket_chat_inputs",
          Store.query!(store, "SELECT input.* FROM ticket_chat_inputs input JOIN ticket_chat_runs binding ON binding.chat_key = input.chat_key WHERE binding.run_id = ? ORDER BY input.input_key", [run]).rows
        )

      rows =
        Map.put(
          rows,
          "worker_file_operations",
          Store.query!(
            store,
            "SELECT op.* FROM worker_file_operations op JOIN worker_evidence worker ON worker.request_key = op.request_key WHERE worker.run_id = ? ORDER BY op.request_key, op.call_id",
            [run]
          ).rows
        )

      pending = Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING','ACCEPTED') LIMIT 1", [run])
      amendment = Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase NOT IN ('APPLIED','SUPERSEDED','REJECTED') LIMIT 1", [run])
      if is_nil(pending) and is_nil(amendment), do: {:ok, rows}, else: {:error, :mr_actor_pending_input}
    end
  end
end
