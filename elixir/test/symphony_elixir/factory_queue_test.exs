defmodule SymphonyElixir.FactoryQueueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Queue

  test "builds an assignee-wide JQL query with optional filters omitted" do
    queue = %{
      "assignee" => "currentUser()",
      "statuses" => ["READY", "TO DO"],
      "factory_labels" => ["spec-needed", "ai-ready"],
      "projects" => [],
      "epics" => []
    }

    assert {:ok, jql} = Queue.jql(queue)
    assert jql =~ "assignee = currentUser()"
    assert jql =~ ~s|status IN ("READY", "TO DO")|
    refute jql =~ "project IN"
    refute jql =~ "parent IN"
  end

  test "classifies work and rejects conflicting authorization labels" do
    assert Queue.classify(%{"labels" => ["spec-needed"]}) == :specification
    assert Queue.classify(%{"labels" => ["ai-ready"]}) == :delivery
    assert Queue.classify(%{"labels" => ["ai-testing"]}) == :reconcile

    assert Queue.classify(%{"labels" => ["ai-ready", "spec-needed"]}) ==
             {:error, :ambiguous_factory_labels}
  end

  test "routes only from explicit Jira metadata and fails on ambiguity" do
    snapshot = %{
      "labels" => ["repo-grail", "ai-ready"],
      "components" => ["doc-extract"],
      "project_key" => "PPL"
    }

    route = %{
      "path" => "/repo/grail",
      "base_branch" => "master",
      "gitlab_project" => "grailbio/grail",
      "route_labels" => ["repo-grail"]
    }

    assert {:ok, %{"repo_key" => "grail"}} = Queue.route(snapshot, %{"grail" => route})
    assert Queue.route(%{snapshot | "labels" => ["ai-ready"]}, %{"grail" => route}) == {:error, :routing_required}

    assert Queue.route(snapshot, %{"grail" => route, "duplicate" => route}) ==
             {:error, :ambiguous_repository_route}
  end
end
