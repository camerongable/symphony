defmodule SymphonyElixir.Factory.NativeSessionDiscovery do
  @moduledoc """
  Finds a possible native Codex task ID after an uncertain Desktop worktree create.

  Session files are only a candidate index. The broker must still read the task
  through Codex and prove its Project and checkout before binding it to a run.
  """

  alias SymphonyElixir.Factory.DesktopRequest
  alias SymphonyElixir.PathSafety

  @max_files 2_000
  @max_head_bytes 1_048_576
  @max_utc_offset_seconds 14 * 60 * 60
  @request_key_pattern ~r/\Adesktop:[0-9a-f]{64}:bootstrap\z/
  @thread_id_pattern ~r/\Arollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-f-]{36})\.jsonl\z/

  @type candidate :: %{thread_id: String.t(), cwd: Path.t(), created_at: String.t()}

  @doc "Looks up a candidate only for a claimed native CREATE in the durable ledger."
  @spec find_for_request(DBConnection.conn(), String.t(), keyword()) :: {:ok, candidate()} | {:error, term()}
  def find_for_request(connection, request_key, opts \\ []) do
    with {:ok, request} <- DesktopRequest.get(connection, request_key),
         :ok <- require_claimed_native_create(request),
         {:ok, claimed_at} <- claim_time(request) do
      find(request_key, claimed_at, opts)
    end
  end

  defp claim_time(%{"claimed_at" => claimed_at}) when is_binary(claimed_at) and claimed_at != "",
    do: {:ok, claimed_at}

  defp claim_time(%{"status" => "CREATE_UNCERTAIN", "updated_at" => updated_at}) when is_binary(updated_at),
    do: {:ok, updated_at}

  defp claim_time(_request), do: {:error, :native_claim_timestamp_missing}

  @doc "Returns one candidate ID from bounded local session metadata, never Project proof."
  @spec find(String.t(), String.t(), keyword()) :: {:ok, candidate()} | {:error, term()}
  def find(request_key, claimed_at, opts \\ []) do
    root = Keyword.get_lazy(opts, :sessions_root, &default_sessions_root/0)
    source_thread_id = Keyword.get(opts, :source_thread_id)

    with :ok <- validate_request_key(request_key),
         :ok <- validate_source_thread_id(source_thread_id),
         {:ok, claimed_time, _offset} <- DateTime.from_iso8601(claimed_at),
         {:ok, canonical_root} <- canonical_sessions_root(root),
         {:ok, archive_root} <- canonical_archive_root(canonical_root, opts),
         {:ok, paths} <- session_paths(canonical_root, archive_root, claimed_time),
         {:ok, candidates} <- scan_paths(paths, request_key, source_thread_id, claimed_time) do
      unique_candidate(candidates)
    else
      {:error, :invalid_format} -> {:error, :invalid_native_claim_time}
      {:error, _reason} = error -> error
    end
  end

  defp require_claimed_native_create(request) do
    with {:ok, metadata} <- Jason.decode(request["metadata_json"]) do
      cond do
        request["target_kind"] != "TASK" or request["action"] != "CREATE" or
            metadata["workspace_mode"] != "CODEX_NATIVE" ->
          {:error, :not_native_task_create}

        request["status"] not in ["CREATE_UNCERTAIN", "RECONCILE_REQUIRED"] ->
          {:error, :native_create_not_uncertain}

        true ->
          :ok
      end
    end
  end

  defp default_sessions_root do
    codex_home = System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
    Path.join(codex_home, "sessions")
  end

  defp validate_request_key(request_key) when is_binary(request_key) do
    if Regex.match?(@request_key_pattern, request_key),
      do: :ok,
      else: {:error, :invalid_native_request_key}
  end

  defp validate_request_key(_request_key), do: {:error, :invalid_native_request_key}

  defp validate_source_thread_id(id) when is_binary(id) do
    if String.match?(id, ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/),
      do: :ok,
      else: {:error, :native_source_thread_required}
  end

  defp validate_source_thread_id(_id), do: {:error, :native_source_thread_required}

  defp canonical_sessions_root(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute or {:error, :invalid_native_sessions_root},
         {:ok, canonical} <- PathSafety.canonicalize(root),
         {:ok, %File.Stat{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      {:error, _reason} -> {:error, :invalid_native_sessions_root}
    end
  end

  defp canonical_sessions_root(_root), do: {:error, :invalid_native_sessions_root}

  defp canonical_archive_root(root, opts) do
    configured = Keyword.get(opts, :archived_sessions_root)

    candidate =
      cond do
        is_binary(configured) -> configured
        Path.basename(root) == "sessions" -> Path.join(Path.dirname(root), "archived_sessions")
        true -> nil
      end

    canonical_optional_archive_root(candidate)
  end

  defp canonical_optional_archive_root(nil), do: {:ok, nil}

  defp canonical_optional_archive_root(candidate) do
    if Path.type(candidate) == :absolute do
      case File.stat(candidate) do
        {:error, :enoent} -> {:ok, nil}
        {:ok, %File.Stat{type: :directory}} -> PathSafety.canonicalize(candidate)
        _other -> {:error, :invalid_native_archived_sessions_root}
      end
    else
      {:error, :invalid_native_archived_sessions_root}
    end
  end

  defp session_paths(root, archive_root, claimed_time) do
    dates = Date.range(Date.add(DateTime.to_date(claimed_time), -1), Date.add(DateTime.to_date(claimed_time), 2))

    dated_paths =
      Enum.flat_map(dates, fn date ->
        directory = Path.join([root, Integer.to_string(date.year), pad(date.month), pad(date.day)])

        case File.ls(directory) do
          {:ok, names} ->
            names
            |> Enum.filter(&(String.match?(&1, @thread_id_pattern) and filename_in_window?(&1, claimed_time)))
            |> Enum.map(&{Path.join(directory, &1), root})

          {:error, :enoent} ->
            []

          {:error, _reason} ->
            [:unreadable]
        end
      end)

    archived_paths = archive_paths(archive_root, claimed_time)
    paths = dated_paths ++ archived_paths

    cond do
      :unreadable in paths -> {:error, :native_session_directory_unreadable}
      length(paths) > @max_files -> {:error, :native_session_file_limit_exceeded}
      true -> {:ok, Enum.sort(paths)}
    end
  end

  defp archive_paths(nil, _claimed_time), do: []

  defp archive_paths(root, claimed_time) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.match?(&1, @thread_id_pattern) and filename_in_window?(&1, claimed_time)))
        |> Enum.map(&{Path.join(root, &1), root})

      _other ->
        [:unreadable]
    end
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp filename_in_window?(name, claimed_time) do
    with [_, date, hour, minute, second] <-
           Regex.run(~r/\Arollout-(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})-/, name),
         {:ok, naive} <- NaiveDateTime.from_iso8601("#{date}T#{hour}:#{minute}:#{second}") do
      # Rollout filenames use host local time; the session header carries the authoritative UTC timestamp.
      offset = NaiveDateTime.diff(naive, DateTime.to_naive(claimed_time), :second)
      offset in (-300 - @max_utc_offset_seconds)..(86_400 + @max_utc_offset_seconds)
    else
      _other -> false
    end
  end

  defp scan_paths(paths, request_key, source_thread_id, claimed_time) do
    Enum.reduce_while(paths, {:ok, []}, fn {path, root}, {:ok, candidates} ->
      case scan_path(path, root, request_key, source_thread_id, claimed_time) do
        {:ok, nil} -> {:cont, {:ok, candidates}}
        {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp scan_path(path, root, request_key, source_thread_id, claimed_time) do
    with :ok <- validate_session_path(path, root),
         {:ok, bytes, truncated?} <- read_head(path),
         {:ok, metadata, lines} <- parse_header(bytes),
         :ok <- validate_session_identity(metadata, path),
         true <- within_creation_window?(metadata, claimed_time) do
      find_creation_marker(metadata, lines, request_key, source_thread_id, truncated?)
    else
      false -> {:ok, nil}
      {:error, :unrelated_native_session} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp validate_session_path(path, root) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- String.starts_with?(canonical, root <> "/") do
      :ok
    else
      _other -> {:error, :unsafe_native_session_path}
    end
  end

  defp read_head(path) do
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, @max_head_bytes + 1) end) do
      {:ok, data} when is_binary(data) ->
        truncated? = byte_size(data) > @max_head_bytes
        {:ok, binary_part(data, 0, min(byte_size(data), @max_head_bytes)), truncated?}

      _other ->
        {:error, :native_session_unreadable}
    end
  end

  defp parse_header(bytes) do
    lines = String.split(bytes, "\n")
    complete_lines = if String.ends_with?(bytes, "\n"), do: lines, else: Enum.drop(lines, -1)

    case complete_lines do
      [first | rest] ->
        case Jason.decode(first) do
          {:ok, %{"type" => "session_meta", "payload" => metadata}} when is_map(metadata) ->
            {:ok, metadata, rest}

          _other ->
            {:error, :native_session_scan_incomplete}
        end

      _other ->
        {:error, :native_session_scan_incomplete}
    end
  end

  defp validate_session_identity(metadata, path) do
    with [_, filename_id] <- Regex.run(@thread_id_pattern, Path.basename(path)),
         true <- metadata["id"] == filename_id,
         true <- metadata["source"] == "vscode",
         true <- metadata["originator"] == "Codex Desktop",
         true <- metadata["thread_source"] == "agent_created_thread",
         true <- is_binary(metadata["cwd"]) and Path.type(metadata["cwd"]) == :absolute do
      :ok
    else
      _other -> {:error, :unrelated_native_session}
    end
  end

  defp within_creation_window?(metadata, claimed_time) do
    case DateTime.from_iso8601(metadata["timestamp"] || "") do
      {:ok, created_at, _offset} ->
        DateTime.diff(created_at, claimed_time, :second) in -300..86_400

      _other ->
        false
    end
  end

  defp find_creation_marker(metadata, lines, request_key, source_thread_id, truncated?) do
    found? = Enum.any?(lines, &creation_matches?(&1, request_key, source_thread_id))
    other_creation? = Enum.any?(lines, &other_creation_marker?(&1, request_key, source_thread_id))

    cond do
      found? ->
        {:ok, %{thread_id: metadata["id"], cwd: metadata["cwd"], created_at: metadata["timestamp"]}}

      other_creation? ->
        {:ok, nil}

      truncated? ->
        {:error, :native_session_scan_incomplete}

      true ->
        {:ok, nil}
    end
  end

  defp other_creation_marker?(line, request_key, source_thread_id) do
    with {:ok, %{"type" => "response_item", "payload" => payload}} <- Jason.decode(line),
         %{"type" => "function_call_output", "name" => "create_thread", "namespace" => "codex_app"} <- payload,
         output when is_binary(output) <- payload["output"],
         [_, source] <- Regex.run(~r/<source_thread_id>(.*?)<\/source_thread_id>/s, output),
         [_, input] <- Regex.run(~r/<input>(.*?)<\/input>/s, output),
         marker <- input |> String.trim_leading() |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      source != source_thread_id or marker != "Factory request ID: #{request_key}"
    else
      _other -> false
    end
  end

  defp creation_matches?(line, request_key, source_thread_id) do
    with {:ok, %{"type" => "response_item", "payload" => payload}} <- Jason.decode(line),
         %{"type" => "function_call_output", "name" => "create_thread", "namespace" => "codex_app"} <- payload,
         output when is_binary(output) <- payload["output"],
         [_, source] <- Regex.run(~r/<source_thread_id>(.*?)<\/source_thread_id>/s, output),
         true <- source == source_thread_id,
         [_, input] <- Regex.run(~r/<input>(.*?)<\/input>/s, output) do
      input
      |> String.trim_leading()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.trim()
      |> Kernel.==("Factory request ID: #{request_key}")
    else
      _other -> false
    end
  end

  defp unique_candidate([candidate]), do: {:ok, candidate}
  defp unique_candidate([]), do: {:error, :native_session_not_found}
  defp unique_candidate(_candidates), do: {:error, :native_session_ambiguous}
end
