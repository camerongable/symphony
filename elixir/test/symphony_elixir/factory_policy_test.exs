defmodule SymphonyElixir.FactoryPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Policy

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

  test "ticket supervisor policy is disabled by default and never bypasses the capability fence" do
    factory = valid_factory() |> put_in([:manual_validation, "required_apps"], ["polaris-app"])
    assert :ok = Policy.validate(factory)
    assert :ok = Policy.validate(Map.put(factory, :ticket_supervisor, %{}))

    assert :ok =
             Policy.validate(Map.put(factory, :ticket_supervisor, %{"enabled" => false, "pilot_issue_keys" => ["PPL-123"]}))

    assert {:error, :ticket_supervisor_runtime_capability_unproven} =
             Policy.validate(Map.put(factory, :ticket_supervisor, %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}))
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
end
