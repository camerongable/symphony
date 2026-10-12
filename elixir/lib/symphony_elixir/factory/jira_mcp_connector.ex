defmodule SymphonyElixir.Factory.JiraMcpConnector do
  @moduledoc """
  Provides the controller's Jira MCP tools through a short-lived Codex app-server connection.

  Tool approval or elicitation is never answered automatically. The caller must
  treat an unproven result as blocked and reconcile from Jira before retrying.
  """

  alias SymphonyElixir.Codex.AppServer

  @allowed_tools ~w(jira_search jira_get_issue jira_add_comment jira_update_issue)
  @max_bytes 1_048_576

  @doc "Reads advertised Jira tools on an existing caller-owned connector session."
  @spec catalog(keyword()) :: {:ok, map()} | {:error, term()}
  def catalog(opts) do
    case opts[:mcp_session] do
      %{} = session ->
        app_server = Keyword.get(opts, :app_server, AppServer)

        case app_server.mcp_tool_catalog_in_session(session, "Jira") do
          {:ok, tools} when is_map(tools) -> {:ok, tools}
          {:error, _} = error -> error
          _ -> {:error, :jira_catalog_unproven}
        end

      _ ->
        {:error, :jira_catalog_session_required}
    end
  end

  @doc "Calls one Jira tool and returns only a decoded structured result."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(tool, arguments, opts) when tool in @allowed_tools and is_map(arguments) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, AppServer)

    with {:ok, response} <- call_tool(app_server, Keyword.get(opts, :mcp_session), workspace, tool, arguments) do
      cond do
        response["isError"] == true -> {:error, :jira_tool_error}
        tool in ["jira_search", "jira_get_issue"] -> decode_result(response)
        true -> {:ok, %{}}
      end
    end
  end

  def call("jira_update_factory_labels" = tool, arguments, opts) when is_map(arguments) do
    with :ok <- factory_delta(arguments),
         {:ok, tools} <- catalog(opts),
         :ok <- atomic_schema(tools[tool]),
         {:ok, response} <- call_tool(Keyword.get(opts, :app_server, AppServer), opts[:mcp_session], Keyword.fetch!(opts, :workspace), tool, arguments),
         false <- response["isError"] == true,
         {:ok, ack} <- decode_result(response),
         true <- ack["issue_key"] == arguments["issue_key"] and ack["mutation_requested"] == true do
      {:ok, ack}
    else
      {:error, _} = error -> error
      _ -> {:error, :jira_factory_labels_unproven}
    end
  end

  def call("jira_transition_issue" = tool, arguments, opts) when is_map(arguments) do
    with true <- Enum.sort(Map.keys(arguments)) == ~w(issue_key transition_id) and valid_issue?(arguments["issue_key"]),
         id when is_binary(id) <- arguments["transition_id"],
         true <- Regex.match?(~r/\A[1-9][0-9]*\z/, id),
         {:ok, tools} <- catalog(opts),
         :ok <- transition_write_schema(tools[tool]),
         {:ok, response} <- call_tool(Keyword.get(opts, :app_server, AppServer), opts[:mcp_session], Keyword.fetch!(opts, :workspace), tool, arguments),
         false <- response["isError"] == true do
      {:ok, %{}}
    else
      {:error, _} = error -> error
      _ -> {:error, :jira_transition_unproven}
    end
  end

  def call(_tool, _arguments, _opts), do: {:error, :jira_tool_not_allowed}

  @doc "Checks fixed mutation arguments and advertised capability without issuing any tool call."
  @spec validate_call(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def validate_call("jira_update_factory_labels" = tool, arguments, opts) when is_map(arguments) do
    with :ok <- factory_delta(arguments), {:ok, tools} <- catalog(opts), do: atomic_schema(tools[tool])
  end

  def validate_call("jira_transition_issue" = tool, arguments, opts) when is_map(arguments) do
    with true <- Enum.sort(Map.keys(arguments)) == ~w(issue_key transition_id) and valid_issue?(arguments["issue_key"]),
         id when is_binary(id) <- arguments["transition_id"],
         true <- Regex.match?(~r/\A[1-9][0-9]*\z/, id),
         {:ok, tools} <- catalog(opts) do
      transition_write_schema(tools[tool])
    else
      {:error, _} = error -> error
      _ -> {:error, :jira_transition_unproven}
    end
  end

  def validate_call("jira_add_comment" = tool, arguments, opts) when is_map(arguments) do
    with :ok <- comment_arguments(arguments),
         {:ok, tools} <- catalog(opts) do
      comment_schema(tools[tool])
    end
  end

  def validate_call(_tool, _arguments, _opts), do: {:error, :jira_tool_not_allowed}

  defp comment_arguments(arguments) do
    body = arguments["body"]

    valid =
      Enum.sort(Map.keys(arguments)) == ~w(body issue_key) and valid_issue?(arguments["issue_key"]) and
        is_binary(body) and byte_size(body) in 1..65_536

    if valid, do: :ok, else: {:error, :invalid_jira_factory_comment}
  end

  defp comment_schema(%{"annotations" => annotations, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required}})
       when is_map(annotations) and is_map(properties) and is_list(required) do
    valid =
      append_annotation?(annotations) and Enum.sort(required) == ~w(body issue_key) and
        Enum.all?(~w(body issue_key), &match?(%{"type" => "string"}, properties[&1]))

    if valid, do: :ok, else: {:error, :jira_comment_catalog_unproven}
  end

  defp comment_schema(_tool), do: {:error, :jira_comment_catalog_unproven}
  defp append_annotation?(%{"destructiveHint" => false, "readOnlyHint" => false}), do: true
  defp append_annotation?(%{"readOnlyHint" => _}), do: false
  defp append_annotation?(%{"destructiveHint" => false}), do: true
  defp append_annotation?(_annotations), do: false

  @doc "Reads only a bounded available-transition list; never opens a fallback session."
  @spec call_list(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def call_list("jira_get_transitions" = tool, arguments, opts) when is_map(arguments) do
    with {:ok, tools} <- catalog(opts),
         :ok <- transition_read_schema(tools[tool]),
         true <- Map.keys(arguments) == ["issue_key"] and valid_issue?(arguments["issue_key"]),
         {:ok, response} <- call_tool(Keyword.get(opts, :app_server, AppServer), opts[:mcp_session], Keyword.fetch!(opts, :workspace), tool, arguments),
         false <- response["isError"] == true,
         {:ok, values} when is_list(values) <- decode_list(response),
         true <- length(values) <= 100 and Enum.all?(values, &is_map/1) do
      {:ok, values}
    else
      {:error, _} = error -> error
      _ -> {:error, :jira_transitions_unproven}
    end
  end

  def call_list(_tool, _arguments, _opts), do: {:error, :jira_tool_not_allowed}

  defp atomic_schema(%{"annotations" => %{"readOnlyHint" => false}, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required}})
       when is_map(properties) and is_list(required) do
    fields = ~w(issue_key add_labels remove_labels)

    if Enum.sort(Map.keys(properties)) == Enum.sort(fields) and Enum.sort(required) == Enum.sort(fields) and
         match?(%{"type" => "string"}, properties["issue_key"]) and
         Enum.all?(~w(add_labels remove_labels), &match?(%{"type" => "array", "items" => %{"type" => "string"}}, properties[&1])),
       do: :ok,
       else: {:error, :jira_atomic_labels_capability_unavailable}
  end

  defp atomic_schema(_tool), do: {:error, :jira_atomic_labels_capability_unavailable}

  defp transition_read_schema(%{
         "annotations" => %{"readOnlyHint" => true},
         "inputSchema" => %{"type" => "object", "properties" => %{"issue_key" => %{"type" => "string"}}, "required" => ["issue_key"]}
       }),
       do: :ok

  defp transition_read_schema(_tool), do: {:error, :jira_transition_catalog_unproven}

  defp transition_write_schema(%{"annotations" => annotations, "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required}})
       when is_map(annotations) and is_map(properties) and is_list(required) do
    if transition_write_annotation?(annotations) and Enum.sort(required) == ~w(issue_key transition_id) and
         Enum.all?(~w(issue_key transition_id), &match?(%{"type" => "string"}, properties[&1])),
       do: :ok,
       else: {:error, :jira_transition_catalog_unproven}
  end

  defp transition_write_schema(_tool), do: {:error, :jira_transition_catalog_unproven}

  defp transition_write_annotation?(%{"readOnlyHint" => false}), do: true
  defp transition_write_annotation?(%{"readOnlyHint" => _}), do: false
  defp transition_write_annotation?(%{"destructiveHint" => true}), do: true
  defp transition_write_annotation?(_annotations), do: false

  defp factory_delta(arguments) do
    adds = arguments["add_labels"]
    removes = arguments["remove_labels"]

    valid =
      Enum.sort(Map.keys(arguments)) == ~w(add_labels issue_key remove_labels) and valid_issue?(arguments["issue_key"]) and
        is_list(adds) and length(adds) == 1 and hd(adds) in ~w(ai-running ai-review) and
        valid_removals?(removes) and not Enum.any?(adds, &(&1 in removes))

    if valid, do: :ok, else: {:error, :invalid_jira_factory_label_delta}
  end

  defp valid_removals?(removes) do
    is_list(removes) and length(removes) <= 3 and Enum.uniq(removes) == removes and
      Enum.all?(removes, &(&1 in ~w(ai-ready ai-running ai-verifying)))
  end

  defp valid_issue?(key), do: is_binary(key) and Regex.match?(~r/\A[A-Z][A-Z0-9_]*-[1-9][0-9]*\z/, key)

  defp decode_list(%{"structuredContent" => %{"result" => text}}) when is_binary(text), do: bounded_list(text)
  defp decode_list(%{"structuredContent" => values}) when is_list(values), do: bounded_list(Jason.encode!(values))
  defp decode_list(%{"content" => [%{"type" => "text", "text" => text}]}) when is_binary(text), do: bounded_list(text)
  defp decode_list(_response), do: {:error, :jira_tool_result_invalid}

  defp bounded_list(text) when byte_size(text) <= @max_bytes, do: Jason.decode(text)
  defp bounded_list(_text), do: {:error, :jira_tool_result_too_large}

  defp call_tool(app_server, nil, workspace, tool, arguments),
    do: app_server.call_mcp_tool(workspace, "Jira", tool, arguments)

  defp call_tool(app_server, session, _workspace, tool, arguments),
    do: app_server.call_mcp_tool_in_session(session, "Jira", tool, arguments)

  defp decode_result(%{"structuredContent" => %{"result" => result}}) when is_binary(result),
    do: decode_json_map(result)

  defp decode_result(%{"structuredContent" => %{} = result}), do: {:ok, result}

  defp decode_result(%{"content" => [%{"type" => "text", "text" => text}]}) when is_binary(text) do
    decode_json_map(text)
  end

  defp decode_result(_response), do: {:error, :jira_tool_result_invalid}

  defp decode_json_map(text) do
    case Jason.decode(text) do
      {:ok, %{} = result} -> {:ok, result}
      _other -> {:error, :jira_tool_result_invalid}
    end
  end
end
