defmodule Mix.Tasks.Factory.PilotReportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Factory.PilotReport
  alias SymphonyElixir.Factory.{RunLedger, Store}

  test "help explains read-only evidence and supported filters without opening a ledger" do
    output = capture_io(fn -> PilotReport.run(["--help"]) end)
    assert output =~ "mix factory.pilot_report --issue"
    assert output =~ "mix factory.pilot_report --run"
    assert output =~ "explicitly unavailable"
  end

  test "opens an existing ledger read-only and does not apply migrations" do
    root = Path.join(System.tmp_dir!(), "pilot-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "factory.sqlite")
    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{database}\n---\n")
    store = start_supervised!({Store, database: database})
    {:ok, _} = RunLedger.register(store, %{run_id: "run", issue_key: "PPL-123", kind: "DELIVERY", state: "VERIFYING"})
    Store.query!(store, "DELETE FROM factory_schema_migrations WHERE version = 15")

    report =
      capture_io(fn -> PilotReport.run(["--issue", "PPL-123", "--workflow", workflow]) end)
      |> Jason.decode!()

    assert [%{"identity" => %{"run_id" => "run"}}] = report["runs"]
    assert report["unavailable"]["tokens"] == "Not stored per run or turn"
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM factory_schema_migrations WHERE version = 15")["count"] == 0
    assert Store.one!(store, "SELECT COUNT(*) AS count FROM events")["count"] == 1
  end

  test "rejects conflicting filters and unknown arguments" do
    for args <- [["--issue", "PPL-123", "--run", "run"], ["--unknown"], ["extra"]] do
      assert_raise Mix.Error, ~r/Invalid arguments/, fn -> PilotReport.run(args) end
    end
  end

  test "missing database is not created" do
    root = Path.join(System.tmp_dir!(), "pilot-report-missing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "missing.sqlite")
    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{database}\n---\n")

    assert_raise Mix.Error, ~r/Unable to read pilot ledger/, fn -> PilotReport.run(["--workflow", workflow]) end
    refute File.exists?(database)
  end
end
