defmodule SymphonyElixir.FactoryModelRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.ModelRouter

  @policy %{
    "default_provider" => "codex",
    "providers" => %{
      "codex" => %{
        "fast" => "fast-model",
        "balanced" => "balanced-model",
        "deep" => "deep-model"
      },
      "alternate" => %{"fast" => "alternate-fast"}
    },
    "roles" => %{
      "explorer" => %{
        "model_class" => "fast",
        "reasoning_effort" => "medium"
      },
      "feature-writer" => %{
        "model_class" => "balanced",
        "reasoning_effort" => "high"
      },
      "feature-writer-high-risk" => %{
        "model_class" => "deep",
        "reasoning_effort" => "xhigh"
      }
    },
    "delivery_routing" => %{
      "default_role" => "feature-writer",
      "high_risk_role" => "feature-writer-high-risk",
      "high_risk_values" => ["high", "critical", "unknown"],
      "high_risk_signals" => ["database-migration", "security"],
      "unknown_risk_is_high" => true
    }
  }

  test "resolves an explicit role" do
    assert {:ok, route} = ModelRouter.resolve(@policy, "explorer")
    assert route.model == "fast-model"
    assert route.reasoning_effort == "medium"
    assert route.routing_reason == "explicit-role"
  end

  test "keeps a low-risk writer on the balanced route" do
    assert {:ok, route} = ModelRouter.resolve(@policy, "feature-writer", risk: "low")
    assert route.resolved_role == "feature-writer"
    assert route.model == "balanced-model"
    assert route.routing_reason == "risk:low"
  end

  test "escalates a writer from a risk signal" do
    assert {:ok, route} =
             ModelRouter.resolve(@policy, "feature-writer",
               risk: "low",
               risk_signals: [" security ", "database-migration"]
             )

    assert route.resolved_role == "feature-writer-high-risk"
    assert route.model == "deep-model"
    assert route.reasoning_effort == "xhigh"
    assert route.routing_reason == "high-risk-signal:database-migration,security"
  end

  test "treats unknown risk as high by default" do
    assert {:ok, route} = ModelRouter.resolve(@policy, "feature-writer")
    assert route.resolved_role == "feature-writer-high-risk"
    assert route.routing_reason == "risk:unknown"
  end

  test "fails closed on an unavailable route" do
    assert {:error, {:missing_model_policy, "roles.missing"}} =
             ModelRouter.resolve(@policy, "missing")

    assert {:error, {:missing_model_policy, "providers.unknown"}} =
             ModelRouter.resolve(@policy, "explorer", provider: "unknown")
  end
end
