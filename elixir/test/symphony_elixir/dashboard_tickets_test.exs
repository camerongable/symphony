defmodule SymphonyElixirWeb.DashboardTicketsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.DashboardTickets

  test "overview membership joins exact authoritative current runs and last-polled intake" do
    factory = snapshot()
    projected = DashboardTickets.project(factory)
    assert Enum.map(projected.tickets, & &1.key) == ["PPL-1", "PPL-3", "PPL-2"]
    assert Enum.find(projected.tickets, &(&1.key == "PPL-1")).run.state == "REPAIRING"
    assert Enum.find(projected.tickets, &(&1.key == "PPL-1")).intake.status == "To Do"
    assert Enum.find(projected.tickets, &(&1.key == "PPL-2")).run == nil
    assert Enum.find(projected.tickets, &(&1.key == "PPL-3")).intake == nil
    assert projected.diagnostics == []
  end

  test "input ordering and stale mutable history never choose current workflow" do
    factory = snapshot()
    reversed = %{factory | current_runs: Enum.reverse(factory.current_runs), intake: %{issues: Enum.reverse(factory.intake.issues)}}
    assert DashboardTickets.project(factory) == DashboardTickets.project(reversed)
    no_current = Map.delete(factory, :current_runs)
    assert Enum.all?(DashboardTickets.project(no_current).tickets, &is_nil(&1.run))
  end

  test "conflicting duplicates remain visible without choosing arbitrary phase or link" do
    factory = snapshot()
    [run | _] = factory.current_runs
    factory = %{factory | current_runs: [run, %{run | state: "WRITING"}]}
    ticket = Enum.find(DashboardTickets.project(factory).tickets, &(&1.key == "PPL-1"))
    assert ticket.run == nil
    assert length(ticket.run_records) == 2
    assert Enum.any?(ticket.diagnostics, &String.contains?(&1, "Conflicting current workflow"))
  end

  test "identical copies may collapse but conflicting intake records are not merged" do
    factory = snapshot()
    [issue | _] = factory.intake.issues
    duplicated = %{factory | intake: %{issues: [issue, issue]}}
    assert hd(DashboardTickets.project(duplicated).tickets).intake == issue
    conflicted = %{factory | intake: %{issues: [issue, %{issue | status: "Done"}]}}
    ticket = hd(DashboardTickets.project(conflicted).tickets)
    assert ticket.intake == nil
    assert ticket.run.state == "REPAIRING"
    assert Enum.any?(ticket.diagnostics, &String.contains?(&1, "Conflicting Jira"))
  end

  test "missing identity is diagnosed, not assigned to another ticket" do
    factory = snapshot()
    factory = %{factory | current_runs: [%{state: "WRITING"} | factory.current_runs]}
    projected = DashboardTickets.project(factory)
    assert projected.diagnostics == ["A current workflow record has no valid issue key."]
    assert length(projected.tickets) == 3
  end

  test "terminal membership is retained and excluded membership stays excluded" do
    factory = snapshot()
    factory = %{factory | current_runs: [%{issue_key: "PPL-3", state: "FAILED"}, %{issue_key: "hidden", state: "WRITING"}]}
    projected = DashboardTickets.project(factory)
    assert Enum.find(projected.tickets, &(&1.key == "PPL-3")).run.state == "FAILED"
    refute Enum.any?(projected.tickets, &(&1.key == "hidden"))
  end

  test "buckets and supplied overview totals are not repaired or inferred" do
    factory = snapshot()
    factory = put_in(factory, [:overview], %{by_issue: %{"PPL-1" => "VALIDATION_PENDING"}, active: 19, queued: 20})
    before = :erlang.term_to_binary(factory)
    assert hd(DashboardTickets.project(factory).tickets).bucket == "VALIDATION_PENDING"
    assert :erlang.term_to_binary(factory) == before
  end

  test "exact nonempty keys do not case-fold, trim or join foreign identities" do
    factory = %{
      overview: %{by_issue: %{"PPL-1" => "QUEUED", " " => "ACTIVE"}},
      current_runs: [%{issue_key: "ppl-1", state: "WRITING"}],
      intake: %{issues: []}
    }

    projected = DashboardTickets.project(factory)
    assert [%{key: "PPL-1", run: nil}] = projected.tickets
    assert projected.diagnostics != []
    assert hd(projected.tickets).diagnostics != []
  end

  defp snapshot do
    %{
      overview: %{by_issue: %{"PPL-1" => "ACTIVE", "PPL-2" => "QUEUED", "PPL-3" => "REVIEW_READY"}},
      current_runs: [%{issue_key: "PPL-1", state: "REPAIRING"}, %{issue_key: "PPL-3", state: "READY_FOR_REVIEW"}],
      runs: [%{issue_key: "PPL-1", state: "WRITING", updated_at: "2099-01-01"}],
      intake: %{issues: [%{issue_key: "PPL-1", status: "To Do"}, %{issue_key: "PPL-2", status: "In Dev"}]}
    }
  end
end
