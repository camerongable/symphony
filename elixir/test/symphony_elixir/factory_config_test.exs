defmodule SymphonyElixir.FactoryConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.{Capacity, ControlServer, Store, Supervisor}

  test "factory configuration is optional" do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    refute settings.factory.enabled
    assert settings.factory.lease_seconds == 240
    assert settings.factory.writer_disk_gb == 20
    assert settings.factory.maximum_code_repair_rounds == 5
    assert settings.factory.maximum_validation_repair_rounds == 2
    assert settings.factory.branch_prefix == "ai"
    assert settings.factory.hibernation == %{}
    assert settings.factory.controller_required_mcp_servers == []
    assert settings.factory.controller_mcp_startup_timeout_ms == 60_000
    assert settings.factory.controller_writer_stale_minutes == 15
    assert settings.factory.task_transport == "app_server"
    assert settings.factory.specification_authorization_mode == "auto_after_critic"
    refute settings.factory.native_session_discovery_enabled
    assert is_nil(settings.factory.controller_codex_project_id)
  end

  test "configured lower code repair limits remain exact" do
    for cap <- [0, 1, 2, 5] do
      assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "factory" => %{"maximum_code_repair_rounds" => cap}})
      assert settings.factory.maximum_code_repair_rounds == cap
    end
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
    assert message =~ "factory.controller_codex_project_id"
  end

  test "factory transport accepts only the explicit desktop broker opt-in" do
    assert {:ok, settings} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "factory" => %{"task_transport" => "desktop_broker"}})

    assert settings.factory.task_transport == "desktop_broker"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "factory" => %{"task_transport" => "unknown"}})

    assert message =~ "factory.task_transport"

    assert {:ok, opted_in} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{"native_session_discovery_enabled" => true}
             })

    assert opted_in.factory.native_session_discovery_enabled
  end

  test "specification authorization mode is explicit and validated" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{"specification_authorization_mode" => "human_confirmation"}
             })

    assert settings.factory.specification_authorization_mode == "human_confirmation"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{"specification_authorization_mode" => "unreviewed"}
             })

    assert message =~ "factory.specification_authorization_mode"
  end

  test "enabled configuration starts a compatible durable store" do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-runtime-#{token}.sqlite")

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "factory" => %{
                 "enabled" => true,
                 "database" => database,
                 "scope" => "assigned-jira-work",
                 "dispatcher_id" => "dispatcher-a",
                 "controller_codex_project_id" => "project-grail",
                 "queue" => %{
                   "assignee" => "currentUser()",
                   "statuses" => ["READY", "TO DO"],
                   "factory_labels" => ["ai-ready"]
                 },
                 "models" => model_policy(),
                 "repositories" => %{
                   "grail" => %{
                     "path" => System.tmp_dir!(),
                     "base_branch" => "master",
                     "codex_project_id" => "project-grail",
                     "gitlab_project" => "example/grail",
                     "route_labels" => ["repo-grail"]
                   }
                 }
               }
             })

    supervisor_name = Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
    start_supervised!({Supervisor, settings: settings, name: supervisor_name})

    assert %{"version" => 1} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 1")

    assert %{"version" => 2} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 2")

    assert %{"version" => 4} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 4")

    assert %{"version" => 5} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 5")

    assert %{"version" => 6} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 6")

    assert %{"version" => 7} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 7")

    assert %{"version" => 9} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 9")

    assert %{"version" => 11} =
             Store.one!(Supervisor.store_name(), "SELECT version FROM factory_schema_migrations WHERE version = 11")

    assert %{"name" => "intake_snapshots"} =
             Store.one!(
               Supervisor.store_name(),
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'intake_snapshots'"
             )

    assert %{"status" => "PAUSED", "dispatcher_id" => "dispatcher-a"} =
             ControlServer.status(Supervisor.control_name())

    assert {:ok, snapshot} =
             Capacity.snapshot(Supervisor.store_name(), settings.factory, "grail", free_bytes: 40_000_000_000)

    assert snapshot.available_writer_slots == 2

    on_exit(fn -> File.rm(database) end)
  end

  test "store upgrades a compatible pre-model-routing run table" do
    token = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-legacy-#{token}.sqlite")
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

  defp model_policy do
    roles =
      ~w(
        orchestrator orchestrator-intake specification-author specification-critic feature-planner
        feature-writer feature-writer-high-risk change-verifier manual-validator
        explorer failure-triager
      )
      |> Map.new(fn role ->
        {role, %{"provider" => "codex", "model_class" => "test", "reasoning_effort" => "medium"}}
      end)

    %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"test" => "gpt-test"}},
      "roles" => roles,
      "delivery_routing" => %{
        "default_role" => "feature-writer",
        "high_risk_role" => "feature-writer-high-risk",
        "high_risk_values" => ["high"],
        "unknown_risk_is_high" => true
      }
    }
  end
end
