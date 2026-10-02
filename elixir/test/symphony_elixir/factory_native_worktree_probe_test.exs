defmodule SymphonyElixir.FactoryNativeWorktreeProbeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  alias Mix.Tasks.Factory.Desktop

  alias SymphonyElixir.Factory.{DesktopRequest, NativeWorktreeProbe, RunLedger, StageSchemas, Store, TaskLedger}
  alias SymphonyElixir.Factory.NativeMaintenanceEvidence

  setup do
    root = Path.join(System.tmp_dir!(), "native-probe-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    path = Path.join(root, "writer")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "master"])
    git!(repo, ["config", "user.email", "factory@example.test"])
    git!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "--no-verify", "-m", "base"])
    git!(repo, ["worktree", "add", "-b", "cgable/PPL-123", path])
    sha = String.trim(git!(path, ["rev-parse", "HEAD"]))
    {:ok, path} = SymphonyElixir.PathSafety.canonicalize(path)
    {:ok, repo} = SymphonyElixir.PathSafety.canonicalize(repo)
    database = Path.join(root, "factory.sqlite")
    {:ok, store} = Store.start_link(database: database)

    {:ok, _} =
      RunLedger.register(store, %{
        run_id: "run",
        issue_key: "PPL-123",
        kind: "DELIVERY",
        state: "READY_FOR_REVIEW",
        factory_owned: false,
        workspace_state: "CODEX_NATIVE",
        worktree: path,
        candidate_sha: sha,
        branch: "cgable/PPL-123",
        base_branch: "master",
        repo_path: repo
      })

    {:ok, _} =
      TaskLedger.register(store, %{
        task_key: "run:feature-writer",
        run_id: "run",
        stage: "WRITING",
        role: "feature-writer",
        status: "CONSUMED",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "test",
        prompt_sha256: String.duplicate("b", 64),
        codex_project_id: "project",
        thread_id: "writer-thread",
        workspace: path,
        workspace_sha: sha
      })

    {:ok, writer} =
      TaskLedger.update(store, "run:feature-writer", %{
        turn_id: "writer-turn",
        output_json: Jason.encode!(%{"status" => "COMPLETE"}),
        failure_code: "preserve-this"
      })

    on_exit(fn -> File.rm_rf(root) end)
    %{store: store, database: database, writer: writer, path: path, repo: repo, sha: sha}
  end

  test "probe records an informational receipt without changing any writer field and survives restart", c do
    request = legacy_request(c)
    assert request["action"] == "FOLLOWUP"
    assert request["existing_thread_id"] == c.writer["thread_id"]
    assert request["cwd"] == c.path
    record(c, request)
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    observed = artifacts(c)
    assert {:ok, result} = NativeWorktreeProbe.receipt(request, observed)
    assert result["status"] == "SUPPORTED"
    assert {:ok, completed} = DesktopRequest.complete(c.store, request["request_key"], completion(request, observed))
    assert completed["status"] == "SUCCEEDED"
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    GenServer.stop(c.store)
    {:ok, store} = Store.start_link(database: c.database)
    assert {:ok, ^completed} = DesktopRequest.get(store, request["request_key"])
    assert TaskLedger.get(store, c.writer["task_key"]) == {:ok, c.writer}
    assert :ok = DesktopRequest.reconcile_native_successes(store)
    assert TaskLedger.get(store, c.writer["task_key"]) == {:ok, c.writer}
  end

  test "empty and duplicate active attachments cannot report supported capability", c do
    for {observed, expected} <- [{%{"artifacts" => []}, "UNAVAILABLE"}, {Map.update!(artifacts(c), "artifacts", &(&1 ++ &1)), "AMBIGUOUS"}] do
      request = legacy_request(c)
      record(c, request)
      assert {:ok, receipt} = NativeWorktreeProbe.receipt(request, observed)
      assert receipt["status"] == expected
      assert receipt["artifact_identity_key"] == nil
      assert {:ok, _} = DesktopRequest.complete(c.store, request["request_key"], completion(request, observed))
      assert {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{turn_id: "next-writer-turn"})
    end
  end

  test "final prose and mismatched broker observations cannot spoof attachment proof", c do
    request = legacy_request(c)
    record(c, request)
    good = completion(request, artifacts(c))
    no_tool_call = put_in(good, ["output", "completed_tool_calls"], [])

    assert {:error, :artifact_tool_observation_missing} =
             DesktopRequest.complete(c.store, request["request_key"], no_tool_call)

    missing = Map.delete(good, "artifact_output")
    assert {:error, :artifact_tool_observation_missing} = DesktopRequest.complete(c.store, request["request_key"], missing)
    wrong = put_in(good, ["artifact_output", "artifacts", Access.at(0), "payload", "sourceCwd"], "/wrong/repo")
    assert {:error, :artifact_tool_observation_missing} = DesktopRequest.complete(c.store, request["request_key"], wrong)
    wrong_observed = wrong["artifact_output"]
    forged = put_in(completion(request, wrong_observed), ["output", "result"], good["output"]["result"])
    assert {:error, :maintenance_receipt_mismatch} = DesktopRequest.complete(c.store, request["request_key"], forged)
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
  end

  test "changed writer binding and checkout proof fail closed", c do
    request = legacy_request(c)
    key = request["request_key"]
    assert {:ok, _} = DesktopRequest.claim(c.store, request["request_key"])

    assert {:error, :thread_route_mismatch} =
             DesktopRequest.record_thread(c.store, request["request_key"], "different", "project", %{cwd: c.path, head_sha: c.sha})

    assert {:error, :maintenance_checkout_proof_missing} =
             DesktopRequest.record_thread(c.store, request["request_key"], "writer-thread", "project", %{cwd: "/wrong", head_sha: c.sha})

    assert {:ok, _} = DesktopRequest.record_thread(c.store, key, "writer-thread", "project", %{cwd: c.path, head_sha: c.sha})
    assert {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{turn_id: "new-writer-turn"})
    attrs = completion(request, artifacts(c))
    assert {:error, :maintenance_binding_changed} = DesktopRequest.complete(c.store, key, attrs)
  end

  test "malformed completed tool calls reject atomically without changing the request or writer", c do
    request = legacy_request(c)
    record(c, request)
    assert {:ok, recorded} = DesktopRequest.get(c.store, request["request_key"])
    good = completion(request, artifacts(c))

    for value <- [1, "spoof", nil] do
      bad = update_in(good, ["output", "completed_tool_calls"], &[value | &1])
      assert {:error, :artifact_tool_observation_missing} = DesktopRequest.complete(c.store, request["request_key"], bad)
      assert {:ok, ^recorded} = DesktopRequest.get(c.store, request["request_key"])
      assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    end
  end

  test "maintenance API rejects missing operation malformed metadata and invalid observations", c do
    ordinary = %{"metadata_json" => "{}", "schema_json" => "{}"}
    assert :ok = NativeWorktreeProbe.validate_request(c.store, ordinary)
    assert :ok = NativeWorktreeProbe.validate_completion(c.store, ordinary, %{})
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    assert {:error, :invalid_maintenance_metadata} = NativeWorktreeProbe.operation(%{"metadata_json" => "{"})
    assert {:error, :invalid_maintenance_metadata} = NativeWorktreeProbe.operation(%{"metadata_json" => "[]"})
    assert {:error, :unsupported_maintenance_operation} = NativeWorktreeProbe.operation(%{"metadata_json" => ~s({"maintenance_operation":null})})

    assert {:error, :maintenance_operation_missing} =
             DesktopRequest.enqueue(c.store, put_in(request_attrs(request), ["metadata"], %{}))

    assert {:error, :unsupported_maintenance_operation} = NativeWorktreeProbe.record(c.store, %{request | "metadata_json" => "{}"}, "writer-thread", nil)
    assert {:error, :maintenance_checkout_proof_missing} = NativeWorktreeProbe.record(c.store, request, "writer-thread", nil)
    assert {:error, :maintenance_thread_mismatch} = NativeWorktreeProbe.record(c.store, request, "other-thread", nil)

    for observed <- [%{}, %{"artifacts" => [1]}, %{"artifacts" => [], "other" => true}] do
      assert {:error, :invalid_artifact_observation} = NativeWorktreeProbe.receipt(request, observed)
    end

    assert {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{status: "RETRY_PENDING"})
    assert {:error, :maintenance_writer_not_eligible} = NativeWorktreeProbe.enqueue(c.store, "run")
  end

  test "unknown maintenance operations and schemas cannot enter the broker queue", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    attrs = request_attrs(request)

    assert {:error, :unsupported_maintenance_operation} =
             DesktopRequest.enqueue(c.store, put_in(attrs, ["metadata", "maintenance_operation"], "ARCHIVE_WORKTREE"))

    assert {:error, :unsupported_maintenance_schema} =
             DesktopRequest.enqueue(c.store, Map.put(attrs, "schema", StageSchemas.for_stage(:change_verifier)))
  end

  test "maintenance successes are excluded from implementation backfill even if writer later becomes retryable", c do
    request = legacy_request(c)
    record(c, request)
    assert {:ok, _} = DesktopRequest.complete(c.store, request["request_key"], completion(request, artifacts(c)))
    assert {:ok, writer} = TaskLedger.update(c.store, c.writer["task_key"], %{status: "RETRY_PENDING", output_json: nil})
    assert :ok = DesktopRequest.reconcile_native_successes(c.store)
    assert {:ok, ^writer} = TaskLedger.get(c.store, c.writer["task_key"])
  end

  test "broker records immutable target stdout evidence and completes it after SQLite restart without writer mutation", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    payload = emitted_evidence(request, artifacts(c))
    assert {:error, :maintenance_request_not_bound} = NativeMaintenanceEvidence.record(c.store, request["request_key"], payload)
    record(c, request)
    assert {:ok, event} = NativeMaintenanceEvidence.record(c.store, request["request_key"], payload)
    assert event["receipt"]["status"] == "SUPPORTED"
    assert {:ok, ^event} = NativeMaintenanceEvidence.record(c.store, request["request_key"], payload)
    assert Jason.decode!(event["payload_json"])["provenance"] == "TARGET_ATTESTED_NATIVE_CHAT"
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    changed = put_in(payload, ["command_proof", "command_item", "id"], "exec-deadbeef")
    assert {:error, :maintenance_evidence_conflict} = NativeMaintenanceEvidence.record(c.store, request["request_key"], changed)
    GenServer.stop(c.store)
    {:ok, store} = Store.start_link(database: c.database)
    assert {:ok, ^event} = NativeMaintenanceEvidence.record(store, request["request_key"], payload)
    attrs = stored_completion(request, artifacts(c), payload)
    assert {:ok, completed} = DesktopRequest.complete(store, request["request_key"], attrs)
    result = Jason.decode!(completed["output_json"])
    assert result["maintenance_evidence"]["transport_provenance"] == "BROKER_OBSERVED_COMMAND_STDOUT"
    assert hd(result["completed_tool_calls"])["output_provenance"] == "TARGET_ATTESTED_NATIVE_CHAT"
    assert result["result"]["status"] == "SUPPORTED"
    assert TaskLedger.get(store, c.writer["task_key"]) == {:ok, c.writer}
    assert :ok = DesktopRequest.reconcile_native_successes(store)
    assert TaskLedger.get(store, c.writer["task_key"]) == {:ok, c.writer}
  end

  test "record-maintenance-evidence CLI accepts only exact bound evidence and does not claim or complete", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    record(c, request)
    workflow = Path.join(Path.dirname(c.database), "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{c.database}\n---\n")
    payload = emitted_evidence(request, artifacts(c)) |> Jason.encode!() |> Base.encode64()

    event =
      capture_io(fn ->
        Desktop.run(["record-maintenance-evidence", request["request_key"], "--payload-base64", payload, "--workflow", workflow])
      end)
      |> Jason.decode!()

    assert event["event_type"] == "NATIVE_MAINTENANCE_TARGET_EVIDENCE"
    assert {:ok, %{"status" => "THREAD_RECORDED", "turn_id" => nil}} = DesktopRequest.get(c.store, request["request_key"])
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}

    for invalid <- ["not-base64", Base.encode64("[]"), Base.encode64("{")] do
      assert_raise Mix.Error, fn ->
        Desktop.run(["record-maintenance-evidence", request["request_key"], "--payload-base64", invalid, "--workflow", workflow])
      end
    end
  end

  test "wrong evidence binding command frame and shell commands never create events or change the writer", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    record(c, request)
    good = emitted_evidence(request, artifacts(c))
    other_command = emitted_evidence(request, %{"artifacts" => []})["command_proof"]["command_item"]["command"]

    bad = [
      %{},
      Map.put(good, "evidence", 1),
      Map.put(good, "command_proof", nil),
      Map.put(good, "other", true),
      put_in(good, ["evidence", "binding", "codex_project_id"], "other"),
      put_in(good, ["evidence", "binding", "candidate_sha"], String.duplicate("c", 40)),
      put_in(good, ["evidence", "emitter_sha256"], String.duplicate("c", 64)),
      put_in(good, ["evidence", "tool"], "archive_worktree"),
      put_in(good, ["command_proof", "thread_id"], "sibling-thread"),
      put_in(good, ["command_proof", "turn_id"], "writer-turn"),
      put_in(good, ["command_proof", "command_item", "cwd"], "/sibling/path"),
      put_in(good, ["command_proof", "command_item", "id"], "invented"),
      put_in(good, ["command_proof", "command_item", "exitCode"], 1),
      put_in(good, ["command_proof", "command_item", "output", "truncated"], true),
      put_in(good, ["command_proof", "command_item", "output", "text"], "{}"),
      put_in(good, ["command_proof", "command_item", "command"], other_command),
      put_in(good, ["command_proof", "command_item", "command"], "echo fake; python3 arbitrary.py")
    ]

    assert {:ok, recorded} = DesktopRequest.get(c.store, request["request_key"])

    for payload <- bad do
      assert {:error, _} = NativeMaintenanceEvidence.record(c.store, request["request_key"], payload)
      assert {:ok, ^recorded} = DesktopRequest.get(c.store, request["request_key"])
      assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
      assert [[0]] = Store.query!(c.store, "SELECT COUNT(*) FROM events WHERE event_type = 'NATIVE_MAINTENANCE_TARGET_EVIDENCE'").rows
    end

    assert {:error, :unknown_request} = NativeMaintenanceEvidence.record(c.store, "sibling-request", good)
  end

  test "stored evidence requires observed same-turn list_artifacts before completion", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    record(c, request)
    payload = emitted_evidence(request, artifacts(c))
    assert {:ok, _} = NativeMaintenanceEvidence.record(c.store, request["request_key"], payload)
    good = stored_completion(request, artifacts(c), payload)

    for attrs <- [
          put_in(good, ["turn_id"], "wrong-turn"),
          good |> Map.put("artifact_output", artifacts(c)) |> Map.put("turn_id", "bypass-turn"),
          Map.put(good, "artifact_output", %{"artifacts" => []}),
          put_in(good, ["thread_id"], "sibling-thread"),
          put_in(good, ["output", "completed_tool_calls"], []),
          Map.delete(good, "output"),
          put_in(good, ["output", "completed_tool_calls"], [1]),
          put_in(good, ["output", "completed_tool_calls", Access.at(0), "arguments"], %{"other" => true}),
          put_in(good, ["output", "completed_tool_calls", Access.at(0), "thread_id"], "sibling-thread")
        ] do
      assert {:error, _} = DesktopRequest.complete(c.store, request["request_key"], attrs)
      assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    end

    assert {:ok, _} = TaskLedger.update(c.store, c.writer["task_key"], %{turn_id: "new-writer-turn"})
    assert {:error, :maintenance_binding_changed} = DesktopRequest.complete(c.store, request["request_key"], good)
  end

  test "emitter-pinned request cannot complete through direct caller data without recorded evidence", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    record(c, request)
    assert {:ok, recorded} = DesktopRequest.get(c.store, request["request_key"])
    attrs = completion(request, artifacts(c))
    assert {:error, :maintenance_evidence_missing} = DesktopRequest.complete(c.store, request["request_key"], attrs)
    assert {:ok, ^recorded} = DesktopRequest.get(c.store, request["request_key"])
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
    assert [[0]] = Store.query!(c.store, "SELECT COUNT(*) FROM events WHERE event_type = 'NATIVE_MAINTENANCE_TARGET_EVIDENCE'").rows
  end

  test "unbound frames replayed sibling turns and duplicate evidence rows fail closed", c do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    record(c, request)
    payload = emitted_evidence(request, artifacts(c))
    key = request["request_key"]
    Store.query!(c.store, "UPDATE desktop_requests SET verified_project_id = 'wrong' WHERE request_key = ?", [key])
    assert {:error, :maintenance_request_not_bound} = NativeMaintenanceEvidence.record(c.store, key, payload)
    Store.query!(c.store, "UPDATE desktop_requests SET verified_project_id = 'project' WHERE request_key = ?", [key])
    Store.query!(c.store, "UPDATE desktop_requests SET thread_id = 'sibling-thread' WHERE request_key = ?", [key])
    assert {:error, :maintenance_request_not_bound} = NativeMaintenanceEvidence.record(c.store, key, payload)
    Store.query!(c.store, "UPDATE desktop_requests SET thread_id = 'writer-thread' WHERE request_key = ?", [key])

    Store.query!(
      c.store,
      """
      INSERT INTO desktop_requests(request_key, target_kind, target_key, action, status, payload_sha256,
        codex_project_id, model, reasoning_effort, title, prompt, schema_json, cwd, metadata_json,
        thread_id, turn_id, created_at, updated_at)
      SELECT 'sibling', target_kind, target_key, action, 'SUCCEEDED', payload_sha256,
        codex_project_id, model, reasoning_effort, title, prompt, schema_json, cwd, metadata_json,
        thread_id, ?, created_at, updated_at FROM desktop_requests WHERE request_key = ?
      """,
      [payload["command_proof"]["turn_id"], key]
    )

    assert {:error, :maintenance_command_turn_replayed} = NativeMaintenanceEvidence.record(c.store, key, payload)
    payload = put_in(payload, ["command_proof", "turn_id"], "different-probe-turn")
    assert {:ok, event} = NativeMaintenanceEvidence.record(c.store, key, payload)
    Store.query!(c.store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES(?,?,?,?)", [event["occurred_at"], event["event_type"], event["run_id"], event["payload_json"]])
    assert {:error, :maintenance_evidence_conflict} = NativeMaintenanceEvidence.record(c.store, key, payload)
    attrs = stored_completion(request, artifacts(c), payload)
    assert {:error, :maintenance_evidence_conflict} = DesktopRequest.complete(c.store, key, attrs)
    assert TaskLedger.get(c.store, c.writer["task_key"]) == {:ok, c.writer}
  end

  defp legacy_request(c) do
    assert {:ok, request} = NativeWorktreeProbe.enqueue(c.store, "run")
    attrs = request_attrs(request) |> update_in(["metadata"], &Map.delete(&1, "emitter_sha256"))
    Store.query!(c.store, "DELETE FROM desktop_requests WHERE request_key = ? AND status = 'PENDING'", [request["request_key"]])
    assert {:ok, legacy} = DesktopRequest.enqueue(c.store, attrs)
    legacy
  end

  defp emitted_evidence(request, observed) do
    input = NativeMaintenanceEvidence.input(request) |> Map.put("artifact_output", observed)
    encoded = input |> Jason.encode!() |> Base.encode64()
    emitter = NativeMaintenanceEvidence.emitter_path()
    {stdout, 0} = System.cmd("python3", ["-B", emitter, request["request_key"], "--payload-base64", encoded])
    command = "python3 -B #{emitter} #{request["request_key"]} --payload-base64 #{encoded}"

    %{
      "evidence" => Jason.decode!(stdout),
      "command_proof" => %{
        "thread_id" => request["existing_thread_id"],
        "turn_id" => "probe-maintenance-turn",
        "turn_status" => "completed",
        "command_item" => %{
          "type" => "commandExecution",
          "id" => "exec-1234abcd",
          "command" => "/bin/zsh -lc '#{command}'",
          "cwd" => request["cwd"],
          "status" => "completed",
          "exitCode" => 0,
          "output" => %{"text" => stdout, "truncated" => false}
        }
      }
    }
  end

  defp stored_completion(request, observed, payload) do
    completion(request, observed)
    |> Map.delete("artifact_output")
    |> Map.put("turn_id", payload["command_proof"]["turn_id"])
    |> put_in(["output", "completed_tool_calls"], [
      %{"tool" => "mcp__codex_app__list_artifacts", "status" => "completed", "arguments" => %{}, "thread_id" => request["existing_thread_id"], "turn_id" => payload["command_proof"]["turn_id"]}
    ])
  end

  defp record(c, request) do
    assert {:ok, _} = DesktopRequest.claim(c.store, request["request_key"])
    assert {:ok, _} = DesktopRequest.record_thread(c.store, request["request_key"], "writer-thread", "project", %{cwd: c.path, head_sha: c.sha})
  end

  defp artifacts(c),
    do: %{"artifacts" => [%{"id" => "artifact-id", "attachmentType" => "worktree", "identityKey" => c.path, "payload" => %{"root" => c.path, "workspaceRoot" => c.path, "sourceCwd" => c.repo}}]}

  defp completion(request, observed) do
    {:ok, receipt} = NativeWorktreeProbe.receipt(request, observed)

    %{
      "thread_id" => "writer-thread",
      "turn_id" => "probe-#{receipt["writer_turn_id"]}",
      "artifact_output" => observed,
      "output" => %{
        "result" => receipt,
        "completed_tool_calls" => [
          %{"tool" => "mcp__codex_app__list_artifacts", "status" => "completed", "output" => observed}
        ]
      }
    }
  end

  defp request_attrs(request) do
    request
    |> Map.take(~w(request_key target_kind target_key action existing_thread_id codex_project_id model reasoning_effort title prompt cwd branch base_branch))
    |> Map.put("schema", Jason.decode!(request["schema_json"]))
    |> Map.put("metadata", Jason.decode!(request["metadata_json"]))
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
