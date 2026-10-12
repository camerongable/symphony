defmodule SymphonyElixir.FactoryNativeSourceBindingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{DesktopRequest, DesktopStageRunner, NativeSourceBinding, RunLedger, Store, TaskLedger}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Tracker.Issue

  @bootstrap_schema %{"type" => "object", "required" => ["status"], "properties" => %{"status" => %{"enum" => ["WORKSPACE_READY"]}}}

  setup do
    root = Path.join(System.tmp_dir!(), "source-binding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    repo = Path.join(root, "repo")
    git!(root, ["init", repo])
    git!(repo, ["config", "user.email", "factory@example.test"])
    git!(repo, ["config", "user.name", "Factory Test"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "--no-verify", "-m", "base"])
    sha = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
    control = Path.join(root, "control")
    source = Path.join(root, "source")
    git!(repo, ["worktree", "add", "--detach", control, sha])
    git!(repo, ["worktree", "add", "--detach", source, sha])
    {:ok, repo} = PathSafety.canonicalize(repo)
    {:ok, control} = PathSafety.canonicalize(control)
    {:ok, source} = PathSafety.canonicalize(source)
    database = Path.join(root, "ledger.sqlite")
    store = start_supervised!({Store, database: database})

    {:ok, _} =
      RunLedger.register(store, %{
        run_id: "run",
        issue_key: "PPL-1",
        kind: "DELIVERY",
        state: "IMPLEMENTING",
        repo_path: repo,
        base_branch: "master",
        branch: "ai/PPL-1",
        factory_owned: false,
        workspace_state: "CODEX_NATIVE"
      })

    {:ok, _} =
      TaskLedger.register(store, %{
        task_key: "run:feature-writer",
        run_id: "run",
        stage: "IMPLEMENTING",
        role: "feature-writer",
        status: "STARTING",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6.1-sol",
        reasoning_effort: "medium",
        routing_reason: "test",
        codex_project_id: "project",
        prompt_sha256: digest("Implement")
      })

    %{store: store, database: database, repo: repo, control: control, source: source, sha: sha}
  end

  test "bootstrap persists source separately and preserves the writer allocation across restart", ctx do
    request = enqueue(ctx)
    assert {:ok, _} = DesktopRequest.claim(ctx.store, request.request_key)
    proof = proof(ctx)
    assert {:ok, %{"verified_cwd" => source}} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof)
    assert source == ctx.source
    assert {:ok, writer} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert writer["model"] == "gpt-6.1-sol"
    assert writer["reasoning_effort"] == "medium"
    assert writer["workspace"] == source
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    assert run["worktree"] == source
    assert run["factory_owned"] == 0
    assert {:ok, _} = DesktopRequest.complete(ctx.store, request.request_key, bootstrap_completion(ctx.sha))
    binding = NativeSourceBinding.get(ctx.store, "run:feature-writer")
    assert binding["control_workspace"] == ctx.control
    assert binding["source_workspace"] == source
    assert {:ok, reopened} = Store.start_link(database: ctx.database)
    assert NativeSourceBinding.get(reopened, "run:feature-writer") == binding
    GenServer.stop(reopened)
    assert {:ok, _} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof)
    assert {:error, {:not_claimable, "SUCCEEDED"}} = DesktopRequest.claim(ctx.store, request.request_key)
  end

  test "unproven, primary, dirty, wrong-SHA and ambiguous attachments cannot bind", ctx do
    request = enqueue(ctx)
    assert {:ok, _} = DesktopRequest.claim(ctx.store, request.request_key)
    original = proof(ctx)

    variants = [
      %{},
      Map.put(original, "cwd", ctx.control),
      Map.put(original, "head_sha", String.duplicate("a", 40)),
      proof(ctx, artifacts(ctx) ++ artifacts(ctx)),
      proof(ctx, []),
      proof(ctx, [put_in(hd(artifacts(ctx)), ["payload", "sourceCwd"], ctx.repo)]),
      put_in(original, ["source_binding", "command_proof", "thread_id"], "other"),
      put_in(original, ["source_binding", "command_proof", "command_item", "cwd"], ctx.control),
      put_in(original, ["source_binding", "command_proof", "command_item", "exitCode"], 1),
      put_in(original, ["source_binding", "command_proof", "command_item", "output", "truncated"], true),
      put_in(original, ["source_binding", "command_proof", "command_item", "output", "text"], "{}"),
      put_in(original, ["source_binding", "command_proof", "command_item", "command"], "printf forged")
    ]

    for invalid <- variants do
      assert {:error, _} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", invalid)
      assert NativeSourceBinding.get(ctx.store, "run:feature-writer") == nil
      assert {:ok, %{"workspace" => nil, "thread_id" => nil}} = TaskLedger.get(ctx.store, "run:feature-writer")
    end

    File.write!(Path.join(ctx.source, "untracked.txt"), "dirty")
    assert {:error, _} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", original)
    File.rm!(Path.join(ctx.source, "untracked.txt"))
    primary = Map.merge(ctx, %{source: ctx.repo})
    assert {:error, _} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof(primary))
    assert NativeSourceBinding.get(ctx.store, "run:feature-writer") == nil
  end

  test "only the mechanical writer bootstrap may use the fast-low model exception", ctx do
    base = attrs(ctx)

    for invalid <- [
          Map.put(base, :action, "FOLLOWUP"),
          Map.put(base, :cwd, ctx.control),
          Map.put(base, :request_key, "wrong"),
          Map.put(base, :reasoning_effort, "high"),
          put_in(base, [:metadata, "expected_sha"], nil),
          put_in(base, [:metadata, "bootstrap_model_route"], "invalid"),
          put_in(base, [:metadata, "source_emitter_sha256"], "invalid")
        ] do
      assert {:error, _} = DesktopRequest.enqueue(ctx.store, invalid)
    end

    assert {:error, :model_route_mismatch} = DesktopRequest.enqueue(ctx.store, put_in(base, [:metadata, "native_source_bootstrap"], false))
    assert {:ok, _} = TaskLedger.update(ctx.store, "run:feature-writer", %{role: "feature-writer-high-risk"})
    assert {:ok, _} = DesktopRequest.enqueue(ctx.store, base)
    assert {:error, :target_has_unresolved_request} = DesktopRequest.enqueue(ctx.store, Map.put(base, :request_key, "other:bootstrap"))
  end

  test "completed source turns require same-turn source execution and reject control writes", ctx do
    request = enqueue(ctx)
    {:ok, _} = DesktopRequest.claim(ctx.store, request.request_key)
    {:ok, _} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof(ctx))
    valid_bootstrap = bootstrap_completion(ctx.sha)

    for invalid <- [
          put_in(valid_bootstrap, [:output, "completed_tool_calls"], []),
          put_in(valid_bootstrap, [:output, "completed_tool_calls"], ["malformed"]),
          put_in(valid_bootstrap, [:output, "completed_tool_calls"], valid_bootstrap.output["completed_tool_calls"] ++ [%{"tool" => "mcp__codex_app__create_worktree", "status" => "failed"}]),
          put_in(valid_bootstrap, [:output, "completed_tool_calls"], Enum.map(valid_bootstrap.output["completed_tool_calls"], &Map.put(&1, "turn_id", "other"))),
          put_in(valid_bootstrap, [:output, "completed_tool_calls"], Enum.map(valid_bootstrap.output["completed_tool_calls"], &Map.put(&1, "input", "malformed")))
        ] do
      assert {:error, :native_source_bootstrap_calls_unproven} = DesktopRequest.complete(ctx.store, request.request_key, invalid)
    end

    {:ok, _} = DesktopRequest.complete(ctx.store, request.request_key, valid_bootstrap)

    followup =
      attrs(ctx)
      |> Map.merge(%{
        action: "FOLLOWUP",
        request_key: "source-turn",
        existing_thread_id: "thread",
        model: "gpt-6.1-sol",
        reasoning_effort: "medium",
        cwd: ctx.source,
        prompt: "Factory request ID: source-turn\n\nImplement",
        schema: %{"type" => "object"},
        metadata: %{"workspace_mode" => "CODEX_NATIVE", "expected_sha" => ctx.sha, "stage_prompt_sha256" => digest("Implement"), "previous_turn_id" => "bootstrap-turn"}
      })

    git!(ctx.source, ["switch", "-c", "ai/PPL-1"])
    {:ok, _} = DesktopRequest.enqueue(ctx.store, followup)
    {:ok, _} = DesktopRequest.claim(ctx.store, followup.request_key)
    {:ok, _} = DesktopRequest.record_thread(ctx.store, followup.request_key, "thread", "project", %{cwd: ctx.source, head_sha: ctx.sha})

    completion = %{
      "thread_id" => "thread",
      "turn_id" => "source-turn",
      "output" => %{"result" => %{"status" => "CONTINUE"}, "completed_tool_calls" => []},
      "source_execution" => %{
        "thread_id" => "thread",
        "turn_id" => "source-turn",
        "turn_status" => "completed",
        "commands" => [
          source_command(ctx.source)
        ],
        "changed_paths" => [Path.join(ctx.source, "README.md")]
      }
    }

    for invalid <- [
          Map.delete(completion, "source_execution"),
          put_in(completion, ["source_execution", "turn_id"], "other"),
          put_in(completion, ["source_execution", "commands"], []),
          put_in(completion, ["source_execution", "commands"], [source_command(ctx.control)]),
          put_in(completion, ["source_execution", "commands"], ["malformed"]),
          put_in(completion, ["source_execution", "changed_paths"], [nil]),
          put_in(completion, ["source_execution", "changed_paths"], ["README.md"]),
          put_in(completion, ["source_execution", "changed_paths"], [Path.join(ctx.control, "README.md")])
        ] do
      assert {:error, _} = DesktopRequest.complete(ctx.store, followup.request_key, invalid)
    end

    assert {:ok, _} = DesktopRequest.complete(ctx.store, followup.request_key, completion)
    assert {:ok, stored} = DesktopRequest.get(ctx.store, followup.request_key)
    output = Jason.decode!(stored["output_json"])
    assert output["source_execution"] == completion["source_execution"]
    assert {:ok, _} = DesktopRequest.complete(ctx.store, followup.request_key, Map.delete(completion, "source_execution") |> Map.put("output", output))

    assert {:error, :native_source_execution_conflict} =
             DesktopRequest.complete(ctx.store, followup.request_key, completion |> Map.put("output", output) |> put_in(["source_execution", "turn_id"], "other"))

    assert git!(ctx.repo, ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
    assert git!(ctx.control, ["rev-parse", "HEAD"]) |> String.trim() == ctx.sha
  end

  defp enqueue(ctx) do
    request = attrs(ctx)
    assert {:ok, _} = DesktopRequest.enqueue(ctx.store, request)
    request
  end

  defp attrs(ctx) do
    %{
      request_key: "source:bootstrap",
      target_kind: "TASK",
      target_key: "run:feature-writer",
      action: "CREATE",
      codex_project_id: "project",
      model: "gpt-6-luna",
      reasoning_effort: "low",
      title: "Writer",
      prompt: "Factory request ID: source:bootstrap\n\nSetup",
      cwd: ctx.repo,
      branch: "ai/PPL-1",
      base_branch: "master",
      schema: @bootstrap_schema,
      metadata: %{
        "workspace_mode" => "CODEX_NATIVE",
        "expected_sha" => ctx.sha,
        "native_source_bootstrap" => true,
        "source_emitter_sha256" => NativeSourceBinding.emitter_sha256(),
        "bootstrap_model_route" => %{"model_class" => "fast", "resolved_role" => "workspace-maintainer", "model" => "gpt-6-luna", "reasoning_effort" => "low"}
      }
    }
  end

  defp artifacts(ctx) do
    [%{"attachmentType" => "worktree", "identityKey" => ctx.source, "payload" => %{"root" => ctx.source, "workspaceRoot" => ctx.source, "sourceCwd" => ctx.control}}]
  end

  test "corrupt requests, symlink edits and overlapping bindings fail closed", ctx do
    request = enqueue(ctx)
    {:ok, _} = DesktopRequest.claim(ctx.store, request.request_key)
    {:ok, original} = DesktopRequest.get(ctx.store, request.request_key)
    Store.query!(ctx.store, "UPDATE desktop_requests SET prompt = 'changed' WHERE request_key = ?", [request.request_key])
    assert {:error, :request_payload_corrupt} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof(ctx))
    Store.query!(ctx.store, "UPDATE desktop_requests SET prompt = ? WHERE request_key = ?", [original["prompt"], request.request_key])
    assert {:ok, _} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof(ctx))
    assert {:error, :native_source_already_bound} = NativeSourceBinding.record(ctx.store, original, "thread", proof(ctx))
    binding = NativeSourceBinding.get(ctx.store, "run:feature-writer")

    assert {:ok, _} =
             RunLedger.register(ctx.store, %{
               run_id: "other",
               issue_key: "PPL-2",
               kind: "DELIVERY",
               state: "IMPLEMENTING",
               repo_path: ctx.repo,
               base_branch: "master",
               branch: "ai/PPL-1",
               factory_owned: false
             })

    {:ok, writer} = TaskLedger.get(ctx.store, "run:feature-writer")
    assert {:ok, _} = TaskLedger.register(ctx.store, writer |> Map.merge(%{"task_key" => "other:feature-writer", "run_id" => "other", "thread_id" => nil, "workspace" => nil, "workspace_sha" => nil}))
    other = attrs(ctx) |> Map.merge(%{request_key: "other:bootstrap", target_key: "other:feature-writer", prompt: "Factory request ID: other:bootstrap\n\nSetup"})
    {:ok, _} = DesktopRequest.enqueue(ctx.store, other)
    {:ok, _} = DesktopRequest.claim(ctx.store, other.request_key)
    other_proof = proof(ctx, nil, other.request_key) |> put_in(["source_binding", "command_proof", "thread_id"], "other-thread")
    assert {:error, :native_source_binding_conflict} = DesktopRequest.record_thread(ctx.store, other.request_key, "other-thread", "project", other_proof)
    assert NativeSourceBinding.get(ctx.store, "other:feature-writer") == nil
    assert NativeSourceBinding.get(ctx.store, "run:feature-writer") == binding

    File.ln_s!(ctx.control, Path.join(ctx.source, "escape"))

    attrs = %{
      "thread_id" => "thread",
      "turn_id" => "turn",
      "source_execution" => %{
        "thread_id" => "thread",
        "turn_id" => "turn",
        "turn_status" => "completed",
        "commands" => [source_command(ctx.source)],
        "changed_paths" => [Path.join(ctx.source, "escape/README.md")]
      }
    }

    followup = %{"target_key" => "run:feature-writer", "action" => "FOLLOWUP", "verified_cwd" => ctx.source}
    assert {:error, :native_source_execution_mismatch} = NativeSourceBinding.validate_completion(ctx.store, followup, attrs)
    assert {:ok, %{}} = NativeSourceBinding.attach(ctx.store, followup, %{})
    assert NativeSourceBinding.validate_completion(ctx.store, Map.put(followup, "metadata_json", Jason.encode!(%{"maintenance_operation" => "NATIVE_WORKTREE_PROBE"})), %{}) == :ok
  end

  test "binding refuses stale task paths and a receipt for a different candidate", ctx do
    candidate = String.duplicate("a", 40)
    request = attrs(ctx) |> put_in([:metadata, "expected_sha"], candidate)
    {:ok, _} = DesktopRequest.enqueue(ctx.store, request)
    {:ok, _} = DesktopRequest.claim(ctx.store, request.request_key)
    assert {:error, :native_source_sha_mismatch} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof(ctx))
    assert {:ok, _} = TaskLedger.update(ctx.store, "run:feature-writer", %{workspace: ctx.control})
    assert {:error, :native_source_existing_workspace} = DesktopRequest.record_thread(ctx.store, request.request_key, "thread", "project", proof(ctx))

    for malformed <- [nil, "not-json", "[]"] do
      refute NativeSourceBinding.bootstrap?(%{"metadata_json" => malformed})
      assert {:error, :native_source_bootstrap_required} = NativeSourceBinding.record(ctx.store, %{"metadata_json" => malformed}, "thread", %{})
    end
  end

  test "attachment bootstrap uses the cheap setup route then sends source work with the normal writer allocation", ctx do
    opts = [
      store: ctx.store,
      target_kind: "TASK",
      target_key: "run:feature-writer",
      project_id: "project",
      request_key: "stage",
      thread_name: "Writer",
      issue_key: "PPL-1",
      model: "gpt-6.1-sol",
      reasoning_effort: "medium",
      workspace_mode: "CODEX_NATIVE",
      expected_sha: ctx.sha,
      branch: "ai/PPL-1",
      base_branch: "master",
      poll_ms: 5,
      wait_timeout_ms: 4_000,
      native_source_attachment_enabled: true,
      model_policy: %{"default_provider" => "codex", "providers" => %{"codex" => %{"fast" => "gpt-6-luna"}}}
    ]

    runner = Task.async(fn -> DesktopStageRunner.run(ctx.repo, %Issue{}, "Implement", %{"type" => "object"}, opts) end)
    wait_timeout_ms = Keyword.fetch!(opts, :wait_timeout_ms)
    setup_request = wait_for_stage_request(ctx.store, "stage:bootstrap", runner, wait_timeout_ms)
    assert setup_request["model"] == "gpt-6-luna"
    assert setup_request["reasoning_effort"] == "low"
    assert {:ok, _} = DesktopRequest.claim(ctx.store, "stage:bootstrap")
    assert {:ok, _} = DesktopRequest.record_thread(ctx.store, "stage:bootstrap", "thread", "project", proof(ctx, nil, "stage:bootstrap"))
    assert {:ok, recorded} = DesktopRequest.get(ctx.store, "stage:bootstrap")
    Task.shutdown(runner, :brutal_kill)
    runner = Task.async(fn -> DesktopStageRunner.run(ctx.repo, %Issue{}, "Implement", %{"type" => "object"}, opts) end)
    Process.sleep(20)
    assert {:ok, ^recorded} = DesktopRequest.get(ctx.store, "stage:bootstrap")
    assert {:ok, _} = DesktopRequest.complete(ctx.store, "stage:bootstrap", bootstrap_completion(ctx.sha))
    source_request = wait_for_stage_request(ctx.store, "stage", runner, wait_timeout_ms)
    assert source_request["model"] == "gpt-6.1-sol"
    assert source_request["reasoning_effort"] == "medium"
    assert source_request["cwd"] == ctx.source
    assert source_request["existing_thread_id"] == "thread"
    assert String.contains?(source_request["prompt"], "SOURCE is #{ctx.source}")
    assert Jason.decode!(source_request["metadata_json"])["stage_prompt_sha256"] == digest("Implement")
    assert {:ok, _} = DesktopRequest.claim(ctx.store, "stage")
    assert {:ok, _} = DesktopRequest.record_thread(ctx.store, "stage", "thread", "project", %{cwd: ctx.source, head_sha: ctx.sha})

    assert {:ok, _} =
             DesktopRequest.complete(ctx.store, "stage", %{
               thread_id: "thread",
               turn_id: "source-turn",
               output: %{"result" => %{"status" => "CONTINUE"}, "completed_tool_calls" => []},
               source_execution: %{
                 "thread_id" => "thread",
                 "turn_id" => "source-turn",
                 "turn_status" => "completed",
                 "commands" => [
                   source_command(ctx.source)
                 ],
                 "changed_paths" => []
               }
             })

    assert {:ok, %{thread_id: "thread", turn_id: "source-turn"}} = Task.await(runner)
    assert NativeSourceBinding.get(ctx.store, "run:feature-writer")["source_workspace"] == ctx.source
  end

  defp wait_for_stage_request(store, key, runner, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_stage_request(store, key, runner, deadline, timeout_ms)
  end

  defp wait_for_stage_request(store, key, runner, deadline, timeout_ms) do
    case DesktopRequest.get(store, key) do
      {:ok, request} ->
        request

      _other ->
        poll_stage_request(store, key, runner, deadline, timeout_ms)
    end
  end

  defp poll_stage_request(store, key, runner, deadline, timeout_ms) do
    case Task.yield(runner, 0) do
      {:ok, result} ->
        flunk("request missing: #{key}; stage runner completed before publishing the request: #{inspect(result)}")

      {:exit, reason} ->
        flunk("request missing: #{key}; stage runner exited before publishing the request: #{inspect(reason)}")

      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)
        if remaining <= 0, do: flunk("request missing: #{key} after #{timeout_ms}ms while stage runner remained active")
        Process.sleep(min(5, remaining))
        wait_for_stage_request(store, key, runner, deadline, timeout_ms)
    end
  end

  defp proof(ctx, items \\ nil, key \\ "source:bootstrap") do
    payload = %{"control_cwd" => ctx.control, "artifact_output" => %{"artifacts" => items || artifacts(ctx)}} |> Jason.encode!() |> Base.encode64()
    emitter = NativeSourceBinding.emitter_path()
    {stdout, 0} = System.cmd("python3", ["-B", emitter, key, "--payload-base64", payload], cd: ctx.source)

    %{
      "cwd" => ctx.source,
      "head_sha" => ctx.sha,
      "source_binding" => %{
        "evidence" => Jason.decode!(stdout),
        "command_proof" => %{
          "thread_id" => "thread",
          "turn_id" => "bootstrap-turn",
          "turn_status" => "completed",
          "command_item" => %{
            "type" => "commandExecution",
            "id" => "exec-aabb",
            "command" => "python3 -B #{emitter} #{key} --payload-base64 #{payload}",
            "cwd" => ctx.source,
            "status" => "completed",
            "exitCode" => 0,
            "output" => %{"text" => stdout, "truncated" => false}
          }
        }
      }
    }
  end

  defp bootstrap_completion(sha) do
    %{
      thread_id: "thread",
      turn_id: "bootstrap-turn",
      output: %{
        "result" => %{"status" => "WORKSPACE_READY"},
        "completed_tool_calls" =>
          Enum.map(~w(mcp__codex_app__create_worktree mcp__codex_app__list_artifacts), fn tool ->
            %{
              "tool" => tool,
              "status" => "completed",
              "thread_id" => "thread",
              "turn_id" => "bootstrap-turn",
              "input" => if(tool == "mcp__codex_app__create_worktree", do: %{"ref" => sha, "allowAsync" => true}, else: %{})
            }
          end)
      }
    }
  end

  defp source_command(cwd) do
    %{"type" => "commandExecution", "id" => "exec-abcd", "command" => "pwd", "status" => "completed", "exitCode" => 0, "cwd" => cwd, "output" => %{"text" => cwd, "truncated" => false}}
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
