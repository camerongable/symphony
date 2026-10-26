defmodule SymphonyElixir.Factory.CiRepairReassessment do
  @moduledoc "Append-only evidence reassessment. The legacy collector_version column holds the ordered collector/assessment envelope identity; claimed historical bytes remain independent of current policy."
  alias SymphonyElixir.Factory.{Store, TicketCiRepair}

  @spec envelope_version() :: String.t()
  def envelope_version do
    versions = TicketCiRepair.evidence_versions()
    "evidence-pair-v1:" <> digest(Jason.encode!([versions["collector_version"], versions["assessment_version"]]))
  end

  @spec eligible?(map(), map()) :: boolean()
  def eligible?(row, run) do
    with true <- valid?(row),
         true <- row["verdict"] == "BLOCKED" and run["state"] == "CI_WAITING",
         true <- Map.take(row, ~w(run_id candidate_sha pipeline_id)) == %{"run_id" => run["run_id"], "candidate_sha" => run["candidate_sha"], "pipeline_id" => run["ci_pipeline_id"]},
         {:ok, diagnosis} <- Jason.decode(row["diagnosis_json"]),
         {:ok, %{"run" => prior}} <- Jason.decode(row["preimage_json"]) do
      diagnosis["evidence_versions"] != TicketCiRepair.evidence_versions() and
        Map.drop(prior, ~w(updated_at ci_last_checked_at ci_evidence_json)) == Map.drop(run, ~w(updated_at ci_last_checked_at ci_evidence_json))
    else
      _ -> false
    end
  end

  @spec effective(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def effective(store, original) do
    case Store.one!(store, "SELECT * FROM ticket_ci_repair_reassessments WHERE diagnosis_key=? AND collector_version=?", [original["diagnosis_key"], envelope_version()]) do
      nil -> {:ok, original}
      row -> validate(row, original)
    end
  end

  @spec claimed(Store.connection(), map()) :: map() | nil
  def claimed(store, claim) do
    original = Store.one!(store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key=?", [claim["diagnosis_key"]])

    case {original, claim["reassessment_key"], claim["reassessment_sha256"]} do
      {%{} = row, nil, nil} ->
        row

      {%{}, key, expected} when is_binary(key) and is_binary(expected) ->
        with %{} = row <- Store.one!(store, "SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key=?", [key]),
             true <- digest(Jason.encode!(row)) == expected,
             {:ok, validated} <- validate(row, original) do
          validated
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec claim_binding(map()) :: map()
  def claim_binding(%{"reassessment_key" => key} = row), do: %{"reassessment_key" => key, "reassessment_sha256" => digest(Jason.encode!(row))}
  def claim_binding(_row), do: %{}

  @spec validate_claim(Store.connection(), map()) :: :ok | {:error, atom()}
  def validate_claim(store, claim) do
    if is_nil(claim["reassessment_key"]) and is_nil(claim["reassessment_sha256"]) do
      :ok
    else
      case claimed(store, claim) do
        %{"verdict" => "REPAIRABLE", "diagnosis_json" => raw} ->
          {:ok, diagnosis} = Jason.decode(raw)

          validate_scope(claim, diagnosis)

        _ ->
          {:error, :ci_reassessment_receipt_changed}
      end
    end
  end

  defp validate_scope(claim, diagnosis) do
    if Map.take(claim, ~w(allowed_writer_paths required_generated_paths)) == Map.take(diagnosis, ~w(allowed_writer_paths required_generated_paths)),
      do: :ok,
      else: {:error, :ci_reassessment_receipt_changed}
  end

  @spec unchanged?(Store.connection(), map()) :: boolean()
  def unchanged?(store, %{"reassessment_key" => key} = row) do
    original = Store.one!(store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key=?", [row["diagnosis_key"]])
    Store.one!(store, "SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key=?", [key]) == row and is_map(original) and validate(row, original) == {:ok, row}
  end

  def unchanged?(store, row), do: Store.one!(store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key=?", [row["diagnosis_key"]]) == row

  @spec insert(DBConnection.t(), map(), map(), map(), map()) :: :ok | {:error, atom()}
  def insert(%DBConnection{} = tx, original, run, collected, diagnosis) do
    with true <- eligible?(original, run),
         true <- unchanged?(tx, original),
         true <- Store.one!(tx, "SELECT * FROM runs WHERE run_id=?", [run["run_id"]]) == run,
         nil <- Store.one!(tx, "SELECT claim_key FROM ticket_ci_repair_claims WHERE diagnosis_key=?", [original["diagnosis_key"]]),
         nil <- Store.one!(tx, "SELECT reassessment_key FROM ticket_ci_repair_reassessments WHERE diagnosis_key=? AND collector_version=?", [original["diagnosis_key"], envelope_version()]),
         {:ok, diagnosis} <- TicketCiRepair.bounded_diagnosis(Map.put(diagnosis, "evidence_versions", TicketCiRepair.evidence_versions())) do
      version = envelope_version()
      key = key(original["diagnosis_key"], version)
      preimage = Jason.encode!(%{"run" => run, "ci_snapshots" => collected["snapshots"], "evidence_versions" => TicketCiRepair.evidence_versions()})
      raw = Jason.encode!(diagnosis)

      values = [
        key,
        original["diagnosis_key"],
        version,
        digest(Jason.encode!(original)),
        run["run_id"],
        run["candidate_sha"],
        collected["evidence"]["pipeline_id"],
        preimage,
        digest(preimage),
        raw,
        digest(raw),
        diagnosis["status"],
        DateTime.utc_now() |> DateTime.to_iso8601(),
        "COLLECTOR_REASSESSMENT_V1"
      ]

      row =
        Map.new(
          Enum.zip(
            ~w(reassessment_key diagnosis_key collector_version original_sha256 run_id candidate_sha pipeline_id preimage_json preimage_sha256 diagnosis_json diagnosis_sha256 verdict created_at kind),
            values
          )
        )

      if TicketCiRepair.journal_row_bounded?(row) do
        Store.query!(tx, "INSERT INTO ticket_ci_repair_reassessments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", values)
        :ok
      else
        {:error, :ci_repair_snapshot_limit}
      end
    else
      _ -> {:error, :ci_reassessment_preimage_changed}
    end
  end

  defp validate(row, original) do
    if valid?(original) and original["verdict"] == "BLOCKED" and valid?(row) and row["kind"] == "COLLECTOR_REASSESSMENT_V1" and
         identity_valid?(row, original) and versions_valid?(row) do
      {:ok, row}
    else
      {:error, :ci_reassessment_receipt_changed}
    end
  end

  defp identity_valid?(row, original) do
    row["diagnosis_key"] == original["diagnosis_key"] and row["original_sha256"] == digest(Jason.encode!(original)) and
      row["reassessment_key"] == key(original["diagnosis_key"], row["collector_version"]) and
      Map.take(row, ~w(run_id candidate_sha pipeline_id)) == Map.take(original, ~w(run_id candidate_sha pipeline_id))
  end

  defp versions_valid?(row) do
    {:ok, diagnosis} = Jason.decode(row["diagnosis_json"])
    {:ok, preimage} = Jason.decode(row["preimage_json"])

    case {diagnosis["evidence_versions"], preimage["evidence_versions"]} do
      {nil, nil} ->
        row["collector_version"] in ~w(bounded_pages_v1 bounded_pages_v2)

      {%{"collector_version" => collector, "assessment_version" => assessment} = versions, versions}
      when is_binary(collector) and is_binary(assessment) ->
        Enum.sort(Map.keys(versions)) == ~w(assessment_version collector_version) and
          row["collector_version"] == "evidence-pair-v1:" <> digest(Jason.encode!([collector, assessment]))

      _ ->
        false
    end
  end

  defp valid?(row) do
    with true <- is_binary(row["diagnosis_json"]) and is_binary(row["preimage_json"]),
         true <- digest(row["diagnosis_json"]) == row["diagnosis_sha256"] and digest(row["preimage_json"]) == row["preimage_sha256"],
         {:ok, %{} = diagnosis} <- Jason.decode(row["diagnosis_json"]),
         {:ok, %{"run" => %{} = prior}} <- Jason.decode(row["preimage_json"]) do
      diagnosis["status"] == row["verdict"] and prior["run_id"] == row["run_id"] and prior["candidate_sha"] == row["candidate_sha"] and prior["ci_pipeline_id"] == row["pipeline_id"]
    else
      _ -> false
    end
  end

  defp key(original, version), do: "ci-reassessment:" <> digest(Jason.encode!([original, version]))
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
