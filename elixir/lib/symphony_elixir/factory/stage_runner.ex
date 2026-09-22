defmodule SymphonyElixir.Factory.StageRunner do
  @moduledoc """
  Runs one named, durable Codex factory task and returns its structured result.

  Every task is a non-ephemeral Codex thread. A caller may resume the same
  thread ID after a restart or for another bounded pass.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Tracker.Issue

  @type result :: %{
          thread_id: String.t(),
          turn_id: String.t(),
          output: map()
        }

  @doc "Runs one structured stage turn in a durable Codex task."
  @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(workspace, %Issue{} = issue, prompt, output_schema, opts \\ [])
      when is_binary(workspace) and is_binary(prompt) and is_map(output_schema) do
    app_server = Keyword.get(opts, :app_server, AppServer)
    collector = start_collector()
    on_message = message_handler(collector, Keyword.get(opts, :on_message))

    session_opts =
      opts
      |> Keyword.take([
        :fork_on_active_writer,
        :model,
        :mcp_startup_timeout_ms,
        :project_id,
        :reasoning_effort,
        :required_apps,
        :required_mcp_servers,
        :resume_thread_id,
        :section_id,
        :service_name,
        :thread_name,
        :thread_source,
        :worker_host
      ])
      |> Keyword.put_new(:service_name, "symphony-factory")
      |> Keyword.put_new(:thread_source, "symphonyFactory")

    case app_server.start_session(workspace, session_opts) do
      {:ok, session} ->
        run_session(app_server, session, issue, prompt, output_schema, on_message, collector, opts)

      {:error, reason} ->
        Agent.stop(collector)
        {:error, reason}
    end
  end

  defp run_session(app_server, session, issue, prompt, output_schema, on_message, collector, opts) do
    notify_started(opts, session.thread_id)

    try do
      with :ok <- maybe_archive_forked_thread(app_server, session, opts),
           {:ok, turn} <-
             app_server.run_turn(session, prompt, issue,
               on_message: on_message,
               output_schema: output_schema
             ),
           {:ok, output} <- collector_output(collector) do
        {:ok, %{thread_id: session.thread_id, turn_id: turn.turn_id, output: output}}
      end
    after
      app_server.stop_session(session)
      Agent.stop(collector)
    end
  end

  defp start_collector do
    {:ok, collector} = Agent.start_link(fn -> nil end)
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
    case get_in(payload, ["params", "item"]) do
      %{"type" => "agentMessage", "text" => text} when is_binary(text) ->
        Agent.update(collector, fn _current -> text end)

      _other ->
        :ok
    end
  end

  defp maybe_collect_output(_collector, _message), do: :ok

  defp collector_output(collector) do
    case Agent.get(collector, & &1) do
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

  defp notify_started(opts, thread_id) do
    case Keyword.get(opts, :on_thread_started) do
      callback when is_function(callback, 1) -> callback.(thread_id)
      _other -> :ok
    end
  end

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
