defmodule SymphonyElixir.Factory.MrFeedbackMcpReader do
  @moduledoc """
  Reads one exact factory MR and all its discussions through GitLab MCP.

  GitLab's paginated MCP response is authoritative only when every page is
  present and its project, MR, and source HEAD match the ledger binding.
  """

  alias SymphonyElixir.Factory.GitLabMcpConnector

  @page_size 100
  @maximum_pages 20

  @doc "Returns a source-backed MR and complete discussion list for one run."
  @spec fetch(map(), map(), keyword()) :: {:ok, %{mr: map(), discussions: [map()]}} | {:error, term()}
  def fetch(route, run, opts) when is_map(route) and is_map(run) do
    connector = Keyword.get(opts, :connector, GitLabMcpConnector)
    project_id = route["gitlab_project_id"] || encode_project(route["gitlab_project"])
    iid = run["mr_iid"]

    with true <-
           (is_binary(project_id) and project_id != "" and is_integer(iid) and iid > 0) or
             {:error, :gitlab_feedback_route_invalid},
         mr_args <- %{"project_id" => project_id, "merge_request_iid" => Integer.to_string(iid)},
         {:ok, raw_mr} <-
           connector.call("get_merge_request", mr_args, connector_opts(opts)),
         {:ok, mr} <- normalize_mr(raw_mr, route, run),
         {:ok, discussions} <- read_pages(connector, connector_opts(opts), project_id, iid, 1, MapSet.new(), []),
         {:ok, final_raw_mr} <- connector.call("get_merge_request", mr_args, connector_opts(opts)),
         {:ok, final_mr} <- normalize_mr(final_raw_mr, route, run),
         true <- final_mr == mr or {:error, :gitlab_feedback_mr_changed_during_poll} do
      {:ok, %{mr: mr, discussions: discussions}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp read_pages(_connector, _opts, _project_id, _iid, page, _seen, _acc) when page > @maximum_pages,
    do: {:error, :gitlab_discussion_page_limit_exceeded}

  defp read_pages(connector, opts, project_id, iid, page, seen, acc) do
    args = %{
      "project_id" => project_id,
      "merge_request_iid" => Integer.to_string(iid),
      "page" => page,
      "per_page" => @page_size
    }

    with {:ok, raw} <- connector.call("mr_discussions", args, opts),
         {:ok, discussions, next_page} <- normalize_page(raw, page),
         :ok <- distinct_discussions(discussions, seen) do
      next_seen = Enum.reduce(discussions, seen, &MapSet.put(&2, &1["id"]))
      acc = acc ++ discussions

      if next_page do
        read_pages(connector, opts, project_id, iid, next_page, next_seen, acc)
      else
        {:ok, acc}
      end
    end
  end

  defp normalize_mr(raw, route, run) do
    with {:ok, iid} <- positive_id(raw["iid"]),
         {:ok, project_id} <- positive_id(raw["project_id"]),
         true <-
           (iid == run["mr_iid"] and
              (is_nil(route["gitlab_project_id"]) or Integer.to_string(project_id) == route["gitlab_project_id"]) and
              raw["web_url"] == run["mr_url"] and raw["source_branch"] == run["branch"] and
              raw["sha"] == run["candidate_sha"] and raw["state"] == "opened") or
             {:error, :gitlab_feedback_mr_mismatch} do
      {:ok,
       %{
         "project" => route["gitlab_project"],
         "iid" => iid,
         "web_url" => raw["web_url"],
         "source_branch" => raw["source_branch"],
         "sha" => raw["sha"],
         "state" => raw["state"]
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp normalize_page(%{"items" => items, "pagination" => pagination}, page)
       when is_list(items) and length(items) <= @page_size and is_map(pagination) do
    with {:ok, current_page} <- positive_id(pagination["x_page"]),
         true <- current_page == page or {:error, :gitlab_discussion_page_mismatch},
         {:ok, next_page} <- next_page(pagination["x_next_page"], page),
         {:ok, total_pages} <- positive_id(pagination["x_total_pages"]),
         true <-
           (total_pages >= page and is_nil(next_page) == (page == total_pages)) or
             {:error, :gitlab_discussion_page_mismatch},
         {:ok, discussions} <- normalize_discussions(items) do
      {:ok, discussions, next_page}
    else
      {:error, _reason} = error -> error
    end
  end

  defp normalize_page(_raw, _page), do: {:error, :gitlab_discussion_page_invalid}

  defp normalize_discussions(items) do
    Enum.reduce_while(items, {:ok, []}, fn discussion, {:ok, acc} ->
      case normalize_discussion(discussion) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, discussions} -> {:ok, Enum.reverse(discussions)}
      error -> error
    end
  end

  defp normalize_discussion(%{"id" => id, "notes" => notes}) when is_binary(id) and id != "" and is_list(notes) do
    with {:ok, normalized_notes} <- normalize_notes(notes) do
      {:ok, %{"id" => id, "notes" => normalized_notes}}
    end
  end

  defp normalize_discussion(_discussion), do: {:error, :gitlab_discussion_invalid}

  defp normalize_notes(notes) do
    Enum.reduce_while(notes, {:ok, []}, fn note, {:ok, acc} ->
      with true <- is_map(note) or {:error, :gitlab_discussion_note_invalid},
           {:ok, id} <- positive_id(note["id"]),
           true <- is_map(note["author"]) or {:error, :gitlab_discussion_note_invalid},
           {:ok, author_id} <- positive_id(note["author"]["id"]),
           true <-
             (is_binary(note["body"]) and is_binary(note["updated_at"])) or
               {:error, :gitlab_discussion_note_invalid} do
        normalized =
          note
          |> Map.put("id", id)
          |> Map.put("author", %{"id" => author_id})

        {:cont, {:ok, [normalized | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp distinct_discussions(discussions, seen) do
    ids = Enum.map(discussions, & &1["id"])

    if length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &(not MapSet.member?(seen, &1))),
      do: :ok,
      else: {:error, :gitlab_discussion_duplicate}
  end

  defp next_page(nil, _page), do: {:ok, nil}
  defp next_page("", _page), do: {:ok, nil}

  defp next_page(value, page) do
    with {:ok, number} <- positive_id(value),
         true <- number == page + 1 or {:error, :gitlab_discussion_page_mismatch} do
      {:ok, number}
    else
      {:error, _reason} = error -> error
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> {:error, :gitlab_identifier_invalid}
    end
  end

  defp positive_id(_value), do: {:error, :gitlab_identifier_invalid}

  defp encode_project(path) when is_binary(path), do: URI.encode(path, &URI.char_unreserved?/1)
  defp encode_project(_path), do: nil

  defp connector_opts(opts), do: Keyword.take(opts, [:workspace, :app_server, :mcp_session])
end
