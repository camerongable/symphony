defmodule SymphonyElixir.FactoryTicketParentAdmissionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{DesktopRequest, DesktopToolArgs, RunLedger, Scheduler, Store}
  alias SymphonyElixir.Factory.{TicketChat, TicketChatOutbox, TicketParentGuard}
  alias SymphonyElixir.Factory.TicketContextReader
  alias SymphonyElixir.TicketChatFixture

  @broker "019fa5b7-27fa-7660-ab47-7c3abb867c91"
  @other_broker "019fa5b7-27fa-7660-ab47-7c3abb867c92"

  setup context do
    ctx = TicketChatFixture.setup_fixture(context)
    runtime_trace = TicketChatFixture.runtime_fixture(ctx.root)
    {contract, snapshot} = TicketChatFixture.authorized_contract("PPL-456", "id-456")

    {:ok, _} =
      RunLedger.register(ctx.store, %{
        run_id: "new-run",
        issue_key: "PPL-456",
        repo_key: "grail",
        kind: "DELIVERY",
        state: "ADMITTING_WRITER",
        execution_mode: "TICKET_SUPERVISOR_V1",
        repo_path: Path.join(ctx.root, "source"),
        snapshot_json: Jason.encode!(snapshot),
        spec_revision: contract.revision,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        manual_validation_required: 0
      })

    models = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"fast" => "gpt-6-luna"}},
      "roles" => %{"orchestrator-intake" => %{"model_class" => "fast", "reasoning_effort" => "low"}}
    }

    factory = %{scope: "scope", models: models, ticket_supervisor: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123", "PPL-456"]}}
    workflow = Path.join(ctx.root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\n")
    cli_root = Path.expand("../..", __DIR__)
    opts = [parent_output_root: ctx.root, broker_thread_id: @broker, ticket_cli_root: cli_root, ticket_workflow: workflow]
    Map.merge(ctx, %{context: %{store: ctx.store, factory: factory}, opts: opts, runtime_trace: runtime_trace})
  end

  test "parent-only admission reuses one CREATE across duplicate calls and restart without source work", ctx do
    {:ok, before} = RunLedger.get(ctx.store, "new-run")
    tasks = Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows
    assert {:ok, first} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert first.status == "PARENT_PENDING"
    refute first.model_invoked
    assert {:ok, ^first} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    concurrent = for _ <- 1..3, do: Task.async(fn -> Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts) end)
    for task <- concurrent, do: assert(Task.await(task) == {:ok, first})
    assert {:ok, request} = DesktopRequest.get(ctx.store, first.request_key)
    assert request["action"] == "CREATE"
    assert request["model"] == "gpt-6-luna"
    assert request["reasoning_effort"] == "low"
    assert request["title"] == "PPL-456 · Ticket"
    assert Jason.decode!(request["metadata_json"])["broker_thread_id"] == @broker
    assert {:ok, args} = DesktopToolArgs.create_thread(request)
    assert args["target"]["type"] == "projectless"
    assert {:ok, chat} = TicketChat.for_run(ctx.store, "new-run")
    refute File.exists?(chat["cwd"])
    assert chat["broker_thread_id"] == @broker
    reader = Jason.decode!(chat["context_reader_json"])
    assert reader["run_id"] == "new-run"
    assert reader["cwd"] == ctx.opts[:ticket_cli_root]
    assert reader["workflow"] == ctx.opts[:ticket_workflow]
    assert reader["arguments"] == ["context", "new-run", "--workflow", ctx.opts[:ticket_workflow]]
    assert reader["command"] =~ "./scripts/factory-broker ticket context"
    refute reader["command"] =~ "mix run"
    assert request["prompt"] =~ chat["context_reader_json"]
    assert request["prompt"] =~ "You may stage only an explicit command from that direct human message"
    assert {:ok, ^before} = RunLedger.get(ctx.store, "new-run")
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks").rows == tasks
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == []
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access").rows == []
    methods = ctx.runtime_trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["method"])
    assert Enum.count(methods, &(&1 == "initialize")) == 1
    assert Enum.count(methods, &(&1 == "initialized")) <= 1
    assert Enum.all?(methods, &(&1 in ~w(initialize initialized)))
    assert {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, ^first} = Scheduler.ticket_parent_step(%{ctx.context | store: reopened}, "new-run", ctx.opts)
      assert Store.query!(reopened, "SELECT request_key FROM desktop_requests WHERE target_key = ?", [first.chat_key]).rows == [[first.request_key]]
    after
      GenServer.stop(reopened)
    end
  end

  test "unqualified runtime rejects a new parent without changing any run or request", ctx do
    TicketChatFixture.runtime_fixture(ctx.root, %{})
    before = Enum.map(~w(runs ticket_chats ticket_chat_runs desktop_requests), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    assert {:error, :worker_runtime_identity_unproven} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert Enum.map(~w(runs ticket_chats ticket_chat_runs desktop_requests), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == before
  end

  test "run drift during initialization rejects reservation after an outside-transaction probe", ctx do
    command = "/usr/bin/sqlite3 '#{ctx.database}' \"UPDATE runs SET state = 'BLOCKED' WHERE run_id = 'new-run'\" || exit 1"
    TicketChatFixture.runtime_fixture(ctx.root, :supported, command)
    before = Enum.map(~w(ticket_chats ticket_chat_runs desktop_requests), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    assert {:error, :ticket_parent_run_changed} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert {:ok, %{"state" => "BLOCKED"}} = RunLedger.get(ctx.store, "new-run")
    assert Enum.map(~w(ticket_chats ticket_chat_runs desktop_requests), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == before
  end

  test "uncertain bootstrap is retained; exact observed ACK becomes ready and retains broker on presentations", ctx do
    {:ok, parent} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    policy = [ticket_policy: ctx.context.factory.ticket_supervisor]
    assert {:ok, claimed} = DesktopRequest.claim(ctx.store, parent.request_key, policy)
    assert {:ok, pending} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert pending.status == "PARENT_PENDING"
    assert pending.request_key == parent.request_key
    File.mkdir_p!(claimed["cwd"])
    {:ok, args} = DesktopToolArgs.create_thread(claimed)

    proof = %{
      "request_key" => parent.request_key,
      "payload_sha256" => claimed["payload_sha256"],
      "generation" => 1,
      "thread_id" => "new-parent",
      "project_id" => nil,
      "cwd" => claimed["cwd"],
      "tool_arguments" => args,
      "worktree_attachments" => []
    }

    assert {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, parent.request_key, proof)

    assert {:ok, _} =
             DesktopRequest.complete(ctx.store, parent.request_key, %{thread_id: "new-parent", turn_id: "bootstrap", output: %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}})

    assert {:ok, ready} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert ready.status == "PARENT_READY"
    assert ready.thread_id == "new-parent"
    assert {:ok, queued} = TicketChatOutbox.publish(ctx.store, "new-run")
    assert {:ok, request} = DesktopRequest.get(ctx.store, queued.request_key)
    assert {:error, :ticket_chat_runtime_not_integrated} = DesktopToolArgs.followup(ctx.store, queued.request_key)
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, queued.request_key)
    assert {:ok, _} = DesktopToolArgs.followup(ctx.store, queued.request_key, policy)
    assert Jason.decode!(request["metadata_json"])["broker_thread_id"] == @broker
    assert request["prompt"] =~ "Controller-observed AS-OF presentation only"
    assert request["prompt"] =~ "do not claim it is current at render time or claim a parent refresh"
    assert request["prompt"] =~ "do not refresh, call tools, stage, or perform source"
    guard = TicketChatFixture.parent_guard(%{ctx | cwd: claimed["cwd"]})
    guard = put_in(guard, ["owner", "response", "thread", "id"], "new-parent")
    guard = put_in(guard, ["native", "id"], "new-parent")
    guard = put_in(guard, ["native", "queue_observation", "thread_id"], "new-parent")
    assert {:ok, receipt} = TicketParentGuard.receipt(request, guard, DateTime.utc_now())
    assert receipt["source_thread_id"] == @broker
    assert {:error, :parent_broker_identity_mismatch} = TicketParentGuard.receipt(request, Map.put(guard, "source_thread_id", @other_broker), DateTime.utc_now())
    assert {:ok, _} = DesktopRequest.claim(ctx.store, queued.request_key, Keyword.put(policy, :parent_guard, guard))
    wrong_native = %{"id" => "new-parent", "cwd" => claimed["cwd"], "projectId" => nil, "turns" => []}
    assert {:error, :parent_broker_identity_mismatch} = TicketChat.observe_native_turn(ctx.store, queued.request_key, @other_broker, wrong_native)
  end

  test "a negative CREATE remains failed until its deterministic same-parent recovery is proven", ctx do
    {:ok, parent} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    policy = [ticket_policy: ctx.context.factory.ticket_supervisor]
    {:ok, create} = DesktopRequest.claim(ctx.store, parent.request_key, policy)
    File.mkdir_p!(create["cwd"])
    {:ok, create_args} = DesktopToolArgs.create_thread(create)

    create_proof = %{
      "request_key" => create["request_key"],
      "payload_sha256" => create["payload_sha256"],
      "generation" => 1,
      "thread_id" => "new-parent",
      "project_id" => nil,
      "cwd" => create["cwd"],
      "tool_arguments" => create_args,
      "worktree_attachments" => []
    }

    assert {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, create["request_key"], create_proof)

    artifact = %{"server" => "codex_app", "tool" => "list_artifacts", "arguments" => %{}, "result" => %{"content" => [%{"type" => "text", "text" => "{\"artifacts\":[]}"}]}}

    negative = %{
      "result" => %{"acknowledged" => false},
      "completed_tool_calls" => [],
      "bootstrap_evidence" => %{"list_artifacts" => [artifact], "completed_commands" => []},
      "native_readback_sha256" => String.duplicate("a", 64)
    }

    assert {:ok, failed} = DesktopRequest.complete(ctx.store, create["request_key"], %{"thread_id" => "new-parent", "turn_id" => "negative-create", "output" => negative})
    assert failed["status"] == "FAILED"
    assert {:ok, pending} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert pending.status == "PARENT_PENDING"
    assert pending.request_key == create["request_key"] <> ":bootstrap-recovery:1"
    assert {:error, :ticket_chat_parent_not_ready} = TicketChat.ready_for_run(ctx.store, "new-run")
    {:ok, recovery_request} = DesktopRequest.get(ctx.store, pending.request_key)
    assert recovery_request["action"] == "FOLLOWUP"
    assert recovery_request["existing_thread_id"] == "new-parent"
    assert {:ok, same_pending} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert same_pending.request_key == pending.request_key
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND action = 'FOLLOWUP'")["count"] == 1

    guard = TicketChatFixture.parent_guard(%{cwd: recovery_request["cwd"]})
    guard = put_in(guard, ["owner", "response", "thread", "id"], "new-parent") |> put_in(["native", "id"], "new-parent") |> put_in(["native", "queue_observation", "thread_id"], "new-parent")
    {:ok, recovery} = DesktopRequest.claim(ctx.store, pending.request_key, Keyword.put(policy, :parent_guard, guard))
    {:ok, recovery_args} = DesktopToolArgs.followup(recovery)

    recovery_proof = %{
      "request_key" => recovery["request_key"],
      "payload_sha256" => recovery["payload_sha256"],
      "generation" => 1,
      "thread_id" => "new-parent",
      "project_id" => nil,
      "cwd" => recovery["cwd"],
      "tool_arguments" => recovery_args,
      "worktree_attachments" => []
    }

    assert {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, recovery["request_key"], recovery_proof)

    locator = Jason.decode!(TicketChat.for_run(ctx.store, "new-run") |> elem(1) |> Map.fetch!("context_reader_json"))

    positive = %{
      "result" => %{"acknowledged" => true},
      "completed_tool_calls" => [],
      "bootstrap_evidence" => %{
        "list_artifacts" => [artifact],
        "completed_commands" => [%{"status" => "completed", "exit_code" => 0, "cwd" => locator["cwd"], "command_actions" => [%{"command" => locator["command"]}]}]
      },
      "native_readback_sha256" => String.duplicate("b", 64)
    }

    assert {:ok, recovered} = DesktopRequest.complete(ctx.store, recovery["request_key"], %{"thread_id" => "new-parent", "turn_id" => "positive-recovery", "output" => positive})
    assert recovered["status"] == "SUCCEEDED"
    assert Jason.decode!(recovered["target_observation_json"])["native_readback_sha256"] == String.duplicate("b", 64)

    assert not Map.has_key?(
             Jason.decode!(Store.one!(ctx.store, "SELECT observation_json FROM ticket_chats WHERE chat_key = ?", [recovery["target_key"]])["observation_json"]),
             "native_readback_sha256"
           )

    assert {:ok, _} = TicketChat.ready_for_run(ctx.store, "new-run")
    assert {:ok, ready} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert ready.status == "PARENT_READY"
    assert ready.thread_id == "new-parent"
    assert {:ok, again} = DesktopRequest.complete(ctx.store, recovery["request_key"], %{"thread_id" => "new-parent", "turn_id" => "positive-recovery", "output" => positive})
    assert again == recovered
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'new-run'").rows == []
  end

  test "missing roots, broker, disabled or disallowed policies and ineligible contracts reject before reservation", ctx do
    count = Store.query!(ctx.store, "SELECT * FROM ticket_chats").rows

    cases = [
      {ctx.context, Keyword.delete(ctx.opts, :parent_output_root), :ticket_parent_output_root_required},
      {ctx.context, Keyword.put(ctx.opts, :parent_output_root, "relative"), :ticket_parent_output_root_required},
      {ctx.context, Keyword.put(ctx.opts, :parent_output_root, Path.join(ctx.root, "absent")), :ticket_parent_output_root_invalid},
      {ctx.context, Keyword.delete(ctx.opts, :broker_thread_id), :parent_broker_identity_invalid},
      {ctx.context, Keyword.put(ctx.opts, :broker_thread_id, "unknown"), :parent_broker_identity_invalid},
      {ctx.context, Keyword.delete(ctx.opts, :ticket_cli_root), :ticket_context_reader_unavailable},
      {ctx.context, Keyword.delete(ctx.opts, :ticket_workflow), :ticket_context_reader_unavailable},
      {put_in(ctx.context, [:factory, :ticket_supervisor, "enabled"], false), ctx.opts, :ticket_chat_runtime_not_integrated},
      {put_in(ctx.context, [:factory, :ticket_supervisor, "pilot_issue_keys"], []), ctx.opts, :ticket_chat_not_allowlisted}
    ]

    for {context, opts, error} <- cases do
      assert {:error, ^error} = Scheduler.ticket_parent_step(context, "new-run", opts)
      assert Store.query!(ctx.store, "SELECT * FROM ticket_chats").rows == count
    end

    {:ok, _} = RunLedger.update(ctx.store, "new-run", %{manual_validation_required: 1})
    assert {:error, :ticket_chat_validation_flag_mismatch} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chats").rows == count
  end

  test "changing broker or output root never retargets an existing parent, nor fills historical missing binding", ctx do
    {:ok, parent} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    other_root = Path.join(ctx.root, "other-output")
    File.mkdir_p!(other_root)
    assert {:error, :ticket_chat_identity_conflict} = Scheduler.ticket_parent_step(ctx.context, "new-run", Keyword.put(ctx.opts, :parent_output_root, other_root))
    assert {:error, :ticket_chat_identity_conflict} = Scheduler.ticket_parent_step(ctx.context, "new-run", Keyword.put(ctx.opts, :broker_thread_id, @other_broker))
    assert {:error, :ticket_chat_identity_conflict} = Scheduler.ticket_parent_step(ctx.context, "run", ctx.opts)
    assert {:ok, ^parent} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    assert {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    assert chat["broker_thread_id"] == nil
  end

  test "dated deployment explicitly rehomes only the unissued reservation and retains issued cwd", ctx do
    {:ok, original} = Scheduler.ticket_parent_step(ctx.context, "new-run", ctx.opts)
    {:ok, run} = RunLedger.get(ctx.store, "new-run")
    dated = Path.join(ctx.root, "desktop/{date}")
    opts = Keyword.put(ctx.opts, :parent_output_root, dated)
    assert {:ok, rebound} = Scheduler.ticket_parent_step(ctx.context, "new-run", opts)
    assert rebound.request_key == original.request_key
    assert {:ok, request} = DesktopRequest.get(ctx.store, rebound.request_key)
    assert Path.dirname(request["cwd"]) == TicketChat.output_root(dated)
    assert request["prompt"] =~ "./scripts/factory-broker ticket context"
    refute File.exists?(request["cwd"])
    assert {:ok, ^run} = RunLedger.get(ctx.store, "new-run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'CREATE_UNCERTAIN', claimed_at = ? WHERE request_key = ?", [DateTime.to_iso8601(DateTime.utc_now()), rebound.request_key])
    other_day = Path.join(ctx.root, "another-day/{date}")
    assert {:ok, _} = Scheduler.ticket_parent_step(ctx.context, "new-run", Keyword.put(opts, :parent_output_root, other_day))
    assert {:ok, issued} = DesktopRequest.get(ctx.store, rebound.request_key)
    assert issued["cwd"] == request["cwd"]
    assert issued["payload_sha256"] == request["payload_sha256"]
  end

  test "reader binds the current ledger and rejects changed or malformed command locators", ctx do
    assert {:ok, locator} = TicketContextReader.bind(ctx.store, "new-run", ctx.opts)
    assert :ok = TicketContextReader.validate(ctx.store, "new-run", locator)
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.validate(ctx.store, "other-run", locator)
    changed = locator |> Jason.decode!() |> Map.put("command", "mix factory.ticket stage new-run") |> Jason.encode!()
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.validate(ctx.store, "new-run", changed)
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.validate(ctx.store, "new-run", "not-json")
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.validate(ctx.store, "new-run", %{})
    workflow = Path.join(ctx.root, "other-workflow.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{Path.join(ctx.root, "absent.sqlite")}\n---\n")
    assert {:error, :ticket_context_reader_unavailable} = Scheduler.ticket_parent_step(ctx.context, "new-run", Keyword.put(ctx.opts, :ticket_workflow, workflow))
    assert {:error, :unknown_ticket_chat} = TicketChat.for_run(ctx.store, "new-run")
    refute File.exists?(Path.join(ctx.root, "absent.sqlite"))
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: relative.sqlite\n---\n")
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.bind(ctx.store, "new-run", Keyword.put(ctx.opts, :ticket_workflow, workflow))
  end

  test "reader command survives delegation escaping and retains exact legacy bindings", ctx do
    assert {:ok, json} = TicketContextReader.bind(ctx.store, "new-run", ctx.opts)
    locator = Jason.decode!(json)
    command = locator["command"]
    refute command =~ ">"
    assert command == String.replace(command, ">", "&gt;")
    assert OptionParser.split(command) == ["./scripts/factory-broker", "ticket" | locator["arguments"]]
    encoded = locator["arguments"] |> Jason.encode!() |> Base.encode64()
    legacy_command = "mise exec -- mix run --no-compile --no-start -e 'Mix.Tasks.Factory.Ticket.run(Base.decode64!(\"#{encoded}\") |> Jason.decode!())'"
    legacy = locator |> Map.put("command", legacy_command) |> Jason.encode!()
    assert :ok = TicketContextReader.validate(ctx.store, "new-run", legacy)
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.validate(ctx.store, "other-run", legacy)
    changed = locator |> Map.put("command", command <> "; echo unsafe") |> Jason.encode!()
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.validate(ctx.store, "new-run", changed)
  end

  test "bound legacy locator bytes survive rebinding without changing chat identity", ctx do
    assert {:ok, json} = TicketContextReader.bind(ctx.store, "run", ctx.opts)
    locator = Jason.decode!(json)
    encoded = locator["arguments"] |> Jason.encode!() |> Base.encode64()
    legacy_command = "mise exec -- mix run --no-compile --no-start -e 'Mix.Tasks.Factory.Ticket.run(Base.decode64!(\"#{encoded}\") |> Jason.decode!())'"
    legacy = locator |> Map.put("command", legacy_command) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE ticket_chats SET context_reader_json = ? WHERE chat_key = ?", [legacy, ctx.chat["chat_key"]])
    assert {:ok, ^legacy} = TicketContextReader.bind(ctx.store, "run", ctx.opts)
    assert :ok = TicketContextReader.validate(ctx.store, "run", legacy)
    assert {:ok, safe} = TicketContextReader.execution_locator(legacy)
    assert Jason.decode!(safe) == locator
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.execution_locator(Jason.encode!(Map.put(locator, "command", "echo unsafe")))
    assert Store.one!(ctx.store, "SELECT context_reader_json FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])["context_reader_json"] == legacy
  end

  test "reader quotes literal arguments instead of interpolating executable shell or Elixir text", ctx do
    assert {:ok, json} = TicketContextReader.bind(ctx.store, "run'$(false)", ctx.opts)
    reader = Jason.decode!(json)
    assert OptionParser.split(reader["command"]) == ["./scripts/factory-broker", "ticket" | reader["arguments"]]
    assert reader["command"] =~ "'run'\"'\"'$(false)'"
    assert Enum.at(reader["arguments"], 1) == "run'$(false)"
    assert TicketContextReader.instructions(nil) =~ "do not present the incoming snapshot as fresh"
  end

  test "reader instructions permit only pending staging of a later direct human message", ctx do
    assert {:ok, locator} = TicketContextReader.bind(ctx.store, "new-run", ctx.opts)
    instructions = TicketContextReader.instructions(locator)

    assert instructions =~ "Refresh durable context"
    assert instructions =~ "This refresh is read-only"
    assert instructions =~ "in that same turn before staging"
    assert instructions =~ "a refresh from an earlier turn is not sufficient"
    assert instructions =~ "direct human message"
    assert instructions =~ "explicit command from that direct human message"
    assert instructions =~ "./scripts/factory-broker ticket details RUN ARTIFACT_REF --offset 0 --limit 4096 --workflow WORKFLOW.md"
    assert instructions =~ "Follow a returned next_offset only with the same reference"
    assert instructions =~ "./scripts/factory-broker ticket stage RUN --payload-base64 BASE64_JSON --workflow WORKFLOW.md"
    assert instructions =~ "cwd set to this locator's cwd"
    assert instructions =~ "Encoding and staging are separate commands"
    assert instructions =~ "Never stage through mix run -e, Mix.Tasks.Factory.Ticket.run"
    assert instructions =~ "do not provide an admissible staging receipt"
    assert instructions =~ "Preserve every trailing newline"
    assert instructions =~ "do not trim or normalize either"
    assert instructions =~ "Preserve the direct message body byte-for-byte"
    assert instructions =~ "JSON must contain exactly proposal_id, body, operations, generation, spec_revision, contract_sha256, and candidate_sha"
    assert instructions =~ "value exactly matching one declared answer"
    assert instructions =~ "For one explicit answer, operations must contain exactly one object with operation `answer_question`"
    assert instructions =~ "For `Revise the contract:\n` followed by the complete replacement Markdown"
    assert instructions =~ "exactly one `propose_contract_revision` operation whose markdown is the complete suffix"
    assert instructions =~ "exact message `Rework the current candidate.`"
    assert instructions =~ "exactly one `request_rework` operation and no other operation"
    assert instructions =~ "do not supply question_digest"
    assert instructions =~ "keep proposal_id stable for retries of that exact input"
    assert instructions =~ "If the grammar, operation schema, or exact binding is unavailable, report that you cannot stage"
    assert instructions =~ "report refresh unavailable and do not stage"
    assert instructions =~ "PENDING"
    assert instructions =~ "do not apply"
    assert instructions =~ "do not stage this controller presentation"
    assert instructions =~ "Do not invoke other broker actions, scheduler, source, Jira, GitLab, or delivery actions"
    assert TicketContextReader.instructions(nil) =~ "or stage any proposal"
  end
end
