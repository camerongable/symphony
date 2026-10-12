defmodule SymphonyElixir.FactoryStoreMigrationTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketChatFixture

  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChatCommands, TicketContractAmendment}

  test "populated version 30 ledger rejects read-only without mutation and migrates through version 34" do
    ctx = setup_fixture(%{})
    {:ok, legacy_command} = stage(ctx, "v28-migration", "Rework: current candidate", [%{"operation" => "request_rework"}])
    command_before = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [legacy_command["command_key"]])
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    chat_before = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])
    link_before = Store.one!(ctx.store, "SELECT * FROM ticket_chat_runs WHERE run_id = 'run'")

    assert Store.one!(ctx.store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 30") != nil
    assert Store.query!(ctx.store, "PRAGMA table_info(ticket_chat_commands)").rows |> Enum.any?(&(Enum.at(&1, 1) == "application_receipt_json"))
    Store.query!(ctx.store, "DROP TABLE ticket_amendment_jira_effects")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version = 31")
    schema_before = Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows
    versions_before = Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows

    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows == schema_before
    assert Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows == versions_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [legacy_command["command_key"]]) == command_before

    assert :ok = Store.initialize(ctx.store)
    assert Store.one!(ctx.store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 31") != nil
    assert Store.one!(ctx.store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 32") != nil
    assert Store.one!(ctx.store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 33") != nil
    assert Store.one!(ctx.store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 34") != nil
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [legacy_command["command_key"]]) == command_before
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]]) == chat_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_runs WHERE run_id = 'run'") == link_before
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    GenServer.stop(reader)
  end

  test "populated version 33 ledger rejects read-only without mutation and migrates the amendment phase" do
    ctx = setup_fixture(%{})
    markdown = "Migration proposal\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    {:ok, staged} = stage(ctx, "v33-amendment", body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    chat = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])

    amendment_context = %{
      "chat_key" => chat["chat_key"],
      "run_id" => run["run_id"],
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run["spec_revision"], "contract_sha256" => run["contract_sha256"], "candidate_sha" => run["candidate_sha"]}
    }

    assert {:ok, _} = TicketContractAmendment.reserve(ctx.store, staged["command_key"], amendment_context)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [staged["command_key"]])
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    chat_before = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])
    request_before = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_key = ?", [ctx.chat["chat_key"]])

    legacy_sql =
      Store.one!(ctx.store, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ticket_contract_amendments'")["sql"]
      |> String.replace(~s|CREATE TABLE "ticket_contract_amendments"|, "CREATE TABLE ticket_contract_amendments_legacy")
      |> String.replace("CHECK(phase IN ('RESERVED', 'APPLIED', 'SUPERSEDED'))", "CHECK(phase IN ('RESERVED'))")
      |> String.replace(",\n      application_receipt_sha256 TEXT", "")

    columns =
      ~w(command_key run_id chat_key generation active_owner phase prior_binding_json prior_revision prior_contract_markdown prior_contract_sha256 proposed_revision proposed_contract_markdown proposed_contract_sha256 candidate_sha input_key input_sha256 readback_sha256 admission_sha256 payload_sha256 predecessor_json created_at updated_at last_error receipt_json)

    column_sql = Enum.join(columns, ", ")
    Store.query!(ctx.store, "PRAGMA foreign_keys = OFF")
    Store.query!(ctx.store, "PRAGMA legacy_alter_table = ON")
    Store.query!(ctx.store, legacy_sql)
    Store.query!(ctx.store, "INSERT INTO ticket_contract_amendments_legacy (#{column_sql}) SELECT #{column_sql} FROM ticket_contract_amendments")
    Store.query!(ctx.store, "DROP TABLE ticket_contract_amendments")
    Store.query!(ctx.store, "ALTER TABLE ticket_contract_amendments_legacy RENAME TO ticket_contract_amendments")
    Store.query!(ctx.store, "PRAGMA legacy_alter_table = OFF")
    Store.query!(ctx.store, "PRAGMA foreign_keys = ON")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version = 34")
    schema_before = Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows
    versions_before = Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows

    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows == schema_before
    assert Store.query!(ctx.store, "SELECT version, applied_at FROM factory_schema_migrations ORDER BY version").rows == versions_before

    assert :ok = Store.initialize(ctx.store)
    assert Store.one!(ctx.store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 34") != nil
    migrated_amendment = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [staged["command_key"]])
    assert Map.delete(migrated_amendment, "application_receipt_sha256") == Map.delete(amendment_before, "application_receipt_sha256")
    assert migrated_amendment["application_receipt_sha256"] == nil
    assert {:ok, _} = TicketContractAmendment.get(ctx.store, staged["command_key"])
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]]) == chat_before
    assert Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE target_key = ?", [ctx.chat["chat_key"]]) == request_before
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_amendment_authorization_effects")["count"] == 0
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    GenServer.stop(reader)
  end

  test "version 27 migration retains populated command rows and initializes a null application receipt" do
    ctx = setup_fixture(%{})
    payload = "[]"
    payload_sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

    Store.query!(
      ctx.store,
      """
      INSERT INTO ticket_chat_commands (
        command_key, proposal_id, chat_key, run_id, binding_json, body_sha256, payload_json,
        payload_sha256, status, receipt_json, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?, ?)
      """,
      [
        "legacy-command",
        "legacy-proposal",
        ctx.chat["chat_key"],
        "run",
        Jason.encode!(%{"generation" => 1, "spec_revision" => 1, "contract_sha256" => ctx.contract.sha256, "candidate_sha" => String.duplicate("a", 40)}),
        String.duplicate("b", 64),
        payload,
        payload_sha,
        "legacy-admission-bytes",
        "created-old",
        "updated-old"
      ]
    )

    Store.query!(ctx.store, "ALTER TABLE ticket_chat_commands DROP COLUMN application_receipt_json")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version = 28")
    stop_supervised!(Store)

    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert Store.one!(reopened, "SELECT receipt_json, application_receipt_json FROM ticket_chat_commands WHERE command_key = 'legacy-command'") == %{
               "receipt_json" => "legacy-admission-bytes",
               "application_receipt_json" => nil
             }

      assert Store.one!(reopened, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 37
    after
      GenServer.stop(reopened)
    end
  end

  test "version 26 ledger requires the idempotent Jira journal migration before read-only access" do
    database = Path.join(System.tmp_dir!(), "factory-jira-journal-#{System.unique_integer([:positive])}.sqlite")
    on_exit(fn -> File.rm(database) end)
    {:ok, store} = Store.start_link(database: database)

    try do
      before = Store.one!(store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 26")
      Store.query!(store, "DROP TABLE ticket_jira_effects")
      Store.query!(store, "DELETE FROM factory_schema_migrations WHERE version = 27")
      assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: database)
      assert :ok = Store.initialize(store)
      assert :ok = Store.initialize(store)
      assert Store.one!(store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 26") == before
      assert Store.one!(store, "SELECT COUNT(*) AS count FROM ticket_jira_effects")["count"] == 0
      assert {:ok, reader} = Store.start_read_only(database: database)
      GenServer.stop(reader)
    after
      GenServer.stop(store)
    end
  end

  test "version 25 ledger requires the idempotent MR claim migration before read-only access" do
    database = Path.join(System.tmp_dir!(), "factory-mr-claims-#{System.unique_integer([:positive])}.sqlite")
    on_exit(fn -> File.rm(database) end)
    {:ok, store} = Store.start_link(database: database)

    try do
      before = Store.one!(store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 25")
      Store.query!(store, "DROP TABLE ticket_mr_claims")
      Store.query!(store, "DELETE FROM factory_schema_migrations WHERE version = 26")
      assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: database)
      assert :ok = Store.initialize(store)
      assert :ok = Store.initialize(store)
      assert Store.one!(store, "SELECT applied_at FROM factory_schema_migrations WHERE version = 25") == before
      assert Store.one!(store, "SELECT COUNT(*) AS count FROM ticket_mr_claims")["count"] == 0
      assert {:ok, reader} = Store.start_read_only(database: database)
      GenServer.stop(reader)
    after
      GenServer.stop(store)
    end
  end

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
        Store.query!(original, "DELETE FROM factory_schema_migrations WHERE version >= 16")
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
        assert Store.one!(original, "SELECT MAX(version) AS version FROM factory_schema_migrations")["version"] == 37
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
