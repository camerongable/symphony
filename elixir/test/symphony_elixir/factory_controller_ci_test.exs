defmodule SymphonyElixir.FactoryControllerCiTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, TicketWorkerRunner}

  setup :setup_fixture

  defp readbacks(ctx) do
    url = "https://gitlab.com/grailbio/grail/-/merge_requests/42"
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "CI_WAITING", mr_iid: 42, mr_url: url, ci_preflight_sha: ctx.sha})
    {:ok, run} = RunLedger.get(ctx.store, "run")

    snapshots = %{
      "mr" => %{
        "iid" => 42,
        "project_id" => 33_747_681,
        "web_url" => url,
        "sha" => ctx.sha,
        "diff_refs" => %{"head_sha" => ctx.sha},
        "source_branch" => "cgable/fixture",
        "target_branch" => "master",
        "draft" => true,
        "reviewers" => [],
        "assignees" => [%{"id" => 11_599_766}],
        "state" => "opened"
      },
      "pipeline" => %{
        "id" => 99,
        "project_id" => 33_747_681,
        "sha" => ctx.sha,
        "ref" => "refs/merge-requests/42/head",
        "source" => "merge_request_event",
        "status" => "success",
        "web_url" => "https://gitlab.com/grailbio/grail/-/pipelines/99"
      },
      "jobs" => [
        %{
          "id" => 100,
          "name" => "bazel",
          "status" => "success",
          "allow_failure" => false,
          "web_url" => "https://gitlab.com/grailbio/grail/-/jobs/100",
          "pipeline" => %{"id" => 99, "project_id" => 33_747_681, "sha" => ctx.sha}
        }
      ],
      "merge_commit" => nil
    }

    {run, put_in(snapshots, ["mr", "head_pipeline"], snapshots["pipeline"])}
  end

  test "CI head-pipeline evidence binds the exact candidate without advancing delivery", ctx do
    {run, snapshots} = readbacks(ctx)
    assert {:ok, evidence} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
    assert evidence["status"] == "PASS"
    assert evidence["sha"] == ctx.sha
    assert evidence["pipeline_id"] == 99
    assert evidence["source_binding"] == %{"kind" => "HEAD", "candidate_sha" => ctx.sha}
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  test "malformed GitLab container fields fail closed instead of crashing the controller", ctx do
    {_run, snapshots} = readbacks(ctx)
    malformed = put_in(snapshots, ["mr", "assignees"], ["not an assignee object"])
    assert {:error, :invalid_ci_snapshots} = TicketWorkerRunner.ci_binding(ctx.store, "run", malformed, 33_747_681)
    assert {:error, :invalid_ci_snapshots} = TicketWorkerRunner.ci_binding(ctx.store, "run", %{}, 33_747_681)
    malformed = Map.put(snapshots, "pipeline", "not a pipeline")
    assert {:error, :ci_pipeline_binding_invalid} = TicketWorkerRunner.ci_binding(ctx.store, "run", malformed, 33_747_681)

    for invalid <- [nil, "not a job object"] do
      malformed = Map.put(snapshots, "jobs", [invalid])
      assert {:error, :invalid_ci_snapshots} = TicketWorkerRunner.ci_binding(ctx.store, "run", malformed, 33_747_681)
    end

    assert {:ok, unchanged} = RunLedger.get(ctx.store, "run")
    assert unchanged["state"] == "CI_WAITING"
  end

  test "a running current pipeline waits without advancing the run", ctx do
    {run, snapshots} = readbacks(ctx)
    snapshots = put_in(snapshots, ["pipeline", "status"], "running")
    snapshots = put_in(snapshots, ["mr", "head_pipeline"], snapshots["pipeline"])
    assert {:ok, %{"status" => "WAIT"}} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  test "jobs without a pipeline and branch pipelines cannot qualify", ctx do
    {_run, snapshots} = readbacks(ctx)
    missing = snapshots |> Map.put("pipeline", nil) |> put_in(["mr", "head_pipeline"], nil)
    assert {:error, :ci_job_binding_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", missing, 33_747_681)
    branch = put_in(snapshots, ["pipeline", "ref"], "master")
    assert {:error, :ci_pipeline_candidate_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", branch, 33_747_681)
  end

  test "skipped or competing required Bazel jobs cannot produce a pass", ctx do
    {_run, snapshots} = readbacks(ctx)
    [job] = snapshots["jobs"]
    skipped = Map.put(snapshots, "jobs", [Map.put(job, "status", "skipped")])
    assert {:ok, %{"status" => "BLOCK"}} = TicketWorkerRunner.ci_binding(ctx.store, "run", skipped, 33_747_681)
    competing = Map.put(snapshots, "jobs", [job, Map.put(job, "id", 101)])
    assert {:error, :ci_jobs_ambiguous} = TicketWorkerRunner.ci_binding(ctx.store, "run", competing, 33_747_681)
  end

  test "self-reported project IDs cannot substitute for a controller project pin", ctx do
    {_run, snapshots} = readbacks(ctx)
    assert {:error, :ci_project_pin_required} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots)
    assert {:error, :ci_mr_binding_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 123)
  end

  test "an older success for the same candidate cannot replace the MR's current pipeline", ctx do
    {_run, snapshots} = readbacks(ctx)
    snapshots = put_in(snapshots, ["mr", "head_pipeline"], Map.put(snapshots["pipeline"], "id", 101))
    assert {:error, :ci_current_pipeline_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
  end

  test "CI cannot pass when current-pipeline visibility or scope is incomplete", ctx do
    {_run, snapshots} = readbacks(ctx)

    for mr <- [
          Map.delete(snapshots["mr"], "head_pipeline"),
          Map.put(snapshots["mr"], "head_pipeline", nil),
          Map.put(snapshots["mr"], "head_pipeline", "not a pipeline"),
          put_in(snapshots["mr"], ["head_pipeline", "project_id"], 123),
          put_in(snapshots["mr"], ["head_pipeline", "status"], "failed"),
          put_in(snapshots["mr"], ["head_pipeline", "sha"], String.duplicate("a", 40))
        ] do
      assert {:error, :ci_current_pipeline_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", Map.put(snapshots, "mr", mr), 33_747_681)
    end
  end

  test "hidden pipeline visibility is not interpreted as an absent pipeline", ctx do
    {_run, snapshots} = readbacks(ctx)
    snapshots = Map.merge(snapshots, %{"pipeline" => nil, "jobs" => []})
    snapshots = Map.update!(snapshots, "mr", &Map.delete(&1, "head_pipeline"))
    assert {:error, :ci_current_pipeline_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
  end

  test "a merged-result pipeline proves its own source parent rather than trusting the current MR head", ctx do
    {_run, snapshots} = readbacks(ctx)
    merge_sha = String.duplicate("b", 40)
    target_sha = String.duplicate("a", 40)
    snapshots = put_in(snapshots, ["pipeline", "sha"], merge_sha)
    snapshots = put_in(snapshots, ["pipeline", "ref"], "refs/merge-requests/42/merge")
    snapshots = put_in(snapshots, ["mr", "head_pipeline"], snapshots["pipeline"])
    snapshots = Map.update!(snapshots, "jobs", fn [job] -> [put_in(job, ["pipeline", "sha"], merge_sha)] end)
    assert {:error, :ci_merge_source_unproven} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
    snapshots = Map.put(snapshots, "merge_commit", %{"id" => merge_sha, "parent_ids" => [target_sha, ctx.sha]})
    assert {:ok, evidence} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
    assert evidence["status"] == "PASS"
    assert evidence["source_binding"] == %{"kind" => "MERGE", "candidate_sha" => ctx.sha, "merge_sha" => merge_sha, "target_parent_sha" => target_sha}
    stale = put_in(snapshots, ["merge_commit", "parent_ids"], [target_sha, String.duplicate("c", 40)])
    assert {:error, :ci_merge_source_unproven} = TicketWorkerRunner.ci_binding(ctx.store, "run", stale, 33_747_681)
  end

  test "no exact-MR pipeline is a read-only wait rather than a pass", ctx do
    {run, snapshots} = readbacks(ctx)
    snapshots = Map.merge(snapshots, %{"pipeline" => nil, "jobs" => []})
    snapshots = put_in(snapshots, ["mr", "head_pipeline"], nil)
    assert {:ok, %{"status" => "WAIT", "pipeline_id" => nil, "source_binding" => nil}} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  test "an allow-failure Bazel success cannot satisfy the required test gate", ctx do
    {_run, snapshots} = readbacks(ctx)
    snapshots = Map.update!(snapshots, "jobs", fn [job] -> [Map.put(job, "allow_failure", true)] end)
    assert {:ok, %{"status" => "BLOCK"}} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
  end

  test "a job from another pipeline cannot become evidence for this candidate", ctx do
    {_run, snapshots} = readbacks(ctx)
    snapshots = Map.update!(snapshots, "jobs", fn [job] -> [put_in(job, ["pipeline", "id"], 101)] end)
    assert {:error, :ci_job_binding_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
  end

  test "pipeline failures do not guess source repairs or retry a remote job", ctx do
    {run, snapshots} = readbacks(ctx)
    snapshots = put_in(snapshots, ["pipeline", "status"], "failed")
    snapshots = put_in(snapshots, ["mr", "head_pipeline"], snapshots["pipeline"])
    assert {:ok, %{"status" => "BLOCK", "findings" => [_]}} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
    assert {:ok, ^run} = RunLedger.get(ctx.store, "run")
  end

  test "a newer candidate rejects an old CI observation", ctx do
    {_run, snapshots} = readbacks(ctx)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: String.duplicate("c", 40)})
    assert {:error, :ci_candidate_unproven} = TicketWorkerRunner.ci_binding(ctx.store, "run", snapshots, 33_747_681)
  end

  test "duplicate job IDs are rejected before a Bazel success can pass", ctx do
    {_run, snapshots} = readbacks(ctx)
    [job] = snapshots["jobs"]
    duplicated = Map.put(snapshots, "jobs", [job, Map.put(job, "allow_failure", true)])
    assert {:error, :ci_jobs_ambiguous} = TicketWorkerRunner.ci_binding(ctx.store, "run", duplicated, 33_747_681)
  end

  test "successful CI data must retain usable pipeline and job links", ctx do
    {_run, snapshots} = readbacks(ctx)
    invalid = put_in(snapshots, ["pipeline", "web_url"], "")
    assert {:error, :ci_pipeline_binding_invalid} = TicketWorkerRunner.ci_binding(ctx.store, "run", invalid, 33_747_681)
    invalid = Map.update!(snapshots, "jobs", fn [job] -> [Map.put(job, "web_url", " ")] end)
    assert {:error, :ci_job_binding_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", invalid, 33_747_681)
  end

  test "another required job cannot fail underneath a successful pipeline label", ctx do
    {_run, snapshots} = readbacks(ctx)
    [job] = snapshots["jobs"]
    failed = Map.merge(job, %{"id" => 101, "name" => "lint", "status" => "failed"})
    inconsistent = Map.put(snapshots, "jobs", [job, failed])
    assert {:error, :ci_snapshot_inconsistent} = TicketWorkerRunner.ci_binding(ctx.store, "run", inconsistent, 33_747_681)
    malformed = Map.put(snapshots, "jobs", [job, Map.put(failed, "status", nil)])
    assert {:error, :ci_job_binding_mismatch} = TicketWorkerRunner.ci_binding(ctx.store, "run", malformed, 33_747_681)
  end
end
