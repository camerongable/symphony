defmodule SymphonyElixir.Factory.TicketPushRecovery do
  @moduledoc "Explicit same-candidate remote CAS recovery; the original push outcome remains unknown."
  alias SymphonyElixir.Factory.{ControllerGitRead, RunLedger, Store, TicketPush, TicketPushRecoveryIO, WorkspaceAccess, Worktree}
  @old_helper Path.expand("../../../priv/ticket_push_executor_v2.py", __DIR__)
  @old_sha "c0e98bd870546c62ec3797592183f2e242d2070d23dd6297dc0ca179bc47ab37"
  @kind "TICKET_PUSH_CAS_RECOVERY"

  @spec prepare(Store.connection(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%DBConnection{}, _, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, run_id, expected_nonce, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- execution_context(store, run),
         {:ok, prior} <- Jason.decode(run["candidate_handoff"] || "null"),
         true <- (is_map(prior) and prior["owner_nonce"] == expected_nonce) or {:error, :push_recovery_nonce_changed},
         {:ok, original, history, attempt} <- predecessor(run["candidate_handoff"], prior),
         :ok <- audited_original(original),
         {:ok, observed} <- TicketPush.recovery_observation(store, run_id, original, authorization, opts),
         proposed = Map.merge(observed.intent, %{"kind" => @kind, "original_envelope" => original}),
         {:ok, _budgeted} <- TicketPushRecoveryIO.prepare(store, proposed, authorization, opts),
         {:ok, remote} <- read_recovery_ref(run),
         true <- remote in [nil, "", run["candidate_sha"]] or {:error, :push_recovery_remote_conflict} do
      WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
        with :ok <- TicketPush.recheck_recovery_observation(tx, observed, access, authorization, opts),
             :ok <- control_boundary(tx, run_id, opts),
             true <-
               Store.one!(tx, "SELECT COUNT(*) AS count FROM events WHERE run_id = ? AND event_type = 'TICKET_PUSH_CAS_ATTEMPT'", [run_id])["count"] == attempt - 1 or
                 {:error, :push_recovery_budget_changed},
             intent =
               Map.merge(observed.intent, %{
                 "kind" => @kind,
                 "phase" => "PREPARED",
                 "old_outcome" => "UNKNOWN",
                 "original_envelope" => original,
                 "original_envelope_sha256" => digest(original),
                 "unknown_predecessors" => history,
                 "recovery_attempt" => attempt,
                 "owner_nonce" => nonce(),
                 "helper_pid" => nil,
                 "execution_json" => nil,
                 "prepared_at" => now(),
                 "failure" => nil
               }),
             :ok <- persist(tx, run, intent),
             :ok <- retain_hazard(tx, run, original) do
          {:ok, intent}
        end
      end)
    else
      {:error, _} = error -> error
    end
  end

  @spec execute(Store.connection(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(store, run_id, expected_nonce, authorization, opts) do
    with {:ok, intent} <-
           mutate(store, run_id, expected_nonce, authorization, opts, fn current ->
             if current["phase"] == "PREPARED", do: {:ok, Map.merge(current, %{"phase" => "PUSH_UNCERTAIN", "issued_at" => now()})}, else: {:error, :push_recovery_already_issued}
           end),
         {:ok, execution} <- TicketPushRecoveryIO.prepare(store, intent, authorization, opts) do
      result =
        TicketPushRecoveryIO.execute(execution, fn pid, encoded ->
          mutate(store, run_id, expected_nonce, authorization, opts, fn current ->
            if encoded == Jason.encode!(execution) and is_nil(current["helper_pid"]) and is_nil(current["execution_json"]),
              do: {:ok, Map.merge(current, %{"helper_pid" => pid, "execution_json" => encoded})},
              else: {:error, :push_recovery_execution_already_bound}
          end)
        end)

      case result do
        {:ok, _} ->
          case reconcile(store, run_id, expected_nonce, authorization, opts) do
            {:error, reason} = error ->
              retain_error(store, run_id, expected_nonce, reason)
              error

            success ->
              success
          end

        {:error, reason} ->
          retain_error(store, run_id, expected_nonce, reason)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        retain_error(store, run_id, expected_nonce, reason)
        error
    end
  end

  @spec reconcile(Store.connection(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, run_id, expected_nonce, authorization, opts) do
    with {:ok, observed, intent} <- observation(store, run_id, expected_nonce, authorization, opts),
         true <- intent["phase"] == "PUSH_UNCERTAIN" or {:error, :push_recovery_not_issued},
         {:ok, raw} <- TicketPushRecoveryIO.readback(intent),
         true <- TicketPushRecoveryIO.receipt_valid?(raw, intent) or {:error, :push_recovery_receipt_unproven},
         {:ok, remote} <- Worktree.read_remote_branch(%{"path" => observed.run["repo_path"]}, observed.run["branch"]),
         true <- remote == observed.run["candidate_sha"] or {:error, :push_recovery_remote_conflict} do
      WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
        with :ok <- TicketPush.recheck_recovery_observation(tx, observed, access, authorization, opts),
             :ok <- control_boundary(tx, run_id, opts),
             complete = Map.merge(intent, %{"phase" => "COMPLETED", "receipt_json" => raw, "receipt_sha256" => digest(raw), "remote_sha" => remote, "completed_at" => now(), "failure" => nil}),
             :ok <- persist(tx, observed.run, complete),
             released =
               Store.query!(
                 tx,
                 "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND generation = ? AND released_at IS NULL RETURNING reservation_key",
                 [now(), Jason.encode!(complete), access["reservation_key"], access["generation"]]
               ).rows,
             true <- released == [[access["reservation_key"]]] or {:error, :push_recovery_lease_changed},
             {:ok, %{run: updated}} <- RunLedger.update(tx, run_id, transition(observed.run, remote)) do
          {:ok, %{status: "PUSH_RECOVERY_CONVERGED", run: updated, old_outcome: "UNKNOWN", new_exit_code: Jason.decode!(raw)["termination"]["code"]}}
        end
      end)
    else
      {:error, _} = error -> error
    end
  end

  defp mutate(store, run_id, nonce, authorization, opts, change) do
    with {:ok, observed, intent} <- observation(store, run_id, nonce, authorization, opts) do
      WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
        with :ok <- TicketPush.recheck_recovery_observation(tx, observed, access, authorization, opts),
             :ok <- control_boundary(tx, run_id, opts),
             {:ok, updated} <- change.(intent),
             :ok <- persist(tx, observed.run, updated),
             do: {:ok, updated}
      end)
    end
  end

  @spec completed_proof(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def completed_proof(store, run_id) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         raw when is_binary(raw) <- run["candidate_handoff"],
         {:ok, %{"kind" => @kind, "phase" => "COMPLETED", "old_outcome" => "UNKNOWN"} = intent} <- Jason.decode(raw),
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <-
           Map.take(binding, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)) ==
             Map.take(run, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)),
         :ok <- audited_original(intent["original_envelope"]),
         true <- digest(intent["original_envelope"]) == intent["original_envelope_sha256"],
         {:ok, access} <- WorkspaceAccess.get(store, intent["reservation_key"]),
         true <- access["released_at"] != nil and access["release_receipt_json"] == raw and access["generation"] == intent["reservation_generation"],
         {:ok, receipt} <- TicketPushRecoveryIO.readback(intent),
         true <- receipt == intent["receipt_json"] and digest(receipt) == intent["receipt_sha256"] and TicketPushRecoveryIO.receipt_valid?(receipt, intent),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == binding["origin"] and intent["remote_sha"] == run["candidate_sha"] do
      {:ok, %{intent: intent, binding: binding, envelope: raw, envelope_sha256: digest(raw), released_access: access, run: run}}
    else
      _ -> {:error, :push_recovery_completion_unproven}
    end
  end

  @spec validate_completed_proof(Store.connection(), String.t(), map()) :: :ok | {:error, term()}
  def validate_completed_proof(store, run_id, proof) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- run == proof[:run] and run["candidate_handoff"] == proof[:envelope],
         true <- digest(proof[:envelope]) == proof[:envelope_sha256],
         {:ok, intent} <- Jason.decode(proof[:envelope]),
         true <- intent == proof[:intent] and intent["kind"] == @kind and intent["phase"] == "COMPLETED",
         true <- digest(intent["binding_json"]) == intent["binding_sha256"] and digest(intent["receipt_json"]) == intent["receipt_sha256"],
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <-
           binding == proof[:binding] and
             Map.take(binding, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)) ==
               Map.take(run, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)),
         true <- TicketPushRecoveryIO.receipt_valid?(intent["receipt_json"], intent),
         {:ok, access} <- WorkspaceAccess.get(store, intent["reservation_key"]),
         true <- access == proof[:released_access] and access["release_receipt_json"] == proof[:envelope] and access["released_at"] != nil and access["generation"] == intent["reservation_generation"] do
      :ok
    else
      _ -> {:error, :ticket_push_proof_changed}
    end
  end

  @doc "Validates an authentic completed CAS predecessor against the stable source and a real current descendant. Never substitutes for exact-current completion authority."
  @spec validate_historical_completed_preimage(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_historical_completed_preimage(%DBConnection{}, _prior), do: {:error, :workspace_observation_inside_transaction}

  def validate_historical_completed_preimage(store, prior) when is_map(prior) do
    with {:ok, _observation} <- observe_historical_completed_preimage(store, prior), do: :ok
  end

  def validate_historical_completed_preimage(_store, _prior), do: {:error, :ticket_push_history_unproven}

  @doc false
  @spec observe_historical_completed_preimage(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def observe_historical_completed_preimage(%DBConnection{}, _prior), do: {:error, :workspace_observation_inside_transaction}

  def observe_historical_completed_preimage(store, prior) when is_map(prior) do
    started = System.monotonic_time(:millisecond)
    stable = ~w(run_id issue_key repo_key repo_path worktree branch base_branch)
    original_fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)

    with {:ok, current} <- RunLedger.get(store, prior["run_id"]),
         true <- Map.take(current, stable) == Map.take(prior, stable),
         raw when is_binary(raw) <- prior["candidate_handoff"],
         {:ok, %{"kind" => @kind, "phase" => "COMPLETED", "old_outcome" => "UNKNOWN"} = intent} <- Jason.decode(raw),
         true <- is_binary(intent["binding_json"]),
         true <- digest(intent["binding_json"]) == intent["binding_sha256"],
         {:ok, %{} = binding} <- Jason.decode(intent["binding_json"]),
         true <- is_map(binding["checkout"]),
         true <- Map.take(binding, original_fields) == Map.take(prior, original_fields),
         true <- is_binary(intent["original_envelope"]),
         :ok <- audited_original(intent["original_envelope"]),
         true <- digest(intent["original_envelope"]) == intent["original_envelope_sha256"],
         {:ok, execution} <- decode_object(intent["execution_json"]),
         true <-
           {execution["intent_json"], execution["intent_sha256"], execution["invocation"], execution["run_id"]} ==
             {intent["binding_json"], intent["binding_sha256"], intent["owner_nonce"], prior["run_id"]},
         {:ok, access} <- WorkspaceAccess.get(store, intent["reservation_key"]),
         true <- {access["run_id"], access["mode"], access["task_key"], access["generation"]} == {prior["run_id"], "MAINTENANCE", nil, intent["reservation_generation"]},
         true <- access["released_at"] != nil and access["release_receipt_json"] == raw,
         true <- is_binary(intent["receipt_json"]),
         {:ok, receipt} <- TicketPushRecoveryIO.readback(intent),
         true <- receipt == intent["receipt_json"] and digest(receipt) == intent["receipt_sha256"] and TicketPushRecoveryIO.receipt_valid?(receipt, intent),
         true <- intent["remote_sha"] == prior["candidate_sha"],
         {:ok, origin} <- Worktree.origin_identity(%{"path" => current["repo_path"]}, current["worktree"]),
         true <- origin == binding["origin"],
         {:ok, checkout} <-
           Worktree.checkout_identity(%{"path" => current["repo_path"]}, current["worktree"], clean: true, detached: false, expected_branch: current["branch"], expected_sha: current["candidate_sha"]),
         true <- Enum.all?(~w(path git_dir common_dir root_device root_inode)a, &(Map.get(checkout, &1) == get_in(binding, ["checkout", Atom.to_string(&1)]))),
         {:ok, ""} <- SymphonyElixir.Factory.TicketPushAncestryRead.run(current["worktree"], ["merge-base", "--is-ancestor", prior["candidate_sha"], current["candidate_sha"]]),
         {:ok, ^current} <- RunLedger.get(store, prior["run_id"]) do
      {:ok, %{kind: :cas, prior: prior, current: current, intent: intent, binding: binding, access: access, receipt: receipt, observed_at: started}}
    else
      _ -> {:error, :ticket_push_history_unproven}
    end
  end

  def observe_historical_completed_preimage(_store, _prior), do: {:error, :ticket_push_history_unproven}

  @doc "Rechecks an observed immutable CAS predecessor using ledger and receipt bytes only, never Git or helper IO."
  @spec recheck_historical_completed_preimage(Store.connection(), map(), map()) :: :ok | {:error, atom()}
  def recheck_historical_completed_preimage(store, prior, %{kind: :cas, prior: prior, current: expected, intent: intent, binding: binding, access: access, receipt: receipt, observed_at: at}) do
    fields = ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)
    stable = ~w(run_id issue_key repo_key repo_path worktree branch base_branch)

    with true <- is_integer(at) and (System.monotonic_time(:millisecond) - at) in 0..60_000,
         {:ok, ^expected} <- RunLedger.get(store, prior["run_id"]),
         true <- Map.take(prior, stable) == Map.take(expected, stable),
         {:ok, ^intent} <- decode_object(prior["candidate_handoff"]),
         true <- intent["kind"] == @kind and intent["phase"] == "COMPLETED" and intent["old_outcome"] == "UNKNOWN",
         {:ok, ^binding} <- decode_object(intent["binding_json"]),
         true <- digest(intent["binding_json"]) == intent["binding_sha256"] and Map.take(binding, fields) == Map.take(prior, fields),
         :ok <- original_binding(intent["original_envelope"]),
         true <- digest(intent["original_envelope"]) == intent["original_envelope_sha256"],
         {:ok, execution} <- decode_object(intent["execution_json"]),
         true <-
           {execution["intent_json"], execution["intent_sha256"], execution["invocation"], execution["run_id"]} ==
             {intent["binding_json"], intent["binding_sha256"], intent["owner_nonce"], prior["run_id"]},
         {:ok, ^access} <- WorkspaceAccess.get(store, intent["reservation_key"]),
         true <- {access["run_id"], access["mode"], access["task_key"], access["generation"]} == {prior["run_id"], "MAINTENANCE", nil, intent["reservation_generation"]},
         true <- access["released_at"] != nil and access["release_receipt_json"] == prior["candidate_handoff"],
         true <- is_binary(receipt) and receipt == intent["receipt_json"] and digest(receipt) == intent["receipt_sha256"] and TicketPushRecoveryIO.receipt_valid?(receipt, intent),
         true <- intent["remote_sha"] == prior["candidate_sha"] do
      :ok
    else
      _ -> {:error, :ticket_push_history_changed}
    end
  end

  def recheck_historical_completed_preimage(_store, _prior, _proof), do: {:error, :ticket_push_history_unproven}

  defp observation(store, run_id, nonce, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- execution_context(store, run),
         {:ok, %{"kind" => @kind, "old_outcome" => "UNKNOWN"} = intent} <- Jason.decode(run["candidate_handoff"] || "null"),
         true <- intent["owner_nonce"] == nonce or {:error, :push_recovery_nonce_changed},
         true <- digest(intent["original_envelope"]) == intent["original_envelope_sha256"],
         :ok <- audited_original(intent["original_envelope"]),
         {:ok, observed} <- TicketPush.recovery_observation(store, run_id, intent["original_envelope"], authorization, opts) do
      {:ok, observed, intent}
    else
      {:error, _} = error -> error
      _ -> {:error, :push_recovery_binding_unproven}
    end
  end

  defp predecessor(raw, %{"kind" => "TICKET_PUSH", "phase" => "PUSH_UNCERTAIN"}), do: {:ok, raw, [], 1}

  defp predecessor(raw, %{"kind" => @kind, "phase" => "PUSH_UNCERTAIN", "recovery_attempt" => attempt} = prior) when attempt in 1..2 do
    with true <- is_binary(prior["execution_json"]) and is_integer(prior["helper_pid"]),
         true <- digest(prior["original_envelope"]) == prior["original_envelope_sha256"],
         {:ok, execution} <- Jason.decode(prior["execution_json"]),
         true <- execution["helper_sha256"] == TicketPushRecoveryIO.helper_sha(),
         true <- execution["invocation"] == prior["owner_nonce"] and execution["intent_json"] == prior["binding_json"],
         true <- is_list(prior["unknown_predecessors"]) and length(prior["unknown_predecessors"]) == attempt - 1,
         true <-
           Enum.with_index(prior["unknown_predecessors"], 1)
           |> Enum.all?(fn {previous, ordinal} ->
             case Jason.decode(previous) do
               {:ok, item} -> item["kind"] == @kind and item["recovery_attempt"] == ordinal and item["original_envelope"] == prior["original_envelope"] and item["owner_nonce"] != prior["owner_nonce"]
               _ -> false
             end
           end) do
      {:ok, prior["original_envelope"], prior["unknown_predecessors"] ++ [raw], attempt + 1}
    else
      _ -> {:error, :push_recovery_predecessor_unproven}
    end
  end

  defp predecessor(_, %{"recovery_attempt" => 3}), do: {:error, :push_recovery_budget_exhausted}
  defp predecessor(_, _), do: {:error, :push_recovery_original_unproven}

  defp audited_original(raw) do
    with :ok <- original_binding(raw),
         {:ok, bytes} <- File.read(@old_helper),
         true <- digest(bytes) == @old_sha do
      :ok
    else
      _ -> {:error, :push_recovery_old_executor_unproven}
    end
  end

  defp original_binding(raw) do
    with {:ok, %{"version" => 1, "kind" => "TICKET_PUSH", "phase" => "PUSH_UNCERTAIN", "receipt_json" => nil} = old} <- decode_object(raw),
         {:ok, execution} <- decode_object(old["execution_json"]),
         true <- execution["helper_path"] == @old_helper and execution["helper_sha256"] == @old_sha,
         true <- execution["intent_json"] == old["binding_json"] and execution["invocation"] == old["owner_nonce"] do
      :ok
    else
      _ -> {:error, :push_recovery_old_executor_unproven}
    end
  end

  defp decode_object(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :push_recovery_object_unproven}
    end
  end

  defp decode_object(_raw), do: {:error, :push_recovery_object_unproven}

  defp read_recovery_ref(run) do
    ref = "refs/heads/" <> run["branch"]
    candidate = run["candidate_sha"]

    with {:ok, output} <- ControllerGitRead.run(run["repo_path"], ["ls-remote", "--refs", "origin", ref]) do
      case String.split(String.trim(output), ~r/\s+/) do
        [""] -> {:ok, nil}
        [^candidate, ^ref] -> {:ok, candidate}
        _ -> {:error, :push_recovery_remote_conflict}
      end
    end
  end

  if Mix.env() == :test do
    defp execution_context(store, run) do
      %{rows: databases} = Store.query!(store, "PRAGMA database_list")

      with [_id, "main", database] <- Enum.find(databases, fn [_, name, _] -> name == "main" end),
           {:ok, root} <- SymphonyElixir.PathSafety.canonicalize(Path.dirname(database)),
           true <- String.starts_with?(Path.basename(root), "ticket-worker-"),
           {:ok, temporary} <- SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!()),
           true <- String.starts_with?(root, temporary <> "/"),
           {:ok, repo} <- SymphonyElixir.PathSafety.canonicalize(run["repo_path"]),
           {:ok, source} <- SymphonyElixir.PathSafety.canonicalize(run["worktree"]),
           true <- String.starts_with?(repo, root <> "/") and String.starts_with?(source, root <> "/") do
        :ok
      else
        _ -> {:error, :push_recovery_fixture_paths_unproven}
      end
    end
  else
    defp execution_context(_store, _run), do: :ok
  end

  defp persist(tx, run, intent) do
    rows = Store.query!(tx, "UPDATE runs SET candidate_handoff = ? WHERE run_id = ? AND candidate_handoff = ? RETURNING run_id", [Jason.encode!(intent), run["run_id"], run["candidate_handoff"]]).rows
    if rows == [[run["run_id"]]], do: :ok, else: {:error, :push_recovery_envelope_changed}
  end

  defp retain_hazard(tx, run, original) do
    if Store.one!(tx, "SELECT id FROM events WHERE run_id = ? AND event_type = 'TICKET_PUSH_UNKNOWN_HAZARD'", [run["run_id"]]) == nil do
      Store.query!(tx, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_PUSH_UNKNOWN_HAZARD', ?, ?)", [
        now(),
        run["run_id"],
        Jason.encode!(%{"original_envelope" => original, "sha256" => digest(original), "candidate_sha" => run["candidate_sha"], "branch" => run["branch"], "worktree" => run["worktree"]})
      ])
    end

    Store.query!(tx, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_PUSH_CAS_ATTEMPT', ?, ?)", [
      now(),
      run["run_id"],
      Jason.encode!(%{"original_envelope_sha256" => digest(original)})
    ])

    :ok
  end

  @doc false
  @spec tick_binding(Store.connection(), keyword()) :: {:ok, map()} | {:error, atom()}
  def tick_binding(store, opts) do
    expected = opts[:operator_tick]

    with true <- is_map(expected) and Enum.sort(Map.keys(expected)) == ~w(dispatcher_id generation scope tick_id),
         current when is_map(current) <- Store.one!(store, "SELECT * FROM control WHERE scope = ?", [expected["scope"]]),
         true <- current["status"] == "ACTIVE" and Map.take(current, Map.keys(expected)) == expected,
         {:ok, expires, _} <- DateTime.from_iso8601(current["lease_expires_at"] || ""),
         true <- DateTime.diff(expires, DateTime.utc_now(), :second) > 0 do
      {:ok, expected}
    else
      _ -> {:error, :push_recovery_operator_tick_unproven}
    end
  end

  defp control_boundary(tx, run_id, opts) do
    cond do
      Store.one!(tx, "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING', 'ACCEPTED') LIMIT 1", [run_id]) != nil ->
        {:error, :push_recovery_pending_human_input}

      Store.one!(tx, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase NOT IN ('APPLIED', 'SUPERSEDED', 'REJECTED') LIMIT 1", [run_id]) != nil ->
        {:error, :push_recovery_pending_amendment}

      true ->
        case tick_binding(tx, opts) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp retain_error(store, run_id, nonce, reason) do
    Store.transaction!(store, fn tx ->
      with {:ok, run} <- RunLedger.get(tx, run_id),
           {:ok, intent} <- Jason.decode(run["candidate_handoff"]),
           true <- intent["owner_nonce"] == nonce and intent["kind"] == @kind and intent["phase"] == "PUSH_UNCERTAIN" do
        failure = %{"kind" => "TRANSPORT_UNCERTAIN", "phase" => "PUSH_UNCERTAIN", "code" => error_code(reason), "evidence_at" => now()}
        persist(tx, run, Map.put(intent, "failure", failure))
      end
    end)
  end

  defp error_code({:push_recovery_transport_exit, code, diagnostic, _digest}), do: "exit_#{code}:#{diagnostic}"
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "unclassified_transport_error"
  defp transition(%{"state" => "CI_PUSHING"}, sha), do: %{state: "CI_MR_CREATING", ci_preflight_sha: sha, ci_pipeline_id: nil, ci_pipeline_url: nil, ci_evidence_json: nil, ci_last_checked_at: nil}
  defp transition(_, _), do: %{state: "MR_CREATING"}
  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
