defmodule Mix.Tasks.Factory.DesktopTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Factory.Desktop
  alias SymphonyElixir.Factory.{DesktopRequest, RunLedger, Store, TaskLedger, TicketChat}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TicketChatFixture

  setup do
    token = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "desktop-cli-#{token}")
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

  test "MR claim CLI rejects incomplete static policy before connector calls or ledger mutation", context do
    enqueue(context.store, "CODEX_NATIVE")
    assert {:ok, request} = DesktopRequest.get(context.store, "verify:create")
    database = Path.join(Path.dirname(context.workflow), "factory.sqlite")

    File.write!(context.workflow, """
    ---
    tracker:
      kind: memory
    factory:
      database: #{database}
      ticket_supervisor:
        enabled: true
        pilot_issue_keys: [PPL-123]
    ---
    """)

    for args <- [
          ["claim-ticket-mr", "verify:create", "--source-thread-id", "broker", "--payload-base64", Base.encode64("{}")],
          ["claim-ticket-mr-interactive", "verify:create", "--source-thread-id", "broker"]
        ] do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/missing_queue_setting.*assignee/, fn ->
            Desktop.run(args ++ ["--workflow", context.workflow])
          end
        end)

      assert output == ""
    end

    assert {:ok, ^request} = DesktopRequest.get(context.store, "verify:create")
    assert Store.one!(context.store, "SELECT COUNT(*) AS n FROM ticket_mr_claims")["n"] == 0
  end

  test "MR claim CLI requires explicit broker identity and guard payload" do
    assert_raise Mix.Error, ~r/Invalid arguments/, fn -> Desktop.run(["claim-ticket-mr", "request"]) end
  end

  test "explicit workflow scope is restored after both success and loading failure", context do
    original = Application.fetch_env(:symphony_elixir, :workflow_file_path)

    try do
      for previous <- [:error, {:ok, Path.join(Path.dirname(context.workflow), "previous.md")}] do
        restore_workflow(previous)
        capture_io(fn -> Desktop.run(["list", "--workflow", context.workflow]) end)
        assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == previous

        assert_raise Mix.Error, fn -> Desktop.run(["list", "--workflow", context.workflow <> ".missing"]) end
        assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == previous
      end
    after
      restore_workflow(original)
    end
  end

  defp restore_workflow({:ok, previous}), do: SymphonyElixir.Workflow.set_workflow_file_path(previous)
  defp restore_workflow(:error), do: SymphonyElixir.Workflow.clear_workflow_file_path()

  test "disabled ticket route cannot be issued or mutated through the broker CLI", context do
    {:ok, root} = PathSafety.canonicalize(Path.dirname(context.workflow))

    {contract, snapshot} = TicketChatFixture.authorized_contract("PPL-124", "issue-124")

    {:ok, _} =
      RunLedger.register(context.store, %{
        run_id: "ticket-run",
        issue_key: "PPL-124",
        kind: "DELIVERY",
        state: "WRITING",
        execution_mode: "TICKET_SUPERVISOR_V1",
        repo_key: "grail",
        repo_path: Path.join(root, "source"),
        snapshot_json: Jason.encode!(snapshot),
        spec_revision: contract.revision,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        manual_validation_required: 0
      })

    {:ok, reserved} =
      TicketChat.reserve(context.store, "ticket-run", %{
        scope_key: "scope",
        issue_id: "issue-124",
        issue_key: "PPL-124",
        repo_key: "grail",
        route: "desktop_owned_ticket_chat_v1",
        cwd: Path.join(root, TicketChat.directory_name("scope", "issue-124", "grail")),
        model: "gpt-6-luna",
        reasoning_effort: "low",
        title: "PPL-124 · Factory",
        prompt: "Read current context only."
      })

    key = reserved.request["request_key"]

    actions = [
      ["claim", key],
      ["create-thread-args", key],
      ["find-thread", key],
      ["record-thread", key, "thread", "projectless"],
      ["fail", key, "FAILED"],
      ["complete", key, "--payload-base64", Base.encode64("{}")],
      ["record-maintenance-evidence", key, "--payload-base64", Base.encode64("{}")]
    ]

    for action <- actions do
      assert_raise Mix.Error, ~r/ticket_chat_runtime_not_integrated/, fn ->
        Desktop.run(action ++ ["--workflow", context.workflow])
      end
    end

    expected = reserved.request
    assert {:ok, ^expected} = DesktopRequest.get(context.store, key)
    assert DesktopRequest.list_pending(context.store) == []
    shown = capture_io(fn -> Desktop.run(["show", key, "--workflow", context.workflow]) end) |> Jason.decode!()
    assert shown["target_kind"] == "TICKET_CHAT"
    assert shown["codex_project_id"] == nil
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
