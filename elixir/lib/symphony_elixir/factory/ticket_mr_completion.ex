defmodule SymphonyElixir.Factory.TicketMrCompletion do
  @moduledoc "Records a typed MR result from the same authenticated native turn, without another invocation."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{DesktopRequest, Store, TicketMrGuard, TicketMrOperation, TicketParentEvidence}

  @spec complete(Store.connection(), String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(store, key, turn_id, broker, opts \\ []) do
    reader = Keyword.get(opts, :reader, AppServer)

    with {:ok, request} <- DesktopRequest.get(store, key),
         true <-
           (TicketMrOperation.typed_request?(request) and DesktopRequest.payload_intact?(request)) or
             {:error, :mr_completion_request_invalid},
         :ok <- TicketMrOperation.authorize_readback(store, request),
         claim when is_map(claim) <- Store.one!(store, "SELECT * FROM ticket_mr_claims WHERE request_key=?", [key]),
         {:ok, receipt} <- Jason.decode(claim["receipt_json"]),
         true <-
           (get_in(receipt, ["guard", "source_thread_id"]) == broker and is_binary(broker)) or
             {:error, :mr_completion_broker_mismatch},
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, native} <-
           reader.read_native_thread(request["existing_thread_id"],
             workspace: request["cwd"],
             include_turns: false,
             history_after_turn: metadata["previous_turn_id"]
           ),
         {:ok, completion} <- project(request, native, turn_id, broker),
         {:ok, confirmed} <-
           reader.read_native_thread(request["existing_thread_id"], workspace: request["cwd"], include_turns: false),
         true <-
           Map.take(confirmed, ~w(id cwd projectId updatedAt)) == Map.take(native, ~w(id cwd projectId updatedAt)) or
             {:error, :mr_completion_history_changed} do
      Store.transaction!(store, &record_completion(&1, key, request, claim, completion))
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_completion_evidence_unproven}
    end
  end

  defp record_completion(tx, key, request, claim, completion) do
    with {:ok, ^request} <- DesktopRequest.get(tx, key),
         ^claim <- Store.one!(tx, "SELECT * FROM ticket_mr_claims WHERE request_key=?", [key]),
         :ok <- TicketMrOperation.authorize_readback(tx, request) do
      DesktopRequest.complete(tx, key, completion)
    else
      _ -> {:error, :mr_completion_request_changed}
    end
  end

  @spec project(map(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def project(request, native, turn_id, broker) do
    with {:ok, metadata, turns} <- projection_context(request, native, broker),
         [{turn, index, _}] <-
           for(
             {turn, index} <- Enum.with_index(turns),
             item <- turn["items"],
             TicketParentEvidence.delegation_item?(item, broker, request["prompt"]),
             do: {turn, index, item}
           ),
         true <-
           (turn["id"] == turn_id and turn_id != metadata["previous_turn_id"]) or {:error, :mr_completion_turn_mismatch},
         previous when is_integer(previous) <- Enum.find_index(turns, &(&1["id"] == metadata["previous_turn_id"])),
         true <- index > previous or {:error, :mr_completion_turn_mismatch},
         true <- (turn["status"] == "completed" and is_nil(turn["error"])) or {:error, :mr_completion_turn_incomplete},
         :ok <- turn_time(request, turn),
         [final] <- Enum.filter(turn["items"], &(&1["type"] == "agentMessage" and &1["phase"] == "final_answer")),
         text when is_binary(text) and byte_size(text) in 1..65_536 <- final["text"],
         {:ok, result} when is_map(result) <- Jason.decode(text),
         {:ok, calls} <- calls(turn["items"]) do
      {:ok, %{"thread_id" => native["id"], "turn_id" => turn_id, "output" => %{"result" => result, "completed_tool_calls" => calls}}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :mr_completion_json_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :mr_completion_evidence_unproven}
    end
  end

  defp projection_context(request, native, broker) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- TicketMrOperation.typed_request?(request) or {:error, :mr_completion_request_invalid},
         %{"version" => 2, "operation" => "CREATE_OR_REUSE_DRAFT_MR"} <- metadata["delivery_operation"],
         true <- broker_id?(broker),
         true <- String.starts_with?(request["prompt"], "Factory request ID: " <> request["request_key"] <> "\n"),
         true <- native_identity?(request, metadata, native) or {:error, :mr_completion_native_identity_mismatch},
         turns when is_list(turns) and length(turns) in 1..5000 <- native["turns"],
         %{"mode" => "PAGED_AFTER_ANCHOR", "anchor_turn_id" => anchor, "turn_count" => count, "updated_at" => version} <-
           native["history_observation"],
         true <- anchor == metadata["previous_turn_id"] and hd(turns)["id"] == anchor,
         true <-
           (count == length(turns) and is_number(version) and version == native["updatedAt"]) or
             {:error, :mr_completion_history_incomplete},
         true <- Enum.all?(turns, &complete_items?/1) and length(Enum.uniq_by(turns, & &1["id"])) == length(turns) do
      {:ok, metadata, turns}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :mr_completion_json_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :mr_completion_evidence_unproven}
    end
  end

  defp broker_id?(broker) do
    is_binary(broker) and Regex.match?(~r/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, broker)
  end

  defp complete_items?(%{"id" => id, "items" => items}) when is_binary(id) and is_list(items) and length(items) <= 10_000 do
    Enum.all?(items, &(is_map(&1) and is_binary(&1["id"]) and is_binary(&1["type"]))) and
      length(Enum.uniq_by(items, & &1["id"])) == length(items)
  end

  defp complete_items?(_), do: false

  defp native_identity?(request, metadata, native) do
    cwd = get_in(metadata, ["delivery_operation", "controller_native_cwd"]) || request["cwd"]
    native["id"] == request["existing_thread_id"] and native["cwd"] == cwd and TicketMrGuard.native_project_matches?(native, request["codex_project_id"])
  end

  defp turn_time(request, turn) do
    with {:ok, claimed, _} <- DateTime.from_iso8601(request["claimed_at"] || ""),
         started when is_number(started) <- turn["startedAt"],
         completed when is_number(completed) <- turn["completedAt"],
         true <-
           completed >= started and
             started + if(is_integer(started), do: 1, else: 0) > DateTime.to_unix(claimed, :microsecond) / 1_000_000 do
      :ok
    else
      _ -> {:error, :mr_completion_turn_time_invalid}
    end
  end

  defp calls(items) do
    Enum.reduce_while(Enum.filter(items, &(&1["type"] in ~w(mcpToolCall mcp_tool_call))), {:ok, []}, fn item, {:ok, calls} ->
      cond do
        item["status"] != "completed" ->
          {:halt, {:error, :mr_completion_tool_incomplete}}

        not is_binary(item["server"]) or not is_binary(item["tool"]) ->
          {:halt, {:error, :mr_completion_tool_invalid}}

        is_nil(item["result"]) and is_nil(item["error"]) ->
          {:halt, {:error, :mr_completion_tool_payload_missing}}

        true ->
          {:cont, {:ok, calls ++ [call_record(item)]}}
      end
    end)
  end

  defp call_record(item) do
    failed = item["isError"] == true or not is_nil(item["error"]) or (is_map(item["result"]) and item["result"]["isError"] == true)
    %{"server" => item["server"], "tool" => item["tool"], "status" => "completed", "isError" => failed, "error" => item["error"]}
  end
end
