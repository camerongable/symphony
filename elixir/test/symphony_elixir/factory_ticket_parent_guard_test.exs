defmodule SymphonyElixir.FactoryTicketParentGuardTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{DesktopRequest, Store, TicketChat, TicketChatOutbox, TicketParentGuard}
  alias SymphonyElixir.TicketChatFixture

  defmodule Reader do
    def read_native_thread(thread, opts) do
      send(self(), {:queue_read, thread, opts})
      Process.get(:queue_read_result)
    end
  end

  setup context do
    ctx = TicketChatFixture.setup_fixture(context)
    TicketChatFixture.runtime_fixture(ctx.root)
    {:ok, queued} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, request} = DesktopRequest.get(ctx.store, queued.request_key)
    Map.merge(ctx, %{request: request, proof: TicketChatFixture.parent_guard(ctx)})
  end

  test "unsupported runtime cannot claim a followup despite fresh valid guard evidence", ctx do
    TicketChatFixture.runtime_fixture(ctx.root, %{})
    assert {:error, :worker_runtime_identity_unproven} = TicketChatFixture.claim_followup(ctx, ctx.request["request_key"])
    assert {:ok, current} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert current == ctx.request
    assert Store.query!(ctx.store, "SELECT * FROM ticket_parent_claims").rows == []
  end

  test "a slow runtime probe cannot extend a followup guard's original freshness window", ctx do
    marker = Path.join(ctx.root, "probe-started")
    TicketChatFixture.runtime_fixture(ctx.root, :supported, "touch '#{marker}'; sleep 11")
    command = Path.join(ctx.root, "runtime-fixture")

    SymphonyElixir.TestSupport.write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      codex_command: "#{command} app-server",
      codex_read_timeout_ms: 15_000
    )

    assert {:error, :parent_guard_observation_expired} = TicketChatFixture.claim_followup(ctx, ctx.request["request_key"])
    assert File.exists?(marker)
    assert {:ok, current} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert current == ctx.request
    assert Store.query!(ctx.store, "SELECT * FROM ticket_parent_claims").rows == []
  end

  test "followup claim retains guard and payload binding through restart and refuses replay", ctx do
    assert {:error, :parent_guard_evidence_required} = DesktopRequest.claim(ctx.store, ctx.request["request_key"], policy())
    assert {:ok, claimed} = TicketChatFixture.claim_followup(ctx, ctx.request["request_key"])
    assert claimed["status"] == "FOLLOWUP_UNCERTAIN"
    stored = Store.one!(ctx.store, "SELECT * FROM ticket_parent_claims WHERE request_key = ?", [claimed["request_key"]])
    receipt = Jason.decode!(stored["receipt_json"])
    assert receipt["payload_sha256"] == claimed["payload_sha256"]
    assert receipt["generation"] == 1
    assert receipt["owner_source"] == "codex_app/read_thread"
    assert receipt["owner_status"] == "idle"
    assert {:ok, guard_at, _} = DateTime.from_iso8601(receipt["guard_checked_at"])
    assert {:ok, claim_at, _} = DateTime.from_iso8601(claimed["claimed_at"])
    assert DateTime.compare(guard_at, claim_at) in [:lt, :eq]
    assert {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:error, :ticket_chat_request_already_issued} = DesktopRequest.claim(reopened, claimed["request_key"], policy())
      assert Store.one!(reopened, "SELECT * FROM ticket_parent_claims WHERE request_key = ?", [claimed["request_key"]]) == stored
    after
      GenServer.stop(reopened)
    end
  end

  test "busy, unknown, foreign, mismatched, expired and queued observations leave the request pending", ctx do
    old = DateTime.utc_now() |> DateTime.add(-11, :second) |> DateTime.to_iso8601()
    future = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.to_iso8601()

    for {proof, error} <- [
          {put_in(ctx.proof, ["owner", "response", "thread", "status"], %{"type" => "active"}), :parent_owner_not_quiet},
          {put_in(ctx.proof, ["owner", "response", "thread", "status"], %{"type" => "systemError"}), :parent_owner_not_quiet},
          {put_in(ctx.proof, ["owner", "source"], "app-server/thread/read"), :parent_guard_evidence_invalid},
          {put_in(ctx.proof, ["owner", "response", "thread", "id"], "other"), :parent_guard_identity_mismatch},
          {put_in(ctx.proof, ["native", "projectId"], "project"), :parent_guard_evidence_invalid},
          {put_in(ctx.proof, ["owner", "observed_at"], old), :parent_guard_observation_expired},
          {put_in(ctx.proof, ["owner", "observed_at"], "not-a-timestamp"), :parent_guard_evidence_invalid},
          {put_in(ctx.proof, ["owner", "observed_at"], nil), :parent_guard_evidence_invalid},
          {put_in(ctx.proof, ["native", "queue_observation", "observed_at"], future), :parent_guard_observation_expired},
          {put_in(ctx.proof, ["native", "queue_observation", "empty_complete"], false), :parent_queue_not_empty},
          {put_in(ctx.proof, ["native", "queue_observation", "sha256"], "invalid"), :parent_queue_evidence_invalid},
          {put_in(ctx.proof, ["native", "queue_observation", "sha256"], String.duplicate("a", 64)), :parent_queue_evidence_invalid},
          {put_in(ctx.proof, ["native", "queue_observation", "raw_response"], %{"data" => [%{"id" => "queued"}], "nextCursor" => nil}), :parent_queue_evidence_invalid},
          {put_in(ctx.proof, ["native", "queue_observation", "raw_response"], %{"data" => []}), :parent_queue_evidence_invalid},
          {update_in(ctx.proof, ["native", "queue_observation"], &Map.delete(&1, "raw_response")), :parent_queue_evidence_invalid},
          {Map.put(ctx.proof, "source_thread_id", "unknown"), :parent_broker_identity_invalid},
          {put_in(ctx.proof, ["owner", "response", "thread"], 1), :parent_guard_evidence_invalid}
        ] do
      assert {:error, ^error} = DesktopRequest.claim(ctx.store, ctx.request["request_key"], Keyword.put(policy(), :parent_guard, proof))
      assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
      assert unchanged == ctx.request
      assert Store.one!(ctx.store, "SELECT * FROM ticket_parent_claims WHERE request_key = ?", [ctx.request["request_key"]]) == nil
    end
  end

  test "only owning Desktop quiet status plus a complete queue observation permits collection and claim", ctx do
    proof = put_in(ctx.proof, ["owner", "response", "thread", "status"], %{"type" => "notLoaded"})
    Process.put(:queue_read_result, {:ok, proof["native"]})
    assert {:ok, _} = TicketChat.claim_followup(ctx.store, ctx.request["request_key"], proof["source_thread_id"], proof["owner"], Keyword.put(policy(), :reader, Reader))
    assert_received {:queue_read, "parent", [workspace: cwd, include_turns: false, include_queue: true]}
    assert cwd == ctx.cwd
    refute_received {:queue_read, _, _}
  end

  test "failed queue read never claims or sends and disabled policy never reads", ctx do
    assert {:error, :ticket_chat_runtime_not_integrated} = TicketChat.claim_followup(ctx.store, ctx.request["request_key"], ctx.proof["source_thread_id"], ctx.proof["owner"])
    Process.put(:queue_read_result, {:error, :native_queue_page_invalid})
    assert {:error, :ticket_chat_runtime_not_integrated} = TicketChat.claim_followup(ctx.store, ctx.request["request_key"], ctx.proof["source_thread_id"], ctx.proof["owner"], reader: Reader)
    refute_received {:queue_read, _, _}

    assert {:error, :native_queue_page_invalid} =
             TicketChat.claim_followup(ctx.store, ctx.request["request_key"], ctx.proof["source_thread_id"], ctx.proof["owner"], Keyword.put(policy(), :reader, Reader))

    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert unchanged == ctx.request
  end

  test "guard rejects malformed generation rather than manufacturing a binding", ctx do
    request = Map.put(ctx.request, "metadata_json", Jason.encode!(%{"generation" => 0}))
    assert {:error, :parent_guard_generation_invalid} = TicketParentGuard.receipt(request, ctx.proof, DateTime.utc_now())
    assert {:error, :parent_guard_evidence_invalid} = TicketParentGuard.receipt(Map.put(request, "metadata_json", "{}"), ctx.proof, DateTime.utc_now())

    for metadata <- ["not-json", "[]"] do
      assert {:error, :parent_guard_evidence_invalid} = TicketParentGuard.receipt(Map.put(request, "metadata_json", metadata), ctx.proof, DateTime.utc_now())
    end

    assert {:error, :parent_guard_generation_invalid} = TicketParentGuard.receipt(Map.put(request, "metadata_json", nil), ctx.proof, DateTime.utc_now())
    assert {:ok, unchanged} = DesktopRequest.get(ctx.store, ctx.request["request_key"])
    assert unchanged == ctx.request
    assert Store.one!(ctx.store, "SELECT * FROM ticket_parent_claims WHERE request_key = ?", [ctx.request["request_key"]]) == nil
  end

  defp policy, do: [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]
end
