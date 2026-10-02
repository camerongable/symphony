defmodule SymphonyElixir.FactoryStoreMigrationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{RunLedger, Store}

  test "upgrades an existing MR feedback table without losing its receipts" do
    {:ok, store} = Store.start_link(database: ":memory:")

    assert {:ok, _run} =
             RunLedger.register(store, %{
               "run_id" => "delivery-before-feedback-upgrade",
               "issue_key" => "PPL-42",
               "kind" => "DELIVERY",
               "state" => "READY_FOR_REVIEW"
             })

    Store.query!(store, "DROP TABLE mr_feedback_notes")

    Store.query!(store, """
    CREATE TABLE mr_feedback_notes (
      feedback_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      project TEXT NOT NULL,
      mr_iid INTEGER NOT NULL,
      discussion_id TEXT NOT NULL,
      note_id INTEGER NOT NULL,
      note_updated_at TEXT NOT NULL,
      author_id INTEGER NOT NULL,
      body_sha256 TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('PENDING', 'CLAIMED', 'COMPLETE', 'FAILED')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    Store.query!(
      store,
      """
      INSERT INTO mr_feedback_notes (
        feedback_key, run_id, project, mr_iid, discussion_id, note_id,
        note_updated_at, author_id, body_sha256, status, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "old-receipt",
        "delivery-before-feedback-upgrade",
        "grailbio/grail",
        47_557,
        "discussion-1",
        393_425_243,
        "2026-09-30T10:00:00Z",
        12,
        "digest",
        "PENDING",
        "2026-09-30T10:00:00Z",
        "2026-09-30T10:00:00Z"
      ]
    )

    assert_raise Exqlite.Error, ~r/no such column: request_key/, fn ->
      Store.query!(store, "SELECT request_key FROM mr_feedback_notes LIMIT 1")
    end

    assert :ok = Store.initialize(store)

    assert %{"status" => "PENDING", "request_key" => nil, "reply_id" => nil, "reply_phase" => 0, "review_batch_key" => nil} =
             Store.one!(store, "SELECT status, request_key, reply_id, reply_phase, review_batch_key FROM mr_feedback_notes WHERE feedback_key = ?", [
               "old-receipt"
             ])

    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'SUPERSEDED' WHERE feedback_key = 'old-receipt'")
    assert :ok = Store.initialize(store)

    assert Store.one!(store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = 'old-receipt'")["status"] ==
             "SUPERSEDED"

    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'REWORKING' WHERE feedback_key = 'old-receipt'")

    assert Store.one!(store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = 'old-receipt'")["status"] ==
             "REWORKING"
  end
end
