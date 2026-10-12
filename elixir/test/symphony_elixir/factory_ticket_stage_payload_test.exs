defmodule SymphonyElixir.FactoryTicketStagePayloadTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture, only: [setup_fixture: 1]

  alias SymphonyElixir.Factory.{
    RunLedger,
    Store,
    TicketChat,
    TicketChatCommands,
    TicketContextReader,
    TicketStagePayload
  }

  defmodule NativeReader do
    def read_native_thread(thread, opts) do
      native = Process.get(:stage_payload_native)
      true = thread == Process.get(:stage_payload_thread) and opts[:workspace] == Process.get(:stage_payload_cwd) and opts[:include_latest_turn] and opts[:include_turns] == false
      if mutation = Process.get(:stage_payload_mutation), do: mutation.()
      {:ok, native}
    end
  end

  setup context do
    ctx = setup_fixture(context)
    workflow = Path.join(ctx.root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\n")
    {:ok, locator} = TicketContextReader.bind(ctx.store, "run", ticket_cli_root: File.cwd!(), ticket_workflow: workflow)
    {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    Process.put(:stage_payload_thread, chat["thread_id"])
    Process.put(:stage_payload_cwd, chat["cwd"])
    Store.query!(ctx.store, "UPDATE ticket_chats SET context_reader_json = ? WHERE chat_key = ?", [locator, chat["chat_key"]])
    Process.delete(:stage_payload_mutation)
    {:ok, Map.merge(ctx, %{workflow: workflow, chat: chat})}
  end

  test "preparation preserves both terminal-newline variants and is read-only and retry-stable", ctx do
    before = protected(ctx.store)
    {:ok, reader} = Store.start_read_only(database: ctx.database)

    try do
      for suffix <- ["", "\n"] do
        body = "Revise the contract:\n## Goal\nExact bytes" <> suffix
        Process.put(:stage_payload_native, native(ctx, body))
        assert {:ok, prepared} = TicketStagePayload.prepare(reader, "run", ctx.workflow, reader: NativeReader)
        attrs = prepared.payload_base64 |> Base.decode64!() |> Jason.decode!()
        assert attrs["body"] == body
        assert attrs["operations"] == [%{"operation" => "propose_contract_revision", "markdown" => "## Goal\nExact bytes" <> suffix}]
        assert {:ok, "run", ^attrs} = TicketChatCommands.staging_invocation(prepared.stage_command)
        assert {:ok, ^prepared} = TicketStagePayload.prepare(reader, "run", ctx.workflow, reader: NativeReader)
        assert prepared.status == "PREPARED_ONLY" and prepared.staged == false
      end
    after
      GenServer.stop(reader)
    end

    assert protected(ctx.store) == before
  end

  test "the existing public stage and synthetic completed-turn receipt admit the prepared exact body", ctx do
    body = "Revise the contract:\n## Goal\nLiteral contract\n"
    native = native(ctx, body)
    Process.put(:stage_payload_native, native)
    assert {:ok, prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    attrs = prepared.payload_base64 |> Base.decode64!() |> Jason.decode!()
    assert {:ok, staged} = TicketChatCommands.stage(ctx.store, "run", attrs)
    [turn] = native["latest_turn_observation"]["raw_response"]["data"]
    execution = %{"type" => "commandExecution", "status" => "completed", "exitCode" => 0, "command" => prepared.stage_command, "aggregatedOutput" => Jason.encode!(staged)}

    completed =
      turn
      |> Map.put("status", "completed")
      |> Map.put("completedAt", System.system_time(:millisecond) / 1000 + 1)
      |> Map.update!("items", &(&1 ++ [execution]))

    observed = Map.put(native, "turns", [completed])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}], worker_started: false}} = TicketChatCommands.admit_readback(ctx.store, "run", observed)
    assert {:ok, %{"status" => "ACCEPTED"}} = TicketChatCommands.get(ctx.store, staged["command_key"])
  end

  test "rework recognizes an optional line terminator without altering the stored body", ctx do
    for body <- ["Rework the current candidate.", "Rework the current candidate.\n"] do
      Process.put(:stage_payload_native, native(ctx, body))
      assert {:ok, prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
      attrs = prepared.payload_base64 |> Base.decode64!() |> Jason.decode!()
      assert attrs["body"] == body
      assert attrs["operations"] == [%{"operation" => "request_rework"}]
    end
  end

  test "an unclosed interrupted persisted turn prepares bytes without admitting work", ctx do
    valid = native(ctx, "Rework the current candidate.")
    [turn] = valid["latest_turn_observation"]["raw_response"]["data"]
    unclosed = turn |> Map.put("status", "interrupted") |> Map.put("completedAt", nil)
    Process.put(:stage_payload_native, with_turn(valid, unclosed))
    before = protected(ctx.store)
    assert {:ok, prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    assert prepared.staged == false
    assert protected(ctx.store) == before

    Process.put(:stage_payload_native, with_turn(valid, Map.put(unclosed, "completedAt", 2)))
    assert {:error, :active_direct_native_input_unproven} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
  end

  test "stale, ambiguous, delegated, wrong-route and non-text native evidence fails closed", ctx do
    valid = native(ctx, "Rework the current candidate.")
    raw = valid["latest_turn_observation"]["raw_response"]
    [turn] = raw["data"]
    [user] = turn["items"]

    variants = [
      Map.put(valid, "id", "other"),
      Map.put(valid, "cwd", "/other"),
      Map.put(valid, "projectId", "project"),
      Map.delete(valid, "projectId"),
      put_in(valid, ["latest_turn_observation", "sha256"], "wrong"),
      put_in(valid, ["latest_turn_observation", "observed_at"], "2000-01-01T00:00:00Z"),
      with_turn(valid, Map.put(turn, "status", "completed")),
      with_turn(valid, Map.put(turn, "items", [user, user])),
      with_turn(valid, Map.put(turn, "items", [user, %{"type" => "functionCallOutput", "name" => "send_message_to_thread"}])),
      with_turn(valid, Map.put(turn, "items", [Map.delete(user, "clientId")])),
      with_turn(valid, Map.put(turn, "items", [Map.put(user, "content", [%{"type" => "image"}])]))
    ]

    before = protected(ctx.store)

    for invalid <- variants do
      Process.put(:stage_payload_native, invalid)
      assert {:error, :active_direct_native_input_unproven} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    end

    Process.put(:stage_payload_native, native(ctx, "Please infer what I want."))
    assert {:error, :native_preparation_grammar_unsupported} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    assert protected(ctx.store) == before
  end

  test "a binding change during native read cannot produce a staged payload", ctx do
    Process.put(:stage_payload_native, native(ctx, "Rework the current candidate."))
    Process.put(:stage_payload_mutation, fn -> RunLedger.update(ctx.store, "run", %{candidate_sha: String.duplicate("b", 40)}) end)
    assert {:error, :native_preparation_binding_changed} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
  end

  defp native(ctx, body) do
    turn = %{
      "id" => "active-turn",
      "status" => "inProgress",
      "startedAt" => System.system_time(:millisecond) / 1000 - 1,
      "items" => [%{"type" => "userMessage", "id" => "human-item", "clientId" => "human-client", "content" => [%{"type" => "text", "text" => body}]}]
    }

    with_turn(%{"id" => ctx.chat["thread_id"], "cwd" => ctx.chat["cwd"], "projectId" => nil, "updatedAt" => 1}, turn)
  end

  defp with_turn(native, turn) do
    raw = %{"data" => [turn], "nextCursor" => nil}

    observation = %{
      "mode" => "LATEST_DESC",
      "parameters" => %{"threadId" => native["id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
      "raw_response" => raw,
      "sha256" => Base.encode16(:crypto.hash(:sha256, Jason.encode!(raw)), case: :lower),
      "updated_at" => native["updatedAt"],
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    Map.put(native, "latest_turn_observation", observation)
  end

  defp protected(store), do: Enum.map(~w(runs ticket_chats ticket_chat_commands ticket_chat_inputs events), fn table -> Store.query!(store, "SELECT * FROM #{table}").rows end)
end
