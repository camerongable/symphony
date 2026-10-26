defmodule SymphonyElixir.FactoryIntakeLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{IntakeLedger, Store}

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-intake-ledger-#{token}.sqlite")
    store = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)
    %{store: store, database: database}
  end

  test "saved rejection survives reader restart and refuses stale observations", %{store: store, database: database} do
    reason = :manual_validation_contract_missing
    snapshot = %{"key" => "PPL-123", "labels" => ["ai-ready"], "description" => "Missing declaration"}
    assert {:ok, saved} = IntakeLedger.replace(store, "scope", [snapshot])

    assert :ok =
             IntakeLedger.record_blocked(store, "scope", snapshot, saved.observed_at, reason)

    assert {:ok, reader} = Store.start_read_only(database: database)
    assert {:ok, %{decisions: decisions}} = IntakeLedger.get(reader, "scope")
    assert decisions["PPL-123"]["code"] == "manual_validation_contract_missing"
    GenServer.stop(reader)
    assert {:ok, reader} = Store.start_read_only(database: database)
    assert {:ok, %{decisions: %{"PPL-123" => _}}} = IntakeLedger.get(reader, "scope")
    GenServer.stop(reader)

    revised = Map.put(snapshot, "description", "## Manual Validation\n- Required: no")
    assert {:ok, replacement} = IntakeLedger.replace(store, "scope", [revised])

    assert {:error, :intake_observation_changed} =
             IntakeLedger.record_blocked(store, "scope", snapshot, saved.observed_at, reason)

    assert {:error, :intake_observation_changed} =
             IntakeLedger.record_blocked(store, "scope", snapshot, replacement.observed_at, reason)

    assert {:ok, %{snapshots: [^revised], decisions: %{}}} = IntakeLedger.get(store, "scope")
    assert {:ok, _} = IntakeLedger.replace(store, "scope", [])
    assert {:ok, %{snapshots: [], decisions: %{}}} = IntakeLedger.get(store, "scope")
    corrupt_decisions = Jason.encode!(%{"PPL-123" => "corrupt"})
    Store.query!(store, "UPDATE intake_snapshots SET decisions_json = ? WHERE scope = ?", [corrupt_decisions, "scope"])
    assert {:error, :invalid_stored_intake_snapshot} = IntakeLedger.get(store, "scope")
  end

  test "persists and atomically replaces the last successful queue snapshot", %{store: store} do
    first_time = ~U[2026-09-22 20:00:00Z]
    second_time = DateTime.add(first_time, 300, :second)
    first = [%{"key" => "PPL-123", "labels" => ["spec-needed", "repo-grail"]}]

    assert {:ok, %{scope: "assigned-jira-work", observed_at: "2026-09-22T20:00:00Z", snapshots: ^first}} =
             IntakeLedger.replace(store, " assigned-jira-work ", first, now: first_time)

    assert {:ok, %{snapshots: ^first}} = IntakeLedger.get(store, "assigned-jira-work")

    assert {:ok, %{observed_at: "2026-09-22T20:05:00Z", snapshots: []}} =
             IntakeLedger.replace(store, "assigned-jira-work", [], now: second_time)

    assert {:ok, %{observed_at: "2026-09-22T20:05:00Z", snapshots: []}} =
             IntakeLedger.get(store, "assigned-jira-work")
  end

  test "distinguishes an absent snapshot from invalid input and corrupt storage", %{store: store} do
    assert {:ok, nil} = IntakeLedger.get(store, "missing")
    assert {:error, :invalid_intake_scope} = IntakeLedger.get(store, :not_a_scope)
    assert {:error, :invalid_intake_scope} = IntakeLedger.replace(store, " ", [])
    assert {:error, :invalid_intake_snapshots} = IntakeLedger.replace(store, "scope", ["not-a-map"])
    assert {:error, :invalid_intake_snapshot} = IntakeLedger.replace(store, :scope, [])

    Store.query!(
      store,
      "INSERT INTO intake_snapshots(scope, observed_at, snapshot_json) VALUES (?, ?, ?)",
      ["corrupt", "2026-09-22T20:00:00Z", "{invalid"]
    )

    assert {:error, :invalid_stored_intake_snapshot} = IntakeLedger.get(store, "corrupt")

    Store.query!(
      store,
      "INSERT INTO intake_snapshots(scope, observed_at, snapshot_json) VALUES (?, ?, ?)",
      ["wrong-shape", "2026-09-22T20:00:00Z", Jason.encode!(["not-a-map"])]
    )

    assert {:error, :invalid_stored_intake_snapshot} = IntakeLedger.get(store, "wrong-shape")
  end
end
