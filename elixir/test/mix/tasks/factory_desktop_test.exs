defmodule Mix.Tasks.Factory.DesktopTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Factory.Desktop
  alias SymphonyElixir.Factory.{DesktopRequest, RunLedger, Store, TaskLedger}

  setup do
    root = Path.join(System.tmp_dir!(), "desktop-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    database = Path.join(root, "factory.sqlite")
    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{database}\n---\n")
    store = start_supervised!({Store, database: database})
    {:ok, _} = RunLedger.register(store, %{run_id: "run", issue_key: "PPL-123", kind: "DELIVERY", state: "VERIFYING"})

    {:ok, _} =
      TaskLedger.register(store, %{
        task_key: "verify",
        run_id: "run",
        stage: "VERIFYING",
        role: "change-verifier",
        status: "STARTING",
        model_provider: "codex",
        model_class: "standard",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        routing_reason: "role-policy",
        codex_project_id: "project-grail",
        prompt_sha256: String.duplicate("a", 64)
      })

    on_exit(fn -> File.rm_rf!(root) end)
    %{store: store, workflow: workflow}
  end

  test "create-thread-args prints the exact tool object without claiming the request", context do
    enqueue(context.store, "CODEX_NATIVE")

    args =
      capture_io(fn -> Desktop.run(["create-thread-args", "verify:create", "--workflow", context.workflow]) end)
      |> Jason.decode!()

    assert Enum.sort(Map.keys(args)) == ~w(model prompt target thinking title)
    assert args["target"]["projectId"] == "project-grail"
    assert args["target"]["environment"]["startingState"]["branchName"] == String.duplicate("a", 40)
    assert {:ok, %{"status" => "PENDING", "claimed_at" => nil}} = DesktopRequest.get(context.store, "verify:create")
  end

  test "create-thread-args rejects unsupported workspace routes before any tool call", context do
    enqueue(context.store, "FACTORY")

    assert_raise Mix.Error, ~r/unsupported_create_thread_workspace_mode/, fn ->
      Desktop.run(["create-thread-args", "verify:create", "--workflow", context.workflow])
    end
  end

  test "create-thread-args requires exactly one request key" do
    assert_raise Mix.Error, ~r/Invalid arguments/, fn -> Desktop.run(["create-thread-args"]) end
  end

  defp enqueue(store, mode) do
    {:ok, _} =
      DesktopRequest.enqueue(store, %{
        request_key: "verify:create",
        target_key: "verify",
        target_kind: "TASK",
        action: "CREATE",
        codex_project_id: "project-grail",
        model: "gpt-6-sol",
        reasoning_effort: "high",
        title: "Verify candidate",
        prompt: "Verify the exact candidate.",
        cwd: "/tmp/repo",
        metadata: %{"workspace_mode" => mode, "expected_sha" => String.duplicate("a", 40)}
      })
  end
end
