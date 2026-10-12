defmodule SymphonyElixir.Factory.TicketParentGuard do
  @moduledoc "Fresh owning-Desktop and native-queue observations bound to one parent followup claim."

  @spec receipt(map(), map(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def receipt(request, proof, now) when is_map(request) and is_map(proof) do
    with {:ok, owner, owner_at} <- owner_observation(proof["owner"]),
         {:ok, thread, cwd, queue} <- native_observation(proof["native"]),
         true <- identity_matches?(request, owner, thread, cwd) or {:error, :parent_guard_identity_mismatch},
         true <- owner["status"] in [%{"type" => "idle"}, %{"type" => "notLoaded"}] or {:error, :parent_owner_not_quiet},
         true <- queue_empty?(queue, thread) or {:error, :parent_queue_not_empty},
         :ok <- fresh(owner_at, now),
         :ok <- fresh(queue["observed_at"], now),
         :ok <- validate_queue_evidence(queue),
         true <- valid_broker?(proof["source_thread_id"]) or {:error, :parent_broker_identity_invalid},
         :ok <- bound_broker(request, proof["source_thread_id"]),
         {:ok, generation} <- generation(request["metadata_json"]) do
      {:ok,
       %{
         "request_key" => request["request_key"],
         "payload_sha256" => request["payload_sha256"],
         "generation" => generation,
         "thread_id" => thread,
         "source_thread_id" => proof["source_thread_id"],
         "owner_source" => "codex_app/read_thread",
         "owner_status" => owner["status"]["type"],
         "owner_observed_at" => owner_at,
         "owner_sha256" => digest(proof["owner"]["response"]),
         "queue_observed_at" => queue["observed_at"],
         "queue_sha256" => queue["sha256"],
         "guard_checked_at" => DateTime.to_iso8601(now)
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def receipt(_request, _proof, _now), do: {:error, :parent_guard_evidence_required}

  defp owner_observation(%{"source" => "codex_app/read_thread", "observed_at" => at, "response" => %{"schemaVersion" => 1, "thread" => owner}})
       when is_map(owner),
       do: {:ok, owner, at}

  defp owner_observation(_owner), do: {:error, :parent_guard_evidence_invalid}

  defp native_observation(%{"id" => thread, "cwd" => cwd, "projectId" => nil, "queue_observation" => queue}) when is_map(queue),
    do: {:ok, thread, cwd, queue}

  defp native_observation(_native), do: {:error, :parent_guard_evidence_invalid}

  defp identity_matches?(request, owner, thread, cwd) do
    thread == request["existing_thread_id"] and cwd == request["cwd"] and
      Map.take(owner, ~w(id cwd kind hostId)) == %{"id" => thread, "cwd" => cwd, "kind" => "codex", "hostId" => "local"}
  end

  defp queue_empty?(queue, thread) do
    Map.take(queue, ~w(thread_id empty_complete count_lower_bound has_more)) ==
      %{"thread_id" => thread, "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false}
  end

  defp validate_queue_evidence(%{"raw_response" => %{"data" => [], "nextCursor" => nil} = raw, "sha256" => sha}) do
    if valid_digest?(sha) and sha == digest(raw), do: :ok, else: {:error, :parent_queue_evidence_invalid}
  end

  defp validate_queue_evidence(_queue), do: {:error, :parent_queue_evidence_invalid}

  defp generation(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"generation" => n}} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, %{"generation" => _}} -> {:error, :parent_guard_generation_invalid}
      _ -> {:error, :parent_guard_evidence_invalid}
    end
  end

  defp bound_broker(%{"metadata_json" => json}, broker) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"broker_thread_id" => ^broker}} ->
        :ok

      {:ok, metadata} when is_map(metadata) ->
        if Map.has_key?(metadata, "broker_thread_id"), do: {:error, :parent_broker_identity_mismatch}, else: :ok

      _ ->
        {:error, :parent_guard_evidence_invalid}
    end
  end

  defp bound_broker(_request, _broker), do: {:error, :parent_guard_generation_invalid}

  defp fresh(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed, _} ->
        age = DateTime.diff(now, observed, :microsecond)
        if age >= 0 and age <= 10_000_000, do: :ok, else: {:error, :parent_guard_observation_expired}

      _ ->
        {:error, :parent_guard_evidence_invalid}
    end
  end

  defp fresh(_value, _now), do: {:error, :parent_guard_evidence_invalid}
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_broker?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)
  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
