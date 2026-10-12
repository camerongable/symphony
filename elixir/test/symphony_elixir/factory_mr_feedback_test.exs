defmodule SymphonyElixir.FactoryMrFeedbackTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{MrFeedback, MrFeedbackLedger, RunLedger, Store}

  test "an observation about code is not an explicit edit request" do
    refute MrFeedback.explicit_edit_request?("@Symphony this case statement doesn't make sense when it defaults. The whole switch seems odd when there's nothing conditional about it.")

    assert MrFeedback.explicit_edit_request?("@symphony please simplify the switch")
  end

  test "contextual approval requires an earlier marked concrete edit offer" do
    offer = %{"id" => 50, "body" => "Symphony: Would you like me to simplify the switch? <!-- symphony-feedback:offer -->"}
    approval = %{"id" => 51, "body" => "@Symphony go ahead"}

    assert MrFeedback.approves_proposed_edit?(approval["body"], [offer, approval], 51)
    assert MrFeedback.approves_proposed_edit?("@Symphony yes", [Map.put(offer, "body", "Symphony: Would an explicit allowlist be clearer? <!-- symphony-feedback:offer -->"), approval], 51)
    refute MrFeedback.approves_proposed_edit?(approval["body"], [approval, offer], 51)
    refute MrFeedback.approves_proposed_edit?(approval["body"], [Map.put(offer, "body", "Would you like me to simplify the switch?"), approval], 51)
    refute MrFeedback.approves_proposed_edit?(approval["body"], [%{"id" => 50}, approval], 51)
    refute MrFeedback.approves_proposed_edit?("@Symphony that seems odd", [offer, approval], 51)
    refute MrFeedback.explicit_edit_request?(approval["body"])
    assert MrFeedback.explicit_edit_request?("@Symphony please make the suggested change")
  end

  setup do
    {:ok, store} = Store.start_link(database: ":memory:")

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

    %{
      store: store,
      run: run,
      route: %{"repo_key" => "grail", "gitlab_project" => "grailbio/grail"},
      jira: %{"key" => "PPL-42", "labels" => ["repo-grail", "ai-review"]},
      mr: %{
        "project" => "grailbio/grail",
        "iid" => 123,
        "web_url" => run["mr_url"],
        "state" => "opened",
        "source_branch" => run["branch"],
        "sha" => run["candidate_sha"]
      },
      discussion: %{"id" => "discussion-1"},
      note: %{
        "id" => 51,
        "updated_at" => "2026-09-30T10:00:00Z",
        "author" => %{"id" => 12},
        "body" => "@Symphony please explain this tradeoff"
      }
    }
  end

  test "accepts only the exact review-ready Jira and MR identities", context do
    assert {:ok, candidate} = candidate(context)
    assert candidate.run_id == context.run["run_id"]
    assert candidate.discussion_id == "discussion-1"

    for {change, expected} <- [
          {{:run, "state", "WRITING"}, :delivery_not_review_ready},
          {{:jira, "labels", ["ai-running"]}, :jira_review_label_missing},
          {{:mr, "sha", String.duplicate("b", 40)}, :mr_head_mismatch},
          {{:mr, "project", "other/project"}, :mr_identity_mismatch},
          {{:mr, "web_url", "https://other/mr"}, :mr_identity_mismatch}
        ] do
      {source, field, value} = change
      assert {:error, ^expected} = candidate(Map.update!(context, source, &Map.put(&1, field, value)))
    end
  end

  test "ignores bot, unauthorized, system, quoted, and code-only mentions", context do
    assert {:error, :unauthorized_author} = candidate(%{context | note: put_in(context.note["author"]["id"], 99)})
    assert {:error, :unauthorized_author} = candidate(context, [12], 12)
    assert {:error, :non_actionable_note} = candidate(%{context | note: Map.put(context.note, "system", true)})
    assert {:error, :mention_missing} = candidate(%{context | note: Map.put(context.note, "body", "> @Symphony old text")})

    assert {:error, :mention_missing} =
             candidate(%{context | note: Map.put(context.note, "body", "```\n@Symphony quoted code\n```")})

    assert {:error, :mention_missing} =
             candidate(%{context | note: Map.put(context.note, "body", "The literal `@Symphony` is only an example")})

    assert {:error, :mention_missing} = candidate(%{context | note: Map.put(context.note, "body", "email@symphony.com")})
  end

  test "records one receipt per note body and keeps edited versions", context do
    assert {:error, :unknown_feedback} = MrFeedbackLedger.requeue_clarification(context.store, "missing-feedback")
    assert Store.query!(context.store, "SELECT * FROM mr_feedback_notes").rows == []
    assert {:ok, first} = candidate(context)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, first)
    assert {:ok, :already_recorded} = MrFeedbackLedger.record_candidate(context.store, first)
    assert [%{"feedback_key" => first_key, "status" => "PENDING"}] = MrFeedbackLedger.pending(context.store)
    assert first_key == first.feedback_key
    before_requeue = Store.query!(context.store, "SELECT * FROM mr_feedback_notes").rows
    assert {:error, :feedback_not_change_request} = MrFeedbackLedger.requeue_clarification(context.store, first_key)
    assert Store.query!(context.store, "SELECT * FROM mr_feedback_notes").rows == before_requeue

    edited_note = %{context.note | "updated_at" => "2026-09-30T10:01:00Z", "body" => "@Symphony please change this"}
    assert {:ok, edited} = candidate(%{context | note: edited_note})
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, edited)
    assert [%{"feedback_key" => edited_key}] = MrFeedbackLedger.pending(context.store)
    assert edited_key == edited.feedback_key

    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = ?", [first.feedback_key])["status"] ==
             "SUPERSEDED"

    assert Store.one!(context.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'MR_FEEDBACK_DISCOVERED'")["count"] == 2

    assert {:ok, claimed} = MrFeedbackLedger.claim(context.store, edited.feedback_key, "owned-request", nil)
    assert {:error, :feedback_claim_mismatch} = MrFeedbackLedger.finish(context.store, edited.feedback_key, "different-request", "COMPLETE")
    assert Store.one!(context.store, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [edited.feedback_key]) == claimed
    assert :ok = MrFeedbackLedger.finish(context.store, edited.feedback_key, "owned-request", "COMPLETE")
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = ?", [edited.feedback_key])["status"] == "COMPLETE"
  end

  test "quarantines V1 feedback from selectors and direct ledger mutations", context do
    v1_run = Map.put(context.run, "run_id", "supervisor-v1") |> Map.put("execution_mode", "TICKET_SUPERVISOR_V1")
    assert {:ok, _} = RunLedger.register(context.store, v1_run)
    assert {:ok, base_candidate} = candidate(context)
    candidate = Map.put(base_candidate, :run_id, "supervisor-v1")

    assert {:error, :feedback_run_quarantined} = MrFeedbackLedger.record_candidate(context.store, candidate)

    Store.query!(context.store, """
    INSERT INTO mr_feedback_notes (feedback_key, run_id, project, mr_iid, discussion_id, note_id,
      note_updated_at, author_id, body_sha256, status, created_at, updated_at)
    VALUES ('v1-receipt', 'supervisor-v1', 'grailbio/grail', 123, 'discussion-1', 51,
      '2026-09-30T10:00:00Z', 12, '#{String.duplicate("a", 64)}', 'PENDING',
      '2026-09-30T10:00:00Z', '2026-09-30T10:00:00Z')
    """)

    assert MrFeedbackLedger.pending(context.store) == []
    assert MrFeedbackLedger.next(context.store) == nil
    assert {:error, :feedback_run_quarantined} = MrFeedbackLedger.dismiss(context.store, "v1-receipt", :stale)
    assert {:error, :feedback_run_quarantined} = MrFeedbackLedger.claim(context.store, "v1-receipt", "request", nil)

    assert :ok = MrFeedbackLedger.supersede_changed(context.store, "grailbio/grail", 123, "discussion-1", 51, "edited body")
    assert Store.one!(context.store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = 'v1-receipt'")["status"] == "PENDING"
    assert Store.one!(context.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'MR_FEEDBACK_DISCOVERED'")["count"] == 0
  end

  test "a V1 owner quarantines feedback attached to an older LEGACY run for the same issue", context do
    assert {:ok, legacy_receipt} = candidate(context)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(context.store, legacy_receipt)
    Store.query!(context.store, "UPDATE mr_feedback_notes SET status = 'CLAIMED', request_key = 'old-controller-turn' WHERE feedback_key = ?", [legacy_receipt.feedback_key])

    assert {:ok, _v1} =
             RunLedger.register(context.store, %{run_id: "newer-supervisor", issue_key: context.run["issue_key"], kind: "DELIVERY", state: "READY_FOR_REVIEW", execution_mode: "TICKET_SUPERVISOR_V1"})

    before = Store.query!(context.store, "SELECT * FROM mr_feedback_notes ORDER BY feedback_key").rows

    assert MrFeedbackLedger.pending(context.store) == []
    assert MrFeedbackLedger.next(context.store) == nil
    assert {:error, :feedback_run_quarantined} = MrFeedbackLedger.finish(context.store, legacy_receipt.feedback_key, "old-controller-turn", "COMPLETE")
    receipts = [%{"feedback_key" => legacy_receipt.feedback_key}]

    assert {:error, :feedback_batch_claim_mismatch} =
             MrFeedbackLedger.finish_batch(context.store, receipts, "old-controller-turn", [%{"feedback_key" => legacy_receipt.feedback_key, "status" => "REPLIED"}], %{})

    assert {:error, :feedback_batch_claim_mismatch} =
             MrFeedbackLedger.reconcile_batch(context.store, receipts, "old-controller-turn", "uncertain")

    assert :ok = MrFeedbackLedger.supersede_changed(context.store, "grailbio/grail", 123, "discussion-1", 51, "changed note body")
    assert Store.query!(context.store, "SELECT * FROM mr_feedback_notes ORDER BY feedback_key").rows == before
  end

  test "rejects missing note and discussion identities without persisting them", context do
    assert {:error, :invalid_note_identity} = candidate(%{context | discussion: %{"id" => " "}})
    assert {:error, :invalid_note_identity} = candidate(%{context | note: Map.put(context.note, "updated_at", nil)})
    assert {:error, :invalid_note_identity} = candidate(%{context | note: Map.put(context.note, "id", 0)})
    assert {:error, :non_actionable_note} = candidate(%{context | note: Map.put(context.note, "body", nil)})
    assert MrFeedbackLedger.pending(context.store) == []
    assert {:error, :invalid_feedback_note} = MrFeedbackLedger.supersede_changed(context.store, nil, 123, "discussion", 51, "edited")
  end

  defp candidate(context, allowed_ids \\ [12], bot_id \\ 99) do
    MrFeedback.candidate(
      context.run,
      context.route,
      context.jira,
      context.mr,
      context.discussion,
      context.note,
      allowed_ids,
      bot_id
    )
  end
end
