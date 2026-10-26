defmodule SymphonyElixir.Factory.TicketReworkRecovery do
  @moduledoc "Evidence for exact initial rework whose native preparer was denied, not a synthetic stage receipt."
  alias SymphonyElixir.Factory.TicketContextReader
  @input_fields ~w(input_key chat_key generation thread_id turn_id item_id client_id body body_sha256 readback_sha256 origin)
  @binding ~w(generation spec_revision contract_sha256 candidate_sha)

  @spec prepare(map(), map(), map(), map()) :: {:ok, map()} | :none
  def prepare(native, chat, run, context) when is_map(native) and is_map(chat) and is_map(run) and is_map(context) do
    prepare_observation(native, chat, run, context, nil)
  end

  def prepare(_native, _chat, _run, _context), do: :none

  defp prepare_observation(native, chat, run, context, historical) do
    with true <- run["state"] == "WRITING" and run["implementation_iteration"] == 0 and is_nil(run["candidate_sha"]),
         disposition when is_map(disposition) <- context[:writer_disposition] || context["writer_disposition"],
         true <- (disposition[:status] || disposition["status"]) == "BLOCKED",
         blocked_key when is_binary(blocked_key) <- disposition[:request_key] || disposition["request_key"],
         true <- native["id"] == chat["thread_id"] and native["cwd"] == chat["cwd"],
         true <- Map.has_key?(native, "projectId") and is_nil(native["projectId"]),
         turns when is_list(turns) and turns != [] <- native["turns"],
         turn <- Enum.max_by(turns, &(&1["startedAt"] || 0)),
         %{"status" => "completed", "items" => items} <- turn,
         true <- is_number(turn["completedAt"]) and turn["completedAt"] >= turn["startedAt"],
         [user] <- Enum.filter(items, &(&1["type"] == "userMessage")),
         true <- is_binary(user["clientId"]) and is_binary(user["id"]),
         false <- Enum.any?(items, &delegated?/1),
         [%{"type" => "text", "text" => body}] <- user["content"],
         true <- body in ["Rework the current candidate.", "Rework the current candidate.\n"],
         {:ok, locator} <- recovery_locator(chat, historical),
         [refresh] <- Enum.filter(items, &command?(&1, locator["command"], locator["cwd"], "completed", 0)),
         {:ok, refreshed} <- Jason.decode(refresh["aggregatedOutput"] || ""),
         true <- refresh_matches?(refreshed, chat, run, blocked_key),
         expected <- preparation_commands(run, locator, historical),
         [failure] <- Enum.filter(items, fn item -> Enum.any?(expected, &command?(item, &1, locator["cwd"], "failed", 1)) end),
         output when is_binary(output) <- failure["aggregatedOutput"],
         true <- String.contains?(output, "Operation not permitted") and String.contains?(output, "{:port_exit, 1}"),
         true <- index(items, user) < index(items, refresh) and index(items, refresh) < index(items, failure),
         false <- Enum.any?(items, &(&1["type"] == "commandExecution" and &1 != refresh and &1 != failure)) do
      {:ok,
       %{
         "kind" => "CONTROLLER_NATIVE_REWORK_RECOVERY",
         "binding" => binding(chat, run),
         "blocked_request_key" => blocked_key,
         "turn" => turn,
         "human_item_id" => user["id"],
         "native_readback_sha256" => digest(Jason.encode!(native)),
         "locator" => locator,
         "thread_id" => native["id"],
         "cwd" => native["cwd"],
         "project_id" => nil
       }}
    else
      _ -> :none
    end
  rescue
    _ -> :none
  end

  defp recovery_locator(chat, nil) do
    with {:ok, json} <- TicketContextReader.execution_locator(chat["context_reader_json"]), do: Jason.decode(json)
  end

  defp recovery_locator(chat, %{"locator" => locator}) do
    with {:ok, saved} <- TicketContextReader.historical_locator(chat["context_reader_json"]),
         {:ok, retained} <- TicketContextReader.historical_locator(Jason.encode!(locator)),
         true <- Map.delete(saved, "command") == Map.delete(retained, "command") do
      {:ok, locator}
    else
      _ -> :none
    end
  end

  defp preparation_commands(run, locator, historical) do
    prefixes =
      if historical,
        do: [TicketContextReader.cli_prefix(), "mise exec -- elixir -pa \"_build/dev/lib/*/ebin\" -S mix factory.ticket"],
        else: [TicketContextReader.cli_prefix()]

    Enum.map(prefixes, &"#{&1} prepare-stage #{run["run_id"]} --workflow #{locator["workflow"]}")
  end

  @spec valid?(map(), map(), map()) :: boolean()
  def valid?(command, input, chat) when is_map(command) and is_map(input) and is_map(chat) do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(command["receipt_json"] || "null"),
         %{"kind" => "CONTROLLER_NATIVE_REWORK_RECOVERY", "input" => captured, "binding" => binding} = proof <- receipt["recovery_evidence"],
         true <- receipt["recovery_sha256"] == digest(Jason.encode!(proof)),
         true <- captured == Map.take(input, @input_fields),
         true <- proof["input_readback_sha256"] == input["readback_sha256"],
         true <- is_binary(proof["native_readback_sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, proof["native_readback_sha256"]),
         true <- input["origin"] == "NATIVE_CLIENT_INPUT" and input["thread_id"] == chat["thread_id"] and input["generation"] == chat["generation"],
         true <- Jason.encode!(binding) == command["binding_json"],
         true <- command["body_sha256"] == digest(input["body"]) and input["body_sha256"] == command["body_sha256"],
         true <- command["payload_json"] == Jason.encode!([%{"operation" => "request_rework"}]),
         true <- command["payload_sha256"] == digest(command["payload_json"]),
         true <- proof["turn"]["id"] == input["turn_id"],
         true <- valid_proof_turn?(proof, input, chat),
         true <- receipt["input_key"] == input["input_key"] and receipt["status"] == "ACCEPTED" do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid?(_command, _input, _chat), do: false

  @spec bind_input(map(), map()) :: map()
  def bind_input(proof, input), do: proof |> Map.put("input", Map.take(input, @input_fields)) |> Map.put("input_readback_sha256", input["readback_sha256"])

  defp valid_proof_turn?(proof, input, chat) do
    native = %{"id" => proof["thread_id"], "cwd" => proof["cwd"], "projectId" => proof["project_id"], "turns" => [proof["turn"]]}
    refresh = Enum.find(proof["turn"]["items"], &(&1["type"] == "commandExecution" and &1["exitCode"] == 0))

    with {:ok, context} <- Jason.decode(refresh["aggregatedOutput"]),
         {:ok, checked} <- prepare_observation(native, chat, context["run"], context, proof),
         true <- Map.drop(checked, ["native_readback_sha256"]) == Map.drop(proof, ["native_readback_sha256", "input", "input_readback_sha256"]),
         [user] <- Enum.filter(proof["turn"]["items"], &(&1["type"] == "userMessage")),
         [%{"type" => "text", "text" => body}] <- user["content"] do
      user["id"] == input["item_id"] and user["clientId"] == input["client_id"] and
        body == input["body"]
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp refresh_matches?(context, chat, run, key) do
    identity = context["identity"] || %{}
    observed = context["run"] || %{}

    identity["thread_id"] == chat["thread_id"] and identity["chat_key"] == chat["chat_key"] and
      identity["generation"] == chat["generation"] and observed["run_id"] == run["run_id"] and
      Map.take(observed, ~w(state implementation_iteration spec_revision contract_sha256 candidate_sha)) ==
        Map.take(run, ~w(state implementation_iteration spec_revision contract_sha256 candidate_sha)) and
      get_in(context, ["writer_disposition", "status"]) == "BLOCKED" and get_in(context, ["writer_disposition", "request_key"]) == key
  end

  defp command?(item, command, cwd, status, exit),
    do:
      item["type"] == "commandExecution" and item["cwd"] == cwd and
        item["status"] == status and item["exitCode"] == exit and item["commandActions"] == [%{"command" => command, "type" => "unknown"}]

  defp index(items, item), do: Enum.find_index(items, &(&1 == item))
  defp delegated?(%{"type" => "functionCallOutput", "name" => name}), do: name in ~w(create_thread send_message_to_thread)
  defp delegated?(item), do: item["type"] in ~w(collabAgentSpawnToolCall collabAgentSendMessageToolCall)
  defp binding(chat, run), do: Map.take(run, @binding) |> Map.put("generation", chat["generation"])
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
