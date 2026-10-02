defmodule SymphonyElixir.Factory.StageRunner do
  @moduledoc """
  Runs one named, durable Codex factory task and returns its structured result.

  Every task is a non-ephemeral Codex thread. A caller may resume the same
  thread ID after a restart or for another bounded pass.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.StageSchemas
  alias SymphonyElixir.Tracker.Issue

  @type result :: %{
          thread_id: String.t(),
          turn_id: String.t(),
          output: map()
        }

  @type required_tool_call :: %{
          optional(:server) => String.t(),
          required(:tool) => String.t()
        }

  @doc "Runs one structured stage turn in a durable Codex task."
  @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(workspace, %Issue{} = issue, prompt, output_schema, opts \\ [])
      when is_binary(workspace) and is_binary(prompt) and is_map(output_schema) do
    app_server = Keyword.get(opts, :app_server, AppServer)
    event_scope = Keyword.get(opts, :event_scope, :legacy)
    unless event_scope in [:legacy, :exact_turn], do: raise(ArgumentError, "unsupported event_scope: #{inspect(event_scope)}")
    collector = start_collector(event_scope)
    on_message = message_handler(collector, Keyword.get(opts, :on_message))

    session_opts =
      opts
      |> Keyword.take([
        :allowed_mcp_tool_approvals,
        :approval_policy,
        :fork_on_active_writer,
        :model,
        :mcp_startup_timeout_ms,
        :project_id,
        :project_root,
        :reasoning_effort,
        :required_apps,
        :required_mcp_servers,
        :resume_thread_id,
        :section_id,
        :service_name,
        :thread_name,
        :thread_source,
        :worker_host,
        :event_scope
      ])
      |> Keyword.put_new(:service_name, "symphony-factory")
      |> Keyword.put_new(:thread_source, "symphonyFactory")
      |> Keyword.put(:on_thread_created, Keyword.get(opts, :on_thread_created, Keyword.get(opts, :on_thread_started)))

    case app_server.start_session(workspace, session_opts) do
      {:ok, session} ->
        run_session(app_server, session, issue, prompt, output_schema, on_message, collector, opts)

      {:error, reason} ->
        Agent.stop(collector)
        {:error, reason}
    end
  end

  defp run_session(app_server, session, issue, prompt, output_schema, on_message, collector, opts) do
    turn_context = %{
      on_message: on_message,
      collector: collector,
      required_tool_calls: Keyword.get(opts, :required_tool_calls, []),
      format_repair_attempts: Keyword.get(opts, :format_repair_attempts, 0),
      event_scope: Keyword.get(opts, :event_scope, :legacy)
    }

    with :ok <- maybe_archive_forked_thread(app_server, session, opts),
         {:ok, turn, output} <-
           run_structured_turn(app_server, session, issue, prompt, output_schema, turn_context) do
      {:ok, %{thread_id: session.thread_id, turn_id: turn.turn_id, output: output}}
    end
  after
    app_server.stop_session(session)
    Agent.stop(collector)
  end

  defp run_structured_turn(app_server, session, issue, prompt, output_schema, context) do
    with {:ok, turn} <-
           app_server.run_turn(session, prompt, issue,
             on_message: context.on_message,
             output_schema: output_schema,
             event_scope: context.event_scope
           ) do
      case collector_output(context.collector, context.required_tool_calls, output_schema) do
        {:ok, output} ->
          {:ok, turn, output}

        {:error, reason} ->
          maybe_repair_output(app_server, session, issue, output_schema, context, reason)
      end
    end
  end

  defp maybe_repair_output(app_server, session, issue, output_schema, context, reason) do
    if context.format_repair_attempts > 0 and malformed_output?(reason) do
      Agent.update(context.collector, &Map.put(&1, :output, nil))

      run_structured_turn(
        app_server,
        session,
        issue,
        format_repair_prompt(),
        output_schema,
        %{context | format_repair_attempts: context.format_repair_attempts - 1}
      )
    else
      {:error, reason}
    end
  end

  defp malformed_output?({:factory_stage_output_invalid_json, _reason}), do: true
  defp malformed_output?(:factory_stage_output_not_an_object), do: true
  defp malformed_output?(:factory_stage_output_missing), do: true
  defp malformed_output?(:factory_stage_output_schema_mismatch), do: true
  defp malformed_output?(_reason), do: false

  defp format_repair_prompt do
    """
    Your previous response did not satisfy the structured output schema.
    Do not run tools, repeat the skill, or change Jira, Git, or any external state.
    Do not invent facts, questions, or contract content. In this same task,
    return exactly one JSON object satisfying the supplied schema using only
    evidence established by the previous turn. If that evidence is insufficient
    for a complete contract, return BLOCKED with targeted questions rather
    than filling gaps by inference. No Markdown fences or explanatory prose.
    """
  end

  defp start_collector(event_scope) do
    {:ok, collector} = Agent.start_link(fn -> %{output: nil, completed_tool_calls: [], event_scope: event_scope, identity: nil, identity_error: nil} end)
    collector
  end

  defp message_handler(collector, downstream) do
    fn message ->
      maybe_collect_output(collector, message)

      if is_function(downstream, 1) do
        downstream.(message)
      end

      :ok
    end
  end

  defp maybe_collect_output(collector, %{payload: payload}) when is_map(payload) do
    state = Agent.get(collector, & &1)

    if state.event_scope == :exact_turn and not collector_identity_matches?(payload, state.identity) do
      if is_nil(state.identity), do: Agent.update(collector, &Map.put(&1, :identity_error, :factory_stage_identity_missing))
      :ok
    else
      case get_in(payload, ["params", "item"]) do
        %{"type" => "agentMessage", "phase" => "commentary"} ->
          :ok

        %{"type" => "agentMessage", "text" => text} when is_binary(text) ->
          Agent.update(collector, &Map.put(&1, :output, text))

        %{} = item ->
          case completed_tool_call(payload, item) do
            nil -> :ok
            tool_call -> Agent.update(collector, &Map.update!(&1, :completed_tool_calls, fn calls -> [tool_call | calls] end))
          end

        _other ->
          :ok
      end
    end
  end

  defp maybe_collect_output(collector, %{event: :session_started, thread_id: thread_id, turn_id: turn_id}) do
    Agent.update(collector, &Map.put(&1, :identity, {thread_id, turn_id}))
  end

  defp maybe_collect_output(_collector, _message), do: :ok

  defp collector_output(collector, required_tool_calls, output_schema) do
    state = Agent.get(collector, & &1)

    with true <- not (state.event_scope == :exact_turn and (is_nil(state.identity) or not is_nil(state.identity_error))) || {:error, state.identity_error || :factory_stage_identity_missing},
         :ok <- validate_required_tool_calls(required_tool_calls, state.completed_tool_calls),
         {:ok, output} <- decode_output(state.output),
         :ok <- StageSchemas.validate(output, output_schema) do
      {:ok, output}
    end
  end

  defp collector_identity_matches?(_payload, nil), do: false

  defp collector_identity_matches?(payload, {thread_id, turn_id}) do
    params = Map.get(payload, "params", %{})
    Map.get(params, "threadId") == thread_id and Map.get(params, "turnId") == turn_id
  end

  defp decode_output(text) do
    case text do
      text when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{} = output} -> {:ok, output}
          {:ok, _other} -> {:error, :factory_stage_output_not_an_object}
          {:error, reason} -> {:error, {:factory_stage_output_invalid_json, reason}}
        end

      _other ->
        {:error, :factory_stage_output_missing}
    end
  end

  defp completed_tool_call(payload, item) do
    if payload["method"] == "item/completed" and successful_mcp_tool_item?(item) do
      tool = item["tool"] || item["toolName"] || item["name"]

      server =
        case item["server"] do
          %{"name" => name} -> name
          value when is_binary(value) -> value
          _other -> item["serverName"]
        end

      if present_string?(tool) do
        %{server: normalize_tool_value(server), tool: String.trim(tool)}
      end
    end
  end

  defp successful_mcp_tool_item?(item) do
    type = item["type"]
    status = item["status"]

    type in ["mcpToolCall", "mcp_tool_call"] and status == "completed" and
      is_nil(item["error"]) and item["isError"] != true and
      not match?(%{"isError" => true}, item["result"])
  end

  defp validate_required_tool_calls(required, completed) when is_list(required) do
    missing = Enum.reject(required, &required_tool_call_completed?(&1, completed))

    case missing do
      [] -> :ok
      _ -> {:error, {:required_tool_calls_missing, missing}}
    end
  end

  defp validate_required_tool_calls(_required, _completed),
    do: {:error, :invalid_required_tool_calls}

  defp required_tool_call_completed?(required, completed) when is_map(required) do
    expected_tool = required[:tool] || required["tool"]
    expected_server = required[:server] || required["server"]

    Enum.any?(completed, fn actual ->
      same_tool_value?(actual.tool, expected_tool) and
        (not present_string?(expected_server) or same_tool_value?(actual.server, expected_server))
    end)
  end

  defp required_tool_call_completed?(_required, _completed), do: false

  defp same_tool_value?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp same_tool_value?(_left, _right), do: false

  defp normalize_tool_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_tool_value(_value), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp maybe_archive_forked_thread(
         app_server,
         %{forked_from_thread_id: replaced_thread_id, thread_id: thread_id} = session,
         opts
       )
       when is_binary(replaced_thread_id) and replaced_thread_id != thread_id do
    if Keyword.get(opts, :archive_forked_thread, false) do
      app_server.archive_thread(session, replaced_thread_id)
    else
      :ok
    end
  end

  defp maybe_archive_forked_thread(_app_server, _session, _opts), do: :ok
end
