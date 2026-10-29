defmodule SymphonyElixir.Factory.SpecialistErrorNotice do
  @moduledoc "Immutable specialist failures and their independently acknowledged parent notices."
  alias SymphonyElixir.Factory.Store

  @spec observe(Store.connection(), String.t(), map()) :: :ok | {:error, term()}
  def observe(store, key, %{payload: %{"params" => params} = payload} = event) when is_map(params) do
    case observed_error(payload, event) do
      nil ->
        :ok

      reason ->
        with row when is_map(row) <- Store.one!(store, "SELECT w.*, t.role, t.stage FROM worker_evidence w JOIN factory_tasks t ON t.task_key = w.task_key WHERE w.request_key = ?", [key]),
             true <- is_binary(row["turn_id"]) and params["threadId"] == row["thread_id"] and params["turnId"] == row["turn_id"],
             {:ok, _} <- record_bound(store, Map.put(row, "continuing_observation", true), reason) do
          :ok
        else
          _ -> {:error, :specialist_error_observation_unbound}
        end
    end
  end

  def observe(_store, _key, _event), do: :ok

  @spec observe_task(Store.connection(), String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def observe_task(store, task_key, request_key, prompt_sha, %{payload: %{"params" => params} = payload} = event) when is_map(params) do
    case observed_error(payload, event) do
      nil ->
        :ok

      reason ->
        with row when is_map(row) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key]),
             true <- row["prompt_sha256"] == prompt_sha and is_binary(row["turn_id"]) and params["threadId"] == row["thread_id"] and params["turnId"] == row["turn_id"],
             bound = row |> Map.put("request_key", request_key) |> Map.put("continuing_observation", true) |> Map.put("binding_sha256", prompt_sha),
             {:ok, _} <- record_bound(store, bound, reason) do
          :ok
        else
          _ -> {:error, :specialist_error_observation_unbound}
        end
    end
  end

  def observe_task(_store, _task, _request, _prompt, _event), do: :ok

  defp observed_error(%{"method" => "error", "params" => params}, _event), do: {:provider_observation, params["error"]}

  defp observed_error(%{"method" => "item/tool/call", "params" => params}, %{event: type})
       when type in [:tool_call_failed, :unsupported_tool_call] do
    {:tool_call_observation, type, Map.take(params, ~w(callId tool name))}
  end

  defp observed_error(%{"method" => "item/completed", "params" => %{"item" => item}}, _event) when is_map(item) do
    result_error = is_map(item["result"]) and item["result"]["isError"] == true

    failed_status = item["status"] == "failed" or item["success"] == false or item["isError"] == true
    failed_exit = is_integer(item["exitCode"]) and item["exitCode"] != 0

    if failed_status or not is_nil(item["error"]) or failed_exit or result_error,
      do: {:tool_observation, item["id"], Map.take(item, ~w(type status success isError exitCode error))}
  end

  defp observed_error(_payload, %{event: type}) when type in [:approval_required, :turn_input_required], do: {:permission_observation, type}
  defp observed_error(_payload, _event), do: nil

  @spec record(Store.connection(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def record(store, key, reason) do
    case Store.one!(store, "SELECT w.*, t.role, t.stage FROM worker_evidence w JOIN factory_tasks t ON t.task_key = w.task_key WHERE w.request_key = ?", [key]) do
      nil -> {:error, :specialist_error_binding_missing}
      row -> record_bound(store, row, reason)
    end
  end

  @spec record_task(Store.connection(), String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def record_task(store, task_key, request_key, reason) do
    case Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key]) do
      nil ->
        {:error, :specialist_error_binding_missing}

      row ->
        binding = digest(Jason.encode!(Map.take(row, ~w(run_id task_key role stage model reasoning_effort prompt_sha256 workspace workspace_sha))))
        request = Store.one!(store, "SELECT * FROM desktop_requests WHERE request_key = ? AND target_kind = 'TASK' AND target_key = ?", [request_key, task_key])
        bound = if request, do: Map.merge(row, Map.take(request, ~w(thread_id turn_id))), else: row
        record_bound(store, bound |> Map.put("request_key", request_key) |> Map.put("binding_sha256", binding), reason)
    end
  end

  @spec record_critic(Store.connection(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def record_critic(store, command_key, reason) do
    case Store.one!(store, "SELECT * FROM ticket_contract_critic_attempts WHERE command_key = ?", [command_key]) do
      nil ->
        {:error, :specialist_error_binding_missing}

      row ->
        bound =
          row
          |> Map.take(~w(run_id task_key))
          |> Map.merge(%{
            "request_key" => command_key,
            "role" => "specification-critic",
            "stage" => "CONTRACT_AMENDMENT",
            "thread_id" => row["worker_thread_id"],
            "turn_id" => row["worker_turn_id"],
            "binding_sha256" => digest(Jason.encode!(Map.take(row, ~w(command_key run_id task_key prompt_sha256 schema_sha256 snapshot_sha256 route_sha256 input_sha256))))
          })

        record_bound(store, bound, reason)
    end
  end

  defp record_bound(store, row, reason) do
    error_sha = digest(:erlang.term_to_binary(reason, [:deterministic]))
    identity = Map.take(row, ~w(run_id request_key task_key role stage thread_id turn_id binding_sha256)) |> Map.put("error_sha256", error_sha)
    id = digest(Jason.encode!(identity |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)))
    category = category(reason)
    continuing = row["continuing_observation"] == true

    ownership =
      cond do
        continuing -> "This error was observed within the bound turn; the specialist may still be continuing."
        row["owner_stopped_at"] -> "Owned shutdown was recorded; retry still requires controller authorization."
        true -> "Owner shutdown is not proven; a replacement specialist is not authorized by this notice."
      end

    preserved =
      if row["role"] == "feature-writer",
        do: "Existing candidate and partial file edits are preserved; this is not a completed slice.",
        else: "Existing inputs and candidate are unchanged by this notice; this attempt has no validated completed result."

    next = if continuing, do: "The controller observes this attempt; the notice does not authorize a retry or restart.", else: "The controller must reconcile this exact attempt before retrying."
    notice = Map.merge(identity, %{"notice_id" => id, "category" => category, "cause" => cause(category), "ownership" => ownership, "preserved_work" => preserved, "next_action" => next})
    existing = Store.one!(store, "SELECT payload_json FROM events WHERE event_type = 'SPECIALIST_ERROR_RECORDED' AND run_id = ? AND json_extract(payload_json, '$.notice_id') = ?", [row["run_id"], id])

    if existing do
      {:ok, Jason.decode!(existing["payload_json"])}
    else
      Store.query!(store, "INSERT OR IGNORE INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('SPECIALIST_ERROR_RECORDED', ?, ?, ?)", [
        row["run_id"],
        Jason.encode!(notice),
        DateTime.to_iso8601(DateTime.utc_now())
      ])

      {:ok, notice}
    end
  end

  @spec pending(Store.connection(), String.t()) :: {:ok, [map()]}
  def pending(store, run_id) do
    result =
      Store.query!(
        store,
        "SELECT e.payload_json FROM events e WHERE e.run_id = ? AND e.event_type = 'SPECIALIST_ERROR_RECORDED' AND NOT EXISTS (SELECT 1 FROM events q WHERE q.run_id = e.run_id AND q.event_type = 'SPECIALIST_ERROR_QUEUED' AND json_extract(q.payload_json, '$.notice_id') = json_extract(e.payload_json, '$.notice_id')) ORDER BY e.id LIMIT 1",
        [run_id]
      )

    {:ok, Enum.map(result.rows, fn [json] -> Jason.decode!(json) end)}
  end

  @spec queued(Store.connection(), String.t(), [map()], String.t()) :: :ok
  def queued(store, run_id, notices, request_key) do
    Enum.each(notices, fn notice ->
      Store.query!(store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('SPECIALIST_ERROR_QUEUED', ?, ?, ?)", [
        run_id,
        Jason.encode!(%{notice_id: notice["notice_id"], request_key: request_key}),
        DateTime.to_iso8601(DateTime.utc_now())
      ])
    end)

    :ok
  end

  @spec metadata([map()]) :: map()
  def metadata([]), do: %{}

  def metadata([notice]) do
    text =
      "Specialist error: #{notice["role"]} at #{notice["stage"]}. #{notice["cause"]}\nRequest: #{notice["request_key"]}; turn: #{notice["turn_id"] || "not bound"}.\n#{notice["ownership"]}\n#{notice["preserved_work"]}\nNext: #{notice["next_action"]}\nNotice: #{notice["notice_id"]}. Returned error only; not verified, committed or delivered."

    %{"specialist_notice_ids" => [notice["notice_id"]], "specialist_notice_text" => text}
  end

  @doc "Separates an optional complete notice pair without granting ledger authority."
  @spec split_metadata(map()) :: {:ok, map(), map()} | {:error, atom()}
  def split_metadata(metadata) when is_map(metadata) do
    keys = ~w(specialist_notice_ids specialist_notice_text)
    notice = Map.take(metadata, keys)

    case notice do
      empty when map_size(empty) == 0 ->
        {:ok, metadata, %{}}

      %{"specialist_notice_ids" => [id], "specialist_notice_text" => text}
      when is_binary(id) and byte_size(id) > 0 and is_binary(text) and byte_size(text) > 0 ->
        if String.valid?(id) and String.valid?(text),
          do: {:ok, Map.drop(metadata, keys), notice},
          else: {:error, :invalid_specialist_notice_metadata}

      _ ->
        {:error, :invalid_specialist_notice_metadata}
    end
  end

  def split_metadata(_metadata), do: {:error, :invalid_specialist_notice_metadata}

  @spec valid_metadata?(Store.connection(), String.t(), map()) :: boolean()
  def valid_metadata?(store, run_id, metadata) do
    case metadata["specialist_notice_ids"] do
      [id] when is_binary(id) ->
        case Store.one!(store, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'SPECIALIST_ERROR_RECORDED' AND json_extract(payload_json, '$.notice_id') = ?", [run_id, id]) do
          nil -> false
          row -> Map.take(metadata, ~w(specialist_notice_ids specialist_notice_text)) == metadata([Jason.decode!(row["payload_json"])])
        end

      _ ->
        false
    end
  end

  @spec validate_render(map(), map(), String.t()) :: :ok | {:error, atom()}
  def validate_render(metadata, output, readback_sha) do
    case metadata["specialist_notice_text"] do
      nil ->
        :ok

      text ->
        expected = %{"notice_ids" => metadata["specialist_notice_ids"], "text_sha256" => digest(text), "native_readback_sha256" => readback_sha}

        if output["rendered_specialist_notice"] == expected and is_binary(readback_sha) and byte_size(readback_sha) == 64 do
          :ok
        else
          {:error, :specialist_notice_render_unproven}
        end
    end
  end

  defp category(reason) do
    text = inspect(reason, limit: :infinity, printable_limit: :infinity)

    cond do
      String.contains?(text, ["serverOverloaded", "at capacity"]) -> "PROVIDER_CAPACITY"
      String.contains?(text, ["permission", "approval", "sandbox"]) -> "PERMISSION"
      String.contains?(text, ["timeout", "timed_out"]) -> "TIMEOUT"
      String.contains?(text, ["invalid_output", "malformed", "schema", "json"]) -> "MALFORMED_OUTPUT"
      String.contains?(text, ["tool", "transport", "connection"]) -> "TOOL_TRANSPORT"
      true -> "NATIVE_FAILURE"
    end
  end

  defp cause("PROVIDER_CAPACITY"), do: "The selected model is at capacity."
  defp cause("PERMISSION"), do: "The specialist encountered a permission or sandbox error. No escalation was approved."
  defp cause("TIMEOUT"), do: "The specialist attempt exceeded its bounded deadline."
  defp cause("MALFORMED_OUTPUT"), do: "The specialist returned output that could not be validated."
  defp cause("TOOL_TRANSPORT"), do: "A specialist tool or transport operation failed."
  defp cause(_), do: "The specialist native attempt failed; exact diagnostic evidence remains in the ledger."
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
