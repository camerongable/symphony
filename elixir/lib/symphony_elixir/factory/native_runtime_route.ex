defmodule SymphonyElixir.Factory.NativeRuntimeRoute do
  @moduledoc "Explicit experimental storage identity for an owned local native reader, not issuance authority."
  alias SymphonyElixir.{Config, PathSafety}
  import Bitwise

  @enforce_keys [:codex_home, :sqlite_home]
  defstruct [:codex_home, :sqlite_home]
  @opaque t :: %__MODULE__{codex_home: map(), sqlite_home: map()}

  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = route) do
    with {:ok, _storage} <- storage(route), do: {:ok, route}
  end

  def validate(%{"version" => 1, "codex_home" => codex, "sqlite_home" => sqlite} = descriptor) when map_size(descriptor) == 3 do
    with {:ok, uid} <- executing_uid(),
         {:ok, roots} <- protected_roots(),
         {:ok, codex} <- private_directory(codex, uid, roots),
         {:ok, sqlite} <- private_directory(sqlite, uid, roots) do
      {:ok, %__MODULE__{codex_home: codex, sqlite_home: sqlite}}
    end
  end

  def validate(_descriptor), do: {:error, :native_runtime_route_invalid}

  @spec origin(t()) :: {:ok, map()} | {:error, term()}
  def origin(%__MODULE__{} = route) do
    with {:ok, _storage} <- storage(route) do
      {:ok, %{"version" => 2, "codex_home" => encode_directory(route.codex_home), "sqlite_home" => encode_directory(route.sqlite_home)}}
    end
  end

  def origin(_route), do: {:error, :native_runtime_route_invalid}

  @spec restore_origin(term()) :: {:ok, t()} | {:error, term()}
  def restore_origin(%{"version" => 2, "codex_home" => codex, "sqlite_home" => sqlite} = envelope) when map_size(envelope) == 3 do
    with {:ok, codex} <- decode_directory(codex),
         {:ok, sqlite} <- decode_directory(sqlite),
         {:ok, route} <- validate(%__MODULE__{codex_home: codex, sqlite_home: sqlite}) do
      {:ok, route}
    end
  end

  def restore_origin(_envelope), do: {:error, :native_runtime_origin_invalid}

  @doc "Checks only the serialized origin format; it grants no current storage authority."
  @spec validate_origin_format(term()) :: :ok | {:error, atom()}
  def validate_origin_format(%{"version" => 2, "codex_home" => codex, "sqlite_home" => sqlite} = origin) when map_size(origin) == 3 do
    if directory_format?(codex) and directory_format?(sqlite), do: :ok, else: {:error, :native_runtime_origin_invalid}
  end

  def validate_origin_format(_origin), do: {:error, :native_runtime_origin_invalid}

  @spec storage(t()) :: {:ok, map()} | {:error, term()}
  def storage(%__MODULE__{codex_home: %{path: codex}, sqlite_home: %{path: sqlite}} = route) do
    with {:ok, current} <- validate(%{"version" => 1, "codex_home" => codex, "sqlite_home" => sqlite}),
         true <- current === route or {:error, :native_runtime_storage_changed} do
      {:ok,
       %{
         codex_home: codex,
         sqlite_home: sqlite,
         env: [{~c"CODEX_HOME", String.to_charlist(codex)}, {~c"CODEX_SQLITE_HOME", String.to_charlist(sqlite)}],
         overrides: ["sqlite_home=" <> Jason.encode!(sqlite)]
       }}
    end
  end

  def storage(_route), do: {:error, :native_runtime_route_invalid}

  defp encode_directory(%{path: path, device: {major, minor}, inode: inode, uid: uid}) do
    %{"path" => path, "device" => [major, minor], "inode" => inode, "uid" => uid}
  end

  defp decode_directory(%{"path" => path, "device" => [major, minor], "inode" => inode, "uid" => uid} = directory)
       when map_size(directory) == 4 and is_binary(path) and byte_size(path) > 0 and is_integer(major) and major >= 0 and is_integer(minor) and minor >= 0 and is_integer(inode) and inode > 0 and
              is_integer(uid) and uid >= 0 do
    if directory_format?(directory) and PathSafety.canonicalize(path) == {:ok, path} do
      {:ok, %{path: path, device: {major, minor}, inode: inode, uid: uid}}
    else
      {:error, :native_runtime_origin_invalid}
    end
  end

  defp decode_directory(_directory), do: {:error, :native_runtime_origin_invalid}

  defp directory_format?(%{"path" => path, "device" => [major, minor], "inode" => inode, "uid" => uid} = directory)
       when map_size(directory) == 4 and is_binary(path) and byte_size(path) > 0 and is_integer(major) and major >= 0 and is_integer(minor) and minor >= 0 and is_integer(inode) and inode > 0 and
              is_integer(uid) and uid >= 0 do
    String.valid?(path) and Path.type(path) == :absolute and not Regex.match?(~r/\p{Cc}/u, path) and Path.expand(path) == path
  end

  defp directory_format?(_directory), do: false

  defp executing_uid do
    case System.cmd("/usr/bin/id", ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _ -> {:error, :native_runtime_uid_unproven}
        end

      _ ->
        {:error, :native_runtime_uid_unproven}
    end
  rescue
    _ -> {:error, :native_runtime_uid_unproven}
  end

  defp protected_roots do
    with {:ok, settings} <- Config.settings() do
      sources = settings.factory.repositories |> Map.values() |> Enum.map(&Map.get(&1, "path")) |> Enum.reject(&is_nil/1)
      broad = ["/", System.user_home!(), System.tmp_dir!(), "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
      roots = Enum.map(broad, &{&1, true}) ++ Enum.map([Config.local_workspace_root() | sources], &{&1, false})

      Enum.reduce_while(roots, {:ok, []}, fn {path, broad?}, {:ok, roots} ->
        case PathSafety.canonicalize(path) do
          {:ok, canonical} -> {:cont, {:ok, [{canonical, broad?} | roots]}}
          _ -> {:halt, {:error, :native_runtime_protected_roots_unproven}}
        end
      end)
    end
  end

  defp private_directory(path, uid, roots) when is_binary(path) and byte_size(path) > 0 do
    with true <- String.valid?(path) and Path.type(path) == :absolute and not Regex.match?(~r/\p{Cc}/u, path),
         {:ok, canonical} <- PathSafety.canonicalize(path),
         false <- Enum.any?(roots, fn {root, broad?} -> canonical == root or (not broad? and overlap?(canonical, root)) end),
         {:ok, stat} <- File.stat(canonical),
         true <- stat.type == :directory and stat.uid == uid and band(stat.mode, 0o7777) == 0o700 do
      {:ok, %{path: canonical, device: {stat.major_device, stat.minor_device}, inode: stat.inode, uid: stat.uid}}
    else
      _ -> {:error, :native_runtime_storage_unsafe}
    end
  end

  defp private_directory(_path, _uid, _roots), do: {:error, :native_runtime_storage_unsafe}

  defp overlap?(left, right), do: left == "/" or right == "/" or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
end
