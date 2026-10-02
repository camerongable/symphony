defmodule SymphonyElixir.FactoryMrFeedbackPollTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{MrFeedbackLedger, MrFeedbackMcpReader, MrFeedbackPoller, RunLedger, Store}

  defmodule FakeGitLabConnector do
    @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def call(tool, args, _opts) do
      send(self(), {:gitlab_call, tool, args})

      case tool do
        "get_merge_request" ->
          mr =
            case Process.get(:feedback_mr_queue) do
              [next | rest] ->
                Process.put(:feedback_mr_queue, rest)
                next

              _other ->
                Process.get(:feedback_mr)
            end

          case mr do
            {:error, _reason} = error -> error
            result -> {:ok, result}
          end

        "mr_discussions" ->
          Map.fetch!(Process.get(:feedback_pages), args["page"])
      end
    end
  end

  defmodule FakeJiraReader do
    @spec issue(String.t(), keyword()) :: {:ok, map()}
    def issue(key, _opts) do
      send(self(), {:jira_issue, key})
      {:ok, Process.get(:feedback_jira)}
    end
  end

  defmodule FakeJiraFailureReader do
    @spec issue(String.t(), keyword()) :: {:error, atom()}
    def issue(_key, _opts), do: {:error, :jira_offline}
  end

  defmodule FakeFailingLedger do
    @spec supersede_changed(term(), String.t(), pos_integer(), String.t(), pos_integer(), String.t()) :: :ok
    def supersede_changed(_store, _project, _iid, _discussion_id, _note_id, _body), do: :ok

    @spec record_candidate(term(), map()) :: {:error, atom()}
    def record_candidate(_store, _candidate), do: {:error, :ledger_unavailable}
  end

  setup do
    token = System.unique_integer([:positive])
    database = Path.join(System.tmp_dir!(), "symphony-feedback-#{token}.sqlite")
    {:ok, store} = Store.start_link(database: database)
    on_exit(fn -> File.rm(database) end)

    route = %{
      "repo_key" => "grail",
      "gitlab_project" => "grailbio/grail",
      "gitlab_project_id" => "33747681"
    }

    run = %{
      "run_id" => "delivery-42",
      "issue_key" => "PPL-42",
      "kind" => "DELIVERY",
      "state" => "READY_FOR_REVIEW",
      "repo_key" => "grail",
      "mr_iid" => 123,
      "mr_url" => "https://gitlab.example/grailbio/grail/-/merge_requests/123",
      "branch" => "factory/PPL-42",
      "candidate_sha" => String.duplicate("a", 40)
    }

    assert {:ok, _registered} = RunLedger.register(store, run)

    Process.put(:feedback_mr, %{
      "iid" => "123",
      "project_id" => "33747681",
      "web_url" => run["mr_url"],
      "state" => "opened",
      "source_branch" => run["branch"],
      "sha" => run["candidate_sha"]
    })

    Process.put(:feedback_jira, %{"key" => "PPL-42", "labels" => ["repo-grail", "ai-review"]})

    Process.put(:feedback_pages, %{
      1 => {:ok, page(1, 2, [%{"id" => "discussion-1", "notes" => [note("51", "@Symphony review this")]}])},
      2 => {:ok, page(2, nil, [%{"id" => "discussion-2", "notes" => [note("52", "No mention")]}])}
    })

    %{store: store, database: database, route: route, run: run}
  end

  test "skips connector startup when no review-ready MR remains", context do
    assert MrFeedbackPoller.review_runs?(context.store)
    assert {:ok, _run} = RunLedger.update(context.store, context.run["run_id"], %{state: "REVIEW_WRITING"})
    refute MrFeedbackPoller.review_runs?(context.store)
  end

  test "reads every page and normalizes GitLab string identifiers", context do
    assert {:ok, %{mr: mr, discussions: discussions}} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )

    assert mr["iid"] == 123
    assert Enum.map(discussions, & &1["id"]) == ["discussion-1", "discussion-2"]
    assert get_in(hd(discussions), ["notes", Access.at(0), "id"]) == 51
    assert get_in(hd(discussions), ["notes", Access.at(0), "author", "id"]) == 12
    assert_received {:gitlab_call, "mr_discussions", %{"page" => 2}}
    assert_received {:gitlab_call, "get_merge_request", %{"merge_request_iid" => "123"}}
    assert_received {:gitlab_call, "get_merge_request", %{"merge_request_iid" => "123"}}
  end

  test "rejects an MR head change after paginated discussions", context do
    first = Process.get(:feedback_mr)
    Process.put(:feedback_mr_queue, [first, Map.put(first, "sha", String.duplicate("b", 40))])

    assert {:error, :gitlab_feedback_mr_mismatch} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )

    assert_received {:gitlab_call, "mr_discussions", %{"page" => 2}}
  end

  test "fails closed on a missing or inconsistent discussion page", context do
    Process.put(:feedback_pages, %{
      1 => {:ok, page(1, 2, [%{"id" => "discussion-1", "notes" => [note("51", "@Symphony hi")]}])},
      2 => {:ok, page(3, nil, [])}
    })

    assert {:error, :gitlab_discussion_page_mismatch} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )
  end

  test "rejects a page that claims completion before the reported total", context do
    Process.put(:feedback_pages, %{
      1 => {:ok, %{"items" => [], "pagination" => %{"x_page" => 1, "x_next_page" => nil, "x_total_pages" => 2}}}
    })

    assert {:error, :gitlab_discussion_page_mismatch} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )
  end

  test "rejects moved heads and mismatched MR identities before reading discussions", context do
    for {field, value, expected} <- [
          {"sha", String.duplicate("b", 40), :gitlab_feedback_mr_mismatch},
          {"iid", "124", :gitlab_feedback_mr_mismatch},
          {"project_id", "1", :gitlab_feedback_mr_mismatch},
          {"project_id", "invalid", :gitlab_identifier_invalid},
          {"project_id", nil, :gitlab_identifier_invalid}
        ] do
      Process.put(:feedback_mr, Map.put(Process.get(:feedback_mr), field, value))

      assert {:error, ^expected} =
               MrFeedbackMcpReader.fetch(context.route, context.run,
                 connector: FakeGitLabConnector,
                 workspace: "/tmp/factory-controller"
               )

      refute_received {:gitlab_call, "mr_discussions", _}
    end
  end

  test "supports a scoped project path and rejects an absent route or MR read", context do
    route = Map.delete(context.route, "gitlab_project_id")

    assert {:ok, _result} =
             MrFeedbackMcpReader.fetch(route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )

    assert_received {:gitlab_call, "get_merge_request", %{"project_id" => "grailbio%2Fgrail"}}

    assert {:error, :gitlab_feedback_route_invalid} =
             MrFeedbackMcpReader.fetch(%{}, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )

    Process.put(:feedback_mr, {:error, :offline})

    assert {:error, :offline} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )
  end

  test "rejects incomplete, duplicated, malformed, and over-limit discussion pages", context do
    invalid_id_note = note("x", "@Symphony")

    variants = [
      {%{}, :gitlab_discussion_page_invalid},
      {page(1, nil, [%{"id" => "broken"}]), :gitlab_discussion_invalid},
      {page(1, nil, [%{"id" => "a", "notes" => []}, %{"id" => "a", "notes" => []}]), :gitlab_discussion_duplicate},
      {page(1, nil, [%{"id" => "a", "notes" => [invalid_id_note]}]), :gitlab_identifier_invalid},
      {page(1, nil, [%{"id" => "a", "notes" => [nil]}]), :gitlab_discussion_note_invalid}
    ]

    for {first_page, expected} <- variants do
      Process.put(:feedback_pages, %{1 => {:ok, first_page}})

      assert {:error, ^expected} =
               MrFeedbackMcpReader.fetch(context.route, context.run,
                 connector: FakeGitLabConnector,
                 workspace: "/tmp/factory-controller"
               )
    end

    pages = Map.new(1..20, fn page_number -> {page_number, {:ok, page(page_number, page_number + 1, [])}} end)
    Process.put(:feedback_pages, pages)

    assert {:error, :gitlab_discussion_page_limit_exceeded} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )
  end

  test "rejects duplicate discussions across pages and malformed next-page cursors", context do
    first = page(1, 2, [%{"id" => "same", "notes" => []}])
    second = page(2, nil, [%{"id" => "same", "notes" => []}])
    Process.put(:feedback_pages, %{1 => {:ok, first}, 2 => {:ok, second}})

    assert {:error, :gitlab_discussion_duplicate} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )

    for cursor <- ["not-a-page", 3] do
      Process.put(:feedback_pages, %{1 => {:ok, page(1, cursor, [])}})

      assert {:error, reason} =
               MrFeedbackMcpReader.fetch(context.route, context.run,
                 connector: FakeGitLabConnector,
                 workspace: "/tmp/factory-controller"
               )

      assert reason in [:gitlab_identifier_invalid, :gitlab_discussion_page_mismatch]
    end

    Process.put(:feedback_pages, %{
      1 => {:ok, %{"items" => [], "pagination" => %{"x_page" => 1, "x_next_page" => "", "x_total_pages" => 1}}}
    })

    assert {:ok, %{discussions: []}} =
             MrFeedbackMcpReader.fetch(context.route, context.run,
               connector: FakeGitLabConnector,
               workspace: "/tmp/factory-controller"
             )
  end

  test "records a single mention and unchanged polls do not create another receipt", context do
    factory = %{
      review_feedback: %{"enabled" => true, "allowed_author_ids" => [12], "bot_author_id" => 99},
      repositories: %{"grail" => context.route}
    }

    polling = %{store: context.store, factory: factory}
    opts = [workspace: "/tmp/factory-controller", jira_reader: FakeJiraReader, gitlab_connector: FakeGitLabConnector]

    assert %{recorded: 1, failures: []} = MrFeedbackPoller.poll(polling, opts)
    assert %{recorded: 0, failures: []} = MrFeedbackPoller.poll(polling, opts)
    assert length(MrFeedbackLedger.pending(context.store)) == 1

    GenServer.stop(context.store)
    {:ok, restarted} = Store.start_link(database: context.database)
    assert %{recorded: 0, failures: []} = MrFeedbackPoller.poll(%{polling | store: restarted}, opts)
    assert length(MrFeedbackLedger.pending(restarted)) == 1
    GenServer.stop(restarted)
  end

  test "factory reply by the same authorized account is ignored by durable marker", context do
    reply = note("53", "@Symphony acknowledged\n<!-- symphony-feedback:original-key -->")
    Process.put(:feedback_pages, %{1 => {:ok, page(1, nil, [%{"id" => "discussion-1", "notes" => [reply]}])}})
    factory = %{review_feedback: %{"allowed_author_ids" => [12]}, repositories: %{"grail" => context.route}}

    assert %{recorded: 0, failures: []} =
             MrFeedbackPoller.poll(%{store: context.store, factory: factory},
               workspace: "/tmp/factory-controller",
               jira_reader: FakeJiraReader,
               gitlab_connector: FakeGitLabConnector
             )

    assert MrFeedbackLedger.pending(context.store) == []
  end

  test "an edit that removes the mention supersedes the old pending receipt", context do
    factory = %{
      review_feedback: %{"allowed_author_ids" => [12], "bot_author_id" => 99},
      repositories: %{"grail" => context.route}
    }

    polling = %{store: context.store, factory: factory}
    opts = [workspace: "/tmp/factory-controller", jira_reader: FakeJiraReader, gitlab_connector: FakeGitLabConnector]
    assert %{recorded: 1, failures: []} = MrFeedbackPoller.poll(polling, opts)

    edited_note = note("51", "Never mind, no agent action needed")
    Process.put(:feedback_pages, %{1 => {:ok, page(1, nil, [%{"id" => "discussion-1", "notes" => [edited_note]}])}})

    assert %{recorded: 0, failures: []} = MrFeedbackPoller.poll(polling, opts)
    assert MrFeedbackLedger.pending(context.store) == []
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE note_id = 51")["status"] == "SUPERSEDED"
  end

  test "a moved MR head during pagination cannot create a receipt", context do
    first = Process.get(:feedback_mr)
    Process.put(:feedback_mr_queue, [first, Map.put(first, "sha", String.duplicate("b", 40))])

    factory = %{
      review_feedback: %{"allowed_author_ids" => [12], "bot_author_id" => 99},
      repositories: %{"grail" => context.route}
    }

    assert %{recorded: 0, failures: [{"delivery-42", :gitlab_feedback_mr_mismatch}]} =
             MrFeedbackPoller.poll(%{store: context.store, factory: factory},
               workspace: "/tmp/factory-controller",
               jira_reader: FakeJiraReader,
               gitlab_connector: FakeGitLabConnector
             )

    assert MrFeedbackLedger.pending(context.store) == []
  end

  test "does not read GitLab after the Jira review label disappears", context do
    Process.put(:feedback_jira, %{"key" => "PPL-42", "labels" => ["repo-grail"]})
    factory = %{review_feedback: %{"allowed_author_ids" => [12]}, repositories: %{"grail" => context.route}}

    assert %{recorded: 0, failures: []} =
             MrFeedbackPoller.poll(%{store: context.store, factory: factory},
               workspace: "/tmp/factory-controller",
               jira_reader: FakeJiraReader,
               gitlab_connector: FakeGitLabConnector
             )

    refute_received {:gitlab_call, _, _}
  end

  test "isolates a missing route, Jira outage, GitLab outage, and ledger rejection", context do
    factory = %{
      review_feedback: %{"allowed_author_ids" => [12]},
      repositories: %{"grail" => context.route}
    }

    polling = %{store: context.store, factory: factory}
    opts = [workspace: "/tmp/factory-controller", jira_reader: FakeJiraReader, gitlab_connector: FakeGitLabConnector]

    assert %{recorded: 0, failures: [{"delivery-42", :review_feedback_route_missing}]} =
             MrFeedbackPoller.poll(%{polling | factory: %{factory | repositories: %{}}}, opts)

    assert %{recorded: 0, failures: [{"delivery-42", :jira_offline}]} =
             MrFeedbackPoller.poll(polling, Keyword.put(opts, :jira_reader, FakeJiraFailureReader))

    Process.put(:feedback_mr, {:error, :gitlab_offline})
    assert %{recorded: 0, failures: [{"delivery-42", :gitlab_offline}]} = MrFeedbackPoller.poll(polling, opts)

    Process.put(:feedback_mr, %{
      "iid" => "123",
      "project_id" => "33747681",
      "web_url" => context.run["mr_url"],
      "state" => "opened",
      "source_branch" => context.run["branch"],
      "sha" => context.run["candidate_sha"]
    })

    assert %{recorded: 0, failures: [{"delivery-42", :ledger_unavailable}]} =
             MrFeedbackPoller.poll(polling, Keyword.put(opts, :ledger, FakeFailingLedger))

    assert MrFeedbackLedger.pending(context.store) == []
  end

  defp page(current, next_page, items) do
    %{
      "items" => items,
      "pagination" => %{
        "x_page" => current,
        "x_next_page" => next_page,
        "x_total_pages" => if(next_page, do: next_page, else: current)
      }
    }
  end

  defp note(id, body) do
    %{
      "id" => id,
      "body" => body,
      "updated_at" => "2026-09-30T10:00:00Z",
      "author" => %{"id" => "12"},
      "system" => false
    }
  end
end
