defmodule SymphonyElixir.Factory.CiJobArtifacts do
  @moduledoc "Exact-job MCP archive evidence. Gaps never classify a failure or grant source authority."
  alias SymphonyElixir.Factory.{GitLabMcpConnector, TicketCiRepair}

  @helper Path.expand("../../../priv/read_ci_archive_v2.py", __DIR__)
  @external_resource @helper
  @helper_bytes File.read!(@helper)
  @helper_sha :crypto.hash(:sha256, @helper_bytes) |> Base.encode16(case: :lower)
  @max_archive 67_108_864
  @max_output 8_388_609

  @spec collect(map(), pos_integer(), [map()], keyword()) :: [map()]
  def collect(run, project, jobs, opts) do
    connector = Keyword.get(opts, :connector, GitLabMcpConnector)

    jobs
    |> Enum.with_index()
    |> Enum.map(fn {job, index} ->
      if index < 2 and function_exported?(connector, :job_artifacts, 3) do
        collect_job(run, project, job["id"], connector, opts)
      else
        gap(job["id"], "ARTIFACT_BUDGET_OR_CAPABILITY_UNAVAILABLE")
      end
    end)
  end

  defp collect_job(run, project, id, connector, opts) do
    args = %{"project_id" => to_string(project), "job_id" => to_string(id), "path" => "", "recursive" => true}

    with true <- is_integer(project) and project > 0 and is_integer(id) and id > 0,
         {:ok, files, metadata} <- metadata(connector, args, opts),
         {:ok, selected} <- selected(files),
         {:ok, directory, relative} <- private_directory(opts[:workspace], run["worktree"]),
         download_args = %{"project_id" => to_string(project), "job_id" => to_string(id), "local_path" => relative},
         {:ok, response} <- connector.job_artifacts("download_job_artifacts", download_args, opts),
         {:ok, path, stat, sha} <- downloaded(response, directory, id),
         frame = %{
           "version" => 1,
           "archive_path" => path,
           "expected_sha256" => sha,
           "expected_size" => stat.size,
           "source_root" => run["worktree"],
           "download_root" => directory,
           "selected_members" => selected
         },
         {:ok, decoded, receipt} <- decode(frame),
         true <- decoded["version"] == 1 and decoded["archive_sha256"] == sha and is_list(decoded["members"]) and is_list(decoded["gaps"]) do
      %{
        "job_id" => id,
        "status" => if(decoded["gaps"] == [], do: "COMPLETE", else: "PARTIAL"),
        "provenance" => %{
          "metadata_arguments" => args,
          "metadata_sha256" => hash(Jason.encode!(files)),
          "metadata_observations" => metadata,
          "download_arguments" => download_args,
          "download_response_sha256" => hash(Jason.encode!(response)),
          "archive_sha256" => sha,
          "archive_bytes" => stat.size,
          "helper_sha256" => @helper_sha,
          "owned_reader" => receipt
        },
        "members" => Enum.map(decoded["members"], &sanitize_member/1),
        "gaps" => Enum.map(decoded["gaps"], &sanitize_gap/1)
      }
    else
      {:reader_error, reason, receipt} -> Map.put(gap(id, reason), "owned_reader", receipt)
      {:error, reason} -> gap(id, artifact_reason(reason))
      _ -> gap(id, "ARTIFACT_BINDING_UNPROVEN")
    end
  rescue
    _ -> gap(id, "ARTIFACT_COLLECTION_EXCEPTION")
  end

  defp metadata(connector, args, opts) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    state = %{files: [], names: %{}, requests: 0, entries: 0, bytes: 0, observations: [], deadline: deadline}
    walk_metadata([{"", 0}], state, connector, args, opts)
  end

  defp walk_metadata([], state, _connector, _args, _opts) do
    if metadata_expired?(state),
      do: {:error, :artifact_metadata_budget},
      else: {:ok, Enum.reverse(state.files), Enum.reverse(state.observations)}
  end

  defp walk_metadata([{path, depth} | rest], state, connector, args, opts) do
    if state.requests >= 16 or depth > 4 or metadata_expired?(state) do
      {:error, :artifact_metadata_budget}
    else
      request = Map.put(args, "path", path)

      with {:ok, files} <- metadata_call(connector, request, opts),
           false <- metadata_expired?(state),
           {:ok, state, directories} <- metadata_entries(files, path, depth, state) do
        observation = %{"path" => TicketCiRepair.sanitize_text(path), "response_sha256" => hash(Jason.encode!(files)), "entries" => length(files)}
        state = %{state | requests: state.requests + 1, observations: [observation | state.observations]}
        walk_metadata(rest ++ directories, state, connector, args, opts)
      else
        true -> {:error, :artifact_metadata_budget}
        {:error, _} = error -> error
      end
    end
  end

  defp metadata_expired?(state), do: System.monotonic_time(:millisecond) >= state.deadline

  defp metadata_call(connector, args, opts) do
    case connector.job_artifacts("list_job_artifacts", args, opts) do
      {:ok, files} when is_list(files) -> {:ok, files}
      _ -> {:error, :artifact_metadata_tool_unavailable}
    end
  end

  defp metadata_entries(files, parent, depth, state) do
    entries = state.entries + length(files)
    bytes = state.bytes + byte_size(Jason.encode!(files))

    if entries <= 256 and bytes <= 262_144 do
      collect = &collect_metadata_entry(&1, parent, depth, &2)
      Enum.reduce_while(files, {:ok, %{state | entries: entries, bytes: bytes}, []}, collect)
    else
      {:error, :artifact_metadata_budget}
    end
  end

  defp collect_metadata_entry(file, parent, depth, {:ok, state, directories}) do
    case metadata_entry(file, parent) do
      {:ok, path, type} -> register_metadata_entry(file, path, type, depth, state, directories)
      {:error, _} = error -> {:halt, error}
    end
  end

  defp register_metadata_entry(file, path, type, depth, state, directories) do
    name = path |> String.normalize(:nfc) |> String.downcase()
    entry = file |> Map.take(~w(type path size mode)) |> Map.put("path", path)

    case Map.fetch(state.names, name) do
      {:ok, ^entry} -> {:cont, {:ok, state, directories}}
      {:ok, _} -> {:halt, {:error, :artifact_metadata_duplicate}}
      :error -> add_metadata_entry(file, path, type, depth, %{state | names: Map.put(state.names, name, entry)}, directories)
    end
  end

  defp add_metadata_entry(_file, path, "directory", depth, state, directories),
    do: {:cont, {:ok, state, directories ++ [{path, max(depth + 1, length(String.split(path, "/")))}]}}

  defp add_metadata_entry(file, _path, "file", _depth, state, directories), do: {:cont, {:ok, %{state | files: [file | state.files]}, directories}}

  defp metadata_entry(%{"path" => raw, "type" => type} = file, parent) when is_binary(raw) and type in ~w(file directory) do
    path = if type == "directory", do: String.trim_trailing(raw, "/"), else: raw

    with true <- metadata_entry?(file) and safe_metadata_path?(path),
         true <- raw == path or (type == "directory" and raw == path <> "/"),
         true <- parent == "" or String.starts_with?(path, parent <> "/"),
         true <- metadata_mode?(file["mode"], type) do
      {:ok, path, type}
    else
      _ -> {:error, :artifact_metadata_path_or_type}
    end
  end

  defp metadata_entry(_, _), do: {:error, :artifact_metadata_path_or_type}

  defp safe_metadata_path?(path) do
    byte_size(path) in 1..1024 and String.valid?(path) and not Regex.match?(~r/[\x00-\x1f\x7f\\:]/u, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp metadata_mode?(nil, _type), do: true

  defp metadata_mode?(mode, type) when is_binary(mode) and byte_size(mode) <= 8 do
    case Integer.parse(mode, 8) do
      {value, ""} when value >= 0 ->
        bits = Bitwise.band(value, 0o170000)
        bits == 0 or (type == "file" and bits == 0o100000) or (type == "directory" and bits == 0o040000)

      _ ->
        false
    end
  end

  defp metadata_mode?(_, _), do: false

  defp artifact_reason(reason)
       when reason in [
              :artifact_metadata_budget,
              :artifact_metadata_duplicate,
              :artifact_metadata_path_or_type,
              :artifact_metadata_tool_unavailable,
              :artifact_metadata_unproven,
              :artifact_metadata_unavailable,
              :artifact_directory_unproven,
              :artifact_download_unproven,
              :artifact_frame_limit
            ],
       do: reason |> Atom.to_string() |> String.upcase()

  defp artifact_reason(_reason), do: "ARTIFACT_CONNECTOR_UNAVAILABLE"

  defp selected(files) when is_list(files) and length(files) in 1..256 do
    valid = Enum.all?(files, &metadata_entry?/1)

    names = for file <- files, file["type"] == "file" and Regex.match?(~r/\.(?:log|txt|xml|json)(?:\.gz)?\z/i, file["path"]), do: file["path"]
    size = files |> Enum.filter(&(&1["type"] == "file")) |> Enum.map(& &1["size"]) |> Enum.sum()
    if valid and names != [] and length(Enum.uniq(names)) == length(names) and size <= @max_archive, do: {:ok, names}, else: {:error, :artifact_metadata_unproven}
  end

  defp selected(_), do: {:error, :artifact_metadata_unavailable}

  defp metadata_entry?(%{"type" => type, "path" => path} = file) when type in ~w(file directory) and is_binary(path) do
    byte_size(path) <= 1024 and (type == "directory" or (is_integer(file["size"]) and file["size"] >= 0))
  end

  defp metadata_entry?(_), do: false

  defp private_directory(workspace, source) when is_binary(workspace) and is_binary(source) do
    workspace = Path.expand(workspace)
    source = Path.expand(source)
    relative = ".factory-ci-artifacts-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    directory = Path.join(workspace, relative)

    with true <- workspace != source and not String.starts_with?(workspace, source <> "/"),
         {:ok, %{type: :directory}} <- File.lstat(workspace),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700) do
      {:ok, directory, relative}
    else
      _ -> {:error, :artifact_directory_unproven}
    end
  end

  defp private_directory(_, _), do: {:error, :artifact_directory_unproven}

  defp downloaded(%{"success" => true, "file_path" => path} = response, directory, id) when map_size(response) == 2 do
    expected = Path.join(directory, "artifacts_job_#{id}.zip")

    with true <- path == expected,
         {:ok, %{type: :regular, links: 1, size: size, uid: uid} = stat} <- File.lstat(path),
         true <- size in 1..@max_archive and uid == File.stat!(directory).uid,
         :ok <- File.chmod(path, 0o600),
         {:ok, raw} <- File.read(path),
         true <- byte_size(raw) == size,
         {:ok, after_read} <- File.lstat(path),
         true <- Map.take(stat, ~w(inode major_device minor_device size mtime)a) == Map.take(after_read, ~w(inode major_device minor_device size mtime)a) do
      {:ok, path, after_read, hash(raw)}
    else
      _ -> {:error, :artifact_download_unproven}
    end
  end

  defp downloaded(_, _, _), do: {:error, :artifact_download_unproven}

  defp decode(frame) do
    raw = Jason.encode!(frame) <> "\n"

    if byte_size(raw) <= 16_384 do
      args = ["-I", "-S", "-B", "-c", "import sys;exec(compile(bytes.fromhex(sys.argv[1]),sys.argv[2],'exec'))", Base.encode16(@helper_bytes, case: :lower), @helper]
      port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args])
      {:os_pid, pid} = Port.info(port, :os_pid)
      true = Port.command(port, raw)
      deadline = System.monotonic_time(:millisecond) + 8_000

      case receive_reader(port, deadline, "") do
        {:ok, bytes, 0} ->
          decoded_response(bytes, pid)

        {:ok, _bytes, status} ->
          {:reader_error, "ARTIFACT_READER_FAILED", %{"pid" => pid, "exit_status" => status}}

        {:error, reason} ->
          {:reader_error, reason |> Atom.to_string() |> String.upcase(), stop_reader(port, pid)}
      end
    else
      {:error, :artifact_frame_limit}
    end
  end

  defp decoded_response(bytes, pid) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(bytes), do: {:ok, decoded, %{"pid" => pid, "exit_status" => 0}}
  end

  defp receive_reader(port, deadline, bytes) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        if byte_size(bytes) + byte_size(data) <= @max_output and System.monotonic_time(:millisecond) < deadline,
          do: receive_reader(port, deadline, bytes <> data),
          else: {:error, :artifact_reader_limit}

      {^port, {:exit_status, status}} ->
        {:ok, bytes, status}
    after
      remaining -> {:error, :artifact_reader_timeout}
    end
  end

  defp stop_reader(port, pid) do
    receive do
      {^port, {:exit_status, status}} -> %{"pid" => pid, "exit_status" => status}
    after
      0 -> kill_reader(port, pid)
    end
  end

  defp kill_reader(port, pid) do
    if Port.info(port, :os_pid) == {:os_pid, pid}, do: System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, status}} -> %{"pid" => pid, "exit_status" => status}
    after
      1_000 -> %{"pid" => pid, "status" => "REAP_UNPROVEN"}
    end
  end

  defp sanitize_member(member), do: Map.take(member, ~w(path sha256 text complete)) |> Map.update!("path", &TicketCiRepair.sanitize_text/1) |> Map.update!("text", &TicketCiRepair.sanitize_text/1)
  defp sanitize_gap(gap), do: Map.take(gap, ~w(code path)) |> Map.new(fn {key, value} -> {key, TicketCiRepair.sanitize_text(value)} end)
  defp gap(id, reason), do: %{"job_id" => id, "status" => "UNAVAILABLE", "members" => [], "gaps" => [%{"code" => reason}]}
  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
