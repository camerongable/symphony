defmodule SymphonyElixir.FactoryReviewProtocolTest do
  use ExUnit.Case, async: true
  import Kernel, except: [binding: 1]
  alias SymphonyElixir.Factory.{ReviewProtocol, StageSchemas, TicketWorkerRunner}

  defp packet(history \\ []) do
    ReviewProtocol.attach(%{"run_id" => "run", "spec_revision" => 1, "contract_sha256" => "contract", "role" => "change-verifier", "contract" => "AC-1: response. AC-2: value-free logs."}, history)
    |> put_in(["review_protocol", "version"], 1)
  end

  defp output(packet, status \\ "PASS") do
    rows = fn ids, state -> Enum.map(ids, &%{"id" => &1, "status" => state, "evidence" => ["handler.go:42; synthetic boundary test"]}) end
    criteria = packet["review_protocol"]["criterion_ids"]
    obligations = Enum.map(packet["review_protocol"]["finding_obligations"], & &1["id"])
    findings = if status == "REPAIR", do: ["Missing RPC redaction"], else: []

    %{
      "status" => status,
      "candidate_sha" => "candidate",
      "findings" => findings,
      "checks" => ["Exact SHA CI passed"],
      "review_report" => %{
        "version" => 1,
        "candidate_sha" => "candidate",
        "block_reason" => "NONE",
        "criteria" => rows.(criteria, if(status == "REPAIR", do: "FAIL", else: "PASS")),
        "closures" => rows.(obligations, "ADDRESSED"),
        "boundary_sweeps" => Enum.map(rows.(criteria, "CHECKED"), &Map.put(&1, "paths", ["RPC -> service -> provider/cache; success and error paths"])),
        "finding_classifications" => Enum.map(findings, &%{"finding" => &1, "classification" => "NEW"})
      }
    }
  end

  defp binding(packet), do: %{"expected_sha" => "candidate", "schema" => ReviewProtocol.schema(packet, StageSchemas.for_stage(:change_verifier))}
  defp prior(id \\ "finding", admitted \\ true), do: %{"status" => "REPAIR", "finding_entries" => [%{"id" => id, "finding" => "Prior privacy finding"}], "repair_admitted" => admitted}

  test "fresh writers use operational results and retain repair feedback as context" do
    source = Map.drop(packet(), ["review_protocol"]) |> Map.put("role", "feature-writer") |> Map.put("repair_findings", "Repair the supplied finding")
    writer = ReviewProtocol.attach(source, [prior()])
    assert writer == source
    schema = ReviewProtocol.schema(writer, StageSchemas.for_stage(:native_feature_writer))
    refute Map.has_key?(schema["properties"], "review_report")
    result = %{"status" => "CONTINUE", "changed_paths" => ["handler.go"], "commit_message" => "fix: bounded increment", "blockers" => [], "checks" => []}
    assert :ok = ReviewProtocol.validate(writer, %{"schema" => schema}, result)

    for invalid <- [
          Map.delete(result, "changed_paths"),
          Map.put(result, "status", "PASS"),
          Map.put(result, "changed_paths", "handler.go"),
          Map.merge(result, %{"status" => "COMPLETE", "blockers" => ["Needs a decision"]})
        ] do
      assert {:error, :worker_operational_result_invalid} = ReviewProtocol.validate(writer, %{"schema" => schema}, invalid)
    end
  end

  test "retained writer transport accepts surplus advisory closures without accepting verifier claims" do
    writer = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), []) |> Map.put("role", "feature-writer")
    report = typed_result(writer, [], "PASS")["review_report"] |> Map.put("closures", [%{"id" => "PPL-10240-W1", "status" => "ADDRESSED", "evidence" => ["Source increment inspected"]}])
    result = %{"status" => "CONTINUE", "changed_paths" => ["handler.go"], "commit_message" => "fix: bounded increment", "blockers" => [], "checks" => [], "review_report" => report}
    bound = %{"expected_sha" => "candidate", "schema" => ReviewProtocol.schema(writer, StageSchemas.for_stage(:native_feature_writer))}
    assert :ok = StageSchemas.validate(result, bound["schema"])
    assert :ok = ReviewProtocol.validate(writer, bound, result)
    assert {:error, _} = ReviewProtocol.validate(writer, bound, Map.put(result, "status", "PASS"))
  end

  test "typed findings have one authoritative description and observations do not block PASS" do
    packet = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [])
    assert packet["review_protocol"]["version"] == 2
    result = output(packet) |> Map.delete("findings")
    report = result["review_report"] |> Map.delete("finding_classifications") |> Map.put("version", 2) |> Map.put("affected_path_checks", [])

    observation = %{
      "id" => "OBS-1",
      "description" => "A possible readability improvement",
      "classification" => "NEW",
      "disposition" => "OBSERVATION",
      "basis" => %{"kind" => "PREFERENCE", "reference" => "Readability"}
    }

    result = Map.put(result, "review_report", Map.put(report, "findings", [observation]))
    assert :ok = ReviewProtocol.validate(packet, binding(packet), result)
    assert ReviewProtocol.findings(result) == []
    assert :pass = ReviewProtocol.decision(packet, result)
    assert {:error, :review_report_candidate_changed} = ReviewProtocol.validate(packet, binding(packet), put_in(result, ["review_report", "candidate_sha"], "stale"))
    serious = put_in(result, ["review_report", "findings", Access.at(0), "basis"], %{"kind" => "SAFETY_INVARIANT", "reference" => "PRIVACY"})
    assert {:error, :review_report_observation_blocks_acceptance} = ReviewProtocol.validate(packet, binding(packet), serious)
  end

  defp typed_result(packet, rows, status \\ "REPAIR") do
    result = output(packet, status) |> Map.delete("findings")
    ids = packet["review_protocol"]["review_scope"]["criterion_ids"]
    report = result["review_report"] |> Map.delete("finding_classifications") |> Map.merge(%{"version" => 2, "findings" => rows, "affected_path_checks" => []})
    report = Map.update!(report, "criteria", &Enum.filter(&1, fn row -> row["id"] in ids end)) |> Map.update!("boundary_sweeps", &Enum.filter(&1, fn row -> row["id"] in ids end))
    Map.put(result, "review_report", report)
  end

  test "legacy criterion annotations normalize through repair scope while fresh schemas reject them" do
    fresh = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [])
    legacy = update_in(fresh, ["review_protocol"], &Map.delete(&1, "finding_reference_format"))

    finding = %{
      "id" => "F-1",
      "description" => "Required behavior remains unfinished",
      "classification" => "NEW",
      "disposition" => "REQUIRED_REPAIR",
      "basis" => %{"kind" => "ACCEPTANCE_CRITERION", "reference" => "AC-1 / R-3"}
    }

    result = typed_result(legacy, [finding])
    assert :ok = ReviewProtocol.validate(legacy, binding(legacy), result)
    assert [%{"basis" => %{"reference" => "AC-1"}}] = ReviewProtocol.finding_entries(nil, nil, result)
    assert {:error, :review_report_schema_invalid} = ReviewProtocol.validate(fresh, binding(fresh), result)
    canonical = put_in(result, ["review_report", "findings", Access.at(0), "basis", "reference"], "AC-1")
    assert :ok = ReviewProtocol.validate(fresh, binding(fresh), canonical)
    forged = put_in(canonical, ["review_report", "findings", Access.at(0), "basis", "kind"], "SAFETY_INVARIANT")
    assert {:error, :review_report_schema_invalid} = ReviewProtocol.validate(fresh, binding(fresh), forged)

    for reference <- ["AC-99 / R-3", "AC-1 / AC-2", "not AC-1"] do
      invalid = put_in(result, ["review_report", "findings", Access.at(0), "basis", "reference"], reference)
      assert {:error, :review_report_finding_basis_invalid} = ReviewProtocol.validate(legacy, binding(legacy), invalid)
    end

    history = %{
      "request_key" => "prior",
      "output_sha256" => "digest",
      "candidate_sha" => "previous",
      "finding_entries" => [%{"id" => "F-1", "finding" => finding["description"], "basis" => finding["basis"]}],
      "criteria" => Enum.map(["AC-1", "AC-2"], &%{"id" => &1, "status" => "PASS", "evidence" => ["Prior checked boundary"]}),
      "repair_admitted" => true
    }

    focused = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [history])
    assert focused["review_protocol"]["review_scope"]["criterion_ids"] == ["AC-1"]
    unresolved = typed_result(focused, [finding |> Map.put("classification", "UNRESOLVED") |> put_in(["basis", "reference"], "AC-1")])
    unresolved = put_in(unresolved, ["review_report", "closures"], [%{"id" => "F-1", "status" => "UNRESOLVED", "evidence" => ["Not yet repaired"]}])
    assert :ok = ReviewProtocol.validate(focused, binding(focused), unresolved)
  end

  defp focused_writer do
    history = %{
      "status" => "REPAIR",
      "finding_entries" => [%{"id" => "F-1", "finding" => "Prior implementation defect"}],
      "repair_admitted" => true,
      "request_key" => "origin",
      "output_sha256" => "origin-output",
      "candidate_sha" => "prior-candidate",
      "criteria" => [%{"id" => "AC-1", "status" => "PASS", "evidence" => ["prior verified behavior"]}, %{"id" => "AC-2", "status" => "FAIL", "evidence" => ["prior defect"]}]
    }

    writer = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [history]) |> Map.put("role", "feature-writer")
    report = typed_result(writer, [], "PASS")["review_report"]
    report = put_in(report, ["criteria", Access.at(0), "status"], "NOT_CHECKED")
    report = put_in(report, ["boundary_sweeps", Access.at(0)], %{"id" => "AC-1", "status" => "UNAVAILABLE", "evidence" => ["Unchanged area; historical verification only"], "paths" => []})
    report = Map.put(report, "affected_path_checks", [%{"id" => "source implementation", "status" => "CHECKED", "evidence" => ["handler.go:42 repaired source"]}])
    result = %{"status" => "COMPLETE", "changed_paths" => ["handler.go"], "commit_message" => "fix: repair implementation", "blockers" => [], "checks" => ["Tests NOT_RUN"], "review_report" => report}
    {writer, %{"expected_sha" => "candidate", "schema" => ReviewProtocol.schema(writer, StageSchemas.for_stage(:native_feature_writer))}, result}
  end

  test "focused writer readiness preserves honest historical boundaries and supplemental source checks" do
    {writer, binding, result} = focused_writer()
    assert :ok = ReviewProtocol.validate(writer, binding, result)
    assert result["status"] == "COMPLETE"
    assert get_in(result, ["review_report", "criteria", Access.at(0), "status"]) == "NOT_CHECKED"
  end

  @tag writer_adoption_boundary: true
  test "file-only writer can leave supplemental execution pending without claiming verifier acceptance" do
    {writer, binding, result} = focused_writer()
    policy = %{"mode" => "FILE_SOURCE", "profile" => "symphony_ticket_file_source_v1", "source_access" => "read", "file_tools_sha256" => SymphonyElixir.Factory.WorkerFileTools.tool_contract_sha256()}
    binding = Map.put(binding, "policy", policy)

    result =
      update_in(
        result,
        ["review_report", "affected_path_checks"],
        &(&1 ++ [%{"id" => "executable-validation", "status" => "UNAVAILABLE", "evidence" => ["File-only worker cannot execute commands; controller tests are pending."]}])
      )

    assert :ok = ReviewProtocol.validate(writer, binding, result)
    assert get_in(result, ["review_report", "affected_path_checks", Access.at(1), "status"]) == "UNAVAILABLE"

    unchecked_source = put_in(result, ["review_report", "boundary_sweeps", Access.at(1), "status"], "UNAVAILABLE")
    assert :ok = ReviewProtocol.validate(writer, binding, unchecked_source)
    verifier = Map.put(writer, "role", "change-verifier")
    verifier_result = result |> Map.take(~w(checks review_report)) |> Map.merge(%{"status" => "PASS", "candidate_sha" => "candidate"})
    assert {:error, _} = ReviewProtocol.validate(verifier, binding(verifier), verifier_result)
  end

  @tag writer_adoption_boundary: true
  test "verifier still requires every bound affected path to be checked" do
    verifier = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [])
    verifier = put_in(verifier, ["review_protocol", "review_scope", "affected_paths"], ["handler.go"])
    result = typed_result(verifier, [], "PASS")
    result = put_in(result, ["review_report", "affected_path_checks"], [%{"id" => "handler.go", "status" => "CHECKED", "evidence" => ["Inspected exact candidate execution path"]}])
    assert :ok = ReviewProtocol.validate(verifier, binding(verifier), result)

    assert {:error, :review_report_verdict_contradiction} =
             ReviewProtocol.validate(verifier, binding(verifier), put_in(result, ["review_report", "affected_path_checks", Access.at(0), "status"], "UNAVAILABLE"))
  end

  test "retained writer advisory semantics do not establish acceptance or block operational progress" do
    {writer, binding, result} = focused_writer()

    mutations = [
      {"duplicate supplemental ID", update_in(result, ["review_report", "affected_path_checks"], &(&1 ++ &1))},
      {"blank supplemental ID", put_in(result, ["review_report", "affected_path_checks", Access.at(0), "id"], " ")},
      {"empty supplemental evidence", put_in(result, ["review_report", "affected_path_checks", Access.at(0), "evidence"], [])},
      {"unavailable supplemental check", put_in(result, ["review_report", "affected_path_checks", Access.at(0), "status"], "UNAVAILABLE")},
      {"blank path", put_in(result, ["review_report", "boundary_sweeps", Access.at(0), "paths"], [" "])},
      {"checked without path", put_in(result, ["review_report", "boundary_sweeps", Access.at(0), "status"], "CHECKED")},
      {"pass without inspection", put_in(result, ["review_report", "criteria", Access.at(0), "status"], "PASS")},
      {"failed implementation", put_in(result, ["review_report", "criteria", Access.at(1), "status"], "FAIL")},
      {"unresolved closure", put_in(result, ["review_report", "closures", Access.at(0), "status"], "UNRESOLVED")},
      {"stale candidate", put_in(result, ["review_report", "candidate_sha"], "other")},
      {"missing boundary evidence", put_in(result, ["review_report", "boundary_sweeps", Access.at(0), "evidence"], [])}
    ]

    for {name, changed} <- mutations do
      assert :ok = ReviewProtocol.validate(writer, binding, changed), name
    end

    for changed <-
          [
            put_in(writer, ["review_protocol", "review_scope", "mode"], "COMPREHENSIVE"),
            put_in(writer, ["review_protocol", "review_scope", "carried_evidence"], []),
            put_in(writer, ["review_protocol", "review_scope", "carried_evidence", Access.at(0), "criteria", Access.at(0), "status"], "FAIL"),
            put_in(writer, ["review_protocol", "review_scope", "carried_evidence", Access.at(0), "criteria", Access.at(0), "status"], "NOT_CHECKED"),
            put_in(writer, ["review_protocol", "review_scope", "carried_evidence", Access.at(0), "criteria", Access.at(0), "evidence"], []),
            put_in(writer, ["review_protocol", "review_scope", "carried_evidence", Access.at(0), "criteria"], []),
            update_in(writer, ["review_protocol", "review_scope", "carried_evidence"], &(&1 ++ [put_in(hd(&1), ["criteria", Access.at(0), "status"], "FAIL")]))
          ] ++ Enum.map(~w(request_key output_sha256 candidate_sha), &put_in(writer, ["review_protocol", "review_scope", "carried_evidence", Access.at(0), &1], "")) do
      assert :ok = ReviewProtocol.validate(changed, binding, result)
    end

    bound = put_in(writer, ["review_protocol", "review_scope", "affected_paths"], [])
    assert :ok = ReviewProtocol.validate(bound, binding, result)
    assert {:error, :review_protocol_schema_changed} = ReviewProtocol.validate(writer, Map.put(binding, "schema", %{}), result)

    verifier = Map.put(writer, "role", "change-verifier")
    verifier_binding = binding(verifier)
    verifier_result = result |> Map.take(~w(checks review_report)) |> Map.merge(%{"status" => "PASS", "candidate_sha" => "candidate"})
    assert {:error, _} = ReviewProtocol.validate(verifier, verifier_binding, verifier_result)
    verifier_result = put_in(verifier_result, ["review_report", "affected_path_checks"], [])
    assert {:error, _} = ReviewProtocol.validate(verifier, verifier_binding, verifier_result)
  end

  test "writer finding observations remain compatible without granting independent verifier acceptance" do
    {writer, binding, result} = focused_writer()
    report = result["review_report"]
    report = Map.update!(report, "criteria", &Enum.map(&1, fn row -> Map.put(row, "status", "PASS") end))
    report = Map.update!(report, "boundary_sweeps", &Enum.map(&1, fn row -> Map.merge(row, %{"status" => "CHECKED", "paths" => ["handler.go"]}) end))

    finding = %{
      "id" => "NEW",
      "description" => "Writer privacy observation",
      "classification" => "NEW",
      "disposition" => "REQUIRED_REPAIR",
      "basis" => %{"kind" => "SAFETY_INVARIANT", "reference" => "PRIVACY"}
    }

    report = Map.put(report, "findings", [finding])
    assert :ok = ReviewProtocol.validate(writer, binding, Map.put(result, "review_report", report))

    verifier = Map.put(writer, "role", "change-verifier")
    verifier_result = %{"status" => "PASS", "candidate_sha" => "candidate", "checks" => [], "review_report" => Map.put(report, "affected_path_checks", [])}
    assert {:error, :review_report_verdict_contradiction} = ReviewProtocol.validate(verifier, binding(verifier), verifier_result)
  end

  test "focused reviews bind prior provenance and escalate late mandatory findings without a third repair" do
    finding = %{
      "id" => "F-1",
      "description" => "Private value reaches error logger",
      "classification" => "NEW",
      "disposition" => "REQUIRED_REPAIR",
      "basis" => %{"kind" => "ACCEPTANCE_CRITERION", "reference" => "AC-2"}
    }

    first = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [])
    assert first["review_protocol"]["review_scope"]["mode"] == "COMPREHENSIVE"
    assert :ok = ReviewProtocol.validate(first, binding(first), typed_result(first, [finding]))

    history = %{
      "status" => "REPAIR",
      "finding_entries" => [%{"id" => "F-1", "finding" => finding["description"], "basis" => finding["basis"], "disposition" => "REQUIRED_REPAIR"}],
      "repair_admitted" => true,
      "request_key" => "origin",
      "output_sha256" => "origin-output",
      "candidate_sha" => "prior-candidate",
      "criteria" => [%{"id" => "AC-1", "status" => "PASS", "evidence" => ["historical inspection"]}]
    }

    followup = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [history])

    assert followup["review_protocol"]["review_scope"] == %{
             "mode" => "FOCUSED",
             "criterion_ids" => ["AC-2"],
             "carried_evidence" => [Map.take(history, ~w(request_key output_sha256 candidate_sha criteria))]
           }

    regression = finding |> Map.put("classification", "REGRESSION") |> Map.put("description", "Same invariant regressed on affected path")
    result = typed_result(followup, [regression])
    assert :ok = ReviewProtocol.validate(followup, binding(followup), result)
    assert :repair = ReviewProtocol.decision(followup, result)
    reused = put_in(result, ["review_report", "findings", Access.at(0), "classification"], "NEW")
    assert {:error, :review_report_finding_identity_changed} = ReviewProtocol.validate(followup, binding(followup), reused)
    late = typed_result(followup, [Map.put(finding, "id", "NEW-2")])
    assert :ok = ReviewProtocol.validate(followup, binding(followup), late)
    assert {:stop, %{"reason" => "LATE_FINDING_ESCALATION", "repairs_used" => 1}} = ReviewProtocol.decision(followup, late)
    exhausted = put_in(followup, ["review_protocol", "repairs_used"], 2)
    assert {:stop, %{"reason" => "REPAIR_LIMIT", "repairs_used" => 2}} = ReviewProtocol.decision(exhausted, result)
  end

  test "authenticated BLOCK obligations allow honest unresolved reports without spending an automatic repair" do
    blocked = prior("BLOCK-F", false) |> Map.put("status", "BLOCK")
    packet = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [blocked])

    row = %{
      "id" => "BLOCK-F",
      "description" => "Still unresolved",
      "classification" => "UNRESOLVED",
      "disposition" => "REQUIRED_REPAIR",
      "basis" => %{"kind" => "PRIOR_FINDING", "reference" => "BLOCK-F"}
    }

    result = typed_result(packet, [row]) |> put_in(["review_report", "closures", Access.at(0), "status"], "UNRESOLVED")
    assert packet["review_protocol"]["repairs_used"] == 0
    assert :ok = ReviewProtocol.validate(packet, binding(packet), result)
    assert :repair = ReviewProtocol.decision(packet, result)
    invalid = put_in(result, ["review_report", "findings", Access.at(0), "id"], "unknown")
    assert {:error, _} = ReviewProtocol.validate(packet, binding(packet), invalid)
  end

  test "focused PASS cannot omit a criterion that the prior BLOCK never verified" do
    history = %{
      "status" => "BLOCK",
      "repair_admitted" => false,
      "request_key" => "blocked",
      "output_sha256" => "blocked-output",
      "candidate_sha" => "old",
      "finding_entries" => [%{"id" => "F-privacy", "finding" => "Privacy failure", "basis" => %{"kind" => "ACCEPTANCE_CRITERION", "reference" => "AC-1"}}],
      "criteria" => [%{"id" => "AC-1", "status" => "FAIL", "evidence" => ["Defect"]}, %{"id" => "AC-2", "status" => "NOT_CHECKED", "evidence" => ["Environment unavailable"]}]
    }

    packet = ReviewProtocol.attach(Map.drop(packet(), ["review_protocol"]), [history])
    assert packet["review_protocol"]["review_scope"]["criterion_ids"] == ["AC-1", "AC-2"]
    incomplete = typed_result(packet, [], "PASS") |> update_in(["review_report", "criteria"], &Enum.reject(&1, fn row -> row["id"] == "AC-2" end))
    assert {:error, :review_report_criteria_incomplete} = ReviewProtocol.validate(packet, binding(packet), incomplete)
  end

  test "legacy schemas and evidence remain byte-identical" do
    packet = %{"role" => "change-verifier"}
    schema = StageSchemas.for_stage(:change_verifier)
    output = %{"status" => "PASS", "candidate_sha" => "candidate", "findings" => [], "checks" => []}
    assert ReviewProtocol.schema(packet, schema) == schema
    assert :ok = ReviewProtocol.validate(packet, %{"schema" => schema}, output)
    assert :legacy = ReviewProtocol.decision(packet, output)
  end

  test "completion confirmation admits only an honest no-edit completion or blocker" do
    packet = packet() |> Map.put("role", "feature-writer") |> Map.put("completion_confirmation", %{"version" => 1})
    schema = ReviewProtocol.schema(packet, StageSchemas.for_stage(:native_feature_writer))
    result = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => [], "review_report" => output(packet)["review_report"]}
    assert :ok = ReviewProtocol.validate(packet, %{"expected_sha" => "candidate", "schema" => schema}, result)

    for changed <- [Map.put(result, "status", "CONTINUE"), Map.put(result, "changed_paths", ["fixture.txt"]), Map.put(result, "commit_message", "fix(PPL-123): edit")],
        do: assert({:error, _} = ReviewProtocol.validate(packet, %{"expected_sha" => "candidate", "schema" => schema}, changed))

    blocked = result |> Map.put("status", "BLOCKED") |> Map.put("blockers", ["Source is not ready"])
    blocked = put_in(blocked, ["review_report", "block_reason"], "HUMAN_DECISION")
    assert :ok = ReviewProtocol.validate(packet, %{"expected_sha" => "candidate", "schema" => schema}, blocked)
  end

  test "a completion marker cannot lose its no-edit schema through the legacy fallback" do
    packet = %{"role" => "feature-writer", "completion_confirmation" => %{"version" => 1}}
    schema = ReviewProtocol.schema(packet, StageSchemas.for_stage(:native_feature_writer))
    result = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => []}
    assert :ok = ReviewProtocol.validate(packet, %{"schema" => schema}, result)
    assert {:error, _} = ReviewProtocol.validate(packet, %{"schema" => schema}, Map.put(result, "status", "CONTINUE"))
    assert {:error, _} = ReviewProtocol.validate(packet, %{"schema" => schema}, Map.put(result, "changed_paths", ["fixture.txt"]))
    legacy = StageSchemas.for_stage(:native_feature_writer)
    assert {:error, _} = ReviewProtocol.validate(packet, %{"schema" => legacy}, result)
  end

  test "complete candidate-bound first review passes but schema downgrade fails" do
    packet = packet()
    assert :ok = ReviewProtocol.validate(packet, binding(packet), output(packet))
    downgraded = %{"schema" => StageSchemas.for_stage(:change_verifier)}
    assert {:error, _} = ReviewProtocol.validate(packet, downgraded, output(packet))
    assert :pass = ReviewProtocol.decision(packet, output(packet))
  end

  test "blocked resume wrappers retain the admitted structured schema without granting resume authority" do
    packet = packet() |> Map.put("role", "feature-writer")
    legacy = StageSchemas.for_stage(:native_feature_writer)
    expected = ReviewProtocol.schema(packet, legacy)
    native = TicketWorkerRunner.blocked_resume_packet(Jason.encode!(packet), "explicit human instruction", %{"disposition_key" => "stopped"})
    recovery = Jason.encode!(%{"base_packet" => packet, "blocked_writer_context" => %{}, "controller_infrastructure_recovery" => "TCAP-exact", "recovery_instruction" => "bound recovery"})
    failed = Jason.encode!(%{"base_packet" => packet, "controller_failed_turn_recovery" => "TFER-exact", "recovery_instruction" => "bound retry", "preserved_paths" => []})

    for wrapper <- [native, recovery, failed] do
      assert ReviewProtocol.schema_json(wrapper, legacy) == expected
      assert :ok = ReviewProtocol.validate_admission(wrapper, expected)
      assert {:error, :review_protocol_schema_changed} = ReviewProtocol.validate_admission(wrapper, legacy)
    end

    unknown = put_in(packet, ["review_protocol", "version"], 999)
    assert {:error, :review_protocol_unsupported} = ReviewProtocol.validate_admission(Jason.encode!(unknown), legacy)
  end

  test "missing duplicate unknown and cross-candidate evidence cannot pass" do
    packet = packet([prior()])
    original = output(packet)

    mutations = [
      put_in(original, ["review_report", "criteria"], []),
      update_in(original, ["review_report", "criteria"], &(&1 ++ [hd(&1)])),
      put_in(original, ["review_report", "criteria", Access.at(0), "id"], "AC-unknown"),
      put_in(original, ["review_report", "candidate_sha"], "other-candidate"),
      put_in(original, ["review_report", "closures"], []),
      update_in(original, ["review_report", "closures"], &(&1 ++ &1)),
      put_in(original, ["review_report", "closures", Access.at(0), "id"], "other-finding"),
      put_in(original, ["review_report", "criteria", Access.at(0), "evidence"], []),
      put_in(original, ["review_report", "boundary_sweeps", Access.at(0), "paths"], []),
      put_in(original, ["review_report", "boundary_sweeps", Access.at(0), "status"], "UNAVAILABLE"),
      put_in(original, ["review_report", "closures", Access.at(0), "status"], "UNRESOLVED")
    ]

    for changed <- mutations, do: assert({:error, _} = ReviewProtocol.validate(packet, binding(packet), changed))
  end

  test "one initial review allows two repairs and no third admission" do
    first = packet()
    second = packet([prior()])
    third = packet([prior(), prior("finding2")])
    assert :repair = ReviewProtocol.decision(first, output(first, "REPAIR"))
    assert :repair = ReviewProtocol.decision(second, output(second, "REPAIR"))
    assert {:stop, %{"reason" => "REPAIR_LIMIT", "repairs_used" => 2, "repair_attempt_limit" => 2}} = ReviewProtocol.decision(third, output(third, "REPAIR"))
    assert :pass = ReviewProtocol.decision(third, output(third))
  end

  test "an unresolved prior finding stops after the first repair without falsifying the verdict" do
    packet = packet([prior()])
    repaired = output(packet, "REPAIR") |> put_in(["review_report", "closures", Access.at(0), "status"], "UNRESOLVED")
    assert :ok = ReviewProtocol.validate(packet, binding(packet), repaired)
    assert repaired["status"] == "REPAIR"
    assert {:stop, %{"reason" => "UNRESOLVED_FINDING", "repairs_used" => 1}} = ReviewProtocol.decision(packet, repaired)
  end

  test "unresolved classification without a prior repaired finding cannot stop the first review" do
    packet = packet()
    report = output(packet, "REPAIR") |> put_in(["review_report", "finding_classifications", Access.at(0), "classification"], "UNRESOLVED")
    assert {:error, :review_protocol_evidence_incomplete} = ReviewProtocol.validate(packet, binding(packet), report)
    assert :repair = ReviewProtocol.decision(packet, report)
  end

  test "policy stops do not spend another attempt and new snapshots retain lineage" do
    before = packet([prior()])
    after_ci = packet([prior(), prior("stopped-review", false)])
    assert before["review_protocol"]["lineage"] == after_ci["review_protocol"]["lineage"]
    assert after_ci["review_protocol"]["repairs_used"] == 1
    assert :repair = ReviewProtocol.decision(after_ci, output(after_ci, "REPAIR"))
  end

  test "genuine blockers are independent of repair count and a limit alone cannot become BLOCK" do
    packet = packet([prior(), prior("finding2")])
    blocked = output(packet) |> Map.put("status", "BLOCK")
    assert {:error, _} = ReviewProtocol.validate(packet, binding(packet), blocked)

    classification = %{"finding" => "Decision required", "classification" => "NEW"}

    blocked =
      blocked
      |> Map.put("findings", ["Decision required"])
      |> put_in(["review_report", "finding_classifications"], [classification])
      |> put_in(["review_report", "block_reason"], "HUMAN_DECISION")

    assert :ok = ReviewProtocol.validate(packet, binding(packet), blocked)
    assert :block = ReviewProtocol.decision(packet, blocked)
  end

  test "finding classifications cannot omit or duplicate current findings" do
    packet = packet()
    output = output(packet, "REPAIR")
    assert :ok = ReviewProtocol.validate(packet, binding(packet), output)

    for rows <- [[], output["review_report"]["finding_classifications"] ++ output["review_report"]["finding_classifications"]] do
      assert {:error, _} = ReviewProtocol.validate(packet, binding(packet), put_in(output, ["review_report", "finding_classifications"], rows))
    end
  end

  test "CI repair packets and old non-AC fixtures do not acquire ordinary repair requirements" do
    original = %{"role" => "feature-writer", "contract" => "AC-1: behavior", "ci_repair" => %{}}
    assert ReviewProtocol.attach(original, []) == original
    legacy = %{"role" => "feature-writer", "contract" => "Fixture behavior"}
    assert ReviewProtocol.attach(legacy, []) == legacy
  end

  test "new finding IDs follow receipt and index rather than reworded prose" do
    receipt = %{"request_key" => "review", "output_sha256" => "output"}
    id = ReviewProtocol.finding_id("contract", receipt, %{"review_report" => %{}}, 0, "first wording")
    assert id == ReviewProtocol.finding_id("contract", receipt, %{"review_report" => %{}}, 0, "rewritten wording")
    refute id == ReviewProtocol.finding_id("contract", receipt, %{"review_report" => %{}}, 1, "first wording")
  end

  test "unknown protocol versions and writer self-certification cannot pass verification" do
    packet = packet()
    unsupported = put_in(packet, ["review_protocol", "version"], 99)
    result = ReviewProtocol.validate(unsupported, binding(packet), output(packet))
    assert {:error, :review_protocol_unsupported} = result
    writer = Map.put(packet, "role", "feature-writer")
    schema = ReviewProtocol.schema(writer, StageSchemas.for_stage(:native_feature_writer))
    result = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => [], "review_report" => output(packet)["review_report"]}
    assert :ok = ReviewProtocol.validate(writer, %{"schema" => schema, "expected_sha" => "candidate"}, result)

    for protocol <- [Map.put(writer["review_protocol"], "version", 99), %{}, "unsupported"] do
      assert {:error, :review_protocol_unsupported} = ReviewProtocol.validate(Map.put(writer, "review_protocol", protocol), %{"schema" => schema}, result)
    end

    assert {:error, _} = ReviewProtocol.validate(packet, binding(packet), result)
  end

  test "writer observations survive handoff without becoming verifier findings or acceptance" do
    writer = packet() |> Map.put("role", "feature-writer")
    schema = ReviewProtocol.schema(writer, StageSchemas.for_stage(:native_feature_writer))
    report = output(writer)["review_report"] |> Map.put("finding_classifications", [%{"finding" => "RPC interceptor repeats the same privacy leak", "classification" => "NEW"}])
    report = Map.update!(report, "criteria", &Enum.map(&1, fn row -> Map.put(row, "status", "NOT_CHECKED") end))

    result = %{
      "status" => "CONTINUE",
      "changed_paths" => ["handler.go"],
      "commit_message" => "fix(PPL-123): redact RPC logs",
      "blockers" => [],
      "checks" => ["Tests NOT_RUN"],
      "review_report" => report
    }

    binding = %{"schema" => schema, "expected_sha" => "candidate"}
    assert :ok = ReviewProtocol.validate(writer, binding, result)
    assert :ok = ReviewProtocol.validate(writer, binding, Map.put(result, "status", "COMPLETE"))
    failed = put_in(result, ["review_report", "criteria", Access.at(0), "status"], "FAIL")
    assert :ok = ReviewProtocol.validate(writer, binding, Map.put(failed, "status", "COMPLETE"))
    assert {:error, _} = ReviewProtocol.validate(packet(), binding(packet()), result)

    for classifications <- [[%{"finding" => " ", "classification" => "NEW"}], report["finding_classifications"] ++ report["finding_classifications"]] do
      assert :ok = ReviewProtocol.validate(writer, binding, put_in(result, ["review_report", "finding_classifications"], classifications))
    end
  end
end
