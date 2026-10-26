defmodule SymphonyElixir.CiRepairWorkerServer do
  @moduledoc false
  alias SymphonyElixir.DesktopTicketLifecycleFixture.WorkerServer
  alias SymphonyElixir.Factory.{Store, WorkerFileTools}

  def start_session(workspace, opts) do
    with {:ok, session} <- WorkerServer.start_session(workspace, opts) do
      if opts[:ci_evidence_successor_fixture] do
        port =
          Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
            :binary,
            :exit_status,
            :use_stdio,
            args: ["-I", "-S", "-B", "-c", "import select,sys;ready=select.select([sys.stdin.buffer],[],[],60)[0];sys.exit(0 if ready and sys.stdin.buffer.read(1)==b'x' else 124)"]
          ])

        {:os_pid, pid} = Port.info(port, :os_pid)
        {:ok, session |> Map.put(:fixture_owner_port, port) |> put_in([:metadata, :codex_app_server_pid], to_string(pid))}
      else
        {:ok, session}
      end
    end
  end

  def stop_session(%{fixture_owner_port: port} = session) do
    true = Port.command(port, "x")

    receive do
      {^port, {:exit_status, 0}} ->
        {:ok,
         %{
           "transport" => "owned_app_server",
           "thread_id" => session.thread_id,
           "pid" => session.metadata.codex_app_server_pid,
           "invocation_nonce" => session.worker_invocation,
           "exit_status" => 0,
           "cwd" => session.workspace
         }}

      {^port, {:exit_status, status}} ->
        {:error, {:fixture_owner_exit, status}}
    after
      5_000 ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) ->
            if to_string(pid) == session.metadata.codex_app_server_pid do
              System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
            end

          _ ->
            :ok
        end

        receive do
          {^port, {:exit_status, status}} -> {:error, {:fixture_owner_forced_exit, status}}
        after
          2_000 ->
            if Port.info(port), do: Port.close(port)
            {:error, :fixture_owner_stop_unproven}
        end
    end
  end

  def stop_session(session), do: WorkerServer.stop_session(session)

  def run_turn(session, prompt, issue, opts) do
    packet = Jason.decode!(prompt)

    cond do
      packet["role"] == "feature-writer" ->
        source_turn(session, packet, opts)

      packet["role"] == "change-verifier" and Application.get_env(:symphony_elixir, :verifier_repair_fixture) == true ->
        verifier_turn(session, packet, opts)

      true ->
        WorkerServer.run_turn(session, prompt, issue, opts)
    end
  end

  defp verifier_verdict(false), do: "PASS"

  defp verifier_verdict(true) do
    if Application.get_env(:symphony_elixir, :operator_verifier_repair_fixture), do: "BLOCK", else: "REPAIR"
  end

  defp verifier_turn(session, packet, opts) do
    turn = "verifier-turn-#{System.unique_integer([:positive])}"
    opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
    repairing = packet["code_repair_round"] <= Application.get_env(:symphony_elixir, :verifier_repair_max_round, 0)

    output = %{
      "status" => verifier_verdict(repairing),
      "candidate_sha" => packet["candidate_sha"],
      "findings" => if(repairing, do: ["Preserve the configuration error prefix", "Redact configuration values", "Preserve the configuration error prefix"], else: []),
      "checks" => ["synthetic exact-candidate review"]
    }

    opts[:on_message].(%{
      payload: %{
        "method" => "item/completed",
        "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
      }
    })

    {:ok, %{turn_id: turn}}
  end

  defp source_turn(session, packet, opts) do
    cond do
      Application.get_env(:symphony_elixir, :ci_generated_only) == true -> generated_only_turn(session, packet, opts)
      ordinary_go_packet?(packet) -> ordinary_go_turn(session, packet, opts)
      true -> normal_source_turn(session, packet, opts)
    end
  end

  defp generated_only_turn(session, %{"ci_repair" => repair} = packet, opts) when is_map(repair) do
    if not is_map(packet["controller_generation_scope"]), do: raise("generated-only capability missing from admitted packet")
    SymphonyElixir.CiRepairEmptyWorkerServer.run_turn(session, Jason.encode!(packet), %{}, opts)
  end

  defp generated_only_turn(session, %{"stage" => "WRITING"}, opts) do
    turn = "generated-imports-#{System.unique_integer([:positive])}"
    :ok = WorkerFileTools.turn_preflight(session.files, session)
    opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
    identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => "read", "namespace" => nil, "tool" => "repo_read"}

    files = %{
      "go/src/grail.com/doc-extract/server/service/extract/accepted_execution_test.go" => "package extract\n\nimport (\n _ \"go.uber.org/zap\"\n _ \"go.uber.org/zap/zaptest/observer\"\n)\n",
      "go/src/grail.com/doc-extract/worker/cmd/main_test.go" =>
        "package main\n\nimport (\n _ \"go.uber.org/cadence/activity\"\n _ \"go.uber.org/cadence/testsuite\"\n _ \"go.uber.org/cadence/workflow\"\n)\n"
    }

    for {path, content} <- files do
      prior = fixture_read(session, path, %{identity | "callId" => "read-" <> path})
      fixture_write(session, path, prior["sha256"], content, %{identity | "callId" => "write-" <> path})
    end

    build = "go/src/grail.com/doc-extract/server/service/extract/BUILD"
    prior = fixture_read(session, build, %{identity | "callId" => "read-build"})
    fixture_write(session, build, prior["sha256"], prior["text"] <> "# source candidate retains stale generated deps\n", %{identity | "callId" => "write-build"})

    output = %{
      "status" => "COMPLETE",
      "changed_paths" => Enum.sort([build | Map.keys(files)]),
      "commit_message" => "fix(PPL-123): add synthetic import coverage",
      "blockers" => [],
      "checks" => ["NOT_RUN: synthetic import fixture awaits CI"]
    }

    opts[:on_message].(%{
      payload: %{
        "method" => "item/completed",
        "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
      }
    })

    {:ok, %{turn_id: turn}}
  end

  defp generated_only_turn(session, packet, opts), do: normal_source_turn(session, packet, opts)

  @spec ordinary_go_packet?(map()) :: boolean()
  def ordinary_go_packet?(packet) do
    Application.get_env(:symphony_elixir, :ordinary_go_generation) == true and
      is_map(packet["repair_review"]) and not is_map(packet["ci_repair"])
  end

  defp ordinary_go_turn(session, packet, opts) do
    turn = "ordinary-go-turn-#{System.unique_integer([:positive])}"
    :ok = WorkerFileTools.turn_preflight(session.files, session)
    opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
    identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => turn <> ":read-old", "namespace" => nil, "tool" => "repo_read"}
    old = fixture_read(session, "pkg/old.go", identity)
    moved_path = Application.get_env(:symphony_elixir, :ordinary_go_path, "moved/job.go")
    moved = fixture_read(session, moved_path, %{identity | "callId" => turn <> ":read-moved"})
    reviewed = packet["repair_review"]["prior_candidate_sha"]
    marker = "// review #{reviewed}"

    paths =
      cond do
        moved && String.contains?(moved["text"], marker) ->
          []

        old && String.contains?(old["text"], marker) ->
          deleted =
            WorkerFileTools.execute(session.files, "repo_delete", %{"path" => "pkg/old.go", "expected_sha256" => old["sha256"]}, %{identity | "tool" => "repo_delete", "callId" => turn <> ":delete"})

          true = deleted["success"]
          content = "package moved\nimport \"example.invalid/fixture/dep\"\nfunc Value() int{return dep.Value}\n#{marker}\n"
          fixture_write(session, moved_path, "ABSENT", content, %{identity | "callId" => turn <> ":write-moved"})
          [moved_path, "pkg/old.go"]

        true ->
          content = "package pkg\nimport \"fmt\"\nfunc Value() string{return fmt.Sprint(1)}\n#{marker}\n"
          fixture_write(session, "pkg/old.go", old["sha256"], content, %{identity | "callId" => turn <> ":write-old"})
          ["pkg/old.go"]
      end

    output = %{
      "status" => if(paths == [], do: "COMPLETE", else: "CONTINUE"),
      "changed_paths" => paths,
      "commit_message" => "fix(PPL-123): generate ordinary Go repair dependencies",
      "blockers" => [],
      "checks" => ["synthetic Go move; controller owns generation"]
    }

    opts[:on_message].(%{
      payload: %{
        "method" => "item/completed",
        "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
      }
    })

    {:ok, %{turn_id: turn}}
  end

  defp fixture_read(session, path, identity) do
    result = WorkerFileTools.execute(session.files, "repo_read", %{"path" => path, "start_line" => 1}, identity)
    if result["success"], do: result["contentItems"] |> hd() |> Map.fetch!("text") |> Jason.decode!()
  end

  defp fixture_write(session, path, expected, content, identity) do
    result = WorkerFileTools.execute(session.files, "repo_write", %{"path" => path, "expected_sha256" => expected, "content" => content}, %{identity | "tool" => "repo_write"})
    true = result["success"]
  end

  defp normal_source_turn(session, packet, opts) do
    path = Keyword.get(opts, :ci_source_path, "job.go")
    turn = "ci-turn-#{System.unique_integer([:positive])}"
    :ok = WorkerFileTools.turn_preflight(session.files, session)
    opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
    identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => turn <> ":read", "namespace" => nil, "tool" => "repo_read"}
    read = WorkerFileTools.execute(session.files, "repo_read", %{"path" => path, "start_line" => 1}, identity)
    expected = if read["success"], do: read["contentItems"] |> hd() |> Map.fetch!("text") |> Jason.decode!() |> Map.fetch!("sha256"), else: "ABSENT"
    repair = packet["ci_repair"]

    legacy =
      Application.get_env(:symphony_elixir, :verifier_legacy_packet) == true and
        packet["stage"] == "REPAIRING" and not is_map(repair)

    ordinary =
      Application.get_env(:symphony_elixir, :verifier_repair_fixture) == true and
        (is_map(packet["repair_review"]) or legacy)

    current = if read["success"], do: read["contentItems"] |> hd() |> Map.fetch!("text") |> Jason.decode!() |> Map.get("text", ""), else: ""
    reviewed = get_in(packet, ["repair_review", "prior_candidate_sha"]) || packet["candidate_sha"]

    slice =
      case Regex.run(~r/# review ([a-f0-9]+) slice (\d+)/, current) do
        [_, ^reviewed, value] -> String.to_integer(value) + 1
        _ -> 1
      end

    continued = if ordinary, do: not legacy and slice < 3, else: is_map(repair) and packet["candidate_sha"] == repair["failed_candidate_sha"]

    content = if ordinary, do: "value = #{slice}\n# review #{reviewed} slice #{slice}\n", else: source_content(path, repair, continued)

    write =
      WorkerFileTools.execute(session.files, "repo_write", %{"path" => path, "expected_sha256" => expected, "content" => content}, %{
        identity
        | "tool" => "repo_write",
          "callId" => turn <> ":write"
      })

    true = write["success"]

    paths =
      if Application.get_env(:symphony_elixir, :ordinary_go_generation) == true and packet["stage"] == "WRITING" do
        build = fixture_read(session, "BUILD", %{identity | "callId" => turn <> ":read-build"})

        content =
          "# gazelle:prefix example.invalid/fixture\nload(\"@io_bazel_rules_go//go:def.bzl\", \"go_library\")\n\ngo_library(\n    name = \"fixture\",\n    srcs = [\"job.go\"],\n    importpath = \"example.invalid/fixture\",\n    visibility = [\"//visibility:public\"],\n)\n"

        fixture_write(session, "BUILD", build["sha256"], content, %{identity | "callId" => turn <> ":write-build"})
        ["BUILD", path]
      else
        [path]
      end

    output = %{
      "status" => if(continued, do: "CONTINUE", else: "COMPLETE"),
      "changed_paths" => paths,
      "commit_message" => "fix(PPL-123): bounded CI source slice",
      "blockers" => [],
      "checks" => ["NOT_RUN: compile and tests remain CI-owned"]
    }

    opts[:on_message].(%{
      payload: %{
        "method" => "item/completed",
        "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
      }
    })

    {:ok, %{turn_id: turn}}
  end

  defp source_content("job.py", repair, continued), do: "value = #{if is_map(repair), do: if(continued, do: 1, else: 2), else: 3}\n"

  defp source_content(_path, repair, continued) do
    cond do
      is_map(repair) and Application.get_env(:symphony_elixir, :ordinary_go_generation) == true ->
        "package job\nimport \"example.invalid/fixture/dep\"\nvar fixed=dep.Value+#{if continued, do: 1, else: 2}\n"

      is_map(repair) ->
        "package job\nvar fixed = #{if continued, do: 1, else: 2}\n"

      true ->
        "package job\nvar _ = json.RawMessage{}\n"
    end
  end

  def read_native_thread(thread, _opts) do
    store = Process.get(:ci_repair_fixture_store)
    task = Store.one!(store, "SELECT * FROM factory_tasks WHERE thread_id = ? AND role = 'feature-writer'", [thread])
    request = %{"existing_thread_id" => thread, "cwd" => task["workspace"], "codex_project_id" => task["codex_project_id"], "metadata_json" => Jason.encode!(%{"previous_turn_id" => task["turn_id"]})}
    native = SymphonyElixir.DesktopTicketLifecycleFixture.mr_guard(request)["native"] |> Map.put("status", %{"type" => "idle"})
    if hook = Process.get(:ci_repair_source_observed), do: hook.()
    {:ok, native}
  end
end

defmodule SymphonyElixir.CiRepairBlockedWorkerServer do
  @moduledoc false
  alias SymphonyElixir.CiRepairWorkerServer
  alias SymphonyElixir.Factory.WorkerFileTools
  def start_session(workspace, opts), do: CiRepairWorkerServer.start_session(workspace, Keyword.put(opts, :ci_evidence_successor_fixture, true))
  def stop_session(session), do: CiRepairWorkerServer.stop_session(session)
  def read_native_thread(thread, opts), do: CiRepairWorkerServer.read_native_thread(thread, opts)

  def run_turn(session, prompt, issue, opts) do
    if is_map(Jason.decode!(prompt)["ci_repair"]) do
      turn = "ci-blocked-#{System.unique_integer([:positive])}"
      :ok = WorkerFileTools.turn_preflight(session.files, session)
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
      output = %{"status" => "BLOCKED", "changed_paths" => [], "commit_message" => nil, "blockers" => ["Assertion logs unavailable"], "checks" => []}

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
        }
      })

      {:ok, %{turn_id: turn}}
    else
      CiRepairWorkerServer.run_turn(session, prompt, issue, opts)
    end
  end
end

defmodule SymphonyElixir.CiRepairOwnedGoWorkerServer do
  @moduledoc false
  alias SymphonyElixir.CiRepairWorkerServer
  def start_session(workspace, opts), do: CiRepairWorkerServer.start_session(workspace, Keyword.put(opts, :ci_evidence_successor_fixture, true))
  def stop_session(session), do: CiRepairWorkerServer.stop_session(session)
  def read_native_thread(thread, opts), do: CiRepairWorkerServer.read_native_thread(thread, opts)
  def run_turn(session, prompt, issue, opts), do: CiRepairWorkerServer.run_turn(session, prompt, issue, opts)
end

defmodule SymphonyElixir.CiRepairOwnedPythonWorkerServer do
  @moduledoc false
  alias SymphonyElixir.{CiRepairPythonWorkerServer, CiRepairWorkerServer}
  def start_session(workspace, opts), do: CiRepairWorkerServer.start_session(workspace, Keyword.put(opts, :ci_evidence_successor_fixture, true))
  def stop_session(session), do: CiRepairWorkerServer.stop_session(session)
  def read_native_thread(thread, opts), do: CiRepairWorkerServer.read_native_thread(thread, opts)
  def run_turn(session, prompt, issue, opts), do: CiRepairPythonWorkerServer.run_turn(session, prompt, issue, opts)
end

defmodule SymphonyElixir.CiRepairHeldOwnedPythonWorkerServer do
  @moduledoc false
  alias SymphonyElixir.CiRepairOwnedPythonWorkerServer

  def start_session(workspace, opts) do
    send(Process.whereis(:ci_handoff_start_owner), {:ci_handoff_start_sent, opts[:resume_thread_id], self()})

    receive do
      :continue_ci_handoff -> CiRepairOwnedPythonWorkerServer.start_session(workspace, opts)
    after
      60_000 -> {:error, :ci_handoff_fixture_wait_expired}
    end
  end

  def read_native_thread(thread, opts), do: CiRepairOwnedPythonWorkerServer.read_native_thread(thread, opts)
  def run_turn(session, prompt, issue, opts), do: CiRepairOwnedPythonWorkerServer.run_turn(session, prompt, issue, opts)
  def stop_session(session), do: CiRepairOwnedPythonWorkerServer.stop_session(session)
end

defmodule SymphonyElixir.CiRepairPythonWorkerServer do
  @moduledoc false
  alias SymphonyElixir.CiRepairWorkerServer
  def start_session(workspace, opts), do: CiRepairWorkerServer.start_session(workspace, opts)
  def stop_session(session), do: CiRepairWorkerServer.stop_session(session)
  def read_native_thread(thread, opts), do: CiRepairWorkerServer.read_native_thread(thread, opts)
  def run_turn(session, prompt, issue, opts), do: CiRepairWorkerServer.run_turn(session, prompt, issue, Keyword.put(opts, :ci_source_path, "job.py"))
end

defmodule SymphonyElixir.CiRepairEmptyWorkerServer do
  @moduledoc false
  alias SymphonyElixir.CiRepairWorkerServer
  alias SymphonyElixir.Factory.WorkerFileTools

  def start_session(workspace, opts), do: CiRepairWorkerServer.start_session(workspace, opts)
  def stop_session(session), do: CiRepairWorkerServer.stop_session(session)
  def read_native_thread(thread, opts), do: CiRepairWorkerServer.read_native_thread(thread, opts)

  def run_turn(session, prompt, issue, opts) do
    packet = Jason.decode!(prompt)

    if packet["role"] == "feature-writer" and is_map(packet["ci_repair"]) do
      turn = "ci-empty-#{System.unique_integer([:positive])}"
      :ok = WorkerFileTools.turn_preflight(session.files, session)
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
      output = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => ["NOT_RUN: controller generation is separate"]}

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{"threadId" => session.thread_id, "turnId" => turn, "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}}
        }
      })

      {:ok, %{turn_id: turn}}
    else
      CiRepairWorkerServer.run_turn(session, prompt, issue, opts)
    end
  end
end
