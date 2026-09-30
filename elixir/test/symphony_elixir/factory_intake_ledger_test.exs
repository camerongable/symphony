defmodule SymphonyElixir.FactoryIntakeLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{IntakeLedger, Store}

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-intake-ledger-#{token}.sqlite")
    store = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)
    %{store: store}
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
