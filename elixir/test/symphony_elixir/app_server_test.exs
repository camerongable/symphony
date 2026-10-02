defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

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

  test "app server captures codex side output and logs it through Logger" do
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
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
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

  defp with_thread_listing_server(test_name, list_handler, callback) do
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
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
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
