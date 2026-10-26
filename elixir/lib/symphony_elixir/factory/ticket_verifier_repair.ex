defmodule SymphonyElixir.Factory.TicketVerifierRepair do
  @moduledoc "Explicit operator authorization to repair an exact consumed BLOCK; never rewrites the verdict."
  alias SymphonyElixir.Factory.{
    Capacity,
    Control,
    JiraMcpReader,
    Policy,
    ReviewProtocol,
    RunLedger,
    Store,
    TaskLedger,
    TicketPushRecovery,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerInstructions,
    WorkspaceAccess,
    Worktree
  }

  @authorized "TICKET_VERIFIER_REPAIR_AUTHORIZED"
  @applied "TICKET_VERIFIER_REPAIR_APPLIED"
  @fields ~w(authorization_key run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference authorization_body repair_instructions)
  @run_fields ~w(run_id issue_key repo_key repo_path worktree branch base_branch candidate_sha spec_revision contract_sha256 verifier_round code_repair_round implementation_iteration)
  @terminal_fields ~w(run_id candidate_sha spec_revision contract_sha256 verifier_round code_repair_round implementation_iteration)
  @limit 262_144

  @doc "Authenticates archived operator authority for this exact preserved BLOCK and repair round."
  @spec review_authority(Store.connection(), map(), map()) :: {:ok, map() | nil} | {:error, atom()}
  def review_authority(store, packet, verifier) do
    rows =
      Store.query!(store, "SELECT id,payload_json FROM events WHERE event_type=? AND run_id=? AND json_extract(payload_json,'$.authorization.verifier_request_key')=?", [
        @authorized,
        packet["run_id"],
        verifier["request_key"]
      ]).rows

    case rows do
      [] -> {:ok, nil}
      [[id, raw]] when byte_size(raw) <= @limit -> archived_authority(store, packet, verifier, id, raw)
      _ -> {:error, :verifier_repair_authority_unproven}
    end
  end

  defp archived_authority(store, packet, verifier, id, raw) do
    with {:ok, proof} <- Jason.decode(raw),
         true <- valid_authorization_version?(proof),
         true <- proof["authority"] == "LOCAL_OPERATOR_AUTHORIZATION",
         :ok <- valid_input(proof["authorization"]),
         input = proof["authorization"],
         prior = proof["run"],
         true <- valid_archived_budget?(proof, input, prior),
         true <- Map.take(input, ~w(run_id candidate_sha spec_revision contract_sha256)) == Map.take(prior, ~w(run_id candidate_sha spec_revision contract_sha256)),
         true <- Map.take(packet, ~w(run_id spec_revision contract_sha256)) == Map.take(prior, ~w(run_id spec_revision contract_sha256)),
         true <- packet["code_repair_round"] == prior["code_repair_round"] + 1,
         true <- packet["verifier_round"] in [prior["verifier_round"], prior["verifier_round"] + 1],
         true <- proof["verifier"] == Map.take(verifier, ~w(request_key task_key thread_id turn_id binding_sha256 output_sha256 reservation_key consumed_at owner_stopped_at)),
         true <- input["verifier_request_key"] == verifier["request_key"],
         true <- input["verifier_output_sha256"] == verifier["output_sha256"],
         true <- verifier["task_key"] == prior["run_id"] <> ":change-verifier:" <> to_string(prior["verifier_round"]),
         true <- digest(verifier["output_json"]) == verifier["output_sha256"],
         true <- digest(verifier["binding_json"]) == verifier["binding_sha256"],
         {:ok, %{"status" => "BLOCK", "candidate_sha" => sha} = output} <- Jason.decode(verifier["output_json"]),
         true <- sha == prior["candidate_sha"],
         true <- proof["findings"] == finding_ids(prior["contract_sha256"], ReviewProtocol.findings(output)),
         true <- proof["authorization_body_sha256"] == digest(input["authorization_body"]),
         true <- proof["repair_instructions_sha256"] == digest(input["repair_instructions"]),
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [verifier["reservation_key"]]),
         true <- digest(access["release_receipt_json"] || "") == proof["review_release_sha256"],
         {:ok, terminal} <- terminal_record(store, prior, verifier),
         true <- terminal.id == proof["terminal_event_id"],
         true <- digest(terminal.raw) == proof["terminal_sha256"],
         [[applied_id, applied_raw]] <-
           Store.query!(store, "SELECT id,payload_json FROM events WHERE event_type=? AND run_id=? AND json_extract(payload_json,'$.authorization_event_id')=?", [@applied, packet["run_id"], id]).rows,
         true <- byte_size(applied_raw) <= @limit,
         {:ok, applied} <- Jason.decode(applied_raw),
         true <- applied["version"] == 1,
         true <- applied["kind"] == "BLOCKED_VERIFIER_REPAIR_APPLIED_V1",
         true <- applied["authorization_sha256"] == digest(raw),
         true <- applied["prior_run"] == Map.take(prior, @terminal_fields),
         true <- applied["next_run"] == Map.update!(applied["prior_run"], "code_repair_round", &(&1 + 1)),
         true <- id < applied_id,
         true <- valid_applied_tick?(applied["tick"], proof["control"]) do
      {:ok,
       %{
         "authorization_event_id" => id,
         "authorization_sha256" => digest(raw),
         "applied_event_id" => applied_id,
         "applied_sha256" => digest(applied_raw),
         "authorization_key" => input["authorization_key"],
         "authorization_reference" => input["authorization_reference"],
         "authorization_body_sha256" => proof["authorization_body_sha256"],
         "repair_instructions" => input["repair_instructions"],
         "repair_instructions_sha256" => proof["repair_instructions_sha256"]
       }}
    else
      _ -> {:error, :verifier_repair_authority_unproven}
    end
  end

  defp finding_ids(contract, findings), do: Enum.map(Enum.uniq(findings), &%{"id" => digest(Jason.encode!([contract, &1])), "finding" => &1})

  defp valid_applied_tick?(tick, control) when is_map(tick) and is_map(control) do
    Enum.sort(Map.keys(tick)) == ~w(dispatcher_id generation scope tick_id) and Enum.sort(Map.keys(control)) == ~w(dispatcher_id scope) and
      Map.take(tick, ~w(dispatcher_id scope)) == control and is_integer(tick["generation"]) and tick["generation"] > 0 and is_binary(tick["tick_id"]) and tick["tick_id"] != ""
  end

  defp valid_applied_tick?(_, _), do: false

  @doc "Selects only a staged, unconsumed operator authorization; does not grant worker admission."
  @spec pending?(Store.connection(), String.t()) :: boolean()
  def pending?(store, run_id) do
    Store.one!(
      store,
      "SELECT a.id FROM events a WHERE a.run_id=? AND a.event_type=? AND NOT EXISTS (SELECT 1 FROM events p WHERE p.event_type=? AND json_extract(p.payload_json,'$.authorization_event_id')=a.id) LIMIT 1",
      [run_id, @authorized, @applied]
    ) != nil
  end

  @doc "Applies one exact authorization under the normal owned tick; never dispatches in this tick."
  @spec apply_authorized(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_authorized(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def apply_authorized(store, run_id, factory, opts) do
    case :global.trans({{SymphonyElixir.Factory.Scheduler, :ticket_stage, run_id}, self()}, fn -> apply_locked(store, run_id, factory, opts) end) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp apply_locked(store, run_id, factory, opts) do
    with true <- opts[:ordinary_controller_tick] == true or {:error, :verifier_repair_normal_tick_required},
         {:ok, tick} <- owned_tick(store, factory, opts),
         [[raw]] <-
           Store.query!(
             store,
             "SELECT a.payload_json FROM events a WHERE a.event_type=? AND a.run_id=? AND NOT EXISTS (SELECT 1 FROM events p WHERE p.event_type=? AND json_extract(p.payload_json,'$.authorization_event_id')=a.id)",
             [@authorized, run_id, @applied]
           ).rows,
         {:ok, proof} <- Jason.decode(raw),
         {:ok, record} <- authorization(store, proof["authorization"]["authorization_key"]),
         true <- record.raw == raw,
         [] <- applied_rows(store, record.id),
         {:ok, observed} <- observe(store, proof["authorization"], factory, opts, {:tick, tick}),
         current = authorization_proof(proof["authorization"], observed, factory),
         true <- Map.drop(current, ~w(jira authorized_at)) == Map.drop(proof, ~w(jira authorized_at)) or {:error, :verifier_repair_authorization_changed} do
      Store.transaction!(store, fn tx ->
        commit_application(tx, observed, factory, opts, record, tick)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :verifier_repair_authorization_unavailable}
    end
  end

  defp commit_application(tx, observed, factory, opts, record, tick) do
    proof = record.proof
    run_id = observed.run["run_id"]

    result =
      with :ok <- recheck(tx, observed, factory, {:tick, tick}, opts),
           {:ok, ^record} <- authorization(tx, proof["authorization"]["authorization_key"]),
           [] <- applied_rows(tx, record.id),
           :ok <- TicketWorkerRunner.validate_authorization(observed.run, observed.jira),
           {:ok, %{run: run}} <-
             RunLedger.update(tx, run_id, %{
               state: "REPAIRING",
               failure_code: nil,
               last_error: nil,
               repair_findings_json: Jason.encode!(ReviewProtocol.findings(observed.output)),
               code_repair_round: observed.run["code_repair_round"] + 1
             }) do
        applied = %{
          "version" => 1,
          "kind" => "BLOCKED_VERIFIER_REPAIR_APPLIED_V1",
          "authorization_event_id" => record.id,
          "authorization_sha256" => digest(record.raw),
          "prior_run" => Map.take(observed.run, @terminal_fields),
          "next_run" => Map.take(run, @terminal_fields),
          "tick" => tick,
          "applied_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        id = append(tx, @applied, run_id, Jason.encode!(applied))

        {:ok,
         %{
           status: "VERIFIER_REPAIR_APPLIED",
           authorization: receipt(record, "VERIFIER_REPAIR_APPLIED"),
           applied_event_id: id,
           run: run,
           source_advanced: false
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :verifier_repair_authorization_changed}
      end

    case result do
      {:error, reason} -> Exqlite.rollback(tx, reason)
      ok -> ok
    end
  end

  @spec stage(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def stage(store, input, factory, opts) do
    with :ok <- valid_input(input) do
      serialized(input["run_id"], fn -> stage_locked(store, input, factory, opts) end)
    end
  end

  defp serialized(run_id, operation) do
    case :global.trans({{SymphonyElixir.Factory.Scheduler, :ticket_stage, run_id}, self()}, operation) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp stage_locked(store, input, factory, opts) do
    case authorization(store, input["authorization_key"]) do
      {:ok, record} -> replay(store, record, input)
      :none -> stage_new(store, input, factory, opts)
      error -> error
    end
  end

  defp stage_new(store, input, factory, opts) do
    with {:ok, observed} <- observe(store, input, factory, opts),
         proof = authorization_proof(input, observed, factory),
         raw = Jason.encode!(proof),
         true <- byte_size(raw) <= @limit or {:error, :verifier_repair_authorization_too_large} do
      Store.transaction!(store, fn tx ->
        stage_commit(tx, observed, factory, proof, raw)
      end)
    end
  end

  defp stage_commit(tx, observed, factory, proof, raw) do
    input = proof["authorization"]

    with :ok <- recheck(tx, observed, factory),
         :none <- authorization(tx, input["authorization_key"]),
         [] <- authorization_rows(tx, input["run_id"], input["verifier_request_key"]),
         :ok <- TicketWorkerRunner.validate_authorization(observed.run, observed.jira) do
      id = append(tx, @authorized, input["run_id"], raw)
      {:ok, receipt(%{id: id, raw: raw, proof: proof}, "VERIFIER_REPAIR_AUTHORIZED")}
    else
      {:error, _} = error -> error
      _ -> {:error, :verifier_repair_authorization_conflict}
    end
  end

  defp observe(store, input, factory, opts, mode \\ :stage) do
    with {:ok, run} <- RunLedger.get(store, input["run_id"]),
         true <- Map.get(factory, :enabled) == true or {:error, :verifier_repair_not_enabled},
         {:ok, facts} <- blocked_facts(store, run, input),
         control = Control.status(store, factory.scope),
         :ok <- control_mode(store, control, factory, mode, opts),
         true <- Policy.ticket_selected?(Map.get(factory, :ticket_supervisor, %{}), run["issue_key"]) or {:error, :verifier_repair_not_selected},
         :ok <- available(store, run, factory, input),
         {:ok, route} <- Map.fetch(factory.repositories, run["repo_key"]),
         true <- route["path"] == run["repo_path"] or {:error, :verifier_repair_route_changed},
         checkout = [expected_branch: run["branch"], expected_sha: run["candidate_sha"], clean: true, detached: false],
         {:ok, _} <- Worktree.validate_native(route, run["worktree"], checkout),
         {:ok, %{result: "PASS"}} <- Capacity.snapshot(store, capacity_policy(factory), run["repo_key"], Keyword.put(opts, :exclude_writer_issue_key, run["issue_key"])),
         reader = Keyword.get(opts, :jira_reader, JiraMcpReader),
         {:ok, snapshot} <- reader.issue(run["issue_key"], workspace: Keyword.get(opts, :workspace, run["repo_path"]), store: store),
         {:ok, jira} <- TicketWorkerRunner.delivery_authorization(store, run, snapshot, DateTime.utc_now(), opts),
         {:ok, _} <- WorkerInstructions.read(store, facts.packet, "change-verifier") do
      {:ok, Map.merge(facts, %{run: run, control: control, jira: jira, repair_input: input})}
    else
      {:error, _} = error -> error
      _ -> {:error, :verifier_repair_observation_unproven}
    end
  end

  defp blocked_facts(store, run, input) do
    key = run["run_id"] <> ":change-verifier:" <> to_string(run["verifier_round"])

    with true <- run["state"] == "FAILED",
         true <- run["kind"] == "DELIVERY",
         true <- run["execution_mode"] == "TICKET_SUPERVISOR_V1",
         true <- Map.take(input, ~w(run_id candidate_sha spec_revision contract_sha256)) == Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256)),
         {:ok, evidence} <- WorkerEvidence.get(store, input["verifier_request_key"]),
         true <- evidence["run_id"] == run["run_id"],
         true <- evidence["task_key"] == key,
         true <- evidence["status"] == "CONSUMED",
         true <- is_binary(evidence["consumed_at"]),
         true <- digest(evidence["binding_json"]) == evidence["binding_sha256"],
         true <- digest(evidence["output_json"]) == evidence["output_sha256"],
         true <- evidence["output_sha256"] == input["verifier_output_sha256"],
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         {:ok, %{"status" => "BLOCK", "candidate_sha" => candidate} = output} <- Jason.decode(evidence["output_json"]),
         findings = ReviewProtocol.findings(output),
         true <- candidate == run["candidate_sha"],
         true <- is_list(findings),
         true <- findings != [],
         true <- Enum.all?(findings, &is_binary/1),
         true <- binding["role"] == "change-verifier",
         true <- binding["stage"] == "VERIFYING",
         true <- binding["mode"] == "REVIEW",
         true <- binding["expected_sha"] == candidate,
         true <- Map.take(binding, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         {:ok, task} <- TaskLedger.get(store, key),
         true <- task["status"] == "CONSUMED",
         true <- task["role"] == "change-verifier",
         true <- task["stage"] == "VERIFYING",
         true <- Map.take(task, ~w(thread_id turn_id output_json)) == Map.take(evidence, ~w(thread_id turn_id output_json)),
         true <- task["prompt_sha256"] == binding["input_sha256"],
         true <- binding["input_sha256"] == binding["prompt_sha256"],
         {:ok, access} <- WorkspaceAccess.get(store, evidence["reservation_key"]),
         true <- released_review?(access, evidence, binding, run),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(snapshot["binding_json"]) == snapshot["binding_sha256"],
         {:ok, packet} <- Jason.decode(snapshot["binding_json"]),
         true <- Map.take(packet, @terminal_fields) == Map.take(run, @terminal_fields),
         true <- packet["role"] == "change-verifier",
         true <- packet["stage"] == "VERIFYING",
         true <- get_in(packet, ["ci_evidence", "status"]) == "PASS",
         true <- get_in(packet, ["ci_evidence", "sha"]) == candidate,
         {:ok, ci} <- Jason.decode(run["ci_evidence_json"]),
         true <- packet["ci_evidence"] == ci,
         true <- run["ci_preflight_sha"] == candidate,
         true <- ci["pipeline_id"] == run["ci_pipeline_id"],
         {:ok, terminal} <- terminal_record(store, run, evidence),
         detail = inspect({:verification_blocked, findings}),
         true <- run["last_error"] == detail,
         true <- run["failure_code"] == String.slice(detail, 0, 200) do
      {:ok,
       %{
         evidence: evidence,
         binding: binding,
         output: output,
         task: task,
         access: access,
         mapping: mapping,
         snapshot: snapshot,
         packet: packet,
         terminal: terminal
       }}
    else
      _ -> {:error, :verifier_repair_block_not_current}
    end
  end

  defp released_review?(access, evidence, binding, run) do
    expected = Map.take(evidence, ~w(request_key binding_sha256 output_sha256 consumed_at owner_stopped_at))

    with true <- access["mode"] == "REVIEW",
         true <- is_binary(access["released_at"]),
         true <- access["canonical_path"] == run["worktree"],
         true <- access["reservation_key"] == binding["reservation_key"],
         true <- access["run_id"] == run["run_id"],
         true <- access["task_key"] == evidence["task_key"],
         true <- access["request_key"] == evidence["request_key"],
         true <- access["generation"] == binding["reservation_generation"],
         true <- Jason.decode(access["release_receipt_json"] || "null") == {:ok, expected} do
      saved_access?(access, evidence, binding)
    else
      _ -> false
    end
  end

  defp saved_access?(access, evidence, binding) do
    case Jason.decode(access["binding_json"] || "null") do
      {:ok, saved} when is_map(saved) ->
        Map.take(saved, ~w(run_id task_key request_key reservation_key mode expected_sha spec_revision contract_sha256 prompt_sha256)) ==
          Map.merge(Map.take(binding, ~w(run_id task_key reservation_key mode expected_sha spec_revision contract_sha256 prompt_sha256)), %{"request_key" => evidence["request_key"]})

      _ ->
        false
    end
  end

  defp terminal_record(store, run, evidence) do
    rows =
      Store.query!(store, "SELECT id,payload_json FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_VERIFIER_TERMINAL' AND json_extract(payload_json,'$.request_key')=?", [
        run["run_id"],
        evidence["request_key"]
      ]).rows

    with [[id, raw]] <- rows,
         {:ok, receipt} <- Jason.decode(raw),
         true <- receipt["version"] == 1 and receipt["kind"] == "TICKET_VERIFIER_TERMINAL_V1" and receipt["reason"] == "verification_blocked",
         true <- receipt["output_sha256"] == evidence["output_sha256"] and receipt["binding_sha256"] == evidence["binding_sha256"] and receipt["task_key"] == evidence["task_key"],
         true <- receipt["prior_run"] == Map.take(run, @terminal_fields) do
      {:ok, %{id: id, raw: raw}}
    else
      _ -> {:error, :verifier_repair_terminal_unproven}
    end
  end

  defp available(store, run, factory, input) do
    latest = Store.one!(store, "SELECT run_id FROM runs WHERE issue_key=? AND kind='DELIVERY' ORDER BY created_at DESC,rowid DESC LIMIT 1", [run["issue_key"]])
    active_access = Store.one!(store, "SELECT reservation_key FROM workspace_access WHERE canonical_path=? AND released_at IS NULL LIMIT 1", [run["worktree"]])

    pending_io =
      Store.one!(store, "SELECT o.call_id FROM worker_file_operations o JOIN worker_evidence e ON e.request_key=o.request_key WHERE e.run_id=? AND (o.phase='PREPARED' OR o.io_pending=1) LIMIT 1", [
        run["run_id"]
      ])

    pending_check =
      Store.one!(store, "SELECT c.check_key FROM controller_checks c JOIN worker_evidence e ON e.request_key=c.worker_request_key WHERE e.run_id=? AND c.phase!='COMPLETE' LIMIT 1", [run["run_id"]])

    pending_command = Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id=? AND status IN ('PENDING','ACCEPTED') LIMIT 1", [run["run_id"]])
    pending_amendment = Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id=? AND phase NOT IN ('APPLIED','SUPERSEDED','REJECTED') LIMIT 1", [run["run_id"]])

    with true <- latest["run_id"] == run["run_id"],
         true <- is_nil(active_access),
         true <- is_nil(pending_io),
         true <- is_nil(pending_check),
         true <- is_nil(pending_command),
         true <- is_nil(pending_amendment),
         true <- WorkerEvidence.pending(store, run["run_id"]) == [],
         {:ok, _budget} <- repair_budget(factory, run, input),
         true <- run["implementation_iteration"] < factory.maximum_implementation_iterations do
      :ok
    else
      _ -> {:error, :verifier_repair_admission_unavailable}
    end
  end

  defp recheck(tx, observed, factory, mode \\ :stage, opts \\ []) do
    with :ok <- recheck_control(tx, observed.control, factory, mode, opts),
         {:ok, run} <- RunLedger.get(tx, observed.run["run_id"]),
         true <- run == observed.run,
         {:ok, current} <-
           blocked_facts(tx, run, %{
             "run_id" => run["run_id"],
             "candidate_sha" => run["candidate_sha"],
             "spec_revision" => run["spec_revision"],
             "contract_sha256" => run["contract_sha256"],
             "verifier_request_key" => observed.evidence["request_key"],
             "verifier_output_sha256" => observed.evidence["output_sha256"]
           }),
         true <- Map.take(observed, Map.keys(current)) == current,
         :ok <- available(tx, run, factory, observed.repair_input) do
      :ok
    else
      _ -> {:error, :verifier_repair_observation_changed}
    end
  end

  defp authorization_proof(input, observed, factory) do
    {:ok, budget} = repair_budget(factory, observed.run, input)

    proof = %{
      "version" => 1,
      "kind" => "BLOCKED_VERIFIER_REPAIR_AUTHORIZATION_V1",
      "authority" => "LOCAL_OPERATOR_AUTHORIZATION",
      "authorization" => input,
      "authorization_body_sha256" => digest(input["authorization_body"]),
      "repair_instructions_sha256" => digest(input["repair_instructions"]),
      "run" => Map.take(observed.run, @run_fields),
      "run_sha256" => digest(Jason.encode!(observed.run)),
      "prior_handoff_sha256" => digest(observed.run["candidate_handoff"] || ""),
      "ci_evidence_sha256" => digest(observed.run["ci_evidence_json"] || ""),
      "verifier" => Map.take(observed.evidence, ~w(request_key task_key thread_id turn_id binding_sha256 output_sha256 reservation_key consumed_at owner_stopped_at)),
      "review_release_sha256" => digest(observed.access["release_receipt_json"]),
      "terminal_event_id" => observed.terminal.id,
      "terminal_sha256" => digest(observed.terminal.raw),
      "limits" => %{"maximum_implementation_iterations" => factory.maximum_implementation_iterations, "maximum_code_repair_rounds" => budget.limit},
      "control" => %{"scope" => factory.scope, "dispatcher_id" => factory.dispatcher_id},
      "findings" => finding_ids(observed.run["contract_sha256"], ReviewProtocol.findings(observed.output)),
      "jira" => %{"snapshot_sha256" => digest(observed.jira["snapshot_json"]), "observed_at" => observed.jira["observed_at"]},
      "authorized_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    if budget.exception do
      proof
      |> Map.put("version", 2)
      |> Map.put("kind", "BLOCKED_VERIFIER_REPAIR_AUTHORIZATION_V2")
      |> Map.put("budget_exception", budget.exception)
      |> Map.put("configured_limits", Map.put(proof["limits"], "maximum_code_repair_rounds", factory.maximum_code_repair_rounds))
    else
      proof
    end
  end

  defp repair_budget(factory, run, input) do
    configured = factory.maximum_code_repair_rounds
    exceptions = Map.get(factory.ticket_supervisor, "verifier_repair_budget_exceptions", %{})
    entry = if is_map(exceptions), do: Map.get(exceptions, input["authorization_key"])

    cond do
      run["code_repair_round"] < configured -> {:ok, %{limit: configured, exception: nil}}
      entry === budget_binding(input, run, configured) -> {:ok, %{limit: run["code_repair_round"] + 1, exception: entry}}
      true -> {:error, :verifier_repair_budget_exhausted}
    end
  end

  defp budget_binding(input, run, configured) do
    Map.take(input, ~w(run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference))
    |> Map.merge(%{
      "kind" => "ONE_VERIFIER_REPAIR",
      "verifier_round" => run["verifier_round"],
      "prior_code_repair_round" => run["code_repair_round"],
      "next_code_repair_round" => run["code_repair_round"] + 1,
      "configured_limit" => configured
    })
  end

  defp valid_archived_budget?(%{"version" => 2, "budget_exception" => entry, "configured_limits" => configured, "limits" => effective}, input, prior)
       when is_map(entry) and is_map(configured) and is_map(effective) do
    limit = configured["maximum_code_repair_rounds"]

    valid_limits?(configured) and valid_limits?(effective) and valid_prior_budget?(prior, configured) and
      entry === budget_binding(input, prior, limit) and
      effective === Map.put(configured, "maximum_code_repair_rounds", prior["code_repair_round"] + 1)
  end

  defp valid_archived_budget?(proof, _input, _prior),
    do: proof["version"] == 1 and not Map.has_key?(proof, "budget_exception") and not Map.has_key?(proof, "configured_limits")

  defp valid_limits?(limits) do
    Enum.sort(Map.keys(limits)) == ~w(maximum_code_repair_rounds maximum_implementation_iterations) and
      Enum.all?(Map.values(limits), &(is_integer(&1) and &1 >= 0))
  end

  defp valid_prior_budget?(prior, configured) do
    is_integer(prior["code_repair_round"]) and prior["code_repair_round"] >= configured["maximum_code_repair_rounds"] and
      is_integer(prior["implementation_iteration"]) and prior["implementation_iteration"] >= 0 and
      prior["implementation_iteration"] < configured["maximum_implementation_iterations"]
  end

  defp valid_authorization_version?(%{"version" => 1, "kind" => "BLOCKED_VERIFIER_REPAIR_AUTHORIZATION_V1"}), do: true
  defp valid_authorization_version?(%{"version" => 2, "kind" => "BLOCKED_VERIFIER_REPAIR_AUTHORIZATION_V2"}), do: true
  defp valid_authorization_version?(_), do: false

  defp authorization(store, key) do
    case Store.query!(store, "SELECT id,payload_json FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization.authorization_key')=?", [@authorized, key]).rows do
      [] ->
        :none

      [[id, raw]] when byte_size(raw) <= @limit ->
        with {:ok, proof} <- Jason.decode(raw),
             true <- valid_authorization_version?(proof),
             do: {:ok, %{id: id, raw: raw, proof: proof}}

      _ ->
        {:error, :verifier_repair_authorization_ambiguous}
    end
  end

  defp authorization_rows(store, run_id, request) do
    Store.query!(store, "SELECT id FROM events WHERE event_type=? AND run_id=? AND json_extract(payload_json,'$.authorization.verifier_request_key')=?", [@authorized, run_id, request]).rows
  end

  defp replay(store, record, input) do
    if record.proof["authorization"] == input do
      case applied_rows(store, record.id) do
        [] -> {:ok, receipt(record, "VERIFIER_REPAIR_AUTHORIZED")}
        [[_]] -> {:ok, receipt(record, "VERIFIER_REPAIR_APPLIED")}
        _ -> {:error, :verifier_repair_authorization_ambiguous}
      end
    else
      {:error, :verifier_repair_authorization_conflict}
    end
  end

  defp applied_rows(store, id), do: Store.query!(store, "SELECT id FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization_event_id')=?", [@applied, id]).rows

  defp owned_tick(store, factory, opts) do
    with {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         true <- tick["scope"] == factory.scope and tick["dispatcher_id"] == factory.dispatcher_id do
      {:ok, tick}
    else
      _ -> {:error, :verifier_repair_tick_unproven}
    end
  end

  defp control_mode(_store, control, factory, :stage, _opts), do: idle_control(control, factory)

  defp control_mode(store, _control, factory, {:tick, tick}, opts) do
    case owned_tick(store, factory, opts) do
      {:ok, ^tick} -> :ok
      _ -> {:error, :verifier_repair_tick_unproven}
    end
  end

  defp recheck_control(store, expected, factory, :stage, opts) do
    current = Control.status(store, factory.scope)

    with :ok <- control_mode(store, expected, factory, :stage, opts),
         :ok <- control_mode(store, current, factory, :stage, opts),
         true <- Map.drop(current, ~w(generation updated_at)) == Map.drop(expected, ~w(generation updated_at)),
         true <- current["generation"] >= expected["generation"] do
      :ok
    else
      _ -> {:error, :verifier_repair_control_changed}
    end
  end

  defp recheck_control(store, _expected, factory, mode, opts), do: control_mode(store, nil, factory, mode, opts)

  defp receipt(record, status),
    do: %{status: status, authorization_key: record.proof["authorization"]["authorization_key"], authorization_event_id: record.id, authorization_sha256: digest(record.raw)}

  defp append(store, type, run_id, raw) do
    [[id]] = Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,?,?,?) RETURNING id", [DateTime.to_iso8601(DateTime.utc_now()), type, run_id, raw]).rows
    id
  end

  defp idle_control(%{"status" => "ACTIVE", "tick_id" => nil, "lease_expires_at" => nil, "scope" => scope, "dispatcher_id" => dispatcher, "generation" => generation}, factory)
       when dispatcher == factory.dispatcher_id and scope == factory.scope and is_integer(generation) and generation >= 0,
       do: :ok

  defp idle_control(_, _), do: {:error, :verifier_repair_control_busy}

  defp valid_input(input) when is_map(input) do
    with true <- MapSet.new(Map.keys(input)) == MapSet.new(@fields),
         true <- Enum.all?(Map.delete(input, "spec_revision"), fn {_key, value} -> is_binary(value) and byte_size(value) in 1..8192 end),
         true <- byte_size(input["authorization_key"]) <= 256,
         true <- byte_size(input["authorization_reference"]) <= 2048,
         true <- is_integer(input["spec_revision"]),
         true <- input["spec_revision"] > 0,
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, input["candidate_sha"]),
         true <- Enum.all?(~w(contract_sha256 verifier_output_sha256), &Regex.match?(~r/\A[0-9a-f]{64}\z/, input[&1])) do
      :ok
    else
      _ -> {:error, :verifier_repair_authorization_invalid}
    end
  end

  defp valid_input(_), do: {:error, :verifier_repair_authorization_invalid}

  defp capacity_policy(factory),
    do: %{"repositories" => factory.repositories, "capacity" => Map.new(~w(maximum_specifiers maximum_writers maximum_validators writer_disk_gb)a, &{Atom.to_string(&1), Map.fetch!(factory, &1)})}

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
