defmodule SymphonyElixir.Factory.WorkerCheckIO do
  @moduledoc "Fixed controller check transport with durable owned-child receipts; never a worker shell."
  alias SymphonyElixir.Factory.{Store, WorkerFileIO}
  alias SymphonyElixir.PathSafety

  @helper Path.expand("../../../priv/worker_check_executor.py", __DIR__)
  @external_resource @helper
  @helper_sha :crypto.hash(:sha256, File.read!(@helper)) |> Base.encode16(case: :lower)
  @git "/Library/Developer/CommandLineTools/usr/bin/git"
  @profile ~S|(version 1)(deny default)(allow process-exec (literal "/Library/Developer/CommandLineTools/usr/bin/git"))(allow file-read*)(allow file-write* (literal "/dev/null"))(allow sysctl-read)(allow mach-lookup)|
  @limit 2_097_152
  @output_limit 1_048_576

  @spec policy(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def policy("git-diff-check", _root) do
    with {:ok, raw} <- File.read(@git) do
      {:ok, %{"action" => "git-diff-check", "program" => @git, "program_sha256" => hash(raw), "profile_sha256" => hash(@profile)}}
    end
  end

  def policy(_action, _root), do: {:error, :controller_check_action_not_authorized}

  @doc false
  @spec prepare(Store.connection(), Path.t()) :: {:ok, map()} | {:error, term()}
  def prepare(store, root) do
    with {:ok, helper} <- verified_helper(root),
         {:ok, transport} <- WorkerFileIO.controller_spool(store, root),
         {:ok, stat} <- File.stat(root) do
      {:ok,
       Map.merge(transport, %{
         "invocation" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
         "helper_path" => helper,
         "helper_sha256" => @helper_sha,
         "root_device" => stat.major_device,
         "root_inode" => stat.inode
       })}
    end
  end

  @doc false
  @spec execute(map(), (pos_integer() -> {:ok, map()} | {:error, term()})) :: {:ok, String.t()} | {:error, term()}
  def execute(row, started), do: exchange(row, "--execute", started)

  @doc false
  @spec readback(map()) :: {:ok, String.t()} | {:error, term()}
  def readback(row), do: exchange(row, "--status", nil)

  defp exchange(row, mode, started) do
    binding = Jason.decode!(row["binding_json"])

    with {:ok, helper} <- verified_helper(binding["root"]),
         true <-
           (helper == binding["helper_path"] and @helper_sha == binding["helper_sha256"]) or
             {:error, :controller_check_program_changed} do
      args = ["-I", "-S", "-B", helper, mode]
      port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1), env: cleared_environment()])

      try do
        {:os_pid, pid} = Port.info(port, :os_pid)

        with {:ok, active} <- start_or_read(row, started, pid) do
          input = Jason.encode!(%{"binding_json" => row["binding_json"], "helper_pid" => active["helper_pid"]})
          true = Port.command(port, <<byte_size(input)::unsigned-big-32, input::binary>>)
          collect(port, "", System.monotonic_time(:millisecond) + 30_000)
        end
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    else
      {:error, reason} -> if mode == "--execute", do: {:error, {:controller_check_not_started, reason}}, else: {:error, reason}
    end
  rescue
    _ -> {:error, :controller_check_transport_unproven}
  end

  defp start_or_read(row, nil, _pid), do: {:ok, row}
  defp start_or_read(_row, started, pid), do: started.(pid)

  defp collect(port, raw, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= @limit + 4 ->
        collect(port, raw <> bytes, deadline)

      {^port, {:exit_status, 0}} ->
        decode_frame(raw)

      {^port, _} ->
        {:error, :controller_check_transport_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :controller_check_transport_unproven}
    end
  end

  defp decode_frame(<<size::unsigned-big-32, raw::binary>>) when byte_size(raw) == size, do: {:ok, raw}
  defp decode_frame(_), do: {:error, :controller_check_transport_unproven}

  @doc false
  @spec receipt_valid?(term(), map(), term()) :: boolean()
  def receipt_valid?(raw, binding, helper_pid) when is_binary(raw) and byte_size(raw) <= @limit do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(receipt)) == Enum.sort(~w(version binding_json helper_pid pid cwd base_sha candidate_sha termination result output_base64 output_sha256 timed_out overflow)),
         true <- receipt["version"] == 1 and receipt["binding_json"] == Jason.encode!(binding),
         true <- producer_identity?(receipt, helper_pid),
         true <- Map.take(receipt, ~w(cwd base_sha candidate_sha)) == Map.take(binding, ~w(cwd base_sha candidate_sha)),
         true <- receipt["timed_out"] in [true, false] and receipt["overflow"] in [true, false],
         true <- terminal?(receipt["termination"]),
         {:ok, output} <- Base.decode64(receipt["output_base64"]),
         true <- byte_size(output) <= @output_limit and hash(output) == receipt["output_sha256"] do
      expected = if receipt["termination"] == %{"kind" => "exited", "code" => 0} and not receipt["timed_out"] and not receipt["overflow"], do: "PASS", else: "FAIL"
      receipt["result"] == expected
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def receipt_valid?(_raw, _binding, _pid), do: false

  defp producer_identity?(receipt, helper_pid),
    do:
      is_integer(helper_pid) and helper_pid > 0 and receipt["helper_pid"] == helper_pid and
        is_integer(receipt["pid"]) and receipt["pid"] > 0

  defp terminal?(%{"kind" => "exited", "code" => code} = term), do: map_size(term) == 2 and is_integer(code) and code in 0..255
  defp terminal?(%{"kind" => "signaled", "signal" => signal} = term), do: map_size(term) == 2 and is_integer(signal) and signal in 1..64
  defp terminal?(_), do: false

  defp verified_helper(root) do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/worker_check_executor.py")),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == @helper_sha or {:error, :controller_check_program_changed},
         do: {:ok, path}
  end

  defp cleared_environment, do: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
