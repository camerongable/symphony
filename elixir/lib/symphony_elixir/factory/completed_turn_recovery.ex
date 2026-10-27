defmodule SymphonyElixir.Factory.CompletedTurnRecovery do
  @moduledoc "Reconciles a completed exact native turn after a proven stopped transport failure."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLedger, TicketWorkerRunner, WorkerEvidence, WorkspaceAccess}

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
         workspace = before.binding["policy"]["cwd"],
         read_options = [workspace: workspace, include_turns: false, include_latest_turn: true, include_queue: true],
         {:ok, native} <- reader.read_native_thread(before.evidence["thread_id"], read_options),
         {:ok, result} <- native_result(before, native) do
      recovered = result |> Map.put(:reconciliation_preimage, before) |> Map.put(:native_recovery, provenance(before, native, result))

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
    with {:ok, evidence, binding} <- stopped_binding(store, key),
         true <- evidence["policy_json"] == Jason.encode!(binding["policy"]) or {:error, :completed_turn_policy_unproven},
         {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         :ok <- TicketWorkerRunner.admitted_stage(run, binding["role"]),
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

  defp stopped_binding(store, key) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         true <- evidence["status"] == "RECONCILE_REQUIRED" or {:error, :completed_turn_not_pending},
         true <- transport_failure?(evidence["failure_code"]) or {:error, :completed_turn_transport_unproven},
         true <- WorkerEvidence.owner_stopped?(store, evidence) or {:error, :completed_turn_stop_unproven},
         true <- (is_binary(evidence["thread_id"]) and is_binary(evidence["turn_id"])) or {:error, :completed_turn_identity_missing},
         true <- digest_raw(evidence["binding_json"]) == evidence["binding_sha256"] or {:error, :worker_evidence_corrupt},
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         true <- is_map(binding) or {:error, :worker_evidence_corrupt} do
      {:ok, evidence, binding}
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
    status = native["status"]
    latest = native["latest_turn_observation"]
    confirmed = if is_map(latest), do: latest["confirmation"]
    queue = native["queue_observation"]
    parameters = %{"threadId" => evidence["thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}

    with {:ok, encoded} <- Jason.encode(native),
         true <- byte_size(encoded) <= 2_097_152,
         true <- is_map(status) and is_map(latest) and is_map(confirmed) and is_map(queue),
         true <- {native["id"], native["cwd"]} == {evidence["thread_id"], before.binding["policy"]["cwd"]},
         true <- status["type"] in ~w(idle notLoaded systemError),
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
         {:ok, final, output} <- final_output(items) do
      {:ok, %{thread_id: evidence["thread_id"], turn_id: turn, item_id: final["id"], output: output}}
    else
      _ -> {:error, :completed_turn_native_unproven}
    end
  end

  defp native_result(_before, _native), do: {:error, :completed_turn_native_unproven}

  defp final_output(items) do
    with true <- Enum.all?(items, &is_map/1),
         [final] <- Enum.filter(items, &(&1["type"] == "agentMessage" and &1["phase"] != "commentary")),
         true <- final["phase"] == "final_answer" and is_binary(final["id"]) and final["id"] != "",
         true <- is_binary(final["text"]) and String.trim(final["text"]) != "",
         {:ok, output} when is_map(output) <- Jason.decode(final["text"]) do
      {:ok, final, output}
    else
      _ -> {:error, :completed_turn_native_unproven}
    end
  end

  defp provenance(before, native, result) do
    latest = native["latest_turn_observation"]

    %{
      "kind" => "NATIVE_COMPLETION_RECEIPT_V1",
      "version" => 1,
      "request_key" => before.evidence["request_key"],
      "task_key" => before.evidence["task_key"],
      "run_id" => before.evidence["run_id"],
      "reservation_key" => before.evidence["reservation_key"],
      "reservation_generation" => before.binding["reservation_generation"],
      "owner_id" => before.evidence["owner_id"],
      "owner_stopped_at" => before.evidence["owner_stopped_at"],
      "binding_sha256" => before.evidence["binding_sha256"],
      "failure_code" => before.evidence["failure_code"],
      "owner_stop_json" => before.evidence["owner_stop_json"],
      "native_parsed_json_sha256" => digest(native),
      "native_completion" => %{"status" => "completed", "error" => nil},
      "thread_id" => result.thread_id,
      "turn_id" => result.turn_id,
      "item_id" => result.item_id,
      "output_sha256" => digest(result.output),
      "native_observation" => %{
        "thread" => Map.take(native, ~w(id cwd updatedAt)) |> Map.put("status", Map.take(native["status"], ~w(type))),
        "latest" => Map.take(latest, ~w(mode parameters sha256 updated_at observed_at)),
        "confirmation" => Map.take(latest["confirmation"], ~w(sha256 observed_at)),
        "queue" => Map.take(native["queue_observation"], ~w(thread_id empty_complete count_lower_bound has_more sha256 observed_at))
      }
    }
  end

  @doc "Checks the bounded projection against the original atomic recovery preimage."
  @spec validate_receipt(map(), map(), map(), String.t()) :: :ok | {:error, atom()}
  def validate_receipt(proof, %{evidence: evidence, binding: binding, access: access}, result, occurred_at) when is_map(proof) do
    keys =
      ~w(kind version request_key task_key run_id reservation_key reservation_generation owner_id owner_stopped_at binding_sha256 failure_code owner_stop_json native_parsed_json_sha256 native_completion native_observation thread_id turn_id item_id output_sha256)

    identity = ~w(request_key task_key run_id reservation_key owner_id owner_stopped_at binding_sha256 failure_code owner_stop_json thread_id turn_id)

    with true <- exact_keys?(proof, keys),
         true <- proof["kind"] == "NATIVE_COMPLETION_RECEIPT_V1" and proof["version"] === 1,
         true <- Map.take(proof, identity) == Map.take(evidence, identity),
         true <- Map.take(evidence, ~w(run_id task_key request_key reservation_key)) == Map.take(access, ~w(run_id task_key request_key reservation_key)),
         true <- Map.take(evidence, ~w(run_id task_key reservation_key)) == Map.take(binding, ~w(run_id task_key reservation_key)),
         true <- is_integer(proof["reservation_generation"]) and proof["reservation_generation"] > 0,
         true <- proof["reservation_generation"] == binding["reservation_generation"] and proof["reservation_generation"] == access["generation"],
         true <- proof["binding_sha256"] == digest_raw(evidence["binding_json"]),
         true <- {proof["thread_id"], proof["turn_id"], proof["item_id"]} == {result[:thread_id], result[:turn_id], result[:item_id]},
         true <- proof["output_sha256"] == digest(result[:output]),
         true <- valid_receipt_identity?(proof) and transport_failure?(proof["failure_code"]),
         true <- is_binary(proof["owner_stop_json"]) and byte_size(proof["owner_stop_json"]) <= 8192,
         true <- proof["native_completion"] == %{"status" => "completed", "error" => nil},
         true <- valid_observation?(proof["native_observation"], evidence, access, occurred_at),
         {:ok, acquired} <- utc(access["acquired_at"]),
         {:ok, stopped} <- utc(proof["owner_stopped_at"]),
         true <- DateTime.compare(acquired, stopped) != :gt,
         {:ok, raw} <- Jason.encode(proof),
         true <- byte_size(raw) <= 32_768 do
      :ok
    else
      _ -> {:error, :completed_turn_receipt_unproven}
    end
  end

  def validate_receipt(_proof, _before, _result, _occurred_at), do: {:error, :completed_turn_receipt_unproven}

  defp valid_receipt_identity?(proof) do
    limits = [{~w(request_key task_key reservation_key), 4096}, {~w(run_id owner_id), 256}, {~w(thread_id turn_id item_id), 1024}, {~w(failure_code), 128}]

    Enum.all?(limits, fn {keys, maximum} -> Enum.all?(keys, &bounded_text?(proof[&1], maximum)) end) and
      Enum.all?(~w(binding_sha256 output_sha256 native_parsed_json_sha256), &hex_digest?(proof[&1]))
  end

  defp valid_observation?(observed, evidence, access, occurred_at) do
    with true <- exact_keys?(observed, ~w(thread latest confirmation queue)),
         thread = observed["thread"],
         latest = observed["latest"],
         confirmation = observed["confirmation"],
         queue = observed["queue"],
         true <- exact_keys?(thread, ~w(id cwd updatedAt status)) and exact_keys?(thread["status"], ~w(type)),
         true <- {thread["id"], thread["cwd"]} == {evidence["thread_id"], access["canonical_path"]},
         true <- bounded_text?(thread["cwd"], 4096) and thread["status"]["type"] in ~w(idle notLoaded systemError),
         true <- is_number(thread["updatedAt"]) and thread["updatedAt"] >= 0,
         true <- exact_keys?(latest, ~w(mode parameters sha256 updated_at observed_at)),
         true <- latest["mode"] == "LATEST_DESC" and latest["updated_at"] === thread["updatedAt"],
         true <- latest["parameters"] === %{"threadId" => evidence["thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
         true <- exact_keys?(confirmation, ~w(sha256 observed_at)),
         true <- exact_keys?(queue, ~w(thread_id empty_complete count_lower_bound has_more sha256 observed_at)),
         true <-
           Map.take(queue, ~w(thread_id empty_complete count_lower_bound has_more)) === %{"thread_id" => evidence["thread_id"], "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false},
         true <- Enum.all?([latest, confirmation, queue], &hex_digest?(&1["sha256"])),
         {:ok, stopped} <- utc(evidence["owner_stopped_at"]),
         {:ok, event} <- utc(occurred_at),
         true <- Enum.all?([latest, confirmation, queue], &observation_time?(&1["observed_at"], stopped, event)) do
      true
    else
      _ -> false
    end
  end

  defp observation_time?(raw, stopped, event) do
    case utc(raw) do
      {:ok, observed} -> DateTime.compare(stopped, observed) != :gt and DateTime.diff(event, observed, :microsecond) in 0..10_000_000
      _ -> false
    end
  end

  defp exact_keys?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  defp bounded_text?(value, maximum), do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum
  defp hex_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp utc(raw) when is_binary(raw) do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\z/, raw),
         {:ok, at, 0} <- DateTime.from_iso8601(raw),
         true <- at.year > 0 do
      {:ok, at}
    else
      _ -> {:error, :invalid_utc_timestamp}
    end
  end

  defp utc(_raw), do: {:error, :invalid_utc_timestamp}

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
