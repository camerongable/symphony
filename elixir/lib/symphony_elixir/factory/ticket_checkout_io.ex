defmodule SymphonyElixir.Factory.TicketCheckoutIO do
  @moduledoc "One fixed Git checkout invocation with durable, independently readable terminal receipts."
  alias SymphonyElixir.Factory.{Store, WorkerFileIO}
  alias SymphonyElixir.PathSafety

  @helper Path.expand("../../../priv/ticket_checkout_executor.py", __DIR__)
  @external_resource @helper
  @helper_sha :crypto.hash(:sha256, File.read!(@helper)) |> Base.encode16(case: :lower)
  @git "/Library/Developer/CommandLineTools/usr/bin/git"
  @limit 262_144

  @spec prepare(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(store, intent, authorization) do
    binding = Jason.decode!(intent["binding_json"])

    with {:ok, helper} <- helper(binding["repo_path"]),
         :ok <- WorkerFileIO.program_outside_source(helper, binding["workspace_root"]),
         {:ok, spool} <- WorkerFileIO.controller_spool(store, binding["repo_path"]),
         :ok <- WorkerFileIO.workspace_allowed?(store, binding["workspace_root"]),
         {:ok, program} <- File.read(@git) do
      {:ok,
       Map.merge(spool, %{
         "invocation" => intent["owner_nonce"],
         "intent_json" => intent["binding_json"],
         "intent_sha256" => intent["binding_sha256"],
         "run_id" => intent["run_id"],
         "helper_path" => helper,
         "helper_sha256" => @helper_sha,
         "program_sha256" => hash(program),
         "authorization" => authorization
       })}
    end
  end

  @spec execute(map(), (pos_integer(), String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def execute(execution, started), do: exchange(execution, nil, "--execute", started)

  @spec readback(map()) :: {:ok, String.t()} | {:error, term()}
  def readback(intent) do
    with {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || ""),
         true <- is_integer(intent["helper_pid"]) do
      exchange(execution, intent["helper_pid"], "--status", nil)
    else
      _ -> {:error, :ticket_checkout_execution_unproven}
    end
  end

  defp exchange(execution, original_pid, mode, started) do
    with {:ok, path} <- helper(execution["root"]),
         true <- path == execution["helper_path"] and execution["helper_sha256"] == @helper_sha do
      port =
        Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(["-I", "-S", "-B", path, mode], &String.to_charlist/1),
          env: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
        ])

      try do
        {:os_pid, pid} = Port.info(port, :os_pid)
        encoded = Jason.encode!(execution)
        result = if started, do: started.(pid, encoded), else: {:ok, %{}}

        with {:ok, _} <- result do
          input = Jason.encode!(%{"execution_json" => encoded, "helper_pid" => original_pid || pid})
          true = Port.command(port, <<byte_size(input)::unsigned-big-32, input::binary>>)
          timeout_ms = if mode == "--execute", do: 610_000, else: 35_000
          collect(port, "", System.monotonic_time(:millisecond) + timeout_ms)
        end
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    else
      _ -> {:error, :ticket_checkout_program_changed}
    end
  rescue
    _ -> {:error, :ticket_checkout_transport_unproven}
  end

  defp collect(port, raw, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= @limit + 4 ->
        collect(port, raw <> bytes, deadline)

      {^port, {:exit_status, 0}} ->
        frame(raw)

      {^port, _} ->
        {:error, :ticket_checkout_transport_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :ticket_checkout_transport_unproven}
    end
  end

  defp frame(<<size::unsigned-big-32, raw::binary>>) when byte_size(raw) == size, do: {:ok, raw}
  defp frame(_), do: {:error, :ticket_checkout_transport_unproven}

  @spec receipt_valid?(String.t(), map()) :: boolean()
  def receipt_valid?(raw, intent) when is_binary(raw) and byte_size(raw) <= @limit do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(receipt)) == Enum.sort(~w(version execution_json helper_pid child_pid termination timed_out overflow output_base64 output_sha256)),
         true <- receipt["version"] == 1 and receipt["execution_json"] == intent["execution_json"],
         {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || ""),
         true <-
           {execution["run_id"], execution["invocation"], execution["intent_json"], execution["intent_sha256"]} ==
             {intent["run_id"], intent["owner_nonce"], intent["binding_json"], intent["binding_sha256"]},
         true <- is_integer(intent["helper_pid"]) and intent["helper_pid"] > 0 and receipt["helper_pid"] == intent["helper_pid"],
         true <- is_integer(receipt["child_pid"]) and receipt["child_pid"] > 0,
         true <- terminal?(receipt["termination"]),
         true <- receipt["timed_out"] in [true, false] and receipt["overflow"] in [true, false],
         {:ok, output} <- Base.decode64(receipt["output_base64"]),
         true <- byte_size(output) <= 65_536 and hash(output) == receipt["output_sha256"] do
      true
    else
      _ -> false
    end
  end

  def receipt_valid?(_, _), do: false
  defp terminal?(%{"kind" => "exited", "code" => code} = term), do: map_size(term) == 2 and is_integer(code) and code in 0..255
  defp terminal?(%{"kind" => "signaled", "signal" => signal} = term), do: map_size(term) == 2 and is_integer(signal) and signal in 1..64
  defp terminal?(_), do: false

  defp helper(root) do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_checkout_executor.py")),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == @helper_sha do
      {:ok, path}
    else
      _ -> {:error, :ticket_checkout_program_changed}
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
