defmodule SymphonyElixir.FactoryStoreConcurrencyTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{Admin, Store}
  alias SymphonyElixir.Factory.ControlServer

  test "a file-backed ledger stays readable while a source transaction owns a connection" do
    root = Path.join(System.tmp_dir!(), "factory-store-concurrency-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, database: Path.join(root, "factory.sqlite")})
    Store.query!(store, "CREATE TABLE concurrency_probe(value INTEGER NOT NULL)")
    Store.query!(store, "INSERT INTO concurrency_probe(value) VALUES (0)")
    read_store_name = {:global, {:factory_read_probe, root}}
    reader_store = start_supervised!(%{id: :reader, start: {Store, :start_read_only, [[database: Path.join(root, "factory.sqlite"), name: read_store_name]]}})
    factory = %{scope: "read-status", dispatcher_id: "dispatcher", lease_seconds: 240}
    control = start_supervised!({ControlServer, store: store, read_store: reader_store, factory: factory, name: {:global, {:read_status, root}}})
    owner = self()

    writer =
      Task.async(fn ->
        Store.transaction!(store, fn tx ->
          Store.query!(tx, "UPDATE concurrency_probe SET value = 1")
          send(owner, :transaction_owned)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :transaction_owned, 1000
    reader = Task.async(fn -> Store.one!(reader_store, "SELECT value FROM concurrency_probe") end)

    try do
      assert {:ok, %{"value" => 0}} = Task.yield(reader, 1000)
      assert ControlServer.status(control)["status"] == "PAUSED"
      assert Process.alive?(control)
    after
      send(writer.pid, :finish)
      Task.await(writer, 5000)
      Task.shutdown(reader, :brutal_kill)
    end

    assert Store.one!(store, "SELECT value FROM concurrency_probe") == %{"value" => 1}
  end

  test "broker administrative reads do not migrate or acquire the writer's transaction lock" do
    root = Path.join(System.tmp_dir!(), "factory-admin-concurrency-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "factory.sqlite")
    store = start_supervised!({Store, database: database})
    factory = %{enabled: true, database: database, scope: "broker-status", dispatcher_id: "dispatcher", lease_seconds: 240}
    SymphonyElixir.Factory.Control.initialize(store, factory)
    owner = self()

    writer =
      Task.async(fn ->
        Store.transaction!(store, fn tx ->
          Store.query!(tx, "UPDATE control SET status = 'ACTIVE' WHERE scope = ?", [factory.scope])
          send(owner, :admin_transaction_owned)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :admin_transaction_owned, 1000
    overview = Task.async(fn -> Admin.overview(factory) end)

    try do
      assert {:ok, {:ok, %{control: %{"status" => "PAUSED"}, runs: [], tasks: []}}} = Task.yield(overview, 1000)
      assert {:ok, %{"status" => "PAUSED"}} = Admin.status(factory)
    after
      send(writer.pid, :finish)
      Task.await(writer, 5000)
      Task.shutdown(overview, :brutal_kill)
    end

    assert {:ok, %{"status" => "ACTIVE"}} = Admin.status(factory)
  end
end
