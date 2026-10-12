defmodule SymphonyElixir.Factory.WorkerFileTools do
  @moduledoc "Controller-owned descriptor file tools; native admission remains fenced pending containment and recovery acceptance."
  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLedger, WorkerEvidence, WorkerFileIO, WorkspaceAccess, Worktree}

  @max_file_bytes 262_144
  @max_output_bytes 16_384
  @blocked ~w(.git .codex .agents .env .ssh .aws .config .factory-file-io node_modules _build deps)

  @spec bind(Store.connection(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def bind(store, key, owner) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         true <- evidence["owner_id"] == owner or {:error, :file_worker_owner_mismatch},
         {:ok, binding} <- intact_binding(evidence),
         true <- file_writer?(binding) or {:error, :file_worker_policy_required} do
      {:ok, %{store: store, key: key, owner: owner, binding_sha256: evidence["binding_sha256"]}}
    end
  end

  @spec preflight(map(), Path.t()) :: :ok | {:error, term()}
  def preflight(%{store: store, key: key, owner: owner, binding_sha256: hash}, workspace) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         true <- {evidence["owner_id"], evidence["binding_sha256"]} == {owner, hash} or {:error, :file_worker_binding_changed},
         :ok <- matching(starting?(evidence), true, :file_worker_not_starting),
         {:ok, binding} <- intact_binding(evidence),
         :ok <- policy_workspace(binding, workspace),
         {:ok, access} <- WorkspaceAccess.validate(store, binding["reservation_key"], binding["reservation_generation"]),
         true <- access["canonical_path"] == workspace or {:error, :file_worker_workspace_mismatch},
         do: :ok
  end

  def preflight(_capability, _workspace), do: {:error, :file_worker_capability_required}

  @doc "Admits one turn only on the thread and process bound to the current controller capability."
  @spec turn_preflight(map(), map()) :: :ok | {:error, term()}
  def turn_preflight(%{store: store, key: key} = capability, %{workspace: workspace, metadata: %{} = metadata} = session) do
    process = %{"pid" => metadata[:codex_app_server_pid], "invocation_nonce" => session[:worker_invocation]}

    with :ok <- preflight(capability, workspace),
         {:ok, evidence} <- WorkerEvidence.get(store, key),
         :ok <- matching(evidence["status"], "THREAD_BOUND", :file_worker_not_thread_bound),
         :ok <- matching(evidence["thread_id"], session[:thread_id], :file_worker_identity_mismatch),
         {:ok, expected} <- decode_process(evidence["owner_process_json"]),
         :ok <- matching(expected, process, :file_worker_process_mismatch),
         {:ok, binding} <- intact_binding(evidence),
         :ok <- matching(binding["policy"], session[:worker_policy], :file_worker_policy_required),
         :ok <- current_tools(session),
         :ok <- matching(Map.take(binding, ~w(model reasoning_effort)), worker_allocation(session), :file_worker_inputs_changed),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]) do
      current_inputs(task, binding)
    end
  end

  def turn_preflight(_capability, _session), do: {:error, :file_worker_capability_required}

  defp worker_allocation(session), do: %{"model" => session[:model], "reasoning_effort" => session[:reasoning_effort]}

  defp current_tools(session), do: matching(get_in(session, [:dynamic_tool_binding, :tool_specs]), tool_specs(), :file_worker_tool_contract_changed)

  defp decode_process(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = process} -> {:ok, process}
      _ -> {:error, :file_worker_process_unbound}
    end
  end

  defp decode_process(_raw), do: {:error, :file_worker_process_unbound}

  defp policy_workspace(binding, workspace) do
    matching({file_writer?(binding), get_in(binding, ["policy", "cwd"])}, {true, workspace}, :file_worker_policy_required)
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      spec(
        "repo_read",
        "Read bounded UTF-8 source lines; returns the full-file SHA-256 for edits.",
        %{"path" => string(), "start_line" => %{"type" => "integer", "minimum" => 1}},
        ~w(path start_line)
      ),
      spec("repo_list", "List one source directory, without following symlinks or exposing control files.", %{"path" => string()}, ~w(path)),
      spec(
        "repo_write",
        "Replace a source file using its exact SHA-256, or create in an existing directory with expected_sha256=ABSENT. No Git or shell operations.",
        %{"path" => string(), "expected_sha256" => string(), "content" => string()},
        ~w(path expected_sha256 content)
      ),
      spec(
        "repo_delete",
        "Delete one regular source file using its exact SHA-256. No recursive deletion, Git or shell operations.",
        %{"path" => string(), "expected_sha256" => string()},
        ~w(path expected_sha256)
      ),
      spec(
        "repo_mkdir",
        "Create one source directory under an existing parent. Replays require the original creation identity; no recursive creation or shell operations.",
        %{"path" => string()},
        ~w(path)
      ),
      spec(
        "repo_read_binary",
        "Read a bounded base64 page of a regular source file; returns its full-file SHA-256 and next byte offset.",
        %{"path" => string(), "offset" => %{"type" => "integer", "minimum" => 0}},
        ~w(path offset)
      ),
      spec(
        "repo_write_binary",
        "Replace a bounded regular source file with canonical base64 bytes using its exact SHA-256, or ABSENT for a new file.",
        %{"path" => string(), "expected_sha256" => string(), "content_base64" => string()},
        ~w(path expected_sha256 content_base64)
      )
    ]
  end

  @spec tool_contract_sha256() :: String.t()
  def tool_contract_sha256, do: tool_specs() |> Jason.encode!() |> digest()

  defp string, do: %{"type" => "string"}

  defp spec(name, description, properties, required),
    do: %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}}

  @spec execute(map(), String.t(), term(), map()) :: map()
  def execute(capability, tool, arguments, identity) do
    result =
      with :ok <- valid_call(tool, arguments, identity),
           {:ok, _} <- authorize(capability, identity) do
        dispatch(capability, tool, arguments, identity)
      end

    case result do
      {:ok, value} -> output(true, value)
      {:error, reason} -> output(false, %{error: inspect(reason)})
    end
  end

  defp output(success, value) do
    text = Jason.encode!(value)

    if byte_size(text) <= @max_output_bytes,
      do: %{"success" => success, "contentItems" => [%{"type" => "inputText", "text" => text}]},
      else: %{"success" => false, "contentItems" => [%{"type" => "inputText", "text" => "{\"error\":\"file_worker_output_too_large\"}"}]}
  end

  defp valid_call(tool, arguments, identity) when is_map(arguments) and is_map(identity) do
    fields = call_fields(tool)

    valid =
      fields != [] and {identity["namespace"], identity["tool"]} == {nil, tool} and
        Enum.sort(Map.keys(arguments)) == Enum.sort(fields) and valid_identity?(identity)

    if valid, do: :ok, else: {:error, :file_worker_call_rejected}
  end

  defp valid_call(_tool, _arguments, _identity), do: {:error, :file_worker_call_rejected}
  defp call_fields("repo_read"), do: ~w(path start_line)
  defp call_fields("repo_list"), do: ~w(path)
  defp call_fields("repo_write"), do: ~w(path expected_sha256 content)
  defp call_fields("repo_delete"), do: ~w(path expected_sha256)
  defp call_fields("repo_mkdir"), do: ~w(path)
  defp call_fields("repo_read_binary"), do: ~w(path offset)
  defp call_fields("repo_write_binary"), do: ~w(path expected_sha256 content_base64)
  defp call_fields(_), do: []

  defp valid_identity?(identity),
    do: Enum.all?(~w(threadId turnId callId), &(is_binary(identity[&1]) and byte_size(identity[&1]) in 1..256))

  defp starting?(evidence), do: evidence["status"] in ~w(START_SENT THREAD_BOUND) and evidence["owner_stopped_at"] == nil

  defp active?(evidence),
    do: evidence["status"] == "TURN_BOUND" and evidence["owner_stopped_at"] == nil and evidence["owner_process_json"] != nil

  defp matching(value, value, _reason), do: :ok
  defp matching(_value, _expected, reason), do: {:error, reason}

  defp authorize(cap, identity) do
    with {:ok, evidence} <- WorkerEvidence.get(cap.store, cap.key),
         :ok <- matching({evidence["owner_id"], evidence["binding_sha256"]}, {cap.owner, cap.binding_sha256}, :file_worker_binding_changed),
         :ok <- matching(active?(evidence), true, :file_worker_not_active),
         :ok <- matching(native_identity(evidence), native_identity(identity), :file_worker_identity_mismatch),
         {:ok, binding} <- intact_binding(evidence),
         {:ok, access} <- WorkspaceAccess.validate(cap.store, binding["reservation_key"], binding["reservation_generation"]),
         {:ok, run} <- RunLedger.get(cap.store, evidence["run_id"]),
         {:ok, task} <- TaskLedger.get(cap.store, evidence["task_key"]),
         :ok <- matching({file_writer?(binding), access["mode"]}, {true, "SOURCE"}, :file_worker_policy_required),
         :ok <- current_inputs(task, binding),
         :ok <- matching(run["candidate_sha"] in [nil, binding["expected_sha"]], true, :file_worker_candidate_changed),
         {:ok, _} <- pinned_checkout(run, access, binding) do
      {:ok, access}
    end
  end

  defp native_identity(%{"thread_id" => thread, "turn_id" => turn}), do: {thread, turn}
  defp native_identity(%{"threadId" => thread, "turnId" => turn}), do: {thread, turn}

  defp current_inputs(task, binding) do
    fields = ~w(role model reasoning_effort prompt_sha256)
    matching(Map.take(task, fields), Map.take(binding, fields), :file_worker_inputs_changed)
  end

  defp pinned_checkout(run, access, binding) do
    options = [clean: false, detached: false, expected_branch: run["branch"], expected_sha: binding["expected_sha"]]
    Worktree.checkout_identity(%{"path" => run["repo_path"]}, access["canonical_path"], options)
  end

  defp intact_binding(evidence) do
    if digest(evidence["binding_json"]) == evidence["binding_sha256"], do: Jason.decode(evidence["binding_json"]), else: {:error, :file_worker_binding_corrupt}
  end

  defp file_writer?(binding),
    do:
      binding["role"] == "feature-writer" and binding["mode"] == "SOURCE" and get_in(binding, ["policy", "mode"]) == "FILE_SOURCE" and
        get_in(binding, ["policy", "source_access"]) == "read" and
        get_in(binding, ["policy", "file_tools_sha256"]) == tool_contract_sha256()

  defp dispatch(cap, "repo_write", args, identity), do: write(cap, args, identity)
  defp dispatch(cap, "repo_delete", args, identity), do: write(cap, args, identity)
  defp dispatch(cap, "repo_mkdir", args, identity), do: write(cap, args, identity)
  defp dispatch(cap, "repo_write_binary", args, identity), do: write(cap, args, identity)

  defp dispatch(cap, tool, args, identity) do
    Store.transaction!(cap.store, fn tx ->
      with {:ok, access} <- authorize(%{cap | store: tx}, identity),
           :ok <- valid_path(args["path"], tool == "repo_list") do
        inspect_path(tool, access, args)
      end
    end)
  end

  defp inspect_path("repo_list", access, args), do: file_io(access, "list", args)

  defp inspect_path("repo_read", access, %{"path" => path, "start_line" => start}) when is_integer(start) and start in 1..262_144 do
    with {:ok, %{"text" => raw, "sha256" => sha}} <- file_io(access, "read", %{"path" => path}),
         lines = String.split(raw, "\n"),
         true <- start <= length(lines) or {:error, :file_worker_line_out_of_range} do
      selected = lines |> Enum.drop(start - 1) |> Enum.take(100)
      text = Enum.join(selected, "\n")
      next = if start - 1 + length(selected) < length(lines), do: start + length(selected)

      if byte_size(text) <= @max_output_bytes,
        do: {:ok, %{sha256: sha, start_line: start, next_line: next, text: text}},
        else: {:error, :file_worker_output_too_large}
    end
  end

  defp inspect_path("repo_read_binary", access, %{"path" => path, "offset" => offset}) when is_integer(offset) and offset in 0..@max_file_bytes do
    with {:ok, %{"content_base64" => encoded, "sha256" => sha}} <- file_io(access, "read_binary", %{"path" => path}),
         {:ok, raw} <- Base.decode64(encoded),
         true <- offset <= byte_size(raw) or {:error, :file_worker_offset_out_of_range} do
      count = min(8_192, byte_size(raw) - offset)
      next = if offset + count < byte_size(raw), do: offset + count
      page = raw |> binary_part(offset, count) |> Base.encode64()
      {:ok, %{sha256: sha, offset: offset, next_offset: next, total_bytes: byte_size(raw), content_base64: page}}
    end
  end

  defp inspect_path(_tool, _path, _args), do: {:error, :file_worker_call_rejected}

  defp write(cap, args, identity) do
    with :ok <- valid_write(args),
         {:ok, operation} <- prepare_write(cap, args, identity) do
      decision = Store.transaction!(cap.store, fn tx -> apply_write(%{cap | store: tx}, args, identity, operation) end)

      case decision do
        {:dispatch, access} -> perform_write(cap, access, args, identity, operation)
        result -> result
      end
    end
  end

  defp valid_write(%{"expected_sha256" => expected, "content" => content}) when is_binary(expected) and is_binary(content) do
    if (expected == "ABSENT" or Regex.match?(~r/\A[0-9a-f]{64}\z/, expected)) and byte_size(content) <= @max_file_bytes and String.valid?(content) and not String.contains?(content, <<0>>),
      do: :ok,
      else: {:error, :file_worker_write_rejected}
  end

  defp valid_write(%{"expected_sha256" => expected, "content_base64" => encoded}) when is_binary(expected) and is_binary(encoded) do
    with true <- expected == "ABSENT" or Regex.match?(~r/\A[0-9a-f]{64}\z/, expected),
         true <- byte_size(encoded) <= 349_528,
         {:ok, raw} <- Base.decode64(encoded),
         true <- byte_size(raw) <= @max_file_bytes and Base.encode64(raw) == encoded,
         do: :ok,
         else: (_ -> {:error, :file_worker_write_rejected})
  end

  defp valid_write(%{"expected_sha256" => expected} = args) when is_binary(expected) and map_size(args) == 2 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, expected), do: :ok, else: {:error, :file_worker_write_rejected}
  end

  defp valid_write(%{"path" => _path} = args) when map_size(args) == 1, do: :ok

  defp valid_write(_), do: {:error, :file_worker_write_rejected}

  # Commit intent before disk changes so recovery reads the exact edit instead of recreating it.
  defp prepare_write(cap, args, identity) do
    Store.transaction!(cap.store, fn tx ->
      with {:ok, access} <- authorize(%{cap | store: tx}, identity),
           :ok <- valid_path(args["path"], false) do
        prepare_operation(tx, cap.key, identity["callId"], access, args)
      end
    end)
  end

  defp prepare_operation(store, key, call, access, args) do
    hash = digest(Jason.encode!(args))

    case operation(store, key, call) do
      nil ->
        if pending_operation?(store, key),
          do: {:error, :file_worker_edit_reconciliation_required},
          else: insert_operation(store, key, call, access, args, hash)

      existing ->
        reuse_operation(store, key, call, access, existing, args, hash)
    end
  end

  defp reuse_operation(store, key, call, access, existing, args, hash) do
    observed = Map.take(existing, ~w(arguments_sha256 path before_sha256 after_sha256))
    expected = %{"arguments_sha256" => hash, "path" => args["path"], "before_sha256" => before_digest(args), "after_sha256" => after_digest(args)}

    cond do
      observed != expected ->
        {:error, :file_worker_operation_conflict}

      existing["phase"] == "ABORTED" ->
        {:error, :file_worker_operation_aborted}

      existing["io_pending"] == 1 ->
        {:error, :file_worker_helper_exit_unproven}

      existing["phase"] == "PREPARED" and not valid_operation_receipt?(existing, access) ->
        {:error, :file_worker_helper_exit_unproven}

      existing["phase"] == "PREPARED" ->
        with {:ok, _receipt} <- recover_exit(store, key, call, access, 0, existing["io_binding_json"], existing["io_receipt_json"]) do
          Store.query!(store, "UPDATE worker_file_operations SET io_pending = 1 WHERE request_key = ? AND call_id = ?", [key, call])
          {:ok, operation(store, key, call)}
        end

      true ->
        {:ok, existing}
    end
  end

  defp pending_operation?(store, key),
    do: Store.one!(store, "SELECT call_id FROM worker_file_operations WHERE request_key = ? AND phase = 'PREPARED'", [key]) != nil

  defp valid_operation_receipt?(row, access) do
    identity =
      Map.take(row, ~w(request_key call_id arguments_sha256 path before_sha256 after_sha256))
      |> Map.put("invocation", row["io_invocation"])
      |> Map.merge(recovery_identity(row["request_key"], row["call_id"], access))

    WorkerFileIO.receipt_matches_binding?(row["io_receipt_json"], row["io_binding_json"], identity)
  end

  defp recovery_identity(key, call, access) do
    %{
      "root" => access["canonical_path"],
      "generation" => access["generation"],
      "request_key" => key,
      "call_id" => call,
      "reservation_key" => access["reservation_key"],
      "run_id" => access["run_id"],
      "workspace_binding_sha256" => digest(access["binding_json"])
    }
  end

  defp insert_operation(store, key, call, access, args, hash) do
    with {:ok, current} <- current_input_digest(access, args),
         :ok <- matching(current, before_digest(args), :file_worker_compare_failed),
         identity = operation_identity(key, call, access, args),
         {:ok, binding} <- WorkerFileIO.prepare_mutation(store, access, args, identity) do
      Store.query!(
        store,
        "INSERT INTO worker_file_operations(request_key, call_id, arguments_sha256, path, before_sha256, after_sha256, phase, io_pending, io_invocation, io_binding_json) VALUES (?, ?, ?, ?, ?, ?, 'PREPARED', 1, ?, ?)",
        [key, call, hash, args["path"], before_digest(args), after_digest(args), binding["invocation"], Jason.encode!(binding)]
      )

      {:ok, operation(store, key, call)}
    end
  end

  defp operation_identity(key, call, access, args) do
    %{
      "request_key" => key,
      "call_id" => call,
      "run_id" => access["run_id"],
      "path" => args["path"],
      "before_sha256" => before_digest(args),
      "after_sha256" => after_digest(args)
    }
  end

  defp apply_write(cap, args, identity, operation) do
    with {:ok, access} <- authorize(cap, identity),
         :ok <- valid_path(args["path"], false),
         {:ok, current} <- current_digest(access, args["path"]) do
      cond do
        after_matches?(access, operation, current) -> applied(cap, identity, operation)
        operation["phase"] == "APPLIED" -> {:error, :file_worker_replay_changed}
        current != operation["before_sha256"] -> {:error, :file_worker_compare_failed}
        true -> {:dispatch, access}
      end
    end
  end

  defp perform_write(cap, access, args, identity, operation) do
    with {:ok, %{"sha256" => written_sha}} <- mutation_io(cap, args, identity, operation),
         :ok <- matching(valid_written_sha?(operation, written_sha), true, :file_worker_write_unproven) do
      Store.transaction!(cap.store, fn tx -> finalize_write(%{cap | store: tx}, access, args, identity, operation) end)
    end
  end

  defp finalize_write(cap, access, args, identity, operation) do
    with {:ok, ^access} <- authorize(cap, identity),
         {:ok, after_sha} <- current_digest(access, args["path"]),
         :ok <- matching(after_matches?(access, operation, after_sha), true, :file_worker_write_unproven),
         do: applied(cap, identity, operation)
  end

  defp mutation_io(cap, args, identity, operation) do
    binding = Jason.decode!(operation["io_binding_json"])

    case WorkerFileIO.dispatch_mutation(binding, args, Map.get(cap, :file_io_transport)) do
      {status, value, receipt} when status in [:ok, :error] ->
        Store.query!(cap.store, "UPDATE worker_file_operations SET io_pending = 0, io_receipt_json = ? WHERE request_key = ? AND call_id = ?", [Jason.encode!(receipt), cap.key, identity["callId"]])
        if status == :error, do: reconcile(cap.store, cap.key)
        {status, value}

      {:error, _} = error ->
        error
    end
  end

  defp applied(cap, identity, operation) do
    Store.query!(cap.store, "UPDATE worker_file_operations SET phase = 'APPLIED', io_pending = 0 WHERE request_key = ? AND call_id = ?", [cap.key, identity["callId"]])
    result = %{path: operation["path"], status: "APPLIED"}
    {:ok, if(operation["after_sha256"] == "DIRECTORY", do: result, else: Map.put(result, :sha256, operation["after_sha256"]))}
  end

  defp operation(store, key, call), do: Store.one!(store, "SELECT * FROM worker_file_operations WHERE request_key = ? AND call_id = ?", [key, call])

  @doc "Read back uncertain edits without granting another write or starting another turn."
  @spec reconcile(Store.connection(), String.t()) :: :ok | {:error, term()}
  def reconcile(store, key) do
    Store.transaction!(store, fn tx ->
      with {:ok, evidence} <- WorkerEvidence.get(tx, key),
           {:ok, binding} <- intact_binding(evidence),
           true <- file_writer?(binding) or {:error, :file_worker_policy_required},
           {:ok, access} <- WorkspaceAccess.validate(tx, binding["reservation_key"], binding["reservation_generation"]) do
        reconcile_operations(tx, key, access)
      end
    end)
  end

  defp reconcile_operations(store, key, access) do
    rows =
      Store.query!(
        store,
        "SELECT path, after_sha256, call_id, arguments_sha256, io_receipt_json, io_pending, io_binding_json, io_invocation FROM worker_file_operations WHERE request_key = ? AND (phase = 'PREPARED' OR io_pending = 1)",
        [key]
      ).rows

    Enum.reduce_while(rows, :ok, fn row, :ok -> reconcile_operation(store, key, access, row) end)
  end

  defp reconcile_operation(store, key, access, [relative, expected, call, hash, receipt, pending, binding, invocation]) do
    effect = Map.take(operation(store, key, call), ~w(path before_sha256 after_sha256))

    identity =
      recovery_identity(key, call, access)
      |> Map.merge(%{"arguments_sha256" => hash, "invocation" => invocation})
      |> Map.merge(effect)

    result =
      with {:ok, stopped} <- recover_exit(store, key, call, access, pending, binding, receipt),
           valid? = WorkerFileIO.receipt_matches_binding?(stopped, binding, identity),
           true <- valid? or {:error, :file_worker_helper_exit_unproven},
           do: reconcile_outcome(store, key, call, access, relative, expected, stopped)

    case result do
      :aborted ->
        {:cont, :ok}

      :ok ->
        Store.query!(store, "UPDATE worker_file_operations SET phase = 'APPLIED' WHERE request_key = ? AND call_id = ?", [key, call])
        {:cont, :ok}

      error ->
        {:halt, error}
    end
  end

  defp reconcile_outcome(store, key, call, access, relative, expected, stopped) do
    if Jason.decode!(stopped)["disposition"] == "NO_SPAWN" do
      operation = operation(store, key, call)

      with :ok <- proven_edit(access, relative, operation["before_sha256"]) do
        Store.query!(store, "UPDATE worker_file_operations SET phase = 'ABORTED' WHERE request_key = ? AND call_id = ?", [key, call])
        :aborted
      end
    else
      case reconcile_after(store, key, call, access, relative, expected) do
        :ok -> :ok
        {:error, _} -> cancel_stopped_unchanged(store, key, call, access)
      end
    end
  end

  defp cancel_stopped_unchanged(store, key, call, access) do
    operation = operation(store, key, call)
    effect = Map.take(operation, ~w(path before_sha256 after_sha256))

    with :ok <- proven_edit(access, operation["path"], operation["before_sha256"]),
         {:ok, binding} <- Jason.decode(operation["io_binding_json"]),
         :ok <- WorkerFileIO.confirm_no_temporary(binding, effect) do
      Store.query!(store, "UPDATE worker_file_operations SET phase = 'ABORTED' WHERE request_key = ? AND call_id = ?", [key, call])
      :aborted
    end
  end

  defp reconcile_after(store, key, call, access, relative, "DIRECTORY") do
    with {:ok, current} <- current_digest(access, relative) do
      matches = after_matches?(access, operation(store, key, call), current)
      matching(matches, true, :file_worker_edit_reconciliation_required)
    end
  end

  defp reconcile_after(_store, _key, _call, access, relative, expected), do: proven_edit(access, relative, expected)

  defp recover_exit(store, key, call, access, 0, raw, receipt) do
    case Jason.decode(receipt || "") do
      {:ok, %{"recovery" => _}} ->
        valid? = WorkerFileIO.receipt_matches_binding?(receipt, raw, recovery_identity(key, call, access))

        with true <- valid? or {:error, :file_worker_helper_exit_unproven},
             {:ok, recovered} <- read_recovered_exit(raw, recovery_identity(key, call, access)),
             true <- same_recovered_receipt?(receipt, recovered) or {:error, :file_io_artifact_recovery_changed},
             do: persist_recovered_exit(store, key, call, recovered)

      _ ->
        {:ok, receipt}
    end
  end

  defp recover_exit(store, key, call, access, 1, raw, _receipt) when is_binary(raw) do
    with {:ok, recovered} <- read_recovered_exit(raw, recovery_identity(key, call, access)),
         do: persist_recovered_exit(store, key, call, recovered)
  end

  defp recover_exit(_store, _key, _call, _access, _pending, _invocation, _receipt), do: {:error, :file_worker_helper_exit_unproven}

  defp read_recovered_exit(raw, identity) do
    with {:ok, binding} when is_map(binding) <- Jason.decode(raw),
         true <- Map.take(binding, Map.keys(identity)) == identity or {:error, :file_io_recovery_binding_changed} do
      encode_recovered_exit(WorkerFileIO.recover_mutation(binding))
    else
      {:error, :file_io_recovery_binding_changed} = error -> error
      _ -> {:error, :file_worker_helper_exit_unproven}
    end
  end

  defp same_recovered_receipt?(cached, recovered) do
    case {Jason.decode(cached), Jason.decode(recovered)} do
      {{:ok, original}, {:ok, current}} ->
        original == current or (not Map.has_key?(current, "recovery") and Map.delete(original, "recovery") == current)

      _ ->
        false
    end
  end

  defp encode_recovered_exit({status, _value, receipt}) when status in [:ok, :error], do: {:ok, Jason.encode!(receipt)}
  defp encode_recovered_exit({:error, _} = error), do: error

  defp persist_recovered_exit(store, key, call, encoded) do
    Store.query!(store, "UPDATE worker_file_operations SET io_pending = 0, io_receipt_json = ? WHERE request_key = ? AND call_id = ?", [encoded, key, call])
    {:ok, encoded}
  end

  defp proven_edit(access, relative, expected) do
    with :ok <- valid_path(relative, false), {:ok, current} <- current_digest(access, relative) do
      matching(current, expected, :file_worker_edit_reconciliation_required)
    end
  end

  defp valid_path(relative, directory) when is_binary(relative) and byte_size(relative) in 1..1024 do
    if relative == "." and directory, do: :ok, else: validate_relative(relative)
  end

  defp valid_path(_relative, _directory), do: {:error, :file_worker_path_rejected}

  defp validate_relative(relative) do
    parts = String.split(relative, "/")

    valid =
      String.valid?(relative) and Path.type(relative) == :relative and Enum.all?(parts, &valid_part?/1) and
        not String.contains?(relative, [<<0>>, "\\", "\n", "\r"])

    if valid, do: :ok, else: {:error, :file_worker_path_rejected}
  end

  defp valid_part?(part), do: part not in ["", ".", ".."] and not blocked?(part)

  defp blocked?(part) do
    normalized = part |> String.normalize(:nfc) |> String.downcase()
    normalized in @blocked or String.starts_with?(normalized, ".env.") or String.starts_with?(normalized, ".symphony-")
  end

  defp current_digest(access, path) do
    with {:ok, %{"sha256" => sha}} <- file_io(access, "digest", %{"path" => path}), do: {:ok, sha}
  end

  defp current_input_digest(access, %{"path" => path, "content" => _content}) do
    with {:ok, %{"sha256" => sha}} <- file_io(access, "text_digest", %{"path" => path}), do: {:ok, sha}
  end

  defp current_input_digest(access, args), do: current_digest(access, args["path"])

  defp raw_file_io(access, operation, args),
    do: WorkerFileIO.request(access["canonical_path"], Jason.decode!(access["binding_json"]), operation, args)

  defp file_io(access, operation, args) do
    case raw_file_io(access, operation, args) do
      {status, value, _receipt} when status in [:ok, :error] -> {status, value}
      {:error, _} = error -> error
    end
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp before_digest(args), do: Map.get(args, "expected_sha256", "ABSENT")
  defp after_digest(%{"content" => content}), do: digest(content)
  defp after_digest(%{"content_base64" => encoded}), do: encoded |> Base.decode64!() |> digest()
  defp after_digest(%{"expected_sha256" => _expected}), do: "ABSENT"
  defp after_digest(_args), do: "DIRECTORY"

  defp valid_written_sha?(%{"after_sha256" => "DIRECTORY", "io_invocation" => nonce}, observed) when is_binary(observed),
    do: Regex.match?(~r/\ADIRECTORY:[1-9][0-9]*:[1-9][0-9]*:[0-9a-f]{64}\z/, observed) and String.ends_with?(observed, ":" <> nonce)

  defp valid_written_sha?(operation, observed), do: observed == operation["after_sha256"]

  defp after_matches?(access, %{"after_sha256" => "DIRECTORY"} = operation, observed) do
    with true <- valid_written_sha?(operation, observed),
         {:ok, binding} <- Jason.decode(operation["io_binding_json"]),
         {:ok, %{"sha256" => ^observed}, receipt} <- WorkerFileIO.recover_mutation(binding),
         true <- valid_operation_receipt?(Map.put(operation, "io_receipt_json", Jason.encode!(receipt)), access),
         do: true,
         else: (_ -> false)
  end

  defp after_matches?(_access, operation, observed), do: observed == operation["after_sha256"]
end
