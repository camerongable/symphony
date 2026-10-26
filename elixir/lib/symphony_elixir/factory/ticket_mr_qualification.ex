defmodule SymphonyElixir.Factory.TicketMrQualification do
  @moduledoc "Immutable fresh-MR observations; completed controller results are never rewritten."
  alias SymphonyElixir.Factory.{Control, DesktopRequest, RepairObligations, RunLedger, StageSchemas, Store}
  alias SymphonyElixir.Factory.{TicketCiRepair, TicketMrOperation}
  @kind "MR_OBSERVATION_V1"
  @stable ~w(run_id candidate_sha contract_sha256 spec_revision code_repair_round repo_key repo_path worktree branch base_branch mr_iid mr_url)
  @bookkeeping ~w(lease_expires_at updated_at)

  @spec prepare(Store.connection(), map(), map(), map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(%DBConnection{}, _run, _request, _binding, _output, _scope), do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, run, request, binding, output, scope) do
    with {:ok, current} <- RunLedger.get(store, run["run_id"]),
         true <- current == run and run["state"] == binding["stage"] and run["state"] in ~w(CI_MR_CREATING MR_CREATING) and binding["scope"] == scope,
         {:ok, claim} <- original(store, run, request, binding, output),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, run["run_id"]),
         control when is_map(control) <- Control.status(store, scope),
         :ok <- lease(control),
         nil <- Store.one!(store, "SELECT qualification_key FROM ticket_mr_qualifications WHERE request_key=?", [request["request_key"]]) do
      prepared = %{run: run, request: request, binding: binding, output: output, claim: claim}
      {:ok, Map.merge(prepared, %{inputs: inputs, control: control, scope: scope})}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_qualification_ineligible}
    end
  end

  @spec observe(map(), map(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def observe(prepared, mr, started) do
    with :ok <- observation(prepared.run, prepared.binding, mr) do
      {:ok, Map.merge(prepared, %{mr: mr, observed_at: DateTime.to_iso8601(started)})}
    end
  end

  @spec persist(DBConnection.t(), map()) :: :ok | {:error, atom()}
  def persist(%DBConnection{} = tx, prepared) do
    with {:ok, current} <- RunLedger.get(tx, prepared.run["run_id"]),
         true <- current == prepared.run,
         {:ok, request} <- DesktopRequest.get(tx, prepared.request["request_key"]),
         true <- request == prepared.request,
         {:ok, claim} <- original(tx, current, request, prepared.binding, prepared.output),
         true <- claim == prepared.claim,
         {:ok, inputs} <- TicketCiRepair.input_snapshot(tx, current["run_id"]),
         true <- inputs == prepared.inputs,
         control when is_map(control) <- Control.status(tx, prepared.scope),
         :ok <- lease(control),
         true <- Map.drop(control, @bookkeeping) == Map.drop(prepared.control, @bookkeeping),
         {:ok, at, _} <- DateTime.from_iso8601(prepared.observed_at),
         true <- DateTime.diff(DateTime.utc_now(), at, :millisecond) in 0..60_000,
         :ok <- observation(current, prepared.binding, prepared.mr),
         nil <- Store.one!(tx, "SELECT qualification_key FROM ticket_mr_qualifications WHERE request_key=?", [request["request_key"]]) do
      preimage = Jason.encode!(%{"run" => prepared.run, "request" => request, "binding" => prepared.binding, "claim" => claim, "inputs" => inputs, "control" => prepared.control})
      mr = Jason.encode!(prepared.mr)
      key = key(request, prepared.binding)

      Store.query!(tx, "INSERT INTO ticket_mr_qualifications VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
        key,
        request["request_key"],
        current["run_id"],
        current["candidate_sha"],
        current["contract_sha256"],
        current["spec_revision"],
        prepared.binding["stage"],
        prepared.binding["completed_push_sha256"],
        digest(Jason.encode!(request)),
        digest(request["output_json"]),
        digest(Jason.encode!(prepared.binding)),
        preimage,
        digest(preimage),
        mr,
        digest(mr),
        prepared.observed_at,
        @kind
      ])

      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_mr_qualification_changed}
    end
  end

  @spec resolve(Store.connection(), map(), map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def resolve(store, run, request, binding, output) do
    with row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_mr_qualifications WHERE request_key=?", [request["request_key"]]),
         true <- row["kind"] == @kind and row["qualification_key"] == key(request, binding),
         true <- Map.take(row, ~w(run_id candidate_sha contract_sha256 spec_revision)) == Map.take(run, ~w(run_id candidate_sha contract_sha256 spec_revision)),
         true <- row_push_matches?(row, binding, run),
         true <- row["request_sha256"] == digest(Jason.encode!(request)) and row["output_sha256"] == digest(request["output_json"]) and row["binding_sha256"] == digest(Jason.encode!(binding)),
         true <- digest(row["preimage_json"]) == row["preimage_sha256"] and digest(row["observation_json"]) == row["observation_sha256"],
         {:ok, saved} <- Jason.decode(row["preimage_json"]),
         true <- is_map(saved) and is_map(saved["run"]),
         true <- Map.take(saved["run"], @stable) == Map.take(run, @stable) and saved["request"] == request and saved["binding"] == binding,
         {:ok, claim} <- original(store, run, request, binding, output, :historical),
         true <- claim == saved["claim"],
         {:ok, mr} <- Jason.decode(row["observation_json"]),
         true <- is_map(mr),
         :ok <- observation(run, binding, mr),
         {:ok, _, _} <- DateTime.from_iso8601(row["observed_at"]) do
      {:ok, fields(mr)}
    else
      _ -> {:error, :ticket_mr_result_mismatch}
    end
  end

  defp row_push_matches?(row, binding, run) do
    row["stage"] == binding["stage"] and row["completed_push_sha256"] == binding["completed_push_sha256"] and
      row["completed_push_sha256"] == digest(run["candidate_handoff"])
  end

  @spec fields(map()) :: map()
  def fields(mr), do: %{"mr_iid" => mr["iid"], "mr_url" => mr["web_url"], "mr_state" => mr["state"]}

  defp original(store, run, request, binding, output, mode \\ :current) do
    with true <-
           request["status"] == "SUCCEEDED" and
             Map.take(binding, ~w(run_id candidate_sha contract_sha256 spec_revision)) == Map.take(run, ~w(run_id candidate_sha contract_sha256 spec_revision)) and
             binding["completed_push_sha256"] == digest(run["candidate_handoff"]),
         :ok <- TicketMrOperation.authorize_readback(store, request),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         true <- metadata["delivery_operation"] == binding,
         {:ok, %{"result" => ^output, "completed_tool_calls" => calls}} <- Jason.decode(request["output_json"]),
         true <- is_list(calls) and Enum.any?(calls, &(&1["server"] == "GitLab" and &1["tool"] == "get_merge_request" and &1["status"] == "completed")),
         :ok <- StageSchemas.validate(output, StageSchemas.for_stage(:gitlab_mr)),
         {:ok, prior} <- TicketCiRepair.retained_preimage(store, run),
         true <- prior["candidate_sha"] != run["candidate_sha"],
         expected = %{
           "status" => "BLOCK",
           "sha" => prior["candidate_sha"],
           "iid" => prior["mr_iid"],
           "mr_url" => prior["mr_url"],
           "source_branch" => run["branch"],
           "target_branch" => run["base_branch"],
           "draft" => true,
           "reviewers_count" => 0,
           "assignee_id" => 11_599_766,
           "state" => "opened"
         },
         true <- Map.take(output, Map.keys(expected)) == expected,
         {:ok, claim} <- repair_scope(store, run, mode) do
      {:ok, claim}
    else
      _ -> {:error, :ticket_mr_qualification_ineligible}
    end
  end

  defp repair_scope(store, run, mode) do
    case Store.one!(store, "SELECT * FROM ticket_ci_repair_claims WHERE run_id=? AND round=?", [run["run_id"], run["code_repair_round"]]) do
      nil ->
        case RepairObligations.ordinary_preflight(store, run) do
          {:ok, proof} -> {:ok, proof}
          _ when mode == :historical -> RepairObligations.ordinary_history(store, run)
          error -> error
        end

      claim ->
        {:ok, claim}
    end
  end

  defp observation(run, binding, mr) do
    expected = %{
      "iid" => run["mr_iid"],
      "web_url" => run["mr_url"],
      "project_id" => binding["gitlab_project_id"],
      "sha" => run["candidate_sha"],
      "source_branch" => run["branch"],
      "target_branch" => run["base_branch"],
      "state" => "opened",
      "draft" => true,
      "reviewers" => [],
      "remove_source_branch" => false
    }

    if Map.take(mr, Map.keys(expected)) == expected and is_list(mr["assignees"]) and Enum.any?(mr["assignees"], &(is_map(&1) and &1["id"] == 11_599_766)) and
         (is_nil(mr["diff_refs"]) or (is_map(mr["diff_refs"]) and mr["diff_refs"]["head_sha"] in [nil, run["candidate_sha"]])) do
      :ok
    else
      {:error, :ticket_mr_qualification_observation_mismatch}
    end
  end

  defp lease(control) do
    with true <- control["status"] == "ACTIVE" and is_binary(control["tick_id"]),
         {:ok, expires, _} <- DateTime.from_iso8601(control["lease_expires_at"] || ""),
         true <- DateTime.compare(expires, DateTime.utc_now()) == :gt do
      :ok
    else
      _ -> {:error, :ticket_mr_qualification_lease_unproven}
    end
  end

  defp key(request, binding), do: "mr-observation:" <> digest(Jason.encode!([request["request_key"], digest(request["output_json"]), binding["completed_push_sha256"]]))
  defp digest(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
