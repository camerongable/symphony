defmodule SymphonyElixir.Factory.TicketCiReview do
  @moduledoc "Bounded fresh review-blocker observation; grants no merge or source authority."
  alias SymphonyElixir.Factory.GitLabMcpConnector

  @spec observe(pos_integer(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(project, iid, opts) when is_integer(project) and project > 0 and is_integer(iid) and iid > 0 do
    started = DateTime.utc_now()

    with {:ok, first} <- pages(project, iid, opts, 1, nil, []),
         {:ok, second} <- pages(project, iid, opts, 1, nil, []),
         true <- first == second or {:error, :ci_repair_discussions_changed},
         :ok <- quiet(first),
         true <- DateTime.diff(DateTime.utc_now(), started, :millisecond) <= 30_000 or {:error, :ci_repair_discussions_expired} do
      {:ok, %{"project_id" => project, "mr_iid" => iid, "pages" => first, "observed_at" => DateTime.to_iso8601(started)}}
    end
  end

  def observe(_project, _iid, _opts), do: {:error, :ci_repair_discussions_unproven}

  @spec fresh?(map()) :: boolean()
  def fresh?(%{"observed_at" => time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, parsed, _} -> DateTime.diff(DateTime.utc_now(), parsed, :millisecond) in 0..30_000
      _ -> false
    end
  end

  def fresh?(_proof), do: false

  @doc "Rechecks a previously collected exact-project/MR quiet-discussion receipt without connector IO."
  @spec validate_receipt(pos_integer(), pos_integer(), map()) :: :ok | {:error, atom()}
  def validate_receipt(project, iid, %{"project_id" => observed_project, "mr_iid" => observed_iid, "pages" => pages} = proof)
      when is_integer(project) and project > 0 and is_integer(iid) and iid > 0 and project == observed_project and iid == observed_iid and is_list(pages) and length(pages) in 1..3 do
    with true <- Enum.sort(Map.keys(proof)) == Enum.sort(~w(project_id mr_iid pages observed_at)) and fresh?(proof),
         true <-
           Enum.all?(Enum.with_index(pages, 1), fn {page, index} ->
             is_map(page) and Enum.sort(Map.keys(page)) == Enum.sort(~w(items page total total_pages raw_sha256)) and
               is_list(page["items"]) and compact(page["items"]) == {:ok, page["items"]} and page["page"] == index and is_integer(page["total"]) and page["total"] in 0..300 and
               page["total_pages"] == length(pages) and
               length(pages) == max(1, div(page["total"] + 99, 100)) and page["total"] == hd(pages)["total"] and
               length(page["items"]) == min(100, max(0, page["total"] - (index - 1) * 100)) and is_binary(page["raw_sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, page["raw_sha256"])
           end),
         :ok <- quiet(pages) do
      :ok
    else
      _ -> {:error, :ci_repair_discussions_unproven}
    end
  rescue
    _ -> {:error, :ci_repair_discussions_unproven}
  end

  def validate_receipt(_, _, _), do: {:error, :ci_repair_discussions_unproven}

  defp pages(project, iid, opts, page, expected, accumulated) do
    connector = opts[:connector] || GitLabMcpConnector
    args = %{"project_id" => to_string(project), "merge_request_iid" => to_string(iid), "page" => page, "per_page" => 100}

    with {:ok, %{"items" => items, "pagination" => meta} = raw} <- connector.discussion_page(args, opts),
         true <- is_list(items) and is_map(meta),
         {:ok, total} <- number(meta["x_total"]),
         {:ok, total_pages} <- number(meta["x_total_pages"]),
         {:ok, ^page} <- number(meta["x_page"]),
         {:ok, 100} <- number(meta["x_per_page"]),
         true <- total <= 300 and total_pages == max(1, div(total + 99, 100)) and total_pages <= 3,
         true <- is_nil(expected) or expected == {total, total_pages},
         true <- length(items) == min(100, max(0, total - (page - 1) * 100)),
         {:ok, compact} <- compact(items),
         next = meta["x_next_page"],
         true <- (page == total_pages and Map.has_key?(meta, "x_next_page") and is_nil(next)) or (page < total_pages and number(next) == {:ok, page + 1}) do
      result = accumulated ++ [%{"items" => compact, "page" => page, "total" => total, "total_pages" => total_pages, "raw_sha256" => digest(Jason.encode!(raw))}]
      if page == total_pages, do: {:ok, result}, else: pages(project, iid, opts, page + 1, {total, total_pages}, result)
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_repair_discussions_unproven}
    end
  end

  defp compact(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, result} ->
      with %{"id" => id, "individual_note" => individual, "notes" => notes} <- item,
           true <- is_binary(id) and byte_size(id) in 1..128 and is_boolean(individual) and is_list(notes) and length(notes) in 1..100,
           {:ok, compact_notes} <- notes(notes) do
        {:cont, {:ok, result ++ [%{"id" => id, "individual_note" => individual, "notes" => compact_notes}]}}
      else
        _ -> {:halt, {:error, :ci_repair_discussions_unproven}}
      end
    end)
  end

  defp notes(notes) do
    Enum.reduce_while(notes, {:ok, []}, fn note, {:ok, result} ->
      with %{"id" => id, "system" => system, "resolvable" => resolvable} <- note,
           {:ok, id} <- number(id),
           true <- id > 0 and is_boolean(system) and is_boolean(resolvable),
           true <- not resolvable or is_boolean(note["resolved"]) do
        {:cont, {:ok, result ++ [%{"id" => id, "system" => system, "resolvable" => resolvable, "resolved" => if(resolvable, do: note["resolved"], else: nil)}]}}
      else
        _ -> {:halt, {:error, :ci_repair_discussions_unproven}}
      end
    end)
  end

  defp quiet(pages) do
    items = Enum.flat_map(pages, & &1["items"])
    notes = Enum.flat_map(items, & &1["notes"])

    cond do
      length(Enum.uniq_by(items, & &1["id"])) != length(items) or length(Enum.uniq_by(notes, & &1["id"])) != length(notes) -> {:error, :ci_repair_discussions_unproven}
      Enum.any?(notes, &(&1["resolvable"] and &1["resolved"] == false)) -> {:error, :ci_repair_review_blocked}
      true -> :ok
    end
  end

  defp number(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp number(value) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value), do: {:ok, String.to_integer(value)}, else: {:error, :ci_repair_discussions_unproven}
  end

  defp number(_value), do: {:error, :ci_repair_discussions_unproven}
  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
