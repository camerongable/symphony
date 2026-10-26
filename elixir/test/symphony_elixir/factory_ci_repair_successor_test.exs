defmodule SymphonyElixir.FactoryCiRepairSuccessorTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{Store, TicketCiRepairSuccessor}

  alias SymphonyElixir.Factory.{
    Control,
    ControlServer,
    Controller,
    DesktopStageRunner,
    RunLedger,
    StageSchemas,
    TaskLedger,
    TicketCiRepair,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerInstructions,
    WorkspaceAccess
  }

  defmodule NativeReader do
    def read_native_thread(_, _), do: {:ok, Process.get(:successor_native_receipt)}
  end

  test "historical successors do not turn ordinary verifier repairs into CI claims" do
    fixture = journal_fixture()
    ctx = fixture.ctx

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_evidence_successors VALUES (?,'run','claim',?,NULL,2,5,?,?,?,?,?,'new-request','new-reservation',?)", [
      fixture.key,
      fixture.request,
      fixture.content_sha,
      fixture.raw_supplement,
      hash(fixture.raw_supplement),
      fixture.raw_proof,
      hash(fixture.raw_proof),
      fixture.proof["admitted_at"]
    ])

    {:ok, %{run: repair}} = RunLedger.update(ctx.store, "run", %{code_repair_round: 2, repair_findings_json: Jason.encode!(["Preserve the required failure prefix"])})
    history = Store.query!(ctx.store, "SELECT * FROM ticket_ci_repair_evidence_successors").rows
    assert {:ok, nil} = TicketCiRepair.writer_scope(ctx.store, repair)
    assert :ok = TicketCiRepairSuccessor.issuance_check(ctx.store, repair, [])
    assert :ok = Store.initialize(ctx.store)
    assert :ok = TicketCiRepairSuccessor.issuance_check(ctx.store, repair, [])
    assert Store.query!(ctx.store, "SELECT * FROM ticket_ci_repair_evidence_successors").rows == history

    for malformed <- ["{", "null", ~s({"kind":"TICKET_CI_REPAIR","claim_key":"missing"}), ~s({"kind":"OTHER"}), ~s([42])] do
      {:ok, %{run: invalid}} = RunLedger.update(ctx.store, "run", %{repair_findings_json: malformed})
      assert {:error, :ci_repair_scope_unproven} = TicketCiRepair.writer_scope(ctx.store, invalid)
      assert {:error, :ci_repair_scope_unproven} = TicketCiRepairSuccessor.issuance_check(ctx.store, invalid, [])
    end
  end

  test "the current controller policy can authorize seven total attempts" do
    fixture = journal_fixture()
    {_owner, _tick, policy} = current_policy_fixture(fixture, 7)
    assert policy["configured_limit"] == 7
    assert policy["effective_limit"] == 7
    assert TicketCiRepairSuccessor.attempts_used(fixture.ctx.store, "run") == 1
  end

  test "exhaustion notice respects a lower cap, is deduplicated, and never spends or releases an attempt" do
    fixture = journal_fixture()
    ctx = fixture.ctx
    {_owner, tick, _policy} = current_policy_fixture(fixture, 1)
    Process.put(:successor_native_receipt, fixture_native(ctx.path).receipt)
    opts = Keyword.merge(SymphonyElixir.TicketWorkerFixture.opts(ctx), operator_tick: tick, app_server: NativeReader, workspace_root: Path.dirname(ctx.path))
    before = Map.new(~w(worker_evidence workspace_access factory_tasks ticket_ci_repair_evidence_successors), &{&1, Store.query!(ctx.store, "SELECT rowid,* FROM #{&1} ORDER BY rowid").rows})
    auth = fixture.proof["authorization"]
    assert {:error, :push_recovery_operator_tick_unproven} = TicketCiRepairSuccessor.record_exhaustion(ctx.store, fixture.request, auth, Keyword.delete(opts, :operator_tick))
    assert {:ok, unchanged} = RunLedger.get(ctx.store, "run")
    assert unchanged == fixture.run
    assert {:ok, exhausted} = TicketCiRepairSuccessor.record_exhaustion(ctx.store, fixture.request, auth, opts)
    assert exhausted["failure_code"] == "CI_REPAIR_EXHAUSTED"
    assert exhausted["last_error"] =~ "1 total attempts used; configured limit 1"
    assert Map.drop(exhausted, ~w(failure_code last_error updated_at)) == Map.drop(fixture.run, ~w(failure_code last_error updated_at))
    recorded_events = Store.query!(ctx.store, "SELECT * FROM events ORDER BY rowid").rows
    assert {:ok, ^exhausted} = TicketCiRepairSuccessor.record_exhaustion(ctx.store, fixture.request, auth, opts)
    assert Store.query!(ctx.store, "SELECT * FROM events ORDER BY rowid").rows == recorded_events
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 1
    assert Map.new(Map.keys(before), &{&1, Store.query!(ctx.store, "SELECT rowid,* FROM #{&1} ORDER BY rowid").rows}) == before
    expired = Map.put(auth, "observed_at", "2020-01-01T00:00:00Z")
    assert {:error, :ticket_authorization_expired} = TicketCiRepairSuccessor.record_exhaustion(ctx.store, fixture.request, expired, opts)
    assert {:ok, ^exhausted} = RunLedger.get(ctx.store, "run")
  end

  test "atomic API reserves one successor and rolls back a failure after SOURCE transfer without dispatch" do
    atomic_successor_case(false)
  end

  test "operator source scope belongs only to the new applied successor and rejects the stopped predecessor" do
    atomic_successor_case(true)
  end

  defp atomic_successor_case(scoped) do
    fixture = journal_fixture(scoped)
    ctx = fixture.ctx
    extension = if scoped, do: extension_fixture(fixture)
    {owner, tick, policy} = current_policy_fixture(fixture, 5, extension)
    assert {:ok, source} = WorkspaceAccess.prepare_ci_successor_source(ctx.store, fixture.run, fixture.access, Path.join(ctx.root, "workspaces"))
    proof = fixture.proof |> Map.put("policy_receipt", policy) |> Map.put("admitted_at", utc())
    raw_proof = Jason.encode!(proof)

    row = %{
      "successor_key" => fixture.key,
      "run_id" => "run",
      "claim_key" => "claim",
      "prior_request_key" => fixture.request,
      "prior_successor_key" => nil,
      "attempt_index" => 2,
      "configured_limit" => 5,
      "evidence_content_sha256" => fixture.content_sha,
      "evidence_json" => fixture.raw_supplement,
      "evidence_sha256" => hash(fixture.raw_supplement),
      "proof_json" => raw_proof,
      "proof_sha256" => hash(raw_proof),
      "created_at" => proof["admitted_at"]
    }

    supplement = %{
      "version" => 1,
      "kind" => "CI_EVIDENCE_SUCCESSOR_PACKET_V1",
      "successor_key" => fixture.key,
      "proof_sha256" => row["proof_sha256"],
      "evidence_sha256" => row["evidence_sha256"],
      "evidence_content_sha256" => row["evidence_content_sha256"],
      "attempt_index" => 2
    }

    packet = fixture.packet |> Map.put("ci_evidence_successor", supplement) |> Map.put("ci_evidence_successor_evidence", Jason.decode!(fixture.raw_supplement))

    packet =
      if extension,
        do: packet |> Map.put("ci_repair_scope_extension", policy) |> put_in(["ci_repair", "allowed_writer_paths"], Enum.sort(["fixture.txt" | extension["allowed_writer_paths"]])),
        else: packet

    instruction_sha = hash(Jason.encode!(packet))
    prompt = Jason.encode!(Map.merge(packet, Map.put(fixture.admitted, "instruction_binding_sha256", instruction_sha)))
    request = DesktopStageRunner.request_key("writer", fixture.task["turn_id"], prompt)
    row = Map.merge(row, %{"new_request_key" => request, "new_reservation_key" => "workspace:" <> request})
    native = fixture_native(ctx.path)

    review = %{
      "project_id" => 123,
      "mr_iid" => 9,
      "observed_at" => utc(),
      "pages" => [%{"items" => [], "page" => 1, "total" => 0, "total_pages" => 1, "raw_sha256" => hash("synthetic empty discussion page")}]
    }

    context = %{
      row: row,
      run: fixture.run,
      claim: proof["claim"],
      prior: fixture.evidence,
      task: fixture.task,
      access: fixture.access,
      event: proof["disposition_event"],
      authorization: proof["authorization"],
      inputs: proof["inputs"],
      policy: policy,
      source: source,
      native: native,
      review: review,
      snapshots: proof["ci_snapshots"],
      evidence: Jason.decode!(fixture.raw_supplement),
      tick: tick,
      owner: owner,
      proof: proof,
      packet: packet,
      prior_packet: fixture.packet,
      instruction_sha: instruction_sha,
      prompt: prompt
    }

    atomic_admission_assertions(ctx, fixture, context, tick, request)

    if scoped do
      state = :sys.get_state(owner)
      options = [settings: %{factory: state.factory}, store: ctx.store, control_server: state.control_server, capacity_opts: [free_bytes: 40_000_000_000]]
      snapshot = SymphonyElixir.Factory.Observability.snapshot(options)
      assert snapshot.available, inspect(Map.get(snapshot, :error))
      projected = Enum.find(snapshot.runs, &(&1.run_id == "run"))
      assert projected.historical_failure.phase == "SUPERSEDED_EXHAUSTION"
      refute projected.historical_failure.blocking
      assert projected.last_error == nil
      assert projected.failure_code == nil
      assert {:ok, recorded} = RunLedger.get(ctx.store, "run")
      assert recorded["last_error"] == fixture.run["last_error"]
      assert recorded["failure_code"] == "CI_REPAIR_EXHAUSTED"
      assert {:ok, _} = RunLedger.update(ctx.store, "run", %{last_error: "A genuinely new exhaustion"})
      changed = SymphonyElixir.Factory.Observability.snapshot(options)
      current = Enum.find(changed.runs, &(&1.run_id == "run"))
      assert current.historical_failure == nil
      assert current.attention.blocking
      assert current.last_error == "A genuinely new exhaustion"
      assert {:ok, _} = RunLedger.update(ctx.store, "run", %{last_error: recorded["last_error"]})
    end

    if extension do
      for path <- extension["allowed_writer_paths"] do
        assert :ok = TicketCiRepair.authorize_mutation(ctx.store, "run", path, :text, request)
        assert :ok = Store.transaction!(ctx.store, &TicketCiRepair.authorize_mutation(&1, "run", path, :text, request))
        assert {:error, _} = TicketCiRepair.authorize_mutation(ctx.store, "run", path, :text, fixture.request)
        assert {:error, _} = TicketCiRepair.authorize_mutation(ctx.store, "run", path, :binary, request)
      end

      assert {:error, _} = TicketCiRepair.authorize_mutation(ctx.store, "run", "go/src/grail.com/workflows/commercial/repeattesting/foreign.go", :text, request)
      assert {:ok, scope} = TicketCiRepair.effective_writer_scope(ctx.store, fixture.run, request)
      assert scope["allowed_writer_paths"] == Enum.sort(["fixture.txt" | extension["allowed_writer_paths"]])
      assert TicketCiRepair.writer_result(ctx.store, fixture.run, %{"status" => "CONTINUE", "changed_paths" => extension["allowed_writer_paths"]}) == :ok
      assert Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key='claim'") == fixture.proof["claim"]
      workflow = SymphonyElixir.Workflow.workflow_file_path()
      original = File.read!(workflow)
      original_mtime = File.stat!(workflow).mtime
      File.write!(workflow, original <> "\nOperator policy changed\n")
      assert {:error, _} = TicketCiRepair.authorize_mutation(ctx.store, "run", hd(extension["allowed_writer_paths"]), :text, request)
      File.write!(workflow, original)
      File.touch!(workflow, original_mtime)
      assert :ok = TicketCiRepair.authorize_mutation(ctx.store, "run", hd(extension["allowed_writer_paths"]), :text, request)
    end
  end

  defp extension_fixture(fixture) do
    Map.take(fixture.run, ~w(run_id issue_key repo_key spec_revision contract_sha256))
    |> Map.merge(%{
      "version" => 1,
      "project_id" => 123,
      "claim_key" => "claim",
      "claim_sha256" => fixture.proof["claim"]["claim_sha256"],
      "failed_candidate_sha" => fixture.run["candidate_sha"],
      "allowed_writer_paths" => ["go/src/grail.com/workflows/commercial/repeattesting/fax_parent.go", "go/src/grail.com/workflows/commercial/repeattesting/fax_parent_test.go"],
      "authorization_reference" => "Explicit interactive test-fixture operator approval for these two paths"
    })
  end

  test "operator source capability rejects foreign identity, policy paths, unknown fields and extra paths" do
    fixture = journal_fixture()
    extension = extension_fixture(fixture)
    assert :ok = TicketCiRepairSuccessor.validate_scope_extension(extension, fixture.run, fixture.proof["claim"])

    for changed <- [
          Map.put(extension, "run_id", "foreign"),
          Map.put(extension, "claim_key", "foreign"),
          Map.put(extension, "claim_sha256", String.duplicate("0", 64)),
          Map.put(extension, "failed_candidate_sha", String.duplicate("0", 40)),
          Map.put(extension, "contract_sha256", String.duplicate("0", 64)),
          Map.put(extension, "unknown", true),
          Map.put(extension, "allowed_writer_paths", ["../outside.go", "a.go"]),
          Map.put(extension, "allowed_writer_paths", [".gitlab/workflows/a.go", "a.go"]),
          Map.put(extension, "allowed_writer_paths", extension["allowed_writer_paths"] ++ ["third.go"])
        ] do
      assert {:error, :ci_scope_extension_unproven} = TicketCiRepairSuccessor.validate_scope_extension(changed, fixture.run, fixture.proof["claim"])
    end
  end

  defp current_policy_fixture(fixture, limit, extension \\ nil) do
    ctx = fixture.ctx
    previous = SymphonyElixir.Workflow.workflow_file_path()
    workflow = Path.join(ctx.root, "successor-WORKFLOW.md")

    raw =
      "---\ntracker:\n  kind: memory\nfactory:\n  enabled: true\n  database: #{ctx.database}\n  controller_codex_project_id: projectless\n  scope: fixture\n  dispatcher_id: fixture\n  maximum_code_repair_rounds: #{limit}\n  ticket_supervisor:\n    enabled: true\n    all_eligible_tickets: true\n    pilot_issue_keys: []\n    ci_repair: native_bounded_v1\n  repositories:\n    grail:\n      path: #{ctx.repo}\n      base_branch: master\n      gitlab_project: fixture/project\n      gitlab_project_id: '123'\n---\nFixture.\n"

    raw = if extension, do: String.replace(raw, "  ticket_supervisor:\n", "  ci_repair_scope_extensions: #{Jason.encode!(%{"run" => extension})}\n  ticket_supervisor:\n", global: false), else: raw
    File.write!(workflow, raw)
    File.chmod!(workflow, 0o600)
    SymphonyElixir.Workflow.set_workflow_file_path(workflow)
    on_exit(fn -> SymphonyElixir.Workflow.set_workflow_file_path(previous) end)
    {:ok, loaded} = SymphonyElixir.Workflow.parse_content(raw)
    {:ok, settings} = SymphonyElixir.Config.Schema.parse(loaded.config)
    control = start_supervised!({ControlServer, store: ctx.store, factory: settings.factory, name: nil})
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})
    owner = start_supervised!({Controller, settings: settings, store: ctx.store, control_server: control, task_supervisor: supervisor})
    assert {:ok, _} = Control.activate(ctx.store, settings.factory, "fixture")
    assert %{result: "ACQUIRED"} = Control.acquire_tick(ctx.store, settings.factory, "fixture")
    tick = Store.one!(ctx.store, "SELECT * FROM control WHERE scope='fixture'") |> Map.take(~w(scope dispatcher_id generation tick_id))
    assert {:ok, policy} = TicketCiRepairSuccessor.policy_receipt(ctx.store, fixture.run)
    {owner, tick, policy}
  end

  defp atomic_admission_assertions(ctx, fixture, context, tick, request) do
    options = SymphonyElixir.TicketWorkerFixture.opts(ctx) |> Keyword.put(:operator_tick, tick)

    protected = fn ->
      Map.new(
        ~w(runs factory_tasks worker_evidence workspace_access worker_instruction_task_bindings worker_instruction_snapshots ticket_ci_repair_evidence_successors events),
        &{&1, Store.query!(ctx.store, "SELECT rowid,* FROM #{&1} ORDER BY rowid").rows}
      )
    end

    before = protected.()
    assert {:error, :workspace_capacity_policy_missing} = TicketCiRepairSuccessor.admit(ctx.store, context, operator_tick: tick)
    assert protected.() == before
    assert {:error, :insufficient_writer_capacity} = TicketCiRepairSuccessor.admit(ctx.store, context, Keyword.put(options, :free_bytes, 1_000_000_000))
    assert protected.() == before
    assert {:error, :push_recovery_operator_tick_unproven} = TicketCiRepairSuccessor.admit(ctx.store, context, Keyword.delete(options, :operator_tick))
    assert protected.() == before
    unrelated = context |> put_in([:native, :request, "existing_thread_id"], "unrelated") |> put_in([:native, :receipt, "id"], "unrelated")
    assert {:error, :ci_successor_preparation_changed} = TicketCiRepairSuccessor.admit(ctx.store, unrelated, options)
    assert protected.() == before
    assert {:error, :ci_repair_discussions_unproven} = TicketCiRepairSuccessor.admit(ctx.store, put_in(context, [:review, "mr_iid"], 10), options)
    assert protected.() == before

    Store.query!(
      ctx.store,
      "CREATE TRIGGER fixture_bind_failure BEFORE INSERT ON worker_instruction_task_bindings WHEN NEW.prompt_sha256 != ? BEGIN SELECT RAISE(ABORT,'fixture after-transfer failure'); END"
      |> String.replace("?", "'" <> fixture.task["prompt_sha256"] <> "'")
    )

    context = %{context | native: fixture_native(ctx.path)}
    assert_raise Exqlite.Error, fn -> TicketCiRepairSuccessor.admit(ctx.store, context, options) end
    assert protected.() == before
    Store.query!(ctx.store, "DROP TRIGGER fixture_bind_failure")
    context = %{context | native: fixture_native(ctx.path)}
    assert {:ok, applied} = TicketCiRepairSuccessor.admit(ctx.store, context, options)
    assert applied.destination["status"] == "RESERVED" and applied.destination["thread_id"] == nil
    assert applied.destination["request_key"] == request
    assert applied.access["generation"] == fixture.access["generation"] + 1
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key=?", [fixture.request]) == fixture.evidence
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 2
    assert {:error, _} = TicketCiRepairSuccessor.admit(ctx.store, context, options)
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 2
  end

  defp fixture_native(path) do
    at = utc()
    empty = %{"data" => [], "nextCursor" => nil}
    latest = %{"data" => [%{"id" => "turn", "status" => "completed", "items" => []}], "nextCursor" => nil}

    request = %{
      "existing_thread_id" => "worker",
      "cwd" => path,
      "codex_project_id" => "projectless",
      "metadata_json" => Jason.encode!(%{"previous_turn_id" => "turn", "delivery_operation" => %{"controller_native_cwd" => path}})
    }

    native = %{
      "id" => "worker",
      "cwd" => path,
      "projectId" => nil,
      "status" => %{"type" => "idle"},
      "updatedAt" => 42,
      "queue_observation" => %{
        "thread_id" => "worker",
        "empty_complete" => true,
        "count_lower_bound" => 0,
        "has_more" => false,
        "observed_at" => at,
        "raw_response" => empty,
        "sha256" => hash(Jason.encode!(empty))
      },
      "latest_turn_observation" => %{
        "mode" => "LATEST_DESC",
        "parameters" => %{"threadId" => "worker", "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
        "raw_response" => latest,
        "sha256" => hash(Jason.encode!(latest)),
        "confirmation" => %{"raw_response" => latest, "sha256" => hash(Jason.encode!(latest)), "observed_at" => at},
        "updated_at" => 42,
        "observed_at" => at
      }
    }

    %{request: request, receipt: native}
  end

  defp journal_fixture(exhausted \\ false) do
    ctx = SymphonyElixir.TicketWorkerFixture.setup_fixture(%{})
    SymphonyElixir.TicketWorkerFixture.bind_parent(ctx)
    snapshot = Store.one!(ctx.store, "SELECT snapshot_json FROM runs WHERE run_id='run'")["snapshot_json"] |> Jason.decode!() |> Map.merge(%{"labels" => ["ai-running"], "status" => "In Progress"})
    {:ok, %{run: prior}} = RunLedger.update(ctx.store, "run", %{state: "CI_WAITING", ci_pipeline_id: 99, mr_iid: 9, mr_url: "https://example/mr/9", snapshot_json: Jason.encode!(snapshot)})
    {:ok, source_task} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", stage: "WRITING", thread_id: "worker"})
    snapshots = fixture_ci(ctx.sha)
    diagnosis = %{"status" => "REPAIRABLE", "artifacts" => [], "allowed_writer_paths" => ["fixture.txt"], "required_generated_paths" => []}
    raw_diagnosis = Jason.encode!(diagnosis)
    preimage = Jason.encode!(%{"run" => prior})

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES ('diagnosis','run',?,99,?,?,?,?,'REPAIRABLE',?)", [
      ctx.sha,
      preimage,
      hash(preimage),
      raw_diagnosis,
      hash(raw_diagnosis),
      utc()
    ])

    claim = %{
      "kind" => "TICKET_CI_REPAIR",
      "claim_key" => "claim",
      "diagnosis_key" => "diagnosis",
      "round" => 1,
      "prior_run" => prior,
      "source_task" => source_task,
      "allowed_writer_paths" => ["fixture.txt"],
      "required_generated_paths" => [],
      "ci_snapshots" => snapshots
    }

    raw_claim = Jason.encode!(claim)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim','diagnosis','run',1,?,?,?)", [raw_claim, hash(raw_claim), utc()])
    failure = if exhausted, do: %{failure_code: "CI_REPAIR_EXHAUSTED", last_error: "Synthetic prior repair budget exhausted"}, else: %{}
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", Map.merge(failure, %{state: "REPAIRING", code_repair_round: 1, repair_findings_json: ~s({"kind":"TICKET_CI_REPAIR","claim_key":"claim"})}))
    {:ok, repair} = TicketCiRepair.writer_packet(ctx.store, run)

    packet =
      Map.take(run, ~w(run_id issue_key spec_revision contract_sha256 candidate_sha code_repair_round))
      |> Map.merge(%{"role" => "feature-writer", "stage" => "REPAIRING", "ci_repair" => repair, "repair_findings" => run["repair_findings_json"]})

    assert {:ok, admitted} = WorkerInstructions.admit(ctx.store, packet, "ci-repair-writer", Path.join(System.user_home!(), ".agents"))
    prompt_sha = hash("synthetic admitted prompt")
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STARTING", stage: "REPAIRING", prompt_sha256: prompt_sha})
    assert :ok = WorkerInstructions.bind_task(ctx.store, "writer", prompt_sha, admitted["instruction_binding_sha256"])
    attrs = SymphonyElixir.TicketWorkerFixture.attrs(ctx)
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs, SymphonyElixir.TicketWorkerFixture.opts(ctx))
    policy = %{"cwd" => ctx.path, "sandbox" => "read-only"}
    request = attrs["request_key"]

    assert {:ok, _} =
             WorkerEvidence.reserve(ctx.store, %{
               "request_key" => request,
               "task_key" => "writer",
               "reservation_key" => attrs["reservation_key"],
               "input_sha256" => prompt_sha,
               "owner_id" => "fixture",
               "schema" => StageSchemas.for_stage(:native_feature_writer),
               "policy" => policy
             })

    assert {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, request)
    assert {:ok, _} = WorkerEvidence.bind_thread(ctx.store, request, "worker", policy)
    synthetic_process = Map.put(SymphonyElixir.TicketWorkerFixture.process_receipt(), "pid", "99999999")
    assert {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, request, synthetic_process)
    assert {:ok, _} = WorkerEvidence.bind_turn(ctx.store, request, "worker", "turn")
    output = %{"status" => "BLOCKED", "changed_paths" => [], "commit_message" => nil, "blockers" => ["Assertion evidence unavailable"], "checks" => []}
    assert {:ok, _} = WorkerEvidence.record_result(ctx.store, request, %{thread_id: "worker", turn_id: "turn", item_id: "result", output: output})
    synthetic_stop = Map.put(SymphonyElixir.TicketWorkerFixture.stop_receipt(ctx), "pid", "99999999")
    assert {:ok, evidence} = WorkerEvidence.record_owner_stopped(ctx.store, request, "fixture", synthetic_stop)
    {:ok, task} = TaskLedger.update(ctx.store, "writer", %{status: "COMPLETE", thread_id: "worker", turn_id: "turn", output_json: Jason.encode!(output)})
    access = Store.one!(ctx.store, "SELECT * FROM workspace_access WHERE reservation_key=?", [attrs["reservation_key"]])
    disposition_key = hash(Jason.encode!(["run", request, evidence["output_sha256"]]))

    disposition = %{
      "disposition_key" => disposition_key,
      "request_key" => request,
      "task_key" => "writer",
      "output_json" => evidence["output_json"],
      "output_sha256" => evidence["output_sha256"],
      "reservation_key" => evidence["reservation_key"],
      "reservation_generation" => access["generation"],
      "task_status" => "COMPLETE",
      "task" => Map.take(task, ~w(task_key role stage status thread_id turn_id updated_at)),
      "run_binding" => Map.take(run, ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch))
    }

    Store.query!(ctx.store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_NATIVE_WRITER_BLOCKED','run',?)", [utc(), Jason.encode!(disposition)])
    event = Store.one!(ctx.store, "SELECT * FROM events WHERE event_type='TICKET_NATIVE_WRITER_BLOCKED' ORDER BY id DESC LIMIT 1")
    assert {:ok, inputs} = TicketCiRepair.input_snapshot(ctx.store, "run")
    assert {:ok, auth} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())

    artifact = %{
      "job_id" => 7,
      "status" => "COMPLETE",
      "provenance" => %{"metadata_arguments" => %{"project_id" => "123", "job_id" => "7"}, "owned_reader" => %{"exit_status" => 0}},
      "members" => [%{"path" => "tests/failure.log.gz", "sha256" => hash("decoded assertion"), "text" => "decoded assertion", "complete" => true}]
    }

    assert {:ok, content, content_sha} = TicketCiRepairSuccessor.evidence_content([artifact], 123, [7])
    supplement = %{"artifacts" => [artifact], "content_members" => content}

    policy_receipt = %{
      "version" => 1,
      "kind" => "CI_REPAIR_POLICY_V1",
      "workflow_path" => Path.join(ctx.root, "WORKFLOW.md"),
      "workflow_sha256" => hash("archived fixture policy"),
      "workflow_stat" => %{"inode" => 1, "device" => 1, "rdev" => 0, "size" => 1, "mtime_seconds" => 1, "uid" => 505, "mode" => 0o100600},
      "configured_limit" => 5,
      "effective_limit" => 5,
      "scope" => "fixture",
      "dispatcher_id" => "fixture",
      "repo_key" => "grail",
      "cached_policy_sha256" => hash("cached fixture")
    }

    accepted = %{
      "kind" => "BLOCKED_NO_EDIT_ACCEPTED_V1",
      "event_id" => event["id"],
      "event_sha256" => hash(Jason.encode!(event)),
      "request_key" => request,
      "output_sha256" => evidence["output_sha256"],
      "candidate_sha" => ctx.sha
    }

    claim_row = Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key='claim'")

    proof = %{
      "version" => 1,
      "kind" => "CI_EVIDENCE_SUCCESSOR_V1",
      "run" => run,
      "claim" => claim_row,
      "prior_evidence" => evidence,
      "prior_task" => task,
      "prior_access" => access,
      "disposition_event" => event,
      "accepted_outcome" => accepted,
      "inputs" => inputs,
      "source_observation" => %{"canonical_path" => ctx.path, "head_sha" => ctx.sha, "dirty_paths" => []},
      "authorization" => auth,
      "ci_snapshots" => snapshots,
      "content_members" => content,
      "previous_content_sha256" => nil,
      "total_before" => 1,
      "configured_limit" => 5,
      "policy_receipt" => policy_receipt,
      "admitted_at" => utc()
    }

    key = "ci-evidence-successor:" <> hash(Jason.encode!(["claim", request, content_sha]))
    raw_proof = Jason.encode!(proof)
    raw_supplement = Jason.encode!(supplement)

    %{
      ctx: ctx,
      run: run,
      key: key,
      request: request,
      content_sha: content_sha,
      raw_supplement: raw_supplement,
      raw_proof: raw_proof,
      proof: proof,
      evidence: evidence,
      task: task,
      access: access,
      disposition_key: disposition_key,
      accepted: accepted,
      preimage: preimage,
      packet: packet,
      admitted: admitted
    }
  end

  test "journal authenticates genuine instruction admission, original BLOCKED receipt and archived Jira contract" do
    %{
      ctx: ctx,
      run: _run,
      key: key,
      request: request,
      content_sha: content_sha,
      raw_supplement: raw_supplement,
      raw_proof: raw_proof,
      proof: proof,
      evidence: evidence,
      access: access,
      disposition_key: disposition_key,
      accepted: accepted,
      preimage: preimage
    } = journal_fixture()

    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_evidence_successors VALUES (?,'run','claim',?,NULL,2,5,?,?,?,?,?,'new-request','new-reservation',?)", [
      key,
      request,
      content_sha,
      raw_supplement,
      hash(raw_supplement),
      raw_proof,
      hash(raw_proof),
      proof["admitted_at"]
    ])

    assert {:ok, journal} = TicketCiRepairSuccessor.journal(ctx.store, key)
    assert journal.proof["prior_evidence"] == evidence
    assert journal.proof["accepted_outcome"]["kind"] == "BLOCKED_NO_EDIT_ACCEPTED_V1"
    assert Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key=?", [request]) == evidence
    assert :ok = Store.initialize(ctx.store)
    assert {:ok, ^journal} = TicketCiRepairSuccessor.journal(ctx.store, key)
    assert {:error, :ci_successor_applied_unproven} = TicketCiRepairSuccessor.applied(ctx.store, key)

    # Synthetic post-transfer boundary fixture, not evidence that the admission API executed.
    new_access = access |> Map.merge(%{"reservation_key" => "new-reservation", "request_key" => "new-request", "generation" => access["generation"] + 1, "acquired_at" => utc()})

    transfer = %{
      "kind" => "CI_EVIDENCE_SUCCESSOR_TRANSFER_V1",
      "ci_evidence_successor_key" => key,
      "old_request_key" => request,
      "old_reservation_key" => access["reservation_key"],
      "new_request_key" => "new-request",
      "new_reservation_key" => "new-reservation",
      "new_generation" => new_access["generation"],
      "disposition_key" => disposition_key,
      "output_sha256" => evidence["output_sha256"],
      "checkout_head_sha" => ctx.sha
    }

    Store.query!(ctx.store, "UPDATE workspace_access SET released_at=?,release_receipt_json=? WHERE reservation_key=?", [utc(), Jason.encode!(transfer), access["reservation_key"]])
    insert_fixture_row(ctx.store, "workspace_access", new_access)
    old_binding = Jason.decode!(evidence["binding_json"])
    new_prompt_sha = hash("separate successor prompt")

    new_binding =
      Map.merge(old_binding, %{"reservation_key" => "new-reservation", "reservation_generation" => new_access["generation"], "prompt_sha256" => new_prompt_sha, "input_sha256" => new_prompt_sha})
      |> Jason.encode!()

    destination =
      evidence
      |> Map.merge(%{
        "request_key" => "new-request",
        "reservation_key" => "new-reservation",
        "binding_json" => new_binding,
        "binding_sha256" => hash(new_binding),
        "status" => "THREAD_BOUND",
        "turn_id" => nil,
        "output_json" => nil,
        "output_sha256" => nil,
        "item_id" => nil,
        "owner_stopped_at" => nil,
        "owner_stop_json" => nil
      })

    insert_fixture_row(ctx.store, "worker_evidence", destination)

    applied = %{
      "kind" => "CI_EVIDENCE_SUCCESSOR_APPLIED_V1",
      "successor_key" => key,
      "prior_request_key" => request,
      "new_request_key" => "new-request",
      "new_reservation_key" => "new-reservation",
      "new_generation" => new_access["generation"],
      "new_binding_sha256" => hash(new_binding),
      "proof_sha256" => hash(raw_proof),
      "evidence_sha256" => hash(raw_supplement),
      "attempt_index" => 2,
      "accepted_outcome_sha256" => hash(Jason.encode!(accepted))
    }

    Store.query!(ctx.store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_CI_REPAIR_SUCCESSOR_APPLIED','run',?)", [utc(), Jason.encode!(applied)])
    assert {:ok, applied_journal} = TicketCiRepairSuccessor.applied(ctx.store, key)
    assert applied_journal.destination == destination

    if export = System.get_env("CI_SUCCESSOR_EXPORT_DIR") do
      File.mkdir!(export)
      File.chmod!(export, 0o700)
      database = Path.join(export, "fixture.sqlite")
      Store.query!(ctx.store, "VACUUM INTO ?", [database])
      File.chmod!(database, 0o600)
      IO.puts("SYNTHETIC_PRODUCER_PARITY_DATABASE=#{database}")
    end

    # This isolated adversarial fixture deliberately disables only the new-row update trigger;
    # production admission never changes a journal row or an immutable claimed diagnosis.
    Store.query!(ctx.store, "DROP TRIGGER ci_successor_update")

    for forged <- [
          put_in(proof, ["inputs", "ticket_chat_questions"], [[]]),
          put_in(proof, ["authorization", "delivery_review"], true),
          put_in(proof, ["ci_snapshots", "mr", "iid"], 10),
          Map.delete(proof, "policy_receipt")
        ] do
      raw_forged = Jason.encode!(forged)
      Store.query!(ctx.store, "UPDATE ticket_ci_repair_evidence_successors SET proof_json=?,proof_sha256=? WHERE successor_key=?", [raw_forged, hash(raw_forged), key])
      assert {:error, :ci_successor_journal_unproven} = TicketCiRepairSuccessor.journal(ctx.store, key)
    end

    Store.query!(ctx.store, "UPDATE ticket_ci_repair_evidence_successors SET proof_json=?,proof_sha256=? WHERE successor_key=?", [raw_proof, hash(raw_proof), key])
    Store.query!(ctx.store, "DROP TRIGGER ci_repair_diagnosis_update")
    Store.query!(ctx.store, "UPDATE ticket_ci_repair_diagnoses SET preimage_json='{}',preimage_sha256=? WHERE diagnosis_key='diagnosis'", [hash("{}")])
    assert {:error, :ci_successor_journal_unproven} = TicketCiRepairSuccessor.journal(ctx.store, key)
    Store.query!(ctx.store, "UPDATE ticket_ci_repair_diagnoses SET preimage_json=?,preimage_sha256=? WHERE diagnosis_key='diagnosis'", [preimage, hash(preimage)])
    assert :ok = Store.initialize(ctx.store)
    assert {:ok, ^journal} = TicketCiRepairSuccessor.journal(ctx.store, key)
  end

  defp fixture_ci(sha) do
    %{
      "mr" => %{
        "project_id" => 123,
        "iid" => 9,
        "sha" => sha,
        "source_branch" => "cgable/fixture",
        "target_branch" => "master",
        "draft" => true,
        "reviewers" => [],
        "assignee" => %{"id" => 1},
        "force_remove_source_branch" => false,
        "web_url" => "https://example/mr/9"
      },
      "pipeline" => %{"id" => 99, "project_id" => 123, "sha" => sha, "ref" => "cgable/fixture", "source" => "merge_request_event", "status" => "failed", "web_url" => "https://example/pipeline/99"},
      "jobs" => [%{"id" => 7, "name" => "tests", "status" => "failed", "allow_failure" => false, "web_url" => "https://example/job/7", "pipeline" => %{"id" => 99, "project_id" => 123, "sha" => sha}}]
    }
  end

  defp insert_fixture_row(store, table, row) do
    pairs = Enum.sort(row)
    columns = Enum.map_join(pairs, ",", &elem(&1, 0))
    placeholders = Enum.map_join(pairs, ",", fn _ -> "?" end)
    Store.query!(store, "INSERT INTO #{table}(#{columns}) VALUES (#{placeholders})", Enum.map(pairs, &elem(&1, 1)))
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp utc, do: DateTime.utc_now() |> DateTime.to_iso8601()

  test "complete fifteen-column row hash matches sorted Unicode UTF-8 physical encoding" do
    keys =
      ~w(successor_key run_id claim_key prior_request_key prior_successor_key attempt_index configured_limit evidence_content_sha256 evidence_json evidence_sha256 proof_json proof_sha256 new_request_key new_reservation_key created_at)

    row = Map.new(keys, &{&1, nil}) |> Map.merge(%{"successor_key" => "succ-é", "evidence_json" => "{\"text\":\"测试\\n\"}", "attempt_index" => 4, "configured_limit" => 5})
    assert {:ok, "7747f3c93989a2ae61af3f70922f7968ce72dd7f0912cbb6346d03e2be275552"} = TicketCiRepairSuccessor.row_sha256(row)
    assert {:error, :ci_successor_row_unproven} = TicketCiRepairSuccessor.row_sha256(Map.delete(row, "created_at"))
    assert {:error, :ci_successor_row_unproven} = TicketCiRepairSuccessor.row_sha256(Map.put(row, "extra", "not projected away"))
  end

  test "only complete exact-job member content advances evidence identity" do
    artifact = %{
      "job_id" => 7,
      "status" => "PARTIAL",
      "provenance" => %{"metadata_arguments" => %{"project_id" => "123", "job_id" => "7"}, "archive_sha256" => String.duplicate("a", 64), "owned_reader" => %{"exit_status" => 0}},
      "members" => [%{"path" => "tests/failure.log.gz", "sha256" => String.duplicate("b", 64), "text" => "test assertion evidence", "complete" => true}],
      "gaps" => [%{"code" => "PROFILE_OUTPUT_LIMIT"}]
    }

    assert {:ok, content, identity} = TicketCiRepairSuccessor.evidence_content([artifact], 123, [7])
    relocated = put_in(artifact, ["provenance", "download_root"], "/private/other/cache")
    assert {:ok, ^content, ^identity} = TicketCiRepairSuccessor.evidence_content([relocated], 123, [7])
    renamed = Enum.map(content, &Map.put(&1, "path", "renamed/failure.log.gz"))
    refute TicketCiRepairSuccessor.new_content?(renamed, content)
    assert TicketCiRepairSuccessor.new_content?(content, [])
    another = Enum.map(content, &Map.put(&1, "text_sha256", String.duplicate("c", 64)))
    third = Enum.map(content, &Map.put(&1, "text_sha256", String.duplicate("d", 64)))
    refute TicketCiRepairSuccessor.new_content?(content ++ third, content ++ another ++ third)
    changed = put_in(artifact, ["members", Access.at(0), "text"], "different actual assertion")
    assert {:ok, _, changed_identity} = TicketCiRepairSuccessor.evidence_content([changed], 123, [7])
    refute changed_identity == identity
    assert {:error, :ci_successor_complete_evidence_unavailable} = TicketCiRepairSuccessor.evidence_content([put_in(artifact, ["members", Access.at(0), "complete"], false)], 123, [7])
    assert {:error, :ci_successor_complete_evidence_unavailable} = TicketCiRepairSuccessor.evidence_content([artifact], 124, [7])
    assert {:error, :ci_successor_complete_evidence_unavailable} = TicketCiRepairSuccessor.evidence_content([artifact], 123, [8])
    lossy = put_in(artifact, ["members", Access.at(0), "text"], "assertion \uFFFD")
    assert {:error, :ci_successor_complete_evidence_unavailable} = TicketCiRepairSuccessor.evidence_content([lossy], 123, [7])

    for path <- ["../failure.log.gz", "/failure.log.gz", "tests//failure.log.gz", "tests/./failure.log.gz", "tests\\failure.log.gz"] do
      unsafe = put_in(artifact, ["members", Access.at(0), "path"], path)
      assert {:error, :ci_successor_complete_evidence_unavailable} = TicketCiRepairSuccessor.evidence_content([unsafe], 123, [7])
    end
  end

  test "stable CI identity ignores observation time but not routing, human fields, or duplicate jobs" do
    snapshots = %{
      "mr" => %{
        "project_id" => 123,
        "iid" => 9,
        "sha" => "sha",
        "source_branch" => "source",
        "target_branch" => "main",
        "draft" => true,
        "reviewers" => [],
        "assignee" => %{"id" => 1, "username" => "display"},
        "force_remove_source_branch" => false,
        "web_url" => "https://example/mr/9"
      },
      "pipeline" => %{"id" => 6, "project_id" => 123, "sha" => "sha", "ref" => "source", "source" => "merge_request_event", "status" => "failed", "web_url" => "https://example/pipeline/6"},
      "jobs" => [%{"id" => 7, "name" => "tests", "status" => "failed", "allow_failure" => false, "web_url" => "https://example/job/7", "pipeline" => %{"id" => 6, "project_id" => 123, "sha" => "sha"}}]
    }

    assert {:ok, identity} = TicketCiRepairSuccessor.snapshot_identity(snapshots)
    assert {:ok, ^identity} = TicketCiRepairSuccessor.snapshot_identity(Map.put(snapshots, "checked_at", "later"))
    assert {:ok, changed} = TicketCiRepairSuccessor.snapshot_identity(put_in(snapshots, ["mr", "iid"], 10))
    refute identity == changed
    assert {:error, :ci_successor_snapshot_unproven} = TicketCiRepairSuccessor.snapshot_identity(put_in(snapshots, ["mr", "reviewers"], [%{"id" => 2}]))
    assert {:error, :ci_successor_snapshot_unproven} = TicketCiRepairSuccessor.snapshot_identity(Map.put(snapshots, "jobs", snapshots["jobs"] ++ snapshots["jobs"]))
  end

  test "schema48 successor journal is append-only and total attempts include all claims" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    assert Store.one!(ctx.store, "SELECT version FROM factory_schema_migrations WHERE version=48")["version"] == 48
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 0
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    assert :ok = Store.initialize(ctx.store)
  end

  test "archived input snapshot uses actual schema widths and eligibility, including REAL timestamps" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    run = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id='run'")
    assert {:ok, inputs} = SymphonyElixir.Factory.TicketCiRepair.input_snapshot(ctx.store, "run")
    assert :ok = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, inputs)
    assert {:error, :ci_successor_archived_inputs_unproven} = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, Map.put(inputs, "ticket_chat_questions", [[]]))
    assert {:error, :ci_successor_archived_inputs_unproven} = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, put_in(inputs, ["parent", "repo_key"], "foreign"))
    assert {:error, :ci_successor_archived_inputs_unproven} = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, put_in(inputs, ["bootstrap", "status"], "PENDING"))
    assert {:error, :ci_successor_archived_inputs_unproven} = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, put_in(inputs, ["parent", "extra"], "unknown"))

    rows = fn table, overrides ->
      Store.query!(ctx.store, "PRAGMA table_info(#{table})").rows
      |> Enum.map(fn [_cid, name, type, required | _] ->
        Map.get_lazy(overrides, name, fn ->
          cond do
            name == "run_id" -> "run"
            name == "chat_key" -> inputs["parent"]["chat_key"]
            required == 0 -> nil
            type == "REAL" -> 1_700_000_000.125
            type == "INTEGER" -> 1
            true -> "fixture"
          end
        end)
      end)
    end

    question = rows.("ticket_chat_questions", %{"question_key" => "q", "status" => "ANSWERED"})
    native = rows.("ticket_chat_inputs", %{"input_key" => "i", "origin" => "NATIVE_CLIENT_INPUT"})
    archived = inputs |> Map.put("ticket_chat_questions", [question]) |> Map.put("inputs", [native])
    assert :ok = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, archived)

    for {table, row} <- [
          {"ticket_chat_questions", rows.("ticket_chat_questions", %{"question_key" => "q", "status" => "OPEN"})},
          {"ticket_chat_commands", rows.("ticket_chat_commands", %{"command_key" => "c", "status" => "PENDING"})},
          {"ticket_contract_amendments", rows.("ticket_contract_amendments", %{"command_key" => "c", "active_owner" => 1})}
        ] do
      assert {:error, :ci_successor_archived_inputs_unproven} = TicketCiRepairSuccessor.validate_archived_inputs(ctx.store, run, Map.put(inputs, table, [row]))
    end
  end

  test "seven spent historical cycles leave exactly three of ten across claims and successors" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    seed_claims(ctx.store)
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 3
    insert_successor(ctx.store, 4, 5)
    insert_successor(ctx.store, 5, 5)
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 5
    assert_raise Exqlite.Error, fn -> insert_successor(ctx.store, 6, 5) end
    insert_successor(ctx.store, 6, 7)
    insert_successor(ctx.store, 7, 7)
    before = Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_evidence_successors ORDER BY rowid").rows
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 7
    assert_raise Exqlite.Error, fn -> insert_successor(ctx.store, 8, 7) end
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('eighth','diagnosis4','run',4,'{}','hash','now')")
    insert_successor(ctx.store, 9, 10)
    insert_successor(ctx.store, 10, 10)
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 10
    assert Enum.take(Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_evidence_successors ORDER BY rowid").rows, length(before)) == before

    results =
      for _ <- 1..2 do
        Task.async(fn ->
          try do
            Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('eleventh','diagnosis5','run',5,'{}','hash','now')")
            :unexpected_acceptance
          rescue
            Exqlite.Error -> :refused
          end
        end)
      end

    assert Enum.map(results, &Task.await/1) == [:refused, :refused]
    all_rows = Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_evidence_successors ORDER BY rowid").rows

    for sql <- ["UPDATE ticket_ci_repair_evidence_successors SET proof_json='changed'", "DELETE FROM ticket_ci_repair_evidence_successors", "DELETE FROM factory_schema_migrations WHERE version=48"] do
      assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql) end
    end

    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_evidence_successors ORDER BY rowid").rows == all_rows
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
  end

  test "lower configured admission limit is enforced in SQL", _ctx do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    seed_claims(ctx.store)
    assert_raise Exqlite.Error, fn -> insert_successor(ctx.store, 4, 3) end
    assert TicketCiRepairSuccessor.attempts_used(ctx.store, "run") == 3
  end

  test "schema48 failure rolls back its additive objects and restart is idempotent" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    triggers = ~w(ci_successor_update ci_successor_delete ci_successor_schema_rollback ci_successor_total_budget ci_claim_total_budget)
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version=48")
    for name <- triggers, do: Store.query!(ctx.store, "DROP TRIGGER #{name}")
    Store.query!(ctx.store, "DROP TABLE ticket_ci_repair_evidence_successors")
    Store.query!(ctx.store, "CREATE TRIGGER fail_schema48 BEFORE INSERT ON factory_schema_migrations WHEN NEW.version=48 BEGIN SELECT RAISE(ABORT,'fixture migration failure'); END")
    before = Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows
    claims = Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows
    assert_raise Exqlite.Error, fn -> Store.initialize(ctx.store) end
    assert Store.query!(ctx.store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows == before
    assert Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows == claims
    assert Store.one!(ctx.store, "SELECT version FROM factory_schema_migrations WHERE version=48") == nil
    assert Store.query!(ctx.store, "PRAGMA foreign_key_check").rows == []
    Store.query!(ctx.store, "DROP TRIGGER fail_schema48")
    assert :ok = Store.initialize(ctx.store)
    assert :ok = Store.initialize(ctx.store)
    assert Store.one!(ctx.store, "SELECT version FROM factory_schema_migrations WHERE version=48")["version"] == 48
  end

  defp seed_claims(store) do
    Store.query!(
      store,
      "INSERT INTO factory_tasks(task_key,run_id,stage,role,status,model_provider,model_class,model,reasoning_effort,routing_reason,prompt_sha256,created_at,updated_at) VALUES('successor-task','run','REPAIRING','feature-writer','COMPLETE','fixture','fixture','fixture','high','fixture','hash','now','now')"
    )

    for index <- 1..11 do
      Store.query!(store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?, 'run','candidate',?, '{}','hash','{}','hash','REPAIRABLE','now')", ["diagnosis#{index}", index])

      Store.query!(
        store,
        "INSERT INTO workspace_access(reservation_key,run_id,task_key,request_key,mode,generation,canonical_path,git_dir,common_dir,binding_json,acquired_at,released_at) VALUES(?,'run','successor-task',?,'SOURCE',?,'/fixture','/fixture/git','/fixture/git','{}','now','now')",
        ["reservation#{index}", "request#{index}", index]
      )

      Store.query!(
        store,
        "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,owner_id,created_at) VALUES(?,'successor-task','run',?,'{}','hash','RESULT_RECORDED','fixture','now')",
        ["request#{index}", "reservation#{index}"]
      )

      if index <= 3, do: Store.query!(store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,'run',?,'{}','hash','now')", ["claim#{index}", "diagnosis#{index}", index])
    end
  end

  defp insert_successor(store, index, limit) do
    Store.query!(store, "INSERT INTO ticket_ci_repair_evidence_successors VALUES (?,'run','claim3',?,NULL,?,?,?,'[]','hash','{}','hash',?,?,'now')", [
      "successor#{index}",
      "request#{index}",
      index,
      limit,
      "content#{index}",
      "newrequest#{index}",
      "newreservation#{index}"
    ])
  end
end
