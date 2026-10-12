defmodule Mix.Tasks.Factory.Desktop do
  use Mix.Task

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.{ContractChat, DesktopRequest, DesktopToolArgs, NativeSessionDiscovery}
  alias SymphonyElixir.Factory.{DesktopMrHandshake, NativeMaintenanceEvidence}
  alias SymphonyElixir.Factory.NativeWorkspaceMaintenance
  alias SymphonyElixir.Factory.{Policy, Store, TicketChat, TicketMrOperation}
  alias SymphonyElixir.Workflow

  @shortdoc "Exchange durable factory requests with a Codex Desktop broker"

  @moduledoc """
  Exchanges one durable request at a time with the Codex Desktop task broker.

      mix factory.desktop list --workflow /path/to/WORKFLOW.md
      mix factory.desktop maintenance-plan --workflow /path/to/WORKFLOW.md
      mix factory.desktop show REQUEST_KEY --workflow /path/to/WORKFLOW.md
      mix factory.desktop create-thread-args REQUEST_KEY --workflow /path/to/WORKFLOW.md
      mix factory.desktop followup-args REQUEST_KEY --workflow /path/to/WORKFLOW.md
      mix factory.desktop find-thread REQUEST_KEY --source-thread-id BROKER_THREAD_ID --workflow /path/to/WORKFLOW.md
      mix factory.desktop claim REQUEST_KEY --workflow /path/to/WORKFLOW.md
      mix factory.desktop claim-ticket-followup REQUEST_KEY --source-thread-id BROKER_THREAD_ID --payload-base64 OWNER_OBSERVATION --workflow /path/to/WORKFLOW.md
      mix factory.desktop claim-ticket-mr REQUEST_KEY --source-thread-id BROKER_THREAD_ID --payload-base64 GUARD_OBSERVATION --workflow /path/to/WORKFLOW.md
      mix factory.desktop claim-ticket-mr-interactive REQUEST_KEY --source-thread-id BROKER_THREAD_ID --workflow /path/to/WORKFLOW.md
      mix factory.desktop record-thread REQUEST_KEY THREAD_ID VERIFIED_PROJECT_ID --verified-cwd PATH --verified-head-sha SHA --workflow /path/to/WORKFLOW.md
      mix factory.desktop record-ticket-thread REQUEST_KEY --payload-base64 BASE64_JSON --workflow /path/to/WORKFLOW.md
      mix factory.desktop read-ticket-turn REQUEST_KEY THREAD_ID --source-thread-id BROKER_THREAD_ID --include-completion --workflow /path/to/WORKFLOW.md
      mix factory.desktop reconcile-negative-ticket-presentation REQUEST_KEY THREAD_ID --source-thread-id BROKER_THREAD_ID --workflow /path/to/WORKFLOW.md
      mix factory.desktop complete REQUEST_KEY --payload-base64 BASE64_JSON --workflow /path/to/WORKFLOW.md
      mix factory.desktop record-maintenance-evidence REQUEST_KEY --payload-base64 BASE64_JSON --workflow /path/to/WORKFLOW.md
      mix factory.desktop record-user-reply TASK_KEY --payload-base64 BASE64_JSON --workflow /path/to/WORKFLOW.md
      mix factory.desktop fail REQUEST_KEY FAILURE_CODE --workflow /path/to/WORKFLOW.md
      mix factory.desktop fail REQUEST_KEY CREATE_THREAD_INVALID_ARGUMENTS --rejected-tool-call-id ID --tool-error "create_thread received invalid arguments" --workflow /path/to/WORKFLOW.md

  `claim` makes the external operation uncertain before it is issued. Read back
  the native task and its project after creation before `record-thread`; read
  back the completed turn before `complete`. Reconcile an uncertain request
  rather than claiming it again.
  """

  @switches [
    workflow: :string,
    payload_base64: :string,
    verified_cwd: :string,
    verified_head_sha: :string,
    sessions_root: :string,
    source_thread_id: :string,
    include_completion: :boolean,
    rejected_tool_call_id: :string,
    tool_error: :string,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    ensure_dependencies!()
    {opts, action, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] or not valid_action?(action, opts) ->
        Mix.raise("Invalid arguments.\n\n#{@moduledoc}")

      true ->
        run_action(action, opts)
    end
  end

  defp run_action(action, opts) do
    original = Application.fetch_env(:symphony_elixir, :workflow_file_path)
    path = Path.expand(opts[:workflow] || "WORKFLOW.md")

    try do
      Workflow.set_workflow_file_path(path)
      factory = load_factory!(path)
      {:ok, store} = Store.start_link(database: factory.database)
      ticket_policy = if Policy.validate(factory) == :ok, do: factory.ticket_supervisor, else: %{}
      mr_factory = if Policy.validate(factory) == :ok, do: factory, else: nil

      opts =
        opts
        |> Keyword.put(:native_session_discovery_enabled, factory.native_session_discovery_enabled)
        |> Keyword.put(:ticket_policy, ticket_policy)
        |> Keyword.put(:factory, factory)
        |> Keyword.put(:ticket_mr_factory, mr_factory)

      try do
        action
        |> execute_guarded(store, opts)
        |> unwrap!()
        |> Jason.encode!(pretty: true)
        |> Mix.shell().info()
      after
        GenServer.stop(store)
      end
    after
      case original do
        {:ok, previous} -> Workflow.set_workflow_file_path(previous)
        :error -> Workflow.clear_workflow_file_path()
      end
    end
  end

  defp execute_guarded([command, key | _] = action, store, opts)
       when command in ["find-thread", "record-thread", "record-maintenance-evidence", "record-ticket-thread", "read-ticket-turn", "complete", "fail"] do
    case DesktopRequest.get(store, key) do
      {:ok, %{"target_kind" => "TICKET_CHAT"} = request} ->
        execute_ticket_readback(command, action, request, store, opts)

      _ ->
        execute(action, store, opts)
    end
  end

  defp execute_guarded(action, store, opts), do: execute(action, store, opts)

  defp execute_ticket_readback(command, action, request, store, opts) do
    if command in ["find-thread", "record-thread", "record-maintenance-evidence"] or request["status"] == "PENDING" do
      {:error, :ticket_chat_runtime_not_integrated}
    else
      with :ok <- TicketChat.authorize_readback(store, request), do: execute(action, store, opts)
    end
  end

  defp valid_action?(["list"], _opts), do: true
  defp valid_action?(["maintenance-plan"], _opts), do: true
  defp valid_action?(["show", key], _opts), do: key != ""
  defp valid_action?(["create-thread-args", key], _opts), do: key != ""
  defp valid_action?(["followup-args", key], _opts), do: key != ""
  defp valid_action?(["read-ticket-turn", key, thread], opts), do: key != "" and thread != "" and is_binary(opts[:source_thread_id])
  defp valid_action?(["reconcile-negative-ticket-presentation", key, thread], opts), do: key != "" and thread != "" and is_binary(opts[:source_thread_id])
  defp valid_action?(["find-thread", key], _opts), do: key != ""
  defp valid_action?(["claim", key], _opts), do: key != ""
  defp valid_action?(["claim-ticket-followup", key], opts), do: key != "" and is_binary(opts[:source_thread_id]) and is_binary(opts[:payload_base64])
  defp valid_action?(["claim-ticket-mr", key], opts), do: key != "" and is_binary(opts[:source_thread_id]) and is_binary(opts[:payload_base64])
  defp valid_action?(["claim-ticket-mr-interactive", key], opts), do: key != "" and is_binary(opts[:source_thread_id]) and is_nil(opts[:payload_base64])

  defp valid_action?(["record-thread", key, thread_id, project_id], _opts),
    do: key != "" and thread_id != "" and project_id != ""

  defp valid_action?(["complete", key], opts), do: key != "" and is_binary(opts[:payload_base64])
  defp valid_action?(["record-ticket-thread", key], opts), do: key != "" and is_binary(opts[:payload_base64])
  defp valid_action?(["record-maintenance-evidence", key], opts), do: key != "" and is_binary(opts[:payload_base64])
  defp valid_action?(["record-user-reply", key], opts), do: key != "" and is_binary(opts[:payload_base64])
  defp valid_action?(["fail", key, reason], _opts), do: key != "" and reason != ""
  defp valid_action?(_action, _opts), do: false

  defp execute(["list"], store, opts) do
    {:ok,
     %{
       pending: DesktopRequest.list_pending(store, 50, opts),
       reconciliation: DesktopRequest.list_reconciliation(store),
       waiting_for_user: ContractChat.waiting(store)
     }}
  end

  defp execute(["maintenance-plan"], store, _opts) do
    {:ok,
     %{
       capability: "ARCHIVE_RESTORE_NOT_PROVEN",
       authorization: "NOT_REQUESTED",
       candidates: NativeWorkspaceMaintenance.plan(store),
       lifecycle: NativeWorkspaceMaintenance.snapshot(store)
     }}
  end

  defp execute(["show", key], store, _opts), do: DesktopRequest.get(store, key)

  defp execute(["create-thread-args", key], store, opts), do: DesktopToolArgs.create_thread(store, key, opts)
  defp execute(["followup-args", key], store, opts), do: DesktopToolArgs.followup(store, key, opts)

  defp execute(["read-ticket-turn", key, thread], store, opts) do
    read_opts = [include_completion: opts[:include_completion] || false]
    TicketChat.read_native_turn(store, key, thread, opts[:source_thread_id], read_opts)
  end

  defp execute(["reconcile-negative-ticket-presentation", key, thread], store, opts),
    do: DesktopRequest.reconcile_negative_ticket_chat_presentation(store, key, thread, opts[:source_thread_id])

  defp execute(["record-ticket-thread", key], store, opts) do
    case record_proof(opts) do
      {:ok, proof} when is_map(proof) -> DesktopRequest.record_ticket_thread(store, key, proof)
      _ -> {:error, :invalid_workspace_proof}
    end
  end

  defp execute(["find-thread", key], store, opts) do
    if opts[:native_session_discovery_enabled] do
      discovery_opts =
        [source_thread_id: opts[:source_thread_id]] ++
          if(is_binary(opts[:sessions_root]), do: [sessions_root: opts[:sessions_root]], else: [])

      case NativeSessionDiscovery.find_for_request(store, key, discovery_opts) do
        {:ok, candidate} -> {:ok, Map.put(candidate, :proof_level, "CANDIDATE_ONLY")}
        {:error, _reason} = error -> error
      end
    else
      {:error, :native_session_discovery_disabled}
    end
  end

  defp execute(["claim", key], store, opts), do: DesktopRequest.claim(store, key, opts)

  defp execute(["claim-ticket-followup", key], store, opts) do
    case record_proof(opts) do
      {:ok, owner} when is_map(owner) -> TicketChat.claim_followup(store, key, opts[:source_thread_id], owner, opts)
      _ -> {:error, :parent_guard_evidence_invalid}
    end
  end

  defp execute(["claim-ticket-mr", key], store, opts) do
    factory = Keyword.fetch!(opts, :factory)

    with :ok <- Policy.validate(factory),
         true <- factory.ticket_supervisor["enabled"] == true or {:error, :ticket_mr_new_admission_disabled},
         {:ok, guard} <- record_proof(opts),
         true <- guard["source_thread_id"] == opts[:source_thread_id] or {:error, :mr_guard_broker_mismatch} do
      TicketMrOperation.claim_from_jira(store, key, factory, guard, []) |> compact_mr_claim()
    end
  end

  defp execute(["claim-ticket-mr-interactive", key], store, opts) do
    factory = Keyword.fetch!(opts, :factory)
    broker = opts[:source_thread_id]

    with :ok <- Policy.validate(factory),
         true <- factory.ticket_supervisor["enabled"] == true or {:error, :ticket_mr_new_admission_disabled} do
      observe = &DesktopMrHandshake.observe(&1, broker)
      TicketMrOperation.claim_with_owner(store, key, factory, broker, observe, []) |> compact_mr_claim()
    end
  end

  defp execute(["record-thread", key, thread_id, project_id], store, opts) do
    with {:ok, proof} <- record_proof(opts) do
      DesktopRequest.record_thread(store, key, thread_id, project_id, proof)
    end
  end

  defp execute(["complete", key], store, opts) do
    with {:ok, json} <- Base.decode64(opts[:payload_base64]),
         {:ok, %{"thread_id" => thread_id, "turn_id" => turn_id, "output" => output} = payload} <- Jason.decode(json),
         true <- is_binary(thread_id) and thread_id != "" and is_binary(turn_id) and turn_id != "" and is_map(output) do
      DesktopRequest.complete(store, key, Map.take(payload, ~w(thread_id turn_id output artifact_output source_execution)))
    else
      :error -> {:error, :invalid_base64_payload}
      false -> {:error, :incomplete_completion_payload}
      {:ok, _other} -> {:error, :incomplete_completion_payload}
      {:error, reason} -> {:error, {:invalid_completion_payload, reason}}
    end
  end

  defp execute(["record-maintenance-evidence", key], store, opts) do
    with {:ok, json} <- Base.decode64(opts[:payload_base64]),
         {:ok, payload} when is_map(payload) <- Jason.decode(json) do
      NativeMaintenanceEvidence.record(store, key, payload)
    else
      :error -> {:error, :invalid_base64_payload}
      {:ok, _other} -> {:error, :invalid_maintenance_evidence}
      {:error, reason} -> {:error, {:invalid_maintenance_payload, reason}}
    end
  end

  defp execute(["record-user-reply", key], store, opts) do
    with {:ok, json} <- Base.decode64(opts[:payload_base64]),
         {:ok, %{"thread_id" => _, "codex_project_id" => _, "question_turn_id" => _, "user_turn_id" => _, "user_message_id" => _, "text" => _} = payload} <- Jason.decode(json) do
      ContractChat.record_user_reply(store, key, payload)
    else
      :error -> {:error, :invalid_base64_payload}
      {:ok, _other} -> {:error, :incomplete_user_reply_payload}
      {:error, reason} -> {:error, {:invalid_user_reply_payload, reason}}
    end
  end

  defp execute(["fail", key, reason], store, opts) do
    evidence =
      opts
      |> Keyword.take([:rejected_tool_call_id, :tool_error])

    DesktopRequest.fail(store, key, reason, evidence)
  end

  defp load_factory!(workflow_path) do
    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, settings} <- Schema.parse(workflow.config),
         database when is_binary(database) <- settings.factory.database do
      settings.factory
    else
      reason -> Mix.raise("Unable to resolve factory configuration: #{inspect(reason)}")
    end
  end

  defp compact_mr_claim({:ok, %{request: request, arguments: arguments}}) do
    {:ok, %{request_key: request["request_key"], status: request["status"], arguments: arguments}}
  end

  defp compact_mr_claim(error), do: error

  defp record_proof(opts) do
    if is_binary(opts[:payload_base64]) do
      with {:ok, json} <- Base.decode64(opts[:payload_base64]),
           {:ok, proof} when is_map(proof) <- Jason.decode(json) do
        {:ok, proof}
      else
        _other -> {:error, :invalid_workspace_proof}
      end
    else
      proof =
        if is_binary(opts[:verified_cwd]) or is_binary(opts[:verified_head_sha]) do
          %{cwd: opts[:verified_cwd], head_sha: opts[:verified_head_sha]}
        end

      {:ok, proof}
    end
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Mix.raise("Desktop request failed: #{inspect(reason)}")

  defp ensure_dependencies! do
    case Application.ensure_all_started(:exqlite) do
      {:ok, _applications} -> :ok
      {:error, reason} -> Mix.raise("Unable to start factory dependencies: #{inspect(reason)}")
    end
  end
end
