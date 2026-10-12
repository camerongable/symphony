defmodule SymphonyElixir.FactoryTicketJiraJournalTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketJiraJournal, Worktree}

  setup context do
    ctx = setup_fixture(context)
    bind_parent(ctx)
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{state: "MR_CREATING", mr_url: "https://gitlab.example.test/project/-/merge_requests/1"})
    {:ok, checkout} = Worktree.checkout_identity(%{"path" => ctx.repo}, ctx.path, clean: true, detached: false, expected_branch: run["branch"], expected_sha: ctx.sha)
    Map.merge(ctx, %{run: run, checkout: Map.new(checkout, fn {key, value} -> {Atom.to_string(key), value} end), body: "Review candidate #{ctx.sha}: #{run["mr_url"]}"})
  end

  test "duplicate prepare preserves exact intent and checkout drift does not create another semantic key", ctx do
    assert {:ok, original} = prepare(ctx)
    assert {:ok, ^original} = prepare(ctx)
    assert {:error, :ticket_jira_intent_changed} = prepare(%{ctx | checkout: Map.put(ctx.checkout, "root_inode", ctx.checkout["root_inode"] + 1)})
    assert {:error, :ticket_jira_intent_changed} = prepare(%{ctx | body: "different comment"})
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects")["count"] == 1
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
  end

  test "invalid stages, checkout shapes and first effects never persist a journal", ctx do
    for checkout <- [nil, %{}, Map.put(ctx.checkout, "path", ctx.repo), Map.put(ctx.checkout, "root_inode", -1)] do
      assert {:error, :ticket_jira_checkout_binding_invalid} = prepare(%{ctx | checkout: checkout})
    end

    for body <- [nil, "", String.duplicate("x", 65_537)] do
      assert {:error, :ticket_jira_first_effect_invalid} = prepare(%{ctx | body: body})
    end

    assert {:error, :ticket_jira_stage_not_admitted} = TicketJiraJournal.prepare(ctx.store, "run", "START_IMPLEMENTATION", "11", ctx.checkout)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects")["count"] == 0
    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
  end

  test "hash-consistent but structurally invalid stored evidence cannot be claimed", ctx do
    {:ok, row} = prepare(ctx)
    key = row["operation_key"]

    effects = Jason.decode!(row["effects_json"])

    for {field, raw} <- [
          {"binding", "[]"},
          {"effects", "{}"},
          {"effects", "[]"},
          {"effects", Jason.encode!(Enum.take(effects, 1))},
          {"effects", Jason.encode!(Enum.reverse(effects))},
          {"effects", Jason.encode!(put_in(effects, [Access.at(0), "body"], ""))},
          {"effects", Jason.encode!(put_in(effects, [Access.at(1), "add_labels"], ["ai-ready"]))}
        ] do
      digest = Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
      Store.query!(ctx.store, "UPDATE ticket_jira_effects SET #{field}_json = ?, #{field}_sha256 = ? WHERE operation_key = ?", [raw, digest, key])
      assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.claim(ctx.store, key)
      assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"comments" => [%{"id" => "1", "body" => ctx.body}]}))
      assert {:ok, unchanged} = TicketJiraJournal.get(ctx.store, key)
      assert unchanged["phase"] == "FIRST_PENDING"
      assert is_nil(unchanged["first_receipt_json"])
      Store.query!(ctx.store, "UPDATE ticket_jira_effects SET #{field}_json = ?, #{field}_sha256 = ? WHERE operation_key = ?", [row[field <> "_json"], row[field <> "_sha256"], key])
    end
  end

  test "new verifier or push metadata rejects the original binding without allowing a second comment journal", ctx do
    assert {:ok, _} = prepare(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{verifier_round: ctx.run["verifier_round"] + 1})
    assert {:error, :ticket_jira_intent_changed} = prepare(ctx)
    Store.query!(ctx.store, "UPDATE runs SET verifier_round = ?, candidate_handoff = ? WHERE run_id = 'run'", [ctx.run["verifier_round"], "different push envelope"])
    assert {:error, :ticket_jira_intent_changed} = prepare(ctx)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_jira_effects")["count"] == 1
  end

  test "only one claim wins; restart and delayed readback never reclaim or repeat an uncertain comment", ctx do
    {:ok, row} = prepare(ctx)
    key = row["operation_key"]
    claims = for _ <- 1..3, do: Task.async(fn -> TicketJiraJournal.claim(ctx.store, key) end)
    results = Enum.map(claims, &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{"phase" => "FIRST_UNCERTAIN"}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :ticket_jira_effect_not_unissued})) == 2
    assert {:error, :ticket_jira_effect_not_observed} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"comments" => []}))
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:error, :ticket_jira_effect_not_unissued} = TicketJiraJournal.claim(reopened, key)
      assert {:ok, %{"phase" => "FIRST_UNCERTAIN"}} = TicketJiraJournal.prepare(reopened, "run", "REVIEW_READY", ctx.body, ctx.checkout)
      assert {:ok, %{"phase" => "SECOND_PENDING"}} = TicketJiraJournal.reconcile(reopened, key, observation(%{"comments" => [%{"id" => "101", "body" => ctx.body}]}))
      assert {:ok, %{"phase" => "SECOND_UNCERTAIN"}} = TicketJiraJournal.claim(reopened, key)
      assert {:ok, complete} = TicketJiraJournal.reconcile(reopened, key, observation(%{"labels" => ["ai-review", "human-added"]}))
      assert complete["phase"] == "COMPLETE"
      assert Jason.decode!(complete["first_receipt_json"])["observation"]["issue"]["comments"] == [%{"id" => "101", "body" => ctx.body}]
      assert {:ok, ^complete} = TicketJiraJournal.reconcile(reopened, key, %{})
      assert {:error, :ticket_jira_effect_not_unissued} = TicketJiraJournal.claim(reopened, key)
    after
      GenServer.stop(reopened)
    end

    assert {:ok, current} = RunLedger.get(ctx.store, "run")
    assert current == ctx.run
  end

  test "already observed effects avoid claims and ambiguous or incomplete comment readback never advances", ctx do
    {:ok, row} = prepare(ctx)
    key = row["operation_key"]

    for comments <- [
          nil,
          [%{"id" => "1"}],
          [%{"body" => ctx.body}],
          [nil, %{"id" => "1", "body" => ctx.body}],
          [%{"id" => "1", "body" => ctx.body}, %{"id" => "2", "body" => ctx.body}],
          List.duplicate(%{"id" => "1", "body" => "other"}, 100)
        ] do
      assert {:error, _} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"comments" => comments}))
      assert {:ok, ^row} = TicketJiraJournal.get(ctx.store, key)
    end

    assert {:ok, %{"phase" => "SECOND_PENDING"}} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"comments" => [%{"id" => "1", "body" => ctx.body}]}))
    assert {:error, :ticket_jira_effect_not_observed} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"labels" => ["ai-review", "ai-running"]}))
    assert {:ok, %{"phase" => "COMPLETE"}} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"labels" => ["ai-review", "unrelated"]}))
  end

  test "normalized Jira reader text-only comments qualify exact body while malformed text does not", ctx do
    {:ok, row} = prepare(ctx)
    key = row["operation_key"]
    invalid = %{"id" => "1", "text" => 42, "body" => ctx.body}
    observed = observation(%{"comments" => [invalid]})
    assert {:error, :ticket_jira_comment_readback_ambiguous} = TicketJiraJournal.reconcile(ctx.store, key, observed)
    observed = observation(%{"comments" => [%{"id" => "1", "text" => ctx.body}]})
    assert {:ok, %{"phase" => "SECOND_PENDING"}} = TicketJiraJournal.reconcile(ctx.store, key, observed)
    assert {:ok, %{"phase" => "COMPLETE"}} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"labels" => ["ai-review"]}))
  end

  test "uncertain effects reject pre-claim observations and require intact preceding receipts", ctx do
    {:ok, row} = prepare(ctx)
    key = row["operation_key"]
    before_claim = observation(%{"comments" => [%{"id" => "1", "body" => ctx.body}]}) |> Map.put("observed_at", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1)))
    {:ok, uncertain} = TicketJiraJournal.claim(ctx.store, key)
    assert {:error, :ticket_jira_readback_before_claim} = TicketJiraJournal.reconcile(ctx.store, key, before_claim)
    assert {:ok, ^uncertain} = TicketJiraJournal.get(ctx.store, key)
    assert {:ok, second} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"comments" => [%{"id" => "1", "body" => ctx.body}]}))

    for raw <- [nil, "not-json", Jason.encode!(%{"effect_index" => 1})] do
      Store.query!(ctx.store, "UPDATE ticket_jira_effects SET first_receipt_json = ? WHERE operation_key = ?", [raw, key])
      assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.claim(ctx.store, key)
      assert {:error, :ticket_jira_receipt_corrupt} = prepare(ctx)
      assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"labels" => ["ai-review"]}))
    end

    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET first_receipt_json = ? WHERE operation_key = ?", [second["first_receipt_json"], key])
    assert {:ok, complete} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"labels" => ["ai-review"]}))
    historical = Jason.decode!(complete["first_receipt_json"]) |> put_in(["observation", "observed_at"], "2026-01-01T00:00:00Z") |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET first_receipt_json = ? WHERE operation_key = ?", [historical, key])
    assert {:ok, %{"phase" => "COMPLETE"}} = TicketJiraJournal.reconcile(ctx.store, key, %{})
    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET second_receipt_json = NULL WHERE operation_key = ?", [key])
    assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.reconcile(ctx.store, key, %{})
    assert {:error, :ticket_jira_receipt_corrupt} = prepare(ctx)
  end

  test "foreign stale future malformed and oversized readbacks leave uncertainty intact", ctx do
    {:ok, row} = prepare(ctx)
    key = row["operation_key"]
    {:ok, uncertain} = TicketJiraJournal.claim(ctx.store, key)
    observed = observation(%{"comments" => [%{"id" => "1", "body" => ctx.body}]})

    for bad <- [
          nil,
          put_in(observed, ["issue", "key"], "PPL-999"),
          Map.put(observed, "source", "intent"),
          Map.put(observed, "observed_at", 1),
          Map.put(observed, "observed_at", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -61))),
          Map.put(observed, "observed_at", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))),
          put_in(observed, ["issue", "padding"], String.duplicate("x", 1_048_576))
        ] do
      assert {:error, :ticket_jira_readback_unproven} = TicketJiraJournal.reconcile(ctx.store, key, bad)
      assert {:ok, ^uncertain} = TicketJiraJournal.get(ctx.store, key)
    end

    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: String.duplicate("0", 40)})
    assert {:error, :ticket_jira_binding_changed} = TicketJiraJournal.reconcile(ctx.store, key, observed)
    assert {:error, :ticket_jira_binding_changed} = TicketJiraJournal.claim(ctx.store, key)
  end

  test "start operation has fixed transition then label delta and completion changes no run state", ctx do
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER", candidate_sha: nil, mr_url: nil})
    assert {:error, :ticket_jira_first_effect_invalid} = TicketJiraJournal.prepare(ctx.store, "run", "START_IMPLEMENTATION", "guessed", ctx.checkout)
    assert {:ok, row} = TicketJiraJournal.prepare(ctx.store, "run", "START_IMPLEMENTATION", "11", ctx.checkout)
    assert row["operation_key"] == "ticket-jira:d13c38d3939d61de7da47885e06a2563d4c1e5972356e618bf4d46336cd61aec"

    assert Jason.decode!(row["effects_json"]) == [
             %{"kind" => "TRANSITION", "issue_key" => "PPL-123", "transition_id" => "11", "status" => "In Dev"},
             %{"kind" => "LABELS", "issue_key" => "PPL-123", "add_labels" => ["ai-running"], "remove_labels" => ~w(ai-ready ai-verifying)}
           ]

    invalid = row["effects_json"] |> Jason.decode!() |> put_in([Access.at(0), "transition_id"], "0") |> Jason.encode!()
    digest = Base.encode16(:crypto.hash(:sha256, invalid), case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET effects_json = ?, effects_sha256 = ? WHERE operation_key = ?", [invalid, digest, row["operation_key"]])
    assert {:error, :ticket_jira_receipt_corrupt} = TicketJiraJournal.claim(ctx.store, row["operation_key"])
    assert {:ok, rejected} = TicketJiraJournal.get(ctx.store, row["operation_key"])
    assert rejected["phase"] == "FIRST_PENDING"
    assert is_nil(rejected["first_receipt_json"])
    Store.query!(ctx.store, "UPDATE ticket_jira_effects SET effects_json = ?, effects_sha256 = ? WHERE operation_key = ?", [row["effects_json"], row["effects_sha256"], row["operation_key"]])

    assert {:ok, %{"phase" => "SECOND_PENDING"}} = TicketJiraJournal.reconcile(ctx.store, row["operation_key"], observation(%{"status" => "In Dev"}))
    assert {:ok, %{"phase" => "COMPLETE"}} = TicketJiraJournal.reconcile(ctx.store, row["operation_key"], observation(%{"labels" => ["ai-running", "human-label"]}))
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  defp prepare(ctx), do: TicketJiraJournal.prepare(ctx.store, "run", "REVIEW_READY", ctx.body, ctx.checkout)
  defp observation(issue), do: %{"source" => "Jira/get_issue", "observed_at" => DateTime.to_iso8601(DateTime.utc_now()), "issue" => Map.put(issue, "key", "PPL-123")}
end
