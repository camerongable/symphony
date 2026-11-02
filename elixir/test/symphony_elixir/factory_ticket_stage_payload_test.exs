defmodule SymphonyElixir.FactoryTicketStagePayloadTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture, only: [setup_fixture: 1]

  alias SymphonyElixir.Factory.{
    BrokerRuntime,
    RunLedger,
    Store,
    TicketChat,
    TicketChatCommands,
    TicketContextReader,
    TicketStagePayload
  }

  @launcher Path.expand("../../scripts/factory-broker", __DIR__)
  @selector "/Users/cgable/Library/LaunchAgents/com.cgable.symphony-factory.plist"

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
    cli_root = Path.join(ctx.root, "ticket-cli")
    File.mkdir_p!(Path.join(cli_root, "scripts"))
    File.mkdir_p!(Path.join(cli_root, "lib/mix/tasks"))
    File.cp!(@launcher, Path.join(cli_root, "scripts/factory-broker"))
    File.chmod!(Path.join(cli_root, "scripts/factory-broker"), 0o755)
    File.cp!(Path.expand("../../mise.toml", __DIR__), Path.join(cli_root, "mise.toml"))
    File.cp!(Path.expand("../../lib/mix/tasks/factory.ticket.ex", __DIR__), Path.join(cli_root, "lib/mix/tasks/factory.ticket.ex"))
    {:ok, locator} = TicketContextReader.bind(ctx.store, "run", ticket_cli_root: cli_root, ticket_workflow: workflow)
    {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    Process.put(:stage_payload_thread, chat["thread_id"])
    Process.put(:stage_payload_cwd, chat["cwd"])
    Store.query!(ctx.store, "UPDATE ticket_chats SET context_reader_json = ? WHERE chat_key = ?", [locator, chat["chat_key"]])
    Process.delete(:stage_payload_mutation)
    {:ok, Map.merge(ctx, %{workflow: workflow, chat: chat, cli_root: cli_root})}
  end

  test "preparation preserves both terminal-newline variants and is read-only and retry-stable", ctx do
    before = protected(ctx.store)
    {:ok, reader} = Store.start_read_only(database: ctx.database)

    try do
      for suffix <- ["", "\n"] do
        body = "Revise the contract:\n## Goal\nExact bytes µ \"quoted\" 'single' $(not-code)" <> suffix
        Process.put(:stage_payload_native, native(ctx, body))
        assert {:ok, prepared} = TicketStagePayload.prepare(reader, "run", ctx.workflow, reader: NativeReader)
        assert prepared.stage_command =~ "./scripts/factory-broker ticket stage"
        attrs = prepared.payload_base64 |> Base.decode64!() |> Jason.decode!()
        assert attrs["body"] == body
        assert attrs["operations"] == [%{"operation" => "propose_contract_revision", "markdown" => "## Goal\nExact bytes µ \"quoted\" 'single' $(not-code)" <> suffix}]
        assert {:ok, "run", ^attrs} = TicketChatCommands.staging_invocation(prepared.stage_command)
        assert {:ok, ^prepared} = TicketStagePayload.prepare(reader, "run", ctx.workflow, reader: NativeReader)
        assert prepared.status == "PREPARED_ONLY" and prepared.staged == false
      end
    after
      GenServer.stop(reader)
    end

    assert protected(ctx.store) == before
  end

  @tag :parent_identity
  test "preparation accepts an attested parent without ACK and ignores presentation updates during its read", ctx do
    Store.query!(ctx.store, "UPDATE desktop_requests SET status='THREAD_RECORDED',turn_id=NULL,output_json=NULL WHERE target_kind='TICKET_CHAT' AND action='CREATE'")
    Process.put(:stage_payload_native, native(ctx, "Rework the current candidate."))
    before = protected(ctx.store)
    assert {:ok, prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    assert prepared.staged == false
    assert protected(ctx.store) == before

    Process.put(:stage_payload_mutation, fn ->
      Store.query!(ctx.store, "UPDATE ticket_chats SET context_sequence=context_sequence+1,presentation_sha256='presentation',updated_at='later' WHERE chat_key=?", [ctx.chat["chat_key"]])

      Store.query!(ctx.store, "UPDATE desktop_requests SET status='SUCCEEDED',turn_id='ack',output_json=? WHERE target_kind='TICKET_CHAT' AND action='CREATE'", [
        Jason.encode!(%{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []})
      ])
    end)

    assert {:ok, ^prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
  end

  test "the existing public stage and synthetic completed-turn receipt admit the prepared exact body", ctx do
    body = "Revise the contract:\n## Goal\nLiteral contract\n"
    native = native(ctx, body)
    Process.put(:stage_payload_native, native)
    assert {:ok, prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    attrs = prepared.payload_base64 |> Base.decode64!() |> Jason.decode!()

    {stage_output, 0} = with_private_launcher(ctx, fn -> run_cli(prepared.stage_command, prepared.cwd) end)

    staged = Jason.decode!(stage_output)
    assert staged["status"] == "PENDING"
    assert {:ok, stored} = TicketChatCommands.get(ctx.store, staged["command_key"])
    assert Jason.decode!(stored["payload_json"]) == attrs["operations"]
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

  test "a stored parent identity change during native read cannot produce a staged payload", ctx do
    Process.put(:stage_payload_native, native(ctx, "Rework the current candidate."))
    Process.put(:stage_payload_mutation, fn -> Store.query!(ctx.store, "UPDATE desktop_requests SET verified_cwd=? WHERE target_kind='TICKET_CHAT' AND action='CREATE'", [ctx.root]) end)
    assert {:error, :ticket_chat_parent_not_ready} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM ticket_chat_commands")["count"] == 0
  end

  @tag :ticket_deployed_cli
  test "the deployed wrapper reads and prepares with a stale local build while retaining historical locator bytes", ctx do
    body = "Rework the current candidate.\n"
    Process.put(:stage_payload_native, native(ctx, body))
    {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    locator = Jason.decode!(chat["context_reader_json"])
    encoded = locator["arguments"] |> Jason.encode!() |> Base.encode64()
    old_command = "mise exec -- elixir -pa \"_build/dev/lib/*/ebin\" -e 'Mix.start(); Mix.Tasks.Factory.Ticket.run(Jason.decode!(Base.decode64!(\"#{encoded}\")))'"
    historical = locator |> Map.put("command", old_command) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE ticket_chats SET context_reader_json = ? WHERE chat_key = ?", [historical, chat["chat_key"]])
    assert {:ok, ^historical} = TicketContextReader.bind(ctx.store, "run", ticket_cli_root: ctx.cli_root, ticket_workflow: ctx.workflow)
    assert {:ok, projected} = TicketContextReader.execution_locator(historical)
    executable = Jason.decode!(projected)
    assert executable["command"] == "./scripts/factory-broker ticket context run --workflow #{ctx.workflow}"
    assert {:ok, prepared} = TicketStagePayload.prepare(ctx.store, "run", ctx.workflow, reader: NativeReader)
    before = protected(ctx.store)
    stale = Path.join(ctx.cli_root, "_build/dev/lib/symphony_elixir/ebin")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "Elixir.Mix.Tasks.Factory.Ticket.beam"), "stale unrelated build")

    executor = fn args, _store, _factory ->
      assert args == ["prepare-ticket-stage", "run", "--workflow", ctx.workflow]
      {:ok, prepared}
    end

    start_supervised!({BrokerRuntime, name: nil, store: ctx.store, factory: %SymphonyElixir.Config.Schema.Factory{database: ctx.database}, executor: executor})

    with_private_launcher(ctx, fn ->
      {old_output, old_code} = run_cli(old_command, ctx.cli_root)
      assert old_code != 0
      refute old_output =~ "\"identity\""
      {context_output, 0} = run_cli(executable["command"], ctx.cli_root)
      context = Jason.decode!(context_output)
      assert context["ticket_cli"]["prefix"] == "./scripts/factory-broker ticket"
      ref = context["contract"]["artifact"]["artifact_ref"]
      {details, 0} = run_cli("./scripts/factory-broker ticket details run #{ref} --offset 0 --limit 4096 --workflow #{ctx.workflow}", ctx.cli_root)
      assert Jason.decode!(details)["sha256"] == context["contract"]["artifact"]["sha256"]
      {prepared_output, 0} = run_cli("./scripts/factory-broker ticket prepare-stage run --workflow #{ctx.workflow}", ctx.cli_root)
      response = Jason.decode!(prepared_output)
      assert response["stage_command"] == prepared.stage_command
      assert response["staged"] == false
      assert protected(ctx.store) == before
      attrs = response["payload_base64"] |> Base.decode64!() |> Jason.decode!()
      assert attrs["body"] == body
      assert {:ok, "run", ^attrs} = TicketChatCommands.staging_invocation(response["stage_command"])
      {staged_output, 0} = run_cli(response["stage_command"], response["cwd"])
      assert Jason.decode!(staged_output)["status"] == "PENDING"
    end)

    assert Store.one!(ctx.store, "SELECT context_reader_json FROM ticket_chats WHERE chat_key = ?", [chat["chat_key"]])["context_reader_json"] == historical
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM ticket_chat_commands")["n"] == 1
  end

  @tag :ticket_deployed_cli
  test "the deployed ticket selector refuses missing foreign and inherited build routes without local fallback", ctx do
    with_private_launcher(ctx, fn ->
      for build <- ["relative", Path.join(ctx.root, "absent"), compiled_build() <> "/../test"] do
        {output, status} = run_cli("./scripts/factory-broker ticket --help", ctx.cli_root, [{"MIX_BUILD_PATH", build}])
        assert status != 0
        assert output =~ "exact deployed build"
      end

      File.rm!(Path.join(ctx.root, "deployed.plist"))
      File.mkdir_p!(Path.join(ctx.cli_root, "_build"))
      File.ln_s!(compiled_build(), Path.join(ctx.cli_root, "_build/dev"))
      {_output, status} = run_cli("./scripts/factory-broker ticket --help", ctx.cli_root)
      assert status != 0
      other = Path.join(ctx.root, "wrong-cwd")
      File.mkdir_p!(other)
      {_output, status} = run_cli("./scripts/factory-broker ticket --help", other)
      assert status != 0
    end)

    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM ticket_chat_commands")["n"] == 0
  end

  @tag :ticket_deployed_cli
  test "context projection rejects changed nonexecutable symlinked and foreign-cwd launchers", ctx do
    {:ok, chat} = TicketChat.for_run(ctx.store, "run")
    locator = chat["context_reader_json"]
    path = Path.join(ctx.cli_root, "scripts/factory-broker")
    original = File.read!(path)
    File.write!(path, original <> "\nexit 0\n")
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.execution_locator(locator)
    assert TicketContextReader.instructions(locator) == TicketContextReader.instructions(nil)
    assert {:ok, _} = TicketContextReader.historical_locator(locator)
    File.write!(path, original)
    File.chmod!(path, 0o644)
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.execution_locator(locator)
    File.chmod!(path, 0o755)
    File.rm!(path)
    File.ln_s!(@launcher, path)
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.execution_locator(locator)
    File.rm!(path)
    File.write!(path, original)
    File.chmod!(path, 0o755)
    foreign = locator |> Jason.decode!() |> Map.put("cwd", ctx.root) |> Jason.encode!()
    assert {:error, :ticket_context_reader_unavailable} = TicketContextReader.execution_locator(foreign)
    assert {:ok, ^locator} = TicketContextReader.execution_locator(locator)
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

  defp compiled_build, do: :symphony_elixir |> Application.app_dir() |> Path.dirname() |> Path.dirname()

  defp run_cli(command, cwd, env \\ [{"MIX_BUILD_PATH", nil}]),
    do:
      System.cmd("/usr/bin/sandbox-exec", ["-p", "(version 1) (allow default) (deny network*)", "/bin/zsh", "-lc", command],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"MISE_TRUSTED_CONFIG_PATHS", cwd} | env]
      )

  defp with_private_launcher(ctx, fun) do
    path = Path.join(ctx.cli_root, "scripts/factory-broker")
    original = File.read!(path)
    assert length(String.split(original, @selector)) == 2
    selector = Path.join(ctx.root, "deployed.plist")

    File.write!(
      selector,
      "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>EnvironmentVariables</key><dict><key>MIX_BUILD_PATH</key><string>#{compiled_build()}</string></dict></dict></plist>"
    )

    patched = String.replace(original, @selector, selector, global: false)
    assert String.replace(patched, selector, @selector, global: false) == original
    # The fixture redirects only the trusted plist literal, never adds a production selector override.
    File.write!(path, patched)

    try do
      fun.()
    after
      File.write!(path, original)
    end
  end
end
