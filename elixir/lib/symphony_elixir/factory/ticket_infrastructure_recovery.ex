defmodule SymphonyElixir.Factory.TicketInfrastructureRecovery do
  @moduledoc "Exact recovery of a stopped writer with reconciled edits, under infrastructure or explicit operator authority."
  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLedger, TicketChat, WorkerEvidence, WorkerFileIO, WorkerFileTools, WorkspaceAccess}

  @body "Controller-authorized infrastructure recovery: file IO receipts have been reconciled. Preserve all existing edits and resume the unfinished slice under the unchanged contract. This is not a new human answer or product decision."
  @run_fields ~w(run_id state candidate_sha implementation_iteration spec_revision contract_sha256 worktree branch)

  @spec authorize(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def authorize(store, request_key), do: authorize(store, request_key, nil)

  @doc "Authorizes one continuation with recorded operator guidance; never changes contract, paths, or runtime permissions."
  @spec authorize(Store.connection(), String.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def authorize(store, request_key, operator) do
    Store.transaction!(store, fn tx ->
      with {:ok, completed} <- WorkerEvidence.completed_result(tx, request_key),
           :ok <- recoverable(tx, completed, operator),
           :ok <- WorkerFileTools.reconcile(tx, request_key),
           {:ok, files} <- files(tx, completed),
           disposition when is_map(disposition) <- disposition(tx, completed.run["run_id"], request_key) do
        proof = %{
          "kind" => "RECONCILED_FILE_IO_RECOVERY",
          "request_key" => request_key,
          "disposition_key" => disposition["disposition_key"],
          "run" => Map.take(completed.run, @run_fields),
          "task" => Map.take(completed.task, ~w(task_key thread_id turn_id prompt_sha256)),
          "output_sha256" => completed.evidence["output_sha256"],
          "binding_sha256" => completed.evidence["binding_sha256"],
          "files" => files
        }

        proof = if operator, do: Map.put(proof, "operator_guidance", operator), else: proof
        key = "TINF-" <> digest(Jason.encode!(proof))
        proof = Map.put(proof, "recovery_key", key)

        case find(tx, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["request_key"] == request_key)) do
          existing when existing == nil or existing == proof -> persist(tx, completed.run["run_id"], "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", proof)
          _ -> {:error, :infrastructure_recovery_conflict}
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :infrastructure_recovery_disposition_unproven}
      end
    end)
  end

  @spec resume(Store.connection(), String.t()) :: {:ok, map()} | :none | {:error, term()}
  def resume(store, request_key) do
    case find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["request_key"] == request_key)) do
      nil ->
        :none

      proof ->
        with :ok <- preflight(store, proof["recovery_key"]) do
          {:ok, descriptor(proof)}
        end
    end
  end

  @spec preflight(Store.connection(), String.t()) :: :ok | {:error, term()}
  def preflight(store, key) do
    with proof when is_map(proof) <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["recovery_key"] == key)),
         true <- key == "TINF-" <> digest(Jason.encode!(Map.delete(proof, "recovery_key"))),
         {:ok, completed} <- WorkerEvidence.completed_result(store, proof["request_key"]),
         :ok <- recoverable(store, completed, proof["operator_guidance"]),
         true <- Map.take(completed.run, @run_fields) == proof["run"],
         true <- Map.take(completed.task, ~w(task_key thread_id turn_id prompt_sha256)) == proof["task"],
         true <- {completed.evidence["output_sha256"], completed.evidence["binding_sha256"]} == {proof["output_sha256"], proof["binding_sha256"]},
         {:ok, observed} <- files(store, completed),
         true <- observed == proof["files"],
         true <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_APPLIED", &(&1["recovery_key"] == key)) == nil do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :infrastructure_recovery_binding_changed}
    end
  end

  @spec record_transfer(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_transfer(store, key, transfer) do
    with proof when is_map(proof) <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["recovery_key"] == key)),
         true <- {transfer["old_request_key"], transfer["output_sha256"], transfer["disposition_key"]} == {proof["request_key"], proof["output_sha256"], proof["disposition_key"]},
         {:ok, old} <- WorkerEvidence.get(store, proof["request_key"]),
         true <- source_transfer_proven?(store, old, transfer, key),
         {:ok, attempt} <- WorkerEvidence.get(store, transfer["new_request_key"]),
         true <- attempt["status"] == "RESERVED" and attempt["task_key"] == old["task_key"],
         receipt =
           Map.merge(transfer, %{
             "recovery_key" => key,
             "prior_request_key" => old["request_key"],
             "request_key" => attempt["request_key"],
             "reservation_key" => attempt["reservation_key"],
             "reservation_generation" => transfer["new_generation"]
           }) do
      persist(store, old["run_id"], "TICKET_INFRASTRUCTURE_RECOVERY_APPLIED", receipt)
    else
      {:error, _} = error -> error
      _ -> {:error, :infrastructure_recovery_transfer_unproven}
    end
  end

  @spec applied(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def applied(store, key) do
    with proof when is_map(proof) <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["recovery_key"] == key)),
         receipt when is_map(receipt) <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_APPLIED", &(&1["recovery_key"] == key)),
         true <- receipt["prior_request_key"] == proof["request_key"] and receipt["output_sha256"] == proof["output_sha256"],
         {:ok, old} <- WorkerEvidence.get(store, proof["request_key"]),
         true <- WorkerEvidence.superseded_blocked_attempt?(store, old),
         {:ok, attempt} <- WorkerEvidence.get(store, receipt["request_key"]),
         {:ok, binding} <- Jason.decode(attempt["binding_json"]),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         true <- Map.take(run, @run_fields) == proof["run"],
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         true <- task["thread_id"] == proof["task"]["thread_id"] and task["prompt_sha256"] == binding["prompt_sha256"],
         true <- attempt["reservation_key"] == receipt["reservation_key"],
         {:ok, access} <- WorkspaceAccess.validate(store, receipt["reservation_key"], receipt["reservation_generation"]),
         :ok <- recheck_reserved_source(store, attempt, access, proof, receipt) do
      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :infrastructure_recovery_replay_unproven}
    end
  end

  @spec prepared(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepared(store, attempt, transfer) do
    with {:ok, receipt} <- applied(store, transfer["operational_recovery_key"]),
         true <- receipt["request_key"] == attempt["request_key"],
         proof <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["recovery_key"] == receipt["recovery_key"])) do
      {:ok,
       Map.merge(descriptor(proof), %{
         "prepared" => true,
         "prepared_request_key" => attempt["request_key"],
         "prepared_reservation_key" => attempt["reservation_key"],
         "prepared_reservation_generation" => receipt["reservation_generation"],
         "checkout_head_sha" => receipt["checkout_head_sha"]
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :infrastructure_recovery_replay_unproven}
    end
  end

  @spec body() :: String.t()
  def body, do: @body

  @spec body(Store.connection(), String.t()) :: String.t()
  def body(store, key) do
    proof = find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["recovery_key"] == key))
    get_in(proof || %{}, ["operator_guidance", "instruction"]) || @body
  end

  @spec superseded?(Store.connection(), map()) :: boolean()
  def superseded?(store, evidence) do
    with receipt when is_map(receipt) <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_APPLIED", &(&1["prior_request_key"] == evidence["request_key"])),
         proof when is_map(proof) <- find(store, "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED", &(&1["recovery_key"] == receipt["recovery_key"])),
         true <- proof["recovery_key"] == "TINF-" <> digest(Jason.encode!(Map.delete(proof, "recovery_key"))),
         true <- {proof["request_key"], proof["output_sha256"], proof["binding_sha256"]} == {evidence["request_key"], evidence["output_sha256"], evidence["binding_sha256"]},
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         true <- source_transfer_proven?(store, evidence, receipt, receipt["recovery_key"]),
         {:ok, attempt} <- WorkerEvidence.get(store, receipt["request_key"]) do
      attempt["task_key"] == evidence["task_key"] and attempt["run_id"] == evidence["run_id"] and attempt["reservation_key"] == receipt["new_reservation_key"]
    else
      _ -> false
    end
  end

  defp source_transfer_proven?(store, old, receipt, key) do
    fields = ~w(kind old_request_key old_reservation_key new_request_key new_reservation_key disposition_key output_sha256 checkout_head_sha operational_recovery_key)

    with {:ok, access} <- WorkspaceAccess.get(store, old["reservation_key"]),
         true <- is_binary(access["released_at"]),
         {:ok, transfer} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- transfer["operational_recovery_key"] == key and Map.take(transfer, fields) == Map.take(receipt, fields),
         true <- {transfer["old_request_key"], transfer["old_reservation_key"], transfer["output_sha256"]} == {old["request_key"], old["reservation_key"], old["output_sha256"]},
         {:ok, current} <- WorkspaceAccess.get(store, transfer["new_reservation_key"]) do
      {current["run_id"], current["task_key"], current["request_key"], current["generation"], current["canonical_path"]} ==
        {old["run_id"], old["task_key"], transfer["new_request_key"], receipt["new_generation"], access["canonical_path"]}
    else
      _ -> false
    end
  end

  defp recheck_reserved_source(store, %{"status" => "RESERVED"}, access, proof, receipt) do
    with true <- human_input_clear?(store, access["run_id"]) or {:error, :infrastructure_recovery_human_input_pending},
         {:ok, head} <- WorkerEvidence.checkout_head(access),
         true <- head == receipt["checkout_head_sha"] or {:error, :infrastructure_recovery_head_changed},
         {:ok, paths} <- SymphonyElixir.Factory.Worktree.pending_source_paths(access["canonical_path"]),
         true <- paths == proof["files"] |> Enum.map(& &1["path"]) |> Enum.sort() or {:error, :infrastructure_recovery_files_unproven},
         do: validate_files(access, proof["files"])
  end

  defp recheck_reserved_source(_store, _attempt, _access, _proof, _receipt), do: :ok

  defp descriptor(proof),
    do: %{"operational_recovery_key" => proof["recovery_key"], "request_key" => proof["request_key"], "disposition_key" => proof["disposition_key"], "thread_id" => proof["task"]["thread_id"]}

  defp recoverable(store, completed, operator) do
    blockers = completed.output["blockers"]

    with :ok <- TicketChat.ordinary_delivery_eligibility(completed.run),
         true <- human_input_clear?(store, completed.run["run_id"]),
         true <- completed.run["state"] in ~w(WRITING REPAIRING REVIEW_WRITING),
         true <- completed.task["role"] == "feature-writer" and completed.task["status"] == "COMPLETE",
         true <- completed.output["status"] == "BLOCKED" and is_list(blockers) and blockers != [],
         true <- Enum.all?(blockers, &is_binary/1),
         true <- recovery_authorized?(blockers, operator),
         true <- WorkerEvidence.owner_stopped?(store, completed.evidence) do
      :ok
    else
      _ -> {:error, :infrastructure_recovery_not_eligible}
    end
  end

  defp recovery_authorized?(blockers, nil),
    do: Enum.all?(blockers, &String.contains?(&1, ["file_worker_helper_exit_unproven", "file_worker_edit_reconciliation_required"]))

  defp recovery_authorized?(_blockers, %{"authorization_reference" => reference, "instruction" => instruction} = operator) do
    map_size(operator) == 2 and Enum.all?([reference, instruction], &(is_binary(&1) and String.valid?(&1) and byte_size(&1) in 1..8192 and String.trim(&1) != ""))
  end

  defp recovery_authorized?(_, _), do: false

  defp human_input_clear?(store, run_id) do
    Store.one!(store, "SELECT question_key FROM ticket_chat_questions WHERE run_id = ? AND status = 'OPEN' LIMIT 1", [run_id]) == nil and
      Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING', 'ACCEPTED') LIMIT 1", [run_id]) == nil
  end

  defp files(store, completed) do
    %{columns: columns, rows: rows} = Store.query!(store, "SELECT * FROM worker_file_operations WHERE request_key = ? ORDER BY call_id", [completed.evidence["request_key"]])
    operations = Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
    changed = completed.output["changed_paths"]

    with true <- operations != [] and is_list(changed),
         true <- Enum.sort(Enum.map(operations, & &1["path"])) == Enum.sort(changed),
         true <- Enum.all?(operations, &(&1["phase"] == "APPLIED" and &1["io_pending"] == 0)),
         {:ok, pending_paths} <- SymphonyElixir.Factory.Worktree.pending_source_paths(completed.access["canonical_path"]),
         true <- pending_paths == Enum.sort(changed),
         :ok <- validate_files(completed.access, operations) do
      {:ok, Enum.map(operations, &Map.take(&1, ~w(call_id path before_sha256 after_sha256 io_binding_json io_receipt_json io_invocation)))}
    else
      {:error, _} = error -> error
      _ -> {:error, :infrastructure_recovery_files_unproven}
    end
  end

  defp validate_files(access, operations) do
    root = Jason.decode!(access["binding_json"])

    Enum.reduce_while(operations, :ok, fn row, :ok ->
      with {:ok, binding} <- Jason.decode(row["io_binding_json"]),
           {_, _, receipt} <- WorkerFileIO.recover_mutation(binding),
           true <- Jason.encode!(receipt) == row["io_receipt_json"],
           {:ok, %{"sha256" => sha}, _} <- WorkerFileIO.request(access["canonical_path"], root, "digest", %{"path" => row["path"]}),
           true <- sha == row["after_sha256"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :infrastructure_recovery_file_changed}}
      end
    end)
  end

  defp disposition(store, run_id, request), do: find(store, "TICKET_NATIVE_WRITER_BLOCKED", &(&1["request_key"] == request), run_id)

  defp find(store, type, predicate, run_id \\ nil) do
    rows =
      if run_id,
        do: Store.query!(store, "SELECT payload_json FROM events WHERE event_type = ? AND run_id = ? ORDER BY id DESC", [type, run_id]).rows,
        else: Store.query!(store, "SELECT payload_json FROM events WHERE event_type = ? ORDER BY id DESC", [type]).rows

    Enum.find_value(rows, fn [raw] ->
      case Jason.decode(raw) do
        {:ok, value} when is_map(value) -> if predicate.(value), do: value
        _ -> nil
      end
    end)
  end

  defp persist(store, run_id, type, proof) do
    key = proof["recovery_key"]

    case find(store, type, &(&1["recovery_key"] == key), run_id) do
      nil ->
        Store.query!(store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES (?, ?, ?, ?)", [type, run_id, Jason.encode!(proof), DateTime.utc_now() |> DateTime.to_iso8601()])
        {:ok, proof}

      ^proof ->
        {:ok, proof}

      _ ->
        {:error, :infrastructure_recovery_conflict}
    end
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
