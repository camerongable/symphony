defmodule SymphonyElixir.FactoryPolicyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.Policy
  alias SymphonyElixir.Factory.Supervisor, as: FactorySupervisor
  alias SymphonyElixir.TicketChatFixture

  test "fails closed before startup when required routing or model roles are missing" do
    factory = %{
      queue: %{
        "assignee" => "currentUser()",
        "statuses" => ["READY"],
        "factory_labels" => ["ai-ready"]
      },
      repositories: %{
        "repo" => %{
          "path" => System.tmp_dir!(),
          "base_branch" => "master",
          "codex_project_id" => "project-repo",
          "gitlab_project" => "example/repo",
          "route_labels" => []
        }
      },
      models: %{},
      cleanup: %{},
      manual_validation: %{}
    }

    assert {:error, {:repository_route_labels_required, "repo"}} = Policy.validate(factory)

    routed = put_in(factory, [:repositories, "repo", "route_labels"], ["repo-example"])

    assert {:error, {:model_route_unavailable, "orchestrator", _reason}} = Policy.validate(routed)
  end

  test "requires an explicit Codex project for every repository route" do
    factory = %{
      queue: %{
        "assignee" => "currentUser()",
        "statuses" => ["READY"],
        "factory_labels" => ["ai-ready"]
      },
      repositories: %{
        "repo" => %{
          "path" => System.tmp_dir!(),
          "base_branch" => "master",
          "gitlab_project" => "example/repo",
          "route_labels" => ["repo-example"]
        }
      },
      models: %{},
      cleanup: %{},
      manual_validation: %{}
    }

    assert {:error, {:incomplete_repository_route, "repo", ["codex_project_id"]}} =
             Policy.validate(factory)
  end

  test "requires a launch-time Slack provider for enabled manual validation" do
    factory = valid_factory()

    assert {:error, :manual_validation_slack_provider_required} = Policy.validate(factory)

    configured = put_in(factory, [:manual_validation, "required_apps"], ["polaris-app"])
    assert :ok = Policy.validate(configured)
  end

  test "native cleanup cannot be enabled before archive and restore capability is proven" do
    factory = valid_factory() |> put_in([:cleanup, "native"], %{"enabled" => true})
    assert {:error, :native_archive_restore_capability_unproven} = Policy.validate(factory)
  end

  test "ticket route supports explicit global selection without bypassing its enabled gate" do
    for {policy, issue, expected} <- [
          {%{}, "PPL-123", false},
          {%{"enabled" => false, "all_eligible_tickets" => true}, "PPL-123", false},
          {%{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}, "PPL-123", true},
          {%{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}, "PPL-456", false},
          {%{"enabled" => true, "all_eligible_tickets" => true}, "PPL-456", true}
        ] do
      assert Policy.ticket_selected?(policy, issue) == expected
    end

    assert {:error, :invalid_ticket_supervisor_policy} =
             Policy.validate(Map.put(valid_factory(), :ticket_supervisor, %{"all_eligible_tickets" => "true"}))
  end

  test "ticket supervisor static policy is disabled by default and accepts a well-shaped enabled route" do
    factory = valid_factory() |> put_in([:manual_validation, "required_apps"], ["polaris-app"])
    assert :ok = Policy.validate(factory)
    assert :ok = Policy.validate(Map.put(factory, :ticket_supervisor, %{}))

    assert :ok =
             Policy.validate(Map.put(factory, :ticket_supervisor, %{"enabled" => false, "pilot_issue_keys" => ["PPL-123"]}))

    assert :ok =
             Policy.validate(Map.put(factory, :ticket_supervisor, %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}))
  end

  test "enabled startup qualifies the actual runtime before returning factory child specs for either policy key form" do
    root = startup_root()
    trace = TicketChatFixture.runtime_fixture(root)

    for policy <- [
          %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"], "parent_output_root" => root},
          %{enabled: true, pilot_issue_keys: ["PPL-123"], parent_output_root: root}
        ] do
      factory = startup_factory(root, policy)
      assert :ok = Policy.validate(factory)
      assert {:ok, {_flags, children}} = FactorySupervisor.init(%{factory: factory})

      expected = [
        FactorySupervisor.store_name(),
        FactorySupervisor.control_name(),
        FactorySupervisor.task_supervisor_name(),
        SymphonyElixir.Factory.Controller
      ]

      assert Enum.map(children, & &1.id) == expected
    end

    factory = startup_factory(root, %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"], "parent_output_root" => root})
    factory = Map.put(Map.delete(factory, :ticket_supervisor), "ticket_supervisor", factory.ticket_supervisor)
    assert {:ok, _} = FactorySupervisor.init(%{factory: factory})

    messages = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(messages, & &1["method"]) == ["initialize", "initialize", "initialize"]
    refute File.exists?(Path.join(root, "factory.sqlite"))
  end

  test "unsupported enabled startup stops before factory storage or controller children exist" do
    root = startup_root()
    TicketChatFixture.runtime_fixture(root, %{})
    factory = startup_factory(root, %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"], "parent_output_root" => root})
    assert catch_exit(FactorySupervisor.init(%{factory: factory})) == {:invalid_factory_policy, :worker_runtime_identity_unproven}
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_factory_policy, :worker_runtime_identity_unproven}} =
             FactorySupervisor.start_link(settings: %{factory: factory}, name: SymphonyElixir.FactoryStartupProbe)

    assert Process.whereis(SymphonyElixir.FactoryStartupProbe) == nil
    refute File.exists?(factory.database)
    missing = put_in(factory, [:ticket_supervisor, "parent_output_root"], Path.join(root, "absent"))
    assert catch_exit(FactorySupervisor.init(%{factory: missing})) == {:invalid_factory_policy, :ticket_runtime_cwd_unproven}
  end

  test "disabled startup and repeated static policy checks never probe the configured runtime" do
    root = startup_root()
    trace = TicketChatFixture.runtime_fixture(root, %{})
    factory = startup_factory(root, %{"enabled" => false, "pilot_issue_keys" => ["PPL-123"]})

    for _ <- 1..3 do
      assert :ok = Policy.validate(factory)
      assert {:ok, _} = FactorySupervisor.init(%{factory: factory})
    end

    refute File.exists?(trace)
    refute File.exists?(factory.database)
    assert :ignore = FactorySupervisor.start_link(settings: %{factory: %{factory | enabled: false}})
  end

  test "ticket supervisor policy rejects malformed values" do
    factory = valid_factory() |> put_in([:manual_validation, "required_apps"], ["polaris-app"])

    for policy <- [
          %{"enabled" => "true", "pilot_issue_keys" => []},
          %{"enabled" => false, "pilot_issue_keys" => "PPL-123"},
          %{"enabled" => false, "pilot_issue_keys" => ["  "]},
          nil
        ] do
      assert {:error, :invalid_ticket_supervisor_policy} =
               Policy.validate(Map.put(factory, :ticket_supervisor, policy))
    end
  end

  test "parsed ticket supervisor defaults are valid and explicit nulls reach policy validation" do
    factory = valid_factory() |> put_in([:manual_validation, "required_apps"], ["polaris-app"])

    assert :ok = validate_parsed_factory(Map.delete(factory, :ticket_supervisor))
    assert :ok = validate_parsed_factory(Map.put(factory, :ticket_supervisor, %{}))

    assert :ok =
             validate_parsed_factory(Map.put(factory, :ticket_supervisor, %{"enabled" => false, "pilot_issue_keys" => []}))

    malformed = [
      Map.put(factory, :ticket_supervisor, nil),
      Map.put(factory, :ticket_supervisor, %{enabled: nil, pilot_issue_keys: []}),
      Map.put(factory, :ticket_supervisor, %{"enabled" => false, "pilot_issue_keys" => nil}),
      factory
      |> Map.delete(:ticket_supervisor)
      |> Map.put("ticket_supervisor", %{"enabled" => false, "pilot_issue_keys" => nil})
    ]

    for attrs <- malformed do
      assert {:error, :invalid_ticket_supervisor_policy} = validate_parsed_factory(attrs)
    end
  end

  test "requires a safe branch prefix and complete enabled hibernation policy" do
    factory = valid_factory()

    assert {:error, :invalid_branch_prefix} = Policy.validate(%{factory | branch_prefix: "cgable/unsafe"})

    incomplete = %{factory | hibernation: %{"enabled" => true, "allowed_run_states" => []}}
    assert {:error, :hibernation_states_required} = Policy.validate(incomplete)
  end

  test "requires a separate read-only intake model route" do
    factory = valid_factory()
    without_intake = update_in(factory, [:models, "roles"], &Map.delete(&1, "orchestrator-intake"))

    assert {:error, {:model_route_unavailable, "orchestrator-intake", _reason}} =
             Policy.validate(without_intake)
  end

  test "rejects an unrecognized specification authorization policy" do
    factory = valid_factory() |> Map.put(:specification_authorization_mode, "unreviewed")
    assert {:error, :invalid_specification_authorization_mode} = Policy.validate(factory)
  end

  test "Desktop broker enables authorized MR feedback by default" do
    factory = valid_factory() |> put_in([:manual_validation, "required_apps"], ["polaris-app"])
    desktop = Map.put(factory, :task_transport, "desktop_broker")

    assert :ok = Policy.validate(desktop)

    assert {:error, :review_feedback_author_ids_required} =
             Policy.validate(Map.put(desktop, :review_feedback, %{"allowed_author_ids" => []}))
  end

  defp valid_factory do
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
      branch_prefix: "cgable",
      queue: %{
        "assignee" => "currentUser()",
        "statuses" => ["READY"],
        "factory_labels" => ["ai-ready"]
      },
      repositories: %{
        "repo" => %{
          "path" => System.tmp_dir!(),
          "base_branch" => "master",
          "codex_project_id" => "project-repo",
          "gitlab_project" => "example/repo",
          "route_labels" => ["repo-example"]
        }
      },
      models: %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"test" => "gpt-test"}},
        "roles" => roles,
        "delivery_routing" => %{
          "default_role" => "feature-writer",
          "high_risk_role" => "feature-writer-high-risk",
          "high_risk_values" => ["high"],
          "unknown_risk_is_high" => true
        }
      },
      cleanup: %{},
      hibernation: %{},
      manual_validation: %{
        "enabled" => true,
        "allowed_environments" => ["cpp-test"],
        "require_slack_coordination" => true,
        "allow_production" => false,
        "allow_database_ddl" => false
      }
    }
  end

  defp startup_root do
    root = Path.join(System.tmp_dir!(), "factory-startup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp startup_factory(root, policy) do
    valid_factory()
    |> put_in([:manual_validation, "required_apps"], ["polaris-app"])
    |> Map.merge(%{enabled: true, database: Path.join(root, "factory.sqlite"), ticket_supervisor: policy})
  end

  defp validate_parsed_factory(factory_attrs) do
    with {:ok, settings} <- Schema.parse(%{"factory" => factory_attrs}) do
      Policy.validate(settings.factory)
    end
  end
end
