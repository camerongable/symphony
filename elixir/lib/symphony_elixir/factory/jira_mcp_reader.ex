defmodule SymphonyElixir.Factory.JiraMcpReader do
  @moduledoc """
  Reads complete Jira snapshots directly from the controller's MCP connector.

  Agent-authored JSON is never used as a source of Jira description or comment
  bytes. An incomplete page, issue, or comment set fails the tick closed.
  """

  alias SymphonyElixir.Factory.JiraMcpConnector

  @page_size 50
  @maximum_pages 20
  @comment_limit 100
  @fields "summary,description,status,labels,assignee,project,parent,components,updated,comment"

  @doc "Returns the complete, source-backed result of one JQL search."
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(jql, opts) when is_binary(jql) do
    connector = Keyword.get(opts, :connector, JiraMcpConnector)
    read_pages(connector, opts, jql, 0, nil, MapSet.new(), [], 0)
  end

  @doc "Reads one issue and normalizes only the fields the factory consumes."
  @spec issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(issue_key, opts) when is_binary(issue_key) do
    connector = Keyword.get(opts, :connector, JiraMcpConnector)

    with {:ok, raw} <-
           connector.call(
             "jira_get_issue",
             %{
               "issue_key" => issue_key,
               "fields" => @fields,
               "include" => "comments",
               "comment_limit" => @comment_limit,
               "update_history" => false
             },
             connector_opts(opts)
           ),
         {:ok, snapshot} <- normalize_issue(raw),
         true <- snapshot["key"] == issue_key do
      {:ok, snapshot}
    else
      false -> {:error, :jira_issue_key_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp read_pages(_connector, _opts, _jql, _start_at, _token, _seen, _snapshots, @maximum_pages),
    do: {:error, :jira_search_page_limit_exceeded}

  defp read_pages(connector, opts, jql, start_at, token, seen, snapshots, page_count) do
    args = %{"jql" => jql, "limit" => @page_size, "fields" => @fields}
    args = if token, do: Map.put(args, "page_token", token), else: Map.put(args, "start_at", start_at)

    with {:ok, page} <- connector.call("jira_search", args, connector_opts(opts)),
         {:ok, hits} <- page_issues(page),
         {:ok, keys, seen} <- distinct_keys(hits, seen),
         {:ok, fetched} <- fetch_issues(keys, opts),
         :ok <- unchanged_since_search(hits, fetched) do
      snapshots = snapshots ++ fetched
      next_token = page["nextPageToken"] || page["next_page_token"]

      cond do
        is_binary(next_token) and next_token != "" ->
          read_pages(connector, opts, jql, start_at, next_token, seen, snapshots, page_count + 1)

        length(hits) == @page_size ->
          read_pages(connector, opts, jql, start_at + @page_size, nil, seen, snapshots, page_count + 1)

        true ->
          {:ok, snapshots}
      end
    end
  end

  defp page_issues(%{"issues" => issues}) when is_list(issues) and length(issues) <= @page_size,
    do: {:ok, issues}

  defp page_issues(_page), do: {:error, :jira_search_page_invalid}

  defp distinct_keys(hits, seen) do
    keys = Enum.map(hits, & &1["key"])

    if Enum.all?(keys, &(is_binary(&1) and &1 != "" and not MapSet.member?(seen, &1))) and
         length(Enum.uniq(keys)) == length(keys) do
      {:ok, keys, Enum.reduce(keys, seen, &MapSet.put(&2, &1))}
    else
      {:error, :jira_search_duplicate_or_invalid_issue}
    end
  end

  defp fetch_issues(keys, opts) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, snapshots} ->
      case issue(key, opts) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | snapshots]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp unchanged_since_search(hits, snapshots) do
    if Enum.zip(hits, snapshots)
       |> Enum.all?(fn {hit, snapshot} ->
         hit["key"] == snapshot["key"] and
           (not is_binary(hit["updated"]) or hit["updated"] == snapshot["updated"])
       end) do
      :ok
    else
      {:error, :jira_issue_changed_during_search}
    end
  end

  defp normalize_issue(%{} = raw) do
    with true <- is_binary(raw["key"]) and raw["key"] != "",
         true <- is_binary(raw["summary"]) and is_binary(raw["description"]),
         {:ok, status} <- status_name(raw["status"]),
         {:ok, labels} <- string_list(raw["labels"]),
         {:ok, comments} <- normalize_comments(raw["comments"]),
         {:ok, project_key} <- project_key(raw) do
      {:ok,
       %{
         "id" => to_string(raw["id"] || raw["key"]),
         "key" => raw["key"],
         "summary" => raw["summary"],
         "description" => raw["description"],
         "status" => status,
         "labels" => labels,
         "assignee" => raw["assignee"],
         "project_key" => project_key,
         "parent_key" => get_in(raw, ["parent", "key"]) || raw["parent_key"],
         "components" => raw["components"] || [],
         "url" => raw["browse_url"] || raw["url"],
         "updated" => raw["updated"],
         "comments" => comments
       }}
    else
      false -> {:error, :jira_issue_snapshot_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_issue(_raw), do: {:error, :jira_issue_snapshot_invalid}

  defp project_key(raw) do
    case get_in(raw, ["project", "key"]) || raw["project_key"] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _other -> {:error, :jira_issue_project_invalid}
    end
  end

  defp status_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp status_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp status_name(_status), do: {:error, :jira_issue_status_invalid}

  defp string_list(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, values},
      else: {:error, :jira_issue_labels_invalid}
  end

  defp string_list(_values), do: {:error, :jira_issue_labels_invalid}

  defp normalize_comments(values) when is_list(values) and length(values) < @comment_limit do
    comments =
      Enum.map(values, fn comment ->
        body = comment["text"] || comment["body"]

        if is_binary(comment["id"]) and is_binary(body),
          do: Map.put(comment, "text", body),
          else: :invalid
      end)

    if :invalid in comments, do: {:error, :jira_issue_comments_invalid}, else: {:ok, comments}
  end

  defp normalize_comments(values) when is_list(values), do: {:error, :jira_issue_comments_truncated}
  defp normalize_comments(_values), do: {:error, :jira_issue_comments_invalid}

  defp connector_opts(opts), do: Keyword.take(opts, [:workspace, :app_server])
end
