defmodule SymphonyElixir.Factory.NativeMaintenanceEvidence do
  @moduledoc "Immutable target-attested evidence transported through broker-observed command stdout."

  alias SymphonyElixir.Factory.{DesktopRequest, NativeWorktreeProbe, StageSchemas, Store}

  @event "NATIVE_MAINTENANCE_TARGET_EVIDENCE"
  @provenance "TARGET_ATTESTED_NATIVE_CHAT"
  @tool "mcp__codex_app__list_artifacts"
  @emitter Path.expand("../../../scripts/emit-maintenance-evidence.py", __DIR__)
  @external_resource @emitter
  @emitter_sha256 :crypto.hash(:sha256, File.read!(@emitter)) |> Base.encode16(case: :lower)

  @spec emitter_path() :: Path.t()
  def emitter_path, do: @emitter

  @spec emitter_sha256() :: String.t()
  def emitter_sha256, do: @emitter_sha256

  @spec input(map()) :: map()
  def input(request), do: %{"binding" => request_binding(request), "tool" => @tool}

  @spec record(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record(store, request_key, payload) when is_map(payload) do
    Store.transaction!(store, fn transaction ->
      with {:ok, request} <- DesktopRequest.get(transaction, request_key),
           :ok <- recorded_request(transaction, request),
           :ok <- validate_payload(request, payload),
           {:ok, receipt} <- NativeWorktreeProbe.receipt(request, payload["evidence"]["artifact_output"]),
           :ok <- unseen_turn(transaction, request_key, payload["command_proof"]["turn_id"]),
           {:ok, event} <- persist(transaction, request, payload) do
        {:ok, Map.put(event, "receipt", receipt)}
      end
    end)
  end

  @spec attach(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def attach(store, request, attrs) do
    with {:ok, operation} <- NativeWorktreeProbe.operation(request) do
      if operation && (producer_pinned?(request) or not Map.has_key?(attrs, "artifact_output")),
        do: attach_recorded(store, request, attrs),
        else: {:ok, attrs}
    end
  end

  defp producer_pinned?(request), do: Map.has_key?(Jason.decode!(request["metadata_json"]), "emitter_sha256")

  defp request_binding(request) do
    metadata = Jason.decode!(request["metadata_json"])

    %{
      "run_id" => metadata["run_id"],
      "task_key" => request["target_key"],
      "thread_id" => request["existing_thread_id"],
      "writer_turn_id" => metadata["previous_turn_id"],
      "codex_project_id" => request["codex_project_id"],
      "worktree" => request["cwd"],
      "candidate_sha" => metadata["candidate_sha"],
      "source_cwd" => metadata["repo_path"]
    }
  end

  defp recorded_request(store, request) do
    with true <-
           (request["status"] == "THREAD_RECORDED" and is_binary(request["claimed_at"])) or
             {:error, :maintenance_request_not_bound},
         true <-
           (request["thread_id"] == request["existing_thread_id"] and
              request["verified_project_id"] == request["codex_project_id"]) or {:error, :maintenance_request_not_bound},
         {:ok, _workspace} <-
           NativeWorktreeProbe.record(store, request, request["thread_id"], %{
             cwd: request["verified_cwd"],
             head_sha: request["verified_head_sha"]
           }) do
      :ok
    end
  end

  defp validate_payload(request, %{"evidence" => evidence, "command_proof" => proof} = payload)
       when is_map(evidence) and is_map(proof),
       do: validate_maps(request, evidence, proof, payload)

  defp validate_payload(_request, _payload), do: {:error, :invalid_maintenance_evidence}

  defp validate_maps(request, evidence, proof, payload) do
    with true <- Enum.sort(Map.keys(payload)) == ~w(command_proof evidence) or {:error, :invalid_maintenance_evidence},
         :ok <- StageSchemas.validate(evidence, StageSchemas.for_stage(:native_maintenance_evidence)),
         true <- producer_matches?(request, evidence) or {:error, :maintenance_producer_changed},
         true <-
           (evidence["request_key"] == request["request_key"] and evidence["binding"] == request_binding(request)) or
             {:error, :maintenance_evidence_binding_mismatch},
         :ok <- StageSchemas.validate(proof, StageSchemas.for_stage(:native_maintenance_command_proof)),
         true <-
           (proof["thread_id"] == request["thread_id"] and proof["turn_id"] != request_binding(request)["writer_turn_id"] and
              proof["command_item"]["cwd"] == request["cwd"]) or {:error, :maintenance_command_binding_mismatch},
         true <-
           Regex.match?(~r/\Aexec-[0-9a-f-]+\z/, proof["command_item"]["id"]) or
             {:error, :invalid_maintenance_command_id},
         {:ok, ^evidence} <- Jason.decode(proof["command_item"]["output"]["text"]),
         :ok <- verify_command(proof["command_item"]["command"], evidence) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :maintenance_stdout_mismatch}
    end
  end

  defp producer_matches?(request, evidence) do
    metadata = Jason.decode!(request["metadata_json"])
    content = File.read!(@emitter)

    metadata["emitter_sha256"] == evidence["emitter_sha256"] and
      evidence["emitter_sha256"] == Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  defp verify_command(command, evidence) do
    case System.cmd("python3", ["-B", @emitter, "--verify-command-base64", Base.encode64(command)], stderr_to_stdout: true) do
      {output, 0} ->
        if Jason.decode(output) == {:ok, evidence}, do: :ok, else: {:error, :maintenance_command_input_mismatch}

      _other ->
        {:error, :unsupported_maintenance_emitter_command}
    end
  end

  defp unseen_turn(store, request_key, turn_id) do
    reused =
      Store.one!(
        store,
        """
        SELECT request_key FROM desktop_requests WHERE status = 'SUCCEEDED' AND turn_id = ? AND request_key != ?
        """,
        [turn_id, request_key]
      )

    if is_nil(reused), do: :ok, else: {:error, :maintenance_command_turn_replayed}
  end

  defp persist(store, request, payload) do
    value = %{
      "request_key" => request["request_key"],
      "request_payload_sha256" => request["payload_sha256"],
      "provenance" => @provenance,
      "transport_provenance" => "BROKER_OBSERVED_COMMAND_STDOUT",
      "evidence" => payload["evidence"],
      "command_proof" => payload["command_proof"]
    }

    case evidence_rows(store, request["request_key"]) do
      [] ->
        metadata = Jason.decode!(request["metadata_json"])

        Store.query!(store, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)", [
          DateTime.utc_now() |> DateTime.to_iso8601(),
          @event,
          metadata["run_id"],
          Jason.encode!(value)
        ])

        {:ok, Store.one!(store, "SELECT * FROM events WHERE id = last_insert_rowid()")}

      [event] ->
        if Jason.decode(event["payload_json"]) == {:ok, value}, do: {:ok, event}, else: {:error, :maintenance_evidence_conflict}

      _other ->
        {:error, :maintenance_evidence_conflict}
    end
  end

  defp evidence_rows(store, key) do
    result = Store.query!(store, "SELECT * FROM events WHERE event_type = ? AND json_extract(payload_json, '$.request_key') = ?", [@event, key])
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp attach_recorded(store, request, attrs) do
    case evidence_rows(store, request["request_key"]) do
      [] -> if producer_pinned?(request), do: {:error, :maintenance_evidence_missing}, else: {:ok, attrs}
      [event] -> attach_event(store, request, attrs, event)
      _other -> {:error, :maintenance_evidence_conflict}
    end
  end

  defp attach_event(_store, request, attrs, event) do
    with {:ok, value} <- Jason.decode(event["payload_json"]),
         true <- value["request_payload_sha256"] == request["payload_sha256"] or {:error, :maintenance_evidence_binding_mismatch},
         :ok <- validate_payload(request, Map.take(value, ~w(evidence command_proof))),
         true <-
           Map.get(attrs, "artifact_output", value["evidence"]["artifact_output"]) == value["evidence"]["artifact_output"] or
             {:error, :maintenance_evidence_binding_mismatch},
         true <-
           (attrs["thread_id"] == value["command_proof"]["thread_id"] and
              attrs["turn_id"] == value["command_proof"]["turn_id"]) or {:error, :maintenance_command_binding_mismatch},
         {:ok, calls} <- observed_calls(attrs, value["evidence"]["artifact_output"]) do
      provenance = %{"provenance" => @provenance, "transport_provenance" => "BROKER_OBSERVED_COMMAND_STDOUT", "event_id" => event["id"]}
      output = attrs["output"] |> Map.put("completed_tool_calls", calls) |> Map.put("maintenance_evidence", provenance)
      {:ok, attrs |> Map.put("artifact_output", value["evidence"]["artifact_output"]) |> Map.put("output", output)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp observed_calls(%{"output" => %{"completed_tool_calls" => calls}} = attrs, observed) when is_list(calls) do
    frame = Map.take(attrs, ~w(thread_id turn_id))
    if Enum.all?(calls, &is_map/1), do: bind_observed_call(calls, observed, frame), else: {:error, :artifact_tool_observation_missing}
  end

  defp observed_calls(_attrs, _observed), do: {:error, :artifact_tool_observation_missing}

  defp bind_observed_call(calls, observed, frame) do
    case Enum.filter(calls, &(&1["tool"] == @tool)) do
      [%{"status" => "completed"} = call] ->
        if call_bound?(call, frame) and Map.get(call, "output", observed) == observed do
          tagged = call |> Map.put("output", observed) |> Map.put("output_provenance", @provenance)
          {:ok, Enum.map(calls, fn current -> if current == call, do: tagged, else: current end)}
        else
          {:error, :artifact_tool_observation_missing}
        end

      _other ->
        {:error, :artifact_tool_observation_missing}
    end
  end

  defp call_bound?(call, frame) do
    call["isError"] != true and is_nil(call["error"]) and call["arguments"] == %{} and
      Map.take(call, Map.keys(frame)) == frame
  end
end
