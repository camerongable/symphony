defmodule SymphonyElixir.FactoryNativeSessionDiscoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Factory.Desktop
  alias SymphonyElixir.Factory.{DesktopRequest, NativeSessionDiscovery, RunLedger, Store, TaskLedger}

  @claimed_at "2026-09-24T07:00:00Z"
  @request_key "desktop:#{String.duplicate("a", 64)}:bootstrap"
  @source_thread_id "019fa5b7-27fa-7660-ab47-7c3abb867c91"

  setup do
    root = Path.join(System.tmp_dir!(), "factory-session-discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "finds only the real task whose creation input contains the exact request marker", %{root: root} do
    wanted = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    unrelated = "01a0d22b-122f-74a0-9057-7aae0255b6d0"

    write_session(root, wanted, @request_key)
    write_session(root, unrelated, "desktop:#{String.duplicate("b", 64)}:bootstrap")

    assert {:ok, %{thread_id: ^wanted, cwd: "/tmp/grail-worktree"} = candidate} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))

    refute Map.has_key?(candidate, :prompt)
    refute Map.has_key?(candidate, :project_id)
  end

  test "an unrelated oversized task with a different creation marker cannot hide the exact task", %{root: root} do
    wanted = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    unrelated = "01a0d22b-122f-74a0-9057-7aae0255b6d0"
    write_session(root, wanted, @request_key)

    path = write_session(root, unrelated, "desktop:#{String.duplicate("b", 64)}:bootstrap")
    File.write!(path, String.duplicate("x", 1_100_000), [:append])

    assert {:ok, %{thread_id: ^wanted}} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "out-of-window filenames are skipped before an unrelated corrupt log can block discovery", %{root: root} do
    wanted = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    unrelated = "01a0d22b-122f-74a0-9057-7aae0255b6d0"
    write_session(root, wanted, @request_key)

    path =
      Path.join([
        root,
        "2026",
        "09",
        "23",
        "rollout-2026-09-23T00-54-00-#{unrelated}.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json\n")

    assert {:ok, %{thread_id: ^wanted}} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "an archived task is discoverable, but an active duplicate remains ambiguous", %{root: root} do
    archive = Path.join(root, "archived_sessions")
    File.mkdir_p!(archive)
    archived_id = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    active_id = "01a0d22b-122f-74a0-9057-7aae0255b6d0"
    archived_path = Path.join(archive, Path.basename(write_session(root, archived_id, @request_key)))
    File.rename!(session_path(root, archived_id), archived_path)

    opts = discovery_opts(root) ++ [archived_sessions_root: archive]
    assert {:ok, %{thread_id: ^archived_id}} = NativeSessionDiscovery.find(@request_key, @claimed_at, opts)

    write_session(root, active_id, @request_key)
    assert {:error, :native_session_ambiguous} = NativeSessionDiscovery.find(@request_key, @claimed_at, opts)
  end

  test "a missing archive is optional, while a non-directory archive fails closed", %{root: root} do
    archive = Path.join(root, "archived_sessions")
    opts = discovery_opts(root) ++ [archived_sessions_root: archive]

    assert {:error, :native_session_not_found} = NativeSessionDiscovery.find(@request_key, @claimed_at, opts)

    File.write!(archive, "not a directory")

    assert {:error, :invalid_native_archived_sessions_root} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, opts)
  end

  test "an archive that becomes unreadable fails closed", %{root: root} do
    archive = Path.join(root, "archived_sessions")
    File.mkdir_p!(archive)
    File.chmod!(archive, 0o000)
    on_exit(fn -> File.chmod(archive, 0o700) end)

    assert {:error, :native_session_directory_unreadable} =
             NativeSessionDiscovery.find(
               @request_key,
               @claimed_at,
               discovery_opts(root) ++ [archived_sessions_root: archive]
             )
  end

  test "invalid inputs and roots fail before a task can be selected", %{root: root} do
    assert {:error, :invalid_native_request_key} = NativeSessionDiscovery.find("bad", "bad")
    assert {:error, :invalid_native_request_key} = NativeSessionDiscovery.find(nil, @claimed_at, discovery_opts(root))

    assert {:error, :native_source_thread_required} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, sessions_root: root)

    assert {:error, :invalid_native_claim_time} =
             NativeSessionDiscovery.find(@request_key, "bad", discovery_opts(root))

    assert {:error, :invalid_native_sessions_root} =
             NativeSessionDiscovery.find(@request_key, @claimed_at,
               sessions_root: nil,
               source_thread_id: @source_thread_id
             )

    assert {:error, :invalid_native_sessions_root} =
             NativeSessionDiscovery.find(@request_key, @claimed_at,
               sessions_root: "relative/sessions",
               source_thread_id: @source_thread_id
             )

    assert {:error, :invalid_native_sessions_root} =
             NativeSessionDiscovery.find(@request_key, @claimed_at,
               sessions_root: Path.join(root, "missing"),
               source_thread_id: @source_thread_id
             )
  end

  test "the ledger-facing lookup refuses an unclaimed CREATE and finds a local-time session candidate", %{root: root} do
    {:ok, store} = Store.start_link(database: Path.join(root, "factory.sqlite"))

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "run-1",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "DRAFTING",
               repo_path: "/tmp/grail"
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "run-1:author",
               run_id: "run-1",
               stage: "DRAFTING",
               role: "specification-author",
               status: "STARTING",
               model_provider: "codex",
               model_class: "standard",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               routing_reason: "role-policy",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _request} =
             DesktopRequest.enqueue(store, %{
               request_key: @request_key,
               target_kind: "TASK",
               target_key: "run-1:author",
               action: "CREATE",
               codex_project_id: "project-grail",
               model: "gpt-6-sol",
               reasoning_effort: "high",
               title: "PPL-123 · Specification Author",
               prompt: "Factory request ID: #{@request_key}\n\nBootstrap",
               cwd: "/tmp/grail",
               schema: %{"type" => "object"},
               metadata: %{"workspace_mode" => "CODEX_NATIVE", "issue_key" => "PPL-123"}
             })

    assert {:error, :native_create_not_uncertain} =
             NativeSessionDiscovery.find_for_request(store, @request_key, discovery_opts(root))

    assert {:ok, _claimed} = DesktopRequest.claim(store, @request_key)
    Store.query!(store, "UPDATE desktop_requests SET claimed_at = ? WHERE request_key = ?", [@claimed_at, @request_key])
    wanted = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    write_session(root, wanted, @request_key, filename_time: "2026-09-24T00-01-00")

    assert {:ok, %{thread_id: ^wanted}} =
             NativeSessionDiscovery.find_for_request(store, @request_key, discovery_opts(root))

    assert {:error, :unknown_request} = NativeSessionDiscovery.find_for_request(store, "missing")

    Store.query!(store, "UPDATE desktop_requests SET claimed_at = NULL, updated_at = ? WHERE request_key = ?", [
      @claimed_at,
      @request_key
    ])

    assert {:ok, %{thread_id: ^wanted}} =
             NativeSessionDiscovery.find_for_request(store, @request_key, discovery_opts(root))

    Store.query!(store, "UPDATE desktop_requests SET status = 'RECONCILE_REQUIRED' WHERE request_key = ?", [
      @request_key
    ])

    assert {:error, :native_claim_timestamp_missing} =
             NativeSessionDiscovery.find_for_request(store, @request_key, discovery_opts(root))

    Store.query!(store, "UPDATE desktop_requests SET claimed_at = ?, status = 'CREATE_UNCERTAIN' WHERE request_key = ?", [
      @claimed_at,
      @request_key
    ])

    workflow = Path.join(root, "WORKFLOW.md")
    write_workflow(workflow, Path.join(root, "factory.sqlite"), true)

    output =
      capture_io(fn ->
        Desktop.run([
          "find-thread",
          @request_key,
          "--source-thread-id",
          @source_thread_id,
          "--sessions-root",
          root,
          "--workflow",
          workflow
        ])
      end)

    assert %{"thread_id" => ^wanted, "proof_level" => "CANDIDATE_ONLY"} = Jason.decode!(output)

    write_workflow(workflow, Path.join(root, "factory.sqlite"), false)

    assert_raise Mix.Error, ~r/native_session_discovery_disabled/, fn ->
      capture_io(fn ->
        Desktop.run([
          "find-thread",
          @request_key,
          "--source-thread-id",
          @source_thread_id,
          "--sessions-root",
          root,
          "--workflow",
          workflow
        ])
      end)
    end
  end

  test "rejects two matching sessions instead of choosing a task", %{root: root} do
    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6df", @request_key)
    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6d0", @request_key)

    assert {:error, :native_session_ambiguous} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "does not accept a marker quoted outside the Codex task creation envelope", %{root: root} do
    id = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    path = write_session(root, id, "other-request")
    File.write!(path, Jason.encode!(%{type: "response_item", payload: %{type: "message", content: @request_key}}) <> "\n", [:append])

    assert {:error, :native_session_not_found} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "does not mistake the broker's own session or another broker's child for this task", %{root: root} do
    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6df", @request_key, thread_source: "user")

    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6d0", @request_key, source_thread_id: "01a0d258-fce9-75c2-9eee-bc0ae0187e61")

    assert {:error, :native_session_not_found} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "rejects wrong envelopes and markers that are not the first input line", %{root: root} do
    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6df", @request_key, namespace: "other")

    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6d0", @request_key, input_prefix: "An unrelated first line\n")

    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6d1", @request_key <> "-near-prefix")

    write_session(root, "01a0d22b-122f-74a0-9057-7aae0255b6d2", @request_key, originator: "Other Agent")

    assert {:error, :native_session_not_found} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "rejects symlinked session files without reading outside the configured root", %{root: root} do
    id = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    external = Path.join(System.tmp_dir!(), "factory-session-external-#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(external) end)
    File.write!(external, "outside\n")
    path = session_path(root, id)
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(external, path)

    assert {:error, :unsafe_native_session_path} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "fails closed when a candidate header exceeds the bounded read", %{root: root} do
    id = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    path = session_path(root, id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("x", 1_100_000))

    assert {:error, :native_session_scan_incomplete} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))
  end

  test "incomplete, unreadable, and out-of-window session files fail safely", %{root: root} do
    date_directory = Path.join([root, "2026", "09", "23"])
    File.mkdir_p!(Path.dirname(date_directory))
    File.write!(date_directory, "not a directory")

    assert {:error, :native_session_directory_unreadable} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))

    File.rm!(date_directory)
    id = "01a0d22b-122f-74a0-9057-7aae0255b6df"
    path = session_path(root, id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json\n")

    assert {:error, :native_session_scan_incomplete} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))

    write_session(root, id, @request_key, timestamp: "2026-09-20T07:01:00Z")

    assert {:error, :native_session_not_found} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))

    write_session(root, id, @request_key, timestamp: "not-a-timestamp")

    assert {:error, :native_session_not_found} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))

    File.chmod!(path, 0o000)

    assert {:error, :native_session_unreadable} =
             NativeSessionDiscovery.find(@request_key, @claimed_at, discovery_opts(root))

    File.chmod!(path, 0o600)
  end

  defp write_session(root, id, request_key, opts \\ []) do
    path = session_path(root, id, opts)
    File.mkdir_p!(Path.dirname(path))
    source_thread_id = Keyword.get(opts, :source_thread_id, @source_thread_id)

    metadata = %{
      type: "session_meta",
      payload: %{
        id: id,
        timestamp: Keyword.get(opts, :timestamp, "2026-09-24T07:01:00Z"),
        cwd: "/tmp/grail-worktree",
        source: "vscode",
        originator: Keyword.get(opts, :originator, "Codex Desktop"),
        thread_source: Keyword.get(opts, :thread_source, "agent_created_thread")
      }
    }

    creation = %{
      type: "response_item",
      payload: %{
        type: "function_call_output",
        name: "create_thread",
        namespace: Keyword.get(opts, :namespace, "codex_app"),
        output:
          "<codex_delegation>\n<source_thread_id>#{source_thread_id}</source_thread_id>\n<input>#{Keyword.get(opts, :input_prefix, "")}Factory request ID: #{request_key}\n\nWork only in the provided checkout.</input>\n</codex_delegation>"
      }
    }

    File.write!(path, Jason.encode!(metadata) <> "\n" <> Jason.encode!(creation) <> "\n")
    path
  end

  defp session_path(root, id, opts \\ []) do
    filename_time = Keyword.get(opts, :filename_time, "2026-09-24T07-01-00")
    Path.join([root, "2026", "09", "24", "rollout-#{filename_time}-#{id}.jsonl"])
  end

  defp discovery_opts(root), do: [sessions_root: root, source_thread_id: @source_thread_id]

  defp write_workflow(path, database, enabled) do
    File.write!(
      path,
      "---\ntracker:\n  kind: memory\nfactory:\n  database: #{database}\n  native_session_discovery_enabled: #{enabled}\n---\n"
    )
  end
end
