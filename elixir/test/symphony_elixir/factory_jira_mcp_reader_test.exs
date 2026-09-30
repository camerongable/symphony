defmodule SymphonyElixir.FactoryJiraMcpReaderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.JiraMcpReader

  defmodule Connector do
    @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def call("jira_search", args, _opts) do
      send(self(), {:search_args, args})

      case Process.get(:search_pages) do
        [page | rest] ->
          Process.put(:search_pages, rest)
          {:ok, page}

        _other ->
          {:ok, Process.get(:search_page)}
      end
    end

    def call("jira_get_issue", args, _opts) do
      send(self(), {:issue_args, args})

      if Process.get(:issue_error_key) == args["issue_key"] do
        {:error, :jira_read_failed}
      else
        {:ok, Map.get(Process.get(:issues_by_key, %{}), args["issue_key"], Process.get(:issue))}
      end
    end
  end

  test "assignee intake preserves exact Markdown and comment bytes from Jira" do
    description = "## Ticket Delivery Contract\n\n**Spec revision:** 1\n"
    comment = "<!-- AI FACTORY CONTRACT BEGIN -->\n**exact**\n"
    Process.put(:search_page, %{"issues" => [%{"key" => "PPL-10035", "updated" => "2026-09-24T11:09:05Z"}]})
    Process.put(:issue, raw_issue(description, [%{"id" => "749500", "body" => comment}]))

    assert {:ok, [snapshot]} =
             JiraMcpReader.search("assignee = currentUser()", connector: Connector, workspace: "/tmp")

    assert snapshot["key"] == "PPL-10035"
    assert snapshot["description"] == description
    assert snapshot["status"] == "To Do"
    assert snapshot["project_key"] == "PPL"
    assert snapshot["parent_key"] == "PPL-8447"
    assert snapshot["labels"] == ["repo-grail", "spec-needed"]
    assert hd(snapshot["comments"])["text"] == comment
    assert_receive {:search_args, %{"limit" => 50, "start_at" => 0}}
    assert_receive {:issue_args, %{"issue_key" => "PPL-10035", "comment_limit" => 100}}
  end

  test "a changed issue cannot be admitted from a stale search hit" do
    Process.put(:search_page, %{"issues" => [%{"key" => "PPL-10035", "updated" => "old"}]})
    Process.put(:issue, raw_issue("exact", []))

    assert {:error, :jira_issue_changed_during_search} =
             JiraMcpReader.search("assignee = currentUser()", connector: Connector, workspace: "/tmp")
  end

  test "a potentially truncated comment set fails closed" do
    comments = Enum.map(1..100, &%{"id" => Integer.to_string(&1), "body" => "comment"})
    Process.put(:issue, raw_issue("exact", comments))

    assert {:error, :jira_issue_comments_truncated} =
             JiraMcpReader.issue("PPL-10035", connector: Connector, workspace: "/tmp")
  end

  test "search follows a cloud page token without dropping the next page" do
    Process.put(:search_pages, [
      %{"issues" => [], "nextPageToken" => "next"},
      %{"issues" => [%{"key" => "PPL-10035"}]}
    ])

    Process.put(:issue, raw_issue("exact", []))

    assert {:ok, [%{"key" => "PPL-10035"}]} =
             JiraMcpReader.search("assigned", connector: Connector, workspace: "/tmp")

    assert_receive {:search_args, %{"start_at" => 0}}
    assert_receive {:search_args, %{"page_token" => "next"}}
  end

  test "search follows a full server page by start index" do
    keys = Enum.map(1..50, &"PPL-#{&1}")

    Process.put(:search_pages, [
      %{"issues" => Enum.map(keys, &%{"key" => &1})},
      %{"issues" => []}
    ])

    Process.put(
      :issues_by_key,
      Map.new(keys, fn key -> {key, Map.put(raw_issue("exact", []), "key", key)} end)
    )

    assert {:ok, snapshots} = JiraMcpReader.search("assigned", connector: Connector, workspace: "/tmp")
    assert length(snapshots) == 50
    assert_receive {:search_args, %{"start_at" => 0}}
    assert_receive {:search_args, %{"start_at" => 50}}
  end

  test "runaway pagination fails closed" do
    Process.put(:search_page, %{"issues" => [], "nextPageToken" => "again"})

    assert {:error, :jira_search_page_limit_exceeded} =
             JiraMcpReader.search("assigned", connector: Connector, workspace: "/tmp")
  end

  test "malformed search pages and issue reads fail closed" do
    Process.put(:search_page, %{"issues" => "not an array"})

    assert {:error, :jira_search_page_invalid} =
             JiraMcpReader.search("assigned", connector: Connector, workspace: "/tmp")

    Process.put(:search_page, %{"issues" => [%{"key" => "PPL-10035"}]})
    Process.put(:issue_error_key, "PPL-10035")

    assert {:error, :jira_read_failed} =
             JiraMcpReader.search("assigned", connector: Connector, workspace: "/tmp")
  end

  test "an issue key mismatch and malformed fields are rejected" do
    variants = [
      {Map.put(raw_issue("exact", []), "key", "PPL-OTHER"), :jira_issue_key_mismatch},
      {Map.put(raw_issue("exact", []), "description", nil), :jira_issue_snapshot_invalid},
      {"not an issue map", :jira_issue_snapshot_invalid},
      {Map.put(raw_issue("exact", []), "project", nil), :jira_issue_project_invalid},
      {Map.put(raw_issue("exact", []), "status", nil), :jira_issue_status_invalid},
      {Map.put(raw_issue("exact", []), "labels", nil), :jira_issue_labels_invalid},
      {Map.put(raw_issue("exact", []), "labels", [nil]), :jira_issue_labels_invalid},
      {Map.put(raw_issue("exact", []), "comments", nil), :jira_issue_comments_invalid},
      {Map.put(raw_issue("exact", []), "comments", [%{"id" => "1"}]), :jira_issue_comments_invalid}
    ]

    Enum.each(variants, fn {raw, reason} ->
      Process.put(:issue, raw)

      assert {:error, ^reason} =
               JiraMcpReader.issue("PPL-10035", connector: Connector, workspace: "/tmp")
    end)
  end

  defp raw_issue(description, comments) do
    %{
      "id" => "10035",
      "key" => "PPL-10035",
      "summary" => "Specify PDF work",
      "description" => description,
      "status" => %{"name" => "To Do"},
      "labels" => ["repo-grail", "spec-needed"],
      "project" => %{"key" => "PPL"},
      "parent" => %{"key" => "PPL-8447"},
      "assignee" => %{"account_id" => "user-1"},
      "components" => [],
      "browse_url" => "https://jira.example/PPL-10035",
      "updated" => "2026-09-24T11:09:05Z",
      "comments" => comments
    }
  end
end
