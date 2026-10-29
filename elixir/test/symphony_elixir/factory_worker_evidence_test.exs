defmodule SymphonyElixir.FactoryWorkerEvidenceTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, StageSchemas, Store, TaskLauncher, TaskLedger, TicketContext}
  alias SymphonyElixir.Factory.{TicketWorkerRunner, WorkerEvidence, WorkspaceAccess}
  alias SymphonyElixir.Tracker.Issue
  setup :setup_fixture

  defp reserve(ctx, mode \\ "SOURCE", extra \\ %{}) do
    if mode == "REVIEW", do: TaskLedger.update(ctx.store, "writer", %{role: "change-verifier"})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, mode), opts(ctx))

    attrs = %{
      "request_key" => "reservation:request",
      "task_key" => "writer",
      "reservation_key" => "reservation",
      "input_sha256" => TaskLedger.get(ctx.store, "writer") |> elem(1) |> Map.fetch!("prompt_sha256"),
      "owner_id" => "owned-invocation",
      "schema" => %{"type" => "object", "required" => ["status"], "properties" => %{"status" => %{"type" => "string"}}},
      "policy" => TicketWorkerRunner.policy(mode, ctx.path)
    }

    attrs = Map.merge(attrs, extra)
    {:ok, evidence} = WorkerEvidence.reserve(ctx.store, attrs)
    {attrs, evidence}
  end

  @tag :native_worker_binding
  test "routed reservation persists its origin once and an existing destination replays exact bytes", ctx do
    route = private_origin_route(ctx, "first")
    {:ok, origin} = SymphonyElixir.Factory.NativeRuntimeRoute.origin(route)
    {attrs, evidence} = reserve(ctx, "SOURCE", %{"native_runtime" => route})
    binding = Jason.decode!(evidence["binding_json"])
    assert binding["binding_version"] === 2
    assert binding["native_runtime"] === origin
    assert {:ok, ^evidence} = WorkerEvidence.reserve(ctx.store, attrs)
    assert {:ok, ^evidence} = WorkerEvidence.reserve(ctx.store, Map.delete(attrs, "native_runtime"))
    conflict = private_origin_route(ctx, "other")
    assert {:error, :worker_native_runtime_conflict} = WorkerEvidence.reserve(ctx.store, Map.put(attrs, "native_runtime", conflict))
    assert {:ok, ^evidence} = WorkerEvidence.get(ctx.store, evidence["request_key"])
    File.rename!(route.sqlite_home.path, route.sqlite_home.path <> "-original")
    File.mkdir!(route.sqlite_home.path)
    File.chmod!(route.sqlite_home.path, 0o700)
    assert {:error, :native_runtime_storage_changed} = WorkerEvidence.mark_start_sent(ctx.store, evidence["request_key"])
    assert {:ok, ^evidence} = WorkerEvidence.get(ctx.store, evidence["request_key"])
  end

  @tag :native_worker_binding
  test "ordinary successful V2 work records its result without a native recovery receipt or event", ctx do
    route = private_origin_route(ctx, "ordinary")
    {attrs, evidence} = reserve(ctx, "SOURCE", %{"native_runtime" => route})
    key = evidence["request_key"]
    assert {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, key)
    assert {:ok, _} = WorkerEvidence.bind_thread(ctx.store, key, "worker", attrs["policy"])
    assert {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, key, process_receipt())
    assert {:ok, _} = WorkerEvidence.bind_turn(ctx.store, key, "worker", "turn")
    assert {:ok, recorded} = WorkerEvidence.record_result(ctx.store, key, %{thread_id: "worker", turn_id: "turn", item_id: "final", output: %{"status" => "PASS"}})
    assert recorded["status"] == "RESULT_RECORDED"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'")["n"] == 0
  end

  @tag :native_worker_binding
  test "one binding resolver owns history queue locks and workspace without accepting independent overrides", ctx do
    route = private_origin_route(ctx, "namespace")
    {_attrs, evidence} = reserve(ctx, "SOURCE", %{"native_runtime" => route})
    binding = Jason.decode!(evidence["binding_json"])
    assert {:ok, options} = WorkerEvidence.runtime_options(binding)
    assert options[:native_runtime] === route
    assert options[:native_home] == route.codex_home.path
    assert options[:native_queue_database] == Path.join(route.sqlite_home.path, "queue_1.sqlite")
    assert options[:native_history] == Path.join(route.sqlite_home.path, "thread_history_1.sqlite")
    assert options[:workspace] == ctx.path

    for key <- [:native_home, :native_queue_database, :native_history, :workspace] do
      assert {:error, :worker_native_runtime_conflict} = WorkerEvidence.runtime_options(binding, [{key, ctx.repo}])
    end

    assert {:ok, %{}} = WorkerEvidence.inherit_runtime(%{}, %{})
    assert {:error, :worker_native_runtime_conflict} = WorkerEvidence.inherit_runtime(%{"native_runtime" => route}, %{})
    assert {:ok, %{"native_runtime" => ^route}} = WorkerEvidence.inherit_runtime(%{}, binding)

    for malformed <- [
          %{"binding_version" => 2},
          %{"native_runtime" => binding["native_runtime"]},
          %{binding | "binding_version" => 1},
          %{binding | "binding_version" => 3},
          %{binding | "binding_version" => true},
          %{binding | "binding_version" => "2"},
          %{binding | "binding_version" => 2.0},
          %{binding | "native_runtime" => nil}
        ] do
      assert {:error, :worker_native_runtime_unproven} = WorkerEvidence.runtime_options(malformed)
    end
  end

  @tag :native_worker_binding
  test "legacy absence remains byte-stable and caller versions null or serialized routes cannot create authority", ctx do
    {attrs, original} = reserve(ctx)
    original_rows = Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY request_key").rows
    binding = Jason.decode!(original["binding_json"])
    refute Map.has_key?(binding, "binding_version")
    refute Map.has_key?(binding, "native_runtime")
    assert {:ok, ^original} = WorkerEvidence.reserve(ctx.store, attrs)
    assert {:ok, ^attrs} = WorkerEvidence.inherit_runtime(attrs, binding)
    assert WorkerEvidence.runtime_matches?(binding, %{})

    for extra <- [%{"binding_version" => 2}, %{"unknown" => true}] do
      assert {:error, :invalid_worker_attempt} = WorkerEvidence.reserve(ctx.store, Map.merge(attrs, extra))
    end

    for value <- [nil, false, %{"version" => 1, "codex_home" => ctx.root, "sqlite_home" => ctx.root}] do
      assert {:error, :worker_native_runtime_conflict} = WorkerEvidence.reserve(ctx.store, Map.put(attrs, "native_runtime", value))
      fresh = attrs |> Map.put("request_key", "fresh:request") |> Map.put("native_runtime", value)
      assert {:error, :native_runtime_route_invalid} = WorkerEvidence.reserve(ctx.store, fresh)
    end

    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY request_key").rows == original_rows
  end

  defp private_origin_route(ctx, name) do
    descriptor = %{"version" => 1, "codex_home" => Path.join(ctx.root, name <> "-codex"), "sqlite_home" => Path.join(ctx.root, name <> "-sqlite")}

    for path <- [descriptor["codex_home"], descriptor["sqlite_home"]] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    {:ok, route} = SymphonyElixir.Factory.NativeRuntimeRoute.validate(descriptor)
    route
  end

  defp result(ctx, mode \\ "SOURCE") do
    {attrs, evidence} = reserve(ctx, mode)
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, evidence["request_key"])
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "worker", attrs["policy"])
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, evidence["request_key"], process_receipt())
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "worker", "turn")
    output = if mode == "REVIEW", do: %{"status" => "PASS", "candidate_sha" => ctx.sha}, else: %{"status" => "PASS"}
    observed = %{thread_id: "worker", turn_id: "turn", item_id: "final-item", output: output}
    {:ok, receipt} = WorkerEvidence.record_result(ctx.store, evidence["request_key"], observed)
    {attrs, observed, receipt}
  end

  test "a bound session stopped before a turn retains only its genuine shutdown", ctx do
    {attrs, evidence} = reserve(ctx)
    key = evidence["request_key"]
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, key)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, key, "worker", attrs["policy"])
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, key, process_receipt())
    observed = %{thread_id: "worker", turn_id: nil, policy: attrs["policy"], owner_stop: stop_receipt(ctx)}
    {:ok, before_task} = TaskLedger.get(ctx.store, "writer")
    assert {:ok, failed} = WorkerEvidence.reconcile_required(ctx.store, key, :interrupted_owned_session_preflight_failed, observed)
    assert WorkerEvidence.owner_stopped?(ctx.store, failed)
    assert failed["status"] == "RECONCILE_REQUIRED"
    assert Enum.all?(~w(turn_id item_id output_json output_sha256), &is_nil(failed[&1]))
    assert {:ok, ^failed} = WorkerEvidence.record_failed_stop(ctx.store, key, observed)
    assert {:ok, ^before_task} = TaskLedger.get(ctx.store, "writer")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert {:error, _} = WorkerEvidence.completed_result(ctx.store, key)
    assert {:error, _} = WorkerEvidence.rearm_rejected_resume(ctx.store, key)
    assert {:error, _} = SymphonyElixir.Factory.FailedTurnRecovery.prepare_automatic(ctx.store, key, "invented")
  end

  test "pre-turn shutdown rejects foreign thread, invented turn, policy and receipt identity", ctx do
    {attrs, evidence} = reserve(ctx)
    key = evidence["request_key"]
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, key)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, key, "worker", attrs["policy"])
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, key, process_receipt())
    observed = %{thread_id: "worker", turn_id: nil, policy: attrs["policy"], owner_stop: stop_receipt(ctx)}

    probes =
      [Map.put(observed, :thread_id, "other"), Map.put(observed, :turn_id, "invented"), Map.put(observed, :policy, %{})] ++
        Enum.map([{"pid", "different"}, {"invocation_nonce", String.duplicate("c", 64)}, {"cwd", ctx.root}, {"exit_status", nil}, {"transport", "not_owned"}], fn {field, value} ->
          put_in(observed, [:owner_stop, field], value)
        end)

    for invalid <- probes do
      assert {:ok, failed} = WorkerEvidence.reconcile_required(ctx.store, key, :interrupted_owned_session_preflight_failed, invalid)
      refute WorkerEvidence.owner_stopped?(ctx.store, failed)
      assert is_nil(failed["owner_stop_json"])
      assert {:error, :worker_failed_stop_unproven} = WorkerEvidence.record_failed_stop(ctx.store, key, invalid)
    end
  end

  test "attempt binding replays exactly; starts and thread/turn binding cannot be repeated differently", ctx do
    {attrs, evidence} = reserve(ctx)
    assert {:ok, ^evidence} = WorkerEvidence.reserve(ctx.store, attrs)
    assert {:error, :worker_attempt_conflict} = WorkerEvidence.reserve(ctx.store, Map.put(attrs, "owner_id", "other"))
    assert {:error, :worker_input_digest_mismatch} = WorkerEvidence.reserve(ctx.store, Map.put(attrs, "input_sha256", "other"))
    assert {:error, :worker_thread_conflict} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "worker", attrs["policy"])
    assert {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, evidence["request_key"])
    assert {:error, :worker_start_already_sent} = WorkerEvidence.mark_start_sent(ctx.store, evidence["request_key"])
    assert {:error, :worker_thread_missing} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "", attrs["policy"])
    assert {:error, :worker_effective_policy_mismatch} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "worker", %{})
    assert {:ok, bound} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "worker", attrs["policy"])
    assert {:ok, ^bound} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "worker", attrs["policy"])
    assert {:error, :worker_thread_conflict} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "other", attrs["policy"])
    assert {:error, :worker_event_thread_mismatch} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "other", "turn")
    assert {:error, :worker_event_turn_missing} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "worker", nil)
    assert {:ok, turn} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "worker", "turn")
    assert {:ok, ^turn} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "worker", "turn")
    assert {:error, :worker_event_turn_conflict} = WorkerEvidence.bind_turn(ctx.store, evidence["request_key"], "worker", "other-turn")
  end

  test "missing identity, different output, model, contract and corrupted bindings reject", ctx do
    {attrs, observed, receipt} = result(ctx)
    key = receipt["request_key"]
    assert {:ok, ^receipt} = WorkerEvidence.record_result(ctx.store, key, observed)
    assert {:error, :worker_result_identity_mismatch} = WorkerEvidence.record_result(ctx.store, key, %{observed | turn_id: "foreign"})
    assert {:error, :worker_result_item_missing} = WorkerEvidence.record_result(ctx.store, key, %{observed | item_id: nil})
    assert {:error, :worker_result_conflict} = WorkerEvidence.record_result(ctx.store, key, %{observed | output: %{"status" => "FAIL"}})
    assert {:error, :worker_owner_mismatch} = WorkerEvidence.record_owner_stopped(ctx.store, key, "parent-owner", stop_receipt(ctx))
    assert {:error, :worker_stop_receipt_invalid} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], nil)
    assert {:error, :worker_not_ready_for_consumption} = WorkerEvidence.consume(ctx.store, key)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{model: "changed"})
    assert {:error, :worker_inputs_changed} = WorkerEvidence.record_result(ctx.store, key, observed)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{model: "gpt-6-luna"})
    {:ok, _} = RunLedger.update(ctx.store, "run", %{spec_revision: 2})
    assert {:error, :worker_inputs_changed} = WorkerEvidence.bind_thread(ctx.store, key, "worker", attrs["policy"])
    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = '{}' WHERE request_key = ?", [key])
    assert {:error, :worker_evidence_corrupt} = WorkerEvidence.consume(ctx.store, key)
    assert {:error, :unknown_worker_attempt} = WorkerEvidence.get(ctx.store, "missing")
    assert {:error, :invalid_worker_attempt} = WorkerEvidence.reserve(ctx.store, %{})
    assert {:error, :invalid_worker_attempt} = WorkerEvidence.reserve(ctx.store, "bad")
  end

  test "a post-result commit crash retains ownership until exact controller adoption; consumption is atomic", ctx do
    {attrs, observed, receipt} = result(ctx)
    key = receipt["request_key"]
    {:ok, stopped} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))
    assert {:ok, ^stopped} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))
    assert {:error, :worker_stop_receipt_conflict} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], Map.put(stop_receipt(ctx), "exit_status", 1))
    assert {:error, :worker_adoption_not_proven} = WorkerEvidence.consume(ctx.store, key)
    File.write!(Path.join(ctx.path, "fixture.txt"), "candidate\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "controller adopts slice"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: observed.thread_id, turn_id: observed.turn_id, output_json: Jason.encode!(observed.output)})
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    assert {:error, :worker_candidate_not_adopted} = WorkerEvidence.consume(ctx.store, key)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: ctx.sha})
    assert {:error, :worker_candidate_not_adopted} = WorkerEvidence.consume(ctx.store, key)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    Store.query!(ctx.store, "CREATE TRIGGER fail_release BEFORE UPDATE OF released_at ON workspace_access BEGIN SELECT RAISE(ABORT, 'release failure'); END")
    assert_raise Exqlite.Error, fn -> WorkerEvidence.consume(ctx.store, key) end
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, key)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    Store.query!(ctx.store, "DROP TRIGGER fail_release")
    assert {:ok, consumed} = WorkerEvidence.consume(ctx.store, key)
    assert consumed["status"] == "CONSUMED"
    assert {:ok, ^consumed} = WorkerEvidence.consume(ctx.store, key)
    assert {:ok, %{"released_at" => at}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert is_binary(at)
    assert {:ok, %{"released_at" => ^at}} = WorkspaceAccess.release(ctx.store, "reservation", 1, key)
    assert {:error, :worker_already_consumed} = WorkerEvidence.reconcile_required(ctx.store, key, :timeout)
    assert {:error, :workspace_reservation_already_released} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
  end

  test "completed receipt recovers a lost task result exactly once without releasing the checkout", ctx do
    {attrs, observed, receipt} = result(ctx)
    key = receipt["request_key"]
    assert {:error, :worker_not_ready_for_consumption} = WorkerEvidence.adopt_completed(ctx.store, key)
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "RUNNING", thread_id: observed.thread_id})
    assert {:ok, task} = WorkerEvidence.adopt_completed(ctx.store, key)
    assert task["status"] == "COMPLETE"

    assert Map.take(task, ~w(thread_id turn_id output_json)) == %{
             "thread_id" => observed.thread_id,
             "turn_id" => observed.turn_id,
             "output_json" => Jason.encode!(observed.output)
           }

    assert {:ok, ^task} = WorkerEvidence.adopt_completed(ctx.store, key)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.adopt_completed(ctx.store, key)
    assert {:ok, _} = WorkerEvidence.consume(ctx.store, key)
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.adopt_completed(ctx.store, key)
  end

  test "completed result inspection proves readiness without adopting or releasing source", ctx do
    {attrs, observed, receipt} = result(ctx)
    key = receipt["request_key"]
    {:ok, task_before} = TaskLedger.get(ctx.store, "writer")
    {:ok, access_before} = WorkspaceAccess.get(ctx.store, "reservation")

    assert {:error, :worker_not_ready_for_consumption} = WorkerEvidence.completed_result(ctx.store, key)
    {:ok, stopped} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))
    assert {:ok, completed} = WorkerEvidence.completed_result(ctx.store, key)
    assert completed.output == observed.output
    assert completed.evidence["output_json"] == Jason.encode!(observed.output)
    assert completed.evidence["status"] == "RESULT_RECORDED"
    assert completed.task == task_before
    assert completed.evidence["owner_stop_json"] == stopped["owner_stop_json"]
    assert {:ok, ^stopped} = WorkerEvidence.get(ctx.store, key)
    assert {:ok, ^task_before} = TaskLedger.get(ctx.store, "writer")
    assert {:ok, ^access_before} = WorkspaceAccess.get(ctx.store, "reservation")

    {:ok, _} = RunLedger.update(ctx.store, "run", %{spec_revision: 2})
    assert {:error, :worker_inputs_changed} = WorkerEvidence.completed_result(ctx.store, key)
  end

  test "checkout head rejects missing paths and nonrepository directories", ctx do
    assert {:error, :worker_checkout_head_unavailable} =
             WorkerEvidence.checkout_head(%{"canonical_path" => Path.join(ctx.root, "missing-checkout")})

    assert {:error, :worker_checkout_head_unavailable} =
             WorkerEvidence.checkout_head(%{"canonical_path" => ctx.root})
  end

  test "a nonexistent supersession command cannot hide blocked worker evidence", ctx do
    {_attrs, evidence} = reserve(ctx)
    access_before = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [evidence["reservation_key"]])
    evidence_before = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [evidence["request_key"]])
    receipt = Jason.encode!(%{"kind" => "BLOCKED_SOURCE_TRANSFER", "command_key" => "missing-command"})
    Store.query!(ctx.store, "UPDATE workspace_access SET release_receipt_json = ? WHERE reservation_key = ?", [receipt, evidence["reservation_key"]])
    access_with_invalid_receipt = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [evidence["reservation_key"]])

    refute WorkerEvidence.superseded_blocked_attempt?(ctx.store, evidence)
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key = ?", [evidence["request_key"]]) == evidence_before
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [evidence["reservation_key"]]) == access_with_invalid_receipt
    assert access_with_invalid_receipt != access_before
  end

  test "receipt adoption rejects changed inputs and conflicting output without overwriting task state", ctx do
    {attrs, _observed, receipt} = result(ctx)
    key = receipt["request_key"]
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))

    for changes <- [
          %{model: "changed"},
          %{prompt_sha256: "changed"},
          %{thread_id: "other-worker"},
          %{output_json: "{}"},
          %{status: "FAILED"}
        ] do
      {:ok, before} = TaskLedger.get(ctx.store, "writer")
      {:ok, changed} = TaskLedger.update(ctx.store, "writer", changes)
      assert {:error, _} = WorkerEvidence.adopt_completed(ctx.store, key)
      assert {:ok, ^changed} = TaskLedger.get(ctx.store, "writer")
      fields = Map.keys(changes) |> Enum.map(&to_string/1)
      {:ok, _} = TaskLedger.update(ctx.store, "writer", Map.take(before, fields))
    end

    {:ok, _} = RunLedger.register(ctx.store, %{run_id: "foreign-run", issue_key: "PPL-124", kind: "DELIVERY", state: "WRITING"})
    Store.query!(ctx.store, "UPDATE factory_tasks SET run_id = 'foreign-run' WHERE task_key = 'writer'")
    assert {:error, :worker_adoption_scope_mismatch} = WorkerEvidence.adopt_completed(ctx.store, key)
    Store.query!(ctx.store, "UPDATE factory_tasks SET run_id = 'run' WHERE task_key = 'writer'")
    Store.query!(ctx.store, "UPDATE worker_evidence SET output_json = '{}' WHERE request_key = ?", [key])
    assert {:error, :worker_evidence_corrupt} = WorkerEvidence.adopt_completed(ctx.store, key)
  end

  test "launcher recovers receipt before refresh even when routing policy changed; incomplete receipt never relaunches", ctx do
    prompt = "Implement this fixture"
    digest = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: digest, status: "RUNNING"})
    {attrs, _observed, receipt} = result(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")

    options = [
      task_key: "writer",
      stage: "feature_writer",
      role: "feature-writer",
      project_id: nil,
      project_root: ctx.repo,
      recipient: self(),
      model_policy: %{
        "default_provider" => "codex",
        "providers" => %{"codex" => %{"fast" => "different-new-default"}},
        "roles" => %{"feature-writer" => %{"provider" => "codex", "model_class" => "fast", "reasoning_effort" => "low"}}
      }
    ]

    launch = fn -> TaskLauncher.launch(ctx.store, nil, run, %Issue{identifier: "PPL-123"}, ctx.path, prompt, attrs["schema"], options) end
    {:ok, before} = TaskLedger.get(ctx.store, "writer")
    assert {:error, :worker_not_ready_for_consumption} = launch.()
    assert {:ok, ^before} = TaskLedger.get(ctx.store, "writer")
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, receipt["request_key"], attrs["owner_id"], stop_receipt(ctx))
    assert {:already_terminal, recovered} = launch.()
    assert recovered["model"] == "gpt-6-luna"
    assert recovered["reasoning_effort"] == "medium"
    assert {:already_terminal, ^recovered} = launch.()
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence")["count"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 0
    refute_receive {:factory_task_started, _, _}
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})
    {:ok, _} = WorkerEvidence.consume(ctx.store, receipt["request_key"])
    assert {:already_terminal, %{"status" => "CONSUMED"}} = launch.()
  end

  test "timestamps and malformed bindings cannot replace owned exit evidence", ctx do
    {attrs, _observed, receipt} = result(ctx)
    key = receipt["request_key"]
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at = 'legacy-marker' WHERE request_key = ?", [key])
    refute WorkerEvidence.owner_stopped?(ctx.store, WorkerEvidence.get(ctx.store, key) |> elem(1))
    assert {:error, :worker_not_ready_for_consumption} = WorkerEvidence.consume(ctx.store, key)

    for raw <- ["bad JSON", "[]", "{}"] do
      Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stop_json = ? WHERE request_key = ?", [raw, key])
      refute WorkerEvidence.owner_stopped?(ctx.store, WorkerEvidence.get(ctx.store, key) |> elem(1))
    end

    raw = "[]"
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = ?, binding_sha256 = ? WHERE request_key = ?", [raw, hash, key])
    assert {:error, :worker_evidence_corrupt} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))
  end

  test "review output pins candidate and a stopped uncertain worker is still not releasable", ctx do
    {attrs, evidence} = reserve(ctx, "REVIEW")
    key = evidence["request_key"]
    assert {:error, :worker_stop_receipt_invalid} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx, nil))
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, key)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, key, "worker", attrs["policy"])
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, key, "worker", "turn")
    output = %{thread_id: "worker", turn_id: "turn", item_id: "item", output: %{"status" => "PASS", "candidate_sha" => "other"}}
    assert {:error, :worker_review_candidate_mismatch} = WorkerEvidence.record_result(ctx.store, key, output)
    assert {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, key, :owner_terminated_without_output)
    assert {:error, :workspace_completion_not_proven} = WorkspaceAccess.release(ctx.store, "reservation", 1, key)
  end

  test "owned process identity is immutable and an old stop receipt cannot stop a new invocation", ctx do
    {attrs, evidence} = reserve(ctx)
    key = evidence["request_key"]
    assert {:error, :worker_process_identity_invalid} = WorkerEvidence.bind_owner_process(ctx.store, key, nil)
    assert {:error, :worker_process_identity_invalid} = WorkerEvidence.bind_owner_process(ctx.store, key, %{"pid" => "", "invocation_nonce" => "bad"})
    assert {:error, :worker_process_identity_conflict} = WorkerEvidence.bind_owner_process(ctx.store, key, process_receipt())
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, key)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, key, "worker", attrs["policy"])
    process = Map.put(process_receipt(), "invocation_nonce", String.duplicate("b", 64))
    assert {:ok, bound} = WorkerEvidence.bind_owner_process(ctx.store, key, process)
    assert {:ok, ^bound} = WorkerEvidence.bind_owner_process(ctx.store, key, process)
    assert {:error, :worker_process_identity_conflict} = WorkerEvidence.bind_owner_process(ctx.store, key, process_receipt())
    new_stop = Map.merge(stop_receipt(ctx), process)
    assert {:error, :worker_completion_unproven} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], new_stop)
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, key, "worker", "next-turn")
    observed = %{thread_id: "worker", turn_id: "next-turn", item_id: "next-final", output: %{"status" => "PASS"}}
    {:ok, _} = WorkerEvidence.record_result(ctx.store, key, observed)
    assert {:error, :worker_stop_receipt_invalid} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], stop_receipt(ctx))
    assert {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, key, attrs["owner_id"], new_stop)
  end

  test "late exact result and exit recover the same uncertain invocation without creation", ctx do
    {attrs, observed, evidence} = result(ctx)
    key = evidence["request_key"]
    assert {:error, :worker_reconciliation_not_pending} = WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], observed, stop_receipt(ctx))
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, key, :exit_readback_timeout)
    assert {:error, :worker_owner_mismatch} = WorkerEvidence.reconcile_completed(ctx.store, key, "other", observed, stop_receipt(ctx))
    assert {:error, :worker_result_identity_mismatch} = WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], %{observed | turn_id: "old"}, stop_receipt(ctx))
    assert {:error, :worker_result_item_missing} = WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], %{observed | item_id: nil}, stop_receipt(ctx))
    assert {:error, :worker_result_conflict} = WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], %{observed | output: %{"status" => "different"}}, stop_receipt(ctx))

    assert {:error, :worker_stop_receipt_invalid} =
             WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], observed, Map.put(stop_receipt(ctx), "invocation_nonce", String.duplicate("c", 64)))

    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} = WorkerEvidence.get(ctx.store, key)
    assert {:ok, recovered} = WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], observed, stop_receipt(ctx))
    assert recovered["status"] == "RESULT_RECORDED" and recovered["failure_code"] == nil
    assert {:error, :worker_start_already_sent} = WorkerEvidence.mark_start_sent(ctx.store, key)
    assert {:error, :worker_adoption_not_proven} = WorkerEvidence.consume(ctx.store, key)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: "worker", turn_id: "turn", output_json: Jason.encode!(observed.output)})
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.consume(ctx.store, key)
  end

  test "a late completion can fill an absent result only for the known owned turn", ctx do
    {attrs, observed, evidence} = result(ctx)
    key = evidence["request_key"]
    {:ok, _} = WorkerEvidence.reconcile_required(ctx.store, key, :completion_readback_timeout)
    Store.query!(ctx.store, "UPDATE worker_evidence SET output_json = NULL, output_sha256 = NULL, item_id = NULL WHERE request_key = ?", [key])
    assert {:ok, _} = WorkerEvidence.reconcile_completed(ctx.store, key, attrs["owner_id"], observed, stop_receipt(ctx))
  end

  test "a consumed reviewer releases only its unchanged exact candidate", ctx do
    {attrs, observed, evidence} = result(ctx, "REVIEW")
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, evidence["request_key"], attrs["owner_id"], stop_receipt(ctx))
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: observed.thread_id, turn_id: observed.turn_id, output_json: Jason.encode!(observed.output)})
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: String.duplicate("b", 40)})
    assert {:error, :worker_review_candidate_mismatch} = WorkerEvidence.consume(ctx.store, evidence["request_key"])
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: ctx.sha})
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.consume(ctx.store, evidence["request_key"])
  end

  test "the Desktop parent can never become a role worker", ctx do
    bind_parent(ctx)
    {attrs, evidence} = reserve(ctx)
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, evidence["request_key"])
    assert {:error, :worker_cannot_own_parent} = WorkerEvidence.bind_thread(ctx.store, evidence["request_key"], "parent", attrs["policy"])
  end

  test "a resumed worker's completed turn cannot be recycled into another attempt", ctx do
    {attrs, observed, receipt} = result(ctx)
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, receipt["request_key"], attrs["owner_id"], stop_receipt(ctx))
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: "worker", turn_id: "turn", output_json: Jason.encode!(observed.output)})
    {:ok, _} = WorkerEvidence.consume(ctx.store, receipt["request_key"])
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "second"), opts(ctx))
    attrs = Map.merge(attrs, %{"request_key" => "second:request", "reservation_key" => "second", "owner_id" => "second-owner"})
    {:ok, _} = WorkerEvidence.reserve(ctx.store, attrs)
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, attrs["request_key"])
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, attrs["request_key"], "worker", attrs["policy"])
    assert {:error, :worker_turn_already_used} = WorkerEvidence.bind_turn(ctx.store, attrs["request_key"], "worker", "turn")
  end

  test "native worker PASS is exposed only for the exact stopped task, contract, candidate and pinned base", ctx do
    bind_parent(ctx)
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})
    {:ok, writer} = TaskLedger.get(ctx.store, "writer")
    key = "run:change-verifier:0"

    attrs =
      Map.take(writer, ~w(run_id stage model_provider model_class model reasoning_effort routing_reason prompt_sha256 workspace workspace_sha))
      |> Map.merge(%{"task_key" => key, "role" => "change-verifier", "status" => "STARTING"})

    {:ok, _} = TaskLedger.register(ctx.store, attrs)
    access_attrs = attrs(ctx, "REVIEW") |> Map.put("task_key", key)
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, access_attrs)

    worker_attrs = %{
      "request_key" => "reservation:request",
      "task_key" => key,
      "reservation_key" => "reservation",
      "input_sha256" => writer["prompt_sha256"],
      "owner_id" => "owner",
      "schema" => StageSchemas.for_stage(:change_verifier),
      "policy" => TicketWorkerRunner.policy("REVIEW", ctx.path)
    }

    {:ok, _} = WorkerEvidence.reserve(ctx.store, worker_attrs)
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, "reservation:request")
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, "reservation:request", "reviewer", worker_attrs["policy"])
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, "reservation:request", process_receipt())
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, "reservation:request", "reviewer", "review-turn")
    output = %{"status" => "PASS", "candidate_sha" => ctx.sha, "findings" => [], "checks" => ["Fixture inspected"]}
    observed = %{thread_id: "reviewer", turn_id: "review-turn", item_id: "review-final", output: output}
    {:ok, _} = WorkerEvidence.record_result(ctx.store, "reservation:request", observed)
    {:ok, _} = TaskLedger.update(ctx.store, key, %{status: "COMPLETE", thread_id: "reviewer", turn_id: "review-turn", output_json: Jason.encode!(output)})
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, task} = TaskLedger.get(ctx.store, key)
    assert {:error, :worker_verifier_binding_unproven} = WorkerEvidence.verifier_receipt(ctx.store, run, task)
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, "reservation:request", "owner", stop_receipt(ctx, "reviewer"))
    assert {:ok, _} = WorkerEvidence.verifier_receipt(ctx.store, run, task)
    assert {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert packet.latest_verifier.current_binding == "EXACT"
    assert {:ok, _} = TicketContext.details(ctx.store, packet.identity["chat_key"], packet.latest_verifier.receipt.artifact_ref)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_markdown: "unconfirmed text"})
    assert {:ok, %{latest_verifier: %{current_binding: "UNPROVEN_OR_STALE"}}} = TicketContext.context(ctx.store, "run")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_markdown: run["contract_markdown"]})
    bad = Jason.encode!(Map.put(output, "candidate_sha", "wrong"))
    hash = :crypto.hash(:sha256, bad) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE worker_evidence SET output_json = ?, output_sha256 = ? WHERE request_key = 'reservation:request'", [bad, hash])
    {:ok, _} = TaskLedger.update(ctx.store, key, %{output_json: bad})
    {:ok, task} = TaskLedger.get(ctx.store, key)
    assert {:error, :worker_review_candidate_mismatch} = WorkerEvidence.verifier_receipt(ctx.store, run, task)
  end
end
