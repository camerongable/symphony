defmodule SymphonyElixir.Factory.ReviewReport do
  @moduledoc "Versioned typed findings and evidence coverage; presentation never owns repair policy."
  alias SymphonyElixir.Factory.StageSchemas

  @invariants ~w(PRIVACY SECURITY CONTRACT_INTEGRITY EXACT_IDENTITY)

  @spec schema(map()) :: map()
  def schema(protocol) do
    text = %{"type" => "string"}
    texts = array(text)

    row = fn ids, statuses, extra ->
      identity = if ids == [], do: text, else: enum(ids)
      object(Map.merge(%{"id" => identity, "status" => enum(statuses), "evidence" => texts}, extra))
    end

    ids = protocol["review_scope"]["criterion_ids"]

    object(%{
      "version" => %{"type" => "integer", "enum" => [2]},
      "candidate_sha" => text,
      "criteria" => array(row.(ids, ~w(PASS FAIL NOT_CHECKED), %{})),
      "closures" => array(row.(Enum.map(protocol["finding_obligations"], & &1["id"]), ~w(ADDRESSED UNRESOLVED SUPERSEDED), %{})),
      "boundary_sweeps" => array(row.(ids, ~w(CHECKED UNAVAILABLE), %{"paths" => texts})),
      "affected_path_checks" => array(row.(Map.get(protocol["review_scope"], "affected_paths", []), ~w(CHECKED UNAVAILABLE), %{})),
      "findings" =>
        array(
          object(%{
            "id" => text,
            "description" => text,
            "classification" => enum(~w(NEW REGRESSION UNRESOLVED)),
            "disposition" => enum(~w(REQUIRED_REPAIR OBSERVATION)),
            "basis" => basis_schema(protocol, text)
          })
        ),
      "block_reason" => enum(~w(NONE CONTRACT_CHANGED HUMAN_DECISION ENVIRONMENT))
    })
  end

  defp basis_schema(%{"finding_reference_format" => "CANONICAL_V1"} = protocol, text) do
    choices = [
      object(%{"kind" => enum(["ACCEPTANCE_CRITERION"]), "reference" => enum(protocol["criterion_ids"])}),
      object(%{"kind" => enum(["SAFETY_INVARIANT"]), "reference" => enum(@invariants)}),
      object(%{"kind" => enum(["PREFERENCE"]), "reference" => text})
    ]

    prior = Enum.map(protocol["finding_obligations"], & &1["id"])
    choices = if prior == [], do: choices, else: choices ++ [object(%{"kind" => enum(["PRIOR_FINDING"]), "reference" => enum(prior)})]
    %{"anyOf" => choices}
  end

  defp basis_schema(_protocol, text), do: object(%{"kind" => enum(~w(ACCEPTANCE_CRITERION SAFETY_INVARIANT PRIOR_FINDING PREFERENCE)), "reference" => text})

  @spec validate(map(), map(), map(), map()) :: :ok | {:error, atom()}
  def validate(packet, binding, output, expected_schema) do
    protocol = packet["review_protocol"]
    report = output["review_report"]

    with :ok <- check(binding["schema"] == expected_schema, :review_protocol_schema_changed),
         :ok <- check(StageSchemas.validate(output, expected_schema) == :ok, :review_report_schema_invalid),
         :ok <- check(valid_scope?(protocol), :review_report_scope_unproven),
         :ok <-
           check(report["candidate_sha"] == binding["expected_sha"] and (packet["role"] != "change-verifier" or output["candidate_sha"] == binding["expected_sha"]), :review_report_candidate_changed),
         :ok <- check(exact_ids?(report["criteria"], protocol["review_scope"]["criterion_ids"]), :review_report_criteria_incomplete),
         :ok <- check(exact_ids?(report["closures"], Enum.map(protocol["finding_obligations"], & &1["id"])), :review_report_closures_incomplete),
         :ok <- check(exact_ids?(report["boundary_sweeps"], protocol["review_scope"]["criterion_ids"]), :review_report_boundaries_incomplete),
         :ok <-
           check(
             affected_paths?(packet, report) and Enum.all?(report["affected_path_checks"], &texts?(&1["evidence"])),
             :review_report_affected_paths_incomplete
           ),
         :ok <-
           check(
             Enum.all?(report["criteria"] ++ report["closures"] ++ report["boundary_sweeps"], &texts?(&1["evidence"])) and
               Enum.all?(report["boundary_sweeps"], &(texts?(&1["paths"]) or (&1["paths"] == [] and historical_boundary?(packet, output, report, &1)))),
             :review_report_evidence_missing
           ),
         :ok <- validate_findings(protocol, report),
         :ok <- check(verdict?(packet, binding, output, report), :review_report_verdict_contradiction) do
      :ok
    end
  end

  defp affected_paths?(packet, report) do
    scope = packet["review_protocol"]["review_scope"]
    rows = report["affected_path_checks"]

    if packet["role"] == "feature-writer" and not Map.has_key?(scope, "affected_paths") do
      Enum.all?(rows, &text?(&1["id"])) and Enum.uniq_by(rows, & &1["id"]) == rows
    else
      exact_ids?(rows, Map.get(scope, "affected_paths", []))
    end
  end

  defp historical_boundary?(%{"role" => "feature-writer"} = packet, %{"status" => "COMPLETE"}, report, %{"status" => "UNAVAILABLE"} = boundary) do
    scope = packet["review_protocol"]["review_scope"]
    criterion = Enum.find(report["criteria"], &(&1["id"] == boundary["id"]))

    latest =
      Enum.reduce(scope["carried_evidence"], nil, fn origin, previous ->
        case Enum.find(origin["criteria"] || [], &(&1["id"] == boundary["id"])) do
          nil -> previous
          row -> {row, origin}
        end
      end)

    scope["mode"] == "FOCUSED" and criterion["status"] == "NOT_CHECKED" and texts?(boundary["evidence"]) and
      case latest do
        {%{"status" => "PASS"} = row, origin} -> texts?(row["evidence"]) and Enum.all?(~w(request_key output_sha256 candidate_sha), &text?(origin[&1]))
        _ -> false
      end
  end

  defp historical_boundary?(_, _, _, _), do: false

  defp valid_scope?(protocol) do
    scope = protocol["review_scope"]
    active = scope["criterion_ids"]
    all = protocol["criterion_ids"]
    omitted = all -- active

    latest =
      Enum.reduce(scope["carried_evidence"], %{}, fn origin, acc ->
        Enum.reduce(origin["criteria"] || [], acc, fn row, current -> Map.put(current, row["id"], {row, origin}) end)
      end)

    Enum.uniq(active) == active and Enum.all?(active, &(&1 in all)) and
      ((scope["mode"] == "COMPREHENSIVE" and omitted == []) or
         (scope["mode"] == "FOCUSED" and
            Enum.all?(omitted, fn id ->
              case latest[id] do
                {%{"status" => "PASS"} = row, origin} -> texts?(row["evidence"]) and Enum.all?(~w(request_key output_sha256 candidate_sha), &text?(origin[&1]))
                _ -> false
              end
            end)))
  end

  @spec findings(map()) :: [String.t()]
  def findings(output), do: output["review_report"]["findings"] |> Enum.filter(&(&1["disposition"] == "REQUIRED_REPAIR")) |> Enum.map(& &1["description"])

  @spec entries(map()) :: [map()]
  def entries(output) do
    output["review_report"]["findings"]
    |> Enum.filter(&(&1["disposition"] == "REQUIRED_REPAIR"))
    |> Enum.map(&%{"id" => &1["id"], "finding" => &1["description"], "basis" => normalize_basis(&1["basis"]), "disposition" => &1["disposition"]})
  end

  defp validate_findings(protocol, report) do
    rows = report["findings"]
    known = Map.new(protocol["finding_obligations"], &{&1["id"], &1})
    unresolved = report["closures"] |> Enum.filter(&(&1["status"] == "UNRESOLVED")) |> Enum.map(& &1["id"])

    with :ok <- check(Enum.all?(rows, &(text?(&1["id"]) and text?(&1["description"]))) and Enum.uniq_by(rows, & &1["id"]) == rows, :review_report_finding_id_invalid),
         :ok <- check(Enum.all?(rows, &basis?(&1, protocol, known)), :review_report_finding_basis_invalid),
         :ok <- check(Enum.all?(rows, &(&1["disposition"] != "OBSERVATION" or &1["basis"]["kind"] == "PREFERENCE")), :review_report_observation_blocks_acceptance),
         :ok <-
           check(
             Enum.all?(rows, fn row ->
               if row["classification"] == "NEW", do: not Map.has_key?(known, row["id"]), else: Map.has_key?(known, row["id"]) and compatible?(known[row["id"]], row)
             end),
             :review_report_finding_identity_changed
           ),
         :ok <- check(Enum.sort(Enum.map(Enum.filter(rows, &(&1["classification"] == "UNRESOLVED")), & &1["id"])) == Enum.sort(unresolved), :review_report_unresolved_unproven) do
      :ok
    end
  end

  @spec criterion_reference(term()) :: String.t() | nil
  def criterion_reference(reference) when is_binary(reference) do
    case Regex.run(~r/\A(AC-[0-9]+)(?:\s*\/\s*R-[0-9]+)?\z/, reference) do
      [_, criterion] -> criterion
      _ -> nil
    end
  end

  def criterion_reference(_reference), do: nil

  defp normalize_basis(%{"kind" => "ACCEPTANCE_CRITERION", "reference" => ref} = basis), do: Map.put(basis, "reference", criterion_reference(ref) || ref)
  defp normalize_basis(basis), do: basis

  defp compatible?(prior, row), do: row["disposition"] == "REQUIRED_REPAIR" and (is_nil(prior["basis"]) or normalize_basis(prior["basis"]) == normalize_basis(row["basis"]))
  defp basis?(%{"basis" => %{"kind" => "ACCEPTANCE_CRITERION", "reference" => ref}, "disposition" => "REQUIRED_REPAIR"}, protocol, _known), do: criterion_reference(ref) in protocol["criterion_ids"]
  defp basis?(%{"basis" => %{"kind" => "SAFETY_INVARIANT", "reference" => ref}}, _protocol, _known), do: ref in @invariants
  defp basis?(%{"id" => id, "basis" => %{"kind" => "PRIOR_FINDING", "reference" => ref}, "disposition" => "REQUIRED_REPAIR"}, _protocol, known), do: id == ref and Map.has_key?(known, id)
  defp basis?(%{"basis" => %{"kind" => "PREFERENCE", "reference" => ref}, "disposition" => "OBSERVATION"}, _protocol, _known), do: text?(ref)
  defp basis?(_, _, _), do: false

  defp verdict?(%{"role" => "change-verifier"}, _binding, output, report) do
    required = findings(output)
    checked = Enum.all?(report["boundary_sweeps"] ++ report["affected_path_checks"], &(&1["status"] == "CHECKED"))
    closed = Enum.all?(report["closures"], &(&1["status"] != "UNRESOLVED"))

    case output["status"] do
      "PASS" -> required == [] and closed and checked and report["block_reason"] == "NONE" and Enum.all?(report["criteria"], &(&1["status"] == "PASS"))
      "REPAIR" -> required != [] and checked and report["block_reason"] == "NONE" and Enum.all?(report["criteria"], &(&1["status"] in ~w(PASS FAIL)))
      "BLOCK" -> required != [] and report["block_reason"] in ~w(CONTRACT_CHANGED HUMAN_DECISION ENVIRONMENT)
    end
  end

  defp verdict?(%{"role" => "feature-writer"} = packet, binding, output, report) do
    output["status"] != "COMPLETE" or
      (output["blockers"] == [] and report["block_reason"] == "NONE" and Enum.all?(report["criteria"], &(&1["status"] in ~w(PASS NOT_CHECKED))) and
         Enum.all?(report["closures"], &(&1["status"] != "UNRESOLVED")) and
         Enum.all?(report["affected_path_checks"], &writer_supplemental_check?(packet, binding, &1)) and
         Enum.all?(report["boundary_sweeps"], &(&1["status"] == "CHECKED" or historical_boundary?(packet, output, report, &1))))
  end

  defp writer_supplemental_check?(_packet, _binding, %{"status" => "CHECKED"}), do: true

  defp writer_supplemental_check?(packet, %{"policy" => %{"mode" => "FILE_SOURCE", "profile" => "symphony_ticket_file_source_v1", "source_access" => "read", "file_tools_sha256" => hash}}, %{
         "status" => "UNAVAILABLE"
       }) do
    not Map.has_key?(packet["review_protocol"]["review_scope"], "affected_paths") and
      hash == SymphonyElixir.Factory.WorkerFileTools.tool_contract_sha256()
  end

  defp writer_supplemental_check?(_packet, _binding, _check), do: false

  defp exact_ids?(rows, ids), do: Enum.sort(Enum.map(rows, & &1["id"])) == Enum.sort(ids)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp texts?(values), do: is_list(values) and values != [] and Enum.all?(values, &text?/1)
  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
  defp enum(values), do: %{"type" => "string", "enum" => values}
  defp array(value), do: %{"type" => "array", "items" => value}
  defp object(properties), do: %{"type" => "object", "additionalProperties" => false, "required" => Enum.sort(Map.keys(properties)), "properties" => properties}
end
