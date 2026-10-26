defmodule SymphonyElixir.Factory.TicketPushWorkerHistory do
  @moduledoc "Module-owned retained worker supersession proof; historical failures remain unchanged."
  alias SymphonyElixir.Factory.{Store, TicketCapabilityRecovery, WorkerEvidence, WorkspaceAccess}

  @doc "Selects a new codec only for authenticated retained capability transfers; never repairs historical rows."
  @spec capability_recovery(Store.connection(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def capability_recovery(store, run_id) do
    prior =
      rows(
        store,
        "SELECT w.* FROM worker_evidence w JOIN workspace_access a ON a.reservation_key=w.reservation_key WHERE w.run_id=? AND json_extract(a.release_receipt_json,'$.operational_recovery_key') LIKE 'TCAP-%'",
        [run_id]
      )

    if Enum.all?(prior, &TicketCapabilityRecovery.superseded?(store, &1)),
      do: {:ok, prior != []},
      else: {:error, :push_recovery_capability_history_unproven}
  end

  @doc "Captures additive capability authority only for its separately versioned physical codec."
  @spec observe_capability(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe_capability(store, run_id) do
    with {:ok, true} <- capability_recovery(store, run_id),
         {:ok, history} <- observe_generated(store, run_id) do
      events =
        rows(
          store,
          "SELECT * FROM events WHERE run_id=? AND event_type IN ('TICKET_FAILED_TURN_RECOVERY_AUTHORIZED','TICKET_FAILED_TURN_RECOVERY_APPLIED','TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED','TICKET_INFRASTRUCTURE_RECOVERY_APPLIED','TICKET_NATIVE_WRITER_BLOCKED','TICKET_CI_REPAIR_SUCCESSOR_APPLIED','TICKET_CAPABILITY_RECOVERY_AUTHORIZED','TICKET_CAPABILITY_RECOVERY_CHECKED','TICKET_CAPABILITY_RECOVERY_APPLIED','TICKET_CAPABILITY_RECOVERY_PREPARED_ADMITTED') ORDER BY id",
          [run_id]
        )

      {:ok, history |> Map.put("capability_recovery_version", 1) |> Map.put("events_json", compact(events, ~w(payload_json)))}
    end
  end

  @spec observe(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe(store, run_id) do
    workers = rows(store, "SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key", [run_id])
    tasks = rows(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key", [run_id])
    accesses = rows(store, "SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key", [run_id])

    successors = rows(store, "SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id = ? ORDER BY attempt_index", [run_id])

    event_types =
      if successors == [],
        do: "'TICKET_FAILED_TURN_RECOVERY_AUTHORIZED', 'TICKET_FAILED_TURN_RECOVERY_APPLIED', 'TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED', 'TICKET_INFRASTRUCTURE_RECOVERY_APPLIED'",
        else:
          "'TICKET_FAILED_TURN_RECOVERY_AUTHORIZED', 'TICKET_FAILED_TURN_RECOVERY_APPLIED', 'TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED', 'TICKET_INFRASTRUCTURE_RECOVERY_APPLIED', 'TICKET_NATIVE_WRITER_BLOCKED', 'TICKET_CI_REPAIR_SUCCESSOR_APPLIED'"

    events =
      rows(
        store,
        "SELECT * FROM events WHERE run_id = ? AND event_type IN (#{event_types}) ORDER BY id",
        [run_id]
      )

    commands = rows(store, "SELECT * FROM ticket_chat_commands WHERE run_id = ? ORDER BY command_key", [run_id])
    writers = Enum.filter(tasks, &(&1["role"] == "feature-writer"))

    with true <- writers != [] or {:error, :push_recovery_latest_writer_missing},
         true <- WorkerEvidence.pending(store, run_id) == [] or {:error, :push_recovery_current_worker_unconsumed},
         true <- Enum.all?(workers, &(consumed?(store, &1) or WorkerEvidence.superseded_blocked_attempt?(store, &1))) or {:error, :push_recovery_worker_history_unproven},
         true <-
           Enum.all?(writers, fn task ->
             task["status"] == "CONSUMED" and
               Enum.any?(workers, fn worker ->
                 worker["task_key"] == task["task_key"] and worker["status"] == "CONSUMED" and worker["thread_id"] == task["thread_id"] and worker["turn_id"] == task["turn_id"] and
                   worker["output_json"] == task["output_json"] and WorkerEvidence.owner_stopped?(store, worker)
               end)
           end) or {:error, :push_recovery_latest_writer_stop_unproven} do
      history = %{
        "workers_json" => compact(workers, ~w(binding_json output_json policy_json)),
        "tasks_json" => compact(tasks, ~w(output_json)),
        "accesses_json" => compact(accesses, ~w(binding_json release_receipt_json)),
        "events_json" => compact(events, ~w(payload_json)),
        "commands_json" => compact(commands, ~w(binding_json payload_json receipt_json application_receipt_json)),
        "worker_key_order" => if(workers == [], do: [], else: Map.keys(hd(workers)))
      }

      {:ok, if(successors == [], do: history, else: Map.put(history, "successors_json", compact(successors, ~w(evidence_json proof_json))))}
    end
  end

  @doc "Captures the new immutable push codec without changing archived history bytes."
  @spec observe_current(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe_current(store, run_id) do
    with {:ok, history} <- observe(store, run_id) do
      events =
        rows(
          store,
          "SELECT * FROM events WHERE run_id=? AND event_type IN ('TICKET_FAILED_TURN_RECOVERY_AUTHORIZED','TICKET_FAILED_TURN_RECOVERY_APPLIED','TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED','TICKET_INFRASTRUCTURE_RECOVERY_APPLIED','TICKET_NATIVE_WRITER_BLOCKED','TICKET_CI_REPAIR_SUCCESSOR_APPLIED') ORDER BY id",
          [run_id]
        )

      intents = rows(store, "SELECT * FROM ticket_ordinary_generation_intents WHERE run_id=? ORDER BY intent_key", [run_id])

      generation_events =
        rows(store, "SELECT e.* FROM ticket_ordinary_generation_events e JOIN ticket_ordinary_generation_intents i ON i.intent_key=e.intent_key WHERE i.run_id=? ORDER BY e.event_key", [run_id])

      {:ok,
       history
       |> Map.put_new("successors_json", "[]")
       |> Map.put("events_json", compact(events, ~w(payload_json)))
       |> Map.put("generation_intents_json", compact(intents, ~w(binding_json)))
       |> Map.put("generation_events_json", compact(generation_events, ~w(receipt_json)))}
    end
  end

  @doc "Adds the generated-only CI journal codec for new physical issuances only."
  @spec observe_generated(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe_generated(store, run_id) do
    with {:ok, history} <- observe_current(store, run_id) do
      intents = rows(store, "SELECT * FROM ticket_ci_generation_intents WHERE run_id=? AND json_extract(binding_json,'$.kind')='CONTROLLER_CI_GENERATED_ONLY' ORDER BY intent_key", [run_id])

      events =
        rows(
          store,
          "SELECT e.* FROM ticket_ci_generation_events e JOIN ticket_ci_generation_intents i ON i.intent_key=e.intent_key WHERE i.run_id=? AND json_extract(i.binding_json,'$.kind')='CONTROLLER_CI_GENERATED_ONLY' ORDER BY e.event_key",
          [run_id]
        )

      {:ok, history |> Map.put("generated_only_intents_json", compact(intents, ~w(binding_json))) |> Map.put("generated_only_events_json", compact(events, ~w(receipt_json)))}
    end
  end

  @doc "Captures additive review/correction decisions only for the new physical report codec."
  @spec observe_review(Store.connection(), String.t(), :large | :capability) :: {:ok, map()} | {:error, term()}
  def observe_review(store, run_id, mode) do
    observed = if mode == :capability, do: observe_capability(store, run_id), else: observe_generated(store, run_id)

    with {:ok, history} <- observed do
      events = rows(store, "SELECT * FROM events WHERE run_id=? AND event_type IN ('TICKET_REVIEW_REPORT_CORRECTED','TICKET_REVIEW_DECISION') ORDER BY id", [run_id])
      {:ok, Map.put(history, "review_events_json", compact(events, ~w(payload_json)))}
    end
  end

  defp consumed?(store, %{"status" => "CONSUMED"} = worker) do
    with {:ok, access} <- WorkspaceAccess.get(store, worker["reservation_key"]) do
      access["released_at"] != nil and WorkerEvidence.owner_stopped?(store, worker)
    else
      _ -> false
    end
  end

  defp consumed?(_, _), do: false

  defp compact(rows, fields) do
    rows
    |> Enum.map(fn row ->
      Enum.reduce(fields, row, fn field, result -> Map.put(result, field, if(is_binary(row[field]), do: Base.encode16(:crypto.hash(:sha256, row[field]), case: :lower), else: nil)) end)
    end)
    |> Jason.encode!()
  end

  defp rows(store, sql, params) do
    %{columns: columns, rows: values} = Store.query!(store, sql, params)
    Enum.map(values, &Map.new(Enum.zip(columns, &1)))
  end
end
