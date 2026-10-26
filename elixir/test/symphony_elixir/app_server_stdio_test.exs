defmodule SymphonyElixir.AppServerStdioTest do
  use SymphonyElixir.TestSupport

  test "local stderr cannot split a valid MCP stdout response" do
    handler = ~S"""
    printf 'fixture diagnostic before response\n' >&2
    printf '{"id":14,"result":'
    printf 'fixture diagnostic between stdout chunks\n' >&2
    printf '{"content":[]}}\n'
    """

    with_stdio_server(handler, fn session ->
      for _ <- 1..2 do
        assert {:ok, %{"content" => []}} = AppServer.call_mcp_tool_in_session(session, "GitLab", "fixture_read", %{})
      end
    end)
  end

  for {name, output, expected} <- [
        {"malformed stdout", "{invalid-json}", :mcp_tool_protocol_invalid},
        {"non-map stdout", "[]", :mcp_tool_protocol_invalid},
        {"unrecognized stdout map", "{}", :mcp_tool_protocol_invalid},
        {"approval request", ~s({"id":99,"method":"item/tool/requestUserInput","params":{}}), :mcp_tool_approval_required}
      ] do
    test "local transport still rejects #{name}" do
      with_stdio_server("printf '%s\\n' '#{unquote(output)}'", fn session ->
        assert {:error, unquote(expected)} = AppServer.call_mcp_tool_in_session(session, "GitLab", "fixture_read", %{})
      end)
    end
  end

  test "diagnostics alone do not satisfy a response or extend its deadline" do
    handler = ~S"""
    n=0
    while [ "$n" -lt 20 ]; do
      printf 'fixture diagnostic while pending\n' >&2
      printf '%s\n' '{"method":"fixture/progress","params":{}}'
      n=$((n + 1))
      sleep 0.02
    done
    """

    with_stdio_server(
      handler,
      fn session ->
        started = System.monotonic_time(:millisecond)
        assert {:error, :mcp_tool_response_timeout} = AppServer.call_mcp_tool_in_session(session, "GitLab", "fixture_read", %{})
        assert System.monotonic_time(:millisecond) - started < 1_000
      end,
      100
    )
  end

  for {name, handler, expected} <- [
        {"partial stdout EOF", ~S(printf '{"id":14,"result":'; exit 0), {:port_exit, 0}},
        {"nonzero child exit", "exit 7", {:port_exit, 7}},
        {"oversized stdout", ~S(head -c 3145728 /dev/zero | tr '\000' x; printf '\n'), :mcp_tool_result_too_large},
        {"stderr-only pending response", "n=0; while [ \"$n\" -lt 20 ]; do printf 'fixture diagnostic only\\n' >&2; n=$((n + 1)); sleep 0.02; done", :mcp_tool_response_timeout}
      ] do
    test "local transport preserves #{name} denial" do
      with_stdio_server(
        unquote(handler),
        fn session ->
          assert {:error, unquote(Macro.escape(expected))} = AppServer.call_mcp_tool_in_session(session, "GitLab", "fixture_read", %{})
        end,
        if(unquote(name) == "stderr-only pending response", do: 100, else: 1_000)
      )
    end
  end

  defp with_stdio_server(handler, operation, timeout \\ 1_000) do
    root = Path.join(System.tmp_dir!(), "symphony-stdio-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "controller")
    executable = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)

    File.write!(executable, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"stdio-fixture"}}}'
          printf '%s\\n' '{"method":"mcpServer/startupStatus/updated","params":{"name":"GitLab","status":"ready"}}' ;;
        *'"method":"mcpServer/tool/call"'*) #{handler} ;;
        *'"method":"thread/unsubscribe"'*) printf '%s\\n' '{"id":6,"result":{"status":"unsubscribed"}}'; break ;;
      esac
    done
    """)

    File.chmod!(executable, 0o700)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{executable} app-server",
      codex_read_timeout_ms: max(timeout, 1_000)
    )

    try do
      assert {:ok, session} =
               AppServer.start_session(
                 workspace,
                 ephemeral: true,
                 required_mcp_servers: ["GitLab"],
                 mcp_startup_timeout_ms: 1_000
               )

      pid = session.metadata.codex_app_server_pid

      write_workflow_file!(
        Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{executable} app-server",
        codex_read_timeout_ms: timeout
      )

      try do
        operation.(session)
      after
        if :erlang.port_info(session.port) != :undefined, do: AppServer.stop_session(session)
        assert :erlang.port_info(session.port) == :undefined

        assert Enum.reduce_while(1..100, false, fn _, _ ->
                 {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)

                 if status != 0,
                   do: {:halt, true},
                   else:
                     (
                       Process.sleep(10)
                       {:cont, false}
                     )
               end)
      end
    after
      File.rm_rf!(root)
    end
  end
end
