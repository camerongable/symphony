defmodule SymphonyElixir.Factory.TicketCiRepairSuccessor do
  @moduledoc "Immutable supplemental evidence under an existing CI repair claim; never ordinary result consumption."
  alias SymphonyElixir.Factory.{
    CiJobArtifacts,
    CiRepairReassessment,
    Controller,
    DesktopStageRunner,
    Policy,
    RepairObligations,
    RunLedger,
    Store,
    TaskLedger,
    TicketChat,
    TicketCiRepair,
    TicketCiReview,
    TicketMrGuard,
    TicketPush,
    TicketPushPayloadBudget,
    TicketPushRecovery,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerInstructions,
    WorkspaceAccess
  }

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Config.Schema, PathSafety, Workflow}

  @row_keys ~w(successor_key run_id claim_key prior_request_key prior_successor_key attempt_index configured_limit evidence_content_sha256 evidence_json evidence_sha256 proof_json proof_sha256 new_request_key new_reservation_key created_at)

  @doc "Hashes the exact complete immutable journal row using the physical validator's canonical UTF-8 encoding."
  @spec row_sha256(map()) :: {:ok, String.t()} | {:error, atom()}
  def row_sha256(row) when is_map(row) do
    if Enum.sort(Map.keys(row)) == Enum.sort(@row_keys),
      do: {:ok, row |> Enum.sort() |> Jason.OrderedObject.new() |> Jason.encode!() |> digest()},
      else: {:error, :ci_successor_row_unproven}
  end

  def row_sha256(_), do: {:error, :ci_successor_row_unproven}

  @doc "Captures every applied historical CI edge for a new push without upgrading existing intents."
  @spec push_context(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def push_context(store, run) do
    rows = successor_rows(store, run["run_id"])

    current_claim = Store.one!(store, "SELECT claim_key FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]])
    ordinary = match?({:ok, _}, RepairObligations.ordinary_preflight(store, run))

    if rows == [] and is_nil(current_claim) and not ordinary do
      {:ok, %{}}
    else
      with true <- length(rows) <= 9,
           :ok <- validate_push_rows(store, rows),
           {:ok, policy} <- push_policy(store, run),
           total = attempts_used(store, run["run_id"]),
           limit = if(policy, do: policy["effective_limit"], else: 10),
           true <- total <= limit or {:error, :ci_repair_attempt_limit},
           {:ok, current_claim} <- push_current_claim(store, run) do
        heads =
          rows
          |> Enum.group_by(& &1["claim_key"])
          |> Enum.sort()
          |> Enum.map(fn {claim, chain} ->
            head = List.last(chain)
            {:ok, sha} = row_sha256(head)
            %{"claim_key" => claim, "head_key" => head["successor_key"], "head_row_sha256" => sha, "chain_keys" => Enum.map(chain, & &1["successor_key"])}
          end)

        projection =
          Enum.map(rows, fn row ->
            {:ok, sha} = row_sha256(row)
            %{"successor_key" => row["successor_key"], "row_sha256" => sha}
          end)

        proof = %{
          "version" => 1,
          "kind" => "CI_EVIDENCE_SUCCESSOR_PUSH_V1",
          "heads" => heads,
          "all_rows_sha256" => canonical_digest(projection),
          "current_claim_key" => current_claim,
          "current_round" => run["code_repair_round"],
          "attempts_used" => total,
          "attempt_limit" => limit
        }

        fields = %{"ci_evidence_successor" => proof}
        fields = if(policy, do: Map.put(fields, "ci_repair_policy_receipt", policy), else: fields)

        case RepairObligations.ordinary_preflight(store, run) do
          {:ok, ordinary} -> {:ok, Map.put(fields, "ordinary_verifier_repair", ordinary)}
          _ -> {:ok, fields}
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :ci_successor_push_history_unproven}
      end
    end
  end

  @spec push_context(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_context(store, run, opts) do
    with {:ok, context} <- push_context(store, run) do
      task = Store.one!(store, "SELECT stage FROM factory_tasks WHERE run_id=? AND role='feature-writer'", [run["run_id"]])

      if map_size(context) > 0 and run["state"] == "PUSHING" and is_map(task) and task["stage"] == "REPAIRING" do
        with {:ok, qualification} <- prepare_verified_rollover(store, run, opts) do
          {:ok, Map.put(context, "verified_ci_rollover", qualification)}
        end
      else
        {:ok, context}
      end
    end
  end

  defp prepare_verified_rollover(store, run, opts) do
    owned_read_session(store, run, opts, &prepare_verified_rollover_in_session(store, run, &1))
  end

  defp prepare_verified_rollover_in_session(store, run, opts) do
    with {:ok, original} <- Jason.decode(run["candidate_handoff"] || "null"),
         {:ok, prior} <- rollover_prior(store, run, original["reservation_key"]),
         historical = Map.put(run, "verifier_round", prior.binding["verifier_round"]),
         {:ok, _} <- TicketPush.observe_historical_completed_preimage(store, historical),
         {:ok, claim_key} <- push_current_claim(store, Map.put(run, "state", "CI_PUSHING")),
         true <- prior_claim_matches?(store, run, prior.binding, claim_key),
         {:ok, verifier} <- rollover_verifier(store, run),
         {:ok, policy} <- delivery_policy_receipt(store, run, opts),
         {:ok, collected} <- TicketWorkerRunner.collect_ci(store, run["run_id"], policy.project_id, opts),
         {:ok, evidence} <- Jason.decode(run["ci_evidence_json"] || "null"),
         true <- collected["evidence"] == evidence and evidence["status"] == "PASS" do
      {:ok,
       %{
         "version" => 1,
         "kind" => "VERIFIED_CI_ROLLOVER_V1",
         "archived_claim_key" => claim_key,
         "prior_reservation_key" => prior.access["reservation_key"],
         "prior_envelope_sha256" => digest(prior.access["release_receipt_json"]),
         "prior_binding_sha256" => prior.intent["binding_sha256"],
         "prior_receipt_sha256" => prior.intent["receipt_sha256"],
         "verifier_request_key" => verifier["request_key"],
         "verifier_binding_sha256" => verifier["binding_sha256"],
         "verifier_output_sha256" => verifier["output_sha256"],
         "ci_evidence_sha256" => digest(run["ci_evidence_json"]),
         "ci_snapshots_sha256" => canonical_digest(collected["snapshots"]),
         "observed_at" => collected["observed_at"],
         "policy_receipt" => policy.receipt
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :verified_ci_rollover_unproven}
    end
  end

  defp rollover_prior(store, run, reservation) do
    with access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?", [reservation, run["run_id"]]),
         true <- access["mode"] == "MAINTENANCE" and access["task_key"] == nil and is_binary(access["released_at"]),
         raw when is_binary(raw) <- access["release_receipt_json"],
         {:ok, %{"kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = intent} <- Jason.decode(raw),
         {:ok, binding} <- object(intent["binding_json"], intent["binding_sha256"]),
         true <- binding["state"] == "CI_PUSHING" and not Map.has_key?(binding, "verified_ci_rollover"),
         true <- intent["reservation_key"] == reservation and intent["reservation_generation"] == access["generation"],
         true <- intent["remote_sha"] == run["candidate_sha"] and binding["verifier_round"] + 1 == run["verifier_round"],
         true <-
           Map.take(binding, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha spec_revision contract_sha256 code_repair_round)) ==
             Map.take(run, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha spec_revision contract_sha256 code_repair_round)),
         true <- digest(intent["receipt_json"]) == intent["receipt_sha256"] and SymphonyElixir.Factory.TicketPushIO.verified_rollover_prior?(intent) do
      {:ok, %{access: access, intent: intent, binding: binding}}
    else
      _ -> {:error, :verified_ci_rollover_prior_unproven}
    end
  end

  defp rollover_verifier(store, run) do
    key = run["run_id"] <> ":change-verifier:" <> to_string(run["verifier_round"])

    with task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=? AND run_id=? AND role='change-verifier'", [key, run["run_id"]]),
         true <- task["status"] == "CONSUMED" and task["stage"] == "VERIFYING",
         worker when is_map(worker) <-
           Store.one!(store, "SELECT * FROM worker_evidence WHERE task_key=? AND status='CONSUMED' AND thread_id=? AND turn_id=? AND output_json=?", [
             task["task_key"],
             task["thread_id"],
             task["turn_id"],
             task["output_json"]
           ]),
         {:ok, binding} <- object(worker["binding_json"], worker["binding_sha256"]),
         true <- binding["task_key"] == task["task_key"] and binding["prompt_sha256"] == task["prompt_sha256"] and binding["input_sha256"] == task["prompt_sha256"],
         {:ok, %{"status" => "PASS", "candidate_sha" => sha}} <- object(worker["output_json"], worker["output_sha256"]),
         true <- sha == run["candidate_sha"] and binding["expected_sha"] == sha and binding["role"] == "change-verifier" and binding["mode"] == "REVIEW" and binding["stage"] == "VERIFYING",
         true <- Map.take(binding, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         {:ok, packet} <- object(snapshot["binding_json"], mapping["instruction_binding_sha256"]),
         {:ok, _} <- WorkerInstructions.read(store, packet, "change-verifier"),
         true <- packet["candidate_sha"] == sha and packet["verifier_round"] == run["verifier_round"] and packet["role"] == "change-verifier" and packet["stage"] == "VERIFYING",
         true <- Map.take(packet, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         true <- WorkerEvidence.owner_stopped?(store, worker),
         :ok <- rollover_review_access(store, run, task, worker, binding) do
      {:ok, worker}
    else
      _ -> {:error, :verified_ci_rollover_verifier_unproven}
    end
  end

  defp rollover_review_access(store, run, task, worker, binding) do
    with access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [worker["reservation_key"]]),
         true <- access["mode"] == "REVIEW" and access["run_id"] == run["run_id"] and access["task_key"] == task["task_key"] and access["request_key"] == worker["request_key"],
         true <- binding["reservation_key"] == access["reservation_key"] and binding["reservation_generation"] == access["generation"] and is_binary(access["released_at"]),
         {:ok, release} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- release == Map.take(worker, ~w(request_key binding_sha256 output_sha256 owner_stopped_at consumed_at)),
         {:ok, saved} when is_map(saved) <- Jason.decode(access["binding_json"]),
         true <-
           Enum.sort(Map.keys(saved)) ==
             Enum.sort(
               ~w(path git_dir common_dir root_device root_inode allowed_root branch candidate_sha contract_sha256 expected_sha mode prompt_sha256 request_key reservation_key run_id run_state spec_revision task_key)
             ),
         true <- saved["candidate_sha"] == run["candidate_sha"] and saved["branch"] == run["branch"] and saved["run_state"] == "VERIFYING",
         true <- saved["path"] == access["canonical_path"] and saved["path"] == run["worktree"] and saved["path"] == binding["policy"]["cwd"],
         true <-
           saved["git_dir"] == access["git_dir"] and saved["common_dir"] == access["common_dir"] and is_integer(saved["root_device"]) and is_integer(saved["root_inode"]) and
             is_binary(saved["allowed_root"]),
         true <-
           Map.take(saved, ~w(run_id task_key request_key reservation_key mode expected_sha spec_revision contract_sha256 prompt_sha256)) ==
             Map.merge(Map.take(binding, ~w(run_id task_key reservation_key mode expected_sha spec_revision contract_sha256 prompt_sha256)), %{"request_key" => worker["request_key"]}) do
      :ok
    else
      _ -> {:error, :verified_ci_rollover_verifier_unproven}
    end
  end

  @doc "Checks a module-prepared post-CI verifier qualification without refreshing its observation or granting a repair attempt."
  @spec validate_verified_rollover(Store.connection(), map(), map(), Store.connection()) :: :ok | {:error, term()}
  def validate_verified_rollover(store, run, qualification, policy_store) do
    keys =
      ~w(version kind archived_claim_key prior_reservation_key prior_envelope_sha256 prior_binding_sha256 prior_receipt_sha256 verifier_request_key verifier_binding_sha256 verifier_output_sha256 ci_evidence_sha256 ci_snapshots_sha256 observed_at policy_receipt)

    with true <- run["state"] == "PUSHING" and is_map(qualification) and Enum.sort(Map.keys(qualification)) == Enum.sort(keys),
         true <- qualification["version"] == 1 and qualification["kind"] == "VERIFIED_CI_ROLLOVER_V1",
         true <- hex?(qualification["ci_snapshots_sha256"]),
         true <- is_binary(qualification["observed_at"]) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, qualification["observed_at"]),
         {:ok, observed, _} <- DateTime.from_iso8601(qualification["observed_at"]),
         true <- DateTime.diff(DateTime.utc_now(), observed, :millisecond) in -5_000..60_000,
         {:ok, prior} <- rollover_prior(store, run, qualification["prior_reservation_key"]),
         true <- digest(prior.access["release_receipt_json"]) == qualification["prior_envelope_sha256"],
         true <- prior.intent["binding_sha256"] == qualification["prior_binding_sha256"] and prior.intent["receipt_sha256"] == qualification["prior_receipt_sha256"],
         {:ok, key} <- push_current_claim(store, Map.put(run, "state", "CI_PUSHING")),
         true <- key == qualification["archived_claim_key"] and prior_claim_matches?(store, run, prior.binding, key),
         {:ok, verifier} <- rollover_verifier(store, run),
         true <-
           Map.take(qualification, ~w(verifier_request_key verifier_binding_sha256 verifier_output_sha256)) == %{
             "verifier_request_key" => verifier["request_key"],
             "verifier_binding_sha256" => verifier["binding_sha256"],
             "verifier_output_sha256" => verifier["output_sha256"]
           },
         true <- digest(run["ci_evidence_json"]) == qualification["ci_evidence_sha256"],
         {:ok, %{"status" => "PASS", "sha" => sha, "failed_jobs" => [], "findings" => []}} <- Jason.decode(run["ci_evidence_json"]),
         true <- sha == run["candidate_sha"],
         :ok <- recheck_delivery_policy(policy_store, store, run, qualification["policy_receipt"]) do
      :ok
    else
      _ -> {:error, :verified_ci_rollover_changed}
    end
  end

  defp recheck_delivery_policy(policy_store, store, run, policy) do
    with true <- is_map(policy) and Enum.sort(Map.keys(policy)) == Enum.sort(~w(version kind workflow_path workflow_sha256 workflow_stat scope dispatcher_id repo_key cached_policy_sha256 control)),
         true <- policy["version"] == 1 and policy["kind"] == "VERIFIED_CI_DELIVERY_POLICY_V1" and policy["repo_key"] == run["repo_key"],
         {:ok, cached} <- Controller.cached_generation_policy(policy_store, run["repo_key"]),
         true <- digest(Jason.encode!(cached)) == policy["cached_policy_sha256"] and cached["enabled"] == true and cached["ticket_supervisor_enabled"] == true,
         true <- cached["scope"] == policy["scope"] and cached["dispatcher_id"] == policy["dispatcher_id"] and Workflow.workflow_file_path() == policy["workflow_path"],
         true <- policy["control"]["scope"] == policy["scope"] and policy["control"]["dispatcher_id"] == policy["dispatcher_id"],
         {:ok, stat} <- File.lstat(policy["workflow_path"], time: :posix),
         true <- stat.type == :regular and workflow_stat(stat) == policy["workflow_stat"],
         {:ok, _} <- TicketPushRecovery.tick_binding(store, operator_tick: policy["control"]) do
      :ok
    else
      _ -> {:error, :verified_ci_rollover_policy_unproven}
    end
  end

  @spec recheck_push_context(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def recheck_push_context(store, run, context), do: recheck_push_context(store, run, context, store)

  @spec recheck_push_context(Store.connection(), map(), map(), Store.connection()) :: :ok | {:error, term()}
  def recheck_push_context(store, run, %{"ordinary_verifier_repair" => _} = context, policy_store) when not is_map_key(context, "ci_evidence_successor") do
    with true <- successor_rows(store, run["run_id"]) == [],
         :ok <- recheck_ordinary(store, run, context),
         :ok <- recheck_optional_rollover(store, run, context, policy_store) do
      :ok
    else
      _ -> {:error, :ordinary_verifier_repair_changed}
    end
  end

  def recheck_push_context(store, run, context, policy_store) do
    if map_size(context) == 0 do
      :ok
    else
      rows = successor_rows(store, run["run_id"])

      projection =
        Enum.map(rows, fn row ->
          {:ok, sha} = row_sha256(row)
          %{"successor_key" => row["successor_key"], "row_sha256" => sha}
        end)

      policy = context["ci_repair_policy_receipt"]

      with :ok <- validate_push_rows(store, rows),
           true <- canonical_digest(projection) == get_in(context, ["ci_evidence_successor", "all_rows_sha256"]),
           true <- attempts_used(store, run["run_id"]) == get_in(context, ["ci_evidence_successor", "attempts_used"]),
           {:ok, claim} <- push_current_claim(store, run),
           true <- claim == get_in(context, ["ci_evidence_successor", "current_claim_key"]),
           :ok <- recheck_push_policy(policy_store, run, policy),
           :ok <- recheck_ordinary(store, run, context),
           :ok <- recheck_optional_rollover(store, run, context, policy_store) do
        :ok
      else
        _ -> {:error, :ci_successor_push_context_changed}
      end
    end
  end

  defp recheck_optional_rollover(store, run, %{"verified_ci_rollover" => qualification}, policy_store), do: validate_verified_rollover(store, run, qualification, policy_store)
  defp recheck_optional_rollover(_, _, _, _), do: :ok

  defp successor_rows(store, run_id) do
    %{columns: columns, rows: rows} = Store.query!(store, "SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id=? ORDER BY attempt_index", [run_id])
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp validate_push_rows(store, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case applied(store, row["successor_key"]) do
        {:ok, %{row: ^row}} -> {:cont, :ok}
        _ -> {:halt, {:error, :ci_successor_push_history_unproven}}
      end
    end)
  end

  defp push_policy(store, %{"state" => "CI_PUSHING"} = run) do
    case RepairObligations.ordinary_preflight(store, run) do
      {:ok, _} -> {:ok, nil}
      _ -> policy_receipt(store, run)
    end
  end

  defp push_policy(_, %{"state" => "PUSHING"}), do: {:ok, nil}
  defp push_policy(_, _), do: {:error, :ci_successor_push_stage_invalid}

  defp push_current_claim(store, %{"state" => "CI_PUSHING"} = run) do
    if is_nil(Store.one!(store, "SELECT claim_key FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]])) do
      case RepairObligations.ordinary_preflight(store, run) do
        {:ok, _} -> {:ok, nil}
        error -> error
      end
    else
      with row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]]),
           {:ok, claim} <- push_object(row["claim_json"], row["claim_sha256"], :claim),
           :ok <- CiRepairReassessment.validate_claim(store, claim),
           key = row["claim_key"],
           true <- key == row["claim_key"] and claim["claim_key"] == key and claim["round"] == run["code_repair_round"],
           task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE run_id=? AND role='feature-writer'", [run["run_id"]]),
           true <- task["status"] == "CONSUMED" and task["stage"] == "REPAIRING",
           worker when is_map(worker) <-
             Store.one!(store, "SELECT * FROM worker_evidence WHERE task_key=? AND status='CONSUMED' AND thread_id=? AND turn_id=? AND output_json=?", [
               task["task_key"],
               task["thread_id"],
               task["turn_id"],
               task["output_json"]
             ]),
           {:ok, bound} <- object(worker["binding_json"], worker["binding_sha256"]),
           true <- WorkerEvidence.owner_stopped?(store, worker),
           {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
           snapshot when is_map(snapshot) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
           {:ok, packet} <- object(snapshot["binding_json"], mapping["instruction_binding_sha256"]),
           archived = run |> Map.put("state", "REPAIRING") |> Map.put("candidate_sha", bound["expected_sha"]) |> Map.put("repair_findings_json", packet["repair_findings"]),
           :ok <- instruction_claim(store, task, bound, archived),
           :ok <- current_packet_scope(store, packet, run) do
        {:ok, key}
      else
        _ -> {:error, :ci_successor_current_claim_unproven}
      end
    end
  end

  defp push_current_claim(_, %{"state" => "PUSHING"}), do: {:ok, nil}
  defp push_current_claim(_, _), do: {:error, :ci_successor_push_stage_invalid}

  defp recheck_push_policy(_store, %{"state" => "PUSHING"}, nil), do: :ok

  defp recheck_push_policy(_store, %{"state" => "CI_PUSHING"}, nil), do: :ok

  defp recheck_push_policy(store, %{"state" => "CI_PUSHING"} = run, policy) when is_map(policy) do
    with {:ok, cached} <- Controller.cached_generation_policy(store, run["repo_key"]),
         true <- digest(Jason.encode!(cached)) == policy["cached_policy_sha256"],
         true <- Workflow.workflow_file_path() == policy["workflow_path"],
         {:ok, stat} <- File.lstat(policy["workflow_path"], time: :posix),
         true <- stat.type == :regular and workflow_stat(stat) == policy["workflow_stat"] do
      :ok
    else
      _ -> {:error, :ci_successor_current_policy_unproven}
    end
  end

  defp recheck_push_policy(_, _, _), do: {:error, :ci_successor_current_policy_unproven}

  defp recheck_ordinary(store, run, %{"ordinary_verifier_repair" => proof}) do
    case RepairObligations.ordinary_preflight(store, run) do
      {:ok, ^proof} -> :ok
      _ -> {:error, :ordinary_verifier_repair_changed}
    end
  end

  defp recheck_ordinary(store, %{"state" => "CI_PUSHING"} = run, _) do
    if Store.one!(store, "SELECT claim_key FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]]),
      do: :ok,
      else: {:error, :ordinary_verifier_repair_changed}
  end

  defp recheck_ordinary(_, _, _), do: :ok

  defp prior_claim_matches?(store, run, binding, nil) do
    case RepairObligations.ordinary_preflight(store, run) do
      {:ok, proof} -> binding["ordinary_verifier_repair"] == proof and not Map.has_key?(binding, "ci_repair")
      _ -> false
    end
  end

  defp prior_claim_matches?(_, _, binding, key), do: get_in(binding, ["ci_repair", "claim_key"]) == key

  defp canonical_digest(value), do: value |> canonical_value() |> Jason.encode!() |> digest()
  defp canonical_value(value) when is_map(value), do: value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical_value(item)} end) |> Jason.OrderedObject.new()
  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  @spec eligible?(Store.connection(), map(), String.t()) :: boolean()
  def eligible?(store, %{"state" => "REPAIRING"} = run, key) do
    with {:ok, prior} <- WorkerEvidence.get(store, key),
         true <- prior["status"] == "RESULT_RECORDED" and prior["run_id"] == run["run_id"] and WorkerEvidence.owner_stopped?(store, prior),
         {:ok, %{"status" => "BLOCKED", "changed_paths" => []}} <- object(prior["output_json"], prior["output_sha256"]),
         %{"count" => 1} <-
           Store.one!(store, "SELECT COUNT(*) AS count FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_WRITER_BLOCKED' AND json_extract(payload_json,'$.request_key')=?", [run["run_id"], key]),
         nil <- Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE prior_request_key=?", [key]) do
      true
    else
      _ -> false
    end
  end

  def eligible?(_, _, _), do: false

  @doc "Collects fresh supplemental evidence and stopped SOURCE identity outside SQLite; grants no dispatch authority."
  @spec prepare(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, request, authorization, opts) do
    with {:ok, prior} <- WorkerEvidence.get(store, request),
         {:ok, run} <- RunLedger.get(store, prior["run_id"]),
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization),
         {:ok, _} <- policy_receipt(store, run),
         :ok <- WorkspaceAccess.source_capacity(store, run, opts),
         {:ok, _} <- TicketPushRecovery.tick_binding(store, opts) do
      owned_read_session(store, run, opts, &prepare_in_session(store, request, authorization, &1))
    end
  end

  defp owned_read_session(%DBConnection{}, _run, _opts, _operation), do: {:error, :workspace_observation_inside_transaction}

  defp owned_read_session(store, run, opts, operation) do
    if is_nil(opts[:mcp_session]) do
      with {:ok, cached} <- Controller.cached_generation_policy(store, run["repo_key"]),
           root = Config.local_workspace_root(),
           expected = Path.join([root, "factory-controller", String.replace(cached["scope"], ~r/[^a-zA-Z0-9._-]/, "_")]),
           {:ok, workspace} <- PathSafety.canonicalize(expected),
           true <- workspace == Path.expand(expected) and File.dir?(workspace) and not inside_source?(workspace, run["worktree"]),
           true <- is_nil(opts[:workspace]) or Path.expand(opts[:workspace]) == workspace do
        AppServer.with_gitlab_read_session(workspace, fn session ->
          operation.(opts |> Keyword.put(:workspace, workspace) |> Keyword.put(:mcp_session, session))
        end)
      else
        {:error, _} = error -> error
        _ -> {:error, :ci_successor_controller_workspace_unproven}
      end
    else
      operation.(opts)
    end
  end

  defp prepare_in_session(store, request, authorization, opts) do
    with {:ok, prior} <- WorkerEvidence.get(store, request),
         {:ok, run} <- RunLedger.get(store, prior["run_id"]),
         true <- run["state"] == "REPAIRING" or {:error, :ci_successor_not_repairing},
         nil <- Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE prior_request_key=?", [request]),
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization),
         {:ok, policy} <- policy_receipt(store, run),
         true <- attempts_used(store, run["run_id"]) < policy["effective_limit"] or {:error, :ci_repair_attempt_limit},
         {:ok, _} <- TicketChat.ready_for_run(store, run["run_id"]),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, run["run_id"]),
         {:ok, retained} <- TicketCiRepair.retained_preimage(store, run),
         :ok <- TicketPush.validate_historical_completed_preimage(store, retained),
         {:ok, scope} when is_map(scope) <- TicketCiRepair.writer_scope(store, run),
         claim when is_map(claim) <- Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?", [scope["claim_key"]]),
         {:ok, task} <- TaskLedger.get(store, prior["task_key"]),
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [prior["reservation_key"]]),
         [event] <-
           Store.query!(store, "SELECT * FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_WRITER_BLOCKED' AND json_extract(payload_json,'$.request_key')=?", [run["run_id"], request]).rows
           |> event_maps(store),
         {:ok, bound} <- object(prior["binding_json"], prior["binding_sha256"]),
         {:ok, _initial_native} <- native_observation(task, bound, opts),
         {:ok, source} <- WorkspaceAccess.prepare_ci_successor_source(store, run, access, opts[:workspace_root]),
         :ok <- WorkspaceAccess.source_capacity(store, run, opts),
         {:ok, collected} <- TicketWorkerRunner.collect_ci(store, run["run_id"], get_in(scope, ["ci_snapshots", "mr", "project_id"]), opts),
         true <- collected["evidence"]["status"] == "BLOCK" or {:error, :ci_successor_pipeline_not_failed},
         {:ok, identity} <- snapshot_identity(collected["snapshots"]),
         {:ok, ^identity} <- snapshot_identity(scope["ci_snapshots"]),
         project = get_in(identity, ["mr", "project_id"]),
         :ok <- TicketCiRepair.review_blockers(collected["snapshots"]["mr"]),
         {:ok, _initial_review} <- TicketCiReview.observe(project, run["mr_iid"], opts),
         jobs = Enum.filter(identity["jobs"], &(&1["allow_failure"] == false and &1["status"] in ~w(failed canceled canceling))),
         artifacts = CiJobArtifacts.collect(run, project, jobs, opts),
         {:ok, evidence} <- supplemental_evidence(artifacts, project, Enum.map(jobs, & &1["id"])),
         {:ok, closing} <- TicketWorkerRunner.collect_ci(store, run["run_id"], project, opts),
         {:ok, ^identity} <- snapshot_identity(closing["snapshots"]),
         true <- closing["evidence"]["status"] == "BLOCK" or {:error, :ci_successor_pipeline_not_failed},
         {:ok, review} <- TicketCiReview.observe(project, run["mr_iid"], opts),
         {:ok, native} <- native_observation(task, bound, opts),
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         {:ok, ^run} <- RunLedger.get(store, run["run_id"]),
         {:ok, ^inputs} <- TicketCiRepair.input_snapshot(store, run["run_id"]),
         {:ok, ^policy} <- policy_receipt(store, run) do
      materialize(store, %{
        run: run,
        claim: claim,
        prior: prior,
        task: task,
        access: access,
        event: event,
        authorization: authorization,
        inputs: inputs,
        policy: policy,
        source: source,
        native: native,
        review: review,
        snapshots: closing["snapshots"],
        evidence: evidence,
        tick: tick,
        owner: Process.whereis(Controller)
      })
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_preparation_unproven}
    end
  end

  defp materialize(store, context) do
    head = Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE claim_key=? ORDER BY attempt_index DESC LIMIT 1", [context.claim["claim_key"]])

    with {:ok, ancestors} <- prepared_ancestors(store, head),
         claim <- Jason.decode!(context.claim["claim_json"]),
         base when is_map(base) <- CiRepairReassessment.claimed(store, claim),
         {:ok, diagnosis} <- object(base["diagnosis_json"], base["diagnosis_sha256"]),
         project = get_in(context.snapshots, ["mr", "project_id"]),
         jobs = Enum.map(context.snapshots["jobs"], & &1["id"]),
         {:ok, baseline} <- baseline_content(diagnosis["artifacts"], project, jobs),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, context.task),
         instruction when is_map(instruction) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         {:ok, packet} <- object(instruction["binding_json"], mapping["instruction_binding_sha256"]),
         {:ok, bundle} <- WorkerInstructions.read(store, packet, "ci-repair-writer") do
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      content = context.evidence["content_members"]
      content_sha = digest(Jason.encode!(content))
      previous = List.last(ancestors)
      previous_sha = if previous, do: previous.row["evidence_content_sha256"], else: if(baseline == [], do: nil, else: digest(Jason.encode!(baseline)))

      outcome = %{
        "kind" => "BLOCKED_NO_EDIT_ACCEPTED_V1",
        "event_id" => context.event["id"],
        "event_sha256" => digest(Jason.encode!(context.event)),
        "request_key" => context.prior["request_key"],
        "output_sha256" => context.prior["output_sha256"],
        "candidate_sha" => context.run["candidate_sha"]
      }

      proof = %{
        "version" => 1,
        "kind" => "CI_EVIDENCE_SUCCESSOR_V1",
        "run" => context.run,
        "claim" => context.claim,
        "prior_evidence" => context.prior,
        "prior_task" => context.task,
        "prior_access" => context.access,
        "disposition_event" => context.event,
        "accepted_outcome" => outcome,
        "inputs" => context.inputs,
        "source_observation" => %{"canonical_path" => context.source.observed.path, "head_sha" => context.run["candidate_sha"], "dirty_paths" => []},
        "authorization" => context.authorization,
        "ci_snapshots" => context.snapshots,
        "content_members" => content,
        "previous_content_sha256" => previous_sha,
        "total_before" => attempts_used(store, context.run["run_id"]),
        "configured_limit" => context.policy["effective_limit"],
        "policy_receipt" => context.policy,
        "admitted_at" => timestamp
      }

      raw_proof = Jason.encode!(proof)
      raw_evidence = Jason.encode!(context.evidence)
      key = successor_key(context.claim["claim_key"], context.prior["request_key"], content_sha)

      row = %{
        "successor_key" => key,
        "run_id" => context.run["run_id"],
        "claim_key" => context.claim["claim_key"],
        "prior_request_key" => context.prior["request_key"],
        "prior_successor_key" => if(previous, do: previous.row["successor_key"]),
        "attempt_index" => proof["total_before"] + 1,
        "configured_limit" => proof["configured_limit"],
        "evidence_content_sha256" => content_sha,
        "evidence_json" => raw_evidence,
        "evidence_sha256" => digest(raw_evidence),
        "proof_json" => raw_proof,
        "proof_sha256" => digest(raw_proof),
        "created_at" => timestamp
      }

      new_packet =
        packet
        |> put_in(["ci_repair", "allowed_writer_paths"], claim["allowed_writer_paths"])
        |> Map.put("ci_evidence_successor", packet_binding(row))
        |> Map.put("ci_evidence_successor_evidence", context.evidence)
        |> extend_packet(context.policy)

      instruction_sha = digest(Jason.encode!(new_packet))
      prompt = Jason.encode!(Map.merge(new_packet, Map.put(bundle, "instruction_binding_sha256", instruction_sha)))
      request = DesktopStageRunner.request_key(context.task["task_key"], context.task["turn_id"], prompt)
      row = Map.merge(row, %{"new_request_key" => request, "new_reservation_key" => "workspace:" <> request})

      with true <- TicketPushPayloadBudget.bounded?(proof, :successor) and byte_size(raw_evidence) <= 262_144,
           :ok <- journal_identity(store, row, proof, context.evidence),
           :ok <- content_newness(store, row, proof, context.evidence, ancestors) do
        {:ok, Map.merge(context, %{row: row, proof: proof, packet: new_packet, prior_packet: packet, instruction_sha: instruction_sha, prompt: prompt})}
      else
        {:error, _} = error -> error
        _ -> {:error, :ci_successor_preparation_limit}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_preparation_unproven}
    end
  end

  defp prepared_ancestors(_store, nil), do: {:ok, []}

  defp prepared_ancestors(store, %{"successor_key" => key}) do
    with {:ok, prior} <- applied(store, key), do: {:ok, prior.ancestors ++ [prior]}
  end

  defp packet_binding(row),
    do: %{
      "version" => 1,
      "kind" => "CI_EVIDENCE_SUCCESSOR_PACKET_V1",
      "successor_key" => row["successor_key"],
      "proof_sha256" => row["proof_sha256"],
      "evidence_sha256" => row["evidence_sha256"],
      "evidence_content_sha256" => row["evidence_content_sha256"],
      "attempt_index" => row["attempt_index"]
    }

  @doc "Atomically journals, transfers SOURCE, and reserves one new attempt; never sends a native turn."
  @spec admit(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit(%DBConnection{}, _, _), do: {:error, :workspace_observation_inside_transaction}

  def admit(store, context, opts) do
    with :ok <- WorkspaceAccess.source_capacity(store, context.run, opts),
         {:ok, source} <- WorkspaceAccess.prepare_ci_successor_source(store, context.run, context.access, context.source.root),
         true <- source == context.source or {:error, :ci_successor_source_changed},
         {:ok, policy} <- policy_receipt(store, context.run),
         true <- policy == context.policy or {:error, :ci_successor_current_policy_unproven} do
      case Exqlite.transaction(
             store,
             fn tx ->
               case admit_transaction(tx, context, opts) do
                 {:ok, result} -> result
                 {:error, reason} -> Exqlite.rollback(tx, reason)
               end
             end,
             timeout: 60_000
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp admit_transaction(%DBConnection{} = tx, context, opts) do
    row = context.row

    attrs = %{
      "reservation_key" => row["new_reservation_key"],
      "run_id" => row["run_id"],
      "task_key" => context.task["task_key"],
      "request_key" => row["new_request_key"],
      "mode" => "SOURCE",
      "allowed_root" => context.source.root,
      "expected_sha" => context.run["candidate_sha"],
      "prompt_sha256" => digest(context.prompt)
    }

    with :ok <- bound_context(context),
         :ok <- final_context(tx, context, opts),
         nil <- Store.one!(tx, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE prior_request_key=?", [row["prior_request_key"]]),
         true <- context.packet["ci_evidence_successor"] == packet_binding(row) and context.packet["ci_evidence_successor_evidence"] == context.evidence,
         true <- digest(Jason.encode!(context.packet)) == context.instruction_sha,
         _ <-
           Store.query!(tx, "INSERT INTO ticket_ci_repair_evidence_successors(#{Enum.join(@row_keys, ",")}) VALUES (#{Enum.map_join(@row_keys, ",", fn _ -> "?" end)})", Enum.map(@row_keys, &row[&1])),
         {:ok, _entry} <- journal(tx, row["successor_key"]),
         {:ok, inherited} <- WorkerInstructions.inherit(tx, context.packet, "ci-repair-writer", context.task, context.prior_packet),
         true <- inherited["instruction_binding_sha256"] == context.instruction_sha,
         true <- Jason.encode!(Map.merge(context.packet, inherited)) == context.prompt,
         {:ok, access} <- WorkspaceAccess.transfer_ci_successor_source(tx, context.source, attrs, row["successor_key"]),
         {:ok, task} <-
           TaskLedger.update(tx, context.task["task_key"], %{
             stage: "REPAIRING",
             status: "STARTING",
             prompt_sha256: digest(context.prompt),
             workspace: access["canonical_path"],
             workspace_sha: context.run["candidate_sha"],
             output_json: nil,
             failure_code: nil
           }),
         {:ok, old_binding} <- object(context.prior["binding_json"], context.prior["binding_sha256"]),
         {:ok, destination} <-
           WorkerEvidence.reserve_ci_successor(
             tx,
             %{
               "request_key" => row["new_request_key"],
               "task_key" => task["task_key"],
               "reservation_key" => access["reservation_key"],
               "input_sha256" => digest(context.prompt),
               "owner_id" => "owner:" <> row["new_request_key"],
               "schema" => old_binding["schema"],
               "policy" => old_binding["policy"]
             },
             row["successor_key"]
           ),
         :ok <- WorkerInstructions.bind_task(tx, task["task_key"], digest(context.prompt), context.instruction_sha),
         payload = applied_receipt(%{row: row, proof: context.proof}, destination, access),
         _ <-
           Store.query!(tx, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_CI_REPAIR_SUCCESSOR_APPLIED',?,?)", [
             DateTime.utc_now() |> DateTime.to_iso8601(),
             row["run_id"],
             Jason.encode!(payload)
           ]),
         {:ok, result} <- applied(tx, row["successor_key"]),
         :ok <- final_context(tx, context, opts, :admitted) do
      {:ok, Map.merge(result, %{task: task, prompt: context.prompt, instruction_sha: context.instruction_sha})}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_admission_changed}
    end
  end

  defp bound_context(context) do
    with {:ok, proof} <- push_object(context.row["proof_json"], context.row["proof_sha256"], :successor),
         true <- proof == context.proof,
         {:ok, evidence} <- object(context.row["evidence_json"], context.row["evidence_sha256"]),
         true <- evidence == context.evidence,
         true <-
           proof["run"] == context.run and proof["claim"] == context.claim and proof["prior_task"] == context.task and proof["prior_evidence"] == context.prior and
             proof["prior_access"] == context.access and proof["disposition_event"] == context.event,
         true <- proof["inputs"] == context.inputs and proof["authorization"] == context.authorization and proof["policy_receipt"] == context.policy and proof["ci_snapshots"] == context.snapshots,
         true <- context.source.run == context.run and context.source.old == context.access,
         {:ok, prior_binding} <- object(context.prior["binding_json"], context.prior["binding_sha256"]),
         true <- context.native.request == native_request(context.task, prior_binding),
         true <- context.row["new_request_key"] == DesktopStageRunner.request_key(context.task["task_key"], context.task["turn_id"], context.prompt),
         true <- context.row["new_reservation_key"] == "workspace:" <> context.row["new_request_key"] do
      :ok
    else
      _ -> {:error, :ci_successor_preparation_changed}
    end
  rescue
    _ -> {:error, :ci_successor_preparation_changed}
  end

  defp final_context(tx, context, opts, phase \\ :prepared) do
    with {:ok, current} <- RunLedger.get(tx, context.run["run_id"]),
         true <- current == context.run,
         true <- is_pid(context.owner) and Process.whereis(Controller) == context.owner and Process.alive?(context.owner),
         {:ok, tick} <- TicketPushRecovery.tick_binding(tx, opts),
         true <- tick == context.tick and tick["scope"] == context.policy["scope"] and tick["dispatcher_id"] == context.policy["dispatcher_id"],
         :ok <- TicketWorkerRunner.validate_authorization(current, context.authorization),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(tx, current["run_id"]),
         true <- inputs == context.inputs,
         true <- policy_file_current?(context.policy),
         :ok <- TicketCiReview.validate_receipt(get_in(context.snapshots, ["mr", "project_id"]), current["mr_iid"], context.review),
         :ok <- TicketMrGuard.native_receipt(context.native.request, context.native.receipt, DateTime.utc_now()),
         true <- attempts_used(tx, current["run_id"]) == context.proof["total_before"] + if(phase == :admitted, do: 1, else: 0),
         true <- context.row["attempt_index"] <= context.policy["effective_limit"],
         nil <-
           Store.one!(
             tx,
             "SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence e ON e.request_key=op.request_key WHERE e.run_id=? AND (op.phase='PREPARED' OR op.io_pending=1) LIMIT 1",
             [current["run_id"]]
           ),
         nil <- Store.one!(tx, "SELECT intent_key FROM ticket_ci_generation_intents WHERE request_key=? LIMIT 1", [context.prior["request_key"]]),
         nil <-
           Store.one!(
             tx,
             "SELECT i.intent_key FROM ticket_ci_generation_intents i WHERE i.run_id=? AND NOT EXISTS(SELECT 1 FROM ticket_ci_generation_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path='') LIMIT 1",
             [current["run_id"]]
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_admission_changed}
    end
  end

  defp policy_file_current?(receipt) do
    with true <- Workflow.workflow_file_path() == receipt["workflow_path"],
         {:ok, stat} <- File.lstat(receipt["workflow_path"], time: :posix),
         true <- stat.type == :regular and stat.links == 1 and workflow_stat(stat) == receipt["workflow_stat"],
         {:ok, raw} <- File.read(receipt["workflow_path"]),
         true <- digest(raw) == receipt["workflow_sha256"],
         {:ok, after_read} <- File.lstat(receipt["workflow_path"], time: :posix) do
      after_read.type == :regular and after_read.links == 1 and workflow_stat(after_read) == receipt["workflow_stat"]
    else
      _ -> false
    end
  end

  defp event_maps(rows, store) do
    columns = Store.query!(store, "PRAGMA table_info(events)").rows |> Enum.map(&Enum.at(&1, 1))
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp native_observation(task, binding, opts) do
    request = native_request(task, binding)
    reader = opts[:app_server] || AppServer

    with {:ok, native} <- reader.read_native_thread(task["thread_id"], workspace: opts[:workspace], include_turns: false, include_latest_turn: true, include_queue: true),
         :ok <- TicketMrGuard.native_receipt(request, native, DateTime.utc_now()) do
      {:ok, %{request: request, receipt: native}}
    end
  end

  defp native_request(task, binding),
    do: %{
      "existing_thread_id" => task["thread_id"],
      "cwd" => binding["policy"]["cwd"],
      "codex_project_id" => task["codex_project_id"] || "projectless",
      "metadata_json" => Jason.encode!(%{"previous_turn_id" => task["turn_id"], "delivery_operation" => %{"controller_native_cwd" => binding["policy"]["cwd"]}})
    }

  defp supplemental_evidence(artifacts, project, jobs) do
    base = Enum.map(artifacts, &(Map.put(&1, "members", []) |> Map.update("gaps", [], fn gaps -> Enum.take(gaps, 32) end)))

    retained =
      Enum.reduce(artifacts, base, fn artifact, all ->
        Enum.reduce(artifact["members"] || [], all, fn member, current ->
          candidate = Enum.map(current, fn item -> if item["job_id"] == artifact["job_id"], do: Map.update!(item, "members", &(&1 ++ [member])), else: item end)

          if byte_size(Jason.encode!(%{"artifacts" => candidate, "content_members" => []})) <= 240_000,
            do: candidate,
            else: Enum.map(current, fn item -> if item["job_id"] == artifact["job_id"], do: item |> Map.put("status", "PARTIAL") |> Map.put("supplement_budget_gap", true), else: item end)
        end)
      end)

    with {:ok, content, _} <- evidence_content(retained, project, jobs),
         evidence = %{"artifacts" => retained, "content_members" => content},
         true <- byte_size(Jason.encode!(evidence)) <= 262_144 do
      {:ok, evidence}
    else
      _ -> {:error, :ci_successor_complete_evidence_unavailable}
    end
  end

  @doc "Authenticates the complete journal, SOURCE transfer, destination and APPLIED event; journal presence alone grants nothing."
  @spec applied(Store.connection(), String.t()) :: {:ok, map()} | {:error, atom()}
  def applied(store, key) do
    with {:ok, entry} <- journal(store, key),
         row = entry.row,
         old = entry.proof["prior_evidence"],
         old_access when is_map(old_access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [old["reservation_key"]]),
         destination when is_map(destination) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [row["new_request_key"]]),
         new_access when is_map(new_access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [row["new_reservation_key"]]),
         true <- is_binary(old_access["released_at"]) and new_access["generation"] > old_access["generation"],
         {:ok, transfer} <- Jason.decode(old_access["release_receipt_json"]),
         {:ok, disposition} <- Jason.decode(entry.proof["disposition_event"]["payload_json"]),
         true <- transfer == transfer_receipt(entry, destination, new_access, disposition),
         true <- Map.take(old_access, ~w(run_id task_key canonical_path git_dir common_dir)) == Map.take(new_access, ~w(run_id task_key canonical_path git_dir common_dir)),
         true <- new_access["mode"] == "SOURCE" and new_access["request_key"] == destination["request_key"] and destination["reservation_key"] == new_access["reservation_key"],
         {:ok, old_binding} <- object(old["binding_json"], old["binding_sha256"]),
         {:ok, new_binding} <- object(destination["binding_json"], destination["binding_sha256"]),
         fields = ~w(run_id task_key role stage mode model reasoning_effort schema policy contract_sha256 spec_revision expected_sha base_sha),
         true <- Map.take(old_binding, fields) == Map.take(new_binding, fields),
         true <- new_binding["reservation_key"] == new_access["reservation_key"] and new_binding["reservation_generation"] == new_access["generation"],
         true <- destination_owner?(destination, old),
         [event] <-
           Store.query!(store, "SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_CI_REPAIR_SUCCESSOR_APPLIED' AND json_extract(payload_json,'$.successor_key')=?", [
             row["run_id"],
             key
           ]).rows,
         {:ok, payload} <- Jason.decode(hd(event)),
         true <- payload == applied_receipt(entry, destination, new_access) do
      {:ok, Map.merge(entry, %{destination: destination, access: new_access, transfer: transfer})}
    else
      _ -> {:error, :ci_successor_applied_unproven}
    end
  rescue
    _ -> {:error, :ci_successor_applied_unproven}
  end

  defp destination_owner?(%{"thread_id" => nil, "policy_json" => nil, "status" => status}, _old), do: status in ~w(RESERVED START_SENT)
  defp destination_owner?(destination, old), do: destination["thread_id"] == old["thread_id"] and destination["policy_json"] == old["policy_json"]

  defp transfer_receipt(entry, destination, access, disposition) do
    %{
      "kind" => "CI_EVIDENCE_SUCCESSOR_TRANSFER_V1",
      "ci_evidence_successor_key" => entry.row["successor_key"],
      "old_request_key" => entry.row["prior_request_key"],
      "old_reservation_key" => entry.proof["prior_access"]["reservation_key"],
      "new_request_key" => destination["request_key"],
      "new_reservation_key" => access["reservation_key"],
      "new_generation" => access["generation"],
      "disposition_key" => disposition["disposition_key"],
      "output_sha256" => entry.proof["prior_evidence"]["output_sha256"],
      "checkout_head_sha" => entry.proof["run"]["candidate_sha"]
    }
  end

  defp applied_receipt(entry, destination, access) do
    %{
      "kind" => "CI_EVIDENCE_SUCCESSOR_APPLIED_V1",
      "successor_key" => entry.row["successor_key"],
      "prior_request_key" => entry.row["prior_request_key"],
      "new_request_key" => destination["request_key"],
      "new_reservation_key" => access["reservation_key"],
      "new_generation" => access["generation"],
      "new_binding_sha256" => destination["binding_sha256"],
      "proof_sha256" => entry.row["proof_sha256"],
      "evidence_sha256" => entry.row["evidence_sha256"],
      "attempt_index" => entry.row["attempt_index"],
      "accepted_outcome_sha256" => digest(Jason.encode!(entry.proof["accepted_outcome"]))
    }
  end

  @spec superseded?(Store.connection(), map()) :: boolean()
  def superseded?(store, evidence) do
    case Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE prior_request_key=?", [evidence["request_key"]]) do
      %{"successor_key" => key} ->
        case applied(store, key) do
          {:ok, entry} -> entry.proof["prior_evidence"] == evidence
          _ -> false
        end

      _ ->
        false
    end
  end

  @spec supplemental_packet(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def supplemental_packet(store, run, packet) do
    claim_key = get_in(packet, ["ci_repair", "claim_key"])

    case Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE run_id=? AND claim_key=? ORDER BY attempt_index DESC LIMIT 1", [run["run_id"], claim_key]) do
      nil ->
        {:ok, packet}

      %{"successor_key" => key} ->
        with {:ok, entry} <- applied(store, key),
             true <- entry.row["claim_key"] == claim_key and entry.proof["run"]["code_repair_round"] == run["code_repair_round"] do
          {:ok, packet |> Map.put("ci_evidence_successor", packet_binding(entry.row)) |> Map.put("ci_evidence_successor_evidence", entry.evidence) |> extend_packet(entry.proof["policy_receipt"])}
        else
          _ -> {:error, :ci_successor_packet_unproven}
        end
    end
  end

  @spec resume_matches?(Store.connection(), map(), keyword()) :: boolean()
  def resume_matches?(store, previous, opts) do
    case Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE prior_request_key=? AND new_request_key=?", [previous["request_key"], opts[:request_key]]) do
      %{"successor_key" => key} ->
        case applied(store, key) do
          {:ok, entry} -> entry.proof["prior_evidence"] == previous and entry.destination["reservation_key"] == opts[:reservation_key]
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "Checks current CI policy and capacity again immediately before a retained-history writer sends its turn."
  @spec issuance_check(Store.connection(), map(), keyword()) :: :ok | {:error, term()}
  def issuance_check(store, %{"state" => "REPAIRING"} = run, opts) do
    with {:ok, scope} <- TicketCiRepair.writer_scope(store, run) do
      if is_map(scope) and Store.one!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE run_id=? LIMIT 1", [run["run_id"]]) do
        check_ci_issuance(store, run, opts)
      else
        :ok
      end
    end
  end

  def issuance_check(_, _, _), do: :ok

  defp check_ci_issuance(store, run, opts) do
    with {:ok, receipt} <- policy_receipt(store, run),
         true <- attempts_used(store, run["run_id"]) <= receipt["effective_limit"] or {:error, :ci_repair_attempt_limit},
         :ok <- WorkspaceAccess.source_capacity(store, run, opts),
         :ok <- TicketWorkerRunner.validate_authorization(run, opts[:authorization]),
         {:ok, _} <- TicketCiRepair.input_snapshot(store, run["run_id"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_issuance_unproven}
    end
  end

  @doc "Records an exhausted stopped attempt without consuming its result, transferring SOURCE, or spending another attempt."
  @spec record_exhaustion(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_exhaustion(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def record_exhaustion(store, request, authorization, opts) do
    with {:ok, prior} <- WorkerEvidence.get(store, request),
         {:ok, run} <- RunLedger.get(store, prior["run_id"]),
         true <- eligible?(store, run, request),
         {:ok, policy} <- policy_receipt(store, run),
         used = attempts_used(store, run["run_id"]),
         true <- used >= policy["effective_limit"],
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, run["run_id"]),
         {:ok, task} <- TaskLedger.get(store, prior["task_key"]),
         {:ok, binding} <- object(prior["binding_json"], prior["binding_sha256"]),
         :ok <- instruction_claim(store, task, binding, run),
         {:ok, stop} <- Jason.decode(prior["owner_stop_json"]),
         true <- stop["exit_status"] == 0 and is_binary(stop["pid"]) and Regex.match?(~r/\A[1-9][0-9]*\z/, stop["pid"]),
         {:ok, native} <- native_observation(task, binding, opts),
         {:ok, access} <- WorkspaceAccess.get(store, prior["reservation_key"]),
         {:ok, event} <- exhaustion_event(store, run, prior, task, access),
         {:ok, root} when is_binary(root) <- Keyword.fetch(opts, :workspace_root),
         {:ok, _source} <- WorkspaceAccess.prepare_ci_successor_source(store, run, access, root),
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts) do
      message =
        "CI repair budget exhausted: #{used} total attempts used; configured limit #{policy["effective_limit"]} (hard maximum 10). Repair round #{run["code_repair_round"]}, failed pipeline #{run["ci_pipeline_id"]}, stopped request #{request}. No new writer, push, or retry was issued."

      case Exqlite.transaction(store, fn tx ->
             with {:ok, ^run} <- RunLedger.get(tx, run["run_id"]),
                  {:ok, ^prior} <- WorkerEvidence.get(tx, request),
                  {:ok, ^task} <- TaskLedger.get(tx, task["task_key"]),
                  {:ok, ^access} <- WorkspaceAccess.get(tx, access["reservation_key"]),
                  true <- Store.one!(tx, "SELECT * FROM events WHERE id=?", [event["id"]]) == event,
                  true <- eligible?(tx, run, request) and attempts_used(tx, run["run_id"]) == used,
                  {:ok, ^inputs} <- TicketCiRepair.input_snapshot(tx, run["run_id"]),
                  {:ok, ^tick} <- TicketPushRecovery.tick_binding(tx, opts),
                  :ok <- TicketWorkerRunner.validate_authorization(run, authorization),
                  :ok <- TicketMrGuard.native_receipt(native.request, native.receipt, DateTime.utc_now()),
                  :ok <- recheck_push_policy(store, Map.put(run, "state", "CI_PUSHING"), policy),
                  true <- policy_file_current?(policy) do
               if run["failure_code"] == "CI_REPAIR_EXHAUSTED" and run["last_error"] == message do
                 run
               else
                 {:ok, %{run: updated}} = RunLedger.update(tx, run["run_id"], %{failure_code: "CI_REPAIR_EXHAUSTED", last_error: message})
                 updated
               end
             else
               _ -> Exqlite.rollback(tx, :ci_successor_exhaustion_changed)
             end
           end) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_exhaustion_unproven}
    end
  end

  defp exhaustion_event(store, run, prior, task, access) do
    event =
      Store.one!(store, "SELECT * FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_WRITER_BLOCKED' AND json_extract(payload_json,'$.request_key')=?", [run["run_id"], prior["request_key"]])

    expected = %{
      "request_key" => prior["request_key"],
      "task_key" => task["task_key"],
      "output_json" => prior["output_json"],
      "output_sha256" => prior["output_sha256"],
      "reservation_key" => access["reservation_key"],
      "reservation_generation" => access["generation"],
      "task_status" => "COMPLETE",
      "task" => Map.take(task, ~w(task_key role stage status thread_id turn_id updated_at)),
      "run_binding" => Map.take(run, ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch))
    }

    with true <- is_map(event),
         {:ok, payload} <- Jason.decode(event["payload_json"]),
         true <- Map.take(payload, Map.keys(expected)) == expected do
      {:ok, event}
    else
      _ -> {:error, :ci_successor_exhaustion_event_unproven}
    end
  end

  @spec policy_receipt(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def policy_receipt(store, run), do: policy_receipt(store, run, :repair)

  defp delivery_policy_receipt(store, run, opts) do
    with {:ok, receipt} <- policy_receipt(store, run, :delivery),
         {:ok, cached} <- Controller.cached_generation_policy(store, run["repo_key"]),
         project when is_integer(project) and project > 0 <- rollover_project(get_in(cached, ["route", "gitlab_project_id"])),
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         true <- tick["scope"] == cached["scope"] and tick["dispatcher_id"] == cached["dispatcher_id"] do
      {:ok, %{receipt: Map.put(receipt, "control", tick), project_id: project}}
    else
      _ -> {:error, :verified_ci_rollover_policy_unproven}
    end
  end

  defp rollover_project(value) when is_integer(value), do: value

  defp rollover_project(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp rollover_project(_), do: nil

  defp policy_receipt(store, run, mode) do
    with {:ok, cached} <- Controller.cached_generation_policy(store, run["repo_key"]),
         true <- cached["enabled"] == true and cached["ticket_supervisor_enabled"] == true and (mode == :delivery or cached["ci_repair"] == "native_bounded_v1"),
         true <- Policy.ticket_selected?(cached["ticket_selection"], run["issue_key"]),
         {:ok, path} <- PathSafety.canonicalize(Workflow.workflow_file_path()),
         true <- path == Path.expand(Workflow.workflow_file_path()) and not inside_source?(path, run["worktree"]),
         {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :regular and stat.links == 1 and stat.size in 1..262_144 and Bitwise.band(stat.mode, 0o022) == 0,
         {uid, 0} <- System.cmd("/usr/bin/id", ["-u"]),
         true <- to_string(stat.uid) == String.trim(uid),
         {:ok, raw} <- File.read(path),
         {:ok, workflow} <- Workflow.parse_content(raw),
         {:ok, settings} <- Schema.parse(workflow.config),
         true <- factory_matches?(settings.factory, cached, mode),
         true <- Path.expand(cached["route"]["path"]) == Path.expand(run["repo_path"]),
         cap = if(mode == :delivery, do: 0, else: cached["maximum_code_repair_rounds"]),
         true <- mode == :delivery or (is_integer(cap) and cap > 0),
         {:ok, ^raw} <- File.read(path),
         {:ok, after_read} <- File.lstat(path, time: :posix),
         true <- after_read.type == :regular and after_read.links == 1 and workflow_stat(after_read) == workflow_stat(stat),
         {:ok, extension} <- configured_scope_extension(store, run, settings.factory, mode) do
      receipt = %{
        "version" => 3,
        "kind" => "CI_REPAIR_POLICY_V3",
        "workflow_path" => path,
        "workflow_sha256" => digest(raw),
        "workflow_stat" => workflow_stat(stat),
        "configured_limit" => cap,
        "effective_limit" => min(cap, 10),
        "scope_extension" => extension,
        "scope" => cached["scope"],
        "dispatcher_id" => cached["dispatcher_id"],
        "repo_key" => run["repo_key"],
        "cached_policy_sha256" => digest(Jason.encode!(cached))
      }

      receipt =
        if mode == :delivery, do: receipt |> Map.drop(~w(configured_limit effective_limit scope_extension)) |> Map.put("version", 1) |> Map.put("kind", "VERIFIED_CI_DELIVERY_POLICY_V1"), else: receipt

      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_current_policy_unproven}
    end
  end

  defp factory_matches?(factory, cached, mode) do
    supervisor = factory.ticket_supervisor

    factory.enabled == cached["enabled"] and factory.scope == cached["scope"] and factory.dispatcher_id == cached["dispatcher_id"] and
      (mode == :delivery or factory.maximum_code_repair_rounds == cached["maximum_code_repair_rounds"]) and
      factory.ci_repair_scope_extensions == (cached["ci_repair_scope_extensions"] || %{}) and
      Map.take(supervisor, ~w(enabled all_eligible_tickets pilot_issue_keys)) == cached["ticket_selection"] and
      (mode == :delivery or supervisor["ci_repair"] == cached["ci_repair"]) and
      Map.take(factory.repositories[cached["repo_key"]] || %{}, ~w(path base_branch gitlab_project gitlab_project_id)) == cached["route"]
  end

  defp inside_source?(path, source), do: path == Path.expand(source) or String.starts_with?(path, Path.expand(source) <> "/")

  defp configured_scope_extension(_store, _run, _factory, :delivery), do: {:ok, nil}

  defp configured_scope_extension(store, run, factory, :repair) do
    extension = Map.get(factory.ci_repair_scope_extensions, run["run_id"])
    claim = Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]])

    cond do
      is_nil(extension) ->
        {:ok, nil}

      is_map(extension) and is_map(claim) and extension["claim_key"] != claim["claim_key"] ->
        {:ok, nil}

      true ->
        with :ok <- validate_scope_extension(extension, run, claim), do: {:ok, extension}
    end
  end

  @doc "Validates an explicit operator-policy source capability without changing the original repair claim."
  @spec validate_scope_extension(term(), map(), map() | nil) :: :ok | {:error, atom()}
  def validate_scope_extension(nil, _run, _claim), do: :ok

  def validate_scope_extension(extension, run, claim) when is_map(extension) and is_map(claim) do
    keys = ~w(version run_id issue_key repo_key project_id claim_key claim_sha256 failed_candidate_sha spec_revision contract_sha256 allowed_writer_paths authorization_reference)

    with true <- Enum.sort(Map.keys(extension)) == Enum.sort(keys) and extension["version"] === 1,
         true <- is_integer(extension["project_id"]) and extension["project_id"] > 0 and is_integer(extension["spec_revision"]),
         {:ok, scope} <- push_object(claim["claim_json"], claim["claim_sha256"], :claim),
         true <- Map.take(extension, ~w(run_id issue_key repo_key spec_revision contract_sha256)) == Map.take(run, ~w(run_id issue_key repo_key spec_revision contract_sha256)),
         true <- extension["claim_key"] == claim["claim_key"] and extension["claim_sha256"] == claim["claim_sha256"],
         true <- extension["failed_candidate_sha"] == get_in(scope, ["prior_run", "candidate_sha"]),
         true <- extension["project_id"] == get_in(scope, ["ci_snapshots", "mr", "project_id"]),
         paths when is_list(paths) <- extension["allowed_writer_paths"],
         true <- length(paths) == 2 and paths == Enum.sort(Enum.uniq(paths)),
         true <- Enum.all?(paths, &operator_source_path?/1),
         reference when is_binary(reference) <- extension["authorization_reference"],
         true <- String.valid?(reference) and byte_size(reference) in 1..1024 do
      :ok
    else
      _ -> {:error, :ci_scope_extension_unproven}
    end
  end

  def validate_scope_extension(_, _, _), do: {:error, :ci_scope_extension_unproven}

  defp operator_source_path?(path) when is_binary(path) do
    TicketCiRepair.source_path?(path) and Path.extname(path) == ".go" and not Regex.match?(~r/[\*\?\[\]\{\}]/, path)
  end

  defp operator_source_path?(_), do: false

  defp extend_packet(packet, %{"version" => version, "scope_extension" => extension} = receipt) when version in [2, 3] and is_map(extension) do
    packet
    |> Map.put("ci_repair_scope_extension", receipt)
    |> update_in(["ci_repair", "allowed_writer_paths"], &Enum.sort(Enum.uniq(&1 ++ extension["allowed_writer_paths"])))
  end

  defp extend_packet(packet, _receipt), do: Map.delete(packet, "ci_repair_scope_extension")

  defp current_packet_scope(store, %{"ci_repair_scope_extension" => captured}, run) do
    with {:ok, ^captured} <- policy_receipt(store, run), do: :ok
  end

  defp current_packet_scope(_store, _packet, _run), do: :ok

  defp captured_packet_extension(store, packet, run) do
    case packet["ci_repair_scope_extension"] do
      nil ->
        {:ok, []}

      %{"version" => version, "scope_extension" => extension} = receipt when version in [2, 3] and is_map(extension) ->
        with key when is_binary(key) <- get_in(packet, ["ci_evidence_successor", "successor_key"]),
             row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_ci_repair_evidence_successors WHERE successor_key=?", [key]),
             {:ok, proof} <- push_object(row["proof_json"], row["proof_sha256"], :successor),
             true <- proof["policy_receipt"] == receipt and packet["ci_evidence_successor"] == packet_binding(row),
             true <- row["run_id"] == run["run_id"] and row["claim_key"] == get_in(packet, ["ci_repair", "claim_key"]),
             true <- proof["run"]["code_repair_round"] == run["code_repair_round"],
             :ok <- archived_policy(receipt, proof),
             :ok <- validate_scope_extension(extension, run, proof["claim"]) do
          {:ok, extension["allowed_writer_paths"]}
        else
          _ -> {:error, :ci_scope_extension_unproven}
        end

      _ ->
        {:error, :ci_scope_extension_unproven}
    end
  end

  @doc "Returns extra paths only for the current instruction packet and its applied successor, never a stopped predecessor."
  @spec active_scope_paths(Store.connection(), map(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def active_scope_paths(store, run, request) do
    task = Store.one!(store, "SELECT * FROM factory_tasks WHERE run_id=? AND role='feature-writer'", [run["run_id"]])

    with true <- is_map(task),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         {:ok, packet} <- object(snapshot["binding_json"], mapping["instruction_binding_sha256"]),
         :ok <- scope_request_matches(store, request, task, mapping),
         {:ok, paths} <- captured_packet_extension(store, packet, run) do
      if paths == [] do
        {:ok, []}
      else
        with {:ok, entry} <- applied(store, packet["ci_evidence_successor"]["successor_key"]),
             true <- entry.row["claim_key"] == packet["ci_repair"]["claim_key"],
             {:ok, current} <- policy_receipt(store, run),
             true <- current == packet["ci_repair_scope_extension"] do
          {:ok, paths}
        else
          _ -> {:error, :ci_scope_extension_unproven}
        end
      end
    else
      false -> {:ok, []}
      {:error, :worker_instruction_task_binding_unproven} -> {:ok, []}
      _ -> {:error, :ci_scope_extension_unproven}
    end
  end

  defp scope_request_matches(_store, nil, _task, _mapping), do: :ok

  defp scope_request_matches(store, request, task, mapping) do
    with {:ok, evidence} <- WorkerEvidence.get(store, request),
         {:ok, binding} <- object(evidence["binding_json"], evidence["binding_sha256"]),
         true <- evidence["task_key"] == task["task_key"] and binding["input_sha256"] == mapping["prompt_sha256"] do
      :ok
    else
      _ -> {:error, :ci_scope_extension_request_changed}
    end
  end

  defp workflow_stat(stat),
    do: %{"inode" => stat.inode, "device" => stat.major_device, "rdev" => stat.minor_device, "size" => stat.size, "mtime_seconds" => stat.mtime, "uid" => stat.uid, "mode" => stat.mode}

  @spec attempts_used(Store.connection(), String.t()) :: non_neg_integer()
  def attempts_used(store, run_id) do
    Store.one!(store, "SELECT (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=?) + (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=?) AS used", [run_id, run_id])[
      "used"
    ]
  end

  @spec journal(Store.connection(), String.t()) :: {:ok, map()} | {:error, atom()}
  def journal(store, key) do
    journal(store, key, [])
  rescue
    _ -> {:error, :ci_successor_journal_unproven}
  end

  @spec journal(Store.connection(), String.t(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  defp journal(store, key, seen) do
    with true <- is_binary(key) and length(seen) < 10 and key not in seen,
         row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_ci_repair_evidence_successors WHERE successor_key=?", [key]),
         {:ok, proof} <- push_object(row["proof_json"], row["proof_sha256"], :successor),
         {:ok, evidence} <- object(row["evidence_json"], row["evidence_sha256"]),
         :ok <- journal_identity(store, row, proof, evidence),
         {:ok, ancestors} <- journal_ancestors(store, row, [key | seen]),
         :ok <- content_newness(store, row, proof, evidence, ancestors) do
      {:ok, %{row: row, proof: proof, evidence: evidence, ancestors: ancestors}}
    else
      _ -> {:error, :ci_successor_journal_unproven}
    end
  end

  defp journal_identity(store, row, proof, evidence) do
    prior = proof["prior_evidence"]
    claim = proof["claim"]
    run = proof["run"]

    with true <-
           Enum.sort(Map.keys(proof)) ==
             Enum.sort(
               ~w(version kind run claim prior_evidence prior_task prior_access disposition_event accepted_outcome inputs source_observation authorization ci_snapshots content_members previous_content_sha256 total_before configured_limit policy_receipt admitted_at)
             ),
         true <- proof["version"] == 1 and proof["kind"] == "CI_EVIDENCE_SUCCESSOR_V1",
         true <- Enum.all?([prior, claim, run, proof["prior_task"], proof["prior_access"]], &is_map/1),
         true <- row["successor_key"] == successor_key(row["claim_key"], row["prior_request_key"], row["evidence_content_sha256"]),
         true <- row["run_id"] == run["run_id"] and run["state"] == "REPAIRING" and row["claim_key"] == claim["claim_key"],
         true <- row["configured_limit"] == proof["configured_limit"] and row["attempt_index"] == proof["total_before"] + 1,
         true <- row["created_at"] == proof["admitted_at"],
         true <- row["attempt_index"] <= row["configured_limit"] and row["configured_limit"] in 1..10,
         true <- Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?", [row["claim_key"]]) == claim,
         {:ok, body} <- push_object(claim["claim_json"], claim["claim_sha256"], :claim),
         true <- body["kind"] == "TICKET_CI_REPAIR" and body["round"] == claim["round"] and claim["round"] == run["code_repair_round"],
         true <- same_claim_run?(body["prior_run"], run) or {:error, :ci_successor_claim_run_changed},
         {:ok, observed_identity} <- snapshot_identity(proof["ci_snapshots"]),
         {:ok, claimed_identity} <- snapshot_identity(body["ci_snapshots"]),
         true <- claimed_identity == observed_identity or {:error, :ci_successor_snapshot_identity_changed},
         true <-
           (get_in(observed_identity, ["mr", "sha"]) == run["candidate_sha"] and get_in(observed_identity, ["pipeline", "sha"]) == run["candidate_sha"]) or
             {:error, :ci_successor_snapshot_candidate_changed},
         :ok <- archived_admission(store, proof),
         true <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [row["prior_request_key"]]) == prior,
         :ok <- blocked_evidence(store, proof, row),
         :ok <- accepted_outcome(store, proof, row),
         :ok <- journal_content(row, proof, evidence) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_journal_unproven}
    end
  end

  defp same_claim_run?(prior, run) when is_map(prior) do
    fields = ~w(run_id candidate_sha ci_pipeline_id repo_key repo_path worktree branch base_branch spec_revision contract_sha256)
    Map.take(prior, fields) == Map.take(run, fields)
  end

  defp same_claim_run?(_, _), do: false

  defp blocked_evidence(store, proof, row) do
    prior = proof["prior_evidence"]
    task = proof["prior_task"]
    access = proof["prior_access"]
    observed = Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [prior["reservation_key"]])

    with {:ok, output} <- object(prior["output_json"], prior["output_sha256"]),
         {:ok, binding} <- object(prior["binding_json"], prior["binding_sha256"]),
         true <- prior["status"] == "RESULT_RECORDED" and output["status"] == "BLOCKED" and output["changed_paths"] == [],
         true <- WorkerEvidence.owner_stopped?(store, prior),
         {:ok, stop} <- Jason.decode(prior["owner_stop_json"]),
         true <- stop["exit_status"] == 0 and is_binary(stop["pid"]) and Regex.match?(~r/\A[1-9][0-9]*\z/, stop["pid"]),
         true <- task["status"] == "COMPLETE" and task["role"] == "feature-writer" and task["stage"] == "REPAIRING",
         true <- Map.take(task, ~w(thread_id turn_id output_json)) == Map.take(prior, ~w(thread_id turn_id output_json)),
         true <- task["task_key"] == prior["task_key"] and task["prompt_sha256"] == binding["input_sha256"],
         true <- Map.take(binding, ~w(run_id spec_revision contract_sha256)) == Map.take(proof["run"], ~w(run_id spec_revision contract_sha256)),
         true <- binding["stage"] == "REPAIRING" and binding["role"] == "feature-writer" and binding["mode"] == "SOURCE",
         true <- binding["reservation_key"] == access["reservation_key"] and binding["reservation_generation"] == access["generation"],
         :ok <- instruction_claim(store, task, binding, proof["run"]),
         true <- prior["run_id"] == row["run_id"] and access["request_key"] == row["prior_request_key"],
         true <- access["mode"] == "SOURCE" and is_nil(access["released_at"]) and is_nil(access["release_receipt_json"]),
         true <- is_map(observed) and Map.drop(observed, ~w(released_at release_receipt_json)) == Map.drop(access, ~w(released_at release_receipt_json)),
         true <- proof["source_observation"] == %{"canonical_path" => access["canonical_path"], "head_sha" => proof["run"]["candidate_sha"], "dirty_paths" => []},
         true <- get_in(binding, ["policy", "cwd"]) == access["canonical_path"] and binding["expected_sha"] == proof["run"]["candidate_sha"] do
      :ok
    else
      _ -> {:error, :ci_successor_blocked_evidence_changed}
    end
  end

  defp instruction_claim(store, task, binding, run) do
    with {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         {:ok, packet} <- object(snapshot["binding_json"], mapping["instruction_binding_sha256"]),
         true <- snapshot["run_id"] == run["run_id"] and snapshot["role"] == "ci-repair-writer",
         {:ok, _bundle} <- WorkerInstructions.read(store, packet, "ci-repair-writer"),
         true <- packet["stage"] == "REPAIRING" and packet["role"] == "feature-writer",
         true <- packet["code_repair_round"] == run["code_repair_round"],
         true <- mapping["prompt_sha256"] == binding["input_sha256"] and mapping["prompt_sha256"] == task["prompt_sha256"],
         true <- Map.take(packet, ~w(run_id spec_revision contract_sha256 candidate_sha)) == Map.take(run, ~w(run_id spec_revision contract_sha256 candidate_sha)),
         {:ok, expected} when is_map(expected) <- TicketCiRepair.writer_packet(store, run),
         {:ok, paths} <- captured_packet_extension(store, packet, run),
         true <- packet["ci_repair"]["allowed_writer_paths"] == Enum.sort(Enum.uniq(expected["allowed_writer_paths"] ++ paths)),
         true <-
           Map.take(packet["ci_repair"] || %{}, ~w(claim_key failed_candidate_sha required_generated_paths diagnosis)) ==
             Map.take(expected, ~w(claim_key failed_candidate_sha required_generated_paths diagnosis)) do
      :ok
    else
      _ -> {:error, :ci_successor_instruction_claim_unproven}
    end
  end

  defp archived_admission(store, proof) do
    run = proof["run"]
    auth = proof["authorization"]
    inputs = proof["inputs"]

    with true <- is_map(auth) and Enum.sort(Map.keys(auth)) == Enum.sort(~w(run_id issue_key spec_revision contract_sha256 snapshot_json observed_at)),
         {:ok, observed, _} <- DateTime.from_iso8601(auth["observed_at"]),
         {:ok, admitted, _} <- DateTime.from_iso8601(proof["admitted_at"]),
         true <- DateTime.diff(admitted, observed, :second) in -5..60,
         {:ok, snapshot} when is_map(snapshot) <- Jason.decode(auth["snapshot_json"]),
         {:ok, ^auth} <- TicketWorkerRunner.authorization(run, snapshot, observed),
         :ok <- validate_archived_inputs(store, run, inputs) do
      archived_policy(proof["policy_receipt"], proof)
    else
      _ -> {:error, :ci_successor_archived_admission_unproven}
    end
  end

  @doc "Validates historical input snapshot shape and admission eligibility without comparing it to later human state."
  @spec validate_archived_inputs(Store.connection(), map(), map()) :: :ok | {:error, atom()}
  def validate_archived_inputs(store, run, inputs) when is_map(inputs) do
    with true <- Enum.sort(Map.keys(inputs)) == Enum.sort(~w(ticket_chat_commands ticket_chat_questions ticket_contract_amendments parent bootstrap inputs)),
         {:ok, parent} <- archived_map(store, "ticket_chats", inputs["parent"]),
         {:ok, bootstrap} <- archived_map(store, "desktop_requests", inputs["bootstrap"]),
         true <- parent["issue_key"] == run["issue_key"] and parent["repo_key"] == run["repo_key"],
         true <- parent["create_request_key"] == bootstrap["request_key"] and bootstrap["target_key"] == parent["chat_key"] and bootstrap["target_kind"] == "TICKET_CHAT",
         true <- bootstrap["status"] == "SUCCEEDED" and bootstrap["thread_id"] == parent["thread_id"] and is_binary(parent["thread_id"]),
         %{"chat_key" => chat_key} <- Store.one!(store, "SELECT chat_key FROM ticket_chat_runs WHERE run_id=?", [run["run_id"]]),
         true <- chat_key == parent["chat_key"],
         {:ok, commands} <- archived_rows(store, "ticket_chat_commands", inputs["ticket_chat_commands"]),
         {:ok, questions} <- archived_rows(store, "ticket_chat_questions", inputs["ticket_chat_questions"]),
         {:ok, amendments} <- archived_rows(store, "ticket_contract_amendments", inputs["ticket_contract_amendments"]),
         {:ok, native_inputs} <- archived_rows(store, "ticket_chat_inputs", inputs["inputs"]),
         true <- Enum.all?(commands ++ questions ++ amendments, &(&1["run_id"] == run["run_id"] and &1["chat_key"] == chat_key)),
         true <- Enum.all?(native_inputs, &(&1["chat_key"] == chat_key)),
         true <-
           Enum.all?(commands, &(&1["status"] in ~w(APPLIED REJECTED))) and Enum.all?(questions, &(&1["status"] in ~w(ANSWERED INVALIDATED))) and Enum.all?(amendments, &(&1["active_owner"] == 0)) do
      :ok
    else
      _ -> {:error, :ci_successor_archived_inputs_unproven}
    end
  rescue
    _ -> {:error, :ci_successor_archived_inputs_unproven}
  end

  def validate_archived_inputs(_, _, _), do: {:error, :ci_successor_archived_inputs_unproven}

  defp archived_map(store, table, row) when is_map(row) do
    columns = Store.query!(store, "PRAGMA table_info(#{table})").rows
    names = Enum.map(columns, &Enum.at(&1, 1))

    if Enum.sort(Map.keys(row)) == Enum.sort(names) and valid_sql_values?(columns, Enum.map(names, &row[&1])),
      do: {:ok, row},
      else: {:error, :ci_successor_archived_inputs_unproven}
  end

  defp archived_map(_, _, _), do: {:error, :ci_successor_archived_inputs_unproven}

  defp archived_rows(store, table, rows) when is_list(rows) and length(rows) <= 10_000 do
    columns = Store.query!(store, "PRAGMA table_info(#{table})").rows
    names = Enum.map(columns, &Enum.at(&1, 1))

    if Enum.all?(rows, &(is_list(&1) and length(&1) == length(columns) and valid_sql_values?(columns, &1))) and length(Enum.uniq_by(rows, &hd/1)) == length(rows),
      do: {:ok, Enum.map(rows, &Map.new(Enum.zip(names, &1)))},
      else: {:error, :ci_successor_archived_inputs_unproven}
  end

  defp archived_rows(_, _, _), do: {:error, :ci_successor_archived_inputs_unproven}

  defp valid_sql_values?(columns, values) do
    Enum.zip(columns, values)
    |> Enum.all?(fn {[_cid, _name, type, required | _], value} ->
      cond do
        is_nil(value) -> required == 0
        type == "INTEGER" -> is_integer(value)
        type == "REAL" -> is_number(value)
        type == "TEXT" -> is_binary(value) and String.valid?(value)
        true -> false
      end
    end)
  end

  defp archived_policy(receipt, proof) when is_map(receipt) do
    keys = ~w(version kind workflow_path workflow_sha256 workflow_stat configured_limit effective_limit scope dispatcher_id repo_key cached_policy_sha256)
    keys = if receipt["version"] in [2, 3], do: ["scope_extension" | keys], else: keys
    stat_keys = ~w(inode device rdev size mtime_seconds uid mode)

    with true <- Enum.sort(Map.keys(receipt)) == Enum.sort(keys),
         true <- {receipt["version"], receipt["kind"]} in [{1, "CI_REPAIR_POLICY_V1"}, {2, "CI_REPAIR_POLICY_V2"}, {3, "CI_REPAIR_POLICY_V3"}],
         true <-
           is_integer(receipt["configured_limit"]) and receipt["configured_limit"] > 0 and receipt["effective_limit"] == proof["configured_limit"] and
             receipt["effective_limit"] == min(receipt["configured_limit"], %{1 => 5, 2 => 7, 3 => 10}[receipt["version"]]),
         :ok <- validate_scope_extension(receipt["scope_extension"], proof["run"], proof["claim"]),
         true <- receipt["repo_key"] == proof["run"]["repo_key"],
         true <- Enum.all?(~w(scope dispatcher_id workflow_path), &(is_binary(receipt[&1]) and receipt[&1] != "")),
         true <- Enum.all?(~w(workflow_sha256 cached_policy_sha256), &hex?(receipt[&1])),
         stat when is_map(stat) <- receipt["workflow_stat"],
         true <- Enum.sort(Map.keys(stat)) == Enum.sort(stat_keys) and Enum.all?(stat_keys, &is_integer(stat[&1])),
         true <- stat["size"] in 1..262_144 and Bitwise.band(stat["mode"], 0o170022) == 0o100000,
         true <- Path.type(receipt["workflow_path"]) == :absolute and not inside_source?(receipt["workflow_path"], proof["run"]["worktree"]) do
      :ok
    else
      _ -> {:error, :ci_successor_archived_policy_unproven}
    end
  end

  defp archived_policy(_, _), do: {:error, :ci_successor_archived_policy_unproven}

  @doc "Normalizes only immutable CI identities; collection timestamps never change evidence ancestry."
  @spec snapshot_identity(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot_identity(%{"mr" => mr, "pipeline" => pipeline, "jobs" => jobs}) when is_map(mr) and is_map(pipeline) and is_list(jobs) and length(jobs) <= 100 do
    with true <- is_integer(mr["project_id"]) and mr["project_id"] > 0 and mr["reviewers"] == [],
         true <- Enum.all?(jobs, &(is_map(&1) and is_map(&1["pipeline"]) and is_integer(&1["id"]) and &1["id"] > 0)),
         true <- length(Enum.uniq_by(jobs, & &1["id"])) == length(jobs) do
      normalized_mr = Map.take(mr, ~w(project_id iid sha source_branch target_branch draft reviewers assignee force_remove_source_branch web_url))
      normalized_mr = if is_map(mr["assignee"]), do: Map.put(normalized_mr, "assignee", Map.take(mr["assignee"], ["id"])), else: normalized_mr
      normalized_jobs = Enum.map(jobs, &(Map.take(&1, ~w(id name status allow_failure web_url)) |> Map.put("pipeline", Map.take(&1["pipeline"], ~w(id project_id sha))))) |> Enum.sort_by(& &1["id"])
      {:ok, %{"mr" => normalized_mr, "pipeline" => Map.take(pipeline, ~w(id project_id sha ref source status web_url)), "jobs" => normalized_jobs}}
    else
      _ -> {:error, :ci_successor_snapshot_unproven}
    end
  end

  def snapshot_identity(_), do: {:error, :ci_successor_snapshot_unproven}

  defp accepted_outcome(store, proof, row) do
    event = proof["disposition_event"]
    prior = proof["prior_evidence"]

    with true <- is_map(event),
         true <- Store.one!(store, "SELECT * FROM events WHERE id=?", [event["id"]]) == event,
         true <- event["event_type"] == "TICKET_NATIVE_WRITER_BLOCKED" and event["run_id"] == row["run_id"],
         {:ok, disposition} <- Jason.decode(event["payload_json"]),
         true <- disposition["request_key"] == prior["request_key"] and disposition["output_json"] == prior["output_json"] and disposition["output_sha256"] == prior["output_sha256"],
         true <- disposition["reservation_key"] == prior["reservation_key"] and disposition["task_key"] == prior["task_key"],
         true <- disposition["reservation_generation"] == proof["prior_access"]["generation"],
         true <- disposition["disposition_key"] == digest(Jason.encode!([row["run_id"], row["prior_request_key"], prior["output_sha256"]])),
         true <- disposition["task"] == Map.take(proof["prior_task"], ~w(task_key role stage status thread_id turn_id updated_at)),
         true <- disposition["run_binding"] == Map.take(proof["run"], ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch)),
         true <- disposition["task_status"] == "COMPLETE",
         true <-
           proof["accepted_outcome"] == %{
             "kind" => "BLOCKED_NO_EDIT_ACCEPTED_V1",
             "event_id" => event["id"],
             "event_sha256" => digest(Jason.encode!(event)),
             "request_key" => prior["request_key"],
             "output_sha256" => prior["output_sha256"],
             "candidate_sha" => proof["run"]["candidate_sha"]
           } do
      :ok
    else
      _ -> {:error, :ci_successor_blocked_disposition_changed}
    end
  end

  defp journal_content(row, proof, evidence) do
    snapshots = proof["ci_snapshots"]
    project = get_in(snapshots, ["mr", "project_id"])
    jobs = for job <- snapshots["jobs"] || [], job["allow_failure"] == false and job["status"] in ~w(failed canceled canceling), do: job["id"]

    with true <- Enum.sort(Map.keys(evidence)) == ~w(artifacts content_members),
         {:ok, content, identity} <- evidence_content(evidence["artifacts"], project, jobs),
         true <- content == evidence["content_members"] and content == proof["content_members"] and identity == row["evidence_content_sha256"] do
      :ok
    else
      _ -> {:error, :ci_successor_complete_evidence_unavailable}
    end
  end

  @spec journal_ancestors(Store.connection(), map(), [String.t()]) :: {:ok, [map()]} | {:error, atom()}
  defp journal_ancestors(_store, %{"prior_successor_key" => nil}, _seen), do: {:ok, []}

  defp journal_ancestors(store, row, seen) do
    with {:ok, parent} <- journal(store, row["prior_successor_key"], seen),
         true <- parent.row["run_id"] == row["run_id"] and parent.row["claim_key"] == row["claim_key"] and parent.row["attempt_index"] < row["attempt_index"] do
      {:ok, parent.ancestors ++ [parent]}
    else
      _ -> {:error, :ci_successor_chain_unproven}
    end
  end

  defp content_newness(store, row, proof, evidence, ancestors) do
    claim = Jason.decode!(proof["claim"]["claim_json"])
    base = CiRepairReassessment.claimed(store, claim)
    project = get_in(proof, ["ci_snapshots", "mr", "project_id"])
    jobs = Enum.map(evidence["content_members"], & &1["job_id"])

    with :ok <- CiRepairReassessment.validate_claim(store, claim),
         true <- is_map(base),
         {:ok, diagnosis} <- object(base["diagnosis_json"], base["diagnosis_sha256"]),
         {:ok, preimage} <- push_object(base["preimage_json"], base["preimage_sha256"], :preimage),
         true <- same_claim_run?(preimage["run"], claim["prior_run"]),
         true <-
           Map.take(base, ~w(run_id candidate_sha pipeline_id)) == %{
             "run_id" => row["run_id"],
             "candidate_sha" => claim["prior_run"]["candidate_sha"],
             "pipeline_id" => claim["prior_run"]["ci_pipeline_id"]
           },
         artifacts when is_list(artifacts) <- diagnosis["artifacts"],
         {:ok, base_content} <- baseline_content(artifacts, project, jobs) do
      all_content = base_content ++ Enum.flat_map(ancestors, & &1.evidence["content_members"])
      previous = List.last(ancestors)
      previous_hash = if previous, do: previous.row["evidence_content_sha256"], else: if(base_content == [], do: nil, else: digest(Jason.encode!(base_content)))

      earlier =
        Store.query!(store, "SELECT successor_key FROM ticket_ci_repair_evidence_successors WHERE claim_key=? AND attempt_index<? ORDER BY attempt_index", [row["claim_key"], row["attempt_index"]]).rows
        |> List.flatten()

      if earlier == Enum.map(ancestors, & &1.row["successor_key"]) and proof["previous_content_sha256"] == previous_hash and new_content?(evidence["content_members"], all_content),
        do: :ok,
        else: {:error, :ci_successor_evidence_not_new}
    else
      _ -> {:error, :ci_successor_claimed_baseline_unproven}
    end
  end

  defp baseline_content(artifacts, project, jobs) do
    if Enum.all?(artifacts, &is_map/1) do
      case evidence_content(artifacts, project, jobs) do
        {:ok, content, _} ->
          {:ok, content}

        {:error, :ci_successor_complete_evidence_unavailable} ->
          if Enum.all?(artifacts, fn artifact -> is_list(artifact["members"]) and Enum.all?(artifact["members"], &(is_map(&1) and &1["complete"] != true)) end),
            do: {:ok, []},
            else: {:error, :ci_successor_claimed_baseline_unproven}
      end
    else
      {:error, :ci_successor_claimed_baseline_unproven}
    end
  end

  defp object(raw, expected) when is_binary(raw) and byte_size(raw) <= 2_097_152 and is_binary(expected) do
    with true <- digest(raw) == expected, {:ok, value} when is_map(value) <- Jason.decode(raw), do: {:ok, value}, else: (_ -> {:error, :ci_successor_json_changed})
  end

  defp object(_, _), do: {:error, :ci_successor_json_changed}

  defp push_object(raw, expected, kind) when is_binary(raw) and is_binary(expected) do
    with true <- digest(raw) == expected,
         {:ok, value} <- TicketPushPayloadBudget.object(raw, kind) do
      {:ok, value}
    else
      _ -> {:error, :ci_successor_json_changed}
    end
  end

  defp push_object(_raw, _expected, _kind), do: {:error, :ci_successor_json_changed}
  defp successor_key(claim, prior, content), do: "ci-evidence-successor:" <> digest(Jason.encode!([claim, prior, content]))

  @spec evidence_content([map()], pos_integer(), [pos_integer()]) :: {:ok, [map()], String.t()} | {:error, atom()}
  def evidence_content(artifacts, project, jobs) when is_list(artifacts) and length(artifacts) <= 100 and is_integer(project) and project > 0 and is_list(jobs) do
    content =
      artifacts
      |> Enum.filter(&bound_artifact?(&1, project, jobs))
      |> Enum.flat_map(fn artifact ->
        for member <- artifact["members"], complete_member?(member) do
          %{"project_id" => project, "job_id" => artifact["job_id"], "path" => member["path"], "member_sha256" => member["sha256"], "text_sha256" => digest(member["text"])}
        end
      end)
      |> Enum.sort_by(&{&1["job_id"], &1["path"]})

    if content != [] and length(content) <= 256 and Enum.uniq_by(content, &{&1["job_id"], &1["path"]}) == content,
      do: {:ok, content, digest(Jason.encode!(content))},
      else: {:error, :ci_successor_complete_evidence_unavailable}
  end

  def evidence_content(_, _, _), do: {:error, :ci_successor_complete_evidence_unavailable}

  @spec new_content?([map()], [map()]) :: boolean()
  def new_content?(current, prior) when is_list(current) and is_list(prior) do
    identities = fn members -> MapSet.new(members, &Map.take(&1, ~w(project_id job_id member_sha256 text_sha256))) end
    MapSet.size(MapSet.difference(identities.(current), identities.(prior))) > 0
  end

  defp bound_artifact?(artifact, project, jobs) when is_map(artifact) do
    artifact["job_id"] in jobs and artifact["status"] in ~w(COMPLETE PARTIAL) and is_list(artifact["members"]) and
      get_in(artifact, ["provenance", "metadata_arguments", "project_id"]) == to_string(project) and
      get_in(artifact, ["provenance", "metadata_arguments", "job_id"]) == to_string(artifact["job_id"]) and
      get_in(artifact, ["provenance", "owned_reader", "exit_status"]) == 0
  end

  defp bound_artifact?(_, _, _), do: false

  defp complete_member?(%{"complete" => true, "path" => path, "sha256" => sha, "text" => text}) when is_binary(path) and is_binary(sha) and is_binary(text),
    do: member_path?(path) and byte_size(text) in 1..1_048_576 and String.valid?(text) and not String.contains?(text, "\uFFFD") and hex?(sha)

  defp complete_member?(_), do: false

  defp member_path?(path),
    do:
      byte_size(path) in 1..1024 and String.valid?(path) and not Regex.match?(~r/[\x00-\x1F\x7F\\:]/u, path) and Path.type(path) == :relative and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp hex?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
