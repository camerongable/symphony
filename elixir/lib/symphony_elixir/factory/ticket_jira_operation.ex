defmodule SymphonyElixir.Factory.TicketJiraOperation do
  @moduledoc "Controller-owned initial Jira effects with exact checkout ownership and receipt-only recovery."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{DesktopRequest, JiraMcpConnector, JiraMcpReader, RunLedger, Store, TicketChat}
  alias SymphonyElixir.Factory.{TicketJiraJournal, TicketMrOperation, TicketWorkerRunner, WorkspaceAccess}

  @doc "Moves an admitted ordinary ticket to In Dev and ai-running before writer admission, without a model turn."
  @spec start_implementation(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_implementation(store, run_id, opts) do
    opts = opts |> Keyword.put(:store, store) |> Keyword.put(:app_server, Keyword.get(opts, :jira_app_server, AppServer))

    with {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- source_paths(run),
         :ok <- workspace_argument(opts[:workspace]),
         {:ok, workspace} <- TicketMrOperation.controller_cwd(opts[:workspace], run["repo_path"], run["worktree"]),
         key = TicketJiraJournal.identity_key(run, "START_IMPLEMENTATION"),
         :ok <- original_operation_only(store, run_id, key),
         {:ok, owned_opts} <- reservation_options(store, key, opts),
         {:ok, _} <- TicketWorkerRunner.writer_admission_facts(store, run, owned_opts),
         :ok <- WorkspaceAccess.source_capacity(store, run, opts) do
      owned_opts = Keyword.put(owned_opts, :workspace, workspace)
      with_session(owned_opts, fn session_opts -> start_in_session(store, run, key, Keyword.merge(owned_opts, session_opts)) end)
    end
  end

  @doc "Reads back the original issued initial Jira effects and releases their exact ownership without admitting source work."
  @spec reconcile(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, run_id, opts) do
    opts = opts |> Keyword.put(:store, store) |> Keyword.put(:app_server, Keyword.get(opts, :jira_app_server, AppServer))

    with {:ok, run} <- RunLedger.get(store, run_id),
         key = TicketJiraJournal.identity_key(run, "START_IMPLEMENTATION"),
         {:ok, row} <- TicketJiraJournal.bound_operation(store, key),
         true <- row["phase"] in ~w(FIRST_UNCERTAIN SECOND_PENDING SECOND_UNCERTAIN COMPLETE) or {:error, :ticket_jira_recovery_unissued},
         :ok <- source_paths(run),
         :ok <- workspace_argument(opts[:workspace]),
         {:ok, workspace} <- TicketMrOperation.controller_cwd(opts[:workspace], run["repo_path"], run["worktree"]),
         {:ok, access, owned} <- recovery_ownership(store, run, row, opts) do
      owned = Keyword.put(owned, :workspace, workspace)

      with_session(owned, fn session_opts ->
        recover_in_session(store, run, row, access, Keyword.merge(owned, session_opts))
      end)
    end
  end

  defp recover_in_session(store, run, row, access, opts) do
    with {:ok, complete, authority} <- observe_recovery(store, run, row, opts, 2) do
      release_recovery(store, run, complete, authority, access, opts)
    end
  end

  defp recovery_ownership(store, run, row, opts) do
    key = row["operation_key"]

    with {:ok, access} <- WorkspaceAccess.get(store, key),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {run["run_id"], "MAINTENANCE", key, nil} or {:error, :ticket_jira_recovery_ownership_unproven},
         true <- is_nil(access["released_at"]) or row["phase"] == "COMPLETE" or {:error, :ticket_jira_recovery_ownership_unproven},
         {:ok, owned} <- reservation_options(store, key, opts),
         {:ok, facts} <- TicketWorkerRunner.writer_admission_facts(store, run, owned),
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         true <- binding["checkout"] == stringify(facts.checkout) or {:error, :ticket_jira_checkout_changed} do
      {:ok, access, owned}
    end
  end

  defp observe_recovery(store, run, %{"phase" => "COMPLETE"} = row, opts, _remaining) do
    with {:ok, observation, authority} <- read_issue(run, opts),
         :ok <- TicketJiraJournal.confirm_targets(store, row["operation_key"], observation) do
      {:ok, row, authority}
    end
  end

  defp observe_recovery(store, run, row, opts, remaining) when remaining > 0 do
    with {:ok, observation, _authority} <- read_issue(run, opts),
         {:ok, next} <- TicketJiraJournal.reconcile(store, row["operation_key"], observation) do
      observe_recovery(store, run, next, opts, remaining - 1)
    end
  end

  defp release_recovery(store, run, row, authority, access, opts) do
    transaction(store, fn tx ->
      with {:ok, current} <- RunLedger.get(tx, run["run_id"]),
           true <- current == run or {:error, :ticket_writer_admission_changed},
           :ok <- TicketWorkerRunner.validate_authorization(run, authority),
           {:ok, current_row} <- TicketJiraJournal.bound_operation(tx, row["operation_key"]),
           true <- current_row == row or {:error, :ticket_jira_operation_changed},
           {:ok, current_access, _owned} <- recovery_ownership(tx, run, row, opts),
           true <- current_access == access or {:error, :ticket_jira_recovery_ownership_unproven},
           {:ok, _} <- WorkspaceAccess.release_jira(tx, run["run_id"], row["operation_key"], access["generation"]) do
        {:ok, %{status: "JIRA_OPERATION_RECONCILED", run: run, model_invoked: false}}
      end
    end)
  end

  defp workspace_argument(workspace) when is_binary(workspace) and workspace != "", do: :ok
  defp workspace_argument(_workspace), do: {:error, :ticket_jira_controller_cwd_required}

  defp source_paths(run) do
    if Enum.all?(~w(repo_path worktree), &(is_binary(run[&1]) and run[&1] != "")),
      do: :ok,
      else: {:error, :ticket_source_checkout_not_admitted}
  end

  defp with_session(opts, operation) do
    workspace = Keyword.fetch!(opts, :workspace)
    scope = Keyword.get(opts, :jira_session, &AppServer.with_jira_controller_session/2)

    scope.(workspace, fn
      %{thread_id: thread} = session when is_binary(thread) and thread != "" -> operation.(mcp_session: session)
      _ -> {:error, :ticket_jira_session_unproven}
    end)
  end

  defp start_in_session(store, run, key, opts) do
    with {:ok, observation, authority} <- read_issue(run, opts),
         {:ok, first} <- first_effect(store, key, observation, opts),
         {:ok, journal, owned_opts} <- reserve(store, run, first, authority, opts),
         {:ok, complete, final_authority} <- advance(store, run, journal, owned_opts, 2) do
      finalize(store, run, complete, final_authority, owned_opts)
    end
  end

  defp original_operation_only(store, run_id, key) do
    other = Store.one!(store, "SELECT operation_key FROM ticket_jira_effects WHERE run_id = ? AND phase != 'COMPLETE' AND operation_key != ? LIMIT 1", [run_id, key])
    if is_nil(other), do: :ok, else: {:error, :ticket_jira_previous_operation_unresolved}
  end

  defp reservation_options(store, key, opts) do
    case WorkspaceAccess.get(store, key) do
      {:ok, %{"released_at" => nil} = access} -> {:ok, Keyword.put(opts, :reservation, %{key: key, generation: access["generation"]})}
      {:ok, _} -> {:ok, Keyword.delete(opts, :reservation)}
      {:error, :unknown_workspace_reservation} -> {:ok, Keyword.delete(opts, :reservation)}
    end
  end

  defp read_issue(run, opts) do
    reader = Keyword.get(opts, :jira_reader, JiraMcpReader)

    read_opts = Keyword.put(opts, :connector, Keyword.get(opts, :jira_connector, JiraMcpConnector))

    with {:ok, snapshot} <- reader.issue(run["issue_key"], read_opts),
         observed_at = DateTime.utc_now(),
         {:ok, authority} <- TicketWorkerRunner.authorization(run, snapshot, observed_at) do
      {:ok, %{"source" => "Jira/get_issue", "observed_at" => DateTime.to_iso8601(observed_at), "issue" => snapshot}, authority}
    end
  end

  defp first_effect(store, key, observation, opts) do
    case TicketJiraJournal.get(store, key) do
      {:ok, journal} ->
        with {:ok, [%{"kind" => "TRANSITION", "transition_id" => id}, %{"kind" => "LABELS"}]} <- Jason.decode(journal["effects_json"]),
             true <- is_nil(id) or is_binary(id) do
          {:ok, id || :already_in_dev}
        else
          _ -> {:error, :ticket_jira_receipt_corrupt}
        end

      {:error, :ticket_jira_operation_missing} ->
        if observation["issue"]["status"] == "In Dev", do: {:ok, :already_in_dev}, else: transition(observation["issue"]["key"], opts)
    end
  end

  defp transition(issue_key, opts) do
    connector = Keyword.get(opts, :jira_connector, JiraMcpConnector)

    with {:ok, values} <- connector.call_list("jira_get_transitions", %{"issue_key" => issue_key}, opts) do
      case Enum.filter(values, &(is_map(&1) and &1["to_status"] == "In Dev")) do
        [%{"id" => id}] when is_binary(id) -> {:ok, id}
        _ -> {:error, :ticket_jira_in_dev_transition_unproven}
      end
    end
  end

  defp reserve(store, run, first, authority, opts) do
    transaction(store, fn tx ->
      with :ok <- TicketWorkerRunner.validate_authorization(run, authority),
           {:ok, facts} <- TicketWorkerRunner.writer_admission_facts(tx, run, opts),
           :ok <- WorkspaceAccess.source_capacity(tx, run, opts),
           {:ok, journal} <- TicketJiraJournal.prepare(tx, run["run_id"], "START_IMPLEMENTATION", first, stringify(facts.checkout)),
           key = journal["operation_key"],
           {:ok, access} <- reserve_access(tx, run, facts, journal, opts) do
        {:ok, journal, Keyword.put(opts, :reservation, %{key: key, generation: access["generation"]})}
      end
    end)
  end

  defp controller_available(store, run, key) do
    with {:ok, chat} <- TicketChat.ready_for_run(store, run["run_id"]) do
      if DesktopRequest.controller_busy?(store, chat["scope_key"], key),
        do: {:error, :controller_jira_reconciliation_required},
        else: :ok
    end
  end

  defp reserve_access(store, run, facts, journal, opts) do
    key = journal["operation_key"]

    case {journal["phase"], WorkspaceAccess.get(store, key)} do
      {"COMPLETE", {:ok, %{"released_at" => at} = access}} when is_binary(at) ->
        {:ok, access}

      _ ->
        WorkspaceAccess.acquire(store, %{
          "reservation_key" => key,
          "run_id" => run["run_id"],
          "task_key" => nil,
          "request_key" => key,
          "mode" => "MAINTENANCE",
          "allowed_root" => opts[:workspace_root],
          "expected_sha" => facts.expected_sha
        })
    end
  end

  defp advance(_store, run, %{"phase" => "COMPLETE"} = row, opts, _remaining) do
    with {:ok, observation, authority} <- read_issue(run, opts),
         :ok <- target_effects_observed(row, observation["issue"]) do
      {:ok, row, authority}
    end
  end

  defp advance(store, run, row, opts, remaining) when remaining > 0 do
    with {:ok, observation, authority} <- read_issue(run, opts),
         {:ok, next} <- reconcile_or_apply(store, run, row, observation, authority, opts) do
      advance(store, run, next, opts, remaining - 1)
    end
  end

  defp advance(_store, _run, _row, _opts, _remaining), do: {:error, :ticket_jira_effect_limit}

  defp target_effects_observed(row, issue) do
    [first, labels] = Jason.decode!(row["effects_json"])
    current = issue["labels"]

    valid =
      issue["status"] == first["status"] and is_list(current) and
        Enum.all?(labels["add_labels"], &(&1 in current)) and not Enum.any?(labels["remove_labels"], &(&1 in current))

    if valid, do: :ok, else: {:error, :ticket_jira_target_state_changed}
  end

  defp reconcile_or_apply(store, run, %{"phase" => phase} = row, observation, authority, opts) do
    case TicketJiraJournal.reconcile(store, row["operation_key"], observation) do
      {:error, :ticket_jira_effect_not_observed} when phase in ~w(FIRST_PENDING SECOND_PENDING) -> apply_pending(store, run, row, authority, opts)
      result -> result
    end
  end

  defp apply_pending(store, run, row, _authority, opts) do
    effect = Jason.decode!(row["effects_json"]) |> Enum.at(if(row["phase"] == "FIRST_PENDING", do: 0, else: 1))
    connector = Keyword.get(opts, :jira_connector, JiraMcpConnector)
    {tool, args} = effect_call(effect)

    with :ok <- current_effect(effect, opts),
         :ok <- connector.validate_call(tool, args, opts),
         :ok <- AppServer.check_ticket_runtime(opts[:workspace]),
         {:ok, _observation, authority} <- read_issue(run, opts),
         :ok <- current_effect(effect, opts),
         {:ok, _claimed} <- claim(store, run, row, authority, opts) do
      connector.call(tool, args, opts)

      with {:ok, observation, _authority} <- read_issue(run, opts) do
        TicketJiraJournal.reconcile(store, row["operation_key"], observation)
      end
    end
  end

  defp current_effect(%{"kind" => "TRANSITION", "transition_id" => nil}, _opts), do: {:error, :ticket_jira_status_changed}

  defp current_effect(%{"kind" => "TRANSITION"} = effect, opts) do
    with {:ok, id} <- transition(effect["issue_key"], opts),
         true <- id == effect["transition_id"] or {:error, :ticket_jira_transition_changed} do
      :ok
    end
  end

  defp current_effect(%{"kind" => "LABELS"}, _opts), do: :ok

  defp claim(store, run, row, authority, opts) do
    transaction(store, fn tx ->
      with :ok <- TicketWorkerRunner.validate_authorization(run, authority),
           :ok <- controller_available(tx, run, row["operation_key"]),
           {:ok, facts} <- TicketWorkerRunner.writer_admission_facts(tx, run, opts),
           true <- stringify(facts.checkout) == Jason.decode!(row["binding_json"])["checkout"] or {:error, :ticket_jira_checkout_changed},
           {:ok, current} <- TicketJiraJournal.get(tx, row["operation_key"]),
           true <- current == row or {:error, :ticket_jira_operation_changed} do
        TicketJiraJournal.claim(tx, row["operation_key"])
      end
    end)
  end

  defp effect_call(%{"kind" => "TRANSITION"} = effect), do: {"jira_transition_issue", Map.take(effect, ~w(issue_key transition_id))}
  defp effect_call(%{"kind" => "LABELS"} = effect), do: {"jira_update_factory_labels", Map.take(effect, ~w(issue_key add_labels remove_labels))}

  defp finalize(store, run, row, authority, opts) do
    transaction(store, fn tx ->
      with :ok <- TicketWorkerRunner.validate_authorization(run, authority),
           %{key: key, generation: generation} <- opts[:reservation],
           true <- key == row["operation_key"] or {:error, :ticket_jira_operation_changed},
           {:ok, _} <- WorkspaceAccess.release_jira(tx, run["run_id"], key, generation) do
        TicketWorkerRunner.admit_writer(tx, run, authority, opts)
      end
    end)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp transaction(store, operation) do
    case Exqlite.transaction(store, &rollback_error(&1, operation.(&1))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result
end
