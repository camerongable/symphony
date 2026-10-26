defmodule SymphonyElixir.Factory.TicketMrGuard do
  @moduledoc "Fresh owning-Desktop observations for an exact project controller MR request."
  require Logger

  @spec receipt(map(), map(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def receipt(request, proof, broker, now) when is_map(proof) and is_binary(broker) do
    with true <- Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, broker) or {:error, :mr_guard_broker_mismatch},
         true <- proof["source_thread_id"] == broker or {:error, :mr_guard_broker_mismatch},
         %{"source" => "codex_app/read_thread", "observed_at" => owner_at, "response" => %{"schemaVersion" => 1, "thread" => owner}} when is_map(owner) <- proof["owner"],
         %{"id" => thread, "cwd" => cwd, "projectId" => project, "queue_observation" => queue} when is_map(queue) <- proof["native"],
         :ok <- identity(request, owner, thread, cwd, project),
         true <- owner["status"] in [%{"type" => "idle"}, %{"type" => "notLoaded"}] or {:error, :mr_guard_owner_not_quiet},
         :ok <- native_receipt(request, proof["native"], now),
         :ok <- fresh(owner_at, now),
         :ok <- fresh(queue["observed_at"], now) do
      {:ok, %{"source_thread_id" => broker, "owner_sha256" => digest(proof["owner"]), "native_sha256" => digest(proof["native"]), "checked_at" => DateTime.to_iso8601(now)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :mr_guard_evidence_invalid}
    end
  end

  def receipt(_request, _proof, _broker, _now), do: {:error, :mr_guard_evidence_required}

  @doc false
  @spec native_receipt(map(), map(), DateTime.t()) :: :ok | {:error, atom()}
  def native_receipt(request, native, now) do
    result = validate_native_receipt(request, native, now)

    case result do
      {:error, reason} ->
        Logger.warning("Factory native guard rejected reason=#{reason} diagnostics=#{Jason.encode!(rejection_diagnostics(request, native, now))}")

      _ ->
        :ok
    end

    result
  end

  defp validate_native_receipt(request, native, now) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- Map.get(metadata, "delivery_operation", %{}),
         true <-
           ({native["id"], native["cwd"]} == {request["existing_thread_id"], binding["controller_native_cwd"] || request["cwd"]} and native_project_matches?(native, request["codex_project_id"])) or
             {:error, :mr_guard_identity_mismatch},
         true <- not Map.has_key?(binding, "controller_native_cwd") or native["status"] in [%{"type" => "idle"}, %{"type" => "notLoaded"}] or {:error, :mr_guard_owner_not_quiet},
         :ok <- empty_queue(native["queue_observation"], native["id"]),
         :ok <- latest_turn(request, native, now),
         :ok <- fresh(native["queue_observation"]["observed_at"], now) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_guard_evidence_invalid}
    end
  end

  defp rejection_diagnostics(request, native, now) do
    metadata = Jason.decode!(request["metadata_json"])
    observation = native["latest_turn_observation"] || %{}
    confirmation = observation["confirmation"] || %{}
    raw = observation["raw_response"] || %{}
    latest = List.first(raw["data"] || []) || %{}

    %{
      session_id: "#{request["existing_thread_id"]}/#{metadata["previous_turn_id"]}",
      latest_age_ms: observation_age(observation["observed_at"], now),
      confirmation_age_ms: observation_age(confirmation["observed_at"], now),
      queue_age_ms: observation_age(get_in(native, ["queue_observation", "observed_at"]), now),
      latest_turn_matches: latest["id"] == metadata["previous_turn_id"],
      latest_completed: latest["status"] == "completed",
      confirmation_matches: get_in(confirmation, ["raw_response", "data"]) == raw["data"],
      version_matches: observation["updated_at"] == native["updatedAt"],
      latest_digest_matches: observation["sha256"] == digest(raw)
    }
  rescue
    _ -> %{diagnostic: "malformed_observation"}
  end

  defp observation_age(at, now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, observed, _} -> DateTime.diff(now, observed, :millisecond)
      _ -> nil
    end
  end

  defp observation_age(_at, _now), do: nil

  @doc false
  @spec native_project_matches?(map(), term()) :: boolean()
  def native_project_matches?(native, ledger_project) when is_map(native) do
    case Map.fetch(native, "projectId") do
      {:ok, nil} -> ledger_project == "projectless"
      {:ok, project} when is_binary(project) and byte_size(project) > 0 -> project == ledger_project
      _ -> false
    end
  end

  defp identity(request, owner, thread, cwd, project) do
    expected = %{"id" => thread, "cwd" => cwd, "kind" => "codex", "hostId" => "local"}

    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- Map.get(metadata, "delivery_operation", %{}),
         pin = binding["controller_native_cwd"] || request["cwd"],
         true <- Map.take(owner, Map.keys(expected)) == expected,
         true <- not Map.has_key?(binding, "controller_cwd") or binding["controller_cwd"] == request["cwd"],
         true <- {thread, cwd} == {request["existing_thread_id"], pin} and native_project_matches?(%{"projectId" => project}, request["codex_project_id"]) do
      :ok
    else
      _ -> {:error, :mr_guard_identity_mismatch}
    end
  end

  defp latest_turn(request, native, now) do
    params = %{"threadId" => request["existing_thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}

    with %{"mode" => "LATEST_DESC", "parameters" => ^params, "raw_response" => raw, "sha256" => sha, "updated_at" => version, "observed_at" => at} <- native["latest_turn_observation"],
         true <- is_number(version) and version == native["updatedAt"],
         %{"data" => [%{"id" => turn, "status" => "completed", "items" => items}], "nextCursor" => cursor} when is_list(items) <- raw,
         true <- is_nil(cursor) or (is_binary(cursor) and cursor != ""),
         true <- sha == digest(raw),
         :ok <- confirmed_latest(native["latest_turn_observation"], raw, now),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- turn == metadata["previous_turn_id"],
         :ok <- fresh(at, now) do
      :ok
    else
      _ -> {:error, :mr_guard_native_turn_mismatch}
    end
  end

  defp confirmed_latest(observation, raw, now) do
    with %{"raw_response" => confirmation, "sha256" => sha, "observed_at" => at} <- observation["confirmation"],
         %{"data" => data, "nextCursor" => cursor} <- confirmation,
         true <- data == raw["data"],
         true <- is_nil(cursor) or (is_binary(cursor) and cursor != ""),
         true <- sha == digest(confirmation),
         :ok <- fresh(at, now) do
      :ok
    else
      _ -> {:error, :mr_guard_native_turn_mismatch}
    end
  end

  defp empty_queue(queue, thread) when is_map(queue) do
    expected = %{"thread_id" => thread, "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false}

    with true <- Map.take(queue, Map.keys(expected)) == expected or {:error, :mr_guard_queue_not_empty},
         %{"data" => [], "nextCursor" => nil} = raw <- queue["raw_response"],
         true <- queue["sha256"] == digest(raw) or {:error, :mr_guard_queue_invalid} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :mr_guard_queue_invalid}
    end
  end

  defp empty_queue(_queue, _thread), do: {:error, :mr_guard_queue_invalid}

  defp fresh(at, now) when is_binary(at) do
    with {:ok, observed, _} <- DateTime.from_iso8601(at),
         age = DateTime.diff(now, observed, :microsecond),
         true <- age >= 0 and age <= 10_000_000 do
      :ok
    else
      _ -> {:error, :mr_guard_observation_expired}
    end
  end

  defp fresh(_at, _now), do: {:error, :mr_guard_evidence_invalid}
  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, Jason.encode!(value)), case: :lower)
end
