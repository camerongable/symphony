defmodule SymphonyElixir.FactoryTicketCiGenerationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{Store, TicketCiGeneration}

  test "generation preparation cannot observe files or tools inside a SQL checkout" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})

    assert {:error, :controller_generation_observation_inside_transaction} =
             Store.transaction!(ctx.store, &TicketCiGeneration.prepare(&1, "missing-writer"))

    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_generation_intents").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_generation_events").rows == []
  end

  test "a pinned toolset cannot create an intent without an actual admitted writer" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'")
    assert {:error, reason} = TicketCiGeneration.prepare(ctx.store, "missing-writer")
    assert reason in [:ci_repair_generator_unavailable, :unknown_worker_attempt]
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_generation_intents").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_generation_events").rows == []
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'") == before
    assert {:ok, %{status: "UNAVAILABLE", intents: []}} = TicketCiGeneration.readback(ctx.store, "missing-writer")
  end

  test "separate generation journal schema is idempotent while unavailable" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    assert {:error, reason} = TicketCiGeneration.prepare(ctx.store, "missing-writer")
    assert reason in [:ci_repair_generator_unavailable, :unknown_worker_attempt]
    definitions = Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'ci_generation_%'").rows
    assert length(definitions) == 7
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence")["count"] == 0
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'ci_generation_%'").rows == definitions
  end
end
