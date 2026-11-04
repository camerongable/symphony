defmodule SymphonyElixir.FactoryCompletedPublicationTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{RunLedger, Scheduler, Store, TicketPush, TicketWorkerRunner}

  for preflight <- [false, true] do
    @preflight preflight
    @tag timeout: 180_000
    test "a later verifier pass reuses the same published content without a second push (preflight=#{@preflight})" do
      ctx = SymphonyElixir.TicketWorkerFixture.publication_fixture(%{count_pushes: true, ci_preflight: @preflight})
      original = ctx.publication_run["candidate_handoff"]
      {:ok, intent} = Jason.decode(original)
      assert Jason.decode!(intent["binding_json"])["publication_version"] == 2
      assert File.read!(Path.join(ctx.root, "push-count")) == "push\n"
      {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "PUSHING", verifier_round: ctx.publication_run["verifier_round"] + 1})
      missing_verifier = TicketPush.step(ctx.store, "run", ctx.authorization, ctx.options)
      assert match?({:ok, %{status: "PUSH_SETTLED_HELD"}}, missing_verifier) or match?({:error, :ticket_delivery_verifier_pass_unproven}, missing_verifier)

      {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING"})

      if @preflight do
        sha = ctx.publication_run["candidate_sha"]
        {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_preflight_sha: sha, ci_pipeline_id: 123, ci_evidence_json: Jason.encode!(%{status: "PASS", sha: sha, pipeline_id: 123})})
      end

      assert {:ok, %{status: "LAUNCHED", launch: launch}} = Scheduler.ticket_step(ctx.worker_context, "run", ctx.options)
      key = launch.task_key
      assert_receive {:factory_task_started, ^key, _}, 15_000
      assert_receive {:factory_task_finished, ^key, {:ok, _}}, 60_000
      assert {:ok, %{status: "ADOPTED", run: verified}} = Scheduler.ticket_step(ctx.worker_context, "run", ctx.options)
      assert verified["state"] == "PUSHING"
      {:ok, snapshot} = SymphonyElixir.TicketWorkerFixture.PublicationJiraReader.issue("PPL-123", store: ctx.store)
      {:ok, authorization} = TicketWorkerRunner.authorization(verified, snapshot, DateTime.utc_now())

      assert {:ok, ^intent} = TicketPush.prepare(ctx.store, "run", authorization, ctx.options)

      assert {:ok, %{status: "PUSH_COMPLETED", run: advanced}} = TicketPush.step(ctx.store, "run", authorization, ctx.options)
      assert advanced["state"] == "MR_CREATING"
      assert advanced["candidate_handoff"] == original
      assert {:ok, proof} = TicketPush.completed_proof(ctx.store, "run")
      assert proof.intent == intent
      assert :ok = TicketPush.validate_completed_proof(ctx.store, "run", proof)
      assert :ok = TicketPush.validate_historical_completed_preimage(ctx.store, advanced)
      assert {:ok, historical} = TicketPush.observe_historical_completed_preimage(ctx.store, advanced)
      assert :ok = TicketPush.recheck_historical_completed_preimage(ctx.store, advanced, historical)
      assert {:ok, %{status: "PUSH_ALREADY_COMPLETED"}} = TicketPush.step(ctx.store, "run", authorization, ctx.options)
      assert {:ok, reader} = Store.start_read_only(database: ctx.database)
      assert {:ok, %{status: "PUSH_ALREADY_COMPLETED"}} = TicketPush.step(reader, "run", authorization, ctx.options)
      GenServer.stop(reader)
      assert File.read!(Path.join(ctx.root, "push-count")) == "push\n"

      for change <- [%{candidate_sha: String.duplicate("f", 40)}, %{spec_revision: 99}, %{contract_sha256: String.duplicate("e", 64)}] do
        assert {:error, :negative_fixture} =
                 Exqlite.transaction(ctx.store, fn tx ->
                   assert {:ok, _} = RunLedger.update(tx, "run", change)
                   assert {:error, _} = TicketPush.completed_proof(tx, "run")
                   Exqlite.rollback(tx, :negative_fixture)
                 end)
      end
    end
  end
end
