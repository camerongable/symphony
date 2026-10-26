defmodule SymphonyElixir.CapabilityRecoveryFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias SymphonyElixir.CiRepairOwnedGoWorkerServer
  alias SymphonyElixir.Factory.{Store, WorkerFileTools, Worktree}

  def start_session(workspace, opts) do
    with {:ok, session} <- CiRepairOwnedGoWorkerServer.start_session(workspace, opts) do
      {:ok, Map.put(session, :capability_preflight, opts[:recovery_preflight])}
    end
  end

  def stop_session(session), do: CiRepairOwnedGoWorkerServer.stop_session(session)

  def run_turn(session, prompt, issue, opts) do
    packet = Jason.decode!(prompt)

    cond do
      is_binary(packet["controller_infrastructure_recovery"]) ->
        assert String.starts_with?(packet["controller_infrastructure_recovery"], "TCAP-")
        assert packet["recovery_instruction"] =~ ".symphony-base/"
        assert is_function(session.capability_preflight, 1)
        Process.put(:capability_delay_final_ledger, true)
        assert {:error, :capability_recovery_owned_preflight_failed} = session.capability_preflight.(session)
        assert :ok = Task.await(Process.delete(:capability_final_ledger_task), 1000)
        attempt = Store.one!(session.files.store, "SELECT * FROM worker_evidence WHERE request_key=?", [session.files.key])
        assert attempt["status"] == "THREAD_BOUND" and is_nil(attempt["turn_id"])
        assert :ok = session.capability_preflight.(session)
        on_message = opts[:on_message]

        wrapped =
          Keyword.put(opts, :on_message, fn message ->
            capability_message(session, on_message, message)
          end)

        CiRepairOwnedGoWorkerServer.run_turn(session, Jason.encode!(packet["base_packet"]), issue, wrapped)

      packet["role"] == "feature-writer" and packet["stage"] == "REPAIRING" and
          Application.get_env(:symphony_elixir, :capability_fixture_block_once) == true ->
        Application.delete_env(:symphony_elixir, :capability_fixture_block_once)
        blocked_turn(session, opts)

      true ->
        CiRepairOwnedGoWorkerServer.run_turn(session, prompt, issue, opts)
    end
  end

  defp capability_message(session, on_message, %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => raw}}}} = message) do
    output = Jason.decode!(raw)
    {:ok, changed} = Worktree.pending_source_paths(session.workspace)
    on_message.(put_in(message, [:payload, "params", "item", "text"], Jason.encode!(Map.put(output, "changed_paths", changed))))
  end

  defp capability_message(_session, on_message, message), do: on_message.(message)

  defp blocked_turn(session, opts) do
    turn = "capability-blocked-#{System.unique_integer([:positive])}"
    assert :ok = WorkerFileTools.turn_preflight(session.files, session)
    opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})

    for {index, path} <- Enum.with_index(["dep/dep.go", "dep/dep.go", "pkg/old.go", "dep/BUILD"], 1) |> Enum.map(fn {path, index} -> {index, path} end) do
      identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => "read-#{index}", "tool" => "repo_read"}
      assert %{"success" => true, "contentItems" => [%{"text" => raw}]} = WorkerFileTools.execute(session.files, "repo_read", %{"path" => path, "start_line" => 1}, identity)
      before = Jason.decode!(raw)
      suffix = if path == "dep/BUILD", do: "# preserved capability slice\n", else: "// preserved capability slice #{index}\n"

      assert %{"success" => true} =
               WorkerFileTools.execute(session.files, "repo_write", %{"path" => path, "expected_sha256" => before["sha256"], "content" => before["text"] <> suffix}, %{
                 identity
                 | "tool" => "repo_write",
                   "callId" => "write-#{index}"
               })
    end

    output = %{
      "status" => "BLOCKED",
      "changed_paths" => ["dep/BUILD", "dep/dep.go", "pkg/old.go"],
      "commit_message" => nil,
      "blockers" => ["Exact contract-base contents are unavailable through the permitted repository tools."],
      "checks" => []
    }

    opts[:on_message].(%{
      payload: %{
        "method" => "item/completed",
        "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
      }
    })

    {:ok, %{turn_id: turn}}
  end

  def read_owned_native_thread(session) do
    assert {:os_pid, pid} = Port.info(session.fixture_owner_port, :os_pid)
    assert to_string(pid) == session.metadata.codex_app_server_pid
    {:ok, native} = read_native_thread(session.thread_id, store: session.files.store)

    if Process.delete(:capability_delay_final_ledger) do
      delayed_ledger_native(session, native)
    else
      {:ok, native}
    end
  end

  defp delayed_ledger_native(session, native) do
    time = DateTime.utc_now() |> DateTime.add(-9) |> DateTime.to_iso8601()
    native = put_in(native, ["latest_turn_observation", "observed_at"], time)
    native = put_in(native, ["latest_turn_observation", "confirmation", "observed_at"], time)
    native = put_in(native, ["queue_observation", "observed_at"], time)
    parent = self()

    task =
      Task.async(fn ->
        Store.transaction!(session.files.store, fn _ ->
          send(parent, :capability_final_ledger_held)
          Process.sleep(2000)
          :ok
        end)
      end)

    assert_receive :capability_final_ledger_held, 1000
    Process.put(:capability_final_ledger_task, task)
    {:ok, native}
  end

  def read_native_thread(thread, opts) do
    if Keyword.has_key?(opts, :workspace) do
      assert is_binary(opts[:workspace])
      if expected = Process.get(:capability_expected_observer_workspace), do: assert(opts[:workspace] == expected)
    end

    store = opts[:store] || Process.get(:ci_repair_fixture_store)
    old = Store.one!(store, "SELECT * FROM worker_evidence WHERE thread_id=? AND status='RESULT_RECORDED' AND json_extract(output_json,'$.status')='BLOCKED' ORDER BY rowid DESC LIMIT 1", [thread])
    task = Store.one!(store, "SELECT turn_id FROM factory_tasks WHERE thread_id=? AND role='feature-writer'", [thread])

    if is_map(old) and task["turn_id"] == old["turn_id"] do
      capability_native(thread, old)
    else
      CiRepairOwnedGoWorkerServer.read_native_thread(thread, opts)
    end
  end

  defp capability_native(thread, old) do
    binding = Jason.decode!(old["binding_json"])

    raw = %{
      "data" => [%{"id" => old["turn_id"], "status" => "completed", "error" => nil, "items" => [%{"id" => old["item_id"], "type" => "agentMessage", "text" => old["output_json"]}]}],
      "nextCursor" => nil
    }

    time = DateTime.utc_now() |> DateTime.to_iso8601()

    observation = %{
      "mode" => "LATEST_DESC",
      "updated_at" => 1,
      "parameters" => %{"threadId" => thread, "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
      "raw_response" => raw,
      "sha256" => hash(raw),
      "observed_at" => time,
      "confirmation" => %{"raw_response" => raw, "sha256" => hash(raw), "observed_at" => time}
    }

    queue = %{"data" => [], "nextCursor" => nil}

    {:ok,
     %{
       "id" => thread,
       "cwd" => binding["policy"]["cwd"],
       "status" => %{"type" => "idle"},
       "updatedAt" => 1,
       "latest_turn_observation" => observation,
       "queue_observation" => %{"thread_id" => thread, "raw_response" => queue, "sha256" => hash(queue), "observed_at" => time, "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false}
     }}
  end

  def options(ctx, options) do
    queue = Path.join(ctx.root, "capability-queue.sqlite")

    sql =
      """
      CREATE TABLE queued_items (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL, queue_order INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
      CREATE TABLE queued_thread_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL UNIQUE);
      """ <>
        Enum.map_join([{"insert", "NEW"}, {"update", "NEW"}, {"delete", "OLD"}], fn {event, row} ->
          "CREATE TRIGGER queued_items_revision_after_#{event} AFTER #{String.upcase(event)} ON queued_items BEGIN INSERT INTO queued_thread_revisions (thread_id) VALUES (#{row}.thread_id) ON CONFLICT(thread_id) DO UPDATE SET revision = (SELECT COALESCE(MAX(revision),0)+1 FROM queued_thread_revisions); END;"
        end)

    assert {_, 0} = System.cmd("/usr/bin/sqlite3", [queue, sql])
    home = Path.join(ctx.root, "capability-native")
    File.mkdir_p!(Path.join(home, "thread-writer-locks"))
    Keyword.merge(options, native_reader: __MODULE__, native_home: home, native_queue_database: queue, app_server: __MODULE__)
  end

  defp hash(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
