defmodule SymphonyElixir.Factory.NativeSourceBinding do
  @moduledoc "Separates a native writer's chat context from its attached source checkout."

  alias SymphonyElixir.Factory.{DesktopRequest, RunLedger, StageSchemas, Store, TaskLedger, Worktree}
  alias SymphonyElixir.PathSafety

  @emitter Path.expand("../../../scripts/emit-source-binding.py", __DIR__)
  @external_resource @emitter
  @digest :crypto.hash(:sha256, File.read!(@emitter)) |> Base.encode16(case: :lower)
  @tools ~w(mcp__codex_app__create_worktree mcp__codex_app__list_artifacts)

  @spec emitter_path() :: Path.t()
  def emitter_path, do: @emitter

  @spec emitter_sha256() :: String.t()
  def emitter_sha256, do: @digest

  @spec get(Store.connection(), String.t()) :: map() | nil
  def get(store, task_key), do: Store.one!(store, "SELECT * FROM native_source_bindings WHERE task_key = ?", [task_key])

  @spec bootstrap?(map()) :: boolean()
  def bootstrap?(request), do: metadata(request)["native_source_bootstrap"] == true

  @spec validate_request(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_request(store, request) do
    if bootstrap?(request) do
      with {:ok, task} <- TaskLedger.get(store, request["target_key"]),
           {:ok, run} <- RunLedger.get(store, task["run_id"]) do
        require_bootstrap_route(request, run, task)
      end
    else
      :ok
    end
  end

  defp require_bootstrap_route(request, run, task) do
    meta = metadata(request)
    route = meta["bootstrap_model_route"] || %{}

    identity_matches = bootstrap_identity?(request, run, task)
    valid = identity_matches and bootstrap_metadata?(request, meta) and bootstrap_model?(request, route)

    if valid, do: :ok, else: {:error, :native_source_bootstrap_route_mismatch}
  end

  defp bootstrap_identity?(request, run, task) do
    expected = %{"target_kind" => "TASK", "action" => "CREATE", "cwd" => run["repo_path"], "branch" => run["branch"]}

    TaskLedger.source_writer?(task) and run["kind"] == "DELIVERY" and run["factory_owned"] == 0 and
      is_binary(run["branch"]) and run["branch"] != "" and Map.take(request, Map.keys(expected)) == expected
  end

  defp bootstrap_metadata?(request, meta) do
    meta["workspace_mode"] == "CODEX_NATIVE" and String.ends_with?(request["request_key"], ":bootstrap") and
      is_binary(meta["expected_sha"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, meta["expected_sha"]) and meta["source_emitter_sha256"] == @digest
  end

  defp bootstrap_model?(request, route) when is_map(route) do
    expected = %{"model_class" => "fast", "resolved_role" => "workspace-maintainer", "reasoning_effort" => "low", "model" => request["model"]}
    request["reasoning_effort"] == "low" and Map.take(route, Map.keys(expected)) == expected
  end

  defp bootstrap_model?(_request, _route), do: false

  @spec record(Store.connection(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record(store, request, thread_id, proof) do
    with true <- bootstrap?(request) or {:error, :native_source_bootstrap_required},
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt},
         :ok <- validate_request(store, request),
         {:ok, task} <- TaskLedger.get(store, request["target_key"]),
         {:ok, run} <- RunLedger.get(store, task["run_id"]),
         true <- is_nil(get(store, task["task_key"])) or {:error, :native_source_already_bound},
         true <- (is_nil(task["workspace"]) and is_nil(run["worktree"])) or {:error, :native_source_existing_workspace},
         {:ok, receipt, command} <- evidence(request, thread_id, proof),
         {:ok, control, source} <- checkouts(run, receipt, proof),
         :ok <- attachment(receipt, control.path, source.path),
         :ok <- exclusive_paths(store, thread_id, control.path, source.path),
         :ok <- persist(store, request, task, thread_id, receipt, command, control, source) do
      {:ok, source}
    else
      {:error, _reason} = error -> error
    end
  end

  defp evidence(request, thread_id, %{"source_binding" => %{"evidence" => receipt, "command_proof" => command}})
       when is_map(receipt) and is_map(command) do
    with :ok <- StageSchemas.validate(command, StageSchemas.for_stage(:native_maintenance_command_proof)),
         true <- Regex.match?(~r/\Aexec-[0-9a-f-]+\z/, command["command_item"]["id"]) or {:error, :native_source_command_id_invalid},
         true <- command["thread_id"] == thread_id or {:error, :native_source_thread_mismatch},
         true <- command["command_item"]["cwd"] == receipt["source_cwd"] or {:error, :native_source_command_cwd_mismatch},
         {:ok, ^receipt} <- Jason.decode(command["command_item"]["output"]["text"]),
         true <- receipt["request_key"] == request["request_key"] or {:error, :native_source_request_mismatch},
         true <- receipt["emitter_sha256"] == @digest or {:error, :native_source_producer_changed},
         :ok <- verify_command(command["command_item"]["command"], receipt) do
      {:ok, receipt, command}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :native_source_stdout_mismatch}
    end
  end

  defp evidence(_request, _thread_id, _proof), do: {:error, :native_source_proof_required}

  defp verify_command(command, receipt) do
    {output, code} = System.cmd("python3", ["-B", @emitter, "--verify-command-base64", Base.encode64(command)], stderr_to_stdout: true)

    if code == 0 and Jason.decode(output) == {:ok, Map.drop(receipt, ~w(source_cwd head_sha))},
      do: :ok,
      else: {:error, :native_source_command_input_mismatch}
  end

  defp checkouts(run, receipt, proof) do
    opts = [expected_sha: receipt["head_sha"], clean: true, detached: true]

    with true <- (proof["cwd"] == receipt["source_cwd"] and proof["head_sha"] == receipt["head_sha"]) or {:error, :native_source_path_mismatch},
         true <- (is_binary(receipt["control_cwd"]) and is_binary(receipt["source_cwd"])) or {:error, :native_source_path_mismatch},
         {:ok, control} <- Worktree.validate_native(%{"path" => run["repo_path"]}, receipt["control_cwd"], opts),
         {:ok, source} <- Worktree.validate_native(%{"path" => run["repo_path"]}, receipt["source_cwd"], opts),
         true <-
           (control.path == receipt["control_cwd"] and source.path == receipt["source_cwd"] and control.path != source.path) or
             {:error, :native_source_path_mismatch} do
      {:ok, control, source}
    end
  end

  defp attachment(%{"artifact_output" => %{"artifacts" => artifacts}}, control, source) when is_list(artifacts) do
    active = Enum.filter(artifacts, &(is_map(&1) and &1["attachmentType"] == "worktree"))

    case active do
      [%{"identityKey" => ^source, "payload" => %{"root" => ^source, "workspaceRoot" => ^source, "sourceCwd" => ^control}}] -> :ok
      _other -> {:error, :native_source_attachment_unproven}
    end
  end

  defp exclusive_paths(store, thread, control, source) do
    conflict =
      Store.one!(
        store,
        """
        SELECT run_id FROM native_source_bindings WHERE thread_id = ?
          OR control_workspace IN (?, ?) OR source_workspace IN (?, ?) LIMIT 1
        """,
        [thread, control, source, control, source]
      )

    if is_nil(conflict), do: :ok, else: {:error, :native_source_binding_conflict}
  end

  defp persist(store, request, task, thread_id, receipt, command, control, source) do
    if receipt["head_sha"] == metadata(request)["expected_sha"] do
      Store.query!(
        store,
        """
        INSERT INTO native_source_bindings(run_id, task_key, thread_id, codex_project_id,
          control_workspace, source_workspace, attachment_identity, bootstrap_sha,
          bootstrap_request_key, bootstrap_turn_id, evidence_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          task["run_id"],
          task["task_key"],
          thread_id,
          request["codex_project_id"],
          control.path,
          source.path,
          source.path,
          source.sha,
          request["request_key"],
          command["turn_id"],
          Jason.encode!(%{"receipt" => receipt, "command" => command}),
          DateTime.utc_now() |> DateTime.to_iso8601()
        ]
      )

      :ok
    else
      {:error, :native_source_sha_mismatch}
    end
  end

  @spec validate_completion(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def validate_completion(store, request, attrs) do
    binding = if metadata(request)["maintenance_operation"], do: nil, else: get(store, request["target_key"])

    case binding do
      nil -> :ok
      binding -> validate_bound_completion(binding, request, attrs)
    end
  end

  @spec attach(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def attach(store, request, attrs) do
    if get(store, request["target_key"]) && request["action"] == "FOLLOWUP" && is_nil(metadata(request)["maintenance_operation"]) do
      attach_execution(attrs)
    else
      {:ok, attrs}
    end
  end

  defp attach_execution(%{"output" => output} = attrs) when is_map(output) do
    observed = attrs["source_execution"]
    retained = output["source_execution"]

    cond do
      not is_nil(observed) and not is_nil(retained) and observed != retained ->
        {:error, :native_source_execution_conflict}

      is_map(observed || retained) ->
        receipt = observed || retained
        {:ok, attrs |> Map.put("source_execution", receipt) |> Map.put("output", Map.put(output, "source_execution", receipt))}

      true ->
        {:ok, attrs}
    end
  end

  defp attach_execution(attrs), do: {:ok, attrs}

  defp validate_bound_completion(binding, %{"action" => "CREATE"}, attrs) do
    calls = get_in(attrs, ["output", "completed_tool_calls"])

    valid =
      attrs["thread_id"] == binding["thread_id"] and attrs["turn_id"] == binding["bootstrap_turn_id"] and is_list(calls) and
        Enum.all?(@tools, &bootstrap_tool?(calls, &1, binding, attrs))

    if valid, do: :ok, else: {:error, :native_source_bootstrap_calls_unproven}
  end

  defp validate_bound_completion(binding, request, attrs) do
    case attrs["source_execution"] do
      %{"thread_id" => thread, "turn_id" => turn, "turn_status" => "completed", "commands" => commands, "changed_paths" => paths}
      when is_list(commands) and commands != [] and is_list(paths) ->
        valid =
          execution_identity?(binding, request, attrs, thread, turn) and
            Enum.all?(commands, &source_command?(&1, binding["source_workspace"])) and
            Enum.all?(paths, &source_path?(&1, binding["source_workspace"]))

        if valid, do: :ok, else: {:error, :native_source_execution_mismatch}

      _other ->
        {:error, :native_source_execution_unproven}
    end
  end

  defp bootstrap_tool?(calls, tool, binding, attrs) do
    case Enum.filter(calls, &(is_map(&1) and &1["tool"] == tool)) do
      [call] ->
        tool_call?(call, tool) and call["thread_id"] == attrs["thread_id"] and call["turn_id"] == attrs["turn_id"] and
          bootstrap_tool_input?(tool, call["input"], binding)

      _other ->
        false
    end
  end

  defp bootstrap_tool_input?("mcp__codex_app__create_worktree", input, binding) when is_map(input),
    do: input["ref"] == binding["bootstrap_sha"] and input["allowAsync"] == true

  defp bootstrap_tool_input?("mcp__codex_app__list_artifacts", %{} = input, _binding), do: input == %{}
  defp bootstrap_tool_input?(_tool, _input, _binding), do: false

  defp execution_identity?(binding, request, attrs, thread, turn) do
    thread == binding["thread_id"] and thread == attrs["thread_id"] and turn == attrs["turn_id"] and
      request["verified_cwd"] == binding["source_workspace"]
  end

  defp source_command?(command, source) when is_map(command) do
    schema =
      StageSchemas.for_stage(:native_maintenance_command_proof)["properties"]["command_item"]
      |> put_in(["properties", "exitCode"], %{"type" => "integer"})

    StageSchemas.validate(command, schema) == :ok and command["cwd"] == source and
      Regex.match?(~r/\Aexec-[0-9a-f-]+\z/, command["id"])
  end

  defp source_command?(_command, _source), do: false

  defp source_path?(path, source) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path) do
      String.starts_with?(canonical, source <> "/")
    else
      _other -> false
    end
  end

  defp source_path?(_path, _source), do: false

  defp tool_call?(call, tool) when is_map(call), do: call["tool"] == tool and call["status"] == "completed" and call["isError"] != true and is_nil(call["error"])

  defp metadata(request) do
    case Jason.decode(request["metadata_json"] || "{}") do
      {:ok, value} when is_map(value) -> value
      _other -> %{}
    end
  end
end
