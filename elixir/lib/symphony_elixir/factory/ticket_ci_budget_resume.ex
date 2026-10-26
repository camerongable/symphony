defmodule SymphonyElixir.Factory.TicketCiBudgetResume do
  @moduledoc "Authenticates only budget-exhaustion presentation changes across an immutable CI diagnosis."
  alias SymphonyElixir.Factory.{CiRepairReassessment, Store, TicketCiRepairSuccessor}
  @bookkeeping ~w(updated_at ci_last_checked_at)
  @failure ~w(failure_code last_error)
  @kind "CI_REPAIR_BUDGET_RESUMPTION_V1"

  @spec prepare(Store.connection(), map(), map(), pos_integer() | nil) :: {:ok, map() | nil} | {:error, atom()}
  def prepare(store, diagnosis, run, configured) do
    with {:ok, original} <- diagnosed_run(diagnosis) do
      if comparable(original) == comparable(run) do
        {:ok, nil}
      else
        build(
          store,
          diagnosis,
          original,
          run,
          configured || 5,
          TicketCiRepairSuccessor.attempts_used(store, run["run_id"]),
          nil
        )
      end
    end
  rescue
    _ -> refused()
  end

  @spec validate_claim(Store.connection(), map()) :: :ok | {:error, atom()}
  def validate_claim(store, claim) do
    with %{} = row <- Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?", [claim["claim_key"]]),
         true <- sha(row["claim_json"]) == row["claim_sha256"],
         {:ok, ^claim} <- Jason.decode(row["claim_json"]),
         %{} = diagnosis <- claimed_diagnosis(store, claim),
         {:ok, original} <- diagnosed_run(diagnosis) do
      case claim["budget_resume"] do
        nil ->
          exact_claim_preimage(original, claim)

        %{"admitted_at" => at} = proof ->
          validate_resumption(store, row, claim, diagnosis, original, proof, at)

        _ ->
          refused()
      end
    else
      _ -> refused()
    end
  rescue
    _ -> refused()
  end

  defp exact_claim_preimage(original, claim) do
    if comparable(original) == comparable(claim["prior_run"]), do: :ok, else: refused()
  end

  defp validate_resumption(store, row, claim, diagnosis, original, proof, at) do
    configured = proof["configured_limit"]
    expected = Map.delete(proof, "admitted_at")

    with true <- at == row["created_at"] and claim["round"] == row["round"],
         {:ok, ^expected} <-
           build(store, diagnosis, original, claim["prior_run"], configured, prefix_count(store, row), at) do
      :ok
    else
      _ -> refused()
    end
  end

  defp build(store, diagnosis, original, run, configured, used, cutoff) do
    effective = if is_integer(configured), do: min(configured, 10), else: 0

    with true <- is_integer(configured) and configured >= 1,
         true <- Map.drop(comparable(original), @failure) == Map.drop(comparable(run), @failure),
         true <- run["state"] == "CI_WAITING" and run["failure_code"] == "CI_REPAIR_EXHAUSTED",
         true <- run["run_id"] == diagnosis["run_id"] and run["candidate_sha"] == diagnosis["candidate_sha"] and run["ci_pipeline_id"] == diagnosis["pipeline_id"],
         {:ok, exhausted_limit, hard} <- exhaustion_limits(run["last_error"], used, diagnosis),
         true <- used >= exhausted_limit and effective > used and effective > exhausted_limit,
         %{} = event <- failure_event(store, run["run_id"], cutoff),
         :ok <- event_pair(event, run),
         true <- ordered?(diagnosis["created_at"], event["occurred_at"]),
         {:ok, prior} <- original_event(store, diagnosis, original),
         true <- is_nil(prior) or prior["id"] < event["id"] do
      {:ok,
       %{
         "version" => 1,
         "kind" => @kind,
         "diagnosis_key" => diagnosis["diagnosis_key"],
         "preimage_sha256" => diagnosis["preimage_sha256"],
         "exhaustion_event_id" => event["id"],
         "exhaustion_event_payload_sha256" => sha(event["payload_json"]),
         "prior_exhaustion_event" => prior,
         "attempts_before" => used,
         "exhausted_limit" => exhausted_limit,
         "historical_hard_limit" => hard,
         "configured_limit" => configured,
         "effective_limit" => effective
       }}
    else
      _ -> refused()
    end
  end

  defp original_event(_store, _diagnosis, %{"failure_code" => nil, "last_error" => nil}), do: {:ok, nil}

  defp original_event(store, diagnosis, %{"failure_code" => "CI_REPAIR_EXHAUSTED"} = original) do
    with %{} = event <- failure_event(store, original["run_id"], diagnosis["created_at"]),
         :ok <- event_pair(event, original) do
      {:ok, %{"id" => event["id"], "payload_sha256" => sha(event["payload_json"])}}
    else
      _ -> refused()
    end
  end

  defp original_event(_, _, _), do: refused()

  defp diagnosed_run(row) do
    with true <- sha(row["preimage_json"]) == row["preimage_sha256"],
         {:ok, %{"run" => original}} when is_map(original) <- Jason.decode(row["preimage_json"]) do
      {:ok, original}
    else
      _ -> refused()
    end
  end

  defp claimed_diagnosis(store, claim), do: CiRepairReassessment.claimed(store, claim)

  defp failure_event(store, run_id, cutoff) do
    result =
      Store.query!(
        store,
        "SELECT * FROM events WHERE run_id=? AND event_type='RUN_UPDATED' AND (json_type(payload_json,'$.failure_code') IS NOT NULL OR json_type(payload_json,'$.last_error') IS NOT NULL) ORDER BY id DESC LIMIT 2001",
        [run_id]
      )

    true = length(result.rows) <= 2000
    events = Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    Enum.find(events, &(is_nil(cutoff) or ordered?(&1["occurred_at"], cutoff)))
  end

  defp event_pair(event, run) do
    with {:ok, payload} <- Jason.decode(event["payload_json"]),
         true <- Enum.sort(Map.keys(payload)) == ~w(failure_code last_error updated_at),
         true <- Map.take(payload, @failure) == Map.take(run, @failure),
         true <- event["run_id"] == run["run_id"] and event["event_type"] == "RUN_UPDATED",
         true <- ordered?(payload["updated_at"], event["occurred_at"]) do
      :ok
    else
      _ -> refused()
    end
  end

  defp exhaustion_limits(message, used, diagnosis) when is_binary(message) do
    with [_, limit, hard] <- Regex.run(~r/\ACI repair budget exhausted: \d+ total cycles used; configured limit (\d+) \(hard maximum (7|10)\)\./, message),
         limit = String.to_integer(limit),
         hard = String.to_integer(hard),
         true <- limit >= 1 and limit <= hard,
         expected =
           "CI repair budget exhausted: #{used} total cycles used; configured limit #{limit} (hard maximum #{hard}). Current failed pipeline #{diagnosis["pipeline_id"]}; assessment #{diagnosis["diagnosis_key"]}. Human investigation or a new authorized policy decision is required; no new writer or retry was issued.",
         true <- message == expected do
      {:ok, limit, hard}
    else
      _ -> refused()
    end
  end

  defp exhaustion_limits(_, _, _), do: refused()
  defp comparable(run), do: Map.drop(run, @bookkeeping)

  defp prefix_count(store, claim) do
    Store.one!(
      store,
      "SELECT (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=? AND round<?) + (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors s JOIN ticket_ci_repair_claims c ON c.claim_key=s.claim_key WHERE s.run_id=? AND c.round<?) AS n",
      [claim["run_id"], claim["round"], claim["run_id"], claim["round"]]
    )["n"]
  end

  defp ordered?(before, after_value) do
    {:ok, left, 0} = DateTime.from_iso8601(before)
    {:ok, right, 0} = DateTime.from_iso8601(after_value)
    DateTime.compare(left, right) in [:lt, :eq]
  end

  defp sha(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
  defp refused, do: {:error, :ci_repair_budget_resume_unproven}
end
