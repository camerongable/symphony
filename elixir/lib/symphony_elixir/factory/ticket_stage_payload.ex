defmodule SymphonyElixir.Factory.TicketStagePayload do
  @moduledoc "Read-only preparation of literal staging commands from an unclosed native human input."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChat, TicketContextReader}

  @spec prepare(Store.connection(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(store, run_id, workflow, opts \\ []) do
    reader = Keyword.get(opts, :reader, AppServer)

    with {:ok, chat, run} <- capture(store, run_id),
         {:ok, locator} <- locator(store, run_id, chat, workflow),
         native_options = [workspace: chat["cwd"], include_turns: false, include_latest_turn: true],
         {:ok, native} <- reader.read_native_thread(chat["thread_id"], native_options),
         {:ok, turn, user, body} <- direct_input(native, chat),
         {:ok, operations} <- operations(body),
         {:ok, ^chat, ^run} <- capture(store, run_id) do
      binding = Map.take(run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", chat["generation"])
      identity = [run_id, turn["id"], user["id"], user["clientId"], digest(body), binding]
      attrs = Map.merge(binding, %{"proposal_id" => "native-" <> digest(Jason.encode!(identity)), "body" => body, "operations" => operations})
      json = Jason.encode!(attrs)
      payload = Base.encode64(json)
      command = "#{TicketContextReader.cli_prefix()} stage #{run_id} --payload-base64 #{payload} --workflow #{locator["workflow"]}"

      if byte_size(json) <= 24_576 and byte_size(payload) <= 32_768 do
        {:ok,
         %{
           payload_base64: payload,
           stage_command: command,
           cwd: locator["cwd"],
           body_sha256: digest(body),
           native_turn_id: turn["id"],
           native_item_id: user["id"],
           status: "PREPARED_ONLY",
           staged: false
         }}
      else
        {:error, :native_stage_payload_too_large}
      end
    else
      {:error, _} = error -> error
      {:ok, _, _} -> {:error, :native_preparation_binding_changed}
      _ -> {:error, :native_stage_preparation_unproven}
    end
  end

  defp capture(store, run_id) do
    with {:ok, chat} <- TicketChat.bound_for_run(store, run_id),
         {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- TicketChat.ordinary_delivery_eligibility(run) do
      identity =
        Map.take(
          chat,
          ~w(chat_key scope_key issue_id issue_key repo_key route generation create_request_key directory_name cwd model reasoning_effort broker_thread_id thread_id observation_json context_reader_json created_at)
        )

      {:ok, identity, run}
    end
  end

  defp locator(store, run_id, chat, workflow) do
    with :ok <- TicketContextReader.validate(store, run_id, chat["context_reader_json"]),
         {:ok, locator} when is_map(locator) <- Jason.decode(chat["context_reader_json"] || "null"),
         true <- locator["workflow"] == workflow,
         true <- safe_literal?(workflow) and safe_literal?(run_id) do
      {:ok, locator}
    else
      _ -> {:error, :native_stage_locator_unproven}
    end
  end

  defp direct_input(native, chat) when is_map(native) do
    observation = native["latest_turn_observation"]
    expected_params = %{"threadId" => chat["thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}

    with true <- native["id"] == chat["thread_id"] and native["cwd"] == chat["cwd"],
         true <- Map.has_key?(native, "projectId") and is_nil(native["projectId"]),
         true <- is_number(native["updatedAt"]),
         true <- is_map(observation) and observation["mode"] == "LATEST_DESC",
         true <- observation["parameters"] == expected_params and observation["updated_at"] == native["updatedAt"],
         raw when is_map(raw) <- observation["raw_response"],
         true <- observation["sha256"] == digest(Jason.encode!(raw)),
         :ok <- fresh_observation(observation["observed_at"]),
         [%{"id" => turn_id, "items" => items} = turn] when is_list(items) <- raw["data"],
         true <- unclosed_turn?(turn),
         true <- text?(turn_id, 256) and length(items) <= 1000,
         false <- Enum.any?(items, &delegated?/1),
         [%{"id" => item_id, "clientId" => client_id, "content" => content} = user] <- Enum.filter(items, &(is_map(&1) and &1["type"] == "userMessage")),
         true <- text?(item_id, 256) and text?(client_id, 256) and text_content?(content),
         body = Enum.map_join(content, & &1["text"]),
         true <- text?(body, 12_288) do
      {:ok, turn, user, body}
    else
      _ -> {:error, :active_direct_native_input_unproven}
    end
  end

  defp direct_input(_native, _chat), do: {:error, :active_direct_native_input_unproven}

  # A separate app-server may report an owning-Desktop turn as interrupted
  # without a persisted completion. Preparation grants no authority; admission still
  # requires the completed native turn and its matching staging receipt.
  defp unclosed_turn?(%{"status" => status} = turn),
    do: status in ["inProgress", "interrupted"] and Map.get(turn, "completedAt") == nil

  defp unclosed_turn?(_), do: false

  defp fresh_observation(value) when is_binary(value) do
    with {:ok, observed, _} <- DateTime.from_iso8601(value),
         age = DateTime.diff(DateTime.utc_now(), observed, :millisecond),
         true <- age >= 0 and age <= 10_000 do
      :ok
    else
      _ -> {:error, :native_observation_stale}
    end
  end

  defp fresh_observation(_), do: {:error, :native_observation_stale}

  defp operations("Revise the contract:\n" <> markdown) do
    if text?(markdown, 10_240),
      do: {:ok, [%{"operation" => "propose_contract_revision", "markdown" => markdown}]},
      else: {:error, :invalid_contract_revision}
  end

  defp operations("Rework the current candidate."), do: {:ok, [%{"operation" => "request_rework"}]}
  defp operations("Rework the current candidate.\n"), do: {:ok, [%{"operation" => "request_rework"}]}
  defp operations(_), do: {:error, :native_preparation_grammar_unsupported}

  defp delegated?(%{"type" => "functionCallOutput", "name" => name}), do: name in ~w(create_thread send_message_to_thread)
  defp delegated?(%{"type" => type}), do: type in ~w(collabAgentSpawnToolCall collabAgentSendMessageToolCall)
  defp delegated?(_), do: false
  defp text_content?(items) when is_list(items) and items != [], do: Enum.all?(items, &match?(%{"type" => "text", "text" => value} when is_binary(value), &1))
  defp text_content?(_), do: false
  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
  defp safe_literal?(value), do: is_binary(value) and Regex.match?(~r{\A[A-Za-z0-9_./-]+\z}, value)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
