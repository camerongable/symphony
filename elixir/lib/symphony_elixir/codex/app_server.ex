defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @thread_name_set_id 4
  @thread_fork_id 5
  @thread_unsubscribe_id 6
  @thread_metadata_update_id 7
  @thread_section_move_id 8
  @thread_read_id 9
  @thread_archive_id 10
  @apps_installed_id 11
  @project_list_id 12
  @thread_list_id 13
  @mcp_tool_call_id 14
  @thread_list_page_size 100
  @thread_list_max_records 10_000
  @thread_list_source_kinds ~w(cli vscode exec appServer subAgent subAgentReview subAgentCompact subAgentThreadSpawn subAgentOther unknown)
  @thread_unsubscribe_timeout_ms 1_000
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @mcp_startup_statuses_key {__MODULE__, :mcp_startup_statuses}
  @mcp_approval_state_key {__MODULE__, :mcp_approval_state}
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
      thread_source: Keyword.get(opts, :thread_source, "symphony")
    }

    Process.put(@mcp_startup_statuses_key, %{})

    try do
      dynamic_tool_binding = DynamicTool.bind()

      with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
           {:ok, port} <-
             start_port(
               expanded_workspace,
               worker_host,
               dynamic_tool_binding,
               thread_options.gitlab_mcp_startup_timeout_sec
             ) do
        metadata = port_metadata(port, worker_host)

        with {:ok, configured_policies} <- session_policies(expanded_workspace, worker_host),
             {:ok, session_policies} <- scoped_session_policies(configured_policies, thread_options),
             {:ok, thread_ref} <-
               do_start_session(
                 port,
                 expanded_workspace,
                 session_policies,
                 dynamic_tool_binding,
                 thread_options
               ) do
          {:ok,
           %{
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
             workspace: expanded_workspace,
             worker_host: worker_host,
             dynamic_tool_binding: dynamic_tool_binding
           }}
        else
          {:error, reason} ->
            stop_port(port)
            {:error, reason}
        end
      end
    after
      Process.delete(@mcp_startup_statuses_key)
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
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
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
      end)

    Process.put(@mcp_approval_state_key, %{
      items: %{},
      allowed: allowed_mcp_tool_approvals,
      expected_issue_key: Map.get(issue, :identifier)
    })

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
               output_schema: Keyword.get(opts, :output_schema)
             }
           ) do
        {:ok, turn_id} ->
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
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port, thread_id: thread_id}) when is_port(port) do
    Process.unlink(port)

    try do
      unsubscribe_thread(port, thread_id)
    after
      stop_port(port)
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

  defp start_port(workspace, nil, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      launch_command = local_launch_command(dynamic_tool_binding, gitlab_mcp_startup_timeout_sec)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(launch_command)],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec)
       when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding, gitlab_mcp_startup_timeout_sec)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

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

  defp send_initialize(port) do
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

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
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

  defp valid_scoped_jira_approval?(%{server: "Jira", tool: "jira_add_comment", issue_key: issue_key, body_equals: body})
       when is_binary(issue_key) and is_binary(body),
       do: issue_key != "" and body != ""

  defp valid_scoped_jira_approval?(%{server: "Jira", tool: "jira_update_issue", issue_key: issue_key, labels_equals: labels})
       when is_binary(issue_key) and is_list(labels),
       do: issue_key != "" and labels != [] and Enum.all?(labels, &(is_binary(&1) and &1 != "")) and Enum.uniq(labels) == labels

  defp valid_scoped_jira_approval?(_approval), do: false

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding, thread_options) do
    with :ok <- send_initialize(port),
         {:ok, project_id} <- resolve_project_id(port, thread_options.project_id, thread_options.project_root),
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

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} ->
            {:ok, %{thread_id: thread_id, forked_from_thread_id: nil}}

          _ ->
            {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

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

    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => thread_id}}} when thread_id == thread_options.resume_thread_id ->
        {:ok, %{thread_id: thread_id, forked_from_thread_id: nil}}

      {:ok, %{"thread" => %{"id" => thread_id}}} ->
        {:error, {:resumed_thread_id_mismatch, thread_options.resume_thread_id, thread_id}}

      {:ok, payload} ->
        {:error, {:invalid_thread_payload, payload}}

      {:error, {:response_error, error}} ->
        maybe_fork_active_writer(port, workspace, session_policies, thread_options, error)

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
      |> put_if_present("outputSchema", turn_options.output_schema)

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
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
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
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
    metadata = metadata_from_message(port, payload)
    record_mcp_approval_item(method, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
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

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

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
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
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
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        record_mcp_startup_status(other)
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
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
