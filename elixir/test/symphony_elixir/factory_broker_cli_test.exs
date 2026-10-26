defmodule SymphonyElixir.FactoryBrokerCliTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.Store

  @script Path.expand("../../scripts/factory-broker", __DIR__)

  test "compiled broker exports its pinned MR driver without opening a ledger" do
    build = :symphony_elixir |> Application.app_dir() |> Path.dirname() |> Path.dirname()
    {output, 0} = System.cmd(@script, ["mr-driver"], stderr_to_stdout: true, env: [{"MIX_BUILD_PATH", build}])
    driver = Jason.decode!(output)
    assert Map.keys(driver) |> Enum.sort() == ~w(sha256 source version)
    assert driver["version"] == 1
    assert driver["sha256"] == Base.encode16(:crypto.hash(:sha256, driver["source"]), case: :lower)
    assert driver["source"] =~ "COMMITTED_CLAIM_OUTPUT_INVALID"
  end

  test "precompiled ticket CLI needs no network socket under the actual sandbox" do
    build = :symphony_elixir |> Application.app_dir() |> Path.dirname() |> Path.dirname()

    {output, 0} =
      System.cmd(
        "/usr/bin/sandbox-exec",
        ["-p", "(version 1) (allow default) (deny network*)", "/opt/homebrew/bin/mise", "exec", "--", "elixir", "-pa", Path.join(build, "lib/*/ebin"), "-S", "mix", "factory.ticket", "--help"],
        stderr_to_stdout: true
      )

    assert output =~ "prepare-stage"
    refute output =~ "Mix.PubSub"
  end

  test "compiled broker CLI reads an isolated queue without starting the service or build coordinator" do
    root = Path.join(System.tmp_dir!(), "broker-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    workflow = Path.join(root, "WORKFLOW.md")

    File.write!(workflow, """
    ---
    factory:
      enabled: false
      database: #{Path.join(root, "factory.sqlite")}
      scope: isolated-broker
      dispatcher_id: isolated-dispatcher
    ---
    Synthetic broker fixture.
    """)

    {output, 0} = System.cmd(@script, ["desktop", "list", "--workflow", workflow], stderr_to_stdout: true)
    assert Jason.decode!(output) == %{"pending" => [], "reconciliation" => [], "waiting_for_user" => []}
  end

  test "broker launcher rejects commands outside its existing status and exchange interface" do
    {output, code} = System.cmd(@script, ["activate"], stderr_to_stdout: true)
    assert code == 1
    assert output =~ "Use factory-broker status|desktop"
  end

  test "queue discovery stays readable while a source transaction holds the writable ledger" do
    root = Path.join(System.tmp_dir!(), "broker-cli-reader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    database = Path.join(root, "factory.sqlite")
    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, "---\nfactory:\n  enabled: false\n  database: #{database}\n  scope: isolated-broker\n  dispatcher_id: isolated-dispatcher\n---\nSynthetic fixture.\n")
    store = start_supervised!({Store, database: database})
    owner = self()

    writer =
      Task.async(fn ->
        Store.transaction!(store, fn _tx ->
          send(owner, :broker_writer_owned)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :broker_writer_owned, 1000
    reader = Task.async(fn -> ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Factory.Desktop.run(["list", "--workflow", workflow]) end) end)

    try do
      assert {:ok, output} = Task.yield(reader, 1000)
      assert Jason.decode!(output) == %{"pending" => [], "reconciliation" => [], "waiting_for_user" => []}
    after
      send(writer.pid, :finish)
      Task.await(writer, 5000)
      Task.shutdown(reader, :brutal_kill)
    end
  end
end
