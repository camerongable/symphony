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

  test "adds a nullable execution mode idempotently and preserves a historical file database" do
    database = Path.join(System.tmp_dir!(), "factory-execution-mode-#{System.unique_integer([:positive])}.sqlite")
    on_exit(fn -> File.rm(database) end)

    {:ok, original} = Store.start_link(database: database)

    version16_applied_at =
      try do
        Store.query!(original, "DELETE FROM factory_schema_migrations WHERE version = 16")
        Store.query!(original, "ALTER TABLE runs DROP COLUMN execution_mode")
        assert Store.one!(original, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 15
        assert Store.one!(original, "SELECT COUNT(*) AS count FROM factory_schema_migrations")["count"] == 15

        Store.query!(original, """
        INSERT INTO runs (run_id, issue_key, kind, state, candidate_sha, created_at, updated_at)
        VALUES ('historical-run', 'PPL-100', 'SPECIFICATION', 'FAILED', 'old-candidate', 'created-old', 'updated-old')
        """)

        Store.query!(original, """
        INSERT INTO events (occurred_at, event_type, run_id, payload_json)
        VALUES ('event-old', 'HISTORICAL_EVENT', 'historical-run', '{"kept":true}')
        """)

        Store.query!(original, """
        INSERT INTO desktop_requests (
          request_key, target_kind, target_key, action, status, payload_sha256,
          codex_project_id, model, reasoning_effort, title, prompt, schema_json,
          cwd, metadata_json, created_at, updated_at
        ) VALUES (
          'historical-request', 'CONTROLLER', 'assigned-jira-work', 'FOLLOWUP', 'PENDING',
          '#{String.duplicate("c", 64)}', 'projectless', 'gpt-test', 'medium', 'Old controller',
          'Preserve exact request bytes', '{}', '/tmp/controller', '{}', 'created-request', 'updated-request'
        )
        """)

        historical_before = Store.one!(original, "SELECT * FROM runs WHERE run_id = 'historical-run'")
        events_before = Store.query!(original, "SELECT * FROM events WHERE run_id = 'historical-run'").rows
        request_before = Store.one!(original, "SELECT * FROM desktop_requests WHERE request_key = 'historical-request'")

        assert :ok = Store.initialize(original)
        version16_receipt = Store.one!(original, "SELECT applied_at FROM factory_schema_migrations WHERE version = 16")
        assert is_binary(version16_receipt["applied_at"])

        assert :ok = Store.initialize(original)
        assert Store.one!(original, "SELECT applied_at FROM factory_schema_migrations WHERE version = 16") == version16_receipt

        upgraded = Store.one!(original, "SELECT * FROM runs WHERE run_id = 'historical-run'")
        assert upgraded["execution_mode"] == nil
        assert Map.drop(upgraded, ["execution_mode"]) == historical_before
        assert Store.query!(original, "SELECT * FROM events WHERE run_id = 'historical-run'").rows == events_before
        assert Store.one!(original, "SELECT * FROM desktop_requests WHERE request_key = 'historical-request'") == request_before
        assert Store.one!(original, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 16
        version16_receipt["applied_at"]
      after
        GenServer.stop(original)
      end

    {:ok, reopened} = Store.start_link(database: database)

    try do
      reopened_run = Store.one!(reopened, "SELECT * FROM runs WHERE run_id = 'historical-run'")
      assert reopened_run["execution_mode"] == nil
      assert reopened_run["candidate_sha"] == "old-candidate"
      assert reopened_run["created_at"] == "created-old"
      assert reopened_run["updated_at"] == "updated-old"

      assert Store.one!(reopened, "SELECT event_type, run_id, payload_json FROM events WHERE run_id = 'historical-run'") == %{
               "event_type" => "HISTORICAL_EVENT",
               "run_id" => "historical-run",
               "payload_json" => "{\"kept\":true}"
             }

      assert Store.one!(reopened, "SELECT payload_sha256, prompt, status FROM desktop_requests WHERE request_key = 'historical-request'") == %{
               "payload_sha256" => String.duplicate("c", 64),
               "prompt" => "Preserve exact request bytes",
               "status" => "PENDING"
             }

      assert Store.one!(reopened, "SELECT applied_at FROM factory_schema_migrations WHERE version = 16")["applied_at"] ==
               version16_applied_at
    after
      GenServer.stop(reopened)
    end
  end
end
