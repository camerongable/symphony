defmodule SymphonyElixir.FactoryTicketMrCompletionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketMrCompletion

  @broker "00000000-0000-0000-0000-000000000001"

  defp fixture do
    prompt = "Factory request ID: desktop:receipt-fixture\n\nExact typed MR operation."

    request = %{
      "target_kind" => "CONTROLLER",
      "request_key" => "desktop:receipt-fixture",
      "existing_thread_id" => "controller",
      "codex_project_id" => "projectless",
      "cwd" => "/fixture/controller",
      "prompt" => prompt,
      "claimed_at" => "2026-10-19T00:00:00Z",
      "metadata_json" => Jason.encode!(%{"previous_turn_id" => "previous", "delivery_operation" => %{"version" => 2, "operation" => "CREATE_OR_REUSE_DRAFT_MR"}})
    }

    result = %{"status" => "PASS", "sha" => String.duplicate("a", 40)}

    items = [
      %{
        "type" => "functionCallOutput",
        "id" => "delegation",
        "namespace" => "codex_app",
        "name" => "send_message_to_thread",
        "output" => "<codex_delegation>\n  <source_thread_id>#{@broker}</source_thread_id>\n  <input>#{prompt}</input>\n</codex_delegation>"
      },
      %{
        "type" => "mcpToolCall",
        "id" => "gitlab",
        "server" => "GitLab",
        "tool" => "get_merge_request",
        "status" => "completed",
        "error" => nil,
        "result" => %{"_meta" => %{}, "content" => [], "structuredContent" => %{}}
      },
      %{"type" => "agentMessage", "id" => "final", "phase" => "final_answer", "text" => Jason.encode!(result)}
    ]

    turns = [
      %{"id" => "previous", "items" => [], "status" => "completed"},
      %{"id" => "observed", "items" => items, "status" => "completed", "error" => nil, "startedAt" => 1_792_368_001, "completedAt" => 1_792_368_002}
    ]

    native = %{
      "id" => "controller",
      "cwd" => request["cwd"],
      "projectId" => nil,
      "updatedAt" => 42,
      "turns" => turns,
      "history_observation" => %{"mode" => "PAGED_AFTER_ANCHOR", "anchor_turn_id" => "previous", "turn_count" => 2, "updated_at" => 42}
    }

    {request, native, result}
  end

  test "real delegated native item shapes deterministically retain status omitted by handwritten receipts" do
    {request, native, result} = fixture()
    assert {:ok, completion} = TicketMrCompletion.project(request, native, "observed", @broker)

    assert completion == %{
             "thread_id" => "controller",
             "turn_id" => "observed",
             "output" => %{"result" => result, "completed_tool_calls" => [%{"server" => "GitLab", "tool" => "get_merge_request", "status" => "completed", "error" => nil, "isError" => false}]}
           }

    block = put_in(native, ["turns", Access.at(1), "items", Access.at(2), "text"], Jason.encode!(Map.put(result, "status", "BLOCK")))
    assert {:ok, %{"output" => %{"result" => %{"status" => "BLOCK"}}}} = TicketMrCompletion.project(request, block, "observed", @broker)
  end

  test "mixed completed outcomes remain distinct while incomplete or missing tool payload refuses" do
    {request, native, _} = fixture()

    failed = %{
      "type" => "mcpToolCall",
      "id" => "failed",
      "server" => "GitLab",
      "tool" => "get_merge_request",
      "status" => "completed",
      "result" => %{"isError" => true},
      "error" => %{"message" => "synthetic denied"}
    }

    mixed = update_in(native, ["turns", Access.at(1), "items"], &(&1 ++ [failed]))
    assert {:ok, %{"output" => %{"completed_tool_calls" => [success, error]}}} = TicketMrCompletion.project(request, mixed, "observed", @broker)
    assert success["isError"] == false and error["isError"] == true
    assert error["error"] == failed["error"]

    for status <- ["inProgress", "cancelled", nil] do
      changed = put_in(native, ["turns", Access.at(1), "items", Access.at(1), "status"], status)
      assert {:error, :mr_completion_tool_incomplete} = TicketMrCompletion.project(request, changed, "observed", @broker)
    end

    missing = update_in(native, ["turns", Access.at(1), "items", Access.at(1)], &Map.delete(&1, "result"))
    assert {:error, :mr_completion_tool_payload_missing} = TicketMrCompletion.project(request, missing, "observed", @broker)
  end

  test "quoted markers wrong sender duplicate delegation and multiple finals cannot authenticate completion" do
    {request, native, _} = fixture()

    for changed <- [
          put_in(native, ["turns", Access.at(1), "items", Access.at(0), "namespace"], "untrusted"),
          update_in(native, ["turns", Access.at(1), "items", Access.at(0), "output"], &("quoted " <> &1)),
          update_in(native, ["turns", Access.at(1), "items"], &(&1 ++ [hd(&1)])),
          update_in(native, ["turns", Access.at(1), "items"], &(&1 ++ [List.last(&1)])),
          update_in(native, ["turns", Access.at(1), "items"], &(&1 ++ [Map.put(hd(&1), "id", "second-delegation")])),
          update_in(native, ["turns", Access.at(1), "items"], &(&1 ++ [Map.put(List.last(&1), "id", "second-final")])),
          put_in(native, ["history_observation", "anchor_turn_id"], "unbound"),
          put_in(native, ["history_observation", "updated_at"], 41)
        ] do
      assert {:error, _} = TicketMrCompletion.project(request, changed, "observed", @broker)
    end

    assert {:error, _} = TicketMrCompletion.project(request, native, "previous", @broker)
    assert {:error, _} = TicketMrCompletion.project(request, native, "observed", "00000000-0000-0000-0000-000000000002")
    malformed = put_in(native, ["turns", Access.at(1), "items", Access.at(2), "text"], "not-json")
    assert {:error, :mr_completion_json_invalid} = TicketMrCompletion.project(request, malformed, "observed", @broker)
  end
end
