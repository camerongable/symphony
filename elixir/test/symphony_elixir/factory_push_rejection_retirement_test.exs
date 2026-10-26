defmodule SymphonyElixir.FactoryPushRejectionRetirementTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{Store, TicketPushPreissuanceRejection, WorkspaceAccess}
  alias SymphonyElixir.Factory.TicketPushOrdinaryRejection

  test "ordinary retirement refuses missing normal lease and unrelated runs without mutation" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    before = protected(ctx.store)
    assert {:error, :push_rejection_normal_tick_required} = TicketPushOrdinaryRejection.rearm(ctx.store, "run", %{}, [])
    assert {:error, :push_recovery_operator_tick_unproven} = TicketPushOrdinaryRejection.rearm(ctx.store, "run", %{}, ordinary_controller_tick: true)
    refute TicketPushOrdinaryRejection.eligible?(Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'"))
    refute TicketPushOrdinaryRejection.status_execution?(%{})
    assert {:error, :push_rejection_transaction_required} = WorkspaceAccess.transfer_ordinary_preissuance_rejection(ctx.store, %{}, %{}, [])
    assert protected(ctx.store) == before
  end

  test "ordinary journal consumers refuse changed or duplicate records after reopening" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    assert :ok = TicketPushOrdinaryRejection.current(ctx.store, %{"run_id" => "run"}, %{}, %{})

    for _ <- 1..2 do
      Store.query!(ctx.store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES('TICKET_ORDINARY_PUSH_REJECTION_RETIRED','run','{}','fixture')")
      assert {:error, :ordinary_rejection_lineage_changed} = TicketPushOrdinaryRejection.current(ctx.store, %{"run_id" => "run"}, %{}, %{})
    end

    before = Store.query!(ctx.store, "SELECT rowid,* FROM events ORDER BY rowid").rows
    assert :ok = Store.initialize(ctx.store)
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    result = TicketPushOrdinaryRejection.current(reader, %{"run_id" => "run"}, %{}, %{})
    assert {:error, :ordinary_rejection_lineage_changed} = result
    assert Store.query!(reader, "SELECT rowid,* FROM events ORDER BY rowid").rows == before
    GenServer.stop(reader)
  end

  test "audited rejection dispatch denies ordinary readback, absent lease, and changed identity without mutations" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    before = protected(ctx.store)

    assert {:error, :push_rejection_normal_tick_required} =
             TicketPushPreissuanceRejection.rearm(ctx.store, "run", %{}, [])

    assert {:error, :push_recovery_operator_tick_unproven} =
             TicketPushPreissuanceRejection.rearm(ctx.store, "run", %{}, ordinary_controller_tick: true)

    refute TicketPushPreissuanceRejection.eligible?(Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'"))
    refute TicketPushPreissuanceRejection.status_execution?(%{})

    assert {:error, :push_rejection_transaction_required} =
             WorkspaceAccess.transfer_preissuance_rejection(ctx.store, %{}, %{}, [])

    assert protected(ctx.store) == before
  end

  test "rejection journal is additive immutable once-only and restart-readable" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,?,?,?,?,?,?)", [
      "diag",
      "run",
      "sha",
      99,
      "{}",
      "sha",
      "{}",
      "sha",
      "BLOCKED",
      "fixture"
    ])

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,?,?,?,?,?)", [
      "claim",
      "diag",
      "run",
      2,
      "{}",
      "sha",
      "fixture"
    ])

    base = %{"prepared_requalification" => %{"authorization_key" => "prepared"}, "bootstrap_recovery" => %{"status" => "COMPLETED"}}
    successor = Map.put(base, "preissuance_retirement", %{"retirement_key" => "retirement", "original_sha256" => "sha", "attempt" => 1})
    binding_sha = :crypto.hash(:sha256, Jason.encode!(successor)) |> Base.encode16(case: :lower)

    values = [
      "retirement",
      "run",
      "sha",
      2,
      "claim",
      "old-nonce",
      "raw-original",
      "sha",
      "raw-proof",
      "sha",
      "new-nonce",
      binding_sha,
      "new-reservation",
      "fixture"
    ]

    Store.query!(
      ctx.store,
      "INSERT INTO ticket_push_rejection_retirements VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      values
    )

    run = %{"run_id" => "run", "candidate_sha" => "sha", "code_repair_round" => 2}
    assert TicketPushPreissuanceRejection.bind(ctx.store, run, base) == successor

    for incomplete <- [Map.delete(base, "prepared_requalification"), Map.delete(base, "bootstrap_recovery"), %{}] do
      assert TicketPushPreissuanceRejection.bind(ctx.store, run, incomplete) == incomplete
    end

    assert TicketPushPreissuanceRejection.bind(ctx.store, %{run | "candidate_sha" => "other"}, base) == base

    for sql <- [
          "UPDATE ticket_push_rejection_retirements SET proof_json='changed'",
          "DELETE FROM ticket_push_rejection_retirements",
          "DELETE FROM factory_schema_migrations WHERE version=45",
          "INSERT INTO ticket_push_rejection_retirements SELECT 'other',run_id,candidate_sha,code_repair_round,claim_key,'other-old',original_envelope,original_sha256,proof_json,proof_sha256,'other-new',successor_binding_sha256,'other-reservation',created_at FROM ticket_push_rejection_retirements"
        ] do
      assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql) end
    end

    before = protected(ctx.store)
    assert :ok = Store.initialize(ctx.store)
    assert protected(ctx.store) == before
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert protected(reader) == before
    GenServer.stop(reader)
  end

  defp protected(store) do
    Enum.map(
      ~w(runs workspace_access ticket_push_rejection_retirements ticket_ci_repair_claims ticket_ci_repair_diagnoses),
      &Store.query!(store, "SELECT * FROM #{&1} ORDER BY 1").rows
    )
  end
end
