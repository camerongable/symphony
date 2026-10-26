defmodule SymphonyElixir.FactoryTicketContextTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketChatFixture
  alias SymphonyElixir.Factory.{Contract, DesktopRequest, RunLedger, Store, TaskLedger}
  alias SymphonyElixir.Factory.{TicketChatCommands, TicketContext}

  setup :setup_fixture

  test "oversized native recovery receipts and Unicode task failures remain bounded with exact drilldown", ctx do
    register_task(ctx, "run:feature-writer", "feature-writer", %{})
    failure = String.duplicate("Native writer rejected 😀\n", 2000)
    TaskLedger.update(ctx.store, "run:feature-writer", %{failure_code: failure, status: "STALE"})
    {:ok, command} = stage(ctx, "proposal", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    receipt = Jason.encode!(%{"native_turn" => String.duplicate("recovery evidence\n", 2000)})
    Store.query!(ctx.store, "UPDATE ticket_chat_commands SET status = 'ACCEPTED', receipt_json = ? WHERE command_key = ?", [receipt, command["command_key"]])
    before = Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands").rows

    assert {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert byte_size(Jason.encode!(packet)) <= 16_384
    [task] = packet.tasks
    assert byte_size(task["failure_code"]) <= 512
    assert String.valid?(task["failure_code"])
    assert {:ok, failure_page} = TicketContext.details(ctx.store, ctx.chat["chat_key"], task["failure"].artifact_ref)
    assert String.starts_with?(failure, failure_page.text)
    assert failure_page.total_bytes == byte_size(failure)
    [decision] = packet.decisions
    refute Map.has_key?(decision, "receipt_json")
    assert {:ok, receipt_page} = TicketContext.details(ctx.store, ctx.chat["chat_key"], decision["receipt"].artifact_ref)
    assert String.starts_with?(receipt, receipt_page.text)
    assert receipt_page.total_bytes == byte_size(receipt)
    assert {:error, :artifact_not_in_ticket} = TicketContext.details(ctx.store, "other", decision["receipt"].artifact_ref)
    assert before == Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands").rows
    TaskLedger.update(ctx.store, "run:feature-writer", %{failure_code: "changed"})
    assert {:error, :stale_artifact} = TicketContext.details(ctx.store, ctx.chat["chat_key"], task["failure"].artifact_ref)
  end

  test "context is bounded and read-only; UTF-8 details preserve all bytes and detect stale content", ctx do
    markdown = String.duplicate("Long contract 😀\n", 10_000)
    contract = Contract.bind("PPL-123", 1, markdown)
    Store.query!(ctx.store, "UPDATE runs SET contract_markdown = ?, contract_sha256 = ? WHERE run_id = 'run'", [contract.markdown, contract.sha256])
    before = Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events")
    assert {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert packet.ticket_cli.prefix =~ "elixir -pa \"_build/dev/lib/*/ebin\" -S mix factory.ticket"
    assert packet.contract.binding == "EXACT"
    assert byte_size(Jason.encode!(packet)) <= 16_384
    assert byte_size(packet.summary) <= 2048
    ref = packet.contract.artifact.artifact_ref
    assert {:ok, first} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, 0, 20)
    assert String.valid?(first.text)
    assert String.starts_with?(contract.markdown, first.text)
    assert {:ok, next} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, first.next_offset, 80)
    assert String.starts_with?(contract.markdown, first.text <> next.text)
    assert {:ok, %{text: "", next_offset: nil}} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, byte_size(contract.markdown), 10)
    assert before == Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM events")
    Store.query!(ctx.store, "UPDATE runs SET contract_markdown = 'changed' WHERE run_id = 'run'")
    assert {:error, :stale_artifact} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref)
    assert {:error, :stale_artifact} = TicketContext.presentation_data(ctx.store, ctx.chat["chat_key"], %{nested: [packet.contract.artifact]})
    assert {:ok, %{contract: %{binding: "INVALID"}}} = TicketContext.context(ctx.store, "run")
  end

  test "details fail closed for invalid references, other tickets and invalid UTF-8 offsets", ctx do
    Store.query!(ctx.store, "UPDATE runs SET contract_markdown = '😀' WHERE run_id = 'run'")
    {:ok, packet} = TicketContext.context(ctx.store, "run")
    ref = packet.contract.artifact.artifact_ref
    assert {:error, :artifact_not_in_ticket} = TicketContext.details(ctx.store, "other", ref)
    assert {:error, :offset_not_utf8_boundary} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, 1, 4)
    assert {:error, :page_limit_smaller_than_character} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, 0, 1)
    assert {:error, :offset_out_of_range} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, 5)
    assert {:error, :invalid_details_bounds} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref, -1)

    for invalid <- ["not-base64!", Base.url_encode64("{}", padding: false), Base.url_encode64(Jason.encode!(%{kind: "filesystem", id: "/etc/passwd", sha256: "x"}), padding: false)] do
      assert {:error, :invalid_artifact_ref} = TicketContext.details(ctx.store, ctx.chat["chat_key"], invalid)
    end

    assert {:error, :unknown_ticket_chat} = TicketContext.context(ctx.store, "unknown")
  end

  test "journal pages pin the high-water mark and malformed evidence stays visible", ctx do
    for n <- 1..15 do
      Store.query!(ctx.store, "INSERT INTO events(event_type, run_id, payload_json, occurred_at) VALUES ('TEST_PROGRESS', 'run', ?, '2026-10-03')", [Jason.encode!(%{n: n})])
    end

    Store.query!(ctx.store, "UPDATE runs SET ci_evidence_json = 'invalid-json', spec_revision = NULL WHERE run_id = 'run'")
    assert {:ok, context} = TicketContext.context(ctx.store, "run")
    assert length(context.journal) == 8
    assert context.journal_page.older_events
    assert context.ci.artifact.availability == "INVALID_JSON"
    assert context.contract.binding == "UNAVAILABLE"
    assert {:ok, page} = TicketContext.journal(ctx.store, "run", 0, context.journal_page.high_water_id, 5)
    assert page.has_more and length(page.events) == 5
    assert {:ok, next} = TicketContext.journal(ctx.store, "run", page.next_cursor, page.high_water_id, 5)
    assert hd(next.events)["id"] > List.last(page.events)["id"]
    assert {:ok, %{events: [], has_more: false}} = TicketContext.journal(ctx.store, "run", page.high_water_id, page.high_water_id, 5)
    assert {:error, :invalid_journal_bounds} = TicketContext.journal(ctx.store, "run", 0, 100, 21)
    assert {:ok, details} = TicketContext.details(ctx.store, ctx.chat["chat_key"], context.ci.artifact.artifact_ref)
    assert details.text == "invalid-json"
  end

  test "a consumed PASS needs the exact intact receipt, candidate and contract", ctx do
    key = "run:change-verifier:0"

    {:ok, _} =
      TaskLedger.register(ctx.store, %{
        task_key: key,
        run_id: "run",
        stage: "VERIFYING",
        role: "change-verifier",
        status: "CONSUMED",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        routing_reason: "test",
        prompt_sha256: "prompt",
        thread_id: "verifier",
        codex_project_id: "project"
      })

    result = %{"status" => "PASS", "candidate_sha" => String.duplicate("a", 40), "findings" => [], "checks" => []}
    {:ok, _} = TaskLedger.update(ctx.store, key, %{output_json: Jason.encode!(result), turn_id: "verifier-turn"})

    {:ok, request} =
      DesktopRequest.enqueue(ctx.store, %{
        request_key: "verifier-request",
        target_kind: "TASK",
        target_key: key,
        action: "FOLLOWUP",
        codex_project_id: "project",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        existing_thread_id: "verifier",
        title: "Verifier",
        prompt: "Exact review",
        cwd: ctx.root,
        schema: %{},
        metadata: %{stage_prompt_sha256: "prompt", contract_sha256: ctx.contract.sha256, spec_revision: 1}
      })

    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'SUCCEEDED', thread_id = 'verifier', turn_id = 'verifier-turn', output_json = ? WHERE request_key = ?", [
      Jason.encode!(%{result: result}),
      request["request_key"]
    ])

    assert {:ok, %{latest_verifier: %{current_binding: "EXACT", historical_status: "PASS"}}} = TicketContext.context(ctx.store, "run")
    {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert {:ok, receipt_detail} = TicketContext.details(ctx.store, ctx.chat["chat_key"], packet.latest_verifier.receipt.artifact_ref)
    assert Jason.decode!(receipt_detail.text)["result"] == result
    Store.query!(ctx.store, "UPDATE runs SET spec_revision = 2 WHERE run_id = 'run'")
    assert {:ok, %{latest_verifier: %{current_binding: "UNPROVEN_OR_STALE", historical_status: "PASS"}}} = TicketContext.context(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE runs SET spec_revision = 1 WHERE run_id = 'run'")
    Store.query!(ctx.store, "UPDATE desktop_requests SET prompt = 'tampered' WHERE request_key = ?", [request["request_key"]])
    assert {:ok, %{latest_verifier: %{current_binding: "UNPROVEN_OR_STALE"}}} = TicketContext.context(ctx.store, "run")
    Store.query!(ctx.store, "UPDATE desktop_requests SET metadata_json = 'malformed' WHERE request_key = ?", [request["request_key"]])
    assert {:ok, %{latest_verifier: %{current_binding: "UNPROVEN_OR_STALE"}}} = TicketContext.context(ctx.store, "run")
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "READY_FOR_REVIEW"})
    assert {:ok, %{next_action: action}} = TicketContext.context(ctx.store, "run")
    assert action =~ "Review"
  end

  test "all collections have scoped paging; writer and validator evidence survive long histories", ctx do
    register_task(ctx, "run:feature-writer", "feature-writer", %{"status" => "CONTINUE", "summary" => "Completed extraction", "remaining_criteria" => String.duplicate("remaining ", 1000)})
    register_task(ctx, "run:manual-validator", "manual-validator", %{"status" => "PASS", "candidate_sha" => String.duplicate("a", 40)})
    register_worker_evidence(ctx, "worker-request-1", "run:feature-writer", "2026-10-08T00:00:00Z", nil)
    register_worker_evidence(ctx, "worker-request-2", "run:feature-writer", "2026-10-08T00:00:01Z", "2026-10-08T00:00:02Z")
    for n <- 1..9, do: register_task(ctx, "run:task-#{n}", "feature-planner", %{})
    for n <- 1..5, do: TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q#{n}", "body" => "Choose #{n}?", "answers" => %{"yes" => true}})
    {:ok, _} = stage(ctx, "proposal", "Rework the current candidate.", [%{"operation" => "request_rework"}])
    assert {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert packet.collections["tasks"]["total"] == 11 and length(packet.tasks) == 6
    assert packet.collections["workers"]["total"] == 2
    assert packet.collections["questions"]["total"] == 5 and length(packet.open_questions) == 4
    assert packet.work_progress["summary"] == "Completed extraction"
    assert packet.work_progress["remaining_criteria"].omitted
    assert packet.manual_validation.status == "PASS"
    assert packet.manual_validation.publication == "NOT_PROVEN_BY_VALIDATOR_OUTPUT"

    rows_before_replay = %{
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      workers: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
      questions: Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows,
      commands: Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
      events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
    }

    assert {:ok, replay} = TicketContext.replay(ctx.store, "run")
    task_page = replay.records["tasks"]
    assert length(task_page.records) == 10
    assert task_page.has_more
    assert task_page.next_cursor == List.last(task_page.records)["cursor"]
    assert task_page.high_water == replay.high_water.collections["tasks"]
    assert replay.uncertainty |> Enum.any?(&(&1 == "1 of 11 tasks records remain beyond the first bounded page."))

    for kind <- ~w(workers questions commands receipts) do
      refute replay.records[kind].has_more
      refute Enum.any?(replay.uncertainty, &String.contains?(&1, "#{kind} records remain"))
    end

    assert {:ok, replay_again} = TicketContext.replay(ctx.store, "run")
    assert replay_again.high_water == replay.high_water
    assert replay_again.records["tasks"].next_cursor == task_page.next_cursor
    assert replay_again.records["tasks"].records == task_page.records

    assert %{
             tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
             workers: Store.query!(ctx.store, "SELECT * FROM worker_evidence WHERE run_id = 'run' ORDER BY request_key").rows,
             questions: Store.query!(ctx.store, "SELECT * FROM ticket_chat_questions WHERE run_id = 'run' ORDER BY question_key").rows,
             commands: Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
             events: Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows
           } == rows_before_replay

    for kind <- ~w(tasks workers questions commands) do
      high_water = packet.collections[kind]["high_water"]
      assert {:ok, page} = TicketContext.records(ctx.store, "run", kind, 0, high_water, 2)
      assert page.records != []
      assert {:ok, _} = TicketContext.details(ctx.store, ctx.chat["chat_key"], hd(page.records)["artifact"].artifact_ref)
    end

    {:ok, worker_page} = TicketContext.records(ctx.store, "run", "workers", 0, packet.collections["workers"]["high_water"], 1)
    assert worker_page.has_more
    assert hd(worker_page.records)["created_at"] == "2026-10-08T00:00:00Z"
    assert hd(worker_page.records)["consumed_at"] == nil
    refute Map.has_key?(hd(worker_page.records), "updated_at")
    {:ok, next_worker_page} = TicketContext.records(ctx.store, "run", "workers", worker_page.next_cursor, worker_page.high_water, 1)
    assert hd(next_worker_page.records)["consumed_at"] == "2026-10-08T00:00:02Z"

    assert {:ok, page} = TicketContext.records(ctx.store, "run", "tasks", 0, packet.collections["tasks"]["high_water"], 2)
    assert page.has_more
    assert {:ok, next} = TicketContext.records(ctx.store, "run", "tasks", page.next_cursor, page.high_water, 2)
    assert hd(next.records)["cursor"] > List.last(page.records)["cursor"]
    Store.query!(ctx.store, "UPDATE runs SET spec_revision = 2 WHERE run_id = 'run'")
    assert {:ok, questions} = TicketContext.records(ctx.store, "run", "questions", 0, packet.collections["questions"]["high_water"], 10)
    assert length(questions.records) == 5
    assert Enum.all?(questions.records, &(&1["binding"] == "STALE" and &1["binding_json"] != nil))
    assert {:ok, _} = TicketContext.details(ctx.store, ctx.chat["chat_key"], hd(questions.records)["answers"].artifact_ref)
    assert {:error, :unsupported_record_collection} = TicketContext.records(ctx.store, "run", "files", 0, 1, 1)
    assert {:error, :invalid_record_bounds} = TicketContext.records(ctx.store, "run", "tasks", -1, 1, 1)
    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = 'broken' WHERE task_key = 'run:feature-writer'")
    Store.query!(ctx.store, "UPDATE runs SET state = 'AWAITING_CONTRACT_INPUT' WHERE run_id = 'run'")
    assert {:ok, %{next_action: action}} = TicketContext.context(ctx.store, "run")
    assert action =~ "read-backed answer"
  end

  test "artifact references cannot turn missing records or parent receipts into task evidence", ctx do
    assert {:error, :artifact_not_in_ticket} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref("task", "missing", "{}"))
    request = Store.one!(ctx.store, "SELECT * FROM desktop_requests WHERE request_key = ?", [ctx.chat["create_request_key"]])
    assert {:error, :artifact_not_in_ticket} = TicketContext.details(ctx.store, ctx.chat["chat_key"], ref("receipt", request["request_key"], request["output_json"]))
    Store.query!(ctx.store, "UPDATE runs SET issue_key = ? WHERE run_id = 'run'", [String.duplicate("x", 20_000)])
    assert {:error, :context_identity_exceeds_budget} = TicketContext.context(ctx.store, "run")
  end

  test "presentation hashing preserves current evidence while rejecting stale nested artifacts", ctx do
    register_task(ctx, "run:feature-writer", "feature-writer", %{"status" => "CONTINUE", "checks" => ["tested"]})
    {:ok, _} = TicketChatCommands.open_question(ctx.store, "run", %{"question_key" => "Q", "body" => "Choose", "answers" => %{"yes" => true}})
    {:ok, packet} = TicketContext.context(ctx.store, "run")
    assert hd(packet.open_questions)["binding"] == "CURRENT"
    assert {:ok, material} = TicketContext.presentation_data(ctx.store, ctx.chat["chat_key"], packet)
    assert hd(material.tasks)["evidence"].content["checks"] == ["tested"]
    assert {:ok, answer_schema} = TicketContext.details(ctx.store, ctx.chat["chat_key"], hd(packet.open_questions)["answers"].artifact_ref)
    assert Jason.decode!(answer_schema.text) == %{"yes" => true}
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("b", 40)])
    assert {:ok, changed} = TicketContext.context(ctx.store, "run")
    assert hd(changed.open_questions)["binding"] == "STALE"
    Store.query!(ctx.store, "UPDATE factory_tasks SET output_json = '{}' WHERE task_key = 'run:feature-writer'")
    assert {:error, :stale_artifact} = TicketContext.presentation_data(ctx.store, ctx.chat["chat_key"], packet)
  end

  defp register_task(ctx, key, role, output) do
    {:ok, _} =
      TaskLedger.register(ctx.store, %{
        task_key: key,
        run_id: "run",
        stage: "WRITING",
        role: role,
        status: "CONSUMED",
        model_provider: "codex",
        model_class: "fast",
        model: "gpt-6-luna",
        reasoning_effort: "medium",
        routing_reason: "fixture",
        prompt_sha256: "prompt"
      })

    TaskLedger.update(ctx.store, key, %{output_json: Jason.encode!(output)})
  end

  defp ref(kind, id, raw) do
    digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    %{kind: kind, id: id, sha256: digest} |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  defp register_worker_evidence(ctx, request_key, task_key, created_at, consumed_at) do
    reservation_key = "#{request_key}:reservation"

    Store.query!(
      ctx.store,
      "INSERT INTO workspace_access(reservation_key, run_id, task_key, request_key, mode, generation, canonical_path, git_dir, common_dir, binding_json, acquired_at) VALUES (?, 'run', ?, ?, 'SOURCE', 1, ?, ?, ?, '{}', ?)",
      [
        reservation_key,
        task_key,
        request_key,
        Path.join(ctx.root, request_key),
        Path.join(ctx.root, request_key <> ".git"),
        Path.join(ctx.root, request_key <> ".common"),
        created_at
      ]
    )

    Store.query!(
      ctx.store,
      "INSERT INTO worker_evidence(request_key, task_key, run_id, reservation_key, binding_json, binding_sha256, status, owner_id, output_json, created_at, consumed_at) VALUES (?, ?, 'run', ?, '{}', 'digest', 'RESULT_RECORDED', 'fixture-owner', '{}', ?, ?)",
      [
        request_key,
        task_key,
        reservation_key,
        created_at,
        consumed_at
      ]
    )
  end
end
