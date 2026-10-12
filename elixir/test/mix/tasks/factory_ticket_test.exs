defmodule Mix.Tasks.Factory.TicketTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import SymphonyElixir.TicketChatFixture
  alias Mix.Tasks.Factory.Ticket
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChatCommands, TicketChatOutbox}

  setup context do
    ctx = setup_fixture(context)
    workflow = Path.join(ctx.root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\n")
    Map.put(ctx, :workflow, workflow)
  end

  test "context, scoped details, journal, records and synchronization never wake a model", ctx do
    assert capture_io(fn -> Ticket.run(["--help"]) end) =~ "PENDING"
    packet = cli(ctx, ["context", "run"])
    assert packet["identity"]["thread_id"] == "parent"
    detail = cli(ctx, ["details", "run", packet["contract"]["artifact"]["artifact_ref"]])
    assert detail["text"] == ctx.contract.markdown
    journal = cli(ctx, ["journal", "run", "--after", "0", "--high-water", to_string(packet["journal_page"]["high_water_id"]), "--limit", "1"])
    assert length(journal["events"]) == 1
    records = cli(ctx, ["records", "run", "tasks", "--high-water", "0"])
    assert records["records"] == []
    assert cli(ctx, ["synchronization", "run"])["request"] == nil
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 1
  end

  test "replay exposes bounded pages and fixed high-waters without mutating the ledger", ctx do
    for n <- 1..15 do
      Store.query!(ctx.store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('REPLAY_TEST', 'run', ?, '2026-10-08')", [Jason.encode!(%{n: n})])
    end

    before = replay_state(ctx.store)
    replay = cli(ctx, ["replay", "run"])
    assert replay["synchronization"]["delivery_unchanged"]
    assert replay["journal"]["has_more"]
    assert length(replay["journal"]["events"]) == 10
    assert replay["journal"]["high_water_id"] == replay["high_water"]["journal_event_id"]
    assert replay["records"]["workers"]["records"] == []
    assert replay["records"]["tasks"]["next_cursor"] == nil
    assert Enum.any?(replay["uncertainty"], &String.match?(&1, ~r/additional journal events/i))
    assert is_binary(replay["next_action"])
    assert cli(ctx, ["journal", "run", "--after", to_string(replay["journal"]["next_cursor"]), "--high-water", to_string(replay["high_water"]["journal_event_id"]), "--limit", "10"])["events"] != []
    assert replay_state(ctx.store) == before
  end

  test "strict staging returns pending and command scope cannot be changed", ctx do
    {:ok, run} = RunLedger.get(ctx.store, "run")

    attrs =
      Map.take(run, ~w(spec_revision contract_sha256 candidate_sha))
      |> Map.merge(%{"generation" => 1, "proposal_id" => "cli", "body" => "Rework the current candidate.", "operations" => [%{"operation" => "request_rework"}]})

    encoded = attrs |> Jason.encode!() |> Base.encode64()
    pending = cli(ctx, ["stage", "run", "--payload-base64", encoded])
    assert pending["status"] == "PENDING"
    assert cli(ctx, ["command", "run", pending["command_key"]]) == pending
    assert_raise Mix.Error, ~r/command_not_in_run/, fn -> cli(ctx, ["command", "wrong-run", pending["command_key"]]) end
    assert {:ok, %{"status" => "PENDING"}} = TicketChatCommands.get(ctx.store, pending["command_key"])
    assert {:ok, %{status: "PENDING"}} = TicketChatOutbox.publish(ctx.store, "run")
    assert cli(ctx, ["synchronization", "run"])["request"]["status"] == "PENDING"
  end

  test "CLI rejects supplied readback, invalid payloads, paging and bad configuration", ctx do
    previous_workflow = Application.fetch_env(:symphony_elixir, :workflow_file_path)
    assert_raise Mix.Error, ~r/Invalid ticket arguments/, fn -> Ticket.run(["context", "run", "--unknown", "yes"]) end

    for action <- [
          ["collect", "run"],
          ["prepare-stage", "run"],
          ["details", "unknown", "ref"],
          ["journal", "run"],
          ["stage", "run", "--payload-base64", "!bad"],
          ["stage", "run", "--payload-base64", Base.encode64("[]")],
          ["stage", "run", "--payload-base64", String.duplicate("a", 32_769)]
        ] do
      assert_raise Mix.Error, ~r/Ticket operation failed/, fn -> cli(ctx, action) end
    end

    assert_raise Mix.Error, ~r/Unable to load ticket store/, fn -> Ticket.run(["context", "run", "--workflow", Path.join(ctx.root, "missing")]) end
    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == previous_workflow
  end

  test "read-only connection permits snapshot transactions but rejects ledger writes", ctx do
    before_schema = Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master ORDER BY type, name").rows
    before_versions = Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows
    journal_mode = Store.one!(ctx.store, "PRAGMA journal_mode")
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)

    try do
      assert Store.transaction!(reader, fn connection -> Store.one!(connection, "SELECT run_id FROM runs") end) == %{"run_id" => "run"}
      assert_raise Exqlite.Error, ~r/readonly/, fn -> Store.query!(reader, "UPDATE runs SET state = 'FAILED'") end
      assert_raise Exqlite.Error, ~r/readonly/, fn -> Store.query!(reader, "CREATE TABLE reader_mutation (id INTEGER)") end
      assert cli(ctx, ["context", "run"])["run"]["state"] == "WRITING"
    after
      GenServer.stop(reader)
    end

    assert Store.query!(ctx.store, "SELECT type, name, sql FROM sqlite_master ORDER BY type, name").rows == before_schema
    assert Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows == before_versions
    assert Store.one!(ctx.store, "PRAGMA journal_mode") == journal_mode
  end

  test "read-only opening does not create missing paths or accept a symlink", ctx do
    absent = Path.join([ctx.root, "missing-parent", "ledger.sqlite"])
    assert {:error, :existing_factory_ledger_required} = Store.start_read_only(database: absent)
    refute File.exists?(Path.dirname(absent))
    assert {:error, :existing_factory_ledger_required} = Store.start_read_only(database: ":memory:")
    assert {:error, :existing_factory_ledger_required} = Store.start_read_only(database: ctx.root)
    absent_workflow = workflow(ctx, absent, "missing-ledger-WORKFLOW.md")
    assert_raise Mix.Error, ~r/existing_factory_ledger_required/, fn -> cli(ctx, ["replay", "run"], absent_workflow) end
    refute File.exists?(Path.dirname(absent))
    link = Path.join(ctx.root, "linked.sqlite")
    File.ln_s!(ctx.database, link)
    assert {:error, :existing_factory_ledger_required} = Store.start_read_only(database: link)
    linked_workflow = workflow(ctx, link, "linked-ledger-WORKFLOW.md")
    assert_raise Mix.Error, ~r/existing_factory_ledger_required/, fn -> cli(ctx, ["replay", "run"], linked_workflow) end
  end

  test "read-only opening rejects an outdated or incomplete schema without upgrading it", ctx do
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version = 24")
    before = Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert_raise Mix.Error, ~r/factory_ledger_schema_not_current/, fn -> cli(ctx, ["replay", "run"]) end
    assert Store.query!(ctx.store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows == before
    Store.initialize(ctx.store)
    Store.query!(ctx.store, "ALTER TABLE ticket_chat_questions DROP COLUMN answers_json")
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    refute Enum.any?(Store.query!(ctx.store, "PRAGMA table_info(ticket_chat_questions)").rows, &(Enum.at(&1, 1) == "answers_json"))
    Store.query!(ctx.store, "DROP TABLE ticket_chat_questions")
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    refute Store.one!(ctx.store, "SELECT name FROM sqlite_master WHERE name = 'ticket_chat_questions'")
    Store.initialize(ctx.store)
    Store.query!(ctx.store, "ALTER TABLE worker_evidence DROP COLUMN binding_json")
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    refute Enum.any?(Store.query!(ctx.store, "PRAGMA table_info(worker_evidence)").rows, &(Enum.at(&1, 1) == "binding_json"))
    Store.initialize(ctx.store)
    Store.query!(ctx.store, "ALTER TABLE worker_evidence DROP COLUMN consumed_at")
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    refute Enum.any?(Store.query!(ctx.store, "PRAGMA table_info(worker_evidence)").rows, &(Enum.at(&1, 1) == "consumed_at"))
  end

  defp cli(ctx, args, workflow \\ nil) do
    capture_io(fn -> Ticket.run(args ++ ["--workflow", workflow || ctx.workflow]) end) |> Jason.decode!()
  end

  defp workflow(ctx, database, name) do
    path = Path.join(ctx.root, name)
    File.write!(path, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{database}\n---\n")
    path
  end

  defp replay_state(store) do
    %{
      schema: Store.query!(store, "SELECT type, name, sql FROM sqlite_master ORDER BY type, name").rows,
      migrations: Store.query!(store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows,
      events: Store.query!(store, "SELECT * FROM events ORDER BY id").rows,
      requests: Store.query!(store, "SELECT * FROM desktop_requests ORDER BY request_key").rows,
      intents: Store.query!(store, "SELECT * FROM ticket_checkout_intents ORDER BY run_id").rows,
      chat: Store.query!(store, "SELECT * FROM ticket_chats ORDER BY chat_key").rows
    }
  end
end
