defmodule SymphonyElixir.FactoryConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.{Capacity, ControlServer, Store, Supervisor}

  test "factory configuration is optional" do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    refute settings.factory.enabled
    assert settings.factory.lease_seconds == 240
    assert settings.factory.writer_disk_gb == 15
  end

  test "an unresolved optional factory database environment reference stays unset" do
    env_name = "SYMPHONY_MISSING_FACTORY_DB_#{System.unique_integer([:positive])}"
    System.delete_env(env_name)

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{"database" => "$#{env_name}"}
             })

    assert is_nil(settings.factory.database)
  end

  test "enabled factory configuration requires durable control identity" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{"enabled" => true}
             })

    assert message =~ "factory.database"
    assert message =~ "factory.dispatcher_id"
  end

  test "enabled configuration starts a compatible durable store" do
    database = Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.sqlite")

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{
                 "enabled" => true,
                 "database" => database,
                 "scope" => "assigned-jira-work",
                 "dispatcher_id" => "dispatcher-a",
                 "models" => %{"default_provider" => "codex"},
                 "repositories" => %{"grail" => %{"path" => "/Users/cgable/Repos/grail"}}
               }
             })

    supervisor_name = Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
    start_supervised!({Supervisor, settings: settings, name: supervisor_name})

    assert %{"version" => 1} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 1")

    assert %{"version" => 2} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 2")

    assert %{"status" => "PAUSED", "dispatcher_id" => "dispatcher-a"} =
             ControlServer.status(Supervisor.control_name())

    assert {:ok, snapshot} =
             Capacity.snapshot(Supervisor.store_name(), settings.factory, "grail", free_bytes: 30_000_000_000)

    assert snapshot.available_writer_slots == 2

    on_exit(fn -> File.rm(database) end)
  end

  test "store upgrades a compatible pre-model-routing run table" do
    database = Path.join(System.tmp_dir!(), "symphony-legacy-#{System.unique_integer([:positive])}.sqlite")
    {:ok, legacy} = Exqlite.start_link(database: database)

    Exqlite.query!(
      legacy,
      """
      CREATE TABLE runs (
        run_id TEXT PRIMARY KEY,
        issue_key TEXT NOT NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """
    )

    GenServer.stop(legacy)
    connection = start_supervised!({Store, database: database})

    columns =
      connection
      |> Store.query!("PRAGMA table_info(runs)")
      |> Map.fetch!(:rows)
      |> Enum.map(fn [_cid, name | _rest] -> name end)

    assert "model_role" in columns
    assert "reasoning_effort" in columns
    assert "runtime" in columns

    on_exit(fn -> File.rm(database) end)
  end
end
