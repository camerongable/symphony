defmodule SymphonyElixir.FactoryTaskLedgerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLedger}

  setup do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "factory-task-ledger-#{token}.sqlite")
    {:ok, store} = Store.start_link(database: database)

    {:ok, _run} =
      RunLedger.register(store, %{
        run_id: "run-1",
        issue_key: "PPL-123",
        kind: "DELIVERY",
        state: "PLANNING"
      })

    %{store: store}
  end

  test "persists a task route before launch and its reopenable Codex thread afterward", %{store: store} do
    attrs = %{
      task_key: "run-1:planner:1",
      run_id: "run-1",
      stage: "PLANNING",
      role: "feature-planner",
      status: "STARTING",
      model_provider: "codex",
      model_class: "deep",
      model: "gpt-test",
      reasoning_effort: "high",
      routing_reason: "explicit-role",
      prompt_sha256: String.duplicate("a", 64)
    }

    assert {:ok, registered} = TaskLedger.register(store, attrs)
    assert registered["thread_id"] == nil
    assert registered["model"] == "gpt-test"

    assert {:ok, updated} =
             TaskLedger.update(store, attrs.task_key, %{
               status: "COMPLETE",
               thread_id: "thread-123",
               turn_id: "turn-456",
               output_json: Jason.encode!(%{"status" => "PLANNED"})
             })

    assert updated["thread_id"] == "thread-123"
    assert updated["turn_id"] == "turn-456"
    assert [%{"task_key" => "run-1:planner:1"}] = TaskLedger.list_for_run(store, "run-1")
  end

  test "one issue cannot own simultaneous active run kinds", %{store: store} do
    assert {:error, {:register_failed, _error}} =
             RunLedger.register(store, %{
               run_id: "run-2",
               issue_key: "PPL-123",
               kind: "VALIDATION",
               state: "TESTING"
             })
  end
end
