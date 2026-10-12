defmodule SymphonyElixir.Factory.TicketMrGuard do
  @moduledoc "Fresh owning-Desktop observations for an exact project controller MR request."

  @spec receipt(map(), map(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def receipt(request, proof, broker, now) when is_map(proof) and is_binary(broker) do
    with true <- Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, broker) or {:error, :mr_guard_broker_mismatch},
         true <- proof["source_thread_id"] == broker or {:error, :mr_guard_broker_mismatch},
         %{"source" => "codex_app/read_thread", "observed_at" => owner_at, "response" => %{"schemaVersion" => 1, "thread" => owner}} when is_map(owner) <- proof["owner"],
         %{"id" => thread, "cwd" => cwd, "projectId" => project, "queue_observation" => queue} when is_map(queue) <- proof["native"],
         :ok <- identity(request, owner, thread, cwd, project),
         true <- owner["status"] in [%{"type" => "idle"}, %{"type" => "notLoaded"}] or {:error, :mr_guard_owner_not_quiet},
         :ok <- empty_queue(queue, thread),
         :ok <- latest_turn(request, proof["native"], now),
         :ok <- fresh(owner_at, now),
         :ok <- fresh(queue["observed_at"], now) do
      {:ok, %{"source_thread_id" => broker, "owner_sha256" => digest(proof["owner"]), "native_sha256" => digest(proof["native"]), "checked_at" => DateTime.to_iso8601(now)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :mr_guard_evidence_invalid}
    end
  end

  def receipt(_request, _proof, _broker, _now), do: {:error, :mr_guard_evidence_required}

  defp identity(request, owner, thread, cwd, project) do
    expected = %{"id" => thread, "cwd" => cwd, "kind" => "codex", "hostId" => "local"}

    if Map.take(owner, Map.keys(expected)) == expected and
         {thread, cwd, project} == {request["existing_thread_id"], request["cwd"], request["codex_project_id"]},
       do: :ok,
       else: {:error, :mr_guard_identity_mismatch}
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

  defp empty_queue(queue, thread) do
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
