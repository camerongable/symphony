defmodule SymphonyElixir.FactoryRunLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{RunLedger, Store}

  @now ~U[2026-09-21 21:00:00Z]

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-ledger-#{token}.sqlite")
    connection = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)
    %{connection: connection}
  end

  test "registers, reads, updates, and lists a run", %{connection: connection} do
    attrs = %{
      run_id: "run-1",
      issue_key: "PPL-100",
      kind: "DELIVERY",
      state: "WRITING",
      dispatcher_id: "dispatcher-a",
      branch: "factory/PPL-100",
      factory_owned: true
    }

    assert {:ok, %{result: "REGISTERED", run: run}} = RunLedger.register(connection, attrs, now: @now)
    assert run["run_id"] == "run-1"
    assert run["factory_owned"] == 1
    assert run["attempt"] == 1

    assert {:ok, %{result: "UPDATED", run: updated}} =
             RunLedger.update(connection, "run-1", %{state: "VERIFYING", candidate_sha: "abc123"}, now: DateTime.add(@now, 10, :second))

    assert updated["state"] == "VERIFYING"
    assert updated["candidate_sha"] == "abc123"
    assert [%{"run_id" => "run-1"}] = RunLedger.list(connection, state: "VERIFYING")

    assert Enum.map(RunLedger.events(connection, "run-1"), & &1["event_type"]) == [
             "RUN_REGISTERED",
             "RUN_UPDATED"
           ]
  end

  test "enforces one active run per issue and kind", %{connection: connection} do
    attrs = %{run_id: "run-1", issue_key: "PPL-100", kind: "DELIVERY", state: "WRITING"}
    assert {:ok, _registered} = RunLedger.register(connection, attrs, now: @now)

    assert {:error, {:register_failed, _error}} =
             RunLedger.register(connection, %{attrs | run_id: "run-2"}, now: @now)
  end

  test "records every specialized model route", %{connection: connection} do
    assert {:ok, _registered} =
             RunLedger.register(
               connection,
               %{run_id: "run-1", issue_key: "PPL-100", kind: "DELIVERY", state: "WRITING"},
               now: @now
             )

    route = %{
      requested_role: "feature-writer",
      resolved_role: "feature-writer-high-risk",
      provider: "codex",
      model_class: "deep",
      model: "gpt-5.6-sol",
      reasoning_effort: "xhigh",
      routing_reason: "risk:high"
    }

    assert {:ok, recorded} =
             RunLedger.record_model_route(connection, "run-1", "delivery-writer", route,
               task_id: "task-1",
               now: @now
             )

    assert recorded.resolved_role == "feature-writer-high-risk"
    assert recorded.task_id == "task-1"
    assert recorded.route_id == 1

    assert List.last(RunLedger.events(connection, "run-1"))["event_type"] ==
             "MODEL_ROUTE_RECORDED"
  end

  test "fails closed for unknown runs and invalid updates", %{connection: connection} do
    assert {:error, :unknown_run} = RunLedger.get(connection, "missing")
    assert {:error, :no_run_fields} = RunLedger.update(connection, "missing", %{unknown: "value"})

    assert {:error, :unknown_run} =
             RunLedger.record_model_route(connection, "missing", "explorer", %{})
  end
end
