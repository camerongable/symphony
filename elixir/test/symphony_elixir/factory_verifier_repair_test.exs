defmodule SymphonyElixir.FactoryVerifierRepairTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Factory.Ticket
  alias SymphonyElixir.Config.Schema

  alias SymphonyElixir.Factory.{
    BrokerRuntime,
    Control,
    ControlServer,
    Policy,
    ReviewProtocol,
    RunLedger,
    Scheduler,
    StageSchemas,
    Store,
    TaskLedger,
    TicketContext,
    TicketVerifierRepair,
    TicketWorkerRunner,
    TickLease,
    WorkerInstructions,
    WorkspaceAccess
  }

  alias SymphonyElixir.{TicketChatFixture, TicketWorkerFixture, Workflow}
  alias SymphonyElixir.Tracker.Issue

  defmodule Verifier do
    def start_session(workspace, opts) do
      thread = "blocked-verifier-#{System.unique_integer([:positive])}"
      opts[:on_thread_created].(thread)
      {:ok, %{thread_id: thread, worker_policy: TicketWorkerRunner.policy("REVIEW", workspace), worker_invocation: String.duplicate("a", 64), metadata: %{codex_app_server_pid: "fixture"}}}
    end

    def run_turn(session, prompt, _issue, opts) do
      packet = Jason.decode!(prompt)
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: "blocked-turn"})

      output = %{
        "status" => "BLOCK",
        "candidate_sha" => packet["candidate_sha"],
        "findings" => ["Redact versioned logging — preserve provenance", "Remove unrelated fax changes"],
        "checks" => ["Exact candidate ✓", ""]
      }

      output =
        if packet["review_protocol"] do
          rows = Enum.map(packet["review_protocol"]["criterion_ids"], &%{"id" => &1, "status" => "FAIL", "evidence" => ["fixture boundary"]})

          report = %{
            "version" => 1,
            "candidate_sha" => packet["candidate_sha"],
            "block_reason" => "HUMAN_DECISION",
            "criteria" => rows,
            "closures" => [],
            "boundary_sweeps" => Enum.map(rows, &Map.merge(&1, %{"status" => "CHECKED", "paths" => ["fixture.txt"]})),
            "finding_classifications" => Enum.map(output["findings"], &%{"finding" => &1, "classification" => "NEW"})
          }

          if packet["review_protocol"]["version"] == 2 do
            typed =
              output["findings"]
              |> Enum.with_index()
              |> Enum.map(fn {description, index} ->
                %{
                  "id" => "F-#{index}",
                  "description" => description,
                  "classification" => "NEW",
                  "disposition" => "REQUIRED_REPAIR",
                  "basis" => %{"kind" => "ACCEPTANCE_CRITERION", "reference" => "AC-1"}
                }
              end)

            output
            |> Map.delete("findings")
            |> Map.put("review_report", report |> Map.put("version", 2) |> Map.delete("finding_classifications") |> Map.put("findings", typed) |> Map.put("affected_path_checks", []))
          else
            Map.put(output, "review_report", report)
          end
        else
          output
        end

      item = %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}
      opts[:on_message].(%{payload: %{"method" => "item/completed", "params" => %{"threadId" => session.thread_id, "turnId" => "blocked-turn", "item" => item}}})
      {:ok, %{turn_id: "blocked-turn"}}
    end

    def stop_session(session) do
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

  defmodule JiraReader do
    def issue("PPL-123", opts) do
      {:ok, run} = RunLedger.get(opts[:store], "run")
      {:ok, Jason.decode!(run["snapshot_json"]) |> Map.merge(%{"labels" => ["ai-running", "repo-grail"], "status" => "In Dev"})}
    end
  end

  defmodule ControlChangeJiraReader do
    def issue(key, opts) do
      Process.delete(:verifier_control_change).(opts[:store])
      JiraReader.issue(key, opts)
    end
  end

  setup context do
    ctx = TicketWorkerFixture.setup_fixture(%{unregistered: true})
    TicketWorkerFixture.register(ctx, "run", "PPL-123", "run:change-verifier:2")

    TicketWorkerFixture.bind_parent(ctx)

    if context[:structured_review] do
      {contract, snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-id", "AC-1: Implement the fixture behavior.\n\n## Manual Validation\n- Required: no")
      {:ok, _} = RunLedger.update(ctx.store, "run", %{contract_markdown: contract.markdown, contract_sha256: contract.sha256, snapshot_json: Jason.encode!(snapshot)})
    end

    {:ok, _} =
      RunLedger.update(ctx.store, "run", %{
        state: "VERIFYING",
        verifier_round: 2,
        code_repair_round: 8,
        implementation_iteration: 21,
        workspace_state: "CODEX_NATIVE",
        ci_evidence_json: Jason.encode!(%{"status" => "PASS", "sha" => ctx.sha, "pipeline_id" => 17}),
        ci_preflight_sha: ctx.sha,
        ci_pipeline_id: 17
      })

    {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)

    prompt =
      if context[:legacy_report] do
        base = Jason.decode!(prompt) |> Map.drop(~w(shared_instructions instruction_delivery instruction_snapshot_sha256 instruction_binding_sha256)) |> put_in(["review_protocol", "version"], 1)
        {:ok, instructions} = WorkerInstructions.admit(ctx.store, base, "change-verifier", Path.join(System.user_home!(), ".agents"))
        Jason.encode!(Map.merge(base, instructions))
      else
        prompt
      end

    assert Map.has_key?(Jason.decode!(prompt), "review_protocol") == !!context[:structured_review]
    {:ok, _} = TaskLedger.update(ctx.store, "run:change-verifier:2", %{stage: "VERIFYING", role: "change-verifier", prompt_sha256: digest(prompt)})
    assert :ok = WorkerInstructions.bind_task(ctx.store, "run:change-verifier:2", digest(prompt), Jason.decode!(prompt)["instruction_binding_sha256"])
    attrs = TicketWorkerFixture.attrs(ctx, "REVIEW", "verifier") |> Map.merge(%{"task_key" => "run:change-verifier:2", "request_key" => "verifier-request"})
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs, TicketWorkerFixture.opts(ctx))

    options = [
      store: ctx.store,
      target_key: "run:change-verifier:2",
      request_key: "verifier-request",
      reservation_key: "verifier",
      owner_id: "verifier-owner",
      app_server: Verifier,
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      review_base_sha: ctx.sha
    ]

    schema = ReviewProtocol.schema(Jason.decode!(prompt), StageSchemas.for_stage(:change_verifier))
    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123", title: "Fixture"}, prompt, schema, options)

    factory = %{
      enabled: true,
      scope: "scope",
      dispatcher_id: "operator-fixture",
      lease_seconds: 240,
      maximum_code_repair_rounds: 10,
      maximum_implementation_iterations: 25,
      maximum_specifiers: 2,
      maximum_writers: 2,
      maximum_validators: 2,
      writer_disk_gb: 20,
      ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]},
      repositories: %{"grail" => %{"path" => ctx.repo, "base_branch" => "master"}}
    }

    context = %{store: ctx.store, factory: factory, workspace_root: Path.join(ctx.root, "workspaces")}
    assert {:ok, %{run: %{"state" => "FAILED"}}} = Scheduler.ticket_step(context, "run", TicketWorkerFixture.opts(ctx))
    Control.initialize(ctx.store, factory)
    assert {:ok, _} = Control.activate(ctx.store, factory, factory.dispatcher_id)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key='verifier-request'")

    input =
      Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256))
      |> Map.merge(%{
        "authorization_key" => "operator-approval",
        "verifier_request_key" => "verifier-request",
        "verifier_output_sha256" => evidence["output_sha256"],
        "authorization_reference" => "codex://threads/operator#turn=approved",
        "authorization_body" => "Fix the issues and get the ticket moving again.",
        "repair_instructions" => "Resolve both original findings without changing the contract."
      })

    Map.merge(ctx, %{factory: factory, context: context, input: input, options: Keyword.merge(TicketWorkerFixture.opts(ctx), jira_reader: JiraReader)})
  end

  for structured <- [false, true] do
    @tag verifier_repair_authorization: true
    @tag single_repair_budget: true
    @tag structured_review: structured
    test "single-repair exception preserves cap, once-only authority and physical readback structured=#{structured}", ctx do
      factory = budget_factory(ctx)
      ctx = %{ctx | factory: factory, context: %{ctx.context | factory: factory}}
      {:ok, before} = RunLedger.get(ctx.store, "run")
      assert {:ok, authorized} = TicketVerifierRepair.stage(ctx.store, ctx.input, factory, ctx.options)
      assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
      proof = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE id=?", [authorized.authorization_event_id])["payload_json"] |> Jason.decode!()
      assert proof["configured_limits"]["maximum_code_repair_rounds"] == 8
      assert proof["limits"]["maximum_code_repair_rounds"] == 9
      assert proof["budget_exception"]["prior_code_repair_round"] == 8
      assert proof["budget_exception"]["next_code_repair_round"] == 9
      server = start_supervised!({ControlServer, [store: ctx.store, factory: factory, name: nil]})
      assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}} = owned_apply(ctx, server)
      assert {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}} = TicketVerifierRepair.stage(ctx.store, ctx.input, factory, ctx.options)
      assert {:ok, after_run} = RunLedger.get(ctx.store, "run")
      assert after_run["code_repair_round"] == 9
      assert after_run["implementation_iteration"] == before["implementation_iteration"]
      assert factory.maximum_code_repair_rounds == 8
      assert {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
      assert Jason.decode!(prompt)["repair_review"]["operator_authorization"]["authorization_key"] == ctx.input["authorization_key"]
      packet_path = Path.join(ctx.root, "operator-packet.json")
      File.write!(packet_path, prompt)
      assert {"PHYSICAL_OPERATOR_AUTHORITY_PASS\n", 0} = System.cmd("python3", ["-B", "test/support/check_operator_budget_fixture.py", ctx.database, packet_path])
      assert {:error, _} = TicketVerifierRepair.stage(ctx.store, Map.put(ctx.input, "authorization_key", "second-approval"), factory, ctx.options)
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'")["count"] == 1
    end
  end

  @tag single_repair_budget: true
  test "exception identity and exact next-round drift cannot grant a repair", ctx do
    factory = budget_factory(ctx)
    entry = factory.ticket_supervisor["verifier_repair_budget_exceptions"][ctx.input["authorization_key"]]

    for key <- Map.keys(entry) do
      wrong = Map.update!(entry, key, fn value -> if is_integer(value), do: value + 1, else: value <> "-wrong" end)
      changed = put_in(factory, [:ticket_supervisor, "verifier_repair_budget_exceptions", ctx.input["authorization_key"]], wrong)
      assert {:error, _} = TicketVerifierRepair.stage(ctx.store, ctx.input, changed, ctx.options)
    end

    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED'").rows == []
  end

  @tag single_repair_budget: true
  test "removing the exact exception after staging prevents application", ctx do
    factory = budget_factory(ctx)
    assert {:ok, _} = TicketVerifierRepair.stage(ctx.store, ctx.input, factory, ctx.options)
    removed = %{factory | ticket_supervisor: ctx.factory.ticket_supervisor}
    ctx = %{ctx | factory: removed, context: %{ctx.context | factory: removed}}
    server = start_supervised!({ControlServer, [store: ctx.store, factory: removed, name: nil]})
    assert {:ran, {:error, _}} = owned_apply(ctx, server)
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert run["state"] == "FAILED" and run["code_repair_round"] == 8
  end

  defp budget_factory(ctx) do
    entry =
      Map.take(ctx.input, ~w(run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference))
      |> Map.merge(%{"kind" => "ONE_VERIFIER_REPAIR", "verifier_round" => 2, "prior_code_repair_round" => 8, "next_code_repair_round" => 9, "configured_limit" => 8})

    %{ctx.factory | maximum_code_repair_rounds: 8, ticket_supervisor: Map.put(ctx.factory.ticket_supervisor, "verifier_repair_budget_exceptions", %{ctx.input["authorization_key"] => entry})}
  end

  @tag single_repair_budget: true
  @tag structured_review: true
  @tag legacy_report: true
  test "retained V1 structured BLOCK authorization preserves prose IDs across restart and physical readback", ctx do
    assert {:ok, authorized} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    raw = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE id=?", [authorized.authorization_event_id])["payload_json"]
    proof = Jason.decode!(raw)
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key='verifier-request'")
    output = Jason.decode!(evidence["output_json"])
    expected = Enum.map(Enum.uniq(output["findings"]), &%{"id" => digest(Jason.encode!([ctx.input["contract_sha256"], &1])), "finding" => &1})
    assert proof["version"] == 1 and proof["findings"] == expected
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})
    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}} = owned_apply(ctx, server)
    stop_supervised!(ControlServer)
    start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})
    assert Store.one!(ctx.store, "SELECT payload_json FROM events WHERE id=?", [authorized.authorization_event_id])["payload_json"] == raw
    assert {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert Jason.decode!(prompt)["repair_review"]["findings"] != expected
    packet_path = Path.join(ctx.root, "retained-v1-packet.json")
    File.write!(packet_path, prompt)
    assert {"PHYSICAL_OPERATOR_AUTHORITY_PASS\n", 0} = System.cmd("python3", ["-B", "test/support/check_operator_budget_fixture.py", ctx.database, packet_path])
  end

  @tag structured_review: true
  test "typed BLOCK supports exact operator authorization application and archived obligation recovery", ctx do
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key='verifier-request'")
    original = evidence["output_json"]
    refute Map.has_key?(Jason.decode!(original), "findings")
    assert {:ok, _} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})
    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}} = owned_apply(ctx, server)
    assert {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    packet = Jason.decode!(prompt)
    assert packet["review_protocol"]["repairs_used"] == 0
    assert Enum.map(packet["repair_review"]["findings"], & &1["id"]) == ["F-0", "F-1"]
    assert packet["repair_review"]["operator_authorization"]["authorization_key"] == ctx.input["authorization_key"]
    assert Store.one!(ctx.store, "SELECT output_json FROM worker_evidence WHERE request_key='verifier-request'")["output_json"] == original
  end

  @tag single_repair_budget: true
  test "archived V2 limits reject extra keys, missing fields and noninteger limits", ctx do
    factory = budget_factory(ctx)
    ctx = %{ctx | factory: factory, context: %{ctx.context | factory: factory}}
    assert {:ok, authorized} = TicketVerifierRepair.stage(ctx.store, ctx.input, factory, ctx.options)
    server = start_supervised!({ControlServer, [store: ctx.store, factory: factory, name: nil]})
    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}} = owned_apply(ctx, server)
    assert {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    packet = Jason.decode!(prompt)
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key='verifier-request'")
    auth = Store.one!(ctx.store, "SELECT payload_json FROM events WHERE id=?", [authorized.authorization_event_id])["payload_json"] |> Jason.decode!()
    applied = Store.one!(ctx.store, "SELECT id,payload_json FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'")
    applied_proof = Jason.decode!(applied["payload_json"])
    assert {:ok, _} = TicketVerifierRepair.review_authority(ctx.store, packet, evidence)

    for field <- ~w(configured_limits limits),
        invalid <- [
          Map.delete(auth[field], "maximum_implementation_iterations"),
          Map.put(auth[field], "extra", 1),
          Map.put(auth[field], "maximum_implementation_iterations", nil),
          Map.put(auth[field], "maximum_implementation_iterations", "25"),
          Map.put(auth[field], "maximum_implementation_iterations", 25.0),
          Map.put(auth[field], "maximum_implementation_iterations", -1)
        ] do
      raw = auth |> Map.put(field, invalid) |> Jason.encode!()
      Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE id=?", [raw, authorized.authorization_event_id])
      Store.query!(ctx.store, "UPDATE events SET payload_json=? WHERE id=?", [Jason.encode!(Map.put(applied_proof, "authorization_sha256", digest(raw))), applied["id"]])
      assert {:error, :verifier_repair_authority_unproven} = TicketVerifierRepair.review_authority(ctx.store, packet, evidence)
    end
  end

  @tag verifier_repair_authorization: true
  test "explicit operator staging is once-only and does not advance or launch the blocked run", ctx do
    assert {:ok, before} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{status: "VERIFIER_REPAIR_AUTHORIZED"} = receipt} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert {:ok, ^receipt} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED'")["count"] == 1
    assert Store.query!(ctx.store, "SELECT reservation_key FROM workspace_access WHERE released_at IS NULL").rows == []
    assert {:ok, presentation} = TicketContext.context(ctx.store, "run")
    assert presentation.latest_verifier.historical_status == "BLOCK"
    assert presentation.latest_verifier.current_binding == "EXACT"
  end

  @tag verifier_repair_authorization: true
  @tag verifier_repair_control_observation: true
  test "a completed normal tick during Jira permits one staged approval and one later owned application", ctx do
    {:ok, before} = RunLedger.get(ctx.store, "run")
    initial_control = Control.status(ctx.store, ctx.factory.scope)

    Process.put(:verifier_control_change, fn store ->
      assert %{result: "ACQUIRED", tick_id: tick} = Control.acquire_tick(store, ctx.factory, ctx.factory.dispatcher_id)
      assert %{result: "RELEASED"} = Control.release_tick(store, ctx.factory, ctx.factory.dispatcher_id, tick)
    end)

    options = Keyword.put(ctx.options, :jira_reader, ControlChangeJiraReader)
    assert {:ok, %{status: "VERIFIER_REPAIR_AUTHORIZED"} = authorized} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Control.status(ctx.store, ctx.factory.scope)["generation"] == initial_control["generation"] + 2
    assert {:ok, ^authorized} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})
    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED", source_advanced: false}}} = owned_apply(ctx, server)
    assert {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert {:ok, repaired} = RunLedger.get(ctx.store, "run")
    assert repaired["code_repair_round"] == before["code_repair_round"] + 1
    assert repaired["implementation_iteration"] == before["implementation_iteration"]
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED'")["count"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'")["count"] == 1
    assert Store.query!(ctx.store, "SELECT reservation_key FROM workspace_access WHERE released_at IS NULL").rows == []
  end

  @tag verifier_repair_authorization: true
  @tag verifier_repair_control_observation: true
  test "a completed pause and resume during Jira stages current idle authority without dispatch", ctx do
    {:ok, before} = RunLedger.get(ctx.store, "run")

    Process.put(:verifier_control_change, fn store ->
      assert {:ok, %{result: "PAUSED"}} = Control.pause(store, ctx.factory, ctx.factory.dispatcher_id)
      assert {:ok, %{result: "ACTIVE"}} = Control.activate(store, ctx.factory, ctx.factory.dispatcher_id)
    end)

    options = Keyword.put(ctx.options, :jira_reader, ControlChangeJiraReader)
    assert {:ok, %{status: "VERIFIER_REPAIR_AUTHORIZED"}} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'").rows == []
    assert Store.query!(ctx.store, "SELECT reservation_key FROM workspace_access WHERE released_at IS NULL").rows == []
  end

  for mutation <- ~w(active_lease paused dispatcher scope thread model conflict run evidence generation_regression negative_generation malformed_generation orphan_lease) do
    @control_mutation mutation
    @tag verifier_repair_authorization: true
    @tag verifier_repair_control_observation: true
    test "staging refuses #{@control_mutation} drift during Jira without granting authority", ctx do
      mutation = @control_mutation
      Process.put(:verifier_control_change, fn store -> change_observation(ctx, store, mutation) end)
      options = Keyword.put(ctx.options, :jira_reader, ControlChangeJiraReader)
      assert {:error, :verifier_repair_observation_changed} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, options)
      assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type IN ('TICKET_VERIFIER_REPAIR_AUTHORIZED','TICKET_VERIFIER_REPAIR_APPLIED')").rows == []
      refute Enum.any?(TaskLedger.list_for_run(ctx.store, "run"), &(&1["stage"] == "REPAIRING"))
    end
  end

  defp change_observation(ctx, store, "active_lease") do
    assert %{result: "ACQUIRED"} = Control.acquire_tick(store, ctx.factory, ctx.factory.dispatcher_id)
  end

  defp change_observation(ctx, store, "paused") do
    assert {:ok, %{result: "PAUSED"}} = Control.pause(store, ctx.factory, ctx.factory.dispatcher_id)
  end

  defp change_observation(ctx, store, "dispatcher") do
    assert {:ok, %{result: "ACTIVE"}} = Control.activate(store, ctx.factory, "other-dispatcher")
  end

  defp change_observation(_ctx, store, "scope"), do: Store.query!(store, "UPDATE control SET scope='other-scope'")
  defp change_observation(_ctx, store, "thread"), do: Store.query!(store, "UPDATE control SET controller_thread_id='other-thread'")
  defp change_observation(_ctx, store, "model"), do: Store.query!(store, "UPDATE control SET controller_model='other-model'")
  defp change_observation(_ctx, store, "conflict"), do: Store.query!(store, "UPDATE control SET controller_writer_conflict_count=controller_writer_conflict_count+1")
  defp change_observation(_ctx, store, "run"), do: RunLedger.update(store, "run", %{last_error: "changed finding context"})
  defp change_observation(_ctx, store, "evidence"), do: Store.query!(store, "UPDATE worker_evidence SET output_sha256=? WHERE request_key='verifier-request'", [String.duplicate("0", 64)])
  defp change_observation(_ctx, store, "generation_regression"), do: Store.query!(store, "UPDATE control SET generation=generation-1")
  defp change_observation(_ctx, store, "negative_generation"), do: Store.query!(store, "UPDATE control SET generation=-1")
  defp change_observation(_ctx, store, "malformed_generation"), do: Store.query!(store, "UPDATE control SET generation='unknown'")
  defp change_observation(_ctx, store, "orphan_lease"), do: Store.query!(store, "UPDATE control SET lease_expires_at='2099-01-01T00:00:00Z'")

  @tag verifier_repair_authorization: true
  test "normal owned tick applies once without dispatch, retaining the BLOCK and all implementation budgets", ctx do
    assert {:ok, authorized} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert {:error, :verifier_repair_normal_tick_required} = Scheduler.ticket_step(ctx.context, "run", ctx.options)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key='verifier-request'")
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})

    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED", source_advanced: false}}} =
             TickLease.run(
               ctx.factory,
               fn tick ->
                 Scheduler.ticket_step(ctx.context, "run", Keyword.merge(ctx.options, ordinary_controller_tick: true, operator_tick: tick))
               end,
               control_server: server
             )

    {:ok, after_run} = RunLedger.get(ctx.store, "run")
    assert after_run["state"] == "REPAIRING"
    assert after_run["code_repair_round"] == before["code_repair_round"] + 1
    assert after_run["implementation_iteration"] == before["implementation_iteration"]
    assert after_run["verifier_round"] == before["verifier_round"]
    assert after_run["candidate_handoff"] == before["candidate_handoff"]
    assert Jason.decode!(after_run["repair_findings_json"]) == Jason.decode!(evidence["output_json"])["findings"]
    assert evidence == Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key='verifier-request'")
    assert {:ok, replay} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert replay == %{authorized | status: "VERIFIER_REPAIR_APPLIED"}
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'")["count"] == 1
    assert Store.query!(ctx.store, "SELECT reservation_key FROM workspace_access WHERE released_at IS NULL").rows == []
    assert {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    packet = Jason.decode!(prompt)
    assert packet["repair_review"]["prior_candidate_sha"] == ctx.sha
    assert packet["repair_review"]["operator_authorization"]["repair_instructions"] == ctx.input["repair_instructions"]
    assert Enum.map(packet["repair_review"]["findings"], & &1["finding"]) == Jason.decode!(evidence["output_json"])["findings"]
  end

  @tag verifier_repair_authorization: true
  test "changed binding, stale verifier round and forged native-input fields refuse before authorization", ctx do
    for input <- [
          Map.put(ctx.input, "candidate_sha", String.duplicate("b", 40)),
          Map.put(ctx.input, "verifier_output_sha256", String.duplicate("b", 64)),
          Map.put(ctx.input, "native_human_input", true)
        ] do
      assert {:error, _} = TicketVerifierRepair.stage(ctx.store, input, ctx.factory, ctx.options)
    end

    {:ok, _} = RunLedger.update(ctx.store, "run", %{verifier_round: 3})
    assert {:error, :verifier_repair_block_not_current} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED'").rows == []
  end

  @tag verifier_repair_authorization: true
  test "live tick and exhausted budgets deny staging without mutating original BLOCK", ctx do
    {:ok, before} = RunLedger.get(ctx.store, "run")
    %{result: "ACQUIRED", tick_id: tick} = Control.acquire_tick(ctx.store, ctx.factory, ctx.factory.dispatcher_id)
    assert {:error, :verifier_repair_control_busy} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert %{result: "RELEASED"} = Control.release_tick(ctx.store, ctx.factory, ctx.factory.dispatcher_id, tick)
    assert {:error, :verifier_repair_admission_unavailable} = TicketVerifierRepair.stage(ctx.store, ctx.input, %{ctx.factory | maximum_code_repair_rounds: 8}, ctx.options)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
  end

  @tag verifier_repair_authorization: true
  test "APPLIED event failure rolls back state and counter; retained authorization can apply once after restart", ctx do
    assert {:ok, _} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "CREATE TRIGGER refuse_verifier_apply BEFORE INSERT ON events WHEN NEW.event_type='TICKET_VERIFIER_REPAIR_APPLIED' BEGIN SELECT RAISE(ABORT,'apply fault'); END")
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})

    assert_raise Exqlite.Error, fn ->
      TickLease.run(ctx.factory, fn tick -> Scheduler.ticket_step(ctx.context, "run", Keyword.merge(ctx.options, ordinary_controller_tick: true, operator_tick: tick)) end, control_server: server)
    end

    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT id FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'").rows == []
    Store.query!(ctx.store, "DROP TRIGGER refuse_verifier_apply")

    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}} =
             TickLease.run(
               ctx.factory,
               fn tick -> Scheduler.ticket_step(ctx.context, "run", Keyword.merge(ctx.options, ordinary_controller_tick: true, operator_tick: tick)) end,
               control_server: server
             )
  end

  @tag verifier_repair_authorization: true
  test "a later independently BLOCKed verifier needs its own approval and ignores already applied authority", ctx do
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})
    assert {:ok, _} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}} = owned_apply(ctx, server)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING", verifier_round: 3})
    task_key = "run:change-verifier:3"
    {:ok, previous} = TaskLedger.get(ctx.store, "run:change-verifier:2")
    {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    assert {:ok, _} = TaskLedger.register(ctx.store, Map.merge(previous, %{"task_key" => task_key, "status" => "STARTING", "thread_id" => nil, "prompt_sha256" => digest(prompt)}))
    assert :ok = WorkerInstructions.bind_task(ctx.store, task_key, digest(prompt), Jason.decode!(prompt)["instruction_binding_sha256"])
    request = "verifier-request-3"
    attrs = TicketWorkerFixture.attrs(ctx, "REVIEW", "verifier-3") |> Map.merge(%{"task_key" => task_key, "request_key" => request})
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs, TicketWorkerFixture.opts(ctx))

    options = [
      store: ctx.store,
      target_key: task_key,
      request_key: request,
      reservation_key: "verifier-3",
      owner_id: "verifier-owner-3",
      app_server: Verifier,
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      review_base_sha: ctx.sha
    ]

    assert {:ok, _} = TicketWorkerRunner.run(ctx.path, %Issue{identifier: "PPL-123", title: "Fixture"}, prompt, StageSchemas.for_stage(:change_verifier), options)
    assert {:ok, %{run: %{"state" => "FAILED"}}} = Scheduler.ticket_step(ctx.context, "run", ctx.options)
    assert {:ran, {:error, :ticket_role_stage_not_admitted}} = owned_apply(ctx, server)
    evidence = Store.one!(ctx.store, "SELECT * FROM worker_evidence WHERE request_key=?", [request])
    input = Map.merge(ctx.input, %{"authorization_key" => "second-explicit-approval", "verifier_request_key" => request, "verifier_output_sha256" => evidence["output_sha256"]})
    assert {:ok, _} = TicketVerifierRepair.stage(ctx.store, input, ctx.factory, ctx.options)
    assert {:ran, {:ok, %{status: "VERIFIER_REPAIR_APPLIED", run: run}}} = owned_apply(ctx, server)
    assert run["code_repair_round"] == 10
    assert run["implementation_iteration"] == 21
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'")["count"] == 2
  end

  defp owned_apply(ctx, server) do
    TickLease.run(ctx.factory, fn tick -> Scheduler.ticket_step(ctx.context, "run", Keyword.merge(ctx.options, ordinary_controller_tick: true, operator_tick: tick)) end, control_server: server)
  end

  @tag verifier_repair_authorization: true
  test "concurrent same approval and owned application have one immutable winner", ctx do
    results = for _ <- 1..2, do: Task.async(fn -> TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options) end)
    assert [{:ok, receipt}, {:ok, receipt}] = Enum.map(results, &Task.await(&1, 30_000))
    assert {:error, :verifier_repair_authorization_conflict} = TicketVerifierRepair.stage(ctx.store, Map.put(ctx.input, "authorization_key", "another-key"), ctx.factory, ctx.options)
    server = start_supervised!({ControlServer, [store: ctx.store, factory: ctx.factory, name: nil]})

    assert {:ran, results} =
             TickLease.run(
               ctx.factory,
               fn tick ->
                 for(
                   _ <- 1..2,
                   do: Task.async(fn -> TicketVerifierRepair.apply_authorized(ctx.store, "run", ctx.factory, Keyword.merge(ctx.options, ordinary_controller_tick: true, operator_tick: tick)) end)
                 )
                 |> Enum.map(&Task.await(&1, 30_000))
               end,
               control_server: server
             )

    assert Enum.count(results, &match?({:ok, %{status: "VERIFIER_REPAIR_APPLIED"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :verifier_repair_authorization_unavailable}, &1)) == 1
    assert {:ok, replay} = TicketVerifierRepair.stage(ctx.store, ctx.input, ctx.factory, ctx.options)
    assert replay == %{receipt | status: "VERIFIER_REPAIR_APPLIED"}
  end

  @tag verifier_repair_authorization: true
  @tag verifier_repair_default_tick: true
  test "fresh actual ticket CLI uses default Jira transport in controller workspace and replays its exact Unicode approval", ctx do
    input = Map.put(ctx.input, "repair_instructions", "Preserve ✓ Unicode, quotes \"and\" newlines\nwithout native-parent fabrication.")
    trace = TicketChatFixture.runtime_fixture(ctx.root)
    workflow = Workflow.workflow_file_path()
    {:ok, loaded} = Workflow.load(workflow)
    workspace_root = Path.join(ctx.root, "operator-workspaces")
    config = loaded.config |> Map.put("factory", %{"database" => ctx.database}) |> Map.put("workspace", %{"root" => workspace_root})
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nPrivate default Jira transport.\n")
    Workflow.set_workflow_file_path(workflow)
    {:ok, settings} = Schema.parse(config)
    workspace = Path.join([workspace_root, "factory-controller", ctx.factory.scope])
    File.mkdir_p!(workspace)
    {:ok, before} = RunLedger.get(ctx.store, "run")
    snapshot = Jason.decode!(before["snapshot_json"])
    comments = Enum.with_index(snapshot["comments"], fn comment, index -> Map.put(comment, "id", "comment-#{index}") end)

    raw_issue =
      Map.merge(snapshot, %{
        "key" => "PPL-123",
        "summary" => "Fixture",
        "description" => "",
        "status" => "In Dev",
        "labels" => ["ai-running", "repo-grail"],
        "project_key" => "PPL",
        "comments" => comments
      })

    reply = Jason.encode!(%{"id" => 14, "result" => %{"structuredContent" => raw_issue}})
    search_reply = Jason.encode!(%{"id" => 14, "result" => %{"structuredContent" => %{"issues" => []}}})
    assert not String.contains?(reply, "'")

    cases = """
      *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"operator-jira"}}}'; printf '%s\\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"Jira","status":"ready"}}' ;;
      *'"method":"mcpServer/tool/call"'*'"tool":"jira_search"'*) printf '%s\\n' '#{search_reply}' ;;
      *'"method":"mcpServer/tool/call"'*) printf '%s\\n' '#{reply}' ;;
      *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
    """

    command = Path.join(ctx.root, "runtime-fixture")
    File.write!(command, String.replace(File.read!(command), "esac", cases <> "esac"))

    roles =
      Map.new(
        ~w(orchestrator orchestrator-intake specification-author specification-critic feature-planner feature-writer feature-writer-high-risk change-verifier manual-validator explorer failure-triager),
        &{&1, %{"provider" => "codex", "model_class" => "test", "reasoning_effort" => "medium"}}
      )

    models = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"test" => "gpt-test"}},
      "roles" => roles,
      "delivery_routing" => %{"default_role" => "feature-writer", "high_risk_role" => "feature-writer-high-risk", "high_risk_values" => ["high"], "unknown_risk_is_high" => true}
    }

    route = Map.merge(ctx.factory.repositories["grail"], %{"codex_project_id" => "fixture", "gitlab_project" => "fixture/project", "route_labels" => ["repo-grail"]})

    # This default CLI path observes real disk; its transport fixture must not require a production-sized writer slot.
    factory =
      Map.from_struct(settings.factory)
      |> Map.merge(ctx.factory)
      |> Map.merge(%{
        database: ctx.database,
        writer_disk_gb: 1,
        task_transport: "desktop_broker",
        cleanup: %{"enabled" => false},
        review_feedback: %{"enabled" => false},
        models: models,
        repositories: %{"grail" => route},
        queue: %{"assignee" => "currentUser()", "statuses" => ["In Dev"], "factory_labels" => ["ai-running"]},
        ticket_supervisor: Map.put(ctx.factory.ticket_supervisor, "ticket_workflow", workflow)
      })

    assert :ok = Policy.validate(factory)
    start_supervised!({BrokerRuntime, store: ctx.store, factory: factory, name: nil})
    payload = input |> Jason.encode!() |> Base.encode64()
    invoke = fn -> ExUnit.CaptureIO.capture_io(fn -> Ticket.run(["authorize-verifier-repair", "run", "--workflow", workflow, "--payload-base64", payload]) end) |> Jason.decode!() end
    result = invoke.()
    assert result["status"] == "VERIFIER_REPAIR_AUTHORIZED"
    assert invoke.() == result
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    calls = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [start] = Enum.filter(calls, &(&1["method"] == "thread/start"))
    assert start["params"]["cwd"] == workspace
    assert start["params"]["ephemeral"] == true
    assert [read] = Enum.filter(calls, &(&1["method"] == "mcpServer/tool/call"))
    assert read["params"]["server"] == "Jira" and read["params"]["tool"] == "jira_get_issue"
    refute Enum.any?(calls, &(&1["method"] in ["turn/start", "thread/resume"]))

    assert {:error, :verifier_repair_authorization_invalid} =
             Ticket.runtime_authorize_verifier_repair(
               ["authorize-ticket-verifier-repair", "run", "--workflow", workflow <> ".wrong", "--payload-base64", payload],
               ctx.store,
               factory
             )

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED'")["count"] == 1

    server = start_supervised!({ControlServer, [store: ctx.store, factory: factory, name: nil]})
    context = %{ctx.context | factory: factory, workspace_root: workspace_root}

    normal_tick = fn current ->
      TickLease.run(factory, fn tick -> Scheduler.tick(current, ticket_options: [operator_tick: tick, workspace: ctx.repo]) end, control_server: server)
    end

    outside = %{context | workspace_root: Path.join(ctx.root, "outside-controller")}
    assert {:ran, {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}}} = normal_tick.(outside)
    assert {:ok, ^before} = RunLedger.get(ctx.store, "run")
    assert {:ran, {:ok, %{launches: []} = applied_tick}} = normal_tick.(context)
    assert Enum.any?(applied_tick.events, &(&1.event == "TICKET_VERIFIER_REPAIR_APPLIED"))
    assert {:ok, repaired} = RunLedger.get(ctx.store, "run")
    assert repaired["state"] == "REPAIRING"
    assert repaired["code_repair_round"] == before["code_repair_round"] + 1
    assert repaired["implementation_iteration"] == before["implementation_iteration"]
    assert invoke.()["status"] == "VERIFIER_REPAIR_APPLIED"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type='TICKET_VERIFIER_REPAIR_APPLIED'")["count"] == 1
    assert Store.query!(ctx.store, "SELECT reservation_key FROM workspace_access WHERE released_at IS NULL").rows == []
    calls = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    starts = Enum.filter(calls, &(&1["method"] == "thread/start"))
    assert length(starts) == 3
    assert Enum.all?(starts, &(&1["params"]["cwd"] == workspace and &1["params"]["ephemeral"] == true))
    reads = Enum.filter(calls, &(&1["method"] == "mcpServer/tool/call"))
    assert Enum.map(reads, & &1["params"]["tool"]) == ~w(jira_get_issue jira_search jira_get_issue)
    refute Enum.any?(calls, &(&1["method"] in ["turn/start", "thread/resume"]))
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
