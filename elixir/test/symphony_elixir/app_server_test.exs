defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Factory.TicketChatCommands
  alias SymphonyElixir.TicketChatFixture

  @tag :provider_schema
  test "internal review workers use named scoped profiles, explicit turns and no controller connectors" do
    for {mode, profile} <- [{"REVIEW", "symphony_ticket_review_v1"}] do
      handler = """
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' "$*" >> "$trace_file.args" ;;
        *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{"mcp_servers":{"Jira":{},"AI Toolkit Skills":{}},"plugins":{"test-plugin@provider":{}}}}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":"medium","activePermissionProfile":{"id":"#{profile}"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$(pwd -P)" "$(pwd -P)" "$(pwd -P)" ;;
        *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":16,"result":{"data":[{"name":"Jira","tools":{},"resources":[],"resourceTemplates":[],"toolsError":null,"runtimeStatus":"disabled"},{"name":"openai-api-key-local-confirmation","tools":{},"resources":[],"resourceTemplates":[],"toolsError":null,"runtimeStatus":"connected"}],"nextCursor":null}}' ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          printf '{"id":"%s","result":{"turn":{"id":"turn"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"worker","turn":{"id":"turn","status":"completed","items":[]}}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
      """

      with_thread_listing_server(
        "worker-#{mode}",
        handler,
        fn workspace, trace ->
          assert {:ok, session} = AppServer.start_session(workspace, worker_access: mode, model: "gpt-6-luna", reasoning_effort: "medium")
          assert session.approval_policy == "never" and session.worker_policy["mode"] == mode
          issue = %Issue{identifier: "PPL-123", title: "Fixture"}

          schema = %{
            "type" => "object",
            "required" => [],
            "additionalProperties" => false,
            "properties" => %{"changed_paths" => %{"type" => "array", "items" => %{"type" => "string"}, "enum" => [[]]}}
          }

          options = [event_scope: :exact_turn, output_schema: schema]
          assert {:ok, %{turn_id: "turn"}} = AppServer.run_turn(session, "Local role work", issue, options)
          AppServer.stop_session(session)
          args = File.read!(trace <> ".args")
          assert args =~ "default_permissions=\"#{profile}\""
          assert args =~ "mcp_servers.Jira.enabled=false"
          assert args =~ "mcp_servers.AI Toolkit Skills.enabled=false"
          assert args =~ "mcp_servers.openai-api-key-local-confirmation.enabled=false"
          assert args =~ "mcp_servers.openai-api-key-local-confirmation.command=\"/usr/bin/false\""
          assert args =~ "plugins.test-plugin@provider.enabled=false"
          refute args =~ "mcp_servers.\"Jira\""
          assert args =~ "network.enabled=false"
          environment = session.worker_policy["shell_environment"]
          assert environment["inherit"] == "core"
          assert environment["set"]["GIT_CONFIG_GLOBAL"] == "/dev/null"
          assert environment["set"]["GIT_CONFIG_SYSTEM"] == "/dev/null"
          assert environment["set"]["GIT_OPTIONAL_LOCKS"] == "0"
          assert environment["set"]["PATH"] |> String.starts_with?("/Library/Developer/CommandLineTools/usr/bin:")
          assert args =~ "shell_environment_policy={inherit=\"core\",set={"
          assert args =~ "\"GIT_CONFIG_GLOBAL\"=\"/dev/null\""
          assert args =~ "\"GIT_CONFIG_SYSTEM\"=\"/dev/null\""
          messages = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
          start = Enum.find(messages, &(&1["method"] == "thread/start"))["params"]
          turn = Enum.find(messages, &(&1["method"] == "turn/start"))["params"]
          assert start["dynamicTools"] == [] and start["permissions"] == profile
          assert start["runtimeWorkspaceRoots"] == [session.workspace]
          assert start["allowProviderModelFallback"] == false
          assert turn["permissions"] == profile and turn["model"] == "gpt-6-luna" and turn["effort"] == "medium"
          assert turn["outputSchema"]["required"] == ["changed_paths"]
          assert turn["outputSchema"]["properties"]["changed_paths"]["maxItems"] == 0
          refute Map.has_key?(turn["outputSchema"]["properties"]["changed_paths"], "enum")
          assert schema["properties"]["changed_paths"]["enum"] == [[]]
          refute Map.has_key?(turn, "sandboxPolicy")
        end,
        Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.10.2 (fixture)")
      )
    end
  end

  @tag installed_runtime_112: true
  test "V1 workers reject unqualified runtime identity before thread creation", _ctx do
    supported = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.10.2 (fixture)")
    agent164 = "symphony-orchestrator/0.164.0-alpha.11.1"
    suffix164 = Map.put(supported, "userAgent", agent164 <> "suffix (fixture)")
    lookalike164 = Map.put(supported, "userAgent", agent164 <> "0 (fixture)")
    next164 = Map.put(supported, "userAgent", "symphony-orchestrator/0.164.0-alpha.11.2 (fixture)")

    for {name, response, reason} <- [
          {"missing", %{}, :worker_runtime_identity_unproven},
          {"null", nil, :worker_runtime_identity_unproven},
          {"malformed-home", Map.put(supported, "codexHome", []), :worker_runtime_identity_unproven},
          {"version", Map.put(supported, "userAgent", "symphony-orchestrator/0.161.0 (fixture)"), :worker_runtime_unsupported},
          {"candidate-version-lookalike", Map.put(supported, "userAgent", "symphony-orchestrator/0.162.0-alpha.20 (fixture)"), :worker_runtime_unsupported},
          {"updated-version-lookalike", Map.put(supported, "userAgent", "symphony-orchestrator/0.162.0-alpha.17.20 (fixture)"), :worker_runtime_unsupported},
          {"current-version-lookalike", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.10.20 (fixture)"), :worker_runtime_unsupported},
          {"current-version-suffix", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.10.2suffix (fixture)"), :worker_runtime_unsupported},
          {"unqualified-new-version", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.10.3 (fixture)"), :worker_runtime_unsupported},
          {"latest-version-lookalike", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.110 (fixture)"), :worker_runtime_unsupported},
          {"latest-version-suffix", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.11suffix (fixture)"), :worker_runtime_unsupported},
          {"patch-version-suffix", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.11.1suffix (fixture)"), :worker_runtime_unsupported},
          {"patch-version-lookalike", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.11.10 (fixture)"), :worker_runtime_unsupported},
          {"qualified-patch-suffix", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.11.2suffix (fixture)"), :worker_runtime_unsupported},
          {"qualified-patch-lookalike", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.11.20 (fixture)"), :worker_runtime_unsupported},
          {"unqualified-next-patch", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.11.3 (fixture)"), :worker_runtime_unsupported},
          {"unqualified-next-version", Map.put(supported, "userAgent", "symphony-orchestrator/0.163.0-alpha.12 (fixture)"), :worker_runtime_unsupported},
          {"updated-runtime-suffix", suffix164, :worker_runtime_unsupported},
          {"updated-runtime-lookalike", lookalike164, :worker_runtime_unsupported},
          {"updated-runtime-unqualified-patch", next164, :worker_runtime_unsupported},
          {"agent", Map.put(supported, "userAgent", "other/0.160.0 (fixture)"), :worker_runtime_unsupported},
          {"platform", Map.put(supported, "platformOs", "linux"), :worker_runtime_unsupported},
          {"home", Map.put(supported, "codexHome", System.tmp_dir!()), :worker_runtime_home_mismatch}
        ] do
      handler = """
      case "$line" in
        *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{}}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":null,"activePermissionProfile":{"id":"symphony_ticket_review_v1"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$(pwd -P)" "$(pwd -P)" "$(pwd -P)" ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
      """

      handler = handler <> "\ncase \"$line\" in *'\"method\":\"mcpServerStatus/list\"'*) printf '%s\\n' '{\"id\":16,\"result\":{\"data\":[],\"nextCursor\":null}}' ;; esac\n"

      with_thread_listing_server(
        "runtime-#{name}",
        handler,
        fn workspace, trace ->
          result = AppServer.start_session(workspace, worker_access: "REVIEW", model: "gpt-6-luna")
          if match?({:ok, _}, result), do: AppServer.stop_session(elem(result, 1))
          assert result == {:error, reason}
          refute File.read!(trace) =~ ~s("method":"thread/start")
          refute File.read!(trace) =~ ~s("method":"thread/resume")
          refute File.read!(trace) =~ ~s("method":"turn/start")
        end,
        response
      )
    end
  end

  @tag installed_runtime_112: true
  test "ticket runtime probes finish only qualified handshakes and observe process exit" do
    candidate_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.162.0-alpha.2 (fixture)")
    updated_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.162.0-alpha.17.2 (fixture)")
    current_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.10.2 (fixture)")
    latest_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.11 (fixture)")
    patch_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.11.1 (fixture)")
    next_patch_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.11.2 (fixture)")
    agent164 = "symphony-orchestrator/0.164.0-alpha.11.1 (fixture)"
    updated_minor_runtime = Map.put(fixture_runtime(), "userAgent", agent164)
    unqualified_runtime = Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.10.3 (fixture)")

    for {name, response, expected} <- [
          {"supported", fixture_runtime(), :ok},
          {"installed-candidate-version", candidate_runtime, :ok},
          {"updated-installed-version", updated_runtime, :ok},
          {"updated-minor-installed-version", updated_minor_runtime, :ok},
          {"current-installed-version", current_runtime, :ok},
          {"latest-installed-version", latest_runtime, :ok},
          {"patch-installed-version", patch_runtime, :ok},
          {"next-patch-installed-version", next_patch_runtime, :ok},
          {"missing-identity", %{}, {:error, :worker_runtime_identity_unproven}},
          {"unsupported-version", unqualified_runtime, {:error, :worker_runtime_unsupported}},
          {"unsupported-platform", Map.put(current_runtime, "platformOs", "linux"), {:error, :worker_runtime_unsupported}},
          {"foreign-home", Map.put(current_runtime, "codexHome", System.tmp_dir!()), {:error, :worker_runtime_home_mismatch}}
        ] do
      with_thread_listing_server(
        "probe-#{name}",
        "",
        fn workspace, trace ->
          owned = fn -> Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, self()})) end
          before = owned.()
          assert AppServer.check_ticket_runtime(workspace) == expected
          assert owned.() == before
          assert File.read!(trace <> ".terminated") == "terminated\n"
          pid = trace |> Kernel.<>(".pid") |> File.read!() |> String.trim()
          assert {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
          assert status != 0
          requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
          expected_methods = if expected == :ok, do: ["initialize", "initialized"], else: ["initialize"]
          assert Enum.map(requests, & &1["method"]) == expected_methods

          if expected == :ok do
            assert List.last(requests) == %{"method" => "initialized", "params" => %{}}
          end
        end,
        response
      )
    end

    with_thread_listing_server("probe-cwd", "", fn workspace, trace ->
      for cwd <- [nil, "", "relative", Path.join(workspace, "absent")] do
        assert {:error, :ticket_runtime_cwd_unproven} = AppServer.check_ticket_runtime(cwd)
      end

      refute File.exists?(trace)
    end)

    for status <- [0, 1] do
      with_thread_listing_server("probe-exited-#{status}", "exit #{status}", fn workspace, _trace ->
        assert {:error, _reason} = AppServer.check_ticket_runtime(workspace)
      end)
    end

    with_thread_listing_server("probe-early-exit", "", fn workspace, trace ->
      File.write!(Path.join(Path.dirname(trace), "fake-codex"), "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$SYMP_TEST_CODEx_TRACE.pid\"\nexit 0\n")
      assert {:error, _reason} = AppServer.check_ticket_runtime(workspace)
      pid = trace |> Kernel.<>(".pid") |> File.read!() |> String.trim()
      assert {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end)
  end

  test "native source admission and retained source sessions are fenced before process or model side effects" do
    with_thread_listing_server("unsafe-source-fenced", "", fn workspace, trace ->
      options = [worker_access: "SOURCE", model: "gpt-6-luna", reasoning_effort: "low"]
      assert {:error, :worker_source_containment_unproven} = AppServer.start_session(workspace, options)
      refute File.exists?(trace)
      refute File.exists?(trace <> ".args")
      session = %{worker_policy: AppServer.worker_policy("SOURCE", workspace)}
      assert {:error, :worker_source_containment_unproven} = AppServer.run_turn(session, "No source turn", %Issue{})
    end)
  end

  test "native history reads initialize and read only, without loading or waking a parent" do
    with_thread_listing_server(
      "native-read",
      """
      case "$line" in
        *'"method":"thread/read"'*)
          printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","projectId":null,"cwd":"/parent","turns":[]}}}' ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, %{"id" => "parent", "turns" => []}} = AppServer.read_native_thread("parent", workspace: workspace)
        requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
        assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "thread/read"]
        assert List.last(requests)["params"] == %{"threadId" => "parent", "includeTurns" => true}
        assert AppServer.read_native_thread(nil) == {:error, :invalid_native_thread_id}
      end
    )
  end

  @tag :native_reader
  test "initialized native readers are owner-bound read-only and close idempotently" do
    handler = """
    case "$line" in
      *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","turns":[]}}}' ;;
    esac
    """

    with_thread_listing_server("owned-native-reader", handler, fn workspace, trace ->
      assert {:ok, reader} = AppServer.open_native_reader(workspace)
      assert reader.owner == self()
      foreign = Task.async(fn -> {AppServer.read_native_thread(reader, "parent", []), AppServer.close_native_reader(reader)} end)
      assert {{:error, :native_reader_not_owned}, {:error, :native_reader_not_owned}} = Task.await(foreign)

      for changed <- [%{reader | cwd: workspace <> "/foreign"}, %{reader | app_server_pid: "999999999"}, %{reader | identity: make_ref()}] do
        assert {:error, :native_reader_not_owned} = AppServer.read_native_thread(changed, "parent", [])
        assert {:error, :native_reader_not_owned} = AppServer.close_native_reader(changed)
      end

      assert {:ok, %{"id" => "parent"}} = AppServer.read_native_thread(reader, "parent", [])
      send(self(), {:unrelated_reader_message, :preserved})
      assert :ok = AppServer.close_native_reader(reader)
      assert :ok = AppServer.close_native_reader(reader)
      assert {:error, :native_reader_not_owned} = AppServer.read_native_thread(reader, "parent", [])
      assert_receive {:unrelated_reader_message, :preserved}
      requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
      assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "thread/read"]
    end)
  end

  @tag :native_reader
  test "dead native readers never reopen and collection respects the remaining deadline" do
    handler = """
    case "$line" in
      *'"method":"thread/read"'*) sleep 0.5; printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","turns":[]}}}' ;;
    esac
    """

    with_thread_listing_server("deadline-native-reader", handler, fn workspace, trace ->
      assert {:ok, reader} = AppServer.open_native_reader(workspace)
      assert {:error, :response_timeout} = AppServer.read_native_thread(reader, "parent", timeout_ms: 50)
      Port.close(reader.port)
      assert {:error, :native_reader_not_owned} = AppServer.read_native_thread(reader, "parent", [])
      assert :ok = AppServer.close_native_reader(reader)
      requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
      assert Enum.count(requests, &(&1["method"] == "initialize")) == 1
      refute Enum.any?(requests, &(&1["method"] in ~w(thread/start thread/resume thread/fork turn/start)))
    end)
  end

  test "controller catalog reads use the existing thread and never start a model turn" do
    tools = %{"get_pipeline" => %{"name" => "get_pipeline", "inputSchema" => %{"type" => "object"}}}
    catalog = Jason.encode!(%{"data" => [%{"name" => "GitLab", "tools" => tools, "toolsError" => nil}], "nextCursor" => nil})

    with_thread_listing_server(
      "scoped-controller-catalog",
      """
      case "$line" in
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"controller-catalog"}}}' ;;
        *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":18,"result":#{catalog}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, session} = AppServer.start_session(workspace, ephemeral: true)
        assert {:ok, ^tools} = AppServer.mcp_tool_catalog_in_session(session, "GitLab")
        assert :ok = AppServer.stop_session(session)
        messages = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
        request = Enum.find(messages, &(&1["method"] == "mcpServerStatus/list"))
        assert request["params"] == %{"threadId" => session.thread_id, "serverName" => "GitLab", "detail" => "toolsAndAuthOnly", "limit" => 1}
        refute Enum.any?(messages, &(&1["method"] in ["turn/start", "thread/resume", "mcpServer/tool/call"]))
      end
    )
  end

  test "ephemeral connector scope never resumes a controller or starts a model and always closes" do
    scopes = [{"GitLab", &AppServer.with_gitlab_read_session/2}, {"Jira", &AppServer.with_jira_controller_session/2}]

    for {server, scope} <- scopes,
        outcome <- [:ok, :error, :raise] do
      with_thread_listing_server(
        "connector-#{server}-#{outcome}",
        """
        case "$line" in
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"ephemeral-reader"}}}'
            printf '%s\\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"#{server}","status":"ready"}}' ;;
          *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
          *'"method":"mcpServer/tool/call"'*) printf '%s\\n' '{"id":14,"result":{"content":[]}}' ;;
        esac
        """,
        fn workspace, trace ->
          operation = fn session ->
            assert session.thread_id == "ephemeral-reader"
            assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
            assert session.workspace == expected_workspace
            assert session.worker_policy == nil
            send(self(), {:reader_port, session.port})

            case outcome do
              :ok ->
                for _ <- 1..2 do
                  assert {:ok, %{"content" => []}} = AppServer.call_mcp_tool_in_session(session, server, "fixture_tool", %{"fixture" => true})
                end

                {:ok, :readback}

              :error ->
                {:error, :changed_mr}

              :raise ->
                raise "read failed"
            end
          end

          case outcome do
            :ok -> assert {:ok, :readback} = scope.(workspace, operation)
            :error -> assert {:error, :changed_mr} = scope.(workspace, operation)
            :raise -> assert_raise RuntimeError, "read failed", fn -> scope.(workspace, operation) end
          end

          assert_received {:reader_port, port}
          assert :erlang.port_info(port) == :undefined
          messages = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
          start = Enum.find(messages, &(&1["method"] == "thread/start"))["params"]
          assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
          assert start["ephemeral"] == true and start["cwd"] == expected_workspace
          refute Enum.any?(~w(model projectId resumeThreadId), &Map.has_key?(start, &1))
          refute Enum.any?(messages, &(&1["method"] in ~w(turn/start thread/resume thread/fork)))
          assert Enum.count(messages, &(&1["method"] == "thread/unsubscribe")) == 1
          assert Enum.count(messages, &(&1["method"] == "mcpServer/tool/call")) == if(outcome == :ok, do: 2, else: 0)
        end
      )
    end
  end

  test "factory Jira provider overrides are session-local and preserve connector authentication" do
    previous = System.get_env("SYMP_FACTORY_TEST_TOKEN")
    System.put_env("SYMP_FACTORY_TEST_TOKEN", "synthetic-auth-sentinel")
    on_exit(fn -> restore_env("SYMP_FACTORY_TEST_TOKEN", previous) end)

    for {server, scope} <- [{"Jira", &AppServer.with_jira_controller_session/2}, {"GitLab", &AppServer.with_gitlab_read_session/2}] do
      handler = """
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' "$*" > "$trace_file.args"; printf '%s' "${SYMP_FACTORY_TEST_TOKEN:-missing}" > "$trace_file.auth" ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"connector"}}}'; printf '%s\\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"#{server}","status":"ready"}}' ;;
        *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":18,"result":{"data":[{"name":"#{server}","tools":{"fixture":{"name":"fixture","inputSchema":{"type":"object"}}},"toolsError":null,"resources":[],"resourceTemplates":[]}],"nextCursor":null}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
      """

      with_thread_listing_server("jira-provider-#{server}", handler, fn workspace, trace ->
        adapter = Path.join(workspace, "adapter.py")
        File.write!(adapter, "pass\n")
        provider = Jason.encode!(%{"command" => "/usr/bin/python3", "args" => [adapter]})
        workflow = File.read!(Workflow.workflow_file_path()) |> String.replace("\n---\n", "\nfactory:\n  jira_connector: #{provider}\n---\n", global: false)
        File.write!(Workflow.workflow_file_path(), workflow)
        WorkflowStore.force_reload()

        assert {:ok, _} = scope.(workspace, fn session -> AppServer.mcp_tool_catalog_in_session(session, server) end)
        args = File.read!(trace <> ".args")

        if server == "Jira" do
          assert args =~ "mcp_servers.Jira.command=\"/usr/bin/python3\""
          assert args =~ "mcp_servers.Jira.args="
          assert args =~ adapter
          assert length(Regex.scan(~r/--config /, args)) == 2
        else
          refute args =~ "mcp_servers.Jira.command="
        end

        assert File.read!(trace <> ".auth") == "synthetic-auth-sentinel"
        messages = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
        refute Enum.any?(messages, &(&1["method"] == "turn/start"))
        assert Enum.any?(messages, &(&1["method"] == "thread/unsubscribe"))
      end)
    end
  end

  test "ephemeral connector startup failure never invokes the collector" do
    scopes = [{"GitLab", &AppServer.with_gitlab_read_session/2}, {"Jira", &AppServer.with_jira_controller_session/2}]

    for {server, scope} <- scopes do
      with_thread_listing_server(
        "connector-#{server}-startup-failure",
        """
        case "$line" in
          *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"error":{"code":-1,"message":"unavailable"}}' ;;
        esac
        """,
        fn workspace, trace ->
          assert {:error, _} = scope.(workspace, fn _ -> flunk("collector invoked") end)
          refute File.read!(trace) =~ "turn/start"
        end
      )
    end
  end

  test "native queue collection distinguishes proven empty from partial or malformed pages" do
    for {name, page, expected} <- [
          {"empty", %{"data" => [], "nextCursor" => nil}, true},
          {"busy", %{"data" => [%{"id" => "input"}], "nextCursor" => nil}, false},
          {"partial", %{"data" => [], "nextCursor" => "more"}, false},
          {"missing-cursor", %{"data" => []}, :native_queue_page_invalid},
          {"bad-item", %{"data" => [nil], "nextCursor" => nil}, :native_queue_page_invalid},
          {"bad-cursor", %{"data" => [], "nextCursor" => 1}, :native_queue_page_invalid}
        ] do
      response = Jason.encode!(%{"id" => 20, "result" => page})

      with_thread_listing_server(
        "queue-#{name}",
        """
        case "$line" in
          *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent"}}}' ;;
          *'"method":"thread/queue/list"'*) printf '%s\\n' '#{response}' ;;
        esac
        """,
        fn workspace, trace ->
          if is_boolean(expected) do
            assert {:ok, thread} =
                     AppServer.read_native_thread("parent", workspace: workspace, include_turns: false, include_queue: true)

            assert thread["queue_observation"]["empty_complete"] == expected
            assert thread["queue_observation"]["thread_id"] == "parent"
            refute Map.has_key?(thread["queue_observation"], "data")
            assert thread["queue_observation"]["raw_response"] == page
          else
            assert {:error, ^expected} =
                     AppServer.read_native_thread("parent", workspace: workspace, include_turns: false, include_queue: true)
          end

          requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
          assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "thread/read", "thread/queue/list"]
          assert Enum.at(requests, 2)["params"]["includeTurns"] == false
        end
      )
    end
  end

  test "latest native turn collection reads one descending page and rechecks history without waking a model" do
    with_thread_listing_server(
      "latest-native-turn",
      """
      case "$line" in
        *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","updatedAt":42}}}' ;;
        *'"method":"thread/turns/list"'*) printf '%s\\n' '{"id":19,"result":{"data":[{"id":"latest","status":"completed","items":[]}],"nextCursor":"older"}}' ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, thread} =
                 AppServer.read_native_thread("parent", workspace: workspace, include_turns: false, include_latest_turn: true)

        assert thread["latest_turn_observation"]["raw_response"]["data"] |> hd() |> Map.get("id") == "latest"
        requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
        assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "thread/read", "thread/turns/list", "thread/read"]
        assert Enum.at(requests, 3)["params"] == %{"threadId" => "parent", "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}
      end
    )
  end

  test "a human turn completing during queue collection invalidates latest-turn guard evidence" do
    for {name, version, turn, expected} <- [
          {"changed-version", 43, "original", :native_history_changed_during_read},
          {"coarse-version", 42, "human", :native_latest_turn_changed_during_read},
          {"unchanged", 42, "original", :accepted}
        ] do
      with_thread_listing_server(
        "latest-queue-race-#{name}",
        """
        case "$line" in
          *'"method":"thread/read"'*) printf '{"id":9,"result":{"thread":{"id":"parent","updatedAt":%s}}}\\n' "${version:-42}" ;;
          *'"method":"thread/turns/list"'*) printf '{"id":19,"result":{"data":[{"id":"%s","status":"completed","items":[]}],"nextCursor":null}}\\n' "${latest:-original}" ;;
          *'"method":"thread/queue/list"'*) version=#{version}; latest=#{turn}; printf '%s\\n' '{"id":20,"result":{"data":[],"nextCursor":null}}' ;;
        esac
        """,
        fn workspace, _trace ->
          opts = [workspace: workspace, include_turns: false, include_latest_turn: true, include_queue: true]
          result = AppServer.read_native_thread("parent", opts)

          if expected == :accepted do
            assert {:ok, thread} = result
            assert thread["latest_turn_observation"]["confirmation"]["raw_response"]["data"] == thread["latest_turn_observation"]["raw_response"]["data"]
          else
            assert {:error, ^expected} = result
          end
        end
      )
    end
  end

  test "latest turn collection rejects missing identity and changing native history" do
    for {name, page, error} <- [
          {"empty", %{"data" => [], "nextCursor" => nil}, :native_latest_turn_invalid},
          {"missing-cursor", %{"data" => [%{"id" => "latest", "items" => []}]}, :native_latest_turn_invalid},
          {"missing-items", %{"data" => [%{"id" => "latest"}], "nextCursor" => nil}, :native_history_items_missing},
          {"changing", %{"data" => [%{"id" => "latest", "items" => []}], "nextCursor" => nil}, :native_history_changed_during_read}
        ] do
      response = Jason.encode!(%{"id" => 19, "result" => page})
      changing = if name == "changing", do: 1, else: 0

      with_thread_listing_server(
        name,
        """
        case "$line" in
          *'"method":"thread/read"'*)
            read_count=$(( ${read_count:-0} + #{changing} ))
            printf '{"id":9,"result":{"thread":{"id":"parent","updatedAt":%s}}}\\n' "$read_count" ;;
          *'"method":"thread/turns/list"'*) printf '%s\\n' '#{response}' ;;
        esac
        """,
        fn workspace, _trace ->
          opts = [workspace: workspace, include_turns: false, include_latest_turn: true]
          assert {:error, ^error} = AppServer.read_native_thread("parent", opts)
        end
      )
    end
  end

  test "complete native history pages full items without loading or waking the parent" do
    with_thread_listing_server(
      "paged-native-read",
      """
      case "$line" in
        *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","projectId":null,"cwd":"/parent","updatedAt":42,"turns":[]}}}' ;;
        *'"method":"thread/turns/list"'*)
          case "$line" in
            *'"cursor":"older"'*) printf '%s\\n' '{"id":19,"result":{"data":[{"id":"second","status":"completed","items":[]}],"nextCursor":null}}' ;;
            *) printf '%s\\n' '{"id":19,"result":{"data":[{"id":"first","status":"completed","items":[]}],"nextCursor":"older"}}' ;;
          esac ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, thread} = AppServer.read_native_thread("parent", workspace: workspace, complete_history: true)
        assert Enum.map(thread["turns"], & &1["id"]) == ["first", "second"]
        assert thread["history_observation"] == %{"mode" => "PAGED_FULL", "next_cursor" => nil, "turn_count" => 2, "updated_at" => 42}
        requests = File.read!(trace) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))
        assert Enum.map(requests, & &1["method"]) == ["initialize", "initialized", "thread/read", "thread/turns/list", "thread/turns/list", "thread/read"]
        for request <- Enum.filter(requests, &(&1["method"] == "thread/turns/list")), do: assert(request["params"]["itemsView"] == "full")
      end
    )
  end

  @tag mr_completion_transport: true
  test "anchored native receipt reads every newer full item across pages and stops at the exact anchor" do
    with_thread_listing_server(
      "anchored-native-read",
      """
      case "$line" in
        *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","projectId":null,"cwd":"/parent","updatedAt":42}}}' ;;
        *'"method":"thread/turns/list"'*)
          case "$line" in
            *'"cursor":"older"'*) printf '%s\\n' '{"id":19,"result":{"data":[{"id":"anchor","items":[]},{"id":"unneeded","items":[]}],"nextCursor":"never-read"}}' ;;
            *) printf '%s\\n' '{"id":19,"result":{"data":[{"id":"newest","items":[]},{"id":"middle","items":[]}],"nextCursor":"older"}}' ;;
          esac ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, thread} =
                 AppServer.read_native_thread("parent",
                   workspace: workspace,
                   include_turns: false,
                   history_after_turn: "anchor"
                 )

        assert Enum.map(thread["turns"], & &1["id"]) == ~w(anchor middle newest)

        assert thread["history_observation"] == %{
                 "mode" => "PAGED_AFTER_ANCHOR",
                 "anchor_turn_id" => "anchor",
                 "turn_count" => 3,
                 "updated_at" => 42
               }

        requests =
          File.read!(trace)
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))

        pages = Enum.filter(requests, &(&1["method"] == "thread/turns/list"))
        assert length(pages) == 2
        assert Enum.all?(pages, &(&1["params"]["itemsView"] == "full" and &1["params"]["sortDirection"] == "desc"))
        refute Enum.any?(requests, &(&1["method"] in ~w(turn/start thread/resume)))
      end
    )
  end

  @tag mr_completion_transport: true
  test "anchored native receipt refuses absent anchors cycles cross-page duplicates and native version drift" do
    for {name, first, second, changing, expected} <- [
          {"absent", %{"data" => [%{"id" => "new", "items" => []}], "nextCursor" => nil}, nil, false, :native_history_anchor_missing},
          {"cycle", %{"data" => [], "nextCursor" => "older"}, %{"data" => [], "nextCursor" => "older"}, false, :native_history_cursor_invalid},
          {"duplicate", %{"data" => [%{"id" => "new", "items" => []}], "nextCursor" => "older"},
           %{"data" => [%{"id" => "new", "items" => []}, %{"id" => "anchor", "items" => []}], "nextCursor" => nil}, false, :native_history_turn_conflict},
          {"drift", %{"data" => [%{"id" => "anchor", "items" => []}], "nextCursor" => nil}, nil, true, :native_history_changed_during_read}
        ] do
      first = Jason.encode!(%{"id" => 19, "result" => first})
      second = Jason.encode!(%{"id" => 19, "result" => second})

      with_thread_listing_server(
        "anchor-" <> name,
        """
        case "$line" in
          *'"method":"thread/read"'*)
            count=$(( ${count:-0} + 1 ))
            version=42
            if [ '#{changing}' = true ] && [ "$count" -gt 1 ]; then version=43; fi
            printf '{"id":9,"result":{"thread":{"id":"parent","updatedAt":%s}}}\\n' "$version" ;;
          *'"method":"thread/turns/list"'*)
            case "$line" in
              *'"cursor":"older"'*) printf '%s\\n' '#{second}' ;;
              *) printf '%s\\n' '#{first}' ;;
            esac ;;
        esac
        """,
        fn workspace, _trace ->
          assert {:error, ^expected} =
                   AppServer.read_native_thread("parent",
                     workspace: workspace,
                     include_turns: false,
                     history_after_turn: "anchor"
                   )
        end
      )
    end
  end

  test "incomplete, repeated-cursor or duplicate native pages retain readback uncertainty" do
    for {name, page, error} <- [
          {"missing-items", %{"data" => [%{"id" => "first"}], "nextCursor" => nil}, :native_history_items_missing},
          {"cursor-cycle", %{"data" => [], "nextCursor" => "repeat"}, :native_history_cursor_invalid},
          {"duplicate-turn", %{"data" => [%{"id" => "first", "items" => []}, %{"id" => "first", "items" => []}], "nextCursor" => nil}, :native_history_turn_conflict},
          {"malformed", %{"data" => []}, :native_history_page_invalid}
        ] do
      response = Jason.encode!(%{"id" => 19, "result" => page})

      with_thread_listing_server(
        name,
        """
        case "$line" in
          *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"parent","updatedAt":42,"turns":[]}}}' ;;
          *'"method":"thread/turns/list"'*) printf '%s\\n' '#{response}' ;;
        esac
        """,
        fn workspace, _trace ->
          assert {:error, ^error} = AppServer.read_native_thread("parent", workspace: workspace, complete_history: true)
        end
      )
    end
  end

  test "native history changing during paged collection is not accepted" do
    with_thread_listing_server(
      "changed-native-history",
      """
      case "$line" in
        *'"method":"thread/read"'*)
          read_count=$(( ${read_count:-0} + 1 ))
          printf '{"id":9,"result":{"thread":{"id":"parent",'
          printf '"updatedAt":%s,"turns":[]}}}\\n' "$read_count" ;;
        *'"method":"thread/turns/list"'*) printf '%s\\n' '{"id":19,"result":{"data":[],"nextCursor":null}}' ;;
      esac
      """,
      fn workspace, _trace ->
        assert {:error, :native_history_changed_during_read} =
                 AppServer.read_native_thread("parent", workspace: workspace, complete_history: true)
      end
    )
  end

  test "controller catalog rejects unavailable, ambiguous, malformed and interactive inventory" do
    tool = %{"get_pipeline" => %{"name" => "get_pipeline", "inputSchema" => %{"type" => "object"}}}
    server = %{"name" => "GitLab", "tools" => tool, "toolsError" => nil}
    complete = %{"data" => [server], "nextCursor" => nil}

    for {name, result, expected} <- [
          {"empty", %{"data" => [], "nextCursor" => nil}, :mcp_tool_catalog_unavailable},
          {"pagination", Map.put(complete, "nextCursor", "more"), :mcp_tool_catalog_unavailable},
          {"missing-cursor", Map.delete(complete, "nextCursor"), :mcp_tool_catalog_unavailable},
          {"wrong-server", %{complete | "data" => [Map.put(server, "name", "Jira")]}, :mcp_tool_catalog_unavailable},
          {"two-servers", %{complete | "data" => [server, server]}, :mcp_tool_catalog_unavailable},
          {"tool-error", %{complete | "data" => [Map.put(server, "toolsError", "unavailable")]}, :mcp_tool_catalog_unavailable},
          {"empty-tools", %{complete | "data" => [Map.put(server, "tools", %{})]}, :mcp_tool_catalog_unavailable},
          {"bad-schema", %{complete | "data" => [Map.put(server, "tools", %{"get_pipeline" => %{"name" => "get_pipeline", "inputSchema" => []}})]}, :mcp_tool_catalog_invalid},
          {"wrong-tool-name", %{complete | "data" => [Map.put(server, "tools", %{"get_pipeline" => %{"name" => "mutate", "inputSchema" => %{"type" => "object"}}})]}, :mcp_tool_catalog_invalid}
        ] do
      response = Jason.encode!(%{"id" => 18, "result" => result})

      with_thread_listing_server(
        "catalog-reject-#{name}",
        """
        case "$line" in
          *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"controller-catalog"}}}' ;;
          *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '#{response}' ;;
          *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
        esac
        """,
        fn workspace, trace ->
          assert {:ok, session} = AppServer.start_session(workspace, ephemeral: true)
          assert {:error, ^expected} = AppServer.mcp_tool_catalog_in_session(session, "GitLab")
          assert :ok = AppServer.stop_session(session)
          refute File.read!(trace) =~ ~s("method":"mcpServer/tool/call")
        end
      )
    end
  end

  test "catalog access rejects restricted, invalid and foreign-owned sessions before sending" do
    restricted = %{worker_policy: %{"mode" => "REVIEW"}}
    malformed = %{worker_policy: "malformed"}
    assert {:error, :worker_connector_catalog_forbidden} = AppServer.mcp_tool_catalog_in_session(restricted, "GitLab")
    assert {:error, :worker_connector_catalog_forbidden} = AppServer.mcp_tool_catalog_in_session(malformed, "GitLab")
    assert {:error, :invalid_mcp_catalog_session} = AppServer.mcp_tool_catalog_in_session(%{}, "GitLab")

    with_thread_listing_server(
      "catalog-ownership",
      """
      case "$line" in
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"controller-catalog"}}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, session} = AppServer.start_session(workspace, ephemeral: true)
        task = Task.async(fn -> AppServer.mcp_tool_catalog_in_session(session, "GitLab") end)
        assert {:error, :mcp_catalog_session_not_owned} = Task.await(task)
        assert :ok = AppServer.stop_session(session)
        refute File.read!(trace) =~ ~s("method":"mcpServerStatus/list")
      end
    )
  end

  test "recovery marker requires its guard before sending any turn request" do
    with_thread_listing_server(
      "missing-recovery-guard",
      """
      case "$line" in
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"owned"}}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
      """,
      fn workspace, trace ->
        {:ok, session} = AppServer.start_session(workspace, native_recovery: %{"kind" => "INTERRUPTED_TURN_QUIESCENCE"})

        try do
          assert {:error, :native_recovery_guard_missing} = AppServer.run_turn(session, "not sent", %Issue{})
          refute File.read!(trace) =~ ~s("method":"turn/start")
        after
          AppServer.stop_session(session)
        end
      end
    )
  end

  test "owned native recovery read stays on its actor and denies a foreign process" do
    latest = Jason.encode!(%{"data" => [%{"id" => "interrupted", "status" => "interrupted", "error" => nil, "items" => []}], "nextCursor" => nil})

    with_thread_listing_server(
      "owned-recovery-read",
      """
      case "$line" in
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"owned"}}}' ;;
        *'"method":"thread/read"'*) printf '%s\\n' '{"id":9,"result":{"thread":{"id":"owned","updatedAt":1,"status":{"type":"idle"}}}}' ;;
        *'"method":"thread/turns/list"'*) printf '%s\\n' '{"id":19,"result":#{latest}}' ;;
        *'"method":"thread/queue/list"'*) printf '%s\\n' '{"id":20,"result":{"data":[],"nextCursor":null}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
      """,
      fn workspace, trace ->
        {:ok, session} = AppServer.start_session(workspace)

        try do
          task = Task.async(fn -> AppServer.read_owned_native_thread(session) end)
          assert {:error, :file_worker_session_not_owned} = Task.await(task)
          assert {:ok, observed} = AppServer.read_owned_native_thread(session)
          assert observed["queue_observation"]["empty_complete"]
          assert is_list(:erlang.port_info(session.port))
          messages = File.read!(trace)
          refute messages =~ ~s("method":"turn/start")
          refute messages =~ ~s("method":"thread/resume")
        after
          AppServer.stop_session(session)
        end
      end
    )
  end

  test "same-owner catalog reads cannot consume notifications from an active turn" do
    catalog =
      Jason.encode!(%{"data" => [%{"name" => "GitLab", "toolsError" => nil, "tools" => %{"get_pipeline" => %{"name" => "get_pipeline", "inputSchema" => %{"type" => "object"}}}}], "nextCursor" => nil})

    with_thread_listing_server(
      "catalog-active-turn",
      """
      case "$line" in
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"controller-catalog"}}}' ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          printf '{"id":"%s","result":{"turn":{"id":"catalog-turn"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"controller-catalog","turn":{"id":"catalog-turn","status":"completed","items":[]}}}' ;;
        *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":18,"result":#{catalog}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{}}' ;;
      esac
      """,
      fn workspace, trace ->
        assert {:ok, session} = AppServer.start_session(workspace, ephemeral: true)

        callback = fn
          %{event: :session_started} ->
            result = AppServer.mcp_tool_catalog_in_session(session, "GitLab")
            send(self(), {:active_catalog, result})

          _event ->
            :ok
        end

        options = [event_scope: :exact_turn, on_message: callback]

        try do
          assert {:ok, %{turn_id: "catalog-turn"}} = AppServer.run_turn(session, "Transport fixture only", %Issue{}, options)
          assert_received {:active_catalog, {:error, :mcp_catalog_session_busy}}
          refute File.read!(trace) =~ ~s("method":"mcpServerStatus/list")
        after
          AppServer.stop_session(session)
        end
      end
    )
  end

  test "worker policy drift, API-key accounts and unexpected catalogs reject before any model turn" do
    for {name, profile, account, catalog, expected} <- [
          {"profile", "wrong-profile", "chatgpt", ~s({"data":[],"nextCursor":null}), :worker_effective_policy_mismatch},
          {"auth", "symphony_ticket_review_v1", "apiKey", ~s({"data":[],"nextCursor":null}), :worker_chatgpt_account_required},
          {"catalog", "symphony_ticket_review_v1", "chatgpt", ~s({"data":[{"name":"unexpected","tools":{"mutate":{}}}],"nextCursor":null}), :worker_connector_catalog_not_empty},
          {"empty-live", "symphony_ticket_review_v1", "chatgpt", ~s({"data":[{"name":"unexpected","tools":{},"resources":[],"resourceTemplates":[],"runtimeStatus":"connected"}],"nextCursor":null}),
           :worker_connector_catalog_not_empty},
          {"disabled-with-resource", "symphony_ticket_review_v1", "chatgpt",
           ~s({"data":[{"name":"Jira","tools":{},"resources":[{}],"resourceTemplates":[],"runtimeStatus":"disabled"}],"nextCursor":null}), :worker_connector_catalog_not_empty},
          {"paginated", "symphony_ticket_review_v1", "chatgpt", ~s({"data":[],"nextCursor":"more"}), :worker_connector_catalog_not_empty}
        ] do
      handler = """
      case "$line" in
        *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{}}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"#{account}"}}}' ;;
        *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":null,"activePermissionProfile":{"id":"#{profile}"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$(pwd -P)" "$(pwd -P)" "$(pwd -P)" ;;
        *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":16,"result":#{catalog}}' ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
      """

      with_thread_listing_server(
        "reject-#{name}",
        handler,
        fn workspace, trace ->
          assert {:error, ^expected} = AppServer.start_session(workspace, worker_access: "REVIEW", model: "gpt-6-luna")
          refute File.read!(trace) =~ ~s("method":"turn/start")
          restricted = [worker_access: "REVIEW", project_id: "project"]
          assert {:error, :worker_capability_configuration_rejected} = AppServer.start_session(workspace, restricted)
          assert {:error, :worker_access_profile_unsupported} = AppServer.start_session(workspace, worker_access: "UNKNOWN")
        end,
        Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.10.2 (fixture)")
      )
    end
  end

  test "native observer rejects server approvals, tool requests and wrong thread history" do
    for {name, response, expected} <- [
          {"approval", ~s({"id":99,"method":"item/commandExecution/requestApproval","params":{}}), :native_read_requests_unsupported},
          {"tool", ~s({"id":9,"method":"item/tool/call","result":{}}), :native_read_requests_unsupported},
          {"wrong-id", ~s({"id":9,"result":{"thread":{"id":"other","turns":[]}}}), :native_read_identity_or_history_mismatch}
        ] do
      with_thread_listing_server(
        "native-#{name}",
        """
        case "$line" in
          *'"method":"thread/read"'*) printf '%s\\n' '#{response}' ;;
        esac
        """,
        fn workspace, trace ->
          assert {:error, ^expected} = AppServer.read_native_thread("parent", workspace: workspace)
          refute File.read!(trace) =~ ~s("method":"turn/start")
          refute File.read!(trace) =~ ~s("decision":"accept")
        end
      )
    end
  end

  test "effective runtime roots, cwd and effort must match, not just the nested thread", _ctx do
    for name <- ~w(cwd roots effort) do
      cwd = if name == "cwd", do: "/elsewhere", else: "actual"
      roots = if name == "roots", do: "/elsewhere", else: "actual"
      effort = if name == "effort", do: "high", else: "medium"

      handler = """
      case "$line" in
        *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{}}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"thread/start"'*)
          actual=$(pwd -P)
          effective='#{cwd}'
          roots='#{roots}'
          [ "$effective" != actual ] || effective=$actual
          [ "$roots" != actual ] || roots=$actual
          printf '{"id":2,"result":{"thread":{"id":"worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":"#{effort}","activePermissionProfile":{"id":"symphony_ticket_review_v1"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$actual" "$effective" "$roots" ;;
      esac
      """

      with_thread_listing_server(
        "effective-#{name}",
        handler,
        fn workspace, trace ->
          options = [worker_access: "REVIEW", model: "gpt-6-luna", reasoning_effort: "medium"]
          assert {:error, :worker_effective_policy_mismatch} = AppServer.start_session(workspace, options)
          refute File.read!(trace) =~ ~s("method":"turn/start")
        end,
        Map.put(fixture_runtime(), "userAgent", "symphony-orchestrator/0.163.0-alpha.10.2 (fixture)")
      )
    end
  end

  test "a failed native turn retains the actual owned process shutdown through StageRunner", _ctx do
    handler = """
    case "$line" in
      *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{}}}' ;;
      *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"chatgpt"}}}' ;;
      *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":null,"activePermissionProfile":{"id":"symphony_ticket_review_v1"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$(pwd -P)" "$(pwd -P)" "$(pwd -P)" ;;
      *'"method":"mcpServerStatus/list"'*) printf '%s\\n' '{"id":16,"result":{"data":[],"nextCursor":null}}' ;;
      *'"method":"turn/start"'*)
        request_id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
        printf '{"id":"%s","result":{"turn":{"id":"failed-turn"}}}\\n' "$request_id"
        printf '%s\\n' '{"method":"error","params":{"threadId":"worker","turnId":"failed-turn","willRetry":false,"error":{"message":"Selected model is at capacity","codexErrorInfo":"serverOverloaded"}}}' ;;
      *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
    esac
    """

    with_thread_listing_server("failed-turn-shutdown", handler, fn workspace, trace ->
      assert {:error, {:worker_failed, {:worker_turn_error, failure}, observed}} =
               SymphonyElixir.Factory.StageRunner.run(workspace, %Issue{identifier: "PPL-123", title: "Fixture"}, "One failed turn", %{"type" => "object"},
                 worker_access: "REVIEW",
                 model: "gpt-6-luna",
                 include_evidence: true,
                 event_scope: :exact_turn,
                 on_session_ready: fn session -> send(self(), {:owned_failed_session, session}) end
               )

      assert_received {:owned_failed_session, session}
      assert failure["codexErrorInfo"] == "serverOverloaded"
      assert observed.thread_id == session.thread_id and observed.turn_id == "failed-turn"
      assert observed.policy == session.worker_policy
      stop = observed.owner_stop
      actual_pid = File.read!(trace <> ".pid") |> String.trim()
      assert stop["transport"] == "owned_app_server"
      assert stop["pid"] == session.metadata.codex_app_server_pid
      assert stop["pid"] == actual_pid
      assert stop["invocation_nonce"] == session.worker_invocation
      assert stop["thread_id"] == session.thread_id and stop["cwd"] == session.worker_policy["cwd"]
      assert is_integer(stop["exit_status"])
      assert Port.info(session.port) == nil
      refute Map.has_key?(observed, :output)
      refute Map.has_key?(observed, :item_id)
    end)
  end

  test "a startup observer exception closes the actual owned port before returning", _ctx do
    handler = """
    case "$line" in
      *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{}}}' ;;
      *'"method":"account/read"'*) printf '%s\\n' '{"id":17,"result":{"account":{"type":"chatgpt"}}}' ;;
      *'"method":"thread/start"'*) printf '{"id":2,"result":{"thread":{"id":"worker","cwd":"%s"},"cwd":"%s","runtimeWorkspaceRoots":["%s"],"reasoningEffort":null,"activePermissionProfile":{"id":"symphony_ticket_review_v1"},"approvalPolicy":"never","model":"gpt-6-luna"}}\\n' "$(pwd -P)" "$(pwd -P)" "$(pwd -P)" ;;
    esac
    """

    with_thread_listing_server("startup-observer-error", handler, fn workspace, _trace ->
      owned_ports = fn -> Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, self()})) end
      before = owned_ports.()

      assert_raise RuntimeError, "observer failed", fn ->
        AppServer.start_session(workspace, worker_access: "REVIEW", model: "gpt-6-luna", on_thread_created: fn _ -> raise "observer failed" end)
      end

      assert owned_ports.() == before
    end)
  end

  test "connector names ambiguous in the CLI path grammar are rejected before restricted startup", _ctx do
    handler = """
    case "$line" in
      *'"method":"config/read"'*) printf '%s\\n' '{"id":15,"result":{"config":{"mcp_servers":{"name.with.dots":{}}}}}' ;;
    esac
    """

    with_thread_listing_server("ambiguous-configuration-key", handler, fn workspace, trace ->
      assert {:error, :worker_configuration_unavailable} = AppServer.start_session(workspace, worker_access: "REVIEW")
      refute File.read!(trace) =~ ~s("method":"thread/start")
    end)
  end

  test "ticket collector consumes only completed native user input through a mechanical history read" do
    ctx = TicketChatFixture.setup_fixture(%{})
    body = "Rework the current candidate."
    {:ok, _} = TicketChatFixture.stage(ctx, "collector", body, [%{"operation" => "request_rework"}])
    native = TicketChatFixture.native(ctx, [body])
    response = Jason.encode!(%{"id" => 9, "result" => %{"thread" => native}})

    with_thread_listing_server(
      "ticket-collector",
      """
      case "$line" in
        *'"method":"thread/read"'*) printf '%s\\n' '#{response}' ;;
      esac
      """,
      fn _workspace, trace ->
        assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}], worker_started: false}} =
                 TicketChatCommands.collect(ctx.store, "run")

        refute File.read!(trace) =~ ~s("method":"turn/start")
        refute File.read!(trace) =~ ~s("method":"thread/resume")
      end
    )
  end

  test "thread lookup finds one exact named task across source kinds and archived pages" do
    with_thread_listing_server(
      "exact-thread",
      """
      case "$line" in
        *'"method":"thread/list"'*)
          case "$line" in
            *'"archived":false'*)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"active-decoy","name":"FACTORY PROBE · Grail · Native Readback - old","projectId":"project-grail","cwd":"/other"}],"nextCursor":null}}'
              ;;
            *'"cursor":"second-archived"'*)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"matching-thread","name":"FACTORY PROBE · Grail · Native Readback","projectId":"project-grail","cwd":"/worktree/grail"}],"nextCursor":null}}'
              ;;
            *)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"archived-decoy","name":"Other task","projectId":"project-grail","cwd":"/other"}],"nextCursor":"second-archived"}}'
              ;;
          esac
          ;;
      esac
      """,
      fn workspace, trace_file ->
        assert {:ok,
                %{
                  id: "matching-thread",
                  project_id: "project-grail",
                  cwd: "/worktree/grail",
                  archived: true
                }} =
                 AppServer.find_thread_by_title("FACTORY PROBE · Grail · Native Readback", "project-grail", workspace: workspace)

        requests = listing_requests(trace_file)
        assert length(requests) == 3
        assert Enum.map(requests, &get_in(&1, ["params", "archived"])) == [false, true, true]
        assert Enum.at(requests, 2)["params"]["cursor"] == "second-archived"

        assert Enum.all?(requests, fn request ->
                 get_in(request, ["params", "searchTerm"]) == "FACTORY PROBE · Grail · Native Readback" and
                   get_in(request, ["params", "sourceKinds"]) ==
                     ~w(cli vscode exec appServer subAgent subAgentReview subAgentCompact subAgentThreadSpawn subAgentOther unknown)
               end)
      end
    )
  end

  test "thread lookup rejects a project mismatch without creating a task" do
    with_thread_listing_server(
      "project-mismatch",
      """
      case "$line" in
        *'"method":"thread/list"'*)
          case "$line" in
            *'"archived":false'*)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"wrong-project","name":"PPL-9723 · Specification Author","projectId":"project-other","cwd":"/worktree/other"}],"nextCursor":null}}'
              ;;
            *)
              printf '%s\\n' '{"id":13,"result":{"data":[],"nextCursor":null}}'
              ;;
          esac
          ;;
      esac
      """,
      fn workspace, trace_file ->
        assert {:error, {:thread_project_mismatch, "project-grail", "project-other"}} =
                 AppServer.find_thread_by_title("PPL-9723 · Specification Author", "project-grail", workspace: workspace)

        refute File.read!(trace_file) =~ ~s("method":"thread/start")
      end
    )
  end

  test "thread lookup exposes an unassigned candidate for independent project readback" do
    with_thread_listing_server(
      "project-unassigned",
      """
      case "$line" in
        *'"method":"thread/list"'*)
          case "$line" in
            *'"archived":false'*)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"unassigned-thread","name":"PPL-9723 · Specification Author","projectId":null,"cwd":"/worktree/grail"}],"nextCursor":null}}'
              ;;
            *)
              printf '%s\\n' '{"id":13,"result":{"data":[],"nextCursor":null}}'
              ;;
          esac
          ;;
      esac
      """,
      fn workspace, _trace_file ->
        assert {:candidate, %{id: "unassigned-thread", project_id: nil, cwd: "/worktree/grail", archived: false}} =
                 AppServer.find_thread_by_title("PPL-9723 · Specification Author", "project-grail", workspace: workspace)
      end
    )
  end

  test "thread lookup rejects duplicate exact names rather than selecting an arbitrary task" do
    with_thread_listing_server(
      "duplicate-thread",
      """
      case "$line" in
        *'"method":"thread/list"'*)
          case "$line" in
            *'"archived":false'*)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"thread-1","name":"PPL-9723 · Specification Author","projectId":"project-grail","cwd":"/worktree/one"}],"nextCursor":null}}'
              ;;
            *)
              printf '%s\\n' '{"id":13,"result":{"data":[{"id":"thread-2","name":"PPL-9723 · Specification Author","projectId":"project-grail","cwd":"/worktree/two"}],"nextCursor":null}}'
              ;;
          esac
          ;;
      esac
      """,
      fn workspace, _trace_file ->
        assert {:error, {:thread_name_ambiguous, ["thread-1", "thread-2"]}} =
                 AppServer.find_thread_by_title("PPL-9723 · Specification Author", "project-grail", workspace: workspace)
      end
    )
  end

  test "thread lookup reports not found only after checking active and archived tasks" do
    with_thread_listing_server(
      "not-found",
      """
      case "$line" in
        *'"method":"thread/list"'*)
          printf '%s\\n' '{"id":13,"result":{"data":[],"nextCursor":null}}'
          ;;
      esac
      """,
      fn workspace, trace_file ->
        assert {:error, :thread_not_found} =
                 AppServer.find_thread_by_title("PPL-9723 · Specification Author", "project-grail", workspace: workspace)

        assert listing_requests(trace_file)
               |> Enum.map(&get_in(&1, ["params", "archived"])) == [false, true]
      end
    )
  end

  test "thread lookup fails closed on a repeated pagination cursor" do
    with_thread_listing_server(
      "repeated-cursor",
      """
      case "$line" in
        *'"method":"thread/list"'*)
          printf '%s\\n' '{"id":13,"result":{"data":[],"nextCursor":"repeated"}}'
          ;;
      esac
      """,
      fn workspace, trace_file ->
        assert {:error, :thread_list_cursor_repeated} =
                 AppServer.find_thread_by_title("PPL-9723 · Specification Author", "project-grail", workspace: workspace)

        assert length(listing_requests(trace_file)) == 2
      end
    )
  end

  test "app server creates named durable threads and resumes the same thread with its model route" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-durable-thread-#{System.unique_integer([:positive])}"
      )

    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn -> restore_env("SYMP_TEST_CODEx_TRACE", previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "PPL-123")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-durable-thread.trace")

      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="\${SYMP_TEST_CODEx_TRACE:-/tmp/codex-durable-thread.trace}"
      printf 'RUN\\n' >> "$trace_file"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*|*'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-visible"}}}'
            ;;
          *'"method":"thread/name/set"'*)
            printf '%s\\n' '{"id":4,"result":{}}'
            ;;
          *'"method":"thread/metadata/update"'*)
            printf '%s\\n' '{"id":7,"result":{"thread":{"id":"thread-visible","projectId":"project-grail"}}}'
            ;;
          *'"method":"thread/section/move"'*)
            printf '%s\\n' '{"id":8,"result":{"thread":{"id":"thread-visible","section":{"id":"section-factory"}}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-visible"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:ok, started_session} =
               AppServer.start_session(workspace,
                 thread_name: " PPL-123: Durable Codex task ",
                 model: "gpt-5.6-terra",
                 project_id: "project-grail",
                 section_id: "section-factory",
                 reasoning_effort: "high",
                 service_name: "symphony-factory",
                 thread_source: "symphonyFactory"
               )

      assert started_session.thread_id == "thread-visible"
      assert started_session.thread_name == "PPL-123: Durable Codex task"
      assert started_session.project_id == "project-grail"
      assert started_session.section_id == "section-factory"
      assert started_session.model == "gpt-5.6-terra"
      assert started_session.reasoning_effort == "high"

      issue = %Issue{
        id: "issue-visible",
        identifier: "PPL-123",
        title: "Keep durable task name",
        description: "Ensure Codex title generation cannot replace the configured task name",
        state: "In Progress",
        url: "https://example.org/issues/PPL-123",
        labels: ["backend"]
      }

      assert {:ok, %{thread_id: "thread-visible", turn_id: "turn-visible"}} =
               AppServer.run_turn(started_session, "Run one bounded pass", issue)

      assert :ok = AppServer.stop_session(started_session)

      assert {:ok, resumed_session} =
               AppServer.start_session(workspace,
                 resume_thread_id: "thread-visible",
                 thread_name: "PPL-123: Durable Codex task",
                 model: "gpt-5.6-sol",
                 project_id: "project-grail",
                 section_id: "section-factory",
                 reasoning_effort: "xhigh",
                 on_thread_created: fn thread_id -> send(self(), {:resumed_thread, thread_id}) end
               )

      assert resumed_session.thread_id == "thread-visible"
      assert_received {:resumed_thread, "thread-visible"}
      assert resumed_session.model == "gpt-5.6-sol"
      assert resumed_session.reasoning_effort == "xhigh"
      assert :ok = AppServer.stop_session(resumed_session)

      payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      assert start_payload = Enum.find(payloads, &(&1["method"] == "thread/start"))
      assert get_in(start_payload, ["params", "ephemeral"]) == false
      assert get_in(start_payload, ["params", "serviceName"]) == "symphony-factory"
      assert get_in(start_payload, ["params", "threadSource"]) == "symphonyFactory"
      assert get_in(start_payload, ["params", "model"]) == "gpt-5.6-terra"
      refute Map.has_key?(start_payload["params"], "projectId")

      assert resume_payload = Enum.find(payloads, &(&1["method"] == "thread/resume"))
      assert get_in(resume_payload, ["params", "threadId"]) == "thread-visible"
      assert get_in(resume_payload, ["params", "model"]) == "gpt-5.6-sol"
      assert get_in(resume_payload, ["params", "excludeTurns"]) == true

      name_payloads = Enum.filter(payloads, &(&1["method"] == "thread/name/set"))
      assert length(name_payloads) == 3

      assert Enum.all?(name_payloads, fn payload ->
               get_in(payload, ["params", "threadId"]) == "thread-visible" &&
                 get_in(payload, ["params", "name"]) == "PPL-123: Durable Codex task"
             end)

      project_payloads = Enum.filter(payloads, &(&1["method"] == "thread/metadata/update"))
      assert length(project_payloads) == 2

      assert Enum.all?(project_payloads, fn payload ->
               get_in(payload, ["params", "threadId"]) == "thread-visible" &&
                 get_in(payload, ["params", "projectId"]) == "project-grail"
             end)

      section_payloads = Enum.filter(payloads, &(&1["method"] == "thread/section/move"))
      assert length(section_payloads) == 2

      assert Enum.all?(section_payloads, fn payload ->
               get_in(payload, ["params", "threadId"]) == "thread-visible" &&
                 get_in(payload, ["params", "sectionId"]) == "section-factory"
             end)

      assert payloads |> Enum.filter(&(&1["method"] == "thread/unsubscribe")) |> length() == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "exact-turn mode buffers the matching early output and ignores foreign completion events" do
    test_root = Path.join(System.tmp_dir!(), "symphony-exact-turn-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "PPL-123")
    codex_binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)

    File.write!(codex_binary, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"strict-thread"}}}' ;;
        *'"method":"thread/name/set"'*) printf '%s\\n' '{"id":4,"result":{}}' ;;
        *'"method":"thread/subscribe"'*) printf '%s\\n' '{"id":5,"result":{}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"method":"item/completed","params":{"threadId":"strict-thread","turnId":"strict-turn","item":{"type":"agentMessage","text":"early output"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"foreign-thread","turn":{"id":"foreign-turn","status":"completed","items":[]}}}'
          turn_request_id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
          printf '{"id":"%s","result":{"turn":{"id":"strict-turn"}}}\\n' "$turn_request_id"
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"foreign-turn","status":"completed","items":[]}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"strict-turn","status":"completed","items":[]}}}'
          ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, codex_command: "#{codex_binary} app-server")
    issue = %Issue{id: "issue-visible", identifier: "PPL-123", title: "Exact turn"}
    messages = self()

    assert {:ok, session} = AppServer.start_session(workspace, thread_name: "strict", on_thread_created: fn _ -> :ok end)

    assert {:ok, %{turn_id: "strict-turn"}} =
             AppServer.run_turn(session, "Review", issue,
               event_scope: :exact_turn,
               on_message: fn message -> send(messages, message) end
             )

    assert_received %{event: :session_started, thread_id: "strict-thread", turn_id: "strict-turn"}
    assert_received %{payload: %{"method" => "item/completed", "params" => %{"threadId" => "strict-thread", "turnId" => "strict-turn", "item" => %{"text" => "early output"}}}}
    assert :ok = AppServer.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "exact-turn mode processes all matching early frames in order before live reads" do
    with_exact_turn_session(
      """
      printf '%s\\n' '{"method":"item/completed","params":{"threadId":"strict-thread","turnId":"strict-turn","item":{"type":"agentMessage","text":"early verdict"}}}'
      printf '%s\\n' '{"method":"item/completed","params":{"threadId":"strict-thread","turnId":"strict-turn","item":{"type":"mcpToolCall","status":"completed","server":{"name":"Jira"},"toolName":"jira_search","result":{}}}}'
      printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"strict-turn","status":"completed","items":[]}}}'
      printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"strict-turn","status":"completed","items":[]}}}'
      printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
      """,
      fn session, issue ->
        parent = self()

        assert {:ok, %{turn_id: "strict-turn"}} =
                 AppServer.run_turn(session, "Review", issue,
                   event_scope: :exact_turn,
                   on_message: fn message -> send(parent, message) end
                 )

        assert_received %{event: :session_started, thread_id: "strict-thread", turn_id: "strict-turn"}
        assert_received %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"text" => "early verdict"}}}}
        assert_received %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "mcpToolCall"}}}}
        assert_received %{event: :turn_completed, payload: %{"params" => %{"turn" => %{"status" => "completed"}}}}
        refute_received %{event: :turn_completed}
      end
    )
  end

  test "strict completion errors override an already observed final-looking output" do
    for status <- ["failed", "interrupted", "inProgress", "unexpected"] do
      with_exact_turn_session(
        """
        printf '%s\\n' '{"method":"item/completed","params":{"threadId":"strict-thread","turnId":"strict-turn","item":{"type":"agentMessage","text":"{\\"status\\":\\"PASS\\"}"}}}'
        printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"strict-turn","status":"#{status}","items":[]}}}'
        printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
        """,
        fn session, issue ->
          result = AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)

          if status in ["failed", "interrupted"] do
            assert {:error, {:turn_failed, %{"status" => ^status}}} = result
          else
            assert {:error, {:worker_turn_status_invalid, ^status}} = result
          end
        end
      )
    end

    with_exact_turn_session(
      """
      printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"strict-turn","items":[]}}}'
      printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
      """,
      fn session, issue ->
        assert {:error, {:worker_turn_status_invalid, nil}} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
      end
    )
  end

  test "strict error notifications honor willRetry without accepting retryable failure as completion" do
    with_exact_turn_session(
      """
      printf '%s\\n' '{"method":"error","params":{"threadId":"strict-thread","turnId":"strict-turn","error":{"message":"retrying"},"willRetry":true}}'
      printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"strict-turn","status":"completed","items":[]}}}'
      printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
      """,
      fn session, issue ->
        assert {:ok, %{turn_id: "strict-turn"}} = AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
      end
    )

    with_exact_turn_session(
      """
      printf '%s\\n' '{"method":"error","params":{"threadId":"strict-thread","turnId":"strict-turn","error":{"message":"terminal failure"},"willRetry":false}}'
      printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
      """,
      fn session, issue ->
        assert {:error, {:worker_turn_error, %{"message" => "terminal failure"}}} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
      end
    )
  end

  test "strict mode refuses unattributable approval requests without executing tools" do
    with_exact_turn_session(
      """
      printf '%s\\n' '{"id":77,"method":"item/commandExecution/requestApproval","params":{"threadId":"foreign-thread","turnId":"foreign-turn","command":"mutate"}}'
      """,
      fn session, issue ->
        parent = self()

        executor = fn _tool, _args ->
          send(parent, :tool_executed)
          {:ok, %{}}
        end

        assert {:error, :worker_request_attribution_unsupported} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn, tool_executor: executor)

        refute_received :tool_executed
      end
    )
  end

  test "an arity-three legacy executor does not grant exact-turn file-worker capabilities" do
    with_exact_turn_session(
      """
      printf '%s\\n' '{"id":77,"method":"item/tool/call","params":{"threadId":"thread-720","turnId":"turn-720","callId":"call","tool":"repo_write","arguments":{}}}'
      """,
      fn session, issue ->
        executor = fn _tool, _args, _identity ->
          send(self(), :unexpected_tool)
          %{"success" => true}
        end

        assert {:error, :worker_request_attribution_unsupported} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn, tool_executor: executor)

        refute_received :unexpected_tool
      end
    )
  end

  test "strict mode rejects missing identities and clears failed invocation buffers" do
    with_exact_turn_session(
      """
      case "$turn_count" in
        1)
          printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"strict-turn","status":"completed","items":[]}}}'
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
          ;;
        *)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"next-turn"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"next-turn","status":"completed","items":[]}}}'
          ;;
      esac
      """,
      fn session, issue ->
        Process.put(:strict_fixture_turn_count, 0)
        on_exit(fn -> Process.delete(:strict_fixture_turn_count) end)

        assert {:error, {:worker_event_identity_missing, "turn/completed"}} =
                 AppServer.run_turn(session, "First", issue, event_scope: :exact_turn)

        assert {:ok, %{turn_id: "next-turn"}} = AppServer.run_turn(session, "Second", issue, event_scope: :exact_turn)
      end,
      turn_count: true
    )
  end

  test "strict early-event frame and byte limits fail with the named overflow error" do
    for mode <- [:frames, :bytes] do
      script =
        case mode do
          :frames ->
            "i=0\nwhile [ $i -lt 257 ]; do printf '%s\\n' '{\"method\":\"item/completed\",\"params\":{\"threadId\":\"other\",\"turnId\":\"other\",\"item\":{}}}'; i=$((i+1)); done\nprintf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"strict-turn\"}}}'"

          :bytes ->
            """
            blob=$(head -c 600000 /dev/zero | tr '\\000' x)
            printf '{"method":"item/completed","params":{"threadId":"other","turnId":"other","item":{"text":"%s"}}}\\n' "$blob"
            printf '{"method":"item/completed","params":{"threadId":"other","turnId":"other","item":{"text":"%s"}}}\\n' "$blob"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
            """
        end

      with_exact_turn_session(script, fn session, issue ->
        assert {:error, :worker_event_buffer_overflow} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
      end)
    end
  end

  test "strict overflow is returned immediately even when turn start never responds" do
    script =
      "i=0\nwhile [ $i -lt 257 ]; do printf '%s\\n' '{\"method\":\"item/completed\",\"params\":{\"threadId\":\"other\",\"turnId\":\"other\",\"item\":{}}}'; i=$((i+1)); done"

    with_exact_turn_session(
      script,
      fn session, issue ->
        started_at = System.monotonic_time(:millisecond)

        assert {:error, :worker_event_buffer_overflow} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)

        assert System.monotonic_time(:millisecond) - started_at < 1_000
      end,
      timeout_ms: 5_000
    )
  end

  test "strict response read timeout remains below the absolute turn budget" do
    with_exact_turn_session(
      "",
      fn session, issue ->
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.dirname(session.workspace),
          codex_command: Config.settings!().codex.command,
          codex_turn_timeout_ms: 200,
          codex_read_timeout_ms: 20
        )

        started_at = System.monotonic_time(:millisecond)
        assert {:error, :response_timeout} = AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
        assert System.monotonic_time(:millisecond) - started_at < 100
      end,
      timeout_ms: 200
    )
  end

  test "late response from a timed-out strict invocation cannot satisfy the next turn" do
    script =
      """
      case "$turn_count" in
        1)
          sleep 0.25
          printf '%s\\n' '{"method":"item/completed","params":{"threadId":"strict-thread","turnId":"old-turn","item":{"type":"agentMessage","text":"{\\"status\\":\\"PASS\\",\\"findings\\":[],\\"required_questions\\":[]}"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"old-turn","status":"completed","items":[]}}}'
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"old-turn"}}}'
          ;;
        *)
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"strict-thread","turn":{"id":"new-turn","status":"failed","items":[]}}}'
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"new-turn"}}}'
          ;;
      esac
      """

    with_exact_turn_session(
      script,
      fn session, issue ->
        assert {:error, :turn_timeout} = AppServer.run_turn(session, "First", issue, event_scope: :exact_turn)

        assert {:error, {:turn_failed, %{"id" => "new-turn", "status" => "failed"}}} =
                 AppServer.run_turn(session, "Second", issue, event_scope: :exact_turn)
      end,
      timeout_ms: 200,
      read_timeout_ms: 1_000,
      turn_count: true
    )
  end

  test "strict absolute deadline expires under continuous unrelated event noise" do
    with_exact_turn_session(
      """
      i=0
      while [ $i -lt 50000 ]; do
        printf '%s\\n' '{"method":"unrelated/noise","params":{}}'
        i=$((i+1))
      done
      printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
      """,
      fn session, issue ->
        assert {:error, :turn_timeout} = AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
      end,
      timeout_ms: 40
    )
  end

  test "strict missing item identity is an error rather than collectable output" do
    with_exact_turn_session(
      """
      printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"{\\"status\\":\\"PASS\\"}"}}}'
      printf '%s\\n' '{"id":3,"result":{"turn":{"id":"strict-turn"}}}'
      """,
      fn session, issue ->
        assert {:error, {:worker_event_identity_missing, "item/completed"}} =
                 AppServer.run_turn(session, "Review", issue, event_scope: :exact_turn)
      end
    )
  end

  test "app server fails when a requested project cannot be bound" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-project-not-found-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "PPL-123")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"unbound-thread"}}}'
            ;;
          *'"method":"thread/metadata/update"'*)
            printf '%s\\n' '{"id":7,"error":{"code":-32600,"message":"project not found: missing-project"}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error, {:project_binding_failed, "missing-project", _reason}} =
               AppServer.start_session(workspace, project_id: "missing-project")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server refuses to substitute a different project for the requested desktop project" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-project-root-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "PPL-123")
      repository_root = Path.join(test_root, "grail")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "requests.jsonl")

      File.mkdir_p!(workspace)
      File.mkdir_p!(repository_root)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        printf '%s\\n' "$line" >> "#{trace_file}"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"project/list"'*)
            printf '%s\\n' '{"id":12,"result":{"data":[{"id":"secondary-project","roots":[{"path":"#{test_root}/other"},{"path":"#{repository_root}"}]},{"id":"local-grail-project","roots":[{"path":"#{repository_root}"}]}],"nextCursor":null}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"bound-thread"}}}'
            ;;
          *'"method":"thread/metadata/update"'*)
            case "$line" in
              *'"projectId":"local-grail-project"'*)
                printf '%s\\n' '{"id":7,"result":{"thread":{"id":"bound-thread","projectId":"local-grail-project"}}}'
                ;;
              *)
                printf '%s\\n' '{"id":7,"error":{"code":-32600,"message":"incorrect project binding"}}'
                ;;
            esac
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error, {:project_id_mismatch, "desktop-grail-project", "local-grail-project"}} =
               AppServer.start_session(workspace,
                 project_id: "desktop-grail-project",
                 project_root: repository_root
               )

      refute File.read!(trace_file) =~ ~s("method":"thread/start")

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 project_id: "local-grail-project",
                 project_root: repository_root
               )

      assert session.project_id == "local-grail-project"
      assert :ok = AppServer.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not start a worker for a secondary-only project root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-secondary-root-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "PPL-123")
      repository_root = Path.join(test_root, "grail")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.mkdir_p!(repository_root)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"project/list"'*)
            printf '%s\\n' '{"id":12,"result":{"data":[{"id":"other-project","roots":[{"path":"#{test_root}/other"},{"path":"#{repository_root}"}]}],"nextCursor":null}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"wrong-thread"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error, {:project_root_not_found, _root}} =
               AppServer.start_session(workspace,
                 project_id: "desktop-grail-project",
                 project_root: repository_root
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "resume cannot replace the persisted controller task identity" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-resume-mismatch-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"unexpected-thread"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error, {:resumed_thread_id_mismatch, "existing-thread", "unexpected-thread"}} =
               AppServer.start_session(workspace,
                 resume_thread_id: "existing-thread",
                 on_thread_created: fn thread_id -> send(self(), {:durable_thread_created, thread_id}) end
               )

      refute_received {:durable_thread_created, _thread_id}
    after
      File.rm_rf(test_root)
    end
  end

  test "controller sessions fork durable history when a stale writer blocks resume" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-writer-recovery-#{System.unique_integer([:positive])}"
      )

    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")
    on_exit(fn -> restore_env("SYMP_TEST_CODEx_TRACE", previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-writer-recovery.trace")

      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="\${SYMP_TEST_CODEx_TRACE:-/tmp/codex-writer-recovery.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"thread old-thread already has an active writer"}}'
            ;;
          *'"method":"thread/read"'*)
            printf '%s\\n' '{"id":9,"result":{"thread":{"id":"old-thread","status":{"type":"idle"}}}}'
            ;;
          *'"method":"thread/fork"'*)
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"recovered-thread"}}}'
            ;;
          *'"method":"thread/name/set"'*)
            printf '%s\\n' '{"id":4,"result":{}}'
            ;;
          *'"method":"thread/metadata/update"'*)
            printf '%s\\n' '{"id":7,"result":{"thread":{"id":"recovered-thread","projectId":"project-grail"}}}'
            ;;
          *'"method":"thread/section/move"'*)
            printf '%s\\n' '{"id":8,"result":{"thread":{"id":"recovered-thread","section":{"id":"section-factory"}}}}'
            ;;
          *'"method":"thread/archive"'*)
            printf '%s\\n' '{"id":10,"result":{}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 resume_thread_id: "old-thread",
                 fork_on_active_writer: true,
                 project_id: "project-grail",
                 section_id: "section-factory",
                 thread_name: "Software Factory Orchestrator"
               )

      assert session.thread_id == "recovered-thread"
      assert session.forked_from_thread_id == "old-thread"
      assert :ok = AppServer.archive_thread(session, session.forked_from_thread_id)
      assert :ok = AppServer.stop_session(session)

      payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      assert fork_payload = Enum.find(payloads, &(&1["method"] == "thread/fork"))
      assert read_payload = Enum.find(payloads, &(&1["method"] == "thread/read"))
      assert get_in(read_payload, ["params", "threadId"]) == "old-thread"
      assert get_in(read_payload, ["params", "includeTurns"]) == false
      assert get_in(fork_payload, ["params", "threadId"]) == "old-thread"
      assert get_in(fork_payload, ["params", "ephemeral"]) == false
      assert get_in(fork_payload, ["params", "excludeTurns"]) == true
      assert get_in(fork_payload, ["params", "deferGoalContinuation"]) == true

      assert project_payload = Enum.find(payloads, &(&1["method"] == "thread/metadata/update"))
      assert get_in(project_payload, ["params", "threadId"]) == "recovered-thread"
      assert get_in(project_payload, ["params", "projectId"]) == "project-grail"

      assert section_payload = Enum.find(payloads, &(&1["method"] == "thread/section/move"))
      assert get_in(section_payload, ["params", "threadId"]) == "recovered-thread"
      assert get_in(section_payload, ["params", "sectionId"]) == "section-factory"

      assert archive_payload = Enum.find(payloads, &(&1["method"] == "thread/archive"))
      assert get_in(archive_payload, ["params", "threadId"]) == "old-thread"
    after
      File.rm_rf(test_root)
    end
  end

  test "controller sessions do not fork while the conflicting task is still active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-active-writer-#{System.unique_integer([:positive])}"
      )

    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")
    on_exit(fn -> restore_env("SYMP_TEST_CODEx_TRACE", previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-active-writer.trace")

      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="\${SYMP_TEST_CODEx_TRACE:-/tmp/codex-active-writer.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"thread old-thread already has an active writer"}}'
            ;;
          *'"method":"thread/read"'*)
            printf '%s\\n' '{"id":9,"result":{"thread":{"id":"old-thread","status":{"type":"active","activeFlags":[]}}}}'
            ;;
          *'"method":"thread/fork"'*)
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"unexpected-fork"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error, {:response_error, %{"message" => message}}} =
               AppServer.start_session(workspace,
                 resume_thread_id: "old-thread",
                 fork_on_active_writer: true
               )

      assert message =~ "active writer"

      payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(payloads, &(&1["method"] == "thread/read"))
      refute Enum.any?(payloads, &(&1["method"] == "thread/fork"))
    after
      File.rm_rf(test_root)
    end
  end

  test "app server waits for every required MCP server before returning a controller session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-ready-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"Jira","status":"starting"}}'
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"GitLab","status":"ready"}}'
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-mcp-ready"}}}'
            ;;
          *'"method":"thread/name/set"'*)
            printf '%s\n' '{"id":4,"result":{}}'
            sleep 0.05
            printf '%s\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"Jira","status":"ready"}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 thread_name: "Software Factory Orchestrator",
                 required_mcp_servers: ["Jira", "GitLab"],
                 mcp_startup_timeout_ms: 1_000
               )

      assert session.thread_id == "thread-mcp-ready"
      assert :ok = AppServer.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails closed when a required MCP server fails to start" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-mcp-failed"}}}'
            printf '%s\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"Jira","status":"failed","failureReason":"authentication failed"}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error,
              {:required_mcp_server_failed, "Jira",
               %{
                 "status" => "failed",
                 "error" => nil,
                 "failure_reason" => "authentication failed"
               }}} =
               AppServer.start_session(workspace,
                 required_mcp_servers: ["Jira"],
                 mcp_startup_timeout_ms: 1_000,
                 on_thread_created: fn thread_id -> send(self(), {:durable_thread_created, thread_id}) end
               )

      assert_received {:durable_thread_created, "thread-mcp-failed"}
    after
      File.rm_rf(test_root)
    end
  end

  test "one ephemeral MCP session serves repeated calls with a factory-scoped startup override" do
    test_root = Path.join(System.tmp_dir!(), "symphony-mcp-reuse-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")
      args_file = Path.join(test_root, "launch-args")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      printf '%s\n' "$@" > '#{args_file}'
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"shared-mcp-thread"}}}'
            printf '%s\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"GitLab","status":"ready"}}'
            ;;
          *'"method":"mcpServer/tool/call"'*)
            printf '%s\n' '{"id":14,"result":{"content":[]}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, codex_command: "#{codex_binary} app-server")

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 ephemeral: true,
                 required_mcp_servers: ["GitLab"],
                 mcp_startup_timeout_ms: 1_000,
                 gitlab_mcp_startup_timeout_sec: 45
               )

      assert {:ok, %{"content" => []}} = AppServer.call_mcp_tool_in_session(session, "GitLab", "whoami", %{})
      assert {:ok, %{"content" => []}} = AppServer.call_mcp_tool_in_session(session, "GitLab", "whoami", %{})
      assert :ok = AppServer.stop_session(session)
      assert File.read!(args_file) =~ "mcp_servers.GitLab.startup_timeout_sec=45"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server requires an installed callable app before returning a session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-app-ready-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-app-ready"}}}'
            ;;
          *'"method":"app/installed"'*)
            printf '%s\n' '{"id":11,"result":{"apps":[{"id":"polaris-app","runtimeName":"Polaris","enabled":true,"callable":true}]}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 required_apps: ["Polaris"]
               )

      assert session.thread_id == "thread-app-ready"
      assert :ok = AppServer.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails closed when a required app is not callable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-app-unavailable-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "FACTORY-CONTROLLER")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-app-unavailable"}}}'
            ;;
          *'"method":"app/installed"'*)
            printf '%s\n' '{"id":11,"result":{"apps":[{"id":"polaris-app","runtimeName":"Polaris","enabled":true,"callable":false}]}}'
            ;;
          *'"method":"thread/unsubscribe"'*)
            printf '%s\n' '{"id":6,"result":{"status":"unsubscribed"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:error,
              {:required_app_unavailable, "Polaris",
               %{
                 "id" => "polaris-app",
                 "runtimeName" => "Polaris",
                 "enabled" => true,
                 "callable" => false
               }}} = AppServer.start_session(workspace, required_apps: ["Polaris"])
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "turn timeout resets on stream updates and fires after silence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TIMEOUT")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}' ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"item/updated","params":{"item":{"id":"one"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"item/updated","params":{"item":{"id":"two"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 250
      )

      issue = %Issue{
        id: "issue-turn-timeout",
        identifier: "MT-TIMEOUT",
        title: "Stream timeout",
        description: "Keep active streams alive",
        state: "In Progress",
        url: "https://example.org/issues/MT-TIMEOUT",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "stream updates", issue)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-silent"}}}' ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-silent"}}}'
            sleep 0.4
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 100
      )

      assert {:error, :turn_timeout} = AppServer.run(workspace, "silent turn", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, %{"method" => "item/commandExecution/requestApproval"}}} =
               AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, %{"method" => "item/tool/requestUserInput"}}} =
               AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "scoped Jira comment approval requires matching started tool, issue, body, and host question" do
    question = %{
      "header" => "Approve app tool call?",
      "id" => "mcp_tool_call_approval_call-720",
      "isOther" => false,
      "isSecret" => false,
      "options" => [
        %{"label" => "Approve Once"},
        %{"label" => "Approve this Session"},
        %{"label" => "Deny"},
        %{"label" => "Cancel"}
      ],
      "question" => "The Jira MCP server wants to run the tool \"jira_add_comment\", which may modify or delete data. Allow this action?"
    }

    request = %{
      "id" => 110,
      "method" => "item/tool/requestUserInput",
      "params" => %{"itemId" => "call-720", "questions" => [question]}
    }

    item = %{
      "id" => "call-720",
      "type" => "mcpToolCall",
      "server" => "Jira",
      "tool" => "jira_add_comment",
      "arguments" => %{"issue_key" => "MT-720", "body" => "Approved marker-720"}
    }

    assert {{:ok, _result}, approved_payloads} = run_scoped_approval_fixture(item, request)

    assert Enum.any?(approved_payloads, fn payload ->
             get_in(payload, ["params", "approvalPolicy"]) == "on-request"
           end)

    assert Enum.any?(approved_payloads, fn payload ->
             get_in(payload, ["result", "answers", question["id"], "answers"]) == ["Approve Once"]
           end)

    denied_items = [
      %{item | "server" => "GitLab"},
      %{item | "tool" => "jira_update_issue"},
      %{item | "arguments" => %{"issue_key" => "MT-721", "body" => "Approved marker-720"}},
      %{item | "arguments" => %{"issue_key" => "MT-720", "body" => "Approved marker-720 plus unapproved text"}},
      %{item | "arguments" => %{"issue_key" => "MT-720", "body" => "Approved marker-720", "visibility" => "public"}},
      nil
    ]

    for denied_item <- denied_items do
      assert {{:error, {:turn_input_required, %{"method" => "item/tool/requestUserInput"}}}, denied_payloads} =
               run_scoped_approval_fixture(denied_item, request)

      refute Enum.any?(denied_payloads, &(&1["id"] == 110 and is_map(&1["result"])))
    end

    altered_request = put_in(request, ["params", "questions", Access.at(0), "question"], "Approve Jira, please?")

    assert {{:error, {:turn_input_required, %{"method" => "item/tool/requestUserInput"}}}, _payloads} =
             run_scoped_approval_fixture(item, altered_request)

    command_request = %{"id" => 110, "method" => "item/commandExecution/requestApproval", "params" => %{}}

    assert {{:error, {:approval_required, %{"method" => "item/commandExecution/requestApproval"}}}, payloads} =
             run_scoped_approval_fixture(item, command_request)

    refute Enum.any?(payloads, &(&1["id"] == 110 and is_map(&1["result"])))

    file_request = %{"id" => 110, "method" => "item/fileChange/requestApproval", "params" => %{}}

    assert {{:error, {:approval_required, %{"method" => "item/fileChange/requestApproval"}}}, payloads} =
             run_scoped_approval_fixture(item, file_request)

    refute Enum.any?(payloads, &(&1["id"] == 110 and is_map(&1["result"])))

    assert {{:error, {:turn_input_required, %{"method" => "item/tool/requestUserInput"}}}, replay_payloads} =
             run_scoped_approval_fixture(item, request, replay: true)

    assert Enum.any?(replay_payloads, &(&1["id"] == 110 and is_map(&1["result"])))
    refute Enum.any?(replay_payloads, &(&1["id"] == 111 and is_map(&1["result"])))
  end

  test "scoped Jira label approval accepts only exact labels on the expected issue" do
    question = %{
      "header" => "Approve app tool call?",
      "id" => "mcp_tool_call_approval_call-720",
      "isOther" => false,
      "isSecret" => false,
      "options" => [
        %{"label" => "Approve Once"},
        %{"label" => "Approve this Session"},
        %{"label" => "Deny"},
        %{"label" => "Cancel"}
      ],
      "question" => "The Jira MCP server wants to run the tool \"jira_update_issue\", which may modify or delete data. Allow this action?"
    }

    request = %{
      "id" => 110,
      "method" => "item/tool/requestUserInput",
      "params" => %{"itemId" => "call-720", "questions" => [question]}
    }

    item = %{
      "id" => "call-720",
      "type" => "mcpToolCall",
      "server" => "Jira",
      "tool" => "jira_update_issue",
      "arguments" => %{"issue_key" => "MT-720", "fields" => Jason.encode!(%{"labels" => ["ai-ready", "repo-grail"]})}
    }

    approval = %{server: "Jira", tool: "jira_update_issue", issue_key: "MT-720", labels_equals: ["ai-ready", "repo-grail"]}

    assert {{:ok, _result}, approved_payloads} = run_scoped_approval_fixture(item, request, approvals: [approval])

    assert Enum.any?(approved_payloads, fn payload ->
             get_in(payload, ["result", "answers", question["id"], "answers"]) == ["Approve Once"]
           end)

    denied_items = [
      %{item | "arguments" => %{"issue_key" => "MT-721", "fields" => Jason.encode!(%{"labels" => ["ai-ready", "repo-grail"]})}},
      %{item | "arguments" => %{"issue_key" => "MT-720", "fields" => Jason.encode!(%{"labels" => ["ai-ready"]})}},
      %{item | "arguments" => %{"issue_key" => "MT-720", "fields" => Jason.encode!(%{"labels" => ["ai-ready", "repo-grail"], "summary" => "Unapproved"})}},
      %{item | "arguments" => %{"issue_key" => "MT-720"}},
      %{item | "arguments" => Map.put(item["arguments"], "attachments", "/tmp/unapproved")},
      %{item | "tool" => "jira_add_comment"}
    ]

    for denied_item <- denied_items do
      assert {{:error, {:turn_input_required, %{"method" => "item/tool/requestUserInput"}}}, payloads} =
               run_scoped_approval_fixture(denied_item, request, approvals: [approval])

      refute Enum.any?(payloads, &(&1["id"] == 110 and is_map(&1["result"])))
    end

    comment_approval = %{
      server: "Jira",
      tool: "jira_add_comment",
      issue_key: "MT-720",
      body_equals: "Approved marker-720"
    }

    second_item = %{
      item
      | "id" => "call-721",
        "tool" => "jira_add_comment",
        "arguments" => %{"issue_key" => "MT-720", "body" => "Approved marker-720"}
    }

    second_request = %{
      request
      | "id" => 111,
        "params" => %{
          "itemId" => "call-721",
          "questions" => [
            %{
              question
              | "id" => "mcp_tool_call_approval_call-721",
                "question" => "The Jira MCP server wants to run the tool \"jira_add_comment\", which may modify or delete data. Allow this action?"
            }
          ]
        }
    }

    assert {{:ok, _result}, dual_payloads} =
             run_scoped_approval_fixture(item, request,
               approvals: [comment_approval, approval],
               replay: true,
               second_item: second_item,
               second_request: second_request
             )

    assert Enum.any?(dual_payloads, &(&1["id"] == 110 and is_map(&1["result"])))
    assert Enum.any?(dual_payloads, &(&1["id"] == 111 and is_map(&1["result"])))
  end

  test "app server blocks freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle generic tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Proceed with the requested action.\",\"label\":\"Allow\"},{\"description\":\"Do not proceed.\",\"label\":\"Deny\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input block",
        description: "Ensure option prompts require operator input",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server keeps inherited stderr out of protocol events and Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Separate stderr",
        description: "Ensure codex stderr does not contaminate the protocol stream",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Separate stderr from protocol", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      refute log =~ "warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not pass tracker credentials to the local Codex child" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-secret-env-#{System.unique_integer([:positive])}"
      )

    custom_secret_env = "SYMP_CUSTOM_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    profile_marker_env = "SYMP_TEST_BASH_PROFILE_LOADED_#{System.unique_integer([:positive])}"
    previous_secret = System.get_env("LINEAR_API_KEY")
    previous_custom_secret = System.get_env(custom_secret_env)
    previous_home = System.get_env("HOME")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_secret)
      restore_env(custom_secret_env, previous_custom_secret)
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      bash_home = Path.join(test_root, "bash-home")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SECRET")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-secret-env.trace")

      File.mkdir_p!(bash_home)
      File.mkdir_p!(workspace)

      File.write!(Path.join(bash_home, ".bash_profile"), """
      export LINEAR_API_KEY='profile-canonical-secret-that-must-not-reach-child'
      export #{custom_secret_env}='profile-custom-secret-that-must-not-reach-child'
      export #{profile_marker_env}=1
      """)

      System.put_env("LINEAR_API_KEY", "canonical-secret-that-must-not-reach-child")
      System.put_env(custom_secret_env, "custom-secret-that-must-not-reach-child")
      System.put_env("HOME", bash_home)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      printf 'PROFILE_LOADED:%s\n' "$#{profile_marker_env}" >> "$trace_file"
      printf 'CANONICAL_SECRET:%s\n' "$LINEAR_API_KEY" >> "$trace_file"
      printf 'CUSTOM_SECRET:%s\n' "$#{custom_secret_env}" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-secret"}}}'
            ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-secret"}}}'
            ;;
          4)
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "$#{custom_secret_env}",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-secret-env",
        identifier: "MT-SECRET",
        title: "Keep tracker auth in Symphony",
        description: "Ensure the child cannot bypass the centrally-authenticated tool boundary",
        state: "In Progress",
        url: "https://example.org/issues/MT-SECRET",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Do not inherit tracker auth", issue)
      assert File.read!(trace_file) =~ "PROFILE_LOADED:1\n"
      assert File.read!(trace_file) =~ "CANONICAL_SECRET:\n"
      assert File.read!(trace_file) =~ "CUSTOM_SECRET:\n"
      refute File.read!(trace_file) =~ "secret-that-must-not-reach-child"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "unset LINEAR_API_KEY"
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp fixture_runtime do
    %{
      "codexHome" => System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
      "platformFamily" => "unix",
      "platformOs" => "macos",
      "userAgent" => "symphony-orchestrator/0.160.0 (fixture)"
    }
  end

  defp with_thread_listing_server(test_name, list_handler, callback, runtime \\ fixture_runtime()) do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-thread-lookup-#{test_name}-#{System.unique_integer([:positive])}")

    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "lookup")
    trace_file = Path.join(test_root, "lookup.trace")
    codex_binary = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-thread-lookup.trace}"
      printf '%s\\n' "$$" > "$trace_file.pid"
      trap 'printf "terminated\\n" > "$trace_file.terminated"; exit 143' TERM
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*) printf '%s\\n' '#{Jason.encode!(%{"id" => 1, "result" => runtime})}' ;;
        esac
        #{list_handler}
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      callback.(workspace, trace_file)
    after
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
      File.rm_rf(test_root)
    end
  end

  defp listing_requests(trace_file) do
    trace_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_leading(&1, "JSON:"))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["method"] == "thread/list"))
  end

  defp run_scoped_approval_fixture(item, request, opts \\ []) do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-scoped-approval-#{System.unique_integer([:positive])}")

    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")
    trace_file = Path.join(test_root, "codex.trace")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-720")
    codex_binary = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      started =
        if is_map(item) do
          Jason.encode!(%{"method" => "item/started", "params" => %{"item" => item}})
        else
          ""
        end

      replay_started =
        if Keyword.get(opts, :replay, false) do
          second_item = Keyword.get(opts, :second_item, %{item | "id" => "call-721"})

          Jason.encode!(%{
            "method" => "item/started",
            "params" => %{"item" => second_item}
          })
        else
          ""
        end

      replay_request =
        if Keyword.get(opts, :replay, false) do
          Keyword.get(
            opts,
            :second_request,
            request
            |> Map.put("id", 111)
            |> put_in(["params", "itemId"], "call-721")
            |> put_in(["params", "questions", Access.at(0), "id"], "mcp_tool_call_approval_call-721")
          )
          |> Jason.encode!()
        else
          ""
        end

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-scoped-approval.trace}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-720"}}}' ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-720"}}}'
            if [ -n '#{started}' ]; then printf '%s\\n' '#{started}'; fi
            printf '%s\\n' '#{Jason.encode!(request)}'
            ;;
          *'"id":110'*)
            if [ -n '#{replay_started}' ]; then
              printf '%s\\n' '#{replay_started}'
              printf '%s\\n' '#{replay_request}'
            else
              printf '%s\\n' '{"method":"turn/completed"}'
            fi
            ;;
          *'"id":111'*) printf '%s\\n' '{"method":"turn/completed"}' ;;
          *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{id: "issue-720", identifier: "MT-720", title: "Scoped approval"}

      approvals =
        Keyword.get(opts, :approvals, [
          %{server: "Jira", tool: "jira_add_comment", issue_key: "MT-720", body_equals: "Approved marker-720"}
        ])

      result =
        AppServer.run(workspace, "Post one exact Jira comment", issue,
          approval_policy: "on-request",
          allowed_mcp_tool_approvals: approvals
        )

      payloads =
        trace_file
        |> then(fn path -> if File.exists?(path), do: File.read!(path), else: "" end)
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      {result, payloads}
    after
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
      File.rm_rf(test_root)
    end
  end

  defp with_exact_turn_session(turn_script, callback, opts \\ []) do
    test_root = Path.join(System.tmp_dir!(), "symphony-exact-fixture-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "PPL-123")
    codex_binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)
    turn_count_init = if Keyword.get(opts, :turn_count, false), do: "turn_count=0", else: ""
    turn_count_step = if Keyword.get(opts, :turn_count, false), do: "turn_count=$((turn_count+1))", else: ""

    File.write!(codex_binary, """
    #!/bin/sh
    #{turn_count_init}
    printf() {
      case "$*" in
        *'"id":3'*) command printf "$@" | sed "s/\\\"id\\\":3/\\\"id\\\":\\\"$turn_request_id\\\"/g" ;;
        *) command printf "$@" ;;
      esac
    }
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"strict-thread","projectId":"project-grail"}}}' ;;
        *'"method":"thread/name/set"'*) printf '%s\\n' '{"id":4,"result":{}}' ;;
        *'"method":"thread/metadata/update"'*) printf '%s\\n' '{"id":7,"result":{"thread":{"id":"strict-thread","projectId":"project-grail"}}}' ;;
        *'"method":"turn/start"'*)
          turn_request_id=$(command printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          #{turn_count_step}
          #{turn_script}
          ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}' ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_turn_timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      codex_read_timeout_ms: 5_000
    )

    issue = %Issue{id: "issue-strict", identifier: "PPL-123", title: "Strict turn"}

    try do
      assert {:ok, session} = AppServer.start_session(workspace, thread_name: "strict fixture", project_id: "project-grail")

      try do
        callback.(session, issue)
      after
        AppServer.stop_session(session)
      end
    after
      File.rm_rf!(test_root)
    end
  end
end
