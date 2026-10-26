defmodule SymphonyElixir.Factory.TicketHumanEmptyCommitRead do
  @moduledoc "Observes immutable empty-child objects without granting import or delivery authority."
  alias SymphonyElixir.PathSafety
  @helper Path.expand("../../../priv/ticket_empty_commit_read.py", __DIR__)
  @external_resource @helper
  @sha :crypto.hash(:sha256, File.read!(@helper))

  @spec observe(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def observe(root, previous, candidate) do
    with true <- is_binary(root) and Path.type(root) == :absolute,
         true <- valid_sha?(previous) and valid_sha?(candidate) and previous != candidate,
         {:ok, helper} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_empty_commit_read.py")),
         {:ok, bytes} <- File.read(helper),
         true <- :crypto.hash(:sha256, bytes) == @sha,
         {:ok, proof} <- exchange(helper, root, previous, candidate),
         true <- valid_proof?(proof, previous, candidate) do
      {:ok, proof}
    else
      _ -> {:error, :human_empty_child_objects_unproven}
    end
  end

  defp valid_sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp valid_proof?(proof, previous, candidate) do
    case proof do
      %{"kind" => "EMPTY_CHILD_OBJECTS_V1", "previous" => %{"sha" => ^previous, "tree" => tree}, "candidate" => %{"sha" => ^candidate, "tree" => tree, "parents" => [^previous]}} -> valid_sha?(tree)
      _ -> false
    end
  end

  defp exchange(helper, root, previous, candidate) do
    port =
      Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(["-I", "-S", "-B", helper], &String.to_charlist/1),
        env: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
      ])

    try do
      raw = Jason.encode!(%{"root" => root, "previous" => previous, "candidate" => candidate})
      true = Port.command(port, <<byte_size(raw)::unsigned-big-32, raw::binary>>)
      collect(port, "", System.monotonic_time(:millisecond) + 12_000)
    after
      if Port.info(port) != nil, do: Port.close(port)
    end
  rescue
    _ -> {:error, :human_empty_child_objects_unproven}
  end

  defp collect(port, raw, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= 8192 -> collect(port, raw <> bytes, deadline)
      {^port, {:exit_status, 0}} -> Jason.decode(raw)
      {^port, _} -> {:error, :human_empty_child_objects_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :human_empty_child_objects_unproven}
    end
  end
end
