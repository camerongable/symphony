defmodule SymphonyElixir.TicketWorkerFixture do
  @moduledoc false
  alias SymphonyElixir.Factory.{Contract, DesktopRequest, DesktopToolArgs, RunLedger, Store, TaskLedger, TicketChat}
  alias SymphonyElixir.Factory.TicketContextReader
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TicketChatFixture

  def setup_fixture(context) do
    token = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "ticket-worker-#{token}")
    File.mkdir_p!(root)
    {:ok, root} = PathSafety.canonicalize(root)
    repo = Path.join(root, "repo")
    git(root, ["init", repo])
    git(repo, ["config", "user.name", "Fixture"])
    git(repo, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(repo, "fixture.txt"), "base\n")
    git(repo, ["add", "fixture.txt"])

    if context[:ordinary_go_generation] || context[:qualified_go_routing] do
      for package <- ~w(dep pkg moved), do: File.mkdir_p!(Path.join(repo, package))

      files = %{
        "WORKSPACE" => "workspace(name = \"fixture\")\n",
        "BUILD" => "# gazelle:prefix example.invalid/fixture\n",
        "dep/dep.go" => "package dep\n\nconst Value = 1\n",
        "dep/BUILD" =>
          "load(\"@io_bazel_rules_go//go:def.bzl\", \"go_library\")\n\ngo_library(\n    name = \"dep\",\n    srcs = [\"dep.go\"],\n    importpath = \"example.invalid/fixture/dep\",\n    visibility = [\"//visibility:public\"],\n)\n",
        "pkg/old.go" => "package pkg\n\nconst Value = 0\n",
        "pkg/BUILD" =>
          "load(\"@io_bazel_rules_go//go:def.bzl\", \"go_library\")\n\ngo_library(\n    name = \"pkg\",\n    srcs = [\"old.go\"],\n    importpath = \"example.invalid/fixture/pkg\",\n    visibility = [\"//visibility:public\"],\n)\n"
      }

      Enum.each(files, fn {path, content} -> File.write!(Path.join(repo, path), content) end)
      git(repo, ["add" | Map.keys(files)])
    end

    git(repo, ["commit", "--no-verify", "-m", "base"])
    git(repo, ["branch", "-M", "master"])
    git(repo, ["update-ref", "refs/remotes/origin/master", "HEAD"])
    path = Path.join(root, "workspaces/source")
    git(repo, ["worktree", "add", "-b", "cgable/fixture", path, "HEAD"])
    if context[:ordinary_go_generation] || context[:qualified_go_routing], do: File.mkdir_p!(Path.join(path, "moved"))
    sha = git(path, ["rev-parse", "HEAD"]) |> String.trim()
    database = Path.join(root, "factory.sqlite")
    store = ExUnit.Callbacks.start_supervised!({Store, database: database})

    ExUnit.Callbacks.on_exit(fn ->
      if retain_fixture?(context),
        do: IO.puts("retained owned lifecycle fixture: #{root}"),
        else: File.rm_rf!(root)
    end)

    ctx = Map.merge(context, %{store: store, root: root, repo: repo, path: path, sha: sha, database: database})
    if context[:unregistered] != true, do: register(ctx, "run", "PPL-123", "writer")
    ctx
  end

  defp retain_fixture?(context) do
    (context[:ordinary_go_generation] == true and System.get_env("RETAIN_ORDINARY_GENERATION_FIXTURE") == "1") or
      (context[:late_ten_budget] == true and System.get_env("RETAIN_LATE_TEN_FIXTURE") == "1") or
      (context[:push_packet_history] == true and System.get_env("RETAIN_PUSH_PACKET_FIXTURE") == "1") or
      (context[:push_prepared_requalification] == true and System.get_env("RETAIN_PREPARED_PUSH_FIXTURE") == "1") or
      context[:ci_generated_only] == true
  end

  def register(ctx, run_id, issue, task_key, path \\ nil, branch \\ "cgable/fixture") do
    contract = Contract.bind(issue, 1, "Implement the fixture behavior.")

    {:ok, _} =
      RunLedger.register(ctx.store, %{
        run_id: run_id,
        issue_key: issue,
        kind: "DELIVERY",
        state: "WRITING",
        repo_key: "grail",
        repo_path: ctx.repo,
        base_branch: "master",
        worktree: path || ctx.path,
        branch: branch,
        candidate_sha: ctx.sha,
        spec_revision: 1,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        snapshot_json: Jason.encode!(%{id: "issue-id"}),
        execution_mode: "TICKET_SUPERVISOR_V1"
      })

    {:ok, _} =
      TaskLedger.register(ctx.store, %{
        task_key: task_key,
        run_id: run_id,
        stage: "feature_writer",
        role: "feature-writer",
        status: "STARTING",
        model_provider: "codex",
        model_class: "fast",
        model: "gpt-6-luna",
        reasoning_effort: "medium",
        routing_reason: "fixture",
        prompt_sha256: String.duplicate("p", 64),
        workspace: path || ctx.path,
        workspace_sha: ctx.sha
      })
  end

  def bind_parent(ctx) do
    {contract, snapshot} = TicketChatFixture.authorized_contract("PPL-123", "issue-id")

    {:ok, _} =
      RunLedger.update(ctx.store, "run", %{
        spec_revision: contract.revision,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        snapshot_json: Jason.encode!(snapshot),
        manual_validation_required: 0
      })

    cwd = Path.join(ctx.root, TicketChat.directory_name("scope", "issue-id", "grail"))
    File.mkdir_p!(cwd)

    locator =
      if ctx[:recovered_bootstrap] do
        workflow = Path.join(ctx.root, "parent-workflow.md")
        File.write!(workflow, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{ctx.database}\n---\n")
        {:ok, json} = TicketContextReader.bind(ctx.store, "run", ticket_cli_root: Path.expand("../..", __DIR__), ticket_workflow: workflow)
        json
      end

    {:ok, %{chat: chat, request: request}} =
      TicketChat.reserve(ctx.store, "run", %{
        scope_key: "scope",
        issue_id: "issue-id",
        issue_key: "PPL-123",
        repo_key: "grail",
        route: "desktop_owned_ticket_chat_v1",
        broker_thread_id: ctx[:broker_thread_id],
        cwd: cwd,
        model: "gpt-6-luna",
        reasoning_effort: "low",
        title: "PPL-123 · Ticket",
        prompt: "Bootstrap",
        context_reader_json: locator
      })

    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'CREATE_UNCERTAIN', claimed_at = ? WHERE request_key = ?", [DateTime.to_iso8601(DateTime.utc_now()), request["request_key"]])
    {:ok, args} = DesktopToolArgs.create_thread(request)

    proof = %{
      "request_key" => request["request_key"],
      "payload_sha256" => request["payload_sha256"],
      "generation" => 1,
      "thread_id" => "parent",
      "project_id" => nil,
      "cwd" => cwd,
      "tool_arguments" => args,
      "worktree_attachments" => []
    }

    {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, request["request_key"], proof)

    if ctx[:recovered_bootstrap] do
      artifact = %{"server" => "codex_app", "tool" => "list_artifacts", "arguments" => %{}, "result" => %{"content" => [%{"type" => "text", "text" => "{\"artifacts\":[]}"}]}}

      negative = %{
        "result" => %{"acknowledged" => false},
        "completed_tool_calls" => [],
        "bootstrap_evidence" => %{"list_artifacts" => [artifact], "completed_commands" => []},
        "native_readback_sha256" => String.duplicate("a", 64)
      }

      {:ok, %{"status" => "FAILED"}} = DesktopRequest.complete(ctx.store, request["request_key"], %{thread_id: "parent", turn_id: "bootstrap", output: negative})

      identity =
        Map.take(chat, ~w(scope_key issue_id issue_key repo_key route broker_thread_id cwd model reasoning_effort context_reader_json))
        |> Map.merge(%{"title" => request["title"], "prompt" => "Bootstrap"})

      {:ok, %{request: recovery}} = TicketChat.reserve(ctx.store, "run", identity)
      guard = TicketChatFixture.parent_guard(%{cwd: cwd})
      {:ok, recovery} = DesktopRequest.claim(ctx.store, recovery["request_key"], ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}, parent_guard: guard)
      {:ok, followup} = DesktopToolArgs.followup(recovery)
      recovery_proof = Map.merge(proof, %{"request_key" => recovery["request_key"], "payload_sha256" => recovery["payload_sha256"], "tool_arguments" => followup})
      {:ok, _} = DesktopRequest.record_ticket_thread(ctx.store, recovery["request_key"], recovery_proof)
      decoded = Jason.decode!(locator)

      positive =
        put_in(negative, ["result", "acknowledged"], true)
        |> Map.put("native_readback_sha256", String.duplicate("b", 64))
        |> put_in(["bootstrap_evidence", "completed_commands"], [%{"status" => "completed", "exit_code" => 0, "cwd" => decoded["cwd"], "command_actions" => [%{"command" => decoded["command"]}]}])

      {:ok, %{"status" => "SUCCEEDED"}} = DesktopRequest.complete(ctx.store, recovery["request_key"], %{thread_id: "parent", turn_id: "recovery", output: positive})
      {:ok, _} = TicketChat.ready_for_run(ctx.store, "run")
    else
      {:ok, _} =
        DesktopRequest.complete(ctx.store, request["request_key"], %{thread_id: "parent", turn_id: "bootstrap", output: %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}})
    end

    chat
  end

  def attrs(ctx, mode \\ "SOURCE", key \\ "reservation"),
    do: %{
      "reservation_key" => key,
      "run_id" => "run",
      "task_key" => "writer",
      "request_key" => key <> ":request",
      "mode" => mode,
      "allowed_root" => Path.join(ctx.root, "workspaces"),
      "expected_sha" => ctx.sha
    }

  def opts(ctx, bytes \\ 21_000_000_000) do
    [
      capacity_policy: %{"repositories" => %{"grail" => %{"path" => ctx.repo}}, "capacity" => %{"writer_disk_gb" => 20, "maximum_writers" => 2, "maximum_specifiers" => 2, "maximum_validators" => 2}},
      free_bytes: bytes
    ]
  end

  def stop_receipt(ctx, thread \\ "worker"),
    do: %{"transport" => "owned_app_server", "thread_id" => thread, "pid" => "fixture", "invocation_nonce" => String.duplicate("a", 64), "exit_status" => 0, "cwd" => ctx.path}

  def process_receipt, do: %{"pid" => "fixture", "invocation_nonce" => String.duplicate("a", 64)}

  def git(path, args) do
    {output, status} =
      System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", path | args], stderr_to_stdout: true, env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}])

    if status != 0, do: raise("fixture Git failed: #{output}")
    output
  end
end
