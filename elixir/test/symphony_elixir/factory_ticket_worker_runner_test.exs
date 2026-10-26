defmodule SymphonyElixir.FactoryTicketWorkerRunnerTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture

  alias SymphonyElixir.Factory.{
    Contract,
    ControlServer,
    Observability,
    ReviewProtocol,
    RunLedger,
    Scheduler,
    StageSchemas,
    Store,
    TaskLauncher,
    TaskLedger,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerInstructions,
    WorkspaceAccess
  }

  alias SymphonyElixir.Tracker.Issue
  setup :setup_fixture

  defmodule FakeWorkerServer do
    def start_session(workspace, opts) do
      send(self(), {:worker_options, opts})
      thread = Process.get(:worker_thread, "worker")
      opts[:on_thread_created].(thread)

      if Process.get(:fail_start),
        do: {:error, :connector_catalog_not_empty},
        else:
          {:ok,
           %{
             thread_id: thread,
             worker_policy: Process.get(:observed_policy, TicketWorkerRunner.policy(opts[:worker_access], workspace)),
             worker_invocation: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
             metadata: %{codex_app_server_pid: "fixture"}
           }}
    end

    def run_turn(session, prompt, _issue, opts) do
      send(self(), {:worker_prompt, prompt})
      turn = Process.get(:worker_turn, "turn")
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
      output = Process.get(:worker_output, %{"status" => "PASS"})

      opts[:on_message].(%{
        payload: %{
          "method" => Process.get(:worker_item_method, "item/completed"),
          "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
        }
      })

      {:ok, %{turn_id: turn}}
    end

    def stop_session(session) do
      send(self(), :owned_session_stopped)
      Process.put(:owned_session, session)

      if Process.get(:fail_stop),
        do: {:error, :shutdown_unproven},
        else:
          {:ok,
           %{
             "transport" => "owned_app_server",
             "thread_id" => session.thread_id,
             "pid" => "fixture",
             "invocation_nonce" => session.worker_invocation,
             "exit_status" => 0,
             "cwd" => session.worker_policy["cwd"]
           }}
    end
  end

  defp prepare(ctx, role \\ "feature-writer") do
    bind_parent(ctx)

    if ctx[:structured_writer] do
      {contract, snapshot} = SymphonyElixir.TicketChatFixture.authorized_contract("PPL-123", "issue-id", "AC-1: fixture behavior.\n\n## Manual Validation\n- Required: no")
      {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_markdown: contract.markdown, contract_sha256: contract.sha256, snapshot_json: Jason.encode!(snapshot)})
    end

    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", role, ctx.sha)
    sha = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{role: role, prompt_sha256: sha})

    if ctx[:structured_writer] do
      TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})
      :ok = WorkerInstructions.bind_task(ctx.store, "writer", sha, Jason.decode!(prompt)["instruction_binding_sha256"])
    end

    mode = if role == "feature-writer", do: "SOURCE", else: "REVIEW"
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, mode), opts(ctx))

    options = [
      store: ctx.store,
      target_key: "writer",
      request_key: "reservation:request",
      reservation_key: "reservation",
      owner_id: "owned-invocation",
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      app_server: FakeWorkerServer,
      review_base_sha: ctx.sha
    ]

    {prompt, options}
  end

  @tag structured_writer: true
  test "stopped rejected reports are visible read-only and disappear after consumption or generation drift", ctx do
    {prompt, options} = prepare(ctx)
    packet = Jason.decode!(prompt)
    report = %{"version" => 2, "candidate_sha" => ctx.sha, "block_reason" => "NONE", "criteria" => [], "closures" => [], "boundary_sweeps" => [], "findings" => []}
    output = %{"status" => "CONTINUE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => [], "review_report" => report}
    Process.put(:worker_output, output)
    schema = ReviewProtocol.schema(packet, StageSchemas.for_stage(:native_feature_writer))
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema, options)
    {:ok, pending} = WorkerEvidence.get(ctx.store, "reservation:request")
    {:ok, _} = TaskLedger.update(ctx.store, "writer", Map.merge(Map.take(pending, ~w(output_json thread_id turn_id)), %{"status" => "COMPLETE"}))
    {:ok, run} = RunLedger.get(ctx.store, "run")
    before = Store.query!(ctx.store, "SELECT id FROM events ORDER BY id").rows
    assert %{reason: "review_report_criteria_incomplete", request_key: "reservation:request"} = ReviewProtocol.pending_status(ctx.store, run)
    assert %{reason: "review_report_criteria_incomplete"} = ReviewProtocol.pending_status(ctx.store, run)
    assert Store.query!(ctx.store, "SELECT id FROM events ORDER BY id").rows == before

    factory = %{enabled: true, scope: "fixture", dispatcher_id: "fixture", lease_seconds: 240, repositories: %{}}
    factory = Map.merge(factory, %{maximum_specifiers: 2, maximum_validators: 2})
    factory = Map.merge(factory, %{maximum_writers: 2, writer_disk_gb: 20})
    server = start_supervised!({ControlServer, [store: ctx.store, factory: factory, name: nil]})
    snapshot = Observability.snapshot(settings: %{factory: factory}, store: ctx.store, control_server: server)
    assert [%{attention: %{source: "WORKER_RESULT", phase: "REPORT_REJECTED", next_action: action}}] = snapshot.current_runs
    assert action =~ "Factory intervention"
    assert action =~ "Do not restart"

    Store.query!(ctx.store, "UPDATE worker_evidence SET status='CONSUMED' WHERE request_key='reservation:request'")
    assert is_nil(ReviewProtocol.pending_status(ctx.store, run))
    Store.query!(ctx.store, "UPDATE worker_evidence SET status='RESULT_RECORDED',binding_sha256='corrupt' WHERE request_key='reservation:request'")
    assert is_nil(ReviewProtocol.pending_status(ctx.store, run))
    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_sha256=? WHERE request_key='reservation:request'", [pending["binding_sha256"]])
    assert is_nil(ReviewProtocol.pending_status(ctx.store, Map.put(run, "candidate_sha", String.duplicate("0", 40))))
    assert is_nil(ReviewProtocol.pending_status(ctx.store, Map.put(run, "contract_sha256", String.duplicate("0", 64))))
    assert is_nil(ReviewProtocol.pending_status(ctx.store, Map.put(run, "state", "VERIFYING")))
    assert is_nil(ReviewProtocol.pending_status(ctx.store, Map.update!(run, "verifier_round", &(&1 + 1))))
    assert is_nil(ReviewProtocol.pending_status(ctx.store, Map.update!(run, "implementation_iteration", &(&1 + 1))))
    assert %{reason: "review_report_criteria_incomplete"} = ReviewProtocol.pending_status(ctx.store, run)
    Store.query!(ctx.store, "UPDATE factory_tasks SET turn_id='different-turn' WHERE task_key='writer'")
    assert is_nil(ReviewProtocol.pending_status(ctx.store, run))
    Store.query!(ctx.store, "UPDATE factory_tasks SET turn_id=? WHERE task_key='writer'", [pending["turn_id"]])

    Store.query!(
      ctx.store,
      "INSERT INTO workspace_access(reservation_key,run_id,task_key,request_key,mode,generation,canonical_path,git_dir,common_dir,binding_json,acquired_at) VALUES('newer-reservation','run','writer','newer-attempt','SOURCE',2,'/fixture/newer','/fixture/newer/.git','/fixture/common','{}','2026-10-25T20:00:00Z')"
    )

    Store.query!(
      ctx.store,
      "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,owner_id,created_at) VALUES('newer-attempt','writer','run','newer-reservation','{}','none','RESERVED','fixture','2026-10-25T20:00:00Z')"
    )

    assert is_nil(ReviewProtocol.pending_status(ctx.store, run))
  end

  defp prepare_verifier(ctx, candidate \\ nil) do
    unless ctx[:parent_bound], do: bind_parent(ctx)
    candidate = candidate || ctx.sha
    criteria = if ctx[:structured_review], do: "AC-1: fixture behavior and boundary coverage.", else: "Updated verifier contract."
    contract = Contract.bind("PPL-123", 2, criteria <> "\n\n## Manual Validation\n- Required: no")
    {:ok, existing_run} = RunLedger.get(ctx.store, "run")
    snapshot = Jason.decode!(existing_run["snapshot_json"])
    snapshot = Map.put(snapshot, "comments", [%{"text" => Contract.draft_comment(contract)}, %{"text" => Contract.specification_skill_authorization_marker(contract)}])

    {:ok, _} =
      RunLedger.update(ctx.store, "run", %{
        state: "VERIFYING",
        candidate_sha: candidate,
        spec_revision: contract.revision,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        snapshot_json: Jason.encode!(snapshot)
      })

    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)

    prompt =
      if ctx[:legacy_report] do
        base = Jason.decode!(prompt) |> Map.drop(~w(shared_instructions instruction_delivery instruction_snapshot_sha256 instruction_binding_sha256)) |> put_in(["review_protocol", "version"], 1)
        {:ok, instructions} = WorkerInstructions.admit(ctx.store, base, "change-verifier", Path.join(System.user_home!(), ".agents"))
        Jason.encode!(Map.merge(base, instructions))
      else
        prompt
      end

    prompt_sha = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    key = ctx[:verifier_task_key] || "writer"
    request = ctx[:verifier_request_key] || "verifier:request"
    reservation = ctx[:verifier_reservation_key] || "verifier:reservation"

    if key != "writer" do
      {:ok, template} = TaskLedger.get(ctx.store, "writer")
      {:ok, _} = TaskLedger.register(ctx.store, Map.merge(template, %{"task_key" => key, "status" => "STARTING"}))
    end

    {:ok, _} = TaskLedger.update(ctx.store, key, %{stage: "VERIFYING", role: "change-verifier", prompt_sha256: prompt_sha, workspace_sha: candidate})

    if ctx[:structured_review] do
      assert :ok = WorkerInstructions.bind_task(ctx.store, key, prompt_sha, Jason.decode!(prompt)["instruction_binding_sha256"])
    end

    access = attrs(ctx, "REVIEW", reservation) |> Map.merge(%{"task_key" => key, "request_key" => request, "expected_sha" => candidate})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, access, opts(ctx))

    options = [
      store: ctx.store,
      target_key: key,
      request_key: request,
      reservation_key: reservation,
      owner_id: "verifier-owner",
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      app_server: FakeWorkerServer,
      review_base_sha: ctx.sha
    ]

    {prompt, options, candidate}
  end

  defp schema, do: %{"type" => "object", "required" => ["status"], "properties" => %{"status" => %{"type" => "string"}}}
  defp issue, do: %Issue{identifier: "PPL-123", title: "Fixture"}

  defp assert_nonpass_verifier(ctx, status) do
    {prompt, options, candidate} = prepare_verifier(ctx)
    Process.put(:worker_output, %{"status" => status, "candidate_sha" => candidate, "findings" => ["needs follow-up"], "checks" => []})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    run_before = RunLedger.get(ctx.store, "run")
    assert {:ok, %{evidence: evidence, output: output}} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    assert output["status"] == status
    assert evidence["request_key"] == "verifier:request"
    assert RunLedger.get(ctx.store, "run") == run_before
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "verifier:reservation")
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
  end

  test "missing Jira dispatch fields and decoded non-object authorization never admit source work", ctx do
    bind_parent(ctx)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    snapshot = Jason.decode!(run["snapshot_json"]) |> Map.merge(%{"labels" => ["ai-running"], "status" => "In Dev"})
    {:ok, proof} = TicketWorkerRunner.authorization(run, snapshot, DateTime.utc_now())

    for malformed <- [Map.delete(snapshot, "labels"), Map.put(snapshot, "labels", nil), Map.put(snapshot, "status", nil)] do
      assert {:error, :ticket_jira_not_dispatchable} =
               TicketWorkerRunner.authorization(run, malformed, DateTime.utc_now())
    end

    assert {:error, :ticket_authorization_invalid} =
             TicketWorkerRunner.validate_authorization(run, Map.put(proof, "snapshot_json", "[]"))

    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  test "writer admission facts reject a malformed reservation without changing prepared state", ctx do
    {_prompt, options} = prepare(ctx)
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "ADMITTING_WRITER"})
    assert {:ok, run} = RunLedger.get(ctx.store, "run")

    protected_tables =
      ~w(runs factory_tasks workspace_access worker_evidence ticket_review_bases ticket_chats ticket_chat_runs desktop_requests ticket_chat_commands ticket_chat_inputs ticket_chat_questions ticket_checkout_intents worker_file_operations controller_checks events)

    protected_before = Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end)
    source_file = Path.join(ctx.path, "fixture.txt")
    source_index = Path.join(String.trim(git(ctx.path, ["rev-parse", "--absolute-git-dir"])), "index")
    source_before = File.read!(source_file)
    index_before = File.read!(source_index)
    head_before = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    bad_options = options |> Keyword.put(:workspace_root, Path.join(ctx.root, "workspaces")) |> Keyword.put(:reservation, %{})

    assert {:error, :ticket_delivery_reservation_invalid} = TicketWorkerRunner.writer_admission_facts(ctx.store, run, bad_options)

    assert Map.new(protected_tables, fn table -> {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows} end) == protected_before
    assert File.read!(source_file) == source_before
    assert File.read!(source_index) == index_before
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == head_before
    refute_received {:worker_options, _}
    refute_received :owned_session_stopped
  end

  test "a schema-valid BLOCKED writer result remains unconsumed and does not publish a candidate", ctx do
    {prompt, options} = prepare(ctx)
    assert {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})

    output = %{
      "status" => "BLOCKED",
      "summary" => "A prerequisite is unresolved.",
      "changed_paths" => ["fixture.txt"],
      "commit_message" => nil,
      "remaining_criteria" => [],
      "next_slice" => "Resolve the blocking prerequisite.",
      "blockers" => ["A required prerequisite is unavailable."],
      "checks" => []
    }

    Process.put(:worker_output, output)
    {:ok, run_before} = RunLedger.get(ctx.store, "run")
    source_file = Path.join(ctx.path, "fixture.txt")
    source_index = Path.join(String.trim(git(ctx.path, ["rev-parse", "--absolute-git-dir"])), "index")
    source_before = File.read!(source_file)
    index_before = File.read!(source_index)
    head_before = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, result} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:native_feature_writer), options)
    assert result.output == output
    assert_received {:worker_options, worker_options}
    assert worker_options[:worker_access] == "FILE_SOURCE"
    assert_received {:worker_prompt, ^prompt}
    assert_received :owned_session_stopped

    {:ok, task_before_adoption} = TaskLedger.get(ctx.store, "writer")
    evidence_before_adoption = WorkerEvidence.get(ctx.store, "reservation:request")
    access_before_adoption = WorkspaceAccess.get(ctx.store, "reservation")
    checks_before_adoption = Store.query!(ctx.store, "SELECT * FROM controller_checks ORDER BY 1").rows

    assert {:ok, evidence} = evidence_before_adoption
    assert evidence["status"] == "RESULT_RECORDED"
    output_json = evidence["output_json"]
    assert Jason.decode!(output_json) == output
    assert {:ok, %{"released_at" => nil} = access} = access_before_adoption

    assert {:error, :ticket_writer_blocked} = TicketWorkerRunner.adoption(ctx.store, "reservation:request")

    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert {:ok, ^evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert evidence["status"] == "RESULT_RECORDED"
    assert evidence["output_json"] == output_json
    assert {:ok, access_after} = WorkspaceAccess.get(ctx.store, "reservation")
    assert access_after == access

    assert {:ok, task_after} = TaskLedger.get(ctx.store, "writer")
    assert task_after["status"] == "COMPLETE"
    assert task_after["failure_code"] == nil

    assert Map.drop(task_after, ["status", "updated_at", "thread_id", "turn_id", "output_json", "failure_code"]) ==
             Map.drop(task_before_adoption, ["status", "updated_at", "thread_id", "turn_id", "output_json", "failure_code"])

    assert Store.query!(ctx.store, "SELECT * FROM controller_checks ORDER BY 1").rows == checks_before_adoption
    assert File.read!(source_file) == source_before
    assert File.read!(source_index) == index_before
    assert git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim() == head_before
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
  end

  test "unsupported stored role rejects before output schema or candidate adoption", ctx do
    {prompt, options} = prepare(ctx)
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, task} = TaskLedger.update(ctx.store, "writer", %{role: "unsupported"})
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert {:error, :ticket_role_stage_not_admitted} = TicketWorkerRunner.adoption(ctx.store, "reservation:request")
    assert {:ok, ^task} = TaskLedger.get(ctx.store, "writer")
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
    assert {:ok, ^evidence} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "START_SENT evidence without an owner returns typed not-ready without adoption", ctx do
    {prompt, _options} = prepare(ctx)
    request = "reservation:request"
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})

    assert {:ok, evidence} =
             WorkerEvidence.reserve(ctx.store, %{
               "request_key" => request,
               "task_key" => "writer",
               "reservation_key" => "reservation",
               "input_sha256" => :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower),
               "owner_id" => "owner:" <> request,
               "schema" => StageSchemas.for_stage(:native_feature_writer),
               "policy" => TicketWorkerRunner.policy("SOURCE", ctx.path)
             })

    assert {:ok, started} = WorkerEvidence.mark_start_sent(ctx.store, request)
    assert started["status"] == "START_SENT"
    assert {started["request_key"], started["binding_sha256"]} == {evidence["request_key"], evidence["binding_sha256"]}
    assert TaskLauncher.active_owner("writer") == nil
    before_run = RunLedger.get(ctx.store, "run")
    before_task = TaskLedger.get(ctx.store, "writer")
    before_access = WorkspaceAccess.get(ctx.store, "reservation")
    assert {:error, :worker_not_ready_for_consumption} = TicketWorkerRunner.adoption(ctx.store, request)
    assert RunLedger.get(ctx.store, "run") == before_run
    assert TaskLedger.get(ctx.store, "writer") == before_task
    assert WorkerEvidence.get(ctx.store, request) == {:ok, started}
    assert WorkspaceAccess.get(ctx.store, "reservation") == before_access
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
  end

  test "START_SENT evidence with a decoded non-object output rejects without changing evidence or access", ctx do
    {prompt, _options} = prepare(ctx)
    request = "reservation:request"
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{stage: "WRITING"})

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => request,
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "input_sha256" => :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower),
        "owner_id" => "owner:" <> request,
        "schema" => StageSchemas.for_stage(:native_feature_writer),
        "policy" => TicketWorkerRunner.policy("SOURCE", ctx.path)
      })

    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, request)
    output_json = "[]"
    output_sha256 = :crypto.hash(:sha256, output_json) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE worker_evidence SET output_json = ?, output_sha256 = ? WHERE request_key = ?", [output_json, output_sha256, request])
    evidence_before = WorkerEvidence.get(ctx.store, request)
    access_before = WorkspaceAccess.get(ctx.store, "reservation")
    task_before = TaskLedger.get(ctx.store, "writer")
    run_before = RunLedger.get(ctx.store, "run")

    assert {:error, :worker_output_invalid} = TicketWorkerRunner.adoption(ctx.store, request)
    assert WorkerEvidence.get(ctx.store, request) == evidence_before
    assert WorkspaceAccess.get(ctx.store, "reservation") == access_before
    assert TaskLedger.get(ctx.store, "writer") == task_before
    assert RunLedger.get(ctx.store, "run") == run_before
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
  end

  test("REPAIR verifier adoption retains the non-PASS result without changing candidate", ctx, do: assert_nonpass_verifier(ctx, "REPAIR"))

  test("BLOCK verifier adoption retains the non-PASS result without changing candidate", ctx, do: assert_nonpass_verifier(ctx, "BLOCK"))

  @tag structured_review: true
  test "controller admits two repairs across fresh reviews then durably stops without changing REPAIR", ctx do
    assert_structured_loop(ctx, 2, "REPAIR_LIMIT")
  end

  @tag structured_review: true
  test "controller stops early when independent review leaves a prior finding unresolved", ctx do
    assert_structured_loop(ctx, 1, "UNRESOLVED_FINDING")
  end

  defp assert_structured_loop(ctx, last_round, reason) do
    context = %{store: ctx.store, workspace_root: Path.join(ctx.root, "workspaces"), factory: %{maximum_code_repair_rounds: 25}}
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})

    for round <- 0..last_round do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING", verifier_round: round})
      if round == 1, do: RunLedger.update(ctx.store, "run", %{code_repair_round: 11})
      {:ok, before} = RunLedger.get(ctx.store, "run")
      current = Map.merge(ctx, %{parent_bound: round > 0, verifier_task_key: "run:change-verifier:#{round}", verifier_request_key: "review:#{round}", verifier_reservation_key: "reservation:#{round}"})
      Process.put(:worker_thread, "review-thread-#{round}")
      {prompt, options, candidate} = prepare_verifier(current)
      packet = Jason.decode!(prompt)
      assert packet["review_protocol"]["repairs_used"] == round
      output = structured_repair(packet, candidate, "new finding #{round}")

      output =
        if reason == "UNRESOLVED_FINDING" and round == last_round do
          output |> put_in(["review_report", "closures", Access.at(0), "status"], "UNRESOLVED") |> put_in(["review_report", "findings", Access.at(0), "classification"], "UNRESOLVED")
        else
          output
        end

      Process.put(:worker_output, output)
      schema = ReviewProtocol.schema_json(prompt, StageSchemas.for_stage(:change_verifier))
      assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema, options)
      assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", opts(ctx))
      assert run["state"] == if(round < last_round, do: "REPAIRING", else: "FAILED")
      assert run["code_repair_round"] == before["code_repair_round"] + if(round < last_round, do: 1, else: 0)
      assert {:ok, evidence} = WorkerEvidence.get(ctx.store, "review:#{round}")
      assert evidence["status"] == "CONSUMED" and Jason.decode!(evidence["output_json"])["status"] == "REPAIR"
    end

    decisions = Store.query!(ctx.store, "SELECT payload_json FROM events WHERE event_type='TICKET_REVIEW_DECISION' ORDER BY id").rows |> Enum.map(fn [raw] -> Jason.decode!(raw) end)
    assert Enum.map(decisions, & &1["result"]) == List.duplicate("REPAIR_ADMITTED", last_round) ++ ["POLICY_STOPPED"]
    assert List.last(decisions)["repairs_used_after"] == last_round
    assert List.last(decisions)["stop"]["reason"] == reason
    {:ok, run} = RunLedger.get(ctx.store, "run")
    assert String.starts_with?(run["last_error"], "{:verification_policy_stopped,")
    assert %{kind: "REVIEW_POLICY", recorded_ci: "NOT_PROVEN"} = ReviewProtocol.status(ctx.store, run)
    passed = Map.put(run, "ci_evidence_json", Jason.encode!(%{"status" => "PASS", "sha" => run["candidate_sha"]}))
    assert %{recorded_ci: "PASSED"} = ReviewProtocol.status(ctx.store, passed)
    stale = Map.put(run, "ci_evidence_json", Jason.encode!(%{"status" => "PASS", "sha" => "another-candidate"}))
    assert %{recorded_ci: "NOT_PROVEN"} = ReviewProtocol.status(ctx.store, stale)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      result = Scheduler.ticket_step(%{context | store: reopened}, "run", opts(ctx))
      assert {:error, :ticket_role_stage_not_admitted} = result
      assert {:ok, ^run} = RunLedger.get(reopened, "run")
      rows = Store.query!(reopened, "SELECT id FROM events WHERE event_type='TICKET_REVIEW_DECISION'").rows
      assert length(rows) == last_round + 1
    after
      GenServer.stop(reopened)
    end
  end

  @tag structured_review: true
  test "combined code-repair exhaustion is a distinct policy stop and cannot spend a review repair", ctx do
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})
    ctx = Map.put(ctx, :verifier_task_key, "run:change-verifier:0")
    {prompt, options, candidate} = prepare_verifier(ctx)
    Process.put(:worker_output, structured_repair(Jason.decode!(prompt), candidate, "new finding"))
    schema = ReviewProtocol.schema_json(prompt, StageSchemas.for_stage(:change_verifier))
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema, options)
    context = %{store: ctx.store, workspace_root: Path.join(ctx.root, "workspaces"), factory: %{maximum_code_repair_rounds: 0}}
    assert {:ok, %{status: "ADOPTED", run: stopped}} = Scheduler.ticket_step(context, "run", opts(ctx))
    assert %{kind: "REVIEW_POLICY", title: "Combined repair limit reached"} = ReviewProtocol.status(ctx.store, stopped)
    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_REVIEW_DECISION'").rows == []
    assert {:ok, evidence} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert Jason.decode!(evidence["output_json"])["status"] == "REPAIR"
    assert stopped["code_repair_round"] == 0
  end

  @tag structured_review: true
  test "new review rejects schema downgrade before native start", ctx do
    {prompt, options, _} = prepare_verifier(ctx)
    assert {:error, :review_protocol_schema_changed} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    refute_received {:worker_options, _}
    assert {:error, :unknown_worker_attempt} = WorkerEvidence.get(ctx.store, "verifier:request")
  end

  @tag structured_review: true
  test "policy decision rolls back together with consumption when transition persistence fails", ctx do
    {prompt, options, candidate} = prepare_verifier(ctx)
    packet = Jason.decode!(prompt)
    Process.put(:worker_output, structured_repair(packet, candidate, "new finding"))
    schema = ReviewProtocol.schema_json(prompt, StageSchemas.for_stage(:change_verifier))
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema, options)
    assert {:ok, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    before = verifier_adoption_records(ctx.store)
    Store.query!(ctx.store, "CREATE TEMP TRIGGER refuse_review_policy BEFORE UPDATE OF state ON runs WHEN NEW.state='REPAIRING' BEGIN SELECT RAISE(ABORT,'synthetic review policy failure'); END")
    context = %{store: ctx.store, workspace_root: Path.join(ctx.root, "workspaces"), factory: %{maximum_code_repair_rounds: 25}}
    assert_raise Exqlite.Error, ~r/synthetic review policy failure/, fn -> Scheduler.ticket_step(context, "run", opts(ctx)) end
    assert verifier_adoption_records(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_REVIEW_DECISION'").rows == []
    Store.query!(ctx.store, "DROP TRIGGER refuse_review_policy")
    assert {:ok, %{status: "ADOPTED"}} = Scheduler.ticket_step(context, "run", opts(ctx))
    assert length(Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_REVIEW_DECISION'").rows) == 1
  end

  defp structured_repair(packet, candidate, finding) do
    rows = fn ids, status -> Enum.map(ids, &%{"id" => &1, "status" => status, "evidence" => ["fixture.txt:1; tested success and failure boundary"]}) end
    protocol = packet["review_protocol"]

    result = %{
      "status" => "REPAIR",
      "candidate_sha" => candidate,
      "findings" => [finding],
      "checks" => [],
      "review_report" => %{
        "version" => protocol["version"],
        "candidate_sha" => candidate,
        "block_reason" => "NONE",
        "criteria" => rows.(protocol["criterion_ids"], "FAIL"),
        "closures" => rows.(Enum.map(protocol["finding_obligations"], & &1["id"]), "ADDRESSED"),
        "boundary_sweeps" => Enum.map(rows.(protocol["criterion_ids"], "CHECKED"), &Map.put(&1, "paths", ["fixture.txt"])),
        "finding_classifications" => [%{"finding" => finding, "classification" => "NEW"}]
      }
    }

    if protocol["version"] == 2 do
      prior = List.first(protocol["finding_obligations"])

      row = %{
        "id" => if(prior, do: prior["id"], else: "F-1"),
        "description" => finding,
        "classification" => if(prior, do: "REGRESSION", else: "NEW"),
        "disposition" => "REQUIRED_REPAIR",
        "basis" => if(prior && prior["basis"], do: prior["basis"], else: %{"kind" => "ACCEPTANCE_CRITERION", "reference" => "AC-1"})
      }

      result |> Map.delete("findings") |> update_in(["review_report"], &(Map.delete(&1, "finding_classifications") |> Map.put("findings", [row])))
    else
      result
    end
  end

  @tag structured_review: true, legacy_report: true
  test "one explicit report-only mapping survives adoption and reopen without rewriting raw evidence", ctx do
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})
    ctx = Map.put(ctx, :verifier_task_key, "run:change-verifier:0")
    {prompt, options, candidate} = prepare_verifier(ctx)

    original =
      structured_repair(Jason.decode!(prompt), candidate, "Detailed genuine mandatory privacy finding")
      |> put_in(["review_report", "finding_classifications", Access.at(0), "finding"], "Short summary")

    Process.put(:worker_output, original)
    schema = ReviewProtocol.schema_json(prompt, StageSchemas.for_stage(:change_verifier))
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema, options)
    assert {:error, :review_protocol_evidence_incomplete} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    {:ok, before} = WorkerEvidence.get(ctx.store, "verifier:request")
    {:ok, _} = TaskLedger.update(ctx.store, ctx.verifier_task_key, Map.merge(Map.take(before, ~w(output_json thread_id turn_id)), %{"status" => "COMPLETE"}))

    input = %{
      "run_id" => "run",
      "request_key" => before["request_key"],
      "binding_sha256" => before["binding_sha256"],
      "output_sha256" => before["output_sha256"],
      "mapping" => [%{"classification_index" => 0, "finding_index" => 0}]
    }

    assert {:ok, prepared} = ReviewProtocol.prepare_correction(ctx.store, input)
    assert prepared["status"] == "REPORT_CORRECTION_PREPARED"

    assert {:ok, receipt} =
             ReviewProtocol.correct_report(ctx.store, Map.merge(input, %{"projection_sha256" => prepared["projection_sha256"], "authorization_reference" => "explicit test operator approval"}))

    assert {:ok, ^receipt} =
             ReviewProtocol.correct_report(ctx.store, Map.merge(input, %{"projection_sha256" => prepared["projection_sha256"], "authorization_reference" => "explicit test operator approval"}))

    assert {:ok, ^before} = WorkerEvidence.get(ctx.store, "verifier:request")
    {:ok, reopened} = Store.start_link(database: ctx.database)
    context = %{store: reopened, workspace_root: Path.join(ctx.root, "workspaces"), factory: %{maximum_code_repair_rounds: 25}}

    try do
      assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", opts(ctx))
      assert run["state"] == "REPAIRING"
      {:ok, after_evidence} = WorkerEvidence.get(reopened, "verifier:request")
      assert Map.take(after_evidence, ~w(output_json output_sha256 binding_json binding_sha256)) == Map.take(before, ~w(output_json output_sha256 binding_json binding_sha256))
      {:ok, task} = TaskLedger.get(reopened, ctx.verifier_task_key)
      assert task["output_json"] == before["output_json"]
      assert {:ok, [entry]} = ReviewProtocol.history(reopened, Jason.decode!(prompt))
      assert entry["repair_admitted"]
      assert entry["finding_entries"] |> hd() |> Map.fetch!("finding") == "Detailed genuine mandatory privacy finding"
      assert length(Store.query!(reopened, "SELECT id FROM events WHERE event_type='TICKET_REVIEW_REPORT_CORRECTED'").rows) == 1
    after
      GenServer.stop(reopened)
    end
  end

  @tag verifier_terminal_adoption: true
  test "scheduler atomically adopts a stopped BLOCK verifier as a terminal failure", ctx do
    assert_terminal_verifier_adoption(ctx, "BLOCK", 2, "{:verification_blocked,")
  end

  @tag verifier_terminal_adoption: true
  test "scheduler adopts an over-budget REPAIR without retrying or resetting the budget", ctx do
    assert_terminal_verifier_adoption(ctx, "REPAIR", 0, "{:code_repair_limit,")
  end

  @tag verifier_terminal_adoption: true
  test "scheduler preserves PASS progression through the same adoption transaction", ctx do
    assert_progressing_verifier_adoption(ctx, "PASS", "PUSHING", 0)
  end

  @tag verifier_terminal_adoption: true
  test "scheduler preserves in-budget REPAIR progression through the same adoption transaction", ctx do
    assert_progressing_verifier_adoption(ctx, "REPAIR", "REPAIRING", 1)
  end

  @tag verifier_terminal_adoption: true
  test "failed terminal persistence rolls back adoption, consumption and access release", ctx do
    {_candidate, context} = recorded_verifier(ctx, "BLOCK", 2)
    assert {:ok, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    assert {:ok, %{"status" => "COMPLETE"}} = TaskLedger.get(ctx.store, "writer")
    before = verifier_adoption_records(ctx.store)

    Store.query!(
      ctx.store,
      "CREATE TEMP TRIGGER refuse_terminal_verifier BEFORE UPDATE OF state ON runs WHEN NEW.state='FAILED' BEGIN SELECT RAISE(ABORT,'synthetic terminal persistence failure'); END"
    )

    assert_raise Exqlite.Error, ~r/synthetic terminal persistence failure/, fn ->
      Scheduler.ticket_step(context, "run", opts(ctx))
    end

    assert verifier_adoption_records(ctx.store) == before
    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_NATIVE_VERIFIER_TERMINAL'").rows == []
  end

  defp assert_progressing_verifier_adoption(ctx, verdict, state, round) do
    {candidate, context} = recorded_verifier(ctx, verdict, 2)
    assert {:ok, %{status: "ADOPTED", run: run}} = Scheduler.ticket_step(context, "run", opts(ctx))
    assert run["state"] == state and run["code_repair_round"] == round and run["candidate_sha"] == candidate
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.get(ctx.store, "verifier:request")
  end

  defp recorded_verifier(ctx, verdict, limit) do
    {prompt, options, candidate} = prepare_verifier(ctx)
    Process.put(:worker_output, %{"status" => verdict, "candidate_sha" => candidate, "findings" => ["needs follow-up"], "checks" => []})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    {candidate, %{store: ctx.store, workspace_root: Path.join(ctx.root, "workspaces"), factory: %{maximum_code_repair_rounds: limit}}}
  end

  defp verifier_adoption_records(store) do
    {RunLedger.get(store, "run"), TaskLedger.get(store, "writer"), WorkerEvidence.get(store, "verifier:request"), WorkspaceAccess.get(store, "verifier:reservation")}
  end

  defp assert_terminal_verifier_adoption(ctx, verdict, limit, failure_prefix) do
    {_candidate, context} = recorded_verifier(ctx, verdict, limit)
    assert {:ok, before} = RunLedger.get(ctx.store, "run")
    assert {:ok, evidence} = WorkerEvidence.get(ctx.store, "verifier:request")

    assert {:ok, %{status: "ADOPTED", run: blocked}} = Scheduler.ticket_step(context, "run", opts(ctx))
    assert blocked["state"] == "FAILED"
    assert String.starts_with?(blocked["failure_code"], failure_prefix)

    assert Map.take(blocked, ~w(candidate_sha code_repair_round implementation_iteration verifier_round)) ==
             Map.take(before, ~w(candidate_sha code_repair_round implementation_iteration verifier_round))

    assert {:ok, consumed} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert consumed["status"] == "CONSUMED" and is_binary(consumed["consumed_at"])
    assert consumed["output_json"] == evidence["output_json"] and consumed["output_sha256"] == evidence["output_sha256"]
    assert {:ok, %{"status" => "CONSUMED"}} = TaskLedger.get(ctx.store, "writer")
    assert {:ok, access} = WorkspaceAccess.get(ctx.store, "verifier:reservation")
    assert is_binary(access["released_at"])
    [disposition] = Store.query!(ctx.store, "SELECT payload_json FROM events WHERE event_type='TICKET_NATIVE_VERIFIER_TERMINAL'").rows
    receipt = Jason.decode!(hd(disposition))
    assert receipt["request_key"] == "verifier:request" and receipt["output_sha256"] == evidence["output_sha256"]
    assert receipt["binding_sha256"] == evidence["binding_sha256"]
    assert {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      reopened_context = %{context | store: reopened}
      assert {:error, :ticket_role_stage_not_admitted} = Scheduler.ticket_step(reopened_context, "run", opts(ctx))
      assert {:ok, ^blocked} = RunLedger.get(reopened, "run")
      assert {:ok, ^consumed} = WorkerEvidence.get(reopened, "verifier:request")
      assert Store.query!(reopened, "SELECT payload_json FROM events WHERE event_type='TICKET_NATIVE_VERIFIER_TERMINAL'").rows == [disposition]
    after
      GenServer.stop(reopened)
    end
  end

  test "ready rework authorization rejects non-READY state without changing the run", ctx do
    {:ok, run} = RunLedger.get(ctx.store, "run")
    snapshot = Jason.decode!(run["snapshot_json"]) |> Map.merge(%{"labels" => ["ai-review"], "status" => "In Review"})
    before = RunLedger.get(ctx.store, "run")

    assert {:error, :ticket_command_run_state_changed} =
             TicketWorkerRunner.ready_rework_authorization(Map.put(run, "state", "VERIFYING"), snapshot, DateTime.utc_now())

    assert RunLedger.get(ctx.store, "run") == before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
  end

  test "conflicting ready and blocked resume options reject before the worker starts", ctx do
    {prompt, options} = prepare(ctx)

    before = %{
      run: RunLedger.get(ctx.store, "run"),
      task: TaskLedger.get(ctx.store, "writer"),
      evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY request_key").rows,
      access: Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows
    }

    conflicting = Keyword.merge(options, ready_rework: %{command_key: "ready-command"}, blocked_resume_prompt: prompt)
    assert {:error, :blocked_resume_packet_mismatch} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), conflicting)
    refute_received {:worker_options, _}
    assert RunLedger.get(ctx.store, "run") == before.run
    assert TaskLedger.get(ctx.store, "writer") == before.task
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence ORDER BY request_key").rows == before.evidence
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows == before.access
  end

  test "a missing reservation rejects before creating evidence or controller checks", ctx do
    {prompt, options} = prepare(ctx)
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows
    task_before = TaskLedger.get(ctx.store, "writer")
    run_before = RunLedger.get(ctx.store, "run")

    assert {:error, :unknown_workspace_reservation} =
             TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), Keyword.put(options, :reservation_key, nil))

    refute_received {:worker_options, _}
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access ORDER BY reservation_key").rows == access_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
    assert TaskLedger.get(ctx.store, "writer") == task_before
    assert RunLedger.get(ctx.store, "run") == run_before
  end

  test "verifier packets include CI evidence only when pipeline and candidate bindings are exact", ctx do
    {_prompt, _options, candidate} = prepare_verifier(ctx)
    assert {:ok, without_ci} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    refute Map.has_key?(Jason.decode!(without_ci), "ci_evidence")

    ci = %{"status" => "PASS", "sha" => candidate, "pipeline_id" => 17}
    {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_evidence_json: Jason.encode!(ci), ci_preflight_sha: candidate, ci_pipeline_id: 17})
    assert {:error, :worker_instruction_snapshot_not_admitted} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    assert {:error, :worker_instruction_snapshot_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "change-verifier", ctx.sha)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED"})
    assert {:ok, with_ci} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    assert Jason.decode!(with_ci)["ci_evidence"] == ci

    for changes <- [%{ci_pipeline_id: 18}, %{ci_preflight_sha: String.duplicate("f", 40)}] do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_preflight_sha: candidate, ci_pipeline_id: 17})
      assert {:ok, valid_control} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
      assert Jason.decode!(valid_control)["ci_evidence"] == ci

      {:ok, _} = RunLedger.update(ctx.store, "run", changes)
      assert {:error, :ticket_verifier_ci_evidence_mismatch} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
      assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
      assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
    end

    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM controller_checks").rows == []
    refute_received {:worker_options, _}
  end

  test "fresh changed-contract verifier creates and reuses its exact controller check before consumption", ctx do
    {prompt, options, candidate} = prepare_verifier(ctx)
    Process.put(:worker_output, %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => []})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert run["spec_revision"] == 2
    assert {:ok, %{evidence: evidence}} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    check = Store.one!(ctx.store, "SELECT * FROM controller_checks WHERE worker_request_key = 'verifier:request'")
    binding = Jason.decode!(check["binding_json"])
    assert Map.take(binding, ~w(run_id candidate_sha spec_revision contract_sha256)) == Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256))
    assert %{"result" => "PASS", "candidate_sha" => ^candidate} = Jason.decode!(check["receipt_json"])
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert {:ok, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    assert ^check = Store.one!(ctx.store, "SELECT * FROM controller_checks WHERE worker_request_key = 'verifier:request'")
    assert {:ok, ^evidence} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "verifier:reservation")
  end

  test "failed current verifier controller check prevents evidence consumption", ctx do
    File.write!(Path.join(ctx.path, "fixture.txt"), "trailing whitespace \n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "whitespace candidate"])
    candidate = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {prompt, options, ^candidate} = prepare_verifier(ctx, candidate)
    Process.put(:worker_output, %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => []})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    assert {:error, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "verifier:reservation")
  end

  test "uncertain verifier controller check is reconciled in place and blocks consumption", ctx do
    {prompt, options, candidate} = prepare_verifier(ctx)
    Process.put(:worker_output, %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => []})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    assert {:ok, check} = WorkerEvidence.prepare_check(ctx.store, "verifier:request", "git-diff-check")
    assert {:ok, _} = WorkerEvidence.start_check(ctx.store, check["check_key"], 99_999)
    assert {:error, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert Store.one!(ctx.store, "SELECT phase FROM controller_checks WHERE check_key = ?", [check["check_key"]])["phase"] == "RUNNING"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "verifier:reservation")
  end

  test "a controller check bound to another candidate cannot be reused for verifier adoption", ctx do
    {prompt, options, candidate} = prepare_verifier(ctx)
    Process.put(:worker_output, %{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => []})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, StageSchemas.for_stage(:change_verifier), options)
    assert {:ok, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    check = Store.one!(ctx.store, "SELECT * FROM controller_checks WHERE worker_request_key = 'verifier:request'")
    binding = Jason.decode!(check["binding_json"]) |> Map.put("candidate_sha", String.duplicate("f", 40))
    raw = Jason.encode!(binding)
    check_sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE controller_checks SET binding_json = ?, binding_sha256 = ? WHERE check_key = ?", [raw, check_sha, check["check_key"]])

    assert {:error, _} = TicketWorkerRunner.adoption(ctx.store, "verifier:request")
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.get(ctx.store, "verifier:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "verifier:reservation")
  end

  test "parent readiness requires successful acknowledgement and exact unchanged observation", ctx do
    {prompt, options} = prepare(ctx)

    rejected = [
      {"desktop_requests", "status", "THREAD_RECORDED"},
      {"desktop_requests", "turn_id", nil},
      {"desktop_requests", "output_json", Jason.encode!(%{"result" => %{"acknowledged" => false}})},
      {"desktop_requests", "verified_cwd", ctx.path},
      {"desktop_requests", "target_observation_json", "{}"},
      {"desktop_requests", "prompt", "changed"},
      {"ticket_chats", "generation", 2},
      {"ticket_chats", "observation_json", "{}"}
    ]

    for {table, field, changed} <- rejected do
      selector = if table == "desktop_requests", do: " WHERE target_kind = 'TICKET_CHAT'", else: ""
      original = Store.one!(ctx.store, "SELECT #{field} FROM #{table}#{selector}")[field]
      Store.query!(ctx.store, "UPDATE #{table} SET #{field} = ?#{selector}", [changed])
      assert {:error, :ticket_chat_parent_not_ready} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
      refute_received {:worker_options, _}
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_evidence")["count"] == 0
      Store.query!(ctx.store, "UPDATE #{table} SET #{field} = ?#{selector}", [original])
    end
  end

  test "validator packet carries declared validation under the exact contract and candidate, not live evidence", ctx do
    bind_parent(ctx)
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)

    contract =
      Contract.bind("PPL-123", 2, """
      ## Manual Validation
      - Required: yes
      - MV-3: Submit the fixed synthetic fixture; expect a successful response.
      - Environment: cpp-test
      - Services: doc-extract
      - Setup and deploy: Use the exact candidate via controller deployment.
      - Test data: Synthetic non-PHI/PII fixture only.
      - Evidence: Record the response and image digest.
      - Teardown: Restore previously observed images.
      - Database migrations: none
      """)

    {:ok, _} = RunLedger.update(ctx.store, "run", %{spec_revision: 2, contract_sha256: contract.sha256, contract_markdown: contract.markdown})
    {:ok, before} = RunLedger.get(ctx.store, "run")

    assert {:ok, raw} = TicketWorkerRunner.packet(ctx.store, "run", "manual-validator", ctx.sha)
    packet = Jason.decode!(raw)
    assert packet["candidate_sha"] == ctx.sha
    assert packet["contract_sha256"] == contract.sha256
    assert packet["validation_evidence"] == "DECLARATIONS_ONLY"
    assert packet["validation_definition"]["services"] == ["doc-extract"]
    assert packet["validation_definition"]["cases"] == [%{"id" => "MV-3", "expectation" => "Submit the fixed synthetic fixture; expect a successful response."}]
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    refute_received {:worker_options, _}

    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    assert {:error, :manual_validation_candidate_missing} = TicketWorkerRunner.packet(ctx.store, "run", "manual-validator", ctx.sha)
    assert {:ok, writer_packet} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert Jason.decode!(writer_packet)["candidate_sha"] == nil

    for candidate_sha <- ["a", String.duplicate("a", 39), String.duplicate("A", 40), String.duplicate("g", 40)] do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: candidate_sha})
      assert {:error, :manual_validation_candidate_invalid} = TicketWorkerRunner.packet(ctx.store, "run", "manual-validator", ctx.sha)
    end
  end

  test "validator packet rejects missing, unnecessary or changed contract definitions before worker creation", ctx do
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:error, :manual_validation_contract_missing} = TicketWorkerRunner.packet(ctx.store, "run", "manual-validator", ctx.sha)
    contract = Contract.bind("PPL-123", 1, "## Manual Validation\n- Required: no")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_sha256: contract.sha256, contract_markdown: contract.markdown})
    {:ok, before} = RunLedger.get(ctx.store, "run")
    assert {:error, :manual_validation_not_required} = TicketWorkerRunner.packet(ctx.store, "run", "manual-validator", ctx.sha)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_markdown: "changed bytes"})
    assert {:error, :ticket_worker_contract_unproven} = TicketWorkerRunner.packet(ctx.store, "run", "manual-validator", ctx.sha)
    refute_received {:worker_options, _}
  end

  test "role runs on the recorded checkout with exact scope and explicit model, not on parent", ctx do
    {prompt, options} = prepare(ctx)
    packet = Jason.decode!(prompt)
    assert packet["output_rules"]["changed_slice"] == "For CONTINUE or COMPLETE with changed_paths, commit_message must be a nonempty conventional message for the controller; never null."
    assert packet["output_rules"]["commit_message"] == "One line, at most 120 UTF-8 bytes, formatted as feat(PPL-123): short summary (or fix, chore, refactor, test, docs, perf)."
    assert packet["output_rules"]["no_edit_completion"] == "For no-edit completion, use COMPLETE, changed_paths [], and commit_message null; preserve the existing candidate."
    assert packet["output_rules"]["blocked"] == "For BLOCKED, report actual changed_paths and blockers; commit_message may be null. Never claim a completed slice."
    assert {:ok, result} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert result.thread_id == "worker" and result.item_id == "final"
    assert_received {:worker_options, args}
    assert args[:worker_access] == "FILE_SOURCE" and args[:model] == "gpt-6-luna" and args[:reasoning_effort] == "medium"
    assert is_map(args[:worker_files])
    assert args[:resume_thread_id] == nil and args[:project_id] == nil
    assert_received :owned_session_stopped
    assert {:ok, %{"status" => "RESULT_RECORDED", "owner_stopped_at" => stopped}} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert is_binary(stopped)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert {:error, :worker_start_already_sent} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
  end

  test "fresh verifier uses confirmed contract and pinned source, never writer claims or parent summaries", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{plan_markdown: "writer claim: everything passed", repair_findings_json: "parent says approve"})
    {prompt, options} = prepare(ctx, "change-verifier")
    assert Jason.decode!(prompt)["tools"] =~ "/Library/Developer/CommandLineTools/usr/bin/git"
    refute prompt =~ "writer claim" or prompt =~ "parent says"
    Process.put(:worker_output, %{"status" => "PASS", "candidate_sha" => ctx.sha})
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert_received {:worker_options, args}
    assert args[:worker_access] == "REVIEW"
  end

  test "connector startup failure parks the same attempt without recreating or freeing source", ctx do
    {prompt, options} = prepare(ctx)
    Process.put(:fail_start, true)
    assert {:error, :connector_catalog_not_empty} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "thread_id" => "worker"}} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert {:error, :worker_start_already_sent} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a started message is never a completed result receipt", ctx do
    {prompt, options} = prepare(ctx)
    Process.put(:worker_item_method, "item/started")
    assert {:error, :factory_stage_output_missing} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "output_json" => nil}} = WorkerEvidence.get(ctx.store, "reservation:request")
  end

  test "review base is pinned from named remote evidence, not an arbitrary or nonexistent SHA", ctx do
    for run <- [%{}, %{"base_branch" => nil, "repo_path" => ctx.repo}, %{"base_branch" => "master", "repo_path" => nil}] do
      assert {:error, :ticket_review_base_missing} = TicketWorkerRunner.observed_base(run)
    end

    assert {:ok, sha} = TicketWorkerRunner.observed_base(%{"base_branch" => "master", "repo_path" => ctx.repo})
    assert sha == ctx.sha
    assert {:error, :ticket_review_base_missing} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    assert {:error, :ticket_review_base_mismatch} = TicketWorkerRunner.bind_base(ctx.store, "run", String.duplicate("b", 40))
    assert {:ok, pin} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:ok, ^pin} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:error, :ticket_review_base_missing} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", String.duplicate("b", 40))
    File.write!(Path.join(ctx.path, "fixture.txt"), "new base\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "base advanced"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    git(ctx.repo, ["update-ref", "refs/remotes/origin/master", sha])
    assert {:error, :ticket_review_base_immutable} = TicketWorkerRunner.bind_base(ctx.store, "run", sha)
    assert {:ok, _} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
  end

  test "stale prompts/models, wrong scope and unbound route fail before any launch", ctx do
    {prompt, options} = prepare(ctx)
    assert {:error, :ticket_worker_input_mismatch} = TicketWorkerRunner.run(ctx.path, issue(), prompt <> "extra", schema(), options)
    assert {:error, :ticket_worker_input_mismatch} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), Keyword.put(options, :model, "other"))
    assert {:error, :ticket_worker_scope_mismatch} = TicketWorkerRunner.run(ctx.repo, issue(), prompt, schema(), options)
    Store.query!(ctx.store, "UPDATE ticket_chats SET thread_id = NULL")
    assert {:error, :ticket_worker_route_not_bound} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    refute_received {:worker_options, _}
    assert {:error, :ticket_worker_role_unsupported} = TicketWorkerRunner.packet(ctx.store, "run", "unknown", ctx.sha)
    assert {:error, :ticket_review_base_missing} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", nil)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_sha256: "stale"})
    assert {:error, :ticket_worker_contract_unproven} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
  end

  test "writer resumes only its proven stopped and consumed attempt", ctx do
    {prompt, options} = prepare(ctx)
    assert {:ok, observed} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: observed.thread_id, turn_id: observed.turn_id, output_json: Jason.encode!(observed.output)})
    assert {:ok, _} = WorkerEvidence.consume(ctx.store, observed.worker_request_key)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STARTING"})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "second"), opts(ctx))
    options = Keyword.merge(options, request_key: "second:request", reservation_key: "second")
    Process.put(:worker_turn, "next-turn")
    assert {:ok, result} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert result.turn_id == "next-turn"
    assert_received {:worker_options, first}
    assert first[:resume_thread_id] == nil
    assert_received {:worker_options, resumed}
    assert resumed[:resume_thread_id] == "worker"
  end

  test "writer history with a broader policy, stale file tools or malformed binding cannot be resumed", ctx do
    {prompt, options} = prepare(ctx)
    assert {:ok, observed} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: observed.thread_id, turn_id: observed.turn_id, output_json: Jason.encode!(observed.output)})
    assert {:ok, _} = WorkerEvidence.consume(ctx.store, observed.worker_request_key)
    {:ok, row} = WorkerEvidence.get(ctx.store, observed.worker_request_key)
    binding = Jason.decode!(row["binding_json"])
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "STARTING"})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "second"), opts(ctx))
    options = Keyword.merge(options, request_key: "second:request", reservation_key: "second")
    assert_received {:worker_options, _}

    broader = %{binding["policy"] | "mode" => "SOURCE", "source_access" => "write", "profile" => "symphony_ticket_source_v1"}
    stale = Map.put(binding["policy"], "file_tools_sha256", String.duplicate("0", 64))

    for raw <- [Jason.encode!(Map.put(binding, "policy", broader)), Jason.encode!(Map.put(binding, "policy", stale)), "not-json", "null", "{}", "[]"] do
      hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = ?, binding_sha256 = ? WHERE request_key = ?", [raw, hash, observed.worker_request_key])
      assert {:error, :ticket_worker_resume_unproven} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    end

    refute_received {:worker_options, _}
  end

  test "unproven writer history and existing review threads cannot be resumed", ctx do
    {prompt, options} = prepare(ctx)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{thread_id: "unowned"})
    assert {:error, :ticket_worker_resume_unproven} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{role: "change-verifier"})
    assert {:error, :ticket_review_worker_must_be_fresh} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{thread_id: nil})
    assert {:error, :ticket_worker_blind_packet_mismatch} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{role: "manual-validator"})
    assert {:error, :ticket_validator_authorized_transport_required} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{role: "unknown"})
    assert {:error, :ticket_worker_role_unsupported} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    refute_received {:worker_options, _}
  end

  defmodule GuardRejectedServer do
    alias SymphonyElixir.FactoryTicketWorkerRunnerTest.FakeWorkerServer
    defdelegate start_session(workspace, opts), to: FakeWorkerServer
    defdelegate stop_session(session), to: FakeWorkerServer
    def run_turn(_session, _prompt, _issue, _opts), do: {:error, :interrupted_owned_session_preflight_failed}
  end

  test "pre-turn guard denial retains the genuine stopped session without a turn or result", ctx do
    {prompt, options} = prepare(ctx)
    options = Keyword.put(options, :app_server, GuardRejectedServer)
    assert {:error, :interrupted_owned_session_preflight_failed} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert_received :owned_session_stopped
    refute_received {:worker_prompt, _}
    assert {:ok, failed} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert WorkerEvidence.owner_stopped?(ctx.store, failed)
    assert failed["status"] == "RECONCILE_REQUIRED" and failed["thread_id"] == "worker"
    assert Enum.all?(~w(turn_id item_id output_json output_sha256), &is_nil(failed[&1]))
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_file_operations")["n"] == 0
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "policy drift and callback errors retain reservations for reconciliation", ctx do
    {prompt, options} = prepare(ctx)
    Process.put(:observed_policy, %{"mode" => "SOURCE", "cwd" => ctx.path})
    assert {:error, {:worker_exception, :error, "{:badmatch, false}"}} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    refute_received {:worker_prompt, _}
    assert {:ok, %{"status" => "RECONCILE_REQUIRED"}} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "callback exception after creation preserves the known worker, without a second creation", ctx do
    {prompt, options} = prepare(ctx)
    options = Keyword.put(options, :on_thread_started, fn _ -> raise "observation failed" end)
    assert {:error, :worker_observation_failed} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "thread_id" => "worker"}} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert {:error, :worker_start_already_sent} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "base proof rejects missing repositories, ref corruption and unrelated candidate history", ctx do
    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    assert {:ok, _} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    git(ctx.path, ["checkout", "--orphan", "unrelated"])
    git(ctx.path, ["commit", "--no-verify", "-m", "unrelated history"])
    unrelated = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: unrelated})
    assert {:error, :ticket_review_base_not_ancestor} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha = 'HEAD'")
    assert {:error, :ticket_review_base_mismatch} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", "HEAD")
    missing = String.duplicate("b", 40)
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha = ?", [missing])
    assert {:error, {:ticket_git_read_failed, _}} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", missing)
    Store.query!(ctx.store, "UPDATE runs SET repo_path = NULL WHERE run_id = 'run'")
    assert {:error, :ticket_review_repository_missing} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
  end

  test "unproven shutdown retains the completed result for same-invocation recovery", ctx do
    {prompt, options} = prepare(ctx)
    Process.put(:fail_stop, true)
    assert {:error, {:worker_shutdown_unproven, {:error, :shutdown_unproven}, observed}} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "output_json" => output}} = WorkerEvidence.get(ctx.store, "reservation:request")
    assert Jason.decode!(output) == observed.output
    session = Process.get(:owned_session)
    Process.put(:fail_stop, false)
    {:ok, stop} = FakeWorkerServer.stop_session(session)
    assert {:ok, %{"status" => "RESULT_RECORDED"}} = WorkerEvidence.reconcile_completed(ctx.store, "reservation:request", options[:owner_id], observed, stop)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a planner can release its clean pinned base before a candidate exists", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    {prompt, options} = prepare(ctx, "feature-planner")
    Process.put(:worker_output, %{"status" => "PLANNED"})
    assert {:ok, observed} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", thread_id: observed.thread_id, turn_id: observed.turn_id, output_json: Jason.encode!(observed.output)})
    assert {:ok, %{"status" => "CONSUMED"}} = WorkerEvidence.consume(ctx.store, observed.worker_request_key)
    assert {:ok, %{"released_at" => at}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert is_binary(at)
    assert {:ok, %{"candidate_sha" => nil}} = RunLedger.get(ctx.store, "run")
  end

  test "a verifier result for another candidate cannot be persisted", ctx do
    {prompt, options} = prepare(ctx, "change-verifier")
    Process.put(:worker_output, %{"status" => "PASS", "candidate_sha" => "wrong"})
    assert {:error, :worker_review_candidate_mismatch} = TicketWorkerRunner.run(ctx.path, issue(), prompt, schema(), options)
    assert {:ok, %{"status" => "RECONCILE_REQUIRED", "output_json" => nil}} = WorkerEvidence.get(ctx.store, "reservation:request")
  end
end
