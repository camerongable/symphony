defmodule SymphonyElixir.Factory.JiraMcpWriter do
  @moduledoc """
  Applies one issue-scoped Jira change through the controller connector and proves it by read-back.

  A repeated call observes an already-written exact comment or label set instead of
  issuing the same mutation again. Unexpected label changes fail closed.
  """

  alias SymphonyElixir.Factory.{Contract, JiraMcpConnector}

  @readback_retry_delays_ms [250, 750, 2_000]

  @doc "Writes only the approved comment and/or label set for one run."
  @spec write(map(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(run, scope, expected_readback, opts \\ []) do
    connector = Keyword.get(opts, :connector, JiraMcpConnector)
    workspace = Keyword.fetch!(opts, :workspace)
    connector_opts = [workspace: workspace] ++ Keyword.take(opts, [:app_server])
    issue_key = run["issue_key"]

    with {:ok, snapshot} <- decode_snapshot(run["snapshot_json"]),
         true <- snapshot["key"] == issue_key,
         {:ok, expected_labels} <- labels(snapshot),
         {:ok, expected_status} <- status(snapshot),
         {:ok, before} <- read_issue(connector, connector_opts, issue_key),
         :ok <- require_status_preimage(before.status, expected_status),
         :ok <- require_label_preimage(before.labels, expected_labels, scope.labels),
         {:ok, after_comment} <- write_comment(connector, connector_opts, issue_key, before, scope, opts),
         :ok <- require_status_preimage(after_comment.status, expected_status),
         {:ok, after_labels} <-
           write_labels(connector, connector_opts, issue_key, after_comment, expected_labels, scope, opts),
         :ok <- require_status_preimage(after_labels.status, expected_status),
         :ok <- verify_readback(after_labels, scope, expected_readback) do
      comment = Enum.find(after_labels.comments, &comment_equivalent?(&1.text, scope.comment, issue_key))

      {:ok,
       %{
         "status" => "PASS",
         "issue_key" => issue_key,
         "operation" => "jira_write",
         "comment_id" => if(comment, do: comment.id),
         "labels" => after_labels.labels,
         "readback_text" => Jason.encode!(after_labels.raw)
       }}
    else
      false -> {:error, :jira_write_issue_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp decode_snapshot(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = snapshot} -> {:ok, snapshot}
      _other -> {:error, :jira_write_snapshot_invalid}
    end
  end

  defp decode_snapshot(%{} = value), do: {:ok, value}
  defp decode_snapshot(_value), do: {:error, :jira_write_snapshot_invalid}

  defp labels(%{"labels" => values}) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and Enum.uniq(values) == values,
      do: {:ok, Enum.sort(values)},
      else: {:error, :jira_write_labels_invalid}
  end

  defp labels(_snapshot), do: {:error, :jira_write_labels_invalid}

  defp status(%{"status" => %{"name" => name}}), do: status(%{"status" => name})

  defp status(%{"status" => value}) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :jira_write_status_invalid}
      normalized -> {:ok, String.upcase(normalized)}
    end
  end

  defp status(_snapshot), do: {:error, :jira_write_status_invalid}

  defp read_issue(connector, connector_opts, issue_key) do
    with {:ok, raw} <-
           connector.call(
             "jira_get_issue",
             %{"issue_key" => issue_key, "include" => "comments", "comment_limit" => 100},
             connector_opts
           ),
         {:ok, issue} <- normalize_issue(raw),
         true <- issue.key == issue_key do
      {:ok, issue}
    else
      false -> {:error, :jira_write_issue_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_issue(%{} = raw) do
    key = raw["key"] || raw["issue_key"]
    fields = raw["fields"] || %{}
    label_values = raw["labels"] || fields["labels"]
    status_value = raw["status"] || fields["status"]
    comment_values = raw["comments"] || get_in(fields, ["comment", "comments"])

    with true <- is_binary(key) and key != "",
         {:ok, labels} <- labels(%{"labels" => label_values}),
         {:ok, status} <- status(%{"status" => status_value}),
         {:ok, comments} <- normalize_comments(comment_values) do
      {:ok, %{key: key, labels: labels, status: status, comments: comments, raw: raw}}
    else
      false -> {:error, :jira_write_readback_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_issue(_raw), do: {:error, :jira_write_readback_invalid}

  defp normalize_comments(values) when is_list(values) do
    comments =
      Enum.map(values, fn
        %{"id" => id, "text" => text} when is_binary(text) -> %{id: to_string(id), text: text}
        %{"id" => id, "body" => body} when is_binary(body) -> %{id: to_string(id), text: body}
        _other -> :invalid
      end)

    cond do
      length(comments) >= 1000 -> {:error, :jira_write_comments_truncated}
      :invalid in comments -> {:error, :jira_write_comments_invalid}
      true -> {:ok, comments}
    end
  end

  defp normalize_comments(_values), do: {:error, :jira_write_comments_invalid}

  defp require_label_preimage(actual, expected, target) when actual == expected or actual == target, do: :ok
  defp require_label_preimage(_actual, _expected, _target), do: {:error, :jira_write_stale_labels}

  defp require_status_preimage(actual, expected) when actual == expected, do: :ok
  defp require_status_preimage(_actual, _expected), do: {:error, :jira_write_stale_status}

  defp write_comment(connector, connector_opts, issue_key, before, %{mutations: mutations, comment: body}, opts) do
    if :comment not in mutations or Enum.any?(before.comments, &comment_equivalent?(&1.text, body, issue_key)) do
      {:ok, before}
    else
      with {:ok, _result} <- connector.call("jira_add_comment", %{"issue_key" => issue_key, "body" => body}, connector_opts),
           {:ok, after_write} <-
             read_issue_until(
               connector,
               connector_opts,
               issue_key,
               &comment_present?(&1, body),
               :jira_comment_readback_mismatch,
               opts
             ) do
        {:ok, after_write}
      else
        false -> {:error, :jira_comment_readback_mismatch}
        {:error, _reason} = error -> error
      end
    end
  end

  defp write_labels(connector, connector_opts, issue_key, before, expected_labels, %{mutations: mutations, labels: labels}, opts) do
    if :labels not in mutations or before.labels == labels do
      {:ok, before}
    else
      with :ok <- require_label_preimage(before.labels, expected_labels, labels),
           {:ok, _result} <-
             connector.call(
               "jira_update_issue",
               %{"issue_key" => issue_key, "fields" => Jason.encode!(%{"labels" => labels})},
               connector_opts
             ),
           {:ok, after_write} <-
             read_issue_until(
               connector,
               connector_opts,
               issue_key,
               &(&1.labels == labels),
               :jira_labels_readback_mismatch,
               opts
             ) do
        {:ok, after_write}
      else
        false -> {:error, :jira_labels_readback_mismatch}
        {:error, _reason} = error -> error
      end
    end
  end

  defp read_issue_until(connector, connector_opts, issue_key, predicate, mismatch_reason, opts) do
    delays = Keyword.get(opts, :readback_retry_delays_ms, @readback_retry_delays_ms)
    sleeper = Keyword.get(opts, :readback_sleeper, &Process.sleep/1)
    read_issue_until(connector, connector_opts, issue_key, predicate, mismatch_reason, delays, sleeper)
  end

  defp read_issue_until(connector, connector_opts, issue_key, predicate, mismatch_reason, delays, sleeper) do
    case read_issue(connector, connector_opts, issue_key) do
      {:ok, issue} when is_function(predicate, 1) ->
        if predicate.(issue) do
          {:ok, issue}
        else
          retry_issue_readback(connector, connector_opts, issue_key, predicate, mismatch_reason, delays, sleeper)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp retry_issue_readback(_connector, _connector_opts, _issue_key, _predicate, mismatch_reason, [], _sleeper),
    do: {:error, mismatch_reason}

  defp retry_issue_readback(connector, connector_opts, issue_key, predicate, mismatch_reason, [delay | rest], sleeper) do
    sleeper.(delay)
    read_issue_until(connector, connector_opts, issue_key, predicate, mismatch_reason, rest, sleeper)
  end

  defp verify_readback(issue, scope, expected_readback) do
    comment_proven? =
      :comment not in scope.mutations or
        Enum.any?(issue.comments, &comment_equivalent?(&1.text, scope.comment, issue.key))

    labels_proven? = :labels not in scope.mutations or issue.labels == scope.labels

    if comment_proven? and labels_proven? and
         is_binary(expected_readback) and String.contains?(Jason.encode!(issue.raw), expected_readback),
       do: :ok,
       else: {:error, :jira_write_readback_mismatch}
  end

  defp comment_equivalent?(actual, expected, issue_key) when is_binary(actual) and is_binary(expected) do
    Contract.draft_comment_equivalent?(expected, actual, issue_key) or
      Contract.input_request_comment_equivalent?(expected, actual, issue_key)
  end

  defp comment_equivalent?(_actual, _expected, _issue_key), do: false

  defp comment_present?(issue, body) do
    Enum.any?(issue.comments, &comment_equivalent?(&1.text, body, issue.key))
  end
end
