defmodule SymphonyElixir.FactoryMrFeedbackReworkTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{
    Control,
    DesktopRequest,
    MrFeedback,
    MrFeedbackLedger,
    MrFeedbackRework,
    RunLedger,
    Store,
    TaskLedger
  }

  setup do
    {:ok, store} = Store.start_link(database: ":memory:")
    sha = String.duplicate("a", 40)
    route = %{"repo_key" => "grail", "gitlab_project" => "grailbio/grail"}

    attrs = %{
      run_id: "delivery-1",
      issue_key: "PPL-42",
      kind: "DELIVERY",
      state: "READY_FOR_REVIEW",
      repo_key: "grail",
      repo_path: "/tmp/grail",
      base_branch: "master",
      branch: "factory/PPL-42",
      worktree: "/tmp/review-writer",
      candidate_sha: sha,
      mr_iid: 123,
      mr_url: "https://gitlab.example/grail/-/merge_requests/123",
      factory_owned: false,
      implementation_iteration: 4
    }

    {:ok, %{run: run}} = RunLedger.register(store, attrs)

    {:ok, _task} =
      TaskLedger.register(store, %{
        task_key: "delivery-1:feature-writer",
        run_id: run["run_id"],
        stage: "WRITING",
        role: "feature-writer",
        status: "COMPLETE",
        model_provider: "codex",
        model_class: "test",
        model: "gpt-test",
        reasoning_effort: "medium",
        routing_reason: "test",
        codex_project_id: "project-grail",
        thread_id: "writer-thread",
        turn_id: "writer-turn",
        workspace: run["worktree"],
        workspace_sha: sha,
        prompt_sha256: String.duplicate("b", 64)
      })

    jira = %{"key" => run["issue_key"], "labels" => ["ai-review"]}

    mr = %{
      "project" => route["gitlab_project"],
      "iid" => 123,
      "web_url" => run["mr_url"],
      "source_branch" => run["branch"],
      "sha" => sha,
      "state" => "opened"
    }

    notes = [
      %{"id" => 51, "body" => "@Symphony please simplify the switch", "updated_at" => "2026-09-30T10:00:00Z", "author" => %{"id" => 12}},
      %{"id" => 52, "body" => "@Symphony please remove the redundant fallback", "updated_at" => "2026-09-30T10:01:00Z", "author" => %{"id" => 12}}
    ]

    discussions = Enum.map(notes, fn note -> %{"id" => "discussion-#{note["id"]}", "notes" => [note]} end)

    receipts =
      Enum.zip(discussions, notes)
      |> Enum.map(fn {discussion, note} ->
        {:ok, candidate} = MrFeedback.candidate(run, route, jira, mr, discussion, note, [12], 99)
        {:ok, :recorded} = MrFeedbackLedger.record_candidate(store, candidate)
        Store.query!(store, "UPDATE mr_feedback_notes SET status = 'CHANGE_REQUEST' WHERE feedback_key = ?", [candidate.feedback_key])
        Store.one!(store, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [candidate.feedback_key])
      end)

    %{store: store, run: run, route: route, jira: jira, mr: mr, discussions: discussions, receipts: receipts, sha: sha}
  end

  test "one review batch resumes the existing writer without restarting delivery", context do
    sha = context.sha

    assert {:ok, batch_key} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    assert is_binary(batch_key)

    assert %{"state" => "REVIEW_WRITING", "review_base_sha" => ^sha, "implementation_iteration" => 4} =
             Store.one!(context.store, "SELECT state, review_base_sha, implementation_iteration FROM runs WHERE run_id = 'delivery-1'")

    assert %{"status" => "RETRY_PENDING", "thread_id" => "writer-thread", "output_json" => nil} =
             Store.one!(context.store, "SELECT status, thread_id, output_json FROM factory_tasks WHERE task_key = 'delivery-1:feature-writer'")

    assert [["REWORKING", ^batch_key], ["REWORKING", ^batch_key]] =
             Store.query!(context.store, "SELECT status, review_batch_key FROM mr_feedback_notes ORDER BY note_id").rows

    assert [["REVIEW_WRITING"]] =
             Store.query!(context.store, "SELECT json_extract(payload_json, '$.state') FROM events WHERE event_type = 'RUN_UPDATED' ORDER BY id DESC LIMIT 1").rows
  end

  test "stale MR head rejects the whole batch without changing state", context do
    changed_mr = %{context.mr | "sha" => String.duplicate("c", 40)}

    assert {:error, :mr_head_mismatch} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, changed_mr))

    assert Store.one!(context.store, "SELECT state FROM runs WHERE run_id = 'delivery-1'")["state"] == "READY_FOR_REVIEW"
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["CHANGE_REQUEST"]]
  end

  test "verified push requeues one resolution batch without another classification", context do
    assert {:ok, batch_key} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    candidate = String.duplicate("c", 40)
    Store.query!(context.store, "UPDATE runs SET state = 'REVIEW_PUSHING', candidate_sha = ? WHERE run_id = 'delivery-1'", [candidate])

    assert :ok = MrFeedbackRework.complete_push(context.store, "delivery-1", batch_key, candidate)
    assert Store.one!(context.store, "SELECT state FROM runs WHERE run_id = 'delivery-1'")["state"] == "READY_FOR_REVIEW"

    assert [["PENDING", 1], ["PENDING", 1]] =
             Store.query!(context.store, "SELECT status, reply_phase FROM mr_feedback_notes ORDER BY note_id").rows

    assert [["READY_FOR_REVIEW"]] =
             Store.query!(context.store, "SELECT json_extract(payload_json, '$.state') FROM events WHERE event_type = 'RUN_UPDATED' ORDER BY id DESC LIMIT 1").rows
  end

  test "cleanup reservation prevents review admission without consuming feedback", context do
    Store.query!(context.store, """
    INSERT INTO native_workspace_maintenance(run_id,phase,binding_json,binding_sha256,checked_at,updated_at)
    VALUES ('delivery-1','PROBING','{}','binding','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')
    """)

    assert {:error, :native_workspace_maintenance_reserved} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    assert Store.one!(context.store, "SELECT state FROM runs WHERE run_id = 'delivery-1'")["state"] == "READY_FOR_REVIEW"
    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["CHANGE_REQUEST"]]
  end

  test "a changed review source quarantines the batch and preserves its candidate", context do
    assert {:ok, batch_key} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    candidate = String.duplicate("c", 40)
    Store.query!(context.store, "UPDATE runs SET state = 'REVIEW_PUSHING', candidate_sha = ? WHERE run_id = 'delivery-1'", [candidate])

    assert :ok = MrFeedbackRework.quarantine(context.store, "delivery-1", batch_key, :review_source_changed)

    assert %{"state" => "FAILED", "candidate_sha" => ^candidate} =
             Store.one!(context.store, "SELECT state, candidate_sha FROM runs WHERE run_id = 'delivery-1'")

    assert Store.query!(context.store, "SELECT DISTINCT status FROM mr_feedback_notes").rows == [["RECONCILE_REQUIRED"]]

    assert [["FAILED"]] =
             Store.query!(context.store, "SELECT json_extract(payload_json, '$.state') FROM events WHERE event_type = 'RUN_UPDATED' ORDER BY id DESC LIMIT 1").rows

    assert {:error, :review_run_changed} =
             MrFeedbackRework.quarantine(context.store, "delivery-1", batch_key, :review_source_changed)
  end

  test "a previously misclassified observation returns to conversation", context do
    [first | _] = context.receipts
    discussion = %{"id" => first["discussion_id"], "notes" => [%{"id" => first["note_id"], "body" => "@Symphony this switch seems odd"}]}

    assert %{"feedback_key" => key} = MrFeedbackRework.ambiguous_receipt([first], [discussion])
    assert :ok = MrFeedbackLedger.requeue_clarification(context.store, key)

    assert %{"status" => "PENDING", "reply_phase" => 2} =
             Store.one!(context.store, "SELECT status, reply_phase FROM mr_feedback_notes WHERE feedback_key = ?", [key])
  end

  test "source-note readback detects an edited note and invalid batch data", context do
    assert {:ok, _batch_key} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    {:ok, run} = RunLedger.get(context.store, "delivery-1")
    assert MrFeedbackRework.source_notes_match?(run, context.discussions)

    [first | rest] = context.discussions
    [note] = first["notes"]
    changed = %{first | "notes" => [%{note | "body" => "@Symphony changed"}]}
    refute MrFeedbackRework.source_notes_match?(run, [changed | rest])
    changed_time = %{first | "notes" => [%{note | "updated_at" => "2026-09-30T10:03:00Z"}]}
    refute MrFeedbackRework.source_notes_match?(run, [changed_time | rest])
    refute MrFeedbackRework.source_notes_match?(%{run | "review_feedback_json" => "invalid"}, context.discussions)
  end

  test "source changes and missing writer binding fail before admission", context do
    [first | rest] = context.discussions
    [note] = first["notes"]
    changed = %{first | "notes" => [%{note | "body" => "@Symphony changed"}]}

    assert {:error, :feedback_source_changed} =
             MrFeedbackRework.admit(
               context.store,
               context.run,
               context.receipts,
               %{evidence(context, context.mr) | discussions: [changed | rest]}
             )

    Store.query!(context.store, "UPDATE factory_tasks SET workspace_sha = ? WHERE task_key = 'delivery-1:feature-writer'", [String.duplicate("c", 40)])

    assert {:error, :review_writer_unavailable} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    Store.query!(context.store, "UPDATE factory_tasks SET status = 'FAILED' WHERE task_key = 'delivery-1:feature-writer'")

    assert {:error, :review_writer_unavailable} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))
  end

  test "changed run or feedback receipt cannot enter review rework", context do
    Store.query!(context.store, "UPDATE runs SET state = 'FAILED' WHERE run_id = 'delivery-1'")

    assert {:error, :review_run_changed} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))

    Store.query!(context.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'delivery-1'")
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'COMPLETE' WHERE note_id = 52")

    assert {:error, :feedback_batch_changed} =
             MrFeedbackRework.admit(context.store, context.run, context.receipts, evidence(context, context.mr))
  end

  test "ambiguous criticism cannot be admitted as a source edit", context do
    note = %{"id" => 53, "body" => "@Symphony this switch seems odd", "updated_at" => "2026-09-30T10:02:00Z", "author" => %{"id" => 12}}
    discussion = %{"id" => "discussion-53", "notes" => [note]}
    {:ok, candidate} = MrFeedback.candidate(context.run, context.route, context.jira, context.mr, discussion, note, [12], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, candidate)
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'CHANGE_REQUEST' WHERE feedback_key = ?", [candidate.feedback_key])
    receipt = Store.one!(context.store, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [candidate.feedback_key])

    assert {:error, :feedback_needs_clarification} =
             MrFeedbackRework.admit(
               context.store,
               context.run,
               [receipt],
               %{evidence(context, context.mr) | discussions: [discussion]}
             )
  end

  test "pending batches exclude unbound notes and controller requests from another scope", context do
    assert MrFeedbackRework.pending_batch(context.store, "owner") == []
    [first, second] = context.receipts
    bind_request(context.store, first, "owner", "SUCCEEDED")
    bind_request(context.store, second, "other", "SUCCEEDED")

    assert [%{"feedback_key" => key}] = MrFeedbackRework.pending_batch(context.store, "owner")
    assert key == first["feedback_key"]
    assert [%{"feedback_key" => other}] = MrFeedbackRework.pending_batch(context.store, "other")
    assert other == second["feedback_key"]
  end

  test "approval of a prior concrete proposal resumes the writer but bare approval does not", context do
    offer = %{"id" => 60, "body" => "Symphony: Should I simplify the switch? <!-- symphony-feedback:proposal -->"}
    approval = %{"id" => 61, "body" => "@Symphony go ahead", "updated_at" => "2026-09-30T10:03:00Z", "author" => %{"id" => 12}}
    discussion = %{"id" => "discussion-61", "notes" => [offer, approval]}
    {:ok, candidate} = MrFeedback.candidate(context.run, context.route, context.jira, context.mr, discussion, approval, [12], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, candidate)
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'CHANGE_REQUEST' WHERE feedback_key = ?", [candidate.feedback_key])
    receipt = Store.one!(context.store, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [candidate.feedback_key])
    proof = %{evidence(context, context.mr) | discussions: [%{discussion | "notes" => [approval]}]}
    assert {:error, :feedback_needs_clarification} = MrFeedbackRework.admit(context.store, context.run, [receipt], proof)
    assert {:ok, _batch} = MrFeedbackRework.admit(context.store, context.run, [receipt], %{proof | discussions: [discussion]})
    assert Store.one!(context.store, "SELECT state FROM runs WHERE run_id = 'delivery-1'")["state"] == "REVIEW_WRITING"
  end

  test "replayed controller replies are read back and retired in the admission transaction", context do
    receipt = replayed_receipt(context)
    reply = %{"id" => 900, "body" => "Symphony: Would you like me to simplify it? <!-- symphony-feedback:#{receipt["feedback_key"]} -->"}
    [discussion | _] = context.discussions
    discussions = [Map.update!(discussion, "notes", &(&1 ++ [reply]))]
    proof = evidence(context, context.mr) |> Map.put(:controller_scope, "owner") |> Map.put(:discussions, discussions)

    assert [%{"feedback_key" => key}] = MrFeedbackRework.pending_batch(context.store, "owner")
    assert key == receipt["feedback_key"]
    assert {:ok, batch_key} = MrFeedbackRework.admit(context.store, context.run, [receipt], proof)

    assert %{"status" => "FAILED", "failure_code" => "FOLLOWUP_REPLY_READ_BACK_BEFORE_REWORK"} =
             Store.one!(context.store, "SELECT status, failure_code FROM desktop_requests WHERE request_key = ?", [receipt["request_key"]])

    assert %{"status" => "REWORKING", "review_batch_key" => ^batch_key, "request_key" => request_key} =
             Store.one!(context.store, "SELECT status, review_batch_key, request_key FROM mr_feedback_notes WHERE feedback_key = ?", [key])

    assert request_key == receipt["request_key"]
    assert MrFeedbackRework.pending_batch(context.store, "owner") == []
  end

  test "replayed reply admission fails closed on missing duplicate or unmarked reply readback", context do
    receipt = replayed_receipt(context)
    [discussion | _] = context.discussions
    marker = "<!-- symphony-feedback:#{receipt["feedback_key"]} -->"
    reply = %{"id" => 900, "body" => "Symphony: Proposed edit #{marker}"}

    for replies <- [[], [Map.put(reply, "body", "Untrusted #{marker}")], [reply, Map.put(reply, "id", 901)]] do
      proof =
        evidence(context, context.mr)
        |> Map.put(:controller_scope, "owner")
        |> Map.put(:discussions, [Map.update!(discussion, "notes", &(&1 ++ replies))])

      assert {:error, :replayed_controller_reply_not_read_back} =
               MrFeedbackRework.admit(context.store, context.run, [receipt], proof)
    end

    assert Store.one!(context.store, "SELECT state FROM runs WHERE run_id = 'delivery-1'")["state"] == "READY_FOR_REVIEW"
    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} = DesktopRequest.get(context.store, receipt["request_key"])
  end

  test "replayed request provenance must still match its scope and failure", context do
    receipt = replayed_receipt(context)
    [discussion | _] = context.discussions
    reply = %{"id" => 900, "body" => "Symphony: Proposed edit <!-- symphony-feedback:#{receipt["feedback_key"]} -->"}
    proof = evidence(context, context.mr) |> Map.put(:controller_scope, "other") |> Map.put(:discussions, [Map.update!(discussion, "notes", &(&1 ++ [reply]))])
    assert {:error, :feedback_batch_changed} = MrFeedbackRework.admit(context.store, context.run, [receipt], proof)
    assert MrFeedbackRework.pending_batch(context.store, "other") == []

    Store.query!(context.store, "UPDATE desktop_requests SET failure_code = 'OTHER_FAILURE' WHERE request_key = ?", [receipt["request_key"]])
    assert MrFeedbackRework.pending_batch(context.store, "owner") == []
    assert {:error, :feedback_batch_changed} = MrFeedbackRework.admit(context.store, context.run, [receipt], Map.put(proof, :controller_scope, "owner"))
  end

  test "admission cannot use a receipt whose classification changed after readback", context do
    [first | _] = context.receipts
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'RECONCILE_REQUIRED', reply_phase = 2, last_error = 'FOLLOWUP_TURN_REPLAYED' WHERE feedback_key = ?", [first["feedback_key"]])
    assert {:error, :feedback_batch_changed} = MrFeedbackRework.admit(context.store, context.run, [first], evidence(context, context.mr))
  end

  test "a duplicate receipt rolls back every admission mutation", context do
    [first | _] = context.receipts

    assert {:error, :feedback_batch_changed} =
             MrFeedbackRework.admit(context.store, context.run, [first, first], evidence(context, context.mr))

    assert Store.one!(context.store, "SELECT state, review_feedback_json FROM runs WHERE run_id = 'delivery-1'") ==
             %{"state" => "READY_FOR_REVIEW", "review_feedback_json" => nil}

    assert Store.query!(context.store, "SELECT DISTINCT status, review_batch_key FROM mr_feedback_notes").rows == [["CHANGE_REQUEST", nil]]
    assert Store.one!(context.store, "SELECT status FROM factory_tasks WHERE task_key = 'delivery-1:feature-writer'")["status"] == "COMPLETE"
  end

  test "a replayed receipt cannot admit after its persisted classification changes", context do
    receipt = replayed_receipt(context)
    [discussion | _] = context.discussions
    reply = %{"id" => 900, "body" => "Symphony: Proposed edit <!-- symphony-feedback:#{receipt["feedback_key"]} -->"}
    proof = evidence(context, context.mr) |> Map.put(:controller_scope, "owner") |> Map.put(:discussions, [Map.update!(discussion, "notes", &(&1 ++ [reply]))])
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'CHANGE_REQUEST' WHERE feedback_key = ?", [receipt["feedback_key"]])

    assert {:error, :feedback_batch_changed} =
             MrFeedbackRework.admit(context.store, context.run, [receipt], proof)

    assert Store.one!(context.store, "SELECT state, review_feedback_json FROM runs WHERE run_id = 'delivery-1'") ==
             %{"state" => "READY_FOR_REVIEW", "review_feedback_json" => nil}

    assert Store.one!(context.store, "SELECT status, review_batch_key FROM mr_feedback_notes WHERE feedback_key = ?", [receipt["feedback_key"]]) ==
             %{"status" => "CHANGE_REQUEST", "review_batch_key" => nil}

    assert Store.one!(context.store, "SELECT status FROM factory_tasks WHERE task_key = 'delivery-1:feature-writer'")["status"] == "COMPLETE"

    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "failure_code" => "FOLLOWUP_TURN_REPLAYED"}} =
             DesktopRequest.get(context.store, receipt["request_key"])
  end

  test "a refused request retirement rolls back the whole replayed admission", context do
    receipt = replayed_receipt(context)
    [discussion | _] = context.discussions
    reply = %{"id" => 900, "body" => "Symphony: Proposed edit <!-- symphony-feedback:#{receipt["feedback_key"]} -->"}
    proof = evidence(context, context.mr) |> Map.put(:controller_scope, "owner") |> Map.put(:discussions, [Map.update!(discussion, "notes", &(&1 ++ [reply]))])

    Store.query!(context.store, """
    CREATE TEMP TRIGGER refuse_feedback_retirement
    BEFORE UPDATE OF status ON desktop_requests
    WHEN NEW.failure_code = 'FOLLOWUP_REPLY_READ_BACK_BEFORE_REWORK'
    BEGIN SELECT RAISE(IGNORE); END
    """)

    assert {:error, :replayed_controller_request_changed} =
             MrFeedbackRework.admit(context.store, context.run, [receipt], proof)

    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "failure_code" => "FOLLOWUP_TURN_REPLAYED"}} =
             DesktopRequest.get(context.store, receipt["request_key"])

    assert Store.one!(context.store, "SELECT state, review_feedback_json FROM runs WHERE run_id = 'delivery-1'") ==
             %{"state" => "READY_FOR_REVIEW", "review_feedback_json" => nil}

    assert Store.one!(context.store, "SELECT status, review_batch_key FROM mr_feedback_notes WHERE feedback_key = ?", [receipt["feedback_key"]]) ==
             %{"status" => "RECONCILE_REQUIRED", "review_batch_key" => nil}

    assert Store.one!(context.store, "SELECT status FROM factory_tasks WHERE task_key = 'delivery-1:feature-writer'")["status"] == "COMPLETE"
  end

  defp replayed_receipt(context) do
    [first | _] = context.receipts
    request_key = bind_request(context.store, first, "owner", "RECONCILE_REQUIRED")
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'RECONCILE_REQUIRED', reply_phase = 2, last_error = 'FOLLOWUP_TURN_REPLAYED' WHERE feedback_key = ?", [first["feedback_key"]])
    Store.query!(context.store, "UPDATE desktop_requests SET failure_code = 'FOLLOWUP_TURN_REPLAYED' WHERE request_key = ?", [request_key])
    Store.one!(context.store, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [first["feedback_key"]])
  end

  defp bind_request(store, receipt, scope, status) do
    key = "feedback:#{receipt["feedback_key"]}"
    Control.initialize(store, %{scope: scope, dispatcher_id: "dispatcher"})
    Control.record_controller_task(store, %{scope: scope}, "controller-thread", "prior-turn", %{})

    assert {:ok, _request} =
             DesktopRequest.enqueue(store, %{
               request_key: key,
               target_kind: "CONTROLLER",
               target_key: scope,
               action: "FOLLOWUP",
               existing_thread_id: "controller-thread",
               codex_project_id: "projectless",
               model: "gpt-test",
               reasoning_effort: "medium",
               title: "Review feedback",
               prompt: "Classify review feedback",
               cwd: "/tmp/factory-controller"
             })

    Store.query!(store, "UPDATE desktop_requests SET status = ? WHERE request_key = ?", [status, key])
    Store.query!(store, "UPDATE mr_feedback_notes SET request_key = ? WHERE feedback_key = ?", [key, receipt["feedback_key"]])
    key
  end

  defp evidence(context, mr) do
    %{
      route: context.route,
      jira: context.jira,
      mr: mr,
      discussions: context.discussions,
      verified_writer_sha: context.sha,
      allowed_authors: [12],
      bot_id: 99
    }
  end
end
