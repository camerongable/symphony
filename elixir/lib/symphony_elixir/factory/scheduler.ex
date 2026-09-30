defmodule SymphonyElixir.Factory.Scheduler do
  @moduledoc """
  One bounded, restart-safe Jira-to-GitLab factory reconciliation tick.

  Long-running cognitive stages are launched asynchronously. Jira/GitLab
  connector operations remain serialized under the controller tick lease.
  Every state transition is durable before the tick returns.
  """

  require Logger

  alias SymphonyElixir.Config

  alias SymphonyElixir.Factory.{
    Capacity,
    Cleanup,
    Contract,
    ContractChat,
    ControllerTask,
    DesktopRequest,
    IntakeLedger,
    JiraMcpReader,
    JiraMcpWriter,
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

    with :ok <- DesktopRequest.reconcile_native_successes(context.store),
         :ok <- reconcile_stale_tasks(context),
         {:ok, jql} <- Queue.jql(context.factory.queue),
         {:ok, queued_snapshots} <- fetch_queue(context, workspace, jql),
         {:ok, _intake_snapshot} <-
           IntakeLedger.replace(context.store, context.factory.scope, queued_snapshots),
         {:ok, snapshots} <- fetch_active_snapshots(context, workspace, queued_snapshots),
         {:ok, intake} <- reconcile_intake(context, snapshots),
         {:ok, result} <- advance_runs(context, workspace, intake) do
      :ok = sweep_one_cleanup_candidate(context)
      {:ok, result}
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
    |> Map.put(:jira_reader, Keyword.get(opts, :jira_reader, JiraMcpReader))
    |> Map.put(:jira_connector, Keyword.get(opts, :jira_connector))
    |> Map.put(:jira_app_server, Keyword.get(opts, :jira_app_server, SymphonyElixir.Codex.AppServer))
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
      "SELECT DISTINCT issue_key FROM runs WHERE state NOT IN (#{placeholders}) ORDER BY issue_key",
      @terminal_states
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [issue_key] -> issue_key end)
  end

  defp recoverable_delivery_issue_keys(store) do
    store
    |> Store.query!("SELECT DISTINCT issue_key FROM runs WHERE kind = 'DELIVERY' AND state IN ('FAILED', 'CANCELLED') ORDER BY issue_key", [])
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
      update_active_snapshot(context.store, issue_key, snapshot)

      case active_run_for_issue(context.store, issue_key) do
        %{} = active ->
          reconcile_reopened_delivery_label(context, snapshot, active, acc)

        nil ->
          reconcile_inactive_snapshot(context, snapshot, acc)
      end
    else
      {:error, :jira_snapshot_missing_key}
    end
  end

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
         {:ok, manual_required} <- Contract.manual_validation_required(contract.markdown),
         {:ok, manual_environment} <- Contract.manual_validation_environment(contract.markdown),
         :ok <- validate_manual_policy(context.factory.manual_validation, manual_required, manual_environment),
         {:ok, _capacity} <- ensure_writer_capacity(context, route["repo_key"]),
         {:ok, %{run: run}} <-
           RunLedger.register(context.store, %{
             run_id: run_id,
             issue_key: issue_key,
             kind: "DELIVERY",
             state: "ADMITTING_WRITER",
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
             factory_owned: not native_transport?(context),
             runtime: if(native_transport?(context), do: "codex-desktop-broker", else: "codex-app-server")
           }) do
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

  defp advance_run(context, workspace, run, acc) do
    case validate_run_transport(context, run) do
      :ok ->
        case validate_run_snapshot(context, run) do
          :ok -> advance_valid_run(context, workspace, run, acc)
          {:cancel, reason} -> cancel_run(context, run, reason, acc)
          {:error, reason} -> block_run(context, workspace, run, reason, acc)
        end

      {:error, reason} ->
        block_run(context, workspace, run, reason, acc)
    end
  end

  defp validate_run_transport(context, run) do
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
    in_dev_delivery? = status == "IN DEV" and run["kind"] == "DELIVERY" and Enum.any?(["ai-running", "ai-ready"], &(&1 in labels))

    in_dev_contract_update? =
      status == "IN DEV" and run["kind"] == "SPECIFICATION" and
        present?(run["parent_run_id"]) and "ai-running" in labels

    if status in allowed or in_dev_delivery? or in_dev_contract_update? do
      :ok
    else
      {:cancel, {:jira_status_left_factory_scope, snapshot_value(snapshot, "status")}}
    end
  end

  defp validate_kind_labels(%{"kind" => "SPECIFICATION"} = run, labels) do
    contract_update? = present?(run["parent_run_id"]) and "ai-running" in labels

    if contract_update? or Enum.any?(["spec-needed", "needs-decision"], &(&1 in labels)) do
      :ok
    else
      {:cancel, :specification_labels_removed}
    end
  end

  defp validate_kind_labels(%{"kind" => "DELIVERY"}, labels) do
    if delivery_label?(labels), do: :ok, else: {:cancel, :delivery_labels_removed}
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
       when state in ["WRITING", "REPAIRING"] do
    case ensure_run_writer(context, run, acc) do
      {:ok, materialized_run, updated_acc} -> advance_writer(context, materialized_run, updated_acc)
      {:error, reason} -> block_run(context, controller_workspace(context), run, reason, acc)
    end
  end

  defp advance_delivery(context, _workspace, %{"state" => "VERIFYING"} = run, acc) do
    advance_verifier(context, run, acc)
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
            findings,
            controller_commits: native_transport?(context),
            run_id: run["run_id"],
            spec_revision: run["spec_revision"],
            base_ref: "origin/#{run["base_branch"]}",
            iteration_limit: context.factory.maximum_implementation_iterations
          ),
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
    preflight? = ci_preflight?(route_for_run(context, run))

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
          prompt:
            Prompt.change_verifier(
              snapshot,
              run["contract_markdown"],
              run["contract_sha256"],
              run["candidate_sha"],
              run["base_branch"],
              decode_json(run["ci_evidence_json"], nil)
            ),
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

  defp consume_change_verifier(context, run, route, verification_path, output, acc) do
    cleanup_result = remove_stage_workspace(context, run, route, verification_path)

    with :ok <- cleanup_result,
         true <- output["candidate_sha"] == run["candidate_sha"] or {:error, :verifier_sha_mismatch} do
      consume_change_verifier_output(context, run, output, acc)
    end
  end

  defp consume_change_verifier_output(context, run, %{"status" => "PASS"}, acc) do
    state = if preflight_verified?(context, run), do: "MR_CREATING", else: "PUSHING"
    RunLedger.update(context.store, run["run_id"], %{state: state})
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
        write_native_writer_slice(transaction, run, task_key, status, sha, ci_preflight?(route_for_run(context, run)))
      else
        {:error, :native_writer_slice_state_changed}
      end
    end)
  end

  defp write_native_writer_slice(transaction, run, task_key, status, sha, preflight?) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    next_state = if status == "COMPLETE", do: if(preflight?, do: "CI_PUSHING", else: "VERIFYING"), else: run["state"]
    verifier_round = run["verifier_round"] + if(status == "COMPLETE" and not preflight?, do: 1, else: 0)

    Store.query!(
      transaction,
      "UPDATE runs SET state = ?, candidate_sha = ?, implementation_iteration = ?, verifier_round = ?, repair_findings_json = '[]', updated_at = ? WHERE run_id = ?",
      [next_state, sha, run["implementation_iteration"] + 1, verifier_round, timestamp, run["run_id"]]
    )

    Store.query!(
      transaction,
      "UPDATE factory_tasks SET status = 'CONSUMED', updated_at = ? WHERE task_key = ?",
      [timestamp, task_key]
    )

    {:ok, sha}
  end

  defp native_writer_slice_current?(current_run, run, task, output_json) do
    expected_run = %{
      "state" => run["state"],
      "worktree" => run["worktree"],
      "branch" => run["branch"],
      "candidate_sha" => run["candidate_sha"],
      "implementation_iteration" => run["implementation_iteration"]
    }

    expected_task = %{"status" => "COMPLETE", "output_json" => output_json, "run_id" => run["run_id"]}

    run["state"] in ["WRITING", "REPAIRING"] and is_map(current_run) and is_map(task) and
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

  defp latest_issue_run(store, issue_key) do
    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
      [issue_key]
    )
  end

  defp latest_delivery_run(store, issue_key) do
    Store.one!(
      store,
      "SELECT * FROM runs WHERE issue_key = ? AND kind = 'DELIVERY' ORDER BY created_at DESC, rowid DESC LIMIT 1",
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
