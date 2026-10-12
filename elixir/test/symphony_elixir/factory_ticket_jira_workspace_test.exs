defmodule SymphonyElixir.FactoryTicketJiraWorkspaceTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{Capacity, Control, DesktopRequest, RunLedger, Store, TaskLedger}
  alias SymphonyElixir.Factory.{TicketJiraJournal, TicketWorkerRunner, WorkspaceAccess}

  setup context do
    ctx = setup_fixture(context)
    bind_parent(ctx)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "COMPLETE"})
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER", candidate_sha: nil})
    Store.query!(ctx.store, "INSERT INTO ticket_review_bases VALUES ('run', 'master', ?, ?)", [ctx.sha, DateTime.to_iso8601(DateTime.utc_now())])
    options = opts(ctx) ++ [workspace_root: Path.join(ctx.root, "workspaces")]
    {:ok, snapshot} = Jason.decode(run["snapshot_json"])
    snapshot = Map.merge(snapshot, %{"labels" => ~w(ai-ready repo-grail), "status" => "To Do"})
    {:ok, authorization} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())
    Map.merge(ctx, %{run: run, options: options, authorization: authorization})
  end

  test "facts do not authorize a writer, and a held baseline maintenance reservation consumes its disk budget", ctx do
    before = ledger(ctx)
    assert {:ok, %{run: run, checkout: checkout, expected_sha: sha}} = TicketWorkerRunner.writer_admission_facts(ctx.store, ctx.run, ctx.options)
    assert run == ctx.run and sha == ctx.sha and checkout.path == ctx.path
    assert ledger(ctx) == before
    assert {:error, :ticket_authorization_required} = TicketWorkerRunner.admit_writer(ctx.store, ctx.run, nil, ctx.options)
    assert {:error, :ticket_authorization_expired} = TicketWorkerRunner.admit_writer(ctx.store, ctx.run, Map.put(ctx.authorization, "observed_at", "2020-01-01T00:00:00Z"), ctx.options)
    assert ledger(ctx) == before
    {:ok, journal} = prepare(ctx, checkout)
    key = journal["operation_key"]
    assert {:ok, access} = WorkspaceAccess.acquire(ctx.store, maintenance(ctx, key))
    assert {:ok, capacity} = Capacity.snapshot(ctx.store, ctx.options[:capacity_policy], "grail", free_bytes: 21_000_000_000)
    assert capacity.available_writer_slots == 0
    owned_opts = Keyword.put(ctx.options, :reservation, %{key: key, generation: access["generation"]})
    assert {:ok, %{run: ^run}} = TicketWorkerRunner.writer_admission_facts(ctx.store, ctx.run, owned_opts)
    assert {:error, :workspace_busy} = TicketWorkerRunner.admit_writer(ctx.store, ctx.run, ctx.authorization, owned_opts)
    assert {:error, :workspace_busy} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "REVIEW", "competing"), ctx.options)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  test "held initial maintenance keeps its budget across failed and cancelled run states", ctx do
    {:ok, access} = WorkspaceAccess.acquire(ctx.store, maintenance(ctx, "initial-hold"))
    assert Jason.decode!(access["binding_json"])["run_state"] == "ADMITTING_WRITER"

    for state <- ~w(FAILED CANCELLED) do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{state: state})
      assert {:ok, capacity} = Capacity.snapshot(ctx.store, ctx.options[:capacity_policy], "grail", free_bytes: 21_000_000_000)
      assert capacity.active_writers == 1 and capacity.available_writer_slots == 0
    end

    Store.query!(ctx.store, "UPDATE workspace_access SET binding_json = 'malformed' WHERE reservation_key = 'initial-hold'")
    assert {:ok, capacity} = Capacity.snapshot(ctx.store, ctx.options[:capacity_policy], "grail", free_bytes: 21_000_000_000)
    assert capacity.active_writers == 1 and capacity.available_writer_slots == 0
  end

  test "uncertain restart and partial Jira completion hold ownership; only exact COMPLETE releases", ctx do
    {:ok, facts} = TicketWorkerRunner.writer_admission_facts(ctx.store, ctx.run, ctx.options)
    {:ok, journal} = prepare(ctx, facts.checkout)
    key = journal["operation_key"]
    {:ok, access} = WorkspaceAccess.acquire(ctx.store, maintenance(ctx, key))
    assert not DesktopRequest.controller_busy?(ctx.store, "scope")
    assert {:ok, _} = TicketJiraJournal.claim(ctx.store, key)
    assert DesktopRequest.controller_busy?(ctx.store, "scope")
    assert not DesktopRequest.controller_busy?(ctx.store, "other-scope")
    assert {:error, :jira_workspace_completion_unproven} = WorkspaceAccess.release_jira(ctx.store, "run", key, access["generation"])
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^access} = WorkspaceAccess.validate(reopened, key, access["generation"])
      assert {:error, :jira_workspace_completion_unproven} = WorkspaceAccess.release_jira(reopened, "run", key, access["generation"])
      assert {:ok, _} = TicketJiraJournal.reconcile(reopened, key, observation(%{"status" => "In Dev"}))
      assert {:error, :jira_workspace_completion_unproven} = WorkspaceAccess.release_jira(reopened, "run", key, access["generation"])
      assert {:ok, _} = TicketJiraJournal.reconcile(reopened, key, observation(%{"labels" => ~w(ai-running repo-grail)}))
      assert DesktopRequest.controller_busy?(reopened, "scope")
      assert {:error, :stale_workspace_reservation} = WorkspaceAccess.release_jira(reopened, "run", key, access["generation"] + 1)
      assert {:error, :jira_workspace_completion_unproven} = WorkspaceAccess.release_jira(reopened, "other-run", key, access["generation"])
      assert {:ok, released} = WorkspaceAccess.release_jira(reopened, "run", key, access["generation"])
      assert not DesktopRequest.controller_busy?(reopened, "scope")
      assert is_binary(released["released_at"])
      assert {:ok, ^released} = WorkspaceAccess.release_jira(reopened, "run", key, access["generation"])
      assert Jason.decode!(released["release_receipt_json"])["operation_key"] == key
      Store.query!(reopened, "UPDATE workspace_access SET release_receipt_json = '{}' WHERE reservation_key = ?", [key])
      assert DesktopRequest.controller_busy?(reopened, "scope")
      Store.query!(reopened, "UPDATE workspace_access SET release_receipt_json = ? WHERE reservation_key = ?", [released["release_receipt_json"], key])
      assert {:ok, current} = RunLedger.get(reopened, "run")
      assert current == ctx.run
      result = TicketWorkerRunner.admit_writer(reopened, current, ctx.authorization, ctx.options)
      assert {:ok, %{run: admitted}} = result
      assert admitted["state"] == "WRITING"
    after
      GenServer.stop(reopened)
    end
  end

  test "unproven initial bases and changed gates never qualify baseline maintenance", ctx do
    attrs = maintenance(ctx, "initial")
    assert {:error, _} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs, "expected_sha", String.duplicate("0", 40)))
    Store.query!(ctx.store, "DELETE FROM ticket_review_bases WHERE run_id = 'run'")
    assert {:error, :workspace_candidate_binding_mismatch} = WorkspaceAccess.acquire(ctx.store, attrs)
    Store.query!(ctx.store, "INSERT INTO ticket_review_bases VALUES ('run', 'master', ?, ?)", [ctx.sha, DateTime.to_iso8601(DateTime.utc_now())])

    for {column, value} <- [{"state", "PLANNING"}, {"execution_mode", "legacy"}, {"manual_validation_required", 1}] do
      Store.query!(ctx.store, "UPDATE runs SET state = 'ADMITTING_WRITER', execution_mode = 'TICKET_SUPERVISOR_V1', manual_validation_required = 0 WHERE run_id = 'run'")
      Store.query!(ctx.store, "UPDATE runs SET #{column} = ? WHERE run_id = 'run'", [value])
      assert {:error, :workspace_candidate_binding_mismatch} = WorkspaceAccess.acquire(ctx.store, attrs)
    end
  end

  test "issued Jira uncertainty rejects controller claims even when its ownership is missing", ctx do
    Control.initialize(ctx.store, %{scope: "scope", dispatcher_id: "fixture-dispatcher"})
    {:ok, facts} = TicketWorkerRunner.writer_admission_facts(ctx.store, ctx.run, ctx.options)
    {:ok, journal} = prepare(ctx, facts.checkout)
    key = journal["operation_key"]
    {:ok, _access} = WorkspaceAccess.acquire(ctx.store, maintenance(ctx, key))

    {:ok, request} =
      DesktopRequest.enqueue(ctx.store, %{
        request_key: "competing-controller",
        target_kind: "CONTROLLER",
        target_key: "scope",
        action: "CREATE",
        codex_project_id: "project-grail",
        model: "gpt-6-luna",
        reasoning_effort: "low",
        title: "Fixture",
        prompt: "Fixture",
        cwd: ctx.root
      })

    assert {:ok, _} = TicketJiraJournal.claim(ctx.store, key)
    assert TicketJiraJournal.controller_busy?(ctx.store, "scope")
    assert not TicketJiraJournal.controller_busy?(ctx.store, "other-scope")
    assert not TicketJiraJournal.controller_busy?(ctx.store, "scope", key)
    expected = {:error, :controller_jira_reconciliation_required}
    assert DesktopRequest.authorize_issuance(ctx.store, request, []) == expected
    assert DesktopRequest.claim(ctx.store, request["request_key"]) == expected

    for mode <- ["LEGACY", nil] do
      Store.query!(ctx.store, "UPDATE runs SET execution_mode = ? WHERE run_id = 'run'", [mode])
      assert TicketJiraJournal.controller_busy?(ctx.store, "scope")
      assert DesktopRequest.claim(ctx.store, request["request_key"]) == expected
    end

    Store.query!(ctx.store, "UPDATE runs SET execution_mode = 'TICKET_SUPERVISOR_V1' WHERE run_id = 'run'")
    Store.query!(ctx.store, "UPDATE workspace_access SET reservation_key = 'fixture-hidden-ownership' WHERE reservation_key = ?", [key])
    assert TicketJiraJournal.controller_busy?(ctx.store, "scope")
    assert DesktopRequest.claim(ctx.store, request["request_key"]) == expected
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, request["request_key"])
  end

  test "changing the pinned base or checkout invalidates held maintenance, and release rolls back with finalization", ctx do
    {:ok, facts} = TicketWorkerRunner.writer_admission_facts(ctx.store, ctx.run, ctx.options)
    {:ok, journal} = prepare(ctx, facts.checkout)
    key = journal["operation_key"]
    {:ok, access} = WorkspaceAccess.acquire(ctx.store, maintenance(ctx, key))
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha = ? WHERE run_id = 'run'", [String.duplicate("0", 40)])
    assert {:error, :workspace_candidate_binding_mismatch} = WorkspaceAccess.validate(ctx.store, key, access["generation"])
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha = ? WHERE run_id = 'run'", [ctx.sha])
    {:ok, _} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"status" => "In Dev"}))
    {:ok, _} = TicketJiraJournal.reconcile(ctx.store, key, observation(%{"labels" => ["ai-running"]}))

    assert {:error, :simulate_crash} =
             Exqlite.transaction(ctx.store, fn tx ->
               assert {:ok, _} = WorkspaceAccess.release_jira(tx, "run", key, access["generation"])
               Exqlite.rollback(tx, :simulate_crash)
             end)

    assert {:ok, ^access} = WorkspaceAccess.get(ctx.store, key)
    File.write!(Path.join(ctx.path, "untracked.txt"), "do not discard\n")
    assert {:error, _} = WorkspaceAccess.release_jira(ctx.store, "run", key, access["generation"])
    assert {:ok, ^access} = WorkspaceAccess.get(ctx.store, key)
  end

  defp prepare(ctx, checkout), do: TicketJiraJournal.prepare(ctx.store, "run", "START_IMPLEMENTATION", "11", Map.new(checkout, fn {key, value} -> {Atom.to_string(key), value} end))

  defp maintenance(ctx, key),
    do: %{"reservation_key" => key, "run_id" => "run", "task_key" => nil, "request_key" => key, "mode" => "MAINTENANCE", "allowed_root" => Path.join(ctx.root, "workspaces"), "expected_sha" => ctx.sha}

  defp observation(issue), do: %{"source" => "Jira/get_issue", "observed_at" => DateTime.to_iso8601(DateTime.utc_now()), "issue" => Map.put(issue, "key", "PPL-123")}
  defp ledger(ctx), do: Enum.map(~w(runs factory_tasks workspace_access worker_evidence events), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
end
