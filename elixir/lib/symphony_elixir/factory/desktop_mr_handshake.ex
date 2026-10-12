defmodule SymphonyElixir.Factory.DesktopMrHandshake do
  @moduledoc "Bounded stdin handoff for fresh owning-Desktop observations; never emits authorization."

  @maximum_bytes 65_536

  @spec observe(map(), String.t(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def observe(request, broker, timeout_ms \\ 40_000) when is_integer(timeout_ms) and timeout_ms > 0 do
    IO.puts(
      Jason.encode!(%{
        status: "OWNER_OBSERVATION_REQUIRED",
        request_key: request["request_key"],
        controller_thread_id: request["existing_thread_id"],
        source_thread_id: broker
      })
    )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    task = Task.async(fn -> read_line([], 0) end)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, line}} -> parse(line, request["request_key"], broker)
      {:ok, {:error, _} = error} -> error
      _ -> {:error, :mr_owner_input_timeout}
    end
  end

  @spec parse(binary(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(line, key, broker) when is_binary(line) do
    with true <- byte_size(line) <= @maximum_bytes,
         {:ok, input} when is_map(input) <- Jason.decode(line),
         true <- Enum.sort(Map.keys(input)) == ~w(owner request_key source_thread_id),
         true <- input["request_key"] == key and input["source_thread_id"] == broker,
         %{"source" => "codex_app/read_thread", "observed_at" => at, "response" => %{"schemaVersion" => 1, "thread" => thread}} = owner <- input["owner"],
         true <- is_binary(at) and is_map(thread) do
      {:ok, owner}
    else
      _ -> {:error, :mr_owner_input_invalid}
    end
  end

  defp read_line(_bytes, count) when count > @maximum_bytes, do: {:error, :mr_owner_input_too_large}

  defp read_line(bytes, count) do
    case IO.read(:stdio, 1) do
      "\n" -> {:ok, bytes |> Enum.reverse() |> IO.iodata_to_binary()}
      byte when is_binary(byte) -> read_line([byte | bytes], count + byte_size(byte))
      :eof -> {:error, :mr_owner_input_eof}
      _ -> {:error, :mr_owner_input_unavailable}
    end
  end
end
