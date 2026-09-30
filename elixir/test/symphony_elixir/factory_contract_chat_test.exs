defmodule SymphonyElixir.FactoryContractChatTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Contract, ContractChat, RunLedger, Store, TaskLedger}

  defmodule BoundWorktree do
    @spec validate_native(map(), Path.t(), keyword()) :: {:ok, map()}
    def validate_native(_route, path, opts), do: {:ok, %{path: path, sha: opts[:expected_sha]}}
  end

  setup do
    {:ok, store} = Store.start_link(database: ":memory:")

    snapshot = %{
      "key" => "PPL-42",
      "summary" => "Fix extraction",
      "description" => "Spec revision: 1\nAC-1: Check output",
      "comments" => [%{"text" => "Human decision: include empty rows"}],
      "status" => "In Dev",
      "labels" => ["repo-grail", "ai-running"]
    }

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "contract-42",
               issue_key: "PPL-42",
               kind: "SPECIFICATION",
               state: "CONTRACT_DISCUSSING",
               snapshot_json: Jason.encode!(snapshot),
               parent_run_id: "failed-42",
               spec_revision: 2
             })

    assert {:ok, task} =
             TaskLedger.register(store, %{
               task_key: "contract-42:contract-update",
               run_id: run["run_id"],
               stage: "CONTRACT_DISCUSSING",
               role: "specification-author",
               status: "COMPLETE",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-luna",
               reasoning_effort: "high",
               routing_reason: "test",
               prompt_sha256: String.duplicate("a", 64),
               thread_id: "thread-42",
               codex_project_id: "grail-project"
             })

    assert {:ok, task} = TaskLedger.update(store, task["task_key"], %{turn_id: "question-turn"})
    %{store: store, run: run, task: task, snapshot: snapshot}
  end

  test "source digest ignores factory bookkeeping but detects contract edits", %{snapshot: snapshot} do
    updated =
      snapshot
      |> Map.put("status", "Done")
      |> Map.put("labels", ["ai-review"])
      |> Map.update!("comments", &(&1 ++ [%{"text" => "AI FACTORY AUTHORIZED revision 2"}]))

    assert ContractChat.source_sha256(snapshot) == ContractChat.source_sha256(updated)

    refute ContractChat.source_sha256(snapshot) ==
             ContractChat.source_sha256(Map.put(snapshot, "description", "Changed acceptance criterion"))
  end

  test "a bound user reply is recorded once and a different replay is rejected", context do
    %{store: store, run: run, task: task} = context
    assert {:ok, %{question_sha256: question_sha}} = ContractChat.wait(store, run, task, ["Which rows?"])
    assert [%{"question_sha256" => ^question_sha}] = ContractChat.waiting(store)

    receipt = %{
      "thread_id" => "thread-42",
      "codex_project_id" => "grail-project",
      "question_turn_id" => "question-turn",
      "user_turn_id" => "answer-turn",
      "user_message_id" => "answer-message",
      "text" => "Include empty rows."
    }

    assert {:ok, %{result: "CONTRACT_CHAT_REPLY_RECORDED"}} =
             ContractChat.record_user_reply(store, task["task_key"], receipt)

    assert {:ok, %{result: "CONTRACT_CHAT_REPLY_ALREADY_RECORDED"}} =
             ContractChat.record_user_reply(store, task["task_key"], receipt)

    assert {:error, :contract_chat_reply_conflict} =
             ContractChat.record_user_reply(store, task["task_key"], Map.put(receipt, "text", "Ignore rows."))

    assert ContractChat.reply(store, run["run_id"]) == "Include empty rows."
    assert ContractChat.waiting(store) == []
    assert :ok = ContractChat.consume_reply(store, run["run_id"])
    assert ContractChat.reply(store, run["run_id"]) == nil

    assert {:ok, %{result: "CONTRACT_CHAT_REPLY_ALREADY_RECORDED"}} =
             ContractChat.record_user_reply(store, task["task_key"], receipt)
  end

  test "an explicitly authorized cross-chat relay retains both source and destination evidence", context do
    %{store: store, run: run, task: task} = context
    assert {:ok, _} = ContractChat.wait(store, run, task, ["Confirm the revision-8 benchmark change."])

    relay = %{
      "thread_id" => "thread-42",
      "codex_project_id" => "grail-project",
      "question_turn_id" => "question-turn",
      "user_turn_id" => "destination-delegation-turn",
      "user_message_id" => "source-user-message",
      "text" => "Keep the revision-8 benchmark change as written.",
      "reply_transport" => "delegated",
      "source_thread_id" => "orchestrator-thread",
      "source_turn_id" => "source-user-turn",
      "source_user_message_id" => "source-user-message",
      "delegation_item_id" => "destination-function-call-output"
    }

    assert {:ok, %{result: "CONTRACT_CHAT_REPLY_RECORDED"}} =
             ContractChat.record_user_reply(store, task["task_key"], relay)

    chat = Store.one!(store, "SELECT * FROM contract_chats WHERE run_id = ?", [run["run_id"]])
    evidence = Jason.decode!(chat["reply_evidence_json"])
    assert evidence["transport"] == "delegated"
    assert evidence["source_thread_id"] == "orchestrator-thread"
    assert evidence["source_turn_id"] == "source-user-turn"
    assert evidence["source_user_message_id"] == "source-user-message"
    assert evidence["delegation_item_id"] == "destination-function-call-output"
    assert chat["user_turn_id"] == "destination-delegation-turn"
    assert ContractChat.reply(store, run["run_id"]) == relay["text"]

    assert {:error, :contract_chat_reply_conflict} =
             ContractChat.record_user_reply(store, task["task_key"], Map.put(relay, "delegation_item_id", "other-output"))
  end

  test "a changed Jira source invalidates the waiting question", context do
    %{store: store, run: run, task: task, snapshot: snapshot} = context
    assert {:ok, _} = ContractChat.wait(store, run, task, ["Which rows?"])
    assert ContractChat.question_source_current?(store, run["run_id"], snapshot)
    refute ContractChat.question_source_current?(store, run["run_id"], Map.put(snapshot, "description", "New AC"))
    assert :ok = ContractChat.invalidate_question(store, run["run_id"])
    assert ContractChat.waiting(store) == []
    assert {:ok, %{"state" => "CONTRACT_DISCUSSING"}} = RunLedger.get(store, run["run_id"])
    assert {:ok, %{"status" => "RETRY_PENDING"}} = TaskLedger.get(store, task["task_key"])
  end

  test "an authorized revision rearms only the failed writer and keeps its worktree", context do
    %{store: store, run: spec} = context
    assert {:ok, _} = RunLedger.update(store, spec["run_id"], %{state: "DELIVERED"})

    old = Contract.bind("PPL-42", 1, "## Ticket Delivery Contract\n\n**Spec revision:** 1\nOld AC")
    revised = Contract.bind("PPL-42", 2, "## Ticket Delivery Contract\n\n**Spec revision:** 2\nRevised AC")

    snapshot = %{
      "key" => "PPL-42",
      "status" => "In Dev",
      "labels" => ["repo-grail", "ai-ready"],
      "comments" => [
        %{"text" => Contract.draft_comment(revised)},
        %{"text" => Contract.specification_skill_authorization_marker(revised)}
      ]
    }

    assert Contract.authorized?(snapshot, revised)

    checkout = "/tmp/ppl-42-native-worktree"
    sha = String.duplicate("b", 40)

    assert {:ok, _} =
             RunLedger.register(store, %{
               run_id: "failed-42",
               issue_key: "PPL-42",
               kind: "DELIVERY",
               state: "FAILED",
               runtime: "codex-desktop-broker",
               repo_path: "/tmp/grail",
               worktree: checkout,
               branch: "cgable/PPL-42-revised-ac",
               candidate_sha: sha,
               spec_revision: 1,
               contract_sha256: old.sha256,
               contract_markdown: old.markdown,
               snapshot_json: Jason.encode!(context.snapshot),
               implementation_iteration: 4
             })

    assert {:ok, _} =
             TaskLedger.register(store, %{
               task_key: "failed-42:feature-writer",
               run_id: "failed-42",
               stage: "WRITING",
               role: "feature-writer",
               status: "COMPLETE",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-luna",
               reasoning_effort: "medium",
               routing_reason: "test",
               prompt_sha256: String.duplicate("a", 64),
               workspace: checkout
             })

    assert {:ok, failed} = RunLedger.get(store, "failed-42")
    assert {:ok, rearmed} = ContractChat.rearm_delivery(store, BoundWorktree, failed, snapshot, revised, false)
    assert rearmed["state"] == "WRITING"
    assert rearmed["spec_revision"] == 2
    assert rearmed["contract_sha256"] == revised.sha256
    assert rearmed["candidate_sha"] == sha
    assert rearmed["worktree"] == checkout
    assert rearmed["implementation_iteration"] == 4
    assert rearmed["attempt"] == 2

    assert {:ok, %{"status" => "CONSUMED", "failure_code" => "CONTRACT_REVISION_REARMED"}} =
             TaskLedger.get(store, "failed-42:feature-writer")

    assert {:error, :contract_delivery_not_failed} =
             ContractChat.rearm_delivery(store, BoundWorktree, rearmed, snapshot, revised, false)

    assert {:ok, %{run: cancelled}} =
             RunLedger.update(store, "failed-42", %{
               state: "CANCELLED",
               failure_code: inspect({:jira_status_left_factory_scope, "In Dev"})
             })

    assert {:error, :interrupted_rearm_unproven} =
             ContractChat.resume_interrupted_rearm(
               store,
               BoundWorktree,
               cancelled,
               Map.put(snapshot, "labels", ["repo-grail", "ai-blocked"])
             )

    blocked_snapshot = Map.put(snapshot, "labels", ["repo-grail", "ai-ready", "ai-blocked"])
    assert :ok = ContractChat.verify_interrupted_rearm(store, BoundWorktree, cancelled, blocked_snapshot)

    assert {:error, :interrupted_rearm_unproven} =
             ContractChat.resume_interrupted_rearm(store, BoundWorktree, cancelled, blocked_snapshot)

    assert {:error, :interrupted_rearm_unproven} =
             ContractChat.verify_interrupted_rearm(store, BoundWorktree, cancelled, Map.put(blocked_snapshot, "status", "To Do"))

    assert {:ok, resumed} = ContractChat.resume_interrupted_rearm(store, BoundWorktree, cancelled, snapshot)
    assert resumed["state"] == "WRITING"
    assert resumed["spec_revision"] == 2
    assert resumed["candidate_sha"] == sha
    assert resumed["worktree"] == checkout
    assert resumed["implementation_iteration"] == 4
    assert resumed["attempt"] == 2
    assert {:ok, %{"status" => "CONSUMED"}} = TaskLedger.get(store, "failed-42:feature-writer")

    assert {:ok, %{run: dirty}} = RunLedger.update(store, "failed-42", %{state: "FAILED", failure_code: ":worktree_dirty"})
    assert {:ok, resumed_dirty} = ContractChat.resume_interrupted_rearm(store, BoundWorktree, dirty, snapshot)
    assert resumed_dirty["state"] == "WRITING"
    assert resumed_dirty["candidate_sha"] == sha
    assert resumed_dirty["implementation_iteration"] == 4
  end
end
