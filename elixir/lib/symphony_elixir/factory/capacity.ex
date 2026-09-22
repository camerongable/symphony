defmodule SymphonyElixir.Factory.Capacity do
  @moduledoc """
  Admission control for specification, source-writing, and manual-validation work.

  Writer capacity is bounded by both configured concurrency and currently free
  disk. Jira-observed writer issue keys can be supplied and are deduplicated
  against local run ownership.
  """

  alias SymphonyElixir.Factory.Store

  @active_specifier_states ~w(SPECIFYING SPEC_DRAFTING SPEC_WRITING AWAITING_JIRA_READBACK SPEC_REVIEW CRITIQUING SPEC_READY_WRITE)
  @active_writer_states ~w(WRITING VERIFYING REPAIRING DELIVERING)
  @active_validator_states ~w(TESTING)

  @doc """
  Returns current per-pool capacity for a configured repository route.
  """
  @spec snapshot(Store.connection(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(connection, policy, repo_key, opts \\ []) do
    with {:ok, repository} <- fetch_path(policy, ["repositories", repo_key]),
         {:ok, capacity} <- capacity_policy(policy),
         repo_path when is_binary(repo_path) <- value(repository, "path"),
         {:ok, free_bytes} <- disk_free_bytes(repo_path, opts) do
      writer_disk_gb = value(capacity, "writer_disk_gb")
      bytes_per_writer = trunc(writer_disk_gb * 1_000_000_000)
      disk_writer_slots = div(free_bytes, bytes_per_writer)

      local_writer_keys = active_issue_keys(connection, nil, @active_writer_states)

      writer_keys =
        local_writer_keys
        |> MapSet.union(external_issue_keys(opts, :external_writer_issue_keys))
        |> maybe_exclude(Keyword.get(opts, :exclude_writer_issue_key))

      specifier_keys =
        connection
        |> active_issue_keys("SPECIFICATION", @active_specifier_states)
        |> MapSet.union(external_issue_keys(opts, :external_specifier_issue_keys))

      validator_keys =
        connection
        |> active_issue_keys("VALIDATION", @active_validator_states)
        |> MapSet.union(external_issue_keys(opts, :external_validator_issue_keys))

      active_writers = MapSet.size(writer_keys)
      active_specifiers = MapSet.size(specifier_keys)
      active_validators = MapSet.size(validator_keys)
      maximum_writers = value(capacity, "maximum_writers")
      maximum_specifiers = value(capacity, "maximum_specifiers")
      maximum_validators = value(capacity, "maximum_validators")

      writer_slots = max(0, min(maximum_writers - active_writers, disk_writer_slots))
      specifier_slots = max(0, maximum_specifiers - active_specifiers)
      validator_slots = max(0, maximum_validators - active_validators)

      {:ok,
       %{
         result: if(writer_slots > 0, do: "PASS", else: "INSUFFICIENT_WRITER_CAPACITY"),
         repo_key: repo_key,
         repo_path: repo_path,
         free_bytes: free_bytes,
         free_gb: Float.round(free_bytes / 1_000_000_000, 2),
         free_gib: Float.round(free_bytes / 1_073_741_824, 2),
         writer_disk_gb: writer_disk_gb,
         disk_writer_slots: disk_writer_slots,
         active_specifiers: active_specifiers,
         maximum_specifiers: maximum_specifiers,
         available_specifier_slots: specifier_slots,
         active_writers: active_writers,
         maximum_writers: maximum_writers,
         available_writer_slots: writer_slots,
         active_validators: active_validators,
         maximum_validators: maximum_validators,
         available_validator_slots: validator_slots
       }}
    else
      nil -> {:error, :invalid_capacity_policy}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_capacity_policy}
    end
  end

  @doc """
  Returns the current free bytes for the filesystem containing a path.
  """
  @spec free_bytes(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes(path) do
    case System.cmd("/bin/df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} -> parse_df_free_bytes(output)
      {output, status} -> {:error, {:df_failed, status, String.trim(output)}}
    end
  end

  defp disk_free_bytes(repo_path, opts) do
    case Keyword.fetch(opts, :free_bytes) do
      {:ok, free_bytes} when is_integer(free_bytes) and free_bytes >= 0 -> {:ok, free_bytes}
      {:ok, invalid} -> {:error, {:invalid_free_bytes, invalid}}
      :error -> free_bytes(repo_path)
    end
  end

  defp active_issue_keys(connection, kind, states) when not is_nil(kind) do
    placeholders = Enum.map_join(states, ", ", fn _state -> "?" end)

    result =
      Store.query!(
        connection,
        "SELECT DISTINCT issue_key FROM runs WHERE kind = ? AND state IN (#{placeholders})",
        [kind | states]
      )

    result.rows
    |> Enum.map(fn [issue_key] -> issue_key end)
    |> MapSet.new()
  end

  defp active_issue_keys(connection, nil, states) do
    placeholders = Enum.map_join(states, ", ", fn _state -> "?" end)

    result =
      Store.query!(
        connection,
        "SELECT DISTINCT issue_key FROM runs WHERE state IN (#{placeholders})",
        states
      )

    result.rows
    |> Enum.map(fn [issue_key] -> issue_key end)
    |> MapSet.new()
  end

  defp external_issue_keys(opts, key) do
    opts
    |> Keyword.get(key, [])
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp maybe_exclude(keys, nil), do: keys
  defp maybe_exclude(keys, issue_key), do: MapSet.delete(keys, to_string(issue_key))

  defp parse_df_free_bytes(output) do
    case output |> String.split("\n", trim: true) |> List.last() |> String.split(~r/\s+/, trim: true) do
      [_filesystem, _blocks, _used, available_kib | _rest] ->
        case Integer.parse(available_kib) do
          {available, ""} when available >= 0 -> {:ok, available * 1_024}
          _other -> {:error, {:invalid_df_output, output}}
        end

      _other ->
        {:error, {:invalid_df_output, output}}
    end
  end

  defp fetch_path(policy, path) do
    Enum.reduce_while(path, {:ok, policy}, fn key, {:ok, current} ->
      case value(current, key) do
        nil -> {:halt, {:error, {:missing_capacity_policy, Enum.join(path, ".")}}}
        found -> {:cont, {:ok, found}}
      end
    end)
  end

  defp capacity_policy(policy) do
    case value(policy, "capacity") do
      nil -> {:ok, policy}
      capacity when is_map(capacity) -> {:ok, capacity}
      _other -> {:error, :invalid_capacity_policy}
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> value_from_existing_atom(map, key, default)
    end
  end

  defp value(_map, _key, default), do: default

  defp value_from_existing_atom(map, key, default) do
    Map.get(map, String.to_existing_atom(key), default)
  rescue
    ArgumentError -> default
  end
end
