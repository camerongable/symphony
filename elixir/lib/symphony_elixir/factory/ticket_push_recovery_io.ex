defmodule SymphonyElixir.Factory.TicketPushRecoveryIO do
  @moduledoc "Fixed remote-CAS helper and genuine new-invocation receipt readback."
  alias SymphonyElixir.Factory.{TicketPushIO, TicketPushWorkerHistory, WorkerFileIO}
  @helper Path.expand("../../../priv/ticket_push_recovery_executor.py", __DIR__)
  @external_resource @helper
  @sha :crypto.hash(:sha256, File.read!(@helper)) |> Base.encode16(case: :lower)
  @limit 262_144

  @spec prepare(term(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(store, intent, authorization, opts) do
    original = Jason.decode!(intent["original_envelope"])
    old_execution = Jason.decode!(original["execution_json"])
    binding = Jason.decode!(intent["binding_json"])

    with {:ok, capability} <- TicketPushWorkerHistory.capability_recovery(store, binding["run_id"]),
         true <- not capability or {:error, :capability_history_requires_current_push_readback},
         {:ok, base} <- TicketPushIO.prepare(store, intent, authorization),
         {:ok, tick} <- SymphonyElixir.Factory.TicketPushRecovery.tick_binding(store, opts),
         {:ok, history} <- TicketPushWorkerHistory.observe(store, binding["run_id"]),
         :ok <- WorkerFileIO.program_outside_source(@helper, binding["worktree"]),
         true <- hash(File.read!(@helper)) == @sha or {:error, :push_recovery_program_changed} do
      execution =
        Map.merge(base, %{
          "helper_path" => @helper,
          "helper_sha256" => @sha,
          "git_environment" => old_execution["git_environment"],
          "worker_history" => history,
          "operator_tick" => tick,
          "original_envelope_sha256" => hash(intent["original_envelope"])
        })

      with :ok <- budget(execution), do: {:ok, execution}
    end
  end

  @spec execute(map(), function()) :: {:ok, String.t()} | {:error, term()}
  def execute(execution, started), do: exchange(execution, nil, "--execute", started)

  @spec readback(map()) :: {:ok, String.t()} | {:error, term()}
  def readback(intent) do
    with {:ok, execution} <- Jason.decode(intent["execution_json"] || "null"),
         true <- (is_map(execution) and is_integer(intent["helper_pid"])) or {:error, :push_recovery_execution_missing} do
      exchange(execution, intent["helper_pid"], "--status", nil)
    end
  end

  @spec receipt_valid?(String.t(), map()) :: boolean()
  def receipt_valid?(raw, intent) do
    with {:ok, receipt} <- Jason.decode(raw),
         true <-
           is_map(receipt) and
             Enum.sort(Map.keys(receipt)) == ~w(child_pid execution_json helper_pid output_base64 output_sha256 overflow stderr_bytes stderr_code stderr_sha256 termination timed_out version),
         true <- receipt["stderr_code"] in ~w(GIT_EXIT_ZERO GIT_EXIT_NONZERO CAS_REF_CHANGED AUTHENTICATION_DENIED TRANSPORT_FAILURE),
         true <- is_integer(receipt["stderr_bytes"]) and receipt["stderr_bytes"] in 0..16_384,
         true <- is_binary(receipt["stderr_sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["stderr_sha256"]),
         true <- receipt["version"] == 1 and intent["kind"] == "TICKET_PUSH_CAS_RECOVERY",
         true <- receipt["execution_json"] == intent["execution_json"] and receipt["helper_pid"] == intent["helper_pid"],
         true <- is_integer(receipt["child_pid"]) and receipt["child_pid"] > 0,
         true <- receipt["timed_out"] == false and receipt["overflow"] == false,
         %{"kind" => "exited", "code" => code} <- receipt["termination"],
         true <- is_integer(code) and code in 0..255,
         true <- receipt["output_base64"] == "" and receipt["output_sha256"] == hash("") do
      true
    else
      _ -> false
    end
  end

  @spec helper_sha() :: String.t()
  def helper_sha, do: @sha

  @spec budget(map()) :: :ok | {:error, atom()}
  def budget(execution) do
    bytes = byte_size(Jason.encode!(%{"execution_json" => Jason.encode!(execution), "helper_pid" => 2_147_483_647}))
    if bytes + 1_024 <= @limit, do: :ok, else: {:error, :push_recovery_packet_budget_exceeded}
  end

  defp exchange(execution, original_pid, mode, started) do
    with true <- execution["helper_path"] == @helper and execution["helper_sha256"] == @sha,
         true <- hash(File.read!(@helper)) == @sha do
      port =
        Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(["-I", "-S", "-B", @helper, mode], &String.to_charlist/1),
          env: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
        ])

      try do
        {:os_pid, pid} = Port.info(port, :os_pid)
        encoded = Jason.encode!(execution)
        result = if started, do: started.(pid, encoded), else: {:ok, %{}}

        with {:ok, _} <- result do
          packet = Jason.encode!(%{"execution_json" => encoded, "helper_pid" => original_pid || pid})
          true = byte_size(packet) <= @limit and Port.command(port, <<byte_size(packet)::unsigned-big-32, packet::binary>>)
          collect(port, "", System.monotonic_time(:millisecond) + 33_000)
        end
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    else
      _ -> {:error, :push_recovery_program_changed}
    end
  rescue
    _ -> {:error, :push_recovery_transport_unproven}
  end

  defp collect(port, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= @limit + 4 -> collect(port, bytes <> chunk, deadline)
      {^port, {:exit_status, 0}} -> frame(bytes)
      {^port, {:exit_status, code}} -> {:error, {:push_recovery_transport_exit, code, diagnostic(bytes), hash(bytes)}}
      {^port, _} -> {:error, :push_recovery_transport_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :push_recovery_transport_timeout}
    end
  end

  defp frame(<<size::unsigned-big-32, raw::binary>>) when byte_size(raw) == size, do: {:ok, raw}
  defp frame(_), do: {:error, :push_recovery_frame_invalid}

  defp diagnostic(bytes) do
    case Regex.run(~r/(?:ValueError|TimeoutExpired|PermissionError|FileNotFoundError): ([a-z_]{1,64})\s*\z/, bytes) do
      [_, reason] -> reason
      _ -> "unclassified_transport_exit"
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
