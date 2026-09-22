defmodule SymphonyElixir.Factory.ControllerTask do
  @moduledoc """
  Resumes the single visible Codex task that performs connector-bound control operations.

  Worker tasks never need Jira or GitLab connectors. The controller task is
  explicitly routed, named, and persisted in the local control record.
  """

  alias SymphonyElixir.Factory.{ControlServer, ModelRouter, StageRunner}
  alias SymphonyElixir.Tracker.Issue

  @doc "Runs one structured controller operation in the persistent controller task."
  @spec run(map(), Path.t(), Issue.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(factory, workspace, %Issue{} = issue, prompt, schema, opts \\ []) do
    control_server = Keyword.get(opts, :control_server, ControlServer)
    stage_runner = Keyword.get(opts, :stage_runner, StageRunner)
    control = ControlServer.status(control_server)
    project_id = factory.controller_codex_project_id
    resume_thread_id = control["controller_thread_id"]

    fork_on_active_writer =
      stale_writer_conflict?(
        control,
        Map.get(factory, :stale_task_minutes, 90),
        Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      )

    with {:ok, route} <- ModelRouter.resolve(factory.models, "orchestrator") do
      result =
        stage_runner.run(workspace, issue, prompt, schema,
          archive_forked_thread: fork_on_active_writer,
          fork_on_active_writer: fork_on_active_writer,
          model: route.model,
          mcp_startup_timeout_ms: factory.controller_mcp_startup_timeout_ms,
          project_id: project_id,
          reasoning_effort: route.reasoning_effort,
          required_mcp_servers: factory.controller_required_mcp_servers,
          resume_thread_id: resume_thread_id,
          service_name: "symphony-factory-controller",
          thread_source: "symphonyFactoryController",
          thread_name: "FACTORY · #{factory.scope} · Orchestrator",
          on_thread_started: fn thread_id ->
            ControlServer.record_controller_task(
              thread_id,
              nil,
              route
              |> Map.put(:project_id, project_id),
              control_server
            )
          end
        )

      reconcile_result(result, resume_thread_id, route, project_id, control_server)
    end
  end

  defp reconcile_result({:ok, result}, _resume_thread_id, route, project_id, control_server) do
    ControlServer.record_controller_task(
      result.thread_id,
      result.turn_id,
      route
      |> Map.put(:project_id, project_id),
      control_server
    )

    ControlServer.clear_controller_writer_conflict(result.thread_id, control_server)
    {:ok, result.output}
  end

  defp reconcile_result({:error, reason}, resume_thread_id, _route, _project_id, control_server) do
    if is_binary(resume_thread_id) and active_writer_error?(reason) do
      ControlServer.record_controller_writer_conflict(resume_thread_id, control_server)
      {:error, {:controller_active_writer, reason}}
    else
      if is_binary(resume_thread_id) do
        ControlServer.clear_controller_writer_conflict(resume_thread_id, control_server)
      end

      {:error, reason}
    end
  end

  defp stale_writer_conflict?(%{"controller_writer_conflict_since" => since}, minutes, now)
       when is_binary(since) and is_integer(minutes) and minutes > 0 do
    case DateTime.from_iso8601(since) do
      {:ok, started_at, _offset} -> DateTime.diff(now, started_at, :second) >= minutes * 60
      {:error, _reason} -> false
    end
  end

  defp stale_writer_conflict?(_control, _minutes, _now), do: false

  defp active_writer_error?({:response_error, %{"message" => message}})
       when is_binary(message),
       do: String.contains?(String.downcase(message), "active writer")

  defp active_writer_error?(_reason), do: false
end
