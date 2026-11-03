defmodule SymphonyElixir.Factory.TicketMrPublication do
  @moduledoc "Controller-owned MR publication; an issued operation is reconciled, never resent."
  alias SymphonyElixir.Factory.{Control, GitLabMrWriter, RunLedger, Store, TicketChat, TicketChatCommands, TicketPush, TicketWorkerRunner}

  @run_fields ~w(run_id issue_key repo_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)
  @control_fields ~w(scope status dispatcher_id generation)
  @parent_fields ~w(chat_key scope_key thread_id cwd create_request_key)

  @spec recorded?(Store.connection(), String.t()) :: boolean()
  def recorded?(store, run_id), do: not is_nil(Store.one!(store, "SELECT operation_key FROM ticket_mr_publications WHERE run_id=? LIMIT 1", [run_id]))

  @spec receipt_format(Store.connection(), map()) :: {:ok, :direct_publication | :legacy} | {:error, term()}
  def receipt_format(store, run) do
    Store.query!(store, "SELECT operation_key FROM ticket_mr_publications WHERE run_id=?", [run["run_id"]]).rows
    |> Enum.reduce_while({:ok, :legacy}, fn [key], {:ok, format} ->
      case get(store, key) do
        {:ok, row} ->
          intent = Jason.decode!(row["intent_json"])
          matched = recorded_run?(run, intent) and intent["completed_push_sha256"] == hash(run["candidate_handoff"] || "")
          {:cont, {:ok, if(matched, do: :direct_publication, else: format)}}

        error ->
          {:halt, error}
      end
    end)
  end

  @spec current_receipt(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def current_receipt(store, run_id, factory, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, row} <- record_for_run(store, run),
         intent = Jason.decode!(row["intent_json"]),
         true <- intent["scope"] == factory.scope or {:error, :ticket_mr_scope_changed} do
      GitLabMrWriter.with_session(intent["workspace"], opts, fn scoped ->
        with {:ok, delivery_opts} <- TicketWorkerRunner.delivery_review_options(store, run, scoped),
             {:ok, facts} <- TicketWorkerRunner.delivery_facts(store, run, delivery_opts),
             {:ok, push} <- TicketPush.completed_proof(store, run_id),
             {:ok, parent} <- TicketChat.bound_for_run(store, run_id),
             control = Map.take(Control.status(store, factory.scope) || %{}, @control_fields),
             {:ok, mr} <- GitLabMrWriter.fetch(intent, run["mr_iid"], scoped),
             :ok <- remote_identity(intent, mr),
             true <- compatible_draft?(mr) or {:error, :gitlab_mr_human_state_preserved},
             true <- mr["web_url"] == run["mr_url"] or {:error, :gitlab_mr_remote_identity_mismatch} do
          receipt = %{
            format: :direct_publication,
            run: run,
            publication: row,
            mr: mr,
            delivery_facts: facts,
            push_proof: push,
            parent: Map.take(parent, @parent_fields),
            control: control,
            observed_at: now()
          }

          with :ok <- validate_receipt(store, receipt, factory, delivery_opts), do: {:ok, receipt}
        else
          {:error, _} = error -> error
          _ -> {:error, :ticket_mr_readback_unproven}
        end
      end)
    end
  end

  @spec validate_receipt(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def validate_receipt(
        store,
        %{format: :direct_publication, run: run, publication: row, mr: mr, delivery_facts: facts, push_proof: push, parent: parent, control: control, observed_at: at},
        factory,
        opts
      ) do
    with {:ok, observed, _} <- DateTime.from_iso8601(at),
         true <- DateTime.diff(DateTime.utc_now(), observed, :millisecond) in 0..60_000 or {:error, :ticket_mr_readback_expired},
         {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run or {:error, :ticket_mr_candidate_changed},
         {:ok, ^row} <- record_for_run(store, run),
         intent = Jason.decode!(row["intent_json"]),
         true <- intent["scope"] == factory.scope and parent["scope_key"] == factory.scope,
         {:ok, chat} <- TicketChat.bound_for_run(store, run["run_id"]),
         true <- Map.take(chat, @parent_fields) == parent,
         true <- Map.take(Control.status(store, factory.scope) || %{}, @control_fields) == control,
         :ok <- TicketChatCommands.progress_allowed(store, run["run_id"]),
         :ok <- TicketWorkerRunner.recheck_delivery_facts(store, run, opts, facts),
         :ok <- TicketPush.validate_completed_proof(store, run["run_id"], push),
         :ok <- remote_identity(intent, mr),
         true <- compatible_draft?(mr) and mr["iid"] == run["mr_iid"] and mr["web_url"] == run["mr_url"] do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_readback_unproven}
    end
  end

  def validate_receipt(_, _, _, _), do: {:error, :ticket_mr_readback_unproven}

  @spec step(Store.connection(), String.t(), map(), map(), Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def step(%DBConnection{}, _, _, _, _, _, _), do: {:error, :ticket_mr_observation_inside_transaction}

  def step(store, run_id, authorization, factory, workspace, description, opts) do
    :global.trans({{__MODULE__, run_id}, self()}, fn ->
      case issued(store, run_id) do
        {:ok, row} ->
          GitLabMrWriter.with_session(workspace, opts, &reconcile(store, row, authorization, factory, &1))

        :none ->
          if(opts[:reconciliation_only] == true,
            do: {:ok, %{status: "MR_PUBLICATION_NOT_ISSUED", model_invoked: false}},
            else: settled_or_fresh(store, run_id, authorization, factory, workspace, description, opts)
          )

        error ->
          error
      end
    end)
  end

  defp settled_or_fresh(store, run_id, authorization, factory, workspace, description, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id) do
      case record_for_run(store, run) do
        {:ok, row} ->
          mr = row["receipt_json"] |> Jason.decode!() |> Map.fetch!("mr")

          if {run["mr_iid"], run["mr_url"]} == {mr["iid"], mr["web_url"]} do
            {:ok, %{status: "MR_ALREADY_PUBLISHED", run: run, operation_key: row["operation_key"], model_invoked: false}}
          else
            GitLabMrWriter.with_session(workspace, opts, &refresh_settled(store, row, authorization, factory, &1))
          end

        {:error, :unknown_mr_publication} ->
          GitLabMrWriter.with_session(workspace, opts, &fresh_step(store, run_id, authorization, factory, workspace, description, &1))

        error ->
          error
      end
    end
  end

  @spec record_for_run(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def record_for_run(store, run) do
    matches =
      Store.query!(store, "SELECT operation_key,intent_json FROM ticket_mr_publications WHERE run_id=? AND phase='SUCCEEDED'", [run["run_id"]]).rows
      |> Enum.filter(fn [_key, raw] ->
        case Jason.decode(raw) do
          {:ok, intent} -> recorded_run?(run, intent) and intent["completed_push_sha256"] == hash(run["candidate_handoff"] || "")
          _ -> false
        end
      end)

    case matches do
      [[key, _]] -> get(store, key)
      [] -> {:error, :unknown_mr_publication}
      _ -> {:error, :ticket_mr_publication_ambiguous}
    end
  end

  defp refresh_settled(store, row, authorization, factory, opts) do
    intent = Jason.decode!(row["intent_json"])
    saved = Jason.decode!(row["receipt_json"])["mr"]

    with {:ok, mr} <- GitLabMrWriter.fetch(intent, saved["iid"], opts),
         :ok <- remote_identity(intent, mr) do
      advance(store, row, mr, authorization, factory, opts)
    end
  end

  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(store, key) do
    case Store.one!(store, "SELECT * FROM ticket_mr_publications WHERE operation_key=?", [key]) do
      nil -> {:error, :unknown_mr_publication}
      row -> with :ok <- validate_record(row), do: {:ok, row}
    end
  end

  defp issued(store, run_id) do
    case Store.query!(store, "SELECT operation_key FROM ticket_mr_publications WHERE run_id=? AND phase='ISSUED_UNKNOWN'", [run_id]).rows do
      [] -> :none
      [[key]] -> get(store, key)
      _ -> {:error, :ticket_mr_publication_ambiguous}
    end
  end

  defp fresh_step(store, run_id, authorization, factory, workspace, description, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- run["state"] in ~w(MR_CREATING CI_MR_CREATING) or {:error, :ticket_mr_stage_invalid},
         :ok <- legacy_settled(store, run_id),
         {:ok, authorization} <- refresh(run, authorization, opts),
         {:ok, observed} <- admission(store, run, authorization, factory, opts),
         {:ok, intent} <- intent(run, observed.push, factory, workspace, description),
         {:ok, row} <- prepare(store, run, intent, observed, authorization, factory, opts) do
      case row["phase"] do
        "SUCCEEDED" -> refresh_settled(store, row, authorization, factory, opts)
        "ISSUED_UNKNOWN" -> reconcile(store, row, authorization, factory, opts)
        _ -> discover(store, row, authorization, factory, opts)
      end
    end
  end

  defp legacy_settled(store, run_id) do
    row =
      Store.one!(
        store,
        """
        SELECT request_key FROM desktop_requests
        WHERE target_kind='CONTROLLER' AND action='FOLLOWUP' AND status!='SUCCEEDED'
          AND json_extract(CASE WHEN json_valid(metadata_json) THEN metadata_json ELSE '{}' END,'$.delivery_operation.operation')='CREATE_OR_REUSE_DRAFT_MR'
          AND json_extract(CASE WHEN json_valid(metadata_json) THEN metadata_json ELSE '{}' END,'$.delivery_operation.run_id')=? LIMIT 1
        """,
        [run_id]
      )

    if row, do: {:error, :ticket_mr_legacy_request_pending}, else: :ok
  end

  defp admission(store, run, authorization, factory, opts) do
    with {:ok, parent} <- TicketChat.bound_for_run(store, run["run_id"]),
         true <- parent["scope_key"] == factory.scope or {:error, :ticket_mr_scope_changed},
         :ok <- TicketChatCommands.progress_allowed(store, run["run_id"]),
         %{"status" => "ACTIVE", "dispatcher_id" => dispatcher} = control <- Control.status(store, factory.scope),
         true <- dispatcher == factory.dispatcher_id,
         {:ok, admitted} <- TicketWorkerRunner.delivery_admission(store, run, authorization, opts),
         {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]) do
      {:ok, %{run: run, admission: admitted, push: push, control: Map.take(control, @control_fields)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_control_unavailable}
    end
  end

  defp recheck(store, observed, authorization, factory, opts) do
    with {:ok, current} <- RunLedger.get(store, observed.run["run_id"]),
         true <- current == observed.run or {:error, :ticket_mr_candidate_changed},
         true <- Map.take(Control.status(store, factory.scope) || %{}, @control_fields) == observed.control or {:error, :ticket_mr_control_changed},
         :ok <- TicketChatCommands.progress_allowed(store, current["run_id"]),
         :ok <- TicketWorkerRunner.recheck_delivery_admission(store, current, authorization, opts, observed.admission),
         :ok <- TicketPush.validate_completed_proof(store, current["run_id"], observed.push) do
      :ok
    end
  end

  defp intent(run, push, factory, workspace, description) do
    route = factory.repositories[run["repo_key"]]
    id = if is_map(route), do: Integer.parse(to_string(route["gitlab_project_id"])), else: :error
    snapshot = Jason.decode!(run["snapshot_json"])
    summary = Enum.find([snapshot["summary"], snapshot["title"]], &(is_binary(&1) and String.trim(&1) != "")) || "deliver the confirmed change"
    title = summary |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 80)

    with {project_id, ""} when project_id > 0 <- id,
         true <- is_binary(description) and byte_size(description) <= 262_144 do
      {:ok,
       %{
         "version" => 1,
         "kind" => "TICKET_MR_PUBLICATION",
         "run" => Map.take(run, @run_fields),
         "stage" => run["state"],
         "project_id" => project_id,
         "project" => route["gitlab_project"],
         "source_branch" => run["branch"],
         "target_branch" => run["base_branch"],
         "candidate_sha" => run["candidate_sha"],
         "completed_push_sha256" => push.envelope_sha256,
         "scope" => factory.scope,
         "workspace" => workspace,
         "ci_preflight" => run["state"] == "CI_MR_CREATING",
         "title" => "Draft: feat(#{run["issue_key"]}): #{title}",
         "description" => description
       }}
    else
      _ -> {:error, :ticket_mr_repository_unconfigured}
    end
  end

  defp prepare(store, run, intent, observed, authorization, factory, opts) do
    raw = Jason.encode!(intent)
    key = "ticket-mr-publication:" <> hash(raw)

    Store.transaction!(store, fn tx ->
      with :ok <- legacy_settled(tx, run["run_id"]),
           :ok <- recheck(tx, observed, authorization, factory, opts) do
        now = now()

        Store.query!(
          tx,
          "INSERT OR IGNORE INTO ticket_mr_publications(operation_key,run_id,project_id,source_branch,target_branch,intent_json,intent_sha256,phase,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'PREPARED',?,?)",
          [key, run["run_id"], intent["project_id"], intent["source_branch"], intent["target_branch"], raw, hash(raw), now, now]
        )

        with {:ok, row} <- get(tx, key), true <- row["intent_json"] == raw or {:error, :ticket_mr_intent_changed}, do: {:ok, row}
      end
    end)
  end

  defp discover(store, row, authorization, factory, opts) do
    intent = Jason.decode!(row["intent_json"])

    with {:ok, matches} <- GitLabMrWriter.discover(intent, opts) do
      case matches do
        [] -> create(store, row, authorization, factory, opts)
        [%{"iid" => iid}] -> read_and_settle(store, row, iid, "REUSED_EXISTING", authorization, factory, opts)
        _ -> fail_before_issuance(store, row, :gitlab_mr_discovery_ambiguous)
      end
    else
      {:error, reason} -> fail_before_issuance(store, row, reason)
    end
  end

  defp create(store, row, authorization, factory, opts) do
    intent = Jason.decode!(row["intent_json"])

    with :ok <- GitLabMrWriter.creation_capability(intent, opts),
         {:ok, run} <- RunLedger.get(store, row["run_id"]),
         true <- same_run?(run, intent) or {:error, :ticket_mr_candidate_changed},
         {:ok, authorization} <- refresh(run, authorization, opts),
         {:ok, observed} <- admission(store, run, authorization, factory, opts),
         {:ok, issued} <- mark_issued(store, row, observed, authorization, factory, opts) do
      case GitLabMrWriter.create(intent, opts) do
        {:ok, %{"iid" => iid}} -> read_and_settle(store, issued, iid, "CREATED_DRAFT", authorization, factory, opts)
        {:error, {:gitlab_mr_not_issued, reason}} -> not_issued(store, issued, reason)
        {:error, reason} -> unknown(store, issued, reason)
        _ -> unknown(store, issued, :gitlab_mr_result_invalid)
      end
    else
      {:error, reason} -> fail_before_issuance(store, row, reason)
    end
  end

  defp mark_issued(store, row, observed, authorization, factory, opts) do
    Store.transaction!(store, fn tx ->
      with :ok <- legacy_settled(tx, row["run_id"]),
           :ok <- recheck(tx, observed, authorization, factory, opts),
           {:ok, ^row} <- get(tx, row["operation_key"]),
           true <- row["phase"] in ~w(PREPARED FAILED_BEFORE_ISSUANCE) or {:error, :ticket_mr_already_issued} do
        Store.query!(tx, "UPDATE ticket_mr_publications SET phase='ISSUED_UNKNOWN',error_json=NULL,updated_at=? WHERE operation_key=?", [now(), row["operation_key"]])
        get(tx, row["operation_key"])
      else
        {:error, _} = error -> error
        _ -> {:error, :ticket_mr_already_issued}
      end
    end)
  end

  defp reconcile(store, row, authorization, factory, opts) do
    intent = Jason.decode!(row["intent_json"])

    with {:ok, matches} <- GitLabMrWriter.discover(intent, opts) do
      case matches do
        [%{"iid" => iid}] -> read_and_settle(store, row, iid, "RECONCILED_EXISTING", authorization, factory, opts)
        [] -> {:ok, %{status: "MR_ISSUED_UNKNOWN", model_invoked: false}}
        _ -> {:error, :gitlab_mr_discovery_ambiguous}
      end
    end
  end

  defp read_and_settle(store, row, iid, origin, authorization, factory, opts) do
    intent = Jason.decode!(row["intent_json"])

    with {:ok, mr} <- GitLabMrWriter.fetch(intent, iid, opts),
         :ok <- remote_identity(intent, mr) do
      outcome = if compatible_draft?(mr), do: origin, else: "PRESERVED_HUMAN_STATE"
      content = if origin == "CREATED_DRAFT" and Map.take(mr, ~w(title description)) == Map.take(intent, ~w(title description)), do: "GENERATED_AND_READ_BACK", else: "OBSERVED_EXISTING"

      receipt = %{
        "version" => 1,
        "kind" => "TICKET_MR_PUBLICATION_RECEIPT",
        "operation_key" => row["operation_key"],
        "intent_sha256" => row["intent_sha256"],
        "outcome" => outcome,
        "content_origin" => content,
        "mr" => mr,
        "observed_at" => now()
      }

      raw = Jason.encode!(receipt)

      with {:ok, saved} <-
             Store.transaction!(store, fn tx ->
               with {:ok, ^row} <- get(tx, row["operation_key"]) do
                 Store.query!(tx, "UPDATE ticket_mr_publications SET phase='SUCCEEDED',receipt_json=?,receipt_sha256=?,error_json=NULL,updated_at=? WHERE operation_key=?", [
                   raw,
                   hash(raw),
                   now(),
                   row["operation_key"]
                 ])

                 get(tx, row["operation_key"])
               else
                 {:error, _} = error -> error
                 _ -> {:error, :ticket_mr_publication_changed}
               end
             end) do
        advance(store, saved, mr, authorization, factory, opts)
      end
    end
  end

  defp advance(store, row, mr, authorization, factory, opts) do
    intent = Jason.decode!(row["intent_json"])

    cond do
      opts[:reconciliation_only] == true -> {:ok, %{status: "MR_PUBLICATION_SETTLED_HELD", model_invoked: false}}
      not compatible_draft?(mr) -> {:ok, %{status: "MR_HUMAN_STATE_PRESERVED", model_invoked: false}}
      true -> advance_compatible(store, row, intent, mr, authorization, factory, opts)
    end
  end

  defp advance_compatible(store, row, intent, mr, authorization, factory, opts) do
    with {:ok, run} <- RunLedger.get(store, row["run_id"]),
         true <- same_run?(run, intent),
         true <- run["state"] == intent["stage"],
         {:ok, authorization} <- refresh(run, authorization, opts),
         {:ok, observed} <- admission(store, run, authorization, factory, opts) do
      Store.transaction!(store, fn tx ->
        with {:ok, ^row} <- get(tx, row["operation_key"]),
             :ok <- recheck(tx, observed, authorization, factory, opts),
             fields = %{"mr_iid" => mr["iid"], "mr_url" => mr["web_url"], "mr_state" => mr["state"]},
             fields = if(intent["ci_preflight"], do: Map.put(fields, "state", "CI_WAITING"), else: fields),
             {:ok, %{run: saved}} <- RunLedger.update(tx, run["run_id"], fields) do
          {:ok, %{status: "MR_PUBLISHED", run: saved, operation_key: row["operation_key"], model_invoked: false}}
        end
      end)
    else
      _ -> {:ok, %{status: "MR_PUBLICATION_SETTLED_HELD", model_invoked: false}}
    end
  end

  defp fail_before_issuance(store, row, reason) do
    Store.transaction!(store, fn tx ->
      with {:ok, current} <- get(tx, row["operation_key"]), true <- current["phase"] in ~w(PREPARED FAILED_BEFORE_ISSUANCE) do
        Store.query!(tx, "UPDATE ticket_mr_publications SET phase='FAILED_BEFORE_ISSUANCE',error_json=?,updated_at=? WHERE operation_key=?", [
          Jason.encode!(%{"reason" => inspect(reason)}),
          now(),
          row["operation_key"]
        ])
      end
    end)

    {:error, reason}
  end

  defp unknown(store, row, reason) do
    Store.query!(store, "UPDATE ticket_mr_publications SET error_json=?,updated_at=? WHERE operation_key=? AND phase='ISSUED_UNKNOWN'", [
      Jason.encode!(%{"reason" => inspect(reason)}),
      now(),
      row["operation_key"]
    ])

    {:ok, %{status: "MR_ISSUED_UNKNOWN", model_invoked: false}}
  end

  defp not_issued(store, row, reason) do
    Store.transaction!(store, fn tx ->
      with {:ok, current} <- get(tx, row["operation_key"]),
           true <- current == row and current["phase"] == "ISSUED_UNKNOWN" do
        Store.query!(tx, "UPDATE ticket_mr_publications SET phase='FAILED_BEFORE_ISSUANCE',error_json=?,updated_at=? WHERE operation_key=?", [
          Jason.encode!(%{"reason" => inspect(reason, limit: 20, printable_limit: 1000)}),
          now(),
          row["operation_key"]
        ])

        {:error, reason}
      else
        _ -> {:error, :ticket_mr_publication_changed}
      end
    end)
  end

  defp same_run?(run, intent), do: Map.take(run, @run_fields) == intent["run"]

  # READY rework's recorded prior projection predates publication and omits only the repository alias.
  defp recorded_run?(run, intent) do
    if Map.has_key?(run, "repo_key"),
      do: same_run?(run, intent),
      else: Map.take(run, @run_fields -- ["repo_key"]) == Map.take(intent["run"], @run_fields -- ["repo_key"])
  end

  defp remote_identity(intent, mr) do
    expected = Map.take(intent, ~w(project_id source_branch target_branch)) |> Map.put("sha", intent["candidate_sha"])

    if Map.take(mr, Map.keys(expected)) == expected and is_integer(mr["iid"]) and mr["iid"] > 0 and mr["web_url"] == "https://gitlab.com/#{intent["project"]}/-/merge_requests/#{mr["iid"]}" and
         get_in(mr, ["diff_refs", "head_sha"]) in [nil, intent["candidate_sha"]], do: :ok, else: {:error, :gitlab_mr_remote_identity_mismatch}
  end

  # A future merge's branch-deletion preference does not authorize or prevent publication.
  defp compatible_draft?(mr), do: mr["state"] == "opened" and mr["draft"] == true and mr["reviewers"] == [] and is_list(mr["assignees"])

  defp validate_record(row) do
    with {:ok, intent} <- Jason.decode(row["intent_json"]),
         true <- intent["version"] == 1 and intent["kind"] == "TICKET_MR_PUBLICATION",
         true <- hash(row["intent_json"]) == row["intent_sha256"] and row["operation_key"] == "ticket-mr-publication:" <> row["intent_sha256"],
         true <- {row["run_id"], row["project_id"], row["source_branch"], row["target_branch"]} == {intent["run"]["run_id"], intent["project_id"], intent["source_branch"], intent["target_branch"]},
         :ok <- validate_saved_receipt(row, intent) do
      :ok
    else
      _ -> {:error, :ticket_mr_publication_record_invalid}
    end
  end

  defp validate_saved_receipt(%{"phase" => "SUCCEEDED"} = row, intent) do
    with true <- hash(row["receipt_json"]) == row["receipt_sha256"],
         {:ok, receipt} <- Jason.decode(row["receipt_json"]),
         true <-
           Map.take(receipt, ~w(version kind operation_key intent_sha256)) == %{
             "version" => 1,
             "kind" => "TICKET_MR_PUBLICATION_RECEIPT",
             "operation_key" => row["operation_key"],
             "intent_sha256" => row["intent_sha256"]
           },
         true <- receipt["outcome"] in ~w(CREATED_DRAFT REUSED_EXISTING RECONCILED_EXISTING PRESERVED_HUMAN_STATE),
         true <- receipt["content_origin"] in ~w(GENERATED_AND_READ_BACK OBSERVED_EXISTING),
         :ok <- remote_identity(intent, receipt["mr"]) do
      :ok
    else
      _ -> {:error, :ticket_mr_publication_record_invalid}
    end
  end

  defp validate_saved_receipt(%{"receipt_json" => nil, "receipt_sha256" => nil}, _), do: :ok
  defp validate_saved_receipt(_, _), do: {:error, :ticket_mr_publication_record_invalid}

  defp refresh(run, authorization, opts) do
    case opts[:mr_authorization_reader] do
      callback when is_function(callback, 2) -> callback.(run, authorization)
      _ -> {:ok, authorization}
    end
  end

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
