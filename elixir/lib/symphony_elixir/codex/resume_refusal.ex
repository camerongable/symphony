defmodule SymphonyElixir.Codex.ResumeRefusal do
  @moduledoc "Correlated pre-session resume refusals; raw RPC errors alone grant no factory retry."

  @keys ~w(version method requested_thread_id classification raw_error)

  @spec classify(map(), String.t()) :: tuple()
  def classify(error, requested_thread) do
    refusal = %{"version" => 1, "method" => "thread/resume", "requested_thread_id" => requested_thread, "classification" => "active_writer", "raw_error" => error}
    reason = {:native_resume_refused, refusal}
    if match?({:ok, _}, details(reason)), do: reason, else: {:response_error, error}
  end

  @spec details(term()) :: {:ok, map()} | :unclassified
  def details({:native_resume_refused, %{} = refusal}) do
    with true <- Enum.sort(Map.keys(refusal)) == Enum.sort(@keys),
         %{"version" => 1, "method" => "thread/resume", "requested_thread_id" => thread, "classification" => "active_writer", "raw_error" => error} <- refusal,
         true <- is_binary(thread) and byte_size(thread) in 1..256,
         true <- supported_error?(error),
         {:ok, encoded} <- Jason.encode(refusal),
         true <- byte_size(encoded) <= 2_097_152 do
      {:ok, refusal}
    else
      _ -> :unclassified
    end
  end

  def details(_), do: :unclassified

  @doc "Persists complete typed identity independently of diagnostic inspection limits."
  @spec failure_identity(term()) :: String.t()
  def failure_identity(reason) do
    case details(reason) do
      {:ok, refusal} -> "NATIVE_RESUME_REFUSAL_V1:" <> (:crypto.hash(:sha256, Jason.encode!(refusal)) |> Base.encode16(case: :lower))
      :unclassified -> inspect(reason)
    end
  end

  defp supported_error?(%{"code" => -32_600, "message" => message}) when is_binary(message) do
    normalized = message |> String.trim() |> String.replace(~r/[ \t]+/, " ")

    Regex.match?(~r/\A(?:thread(?: [^\r\n]+)? )?already has an active writer[.!]?\z/i, normalized) or
      Regex.match?(~r/\Acannot resume(?: thread(?: [^\r\n]+)?)?: (?:another )?active writer (?:already )?(?:exists|is attached)[.!]?\z/i, normalized)
  end

  defp supported_error?(_), do: false
end
