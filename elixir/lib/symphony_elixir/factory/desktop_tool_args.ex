defmodule SymphonyElixir.Factory.DesktopToolArgs do
  @moduledoc "Builds exact Codex Desktop tool arguments from durable requests."

  alias SymphonyElixir.Factory.{DesktopRequest, Store, TicketMrOperation}

  @model_efforts %{
    "gpt-6.1-sol" => ~w(low medium high xhigh max ultra),
    "gpt-6-sol" => ~w(low medium high xhigh max ultra),
    "gpt-6-luna" => ~w(low medium high xhigh max),
    "gpt-5.6-sol" => ~w(low medium high xhigh max ultra),
    "gpt-5.6-terra" => ~w(low medium high xhigh max ultra),
    "gpt-5.6-luna" => ~w(low medium high xhigh max),
    "gpt-5.5" => ~w(low medium high xhigh)
  }

  @spec create_thread(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_thread(store, request_key, opts \\ []) do
    with {:ok, request} <- DesktopRequest.get(store, request_key),
         :ok <- DesktopRequest.authorize_issuance(store, request, opts),
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt} do
      create_thread(request)
    end
  end

  @spec followup(Store.connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def followup(store, request_key, opts \\ []) do
    with {:ok, request} <- DesktopRequest.get(store, request_key),
         :ok <- DesktopRequest.authorize_issuance(store, request, opts),
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt} do
      followup(request)
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

  def create_thread(%{"action" => "CREATE", "target_kind" => "TICKET_CHAT"} = request) do
    with :ok <- validate_fields(request, ~w(model reasoning_effort title prompt)),
         :ok <- validate_projectless_metadata(request) do
      metadata = Jason.decode!(request["metadata_json"])

      {:ok,
       %{
         "target" => %{"type" => "projectless", "directoryName" => metadata["directory_name"]},
         "model" => request["model"],
         "thinking" => request["reasoning_effort"],
         "title" => request["title"],
         "prompt" => request["prompt"]
       }}
    end
  end

  def create_thread(_request), do: {:error, :unsupported_create_thread_route}

  @doc "Formats an observed request only; it is not current ledger authority or permission to send."
  @spec followup(map()) :: {:ok, map()} | {:error, term()}
  def followup(%{"action" => "FOLLOWUP", "target_kind" => "TICKET_CHAT"} = request) do
    with :ok <- validate_fields(Map.put(request, "existing_thread_id", nil), ~w(model reasoning_effort title prompt)),
         true <- present?(request["existing_thread_id"]) or {:error, :missing_existing_thread},
         :ok <- validate_projectless_metadata(request) do
      {:ok, %{"threadId" => request["existing_thread_id"], "model" => request["model"], "thinking" => request["reasoning_effort"], "prompt" => request["prompt"]}}
    end
  end

  def followup(%{"action" => "FOLLOWUP", "target_kind" => "CONTROLLER"} = request) do
    with {:ok, metadata} <- decode_metadata(request["metadata_json"]),
         binding when is_map(binding) <- metadata["delivery_operation"],
         :ok <- TicketMrOperation.validate_request(binding, request),
         true <- unissued_mr?(request) or {:error, :ticket_mr_request_already_issued},
         :ok <- validate_fields(Map.put(request, "existing_thread_id", nil)) do
      {:ok, %{"threadId" => request["existing_thread_id"], "model" => request["model"], "thinking" => request["reasoning_effort"], "prompt" => request["prompt"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :unsupported_followup_route}
    end
  end

  def followup(_request), do: {:error, :unsupported_followup_route}

  defp unissued_mr?(request) do
    fields = ~w(claimed_at thread_id turn_id target_observation_json verified_project_id verified_cwd verified_head_sha output_json)
    request["status"] == "PENDING" and Enum.all?(fields, &is_nil(request[&1]))
  end

  defp validate_fields(request, fields \\ ~w(codex_project_id model reasoning_effort title prompt)) do
    missing = Enum.reject(fields, &present?(request[&1]))

    cond do
      missing != [] -> {:error, {:missing_create_thread_fields, missing}}
      present?(request["existing_thread_id"]) -> {:error, :unexpected_existing_thread}
      not Map.has_key?(@model_efforts, request["model"]) -> {:error, :unsupported_create_thread_model}
      request["reasoning_effort"] not in @model_efforts[request["model"]] -> {:error, :unsupported_create_thread_effort}
      true -> :ok
    end
  end

  defp validate_projectless_metadata(request) do
    with {:ok, metadata} <- decode_metadata(request["metadata_json"]),
         :ok <- projectless_fields(request),
         :ok <- ticket_metadata(metadata),
         true <- valid_directory?(request["cwd"], metadata["directory_name"]) or {:error, :ticket_chat_directory_mismatch} do
      :ok
    end
  end

  defp projectless_fields(request) do
    cond do
      not Map.has_key?(request, "codex_project_id") or not is_nil(request["codex_project_id"]) -> {:error, :ticket_chat_requires_projectless_route}
      not is_nil(request["branch"]) or not is_nil(request["base_branch"]) -> {:error, :ticket_chat_source_route_forbidden}
      true -> :ok
    end
  end

  defp ticket_metadata(metadata) do
    cond do
      Enum.sort(Map.keys(Map.delete(metadata, "broker_thread_id"))) != ~w(chat_key directory_name generation route) -> {:error, :invalid_ticket_chat_metadata}
      not valid_metadata_broker?(metadata) -> {:error, :parent_broker_identity_invalid}
      metadata["route"] != "desktop_owned_ticket_chat_v1" -> {:error, :unsupported_ticket_chat_route}
      not (is_integer(metadata["generation"]) and metadata["generation"] > 0) -> {:error, :invalid_ticket_chat_generation}
      not valid_chat_key?(metadata["chat_key"]) -> {:error, :invalid_ticket_chat_key}
      metadata["directory_name"] != "factory-ticket-" <> String.slice(metadata["chat_key"], 3, 20) -> {:error, :ticket_chat_directory_mismatch}
      true -> :ok
    end
  end

  defp valid_metadata_broker?(%{"broker_thread_id" => broker}) do
    is_binary(broker) and Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, broker)
  end

  defp valid_metadata_broker?(_metadata), do: true

  defp valid_chat_key?(key) when is_binary(key), do: Regex.match?(~r/\ATC-[0-9a-f]{64}\z/, key)
  defp valid_chat_key?(_key), do: false

  defp valid_directory?(cwd, directory) when is_binary(cwd), do: Path.type(cwd) == :absolute and Path.basename(cwd) == directory
  defp valid_directory?(_cwd, _directory), do: false

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
