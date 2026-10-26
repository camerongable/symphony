defmodule SymphonyElixir.Factory.ReviewProtocol do
  @moduledoc "Admission-bound review coverage and controller-owned repair limits."
  alias SymphonyElixir.Factory.{StageSchemas, Store, TicketCompletionConfirmation, WorkerEvidence, WorkerInstructions}

  @limit 2
  @roles ~w(feature-writer change-verifier)
  @report "review_report"
  @report_rejections [
    :review_protocol_evidence_incomplete,
    :review_protocol_schema_changed,
    :review_protocol_admission_unproven
  ]

  @spec attach(map(), [map()]) :: map()
  def attach(%{"role" => role, "contract" => contract} = packet, history) when role in @roles do
    ids = Regex.scan(~r/\bAC-\d+\b/, contract) |> List.flatten() |> Enum.uniq() |> Enum.sort()

    if ids == [] or Map.has_key?(packet, "ci_repair") do
      packet
    else
      obligations =
        history
        |> Enum.flat_map(& &1["finding_entries"])
        |> Enum.uniq_by(& &1["id"])

      Map.put(packet, "review_protocol", %{
        "version" => 1,
        "lineage" => digest(Jason.encode!(Map.take(packet, ~w(run_id spec_revision contract_sha256)))),
        "criterion_ids" => ids,
        "finding_obligations" => obligations,
        "repair_attempt_limit" => @limit,
        "repairs_used" => Enum.count(history, & &1["repair_admitted"]),
        "instructions" =>
          "Complete the entire contract review before returning findings, including success, failure, fallback, retry and public-entry boundaries. For each criterion record the boundary inventory, inspected paths and discriminating evidence in review_report. A repair covers the demonstrated failure family throughout the confirmed scope, not only the cited lines. Recheck every prior finding ID independently; a writer's addressed claim is not closure. Classify each current finding as NEW, REGRESSION or UNRESOLVED. Keep factual REPAIR for code-fixable findings regardless of prior review count. BLOCK is only CONTRACT_CHANGED, HUMAN_DECISION or ENVIRONMENT; the controller alone enforces repair limits. Coverage structure is not proof of correctness; unrun checks remain explicitly NOT_RUN." <>
            writer_instructions(role)
      })
    end
  end

  def attach(packet, _history), do: packet

  defp writer_instructions("feature-writer"),
    do:
      " For a source writer, COMPLETE means the implementation candidate is ready for controller validation, not that tests or independent acceptance passed. Mark criteria NOT_CHECKED when execution is unavailable and explain the inspected source evidence. Use CONTINUE only when source implementation remains unfinished, not solely because formatting, generation, CI or independent verification is pending. Writer classifications are observations, not verifier findings or acceptance."

  defp writer_instructions(_role), do: ""

  @doc "Projects a rejected current stopped report without adopting it or altering evidence."
  @spec pending_status(Store.connection(), map()) :: map() | nil
  def pending_status(store, run) do
    row =
      Store.one!(
        store,
        "SELECT e.* FROM worker_evidence e WHERE e.run_id=? AND e.status='RESULT_RECORDED' AND e.rowid=(SELECT MAX(n.rowid) FROM worker_evidence n WHERE n.task_key=e.task_key) ORDER BY e.rowid DESC LIMIT 1",
        [run["run_id"]]
      )

    with evidence when is_map(evidence) <- row,
         true <- is_binary(evidence["binding_json"]) and is_binary(evidence["output_json"]),
         true <- digest(evidence["binding_json"]) == evidence["binding_sha256"] and digest(evidence["output_json"]) == evidence["output_sha256"],
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         {:ok, output} <- Jason.decode(evidence["output_json"]),
         true <- is_map(binding) and is_map(output),
         task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [evidence["task_key"]]),
         true <- current_pending_report?(run, task, evidence, binding),
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         {:ok, packet} <- context(store, task),
         true <- Map.take(packet, ~w(implementation_iteration verifier_round code_repair_round)) == Map.take(run, ~w(implementation_iteration verifier_round code_repair_round)),
         {:error, reason} <- validate_result(store, task, binding, output),
         true <- reason in @report_rejections do
      %{
        request_key: evidence["request_key"],
        reason: to_string(reason),
        evidence_at: evidence["owner_stopped_at"],
        next_action: "Factory intervention: reconcile the returned report with its admitted schema, preserving its result and edits. Do not restart the repair or run a pipeline yet."
      }
    else
      _ -> nil
    end
  end

  defp current_pending_report?(run, task, evidence, binding) do
    task["status"] == "COMPLETE" and task["stage"] == run["state"] and
      Map.take(task, ~w(task_key role)) == Map.take(binding, ~w(task_key role)) and
      Map.take(task, ~w(run_id thread_id turn_id output_json)) == Map.take(evidence, ~w(run_id thread_id turn_id output_json)) and
      Map.take(binding, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)) and
      binding["stage"] == run["state"] and binding["expected_sha"] == run["candidate_sha"] and
      binding["input_sha256"] == task["prompt_sha256"] and current_report_role?(run, task)
  end

  defp current_report_role?(%{"state" => "VERIFYING"} = run, task),
    do: task["role"] == "change-verifier" and task["task_key"] == "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}"

  defp current_report_role?(%{"state" => state}, task) when state in ~w(WRITING REPAIRING REVIEW_WRITING), do: task["role"] == "feature-writer"
  defp current_report_role?(_, _), do: false

  @spec history(Store.connection(), map()) :: {:ok, [map()]} | {:error, atom()}
  def history(store, packet) do
    result =
      Store.query!(
        store,
        "SELECT evidence.* FROM worker_evidence evidence JOIN factory_tasks task ON task.task_key=evidence.task_key WHERE evidence.run_id=? AND task.role='change-verifier' AND evidence.status='CONSUMED' AND task.status='CONSUMED' ORDER BY evidence.rowid",
        [packet["run_id"]]
      )

    Enum.reduce_while(result.rows, {:ok, []}, fn values, {:ok, history} ->
      row = Map.new(Enum.zip(result.columns, values))

      case history_entry(store, packet, row) do
        {:ok, nil} -> {:cont, {:ok, history}}
        {:ok, entry} -> {:cont, {:ok, history ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp history_entry(store, packet, row) do
    with true <- digest(row["binding_json"]) == row["binding_sha256"] and digest(row["output_json"]) == row["output_sha256"],
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         {:ok, output} <- Jason.decode(row["output_json"]),
         true <- binding["role"] == "change-verifier" and binding["run_id"] == packet["run_id"] and binding["expected_sha"] == output["candidate_sha"],
         task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]]),
         true <- Map.take(task, ~w(thread_id turn_id output_json)) == Map.take(row, ~w(thread_id turn_id output_json)),
         true <- WorkerEvidence.owner_stopped?(store, row),
         :ok <- validate_result(store, task, binding, output),
         true <- output["status"] in ~w(PASS REPAIR BLOCK) and is_list(output["findings"]) and Enum.all?(output["findings"], &is_binary/1) do
      matching_history(store, packet, row, binding, output)
    else
      _ -> {:error, :review_protocol_history_unproven}
    end
  end

  defp matching_history(store, packet, row, binding, output) do
    if Map.take(binding, ~w(spec_revision contract_sha256)) == Map.take(packet, ~w(spec_revision contract_sha256)) do
      entries = output["findings"] |> Enum.with_index() |> Enum.map(fn {finding, index} -> %{"id" => finding_id(packet["contract_sha256"], row, output, index, finding), "finding" => finding} end)
      {:ok, %{"status" => output["status"], "finding_entries" => entries, "repair_admitted" => repair_admitted?(store, row, output)}}
    else
      {:ok, nil}
    end
  end

  @spec finding_id(String.t(), map(), map(), non_neg_integer(), String.t()) :: String.t()
  def finding_id(contract, row, %{@report => _}, index, _finding), do: digest(Jason.encode!([contract, row["request_key"], row["output_sha256"], index]))
  def finding_id(contract, _row, _output, _index, finding), do: digest(Jason.encode!([contract, finding]))

  defp repair_admitted?(store, row, %{@report => _}) do
    Store.one!(
      store,
      "SELECT id FROM events WHERE run_id=? AND event_type='TICKET_REVIEW_DECISION' AND json_extract(payload_json,'$.result')='REPAIR_ADMITTED' AND json_extract(payload_json,'$.request_key')=? AND json_extract(payload_json,'$.output_sha256')=? LIMIT 1",
      [row["run_id"], row["request_key"], row["output_sha256"]]
    ) != nil
  end

  defp repair_admitted?(_store, _row, output), do: output["status"] == "REPAIR"

  @spec schema(map(), map()) :: map()
  def schema(%{"review_protocol" => %{"version" => 1} = protocol} = packet, legacy) do
    schema =
      legacy
      |> Map.update!("required", &(&1 ++ [@report]))
      |> put_in(["properties", @report], report_schema(protocol))

    TicketCompletionConfirmation.schema(packet, schema)
  end

  def schema(packet, legacy), do: TicketCompletionConfirmation.schema(packet, legacy)

  @spec schema_json(String.t(), map()) :: map()
  def schema_json(packet, legacy) do
    case Jason.decode(packet) do
      {:ok, decoded} when is_map(decoded) -> schema(base_packet(decoded), legacy)
      _ -> legacy
    end
  end

  @spec validate_admission(String.t(), map()) :: :ok | {:error, atom()}
  def validate_admission(prompt, output_schema) do
    case Jason.decode(prompt) do
      {:ok, decoded} when is_map(decoded) -> validate_packet_schema(base_packet(decoded), output_schema)
      _ -> :ok
    end
  end

  defp validate_packet_schema(%{"review_protocol" => %{"version" => 1}, "role" => role} = packet, output_schema) when role in @roles do
    if output_schema == schema(packet, legacy_schema(role)),
      do: :ok,
      else: {:error, :review_protocol_schema_changed}
  end

  defp validate_packet_schema(%{"review_protocol" => _}, _schema), do: {:error, :review_protocol_unsupported}
  defp validate_packet_schema(_packet, _schema), do: :ok

  defp base_packet(%{"base_packet" => packet, "blocked_writer_context" => context} = wrapper) when is_map(packet) and is_map(context) do
    native = Enum.sort(Map.keys(wrapper)) == ~w(base_packet blocked_writer_context explicit_native_rework) and is_binary(wrapper["explicit_native_rework"])

    recovery =
      Enum.sort(Map.keys(wrapper)) == ~w(base_packet blocked_writer_context controller_infrastructure_recovery recovery_instruction) and is_binary(wrapper["controller_infrastructure_recovery"]) and
        is_binary(wrapper["recovery_instruction"])

    if native or recovery, do: packet, else: wrapper
  end

  defp base_packet(%{"base_packet" => packet, "controller_failed_turn_recovery" => key, "recovery_instruction" => instruction, "preserved_paths" => paths} = wrapper)
       when is_map(packet) and is_binary(key) and is_binary(instruction) and is_list(paths) do
    if Enum.sort(Map.keys(wrapper)) == ~w(base_packet controller_failed_turn_recovery preserved_paths recovery_instruction), do: packet, else: wrapper
  end

  defp base_packet(packet), do: packet

  @spec context(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def context(store, task) do
    with {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         row when is_map(row) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(row["binding_json"]) == mapping["instruction_binding_sha256"],
         {:ok, packet} <- Jason.decode(row["binding_json"]),
         role = if(task["role"] == "feature-writer" and Map.has_key?(packet, "ci_repair"), do: "ci-repair-writer", else: task["role"]),
         {:ok, _} <- WorkerInstructions.read(store, packet, role) do
      {:ok, packet}
    else
      _ -> {:error, :review_protocol_admission_unproven}
    end
  end

  @spec validate(map(), map(), map()) :: :ok | {:error, atom()}
  def validate(%{"review_protocol" => %{"version" => 1} = protocol} = packet, binding, output) do
    legacy = legacy_schema(packet["role"])

    with true <- binding["schema"] == schema(packet, legacy),
         :ok <- StageSchemas.validate(output, binding["schema"]),
         report = output[@report],
         true <- report["candidate_sha"] == binding["expected_sha"],
         true <- exact_ids?(report["criteria"], protocol["criterion_ids"]),
         true <- exact_ids?(report["closures"], Enum.map(protocol["finding_obligations"], & &1["id"])),
         true <- exact_ids?(report["boundary_sweeps"], protocol["criterion_ids"]),
         true <- Enum.all?(report["criteria"] ++ report["closures"] ++ report["boundary_sweeps"], &evidence?/1),
         true <- Enum.all?(report["boundary_sweeps"], &nonempty_strings?(&1["paths"])),
         true <- valid_unresolved?(protocol, report),
         true <- consistent_result?(packet["role"], output, report) do
      :ok
    else
      _ -> {:error, :review_protocol_evidence_incomplete}
    end
  end

  def validate(%{"review_protocol" => _}, _binding, _output), do: {:error, :review_protocol_unsupported}

  def validate(packet, binding, output) do
    legacy = schema(packet, legacy_schema(packet["role"]))
    if binding["schema"] == legacy, do: StageSchemas.validate(output, legacy), else: {:error, :review_protocol_schema_changed}
  end

  @spec validate_result(Store.connection(), map(), map(), map()) :: :ok | {:error, atom()}
  def validate_result(store, task, binding, output) do
    with {:ok, packet} <- bound_context(store, task, binding),
         :ok <- exact_input(packet, task, binding) do
      validate(packet, binding, output)
    end
  end

  defp exact_input(%{"review_protocol" => _} = packet, task, binding) do
    matching = Map.take(packet, ~w(run_id role stage spec_revision contract_sha256)) == Map.take(binding, ~w(run_id role stage spec_revision contract_sha256))
    prompt = task["prompt_sha256"] == binding["prompt_sha256"] and binding["input_sha256"] == binding["prompt_sha256"]
    candidate = (packet["candidate_sha"] || packet["base_sha"]) == binding["expected_sha"]
    if matching and prompt and candidate, do: :ok, else: {:error, :review_protocol_admission_unproven}
  end

  defp exact_input(_packet, _task, _binding), do: :ok

  defp bound_context(store, task, binding) do
    case context(store, task) do
      {:ok, packet} ->
        {:ok, packet}

      error ->
        missing = Store.one!(store, "SELECT task_key FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?", [task["task_key"], task["prompt_sha256"]]) == nil
        if missing and binding["schema"] == legacy_schema(task["role"]), do: {:ok, %{"role" => task["role"]}}, else: error
    end
  end

  @spec decision(map(), map()) :: :legacy | :pass | :block | :repair | {:stop, map()}
  def decision(%{"review_protocol" => protocol}, %{"status" => "REPAIR"} = output) do
    unresolved = protocol["repairs_used"] > 0 and unresolved_closure?(output[@report])

    cond do
      unresolved -> {:stop, stop(protocol, "UNRESOLVED_FINDING")}
      protocol["repairs_used"] >= @limit -> {:stop, stop(protocol, "REPAIR_LIMIT")}
      true -> :repair
    end
  end

  def decision(%{"review_protocol" => _}, %{"status" => "PASS"}), do: :pass
  def decision(%{"review_protocol" => _}, %{"status" => "BLOCK"}), do: :block
  def decision(_packet, _output), do: :legacy

  @doc "Records one policy decision with verifier consumption in the caller's adoption transaction."
  @spec apply_policy(Store.connection(), map(), map(), map(), String.t()) :: {:ok, term()} | {:error, atom()}
  def apply_policy(%DBConnection{} = store, run, task, output, request) do
    with row when is_map(row) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request]),
         true <- row["task_key"] == task["task_key"] and row["output_json"] == Jason.encode!(output),
         true <- digest(row["binding_json"]) == row["binding_sha256"] and digest(row["output_json"]) == row["output_sha256"],
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         {:ok, packet} <- bound_context(store, task, binding),
         true <- row["run_id"] == run["run_id"] and binding["expected_sha"] == run["candidate_sha"],
         :ok <- validate_result(store, task, binding, output) do
      record_policy(store, run, packet, row, decision(packet, output))
    else
      _ -> {:error, :review_policy_adoption_unproven}
    end
  end

  def apply_policy(_store, _run, _task, _output, _request), do: {:error, :review_policy_adoption_transaction_required}

  defp record_policy(_store, _run, _packet, _row, :legacy), do: {:ok, :legacy}

  defp record_policy(store, run, packet, row, choice) do
    protocol = packet["review_protocol"]

    payload = %{
      "version" => 1,
      "kind" => "REVIEW_POLICY_DECISION_V1",
      "lineage" => protocol["lineage"],
      "request_key" => row["request_key"],
      "binding_sha256" => row["binding_sha256"],
      "output_sha256" => row["output_sha256"],
      "candidate_sha" => run["candidate_sha"],
      "contract_sha256" => run["contract_sha256"],
      "spec_revision" => run["spec_revision"],
      "verifier_round" => run["verifier_round"],
      "result" => disposition(choice),
      "repair_attempt_limit" => @limit,
      "repairs_used_before" => protocol["repairs_used"],
      "repairs_used_after" => protocol["repairs_used"] + if(choice == :repair, do: 1, else: 0),
      "stop" =>
        case choice do
          {:stop, policy} -> policy
          _ -> nil
        end
    }

    persist_decision(store, run["run_id"], row["request_key"], Jason.encode!(payload), choice)
  end

  defp disposition(:repair), do: "REPAIR_ADMITTED"
  defp disposition(:pass), do: "PASS"
  defp disposition(:block), do: "REVIEW_BLOCKED"
  defp disposition({:stop, _}), do: "POLICY_STOPPED"

  defp persist_decision(store, run_id, request, raw, choice) do
    rows = Store.query!(store, "SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_REVIEW_DECISION' AND json_extract(payload_json,'$.request_key')=?", [run_id, request]).rows

    case rows do
      [] ->
        Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_REVIEW_DECISION',?,?)", [DateTime.to_iso8601(DateTime.utc_now()), run_id, raw])
        {:ok, choice}

      [[^raw]] ->
        {:ok, choice}

      _ ->
        {:error, :review_policy_decision_changed}
    end
  end

  @doc "Projects a current preserved review stop independently of scheduler health."
  @spec status(Store.connection(), map()) :: map() | nil
  def status(store, %{"state" => "FAILED"} = run) do
    failure = run["last_error"] || ""

    with true <- String.starts_with?(failure, ["{:verification_blocked,", "{:verification_policy_stopped,", "{:code_repair_limit,"]),
         task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=? AND status='CONSUMED'", [run["run_id"] <> ":change-verifier:" <> to_string(run["verifier_round"])]),
         {:ok, evidence} <- WorkerEvidence.verifier_receipt(store, run, task),
         {:ok, output} <- Jason.decode(evidence["output_json"]),
         true <- output["status"] in ~w(REPAIR BLOCK),
         policy = current_stop(store, run, evidence) || combined_stop(store, run, evidence),
         true <- is_map(policy) or output["status"] == "BLOCK" do
      project_stop(run, task, evidence, output, policy)
    else
      _ -> nil
    end
  end

  def status(_store, _run), do: nil

  defp project_stop(run, task, evidence, output, policy) do
    {kind, title, rule, explanation} = stop_description(policy, output)

    %{
      kind: kind,
      title: title,
      rule: rule,
      explanation: explanation,
      owner: "Requester decision",
      recorded_ci: recorded_ci(run),
      findings: output["findings"],
      verifier_task_key: task["task_key"],
      evidence_at: evidence["consumed_at"],
      next_action: "Review the findings in the ticket chat and decide on a separately authorized continuation. Automatic repair is stopped."
    }
  end

  defp stop_description(%{"reason" => "COMBINED_REPAIR_LIMIT"} = policy, _output) do
    {"REVIEW_POLICY", "Combined repair limit reached", "Combined code-repair budget includes CI and verification repairs",
     "The controller refused the next repair at combined round #{policy["repairs_used"]}. This is separate from the two-attempt verification-repair limit; the historical receipt does not retain its configured limit value."}
  end

  defp stop_description(%{"reason" => "REPAIR_LIMIT"} = policy, _output) do
    {"REVIEW_POLICY", "Verification repair limit reached", "At most two repairs after the initial review",
     "#{policy["repairs_used"]}/#{policy["repair_attempt_limit"]} repair attempts used. The latest review still requires code changes."}
  end

  defp stop_description(%{"reason" => "UNRESOLVED_FINDING"} = policy, _output) do
    {"REVIEW_POLICY", "Verification stopped: a finding remains unresolved", "Stop early when a prior finding remains unresolved",
     "A previously reported finding remains unresolved after #{policy["repairs_used"]} repair attempt(s)."}
  end

  defp stop_description(nil, output) do
    legacy_limit = not Map.has_key?(output, @report) and Enum.any?(output["checks"], &String.contains?(String.downcase(&1), ["two-consecutive-non-pass", "two consecutive non-pass"]))

    if legacy_limit do
      {"LEGACY_REVIEWER_REPORTED_LIMIT", "Verification stopped by the review safety rule", "Legacy rule: two consecutive non-PASS reviews",
       "The verifier reported this safety limit. Its historical BLOCK verdict is preserved; this is not a factory runtime error."}
    else
      {"VERIFICATION", "Independent verification stopped", "Review requires a human decision or unavailable evidence",
       "The recorded verifier returned BLOCK. Read its findings before authorizing further work."}
    end
  end

  defp recorded_ci(%{"candidate_sha" => candidate} = run) do
    case Jason.decode(run["ci_evidence_json"] || "null") do
      {:ok, %{"status" => "PASS", "sha" => ^candidate}} -> "PASSED"
      _ -> "NOT_PROVEN"
    end
  end

  defp combined_stop(store, run, evidence) do
    row =
      Store.one!(store, "SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_VERIFIER_TERMINAL' AND json_extract(payload_json,'$.request_key')=?", [
        run["run_id"],
        evidence["request_key"]
      ])

    with true <- String.starts_with?(run["last_error"] || "", "{:code_repair_limit,"),
         %{"payload_json" => raw} <- row,
         {:ok, receipt} <- Jason.decode(raw),
         true <- receipt["version"] == 1 and receipt["kind"] == "TICKET_VERIFIER_TERMINAL_V1" and receipt["reason"] == "code_repair_limit",
         true <- Map.take(receipt, ~w(request_key task_key binding_sha256 output_sha256)) == Map.take(evidence, ~w(request_key task_key binding_sha256 output_sha256)),
         true <- receipt["prior_run"] == Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256 verifier_round code_repair_round implementation_iteration)) do
      %{"reason" => "COMBINED_REPAIR_LIMIT", "repairs_used" => run["code_repair_round"]}
    else
      _ -> nil
    end
  end

  defp current_stop(store, run, evidence) do
    row =
      Store.one!(store, "SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_REVIEW_DECISION' AND json_extract(payload_json,'$.request_key')=? ORDER BY id DESC LIMIT 1", [
        run["run_id"],
        evidence["request_key"]
      ])

    with %{"payload_json" => raw} <- row,
         {:ok, payload} <- Jason.decode(raw),
         true <- payload["kind"] == "REVIEW_POLICY_DECISION_V1" and payload["version"] == 1 and payload["result"] == "POLICY_STOPPED",
         true <- payload["output_sha256"] == evidence["output_sha256"] and payload["binding_sha256"] == evidence["binding_sha256"],
         true <- Map.take(payload, ~w(candidate_sha contract_sha256 spec_revision verifier_round)) == Map.take(run, ~w(candidate_sha contract_sha256 spec_revision verifier_round)),
         %{"version" => 1, "reason" => reason, "repair_attempt_limit" => 2} = stop <- payload["stop"],
         true <- reason in ~w(REPAIR_LIMIT UNRESOLVED_FINDING) do
      stop
    else
      _ -> nil
    end
  end

  defp stop(protocol, reason),
    do: %{"version" => 1, "reason" => reason, "repair_attempt_limit" => @limit, "repairs_used" => protocol["repairs_used"], "owner" => "OPERATOR", "automatic_repair" => false}

  defp consistent_result?("change-verifier", output, report) do
    findings = output["findings"]
    classified = Enum.map(report["finding_classifications"], & &1["finding"])

    Enum.sort(classified) == Enum.sort(findings) and length(classified) == length(Enum.uniq(classified)) and Enum.all?(findings, &(String.trim(&1) != "")) and
      verifier_verdict?(output["status"], findings, report)
  end

  defp consistent_result?("feature-writer", output, report) do
    valid_writer_classifications?(report["finding_classifications"]) and
      (output["status"] != "COMPLETE" or (output["blockers"] == [] and writer_coverage?(report)))
  end

  defp valid_writer_classifications?(rows) do
    findings = Enum.map(rows, & &1["finding"])
    length(findings) == length(Enum.uniq(findings)) and Enum.all?(findings, &(String.trim(&1) != ""))
  end

  defp writer_coverage?(report) do
    Enum.all?(report["criteria"], &(&1["status"] in ~w(PASS NOT_CHECKED))) and not unresolved_closure?(report) and
      checked?(report) and report["block_reason"] == "NONE"
  end

  defp verifier_verdict?("PASS", findings, report), do: findings == [] and complete_coverage?(report)

  defp verifier_verdict?("REPAIR", findings, report) do
    findings != [] and report["block_reason"] == "NONE" and checked?(report) and
      Enum.all?(report["criteria"], &(&1["status"] in ~w(PASS FAIL))) and
      Enum.any?(report["criteria"], &(&1["status"] == "FAIL"))
  end

  defp verifier_verdict?("BLOCK", findings, report),
    do: findings != [] and report["block_reason"] in ~w(CONTRACT_CHANGED HUMAN_DECISION ENVIRONMENT)

  defp complete_coverage?(report) do
    Enum.all?(report["criteria"], &(&1["status"] == "PASS")) and not unresolved_closure?(report) and
      checked?(report) and report["block_reason"] == "NONE"
  end

  defp checked?(report), do: Enum.all?(report["boundary_sweeps"], &(&1["status"] == "CHECKED"))
  defp unresolved_closure?(report), do: Enum.any?(report["closures"], &(&1["status"] == "UNRESOLVED"))

  defp valid_unresolved?(protocol, report) do
    closure = unresolved_closure?(report)
    classified = Enum.any?(report["finding_classifications"], &(&1["classification"] == "UNRESOLVED"))
    (not closure or protocol["repairs_used"] > 0) and (not classified or closure)
  end

  defp exact_ids?(rows, expected), do: Enum.sort(Enum.map(rows, & &1["id"])) == Enum.sort(expected)
  defp evidence?(row), do: nonempty_strings?(row["evidence"])
  defp nonempty_strings?(values), do: is_list(values) and values != [] and Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))
  defp legacy_schema("feature-writer"), do: StageSchemas.for_stage(:native_feature_writer)
  defp legacy_schema("change-verifier"), do: StageSchemas.for_stage(:change_verifier)
  defp legacy_schema("feature-planner"), do: StageSchemas.for_stage(:feature_planner)
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp report_schema(protocol) do
    text = %{"type" => "string"}
    texts = %{"type" => "array", "items" => text}

    row = fn ids, statuses, extra ->
      identity = if ids == [], do: text, else: %{"type" => "string", "enum" => ids}
      properties = Map.merge(%{"id" => identity, "status" => %{"type" => "string", "enum" => statuses}, "evidence" => texts}, extra)
      object(properties)
    end

    array = fn schema -> %{"type" => "array", "items" => schema} end
    ids = protocol["criterion_ids"]
    finding_ids = Enum.map(protocol["finding_obligations"], & &1["id"])

    object(%{
      "version" => %{"type" => "integer", "enum" => [1]},
      "candidate_sha" => text,
      "criteria" => array.(row.(ids, ~w(PASS FAIL NOT_CHECKED), %{})),
      "closures" => array.(row.(finding_ids, ~w(ADDRESSED UNRESOLVED SUPERSEDED), %{})),
      "boundary_sweeps" => array.(row.(ids, ~w(CHECKED UNAVAILABLE), %{"paths" => texts})),
      "finding_classifications" => array.(object(%{"finding" => text, "classification" => %{"type" => "string", "enum" => ~w(NEW REGRESSION UNRESOLVED)}})),
      "block_reason" => %{"type" => "string", "enum" => ~w(NONE CONTRACT_CHANGED HUMAN_DECISION ENVIRONMENT)}
    })
  end

  defp object(properties), do: %{"type" => "object", "additionalProperties" => false, "required" => Enum.sort(Map.keys(properties)), "properties" => properties}
end
