defmodule SymphonyElixir.Factory.CompletedTurnRecovery do
  @moduledoc "Reconciles a completed exact native turn after a proven stopped transport failure."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLedger, WorkerEvidence, WorkspaceAccess}

  @spec reconcile(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, key, opts \\ []) do
    case committed(store, key) do
      :none -> reconcile_pending(store, key, opts)
      result -> result
    end
  end

  defp reconcile_pending(store, key, opts) do
    with {:ok, before} <- snapshot(store, key),
         reader = Keyword.get(opts, :native_reader, AppServer),
         {:ok, native} <- reader.read_native_thread(before.evidence["thread_id"], workspace: before.binding["policy"]["cwd"], include_turns: false, include_latest_turn: true, include_queue: true),
         {:ok, result} <- native_result(before, native) do
      recovered = result |> Map.put(:reconciliation_preimage, before) |> Map.put(:native_recovery, provenance(before, native))

      with {:ok, _evidence} <- WorkerEvidence.reconcile_completed(store, key, before.evidence["owner_id"], recovered, before.stop) do
        {:ok, result |> Map.put(:policy, before.binding["policy"]) |> Map.put(:owner_stop, before.stop) |> Map.put(:worker_request_key, key)}
      end
    end
  end

  defp committed(store, key) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         true <- evidence["status"] == "RESULT_RECORDED",
         %{"payload_json" => raw} <-
           Store.one!(store, "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED' AND json_extract(payload_json,'$.request_key')=?", [key]),
         {:ok, provenance} <- Jason.decode(raw),
         true <-
           provenance["output_sha256"] == evidence["output_sha256"] and provenance["binding_sha256"] == evidence["binding_sha256"] and provenance["owner_stop_json"] == evidence["owner_stop_json"],
         {:ok, completed} <- WorkerEvidence.completed_result(store, key) do
      {:ok,
       %{
         thread_id: evidence["thread_id"],
         turn_id: evidence["turn_id"],
         item_id: evidence["item_id"],
         output: completed.output,
         policy: completed.binding["policy"],
         owner_stop: Jason.decode!(evidence["owner_stop_json"]),
         worker_request_key: key
       }}
    else
      _ -> :none
    end
  end

  defp snapshot(store, key) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         true <- evidence["status"] == "RECONCILE_REQUIRED" or {:error, :completed_turn_not_pending},
         true <- transport_failure?(evidence["failure_code"]) or {:error, :completed_turn_transport_unproven},
         true <- WorkerEvidence.owner_stopped?(store, evidence) or {:error, :completed_turn_stop_unproven},
         true <- (is_binary(evidence["thread_id"]) and is_binary(evidence["turn_id"])) or {:error, :completed_turn_identity_missing},
         true <- digest_raw(evidence["binding_json"]) == evidence["binding_sha256"] or {:error, :worker_evidence_corrupt},
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         true <- is_map(binding) or {:error, :worker_evidence_corrupt},
         true <- evidence["policy_json"] == Jason.encode!(binding["policy"]) or {:error, :completed_turn_policy_unproven},
         {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         :ok <- SymphonyElixir.Factory.TicketWorkerRunner.admitted_stage(run, binding["role"]),
         true <- task["status"] in ~w(STARTING RUNNING STALE RETRY_PENDING WAITING_FOR_BROKER WAITING_FOR_WRITER) or {:error, :completed_turn_task_changed},
         true <- (task["stage"] == run["state"] and run["candidate_sha"] in [nil, binding["expected_sha"]]) or {:error, :completed_turn_inputs_changed},
         [pending] <- WorkerEvidence.pending(store, evidence["run_id"]),
         true <- pending == evidence or {:error, :completed_turn_superseded},
         {:ok, access} <- WorkspaceAccess.validate(store, evidence["reservation_key"], binding["reservation_generation"]),
         {:ok, stop} <- Jason.decode(evidence["owner_stop_json"]) do
      {:ok, %{evidence: evidence, binding: binding, run: run, task: task, access: access, stop: stop}}
    else
      {:error, _} = error -> error
      _ -> {:error, :completed_turn_identity_unproven}
    end
  end

  defp transport_failure?(":turn_timeout"), do: true
  defp transport_failure?(reason) when is_binary(reason), do: Regex.match?(~r/\A\{:port_exit, -?\d+\}\z/, reason)
  defp transport_failure?(_), do: false

  defp native_result(before, native) when is_map(native) do
    evidence = before.evidence
    latest = native["latest_turn_observation"] || %{}
    confirmed = latest["confirmation"] || %{}
    queue = native["queue_observation"] || %{}
    parameters = %{"threadId" => evidence["thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}

    with true <- byte_size(Jason.encode!(native)) <= 2_097_152,
         true <- {native["id"], native["cwd"]} == {evidence["thread_id"], before.binding["policy"]["cwd"]},
         true <- get_in(native, ["status", "type"]) in ~w(idle notLoaded systemError),
         true <- is_number(native["updatedAt"]) and native["updatedAt"] == latest["updated_at"],
         true <- latest["mode"] == "LATEST_DESC" and latest["parameters"] == parameters,
         %{"data" => [%{"id" => turn, "status" => "completed", "error" => nil, "items" => items}]} = raw when is_list(items) <- latest["raw_response"],
         true <- turn == evidence["turn_id"] and latest["sha256"] == digest(raw),
         %{"data" => data} = confirmation <- confirmed["raw_response"],
         true <- data == raw["data"] and confirmed["sha256"] == digest(confirmation),
         true <-
           Map.take(queue, ~w(thread_id empty_complete count_lower_bound has_more)) == %{"thread_id" => evidence["thread_id"], "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false},
         %{"data" => [], "nextCursor" => nil} = queued <- queue["raw_response"],
         true <- queue["sha256"] == digest(queued),
         true <- Enum.all?([latest["observed_at"], confirmed["observed_at"], queue["observed_at"]], &fresh?/1),
         true <- Enum.all?(items, &is_map/1),
         [final] <- Enum.filter(items, &(&1["type"] == "agentMessage" and &1["phase"] != "commentary")),
         true <- final["phase"] == "final_answer" and is_binary(final["id"]) and final["id"] != "",
         true <- is_binary(final["text"]) and String.trim(final["text"]) != "",
         {:ok, output} when is_map(output) <- Jason.decode(final["text"]) do
      {:ok, %{thread_id: evidence["thread_id"], turn_id: turn, item_id: final["id"], output: output}}
    else
      _ -> {:error, :completed_turn_native_unproven}
    end
  end

  defp native_result(_before, _native), do: {:error, :completed_turn_native_unproven}

  defp provenance(before, native) do
    latest = native["latest_turn_observation"]

    %{
      request_key: before.evidence["request_key"],
      binding_sha256: before.evidence["binding_sha256"],
      failure_code: before.evidence["failure_code"],
      owner_stop_json: before.evidence["owner_stop_json"],
      native_parsed_json_sha256: digest(native),
      native_observation: %{
        thread: Map.take(native, ~w(id cwd updatedAt)) |> Map.put("status", Map.take(native["status"], ~w(type))),
        latest: Map.take(latest, ~w(mode parameters sha256 updated_at observed_at)),
        confirmation: Map.take(latest["confirmation"], ~w(sha256 observed_at)),
        queue: Map.take(native["queue_observation"], ~w(thread_id empty_complete count_lower_bound has_more sha256 observed_at))
      }
    }
  end

  defp fresh?(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> DateTime.diff(DateTime.utc_now(), time, :millisecond) in 0..10_000
      _ -> false
    end
  end

  defp fresh?(_), do: false
  defp digest(value), do: digest_raw(Jason.encode!(value))
  defp digest_raw(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
