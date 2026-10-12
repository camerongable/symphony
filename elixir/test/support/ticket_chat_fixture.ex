defmodule SymphonyElixir.TicketChatFixture do
  @moduledoc false
  alias SymphonyElixir.Factory.{Contract, DesktopRequest, DesktopToolArgs, RunLedger, Store}
  alias SymphonyElixir.Factory.{TicketChat, TicketChatCommands}
  alias SymphonyElixir.PathSafety

  def runtime_fixture(root, response \\ :supported, before_reply \\ "") do
    previous = Application.get_env(:symphony_elixir, :workflow_file_path)
    command = Path.join(root, "runtime-fixture")
    trace = Path.join(root, "runtime-fixture.trace")
    workflow = Path.join(root, "runtime-WORKFLOW.md")

    response =
      if response == :supported do
        %{
          "codexHome" => System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
          "platformFamily" => "unix",
          "platformOs" => "macos",
          "userAgent" => "symphony-orchestrator/0.160.0 (fixture)"
        }
      else
        response
      end

    File.write!(command, """
    #!/bin/sh
    trap 'exit 143' TERM
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> '#{trace}'
      case "$line" in
        *'"method":"initialize"'*)
          #{before_reply}
          printf '%s\\n' '#{Jason.encode!(%{"id" => 1, "result" => response})}' ;;
      esac
    done
    """)

    File.chmod!(command, 0o755)
    SymphonyElixir.TestSupport.write_workflow_file!(workflow, codex_command: "#{command} app-server")
    SymphonyElixir.Workflow.set_workflow_file_path(workflow)

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        SymphonyElixir.Workflow.set_workflow_file_path(previous)
      else
        SymphonyElixir.Workflow.clear_workflow_file_path()
      end
    end)

    trace
  end

  def authorized_contract(issue, issue_id, markdown \\ "A confirmed contract\n\n## Manual Validation\n- Required: no") do
    contract = Contract.bind(issue, 1, markdown)

    snapshot = %{
      "key" => issue,
      "id" => issue_id,
      "comments" => [
        %{"text" => Contract.draft_comment(contract)},
        %{"text" => Contract.specification_skill_authorization_marker(contract)}
      ]
    }

    {contract, snapshot}
  end

  def setup_fixture(context, opts \\ []) do
    token = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "ticket-context-#{token}")
    File.mkdir_p!(root)
    {:ok, root} = PathSafety.canonicalize(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "factory.sqlite")
    store = ExUnit.Callbacks.start_supervised!({Store, database: database})
    {contract, snapshot} = authorized_contract("PPL-123", "issue-id")

    {:ok, _} =
      RunLedger.register(store, %{
        run_id: "run",
        issue_key: "PPL-123",
        repo_key: "grail",
        kind: "DELIVERY",
        state: "WRITING",
        execution_mode: "TICKET_SUPERVISOR_V1",
        repo_path: Path.join(root, "source"),
        snapshot_json: Jason.encode!(snapshot),
        spec_revision: 1,
        contract_sha256: contract.sha256,
        contract_markdown: contract.markdown,
        manual_validation_required: 0,
        candidate_sha: String.duplicate("a", 40)
      })

    cwd = Path.join(root, TicketChat.directory_name("scope", "issue-id", "grail"))

    attrs = %{
      scope_key: "scope",
      issue_id: "issue-id",
      issue_key: "PPL-123",
      repo_key: "grail",
      route: "desktop_owned_ticket_chat_v1",
      cwd: cwd,
      model: "gpt-6-luna",
      reasoning_effort: "low",
      title: "PPL-123 · Ticket",
      prompt: "Ticket bootstrap"
    }

    attrs = if is_binary(opts[:broker_thread_id]), do: Map.put(attrs, :broker_thread_id, opts[:broker_thread_id]), else: attrs

    {:ok, %{chat: chat, request: request}} = TicketChat.reserve(store, "run", attrs)

    File.mkdir_p!(cwd)
    # This is an offline binding fixture, not evidence of a native tool call.
    Store.query!(store, "UPDATE desktop_requests SET status = 'CREATE_UNCERTAIN', claimed_at = ? WHERE request_key = ?", [DateTime.to_iso8601(DateTime.utc_now()), request["request_key"]])
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

    {:ok, _} = DesktopRequest.record_ticket_thread(store, request["request_key"], proof)
    output = %{"result" => %{"acknowledged" => true}, "completed_tool_calls" => []}
    {:ok, _} = DesktopRequest.complete(store, request["request_key"], %{thread_id: "parent", turn_id: "bootstrap", output: output})
    Map.merge(context, %{store: store, root: root, cwd: cwd, database: database, chat: chat, contract: contract})
  end

  def stage(ctx, id, body, operations) do
    run_id = Map.get(ctx, :run_id, "run")
    {:ok, run} = RunLedger.get(ctx.store, run_id)
    attrs = Map.take(run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.merge(%{"generation" => 1, "proposal_id" => id, "body" => body, "operations" => operations})
    TicketChatCommands.stage(ctx.store, run_id, attrs)
  end

  def claim_followup(ctx, key, opts \\ [ticket_policy: %{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}]) do
    DesktopRequest.claim(ctx.store, key, Keyword.put(opts, :parent_guard, parent_guard(ctx)))
  end

  def parent_guard(ctx) do
    at = DateTime.to_iso8601(DateTime.utc_now())
    owner = %{"schemaVersion" => 1, "thread" => %{"id" => "parent", "cwd" => ctx.cwd, "kind" => "codex", "hostId" => "local", "status" => %{"type" => "idle"}}}
    raw = %{"data" => [], "nextCursor" => nil}
    sha = :crypto.hash(:sha256, Jason.encode!(raw)) |> Base.encode16(case: :lower)
    queue = %{"thread_id" => "parent", "observed_at" => at, "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false, "raw_response" => raw, "sha256" => sha}

    %{
      "source_thread_id" => "019fa5b7-27fa-7660-ab47-7c3abb867c91",
      "owner" => %{"source" => "codex_app/read_thread", "observed_at" => at, "response" => owner},
      "native" => %{"id" => "parent", "cwd" => ctx.cwd, "projectId" => nil, "queue_observation" => queue}
    }
  end

  def native(ctx, bodies), do: native(ctx, bodies, nil)

  def native(ctx, bodies, staged_command_key) do
    run_id = Map.get(ctx, :run_id, "run")

    %{
      "id" => "parent",
      "cwd" => ctx.cwd,
      "projectId" => nil,
      "turns" =>
        Enum.with_index(bodies, 1)
        |> Enum.map(fn {body, n} ->
          sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

          command =
            if is_binary(staged_command_key) do
              Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ? AND chat_key = ? AND body_sha256 = ?", [staged_command_key, ctx.chat["chat_key"], sha])
            else
              Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE body_sha256 = ? ORDER BY created_at LIMIT 1", [sha])
            end

          started =
            if command do
              {:ok, at, _} = DateTime.from_iso8601(command["created_at"])
              DateTime.to_unix(at, :microsecond) / 1_000_000
            else
              System.system_time(:millisecond) / 1000
            end

          frame =
            if command do
              original = Jason.decode!(command["payload_json"]) |> Enum.map(&Map.delete(&1, "question_digest"))
              attrs = Jason.decode!(command["binding_json"]) |> Map.merge(%{"proposal_id" => command["proposal_id"], "body" => body, "operations" => original})
              encoded = attrs |> Jason.encode!() |> Base.encode64()

              [
                %{
                  "type" => "commandExecution",
                  "status" => "completed",
                  "exitCode" => 0,
                  "command" => "mise exec -- mix factory.ticket stage #{run_id} --payload-base64 #{encoded} --workflow #{ctx.root}/WORKFLOW.md",
                  "aggregatedOutput" => Jason.encode!(%{"command_key" => command["command_key"], "payload_sha256" => command["payload_sha256"], "status" => "PENDING"})
                }
              ]
            else
              []
            end

          %{
            "id" => "turn-#{n}",
            "status" => "completed",
            "startedAt" => started,
            "completedAt" => started + 10,
            "items" => [%{"type" => "userMessage", "id" => "item-#{n}", "clientId" => "client-#{n}", "content" => [%{"type" => "text", "text" => body}]}] ++ frame
          }
        end)
    }
  end
end
