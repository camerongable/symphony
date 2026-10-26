defmodule SymphonyElixir.Factory.TicketPushPayloadBudget do
  @moduledoc """
  Accounts for completed V12 push copies at explicitly supported journal paths.

  Projection is used only to measure the original two MiB non-push remainder.
  Callers retain and hash the complete original bytes. This grants no push or
  historical-adoption authority; those independent validators remain required.
  """

  alias SymphonyElixir.Factory.TicketPushIO

  @base 2_097_152
  @envelope 12_582_912
  @request 1_048_576
  @receipt 4_194_304
  @keys ~w(version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha)
  @identity ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision)

  @doc "Measures only fixed supported copies, retaining the legacy budget for every other byte."
  @spec bounded?(map(), atom()) :: boolean()
  def bounded?(value, kind) when is_map(value) do
    raw = Jason.encode!(value)

    byte_size(raw) <= @base or (byte_size(raw) <= absolute_limit(kind) and qualified?(value, kind))
  end

  def bounded?(_value, _kind), do: false

  @doc "Decodes one specifically typed journal object without changing its bytes or digest."
  @spec object(term(), atom()) :: {:ok, map()} | {:error, atom()}
  def object(raw, kind) when is_binary(raw) do
    with true <- byte_size(raw) <= absolute_limit(kind),
         {:ok, value} when is_map(value) <- Jason.decode(raw),
         true <- byte_size(raw) <= @base or qualified?(value, kind) do
      {:ok, value}
    else
      _ -> {:error, :push_payload_budget_exceeded}
    end
  end

  def object(_raw, _kind), do: {:error, :push_payload_budget_exceeded}

  defp qualified?(value, kind) do
    case project(value, kind) do
      {:ok, projected, [_ | _] = copies} ->
        length(copies) <= if(kind == :successor, do: 2, else: 1) and
          length(Enum.uniq(copies)) == 1 and byte_size(Jason.encode!(projected)) <= @base

      _ ->
        false
    end
  end

  # A JSON string can at most double its input bytes on each supported layer.
  # Diagnosis rows contain two layers; successor proofs contain one direct and
  # one claim-JSON copy. These ceilings never exempt other paths or remainder.
  defp absolute_limit(:diagnosis_row), do: @base + 4 * @envelope
  defp absolute_limit(:successor), do: @base + 6 * @envelope
  defp absolute_limit(kind) when kind in [:preimage, :claim, :import, :ordinary_generation], do: @base + 2 * @envelope
  defp absolute_limit(_kind), do: @base

  defp project(value, :diagnosis_row), do: project_json(value, "preimage_json", "preimage_sha256", :preimage)
  defp project(value, :preimage), do: project_run(value, "run")
  defp project(value, :claim), do: project_run(value, "prior_run")
  defp project(value, :import), do: project_run(value, "prior_run")

  defp project(%{"version" => 1, "kind" => "CONTROLLER_ORDINARY_GENERATION", "operation" => operation} = value, :ordinary_generation)
       when operation in ~w(GOFMT_DIFF GAZELLE_DIFF) do
    with run when is_map(run) <- value["run_preimage"],
         %{"version" => version, "kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1"} = proof <- value["ordinary_verifier_repair"],
         true <- is_integer(version) and version in [1, 2],
         true <- hex?(proof["reviewed_candidate_sha"], 40) and hex?(proof["source_parent_sha"], 40),
         true <- proof["candidate_sha"] == proof["source_parent_sha"] and proof["source_parent_sha"] == run["candidate_sha"],
         raw when is_binary(raw) <- run["candidate_handoff"],
         {:ok, marker} <- completed_marker(raw, Map.put(run, "candidate_sha", proof["reviewed_candidate_sha"])) do
      {:ok, put_in(value, ["run_preimage", "candidate_handoff"], marker), [marker["sha256"]]}
    else
      _ -> {:error, :push_payload_completion_unproven}
    end
  end

  defp project(%{"claim" => claim} = value, :successor) when is_map(claim) do
    with {:ok, projected, direct} <- project_run(value, "run"),
         {:ok, claimed, nested} <- project_json(claim, "claim_json", "claim_sha256", :claim),
         true <- duplicate_predecessor?(value, claim, direct, nested) do
      {:ok, Map.put(projected, "claim", claimed), direct ++ nested}
    else
      _ -> {:error, :push_payload_copy_changed}
    end
  end

  defp project(_value, _kind), do: {:error, :push_payload_path_unproven}

  defp project_json(value, key, hash_key, kind) do
    with raw when is_binary(raw) <- value[key],
         true <- byte_size(raw) <= absolute_limit(kind) and digest(raw) == value[hash_key],
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw),
         {:ok, projected, copies} <- project(decoded, kind) do
      {:ok, Map.put(value, key, Jason.encode!(projected)), copies}
    else
      _ -> {:error, :push_payload_json_changed}
    end
  end

  defp project_run(value, key) do
    with run when is_map(run) <- value[key],
         raw when is_binary(raw) <- run["candidate_handoff"],
         {:ok, marker} <- completed_marker(raw, run) do
      {:ok, put_in(value, [key, "candidate_handoff"], marker), [marker["sha256"]]}
    else
      _ -> {:error, :push_payload_completion_unproven}
    end
  end

  defp duplicate_predecessor?(value, claim, [_], [_]) do
    with {:ok, decoded} <- Jason.decode(claim["claim_json"]) do
      get_in(value, ["run", "candidate_handoff"]) == get_in(decoded, ["prior_run", "candidate_handoff"])
    end
  end

  defp duplicate_predecessor?(_value, _claim, _direct, _nested), do: false

  defp completed_marker(raw, run) when byte_size(raw) <= @envelope do
    with {:ok, envelope} when is_map(envelope) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(envelope)) == Enum.sort(@keys),
         true <- {envelope["version"], envelope["kind"], envelope["phase"]} == {1, "TICKET_PUSH", "COMPLETED"},
         true <- is_integer(envelope["reservation_generation"]) and envelope["reservation_generation"] > 0,
         true <- envelope["remote_sha"] == run["candidate_sha"] and hex?(run["candidate_sha"], 40),
         binding_raw when is_binary(binding_raw) and byte_size(binding_raw) <= @request <- envelope["binding_json"],
         true <- digest(binding_raw) == envelope["binding_sha256"],
         true <- envelope["reservation_key"] == "ticket-push:" <> digest(binding_raw),
         {:ok, binding} when is_map(binding) <- Jason.decode(binding_raw),
         true <- Map.take(binding, @identity) == Map.take(run, @identity),
         execution_raw when is_binary(execution_raw) and byte_size(execution_raw) <= @request <- envelope["execution_json"],
         {:ok, execution} when is_map(execution) <- Jason.decode(execution_raw),
         true <- TicketPushIO.large_payload_origin?(execution),
         true <- hex?(envelope["owner_nonce"], 64),
         receipt when is_binary(receipt) and byte_size(receipt) <= @receipt <- envelope["receipt_json"],
         true <- digest(receipt) == envelope["receipt_sha256"],
         true <- TicketPushIO.receipt_valid?(receipt, envelope) do
      {:ok, %{"kind" => "COMPLETED_V12_PUSH_SIZE_V1", "sha256" => digest(raw), "bytes" => byte_size(raw)}}
    else
      _ -> {:error, :push_payload_completion_unproven}
    end
  end

  defp completed_marker(_raw, _run), do: {:error, :push_payload_envelope_limit}

  defp hex?(value, count), do: is_binary(value) and byte_size(value) == count and String.match?(value, ~r/\A[0-9a-f]+\z/)
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
