defmodule SymphonyElixir.FactoryNativeWorkspaceMaintenanceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{
    DesktopRequest,
    ModelRouter,
    NativeWorkspaceMaintenance,
    NativeWorktreeProbe,
    RunLedger,
    Store,
    TaskLedger
  }

  setup do
    root = Path.join(System.tmp_dir!(), "native-maintenance-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    path = Path.join(root, "writer")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "master"])
    git!(repo, ["config", "user.email", "factory@example.test"])
    git!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "--no-verify", "-m", "base"])
    git!(repo, ["worktree", "add", "-b", "cgable/PPL-123", path])
    sha = String.trim(git!(path, ["rev-parse", "HEAD"]))
    {:ok, path} = SymphonyElixir.PathSafety.canonicalize(path)
    {:ok, repo} = SymphonyElixir.PathSafety.canonicalize(repo)
    database = Path.join(root, "factory.sqlite")
    {:ok, store} = Store.start_link(database: database)

    {:ok, %{run: run}} =
      RunLedger.register(store, %{
        run_id: "run",
        issue_key: "PPL-123",
        kind: "DELIVERY",
        state: "READY_FOR_REVIEW",
        factory_owned: false,
        workspace_state: "CODEX_NATIVE",
        worktree: path,
        candidate_sha: sha,
        branch: "cgable/PPL-123",
        base_branch: "master",
        repo_path: repo
      })

    {:ok, _writer} =
      TaskLedger.register(store, %{
        task_key: "run:feature-writer",
        run_id: "run",
        stage: "WRITING",
        role: "feature-writer",
        status: "CONSUMED",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        routing_reason: "test",
        prompt_sha256: String.duplicate("b", 64),
        codex_project_id: "project",
        thread_id: "writer-thread",
        workspace: path,
        workspace_sha: sha
      })

    {:ok, writer} = TaskLedger.update(store, "run:feature-writer", %{turn_id: "writer-turn"})
    {:ok, probe} = NativeWorktreeProbe.enqueue(store, "run")
    Store.query!(store, "DELETE FROM desktop_requests WHERE request_key = ?", [probe["request_key"]])

    Store.query!(
      store,
      """
      INSERT INTO desktop_requests(request_key, target_kind, target_key, action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, thread_id, verified_project_id, verified_cwd,
        title, prompt, schema_json, cwd, metadata_json, created_at, updated_at)
      VALUES ('source-create', 'TASK', 'run:feature-writer', 'CREATE', 'SUCCEEDED', ?, 'project',
        'gpt-6.1-sol', 'high', 'writer-thread', 'project', ?, 'source', 'source', '{}', ?,
        '{"workspace_mode":"CODEX_NATIVE"}', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
      """,
      [String.duplicate("c", 64), path, path]
    )

    factory = %{cleanup: %{"native" => %{"enabled" => true}}, models: %{"default_provider" => "codex", "providers" => %{"codex" => %{"fast" => "gpt-6-luna"}}}}
    on_exit(fn -> File.rm_rf(root) end)

    %{
      store: store,
      database: database,
      root: root,
      repo: repo,
      path: path,
      sha: sha,
      writer: writer,
      run: run,
      factory: factory
    }
  end

  test "default disabled and dry-run never enqueue or write lifecycle state", c do
    for cleanup <- [%{}, %{"native" => %{"enabled" => false}}] do
      factory = struct!(SymphonyElixir.Config.Schema.Factory, cleanup: cleanup)
      refute NativeWorkspaceMaintenance.enabled?(factory)
      assert {:ok, :disabled} = NativeWorkspaceMaintenance.reconcile(c.store, factory)
    end

    enabled_factory = struct!(SymphonyElixir.Config.Schema.Factory, cleanup: %{"native" => %{"enabled" => true}})
    assert NativeWorkspaceMaintenance.enabled?(enabled_factory)
    assert {:ok, :disabled} = NativeWorkspaceMaintenance.reconcile(c.store, %{cleanup: %{}})
    assert [%{eligible: true}] = NativeWorkspaceMaintenance.plan(c.store)
    assert NativeWorkspaceMaintenance.snapshot(c.store) == []
    assert :ok = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert :ok = NativeWorkspaceMaintenance.ensure_available(c.store, "missing-run")
    assert NativeWorkspaceMaintenance.snapshot(c.store) == []
    assert Store.one!(c.store, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 1
  end

  test "a V1 issue owner freezes legacy native-workspace maintenance records", c do
    assert {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    before_records = Store.query!(c.store, "SELECT * FROM native_workspace_maintenance ORDER BY run_id").rows
    before_requests = Store.query!(c.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows

    assert {:ok, _v1} =
             RunLedger.register(c.store, %{
               run_id: "newer-supervisor",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "READY_FOR_REVIEW",
               execution_mode: "TICKET_SUPERVISOR_V1"
             })

    assert {:ok, :no_candidate} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert Store.query!(c.store, "SELECT * FROM native_workspace_maintenance ORDER BY run_id").rows == before_records
    assert Store.query!(c.store, "SELECT * FROM desktop_requests ORDER BY request_key").rows == before_requests
    assert NativeWorkspaceMaintenance.plan(c.store) == []
    assert record["phase"] == "PROBING"
  end

  test "maintenance role inherits configured fast model at low effort without changing writer", c do
    assert {:ok, route} = ModelRouter.resolve(c.factory.models, "workspace-maintainer")
    assert route.model == "gpt-6-luna"
    assert route.reasoning_effort == "low"
    assert {:ok, %{"phase" => "PROBING", "generation" => 1} = record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert {:ok, request} = DesktopRequest.get(c.store, record["request_key"])
    assert request["model"] == "gpt-6-luna"
    assert request["reasoning_effort"] == "low"
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    assert RunLedger.get(c.store, "run") == {:ok, c.run}
    assert {:error, :native_workspace_maintenance_reserved} = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert {:ok, :waiting} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert length(NativeWorkspaceMaintenance.snapshot(c.store)) == 1
  end

  test "unavailable immutable receipt releases reservation and never wakes same binding again", c do
    assert {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "UNAVAILABLE", nil)
    assert {:ok, %{phase: "AVAILABLE", reason: "managed_attachment_unavailable"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert :ok = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert {:ok, :no_candidate} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert {:ok, :no_candidate} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert Store.one!(c.store, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 2
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
  end

  test "supported probe cannot grant permission or advance archival", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "SUPPORTED", c.path)
    assert {:ok, %{phase: "AVAILABLE", reason: "archive_restore_capability_not_proven"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert File.dir?(c.path)
    assert NativeWorkspaceMaintenance.snapshot(c.store) |> hd() |> Map.fetch!("authorization_at") == nil
  end

  test "feedback arriving during a read-only probe cannot hold the writer reservation", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)

    Store.query!(
      c.store,
      """
      INSERT INTO mr_feedback_notes(feedback_key,run_id,project,mr_iid,discussion_id,note_id,note_updated_at,
      body_sha256,author_id,status,created_at,updated_at)
      VALUES ('feedback','run','project',1,'discussion',1,'now','body',1,'PENDING','now','now')
      """,
      []
    )

    complete_probe(c, record, "UNAVAILABLE", nil)
    assert {:ok, %{phase: "AVAILABLE"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert :ok = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert [%{reason: :run_has_active_work}] = NativeWorkspaceMaintenance.plan(c.store)
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
  end

  test "missing immutable evidence and changed binding require reconciliation", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "UNAVAILABLE", nil)
    Store.query!(c.store, "DELETE FROM events WHERE event_type = 'NATIVE_MAINTENANCE_TARGET_EVIDENCE'")
    assert {:ok, %{phase: "RECONCILE_REQUIRED", reason: "probe_binding_or_evidence_changed"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    assert {:ok, %{phase: "RECONCILE_REQUIRED"}} = NativeWorkspaceMaintenance.reconcile(c.store, %{cleanup: %{}})
  end

  test "reservations survive restart and disabled config still reconciles registered probes", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "AMBIGUOUS", nil)
    GenServer.stop(c.store)
    {:ok, store} = Store.start_link(database: c.database)
    assert {:error, :native_workspace_maintenance_reserved} = NativeWorkspaceMaintenance.ensure_available(store, "run")
    assert {:ok, %{phase: "AVAILABLE", reason: "managed_attachment_ambiguous"}} = NativeWorkspaceMaintenance.reconcile(store, %{cleanup: %{}})
    assert TaskLedger.get(store, c.writer["task_key"]) == {:ok, c.writer}
  end

  test "missing creation, stale writer, active task and pending feedback fail admission", c do
    Store.query!(c.store, "DELETE FROM desktop_requests WHERE request_key = 'source-create'")
    assert [%{eligible: false, reason: :native_creation_provenance_missing}] = NativeWorkspaceMaintenance.plan(c.store)
    {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{workspace_sha: String.duplicate("a", 40)})
    assert [%{eligible: false, reason: :writer_binding_stale}] = NativeWorkspaceMaintenance.plan(c.store)
    {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{workspace_sha: c.sha, status: "RUNNING"})
    assert [%{eligible: false, reason: :writer_not_terminal}] = NativeWorkspaceMaintenance.plan(c.store)
    assert {:ok, :no_candidate} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
  end

  test "changed candidate and unresolved requests prevent probe admission", c do
    {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{turn_id: nil})
    assert [%{reason: :writer_identity_incomplete}] = NativeWorkspaceMaintenance.plan(c.store)
    {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{turn_id: "writer-turn"})
    {:ok, _} = NativeWorktreeProbe.enqueue(c.store, "run")
    assert [%{reason: :run_has_active_work}] = NativeWorkspaceMaintenance.plan(c.store)
  end

  test "failed or missing probe is not automatically reissued", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    Store.query!(c.store, "UPDATE desktop_requests SET status = 'FAILED' WHERE request_key = ?", [record["request_key"]])
    assert {:ok, %{reason: "probe_requires_reconciliation"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    Store.query!(c.store, "UPDATE native_workspace_maintenance SET phase = 'PROBING'")
    Store.query!(c.store, "DELETE FROM desktop_requests WHERE request_key = ?", [record["request_key"]])
    assert {:ok, %{reason: "probe_request_missing"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
  end

  test "broker recovery of the same probe releases a parked reservation even when disabled", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    Store.query!(c.store, "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED' WHERE request_key = ?", [record["request_key"]])
    assert {:ok, %{phase: "RECONCILE_REQUIRED"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "UNAVAILABLE", nil)
    assert {:ok, %{phase: "AVAILABLE"}} = NativeWorkspaceMaintenance.reconcile(c.store, %{cleanup: %{}})
    assert :ok = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert Store.one!(c.store, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 2
  end

  test "invalid receipt requires reconciliation and archived workspace is not available", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "INVALID", nil)
    assert {:ok, %{reason: "invalid_probe_receipt"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    Store.query!(c.store, "UPDATE native_workspace_maintenance SET phase = 'ARCHIVED'")
    assert {:error, :native_workspace_maintenance_reserved} = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert {:ok, :no_candidate} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
  end

  test "changed source turn admits a new generation only after completed prior probe", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "UNAVAILABLE", nil)
    assert {:ok, %{phase: "AVAILABLE"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{turn_id: "new-source-turn"})
    assert {:ok, %{"generation" => 2}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
  end

  test "route cannot silently move maintenance to expensive model", c do
    role = %{"model_class" => "standard", "reasoning_effort" => "high"}
    models = Map.put(c.factory.models, "roles", %{"workspace-maintainer" => role})
    models = put_in(models, ["providers", "codex", "standard"], "gpt-6.1-sol")
    result = NativeWorkspaceMaintenance.reconcile(c.store, %{c.factory | models: models})
    assert {:error, :maintenance_requires_fast_low_route} = result
    assert NativeWorkspaceMaintenance.snapshot(c.store) == []
  end

  test "missing model and missing writer leave lifecycle untouched", c do
    assert {:error, _} = NativeWorkspaceMaintenance.reconcile(c.store, %{c.factory | models: %{}})
    Store.query!(c.store, "DELETE FROM desktop_requests")
    Store.query!(c.store, "DELETE FROM factory_tasks")
    assert [%{reason: :unknown_task}] = NativeWorkspaceMaintenance.plan(c.store)
    assert NativeWorkspaceMaintenance.snapshot(c.store) == []
  end

  test "invalid configured model cannot enqueue a partial probe or reserve writer", c do
    models = put_in(c.factory.models, ["providers", "codex", "fast"], "")
    assert {:error, _reason} = NativeWorkspaceMaintenance.reconcile(c.store, %{c.factory | models: models})
    assert NativeWorkspaceMaintenance.snapshot(c.store) == []
    assert :ok = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
    assert {:error, :maintenance_requires_fast_low_route} = NativeWorktreeProbe.enqueue(c.store, "run", %{})
  end

  test "unknown future destructive phase cannot be consumed as a read-only probe", c do
    {:ok, record} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
    complete_probe(c, record, "UNAVAILABLE", nil)
    Store.query!(c.store, "UPDATE native_workspace_maintenance SET phase = 'ARCHIVE_PENDING'")
    assert {:ok, :reconciliation_required} = NativeWorkspaceMaintenance.reconcile(c.store, %{cleanup: %{}})
    assert {:error, :native_workspace_maintenance_reserved} = NativeWorkspaceMaintenance.ensure_available(c.store, "run")
  end

  test "rejected candidate cannot starve a valid candidate", c do
    attrs = %{
      run_id: "a-invalid",
      issue_key: "PPL-124",
      kind: "DELIVERY",
      state: "READY_FOR_REVIEW",
      factory_owned: false,
      workspace_state: "CODEX_NATIVE"
    }

    {:ok, _} = RunLedger.register(c.store, attrs)
    assert {:ok, %{"run_id" => "run"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
  end

  test "completed legacy probe route conflict is remembered without starving another candidate", c do
    {:ok, legacy} = NativeWorktreeProbe.enqueue(c.store, "run")
    Store.query!(c.store, "UPDATE desktop_requests SET status = 'SUCCEEDED', output_json = '{}' WHERE request_key = ?", [legacy["request_key"]])
    {:ok, legacy_completed} = DesktopRequest.get(c.store, legacy["request_key"])
    path = Path.join(c.root, "second-writer")
    git!(c.repo, ["worktree", "add", "-b", "cgable/PPL-124", path])
    {:ok, path} = SymphonyElixir.PathSafety.canonicalize(path)

    {:ok, _} =
      RunLedger.register(c.store, %{
        run_id: "second",
        issue_key: "PPL-124",
        kind: "DELIVERY",
        state: "READY_FOR_REVIEW",
        factory_owned: false,
        workspace_state: "CODEX_NATIVE",
        worktree: path,
        candidate_sha: c.sha,
        branch: "cgable/PPL-124",
        base_branch: "master",
        repo_path: c.repo
      })

    {:ok, _} = TaskLedger.register(c.store, Map.merge(c.writer, %{"task_key" => "second:feature-writer", "run_id" => "second", "workspace" => path, "thread_id" => "second-thread"}))
    {:ok, _} = TaskLedger.update(c.store, "second:feature-writer", %{turn_id: "second-turn"})

    Store.query!(
      c.store,
      """
      INSERT INTO desktop_requests(request_key, target_kind, target_key, action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, thread_id, verified_project_id, verified_cwd,
        title, prompt, schema_json, cwd, metadata_json, created_at, updated_at)
      SELECT 'second-create', target_kind, 'second:feature-writer', action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, 'second-thread', verified_project_id, ?,
        title, prompt, schema_json, ?, metadata_json, created_at, updated_at FROM desktop_requests WHERE request_key = 'source-create'
      """,
      [path, path]
    )

    assert {:ok, %{"run_id" => "second"}} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)

    assert %{"phase" => "AVAILABLE", "last_error" => "existing_probe_route_conflict_unverified"} =
             Store.one!(c.store, "SELECT * FROM native_workspace_maintenance WHERE run_id = 'run'")

    assert {:ok, ^legacy_completed} = DesktopRequest.get(c.store, legacy["request_key"])

    assert {:ok, :waiting} = NativeWorkspaceMaintenance.reconcile(c.store, c.factory)
  end

  defp complete_probe(c, record, status, identity) do
    receipt = %{"status" => status, "run_id" => "run", "candidate_sha" => c.sha, "artifact_identity_key" => identity}
    Store.query!(c.store, "UPDATE desktop_requests SET status = 'SUCCEEDED', output_json = ? WHERE request_key = ?", [Jason.encode!(%{"result" => receipt}), record["request_key"]])

    Store.query!(c.store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,?,?,?)", [
      DateTime.to_iso8601(DateTime.utc_now()),
      "NATIVE_MAINTENANCE_TARGET_EVIDENCE",
      "run",
      Jason.encode!(%{"request_key" => record["request_key"]})
    ])
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
