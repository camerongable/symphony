defmodule SymphonyElixir.Factory.TicketCiGenerationIO do
  @moduledoc "Owned generation supervisor transport; recovery reads the original invocation only."
  alias SymphonyElixir.Factory.WorkerFileIO
  alias SymphonyElixir.PathSafety

  @helper Path.expand("../../../priv/controller_generation_executor_v1.py", __DIR__)
  @external_resource @helper
  @helper_sha :crypto.hash(:sha256, File.read!(@helper)) |> Base.encode16(case: :lower)
  @observer Path.expand("../../../priv/controller_generation_io_v1.py", __DIR__)
  @external_resource @observer
  @observer_sha :crypto.hash(:sha256, File.read!(@observer)) |> Base.encode16(case: :lower)
  @ordinary_helper Path.expand("../../../priv/controller_generation_executor_v2.py", __DIR__)
  @external_resource @ordinary_helper
  @ordinary_helper_sha :crypto.hash(:sha256, File.read!(@ordinary_helper)) |> Base.encode16(case: :lower)
  @ordinary_observer Path.expand("../../../priv/controller_generation_io_v2.py", __DIR__)
  @external_resource @ordinary_observer
  @ordinary_observer_sha :crypto.hash(:sha256, File.read!(@ordinary_observer)) |> Base.encode16(case: :lower)
  @generated_helper Path.expand("../../../priv/controller_generation_executor_v3.py", __DIR__)
  @external_resource @generated_helper
  @generated_helper_sha :crypto.hash(:sha256, File.read!(@generated_helper)) |> Base.encode16(case: :lower)
  @retry_helper Path.expand("../../../priv/controller_generation_executor_v4.py", __DIR__)
  @external_resource @retry_helper
  @retry_helper_sha :crypto.hash(:sha256, File.read!(@retry_helper)) |> Base.encode16(case: :lower)
  @static_helper Path.expand("../../../priv/controller_generation_executor_v5.py", __DIR__)
  @external_resource @static_helper
  @static_helper_sha :crypto.hash(:sha256, File.read!(@static_helper)) |> Base.encode16(case: :lower)
  @limit 2_097_152

  @spec observe(map(), [String.t()], 1 | 2 | 3) :: {:ok, map()} | {:error, atom()}
  def observe(transport, paths, version \\ 1) do
    expected = if version == 2, do: @ordinary_observer_sha, else: @observer_sha

    with true <- version in [1, 2, 3],
         {:ok, observer} <- PathSafety.canonicalize(observer_path(version)),
         :ok <- WorkerFileIO.program_outside_source(observer, transport["root"]),
         {:ok, raw} <- File.read(observer),
         true <- hash(raw) == expected,
         {:ok, before} <- File.lstat(transport["spool"]),
         true <- {before.major_device, before.inode} == {transport["spool_device"], transport["spool_inode"]} do
      args = ["-I", "-S", "-B", observer, "observe", transport["root"], Jason.encode!(paths)]
      port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1)])
      {:os_pid, pid} = Port.info(port, :os_pid)
      nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      started = System.monotonic_time(:millisecond)

      try do
        {termination, output} = observe_collect(port, "", started + 7_000)
        {termination, output} = if termination == :deadline, do: kill_observer(port, pid, output), else: {termination, output}

        receipt = %{
          "version" => 1,
          "kind" => "CONTROLLER_GENERATION_OBSERVATION",
          "pid" => pid,
          "invocation" => nonce,
          "observer_sha256" => expected,
          "root" => transport["root"],
          "paths" => paths,
          "termination" => termination,
          "output_sha256" => hash(output),
          "output_bytes" => byte_size(output)
        }

        name = Path.join(transport["spool"], nonce <> ".generation-observation")

        with :ok <- File.write(name, Jason.encode!(receipt), [:exclusive, :sync]),
             {:ok, after_write} <- File.lstat(transport["spool"]),
             true <- {after_write.major_device, after_write.inode} == {before.major_device, before.inode},
             true <- termination == %{"kind" => "exited", "code" => 0},
             {:ok, %{"version" => 1, "files" => _} = result} <- Jason.decode(output) do
          {:ok, Map.put(result, "owned_observer_receipt", receipt)}
        else
          _ -> {:error, :controller_generation_observer_unproven}
        end
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    else
      _ -> {:error, :controller_generation_observer_unproven}
    end
  rescue
    _ -> {:error, :controller_generation_observer_unproven}
  end

  defp observer_path(1), do: Application.app_dir(:symphony_elixir, "priv/controller_generation_io_v1.py")
  defp observer_path(2), do: Application.app_dir(:symphony_elixir, "priv/controller_generation_io_v2.py")
  defp observer_path(3), do: observer_path(1)

  defp observe_collect(port, bytes, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:deadline, bytes}
    else
      receive do
        {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= @limit -> observe_collect(port, bytes <> chunk, deadline)
        {^port, {:exit_status, code}} -> {%{"kind" => "exited", "code" => code}, bytes}
        {^port, _} -> {:deadline, bytes}
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:deadline, bytes}
      end
    end
  end

  defp kill_observer(port, pid, bytes) do
    _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

    case observe_collect(port, bytes, System.monotonic_time(:millisecond) + 2_000) do
      {%{"kind" => "exited", "code" => code}, output} -> {%{"kind" => "killed_and_reaped", "exit_status" => code}, output}
      {_, output} -> {%{"kind" => "stop_unproven"}, output}
    end
  end

  @spec binding(Path.t(), 1 | 2 | 3 | 4 | 5) :: {:ok, map()} | {:error, atom()}
  def binding(root, version \\ 1) do
    with {:ok, helper} <- helper(root, version) do
      {:ok,
       %{
         "helper_path" => helper,
         "helper_sha256" => helper_sha(version),
         "invocation" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
       }}
    end
  end

  @spec execute(map(), (pos_integer() -> :ok | {:error, term()}), (binary() -> :ok | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def execute(binding, started, creator),
    do:
      exchange(
        binding,
        if(binding["started_type"] == "APPLY_STARTED", do: "--apply", else: "--execute"),
        started,
        creator
      )

  @spec status(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def status(binding, pid), do: exchange(binding, "--status", pid, nil)

  defp exchange(binding, mode, started, creator) do
    version = execution_version(binding)

    with {:ok, helper} <- helper(binding["root"], version),
         true <- helper == binding["helper_path"] and binding["helper_sha256"] == helper_sha(version),
         raw = Jason.encode!(binding),
         true <- byte_size(raw) <= @limit do
      environment = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
      args = ["-I", "-S", "-B", helper, mode]
      port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1), env: environment])

      try do
        {:os_pid, pid} = Port.info(port, :os_pid)

        with {:ok, producer} <- start(started, pid),
             true <- Port.command(port, frame(%{"binding_json" => raw, "helper_pid" => producer})),
             {:ok, receipt} <- collect(port, "", nil, creator, System.monotonic_time(:millisecond) + if(mode == "--execute", do: 116_000, else: 10_000)),
             true <- receipt["binding_json"] == raw and receipt["helper_pid"] == producer and receipt["version"] == 1 do
          {:ok, receipt}
        else
          {:error, _} = error -> error
          _ -> {:error, :controller_generation_transport_unproven}
        end
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    else
      _ -> {:error, :controller_generation_program_changed}
    end
  rescue
    _ -> {:error, :controller_generation_transport_unproven}
  end

  defp execution_version(%{"generation_version" => 3}), do: 3
  defp execution_version(%{"generation_version" => 4}), do: 4
  defp execution_version(%{"generation_version" => 5}), do: 5

  defp execution_version(binding) do
    if String.starts_with?(binding["intent_key"] || "", "ordinary-generation:"), do: 2, else: 1
  end

  defp start(pid, _) when is_integer(pid) and pid > 0, do: {:ok, pid}

  defp start(callback, pid) when is_function(callback, 1) do
    case callback.(pid) do
      :ok -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  defp frame(value) do
    raw = Jason.encode!(value)
    <<byte_size(raw)::unsigned-big-32, raw::binary>>
  end

  defp collect(port, bytes, result, creator, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= @limit + 4 ->
        with {:ok, tail, result} <- messages(port, bytes <> chunk, result, creator) do
          collect(port, tail, result, creator, deadline)
        end

      {^port, {:exit_status, 0}} when bytes == "" and is_map(result) ->
        {:ok, result}

      {^port, _} ->
        {:error, :controller_generation_transport_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :controller_generation_transport_unproven}
    end
  end

  defp messages(port, <<size::unsigned-big-32, bytes::binary>>, result, creator) when size <= @limit and byte_size(bytes) >= size do
    <<raw::binary-size(size), tail::binary>> = bytes

    with {:ok, message} <- Jason.decode(raw),
         {:ok, result} <- message(port, message, result, creator) do
      messages(port, tail, result, creator)
    end
  end

  defp messages(_port, <<size::unsigned-big-32, _::binary>>, _, _) when size > @limit, do: {:error, :controller_generation_frame_unproven}
  defp messages(_port, bytes, result, _creator), do: {:ok, bytes, result}

  defp message(port, %{"kind" => "creator", "receipt" => raw} = message, nil, callback) when map_size(message) == 2 and is_function(callback, 1) do
    with :ok <- callback.(raw),
         true <- Port.command(port, frame(%{"kind" => "creator_ack", "sha256" => hash(raw)})) do
      {:ok, nil}
    end
  end

  defp message(_port, %{"kind" => "result", "receipt" => raw} = message, nil, _) when map_size(message) == 2 and is_binary(raw), do: Jason.decode(raw)
  defp message(_, _, _, _), do: {:error, :controller_generation_frame_unproven}

  defp helper_sha(1), do: @helper_sha
  defp helper_sha(2), do: @ordinary_helper_sha
  defp helper_sha(3), do: @generated_helper_sha
  defp helper_sha(4), do: @retry_helper_sha
  defp helper_sha(5), do: @static_helper_sha

  defp helper(root, version) do
    with true <- version in [1, 2, 3, 4, 5],
         {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/controller_generation_executor_v#{version}.py")),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == helper_sha(version) do
      {:ok, path}
    else
      _ -> {:error, :controller_generation_program_changed}
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
