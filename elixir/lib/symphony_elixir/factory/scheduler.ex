defmodule SymphonyElixir.Factory.Scheduler do
  @moduledoc """
  One bounded, restart-safe Jira-to-GitLab factory reconciliation tick.

  Long-running cognitive stages are launched asynchronously. Jira/GitLab
  connector operations remain serialized under the controller tick lease.
  Every state transition is durable before the tick returns.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Workflow

  alias SymphonyElixir.Factory.{
    Capacity,
    Cleanup,
    Contract,
    ContractChat,
    Control,
    ControllerTask,
    DesktopRequest,
    FailedTurnRecovery,
    IntakeLedger,
    JiraMcpConnector,
    JiraMcpReader,
    JiraMcpWriter,
    ModelRouter,
    MrFeedbackConsumer,
    MrFeedbackLedger,
    MrFeedbackPoller,
    MrFeedbackRework,
    NativeWorkspaceMaintenance,
    Policy,
    Prompt,
    Queue,
    Recovery,
    ReviewProtocol,
    RunLedger,
    StageSchemas,
    Store,
    TaskLauncher,
    TaskLedger,
    TicketAmendmentCritic,
    TicketAmendmentJiraOperation,
    TicketCapabilityRecovery,
    TicketChat,
    TicketChatCommands,
    TicketChatOutbox,
    TicketCheckout,
    TicketCompletionConfirmation,
    TicketContextReader,
    TicketContractAmendment,
    TicketInfrastructureRecovery,
    TicketJiraFinalization,
    TicketJiraJournal,
    TicketJiraOperation,
    TicketMrOperation,
    TicketPush,
    TicketVerifierRepair,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkspaceAccess,
    Worktree
  }

  alias SymphonyElixir.Tracker.Issue

  @terminal_states ~w(READY_FOR_REVIEW DELIVERED AWAITING_VALIDATION CANCELLED FAILED)
  @local_intake_denials ~w(
    manual_validation_contract_missing ambiguous_manual_validation_section
    ambiguous_manual_validation_decision ambiguous_manual_validation_environment
    manual_validation_environment_missing manual_validation_format_unsupported
    ticket_manual_validation_not_supported manual_validation_disabled production_validation_forbidden
  )a
  @type context :: map()

  @doc "Reserves/reuses one parent for an ordinary run; does not dispatch native or source work."
  @spec ticket_parent_step(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ticket_parent_step(context, run_id, opts \\ []) do
    lock = {{__MODULE__, :ticket_stage, run_id}, self()}

    case :global.trans(lock, fn -> ticket_parent_step_locked(context, run_id, opts) end) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp ticket_parent_step_locked(context, run_id, opts) do
    with {:ok, run} <- RunLedger.get(context.store, run_id),
         {:ok, attrs} <- prepare_ticket_parent(context, run, opts),
         :ok <- check_new_parent_runtime(context.store, run_id, Path.dirname(attrs.cwd)),
         :ok <- rehome_dated_unissued_parent(context, run, attrs, opts) do
      reserve_ticket_parent(context, run, attrs)
    end
  end

  defp rehome_dated_unissued_parent(context, run, attrs, opts) do
    dated = is_binary(opts[:parent_output_root]) and String.contains?(opts[:parent_output_root], "{date}")

    with true <- dated,
         {:ok, chat} <- TicketChat.for_run(context.store, run["run_id"]),
         true <- chat["cwd"] != attrs.cwd do
      case TicketChat.rehome_unissued(context.store, run["run_id"], attrs, run) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      _ -> :ok
    end
  end

  defp check_new_parent_runtime(store, run_id, root) do
    case TicketChat.for_run(store, run_id) do
      {:ok, _chat} -> :ok
      {:error, :unknown_ticket_chat} -> AppServer.check_ticket_runtime(root)
    end
  end

  defp prepare_ticket_parent(context, run, opts) do
    run_id = run["run_id"]

    with :ok <- TicketChat.ordinary_delivery_eligibility(run),
         :ok <- parent_admission_policy(context.factory.ticket_supervisor, run["issue_key"]),
         {:ok, root} <- parent_output_root(opts[:parent_output_root]),
         true <- is_binary(opts[:broker_thread_id]) or {:error, :parent_broker_identity_invalid},
         {:ok, model} <- ModelRouter.resolve(context.factory.models, "orchestrator-intake"),
         {:ok, reader} <- TicketContextReader.bind(context.store, run_id, opts),
         snapshot <- Jason.decode!(run["snapshot_json"]),
         cwd <- Path.join(root, TicketChat.directory_name(context.factory.scope, snapshot["id"], run["repo_key"])),
         cwd <- retained_parent_cwd(context, run, snapshot, cwd),
         attrs = %{
           scope_key: context.factory.scope,
           issue_id: snapshot["id"],
           issue_key: run["issue_key"],
           repo_key: run["repo_key"],
           route: "desktop_owned_ticket_chat_v1",
           cwd: cwd,
           broker_thread_id: opts[:broker_thread_id],
           context_reader_json: reader,
           model: model.model,
           reasoning_effort: model.reasoning_effort,
           title: "#{run["issue_key"]} · Ticket",
           prompt:
             TicketContextReader.instructions(reader) <>
               " This chat presents ticket progress and user questions; the controller owns all source and delivery actions."
         },
         :ok <- TicketChat.preflight(context.store, run, attrs) do
      {:ok, attrs}
    end
  end

  defp retained_parent_cwd(context, run, snapshot, planned) do
    existing =
      case TicketChat.for_run(context.store, run["run_id"]) do
        {:ok, _} = bound -> bound
        _ -> TicketChat.find(context.store, context.factory.scope, snapshot["id"], run["repo_key"])
      end

    with {:ok, chat} <- existing,
         {:ok, request} <- DesktopRequest.get(context.store, chat["create_request_key"]),
         true <- request["status"] != "PENDING" or not is_nil(chat["thread_id"]) do
      chat["cwd"]
    else
      _ -> planned
    end
  end

  defp reserve_ticket_parent(context, run, attrs) do
    with {:ok, reserved} <- TicketChat.reserve(context.store, run["run_id"], attrs, run) do
      parent_admission_result(context.store, run["run_id"], reserved)
    end
  end

  defp parent_admission_policy(%{"enabled" => true} = policy, issue) do
    if Policy.ticket_selected?(policy, issue), do: :ok, else: {:error, :ticket_chat_not_allowlisted}
  end

  defp parent_admission_policy(_policy, _issue), do: {:error, :ticket_chat_runtime_not_integrated}

  defp parent_output_root(root) when is_binary(root) do
    dated = String.contains?(root, "{date}")
    root = TicketChat.output_root(root)
    if dated, do: File.mkdir_p!(root)

    with true <- Path.type(root) == :absolute or {:error, :ticket_parent_output_root_required},
         {:ok, canonical} <- PathSafety.canonicalize(root),
         true <- (canonical == root and File.dir?(root)) or {:error, :ticket_parent_output_root_invalid} do
      {:ok, root}
    end
  end

  defp parent_output_root(_root), do: {:error, :ticket_parent_output_root_required}

  defp parent_admission_result(store, run_id, %{chat: chat, request: request}) do
    {status, reason} =
      case TicketChat.ready_for_run(store, run_id) do
        {:ok, _} -> {"PARENT_READY", nil}
        {:error, reason} -> {"PARENT_PENDING", reason}
      end

    {:ok,
     %{
       status: status,
       chat_key: chat["chat_key"],
       request_key: request["request_key"],
       request_status: request["status"],
       thread_id: chat["thread_id"],
       reason: reason,
       model_invoked: false
     }}
  end

  @doc "Runs one admitted ordinary ticket role; production polling remains quarantined until parent integration."
  @spec ticket_step(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ticket_step(context, run_id, opts \\ []) do
    lock = {{__MODULE__, :ticket_stage, run_id}, self()}

    case :global.trans(lock, fn -> ticket_step_locked(context, run_id, opts) end) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp ticket_step_locked(context, run_id, opts) do
    with {:ok, run} <- RunLedger.get(context.store, run_id) do
      if run["state"] == "FAILED" and TicketVerifierRepair.pending?(context.store, run_id) do
        opts = Keyword.put(opts, :workspace, controller_workspace(context))
        TicketVerifierRepair.apply_authorized(context.store, run_id, context.factory, opts)
      else
        ticket_active_step(context, run, opts)
      end
    end
  end

  defp ticket_active_step(context, run, opts) do
    run_id = run["run_id"]

    with :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, _} <- TicketChat.ready_for_run(context.store, run_id) do
      opts = ticket_runtime_options(context, opts)

      result =
        case current_ticket_attempts(context.store, run) do
          [] -> ticket_unreserved_step(context, run, opts)
          [[_key, "RESERVED"]] -> launch_ticket_stage(context, run, opts)
          [[key, "RECONCILE_REQUIRED"]] -> retry_rejected_ticket_resume(context, run, key, opts)
          [[key, _]] -> adopt_or_recover_ticket_stage(context, run, key, opts)
          _ -> {:error, :worker_attempt_reconciliation_required}
        end

      presentation = publish_ticket_progress(context.store, run_id)

      case result do
        {:ok, response} -> {:ok, Map.put(response, :presentation, presentation)}
        error -> error
      end
    end
  end

  defp adopt_or_recover_ticket_stage(context, run, key, opts) do
    successor = SymphonyElixir.Factory.TicketCiRepairSuccessor
    supervisor_policy = Map.get(context.factory, :ticket_supervisor, %{})

    if Map.get(supervisor_policy, "ci_repair") == "native_bounded_v1" and Policy.ticket_selected?(supervisor_policy, run["issue_key"]) and successor.eligible?(context.store, run, key) do
      options =
        ticket_runtime_options(context, Keyword.merge(Map.get(context, :ticket_options, []), opts))
        |> Keyword.put(:workspace, controller_workspace(context))

      with {:ok, authorization} <- ticket_authorization(context, run, options),
           {:ok, prepared} <- successor.prepare(context.store, key, authorization, options) do
        launch_ticket_stage(context, run, Keyword.put(options, :ci_evidence_successor, prepared))
      else
        {:error, :ci_repair_attempt_limit} ->
          with {:ok, authorization} <- ticket_authorization(context, run, options),
               {:ok, exhausted} <- successor.record_exhaustion(context.store, key, authorization, options) do
            {:ok, %{status: "CI_REPAIR_EXHAUSTED", run: exhausted, model_invoked: false}}
          end

        {:error, reason} when reason in ~w(ci_successor_complete_evidence_unavailable ci_successor_evidence_not_new)a ->
          {:ok, %{status: "BLOCKED_NO_NEW_EVIDENCE", model_invoked: false, reason: reason}}

        {:error, _} = error ->
          error
      end
    else
      case ticket_infrastructure_resume(context.store, key) do
        {:ok, resume} -> launch_ticket_stage(context, run, Keyword.put(opts, :blocked_resume, resume))
        :none -> adopt_ticket_stage(context, key)
        {:error, _} = error -> error
      end
    end
  end

  defp ticket_infrastructure_resume(store, key) do
    case TicketCapabilityRecovery.pending_resume(store, key) do
      :none -> TicketInfrastructureRecovery.resume(store, key)
      result -> result
    end
  end

  defp retry_rejected_ticket_resume(context, run, key, opts) do
    case FailedTurnRecovery.prepare_schema_confirmation(context.store, key, opts) do
      :none -> retry_ordinary_rejected_resume(context, run, key, opts)
      {:ok, proof} -> {:ok, %{status: "RECOVERY_PREPARED", recovery_key: proof["recovery_key"], model_invoked: false}}
      error -> error
    end
  end

  defp retry_ordinary_rejected_resume(context, run, key, opts) do
    case TicketWorkerRunner.reconcile_completed(context.store, key, opts) do
      {:ok, _} -> adopt_ticket_stage(context, key)
      {:error, _} -> rearm_ordinary_rejected_resume(context, run, key, opts)
    end
  end

  defp rearm_ordinary_rejected_resume(context, run, key, opts) do
    case WorkerEvidence.rearm_rejected_resume(context.store, key) do
      {:ok, _} -> launch_ticket_stage(context, run, opts)
      {:error, :worker_resume_retry_not_due} -> {:ok, %{status: "WAITING_FOR_WRITER", reason: "Native resume retry cooldown", model_invoked: false}}
      {:error, _} -> prepare_failed_ticket_retry(context, key, opts)
    end
  end

  defp prepare_failed_ticket_retry(context, key, opts) do
    with {:ok, evidence} <- WorkerEvidence.get(context.store, key) do
      case FailedTurnRecovery.prepare_automatic(context.store, key, evidence["turn_id"], opts) do
        {:ok, receipt} ->
          {:ok, %{status: "RECOVERY_PREPARED", recovery_key: receipt["recovery_key"], model_invoked: false}}

        {:error, :failed_retry_cooldown} ->
          {:ok, %{status: "WAITING_FOR_WRITER", reason: "Failed native turn retry cooldown", model_invoked: false}}

        {:error, :failed_retry_not_eligible} ->
          adopt_ticket_stage(context, key)

        {:error, _} = error ->
          error
      end
    end
  end

  defp current_ticket_attempts(store, run) do
    pending = WorkerEvidence.pending(store, run["run_id"])
    current_blocked_request = current_amendment_blocked_request(store, run)

    pending
    |> Enum.reject(fn evidence ->
      evidence["request_key"] != current_blocked_request and
        applied_blocked_predecessor?(store, evidence["request_key"])
    end)
    |> Enum.map(&[&1["request_key"], &1["status"]])
  end

  defp applied_blocked_predecessor?(store, request_key) do
    match?({:ok, %{"application_kind" => "BLOCKED_WRITER_HELD"}}, TicketContractAmendment.blocked_predecessor_for_request(store, request_key))
  end

  defp current_amendment_blocked_request(store, run) do
    with {:ok, %{receipt: receipt}} <- TicketContractAmendment.blocked_predecessor_for_installed_run(store, run),
         {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, evidence} <- Jason.decode(predecessor["evidence_json"]) do
      evidence["request_key"]
    else
      _ -> nil
    end
  end

  defp ticket_unreserved_step(context, %{"state" => "ADMITTING_WRITER"} = run, opts) do
    with {:ok, authorization} <- ticket_authorization(context, run, opts) do
      if is_nil(run["worktree"]) do
        ticket_initial_checkout(context.store, run, authorization, opts)
      else
        admit_ticket_writer(context, run, opts)
      end
    end
  end

  defp ticket_unreserved_step(context, run, opts), do: launch_ticket_stage(context, run, opts)

  defp admit_ticket_writer(context, run, opts) do
    with {:ok, _chat} <- TicketChat.ready_for_run(context.store, run["run_id"]) do
      TicketJiraOperation.start_implementation(context.store, run["run_id"], Keyword.put(opts, :workspace, controller_workspace(context)))
    end
  end

  defp ticket_initial_checkout(store, run, authorization, opts) do
    case TicketCheckout.get(store, run["run_id"]) do
      {:ok, %{"phase" => "PREPARED", "owner_nonce" => nil} = intent} ->
        create_ticket_checkout(store, run, authorization, pinned_checkout_opts(intent, opts))

      {:ok, intent} ->
        TicketCheckout.reconcile(store, run["run_id"], authorization, pinned_checkout_opts(intent, opts))

      {:error, :ticket_checkout_intent_missing} ->
        base = Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])

        case initial_ticket_base(run, base, opts) do
          {:ok, sha} -> create_ticket_checkout(store, run, authorization, Keyword.put(opts, :base_sha, sha))
          error -> error
        end
    end
  end

  defp create_ticket_checkout(store, run, authorization, opts) do
    with {:ok, chat} <- TicketChat.ready_for_run(store, run["run_id"]),
         :ok <- AppServer.check_ticket_runtime(chat["cwd"]) do
      TicketCheckout.create(store, run["run_id"], authorization, Keyword.put(opts, :expected_run, run))
    end
  end

  defp initial_ticket_base(run, base, opts) do
    case Keyword.fetch(opts, :base_sha) do
      {:ok, sha} -> {:ok, sha}
      :error -> if(base, do: {:ok, base["base_sha"]}, else: TicketWorkerRunner.observed_base(run))
    end
  end

  defp pinned_checkout_opts(intent, opts),
    do: Keyword.put(opts, :base_sha, Jason.decode!(intent["binding_json"])["base_sha"])

  defp publish_ticket_progress(store, run_id) do
    case TicketChatOutbox.publish(store, run_id) do
      {:ok, receipt} -> receipt
      {:error, reason} -> %{status: "SYNC_ERROR", reason: inspect(reason), model_invoked: false}
    end
  rescue
    error -> %{status: "SYNC_ERROR", reason: Exception.message(error), model_invoked: false}
  catch
    :exit, reason -> %{status: "SYNC_ERROR", reason: inspect(reason), model_invoked: false}
  end

  defp launch_ticket_stage(context, run, opts) do
    opts = ticket_runtime_options(context, opts)
    base = Store.one!(context.store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])

    with %{"base_sha" => base_sha} <- base,
         {:ok, stage} <- ticket_stage(run, context.factory, context.store),
         {:ok, authorization} <- ticket_authorization(context, run, opts),
         {:ok, prompt, blocked_resume} <- ticket_launch_prompt(context, run, stage, base_sha, opts),
         :ok <- TicketCompletionConfirmation.validate_prompt(stage[:completion_confirmation], prompt) do
      launch_ticket_stage_task(context, run, opts, stage, base_sha, authorization, prompt, blocked_resume)
    else
      nil -> {:error, :ticket_review_base_missing}
      {:error, _} = error -> error
    end
  end

  defp ticket_launch_prompt(context, run, stage, base_sha, opts) do
    case opts[:ci_evidence_successor] do
      %{run: ^run, prompt: prompt} ->
        {:ok, prompt, nil}

      nil ->
        ticket_base_prompt(context, run, stage, base_sha, opts)

      _ ->
        {:error, :ci_successor_preparation_changed}
    end
  end

  defp ticket_runtime_options(context, opts) do
    opts
    |> Keyword.put_new(:workspace_root, context.workspace_root)
    |> Keyword.put_new_lazy(:capacity_policy, fn -> factory_policy(context) end)
  end

  defp ticket_base_prompt(context, run, stage, base_sha, opts) do
    prepared = if is_map(opts[:blocked_resume]), do: {:ok, opts[:blocked_resume]}, else: recover_prepared_blocked_resume(context.store, run, stage)

    with {:ok, resume} <- prepared, do: ticket_base_prompt(context, run, stage, base_sha, opts, resume)
  end

  defp ticket_base_prompt(context, run, stage, base_sha, opts, %{"operational_recovery_key" => "TCAP-" <> _} = resume) do
    with {:ok, packet} <- TicketCapabilityRecovery.retained_packet(context.store, run, base_sha, resume),
         do: launch_prompt(context.store, run, stage, packet, Keyword.put(opts, :blocked_resume, resume))
  end

  defp ticket_base_prompt(context, run, stage, base_sha, opts, _resume) do
    with {:ok, packet} <- TicketWorkerRunner.packet(context.store, run["run_id"], stage.role, base_sha),
         do: launch_prompt(context.store, run, stage, packet, opts)
  end

  defp launch_ticket_stage_task(context, run, opts, stage, base_sha, authorization, prompt, blocked_resume) do
    launch_opts =
      Keyword.merge(opts,
        authorization: authorization,
        task_key: stage.key,
        stage: run["state"],
        role: stage.role,
        model_policy: context.factory.models,
        risk: run["risk"],
        risk_signals: decode_json(run["risk_signals_json"], []),
        project_id: nil,
        project_root: run["repo_path"],
        recipient: context.recipient,
        thread_name: task_name(run["issue_key"], stage.role),
        review_base_sha: base_sha,
        expected_sha: run["candidate_sha"] || base_sha,
        resume_terminal: stage.role == "feature-writer"
      )

    launch_opts = apply_resume_launch_options(launch_opts, blocked_resume, prompt, run, base_sha)

    with {:ok, launch_opts} <- capability_launch_options(context, prompt, launch_opts) do
      launch_prepared_ticket_stage(context, run, prompt, stage, launch_opts)
    end
  end

  defp capability_launch_options(context, prompt, opts) do
    case opts[:blocked_resume] do
      %{"operational_recovery_key" => "TCAP-" <> _} = resume ->
        opts = Keyword.put(opts, :workspace, controller_workspace(context))

        with {:ok, checked} <- TicketCapabilityRecovery.prepare(context.store, resume["request_key"], context.factory, Keyword.put(opts, :capability_prompt, prompt)) do
          {:ok, Keyword.put(opts, :blocked_resume, Map.merge(resume, checked))}
        end

      _ ->
        {:ok, opts}
    end
  end

  defp launch_prepared_ticket_stage(context, run, prompt, stage, launch_opts) do
    case TaskLauncher.launch(
           context.store,
           context.task_supervisor,
           run,
           issue_from_snapshot(decode_json!(run["snapshot_json"])),
           run["worktree"],
           prompt,
           ReviewProtocol.schema_json(prompt, StageSchemas.for_stage(stage.schema)),
           launch_opts
         ) do
      {:ok, launch} -> {:ok, %{status: "LAUNCHED", launch: launch}}
      {:already_running, task} -> {:ok, %{status: "RUNNING", task: task}}
      {:already_terminal, task} -> {:ok, %{status: "RECOVERED", task: task}}
      error -> error
    end
  end

  defp apply_resume_launch_options(launch_opts, %{kind: :blocked} = resume, prompt, run, base_sha) do
    Keyword.merge(launch_opts,
      blocked_resume: resume,
      blocked_resume_prompt: prompt,
      expected_sha: resume["checkout_head_sha"] || run["candidate_sha"] || base_sha
    )
  end

  defp apply_resume_launch_options(launch_opts, %{kind: :ready} = resume, _prompt, _run, _base_sha) do
    Keyword.put(launch_opts, :ready_rework, resume)
  end

  defp apply_resume_launch_options(launch_opts, %{kind: :failed_turn, receipt: receipt}, _prompt, _run, _base_sha),
    do: Keyword.put(launch_opts, :failed_turn_recovery, receipt)

  defp apply_resume_launch_options(launch_opts, _resume, _prompt, _run, _base_sha), do: launch_opts

  defp launch_prompt(store, run, stage, base_prompt, opts) do
    case Keyword.get(opts, :blocked_resume) do
      nil ->
        launch_prompt_without_resume(store, run, stage, base_prompt, opts)

      resume ->
        with {:ok, prompt, _} <- blocked_resume_prompt(store, run, stage, base_prompt, resume) do
          {:ok, prompt, Map.put(resume, :kind, :blocked)}
        end
    end
  end

  defp launch_prompt_without_resume(store, run, stage, base_prompt, opts) do
    case SymphonyElixir.Factory.FailedTurnRecovery.prepared(store, run["run_id"], base_prompt) do
      {:ok, receipt} -> {:ok, receipt["prompt"], %{kind: :failed_turn, receipt: receipt}}
      {:error, _} = error -> error
      :none -> launch_prompt_without_failed_recovery(store, run, stage, base_prompt, opts)
    end
  end

  defp launch_prompt_without_failed_recovery(store, run, stage, base_prompt, opts) do
    case recover_prepared_ready_rework(store, run, stage, base_prompt) do
      {:ok, nil} -> launch_prompt_after_ready_rework(store, run, stage, base_prompt, opts)
      {:ok, prepared} -> {:ok, prepared.prompt, prepared}
      {:error, _} = error -> error
    end
  end

  defp launch_prompt_after_ready_rework(store, run, stage, base_prompt, opts) do
    case recover_prepared_blocked_resume(store, run, stage) do
      {:ok, nil} -> {:ok, base_prompt, nil}
      {:ok, resume} -> launch_prompt(store, run, stage, base_prompt, Keyword.put(opts, :blocked_resume, resume))
      {:error, _} = error -> error
    end
  end

  defp recover_prepared_ready_rework(store, %{"state" => "REVIEW_WRITING"} = run, %{role: "feature-writer"}, base_prompt) do
    rows = Store.query!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status = 'APPLIED' ORDER BY updated_at DESC", [run["run_id"]]).rows

    Enum.reduce_while(rows, {:ok, nil}, fn [key], acc ->
      recover_prepared_ready_rework_row(store, run, base_prompt, key, acc)
    end)
  end

  defp recover_prepared_ready_rework(_store, _run, _stage, _base_prompt), do: {:ok, nil}

  defp recover_prepared_ready_rework_row(store, run, base_prompt, key, _acc) do
    case TicketChatCommands.validate_ready_rework_replay(store, key) do
      {:ok, %{receipt: receipt, input: input}} ->
        if receipt["candidate_sha"] == run["candidate_sha"],
          do: recover_prepared_ready_rework_evidence(store, run, base_prompt, key, receipt, input),
          else: {:cont, {:ok, nil}}

      _ ->
        {:cont, {:ok, nil}}
    end
  end

  defp recover_prepared_ready_rework_evidence(store, run, base_prompt, key, receipt, input) do
    case WorkerEvidence.get(store, receipt["request_key"]) do
      {:ok, evidence} ->
        recover_prepared_ready_rework_status(run, base_prompt, key, input, evidence)

      _ ->
        {:cont, {:ok, nil}}
    end
  end

  defp recover_prepared_ready_rework_status(run, base_prompt, key, input, evidence) do
    cond do
      evidence["run_id"] != run["run_id"] ->
        {:cont, {:ok, nil}}

      evidence["status"] == "RESERVED" ->
        prompt = TicketWorkerRunner.ready_rework_packet(base_prompt, key, input["body"])

        prepared = %{
          kind: :ready,
          prepared: true,
          command_key: key,
          input_key: input["input_key"],
          input_body: input["body"],
          prompt: prompt
        }

        {:halt, {:ok, prepared}}

      evidence["status"] in ~w(START_SENT RESULT_RECORDED RECONCILE_REQUIRED) ->
        {:halt, {:error, {:ready_rework_attempt_reconciliation_required, evidence["request_key"]}}}

      true ->
        {:cont, {:ok, nil}}
    end
  end

  defp blocked_resume_prompt(store, run, %{role: "feature-writer"}, base_prompt, %{"operational_recovery_key" => "TCAP-" <> _ = key} = resume) do
    disposition = current_blocked_writer_disposition(store, run["run_id"], run["run_id"] <> ":feature-writer")

    with true <- resume_disposition_matches?(disposition, resume) or {:error, :ticket_blocked_rework_not_current} do
      prompt =
        Jason.encode!(%{
          "base_packet" => Jason.decode!(base_prompt),
          "controller_infrastructure_recovery" => key,
          "recovery_instruction" => TicketCapabilityRecovery.body(),
          "blocked_writer_context" => disposition
        })

      {:ok, prompt, resume}
    end
  end

  defp blocked_resume_prompt(store, run, %{role: "feature-writer"}, base_prompt, %{"operational_recovery_key" => key} = resume) when is_binary(key) do
    disposition = current_blocked_writer_disposition(store, run["run_id"], run["run_id"] <> ":feature-writer")

    with true <- resume_disposition_matches?(disposition, resume) or {:error, :ticket_blocked_rework_not_current} do
      prompt =
        Jason.encode!(%{
          "base_packet" => Jason.decode!(base_prompt),
          "controller_infrastructure_recovery" => key,
          "recovery_instruction" => TicketInfrastructureRecovery.body(),
          "blocked_writer_context" => disposition
        })

      {:ok, prompt, resume}
    end
  end

  defp blocked_resume_prompt(store, run, %{role: "feature-writer"}, base_prompt, resume) do
    with true <- is_map(resume) or {:error, :ticket_blocked_rework_not_current},
         input when is_map(input) <- Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [resume["input_key"]]),
         disposition when is_map(disposition) <- current_blocked_writer_disposition(store, run["run_id"], run["run_id"] <> ":feature-writer"),
         true <- resume_disposition_matches?(disposition, resume) or {:error, :ticket_blocked_rework_not_current} do
      prompt = TicketWorkerRunner.blocked_resume_packet(base_prompt, input["body"], disposition)
      {:ok, prompt, resume}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_blocked_rework_not_current}
    end
  end

  defp blocked_resume_prompt(_store, _run, _stage, _base_prompt, _resume), do: {:error, :blocked_rework_requires_feature_writer}

  defp resume_disposition_matches?(disposition, resume),
    do: is_map(disposition) and disposition["disposition_key"] == resume["disposition_key"] and disposition["request_key"] == resume["request_key"]

  defp recover_prepared_blocked_resume(store, run, %{role: "feature-writer", key: task_key}) do
    pending = WorkerEvidence.pending(store, run["run_id"]) |> Enum.filter(&(&1["task_key"] == task_key and &1["status"] == "RESERVED"))

    case pending do
      [attempt] ->
        case blocked_transfer_for_reserved_attempt(store, run["run_id"], task_key, attempt["request_key"]) do
          {:ok, nil} ->
            {:ok, nil}

          {:ok, transfer} ->
            recover_transferred_resume(store, run, attempt, transfer)

          {:error, _} = error ->
            error
        end

      [] ->
        {:ok, nil}

      _ ->
        {:error, :worker_attempt_reconciliation_required}
    end
  end

  defp recover_prepared_blocked_resume(_store, _run, _stage), do: {:ok, nil}

  defp recover_transferred_resume(store, _run, attempt, %{"operational_recovery_key" => "TCAP-" <> _} = transfer),
    do: TicketCapabilityRecovery.prepared(store, attempt, transfer)

  defp recover_transferred_resume(store, _run, attempt, %{"operational_recovery_key" => key} = transfer) when is_binary(key),
    do: TicketInfrastructureRecovery.prepared(store, attempt, transfer)

  defp recover_transferred_resume(store, run, attempt, transfer) do
    command = prepared_resume_command(store, run["run_id"], attempt["request_key"])
    recover_prepared_blocked_resume(store, run, attempt, command, transfer)
  end

  defp blocked_transfer_for_reserved_attempt(store, run_id, task_key, request_key) do
    %{columns: columns, rows: rows} =
      Store.query!(
        store,
        "SELECT * FROM workspace_access WHERE run_id = ? AND task_key = ? AND released_at IS NOT NULL",
        [run_id, task_key]
      )

    transfers =
      rows
      |> Enum.map(&Map.new(Enum.zip(columns, &1)))
      |> Enum.flat_map(&transfer_receipt_for(&1, request_key))

    case transfers do
      [] -> {:ok, nil}
      [transfer] -> {:ok, transfer}
      _ -> {:error, :blocked_resume_transfer_claim_ambiguous}
    end
  end

  defp transfer_receipt_for(access, request_key) do
    case Jason.decode(access["release_receipt_json"] || "null") do
      {:ok, %{"kind" => "BLOCKED_SOURCE_TRANSFER", "new_request_key" => ^request_key} = transfer} -> [transfer]
      _ -> []
    end
  end

  defp prepared_resume_command(store, run_id, request_key) do
    %{columns: columns, rows: rows} =
      Store.query!(store, "SELECT * FROM ticket_chat_commands WHERE run_id = ? AND status = 'APPLIED' ORDER BY updated_at DESC", [run_id])

    rows
    |> Enum.map(&Map.new(Enum.zip(columns, &1)))
    |> Enum.find(fn command -> applied_resume_command?(command, request_key) end)
  end

  defp applied_resume_command?(command, request_key) do
    case Jason.decode(command["application_receipt_json"] || "null") do
      {:ok, %{"kind" => "BLOCKED_WRITER_RESUMED", "request_key" => ^request_key}} -> true
      _ -> false
    end
  end

  defp recover_prepared_blocked_resume(_store, _run, _attempt, nil, _transfer), do: {:error, :blocked_resume_preparation_unproven}

  defp recover_prepared_blocked_resume(store, run, attempt, command, transfer) do
    with {:ok, receipt} <- Jason.decode(command["application_receipt_json"]),
         true <- prepared_receipt_matches?(receipt, attempt) or {:error, :blocked_resume_preparation_mismatch},
         true <-
           transfer_claim_matches?(transfer, command, receipt, attempt) or
             {:error, :blocked_resume_transfer_claim_mismatch},
         {:ok, old} <- WorkerEvidence.get(store, receipt["prior_request_key"]),
         true <-
           WorkerEvidence.superseded_blocked_attempt?(store, old) or
             {:error, :blocked_resume_supersession_unproven} do
      prepared_resume_descriptor(store, run, attempt, command, receipt, old)
    else
      {:error, _} = error -> error
    end
  end

  defp transfer_claim_matches?(transfer, command, receipt, attempt) do
    transfer["command_key"] == command["command_key"] and transfer["input_key"] == command["input_key"] and
      transfer["old_request_key"] == receipt["prior_request_key"] and transfer["new_request_key"] == attempt["request_key"] and
      transfer["new_reservation_key"] == receipt["reservation_key"] and transfer["disposition_key"] == receipt["disposition_key"] and
      transfer["output_sha256"] == receipt["output_sha256"] and
      transfer["checkout_head_sha"] == receipt["checkout_head_sha"]
  end

  defp prepared_receipt_matches?(receipt, attempt),
    do: receipt["reservation_key"] == attempt["reservation_key"] and receipt["request_key"] == attempt["request_key"]

  defp prepared_resume_descriptor(store, run, attempt, command, receipt, old) do
    input = Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    disposition = current_blocked_writer_disposition(store, run["run_id"], attempt["task_key"])

    if is_map(input) and is_map(disposition) and disposition["disposition_key"] == receipt["disposition_key"] do
      {:ok,
       %{
         "command_key" => command["command_key"],
         "input_key" => input["input_key"],
         "request_key" => old["request_key"],
         "disposition_key" => receipt["disposition_key"],
         "thread_id" => old["thread_id"],
         "prepared" => true,
         "prepared_request_key" => attempt["request_key"],
         "prepared_reservation_key" => attempt["reservation_key"],
         "prepared_reservation_generation" => receipt["reservation_generation"],
         "amendment_command_key" => receipt["amendment_command_key"],
         "checkout_head_sha" => receipt["checkout_head_sha"]
       }}
    else
      {:error, :blocked_resume_preparation_unproven}
    end
  end

  defp ticket_stage(%{"state" => "PLANNING"} = run, _factory, _store),
    do: {:ok, %{key: run["run_id"] <> ":feature-planner", role: "feature-planner", schema: :feature_planner}}

  defp ticket_stage(%{"state" => state} = run, factory, store) when state in ~w(WRITING REPAIRING REVIEW_WRITING) do
    confirmation = TicketCompletionConfirmation.authorization(store, run, factory)

    cond do
      run["implementation_iteration"] < TicketVerifierRepair.implementation_limit(store, run, factory) ->
        {:ok, %{key: run["run_id"] <> ":feature-writer", role: "feature-writer", schema: :native_feature_writer}}

      is_map(confirmation) ->
        {:ok, %{key: run["run_id"] <> ":feature-writer", role: "feature-writer", schema: :native_feature_writer, completion_confirmation: confirmation}}

      true ->
        {:error, :implementation_iteration_limit}
    end
  end

  defp ticket_stage(%{"state" => "VERIFYING"} = run, _factory, _store),
    do: {:ok, %{key: "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}", role: "change-verifier", schema: :change_verifier}}

  defp ticket_stage(_run, _factory, _store), do: {:error, :ticket_role_stage_not_admitted}

  defp ticket_authorization(context, run, opts, prior \\ nil) do
    reader = Keyword.get(opts, :jira_reader, JiraMcpReader)

    read_opts = [
      workspace: controller_workspace(context),
      store: context.store,
      connector: Map.get(context, :jira_connector) || JiraMcpConnector,
      app_server: Map.get(context, :jira_app_server, AppServer)
    ]

    with {:ok, snapshot} <- reader.issue(run["issue_key"], read_opts) do
      observed_at = DateTime.utc_now()
      ticket_opts = Keyword.put(Map.get(context, :ticket_options, []), :workspace_root, context.workspace_root)

      if prior,
        do: TicketWorkerRunner.refresh_delivery_authorization(run, snapshot, observed_at, prior),
        else: TicketWorkerRunner.delivery_authorization(context.store, run, snapshot, observed_at, ticket_opts)
    end
  end

  defp adopt_ticket_stage(context, key) do
    case current_amendment_blocked_receipt(context.store, key) do
      {:ok, receipt} ->
        adopted_amendment_blocked_result(context, key, receipt)

      :not_current ->
        case blocked_writer_attempt(context.store, key) do
          {:ok, _evidence, _task} -> adopt_blocked_writer(context, key)
          :not_blocked -> adopt_recorded_ticket_stage(context, key)
        end
    end
  end

  defp current_amendment_blocked_receipt(store, key) do
    run_id = Store.one!(store, "SELECT run_id FROM worker_evidence WHERE request_key = ?", [key])["run_id"]

    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, %{receipt: receipt}} <- TicketContractAmendment.blocked_predecessor_for_installed_run(store, run),
         {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, evidence} <- Jason.decode(predecessor["evidence_json"]),
         true <- evidence["request_key"] == key do
      {:ok, receipt}
    else
      _ -> :not_current
    end
  end

  defp adopt_blocked_writer(context, key) do
    case TicketContractAmendment.blocked_predecessor_for_request(context.store, key) do
      {:ok, receipt} -> adopted_amendment_blocked_result(context, key, receipt)
      {:error, :blocked_amendment_predecessor_not_found} -> adopt_unamended_blocked_writer(context, key)
    end
  end

  defp adopt_unamended_blocked_writer(context, key) do
    with {:ok, completed} <- WorkerEvidence.completed_result(context.store, key),
         %{"role" => "feature-writer"} = task <- completed.task,
         %{"status" => "BLOCKED"} = output <- completed.output do
      record_ticket_writer_blocked(context, key, completed, task, output)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ticket_writer_block_disposition_not_current}
    end
  end

  defp adopted_amendment_blocked_result(context, key, receipt) do
    with :ok <- WorkspaceAccess.validate_blocked_amendment_predecessor(context.store, receipt),
         {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, disposition} <- Jason.decode(predecessor["disposition_json"]),
         {:ok, run} <- RunLedger.get(context.store, receipt["run_id"]),
         true <- disposition["request_key"] == key and run["state"] == "WRITING" do
      {:ok,
       %{
         status: "BLOCKED",
         run: run,
         request_key: key,
         blockers: disposition["blockers"],
         next_action: disposition["next_action"],
         model_invoked: false
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :blocked_amendment_predecessor_unproven}
    end
  end

  defp adopt_recorded_ticket_stage(context, key) do
    with {:ok, adopted} <- TicketWorkerRunner.adoption(context.store, key) do
      # Exact checkout revalidation can scan a monorepo multiple times before atomic release.
      case Exqlite.transaction(context.store, &ticket_adoption_transaction(%{context | store: &1}, adopted, key), timeout: 60_000) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp blocked_writer_attempt(store, key) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         {:ok, %{"status" => "BLOCKED"}} <- Jason.decode(evidence["output_json"] || "null"),
         true <- task["role"] == "feature-writer" do
      {:ok, evidence, task}
    else
      _ -> :not_blocked
    end
  end

  defp record_ticket_writer_blocked(context, key, completed, task, output) do
    run = completed.run
    evidence = completed.evidence
    binding = completed.binding
    raw_output = evidence["output_json"]
    output_sha = evidence["output_sha256"]
    disposition_key = digest(Jason.encode!([run["run_id"], key, output_sha]))
    next_action = "Review the recorded blockers, then explicitly authorize a separate resume; no source work will resume automatically."

    payload = %{
      "disposition_key" => disposition_key,
      "request_key" => key,
      "task_key" => task["task_key"],
      "output_json" => raw_output,
      "output_sha256" => output_sha,
      "blockers" => output["blockers"],
      "next_action" => next_action,
      "run_binding" => Map.take(run, ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch)),
      "task" => Map.take(task, ~w(task_key role stage status thread_id turn_id updated_at)),
      "reservation_key" => evidence["reservation_key"],
      "reservation_generation" => binding["reservation_generation"],
      "task_status" => task["status"]
    }

    # ticket_step holds the per-run lock; the immediate transaction serializes disposition lookup and insertion.
    transaction_result =
      Exqlite.transaction(context.store, fn tx ->
        record_ticket_writer_blocked_transaction(tx, key, completed, payload, next_action)
        |> transaction_result(tx)
      end)

    case transaction_result do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction_result({:error, reason}, transaction), do: Exqlite.rollback(transaction, reason)
  defp transaction_result(result, _transaction), do: result

  defp record_ticket_writer_blocked_transaction(tx, key, completed, payload, next_action) do
    with {:ok, run} <- RunLedger.get(tx, completed.run["run_id"]),
         true <- run == completed.run or {:error, :ticket_writer_block_binding_changed},
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, _} <- TicketChat.ready_for_run(tx, run["run_id"]),
         {:ok, task} <- TaskLedger.get(tx, completed.task["task_key"]),
         true <- task_binding_current?(task, completed.task, run) or {:error, :ticket_writer_block_task_changed},
         {:ok, evidence} <- WorkerEvidence.get(tx, key),
         :ok <- validate_blocked_evidence(tx, evidence, completed.evidence),
         {:ok, access} <- WorkspaceAccess.get(tx, evidence["reservation_key"]),
         true <- access == completed.access or {:error, :ticket_writer_block_reservation_changed},
         {:ok, _} <- WorkspaceAccess.validate(tx, access["reservation_key"], payload["reservation_generation"]),
         result <- store_ticket_writer_block_event(tx, run["run_id"], payload) do
      case result do
        :ok ->
          {:ok,
           %{
             status: "BLOCKED",
             run: run,
             request_key: key,
             blockers: payload["blockers"],
             next_action: next_action,
             model_invoked: false
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp task_binding_current?(task, expected, run), do: task == expected and task["stage"] == run["state"]

  defp validate_blocked_evidence(store, evidence, expected) do
    if evidence == expected and WorkerEvidence.owner_stopped?(store, evidence) do
      :ok
    else
      {:error, :ticket_writer_block_evidence_changed}
    end
  end

  defp store_ticket_writer_block_event(store, run_id, payload) do
    raw = Jason.encode!(payload)

    existing =
      Store.query!(store, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'", [run_id]).rows
      |> Enum.map(fn [value] -> value end)
      |> Enum.filter(fn value ->
        case Jason.decode(value) do
          {:ok, %{"disposition_key" => key}} -> key == payload["disposition_key"]
          _ -> false
        end
      end)

    case existing do
      [] ->
        Store.query!(store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('TICKET_NATIVE_WRITER_BLOCKED', ?, ?, ?)", [
          run_id,
          raw,
          DateTime.utc_now() |> DateTime.to_iso8601()
        ])

        :ok

      [^raw] ->
        :ok

      _ ->
        {:error, :ticket_writer_block_disposition_conflict}
    end
  end

  defp ticket_adoption_transaction(context, adopted, key) do
    tx = context.store

    with {:ok, run} <- RunLedger.get(tx, adopted.run["run_id"]),
         true <- run == adopted.run or {:error, :ticket_adoption_run_changed},
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, _} <- TicketChat.ready_for_run(tx, run["run_id"]),
         {:ok, task} <- WorkerEvidence.adopt_completed(tx, key),
         :ok <- TicketWorkerRunner.admitted_stage(run, task["role"]),
         true <- task["stage"] == run["state"] or {:error, :ticket_worker_stage_changed},
         :ok <- ticket_role_transition(context, run, task, adopted.output, key),
         {:ok, _} <- TaskLedger.update(tx, task["task_key"], %{status: "CONSUMED"}),
         {:ok, _} <- WorkerEvidence.consume(tx, key),
         {:ok, current} <- RunLedger.get(tx, run["run_id"]) do
      {:ok, %{status: "ADOPTED", run: current, request_key: key}}
    else
      {:error, reason} -> Exqlite.rollback(tx, reason)
    end
  end

  defp ticket_role_transition(_context, run, %{"status" => "CONSUMED"}, _output, _request_key) do
    if run["state"] in ~w(PLANNING WRITING REPAIRING REVIEW_WRITING VERIFYING), do: {:error, :ticket_consumed_task_without_stage_adoption}, else: :ok
  end

  defp ticket_role_transition(context, %{"state" => "PLANNING"} = run, %{"role" => "feature-planner"}, %{"status" => "PLANNED", "plan_markdown" => plan}, _request_key) do
    {:ok, _} = RunLedger.update(context.store, run["run_id"], %{state: "ADMITTING_WRITER", plan_markdown: plan})
    :ok
  end

  defp ticket_role_transition(context, %{"state" => "VERIFYING"} = run, %{"role" => "change-verifier"} = task, output, request_key) do
    policy = ticket_review_policy(context, run, task, output, request_key)

    result =
      case policy do
        {:ok, {:stop, stop}} -> {:policy_stop, stop}
        {:ok, _} -> consume_change_verifier_output(context, run, ReviewProtocol.projection(output), %{events: []})
        error -> error
      end

    case result do
      {:policy_stop, stop} ->
        record_ticket_verifier_terminal(context.store, run, request_key, {:verification_policy_stopped, ReviewProtocol.findings(output)}, stop)

      {:ok, _} ->
        :ok

      {:error, {kind, _findings} = reason} when kind in [:verification_blocked, :code_repair_limit] ->
        record_ticket_verifier_terminal(context.store, run, request_key, reason)

      error ->
        error
    end
  end

  defp ticket_role_transition(context, %{"state" => state} = run, %{"role" => "feature-writer"} = task, %{"status" => status}, request_key)
       when state in ~w(WRITING REPAIRING REVIEW_WRITING) and status in ~w(CONTINUE COMPLETE) do
    rework? = ready_rework_for_request?(context.store, run, task, request_key)
    preflight? = ci_preflight?(route_for_run(context, run)) and not review_rework?(run) and not rework?
    {:ok, _} = write_native_writer_slice(context.store, run, task["task_key"], status, run["candidate_sha"], preflight?)
    :ok
  end

  defp ticket_role_transition(_context, _run, _task, _output, _request_key), do: {:error, :ticket_role_output_not_adoptable}

  defp ticket_review_policy(context, run, task, output, request_key) do
    ReviewProtocol.apply_policy(context.store, run, task, output, request_key, run["code_repair_round"] + 1 <= context.factory.maximum_code_repair_rounds)
  end

  defp record_ticket_verifier_terminal(store, run, request_key, reason, policy \\ nil) do
    with {:ok, evidence} <- WorkerEvidence.get(store, request_key),
         {:ok, _} <- RunLedger.update(store, run["run_id"], %{state: "FAILED", failure_code: failure_code(reason), last_error: inspect(reason)}) do
      receipt = %{
        "version" => if(policy, do: 2, else: 1),
        "kind" => if(policy, do: "TICKET_VERIFIER_TERMINAL_V2", else: "TICKET_VERIFIER_TERMINAL_V1"),
        "request_key" => request_key,
        "task_key" => evidence["task_key"],
        "binding_sha256" => evidence["binding_sha256"],
        "output_sha256" => evidence["output_sha256"],
        "reason" => Atom.to_string(elem(reason, 0)),
        "prior_run" => Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256 verifier_round code_repair_round implementation_iteration))
      }

      receipt = if policy, do: Map.put(receipt, "review_policy", policy), else: receipt

      Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,?,?,?)", [
        DateTime.to_iso8601(DateTime.utc_now()),
        "TICKET_NATIVE_VERIFIER_TERMINAL",
        run["run_id"],
        Jason.encode!(receipt)
      ])

      :ok
    end
  end

  @doc "Runs one serialized reconciliation and dispatch tick."
  @spec tick(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def tick(context, opts \\ []) do
    context = dependencies(context, opts)

    with :ok <- validate_stored_execution_modes(context.store) do
      run_tick(context)
    end
  end

  @doc "Reads back at most one issued ticket operation; never dispatches or prepares replacement work."
  @spec reconcile_ticket_jira(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_ticket_jira(context, opts \\ []) do
    context = dependencies(context, opts)

    case reconcile_ticket_jira_context(context) do
      {:ok, result} -> {:ok, Map.delete(result, :recovery_run_id)}
      error -> error
    end
  end

  defp reconcile_ticket_jira_context(context, mode \\ :readback) do
    acc = %{launches: [], events: [], routing_required: []}

    with :ok <- validate_stored_execution_modes(context.store) do
      run =
        Store.one!(
          context.store,
          """
          WITH recovery AS (
            SELECT operation.run_id, operation.operation, operation.operation_key, operation.created_at
            FROM ticket_jira_effects AS operation JOIN runs ON runs.run_id = operation.run_id
            LEFT JOIN workspace_access AS access ON access.reservation_key = operation.operation_key
            WHERE ((operation.operation = 'REVIEW_READY' AND runs.state = 'MR_CREATING')
                OR (operation.operation = 'START_IMPLEMENTATION' AND runs.state = 'ADMITTING_WRITER'))
              AND access.released_at IS NULL
              AND operation.phase IN ('FIRST_UNCERTAIN','SECOND_PENDING','SECOND_UNCERTAIN','COMPLETE')
              AND NOT (operation.phase = 'SECOND_PENDING'
                AND runs.issue_key IN (SELECT value FROM json_each(?)))
            UNION ALL
            SELECT intent.run_id, 'CHECKOUT',
              'ticket-checkout:' || intent.run_id || ':' || intent.binding_sha256 || ':' || intent.owner_nonce,
              runs.created_at
            FROM ticket_checkout_intents AS intent JOIN runs ON runs.run_id = intent.run_id
            WHERE runs.state = 'ADMITTING_WRITER' AND runs.worktree IS NULL
              AND intent.phase IN ('MUTATING_UNCERTAIN','RECONCILE_REQUIRED') AND intent.owner_nonce IS NOT NULL
            UNION ALL
            SELECT push.run_id, 'PUSH',
              'ticket-push:' || json_extract(push.envelope, '$.binding_sha256') || ':' || json_extract(push.envelope, '$.owner_nonce'),
              push.created_at
            FROM (SELECT run_id, created_at,
              CASE WHEN json_valid(candidate_handoff) THEN candidate_handoff ELSE '{}' END AS envelope
              FROM runs WHERE state IN ('PUSHING','CI_PUSHING')) AS push
            WHERE json_type(push.envelope, '$.version') = 'integer' AND json_extract(push.envelope, '$.version') = 1
              AND json_extract(push.envelope, '$.kind') = 'TICKET_PUSH'
              AND json_extract(push.envelope, '$.phase') = 'PUSH_UNCERTAIN'
              AND json_type(push.envelope, '$.binding_sha256') = 'text' AND length(json_extract(push.envelope, '$.binding_sha256')) > 0
              AND json_type(push.envelope, '$.owner_nonce') = 'text' AND length(json_extract(push.envelope, '$.owner_nonce')) > 0
            UNION ALL
            SELECT runs.run_id, 'MR_RESULT', request.request_key, request.created_at
            FROM (SELECT *, CASE WHEN json_valid(metadata_json) THEN metadata_json ELSE '{}' END AS metadata
              FROM desktop_requests WHERE status = 'SUCCEEDED' AND target_kind = 'CONTROLLER' AND action = 'FOLLOWUP') AS request
            JOIN runs ON runs.run_id = json_extract(request.metadata, '$.delivery_operation.run_id')
            JOIN ticket_chat_runs AS link ON link.run_id = runs.run_id
            JOIN ticket_chats AS chat ON chat.chat_key = link.chat_key
            WHERE runs.state IN ('MR_CREATING','CI_MR_CREATING')
              AND runs.mr_iid IS NULL AND runs.mr_url IS NULL AND runs.mr_state IS NULL
              AND request.target_key = chat.scope_key
              AND json_type(request.metadata, '$.delivery_operation') = 'object'
              AND json_type(request.metadata, '$.delivery_operation.version') = 'integer'
              AND json_extract(request.metadata, '$.delivery_operation.version') IN (1, 2)
              AND json_extract(request.metadata, '$.delivery_operation.operation') = 'CREATE_OR_REUSE_DRAFT_MR'
              AND json_extract(request.metadata, '$.delivery_operation.issue_key') = runs.issue_key
              AND json_extract(request.metadata, '$.delivery_operation.stage') = runs.state
              AND json_extract(request.metadata, '$.delivery_operation.candidate_sha') = runs.candidate_sha
              AND json_extract(request.metadata, '$.delivery_operation.contract_sha256') = runs.contract_sha256
              AND json_type(request.metadata, '$.delivery_operation.spec_revision') = 'integer'
              AND json_extract(request.metadata, '$.delivery_operation.spec_revision') = runs.spec_revision
              AND json_type(request.metadata, '$.delivery_operation.ci_preflight') =
                CASE WHEN runs.state = 'CI_MR_CREATING' THEN 'true' ELSE 'false' END
              AND json_extract(request.metadata, '$.delivery_operation.scope') = chat.scope_key
          )
          SELECT runs.*, recovery.operation AS recovery_operation, recovery.operation_key AS recovery_key
          FROM recovery JOIN runs ON runs.run_id = recovery.run_id
          JOIN ticket_chat_runs AS link ON link.run_id = runs.run_id
          JOIN ticket_chats AS chat ON chat.chat_key = link.chat_key
          WHERE runs.execution_mode = 'TICKET_SUPERVISOR_V1' AND chat.scope_key = ?
          ORDER BY (SELECT COALESCE(MAX(events.id), 0) FROM events
            WHERE events.run_id = runs.run_id AND events.event_type = 'TICKET_RECOVERY_ATTEMPT'
              AND json_extract(CASE WHEN json_valid(events.payload_json) THEN events.payload_json ELSE '{}' END,
                '$.operation_key') = recovery.operation_key),
            recovery.created_at, recovery.operation_key LIMIT 1
          """,
          [Jason.encode!(normal_ticket_advance_keys(context, mode)), context.factory.scope]
        )

      case run do
        nil ->
          {:ok, acc}

        selected ->
          reconcile_selected_ticket(Map.put(context, :ordinary_rejection_dispatch, mode == :before_dispatch), selected, acc)
      end
    end
  end

  defp normal_ticket_advance_keys(context, :before_dispatch) do
    with %{enabled: true, task_transport: "desktop_broker"} <- context.factory,
         %{"enabled" => true} = policy <- Map.get(context.factory, :ticket_supervisor),
         %{"status" => "ACTIVE"} <- Control.status(context.store, context.factory.scope) do
      Store.query!(
        context.store,
        "SELECT DISTINCT runs.issue_key FROM runs JOIN ticket_chat_runs AS link ON link.run_id = runs.run_id JOIN ticket_chats AS chat ON chat.chat_key = link.chat_key WHERE runs.execution_mode = 'TICKET_SUPERVISOR_V1' AND chat.scope_key = ?",
        [context.factory.scope]
      )
      |> then(fn result -> Enum.map(result.rows, fn [key] -> key end) end)
      |> Enum.filter(&Policy.ticket_selected?(policy, &1))
    else
      _ -> []
    end
  end

  defp normal_ticket_advance_keys(_context, _mode), do: []

  defp reconcile_selected_ticket(context, selected, acc) do
    with {:ok, result} <- reconcile_ticket_jira_run(context, selected, acc) do
      {:ok, Map.put(result, :recovery_run_id, selected["run_id"])}
    end
  end

  defp reconcile_ticket_jira_run(context, run, acc) do
    lock = {{__MODULE__, :ticket_stage, run["run_id"]}, self()}
    record_ticket_recovery_attempt(context.store, run)

    result =
      :global.trans(lock, fn ->
        with {:ok, current} <- RunLedger.get(context.store, run["run_id"]),
             true <- current == Map.drop(run, ~w(recovery_operation recovery_key)) or {:error, :ticket_recovery_run_changed},
             :ok <- ticket_recovery_operation(context.store, current, run),
             {:ok, chat} <- TicketChat.ready_for_run(context.store, run["run_id"]),
             true <- chat["scope_key"] == context.factory.scope or {:error, :ticket_recovery_scope_changed} do
          options =
            context.ticket_options
            |> Keyword.put(:workspace, controller_workspace(context))
            |> Keyword.put_new(:workspace_root, context.workspace_root)
            |> Keyword.put(:jira_reader, context.jira_reader)
            |> Keyword.put_new(:jira_connector, context.jira_connector || JiraMcpConnector)
            |> Keyword.put_new(:jira_app_server, context.jira_app_server)

          reconcile_jira_operation(context, run, options)
        end
      end)

    case result do
      {:ok, %{status: status}} ->
        record_ticket_recovery_outcome(context.store, run, "SUCCEEDED", status)
        {:ok, add_event(acc, run["issue_key"], "TICKET_" <> status, run["run_id"])}

      {:error, reason} ->
        record_ticket_recovery_outcome(context.store, run, "DEFERRED", ticket_deferral_code(reason, 3))
        {:ok, add_event(acc, run["issue_key"], "TICKET_DEFERRED", failure_code(reason))}

      :aborted ->
        {:error, :ticket_stage_lock_unavailable}
    end
  rescue
    error ->
      detail = failure_code({:ticket_step_exception, error.__struct__})
      record_ticket_recovery_outcome(context.store, run, "DEFERRED", detail)
      {:ok, add_event(acc, run["issue_key"], "TICKET_DEFERRED", detail)}
  end

  defp reconcile_jira_operation(context, %{"recovery_operation" => "START_IMPLEMENTATION"} = run, options),
    do: TicketJiraOperation.reconcile(context.store, run["run_id"], options)

  defp reconcile_jira_operation(context, %{"recovery_operation" => "REVIEW_READY"} = run, options),
    do: TicketJiraFinalization.reconcile(context.store, run["run_id"], context.factory, options)

  defp reconcile_jira_operation(context, %{"recovery_operation" => "CHECKOUT"} = run, options) do
    with {:ok, intent} <- TicketCheckout.get(context.store, run["run_id"]),
         true <- ticket_checkout_recovery_key(intent) == run["recovery_key"] or {:error, :ticket_recovery_operation_changed},
         {:ok, authorization} <- ticket_authorization(context, run, options) do
      pinned = intent |> pinned_checkout_opts(options) |> Keyword.put(:expected_intent, intent)
      TicketCheckout.reconcile(context.store, run["run_id"], authorization, pinned)
    end
  end

  defp reconcile_jira_operation(context, %{"recovery_operation" => "PUSH"} = run, options) do
    options =
      options
      |> Keyword.put(:ci_preflight_authorized, ci_preflight?(route_for_run(context, run)))
      |> Keyword.put(:expected_envelope, run["candidate_handoff"])

    with {:ok, authorization} <- ticket_authorization(context, run, options) do
      module = SymphonyElixir.Factory.TicketPushPreissuanceRejection

      if context[:ordinary_rejection_dispatch] == true and Map.get(context.factory.ticket_supervisor, "ci_repair") == "native_bounded_v1" and
           Policy.ticket_selected?(context.factory.ticket_supervisor, run["issue_key"]) and module.eligible?(run) do
        options = ticket_runtime_options(context, options) |> Keyword.put(:ordinary_controller_tick, true)
        module.rearm(context.store, run["run_id"], authorization, options)
      else
        TicketPush.reconcile(context.store, run["run_id"], authorization, options)
      end
    end
  end

  defp reconcile_jira_operation(context, %{"recovery_operation" => "MR_RESULT"} = run, options) do
    options =
      options
      |> Keyword.put(:ci_preflight_authorized, ci_preflight?(route_for_run(context, run)))
      |> Keyword.put(:ticket_mr_ephemeral_read, true)
      |> Keyword.put(:expected_request_key, run["recovery_key"])

    with {:ok, authorization} <- ticket_authorization(context, run, options) do
      TicketMrOperation.adopt_result(context.store, run["run_id"], authorization, context.factory, options)
    end
  end

  defp ticket_recovery_operation(store, current, %{"recovery_operation" => "CHECKOUT"} = selected) do
    with {:ok, intent} <- TicketCheckout.get(store, current["run_id"]),
         true <- intent["phase"] in ~w(MUTATING_UNCERTAIN RECONCILE_REQUIRED) or {:error, :ticket_recovery_operation_changed},
         key = ticket_checkout_recovery_key(intent),
         true <- key == selected["recovery_key"] or {:error, :ticket_recovery_operation_changed} do
      :ok
    end
  end

  defp ticket_recovery_operation(store, current, %{"recovery_operation" => "MR_RESULT"} = selected) do
    with {:ok, %{"status" => "SUCCEEDED", "target_kind" => "CONTROLLER", "action" => "FOLLOWUP"}} <-
           DesktopRequest.get(store, selected["recovery_key"]),
         true <- current["state"] in ~w(MR_CREATING CI_MR_CREATING) or {:error, :ticket_recovery_operation_changed} do
      :ok
    else
      _ -> {:error, :ticket_recovery_operation_changed}
    end
  end

  defp ticket_recovery_operation(_store, current, %{"recovery_operation" => "PUSH"} = selected) do
    with {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "PUSH_UNCERTAIN"} = intent} <- Jason.decode(current["candidate_handoff"]),
         key = Enum.join(["ticket-push", intent["binding_sha256"], intent["owner_nonce"]], ":"),
         true <- key == selected["recovery_key"] or {:error, :ticket_recovery_operation_changed} do
      :ok
    else
      _ -> {:error, :ticket_recovery_operation_changed}
    end
  end

  defp ticket_recovery_operation(store, current, selected) do
    case selected["recovery_operation"] do
      "REVIEW_READY" ->
        with {:ok, selection} <- TicketJiraJournal.select_review_operation(store, current["run_id"]),
             true <- selection.operation_key == selected["recovery_key"] or {:error, :ticket_recovery_operation_changed} do
          :ok
        else
          _ -> {:error, :ticket_recovery_operation_changed}
        end

      operation ->
        if TicketJiraJournal.identity_key(current, operation) == selected["recovery_key"],
          do: :ok,
          else: {:error, :ticket_recovery_operation_changed}
    end
  end

  defp ticket_checkout_recovery_key(intent),
    do: Enum.join(["ticket-checkout", intent["run_id"], intent["binding_sha256"], intent["owner_nonce"]], ":")

  defp record_ticket_recovery_attempt(store, run) do
    payload = Jason.encode!(%{operation_key: run["recovery_key"], operation: run["recovery_operation"]})

    Store.query!(store, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_RECOVERY_ATTEMPT', ?, ?)", [
      DateTime.to_iso8601(DateTime.utc_now()),
      run["run_id"],
      payload
    ])
  end

  defp record_ticket_recovery_outcome(store, run, status, reason) do
    payload = Jason.encode!(%{operation_key: run["recovery_key"], operation: run["recovery_operation"], status: status, reason: reason})
    previous = Store.one!(store, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_RECOVERY_OUTCOME' ORDER BY id DESC LIMIT 1", [run["run_id"]])

    unless previous && previous["payload_json"] == payload do
      Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_RECOVERY_OUTCOME',?,?)", [
        DateTime.to_iso8601(DateTime.utc_now()),
        run["run_id"],
        payload
      ])
    end
  end

  defp run_tick(context) do
    workspace = controller_workspace(context)
    File.mkdir_p!(workspace)

    if feedback_controller_in_flight?(context.store) do
      maybe_consume_review_feedback(context, workspace)

      if feedback_controller_in_flight?(context.store) do
        {:ok, %{launches: [], events: [], routing_required: []}}
      else
        result = run_factory_tick(context, workspace)
        maybe_poll_review_feedback(context, workspace)
        maybe_consume_review_feedback(context, workspace)
        maybe_admit_review_rework(context, workspace)
        result
      end
    else
      result = run_factory_tick(context, workspace)
      maybe_poll_review_feedback(context, workspace)
      maybe_consume_review_feedback(context, workspace)
      maybe_admit_review_rework(context, workspace)
      result
    end
  end

  defp validate_stored_execution_modes(store) do
    rows =
      Store.query!(
        store,
        "SELECT execution_mode FROM runs WHERE execution_mode IS NOT NULL AND execution_mode NOT IN ('LEGACY', 'TICKET_SUPERVISOR_V1') ORDER BY run_id",
        []
      ).rows

    if rows == [], do: :ok, else: {:error, :invalid_execution_mode}
  end

  defp run_factory_tick(context, workspace) do
    retry_rejected_verifier_creation(context)

    result =
      with {:ok, recovery} <- reconcile_ticket_jira_context(context, :before_dispatch),
           :ok <- DesktopRequest.reconcile_native_successes(context.store),
           :ok <- reconcile_stale_tasks(context),
           {:ok, jql} <- Queue.jql(context.factory.queue),
           {:ok, queued_snapshots} <- fetch_queue(context, workspace, jql),
           {:ok, intake_snapshot} <-
             IntakeLedger.replace(context.store, context.factory.scope, queued_snapshots),
           {:ok, snapshots} <- fetch_active_snapshots(context, workspace, queued_snapshots),
           {:ok, intake} <- reconcile_intake(Map.put(context, :intake_observed_at, intake_snapshot.observed_at), snapshots),
           {:ok, legacy_result} <- advance_runs(context, workspace, intake),
           {:ok, advance_result} <- advance_ticket_runs(Map.put(context, :ordinary_rejection_dispatch, true), legacy_result, recovery[:recovery_run_id]) do
        :ok = sweep_one_cleanup_candidate(context)
        NativeWorkspaceMaintenance.reconcile(context.store, context.factory)
        {:ok, %{advance_result | events: recovery.events ++ advance_result.events}}
      end

    result
  end

  defp retry_rejected_verifier_creation(context) do
    candidates =
      Store.query!(
        context.store,
        """
        SELECT request.request_key FROM desktop_requests AS request
        JOIN factory_tasks AS task ON task.task_key = request.target_key
        JOIN runs AS run ON run.run_id = task.run_id
        WHERE request.status = 'RECONCILE_REQUIRED' AND request.failure_code = 'CREATE_THREAD_INVALID_ARGUMENTS'
          AND request.thread_id IS NULL AND task.role = 'change-verifier' AND task.status = 'WAITING_FOR_BROKER'
          AND run.state = 'VERIFYING' AND task.task_key = run.run_id || ':change-verifier:' || run.verifier_round
          AND COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY'
          AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
          AND NOT EXISTS (SELECT id FROM events WHERE event_type = 'REJECTED_NATIVE_CREATE_REARMED'
            AND json_extract(payload_json, '$.request_key') = request.request_key)
        ORDER BY request.created_at ASC
        """,
        []
      ).rows

    Enum.reduce_while(candidates, :ok, fn [request_key], :ok ->
      case Recovery.retry_rejected_native_create(context.store, context.factory, request_key) do
        {:ok, _recovered} -> {:halt, :ok}
        {:error, _reason} -> {:cont, :ok}
      end
    end)
  end

  defp feedback_controller_in_flight?(store) do
    Store.one!(
      store,
      "SELECT note.feedback_key FROM mr_feedback_notes AS note JOIN runs AS run ON run.run_id = note.run_id WHERE note.status = 'CLAIMED' AND COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') LIMIT 1"
    ) != nil or
      DesktopRequest.native_controller_busy?(store)
  end

  defp maybe_consume_review_feedback(context, workspace) do
    if review_feedback_enabled?(context.factory) and
         MrFeedbackLedger.next(context.store) != nil do
      result =
        with_review_mcp_session(context, workspace, fn session ->
          context.feedback_consumer.process_one(context,
            workspace: workspace,
            jira_reader: context.jira_reader,
            gitlab_reader: context.gitlab_reader,
            gitlab_connector: context.gitlab_connector,
            gitlab_app_server: context.gitlab_app_server,
            mcp_session: session,
            controller_task: context.controller_task
          )
        end)

      case result do
        {:ok, _status} -> :ok
        {:error, reason} -> Logger.warning("MR feedback consumption deferred reason=#{inspect(reason)}")
      end
    end

    :ok
  end

  defp maybe_poll_review_feedback(context, workspace) do
    if review_feedback_enabled?(context.factory) and MrFeedbackPoller.review_runs?(context.store) do
      poll_review_feedback(context, workspace)
    end

    :ok
  end

  defp poll_review_feedback(context, workspace) do
    context
    |> with_review_mcp_session(workspace, fn session ->
      MrFeedbackPoller.poll(context,
        workspace: workspace,
        jira_reader: context.jira_reader,
        jira_connector: context.jira_connector || JiraMcpConnector,
        jira_app_server: context.jira_app_server,
        gitlab_reader: context.gitlab_reader,
        gitlab_connector: context.gitlab_connector,
        gitlab_app_server: context.gitlab_app_server,
        mcp_session: session
      )
    end)
    |> log_feedback_poll_result()
  end

  defp log_feedback_poll_result({:error, reason}),
    do: Logger.warning("MR feedback poll deferred reason=#{inspect(reason)}")

  defp log_feedback_poll_result(%{failures: failures}) do
    Enum.each(failures, fn {run_id, reason} ->
      Logger.warning("MR feedback poll skipped run_id=#{run_id} reason=#{inspect(reason)}")
    end)
  end

  defp maybe_admit_review_rework(context, workspace) do
    case MrFeedbackRework.pending_batch(context.store, context.factory.scope) do
      [] ->
        :ok

      [%{"run_id" => run_id} | _] = receipts ->
        result =
          with_review_mcp_session(context, workspace, fn session ->
            admit_review_rework(context, workspace, run_id, receipts, session)
          end)

        case result do
          {:ok, :clarification_queued} -> :ok
          {:ok, _batch_key} -> :ok
          {:error, reason} -> Logger.warning("MR review rework deferred run_id=#{run_id} reason=#{inspect(reason)}")
        end
    end
  end

  defp admit_review_rework(context, workspace, run_id, receipts, session) do
    with {:ok, run} <- RunLedger.get(context.store, run_id),
         true <- native_transport?(context) or {:error, :review_rework_requires_native_writer},
         route <- route_for_run(context, run),
         {:ok, jira} <-
           context.jira_reader.issue(run["issue_key"],
             workspace: workspace,
             connector: context.jira_connector || JiraMcpConnector,
             app_server: context.jira_app_server,
             mcp_session: session
           ),
         {:ok, %{mr: mr, discussions: discussions}} <-
           context.gitlab_reader.fetch(route, run,
             workspace: workspace,
             connector: context.gitlab_connector,
             app_server: context.gitlab_app_server,
             mcp_session: session
           ) do
      case MrFeedbackRework.ambiguous_receipt(receipts, discussions) do
        nil ->
          admit_verified_review_rework(context, run, receipts, route, jira, mr, discussions)

        receipt ->
          handle_ambiguous_review_receipt(context.store, receipt)
      end
    else
      false -> {:error, :review_rework_requires_native_writer}
      {:error, _reason} = error -> error
    end
  end

  defp handle_ambiguous_review_receipt(store, %{"status" => "CHANGE_REQUEST", "feedback_key" => key}) do
    :ok = MrFeedbackLedger.requeue_clarification(store, key)
    {:ok, :clarification_queued}
  end

  defp handle_ambiguous_review_receipt(_store, %{"status" => "RECONCILE_REQUIRED"}),
    do: {:ok, :reconciliation_required}

  defp admit_verified_review_rework(context, run, receipts, route, jira, mr, discussions) do
    policy = Map.get(context.factory, :review_feedback, %{})
    allowed = Map.get(policy, "allowed_author_ids", [11_599_766])
    bot_id = Map.get(policy, "bot_author_id", 0)

    with {:ok, _capacity} <- ensure_writer_capacity(context, run["repo_key"], exclude_writer_issue_key: run["issue_key"]),
         {:ok, %{sha: sha}} <-
           context.worktree.validate_native(writer_route(context, run), run["worktree"],
             clean: true,
             detached: false,
             expected_branch: run["branch"],
             expected_sha: run["candidate_sha"]
           ) do
      MrFeedbackRework.admit(context.store, run, receipts, %{
        route: route,
        jira: jira,
        mr: mr,
        discussions: discussions,
        verified_writer_sha: sha,
        allowed_authors: allowed,
        bot_id: bot_id,
        controller_scope: context.factory.scope
      })
    end
  end

  defp with_review_mcp_session(context, workspace, operation) do
    if context.jira_reader == JiraMcpReader and context.gitlab_reader == SymphonyElixir.Factory.MrFeedbackMcpReader and
         context.jira_app_server == AppServer and context.gitlab_app_server == AppServer do
      case AppServer.start_session(workspace,
             ephemeral: true,
             required_mcp_servers: ["Jira", "GitLab"],
             mcp_startup_timeout_ms: 60_000,
             gitlab_mcp_startup_timeout_sec: 45,
             service_name: "symphony-factory-connector",
             thread_source: "symphonyFactoryConnector"
           ) do
        {:ok, session} ->
          try do
            operation.(session)
          after
            AppServer.stop_session(session)
          end

        {:error, _reason} = error ->
          error
      end
    else
      operation.(nil)
    end
  end

  defp review_feedback_enabled?(factory) do
    Map.get(Map.get(factory, :review_feedback, %{}), "enabled", Map.get(factory, :task_transport) == "desktop_broker")
  end

  defp dependencies(context, opts) do
    context
    |> Map.put_new(:workspace_root, Config.local_workspace_root())
    |> Map.put_new(:active_tasks, %{})
    |> Map.put(:controller_task, Keyword.get(opts, :controller_task, ControllerTask))
    |> Map.put(:task_launcher, Keyword.get(opts, :task_launcher, TaskLauncher))
    |> Map.put(:worktree, Keyword.get(opts, :worktree, Worktree))
    |> Map.put(:cleanup, Keyword.get(opts, :cleanup, Cleanup))
    |> Map.put(:jira_reader, Keyword.get(opts, :jira_reader, JiraMcpReader))
    |> Map.put(:jira_connector, Keyword.get(opts, :jira_connector))
    |> Map.put(:jira_app_server, Keyword.get(opts, :jira_app_server, SymphonyElixir.Codex.AppServer))
    |> Map.put(:gitlab_reader, Keyword.get(opts, :gitlab_reader, SymphonyElixir.Factory.MrFeedbackMcpReader))
    |> Map.put(:gitlab_connector, Keyword.get(opts, :gitlab_connector, SymphonyElixir.Factory.GitLabMcpConnector))
    |> Map.put(:gitlab_app_server, Keyword.get(opts, :gitlab_app_server, SymphonyElixir.Codex.AppServer))
    |> Map.put(:feedback_consumer, Keyword.get(opts, :feedback_consumer, MrFeedbackConsumer))
    |> Map.put(:ticket_options, configured_ticket_options(context, opts))
  end

  defp configured_ticket_options(context, opts) do
    policy = Map.get(context.factory, :ticket_supervisor, %{})
    fields = ~w(parent_output_root broker_thread_id ticket_cli_root ticket_workflow)a

    configured =
      Enum.flat_map(fields, fn key ->
        case Map.fetch(policy, Atom.to_string(key)) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    configured
    |> Keyword.put_new(:ticket_workflow, Path.expand(Workflow.workflow_file_path()))
    |> Keyword.merge(Map.get(context, :ticket_options, []))
    |> Keyword.merge(Keyword.get(opts, :ticket_options, []))
  end

  defp reconcile_stale_tasks(context) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-context.factory.stale_task_minutes * 60, :second)
      |> DateTime.to_iso8601()

    result =
      Store.query!(
        context.store,
        """
        SELECT task.task_key FROM factory_tasks AS task JOIN runs AS run ON run.run_id = task.run_id
        WHERE task.status IN ('STARTING', 'RUNNING') AND task.updated_at < ?
          AND COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY'
          AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
        """,
        [cutoff]
      )

    Enum.each(result.rows, fn [task_key] ->
      kill_stale_task(context, task_key)

      TaskLedger.update(context.store, task_key, %{
        status: "STALE",
        failure_code: "stale task exceeded #{context.factory.stale_task_minutes} minutes"
      })
    end)

    :ok
  end

  defp kill_stale_task(context, task_key) do
    owner =
      case Map.get(context.active_tasks, task_key) do
        %{pid: pid} when is_pid(pid) -> pid
        _other -> TaskLauncher.active_owner(task_key)
      end

    if is_pid(owner), do: Process.exit(owner, :kill)
  end

  defp controller_workspace(context) do
    context.workspace_root
    |> Path.expand()
    |> Path.join("factory-controller")
    |> Path.join(safe(context.factory.scope))
  end

  defp fetch_queue(context, workspace, jql) do
    if native_transport?(context) do
      context.jira_reader.search(jql,
        connector: context.jira_connector || SymphonyElixir.Factory.JiraMcpConnector,
        app_server: context.jira_app_server,
        workspace: workspace
      )
    else
      fetch_queue_from_controller(context, workspace, jql)
    end
  end

  defp fetch_queue_from_controller(context, workspace, jql) do
    issue = controller_issue(context.factory.scope)

    case context.controller_task.run(
           context.factory,
           workspace,
           issue,
           Prompt.jira_intake(jql),
           StageSchemas.for_stage(:jira_snapshot),
           control_server: context.control_server,
           model_role: "orchestrator-intake",
           required_tool_calls: [%{server: "Jira", tool: "jira_search"}]
         ) do
      {:ok, %{"status" => "PASS", "snapshot_json" => snapshot_json}} ->
        case decode_jira_snapshot(snapshot_json, :list) do
          {:ok, snapshots} -> {:ok, snapshots}
          :error -> {:error, :jira_intake_invalid_snapshot_json}
        end

      {:ok, output} ->
        {:error, {:jira_intake_blocked, output}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_active_snapshots(context, workspace, queued_snapshots) do
    queued_keys = MapSet.new(queued_snapshots, &snapshot_value(&1, "key"))

    missing_keys =
      (active_issue_keys(context.store) ++ recoverable_delivery_issue_keys(context.store))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(queued_keys, &1))

    if missing_keys == [] do
      {:ok, queued_snapshots}
    else
      jql = "key IN (#{Enum.map_join(missing_keys, ", ", &quote_jql/1)})"

      with {:ok, active_snapshots} <- fetch_queue(context, workspace, jql),
           returned_keys <- MapSet.new(active_snapshots, &snapshot_value(&1, "key")),
           true <- MapSet.subset?(MapSet.new(missing_keys), returned_keys) or {:error, :active_jira_snapshot_missing} do
        {:ok, merge_snapshots(queued_snapshots, active_snapshots)}
      end
    end
  end

  defp active_issue_keys(store) do
    placeholders = Enum.map_join(@terminal_states, ", ", fn _state -> "?" end)

    store
    |> Store.query!(
      "SELECT DISTINCT issue_key FROM runs WHERE state NOT IN (#{placeholders}) AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') ORDER BY issue_key",
      @terminal_states
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [issue_key] -> issue_key end)
  end

  defp recoverable_delivery_issue_keys(store) do
    store
    |> Store.query!(
      "SELECT DISTINCT issue_key FROM runs WHERE kind = 'DELIVERY' AND state IN ('FAILED', 'CANCELLED') AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') ORDER BY issue_key",
      []
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [issue_key] -> issue_key end)
    |> Enum.filter(fn issue_key ->
      case latest_delivery_run(store, issue_key) do
        %{"state" => "FAILED", "snapshot_json" => json} when is_binary(json) ->
          snapshot = decode_json(json, %{})
          Enum.any?(["ai-running", "ai-ready"], &(&1 in normalized_labels(snapshot)))

        %{"state" => "CANCELLED", "snapshot_json" => json} = run when is_binary(json) ->
          snapshot = decode_json(json, %{})
          ContractChat.recoverable_rearm_interruption?(run) and "ai-ready" in normalized_labels(snapshot)

        _other ->
          false
      end
    end)
  end

  defp merge_snapshots(left, right) do
    (left ++ right)
    |> Map.new(&{snapshot_value(&1, "key"), &1})
    |> Map.values()
  end

  defp reconcile_intake(context, snapshots) do
    accumulator = %{launches: [], events: [], routing_required: []}

    result =
      Enum.reduce_while(snapshots, {:ok, accumulator}, fn snapshot, {:ok, acc} ->
        case reconcile_snapshot(context, snapshot, acc) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, acc} <- result do
      {:ok, maybe_register_validations(context, snapshots, acc)}
    end
  end

  defp reconcile_snapshot(context, snapshot, acc) do
    issue_key = snapshot_value(snapshot, "key")

    if present?(issue_key) do
      if v1_issue?(context.store, issue_key) do
        {:ok, acc}
      else
        update_active_snapshot(context.store, issue_key, snapshot)
        reconcile_known_issue_snapshot(context, snapshot, acc, issue_key)
      end
    else
      {:error, :jira_snapshot_missing_key}
    end
  end

  defp reconcile_known_issue_snapshot(context, snapshot, acc, issue_key) do
    case active_run_for_issue(context.store, issue_key) do
      %{} = active -> reconcile_reopened_delivery_label(context, snapshot, active, acc)
      nil -> reconcile_inactive_snapshot(context, snapshot, acc)
    end
  end

  defp v1_issue?(store, issue_key),
    do: Store.one!(store, "SELECT run_id FROM runs WHERE issue_key = ? AND execution_mode = 'TICKET_SUPERVISOR_V1' LIMIT 1", [issue_key]) != nil

  defp reconcile_inactive_snapshot(context, snapshot, acc) do
    issue_key = snapshot_value(snapshot, "key")

    case recover_unavailable_specification_authorization(context, snapshot) do
      {:ok, run} ->
        {:ok, add_event(acc, issue_key, "SPECIFICATION_AUTHORIZATION_RECOVERED", run["run_id"])}

      _other ->
        case latest_delivery_run(context.store, issue_key) do
          %{"state" => "FAILED"} = failed -> reconcile_failed_delivery(context, snapshot, failed, acc)
          %{"state" => "CANCELLED"} = cancelled -> reconcile_interrupted_rearm(context, snapshot, cancelled, acc)
          _other -> register_classified_snapshot(context, snapshot, acc)
        end
    end
  end

  defp reconcile_reopened_delivery_label(context, snapshot, run, acc) do
    reopened =
      Store.one!(
        context.store,
        "SELECT id FROM events WHERE run_id = ? AND event_type = 'FACTORY_BLOCKED_DELIVERY_REOPENED' ORDER BY id DESC LIMIT 1",
        [run["run_id"]]
      )

    if run["kind"] == "DELIVERY" and is_map(reopened) and "ai-blocked" in normalized_labels(snapshot) do
      case clear_interrupted_rearm_block(context, run, snapshot) do
        {:ok, _fresh} -> {:ok, add_event(acc, run["issue_key"], "REOPENED_DELIVERY_BLOCK_LABEL_CLEARED", run["run_id"])}
        {:error, reason} -> {:ok, add_event(acc, run["issue_key"], "REOPENED_DELIVERY_LABEL_CLEAR_REQUIRED", reason)}
      end
    else
      {:ok, acc}
    end
  end

  defp reconcile_interrupted_rearm(context, snapshot, interrupted, acc) do
    if ContractChat.recoverable_rearm_interruption?(interrupted) do
      result =
        with :ok <- ContractChat.verify_interrupted_rearm(context.store, context.worktree, interrupted, snapshot),
             {:ok, current_snapshot} <- clear_interrupted_rearm_block(context, interrupted, snapshot) do
          ContractChat.resume_interrupted_rearm(context.store, context.worktree, interrupted, current_snapshot)
        end

      case result do
        {:ok, run} -> {:ok, add_event(acc, run["issue_key"], "DELIVERY_REARM_INTERRUPTION_RECOVERED", run["run_id"])}
        {:error, reason} -> {:ok, add_event(acc, interrupted["issue_key"], "DELIVERY_REARM_RECOVERY_REQUIRED", reason)}
      end
    else
      register_classified_snapshot(context, snapshot, acc)
    end
  end

  defp clear_interrupted_rearm_block(context, interrupted, snapshot) do
    if "ai-blocked" in normalized_labels(snapshot) do
      operation = "Remove only the factory-added ai-blocked label after proving the interrupted contract rearm."
      current_run = Map.put(interrupted, "snapshot_json", Jason.encode!(snapshot))
      workspace = controller_workspace(context)

      with {:ok, _write} <-
             jira_write(context, workspace, current_run, operation, "ai-ready",
               mutations: [:labels],
               label_remove: ["ai-blocked"]
             ),
           {:ok, fresh} <- fetch_issue(context, workspace, interrupted["issue_key"]),
           true <- "ai-blocked" not in normalized_labels(fresh) do
        {:ok, fresh}
      else
        false -> {:error, :interrupted_rearm_block_not_cleared}
        {:error, _reason} = error -> error
      end
    else
      {:ok, snapshot}
    end
  end

  defp recover_unavailable_specification_authorization(context, snapshot) do
    issue_key = snapshot_value(snapshot, "key")

    case latest_issue_run(context.store, issue_key) do
      %{"kind" => "SPECIFICATION", "state" => "FAILED", "failure_code" => failure, "run_id" => run_id}
      when failure == "{:required_mcp_servers_unavailable, [\"Jira\"]}" ->
        with true <- automatic_specification_authorization?(context),
             {:ok, route} <- Queue.route(snapshot, context.factory.repositories),
             {:ok, %{run: run}} <-
               RunLedger.recover_unavailable_specification_authorization(context.store, run_id, snapshot, route) do
          {:ok, run}
        end

      _other ->
        :not_applicable
    end
  end

  defp reconcile_failed_delivery(context, snapshot, %{"failure_code" => ":worktree_dirty"} = failed, acc),
    do: reconcile_interrupted_rearm(context, snapshot, failed, acc)

  defp reconcile_failed_delivery(context, snapshot, failed, acc) do
    labels = normalized_labels(snapshot)
    status = snapshot_value(snapshot, "status") |> normalize_status()

    if Enum.any?(["ai-running", "ai-ready"], &(&1 in labels)) and
         status in ["IN DEV", "READY", "TO DO"] do
      case Contract.authorized_from_snapshot(snapshot, failed["issue_key"]) do
        {:ok, contract} ->
          reconcile_authorized_failed_delivery(context, snapshot, failed, contract, acc)

        _other ->
          maybe_register_contract_discussion(context, snapshot, failed, acc)
      end
    else
      {:ok, acc}
    end
  end

  defp reconcile_authorized_failed_delivery(context, snapshot, failed, contract, acc) do
    if contract.revision > failed["spec_revision"] and contract.sha256 != failed["contract_sha256"] do
      rearm_revised_delivery(context, snapshot, failed, contract, acc)
    else
      maybe_register_contract_discussion(context, snapshot, failed, acc)
    end
  end

  defp maybe_register_contract_discussion(context, snapshot, failed, acc) do
    if ContractChat.changed?(failed, snapshot),
      do: register_contract_discussion(context, snapshot, failed, acc),
      else: {:ok, acc}
  end

  defp rearm_revised_delivery(context, snapshot, failed, contract, acc) do
    with :ok <- validate_delivery_authorization(context, snapshot, contract),
         {:ok, manual_required} <- Contract.manual_validation_required(contract.markdown),
         {:ok, manual_environment} <- Contract.manual_validation_environment(contract.markdown),
         :ok <- validate_manual_policy(context.factory.manual_validation, manual_required, manual_environment),
         {:ok, _run} <-
           ContractChat.rearm_delivery(context.store, context.worktree, failed, snapshot, contract, manual_required) do
      {:ok, add_event(acc, failed["issue_key"], "DELIVERY_CONTRACT_REARMED", contract.sha256)}
    else
      {:error, reason} -> {:ok, add_event(acc, failed["issue_key"], "DELIVERY_CONTRACT_RECOVERY_REQUIRED", reason)}
    end
  end

  defp register_contract_discussion(context, snapshot, failed, acc) do
    with {:ok, route} <- Queue.route(snapshot, context.factory.repositories),
         {:ok, capacity} <- capacity(context, route["repo_key"]),
         true <- capacity.available_specifier_slots > 0 or {:skip, :specifier_capacity},
         attrs <-
           new_specification_attrs(context, snapshot, route)
           |> Map.merge(%{
             state: "CONTRACT_DISCUSSING",
             parent_run_id: failed["run_id"],
             repair_findings_json: Jason.encode!([failed["failure_code"] || "Delivery stopped for review"])
           }),
         {:ok, %{run: run}} <- RunLedger.register(context.store, attrs) do
      {:ok, add_event(acc, run["issue_key"], "CONTRACT_DISCUSSION_STARTED", run["run_id"])}
    else
      {:skip, _reason} -> {:ok, acc}
      {:error, :routing_required} -> {:ok, routing_required(acc, snapshot)}
      {:error, :ambiguous_repository_route} -> {:ok, routing_required(acc, snapshot)}
      {:error, reason} -> {:error, {:contract_discussion_registration_failed, reason}}
    end
  end

  defp register_classified_snapshot(context, snapshot, acc) do
    classification =
      if resume_blocked_specification?(context, snapshot), do: :specification, else: Queue.classify(snapshot)

    case classification do
      :specification -> register_specification(context, snapshot, acc)
      :delivery -> register_delivery(context, snapshot, acc)
      :reconcile -> {:ok, acc}
      :ignore -> {:ok, acc}
      {:error, reason} -> {:ok, add_event(acc, snapshot_value(snapshot, "key"), "INTAKE_BLOCKED", reason)}
    end
  end

  defp resume_blocked_specification?(context, snapshot) do
    labels = normalized_labels(snapshot)
    status = snapshot_value(snapshot, "status") |> to_string() |> String.downcase()
    allowed_statuses = Map.get(context.factory.queue, "statuses", []) |> Enum.map(&String.downcase/1)
    run = latest_issue_run(context.store, snapshot_value(snapshot, "key"))

    "ai-blocked" in labels and status in allowed_statuses and
      Enum.any?(["spec-needed", "needs-decision"], &(&1 in labels)) and
      Enum.all?(["ai-review", "ai-ready", "ai-running", "ai-verifying", "ai-testing"], &(&1 not in labels)) and
      failed_specification_resumable?(context.store, run, snapshot)
  end

  defp failed_specification_resumable?(store, %{"kind" => "SPECIFICATION", "state" => "FAILED"} = run, snapshot) do
    previous = decode_json(run["snapshot_json"], %{})

    specification_input(previous) != specification_input(snapshot) or
      RunLedger.specification_retry_pending?(store, run["run_id"])
  end

  defp failed_specification_resumable?(_store, _run, _snapshot), do: false

  defp register_specification(context, snapshot, acc) do
    if unchanged_failed_specification?(context.store, snapshot) do
      {:ok, acc}
    else
      with {:ok, route} <- Queue.route(snapshot, context.factory.repositories),
           {:ok, capacity} <- capacity(context, route["repo_key"]),
           true <- capacity.available_specifier_slots > 0 or {:skip, :specifier_capacity},
           {:ok, %{run: run}} <- register_or_resume_specification(context, snapshot, route) do
        {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_REGISTERED", run["run_id"])}
      else
        {:error, :routing_required} -> {:ok, routing_required(acc, snapshot)}
        {:error, :ambiguous_repository_route} -> {:ok, routing_required(acc, snapshot)}
        {:error, :retry_repository_route_mismatch} -> {:ok, routing_required(acc, snapshot)}
        {:error, :retry_codex_project_mismatch} -> {:ok, routing_required(acc, snapshot)}
        {:error, :active_specification_task} -> {:ok, acc}
        {:skip, _reason} -> {:ok, acc}
        {:error, reason} -> {:error, {:specification_registration_failed, reason}}
      end
    end
  end

  defp register_or_resume_specification(context, snapshot, route) do
    issue_key = snapshot_value(snapshot, "key")

    case latest_issue_run(context.store, issue_key) do
      %{"kind" => "SPECIFICATION", "state" => "FAILED", "failure_code" => ":specification_input_changed_during_review", "run_id" => run_id} ->
        RunLedger.recover_stale_specification_critic(context.store, run_id, snapshot, route)

      %{"kind" => "SPECIFICATION", "state" => "FAILED", "failure_code" => ":independent_critic_pass_not_proven", "run_id" => run_id} ->
        RunLedger.recover_stale_critic_authorization(context.store, run_id, snapshot, route)

      %{"kind" => "SPECIFICATION", "state" => "FAILED", "run_id" => run_id} = old_run ->
        reason = if RunLedger.specification_retry_pending?(context.store, run_id), do: :local_retry, else: :jira_input_changed

        if native_transport?(context) and old_run["factory_owned"] == 1 do
          RunLedger.restart_failed_specification_native(
            context.store,
            run_id,
            snapshot,
            route,
            new_specification_attrs(context, snapshot, route),
            reason
          )
        else
          RunLedger.resume_failed_specification(
            context.store,
            run_id,
            snapshot,
            route,
            Contract.next_revision(snapshot),
            reason
          )
        end

      _other ->
        RunLedger.register(context.store, new_specification_attrs(context, snapshot, route))
    end
  end

  defp new_specification_attrs(context, snapshot, route) do
    %{
      run_id: Ecto.UUID.generate(),
      issue_key: snapshot_value(snapshot, "key"),
      kind: "SPECIFICATION",
      state: "SPEC_DRAFTING",
      dispatcher_id: context.factory.dispatcher_id,
      spec_revision: Contract.next_revision(snapshot),
      repo_key: route["repo_key"],
      repo_path: route["path"],
      base_branch: route["base_branch"],
      factory_owned: not native_transport?(context),
      snapshot_json: Jason.encode!(snapshot),
      runtime: if(native_transport?(context), do: "codex-desktop-broker", else: "codex-app-server")
    }
  end

  defp unchanged_failed_specification?(store, snapshot) do
    issue_key = snapshot_value(snapshot, "key")

    case latest_issue_run(store, issue_key) do
      %{"kind" => "SPECIFICATION", "state" => "FAILED"} = run ->
        previous = decode_json(run["snapshot_json"], %{})

        run["failure_code"] not in [":specification_input_changed_during_review", ":independent_critic_pass_not_proven"] and
          specification_input(previous) == specification_input(snapshot) and
          not RunLedger.specification_retry_pending?(store, run["run_id"])

      _other ->
        false
    end
  end

  defp specification_input(snapshot) do
    fields = ~w(key summary description status assignee project_key parent_key)

    selected =
      Map.new(fields, fn field ->
        value = snapshot_value(snapshot, field)
        {field, if(field == "assignee", do: normalize_assignee(value), else: normalize_specification_field(value))}
      end)

    components =
      snapshot
      |> snapshot_value("components")
      |> List.wrap()
      |> Enum.map(&normalize_specification_field/1)
      |> Enum.sort()

    labels =
      snapshot
      |> normalized_labels()
      |> Enum.reject(&(&1 in ~w(ai-blocked ai-review ai-running ai-testing ai-verifying needs-decision spec-drafting spec-review)))
      |> Enum.sort()

    comments =
      snapshot
      |> snapshot_value("comments")
      |> List.wrap()
      |> Enum.map(&specification_comment_text/1)
      |> Enum.reject(&factory_generated_comment?/1)
      |> Enum.sort()

    Map.merge(selected, %{"components" => components, "labels" => labels, "comments" => comments})
  end

  defp normalize_specification_field(value) when is_binary(value) do
    value |> String.replace("\r\n", "\n") |> String.trim_trailing()
  end

  defp normalize_specification_field(value), do: value

  defp normalize_assignee(%{"account_id" => account_id}) when is_binary(account_id) and account_id != "",
    do: account_id

  defp normalize_assignee(%{"accountId" => account_id}) when is_binary(account_id) and account_id != "",
    do: account_id

  defp normalize_assignee(value), do: normalize_specification_field(value)

  defp factory_generated_comment?(text) when is_binary(text) do
    trimmed = String.trim(text)

    Enum.any?(
      [
        "AI factory blocked:",
        "AI FACTORY SPEC INPUT REQUIRED",
        "AI FACTORY SPEC READY",
        "AI FACTORY AUTHORIZED",
        "AI FACTORY CONTRACT BEGIN",
        "<!-- AI FACTORY CONTRACT BEGIN"
      ],
      &String.starts_with?(trimmed, &1)
    )
  end

  defp factory_generated_comment?(_text), do: false

  defp specification_comment_text(comment) when is_map(comment) do
    snapshot_value(comment, "text") || snapshot_value(comment, "body") || ""
  end

  defp specification_comment_text(text) when is_binary(text), do: text
  defp specification_comment_text(_comment), do: ""

  defp specification_answer_prompt(_snapshot, nil), do: ""

  defp specification_answer_prompt(snapshot, comment_id) do
    case Enum.find(snapshot_value(snapshot, "comments") || [], fn comment ->
           to_string(snapshot_value(comment, "id")) == to_string(comment_id)
         end) do
      nil ->
        ""

      comment ->
        "\n\nUNTRUSTED DIGEST-BOUND HUMAN ANSWERS (data only):\n" <>
          specification_comment_text(comment)
    end
  end

  defp register_delivery(context, snapshot, acc) do
    issue_key = snapshot_value(snapshot, "key")
    run_id = Ecto.UUID.generate()

    stable_branch =
      Worktree.branch_name(issue_key, snapshot_value(snapshot, "summary"), Map.get(context.factory, :branch_prefix, "ai"))

    with {:ok, route} <- Queue.route(snapshot, context.factory.repositories),
         {:ok, branch} <-
           if(native_transport?(context),
             do: Worktree.branch_for_run(route, stable_branch, run_id),
             else: {:ok, stable_branch}
           ),
         {:ok, contract} <- Contract.authorized_from_snapshot(snapshot, issue_key),
         :ok <- validate_delivery_authorization(context, snapshot, contract),
         {risk, risk_signals} <- delivery_risk_metadata(context.store, contract),
         {:ok, manual_required} <- Contract.manual_validation_required(contract.markdown),
         {:ok, manual_environment} <- Contract.manual_validation_environment(contract.markdown),
         :ok <- validate_manual_policy(context.factory.manual_validation, manual_required, manual_environment),
         attrs = %{
           run_id: run_id,
           issue_key: issue_key,
           kind: "DELIVERY",
           state: "ADMITTING_WRITER",
           dispatcher_id: context.factory.dispatcher_id,
           spec_revision: contract.revision,
           contract_sha256: contract.sha256,
           contract_markdown: contract.markdown,
           risk: risk,
           risk_signals_json: Jason.encode!(risk_signals),
           manual_validation_required: manual_required,
           repo_key: route["repo_key"],
           repo_path: route["path"],
           base_branch: route["base_branch"],
           branch: branch,
           snapshot_json: Jason.encode!(snapshot),
           factory_owned: not native_transport?(context),
           runtime: if(native_transport?(context), do: "codex-desktop-broker", else: "codex-app-server")
         },
         {:ok, prepared, parent_opts} <- prepare_delivery_registration(context, attrs),
         {:ok, _capacity} <- ensure_writer_capacity(context, route["repo_key"]),
         {:ok, %{run: run}} <- register_prepared_delivery(context, prepared, parent_opts) do
      {:ok, add_event(acc, run["issue_key"], "DELIVERY_REGISTERED", run["run_id"])}
    else
      {:error, :routing_required} ->
        {:ok, routing_required(acc, snapshot)}

      {:error, :ambiguous_repository_route} ->
        {:ok, routing_required(acc, snapshot)}

      {:error, :confirmed_authorization_missing} ->
        {:ok, add_event(acc, issue_key, "AUTHORIZATION_REQUIRED", nil)}

      {:error, :automatic_critic_evidence_missing} ->
        {:ok, add_event(acc, issue_key, "AUTHORIZATION_REQUIRED", :automatic_critic_evidence_missing)}

      {:error, {:insufficient_writer_capacity, _cleaned}} ->
        {:ok, add_event(acc, issue_key, "INSUFFICIENT_WRITER_CAPACITY", nil)}

      {:error, reason} when reason in @local_intake_denials ->
        block_intake(context, snapshot, acc, reason)

      {:error, {:manual_validation_environment_not_allowed, _environment}} ->
        block_intake(context, snapshot, acc, :manual_validation_environment_not_allowed)

      {:error, reason} ->
        {:error, {:delivery_registration_failed, reason}}
    end
  end

  defp block_intake(context, snapshot, acc, reason) do
    # Admission denials bind this observation only; global failures still stop the tick.
    with :ok <- IntakeLedger.record_blocked(context.store, context.factory.scope, snapshot, context.intake_observed_at, reason) do
      {:ok, add_event(acc, snapshot_value(snapshot, "key"), "INTAKE_BLOCKED", reason)}
    end
  end

  defp prepare_delivery_registration(context, attrs) do
    policy = Map.get(context.factory, :ticket_supervisor, %{})
    selected = Policy.ticket_selected?(policy, attrs.issue_key)
    if selected, do: prepare_ticket_registration(context, attrs), else: {:ok, attrs, nil}
  end

  defp prepare_ticket_registration(context, attrs) do
    options = Map.get(context, :ticket_options, [])
    attrs = Map.merge(attrs, %{execution_mode: "TICKET_SUPERVISOR_V1", factory_owned: true, runtime: "codex-app-server"})
    ordinary = Map.new(attrs, fn {key, value} -> {to_string(key), value} end) |> Map.put("manual_validation_required", 0)

    with true <- native_transport?(context) or {:error, :ticket_chat_desktop_transport_required},
         true <- attrs.manual_validation_required == false or {:error, :ticket_manual_validation_not_supported},
         {:ok, _parent} <- prepare_ticket_parent(context, ordinary, options),
         {:ok, root} <- parent_output_root(options[:parent_output_root]),
         :ok <- AppServer.check_ticket_runtime(root) do
      {:ok, attrs, options}
    end
  end

  defp register_prepared_delivery(context, attrs, nil), do: RunLedger.register(context.store, attrs)

  defp register_prepared_delivery(context, attrs, options) do
    operation = fn tx -> rollback_registration(tx, register_ticket_delivery(%{context | store: tx}, attrs, options)) end

    case Exqlite.transaction(context.store, operation) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_registration(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_registration(_tx, result), do: result

  defp register_ticket_delivery(context, attrs, options) do
    with {:ok, %{run: run} = registered} <- RunLedger.register(context.store, attrs),
         {:ok, parent} <- prepare_ticket_parent(context, run, options),
         {:ok, _} <- reserve_ticket_parent(context, run, parent) do
      {:ok, registered}
    end
  end

  defp delivery_risk_metadata(store, contract) do
    result =
      Store.query!(
        store,
        "SELECT risk, risk_signals_json FROM runs WHERE issue_key = ? AND kind = 'SPECIFICATION' " <>
          "AND state = 'DELIVERED' AND spec_revision = ? AND contract_sha256 = ? AND contract_markdown = ?",
        [contract.issue_key, contract.revision, contract.sha256, contract.markdown]
      )

    # Jira prose cannot downgrade a writer; only a unique, exact authorized specification supplies risk metadata.
    case result.rows do
      [[risk, signals]] when is_binary(risk) and is_binary(signals) ->
        with normalized <- risk |> String.trim() |> String.downcase(),
             true <- normalized in ~w(low routine medium high critical unknown),
             {:ok, values} when is_list(values) <- Jason.decode(signals),
             true <- Enum.all?(values, &is_binary/1) do
          {normalized, values}
        else
          _other -> {"unknown", []}
        end

      _other ->
        {"unknown", []}
    end
  end

  defp maybe_register_validations(context, snapshots, acc) do
    Enum.reduce(snapshots, acc, fn snapshot, current ->
      issue_key = snapshot_value(snapshot, "key")

      if not v1_issue?(context.store, issue_key) and "ai-testing" in normalized_labels(snapshot) and
           is_nil(active_run_for_issue(context.store, issue_key)) do
        maybe_register_validation(context, snapshot, current)
      else
        current
      end
    end)
  end

  defp maybe_register_validation(context, snapshot, acc) do
    issue_key = snapshot_value(snapshot, "key")

    with %{} = parent <- latest_run(context.store, issue_key, "DELIVERY", "AWAITING_VALIDATION"),
         {:ok, capacity} <- capacity(context, parent["repo_key"]),
         true <- capacity.available_validator_slots > 0,
         {:ok, %{run: run}} <-
           RunLedger.register(context.store, %{
             run_id: Ecto.UUID.generate(),
             parent_run_id: parent["run_id"],
             issue_key: issue_key,
             kind: "VALIDATION",
             state: "TESTING",
             dispatcher_id: context.factory.dispatcher_id,
             spec_revision: parent["spec_revision"],
             contract_sha256: parent["contract_sha256"],
             contract_markdown: parent["contract_markdown"],
             plan_markdown: parent["plan_markdown"],
             manual_validation_required: true,
             repo_key: parent["repo_key"],
             repo_path: parent["repo_path"],
             base_branch: parent["base_branch"],
             worktree: parent["worktree"],
             branch: parent["branch"],
             candidate_sha: parent["candidate_sha"],
             mr_url: parent["mr_url"],
             mr_iid: parent["mr_iid"],
             snapshot_json: Jason.encode!(snapshot),
             factory_owned: not native_transport?(context),
             runtime: if(native_transport?(context), do: "codex-desktop-broker", else: "codex-app-server")
           }) do
      add_event(acc, issue_key, "VALIDATION_REGISTERED", run["run_id"])
    else
      _other -> acc
    end
  end

  defp advance_runs(context, workspace, accumulator) do
    runs = active_runs(context.store)

    result =
      Enum.reduce_while(runs, {:ok, accumulator}, fn run, {:ok, acc} ->
        case advance_run(context, workspace, run, acc) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    result
  end

  defp advance_ticket_runs(context, acc, recovery_run_id) do
    result =
      Store.query!(
        context.store,
        "SELECT * FROM runs WHERE execution_mode = 'TICKET_SUPERVISOR_V1' AND (state NOT IN ('DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') OR (state='FAILED' AND EXISTS (SELECT 1 FROM events a WHERE a.run_id=runs.run_id AND a.event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED' AND NOT EXISTS (SELECT 1 FROM events p WHERE p.event_type='TICKET_VERIFIER_REPAIR_APPLIED' AND json_extract(p.payload_json,'$.authorization_event_id')=a.id)))) ORDER BY created_at, run_id"
      )

    runs =
      result.rows
      |> Enum.map(&Map.new(Enum.zip(result.columns, &1)))
      |> Enum.reject(&(&1["run_id"] == recovery_run_id))

    {:ok, Enum.reduce(runs, acc, &advance_ticket_run(context, &1, &2))}
  end

  defp advance_ticket_run(context, run, acc) do
    policy = Map.get(context.factory, :ticket_supervisor, %{})

    if Policy.ticket_selected?(policy, run["issue_key"]) do
      options = Keyword.put(context.ticket_options, :jira_reader, context.jira_reader)
      ticket_tick_result(context, run, options, acc)
    else
      acc
    end
  rescue
    error ->
      Logger.warning("Factory ticket deferred issue_identifier=#{run["issue_key"]} run_id=#{run["run_id"]} reason=ticket_step_exception:#{inspect(error.__struct__)}")
      add_event(acc, run["issue_key"], "TICKET_DEFERRED", failure_code({:ticket_step_exception, error.__struct__}))
  end

  defp ticket_tick_result(context, run, options, acc) do
    result = ticket_tick_step(context, run, options)

    case result do
      {:ok, %{status: "LAUNCHED", launch: launch}} ->
        add_event(%{acc | launches: [launch | acc.launches]}, run["issue_key"], "TICKET_LAUNCHED", run["run_id"])

      {:ok, %{status: "COMMAND_RESUMED", launch: launch}} ->
        add_event(%{acc | launches: [launch | acc.launches]}, run["issue_key"], "TICKET_COMMAND_RESUMED", run["run_id"])

      {:ok, %{status: "AMENDMENT_DEFERRED", reason: reason}} ->
        add_event(acc, run["issue_key"], "TICKET_AMENDMENT_DEFERRED", inspect(reason))

      {:ok, %{status: status}} ->
        add_event(acc, run["issue_key"], "TICKET_" <> status, run["run_id"])

      {:error, reason} ->
        Logger.warning("Factory ticket deferred issue_identifier=#{run["issue_key"]} run_id=#{run["run_id"]} reason=#{ticket_deferral_code(reason, 3)}")
        add_event(acc, run["issue_key"], "TICKET_DEFERRED", failure_code(reason))
    end
  end

  defp ticket_tick_step(context, %{"state" => "FAILED"} = run, options),
    do: ticket_step(context, run["run_id"], Keyword.put(options, :ordinary_controller_tick, true))

  defp ticket_tick_step(context, run, options) do
    case TicketChat.ready_for_run(context.store, run["run_id"]) do
      {:ok, _} ->
        if run["state"] in ~w(ADMITTING_WRITER PLANNING WRITING REPAIRING REVIEW_WRITING VERIFYING READY_FOR_REVIEW),
          do: ticket_ready_parent_step(context, run, options),
          else: ticket_delivery_pending(context, run, options)

      {:error, _} ->
        ticket_parent_step(context, run["run_id"], options)
    end
  end

  defp ticket_ready_parent_step(context, expected_run, options) do
    lock = {{__MODULE__, :ticket_stage, expected_run["run_id"]}, self()}

    case :global.trans(lock, fn -> ticket_ready_parent_locked(context, expected_run, options) end) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp ticket_ready_parent_locked(context, expected_run, options) do
    run_id = expected_run["run_id"]

    with {:ok, run} <- RunLedger.get(context.store, run_id),
         true <- run["state"] in ~w(ADMITTING_WRITER PLANNING WRITING REPAIRING REVIEW_WRITING VERIFYING READY_FOR_REVIEW) or {:error, :ticket_command_run_state_changed},
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, chat} <- TicketChat.ready_for_run(context.store, run_id),
         previous <- command_statuses(context.store, chat["chat_key"], run_id),
         {:ok, collected} <- TicketChatCommands.collect(context.store, run_id, native_reader: Keyword.get(options, :ticket_chat_reader, AppServer)),
         :ok <- no_new_native_rejections(context.store, run, chat, previous, collected.receipts),
         {:ok, current_run} <- RunLedger.get(context.store, run_id),
         {:ok, current_chat} <- TicketChat.ready_for_run(context.store, run_id),
         :ok <- validate_ticket_binding(run, chat, current_run, current_chat) do
      apply_or_advance_ticket(context, current_run, current_chat, options)
    else
      {:error, {:answer_recovered, receipt}} -> {:ok, %{status: "ANSWER_RECOVERED", receipt: receipt, source_advanced: false}}
      {:error, reason} -> {:error, {:ticket_command_readback_deferred, reason}}
    end
  end

  defp validate_ticket_binding(run, chat, current_run, current_chat) do
    if current_ticket_binding(run, chat) == current_ticket_binding(current_run, current_chat),
      do: :ok,
      else: {:error, :ticket_command_binding_changed}
  end

  defp command_statuses(store, chat_key, run_id) do
    Store.query!(store, "SELECT command_key, status FROM ticket_chat_commands WHERE chat_key = ? AND run_id = ?", [chat_key, run_id]).rows
    |> Map.new(fn [key, status] -> {key, status} end)
  end

  defp no_new_native_rejections(store, run, chat, previous, receipts) do
    rejected =
      Enum.filter(receipts, &new_native_rejection?(store, previous, &1))

    case rejected do
      [%{"command_key" => key}] ->
        handle_single_native_rejection(store, run, chat, key)

      [first | _] ->
        {:error, {:native_command_rejected, first["command_key"]}}

      [] ->
        :ok
    end
  end

  defp new_native_rejection?(store, previous, receipt) do
    receipt["status"] == "REJECTED" and
      (previous[receipt["command_key"]] != "REJECTED" or recoverable_answer_rejection?(store, receipt["command_key"]))
  end

  defp handle_single_native_rejection(store, run, chat, key) do
    if recovered_answer_exists?(store, key) do
      case TicketChatCommands.recover_declared_answer(store, key, ticket_command_context(run, chat)) do
        {:ok, _receipt} -> :ok
        _ -> {:error, {:native_command_rejected, key}}
      end
    else
      case TicketChatCommands.recover_declared_answer(store, key, ticket_command_context(run, chat)) do
        {:ok, receipt} -> {:error, {:answer_recovered, receipt}}
        _ -> {:error, {:native_command_rejected, key}}
      end
    end
  end

  defp recoverable_answer_rejection?(store, key) do
    case Store.one!(store, "SELECT receipt_json, application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [key]) do
      %{"receipt_json" => receipt, "application_receipt_json" => nil} ->
        case Jason.decode(receipt || "null") do
          {:ok, %{"reason" => "native_intent_mismatch"}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp recovered_answer_exists?(store, key),
    do: Store.one!(store, "SELECT recovery_key FROM ticket_chat_answer_recoveries WHERE predecessor_command_key = ?", [key]) != nil

  defp current_ticket_binding(run, chat),
    do: {Map.take(run, ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch)), Map.take(chat, ~w(chat_key generation thread_id cwd))}

  defp apply_or_advance_ticket(context, run, chat, options) do
    commands = accepted_ticket_commands(context.store, run, chat)

    case amendment_command(context.store, commands) || List.first(commands) do
      nil -> ticket_idle_or_advance(context, run, options)
      key -> dispatch_accepted_ticket_command(context, run, chat, options, key)
    end
  end

  defp accepted_ticket_commands(store, run, chat) do
    Store.query!(store, "SELECT command_key FROM ticket_chat_commands WHERE chat_key = ? AND run_id = ? AND status = 'ACCEPTED' ORDER BY created_at, command_key", [
      chat["chat_key"],
      run["run_id"]
    ]).rows
    |> Enum.map(fn [key] -> key end)
  end

  defp ticket_idle_or_advance(context, run, options) do
    cond do
      run["state"] == "READY_FOR_REVIEW" ->
        {:ok, %{status: "READY_IDLE", model_invoked: false}}

      run["state"] == "WRITING" ->
        case installed_blocked_source_status(context.store, run) do
          :held -> {:ok, %{status: "SOURCE_HELD", model_invoked: false}}
          :resumed -> ticket_step_locked(context, run["run_id"], options)
          :not_held -> ticket_step_locked(context, run["run_id"], options)
          {:error, reason} -> {:error, reason}
        end

      true ->
        ticket_step_locked(context, run["run_id"], options)
    end
  end

  defp installed_blocked_source_status(store, run) do
    case TicketContractAmendment.blocked_predecessor_for_installed_run(store, run) do
      {:error, :blocked_amendment_predecessor_not_found} ->
        :not_held

      {:ok, %{receipt: receipt}} ->
        installed_blocked_source_receipt_status(store, receipt)
    end
  end

  defp installed_blocked_source_receipt_status(store, receipt) do
    with {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, evidence_snapshot} <- Jason.decode(predecessor["evidence_json"]),
         {:ok, evidence} <- WorkerEvidence.get(store, evidence_snapshot["request_key"]) do
      if WorkerEvidence.superseded_blocked_attempt?(store, evidence),
        do: :resumed,
        else: live_blocked_source_status(store, receipt)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_blocked_source_status(store, receipt) do
    case WorkspaceAccess.validate_blocked_amendment_predecessor(store, receipt) do
      :ok -> :held
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_accepted_ticket_command(context, run, chat, options, key) do
    case TicketChatCommands.get(context.store, key) do
      {:ok, %{"status" => "ACCEPTED", "payload_json" => payload}} ->
        dispatch_ticket_payload(context, run, chat, options, key, payload)

      _ ->
        apply_ordinary_ticket_command(context, run, chat, key)
    end
  end

  defp dispatch_ticket_payload(context, run, chat, options, key, payload) do
    case Jason.decode(payload) do
      {:ok, operations} when is_list(operations) ->
        dispatch_ticket_operations(context, run, chat, options, key, payload, operations)

      _ ->
        apply_ordinary_ticket_command(context, run, chat, key)
    end
  end

  defp dispatch_ticket_operations(context, run, chat, options, key, payload, operations) do
    if TicketChatCommands.rework_payload?(operations) do
      if run["state"] == "READY_FOR_REVIEW",
        do: launch_ready_ticket_rework(context, run, options, key),
        else: resume_blocked_ticket_command(context, run, chat, options, key)
    else
      dispatch_non_rework_ticket_payload(context, run, chat, options, key, payload)
    end
  end

  defp launch_ready_ticket_rework(context, run, options, command_key) do
    with {:ok, %{input: input}} <- TicketChatCommands.validate_ready_rework(context.store, command_key),
         review_run = Map.put(run, "state", "REVIEW_WRITING"),
         {:ok, authorization} <- ready_rework_authorization(context, run, options),
         :ok <- TicketWorkerRunner.validate_authorization(review_run, authorization),
         {:ok, stage} <- ticket_stage(review_run, context.factory, context.store),
         {:ok, base_prompt} <-
           TicketWorkerRunner.packet(context.store, run["run_id"], stage.role, Store.one!(context.store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])["base_sha"]),
         prompt = TicketWorkerRunner.ready_rework_packet(base_prompt, command_key, input["body"]),
         opts = ready_rework_launch_options(context, run, stage, authorization, command_key, input, prompt, options),
         result <-
           TaskLauncher.launch(
             context.store,
             context.task_supervisor,
             run,
             issue_from_snapshot(decode_json!(run["snapshot_json"])),
             run["worktree"],
             prompt,
             ReviewProtocol.schema_json(prompt, StageSchemas.for_stage(stage.schema)),
             opts
           ) do
      case result do
        {:ok, launch} -> {:ok, %{status: "LAUNCHED", launch: launch}}
        {:already_running, task} -> {:ok, %{status: "RUNNING", task: task}}
        {:already_terminal, task} -> {:ok, %{status: "RECOVERED", task: task}}
        error -> error
      end
    else
      {:error, reason} -> {:error, {:ready_rework_admission_failed, reason}}
    end
  end

  defp ready_rework_authorization(context, run, options) do
    reader = Keyword.get(options, :jira_reader, JiraMcpReader)
    read_opts = [workspace: context.workspace_root, store: context.store, connector: Map.get(context, :jira_connector) || JiraMcpConnector, app_server: Map.get(context, :jira_app_server, AppServer)]

    with {:ok, snapshot} <- reader.issue(run["issue_key"], read_opts) do
      TicketWorkerRunner.ready_rework_authorization(run, snapshot, DateTime.utc_now())
    end
  end

  defp ready_rework_launch_options(context, run, stage, authorization, command_key, input, prompt, options) do
    options = ticket_runtime_options(context, options)

    Keyword.merge(options,
      authorization: authorization,
      task_key: stage.key,
      stage: "REVIEW_WRITING",
      role: stage.role,
      model_policy: context.factory.models,
      risk: run["risk"],
      risk_signals: decode_json(run["risk_signals_json"], []),
      project_id: nil,
      project_root: run["repo_path"],
      recipient: context.recipient,
      thread_name: task_name(run["issue_key"], "Feature Writer"),
      review_base_sha: Store.one!(context.store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])["base_sha"],
      expected_sha: run["candidate_sha"],
      resume_terminal: true,
      ready_rework: %{command_key: command_key, input_key: input["input_key"], input_body: input["body"], prompt: prompt}
    )
  end

  defp dispatch_non_rework_ticket_payload(context, run, chat, options, key, payload) do
    case Jason.decode(payload) do
      {:ok, operations} when is_list(operations) and operations != [] ->
        if match?(%{"operation" => "propose_contract_revision"}, List.last(operations)) do
          consume_ticket_amendment(context, run, chat, options, key)
        else
          apply_ordinary_ticket_command(context, run, chat, key)
        end

      _ ->
        apply_ordinary_ticket_command(context, run, chat, key)
    end
  end

  defp apply_ordinary_ticket_command(context, run, chat, key) do
    controller_context = ticket_command_context(run, chat)
    command_application_result(TicketChatCommands.apply_accepted(context.store, key, controller_context), key)
  end

  defp amendment_command(store, commands) do
    first = List.first(commands)

    correction =
      Enum.find(commands, fn key ->
        case accepted_contract_proposal(store, key) do
          {:ok, %{supersedes: %{predecessor_command_key: ^first}}} when key != first -> true
          _ -> false
        end
      end)

    correction || if(first && match?({:ok, _}, accepted_contract_proposal(store, first)), do: first)
  end

  defp accepted_contract_proposal(store, key) do
    case TicketChatCommands.get(store, key) do
      {:ok, %{"status" => "ACCEPTED", "payload_json" => payload}} ->
        if contract_proposal_payload?(payload),
          do: TicketChatCommands.validate_contract_amendment(store, key),
          else: {:error, :unsupported_command_operations}

      _ ->
        {:error, :ticket_command_not_accepted}
    end
  end

  defp contract_proposal_payload?(payload) do
    case Jason.decode(payload) do
      {:ok, operations} when is_list(operations) and operations != [] ->
        match?(%{"operation" => "propose_contract_revision"}, List.last(operations))

      _ ->
        false
    end
  end

  defp ticket_command_context(run, chat) do
    %{
      "chat_key" => chat["chat_key"],
      "run_id" => run["run_id"],
      "binding" => Map.take(run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", chat["generation"])
    }
  end

  defp consume_ticket_amendment(context, run, chat, options, key) do
    controller_context = ticket_command_context(run, chat)
    model_policy = context.factory.models
    workspace = controller_workspace(context)
    jira_options = amendment_jira_options(context, options, workspace)

    with {:ok, _amendment} <- TicketContractAmendment.reserve(context.store, key, controller_context),
         {:ok, _draft} <- TicketAmendmentJiraOperation.publish_draft(context.store, key, controller_context, jira_options),
         {:ok, draft} <- TicketAmendmentJiraOperation.readback(context.store, key),
         {:ok, critique} <- prepare_or_reuse_amendment_critic(context.store, key, controller_context, draft, workspace, model_policy, options),
         true <- critique["qualifies"] == true or {:error, :amendment_critic_non_authorizing},
         {:ok, _authorization} <- TicketAmendmentJiraOperation.publish_authorization(context.store, key, controller_context, model_policy, jira_options),
         {:ok, _applied} <- TicketContractAmendment.apply_authorized(context.store, key, controller_context, model_policy) do
      {:ok, %{status: "AMENDMENT_APPLIED", command_key: key, model_invoked: true}}
    else
      {:error, reason} -> {:ok, %{status: "AMENDMENT_DEFERRED", command_key: key, reason: reason, model_invoked: false}}
    end
  end

  defp prepare_or_reuse_amendment_critic(store, key, controller_context, draft, workspace, model_policy, options) do
    case TicketContractAmendment.get_critic_attempt(store, key, model_policy) do
      {:ok, _recorded_or_prepared} ->
        execute_amendment_critic(store, key, controller_context, workspace, model_policy, options)

      {:error, :critic_attempt_not_prepared} ->
        with {:ok, _attempt} <-
               TicketContractAmendment.prepare_critic(
                 store,
                 key,
                 controller_context,
                 draft["readback_json"],
                 model_policy
               ) do
          execute_amendment_critic(store, key, controller_context, workspace, model_policy, options)
        end

      {:error, _} = error ->
        error
    end
  end

  defp execute_amendment_critic(store, key, controller_context, workspace, model_policy, options) do
    TicketAmendmentCritic.execute(
      store,
      key,
      controller_context,
      workspace,
      model_policy,
      critic_options(options)
    )
  end

  defp amendment_jira_options(context, options, workspace) do
    [
      workspace: workspace,
      jira_reader: Keyword.get(options, :jira_reader, context.jira_reader),
      jira_connector: Keyword.get(options, :jira_connector, context.jira_connector || JiraMcpConnector),
      app_server: context.jira_app_server || AppServer,
      jira_session: Keyword.get(options, :jira_session, &AppServer.with_jira_controller_session/2)
    ]
  end

  defp critic_options(options), do: Keyword.take(options, [:stage_runner, :app_server])

  defp resume_blocked_ticket_command(context, run, chat, options, command_key) do
    command = TicketChatCommands.get(context.store, command_key)

    with {:ok, %{"status" => "ACCEPTED", "input_key" => input_key}} <- command,
         input when is_map(input) <- Store.one!(context.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [input_key]),
         {:ok, task} <- TaskLedger.get(context.store, run["run_id"] <> ":feature-writer"),
         disposition when is_map(disposition) <- current_blocked_writer_disposition(context.store, run["run_id"], task["task_key"]) do
      resume = %{
        "command_key" => command_key,
        "input_key" => input_key,
        "request_key" => disposition["request_key"],
        "disposition_key" => disposition["disposition_key"],
        "thread_id" => task["thread_id"]
      }

      resume =
        case TicketContractAmendment.blocked_predecessor_for_request(context.store, disposition["request_key"]) do
          {:ok, receipt} ->
            predecessor = Jason.decode!(receipt["blocked_predecessor_json"])

            resume
            |> Map.put("amendment_command_key", receipt["command_key"])
            |> Map.put("checkout_head_sha", predecessor["checkout_head_sha"])

          _ ->
            resume
        end

      launch_ticket_stage(context, run, Keyword.put(options, :blocked_resume, resume))
      |> case do
        {:ok, %{status: "LAUNCHED", launch: launch}} -> {:ok, command_resumed(launch, command_key, input["body"], chat)}
        other -> other
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_blocked_rework_not_current}
    end
  end

  defp command_resumed(launch, command_key, input_body, chat),
    do: %{status: "COMMAND_RESUMED", launch: launch, command_key: command_key, input_body: input_body, chat: chat}

  defp current_blocked_writer_disposition(store, run_id, task_key) do
    Store.query!(store, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED' ORDER BY id DESC", [run_id]).rows
    |> Enum.map(fn [raw] -> Jason.decode!(raw) end)
    |> Enum.find(&(&1["task_key"] == task_key))
  end

  defp command_application_result({:ok, %{"status" => "APPLIED"} = command}, key),
    do: {:ok, %{status: "COMMAND_APPLIED", command_key: key, application_receipt_json: command["application_receipt_json"], model_invoked: false}}

  defp command_application_result({:ok, %{"status" => "REJECTED"} = command}, key),
    do: {:ok, %{status: "COMMAND_REJECTED", command_key: key, application_receipt_json: command["application_receipt_json"], model_invoked: false}}

  defp command_application_result({:ok, %{"status" => "ACCEPTED"}}, key),
    do: {:ok, %{status: "COMMAND_DEFERRED", command_key: key, reason: :unsupported_command_operations, model_invoked: false}}

  defp command_application_result({:ok, command}, key),
    do: {:ok, %{status: "COMMAND_DEFERRED", command_key: key, reason: command["status"], model_invoked: false}}

  defp command_application_result({:error, reason}, _key), do: {:error, {:ticket_command_application_deferred, reason}}

  defp ticket_delivery_pending(context, %{"state" => state} = run, options) when state in ~w(PUSHING MR_CREATING CI_PUSHING CI_MR_CREATING CI_WAITING) do
    options = ticket_runtime_options(context, options) |> Keyword.put(:workspace, controller_workspace(context)) |> Keyword.put(:ci_preflight_authorized, ci_preflight?(route_for_run(context, run)))

    lock = {{__MODULE__, :ticket_stage, run["run_id"]}, self()}

    case :global.trans(lock, fn -> ticket_delivery_step(context, run, options) end) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp ticket_delivery_pending(_context, _run, _options), do: {:ok, %{status: "DELIVERY_JOIN_PENDING"}}

  defp ticket_delivery_step(context, %{"state" => state} = run, options) when state in ~w(PUSHING CI_PUSHING) do
    with {:ok, authorization} <- ticket_authorization(context, run, options) do
      options =
        options
        |> Keyword.put(:ordinary_controller_tick, context[:ordinary_rejection_dispatch] == true)
        |> Keyword.put(:push_authorization_reader, fn current, prior -> ticket_authorization(context, current, options, prior) end)

      TicketPush.step(context.store, run["run_id"], authorization, options)
    end
  end

  defp ticket_delivery_step(context, %{"state" => "MR_CREATING", "mr_iid" => iid, "mr_url" => url} = run, options)
       when is_integer(iid) and iid > 0 and is_binary(url) and url != "" do
    with {:ok, authorization} <- ticket_authorization(context, run, options) do
      adopted_mr_delivery_step(context, run, options, authorization)
    end
  end

  defp ticket_delivery_step(context, %{"state" => state} = run, options) when state in ~w(MR_CREATING CI_MR_CREATING) do
    with {:ok, authorization} <- ticket_authorization(context, run, options) do
      options = Keyword.put(options, :ticket_mr_ephemeral_read, true)

      case TicketMrOperation.adopt_result(context.store, run["run_id"], authorization, context.factory, options) do
        {:error, :unknown_request} ->
          TicketMrOperation.prepare(context.store, run["run_id"], authorization, context.factory, controller_workspace(context), mr_description(run), options)

        result ->
          result
      end
    end
  end

  defp ticket_delivery_step(context, %{"state" => "CI_WAITING"} = run, options) do
    if ci_poll_due?(run["ci_last_checked_at"]) do
      with {:ok, authorization} <- ticket_authorization(context, run, options) do
        TicketMrOperation.adopt_ci(context.store, run["run_id"], authorization, context.factory, Keyword.put(options, :ticket_mr_ephemeral_read, true))
      end
    else
      {:ok, %{status: "CI_POLL_WAIT"}}
    end
  end

  defp ticket_delivery_step(context, run, options) do
    with {:ok, authorization} <- ticket_authorization(context, run, options),
         {:ok, _} <- TicketWorkerRunner.delivery_admission(context.store, run, authorization, options) do
      {:ok, %{status: "DELIVERY_JOIN_PENDING"}}
    end
  end

  defp adopted_mr_delivery_step(context, run, options, authorization) do
    ephemeral_read_options = Keyword.put(options, :ticket_mr_ephemeral_read, true)

    case TicketMrOperation.adopt_result(context.store, run["run_id"], authorization, context.factory, ephemeral_read_options) do
      {:error, :unknown_request} ->
        TicketMrOperation.prepare(context.store, run["run_id"], authorization, context.factory, controller_workspace(context), mr_description(run), options)

      {:ok, %{status: "MR_WAITING_FOR_RESULT"}} = waiting ->
        waiting

      {:ok, %{status: status}} when status in ~w(MR_ADOPTED MR_ALREADY_ADOPTED) ->
        finalize_adopted_mr_delivery(context, run, options)

      other ->
        other
    end
  end

  defp finalize_adopted_mr_delivery(context, run, options) do
    with {:ok, _receipt} <- TicketMrOperation.current_delivery_receipt(context.store, run["run_id"], context.factory, options),
         {:ok, _chat} <- TicketChat.ready_for_run(context.store, run["run_id"]) do
      finalization_options =
        options
        |> Keyword.put(:workspace, controller_workspace(context))
        |> Keyword.put_new(:jira_connector, Map.get(context, :jira_connector) || JiraMcpConnector)
        |> Keyword.put_new(:jira_app_server, Map.get(context, :jira_app_server, AppServer))

      case TicketJiraFinalization.finish(context.store, run["run_id"], context.factory, finalization_options) do
        {:ok, _} = result -> result
        {:error, _} = error -> error
      end
    else
      {:error, _} = error -> error
    end
  end

  defp advance_run(context, workspace, run, acc) do
    case validate_run_transport(context, run) do
      :quarantined ->
        {:ok, acc}

      :ok ->
        case validate_run_snapshot(context, run) do
          :ok -> advance_valid_run(context, workspace, run, acc)
          {:cancel, reason} -> cancel_run(context, run, reason, acc)
          {:error, reason} -> block_run(context, workspace, run, reason, acc)
        end

      {:error, reason} ->
        if reason == :invalid_execution_mode,
          do: {:error, reason},
          else: block_run(context, workspace, run, reason, acc)
    end
  end

  defp validate_run_transport(context, run) do
    case run["execution_mode"] do
      nil -> validate_legacy_run_transport(context, run)
      "LEGACY" -> validate_legacy_run_transport(context, run)
      "TICKET_SUPERVISOR_V1" -> :quarantined
      _other -> {:error, :invalid_execution_mode}
    end
  end

  defp validate_legacy_run_transport(context, run) do
    if native_transport?(context) == (run["factory_owned"] == 0),
      do: :ok,
      else: {:error, :factory_task_transport_changed}
  end

  defp advance_valid_run(context, workspace, %{"kind" => "SPECIFICATION"} = run, acc) do
    advance_specification(context, workspace, run, acc)
  end

  defp advance_valid_run(context, workspace, %{"kind" => kind} = run, acc)
       when kind in ["DELIVERY", "VALIDATION"] do
    advance_delivery(context, workspace, run, acc)
  end

  defp validate_run_snapshot(context, run) do
    snapshot = decode_json(run["snapshot_json"], %{})
    status = snapshot_value(snapshot, "status") |> normalize_status()
    allowed_statuses = context.factory.queue |> Map.get("statuses", []) |> Enum.map(&normalize_status/1)
    labels = normalized_labels(snapshot)

    with :ok <- validate_status(status, allowed_statuses, snapshot, run, labels),
         :ok <- validate_kind_labels(run, labels) do
      validate_authorization(run, snapshot)
    end
  end

  defp validate_status(status, allowed, snapshot, run, labels) do
    if status in allowed or in_dev_delivery?(status, run, labels) or in_dev_contract_update?(status, run, labels) do
      :ok
    else
      {:cancel, {:jira_status_left_factory_scope, snapshot_value(snapshot, "status")}}
    end
  end

  defp in_dev_delivery?("IN DEV", %{"kind" => "DELIVERY"} = run, labels) do
    Enum.any?(["ai-running", "ai-ready"], &(&1 in labels)) or
      (review_rework?(run) and "ai-review" in labels)
  end

  defp in_dev_delivery?(_status, _run, _labels), do: false

  defp in_dev_contract_update?("IN DEV", %{"kind" => "SPECIFICATION"} = run, labels),
    do: present?(run["parent_run_id"]) and "ai-running" in labels

  defp in_dev_contract_update?(_status, _run, _labels), do: false

  defp validate_kind_labels(%{"kind" => "SPECIFICATION"} = run, labels) do
    contract_update? = present?(run["parent_run_id"]) and "ai-running" in labels

    if contract_update? or Enum.any?(["spec-needed", "needs-decision"], &(&1 in labels)) do
      :ok
    else
      {:cancel, :specification_labels_removed}
    end
  end

  defp validate_kind_labels(%{"kind" => "DELIVERY"} = run, labels) do
    if delivery_label?(labels) or (review_rework?(run) and "ai-review" in labels),
      do: :ok,
      else: {:cancel, :delivery_labels_removed}
  end

  defp validate_kind_labels(%{"kind" => "VALIDATION"}, labels) do
    if "ai-testing" in labels, do: :ok, else: {:cancel, :validation_label_removed}
  end

  defp validate_authorization(%{"kind" => "SPECIFICATION"}, _snapshot), do: :ok

  defp validate_authorization(run, snapshot) do
    if Contract.authorized?(snapshot, bound_contract(run)) do
      :ok
    else
      {:error, :confirmed_authorization_stale}
    end
  end

  defp validate_delivery_authorization(context, snapshot, contract) do
    case Contract.automatic_authorization_proof(snapshot, contract) do
      :none -> :ok
      {:ok, proof} -> validate_automatic_critic_evidence(context.store, contract, proof)
      {:error, _reason} -> {:error, :automatic_critic_evidence_missing}
    end
  end

  defp validate_automatic_critic_evidence(store, contract, proof) do
    with {:ok, task} <- TaskLedger.get(store, proof.critic_task_key),
         true <- is_binary(task["output_json"]),
         {:ok, spec_run} <- RunLedger.get(store, task["run_id"]),
         {:ok, output} <- Jason.decode(task["output_json"]),
         true <-
           task["role"] == "specification-critic" and task["status"] == "CONSUMED" and
             spec_run["kind"] == "SPECIFICATION" and spec_run["state"] == "DELIVERED" and
             spec_run["issue_key"] == contract.issue_key and spec_run["contract_sha256"] == contract.sha256 and
             Contract.digest(task["output_json"]) == proof.critic_output_sha256 and
             output == %{"status" => "PASS", "findings" => [], "required_questions" => []} do
      :ok
    else
      _other -> {:error, :automatic_critic_evidence_missing}
    end
  end

  defp delivery_label?(labels) do
    Enum.any?(["ai-ready", "ai-running", "ai-verifying", "ai-testing"], &(&1 in labels))
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_DRAFTING"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    snapshot = Map.put(snapshot, "factory_repair_findings", decode_json(run["repair_findings_json"], []))
    route = route_for_run(context, run)
    task_key = "#{run["run_id"]}:specification-author"

    with {:ok, specification_path} <- specification_workspace(context, run, route, task_key),
         {:ok, expected_sha} <- specification_expected_sha(context, route, task_key) do
      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: specification_path,
        prompt:
          Prompt.specification_author(snapshot, route, run["spec_revision"]) <>
            specification_answer_prompt(snapshot, run["last_input_marker"]),
        schema: StageSchemas.for_stage(:specification_author),
        task_key: task_key,
        stage: "SPEC_DRAFTING",
        role: "specification-author",
        thread_name: task_name(run["issue_key"], "Specification Author"),
        persistent?: true,
        expected_sha: expected_sha,
        format_repair_attempts: 1
      }

      launch_or_consume(context, run, stage, acc, &consume_specification_author(context, run, &1, &2))
    else
      {:error, reason} ->
        block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "CONTRACT_DISCUSSING"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    route = route_for_run(context, run)
    task_key = "#{run["run_id"]}:contract-update"

    with {:ok, %{"kind" => "DELIVERY", "state" => "FAILED"} = failed} <-
           RunLedger.get(context.store, run["parent_run_id"]),
         {:ok, specification_path, expected_sha, workspace_mode} <-
           contract_discussion_workspace(context, run, route, task_key) do
      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: specification_path,
        prompt:
          Prompt.contract_revision(
            snapshot,
            route,
            failed,
            run["spec_revision"],
            ContractChat.reply(context.store, run["run_id"]),
            decode_json(run["repair_findings_json"], [])
          ),
        schema: StageSchemas.for_stage(:specification_author),
        task_key: task_key,
        stage: "CONTRACT_DISCUSSING",
        role: "specification-author",
        thread_name: task_name(run["issue_key"], "Contract Update"),
        persistent?: true,
        expected_sha: expected_sha,
        workspace_mode: workspace_mode,
        format_repair_attempts: 1
      }

      launch_or_consume(context, run, stage, acc, &consume_contract_author(context, run, task_key, &1, &2))
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_specification(context, _workspace, %{"state" => "AWAITING_CONTRACT_INPUT"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])

    if ContractChat.question_source_current?(context.store, run["run_id"], snapshot) do
      {:ok, acc}
    else
      with :ok <- ContractChat.invalidate_question(context.store, run["run_id"]) do
        {:ok, add_event(acc, run["issue_key"], "CONTRACT_CHAT_INPUT_CHANGED", nil)}
      end
    end
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_WRITING"} = run, acc) do
    contract = bound_contract(run)
    comment = Contract.draft_comment(contract)

    operation = "Add exactly one Jira comment whose complete plain-text body is:\n#{comment}"

    with {:ok, output} <-
           jira_write(context, workspace, run, operation, contract.marker,
             mutations: [:comment],
             approved_comment_body: comment
           ),
         true <- output["status"] == "PASS" or {:error, :jira_spec_write_failed},
         {:ok, snapshot} <- fetch_issue(context, workspace, run["issue_key"]),
         true <- Contract.draft_read_back?(snapshot, contract) or {:error, :jira_spec_readback_mismatch},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "SPEC_REVIEW",
             spec_comment_id: output["comment_id"],
             snapshot_json: Jason.encode!(snapshot),
             verifier_round: run["verifier_round"] + 1
           }) do
      {:ok, add_event(acc, run["issue_key"], "SPEC_DRAFT_READ_BACK", contract.sha256)}
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_REVIEW"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    route = route_for_run(context, run)
    task_key = "#{run["run_id"]}:specification-critic:#{run["verifier_round"]}"

    case stage_workspace(context, run, route, task_key, "specification-critic-#{run["verifier_round"]}", :base) do
      {:ok, critic_path, expected_sha} ->
        stage = %{
          issue: issue_from_snapshot(snapshot),
          workspace: critic_path,
          prompt: Prompt.specification_critic(snapshot, run["contract_markdown"], run["contract_sha256"]),
          schema: StageSchemas.for_stage(:specification_critic),
          task_key: task_key,
          stage: "SPEC_REVIEW",
          role: "specification-critic",
          thread_name: task_name(run["issue_key"], "Specification Critic", run["verifier_round"]),
          persistent?: false,
          expected_sha: expected_sha,
          format_repair_attempts: 1
        }

        launch_or_consume(
          context,
          run,
          stage,
          acc,
          &consume_specification_critic(context, run, route, critic_path, &1, &2)
        )

      {:error, reason} ->
        block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_READY_WRITE"} = run, acc) do
    if automatic_specification_authorization?(context) do
      authorize_specification_automatically(context, workspace, run, acc)
    else
      request_human_specification_confirmation(context, workspace, run, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "AWAITING_CONFIRMATION"} = run, acc) do
    if automatic_specification_authorization?(context) do
      authorize_specification_automatically(context, workspace, run, acc)
    else
      finish_human_specification_confirmation(context, workspace, run, acc)
    end
  end

  defp advance_specification(context, _workspace, %{"state" => "AWAITING_SPEC_INPUT"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])

    case Contract.specification_input(snapshot, run["issue_key"], run["last_input_marker"]) do
      {:ok, comment} ->
        RunLedger.update(context.store, run["run_id"], %{
          state: "SPEC_DRAFTING",
          attempt: 0,
          repair_findings_json: Jason.encode!([]),
          snapshot_json: Jason.encode!(snapshot),
          last_input_marker: to_string(snapshot_value(comment, "id"))
        })

        {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_INPUT_RECEIVED", snapshot_value(comment, "id"))}

      :missing ->
        {:ok, acc}
    end
  end

  defp advance_specification(_context, _workspace, _run, acc), do: {:ok, acc}

  defp request_human_specification_confirmation(context, workspace, run, acc) do
    contract = bound_contract(run)
    ready = Contract.ready_marker(contract)
    confirmation = Contract.confirmation_marker(contract)

    body = "#{ready}\n\nIndependent specification review passed. To authorize implementation, add this exact Jira comment:\n#{confirmation}"
    operation = "Add exactly one Jira comment whose complete plain-text body is:\n#{body}"

    with {:ok, %{"status" => "PASS"}} <-
           jira_write(context, workspace, run, operation, ready,
             mutations: [:comment],
             approved_comment_body: body
           ),
         {:ok, _updated} <- RunLedger.update(context.store, run["run_id"], %{state: "AWAITING_CONFIRMATION"}) do
      {:ok, add_event(acc, run["issue_key"], "HUMAN_CONFIRMATION_REQUIRED", confirmation)}
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      _other -> block_run(context, workspace, run, :jira_ready_marker_failed, acc)
    end
  end

  defp finish_human_specification_confirmation(context, workspace, run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    contract = bound_contract(run)

    case Contract.confirmation(snapshot, contract) do
      {:ok, comment} ->
        comment_id = to_string(snapshot_value(comment, "id"))
        authorization = Contract.authorization_marker(contract, comment_id)
        label_remove = specification_authorization_label_remove(run)

        operation =
          "Add exactly one comment with body `#{authorization}`; add label `ai-ready`; " <>
            "remove labels #{Enum.join(label_remove, ", ")}; preserve all other labels."

        with {:ok, %{"status" => "PASS", "labels" => labels}} <-
               jira_write(context, workspace, run, operation, authorization,
                 approved_comment_body: authorization,
                 label_add: ["ai-ready"],
                 label_remove: label_remove
               ),
             true <- "ai-ready" in normalize_strings(labels) or {:error, :ai_ready_readback_missing},
             :ok <- remove_optional_detached(context, run),
             {:ok, _updated} <-
               RunLedger.update(context.store, run["run_id"], %{
                 state: "DELIVERED",
                 confirmation_comment_id: comment_id,
                 worktree: if(run["factory_owned"] == 0, do: run["worktree"], else: nil),
                 workspace_state: if(present?(run["worktree"]), do: "CODEX_NATIVE", else: "UNMATERIALIZED")
               }) do
          {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_AUTHORIZED", contract.sha256)}
        else
          {:error, reason} -> block_run(context, workspace, run, reason, acc)
          _other -> block_run(context, workspace, run, :authorization_write_failed, acc)
        end

      :missing ->
        {:ok, acc}
    end
  end

  defp automatic_specification_authorization?(context) do
    Map.get(context.factory, :specification_authorization_mode, "auto_after_critic") == "auto_after_critic"
  end

  defp specification_authorization_label_remove(run) do
    labels = ["spec-needed", "needs-decision", "ai-blocked"]

    if present?(run["parent_run_id"]), do: labels ++ ["ai-running", "ai-verifying"], else: labels
  end

  defp authorize_specification_automatically(context, workspace, run, acc) do
    contract = bound_contract(run)
    critic_task_key = "#{run["run_id"]}:specification-critic:#{run["verifier_round"]}"
    snapshot = decode_json!(run["snapshot_json"])
    label_remove = specification_authorization_label_remove(run)

    with {:ok, critic_digest} <- verified_critic_digest(context, critic_task_key, snapshot, contract),
         {:ok, current} <- fetch_issue(context, workspace, run["issue_key"]),
         true <-
           specification_input(current) == specification_input(snapshot) or
             {:error, :specification_input_changed},
         true <- Contract.draft_read_back?(current, contract) or {:error, :specification_draft_stale},
         authorization = Contract.automatic_authorization_marker(contract, critic_task_key, critic_digest),
         operation =
           "Add exactly one comment with body `#{authorization}`; add label `ai-ready`; " <>
             "remove labels #{Enum.join(label_remove, ", ")}; preserve all other labels.",
         {:ok, %{"status" => "PASS", "labels" => labels}} <-
           jira_write(context, workspace, run, operation, authorization,
             approved_comment_body: authorization,
             label_add: ["ai-ready"],
             label_remove: label_remove
           ),
         true <- "ai-ready" in normalize_strings(labels) or {:error, :ai_ready_readback_missing},
         {:ok, authorized_snapshot} <- fetch_issue(context, workspace, run["issue_key"]),
         true <-
           Contract.authorized?(authorized_snapshot, contract) or
             {:error, :automatic_authorization_readback_mismatch},
         :ok <- remove_optional_detached(context, run),
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "DELIVERED",
             snapshot_json: Jason.encode!(authorized_snapshot),
             worktree: if(run["factory_owned"] == 0, do: run["worktree"], else: nil),
             workspace_state: if(present?(run["worktree"]), do: "CODEX_NATIVE", else: "UNMATERIALIZED")
           }) do
      {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_AUTO_AUTHORIZED", contract.sha256)}
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      _other -> block_run(context, workspace, run, :automatic_authorization_failed, acc)
    end
  end

  defp verified_critic_digest(context, task_key, snapshot, contract) do
    with {:ok, %{"status" => "CONSUMED", "output_json" => output_json} = task} when is_binary(output_json) <-
           TaskLedger.get(context.store, task_key),
         true <- critic_prompt_current?(context, task, snapshot, contract),
         {:ok, %{"status" => "PASS", "findings" => [], "required_questions" => []}} <- Jason.decode(output_json) do
      {:ok, Contract.digest(output_json)}
    else
      _other -> {:error, :independent_critic_pass_not_proven}
    end
  end

  defp critic_prompt_current?(context, task, snapshot, contract) do
    if native_transport?(context) do
      case RunLedger.get(context.store, task["run_id"]) do
        {:ok, run} ->
          run["issue_key"] == contract.issue_key and run["spec_revision"] == contract.revision and
            run["contract_sha256"] == contract.sha256 and not stale_native_critic_input?(context, run, task)

        _other ->
          false
      end
    else
      expected =
        snapshot
        |> Prompt.specification_critic(contract.markdown, contract.sha256)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      task["prompt_sha256"] == expected
    end
  end

  defp specification_workspace(context, run, route, task_key) do
    if Map.get(context.factory, :task_transport) == "desktop_broker" do
      native_specification_workspace(context, run, route, task_key)
    else
      factory_specification_workspace(context, run, route, task_key)
    end
  end

  defp contract_discussion_workspace(context, run, route, task_key) do
    cond do
      not native_transport?(context) ->
        with {:ok, path} <- specification_workspace(context, run, route, task_key),
             {:ok, sha} <- specification_expected_sha(context, route, task_key) do
          {:ok, path, sha, nil}
        end

      legacy_native_contract_chat?(context.store, task_key) ->
        with {:ok, path} <- specification_workspace(context, run, route, task_key),
             {:ok, sha} <- specification_expected_sha(context, route, task_key) do
          {:ok, path, sha, "CODEX_NATIVE"}
        end

      true ->
        {:ok, route["path"], nil, "CODEX_PROJECT_LOCAL"}
    end
  end

  defp legacy_native_contract_chat?(store, task_key) do
    case TaskLedger.get(store, task_key) do
      {:ok, %{"workspace_sha" => sha}} when is_binary(sha) and sha != "" -> true
      _other -> false
    end
  end

  defp native_specification_workspace(context, run, route, task_key) do
    case TaskLedger.get(context.store, task_key) do
      {:ok, %{"workspace" => path, "workspace_sha" => sha}} when is_binary(path) and is_binary(sha) ->
        with {:ok, verified} <- context.worktree.validate_native(route, path, expected_sha: sha) do
          {:ok, verified.path}
        end

      {:ok, %{"thread_id" => thread_id}} when is_binary(thread_id) and thread_id != "" ->
        {:error, :native_specification_workspace_unbound}

      _other ->
        if is_nil(run["worktree"]), do: {:ok, route["path"]}, else: {:error, :native_run_workspace_conflict}
    end
  end

  defp specification_expected_sha(context, route, task_key) do
    if Map.get(context.factory, :task_transport) == "desktop_broker" do
      case TaskLedger.get(context.store, task_key) do
        {:ok, %{"workspace_sha" => sha}} when is_binary(sha) -> {:ok, sha}
        _other -> context.worktree.base_sha(route)
      end
    else
      {:ok, nil}
    end
  end

  defp native_transport?(context), do: Map.get(context.factory, :task_transport) == "desktop_broker"

  defp stage_workspace(context, run, route, task_key, stage, sha_source) do
    if native_transport?(context) do
      native_stage_workspace(context, route, task_key, sha_source)
    else
      with {:ok, sha} <- stage_sha(context, route, sha_source),
           {:ok, path} <- create_stage_worktree(context, run, route, stage, sha) do
        {:ok, path, nil}
      end
    end
  end

  defp native_stage_workspace(context, route, task_key, sha_source) do
    case TaskLedger.get(context.store, task_key) do
      {:ok, task} ->
        native_existing_stage_workspace(context, route, task)

      {:error, :unknown_task} ->
        with {:ok, sha} <- stage_sha(context, route, sha_source) do
          {:ok, route["path"], sha}
        end
    end
  end

  defp native_existing_stage_workspace(context, route, %{"workspace" => path, "workspace_sha" => sha})
       when is_binary(path) and path != "" and is_binary(sha) and sha != "" do
    with {:ok, verified} <- context.worktree.validate_native(route, path, expected_sha: sha) do
      {:ok, verified.path, sha}
    end
  end

  defp native_existing_stage_workspace(_context, _route, %{"thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "",
       do: {:error, :native_stage_workspace_unbound}

  defp native_existing_stage_workspace(_context, route, %{"workspace_sha" => sha, "status" => status})
       when is_binary(sha) and sha != "" and
              status in ["STARTING", "RUNNING", "WAITING_FOR_BROKER", "WAITING_FOR_WRITER", "RETRY_PENDING"],
       do: {:ok, route["path"], sha}

  defp native_existing_stage_workspace(_context, _route, _task), do: {:error, :native_stage_sha_unbound}

  defp stage_sha(context, route, :base), do: context.worktree.base_sha(route)
  defp stage_sha(_context, _route, sha) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp stage_sha(_context, _route, _sha), do: {:error, :stage_sha_missing}

  defp create_stage_worktree(context, run, route, stage, sha) do
    if String.starts_with?(stage, "specification-critic-") do
      context.worktree.create_detached_pinned(route, run["issue_key"], run["run_id"], stage, sha)
    else
      context.worktree.create_detached(route, run["issue_key"], run["run_id"], stage, sha)
    end
  end

  defp remove_stage_workspace(_context, %{"factory_owned" => 0}, _route, _path), do: :ok

  defp remove_stage_workspace(context, _run, route, path) do
    context.worktree.remove_detached(route, path)
  end

  defp factory_specification_workspace(context, run, route, task_key) do
    case TaskLedger.get(context.store, task_key) do
      {:ok, %{"thread_id" => thread_id}} when is_binary(thread_id) and thread_id != "" ->
        validate_specification_workspace(context.worktree, route, run["worktree"])

      {:ok, _task} ->
        if is_binary(run["worktree"]) and File.dir?(run["worktree"]) do
          validate_specification_workspace(context.worktree, route, run["worktree"])
        else
          materialize_specification_workspace(context, run, route)
        end

      _other ->
        materialize_specification_workspace(context, run, route)
    end
  end

  defp materialize_specification_workspace(context, run, route) do
    with {:ok, base_sha} <- context.worktree.base_sha(route),
         {:ok, path} <-
           context.worktree.create_detached(route, run["issue_key"], run["run_id"], "specification", base_sha),
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             worktree: path,
             workspace_state: "MATERIALIZED",
             hibernated_at: nil
           }) do
      {:ok, path}
    end
  end

  defp validate_specification_workspace(worktree, route, path) when is_binary(path) do
    if File.dir?(path) do
      case worktree.validate_detached(route, path) do
        {:ok, _pinned} -> {:ok, path}
        {:error, _reason} = error -> error
      end
    else
      {:error, :specification_worktree_missing}
    end
  end

  defp validate_specification_workspace(_worktree, _route, _path),
    do: {:error, :specification_worktree_missing}

  defp consume_specification_author(context, run, output, acc) do
    case output do
      %{"status" => "DRAFTED"} ->
        accept_specification_draft(context, run, output, acc)

      %{"status" => "BLOCKED", "questions" => questions} ->
        request_specification_input(context, run, questions, acc)

      _other ->
        {:error, :invalid_specification_author_output}
    end
  end

  defp consume_contract_author(context, run, task_key, output, acc) do
    case output do
      %{"status" => "DRAFTED"} ->
        with :ok <- ContractChat.consume_reply(context.store, run["run_id"]) do
          accept_specification_draft(context, run, output, acc)
        end

      %{"status" => "BLOCKED", "questions" => questions} ->
        with {:ok, task} <- TaskLedger.get(context.store, task_key),
             {:ok, %{question_sha256: digest}} <- ContractChat.wait(context.store, run, task, questions) do
          {:ok, add_event(acc, run["issue_key"], "CONTRACT_CHAT_INPUT_REQUIRED", digest)}
        end

      _other ->
        {:error, :invalid_contract_author_output}
    end
  end

  defp accept_specification_draft(context, run, output, acc) do
    %{
      "contract_markdown" => markdown,
      "risk" => risk,
      "risk_signals" => risk_signals,
      "manual_validation_required" => manual_required
    } = output

    revision = run["spec_revision"]
    snapshot = decode_json!(run["snapshot_json"])

    with true <- revision == Contract.next_revision(snapshot) or {:error, :specification_revision_state_changed},
         {:ok, normalized} <- Contract.normalize_draft_revision(markdown, revision),
         {:ok, ^manual_required} <- Contract.manual_validation_required(normalized),
         contract <- Contract.bind(run["issue_key"], revision, normalized),
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "SPEC_WRITING",
             contract_markdown: contract.markdown,
             contract_sha256: contract.sha256,
             manual_validation_required: manual_required,
             risk: risk,
             risk_signals_json: Jason.encode!(risk_signals),
             repair_findings_json: Jason.encode!([])
           }) do
      {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_DRAFTED", contract.sha256)}
    else
      {:ok, _other} -> {:error, :manual_validation_decision_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_specification_input(context, run, questions, acc) do
    questions_sha256 = Contract.questions_digest(questions)
    marker = Contract.input_marker(run["issue_key"], questions_sha256)

    body = Contract.input_request_comment(run["issue_key"], questions)

    operation =
      "Add exactly one Jira comment whose complete plain-text body is:\n#{body}\n" <>
        "Add label `needs-decision`; preserve `spec-needed` and all other labels."

    with {:ok, %{"status" => "PASS"}} <-
           jira_write(context, controller_workspace(context), run, operation, questions_sha256,
             approved_comment_body: body,
             label_add: ["needs-decision"]
           ),
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "AWAITING_SPEC_INPUT",
             last_input_marker: questions_sha256,
             repair_findings_json: Jason.encode!(questions)
           }) do
      {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_INPUT_REQUIRED", marker)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :specification_question_write_failed}
    end
  end

  defp consume_specification_critic(context, run, route, critic_path, output, acc) do
    with :ok <- remove_stage_workspace(context, run, route, critic_path) do
      consume_specification_critic_output(context, run, output, acc)
    end
  end

  defp consume_specification_critic_output(context, run, %{"status" => "PASS", "findings" => [], "required_questions" => []}, acc) do
    RunLedger.update(context.store, run["run_id"], %{state: "SPEC_READY_WRITE"})
    {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_REVIEW_PASSED", nil)}
  end

  defp consume_specification_critic_output(
         context,
         %{"parent_run_id" => parent} = run,
         %{"status" => status, "findings" => findings, "required_questions" => questions},
         acc
       )
       when is_binary(parent) and status in ["REPAIR", "BLOCK"] do
    repair_specification_or_request_input(context, run, findings, questions, acc)
  end

  defp consume_specification_critic_output(
         context,
         run,
         %{"status" => "REPAIR", "findings" => findings, "required_questions" => questions},
         acc
       ) do
    repair_specification_or_request_input(context, run, findings, questions, acc)
  end

  defp consume_specification_critic_output(
         context,
         run,
         %{"status" => status, "findings" => findings, "required_questions" => [_first | _rest] = questions},
         acc
       )
       when status in ["REPAIR", "BLOCK"] do
    request_specification_input(context, run, findings ++ questions, acc)
  end

  defp consume_specification_critic_output(
         _context,
         _run,
         %{"status" => status, "findings" => findings, "required_questions" => []},
         _acc
       )
       when status in ["REPAIR", "BLOCK"] do
    {:error, {:specification_review_blocked, findings}}
  end

  defp consume_specification_critic_output(_context, _run, _output, _acc) do
    {:error, :invalid_specification_critic_output}
  end

  defp repair_specification_or_request_input(context, run, findings, questions, acc) do
    if run["attempt"] < 3 do
      snapshot = decode_json!(run["snapshot_json"])
      revision = Contract.next_revision(snapshot)
      draft_proven? = Contract.draft_read_back?(snapshot, bound_contract(run))

      with true <- draft_proven? or {:error, :specification_repair_draft_unproven},
           true <- revision == run["spec_revision"] + 1 or {:error, :specification_repair_revision_unproven},
           {:ok, _updated} <-
             RunLedger.update(context.store, run["run_id"], %{
               state: if(present?(run["parent_run_id"]), do: "CONTRACT_DISCUSSING", else: "SPEC_DRAFTING"),
               attempt: run["attempt"] + 1,
               spec_revision: revision,
               contract_markdown: nil,
               contract_sha256: nil,
               spec_comment_id: nil,
               manual_validation_required: nil,
               repair_findings_json: Jason.encode!(findings ++ questions)
             }) do
        {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_REPAIR", findings ++ questions)}
      end
    else
      request_input_or_block(context, run, findings, questions, acc)
    end
  end

  defp request_input_or_block(context, run, findings, [_first | _rest] = questions, acc) do
    request_specification_input(context, run, findings ++ questions, acc)
  end

  defp request_input_or_block(_context, _run, findings, [], _acc) do
    {:error, {:specification_review_blocked, findings}}
  end

  defp advance_delivery(context, workspace, %{"state" => "PLANNING"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    route = route_for_run(context, run)
    task_key = "#{run["run_id"]}:feature-planner"

    case stage_workspace(context, run, route, task_key, "planning", :base) do
      {:ok, planning_path, expected_sha} ->
        stage = %{
          issue: issue_from_snapshot(snapshot),
          workspace: planning_path,
          prompt: Prompt.feature_planner(snapshot, run["contract_markdown"], run["contract_sha256"], route),
          schema: StageSchemas.for_stage(:feature_planner),
          task_key: task_key,
          stage: "PLANNING",
          role: "feature-planner",
          thread_name: task_name(run["issue_key"], "Feature Planner"),
          persistent?: false,
          expected_sha: expected_sha,
          format_repair_attempts: 1
        }

        launch_or_consume(
          context,
          run,
          stage,
          acc,
          &consume_feature_planner(context, run, route, planning_path, &1, &2)
        )

      {:error, reason} ->
        block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "ADMITTING_WRITER"} = run, acc) do
    route = writer_route(context, run)

    with {:ok, _capacity} <- ensure_writer_capacity(context, run["repo_key"]),
         {:ok, writer} <- admit_writer_workspace(context, run, route),
         operation =
           "Add label `ai-running`; remove labels `ai-ready` and `ai-verifying`; preserve all other labels.",
         {:ok, %{"status" => "PASS", "labels" => labels}} <-
           jira_write(context, workspace, run, operation, "ai-running",
             mutations: [:labels],
             label_add: ["ai-running"],
             label_remove: ["ai-ready", "ai-verifying"]
           ),
         true <- "ai-running" in normalize_strings(labels) or {:error, :ai_running_readback_missing},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "WRITING",
             worktree: writer.path,
             branch: writer.branch,
             workspace_state: if(native_transport?(context), do: "UNMATERIALIZED", else: "MATERIALIZED"),
             hibernated_at: nil
           }) do
      {:ok, add_event(acc, run["issue_key"], "WRITER_ADMITTED", writer.path)}
    else
      {:error, {:insufficient_writer_capacity, _cleaned}} -> {:ok, acc}
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      _other -> block_run(context, workspace, run, :writer_admission_failed, acc)
    end
  end

  defp advance_delivery(context, _workspace, %{"state" => state} = run, acc)
       when state in ["WRITING", "REPAIRING", "REVIEW_WRITING"] do
    case ensure_run_writer(context, run, acc) do
      {:ok, materialized_run, updated_acc} -> advance_writer(context, materialized_run, updated_acc)
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp advance_delivery(context, _workspace, %{"state" => "VERIFYING"} = run, acc) do
    advance_verifier(context, run, acc)
  end

  defp advance_delivery(context, workspace, %{"state" => "REVIEW_PUSHING"} = run, acc) do
    advance_review_push(context, workspace, run, acc)
  end

  defp advance_delivery(context, workspace, %{"state" => "CI_PUSHING"} = run, acc) do
    route = route_for_run(context, run)

    with true <- ci_preflight?(route) or {:error, :ci_preflight_route_disabled},
         true <- context.worktree.reachable?(route, run["candidate_sha"]) or {:error, :candidate_unreachable},
         {:ok, _push} <-
           context.worktree.push_exact(route, run["worktree"], run["branch"], run["candidate_sha"]),
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "CI_MR_CREATING",
             ci_preflight_sha: run["candidate_sha"],
             ci_pipeline_id: nil,
             ci_pipeline_url: nil,
             ci_evidence_json: nil,
             ci_last_checked_at: nil
           }) do
      advance_delivery(context, workspace, %{run | "state" => "CI_MR_CREATING"}, acc)
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      false -> block_run(context, workspace, run, :candidate_unreachable, acc)
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "CI_MR_CREATING"} = run, acc) do
    route = route_for_run(context, run)

    case context.controller_task.run(
           context.factory,
           controller_workspace(context),
           issue_from_run(run),
           Prompt.gitlab_mr(
             route,
             run["issue_key"],
             run["branch"],
             run["base_branch"],
             run["candidate_sha"],
             mr_description(run),
             operation: :ci_preflight
           ),
           StageSchemas.for_stage(:gitlab_mr),
           control_server: context.control_server
         ) do
      {:ok, output} ->
        if valid_mr_readback?(run, output) do
          RunLedger.update(context.store, run["run_id"], %{
            state: "CI_WAITING",
            mr_url: output["mr_url"],
            mr_iid: output["iid"],
            mr_state: output["state"]
          })

          {:ok, add_event(acc, run["issue_key"], "CI_PREFLIGHT_MR_CREATED", output["mr_url"])}
        else
          block_run(context, workspace, run, :gitlab_mr_readback_mismatch, acc)
        end

      {:error, reason} ->
        block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "CI_WAITING"} = run, acc) do
    if ci_poll_due?(run["ci_last_checked_at"]) do
      route = route_for_run(context, run)

      case context.controller_task.run(
             context.factory,
             controller_workspace(context),
             issue_from_run(run),
             Prompt.gitlab_ci_status(route, run),
             StageSchemas.for_stage(:gitlab_ci_status),
             control_server: context.control_server
           ) do
        {:ok, output} -> consume_ci_status(context, workspace, run, output, acc)
        {:error, reason} -> block_run(context, workspace, run, reason, acc)
      end
    else
      {:ok, acc}
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "PUSHING"} = run, acc) do
    route = route_for_run(context, run)

    with true <- context.worktree.reachable?(route, run["candidate_sha"]) or {:error, :candidate_unreachable},
         {:ok, _push} <-
           context.worktree.push_exact(route, run["worktree"], run["branch"], run["candidate_sha"]),
         {:ok, _updated} <- RunLedger.update(context.store, run["run_id"], %{state: "MR_CREATING"}) do
      advance_delivery(context, workspace, %{run | "state" => "MR_CREATING"}, acc)
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      false -> block_run(context, workspace, run, :candidate_unreachable, acc)
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "MR_CREATING"} = run, acc) do
    route = route_for_run(context, run)
    description = mr_description(run)

    case context.controller_task.run(
           context.factory,
           controller_workspace(context),
           issue_from_run(run),
           Prompt.gitlab_mr(
             route,
             run["issue_key"],
             run["branch"],
             run["base_branch"],
             run["candidate_sha"],
             description
           ),
           StageSchemas.for_stage(:gitlab_mr),
           control_server: context.control_server
         ) do
      {:ok, output} -> finalize_mr(context, workspace, run, output, acc)
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "TESTING"} = run, acc) do
    advance_validation(context, workspace, run, acc)
  end

  defp advance_delivery(_context, _workspace, _run, acc), do: {:ok, acc}

  defp advance_review_push(context, workspace, run, acc) do
    route = route_for_run(context, run)

    result =
      with_review_mcp_session(context, workspace, fn session ->
        with :ok <- require_review_verifier_pass(context.store, run),
             {:ok, %{sha: candidate}} <-
               context.worktree.validate_native(writer_route(context, run), run["worktree"],
                 clean: true,
                 detached: false,
                 expected_branch: run["branch"],
                 expected_sha: run["candidate_sha"]
               ),
             {:ok, jira} <-
               context.jira_reader.issue(run["issue_key"],
                 workspace: workspace,
                 connector: context.jira_connector || JiraMcpConnector,
                 app_server: context.jira_app_server,
                 mcp_session: session
               ),
             true <- "ai-review" in Map.get(jira, "labels", []) or {:error, :jira_review_label_missing},
             {:ok, source} <- read_review_push_source(context, workspace, route, run, session),
             true <- MrFeedbackRework.source_notes_match?(run, source.discussions) or {:error, :review_source_changed},
             {:ok, %{sha: ^candidate}} <-
               context.worktree.push_exact(writer_route(context, run), run["worktree"], run["branch"], candidate),
             {:ok, %{discussions: readback}} <-
               context.gitlab_reader.fetch(route, run,
                 workspace: workspace,
                 connector: context.gitlab_connector,
                 app_server: context.gitlab_app_server,
                 mcp_session: session
               ),
             true <- MrFeedbackRework.source_notes_match?(run, readback) or {:error, :review_source_changed},
             {:ok, batch_key} <- review_batch_key(context.store, run["run_id"]),
             :ok <- MrFeedbackRework.complete_push(context.store, run["run_id"], batch_key, candidate) do
          {:ok, candidate}
        end
      end)

    case result do
      {:ok, candidate} ->
        {:ok, add_event(acc, run["issue_key"], "REVIEW_FEEDBACK_PUSHED", candidate)}

      {:error, reason}
      when reason in [
             :review_source_changed,
             :gitlab_feedback_mr_mismatch,
             :jira_review_label_missing,
             :review_verifier_pass_missing
           ] ->
        quarantine_review_push(context, run, reason, acc)

      {:error, reason} ->
        Logger.warning("MR review push deferred run_id=#{run["run_id"]} reason=#{inspect(reason)}")
        RunLedger.update(context.store, run["run_id"], %{last_error: inspect(reason)})
        {:ok, acc}
    end
  end

  defp quarantine_review_push(context, run, reason, acc) do
    with {:ok, batch_key} <- review_batch_key(context.store, run["run_id"]),
         :ok <- MrFeedbackRework.quarantine(context.store, run["run_id"], batch_key, reason) do
      {:ok, add_event(acc, run["issue_key"], "REVIEW_FEEDBACK_RECONCILE_REQUIRED", Atom.to_string(reason))}
    end
  end

  defp require_review_verifier_pass(store, run) do
    key = "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}"
    task = Store.one!(store, "SELECT status, output_json FROM factory_tasks WHERE task_key = ?", [key])
    candidate = run["candidate_sha"]

    case task do
      %{"status" => "CONSUMED", "output_json" => json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"status" => "PASS", "candidate_sha" => ^candidate}} -> :ok
          _other -> {:error, :review_verifier_pass_missing}
        end

      _other ->
        {:error, :review_verifier_pass_missing}
    end
  end

  defp read_review_push_source(context, workspace, route, run, session) do
    opts = [
      workspace: workspace,
      connector: context.gitlab_connector,
      app_server: context.gitlab_app_server,
      mcp_session: session
    ]

    old_run = Map.put(run, "candidate_sha", run["review_base_sha"])

    case context.gitlab_reader.fetch(route, old_run, opts) do
      {:ok, source} -> {:ok, source}
      {:error, :gitlab_feedback_mr_mismatch} -> context.gitlab_reader.fetch(route, run, opts)
      {:error, _reason} = error -> error
    end
  end

  defp review_batch_key(store, run_id) do
    case Store.query!(store, "SELECT DISTINCT review_batch_key FROM mr_feedback_notes WHERE run_id = ? AND status = 'REWORKING' LIMIT 2", [run_id]).rows do
      [[key]] when is_binary(key) -> {:ok, key}
      _other -> {:error, :review_feedback_batch_missing}
    end
  end

  defp consume_feature_planner(context, run, route, planning_path, output, acc) do
    with :ok <- remove_stage_workspace(context, run, route, planning_path) do
      case output do
        %{"status" => "PLANNED", "plan_markdown" => plan} ->
          RunLedger.update(context.store, run["run_id"], %{
            state: "ADMITTING_WRITER",
            plan_markdown: plan
          })

          {:ok, add_event(acc, run["issue_key"], "FEATURE_PLANNED", nil)}

        %{"status" => "BLOCKED", "blockers" => blockers} ->
          {:error, {:planning_blocked, blockers}}

        _other ->
          {:error, :invalid_feature_planner_output}
      end
    end
  end

  defp advance_writer(context, run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    iteration = run["implementation_iteration"] + 1
    findings = decode_json(run["repair_findings_json"], [])

    if iteration > context.factory.maximum_implementation_iterations do
      {:error, :implementation_iteration_limit}
    else
      writer_schema = if native_transport?(context), do: :native_feature_writer, else: :feature_writer

      writer_opts = [
        controller_commits: native_transport?(context),
        run_id: run["run_id"],
        spec_revision: run["spec_revision"],
        base_ref: "origin/#{run["base_branch"]}",
        iteration_limit: context.factory.maximum_implementation_iterations
      ]

      prompt =
        if review_rework?(run) do
          Prompt.review_feedback_writer(
            snapshot,
            run["contract_markdown"],
            run["contract_sha256"],
            run["plan_markdown"],
            iteration,
            decode_json(run["review_feedback_json"], []),
            findings,
            writer_opts
          )
        else
          Prompt.feature_writer(
            snapshot,
            run["contract_markdown"],
            run["contract_sha256"],
            run["plan_markdown"],
            iteration,
            findings,
            writer_opts
          )
        end

      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: run["worktree"],
        prompt: prompt,
        schema: StageSchemas.for_stage(writer_schema),
        task_key: "#{run["run_id"]}:feature-writer",
        stage: run["state"],
        role: "feature-writer",
        thread_name: task_name(run["issue_key"], "Feature Writer"),
        persistent?: true,
        expected_sha: Map.get(run, "_native_expected_sha")
      }

      launch_or_consume(context, run, stage, acc, &consume_feature_writer(context, run, iteration, &1, &2))
    end
  end

  defp consume_feature_writer(context, run, iteration, %{"status" => "CONTINUE", "commit_sha" => commit_sha}, acc) do
    with {:ok, head} <- context.worktree.candidate(run["worktree"], run["base_branch"]),
         true <- is_nil(commit_sha) or commit_sha == head or {:error, :writer_sha_mismatch},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: run["state"],
             implementation_iteration: iteration,
             candidate_sha: head,
             repair_findings_json: Jason.encode!([])
           }) do
      {:ok, add_event(acc, run["issue_key"], "WRITER_CONTINUE", head)}
    end
  end

  defp consume_feature_writer(context, run, iteration, %{"status" => "COMPLETE", "commit_sha" => commit_sha}, acc) do
    preflight? = ci_preflight?(route_for_run(context, run)) and not review_rework?(run) and not ready_rework_active?(context.store, run)

    with {:ok, head} <- context.worktree.candidate(run["worktree"], run["base_branch"]),
         true <- commit_sha == head or {:error, :writer_sha_mismatch},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: if(preflight?, do: "CI_PUSHING", else: "VERIFYING"),
             implementation_iteration: iteration,
             candidate_sha: head,
             verifier_round: run["verifier_round"] + if(preflight?, do: 0, else: 1),
             repair_findings_json: Jason.encode!([])
           }) do
      {:ok, add_event(acc, run["issue_key"], "CANDIDATE_READY", head)}
    end
  end

  defp consume_feature_writer(_context, _run, _iteration, %{"status" => "BLOCKED", "blockers" => blockers}, _acc),
    do: {:error, {:writer_blocked, blockers}}

  defp consume_feature_writer(_context, _run, _iteration, _output, _acc), do: {:error, :invalid_feature_writer_output}

  defp ready_rework_active?(store, run) do
    rows =
      Store.query!(
        store,
        "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status = 'APPLIED' ORDER BY updated_at DESC",
        [run["run_id"]]
      ).rows

    Enum.any?(rows, fn [key] ->
      case TicketChatCommands.validate_ready_rework_replay(store, key) do
        {:ok, %{receipt: receipt}} -> receipt["candidate_sha"] == run["candidate_sha"]
        _ -> false
      end
    end)
  end

  defp ready_rework_for_request?(store, run, task, request_key) do
    rows =
      Store.query!(
        store,
        "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status = 'APPLIED' ORDER BY updated_at DESC",
        [run["run_id"]]
      ).rows

    Enum.any?(rows, fn [key] -> ready_rework_request_matches?(store, run, task, request_key, key) end)
  end

  defp ready_rework_request_matches?(store, run, task, request_key, command_key) do
    with {:ok, %{receipt: receipt}} <- TicketChatCommands.validate_ready_rework_replay(store, command_key),
         {:ok, evidence} <- WorkerEvidence.get(store, request_key),
         {:ok, binding} <- Jason.decode(evidence["binding_json"]) do
      receipt["request_key"] == request_key and receipt["candidate_sha"] == binding["expected_sha"] and
        evidence["request_key"] == request_key and evidence["run_id"] == run["run_id"] and
        evidence["task_key"] == task["task_key"] and task["role"] == "feature-writer"
    else
      _ -> false
    end
  end

  defp advance_verifier(context, run, acc) do
    route = route_for_run(context, run)
    stage = "verify-#{run["verifier_round"]}"
    task_key = "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}"

    case stage_workspace(context, run, route, task_key, stage, run["candidate_sha"]) do
      {:ok, verification_path, expected_sha} ->
        snapshot = decode_json!(run["snapshot_json"])

        stage_spec = %{
          issue: issue_from_snapshot(snapshot),
          workspace: verification_path,
          prompt: verifier_prompt(run, snapshot),
          schema: StageSchemas.for_stage(:change_verifier),
          task_key: task_key,
          stage: "VERIFYING",
          role: "change-verifier",
          thread_name: task_name(run["issue_key"], "Change Verifier", run["verifier_round"]),
          persistent?: false,
          expected_sha: expected_sha
        }

        launch_or_consume(
          context,
          run,
          stage_spec,
          acc,
          &consume_change_verifier(context, run, route, verification_path, &1, &2)
        )

      {:error, reason} ->
        block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp verifier_prompt(run, snapshot) do
    if review_rework?(run) do
      Prompt.review_feedback_verifier(
        snapshot,
        run["contract_markdown"],
        run["contract_sha256"],
        run["candidate_sha"],
        run["base_branch"],
        decode_json(run["review_feedback_json"], [])
      )
    else
      Prompt.change_verifier(
        snapshot,
        run["contract_markdown"],
        run["contract_sha256"],
        run["candidate_sha"],
        run["base_branch"],
        decode_json(run["ci_evidence_json"], nil)
      )
    end
  end

  defp consume_change_verifier(context, run, route, verification_path, output, acc) do
    cleanup_result = remove_stage_workspace(context, run, route, verification_path)

    with :ok <- cleanup_result,
         true <- output["candidate_sha"] == run["candidate_sha"] or {:error, :verifier_sha_mismatch} do
      consume_change_verifier_output(context, run, output, acc)
    end
  end

  defp consume_change_verifier_output(context, run, %{"status" => "PASS"}, acc) do
    state =
      cond do
        review_rework?(run) -> "REVIEW_PUSHING"
        run["execution_mode"] == "TICKET_SUPERVISOR_V1" -> "PUSHING"
        preflight_verified?(context, run) -> "MR_CREATING"
        true -> "PUSHING"
      end

    RunLedger.update(context.store, run["run_id"], %{state: state})
    {:ok, add_event(acc, run["issue_key"], "VERIFICATION_PASSED", run["candidate_sha"])}
  end

  defp consume_change_verifier_output(context, run, %{"status" => "REPAIR", "findings" => findings}, acc) do
    repair_round = run["code_repair_round"] + 1

    if repair_round <= context.factory.maximum_code_repair_rounds do
      RunLedger.update(context.store, run["run_id"], %{
        state: if(review_rework?(run), do: "REVIEW_WRITING", else: "REPAIRING"),
        code_repair_round: repair_round,
        repair_findings_json: Jason.encode!(findings)
      })

      {:ok, add_event(acc, run["issue_key"], "VERIFICATION_REPAIR", findings)}
    else
      {:error, {:code_repair_limit, findings}}
    end
  end

  defp consume_change_verifier_output(_context, _run, %{"status" => "BLOCK", "findings" => findings}, _acc) do
    {:error, {:verification_blocked, findings}}
  end

  defp consume_change_verifier_output(_context, _run, _output, _acc), do: {:error, :invalid_verifier_output}

  defp consume_ci_status(context, workspace, run, output, acc) do
    if valid_ci_readback?(run, output) do
      consume_valid_ci_status(context, workspace, run, output, acc)
    else
      block_run(context, workspace, run, :gitlab_ci_readback_mismatch, acc)
    end
  end

  defp consume_valid_ci_status(context, _workspace, run, %{"status" => "WAIT"} = output, acc) do
    RunLedger.update(context.store, run["run_id"], %{
      ci_pipeline_id: output["pipeline_id"],
      ci_pipeline_url: output["pipeline_url"],
      ci_last_checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:ok, add_event(acc, run["issue_key"], "CI_PREFLIGHT_WAITING", output["pipeline_status"])}
  end

  defp consume_valid_ci_status(context, workspace, run, %{"status" => "PASS"} = output, acc) do
    if ci_bazel_passed?(output) do
      RunLedger.update(context.store, run["run_id"], %{
        state: "VERIFYING",
        verifier_round: run["verifier_round"] + 1,
        ci_pipeline_id: output["pipeline_id"],
        ci_pipeline_url: output["pipeline_url"],
        ci_evidence_json: Jason.encode!(output),
        ci_last_checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:ok, add_event(acc, run["issue_key"], "CI_PREFLIGHT_PASSED", output["pipeline_url"])}
    else
      block_run(context, workspace, run, :gitlab_ci_required_job_missing, acc)
    end
  end

  defp consume_valid_ci_status(context, _workspace, run, %{"status" => "REPAIR", "findings" => findings}, acc) do
    repair_round = run["code_repair_round"] + 1

    if repair_round <= context.factory.maximum_code_repair_rounds and findings != [] do
      RunLedger.update(context.store, run["run_id"], %{
        state: "REPAIRING",
        code_repair_round: repair_round,
        repair_findings_json: Jason.encode!(findings),
        ci_evidence_json: nil,
        ci_last_checked_at: nil
      })

      {:ok, add_event(acc, run["issue_key"], "CI_PREFLIGHT_REPAIR", findings)}
    else
      {:error, {:code_repair_limit, findings}}
    end
  end

  defp consume_valid_ci_status(context, workspace, run, %{"status" => "BLOCK", "findings" => findings}, acc) do
    block_run(context, workspace, run, {:gitlab_ci_blocked, findings}, acc)
  end

  defp valid_ci_readback?(run, output) do
    valid_ci_mr_readback?(run, output) and
      run["ci_preflight_sha"] == run["candidate_sha"] and
      output["status"] in ["WAIT", "PASS", "REPAIR", "BLOCK"] and
      valid_ci_pipeline_binding?(run, output)
  end

  defp valid_ci_mr_readback?(run, output) do
    output["mr_url"] == run["mr_url"] and output["iid"] == run["mr_iid"] and
      output["sha"] == run["candidate_sha"] and output["source_branch"] == run["branch"] and
      output["target_branch"] == run["base_branch"] and output["draft"] == true and
      output["reviewers_count"] == 0 and output["assignee_id"] == 11_599_766 and
      output["mr_state"] == "opened"
  end

  defp valid_ci_pipeline_binding?(run, output) do
    case output["pipeline_id"] do
      nil -> no_pipeline_yet?(output)
      pipeline_id when is_integer(pipeline_id) -> pipeline_matches_candidate?(run, output)
      _other -> false
    end
  end

  defp no_pipeline_yet?(output) do
    output["status"] != "PASS" and is_nil(output["pipeline_url"]) and
      is_nil(output["pipeline_sha"]) and is_nil(output["pipeline_ref"]) and
      is_nil(output["pipeline_source"])
  end

  defp pipeline_matches_candidate?(run, output) do
    merge_ref = "refs/merge-requests/#{run["mr_iid"]}/merge"
    head_ref = "refs/merge-requests/#{run["mr_iid"]}/head"
    pipeline_sha = output["pipeline_sha"]

    is_binary(output["pipeline_url"]) and is_binary(pipeline_sha) and
      String.match?(pipeline_sha, ~r/\A[0-9a-f]{40}\z/) and
      output["pipeline_source"] == "merge_request_event" and
      (output["pipeline_ref"] == merge_ref or
         (output["pipeline_ref"] == head_ref and pipeline_sha == run["candidate_sha"])) and
      (output["status"] != "PASS" or output["pipeline_status"] == "success")
  end

  defp ci_bazel_passed?(%{"required_jobs" => jobs}) when is_list(jobs) do
    Enum.any?(jobs, &(&1["name"] == "bazel" and &1["status"] == "success" and is_integer(&1["id"])))
  end

  defp ci_bazel_passed?(_output), do: false

  defp ci_preflight?(route), do: route["ci_preflight"] == "draft_mr"

  defp review_rework?(%{"review_base_sha" => sha, "review_feedback_json" => feedback})
       when is_binary(sha) and is_binary(feedback),
       do: true

  defp review_rework?(_run), do: false

  defp preflight_verified?(context, run) do
    evidence = decode_json(run["ci_evidence_json"], %{})

    ci_preflight?(route_for_run(context, run)) and
      run["ci_preflight_sha"] == run["candidate_sha"] and
      is_integer(run["ci_pipeline_id"]) and
      evidence["status"] == "PASS" and evidence["sha"] == run["candidate_sha"]
  end

  defp ci_poll_due?(nil), do: true

  defp ci_poll_due?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, last_checked, _offset} -> DateTime.diff(DateTime.utc_now(), last_checked, :second) >= 180
      _other -> true
    end
  end

  defp ci_poll_due?(_value), do: true

  defp finalize_mr(context, workspace, run, output, acc) do
    if valid_mr_readback?(run, output) do
      finalize_valid_mr(context, workspace, run, output, acc)
    else
      block_run(context, workspace, run, :gitlab_mr_readback_mismatch, acc)
    end
  end

  defp finalize_valid_mr(context, _workspace, %{"kind" => "VALIDATION"} = run, output, acc) do
    with {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "TESTING",
             mr_url: output["mr_url"],
             mr_iid: output["iid"],
             mr_state: output["state"]
           }) do
      acc = add_event(acc, run["issue_key"], "VALIDATION_MR_UPDATED", output["mr_url"])
      {:ok, maybe_hibernate_writer(context, run, acc)}
    end
  end

  defp finalize_valid_mr(context, workspace, run, output, acc) do
    manual_required = run["manual_validation_required"] == 1
    target_state = if manual_required, do: "AWAITING_VALIDATION", else: "READY_FOR_REVIEW"
    label = if manual_required, do: "ai-testing", else: "ai-review"

    operation =
      "Add comment `Draft MR: #{output["mr_url"]} (exact SHA #{run["candidate_sha"]})`; " <>
        "add label `#{label}`; remove labels `ai-running`, `ai-verifying`, and `ai-ready`; " <>
        "preserve all other labels."

    with {:ok, %{"status" => "PASS", "labels" => labels}} <-
           jira_write(context, workspace, run, operation, output["mr_url"],
             approved_comment_body: "Draft MR: #{output["mr_url"]} (exact SHA #{run["candidate_sha"]})",
             label_add: [label],
             label_remove: ["ai-running", "ai-verifying", "ai-ready"]
           ),
         true <- label in normalize_strings(labels) or {:error, :jira_delivery_label_missing},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: target_state,
             mr_url: output["mr_url"],
             mr_iid: output["iid"],
             mr_state: output["state"]
           }) do
      acc = add_event(acc, run["issue_key"], target_state, output["mr_url"])
      {:ok, maybe_hibernate_writer(context, run, acc)}
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      _other -> block_run(context, workspace, run, :jira_delivery_update_failed, acc)
    end
  end

  defp valid_mr_readback?(run, output) do
    Enum.all?([
      output["status"] == "PASS",
      output["sha"] == run["candidate_sha"],
      output["source_branch"] == run["branch"],
      output["target_branch"] == run["base_branch"],
      output["draft"] == true,
      output["reviewers_count"] == 0,
      output["assignee_id"] == 11_599_766,
      output["state"] == "opened"
    ])
  end

  defp advance_validation(context, workspace, run, acc) do
    case manual_run_environment(context, run) do
      {:ok, _environment} -> launch_manual_validation(context, workspace, run, acc)
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp launch_manual_validation(context, workspace, run, acc) do
    route = route_for_run(context, run)
    attempt = run["validation_attempt"] + 1
    stage = "validate-#{attempt}"
    task_key = "#{run["run_id"]}:manual-validator"

    case stage_workspace(context, run, route, task_key, stage, run["candidate_sha"]) do
      {:ok, validation_path, expected_sha} ->
        stage_spec = %{
          issue: issue_from_run(run),
          workspace: validation_path,
          prompt: Prompt.manual_validator(run, run["contract_markdown"], run["candidate_sha"], route),
          schema: StageSchemas.for_stage(:manual_validator),
          task_key: task_key,
          stage: "TESTING",
          role: "manual-validator",
          thread_name: task_name(run["issue_key"], "Manual Validator"),
          required_apps: Map.get(context.factory.manual_validation, "required_apps", []),
          required_mcp_servers: Map.get(context.factory.manual_validation, "required_mcp_servers", []),
          mcp_startup_timeout_ms: Map.get(context.factory.manual_validation, "startup_timeout_ms", 60_000),
          persistent?: true,
          expected_sha: expected_sha
        }

        launch_or_consume(
          context,
          run,
          stage_spec,
          acc,
          &consume_manual_validation(context, workspace, run, route, validation_path, attempt, &1, &2)
        )

      {:error, reason} ->
        block_run(context, workspace, run, reason, acc)
    end
  end

  defp consume_manual_validation(context, workspace, run, route, validation_path, attempt, output, acc) do
    cleanup_result = remove_stage_workspace(context, run, route, validation_path)

    with :ok <- cleanup_result,
         true <- output["candidate_sha"] == run["candidate_sha"] or {:error, :validator_sha_mismatch},
         {:ok, contract_environment} <- manual_run_environment(context, run),
         :ok <- validate_manual_result(context.factory.manual_validation, output, contract_environment) do
      consume_manual_validation_output(context, workspace, run, attempt, output, acc)
    end
  end

  defp manual_run_environment(context, run) do
    with {:ok, environment} <- Contract.manual_validation_environment(run["contract_markdown"]),
         :ok <- validate_manual_policy(context.factory.manual_validation, true, environment) do
      {:ok, environment}
    end
  end

  defp consume_manual_validation_output(
         context,
         workspace,
         run,
         attempt,
         %{"status" => "PASS", "evidence_markdown" => evidence},
         acc
       ) do
    finalize_validation(context, workspace, run, evidence, attempt, acc)
  end

  defp consume_manual_validation_output(
         context,
         _workspace,
         run,
         attempt,
         %{"status" => "RETRY", "findings" => findings},
         acc
       ) do
    RunLedger.update(context.store, run["run_id"], %{
      state: "TESTING",
      validation_attempt: attempt,
      repair_findings_json: Jason.encode!(findings)
    })

    {:ok, add_event(acc, run["issue_key"], "VALIDATION_RETRY", findings)}
  end

  defp consume_manual_validation_output(
         context,
         _workspace,
         run,
         attempt,
         %{"status" => "REPAIR", "findings" => findings},
         acc
       ) do
    repair_validation(context, run, attempt, findings, acc)
  end

  defp consume_manual_validation_output(
         _context,
         _workspace,
         _run,
         _attempt,
         %{"status" => "BLOCK", "human_action" => action},
         _acc
       ) do
    {:error, {:validation_blocked, action}}
  end

  defp consume_manual_validation_output(_context, _workspace, _run, _attempt, _output, _acc) do
    {:error, :invalid_manual_validation_output}
  end

  defp repair_validation(context, run, attempt, findings, acc) do
    repair_round = run["validation_repair_round"] + 1

    if repair_round <= context.factory.maximum_validation_repair_rounds do
      RunLedger.update(context.store, run["run_id"], %{
        state: "REPAIRING",
        validation_attempt: attempt,
        validation_repair_round: repair_round,
        repair_findings_json: Jason.encode!(findings)
      })

      {:ok, add_event(acc, run["issue_key"], "VALIDATION_REPAIR", findings)}
    else
      {:error, {:validation_repair_limit, findings}}
    end
  end

  defp validate_manual_policy(_policy, false, nil), do: :ok

  defp validate_manual_policy(policy, true, environment) do
    allowed = Map.get(policy, "allowed_environments", []) |> Enum.map(&String.downcase(to_string(&1)))
    normalized = environment |> to_string() |> String.trim() |> String.downcase()

    cond do
      not Map.get(policy, "enabled", false) -> {:error, :manual_validation_disabled}
      Map.get(policy, "allow_production", false) -> {:error, :unsafe_manual_validation_policy}
      Map.get(policy, "allow_database_ddl", false) -> {:error, :unsafe_manual_validation_policy}
      not Map.get(policy, "require_slack_coordination", true) -> {:error, :slack_coordination_required}
      normalized not in allowed -> {:error, {:manual_validation_environment_not_allowed, environment}}
      normalized in ["staging", "production", "prod"] -> {:error, :production_validation_forbidden}
      true -> :ok
    end
  end

  defp validate_manual_policy(_policy, _required, _environment), do: {:error, :invalid_manual_validation_contract}

  defp validate_manual_result(_policy, %{"status" => "BLOCK"}, _contract_environment), do: :ok

  defp validate_manual_result(policy, output, contract_environment) do
    with :ok <- validate_manual_result_environment(policy, output, contract_environment) do
      validate_manual_result_evidence(output)
    end
  end

  defp validate_manual_result_environment(policy, output, contract_environment) do
    environment = output["environment"] |> to_string() |> String.trim() |> String.downcase()
    expected = contract_environment |> to_string() |> String.trim() |> String.downcase()
    allowed = Map.get(policy, "allowed_environments", []) |> Enum.map(&String.downcase(to_string(&1)))

    cond do
      environment not in allowed ->
        {:error, {:manual_validation_environment_not_allowed, environment}}

      environment != expected ->
        {:error, {:manual_validation_environment_mismatch, expected, environment}}

      true ->
        :ok
    end
  end

  defp validate_manual_result_evidence(output) do
    cond do
      not present?(output["slack_claim_ts"]) ->
        {:error, :manual_validation_slack_claim_missing}

      output["slack_release_confirmed"] != true ->
        {:error, :manual_validation_slack_release_missing}

      output["teardown_confirmed"] != true ->
        {:error, :manual_validation_teardown_missing}

      output["synthetic_data_only"] != true ->
        {:error, :manual_validation_synthetic_data_unproven}

      output["status"] == "PASS" and not present?(output["evidence_markdown"]) ->
        {:error, :manual_validation_evidence_missing}

      true ->
        :ok
    end
  end

  defp finalize_validation(context, workspace, run, evidence, attempt, acc) do
    route = route_for_run(context, run)
    description = mr_description(run) <> "\n\n- Result: PASS\n\n" <> evidence

    with {:ok, output} <-
           update_validation_mr(context, route, run, description),
         true <- valid_validation_mr_readback?(run, output) or {:error, :gitlab_validation_readback_mismatch} do
      finalize_validation_in_jira(context, workspace, run, output, attempt, acc)
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      false -> block_run(context, workspace, run, :validation_finalization_failed, acc)
    end
  end

  defp update_validation_mr(context, route, run, description) do
    context.controller_task.run(
      context.factory,
      controller_workspace(context),
      issue_from_run(run),
      Prompt.gitlab_mr(
        route,
        run["issue_key"],
        run["branch"],
        run["base_branch"],
        run["candidate_sha"],
        description
      ),
      StageSchemas.for_stage(:gitlab_mr),
      control_server: context.control_server
    )
  end

  defp valid_validation_mr_readback?(run, output) do
    valid_mr_readback?(run, output) and output["mr_url"] == run["mr_url"]
  end

  defp finalize_validation_in_jira(context, workspace, run, output, attempt, acc) do
    operation =
      "Add comment `Automated manual validation PASS for exact SHA #{run["candidate_sha"]}. Evidence is recorded in #{run["mr_url"]}`; " <>
        "add label `ai-review`; remove label `ai-testing`; preserve all other labels."

    with {:ok, %{"status" => "PASS", "labels" => labels}} <-
           jira_write(context, workspace, run, operation, run["candidate_sha"],
             approved_comment_body: "Automated manual validation PASS for exact SHA #{run["candidate_sha"]}. Evidence is recorded in #{run["mr_url"]}",
             label_add: ["ai-review"],
             label_remove: ["ai-testing"]
           ),
         true <- "ai-review" in normalize_strings(labels) or {:error, :ai_review_readback_missing},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "READY_FOR_REVIEW",
             validation_attempt: attempt,
             mr_state: output["state"]
           }),
         :ok <- finalize_parent_delivery(context.store, run["parent_run_id"]) do
      {:ok, add_event(acc, run["issue_key"], "VALIDATION_PASSED", run["mr_url"])}
    end
  end

  defp launch_or_consume(context, run, stage_spec, acc, consumer) do
    case TaskLedger.get(context.store, stage_spec.task_key) do
      {:ok, %{"status" => "COMPLETE", "output_json" => output_json} = task} ->
        handle_completed_stage(context, run, stage_spec, acc, consumer, task, output_json)

      {:ok, %{"status" => "FAILED", "failure_code" => reason}} ->
        cleanup = cleanup_failed_stage(context, run, stage_spec.workspace, stage_spec.role)
        block_run(context, controller_workspace(context), run, {:task_failed, reason, cleanup}, acc)

      {:ok, %{"status" => "WAITING_FOR_WRITER", "updated_at" => updated_at}} ->
        retry_waiting_task(context, run, stage_spec, acc, updated_at)

      {:ok, %{"status" => "WAITING_FOR_BROKER", "updated_at" => updated_at}} ->
        retry_waiting_task(context, run, stage_spec, acc, updated_at)

      _other ->
        launch_stage(context, run, stage_spec, acc)
    end
  end

  defp handle_completed_stage(context, run, stage_spec, acc, consumer, task, output_json) do
    cond do
      stage_spec.role == "specification-author" and stale_specification_prompt?(task, stage_spec) ->
        relaunch_stale_author(context, run, stage_spec, acc)

      stage_spec.role == "specification-critic" and
          stale_specification_critic_input?(context, run, task, stage_spec) ->
        block_stale_critic(context, run, stage_spec, acc)

      true ->
        consume_completed_task(context, run, stage_spec, acc, consumer, output_json)
    end
  end

  defp relaunch_stale_author(context, run, stage_spec, acc) do
    with {:ok, _updated} <-
           TaskLedger.update(context.store, stage_spec.task_key, %{status: "RETRY_PENDING", output_json: nil}) do
      launch_stage(context, run, stage_spec, acc)
    end
  end

  defp block_stale_critic(context, run, stage_spec, acc) do
    TaskLedger.update(context.store, stage_spec.task_key, %{status: "STALE"})
    cleanup_failed_stage(context, run, stage_spec.workspace, stage_spec.role)
    block_run(context, controller_workspace(context), run, :specification_input_changed_during_review, acc)
  end

  defp stale_specification_prompt?(task, stage_spec) do
    expected = :sha256 |> :crypto.hash(stage_spec.prompt) |> Base.encode16(case: :lower)
    task["prompt_sha256"] != expected
  end

  defp stale_specification_critic_input?(context, run, task, stage_spec) do
    if native_transport?(context) do
      stale_native_critic_input?(context, run, task)
    else
      stale_specification_prompt?(task, stage_spec)
    end
  end

  defp stale_native_critic_input?(context, run, task) do
    request =
      Store.one!(
        context.store,
        "SELECT prompt, metadata_json, thread_id, turn_id FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'FOLLOWUP' AND status = 'SUCCEEDED' ORDER BY updated_at DESC LIMIT 1",
        [task["task_key"]]
      )

    with %{} <- request,
         true <- request["thread_id"] == task["thread_id"] and request["turn_id"] == task["turn_id"],
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- metadata["stage_prompt_sha256"] == task["prompt_sha256"],
         {:ok, original} <- critic_prompt_snapshot(request["prompt"]),
         true <- critic_prompt_matches_contract?(request["prompt"], run),
         current <- decode_json(run["snapshot_json"], %{}),
         true <- specification_input(original) == specification_input(current) do
      false
    else
      _other -> true
    end
  end

  defp critic_prompt_snapshot(prompt) when is_binary(prompt) do
    case Regex.run(~r/UNTRUSTED JIRA SNAPSHOT:\n(.*?)\n\nCONTRACT UNDER REVIEW:/s, prompt) do
      [_match, json] -> Jason.decode(json)
      _other -> {:error, :critic_snapshot_missing}
    end
  end

  defp critic_prompt_snapshot(_prompt), do: {:error, :critic_snapshot_missing}

  defp critic_prompt_matches_contract?(prompt, run) do
    String.contains?(prompt, "Controller-computed contract SHA-256: #{run["contract_sha256"]}") and
      String.contains?(prompt, "CONTRACT UNDER REVIEW:\n#{run["contract_markdown"]}")
  end

  defp consume_completed_task(context, run, stage_spec, acc, consumer, output_json) do
    output = decode_json!(output_json)

    if native_transport?(context) and stage_spec.role == "feature-writer" do
      consume_native_writer_task(context, run, stage_spec, output_json, output, acc)
    else
      consume_standard_task(context, run, stage_spec, acc, consumer, output)
    end
  end

  defp consume_standard_task(context, run, stage_spec, acc, consumer, output) do
    case consumer.(output, acc) do
      {:ok, _updated_acc} = ok ->
        task_status =
          if stage_spec.stage == "CONTRACT_DISCUSSING" and output["status"] == "BLOCKED",
            do: "WAITING_FOR_USER",
            else: "CONSUMED"

        TaskLedger.update(context.store, stage_spec.task_key, %{status: task_status})
        ok

      {:error, reason} ->
        block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp consume_native_writer_task(
         context,
         run,
         stage_spec,
         output_json,
         %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil},
         acc
       ) do
    candidate = run["candidate_sha"]

    with true <-
           (is_binary(candidate) and candidate == run["_native_expected_sha"]) or
             {:error, :native_writer_candidate_unbound},
         {:ok, %{sha: ^candidate}} <-
           context.worktree.validate_native(writer_route(context, run), run["worktree"],
             clean: true,
             detached: false,
             expected_branch: run["branch"],
             expected_sha: candidate
           ),
         {:ok, ^candidate} <- context.worktree.candidate(run["worktree"], run["base_branch"]),
         {:ok, _updated} <-
           persist_native_writer_slice(context, run, stage_spec.task_key, output_json, "COMPLETE", candidate) do
      {:ok, add_event(acc, run["issue_key"], "CANDIDATE_READY", candidate)}
    else
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
      _other -> block_run(context, controller_workspace(context), run, :native_writer_candidate_unverified, acc)
    end
  end

  defp consume_native_writer_task(
         context,
         run,
         stage_spec,
         output_json,
         %{
           "status" => status,
           "changed_paths" => paths,
           "commit_message" => message
         },
         acc
       )
       when status in ["CONTINUE", "COMPLETE"] do
    parent_sha = run["_native_expected_sha"]

    with true <- is_binary(parent_sha) or {:error, :native_writer_parent_unbound},
         {:ok, %{sha: sha}} <-
           context.worktree.commit_native_slice(
             writer_route(context, run),
             run["worktree"],
             run["branch"],
             parent_sha,
             paths,
             message
           ),
         {:ok, ^sha} <- context.worktree.candidate(run["worktree"], run["base_branch"]),
         {:ok, _updated} <-
           persist_native_writer_slice(context, run, stage_spec.task_key, output_json, status, sha) do
      event = if status == "COMPLETE", do: "CANDIDATE_READY", else: "WRITER_CONTINUE"
      {:ok, add_event(acc, run["issue_key"], event, sha)}
    else
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
      _other -> block_run(context, controller_workspace(context), run, :native_writer_commit_unverified, acc)
    end
  end

  defp consume_native_writer_task(context, run, _stage_spec, _json, %{"status" => "BLOCKED", "blockers" => blockers}, acc),
    do: block_run(context, controller_workspace(context), run, {:writer_blocked, blockers}, acc)

  defp consume_native_writer_task(context, run, _stage_spec, _json, _output, acc),
    do: block_run(context, controller_workspace(context), run, :invalid_feature_writer_output, acc)

  defp persist_native_writer_slice(context, run, task_key, output_json, status, sha) do
    Store.transaction!(context.store, fn transaction ->
      current_run = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [run["run_id"]])
      task = Store.one!(transaction, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key])

      if native_writer_slice_current?(current_run, run, task, output_json) do
        write_native_writer_slice(
          transaction,
          run,
          task_key,
          status,
          sha,
          ci_preflight?(route_for_run(context, run)) and not review_rework?(run)
        )
      else
        {:error, :native_writer_slice_state_changed}
      end
    end)
  end

  defp write_native_writer_slice(transaction, run, task_key, status, sha, preflight?) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    next_state = if status == "COMPLETE", do: if(preflight?, do: "CI_PUSHING", else: "VERIFYING"), else: run["state"]
    verifier_round = run["verifier_round"] + if(status == "COMPLETE" and not preflight?, do: 1, else: 0)
    retain_findings? = status == "CONTINUE"

    {:ok, _updated_run} =
      RunLedger.update(transaction, run["run_id"], %{
        state: next_state,
        candidate_sha: sha,
        implementation_iteration: run["implementation_iteration"] + 1,
        verifier_round: verifier_round,
        repair_findings_json: if(retain_findings?, do: run["repair_findings_json"], else: "[]")
      })

    Store.query!(
      transaction,
      "UPDATE factory_tasks SET status = 'CONSUMED', workspace_sha = ?, updated_at = ? WHERE task_key = ?",
      [sha, timestamp, task_key]
    )

    {:ok, sha}
  end

  defp native_writer_slice_current?(current_run, run, task, output_json) do
    expected_run = %{
      "state" => run["state"],
      "worktree" => run["worktree"],
      "branch" => run["branch"],
      "candidate_sha" => run["candidate_sha"],
      "implementation_iteration" => run["implementation_iteration"],
      "code_repair_round" => run["code_repair_round"],
      "verifier_round" => run["verifier_round"],
      "repair_findings_json" => run["repair_findings_json"]
    }

    expected_task = %{"status" => "COMPLETE", "output_json" => output_json, "run_id" => run["run_id"]}

    run["state"] in ["WRITING", "REPAIRING", "REVIEW_WRITING"] and is_map(current_run) and is_map(task) and
      Map.take(current_run, Map.keys(expected_run)) == expected_run and
      Map.take(task, Map.keys(expected_task)) == expected_task
  end

  defp retry_waiting_task(context, run, stage_spec, acc, updated_at) do
    case writer_retry_due?(updated_at) do
      {:ok, true} -> launch_stage(context, run, stage_spec, acc)
      {:ok, false} -> {:ok, acc}
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp writer_retry_due?(updated_at) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, last_attempt, _offset} -> {:ok, DateTime.diff(DateTime.utc_now(), last_attempt, :second) >= 60}
      _other -> {:error, :invalid_factory_writer_retry_timestamp}
    end
  end

  defp writer_retry_due?(_updated_at), do: {:error, :invalid_factory_writer_retry_timestamp}

  defp cleanup_failed_stage(context, run, workspace, role)
       when role in ["specification-critic", "feature-planner", "change-verifier", "manual-validator"] do
    remove_stage_workspace(context, run, route_for_run(context, run), workspace)
  end

  defp cleanup_failed_stage(_context, _run, _workspace, _role), do: :not_applicable

  defp remove_optional_detached(_context, %{"worktree" => nil}), do: :ok

  defp remove_optional_detached(_context, %{"factory_owned" => 0}), do: :ok

  defp remove_optional_detached(context, run) do
    context.worktree.remove_detached(route_for_run(context, run), run["worktree"])
  end

  defp launch_stage(context, run, stage_spec, acc) do
    risk_signals = decode_json(run["risk_signals_json"], [])
    route = route_for_run(context, run)

    result =
      context.task_launcher.launch(
        context.store,
        context.task_supervisor,
        run,
        stage_spec.issue,
        stage_spec.workspace,
        stage_spec.prompt,
        stage_spec.schema,
        task_key: stage_spec.task_key,
        stage: stage_spec.stage,
        role: stage_spec.role,
        model_policy: context.factory.models,
        risk: run["risk"],
        risk_signals: risk_signals,
        recipient: context.recipient,
        project_id: Map.fetch!(route, "codex_project_id"),
        project_root: Map.fetch!(route, "path"),
        thread_name: stage_spec.thread_name,
        required_apps: Map.get(stage_spec, :required_apps, []),
        format_repair_attempts: Map.get(stage_spec, :format_repair_attempts, 0),
        required_mcp_servers: Map.get(stage_spec, :required_mcp_servers, []),
        mcp_startup_timeout_ms: Map.get(stage_spec, :mcp_startup_timeout_ms, 60_000),
        resume_terminal: stage_spec.persistent?,
        active_task_keys: context.active_task_keys,
        task_transport: Map.get(context.factory, :task_transport, "app_server"),
        native_source_attachment_enabled: Map.get(context.factory, :native_source_attachment_enabled, false),
        workspace_mode: Map.get(stage_spec, :workspace_mode),
        expected_sha: Map.get(stage_spec, :expected_sha)
      )

    case result do
      {:ok, launch} -> {:ok, %{acc | launches: [launch | acc.launches]}}
      {:already_running, _task} -> {:ok, acc}
      {:already_terminal, _task} -> {:ok, acc}
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp jira_write(context, workspace, run, operation, expected_readback, opts) do
    with {:ok, scope} <- jira_write_scope(run, opts) do
      do_jira_write(context, workspace, run, operation, expected_readback, scope)
    end
  end

  defp jira_write_scope(run, opts) do
    mutations = Keyword.get(opts, :mutations, [:comment, :labels])
    comment = Keyword.get(opts, :approved_comment_body)
    label_add = Keyword.get(opts, :label_add, [])
    label_remove = Keyword.get(opts, :label_remove, [])
    existing_labels = run["snapshot_json"] |> decode_json(%{}) |> normalized_labels()

    target_labels =
      existing_labels
      |> Enum.reject(&(&1 in label_remove))
      |> Kernel.++(label_add)
      |> Enum.uniq()
      |> Enum.sort()

    if valid_jira_write_scope?(mutations, comment, label_add, label_remove) do
      {:ok, %{mutations: mutations, comment: comment, labels: target_labels}}
    else
      {:error, :invalid_jira_write_scope}
    end
  end

  defp valid_jira_write_scope?(mutations, comment, label_add, label_remove) do
    mutations in [[:comment], [:labels], [:comment, :labels]] and
      (:comment not in mutations or (is_binary(comment) and comment != "")) and
      (:labels not in mutations or label_add != [] or label_remove != []) and
      valid_label_delta?(label_add, label_remove)
  end

  defp valid_label_delta?(label_add, label_remove) do
    MapSet.disjoint?(MapSet.new(label_add), MapSet.new(label_remove)) and
      Enum.all?(label_add ++ label_remove, &(is_binary(&1) and &1 != ""))
  end

  defp do_jira_write(context, workspace, run, operation, expected_readback, scope) do
    if Map.get(context.factory, :task_transport) == "desktop_broker" do
      result =
        JiraMcpWriter.write(run, scope, expected_readback,
          connector: context.jira_connector || SymphonyElixir.Factory.JiraMcpConnector,
          app_server: context.jira_app_server,
          workspace: workspace
        )

      validate_jira_write_result(result, run, expected_readback, scope)
    else
      do_controller_jira_write(context, workspace, run, operation, expected_readback, scope)
    end
  end

  defp do_controller_jira_write(context, workspace, run, operation, expected_readback, scope) do
    allowed_approvals = jira_write_approvals(run["issue_key"], scope)
    scoped_operation = scoped_jira_operation(operation, run["issue_key"], scope)
    mutation_calls = Enum.map(scope.mutations, &jira_mutation_tool_call/1)

    result =
      context.controller_task.run(
        context.factory,
        workspace,
        issue_from_run(run),
        Prompt.jira_write(run["issue_key"], scoped_operation, expected_readback),
        StageSchemas.for_stage(:jira_write),
        control_server: context.control_server,
        approval_policy: "on-request",
        allowed_mcp_tool_approvals: allowed_approvals,
        required_tool_calls: mutation_calls ++ [%{server: "Jira", tool: "jira_get_issue"}]
      )

    validate_jira_write_result(result, run, expected_readback, scope)
  end

  defp jira_write_approvals(issue_key, scope) do
    Enum.map(scope.mutations, fn
      :comment -> %{server: "Jira", tool: "jira_add_comment", issue_key: issue_key, body_equals: scope.comment}
      :labels -> %{server: "Jira", tool: "jira_update_issue", issue_key: issue_key, labels_equals: scope.labels}
    end)
  end

  defp scoped_jira_operation(operation, issue_key, %{mutations: mutations, labels: labels}) do
    if :labels in mutations do
      operation <>
        "\nThe only permitted jira_update_issue arguments are issue_key=#{issue_key} " <>
        "and fields=#{Jason.encode!(%{"labels" => labels})}. Do not include other fields or arguments."
    else
      operation
    end
  end

  defp jira_mutation_tool_call(:comment), do: %{server: "Jira", tool: "jira_add_comment"}
  defp jira_mutation_tool_call(:labels), do: %{server: "Jira", tool: "jira_update_issue"}

  defp validate_jira_write_result(result, run, expected_readback, scope) do
    case result do
      {:ok, %{"status" => "PASS", "issue_key" => issue_key, "readback_text" => readback} = output}
      when is_binary(readback) ->
        labels_proven? =
          :labels not in scope.mutations or
            (Map.has_key?(output, "labels") and Enum.sort(normalize_strings(output["labels"])) == scope.labels)

        if issue_key == run["issue_key"] and String.contains?(readback, expected_readback) and labels_proven? do
          {:ok, output}
        else
          {:error, {:jira_readback_mismatch, run["issue_key"], expected_readback, scope.labels}}
        end

      {:ok, output} ->
        {:error, {:jira_write_unproven, output}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_issue(context, workspace, issue_key) do
    if native_transport?(context) do
      context.jira_reader.issue(issue_key,
        connector: context.jira_connector || SymphonyElixir.Factory.JiraMcpConnector,
        app_server: context.jira_app_server,
        workspace: workspace
      )
    else
      fetch_issue_from_controller(context, workspace, issue_key)
    end
  end

  defp fetch_issue_from_controller(context, workspace, issue_key) do
    case context.controller_task.run(
           context.factory,
           workspace,
           %Issue{id: issue_key, identifier: issue_key, title: "Jira read-back"},
           Prompt.jira_snapshot(issue_key),
           StageSchemas.for_stage(:jira_snapshot),
           control_server: context.control_server
         ) do
      {:ok, %{"status" => "PASS", "snapshot_json" => snapshot_json}} ->
        case decode_jira_snapshot(snapshot_json, :map) do
          {:ok, snapshot} -> {:ok, snapshot}
          :error -> {:error, :jira_readback_invalid_json}
        end

      {:ok, output} ->
        {:error, {:jira_readback_blocked, output}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_jira_snapshot(value, :list) when is_list(value), do: {:ok, value}
  defp decode_jira_snapshot(value, :map) when is_map(value), do: {:ok, value}

  defp decode_jira_snapshot(value, expected_type) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decode_jira_snapshot(decoded, expected_type)
      {:error, _reason} -> :error
    end
  end

  defp decode_jira_snapshot(_value, _expected_type), do: :error

  defp block_run(context, workspace, run, reason, acc) do
    detail = inspect(reason)

    operation =
      "Add comment `AI factory blocked: #{escape_jira_text(detail)}`; add label `ai-blocked`; " <>
        "remove labels `ai-running`, `ai-verifying`, and `ai-testing`; preserve all other labels."

    jira_result =
      jira_write(context, workspace, run, operation, "AI factory blocked:",
        approved_comment_body: "AI factory blocked: #{escape_jira_text(detail)}",
        label_add: ["ai-blocked"],
        label_remove: ["ai-running", "ai-verifying", "ai-testing"]
      )

    RunLedger.update(context.store, run["run_id"], %{
      state: "FAILED",
      failure_code: failure_code(reason),
      last_error: detail
    })

    event = if match?({:ok, %{"status" => "PASS"}}, jira_result), do: "RUN_BLOCKED", else: "RUN_BLOCKED_JIRA_WRITE_FAILED"
    acc = add_event(acc, run["issue_key"], event, detail)
    {:ok, cleanup_failed_specification(context, run, acc)}
  end

  defp cleanup_failed_specification(context, run, acc) do
    task_active? =
      context.store
      |> TaskLedger.list_for_run(run["run_id"])
      |> Enum.any?(&(&1["status"] in ["STARTING", "RUNNING"]))

    if run["kind"] == "SPECIFICATION" and run["factory_owned"] == 1 and
         is_binary(run["worktree"]) and not task_active? and not resumable_specification_task?(context.store, run) do
      path = run["worktree"]

      result =
        if File.dir?(path) do
          context.worktree.remove_detached(route_for_run(context, run), path)
        else
          :ok
        end

      case result do
        :ok ->
          RunLedger.update(context.store, run["run_id"], %{
            worktree: nil,
            workspace_state: "UNMATERIALIZED"
          })

          add_event(acc, run["issue_key"], "FAILED_SPECIFICATION_WORKTREE_REMOVED", path)

        {:error, reason} ->
          add_event(acc, run["issue_key"], "FAILED_SPECIFICATION_WORKTREE_PRESERVED", inspect(reason))
      end
    else
      acc
    end
  end

  defp resumable_specification_task?(store, run) do
    case TaskLedger.get(store, "#{run["run_id"]}:specification-author") do
      {:ok, %{"thread_id" => thread_id}} when is_binary(thread_id) -> thread_id != ""
      _other -> false
    end
  end

  defp cancel_run(context, run, reason, acc) do
    terminate_run_tasks(context, run["run_id"])
    detail = inspect(reason)

    RunLedger.update(context.store, run["run_id"], %{
      state: "CANCELLED",
      failure_code: failure_code(reason),
      last_error: detail
    })

    {:ok, add_event(acc, run["issue_key"], "RUN_CANCELLED", detail)}
  end

  defp terminate_run_tasks(context, run_id) do
    context.store
    |> TaskLedger.list_for_run(run_id)
    |> Enum.filter(&(&1["status"] in ["STARTING", "RUNNING"]))
    |> Enum.each(fn task ->
      case Map.get(context.active_tasks, task["task_key"]) do
        %{pid: pid} when is_pid(pid) -> Process.exit(pid, :kill)
        _other -> :ok
      end

      TaskLedger.update(context.store, task["task_key"], %{
        status: "CANCELLED",
        failure_code: "run cancelled during reconciliation"
      })
    end)
  end

  defp finalize_parent_delivery(_store, nil), do: :ok

  defp finalize_parent_delivery(store, parent_run_id) do
    case RunLedger.update(store, parent_run_id, %{state: "READY_FOR_REVIEW"}) do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp capacity(context, repo_key) do
    Capacity.snapshot(context.store, factory_policy(context), repo_key)
  end

  defp ensure_writer_capacity(context, repo_key, opts \\ []) do
    policy = factory_policy(context)

    case context.cleanup.ensure_capacity(context.store, policy, repo_key, opts) do
      {:error, {:insufficient_writer_capacity, _cleaned}} ->
        authorize_cleanup_candidates(context, policy, repo_key)
        context.cleanup.ensure_capacity(context.store, policy, repo_key, opts)

      result ->
        result
    end
  end

  defp ensure_run_writer(context, run, acc) do
    cond do
      native_transport?(context) ->
        native_run_writer(context, run, acc)

      present?(run["worktree"]) and File.dir?(run["worktree"]) ->
        {:ok, run, acc}

      true ->
        rehydrate_run_writer(context, run, acc)
    end
  end

  defp admit_writer_workspace(context, run, route) do
    if native_transport?(context) do
      if is_nil(run["worktree"]),
        do: {:ok, %{path: nil, branch: route["branch"]}},
        else: {:error, :native_run_workspace_conflict}
    else
      context.worktree.ensure_writer(route, run["issue_key"], run["run_id"])
    end
  end

  defp native_run_writer(context, run, acc) do
    route = writer_route(context, run)
    task_key = "#{run["run_id"]}:feature-writer"

    case TaskLedger.get(context.store, task_key) do
      {:ok, task} ->
        native_existing_writer(context, run, route, task, acc)

      {:error, :unknown_task} ->
        native_new_writer(context, run, route, acc)
    end
  end

  defp native_existing_writer(context, run, route, %{"workspace" => path, "workspace_sha" => sha} = task, acc)
       when is_binary(path) and path != "" and is_binary(sha) and sha != "" do
    with true <- run["worktree"] == path or {:error, :native_run_workspace_conflict},
         {:ok, verified} <- validate_native_writer_workspace(context, run, route, task, path, sha) do
      expected_sha = run["candidate_sha"] || sha
      {:ok, native_writer_run(run, verified.path, expected_sha), acc}
    end
  end

  defp native_existing_writer(_context, _run, _route, %{"thread_id" => thread_id}, _acc)
       when is_binary(thread_id) and thread_id != "",
       do: {:error, :native_writer_workspace_unbound}

  defp native_existing_writer(_context, run, route, %{"workspace_sha" => sha, "status" => status}, acc)
       when is_binary(sha) and sha != "" and
              status in ["STARTING", "RUNNING", "WAITING_FOR_BROKER", "WAITING_FOR_WRITER", "RETRY_PENDING"] do
    if is_nil(run["worktree"]),
      do: {:ok, native_writer_run(run, route["path"], sha), acc},
      else: {:error, :native_run_workspace_conflict}
  end

  defp native_existing_writer(_context, _run, _route, _task, _acc), do: {:error, :native_writer_sha_unbound}

  defp validate_native_writer_workspace(context, run, route, task, path, bootstrap_sha) do
    resuming_turn? = task["status"] == "STARTING" and present?(task["turn_id"])
    rearmed_investigation? = rearmed_writer_investigation?(run, task)

    active_turn? =
      resuming_turn? or
        task["status"] in ["RUNNING", "WAITING_FOR_BROKER", "WAITING_FOR_WRITER", "RETRY_PENDING", "COMPLETE"]

    branch = run["branch"]

    result =
      context.worktree.validate_native(route, path,
        clean: not (active_turn? or rearmed_investigation?),
        detached: false,
        expected_branch: branch,
        expected_sha: if(active_turn?, do: nil, else: run["candidate_sha"] || bootstrap_sha)
      )

    case {result, task["turn_id"], run["candidate_sha"]} do
      {{:error, {:native_worktree_branch_mismatch, expected_branch, ""}}, nil, nil}
      when expected_branch == branch ->
        context.worktree.validate_native(route, path, expected_sha: bootstrap_sha)

      _other ->
        result
    end
  end

  defp rearmed_writer_investigation?(run, task) do
    task["status"] == "CONSUMED" and
      task["failure_code"] in ["BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED", "CONTRACT_REVISION_REARMED"] and
      run["state"] == "WRITING" and
      task["workspace_sha"] == run["candidate_sha"]
  end

  defp native_new_writer(context, run, route, acc) do
    with true <- is_nil(run["worktree"]) or {:error, :native_run_workspace_conflict},
         {:ok, sha} <- stage_sha(context, route, run["candidate_sha"] || :base) do
      {:ok, native_writer_run(run, route["path"], sha), acc}
    end
  end

  defp native_writer_run(run, path, sha) do
    run |> Map.put("worktree", path) |> Map.put("_native_expected_sha", sha)
  end

  defp rehydrate_run_writer(context, run, acc) do
    route = writer_route(context, run)

    with {:ok, _capacity} <-
           ensure_writer_capacity(context, run["repo_key"], exclude_writer_issue_key: run["issue_key"]),
         {:ok, writer} <- context.worktree.ensure_writer(route, run["issue_key"], run["run_id"]),
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             worktree: writer.path,
             branch: writer.branch,
             workspace_state: "MATERIALIZED",
             hibernated_at: nil
           }) do
      materialized =
        run
        |> Map.put("worktree", writer.path)
        |> Map.put("branch", writer.branch)
        |> Map.put("workspace_state", "MATERIALIZED")
        |> Map.put("hibernated_at", nil)

      {:ok, materialized, add_event(acc, run["issue_key"], "WORKTREE_REHYDRATED", writer.path)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_hibernate_writer(context, run, acc) do
    if run["factory_owned"] == 0 do
      acc
    else
      hibernate_writer(context, run, acc)
    end
  end

  defp hibernate_writer(context, run, acc) do
    case context.cleanup.hibernate(context.store, factory_policy(context), run["run_id"], active_workspace: controller_workspace(context)) do
      {:ok, %{result: result} = hibernation} when result in ["HIBERNATED", "ALREADY_HIBERNATED"] ->
        add_event(acc, run["issue_key"], result, hibernation)

      {:ok, %{result: "SKIPPED"} = hibernation} ->
        add_event(acc, run["issue_key"], "HIBERNATION_SKIPPED", hibernation)

      {:error, reason} ->
        add_event(acc, run["issue_key"], "HIBERNATION_DEFERRED", inspect(reason))
    end
  end

  defp authorize_cleanup_candidates(context, policy, repo_key) do
    candidates = context.cleanup.authorization_candidates(context.store, policy, repo_key)

    if candidates == [] do
      :ok
    else
      workspace = controller_workspace(context)

      case context.controller_task.run(
             context.factory,
             workspace,
             controller_issue(context.factory.scope),
             Prompt.cleanup_authorization(candidates),
             StageSchemas.for_stage(:cleanup_authorization),
             control_server: context.control_server
           ) do
        {:ok, %{"status" => "PASS", "candidates" => readbacks}} ->
          authorize_cleanup_readbacks(context, policy, candidates, readbacks)

        _other ->
          :ok
      end
    end
  end

  defp sweep_one_cleanup_candidate(context) do
    policy = factory_policy(context)

    if cleanup_enabled?(Map.get(policy, "cleanup", %{})) do
      with %{} = candidate <- first_cleanup_candidate(context, policy),
           {:ok, %{"status" => "PASS", "candidates" => [readback]}} <-
             request_cleanup_authorization(context, candidate),
           true <- readback["run_id"] == candidate["run_id"],
           true <- readback["issue_key"] == candidate["issue_key"],
           {:ok, _authorized} <-
             context.cleanup.authorize(
               context.store,
               policy,
               candidate["run_id"],
               readback["jira_status"],
               readback["mr_state"]
             ) do
        context.cleanup.apply(context.store, policy, candidate["run_id"], active_workspace: controller_workspace(context))

        :ok
      else
        _other -> :ok
      end
    else
      :ok
    end
  end

  defp first_cleanup_candidate(context, policy) do
    context.factory.repositories
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn {repo_key, _repository} ->
      context.cleanup.authorization_candidates(context.store, policy, repo_key)
      |> List.first()
    end)
  end

  defp request_cleanup_authorization(context, candidate) do
    workspace = controller_workspace(context)

    context.controller_task.run(
      context.factory,
      workspace,
      controller_issue(context.factory.scope),
      Prompt.cleanup_authorization([candidate]),
      StageSchemas.for_stage(:cleanup_authorization),
      control_server: context.control_server
    )
  end

  defp cleanup_enabled?(%{"enabled" => true}), do: true
  defp cleanup_enabled?(%{enabled: true}), do: true
  defp cleanup_enabled?(_cleanup), do: false

  defp authorize_cleanup_readbacks(context, policy, candidates, readbacks) do
    expected = Map.new(candidates, &{&1["run_id"], &1["issue_key"]})

    Enum.each(readbacks, fn readback ->
      run_id = readback["run_id"]

      if Map.get(expected, run_id) == readback["issue_key"] do
        context.cleanup.authorize(
          context.store,
          policy,
          run_id,
          readback["jira_status"],
          readback["mr_state"]
        )
      end
    end)
  end

  defp factory_policy(context) do
    %{
      "capacity" => %{
        "maximum_specifiers" => context.factory.maximum_specifiers,
        "maximum_writers" => context.factory.maximum_writers,
        "maximum_validators" => context.factory.maximum_validators,
        "writer_disk_gb" => context.factory.writer_disk_gb
      },
      "repositories" => context.factory.repositories,
      "cleanup" => context.factory.cleanup,
      "hibernation" => Map.get(context.factory, :hibernation, %{})
    }
  end

  defp route_for_run(context, run) do
    context.factory.repositories
    |> Map.fetch!(run["repo_key"])
    |> Map.put("repo_key", run["repo_key"])
    |> Map.put("workspace_root", context.workspace_root)
  end

  defp writer_route(context, run) do
    snapshot = decode_json(run["snapshot_json"], %{})

    branch =
      run["branch"] ||
        Worktree.branch_name(
          run["issue_key"],
          snapshot_value(snapshot, "summary"),
          Map.get(context.factory, :branch_prefix, "ai")
        )

    route_for_run(context, run)
    |> Map.put("branch", branch)
    |> maybe_put_expected_sha(run["candidate_sha"])
  end

  defp maybe_put_expected_sha(route, nil), do: route
  defp maybe_put_expected_sha(route, sha), do: Map.put(route, "expected_sha", sha)

  defp bound_contract(run) do
    Contract.bind(run["issue_key"], run["spec_revision"], run["contract_markdown"])
  end

  defp update_active_snapshot(store, issue_key, snapshot) do
    case active_run_for_issue(store, issue_key) do
      nil ->
        :ok

      %{"kind" => "SPECIFICATION", "state" => state} = run when state in ["SPEC_DRAFTING", "SPEC_REVIEW"] ->
        previous = decode_json(run["snapshot_json"], %{})

        if specification_input(previous) == specification_input(snapshot) do
          :ok
        else
          RunLedger.update(store, run["run_id"], specification_snapshot_updates(state, snapshot))
        end

      run ->
        RunLedger.update(store, run["run_id"], %{snapshot_json: Jason.encode!(snapshot)})
    end
  end

  defp specification_snapshot_updates("SPEC_DRAFTING", snapshot),
    do: %{snapshot_json: Jason.encode!(snapshot), spec_revision: Contract.next_revision(snapshot)}

  defp specification_snapshot_updates(_state, snapshot), do: %{snapshot_json: Jason.encode!(snapshot)}

  defp active_runs(store) do
    placeholders = Enum.map_join(@terminal_states, ", ", fn _state -> "?" end)

    result =
      Store.query!(
        store,
        "SELECT * FROM runs WHERE state NOT IN (#{placeholders}) AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') ORDER BY created_at ASC",
        @terminal_states
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp active_run_for_issue(store, issue_key) do
    placeholders = Enum.map_join(@terminal_states, ", ", fn _state -> "?" end)

    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? AND state NOT IN (#{placeholders}) AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') ORDER BY created_at DESC LIMIT 1",
      [issue_key | @terminal_states]
    )
  end

  defp latest_run(store, issue_key, kind, state) do
    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? AND kind = ? AND state = ? ORDER BY created_at DESC LIMIT 1",
      [issue_key, kind, state]
    )
  end

  defp latest_issue_run(store, issue_key) do
    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') ORDER BY created_at DESC, rowid DESC LIMIT 1",
      [issue_key]
    )
  end

  defp latest_delivery_run(store, issue_key) do
    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? AND kind = 'DELIVERY' AND COALESCE(execution_mode, 'LEGACY') = 'LEGACY' AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = runs.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1') ORDER BY created_at DESC, rowid DESC LIMIT 1",
      [issue_key]
    )
  end

  defp issue_from_snapshot(snapshot) do
    %Issue{
      id: to_string(snapshot_value(snapshot, "id") || snapshot_value(snapshot, "key")),
      identifier: snapshot_value(snapshot, "key"),
      title: snapshot_value(snapshot, "summary") || "Factory work",
      description: snapshot_value(snapshot, "description"),
      state: snapshot_value(snapshot, "status"),
      url: snapshot_value(snapshot, "url"),
      labels: normalized_labels(snapshot)
    }
  end

  defp issue_from_run(run) do
    case decode_json(run["snapshot_json"], %{}) do
      %{} = snapshot when map_size(snapshot) > 0 -> issue_from_snapshot(snapshot)
      _other -> %Issue{id: run["issue_key"], identifier: run["issue_key"], title: "Factory work"}
    end
  end

  defp controller_issue(scope) do
    %Issue{id: "factory-controller", identifier: "FACTORY", title: scope}
  end

  defp mr_description(run) do
    snapshot = decode_json(run["snapshot_json"], %{})
    contract = run["contract_markdown"] || ""

    summary = mr_summary(contract, snapshot)

    changes =
      contract_section_items(contract, "In scope")
      |> bounded_description_items(2, 30)

    design_notes =
      contract_section_items(contract, "Shared decisions and dependencies")
      |> Enum.reject(&(String.downcase(&1) in ["none", "n/a", "not applicable"]))
      |> bounded_description_items(1, 30)

    acceptance_criteria = contract_section_items(contract, "Acceptance criteria")
    out_of_scope = contract_section_items(contract, "Out of scope") |> bounded_description_items(1, 55)

    risk = mr_risk(run)

    manual_validation = run["manual_validation_required"] in [true, 1]
    issue_key = run["issue_key"]

    acceptance_criteria =
      acceptance_criteria
      |> bounded_description_items(2, 50)

    summary_lines = [
      "## Summary",
      "",
      "#{summary}; the complete contract and rationale are in #{jira_reference(snapshot, issue_key)}."
    ]

    summary_lines = append_description_list(summary_lines, "### Changes", changes)
    summary_lines = append_description_list(summary_lines, "### Design notes", design_notes)
    root_cause = concise_description_section(contract, "Root cause", 55)
    summary_lines = append_description_label(summary_lines, "Root cause", optional_description_item(root_cause))
    summary_lines = append_description_label(summary_lines, "Why it wasn't caught", optional_description_item(mr_why_not_caught(contract)))
    summary_lines = append_description_label(summary_lines, "Risk", if(risk, do: [risk], else: []))
    summary_lines = append_description_label(summary_lines, "Out of scope", out_of_scope)

    test_lines = mr_test_lines(acceptance_criteria, contract, issue_key, manual_validation)

    Enum.join(summary_lines ++ [""] ++ test_lines, "\n")
    |> String.trim()
  end

  defp mr_summary(contract, snapshot) do
    [contract_section(contract, "Problem and outcome"), snapshot["summary"]]
    |> Enum.find(fn text ->
      is_binary(text) and description_word_count(description_first_sentence(text)) <= 40
    end)
    |> case do
      nil -> "See the confirmed Jira delivery contract"
      value -> description_first_sentence(value)
    end
    |> mr_description_text()
    |> String.replace(~r/[.!?]\s*$/u, "")
  end

  defp mr_risk(run) do
    contract_section_items(run["plan_markdown"] || "", "Risks and dependencies")
    |> Enum.find(&Regex.match?(~r/^risk\s*:/i, &1))
    |> case do
      nil -> nil
      value -> Regex.replace(~r/^risk\s*:\s*/i, value, "")
    end
    |> case do
      nil -> nil
      value -> bounded_description_items([value], 1, 55) |> List.first()
    end
  end

  defp mr_why_not_caught(contract) do
    concise_description_section(contract, "Why it wasn't caught", 55) ||
      concise_description_section(contract, "Why it was not caught", 55)
  end

  defp optional_description_item(nil), do: []
  defp optional_description_item(item), do: [item]

  defp mr_test_lines(acceptance_criteria, contract, issue_key, manual_validation) do
    test_lines = ["## Test plan", "" | Enum.map(acceptance_criteria, &"- #{mr_description_text(&1)}")]

    if manual_validation do
      manual = manual_validation_orientation(contract, issue_key)
      test_lines ++ ["", "### Manual testing", "", "- #{manual}"]
    else
      test_lines
    end
  end

  defp contract_section(markdown, title) do
    markdown
    |> contract_section_lines(title)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "- "))
    |> Enum.map(&mr_description_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp contract_section_items(markdown, title) do
    markdown
    |> contract_section_lines(title)
    |> Enum.filter(&String.starts_with?(String.trim(&1), "- "))
    |> Enum.map(fn line -> line |> String.trim() |> String.trim_leading("- ") |> mr_description_text() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp concise_description_section(markdown, title, max_words) do
    case contract_section(markdown, title) do
      text when is_binary(text) ->
        if description_word_count(text) <= max_words, do: text

      _other ->
        nil
    end
  end

  defp contract_section_lines(markdown, title) do
    header = Regex.compile!("^" <> "#" <> "{1,6}\\s+" <> Regex.escape(title) <> "\\s*$", "i")

    case Enum.split_while(String.split(markdown, "\n"), &(not Regex.match?(header, String.trim(&1)))) do
      {_before, []} -> []
      {_before, [_heading | rest]} -> Enum.take_while(rest, &(not Regex.match?(~r/^\s*#+\s+/, &1)))
    end
  end

  defp append_description_list(lines, _heading, []), do: lines

  defp append_description_list(lines, heading, items) do
    lines ++ ["", heading, "" | Enum.map(items, &"- #{mr_description_text(&1)}")]
  end

  defp bounded_description_items(items, max_items, max_words) do
    items
    |> Enum.filter(&(description_word_count(&1) <= max_words))
    |> Enum.take(max_items)
  end

  defp description_word_count(text) do
    Regex.scan(~r/[\p{L}\p{N}][\p{L}\p{N}'’.-]*/u, text) |> length()
  end

  defp description_first_sentence(text) do
    text |> String.split(~r/(?<=[.!?])\s+/u, parts: 2) |> List.first()
  end

  defp append_description_label(lines, _label, []), do: lines

  defp append_description_label(lines, label, items) do
    lines ++ ["", "**#{label}:** #{Enum.map_join(items, "; ", &mr_description_text/1)}"]
  end

  defp manual_validation_orientation(contract, issue_key) do
    manual = contract_section_items(contract, "Manual Validation")
    fields = Enum.filter(manual, &Regex.match?(~r/^(?:Environment|Services?|Cases):/i, &1))
    cases = Enum.filter(manual, &Regex.match?(~r/^MV-\d+:/i, &1))

    orientation =
      Enum.uniq(fields ++ cases)
      |> Enum.map_join("; ", &mr_description_text/1)

    case orientation do
      "" ->
        "See Jira #{issue_key} for the exact approved environment and validation cases."

      text ->
        if description_word_count(text) <= 50,
          do: text,
          else: "See Jira #{issue_key} for the exact approved environment and validation cases."
    end
  end

  defp jira_reference(snapshot, issue_key) do
    case URI.parse(snapshot["url"] || "") do
      %URI{scheme: "https", host: host} = uri when is_binary(host) and host != "" ->
        "[#{issue_key}](#{URI.to_string(uri)})"

      _other ->
        issue_key
    end
  end

  defp mr_description_text(text) when is_binary(text) do
    text
    |> String.replace(~r/```[^\n]*\n|```/u, "")
    |> String.replace(~r/[\r\n\t]+/u, " ")
    |> String.replace(~r/^\s*(?:[-*+]\s+|\d+[.)]\s+)/u, "")
    |> String.replace("`", "")
    |> String.replace("[", "")
    |> String.replace("]", "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp mr_description_text(_text), do: ""

  defp task_name(issue_key, role), do: "#{issue_key} · #{role}"

  defp task_name(issue_key, role, round), do: "#{issue_key} · R#{round} · #{role}"

  defp decode_json(nil, default), do: default

  defp decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp decode_json!(json), do: Jason.decode!(json)

  defp normalized_labels(snapshot), do: snapshot |> snapshot_value("labels") |> normalize_strings()

  defp normalize_strings(values) when is_list(values) do
    values
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_strings(_values), do: []

  defp normalize_status(nil), do: ""

  defp normalize_status(value) do
    value |> to_string() |> String.trim() |> String.upcase()
  end

  defp snapshot_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, maybe_existing_atom(key)))
  end

  defp maybe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing_factory_key__
  end

  defp routing_required(acc, snapshot) do
    issue_key = snapshot_value(snapshot, "key")
    %{acc | routing_required: [issue_key | acc.routing_required]}
  end

  defp add_event(acc, issue_key, event, detail) do
    %{acc | events: [%{issue_key: issue_key, event: event, detail: detail} | acc.events]}
  end

  defp failure_code(reason) do
    reason
    |> inspect()
    |> String.slice(0, 200)
  end

  defp ticket_deferral_code(reason, _depth) when is_atom(reason), do: Atom.to_string(reason)

  defp ticket_deferral_code(reason, depth) when is_tuple(reason) and depth > 0 do
    reason
    |> Tuple.to_list()
    |> Enum.take(3)
    |> Enum.map(&ticket_deferral_code(&1, depth - 1))
    |> Enum.reject(&(&1 == "unclassified"))
    |> Enum.join(":")
  end

  defp ticket_deferral_code(_reason, _depth), do: "unclassified"

  defp escape_jira_text(value) do
    value |> String.replace("`", "'") |> String.replace(~r/\s+/, " ") |> String.slice(0, 1_000)
  end

  defp quote_jql(value) do
    escaped = value |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp safe(value), do: String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
