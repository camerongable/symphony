defmodule SymphonyElixir.FactoryAdminTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Admin

  test "controls a factory through short-lived local database connections" do
    database = Path.join(System.tmp_dir!(), "symphony-admin-#{System.unique_integer([:positive])}.sqlite")

    factory = %{
      enabled: true,
      database: database,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-a",
      lease_seconds: 240
    }

    assert {:ok, %{"status" => "PAUSED"}} = Admin.status(factory)
    assert {:ok, %{result: "ACTIVE"}} = Admin.activate(factory)
    assert {:ok, %{"status" => "ACTIVE"}} = Admin.status(factory)
    assert {:ok, %{result: "PAUSED"}} = Admin.pause(factory)

    on_exit(fn -> File.rm(database) end)
  end

  test "fails closed when factory control is disabled" do
    assert {:error, :factory_disabled} = Admin.status(%{enabled: false})
  end
end
