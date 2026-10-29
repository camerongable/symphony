defmodule SymphonyElixir.Factory.TaskLauncher do
  @moduledoc """
  Resolves model policy, records it before launch, and starts a visible Codex task.
  """

  alias SymphonyElixir.Codex.ResumeRefusal

  alias SymphonyElixir.Factory.{
    DesktopStageRunner,
    ModelRouter,
    ReviewProtocol,
    RunLedger,
    SpecialistErrorNotice,
    StageRunner,
    Store,
    TaskLedger,
    TicketCapabilityRecovery,
    WorkerInstructions
  }

  alias SymphonyElixir.Factory.{StageSchemas, TicketChat, TicketWorkerRunner, WorkerEvidence, WorkspaceAccess}
  alias SymphonyElixir.Factory.{TicketChatCommands, TicketContractAmendment, TicketPush}

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
    project_id = Keyword.fetch!(opts, :project_id)
    section_id = Keyword.get(opts, :section_id)
    codex_assignment = %{project_id: project_id, section_id: section_id}

    with {:ok, route} <- launch_route(store, run, prompt, opts),
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

  defp launch_route(store, %{"execution_mode" => "TICKET_SUPERVISOR_V1"}, prompt, opts) do
    case TaskLedger.get(store, Keyword.fetch!(opts, :task_key)) do
      {:ok, task} ->
        if task["status"] != "CONSUMED" or task["prompt_sha256"] == digest(prompt),
          do: {:ok, stored_route(task, Keyword.fetch!(opts, :role))},
          else: resolve_route(opts)

      _ ->
        resolve_route(opts)
    end
  end

  defp launch_route(_store, _run, _prompt, opts), do: resolve_route(opts)

  defp resolve_route(opts) do
    ModelRouter.resolve(Keyword.fetch!(opts, :model_policy), Keyword.fetch!(opts, :role), risk: Keyword.get(opts, :risk), risk_signals: Keyword.get(opts, :risk_signals, []))
  end

  defp stored_route(task, role) do
    %{
      result: "RESOLVED",
      requested_role: role,
      resolved_role: task["role"],
      provider: task["model_provider"],
      model_class: task["model_class"],
      model: task["model"],
      reasoning_effort: task["reasoning_effort"],
      routing_reason: task["routing_reason"]
    }
  end

  defp locked_launch(launch) do
    lock = {{__MODULE__, :launch, Keyword.fetch!(launch.opts, :task_key)}, self()}

    case :global.trans(lock, fn -> launch_claimed_task(launch) end) do
      :aborted -> {:error, :factory_task_launch_lock_unavailable}
      result -> result
    end
  end

  defp launch_claimed_task(%{run: %{"execution_mode" => "TICKET_SUPERVISOR_V1"}} = launch) do
    task_key = Keyword.fetch!(launch.opts, :task_key)

    case TaskLedger.get(launch.store, task_key) do
      {:error, :unknown_task} -> begin_ticket_task(launch)
      {:ok, task} -> existing_ticket_task(launch, task)
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

  defp recover_ticket_task(store, task) do
    attempts = WorkerEvidence.pending(store, task["run_id"]) |> Enum.filter(&(&1["task_key"] == task["task_key"])) |> Enum.map(&[&1["request_key"]])

    case attempts do
      [[key]] ->
        case WorkerEvidence.adopt_completed(store, key) do
          {:ok, adopted} -> {:already_terminal, adopted}
          {:error, _} = error -> error
        end

      [] ->
        recover_consumed_ticket_task(store, task)

      _ ->
        {:error, :worker_attempt_reconciliation_required}
    end
  end

  defp existing_ticket_task(launch, task) do
    cond do
      live_task?(task["task_key"]) ->
        {:already_running, task}

      is_map(launch.opts[:blocked_resume]) ->
        begin_ticket_task(launch)

      is_map(launch.opts[:ci_evidence_successor]) ->
        begin_ticket_task(launch)

      task["run_id"] != launch.run["run_id"] or task["role"] != launch.route.requested_role ->
        {:error, :factory_task_route_mismatch}

      new_ticket_pass?(launch, task) ->
        begin_ticket_task(launch)

      {task["stage"], task["prompt_sha256"]} != {launch.stage, digest(launch.prompt)} ->
        {:error, :worker_inputs_changed}

      ticket_attempt_unissued?(launch.store, task) ->
        begin_ticket_task(launch)

      true ->
        recover_ticket_task(launch.store, task)
    end
  end

  defp new_ticket_pass?(launch, task),
    do:
      task["status"] == "CONSUMED" and task["prompt_sha256"] != digest(launch.prompt) and
        Keyword.get(launch.opts, :resume_terminal, false)

  defp ticket_attempt_unissued?(store, task) do
    rows = WorkerEvidence.pending(store, task["run_id"]) |> Enum.filter(&(&1["task_key"] == task["task_key"])) |> Enum.map(&[&1["status"]])
    task["status"] in @in_flight_states and rows in [[], [["RESERVED"]]]
  end

  defp begin_ticket_task(launch) do
    admitted_run = if is_map(launch.opts[:ready_rework]), do: Map.put(launch.run, "state", "REVIEW_WRITING"), else: launch.run

    with :ok <- TicketChat.ordinary_delivery_eligibility(admitted_run),
         :ok <- TicketWorkerRunner.validate_authorization(admitted_run, launch.opts[:authorization]),
         {:ok, _} <- TicketChat.ready_for_run(launch.store, launch.run["run_id"]),
         :ok <- TicketWorkerRunner.admitted_stage(admitted_run, launch.route.requested_role),
         true <- launch.stage == admitted_run["state"] or {:error, :ticket_worker_stage_changed},
         {:ok, packet} <- ticket_base_packet(launch),
         :ok <- ReviewProtocol.validate_admission(packet, launch.output_schema),
         true <-
           ((packet == launch.prompt or launch.opts[:blocked_resume_prompt] == launch.prompt or
               (is_map(launch.opts[:ci_evidence_successor]) and launch.opts[:ci_evidence_successor].prompt == launch.prompt and launch.opts[:ci_evidence_successor].run == launch.run) or
               (is_map(launch.opts[:failed_turn_recovery]) and launch.opts[:failed_turn_recovery]["prompt"] == launch.prompt) or
               (is_map(launch.opts[:ready_rework]) and launch.opts[:ready_rework][:prompt] == launch.prompt)) and
              launch.output_schema == ReviewProtocol.schema_json(packet, ticket_schema(launch.route.requested_role))) or
             {:error, :ticket_worker_packet_mismatch},
         true <- launch.workspace == launch.run["worktree"] or {:error, :ticket_worker_scope_mismatch},
         admitted_options =
           launch.opts |> Keyword.put(:instruction_binding_sha256, Jason.decode!(packet)["instruction_binding_sha256"]) |> Keyword.put(:instruction_mapping_required, same_prepared_prompt?(launch)),
         admitted_launch = %{launch | opts: admitted_options},
         {:ok, prepared} <- prepare_ticket_task(admitted_launch),
         {:ok, pid} <- start_task(launch.store, launch.task_supervisor, prepared) do
      {:ok, %{pid: pid, ref: Process.monitor(pid), task_key: prepared.task["task_key"], route: prepared.route}}
    end
  end

  defp ticket_base_packet(launch) do
    case launch.opts[:blocked_resume] do
      %{"operational_recovery_key" => "TCAP-" <> _} = resume ->
        TicketCapabilityRecovery.retained_packet(launch.store, launch.run, launch.opts[:review_base_sha], resume)

      _ ->
        TicketWorkerRunner.read_packet(launch.store, launch.run["run_id"], launch.route.requested_role, launch.opts[:review_base_sha])
    end
  end

  defp ticket_schema("feature-writer"), do: StageSchemas.for_stage(:native_feature_writer)
  defp ticket_schema("feature-planner"), do: StageSchemas.for_stage(:feature_planner)
  defp ticket_schema("change-verifier"), do: StageSchemas.for_stage(:change_verifier)
  defp ticket_schema(_role), do: nil

  defp prepare_ticket_task(launch) do
    if is_map(launch.opts[:ci_evidence_successor]) do
      prepare_ci_successor_task(launch)
    else
      with {:ok, launch} <- observe_failed_start(launch) do
        prepare_observed_ticket_task(launch)
      end
    end
  end

  defp prepare_ci_successor_task(launch) do
    with {:ok, admitted} <- SymphonyElixir.Factory.TicketCiRepairSuccessor.admit(launch.store, launch.opts[:ci_evidence_successor], launch.opts),
         true <- admitted.prompt == launch.prompt do
      options =
        Keyword.merge(launch.opts,
          request_key: admitted.destination["request_key"],
          reservation_key: admitted.access["reservation_key"],
          expected_sha: launch.run["candidate_sha"],
          owner_id: admitted.destination["owner_id"],
          resume_thread_id: admitted.task["thread_id"],
          instruction_binding_sha256: admitted.instruction_sha,
          instruction_mapping_required: true,
          ci_successor_key: admitted.row["successor_key"],
          model: admitted.task["model"],
          reasoning_effort: admitted.task["reasoning_effort"]
        )

      {:ok,
       %{launch | opts: options, route: %{launch.route | resolved_role: admitted.task["role"]}, workspace: admitted.access["canonical_path"]}
       |> Map.merge(%{task: admitted.task, resume_thread_id: admitted.task["thread_id"]})}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_packet_unproven}
    end
  end

  defp observe_failed_start(launch) do
    case launch.opts[:failed_turn_recovery] do
      proof when is_map(proof) ->
        with {:ok, opts} <- SymphonyElixir.Factory.FailedTurnRecovery.start_observation(launch.store, proof, launch.opts) do
          {:ok, %{launch | opts: opts}}
        end

      _ ->
        {:ok, launch}
    end
  end

  defp prepare_observed_ticket_task(launch) do
    result =
      Exqlite.transaction(
        launch.store,
        fn tx ->
          case prepare_ticket_task_transaction(tx, launch) do
            {:error, reason} -> Exqlite.rollback(tx, reason)
            {:ok, prepared} -> bind_task_instructions(tx, prepared)
          end
        end,
        timeout: 60_000
      )

    case result do
      {:ok, prepared} -> prepared
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_task_instructions(store, prepared) do
    key = prepared.opts[:instruction_binding_sha256]

    result =
      if prepared.opts[:instruction_mapping_required] do
        case WorkerInstructions.task_binding(store, prepared.task) do
          {:ok, %{"instruction_binding_sha256" => ^key}} -> :ok
          _ -> {:error, :worker_instruction_task_binding_unproven}
        end
      else
        WorkerInstructions.bind_task(store, prepared.task["task_key"], digest(prepared.prompt), key)
      end

    case result do
      :ok -> {:ok, prepared}
      {:error, reason} -> Exqlite.rollback(store, reason)
    end
  end

  defp same_prepared_prompt?(launch) do
    case TaskLedger.get(launch.store, launch.opts[:task_key]) do
      {:ok, task} -> task["status"] in @in_flight_states and task["prompt_sha256"] == digest(launch.prompt)
      _ -> false
    end
  end

  defp prepare_ticket_task_transaction(store, launch) do
    cond do
      is_map(launch.opts[:failed_turn_recovery]) -> prepare_failed_turn_retry(store, launch)
      is_map(launch.opts[:blocked_resume]) -> prepare_blocked_resume_transaction(store, launch)
      is_map(launch.opts[:ready_rework]) and launch.opts[:ready_rework][:prepared] -> reuse_prepared_ready_rework_transaction(store, launch)
      is_map(launch.opts[:ready_rework]) -> prepare_ready_rework_transaction(store, launch)
      true -> prepare_ordinary_ticket_task_transaction(store, launch)
    end
  end

  defp prepare_failed_turn_retry(store, launch) do
    receipt = launch.opts[:failed_turn_recovery]

    with :ok <- SymphonyElixir.Factory.FailedTurnRecovery.start_preflight_observed(store, receipt, launch.opts),
         :ok <- WorkspaceAccess.source_capacity(store, launch.run, Keyword.take(launch.opts, [:capacity_policy, :free_bytes])),
         true <- launch.prompt == receipt["prompt"] or {:error, :failed_retry_packet_changed},
         {:ok, task} <- TaskLedger.get(store, launch.opts[:task_key]),
         true <- task["status"] == "STARTING" or {:error, :failed_retry_task_changed},
         {:ok, attempt} <- WorkerEvidence.get(store, receipt["new_request_key"]),
         true <- attempt["status"] == "RESERVED" or {:error, :failed_retry_already_issued} do
      opts =
        Keyword.merge(launch.opts,
          request_key: attempt["request_key"],
          reservation_key: attempt["reservation_key"],
          owner_id: attempt["owner_id"],
          model: task["model"],
          reasoning_effort: task["reasoning_effort"]
        )

      {:ok, %{launch | opts: opts} |> Map.merge(%{task: task, resume_thread_id: task["thread_id"]})}
    else
      {:error, _} = error -> error
    end
  end

  defp reuse_prepared_ready_rework_transaction(store, launch) do
    ready = launch.opts[:ready_rework]
    key = Keyword.fetch!(launch.opts, :task_key)

    with {:ok, current} <- RunLedger.get(store, launch.run["run_id"]),
         :ok <- current_ticket_launch(current, launch.run),
         :ok <- TicketWorkerRunner.validate_authorization(current, launch.opts[:authorization]),
         {:ok, %{receipt: receipt, input: input}} <-
           TicketChatCommands.validate_ready_rework_replay(store, ready.command_key),
         true <-
           {input["input_key"], input["body"], receipt["candidate_sha"]} ==
             {ready.input_key, ready.input_body, current["candidate_sha"]} or {:error, :ready_rework_input_changed},
         {:ok, task} <- TaskLedger.get(store, key),
         {:ok, assignment} <- ready_rework_assignment(task, launch.opts),
         true <- (task["status"] == "STARTING" and task["prompt_sha256"] == digest(launch.prompt)) or {:error, :ready_rework_task_changed},
         request = receipt["request_key"],
         reservation = receipt["reservation_key"],
         true <- DesktopStageRunner.request_key(key, task["turn_id"], launch.prompt) == request or {:error, :ready_rework_request_changed},
         {:ok, access} <- WorkspaceAccess.get(store, reservation),
         true <- (access["generation"] == receipt["reservation_generation"] and access["request_key"] == request) or {:error, :ready_rework_access_changed},
         validation = WorkspaceAccess.validate(store, reservation, access["generation"], clean: true, candidate_adopted: true),
         {:ok, _} <- validation,
         {:ok, %{"status" => "RESERVED", "task_key" => ^key, "reservation_key" => ^reservation} = attempt} <- WorkerEvidence.get(store, request),
         true <- attempt["binding_sha256"] == digest(attempt["binding_json"]) or {:error, :ready_rework_attempt_changed},
         {:ok, binding} <- Jason.decode(attempt["binding_json"]),
         {:ok, prior} <- WorkerEvidence.get(store, receipt["prior_request_key"]),
         true <- prior["binding_sha256"] == digest(prior["binding_json"]) or {:error, :ready_rework_attempt_changed},
         {:ok, prior_binding} <- Jason.decode(prior["binding_json"]),
         true <- WorkerEvidence.runtime_matches?(binding, prior_binding) or {:error, :worker_native_runtime_conflict},
         {:ok, runtime_opts} <- WorkerEvidence.runtime_options(binding, launch.opts) do
      worker_opts =
        Keyword.merge(runtime_opts,
          project_id: assignment.project_id,
          section_id: assignment.section_id,
          request_key: request,
          reservation_key: reservation,
          owner_id: "owner:" <> request,
          resume_thread_id: task["thread_id"],
          model: task["model"],
          reasoning_effort: task["reasoning_effort"]
        )

      {:ok, %{launch | opts: worker_opts} |> Map.merge(%{task: task, resume_thread_id: task["thread_id"]})}
    else
      {:error, _} = error -> error
      _ -> {:error, :ready_rework_prepared_state_unproven}
    end
  end

  defp prepare_ready_rework_transaction(store, launch) do
    ready = launch.opts[:ready_rework]
    key = Keyword.fetch!(launch.opts, :task_key)

    with {:ok, current} <- RunLedger.get(store, launch.run["run_id"]),
         :ok <- current_ticket_launch(current, launch.run),
         :ok <- TicketWorkerRunner.validate_authorization(Map.put(current, "state", "REVIEW_WRITING"), launch.opts[:authorization]),
         {:ok, plan} <- TicketChatCommands.validate_ready_rework(store, ready.command_key),
         true <- {plan.input["input_key"], plan.input["body"], ready.prompt} == {ready.input_key, ready.input_body, launch.prompt} or {:error, :ready_rework_input_changed},
         :ok <- WorkspaceAccess.source_capacity(store, current, Keyword.take(launch.opts, [:capacity_policy, :free_bytes])),
         {:ok, task} <- TaskLedger.get(store, key),
         {:ok, assignment} <- ready_rework_assignment(task, launch.opts),
         {:ok, prior} <- ready_rework_predecessor(store, task, current),
         true <- digest(prior.evidence["binding_json"]) == prior.evidence["binding_sha256"] or {:error, :worker_evidence_corrupt},
         {:ok, prior_binding} <- Jason.decode(prior.evidence["binding_json"]),
         {:ok, %{run: changed_run}} <- RunLedger.update(store, current["run_id"], %{state: "REVIEW_WRITING"}),
         route = %{launch.route | resolved_role: launch.route.requested_role},
         {:ok, refreshed, resume} <- prepare_task(store, changed_run, key, "REVIEW_WRITING", launch.prompt, route, assignment, Keyword.put(launch.opts, :resume_terminal, true)),
         request = DesktopStageRunner.request_key(key, refreshed["turn_id"], launch.prompt),
         reservation = "workspace:" <> request,
         {:ok, access} <-
           WorkspaceAccess.acquire(
             store,
             %{
               "reservation_key" => reservation,
               "run_id" => current["run_id"],
               "task_key" => key,
               "request_key" => request,
               "mode" => "SOURCE",
               "allowed_root" => launch.opts[:workspace_root],
               "expected_sha" => current["candidate_sha"]
             },
             Keyword.take(launch.opts, [:capacity_policy, :free_bytes])
           ),
         true <-
           {access["canonical_path"], access["git_dir"], access["common_dir"]} == {prior.access["canonical_path"], prior.access["git_dir"], prior.access["common_dir"]} or
             {:error, :ready_rework_checkout_changed},
         {:ok, _attempt} <-
           reserve_ready_attempt(
             store,
             %{
               "request_key" => request,
               "task_key" => key,
               "reservation_key" => reservation,
               "input_sha256" => digest(launch.prompt),
               "owner_id" => "owner:" <> request,
               "schema" => launch.output_schema,
               "policy" => TicketWorkerRunner.policy("SOURCE", access["canonical_path"])
             },
             prior_binding,
             launch.opts
           ),
         {:ok, _application} <-
           TicketChatCommands.record_ready_rework(store, ready.command_key, %{
             "command_key" => ready.command_key,
             "input_key" => ready.input_key,
             "candidate_sha" => current["candidate_sha"],
             "request_key" => request,
             "reservation_key" => reservation,
             "reservation_generation" => access["generation"],
             "prior_request_key" => prior.evidence["request_key"],
             "prior_evidence_sha256" => digest(Jason.encode!(prior.evidence)),
             "prior_access_sha256" => digest(Jason.encode!(prior.access)),
             "prior_evidence_json" => Jason.encode!(prior.evidence),
             "prior_access_json" => Jason.encode!(prior.access),
             "prior_run_json" => prior.run_json,
             "prior_run_sha256" => digest(prior.run_json),
             "prior_verifier_task_json" => Jason.encode!(prior.verifier_task),
             "prior_verifier_evidence_json" => Jason.encode!(prior.verifier_evidence),
             "prior_candidate_handoff" => prior.candidate_handoff,
             "prior_push_envelope_sha256" => prior.push_proof.envelope_sha256
           }) do
      worker_opts =
        Keyword.merge(launch.opts,
          project_id: assignment.project_id,
          section_id: assignment.section_id,
          request_key: request,
          reservation_key: reservation,
          owner_id: "owner:" <> request,
          resume_thread_id: refreshed["thread_id"],
          model: refreshed["model"],
          reasoning_effort: refreshed["reasoning_effort"]
        )

      {:ok,
       %{launch | run: changed_run, opts: worker_opts, workspace: access["canonical_path"], route: route}
       |> Map.merge(%{task: refreshed, resume_thread_id: resume})}
    else
      {:error, _} = error -> error
      _ -> {:error, :ready_rework_preparation_unproven}
    end
  end

  @doc false
  @spec ready_rework_assignment(map(), keyword()) ::
          {:ok, %{project_id: String.t() | nil, section_id: String.t() | nil}}
          | {:error, :ready_rework_placement_changed}
  def ready_rework_assignment(task, opts) do
    assignment = %{project_id: task["codex_project_id"], section_id: task["codex_section_id"]}

    if Enum.all?([:project_id, :section_id], fn key ->
         is_nil(Keyword.get(opts, key)) or Keyword.get(opts, key) == Map.fetch!(assignment, key)
       end),
       do: {:ok, assignment},
       else: {:error, :ready_rework_placement_changed}
  end

  defp ready_rework_predecessor(store, task, run) do
    evidence =
      Store.one!(
        store,
        "SELECT * FROM worker_evidence WHERE task_key = ? AND run_id = ? AND status = 'CONSUMED' ORDER BY created_at DESC LIMIT 1",
        [task["task_key"], run["run_id"]]
      )

    with true <-
           (task["status"] == "CONSUMED" and is_map(evidence) and evidence["output_json"] == task["output_json"]) or
             {:error, :ready_rework_predecessor_changed},
         true <-
           WorkerEvidence.owner_stopped?(store, evidence) or
             {:error, :ready_rework_predecessor_owner_not_stopped},
         {:ok, access} <- WorkspaceAccess.get(store, evidence["reservation_key"]),
         true <- (not is_nil(access["released_at"]) and access["request_key"] == evidence["request_key"]) or {:error, :ready_rework_predecessor_changed},
         {:ok, output} <- Jason.decode(evidence["output_json"]),
         true <- complete_candidate_output?(output, run) or {:error, :ready_rework_predecessor_not_complete},
         {:ok, verifier} <- ready_rework_verifier_predecessor(store, run) do
      prior_run = Map.take(run, ~w(run_id issue_key state spec_revision contract_sha256 candidate_sha verifier_round repo_path worktree branch base_branch candidate_handoff mr_iid mr_url mr_state))

      {:ok,
       %{
         evidence: evidence,
         access: access,
         run_json: Jason.encode!(prior_run),
         verifier_task: verifier.task,
         verifier_evidence: verifier.evidence,
         candidate_handoff: run["candidate_handoff"],
         push_proof: verifier.push_proof
       }}
    else
      {:error, _} = error -> error
    end
  end

  defp complete_candidate_output?(output, run) do
    output["status"] == "COMPLETE" and (is_nil(output["commit_sha"]) or output["commit_sha"] == run["candidate_sha"])
  end

  defp runtime_attempt_attrs(attrs, opts) do
    if Keyword.has_key?(opts, :native_runtime), do: Map.put(attrs, "native_runtime", opts[:native_runtime]), else: attrs
  end

  defp reserve_ready_attempt(store, attrs, binding, opts) do
    with {:ok, attrs} <- WorkerEvidence.inherit_runtime(runtime_attempt_attrs(attrs, opts), binding), do: WorkerEvidence.reserve(store, attrs)
  end

  defp ready_rework_verifier_predecessor(store, run) do
    verifier_key = run["run_id"] <> ":change-verifier:" <> Integer.to_string(run["verifier_round"])

    with {:ok, verifier_task} <- TaskLedger.get(store, verifier_key),
         {:ok, verifier_evidence} <- WorkerEvidence.verifier_receipt(store, run, verifier_task),
         {:ok, push_proof} <- TicketPush.completed_proof(store, run["run_id"]),
         true <-
           (is_binary(run["candidate_handoff"]) and push_proof.envelope == run["candidate_handoff"]) or
             {:error, :ready_rework_delivery_history_missing} do
      {:ok, %{task: verifier_task, evidence: verifier_evidence, push_proof: push_proof}}
    end
  end

  defp prepare_ordinary_ticket_task_transaction(store, launch) do
    key = Keyword.fetch!(launch.opts, :task_key)
    route = %{launch.route | resolved_role: launch.route.requested_role}
    assignment = %{project_id: nil, section_id: nil}

    with {:ok, current} <- RunLedger.get(store, launch.run["run_id"]),
         :ok <- current_ticket_launch(current, launch.run),
         :ok <- TicketWorkerRunner.validate_authorization(current, launch.opts[:authorization]),
         {:ok, _task, resume} <- prepare_task(store, launch.run, key, launch.stage, launch.prompt, route, assignment, launch.opts),
         {:ok, task} <- TaskLedger.update(store, key, %{workspace: launch.workspace, workspace_sha: launch.opts[:expected_sha]}),
         request = DesktopStageRunner.request_key(key, task["turn_id"], launch.prompt),
         reservation = "workspace:" <> request,
         mode = if(task["role"] == "feature-writer", do: "SOURCE", else: "REVIEW"),
         {:ok, _} <-
           WorkspaceAccess.acquire(
             store,
             %{
               "reservation_key" => reservation,
               "run_id" => launch.run["run_id"],
               "task_key" => key,
               "request_key" => request,
               "mode" => mode,
               "allowed_root" => launch.opts[:workspace_root],
               "expected_sha" => launch.opts[:expected_sha]
             },
             Keyword.take(launch.opts, [:capacity_policy, :free_bytes])
           ) do
      worker_opts = Keyword.merge(launch.opts, request_key: request, reservation_key: reservation, owner_id: "owner:" <> request, model: task["model"], reasoning_effort: task["reasoning_effort"])
      {:ok, %{launch | opts: worker_opts, route: route} |> Map.merge(%{task: task, resume_thread_id: resume})}
    end
  end

  defp prepare_blocked_resume_transaction(store, launch) do
    if launch.opts[:blocked_resume]["prepared"],
      do: reuse_prepared_blocked_resume(store, launch),
      else: create_blocked_resume(store, launch)
  end

  defp create_blocked_resume(store, launch) do
    key = Keyword.fetch!(launch.opts, :task_key)
    resume = launch.opts[:blocked_resume]

    with {:ok, current} <- RunLedger.get(store, launch.run["run_id"]),
         :ok <- current_ticket_launch(current, launch.run),
         :ok <- TicketWorkerRunner.validate_authorization(current, launch.opts[:authorization]),
         :ok <- blocked_capacity(store, current, launch.opts),
         {:ok, task} <- TaskLedger.get(store, key),
         request = DesktopStageRunner.request_key(key, task["turn_id"], launch.prompt),
         reservation = "workspace:" <> request,
         true <- blocked_source_task?(task, resume) or {:error, :blocked_resume_task_not_stopped},
         {:ok, completed, _amendment_receipt} <- blocked_resume_result(store, task, current, resume),
         {:ok, expected_sha} <- blocked_resume_expected_sha(completed, resume, current, launch.opts),
         evidence = completed.evidence,
         true <- completed.output["status"] == "BLOCKED" or {:error, :blocked_resume_result_invalid},
         true <- launch.prompt == launch.opts[:blocked_resume_prompt] or {:error, :blocked_resume_prompt_mismatch},
         :ok <- blocked_transfer_authority(store, resume),
         proof =
           Map.merge(resume, %{
             "request_key" => evidence["request_key"],
             "output_sha256" => evidence["output_sha256"],
             "task_key" => key,
             "reservation_key" => evidence["reservation_key"],
             "reservation_generation" => Jason.decode!(evidence["binding_json"])["reservation_generation"],
             "new_prompt_sha256" => digest(launch.prompt),
             "amendment_command_key" => resume["amendment_command_key"],
             "checkout_head_sha" => expected_sha
           }),
         attrs = %{
           "reservation_key" => reservation,
           "run_id" => current["run_id"],
           "task_key" => key,
           "request_key" => request,
           "mode" => "SOURCE",
           "allowed_root" => launch.opts[:workspace_root],
           "expected_sha" => expected_sha
         },
         {:ok, access} <- transfer_blocked_access(store, evidence, proof, attrs),
         {:ok, prepared_task} <-
           TaskLedger.update(store, key, %{
             stage: launch.stage,
             status: "STARTING",
             prompt_sha256: digest(launch.prompt),
             workspace: access["canonical_path"],
             workspace_sha: expected_sha,
             output_json: nil,
             failure_code: nil
           }),
         policy = TicketWorkerRunner.policy("SOURCE", access["canonical_path"]),
         {:ok, _attempt} <-
           reserve_blocked_attempt(
             store,
             %{
               "request_key" => request,
               "task_key" => key,
               "reservation_key" => reservation,
               "input_sha256" => digest(launch.prompt),
               "owner_id" => "owner:" <> request,
               "schema" => launch.output_schema,
               "policy" => policy
             },
             resume,
             completed.binding,
             launch.opts
           ),
         transfer = %{
           "kind" => "BLOCKED_SOURCE_TRANSFER",
           "old_request_key" => evidence["request_key"],
           "old_reservation_key" => evidence["reservation_key"],
           "new_request_key" => request,
           "new_reservation_key" => reservation,
           "new_generation" => access["generation"],
           "disposition_key" => resume["disposition_key"],
           "output_sha256" => evidence["output_sha256"],
           "amendment_command_key" => resume["amendment_command_key"],
           "operational_recovery_key" => resume["operational_recovery_key"],
           "checkout_head_sha" => expected_sha
         },
         {:ok, _command} <- record_blocked_transfer(store, resume, transfer) do
      worker_opts =
        Keyword.merge(launch.opts,
          request_key: request,
          reservation_key: reservation,
          expected_sha: expected_sha,
          owner_id: "owner:" <> request,
          resume_thread_id: prepared_task["thread_id"],
          blocked_resume: resume,
          model: prepared_task["model"],
          reasoning_effort: prepared_task["reasoning_effort"]
        )

      {:ok,
       %{launch | opts: worker_opts, route: %{launch.route | resolved_role: prepared_task["role"]}, workspace: access["canonical_path"]}
       |> Map.merge(%{task: prepared_task, resume_thread_id: prepared_task["thread_id"]})}
    else
      {:error, _} = error -> error
    end
  end

  defp transfer_blocked_access(store, evidence, %{"operational_recovery_key" => "TCAP-" <> _} = proof, attrs),
    do: WorkspaceAccess.transfer_capability_source(store, evidence["reservation_key"], proof["reservation_generation"], attrs, proof)

  defp transfer_blocked_access(store, evidence, proof, attrs),
    do: WorkspaceAccess.transfer_blocked_source(store, evidence["reservation_key"], proof["reservation_generation"], attrs, proof)

  defp reserve_blocked_attempt(store, attrs, resume, binding, opts) do
    with {:ok, attrs} <- WorkerEvidence.inherit_runtime(runtime_attempt_attrs(attrs, opts), binding) do
      case resume do
        %{"operational_recovery_key" => "TCAP-" <> _} -> WorkerEvidence.reserve_capability(store, attrs, resume)
        _ -> WorkerEvidence.reserve(store, attrs)
      end
    end
  end

  defp blocked_capacity(store, run, opts) do
    case opts[:blocked_resume] do
      %{"operational_recovery_key" => "TCAP-" <> _, "prepared" => true} = resume ->
        with {:ok, _} <- TicketCapabilityRecovery.prepared_access(store, resume), do: :ok

      %{"operational_recovery_key" => "TCAP-" <> _} = resume ->
        with {:ok, _} <- TicketCapabilityRecovery.checked(store, resume), do: :ok

      _ ->
        WorkspaceAccess.source_capacity(store, run, Keyword.take(opts, [:capacity_policy, :free_bytes]))
    end
  end

  defp blocked_transfer_authority(store, %{"operational_recovery_key" => "TCAP-" <> _} = resume) do
    with {:ok, _} <- TicketCapabilityRecovery.checked(store, resume), do: :ok
  end

  defp blocked_transfer_authority(store, %{"operational_recovery_key" => key}) when is_binary(key),
    do: SymphonyElixir.Factory.TicketInfrastructureRecovery.preflight(store, key)

  defp blocked_transfer_authority(store, resume), do: TicketChatCommands.preflight_rework_transfer(store, resume["command_key"])

  defp record_blocked_transfer(store, %{"operational_recovery_key" => "TCAP-" <> _} = resume, transfer),
    do: TicketCapabilityRecovery.transferred(store, resume, transfer)

  defp record_blocked_transfer(store, %{"operational_recovery_key" => key}, transfer) when is_binary(key),
    do: SymphonyElixir.Factory.TicketInfrastructureRecovery.record_transfer(store, key, transfer)

  defp record_blocked_transfer(store, resume, transfer), do: TicketChatCommands.record_rework_transfer(store, resume["command_key"], transfer)

  defp applied_blocked_transfer(store, %{"operational_recovery_key" => "TCAP-" <> _ = key}),
    do: TicketCapabilityRecovery.applied(store, key)

  defp applied_blocked_transfer(store, %{"operational_recovery_key" => key}) when is_binary(key),
    do: SymphonyElixir.Factory.TicketInfrastructureRecovery.applied(store, key)

  defp applied_blocked_transfer(store, resume) do
    with {:ok, %{"status" => "APPLIED", "application_receipt_json" => raw}} <- TicketChatCommands.get(store, resume["command_key"]),
         :ok <- TicketChatCommands.validate_rework_replay(store, resume["command_key"]),
         do: Jason.decode(raw)
  end

  defp blocked_source_task?(task, resume),
    do: task["status"] == "COMPLETE" and task["role"] == "feature-writer" and task["thread_id"] == resume["thread_id"]

  defp completed_result_matches?(completed, task, run, resume),
    do: completed.task == task and completed.run == run and completed.access["request_key"] == resume["request_key"]

  defp blocked_resume_result(store, task, run, %{"amendment_command_key" => command_key} = resume) do
    with {:ok, receipt} <- TicketContractAmendment.blocked_predecessor_for_request(store, resume["request_key"]),
         true <- receipt["command_key"] == command_key or {:error, :blocked_resume_amendment_link_mismatch},
         :ok <- WorkspaceAccess.validate_blocked_amendment_predecessor(store, receipt),
         {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, evidence} when is_map(evidence) <- Jason.decode(predecessor["evidence_json"]),
         {:ok, held_task} when is_map(held_task) <- Jason.decode(predecessor["task_json"]),
         {:ok, access} when is_map(access) <- Jason.decode(predecessor["access_json"]),
         {:ok, binding} when is_map(binding) <- Jason.decode(evidence["binding_json"]),
         {:ok, output} when is_map(output) <- Jason.decode(evidence["output_json"]),
         true <- (held_task == task and output["status"] == "BLOCKED") or {:error, :blocked_resume_predecessor_changed} do
      {:ok,
       %{
         run: run,
         task: held_task,
         evidence: evidence,
         binding: binding,
         output: output,
         access: access,
         checkout_head_sha: predecessor["checkout_head_sha"]
       }, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_resume_predecessor_unproven}
    end
  end

  defp blocked_resume_result(store, task, run, %{"operational_recovery_key" => "TCAP-" <> _} = resume) do
    with {:ok, verified} <- TicketCapabilityRecovery.checked(store, resume),
         true <- completed_result_matches?(verified.facts, task, run, resume) or {:error, :blocked_resume_result_changed},
         do: {:ok, verified.facts, nil}
  end

  defp blocked_resume_result(store, task, run, resume) do
    with {:ok, completed} <- WorkerEvidence.completed_result(store, resume["request_key"]),
         true <- completed_result_matches?(completed, task, run, resume) or {:error, :blocked_resume_result_changed} do
      {:ok, completed, nil}
    else
      {:error, _} = error -> error
    end
  end

  defp blocked_resume_expected_sha(completed, %{"amendment_command_key" => command_key} = resume, %{"candidate_sha" => nil}, _opts)
       when is_binary(command_key) do
    expected = resume["checkout_head_sha"]

    if valid_sha?(expected) and
         (is_nil(Map.get(completed, :checkout_head_sha)) or Map.get(completed, :checkout_head_sha) == expected) do
      {:ok, expected}
    else
      {:error, :blocked_resume_expected_sha_unproven}
    end
  end

  defp blocked_resume_expected_sha(completed, _resume, %{"state" => "WRITING", "candidate_sha" => nil, "implementation_iteration" => 0}, opts) do
    base = opts[:review_base_sha]

    with true <- valid_sha?(base) and opts[:expected_sha] == base,
         {:ok, binding} when is_map(binding) <- Jason.decode(completed.evidence["binding_json"] || "null"),
         true <- {binding["role"], binding["mode"], binding["expected_sha"], binding["base_sha"], binding["candidate_sha"]} == {"feature-writer", "SOURCE", base, base, nil},
         true <- Map.get(completed, :checkout_head_sha) in [nil, base] do
      {:ok, base}
    else
      _ -> {:error, :blocked_resume_expected_sha_unproven}
    end
  end

  defp blocked_resume_expected_sha(_completed, _resume, %{"candidate_sha" => nil}, _opts),
    do: {:error, :blocked_resume_expected_sha_unproven}

  defp blocked_resume_expected_sha(completed, _resume, current, opts) do
    expected = Map.get(completed, :checkout_head_sha) || current["candidate_sha"] || opts[:expected_sha]
    if valid_sha?(expected), do: {:ok, expected}, else: {:error, :blocked_resume_expected_sha_unproven}
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)

  defp reuse_prepared_blocked_resume(store, launch) do
    resume = launch.opts[:blocked_resume]
    key = Keyword.fetch!(launch.opts, :task_key)
    request = resume["prepared_request_key"]
    reservation = resume["prepared_reservation_key"]

    with {:ok, current} <- RunLedger.get(store, launch.run["run_id"]),
         :ok <- current_ticket_launch(current, launch.run),
         :ok <- TicketWorkerRunner.validate_authorization(current, launch.opts[:authorization]),
         :ok <- blocked_capacity(store, current, launch.opts),
         {:ok, task} <- TaskLedger.get(store, key),
         true <- prepared_task_matches?(task, launch, resume) or {:error, :blocked_resume_prepared_task_mismatch},
         {:ok, access} <- prepared_blocked_access(store, reservation, resume),
         :ok <- prepared_resume_head_current(access, resume),
         true <-
           prepared_access_matches?(access, request, key, current["run_id"]) or
             {:error, :blocked_resume_prepared_access_mismatch},
         {:ok, evidence} <- WorkerEvidence.get(store, request),
         true <-
           prepared_attempt_matches?(evidence, key, reservation, request) or
             {:error, :blocked_resume_prepared_attempt_mismatch},
         policy = TicketWorkerRunner.policy("SOURCE", access["canonical_path"]),
         {:ok, attempt} <-
           reserve_prepared_blocked_attempt(
             store,
             runtime_attempt_attrs(
               %{
                 "request_key" => request,
                 "task_key" => key,
                 "reservation_key" => reservation,
                 "input_sha256" => digest(launch.prompt),
                 "owner_id" => "owner:" <> request,
                 "schema" => launch.output_schema,
                 "policy" => policy
               },
               launch.opts
             ),
             resume
           ),
         true <-
           WorkerEvidence.superseded_blocked_attempt?(store, Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [resume["request_key"]])) or
             {:error, :blocked_resume_supersession_unproven},
         {:ok, receipt} <- applied_blocked_transfer(store, resume),
         true <-
           (receipt["request_key"] == request and receipt["prior_request_key"] == resume["request_key"] and receipt["disposition_key"] == resume["disposition_key"]) or
             {:error, :blocked_resume_command_link_mismatch} do
      worker_opts =
        Keyword.merge(launch.opts,
          request_key: request,
          reservation_key: reservation,
          owner_id: attempt["owner_id"],
          resume_thread_id: task["thread_id"],
          blocked_resume: resume,
          model: task["model"],
          reasoning_effort: task["reasoning_effort"]
        )

      {:ok, %{launch | opts: worker_opts, route: %{launch.route | resolved_role: task["role"]}} |> Map.merge(%{task: task, resume_thread_id: task["thread_id"]})}
    else
      {:error, _} = error -> error
    end
  end

  defp prepared_blocked_access(store, _reservation, %{"operational_recovery_key" => "TCAP-" <> _} = resume),
    do: TicketCapabilityRecovery.prepared_access(store, resume)

  defp prepared_blocked_access(store, reservation, resume),
    do: WorkspaceAccess.validate(store, reservation, resume["prepared_reservation_generation"])

  defp reserve_prepared_blocked_attempt(store, attrs, %{"operational_recovery_key" => "TCAP-" <> _} = resume) do
    with {:ok, attempt} <- WorkerEvidence.get(store, attrs["request_key"]),
         true <- digest(attempt["binding_json"]) == attempt["binding_sha256"] or {:error, :worker_evidence_corrupt},
         {:ok, binding} <- Jason.decode(attempt["binding_json"]),
         {:ok, _runtime} <- WorkerEvidence.runtime_options(binding, if(Map.has_key?(attrs, "native_runtime"), do: [native_runtime: attrs["native_runtime"]], else: [])),
         true <- Map.take(binding, ~w(input_sha256 schema policy)) == Map.take(attrs, ~w(input_sha256 schema policy)) do
      TicketCapabilityRecovery.admit_prepared(store, resume)
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_prepared_unproven}
    end
  end

  defp reserve_prepared_blocked_attempt(store, attrs, _resume), do: WorkerEvidence.reserve(store, attrs)

  defp prepared_resume_head_current(access, %{"amendment_command_key" => command_key, "checkout_head_sha" => expected})
       when is_binary(command_key) and is_binary(expected) do
    with true <- valid_sha?(expected),
         {:ok, %{"expected_sha" => ^expected}} <- Jason.decode(access["binding_json"]) do
      case WorkerEvidence.checkout_head(access) do
        {:ok, ^expected} -> :ok
        _ -> {:error, :blocked_resume_checkout_head_changed}
      end
    else
      {:error, _reason} -> {:error, :blocked_resume_checkout_head_unproven}
      _ -> {:error, :blocked_resume_checkout_head_unproven}
    end
  end

  defp prepared_resume_head_current(_access, %{"amendment_command_key" => command_key}) when is_binary(command_key),
    do: {:error, :blocked_resume_checkout_head_unproven}

  defp prepared_resume_head_current(_access, _resume), do: :ok

  defp prepared_task_matches?(task, launch, resume),
    do: task["status"] == "STARTING" and task["prompt_sha256"] == digest(launch.prompt) and task["thread_id"] == resume["thread_id"]

  defp prepared_access_matches?(access, request, task_key, run_id),
    do: {access["request_key"], access["task_key"], access["run_id"], access["mode"]} == {request, task_key, run_id, "SOURCE"}

  defp prepared_attempt_matches?(evidence, task_key, reservation, request),
    do: {evidence["status"], evidence["task_key"], evidence["reservation_key"], evidence["owner_id"]} == {"RESERVED", task_key, reservation, "owner:" <> request}

  defp current_ticket_launch(current, expected) do
    fields = ~w(issue_key state execution_mode manual_validation_required contract_sha256 spec_revision
      contract_markdown snapshot_json worktree branch candidate_sha implementation_iteration verifier_round)
    if Map.take(current, fields) == Map.take(expected, fields), do: :ok, else: {:error, :ticket_worker_inputs_changed}
  end

  defp recover_consumed_ticket_task(store, task) do
    rows =
      Store.query!(
        store,
        """
        SELECT request_key FROM worker_evidence WHERE task_key = ? AND status = 'CONSUMED'
          AND thread_id = ? AND turn_id = ?
        """,
        [task["task_key"], task["thread_id"], task["turn_id"]]
      ).rows

    case rows do
      [[key]] ->
        case WorkerEvidence.adopt_completed(store, key) do
          {:ok, adopted} -> {:already_terminal, adopted}
          error -> error
        end

      [] ->
        {:error, :ticket_worker_launch_not_integrated}

      _ ->
        {:error, :worker_attempt_reconciliation_required}
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

  defp run_child(store, %{run: %{"execution_mode" => "TICKET_SUPERVISOR_V1"}} = launch, caller, claim_ref) do
    key = launch.task["task_key"]

    if :global.register_name(task_registration(key), self()) == :no do
      send(caller, {:factory_task_claimed, claim_ref, :already_running})
    else
      send(caller, {:factory_task_claimed, claim_ref, :ok})
      recipient = Keyword.fetch!(launch.opts, :recipient)

      started = fn thread ->
        TaskLedger.update_if_current(store, key, digest(launch.prompt), @in_flight_states, %{status: "RUNNING", thread_id: thread})
        send(recipient, {:factory_task_started, key, thread})
      end

      opts = Keyword.merge(launch.opts, store: store, target_key: key, on_thread_started: started)
      result = TicketWorkerRunner.run(launch.workspace, launch.issue, launch.prompt, launch.output_schema, opts)

      case result do
        {:ok, _} ->
          persist_result(store, key, digest(launch.prompt), result)

        {:error, reason} ->
          TaskLedger.update_if_current(store, key, digest(launch.prompt), @in_flight_states, %{status: "STALE", failure_code: ResumeRefusal.failure_identity(reason)})
      end

      send(recipient, {:factory_task_finished, key, result})
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

    request_key = DesktopStageRunner.request_key(task_key, launch.task["turn_id"], launch.prompt)

    on_message = fn
      %{event: :session_started, thread_id: thread, turn_id: turn} ->
        identity = %{status: "RUNNING", thread_id: thread, turn_id: turn}
        TaskLedger.update_if_current(store, task_key, launch_prompt_sha256, @in_flight_states, identity)

      message ->
        SpecialistErrorNotice.observe_task(store, task_key, request_key, launch_prompt_sha256, message)
    end

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
        on_message: on_message,
        store: store,
        target_kind: "TASK",
        target_key: task_key,
        request_key: request_key,
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

    persist_result(store, task_key, launch_prompt_sha256, result, request_key)
    send(parent, {:factory_task_finished, task_key, result})
  end

  defp persist_result(store, task_key, prompt_sha256, result), do: persist_result(store, task_key, prompt_sha256, result, nil)

  defp persist_result(store, task_key, prompt_sha256, {:ok, result}, _request_key) do
    TaskLedger.update_if_current(store, task_key, prompt_sha256, @in_flight_states, %{
      status: "COMPLETE",
      thread_id: result.thread_id,
      turn_id: result.turn_id,
      output_json: Jason.encode!(result.output),
      failure_code: nil
    })
  end

  defp persist_result(store, task_key, prompt_sha256, {:error, reason}, request_key) do
    Store.transaction!(store, fn tx ->
      result =
        TaskLedger.update_if_current(tx, task_key, prompt_sha256, @in_flight_states, %{
          status: failed_task_status(reason),
          failure_code: ResumeRefusal.failure_identity(reason)
        })

      maybe_record_task_failure(tx, task_key, request_key, reason, result)

      result
    end)
  end

  defp failed_task_status(reason) do
    cond do
      legacy_controller_writer_conflict?(reason) -> "WAITING_FOR_WRITER"
      broker_wait?(reason) -> "WAITING_FOR_BROKER"
      true -> "FAILED"
    end
  end

  defp broker_wait?({:desktop_request_pending, _, _}), do: true
  defp broker_wait?({:desktop_request_reconciliation_required, _}), do: true
  defp broker_wait?(_reason), do: false

  defp maybe_record_task_failure(tx, task_key, request_key, reason, {:ok, _}) when is_binary(request_key) do
    unless broker_wait?(reason) do
      case SpecialistErrorNotice.record_task(tx, task_key, request_key, reason) do
        {:ok, _} -> :ok
        {:error, error} -> Exqlite.rollback(tx, error)
      end
    end
  end

  defp maybe_record_task_failure(_tx, _task, _request, _reason, _result), do: :ok

  @doc "Whether Codex refused to resume a task because another writer still owns it."
  @spec retryable_writer_conflict?(term()) :: boolean()
  def retryable_writer_conflict?(reason), do: match?({:ok, _}, ResumeRefusal.details(reason))

  @doc "Preserves legacy waiting behavior only for controller and non-ticket task paths."
  @spec legacy_controller_writer_conflict?(term()) :: boolean()
  def legacy_controller_writer_conflict?({:response_error, %{"code" => -32_600, "message" => message}})
      when is_binary(message) do
    String.contains?(String.downcase(message), "active writer")
  end

  def legacy_controller_writer_conflict?(reason), do: retryable_writer_conflict?(reason)

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
