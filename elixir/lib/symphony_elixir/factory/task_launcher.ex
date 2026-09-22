defmodule SymphonyElixir.Factory.TaskLauncher do
  @moduledoc """
  Resolves model policy, records it before launch, and starts a visible Codex task.
  """

  alias SymphonyElixir.Factory.{ModelRouter, RunLedger, StageRunner, TaskLedger}
  alias SymphonyElixir.Tracker.Issue

  @type launch_result :: %{
          pid: pid(),
          ref: reference(),
          task_key: String.t(),
          route: map()
        }

  @doc "Launches or resumes one durable factory stage task."
  @spec launch(DBConnection.conn(), Supervisor.supervisor(), map(), Issue.t(), Path.t(), String.t(), map(), keyword()) ::
          {:ok, launch_result()} | {:already_terminal, map()} | {:already_running, map()} | {:error, term()}
  def launch(store, task_supervisor, run, %Issue{} = issue, workspace, prompt, output_schema, opts)
      when is_binary(workspace) and is_binary(prompt) and is_map(output_schema) do
    task_key = Keyword.fetch!(opts, :task_key)
    stage = Keyword.fetch!(opts, :stage)
    role = Keyword.fetch!(opts, :role)
    model_policy = Keyword.fetch!(opts, :model_policy)
    project_id = Keyword.fetch!(opts, :project_id)
    section_id = Keyword.get(opts, :section_id)
    codex_assignment = %{project_id: project_id, section_id: section_id}

    with {:ok, route} <-
           ModelRouter.resolve(model_policy, role,
             risk: Keyword.get(opts, :risk),
             risk_signals: Keyword.get(opts, :risk_signals, [])
           ),
         {:ok, task, resume_thread_id} <-
           prepare_task(store, run, task_key, stage, prompt, route, codex_assignment, opts),
         {:ok, pid} <-
           start_task(store, task_supervisor, %{
             task: task,
             run: run,
             issue: issue,
             workspace: workspace,
             prompt: prompt,
             output_schema: output_schema,
             route: route,
             resume_thread_id: resume_thread_id,
             opts: opts
           }) do
      {:ok, %{pid: pid, ref: Process.monitor(pid), task_key: task_key, route: route}}
    else
      {:already_terminal, task} -> {:already_terminal, task}
      {:already_running, task} -> {:already_running, task}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_task(store, run, task_key, stage, prompt, route, codex_assignment, opts) do
    case TaskLedger.get(store, task_key) do
      {:ok, %{"status" => status} = task} when status in ["COMPLETE", "FAILED", "BLOCKED"] ->
        if Keyword.get(opts, :resume_terminal, false) do
          refresh_existing_task(store, run, task, stage, prompt, route, codex_assignment)
        else
          {:already_terminal, task}
        end

      {:ok, %{"status" => status} = task}
      when status in ["STARTING", "RUNNING"] ->
        active_task_keys = Keyword.get(opts, :active_task_keys, MapSet.new())

        if MapSet.member?(active_task_keys, task_key) do
          {:already_running, task}
        else
          refresh_existing_task(store, run, task, stage, prompt, route, codex_assignment)
        end

      {:ok, task} ->
        refresh_existing_task(store, run, task, stage, prompt, route, codex_assignment)

      {:error, :unknown_task} ->
        attrs = %{
          task_key: task_key,
          run_id: run["run_id"],
          stage: stage,
          role: route.resolved_role,
          status: "STARTING",
          model_provider: route.provider,
          model_class: route.model_class,
          model: route.model,
          reasoning_effort: route.reasoning_effort,
          routing_reason: route.routing_reason,
          codex_project_id: codex_assignment.project_id,
          codex_section_id: codex_assignment.section_id,
          prompt_sha256: digest(prompt)
        }

        with {:ok, task} <- TaskLedger.register(store, attrs),
             {:ok, _route_record} <-
               RunLedger.record_model_route(store, run["run_id"], stage, route, task_id: task_key),
             {:ok, _run_update} <-
               RunLedger.update(store, run["run_id"], %{
                 task_id: task_key,
                 runtime: "codex-app-server",
                 model_role: route.resolved_role,
                 model_provider: route.provider,
                 model_class: route.model_class,
                 model: route.model,
                 reasoning_effort: route.reasoning_effort,
                 model_routing_reason: route.routing_reason
               }) do
          {:ok, task, nil}
        end
    end
  end

  defp refresh_existing_task(store, run, task, stage, prompt, route, codex_assignment) do
    task_key = task["task_key"]

    attrs = %{
      stage: stage,
      role: route.resolved_role,
      status: "STARTING",
      model_provider: route.provider,
      model_class: route.model_class,
      model: route.model,
      reasoning_effort: route.reasoning_effort,
      routing_reason: route.routing_reason,
      codex_project_id: codex_assignment.project_id,
      codex_section_id: codex_assignment.section_id,
      prompt_sha256: digest(prompt),
      output_json: nil,
      failure_code: nil
    }

    with {:ok, updated} <- TaskLedger.update(store, task_key, attrs),
         {:ok, _route_record} <-
           RunLedger.record_model_route(store, run["run_id"], stage, route, task_id: task_key),
         {:ok, _run_update} <-
           RunLedger.update(store, run["run_id"], %{
             task_id: task_key,
             runtime: "codex-app-server",
             model_role: route.resolved_role,
             model_provider: route.provider,
             model_class: route.model_class,
             model: route.model,
             reasoning_effort: route.reasoning_effort,
             model_routing_reason: route.routing_reason
           }) do
      {:ok, updated, task["thread_id"]}
    end
  end

  defp start_task(store, task_supervisor, launch) do
    parent = Keyword.fetch!(launch.opts, :recipient)
    task_key = launch.task["task_key"]
    thread_name = Keyword.fetch!(launch.opts, :thread_name)
    stage_runner = Keyword.get(launch.opts, :stage_runner, StageRunner)

    Task.Supervisor.start_child(task_supervisor, fn ->
      on_thread_started = fn thread_id ->
        TaskLedger.update(store, task_key, %{status: "RUNNING", thread_id: thread_id})
        RunLedger.update(store, launch.run["run_id"], %{task_id: thread_id})
        send(parent, {:factory_task_started, task_key, thread_id})
      end

      result =
        stage_runner.run(launch.workspace, launch.issue, launch.prompt, launch.output_schema,
          model: launch.route.model,
          project_id: Keyword.fetch!(launch.opts, :project_id),
          reasoning_effort: launch.route.reasoning_effort,
          required_apps: Keyword.get(launch.opts, :required_apps, []),
          required_mcp_servers: Keyword.get(launch.opts, :required_mcp_servers, []),
          mcp_startup_timeout_ms: Keyword.get(launch.opts, :mcp_startup_timeout_ms, 60_000),
          resume_thread_id: launch.resume_thread_id,
          service_name: "symphony-factory",
          section_id: Keyword.get(launch.opts, :section_id),
          thread_source: "symphonyFactory",
          thread_name: thread_name,
          on_thread_started: on_thread_started
        )

      persist_result(store, task_key, result)
      send(parent, {:factory_task_finished, task_key, result})
    end)
  end

  defp persist_result(store, task_key, {:ok, result}) do
    TaskLedger.update(store, task_key, %{
      status: "COMPLETE",
      thread_id: result.thread_id,
      turn_id: result.turn_id,
      output_json: Jason.encode!(result.output),
      failure_code: nil
    })
  end

  defp persist_result(store, task_key, {:error, reason}) do
    TaskLedger.update(store, task_key, %{
      status: "FAILED",
      failure_code: inspect(reason)
    })
  end

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
