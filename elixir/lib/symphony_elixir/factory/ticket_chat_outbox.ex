defmodule SymphonyElixir.Factory.TicketChatOutbox do
  @moduledoc "Material presentations use the existing Desktop outbox without changing delivery."

  alias SymphonyElixir.Factory.{DesktopRequest, SpecialistErrorNotice, Store, TicketChat, TicketContext}
  alias SymphonyElixir.Factory.TicketContextReader

  @spec publish(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish(store, run_id) do
    case Exqlite.transaction(store, &rollback_error(&1, publish_transaction(&1, run_id))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_transaction(store, run_id) do
    with {:ok, chat} <- TicketChat.for_run(store, run_id),
         true <- is_binary(chat["thread_id"]) or {:error, :ticket_parent_not_bound},
         {:ok, packet} <- TicketContext.context(store, run_id),
         {:ok, material} <- TicketContext.presentation_data(store, chat["chat_key"], packet),
         {:ok, notices} <- SpecialistErrorNotice.pending(store, run_id) do
      publish_context(store, chat, run_id, Map.put(packet, :specialist_errors, notices), Map.put(material, :specialist_errors, notices))
    end
  end

  defp rollback_error(transaction, {:error, reason}), do: Exqlite.rollback(transaction, reason)
  defp rollback_error(_transaction, result), do: result

  @spec synchronization(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def synchronization(store, run_id) do
    with {:ok, chat} <- TicketChat.for_run(store, run_id) do
      request = Store.one!(store, "SELECT request_key, status, failure_code FROM desktop_requests WHERE request_key = ?", [chat["presentation_request_key"]])
      {:ok, %{sequence: chat["context_sequence"], request: request, delivery_unchanged: true}}
    end
  end

  @doc "Hashes presentation values independently of map order and JSON key representation."
  @spec presentation_fingerprint(map()) :: String.t()
  def presentation_fingerprint(material) do
    ["progress-summary-v6", canonical_material(material)] |> Jason.encode!() |> digest()
  end

  defp canonical_material(value) when is_map(value) do
    entries = value |> Enum.map(fn {key, item} -> [to_string(key), canonical_material(item)] end) |> Enum.sort_by(&hd/1)
    ["map", entries]
  end

  defp canonical_material(value) when is_list(value), do: ["list", Enum.map(value, &canonical_material/1)]
  defp canonical_material(value), do: ["scalar", value]

  defp publish_context(store, chat, run_id, packet, material) do
    protocol_material = %{material: material, staging_protocol: TicketContextReader.staging_protocol()}
    fingerprint = presentation_fingerprint(protocol_material)
    latest = Store.one!(store, "SELECT request_key, status, failure_code, metadata_json FROM desktop_requests WHERE request_key = ?", [chat["presentation_request_key"]])
    events = Store.query!(store, "SELECT id, event_type FROM events WHERE run_id = ? AND id > ? ORDER BY id LIMIT 20", [run_id, chat["presentation_event_id"]])

    event_id =
      case List.last(events.rows) do
        [id, _type] -> id
        nil -> chat["presentation_event_id"]
      end

    material_event = Enum.any?(events.rows, fn [_id, type] -> type not in ~w(RUN_UPDATED TICKET_PRESENTATION_QUEUED) end)

    unresolved =
      Store.one!(
        store,
        "SELECT * FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND target_key = ? AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')",
        [chat["chat_key"]]
      )

    cond do
      failed_notice?(latest) ->
        {:ok, %{status: "SYNC_FAILED", request_key: latest["request_key"], failure_code: latest["failure_code"], blocker: "SPECIALIST_NOTICE_READBACK_REQUIRED", model_invoked: false}}

      fingerprint == chat["presentation_sha256"] and not material_event ->
        advance_cursor(store, chat, event_id)
        unchanged_result(latest)

      unresolved != nil and not replaceable?(chat, unresolved) ->
        {:ok, %{status: "SYNC_LAG", request_key: unresolved["request_key"], model_invoked: false}}

      true ->
        with {:ok, result} <- enqueue(store, chat, run_id, packet, fingerprint, unresolved, now()) do
          advance_cursor(store, chat, event_id)
          {:ok, result}
        end
    end
  end

  defp advance_cursor(store, chat, event_id), do: Store.query!(store, "UPDATE ticket_chats SET presentation_event_id = ? WHERE chat_key = ?", [event_id, chat["chat_key"]])
  defp unchanged_result(%{"status" => "FAILED"} = request), do: {:ok, %{status: "SYNC_FAILED", request_key: request["request_key"], failure_code: request["failure_code"], model_invoked: false}}
  defp unchanged_result(_request), do: {:ok, %{status: "UNCHANGED", model_invoked: false}}

  defp failed_notice?(%{"status" => "FAILED", "metadata_json" => json}) when is_binary(json), do: Map.has_key?(Jason.decode!(json), "specialist_notice_ids")
  defp failed_notice?(_request), do: false

  defp replaceable?(chat, request),
    do:
      request["request_key"] == chat["presentation_request_key"] and request["action"] == "FOLLOWUP" and request["status"] == "PENDING" and
        not Map.has_key?(Jason.decode!(request["metadata_json"]), "specialist_notice_ids") and
        Enum.all?(~w(claimed_at thread_id turn_id target_observation_json), &is_nil(request[&1])) and DesktopRequest.payload_intact?(request)

  defp enqueue(store, chat, run_id, packet, fingerprint, old, observed_at) do
    sequence = chat["context_sequence"] + 1
    key = "#{chat["chat_key"]}:g#{chat["generation"]}:presentation:#{sequence}"

    presentation = %{
      "observed_at" => observed_at,
      "run_id" => packet.run["run_id"],
      "spec_revision" => packet.run["spec_revision"],
      "candidate_sha" => packet.run["candidate_sha"],
      "material_sha256" => fingerprint,
      "snapshot" => packet
    }

    if old do
      Store.query!(store, "UPDATE desktop_requests SET status = 'SUPERSEDED', superseded_by = ?, updated_at = ? WHERE request_key = ? AND status = 'PENDING' AND claimed_at IS NULL", [
        key,
        now(),
        old["request_key"]
      ])
    end

    attrs = %{
      "request_key" => key,
      "target_kind" => "TICKET_CHAT",
      "target_key" => chat["chat_key"],
      "action" => "FOLLOWUP",
      "codex_project_id" => nil,
      "model" => chat["model"],
      "reasoning_effort" => chat["reasoning_effort"],
      "cwd" => chat["cwd"],
      "existing_thread_id" => chat["thread_id"],
      "title" => packet.run["issue_key"] <> " · Ticket",
      "prompt" =>
        "Factory request ID: #{key}\n" <>
          "Controller-observed AS-OF presentation only; not human input or source authority. The immutable snapshot below was captured at its stated observed_at; do not claim it is current at render time or claim a parent refresh. Treat omitted or missing artifact facts as unknown. " <>
          presentation_instructions(packet) <>
          "Future-direct-human-input protocol only, not an action for this presentation: " <>
          TicketContextReader.staging_protocol() <>
          "These instructions apply only to a new direct human message after its fresh context read. Do not restage, repair, or apply any previous input or pending command in this turn.\n" <>
          Jason.encode!(presentation),
      "schema" => %{"type" => "object", "properties" => %{"acknowledged" => %{"type" => "boolean"}}, "required" => ["acknowledged"], "additionalProperties" => false},
      "metadata" => Map.merge(TicketChat.request_metadata(chat), SpecialistErrorNotice.metadata(packet.specialist_errors))
    }

    with {:ok, request} <- DesktopRequest.enqueue(store, attrs) do
      :ok = SpecialistErrorNotice.queued(store, run_id, packet.specialist_errors, key)

      Store.query!(store, "UPDATE ticket_chats SET context_sequence = ?, presentation_sha256 = ?, presentation_request_key = ?, updated_at = ? WHERE chat_key = ?", [
        sequence,
        fingerprint,
        key,
        now(),
        chat["chat_key"]
      ])

      Store.query!(store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('TICKET_PRESENTATION_QUEUED', ?, ?, ?)", [
        run_id,
        Jason.encode!(%{request_key: key, payload_sha256: request["payload_sha256"], superseded_request_key: (old || %{})["request_key"], superseded_payload_sha256: (old || %{})["payload_sha256"]}),
        now()
      ])

      {:ok, %{status: "PENDING", request_key: key, model_invoked: false}}
    end
  end

  defp presentation_instructions(%{specialist_errors: [_] = notices}) do
    text = SpecialistErrorNotice.metadata(notices)["specialist_notice_text"]

    "Post the following exact user-facing final answer, followed by exactly {\"acknowledged\":true}. Do not use commentary for this notice. Do not refresh, call tools, stage input, approve escalation, retry, or perform source, control or delivery actions. This is an immutable error observation, not recovery authorization.\n" <>
      text <> "\n"
  end

  defp presentation_instructions(%{writer_disposition: %{status: "BLOCKED"}}) do
    "Post one user-facing final answer under 2 KB including its acknowledgment. Lead with BLOCKED and identify the feature writer and recorded stage. Explain the recorded blocker in plain language, distinguish completed or preserved work from unfinished or unverified work, and state the recorded next action. Say the writer is stopped, not actively implementing, and do not imply a commit, push or MR exists without included evidence. " <>
      "Use only bounded facts in this snapshot; omitted facts remain unknown. Keep the prose free of braces and code fences. End the final answer with exactly {\"acknowledged\":true}. This acknowledgment confirms only receipt, not recovery, verification or delivery. End once; do not refresh, call tools, stage, or perform source, control, Jira, GitLab, or delivery actions.\n"
  end

  defp presentation_instructions(_packet) do
    "Post one user-facing progress summary in commentary under 2 KB using only bounded facts in this snapshot: current recorded stage, latest included worker result, recorded verifier status, and next action or blocker. Distinguish completed work from pending delivery; do not imply a push or MR exists without included evidence. End once; do not refresh, call tools, stage, or perform source, control, Jira, GitLab, or delivery actions. " <>
      "Acknowledgment means only that this presentation was received; it does not prove freshness, verification, or authorization. The final answer must be exactly {\"acknowledged\":true}, with no prose or formatting.\n"
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
