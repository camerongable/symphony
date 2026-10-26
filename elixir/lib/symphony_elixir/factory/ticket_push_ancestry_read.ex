defmodule SymphonyElixir.Factory.TicketPushAncestryRead do
  @moduledoc "Bounded fixed controller Git reads with no prompt or ambient executable selection."
  alias SymphonyElixir.PathSafety
  @helper Path.expand("../../../priv/ticket_push_ancestry_read.py", __DIR__)
  @external_resource @helper
  @sha :crypto.hash(:sha256, File.read!(@helper))

  @spec run(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(root, args) do
    with {:ok, helper} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_ancestry_read.py")),
         {:ok, bytes} <- File.read(helper),
         true <- :crypto.hash(:sha256, bytes) == @sha do
      exchange(helper, root, args)
    else
      _ -> {:error, :ticket_push_ancestry_read_program_changed}
    end
  end

  defp exchange(helper, root, args) do
    port =
      Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(["-I", "-S", "-B", helper], &String.to_charlist/1),
        env: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
      ])

    try do
      environment =
        Map.merge(
          %{
            "HOME" => System.user_home!(),
            "PATH" => "/usr/bin:/bin",
            "LC_ALL" => "C",
            "GIT_TERMINAL_PROMPT" => "0",
            "GIT_NO_LAZY_FETCH" => "1",
            "GIT_NO_REPLACE_OBJECTS" => "1"
          },
          System.get_env() |> Map.take(~w(SSH_AUTH_SOCK GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM))
        )

      raw = Jason.encode!(%{"root" => root, "arguments" => args, "environment" => environment})
      true = Port.command(port, <<byte_size(raw)::unsigned-big-32, raw::binary>>)
      collect(port, "", System.monotonic_time(:millisecond) + 15_000)
    after
      if Port.info(port) != nil, do: Port.close(port)
    end
  rescue
    _ -> {:error, :ticket_push_ancestry_read_unproven}
  end

  defp collect(port, raw, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= 32_768 -> collect(port, raw <> bytes, deadline)
      {^port, {:exit_status, 0}} -> decode(raw)
      {^port, _} -> {:error, :ticket_push_ancestry_read_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :ticket_push_ancestry_read_unproven}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"status" => "PASS", "output" => output}} when is_binary(output) -> {:ok, output}
      {:ok, %{"status" => "TIMEOUT"}} -> {:error, :ticket_push_ancestry_read_timeout}
      _ -> {:error, :ticket_push_ancestry_read_failed}
    end
  end
end
