defmodule SymphonyElixir.FactoryMrPresendRecoveryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{Control, DesktopRequest, Store, TicketMrOwnerAdmission, TicketMrPresendEvidence}
  alias SymphonyElixir.TestSupport.MrPresendFixture

  test "startup fixture exercises the production bounded parser with a sole active loader" do
    root = Path.join(System.tmp_dir!(), "mr-presend-parser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    request = %{"request_key" => "synthetic-request", "claimed_at" => "synthetic-claim"}
    adapter = MrPresendFixture.build(root, request, "fixture-broker", root)
    {native, latest} = MrPresendFixture.native("fixture-broker", root)
    digest = fn value -> :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower) end
    queue = %{"data" => [], "nextCursor" => nil}

    native =
      native
      |> Map.put("latest_turn_observation", %{
        "mode" => "LATEST_DESC",
        "raw_response" => latest,
        "updated_at" => 2,
        "sha256" => digest.(latest),
        "confirmation" => %{"raw_response" => latest, "sha256" => digest.(latest)}
      })
      |> Map.put("queue_observation", %{"thread_id" => "fixture-broker", "raw_response" => queue, "sha256" => digest.(queue)})

    assert {:ok, evidence} = adapter.read(request, "fixture-broker", native)
    assert evidence["state"]["incident_call_id"] == "incident-call"
    assert %{"exec_call_id" => "loader-call", "cell_id" => "1271", "turn_id" => "recovery-turn"} = evidence["state"]["active_recovery"]
    assert [%{"classification" => "CURRENT_RECOVERY_WAIT", "turn_id" => "recovery-turn", "cell_id" => "1271"}] = Map.values(evidence["state"]["pending"])
    interrupted_latest = put_in(latest, ["data", Access.at(0), "status"], "interrupted")

    interrupted =
      native
      |> Map.put("status", %{"type" => "notLoaded"})
      |> Map.put("latest_turn_observation", %{
        "mode" => "LATEST_DESC",
        "raw_response" => interrupted_latest,
        "updated_at" => 2,
        "sha256" => digest.(interrupted_latest),
        "confirmation" => %{"raw_response" => interrupted_latest, "sha256" => digest.(interrupted_latest)}
      })

    assert {:error, :mr_presend_broker_native_unproven} = adapter.native_fence(interrupted, "fixture-broker")
    assert {:ok, %{"turn_status" => "interrupted"}} = adapter.recovery_projection(interrupted, "fixture-broker")
    assert {:ok, %{"source_observation" => %{"turn_id" => "recovery-turn"}}} = adapter.read(request, "fixture-broker", interrupted)
  end

  test "arbitrary previous state and forged owner context cannot enter the checkpoint path" do
    forged = %TicketMrOwnerAdmission{authority: make_ref(), action: :recover, factory: %{database: "/synthetic/factory.sqlite"}}
    assert {:error, :mr_owner_service_authority_required} = TicketMrPresendEvidence.recheck(%{}, "broker", %{}, forged)
    checkpoint = %{previous: %{state: %{incident_seen: true}}}
    assert {:error, :mr_owner_service_authority_required} = TicketMrPresendEvidence.recheck(%{}, "broker", %{}, checkpoint)
  end

  test "controlled claim race fixture mutates the real claim timestamp column" do
    root = Path.join(System.tmp_dir!(), "mr-presend-claim-race-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, database: Path.join(root, "factory.sqlite")})
    Control.initialize(store, %{scope: "synthetic", dispatcher_id: "fixture", controller_codex_project_id: "fixture"})

    assert {:ok, request} =
             DesktopRequest.enqueue(store, %{
               request_key: "synthetic-race",
               target_kind: "CONTROLLER",
               target_key: "synthetic",
               action: "CREATE",
               codex_project_id: "fixture",
               model: "gpt-6-sol",
               reasoning_effort: "low",
               title: "Synthetic race parent",
               prompt: "Synthetic",
               schema: %{"type" => "object"},
               cwd: root,
               metadata: %{}
             })

    Store.query!(store, "INSERT INTO ticket_mr_claims(request_key,receipt_json,receipt_sha256,claimed_at) VALUES(?,'{}','fixture','original')", [request["request_key"]])
    reader = MrPresendFixture.observing(TicketMrPresendEvidence, :claim)
    :persistent_term.put({reader, :state}, %{store: store})
    on_exit(fn -> :persistent_term.erase({reader, :state}) end)
    assert {:error, "mr_presend_session_changed"} = reader.read(request, "fixture", %{})
    assert Store.one!(store, "SELECT claimed_at FROM ticket_mr_claims WHERE request_key=?", [request["request_key"]]) == %{"claimed_at" => "changed-claim"}
  end

  test "additive recovery consumption schema is current and read-only reopen preserves all rows" do
    root = Path.join(System.tmp_dir!(), "mr-presend-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "factory.sqlite")
    store = start_supervised!({Store, database: database})
    assert Store.query!(store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..52, &[&1])
    assert Store.query!(store, "SELECT * FROM ticket_mr_presend_consumptions").rows == []
    before = Store.query!(store, "SELECT * FROM factory_schema_migrations ORDER BY version").rows
    assert {:ok, reader} = Store.start_read_only(database: database)
    assert Store.query!(reader, "SELECT * FROM factory_schema_migrations ORDER BY version").rows == before
    assert Store.query!(reader, "SELECT * FROM ticket_mr_presend_consumptions").rows == []
    GenServer.stop(reader)
  end

  test "populated schema51 migration is additive concurrent repeatable and failure atomic" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    Store.query!(ctx.store, "DROP TRIGGER mr_presend_schema_rollback")
    Store.query!(ctx.store, "DROP TABLE ticket_mr_presend_consumptions")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=52")
    assert Store.query!(ctx.store, "SELECT version FROM factory_schema_migrations ORDER BY version").rows == Enum.map(1..51, &[&1])

    rows = fn ->
      Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name!='ticket_mr_presend_consumptions' ORDER BY name").rows
      |> Map.new(fn [table] -> {table, Store.query!(ctx.store, "SELECT rowid,* FROM #{table} ORDER BY rowid").rows} end)
    end

    before = rows.()
    assert Enum.any?(before, fn {table, values} -> table != "factory_schema_migrations" and values != [] end)
    Store.query!(ctx.store, "CREATE TRIGGER reject52 BEFORE INSERT ON factory_schema_migrations WHEN NEW.version=52 BEGIN SELECT RAISE(ABORT,'fixture_reject52'); END")
    schema = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").rows
    assert_raise Exqlite.Error, fn -> Store.initialize(ctx.store) end
    assert rows.() == before
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").rows == schema
    Store.query!(ctx.store, "DROP TRIGGER reject52")
    outcomes = for _ <- 1..2, do: Task.async(fn -> Store.initialize(ctx.store) end)
    assert Enum.map(outcomes, &Task.await(&1, 30_000)) == [:ok, :ok]
    assert Map.delete(rows.(), "factory_schema_migrations") == Map.delete(before, "factory_schema_migrations")
    assert Enum.take(rows.()["factory_schema_migrations"], 51) == before["factory_schema_migrations"]
    assert Store.query!(ctx.store, "SELECT * FROM ticket_mr_presend_consumptions").rows == []
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert :ok = Store.initialize(ctx.store)
  end
end
