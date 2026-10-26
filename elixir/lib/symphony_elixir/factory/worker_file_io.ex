defmodule SymphonyElixir.Factory.WorkerFileIO do
  @moduledoc "Fixed, bounded, descriptor-relative controller file transport; no model-specified executable or code."
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.PathSafety

  @helper Path.expand("../../../priv/worker_file_io.py", __DIR__)
  @external_resource @helper
  @helper_sha :crypto.hash(:sha256, File.read!(@helper))
  @revision_helper Path.expand("../../../priv/worker_revision_reader_v1.py", __DIR__)
  @external_resource @revision_helper
  @revision_helper_sha :crypto.hash(:sha256, File.read!(@revision_helper))
  @companion Path.expand("../../../priv/worker_file_companion.py", __DIR__)
  @external_resource @companion
  @companion_sha :crypto.hash(:sha256, File.read!(@companion))
  @test_transport Mix.env() == :test
  @limit 2_097_152
  @profile "(version 1)(deny default)(allow process-exec)(allow file-read*)(allow file-write* (subpath (param \"SOURCE_ROOT\")))(allow sysctl-read)(allow mach-lookup)"
  @read_profile "(version 1)(deny default)(allow process-exec)(allow file-read*)(allow sysctl-read)(allow mach-lookup)"
  @revision_profile "(version 1)(deny default)(allow process-exec)(allow process-fork)(allow signal (target children))(allow file-read*)(allow file-write* (literal \"/dev/null\"))(allow sysctl-read)(allow mach-lookup)"
  @type result :: {:ok, map(), map()} | {:error, term(), map()} | {:error, term()}

  @spec request(Path.t(), map(), String.t(), map(), map() | nil) :: result()
  def request(root, binding, operation, arguments, transport \\ nil) do
    with :ok <- platform(),
         {:ok, helper} <- verified_helper(root),
         true <- operation in ~w(read read_binary list digest text_digest temporary_absent) or {:error, :file_io_committed_mutation_required},
         true <- valid_root?(binding) or {:error, :file_io_root_unproven},
         {:ok, program, argv} <- reader_command(helper, "request", root, [], transport) do
      nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      input = Jason.encode!(%{version: 1, nonce: nonce, root: root, device: binding["root_device"], inode: binding["root_inode"], operation: operation, arguments: arguments})

      if byte_size(input) <= @limit do
        exchange(root, program, operation, arguments, input, nonce, argv)
      else
        {:error, :file_io_frame_rejected}
      end
    end
  end

  @spec request_revision(Path.t(), map(), map(), map() | nil) :: result()
  def request_revision(root, binding, arguments, transport \\ nil) do
    with :ok <- platform(),
         {:ok, helper} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/worker_revision_reader_v1.py")),
         :ok <- outside_source(helper, root, :file_io_helper_in_source),
         {:ok, bytes} <- File.read(helper),
         true <- :crypto.hash(:sha256, bytes) == @revision_helper_sha or {:error, :file_io_helper_changed},
         true <- valid_root?(binding) or {:error, :file_io_root_unproven},
         {:ok, program, argv} <- reader_command(helper, "request", root, [], transport) do
      nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      input = Jason.encode!(%{version: 1, nonce: nonce, root: root, device: binding["root_device"], inode: binding["root_inode"], operation: "revision", arguments: arguments})

      if byte_size(input) <= @limit,
        do: exchange(root, program, "revision", arguments, input, nonce, argv, @revision_helper_sha),
        else: {:error, :file_io_frame_rejected}
    end
  end

  @doc false
  @spec prepare_mutation(Store.connection(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_mutation(store, access, args, identity) do
    root = access["canonical_path"]
    root_binding = Jason.decode!(access["binding_json"])

    with :ok <- platform(),
         {:ok, _helper} <- verified_helper(root),
         {:ok, _companion} <- verified_companion(root),
         {:ok, database} <- database_path(store),
         {:ok, spool, stat} <- spool(store, database, root),
         %{"binding_sha256" => worker_hash} = worker <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key = ?", [identity["request_key"]]),
         %{"repo_path" => repository} <- Store.one!(store, "SELECT repo_path FROM runs WHERE run_id = ?", [identity["run_id"]]),
         {:ok, repository_path} <- PathSafety.canonicalize(repository) do
      nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      input = mutation_input(root, root_binding, nonce, args)

      binding =
        Map.merge(identity, %{
          "version" => 1,
          "operation" => mutation_operation(args),
          "invocation" => nonce,
          "database" => database,
          "root" => root,
          "root_device" => root_binding["root_device"],
          "root_inode" => root_binding["root_inode"],
          "workspace_binding_sha256" => hash(access["binding_json"]),
          "worker_binding_sha256" => worker_hash,
          "worker_owner_id" => worker["owner_id"],
          "worker_thread_id" => worker["thread_id"],
          "worker_turn_id" => worker["turn_id"],
          "worker_process_sha256" => hash(worker["owner_process_json"]),
          "repository_path" => repository_path,
          "reservation_key" => access["reservation_key"],
          "generation" => access["generation"],
          "spool" => spool,
          "spool_device" => stat.major_device,
          "spool_inode" => stat.inode,
          "helper_sha256" => hex(@helper_sha),
          "companion_sha256" => hex(@companion_sha),
          "profile_sha256" => hash(@profile),
          "input_sha256" => hash(input),
          "arguments_sha256" => hash(Jason.encode!(args))
        })

      {:ok, binding}
    end
  end

  defp mutation_input(root, binding, nonce, args),
    do: Jason.encode!(%{version: 1, nonce: nonce, root: root, device: binding["root_device"], inode: binding["root_inode"], operation: mutation_operation(args), arguments: args})

  defp mutation_operation(%{"content" => _content}), do: "replace"
  defp mutation_operation(%{"content_base64" => _encoded}), do: "replace_binary"
  defp mutation_operation(%{"expected_sha256" => _expected}), do: "delete"
  defp mutation_operation(_args), do: "mkdir"

  @doc "Inspect a known invocation's temporary; this is not a process-stop proof or authority to release source ownership."
  @spec confirm_no_temporary(map(), map()) :: :ok | {:error, term()}
  def confirm_no_temporary(binding, effect) when is_map(binding) and is_map(effect) do
    programs = %{"helper_sha256" => hex(@helper_sha), "companion_sha256" => hex(@companion_sha), "profile_sha256" => hash(@profile)}

    with true <- valid_recovery_binding?(binding) or {:error, :file_io_cancellation_binding_unproven},
         true <- Map.take(binding, Map.keys(programs)) == programs or {:error, :file_io_cancellation_binding_unproven},
         true <- Map.take(binding, ~w(path before_sha256 after_sha256)) == effect or {:error, :file_io_cancellation_binding_unproven},
         true <- binding["operation"] in ~w(replace replace_binary delete) or {:error, :file_io_cancellation_binding_unproven} do
      inspect_temporary(binding)
    end
  end

  def confirm_no_temporary(_binding, _effect), do: {:error, :file_io_cancellation_binding_unproven}

  defp inspect_temporary(%{"operation" => "delete"}), do: :ok

  defp inspect_temporary(binding) do
    args = %{"path" => binding["path"], "source_nonce" => binding["invocation"]}

    case request(binding["root"], binding, "temporary_absent", args) do
      {:ok, %{"absent" => true}, _receipt} -> :ok
      _ -> {:error, :file_io_temporary_unproven}
    end
  end

  defp database_path(store) do
    case Store.one!(store, "SELECT file FROM pragma_database_list WHERE name = 'main'") do
      %{"file" => path} when is_binary(path) and path != "" -> PathSafety.canonicalize(path)
      _ -> {:error, :file_io_persistent_store_required}
    end
  end

  @doc false
  @spec controller_spool(Store.connection(), Path.t()) :: {:ok, map()} | {:error, term()}
  def controller_spool(store, root) do
    with :ok <- platform(),
         {:ok, companion} <- verified_companion(root),
         {:ok, database} <- database_path(store),
         {:ok, path, stat} <- spool(store, database, root) do
      {:ok,
       %{
         "database" => database,
         "root" => root,
         "spool" => path,
         "spool_device" => stat.major_device,
         "spool_inode" => stat.inode,
         "companion_path" => companion,
         "companion_sha256" => hex(@companion_sha)
       }}
    end
  end

  @doc false
  @spec workspace_allowed?(Store.connection(), Path.t(), map() | nil) :: :ok | {:error, term()}
  def workspace_allowed?(store, path, transport \\ nil) do
    case database_path(store) do
      {:ok, database} ->
        spool = Path.join(Path.dirname(database), ".factory-file-io")

        case observe_spool(path, spool, [%{"path" => path, "required" => true}], false, transport) do
          {:ok, %{"allowed" => true}} -> :ok
          {:ok, %{"error" => "spool_in_source"}} -> {:error, :workspace_overlaps_controller_spool}
          _ -> {:error, :file_io_spool_boundary_unproven}
        end

      {:error, :file_io_persistent_store_required} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp spool(store, database, root) do
    path = Path.join(Path.dirname(database), ".factory-file-io")

    paths =
      Store.query!(
        store,
        "SELECT canonical_path, released_at IS NULL FROM workspace_access UNION SELECT worktree, state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') FROM runs WHERE worktree IS NOT NULL UNION SELECT repo_path, state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') FROM runs WHERE repo_path IS NOT NULL"
      ).rows
      |> Enum.map(fn [path, required] -> %{"path" => path, "required" => required == 1} end)

    roots = [%{"path" => root, "required" => true} | paths]

    with {:ok, %{"device" => device, "inode" => inode}} <- observe_spool(root, path, roots, true),
         {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
         {:ok, db_stat} <- File.stat(database),
         true <- (stat.major_device == device and stat.inode == inode and stat.uid == db_stat.uid and Bitwise.band(stat.mode, 0o777) == 0o700) or {:error, :file_io_spool_rejected} do
      {:ok, path, stat}
    else
      {:ok, _} -> {:error, :file_io_spool_rejected}
      {:error, _} = error -> error
    end
  end

  defp observe_spool(root, path, sources, create, transport \\ nil) do
    packet = Jason.encode!(%{path: path, sources: sources, create: create})

    with true <- byte_size(packet) <= @limit or {:error, :file_io_frame_rejected},
         {:ok, companion} <- verified_companion(root),
         {:ok, program, arguments} <- reader_command(companion, "spool", root, ["--spool"], transport) do
      argv = ["-I", "-S", "-B", program | arguments]
      port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(argv, &String.to_charlist/1), env: cleared_environment()])

      try do
        true = Port.command(port, <<byte_size(packet)::unsigned-big-32, packet::binary>>)
        collect_spool(port, "", System.monotonic_time(:millisecond) + 6_000)
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    end
  end

  defp collect_spool(port, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= 4_096 ->
        collect_spool(port, bytes <> chunk, deadline)

      {^port, {:exit_status, 0}} ->
        Jason.decode(bytes)

      {^port, _other} ->
        {:error, :file_io_spool_boundary_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :file_io_spool_boundary_unproven}
    end
  end

  @doc false
  @spec program_outside_source(Path.t(), Path.t()) :: :ok | {:error, term()}
  def program_outside_source(path, root), do: outside_source(path, root, :controller_program_in_source)

  defp outside_source(path, root, reason) do
    with {:ok, %File.Stat{type: :directory} = stat} <- File.stat(root),
         {:ok, inside?} <- ancestor_matches?(Path.dirname(path), stat) do
      if inside?, do: {:error, reason}, else: :ok
    else
      _ -> {:error, :file_io_program_boundary_unproven}
    end
  end

  defp ancestor_matches?(path, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        cond do
          stat.major_device == root.major_device and stat.inode == root.inode -> {:ok, true}
          Path.dirname(path) == path -> {:ok, false}
          true -> ancestor_matches?(Path.dirname(path), root)
        end

      _ ->
        {:error, :file_io_program_boundary_unproven}
    end
  end

  defp verified_companion(root) do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/worker_file_companion.py")),
         :ok <- outside_source(path, root, :file_io_companion_in_source),
         {:ok, bytes} <- File.read(path),
         true <- :crypto.hash(:sha256, bytes) == @companion_sha or {:error, :file_io_companion_changed},
         do: {:ok, path}
  end

  @doc false
  @spec dispatch_mutation(map(), map(), map() | nil) :: {:ok, map(), map()} | {:error, term(), map()} | {:error, term()}
  def dispatch_mutation(binding, args, transport \\ nil) do
    input = mutation_input(binding["root"], binding, binding["invocation"], args)

    with true <- hash(input) == binding["input_sha256"] or {:error, :file_io_input_changed},
         {:ok, companion} <- verified_companion(binding["root"]),
         {:ok, program, argv} <- companion_command(companion, binding, transport) do
      packet = Jason.encode!(%{binding_json: Jason.encode!(binding), input: input})

      port =
        Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(["-I", "-S", "-B", program | argv], &String.to_charlist/1),
          env: cleared_environment()
        ])

      try do
        true = Port.command(port, <<byte_size(packet)::unsigned-big-32, packet::binary>>)
        await_companion(port, System.monotonic_time(:millisecond) + 6_000, 0)
        recover_mutation(binding)
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    end
  end

  defp companion_command(companion, binding, nil), do: {:ok, companion, [binding["database"], binding["invocation"]]}

  defp companion_command(companion, binding, %{path: path, sha256: expected}) when @test_transport do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         :ok <- outside_source(canonical, binding["root"], :file_io_fixture_in_source),
         {:ok, bytes} <- File.read(canonical),
         true <- hash(bytes) == expected or {:error, :file_io_fixture_changed},
         do: {:ok, canonical, [companion, binding["database"], binding["invocation"]]}
  end

  defp companion_command(_companion, _binding, _transport), do: {:error, :file_io_fixture_rejected}

  defp reader_command(program, _kind, _root, argv, nil), do: {:ok, program, argv}

  defp reader_command(_program, kind, root, _argv, %{path: path, sha256: expected, failure: failure}) when @test_transport do
    with true <- failure in ~w(nonzero deadline overflow truncated malformed scalar) or {:error, :file_io_fixture_rejected},
         {:ok, canonical} <- PathSafety.canonicalize(path),
         :ok <- outside_source(canonical, root, :file_io_fixture_in_source),
         {:ok, bytes} <- File.read(canonical),
         true <- hash(bytes) == expected or {:error, :file_io_fixture_changed},
         do: {:ok, canonical, [kind, failure]}
  end

  defp reader_command(_program, _kind, _root, _argv, _transport), do: {:error, :file_io_fixture_rejected}

  defp await_companion(port, deadline, bytes) do
    receive do
      {^port, {:data, chunk}} ->
        if bytes + byte_size(chunk) <= 4_194_308 do
          await_companion(port, deadline, bytes + byte_size(chunk))
        else
          :unproven
        end

      {^port, {:exit_status, _status}} ->
        :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :unproven
    end
  end

  @doc false
  @spec recover_mutation(map(), map() | nil) :: {:ok, map(), map()} | {:error, term(), map()} | {:error, term()}
  def recover_mutation(binding, transport \\ nil) do
    with true <- valid_recovery_binding?(binding) or {:error, :file_worker_helper_exit_unproven} do
      read_recovery_receipt(binding, transport)
    end
  end

  defp valid_recovery_binding?(binding) when is_map(binding) do
    paths = ~w(spool root database)
    hashes = ~w(invocation input_sha256 helper_sha256 companion_sha256 arguments_sha256 profile_sha256 workspace_binding_sha256)
    identities = ~w(root_device root_inode spool_device spool_inode generation)

    Enum.all?(paths, &(is_binary(binding[&1]) and Path.type(binding[&1]) == :absolute)) and
      Enum.all?(hashes, &valid_hash?(binding[&1])) and Enum.all?(identities, &(is_integer(binding[&1]) and binding[&1] > 0))
  end

  defp valid_recovery_binding?(_binding), do: false

  defp read_recovery_receipt(binding, transport) do
    arguments = ["--status", binding["database"], binding["invocation"]]

    with {:ok, companion} <- verified_companion(binding["root"]),
         {:ok, program, arguments} <- reader_command(companion, "status", binding["root"], arguments, transport) do
      argv = ["-I", "-S", "-B", program | arguments]
      port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(argv, &String.to_charlist/1), env: cleared_environment()])

      try do
        collect_recovery(port, binding, "", System.monotonic_time(:millisecond) + 6_000)
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    end
  end

  defp collect_recovery(port, binding, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} ->
        if byte_size(bytes) + byte_size(chunk) <= 4_194_308 do
          collect_recovery(port, binding, bytes <> chunk, deadline)
        else
          {:error, :file_worker_helper_exit_unproven}
        end

      {^port, {:exit_status, 0}} ->
        decode_recovery(bytes, binding)

      {^port, {:exit_status, _status}} ->
        {:error, :file_worker_helper_exit_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :file_worker_helper_exit_unproven}
    end
  end

  defp decode_recovery(<<size::unsigned-big-32, data::binary>>, binding) when byte_size(data) == size do
    case Jason.decode(data) do
      {:ok, record} -> recover_record(record, binding)
      _ -> {:error, :file_io_receipt_rejected}
    end
  end

  defp decode_recovery(_data, _binding), do: {:error, :file_io_receipt_rejected}

  defp recover_record(%{"version" => 1, "binding_json" => expected, "disposition" => "NO_SPAWN", "companion_pid" => pid, "reason" => reason}, binding) do
    if expected == Jason.encode!(binding) and is_integer(pid) and pid > 0 and reason in ~w(database_busy authorization_changed) do
      receipt = %{
        "transport" => "owned_file_companion",
        "disposition" => "NO_SPAWN",
        "companion_pid" => pid,
        "reason" => reason,
        "nonce" => binding["invocation"],
        "helper_sha256" => binding["helper_sha256"],
        "input_sha256" => binding["input_sha256"],
        "arguments_sha256" => binding["arguments_sha256"],
        "binding_sha256" => hash(expected)
      }

      {:error, {:file_io_not_started, reason}, receipt}
    else
      {:error, :file_io_receipt_rejected}
    end
  end

  defp recover_record(%{"version" => 1, "binding_json" => expected, "pid" => pid, "termination" => terminal, "output_base64" => encoded} = record, binding) when is_binary(encoded) do
    with true <- expected == Jason.encode!(binding) or {:error, :file_io_receipt_binding_changed},
         true <- (is_integer(pid) and pid > 0) or {:error, :file_io_receipt_pid_invalid},
         true <- valid_creator_fields?(record) or {:error, :file_io_creator_receipt_rejected},
         true <- creator_matches_binding?(record, expected, binding) or {:error, :file_io_creator_binding_changed},
         :ok <- validate_recovery_artifacts(record, expected, binding),
         {:ok, status} <- terminal_status(terminal),
         {:ok, output} <- Base.decode64(encoded) do
      receipt =
        Map.merge(
          %{
            "transport" => "owned_file_helper",
            "pid" => pid,
            "nonce" => binding["invocation"],
            "helper_sha256" => binding["helper_sha256"],
            "input_sha256" => binding["input_sha256"],
            "arguments_sha256" => binding["arguments_sha256"],
            "binding_sha256" => hash(expected),
            "exit_status" => status,
            "termination" => terminal
          },
          Map.take(record, ~w(creator_json creator_sha256 cleanup recovery))
        )

      result = if status == 0, do: decode(output, binding["invocation"]), else: {:error, :file_io_response_unproven}
      stopped_result(result, receipt)
    else
      :error -> {:error, :file_io_receipt_rejected}
      {:error, _} = error -> error
    end
  end

  defp recover_record(_record, _binding), do: {:error, :file_io_receipt_rejected}

  defp validate_recovery_artifacts(record, raw_binding, binding) do
    with true <- valid_cleanup_fields?(record) or {:error, :file_io_cleanup_receipt_rejected},
         true <- cleanup_matches_binding?(record, raw_binding, binding) or {:error, :file_io_cleanup_binding_changed},
         true <- valid_recovery_fields?(record) or {:error, :file_io_artifact_recovery_rejected},
         do: :ok
  end

  defp terminal_status(%{"kind" => "exited", "code" => code} = value) when is_integer(code) and code in 0..255 and map_size(value) == 2, do: {:ok, code}
  defp terminal_status(%{"kind" => "signaled", "signal" => signal} = value) when is_integer(signal) and signal in 1..64 and map_size(value) == 2, do: {:ok, nil}
  defp terminal_status(_terminal), do: {:error, :file_io_termination_unproven}
  defp stopped_result({status, value}, receipt), do: {status, value, receipt}
  defp cleared_environment, do: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
  defp hex(raw), do: Base.encode16(raw, case: :lower)
  defp hash(raw), do: hex(:crypto.hash(:sha256, raw))

  defp valid_root?(binding), do: Enum.all?(~w(root_device root_inode), &(is_integer(binding[&1]) and binding[&1] > 0))

  @doc false
  @spec receipt_matches?(term(), term()) :: boolean()
  def receipt_matches?(raw, arguments_sha) when is_binary(raw) and is_binary(arguments_sha) do
    case Jason.decode(raw) do
      {:ok, receipt} when is_map(receipt) ->
        hashes = ~w(nonce helper_sha256 input_sha256 arguments_sha256)

        valid_receipt_shape?(receipt) and
          receipt["arguments_sha256"] == arguments_sha and Enum.all?(hashes, &valid_hash?(receipt[&1]))

      _ ->
        false
    end
  end

  def receipt_matches?(_raw, _arguments_sha), do: false

  defp valid_receipt_shape?(%{"transport" => "owned_file_companion", "disposition" => "NO_SPAWN"} = receipt) do
    fields = ~w(transport disposition companion_pid reason nonce helper_sha256 input_sha256 arguments_sha256 binding_sha256)
    Enum.sort(Map.keys(receipt)) == Enum.sort(fields) and is_integer(receipt["companion_pid"]) and receipt["companion_pid"] > 0 and receipt["reason"] in ~w(database_busy authorization_changed)
  end

  defp valid_receipt_shape?(receipt) do
    fields = ~w(transport pid nonce helper_sha256 input_sha256 arguments_sha256 exit_status)
    fields = fields ++ Enum.filter(~w(termination binding_sha256 creator_json creator_sha256 cleanup recovery), &Map.has_key?(receipt, &1))

    Enum.sort(Map.keys(receipt)) == Enum.sort(fields) and receipt["transport"] == "owned_file_helper" and valid_process_exit?(receipt) and valid_creator_fields?(receipt) and
      valid_cleanup_fields?(receipt) and valid_recovery_fields?(receipt)
  end

  defp valid_recovery_fields?(%{"recovery" => %{"kind" => "COMPLETE_ARTIFACTS"} = recovery} = record) do
    map_size(recovery) == 1 and is_binary(record["creator_json"]) and is_map(record["cleanup"])
  end

  defp valid_recovery_fields?(%{"recovery" => _}), do: false
  defp valid_recovery_fields?(_record), do: true

  defp valid_creator_fields?(record) do
    case Map.take(record, ~w(creator_json creator_sha256)) do
      empty when map_size(empty) == 0 ->
        true

      %{"creator_json" => raw, "creator_sha256" => expected} when is_binary(raw) and byte_size(raw) <= 4096 ->
        valid_hash?(expected) and hash(raw) == expected and valid_creator_json?(raw)

      _ ->
        false
    end
  end

  defp valid_creator_json?(raw) do
    fields = ~w(version event nonce binding_sha256 pid path temporary root_device root_inode parent_device parent_inode device inode)

    case Jason.decode(raw) do
      {:ok, creator} when is_map(creator) ->
        Enum.sort(Map.keys(creator)) == Enum.sort(fields) and valid_creator_header?(creator) and
          positive_identity_fields?(creator, ~w(pid root_device root_inode parent_device parent_inode device inode))

      _ ->
        false
    end
  end

  defp valid_creator_header?(creator) do
    creator["version"] === 1 and creator["event"] == "TEMP_CREATED" and
      valid_hash?(creator["nonce"]) and valid_hash?(creator["binding_sha256"]) and
      is_binary(creator["path"]) and creator["temporary"] == ".symphony-" <> creator["nonce"]
  end

  defp positive_identity_fields?(record, fields), do: Enum.all?(fields, &(is_integer(record[&1]) and record[&1] > 0))

  defp creator_matches_binding?(%{"creator_json" => raw} = receipt, raw_binding, binding) do
    case Jason.decode(raw) do
      {:ok, creator} ->
        expected =
          Map.take(binding, ~w(path root_device root_inode))
          |> Map.put("path", binding["path"])
          |> Map.merge(%{"nonce" => binding["invocation"], "binding_sha256" => hash(raw_binding)})

        binding["operation"] in ~w(replace replace_binary) and creator["pid"] == receipt["pid"] and Map.take(creator, Map.keys(expected)) == expected

      _ ->
        false
    end
  end

  defp creator_matches_binding?(_record, _raw_binding, _binding), do: true

  defp valid_cleanup_fields?(%{"cleanup" => cleanup} = record) when is_map(cleanup) do
    fields = ~w(
      version binding_sha256 original_pid creator_sha256 input_json input_sha256
      pid helper_pid termination output_base64
    )

    Enum.sort(Map.keys(cleanup)) == Enum.sort(fields) and cleanup["version"] === 1 and
      valid_cleanup_process?(cleanup, record) and valid_cleanup_origin?(cleanup, record) and valid_cleanup_io?(cleanup)
  end

  defp valid_cleanup_fields?(%{"cleanup" => _}), do: false
  defp valid_cleanup_fields?(%{"creator_json" => _}), do: false
  defp valid_cleanup_fields?(_record), do: true

  defp valid_cleanup_process?(cleanup, record) do
    is_integer(cleanup["pid"]) and cleanup["pid"] > 0 and cleanup["helper_pid"] == cleanup["pid"] and
      cleanup["original_pid"] == record["pid"] and match?({:ok, _}, terminal_status(cleanup["termination"]))
  end

  defp valid_cleanup_origin?(cleanup, record) do
    is_binary(record["creator_json"]) and valid_hash?(cleanup["binding_sha256"]) and cleanup["creator_sha256"] == record["creator_sha256"]
  end

  defp valid_cleanup_io?(cleanup) do
    valid_hash?(cleanup["input_sha256"]) and is_binary(cleanup["input_json"]) and byte_size(cleanup["input_json"]) <= 8192 and
      hash(cleanup["input_json"]) == cleanup["input_sha256"] and is_binary(cleanup["output_base64"]) and byte_size(cleanup["output_base64"]) <= 8192
  end

  defp cleanup_matches_binding?(%{"cleanup" => cleanup, "creator_json" => raw_creator}, raw_binding, binding) do
    with {:ok, creator} <- Jason.decode(raw_creator),
         {:ok, input} <- Jason.decode(cleanup["input_json"]) do
      args =
        Map.take(creator, ~w(path parent_device parent_inode device inode))
        |> Map.merge(%{"source_nonce" => binding["invocation"], "before_sha256" => binding["before_sha256"], "after_sha256" => binding["after_sha256"]})

      expected = %{
        "version" => 1,
        "nonce" => binding["invocation"],
        "root" => binding["root"],
        "device" => binding["root_device"],
        "inode" => binding["root_inode"],
        "operation" => "temporary_recover",
        "arguments" => args
      }

      cleanup["binding_sha256"] == hash(raw_binding) and input == expected
    else
      _ -> false
    end
  end

  defp cleanup_matches_binding?(%{"cleanup" => _}, _raw_binding, _binding), do: false
  defp cleanup_matches_binding?(_record, _raw_binding, _binding), do: true

  @doc false
  @spec receipt_matches_binding?(term(), term(), map()) :: boolean()
  def receipt_matches_binding?(raw, raw_binding, identity) when is_binary(raw) and is_binary(raw_binding) and is_map(identity) and map_size(identity) > 0 do
    with {:ok, binding} <- Jason.decode(raw_binding),
         true <- valid_recovery_binding?(binding),
         true <- binding["version"] == 1 and Map.take(binding, Map.keys(identity)) == identity,
         true <- receipt_matches?(raw, binding["arguments_sha256"]),
         {:ok, receipt} <- Jason.decode(raw),
         true <- creator_matches_binding?(receipt, raw_binding, binding),
         true <- cleanup_matches_binding?(receipt, raw_binding, binding) do
      expected = %{"binding_sha256" => hash(raw_binding), "nonce" => binding["invocation"], "helper_sha256" => binding["helper_sha256"], "input_sha256" => binding["input_sha256"]}
      (Map.has_key?(receipt, "termination") or receipt["disposition"] == "NO_SPAWN") and Map.take(receipt, Map.keys(expected)) == expected
    else
      _ -> false
    end
  end

  def receipt_matches_binding?(_raw, _raw_binding, _identity), do: false

  defp valid_process_exit?(%{"termination" => terminal} = receipt) do
    is_integer(receipt["pid"]) and receipt["pid"] > 0 and terminal_status(terminal) == {:ok, receipt["exit_status"]}
  end

  defp valid_process_exit?(receipt), do: is_integer(receipt["pid"]) and receipt["pid"] > 0 and receipt["exit_status"] in 0..255

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp platform do
    if :os.type() == {:unix, :darwin} and File.regular?("/usr/bin/python3") and File.regular?("/usr/bin/sandbox-exec"), do: :ok, else: {:error, :file_io_platform_unsupported}
  end

  defp verified_helper(root) do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/worker_file_io.py")),
         :ok <- outside_source(path, root, :file_io_helper_in_source),
         {:ok, bytes} <- File.read(path),
         true <- :crypto.hash(:sha256, bytes) == @helper_sha or {:error, :file_io_helper_changed},
         do: {:ok, path}
  end

  defp exchange(root, helper, operation, arguments, input, nonce, argv, helper_sha \\ @helper_sha) do
    profile =
      case operation do
        "replace" -> @profile
        "revision" -> @revision_profile
        _ -> @read_profile
      end

    args = ["-D", "SOURCE_ROOT=" <> root, "-p", profile, "/usr/bin/python3", "-I", "-S", "-B", helper | argv]
    environment = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
    port = Port.open({:spawn_executable, ~c"/usr/bin/sandbox-exec"}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1), env: environment])
    {:os_pid, pid} = Port.info(port, :os_pid)

    invocation = %{
      "transport" => "owned_file_helper",
      "pid" => pid,
      "nonce" => nonce,
      "helper_sha256" => Base.encode16(helper_sha, case: :lower),
      "input_sha256" => Base.encode16(:crypto.hash(:sha256, input), case: :lower),
      "arguments_sha256" => Base.encode16(:crypto.hash(:sha256, Jason.encode!(arguments)), case: :lower)
    }

    try do
      true = Port.command(port, <<byte_size(input)::unsigned-big-32, input::binary>>)
      collect(port, invocation, "", System.monotonic_time(:millisecond) + 5_000)
    after
      if Port.info(port) != nil, do: Port.close(port)
    end
  end

  defp collect(port, invocation, bytes, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if byte_size(bytes) + byte_size(chunk) <= @limit + 4 do
          collect(port, invocation, bytes <> chunk, deadline)
        else
          {:error, :file_io_response_unproven}
        end

      {^port, {:exit_status, 0}} ->
        stopped(decode(bytes, invocation["nonce"]), invocation, 0)

      {^port, {:exit_status, status}} ->
        stopped({:error, :file_io_response_unproven}, invocation, status)
    after
      remaining -> {:error, :file_io_response_unproven}
    end
  end

  defp stopped({status, value}, invocation, exit_status), do: {status, value, Map.put(invocation, "exit_status", exit_status)}

  defp decode(<<size::unsigned-big-32, data::binary>>, nonce) when byte_size(data) == size do
    case Jason.decode(data) do
      {:ok, %{"version" => 1, "nonce" => ^nonce, "ok" => true, "result" => result} = response}
      when is_map(result) and map_size(response) == 4 ->
        {:ok, result}

      {:ok, %{"version" => 1, "nonce" => ^nonce, "ok" => false, "error" => code} = response}
      when is_binary(code) and map_size(response) == 4 ->
        {:error, {:file_io_rejected, code}}

      _ ->
        {:error, :file_io_response_unproven}
    end
  end

  defp decode(_bytes, _nonce), do: {:error, :file_io_response_unproven}
end
