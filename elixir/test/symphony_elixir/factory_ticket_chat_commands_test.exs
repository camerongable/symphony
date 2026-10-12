defmodule SymphonyElixir.FactoryTicketChatCommandsTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture

  alias SymphonyElixir.Factory.{
    Contract,
    RunLedger,
    Store,
    TicketChatCommands,
    TicketContractAmendment,
    TicketWorkerRunner
  }

  alias SymphonyElixir.Factory.TicketAmendmentJiraOperation

  defmodule JiraReader do
    def issue(issue_key, opts) do
      if opts[:mcp_session] != %{thread_id: "amendment-jira"}, do: raise("missing Jira fixture session")
      snapshot = Process.get(:ticket_amendment_snapshot)
      if snapshot["key"] != issue_key, do: raise("foreign Jira issue")
      {:ok, snapshot}
    end
  end

  defmodule JiraConnector do
    def validate_call("jira_add_comment", %{"issue_key" => "PPL-123", "body" => body}, opts) do
      if opts[:mcp_session] != %{thread_id: "amendment-jira"}, do: raise("missing Jira fixture session")
      if body != Process.get(:ticket_amendment_body), do: raise("wrong amendment body")
      :ok
    end

    def call("jira_add_comment", %{"body" => body}, _opts) do
      snapshot = Process.get(:ticket_amendment_snapshot)
      Process.put(:ticket_amendment_snapshot, Map.update!(snapshot, "comments", &(&1 ++ [%{"id" => "amendment-draft", "text" => body}])) |> Map.put("updated", "2026-10-07T13:00:00Z"))
      {:ok, %{"comment_id" => "amendment-draft"}}
    end
  end

  setup ctx do
    fixture = setup_fixture(ctx)
    SymphonyElixir.TicketChatFixture.runtime_fixture(fixture.root)
    {:ok, fixture}
  end

  test "captured native Python staging command decodes the literal proposal" do
    command =
      String.trim(~S"""
      /bin/zsh -lc 'ticket_payload_b64=$(python3 -c '"'import base64; print(base64.b64encode(b\"{\\\"proposal_id\\\":\\\"human-answer-Q-U9N-busy-retry-2-v3\\\",\\\"body\\\":\\\"Answer Q-U9N-busy-retry-2-v3: yes\\\",\\\"operations\\\":[{\\\"operation\\\":\\\"answer_question\\\",\\\"question_key\\\":\\\"Q-U9N-busy-retry-2-v3\\\",\\\"value\\\":true}],\\\"generation\\\":1,\\\"spec_revision\\\":1,\\\"contract_sha256\\\":\\\"1b0d4e6adb72cf49f1cfde3934f8f4f96439ec1c5455dbfb6c9321fcfed4fa3d\\\",\\\"candidate_sha\\\":null}\").decode())')
      mise exec -- mix factory.ticket stage native-acceptance-parent-v2-019fa5b7 --payload-base64 \""'$ticket_payload_b64" --workflow /private/tmp/symphony-u9-native-acceptance-setup-v2-019fa5b7/ticket-WORKFLOW.md'
      """)

    assert {:ok, "native-acceptance-parent-v2-019fa5b7", attrs} = TicketChatCommands.staging_invocation(command)
    assert attrs["proposal_id"] == "human-answer-Q-U9N-busy-retry-2-v3"
    assert attrs["body"] == "Answer Q-U9N-busy-retry-2-v3: yes"
    assert attrs["operations"] == [%{"operation" => "answer_question", "question_key" => "Q-U9N-busy-retry-2-v3", "value" => true}]
    assert attrs["generation"] == 1
    assert attrs["spec_revision"] == 1
    assert attrs["contract_sha256"] == "1b0d4e6adb72cf49f1cfde3934f8f4f96439ec1c5455dbfb6c9321fcfed4fa3d"
    assert attrs["candidate_sha"] == nil

    for altered <- [
          command <> "; true",
          String.replace(command, "ticket_payload_b64", "other_payload"),
          String.replace(command, "import base64;", "import base64; import os;"),
          String.replace(
            command,
            "--workflow /private/tmp/symphony-u9-native-acceptance-setup-v2-019fa5b7/ticket-WORKFLOW.md",
            "--workflow /private/tmp/symphony-u9-native-acceptance-setup-v2-019fa5b7/ticket-WORKFLOW.md --workflow /private/tmp/symphony-u9-native-acceptance-setup-v2-019fa5b7/ticket-WORKFLOW.md"
          ),
          String.replace(command, "stage native-acceptance-parent-v2-019fa5b7", "stage native-acceptance-parent-v2-$X"),
          String.replace(command, "ticket-WORKFLOW.md", "ticket-WORKFLOW.md$X"),
          command <> " > /tmp/copied-output"
        ] do
      assert :none = TicketChatCommands.staging_invocation(altered)
    end

    unsupported_bytes_escape =
      String.replace(
        command,
        "Answer Q-U9N-busy-retry-2-v3: yes",
        "Answer Q-U9N-busy-retry-2-v3: \\q",
        global: false
      )

    assert :none = TicketChatCommands.staging_invocation(unsupported_bytes_escape)
  end

  test "staging invocation accepts exact bash wrappers and rejects multiline and Python byte-literal wrappers", ctx do
    body = "Rework the current candidate."
    operations = [%{"operation" => "request_rework"}]
    {:ok, staged} = stage(ctx, "bash-wrapper", body, operations)
    binding = Jason.decode!(staged["binding_json"])
    attrs = Map.merge(binding, %{"proposal_id" => staged["proposal_id"], "body" => body, "operations" => operations})
    payload = Jason.encode!(attrs) |> Base.encode64()
    workflow = Path.join(ctx.root, "WORKFLOW.md")
    wrapped = "/bin/bash -lc 'mise exec -- mix factory.ticket stage run --payload-base64 #{payload} --workflow #{workflow}'"

    assert {:ok, "run", ^attrs} = TicketChatCommands.staging_invocation(wrapped)
    multiline = "/bin/zsh -lc 'echo first\nmise exec -- mix factory.ticket stage run --payload-base64 #{payload} --workflow #{workflow}'"
    assert :none = TicketChatCommands.staging_invocation(multiline)

    three_lines = "/bin/zsh -lc 'echo first\necho second\nmise exec -- mix factory.ticket stage run --payload-base64 #{payload} --workflow #{workflow}'"
    assert :none = TicketChatCommands.staging_invocation(three_lines)

    python_literal = "/bin/bash -lc 'python3 -c \"import base64; print(base64.b64encode(b'{}').decode())\"'"
    assert :none = TicketChatCommands.staging_invocation(python_literal)
  end

  test "accepted inputs cannot be replayed or transferred before application", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    body = "Rework the current candidate."
    {:ok, staged} = stage(ctx, "unissued-ready-rework", body, [%{"operation" => "request_rework"}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    before = protected_amendment_state(ctx)

    assert {:error, :ready_rework_receipt_invalid} = TicketChatCommands.validate_ready_rework_replay(ctx.store, staged["command_key"])
    assert protected_amendment_state(ctx) == before
    assert {:error, :blocked_resume_answer_replay_unproven} = TicketChatCommands.validate_rework_replay(ctx.store, staged["command_key"])
    assert protected_amendment_state(ctx) == before

    accepted = accepted_answer(ctx, "unissued-answer-transfer")
    before_transfer = protected_amendment_state(ctx)
    assert {:error, :ticket_rework_transfer_unproven} = TicketChatCommands.record_rework_transfer(ctx.store, accepted["command_key"], %{})
    assert protected_amendment_state(ctx) == before_transfer
  end

  test "rework predicates reject wrong input types", _ctx do
    for body <- [nil, :rework, %{}, ["Rework the current candidate."]] do
      refute TicketChatCommands.rework_body?(body)
    end

    for payload <- [nil, %{}, "request_rework", [:request_rework], [%{"operation" => "request_rework"}, :bad]] do
      refute TicketChatCommands.rework_payload?(payload)
    end
  end

  test "unknown and pending rework preflight and application remain no-ops", ctx do
    before = protected_amendment_state(ctx)
    assert {:error, :unknown_ticket_command} = TicketChatCommands.preflight_rework_transfer(ctx.store, "missing-command")
    assert {:error, :unknown_ticket_command} = TicketChatCommands.apply_accepted(ctx.store, "missing-command", amendment_context(ctx))
    assert protected_amendment_state(ctx) == before
    assert {:ok, pending} = stage(ctx, "pending-preflight", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    after_stage = protected_amendment_state(ctx)

    assert {:error, :ticket_command_not_accepted} = TicketChatCommands.preflight_rework_transfer(ctx.store, pending["command_key"])
    assert {:ok, ^pending} = TicketChatCommands.apply_accepted(ctx.store, pending["command_key"], amendment_context(ctx))
    assert protected_amendment_state(ctx) == after_stage
    refute after_stage == before
  end

  test "critic claim and reconciliation reject a genuinely reserved amendment without a prepared attempt", ctx do
    {:ok, command} = accepted_amendment(ctx, "reserved-without-critic", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    assert {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    assert {:ok, _draft} = prepare_draft(ctx, command, context)

    before = %{
      protected: protected_amendment_state(ctx),
      amendment: Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]),
      attempts: Store.query!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts ORDER BY command_key").rows
    }

    assert {:error, :critic_attempt_not_prepared} =
             TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, critic_model_policy())

    assert {:error, :critic_attempt_not_prepared} =
             TicketContractAmendment.reconcile_critic(ctx.store, command["command_key"], context, :unexpected_callback, %{})

    assert %{
             protected: protected_amendment_state(ctx),
             amendment: Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]),
             attempts: Store.query!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts ORDER BY command_key").rows
           } == before

    assert amendment["phase"] == "RESERVED"
  end

  test "amendment insertion failure rolls back reservation state", ctx do
    {:ok, command} = accepted_amendment(ctx, "amendment-insert-failure", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    before = protected_amendment_state(ctx)
    Store.query!(ctx.store, "CREATE TRIGGER fail_amendment_insert BEFORE INSERT ON ticket_contract_amendments BEGIN SELECT RAISE(ABORT, 'injected amendment insert failure'); END")

    assert {:error, :amendment_reservation_conflict} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)

    Store.query!(ctx.store, "DROP TRIGGER fail_amendment_insert")
    assert protected_amendment_state(ctx) == before
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, command["command_key"])
  end

  test "accepted amendment validation rejects unsupported run state and malformed staging receipts without writes", ctx do
    {:ok, unsupported} = accepted_amendment(ctx, "unsupported-run-state", "Updated contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET kind = 'SPECIFICATION' WHERE run_id = 'run'")
    before_unsupported = protected_amendment_state(ctx)
    assert {:error, :ticket_chat_run_kind_not_eligible} = TicketChatCommands.validate_contract_amendment(ctx.store, unsupported["command_key"])
    assert protected_amendment_state(ctx) == before_unsupported

    Store.query!(ctx.store, "UPDATE runs SET kind = 'DELIVERY' WHERE run_id = 'run'")
    {:ok, malformed} = accepted_amendment(ctx, "malformed-staging-validation", "Another contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = '[]' WHERE input_key = ?", [malformed["input_key"]])
    before_malformed = protected_amendment_state(ctx)
    assert {:error, :native_input_evidence_mismatch} = TicketChatCommands.validate_contract_amendment(ctx.store, malformed["command_key"])
    assert protected_amendment_state(ctx) == before_malformed
  end

  test "contract amendment validation rejects VERIFYING state and succeeds after restoring READY", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, command} = accepted_amendment(ctx, "validate-state-restore", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    assert {:ok, validated} = TicketChatCommands.validate_contract_amendment(ctx.store, command["command_key"])
    assert validated.run["state"] == "READY_FOR_REVIEW"

    Store.query!(ctx.store, "UPDATE runs SET state = 'VERIFYING' WHERE run_id = 'run'")
    before_verifying = protected_amendment_state(ctx)
    assert {:error, :amendment_run_state_not_admitted} = TicketChatCommands.validate_contract_amendment(ctx.store, command["command_key"])
    assert protected_amendment_state(ctx) == before_verifying

    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    assert {:ok, restored} = TicketChatCommands.validate_contract_amendment(ctx.store, command["command_key"])
    assert restored.run["state"] == "READY_FOR_REVIEW"
  end

  test "READY_FOR_REVIEW direct rework admission is bound to one accepted native command", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    body = "Rework the current candidate."
    assert {:ok, staged} = stage(ctx, "ready-rework-admission", body, [%{"operation" => "request_rework"}])
    readback = native(ctx, [body])

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)

    assert {:ok, %{run: %{"state" => "READY_FOR_REVIEW"}, command: command}} =
             TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])

    assert command["status"] == "ACCEPTED"

    {:ok, ready_run} = RunLedger.get(ctx.store, "run")
    jira = Jason.decode!(ready_run["snapshot_json"]) |> Map.merge(%{"status" => "In Review", "labels" => ["ai-review"]})
    assert {:ok, authorization} = TicketWorkerRunner.ready_rework_authorization(ready_run, jira, DateTime.utc_now())
    assert :ok = TicketWorkerRunner.validate_authorization(Map.put(ready_run, "state", "REVIEW_WRITING"), authorization)

    assert {:error, :ticket_jira_not_dispatchable} =
             TicketWorkerRunner.ready_rework_authorization(ready_run, %{jira | "status" => "To Do"}, DateTime.utc_now())

    packet = TicketWorkerRunner.ready_rework_packet(Jason.encode!(%{"role" => "feature-writer"}), staged["command_key"], body)
    assert Jason.decode!(packet)["direct_ticket_rework"] == %{"command_key" => staged["command_key"], "native_body" => body}

    Store.query!(ctx.store, "UPDATE runs SET state = 'WRITING' WHERE run_id = 'run'")
    assert {:error, :ready_rework_not_current} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
  end

  test "repeated supported native rework body associates the current pending proposal", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    body = "Rework the current candidate."
    assert {:ok, first} = stage(ctx, "repeated-rework-first", body, [%{"operation" => "request_rework"}])

    first_readback =
      native(ctx, [body], first["command_key"])
      |> put_in(["turns", Access.at(0), "id"], "repeated-first-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "repeated-first-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "repeated-first-client")

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", first_readback)
    {:ok, first_accepted} = TicketChatCommands.get(ctx.store, first["command_key"])
    assert first_accepted["status"] == "ACCEPTED"

    assert {:ok, second} = stage(ctx, "repeated-rework-second", body, [%{"operation" => "request_rework"}])

    second_readback =
      native(ctx, [body], second["command_key"])
      |> put_in(["turns", Access.at(0), "id"], "repeated-second-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "repeated-second-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "repeated-second-client")

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", second_readback)
    {:ok, first_after} = TicketChatCommands.get(ctx.store, first["command_key"])
    {:ok, second_after} = TicketChatCommands.get(ctx.store, second["command_key"])
    assert first_after["status"] == "ACCEPTED"
    assert second_after["status"] == "ACCEPTED"
    assert second_after["input_key"] != first_after["input_key"]
    second_input_key = second_after["input_key"]

    assert {:ok, %{receipts: [%{"input_key" => ^second_input_key, "status" => "ACCEPTED"}]}} =
             TicketChatCommands.admit_readback(ctx.store, "run", second_readback)

    assert {:ok, ^first_after} = TicketChatCommands.get(ctx.store, first["command_key"])
  end

  test "completed delegated turn admits each direct answer separately and ignores delegation content", ctx do
    question_one = "Q-U9N-busy-retry-1-v3"
    question_two = "Q-U9N-busy-retry-2-v3"

    for key <- [question_one, question_two] do
      assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Confirm #{key}?", "answers" => %{"yes" => true, "no" => false}})
    end

    body_one = "Answer #{question_one}: yes"
    body_two = "Answer #{question_two}: yes"
    assert {:ok, staged_one} = stage(ctx, "busy-retry-one", body_one, [%{"operation" => "answer_question", "question_key" => question_one, "value" => true}])
    assert {:ok, staged_two} = stage(ctx, "busy-retry-two", body_two, [%{"operation" => "answer_question", "question_key" => question_two, "value" => true}])

    first = native(ctx, [body_one], staged_one["command_key"])
    second = native(ctx, [body_two], staged_two["command_key"])
    first_turn = hd(first["turns"])
    second_turn = hd(second["turns"])

    first_user =
      first_turn["items"]
      |> hd()
      |> put_in(["id"], "01a11da0-df24-7d60-911e-99e8c5bc8186")
      |> put_in(["clientId"], "1403aa30-d053-48aa-8cdb-345df05f164f")
      |> put_in(["content", Access.at(0), "text"], body_one <> "\n")

    second_user =
      second_turn["items"]
      |> hd()
      |> put_in(["id"], "01a11da0-df28-7173-8724-576b103c58da")
      |> put_in(["clientId"], "84034e8c-5684-4428-be88-90ddbb2afa04")
      |> put_in(["content", Access.at(0), "text"], body_two <> "\n")

    first_stage = Enum.at(first_turn["items"], 1)

    second_stage = Enum.at(second_turn["items"], 1)

    readback = %{
      first
      | "turns" => [
          %{
            "id" => "01a11da0-3c3a-7d53-b7dc-69311c71fec2",
            "status" => "completed",
            "startedAt" => min(first_turn["startedAt"], second_turn["startedAt"]),
            "completedAt" => max(first_turn["completedAt"], second_turn["completedAt"]) + 1,
            "items" => [
              %{
                "type" => "functionCallOutput",
                "id" => "delegated-call",
                "namespace" => "codex_app",
                "name" => "send_message_to_thread",
                "output" => "<codex_delegation><input>Answer Q-delegated-fake: yes</input></codex_delegation>"
              },
              first_user,
              first_stage,
              second_user,
              second_stage
            ]
          }
        ]
    }

    assert {:ok, %{receipts: [first_receipt, second_receipt], worker_started: false}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert first_receipt["status"] == "ACCEPTED", inspect(first_receipt)
    assert second_receipt["status"] == "ACCEPTED"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs WHERE chat_key = ?", [ctx.chat["chat_key"]])["count"] == 2
    assert Store.one!(ctx.store, "SELECT body FROM ticket_chat_inputs WHERE item_id = ?", [first_user["id"]])["body"] == "#{body_one}\n"
    assert Store.one!(ctx.store, "SELECT body FROM ticket_chat_inputs WHERE item_id = ?", [second_user["id"]])["body"] == "#{body_two}\n"
    assert {:ok, unchanged_second} = TicketChatCommands.get(ctx.store, staged_two["command_key"])
    assert unchanged_second["status"] == "ACCEPTED"
    assert {:ok, %{receipts: [first_again, second_again]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert first_again["input_key"] == first_receipt["input_key"]
    assert second_again["input_key"] == second_receipt["input_key"]
  end

  test "one staged receipt cannot authorize duplicate or ambiguous direct messages", ctx do
    question = "Q-U9N-shared-receipt"
    body = "Answer #{question}: yes"
    assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question, "body" => "Confirm?", "answers" => %{"yes" => true}})
    assert {:ok, staged} = stage(ctx, "shared-receipt", body, [%{"operation" => "answer_question", "question_key" => question, "value" => true}])

    [first_turn, second_turn] =
      native(ctx, [body, body], staged["command_key"])["turns"]

    first_user = hd(first_turn["items"])
    second_user = hd(second_turn["items"])
    stage_output = Enum.at(first_turn["items"], 1)

    turn = %{
      "id" => "same-receipt-turn",
      "status" => "completed",
      "startedAt" => min(first_turn["startedAt"], second_turn["startedAt"]),
      "completedAt" => max(first_turn["completedAt"], second_turn["completedAt"]),
      "items" => [first_user, stage_output, second_user]
    }

    readback = Map.put(native(ctx, []), "turns", [turn])

    duplicate_item = put_in(readback, ["turns", Access.at(0), "items", Access.at(2), "id"], first_user["id"])
    assert {:error, :duplicate_native_input_identity} = TicketChatCommands.admit_readback(ctx.store, "run", duplicate_item)

    duplicate_client = put_in(readback, ["turns", Access.at(0), "items", Access.at(2), "clientId"], first_user["clientId"])
    assert {:error, :duplicate_native_input_identity} = TicketChatCommands.admit_readback(ctx.store, "run", duplicate_client)

    assert {:error, :ambiguous_staged_interpretations} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs WHERE chat_key = ?", [ctx.chat["chat_key"]])["count"] == 0
    assert {:ok, unchanged} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert unchanged["status"] == "PENDING"
    assert unchanged["input_key"] == nil
  end

  test "native history extraction returns direct messages in chronological order", ctx do
    readback = native(ctx, ["older direct note", "newer direct note"])
    [older, newer] = readback["turns"]

    older = Map.merge(older, %{"startedAt" => 100, "completedAt" => 110})
    newer = Map.merge(newer, %{"startedAt" => 200, "completedAt" => 210})
    readback = Map.put(readback, "turns", [newer, older])

    assert {:ok, %{receipts: [first, second]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert first.input_key == "TIN-" <> digest(Jason.encode!([ctx.chat["chat_key"], ctx.chat["generation"], older["id"], "item-1"]))
    assert second.input_key == "TIN-" <> digest(Jason.encode!([ctx.chat["chat_key"], ctx.chat["generation"], newer["id"], "item-2"]))
  end

  test "READY rework permits only the selected open questions", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")

    for key <- ["Q-selected", "Q-unrelated"] do
      assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => %{"yes" => true}})
    end

    body = "Answer Q-selected: yes\nRework: current candidate"
    operations = [%{"operation" => "answer_question", "question_key" => "Q-selected", "value" => true}, %{"operation" => "request_rework"}]
    assert {:ok, staged} = stage(ctx, "ready-unrelated-question", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))

    assert {:error, :unrelated_open_question} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-selected'") == %{"status" => "OPEN"}
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-unrelated'") == %{"status" => "OPEN"}
    Store.query!(ctx.store, "DELETE FROM ticket_chat_questions WHERE question_key = 'Q-unrelated'")
    assert {:ok, %{questions: [%{"question_key" => "Q-selected"}]}} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
    assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-late-unrelated", "body" => "Late question?", "answers" => %{"yes" => true}})
    Store.query!(ctx.store, "UPDATE runs SET state = 'REVIEW_WRITING' WHERE run_id = 'run'")
    assert {:error, :unrelated_open_question} = TicketChatCommands.record_ready_rework(ctx.store, staged["command_key"], %{})
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-selected'") == %{"status" => "OPEN"}
  end

  test "READY rework ignores retained unbound staging intents", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    body = "Rework the current candidate."
    assert {:ok, staged} = stage(ctx, "ready-rework-current", body, [%{"operation" => "request_rework"}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    assert {:ok, old} = stage(ctx, "old-unbound-staging", "Old malformed proposal", [%{"operation" => "request_rework"}])
    assert old["status"] == "PENDING" and is_nil(old["input_key"]) and is_nil(old["receipt_json"])
    assert {:ok, _} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
    assert {:ok, ^old} = TicketChatCommands.get(ctx.store, old["command_key"])
  end

  test "READY rework rejects a competing bound pending interpretation", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-pending", "body" => "Keep?", "answers" => %{"yes" => true}})
    assert {:ok, staged} = stage(ctx, "ready-pending-winner", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    assert {:ok, pending} = stage(ctx, "ready-pending-other", "Answer Q-pending: yes", [%{"operation" => "answer_question", "question_key" => "Q-pending", "value" => true}])
    assert pending["status"] == "PENDING"
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = '{}' WHERE command_key = ?", [pending["command_key"]])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, ["Rework the current candidate."]))

    assert {:error, :competing_ticket_command} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
    Store.query!(ctx.store, "UPDATE runs SET state = 'REVIEW_WRITING' WHERE run_id = 'run'")
    assert {:error, :competing_ticket_command} = TicketChatCommands.record_ready_rework(ctx.store, staged["command_key"], %{})
  end

  test "READY rework rejects missing or incomplete transfer without consuming selected answers", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    question_key = "Q-ready-transfer"
    assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "Keep?", "answers" => %{"yes" => true}})
    body = "Answer #{question_key}: yes\nRework: current candidate"
    operations = [%{"operation" => "answer_question", "question_key" => question_key, "value" => true}, %{"operation" => "request_rework"}]
    {:ok, staged} = stage(ctx, "ready-transfer-missing", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    assert {:ok, validated} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
    assert validated.run["state"] == "READY_FOR_REVIEW"

    Store.query!(ctx.store, "UPDATE runs SET state = 'REVIEW_WRITING' WHERE run_id = 'run'")
    incomplete = %{"request_key" => "new-request", "reservation_key" => "new-reservation", "prior_request_key" => "prior-request"}

    rejected_transfers = [
      nil,
      incomplete,
      %{},
      %{"request_key" => "new-request"},
      %{"request_key" => "new-request", "reservation_key" => "new-reservation"},
      %{"request_key" => nil, "reservation_key" => "new-reservation", "prior_request_key" => "prior-request"},
      %{"request_key" => "new-request", "reservation_key" => nil, "prior_request_key" => "prior-request"},
      %{"request_key" => "new-request", "reservation_key" => "new-reservation", "prior_request_key" => nil},
      %{"request_key" => false, "reservation_key" => "new-reservation", "prior_request_key" => "prior-request"},
      %{"request_key" => "new-request", "reservation_key" => false, "prior_request_key" => "prior-request"},
      %{"request_key" => "new-request", "reservation_key" => "new-reservation", "prior_request_key" => false}
    ]

    protected = protected_amendment_state(ctx)

    for transfer <- rejected_transfers do
      assert {:error, :ready_rework_transfer_unproven} =
               TicketChatCommands.record_ready_rework(ctx.store, staged["command_key"], transfer)

      assert protected_amendment_state(ctx) == protected
    end

    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [question_key]) == %{"status" => "OPEN", "answer_json" => nil}
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, staged["command_key"])
  end

  test "corrupt applicable READY history cannot fall back to retained amendment history", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, older} = accepted_amendment(ctx, "older-amendment-history", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    assert {:ok, _reserved} = TicketContractAmendment.reserve(ctx.store, older["command_key"], amendment_context(ctx))

    # Preserve an older APPLIED amendment row so fallback is available, while keeping
    # the deliberately corrupt newer READY command as the applicable history head.
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET phase = 'APPLIED', active_owner = 0, receipt_json = '{}', application_receipt_sha256 = 'invalid' WHERE command_key = ?", [
      older["command_key"]
    ])

    body = "Rework the current candidate."
    {:ok, ready} = stage(ctx, "corrupt-ready-history", body, [%{"operation" => "request_rework"}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET status = 'APPLIED', application_receipt_json = '{' WHERE command_key = ?", [ready["command_key"]])

    assert {:error, :ticket_delivery_ready_rework_history_corrupt} = TicketWorkerRunner.retained_review_preimage(ctx.store, %{"run_id" => "run"})
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments WHERE phase = 'APPLIED'")["count"] == 1
    assert Store.one!(ctx.store, "SELECT application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [ready["command_key"]])["application_receipt_json"] == "{"
  end

  test "READY rework rejects an active contract amendment owner", ctx do
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, amendment} = accepted_amendment(ctx, "ready-active-amendment", "A revised contract\n\n## Manual Validation\n- Required: no")
    assert {:ok, _} = TicketContractAmendment.reserve(ctx.store, amendment["command_key"], amendment_context(ctx))
    body = "Rework the current candidate."
    assert {:ok, staged} = stage(ctx, "ready-active-owner", body, [%{"operation" => "request_rework"}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))

    assert {:error, :active_contract_amendment} = TicketChatCommands.validate_ready_rework(ctx.store, staged["command_key"])
    Store.query!(ctx.store, "UPDATE runs SET state = 'REVIEW_WRITING' WHERE run_id = 'run'")
    assert {:error, :active_contract_amendment} = TicketChatCommands.record_ready_rework(ctx.store, staged["command_key"], %{})
  end

  test "critic preparation is deterministic, persists an exact child task, and claims once across reopen", ctx do
    {:ok, command} = accepted_amendment(ctx, "critic-prepared", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    policy = critic_model_policy()
    protected = protected_amendment_state(ctx)

    assert {:ok, prepared} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    {:ok, effect} = prepare_draft(ctx, command, context)
    reviewed_snapshot = effect["readback_json"]
    assert {:ok, attempt} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, reviewed_snapshot, policy)
    assert attempt["phase"] == "PREPARED"
    assert attempt["run_id"] == "run"
    assert attempt["task_key"] == "run:contract-amendment-critic:#{command["command_key"]}"
    assert attempt["prompt_sha256"] == digest(attempt["prompt"])
    assert attempt["schema_sha256"] == digest(attempt["schema_json"])
    assert attempt["snapshot_sha256"] == digest(attempt["snapshot_json"])
    assert attempt["route_sha256"] == digest(attempt["route_json"])
    assert {:error, _reason} = Contract.authorized_from_snapshot(Jason.decode!(attempt["snapshot_json"]), "PPL-123")
    assert {:ok, ^attempt} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, reviewed_snapshot, policy)
    task = Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])
    assert task["role"] == "specification-critic"
    assert task["stage"] == "contract-amendment-critic"
    assert task["status"] == "PREPARED"
    assert task["prompt_sha256"] == attempt["prompt_sha256"]
    assert task["workspace"] == nil
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_key = ?", [attempt["task_key"]])["count"] == 0
    assert {:ok, ^prepared} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert protected_amendment_state(ctx) |> Map.put(:tasks, []) == protected |> Map.put(:tasks, [])

    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})

    try do
      assert {:ok, ^attempt} =
               TicketContractAmendment.prepare_critic(
                 reopened,
                 command["command_key"],
                 context,
                 reviewed_snapshot,
                 policy
               )

      assert {:ok, %{"phase" => "INVOKING"} = claimed} =
               TicketContractAmendment.claim_critic(
                 reopened,
                 command["command_key"],
                 context,
                 policy
               )

      assert claimed["task_key"] == attempt["task_key"]

      assert {:error, :critic_attempt_not_authorized} =
               TicketContractAmendment.claim_critic(
                 reopened,
                 command["command_key"],
                 context,
                 policy
               )

      assert {:error, :critic_attempt_not_authorized} =
               TicketContractAmendment.prepare_critic(
                 reopened,
                 command["command_key"],
                 context,
                 reviewed_snapshot,
                 policy
               )

      assert Store.one!(reopened, "SELECT status FROM factory_tasks WHERE task_key = ?", [attempt["task_key"]])["status"] == "INVOKING"
      assert {:ok, %{"phase" => "RESERVED"}} = TicketContractAmendment.get(reopened, command["command_key"])
    after
      stop_supervised!(Store)
    end
  end

  test "answer followed by exact contract delimiter preserves literal indented markdown bytes", ctx do
    ensure_normalized_snapshot(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q-mixed", "body" => "Keep candidate?", "answers" => %{"yes" => true}})
    markdown = "## Contract\nUpdated scope.\n\n## Manual Validation\n- Required: no\n\n```text\n    Answer Q-fake: yes\n```\n--- FACTORY CONTRACT REVISION ---\nAnswer Q-else: literal\n"
    body = "Answer Q-mixed: yes\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown

    operations = [
      %{"operation" => "answer_question", "question_key" => "Q-mixed", "value" => true},
      %{"operation" => "propose_contract_revision", "markdown" => markdown}
    ]

    {:ok, staged} = stage(ctx, "mixed-proposal", body, operations)

    readback =
      native(ctx, [body])
      |> put_in(["turns", Access.at(0), "id"], "mixed-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "mixed-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "mixed-client")

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert {:ok, validated} = TicketChatCommands.validate_contract_amendment(ctx.store, staged["command_key"])
    assert validated.proposed_contract.markdown =~ "--- FACTORY CONTRACT REVISION ---\nAnswer Q-else: literal"
    assert List.last(Jason.decode!(staged["payload_json"]))["markdown"] == markdown
    assert length(validated.answer_questions) == 1
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q-mixed'")["status"] == "OPEN"
  end

  test "mixed grammar accepts two and three distinct answers", ctx do
    ensure_normalized_snapshot(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")

    for count <- 2..3 do
      keys = Enum.map(1..count, &"Q-#{count}-#{&1}")

      Enum.each(keys, fn key ->
        assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => %{"yes" => true}})
      end)

      markdown = "Contract #{count}\n\n## Manual Validation\n- Required: no"
      answers = Enum.map(keys, &"Answer #{&1}: yes")
      body = Enum.join(answers, "\n") <> "\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown
      operations = Enum.map(keys, &%{"operation" => "answer_question", "question_key" => &1, "value" => true}) ++ [%{"operation" => "propose_contract_revision", "markdown" => markdown}]
      {:ok, staged} = stage(ctx, "mixed-#{count}", body, operations)

      readback =
        native(ctx, [body])
        |> put_in(["turns", Access.at(0), "id"], "mixed-turn-#{count}")
        |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "mixed-item-#{count}")
        |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "mixed-client-#{count}")

      assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
      assert {:ok, validated} = TicketChatCommands.validate_contract_amendment(ctx.store, staged["command_key"])
      assert Enum.map(validated.answer_questions, & &1["question_key"]) == keys
    end
  end

  test "amendment answer batches roll back ignored rows and validate genuine replay proof", ctx do
    ensure_normalized_snapshot(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")

    questions = [
      {"Q-proof-text", %{"type" => "text", "max_bytes" => 120}, "Preserve this exact text", "Preserve this exact text"},
      {"Q-proof-integer", %{"type" => "integer", "min" => 1, "max" => 100}, "30", 30}
    ]

    keys = Enum.map(questions, &elem(&1, 0))

    Enum.each(questions, fn {key, schema, _answer, _value} ->
      assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => schema})
    end)

    markdown = "Contract with answers\n\n## Manual Validation\n- Required: no"
    body = Enum.map_join(questions, "\n", fn {key, _schema, answer, _value} -> "Answer #{key}: #{answer}" end) <> "\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown

    operations =
      Enum.map(questions, fn {key, _schema, _answer, value} -> %{"operation" => "answer_question", "question_key" => key, "value" => value} end) ++
        [%{"operation" => "propose_contract_revision", "markdown" => markdown}]

    {:ok, staged} = stage(ctx, "answer-proof-batch", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    assert {:ok, validated} = TicketChatCommands.validate_contract_amendment(ctx.store, staged["command_key"])
    before_questions = Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions ORDER BY question_key").rows

    Store.query!(
      ctx.store,
      "CREATE TRIGGER ignore_second_amendment_answer BEFORE UPDATE OF status ON ticket_chat_questions WHEN NEW.question_key = 'Q-proof-integer' AND NEW.status = 'ANSWERED' BEGIN SELECT RAISE(IGNORE); END"
    )

    assert_raise RuntimeError, ~r/stale_question/, fn ->
      Store.transaction!(ctx.store, fn tx -> TicketChatCommands.apply_amendment_answers(tx, validated) end)
    end

    Store.query!(ctx.store, "DROP TRIGGER ignore_second_amendment_answer")
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions ORDER BY question_key").rows == before_questions

    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} =
             TicketChatCommands.get(ctx.store, staged["command_key"])

    assert {:ok, proof} = Store.transaction!(ctx.store, fn tx -> TicketChatCommands.apply_amendment_answers(tx, validated) end)
    assert proof["question_keys"] == keys
    assert :ok = TicketChatCommands.validate_amendment_answer_replay(ctx.store, validated.command, proof)
    before_missing_proof = protected_amendment_state(ctx)

    assert {:error, :amendment_answer_replay_unproven} =
             TicketChatCommands.validate_amendment_answer_replay(ctx.store, validated.command, nil)

    assert protected_amendment_state(ctx) == before_missing_proof

    missing = Store.one!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [List.last(keys)])
    Store.query!(ctx.store, "DELETE FROM ticket_chat_questions WHERE question_key = ?", [List.last(keys)])
    before_missing_question = protected_amendment_state(ctx)

    assert {:error, :amendment_answer_replay_unproven} =
             TicketChatCommands.validate_amendment_answer_replay(ctx.store, validated.command, proof)

    assert protected_amendment_state(ctx) == before_missing_question

    Store.query!(
      ctx.store,
      "INSERT INTO ticket_chat_questions(question_key, chat_key, run_id, binding_json, body, answers_json, opened_at, status, answer_json, input_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        missing["question_key"],
        missing["chat_key"],
        missing["run_id"],
        missing["binding_json"],
        missing["body"],
        missing["answers_json"],
        missing["opened_at"],
        missing["status"],
        missing["answer_json"],
        missing["input_key"]
      ]
    )

    assert :ok = TicketChatCommands.validate_amendment_answer_replay(ctx.store, validated.command, proof)
  end

  test "malformed mixed grammar rejects the whole proposal instead of applying an answer prefix", ctx do
    ensure_normalized_snapshot(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    markdown = "Contract\n\n## Manual Validation\n- Required: no"

    for {key, body} <- [
          {"wrong-delimiter", "Answer Q-wrong-delimiter: yes\n\n--- FACTORY CONTRACT REVISON ---\n" <> markdown},
          {"empty-section", "Answer Q-empty-section: yes\n\n--- FACTORY CONTRACT REVISION ---\n"},
          {"reversed", "Revise the contract:\n" <> markdown <> "\nAnswer Q-reversed: yes"},
          {"extra-rework", "Answer Q-extra-rework: yes\nRework: current candidate\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown},
          {"duplicate", "Answer Q-duplicate: yes\nAnswer Q-duplicate: yes\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown}
        ] do
      question_key = "Q-#{key}"
      {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "Keep?", "answers" => %{"yes" => true}})
      first_answer = %{"operation" => "answer_question", "question_key" => question_key, "value" => true}
      answers = if key == "duplicate", do: [first_answer, first_answer], else: [first_answer]
      ops = answers ++ [%{"operation" => "propose_contract_revision", "markdown" => markdown}]

      case stage(ctx, "malformed-#{key}", body, ops) do
        {:ok, staged} ->
          readback =
            native(ctx, [body])
            |> put_in(["turns", Access.at(0), "id"], "bad-turn-#{key}")
            |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "bad-item-#{key}")
            |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "bad-client-#{key}")

          assert {:ok, %{receipts: [%{"status" => "REJECTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
          assert {:ok, rejected} = TicketChatCommands.get(ctx.store, staged["command_key"])
          assert rejected["status"] == "REJECTED"

        {:error, reason} ->
          assert reason == :invalid_ticket_command
      end

      assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [question_key])["status"] == "OPEN"
    end

    excess_keys = Enum.map(1..4, &"Q-excess-#{&1}")

    Enum.each(excess_keys, fn key ->
      assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep?", "answers" => %{"yes" => true}})
    end)

    excess_body = Enum.map_join(excess_keys, "\n", &"Answer #{&1}: yes") <> "\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown
    excess_operations = Enum.map(excess_keys, &%{"operation" => "answer_question", "question_key" => &1, "value" => true}) ++ [%{"operation" => "propose_contract_revision", "markdown" => markdown}]
    assert {:error, :invalid_ticket_command} = stage(ctx, "malformed-excess", excess_body, excess_operations)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_questions WHERE question_key IN (?, ?, ?, ?) AND status = 'OPEN'", excess_keys)["count"] == 4
  end

  test "a proposal-only body starting at the delimiter rejects without a current question", ctx do
    ensure_normalized_snapshot(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    markdown = "Contract without an answer\n\n## Manual Validation\n- Required: no"
    body = "--- FACTORY CONTRACT REVISION ---\n" <> markdown
    operations = [%{"operation" => "propose_contract_revision", "markdown" => markdown}]
    {:ok, staged} = stage(ctx, "proposal-without-question", body, operations)
    before_admission = protected_amendment_state(ctx)
    other_commands_before = Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' AND command_key != ? ORDER BY command_key", [staged["command_key"]]).rows
    run_before = RunLedger.get(ctx.store, "run") |> elem(1)
    questions_before = Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows
    tasks_before = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows
    amendments_before = Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE run_id = 'run' ORDER BY command_key").rows

    assert {:ok, %{receipts: [%{"status" => "REJECTED", "receipt_json" => receipt_json}], worker_started: false}} =
             TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))

    assert {:ok, rejected} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert rejected["status"] == "REJECTED"
    assert rejected["receipt_json"] == receipt_json
    assert Jason.decode!(receipt_json)["reason"] == "no_current_question"
    assert Jason.decode!(receipt_json)["worker_started"] == false
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows == questions_before
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == tasks_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows == evidence_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows == access_before
    assert Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE run_id = 'run' ORDER BY command_key").rows == amendments_before
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])["status"] == "REJECTED"
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' AND command_key != ? ORDER BY command_key", [staged["command_key"]]).rows == other_commands_before
    assert Store.one!(ctx.store, "SELECT body FROM ticket_chat_inputs WHERE input_key = ?", [rejected["input_key"]])["body"] == body

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_COMMAND_REJECTED' AND json_extract(payload_json, '$.command_key') = ?", [staged["command_key"]])[
             "count"
           ] == 1

    assert before_admission.run == Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
  end

  test "four mixed answer lines reject the three-answer contract revision without changing ticket state", ctx do
    ensure_normalized_snapshot(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    keys = Enum.map(1..3, &"Q-four-line-#{&1}")

    Enum.each(keys, fn key ->
      assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => %{"yes" => true}})
    end)

    markdown = "Contract with bounded answers\n\n## Manual Validation\n- Required: no"
    body = Enum.map_join(keys ++ ["Q-four-line-extra"], "\n", &"Answer #{&1}: yes") <> "\n\n--- FACTORY CONTRACT REVISION ---\n" <> markdown
    operations = Enum.map(keys, &%{"operation" => "answer_question", "question_key" => &1, "value" => true}) ++ [%{"operation" => "propose_contract_revision", "markdown" => markdown}]
    {:ok, staged} = stage(ctx, "four-answer-lines", body, operations)
    {:ok, run_before} = RunLedger.get(ctx.store, "run")
    questions_before = Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows
    amendments_before = Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE run_id = 'run' ORDER BY command_key").rows
    tasks_before = Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows
    evidence_before = Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows
    access_before = Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows

    readback =
      native(ctx, [body])
      |> put_in(["turns", Access.at(0), "id"], "four-answer-lines-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "four-answer-lines-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "four-answer-lines-client")

    assert {:ok, %{receipts: [%{"status" => "REJECTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert {:ok, rejected} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert rejected["status"] == "REJECTED"
    assert Jason.decode!(rejected["receipt_json"])["reason"] == "invalid_mixed_contract_revision"
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows == questions_before
    assert Store.query!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE run_id = 'run' ORDER BY command_key").rows == amendments_before
    assert Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows == tasks_before
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows == evidence_before
    assert Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows == access_before
  end

  test "concurrent critic claims authorize exactly one caller", ctx do
    {:ok, command} = accepted_amendment(ctx, "critic-claim-race", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    policy = critic_model_policy()
    {:ok, _} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    {:ok, effect} = prepare_draft(ctx, command, context)
    reviewed_snapshot = effect["readback_json"]
    {:ok, _} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, reviewed_snapshot, policy)
    {:ok, other} = Store.start_link(database: ctx.database)

    try do
      tasks = [
        Task.async(fn -> TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, policy) end),
        Task.async(fn -> TicketContractAmendment.claim_critic(other, command["command_key"], context, policy) end)
      ]

      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert Enum.count(results, &match?({:ok, %{"phase" => "INVOKING"}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :critic_attempt_not_authorized})) == 1
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_critic_attempts WHERE command_key = ? AND phase = 'INVOKING'", [command["command_key"]])["count"] == 1
    after
      GenServer.stop(other)
    end
  end

  test "critic preparation rolls back child task registration when attempt insertion fails", ctx do
    {:ok, command} = accepted_amendment(ctx, "critic-insert-failure", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    {:ok, _} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    {:ok, effect} = prepare_draft(ctx, command, context)
    reviewed_snapshot = effect["readback_json"]
    Store.query!(ctx.store, "CREATE TRIGGER fail_critic_attempt_insert BEFORE INSERT ON ticket_contract_critic_attempts BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END")

    assert_raise Exqlite.Error, fn ->
      TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, reviewed_snapshot, critic_model_policy())
    end

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_critic_attempts")["count"] == 0
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM factory_tasks WHERE run_id = 'run'")["count"] == 0
  end

  test "critic attempt rejects changed route, binding, and self-consistent attempt tampering", ctx do
    {:ok, command} = accepted_amendment(ctx, "critic-tamper", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    policy = critic_model_policy()
    {:ok, _} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    {:ok, effect} = prepare_draft(ctx, command, context)
    reviewed_snapshot = effect["readback_json"]
    {:ok, attempt} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, reviewed_snapshot, policy)
    changed_policy = put_in(policy, ["providers", "openai", "standard"], "replacement-model")
    assert {:error, :critic_attempt_binding_conflict} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, changed_policy)

    changed_prompt = attempt["prompt"] <> " altered"
    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET prompt = ?, prompt_sha256 = ? WHERE command_key = ?", [changed_prompt, digest(changed_prompt), command["command_key"]])
    assert {:error, :invalid_critic_attempt} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, policy)

    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET prompt = ?, prompt_sha256 = ? WHERE command_key = ?", [attempt["prompt"], attempt["prompt_sha256"], command["command_key"]])
    changed_snapshot = attempt["snapshot_json"] |> Jason.decode!() |> Map.put("description", "changed issue description") |> Jason.encode!()

    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET snapshot_json = ?, snapshot_sha256 = ? WHERE command_key = ?", [
      changed_snapshot,
      digest(changed_snapshot),
      command["command_key"]
    ])

    assert {:error, :invalid_critic_attempt} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, policy)

    Store.query!(ctx.store, "UPDATE ticket_contract_critic_attempts SET snapshot_json = ?, snapshot_sha256 = ? WHERE command_key = ?", [
      attempt["snapshot_json"],
      attempt["snapshot_sha256"],
      command["command_key"]
    ])

    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert {:error, _reason} = TicketContractAmendment.claim_critic(ctx.store, command["command_key"], context, policy)
  end

  test "accepted direct proposal reserves once without changing protected ticket state", ctx do
    {:ok, command} = accepted_amendment(ctx, "reserved", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    context = amendment_context(ctx, run)
    protected = protected_amendment_state(ctx)

    assert {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    assert amendment["phase"] == "RESERVED"
    assert amendment["prior_revision"] == 1
    assert amendment["proposed_revision"] == 2
    assert amendment["proposed_contract_sha256"] == Contract.digest("A confirmed contract\n\n## Manual Validation\n- Required: no")
    assert {:ok, ^amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:ok, duplicate} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    assert duplicate == amendment
    assert protected_amendment_state(ctx) == protected
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 1
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})

    try do
      assert {:ok, ^amendment} = TicketContractAmendment.get(reopened, command["command_key"])
    after
      stop_supervised!(Store)
    end
  end

  test "amendment reservation fails closed for Required yes and stale bindings", ctx do
    {:ok, yes_command} = accepted_amendment(ctx, "required-yes", "A confirmed contract\n\n## Manual Validation\n- Required: yes")
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, yes_command["command_key"], amendment_context(ctx))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0

    {:ok, command} = accepted_amendment(ctx, "stale", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "mixed operations cannot authorize a supported proposal prefix", ctx do
    {:ok, command} = accepted_amendment(ctx, "mixed", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    receipts = Jason.decode!(input["staging_receipts_json"])
    receipt = receipts[command["command_key"]]
    mixed = [%{"operation" => "propose_contract_revision", "markdown" => "A confirmed contract\n\n## Manual Validation\n- Required: no"}, %{"operation" => "request_rework"}]
    payload = Jason.encode!(mixed)
    payload_sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    receipt = put_in(receipt, ["payload_sha256"], payload_sha) |> put_in(["attrs", "operations"], mixed)
    receipts = Map.put(receipts, command["command_key"], receipt)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [payload, payload_sha, command["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = ? WHERE input_key = ?", [Jason.encode!(receipts), command["input_key"]])

    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "a WRITING amendment requires an exact retained stopped BLOCKED disposition", ctx do
    {:ok, command} = accepted_amendment(ctx, "unproven-block", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    before = protected_amendment_state(ctx)
    assert {:error, :stopped_blocked_writer_not_proven} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))
    assert protected_amendment_state(ctx) == before
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "two ledger connections racing on one command return the same durable row", ctx do
    {:ok, command} = accepted_amendment(ctx, "race", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, other} = Store.start_link(database: ctx.database)
    context = amendment_context(ctx)

    try do
      tasks = [
        Task.async(fn -> TicketContractAmendment.reserve(ctx.store, command["command_key"], context) end),
        Task.async(fn -> TicketContractAmendment.reserve(other, command["command_key"], context) end)
      ]

      assert [{:ok, left}, {:ok, right}] = Enum.map(tasks, &Task.await(&1, 10_000))
      assert left == right
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 1
    after
      GenServer.stop(other)
    end
  end

  test "different accepted proposals racing for one run leave one owner and both commands intact", ctx do
    {:ok, first} = accepted_amendment(ctx, "first-owner", "First proposal\n\n## Manual Validation\n- Required: no")
    {:ok, second} = accepted_amendment(ctx, "second-owner", "Second proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    before = protected_amendment_state(ctx)
    {:ok, other} = Store.start_link(database: ctx.database)

    try do
      tasks = [
        Task.async(fn -> TicketContractAmendment.reserve(ctx.store, first["command_key"], context) end),
        Task.async(fn -> TicketContractAmendment.reserve(other, second["command_key"], context) end)
      ]

      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :amendment_reservation_conflict})) == 1

      assert Enum.all?([first, second], fn command ->
               assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, command["command_key"])
             end)

      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments WHERE active_owner = 1")["count"] == 1
      assert protected_amendment_state(ctx) == before
    after
      GenServer.stop(other)
    end
  end

  test "a second accepted proposal for the current READY candidate reports a reservation conflict", ctx do
    {:ok, first} = accepted_amendment(ctx, "ready-first-owner", "First proposal\n\n## Manual Validation\n- Required: no")
    {:ok, second} = accepted_amendment(ctx, "ready-second-owner", "Second proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)

    assert {:ok, _reserved} = TicketContractAmendment.reserve(ctx.store, first["command_key"], context)
    before_competitor = protected_amendment_state(ctx)
    competing_result = TicketContractAmendment.reserve(ctx.store, second["command_key"], context)

    assert competing_result == {:error, :amendment_reservation_conflict},
           "a competing current-candidate proposal did not receive the ownership-conflict outcome: #{inspect(competing_result)}"

    assert protected_amendment_state(ctx) == before_competitor
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, first["command_key"])
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, second["command_key"])
    assert Store.one!(ctx.store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = 'run' AND active_owner = 1") == %{"command_key" => first["command_key"]}
  end

  test "corrupt reserved ownership cannot validate a competitor or authorize replay", ctx do
    {:ok, first} = accepted_amendment(ctx, "corrupt-ready-owner", "First proposal\n\n## Manual Validation\n- Required: no")
    {:ok, second} = accepted_amendment(ctx, "corrupt-ready-competitor", "Second proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    assert {:ok, reserved} = TicketContractAmendment.reserve(ctx.store, first["command_key"], context)

    snapshot = fn ->
      extra =
        for table <- ~w(ticket_contract_amendments ticket_contract_critic_attempts ticket_amendment_jira_effects ticket_amendment_authorization_effects ticket_contract_amendment_supersessions),
            into: %{},
            do: {table, Store.query!(ctx.store, "SELECT * FROM #{table} ORDER BY 1").rows}

      {protected_amendment_state(ctx), extra}
    end

    for {field, raw, operation, error} <- [
          {"prior_binding_json", "[]", :competitor, :invalid_contract_amendment},
          {"supersession_json", "{", :replay, :invalid_contract_amendment},
          {"supersession_json", "[]", :replay, :invalid_amendment_proposal}
        ] do
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET #{field} = ? WHERE command_key = ?", [raw, first["command_key"]])
      before_read = snapshot.()

      result =
        case operation do
          :competitor -> TicketChatCommands.validate_contract_amendment(ctx.store, second["command_key"])
          :replay -> TicketContractAmendment.reserve(ctx.store, first["command_key"], context)
        end

      assert result == {:error, error}
      assert snapshot.() == before_read
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET #{field} = ? WHERE command_key = ?", [reserved[field], first["command_key"]])
      assert {:ok, ^reserved} = TicketContractAmendment.reserve(ctx.store, first["command_key"], context)
    end
  end

  test "inactive reserved replay is rejected and cannot release run ownership", ctx do
    {:ok, first} = accepted_amendment(ctx, "inactive-owner", "First proposal\n\n## Manual Validation\n- Required: no")
    {:ok, second} = accepted_amendment(ctx, "waiting-owner", "Second proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    assert {:ok, reserved} = TicketContractAmendment.reserve(ctx.store, first["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET active_owner = 0 WHERE command_key = ?", [first["command_key"]])

    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, first["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.reserve(ctx.store, first["command_key"], context)
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.reserve(ctx.store, second["command_key"], context)

    assert Store.one!(ctx.store, "SELECT active_owner, phase FROM ticket_contract_amendments WHERE command_key = ?", [first["command_key"]]) == %{
             "active_owner" => 0,
             "phase" => "RESERVED"
           }

    Store.query!(ctx.store, "PRAGMA ignore_check_constraints = ON")
    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET phase = 'UNKNOWN' WHERE command_key = ?", [first["command_key"]])
    Store.query!(ctx.store, "PRAGMA ignore_check_constraints = OFF")
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, first["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.reserve(ctx.store, first["command_key"], context)
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.reserve(ctx.store, second["command_key"], context)
    assert reserved["active_owner"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 1
  end

  test "getter rejects a self-consistent proposal body that differs from the accepted command", ctx do
    {:ok, command} = accepted_amendment(ctx, "getter-proposal-binding", "Original proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    assert {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))

    for {field, altered} <- [
          {"prior_binding_json", "{}"},
          {"proposed_revision", amendment["proposed_revision"] + 1}
        ] do
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET #{field} = ? WHERE command_key = ?", [altered, command["command_key"]])
      corrupted = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
      assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
      assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == corrupted
      Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET #{field} = ? WHERE command_key = ?", [amendment[field], command["command_key"]])
      assert {:ok, ^amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    end

    changed_markdown = "Different proposal\n\n## Manual Validation\n- Required: no"
    changed_sha = Contract.digest(changed_markdown)

    Store.query!(ctx.store, "UPDATE ticket_contract_amendments SET proposed_contract_markdown = ?, proposed_contract_sha256 = ? WHERE command_key = ?", [
      changed_markdown,
      changed_sha,
      command["command_key"]
    ])

    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    assert {:error, :invalid_contract_amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))
    assert amendment["proposed_contract_markdown"] != changed_markdown
  end

  test "stale caller binding and changed native input cannot reserve", ctx do
    {:ok, command} = accepted_amendment(ctx, "stale-input", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    assert {:error, :stale_controller_context} = TicketContractAmendment.reserve(ctx.store, command["command_key"], Map.put(context, "run_id", "other"))

    input = Store.one!(ctx.store, "SELECT body FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = 'edited native input' WHERE input_key = ?", [command["input_key"]])
    assert {:error, :native_input_evidence_mismatch} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET body = ? WHERE input_key = ?", [input["body"], command["input_key"]])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "a drifted ticket run association is rejected before reservation", ctx do
    {:ok, command} = accepted_amendment(ctx, "association-drift", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    association = Store.one!(ctx.store, "SELECT * FROM ticket_chat_runs WHERE run_id = 'run'")
    Store.query!(ctx.store, "DELETE FROM ticket_chat_runs WHERE run_id = 'run'")

    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0

    Store.query!(ctx.store, "INSERT INTO ticket_chat_runs(run_id, chat_key, created_at) VALUES (?, ?, ?)", [association["run_id"], association["chat_key"], association["created_at"]])
  end

  test "chat generation and installed contract drift reject accepted amendments", ctx do
    {:ok, generation_command} = accepted_amendment(ctx, "generation-drift", "Generation proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE ticket_chats SET generation = 2 WHERE chat_key = ?", [ctx.chat["chat_key"]])
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, generation_command["command_key"], amendment_context(ctx))
    Store.query!(ctx.store, "UPDATE ticket_chats SET generation = 1 WHERE chat_key = ?", [ctx.chat["chat_key"]])

    {:ok, contract_command} = accepted_amendment(ctx, "contract-drift", "Contract proposal\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET contract_sha256 = ? WHERE run_id = 'run'", [String.duplicate("c", 64)])
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, contract_command["command_key"], amendment_context(ctx))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "missing and malformed Required directives are not admitted", ctx do
    for {id, markdown} <- [
          {"missing-required", "A confirmed contract\n\n## Manual Validation\nNo directive."},
          {"malformed-required", "A confirmed contract\n\n## Manual Validation\n- Required: maybe"}
        ] do
      {:ok, command} = accepted_amendment(ctx, id, markdown)
      assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], amendment_context(ctx))
    end

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "corrupted admission, input staging, and payload digests cannot reserve", ctx do
    {:ok, command} = accepted_amendment(ctx, "corrupt-evidence", "A confirmed contract\n\n## Manual Validation\n- Required: no")
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    context = amendment_context(ctx)
    input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])

    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = '[]' WHERE command_key = ?", [command["command_key"]])
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = ? WHERE command_key = ?", [command["receipt_json"], command["command_key"]])

    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = '[]' WHERE input_key = ?", [command["input_key"]])
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = ? WHERE input_key = ?", [input["staging_receipts_json"], command["input_key"]])

    bad_payload = Jason.encode!([%{"operation" => "propose_contract_revision", "markdown" => "changed"}])
    bad_sha = :crypto.hash(:sha256, bad_payload) |> Base.encode16(case: :lower)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [bad_payload, bad_sha, command["command_key"]])
    assert {:error, _reason} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [command["payload_json"], command["payload_sha256"], command["command_key"]])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_contract_amendments")["count"] == 0
  end

  test "active-turn staging waits for direct completed input and consumes a question plus request exactly once", ctx do
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q1", "body" => "Keep the candidate?", "answers" => %{"yes" => true, "yes please" => true, "no" => false}})
    operations = [%{"operation" => "answer_question", "question_key" => "Q1", "value" => true}, %{"operation" => "request_rework"}]
    body = "Answer Q1: Yes please!\nRework: current candidate"
    assert {:ok, pending} = stage(ctx, "proposal", body, operations)
    assert pending["status"] == "PENDING"
    native = native(ctx, [body])
    busy = put_in(native, ["turns", Access.at(0), "status"], "inProgress")
    assert {:ok, %{receipts: []}} = TicketChatCommands.admit_readback(ctx.store, "run", busy)
    assert {:ok, %{receipts: [accepted], worker_started: false}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    assert accepted["status"] == "ACCEPTED"
    assert {:ok, %{receipts: [^accepted]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q1'")["status"] == "OPEN"
    assert accepted["receipt_json"] != nil
    assert accepted["application_receipt_json"] == nil
    assert {:ok, still_accepted} = apply_command(ctx, accepted)
    assert still_accepted["status"] == "ACCEPTED"
    assert still_accepted["application_receipt_json"] == nil
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q1'")["status"] == "OPEN"
    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 0}} = RunLedger.get(ctx.store, "run")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM factory_tasks")["count"] == 0
  end

  test "quoted and unrelated source cannot authorize the parent interpretation", ctx do
    for {body, n} <-
          Enum.with_index(
            [
              "> Please rework the current candidate.",
              "```\nPlease rework the current candidate.\n```",
              "The log says: rework the current candidate",
              "What is the current stage?",
              "Do not rework the current candidate.",
              "Please rework the current candidate if CI fails.",
              "Please rework the current candidate.\u200B"
            ],
            1
          ) do
      assert {:ok, staged} = stage(ctx, "malicious-#{n}", body, [%{"operation" => "request_rework"}])
      input = native(ctx, [body]) |> put_in(["turns", Access.at(0), "id"], "turn-#{n}") |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "client-#{n}")
      assert {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", input)
      assert {:ok, %{"status" => "REJECTED"}} = TicketChatCommands.get(ctx.store, staged["command_key"])
      rejected = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
      assert {:ok, ^rejected} = apply_command(ctx, rejected)
    end
  end

  test "answer-only application and replay survive a database reopen", ctx do
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q", "body" => "Keep?", "answers" => %{"yes" => true}})
    body = "Answer Q: yes"
    {:ok, staged} = stage(ctx, "reopen", body, [%{"operation" => "answer_question", "question_key" => "Q", "value" => true}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    accepted = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    assert {:ok, applied} = apply_command(ctx, accepted)
    assert applied["status"] == "APPLIED"
    assert applied["receipt_json"] == accepted["receipt_json"]
    assert applied["application_receipt_json"] != nil
    application_events = Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_COMMAND_APPLIED' AND run_id = 'run'")["count"]
    assert application_events == 1
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})

    assert {:ok, replayed} =
             TicketChatCommands.apply_accepted(reopened, staged["command_key"], %{
               "chat_key" => ctx.chat["chat_key"],
               "run_id" => "run",
               "binding" => %{"generation" => 1, "spec_revision" => 1, "contract_sha256" => ctx.contract.sha256, "candidate_sha" => String.duplicate("a", 40)}
             })

    assert replayed == applied
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_COMMAND_APPLIED' AND run_id = 'run'")["count"] == 1
    assert Store.one!(reopened, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q'")["status"] == "ANSWERED"
    stop_supervised!(Store)
  end

  test "multiple answers apply only after every question remains current", ctx do
    for key <- ["Q1", "Q2"], do: TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => %{"yes" => true}})
    body = "Answer Q1: yes\nAnswer Q2: yes"
    operations = Enum.map(["Q1", "Q2"], &%{"operation" => "answer_question", "question_key" => &1, "value" => true})
    {:ok, staged} = stage(ctx, "multi-answer", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    accepted = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET body = 'Changed Q2?' WHERE question_key = 'Q2'")
    assert {:ok, rejected} = apply_command(ctx, accepted)
    assert rejected["status"] == "REJECTED"
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q1'")["status"] == "OPEN"
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q2'")["status"] == "OPEN"
    assert {:ok, ^rejected} = apply_command(ctx, rejected)
  end

  test "mixed rework preflight rejects a stale later answer before any question changes", ctx do
    for key <- ["Q1", "Q2"], do: TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => %{"yes" => true}})
    body = "Answer Q1: yes\nAnswer Q2: yes\nRework: current candidate"
    operations = Enum.map(["Q1", "Q2"], &%{"operation" => "answer_question", "question_key" => &1, "value" => true}) ++ [%{"operation" => "request_rework"}]
    {:ok, staged} = stage(ctx, "mixed-stale-answer", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET body = 'Changed Q2?' WHERE question_key = 'Q2'")

    assert {:error, :native_intent_mismatch} = TicketChatCommands.preflight_rework_transfer(ctx.store, staged["command_key"])
    assert Store.query!(ctx.store, "SELECT question_key, status, answer_json FROM ticket_chat_questions ORDER BY question_key").rows == [["Q1", "OPEN", nil], ["Q2", "OPEN", nil]]
    assert {:ok, %{"status" => "ACCEPTED", "application_receipt_json" => nil}} = TicketChatCommands.get(ctx.store, staged["command_key"])
  end

  test "all answer questions apply together when current", ctx do
    for key <- ["Q1", "Q2"], do: TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep #{key}?", "answers" => %{"yes" => true}})
    body = "Answer Q1: yes\nAnswer Q2: yes"
    operations = Enum.map(["Q1", "Q2"], &%{"operation" => "answer_question", "question_key" => &1, "value" => true})
    {:ok, staged} = stage(ctx, "multi-answer", body, operations)
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    accepted = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    assert {:ok, applied} = apply_command(ctx, accepted)
    assert applied["status"] == "APPLIED"
    assert Store.query!(ctx.store, "SELECT question_key, status FROM ticket_chat_questions ORDER BY question_key").rows == [["Q1", "ANSWERED"], ["Q2", "ANSWERED"]]
  end

  test "broker, assistant, incomplete and malformed inputs remain non-authorizing", ctx do
    {:ok, staged} = stage(ctx, "proposal", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    valid = native(ctx, ["Rework the current candidate."])
    staged_before = protected_amendment_state(ctx)

    for changed <- [
          put_in(valid, ["turns", Access.at(0), "status"], "interrupted"),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(0), "type"], "agentMessage")
        ] do
      assert {:ok, %{receipts: []}} = TicketChatCommands.admit_readback(ctx.store, "run", changed)
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs")["count"] == 0
      assert {:ok, ^staged} = TicketChatCommands.get(ctx.store, staged["command_key"])
    end

    for changed <- [
          put_in(valid, ["turns", Access.at(0), "items", Access.at(0), "id"], nil),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(0), "clientId"], nil),
          update_in(valid, ["turns", Access.at(0), "items", Access.at(0)], &Map.delete(&1, "clientId")),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(0), "content"], [%{"type" => "image", "text" => "Rework"}]),
          put_in(valid, ["turns", Access.at(0), "items", Access.at(0), "content"], nil)
        ] do
      assert {:error, :native_input_history_invalid} = TicketChatCommands.admit_readback(ctx.store, "run", changed)
      assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs")["count"] == 0
      assert {:ok, ^staged} = TicketChatCommands.get(ctx.store, staged["command_key"])
      assert protected_amendment_state(ctx) == staged_before
    end

    broker_output = update_in(valid, ["turns", Access.at(0), "items"], &(&1 ++ [%{"type" => "functionCallOutput"}]))

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}], worker_started: false}} =
             TicketChatCommands.admit_readback(ctx.store, "run", broker_output)

    assert {:ok, %{"status" => "ACCEPTED"}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert {:error, :native_input_route_mismatch} = TicketChatCommands.admit_readback(ctx.store, "run", %{valid | "id" => "other"})
    assert {:error, :native_input_history_invalid} = TicketChatCommands.admit_readback(ctx.store, "run", %{})
  end

  test "two distinct messages are preserved and edited native identity rolls back the batch", ctx do
    for {body, id} <- [{"Rework the current candidate.", "one"}, {"Revise the contract:\nUpdated AC", "two"}] do
      op = if id == "one", do: %{"operation" => "request_rework"}, else: %{"operation" => "propose_contract_revision", "markdown" => "Updated AC"}
      assert {:ok, _} = stage(ctx, id, body, [op])
    end

    readback = native(ctx, ["Rework the current candidate.", "Revise the contract:\nUpdated AC"])
    assert {:ok, %{receipts: [first, second]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert first["status"] == second["status"] and first["status"] == "ACCEPTED"
    assert {:ok, %{"contract_markdown" => markdown}} = RunLedger.get(ctx.store, "run")
    assert {:ok, false} = Contract.manual_validation_required(markdown)
    edited = put_in(readback, ["turns", Access.at(0), "items", Access.at(0), "content", Access.at(0), "text"], "Rework the current candidate!")
    assert {:error, :native_input_changed} = TicketChatCommands.admit_readback(ctx.store, "run", edited)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs")["count"] == 2
  end

  test "stale generation, revision, candidate and question cannot accept an old yes", ctx do
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q1", "body" => "Keep?", "answers" => %{"yes" => true}})
    {:ok, staged} = stage(ctx, "proposal", "yes", [%{"operation" => "answer_question", "question_key" => "Q1", "value" => true}])
    Store.query!(ctx.store, "UPDATE runs SET spec_revision = 2, candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    first_readback = native(ctx, ["yes"])
    assert {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", first_readback)
    assert {:ok, %{"status" => "REJECTED", "receipt_json" => receipt}} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert receipt =~ "stale_command_binding"
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q1'")["status"] == "OPEN"
  end

  test "accepted answers are durably rejected when the current binding or question changes", ctx do
    accepted = accepted_answer(ctx, "accepted-stale")
    Store.query!(ctx.store, "UPDATE runs SET spec_revision = 2 WHERE run_id = 'run'")
    assert_post_admission_stale_rejection(ctx, accepted)
  end

  test "generation drift after acceptance rejects without answering", ctx do
    accepted = accepted_answer(ctx, "generation-drift")
    Store.query!(ctx.store, "UPDATE ticket_chats SET generation = 2 WHERE chat_key = ?", [ctx.chat["chat_key"]])
    assert_post_admission_stale_rejection(ctx, accepted)
  end

  test "candidate drift after acceptance rejects without answering", ctx do
    accepted = accepted_answer(ctx, "candidate-drift")
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert_post_admission_stale_rejection(ctx, accepted)
  end

  test "contract digest drift after acceptance rejects without answering", ctx do
    accepted = accepted_answer(ctx, "contract-drift")
    Store.query!(ctx.store, "UPDATE runs SET contract_sha256 = ? WHERE run_id = 'run'", [String.duplicate("c", 64)])
    assert_post_admission_stale_rejection(ctx, accepted)
  end

  test "question digest drift after acceptance rejects without answering", ctx do
    accepted = accepted_answer(ctx, "question-drift")
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET body = 'Changed wording' WHERE question_key = ?", [accepted["test_question_key"]])
    assert_post_admission_stale_rejection(ctx, accepted)
  end

  test "malformed admission and staging JSON fail closed durably", ctx do
    for {proposal, corrupted_json, target} <- [
          {"admission-list", "[]", :admission},
          {"admission-number", "42", :admission},
          {"admission-invalid-json", "{", :admission},
          {"staging-list", "[]", :staging},
          {"staging-number", "42", :staging},
          {"staging-invalid-json", "{", :staging}
        ] do
      accepted = accepted_answer(ctx, proposal)

      case target do
        :admission -> Store.query!(ctx.store, "UPDATE ticket_chat_commands SET receipt_json = ? WHERE command_key = ?", [corrupted_json, accepted["command_key"]])
        :staging -> Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = ? WHERE input_key = ?", [corrupted_json, accepted["input_key"]])
      end

      assert {:ok, rejected} = apply_command(ctx, accepted)
      assert rejected["status"] == "REJECTED"
      assert rejected["receipt_json"] == if(target == :admission, do: corrupted_json, else: accepted["receipt_json"])
      assert rejected["application_receipt_json"] != nil
      assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]])["status"] == "OPEN"

      if target == :staging do
        assert Jason.decode!(rejected["application_receipt_json"])["reason"] == "native_input_evidence_mismatch"
      end
    end
  end

  test "absent staging receipt and invalid input timestamp reject without answering", ctx do
    for {proposal, tamper} <- [
          {"absent-staging-receipt", :absent_receipt},
          {"malformed-staging-receipt", :malformed_receipt},
          {"invalid-command-timestamp", :timestamp}
        ] do
      accepted = accepted_answer(ctx, proposal)
      before_question = Store.one!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]])

      case tamper do
        :absent_receipt ->
          Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = '{}' WHERE input_key = ?", [accepted["input_key"]])

        :malformed_receipt ->
          Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = '[]' WHERE input_key = ?", [accepted["input_key"]])

        :timestamp ->
          Store.query!(ctx.store, "UPDATE ticket_chat_commands SET created_at = 'not-a-timestamp' WHERE command_key = ?", [accepted["command_key"]])
      end

      assert {:ok, rejected} = apply_command(ctx, accepted)
      assert rejected["status"] == "REJECTED"

      assert Jason.decode!(rejected["application_receipt_json"]) == %{
               "status" => "REJECTED",
               "reason" => "native_input_evidence_mismatch",
               "command_key" => accepted["command_key"],
               "input_key" => accepted["input_key"]
             }

      assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]]) == before_question
    end
  end

  test "malformed persisted operations are rejected rather than left accepted", ctx do
    for {proposal, payload} <- [{"invalid-json", "{"}, {"empty-list", "[]"}, {"number", "42"}, {"bad-operation", "[\"bad operation\"]"}] do
      accepted = accepted_answer(ctx, proposal)
      sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [payload, sha, accepted["command_key"]])
      assert {:ok, rejected} = apply_command(ctx, accepted)
      assert rejected["status"] == "REJECTED"
      assert rejected["application_receipt_json"] != nil
      assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]])["status"] == "OPEN"
    end

    for {proposal, bad_digest} <- [{"digest-number", 42}, {"digest-null", nil}] do
      accepted = accepted_answer(ctx, proposal)
      operation = %{"operation" => "answer_question", "question_key" => accepted["test_question_key"], "value" => true, "question_digest" => bad_digest}
      payload = Jason.encode!([operation])
      sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      input = Store.one!(ctx.store, "SELECT staging_receipts_json FROM ticket_chat_inputs WHERE input_key = ?", [accepted["input_key"]])
      receipts = Jason.decode!(input["staging_receipts_json"])
      receipt = Map.update!(receipts[accepted["command_key"]], "payload_sha256", fn _ -> sha end)
      receipts = Map.put(receipts, accepted["command_key"], receipt)
      Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = ?, payload_sha256 = ? WHERE command_key = ?", [payload, sha, accepted["command_key"]])
      Store.query!(ctx.store, "UPDATE ticket_chat_inputs SET staging_receipts_json = ? WHERE input_key = ?", [Jason.encode!(receipts), accepted["input_key"]])
      assert {:ok, rejected} = apply_command(ctx, accepted)
      assert rejected["status"] == "REJECTED"
      assert rejected["application_receipt_json"] != nil
      assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]])["status"] == "OPEN"
    end
  end

  test "terminal replay rejects a missing or corrupted application receipt without overwriting it", ctx do
    accepted = accepted_answer(ctx, "terminal-corrupt")
    assert {:ok, applied} = apply_command(ctx, accepted)
    applied = Map.put(applied, "test_question_key", accepted["test_question_key"])

    for bad_receipt <- [
          nil,
          "[]",
          "42",
          "{",
          Jason.encode!(%{"status" => "REJECTED", "command_key" => applied["command_key"], "input_key" => applied["input_key"]}),
          Jason.encode!(%{"status" => "APPLIED", "command_key" => "other", "input_key" => applied["input_key"]}),
          Jason.encode!(%{"status" => "APPLIED", "command_key" => applied["command_key"], "input_key" => "other"})
        ] do
      Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ? WHERE command_key = ?", [bad_receipt, applied["command_key"]])
      assert {:error, :invalid_application_receipt} = apply_command(ctx, applied)
      assert Store.one!(ctx.store, "SELECT application_receipt_json FROM ticket_chat_commands WHERE command_key = ?", [applied["command_key"]])["application_receipt_json"] == bad_receipt
      assert Store.one!(ctx.store, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [applied["test_question_key"]])["answer_json"] == "true"
    end

    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ?, receipt_json = ? WHERE command_key = ?", [
      applied["application_receipt_json"],
      Jason.encode!(%{"status" => "REJECTED", "input_key" => applied["input_key"]}),
      applied["command_key"]
    ])

    incompatible = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [applied["command_key"]])
    assert {:error, :invalid_application_receipt} = apply_command(ctx, applied)
    assert Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [applied["command_key"]]) == incompatible
    assert Store.one!(ctx.store, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [applied["test_question_key"]])["answer_json"] == "true"

    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ?, receipt_json = ? WHERE command_key = ?", [
      applied["application_receipt_json"],
      Jason.encode!(%{"status" => "ACCEPTED", "input_key" => "other"}),
      applied["command_key"]
    ])

    assert {:error, :invalid_application_receipt} = apply_command(ctx, applied)
    assert Store.one!(ctx.store, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [applied["test_question_key"]])["answer_json"] == "true"

    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET application_receipt_json = ?, receipt_json = ?, input_key = NULL WHERE command_key = ?", [
      applied["application_receipt_json"],
      applied["receipt_json"],
      applied["command_key"]
    ])

    assert {:error, :invalid_application_receipt} = apply_command(ctx, applied)
    assert Store.one!(ctx.store, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [applied["test_question_key"]])["answer_json"] == "true"
  end

  test "answer-only history stays outside retained review preimage and malformed payload remains unclassified", ctx do
    accepted = accepted_answer(ctx, "answer-only-review-history")
    assert {:ok, applied} = apply_command(ctx, accepted)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    assert {:error, :ticket_delivery_review_history_absent} = TicketWorkerRunner.retained_review_preimage(ctx.store, run)
    original_payload = applied["payload_json"]
    protected_before = protected_amendment_state(ctx)

    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = '{' WHERE command_key = ?", [applied["command_key"]])
    protected_after_tamper = protected_amendment_state(ctx)

    try do
      assert {:error, :ticket_delivery_ready_rework_history_unclassified} = TicketWorkerRunner.retained_review_preimage(ctx.store, run)
      assert protected_amendment_state(ctx) == protected_after_tamper
    after
      Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = ? WHERE command_key = ?", [original_payload, applied["command_key"]])
    end

    assert {:error, :ticket_delivery_review_history_absent} = TicketWorkerRunner.retained_review_preimage(ctx.store, run)
    assert protected_amendment_state(ctx) == protected_before
  end

  test "ambiguous questions and extra clauses reject atomically", ctx do
    for key <- ["Q1", "Q2"], do: TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => key, "body" => "Keep?", "answers" => %{"yes" => true}})
    {:ok, cmd} = stage(ctx, "ambiguous", "yes", [%{"operation" => "answer_question", "question_key" => "Q1", "value" => true}])
    first_readback = native(ctx, ["yes"])
    assert {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", first_readback)
    assert {:ok, %{"status" => "REJECTED", "receipt_json" => receipt}} = TicketChatCommands.get(ctx.store, cmd["command_key"])
    assert receipt =~ "ambiguous_question"
    {:ok, cmd2} = stage(ctx, "extra", "Answer Q1: yes\nand deploy production", [%{"operation" => "answer_question", "question_key" => "Q1", "value" => true}])
    second = native(ctx, ["ignored", "Answer Q1: yes\nand deploy production"])
    second = put_in(second, ["turns", Access.at(0)], hd(first_readback["turns"]))
    assert {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", second)
    assert {:ok, %{"status" => "REJECTED"}} = TicketChatCommands.get(ctx.store, cmd2["command_key"])
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_questions WHERE status = 'OPEN'")["count"] == 2
  end

  test "historical matching text cannot acquire a new action from a later proposal", ctx do
    body = "Rework the current candidate."
    historical = native(ctx, [body])
    assert {:ok, %{receipts: [%{status: "OBSERVED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", historical)
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    {:ok, staged} = stage(ctx, "later", body, [%{"operation" => "request_rework"}])
    assert {:ok, %{receipts: [%{status: "OBSERVED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", historical)
    assert {:ok, ^staged} = TicketChatCommands.get(ctx.store, staged["command_key"])
  end

  test "indented commands are data; fresh project contradiction and failed staging are rejected", ctx do
    for {body, n} <- Enum.with_index(["    Rework the current candidate.", "\tRework the current candidate."], 1) do
      {:ok, staged} = stage(ctx, "indented-#{n}", body, [%{"operation" => "request_rework"}])
      readback = native(ctx, [body]) |> put_in(["turns", Access.at(0), "id"], "indent-turn-#{n}") |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "indent-client-#{n}")
      assert {:ok, _} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
      assert {:ok, %{"status" => "REJECTED", "receipt_json" => receipt}} = TicketChatCommands.get(ctx.store, staged["command_key"])
      assert receipt =~ "quoted_code_not_authorization"
    end

    {:ok, staged} = stage(ctx, "failed", "Rework the current candidate.", [%{"operation" => "request_rework"}])

    readback =
      native(ctx, ["Rework the current candidate."]) |> put_in(["turns", Access.at(0), "id"], "failed-turn") |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "failed-client")

    assert {:error, :native_input_route_mismatch} = TicketChatCommands.admit_readback(ctx.store, "run", %{readback | "projectId" => "other"})
    failed = put_in(readback, ["turns", Access.at(0), "items", Access.at(1), "exitCode"], 1)
    assert {:ok, %{receipts: [%{status: "OBSERVED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", failed)
    assert {:ok, ^staged} = TicketChatCommands.get(ctx.store, staged["command_key"])
  end

  test "staging is strict, bounded, idempotent and rejects self-supplied origin", ctx do
    assert {:error, :invalid_ticket_command} = TicketChatCommands.stage(ctx.store, "run", nil)
    assert {:error, :invalid_ticket_command} = TicketChatCommands.stage(ctx.store, "run", %{"origin" => "direct"})
    assert {:error, :invalid_ticket_question} = TicketChatCommands.open_question(ctx.store, "run", nil)
    assert {:error, :invalid_ticket_question} = TicketChatCommands.open_question(ctx.store, "run", %{})
    assert {:error, :invalid_ticket_question} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "bad", "body" => "Question", "answers" => nil})
    attrs = %{"question_key" => "Q", "body" => "Keep?", "answers" => %{"yes" => true}}
    assert {:ok, question} = TicketChatCommands.open_question(ctx.store, "run", attrs)
    assert {:ok, ^question} = TicketChatCommands.open_question(ctx.store, "run", attrs)
    assert {:error, :question_identity_conflict} = TicketChatCommands.open_question(ctx.store, "run", %{attrs | "body" => "different"})
    assert {:error, :unknown_ticket_command} = TicketChatCommands.get(ctx.store, "unknown")
    body = "Rework the current candidate."
    ops = [%{"operation" => "request_rework"}]
    assert {:ok, first} = stage(ctx, "same", body, ops)
    assert {:ok, ^first} = stage(ctx, "same", body, ops)
    assert {:error, :proposal_identity_conflict} = stage(ctx, "same", "changed", ops)
    assert {:error, :invalid_ticket_command} = stage(ctx, "bad-op", body, [%{"operation" => "deploy"}])
    for n <- 2..8, do: assert({:ok, _} = stage(ctx, "bounded-#{n}", body, ops))
    assert {:error, :pending_commands_limit} = stage(ctx, "excess", body, ops)
    Store.query!(ctx.store, "UPDATE ticket_chats SET thread_id = NULL")
    assert {:error, :ticket_parent_not_bound} = TicketChatCommands.collect(ctx.store, "run")
  end

  test "a crash after an answer update rolls back the application but retains accepted input", ctx do
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q", "body" => "Keep?", "answers" => %{"yes" => true}})
    ops = [%{"operation" => "answer_question", "question_key" => "Q", "value" => true}]
    body = "Answer Q: yes"
    {:ok, staged} = stage(ctx, "crash", body, ops)
    readback = native(ctx, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    Store.query!(ctx.store, "CREATE TRIGGER fail_receipt BEFORE UPDATE ON ticket_chat_commands WHEN NEW.status = 'APPLIED' BEGIN SELECT RAISE(ABORT, 'simulated crash'); END")
    accepted = TicketChatCommands.get(ctx.store, staged["command_key"]) |> elem(1)
    assert_raise Exqlite.Error, fn -> apply_command(ctx, accepted) end
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q'")["status"] == "OPEN"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_inputs")["count"] == 1
    assert {:ok, accepted_after} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert accepted_after["status"] == "ACCEPTED"
    assert accepted_after["receipt_json"] != nil
    Store.query!(ctx.store, "DROP TRIGGER fail_receipt")
    assert {:ok, applied} = apply_command(ctx, accepted_after)
    assert applied["status"] == "APPLIED"
  end

  test "an ignored question update rolls back the command application", ctx do
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q", "body" => "Keep?", "answers" => %{"yes" => true}})
    body = "Answer Q: yes"
    {:ok, staged} = stage(ctx, "ignored-answer-update", body, [%{"operation" => "answer_question", "question_key" => "Q", "value" => true}])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native(ctx, [body]))
    accepted = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])
    before = protected_amendment_state(ctx)
    Store.query!(ctx.store, "CREATE TRIGGER ignore_question_answer BEFORE UPDATE OF status ON ticket_chat_questions WHEN NEW.status = 'ANSWERED' BEGIN SELECT RAISE(IGNORE); END")

    assert {:error, :stale_question} = apply_command(ctx, accepted)

    Store.query!(ctx.store, "DROP TRIGGER ignore_question_answer")
    assert protected_amendment_state(ctx) == before
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = 'Q'") == %{"status" => "OPEN", "answer_json" => nil}
    assert {:ok, ^accepted} = TicketChatCommands.get(ctx.store, staged["command_key"])
  end

  test "an ignored APPLIED command update rolls back the answer and permits exact retry", ctx do
    accepted = accepted_answer(ctx, "ignored-command-application")
    before = protected_amendment_state(ctx)

    Store.query!(
      ctx.store,
      "CREATE TRIGGER ignore_command_applied BEFORE UPDATE OF status ON ticket_chat_commands WHEN NEW.command_key = '#{accepted["command_key"]}' AND NEW.status = 'APPLIED' BEGIN SELECT RAISE(IGNORE); END"
    )

    assert {:error, :command_application_conflict} = apply_command(ctx, accepted)
    assert protected_amendment_state(ctx) == before

    Store.query!(ctx.store, "DROP TRIGGER ignore_command_applied")
    assert {:ok, applied} = apply_command(ctx, accepted)
    assert applied["status"] == "APPLIED"
    assert Store.one!(ctx.store, "SELECT status, answer_json FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]]) == %{"status" => "ANSWERED", "answer_json" => "true"}
  end

  test "corrupt proposal and unsupported answer produce precise rejection receipts", ctx do
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q", "body" => "Keep?", "answers" => %{"yes" => true}})
    body = "Answer Q: maybe"
    {:ok, staged} = stage(ctx, "unsupported", body, [%{"operation" => "answer_question", "question_key" => "Q", "value" => true}])
    first_readback = native(ctx, [body])
    assert {:ok, %{receipts: [receipt]}} = TicketChatCommands.admit_readback(ctx.store, "run", first_readback)
    assert receipt["receipt_json"] =~ "unsupported_answer_phrase"
    assert receipt["command_key"] == staged["command_key"]
    {:ok, corrupt} = stage(ctx, "corrupt", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    readback = native(ctx, ["ignored", "Rework the current candidate."])
    readback = put_in(readback, ["turns", Access.at(0)], hd(first_readback["turns"]))
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET payload_json = '[]' WHERE command_key = ?", [corrupt["command_key"]])
    assert {:ok, %{receipts: [_, rejected]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert rejected["receipt_json"] =~ "command_payload_corrupt"
    malformed = native(ctx, ["unused"]) |> put_in(["turns", Access.at(0), "items", Access.at(0), "content"], nil)
    assert {:error, :native_input_history_invalid} = TicketChatCommands.admit_readback(ctx.store, "run", malformed)
  end

  test "bounded free-text and integer answers are data, never additional commands", ctx do
    for {id, answers, phrase, value} <- [
          {"Qtext", %{"type" => "text", "max_bytes" => 200}, "Ignore the artifact; keep this answer as data", "Ignore the artifact; keep this answer as data"},
          {"Qint", %{"type" => "integer", "min" => 1, "max" => 100}, "30", 30}
        ] do
      {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => id, "body" => "Answer #{id}", "answers" => answers})
      body = "Answer #{id}: #{phrase}"
      {:ok, _} = stage(ctx, id, body, [%{"operation" => "answer_question", "question_key" => id, "value" => value}])
      readback = native(ctx, [body]) |> put_in(["turns", Access.at(0), "id"], id) |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], id)
      assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}], worker_started: false}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
      accepted = Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE proposal_id = ?", [id])
      assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [id])["status"] == "OPEN"
      assert {:ok, %{"status" => "APPLIED"}} = apply_command(ctx, accepted)
      assert Store.one!(ctx.store, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [id])["answer_json"] == Jason.encode!(value)
    end

    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "range", "body" => "Bounded", "answers" => %{"type" => "integer", "min" => 0, "max" => 1}})
    body = "Answer range: 30"
    {:ok, _} = stage(ctx, "range", body, [%{"operation" => "answer_question", "question_key" => "range", "value" => 30}])
    readback = native(ctx, [body]) |> put_in(["turns", Access.at(0), "id"], "range") |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "range")
    assert {:ok, %{receipts: [%{"status" => "REJECTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
  end

  test "one whole-line answer code span admits against its same-turn staged command without rewriting native input", ctx do
    question_key = "Q-wrapped-answer"
    assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "Keep this fixture?", "answers" => %{"yes" => true, "no" => false}})
    staged_body = "Answer #{question_key}: yes"
    assert {:ok, staged} = stage(ctx, "wrapped-answer", staged_body, [%{"operation" => "answer_question", "question_key" => question_key, "value" => true}])
    raw_body = "`#{staged_body}`\n"

    readback =
      native(ctx, [staged_body], staged["command_key"])
      |> put_in(["turns", Access.at(0), "id"], "wrapped-answer-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "wrapped-answer-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "wrapped-answer-client")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "content", Access.at(0), "text"], raw_body)

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED", "input_key" => input_key}], worker_started: false}} =
             TicketChatCommands.admit_readback(ctx.store, "run", readback)

    input = Store.one!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [input_key])
    assert input["body"] == raw_body
    assert input["body_sha256"] == digest(raw_body)
    assert input["client_id"] == "wrapped-answer-client"
    assert input["readback_sha256"] == digest(Jason.encode!(readback))
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [question_key])["status"] == "OPEN"
    assert {:ok, %{"status" => "APPLIED"}} = apply_command(ctx, Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]]))
    assert Store.one!(ctx.store, "SELECT answer_json FROM ticket_chat_questions WHERE question_key = ?", [question_key])["answer_json"] == "true"
    assert {:ok, %{receipts: [%{"status" => "APPLIED", "input_key" => ^input_key}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert Store.one!(ctx.store, "SELECT body FROM ticket_chat_inputs WHERE input_key = ?", [input_key])["body"] == raw_body
  end

  test "answer-only code-span association rejects prose, changed intent, invalid receipts and wrapped rework", ctx do
    for {id, raw_body_kind, operation_kind, corrupt_receipt?} <- [
          {"quoted-prose", :quoted_prose, :answer, false},
          {"fence", :fence, :answer, false},
          {"multiline", :multiline, :answer, false},
          {"wrong-question", :wrong_question, :answer, false},
          {"wrong-value", :wrong_value, :answer, false},
          {"lone-backtick", :lone_backtick, :answer, false},
          {"receipt", :valid, :answer, true},
          {"mixed-operations", :valid, :answer_and_rework, false},
          {"wrapped-rework", :rework, :rework, false}
        ] do
      question_key = "Q-wrapped-#{id}"

      if operation_kind in [:answer, :answer_and_rework] do
        assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "Keep #{id}?", "answers" => %{"yes" => true, "no" => false}})
      end

      staged_body = if operation_kind == :rework, do: "Rework the current candidate.", else: "Answer #{question_key}: yes"

      operations =
        case operation_kind do
          :answer -> [%{"operation" => "answer_question", "question_key" => question_key, "value" => true}]
          :answer_and_rework -> [%{"operation" => "answer_question", "question_key" => question_key, "value" => true}, %{"operation" => "request_rework"}]
          :rework -> [%{"operation" => "request_rework"}]
        end

      assert {:ok, staged} = stage(ctx, "wrapped-#{id}", staged_body, operations)
      inner_body = if id == "wrong-question", do: "Answer Q-other: yes", else: if(id == "wrong-value", do: "Answer #{question_key}: no", else: staged_body)

      raw_body =
        case raw_body_kind do
          :quoted_prose -> "Please use `#{inner_body}`"
          :fence -> "```#{inner_body}```\n"
          :multiline -> "`#{inner_body}\nextra`\n"
          :lone_backtick -> " ` \n"
          _ -> "`#{inner_body}`\n"
        end

      readback =
        native(ctx, [staged_body], staged["command_key"])
        |> put_in(["turns", Access.at(0), "id"], "wrapped-#{id}-turn")
        |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "wrapped-#{id}-item")
        |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "wrapped-#{id}-client")
        |> put_in(["turns", Access.at(0), "items", Access.at(0), "content", Access.at(0), "text"], raw_body)

      readback =
        if corrupt_receipt? do
          put_in(
            readback,
            ["turns", Access.at(0), "items", Access.at(1), "aggregatedOutput"],
            Jason.encode!(%{"command_key" => staged["command_key"], "payload_sha256" => String.duplicate("0", 64), "status" => "PENDING"})
          )
        else
          readback
        end

      assert {:ok, %{receipts: [%{status: "OBSERVED", worker_started: false}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
      assert {:ok, unchanged} = TicketChatCommands.get(ctx.store, staged["command_key"])
      assert unchanged["status"] == "PENDING"
      assert unchanged["input_key"] == nil
      Store.query!(ctx.store, "DELETE FROM ticket_chat_commands WHERE command_key = ? AND status = 'PENDING'", [staged["command_key"]])
    end
  end

  test "a rejected native phrase-string answer is recovered once as its declared typed value", ctx do
    question_key = "Q-U11-chat-access"
    assert {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "May the controller use this chat?", "answers" => %{"yes" => true, "no" => false}})
    body = "Answer #{question_key}: yes"
    assert {:ok, staged} = stage(ctx, "u11-typed-answer", body, [%{"operation" => "answer_question", "question_key" => question_key, "value" => "yes"}])

    readback =
      native(ctx, [body], staged["command_key"])
      |> put_in(["turns", Access.at(0), "id"], "u11-typed-answer-turn")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "u11-typed-answer-item")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "u11-typed-answer-client")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "content", Access.at(0), "text"], "`#{body}`\n")

    assert {:ok, %{receipts: [%{"status" => "REJECTED", "receipt_json" => rejected_receipt}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert Jason.decode!(rejected_receipt)["reason"] == "native_intent_mismatch"
    original = TicketChatCommands.get(ctx.store, staged["command_key"]) |> elem(1)
    assert original["application_receipt_json"] == nil
    chat = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [original["chat_key"]])
    run = RunLedger.get(ctx.store, "run") |> elem(1)

    controller = %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run["spec_revision"], "contract_sha256" => run["contract_sha256"], "candidate_sha" => run["candidate_sha"]}
    }

    assert {:ok, receipt} = TicketChatCommands.recover_declared_answer(ctx.store, staged["command_key"], controller)
    assert receipt["kind"] == "DECLARED_ANSWER_RECOVERY"
    assert receipt["input_key"] == original["input_key"]
    assert {:ok, ^receipt} = TicketChatCommands.recover_declared_answer(ctx.store, staged["command_key"], controller)
    assert {:error, :answer_recovery_replay_unproven} = TicketChatCommands.recover_declared_answer(ctx.store, staged["command_key"], Map.put(controller, "run_id", "other"))
    assert TicketChatCommands.get(ctx.store, staged["command_key"]) == {:ok, original}

    assert Store.one!(ctx.store, "SELECT status, answer_json, input_key FROM ticket_chat_questions WHERE question_key = ?", [question_key]) == %{
             "status" => "ANSWERED",
             "answer_json" => "true",
             "input_key" => original["input_key"]
           }

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_answer_recoveries WHERE predecessor_command_key = ?", [staged["command_key"]])["count"] == 1
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'TICKET_ANSWER_RECOVERED' AND run_id = 'run'")["count"] == 1

    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    {:ok, advanced_run} = RunLedger.get(ctx.store, "run")

    advanced_controller = %{
      controller
      | "binding" => %{
          "generation" => chat["generation"],
          "spec_revision" => advanced_run["spec_revision"],
          "contract_sha256" => advanced_run["contract_sha256"],
          "candidate_sha" => advanced_run["candidate_sha"]
        }
    }

    assert {:ok, ^receipt} = TicketChatCommands.recover_declared_answer(ctx.store, staged["command_key"], advanced_controller)

    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET answer_json = 'false' WHERE question_key = ?", [question_key])
    Store.query!(ctx.store, "UPDATE ticket_chat_answer_recoveries SET answer_json = 'false' WHERE predecessor_command_key = ?", [staged["command_key"]])
    assert {:error, :answer_recovery_replay_unproven} = TicketChatCommands.recover_declared_answer(ctx.store, staged["command_key"], advanced_controller)
  end

  test "a question digest prevents changed wording from consuming an earlier answer", ctx do
    attrs = %{"question_key" => "Q", "body" => "Keep candidate?", "answers" => %{"yes" => true}}
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", attrs)
    body = "Answer Q: yes"
    {:ok, _} = stage(ctx, "digest", body, [%{"operation" => "answer_question", "question_key" => "Q", "value" => true}])
    readback = native(ctx, [body])
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET body = 'Different question?' WHERE question_key = 'Q'")
    assert {:ok, %{receipts: [%{"status" => "REJECTED", "receipt_json" => receipt}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    assert receipt =~ "native_intent_mismatch"
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = 'Q'")["status"] == "OPEN"
    assert {:error, :question_not_in_ticket} = stage(ctx, "unknown", "yes", [%{"operation" => "answer_question", "question_key" => "missing", "value" => true}])
    Store.query!(ctx.store, "UPDATE ticket_chat_questions SET binding_json = '{}' WHERE question_key = 'Q'")
    assert {:error, :stale_question} = stage(ctx, "stale", "yes", [%{"operation" => "answer_question", "question_key" => "Q", "value" => true}])
  end

  test "copied output, shell chains and mismatched arguments are not successful staging", ctx do
    body = "Rework the current candidate."
    {:ok, staged} = stage(ctx, "invocation", body, [%{"operation" => "request_rework"}])
    valid = native(ctx, [body])
    command = get_in(valid, ["turns", Access.at(0), "items", Access.at(1), "command"])

    for altered <- [
          "printf copied-output",
          "printf copied-output # factory.ticket stage ",
          command <> "; true",
          String.replace(command, "stage run", "stage other"),
          "mix factory.ticket stage run --payload-base64 invalid --workflow /tmp/WORKFLOW.md",
          "/bin/zsh -lc '#{String.replace(command, "#{ctx.root}/WORKFLOW.md", "#{ctx.root}/$X/WORKFLOW.md")}'",
          "/bin/zsh -lc 'printf copied-output; #{command}'",
          "/bin/zsh -lc 'printf #{<<96>>}copied-output#{<<96>>}; #{command}'",
          "'unterminated"
        ] do
      changed = put_in(valid, ["turns", Access.at(0), "items", Access.at(1), "command"], altered)
      # Each failed observation is isolated so the native edit check does not mask invocation validation.
      Store.query!(ctx.store, "DELETE FROM ticket_chat_inputs")
      assert {:ok, %{receipts: [%{status: "OBSERVED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", changed)
      assert {:ok, ^staged} = TicketChatCommands.get(ctx.store, staged["command_key"])
    end

    Store.query!(ctx.store, "DELETE FROM ticket_chat_inputs")
    wrapped = put_in(valid, ["turns", Access.at(0), "items", Access.at(1), "command"], "/bin/zsh -lc '#{command}'")
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", wrapped)
  end

  defp apply_command(ctx, command) do
    {:ok, run} = RunLedger.get(ctx.store, "run")
    chat = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])

    TicketChatCommands.apply_accepted(ctx.store, command["command_key"], %{
      "chat_key" => chat["chat_key"],
      "run_id" => "run",
      "binding" => %{"generation" => chat["generation"], "spec_revision" => run["spec_revision"], "contract_sha256" => run["contract_sha256"], "candidate_sha" => run["candidate_sha"]}
    })
  end

  defp accepted_answer(ctx, proposal) do
    question_key = "Q-" <> proposal
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => question_key, "body" => "Keep?", "answers" => %{"yes" => true}})
    body = "Answer #{question_key}: yes"
    {:ok, staged} = stage(ctx, proposal, body, [%{"operation" => "answer_question", "question_key" => question_key, "value" => true}])

    readback =
      native(ctx, [body])
      |> put_in(["turns", Access.at(0), "id"], "turn-#{proposal}")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "item-#{proposal}")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "client-#{proposal}")

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]]) |> Map.put("test_question_key", question_key)
  end

  defp accepted_amendment(ctx, proposal, markdown) do
    ensure_normalized_snapshot(ctx)
    body = "Revise the contract:\n" <> markdown
    {:ok, staged} = stage(ctx, proposal, body, [%{"operation" => "propose_contract_revision", "markdown" => markdown}])

    readback =
      native(ctx, [body])
      |> put_in(["turns", Access.at(0), "id"], "turn-#{proposal}")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "id"], "item-#{proposal}")
      |> put_in(["turns", Access.at(0), "items", Access.at(0), "clientId"], "client-#{proposal}")

    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", readback)
    {:ok, Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])}
  end

  defp amendment_context(ctx, run \\ nil) do
    run = run || elem(RunLedger.get(ctx.store, "run"), 1)
    chat = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])

    %{
      "chat_key" => chat["chat_key"],
      "run_id" => run["run_id"],
      "binding" => %{
        "generation" => chat["generation"],
        "spec_revision" => run["spec_revision"],
        "contract_sha256" => run["contract_sha256"],
        "candidate_sha" => run["candidate_sha"]
      }
    }
  end

  defp critic_model_policy do
    %{
      "default_provider" => "openai",
      "providers" => %{"openai" => %{"standard" => "critic-model-v1"}},
      "roles" => %{
        "specification-critic" => %{
          "provider" => "openai",
          "model_class" => "standard",
          "reasoning_effort" => "high"
        }
      }
    }
  end

  defp prepare_draft(ctx, command, context) do
    run = Store.one!(ctx.store, "SELECT snapshot_json FROM runs WHERE run_id = 'run'")
    snapshot = Jason.decode!(run["snapshot_json"])
    {:ok, amendment} = TicketContractAmendment.get(ctx.store, command["command_key"])
    body = Contract.draft_comment(Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"]))
    Process.put(:ticket_amendment_snapshot, snapshot)
    Process.put(:ticket_amendment_body, body)
    workspace = Path.join(ctx.root, "control")
    File.mkdir_p!(workspace)

    TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context,
      workspace: workspace,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "amendment-jira"}) end,
      jira_reader: JiraReader,
      jira_connector: JiraConnector
    )
  end

  defp ensure_normalized_snapshot(ctx) do
    run = Store.one!(ctx.store, "SELECT snapshot_json FROM runs WHERE run_id = 'run'")
    snapshot = Jason.decode!(run["snapshot_json"])

    unless Map.has_key?(snapshot, "summary") do
      normalized =
        snapshot
        |> Map.merge(%{
          "summary" => "Existing summary",
          "description" => "Existing description",
          "status" => "In Progress",
          "labels" => ["ai-ready"],
          "assignee" => nil,
          "project_key" => "PPL",
          "parent_key" => nil,
          "components" => [],
          "url" => "https://jira.example/PPL-123",
          "updated" => "2026-10-07T12:00:00Z"
        })
        |> Map.update!("comments", &assign_old_comment_ids/1)

      Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run'", [Jason.encode!(normalized)])
    end
  end

  defp assign_old_comment_ids(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} -> Map.put_new(comment, "id", "old-comment-#{index}") end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp protected_amendment_state(ctx) do
    %{
      run: Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'"),
      chat: Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]]),
      links: Store.query!(ctx.store, "SELECT * FROM ticket_chat_runs WHERE chat_key = ? ORDER BY run_id", [ctx.chat["chat_key"]]).rows,
      commands: Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
      questions: Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows,
      inputs: Store.query!(ctx.store, "SELECT * FROM ticket_chat_inputs WHERE chat_key = ? ORDER BY input_key", [ctx.chat["chat_key"]]).rows,
      events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows,
      requests: Store.query!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' ORDER BY request_key").rows,
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      evidence: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
      access: Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows
    }
  end

  defp assert_post_admission_stale_rejection(ctx, accepted) do
    assert {:ok, rejected} = apply_command(ctx, accepted)
    assert rejected["status"] == "REJECTED"
    assert rejected["receipt_json"] == accepted["receipt_json"]
    assert rejected["application_receipt_json"] != nil
    assert Store.one!(ctx.store, "SELECT status FROM ticket_chat_questions WHERE question_key = ?", [accepted["test_question_key"]])["status"] == "OPEN"
    assert {:ok, ^rejected} = apply_command(ctx, rejected)
  end
end
