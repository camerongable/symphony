defmodule SymphonyElixir.Factory.RepairObligations do
  @moduledoc "Retains verifier findings and proves ordinary repair preflight scope; never attests delivery acceptance."
  alias SymphonyElixir.Factory.{ReviewProtocol, Store, TicketVerifierRepair, WorkerEvidence, WorkerInstructions}

  @spec attach(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def attach(store, %{"role" => role} = packet) when role in ~w(feature-writer change-verifier) do
    retained =
      Store.query!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE run_id=? AND json_extract(binding_json,'$.role')=? ORDER BY rowid DESC", [packet["run_id"], role]).rows
      |> Enum.find_value(fn [raw] ->
        case Jason.decode(raw) do
          {:ok, prior} when is_map(prior) -> if Map.drop(prior, ~w(repair_review review_protocol)) == packet, do: prior
          _ -> nil
        end
      end)

    if retained do
      {:ok, retained}
    else
      with {:ok, review} <- previous_review(store, packet),
           {:ok, history} <- review_history(store, packet) do
        enriched = if(is_nil(review), do: packet, else: Map.put(packet, "repair_review", review))
        {:ok, ReviewProtocol.attach(enriched, history)}
      end
    end
  end

  def attach(_store, packet), do: {:ok, packet}

  defp review_history(_store, %{"ci_repair" => _}), do: {:ok, []}
  defp review_history(store, packet), do: ReviewProtocol.history(store, packet)

  @spec ordinary_preflight(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def ordinary_preflight(store, run) do
    with task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE run_id=? AND role='feature-writer'", [run["run_id"]]),
         true <- task["stage"] == "REPAIRING" and task["status"] == "CONSUMED" and task["workspace_sha"] == run["candidate_sha"],
         source when is_map(source) <-
           Store.one!(store, "SELECT * FROM worker_evidence WHERE task_key=? AND thread_id=? AND turn_id=? AND status='CONSUMED'", [task["task_key"], task["thread_id"], task["turn_id"]]),
         true <- source["output_json"] == task["output_json"],
         {:ok, binding} <- Jason.decode(source["binding_json"]),
         true <- binding["input_sha256"] == task["prompt_sha256"] and binding["prompt_sha256"] == task["prompt_sha256"] do
      ordinary_scope(store, run, source)
    else
      _ -> {:error, :ordinary_verifier_repair_unproven}
    end
  end

  @doc "Rechecks only an already completed immutable push scope; never grants current worker or push admission."
  @spec ordinary_history(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def ordinary_history(store, run) do
    with raw when is_binary(raw) <- run["candidate_handoff"],
         {:ok, %{"phase" => "COMPLETED", "kind" => "TICKET_PUSH"} = intent} <- Jason.decode(raw),
         true <- digest(intent["binding_json"]) == intent["binding_sha256"] and digest(intent["receipt_json"]) == intent["receipt_sha256"],
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <-
           Map.take(binding, ~w(run_id candidate_sha contract_sha256 spec_revision code_repair_round verifier_round worktree branch base_branch)) ==
             Map.take(run, ~w(run_id candidate_sha contract_sha256 spec_revision code_repair_round verifier_round worktree branch base_branch)),
         proof when is_map(proof) <- binding["ordinary_verifier_repair"],
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?", [intent["reservation_key"], run["run_id"]]),
         true <- access["mode"] == "MAINTENANCE" and is_binary(access["released_at"]) and access["release_receipt_json"] == raw,
         true <- access["generation"] == intent["reservation_generation"] and intent["remote_sha"] == run["candidate_sha"],
         source when is_map(source) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=? AND run_id=? AND status='CONSUMED'", [proof["writer_request_key"], run["run_id"]]),
         {:ok, ^proof} <- ordinary_scope(store, run, source) do
      {:ok, proof}
    else
      _ -> {:error, :ordinary_verifier_repair_history_unproven}
    end
  end

  @doc "Authenticates the stopped ordinary writer before controller generation; it does not authorize a push."
  @spec ordinary_generation(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def ordinary_generation(store, run, request_key) do
    with source when is_map(source) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=? AND run_id=?", [request_key, run["run_id"]]),
         {:ok, proof} <- ordinary_scope(store, run, source, :generation) do
      {:ok, Map.put(proof, "candidate_sha", proof["source_parent_sha"])}
    else
      _ -> {:error, :ordinary_verifier_generation_unproven}
    end
  end

  defp ordinary_scope(store, run, source, phase \\ :consumed) do
    with true <- digest(source["binding_json"]) == source["binding_sha256"] and digest(source["output_json"]) == source["output_sha256"],
         {:ok, binding} <- Jason.decode(source["binding_json"]),
         true <- binding["role"] == "feature-writer" and binding["stage"] == "REPAIRING" and binding["mode"] == "SOURCE",
         true <- source["task_key"] == run["run_id"] <> ":feature-writer" and binding["task_key"] == source["task_key"],
         true <- Map.take(binding, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         true <- binding["input_sha256"] == binding["prompt_sha256"],
         true <- WorkerEvidence.owner_stopped?(store, source),
         true <- ordinary_source_phase?(store, source, binding, phase),
         {:ok, %{"status" => "COMPLETE"}} <- Jason.decode(source["output_json"]),
         mapping when is_map(mapping) <- Store.one!(store, "SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?", [source["task_key"], binding["prompt_sha256"]]),
         true <- mapping["run_id"] == run["run_id"] and mapping["role"] == "feature-writer",
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(snapshot["binding_json"]) == mapping["instruction_binding_sha256"],
         {:ok, packet} <- Jason.decode(snapshot["binding_json"]),
         {:ok, _} <- WorkerInstructions.read(store, packet, "feature-writer"),
         true <- packet["stage"] == "REPAIRING" and packet["role"] == "feature-writer" and not Map.has_key?(packet, "ci_repair"),
         true <- packet["code_repair_round"] == run["code_repair_round"] and packet["candidate_sha"] == binding["expected_sha"],
         true <- packet["verifier_round"] in [run["verifier_round"], run["verifier_round"] - 1],
         true <- Map.take(packet, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         {:ok, review} <- ordinary_review(store, packet),
         verifier when is_map(verifier) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=? AND run_id=? AND status='CONSUMED'", [review["verifier_request_key"], run["run_id"]]),
         {:ok, ^review} <- review(store, verifier, packet),
         {:ok, findings} <- Jason.decode(packet["repair_findings"] || "null"),
         true <- is_list(findings) and Enum.uniq(findings) == Enum.map(review["findings"], & &1["finding"]),
         {:ok, verifier_binding} <- Jason.decode(verifier["binding_json"]),
         true <- verifier_binding["task_key"] == run["run_id"] <> ":change-verifier:" <> to_string(packet["verifier_round"]),
         {:ok, reviewed} <- verifier_packet(store, verifier["request_key"]),
         true <- reviewed["code_repair_round"] == run["code_repair_round"] - 1,
         true <- get_in(reviewed, ["ci_evidence", "status"]) == "PASS" and get_in(reviewed, ["ci_evidence", "sha"]) == review["prior_candidate_sha"],
         true <- is_nil(Store.one!(store, "SELECT claim_key FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]])) do
      {:ok,
       %{
         "version" => 1,
         "kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1",
         "candidate_sha" => run["candidate_sha"],
         "source_parent_sha" => binding["expected_sha"],
         "round" => run["code_repair_round"],
         "verifier_round" => packet["verifier_round"],
         "reviewed_candidate_sha" => review["prior_candidate_sha"],
         "verifier_request_key" => verifier["request_key"],
         "verifier_thread_id" => verifier["thread_id"],
         "verifier_turn_id" => verifier["turn_id"],
         "verifier_binding_sha256" => verifier["binding_sha256"],
         "verifier_output_sha256" => verifier["output_sha256"],
         "writer_request_key" => source["request_key"],
         "writer_thread_id" => source["thread_id"],
         "writer_turn_id" => source["turn_id"],
         "writer_binding_sha256" => source["binding_sha256"],
         "writer_output_sha256" => source["output_sha256"],
         "instruction_binding_sha256" => mapping["instruction_binding_sha256"]
       }
       |> operator_scope(review)}
    else
      _ -> {:error, :ordinary_verifier_repair_unproven}
    end
  end

  defp operator_scope(proof, review) do
    case Map.fetch(review, "operator_authorization") do
      {:ok, operator} -> Map.merge(proof, %{"version" => 2, "operator_authorization" => operator})
      :error -> proof
    end
  end

  defp ordinary_source_phase?(store, source, binding, :consumed),
    do: source["status"] == "CONSUMED" and is_binary(source["consumed_at"]) and released_worker?(store, source, binding, "SOURCE")

  defp ordinary_source_phase?(store, source, binding, :generation) do
    access = Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [source["reservation_key"]])

    is_map(access) and source["status"] == "RESULT_RECORDED" and is_nil(source["consumed_at"]) and
      access["mode"] == "SOURCE" and is_nil(access["released_at"]) and access["request_key"] == source["request_key"] and
      access["task_key"] == source["task_key"] and access["generation"] == binding["reservation_generation"]
  end

  defp ordinary_review(store, packet) do
    if Map.has_key?(packet, "repair_review") do
      case packet["repair_review"] do
        review when is_map(review) -> {:ok, review}
        _ -> {:error, :repair_review_history_unproven}
      end
    else
      # Older admitted packets are immutable. Derive their missing advisory context
      # only from the exact verifier round they already pin, not the latest result.
      with round when is_integer(round) <- packet["verifier_round"],
           row when is_map(row) <-
             Store.one!(store, "SELECT * FROM worker_evidence WHERE run_id=? AND task_key=? AND status='CONSUMED'", [packet["run_id"], packet["run_id"] <> ":change-verifier:" <> to_string(round)]),
           {:ok, context} when is_map(context) <- review(store, row, packet) do
        {:ok, context}
      else
        _ -> {:error, :repair_review_history_unproven}
      end
    end
  end

  @spec ordinary_preimage(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def ordinary_preimage(store, run) do
    with {:ok, proof} <- ordinary_preimage_scope(store, run),
         {:ok, reviewed} <- verifier_packet(store, proof["verifier_request_key"]),
         ci when is_map(ci) <- reviewed["ci_evidence"],
         true <- ci["status"] == "PASS" and ci["sha"] == proof["reviewed_candidate_sha"],
         access when is_map(access) <-
           Store.one!(
             store,
             """
             SELECT * FROM workspace_access WHERE run_id=? AND mode='MAINTENANCE' AND released_at IS NOT NULL
               AND json_extract(release_receipt_json,'$.phase')='COMPLETED'
               AND json_extract(release_receipt_json,'$.remote_sha')=? ORDER BY generation DESC LIMIT 1
             """,
             [run["run_id"], proof["reviewed_candidate_sha"]]
           ),
         {:ok, intent} <- Jason.decode(access["release_receipt_json"]),
         true <- digest(intent["binding_json"]) == intent["binding_sha256"],
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <- (binding["code_repair_round"] || 0) == proof["round"] - 1,
         true <-
           Map.take(binding, ~w(run_id repo_path worktree branch base_branch spec_revision contract_sha256)) ==
             Map.take(run, ~w(run_id repo_path worktree branch base_branch spec_revision contract_sha256)) do
      {:ok,
       run
       |> Map.put("candidate_sha", proof["reviewed_candidate_sha"])
       |> Map.put("candidate_handoff", access["release_receipt_json"])
       |> Map.put("ci_preflight_sha", proof["reviewed_candidate_sha"])
       |> Map.put("ci_evidence_json", Jason.encode!(ci))
       |> Map.put("ci_pipeline_id", ci["pipeline_id"])
       |> Map.put("ci_pipeline_url", ci["pipeline_url"])
       |> Map.put("ci_last_checked_at", nil)
       |> Map.put("code_repair_round", proof["round"] - 1)
       |> Map.put("verifier_round", binding["verifier_round"])
       |> Map.put("state", "CI_WAITING")}
    else
      _ -> {:error, :ordinary_verifier_repair_unproven}
    end
  end

  defp ordinary_preimage_scope(store, run) do
    case ordinary_preflight(store, run) do
      {:ok, proof} -> {:ok, proof}
      _ -> ordinary_history(store, run)
    end
  end

  defp verifier_packet(store, request) do
    with evidence when is_map(evidence) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request]),
         task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [evidence["task_key"]]),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(snapshot["binding_json"]) == mapping["instruction_binding_sha256"],
         {:ok, packet} <- Jason.decode(snapshot["binding_json"]),
         {:ok, _} <- WorkerInstructions.read(store, packet, "change-verifier") do
      {:ok, packet}
    else
      _ -> {:error, :repair_review_history_unproven}
    end
  end

  @spec previous_review(Store.connection(), map()) :: {:ok, map() | nil} | {:error, atom()}
  def previous_review(store, packet) do
    row =
      Store.one!(
        store,
        """
        SELECT evidence.* FROM worker_evidence AS evidence
        WHERE evidence.run_id=? AND evidence.task_key LIKE ?
          AND evidence.status='CONSUMED'
        ORDER BY evidence.rowid DESC LIMIT 1
        """,
        [packet["run_id"], packet["run_id"] <> ":change-verifier:%"]
      )

    if row, do: review(store, row, packet), else: {:ok, nil}
  end

  defp review(store, row, packet) do
    with task when is_map(task) <- Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]]),
         true <- task["status"] == "CONSUMED" and task["role"] == "change-verifier" and task["stage"] == "VERIFYING",
         true <- Map.take(task, ~w(thread_id turn_id output_json)) == Map.take(row, ~w(thread_id turn_id output_json)),
         true <- digest(row["binding_json"]) == row["binding_sha256"] and digest(row["output_json"]) == row["output_sha256"],
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         true <- binding["run_id"] == packet["run_id"] and binding["task_key"] == task["task_key"],
         true <- binding["prompt_sha256"] == task["prompt_sha256"] and binding["input_sha256"] == task["prompt_sha256"],
         true <- binding["role"] == "change-verifier" and binding["stage"] == "VERIFYING" and binding["mode"] == "REVIEW",
         true <- WorkerEvidence.owner_stopped?(store, row) and is_binary(row["consumed_at"]),
         true <- released_worker?(store, row, binding, "REVIEW"),
         {:ok, mapping} <- WorkerInstructions.task_binding(store, task),
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(snapshot["binding_json"]) == mapping["instruction_binding_sha256"],
         {:ok, admitted} <- Jason.decode(snapshot["binding_json"]),
         {:ok, _} <- WorkerInstructions.read(store, admitted, "change-verifier"),
         true <-
           Map.take(admitted, ~w(run_id spec_revision contract_sha256 candidate_sha role stage)) ==
             Map.merge(Map.take(binding, ~w(run_id spec_revision contract_sha256 role stage)), %{"candidate_sha" => binding["expected_sha"]}),
         {:ok, output} <- Jason.decode(row["output_json"]),
         true <- output["candidate_sha"] == binding["expected_sha"] and is_binary(output["candidate_sha"]),
         true <- output["status"] in ~w(PASS REPAIR BLOCK) and is_list(output["findings"]) and Enum.all?(output["findings"], &is_binary/1) do
      with true <- Map.take(binding, ~w(spec_revision contract_sha256)) == Map.take(packet, ~w(spec_revision contract_sha256)),
           {:ok, operator} <- operator_authority(store, output["status"], packet, row),
           true <- output["status"] == "REPAIR" or is_map(operator) do
        {:ok,
         %{
           "prior_candidate_sha" => output["candidate_sha"],
           "verifier_request_key" => row["request_key"],
           "verifier_output_sha256" => row["output_sha256"],
           "findings" =>
             output["findings"]
             |> Enum.with_index()
             |> Enum.map(fn {finding, index} -> %{"id" => ReviewProtocol.finding_id(packet["contract_sha256"], row, output, index, finding), "finding" => finding} end)
             |> Enum.uniq_by(& &1["id"]),
           "closure_rules" =>
             "For each finding ID report addressed with code/check evidence, unresolved, or superseded with explicit justification. Classify additional findings as new or regression. Compare the prior reviewed candidate to the current candidate as well as reviewing the full contract diff. Do not weaken correctness, privacy, scope or exact-SHA CI requirements; style preferences alone do not create new acceptance criteria. A writer's addressed claim is not verifier closure."
         }
         |> then(fn review -> if is_map(operator), do: Map.put(review, "operator_authorization", operator), else: review end)}
      else
        {:error, _} = error -> error
        _ -> {:ok, nil}
      end
    else
      _ -> {:error, :repair_review_history_unproven}
    end
  end

  defp operator_authority(store, "BLOCK", packet, row), do: TicketVerifierRepair.review_authority(store, packet, row)
  defp operator_authority(_store, _status, _packet, _row), do: {:ok, nil}

  defp released_worker?(store, worker, binding, mode) do
    with access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [worker["reservation_key"]]),
         true <- access["mode"] == mode and is_binary(access["released_at"]),
         true <- Map.take(access, ~w(run_id task_key request_key reservation_key)) == Map.take(worker, ~w(run_id task_key request_key reservation_key)),
         true <- access["generation"] == binding["reservation_generation"] and access["reservation_key"] == binding["reservation_key"],
         true <- access["canonical_path"] == get_in(binding, ["policy", "cwd"]),
         {:ok, release} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- release == Map.take(worker, ~w(request_key binding_sha256 output_sha256 owner_stopped_at consumed_at)),
         {:ok, saved} <- Jason.decode(access["binding_json"] || "null"),
         true <-
           Map.take(saved, ~w(run_id task_key request_key reservation_key mode expected_sha spec_revision contract_sha256 prompt_sha256)) ==
             Map.merge(Map.take(binding, ~w(run_id task_key reservation_key mode expected_sha spec_revision contract_sha256 prompt_sha256)), %{"request_key" => worker["request_key"]}) do
      true
    else
      _ -> false
    end
  end

  defp digest(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp digest(_raw), do: nil
end
