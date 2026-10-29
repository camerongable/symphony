defmodule SymphonyElixir.FactoryTicketChatTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{Contract, DesktopRequest, DesktopToolArgs, RunLedger, Store, TaskLedger, TicketChat}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TicketChatFixture

  test "parent preflight validates missing fields before constructing its prompt", ctx do
    assert {:error, {:missing_ticket_chat_fields, missing}} = TicketChat.preflight(ctx.store, %{}, %{})
    assert "prompt" in missing
  end

  test "only an unissued parent can be rehomed with audited request rebinding", ctx do
    original = attrs(ctx.root)
    {:ok, first} = TicketChat.reserve(ctx.store, "run-one", original)
    root = Path.join(ctx.root, "desktop-date")
    File.mkdir_p!(root)
    relocated = %{original | cwd: Path.join(root, first.chat["directory_name"])}
    {:ok, run} = RunLedger.get(ctx.store, "run-one")
    assert {:error, :ticket_chat_identity_conflict} = TicketChat.reserve(ctx.store, "run-one", relocated)
    assert {:ok, _} = TicketChat.rehome_unissued(ctx.store, "run-one", relocated, run)
    assert {:ok, rebound} = TicketChat.reserve(ctx.store, "run-one", relocated)
    assert rebound.chat["chat_key"] == first.chat["chat_key"]
    assert rebound.request["request_key"] == first.request["request_key"]
    assert rebound.request["payload_sha256"] != first.request["payload_sha256"]
    assert DesktopRequest.payload_intact?(rebound.request)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run-one")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'ticket_parent_unissued_rehomed'") == %{"count" => 1}
    simulate_claim(ctx.store, rebound.request)
    assert {:error, :ticket_chat_identity_conflict} = TicketChat.reserve(ctx.store, "run-one", original)
    assert {:error, :ticket_chat_identity_conflict} = TicketChat.rehome_unissued(ctx.store, "run-one", original, run)
  end

  test "dated parent creation refuses yesterday's binding and occupied leaf", ctx do
    root = Path.join(ctx.root, "{date}")
    policy = %{"parent_output_root" => root}
    assert {:error, :ticket_chat_creation_date_changed} = TicketChat.creation_root_current(%{"action" => "CREATE", "cwd" => Path.join(ctx.root, "old-date/parent")}, policy)
    cwd = Path.join(TicketChat.output_root(root), "parent")
    assert :ok = TicketChat.creation_root_current(%{"action" => "CREATE", "cwd" => cwd}, policy)
    File.mkdir_p!(cwd)
    assert {:error, :ticket_chat_creation_path_collision} = TicketChat.creation_root_current(%{"action" => "CREATE", "cwd" => cwd}, policy)
    assert :ok = TicketChat.creation_root_current(%{"action" => "FOLLOWUP", "cwd" => cwd}, policy)
  end

  setup do
    token = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "ticket-chat-#{token}")
    File.mkdir_p!(root)
    {:ok, root} = PathSafety.canonicalize(root)
    TicketChatFixture.runtime_fixture(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "factory.sqlite")
    store = start_supervised!({Store, database: database})
    register_run(store, "run-one", "DELIVERY", root)
    %{store: store, database: database, root: root}
  end

  test "one reservation and parent are reused across delivery runs without altering source rows", ctx do
    {:ok, writer} =
      TaskLedger.register(ctx.store, %{
        task_key: "run-one:feature-writer",
        run_id: "run-one",
        stage: "WRITING",
        role: "feature-writer",
        status: "COMPLETE",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        routing_reason: "normal-writer",
        prompt_sha256: "writer-digest",
        workspace: Path.join(ctx.root, "source"),
        thread_id: "source-thread",
        codex_project_id: "real-project"
      })

    {:ok, run_before} = RunLedger.get(ctx.store, "run-one")
    assert {:ok, first} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    assert {:ok, ^first} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    assert first.chat["thread_id"] == nil
    assert first.request["codex_project_id"] == nil
    assert DesktopRequest.payload_intact?(first.request)
    simulate_claim(ctx.store, first.request)
    proof = proof(first.request)
    assert {:ok, bound} = DesktopRequest.record_ticket_thread(ctx.store, first.request["request_key"], proof)
    assert bound["verified_project_id"] == nil
    assert {:ok, ^bound} = DesktopRequest.record_ticket_thread(ctx.store, first.request["request_key"], proof)
    assert {:ok, _} = DesktopRequest.complete(ctx.store, first.request["request_key"], completion("parent-turn"))
    register_run(ctx.store, "run-two", "DELIVERY", ctx.root)

    for run_id <- ["run-two"] do
      assert {:ok, reused} = TicketChat.reserve(ctx.store, run_id, %{attrs(ctx.root) | prompt: "New phase objective"})
      assert reused.chat["thread_id"] == "parent-thread"
      assert reused.chat["chat_key"] == first.chat["chat_key"]
      assert reused.request["request_key"] == first.request["request_key"]
      assert {:ok, chat} = TicketChat.for_run(ctx.store, run_id)
      assert chat["thread_id"] == "parent-thread"
    end

    assert {:ok, ^writer} = TaskLedger.get(ctx.store, writer["task_key"])
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run-one")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chats")["count"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 1
  end

  test "ordinary delivery admission rejects inconsistent or incomplete evidence before writes", ctx do
    for malformed <- [nil, []] do
      assert {:error, :ticket_chat_run_not_eligible} = TicketChat.ordinary_delivery_eligibility(malformed)
    end

    {contract, snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-123", "## Manual Validation\n- Required: no")
    required = "## Manual Validation\n- Required: yes"
    {required_contract, required_snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-123", required)
    {missing_contract, missing_decision_snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-123", "An otherwise authorized contract without a validation declaration.")
    {malformed_contract, malformed_decision_snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-123", "## Manual Validation\n- Required: maybe")
    {:ok, original} = RunLedger.get(ctx.store, "run-one")

    missing_validation = {missing_contract, missing_decision_snapshot}
    malformed_validation = {malformed_contract, malformed_decision_snapshot}

    for {invalid_contract, invalid_snapshot} <- [missing_validation, malformed_validation] do
      invalid =
        Map.merge(original, %{
          "kind" => "DELIVERY",
          "execution_mode" => "TICKET_SUPERVISOR_V1",
          "manual_validation_required" => 0,
          "spec_revision" => invalid_contract.revision,
          "contract_sha256" => invalid_contract.sha256,
          "contract_markdown" => invalid_contract.markdown,
          "snapshot_json" => Jason.encode!(invalid_snapshot)
        })

      assert {:error, :ticket_chat_validation_not_explicitly_disabled} =
               TicketChat.ordinary_delivery_eligibility(invalid)
    end

    invalid_snapshots = [
      %{"key" => "PPL-999", "id" => "issue-123", "comments" => snapshot["comments"]},
      %{"key" => "PPL-123", "id" => "wrong-id", "comments" => snapshot["comments"]},
      %{"key" => "PPL-123", "id" => "issue-123", "comments" => "not-a-list"},
      %{"key" => "PPL-123", "id" => "issue-123", "comments" => [Contract.draft_comment(contract)]},
      %{"key" => "PPL-123", "id" => "issue-123", "comments" => [42]},
      %{"key" => "PPL-123", "id" => "issue-123", "comments" => [%{"text" => 42}]},
      %{"key" => "PPL-123", "id" => "issue-123", "comments" => []},
      %{
        "key" => "PPL-123",
        "id" => "issue-123",
        "comments" => [Contract.draft_comment(contract), "AI FACTORY AUTHORIZED issue-hex=504C2D313233 revision=1 sha256=#{contract.sha256} mode=specify-work"]
      }
    ]

    cases =
      [
        %{"kind" => "SPECIFICATION"},
        %{"execution_mode" => nil},
        %{"execution_mode" => "LEGACY"},
        %{"manual_validation_required" => nil},
        %{"manual_validation_required" => 1},
        %{"contract_sha256" => String.duplicate("0", 64)},
        %{"spec_revision" => 2},
        %{"contract_markdown" => "stale"},
        %{"snapshot_json" => Jason.encode!(required_snapshot), "contract_sha256" => required_contract.sha256, "contract_markdown" => required_contract.markdown}
      ] ++
        [%{"snapshot_json" => Jason.encode!(missing_decision_snapshot)}, %{"snapshot_json" => Jason.encode!(malformed_decision_snapshot)}] ++
        Enum.map(invalid_snapshots, &%{"snapshot_json" => Jason.encode!(&1)}) ++
        [%{"snapshot_json" => "["}, %{"snapshot_json" => nil}]

    for mutation <- cases do
      Store.query!(
        ctx.store,
        "UPDATE runs SET kind = 'DELIVERY', execution_mode = 'TICKET_SUPERVISOR_V1', manual_validation_required = 0, spec_revision = 1, contract_sha256 = ?, contract_markdown = ?, snapshot_json = ? WHERE run_id = 'run-one'",
        [contract.sha256, contract.markdown, Jason.encode!(snapshot)]
      )

      Store.query!(ctx.store, "UPDATE runs SET #{Enum.map_join(Map.keys(mutation), ", ", &(&1 <> " = ?"))} WHERE run_id = 'run-one'", Map.values(mutation))

      assert {:error, _reason} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))

      for table <- ~w(ticket_chats ticket_chat_runs desktop_requests) do
        assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM #{table}")["count"] == 0
      end
    end
  end

  test "uncertain creation survives reopen and never reserves a replacement", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    simulate_claim(ctx.store, reserved.request)
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})
    assert {:ok, reused} = TicketChat.reserve(reopened, "run-one", attrs(ctx.root))
    assert reused.request["status"] == "CREATE_UNCERTAIN"
    assert reused.chat["generation"] == 1
    assert reused.request["request_key"] == reserved.request["request_key"]
    assert {:error, :ticket_chat_runtime_not_integrated} = DesktopRequest.claim(reopened, reserved.request["request_key"])
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM desktop_requests")["count"] == 1
  end

  test "bad allocation rolls back identity, run link and request together", ctx do
    assert {:error, :unsupported_create_thread_model} = TicketChat.reserve(ctx.store, "run-one", %{attrs(ctx.root) | model: "invalid"})

    for table <- ~w(ticket_chats ticket_chat_runs desktop_requests) do
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM #{table}")["count"] == 0
    end

    assert {:ok, _} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
  end

  test "legacy and wrong issue, repository, scope or source cwd cannot be adopted", ctx do
    for mutation <- [%{issue_id: "other-id"}, %{issue_key: "PPL-999"}, %{repo_key: "other-repo"}, %{route: "other-route"}] do
      assert {:error, _} = TicketChat.reserve(ctx.store, "run-one", Map.merge(attrs(ctx.root), mutation))
    end

    {:ok, _} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    other = Map.put(attrs(ctx.root), :scope_key, "other-scope")
    other = Map.put(other, :cwd, Path.join(ctx.root, TicketChat.directory_name(other.scope_key, other.issue_id, other.repo_key)))
    assert {:error, :ticket_chat_run_already_bound} = TicketChat.reserve(ctx.store, "run-one", other)
    register_run(ctx.store, "legacy", "DELIVERY", ctx.root)
    Store.query!(ctx.store, "UPDATE runs SET execution_mode = NULL WHERE run_id = 'legacy'")
    assert {:error, :ticket_chat_run_mode_not_eligible} = TicketChat.reserve(ctx.store, "legacy", attrs(ctx.root))
    assert {:ok, %{"execution_mode" => nil}} = RunLedger.get(ctx.store, "legacy")
    register_run(ctx.store, "source-cwd", "DELIVERY", ctx.root)
    directory = TicketChat.directory_name("scope", "issue-123", "grail")
    bad = %{attrs(ctx.root) | cwd: Path.join([ctx.root, "source", directory])}
    assert {:error, :ticket_chat_source_directory_forbidden} = TicketChat.reserve(ctx.store, "source-cwd", bad)
  end

  test "projectless arguments and disabled issuance leave legacy shape isolated", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    assert {:ok, args} = DesktopToolArgs.create_thread(reserved.request)
    assert String.starts_with?(args["prompt"], "Factory request ID: #{reserved.request["request_key"]}\n")
    assert args["prompt"] =~ "end with exactly one JSON object"
    assert args["target"] == %{"type" => "projectless", "directoryName" => reserved.chat["directory_name"]}
    assert Enum.sort(Map.keys(args)) == ~w(model prompt target thinking title)
    refute Map.has_key?(args, "cwd")
    assert {:error, :ticket_chat_runtime_not_integrated} = DesktopRequest.claim(ctx.store, reserved.request["request_key"])
    assert {:error, :ticket_chat_runtime_not_integrated} = DesktopToolArgs.create_thread(ctx.store, reserved.request["request_key"])
    expected_request = reserved.request
    assert {:ok, ^expected_request} = DesktopRequest.get(ctx.store, reserved.request["request_key"])
  end

  test "allowlisted parent claims once and drains exact readback after rollback", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    key = reserved.request["request_key"]
    opts = [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]
    assert DesktopRequest.list_pending(ctx.store, 50, opts) == [reserved.request]
    assert {:ok, args} = DesktopToolArgs.create_thread(ctx.store, key, opts)
    assert args["target"]["type"] == "projectless"
    assert {:ok, claimed} = DesktopRequest.claim(ctx.store, key, opts)
    trace = Path.join(ctx.root, "runtime-fixture.trace")
    handshake = File.read!(trace)
    methods = handshake |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["method"])
    assert methods == ["initialize", "initialized"]
    assert claimed["status"] == "CREATE_UNCERTAIN"
    assert {:error, :ticket_chat_request_already_issued} = DesktopRequest.claim(ctx.store, key, opts)
    assert {:error, :ticket_chat_runtime_not_integrated} = DesktopToolArgs.create_thread(ctx.store, key)
    assert DesktopRequest.list_reconciliation(ctx.store) == [claimed]
    assert File.read!(trace) == handshake
    File.mkdir_p!(claimed["cwd"])
    assert {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, key, proof(claimed))
    assert {:ok, _} = DesktopRequest.complete(ctx.store, key, completion("parent-bootstrap"))
    assert {:ok, _} = TicketChat.ready_for_run(ctx.store, "run-one")
    {:ok, current} = RunLedger.get(ctx.store, "run-one")
    {:ok, completed} = DesktopRequest.get(ctx.store, key)
    assert :ok = TicketChat.authorize_readback(ctx.store, completed)
    Store.query!(ctx.store, "UPDATE runs SET repo_key = 'foreign' WHERE run_id = 'run-one'")
    assert {:error, :ticket_chat_run_identity_mismatch} = TicketChat.authorize_readback(ctx.store, completed)
    Store.query!(ctx.store, "UPDATE runs SET repo_key = ? WHERE run_id = 'run-one'", [current["repo_key"]])
    assert :ok = TicketChat.authorize_readback(ctx.store, completed)
    Store.query!(ctx.store, "UPDATE runs SET execution_mode = 'LEGACY' WHERE run_id = 'run-one'")
    assert {:error, :ticket_chat_run_identity_mismatch} = TicketChat.authorize_readback(ctx.store, completed)
    Store.query!(ctx.store, "UPDATE runs SET execution_mode = ? WHERE run_id = 'run-one'", [current["execution_mode"]])
    Store.query!(ctx.store, "UPDATE runs SET worktree = ? WHERE run_id = 'run-one'", [claimed["cwd"]])
    assert {:error, :ticket_chat_source_directory_forbidden} = TicketChat.authorize_readback(ctx.store, completed)
    Store.query!(ctx.store, "UPDATE runs SET worktree = ? WHERE run_id = 'run-one'", [current["worktree"]])
    assert {:ok, ^current} = RunLedger.get(ctx.store, "run-one")
    assert {:ok, ^completed} = DesktopRequest.get(ctx.store, key)
    assert :ok = TicketChat.authorize_readback(ctx.store, completed)
    assert {:ok, _} = TicketChat.ready_for_run(ctx.store, "run-one")
    assert DesktopRequest.list_reconciliation(ctx.store) == []
  end

  test "unsupported runtime leaves a new parent request pending and unclaimed", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    TicketChatFixture.runtime_fixture(ctx.root, %{})
    opts = [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]
    assert {:error, :worker_runtime_identity_unproven} = DesktopRequest.claim(ctx.store, reserved.request["request_key"], opts)
    assert {:ok, request} = DesktopRequest.get(ctx.store, reserved.request["request_key"])
    assert request == reserved.request
    assert Store.query!(ctx.store, "SELECT * FROM ticket_parent_claims").rows == []
  end

  test "request drift during runtime initialization cannot claim the stale parent", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    key = reserved.request["request_key"]
    opts = [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]

    for {field, value} <- [{"status", "SUPERSEDED"}, {"target_kind", "TASK"}] do
      Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'PENDING', target_kind = 'TICKET_CHAT', codex_project_id = NULL WHERE request_key = ?", [key])
      project = if field == "target_kind", do: ", codex_project_id = 'fixture-project'", else: ""

      command =
        "/usr/bin/sqlite3 '#{ctx.database}' \"UPDATE desktop_requests SET #{field} = '#{value}'#{project} WHERE request_key = '#{key}'\" || exit 1"

      TicketChatFixture.runtime_fixture(ctx.root, :supported, command)
      assert {:error, :ticket_parent_request_changed} = DesktopRequest.claim(ctx.store, key, opts)
      assert {:ok, request} = DesktopRequest.get(ctx.store, key)
      assert request[field] == value
      assert request["claimed_at"] == nil
      assert Store.query!(ctx.store, "SELECT * FROM ticket_parent_claims").rows == []
    end
  end

  test "parent admission rejects stale payload and invalid linked contracts without claiming", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    key = reserved.request["request_key"]
    policy = %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}
    assert {:error, :ticket_chat_not_allowlisted} = DesktopRequest.claim(ctx.store, key, ticket_policy: %{policy | "pilot_issue_keys" => []})
    assert {:error, :ticket_chat_request_changed} = TicketChat.authorize_issuance(ctx.store, Map.put(reserved.request, "prompt", "replacement"), policy)
    {:ok, _} = RunLedger.update(ctx.store, "run-one", %{manual_validation_required: 1})
    assert {:error, :ticket_chat_validation_flag_mismatch} = DesktopRequest.claim(ctx.store, key, ticket_policy: policy)
    assert {:error, :ticket_chat_validation_flag_mismatch} = DesktopToolArgs.create_thread(ctx.store, key, ticket_policy: policy)
    assert DesktopRequest.list_pending(ctx.store, 50, ticket_policy: policy) == []
    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, key)
    assert unchanged == reserved.request
  end

  test "changed contract after claim does not authorize sends but permits identity readback", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    key = reserved.request["request_key"]
    opts = [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]
    {:ok, claimed} = DesktopRequest.claim(ctx.store, key, opts)
    File.mkdir_p!(claimed["cwd"])
    {:ok, _} = RunLedger.update(ctx.store, "run-one", %{manual_validation_required: 1})
    assert :ok = TicketChat.authorize_readback(ctx.store, claimed)
    assert {:error, :ticket_chat_request_already_issued} = DesktopToolArgs.create_thread(ctx.store, key, opts)
    assert DesktopRequest.list_reconciliation(ctx.store) == [claimed]
    Store.query!(ctx.store, "UPDATE desktop_requests SET claimed_at = NULL WHERE request_key = ?", [key])
    assert DesktopRequest.list_reconciliation(ctx.store) == []
  end

  test "explicit null project, immutable metadata and exact observation are required even on replay", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    request = reserved.request

    for value <- ["projectless", "wrong-project", ""] do
      assert {:error, :ticket_chat_requires_projectless_route} = DesktopRequest.enqueue(ctx.store, request_attrs(request) |> Map.put("codex_project_id", value))
    end

    assert {:error, :ticket_chat_requires_projectless_route} = DesktopRequest.enqueue(ctx.store, Map.delete(request_attrs(request), "codex_project_id"))
    proof = proof(request)
    assert {:error, :ticket_chat_request_not_claimed} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], proof)
    simulate_claim(ctx.store, request)

    for bad <- [
          Map.delete(proof, "project_id"),
          Map.put(proof, "project_id", "project"),
          Map.put(proof, "generation", 2),
          Map.put(proof, "cwd", ctx.root),
          Map.put(proof, "payload_sha256", "wrong"),
          Map.put(proof, "worktree_attachments", [%{}])
        ] do
      assert {:error, :ticket_chat_observation_mismatch} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], bad)
    end

    assert {:ok, bound} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], proof)
    assert {:error, :ticket_chat_observation_mismatch} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], Map.put(proof, "cwd", "/wrong"))
    assert {:ok, ^bound} = DesktopRequest.get(ctx.store, request["request_key"])
    assert {:error, :thread_route_mismatch} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], Map.put(proof, "thread_id", "replacement"))
  end

  test "bad route metadata, source bootstrap fields and corrupted payloads fail closed", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    request = reserved.request
    metadata = Jason.decode!(request["metadata_json"])

    cases = [
      Map.put(request, "metadata_json", Jason.encode!(Map.put(metadata, "workspace_mode", "CODEX_NATIVE"))),
      Map.put(request, "branch", "feature"),
      Map.put(request, "cwd", ctx.root),
      Map.put(request, "metadata_json", Jason.encode!(Map.put(metadata, "generation", 0))),
      Map.put(request, "metadata_json", Jason.encode!(Map.put(metadata, "chat_key", "not-bound")))
    ]

    for bad <- cases do
      assert {:error, _} = DesktopToolArgs.create_thread(bad)
    end

    Store.query!(ctx.store, "UPDATE desktop_requests SET prompt = 'corrupted' WHERE request_key = ?", [request["request_key"]])
    assert {:error, :request_payload_corrupt} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    simulate_claim(ctx.store, request)
    assert {:error, :request_payload_corrupt} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], proof(request))
  end

  test "presentation followup leaves original creation evidence and source state intact", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    simulate_claim(ctx.store, reserved.request)
    {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, reserved.request["request_key"], proof(reserved.request))
    {:ok, _} = DesktopRequest.complete(ctx.store, reserved.request["request_key"], completion("bootstrap-turn"))
    {:ok, chat_before} = TicketChat.get(ctx.store, reserved.chat["chat_key"])
    register_run(ctx.store, chat_before["chat_key"], "DELIVERY", ctx.root)

    {:ok, _} =
      TaskLedger.register(ctx.store, %{
        task_key: "colliding-source-task",
        run_id: chat_before["chat_key"],
        stage: "WRITING",
        role: "feature-writer",
        status: "RUNNING",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        routing_reason: "normal-writer",
        prompt_sha256: "source-digest"
      })

    Store.query!(
      ctx.store,
      """
      INSERT INTO native_source_bindings(run_id, task_key, thread_id, codex_project_id, control_workspace, source_workspace,
        attachment_identity, bootstrap_sha, bootstrap_request_key, bootstrap_turn_id, evidence_json, created_at)
      VALUES (?, 'colliding-source-task', 'source-thread', 'source-project', '/source-control', '/source-workspace',
        'source-attachment', 'source-sha', 'source-request', 'source-turn', '{}', 'source-created')
      """,
      [chat_before["chat_key"]]
    )

    source_before = Store.one!(ctx.store, "SELECT * FROM native_source_bindings WHERE run_id = ?", [chat_before["chat_key"]])

    followup =
      request_attrs(reserved.request) |> Map.merge(%{"request_key" => "presentation-one", "action" => "FOLLOWUP", "existing_thread_id" => "parent-thread", "prompt" => "Current stage summary"})

    {:ok, request} = DesktopRequest.enqueue(ctx.store, followup)
    assert {:ok, args} = DesktopToolArgs.followup(request)
    assert args == %{"threadId" => "parent-thread", "prompt" => "Current stage summary", "model" => "gpt-6-luna", "thinking" => "low"}
    simulate_claim(ctx.store, request)
    {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], proof(request))
    {:ok, _} = DesktopRequest.complete(ctx.store, request["request_key"], completion("summary-turn"))
    assert {:ok, ^chat_before} = TicketChat.get(ctx.store, reserved.chat["chat_key"])
    assert Store.one!(ctx.store, "SELECT * FROM native_source_bindings WHERE run_id = ?", [chat_before["chat_key"]]) == source_before
    assert TaskLedger.list_for_run(ctx.store, "run-one") == []
  end

  test "a false CREATE completion is retained as failed and reserves one same-parent recovery", ctx do
    assert {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    simulate_claim(ctx.store, reserved.request)
    assert {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, reserved.request["request_key"], proof(reserved.request))
    digest = String.duplicate("a", 64)
    artifact = %{"server" => "codex_app", "tool" => "list_artifacts", "arguments" => %{}, "result" => %{"content" => [%{"type" => "text", "text" => "{\"artifacts\":[]}"}]}}

    output = %{
      "result" => %{"acknowledged" => false},
      "completed_tool_calls" => [],
      "bootstrap_evidence" => %{"list_artifacts" => [artifact], "completed_commands" => []},
      "native_readback_sha256" => digest
    }

    assert {:error, :ticket_chat_acknowledgement_required} =
             DesktopRequest.complete(ctx.store, reserved.request["request_key"], %{
               "thread_id" => "parent-thread",
               "turn_id" => "negative-turn",
               "output" => Map.delete(output, "native_readback_sha256")
             })

    assert Store.one!(ctx.store, "SELECT status FROM desktop_requests WHERE request_key = ?", [reserved.request["request_key"]])["status"] == "THREAD_RECORDED"
    assert {:ok, failed} = DesktopRequest.complete(ctx.store, reserved.request["request_key"], %{"thread_id" => "parent-thread", "turn_id" => "negative-turn", "output" => output})
    assert failed["status"] == "FAILED"
    assert failed["failure_code"] == "TICKET_CHAT_BOOTSTRAP_NOT_ACKNOWLEDGED"
    assert Jason.decode!(failed["output_json"])["result"] == %{"acknowledged" => false}
    assert Jason.decode!(failed["target_observation_json"])["native_readback_sha256"] == digest
    chat_proof = Store.one!(ctx.store, "SELECT observation_json FROM ticket_chats WHERE chat_key = ?", [reserved.chat["chat_key"]])["observation_json"] |> Jason.decode!()
    refute Map.has_key?(chat_proof, "native_readback_sha256")
    assert {:ok, recovery} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    assert recovery.request["request_key"] == reserved.chat["create_request_key"] <> ":bootstrap-recovery:1"
    assert recovery.request["action"] == "FOLLOWUP"
    assert recovery.request["existing_thread_id"] == failed["thread_id"]
    assert recovery.request["status"] == "PENDING"
    assert {:ok, again} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    assert again.request == recovery.request
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND action = 'FOLLOWUP'")["count"] == 1
    assert {:error, :ticket_chat_parent_not_ready} = TicketChat.ready_for_run(ctx.store, "run-one")
  end

  test "observation rechecks current request status and local directory before binding", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    proof = proof(reserved.request)
    stale = Map.put(reserved.request, "status", "CREATE_UNCERTAIN")
    assert {:error, :ticket_chat_request_not_claimed} = TicketChat.record_thread(ctx.store, stale, "parent-thread", proof)
    simulate_claim(ctx.store, reserved.request)
    File.mkdir_p!(Path.join(reserved.chat["cwd"], ".git"))
    assert {:error, :ticket_chat_source_directory_forbidden} = DesktopRequest.record_ticket_thread(ctx.store, reserved.request["request_key"], proof)
    assert {:ok, %{"thread_id" => nil}} = TicketChat.get(ctx.store, reserved.chat["chat_key"])
  end

  test "parent cannot be reserved inside an unrelated repository or linked worktree", ctx do
    for kind <- ["repository", "linked-worktree"] do
      other_repo = Path.join(ctx.root, kind)
      File.mkdir_p!(other_repo)
      marker = Path.join(other_repo, ".git")
      if kind == "repository", do: File.mkdir!(marker), else: File.write!(marker, "gitdir: /unrelated/git/worktrees/example")
      directory = TicketChat.directory_name("scope", "issue-123", "grail")
      nested = %{attrs(ctx.root) | cwd: Path.join([other_repo, "nested", directory])}
      assert {:error, :ticket_chat_source_directory_forbidden} = TicketChat.reserve(ctx.store, "run-one", nested)
    end

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chats")["count"] == 0
  end

  test "contradictory stored Project evidence cannot be accepted on replay or completion", ctx do
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    simulate_claim(ctx.store, reserved.request)
    proof = proof(reserved.request)
    {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, reserved.request["request_key"], proof)
    Store.query!(ctx.store, "UPDATE desktop_requests SET verified_project_id = 'wrong-project' WHERE request_key = ?", [reserved.request["request_key"]])
    assert {:error, :ticket_chat_observation_conflict} = DesktopRequest.record_ticket_thread(ctx.store, reserved.request["request_key"], proof)
    assert {:error, :ticket_chat_observation_conflict} = DesktopRequest.complete(ctx.store, reserved.request["request_key"], completion("bad-project-turn"))
    assert {:ok, %{"status" => "THREAD_RECORDED", "verified_project_id" => "wrong-project"}} = DesktopRequest.get(ctx.store, reserved.request["request_key"])
  end

  test "missing identities and malformed public inputs fail without partial state", ctx do
    assert {:error, :unknown_ticket_chat} = TicketChat.for_run(ctx.store, "missing")
    assert {:error, :unknown_ticket_chat} = TicketChat.find(ctx.store, "scope", "issue-123", "grail")
    assert {:error, :unknown_ticket_chat_fields} = TicketChat.reserve(ctx.store, "run-one", Map.put(attrs(ctx.root), :unexpected, true))
    {:ok, reserved} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    assert {:ok, reserved.chat} == TicketChat.find(ctx.store, "scope", "issue-123", "grail")
    assert {:error, :unknown_request} = TicketChat.record_thread(ctx.store, %{"request_key" => "missing"}, "thread", %{})
    assert {:error, :ticket_chat_observation_required} = TicketChat.record_thread(ctx.store, reserved.request, "thread", nil)

    Store.query!(ctx.store, """
    INSERT INTO desktop_requests(request_key, target_kind, target_key, action, status, payload_sha256, codex_project_id,
      model, reasoning_effort, title, prompt, schema_json, cwd, metadata_json, created_at, updated_at)
    VALUES ('legacy-request', 'TASK', 'legacy-task', 'CREATE', 'PENDING', 'legacy-hash', 'legacy-project',
      'gpt-6-luna', 'low', 'Legacy', 'Legacy', '{}', '/tmp/legacy', '{}', 'old', 'old')
    """)

    assert {:error, :not_a_ticket_chat_request} = TicketChat.record_thread(ctx.store, %{"request_key" => "legacy-request"}, "thread", %{})

    request = reserved.request

    for {field, value} <- [{"metadata_json", nil}, {"metadata_json", "not-json"}, {"schema_json", nil}, {"schema_json", "{}"}] do
      assert {:error, _} = TicketChat.validate_request(ctx.store, Map.put(request, field, value))
    end

    assert {:error, :ticket_chat_create_key_mismatch} = TicketChat.validate_request(ctx.store, Map.put(request, "request_key", "replacement-create"))
    assert {:error, :unsupported_followup_route} = DesktopToolArgs.followup(request)
    assert {:error, :ticket_chat_directory_mismatch} = DesktopToolArgs.create_thread(Map.put(request, "cwd", nil))
    metadata = Jason.decode!(request["metadata_json"]) |> Map.put("chat_key", nil)
    assert {:error, :invalid_ticket_chat_key} = DesktopToolArgs.create_thread(Map.put(request, "metadata_json", Jason.encode!(metadata)))
  end

  test "malformed run snapshots and unreadable source paths cannot bind a parent", ctx do
    Store.query!(ctx.store, "UPDATE runs SET snapshot_json = '[' WHERE run_id = 'run-one'")
    assert {:error, :ticket_chat_snapshot_invalid} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
    {_contract, snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-123")
    Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run-one'", [Jason.encode!(snapshot)])
    obstacle = Path.join(ctx.root, "not-a-directory")
    File.write!(obstacle, "fixture")
    Store.query!(ctx.store, "UPDATE runs SET repo_path = ? WHERE run_id = 'run-one'", [Path.join(obstacle, "source")])
    assert {:error, :ticket_chat_source_directory_forbidden} = TicketChat.reserve(ctx.store, "run-one", attrs(ctx.root))
  end

  test "concurrent connections reserve exactly one identity and creation request", ctx do
    {:ok, second} = Store.start_link(database: ctx.database)

    try do
      tasks = for store <- [ctx.store, second], do: Task.async(fn -> TicketChat.reserve(store, "run-one", attrs(ctx.root)) end)
      assert [{:ok, one}, {:ok, two}] = Enum.map(tasks, &Task.await/1)
      assert one == two
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chats")["count"] == 1
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_runs")["count"] == 1
    after
      GenServer.stop(second)
    end
  end

  defp attrs(root) do
    %{
      scope_key: "scope",
      issue_id: "issue-123",
      issue_key: "PPL-123",
      repo_key: "grail",
      route: "desktop_owned_ticket_chat_v1",
      cwd: Path.join(root, TicketChat.directory_name("scope", "issue-123", "grail")),
      model: "gpt-6-luna",
      reasoning_effort: "low",
      title: "PPL-123 · Factory",
      prompt: "Read current context only."
    }
  end

  defp register_run(store, key, kind, root) do
    {contract, snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-123")

    {:ok, _} =
      RunLedger.register(store, %{
        run_id: key,
        issue_key: "PPL-123",
        kind: kind,
        state: "FAILED",
        repo_key: "grail",
        repo_path: Path.join(root, "source"),
        candidate_sha: "original-candidate",
        task_id: "original-task",
        execution_mode: "TICKET_SUPERVISOR_V1",
        snapshot_json: Jason.encode!(snapshot),
        spec_revision: contract.revision,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        manual_validation_required: 0
      })
  end

  defp request_attrs(request) do
    request
    |> Map.take(~w(request_key target_kind target_key action codex_project_id model reasoning_effort title prompt cwd))
    |> Map.put("schema", Jason.decode!(request["schema_json"]))
    |> Map.put("metadata", Jason.decode!(request["metadata_json"]))
  end

  defp simulate_claim(store, request) do
    File.mkdir_p!(request["cwd"])
    state = if request["action"] == "CREATE", do: "CREATE_UNCERTAIN", else: "FOLLOWUP_UNCERTAIN"
    Store.query!(store, "UPDATE desktop_requests SET status = ?, claimed_at = ? WHERE request_key = ?", [state, DateTime.to_iso8601(DateTime.utc_now()), request["request_key"]])
  end

  defp proof(request) do
    args =
      case request["action"] do
        "CREATE" -> DesktopToolArgs.create_thread(request)
        "FOLLOWUP" -> DesktopToolArgs.followup(request)
      end

    {:ok, args} = args

    %{
      "request_key" => request["request_key"],
      "payload_sha256" => request["payload_sha256"],
      "thread_id" => "parent-thread",
      "project_id" => nil,
      "cwd" => request["cwd"],
      "generation" => 1,
      "tool_arguments" => args,
      "worktree_attachments" => []
    }
  end

  defp completion(turn), do: %{"thread_id" => "parent-thread", "turn_id" => turn, "output" => %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}}
end
