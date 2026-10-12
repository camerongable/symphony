defmodule SymphonyElixir.Factory.ControllerCi do
  @moduledoc "Pure exact-candidate CI data validation; connector provenance and delivery remain controller responsibilities."

  @pending ~w(created waiting_for_resource preparing pending running scheduled)
  @job_statuses @pending ++ ~w(success failed canceled canceling skipped manual waiting_for_callback)
  @sha ~r/\A[0-9a-f]{40}\z/

  @spec bind(map(), map(), pos_integer() | nil) :: {:ok, map()} | {:error, term()}
  def bind(_run, _snapshots, pin) when not is_integer(pin) or pin <= 0, do: {:error, :ci_project_pin_required}

  def bind(run, %{"mr" => mr, "pipeline" => pipeline, "jobs" => jobs, "merge_commit" => commit} = snapshots, project_id)
      when is_map(mr) and is_list(jobs) and length(jobs) <= 100 do
    with true <- Enum.sort(Map.keys(snapshots)) == ~w(jobs merge_commit mr pipeline) or {:error, :invalid_ci_snapshots},
         true <- containers?(mr, jobs) or {:error, :invalid_ci_snapshots},
         :ok <- mr_binding(run, mr, project_id),
         {:ok, source} <- pipeline_binding(run, mr, pipeline, commit),
         :ok <- current_pipeline(mr, pipeline),
         :ok <- jobs_binding(pipeline, jobs),
         {:ok, status, findings} <- verdict(pipeline, jobs) do
      {:ok,
       Map.merge(mr_fields(mr), pipeline_fields(pipeline))
       |> Map.merge(%{
         "status" => status,
         "required_jobs" => Enum.filter(jobs, &(&1["name"] == "bazel" and &1["allow_failure"] == false)) |> Enum.map(&Map.take(&1, ~w(id name status web_url))),
         "findings" => findings,
         "source_binding" => source
       })}
    end
  end

  def bind(_run, _snapshots, _pin), do: {:error, :invalid_ci_snapshots}

  defp containers?(mr, jobs) do
    object_list?(mr["assignees"]) and object_list?(mr["reviewers"]) and
      (is_nil(mr["diff_refs"]) or is_map(mr["diff_refs"])) and object_list?(jobs) and
      Enum.all?(jobs, &is_map(&1["pipeline"]))
  end

  defp object_list?(value), do: is_list(value) and Enum.all?(value, &is_map/1)

  defp mr_binding(run, mr, project_id) do
    expected = {run["mr_iid"], run["mr_url"], run["branch"], run["base_branch"], run["candidate_sha"]}
    observed = {mr["iid"], mr["web_url"], mr["source_branch"], mr["target_branch"], mr["sha"]}

    with true <- (sha?(run["candidate_sha"]) and run["ci_preflight_sha"] == run["candidate_sha"]) or {:error, :ci_candidate_unproven},
         true <- complete_mr_scope?(mr) or {:error, :ci_mr_binding_mismatch},
         true <- (observed == expected and mr["project_id"] == project_id) or {:error, :ci_mr_binding_mismatch},
         true <- get_in(mr, ["diff_refs", "head_sha"]) in [nil, run["candidate_sha"]] or {:error, :ci_mr_binding_mismatch} do
      mr_review_state(mr)
    end
  end

  defp mr_review_state(mr) do
    cond do
      mr["draft"] != true or mr["state"] != "opened" or mr["reviewers"] != [] -> {:error, :ci_mr_review_state_changed}
      not Enum.any?(mr["assignees"], &(&1["id"] == 11_599_766)) -> {:error, :ci_mr_assignee_mismatch}
      true -> :ok
    end
  end

  defp complete_mr_scope?(mr),
    do:
      is_integer(mr["iid"]) and mr["iid"] > 0 and
        Enum.all?(~w(web_url source_branch target_branch), &(is_binary(mr[&1]) and mr[&1] != ""))

  defp pipeline_binding(_run, _mr, nil, nil), do: {:ok, nil}

  defp pipeline_binding(run, mr, pipeline, commit) when is_map(pipeline) do
    with true <- (is_integer(pipeline["id"]) and pipeline["id"] > 0) or {:error, :ci_pipeline_id_invalid},
         true <- (pipeline["project_id"] == mr["project_id"] and pipeline["source"] == "merge_request_event") or {:error, :ci_pipeline_scope_mismatch},
         true <- (sha?(pipeline["sha"]) and present?(pipeline["web_url"])) or {:error, :ci_pipeline_binding_invalid} do
      source_binding(run, pipeline, commit)
    end
  end

  defp pipeline_binding(_run, _mr, _pipeline, _commit), do: {:error, :ci_pipeline_binding_invalid}

  defp current_pipeline(mr, nil) do
    if Map.has_key?(mr, "head_pipeline") and is_nil(mr["head_pipeline"]),
      do: :ok,
      else: {:error, :ci_current_pipeline_mismatch}
  end

  defp current_pipeline(%{"head_pipeline" => %{} = current}, pipeline) do
    fields = ~w(id project_id sha ref source status web_url)

    if Map.take(current, fields) == Map.take(pipeline, fields),
      do: :ok,
      else: {:error, :ci_current_pipeline_mismatch}
  end

  defp current_pipeline(_mr, _pipeline), do: {:error, :ci_current_pipeline_mismatch}

  defp source_binding(run, pipeline, commit) do
    head_ref = "refs/merge-requests/#{run["mr_iid"]}/head"
    merge_ref = "refs/merge-requests/#{run["mr_iid"]}/merge"

    cond do
      pipeline["ref"] == head_ref and pipeline["sha"] == run["candidate_sha"] and is_nil(commit) ->
        {:ok, %{"kind" => "HEAD", "candidate_sha" => run["candidate_sha"]}}

      pipeline["ref"] == merge_ref ->
        merge_source_binding(run, pipeline, commit)

      true ->
        {:error, :ci_pipeline_candidate_mismatch}
    end
  end

  defp merge_source_binding(run, pipeline, %{"id" => sha, "parent_ids" => [target, source]}) do
    if sha == pipeline["sha"] and source == run["candidate_sha"] and sha?(target) and target != source,
      do: {:ok, %{"kind" => "MERGE", "candidate_sha" => source, "merge_sha" => sha, "target_parent_sha" => target}},
      else: {:error, :ci_merge_source_unproven}
  end

  defp merge_source_binding(_run, _pipeline, _commit), do: {:error, :ci_merge_source_unproven}

  defp jobs_binding(nil, []), do: :ok

  defp jobs_binding(pipeline, jobs) when is_map(pipeline) do
    ids = Enum.map(jobs, & &1["id"])

    cond do
      length(Enum.uniq(ids)) != length(ids) -> {:error, :ci_jobs_ambiguous}
      not Enum.all?(jobs, &job_bound?(&1, pipeline)) -> {:error, :ci_job_binding_mismatch}
      true -> :ok
    end
  end

  defp jobs_binding(_pipeline, _jobs), do: {:error, :ci_job_binding_mismatch}

  defp job_bound?(job, pipeline) when is_map(job) do
    is_integer(job["id"]) and job["id"] > 0 and present?(job["name"]) and present?(job["web_url"]) and
      job["allow_failure"] in [true, false] and
      job["status"] in @job_statuses and
      get_in(job, ["pipeline", "id"]) == pipeline["id"] and
      get_in(job, ["pipeline", "project_id"]) == pipeline["project_id"] and
      get_in(job, ["pipeline", "sha"]) == pipeline["sha"]
  end

  defp verdict(nil, []), do: {:ok, "WAIT", []}
  defp verdict(%{"status" => status}, _jobs) when status in @pending, do: {:ok, "WAIT", []}

  defp verdict(%{"status" => "success"}, jobs) do
    required = Enum.filter(jobs, &(&1["allow_failure"] == false))

    case required_job_states(required) do
      :ok -> bazel_verdict(required)
      result -> result
    end
  end

  defp verdict(_pipeline, _jobs), do: {:ok, "BLOCK", ["Pipeline did not pass; controller diagnosis is required."]}

  defp required_job_states(jobs) do
    cond do
      Enum.any?(jobs, &(&1["status"] in ~w(failed canceled canceling))) -> {:error, :ci_snapshot_inconsistent}
      Enum.any?(jobs, &(&1["status"] in @pending)) -> {:ok, "WAIT", []}
      Enum.any?(jobs, &(&1["status"] not in ~w(success skipped))) -> {:error, :ci_snapshot_inconsistent}
      true -> :ok
    end
  end

  defp bazel_verdict(jobs) do
    case Enum.filter(jobs, &(&1["name"] == "bazel" and &1["allow_failure"] == false)) do
      [%{"status" => "success"}] -> {:ok, "PASS", []}
      [] -> {:ok, "BLOCK", ["Successful pipeline lacks a required non-allow-failure Bazel job."]}
      [_job] -> {:ok, "BLOCK", ["Required Bazel job did not pass."]}
      _ -> {:error, :ci_jobs_ambiguous}
    end
  end

  defp mr_fields(mr),
    do: %{
      "mr_url" => mr["web_url"],
      "iid" => mr["iid"],
      "sha" => mr["sha"],
      "source_branch" => mr["source_branch"],
      "target_branch" => mr["target_branch"],
      "draft" => mr["draft"],
      "reviewers_count" => 0,
      "assignee_id" => 11_599_766,
      "mr_state" => mr["state"]
    }

  defp pipeline_fields(nil), do: %{"pipeline_id" => nil, "pipeline_url" => nil, "pipeline_sha" => nil, "pipeline_ref" => nil, "pipeline_source" => nil, "pipeline_status" => "missing"}

  defp pipeline_fields(pipeline),
    do: %{
      "pipeline_id" => pipeline["id"],
      "pipeline_url" => pipeline["web_url"],
      "pipeline_sha" => pipeline["sha"],
      "pipeline_ref" => pipeline["ref"],
      "pipeline_source" => pipeline["source"],
      "pipeline_status" => pipeline["status"]
    }

  defp sha?(value), do: is_binary(value) and Regex.match?(@sha, value)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
