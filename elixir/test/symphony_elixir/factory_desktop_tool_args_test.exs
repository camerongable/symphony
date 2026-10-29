defmodule SymphonyElixir.FactoryDesktopToolArgsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{DesktopRequest, DesktopToolArgs, RunLedger, Store, TaskLedger}

  test "ticket chat formatting permits notices only on followups and preserves base guards" do
    bare = ticket_request()
    assert {:ok, bare_args} = DesktopToolArgs.followup(bare)
    assert {:ok, _} = DesktopToolArgs.create_thread(%{bare | "action" => "CREATE", "existing_thread_id" => nil})

    base = Jason.decode!(bare["metadata_json"])
    notice = %{"specialist_notice_ids" => ["legacy-opaque-id"], "specialist_notice_text" => "Exact notice\nwith preserved spacing. "}
    request = Map.put(bare, "metadata_json", Jason.encode!(Map.merge(base, notice)))
    assert {:ok, ^bare_args} = DesktopToolArgs.followup(request)
    assert {:error, :invalid_ticket_chat_metadata} = DesktopToolArgs.create_thread(%{request | "action" => "CREATE", "existing_thread_id" => nil})

    for {changes, error} <- [
          {%{"unknown" => true}, :invalid_ticket_chat_metadata},
          {%{"generation" => 0}, :invalid_ticket_chat_generation},
          {%{"generation" => "1"}, :invalid_ticket_chat_generation},
          {%{"directory_name" => "elsewhere"}, :ticket_chat_directory_mismatch},
          {%{"broker_thread_id" => "invalid"}, :parent_broker_identity_invalid},
          {%{"route" => "other"}, :unsupported_ticket_chat_route}
        ] do
      changed = Map.put(request, "metadata_json", Jason.encode!(Map.merge(base, Map.merge(notice, changes))))
      assert DesktopToolArgs.followup(changed) == {:error, error}
    end

    assert {:error, :unsupported_create_thread_model} = DesktopToolArgs.followup(Map.put(request, "model", "unknown"))
    assert {:error, :ticket_chat_directory_mismatch} = DesktopToolArgs.followup(Map.put(request, "cwd", "/tmp/wrong"))
    with_broker = Map.put(base, "broker_thread_id", "019fa5b7-27fa-7660-ab47-7c3abb867c91")
    assert {:ok, ^bare_args} = DesktopToolArgs.followup(Map.put(request, "metadata_json", Jason.encode!(Map.merge(with_broker, notice))))
  end

  test "ticket chat formatting rejects every incomplete or malformed notice pair" do
    request = ticket_request()
    base = Jason.decode!(request["metadata_json"])

    for notice <- [
          %{"specialist_notice_ids" => ["id"]},
          %{"specialist_notice_text" => "text"},
          %{"specialist_notice_ids" => nil, "specialist_notice_text" => "text"},
          %{"specialist_notice_ids" => "id", "specialist_notice_text" => "text"},
          %{"specialist_notice_ids" => [], "specialist_notice_text" => "text"},
          %{"specialist_notice_ids" => ["id", "id"], "specialist_notice_text" => "text"},
          %{"specialist_notice_ids" => [""], "specialist_notice_text" => "text"},
          %{"specialist_notice_ids" => ["id"], "specialist_notice_text" => ""},
          %{"specialist_notice_ids" => ["id"], "specialist_notice_text" => nil},
          %{"specialist_notice_ids" => ["id"], "specialist_notice_text" => 42}
        ] do
      assert {:error, :invalid_ticket_chat_metadata} = DesktopToolArgs.followup(Map.put(request, "metadata_json", Jason.encode!(Map.merge(base, notice))))
    end

    invalid_utf8 = "{\"specialist_notice_ids\":[\"id\"],\"specialist_notice_text\":\"" <> <<255>> <> "\"}"
    assert {:error, :invalid_create_thread_metadata} = DesktopToolArgs.followup(Map.put(request, "metadata_json", invalid_utf8))
  end

  test "native creation pins the immutable commit and emits only supported tool keys" do
    request = request()
    assert {:ok, args} = DesktopToolArgs.create_thread(request)

    assert args == %{
             "target" => %{
               "type" => "project",
               "projectId" => "project-grail",
               "environment" => %{
                 "type" => "worktree",
                 "startingState" => %{"type" => "branch", "branchName" => String.duplicate("a", 40)}
               }
             },
             "model" => "gpt-6-sol",
             "thinking" => "high",
             "title" => "Verify candidate",
             "prompt" => "Verify the exact candidate."
           }
  end

  test "project-local creation explicitly uses the saved project checkout" do
    request = Map.put(request(), "metadata_json", Jason.encode!(%{"workspace_mode" => "CODEX_PROJECT_LOCAL"}))
    assert {:ok, args} = DesktopToolArgs.create_thread(request)
    assert args["target"]["environment"] == %{"type" => "local"}
    refute Map.has_key?(args, "projectId")
  end

  test "invalid or unsupported create routes fail closed" do
    cases = [
      {Map.put(request(), "action", "FOLLOWUP"), :unsupported_create_thread_route},
      {Map.put(request(), "target_kind", "CONTROLLER"), :unsupported_create_thread_route},
      {Map.put(request(), "codex_project_id", " "), {:missing_create_thread_fields, ["codex_project_id"]}},
      {Map.put(request(), "existing_thread_id", "existing"), :unexpected_existing_thread},
      {Map.put(request(), "model", "unknown"), :unsupported_create_thread_model},
      {Map.put(request(), "reasoning_effort", "unknown"), :unsupported_create_thread_effort},
      {Map.put(request(), "model", "gpt-5.5") |> Map.put("reasoning_effort", "ultra"), :unsupported_create_thread_effort},
      {Map.put(request(), "metadata_json", "not-json"), :invalid_create_thread_metadata},
      {Map.put(request(), "metadata_json", "[]"), :invalid_create_thread_metadata},
      {Map.put(request(), "metadata_json", nil), :invalid_create_thread_metadata},
      {metadata(%{"workspace_mode" => "FACTORY"}), :unsupported_create_thread_workspace_mode},
      {metadata(%{"workspace_mode" => "CODEX_NATIVE"}), :native_base_sha_required},
      {metadata(%{"workspace_mode" => "CODEX_NATIVE", "expected_sha" => "main"}), :native_base_sha_required}
    ]

    for {request, error} <- cases do
      assert DesktopToolArgs.create_thread(request) == {:error, error}
    end
  end

  test "stored request generation checks payload integrity without mutating the request" do
    store = start_supervised!({Store, database: ":memory:"})
    register_request(store)
    assert {:ok, before} = DesktopRequest.get(store, "verify:create")
    assert {:ok, args} = DesktopToolArgs.create_thread(store, "verify:create")
    assert {:ok, ^before} = DesktopRequest.get(store, "verify:create")
    assert args["target"]["projectId"] == "project-grail"
    assert {:error, :unknown_request} = DesktopToolArgs.create_thread(store, "missing")

    Store.query!(store, "UPDATE desktop_requests SET prompt = ? WHERE request_key = ?", ["changed", "verify:create"])
    assert {:error, :request_payload_corrupt} = DesktopToolArgs.create_thread(store, "verify:create")
  end

  defp ticket_request do
    chat_key = "TC-" <> String.duplicate("a", 64)
    directory = "factory-ticket-" <> String.slice(chat_key, 3, 20)

    %{
      "action" => "FOLLOWUP",
      "target_kind" => "TICKET_CHAT",
      "existing_thread_id" => "parent",
      "codex_project_id" => nil,
      "model" => "gpt-6-luna",
      "reasoning_effort" => "medium",
      "title" => "Ticket",
      "prompt" => "Exact payload",
      "cwd" => "/private/tmp/" <> directory,
      "metadata_json" => Jason.encode!(%{"chat_key" => chat_key, "directory_name" => directory, "generation" => 1, "route" => "desktop_owned_ticket_chat_v1"})
    }
  end

  defp register_request(store) do
    {:ok, _} = RunLedger.register(store, %{run_id: "run", issue_key: "PPL-123", kind: "DELIVERY", state: "VERIFYING"})

    {:ok, _} =
      TaskLedger.register(store, %{
        task_key: "verify",
        run_id: "run",
        stage: "VERIFYING",
        role: "change-verifier",
        status: "STARTING",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "role-policy",
        codex_project_id: "project-grail",
        prompt_sha256: String.duplicate("a", 64)
      })

    attrs = request() |> Map.delete("metadata_json") |> Map.put("metadata", Jason.decode!(request()["metadata_json"]))
    {:ok, _} = DesktopRequest.enqueue(store, attrs)
  end

  defp metadata(value), do: Map.put(request(), "metadata_json", Jason.encode!(value))

  defp request do
    %{
      "request_key" => "verify:create",
      "target_key" => "verify",
      "action" => "CREATE",
      "target_kind" => "TASK",
      "codex_project_id" => "project-grail",
      "model" => "gpt-6-sol",
      "reasoning_effort" => "high",
      "title" => "Verify candidate",
      "prompt" => "Verify the exact candidate.",
      "cwd" => "/tmp/repo",
      "metadata_json" => Jason.encode!(%{"workspace_mode" => "CODEX_NATIVE", "expected_sha" => String.duplicate("a", 40)})
    }
  end
end
