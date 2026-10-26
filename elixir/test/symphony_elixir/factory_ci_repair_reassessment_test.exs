defmodule SymphonyElixir.FactoryCiRepairReassessmentTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{CiRepairReassessment, Store, TicketCiRepair}

  setup do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    Store.query!(ctx.store, "UPDATE runs SET state='CI_WAITING',ci_pipeline_id=7,code_repair_round=1 WHERE run_id='run'")
    run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'")
    preimage = Jason.encode!(%{"run" => run, "ci_snapshots" => %{}})
    raw = Jason.encode!(%{"status" => "BLOCKED", "reason" => "UNSUPPORTED_FAILURE"})

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,?,?,?,?,?,?)", [
      "original",
      "run",
      run["candidate_sha"],
      7,
      preimage,
      hash(preimage),
      raw,
      hash(raw),
      "BLOCKED",
      "2026-10-15T00:00:00Z"
    ])

    original = Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key='original'")
    {:ok, store: ctx.store, run: run, original: original}
  end

  test "reassessment is appended once and exact claimed bytes survive ordinary restart", ctx do
    assert CiRepairReassessment.eligible?(ctx.original, ctx.run)
    assert {:ok, ctx.original} == CiRepairReassessment.effective(ctx.store, ctx.original)
    assert :ok = insert(ctx, diagnosis())
    assert {:ok, revised} = CiRepairReassessment.effective(ctx.store, ctx.original)
    assert revised["verdict"] == "REPAIRABLE"
    assert revised["diagnosis_key"] == "original"
    assert revised["collector_version"] == CiRepairReassessment.envelope_version()
    versions = TicketCiRepair.evidence_versions()
    assert Jason.decode!(revised["diagnosis_json"])["evidence_versions"] == versions
    assert Jason.decode!(revised["preimage_json"])["evidence_versions"] == versions
    assert {:error, :ci_reassessment_preimage_changed} = insert(ctx, diagnosis())
    claim = Map.merge(%{"diagnosis_key" => "original"}, CiRepairReassessment.claim_binding(revised))
    assert CiRepairReassessment.claimed(ctx.store, claim) == revised
    assert :ok = Store.initialize(ctx.store)
    assert CiRepairReassessment.claimed(ctx.store, claim) == revised
    assert CiRepairReassessment.claimed(ctx.store, Map.put(claim, "reassessment_sha256", String.duplicate("0", 64))) == nil
    assert CiRepairReassessment.claimed(ctx.store, Map.put(claim, "reassessment_key", "wrong")) == nil
    assert CiRepairReassessment.claimed(ctx.store, %{"diagnosis_key" => "original"}) == ctx.original
    assert Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key='original'") == ctx.original
    assert Store.one!(ctx.store, "SELECT code_repair_round FROM runs WHERE run_id='run'")["code_repair_round"] == 1
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_repair_claims").rows == []

    for sql <- ["UPDATE ticket_ci_repair_reassessments SET verdict='BLOCKED'", "DELETE FROM ticket_ci_repair_reassessments", "DELETE FROM factory_schema_migrations WHERE version=44"] do
      assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql) end
    end
  end

  test "current evidence pair is exact while legacy claimed bytes remain valid", ctx do
    old = diagnosis()
    old_raw = Jason.encode!(old)
    old_key = "ci-reassessment:" <> hash(Jason.encode!(["original", "bounded_pages_v2"]))

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_reassessments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
      old_key,
      "original",
      "bounded_pages_v2",
      hash(Jason.encode!(ctx.original)),
      "run",
      ctx.run["candidate_sha"],
      7,
      ctx.original["preimage_json"],
      ctx.original["preimage_sha256"],
      old_raw,
      hash(old_raw),
      "REPAIRABLE",
      "old",
      "COLLECTOR_REASSESSMENT_V1"
    ])

    legacy = Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key=?", [old_key])
    legacy_claim = Map.merge(%{"diagnosis_key" => "original"}, CiRepairReassessment.claim_binding(legacy))
    assert CiRepairReassessment.claimed(ctx.store, legacy_claim) == legacy
    assert CiRepairReassessment.effective(ctx.store, ctx.original) == {:ok, ctx.original}
    assert :ok = insert(ctx, diagnosis())
    assert {:ok, current} = CiRepairReassessment.effective(ctx.store, ctx.original)
    assert current != legacy
    assert CiRepairReassessment.claimed(ctx.store, legacy_claim) == legacy
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_repair_reassessments").rows |> length() == 2
    assert :ok = Store.initialize(ctx.store)
    assert CiRepairReassessment.claimed(ctx.store, legacy_claim) == legacy
    assert {:ok, ^current} = CiRepairReassessment.effective(ctx.store, ctx.original)
  end

  test "claimed lineage changes deny while the old unsupported policy can be reassessed once", ctx do
    refute CiRepairReassessment.eligible?(ctx.original, Map.put(ctx.run, "candidate_sha", String.duplicate("b", 40)))
    refute CiRepairReassessment.eligible?(ctx.original, Map.put(ctx.run, "contract_sha256", "changed"))
    refute CiRepairReassessment.eligible?(ctx.original, Map.put(ctx.run, "state", "REPAIRING"))
    unsupported = Jason.encode!(%{"status" => "BLOCKED", "reason" => "UNSUPPORTED_FAILURE"})
    assert CiRepairReassessment.eligible?(Map.merge(ctx.original, %{"diagnosis_json" => unsupported, "diagnosis_sha256" => hash(unsupported)}), ctx.run)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim','original','run',1,'{}',?,'now')", [hash("{}")])
    assert {:error, :ci_reassessment_preimage_changed} = insert(ctx, diagnosis())
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_repair_reassessments").rows == []
  end

  test "claimed v3 composite evidence remains exact when v4 becomes current", ctx do
    versions = %{"collector_version" => "bounded_evidence_v3", "assessment_version" => "generic_failures_v1"}
    envelope = "evidence-pair-v1:" <> hash(Jason.encode!([versions["collector_version"], versions["assessment_version"]]))
    key = "ci-reassessment:" <> hash(Jason.encode!(["original", envelope]))
    preimage = Jason.encode!(%{"run" => ctx.run, "ci_snapshots" => %{}, "evidence_versions" => versions})
    raw = Jason.encode!(Map.put(diagnosis(), "evidence_versions", versions))

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_reassessments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
      key,
      "original",
      envelope,
      hash(Jason.encode!(ctx.original)),
      "run",
      ctx.run["candidate_sha"],
      7,
      preimage,
      hash(preimage),
      raw,
      hash(raw),
      "REPAIRABLE",
      "old",
      "COLLECTOR_REASSESSMENT_V1"
    ])

    prior = Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key=?", [key])
    claim = Map.merge(%{"diagnosis_key" => "original"}, CiRepairReassessment.claim_binding(prior))
    assert TicketCiRepair.evidence_versions()["collector_version"] == "bounded_evidence_v4"
    assert CiRepairReassessment.claimed(ctx.store, claim) == prior
    assert CiRepairReassessment.effective(ctx.store, ctx.original) == {:ok, ctx.original}
    assert :ok = insert(ctx, diagnosis())
    assert {:ok, current} = CiRepairReassessment.effective(ctx.store, ctx.original)
    refute current == prior
    assert :ok = Store.initialize(ctx.store)
    assert CiRepairReassessment.claimed(ctx.store, claim) == prior
    assert Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key='original'") == ctx.original
  end

  test "another blocked assessment is retained without polling retries", ctx do
    blocked = %{"status" => "BLOCKED", "reason" => "UNSUPPORTED_FAILURE"}
    assert :ok = insert(ctx, blocked)
    assert {:ok, row} = CiRepairReassessment.effective(ctx.store, ctx.original)
    assert row["verdict"] == "BLOCKED"
    assert {:error, :ci_reassessment_preimage_changed} = insert(ctx, blocked)
  end

  test "correct hashes do not make scalar or malformed JSON objects authoritative", ctx do
    assert :ok = insert(ctx, diagnosis())

    for raw <- ["null", "[]", "7", "false", "{}"] do
      malformed = Map.merge(ctx.original, %{"diagnosis_json" => raw, "diagnosis_sha256" => hash(raw)})
      refute CiRepairReassessment.eligible?(malformed, ctx.run)
      assert {:error, :ci_reassessment_receipt_changed} = CiRepairReassessment.effective(ctx.store, malformed)
    end

    for prior <- [nil, [], 7, false] do
      raw = Jason.encode!(%{"run" => prior})
      malformed = Map.merge(ctx.original, %{"preimage_json" => raw, "preimage_sha256" => hash(raw)})
      refute CiRepairReassessment.eligible?(malformed, ctx.run)
      assert {:error, :ci_reassessment_receipt_changed} = CiRepairReassessment.effective(ctx.store, malformed)
    end
  end

  defp insert(ctx, diagnosis) do
    Store.transaction!(ctx.store, fn tx -> CiRepairReassessment.insert(tx, ctx.original, ctx.run, %{"snapshots" => %{}, "evidence" => %{"pipeline_id" => 7}}, diagnosis) end)
  end

  defp diagnosis, do: %{"status" => "REPAIRABLE", "pipeline_id" => 7, "allowed_writer_paths" => ["pkg/job.go"], "required_generated_paths" => [], "logs" => [], "findings" => []}
  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
