defmodule SymphonyElixir.Factory.DesktopRequest do
  @moduledoc """
  Durable handoff requests for a Codex Desktop-owned task broker.

  Claiming a request moves it to an uncertain state before any external call.
  A broker must reconcile that state with Codex rather than issuing a second
  create or follow-up after an interrupted attempt.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.DesktopToolArgs
  alias SymphonyElixir.Factory.NativeMaintenanceEvidence

  alias SymphonyElixir.Factory.{
    NativeSourceBinding,
    NativeWorktreeProbe,
    RunLedger,
    SpecialistErrorNotice,
    StageSchemas
  }

  alias SymphonyElixir.Factory.{Store, TaskLauncher, TaskLedger, TicketChat, Worktree}
  alias SymphonyElixir.Factory.{TicketJiraJournal, TicketMrOperation, TicketParentGuard}

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

  @doc "Keeps shared-controller uncertainty fenced, except proven unissued quarantined feedback."
  @spec controller_busy?(Store.connection(), String.t() | nil, String.t() | nil) :: boolean()
  def controller_busy?(connection, scope \\ nil, except_jira_operation \\ nil) do
    native_busy = native_controller_busy?(connection, scope)
    native_busy or TicketJiraJournal.controller_busy?(connection, scope, except_jira_operation)
  end

  @doc "Checks native controller requests only; Jira recovery must not be mistaken for an active native turn."
  @spec native_controller_busy?(Store.connection(), String.t() | nil) :: boolean()
  def native_controller_busy?(connection, scope \\ nil) do
    Store.one!(
      connection,
      """
      SELECT request.request_key FROM desktop_requests AS request
      WHERE request.target_kind = 'CONTROLLER'
        AND (? IS NULL OR request.target_key = ?)
        AND request.status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')
        AND NOT (
          request.status = 'PENDING' AND request.thread_id IS NULL AND request.turn_id IS NULL
          AND request.target_observation_json IS NULL AND request.verified_project_id IS NULL
          AND request.verified_cwd IS NULL AND request.verified_head_sha IS NULL AND request.output_json IS NULL
          AND EXISTS (SELECT 1 FROM mr_feedback_notes AS note WHERE note.request_key = request.request_key)
          AND NOT EXISTS (
            SELECT 1 FROM mr_feedback_notes AS note LEFT JOIN runs AS owner ON owner.run_id = note.run_id
            WHERE note.request_key = request.request_key AND (
              owner.run_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = owner.issue_key
                  AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1'
              )
            )
          )
        ) LIMIT 1
      """,
      [scope, scope]
    ) != nil
  end

  @doc "Enqueues one request, returning an identical existing request by stable key."
  @spec enqueue(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def enqueue(connection, attrs) when is_map(attrs) do
    with {:ok, payload} <- normalize(attrs),
         :ok <- NativeWorktreeProbe.validate_request(connection, payload) do
      Store.transaction!(connection, fn transaction -> enqueue_transaction(transaction, payload) end)
    end
  end

  @doc "Atomically claims a pending request; claims are never automatically reissued."
  @spec claim(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(connection, request_key, opts \\ []) do
    case get(connection, request_key) do
      {:ok, %{"target_kind" => "TICKET_CHAT"} = request} -> claim_ticket_parent(connection, request, opts)
      {:ok, request} -> claim_project_request(connection, request, opts)
      {:error, _} = error -> error
    end
  end

  defp claim_project_request(connection, request, opts) do
    if TicketMrOperation.typed_request?(request) do
      claim_typed_mr_request(connection, request, opts)
    else
      Store.transaction!(connection, &claim_transaction(&1, request["request_key"], opts, request))
    end
  end

  defp claim_typed_mr_request(connection, request, opts) do
    case Keyword.fetch(opts, :ticket_mr_admission) do
      {:ok, admission} ->
        with {:ok, %{request: claimed}} <- claim_mr_followup(connection, request["request_key"], admission, opts) do
          {:ok, claimed}
        end

      :error ->
        {:error, :request_run_quarantined}
    end
  end

  @doc "Qualifies and atomically claims an unissued MR followup; returns exact arguments after commit."
  @spec claim_mr_followup(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_mr_followup(%DBConnection{}, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def claim_mr_followup(connection, key, %{factory: factory} = admission, opts) do
    with_mr_claim_preadmission(connection, key, factory, opts, fn ->
      claim_mr_followup_prepared(connection, key, admission, opts)
    end)
  end

  def claim_mr_followup(_, _, _, _), do: {:error, :ticket_mr_claim_authority_required}

  @doc false
  @spec with_mr_claim_preadmission(Store.connection(), String.t(), map(), keyword(), (-> term())) :: term()
  def with_mr_claim_preadmission(%DBConnection{}, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def with_mr_claim_preadmission(connection, key, factory, opts, operation) do
    scope = {__MODULE__, :mr_claim_preadmission}

    case Process.get(scope) do
      %{store: ^connection, key: ^key, factory: ^factory} ->
        operation.()

      previous ->
        with {:ok, prepared} <- TicketMrOperation.claim_preadmission(connection, key, factory, opts) do
          Process.put(scope, %{store: connection, key: key, factory: factory, prepared: prepared, reference: make_ref()})

          try do
            operation.()
          after
            restore_mr_scope(scope, previous)
          end
        end
    end
  end

  @doc false
  @spec mr_claim_preadmission(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def mr_claim_preadmission(store, request, factory) do
    case Process.get({__MODULE__, :mr_claim_preadmission}) do
      %{factory: ^factory, prepared: %{request: ^request} = prepared, reference: reference} = context
      when is_reference(reference) ->
        if store === context.store or (not is_nil(context[:transaction]) and store === context[:transaction]),
          do: {:ok, prepared},
          else: {:error, :ticket_mr_claim_preadmission_required}

      _ ->
        {:error, :ticket_mr_claim_preadmission_required}
    end
  end

  defp claim_mr_followup_prepared(connection, key, admission, opts) do
    qualified_opts = Keyword.put(opts, :ticket_mr_admission, admission)

    with {:ok, request} <- get(connection, key),
         true <- TicketMrOperation.typed_request?(request) or {:error, :ticket_mr_claim_authority_required},
         {:ok, _arguments} <- DesktopToolArgs.followup(request),
         {:ok, receipt} <- issuance_admission(connection, request, qualified_opts),
         %{factory: factory} <- admission,
         {:ok, run} <- RunLedger.get(connection, receipt["binding"]["run_id"]),
         :ok <- SymphonyElixir.Factory.TicketMrCwdCorrection.check_native_actor(request, run, receipt["proof"]["native"]),
         :ok <- AppServer.check_ticket_runtime(receipt["binding"]["controller_cwd"]),
         {:ok, current_request, current_run, authorization} <-
           TicketMrOperation.read_claim_authorization(
             connection,
             key,
             factory,
             opts
           ),
         true <- current_request == request or {:error, :ticket_mr_request_changed},
         true <- current_run == run or {:error, :ticket_mr_claim_run_changed} do
      fresh_opts = Keyword.put(opts, :ticket_mr_admission, Map.put(admission, :authorization, authorization))

      case Exqlite.transaction(connection, &claim_mr_scoped_transaction(connection, &1, request, run, fresh_opts)) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp restore_mr_scope(scope, nil), do: Process.delete(scope)
  defp restore_mr_scope(scope, previous), do: Process.put(scope, previous)

  defp claim_mr_scoped_transaction(original, tx, request, run, opts) do
    scope = {__MODULE__, :mr_claim_preadmission}
    %{store: ^original} = previous = Process.get(scope)
    Process.put(scope, Map.put(previous, :transaction, tx))

    try do
      claim_mr_transaction(tx, request, run, opts)
    after
      Process.put(scope, previous)
    end
  end

  defp claim_mr_transaction(connection, request, run, opts) do
    with {:ok, current_run} <- RunLedger.get(connection, run["run_id"]),
         true <- current_run == run or {:error, :ticket_mr_claim_run_changed},
         {:ok, arguments} <- DesktopToolArgs.followup(request),
         {:ok, claimed} <- claim_transaction(connection, request["request_key"], opts, request) do
      {:ok, %{request: claimed, arguments: arguments}}
    else
      {:error, reason} -> Exqlite.rollback(connection, reason)
    end
  end

  @doc false
  @spec claim_mr_prequalified(Store.connection(), SymphonyElixir.Factory.TicketMrOwnerAdmission.t(), map()) :: {:ok, map()} | {:error, term()}
  def claim_mr_prequalified(%DBConnection{} = connection, %SymphonyElixir.Factory.TicketMrOwnerAdmission{} = context, proof) do
    with true <- SymphonyElixir.Factory.BrokerRuntime.owner_admission_active?(context) or {:error, :mr_owner_service_authority_required},
         true <- context.action == :claim or {:error, :mr_owner_admission_binding_mismatch},
         {:ok, arguments} <- DesktopToolArgs.followup(context.prepared.request),
         {:ok, claimed} <- claim_transaction(connection, context.key, [ticket_mr_admission: %{owner_admission: context, guard: proof}], context.prepared.request) do
      {:ok, %{request_key: claimed["request_key"], status: claimed["status"], arguments: arguments}}
    else
      {:error, _} = error -> error
    end
  end

  def claim_mr_prequalified(_connection, _context, _proof), do: {:error, :mr_owner_service_authority_required}

  defp claim_ticket_parent(connection, request, opts) do
    with :ok <- authorize_issuance(connection, request, opts),
         :ok <- require_status(request, "PENDING"),
         :ok <- TicketChat.creation_root_current(request, Keyword.get(opts, :ticket_policy, %{})),
         {:ok, _receipt} <- parent_guard_receipt(request, opts),
         cwd = if(request["action"] == "CREATE", do: Path.dirname(request["cwd"]), else: request["cwd"]),
         :ok <- AppServer.check_ticket_runtime(cwd) do
      Store.transaction!(connection, &claim_transaction(&1, request["request_key"], opts, request))
    end
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

  @doc "Records an explicitly projectless ticket-parent observation without source binding."
  @spec record_ticket_thread(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_ticket_thread(connection, request_key, proof) when is_map(proof) do
    Store.transaction!(connection, fn transaction ->
      case get(transaction, request_key) do
        {:ok, %{"target_kind" => "TICKET_CHAT"} = request} -> TicketChat.record_thread(transaction, request, proof["thread_id"], proof)
        {:ok, _} -> {:error, :not_a_ticket_chat_request}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Records a broker-verified result for the exact bound thread."
  @spec complete(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def complete(connection, request_key, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    Store.transaction!(connection, fn transaction ->
      with {:ok, request} <- get(transaction, request_key),
           :ok <- require_not_quarantined_request(transaction, request),
           {:ok, attrs} <- NativeMaintenanceEvidence.attach(transaction, request, attrs),
           {:ok, attrs} <- attach_source_evidence(transaction, request, attrs),
           {:ok, output} <- normalize_legacy_controller_snapshot(request, Map.get(attrs, "output")),
           {:ok, output} <- normalize_specification_critic_review(transaction, request, output),
           {:ok, output} <- normalize_change_verifier_review(transaction, request, output),
           {:ok, output} <- normalize_legacy_native_writer_slice(transaction, request, output),
           {:ok, output_json} <- encode_json(output) do
        complete_transaction(transaction, request_key, Map.put(attrs, "output", output), output_json)
      end
    end)
  end

  @spec reconcile_negative_ticket_chat_presentation(
          Store.connection(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def reconcile_negative_ticket_chat_presentation(connection, request_key, thread_id, broker_thread_id, opts \\ []) do
    case get(connection, request_key) do
      {:ok, %{"status" => "FAILED", "failure_code" => "TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED"} = request} ->
        replay_negative_presentation(connection, request, thread_id, broker_thread_id)

      {:ok, request} ->
        reconcile_negative_presentation(connection, request, thread_id, broker_thread_id, Keyword.get(opts, :reader, AppServer))

      {:error, _} = error ->
        error
    end
  end

  defp reconcile_negative_presentation(connection, request, thread_id, broker, reader) do
    with {:ok, chat} <- validate_negative_presentation_request(connection, request, thread_id, broker, true),
         {:ok, readback} <-
           TicketChat.read_native_turn(
             connection,
             request["request_key"],
             thread_id,
             broker,
             reader: reader,
             include_completion: true
           ),
         {:ok, completion} <- negative_presentation_completion(request, chat, readback, thread_id, broker) do
      persist_negative_presentation(connection, request, chat, readback, completion, thread_id, broker)
    end
  end

  defp negative_presentation_completion(request, chat, readback, thread_id, broker) do
    completion = readback["completion"] || %{}
    output = completion["output"] || %{}
    observation = Jason.decode!(request["target_observation_json"] || "{}")

    valid =
      valid_negative_presentation_history?(request, chat, readback, thread_id, broker) and
        valid_negative_presentation_turn?(readback, completion, thread_id) and
        valid_negative_presentation_output?(readback, output, observation)

    if valid do
      {:ok, %{turn_id: readback["turn_id"], output: output, receipt: negative_receipt(readback)}}
    else
      {:error, :ticket_chat_negative_presentation_unproven}
    end
  end

  defp valid_negative_presentation_history?(request, chat, readback, thread_id, broker) do
    readback["history_complete"] === true and readback["request_key"] == request["request_key"] and
      readback["payload_sha256"] == request["payload_sha256"] and readback["generation"] == chat["generation"] and
      readback["source_thread_id"] == broker and readback["thread_id"] == thread_id
  end

  defp valid_negative_presentation_turn?(readback, completion, thread_id) do
    is_binary(readback["turn_id"]) and readback["turn_id"] != "" and completion["thread_id"] == thread_id and
      completion["turn_id"] == readback["turn_id"]
  end

  defp valid_negative_presentation_output?(readback, output, observation) do
    output["result"] == %{"acknowledged" => false} and valid_sha256?(readback["readback_sha256"]) and
      valid_sha256?(readback["invocation_sha256"]) and
      (is_nil(observation["native_readback_sha256"]) or observation["native_readback_sha256"] == readback["readback_sha256"]) and
      output["native_readback_sha256"] == readback["readback_sha256"]
  end

  defp negative_receipt(readback),
    do: Map.take(readback, ~w(request_key payload_sha256 generation source_thread_id thread_id cwd turn_id item_id started_at completed_at readback_sha256 invocation_sha256 status))

  defp persist_negative_presentation(connection, request, chat, _readback, completion, thread_id, broker) do
    Store.transaction!(connection, fn transaction ->
      persist_negative_presentation_transaction(transaction, request, chat, completion, thread_id, broker)
    end)
  end

  defp persist_negative_presentation_transaction(transaction, request, chat, completion, thread_id, broker) do
    with {:ok, current} <- get(transaction, request["request_key"]),
         true <- current == request or {:error, :ticket_chat_request_changed},
         {:ok, current_chat} <- TicketChat.get(transaction, chat["chat_key"]),
         {:ok, _} <- validate_negative_presentation_request(transaction, current, thread_id, broker, true),
         true <- current_chat == chat or {:error, :ticket_chat_binding_changed},
         output_json <- Jason.encode!(completion.output),
         attestation <- negative_presentation_attestation(request, chat, completion, output_json),
         attestation_json <- Jason.encode!(attestation),
         encoded_observation <- put_negative_presentation_attestation(request["target_observation_json"], attestation_json) do
      Store.query!(
        transaction,
        "UPDATE desktop_requests SET status = 'FAILED', failure_code = 'TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED', turn_id = ?, output_json = ?, target_observation_json = ?, updated_at = ? WHERE request_key = ? AND status = 'THREAD_RECORDED' AND payload_sha256 = ? AND target_observation_json = ?",
        [completion.turn_id, output_json, encoded_observation, now(), request["request_key"], request["payload_sha256"], request["target_observation_json"]]
      )

      with :ok <- ensure_single_change(transaction, :ticket_chat_negative_presentation_conflict),
           {:ok,
            %{
              "status" => "FAILED",
              "failure_code" => "TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED",
              "turn_id" => turn,
              "output_json" => ^output_json,
              "target_observation_json" => ^encoded_observation
            } = failed} <- get(transaction, request["request_key"]),
           true <- turn == completion.turn_id do
        {:ok, failed}
      else
        _ -> Exqlite.rollback(transaction, :ticket_chat_negative_presentation_conflict)
      end
    else
      {:error, reason} -> Exqlite.rollback(transaction, reason)
    end
  end

  defp negative_presentation_attestation(request, chat, completion, output_json) do
    observation = Jason.decode!(request["target_observation_json"] || "{}")

    proof = %{
      "kind" => "NATIVE_COMPLETED_NEGATIVE_TICKET_PRESENTATION",
      "request_key" => request["request_key"],
      "payload_sha256" => request["payload_sha256"],
      "generation" => chat["generation"],
      "thread_id" => chat["thread_id"],
      "source_thread_id" => chat["broker_thread_id"],
      "turn_id" => completion.turn_id,
      "readback_sha256" => completion.receipt["readback_sha256"],
      "native_readback_sha256_present" => Map.has_key?(observation, "native_readback_sha256"),
      "native_readback_sha256" => observation["native_readback_sha256"],
      "invocation_sha256" => completion.receipt["invocation_sha256"],
      "receipt_json" => Jason.encode!(completion.receipt),
      "receipt_sha256" => sha256(Jason.encode!(completion.receipt)),
      "output_sha256" => sha256(output_json)
    }

    Map.put(proof, "attestation_sha256", sha256(Jason.encode!(proof)))
  end

  defp put_negative_presentation_attestation(observation_json, attestation_json) do
    proof = Jason.decode!(observation_json)
    Jason.encode!(Map.put(proof, "negative_presentation_attestation", Jason.decode!(attestation_json)))
  end

  defp replay_negative_presentation(connection, request, thread_id, broker) do
    with {:ok, chat} <- TicketChat.get(connection, request["target_key"]),
         :ok <- validate_negative_presentation_binding(request, chat, thread_id, broker),
         {:ok, attestation} <- stored_negative_presentation_attestation(request),
         true <- payload_intact?(request),
         :ok <- TicketChat.validate_request(connection, request),
         true <- request["status"] == "FAILED" and request["failure_code"] == "TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED",
         true <- replay_observation_matches?(request, chat, thread_id) do
      {:ok, receipt} = Jason.decode(attestation["receipt_json"])

      if replay_negative_presentation_receipt_identity?(receipt, request, chat, thread_id, broker, attestation) and
           replay_negative_presentation_receipt_invocation?(receipt, attestation) do
        {:ok, request}
      else
        {:error, :ticket_chat_negative_presentation_replay_unproven}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_chat_negative_presentation_replay_unproven}
    end
  end

  defp replay_negative_presentation_receipt_identity?(receipt, request, chat, thread_id, broker, attestation) do
    receipt["request_key"] == request["request_key"] and receipt["payload_sha256"] == request["payload_sha256"] and
      receipt["generation"] == chat["generation"] and receipt["thread_id"] == thread_id and
      receipt["source_thread_id"] == broker and receipt["cwd"] == chat["cwd"] and
      receipt["turn_id"] == request["turn_id"] and receipt["readback_sha256"] == attestation["readback_sha256"]
  end

  defp replay_negative_presentation_receipt_invocation?(receipt, attestation) do
    receipt["invocation_sha256"] == attestation["invocation_sha256"] and valid_sha256?(receipt["invocation_sha256"])
  end

  defp stored_negative_presentation_attestation(request) do
    with {:ok, observation} when is_map(observation) <- Jason.decode(request["target_observation_json"] || "null"),
         %{"kind" => "NATIVE_COMPLETED_NEGATIVE_TICKET_PRESENTATION"} = attestation <- observation["negative_presentation_attestation"],
         true <- negative_presentation_output_attestation_valid?(request, attestation),
         true <- request["failure_code"] == "TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED" and request["turn_id"] == attestation["turn_id"],
         true <- is_binary(attestation["receipt_json"]) and attestation["receipt_sha256"] == sha256(attestation["receipt_json"]),
         {:ok, receipt} when is_map(receipt) <- Jason.decode(attestation["receipt_json"]),
         true <- stored_negative_presentation_receipt_matches?(receipt, attestation) do
      {:ok, attestation}
    else
      _ -> {:error, :ticket_chat_negative_presentation_replay_unproven}
    end
  end

  defp negative_presentation_output_attestation_valid?(request, attestation) do
    with true <- digest(Map.delete(attestation, "attestation_sha256")) == attestation["attestation_sha256"],
         true <- valid_sha256?(attestation["output_sha256"]) and attestation["output_sha256"] == sha256(request["output_json"] || ""),
         {:ok, %{"result" => %{"acknowledged" => false}, "native_readback_sha256" => readback}} <- Jason.decode(request["output_json"] || "null"),
         true <- valid_sha256?(readback) and readback == attestation["readback_sha256"] do
      true
    else
      _ -> false
    end
  end

  defp stored_negative_presentation_receipt_matches?(receipt, attestation) do
    receipt["request_key"] == attestation["request_key"] and receipt["payload_sha256"] == attestation["payload_sha256"] and
      receipt["generation"] == attestation["generation"] and receipt["thread_id"] == attestation["thread_id"] and
      receipt["source_thread_id"] == attestation["source_thread_id"] and receipt["turn_id"] == attestation["turn_id"] and
      receipt["readback_sha256"] == attestation["readback_sha256"] and receipt["invocation_sha256"] == attestation["invocation_sha256"]
  end

  defp replay_observation_matches?(request, chat, thread_id) do
    with {:ok, observation} when is_map(observation) <- Jason.decode(request["target_observation_json"] || "null"),
         %{"kind" => "NATIVE_COMPLETED_NEGATIVE_TICKET_PRESENTATION"} = attestation <- observation["negative_presentation_attestation"],
         proof <- Map.delete(observation, "negative_presentation_attestation"),
         true <- replay_native_observation_hash_matches?(proof, attestation),
         true <- exact_ticket_followup_observation?(request, chat, thread_id, proof) do
      true
    else
      _ -> false
    end
  end

  defp replay_native_observation_hash_matches?(proof, %{"native_readback_sha256_present" => present} = attestation)
       when is_boolean(present) do
    Map.has_key?(proof, "native_readback_sha256") == present and
      proof["native_readback_sha256"] == attestation["native_readback_sha256"] and
      (is_nil(proof["native_readback_sha256"]) or proof["native_readback_sha256"] == attestation["readback_sha256"])
  end

  defp replay_native_observation_hash_matches?(proof, attestation) do
    not Map.has_key?(attestation, "native_readback_sha256_present") and
      not Map.has_key?(proof, "native_readback_sha256")
  end

  defp validate_negative_presentation_request(store, request, thread_id, broker, require_current) do
    with {:ok, chat} <- TicketChat.get(store, request["target_key"]),
         :ok <- validate_negative_presentation_binding(request, chat, thread_id, broker),
         true <-
           request["status"] == "THREAD_RECORDED" and is_binary(request["claimed_at"]) and is_nil(request["turn_id"]) and
             is_nil(request["output_json"]) and request["failure_code"] in [nil, "NATIVE_PRESENTATION_REFRESH_LOOP_STOPPED"],
         true <- not require_current or chat["presentation_request_key"] == request["request_key"],
         true <- payload_intact?(request),
         :ok <- TicketChat.validate_request(store, request),
         true <- exact_ticket_followup_observation?(request, chat, thread_id) do
      {:ok, chat}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_chat_negative_presentation_not_current}
    end
  end

  defp validate_negative_presentation_binding(request, chat, thread_id, broker) do
    valid =
      valid_negative_presentation_target?(request, chat) and
        valid_negative_presentation_thread?(request, chat, thread_id) and
        valid_negative_presentation_broker?(request, chat, broker)

    if valid, do: :ok, else: {:error, :ticket_chat_negative_presentation_binding_mismatch}
  end

  defp valid_negative_presentation_target?(request, chat) do
    request["target_kind"] == "TICKET_CHAT" and request["target_key"] == chat["chat_key"] and
      request["action"] == "FOLLOWUP"
  end

  defp valid_negative_presentation_thread?(request, chat, thread_id) do
    is_binary(thread_id) and request["thread_id"] == thread_id and request["existing_thread_id"] == thread_id and
      chat["thread_id"] == thread_id
  end

  defp valid_negative_presentation_broker?(request, chat, broker) do
    chat["broker_thread_id"] == broker and is_binary(broker) and
      Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, broker) and
      request["verified_cwd"] == chat["cwd"] and is_nil(request["verified_project_id"])
  end

  defp exact_ticket_followup_observation?(request, chat, thread_id) do
    with {:ok, arguments} <- DesktopToolArgs.followup(request),
         {:ok, observation} when is_map(observation) <- Jason.decode(request["target_observation_json"] || "null") do
      valid_native_observation_hash?(observation) and
        Map.delete(observation, "native_readback_sha256") == expected_ticket_followup_observation(request, chat, thread_id, arguments)
    else
      _ -> false
    end
  end

  defp exact_ticket_followup_observation?(request, chat, thread_id, observation) do
    case DesktopToolArgs.followup(request) do
      {:ok, arguments} ->
        valid_native_observation_hash?(observation) and
          Map.delete(observation, "native_readback_sha256") == expected_ticket_followup_observation(request, chat, thread_id, arguments)

      _ ->
        false
    end
  end

  defp valid_native_observation_hash?(observation) do
    is_nil(observation["native_readback_sha256"]) or valid_sha256?(observation["native_readback_sha256"])
  end

  defp expected_ticket_followup_observation(request, chat, thread_id, arguments) do
    %{
      "request_key" => request["request_key"],
      "payload_sha256" => request["payload_sha256"],
      "generation" => chat["generation"],
      "thread_id" => thread_id,
      "project_id" => nil,
      "cwd" => chat["cwd"],
      "tool_arguments" => arguments,
      "worktree_attachments" => []
    }
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
  @spec rebind_unissued_cwd(Store.connection(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def rebind_unissued_cwd(store, request, cwd, prompt) do
    unissued = ~w(claimed_at thread_id turn_id target_observation_json verified_cwd verified_project_id verified_head_sha output_json rejected_tool_call_id failure_code)

    with {:ok, current} <- get(store, request["request_key"]),
         true <- current == request and current["target_kind"] == "TICKET_CHAT" and current["action"] == "CREATE" and current["status"] == "PENDING",
         true <- Enum.all?(unissued, &is_nil(current[&1])),
         true <- payload_intact?(current) do
      rebound = current |> Map.put("cwd", cwd) |> Map.put("prompt", prompt)
      query = "UPDATE desktop_requests SET cwd = ?, prompt = ?, payload_sha256 = ?, updated_at = ? WHERE request_key = ? AND status = 'PENDING' AND payload_sha256 = ?"
      Store.query!(store, query, [cwd, prompt, payload_digest(rebound), now(), current["request_key"], current["payload_sha256"]])
      get(store, current["request_key"])
    else
      _ -> {:error, :ticket_chat_rebind_requires_unissued_request}
    end
  end

  @doc false
  @spec pin_unissued_mr_actor(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def pin_unissued_mr_actor(%DBConnection{} = store, request, actor_cwd) do
    unissued = ~w(claimed_at thread_id turn_id target_observation_json verified_cwd verified_project_id verified_head_sha output_json rejected_tool_call_id failure_code superseded_by)

    with {:ok, current} <- get(store, request["request_key"]),
         true <- current == request and current["status"] == "PENDING" and TicketMrOperation.typed_request?(current),
         true <- Enum.all?(unissued, &is_nil(current[&1])) and payload_intact?(current),
         true <- Store.one!(store, "SELECT request_key FROM ticket_mr_claims WHERE request_key = ?", [current["request_key"]]) == nil,
         {:ok, metadata} <- Jason.decode(current["metadata_json"]),
         true <- not Map.has_key?(metadata["delivery_operation"], "controller_native_cwd") do
      metadata = put_in(metadata, ["delivery_operation", "controller_native_cwd"], actor_cwd)
      pinned = Map.put(current, "metadata_json", Jason.encode!(metadata))

      Store.query!(store, "UPDATE desktop_requests SET metadata_json = ?, payload_sha256 = ?, updated_at = ? WHERE request_key = ? AND status = 'PENDING' AND payload_sha256 = ?", [
        pinned["metadata_json"],
        payload_digest(pinned),
        now(),
        current["request_key"],
        current["payload_sha256"]
      ])

      get(store, current["request_key"])
    else
      _ -> {:error, :ticket_mr_actor_requires_unissued_request}
    end
  end

  def pin_unissued_mr_actor(_store, _request, _actor_cwd), do: {:error, :mr_actor_audit_transaction_required}

  @doc false
  @spec payload_intact?(map()) :: boolean()
  def payload_intact?(request) when is_map(request) do
    request["payload_sha256"] == payload_digest(request)
  rescue
    _error -> false
  end

  def payload_intact?(_request), do: false

  defp payload_digest(request) do
    request
    |> Map.take(@required_strings ++ ~w(existing_thread_id branch base_branch))
    |> Map.put("existing_thread_id", request["existing_thread_id"])
    |> Map.put("branch", request["branch"])
    |> Map.put("base_branch", request["base_branch"])
    |> Map.put("schema_json", request["schema_json"])
    |> Map.put("metadata_json", request["metadata_json"])
    |> digest()
  end

  @doc "Lists only requests safe to issue exactly once through the Desktop broker."
  @spec list_pending(Store.connection(), pos_integer(), keyword()) :: [map()]
  def list_pending(connection, limit \\ 50, opts \\ []) when is_integer(limit) and limit > 0 do
    legacy =
      list_by_status(
        connection,
        "status = 'PENDING' AND target_kind != 'TICKET_CHAT' AND NOT #{v1_owner_predicate()}",
        limit
      )

    parents = list_ticket_requests(connection, "status = 'PENDING'", limit, &TicketChat.authorize_issuance(connection, &1, Keyword.get(opts, :ticket_policy, %{})))
    mrs = list_mr_pending(connection, limit, Keyword.get(opts, :ticket_mr_factory))
    ordered_requests(legacy ++ parents ++ mrs, limit)
  end

  defp list_mr_pending(connection, limit, factory) when is_map(factory) do
    predicate = "status = 'PENDING' AND CASE WHEN json_valid(metadata_json) THEN json_type(metadata_json, '$.delivery_operation') END = 'object'"
    authorize = &TicketMrOperation.authorize_discovery(connection, &1, factory)
    list_ticket_requests(connection, predicate, limit, authorize, "CONTROLLER")
  end

  defp list_mr_pending(_connection, _limit, _factory), do: []

  @doc "Lists interrupted or ambiguous requests that need Codex readback."
  @spec list_reconciliation(Store.connection(), pos_integer()) :: [map()]
  def list_reconciliation(connection, limit \\ 50) when is_integer(limit) and limit > 0 do
    legacy =
      list_by_status(
        connection,
        "status IN ('CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED') AND target_kind != 'TICKET_CHAT' AND NOT #{v1_owner_predicate()}",
        limit
      )

    parents = list_ticket_requests(connection, "status IN ('CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')", limit, &TicketChat.authorize_readback(connection, &1))
    mrs = list_mr_readback(connection, limit)
    ordered_requests(legacy ++ parents ++ mrs, limit)
  end

  defp ordered_requests(requests, limit), do: requests |> Enum.uniq_by(& &1["request_key"]) |> Enum.sort_by(&{&1["created_at"], &1["request_key"]}) |> Enum.take(limit)

  defp list_mr_readback(connection, limit) do
    predicate = "status IN ('FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED') AND EXISTS (SELECT 1 FROM ticket_mr_claims AS claim WHERE claim.request_key = desktop_requests.request_key)"
    list_ticket_requests(connection, predicate, limit, &TicketMrOperation.authorize_readback(connection, &1), "CONTROLLER")
  end

  defp list_ticket_requests(connection, predicate, limit, authorize, kind \\ "TICKET_CHAT") do
    Stream.unfold(0, fn offset ->
      rows = Store.query!(connection, "SELECT * FROM desktop_requests WHERE target_kind = ? AND #{predicate} ORDER BY created_at ASC, request_key ASC LIMIT ? OFFSET ?", [kind, limit, offset])

      case rows.rows do
        [] -> nil
        page -> {Enum.map(page, &Map.new(Enum.zip(rows.columns, &1))), offset + length(page)}
      end
    end)
    |> Stream.flat_map(& &1)
    |> Stream.filter(&(authorize.(&1) == :ok))
    |> Enum.take(limit)
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
          AND EXISTS (SELECT 1 FROM runs AS run WHERE run.run_id = task.run_id AND COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY'
            AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1'))
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

  defp claim_transaction(connection, request_key, opts, expected_request) do
    with {:ok, request} <- get(connection, request_key),
         true <- request == expected_request or {:error, :ticket_parent_request_changed},
         {:ok, mr_receipt} <- issuance_admission(connection, request, opts),
         :ok <- require_status(request, "PENDING"),
         :ok <- record_parent_guard(connection, request, opts) do
      status = if request["action"] == "CREATE", do: "CREATE_UNCERTAIN", else: "FOLLOWUP_UNCERTAIN"
      timestamp = now()
      record_mr_claim(connection, request, mr_receipt, timestamp)

      Store.query!(
        connection,
        "UPDATE desktop_requests SET status = ?, claimed_at = ?, updated_at = ? WHERE request_key = ? AND status = 'PENDING'",
        [status, timestamp, timestamp, request_key]
      )

      get(connection, request_key)
    end
  end

  defp record_mr_claim(_connection, _request, nil, _timestamp), do: :ok

  defp record_mr_claim(connection, request, receipt, timestamp) do
    json = receipt |> Map.put("claimed_at", timestamp) |> Jason.encode!()
    Store.query!(connection, "INSERT INTO ticket_mr_claims(request_key, receipt_json, receipt_sha256, claimed_at) VALUES (?, ?, ?, ?)", [request["request_key"], json, sha256(json), timestamp])
    :ok
  end

  defp record_parent_guard(connection, %{"target_kind" => "TICKET_CHAT", "action" => "FOLLOWUP"} = request, opts) do
    with {:ok, receipt} <- parent_guard_receipt(request, opts) do
      Store.query!(connection, "INSERT INTO ticket_parent_claims(request_key, receipt_json, claimed_at) VALUES (?, ?, ?)", [request["request_key"], Jason.encode!(receipt), now()])
      :ok
    end
  end

  defp record_parent_guard(_connection, _request, _opts), do: :ok

  defp parent_guard_receipt(%{"target_kind" => "TICKET_CHAT", "action" => "FOLLOWUP"} = request, opts),
    do: TicketParentGuard.receipt(request, Keyword.get(opts, :parent_guard), DateTime.utc_now())

  defp parent_guard_receipt(_request, _opts), do: {:ok, nil}

  defp require_not_quarantined_request(connection, request) do
    cond do
      mr_owned_request?(connection, request) -> TicketMrOperation.authorize_readback(connection, request)
      request_owned_by_v1?(connection, request) -> {:error, :request_run_quarantined}
      true -> :ok
    end
  end

  defp mr_owned_request?(connection, request) do
    TicketMrOperation.typed_request?(request) or
      Store.one!(connection, "SELECT request_key FROM ticket_mr_claims WHERE request_key = ?", [request["request_key"]]) != nil
  end

  defp request_owned_by_v1?(connection, request) do
    Store.one!(connection, v1_owner_sql(), [request["request_key"]]) != nil
  end

  defp v1_owner_predicate do
    "(EXISTS (SELECT 1 FROM factory_tasks AS owner_task JOIN runs AS owner_run ON owner_run.run_id = owner_task.run_id WHERE desktop_requests.target_kind = 'TASK' AND owner_task.task_key = desktop_requests.target_key AND (owner_run.execution_mode = 'TICKET_SUPERVISOR_V1' OR EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = owner_run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1'))) OR EXISTS (SELECT 1 FROM mr_feedback_notes AS owner_note JOIN runs AS owner_run ON owner_run.run_id = owner_note.run_id WHERE owner_note.request_key = desktop_requests.request_key AND (owner_run.execution_mode = 'TICKET_SUPERVISOR_V1' OR EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = owner_run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1'))) OR #{v1_controller_owner_predicate()})"
  end

  defp v1_controller_owner_predicate do
    """
    (EXISTS (SELECT 1 FROM ticket_mr_claims AS claim WHERE claim.request_key = desktop_requests.request_key) OR EXISTS (
      SELECT 1 FROM runs AS owner_run
      WHERE desktop_requests.target_kind = 'CONTROLLER'
        AND owner_run.execution_mode = 'TICKET_SUPERVISOR_V1'
        AND CASE WHEN json_valid(desktop_requests.metadata_json) THEN
          json_extract(desktop_requests.metadata_json, '$.delivery_operation.run_id') = owner_run.run_id
          OR json_extract(desktop_requests.metadata_json, '$.issue_key') = owner_run.issue_key
        ELSE 0 END
    ))
    """
  end

  defp v1_owner_sql do
    "SELECT request_key FROM desktop_requests WHERE request_key = ? AND #{v1_owner_predicate()} LIMIT 1"
  end

  @spec authorize_issuance(Store.connection(), map(), keyword()) :: :ok | {:error, term()}
  def authorize_issuance(connection, %{"target_kind" => "TICKET_CHAT"} = request, opts),
    do: TicketChat.authorize_issuance(connection, request, Keyword.get(opts, :ticket_policy, %{}))

  def authorize_issuance(connection, request, opts) do
    case issuance_admission(connection, request, opts) do
      {:ok, _receipt} -> :ok
      {:error, _} = error -> error
    end
  end

  defp issuance_admission(connection, request, opts) do
    with :ok <- jira_controller_available(connection, request) do
      request_admission(connection, request, opts)
    end
  end

  defp jira_controller_available(connection, %{"target_kind" => "CONTROLLER", "target_key" => scope}) do
    if TicketJiraJournal.controller_busy?(connection, scope) do
      {:error, :controller_jira_reconciliation_required}
    else
      :ok
    end
  end

  defp jira_controller_available(_connection, _request), do: :ok

  defp request_admission(connection, request, opts) do
    if mr_owned_request?(connection, request) do
      case Keyword.fetch(opts, :ticket_mr_admission) do
        {:ok, admission} -> TicketMrOperation.claim_receipt(connection, request, admission, opts)
        :error -> {:error, :request_run_quarantined}
      end
    else
      case authorize_ordinary_issuance(connection, request, opts) do
        :ok -> {:ok, nil}
        {:error, _} = error -> error
      end
    end
  end

  defp authorize_ordinary_issuance(connection, %{"target_kind" => "TICKET_CHAT"} = request, opts),
    do: TicketChat.authorize_issuance(connection, request, Keyword.get(opts, :ticket_policy, %{}))

  defp authorize_ordinary_issuance(connection, request, _opts), do: require_not_quarantined_request(connection, request)

  defp record_thread_transaction(connection, request_key, thread_id, verified_project_id, proof) do
    with :ok <- require_nonempty(thread_id, :thread_id),
         :ok <- require_nonempty(verified_project_id, :verified_project_id),
         {:ok, request} <- get(connection, request_key),
         :ok <- require_not_quarantined_request(connection, request),
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
         :ok <- bind_readback_target(connection, request, thread_id),
         :ok <- bind_native_workspace(connection, request, workspace) do
      maybe_record_thread(connection, request, thread_id, project_id, workspace)
    end
  end

  defp bind_readback_target(connection, request, thread_id) do
    if mr_owned_request?(connection, request),
      do: TicketMrOperation.authorize_readback(connection, request),
      else: bind_target_thread(connection, request, thread_id)
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
         :ok <- require_completion_with_claim(connection, request, attrs, output_json),
         :ok <- require_unseen_turn(connection, request, attrs),
         :ok <- validate_output(request, attrs),
         :ok <- NativeWorktreeProbe.validate_completion(connection, request, attrs),
         :ok <- validate_source_completion(connection, request, attrs),
         :ok <- require_controller_format_repair_completion(connection, request, attrs, output_json),
         {:ok, completed} <- maybe_complete(connection, request, attrs, output_json),
         :ok <- finish_controller_format_repair(connection, request, attrs, output_json) do
      {:ok, completed}
    end
  end

  defp attach_source_evidence(_store, %{"target_kind" => "TICKET_CHAT"}, attrs), do: {:ok, attrs}
  defp attach_source_evidence(store, request, attrs), do: NativeSourceBinding.attach(store, request, attrs)

  defp validate_source_completion(store, %{"target_kind" => "TICKET_CHAT"} = request, attrs) do
    with {:ok, proof} when is_map(proof) <- Jason.decode(request["target_observation_json"] || "null"),
         {:ok, _} <- TicketChat.record_thread(store, request, request["thread_id"], proof),
         :ok <- validate_ticket_chat_acknowledgment(attrs) do
      :ok
    else
      {:ok, _} -> {:error, :ticket_chat_observation_required}
      {:error, _} = error -> error
    end
  end

  defp validate_source_completion(store, request, attrs), do: NativeSourceBinding.validate_completion(store, request, attrs)

  defp validate_ticket_chat_acknowledgment(attrs) do
    result = get_in(attrs, ["output", "result"])

    cond do
      result == %{"acknowledged" => true} -> :ok
      result == %{"acknowledged" => false} and exact_empty_attachment_read?(attrs) -> :ok
      true -> {:error, :ticket_chat_acknowledgement_required}
    end
  end

  defp exact_empty_attachment_read?(attrs) do
    output = attrs["output"] || %{}
    calls = get_in(output, ["bootstrap_evidence", "list_artifacts"])

    valid_sha256?(output["native_readback_sha256"]) and
      Enum.any?(calls || [], fn
        %{"server" => "codex_app", "tool" => "list_artifacts", "arguments" => %{}, "result" => result} ->
          case result do
            %{"content" => [%{"type" => "text", "text" => text}]} -> Jason.decode(text) == {:ok, %{"artifacts" => []}}
            _ -> false
          end

        _ ->
          false
      end)
  end

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

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

  defp validate_output(request, %{"output" => %{"result" => result, "completed_tool_calls" => calls} = output})
       when is_map(result) and is_list(calls) do
    with {:ok, schema} <- Jason.decode(request["schema_json"]),
         :ok <- StageSchemas.validate(result, schema),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         :ok <- validate_required_calls(Map.get(metadata, "required_tool_calls", []), calls),
         observation = Jason.decode!(request["target_observation_json"] || "{}"),
         :ok <- SpecialistErrorNotice.validate_render(metadata, output, observation["native_readback_sha256"]) do
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

  defp maybe_complete(_connection, %{"status" => "FAILED", "failure_code" => "TICKET_CHAT_BOOTSTRAP_NOT_ACKNOWLEDGED"} = request, _attrs, _output_json),
    do: {:ok, request}

  defp maybe_complete(_connection, %{"status" => "FAILED", "failure_code" => "TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED"} = request, _attrs, _output_json),
    do: {:ok, request}

  defp maybe_complete(connection, %{"target_kind" => "TICKET_CHAT", "action" => "CREATE"} = request, %{"output" => %{"result" => %{"acknowledged" => false}}} = attrs, output_json) do
    with :ok <- persist_ticket_chat_attestation(connection, request, attrs),
         :ok <- persist_failed_bootstrap(connection, request, attrs, output_json) do
      get(connection, request["request_key"])
    end
  end

  defp maybe_complete(connection, %{"target_kind" => "TICKET_CHAT", "action" => "FOLLOWUP"} = request, attrs, output_json) do
    if request["request_key"] == request["target_key"] <> ":g1:create:bootstrap-recovery:1" do
      complete_ticket_chat_bootstrap_recovery(connection, request, attrs, output_json)
    else
      complete_ticket_chat_followup(connection, request, attrs, output_json)
    end
  end

  defp maybe_complete(connection, request, attrs, output_json) do
    with :ok <- complete_native_stage(connection, request, attrs) do
      thread_id = if TicketMrOperation.typed_request?(request), do: attrs["thread_id"], else: request["thread_id"]

      Store.query!(
        connection,
        "UPDATE desktop_requests SET status = 'SUCCEEDED', thread_id = ?, turn_id = ?, output_json = ?, failure_code = NULL, updated_at = ? WHERE request_key = ?",
        [thread_id, Map.get(attrs, "turn_id"), output_json, now(), request["request_key"]]
      )

      get(connection, request["request_key"])
    end
  end

  defp complete_ticket_chat_bootstrap_recovery(connection, request, attrs, output_json) do
    with :ok <- persist_ticket_chat_attestation(connection, request, attrs),
         :ok <- complete_native_stage(connection, request, attrs) do
      Store.query!(
        connection,
        "UPDATE desktop_requests SET status = 'SUCCEEDED', turn_id = ?, output_json = ?, failure_code = NULL, updated_at = ? WHERE request_key = ? AND status = 'THREAD_RECORDED'",
        [Map.get(attrs, "turn_id"), output_json, now(), request["request_key"]]
      )

      with :ok <- ensure_single_change(connection, :ticket_chat_completion_conflict),
           {:ok, %{"status" => "SUCCEEDED", "turn_id" => turn_id, "output_json" => ^output_json, "failure_code" => nil} = completed} <- get(connection, request["request_key"]),
           true <- turn_id == attrs["turn_id"] do
        {:ok, completed}
      else
        _ -> Exqlite.rollback(connection, :ticket_chat_completion_conflict)
      end
    end
  end

  defp complete_ticket_chat_followup(connection, request, attrs, output_json) do
    with :ok <- complete_native_stage(connection, request, attrs) do
      Store.query!(connection, "UPDATE desktop_requests SET status = 'SUCCEEDED', turn_id = ?, output_json = ?, failure_code = NULL, updated_at = ? WHERE request_key = ?", [
        Map.get(attrs, "turn_id"),
        output_json,
        now(),
        request["request_key"]
      ])

      get(connection, request["request_key"])
    end
  end

  defp persist_ticket_chat_attestation(connection, request, attrs) do
    with true <- request["target_kind"] == "TICKET_CHAT" and is_binary(request["target_observation_json"]),
         true <- valid_sha256?(get_in(attrs, ["output", "native_readback_sha256"])),
         {:ok, proof} when is_map(proof) <- Jason.decode(request["target_observation_json"]),
         encoded <- Jason.encode!(Map.put(proof, "native_readback_sha256", get_in(attrs, ["output", "native_readback_sha256"]))) do
      Store.query!(connection, "UPDATE desktop_requests SET target_observation_json = ? WHERE request_key = ? AND target_observation_json = ?", [
        encoded,
        request["request_key"],
        request["target_observation_json"]
      ])

      verify_ticket_chat_attestation_update(connection, request, encoded)
    else
      _ -> {:error, :ticket_chat_observation_required}
    end
  end

  defp verify_ticket_chat_attestation_update(connection, request, encoded) do
    with :ok <- ensure_single_change(connection, :ticket_chat_observation_conflict) do
      if get(connection, request["request_key"]) != {:ok, Map.put(request, "target_observation_json", encoded)},
        do: Exqlite.rollback(connection, :ticket_chat_observation_conflict)

      :ok
    end
  end

  defp persist_failed_bootstrap(connection, request, attrs, output_json) do
    Store.query!(
      connection,
      "UPDATE desktop_requests SET status = 'FAILED', turn_id = ?, output_json = ?, failure_code = 'TICKET_CHAT_BOOTSTRAP_NOT_ACKNOWLEDGED', updated_at = ? WHERE request_key = ? AND status = 'THREAD_RECORDED'",
      [Map.get(attrs, "turn_id"), output_json, now(), request["request_key"]]
    )

    with :ok <- ensure_single_change(connection, :ticket_chat_completion_conflict),
         {:ok, %{"status" => "FAILED", "failure_code" => "TICKET_CHAT_BOOTSTRAP_NOT_ACKNOWLEDGED", "turn_id" => turn_id, "output_json" => ^output_json}} <- get(connection, request["request_key"]),
         true <- turn_id == attrs["turn_id"] do
      :ok
    else
      _ -> Exqlite.rollback(connection, :ticket_chat_completion_conflict)
    end
  end

  defp ensure_single_change(connection, reason) do
    if Store.one!(connection, "SELECT changes() AS count")["count"] == 1, do: :ok, else: Exqlite.rollback(connection, reason)
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
         :ok <- require_not_quarantined_request(connection, request),
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

      record_specialist_failure(connection, request, reason)

      get(connection, request_key)
    end
  end

  defp record_specialist_failure(connection, %{"target_kind" => "TASK"} = request, reason) do
    case SpecialistErrorNotice.record_task(connection, request["target_key"], request["request_key"], reason) do
      {:ok, _notice} -> :ok
      {:error, error} -> Exqlite.rollback(connection, error)
    end
  end

  defp record_specialist_failure(_connection, _request, _reason), do: :ok

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
    required = if attrs["target_kind"] == "TICKET_CHAT", do: @required_strings -- ["codex_project_id"], else: @required_strings
    missing = Enum.reject(required, &present?(Map.get(attrs, &1)))

    cond do
      unknown != [] ->
        {:error, {:unknown_request_fields, Enum.sort(unknown)}}

      missing != [] ->
        {:error, {:missing_request_fields, missing}}

      attrs["target_kind"] not in ["TASK", "CONTROLLER", "TICKET_CHAT"] ->
        {:error, :invalid_target_kind}

      attrs["target_kind"] == "TICKET_CHAT" and
          (not Map.has_key?(attrs, "codex_project_id") or not is_nil(attrs["codex_project_id"])) ->
        {:error, :ticket_chat_requires_projectless_route}

      true ->
        :ok
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

  defp validate_target(connection, %{"target_kind" => "TICKET_CHAT"} = payload),
    do: TicketChat.validate_request(connection, payload)

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

  defp require_completion_with_claim(connection, %{"status" => "FOLLOWUP_UNCERTAIN"} = request, attrs, _output_json) do
    with true <- TicketMrOperation.typed_request?(request) or {:error, {:not_completable, request["status"]}},
         :ok <- TicketMrOperation.authorize_readback(connection, request),
         true <- (request["thread_id"] in [nil, request["existing_thread_id"]] and attrs["thread_id"] == request["existing_thread_id"]) or {:error, :thread_route_mismatch} do
      require_fresh_turn(request, attrs)
    end
  end

  defp require_completion_with_claim(_connection, request, attrs, output_json), do: require_completion(request, attrs, output_json)

  defp require_completion(%{"status" => status} = request, attrs, output_json) when status in ["SUCCEEDED", "FAILED"] do
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
