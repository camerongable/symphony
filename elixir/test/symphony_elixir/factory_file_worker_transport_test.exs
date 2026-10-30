defmodule SymphonyElixir.FactoryFileWorkerTransportTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{Store, TicketWorkerRunner, WorkerEvidence, WorkerFileTools, WorkspaceAccess}
  setup :setup_fixture

  for entry <- ~w(start resume) do
    @tag :native_worker_origin
    test "explicit FILE_SOURCE native #{entry} retains its seven tools and exact routed storage", ctx do
      files = starting_files(ctx)
      descriptor = %{"version" => 1, "codex_home" => Path.join(ctx.root, "codex-B"), "sqlite_home" => Path.join(ctx.root, "sqlite-B")}
      default = Path.join(ctx.root, "sqlite-A")

      for path <- [default, descriptor["codex_home"], descriptor["sqlite_home"]] do
        File.mkdir!(path)
        File.chmod!(path, 0o700)
      end

      File.write!(Path.join(default, "marker"), "A")
      File.write!(Path.join(descriptor["sqlite_home"], "marker"), "B")
      script = Path.expand("test/support/native_origin_worker_server.py")
      trace = Path.join(ctx.root, "origin.trace")
      control = Path.join(ctx.root, "origin-control.json")
      File.write!(control, "{}")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(ctx.root, "workspaces"),
        codex_command: "/usr/bin/python3 -I -S -B #{script} #{trace} #{default} #{control} app-server"
      )

      assert {:ok, route} = SymphonyElixir.Factory.NativeRuntimeRoute.validate(descriptor)
      bind = fn thread -> WorkerEvidence.bind_thread(ctx.store, files.key, thread, TicketWorkerRunner.policy("SOURCE", ctx.path)) end
      resume = if unquote(entry) == "resume", do: "worker-B"
      options = [worker_access: "FILE_SOURCE", worker_files: files, native_runtime: route, model: "gpt-6-luna", reasoning_effort: "medium", resume_thread_id: resume, on_thread_created: bind]
      assert {:ok, session} = AppServer.start_session(ctx.path, options)

      try do
        assert session.native_runtime === route
        requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
        request = Enum.find(requests, &(&1["method"] == "thread/" <> unquote(entry)))
        assert request["params"]["permissions"] == "symphony_ticket_file_source_v1"
        if unquote(entry) == "start", do: assert(request["params"]["dynamicTools"] == WorkerFileTools.tool_specs()), else: refute(Map.has_key?(request["params"], "dynamicTools"))
        assert session.dynamic_tool_binding.tool_specs == WorkerFileTools.tool_specs()

        for actor <- Enum.filter(requests, &(&1["method"] == "actor")) do
          assert actor["codex_home"] == descriptor["codex_home"]
          assert actor["sqlite_home"] == descriptor["sqlite_home"]
        end
      after
        assert {:ok, _stop} = AppServer.stop_session(session)
      end
    end
  end

  for entry <- ~w(start resume) do
    @tag :file_revision
    @revision_entry entry
    test "restricted native #{@revision_entry} keeps seven tools and restores exact base bytes using current-file CAS", ctx do
      Store.query!(ctx.store, "INSERT INTO ticket_review_bases VALUES ('run','refs/remotes/origin/master',?,'now')", [ctx.sha])
      files = starting_files(ctx)
      File.write!(Path.join(ctx.path, "fixture.txt"), "dirty\r\n")
      for name <- ~w(logging.go logging_test.go BUILD), do: File.write!(Path.join(ctx.path, name), "preserve #{name}\n")
      trace = configure_server(Map.put(ctx, :revision_restore, true))
      policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
      assert policy["file_tools_sha256"] == "44f58a614a4437a56c277c24b295d0cd8d529b3c197c9a820dda7dd7516a135e"
      bind = fn thread -> WorkerEvidence.bind_thread(ctx.store, files.key, thread, policy) end
      resume = if @revision_entry == "resume", do: "file-worker"

      options = [
        worker_access: "FILE_SOURCE",
        worker_files: files,
        model: "gpt-6-luna",
        reasoning_effort: "medium",
        on_thread_created: bind,
        resume_thread_id: resume
      ]

      assert {:ok, session} = AppServer.start_session(ctx.path, options)

      try do
        process = %{"pid" => session.metadata.codex_app_server_pid, "invocation_nonce" => session.worker_invocation}
        assert {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, files.key, process)

        callback = fn
          %{event: :session_started, thread_id: thread, turn_id: turn} -> WorkerEvidence.bind_turn(ctx.store, files.key, thread, turn)
          _ -> :ok
        end

        options = [event_scope: :exact_turn, on_message: callback]
        assert {:ok, %{turn_id: "file-turn"}} = AppServer.run_turn(session, "Restore the base preimage only", %Issue{}, options)
        assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
        for name <- ~w(logging.go logging_test.go BUILD), do: assert(File.read!(Path.join(ctx.path, name)) == "preserve #{name}\n")
        requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
        params = Enum.find(requests, &(&1["method"] == "thread/" <> @revision_entry))["params"]

        if @revision_entry == "start" do
          assert params["dynamicTools"] == WorkerFileTools.tool_specs()
        else
          refute Map.has_key?(params, "dynamicTools")
        end

        assert Jason.decode!(File.read!(trace <> ".catalog")) == WorkerFileTools.tool_specs()
        assert params["permissions"] == "symphony_ticket_file_source_v1"
        assert session.thread_sandbox == "read-only"
        assert Enum.any?(requests, &(&1["id"] == 79 and get_in(&1, ["result", "success"]) == false))
        assert Enum.any?(requests, &(&1["id"] == 80 and get_in(&1, ["result", "success"]) == true))
        assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM worker_file_operations")["n"] == 1
      after
        assert {:ok, %{"exit_status" => 143}} = AppServer.stop_session(session)
      end
    end
  end

  test "file-source startup and retained sessions remain fenced before process and model effects" do
    path = Path.join(System.tmp_dir!(), "file-worker-fenced-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: System.tmp_dir!(), codex_command: "not-a-real-codex-command")

    assert {:error, :file_worker_capability_required} =
             AppServer.start_session(path, worker_access: "FILE_SOURCE", model: "gpt-6-luna", reasoning_effort: "low")

    session = %{worker_policy: AppServer.worker_policy("FILE_SOURCE", path)}
    assert {:error, :file_worker_capability_required} = AppServer.run_turn(session, "Do not run", %Issue{})
  end

  test "a bound read-only worker edits through the controller file tools without native commands", ctx do
    files = starting_files(ctx)
    trace = configure_server(ctx)
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
    bind = fn thread -> WorkerEvidence.bind_thread(ctx.store, files.key, thread, policy) end

    assert {:ok, session} =
             AppServer.start_session(ctx.path,
               worker_access: "FILE_SOURCE",
               worker_files: files,
               model: "gpt-6-luna",
               reasoning_effort: "medium",
               on_thread_created: bind
             )

    try do
      process = %{"pid" => session.metadata.codex_app_server_pid, "invocation_nonce" => session.worker_invocation}
      assert {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, files.key, process)

      callback = fn
        %{event: :session_started, thread_id: thread, turn_id: turn} -> WorkerEvidence.bind_turn(ctx.store, files.key, thread, turn)
        _ -> :ok
      end

      options = [event_scope: :exact_turn, on_message: callback]
      assert {:ok, %{turn_id: "file-turn"}} = AppServer.run_turn(session, "Fixture edit", %Issue{}, options)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
      assert session.thread_sandbox == "read-only"
      assert session.worker_policy["source_access"] == "read"
      assert session.dynamic_tool_binding.tool_specs == WorkerFileTools.tool_specs()
      args = File.read!(trace <> ".args")
      assert args =~ "features.shell_tool=false"
      assert args =~ "features.unified_exec=false"
      assert args =~ "features.code_mode_host=true"
      assert args =~ "plugins.openai-developers@openai-curated-remote.enabled=false"
      assert args =~ ~s(model_reasoning_effort="medium")
      requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      start = Enum.find(requests, &(&1["method"] == "thread/start"))["params"]
      assert start["dynamicTools"] == WorkerFileTools.tool_specs()
      assert start["permissions"] == "symphony_ticket_file_source_v1"
      assert start["approvalPolicy"] == "never"
      assert Enum.any?(requests, &(&1["id"] == 77 and get_in(&1, ["result", "success"]) == true))
    after
      assert {:ok, %{"exit_status" => 143}} = AppServer.stop_session(session)
    end
  end

  @tag :runtime_startup_sanity
  test "effective capability drift rejects startup even on an unfamiliar runtime", ctx do
    files = starting_files(ctx)
    trace = configure_server(ctx)
    config_path = trace <> ".config"
    config = Jason.decode!(File.read!(config_path))
    initialization = Jason.decode!(File.read!(trace <> ".initialize"))
    initialization = put_in(initialization, ["result", "userAgent"], "symphony-orchestrator/0.166.0-alpha.5.1 (fixture)")
    File.write!(trace <> ".initialize", Jason.encode!(initialization))
    File.write!(config_path, Jason.encode!(put_in(config, ["config", "features", "shell_tool"], true)))

    assert {:error, :file_worker_effective_capabilities_mismatch} =
             AppServer.start_session(ctx.path, worker_access: "FILE_SOURCE", worker_files: files, model: "gpt-6-luna", reasoning_effort: "medium")

    refute File.read!(trace) =~ "thread/start"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    File.write!(config_path, Jason.encode!(config))
    initialization = Jason.decode!(File.read!(trace <> ".initialize"))
    initialization = put_in(initialization, ["result", "userAgent"], "other/0.161.0 (fixture)")
    File.write!(trace <> ".initialize", Jason.encode!(initialization))

    assert {:error, :worker_runtime_unsupported} =
             AppServer.start_session(ctx.path, worker_access: "FILE_SOURCE", worker_files: files, model: "gpt-6-luna", reasoning_effort: "medium")

    refute File.read!(trace) =~ "thread/start"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "a resumed worker receives only current file tools and rechecks capabilities before its turn", ctx do
    files = starting_files(ctx)
    trace = configure_server(ctx)
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
    bind = fn thread -> WorkerEvidence.bind_thread(ctx.store, files.key, thread, policy) end

    assert {:ok, session} =
             AppServer.start_session(ctx.path,
               worker_access: "FILE_SOURCE",
               worker_files: files,
               model: "gpt-6-luna",
               reasoning_effort: "medium",
               resume_thread_id: "file-worker",
               on_thread_created: bind
             )

    try do
      process = %{"pid" => session.metadata.codex_app_server_pid, "invocation_nonce" => session.worker_invocation}
      assert {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, files.key, process)
      config_path = trace <> ".config"
      assert {:error, :file_worker_session_not_owned} = AppServer.run_turn(%{session | port: nil}, "No edit", %Issue{})
      config = Jason.decode!(File.read!(config_path))
      File.write!(config_path, Jason.encode!(put_in(config, ["config", "features", "unified_exec"], true)))
      result = AppServer.run_turn(session, "No edit", %Issue{}, event_scope: :exact_turn)
      assert {:error, :file_worker_effective_capabilities_mismatch} = result

      requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      resume = Enum.find(requests, &(&1["method"] == "thread/resume"))["params"]
      refute Map.has_key?(resume, "dynamicTools")
      assert resume["permissions"] == "symphony_ticket_file_source_v1"
      refute Enum.any?(requests, &(&1["method"] == "turn/start"))
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    after
      assert {:ok, %{"exit_status" => 143}} = AppServer.stop_session(session)
    end
  end

  defp starting_files(ctx) do
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "reservation:request",
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "input_sha256" => String.duplicate("p", 64),
        "owner_id" => "owner",
        "schema" => %{},
        "policy" => policy
      })

    {:ok, files} = WorkerFileTools.bind(ctx.store, "reservation:request", "owner")
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, files.key)
    files
  end

  defp configure_server(ctx) do
    binary = Path.join(ctx.root, "fake-codex")
    trace = Path.join(ctx.root, "codex.trace")

    flags = %{
      "shell_tool" => false,
      "unified_exec" => false,
      "code_mode_host" => true,
      "apps" => false,
      "multi_agent" => false,
      "browser_use" => false,
      "browser_use_external" => false,
      "computer_use" => false,
      "image_generation" => false,
      "request_permissions_tool" => false,
      "hooks" => false
    }

    config = Jason.encode!(%{"config" => %{"mcp_servers" => %{}, "plugins" => %{}, "features" => flags, "web_search" => "disabled"}})
    File.write!(trace <> ".config", config)

    runtime = %{
      "codexHome" => System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
      "platformFamily" => "unix",
      "platformOs" => "macos",
      "userAgent" => "symphony-orchestrator/0.163.0-alpha.11 (fixture)"
    }

    File.write!(trace <> ".initialize", Jason.encode!(%{"id" => 1, "result" => runtime}))
    hash = :crypto.hash(:sha256, "base\n") |> Base.encode16(case: :lower)

    call =
      Jason.encode!(%{
        "id" => 77,
        "method" => "item/tool/call",
        "params" => %{
          "threadId" => "file-worker",
          "turnId" => "file-turn",
          "callId" => "file-edit",
          "tool" => "repo_write",
          "arguments" => %{"path" => "fixture.txt", "expected_sha256" => hash, "content" => "edited\n"}
        }
      })

    File.write!(binary, """
    #!/bin/sh
    printf '%s\\n' "$@" >> '#{trace}.args'
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '#{trace}'
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' "$(cat '#{trace}.initialize')" ;;
        *'"method":"config/read"'*) printf '{"id":15,"result":%s}\\n' "$(cat '#{trace}.config')" ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":16,"result":{"data":[],"nextCursor":null}}' ;;
        *'"method":"thread/start"'*|*'"method":"thread/resume"'*) printf '{"id":2,"result":{"thread":{"id":"file-worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":"medium","activePermissionProfile":{"id":"symphony_ticket_file_source_v1"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$(pwd -P)" "$(pwd -P)" "$(pwd -P)" ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          printf '{"id":"%s","result":{"turn":{"id":"file-turn"}}}\\n' "$request_id"
          printf '%s\\n' '#{call}' ;;
        *'"id":77'*) printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"file-worker","turn":{"id":"file-turn","status":"completed","items":[]}}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)

    if ctx[:revision_restore] do
      server = Path.expand("../support/revision_worker_server.py", __DIR__)
      File.write!(binary, "#!/bin/sh\nexec /usr/bin/python3 -I -S -B '#{server}' '#{trace}'\n")
      File.write!(trace <> ".catalog", Jason.encode!(WorkerFileTools.tool_specs()))
    end

    timeout = if ctx[:revision_restore], do: 30_000, else: 5_000
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.root, codex_command: "#{binary} app-server", codex_turn_timeout_ms: timeout, codex_read_timeout_ms: timeout)
    trace
  end
end
