defmodule SymphonyElixir.Factory.DesktopToolArgs do
  @moduledoc "Builds exact Codex Desktop tool arguments from durable requests."

  alias SymphonyElixir.Factory.{DesktopRequest, Store}

  @model_efforts %{
    "gpt-6.1-sol" => ~w(low medium high xhigh max ultra),
    "gpt-6-sol" => ~w(low medium high xhigh max ultra),
    "gpt-6-luna" => ~w(low medium high xhigh max),
    "gpt-5.6-sol" => ~w(low medium high xhigh max ultra),
    "gpt-5.6-terra" => ~w(low medium high xhigh max ultra),
    "gpt-5.6-luna" => ~w(low medium high xhigh max),
    "gpt-5.5" => ~w(low medium high xhigh)
  }

  @spec create_thread(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_thread(store, request_key) do
    with {:ok, request} <- DesktopRequest.get(store, request_key),
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt} do
      create_thread(request)
    end
  end

  @spec create_thread(map()) :: {:ok, map()} | {:error, term()}
  def create_thread(%{"action" => "CREATE", "target_kind" => "TASK"} = request) do
    with :ok <- validate_fields(request),
         {:ok, metadata} <- decode_metadata(request["metadata_json"]),
         {:ok, environment} <- environment(metadata) do
      {:ok,
       %{
         "target" => %{
           "type" => "project",
           "projectId" => request["codex_project_id"],
           "environment" => environment
         },
         "model" => request["model"],
         "thinking" => request["reasoning_effort"],
         "title" => request["title"],
         "prompt" => request["prompt"]
       }}
    end
  end

  def create_thread(_request), do: {:error, :unsupported_create_thread_route}

  defp validate_fields(request) do
    missing = Enum.reject(~w(codex_project_id model reasoning_effort title prompt), &present?(request[&1]))

    cond do
      missing != [] -> {:error, {:missing_create_thread_fields, missing}}
      present?(request["existing_thread_id"]) -> {:error, :unexpected_existing_thread}
      not Map.has_key?(@model_efforts, request["model"]) -> {:error, :unsupported_create_thread_model}
      request["reasoning_effort"] not in @model_efforts[request["model"]] -> {:error, :unsupported_create_thread_effort}
      true -> :ok
    end
  end

  defp decode_metadata(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _other -> {:error, :invalid_create_thread_metadata}
    end
  end

  defp decode_metadata(_json), do: {:error, :invalid_create_thread_metadata}

  defp environment(%{"workspace_mode" => "CODEX_PROJECT_LOCAL"}), do: {:ok, %{"type" => "local"}}

  defp environment(%{"workspace_mode" => "CODEX_NATIVE", "expected_sha" => sha}) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, sha) do
      {:ok, %{"type" => "worktree", "startingState" => %{"type" => "branch", "branchName" => sha}}}
    else
      {:error, :native_base_sha_required}
    end
  end

  defp environment(%{"workspace_mode" => "CODEX_NATIVE"}), do: {:error, :native_base_sha_required}
  defp environment(_metadata), do: {:error, :unsupported_create_thread_workspace_mode}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
