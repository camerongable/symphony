defmodule SymphonyElixir.Factory.TicketPushPreissuanceRejection do
  @moduledoc "Exact audited preissuance dispositions with separately issued successors."
  alias SymphonyElixir.Factory.{
    CiRepairReassessment,
    RunLedger,
    Store,
    TicketPush,
    TicketPushIO,
    TicketPushOrdinaryRejection,
    TicketPushRecovery,
    WorkspaceAccess,
    Worktree
  }

  @resource Path.expand("../../../priv/ticket_push_rejection_v1.json", __DIR__)
  @external_resource @resource
  @resource_sha :crypto.hash(:sha256, File.read!(@resource)) |> Base.encode16(case: :lower)
  @import_resource Path.expand("../../../priv/ticket_push_rejection_v2.json", __DIR__)
  @external_resource @import_resource
  @import_resource_sha :crypto.hash(:sha256, File.read!(@import_resource)) |> Base.encode16(case: :lower)
  @generation_resource Path.expand("../../../priv/ticket_push_rejection_v3.json", __DIR__)
  @external_resource @generation_resource
  @generation_resource_sha :crypto.hash(:sha256, File.read!(@generation_resource)) |> Base.encode16(case: :lower)

  defp audits do
    for {name, expected, kind} <- [
          {"ticket_push_rejection_v1.json", @resource_sha, "AUDITED_V3_PREISSUANCE_AUTHORITY_CLOSED"},
          {"ticket_push_rejection_v2.json", @import_resource_sha, "AUDITED_V7_PREISSUANCE_AUTHORITY_CLOSED"},
          {"ticket_push_rejection_v3.json", @generation_resource_sha, "AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED"}
        ],
        {:ok, raw} <- [File.read(Application.app_dir(:symphony_elixir, "priv/" <> name))],
        digest(raw) == expected,
        {:ok, %{"kind" => ^kind} = value} <- [Jason.decode(raw)] do
      {value, expected}
    end
  end

  defp original_audit(original_sha) do
    case Enum.filter(audits(), fn {audit, _} -> audit["original_sha256"] == original_sha end) do
      [{audit, sha}] -> {:ok, audit, sha}
      _ -> {:error, :push_rejection_audit_changed}
    end
  end

  @spec audit() :: {:ok, map()} | {:error, atom()}
  def audit do
    with {:ok, raw} <- File.read(Application.app_dir(:symphony_elixir, "priv/ticket_push_rejection_v1.json")),
         true <- digest(raw) == @resource_sha,
         {:ok, %{"kind" => "AUDITED_V3_PREISSUANCE_AUTHORITY_CLOSED"} = value} <- Jason.decode(raw) do
      {:ok, value}
    else
      _ -> {:error, :push_rejection_audit_changed}
    end
  end

  @spec eligible?(map()) :: boolean()
  def eligible?(run) do
    TicketPushOrdinaryRejection.eligible?(run) or legacy_eligible?(run)
  end

  defp legacy_eligible?(run) do
    case original_audit(digest(run["candidate_handoff"])) do
      {:ok, audit, _sha} ->
        Map.take(run, ~w(run_id candidate_sha contract_sha256 code_repair_round)) ==
          Map.take(audit, ~w(run_id candidate_sha contract_sha256 code_repair_round)) and
          run["state"] == "CI_PUSHING" and digest(run["candidate_handoff"]) == audit["original_sha256"]

      _ ->
        false
    end
  end

  @spec status_execution?(map()) :: boolean()
  def status_execution?(execution) do
    TicketPushOrdinaryRejection.status_execution?(execution) or
      Enum.any?(audits(), fn {audit, _sha} ->
        digest(Jason.encode!(execution)) == audit["execution_sha256"] and
          Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256)) ==
            Map.take(audit, ~w(helper_path helper_sha256 companion_path companion_sha256))
      end)
  end

  @doc "Proves the audited v3 rejection branch cannot later issue a push; this is not an owned-exit receipt."
  @spec closed_authority(map(), map()) :: {:ok, map()} | {:error, term()}
  def closed_authority(run, intent) do
    if TicketPushOrdinaryRejection.eligible?(run),
      do: TicketPushOrdinaryRejection.closed_authority(run, intent),
      else: legacy_closed_authority(run, intent)
  end

  defp legacy_closed_authority(run, intent) do
    with true <- eligible?(run),
         {:ok, audit, audit_sha} <- original_audit(digest(run["candidate_handoff"])),
         true <- {intent["helper_pid"], intent["owner_nonce"]} == {audit["helper_pid"], audit["original_nonce"]},
         true <- digest(intent["execution_json"]) == audit["execution_sha256"],
         {:ok, raw} <- TicketPushIO.readback(intent),
         {:ok, reason} <- TicketPushIO.rejection_reason(raw, intent),
         true <- reason == audit["reason"],
         true <- digest(raw) == audit["rejection_sha256"],
         :ok <- stopped_import_helper(audit),
         :ok <- remote_import_preimage(run, audit) do
      {:ok,
       %{
         "kind" => audit["kind"],
         "audit_sha256" => audit_sha,
         "rejection_json" => raw,
         "rejection_sha256" => digest(raw)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :push_rejection_authority_unproven}
    end
  end

  defp stopped_import_helper(%{"kind" => kind, "helper_pid" => pid}) when kind in ["AUDITED_V7_PREISSUANCE_AUTHORITY_CLOSED", "AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED"] do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "pid="], stderr_to_stdout: true) do
      {"", 1} -> :ok
      _ -> {:error, :push_rejection_helper_stop_unproven}
    end
  end

  defp stopped_import_helper(_audit), do: :ok

  defp remote_import_preimage(run, %{"kind" => kind} = audit) when kind in ["AUDITED_V7_PREISSUANCE_AUTHORITY_CLOSED", "AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED"] do
    expected = audit["expected_remote_sha"]

    case Worktree.read_remote_branch(%{"path" => run["repo_path"]}, run["branch"]) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :push_rejection_remote_changed}
    end
  end

  defp remote_import_preimage(_run, _audit), do: :ok

  defp claim_admitted(store, saved, proof) do
    case {proof["kind"], CiRepairReassessment.claimed(store, saved)} do
      {"AUDITED_V3_PREISSUANCE_AUTHORITY_CLOSED", %{"verdict" => "REPAIRABLE", "reassessment_key" => key}} when is_binary(key) -> :ok
      {"AUDITED_V7_PREISSUANCE_AUTHORITY_CLOSED", %{"verdict" => "REPAIRABLE"}} -> :ok
      {"AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED", %{"verdict" => "REPAIRABLE"}} -> :ok
      _ -> {:error, :push_rejection_lineage_unproven}
    end
  end

  @spec rearm(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def rearm(%DBConnection{}, _run_id, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  def rearm(store, run_id, authorization, opts) do
    case RunLedger.get(store, run_id) do
      {:ok, run} ->
        if TicketPushOrdinaryRejection.eligible?(run),
          do: TicketPushOrdinaryRejection.rearm(store, run_id, authorization, opts),
          else: legacy_rearm(store, run_id, authorization, opts)

      error ->
        error
    end
  end

  defp legacy_rearm(store, run_id, authorization, opts) do
    with true <- opts[:ordinary_controller_tick] == true or {:error, :push_rejection_normal_tick_required},
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         {:ok, observed} <-
           TicketPush.recovery_observation(store, run_id, current_envelope(store, run_id), authorization, opts),
         {:ok, proof} <- closed_authority(observed.run, observed.intent),
         claim when is_map(claim) <-
           Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [
             run_id,
             observed.run["code_repair_round"]
           ]),
         {:ok, saved} <- Jason.decode(claim["claim_json"]),
         :ok <- claim_admitted(store, saved, proof),
         :ok <- CiRepairReassessment.validate_claim(store, saved),
         {:ok, _preflight} <- TicketPushIO.prepare(store, observed.intent, authorization, opts) do
      commit_plan(store, observed, claim, saved, tick, plan(observed, claim, proof), authorization, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :push_rejection_lineage_unproven}
    end
  end

  defp commit_plan(store, observed, claim, saved, tick, plan, authorization, opts) do
    WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
      with {:ok, ^tick} <- TicketPushRecovery.tick_binding(tx, opts),
           :ok <- TicketPush.recheck_recovery_observation(tx, observed, access, authorization, opts),
           ^claim <- Store.one!(tx, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?", [claim["claim_key"]]),
           :ok <- CiRepairReassessment.validate_claim(tx, saved),
           nil <-
             Store.one!(
               tx,
               "SELECT retirement_key FROM ticket_push_rejection_retirements WHERE run_id=? AND candidate_sha=? AND code_repair_round=? AND claim_key=?",
               [observed.run["run_id"], plan["candidate_sha"], plan["code_repair_round"], plan["claim_key"]]
             ) do
        append_successor(tx, observed, access, plan, opts)
      else
        {:error, _} = error -> error
        _ -> {:error, :push_rejection_preimage_changed}
      end
    end)
  end

  defp append_successor(tx, observed, access, plan, opts) do
    fields =
      ~w(retirement_key run_id candidate_sha code_repair_round claim_key original_nonce original_envelope original_sha256 proof_json proof_sha256 successor_nonce successor_binding_sha256 successor_reservation_key created_at)

    Store.query!(tx, "INSERT INTO ticket_push_rejection_retirements VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", Enum.map(fields, &plan[&1]))
    run_id = observed.run["run_id"]

    with {:ok, successor} <- WorkspaceAccess.transfer_preissuance_rejection(tx, plan, access, opts),
         intent = successor_intent(observed.intent, plan, successor),
         [[^run_id]] <-
           Store.query!(tx, "UPDATE runs SET candidate_handoff=? WHERE run_id=? AND candidate_handoff=? RETURNING run_id", [Jason.encode!(intent), run_id, observed.run["candidate_handoff"]]).rows do
      {:ok, %{status: "PUSH_REJECTION_RETIRED", run_id: run_id, successor_nonce: intent["owner_nonce"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :push_rejection_preimage_changed}
    end
  end

  defp current_envelope(store, run_id) do
    case RunLedger.get(store, run_id) do
      {:ok, run} -> run["candidate_handoff"]
      _ -> nil
    end
  end

  defp plan(observed, claim, proof) do
    original = observed.run["candidate_handoff"]
    key = "push-rejection:" <> digest(original <> proof["rejection_sha256"])
    identity = %{"retirement_key" => key, "original_sha256" => digest(original), "attempt" => 1}
    encoded = observed.binding |> Map.put("preissuance_retirement", identity) |> Jason.encode!()
    raw = Jason.encode!(proof)

    %{
      "retirement_key" => key,
      "run_id" => observed.run["run_id"],
      "candidate_sha" => observed.run["candidate_sha"],
      "code_repair_round" => observed.run["code_repair_round"],
      "claim_key" => claim["claim_key"],
      "original_nonce" => observed.intent["owner_nonce"],
      "original_envelope" => original,
      "original_sha256" => digest(original),
      "proof_json" => raw,
      "proof_sha256" => digest(raw),
      "successor_nonce" => digest(key <> ":successor:1"),
      "successor_binding_sha256" => digest(encoded),
      "successor_reservation_key" => "ticket-push:" <> digest(encoded),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp successor_intent(intent, plan, access) do
    binding =
      Jason.decode!(intent["binding_json"]) |> Map.put("preissuance_retirement", identity(plan)) |> Jason.encode!()

    Map.merge(intent, %{
      "phase" => "PREPARED",
      "owner_nonce" => plan["successor_nonce"],
      "binding_json" => binding,
      "binding_sha256" => plan["successor_binding_sha256"],
      "reservation_key" => access["reservation_key"],
      "reservation_generation" => access["generation"],
      "helper_pid" => nil,
      "execution_json" => nil
    })
  end

  @spec bind(Store.connection(), map(), map()) :: map()
  def bind(store, run, binding) do
    case Store.one!(
           store,
           "SELECT * FROM ticket_push_rejection_retirements WHERE run_id=? AND candidate_sha=? AND code_repair_round=?",
           [run["run_id"], run["candidate_sha"], run["code_repair_round"]]
         ) do
      nil ->
        binding

      row ->
        successor = Map.put(binding, "preissuance_retirement", identity(row))
        if digest(Jason.encode!(successor)) == row["successor_binding_sha256"], do: successor, else: binding
    end
  end

  @spec current(Store.connection(), map(), map(), map()) :: :ok | {:error, atom()}
  def current(store, run, intent, %{"preissuance_retirement" => ref}) do
    with row when is_map(row) <-
           Store.one!(store, "SELECT * FROM ticket_push_rejection_retirements WHERE retirement_key=?", [
             ref["retirement_key"]
           ]),
         true <- identity(row) == ref,
         true <-
           Map.take(row, ~w(run_id candidate_sha code_repair_round)) ==
             Map.take(run, ~w(run_id candidate_sha code_repair_round)),
         true <-
           {intent["owner_nonce"], intent["binding_sha256"], intent["reservation_key"]} ==
             {row["successor_nonce"], row["successor_binding_sha256"], row["successor_reservation_key"]},
         true <-
           digest(row["original_envelope"]) == row["original_sha256"] and
             digest(row["proof_json"]) == row["proof_sha256"],
         :ok <- validate_retirement(row),
         {:ok, proof} <- Jason.decode(row["proof_json"]),
         {:ok, audit, audit_sha} <- original_audit(row["original_sha256"]),
         true <-
           proof["audit_sha256"] == audit_sha and proof["rejection_sha256"] == audit["rejection_sha256"] and
             digest(proof["rejection_json"]) == audit["rejection_sha256"],
         {:ok, original} <- Jason.decode(row["original_envelope"]),
         true <- original["owner_nonce"] == row["original_nonce"] and row["original_sha256"] == audit["original_sha256"],
         {:ok, access} <- WorkspaceAccess.get(store, original["reservation_key"]),
         true <- not is_nil(access["released_at"]) and access["release_receipt_json"] == row["proof_json"] do
      :ok
    else
      _ -> {:error, :push_rejection_lineage_changed}
    end
  end

  def current(store, run, _intent, _binding) do
    row =
      Store.one!(store, "SELECT * FROM ticket_push_rejection_retirements WHERE run_id=? AND candidate_sha=? AND code_repair_round=?", [run["run_id"], run["candidate_sha"], run["code_repair_round"]])

    with %{} <- row,
         {:ok, original} <- Jason.decode(row["original_envelope"]),
         {:ok, binding} <- Jason.decode(original["binding_json"]),
         true <- Map.take(binding, ~w(state spec_revision contract_sha256 verifier_round)) == Map.take(run, ~w(state spec_revision contract_sha256 verifier_round)) do
      {:error, :push_rejection_lineage_changed}
    else
      _ -> :ok
    end
  end

  @spec validate_retirement(map()) :: :ok | {:error, atom()}
  def validate_retirement(row) do
    with {:ok, audit, audit_sha} <- original_audit(row["original_sha256"]),
         true <-
           Map.take(row, ~w(run_id candidate_sha code_repair_round original_nonce original_sha256)) ==
             Map.take(audit, ~w(run_id candidate_sha code_repair_round original_nonce original_sha256)),
         true <-
           digest(row["original_envelope"]) == audit["original_sha256"] and
             digest(row["proof_json"]) == row["proof_sha256"],
         {:ok, proof} <- Jason.decode(row["proof_json"]),
         true <- proof["kind"] == audit["kind"] and proof["audit_sha256"] == audit_sha,
         true <-
           proof["rejection_sha256"] == audit["rejection_sha256"] and
             digest(proof["rejection_json"]) == audit["rejection_sha256"] do
      :ok
    else
      _ -> {:error, :push_rejection_proof_changed}
    end
  end

  @spec identity(map()) :: map()
  def identity(row),
    do: %{"retirement_key" => row["retirement_key"], "original_sha256" => row["original_sha256"], "attempt" => 1}

  defp digest(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp digest(_), do: nil
end
