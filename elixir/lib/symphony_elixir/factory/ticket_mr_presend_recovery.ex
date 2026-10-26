defmodule SymphonyElixir.Factory.TicketMrPresendRecovery do
  @moduledoc "Consumes one audited delayed first-send capability without resetting the original claim."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{BrokerRuntime, DesktopRequest, Store, TicketMrGuard}
  alias SymphonyElixir.Factory.{TicketMrOperation, TicketMrOwnerAdmission, TicketMrPresendEvidence}
  @observation_ms 20_000
  @observation_attempts 3

  @doc false
  @spec available(Store.connection(), map(), String.t() | nil) :: :ok | {:error, term()}
  def available(store, request, broker \\ nil) do
    with true <- request["status"] == "FOLLOWUP_UNCERTAIN" and Enum.all?(~w(thread_id turn_id output_json failure_code superseded_by), &is_nil(request[&1])),
         :ok <- TicketMrOperation.authorize_readback(store, request),
         claim when is_map(claim) <- Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key=?", [request["request_key"]]),
         {:ok, receipt} <- Jason.decode(claim["receipt_json"]),
         bound_broker when is_binary(bound_broker) <- get_in(receipt, ["guard", "source_thread_id"]),
         true <- is_nil(broker) or broker == bound_broker,
         nil <-
           Store.one!(
             store,
             "SELECT request_key FROM desktop_requests WHERE target_kind='CONTROLLER' AND request_key!=? AND status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED') LIMIT 1",
             [request["request_key"]]
           ),
         nil <- Store.one!(store, "SELECT request_key FROM ticket_mr_presend_consumptions WHERE request_key=?", [request["request_key"]]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_presend_recovery_unavailable}
    end
  rescue
    Exqlite.Error -> {:error, :mr_presend_recovery_unavailable}
  end

  @doc false
  @spec observe(Store.connection(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(store, request, broker, opts) do
    with :ok <- available(store, request, broker),
         claim = Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key=?", [request["request_key"]]),
         {:ok, evidence, fence} <- stable_observation(store, request, broker, claim, opts, nil) do
      {:ok, %{claim: claim, evidence: evidence, broker_fence: fence}}
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_presend_history_changed}
    end
  end

  @doc false
  @spec finalize(Store.connection(), TicketMrOwnerAdmission.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def finalize(store, %TicketMrOwnerAdmission{} = context, owner, target) do
    if BrokerRuntime.owner_admission_active?(context) do
      finalize_current(store, context, owner, target)
    else
      {:error, :mr_owner_service_authority_required}
    end
  end

  def finalize(_, _, _, _), do: {:error, :mr_owner_service_authority_required}

  defp finalize_current(store, context, owner, target) do
    request = context.prepared.request

    with true <- context.action == :recover,
         :ok <- available(store, request, context.broker),
         {:ok, evidence, fence} <- stable_observation(store, request, context.broker, context.presend_recovery.claim, context.opts, context),
         :ok <- original_target(context.presend_recovery.claim, target),
         proof = %{"source_thread_id" => context.broker, "owner" => owner, "native" => target},
         {:ok, guard} <- TicketMrGuard.receipt(request, proof, context.broker, DateTime.utc_now()),
         :ok <- source_fresh(evidence),
         :ok <- TicketMrOwnerAdmission.recheck(store, context, context.factory) do
      record = %{
        "version" => 1,
        "operation" => "DELAYED_FIRST_SEND",
        "request_sha256" => digest(request),
        "claim_sha256" => context.presend_recovery.claim["receipt_sha256"],
        "run_sha256" => digest(context.prepared.run),
        "authorization_sha256" => digest(context.prepared.authorization),
        "admission_sha256" => digest(context.prepared.admitted),
        "guard" => guard,
        "broker_fence" => fence,
        "evidence" => evidence
      }

      Store.transaction!(store, &consume(&1, context, record))
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_presend_recovery_unproven}
    end
  end

  defp stable_observation(store, request, broker, claim, opts, context) do
    reader = Keyword.get(opts, :presend_evidence_reader, TicketMrPresendEvidence)
    native_reader = Keyword.get(opts, :presend_native_reader, AppServer)
    remaining = if context, do: min(@observation_ms, DateTime.diff(context.expires_at, DateTime.utc_now(), :millisecond)), else: @observation_ms
    deadline = System.monotonic_time(:millisecond) + remaining
    pin = if context, do: broker_identity(context.presend_recovery.broker_fence)
    input = %{store: store, request: request, broker: broker, claim: claim}
    observation = %{reader: reader, native_reader: native_reader, context: context, deadline: deadline}
    observe_attempt(Map.merge(input, observation), pin, 1)
  end

  defp observe_attempt(input, pin, attempt) do
    with :ok <- observation_budget(input),
         :ok <- pinned_claim(input),
         {:ok, before} <- read_broker(input.native_reader, input.request, input.broker),
         :ok <- observation_budget(input),
         {:ok, fence} <- recovery_projection(input.reader, before, input.broker),
         :ok <- same_broker_turn(fence, pin) do
      pin = pin || broker_identity(fence)

      case confirm_observation(input, before, fence, pin) do
        {:error, reason} when reason in ["mr_presend_session_changed", :mr_presend_broker_observation_changed] ->
          retry_observation(input, pin, attempt)

        result ->
          result
      end
    end
  end

  defp retry_observation(input, pin, attempt) when attempt < @observation_attempts,
    do: observe_attempt(input, pin, attempt + 1)

  defp retry_observation(_input, _pin, _attempt), do: {:error, :mr_presend_observation_budget_exhausted}

  defp confirm_observation(input, before, fence, pin) do
    with {:ok, evidence} <- read_evidence(input, before),
         :ok <- observation_budget(input),
         {:ok, after_read} <- read_broker(input.native_reader, input.request, input.broker),
         :ok <- observation_budget(input),
         {:ok, confirmed} <- recovery_projection(input.reader, after_read, input.broker),
         :ok <- same_broker_turn(confirmed, pin),
         true <- confirmed == fence or {:error, :mr_presend_broker_observation_changed},
         :ok <- current_loader(evidence, confirmed),
         :ok <- pinned_claim(input),
         :ok <- observation_budget(input) do
      {:ok, evidence, confirmed}
    end
  end

  defp read_evidence(%{context: nil} = input, native), do: input.reader.read(input.request, input.broker, native)
  defp read_evidence(input, native), do: input.reader.recheck(input.request, input.broker, native, input.context)

  defp recovery_projection(reader, native, broker) do
    case Code.ensure_loaded(reader) do
      {:module, ^reader} ->
        cond do
          function_exported?(reader, :recovery_projection, 2) -> reader.recovery_projection(native, broker)
          function_exported?(reader, :native_fence, 2) -> reader.native_fence(native, broker)
          true -> {:error, :mr_presend_evidence_reader_unavailable}
        end

      {:error, _} ->
        {:error, :mr_presend_evidence_reader_unavailable}
    end
  end

  defp pinned_claim(input) do
    with {:ok, request} <- DesktopRequest.get(input.store, input.request["request_key"]),
         true <- request == input.request,
         true <- Store.one!(input.store, "SELECT * FROM ticket_mr_claims WHERE request_key=?", [request["request_key"]]) == input.claim,
         :ok <- available(input.store, request, input.broker) do
      :ok
    else
      _ -> {:error, :mr_presend_recovery_changed}
    end
  end

  defp same_broker_turn(fence, pin) do
    if fence["turn_status"] in ~w(inProgress interrupted) and (is_nil(pin) or broker_identity(fence) == pin),
      do: :ok,
      else: {:error, :mr_presend_broker_turn_changed}
  end

  defp broker_identity(fence), do: Map.take(fence, ~w(id cwd turn_id turn_status))

  defp observation_budget(input) do
    if System.monotonic_time(:millisecond) < input.deadline do
      :ok
    else
      {:error, :mr_presend_observation_budget_exhausted}
    end
  end

  defp consume(tx, context, proof) do
    request = context.prepared.request
    claim = context.presend_recovery.claim

    with {:ok, ^request} <- DesktopRequest.get(tx, context.key),
         ^claim <- Store.one!(tx, "SELECT * FROM ticket_mr_claims WHERE request_key=?", [context.key]),
         :ok <- available(tx, request, context.broker),
         :ok <- TicketMrOwnerAdmission.recheck(tx, context, context.factory) do
      json = Jason.encode!(proof)
      incident_call = proof["evidence"]["state"]["incident_call_id"]

      Store.query!(
        tx,
        "INSERT INTO ticket_mr_presend_consumptions(request_key,claim_sha256,payload_sha256,broker_thread_id,native_call_id,proof_json,proof_sha256,consumed_at) VALUES(?,?,?,?,?,?,?,?)",
        [context.key, claim["receipt_sha256"], request["payload_sha256"], context.broker, incident_call, json, digest_raw(json), DateTime.to_iso8601(DateTime.utc_now())]
      )

      arguments = %{"threadId" => request["existing_thread_id"], "model" => request["model"], "thinking" => request["reasoning_effort"], "prompt" => request["prompt"]}
      {:ok, %{request_key: context.key, status: request["status"], arguments: arguments}}
    else
      {:error, reason} -> Exqlite.rollback(tx, reason)
      _ -> Exqlite.rollback(tx, :mr_presend_recovery_changed)
    end
  end

  defp current_loader(evidence, %{"turn_status" => status, "turn_id" => turn}) when status in ~w(inProgress interrupted) do
    state = evidence["state"]
    observation = evidence["source_observation"]

    case {state["active_recovery"], Map.values(state["pending"]), observation} do
      {nil, [%{"classification" => "CURRENT_RECOVERY", "turn_id" => ^turn, "exec_call_id" => exec}], %{"turn_id" => ^turn, "exec_call_id" => exec}} ->
        source_fresh(evidence)

      {%{"classification" => "CURRENT_RECOVERY", "turn_id" => ^turn, "exec_call_id" => exec}, [], %{"turn_id" => ^turn, "exec_call_id" => exec}} ->
        source_fresh(evidence)

      {%{"classification" => "CURRENT_RECOVERY", "turn_id" => ^turn, "exec_call_id" => exec, "cell_id" => cell},
       [%{"classification" => "CURRENT_RECOVERY_WAIT", "turn_id" => ^turn, "exec_call_id" => exec, "cell_id" => cell}], %{"turn_id" => ^turn, "exec_call_id" => exec}} ->
        source_fresh(evidence)

      _ ->
        {:error, :mr_presend_current_loader_unproven}
    end
  end

  defp current_loader(_, _), do: {:error, :mr_presend_current_loader_unproven}

  defp source_fresh(%{"source_observation" => %{"completed_at_ms" => completed}}) when is_integer(completed) do
    age = System.system_time(:millisecond) - completed
    if age >= 0 and age <= 10_000, do: :ok, else: {:error, :mr_presend_source_observation_expired}
  end

  defp source_fresh(_), do: {:error, :mr_presend_source_observation_unproven}

  defp original_target(claim, target) do
    with {:ok, receipt} <- Jason.decode(claim["receipt_json"]),
         original when is_map(original) <- get_in(receipt, ["proof", "native"]),
         true <- Map.take(original, ~w(id cwd projectId updatedAt)) == Map.take(target, ~w(id cwd projectId updatedAt)),
         true <- get_in(original, ["latest_turn_observation", "raw_response", "data"]) == get_in(target, ["latest_turn_observation", "raw_response", "data"]) do
      :ok
    else
      _ -> {:error, :mr_presend_target_changed}
    end
  end

  defp read_broker(reader, request, broker), do: reader.read_native_thread(broker, workspace: request["cwd"], include_turns: false, include_latest_turn: true, include_queue: true)
  defp digest(value), do: value |> Jason.encode!() |> digest_raw()
  defp digest_raw(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
