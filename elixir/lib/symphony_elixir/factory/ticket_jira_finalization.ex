defmodule SymphonyElixir.Factory.TicketJiraFinalization do
  @moduledoc "Exact ordinary-delivery Jira finalization; issued target labels are reconciliation evidence, not dispatch authority."
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{Control, DesktopRequest, JiraMcpConnector, JiraMcpReader, RunLedger, Store, TicketChat}
  alias SymphonyElixir.Factory.{TicketJiraJournal, TicketMrOperation, TicketWorkerRunner, WorkspaceAccess}

  @doc "Reconciles only an issued journal under its original retained ownership, without new effects."
  @spec reconcile(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, run_id, factory, opts) do
    with {:ok, %{"state" => "MR_CREATING"} = run} <- RunLedger.get(store, run_id),
         {:ok, selection} <- TicketJiraJournal.select_review_operation(store, run_id),
         key = selection.operation_key,
         :ok <- recovery_selection(selection),
         {:ok, _row, access} <- recovery_binding(store, run, key, opts) do
      recovery = opts |> Keyword.put(:reconciliation_only, true) |> Keyword.put(:recovery_generation, access["generation"]) |> Keyword.put(:review_selection, selection)
      finish(store, run_id, factory, recovery)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_recovery_not_admitted}
    end
  end

  defp recovery_selection(%{disposition: :reuse}), do: :ok
  defp recovery_selection(_selection), do: {:error, :ticket_jira_operation_missing}

  defp recovery_generation(access, opts) do
    expected = opts[:recovery_generation]
    if is_nil(expected) or access["generation"] == expected, do: :ok, else: {:error, :stale_workspace_reservation}
  end

  defp recovery_binding(store, run, key, opts) do
    with {:ok, %{"operation" => "REVIEW_READY", "phase" => phase} = row} <- TicketJiraJournal.bound_operation(store, key),
         true <- phase in ~w(FIRST_UNCERTAIN SECOND_PENDING SECOND_UNCERTAIN COMPLETE) or {:error, :ticket_jira_recovery_unissued},
         {:ok, access} <- WorkspaceAccess.get(store, key),
         {:ok, access} <- WorkspaceAccess.validate(store, key, access["generation"]),
         :ok <- recovery_generation(access, opts),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {run["run_id"], "MAINTENANCE", key, nil} or {:error, :ticket_jira_recovery_ownership_unproven},
         owned = Keyword.put(opts, :reservation, %{key: key, generation: access["generation"]}),
         {:ok, facts} <- TicketWorkerRunner.delivery_facts(store, run, owned),
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         true <- binding["checkout"] == stringify(facts.checkout) or {:error, :ticket_jira_recovery_checkout_changed} do
      {:ok, row, access}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_recovery_not_admitted}
    end
  end

  @doc "Records review handoff and ai-review once, then releases ownership and marks review-ready atomically."
  @spec finish(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(store, run_id, factory, opts) do
    opts = opts |> Keyword.put(:store, store) |> Keyword.put(:mr_session, opts[:mr_session] || opts[:mcp_session])

    with {:ok, %{"state" => "MR_CREATING"} = run} <- RunLedger.get(store, run_id),
         {:ok, selection} <- TicketJiraJournal.select_review_operation(store, run_id),
         key = selection.operation_key,
         :ok <- previous_operation(store, run_id, key),
         {:ok, owned} <- owned_options(store, key, Keyword.put(opts, :review_selection, selection)),
         {:ok, qualified} <- qualify_mr(store, run_id, factory, owned),
         {:ok, workspace} <- TicketMrOperation.controller_cwd(opts[:workspace], run["repo_path"], run["worktree"]) do
      scoped = owned |> Keyword.put(:workspace, workspace) |> Keyword.put(:app_server, Keyword.get(opts, :jira_app_server, AppServer))
      scope = Keyword.get(opts, :jira_session, &AppServer.with_jira_controller_session/2)

      scope.(workspace, fn
        %{thread_id: id} = session when is_binary(id) and id != "" -> in_session(store, run, key, factory, qualified, Keyword.put(scoped, :mcp_session, session))
        _ -> {:error, :ticket_jira_session_unproven}
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_finalization_not_admitted}
    end
  end

  defp previous_operation(store, run_id, key) do
    other = Store.one!(store, "SELECT operation_key FROM ticket_jira_effects WHERE run_id = ? AND phase != 'COMPLETE' AND operation_key != ? LIMIT 1", [run_id, key])
    if is_nil(other), do: :ok, else: {:error, :ticket_jira_previous_operation_unresolved}
  end

  defp owned_options(store, key, opts) do
    case WorkspaceAccess.get(store, key) do
      {:ok, %{"released_at" => nil} = access} -> {:ok, Keyword.put(opts, :reservation, %{key: key, generation: access["generation"]})}
      {:ok, _} -> {:ok, Keyword.delete(opts, :reservation)}
      {:error, :unknown_workspace_reservation} -> {:ok, Keyword.delete(opts, :reservation)}
    end
  end

  defp mr_options(opts) do
    opts
    |> Keyword.put(:mcp_session, opts[:mr_session])
    |> Keyword.put(:ticket_mr_ephemeral_read, is_nil(opts[:mr_session]))
    |> Keyword.put(:app_server, Keyword.get(opts, :gitlab_app_server, AppServer))
  end

  defp qualify_mr(store, run_id, factory, opts), do: TicketMrOperation.current_delivery_receipt(store, run_id, factory, mr_options(opts))

  defp in_session(store, run, key, factory, qualified, opts) do
    with {:ok, observation, authority} <- read_issue(store, run, key, opts),
         {:ok, row, owned} <- prepare(store, run, key, factory, qualified, observation, authority, opts),
         {:ok, complete, final_observation, final_authority} <- advance(store, run, row, factory, owned, 2) do
      finalize(store, run, complete, factory, final_observation, final_authority, owned)
    end
  end

  defp read_issue(store, run, key, opts) do
    reader = Keyword.get(opts, :jira_reader, JiraMcpReader)
    reader_opts = Keyword.put(opts, :connector, Keyword.get(opts, :jira_connector, JiraMcpConnector))

    with {:ok, snapshot} <- reader.issue(run["issue_key"], reader_opts),
         observed = DateTime.utc_now(),
         :ok <- contract_snapshot(run, snapshot),
         {:ok, authority} <- authority(store, run, key, snapshot, observed, opts) do
      {:ok, %{"source" => "Jira/get_issue", "observed_at" => DateTime.to_iso8601(observed), "issue" => snapshot}, authority}
    end
  end

  defp contract_snapshot(run, snapshot) do
    original = Jason.decode!(run["snapshot_json"])

    if {snapshot["key"], snapshot["id"]} == {run["issue_key"], original["id"]},
      do: TicketChat.ordinary_delivery_eligibility(Map.put(run, "snapshot_json", Jason.encode!(snapshot))),
      else: {:error, :ticket_authorization_identity_changed}
  end

  defp authority(store, run, key, snapshot, at, opts) do
    case TicketWorkerRunner.delivery_authorization(store, run, snapshot, at, opts) do
      {:ok, proof} -> {:ok, %{kind: :new_effect, proof: proof}}
      {:error, :ticket_jira_not_dispatchable} -> issued_authority(store, key, snapshot)
      error -> error
    end
  end

  defp issued_authority(store, key, snapshot) do
    allowed = ["In Dev", "In Progress", "In Review", "In Testing", "Testing", "Done"]

    with labels when is_list(labels) <- snapshot["labels"],
         true <- "ai-review" in labels and "ai-blocked" not in labels and "spec-needed" not in labels and snapshot["status"] in allowed,
         {:ok, %{"phase" => phase, "operation" => "REVIEW_READY"}} <- TicketJiraJournal.bound_operation(store, key),
         true <- phase in ~w(SECOND_UNCERTAIN COMPLETE) do
      {:ok, %{kind: :issued_readback}}
    else
      _ -> {:error, :ticket_jira_not_dispatchable}
    end
  end

  defp validate_authority(store, run, key, observation, authority, opts) do
    with {:ok, at, _} <- DateTime.from_iso8601(observation["observed_at"]),
         true <- DateTime.diff(DateTime.utc_now(), at, :millisecond) in 0..60_000 or {:error, :ticket_authorization_expired},
         :ok <- contract_snapshot(run, observation["issue"]),
         {:ok, current} <- authority(store, run, key, observation["issue"], at, opts),
         true <- current == authority or {:error, :ticket_jira_authority_changed} do
      :ok
    end
  end

  defp prepare(store, run, key, factory, qualified, observation, authority, opts) do
    transaction(store, fn tx ->
      with :ok <- validate_authority(tx, run, key, observation, authority, opts),
           :ok <- TicketMrOperation.validate_delivery_receipt(tx, qualified, factory, mr_options(opts)),
           {:ok, facts} <- TicketWorkerRunner.delivery_facts(tx, run, opts),
           {:ok, row, access} <- prepare_owned_operation(tx, run, key, facts, opts) do
        {:ok, row, Keyword.put(opts, :reservation, %{key: key, generation: access["generation"]})}
      end
    end)
  end

  defp prepare_owned_operation(store, run, key, facts, opts) do
    if opts[:reconciliation_only] == true do
      recovery_binding(store, run, key, opts)
    else
      with {:ok, row} <-
             TicketJiraJournal.prepare_review(
               store,
               run["run_id"],
               comment(run),
               stringify(facts.checkout),
               opts[:review_selection]
             ),
           {:ok, access} <- access(store, run, row, opts) do
        {:ok, row, access}
      end
    end
  end

  defp access(store, run, row, opts) do
    key = row["operation_key"]

    WorkspaceAccess.acquire(store, %{
      "reservation_key" => key,
      "run_id" => run["run_id"],
      "request_key" => key,
      "task_key" => nil,
      "mode" => "MAINTENANCE",
      "allowed_root" => opts[:workspace_root],
      "expected_sha" => run["candidate_sha"]
    })
  end

  defp advance(store, run, %{"phase" => "COMPLETE"} = row, _factory, opts, _remaining) do
    with {:ok, observation, authority} <- read_issue(store, run, row["operation_key"], opts),
         :ok <- TicketJiraJournal.confirm_targets(store, row["operation_key"], observation) do
      {:ok, row, observation, authority}
    end
  end

  defp advance(store, run, row, factory, opts, remaining) when remaining > 0 do
    with {:ok, observation, authority} <- read_issue(store, run, row["operation_key"], opts),
         {:ok, next} <- reconcile_or_apply(store, run, row, factory, observation, authority, opts) do
      advance(store, run, next, factory, opts, remaining - 1)
    end
  end

  defp advance(_store, _run, _row, _factory, _opts, _remaining), do: {:error, :ticket_jira_effect_limit}

  defp reconcile_or_apply(store, run, %{"phase" => phase} = row, factory, observation, authority, opts) do
    case TicketJiraJournal.reconcile(store, row["operation_key"], observation) do
      {:error, :ticket_jira_effect_not_observed} when phase in ~w(FIRST_PENDING SECOND_PENDING) ->
        if opts[:reconciliation_only] == true,
          do: {:error, :ticket_jira_effect_not_observed},
          else: apply_pending(store, run, row, factory, observation, authority, opts)

      result ->
        result
    end
  end

  defp apply_pending(store, run, row, factory, _observation, %{kind: :new_effect}, opts) do
    effect = row["effects_json"] |> Jason.decode!() |> Enum.at(if(row["phase"] == "FIRST_PENDING", do: 0, else: 1))
    {tool, args} = call_arguments(effect)
    connector = Keyword.get(opts, :jira_connector, JiraMcpConnector)

    with :ok <- new_effect_policy(store, run, factory, row["operation_key"]),
         :ok <- connector.validate_call(tool, args, opts),
         {:ok, qualified} <- qualify_mr(store, run["run_id"], factory, opts),
         {:ok, fresh, fresh_authority} <- read_issue(store, run, row["operation_key"], opts) do
      case TicketJiraJournal.reconcile(store, row["operation_key"], fresh) do
        {:error, :ticket_jira_effect_not_observed} ->
          apply_qualified(store, run, row, factory, qualified, fresh, fresh_authority, opts)

        result ->
          result
      end
    end
  end

  defp apply_pending(_store, _run, _row, _factory, _observation, _authority, _opts), do: {:error, :ticket_jira_reconciliation_not_write_authority}

  defp apply_qualified(store, run, row, factory, qualified, observation, %{kind: :new_effect} = authority, opts) do
    effect = row["effects_json"] |> Jason.decode!() |> Enum.at(if(row["phase"] == "FIRST_PENDING", do: 0, else: 1))
    {tool, args} = call_arguments(effect)
    connector = Keyword.get(opts, :jira_connector, JiraMcpConnector)

    with :ok <- claim_qualified(store, run, row, factory, qualified, observation, authority, opts) do
      connector.call(tool, args, opts)

      with {:ok, fresh, _} <- read_issue(store, run, row["operation_key"], opts),
           do: TicketJiraJournal.reconcile(store, row["operation_key"], fresh)
    end
  end

  defp apply_qualified(_store, _run, _row, _factory, _qualified, _observation, _authority, _opts), do: {:error, :ticket_jira_reconciliation_not_write_authority}

  defp claim_qualified(store, run, row, factory, qualified, observation, authority, opts) do
    transaction(store, fn tx ->
      with :ok <- new_effect_policy(tx, run, factory, row["operation_key"]),
           :ok <- validate_authority(tx, run, row["operation_key"], observation, authority, opts),
           {:ok, _facts} <- TicketWorkerRunner.delivery_admission(tx, run, authority.proof, opts),
           :ok <- TicketMrOperation.validate_delivery_receipt(tx, qualified, factory, mr_options(opts)),
           {:ok, current} <- TicketJiraJournal.bound_operation(tx, row["operation_key"]),
           true <- current == row or {:error, :ticket_jira_operation_changed},
           {:ok, _} <- TicketJiraJournal.claim(tx, row["operation_key"]) do
        :ok
      end
    end)
  end

  defp new_effect_policy(store, run, factory, key) do
    policy = Map.get(factory, :ticket_supervisor, %{})
    control = Control.status(store, factory.scope)

    valid =
      factory.task_transport == "desktop_broker" and policy["enabled"] == true and
        run["issue_key"] in (policy["pilot_issue_keys"] || []) and is_map(control) and control["status"] == "ACTIVE"

    cond do
      not valid -> {:error, :ticket_jira_new_effect_not_admitted}
      DesktopRequest.controller_busy?(store, factory.scope, key) -> {:error, :controller_jira_reconciliation_required}
      true -> :ok
    end
  end

  defp call_arguments(%{"kind" => "COMMENT"} = effect), do: {"jira_add_comment", Map.take(effect, ~w(issue_key body))}
  defp call_arguments(%{"kind" => "LABELS"} = effect), do: {"jira_update_factory_labels", Map.take(effect, ~w(issue_key add_labels remove_labels))}

  defp finalize(store, run, row, factory, _observation, _authority, opts) do
    with {:ok, qualified} <- qualify_mr(store, run["run_id"], factory, opts),
         {:ok, observation, authority} <- read_issue(store, run, row["operation_key"], opts) do
      transaction(store, &finalize_transaction(&1, run, row, factory, qualified, observation, authority, opts))
    end
  end

  defp finalize_transaction(store, run, row, factory, qualified, observation, authority, opts) do
    with :ok <- validate_authority(store, run, row["operation_key"], observation, authority, opts),
         :ok <- TicketMrOperation.validate_delivery_receipt(store, qualified, factory, mr_options(opts)),
         :ok <- TicketJiraJournal.confirm_targets(store, row["operation_key"], observation),
         %{key: key, generation: generation} <- opts[:reservation],
         {:ok, _} <- WorkspaceAccess.release_jira(store, run["run_id"], key, generation),
         {:ok, %{run: ready}} <-
           RunLedger.update(store, run["run_id"], %{
             state: "READY_FOR_REVIEW",
             jira_status: observation["issue"]["status"],
             snapshot_json: Jason.encode!(observation["issue"]),
             last_error: nil
           }),
         {:ok, _} <- TicketChat.ready_for_run(store, run["run_id"]) do
      {:ok, %{status: "REVIEW_READY", run: ready, model_invoked: false}}
    end
  end

  defp comment(run) do
    Enum.join(
      ["Symphony: draft MR ready for review.", "MR: " <> run["mr_url"], "Candidate: " <> run["candidate_sha"], "Next: review the draft MR; transition Jira to In Review when ready."],
      "\n\n"
    )
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp transaction(store, operation) do
    case Exqlite.transaction(store, &rollback(&1, operation.(&1))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback(_tx, result), do: result
end
