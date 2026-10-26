defmodule SymphonyElixir.FactoryTicketChatOutboxTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture

  alias SymphonyElixir.Factory.{
    DesktopRequest,
    DesktopToolArgs,
    RunLedger,
    Store,
    TicketChat,
    TicketChatOutbox,
    TicketContext,
    TicketContextReader
  }

  @broker "019fa5b7-27fa-7660-ab47-7c3abb867c91"

  defmodule NativeReader do
    def read_native_thread(_thread_id, _opts), do: {:ok, Process.get(:negative_presentation_native)}
  end

  setup context do
    ctx = setup_fixture(context, broker_thread_id: @broker)
    runtime_fixture(ctx.root)
    ctx
  end

  test "presentation fingerprint preserves values but ignores JSON map representation" do
    material = %{run: %{state: "PUSHING", candidate_sha: "exact"}, results: [%{status: "PASS", required: false}], question: nil}
    json_material = material |> Jason.encode!() |> Jason.decode!()

    assert TicketChatOutbox.presentation_fingerprint(material) ==
             TicketChatOutbox.presentation_fingerprint(json_material)

    refute TicketChatOutbox.presentation_fingerprint(material) ==
             TicketChatOutbox.presentation_fingerprint(put_in(material, [:run, :state], "FAILED"))

    refute TicketChatOutbox.presentation_fingerprint(%{value: []}) ==
             TicketChatOutbox.presentation_fingerprint(%{value: %{}})

    refute TicketChatOutbox.presentation_fingerprint(%{value: false}) ==
             TicketChatOutbox.presentation_fingerprint(%{value: "false"})

    refute TicketChatOutbox.presentation_fingerprint(%{value: [1, 2]}) ==
             TicketChatOutbox.presentation_fingerprint(%{value: [2, 1]})
  end

  test "only material changes enqueue; unclaimed summaries are superseded without rewriting hashes", ctx do
    {:ok, run} = RunLedger.get(ctx.store, "run")
    assert {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    assert {:ok, original} = DesktopRequest.get(ctx.store, first.request_key)
    assert original["prompt"] =~ "Controller-observed AS-OF presentation only; not human input or source authority"
    assert original["prompt"] =~ "do not refresh, call tools, stage, or perform source"
    assert original["prompt"] =~ "Controller-observed AS-OF presentation only"
    assert original["prompt"] =~ "do not claim it is current at render time or claim a parent refresh"
    assert original["prompt"] =~ "Treat omitted or missing artifact facts as unknown"
    assert original["prompt"] =~ "latest included worker result, recorded verifier status"
    assert original["prompt"] =~ "End once; do not refresh, call tools, stage"
    assert original["prompt"] =~ "Acknowledgment means only that this presentation was received"
    assert original["prompt"] =~ "Future-direct-human-input protocol only, not an action for this presentation"
    assert original["prompt"] =~ TicketContextReader.staging_protocol()
    assert original["prompt"] =~ "Do not restage, repair, or apply any previous input or pending command in this turn"
    refute original["prompt"] =~ "exec_command"
    refute original["prompt"] =~ "Refresh durable context"
    snapshot = snapshot_from_request(original)
    assert snapshot["observed_at"] =~ ~r/\A\d{4}-\d{2}-\d{2}T/
    assert snapshot["run_id"] == "run"
    assert snapshot["spec_revision"] == 1
    assert snapshot["candidate_sha"] == String.duplicate("a", 40)
    assert snapshot["material_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert snapshot["snapshot"]["run"]["run_id"] == "run"
    {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    {:ok, bootstrap} = DesktopRequest.get(ctx.store, chat["create_request_key"])
    policy = %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}
    assert :ok = TicketChat.authorize_issuance(ctx.store, original, policy)
    Store.query!(ctx.store, "UPDATE desktop_requests SET output_json = ? WHERE request_key = ?", [Jason.encode!(%{"result" => %{"acknowledged" => false}}), bootstrap["request_key"]])
    assert {:error, :ticket_chat_parent_not_ready} = TicketChat.authorize_issuance(ctx.store, original, policy)
    assert {:ok, ^original} = DesktopRequest.get(ctx.store, first.request_key)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET output_json = ? WHERE request_key = ?", [bootstrap["output_json"], bootstrap["request_key"]])
    assert :ok = TicketChat.authorize_issuance(ctx.store, original, policy)
    assert {:ok, %{status: "UNCHANGED", model_invoked: false}} = TicketChatOutbox.publish(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE runs SET updated_at = 'another time' WHERE run_id = 'run'")
    assert {:ok, %{status: "UNCHANGED", model_invoked: false}} = TicketChatOutbox.publish(ctx.store, "run")
    assert {:ok, unchanged_request} = DesktopRequest.get(ctx.store, first.request_key)
    assert unchanged_request["prompt"] == original["prompt"]
    assert snapshot_from_request(unchanged_request)["observed_at"] == snapshot["observed_at"]
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' AND action = 'FOLLOWUP'")["count"] == 1
    Store.query!(ctx.store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('DECISION_RECORDED', 'run', '{\"decision\":\"keep\"}', '2026-10-03')")
    assert {:ok, second} = TicketChatOutbox.publish(ctx.store, "run")
    assert second.request_key != first.request_key
    assert {:ok, old} = DesktopRequest.get(ctx.store, first.request_key)
    assert old["status"] == "SUPERSEDED"
    assert old["superseded_by"] == second.request_key
    assert old["payload_sha256"] == original["payload_sha256"] and old["prompt"] == original["prompt"]
    assert DesktopRequest.payload_intact?(old)
    assert {:ok, after_publish} = RunLedger.get(ctx.store, "run")
    assert Map.delete(run, "updated_at") == Map.delete(after_publish, "updated_at")
    assert {:error, :ticket_chat_runtime_not_integrated} = DesktopRequest.claim(ctx.store, second.request_key)
    assert {:ok, %{request: %{"status" => "PENDING"}, delivery_unchanged: true}} = TicketChatOutbox.synchronization(ctx.store, "run")
  end

  test "immutable presentation does not weaken direct human context-reader instructions", ctx do
    workflow = Path.join(ctx.root, "Workflow with spaces µ 'quoted'.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\n")
    assert {:ok, locator} = TicketContextReader.bind(ctx.store, "run", ticket_cli_root: File.cwd!(), ticket_workflow: workflow)
    reader = Jason.decode!(locator)
    assert OptionParser.split(reader["command"]) == ["./scripts/factory-broker", "ticket", "context", "run", "--workflow", workflow]
    raw = "./scripts/factory-broker ticket context run --workflow #{workflow}"
    refute reader["command"] == raw
    malformed = locator |> Jason.decode!() |> Map.put("command", raw) |> Jason.encode!()
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.execution_locator(malformed)
    assert TicketContextReader.instructions(malformed) == TicketContextReader.instructions(nil)

    instructions = TicketContextReader.instructions(locator)

    assert instructions =~ "For each direct human message, run it successfully in that same turn before staging"
    assert instructions =~ "only an explicit command from that direct human message"
    assert instructions =~ "For one explicit answer, operations must contain exactly one object with operation `answer_question`"
    assert instructions =~ "exactly one `propose_contract_revision` operation"
    assert instructions =~ "exactly one `request_rework` operation and no other operation"
    assert instructions =~ "Staging records a PENDING proposal only; do not apply it"
  end

  test "legacy material-only fingerprint refreshes instructions once without changing delivery", ctx do
    {:ok, run_before} = RunLedger.get(ctx.store, "run")
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, original} = DesktopRequest.get(ctx.store, first.request_key)
    {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    {:ok, packet} = TicketContext.context(ctx.store, "run")
    {:ok, material} = TicketContext.presentation_data(ctx.store, chat["chat_key"], packet)
    legacy = TicketChatOutbox.presentation_fingerprint(material)
    Store.query!(ctx.store, "UPDATE ticket_chats SET presentation_sha256 = ? WHERE chat_key = ?", [legacy, chat["chat_key"]])

    assert {:ok, %{status: "PENDING", request_key: refreshed_key}} = TicketChatOutbox.publish(ctx.store, "run")
    refute refreshed_key == first.request_key
    assert {:ok, refreshed} = DesktopRequest.get(ctx.store, refreshed_key)
    assert refreshed["prompt"] =~ TicketContextReader.staging_protocol()
    assert {:ok, old} = DesktopRequest.get(ctx.store, first.request_key)
    assert old["status"] == "SUPERSEDED"
    assert old["prompt"] == original["prompt"]
    assert old["payload_sha256"] == original["payload_sha256"]
    assert DesktopRequest.payload_intact?(old)
    assert {:ok, %{status: "UNCHANGED", model_invoked: false}} = TicketChatOutbox.publish(ctx.store, "run")
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
  end

  test "claimed or uncertain summaries remain immutable and failure does not fail delivery", ctx do
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, original} = DesktopRequest.get(ctx.store, first.request_key)
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN', claimed_at = 'now' WHERE request_key = ?", [first.request_key])
    Store.query!(ctx.store, "UPDATE runs SET state = 'VERIFYING' WHERE run_id = 'run'")
    assert {:ok, %{status: "SYNC_LAG", request_key: key}} = TicketChatOutbox.publish(ctx.store, "run")
    assert key == first.request_key
    assert {:ok, uncertain} = DesktopRequest.get(ctx.store, key)
    assert uncertain["prompt"] == original["prompt"]
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED', failure_code = 'MESSAGE_FAILED' WHERE request_key = ?", [key])
    assert {:ok, %{request: %{"status" => "FAILED"}}} = TicketChatOutbox.synchronization(ctx.store, "run")
    assert {:ok, %{"state" => "VERIFYING"}} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{status: "PENDING"}} = TicketChatOutbox.publish(ctx.store, "run")
  end

  test "a completed negative acknowledgment fails only its exact presentation and replays without changing source", ctx do
    {:ok, run_before} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{request_key: key}} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, request} = DesktopRequest.get(ctx.store, key)
    {:ok, chat} = TicketChat.get(ctx.store, request["target_key"])
    broker = @broker
    assert {:ok, _} = claim_followup(ctx, key)
    assert {:ok, stopped} = DesktopRequest.fail(ctx.store, key, "NATIVE_PRESENTATION_REFRESH_LOOP_STOPPED")
    assert stopped["failure_code"] == "NATIVE_PRESENTATION_REFRESH_LOOP_STOPPED"
    {:ok, claimed} = DesktopRequest.get(ctx.store, key)
    {:ok, arguments} = DesktopToolArgs.followup(claimed)

    proof = %{
      "request_key" => key,
      "payload_sha256" => claimed["payload_sha256"],
      "generation" => chat["generation"],
      "thread_id" => "parent",
      "project_id" => nil,
      "cwd" => chat["cwd"],
      "tool_arguments" => arguments,
      "worktree_attachments" => []
    }

    now = System.system_time(:second)

    native = %{
      "id" => "parent",
      "cwd" => chat["cwd"],
      "projectId" => nil,
      "updatedAt" => now,
      "history_observation" => %{"mode" => "PAGED_FULL", "next_cursor" => nil, "turn_count" => 1, "updated_at" => now},
      "turns" => [
        %{
          "id" => "negative-turn",
          "status" => "completed",
          "startedAt" => now + 2,
          "completedAt" => now + 3,
          "items" => [
            %{
              "id" => "call-output",
              "type" => "functionCallOutput",
              "namespace" => "codex_app",
              "name" => "send_message_to_thread",
              "output" => "<codex_delegation>\n  <source_thread_id>#{broker}</source_thread_id>\n  <input>#{claimed["prompt"]}</input>\n</codex_delegation>"
            },
            %{"id" => "answer", "type" => "agentMessage", "phase" => "final_answer", "text" => "{\"acknowledged\":false}"}
          ]
        }
      ]
    }

    Process.put(:negative_presentation_native, native)
    assert {:ok, native_receipt} = TicketChat.observe_native_turn(ctx.store, key, broker, native)
    typed_proof = Map.put(proof, "native_readback_sha256", native_receipt["readback_sha256"])
    assert {:ok, recorded} = DesktopRequest.record_ticket_thread(ctx.store, key, typed_proof)
    assert recorded["failure_code"] == "NATIVE_PRESENTATION_REFRESH_LOOP_STOPPED"
    assert recorded["status"] == "THREAD_RECORDED" and is_binary(recorded["claimed_at"])
    assert is_nil(recorded["turn_id"]) and is_nil(recorded["output_json"])
    assert DesktopRequest.payload_intact?(recorded)
    assert :ok = TicketChat.validate_request(ctx.store, recorded)
    assert {:ok, current_chat} = TicketChat.get(ctx.store, recorded["target_key"])
    assert current_chat["presentation_request_key"] == key
    assert {:ok, failed} = DesktopRequest.reconcile_negative_ticket_chat_presentation(ctx.store, key, "parent", broker, reader: NativeReader)
    assert failed["status"] == "FAILED"
    assert failed["failure_code"] == "TICKET_CHAT_PRESENTATION_NOT_ACKNOWLEDGED"
    assert failed["turn_id"] == "negative-turn"
    assert Jason.decode!(failed["output_json"])["result"] == %{"acknowledged" => false}
    assert {:ok, ^run_before} = RunLedger.get(ctx.store, "run")
    assert {:error, :ticket_chat_request_already_issued} = claim_followup(ctx, key)
    Store.query!(ctx.store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('DECISION_RECORDED', 'run', '{\"decision\":\"keep\"}', '2026-10-10')")
    assert {:ok, %{status: "PENDING", request_key: replacement}} = TicketChatOutbox.publish(ctx.store, "run")
    assert replacement != key
    original_observation = Jason.decode!(failed["target_observation_json"])
    changed_hash = Map.put(original_observation, "native_readback_sha256", String.duplicate("0", 64))
    Store.query!(ctx.store, "UPDATE desktop_requests SET target_observation_json = ? WHERE request_key = ?", [Jason.encode!(changed_hash), key])
    assert {:error, :ticket_chat_negative_presentation_replay_unproven} = DesktopRequest.reconcile_negative_ticket_chat_presentation(ctx.store, key, "parent", broker, reader: NativeReader)
    removed_hash = Map.delete(original_observation, "native_readback_sha256")
    Store.query!(ctx.store, "UPDATE desktop_requests SET target_observation_json = ? WHERE request_key = ?", [Jason.encode!(removed_hash), key])
    assert {:error, :ticket_chat_negative_presentation_replay_unproven} = DesktopRequest.reconcile_negative_ticket_chat_presentation(ctx.store, key, "parent", broker, reader: NativeReader)
    Store.query!(ctx.store, "UPDATE desktop_requests SET target_observation_json = ? WHERE request_key = ?", [failed["target_observation_json"], key])
    assert {:ok, ^failed} = DesktopRequest.reconcile_negative_ticket_chat_presentation(ctx.store, key, "parent", broker, reader: NativeReader)
    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, key)
    assert unchanged == failed
  after
    Process.delete(:negative_presentation_native)
  end

  test "an unrelated pending acknowledgment cannot be superseded", ctx do
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE request_key = ?", [first.request_key])
    Store.query!(ctx.store, "UPDATE ticket_chats SET presentation_request_key = NULL, presentation_sha256 = NULL")
    {:ok, old} = DesktopRequest.get(ctx.store, first.request_key)
    attrs = Map.take(old, ~w(target_kind target_key action codex_project_id model reasoning_effort existing_thread_id title prompt cwd))

    {:ok, request} =
      DesktopRequest.enqueue(ctx.store, Map.merge(attrs, %{"request_key" => "question-ack", "schema" => Jason.decode!(old["schema_json"]), "metadata" => Jason.decode!(old["metadata_json"])}))

    assert {:ok, %{status: "SYNC_LAG", request_key: "question-ack"}} = TicketChatOutbox.publish(ctx.store, "run")
    assert {:ok, ^request} = DesktopRequest.get(ctx.store, "question-ack")
  end

  test "a failed replacement rolls back supersession and its sequence; restart preserves one request", ctx do
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, original} = DesktopRequest.get(ctx.store, first.request_key)
    Store.query!(ctx.store, "UPDATE runs SET state = 'VERIFYING' WHERE run_id = 'run'")
    Store.query!(ctx.store, "CREATE TRIGGER fail_replacement BEFORE INSERT ON desktop_requests BEGIN SELECT RAISE(ABORT, 'replacement failed'); END")
    assert_raise Exqlite.Error, fn -> TicketChatOutbox.publish(ctx.store, "run") end
    assert {:ok, ^original} = DesktopRequest.get(ctx.store, first.request_key)
    assert {:ok, %{sequence: 1}} = TicketChatOutbox.synchronization(ctx.store, "run")
    Store.query!(ctx.store, "DROP TRIGGER fail_replacement")
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})
    assert {:ok, %{status: "PENDING"}} = TicketChatOutbox.publish(reopened, "run")
    assert {:ok, %{status: "UNCHANGED"}} = TicketChatOutbox.publish(reopened, "run")
    assert {:error, :unknown_ticket_chat} = TicketChatOutbox.publish(reopened, "unknown")
  end

  test "timestamp-only ledger updates and identical CI WAIT readbacks never wake the parent", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_evidence_json: Jason.encode!(%{status: "WAIT", sha: String.duplicate("a", 40), pipeline: %{id: 42, status: "pending", updated_at: "first"}})})
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")

    for n <- 1..12 do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_last_checked_at: "poll-#{n}"})
      assert {:ok, %{status: "UNCHANGED", model_invoked: false}} = TicketChatOutbox.publish(ctx.store, "run")
    end

    {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_evidence_json: Jason.encode!(%{status: "WAIT", sha: String.duplicate("a", 40), pipeline: %{id: 42, status: "pending", updated_at: "second"}})})
    assert {:ok, %{status: "UNCHANGED"}} = TicketChatOutbox.publish(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED', failure_code = 'MESSAGE_FAILED' WHERE request_key = ?", [first.request_key])
    assert {:ok, %{status: "SYNC_FAILED", failure_code: "MESSAGE_FAILED", model_invoked: false}} = TicketChatOutbox.publish(ctx.store, "run")
  end

  test "a changed blocker in the same run state is material, without unbounded inline errors", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "FAILED", failure_code: "FIRST", last_error: "First failure"})
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, _} = RunLedger.update(ctx.store, "run", %{failure_code: "NEW_BLOCKER", last_error: String.duplicate("actionable ", 5000)})
    assert {:ok, %{status: "PENDING", request_key: key}} = TicketChatOutbox.publish(ctx.store, "run")
    assert key != first.request_key
    assert {:ok, %{status: "UNCHANGED"}} = TicketChatOutbox.publish(ctx.store, "run")
  end

  defp snapshot_from_request(request) do
    request["prompt"] |> String.split("\n") |> List.last() |> Jason.decode!()
  end
end
