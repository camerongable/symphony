defmodule SymphonyElixir.Factory.TicketParentEvidence do
  @moduledoc "Exact completed delegation provenance; persisted history never attests live idle ownership."

  alias SymphonyElixir.Factory.{DesktopRequest, SpecialistErrorNotice}

  @spec observe(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def observe(request, broker, native) when is_map(native) and is_binary(broker) do
    with true <- Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, broker) or {:error, :parent_broker_identity_invalid},
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt},
         {:ok, %{"generation" => generation} = metadata} when is_integer(generation) and generation > 0 <- Jason.decode(request["metadata_json"]),
         true <- Map.get(metadata, "broker_thread_id", broker) == broker or {:error, :parent_broker_identity_mismatch},
         :ok <- validate_parent(request, native),
         {:ok, tool} <- expected_tool(request),
         {:ok, turn, item} <- exact_invocation(native["turns"], tool, wrapper_variants(broker, request["prompt"])),
         :ok <- validate_timestamps(request, turn),
         {:ok, rendered_notice} <- rendered_notice(metadata, turn, digest(native)) do
      {:ok,
       %{
         "request_key" => request["request_key"],
         "payload_sha256" => request["payload_sha256"],
         "generation" => generation,
         "source_thread_id" => broker,
         "thread_id" => native["id"],
         "cwd" => native["cwd"],
         "turn_id" => turn["id"],
         "item_id" => item["id"],
         "started_at" => turn["startedAt"],
         "started_at_precision" => if(is_integer(turn["startedAt"]), do: "SECOND", else: "FRACTIONAL_SECOND"),
         "completed_at" => turn["completedAt"],
         "readback_sha256" => digest(native),
         "invocation_sha256" => digest(item),
         "rendered_specialist_notice" => rendered_notice,
         "status" => "OBSERVED_COMPLETED",
         "history_complete" => full_history?(native),
         "live_idle_attested" => false
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :parent_native_readback_invalid}
    end
  end

  def observe(_request, _broker, _native), do: {:error, :parent_native_readback_invalid}

  @doc "Exposes the target's recorded empty inventory as historical evidence, never current attachment state."
  @spec attachment_observation(map(), map()) :: {:ok, map()} | {:error, atom()}
  def attachment_observation(native, receipt) do
    with true <- receipt["readback_sha256"] == digest(native) and full_history?(native),
         calls <- for(turn <- native["turns"], item <- turn["items"], item["type"] == "mcpToolCall" and item["server"] == "codex_app" and item["tool"] == "list_artifacts", do: {turn, item}),
         [{turn, item}] <- calls,
         true <- turn["status"] == "completed" and is_number(turn["completedAt"]),
         false <- Enum.any?(native["turns"], &attachment_mutation?/1),
         [_] <- empty_artifact_call([item]) do
      {:ok,
       %{
         "historical" => true,
         "turn_id" => turn["id"],
         "item_id" => item["id"],
         "completed_at" => turn["completedAt"],
         "native_readback_sha256" => receipt["readback_sha256"],
         "observation" => Map.take(item, ~w(server tool arguments result))
       }}
    else
      _ -> {:error, :parent_attachment_history_unproven}
    end
  end

  defp attachment_mutation?(turn) do
    Enum.any?(turn["items"], fn item ->
      type = item["type"] || ""
      tool = String.downcase(item["tool"] || item["name"] || "")

      String.contains?(tool, "worktree") or tool in ~w(handoff_thread move_thread_to_project) or
        String.starts_with?(type, "collabAgent") or String.contains?(String.downcase(type), "worktree")
    end)
  end

  @doc "Extracts a bounded final result from the already attested completed native turn."
  @spec completion(map(), map()) :: {:ok, map()} | {:error, atom()}
  def completion(native, receipt) do
    with true <- receipt["readback_sha256"] == digest(native),
         [turn] <- Enum.filter(native["turns"], &(&1["id"] == receipt["turn_id"])),
         [final] <- Enum.filter(turn["items"], &(&1["type"] == "agentMessage" and &1["phase"] == "final_answer")),
         text when is_binary(text) and byte_size(text) <= 2048 <- final["text"],
         {:ok, %{"acknowledged" => acknowledged} = result} <- terminal_ack(text),
         true <- valid_acknowledgment_result?(acknowledged, result) do
      calls =
        turn["items"]
        |> Enum.filter(&completed_mcp?(&1))
        |> Enum.map(&Map.take(&1, ~w(server tool)))

      is_recovery_request? = String.ends_with?(receipt["request_key"] || "", ":bootstrap-recovery:1")
      include_bootstrap_evidence? = acknowledged == false or is_recovery_request?

      bootstrap_evidence =
        if include_bootstrap_evidence? do
          %{
            "list_artifacts" => empty_artifact_call(turn["items"]),
            "completed_commands" => if(is_recovery_request?, do: compact_context_commands(turn["items"]), else: [])
          }
        end

      output = %{"result" => result, "completed_tool_calls" => calls}
      output = add_rendered_notice(output, receipt["rendered_specialist_notice"])
      output = if include_bootstrap_evidence?, do: Map.merge(output, %{"bootstrap_evidence" => bootstrap_evidence, "native_readback_sha256" => receipt["readback_sha256"]}), else: output

      completion = %{
        "thread_id" => receipt["thread_id"],
        "turn_id" => receipt["turn_id"],
        "output" => output
      }

      if byte_size(Jason.encode!(completion)) <= 16_384, do: {:ok, completion}, else: {:error, :parent_native_completion_invalid}
    else
      _ -> {:error, :parent_native_completion_invalid}
    end
  end

  defp add_rendered_notice(output, nil), do: output
  defp add_rendered_notice(output, proof), do: Map.put(output, "rendered_specialist_notice", proof)

  defp valid_acknowledgment_result?(acknowledged, result),
    do: is_boolean(acknowledged) and Map.keys(result) == ["acknowledged"]

  defp rendered_notice(%{"specialist_notice_text" => text, "specialist_notice_ids" => ids} = metadata, turn, readback_sha) do
    with [final] <- Enum.filter(turn["items"], &(&1["type"] == "agentMessage" and &1["phase"] == "final_answer")),
         true <- final["text"] == text <> "\n{\"acknowledged\":true}" do
      text_sha = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      proof = %{"notice_ids" => ids, "text_sha256" => text_sha, "native_readback_sha256" => readback_sha}
      with :ok <- SpecialistErrorNotice.validate_render(metadata, %{"rendered_specialist_notice" => proof}, readback_sha), do: {:ok, proof}
    else
      _ -> {:error, :specialist_notice_render_unproven}
    end
  end

  defp rendered_notice(_metadata, _turn, _readback), do: {:ok, nil}

  defp empty_artifact_call(items) do
    case Enum.find(items, fn
           %{"type" => "mcpToolCall", "server" => "codex_app", "tool" => "list_artifacts", "arguments" => %{}, "result" => %{"content" => [%{"type" => "text", "text" => text}]}} = item ->
             is_binary(text) and byte_size(text) <= 32 and completed_mcp?(item) and Jason.decode(text) == {:ok, %{"artifacts" => []}}

           _ ->
             false
         end) do
      item when is_map(item) -> [Map.take(item, ~w(server tool arguments result))]
      _ -> []
    end
  end

  defp compact_context_commands(items) do
    items
    |> Enum.filter(fn
      %{"type" => "commandExecution", "status" => "completed", "exitCode" => 0, "cwd" => cwd, "commandActions" => [%{"command" => command}]} ->
        is_binary(cwd) and byte_size(cwd) <= 4096 and is_binary(command) and byte_size(command) <= 2048

      _ ->
        false
    end)
    |> Enum.take(4)
    |> Enum.map(fn item ->
      action = hd(item["commandActions"])
      %{"status" => item["status"], "exit_code" => item["exitCode"], "cwd" => item["cwd"], "command_actions" => [%{"command" => action["command"]}]}
    end)
  end

  defp completed_mcp?(item) do
    item["type"] == "mcpToolCall" and item["status"] == "completed" and is_nil(item["error"]) and
      item["isError"] != true and not result_error?(item["result"]) and
      is_binary(item["server"]) and is_binary(item["tool"]) and not is_nil(item["result"])
  end

  defp result_error?(result) when is_map(result), do: result["isError"] == true
  defp result_error?(_result), do: false

  defp terminal_ack(text) do
    case :binary.matches(text, "{") do
      [] ->
        {:error, :invalid_terminal_acknowledgment}

      matches ->
        {offset, _length} = List.last(matches)
        <<prose::binary-size(offset), object::binary>> = text

        with true <- not String.contains?(prose, ["{", "}"]) or {:error, :ambiguous_final_objects},
             true <- not formatted_final_object?(text) or {:error, :formatted_final_object},
             true <- Regex.match?(~r/\A\{\s*"acknowledged"\s*:\s*(?:true|false)\s*\}\s*\z/, object) or {:error, :invalid_terminal_acknowledgment},
             {:ok, %{"acknowledged" => acknowledged} = result} when is_boolean(acknowledged) <- Jason.decode(object),
             true <- Map.keys(result) == ["acknowledged"] or {:error, :invalid_terminal_acknowledgment} do
          {:ok, result}
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_terminal_acknowledgment}
        end
    end
  end

  defp formatted_final_object?(text),
    do: String.contains?(text, "```") or Regex.match?(~r/(?:\A|\n) {0,3}~{3,}/, text)

  defp validate_parent(request, native) do
    cond do
      request["target_kind"] != "TICKET_CHAT" -> {:error, :not_a_ticket_chat_request}
      not parent_identity_matches?(request, native) -> {:error, :parent_native_identity_mismatch}
      not Map.has_key?(native, "projectId") or not is_nil(native["projectId"]) -> {:error, :parent_native_project_not_proven}
      true -> :ok
    end
  end

  defp full_history?(%{"history_observation" => %{"mode" => "PAGED_FULL", "next_cursor" => nil, "turn_count" => count, "updated_at" => version}, "turns" => turns, "updatedAt" => version}),
    do: is_number(version) and count == length(turns)

  defp full_history?(_native), do: false

  defp parent_identity_matches?(request, native) do
    expected = request["thread_id"] || request["existing_thread_id"]

    is_binary(native["id"]) and native["id"] != "" and native["cwd"] == request["cwd"] and
      (is_nil(expected) or native["id"] == expected)
  end

  defp expected_tool(%{"action" => "CREATE"}), do: {:ok, "create_thread"}
  defp expected_tool(%{"action" => "FOLLOWUP"}), do: {:ok, "send_message_to_thread"}
  defp expected_tool(_request), do: {:error, :parent_native_action_invalid}

  defp exact_invocation(turns, tool, expected) when is_list(turns) do
    with :ok <- inspectable_history(turns) do
      select_invocation(Enum.flat_map(turns, &matching_items(&1, tool, expected)))
    end
  end

  defp exact_invocation(_turns, _tool, _expected), do: {:error, :parent_native_history_missing}

  defp select_invocation(matches) do
    case matches do
      [{%{"status" => "completed", "id" => turn_id} = turn, %{"id" => item_id} = item}]
      when is_binary(turn_id) and turn_id != "" and is_binary(item_id) and item_id != "" ->
        {:ok, turn, item}

      [_] ->
        {:error, :parent_native_turn_incomplete}

      [] ->
        {:error, :parent_native_invocation_not_observed}

      _ ->
        {:error, :parent_native_invocation_ambiguous}
    end
  end

  defp inspectable_history(turns) do
    items = Enum.flat_map(turns, fn turn -> if is_map(turn) and is_list(turn["items"]), do: turn["items"], else: [] end)

    cond do
      not Enum.all?(turns, &inspectable_turn?/1) -> {:error, :parent_native_history_incomplete}
      not Enum.all?(items, &inspectable_item?/1) -> {:error, :parent_native_history_incomplete}
      duplicate_ids?(turns) or duplicate_ids?(items) -> {:error, :parent_native_history_identity_conflict}
      true -> :ok
    end
  end

  defp inspectable_turn?(turn) when is_map(turn), do: present?(turn["id"]) and present?(turn["status"]) and is_list(turn["items"])
  defp inspectable_turn?(_turn), do: false
  defp inspectable_item?(%{"type" => "functionCallOutput"} = item), do: Enum.all?(~w(id namespace name output), &is_binary(item[&1])) and present?(item["id"])
  defp inspectable_item?(item) when is_map(item), do: present?(item["id"]) and present?(item["type"])
  defp inspectable_item?(_item), do: false
  defp duplicate_ids?(values), do: length(Enum.uniq_by(values, & &1["id"])) != length(values)
  defp present?(value), do: is_binary(value) and value != ""

  defp matching_items(%{"items" => items} = turn, tool, expected) when is_list(items) do
    for %{"type" => "functionCallOutput", "namespace" => "codex_app", "name" => ^tool, "output" => output} = item <- items,
        output in expected,
        do: {turn, item}
  end

  defp validate_timestamps(request, turn) do
    with {:ok, claimed, _} <- DateTime.from_iso8601(request["claimed_at"] || ""),
         true <- is_number(turn["startedAt"]) and is_number(turn["completedAt"]),
         true <- start_not_before_claim?(turn["startedAt"], DateTime.to_unix(claimed, :microsecond) / 1_000_000),
         true <- turn["completedAt"] >= turn["startedAt"] do
      :ok
    else
      _ -> {:error, :parent_native_turn_time_invalid}
    end
  end

  defp start_not_before_claim?(started, claimed) when is_integer(started), do: started + 1 > claimed
  defp start_not_before_claim?(started, claimed), do: started >= claimed

  defp wrapper_variants(broker, prompt) do
    [wrapper(broker, prompt), wrapper(broker, escape_xml_text(prompt))] |> Enum.uniq()
  end

  @doc false
  @spec delegation_item?(map(), String.t(), String.t()) :: boolean()
  def delegation_item?(%{"type" => "functionCallOutput", "namespace" => "codex_app", "name" => "send_message_to_thread", "output" => output}, broker, prompt),
    do: output in wrapper_variants(broker, prompt)

  def delegation_item?(_, _, _), do: false

  defp escape_xml_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp wrapper(broker, prompt), do: "<codex_delegation>\n  <source_thread_id>#{broker}</source_thread_id>\n  <input>#{prompt}</input>\n</codex_delegation>"
  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
