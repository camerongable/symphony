defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}
  alias SymphonyElixir.Codex.{OutputSchema, ResumeRefusal}
  alias SymphonyElixir.Factory.WorkerFileTools
  alias SymphonyElixir.Factory.NativeRuntimeRoute

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @thread_name_set_id 4
  @thread_fork_id 5
  @thread_unsubscribe_id 6
  @thread_metadata_update_id 7
  @thread_section_move_id 8
  @thread_read_id 9
  @native_read_deadline_key {__MODULE__, :native_read_deadline}
  @thread_archive_id 10
  @apps_installed_id 11
  @project_list_id 12
  @thread_list_id 13
  @mcp_tool_call_id 14
  @worker_config_id 15
  @worker_catalog_id 16
  @worker_account_id 17
  @controller_catalog_id 18
  @native_turn_list_id 19
  @native_queue_list_id 20
  @owned_exit_key {__MODULE__, :owned_exit}
  @thread_list_page_size 100
  @thread_list_max_records 10_000
  @thread_list_source_kinds ~w(cli vscode exec appServer subAgent subAgentReview subAgentCompact subAgentThreadSpawn subAgentOther unknown)
  @thread_unsubscribe_timeout_ms 1_000
  @port_line_bytes 1_048_576
  @ticket_worker_runtime_versions ~w(0.160.0 0.162.0-alpha.2 0.162.0-alpha.17.2 0.163.0-alpha.10.2 0.163.0-alpha.11 0.163.0-alpha.11.1 0.163.0-alpha.11.2 0.164.0-alpha.11.1 0.165.0-alpha.1.2)
  @max_stream_log_bytes 1_000
  @mcp_startup_statuses_key {__MODULE__, :mcp_startup_statuses}
  @mcp_approval_state_key {__MODULE__, :mcp_approval_state}
  @turn_event_state_key {__MODULE__, :turn_event_state}
  @type native_reader :: %{
          required(:owner) => pid(),
          required(:port) => port(),
          required(:app_server_pid) => String.t(),
          required(:cwd) => Path.t(),
          required(:identity) => reference(),
          required(:native_runtime) => NativeRuntimeRoute.t() | nil,
          optional(:native_runtime_origin) => map()
        }
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          allowed_mcp_tool_approvals: list(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          forked_from_thread_id: String.t() | nil,
          thread_name: String.t() | nil,
          project_id: String.t() | nil,
          section_id: String.t() | nil,
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          worker_policy: map() | nil,
          worker_files: map() | nil,
          native_recovery: map() | nil,
          recovery_preflight: (map() -> :ok | {:error, term()}) | nil,
          worker_invocation: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @doc "Calls one configured MCP tool from an ephemeral app-server thread without accepting interactive approvals."
  @spec call_mcp_tool(Path.t(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_mcp_tool(workspace, server, tool, arguments, opts \\ [])
      when is_binary(server) and is_binary(tool) and is_map(arguments) do
    with {:ok, session} <-
           start_session(workspace,
             ephemeral: true,
             required_mcp_servers: [server],
             mcp_startup_timeout_ms: Keyword.get(opts, :mcp_startup_timeout_ms, 60_000),
             service_name: "symphony-factory-connector",
             thread_source: "symphonyFactoryConnector"
           ) do
      try do
        call_mcp_tool_in_session(session, server, tool, arguments)
      after
        stop_session(session)
      end
    end
  end

  @doc "Owns a short-lived GitLab connector transport without starting a model turn."
  @spec with_gitlab_read_session(Path.t(), (session() -> term())) :: term()
  def with_gitlab_read_session(workspace, operation) when is_function(operation, 1) do
    with {:ok, session} <-
           start_session(workspace,
             ephemeral: true,
             required_mcp_servers: ["GitLab"],
             mcp_startup_timeout_ms: 60_000,
             gitlab_mcp_startup_timeout_sec: 45,
             service_name: "symphony-factory-connector",
             thread_source: "symphonyFactoryConnector"
           ) do
      try do
        operation.(session)
      after
        stop_session(session)
      end
    end
  end

  @doc "Owns a bounded Jira controller connector without starting a model turn."
  @spec with_jira_controller_session(Path.t(), (session() -> term())) :: term()
  def with_jira_controller_session(workspace, operation) when is_function(operation, 1) do
    with {:ok, session} <-
           start_session(workspace,
             ephemeral: true,
             required_mcp_servers: ["Jira"],
             factory_jira_controller: true,
             mcp_startup_timeout_ms: 60_000,
             service_name: "symphony-factory-connector",
             thread_source: "symphonyFactoryConnector"
           ) do
      try do
        operation.(session)
      after
        stop_session(session)
      end
    end
  end

  @doc "Calls a configured MCP tool on an already-open, caller-owned session."
  @spec call_mcp_tool_in_session(session(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_mcp_tool_in_session(%{port: port, thread_id: thread_id}, server, tool, arguments)
      when is_binary(server) and is_binary(tool) and is_map(arguments) do
    send_message(port, %{
      "method" => "mcpServer/tool/call",
      "id" => @mcp_tool_call_id,
      "params" => %{
        "server" => server,
        "tool" => tool,
        "arguments" => arguments,
        "threadId" => thread_id
      }
    })

    deadline_ms = System.monotonic_time(:millisecond) + Config.settings!().codex.read_timeout_ms
    await_mcp_tool_response(port, deadline_ms, "")
  end

  @doc "Reads advertised schemas on a caller-owned controller session; does not execute a tool or attest API results."
  @spec mcp_tool_catalog_in_session(session(), String.t()) :: {:ok, map()} | {:error, term()}
  def mcp_tool_catalog_in_session(%{worker_policy: policy}, _server) when not is_nil(policy), do: {:error, :worker_connector_catalog_forbidden}

  def mcp_tool_catalog_in_session(%{port: port, thread_id: thread_id, worker_policy: nil}, server)
      when is_port(port) and is_binary(thread_id) and byte_size(thread_id) in 1..256 and
             is_binary(server) and byte_size(server) in 1..256 do
    cond do
      Process.get(@turn_event_state_key) != nil -> {:error, :mcp_catalog_session_busy}
      :erlang.port_info(port, :connected) != {:connected, self()} -> {:error, :mcp_catalog_session_not_owned}
      true -> read_controller_catalog(port, thread_id, server)
    end
  end

  def mcp_tool_catalog_in_session(_session, _server), do: {:error, :invalid_mcp_catalog_session}

  defp read_controller_catalog(port, thread_id, server) do
    previous_deadline = Process.get(@native_read_deadline_key)
    deadline = System.monotonic_time(:millisecond) + 20_000
    Process.put(@native_read_deadline_key, if(is_integer(previous_deadline), do: min(deadline, previous_deadline), else: deadline))

    try do
      send_message(port, %{
        "method" => "mcpServerStatus/list",
        "id" => @controller_catalog_id,
        "params" => %{"threadId" => thread_id, "serverName" => server, "detail" => "toolsAndAuthOnly", "limit" => 1}
      })

      case await_response(port, @controller_catalog_id) do
        {:ok, %{"data" => [%{"name" => ^server, "toolsError" => nil, "tools" => tools}], "nextCursor" => nil}}
        when is_map(tools) and map_size(tools) > 0 ->
          if Enum.all?(tools, &catalog_tool?/1), do: {:ok, tools}, else: {:error, :mcp_tool_catalog_invalid}

        {:ok, _} ->
          {:error, :mcp_tool_catalog_unavailable}

        {:error, _} = error ->
          error
      end
    after
      if is_nil(previous_deadline), do: Process.delete(@native_read_deadline_key), else: Process.put(@native_read_deadline_key, previous_deadline)
    end
  end

  defp catalog_tool?({name, %{"name" => name, "inputSchema" => %{"type" => "object"}}}) when is_binary(name) and byte_size(name) in 1..256, do: true
  defp catalog_tool?(_tool), do: false

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    thread_options = %{
      mcp_startup_timeout_ms: Keyword.get(opts, :mcp_startup_timeout_ms, 60_000),
      gitlab_mcp_startup_timeout_sec: Keyword.get(opts, :gitlab_mcp_startup_timeout_sec),
      approval_policy: Keyword.get(opts, :approval_policy),
      allowed_mcp_tool_approvals: Keyword.get(opts, :allowed_mcp_tool_approvals, []),
      fork_on_active_writer: Keyword.get(opts, :fork_on_active_writer, false),
      ephemeral: Keyword.get(opts, :ephemeral, false),
      model: Keyword.get(opts, :model),
      name: normalize_thread_name(Keyword.get(opts, :thread_name)),
      on_thread_created: Keyword.get(opts, :on_thread_created),
      project_id: normalize_project_id(Keyword.get(opts, :project_id)),
      project_root: normalize_project_root(Keyword.get(opts, :project_root)),
      section_id: normalize_section_id(Keyword.get(opts, :section_id)),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      required_apps: normalize_required_apps(Keyword.get(opts, :required_apps, [])),
      required_mcp_servers: normalize_required_mcp_servers(Keyword.get(opts, :required_mcp_servers, [])),
      resume_thread_id: Keyword.get(opts, :resume_thread_id),
      service_name: Keyword.get(opts, :service_name, "symphony-orchestrator"),
      thread_source: Keyword.get(opts, :thread_source, "symphony"),
      worker_access: Keyword.get(opts, :worker_access),
      worker_files: Keyword.get(opts, :worker_files),
      native_recovery: Keyword.get(opts, :native_recovery),
      recovery_preflight: Keyword.get(opts, :recovery_preflight),
      native_runtime: nil,
      worker_policy: nil,
      worker_overrides: []
    }

    Process.put(@mcp_startup_statuses_key, %{})

    try do
      binding = DynamicTool.bind()

      with {:ok, connector_overrides} <- factory_connector_overrides(opts, worker_host),
           {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
           {:ok, thread_options} <- worker_runtime_route(expanded_workspace, worker_host, opts, thread_options),
           {:ok, thread_options, binding} <- prepare_worker(expanded_workspace, worker_host, thread_options, binding),
           {:ok, storage} <- worker_storage(expanded_workspace, thread_options),
           {:ok, port} <-
             start_port(
               expanded_workspace,
               worker_host,
               binding,
               thread_options.gitlab_mcp_startup_timeout_sec,
               thread_options.worker_overrides ++ storage.overrides,
               connector_overrides,
               storage.env
             ) do
        metadata = port_metadata(port, worker_host)

        try do
          with {:ok, configured_policies} <- session_policies(expanded_workspace, worker_host),
               {:ok, session_policies} <- worker_session_policies(configured_policies, thread_options),
               {:ok, thread_ref} <-
                 do_start_session(
                   port,
                   expanded_workspace,
                   session_policies,
                   binding,
                   thread_options
                 ) do
            session = %{
              port: port,
              metadata: metadata,
              approval_policy: session_policies.approval_policy,
              auto_approve_requests: false,
              allowed_mcp_tool_approvals: thread_options.allowed_mcp_tool_approvals,
              thread_sandbox: session_policies.thread_sandbox,
              turn_sandbox_policy: session_policies.turn_sandbox_policy,
              thread_id: thread_ref.thread_id,
              forked_from_thread_id: thread_ref.forked_from_thread_id,
              thread_name: thread_options.name,
              project_id: thread_ref.project_id,
              section_id: thread_options.section_id,
              model: thread_options.model,
              reasoning_effort: thread_options.reasoning_effort,
              worker_policy: thread_options.worker_policy,
              worker_files: thread_options.worker_files,
              native_recovery: thread_options.native_recovery,
              recovery_preflight: thread_options.recovery_preflight,
              worker_invocation: worker_invocation(thread_options.worker_policy),
              workspace: expanded_workspace,
              worker_host: worker_host,
              dynamic_tool_binding: binding
            }

            finish_worker_session(session, thread_options)
          else
            {:error, reason} ->
              stop_port(port)
              {:error, reason}
          end
        catch
          kind, reason ->
            stop_port(port)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end
    after
      Process.delete(@mcp_startup_statuses_key)
    end
  end

  defp worker_invocation(nil), do: nil
  defp worker_invocation(_policy), do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp worker_runtime_route(workspace, host, opts, options) do
    if Keyword.has_key?(opts, :native_runtime) do
      with true <- is_nil(host) or {:error, :native_runtime_remote_unsupported},
           true <- options.worker_access in ~w(FILE_SOURCE REVIEW) or {:error, :native_runtime_worker_required},
           true <- match?(%NativeRuntimeRoute{}, opts[:native_runtime]) or {:error, :native_runtime_route_invalid},
           {:ok, route} <- NativeRuntimeRoute.validate(opts[:native_runtime]),
           {:ok, _storage} <- reader_storage(route, workspace) do
        {:ok, %{options | native_runtime: route}}
      end
    else
      {:ok, options}
    end
  end

  defp worker_storage(_workspace, %{native_runtime: nil}), do: {:ok, %{env: [], overrides: []}}
  defp worker_storage(workspace, %{native_runtime: route}), do: reader_storage(route, workspace)

  defp finish_worker_session(session, %{native_runtime: nil}), do: {:ok, session}

  defp finish_worker_session(session, %{native_runtime: route}) do
    with {:ok, origin} <- NativeRuntimeRoute.origin(route) do
      session = Map.merge(session, %{native_runtime: route, native_runtime_origin: origin})
      Process.put({__MODULE__, :routed_session, session.port}, session)
      {:ok, session}
    else
      error ->
        stop_port(session.port)
        error
    end
  end

  defp routed_session_access(session, current? \\ true)

  defp routed_session_access(%{port: port} = session, current?) when is_port(port) do
    binding = Process.get({__MODULE__, :routed_session, port})
    connected = Port.info(port, :connected)

    cond do
      is_map(binding) ->
        with true <- binding === session or {:error, :native_runtime_session_not_owned},
             true <- connected == {:connected, self()} or (not current? and is_nil(connected)) or {:error, :native_runtime_session_not_owned},
             true <- is_nil(connected) or port_metadata(port, nil)[:codex_app_server_pid] == session.metadata[:codex_app_server_pid] or {:error, :native_runtime_session_not_owned} do
          if current? do
            case reader_storage(binding.native_runtime, binding.workspace) do
              {:ok, _storage} -> :ok
              error -> error
            end
          else
            :ok
          end
        end

      Map.has_key?(session, :native_runtime) or Map.has_key?(session, :native_runtime_origin) ->
        {:error, :native_runtime_session_not_owned}

      match?({:connected, owner} when owner != self(), connected) ->
        {:error, :file_worker_session_not_owned}

      true ->
        :ok
    end
  end

  defp routed_session_access(session, _current?) do
    if is_map(session) and (Map.has_key?(session, :native_runtime) or Map.has_key?(session, :native_runtime_origin)),
      do: {:error, :native_runtime_session_not_owned},
      else: :ok
  end

  def run_turn(session, prompt, issue, opts \\ [])

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{worker_policy: %{"mode" => "SOURCE"}}, _prompt, _issue, _opts),
    do: {:error, :worker_source_containment_unproven}

  def run_turn(%{worker_policy: %{"mode" => "FILE_SOURCE"}} = session, prompt, issue, opts) do
    with :ok <- WorkerFileTools.turn_preflight(session[:worker_files], session),
         :ok <- routed_session_access(session),
         :ok <- file_worker_session_owned(session),
         :ok <- file_worker_runtime(session.port, session.workspace),
         :ok <- worker_catalog_empty(session.port, session),
         :ok <- recovery_turn_preflight(session),
         :ok <- routed_session_access(session) do
      run_allowed_turn(session, prompt, issue, opts)
    end
  end

  def run_turn(session, prompt, issue, opts) do
    with :ok <- routed_session_access(session), :ok <- recovery_turn_preflight(session), :ok <- routed_session_access(session), do: run_allowed_turn(session, prompt, issue, opts)
  end

  defp recovery_turn_preflight(%{native_recovery: proof, recovery_preflight: callback} = session) when is_map(proof) and is_function(callback, 1), do: callback.(session)
  defp recovery_turn_preflight(%{native_recovery: proof}) when is_map(proof), do: {:error, :native_recovery_guard_missing}
  defp recovery_turn_preflight(_session), do: :ok

  defp run_allowed_turn(
         %{
           port: port,
           metadata: metadata,
           approval_policy: approval_policy,
           auto_approve_requests: auto_approve_requests,
           allowed_mcp_tool_approvals: allowed_mcp_tool_approvals,
           turn_sandbox_policy: turn_sandbox_policy,
           thread_id: thread_id,
           model: model,
           reasoning_effort: reasoning_effort,
           thread_name: thread_name,
           workspace: workspace,
           dynamic_tool_binding: dynamic_tool_binding
         } = session,
         prompt,
         issue,
         opts
       ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    event_scope = Keyword.get(opts, :event_scope, :legacy)
    if event_scope not in [:legacy, :exact_turn], do: raise(ArgumentError, "unsupported event_scope: #{inspect(event_scope)}")

    tool_executor = turn_tool_executor(session, dynamic_tool_binding, issue, opts)

    Process.put(@mcp_approval_state_key, %{
      items: %{},
      allowed: allowed_mcp_tool_approvals,
      expected_issue_key: Map.get(issue, :identifier)
    })

    Process.put(@turn_event_state_key, %{scope: event_scope, identity: nil, early: [], bytes: 0})

    if event_scope == :exact_turn do
      Process.put(@turn_event_state_key, %{
        scope: event_scope,
        identity: nil,
        early: [],
        bytes: 0,
        deadline: System.monotonic_time(:millisecond) + Config.settings!().codex.turn_timeout_ms
      })
    end

    Process.put({__MODULE__, :file_tool_turn}, get_in(session, [:worker_policy, "mode"]) == "FILE_SOURCE")

    try do
      case start_turn(
             port,
             thread_id,
             prompt,
             issue,
             %{
               workspace: workspace,
               approval_policy: approval_policy,
               sandbox_policy: turn_sandbox_policy,
               model: model,
               reasoning_effort: reasoning_effort,
               output_schema: Keyword.get(opts, :output_schema),
               worker_policy: Map.get(session, :worker_policy),
               request_id: turn_start_request_id(event_scope)
             }
           ) do
        {:ok, turn_id} ->
          state = Process.get(@turn_event_state_key)
          Process.put(@turn_event_state_key, %{state | identity: {thread_id, turn_id}})
          session_id = "#{thread_id}-#{turn_id}"
          Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

          emit_message(
            on_message,
            :session_started,
            %{
              session_id: session_id,
              thread_id: thread_id,
              turn_id: turn_id
            },
            metadata
          )

          case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
            {:ok, result} ->
              reassert_thread_name(port, thread_id, thread_name)
              Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

              {:ok,
               %{
                 result: result,
                 session_id: session_id,
                 thread_id: thread_id,
                 turn_id: turn_id
               }}

            {:error, reason} ->
              reassert_thread_name(port, thread_id, thread_name)
              Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

              emit_message(
                on_message,
                :turn_ended_with_error,
                %{
                  session_id: session_id,
                  reason: reason
                },
                metadata
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
          emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
          {:error, reason}
      end
    after
      Process.delete(@mcp_approval_state_key)
      Process.delete(@turn_event_state_key)
      Process.delete({__MODULE__, :file_tool_turn})
    end
  end

  defp turn_tool_executor(%{worker_policy: %{"mode" => "FILE_SOURCE"}} = session, _binding, _issue, _opts),
    do: fn tool, arguments, identity -> WorkerFileTools.execute(session.worker_files, tool, arguments, identity) end

  defp turn_tool_executor(%{worker_policy: %{}}, _binding, _issue, _opts),
    do: fn _tool, _arguments -> %{success: false, error: "Factory workers cannot call controller connectors"} end

  defp turn_tool_executor(_session, binding, issue, opts),
    do: Keyword.get(opts, :tool_executor, fn tool, arguments -> DynamicTool.execute(tool, arguments, binding, issue: issue) end)

  defp turn_start_request_id(:exact_turn),
    do: "turn-start-#{System.unique_integer([:positive, :monotonic])}"

  defp turn_start_request_id(:legacy), do: @turn_start_id

  @spec stop_session(session()) :: :ok | {:ok, map()} | {:error, term()}
  def stop_session(session) do
    with :ok <- routed_session_access(session, false) do
      try do
        stop_valid_session(session)
      after
        if is_map(session) and is_port(session[:port]) and Process.get({__MODULE__, :routed_session, session.port}) === session,
          do: Process.delete({__MODULE__, :routed_session, session.port})
      end
    end
  end

  defp stop_valid_session(%{worker_policy: %{} = policy, port: port, thread_id: thread, metadata: metadata} = session) do
    Process.unlink(port)

    try do
      maybe_unsubscribe_owned(port, thread)

      with {:ok, status} <- stop_owned_worker(port, metadata[:codex_app_server_pid]) do
        {:ok,
         %{
           "transport" => "owned_app_server",
           "thread_id" => thread,
           "pid" => metadata[:codex_app_server_pid],
           "invocation_nonce" => session.worker_invocation,
           "exit_status" => status,
           "cwd" => policy["cwd"]
         }}
      end
    after
      stop_port(port)
    end
  end

  defp stop_valid_session(%{port: port, thread_id: thread_id}) when is_port(port) do
    Process.unlink(port)

    try do
      unsubscribe_thread(port, thread_id)
    after
      stop_port(port)
    end
  end

  defp stop_owned_worker(port, pid) do
    case Process.get({@owned_exit_key, port}) do
      nil -> receive_owned_exit(port, pid)
      status -> {:ok, status}
    end
  end

  defp maybe_unsubscribe_owned(port, thread) do
    if :erlang.port_info(port) != :undefined, do: unsubscribe_thread(port, thread)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp receive_owned_exit(port, pid) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      0 -> signal_owned_worker(port, pid)
    end
  end

  defp signal_owned_worker(port, pid) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, actual} when is_binary(pid) ->
        if to_string(actual) == pid do
          signal_and_wait(port, pid)
        else
          {:error, :worker_shutdown_identity_mismatch}
        end

      _ ->
        {:error, :worker_shutdown_unproven}
    end
  end

  defp signal_and_wait(port, pid) do
    case System.cmd("/bin/kill", ["-TERM", pid], stderr_to_stdout: true) do
      {_output, 0} -> await_owned_worker_exit(port, System.monotonic_time(:millisecond) + 5_000)
      _ -> {:error, :worker_shutdown_unproven}
    end
  end

  defp await_owned_worker_exit(port, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
      {^port, {:data, _}} -> await_owned_worker_exit(port, deadline)
    after
      remaining -> {:error, :worker_shutdown_unproven}
    end
  end

  @doc "Archives a superseded durable task through the active app-server session."
  @spec archive_thread(session(), String.t()) :: :ok | {:error, term()}
  def archive_thread(%{port: port}, thread_id) when is_port(port) and is_binary(thread_id) do
    send_message(port, %{
      "method" => "thread/archive",
      "id" => @thread_archive_id,
      "params" => %{"threadId" => thread_id}
    })

    case await_response(port, @thread_archive_id) do
      {:ok, _response} -> :ok
      other -> other
    end
  end

  @doc "Finds one stored task by exact title and project without resuming it; an unassigned match needs external project readback."
  @spec find_thread_by_title(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:candidate, map()} | {:error, term()}
  def find_thread_by_title(title, project_id, opts \\ []) do
    with name when is_binary(name) <- normalize_thread_name(title),
         project when is_binary(project) <- normalize_project_id(project_id) do
      workspace = Keyword.get(opts, :workspace, File.cwd!())
      worker_host = Keyword.get(opts, :worker_host)
      dynamic_tool_binding = DynamicTool.bind()

      with {:ok, port} <- start_port(workspace, worker_host, dynamic_tool_binding) do
        Process.unlink(port)

        try do
          with :ok <- send_initialize(port),
               {:ok, active} <- list_threads_by_title(port, name, false),
               {:ok, archived} <- list_threads_by_title(port, name, true) do
            resolve_exact_thread(active ++ archived, project)
          end
        after
          stop_port(port)
        end
      end
    else
      nil -> {:error, :invalid_thread_lookup}
    end
  end

  defp list_threads_by_title(port, title, archived) do
    list_threads_by_title(port, title, archived, nil, [], [], 0)
  end

  @doc "Reads persisted native history without loading, resuming, or starting a model turn."
  def read_native_thread(thread_id, opts \\ [])

  @spec read_native_thread(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_native_thread(thread_id, opts) when is_binary(thread_id) and byte_size(thread_id) in 1..256 do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    native_read_scope(20_000, fn ->
      with {:ok, reader} <- open_native_reader_actor(workspace, false, opts) do
        try do
          read_native_thread(reader, thread_id, opts)
        after
          close_native_reader(reader)
        end
      end
    end)
  end

  def read_native_thread(_thread_id, _opts), do: {:error, :invalid_native_thread_id}

  @doc "Initializes a linked read-only actor; owner exit closes it without changing the caller's exit flags."
  @spec open_native_reader(Path.t()) :: {:ok, native_reader()} | {:error, term()}
  def open_native_reader(workspace), do: open_native_reader_actor(workspace, true, [])

  @spec open_native_reader(Path.t(), keyword()) :: {:ok, native_reader()} | {:error, term()}
  def open_native_reader(workspace, opts) when is_list(opts), do: open_native_reader_actor(workspace, true, opts)

  defp open_native_reader_actor(workspace, linked?, opts) when is_binary(workspace) do
    with {:ok, cwd} <- PathSafety.canonicalize(Path.expand(workspace)),
         true <- File.dir?(cwd) or {:error, :native_reader_cwd_invalid},
         {:ok, route, storage} <- native_reader_route(cwd, opts),
         {:ok, port} <- start_port(cwd, nil, DynamicTool.bind(), nil, [], storage.overrides, storage.env) do
      if not linked?, do: Process.unlink(port)

      reader = %{
        owner: self(),
        port: port,
        app_server_pid: port_metadata(port, nil)[:codex_app_server_pid],
        cwd: cwd,
        identity: make_ref(),
        native_runtime: route
      }

      Process.put({__MODULE__, :native_reader, port}, reader)

      try do
        with :ok <- native_read_scope(20_000, fn -> initialize_native_reader(port, storage) end),
             {:ok, attested_reader} <- attest_native_reader(reader) do
          Process.put({__MODULE__, :native_reader, port}, attested_reader)
          {:ok, attested_reader}
        else
          error ->
            close_native_reader(reader)
            error
        end
      rescue
        error ->
          close_native_reader(reader)
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          close_native_reader(reader)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp open_native_reader_actor(_workspace, _linked?, _opts), do: {:error, :native_reader_cwd_invalid}

  defp native_reader_route(cwd, opts) do
    if Keyword.has_key?(opts, :native_runtime) do
      with true <- is_nil(opts[:worker_host]) or {:error, :native_runtime_remote_unsupported},
           {:ok, route} <- NativeRuntimeRoute.validate(opts[:native_runtime]),
           {:ok, storage} <- reader_storage(route, cwd) do
        {:ok, route, storage}
      end
    else
      {:ok, nil, %{env: [], overrides: []}}
    end
  end

  defp reader_storage(route, cwd) do
    with {:ok, storage} <- NativeRuntimeRoute.storage(route),
         false <- Enum.any?([storage.codex_home, storage.sqlite_home], &reader_path_overlap?(&1, cwd)) do
      {:ok, storage}
    else
      true -> {:error, :native_runtime_storage_unsafe}
      {:error, _} = error -> error
    end
  end

  defp reader_path_overlap?(left, right), do: left == right or left == "/" or right == "/" or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")

  defp initialize_native_reader(port, %{codex_home: home, sqlite_home: sqlite}) do
    with {:ok, response} <- initialization_response(port),
         true <- (is_map(response) and response["codexHome"] == home) or {:error, :native_runtime_home_mismatch} do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      send_message(port, %{"method" => "config/read", "id" => @worker_config_id, "params" => %{"includeLayers" => false}})

      case await_response(port, @worker_config_id) do
        {:ok, %{"config" => %{"sqlite_home" => ^sqlite}}} -> :ok
        {:ok, _} -> {:error, :native_runtime_sqlite_mismatch}
        error -> error
      end
    end
  end

  defp initialize_native_reader(port, _storage), do: send_initialize(port)

  defp attest_native_reader(%{native_runtime: nil} = reader), do: {:ok, reader}

  defp attest_native_reader(reader) do
    with {:ok, origin} <- NativeRuntimeRoute.origin(reader.native_runtime) do
      {:ok, Map.put(reader, :native_runtime_origin, origin)}
    end
  end

  defp native_reader_route_current(reader, opts) do
    route = reader.native_runtime

    with :ok <- matching_reader_route(route, opts) do
      if is_nil(route) do
        :ok
      else
        case reader_storage(route, reader.cwd) do
          {:ok, _storage} -> :ok
          error -> error
        end
      end
    end
  end

  defp matching_reader_route(route, opts) do
    cond do
      not is_nil(route) and not is_nil(opts[:worker_host]) ->
        {:error, :native_runtime_remote_unsupported}

      Keyword.has_key?(opts, :native_runtime) ->
        with true <- not is_nil(route) or {:error, :native_runtime_route_conflict},
             {:ok, supplied} <- NativeRuntimeRoute.validate(opts[:native_runtime]),
             true <- supplied === route or {:error, :native_runtime_route_conflict} do
          :ok
        end

      true ->
        :ok
    end
  end

  @doc "Collects fresh persisted history on the same initialized owned reader."
  @spec read_native_thread(native_reader(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_native_thread(reader, thread_id, opts) when is_binary(thread_id) and byte_size(thread_id) in 1..256 do
    timeout = Keyword.get(opts, :timeout_ms, 20_000)

    with :ok <- native_reader_owned(reader),
         :ok <- native_reader_route_current(reader, opts),
         true <- (is_integer(timeout) and timeout > 0) or {:error, :native_read_deadline_expired} do
      native_read_scope(min(timeout, 20_000), fn -> collect_native_thread(reader.port, thread_id, opts) end)
    end
  end

  def read_native_thread(_reader, _thread_id, _opts), do: {:error, :invalid_native_thread_id}

  @doc "Exports storage provenance only from the same successfully attested owned reader."
  @spec native_reader_origin(native_reader()) :: {:ok, map()} | {:error, term()}
  def native_reader_origin(reader) do
    with :ok <- native_reader_owned(reader),
         {:ok, origin} <- Map.fetch(reader, :native_runtime_origin),
         :ok <- native_reader_route_current(reader, []),
         {:ok, current} <- NativeRuntimeRoute.origin(reader.native_runtime),
         true <- current === origin or {:error, :native_runtime_origin_mismatch} do
      {:ok, origin}
    else
      :error -> {:error, :native_runtime_origin_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Closes only this process's native reader; repeated owned dead-reader cleanup is harmless."
  @spec close_native_reader(native_reader()) :: :ok | {:error, term()}
  def close_native_reader(%{owner: owner, port: port} = reader) when owner == self() and is_port(port) do
    binding = Process.get({__MODULE__, :native_reader, port})

    cond do
      is_nil(Port.info(port)) and binding in [nil, reader] ->
        Process.delete({__MODULE__, :native_reader, port})
        drain_native_reader(port)

      native_reader_owned(reader, false) == :ok ->
        stop_port(port)
        Process.delete({__MODULE__, :native_reader, port})
        drain_native_reader(port)

      true ->
        {:error, :native_reader_not_owned}
    end
  end

  def close_native_reader(_reader), do: {:error, :native_reader_not_owned}

  defp native_reader_owned(reader, check_cwd? \\ true)

  defp native_reader_owned(%{owner: owner, port: port, app_server_pid: pid, cwd: cwd} = reader, check_cwd?) when owner == self() and is_port(port) do
    with true <- Process.get({__MODULE__, :native_reader, port}) === reader,
         {:connected, ^owner} <- Port.info(port, :connected),
         {:os_pid, actual} <- Port.info(port, :os_pid),
         true <- to_string(actual) == pid,
         true <- not check_cwd? or PathSafety.canonicalize(cwd) == {:ok, cwd} do
      :ok
    else
      _ -> {:error, :native_reader_not_owned}
    end
  end

  defp native_reader_owned(_reader, _check_cwd?), do: {:error, :native_reader_not_owned}

  defp drain_native_reader(port) do
    receive do
      {^port, _} -> drain_native_reader(port)
      {:EXIT, ^port, _} -> drain_native_reader(port)
    after
      0 -> :ok
    end
  end

  defp native_read_scope(timeout, callback) do
    previous = Process.get(@native_read_deadline_key)
    deadline = System.monotonic_time(:millisecond) + timeout
    Process.put(@native_read_deadline_key, if(is_integer(previous), do: min(previous, deadline), else: deadline))

    try do
      callback.()
    after
      if is_nil(previous), do: Process.delete(@native_read_deadline_key), else: Process.put(@native_read_deadline_key, previous)
    end
  end

  defp collect_native_thread(port, thread_id, opts) do
    include_turns = Keyword.get(opts, :include_turns, true)
    send_message(port, %{"method" => "thread/read", "id" => @thread_read_id, "params" => %{"threadId" => thread_id, "includeTurns" => include_turns}})

    case await_response(port, @thread_read_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id} = thread}} ->
        with true <- not include_turns or is_list(thread["turns"]) or {:error, :native_read_identity_or_history_mismatch},
             {:ok, observed} <- maybe_read_complete_history(port, thread, opts),
             {:ok, observed} <- maybe_read_latest_turn(port, observed, opts),
             {:ok, observed} <- maybe_read_native_queue(port, observed, opts) do
          recheck_latest_queue_version(port, observed, opts)
        end

      {:ok, _} ->
        {:error, :native_read_identity_or_history_mismatch}

      error ->
        error
    end
  end

  @doc "Reads latest-turn and queue evidence using the worker's existing owned native actor."
  @spec read_owned_native_thread(session()) :: {:ok, map()} | {:error, term()}
  def read_owned_native_thread(%{port: port, thread_id: thread} = session) do
    with :ok <- routed_session_access(session),
         :ok <- file_worker_session_owned(session),
         true <- is_nil(Process.get(@turn_event_state_key)) or {:error, :native_recovery_session_busy} do
      Process.put(@native_read_deadline_key, System.monotonic_time(:millisecond) + 20_000)

      try do
        send_message(port, %{"method" => "thread/read", "id" => @thread_read_id, "params" => %{"threadId" => thread, "includeTurns" => false}})
        opts = [include_latest_turn: true, include_queue: true]

        with {:ok, %{"thread" => %{"id" => ^thread} = observed}} <- await_response(port, @thread_read_id),
             {:ok, observed} <- maybe_read_latest_turn(port, observed, opts),
             {:ok, observed} <- maybe_read_native_queue(port, observed, opts) do
          with {:ok, observed} <- recheck_latest_queue_version(port, observed, opts), :ok <- routed_session_access(session), do: {:ok, observed}
        else
          {:error, _} = error -> error
          _ -> {:error, :native_read_identity_or_history_mismatch}
        end
      after
        Process.delete(@native_read_deadline_key)
      end
    end
  end

  def read_owned_native_thread(_session), do: {:error, :file_worker_session_not_owned}

  @doc "Checks the configured runtime without a thread, model turn, connector call or transferable authority."
  @spec check_ticket_runtime(Path.t()) :: :ok | {:error, term()}
  def check_ticket_runtime(workspace) when is_binary(workspace) do
    with true <- Path.type(workspace) == :absolute,
         {:ok, cwd} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(cwd),
         {:ok, port} <- start_port(cwd, nil, DynamicTool.bind()) do
      Process.unlink(port)
      pid = port_metadata(port, nil)[:codex_app_server_pid]
      previous = Process.get(@native_read_deadline_key)
      deadline = System.monotonic_time(:millisecond) + 20_000
      Process.put(@native_read_deadline_key, if(is_integer(previous), do: min(deadline, previous), else: deadline))

      try do
        result = inspect_ticket_runtime(port)

        case stop_ticket_runtime(port, pid) do
          {:ok, status} when status in [0, 143] -> result
          {:ok, _status} -> {:error, :ticket_runtime_process_failed}
          {:error, _} = error -> error
        end
      after
        if is_nil(previous), do: Process.delete(@native_read_deadline_key), else: Process.put(@native_read_deadline_key, previous)
        stop_port(port)
      end
    else
      false -> {:error, :ticket_runtime_cwd_unproven}
      {:error, _} = error -> error
    end
  end

  def check_ticket_runtime(_workspace), do: {:error, :ticket_runtime_cwd_unproven}

  defp inspect_ticket_runtime(port) do
    with {:ok, response} <- initialization_response(port),
         :ok <- qualify_ticket_runtime_identity(response) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  rescue
    _ -> {:error, :ticket_runtime_initialization_failed}
  catch
    _kind, _reason -> {:error, :ticket_runtime_initialization_failed}
  end

  defp stop_ticket_runtime(port, pid) do
    if is_nil(Process.get({@owned_exit_key, port})) do
      receive do
        {^port, {:exit_status, _status}} -> {:error, :ticket_runtime_process_failed}
      after
        0 -> signal_owned_worker(port, pid)
      end
    else
      {:error, :ticket_runtime_process_failed}
    end
  end

  defp maybe_read_native_queue(port, thread, opts) do
    if Keyword.get(opts, :include_queue, false) do
      send_message(port, %{"method" => "thread/queue/list", "id" => @native_queue_list_id, "params" => %{"threadId" => thread["id"], "limit" => 10}})

      case await_response(port, @native_queue_list_id) do
        {:ok, %{"data" => items, "nextCursor" => next} = result} when is_list(items) ->
          native_queue_observation(thread, result, items, next)

        {:ok, _} ->
          {:error, :native_queue_page_invalid}

        error ->
          error
      end
    else
      {:ok, thread}
    end
  end

  defp native_queue_observation(thread, result, items, next) do
    if Enum.all?(items, &is_map/1) and (is_nil(next) or (is_binary(next) and next != "")) do
      observation = %{
        "thread_id" => thread["id"],
        "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "empty_complete" => items == [] and is_nil(next),
        "count_lower_bound" => length(items),
        "has_more" => not is_nil(next),
        "raw_response" => result,
        "sha256" => :crypto.hash(:sha256, Jason.encode!(result)) |> Base.encode16(case: :lower)
      }

      {:ok, Map.put(thread, "queue_observation", observation)}
    else
      {:error, :native_queue_page_invalid}
    end
  end

  defp maybe_read_complete_history(port, thread, opts) do
    if anchor = Keyword.get(opts, :history_after_turn) do
      with true <- (is_binary(anchor) and byte_size(anchor) in 1..256) or {:error, :native_history_anchor_invalid},
           true <- is_number(thread["updatedAt"]) or {:error, :native_history_version_missing},
           {:ok, turns} <- read_anchored_turn_pages(port, thread["id"], anchor, nil, [], [], 0),
           :ok <- unchanged_native_history(port, thread) do
        {:ok,
         thread
         |> Map.put("turns", turns)
         |> Map.put("history_observation", %{"mode" => "PAGED_AFTER_ANCHOR", "anchor_turn_id" => anchor, "turn_count" => length(turns), "updated_at" => thread["updatedAt"]})}
      end
    else
      read_complete_history(port, thread, opts)
    end
  end

  defp read_anchored_turn_pages(_port, _thread, _anchor, _cursor, _seen, _turns, pages) when pages >= 20, do: {:error, :native_history_anchor_budget_exhausted}

  defp read_anchored_turn_pages(port, thread, anchor, cursor, seen, turns, pages) do
    params = %{"threadId" => thread, "limit" => 5, "sortDirection" => "desc", "itemsView" => "full"}
    params = if is_nil(cursor), do: params, else: Map.put(params, "cursor", cursor)
    send_message(port, %{"method" => "thread/turns/list", "id" => @native_turn_list_id, "params" => params})

    with {:ok, %{"data" => page, "nextCursor" => next}} when is_list(page) <- await_response(port, @native_turn_list_id),
         :ok <- validate_full_turn_items(page),
         all = turns ++ page,
         :ok <- validate_native_turn_ids(all) do
      case Enum.find_index(all, &(&1["id"] == anchor)) do
        index when is_integer(index) ->
          {:ok, all |> Enum.take(index + 1) |> Enum.reverse()}

        nil when is_binary(next) and next != "" ->
          continue_anchored_pages(port, thread, anchor, next, seen, all, pages)

        _ ->
          {:error, :native_history_anchor_missing}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :native_history_page_invalid}
    end
  end

  defp continue_anchored_pages(port, thread, anchor, next, seen, all, pages) do
    if next in seen,
      do: {:error, :native_history_cursor_invalid},
      else: read_anchored_turn_pages(port, thread, anchor, next, [next | seen], all, pages + 1)
  end

  defp read_complete_history(port, thread, opts) do
    if Keyword.get(opts, :complete_history, false) do
      with true <- is_number(thread["updatedAt"]) or {:error, :native_history_version_missing},
           {:ok, turns} <- read_turn_pages(port, thread["id"], nil, [], [], 0),
           :ok <- unchanged_native_history(port, thread) do
        {:ok, thread |> Map.put("turns", turns) |> Map.put("history_observation", %{"mode" => "PAGED_FULL", "next_cursor" => nil, "turn_count" => length(turns), "updated_at" => thread["updatedAt"]})}
      end
    else
      {:ok, thread}
    end
  end

  defp maybe_read_latest_turn(port, thread, opts) do
    if Keyword.get(opts, :include_latest_turn, false) do
      params = %{"threadId" => thread["id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}
      send_message(port, %{"method" => "thread/turns/list", "id" => @native_turn_list_id, "params" => params})

      with true <- is_number(thread["updatedAt"]) or {:error, :native_history_version_missing},
           {:ok, %{"data" => [_turn], "nextCursor" => cursor} = raw} <- await_response(port, @native_turn_list_id),
           true <- is_nil(cursor) or (is_binary(cursor) and cursor != "") or {:error, :native_latest_turn_invalid},
           :ok <- validate_full_turn_items(raw["data"]),
           :ok <- validate_native_turn_ids(raw["data"]),
           :ok <- unchanged_native_history(port, thread) do
        observation = %{
          "mode" => "LATEST_DESC",
          "parameters" => params,
          "raw_response" => raw,
          "sha256" => digest_native(raw),
          "updated_at" => thread["updatedAt"],
          "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        {:ok, Map.put(thread, "latest_turn_observation", observation)}
      else
        {:error, _} = error -> error
        _ -> {:error, :native_latest_turn_invalid}
      end
    else
      {:ok, thread}
    end
  end

  defp digest_native(raw), do: Base.encode16(:crypto.hash(:sha256, Jason.encode!(raw)), case: :lower)

  defp recheck_latest_queue_version(port, thread, opts) do
    if Keyword.get(opts, :include_latest_turn, false) and Keyword.get(opts, :include_queue, false) do
      original = thread["latest_turn_observation"]
      send_message(port, %{"method" => "thread/turns/list", "id" => @native_turn_list_id, "params" => original["parameters"]})

      with {:ok, %{"data" => data, "nextCursor" => cursor} = raw} <- await_response(port, @native_turn_list_id),
           true <- is_nil(cursor) or (is_binary(cursor) and cursor != "") or {:error, :native_latest_turn_invalid},
           true <- data == original["raw_response"]["data"] or {:error, :native_latest_turn_changed_during_read},
           :ok <- unchanged_native_history(port, thread) do
        confirmation = %{"raw_response" => raw, "sha256" => digest_native(raw), "observed_at" => DateTime.to_iso8601(DateTime.utc_now())}
        {:ok, put_in(thread, ["latest_turn_observation", "confirmation"], confirmation)}
      else
        {:error, _} = error -> error
        _ -> {:error, :native_latest_turn_invalid}
      end
    else
      {:ok, thread}
    end
  end

  defp read_turn_pages(_port, _thread, _cursor, _seen, _turns, pages) when pages >= 100, do: {:error, :native_history_page_limit}

  defp read_turn_pages(port, thread, cursor, seen, turns, pages) do
    params = %{"threadId" => thread, "limit" => 50, "sortDirection" => "asc", "itemsView" => "full"}
    params = if is_nil(cursor), do: params, else: Map.put(params, "cursor", cursor)
    send_message(port, %{"method" => "thread/turns/list", "id" => @native_turn_list_id, "params" => params})

    case await_response(port, @native_turn_list_id) do
      {:ok, %{"data" => page, "nextCursor" => next}} when is_list(page) ->
        finish_turn_page(port, thread, page, next, seen, turns, pages)

      {:ok, _} ->
        {:error, :native_history_page_invalid}

      error ->
        error
    end
  end

  defp finish_turn_page(port, thread, page, next, seen, turns, pages) do
    all = turns ++ page

    with :ok <- validate_full_turn_items(page), :ok <- validate_native_turn_ids(all) do
      cond do
        is_nil(next) -> {:ok, all}
        not is_binary(next) or next == "" or next in seen -> {:error, :native_history_cursor_invalid}
        true -> read_turn_pages(port, thread, next, [next | seen], all, pages + 1)
      end
    end
  end

  defp validate_full_turn_items(page) do
    if Enum.all?(page, &(is_map(&1) and is_list(&1["items"]))), do: :ok, else: {:error, :native_history_items_missing}
  end

  defp validate_native_turn_ids(turns) do
    ids = Enum.map(turns, & &1["id"])
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and length(Enum.uniq(ids)) == length(ids), do: :ok, else: {:error, :native_history_turn_conflict}
  end

  defp unchanged_native_history(port, thread) do
    send_message(port, %{"method" => "thread/read", "id" => @thread_read_id, "params" => %{"threadId" => thread["id"], "includeTurns" => false}})

    case await_response(port, @thread_read_id) do
      {:ok, %{"thread" => current}} when is_map(current) ->
        if Map.take(current, ~w(id cwd projectId updatedAt)) == Map.take(thread, ~w(id cwd projectId updatedAt)),
          do: :ok,
          else: {:error, :native_history_changed_during_read}

      {:ok, _} ->
        {:error, :native_history_page_invalid}

      error ->
        error
    end
  end

  defp list_threads_by_title(_port, _title, _archived, _cursor, _seen, _matches, scanned)
       when scanned > @thread_list_max_records,
       do: {:error, :thread_list_limit_exceeded}

  defp list_threads_by_title(port, title, archived, cursor, seen, matches, scanned) do
    params = %{
      "archived" => archived,
      "limit" => @thread_list_page_size,
      "searchTerm" => title,
      "sourceKinds" => @thread_list_source_kinds,
      "useStateDbOnly" => false
    }

    params = if is_nil(cursor), do: params, else: Map.put(params, "cursor", cursor)
    send_message(port, %{"method" => "thread/list", "id" => @thread_list_id, "params" => params})

    case await_response(port, @thread_list_id) do
      {:ok, %{"data" => page} = response} when is_list(page) ->
        updated_scanned = scanned + length(page)

        cond do
          updated_scanned > @thread_list_max_records ->
            {:error, :thread_list_limit_exceeded}

          not Enum.all?(page, &is_map/1) ->
            {:error, :invalid_thread_list_page}

          true ->
            exact_matches =
              page
              |> Enum.filter(&(Map.get(&1, "name") == title))
              |> Enum.map(&Map.put(&1, "archived", archived))

            continue_thread_list(
              port,
              title,
              archived,
              Map.get(response, "nextCursor"),
              seen,
              matches ++ exact_matches,
              updated_scanned
            )
        end

      other ->
        {:error, {:thread_lookup_failed, other}}
    end
  end

  defp continue_thread_list(_port, _title, _archived, nil, _seen, matches, _scanned),
    do: {:ok, matches}

  defp continue_thread_list(port, title, archived, cursor, seen, matches, scanned)
       when is_binary(cursor) and cursor != "" do
    if cursor in seen do
      {:error, :thread_list_cursor_repeated}
    else
      list_threads_by_title(port, title, archived, cursor, [cursor | seen], matches, scanned)
    end
  end

  defp continue_thread_list(_port, _title, _archived, _cursor, _seen, _matches, _scanned),
    do: {:error, :invalid_thread_list_cursor}

  defp resolve_exact_thread([], _project_id), do: {:error, :thread_not_found}

  defp resolve_exact_thread([%{"id" => id, "projectId" => project_id, "cwd" => cwd, "archived" => archived}], expected_project_id)
       when is_binary(id) and id != "" and is_binary(cwd) and cwd != "" and
              is_boolean(archived) do
    result = %{id: id, project_id: project_id, cwd: cwd, archived: archived}

    case project_id do
      ^expected_project_id -> {:ok, result}
      nil -> {:candidate, result}
      _ -> {:error, {:thread_project_mismatch, expected_project_id, project_id}}
    end
  end

  defp resolve_exact_thread([record], _project_id),
    do: {:error, {:invalid_thread_list_entry, Map.get(record, "id")}}

  defp resolve_exact_thread(records, _project_id),
    do: {:error, {:thread_name_ambiguous, Enum.map(records, &Map.get(&1, "id"))}}

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding),
    do: start_port(workspace, worker_host, dynamic_tool_binding, nil)

  defp start_port(workspace, worker_host, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec),
    do: start_port(workspace, worker_host, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, [])

  defp start_port(workspace, nil, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, overrides) do
    start_port(workspace, nil, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, overrides, [])
  end

  defp start_port(_workspace, host, _binding, _timeout, [_ | _]) when is_binary(host), do: {:error, :worker_remote_profile_unsupported}

  defp start_port(workspace, worker_host, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, [])
       when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp start_port(workspace, host, binding, timeout, overrides, []) when is_binary(host),
    do: start_port(workspace, host, binding, timeout, overrides)

  defp start_port(_workspace, host, _binding, _timeout, _overrides, [_ | _]) when is_binary(host),
    do: {:error, :factory_connector_remote_unsupported}

  defp start_port(workspace, nil, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, overrides, connector_overrides) do
    start_port(workspace, nil, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, overrides, connector_overrides, [])
  end

  defp start_port(workspace, host, binding, timeout, overrides, connector_overrides, []) when is_binary(host),
    do: start_port(workspace, host, binding, timeout, overrides, connector_overrides)

  defp start_port(_workspace, host, _binding, _timeout, _overrides, _connector_overrides, [_ | _]) when is_binary(host),
    do: {:error, :native_runtime_remote_unsupported}

  defp start_port(workspace, nil, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec, overrides, connector_overrides, child_env) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      arguments = Enum.map_join(overrides ++ connector_overrides, "", &(" --config " <> shell_escape(&1)))
      command = local_launch_command(dynamic_tool_binding, gitlab_mcp_startup_timeout_sec) <> arguments

      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          args: [~c"-lc", String.to_charlist(command)],
          cd: String.to_charlist(workspace),
          env: worker_port_env(dynamic_tool_binding, overrides) ++ child_env,
          line: @port_line_bytes
        ])

      {:ok, port}
    end
  end

  defp factory_connector_overrides(opts, worker_host) do
    if Keyword.get(opts, :factory_jira_controller, false) do
      if is_nil(worker_host) and is_nil(opts[:worker_access]) and opts[:ephemeral] == true and opts[:required_mcp_servers] == ["Jira"],
        do: jira_connector_overrides(Config.settings!().factory.jira_connector),
        else: {:error, :factory_connector_route_invalid}
    else
      {:ok, []}
    end
  end

  defp jira_connector_overrides(config) when config == %{}, do: {:ok, []}

  defp jira_connector_overrides(%{"command" => command, "args" => args} = config) when is_binary(command) and is_list(args) do
    if Enum.sort(Map.keys(config)) == ~w(args command) and not String.contains?(command, <<0>>) and Path.type(command) == :absolute and File.regular?(command) and
         Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>))) do
      {:ok, ["mcp_servers.Jira.command=" <> Jason.encode!(command), "mcp_servers.Jira.args=" <> Jason.encode!(args)]}
    else
      {:error, :factory_jira_connector_invalid}
    end
  end

  defp jira_connector_overrides(_config), do: {:error, :factory_jira_connector_invalid}

  defp local_launch_command(dynamic_tool_binding, gitlab_mcp_startup_timeout_sec) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{codex_command(gitlab_mcp_startup_timeout_sec)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec)
       when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{codex_command(gitlab_mcp_startup_timeout_sec)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp codex_command(nil), do: Config.settings!().codex.command

  defp codex_command(seconds) when is_integer(seconds) and seconds in 31..55 do
    Config.settings!().codex.command <> " --config mcp_servers.GitLab.startup_timeout_sec=#{seconds}"
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp worker_port_env(binding, []), do: tracker_secret_port_env(binding)

  defp worker_port_env(binding, overrides) do
    secrets = System.get_env() |> Map.keys() |> Enum.filter(&String.match?(&1, ~r/(?:_TOKEN|_KEY|_SECRET|_PASSWORD)$/))
    host = code_mode_host_env(overrides)
    tracker_secret_port_env(binding) ++ Enum.map(secrets, &{String.to_charlist(&1), false}) ++ host
  end

  defp code_mode_host_env(overrides) do
    path = Path.dirname(code_mode_host_path()) <> ":" <> (System.get_env("PATH") || "")
    if "features.code_mode_host=true" in overrides, do: [{~c"PATH", String.to_charlist(path)}], else: []
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port, options \\ nil) do
    with {:ok, response} <- initialization_response(port),
         :ok <- qualify_worker_initialization(response, options) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp initialization_response(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    await_response(port, @initialize_id)
  end

  defp qualify_worker_initialization(response, %{worker_access: mode, native_runtime: %NativeRuntimeRoute{} = route}) when mode in ~w(FILE_SOURCE REVIEW) do
    with {:ok, home, family, os, agent} <- worker_runtime_fields(response),
         :ok <- worker_runtime_supported(family, os, agent),
         true <- home == route.codex_home.path or {:error, :worker_runtime_home_mismatch} do
      :ok
    end
  end

  defp qualify_worker_initialization(response, %{worker_access: mode}) when mode in ~w(FILE_SOURCE REVIEW) do
    qualify_ticket_runtime_identity(response)
  end

  defp qualify_worker_initialization(_response, _options), do: :ok

  defp qualify_ticket_runtime_identity(response) do
    with {:ok, home, family, os, agent} <- worker_runtime_fields(response),
         :ok <- worker_runtime_supported(family, os, agent) do
      worker_runtime_home(home)
    end
  end

  defp worker_runtime_fields(response) do
    case response do
      %{"codexHome" => home, "platformFamily" => family, "platformOs" => os, "userAgent" => agent}
      when is_binary(home) and is_binary(family) and is_binary(os) and is_binary(agent) ->
        {:ok, home, family, os, agent}

      _ ->
        {:error, :worker_runtime_identity_unproven}
    end
  end

  defp worker_runtime_supported("unix", "macos", agent) do
    supported_agent? =
      Enum.any?(@ticket_worker_runtime_versions, fn version ->
        String.starts_with?(agent, "symphony-orchestrator/#{version} (")
      end)

    if byte_size(agent) <= 2_048 and supported_agent?,
      do: :ok,
      else: {:error, :worker_runtime_unsupported}
  end

  defp worker_runtime_supported(_family, _os, _agent), do: {:error, :worker_runtime_unsupported}

  defp worker_runtime_home(home) do
    expected = System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")

    with true <- (Path.type(home) == :absolute and Path.type(expected) == :absolute) or {:error, :worker_runtime_home_mismatch},
         {:ok, observed_home} <- PathSafety.canonicalize(home),
         {:ok, expected_home} <- PathSafety.canonicalize(expected),
         true <- observed_home == expected_home or {:error, :worker_runtime_home_mismatch} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp scoped_session_policies(policies, %{approval_policy: nil, allowed_mcp_tool_approvals: []}),
    do: {:ok, policies}

  defp scoped_session_policies(
         policies,
         %{approval_policy: "on-request", allowed_mcp_tool_approvals: allowed}
       )
       when is_list(allowed) do
    if allowed != [] and length(allowed) <= 2 and
         Enum.all?(allowed, &valid_scoped_jira_approval?/1) and
         Enum.uniq_by(allowed, & &1.tool) == allowed and
         length(Enum.uniq(Enum.map(allowed, & &1.issue_key))) == 1 do
      {:ok, %{policies | approval_policy: "on-request"}}
    else
      {:error, :invalid_scoped_mcp_approval}
    end
  end

  defp scoped_session_policies(_policies, _options), do: {:error, :invalid_scoped_mcp_approval}

  defp worker_session_policies(policies, %{worker_policy: nil} = options), do: scoped_session_policies(policies, options)

  defp worker_session_policies(_policies, options) do
    readonly = options.worker_access in ~w(REVIEW FILE_SOURCE)

    {:ok,
     %{
       approval_policy: "never",
       thread_sandbox: if(readonly, do: "read-only", else: "workspace-write"),
       turn_sandbox_policy: if(readonly, do: %{"type" => "readOnly"}, else: %{"type" => "workspaceWrite", "networkAccess" => false})
     }}
  end

  defp prepare_worker(_workspace, _host, %{worker_access: nil} = options, binding), do: {:ok, options, binding}

  # Native PID exit does not stop a detached writable descendant; this route cannot admit source work yet.
  defp prepare_worker(_workspace, _host, %{worker_access: "SOURCE"}, _binding), do: {:error, :worker_source_containment_unproven}

  defp prepare_worker(workspace, nil, %{worker_access: "FILE_SOURCE"} = options, binding) do
    with :ok <- WorkerFileTools.preflight(options.worker_files, workspace),
         :ok <- restricted_worker_options(options),
         {:ok, inventory} <- read_worker_configuration(workspace, binding, options),
         policy = worker_policy("FILE_SOURCE", workspace),
         {:ok, overrides} <- worker_overrides(inventory, policy) do
      overrides = overrides ++ worker_allocation_overrides(options)
      {:ok, %{options | worker_policy: policy, worker_overrides: overrides}, Map.put(binding, :tool_specs, WorkerFileTools.tool_specs())}
    end
  end

  defp prepare_worker(workspace, nil, %{worker_access: "REVIEW"} = options, binding) do
    with :ok <- restricted_worker_options(options),
         {:ok, inventory} <- read_worker_configuration(workspace, binding, options),
         policy = worker_policy("REVIEW", workspace),
         {:ok, overrides} <- worker_overrides(inventory, policy) do
      overrides = overrides ++ worker_allocation_overrides(options)
      {:ok, %{options | worker_policy: policy, worker_overrides: overrides}, Map.put(binding, :tool_specs, [])}
    end
  end

  defp prepare_worker(_workspace, _host, _options, _binding), do: {:error, :worker_access_profile_unsupported}

  defp worker_allocation_overrides(%{reasoning_effort: effort}) when is_binary(effort),
    do: ["model_reasoning_effort=" <> Jason.encode!(effort)]

  defp worker_allocation_overrides(_options), do: []

  defp restricted_worker_options(options) do
    empty = %{required_apps: [], required_mcp_servers: [], allowed_mcp_tool_approvals: []}
    expected = Map.merge(empty, %{fork_on_active_writer: false, project_id: nil, project_root: nil})
    valid = Map.take(options, Map.keys(expected)) == expected
    if valid, do: :ok, else: {:error, :worker_capability_configuration_rejected}
  end

  defp read_worker_configuration(workspace, binding, options) do
    with {:ok, storage} <- worker_storage(workspace, options),
         {:ok, port} <- start_port(workspace, nil, binding, nil, storage.overrides, [], storage.env) do
      Process.put(@native_read_deadline_key, System.monotonic_time(:millisecond) + 20_000)

      try do
        with :ok <- send_initialize(port, if(is_nil(options.native_runtime), do: nil, else: options)),
             true <- send_message(port, %{"method" => "config/read", "id" => @worker_config_id, "params" => %{"cwd" => workspace, "includeLayers" => false}}),
             {:ok, %{"config" => config}} <- await_response(port, @worker_config_id),
             :ok <- worker_sqlite_config(config, options) do
          {:ok, config}
        else
          {:error, _} = error -> error
          _ -> {:error, :worker_configuration_unavailable}
        end
      after
        stop_port(port)
        Process.delete(@native_read_deadline_key)
      end
    end
  end

  @doc false
  @spec worker_policy(String.t(), Path.t()) :: map()
  def worker_policy(mode, workspace) do
    policy = %{
      "mode" => mode,
      "profile" => worker_profile(mode),
      "cwd" => workspace,
      "approval_policy" => "never",
      "network" => false,
      "connectors" => [],
      "source_access" => if(mode == "SOURCE", do: "write", else: "read"),
      "read_roots" => worker_read_roots(workspace)
    }

    cond do
      mode == "FILE_SOURCE" -> Map.put(policy, "file_tools_sha256", WorkerFileTools.tool_contract_sha256())
      mode == "REVIEW" -> Map.put(policy, "shell_environment", review_shell_environment())
      true -> policy
    end
  end

  defp review_shell_environment do
    %{
      "inherit" => "core",
      "set" => %{
        "PATH" => "/Library/Developer/CommandLineTools/usr/bin:" <> (System.get_env("PATH") || "/usr/bin:/bin"),
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_SYSTEM" => "/dev/null",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_NO_LAZY_FETCH" => "1",
        "GIT_NO_REPLACE_OBJECTS" => "1",
        "GIT_CONFIG_COUNT" => "3",
        "GIT_CONFIG_KEY_0" => "core.excludesfile",
        "GIT_CONFIG_VALUE_0" => "/dev/null",
        "GIT_CONFIG_KEY_1" => "core.fsmonitor",
        "GIT_CONFIG_VALUE_1" => "false",
        "GIT_CONFIG_KEY_2" => "core.hooksPath",
        "GIT_CONFIG_VALUE_2" => "/dev/null"
      }
    }
  end

  defp worker_read_roots(workspace) do
    home = System.user_home!()
    tools = [Path.join(home, ".agents/skills"), Path.join(home, ".agents/rules"), Path.join(home, ".local/share/mise"), "/opt/homebrew"]

    roots =
      case System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-common-dir"], stderr_to_stdout: true) do
        {path, 0} -> [String.trim(path) | tools]
        _ -> tools
      end

    roots |> Enum.filter(&File.dir?/1) |> Enum.map(&canonical_worker_read_root/1) |> Enum.uniq()
  end

  defp canonical_worker_read_root(path) do
    {:ok, canonical} = PathSafety.canonicalize(path)
    canonical
  end

  defp worker_overrides(config, policy) when is_map(config) do
    mcp = config["mcp_servers"] || %{}
    plugins = config["plugins"] || %{}

    valid_inventory = is_map(mcp) and is_map(plugins) and map_size(mcp) + map_size(plugins) <= 256

    if valid_inventory and valid_worker_config_names?(mcp, plugins) do
      profile = policy["profile"]
      parent = if policy["mode"] == "SOURCE", do: ":workspace", else: ":read-only"
      access = policy["source_access"]
      reads = Enum.map_join(policy["read_roots"], "", &"#{Jason.encode!(&1)}=\"read\",")

      filesystem =
        ~s({#{reads}":root"="deny",":minimal"="read",":tmpdir"="deny",":slash_tmp"="deny","/Library/Developer/CommandLineTools"="read","/var/db/xcode_select_link"="read",":workspace_roots"={"."="#{access}"}})

      fixed = [
        "approval_policy=\"never\"",
        "features.apps=false",
        "features.multi_agent=false",
        "web_search=\"disabled\"",
        "default_permissions=\"#{profile}\"",
        "permissions.#{profile}.extends=\"#{parent}\"",
        "permissions.#{profile}.filesystem=#{filesystem}",
        "permissions.#{profile}.network.enabled=false",
        "plugins.openai-developers@openai-curated-remote.enabled=false",
        # Disabled plugin-injected servers still need a transport during config validation.
        "mcp_servers.openai-api-key-local-confirmation.command=\"/usr/bin/false\"",
        "mcp_servers.openai-api-key-local-confirmation.enabled=false",
        "plugins.openai-developers@openai-curated-remote.mcp_servers.openai-api-key-local-confirmation.disabled_tools=[\"confirm_openai_api_key_local_destination\"]"
      ]

      overrides = Enum.map(Map.keys(mcp), &"mcp_servers.#{&1}.enabled=false") ++ Enum.map(Map.keys(plugins), &"plugins.#{&1}.enabled=false")
      {:ok, fixed ++ overrides ++ file_worker_overrides(policy) ++ review_shell_overrides(policy)}
    else
      {:error, :worker_configuration_unavailable}
    end
  end

  defp worker_overrides(_config, _mode), do: {:error, :worker_configuration_unavailable}

  defp file_worker_overrides(%{"mode" => "FILE_SOURCE"}), do: Enum.map(file_worker_flags(), fn {flag, enabled} -> "features.#{flag}=#{enabled}" end)
  defp file_worker_overrides(_policy), do: []

  defp review_shell_overrides(%{"shell_environment" => %{"set" => environment}}) do
    values = environment |> Enum.sort() |> Enum.map_join(",", fn {key, value} -> "#{Jason.encode!(key)}=#{Jason.encode!(value)}" end)
    ["shell_environment_policy={inherit=\"core\",set={#{values}},ignore_default_excludes=false}"]
  end

  defp review_shell_overrides(_policy), do: []

  defp valid_worker_config_names?(mcp, plugins) do
    Enum.all?(Map.keys(mcp) ++ Map.keys(plugins), fn name ->
      is_binary(name) and name != "" and not String.contains?(name, [".", "=", "\n", "\r", <<0>>])
    end)
  end

  defp worker_profile("SOURCE"), do: "symphony_ticket_source_v1"
  defp worker_profile("REVIEW"), do: "symphony_ticket_review_v1"
  defp worker_profile("FILE_SOURCE"), do: "symphony_ticket_file_source_v1"

  defp file_worker_flags,
    do: %{
      "shell_tool" => false,
      "unified_exec" => false,
      "code_mode_host" => true,
      "apps" => false,
      "multi_agent" => false,
      "browser_use" => false,
      "browser_use_external" => false,
      "computer_use" => false,
      "image_generation" => false,
      "request_permissions_tool" => false,
      "hooks" => false
    }

  defp code_mode_host_path, do: "/Applications/ChatGPT.localized/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host"

  defp valid_scoped_jira_approval?(%{server: "Jira", tool: "jira_add_comment", issue_key: issue_key, body_equals: body})
       when is_binary(issue_key) and is_binary(body),
       do: issue_key != "" and body != ""

  defp valid_scoped_jira_approval?(%{server: "Jira", tool: "jira_update_issue", issue_key: issue_key, labels_equals: labels})
       when is_binary(issue_key) and is_list(labels),
       do: issue_key != "" and labels != [] and Enum.all?(labels, &(is_binary(&1) and &1 != "")) and Enum.uniq(labels) == labels

  defp valid_scoped_jira_approval?(_approval), do: false

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding, thread_options) do
    with :ok <- send_initialize(port, thread_options),
         :ok <- worker_sqlite_runtime(port, thread_options),
         :ok <- file_worker_runtime(port, workspace, thread_options),
         :ok <- worker_account(port, thread_options),
         {:ok, project_id} <- resolve_project_id(port, thread_options.project_id, thread_options.project_root),
         {:ok, _storage} <- worker_storage(workspace, thread_options),
         {:ok, thread_ref} <-
           open_thread(
             port,
             workspace,
             session_policies,
             dynamic_tool_binding,
             %{thread_options | project_id: project_id}
           ) do
      {:ok, Map.put(thread_ref, :project_id, project_id)}
    end
  end

  defp worker_sqlite_runtime(_port, %{native_runtime: nil}), do: :ok

  defp worker_sqlite_runtime(port, options) do
    send_message(port, %{"method" => "config/read", "id" => @worker_config_id, "params" => %{"includeLayers" => false}})

    case await_response(port, @worker_config_id) do
      {:ok, %{"config" => config}} -> worker_sqlite_config(config, options)
      {:error, _} = error -> error
      _ -> {:error, :native_runtime_sqlite_mismatch}
    end
  end

  defp worker_sqlite_config(_config, %{native_runtime: nil}), do: :ok
  defp worker_sqlite_config(%{"sqlite_home" => sqlite}, %{native_runtime: route}) when sqlite == route.sqlite_home.path, do: :ok
  defp worker_sqlite_config(_config, _options), do: {:error, :native_runtime_sqlite_mismatch}

  defp file_worker_runtime(port, workspace, %{worker_access: "FILE_SOURCE"}), do: file_worker_runtime(port, workspace)
  defp file_worker_runtime(_port, _workspace, _options), do: :ok

  defp file_worker_session_owned(%{port: port, metadata: %{codex_app_server_pid: expected}}) when is_port(port) do
    owned = :erlang.port_info(port, :connected) == {:connected, self()}

    if owned and port_metadata(port, nil)[:codex_app_server_pid] == expected,
      do: :ok,
      else: {:error, :file_worker_session_not_owned}
  end

  defp file_worker_session_owned(_session), do: {:error, :file_worker_session_not_owned}

  defp file_worker_runtime(port, workspace) do
    send_message(port, %{"method" => "config/read", "id" => @worker_config_id, "params" => %{"cwd" => workspace, "includeLayers" => false}})

    with {:ok, %{"config" => config}} <- await_response(port, @worker_config_id),
         true <- config["web_search"] == "disabled" and is_map(config["features"]),
         true <- Map.take(config["features"], Map.keys(file_worker_flags())) == file_worker_flags(),
         true <- disabled_inventory?(config["mcp_servers"]) and disabled_inventory?(config["plugins"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :file_worker_effective_capabilities_mismatch}
    end
  end

  defp disabled_inventory?(items) when is_map(items), do: Enum.all?(items, fn {_name, value} -> is_map(value) and value["enabled"] == false end)
  defp disabled_inventory?(_items), do: false

  defp worker_account(_port, %{worker_policy: nil}), do: :ok

  defp worker_account(port, _options) do
    send_message(port, %{"method" => "account/read", "id" => @worker_account_id, "params" => %{"refreshToken" => false}})

    case await_response(port, @worker_account_id) do
      {:ok, %{"account" => %{"type" => "chatgpt"}}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :worker_chatgpt_account_required}
    end
  end

  defp open_thread(port, workspace, session_policies, dynamic_tool_binding, thread_options) do
    case start_or_resume_thread(
           port,
           workspace,
           session_policies,
           dynamic_tool_binding,
           thread_options
         ) do
      {:ok, thread_ref} ->
        finish_open_thread(port, thread_ref, thread_options)

      {:error, _reason} = error ->
        error
    end
  end

  defp finish_open_thread(port, thread_ref, thread_options) do
    thread_id = thread_ref.thread_id

    with :ok <- notify_thread_created(thread_options, thread_id),
         :ok <- worker_catalog_empty(port, %{worker_policy: thread_options.worker_policy, thread_id: thread_id}),
         :ok <- set_thread_name(port, thread_id, thread_options.name),
         :ok <- set_thread_project(port, thread_id, thread_options.project_id),
         :ok <- move_thread_to_section(port, thread_id, thread_options.section_id),
         :ok <-
           await_required_mcp_servers(
             port,
             thread_options.required_mcp_servers,
             thread_options.mcp_startup_timeout_ms
           ),
         :ok <- ensure_required_apps(port, thread_options.required_apps, thread_id) do
      {:ok, thread_ref}
    else
      {:error, _reason} = error ->
        unsubscribe_thread(port, thread_id)
        error
    end
  end

  defp notify_thread_created(%{on_thread_created: callback}, thread_id) when is_function(callback, 1) do
    callback.(thread_id)
    :ok
  end

  defp notify_thread_created(_thread_options, _thread_id), do: :ok

  defp start_or_resume_thread(
         port,
         workspace,
         session_policies,
         _dynamic_tool_binding,
         %{resume_thread_id: thread_id} = thread_options
       )
       when is_binary(thread_id) and thread_id != "" do
    resume_thread(port, workspace, session_policies, thread_options)
  end

  defp start_or_resume_thread(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         thread_options
       ) do
    start_thread(port, workspace, session_policies, dynamic_tool_binding, thread_options)
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding,
         thread_options
       ) do
    params =
      %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs,
        "ephemeral" => thread_options.ephemeral,
        "serviceName" => thread_options.service_name,
        "threadSource" => thread_options.thread_source
      }
      |> put_if_present("model", thread_options.model)
      |> worker_params(thread_options.worker_policy)

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id) do
      {:ok, response} ->
        started_thread(response, workspace, thread_options)

      other ->
        other
    end
  end

  defp started_thread(%{"thread" => %{"id" => thread_id}} = response, workspace, options) do
    with :ok <- verify_worker_response(response, workspace, options) do
      {:ok, %{thread_id: thread_id, forked_from_thread_id: nil}}
    end
  end

  defp started_thread(%{"thread" => thread}, _workspace, _options), do: {:error, {:invalid_thread_payload, thread}}
  defp started_thread(response, _workspace, _options), do: {:error, {:invalid_thread_payload, response}}

  defp resume_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox} = session_policies,
         thread_options
       ) do
    params =
      %{
        "threadId" => thread_options.resume_thread_id,
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "excludeTurns" => true,
        "cwd" => workspace
      }
      |> put_if_present("model", thread_options.model)
      |> worker_params(thread_options.worker_policy)
      |> resume_worker_tools(thread_options)

    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => thread_id}} = response} when thread_id == thread_options.resume_thread_id ->
        with :ok <- verify_worker_response(response, workspace, thread_options) do
          {:ok, %{thread_id: thread_id, forked_from_thread_id: nil}}
        end

      {:ok, %{"thread" => %{"id" => thread_id}}} ->
        {:error, {:resumed_thread_id_mismatch, thread_options.resume_thread_id, thread_id}}

      {:ok, payload} ->
        {:error, {:invalid_thread_payload, payload}}

      {:error, {:response_error, error}} ->
        if thread_options.fork_on_active_writer,
          do: maybe_fork_active_writer(port, workspace, session_policies, thread_options, error),
          else: {:error, ResumeRefusal.classify(error, thread_options.resume_thread_id)}

      other ->
        other
    end
  end

  defp maybe_fork_active_writer(
         port,
         workspace,
         session_policies,
         %{fork_on_active_writer: true} = thread_options,
         %{"code" => -32_600, "message" => message} = error
       )
       when is_binary(message) do
    if String.contains?(String.downcase(message), "active writer") do
      case read_thread_status(port, thread_options.resume_thread_id) do
        {:ok, status} when status in ["idle", "notLoaded", "systemError"] ->
          fork_thread(port, workspace, session_policies, thread_options)

        {:ok, _active_status} ->
          {:error, {:response_error, error}}

        {:error, _reason} = read_error ->
          read_error
      end
    else
      {:error, {:response_error, %{"code" => -32_600, "message" => message}}}
    end
  end

  defp maybe_fork_active_writer(_port, _workspace, _session_policies, _thread_options, error),
    do: {:error, {:response_error, error}}

  defp fork_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         thread_options
       ) do
    params =
      %{
        "threadId" => thread_options.resume_thread_id,
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "ephemeral" => false,
        "excludeTurns" => true,
        "deferGoalContinuation" => true,
        "cwd" => workspace,
        "threadSource" => thread_options.thread_source
      }
      |> put_if_present("model", thread_options.model)

    send_message(port, %{
      "method" => "thread/fork",
      "id" => @thread_fork_id,
      "params" => params
    })

    case await_response(port, @thread_fork_id) do
      {:ok, %{"thread" => %{"id" => thread_id}}} ->
        {:ok,
         %{
           thread_id: thread_id,
           forked_from_thread_id: thread_options.resume_thread_id
         }}

      {:ok, payload} ->
        {:error, {:invalid_thread_payload, payload}}

      other ->
        other
    end
  end

  defp read_thread_status(port, thread_id) do
    send_message(port, %{
      "method" => "thread/read",
      "id" => @thread_read_id,
      "params" => %{"threadId" => thread_id, "includeTurns" => false}
    })

    case await_response(port, @thread_read_id) do
      {:ok, %{"thread" => %{"status" => %{"type" => status}}}} when is_binary(status) ->
        {:ok, status}

      {:ok, payload} ->
        {:error, {:invalid_thread_read_payload, payload}}

      other ->
        other
    end
  end

  defp set_thread_name(_port, _thread_id, nil), do: :ok

  defp set_thread_name(port, thread_id, thread_name) do
    send_message(port, %{
      "method" => "thread/name/set",
      "id" => @thread_name_set_id,
      "params" => %{
        "threadId" => thread_id,
        "name" => thread_name
      }
    })

    case await_response(port, @thread_name_set_id) do
      {:ok, _response} -> :ok
      other -> other
    end
  end

  defp reassert_thread_name(port, thread_id, thread_name) do
    case set_thread_name(port, thread_id, thread_name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to restore configured Codex task name for thread_id=#{thread_id}: #{inspect(reason)}")
    end
  end

  defp set_thread_project(_port, _thread_id, nil), do: :ok

  defp set_thread_project(port, thread_id, project_id) do
    send_message(port, %{
      "method" => "thread/metadata/update",
      "id" => @thread_metadata_update_id,
      "params" => %{
        "threadId" => thread_id,
        "projectId" => project_id
      }
    })

    case await_response(port, @thread_metadata_update_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id, "projectId" => ^project_id}}} ->
        :ok

      other ->
        {:error, {:project_binding_failed, project_id, other}}
    end
  end

  defp resolve_project_id(_port, nil, nil), do: {:ok, nil}
  defp resolve_project_id(_port, project_id, nil), do: {:ok, project_id}

  defp resolve_project_id(port, requested_id, project_root) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(project_root),
         true <- File.dir?(canonical_root) || {:error, {:project_root_unavailable, project_root}},
         {:ok, projects} <- list_projects(port, nil, [], []) do
      matching_projects =
        Enum.filter(projects, &primary_project_root?(&1, canonical_root))

      case matching_projects do
        [%{"id" => id}] when is_binary(requested_id) and requested_id != id ->
          {:error, {:project_id_mismatch, requested_id, id}}

        [%{"id" => id}] when is_binary(id) and id != "" ->
          {:ok, id}

        [] ->
          {:error, {:project_root_not_found, canonical_root}}

        _ ->
          {:error, {:project_root_ambiguous, canonical_root}}
      end
    end
  end

  defp primary_project_root?(%{"roots" => [%{"path" => primary_root} | _]}, canonical_root)
       when is_binary(primary_root),
       do: PathSafety.canonicalize(primary_root) == {:ok, canonical_root}

  defp primary_project_root?(_project, _canonical_root), do: false

  defp list_projects(_port, _cursor, _seen, projects) when length(projects) > 1_000,
    do: {:error, :project_list_limit_exceeded}

  defp list_projects(port, cursor, seen, projects) do
    params = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}
    send_message(port, %{"method" => "project/list", "id" => @project_list_id, "params" => params})

    case await_response(port, @project_list_id) do
      {:ok, %{"data" => page} = response} when is_list(page) ->
        continue_project_list(port, Map.get(response, "nextCursor"), seen, projects ++ page)

      other ->
        {:error, {:project_lookup_failed, other}}
    end
  end

  defp continue_project_list(_port, nil, _seen, projects), do: {:ok, projects}

  defp continue_project_list(port, next_cursor, seen, projects)
       when is_binary(next_cursor) and next_cursor != "" do
    if next_cursor in seen do
      {:error, :project_list_cursor_repeated}
    else
      list_projects(port, next_cursor, [next_cursor | seen], projects)
    end
  end

  defp continue_project_list(_port, _cursor, _seen, _projects), do: {:error, :invalid_project_list_cursor}

  defp move_thread_to_section(_port, _thread_id, nil), do: :ok

  defp move_thread_to_section(port, thread_id, section_id) do
    send_message(port, %{
      "method" => "thread/section/move",
      "id" => @thread_section_move_id,
      "params" => %{
        "threadId" => thread_id,
        "sectionId" => section_id
      }
    })

    case await_response(port, @thread_section_move_id) do
      {:ok, _response} -> :ok
      other -> other
    end
  end

  defp unsubscribe_thread(port, thread_id) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _port_info ->
        case send_unsubscribe(port, thread_id) do
          :sent -> confirm_thread_unsubscribe(port)
          :closed -> :ok
        end
    end
  end

  defp send_unsubscribe(port, thread_id) do
    message = %{
      "method" => "thread/unsubscribe",
      "id" => @thread_unsubscribe_id,
      "params" => %{"threadId" => thread_id}
    }

    try do
      send_message(port, message)
      :sent
    rescue
      ArgumentError -> :closed
    catch
      :exit, _reason -> :closed
    end
  end

  defp confirm_thread_unsubscribe(port) do
    case with_timeout_response(port, @thread_unsubscribe_id, @thread_unsubscribe_timeout_ms, "") do
      {:ok, %{"status" => status}} when status in ["unsubscribed", "notSubscribed", "notLoaded"] ->
        :ok

      {:ok, result} ->
        Logger.warning("Unexpected Codex thread unsubscribe response: #{inspect(result)}")
        :ok

      {:error, reason} ->
        Logger.warning("Unable to confirm Codex thread unsubscribe: #{inspect(reason)}")
        :ok
    end
  end

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         turn_options
       ) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => turn_options.workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => turn_options.approval_policy,
        "sandboxPolicy" => turn_options.sandbox_policy
      }
      |> put_if_present("model", turn_options.model)
      |> put_if_present("effort", turn_options.reasoning_effort)
      |> put_if_present("outputSchema", OutputSchema.for_provider(turn_options.output_schema))
      |> worker_params(turn_options.worker_policy)

    request_id = turn_options.request_id

    send_message(port, %{
      "method" => "turn/start",
      "id" => request_id,
      "params" => params
    })

    case await_response(port, request_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp normalize_thread_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_thread_name(_name), do: nil

  defp worker_params(params, nil), do: params

  defp worker_params(params, policy),
    do: params |> Map.drop(["sandbox", "sandboxPolicy"]) |> Map.merge(%{"permissions" => policy["profile"], "runtimeWorkspaceRoots" => [policy["cwd"]], "allowProviderModelFallback" => false})

  defp resume_worker_tools(params, %{worker_access: nil}), do: params
  # Native resume retains the original tools; the runner rejects any prior policy/tool-version mismatch.
  defp resume_worker_tools(params, %{worker_access: "FILE_SOURCE"}), do: params
  defp resume_worker_tools(params, _options), do: Map.put(params, "dynamicTools", [])

  defp verify_worker_response(_response, _workspace, %{worker_policy: nil}), do: :ok

  defp verify_worker_response(response, workspace, options) do
    if get_in(response, ["activePermissionProfile", "id"]) == options.worker_policy["profile"] and
         response["approvalPolicy"] == "never" and response["model"] == options.model and
         response["cwd"] == workspace and response["runtimeWorkspaceRoots"] == [workspace] and response["reasoningEffort"] == options.reasoning_effort and
         get_in(response, ["thread", "cwd"]) == workspace,
       do: :ok,
       else: {:error, :worker_effective_policy_mismatch}
  end

  defp worker_catalog_empty(_port, %{worker_policy: nil}), do: :ok

  defp worker_catalog_empty(port, %{thread_id: thread_id}) do
    send_message(port, %{"method" => "mcpServerStatus/list", "id" => @worker_catalog_id, "params" => %{"threadId" => thread_id}})

    case await_response(port, @worker_catalog_id) do
      {:ok, %{"data" => servers, "nextCursor" => nil}} when is_list(servers) ->
        if Enum.all?(servers, &disabled_worker_server?/1), do: :ok, else: {:error, :worker_connector_catalog_not_empty}

      {:error, _} = error ->
        error

      _ ->
        {:error, :worker_connector_catalog_not_empty}
    end
  end

  defp disabled_worker_server?(%{"tools" => tools, "resources" => [], "resourceTemplates" => []} = server) when tools == %{} do
    server["toolsError"] == nil and (server["runtimeStatus"] == "disabled" or server["name"] == "openai-api-key-local-confirmation")
  end

  defp disabled_worker_server?(_server), do: false

  defp normalize_project_id(project_id) when is_binary(project_id) do
    case String.trim(project_id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_project_id(_project_id), do: nil

  defp normalize_project_root(project_root) when is_binary(project_root) do
    case String.trim(project_root) do
      "" -> nil
      path -> Path.expand(path)
    end
  end

  defp normalize_project_root(_project_root), do: nil

  defp normalize_section_id(section_id) when is_binary(section_id) do
    case String.trim(section_id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_section_id(_section_id), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    timeout_ms = Config.settings!().codex.turn_timeout_ms
    state = Process.get(@turn_event_state_key, %{})

    cond do
      Map.get(state, :overflow, false) ->
        {:error, :worker_event_buffer_overflow}

      state[:scope] == :exact_turn ->
        Process.put(@turn_event_state_key, %{state | early: Enum.reverse(state.early), bytes: 0})
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      true ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    if turn_deadline_expired?() do
      {:error, :turn_timeout}
    else
      receive_loop_until_event(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
    end
  end

  defp receive_loop_until_event(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    case pop_early_turn_event() do
      {:ok, payload} ->
        dispatch_incoming(port, on_message, Jason.encode!(payload), timeout_ms, tool_executor, auto_approve_requests)
        |> case do
          {:continue, :ignored} -> receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
          result -> result
        end

      :empty ->
        receive_live_event(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
    end
  end

  defp receive_live_event(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    timeout_ms = effective_turn_timeout(timeout_ms)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        case dispatch_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests) do
          {:continue, :ignored} -> receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
          result -> result
        end

      {^port, {:data, {:noeol, chunk}}} ->
        if exact_turn_scope?() and byte_size(pending_line) + byte_size(chunk) > @port_line_bytes do
          {:error, :worker_event_buffer_overflow}
        else
          receive_loop(
            port,
            on_message,
            timeout_ms,
            pending_line <> to_string(chunk),
            tool_executor,
            auto_approve_requests
          )
        end

      {^port, {:exit_status, status}} ->
        Process.put({@owned_exit_key, port}, status)
        if turn_deadline_expired?(), do: {:error, :turn_timeout}, else: {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp dispatch_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    timeout = effective_turn_timeout(timeout_ms)

    cond do
      exact_turn_scope?() and byte_size(data) > @port_line_bytes -> {:error, :worker_event_buffer_overflow}
      turn_deadline_expired?() -> {:error, :turn_timeout}
      true -> handle_incoming(port, on_message, data, timeout, tool_executor, auto_approve_requests)
    end
  end

  defp pop_early_turn_event do
    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn, early: [payload | rest]} = state ->
        Process.put(@turn_event_state_key, %{state | early: rest})
        {:ok, payload}

      _ ->
        :empty
    end
  end

  defp turn_deadline_expired? do
    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn, deadline: deadline} -> System.monotonic_time(:millisecond) >= deadline
      _ -> false
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        handle_method_event(port, on_message, payload, payload_string, timeout_ms, tool_executor, auto_approve_requests)

      {:ok, payload} ->
        emit_other_message(port, on_message, payload, payload_string, timeout_ms, tool_executor, auto_approve_requests)

      {:error, _reason} ->
        emit_malformed_message(port, on_message, payload_string, timeout_ms, tool_executor, auto_approve_requests)
    end
  end

  defp handle_method_event(port, on_message, payload, raw, timeout, tool_executor, auto_approve) do
    case payload["method"] do
      "turn/completed" -> handle_completed_event(port, on_message, payload, raw)
      "error" -> handle_error_method_event(port, on_message, payload, raw, timeout, tool_executor, auto_approve)
      "turn/failed" -> handle_terminal_event(port, on_message, payload, raw, :failed)
      "turn/cancelled" -> handle_terminal_event(port, on_message, payload, raw, :cancelled)
      method -> handle_scoped_method(port, on_message, payload, raw, method, timeout, tool_executor, auto_approve)
    end
  end

  defp handle_error_method_event(port, on_message, %{"params" => params} = payload, raw, timeout, executor, auto)
       when is_map(params),
       do: handle_error_event(port, on_message, payload, raw, timeout, executor, auto)

  defp handle_error_method_event(port, on_message, payload, raw, timeout, executor, auto),
    do: handle_scoped_method(port, on_message, payload, raw, "error", timeout, executor, auto)

  defp handle_completed_event(port, on_message, payload, raw) do
    with :match <- exact_event_scope(payload, :terminal),
         :ok <- validate_completion_status(payload) do
      emit_turn_event(on_message, :turn_completed, payload, raw, port, payload)
      {:ok, :turn_completed}
    else
      :ignore -> {:continue, :ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_completion_status(payload) do
    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn} ->
        turn = get_in(payload, ["params", "turn"])

        case {turn["status"], Map.get(turn, "error")} do
          {"completed", nil} -> :ok
          {status, _} when status in ["failed", "interrupted"] -> {:error, {:turn_failed, turn}}
          {status, _} -> {:error, {:worker_turn_status_invalid, status}}
        end

      _ ->
        :ok
    end
  end

  defp handle_error_event(port, on_message, payload, raw, timeout, tool_executor, auto_approve) do
    case exact_error_scope(payload) do
      :legacy ->
        handle_turn_method(port, on_message, payload, raw, "error", timeout, tool_executor, auto_approve)

      :ignore ->
        {:continue, :ignored}

      {:error, reason} ->
        {:error, reason}

      {:retry, true} ->
        emit_message(on_message, :notification, %{payload: payload, raw: raw}, metadata_from_message(port, payload))
        receive_loop(port, on_message, timeout, "", tool_executor, auto_approve)

      {:retry, false} ->
        {:error, {:worker_turn_error, get_in(payload, ["params", "error"])}}
    end
  end

  defp handle_terminal_event(port, on_message, payload, raw, kind) do
    case exact_event_scope(payload, :terminal) do
      :ignore ->
        {:continue, :ignored}

      {:error, reason} ->
        {:error, reason}

      :match ->
        params = payload["params"]
        event = if kind == :failed, do: :turn_failed, else: :turn_cancelled
        emit_turn_event(on_message, event, payload, raw, port, params)
        reason = if kind == :failed, do: {:turn_failed, params}, else: {:turn_cancelled, params}
        {:error, reason}
    end
  end

  defp handle_scoped_method(port, on_message, payload, raw, method, timeout, tool_executor, auto_approve) do
    result = if method in ["item/started", "item/completed"], do: exact_event_scope(payload, :item), else: :match

    case result do
      :ignore -> {:continue, :ignored}
      {:error, reason} -> {:error, reason}
      :match -> handle_turn_method(port, on_message, payload, raw, method, timeout, tool_executor, auto_approve)
    end
  end

  defp emit_other_message(port, on_message, payload, raw, timeout, tool_executor, auto_approve) do
    emit_message(on_message, :other_message, %{payload: payload, raw: raw}, metadata_from_message(port, payload))
    receive_loop(port, on_message, timeout, "", tool_executor, auto_approve)
  end

  defp emit_malformed_message(port, on_message, raw, timeout, tool_executor, auto_approve) do
    log_non_json_stream_line(raw, "turn stream")

    if protocol_message_candidate?(raw) do
      emit_message(on_message, :malformed, %{payload: raw, raw: raw}, metadata_from_message(port, %{raw: raw}))
    end

    receive_loop(port, on_message, timeout, "", tool_executor, auto_approve)
  end

  defp exact_error_scope(payload) do
    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn, identity: {thread_id, turn_id}} ->
        params = payload["params"]
        classify_error_scope(params, thread_id, turn_id)

      _ ->
        :legacy
    end
  end

  defp classify_error_scope(params, thread_id, turn_id) do
    case event_identity_scope(params, thread_id, turn_id, "turnId") do
      :missing -> {:error, {:worker_event_identity_missing, "error"}}
      :foreign -> :ignore
      :matching -> classify_retryability(params)
    end
  end

  defp classify_retryability(%{"willRetry" => true}), do: {:retry, true}
  defp classify_retryability(%{"willRetry" => false}), do: {:retry, false}
  defp classify_retryability(params), do: {:error, {:worker_error_notification_invalid, params}}

  defp event_identity_scope(params, thread_id, turn_id, turn_key) do
    event_thread = params["threadId"]
    event_turn = params[turn_key]

    cond do
      not is_binary(event_thread) or not is_binary(event_turn) -> :missing
      event_thread == thread_id and event_turn == turn_id -> :matching
      true -> :foreign
    end
  end

  defp exact_event_scope(payload, kind) do
    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn, identity: {thread_id, turn_id}} ->
        params = Map.get(payload, "params", %{})
        event_thread = Map.get(params, "threadId")
        event_turn = if kind == :terminal, do: get_in(params, ["turn", "id"]), else: Map.get(params, "turnId")

        cond do
          not is_binary(event_thread) or not is_binary(event_turn) ->
            {:error, {:worker_event_identity_missing, payload["method"]}}

          event_thread == thread_id and event_turn == turn_id ->
            :match

          true ->
            :ignore
        end

      _ ->
        :match
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    attributed = bound_file_tool_request?(payload, method, tool_executor)

    if exact_turn_scope?() and Map.has_key?(payload, "id") and not attributed do
      {:error, :worker_request_attribution_unsupported}
    else
      process_turn_method(
        port,
        on_message,
        payload,
        payload_string,
        method,
        timeout_ms,
        tool_executor,
        auto_approve_requests
      )
    end
  end

  defp bound_file_tool_request?(%{"id" => id, "params" => params}, "item/tool/call", executor) do
    Process.get({__MODULE__, :file_tool_turn}) == true and is_function(executor, 3) and
      (is_integer(id) or is_binary(id)) and valid_file_request_identity?(params)
  end

  defp bound_file_tool_request?(_payload, _method, _executor), do: false

  defp valid_file_request_identity?(%{"threadId" => thread, "turnId" => turn, "callId" => call}) do
    match?(%{identity: {^thread, ^turn}}, Process.get(@turn_event_state_key)) and is_binary(call) and call != ""
  end

  defp valid_file_request_identity?(_params), do: false

  defp process_turn_method(port, on_message, payload, payload_string, method, timeout_ms, tool_executor, auto_approve_requests) do
    metadata = metadata_from_message(port, payload)
    record_mcp_approval_item(method, payload)

    result =
      maybe_handle_approval_request(
        port,
        method,
        payload,
        payload_string,
        on_message,
        metadata,
        tool_executor,
        auto_approve_requests
      )

    context = %{
      port: port,
      on_message: on_message,
      payload: payload,
      raw: payload_string,
      method: method,
      timeout: timeout_ms,
      executor: tool_executor,
      auto_approve: auto_approve_requests,
      metadata: metadata
    }

    handle_turn_method_result(result, context)
  end

  defp handle_turn_method_result(:input_required, context) do
    emit_message(context.on_message, :turn_input_required, %{payload: context.payload, raw: context.raw}, context.metadata)
    {:error, {:turn_input_required, context.payload}}
  end

  defp handle_turn_method_result(:approved, context),
    do: receive_loop(context.port, context.on_message, context.timeout, "", context.executor, context.auto_approve)

  defp handle_turn_method_result(:approval_required, context) do
    emit_message(context.on_message, :approval_required, %{payload: context.payload, raw: context.raw}, context.metadata)
    {:error, {:approval_required, context.payload}}
  end

  defp handle_turn_method_result(:unhandled, context) do
    if needs_input?(context.method, context.payload) do
      handle_turn_input_required(context)
    else
      emit_message(context.on_message, :notification, %{payload: context.payload, raw: context.raw}, context.metadata)
      Logger.debug("Codex notification: #{inspect(context.method)}")
      receive_loop(context.port, context.on_message, context.timeout, "", context.executor, context.auto_approve)
    end
  end

  defp handle_turn_input_required(context) do
    emit_message(context.on_message, :turn_input_required, %{payload: context.payload, raw: context.raw}, context.metadata)
    {:error, {:turn_input_required, context.payload}}
  end

  defp exact_turn_scope? do
    match?(%{scope: :exact_turn}, Process.get(@turn_event_state_key))
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result = invoke_tool_executor(tool_executor, tool_name, arguments, params) |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp invoke_tool_executor(executor, name, arguments, params) when is_function(executor, 3), do: executor.(name, arguments, params)
  defp invoke_tool_executor(executor, name, arguments, _params), do: executor.(name, arguments)

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _auto_approve_requests
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         _auto_approve_requests
       ) do
    case scoped_mcp_approval_answer(params) do
      {:ok, question_id} ->
        send_message(port, %{
          "id" => id,
          "result" => %{"answers" => %{question_id => %{"answers" => ["Approve Once"]}}}
        })

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: "Approve Once"},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp record_mcp_approval_item("item/started", %{"params" => %{"item" => %{"id" => item_id} = item}})
       when is_binary(item_id) do
    case Process.get(@mcp_approval_state_key) do
      %{items: items} = state -> Process.put(@mcp_approval_state_key, %{state | items: Map.put(items, item_id, item)})
      _other -> :ok
    end
  end

  defp record_mcp_approval_item(_method, _payload), do: :ok

  defp scoped_mcp_approval_answer(%{"itemId" => item_id, "questions" => [question]})
       when is_binary(item_id) do
    with %{items: items, allowed: allowed, expected_issue_key: expected_issue_key} = state <-
           Process.get(@mcp_approval_state_key),
         %{} = item <- Map.get(items, item_id),
         %{} = approval <-
           Enum.find(allowed, &scoped_approval_matches_item?(&1, item)),
         ^expected_issue_key <- approval.issue_key,
         true <- scoped_approval_arguments?(approval, approval_item_arguments(item)),
         {:ok, question_id} <- scoped_approval_question(question, item_id, approval.tool) do
      Process.put(@mcp_approval_state_key, %{
        state
        | items: Map.delete(items, item_id),
          allowed: List.delete(allowed, approval)
      })

      {:ok, question_id}
    else
      _other -> :error
    end
  end

  defp scoped_mcp_approval_answer(_params), do: :error

  defp scoped_approval_matches_item?(%{server: server, tool: tool}, item) do
    item["type"] in ["mcpToolCall", "mcp_tool_call"] and
      item["server"] == server and item["tool"] == tool
  end

  defp scoped_approval_matches_item?(_approval, _item), do: false

  defp approval_item_arguments(%{"arguments" => arguments}) when is_map(arguments), do: arguments

  defp approval_item_arguments(%{"arguments" => json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = arguments} -> arguments
      _other -> %{}
    end
  end

  defp approval_item_arguments(_item), do: %{}

  defp scoped_approval_arguments?(%{tool: "jira_add_comment", issue_key: issue_key, body_equals: body}, arguments) do
    Enum.sort(Map.keys(arguments)) == ["body", "issue_key"] and
      arguments == %{"issue_key" => issue_key, "body" => body}
  end

  defp scoped_approval_arguments?(%{tool: "jira_update_issue", issue_key: issue_key, labels_equals: labels}, arguments) do
    with ["fields", "issue_key"] <- Enum.sort(Map.keys(arguments)),
         ^issue_key <- arguments["issue_key"],
         fields_json when is_binary(fields_json) <- arguments["fields"],
         {:ok, %{"labels" => actual_labels} = fields} <- Jason.decode(fields_json),
         true <- Map.keys(fields) == ["labels"],
         true <- is_list(actual_labels),
         true <- Enum.uniq(actual_labels) == actual_labels do
      MapSet.new(actual_labels) == MapSet.new(labels)
    else
      _other -> false
    end
  end

  defp scoped_approval_arguments?(_approval, _arguments), do: false

  defp scoped_approval_question(
         %{
           "header" => "Approve app tool call?",
           "id" => question_id,
           "isOther" => false,
           "isSecret" => false,
           "options" => options,
           "question" => question_text
         },
         item_id,
         tool
       )
       when is_list(options) and tool in ["jira_add_comment", "jira_update_issue"] do
    labels =
      Enum.map(options, fn
        %{"label" => label} -> label
        _option -> nil
      end)

    if question_id == "mcp_tool_call_approval_#{item_id}" and
         question_text == "The Jira MCP server wants to run the tool \"#{tool}\", which may modify or delete data. Allow this action?" and
         labels == ["Approve Once", "Approve this Session", "Deny", "Cancel"] do
      {:ok, question_id}
    else
      :error
    end
  end

  defp scoped_approval_question(_question, _item_id, _tool), do: :error

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, effective_turn_timeout(Config.settings!().codex.read_timeout_ms), "")
  end

  defp effective_turn_timeout(timeout_ms) do
    timeout_ms =
      case Process.get(@native_read_deadline_key) do
        nil -> timeout_ms
        deadline -> min(timeout_ms, max(deadline - System.monotonic_time(:millisecond), 0))
      end

    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn, deadline: deadline} ->
        min(timeout_ms, max(deadline - System.monotonic_time(:millisecond), 0))

      _ ->
        timeout_ms
    end
  end

  defp await_mcp_tool_response(port, deadline_ms, pending_line) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case Jason.decode(pending_line <> to_string(chunk)) do
          {:ok, payload} -> handle_mcp_tool_payload(port, deadline_ms, payload)
          {:error, _reason} -> {:error, :mcp_tool_protocol_invalid}
        end

      {^port, {:data, {:noeol, chunk}}} ->
        if byte_size(pending_line) + byte_size(chunk) > @port_line_bytes,
          do: {:error, :mcp_tool_result_too_large},
          else: await_mcp_tool_response(port, deadline_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        Process.put({@owned_exit_key, port}, status)
        {:error, {:port_exit, status}}
    after
      remaining_ms -> {:error, :mcp_tool_response_timeout}
    end
  end

  defp handle_mcp_tool_payload(_port, _deadline_ms, %{"id" => @mcp_tool_call_id, "result" => %{"isError" => true}}),
    do: {:error, :mcp_tool_error}

  defp handle_mcp_tool_payload(_port, _deadline_ms, %{"id" => @mcp_tool_call_id, "result" => %{} = result}),
    do: {:ok, result}

  defp handle_mcp_tool_payload(_port, _deadline_ms, %{"id" => @mcp_tool_call_id, "error" => _error}),
    do: {:error, :mcp_tool_call_rejected}

  defp handle_mcp_tool_payload(_port, _deadline_ms, %{"id" => _other_id}), do: {:error, :mcp_tool_approval_required}

  defp handle_mcp_tool_payload(port, deadline_ms, %{"method" => method} = payload) do
    if needs_input?(method, payload) or String.contains?(String.downcase(method), "approval") or
         String.ends_with?(method, "requestUserInput") do
      {:error, :mcp_tool_approval_required}
    else
      await_mcp_tool_response(port, deadline_ms, "")
    end
  end

  defp handle_mcp_tool_payload(_port, _deadline_ms, _payload), do: {:error, :mcp_tool_protocol_invalid}

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    timeout_ms = effective_turn_timeout(timeout_ms)

    if turn_deadline_expired?() do
      {:error, :turn_timeout}
    else
      with_timeout_response_loop(port, request_id, timeout_ms, pending_line)
    end
  end

  defp with_timeout_response_loop(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        if Process.get(@native_read_deadline_key) != nil and byte_size(pending_line) + byte_size(chunk) > 4_194_304 do
          {:error, :native_history_exceeds_read_budget}
        else
          with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))
        end

      {^port, {:exit_status, status}} ->
        Process.put({@owned_exit_key, port}, status)
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        if exact_turn_scope?() and turn_deadline_expired?() do
          {:error, :turn_timeout}
        else
          {:error, :response_timeout}
        end
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    if turn_deadline_expired?() do
      {:error, :turn_timeout}
    else
      handle_response_within_deadline(port, request_id, data, timeout_ms)
    end
  end

  defp handle_response_within_deadline(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, response} when is_map(response) ->
        if Process.get(@native_read_deadline_key) != nil do
          handle_native_read_response(port, request_id, timeout_ms, response, byte_size(payload))
        else
          handle_response_payload(port, request_id, timeout_ms, response)
        end

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp handle_native_read_response(port, request_id, timeout, response, bytes) do
    cond do
      bytes > 4_194_304 -> {:error, :native_history_exceeds_read_budget}
      Map.has_key?(response, "method") and Map.has_key?(response, "id") -> {:error, :native_read_requests_unsupported}
      Map.has_key?(response, "method") -> with_timeout_response(port, request_id, timeout, "")
      true -> handle_response_payload(port, request_id, timeout, response)
    end
  end

  defp handle_response_payload(_port, request_id, _timeout, %{"id" => request_id, "error" => error}),
    do: {:error, {:response_error, error}}

  defp handle_response_payload(_port, request_id, _timeout, %{"id" => request_id, "result" => result}),
    do: {:ok, result}

  defp handle_response_payload(_port, request_id, _timeout, %{"id" => request_id} = response),
    do: {:error, {:response_error, response}}

  defp handle_response_payload(port, request_id, timeout, response) do
    record_mcp_startup_status(response)

    if unsupported_strict_request?(response) do
      {:error, :worker_request_attribution_unsupported}
    else
      handle_interleaved_response(port, request_id, timeout, response)
    end
  end

  defp unsupported_strict_request?(%{"method" => method} = response) when is_binary(method),
    do: (exact_turn_scope?() or Process.get(@native_read_deadline_key) != nil) and Map.has_key?(response, "id")

  defp unsupported_strict_request?(_response), do: false

  defp handle_interleaved_response(port, request_id, timeout, response) do
    case buffer_early_turn_event(response) do
      :overflow ->
        {:error, :worker_event_buffer_overflow}

      _ ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(response)}")
        with_timeout_response(port, request_id, timeout, "")
    end
  end

  defp buffer_early_turn_event(%{"method" => method} = payload) when is_binary(method) do
    if early_turn_event_method?(method), do: enqueue_early_turn_event(payload), else: :ok
  end

  defp buffer_early_turn_event(_payload), do: :ok

  defp early_turn_event_method?(method),
    do: String.starts_with?(method, "turn/") or String.starts_with?(method, "item/") or method == "error"

  defp enqueue_early_turn_event(payload) do
    case Process.get(@turn_event_state_key) do
      %{scope: :exact_turn, identity: nil} = state -> append_early_turn_event(state, payload)
      _ -> :ok
    end
  end

  defp append_early_turn_event(%{overflow: true}, _payload), do: :overflow

  defp append_early_turn_event(%{early: frames, bytes: bytes} = state, payload) do
    size = byte_size(Jason.encode!(payload))

    if length(frames) >= 256 or bytes + size > 1_048_576 do
      Process.put(@turn_event_state_key, Map.put(state, :overflow, true))
      :overflow
    else
      Process.put(@turn_event_state_key, %{state | early: [payload | frames], bytes: bytes + size})
      :ok
    end
  end

  defp await_required_mcp_servers(_port, [], _timeout_ms), do: :ok

  defp await_required_mcp_servers(port, required_servers, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    await_required_mcp_servers(port, required_servers, deadline_ms, "")
  end

  defp await_required_mcp_servers(port, required_servers, deadline_ms, pending_line) do
    statuses = Process.get(@mcp_startup_statuses_key, %{})

    case required_mcp_servers_state(required_servers, statuses) do
      :ready ->
        :ok

      {:failed, server, details} ->
        {:error, {:required_mcp_server_failed, server, details}}

      {:waiting, waiting_servers} ->
        receive_required_mcp_status(port, required_servers, waiting_servers, deadline_ms, pending_line)
    end
  end

  defp receive_required_mcp_status(port, required_servers, waiting_servers, deadline_ms, pending_line) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        payload = pending_line <> to_string(chunk)
        record_mcp_status_line(payload)
        await_required_mcp_servers(port, required_servers, deadline_ms, "")

      {^port, {:data, {:noeol, chunk}}} ->
        await_required_mcp_servers(
          port,
          required_servers,
          deadline_ms,
          pending_line <> to_string(chunk)
        )

      {^port, {:exit_status, status}} ->
        Process.put({@owned_exit_key, port}, status)
        {:error, {:port_exit, status}}
    after
      remaining_ms ->
        {:error, {:required_mcp_servers_unavailable, waiting_servers}}
    end
  end

  defp record_mcp_status_line(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = message} -> record_mcp_startup_status(message)
      {:error, _reason} -> log_non_json_stream_line(payload, "MCP startup stream")
    end
  end

  defp record_mcp_startup_status(%{
         "method" => "mcpServer/startupStatus/updated",
         "params" => %{"name" => name, "status" => status} = params
       })
       when is_binary(name) and is_binary(status) do
    case Process.get(@mcp_startup_statuses_key) do
      %{} = statuses ->
        Process.put(
          @mcp_startup_statuses_key,
          Map.put(statuses, name, %{
            "status" => String.downcase(status),
            "error" => params["error"],
            "failure_reason" => params["failureReason"]
          })
        )

      _not_tracking ->
        :ok
    end

    :ok
  end

  defp record_mcp_startup_status(_message), do: :ok

  defp required_mcp_servers_state(required_servers, statuses) do
    Enum.reduce_while(required_servers, :ready, fn server, result ->
      case Map.get(statuses, server) do
        %{"status" => "ready"} ->
          {:cont, result}

        %{"status" => status} = details when status in ["failed", "error", "cancelled"] ->
          {:halt, {:failed, server, details}}

        _other ->
          {:cont, add_waiting_mcp_server(result, server)}
      end
    end)
    |> case do
      {:waiting, servers} -> {:waiting, Enum.reverse(servers)}
      other -> other
    end
  end

  defp add_waiting_mcp_server(:ready, server), do: {:waiting, [server]}
  defp add_waiting_mcp_server({:waiting, servers}, server), do: {:waiting, [server | servers]}

  defp normalize_required_mcp_servers(servers) when is_list(servers) do
    servers
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_required_mcp_servers(_servers), do: []

  defp ensure_required_apps(_port, [], _thread_id), do: :ok

  defp ensure_required_apps(port, required_apps, thread_id) do
    send_message(port, %{
      "id" => @apps_installed_id,
      "method" => "app/installed",
      "params" => %{"forceRefresh" => true, "threadId" => thread_id}
    })

    case await_response(port, @apps_installed_id) do
      {:ok, %{"apps" => apps}} when is_list(apps) ->
        required_apps_state(required_apps, apps)

      {:ok, response} ->
        {:error, {:required_apps_invalid_response, response}}

      {:error, reason} ->
        {:error, {:required_apps_unavailable, required_apps, reason}}
    end
  end

  defp required_apps_state(required_apps, installed_apps) do
    Enum.reduce_while(required_apps, :ok, fn required_app, :ok ->
      case Enum.find(installed_apps, &app_matches?(&1, required_app)) do
        %{"enabled" => true, "callable" => true} ->
          {:cont, :ok}

        %{} = app ->
          details = Map.take(app, ["id", "runtimeName", "enabled", "callable"])
          {:halt, {:error, {:required_app_unavailable, required_app, details}}}

        nil ->
          {:halt, {:error, {:required_app_missing, required_app}}}
      end
    end)
  end

  defp app_matches?(app, required_app) when is_map(app) do
    required = normalize_app_identifier(required_app)

    [app["id"], app["runtimeName"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&(normalize_app_identifier(&1) == required))
  end

  defp app_matches?(_app, _required_app), do: false

  defp normalize_required_apps(apps) when is_list(apps) do
    apps
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_required_apps(_apps), do: []

  defp normalize_app_identifier(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    Process.delete({@owned_exit_key, port})

    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
