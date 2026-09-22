defmodule SymphonyElixir.Factory.Scheduler do
  @moduledoc """
  One bounded, restart-safe Jira-to-GitLab factory reconciliation tick.

  Long-running cognitive stages are launched asynchronously. Jira/GitLab
  connector operations remain serialized in the persistent controller task.
  Every state transition is durable before the tick returns.
  """

  require Logger

  alias SymphonyElixir.Config

  alias SymphonyElixir.Factory.{
    Capacity,
    Cleanup,
    Contract,
    ControllerTask,
    Prompt,
    Queue,
    RunLedger,
    StageSchemas,
    Store,
    TaskLauncher,
    TaskLedger,
    Worktree
  }

  alias SymphonyElixir.Tracker.Issue

  @terminal_states ~w(READY_FOR_REVIEW DELIVERED AWAITING_VALIDATION CANCELLED FAILED)
  @type context :: map()

  @doc "Runs one serialized reconciliation and dispatch tick."
  @spec tick(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def tick(context, opts \\ []) do
    context = dependencies(context, opts)
    workspace = controller_workspace(context)
    File.mkdir_p!(workspace)

    with :ok <- reconcile_stale_tasks(context),
         {:ok, jql} <- Queue.jql(context.factory.queue),
         {:ok, queued_snapshots} <- fetch_queue(context, workspace, jql),
         {:ok, snapshots} <- fetch_active_snapshots(context, workspace, queued_snapshots),
         {:ok, intake} <- reconcile_intake(context, snapshots) do
      advance_runs(context, workspace, intake)
    end
  end

  defp dependencies(context, opts) do
    context
    |> Map.put_new(:workspace_root, Config.local_workspace_root())
    |> Map.put_new(:active_tasks, %{})
    |> Map.put(:controller_task, Keyword.get(opts, :controller_task, ControllerTask))
    |> Map.put(:task_launcher, Keyword.get(opts, :task_launcher, TaskLauncher))
    |> Map.put(:worktree, Keyword.get(opts, :worktree, Worktree))
    |> Map.put(:cleanup, Keyword.get(opts, :cleanup, Cleanup))
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
        SELECT task_key FROM factory_tasks
        WHERE status IN ('STARTING', 'RUNNING') AND updated_at < ?
        """,
        [cutoff]
      )

    Enum.each(result.rows, fn [task_key] ->
      case Map.get(context.active_tasks, task_key) do
        %{pid: pid} when is_pid(pid) -> Process.exit(pid, :kill)
        _other -> :ok
      end

      TaskLedger.update(context.store, task_key, %{
        status: "STALE",
        failure_code: "stale task exceeded #{context.factory.stale_task_minutes} minutes"
      })
    end)

    :ok
  end

  defp controller_workspace(context) do
    context.workspace_root
    |> Path.expand()
    |> Path.join("factory-controller")
    |> Path.join(safe(context.factory.scope))
  end

  defp fetch_queue(context, workspace, jql) do
    issue = controller_issue(context.factory.scope)

    case context.controller_task.run(
           context.factory,
           workspace,
           issue,
           Prompt.jira_intake(jql),
           StageSchemas.for_stage(:jira_snapshot),
           control_server: context.control_server
         ) do
      {:ok, %{"status" => "PASS", "snapshot_json" => snapshot_json}} ->
        case Jason.decode(snapshot_json) do
          {:ok, snapshots} when is_list(snapshots) -> {:ok, snapshots}
          _other -> {:error, :jira_intake_invalid_snapshot_json}
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
      context.store
      |> active_issue_keys()
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
      "SELECT DISTINCT issue_key FROM runs WHERE state NOT IN (#{placeholders}) ORDER BY issue_key",
      @terminal_states
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [issue_key] -> issue_key end)
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
      update_active_snapshot(context.store, issue_key, snapshot)

      if active_run_for_issue(context.store, issue_key) do
        {:ok, acc}
      else
        register_classified_snapshot(context, snapshot, acc)
      end
    else
      {:error, :jira_snapshot_missing_key}
    end
  end

  defp register_classified_snapshot(context, snapshot, acc) do
    case Queue.classify(snapshot) do
      :specification -> register_specification(context, snapshot, acc)
      :delivery -> register_delivery(context, snapshot, acc)
      :reconcile -> {:ok, acc}
      :ignore -> {:ok, acc}
      {:error, reason} -> {:ok, add_event(acc, snapshot_value(snapshot, "key"), "INTAKE_BLOCKED", reason)}
    end
  end

  defp register_specification(context, snapshot, acc) do
    with {:ok, route} <- Queue.route(snapshot, context.factory.repositories),
         {:ok, capacity} <- capacity(context, route["repo_key"]),
         true <- capacity.available_specifier_slots > 0 or {:skip, :specifier_capacity},
         {:ok, %{run: run}} <-
           RunLedger.register(context.store, %{
             run_id: Ecto.UUID.generate(),
             issue_key: snapshot_value(snapshot, "key"),
             kind: "SPECIFICATION",
             state: "SPEC_DRAFTING",
             dispatcher_id: context.factory.dispatcher_id,
             spec_revision: Contract.next_revision(snapshot),
             repo_key: route["repo_key"],
             repo_path: route["path"],
             base_branch: route["base_branch"],
             snapshot_json: Jason.encode!(snapshot),
             runtime: "codex-app-server"
           }) do
      {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_REGISTERED", run["run_id"])}
    else
      {:error, :routing_required} -> {:ok, routing_required(acc, snapshot)}
      {:error, :ambiguous_repository_route} -> {:ok, routing_required(acc, snapshot)}
      {:skip, _reason} -> {:ok, acc}
      {:error, reason} -> {:error, {:specification_registration_failed, reason}}
    end
  end

  defp register_delivery(context, snapshot, acc) do
    issue_key = snapshot_value(snapshot, "key")

    branch =
      Worktree.branch_name(
        issue_key,
        snapshot_value(snapshot, "summary"),
        Map.get(context.factory, :branch_prefix, "ai")
      )

    with {:ok, route} <- Queue.route(snapshot, context.factory.repositories),
         {:ok, contract} <- Contract.authorized_from_snapshot(snapshot, issue_key),
         {:ok, manual_required} <- Contract.manual_validation_required(contract.markdown),
         {:ok, manual_environment} <- Contract.manual_validation_environment(contract.markdown),
         :ok <- validate_manual_policy(context.factory.manual_validation, manual_required, manual_environment),
         {:ok, _capacity} <- ensure_writer_capacity(context, route["repo_key"]),
         {:ok, %{run: run}} <-
           RunLedger.register(context.store, %{
             run_id: Ecto.UUID.generate(),
             issue_key: issue_key,
             kind: "DELIVERY",
             state: "PLANNING",
             dispatcher_id: context.factory.dispatcher_id,
             spec_revision: contract.revision,
             contract_sha256: contract.sha256,
             contract_markdown: contract.markdown,
             manual_validation_required: manual_required,
             repo_key: route["repo_key"],
             repo_path: route["path"],
             base_branch: route["base_branch"],
             branch: branch,
             snapshot_json: Jason.encode!(snapshot),
             runtime: "codex-app-server"
           }) do
      {:ok, add_event(acc, run["issue_key"], "DELIVERY_REGISTERED", run["run_id"])}
    else
      {:error, :routing_required} ->
        {:ok, routing_required(acc, snapshot)}

      {:error, :ambiguous_repository_route} ->
        {:ok, routing_required(acc, snapshot)}

      {:error, :confirmed_authorization_missing} ->
        {:ok, add_event(acc, issue_key, "AUTHORIZATION_REQUIRED", nil)}

      {:error, {:insufficient_writer_capacity, _cleaned}} ->
        {:ok, add_event(acc, issue_key, "INSUFFICIENT_WRITER_CAPACITY", nil)}

      {:error, reason} ->
        {:error, {:delivery_registration_failed, reason}}
    end
  end

  defp maybe_register_validations(context, snapshots, acc) do
    Enum.reduce(snapshots, acc, fn snapshot, current ->
      issue_key = snapshot_value(snapshot, "key")

      if "ai-testing" in normalized_labels(snapshot) and is_nil(active_run_for_issue(context.store, issue_key)) do
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
             runtime: "codex-app-server"
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

  defp advance_run(context, workspace, run, acc) do
    case validate_run_snapshot(context, run) do
      :ok -> advance_valid_run(context, workspace, run, acc)
      {:cancel, reason} -> cancel_run(context, run, reason, acc)
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
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

    with :ok <- validate_status(status, allowed_statuses, snapshot),
         :ok <- validate_kind_labels(run["kind"], labels) do
      validate_authorization(run, snapshot)
    end
  end

  defp validate_status(status, allowed, snapshot) do
    if status in allowed do
      :ok
    else
      {:cancel, {:jira_status_left_factory_scope, snapshot_value(snapshot, "status")}}
    end
  end

  defp validate_kind_labels("SPECIFICATION", labels) do
    if Enum.any?(["spec-needed", "needs-decision"], &(&1 in labels)) do
      :ok
    else
      {:cancel, :specification_labels_removed}
    end
  end

  defp validate_kind_labels("DELIVERY", labels) do
    if delivery_label?(labels), do: :ok, else: {:cancel, :delivery_labels_removed}
  end

  defp validate_kind_labels("VALIDATION", labels) do
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

  defp delivery_label?(labels) do
    Enum.any?(["ai-ready", "ai-running", "ai-verifying", "ai-testing"], &(&1 in labels))
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_DRAFTING"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    snapshot = Map.put(snapshot, "factory_repair_findings", decode_json(run["repair_findings_json"], []))
    route = route_for_run(context, run)

    with {:ok, base_sha} <- context.worktree.base_sha(route),
         {:ok, specification_path} <-
           context.worktree.create_detached(route, run["issue_key"], run["run_id"], "specification", base_sha),
         {:ok, _updated} <- RunLedger.update(context.store, run["run_id"], %{worktree: specification_path}) do
      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: specification_path,
        prompt: Prompt.specification_author(snapshot, route),
        schema: StageSchemas.for_stage(:specification_author),
        task_key: "#{run["run_id"]}:specification-author",
        stage: "SPEC_DRAFTING",
        role: "specification-author",
        thread_name: task_name(run["issue_key"], "Specification Author"),
        persistent?: true
      }

      launch_or_consume(context, run, stage, acc, &consume_specification_author(context, run, &1, &2))
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_WRITING"} = run, acc) do
    contract = bound_contract(run)
    comment = Contract.draft_comment(contract)

    operation = "Add exactly one Jira comment whose complete plain-text body is:\n#{comment}"

    with {:ok, output} <- jira_write(context, workspace, run, operation, contract.marker),
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

    with {:ok, base_sha} <- context.worktree.base_sha(route),
         {:ok, critic_path} <-
           context.worktree.create_detached(
             route,
             run["issue_key"],
             run["run_id"],
             "specification-critic-#{run["verifier_round"]}",
             base_sha
           ) do
      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: critic_path,
        prompt: Prompt.specification_critic(snapshot, run["contract_markdown"], run["contract_sha256"]),
        schema: StageSchemas.for_stage(:specification_critic),
        task_key: "#{run["run_id"]}:specification-critic:#{run["verifier_round"]}",
        stage: "SPEC_REVIEW",
        role: "specification-critic",
        thread_name: task_name(run["issue_key"], "Specification Critic", run["verifier_round"]),
        persistent?: false
      }

      launch_or_consume(
        context,
        run,
        stage,
        acc,
        &consume_specification_critic(context, run, route, critic_path, &1, &2)
      )
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "SPEC_READY_WRITE"} = run, acc) do
    contract = bound_contract(run)
    ready = Contract.ready_marker(contract)
    confirmation = Contract.confirmation_marker(contract)

    body = "#{ready}\n\nIndependent specification review passed. To authorize implementation, add this exact Jira comment:\n#{confirmation}"
    operation = "Add exactly one Jira comment whose complete plain-text body is:\n#{body}"

    with {:ok, %{"status" => "PASS"}} <- jira_write(context, workspace, run, operation, ready),
         {:ok, _updated} <- RunLedger.update(context.store, run["run_id"], %{state: "AWAITING_CONFIRMATION"}) do
      {:ok, add_event(acc, run["issue_key"], "HUMAN_CONFIRMATION_REQUIRED", confirmation)}
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
      _other -> block_run(context, workspace, run, :jira_ready_marker_failed, acc)
    end
  end

  defp advance_specification(context, workspace, %{"state" => "AWAITING_CONFIRMATION"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])
    contract = bound_contract(run)

    case Contract.confirmation(snapshot, contract) do
      {:ok, comment} ->
        comment_id = to_string(snapshot_value(comment, "id"))
        authorization = Contract.authorization_marker(contract, comment_id)

        operation =
          "Add exactly one comment with body `#{authorization}`; add label `ai-ready`; " <>
            "remove labels `spec-needed`, `needs-decision`, and `ai-blocked`; preserve all other labels."

        with {:ok, %{"status" => "PASS", "labels" => labels}} <-
               jira_write(context, workspace, run, operation, authorization),
             true <- "ai-ready" in normalize_strings(labels) or {:error, :ai_ready_readback_missing},
             :ok <- remove_optional_detached(context, run),
             {:ok, _updated} <-
               RunLedger.update(context.store, run["run_id"], %{
                 state: "DELIVERED",
                 confirmation_comment_id: comment_id
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

  defp advance_specification(context, _workspace, %{"state" => "AWAITING_SPEC_INPUT"} = run, acc) do
    snapshot = decode_json!(run["snapshot_json"])

    case Contract.specification_input(snapshot, run["issue_key"], run["last_input_marker"]) do
      {:ok, comment} ->
        if run["attempt"] < 3 do
          RunLedger.update(context.store, run["run_id"], %{
            state: "SPEC_DRAFTING",
            attempt: run["attempt"] + 1,
            repair_findings_json: Jason.encode!([]),
            last_input_marker: to_string(snapshot_value(comment, "id"))
          })

          {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_INPUT_RECEIVED", snapshot_value(comment, "id"))}
        else
          block_run(context, controller_workspace(context), run, :specification_attempt_limit, acc)
        end

      :missing ->
        {:ok, acc}
    end
  end

  defp advance_specification(_context, _workspace, _run, acc), do: {:ok, acc}

  defp consume_specification_author(context, run, output, acc) do
    case output do
      %{
        "status" => "DRAFTED",
        "contract_markdown" => markdown,
        "risk" => risk,
        "risk_signals" => risk_signals,
        "manual_validation_required" => manual_required
      } ->
        contract = Contract.bind(run["issue_key"], run["spec_revision"], markdown)

        case Contract.manual_validation_required(contract.markdown) do
          {:ok, ^manual_required} ->
            RunLedger.update(context.store, run["run_id"], %{
              state: "SPEC_WRITING",
              contract_markdown: contract.markdown,
              contract_sha256: contract.sha256,
              manual_validation_required: manual_required,
              risk: risk,
              risk_signals_json: Jason.encode!(risk_signals),
              repair_findings_json: Jason.encode!([])
            })

            {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_DRAFTED", contract.sha256)}

          {:ok, _other} ->
            {:error, :manual_validation_decision_mismatch}

          {:error, reason} ->
            {:error, reason}
        end

      %{"status" => "BLOCKED", "questions" => questions} ->
        request_specification_input(context, run, questions, acc)

      _other ->
        {:error, :invalid_specification_author_output}
    end
  end

  defp request_specification_input(context, run, questions, acc) do
    questions_sha256 = Contract.questions_digest(questions)
    marker = Contract.input_marker(run["issue_key"], questions_sha256)

    question_list =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {question, index} -> "#{index}. #{question}" end)

    body =
      "AI FACTORY SPEC INPUT REQUIRED issue=#{run["issue_key"]} questions_sha256=#{questions_sha256}\n\n" <>
        question_list <>
        "\n\nReply in one Jira comment beginning with this exact first line, followed by your answers:\n#{marker}"

    operation =
      "Add exactly one Jira comment whose complete plain-text body is:\n#{body}\n" <>
        "Add label `needs-decision`; preserve `spec-needed` and all other labels."

    with {:ok, %{"status" => "PASS"}} <-
           jira_write(context, controller_workspace(context), run, operation, questions_sha256),
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
    with :ok <- context.worktree.remove_detached(route, critic_path) do
      consume_specification_critic_output(context, run, output, acc)
    end
  end

  defp consume_specification_critic_output(context, run, %{"status" => "PASS"}, acc) do
    RunLedger.update(context.store, run["run_id"], %{state: "SPEC_READY_WRITE"})
    {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_REVIEW_PASSED", nil)}
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
      RunLedger.update(context.store, run["run_id"], %{
        state: "SPEC_DRAFTING",
        attempt: run["attempt"] + 1,
        repair_findings_json: Jason.encode!(findings ++ questions)
      })

      {:ok, add_event(acc, run["issue_key"], "SPECIFICATION_REPAIR", findings ++ questions)}
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

    with {:ok, base_sha} <- context.worktree.base_sha(route),
         {:ok, planning_path} <-
           context.worktree.create_detached(route, run["issue_key"], run["run_id"], "planning", base_sha) do
      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: planning_path,
        prompt: Prompt.feature_planner(snapshot, run["contract_markdown"], run["contract_sha256"], route),
        schema: StageSchemas.for_stage(:feature_planner),
        task_key: "#{run["run_id"]}:feature-planner",
        stage: "PLANNING",
        role: "feature-planner",
        thread_name: task_name(run["issue_key"], "Feature Planner"),
        persistent?: false
      }

      launch_or_consume(context, run, stage, acc, &consume_feature_planner(context, run, route, planning_path, &1, &2))
    else
      {:error, reason} -> block_run(context, workspace, run, reason, acc)
    end
  end

  defp advance_delivery(context, workspace, %{"state" => "ADMITTING_WRITER"} = run, acc) do
    route = writer_route(context, run)

    with {:ok, _capacity} <- ensure_writer_capacity(context, run["repo_key"]),
         {:ok, writer} <- context.worktree.ensure_writer(route, run["issue_key"], run["run_id"]),
         operation =
           "Add label `ai-running`; remove labels `ai-ready` and `ai-verifying`; preserve all other labels.",
         {:ok, %{"status" => "PASS", "labels" => labels}} <-
           jira_write(context, workspace, run, operation, "ai-running"),
         true <- "ai-running" in normalize_strings(labels) or {:error, :ai_running_readback_missing},
         {:ok, _updated} <-
           RunLedger.update(context.store, run["run_id"], %{
             state: "WRITING",
             worktree: writer.path,
             branch: writer.branch,
             workspace_state: "MATERIALIZED",
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
       when state in ["WRITING", "REPAIRING"] do
    with {:ok, materialized_run, updated_acc} <- ensure_run_writer(context, run, acc) do
      advance_writer(context, materialized_run, updated_acc)
    end
  end

  defp advance_delivery(context, _workspace, %{"state" => "VERIFYING"} = run, acc) do
    advance_verifier(context, run, acc)
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

  defp consume_feature_planner(context, run, route, planning_path, output, acc) do
    with :ok <- context.worktree.remove_detached(route, planning_path) do
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
      stage = %{
        issue: issue_from_snapshot(snapshot),
        workspace: run["worktree"],
        prompt:
          Prompt.feature_writer(
            snapshot,
            run["contract_markdown"],
            run["contract_sha256"],
            run["plan_markdown"],
            iteration,
            findings
          ),
        schema: StageSchemas.for_stage(:feature_writer),
        task_key: "#{run["run_id"]}:feature-writer",
        stage: run["state"],
        role: "feature-writer",
        thread_name: task_name(run["issue_key"], "Feature Writer"),
        persistent?: true
      }

      launch_or_consume(context, run, stage, acc, &consume_feature_writer(context, run, iteration, &1, &2))
    end
  end

  defp consume_feature_writer(context, run, iteration, output, acc) do
    case output do
      %{"status" => "CONTINUE", "commit_sha" => commit_sha} ->
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

      %{"status" => "COMPLETE", "commit_sha" => commit_sha} ->
        with {:ok, head} <- context.worktree.candidate(run["worktree"], run["base_branch"]),
             true <- commit_sha == head or {:error, :writer_sha_mismatch},
             {:ok, _updated} <-
               RunLedger.update(context.store, run["run_id"], %{
                 state: "VERIFYING",
                 implementation_iteration: iteration,
                 candidate_sha: head,
                 verifier_round: run["verifier_round"] + 1,
                 repair_findings_json: Jason.encode!([])
               }) do
          {:ok, add_event(acc, run["issue_key"], "CANDIDATE_READY", head)}
        end

      %{"status" => "BLOCKED", "blockers" => blockers} ->
        {:error, {:writer_blocked, blockers}}

      _other ->
        {:error, :invalid_feature_writer_output}
    end
  end

  defp advance_verifier(context, run, acc) do
    route = route_for_run(context, run)
    stage = "verify-#{run["verifier_round"]}"

    with {:ok, verification_path} <-
           context.worktree.create_detached(
             route,
             run["issue_key"],
             run["run_id"],
             stage,
             run["candidate_sha"]
           ) do
      snapshot = decode_json!(run["snapshot_json"])

      stage_spec = %{
        issue: issue_from_snapshot(snapshot),
        workspace: verification_path,
        prompt:
          Prompt.change_verifier(
            snapshot,
            run["contract_markdown"],
            run["contract_sha256"],
            run["candidate_sha"],
            run["base_branch"]
          ),
        schema: StageSchemas.for_stage(:change_verifier),
        task_key: "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}",
        stage: "VERIFYING",
        role: "change-verifier",
        thread_name: task_name(run["issue_key"], "Change Verifier", run["verifier_round"]),
        persistent?: false
      }

      launch_or_consume(
        context,
        run,
        stage_spec,
        acc,
        &consume_change_verifier(context, run, route, verification_path, &1, &2)
      )
    end
  end

  defp consume_change_verifier(context, run, route, verification_path, output, acc) do
    cleanup_result = context.worktree.remove_detached(route, verification_path)

    with :ok <- cleanup_result,
         true <- output["candidate_sha"] == run["candidate_sha"] or {:error, :verifier_sha_mismatch} do
      consume_change_verifier_output(context, run, output, acc)
    end
  end

  defp consume_change_verifier_output(context, run, %{"status" => "PASS"}, acc) do
    RunLedger.update(context.store, run["run_id"], %{state: "PUSHING"})
    {:ok, add_event(acc, run["issue_key"], "VERIFICATION_PASSED", run["candidate_sha"])}
  end

  defp consume_change_verifier_output(context, run, %{"status" => "REPAIR", "findings" => findings}, acc) do
    repair_round = run["code_repair_round"] + 1

    if repair_round <= context.factory.maximum_code_repair_rounds do
      RunLedger.update(context.store, run["run_id"], %{
        state: "REPAIRING",
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
           jira_write(context, workspace, run, operation, output["mr_url"]),
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
      output["state"] == "opened"
    ])
  end

  defp advance_validation(context, workspace, run, acc) do
    route = route_for_run(context, run)
    attempt = run["validation_attempt"] + 1
    stage = "validate-#{attempt}"

    with {:ok, validation_path} <-
           context.worktree.create_detached(
             route,
             run["issue_key"],
             run["run_id"],
             stage,
             run["candidate_sha"]
           ) do
      stage_spec = %{
        issue: issue_from_run(run),
        workspace: validation_path,
        prompt: Prompt.manual_validator(run, run["contract_markdown"], run["candidate_sha"], route),
        schema: StageSchemas.for_stage(:manual_validator),
        task_key: "#{run["run_id"]}:manual-validator",
        stage: "TESTING",
        role: "manual-validator",
        thread_name: task_name(run["issue_key"], "Manual Validator"),
        required_apps: Map.get(context.factory.manual_validation, "required_apps", []),
        required_mcp_servers: Map.get(context.factory.manual_validation, "required_mcp_servers", []),
        mcp_startup_timeout_ms: Map.get(context.factory.manual_validation, "startup_timeout_ms", 60_000),
        persistent?: true
      }

      launch_or_consume(
        context,
        run,
        stage_spec,
        acc,
        &consume_manual_validation(context, workspace, run, route, validation_path, attempt, &1, &2)
      )
    end
  end

  defp consume_manual_validation(context, workspace, run, route, validation_path, attempt, output, acc) do
    cleanup_result = context.worktree.remove_detached(route, validation_path)

    with :ok <- cleanup_result,
         true <- output["candidate_sha"] == run["candidate_sha"] or {:error, :validator_sha_mismatch},
         :ok <- validate_manual_result(context.factory.manual_validation, output) do
      consume_manual_validation_output(context, workspace, run, attempt, output, acc)
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

  defp validate_manual_result(_policy, %{"status" => "BLOCK"}), do: :ok

  defp validate_manual_result(policy, output) do
    environment = output["environment"] |> to_string() |> String.trim() |> String.downcase()
    allowed = Map.get(policy, "allowed_environments", []) |> Enum.map(&String.downcase(to_string(&1)))

    cond do
      environment not in allowed ->
        {:error, {:manual_validation_environment_not_allowed, environment}}

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
    description = mr_description(run) <> "\n\n## Automated manual validation\n\n" <> evidence

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
           jira_write(context, workspace, run, operation, run["candidate_sha"]),
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
      {:ok, %{"status" => "COMPLETE", "output_json" => output_json}} ->
        output = decode_json!(output_json)

        case consumer.(output, acc) do
          {:ok, _updated_acc} = ok ->
            TaskLedger.update(context.store, stage_spec.task_key, %{status: "CONSUMED"})
            ok

          {:error, reason} ->
            block_run(context, controller_workspace(context), run, reason, acc)
        end

      {:ok, %{"status" => "FAILED", "failure_code" => reason}} ->
        cleanup = cleanup_failed_stage(context, run, stage_spec.workspace, stage_spec.role)
        block_run(context, controller_workspace(context), run, {:task_failed, reason, cleanup}, acc)

      _other ->
        launch_stage(context, run, stage_spec, acc)
    end
  end

  defp cleanup_failed_stage(context, run, workspace, role)
       when role in ["specification-author", "specification-critic", "feature-planner", "change-verifier", "manual-validator"] do
    context.worktree.remove_detached(route_for_run(context, run), workspace)
  end

  defp cleanup_failed_stage(_context, _run, _workspace, _role), do: :not_applicable

  defp remove_optional_detached(_context, %{"worktree" => nil}), do: :ok

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
        thread_name: stage_spec.thread_name,
        required_apps: Map.get(stage_spec, :required_apps, []),
        required_mcp_servers: Map.get(stage_spec, :required_mcp_servers, []),
        mcp_startup_timeout_ms: Map.get(stage_spec, :mcp_startup_timeout_ms, 60_000),
        resume_terminal: stage_spec.persistent?,
        active_task_keys: context.active_task_keys
      )

    case result do
      {:ok, launch} -> {:ok, %{acc | launches: [launch | acc.launches]}}
      {:already_running, _task} -> {:ok, acc}
      {:already_terminal, _task} -> {:ok, acc}
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp jira_write(context, workspace, run, operation, expected_readback) do
    case context.controller_task.run(
           context.factory,
           workspace,
           issue_from_run(run),
           Prompt.jira_write(run["issue_key"], operation, expected_readback),
           StageSchemas.for_stage(:jira_write),
           control_server: context.control_server
         ) do
      {:ok, %{"status" => "PASS", "readback_text" => readback} = output}
      when is_binary(readback) ->
        if String.contains?(readback, expected_readback) do
          {:ok, output}
        else
          {:error, {:jira_readback_text_mismatch, expected_readback}}
        end

      {:ok, output} ->
        {:error, {:jira_write_unproven, output}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_issue(context, workspace, issue_key) do
    case context.controller_task.run(
           context.factory,
           workspace,
           %Issue{id: issue_key, identifier: issue_key, title: "Jira read-back"},
           Prompt.jira_snapshot(issue_key),
           StageSchemas.for_stage(:jira_snapshot),
           control_server: context.control_server
         ) do
      {:ok, %{"status" => "PASS", "snapshot_json" => json}} ->
        case Jason.decode(json) do
          {:ok, %{} = snapshot} -> {:ok, snapshot}
          _other -> {:error, :jira_readback_invalid_json}
        end

      {:ok, output} ->
        {:error, {:jira_readback_blocked, output}}

      {:error, _reason} = error ->
        error
    end
  end

  defp block_run(context, workspace, run, reason, acc) do
    detail = inspect(reason)

    operation =
      "Add comment `AI factory blocked: #{escape_jira_text(detail)}`; add label `ai-blocked`; " <>
        "remove labels `ai-running`, `ai-verifying`, and `ai-testing`; preserve all other labels."

    jira_result = jira_write(context, workspace, run, operation, "AI factory blocked:")

    RunLedger.update(context.store, run["run_id"], %{
      state: "FAILED",
      failure_code: failure_code(reason),
      last_error: detail
    })

    event = if match?({:ok, %{"status" => "PASS"}}, jira_result), do: "RUN_BLOCKED", else: "RUN_BLOCKED_JIRA_WRITE_FAILED"
    {:ok, add_event(acc, run["issue_key"], event, detail)}
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
    if present?(run["worktree"]) and File.dir?(run["worktree"]) do
      {:ok, run, acc}
    else
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
  end

  defp maybe_hibernate_writer(context, run, acc) do
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
      nil -> :ok
      run -> RunLedger.update(store, run["run_id"], %{snapshot_json: Jason.encode!(snapshot)})
    end
  end

  defp active_runs(store) do
    placeholders = Enum.map_join(@terminal_states, ", ", fn _state -> "?" end)

    result =
      Store.query!(
        store,
        "SELECT * FROM runs WHERE state NOT IN (#{placeholders}) ORDER BY created_at ASC",
        @terminal_states
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp active_run_for_issue(store, issue_key) do
    placeholders = Enum.map_join(@terminal_states, ", ", fn _state -> "?" end)

    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? AND state NOT IN (#{placeholders}) ORDER BY created_at DESC LIMIT 1",
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
    """
    ## Summary

    Automated factory delivery for #{run["issue_key"]}.

    ## Confirmed contract

    - Revision: #{run["spec_revision"]}
    - SHA-256: `#{run["contract_sha256"]}`
    - Candidate: `#{run["candidate_sha"]}`

    #{run["contract_markdown"]}

    ## Verification

    Independent detached verification passed for the exact candidate SHA above.
    """
    |> String.trim()
  end

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
end
