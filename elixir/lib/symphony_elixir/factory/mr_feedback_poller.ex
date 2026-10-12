defmodule SymphonyElixir.Factory.MrFeedbackPoller do
  @moduledoc """
  Performs one bounded, model-free review-feedback discovery pass.

  Only the newest delivered factory run for an issue is eligible. Each run is
  checked against fresh Jira and GitLab state before a note enters the ledger.
  """

  alias SymphonyElixir.Factory.{GitLabMcpConnector, JiraMcpConnector, JiraMcpReader, MrFeedback, MrFeedbackLedger}
  alias SymphonyElixir.Factory.{MrFeedbackMcpReader, Store}

  @doc "Polls eligible MRs and records only new, authorized human mentions."
  @spec poll(map(), keyword()) :: %{recorded: non_neg_integer(), failures: [{String.t(), term()}]}
  def poll(context, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    policy = Map.get(context.factory, :review_feedback, %{})
    allowed_ids = value(policy, "allowed_author_ids", [11_599_766])
    bot_id = value(policy, "bot_author_id", 0)
    jira_reader = Keyword.get(opts, :jira_reader, JiraMcpReader)
    gitlab_reader = Keyword.get(opts, :gitlab_reader, MrFeedbackMcpReader)

    Enum.reduce(review_runs(context.store), %{recorded: 0, failures: []}, fn run, acc ->
      case poll_run(context, workspace, run, allowed_ids, bot_id, jira_reader, gitlab_reader, opts) do
        {:ok, count} -> %{acc | recorded: acc.recorded + count}
        {:error, reason} -> %{acc | failures: [{run["run_id"], reason} | acc.failures]}
      end
    end)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  @doc "Checks whether feedback discovery has any review-ready MR to inspect."
  @spec review_runs?(Store.connection()) :: boolean()
  def review_runs?(store), do: review_runs(store) != []

  defp review_runs(store) do
    store
    |> Store.query!("""
    SELECT r.* FROM runs AS r
    WHERE r.kind = 'DELIVERY' AND r.state IN ('READY_FOR_REVIEW', 'DELIVERED')
      AND r.mr_iid IS NOT NULL AND r.mr_url IS NOT NULL
      AND r.run_id = (
        SELECT latest.run_id FROM runs AS latest
        WHERE latest.kind = 'DELIVERY' AND latest.issue_key = r.issue_key
          AND COALESCE(latest.execution_mode, 'LEGACY') = 'LEGACY'
          AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = latest.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
        ORDER BY latest.created_at DESC, latest.rowid DESC LIMIT 1
      )
      AND COALESCE(r.execution_mode, 'LEGACY') = 'LEGACY'
    ORDER BY r.created_at, r.run_id
    """)
    |> then(fn result -> Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1))) end)
  end

  defp poll_run(context, workspace, run, allowed_ids, bot_id, jira_reader, gitlab_reader, opts) do
    with {:ok, route} <- route(context.factory.repositories, run),
         {:ok, jira} <-
           jira_reader.issue(run["issue_key"],
             workspace: workspace,
             connector: Keyword.get(opts, :jira_connector, JiraMcpConnector),
             app_server: Keyword.get(opts, :jira_app_server, SymphonyElixir.Codex.AppServer),
             mcp_session: Keyword.get(opts, :mcp_session)
           ),
         true <- review_label?(jira) || {:skip, :not_review},
         {:ok, %{mr: mr, discussions: discussions}} <-
           gitlab_reader.fetch(route, run,
             workspace: workspace,
             connector: Keyword.get(opts, :gitlab_connector, GitLabMcpConnector),
             app_server: Keyword.get(opts, :gitlab_app_server, SymphonyElixir.Codex.AppServer),
             mcp_session: Keyword.get(opts, :mcp_session)
           ) do
      binding = %{
        store: context.store,
        run: run,
        route: route,
        jira: jira,
        mr: mr,
        allowed_ids: allowed_ids,
        bot_id: bot_id,
        ledger: Keyword.get(opts, :ledger, MrFeedbackLedger)
      }

      record_notes(binding, discussions)
    else
      {:skip, :not_review} -> {:ok, 0}
      {:error, _reason} = error -> error
    end
  end

  defp record_notes(binding, discussions) do
    discussions
    |> Enum.flat_map(fn discussion -> Enum.map(discussion["notes"], &{discussion, &1}) end)
    |> Enum.reduce_while({:ok, 0}, fn {discussion, note}, {:ok, count} ->
      case record_note(binding, discussion, note) do
        {:ok, :recorded} -> {:cont, {:ok, count + 1}}
        {:ok, :ignored} -> {:cont, {:ok, count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp record_note(binding, discussion, note) do
    with :ok <-
           binding.ledger.supersede_changed(
             binding.store,
             binding.mr["project"],
             binding.mr["iid"],
             discussion["id"],
             note["id"],
             note["body"]
           ) do
      case MrFeedback.candidate(
             binding.run,
             binding.route,
             binding.jira,
             binding.mr,
             discussion,
             note,
             binding.allowed_ids,
             binding.bot_id
           ) do
        {:ok, candidate} ->
          record_candidate(binding, candidate)

        {:error, _reason} ->
          {:ok, :ignored}
      end
    end
  end

  defp record_candidate(binding, candidate) do
    case binding.ledger.record_candidate(binding.store, candidate) do
      {:ok, :recorded} -> {:ok, :recorded}
      {:ok, :already_recorded} -> {:ok, :ignored}
      {:error, _reason} = error -> error
    end
  end

  defp route(repositories, run) do
    case Map.get(repositories, run["repo_key"]) do
      %{} = selected -> {:ok, Map.put(selected, "repo_key", run["repo_key"])}
      _other -> {:error, :review_feedback_route_missing}
    end
  end

  defp review_label?(jira) do
    is_list(jira["labels"]) and Enum.any?(jira["labels"], &(is_binary(&1) and String.downcase(&1) == "ai-review"))
  end

  defp value(map, key, default), do: Map.get(map, key, default)
end
