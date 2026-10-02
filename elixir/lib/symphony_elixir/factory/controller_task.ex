defmodule SymphonyElixir.Factory.ControllerTask do
  @moduledoc """
  Resumes the single visible Codex task that performs connector-bound control operations.

  Worker tasks never need Jira or GitLab connectors. The controller task is
  explicitly routed, named, and persisted in the local control record.
  """

  alias SymphonyElixir.Factory.{ControlServer, DesktopStageRunner, ModelRouter, StageRunner}
  alias SymphonyElixir.Tracker.Issue

  @doc "Runs one structured controller operation in the persistent controller task."
  @spec run(map(), Path.t(), Issue.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(factory, workspace, %Issue{} = issue, prompt, schema, opts \\ []) do
    control_server = Keyword.get(opts, :control_server, ControlServer)

    stage_runner =
      Keyword.get(
        opts,
        :stage_runner,
        if(Map.get(factory, :task_transport) == "desktop_broker", do: DesktopStageRunner, else: StageRunner)
      )

    control = ControlServer.status(control_server)
    project_id = factory.controller_codex_project_id
    resume_thread_id = control["controller_thread_id"]

    model_role = Keyword.get(opts, :model_role, "orchestrator")

    with :ok <- validate_controller_identity(control),
         :ok <- validate_controller_transport(factory, control),
         :ok <- validate_scoped_approvals(model_role, issue.identifier, opts),
         :ok <- validate_desktop_approvals(factory, opts),
         {:ok, route} <- ModelRouter.resolve(factory.models, model_role) do
      result =
        stage_runner.run(workspace, issue, structured_output_prompt(prompt, schema), schema,
          app_server: Keyword.get(opts, :app_server, SymphonyElixir.Codex.AppServer),
          approval_policy: Keyword.get(opts, :approval_policy),
          allowed_mcp_tool_approvals: Keyword.get(opts, :allowed_mcp_tool_approvals, []),
          archive_forked_thread: false,
          fork_on_active_writer: false,
          model: route.model,
          mcp_startup_timeout_ms: factory.controller_mcp_startup_timeout_ms,
          project_id: project_id,
          reasoning_effort: route.reasoning_effort,
          required_mcp_servers: factory.controller_required_mcp_servers,
          resume_thread_id: resume_thread_id,
          service_name: "symphony-factory-controller",
          thread_source: "symphonyFactoryController",
          thread_name: "FACTORY · #{factory.scope} · Orchestrator",
          format_repair_attempts: 1,
          required_tool_calls: Keyword.get(opts, :required_tool_calls, []),
          wait_timeout_ms: Keyword.get(opts, :wait_timeout_ms, 30 * 60 * 1_000),
          store: Keyword.get(opts, :store, SymphonyElixir.Factory.Supervisor.store_name()),
          target_kind: "CONTROLLER",
          target_key: factory.scope,
          request_key:
            DesktopStageRunner.request_key(
              "controller:" <> factory.scope,
              control["controller_turn_id"],
              prompt
            ),
          previous_turn_id: control["controller_turn_id"],
          issue_key: issue.identifier,
          on_thread_created: fn thread_id ->
            if thread_id != resume_thread_id do
              ControlServer.record_controller_task(
                thread_id,
                nil,
                route
                |> Map.put(:project_id, project_id),
                control_server
              )
            end
          end
        )

      reconcile_result(result, resume_thread_id, route, project_id, control_server)
    end
  end

  defp structured_output_prompt(prompt, schema) do
    """
    #{prompt}

    Controller receipt format: after completing and reading back the requested
    operation, return exactly one raw JSON object matching this schema. Do not
    add prose or Markdown fences. If formatting needs repair, do not repeat any
    tool call or external mutation; return only a receipt supported by the
    evidence already established in this turn.

    #{Jason.encode!(schema)}
    """
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

  defp active_writer_error?({:response_error, %{"message" => message}})
       when is_binary(message),
       do: String.contains?(String.downcase(message), "active writer")

  defp active_writer_error?(_reason), do: false

  defp validate_controller_identity(%{"controller_thread_id" => thread_id} = control)
       when is_nil(thread_id) or thread_id == "" do
    if Enum.any?(
         ["controller_turn_id", "controller_model", "controller_codex_project_id"],
         &(is_binary(control[&1]) and control[&1] != "")
       ) do
      {:error, :controller_identity_missing}
    else
      :ok
    end
  end

  defp validate_controller_identity(_control), do: :ok

  defp validate_controller_transport(%{task_transport: "desktop_broker"}, %{"controller_thread_id" => thread_id})
       when not is_binary(thread_id) or thread_id == "",
       do: {:error, :desktop_controller_thread_unbound}

  defp validate_controller_transport(_factory, _control), do: :ok

  defp validate_desktop_approvals(%{task_transport: "desktop_broker"}, opts) do
    if Keyword.get(opts, :allowed_mcp_tool_approvals, []) == [],
      do: :ok,
      else: {:error, :controller_approval_transport_unavailable}
  end

  defp validate_desktop_approvals(_factory, _opts), do: :ok

  defp validate_scoped_approvals(role, issue_key, opts) do
    case {role, Keyword.get(opts, :approval_policy), Keyword.get(opts, :allowed_mcp_tool_approvals, [])} do
      {_role, nil, []} ->
        :ok

      {"orchestrator", "on-request", approvals} when is_list(approvals) ->
        if approvals != [] and length(approvals) <= 2 and
             Enum.all?(approvals, &valid_jira_approval?(&1, issue_key)) and
             Enum.uniq_by(approvals, & &1.tool) == approvals do
          :ok
        else
          {:error, :invalid_controller_jira_approval}
        end

      {"orchestrator", _policy, _allowed} ->
        {:error, :invalid_controller_jira_approval}

      {_role, _policy, _allowed} ->
        {:error, :controller_approval_for_non_write_role}
    end
  end

  defp valid_jira_approval?(%{server: "Jira", tool: "jira_add_comment", issue_key: issue_key, body_equals: body}, issue_key)
       when is_binary(body) and body != "",
       do: true

  defp valid_jira_approval?(%{server: "Jira", tool: "jira_update_issue", issue_key: issue_key, labels_equals: labels}, issue_key)
       when is_list(labels),
       do: labels != [] and Enum.all?(labels, &(is_binary(&1) and &1 != "")) and Enum.uniq(labels) == labels

  defp valid_jira_approval?(_approval, _issue_key), do: false
end
