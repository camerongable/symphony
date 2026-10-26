defmodule SymphonyElixir.Factory.TicketPushHazard do
  @moduledoc "Retains unknown push history and admits only independently observed descendant candidates."
  alias SymphonyElixir.Factory.{TicketPushAncestryRead, RunLedger, Store, Worktree}

  @spec active?(Store.connection(), String.t()) :: boolean()
  def active?(store, run_id), do: hazard(store, run_id) != nil

  @spec with_descendant(Store.connection(), String.t(), String.t(), (Store.connection() -> term())) :: term()
  def with_descendant(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def with_descendant(store, run_id, candidate, commit) do
    case hazard(store, run_id) do
      nil -> Store.transaction!(store, commit)
      saved -> observe_descendant(store, run_id, candidate, saved, commit)
    end
  end

  defp observe_descendant(store, run_id, candidate, saved, commit) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, proof} <- Jason.decode(saved["payload_json"]),
         true <- is_binary(candidate) and Regex.match?(~r/\A[0-9a-f]{40}\z/, candidate),
         {:ok, checkout} <- Worktree.checkout_identity(%{"path" => run["repo_path"]}, run["worktree"], clean: true, detached: false, expected_branch: run["branch"], expected_sha: candidate),
         {:ok, ""} <- TicketPushAncestryRead.run(run["worktree"], ["merge-base", "--is-ancestor", run["candidate_sha"], candidate]),
         {:ok, ""} <- TicketPushAncestryRead.run(run["worktree"], ["merge-base", "--is-ancestor", proof["candidate_sha"], candidate]) do
      Store.transaction!(store, fn tx ->
        with {:ok, current} <- RunLedger.get(tx, run_id),
             true <- current == run and hazard(tx, run_id) == saved,
             {:ok, stat} <- File.lstat(checkout.path),
             true <- {stat.major_device, stat.inode} == {checkout.root_device, checkout.root_inode} do
          payload =
            Map.take(run, ~w(branch worktree contract_sha256 spec_revision))
            |> Map.merge(%{"hazard_sha256" => proof["sha256"], "from_sha" => run["candidate_sha"], "to_sha" => candidate, "handoff" => run["candidate_handoff"]})

          Store.query!(tx, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_PUSH_DESCENDANT_PROVEN', ?, ?)", [
            DateTime.to_iso8601(DateTime.utc_now()),
            run_id,
            Jason.encode!(payload)
          ])

          case commit.(tx) do
            {:error, reason} -> Exqlite.rollback(tx, reason)
            result -> result
          end
        else
          _ -> Exqlite.rollback(tx, :push_unknown_hazard_preimage_changed)
        end
      end)
    else
      _ -> {:error, :push_unknown_candidate_descendant_unproven}
    end
  end

  defp hazard(store, run_id), do: Store.one!(store, "SELECT * FROM events WHERE run_id = ? AND event_type = 'TICKET_PUSH_UNKNOWN_HAZARD' ORDER BY id LIMIT 1", [run_id])
end
