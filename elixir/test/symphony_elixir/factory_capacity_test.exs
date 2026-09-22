defmodule SymphonyElixir.FactoryCapacityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Capacity, RunLedger, Store}

  @now ~U[2026-09-21 22:00:00Z]
  @policy %{
    "capacity" => %{
      "maximum_specifiers" => 2,
      "maximum_writers" => 2,
      "maximum_validators" => 2,
      "writer_disk_gb" => 20
    },
    "repositories" => %{
      "grail" => %{"path" => "/Users/cgable/Repos/grail"}
    }
  }

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-capacity-#{token}.sqlite")
    connection = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)
    %{connection: connection}
  end

  test "admits writers only when both disk and writer slots are available", %{connection: connection} do
    assert {:ok, snapshot} = Capacity.snapshot(connection, @policy, "grail", free_bytes: 41_000_000_000)
    assert snapshot.disk_writer_slots == 2
    assert snapshot.available_writer_slots == 2
    assert snapshot.result == "PASS"

    register_run(connection, "writer-1", "PPL-1", "DELIVERY", "WRITING")

    assert {:ok, snapshot} = Capacity.snapshot(connection, @policy, "grail", free_bytes: 41_000_000_000)
    assert snapshot.active_writers == 1
    assert snapshot.available_writer_slots == 1

    assert {:ok, snapshot} = Capacity.snapshot(connection, @policy, "grail", free_bytes: 19_999_999_999)
    assert snapshot.disk_writer_slots == 0
    assert snapshot.available_writer_slots == 0
    assert snapshot.result == "INSUFFICIENT_WRITER_CAPACITY"
  end

  test "deduplicates Jira-observed work against the local ledger", %{connection: connection} do
    register_run(connection, "writer-1", "PPL-1", "DELIVERY", "VERIFYING")

    assert {:ok, snapshot} =
             Capacity.snapshot(connection, @policy, "grail",
               free_bytes: 45_000_000_000,
               external_writer_issue_keys: ["PPL-1", "PPL-2"]
             )

    assert snapshot.active_writers == 2
    assert snapshot.available_writer_slots == 0
  end

  test "does not charge a hibernated repair for its already-owned writer slot", %{connection: connection} do
    register_run(connection, "writer-1", "PPL-1", "DELIVERY", "REPAIRING")

    assert {:ok, snapshot} =
             Capacity.snapshot(connection, @policy, "grail",
               free_bytes: 20_000_000_000,
               exclude_writer_issue_key: "PPL-1"
             )

    assert snapshot.active_writers == 0
    assert snapshot.available_writer_slots == 1
  end

  test "tracks specification and validation pools independently", %{connection: connection} do
    register_run(connection, "spec-1", "PPL-1", "SPECIFICATION", "SPEC_DRAFTING")
    register_run(connection, "validator-1", "PPL-2", "VALIDATION", "TESTING")

    assert {:ok, snapshot} = Capacity.snapshot(connection, @policy, "grail", free_bytes: 45_000_000_000)
    assert snapshot.active_specifiers == 1
    assert snapshot.available_specifier_slots == 1
    assert snapshot.active_validators == 1
    assert snapshot.available_validator_slots == 1
    assert snapshot.available_writer_slots == 2
  end

  test "reads free disk for an existing route" do
    assert {:ok, free_bytes} = Capacity.free_bytes("/Users/cgable/Repos/symphony")
    assert free_bytes > 0
  end

  defp register_run(connection, run_id, issue_key, kind, state) do
    assert {:ok, _registered} =
             RunLedger.register(
               connection,
               %{run_id: run_id, issue_key: issue_key, kind: kind, state: state},
               now: @now
             )
  end
end
