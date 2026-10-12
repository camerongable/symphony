defmodule SymphonyElixir.Factory.TicketChatOutbox do
  @moduledoc "Material presentations use the existing Desktop outbox without changing delivery."

  alias SymphonyElixir.Factory.{DesktopRequest, Store, TicketChat, TicketContext, TicketContextReader}

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
         {:ok, material} <- TicketContext.presentation_data(store, chat["chat_key"], packet) do
      publish_context(store, chat, run_id, packet, material)
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
    ["progress-summary-v5", canonical_material(material)] |> Jason.encode!() |> digest()
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
    latest = Store.one!(store, "SELECT request_key, status, failure_code FROM desktop_requests WHERE request_key = ?", [chat["presentation_request_key"]])
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

  defp replaceable?(chat, request),
    do:
      request["request_key"] == chat["presentation_request_key"] and request["action"] == "FOLLOWUP" and request["status"] == "PENDING" and
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
          "Post one user-facing progress summary in commentary under 2 KB using only bounded facts in this snapshot: current recorded stage, latest included worker result, recorded verifier status, and next action or blocker. Distinguish completed work from pending delivery; do not imply a push or MR exists without included evidence. End once; do not refresh, call tools, stage, or perform source, control, Jira, GitLab, or delivery actions. " <>
          "Acknowledgment means only that this presentation was received; it does not prove freshness, verification, or authorization. The final answer must be exactly {\"acknowledged\":true}, with no prose or formatting.\n" <>
          "Future-direct-human-input protocol only, not an action for this presentation: " <>
          TicketContextReader.staging_protocol() <>
          "These instructions apply only to a new direct human message after its fresh context read. Do not restage, repair, or apply any previous input or pending command in this turn.\n" <>
          Jason.encode!(presentation),
      "schema" => %{"type" => "object", "properties" => %{"acknowledged" => %{"type" => "boolean"}}, "required" => ["acknowledged"], "additionalProperties" => false},
      "metadata" => TicketChat.request_metadata(chat)
    }

    with {:ok, request} <- DesktopRequest.enqueue(store, attrs) do
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

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
