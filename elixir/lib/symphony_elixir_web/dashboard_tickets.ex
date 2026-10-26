defmodule SymphonyElixirWeb.DashboardTickets do
  @moduledoc "Pure presentation join over the bounded dashboard snapshot."

  @spec project(map()) :: %{tickets: [map()], diagnostics: [String.t()]}
  def project(factory) do
    membership = get_in(factory, [:overview, :by_issue]) || %{}
    {runs, run_notes} = index(factory[:current_runs] || [], "current workflow")
    {intake, intake_notes} = index(get_in(factory, [:intake, :issues]) || [], "Jira snapshot")

    {tickets, membership_notes} =
      membership
      |> Enum.sort_by(fn {key, _bucket} -> key end)
      |> Enum.reduce({[], []}, fn {key, bucket}, {tickets, notes} ->
        if valid_key?(key) do
          {[join_ticket(key, bucket, runs, intake) | tickets], notes}
        else
          {tickets, ["Overview membership contains a missing or invalid issue key." | notes]}
        end
      end)

    ordered = Enum.sort_by(tickets, &{bucket_order(&1.bucket), &1.key})
    %{tickets: ordered, diagnostics: run_notes ++ intake_notes ++ membership_notes}
  end

  defp join_ticket(key, bucket, runs, intake) do
    {run, run_errors} = record(runs, key, "current workflow")
    {issue, issue_errors} = record(intake, key, "Jira snapshot")
    errors = run_errors ++ issue_errors
    errors = if is_nil(run) and is_nil(issue), do: errors ++ ["No unambiguous current record is available."], else: errors

    %{
      key: key,
      bucket: bucket,
      run: run,
      intake: issue,
      diagnostics: errors,
      run_records: Map.get(runs, key, []),
      intake_records: Map.get(intake, key, [])
    }
  end

  defp bucket_order("NEEDS_ATTENTION"), do: 0
  defp bucket_order("ACTIVE"), do: 1
  defp bucket_order("VALIDATION_PENDING"), do: 2
  defp bucket_order("REVIEW_READY"), do: 3
  defp bucket_order("QUEUED"), do: 4
  defp bucket_order(_bucket), do: 5

  defp index(records, source) do
    Enum.reduce(records, {%{}, []}, fn record, {index, notes} ->
      key = if is_map(record), do: record[:issue_key]

      if valid_key?(key) do
        {Map.update(index, key, [record], &[record | &1]), notes}
      else
        {index, ["A #{source} record has no valid issue key." | notes]}
      end
    end)
  end

  defp record(index, key, source) do
    case Enum.uniq(Map.get(index, key, [])) do
      [] -> {nil, []}
      [record] -> {record, []}
      _conflicts -> {nil, ["Conflicting #{source} records for #{key}; no record selected."]}
    end
  end

  defp valid_key?(key), do: is_binary(key) and String.trim(key) != ""
end
