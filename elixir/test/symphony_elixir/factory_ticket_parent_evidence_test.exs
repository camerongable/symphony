defmodule SymphonyElixir.FactoryTicketParentEvidenceTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{DesktopRequest, Store, TicketChat, TicketChatOutbox, TicketParentEvidence}
  alias SymphonyElixir.TicketChatFixture
  @broker "019fa5b7-27fa-7660-ab47-7c3abb867c91"
  setup :fixture

  defmodule NativeReader do
    def read_native_thread(thread, opts) do
      send(self(), {:read_native_thread, thread, opts})
      {:ok, Process.get(:native_read_fixture)}
    end
  end

  defp fixture(context) do
    ctx = TicketChatFixture.setup_fixture(context)
    TicketChatFixture.runtime_fixture(ctx.root)
    {:ok, queued} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, request} = TicketChatFixture.claim_followup(ctx, queued.request_key)
    Map.merge(ctx, %{request: request, native: native(ctx.cwd, request["prompt"], "send_message_to_thread")})
  end

  test "exact completed origin is observed without asserting live idle, attachments or acknowledgment", ctx do
    assert {:ok, receipt} = observe(ctx, Map.put(ctx.native, "status", %{"type" => "notLoaded"}))
    assert receipt["turn_id"] == "native-turn"
    assert receipt["item_id"] == "native-item"
    assert receipt["source_thread_id"] == @broker
    assert receipt["payload_sha256"] == ctx.request["payload_sha256"]
    assert byte_size(receipt["readback_sha256"]) == 64
    refute receipt["live_idle_attested"]
    refute receipt["history_complete"]
    refute Map.has_key?(receipt, "worktree_attachments")
    refute Map.has_key?(receipt, "acknowledged")
    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert unchanged == ctx.request
  end

  test "controller collector requires complete transport history and requests no source turn", ctx do
    Process.put(:native_read_fixture, ctx.native)
    assert {:error, :parent_native_history_incomplete} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], "parent", @broker, reader: NativeReader)
    native = ctx.native |> Map.put("updatedAt", 42) |> Map.put("history_observation", %{"mode" => "PAGED_FULL", "next_cursor" => nil, "turn_count" => 1, "updated_at" => 42})
    Process.put(:native_read_fixture, native)
    assert {:ok, %{"history_complete" => true, "live_idle_attested" => false}} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], "parent", @broker, reader: NativeReader)
    assert_receive {:read_native_thread, "parent", [workspace: cwd, complete_history: true]}
    assert cwd == ctx.cwd
    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert unchanged == ctx.request
  end

  test "wrong collector target or malformed broker fails before native history access", ctx do
    assert {:error, :parent_native_identity_mismatch} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], "other", @broker)

    for thread <- [nil, "", String.duplicate("x", 257)] do
      assert {:error, :parent_native_identity_mismatch} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], thread, @broker, reader: NativeReader)
    end

    assert {:error, :parent_native_identity_mismatch} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], "other", @broker, reader: NativeReader)
    assert {:error, :parent_broker_identity_invalid} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], "parent", String.duplicate("-", 36), reader: NativeReader)
    refute_receive {:read_native_thread, _, _}
  end

  test "opt-in completion returns the exact attested final JSON and observed successful tools only", ctx do
    items = [
      %{"id" => "commentary", "type" => "agentMessage", "phase" => "commentary", "text" => "Not the result"},
      %{"id" => "final", "type" => "agentMessage", "phase" => "final_answer", "text" => ~s({"acknowledged":true})},
      %{"id" => "tool", "type" => "mcpToolCall", "server" => "codex_app", "tool" => "list_artifacts", "arguments" => %{}, "status" => "completed", "error" => nil, "result" => %{"content" => []}},
      %{"id" => "text-tool", "type" => "mcpToolCall", "server" => "codex_app", "tool" => "read_thread", "status" => "completed", "error" => nil, "result" => "ok"},
      %{"id" => "failed", "type" => "mcpToolCall", "server" => "codex_app", "tool" => "other", "status" => "completed", "error" => %{"message" => "failed"}, "result" => nil},
      %{"id" => "result-error", "type" => "mcpToolCall", "server" => "codex_app", "tool" => "error", "status" => "completed", "error" => nil, "result" => %{"isError" => true}},
      %{"id" => "item-error", "type" => "mcpToolCall", "server" => "codex_app", "tool" => "error", "status" => "completed", "isError" => true, "result" => %{}},
      %{
        "id" => "large-tool",
        "type" => "mcpToolCall",
        "server" => "codex_app",
        "tool" => "large_result",
        "status" => "completed",
        "error" => nil,
        "result" => %{"content" => [%{"text" => String.duplicate("artifact-data", 10_000)}]}
      },
      %{
        "id" => "large-command",
        "type" => "commandExecution",
        "status" => "completed",
        "exitCode" => 0,
        "cwd" => String.duplicate("/path", 2_000),
        "commandActions" => [%{"command" => String.duplicate("refresh-", 10_000)}]
      }
    ]

    native = update_in(ctx.native, ["turns", Access.at(0), "items"], &(&1 ++ items))
    native = native |> Map.put("updatedAt", 42) |> Map.put("history_observation", %{"mode" => "PAGED_FULL", "next_cursor" => nil, "turn_count" => 1, "updated_at" => 42})
    Process.put(:native_read_fixture, native)
    assert {:ok, receipt} = TicketChat.read_native_turn(ctx.store, ctx.request["request_key"], "parent", @broker, reader: NativeReader, include_completion: true)

    assert receipt["completion"] == %{
             "thread_id" => "parent",
             "turn_id" => "native-turn",
             "output" => %{
               "result" => %{"acknowledged" => true},
               "completed_tool_calls" => [
                 %{"server" => "codex_app", "tool" => "list_artifacts"},
                 %{"server" => "codex_app", "tool" => "read_thread"},
                 %{"server" => "codex_app", "tool" => "large_result"}
               ]
             }
           }

    assert byte_size(Jason.encode!(receipt["completion"])) < 2048

    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert unchanged == ctx.request
    assert {:error, :parent_native_completion_invalid} = TicketParentEvidence.completion(native, Map.put(receipt, "readback_sha256", "wrong"))

    for text <- [
          "{}",
          "[]",
          "{\"acknowledged\":true} trailing",
          ~s({"acknowledged":"yes"}),
          "Summary {\"acknowledged\":true} trailing",
          "Summary {\"acknowledged\":true} {\"acknowledged\":false}",
          "Summary {} {\"acknowledged\":true}",
          "Summary ```json\\n{\"acknowledged\":true}\\n```",
          "Summary\n~~~~json\n{\"acknowledged\":true}",
          ~s(Summary {"acknowledged":true,"other":1}),
          ~s(Summary {"acknowledged":true,"acknowledged":false}),
          String.duplicate("x", 2049)
        ] do
      bad = put_in(native, ["turns", Access.at(0), "items", Access.at(2), "text"], text)
      assert {:ok, proof} = observe(ctx, bad)
      assert {:error, :parent_native_completion_invalid} = TicketParentEvidence.completion(bad, proof)
    end

    duplicate = update_in(native, ["turns", Access.at(0), "items"], &(&1 ++ [%{"id" => "second-final", "type" => "agentMessage", "phase" => "final_answer", "text" => ~s({"acknowledged":true})}]))
    assert {:ok, proof} = observe(ctx, duplicate)
    assert {:error, :parent_native_completion_invalid} = TicketParentEvidence.completion(duplicate, proof)
    oversized = update_in(native, ["turns", Access.at(0), "items", Access.at(3), "tool"], fn _ -> String.duplicate("x", 16_384) end)
    assert {:ok, proof} = observe(ctx, oversized)
    assert {:error, :parent_native_completion_invalid} = TicketParentEvidence.completion(oversized, proof)
  end

  test "completion accepts bounded final prose ending in one exact acknowledgment object", ctx do
    text = "PPL-456 is in `PLANNING` on contract revision 1. The plan is recorded, but there’s no candidate SHA or CI evidence yet; two questions remain open. {\"acknowledged\":true}"
    native = update_in(ctx.native, ["turns", Access.at(0), "items"], &(&1 ++ [%{"id" => "final", "type" => "agentMessage", "phase" => "final_answer", "text" => text}]))
    assert {:ok, proof} = observe(ctx, native)
    assert {:ok, completion} = TicketParentEvidence.completion(native, proof)
    assert completion["output"]["result"] == %{"acknowledged" => true}
  end

  test "CREATE uses its own exact delegation name and completed receipt", ctx do
    key = ctx.chat["create_request_key"]
    {:ok, request} = DesktopRequest.get(ctx.store, key)
    native = native(ctx.cwd, request["prompt"], "create_thread")
    assert {:ok, %{"request_key" => ^key}} = TicketChat.observe_native_turn(ctx.store, key, @broker, native)
    assert {:error, :parent_native_invocation_not_observed} = TicketChat.observe_native_turn(ctx.store, key, @broker, ctx.native)
  end

  test "CREATE observes the exact delegation when native history XML-escapes prompt text", ctx do
    key = ctx.chat["create_request_key"]
    {:ok, request} = DesktopRequest.get(ctx.store, key)
    request = request |> Map.update!("prompt", &(&1 <> "\nExample pipeline: left |> right")) |> rehash_request()
    assert request["prompt"] =~ "|>"

    escaped_prompt =
      request["prompt"]
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    native = native(ctx.cwd, escaped_prompt, "create_thread")
    assert {:ok, %{"request_key" => ^key}} = TicketParentEvidence.observe(request, @broker, native)
  end

  test "identity, explicit null project and whole prompt are required", ctx do
    for bad <- [Map.put(ctx.native, "id", "other"), Map.put(ctx.native, "cwd", "/other")] do
      assert {:error, :parent_native_identity_mismatch} = observe(ctx, bad)
    end

    for bad <- [Map.delete(ctx.native, "projectId"), Map.put(ctx.native, "projectId", "project")] do
      assert {:error, :parent_native_project_not_proven} = observe(ctx, bad)
    end

    for bad <- [native(ctx.cwd, "prefix only", "send_message_to_thread"), native(ctx.cwd, ctx.request["prompt"], "create_thread")] do
      assert {:error, :parent_native_invocation_not_observed} = observe(ctx, bad)
    end

    assert {:error, :parent_native_invocation_not_observed} = TicketChat.observe_native_turn(ctx.store, ctx.request["request_key"], "019fa5b7-27fa-7660-ab47-7c3abb867c92", ctx.native)
    assert {:error, :parent_broker_identity_invalid} = TicketChat.observe_native_turn(ctx.store, ctx.request["request_key"], "bad", ctx.native)
  end

  test "direct evidence rejects malformed request metadata, action and secondary items", ctx do
    for native <- [nil, []] do
      assert {:error, :parent_native_readback_invalid} = TicketParentEvidence.observe(ctx.request, @broker, native)
    end

    for metadata <- ["[]", "{}", ~s({"generation":0})] do
      request = ctx.request |> Map.put("metadata_json", metadata) |> rehash_request()
      assert {:error, :parent_native_readback_invalid} = TicketParentEvidence.observe(request, @broker, ctx.native)
    end

    assert {:error, :not_a_ticket_chat_request} = TicketParentEvidence.observe(ctx.request |> Map.put("target_kind", "WORKER") |> rehash_request(), @broker, ctx.native)
    assert {:error, :parent_native_action_invalid} = TicketParentEvidence.observe(ctx.request |> Map.put("action", "INVALID") |> rehash_request(), @broker, ctx.native)
    bad = update_in(ctx.native, ["turns", Access.at(0), "items"], &(&1 ++ [nil]))
    assert {:error, :parent_native_history_incomplete} = TicketParentEvidence.observe(ctx.request, @broker, bad)

    {:ok, claimed, _} = DateTime.from_iso8601(ctx.request["claimed_at"])
    fraction = DateTime.to_unix(claimed, :microsecond) / 1_000_000 + 0.001
    native = ctx.native |> put_in(["turns", Access.at(0), "startedAt"], fraction) |> put_in(["turns", Access.at(0), "completedAt"], fraction + 1)
    assert {:ok, %{"started_at_precision" => "FRACTIONAL_SECOND"}} = TicketParentEvidence.observe(ctx.request, @broker, native)
    assert {:error, :parent_native_turn_time_invalid} = TicketParentEvidence.observe(ctx.request, @broker, put_in(native, ["turns", Access.at(0), "startedAt"], fraction - 1))
    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert unchanged == ctx.request
  end

  test "missing, unfinished, duplicate and pre-claim turns cannot be adopted", ctx do
    assert {:error, :parent_native_history_missing} = observe(ctx, Map.delete(ctx.native, "turns"))
    assert {:error, :parent_native_turn_incomplete} = observe(ctx, put_in(ctx.native, ["turns", Access.at(0), "status"], "interrupted"))
    assert {:error, :parent_native_history_identity_conflict} = observe(ctx, %{ctx.native | "turns" => ctx.native["turns"] ++ ctx.native["turns"]})
    assert {:error, :parent_native_history_identity_conflict} = observe(ctx, update_in(ctx.native, ["turns", Access.at(0), "items"], &(&1 ++ &1)))
    duplicate = update_in(ctx.native, ["turns", Access.at(0), "items"], fn [item] -> [item, %{item | "id" => "other-item"}] end)
    assert {:error, :parent_native_invocation_ambiguous} = observe(ctx, duplicate)
    assert {:error, :parent_native_turn_time_invalid} = observe(ctx, put_in(ctx.native, ["turns", Access.at(0), "startedAt"], 1))
    assert {:error, :parent_native_turn_time_invalid} = observe(ctx, put_in(ctx.native, ["turns", Access.at(0), "completedAt"], 1))
  end

  test "coarse same-second start is retained as coarse rather than rejecting a valid native turn", ctx do
    {:ok, claimed, _} = DateTime.from_iso8601(ctx.request["claimed_at"])
    same_second = DateTime.to_unix(claimed, :second)
    native = put_in(ctx.native, ["turns", Access.at(0), "startedAt"], same_second)
    assert {:ok, %{"started_at_precision" => "SECOND"}} = observe(ctx, native)
    assert {:error, :parent_native_turn_time_invalid} = observe(ctx, put_in(native, ["turns", Access.at(0), "startedAt"], same_second - 1))
  end

  test "uninspectable secondary history cannot hide another invocation", ctx do
    for turn <- [%{"id" => "other-turn", "status" => "completed"}, %{"id" => "other-turn", "status" => "completed", "items" => nil}, nil] do
      assert {:error, :parent_native_history_incomplete} = observe(ctx, update_in(ctx.native, ["turns"], &(&1 ++ [turn])))
    end

    bad = %{"id" => "other-turn", "status" => "completed", "items" => [%{"id" => "other-item", "type" => "functionCallOutput"}]}
    assert {:error, :parent_native_history_incomplete} = observe(ctx, update_in(ctx.native, ["turns"], &(&1 ++ [bad])))
  end

  test "stale generation and missing claim fail before history is accepted", ctx do
    Store.query!(ctx.store, "UPDATE desktop_requests SET claimed_at = NULL WHERE request_key = ?", [ctx.request["request_key"]])
    assert {:error, :ticket_chat_claim_evidence_missing} = observe(ctx, ctx.native)
    Store.query!(ctx.store, "UPDATE desktop_requests SET claimed_at = ? WHERE request_key = ?", [ctx.request["claimed_at"], ctx.request["request_key"]])
    Store.query!(ctx.store, "UPDATE ticket_chats SET generation = generation + 1")
    assert {:error, :ticket_chat_binding_mismatch} = observe(ctx, ctx.native)
  end

  defp observe(ctx, native), do: TicketChat.observe_native_turn(ctx.store, ctx.request["request_key"], @broker, native)

  defp rehash_request(request) do
    fields = ~w(request_key target_kind target_key action codex_project_id model reasoning_effort title prompt cwd existing_thread_id branch base_branch schema_json metadata_json)
    entries = request |> Map.take(fields) |> Enum.sort_by(&elem(&1, 0))
    raw = "{" <> Enum.map_join(entries, ",", fn {key, value} -> Jason.encode!(key) <> ":" <> Jason.encode!(value) end) <> "}"
    Map.put(request, "payload_sha256", Base.encode16(:crypto.hash(:sha256, raw), case: :lower))
  end

  defp native(cwd, prompt, tool) do
    started = DateTime.to_unix(DateTime.utc_now(), :second) + 1

    %{
      "id" => "parent",
      "cwd" => cwd,
      "projectId" => nil,
      "turns" => [
        %{
          "id" => "native-turn",
          "status" => "completed",
          "startedAt" => started,
          "completedAt" => started + 1,
          "items" => [
            %{
              "id" => "native-item",
              "type" => "functionCallOutput",
              "namespace" => "codex_app",
              "name" => tool,
              "output" => "<codex_delegation>\n  <source_thread_id>#{@broker}</source_thread_id>\n  <input>#{prompt}</input>\n</codex_delegation>"
            }
          ]
        }
      ]
    }
  end
end
