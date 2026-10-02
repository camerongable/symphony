defmodule SymphonyElixir.Factory.TaskLauncher do
  @moduledoc """
  Resolves model policy, records it before launch, and starts a visible Codex task.
  """

  alias SymphonyElixir.Factory.{DesktopStageRunner, ModelRouter, RunLedger, StageRunner, Store, TaskLedger}

  @in_flight_states ~w(STARTING RUNNING WAITING_FOR_BROKER WAITING_FOR_WRITER STALE RETRY_PENDING)
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
         :ok <- validate_run_route(run, issue, Keyword.fetch!(opts, :project_root)) do
      locked_launch(%{
        store: store,
        task_supervisor: task_supervisor,
        run: run,
        issue: issue,
        workspace: workspace,
        prompt: prompt,
        output_schema: output_schema,
        stage: Keyword.fetch!(opts, :stage),
        route: route,
        assignment: codex_assignment,
        opts: opts
      })
    end
  end

  defp locked_launch(launch) do
    lock = {{__MODULE__, :launch, Keyword.fetch!(launch.opts, :task_key)}, self()}

    case :global.trans(lock, fn -> launch_claimed_task(launch) end) do
      :aborted -> {:error, :factory_task_launch_lock_unavailable}
      result -> result
    end
  end

  defp launch_claimed_task(launch) do
    task_key = Keyword.fetch!(launch.opts, :task_key)

    with {:ok, task, resume_thread_id} <-
           prepare_task(
             launch.store,
             launch.run,
             task_key,
             launch.stage,
             launch.prompt,
             launch.route,
             launch.assignment,
             launch.opts
           ),
         {:ok, pid} <-
           start_task(launch.store, launch.task_supervisor, %{
             task: task,
             run: launch.run,
             issue: launch.issue,
             workspace: launch.workspace,
             prompt: launch.prompt,
             output_schema: launch.output_schema,
             route: launch.route,
             resume_thread_id: resume_thread_id,
             opts: launch.opts
           }) do
      {:ok, %{pid: pid, ref: Process.monitor(pid), task_key: task_key, route: launch.route}}
    else
      {:already_terminal, task} -> {:already_terminal, task}
      {:already_running, task} -> {:already_running, task}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_task(store, run, task_key, stage, prompt, route, codex_assignment, opts) do
    case TaskLedger.get(store, task_key) do
      {:ok, task} ->
        prepare_existing_task(store, run, task, stage, prompt, route, codex_assignment, opts)

      {:error, :unknown_task} ->
        reusable_thread_id =
          if stage == "SPEC_DRAFTING" and route.resolved_role == "specification-author" and
               Keyword.get(opts, :task_transport) != "desktop_broker" do
            TaskLedger.reusable_specification_thread(
              store,
              run["issue_key"],
              run["repo_path"],
              codex_assignment.project_id
            )
          end

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
          thread_id: reusable_thread_id,
          workspace_sha: Keyword.get(opts, :expected_sha),
          prompt_sha256: digest(prompt)
        }

        with {:ok, task} <- TaskLedger.register(store, attrs),
             {:ok, _route_record} <-
               RunLedger.record_model_route(store, run["run_id"], stage, route, task_id: task_key),
             {:ok, _run_update} <-
               RunLedger.update(store, run["run_id"], %{
                 task_id: task_key,
                 runtime: runtime_name(opts),
                 model_role: route.resolved_role,
                 model_provider: route.provider,
                 model_class: route.model_class,
                 model: route.model,
                 reasoning_effort: route.reasoning_effort,
                 model_routing_reason: route.routing_reason
               }) do
          {:ok, task, reusable_thread_id}
        end
    end
  end

  defp prepare_existing_task(store, run, task, stage, prompt, route, assignment, opts) do
    with :ok <- validate_task_route(task, run, route, assignment) do
      cond do
        live_task?(task["task_key"]) ->
          {:already_running, task}

        task["status"] in ["COMPLETE", "FAILED", "BLOCKED"] and
            not Keyword.get(opts, :resume_terminal, false) ->
          {:already_terminal, task}

        Keyword.get(opts, :task_transport) == "desktop_broker" and
            unresolved_native_request?(store, task["task_key"]) ->
          {:already_running, task}

        true ->
          refresh_existing_task(store, run, task, stage, prompt, route, assignment, opts)
      end
    end
  end

  defp refresh_existing_task(store, run, task, stage, prompt, route, codex_assignment, opts) do
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
             runtime: runtime_name(opts),
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
    caller = self()
    claim_ref = make_ref()

    case Task.Supervisor.start_child(task_supervisor, fn -> run_child(store, launch, caller, claim_ref) end) do
      {:ok, pid} ->
        receive do
          {:factory_task_claimed, ^claim_ref, :ok} -> {:ok, pid}
          {:factory_task_claimed, ^claim_ref, :already_running} -> {:already_running, launch.task}
        after
          5_000 -> {:error, :factory_task_claim_timeout}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp run_child(store, launch, caller, claim_ref) do
    task_key = launch.task["task_key"]
    parent = Keyword.fetch!(launch.opts, :recipient)
    launch_prompt_sha256 = digest(launch.prompt)

    case :global.register_name(task_registration(task_key), self()) do
      :yes ->
        send(caller, {:factory_task_claimed, claim_ref, :ok})

      :no ->
        send(caller, {:factory_task_claimed, claim_ref, :already_running})
        exit(:normal)
    end

    on_thread_started = fn thread_id ->
      case TaskLedger.update_if_current(
             store,
             task_key,
             launch_prompt_sha256,
             @in_flight_states,
             %{status: "RUNNING", thread_id: thread_id}
           ) do
        {:ok, _task} ->
          RunLedger.update(store, launch.run["run_id"], %{task_id: thread_id})
          send(parent, {:factory_task_started, task_key, thread_id})

        {:skipped, %{"status" => "COMPLETE", "thread_id" => ^thread_id, "prompt_sha256" => prompt_sha256}}
        when prompt_sha256 == launch_prompt_sha256 ->
          send(parent, {:factory_task_started, task_key, thread_id})

        _other ->
          :ok
      end
    end

    stage_runner =
      Keyword.get(
        launch.opts,
        :stage_runner,
        if(Keyword.get(launch.opts, :task_transport) == "desktop_broker", do: DesktopStageRunner, else: StageRunner)
      )

    result =
      stage_runner.run(launch.workspace, launch.issue, launch.prompt, launch.output_schema,
        format_repair_attempts: Keyword.get(launch.opts, :format_repair_attempts, 0),
        model: launch.route.model,
        project_id: Keyword.fetch!(launch.opts, :project_id),
        project_root: Keyword.fetch!(launch.opts, :project_root),
        reasoning_effort: launch.route.reasoning_effort,
        required_apps: Keyword.get(launch.opts, :required_apps, []),
        required_mcp_servers: Keyword.get(launch.opts, :required_mcp_servers, []),
        mcp_startup_timeout_ms: Keyword.get(launch.opts, :mcp_startup_timeout_ms, 60_000),
        resume_thread_id: launch.resume_thread_id,
        service_name: "symphony-factory",
        section_id: Keyword.get(launch.opts, :section_id),
        thread_source: "symphonyFactory",
        thread_name: Keyword.fetch!(launch.opts, :thread_name),
        on_thread_started: on_thread_started,
        store: store,
        target_kind: "TASK",
        target_key: task_key,
        request_key: DesktopStageRunner.request_key(task_key, launch.task["turn_id"], launch.prompt),
        previous_turn_id: launch.task["turn_id"],
        issue_key: launch.issue.identifier,
        branch: launch.run["branch"],
        base_branch: launch.run["base_branch"],
        workspace_mode:
          Keyword.get(launch.opts, :workspace_mode) ||
            if(Keyword.get(launch.opts, :task_transport) == "desktop_broker", do: "CODEX_NATIVE"),
        expected_sha: Keyword.get(launch.opts, :expected_sha),
        native_source_attachment_enabled: Keyword.get(launch.opts, :native_source_attachment_enabled, false),
        model_policy: Keyword.get(launch.opts, :model_policy, %{})
      )

    persist_result(store, task_key, launch_prompt_sha256, result)
    send(parent, {:factory_task_finished, task_key, result})
  end

  defp persist_result(store, task_key, prompt_sha256, {:ok, result}) do
    TaskLedger.update_if_current(store, task_key, prompt_sha256, @in_flight_states, %{
      status: "COMPLETE",
      thread_id: result.thread_id,
      turn_id: result.turn_id,
      output_json: Jason.encode!(result.output),
      failure_code: nil
    })
  end

  defp persist_result(store, task_key, prompt_sha256, {:error, reason}) do
    TaskLedger.update_if_current(store, task_key, prompt_sha256, @in_flight_states, %{
      status:
        cond do
          retryable_writer_conflict?(reason) -> "WAITING_FOR_WRITER"
          match?({:desktop_request_pending, _, _}, reason) -> "WAITING_FOR_BROKER"
          match?({:desktop_request_reconciliation_required, _}, reason) -> "WAITING_FOR_BROKER"
          true -> "FAILED"
        end,
      failure_code: inspect(reason)
    })
  end

  @doc "Whether Codex refused to resume a task because another writer still owns it."
  @spec retryable_writer_conflict?(term()) :: boolean()
  def retryable_writer_conflict?({:response_error, %{"code" => -32_600, "message" => message}})
      when is_binary(message) do
    String.contains?(String.downcase(message), "active writer")
  end

  def retryable_writer_conflict?(_reason), do: false

  @doc "Returns the live local stage process for a durable task key, if any."
  @spec active_owner(String.t()) :: pid() | nil
  def active_owner(task_key) when is_binary(task_key) do
    case :global.whereis_name(task_registration(task_key)) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp runtime_name(opts) do
    if Keyword.get(opts, :task_transport) == "desktop_broker",
      do: "codex-desktop-broker",
      else: "codex-app-server"
  end

  defp validate_run_route(run, issue, project_root) do
    case {run["issue_key"], run["repo_path"], issue.identifier} do
      {issue_key, repo_path, issue_identifier}
      when issue_key == issue_identifier and is_binary(repo_path) and is_binary(project_root) ->
        if Path.expand(repo_path) == Path.expand(project_root),
          do: :ok,
          else: {:error, :factory_run_repository_route_mismatch}

      _other ->
        {:error, :factory_run_repository_route_missing}
    end
  end

  defp validate_task_route(task, run, route, assignment) do
    if task["run_id"] == run["run_id"] and task["role"] == route.resolved_role and
         task["codex_project_id"] == assignment.project_id do
      :ok
    else
      {:error, :factory_task_route_mismatch}
    end
  end

  defp live_task?(task_key) do
    is_pid(active_owner(task_key))
  end

  defp unresolved_native_request?(store, task_key) do
    not is_nil(
      Store.one!(
        store,
        "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED') LIMIT 1",
        [task_key]
      )
    )
  end

  defp task_registration(task_key) do
    {__MODULE__, :active, task_key}
  end
end
