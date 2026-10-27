defmodule SymphonyElixir.Factory.WorkerEvidence do
  @moduledoc "Immutable attempt bindings and exact worker receipts; model completion is not adoption."
  alias SymphonyElixir.Factory.{
    ReviewProtocol,
    RunLedger,
    StageSchemas,
    Store,
    TaskLedger,
    WorkerCheckIO,
    WorkspaceAccess
  }

  alias SymphonyElixir.Factory.SpecialistErrorNotice
  alias SymphonyElixir.Factory.TicketCapabilityRecovery

  @fields ~w(request_key task_key reservation_key input_sha256 owner_id schema policy)

  @spec reserve(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def reserve(store, attrs) do
    transaction(store, fn tx ->
      with :ok <- valid_attrs(attrs),
           {:ok, task} <- TaskLedger.get(tx, attrs["task_key"]),
           true <- task["prompt_sha256"] == attrs["input_sha256"] or {:error, :worker_input_digest_mismatch},
           {:ok, run} <- RunLedger.get(tx, task["run_id"]),
           {:ok, access} <- WorkspaceAccess.get(tx, attrs["reservation_key"]),
           {:ok, _} <- WorkspaceAccess.validate(tx, access["reservation_key"], access["generation"]),
           true <- {access["task_key"], access["request_key"]} == {attrs["task_key"], attrs["request_key"]} or {:error, :worker_reservation_mismatch} do
        binding =
          Map.take(task, ~w(task_key run_id role stage model reasoning_effort prompt_sha256))
          |> Map.merge(Map.take(run, ~w(spec_revision contract_sha256)))
          |> Map.merge(Map.take(attrs, ~w(input_sha256 schema policy)))
          |> Map.merge(%{
            "reservation_key" => access["reservation_key"],
            "reservation_generation" => access["generation"],
            "expected_sha" => Jason.decode!(access["binding_json"])["expected_sha"],
            "mode" => access["mode"]
          })

        pin = Store.one!(tx, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])
        binding = Map.put(binding, "base_sha", (pin || %{})["base_sha"])

        reserve_binding(tx, attrs, binding)
      end
    end)
  end

  @doc "Reserves only a dedicated CI successor whose physical SOURCE was observed before its current transaction."
  @spec reserve_ci_successor(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def reserve_ci_successor(%DBConnection{} = tx, attrs, key) do
    with :ok <- valid_attrs(attrs),
         {:ok, entry} <- SymphonyElixir.Factory.TicketCiRepairSuccessor.journal(tx, key),
         true <- {attrs["request_key"], attrs["reservation_key"]} == {entry.row["new_request_key"], entry.row["new_reservation_key"]},
         {:ok, task} <- TaskLedger.get(tx, attrs["task_key"]),
         true <-
           task["task_key"] == entry.proof["prior_task"]["task_key"] and task["run_id"] == entry.row["run_id"] and task["status"] == "STARTING" and task["stage"] == "REPAIRING" and
             task["prompt_sha256"] == attrs["input_sha256"],
         {:ok, run} <- RunLedger.get(tx, task["run_id"]),
         true <- run == entry.proof["run"],
         {:ok, access} <- WorkspaceAccess.get(tx, attrs["reservation_key"]),
         true <- access["mode"] == "SOURCE" and is_nil(access["released_at"]) and access["request_key"] == attrs["request_key"] and access["task_key"] == task["task_key"],
         {:ok, old_access} <- WorkspaceAccess.get(tx, entry.proof["prior_access"]["reservation_key"]),
         {:ok, transfer} <- Jason.decode(old_access["release_receipt_json"] || "null"),
         true <-
           transfer["kind"] == "CI_EVIDENCE_SUCCESSOR_TRANSFER_V1" and transfer["ci_evidence_successor_key"] == key and transfer["new_request_key"] == attrs["request_key"] and
             transfer["new_reservation_key"] == access["reservation_key"] and transfer["new_generation"] == access["generation"],
         true <- Map.take(access, ~w(run_id task_key canonical_path git_dir common_dir)) == Map.take(entry.proof["prior_access"], ~w(run_id task_key canonical_path git_dir common_dir)),
         {:ok, original} <- decode_binding(entry.proof["prior_evidence"]["binding_json"]),
         true <- attrs["policy"] == original["policy"] and attrs["schema"] == original["schema"] do
      binding =
        Map.take(task, ~w(task_key run_id role stage model reasoning_effort prompt_sha256))
        |> Map.merge(Map.take(run, ~w(spec_revision contract_sha256)))
        |> Map.merge(Map.take(attrs, ~w(input_sha256 schema policy)))
        |> Map.merge(%{
          "reservation_key" => access["reservation_key"],
          "reservation_generation" => access["generation"],
          "expected_sha" => run["candidate_sha"],
          "mode" => "SOURCE",
          "base_sha" => original["base_sha"]
        })

      reserve_binding(tx, attrs, binding)
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_reservation_unproven}
    end
  end

  def reserve_ci_successor(_, _, _), do: {:error, :ci_successor_transaction_required}

  @doc "Reserves only the exact TCAP transfer already admitted by a fresh owned-tick observation."
  @spec reserve_capability(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def reserve_capability(%DBConnection{} = tx, attrs, resume) do
    with :ok <- valid_attrs(attrs),
         {:ok, verified} <- TicketCapabilityRecovery.reservation_facts(tx, resume),
         target = verified.checked["destination"],
         true <-
           {attrs["request_key"], attrs["reservation_key"], attrs["task_key"], attrs["input_sha256"]} ==
             {target["request_key"], target["reservation_key"], verified.task["task_key"], target["prompt_sha256"]},
         true <- attrs["schema"] == verified.binding["schema"] and attrs["policy"] == verified.binding["policy"] do
      binding =
        Map.take(verified.task, ~w(task_key run_id role stage model reasoning_effort prompt_sha256))
        |> Map.merge(Map.take(verified.run, ~w(spec_revision contract_sha256)))
        |> Map.merge(Map.take(attrs, ~w(input_sha256 schema policy)))
        |> Map.merge(%{
          "reservation_key" => verified.access["reservation_key"],
          "reservation_generation" => verified.access["generation"],
          "expected_sha" => verified.run["candidate_sha"],
          "base_sha" => verified.binding["base_sha"],
          "mode" => "SOURCE"
        })

      reserve_binding(tx, attrs, binding)
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_reservation_unproven}
    end
  end

  def reserve_capability(_, _, _), do: {:error, :capability_recovery_transaction_required}

  defp valid_attrs(attrs) when is_map(attrs) do
    if Map.keys(attrs) -- @fields == [] and Enum.all?(~w(request_key task_key reservation_key input_sha256 owner_id), &(is_binary(attrs[&1]) and attrs[&1] != "")) and is_map(attrs["schema"]) and
         is_map(attrs["policy"]), do: :ok, else: {:error, :invalid_worker_attempt}
  end

  defp valid_attrs(_attrs), do: {:error, :invalid_worker_attempt}

  defp reserve_binding(store, attrs, binding) do
    raw = Jason.encode!(binding)

    case row(store, attrs["request_key"]) do
      nil ->
        Store.query!(
          store,
          "INSERT INTO worker_evidence(request_key, task_key, run_id, reservation_key, binding_json, binding_sha256, status, owner_id, created_at) VALUES (?, ?, ?, ?, ?, ?, 'RESERVED', ?, ?)",
          [attrs["request_key"], attrs["task_key"], binding["run_id"], attrs["reservation_key"], raw, digest(raw), attrs["owner_id"], now()]
        )

        {:ok, row(store, attrs["request_key"])}

      existing ->
        if {existing["binding_json"], existing["owner_id"]} == {raw, attrs["owner_id"]},
          do: {:ok, existing},
          else: {:error, :worker_attempt_conflict}
    end
  end

  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(store, key) do
    case row(store, key) do
      nil -> {:error, :unknown_worker_attempt}
      evidence -> {:ok, evidence}
    end
  end

  @doc false
  @spec superseded_blocked_attempt?(Store.connection(), map()) :: boolean()
  def superseded_blocked_attempt?(store, evidence) do
    SymphonyElixir.Factory.FailedTurnRecovery.superseded?(store, evidence) or
      SymphonyElixir.Factory.TicketInfrastructureRecovery.superseded?(store, evidence) or
      TicketCapabilityRecovery.superseded?(store, evidence) or
      superseded_human_rework?(store, evidence) or
      SymphonyElixir.Factory.TicketCiRepairSuccessor.superseded?(store, evidence)
  end

  defp superseded_human_rework?(store, evidence) do
    access =
      Store.one!(
        store,
        "SELECT release_receipt_json FROM workspace_access WHERE reservation_key = ? AND request_key = ?",
        [evidence["reservation_key"], evidence["request_key"]]
      )

    with {:ok, transfer} <- Jason.decode((access || %{})["release_receipt_json"] || "null"),
         {:ok, command} <- get_rework_command(store, transfer["command_key"]),
         {:ok, application} <- Jason.decode(command["application_receipt_json"] || "null"),
         {:ok, new_evidence} <- get(store, transfer["new_request_key"]) do
      supersession_receipt_matches?(transfer, evidence, command, application) and
        resumed_evidence_matches?(new_evidence, evidence, application)
    else
      _ -> false
    end
  end

  defp supersession_receipt_matches?(transfer, evidence, command, application) do
    transfer["kind"] == "BLOCKED_SOURCE_TRANSFER" and transfer["old_request_key"] == evidence["request_key"] and
      transfer["old_reservation_key"] == evidence["reservation_key"] and transfer["output_sha256"] == evidence["output_sha256"] and
      transfer["input_key"] == command["input_key"] and transfer["disposition_key"] == application["disposition_key"] and
      command["status"] == "APPLIED" and application["kind"] == "BLOCKED_WRITER_RESUMED" and
      application["prior_request_key"] == evidence["request_key"]
  end

  defp resumed_evidence_matches?(new_evidence, evidence, application) do
    application["request_key"] == new_evidence["request_key"] and
      application["reservation_key"] == new_evidence["reservation_key"] and
      new_evidence["task_key"] == evidence["task_key"] and new_evidence["run_id"] == evidence["run_id"]
  end

  @spec pending(Store.connection(), String.t()) :: [map()]
  def pending(store, run_id) do
    %{columns: columns, rows: rows} = Store.query!(store, "SELECT * FROM worker_evidence WHERE run_id = ? AND status != 'CONSUMED' ORDER BY created_at, request_key", [run_id])

    rows
    |> Enum.map(&Map.new(Enum.zip(columns, &1)))
    |> Enum.reject(&superseded_blocked_attempt?(store, &1))
  end

  defp get_rework_command(store, key) when is_binary(key) do
    case Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [key]) do
      nil -> {:error, :unknown_ticket_command}
      command -> {:ok, command}
    end
  end

  defp get_rework_command(_store, _key), do: {:error, :unknown_ticket_command}

  @doc "Recovers a lost task result from its exact stopped attempt without launching or releasing source."
  @spec adopt_completed(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def adopt_completed(store, key) do
    transition(store, key, &adopt_completed_transaction/3)
  end

  defp adopt_completed_transaction(store, %{"status" => "CONSUMED"} = evidence, binding) do
    with {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         :ok <- adoption_scope(task, evidence, binding),
         :ok <- task_adopted(task, evidence),
         true <- owner_stopped?(store, evidence) or {:error, :worker_not_ready_for_consumption} do
      {:ok, task}
    end
  end

  defp adopt_completed_transaction(store, evidence, binding) do
    with :ok <- ready_for_consumption(store, evidence),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         :ok <- adoption_scope(task, evidence, binding),
         {:ok, output} <- Jason.decode(evidence["output_json"]),
         :ok <- StageSchemas.validate(output, binding["schema"]),
         :ok <- pinned_result(binding, output),
         {:ok, _} <- WorkspaceAccess.validate(store, evidence["reservation_key"], binding["reservation_generation"]) do
      adopt_task(store, task, evidence)
    end
  end

  defp completed_task_compatible(task, evidence) do
    result = Map.take(evidence, ~w(thread_id turn_id output_json))
    exact = Map.take(task, Map.keys(result)) == result
    compatible = Enum.all?(result, fn {key, value} -> is_nil(task[key]) or task[key] == value end)

    cond do
      task["status"] == "COMPLETE" and exact -> :ok
      task["status"] not in ~w(STARTING RUNNING STALE RETRY_PENDING WAITING_FOR_BROKER WAITING_FOR_WRITER) -> {:error, :worker_task_result_conflict}
      not compatible -> {:error, :worker_task_result_conflict}
      true -> :ok
    end
  end

  @doc "Reads one exact stopped result for controller classification without adopting or consuming its task."
  @spec completed_result(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def completed_result(store, key) do
    transition(store, key, &completed_result_transaction(&1, &2, &3))
  end

  @doc false
  @spec checkout_head(map()) :: {:ok, String.t()} | {:error, term()}
  def checkout_head(access) do
    case System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", access["canonical_path"], "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {head, 0} ->
        sha = String.trim(head)
        if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: {:ok, sha}, else: {:error, :worker_checkout_head_invalid}

      _ ->
        {:error, :worker_checkout_head_unavailable}
    end
  end

  defp completed_result_transaction(store, evidence, binding) do
    with :ok <- ready_for_consumption(store, evidence),
         {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         :ok <- adoption_scope(task, evidence, binding),
         :ok <- completed_task_compatible(task, evidence),
         {:ok, output} <- Jason.decode(evidence["output_json"]),
         :ok <- StageSchemas.validate(output, binding["schema"]),
         :ok <- pinned_result(binding, output),
         {:ok, access} <- WorkspaceAccess.validate(store, evidence["reservation_key"], binding["reservation_generation"]) do
      {:ok, %{run: run, task: task, evidence: evidence, binding: binding, output: output, access: access}}
    end
  end

  defp adoption_scope(task, evidence, binding) do
    if {task["task_key"], task["run_id"]} == {evidence["task_key"], evidence["run_id"]} and
         {binding["task_key"], binding["run_id"]} == {evidence["task_key"], evidence["run_id"]},
       do: :ok,
       else: {:error, :worker_adoption_scope_mismatch}
  end

  defp adopt_task(store, task, evidence) do
    result = Map.take(evidence, ~w(thread_id turn_id output_json))
    exact = Map.take(task, Map.keys(result)) == result
    compatible = Enum.all?(result, fn {key, value} -> is_nil(task[key]) or task[key] == value end)

    cond do
      task["status"] in ~w(COMPLETE CONSUMED) and exact ->
        {:ok, task}

      task["status"] not in ~w(STARTING RUNNING STALE RETRY_PENDING WAITING_FOR_BROKER WAITING_FOR_WRITER) ->
        {:error, :worker_task_result_conflict}

      not compatible ->
        {:error, :worker_task_result_conflict}

      true ->
        TaskLedger.update(store, task["task_key"], Map.merge(result, %{"status" => "COMPLETE", "failure_code" => nil}))
    end
  end

  @doc "Read-only exact verifier proof for the current task/candidate; old receipts never imply a new PASS."
  @spec verifier_receipt(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def verifier_receipt(store, run, task) do
    evidence =
      Store.one!(store, "SELECT * FROM worker_evidence WHERE task_key = ? AND run_id = ? AND thread_id = ? AND turn_id = ? ORDER BY created_at DESC LIMIT 1", [
        task["task_key"],
        run["run_id"],
        task["thread_id"],
        task["turn_id"]
      ])

    with true <- is_map(evidence) or {:error, :worker_receipt_missing},
         :ok <- intact(evidence),
         {:ok, binding} <- decode_binding(evidence["binding_json"]),
         {:ok, output} <- Jason.decode(evidence["output_json"] || "null"),
         :ok <- current_inputs(run, task, binding),
         :ok <- exact_verifier(store, run, task, evidence, binding, output) do
      {:ok, evidence}
    end
  end

  defp exact_verifier(store, run, task, evidence, binding, output) do
    pin = Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]]) || %{}
    current = {binding["role"], binding["mode"], binding["expected_sha"], binding["base_sha"]}
    expected = {"change-verifier", "REVIEW", run["candidate_sha"], pin["base_sha"]}
    ready = evidence["status"] in ~w(RESULT_RECORDED CONSUMED) and owner_stopped?(store, evidence)
    task_ready = task["status"] in ~w(COMPLETE CONSUMED) and task["output_json"] == evidence["output_json"]

    if current == expected and is_binary(pin["base_sha"]) and ready and task_ready do
      pinned_result(binding, output)
      |> then(fn
        :ok -> ReviewProtocol.validate_result(store, task, binding, output)
        error -> error
      end)
    else
      {:error, :worker_verifier_binding_unproven}
    end
  end

  @spec bind_thread(Store.connection(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def bind_thread(store, key, thread, policy) do
    transition(store, key, fn tx, evidence, binding ->
      cond do
        not is_binary(thread) or thread == "" -> {:error, :worker_thread_missing}
        Store.one!(tx, "SELECT chat_key FROM ticket_chats WHERE thread_id = ?", [thread]) != nil -> {:error, :worker_cannot_own_parent}
        binding["policy"] != policy -> {:error, :worker_effective_policy_mismatch}
        evidence["thread_id"] == thread and evidence["policy_json"] == Jason.encode!(policy) -> {:ok, evidence}
        evidence["status"] != "START_SENT" -> {:error, :worker_thread_conflict}
        true -> update(tx, key, "status = 'THREAD_BOUND', thread_id = ?, policy_json = ?", [thread, Jason.encode!(policy)])
      end
    end)
  end

  @spec mark_start_sent(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def mark_start_sent(store, key) do
    transition(store, key, fn tx, evidence, _binding ->
      if evidence["status"] == "RESERVED", do: update(tx, key, "status = 'START_SENT'", []), else: {:error, :worker_start_already_sent}
    end)
  end

  @spec bind_turn(Store.connection(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def bind_turn(store, key, thread, turn) do
    transition(store, key, fn tx, evidence, _binding ->
      cond do
        evidence["thread_id"] != thread ->
          {:error, :worker_event_thread_mismatch}

        not is_binary(turn) or turn == "" ->
          {:error, :worker_event_turn_missing}

        evidence["turn_id"] == turn ->
          {:ok, evidence}

        evidence["status"] != "THREAD_BOUND" ->
          {:error, :worker_event_turn_conflict}

        true ->
          record_turn(tx, key, thread, turn)
      end
    end)
  end

  defp record_turn(store, key, thread, turn) do
    with :ok <- unseen_turn(store, key, thread, turn) do
      update(store, key, "status = 'TURN_BOUND', turn_id = ?", [turn])
    end
  end

  @doc "Binds the actually owned process before its turn; never infer ownership from a later result."
  @spec bind_owner_process(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def bind_owner_process(store, key, process) do
    transition(store, key, fn tx, evidence, _binding ->
      raw = Jason.encode!(process)

      cond do
        not valid_process?(process) -> {:error, :worker_process_identity_invalid}
        evidence["owner_process_json"] == raw -> {:ok, evidence}
        evidence["owner_process_json"] != nil or evidence["status"] != "THREAD_BOUND" -> {:error, :worker_process_identity_conflict}
        true -> update(tx, key, "owner_process_json = ?", [raw])
      end
    end)
  end

  defp valid_process?(%{"pid" => pid, "invocation_nonce" => nonce} = process) do
    Map.keys(process) -- ~w(pid invocation_nonce) == [] and is_binary(pid) and pid != "" and is_binary(nonce) and Regex.match?(~r/\A[0-9a-f]{64}\z/, nonce)
  end

  defp valid_process?(_process), do: false

  @spec record_result(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_result(store, key, result) do
    transition(store, key, &record_result_transaction(&1, &2, &3, result))
  end

  defp record_result_transaction(store, evidence, binding, result) do
    with :ok <- result_identity(evidence, result),
         true <- (is_binary(result[:item_id]) and result[:item_id] != "") or {:error, :worker_result_item_missing},
         :ok <- StageSchemas.validate(result[:output], binding["schema"]),
         :ok <- pinned_result(binding, result[:output]) do
      persist_result(store, evidence, result)
    end
  end

  defp result_identity(evidence, result) do
    expected = {evidence["thread_id"], evidence["turn_id"]}

    if expected == {result[:thread_id], result[:turn_id]} and evidence["turn_id"] != nil,
      do: :ok,
      else: {:error, :worker_result_identity_mismatch}
  end

  defp persist_result(store, evidence, result) do
    raw = Jason.encode!(result[:output])
    duplicate = {evidence["output_json"], evidence["item_id"]} == {raw, result[:item_id]}

    cond do
      evidence["status"] in ~w(RESULT_RECORDED CONSUMED) and duplicate -> {:ok, evidence}
      evidence["status"] != "TURN_BOUND" -> {:error, :worker_result_conflict}
      true -> update(store, evidence["request_key"], "status = 'RESULT_RECORDED', item_id = ?, output_json = ?, output_sha256 = ?", [result[:item_id], raw, digest(raw)])
    end
  end

  defp pinned_result(%{"role" => role, "expected_sha" => sha}, output) when role in ~w(change-verifier manual-validator) do
    if output["candidate_sha"] == sha, do: :ok, else: {:error, :worker_review_candidate_mismatch}
  end

  defp pinned_result(_binding, _output), do: :ok

  @doc "Only the owned invocation's shutdown path records stop; an absent PID is not evidence."
  @spec record_owner_stopped(Store.connection(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_owner_stopped(store, key, owner, proof) do
    transition(store, key, fn tx, evidence, _binding ->
      cond do
        evidence["owner_id"] != owner -> {:error, :worker_owner_mismatch}
        not valid_stop(tx, evidence, proof) -> {:error, :worker_stop_receipt_invalid}
        evidence["owner_stopped_at"] != nil and evidence["owner_stop_json"] == Jason.encode!(proof) -> {:ok, evidence}
        evidence["owner_stopped_at"] != nil -> {:error, :worker_stop_receipt_conflict}
        evidence["status"] != "RESULT_RECORDED" -> {:error, :worker_completion_unproven}
        true -> update(tx, key, "owner_stopped_at = ?, owner_stop_json = ?", [now(), Jason.encode!(proof)])
      end
    end)
  end

  defp valid_stop(store, evidence, proof) when is_map(proof) do
    access = Store.one!(store, "SELECT canonical_path FROM workspace_access WHERE reservation_key = ?", [evidence["reservation_key"]])
    keys = ~w(transport thread_id pid invocation_nonce exit_status cwd)
    identity = {proof["transport"], proof["thread_id"], proof["cwd"]}
    expected = {"owned_app_server", evidence["thread_id"], (access || %{})["canonical_path"]}
    process = Jason.decode(evidence["owner_process_json"] || "null")

    Map.keys(proof) -- keys == [] and identity == expected and process == {:ok, Map.take(proof, ~w(pid invocation_nonce))} and valid_process?(Map.take(proof, ~w(pid invocation_nonce))) and
      is_integer(proof["exit_status"])
  end

  defp valid_stop(_store, _evidence, _proof), do: false

  @doc false
  @spec owner_stopped?(Store.connection(), map()) :: boolean()
  def owner_stopped?(store, evidence) do
    with true <- is_binary(evidence["owner_stopped_at"]),
         raw when is_binary(raw) <- evidence["owner_stop_json"],
         {:ok, proof} <- Jason.decode(raw) do
      valid_stop(store, evidence, proof)
    else
      _ -> false
    end
  end

  @spec reconcile_required(Store.connection(), String.t(), term(), map() | nil) :: {:ok, map()} | {:error, term()}
  def reconcile_required(store, key, reason, observed \\ nil) do
    transaction(store, &reconcile_failed_attempt(&1, key, reason, observed))
  end

  defp reconcile_failed_attempt(tx, key, reason, observed) do
    with {:ok, evidence} <- get(tx, key),
         true <- evidence["status"] != "CONSUMED" or {:error, :worker_already_consumed} do
      {:ok, failed} = update(tx, key, "status = 'RECONCILE_REQUIRED', failure_code = ?", [inspect(reason)])

      record_resume_outcome(tx, failed, reason)

      if failed_stop_matches?(tx, failed, observed) and is_nil(failed["owner_stopped_at"]),
        do: update(tx, key, "owner_stopped_at = ?, owner_stop_json = ?", [now(), Jason.encode!(observed.owner_stop)])

      SpecialistErrorNotice.record(tx, key, reason)
      get(tx, failed["request_key"])
    end
  end

  defp record_resume_outcome(store, evidence, {kind, _} = reason) when kind in [:native_resume_refused, :response_error] do
    refusal =
      case SymphonyElixir.Codex.ResumeRefusal.details(reason) do
        {:ok, observed} -> observed
        :unclassified -> nil
      end

    binding = Jason.decode!(evidence["binding_json"])

    payload = %{
      kind: "NATIVE_RESUME_FAILURE_OBSERVATION_V1",
      request_key: evidence["request_key"],
      task_key: evidence["task_key"],
      run_id: evidence["run_id"],
      binding_sha256: evidence["binding_sha256"],
      input_sha256: binding["input_sha256"],
      reservation_generation: binding["reservation_generation"],
      refusal: refusal,
      refusal_parsed_json_sha256: digest(Jason.encode!(refusal)),
      failure_code: evidence["failure_code"],
      failure_sha256: digest(evidence["failure_code"])
    }

    Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?, 'TICKET_WORKER_RESUME_FAILURE_OBSERVED', ?, ?)", [now(), evidence["run_id"], Jason.encode!(payload)])
  end

  defp record_resume_outcome(_store, _evidence, _reason), do: :ok

  @doc "Retains a genuine bound-session or exact-turn shutdown without inventing a turn or result."
  @spec record_failed_stop(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_failed_stop(store, key, observed) do
    transaction(store, &retain_failed_stop(&1, key, observed))
  end

  defp retain_failed_stop(tx, key, observed) do
    with {:ok, evidence} <- get(tx, key),
         true <- failed_stop_matches?(tx, evidence, observed) do
      if evidence["owner_stopped_at"], do: {:ok, evidence}, else: update(tx, key, "owner_stopped_at = ?, owner_stop_json = ?", [now(), Jason.encode!(observed.owner_stop)])
    else
      _ -> {:error, :worker_failed_stop_unproven}
    end
  end

  defp failed_stop_matches?(store, evidence, observed) when is_map(observed) do
    evidence["status"] == "RECONCILE_REQUIRED" and
      {observed[:thread_id], observed[:turn_id], Jason.encode!(observed[:policy])} == {evidence["thread_id"], evidence["turn_id"], evidence["policy_json"]} and
      failed_identity_bound?(evidence) and is_nil(evidence["output_json"]) and valid_stop(store, evidence, observed[:owner_stop]) and
      (is_nil(evidence["owner_stop_json"]) or evidence["owner_stop_json"] == Jason.encode!(observed[:owner_stop]))
  end

  defp failed_stop_matches?(_store, _evidence, _observed), do: false

  defp failed_identity_bound?(%{"turn_id" => nil} = evidence),
    do: is_binary(evidence["thread_id"]) and evidence["thread_id"] != "" and is_nil(evidence["item_id"]) and is_nil(evidence["output_sha256"])

  defp failed_identity_bound?(evidence), do: is_binary(evidence["turn_id"])

  @doc "Rearms only an exact pre-session resume rejection; ambiguous starts remain protected."
  @spec rearm_rejected_resume(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def rearm_rejected_resume(store, key) do
    transition(store, key, fn tx, evidence, binding ->
      {:ok, task} = TaskLedger.get(tx, evidence["task_key"])
      {:ok, run} = RunLedger.get(tx, evidence["run_id"])
      reason = resume_rejection_reason(tx, evidence, binding, task)

      with true <- evidence["status"] == "RECONCILE_REQUIRED" and task["status"] == "STALE",
           true <- is_binary(task["thread_id"]) and task["thread_id"] != "",
           true <- is_binary(reason) and {evidence["failure_code"], task["failure_code"]} == {reason, reason},
           true <- {run["execution_mode"], run["state"], binding["role"], binding["mode"]} == {"TICKET_SUPERVISOR_V1", "WRITING", "feature-writer", "SOURCE"},
           true <- Enum.all?(~w(thread_id turn_id item_id output_json output_sha256 policy_json owner_process_json owner_stopped_at owner_stop_json), &is_nil(evidence[&1])),
           [current] <- pending(tx, evidence["run_id"]),
           true <- current["request_key"] == key,
           %{"n" => 0} <- Store.one!(tx, "SELECT COUNT(*) AS n FROM worker_file_operations WHERE request_key = ?", [key]),
           {:ok, _} <- WorkspaceAccess.validate(tx, evidence["reservation_key"], binding["reservation_generation"]),
           :ok <- resume_retry_due(task),
           {:ok, _} <- TaskLedger.update(tx, task["task_key"], %{status: "STARTING", failure_code: nil}) do
        Store.query!(tx, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_WORKER_RESUME_REARMED', ?, ?)", [
          now(),
          evidence["run_id"],
          Jason.encode!(%{request_key: key, task_key: task["task_key"], thread_id: task["thread_id"], prior_turn_id: task["turn_id"], failure_code: reason, binding_sha256: evidence["binding_sha256"]})
        ])

        update(tx, key, "status = 'RESERVED', failure_code = NULL", [])
      else
        {:error, _} = error -> error
        _ -> {:error, :worker_resume_rejection_unproven}
      end
    end)
  end

  defp resume_rejection_reason(store, evidence, binding, task) do
    case Store.one!(store, "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_RESUME_FAILURE_OBSERVED' AND json_extract(payload_json,'$.request_key')=? ORDER BY id DESC LIMIT 1", [
           evidence["request_key"]
         ]) do
      nil ->
        inspect({:response_error, %{"code" => -32_600, "message" => "thread #{task["thread_id"]} already has an active writer"}})

      %{"payload_json" => raw} ->
        with {:ok, observed} when is_map(observed) <- Jason.decode(raw),
             true <- observed["kind"] == "NATIVE_RESUME_FAILURE_OBSERVATION_V1",
             true <- Map.take(observed, ~w(request_key task_key run_id binding_sha256)) == Map.take(evidence, ~w(request_key task_key run_id binding_sha256)),
             true <- observed["input_sha256"] == binding["input_sha256"] and observed["reservation_generation"] == binding["reservation_generation"],
             {:ok, refusal} <- SymphonyElixir.Codex.ResumeRefusal.details({:native_resume_refused, observed["refusal"]}),
             true <- observed["refusal_parsed_json_sha256"] == digest(Jason.encode!(refusal)),
             true <- refusal["requested_thread_id"] == task["thread_id"],
             true <- is_binary(observed["failure_code"]) and observed["failure_sha256"] == digest(observed["failure_code"]) do
          observed["failure_code"]
        else
          _ -> nil
        end
    end
  end

  defp resume_retry_due(task) do
    case DateTime.from_iso8601(task["updated_at"] || "") do
      {:ok, at, _} -> if DateTime.diff(DateTime.utc_now(), at) >= 180, do: :ok, else: {:error, :worker_resume_retry_not_due}
      _ -> {:error, :worker_resume_retry_time_unproven}
    end
  end

  defp unseen_turn(store, key, thread, turn) do
    if Store.one!(store, "SELECT request_key FROM worker_evidence WHERE request_key != ? AND thread_id = ? AND turn_id = ?", [key, thread, turn]) == nil,
      do: :ok,
      else: {:error, :worker_turn_already_used}
  end

  @doc "Recover the same known turn and owned process; never restart creation to repair an uncertain result."
  @spec reconcile_completed(Store.connection(), String.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_completed(store, key, owner, result, stop) do
    transition(store, key, fn tx, evidence, binding ->
      with true <- evidence["status"] == "RECONCILE_REQUIRED" or {:error, :worker_reconciliation_not_pending},
           true <- evidence["owner_id"] == owner or {:error, :worker_owner_mismatch},
           :ok <- recovered_preimage(tx, evidence, binding, result[:reconciliation_preimage]),
           :ok <- result_identity(evidence, result),
           true <- (is_binary(result[:item_id]) and result[:item_id] != "") or {:error, :worker_result_item_missing},
           :ok <- StageSchemas.validate(result[:output], binding["schema"]),
           :ok <- pinned_result(binding, result[:output]),
           raw = Jason.encode!(result[:output]),
           :ok <- recovered_output(evidence, raw, result[:item_id]),
           true <- valid_stop(tx, evidence, stop) or {:error, :worker_stop_receipt_invalid},
           true <- is_nil(evidence["owner_stop_json"]) or evidence["owner_stop_json"] == Jason.encode!(stop) or {:error, :worker_stop_receipt_conflict} do
        if provenance = result[:native_recovery] do
          Store.query!(tx, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?, 'TICKET_WORKER_NATIVE_COMPLETION_RECOVERED', ?, ?)", [
            now(),
            evidence["run_id"],
            Jason.encode!(Map.merge(provenance, %{thread_id: result.thread_id, turn_id: result.turn_id, item_id: result.item_id, output_sha256: digest(raw)}))
          ])
        end

        update(
          tx,
          key,
          "status = 'RESULT_RECORDED', item_id = ?, output_json = ?, output_sha256 = ?, owner_stopped_at = COALESCE(owner_stopped_at, ?), owner_stop_json = COALESCE(owner_stop_json, ?), failure_code = NULL",
          [
            result[:item_id],
            raw,
            digest(raw),
            now(),
            Jason.encode!(stop)
          ]
        )
      end
    end)
  end

  defp recovered_preimage(_store, _evidence, _binding, nil), do: :ok

  defp recovered_preimage(store, evidence, binding, before) when is_map(before) do
    with {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         [current] <- pending(store, evidence["run_id"]),
         true <- current == evidence,
         {:ok, access} <- WorkspaceAccess.validate(store, evidence["reservation_key"], binding["reservation_generation"]),
         {:ok, stop} <- Jason.decode(evidence["owner_stop_json"]),
         true <- %{evidence: evidence, binding: binding, run: run, task: task, access: access, stop: stop} == before do
      :ok
    else
      _ -> {:error, :completed_turn_inputs_changed}
    end
  end

  defp recovered_preimage(_store, _evidence, _binding, _before), do: {:error, :completed_turn_inputs_changed}

  defp recovered_output(evidence, raw, item) do
    if evidence["output_json"] == nil or {evidence["output_json"], evidence["item_id"]} == {raw, item},
      do: :ok,
      else: {:error, :worker_result_conflict}
  end

  @doc "Reserves a controller-selected check without changing source-task or delivery state."
  @spec prepare_check(Store.connection(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_check(store, key, action) do
    transition(store, key, &prepare_check_transaction(&1, &2, &3, action))
  end

  defp prepare_check_transaction(store, evidence, binding, action) do
    with {:ok, scope, access} <- check_scope(store, evidence, binding),
         {:ok, policy} <- WorkerCheckIO.policy(action, access["canonical_path"]) do
      identity = Map.merge(scope, policy)
      key = "check:" <> digest(Jason.encode!(identity))

      case check_row(store, key) do
        nil -> reserve_check(store, key, evidence, access, identity)
        row -> reuse_check(row, identity)
      end
    end
  end

  defp reuse_check(row, identity) do
    if intact_check?(row) and Map.take(Jason.decode!(row["binding_json"]), Map.keys(identity)) == identity, do: {:ok, row}, else: {:error, :controller_check_binding_changed}
  end

  defp reserve_check(store, key, evidence, access, identity) do
    with :ok <- checks_stopped(store, evidence["reservation_key"]),
         {:ok, transport} <- WorkerCheckIO.prepare(store, access["canonical_path"]) do
      binding = Map.merge(identity, transport) |> Map.put("check_key", key)
      raw = Jason.encode!(binding)

      Store.query!(store, "INSERT INTO controller_checks(check_key, worker_request_key, reservation_key, binding_json, binding_sha256, phase) VALUES (?, ?, ?, ?, ?, 'PREPARED')", [
        key,
        evidence["request_key"],
        evidence["reservation_key"],
        raw,
        digest(raw)
      ])

      {:ok, check_row(store, key)}
    end
  end

  defp check_scope(store, evidence, binding) do
    with :ok <- ready_for_consumption(store, evidence),
         true <- binding["role"] in ~w(feature-writer change-verifier) or {:error, :controller_check_role_unsupported},
         true <-
           Store.one!(store, "SELECT call_id FROM worker_file_operations WHERE request_key = ? AND (phase = 'PREPARED' OR io_pending = 1)", [evidence["request_key"]]) == nil or
             {:error, :worker_file_edits_unreconciled},
         {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         pin when is_map(pin) <- Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [evidence["run_id"]]),
         true <- (is_binary(run["candidate_sha"]) and pin["base_sha"] == binding["base_sha"]) or {:error, :controller_check_candidate_unproven},
         {:ok, access} <-
           WorkspaceAccess.validate(store, evidence["reservation_key"], binding["reservation_generation"], clean: true, candidate_adopted: true) do
      scope =
        Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256))
        |> Map.merge(%{
          "base_sha" => pin["base_sha"],
          "worker_request_key" => evidence["request_key"],
          "worker_binding_sha256" => evidence["binding_sha256"],
          "worker_output_sha256" => evidence["output_sha256"],
          "worker_stop_sha256" => digest(evidence["owner_stop_json"]),
          "reservation_key" => access["reservation_key"],
          "generation" => access["generation"],
          "workspace_binding_sha256" => digest(access["binding_json"]),
          "cwd" => access["canonical_path"]
        })

      {:ok, scope, access}
    else
      nil -> {:error, :ticket_review_base_missing}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec start_check(Store.connection(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def start_check(store, key, pid) when is_integer(pid) and pid > 0 do
    check_transition(store, key, fn tx, row ->
      if row["phase"] == "PREPARED" and is_nil(row["helper_pid"]) do
        Store.query!(tx, "UPDATE controller_checks SET phase = 'RUNNING', helper_pid = ? WHERE check_key = ?", [pid, key])
        {:ok, check_row(tx, key)}
      else
        {:error, :controller_check_already_started}
      end
    end)
  end

  @doc false
  @spec finish_check(Store.connection(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def finish_check(store, key, raw) do
    check_transition(store, key, &finish_check_transaction(&1, &2, raw))
  end

  defp finish_check_transaction(store, row, raw) do
    binding = Jason.decode!(row["binding_json"])

    cond do
      not WorkerCheckIO.receipt_valid?(raw, binding, row["helper_pid"]) ->
        {:error, :controller_check_receipt_unproven}

      row["phase"] == "COMPLETE" ->
        if row["receipt_json"] == raw, do: {:ok, row}, else: {:error, :controller_check_receipt_conflict}

      row["phase"] in ~w(RUNNING RECONCILE_REQUIRED) ->
        Store.query!(store, "UPDATE controller_checks SET phase = 'COMPLETE', receipt_json = ?, receipt_sha256 = ?, error = NULL WHERE check_key = ?", [raw, digest(raw), row["check_key"]])
        {:ok, check_row(store, row["check_key"])}

      true ->
        {:error, :controller_check_not_started}
    end
  end

  @doc false
  @spec uncertain_check(Store.connection(), String.t(), term()) :: {:error, term()}
  def uncertain_check(store, key, reason) do
    Store.query!(store, "UPDATE controller_checks SET phase = 'RECONCILE_REQUIRED', error = ? WHERE check_key = ? AND phase != 'COMPLETE'", [inspect(reason), key])
    {:error, reason}
  end

  defp check_transition(store, key, fun) do
    case check_row(store, key) do
      nil ->
        {:error, :unknown_controller_check}

      row ->
        transition(store, row["worker_request_key"], &check_current(&1, &2, &3, key, fun))
    end
  end

  defp check_current(store, evidence, binding, key, fun) do
    row = check_row(store, key)

    with true <- intact_check?(row) or {:error, :controller_check_binding_changed},
         {:ok, scope, _} <- check_scope(store, evidence, binding),
         true <- Map.take(Jason.decode!(row["binding_json"]), Map.keys(scope)) == scope or {:error, :controller_check_binding_changed} do
      fun.(store, row)
    end
  end

  defp check_row(store, key), do: Store.one!(store, "SELECT * FROM controller_checks WHERE check_key = ?", [key])

  defp intact_check?(row) do
    with {:ok, binding} when is_map(binding) <- Jason.decode(row["binding_json"]),
         true <- digest(row["binding_json"]) == row["binding_sha256"] do
      intact_check_receipt?(row, binding)
    else
      _ -> false
    end
  end

  defp intact_check_receipt?(%{"phase" => "COMPLETE"} = row, binding) do
    is_binary(row["receipt_json"]) and digest(row["receipt_json"]) == row["receipt_sha256"] and
      WorkerCheckIO.receipt_valid?(row["receipt_json"], binding, row["helper_pid"])
  end

  defp intact_check_receipt?(row, _binding), do: is_nil(row["receipt_json"]) and is_nil(row["receipt_sha256"])

  @doc false
  @spec checks_stopped(Store.connection(), String.t()) :: :ok | {:error, term()}
  def checks_stopped(store, reservation) do
    result = Store.query!(store, "SELECT * FROM controller_checks WHERE reservation_key = ?", [reservation])
    rows = Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    if Enum.all?(rows, &(&1["phase"] == "COMPLETE" and intact_check?(&1))), do: :ok, else: {:error, :controller_checks_unreconciled}
  end

  @doc "Consume only after controller adoption and task consumption; releases checkout atomically."
  @spec consume(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def consume(store, key) do
    transition(store, key, &consume_transaction/3)
  end

  defp consume_transaction(_store, %{"status" => "CONSUMED"} = evidence, _binding), do: {:ok, evidence}

  defp consume_transaction(store, evidence, binding) do
    key = evidence["request_key"]

    with :ok <- ready_for_consumption(store, evidence),
         :ok <- checks_stopped(store, evidence["reservation_key"]),
         true <-
           Store.one!(store, "SELECT call_id FROM worker_file_operations WHERE request_key = ? AND (phase = 'PREPARED' OR io_pending = 1)", [key]) == nil or {:error, :worker_file_edits_unreconciled},
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         :ok <- task_adopted(task, evidence),
         {:ok, adopted_sha} <- consumed_candidate(run, binding),
         {:ok, access} <- WorkspaceAccess.validate(store, evidence["reservation_key"], binding["reservation_generation"], clean: true),
         :ok <- adopted_head(store, access, adopted_sha),
         {:ok, consumed} <- update(store, key, "status = 'CONSUMED', consumed_at = ?", [now()]),
         {:ok, _} <- WorkspaceAccess.release(store, access["reservation_key"], access["generation"], key) do
      {:ok, consumed}
    end
  end

  defp consumed_candidate(%{"candidate_sha" => nil}, %{"role" => "feature-planner", "mode" => "REVIEW", "expected_sha" => sha, "base_sha" => sha}) when is_binary(sha), do: {:ok, sha}

  defp consumed_candidate(run, %{"mode" => "REVIEW", "expected_sha" => sha}) do
    if run["candidate_sha"] == sha, do: {:ok, sha}, else: {:error, :worker_review_candidate_mismatch}
  end

  defp consumed_candidate(run, _binding), do: {:ok, run["candidate_sha"]}

  defp ready_for_consumption(store, evidence) do
    if evidence["status"] == "RESULT_RECORDED" and owner_stopped?(store, evidence),
      do: :ok,
      else: {:error, :worker_not_ready_for_consumption}
  end

  defp task_adopted(task, evidence) do
    exact = Map.take(task, ~w(output_json thread_id turn_id)) == Map.take(evidence, ~w(output_json thread_id turn_id))
    if task["status"] == "CONSUMED" and exact, do: :ok, else: {:error, :worker_adoption_not_proven}
  end

  defp adopted_head(_store, access, sha) do
    case System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", access["canonical_path"], "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {head, 0} when is_binary(sha) -> if String.trim(head) == sha, do: :ok, else: {:error, :worker_candidate_not_adopted}
      _ -> {:error, :worker_candidate_not_adopted}
    end
  end

  defp transition(store, key, fun) do
    transaction(store, fn tx ->
      with {:ok, evidence} <- get(tx, key),
           :ok <- intact(evidence),
           {:ok, binding} <- decode_binding(evidence["binding_json"]),
           {:ok, run} <- RunLedger.get(tx, evidence["run_id"]),
           {:ok, task} <- TaskLedger.get(tx, evidence["task_key"]),
           :ok <- current_inputs(run, task, binding) do
        fun.(tx, evidence, binding)
      end
    end)
  end

  defp intact(evidence) do
    binding = digest(evidence["binding_json"]) == evidence["binding_sha256"]
    output = is_nil(evidence["output_json"]) or digest(evidence["output_json"]) == evidence["output_sha256"]
    if binding and output, do: :ok, else: {:error, :worker_evidence_corrupt}
  end

  defp decode_binding(raw) do
    case Jason.decode(raw) do
      {:ok, binding} when is_map(binding) -> {:ok, binding}
      _ -> {:error, :worker_evidence_corrupt}
    end
  end

  defp current_inputs(run, task, binding) do
    run_keys = ~w(spec_revision contract_sha256)
    task_keys = ~w(role stage model reasoning_effort prompt_sha256)

    if Map.take(run, run_keys) == Map.take(binding, run_keys) and Map.take(task, task_keys) == Map.take(binding, task_keys),
      do: :ok,
      else: {:error, :worker_inputs_changed}
  end

  defp update(store, key, assignment, params) do
    Store.query!(store, "UPDATE worker_evidence SET #{assignment} WHERE request_key = ?", params ++ [key])
    {:ok, row(store, key)}
  end

  defp row(store, key), do: Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [key])
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp transaction(store, fun) do
    case Exqlite.transaction(store, fn tx -> rollback_error(tx, fun.(tx)) end, timeout: 60_000) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result
end
