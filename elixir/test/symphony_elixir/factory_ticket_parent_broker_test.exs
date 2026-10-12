defmodule SymphonyElixir.FactoryTicketParentBrokerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Factory.Desktop
  alias SymphonyElixir.Factory.{Control, DesktopRequest, DesktopToolArgs, RunLedger, Store, TicketChatOutbox}
  alias SymphonyElixir.TicketChatFixture

  setup context do
    ctx = TicketChatFixture.setup_fixture(context)
    TicketChatFixture.runtime_fixture(ctx.root)
    Map.put(ctx, :workflow, Path.join(ctx.root, "WORKFLOW.md"))
  end

  test "typed CLI presentation drains after rollback without source or delivery mutation", ctx do
    workflow(ctx, true)
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, queued} = TicketChatOutbox.publish(ctx.store, "run")
    key = queued.request_key
    assert_raise Mix.Error, ~r/ticket_chat_runtime_not_integrated/, fn -> cli(ctx, ["followup-args", key]) end
    {:ok, args} = DesktopToolArgs.followup(ctx.store, key, policy())
    assert String.starts_with?(args["prompt"], "Factory request ID: #{key}\n")
    assert args["prompt"] =~ "Controller-observed AS-OF presentation only; not human input or source authority"
    assert args["prompt"] =~ "do not refresh, call tools, stage, or perform source, control, Jira, GitLab, or delivery actions"
    assert args["prompt"] =~ ~s|The final answer must be exactly {"acknowledged":true}, with no prose or formatting.|
    assert args["threadId"] == "parent"
    assert args["model"] == "gpt-6-luna"
    assert args["thinking"] == "low"
    refute cli(ctx, ["list"])["pending"] |> Enum.any?(&(&1["request_key"] == key))
    {:ok, claimed} = TicketChatFixture.claim_followup(ctx, key, policy())
    assert claimed["status"] == "FOLLOWUP_UNCERTAIN"
    workflow(ctx, false)
    assert_raise Mix.Error, ~r/ticket_chat_runtime_not_integrated/, fn -> cli(ctx, ["followup-args", key]) end
    assert cli(ctx, ["list"])["reconciliation"] |> Enum.any?(&(&1["request_key"] == key))

    proof = %{
      "request_key" => key,
      "payload_sha256" => claimed["payload_sha256"],
      "generation" => 1,
      "thread_id" => "parent",
      "project_id" => nil,
      "cwd" => ctx.cwd,
      "tool_arguments" => args,
      "worktree_attachments" => []
    }

    invalid = Map.put(proof, "worktree_attachments", [%{"root" => "/unrelated"}])
    assert_raise Mix.Error, ~r/ticket_chat_observation_mismatch/, fn -> cli(ctx, ["record-ticket-thread", key, "--payload-base64", encode(invalid)]) end
    assert cli(ctx, ["record-ticket-thread", key, "--payload-base64", encode(proof)])["status"] == "THREAD_RECORDED"
    payload = %{"thread_id" => "parent", "turn_id" => "presentation", "output" => %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}}
    declined = put_in(payload, ["output", "result", "acknowledged"], false)
    assert_raise Mix.Error, ~r/ticket_chat_acknowledgement_required/, fn -> cli(ctx, ["complete", key, "--payload-base64", encode(declined)]) end
    assert {:ok, %{"status" => "THREAD_RECORDED", "output_json" => nil}} = DesktopRequest.get(ctx.store, key)
    assert cli(ctx, ["complete", key, "--payload-base64", encode(payload)])["status"] == "SUCCEEDED"
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
    assert {:ok, %{status: "UNCHANGED"}} = TicketChatOutbox.publish(ctx.store, "run")
  end

  test "coalesced pending arguments cannot claim a superseded presentation", ctx do
    workflow(ctx, true)
    {:ok, first} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, args} = DesktopToolArgs.followup(ctx.store, first.request_key, policy())
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "VERIFYING"})
    {:ok, second} = TicketChatOutbox.publish(ctx.store, "run")
    refute first.request_key == second.request_key
    assert {:error, :ticket_chat_request_already_issued} = DesktopRequest.claim(ctx.store, first.request_key, policy())
    {:ok, claimed} = TicketChatFixture.claim_followup(ctx, second.request_key, policy())
    refute args["prompt"] == claimed["prompt"]
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "REPAIRING"})
    assert {:ok, %{status: "SYNC_LAG"}} = TicketChatOutbox.publish(ctx.store, "run")
    assert {:error, :ticket_chat_request_already_issued} = DesktopRequest.claim(ctx.store, second.request_key, policy())
  end

  test "disabled CLI refuses new typed operations and malformed readback cannot mutate", ctx do
    workflow(ctx, false)
    {:ok, queued} = TicketChatOutbox.publish(ctx.store, "run")
    assert_raise Mix.Error, ~r/ticket_chat_runtime_not_integrated/, fn -> cli(ctx, ["claim", queued.request_key]) end
    assert_raise Mix.Error, ~r/ticket_chat_runtime_not_integrated/, fn -> cli(ctx, ["record-ticket-thread", queued.request_key, "--payload-base64", encode(%{})]) end
    assert {:ok, %{"status" => "PENDING"}} = DesktopRequest.get(ctx.store, queued.request_key)
  end

  test "older parent remains visible ahead of legacy work at a one-request limit", ctx do
    {:ok, queued} = TicketChatOutbox.publish(ctx.store, "run")
    Control.initialize(ctx.store, %{scope: "other", dispatcher_id: "fixture"})

    {:ok, _} =
      DesktopRequest.enqueue(ctx.store, %{
        request_key: "legacy-controller",
        target_kind: "CONTROLLER",
        target_key: "other",
        action: "CREATE",
        codex_project_id: "project",
        model: "gpt-6-luna",
        reasoning_effort: "low",
        title: "Other",
        prompt: "Read only",
        cwd: ctx.root,
        schema: %{"type" => "object"},
        metadata: %{}
      })

    Store.query!(ctx.store, "UPDATE desktop_requests SET created_at = '2000-01-01T00:00:00Z' WHERE request_key = ?", [queued.request_key])
    assert [%{"request_key" => key}] = DesktopRequest.list_pending(ctx.store, 1, policy())
    assert key == queued.request_key
    {:ok, _} = TicketChatFixture.claim_followup(ctx, queued.request_key, policy())
    {:ok, _} = DesktopRequest.claim(ctx.store, "legacy-controller")
    assert [%{"request_key" => ^key}] = DesktopRequest.list_reconciliation(ctx.store, 1)
  end

  test "direct readback and completion require durable claim and exact linked identity", ctx do
    {:ok, queued} = TicketChatOutbox.publish(ctx.store, "run")
    {:ok, args} = DesktopToolArgs.followup(ctx.store, queued.request_key, policy())
    {:ok, claimed} = TicketChatFixture.claim_followup(ctx, queued.request_key, policy())

    proof = %{
      "request_key" => queued.request_key,
      "payload_sha256" => claimed["payload_sha256"],
      "generation" => 1,
      "thread_id" => "parent",
      "project_id" => nil,
      "cwd" => ctx.cwd,
      "tool_arguments" => args,
      "worktree_attachments" => []
    }

    Store.query!(ctx.store, "UPDATE desktop_requests SET claimed_at = NULL WHERE request_key = ?", [queued.request_key])
    assert {:error, :ticket_chat_claim_evidence_missing} = DesktopRequest.record_ticket_thread(ctx.store, queued.request_key, proof)
    Store.query!(ctx.store, "UPDATE desktop_requests SET claimed_at = ? WHERE request_key = ?", [claimed["claimed_at"], queued.request_key])
    {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, queued.request_key, proof)
    Store.query!(ctx.store, "DELETE FROM ticket_chat_runs WHERE run_id = 'run'")
    payload = %{thread_id: "parent", turn_id: "no-adoption", output: %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}}
    assert {:error, :ticket_chat_run_binding_missing} = DesktopRequest.complete(ctx.store, queued.request_key, payload)
    assert {:ok, %{"status" => "THREAD_RECORDED", "output_json" => nil}} = DesktopRequest.get(ctx.store, queued.request_key)
  end

  defp workflow(ctx, enabled) do
    File.write!(ctx.workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n  ticket_supervisor:\n    enabled: #{enabled}\n    pilot_issue_keys: [PPL-123]\n---\n")
  end

  defp cli(ctx, args), do: capture_io(fn -> Desktop.run(args ++ ["--workflow", ctx.workflow]) end) |> Jason.decode!()
  defp encode(payload), do: payload |> Jason.encode!() |> Base.encode64()
  defp policy, do: [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]
end
