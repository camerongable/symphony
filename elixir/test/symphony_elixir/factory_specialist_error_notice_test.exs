defmodule SymphonyElixir.FactorySpecialistErrorNoticeTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture

  alias SymphonyElixir.Factory.{
    DesktopRequest,
    SpecialistErrorNotice,
    Store,
    TaskLedger,
    TicketChat,
    TicketChatOutbox,
    TicketParentEvidence
  }

  @broker "019fa5b7-27fa-7660-ab47-7c3abb867c91"

  setup :setup_fixture

  test "durable errors require visible final notices and survive uncertain parent presentations", ctx do
    payload = %{
      "notice_id" => "error-one",
      "request_key" => "writer-attempt",
      "task_key" => "run:feature-writer",
      "role" => "feature-writer",
      "stage" => "WRITING",
      "thread_id" => "writer",
      "turn_id" => "failed-turn",
      "category" => "PROVIDER_CAPACITY",
      "cause" => "The selected model is at capacity.",
      "ownership" => "Owner shutdown is not proven; no new writer is authorized.",
      "preserved_work" => "Existing candidate and partial file edits are preserved; this is not a completed slice.",
      "next_action" => "The controller must reconcile this exact attempt before retrying."
    }

    Store.query!(ctx.store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('SPECIALIST_ERROR_RECORDED', 'run', ?, ?)", [
      Jason.encode!(payload),
      DateTime.to_iso8601(DateTime.utc_now())
    ])

    assert {:ok, %{request_key: key}} = TicketChatOutbox.publish(ctx.store, "run")
    request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE request_key = ?", [key])
    assert request["prompt"] =~ "Post the following exact user-facing final answer"
    assert request["prompt"] =~ "selected model is at capacity"
    metadata = Jason.decode!(request["metadata_json"])
    assert metadata["specialist_notice_ids"] == ["error-one"]
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN' WHERE request_key = ?", [key])
    Store.query!(ctx.store, "UPDATE runs SET implementation_iteration = 3 WHERE run_id = 'run'")
    assert {:ok, %{status: "SYNC_LAG", request_key: ^key}} = TicketChatOutbox.publish(ctx.store, "run")
    assert {:ok, []} = SpecialistErrorNotice.pending(ctx.store, "run")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'SPECIALIST_ERROR_QUEUED'")["count"] == 1
  end

  test "all specialist roles persist deduplicated safe diagnostics across a ledger reopen", ctx do
    for {role, error} <- [
          {"specification-author", :permission_denied},
          {"specification-critic", :worker_timeout},
          {"feature-planner", :invalid_output},
          {"feature-writer", {:worker_turn_error, %{"codexErrorInfo" => "serverOverloaded", "secret" => "never-visible"}}},
          {"change-verifier", :tool_transport_error},
          {"manual-validator", :native_error}
        ] do
      key = "run:" <> role

      {:ok, _} =
        TaskLedger.register(ctx.store, %{
          task_key: key,
          run_id: "run",
          stage: "WRITING",
          role: role,
          status: "STALE",
          model_provider: "codex",
          model_class: "fast",
          model: "gpt-6-luna",
          reasoning_effort: "low",
          routing_reason: "fixture",
          prompt_sha256: String.duplicate("a", 64)
        })

      {:ok, first} = SpecialistErrorNotice.record_task(ctx.store, key, role <> "-attempt", error)
      {:ok, again} = SpecialistErrorNotice.record_task(ctx.store, key, role <> "-attempt", error)
      assert first == again
      refute Jason.encode!(SpecialistErrorNotice.metadata([first])) =~ "never-visible"
      assert first["binding_sha256"] != nil
    end

    reopened = start_supervised!({Store, database: ctx.database}, id: :reopened_notice_store)
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'SPECIALIST_ERROR_RECORDED'")["count"] == 6
    assert {:ok, [_]} = SpecialistErrorNotice.pending(reopened, "run")
  end

  test "notice completion requires exact visible final readback and rejects ACK-only", ctx do
    notice = seed_notice(ctx)
    assert {:ok, %{request_key: key}} = TicketChatOutbox.publish(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN', claimed_at = ? WHERE request_key = ?", [DateTime.to_iso8601(DateTime.utc_now()), key])
    {:ok, request} = DesktopRequest.get(ctx.store, key)
    text = SpecialistErrorNotice.metadata([notice])["specialist_notice_text"]
    native = notice_native(ctx, request, text <> "\n{\"acknowledged\":true}")
    assert {:ok, receipt} = TicketParentEvidence.observe(request, @broker, native)
    assert {:ok, completion} = TicketParentEvidence.completion(native, receipt)
    assert :ok = SpecialistErrorNotice.validate_render(Jason.decode!(request["metadata_json"]), completion["output"], receipt["readback_sha256"])
    ack_only = notice_native(ctx, request, "{\"acknowledged\":true}")
    assert {:error, :specialist_notice_render_unproven} = TicketParentEvidence.observe(request, @broker, ack_only)

    assert {:error, :specialist_notice_render_unproven} =
             SpecialistErrorNotice.validate_render(Jason.decode!(request["metadata_json"]), %{"result" => %{"acknowledged" => true}}, receipt["readback_sha256"])

    forged = request |> Map.put("metadata_json", Jason.encode!(Map.put(Jason.decode!(request["metadata_json"]), "specialist_notice_text", "wrong")))
    assert {:error, :ticket_chat_binding_mismatch} = TicketChat.validate_request(ctx.store, forged)
    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'FAILED', failure_code = 'READBACK_FAILED' WHERE request_key = ?", [key])
    assert {:ok, %{status: "SYNC_FAILED", blocker: "SPECIALIST_NOTICE_READBACK_REQUIRED"}} = TicketChatOutbox.publish(ctx.store, "run")
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events WHERE event_type = 'SPECIALIST_ERROR_QUEUED'")["count"] == 1
  end

  test "in-turn provider and tool errors are exact-bound, deduplicated and do not stop the specialist", ctx do
    seed_notice(ctx)
    at = DateTime.to_iso8601(DateTime.utc_now())

    Store.query!(
      ctx.store,
      "INSERT INTO workspace_access(reservation_key, run_id, task_key, request_key, mode, generation, canonical_path, git_dir, common_dir, binding_json, acquired_at) VALUES ('access', 'run', 'run:planner', 'attempt', 'REVIEW', 1, ?, ?, ?, '{}', ?)",
      [ctx.root, ctx.root <> "/.git", ctx.root <> "/.git", at]
    )

    Store.query!(
      ctx.store,
      "INSERT INTO worker_evidence(request_key,task_key,run_id,reservation_key,binding_json,binding_sha256,status,thread_id,turn_id,owner_id,created_at) VALUES ('attempt','run:planner','run','access','{}',?,'TURN_BOUND','specialist','exact-turn','owner',?)",
      [String.duplicate("b", 64), at]
    )

    provider = %{
      event: :notification,
      payload: %{"method" => "error", "params" => %{"threadId" => "specialist", "turnId" => "exact-turn", "error" => %{"codexErrorInfo" => "serverOverloaded", "raw" => "private"}}}
    }

    tool = %{
      event: :notification,
      payload: %{
        "method" => "item/completed",
        "params" => %{"threadId" => "specialist", "turnId" => "exact-turn", "item" => %{"id" => "call-one", "type" => "dynamicToolCall", "success" => false, "arguments" => %{"secret" => "private"}}}
      }
    }

    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", provider)
    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", provider)
    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", tool)

    dynamic = %{
      event: :tool_call_failed,
      payload: %{
        "id" => 42,
        "method" => "item/tool/call",
        "params" => %{"threadId" => "specialist", "turnId" => "exact-turn", "callId" => "failed-call", "tool" => "repo_write", "arguments" => %{"secret" => "private"}}
      }
    }

    unsupported = %{dynamic | event: :unsupported_tool_call, payload: put_in(dynamic.payload, ["params", "callId"], "unsupported-call")}
    unsupported = update_in(unsupported, [:payload, "params"], &Map.delete(&1, "tool"))
    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", dynamic)
    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", dynamic)
    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", unsupported)
    assert :ok = SpecialistErrorNotice.observe(ctx.store, "attempt", %{dynamic | event: :tool_call_completed})
    assert {:error, :specialist_error_observation_unbound} = SpecialistErrorNotice.observe(ctx.store, "attempt", put_in(provider, [:payload, "params", "turnId"], "other-turn"))

    assert :ok =
             SpecialistErrorNotice.observe(ctx.store, "attempt", %{event: :notification, payload: %{"method" => "item/completed", "params" => %{"item" => %{"result" => "plain", "success" => true}}}})

    assert Store.one!(ctx.store, "SELECT status FROM worker_evidence WHERE request_key='attempt'")["status"] == "TURN_BOUND"
    rows = Store.query!(ctx.store, "SELECT payload_json FROM events WHERE event_type='SPECIALIST_ERROR_RECORDED' AND json_extract(payload_json,'$.request_key')='attempt'").rows
    assert length(rows) == 4
    assert {:error, :specialist_error_observation_unbound} = SpecialistErrorNotice.observe(ctx.store, "attempt", put_in(dynamic, [:payload, "params", "turnId"], "foreign-turn"))

    for [json] <- rows do
      notice = Jason.decode!(json)
      assert notice["ownership"] =~ "may still be continuing"
      refute Jason.encode!(SpecialistErrorNotice.metadata([notice])) =~ "private"
    end
  end

  defp seed_notice(ctx) do
    {:ok, _} =
      TaskLedger.register(ctx.store, %{
        task_key: "run:planner",
        run_id: "run",
        stage: "PLANNING",
        role: "feature-planner",
        status: "STALE",
        model_provider: "codex",
        model_class: "fast",
        model: "gpt-6-luna",
        reasoning_effort: "low",
        routing_reason: "fixture",
        prompt_sha256: String.duplicate("a", 64)
      })

    {:ok, notice} = SpecialistErrorNotice.record_task(ctx.store, "run:planner", "planner-request", :worker_timeout)
    notice
  end

  defp notice_native(ctx, request, final) do
    at = System.system_time(:second) + 1

    %{
      "id" => "parent",
      "cwd" => ctx.cwd,
      "projectId" => nil,
      "turns" => [
        %{
          "id" => "notice-turn",
          "status" => "completed",
          "startedAt" => at,
          "completedAt" => at + 1,
          "items" => [
            %{
              "id" => "delegation",
              "type" => "functionCallOutput",
              "namespace" => "codex_app",
              "name" => "send_message_to_thread",
              "output" => "<codex_delegation>\n  <source_thread_id>#{@broker}</source_thread_id>\n  <input>#{request["prompt"]}</input>\n</codex_delegation>"
            },
            %{"id" => "visible", "type" => "agentMessage", "phase" => "final_answer", "text" => final}
          ]
        }
      ]
    }
  end
end
