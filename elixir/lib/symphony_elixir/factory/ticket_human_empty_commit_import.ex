defmodule SymphonyElixir.Factory.TicketHumanEmptyCommitImport do
  @moduledoc "Audited empty-child source equivalence, distinct from a factory push or verifier result."
  alias SymphonyElixir.Factory.{
    CiCollection,
    Control,
    DesktopRequest,
    GitLabMcpConnector,
    RunLedger,
    Store,
    TicketCiRepair,
    TicketHumanEmptyCommitRead,
    TicketPush,
    TicketPushHazard,
    TicketPushPayloadBudget,
    TicketPushWorkerHistory,
    TicketWorkerRunner,
    WorkerEvidence,
    Worktree
  }

  @kind "HUMAN_EMPTY_COMMIT_IMPORT_V1"
  @identity ~w(run_id issue_key repo_key repo_path worktree branch base_branch contract_sha256 spec_revision verifier_round code_repair_round)
  @unissued ~w(claimed_at thread_id turn_id target_observation_json verified_cwd verified_project_id verified_head_sha output_json rejected_tool_call_id failure_code superseded_by)
  @control ~w(scope status dispatcher_id controller_thread_id controller_codex_project_id controller_model controller_reasoning_effort)
  @enforce_keys [:proof, :push, :history, :at, :owner]
  defstruct @enforce_keys

  @doc "Performs one explicit operator import; prepared caller-supplied maps grant no mutation authority."
  @spec adopt(Store.connection(), String.t(), String.t(), String.t(), String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt(store, run_id, candidate, request_key, authorization_reference, project, opts) do
    with {:ok, prepared} <- prepare(store, run_id, candidate, request_key, authorization_reference, project, opts) do
      apply_prepared(store, prepared, project, opts)
    end
  rescue
    error in RuntimeError ->
      if String.starts_with?(error.message, "factory SQLite transaction failed:"),
        do: {:error, :empty_import_compare_exchange_rejected},
        else: reraise(error, __STACKTRACE__)
  end

  @doc "Observes a clean exact empty child and existing MR through a controller-owned readonly session."
  @spec prepare(Store.connection(), String.t(), String.t(), String.t(), String.t(), pos_integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def prepare(%DBConnection{}, _, _, _, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, run_id, candidate, request_key, authorization_reference, project, opts) do
    with true <- is_binary(authorization_reference) and byte_size(authorization_reference) in 1..1024,
         {:ok, run} <- RunLedger.get(store, run_id),
         true <- run["state"] == "CI_MR_CREATING" or {:error, :empty_import_stage_invalid},
         {:ok, request} <- DesktopRequest.get(store, request_key),
         :ok <- unissued(store, request, run),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         true <- push.intent["kind"] == "TICKET_PUSH" or {:error, :empty_import_physical_push_required},
         true <- Map.has_key?(push.binding, "ci_evidence_successor") or {:error, :empty_import_ci_successor_history_required},
         :ok <- TicketWorkerRunner.delivery_candidate_check(store, run),
         {:ok, history} <- stopped_history(store, run),
         :ok <- TicketCiRepair.stopped_source_observation(store, run, opts),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, run_id),
         scope when is_binary(scope) <- get_in(Jason.decode!(request["metadata_json"]), ["delivery_operation", "scope"]),
         control when is_map(control) <- Control.status(store, scope),
         binding = Jason.decode!(request["metadata_json"])["delivery_operation"],
         true <-
           binding["controller_thread_id"] == control["controller_thread_id"] and binding["controller_project_id"] == control["controller_codex_project_id"] and project == binding["gitlab_project_id"],
         true <- (control["status"] == "ACTIVE" and is_nil(control["tick_id"])) or {:error, :empty_import_controller_busy},
         true <- opts[:project_path] == binding["gitlab_project"] and opts[:workspace] == binding["controller_cwd"],
         {:ok, checkout} <- checkout(run, candidate),
         true <- stringify(checkout) == push.binding["checkout"] or {:error, :empty_import_checkout_changed},
         {:ok, objects} <- TicketHumanEmptyCommitRead.observe(run["worktree"], run["candidate_sha"], candidate),
         {:ok, origin} <- Worktree.origin_identity(%{"path" => run["repo_path"]}, run["worktree"]),
         true <- origin == push.binding["origin"] or {:error, :empty_import_origin_changed},
         {:ok, mr} <- remote_observation(run, candidate, project, opts),
         {:ok, ^run} <- RunLedger.get(store, run_id),
         {:ok, ^request} <- DesktopRequest.get(store, request_key),
         {:ok, ^inputs} <- TicketCiRepair.input_snapshot(store, run_id),
         {:ok, ^history} <- stopped_history(store, run),
         {:ok, ^checkout} <- checkout(run, candidate),
         {:ok, ^mr} <- remote_observation(run, candidate, project, opts),
         :ok <- TicketPush.validate_completed_proof(store, run_id, push) do
      proof = %{
        "version" => 1,
        "kind" => @kind,
        "prior_run" => run,
        "request" => request,
        "authorization_reference" => authorization_reference,
        "objects" => objects,
        "checkout" => stringify(checkout),
        "origin" => origin,
        "mr" => mr,
        "inputs" => inputs,
        "control" => Map.take(control, @control),
        "history" => history,
        "source_checks" => source_checks(store, run_id),
        "observed_at" => now()
      }

      {:ok, %__MODULE__{proof: proof, push: push, history: history, at: System.monotonic_time(:millisecond), owner: self()}}
    else
      {:error, _} = error -> error
      _ -> {:error, :empty_import_observation_unproven}
    end
  end

  defp apply_prepared(store, %__MODULE__{} = prepared, project, opts) do
    with true <- prepared.owner == self() and fresh?(prepared.at),
         run = prepared.proof["prior_run"],
         candidate = get_in(prepared.proof, ["objects", "candidate", "sha"]),
         {:ok, observed} <- checkout(run, candidate),
         true <- stringify(observed) == prepared.proof["checkout"],
         {:ok, objects} <- TicketHumanEmptyCommitRead.observe(run["worktree"], run["candidate_sha"], candidate),
         true <- objects == prepared.proof["objects"],
         :ok <- TicketCiRepair.stopped_source_observation(store, run, opts),
         {:ok, mr} <- remote_observation(run, candidate, project, opts),
         true <- mr == prepared.proof["mr"] do
      TicketPushHazard.with_descendant(store, run["run_id"], candidate, fn tx ->
        case persist(tx, prepared) do
          {:error, reason} -> Exqlite.rollback(tx, reason)
          result -> result
        end
      end)
    else
      _ -> {:error, :empty_import_preparation_expired}
    end
  end

  defp persist(tx, prepared) do
    proof = prepared.proof
    prior = proof["prior_run"]
    request = proof["request"]
    candidate = proof["objects"]["candidate"]["sha"]
    raw = Jason.encode!(proof)
    key = "human-empty-import:" <> digest(raw)

    with true <- TicketPushPayloadBudget.bounded?(proof, :import) and prepared.owner == self() and fresh?(prepared.at),
         {:ok, ^prior} <- RunLedger.get(tx, prior["run_id"]),
         {:ok, ^request} <- DesktopRequest.get(tx, request["request_key"]),
         :ok <- unissued(tx, request, prior),
         :ok <-
           proof_shape(
             %{"run_id" => prior["run_id"], "request_key" => request["request_key"], "candidate_sha" => candidate, "import_key" => key, "proof_json" => raw, "proof_sha256" => digest(raw)},
             proof
           ),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(tx, prior["run_id"]),
         true <- inputs == proof["inputs"],
         control when is_map(control) <- Control.status(tx, proof["control"]["scope"]),
         true <- Map.take(control, @control) == proof["control"] and is_nil(control["tick_id"]),
         {:ok, history} <- stopped_history(tx, prior),
         true <- history == prepared.history and source_checks(tx, prior["run_id"]) == proof["source_checks"],
         :ok <- TicketPush.validate_completed_proof(tx, prior["run_id"], prepared.push),
         nil <- Store.one!(tx, "SELECT import_key FROM ticket_human_empty_commit_imports WHERE run_id=? AND candidate_sha=?", [prior["run_id"], candidate]),
         retired =
           Store.query!(
             tx,
             "UPDATE desktop_requests SET status='FAILED',failure_code=?,updated_at=? WHERE request_key=? AND status='PENDING' AND claimed_at IS NULL AND payload_sha256=? RETURNING request_key",
             [retirement_reason(key), now(), request["request_key"], request["payload_sha256"]]
           ).rows,
         true <- retired == [[request["request_key"]]] do
      Store.query!(tx, "INSERT INTO ticket_human_empty_commit_imports VALUES(?,?,?,?,?,?,?)", [key, prior["run_id"], request["request_key"], candidate, raw, digest(raw), now()])
      envelope = envelope(key, proof)

      {:ok, %{run: updated}} =
        RunLedger.update(tx, prior["run_id"], %{candidate_sha: candidate, ci_preflight_sha: candidate, ci_pipeline_id: nil, ci_pipeline_url: nil, ci_evidence_json: nil, ci_last_checked_at: nil})

      Store.query!(tx, "UPDATE runs SET candidate_handoff=? WHERE run_id=? AND candidate_handoff=?", [Jason.encode!(envelope), prior["run_id"], prior["candidate_handoff"]])

      Store.query!(tx, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES(?,'TICKET_HUMAN_EMPTY_COMMIT_IMPORTED',?,?)", [
        now(),
        prior["run_id"],
        Jason.encode!(%{
          "import_key" => key,
          "prior_candidate_sha" => prior["candidate_sha"],
          "candidate_sha" => candidate,
          "retired_request_key" => request["request_key"],
          "proof_sha256" => digest(raw)
        })
      ])

      {:ok,
       %{
         status: "HUMAN_EMPTY_COMMIT_IMPORTED",
         import_key: key,
         candidate_sha: updated["candidate_sha"],
         prior_candidate_sha: prior["candidate_sha"],
         factory_push_performed: false,
         verifier_pass: false
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :empty_import_preimage_changed}
    end
  end

  @doc "Returns separate physical-push provenance and the imported exact remote binding."
  @spec completed_proof(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def completed_proof(store, run_id) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, imported} <- historical_proof(store, run),
         raw = run["candidate_handoff"],
         {:ok, intent} <- Jason.decode(raw) do
      {:ok, %{intent: intent, binding: Jason.decode!(intent["binding_json"]), envelope: raw, envelope_sha256: digest(raw), run: run, released_access: imported.access, import_row: imported.row}}
    end
  end

  @spec validate_completed_proof(Store.connection(), String.t(), map()) :: :ok | {:error, term()}
  def validate_completed_proof(store, run_id, proof) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- run == proof[:run] and digest(run["candidate_handoff"]) == proof[:envelope_sha256],
         {:ok, imported} <- historical_proof(store, run),
         true <- imported.row == proof[:import_row] and imported.access == proof[:released_access],
         true <- proof[:envelope] == run["candidate_handoff"] and proof[:intent] == Jason.decode!(run["candidate_handoff"]),
         true <- proof[:binding] == Jason.decode!(proof[:intent]["binding_json"]) do
      :ok
    else
      _ -> {:error, :empty_import_proof_changed}
    end
  end

  @doc "Validates retained import bytes and their actual original stopped physical push."
  @spec historical_proof(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def historical_proof(store, run) do
    with {:ok, %{"kind" => @kind, "phase" => "IMPORTED", "import_key" => key} = intent} <- Jason.decode(run["candidate_handoff"] || "null"),
         row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_human_empty_commit_imports WHERE import_key=? AND run_id=?", [key, run["run_id"]]),
         true <- digest(row["proof_json"]) == row["proof_sha256"] and key == "human-empty-import:" <> row["proof_sha256"],
         {:ok, proof} <- TicketPushPayloadBudget.object(row["proof_json"], :import),
         :ok <- proof_shape(row, proof),
         prior = proof["prior_run"],
         true <- Map.take(run, @identity) == Map.take(prior, @identity),
         true <- run["candidate_sha"] == row["candidate_sha"] and intent == envelope(key, proof),
         :ok <- TicketPush.validate_historical_completed_preimage(store, prior),
         physical = Jason.decode!(prior["candidate_handoff"]),
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [physical["reservation_key"]]),
         true <- access["release_receipt_json"] == prior["candidate_handoff"],
         {:ok, request} <- DesktopRequest.get(store, row["request_key"]),
         true <- Map.drop(request, ~w(status failure_code updated_at)) == Map.drop(proof["request"], ~w(status failure_code updated_at)),
         true <- request["status"] == "FAILED" and request["failure_code"] == retirement_reason(key) do
      {:ok, %{row: row, proof: proof, access: access}}
    else
      {:error, _} = error -> error
      _ -> {:error, :empty_import_history_unproven}
    end
  end

  @doc "Source equivalence is not a new controller check receipt or product verifier PASS."
  @spec source_equivalence(Store.connection(), map()) :: :ok | {:error, term()}
  def source_equivalence(store, run) do
    with {:ok, imported} <- historical_proof(store, run),
         prior = imported.proof["prior_run"],
         :ok <- TicketWorkerRunner.delivery_candidate_check(store, prior),
         true <- source_checks(store, run["run_id"]) == imported.proof["source_checks"] do
      :ok
    else
      _ -> {:error, :empty_import_source_equivalence_unproven}
    end
  end

  @spec history(Store.connection(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def history(store, run_id) do
    %{columns: columns, rows: rows} = Store.query!(store, "SELECT * FROM ticket_human_empty_commit_imports WHERE run_id=? ORDER BY import_key", [run_id])
    journal = Enum.map(rows, &Map.new(Enum.zip(columns, &1)))

    Enum.reduce_while(journal, {:ok, []}, fn row, {:ok, saved} ->
      with {:ok, proof} <- TicketPushPayloadBudget.object(row["proof_json"], :import),
           :ok <- proof_shape(row, proof),
           imported = proof["prior_run"] |> Map.put("candidate_sha", row["candidate_sha"]) |> Map.put("candidate_handoff", Jason.encode!(envelope(row["import_key"], proof))),
           {:ok, _} <- historical_proof(store, imported) do
        {:cont, {:ok, saved ++ [row]}}
      else
        _ -> {:halt, {:error, :empty_import_history_unproven}}
      end
    end)
  end

  defp proof_shape(row, proof) do
    prior = proof["prior_run"]
    %{"kind" => "TICKET_PUSH", "phase" => "COMPLETED"} = Jason.decode!(prior["candidate_handoff"])
    objects = proof["objects"]
    candidate = objects["candidate"]
    previous = objects["previous"]

    valid =
      proof["kind"] == @kind and proof["version"] == 1 and row["run_id"] == prior["run_id"] and row["request_key"] == proof["request"]["request_key"] and
        row["candidate_sha"] == candidate["sha"] and previous["sha"] == prior["candidate_sha"] and candidate["parents"] == [previous["sha"]] and candidate["tree"] == previous["tree"] and
        objects["kind"] == "EMPTY_CHILD_OBJECTS_V1" and row["import_key"] == "human-empty-import:" <> digest(row["proof_json"]) and row["proof_sha256"] == digest(row["proof_json"]) and
        proof["mr"]["sha"] == candidate["sha"] and get_in(proof, ["mr", "diff_refs", "head_sha"]) == candidate["sha"] and is_binary(proof["authorization_reference"]) and
        proof["authorization_reference"] != ""

    if valid, do: :ok, else: {:error, :empty_import_history_unproven}
  rescue
    _ -> {:error, :empty_import_history_unproven}
  end

  defp envelope(key, proof) do
    prior = proof["prior_run"]

    binding =
      Map.take(prior, @identity)
      |> Map.merge(%{
        "state" => "CI_PUSHING",
        "candidate_sha" => proof["objects"]["candidate"]["sha"],
        "checkout" => proof["checkout"],
        "origin" => proof["origin"],
        "human_empty_commit_import_key" => key,
        "physical_predecessor_sha256" => digest(prior["candidate_handoff"])
      })

    encoded = Jason.encode!(binding)
    %{"version" => 1, "kind" => @kind, "phase" => "IMPORTED", "import_key" => key, "binding_json" => encoded, "binding_sha256" => digest(encoded)}
  end

  defp unissued(store, request, run) do
    with true <- request["status"] == "PENDING" and Enum.all?(@unissued, &is_nil(request[&1])),
         true <- is_nil(Store.one!(store, "SELECT request_key FROM ticket_mr_claims WHERE request_key=?", [request["request_key"]])),
         true <- SymphonyElixir.Factory.TicketMrOperation.typed_request?(request),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- SymphonyElixir.Factory.TicketMrOperation.validate_request(binding, request),
         true <- binding["stage"] == run["state"],
         true <- Map.take(binding, ~w(run_id candidate_sha contract_sha256 spec_revision)) == Map.take(run, ~w(run_id candidate_sha contract_sha256 spec_revision)),
         true <- binding["completed_push_sha256"] == digest(run["candidate_handoff"]),
         true <- DesktopRequest.payload_intact?(request) do
      :ok
    else
      _ -> {:error, :empty_import_request_not_wholly_unissued}
    end
  end

  defp stopped_history(store, run) do
    with nil <- Store.one!(store, "SELECT reservation_key FROM workspace_access WHERE run_id=? AND released_at IS NULL LIMIT 1", [run["run_id"]]),
         {:ok, history} <- TicketPushWorkerHistory.observe(store, run["run_id"]),
         true <-
           Enum.all?(source_checks(store, run["run_id"]), fn check ->
             check["phase"] == "COMPLETE" and digest(check["binding_json"]) == check["binding_sha256"] and digest(check["receipt_json"]) == check["receipt_sha256"] and
               WorkerEvidence.checks_stopped(store, check["reservation_key"]) == :ok
           end) do
      {:ok, history}
    else
      _ -> {:error, :empty_import_source_not_stopped}
    end
  end

  defp source_checks(store, run_id) do
    %{columns: columns, rows: rows} =
      Store.query!(store, "SELECT c.* FROM controller_checks c JOIN worker_evidence w ON w.request_key=c.worker_request_key WHERE w.run_id=? ORDER BY c.check_key", [run_id])

    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp remote_observation(run, candidate, project, opts) do
    with true <- is_integer(project) and project > 0,
         {:ok, ^candidate} <- Worktree.read_remote_branch(%{"path" => run["repo_path"]}, run["branch"]),
         connector = Keyword.get(opts, :connector, GitLabMcpConnector),
         {:ok, ^candidate} <- connector.branch_head(project, opts[:project_path], run["branch"], opts),
         {:ok, mr} <- CiCollection.collect_mr(run, project, opts),
         true <- mr["sha"] == candidate and get_in(mr, ["diff_refs", "head_sha"]) == candidate,
         true <- mr["state"] == "opened" and mr["draft"] == true and mr["reviewers"] == [],
         true <- mr["source_branch"] == run["branch"] and mr["target_branch"] == run["base_branch"] and mr["web_url"] == run["mr_url"] do
      {:ok, mr}
    else
      _ -> {:error, :empty_import_remote_or_mr_changed}
    end
  end

  defp checkout(run, candidate), do: Worktree.checkout_identity(%{"path" => run["repo_path"]}, run["worktree"], clean: true, detached: false, expected_branch: run["branch"], expected_sha: candidate)
  defp stringify(value), do: Map.new(value, fn {key, item} -> {to_string(key), item} end)
  defp retirement_reason(key), do: "SUPERSEDED_BY_" <> key
  defp digest(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp digest(_), do: nil
  defp fresh?(at), do: is_integer(at) and (System.monotonic_time(:millisecond) - at) in 0..30_000
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
