defmodule SymphonyElixir.FactoryMrFeedbackConsumerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Control, MrFeedback, MrFeedbackConsumer, MrFeedbackLedger}
  alias SymphonyElixir.Factory.{RunLedger, StageSchemas, Store}

  defmodule FakeJiraReader do
    @spec issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
    def issue(_key, _opts), do: Process.get(:feedback_jira_result)
  end

  defmodule FakeGitLabReader do
    @spec fetch(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def fetch(_route, _run, _opts) do
      case Process.get(:feedback_gitlab_result) do
        {:ok, %{discussions: _discussions} = result} ->
          {:ok, with_reply(result, Process.get(:feedback_reply))}

        error ->
          error
      end
    end

    defp with_reply(result, nil), do: result

    defp with_reply(result, reply) do
      discussions =
        Enum.map(result.discussions, fn discussion ->
          if is_nil(reply["discussion_id"]) or reply["discussion_id"] == discussion["id"],
            do: Map.update!(discussion, "notes", &(&1 ++ [reply])),
            else: discussion
        end)

      %{result | discussions: discussions}
    end
  end

  defmodule FakeGitLabConnector do
    @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def call("whoami", %{}, _opts), do: Process.get(:feedback_whoami, {:ok, %{"id" => "99"}})
  end

  defmodule FakeControllerTask do
    @spec run(map(), Path.t(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def run(_factory, _workspace, _issue, prompt, _schema, opts) do
      send(self(), {:controller_request, prompt, opts})
      Process.get(:feedback_controller_result)
    end
  end

  defmodule FakeDesktopRequest do
    @spec get(term(), String.t()) :: {:ok, map()}
    def get(_store, _key), do: {:ok, Process.get(:completed_feedback_request)}

    @spec payload_intact?(map()) :: boolean()
    def payload_intact?(_request), do: true
  end

  setup do
    {:ok, store} = Store.start_link(database: ":memory:")
    Control.initialize(store, %{scope: "test", dispatcher_id: "dispatcher"})
    Control.record_controller_task(store, %{scope: "test"}, "controller-thread", "prior-turn", %{})

    run = %{
      run_id: "delivery-1",
      issue_key: "PPL-42",
      kind: "DELIVERY",
      state: "READY_FOR_REVIEW",
      repo_key: "grail",
      branch: "factory/PPL-42",
      candidate_sha: String.duplicate("a", 40),
      mr_iid: 123,
      mr_url: "https://gitlab.example/grail/-/merge_requests/123"
    }

    {:ok, %{run: persisted}} = RunLedger.register(store, run)
    route = %{"repo_key" => "grail", "gitlab_project" => "grailbio/grail"}
    jira = %{"key" => "PPL-42", "labels" => ["ai-review"]}

    mr = %{
      "project" => route["gitlab_project"],
      "iid" => 123,
      "web_url" => run.mr_url,
      "source_branch" => run.branch,
      "sha" => run.candidate_sha,
      "state" => "opened"
    }

    note = %{
      "id" => 51,
      "author" => %{"id" => 12},
      "body" => "@Symphony why is this needed?",
      "updated_at" => "2026-09-30T10:00:00Z"
    }

    discussion = %{"id" => "discussion-1", "notes" => [note]}
    {:ok, candidate} = MrFeedback.candidate(persisted, route, jira, mr, discussion, note, [12], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(store, candidate)
    Process.put(:feedback_jira_result, {:ok, jira})
    Process.put(:feedback_gitlab_result, {:ok, %{mr: mr, discussions: [discussion]}})
    Process.put(:feedback_controller_result, {:error, {:desktop_request_pending, "PENDING", "request"}})

    context = %{
      store: store,
      control_server: self(),
      factory: %{
        scope: "test",
        repositories: %{"grail" => route},
        review_feedback: %{"allowed_author_ids" => [12], "bot_author_id" => 99}
      }
    }

    %{context: context, store: store, candidate: candidate, note: note, mr: mr, discussion: discussion}
  end

  test "no pending receipt is a no-op", %{context: context, store: store} do
    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'COMPLETE'")
    assert {:ok, :idle} = MrFeedbackConsumer.process_one(context, opts())
    refute_received {:controller_request, _, _}
  end

  test "notes found for the same MR share one controller request", context do
    second_note = %{context.note | "id" => 52, "body" => "@Symphony why is the default branch needed?"}
    second_discussion = %{"id" => "discussion-2", "notes" => [second_note]}
    {:ok, run} = RunLedger.get(context.store, "delivery-1")

    assert {:ok, candidate} =
             MrFeedback.candidate(
               run,
               context.context.factory.repositories["grail"],
               %{"key" => "PPL-42", "labels" => ["ai-review"]},
               context.mr,
               second_discussion,
               second_note,
               [12],
               99
             )

    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, candidate)

    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [context.discussion, second_discussion]}})

    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, prompt, _opts}
    assert prompt =~ "discussion-1"
    assert prompt =~ "discussion-2"

    assert [["CLAIMED", key], ["CLAIMED", key]] =
             Store.query!(context.store, "SELECT status, request_key FROM mr_feedback_notes ORDER BY note_id").rows
  end

  test "one batch atomically records a question reply and a source-change request", context do
    second_note = %{context.note | "id" => 52, "body" => "@Symphony please simplify the switch"}
    second_discussion = %{"id" => "discussion-2", "notes" => [second_note]}
    {:ok, run} = RunLedger.get(context.store, "delivery-1")

    {:ok, second} =
      MrFeedback.candidate(
        run,
        context.context.factory.repositories["grail"],
        %{"key" => "PPL-42", "labels" => ["ai-review"]},
        context.mr,
        second_discussion,
        second_note,
        [12],
        99
      )

    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, second)
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [context.discussion, second_discussion]}})
    reply_body = "The branch handles the fallback.\n<!-- symphony-feedback:#{context.candidate.feedback_key} -->"

    Process.put(:feedback_reply, %{
      "id" => 900,
      "discussion_id" => "discussion-1",
      "body" => reply_body,
      "author" => %{"id" => 99}
    })

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "results" => [
           %{"status" => "REPLIED", "feedback_key" => context.candidate.feedback_key, "reply_id" => "900", "reply_body" => reply_body, "reason" => ""},
           %{"status" => "CHANGE_REQUEST", "feedback_key" => second.feedback_key, "reply_id" => nil, "reply_body" => nil, "reason" => "Simplify the switch"}
         ]
       }}
    )

    assert {:ok, :batch_complete} = MrFeedbackConsumer.process_one(context.context, opts())

    assert [["COMPLETE", 900], ["CHANGE_REQUEST", nil]] =
             Store.query!(context.store, "SELECT status, reply_id FROM mr_feedback_notes ORDER BY note_id").rows
  end

  test "a pushed review change requires a thread reply, never another change classification", context do
    Store.query!(context.store, "UPDATE mr_feedback_notes SET reply_phase = 1")

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "results" => [
           %{"status" => "CHANGE_REQUEST", "feedback_key" => context.candidate.feedback_key, "reply_id" => nil, "reply_body" => nil, "reason" => "Change it again"}
         ]
       }}
    )

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, prompt, _opts}
    assert prompt =~ "Do not return CHANGE_REQUEST"
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes")["status"] == "RECONCILE_REQUIRED"
  end

  test "resolution readback requires its distinct marker and completes the pushed batch", context do
    key = context.candidate.feedback_key
    Store.query!(context.store, "UPDATE mr_feedback_notes SET reply_phase = 1")
    body = "The requested simplification is pushed. <!-- symphony-feedback:#{key}:resolution -->"
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 99}})
    Process.put(:feedback_controller_result, {:ok, %{"results" => [%{"status" => "REPLIED", "feedback_key" => key, "reply_id" => "900", "reply_body" => body, "reason" => ""}]}})

    assert {:ok, :batch_complete} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status, reply_id FROM mr_feedback_notes") == %{"status" => "COMPLETE", "reply_id" => 900}
    assert {:ok, :idle} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, _, _}
    refute_received {:controller_request, _, _}
  end

  test "one question uses the same claimed Desktop request on repeated pending checks", context do
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert [receipt] = Store.query!(context.store, "SELECT status, request_key FROM mr_feedback_notes").rows
    assert receipt |> hd() == "CLAIMED"
    assert is_binary(Enum.at(receipt, 1))
    assert_received {:controller_request, first_prompt, first_opts}
    assert_received {:controller_request, second_prompt, second_opts}
    assert first_prompt == second_prompt
    assert first_opts[:wait_timeout_ms] == 2_000
    assert second_opts[:wait_timeout_ms] == 2_000
  end

  test "exact-thread reply is accepted only after body and ID readback", context do
    key = context.candidate.feedback_key
    body = "The guard protects a stale source head.\n<!-- symphony-feedback:#{key} -->"
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 99}})

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "status" => "REPLIED",
         "feedback_key" => key,
         "reply_id" => "900",
         "reply_body" => body,
         "reason" => ""
       }}
    )

    assert {:ok, :complete} =
             MrFeedbackConsumer.process_one(context.context, Keyword.put(opts(), :gitlab_app_server, FakeGitLabConnector))

    assert Store.one!(context.store, "SELECT status, reply_id FROM mr_feedback_notes") == %{
             "status" => "COMPLETE",
             "reply_id" => 900
           }
  end

  test "a source change or missing Jira readback stops before claim", context do
    Process.put(:feedback_jira_result, {:error, :jira_offline})
    assert {:error, :jira_offline} = MrFeedbackConsumer.process_one(context.context, opts())
    Process.put(:feedback_jira_result, {:ok, %{"key" => "PPL-42", "labels" => ["ai-review"]}})
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [%{context.discussion | "notes" => [%{context.note | "body" => "@Symphony edited"}]}]}})
    assert {:ok, :dismissed} = MrFeedbackConsumer.process_one(context.context, opts())
    assert MrFeedbackLedger.pending(context.store) == []
    refute_received {:controller_request, _, _}
  end

  test "a claimed receipt with changed source remains claimed for request reconciliation", context do
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [%{context.discussion | "notes" => []}]}})

    assert {:error, :feedback_source_changed} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes")["status"] == "CLAIMED"
  end

  test "a withdrawn oldest note is dismissed so the next receipt can proceed", context do
    {:ok, run} = RunLedger.get(context.store, "delivery-1")
    route = context.context.factory.repositories["grail"]
    jira = %{"key" => "PPL-42", "labels" => ["ai-review"]}
    next_note = %{context.note | "id" => 52, "body" => "@Symphony another question"}
    discussion = %{context.discussion | "notes" => [context.note, next_note]}
    {:ok, second} = MrFeedback.candidate(run, route, jira, context.mr, discussion, next_note, [12], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, second)
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [%{discussion | "notes" => [next_note]}]}})

    assert {:ok, :dismissed} = MrFeedbackConsumer.process_one(context.context, opts())
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE note_id = 51")["status"] == "SUPERSEDED"
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE note_id = 52")["status"] == "CLAIMED"
  end

  test "reply from a non-bot author cannot prove completion", context do
    key = context.candidate.feedback_key
    body = "Answer\n<!-- symphony-feedback:#{key} -->"
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 12}})
    Process.put(:feedback_controller_result, {:ok, %{"status" => "REPLIED", "feedback_key" => key, "reply_id" => "900", "reply_body" => body, "reason" => ""}})

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes")["status"] == "RECONCILE_REQUIRED"
  end

  test "reply author is resolved from authenticated GitLab identity when no bot ID is configured", context do
    key = context.candidate.feedback_key
    body = "Answer\n<!-- symphony-feedback:#{key} -->"
    factory = %{context.context.factory | review_feedback: %{"allowed_author_ids" => [12]}}
    Process.put(:feedback_whoami, {:ok, %{"id" => "11599766"}})
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 11_599_766}})
    Process.put(:feedback_controller_result, {:ok, %{"status" => "REPLIED", "feedback_key" => key, "reply_id" => "900", "reply_body" => body, "reason" => ""}})

    assert {:ok, :complete} = MrFeedbackConsumer.process_one(%{context.context | factory: factory}, opts())
  end

  test "unproven authenticated GitLab identity quarantines reply", context do
    key = context.candidate.feedback_key
    body = "Answer\n<!-- symphony-feedback:#{key} -->"
    Process.put(:feedback_whoami, {:ok, %{"id" => "invalid"}})
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 99}})
    Process.put(:feedback_controller_result, {:ok, %{"status" => "REPLIED", "feedback_key" => key, "reply_id" => "900", "reply_body" => body, "reason" => ""}})

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
  end

  test "integer authenticated identity conflicting with configured bot is quarantined", context do
    key = context.candidate.feedback_key
    body = "Answer\n<!-- symphony-feedback:#{key} -->"
    Process.put(:feedback_whoami, {:ok, %{"id" => 12}})
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 12}})
    Process.put(:feedback_controller_result, {:ok, %{"status" => "REPLIED", "feedback_key" => key, "reply_id" => "900", "reply_body" => body, "reason" => ""}})

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
  end

  test "missing authenticated identity is quarantined", context do
    key = context.candidate.feedback_key
    Process.put(:feedback_whoami, {:ok, %{}})
    Process.put(:feedback_controller_result, {:ok, %{"status" => "REPLIED", "feedback_key" => key, "reply_id" => "900", "reply_body" => "Answer", "reason" => ""}})

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
  end

  test "a source-change request is recorded without a GitLab reply", context do
    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "status" => "CHANGE_REQUEST",
         "feedback_key" => context.candidate.feedback_key,
         "reply_id" => nil,
         "reply_body" => nil,
         "reason" => "Change the threshold"
       }}
    )

    assert {:ok, :change_request} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes")["status"] == "CHANGE_REQUEST"
  end

  test "an ambiguous controller result is quarantined without another send", context do
    Process.put(:feedback_controller_result, {:error, :tool_outcome_unknown})
    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes")["status"] == "RECONCILE_REQUIRED"
    assert {:ok, :idle} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, _, _}
    refute_received {:controller_request, _, _}
  end

  test "a changed controller lineage quarantines the claimed request", context do
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    Control.record_controller_task(context.store, %{scope: "test"}, "controller-thread", "new-turn", %{})
    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes")["status"] == "RECONCILE_REQUIRED"
  end

  test "a completed Desktop turn is adopted after a crash without another send", context do
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, _, _}
    receipt = Store.one!(context.store, "SELECT * FROM mr_feedback_notes")
    body = "The guard protects a stale head.\n<!-- symphony-feedback:#{receipt["feedback_key"]} -->"
    Process.put(:feedback_reply, %{"id" => 900, "body" => body, "author" => %{"id" => 99}})

    output = %{
      "status" => "REPLIED",
      "feedback_key" => receipt["feedback_key"],
      "reply_id" => "900",
      "reply_body" => body,
      "reason" => ""
    }

    Process.put(:completed_feedback_request, %{
      "status" => "SUCCEEDED",
      "target_kind" => "CONTROLLER",
      "target_key" => "test",
      "thread_id" => "controller-thread",
      "turn_id" => "completed-turn",
      "schema_json" => Jason.encode!(StageSchemas.for_stage(:gitlab_feedback_reply)),
      "output_json" => Jason.encode!(%{"result" => output})
    })

    Control.record_controller_task(context.store, %{scope: "test"}, "controller-thread", "completed-turn", %{})

    assert {:ok, :complete} =
             MrFeedbackConsumer.process_one(context.context, Keyword.put(opts(), :desktop_request, FakeDesktopRequest))

    assert Store.one!(context.store, "SELECT status, reply_id FROM mr_feedback_notes") == %{
             "status" => "COMPLETE",
             "reply_id" => 900
           }

    refute_received {:controller_request, _, _}
  end

  test "one MR batch holds the shared controller claim", context do
    {:ok, run} = RunLedger.get(context.store, "delivery-1")
    route = context.context.factory.repositories["grail"]
    jira = %{"key" => "PPL-42", "labels" => ["ai-review"]}
    note = %{context.note | "id" => 52, "body" => "@Symphony a second question"}
    discussion = %{context.discussion | "notes" => [note]}
    {:ok, second} = MrFeedback.candidate(run, route, jira, context.mr, discussion, note, [12], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, second)
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [%{discussion | "notes" => [context.note, note]}]}})

    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())

    assert {:error, :feedback_not_pending} =
             MrFeedbackLedger.claim(context.store, second.feedback_key, "second-request", "prior-turn")
  end

  test "another unresolved controller request defers feedback without claiming or sending", context do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      context.store,
      """
      INSERT INTO desktop_requests (
        request_key, target_kind, target_key, action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, title, prompt, schema_json,
        cwd, metadata_json, created_at, updated_at
      ) VALUES (?, 'CONTROLLER', 'test', 'FOLLOWUP', 'PENDING', ?,
        'projectless', 'gpt-test', 'medium', 'Controller', 'other work', '{}',
        '/tmp/controller', '{}', ?, ?)
      """,
      ["other-controller-request", String.duplicate("a", 64), now, now]
    )

    assert {:ok, :controller_busy} = MrFeedbackConsumer.process_one(context.context, opts())
    assert [%{"status" => "PENDING"}] = MrFeedbackLedger.pending(context.store) |> Enum.map(&Map.take(&1, ["status"]))
    refute_received {:controller_request, _, _}
  end

  test "an answer for another receipt or a blocked decision is quarantined", context do
    Process.put(:feedback_controller_result, {:ok, %{"status" => "REPLIED", "feedback_key" => "other"}})
    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())

    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'PENDING', request_key = NULL")

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "status" => "BLOCK",
         "feedback_key" => context.candidate.feedback_key,
         "reply_id" => nil,
         "reply_body" => nil,
         "reason" => "Insufficient evidence"
       }}
    )

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
  end

  test "a fabricated or missing reply fails exact-thread readback", context do
    key = context.candidate.feedback_key
    body = "Answer\n<!-- symphony-feedback:#{key} -->"

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "status" => "REPLIED",
         "feedback_key" => key,
         "reply_id" => "900",
         "reply_body" => body,
         "reason" => ""
       }}
    )

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'PENDING', request_key = NULL")
    Process.put(:feedback_reply, %{"id" => 900, "body" => "Different\n<!-- symphony-feedback:#{key} -->"})
    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
  end

  test "missing route and unknown claim fail closed", context do
    factory = %{context.context.factory | repositories: %{}}

    assert {:error, :review_feedback_route_missing} =
             MrFeedbackConsumer.process_one(%{context.context | factory: factory}, opts())

    assert {:error, :unknown_feedback} = MrFeedbackLedger.claim(context.store, "missing", "request", "prior-turn")
  end

  test "a completed batched controller request is reconciled without resending", context do
    {second, _discussion} = add_second_note(context, "@Symphony please simplify this")
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, _, _}
    [request_key] = Store.query!(context.store, "SELECT DISTINCT request_key FROM mr_feedback_notes").rows |> hd()

    results =
      [context.candidate.feedback_key, second.feedback_key]
      |> Enum.map(fn key -> %{"status" => "CHANGE_REQUEST", "feedback_key" => key, "reply_id" => nil, "reply_body" => nil, "reason" => "Explicit edit"} end)

    Process.put(:completed_feedback_request, %{
      "status" => "SUCCEEDED",
      "target_kind" => "CONTROLLER",
      "target_key" => "test",
      "thread_id" => "controller-thread",
      "turn_id" => "completed-batch-turn",
      "schema_json" => Jason.encode!(StageSchemas.for_stage(:gitlab_feedback_batch)),
      "output_json" => Jason.encode!(%{"result" => %{"results" => results}})
    })

    Control.record_controller_task(context.store, %{scope: "test"}, "controller-thread", "completed-batch-turn", %{})

    assert {:ok, :batch_complete} =
             MrFeedbackConsumer.process_one(context.context, Keyword.put(opts(), :desktop_request, FakeDesktopRequest))

    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["CHANGE_REQUEST"]]
    assert [request_key] == Store.query!(context.store, "SELECT DISTINCT request_key FROM mr_feedback_notes").rows |> hd()
    refute_received {:controller_request, _, _}
  end

  test "an unproven completed batch is quarantined without a second send", context do
    {_second, _discussion} = add_second_note(context, "@Symphony another question")
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, _, _}

    Process.put(:completed_feedback_request, %{"status" => "FAILED"})
    Control.record_controller_task(context.store, %{scope: "test"}, "controller-thread", "unproven-turn", %{})

    assert {:ok, :reconcile_required} =
             MrFeedbackConsumer.process_one(context.context, Keyword.put(opts(), :desktop_request, FakeDesktopRequest))

    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["RECONCILE_REQUIRED"]]
    refute_received {:controller_request, _, _}
  end

  test "a changed second note is dismissed before the batch can be sent", context do
    {second, discussion} = add_second_note(context, "@Symphony another question")
    changed = %{hd(discussion["notes"]) | "body" => "@Symphony edited", "updated_at" => "2026-09-30T10:02:00Z"}
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [context.discussion, %{discussion | "notes" => [changed]}]}})

    assert {:ok, :dismissed} = MrFeedbackConsumer.process_one(context.context, opts())

    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = ?", [second.feedback_key])["status"] ==
             "SUPERSEDED"
  end

  test "a changed claimed batch stays claimed for reconciliation", context do
    {_second, discussion} = add_second_note(context, "@Symphony another question")
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    changed = %{hd(discussion["notes"]) | "body" => "@Symphony edited"}
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [context.discussion, %{discussion | "notes" => [changed]}]}})

    assert {:error, :feedback_source_changed} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["CLAIMED"]]
  end

  test "a claimed batch rejects changed binding and changed mode", context do
    {_second, _discussion} = add_second_note(context, "@Symphony another question")
    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())

    Store.query!(context.store, "UPDATE mr_feedback_notes SET mr_iid = 456 WHERE note_id = 52")
    assert {:error, :feedback_batch_changed} = MrFeedbackConsumer.process_one(context.context, opts())

    Store.query!(context.store, "UPDATE mr_feedback_notes SET mr_iid = 123, reply_phase = 2")
    assert {:error, :feedback_request_binding_changed} = MrFeedbackConsumer.process_one(context.context, opts())
  end

  test "batched controller errors and malformed results quarantine the receipt", context do
    {_second, _discussion} = add_second_note(context, "@Symphony another question")
    Process.put(:feedback_controller_result, {:error, :connector_offline})
    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["RECONCILE_REQUIRED"]]
  end

  test "batch source and result-shape failures do not produce a second request", context do
    {_second, _discussion} = add_second_note(context, "@Symphony another question")
    Process.put(:feedback_jira_result, {:error, :jira_offline})
    assert {:error, :jira_offline} = MrFeedbackConsumer.process_one(context.context, opts())

    Process.put(:feedback_jira_result, {:ok, %{"key" => "PPL-42", "labels" => ["ai-review"]}})
    Process.put(:feedback_controller_result, {:ok, %{"unexpected" => true}})
    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["RECONCILE_REQUIRED"]]
  end

  test "batch reply requires exact-thread author and body readback", context do
    {second, _discussion} = add_second_note(context, "@Symphony please simplify this")
    body = "Answer\n<!-- symphony-feedback:#{context.candidate.feedback_key} -->"

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "results" => [
           %{"status" => "REPLIED", "feedback_key" => context.candidate.feedback_key, "reply_id" => "900", "reply_body" => body, "reason" => ""},
           %{"status" => "CHANGE_REQUEST", "feedback_key" => second.feedback_key, "reply_id" => nil, "reply_body" => nil, "reason" => "Edit"}
         ]
       }}
    )

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["RECONCILE_REQUIRED"]]
  end

  test "batch reply from a different author cannot prove completion", context do
    {second, _discussion} = add_second_note(context, "@Symphony please simplify this")
    body = "Answer\n<!-- symphony-feedback:#{context.candidate.feedback_key} -->"
    Process.put(:feedback_reply, %{"id" => 900, "discussion_id" => "discussion-1", "body" => body, "author" => %{"id" => 12}})

    Process.put(
      :feedback_controller_result,
      {:ok,
       %{
         "results" => [
           %{"status" => "REPLIED", "feedback_key" => context.candidate.feedback_key, "reply_id" => "900", "reply_body" => body, "reason" => ""},
           %{"status" => "CHANGE_REQUEST", "feedback_key" => second.feedback_key, "reply_id" => nil, "reply_body" => nil, "reason" => "Edit"}
         ]
       }}
    )

    assert {:ok, :reconcile_required} = MrFeedbackConsumer.process_one(context.context, opts())
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["RECONCILE_REQUIRED"]]
  end

  test "clarification batch must answer in the original threads", context do
    {_second, _discussion} = add_second_note(context, "@Symphony another observation")
    Store.query!(context.store, "UPDATE mr_feedback_notes SET reply_phase = 2")

    assert {:ok, :pending} = MrFeedbackConsumer.process_one(context.context, opts())
    assert_received {:controller_request, prompt, _opts}
    assert prompt =~ "previously misclassified as edit requests"
  end

  test "batch ledger rejects a finish without an exact claim", context do
    {_second, _discussion} = add_second_note(context, "@Symphony another question")

    receipts =
      Store.query!(context.store, "SELECT * FROM mr_feedback_notes ORDER BY note_id")
      |> then(fn result -> Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1))) end)

    decisions =
      Enum.map(receipts, fn receipt ->
        %{"status" => "CHANGE_REQUEST", "feedback_key" => receipt["feedback_key"], "reason" => "Edit"}
      end)

    assert {:error, :feedback_batch_claim_mismatch} =
             MrFeedbackLedger.finish_batch(context.store, receipts, "unclaimed", decisions, %{})
  end

  defp add_second_note(context, body) do
    note = %{context.note | "id" => 52, "body" => body}
    discussion = %{"id" => "discussion-2", "notes" => [note]}
    {:ok, run} = RunLedger.get(context.store, "delivery-1")

    {:ok, candidate} =
      MrFeedback.candidate(
        run,
        context.context.factory.repositories["grail"],
        %{"key" => "PPL-42", "labels" => ["ai-review"]},
        context.mr,
        discussion,
        note,
        [12],
        99
      )

    {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, candidate)
    Process.put(:feedback_gitlab_result, {:ok, %{mr: context.mr, discussions: [context.discussion, discussion]}})
    {candidate, discussion}
  end

  defp opts do
    [
      workspace: "/tmp/factory-controller",
      jira_reader: FakeJiraReader,
      gitlab_reader: FakeGitLabReader,
      gitlab_connector: FakeGitLabConnector,
      controller_task: FakeControllerTask
    ]
  end
end
