defmodule SymphonyElixir.FactoryJiraMcpWriterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Contract, JiraMcpWriter}

  defmodule Connector do
    def call("jira_get_issue", _args, _opts), do: {:ok, Process.get(:jira_writer_issue)}

    def call("jira_add_comment", _args, _opts) do
      send(self(), :duplicate_comment_attempt)
      {:error, :duplicate_comment_attempt}
    end
  end

  defmodule AuthorizationConnector do
    def call("jira_get_issue", _args, _opts), do: {:ok, Process.get(:jira_writer_issue)}

    def call("jira_add_comment", _args, _opts) do
      send(self(), :duplicate_comment_attempt)
      {:error, :duplicate_comment_attempt}
    end

    def call("jira_update_issue", %{"fields" => fields}, _opts) do
      %{"labels" => labels} = Jason.decode!(fields)
      Process.put(:jira_writer_issue, Map.put(Process.get(:jira_writer_issue), "labels", labels))
      send(self(), {:authorization_labels_updated, labels})
      {:ok, %{}}
    end
  end

  test "finishes authorization labels without reposting an existing exact comment" do
    contract = Contract.bind("PPL-9723", 8, "## Ticket Delivery Contract\n\n## Manual Validation\n- Required: no")
    authorization = Contract.automatic_authorization_marker(contract, "spec-run:specification-critic:1", String.duplicate("a", 64))
    before_labels = ["ai-running", "repo-grail"]
    after_labels = ["ai-ready", "repo-grail"]

    Process.put(:jira_writer_issue, %{
      "key" => contract.issue_key,
      "status" => "In Dev",
      "labels" => before_labels,
      "comments" => [%{"id" => "751982", "body" => authorization}]
    })

    run = %{
      "issue_key" => contract.issue_key,
      "snapshot_json" => Jason.encode!(%{"key" => contract.issue_key, "status" => "In Dev", "labels" => before_labels})
    }

    scope = %{mutations: [:comment, :labels], comment: authorization, labels: after_labels}

    assert {:ok, %{"status" => "PASS", "comment_id" => "751982", "labels" => ^after_labels}} =
             JiraMcpWriter.write(run, scope, authorization, connector: AuthorizationConnector, workspace: "/tmp")

    assert_received {:authorization_labels_updated, ^after_labels}
    refute_received :duplicate_comment_attempt
  end

  defmodule EventuallyVisibleConnector do
    def call("jira_get_issue", _args, _opts) do
      reads = Process.get(:jira_writer_reads, 0) + 1
      Process.put(:jira_writer_reads, reads)

      issue = Process.get(:jira_writer_issue)
      pending = Process.get(:jira_writer_pending_comment)
      visible_after = Process.get(:jira_writer_visible_after)

      issue =
        if is_binary(pending) and reads >= visible_after and
             not Enum.any?(issue["comments"], &(&1["body"] == pending)) do
          Map.update!(issue, "comments", &(&1 ++ [%{"id" => "750764", "body" => pending}]))
        else
          issue
        end

      Process.put(:jira_writer_issue, issue)
      {:ok, issue}
    end

    def call("jira_add_comment", %{"body" => body}, _opts) do
      Process.put(:jira_writer_adds, Process.get(:jira_writer_adds, 0) + 1)
      Process.put(:jira_writer_pending_comment, body)
      {:ok, %{"id" => "750764"}}
    end
  end

  test "reuses a Jira-rendered draft after proving its decoded contract payload" do
    contract = Contract.bind("PPL-9723", 2, "## Ticket Delivery Contract\n\n- AC-1: preserve bytes")
    draft = Contract.draft_comment(contract)

    jira_rendered =
      draft
      |> String.replace("\n```\n|", "\n\n```\n|")
      |> String.replace("\n```\nAI FACTORY CONTRACT END", "\n```\n\nAI FACTORY CONTRACT END")

    labels = ["repo-grail", "spec-needed"]

    Process.put(:jira_writer_issue, %{
      "key" => contract.issue_key,
      "status" => "To Do",
      "labels" => labels,
      "comments" => [%{"id" => "750753", "body" => jira_rendered}]
    })

    run = %{
      "issue_key" => contract.issue_key,
      "snapshot_json" => Jason.encode!(%{"key" => contract.issue_key, "status" => "To Do", "labels" => labels})
    }

    scope = %{mutations: [:comment], comment: draft, labels: labels}

    assert {:ok, %{"status" => "PASS", "comment_id" => "750753"}} =
             JiraMcpWriter.write(run, scope, contract.marker, connector: Connector, workspace: "/tmp")

    refute_received :duplicate_comment_attempt
  end

  test "reuses a Jira-rendered specification question request without reposting it" do
    request = Contract.input_request_comment("PPL-9723", ["Which notice should appear?"])

    jira_rendered =
      request
      |> String.replace("\n```\n|", "\n\n```\n|")
      |> String.replace("\n```\nReply", "\n```\n\nReply")
      |> String.replace("your answers:\nAI FACTORY", "your answers:\n\nAI FACTORY")

    labels = ["repo-grail", "spec-needed"]

    Process.put(:jira_writer_issue, %{
      "key" => "PPL-9723",
      "status" => "To Do",
      "labels" => labels,
      "comments" => [%{"id" => "750763", "body" => jira_rendered}]
    })

    run = %{
      "issue_key" => "PPL-9723",
      "snapshot_json" => Jason.encode!(%{"key" => "PPL-9723", "status" => "To Do", "labels" => labels})
    }

    scope = %{mutations: [:comment], comment: request, labels: labels}
    digest = Contract.questions_digest(["Which notice should appear?"])

    assert {:ok, %{"status" => "PASS", "comment_id" => "750763"}} =
             JiraMcpWriter.write(run, scope, digest, connector: Connector, workspace: "/tmp")

    refute_received :duplicate_comment_attempt
  end

  test "retries delayed Jira comment read-back without posting the comment twice" do
    contract = Contract.bind("PPL-9723", 3, "## Ticket Delivery Contract\n\n- AC-1: preserve bytes")
    labels = ["repo-grail", "spec-needed"]
    put_delayed_jira_issue(contract.issue_key, labels, 3)

    assert {:ok, %{"status" => "PASS", "comment_id" => "750764"}} =
             JiraMcpWriter.write(
               jira_run(contract.issue_key, labels),
               %{mutations: [:comment], comment: Contract.draft_comment(contract), labels: labels},
               contract.marker,
               connector: EventuallyVisibleConnector,
               workspace: "/tmp",
               readback_retry_delays_ms: [0, 0],
               readback_sleeper: fn _delay -> :ok end
             )

    assert Process.get(:jira_writer_reads) == 3
    assert Process.get(:jira_writer_adds) == 1
  end

  test "leaves an unobserved Jira comment for reconciliation after bounded read-back" do
    contract = Contract.bind("PPL-9723", 3, "## Ticket Delivery Contract\n\n- AC-1: preserve bytes")
    labels = ["repo-grail", "spec-needed"]
    put_delayed_jira_issue(contract.issue_key, labels, 99)

    assert {:error, :jira_comment_readback_mismatch} =
             JiraMcpWriter.write(
               jira_run(contract.issue_key, labels),
               %{mutations: [:comment], comment: Contract.draft_comment(contract), labels: labels},
               contract.marker,
               connector: EventuallyVisibleConnector,
               workspace: "/tmp",
               readback_retry_delays_ms: [0, 0],
               readback_sleeper: fn _delay -> :ok end
             )

    assert Process.get(:jira_writer_reads) == 4
    assert Process.get(:jira_writer_adds) == 1
  end

  defp put_delayed_jira_issue(issue_key, labels, visible_after) do
    Process.put(:jira_writer_issue, %{
      "key" => issue_key,
      "status" => "To Do",
      "labels" => labels,
      "comments" => []
    })

    Process.put(:jira_writer_visible_after, visible_after)
  end

  defp jira_run(issue_key, labels) do
    %{
      "issue_key" => issue_key,
      "snapshot_json" => Jason.encode!(%{"key" => issue_key, "status" => "To Do", "labels" => labels})
    }
  end
end
