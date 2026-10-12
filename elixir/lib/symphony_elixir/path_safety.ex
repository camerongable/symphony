defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, %{}) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  @spec resolve_segments(String.t(), [String.t()], [String.t()], %{optional(String.t()) => true}) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_segments(root, resolved_segments, [], _active_symlinks), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], active_symlinks) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(root, resolved_segments, rest, active_symlinks, candidate_path)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, active_symlinks)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resolve_symlink(String.t(), [String.t()], [String.t()], %{optional(String.t()) => true}, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_symlink(root, resolved_segments, rest, active_symlinks, candidate_path) do
    if Map.has_key?(active_symlinks, candidate_path) do
      {:error, :eloop}
    else
      with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
        resolve_symlink_target(root, resolved_segments, rest, active_symlinks, candidate_path, target)
      end
    end
  end

  @spec resolve_symlink_target(
          String.t(),
          [String.t()],
          [String.t()],
          %{optional(String.t()) => true},
          String.t(),
          charlist() | binary()
        ) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_symlink_target(root, resolved_segments, rest, active_symlinks, candidate_path, target) do
    resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
    {target_root, target_segments} = split_absolute_path(resolved_target)
    active_during_target = Map.put(active_symlinks, candidate_path, true)

    with {:ok, canonical_target} <- resolve_segments(target_root, [], target_segments, active_during_target) do
      {canonical_root, canonical_segments} = split_absolute_path(canonical_target)
      resolve_segments(canonical_root, canonical_segments, rest, active_symlinks)
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
