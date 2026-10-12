defmodule SymphonyElixir.Factory.NativeWorkspaceMaintenance do
  @moduledoc "Bounded native workspace capability admission, isolated from delivery and writer state."

  alias SymphonyElixir.Factory.{DesktopRequest, ModelRouter, NativeWorktreeProbe, RunLedger, Store, TaskLedger}

  @reserved ~w(PROBING ARCHIVE_PENDING ARCHIVED RESTORE_PENDING RECONCILE_REQUIRED)
  @active_tasks ~w(STARTING RUNNING WAITING_FOR_BROKER WAITING_FOR_WRITER STALE RETRY_PENDING)
  @unresolved ~w(PENDING CREATE_UNCERTAIN FOLLOWUP_UNCERTAIN THREAD_RECORDED RECONCILE_REQUIRED)

  @spec enabled?(map()) :: boolean()
  def enabled?(factory), do: get_in(factory, [:cleanup, "native", "enabled"]) == true

  @spec snapshot(Store.connection()) :: [map()]
  def snapshot(store), do: rows(store, "SELECT * FROM native_workspace_maintenance ORDER BY checked_at, run_id", [])

  @spec ensure_available(Store.connection(), String.t()) :: :ok | {:error, atom()}
  def ensure_available(store, run_id) do
    case Store.one!(
           store,
           """
           SELECT maintenance.phase, run.issue_key FROM runs AS run
           LEFT JOIN native_workspace_maintenance AS maintenance ON maintenance.run_id = run.run_id
           WHERE run.run_id = ?
           """,
           [run_id]
         ) do
      %{"issue_key" => issue_key} when not is_nil(issue_key) ->
        if v1_issue_owned?(store, issue_key) do
          {:error, :run_quarantined}
        else
          checkout_available(store, run_id)
        end

      _other ->
        :ok
    end
  end

  @doc "Checks maintenance reservations without admitting cleanup or altering run ownership."
  @spec checkout_available(Store.connection(), String.t()) :: :ok | {:error, atom()}
  def checkout_available(store, run_id) do
    case Store.one!(store, "SELECT phase FROM native_workspace_maintenance WHERE run_id = ?", [run_id]) do
      %{"phase" => phase} when phase in @reserved -> {:error, :native_workspace_maintenance_reserved}
      _other -> :ok
    end
  end

  defp v1_issue_owned?(store, issue_key),
    do: Store.one!(store, "SELECT run_id FROM runs WHERE issue_key = ? AND execution_mode = 'TICKET_SUPERVISOR_V1' LIMIT 1", [issue_key]) != nil

  @spec plan(Store.connection()) :: [map()]
  def plan(store) do
    rows(
      store,
      """
      SELECT run.* FROM runs AS run
      LEFT JOIN native_workspace_maintenance AS maintenance ON maintenance.run_id = run.run_id
      WHERE run.kind = 'DELIVERY' AND run.workspace_state = 'CODEX_NATIVE' AND run.factory_owned = 0
        AND run.state IN ('READY_FOR_REVIEW', 'DELIVERED')
        AND COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY'
        AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
      ORDER BY COALESCE(maintenance.checked_at, ''), run.updated_at, run.run_id
      """,
      []
    )
    |> Enum.map(fn run ->
      case candidate_binding(store, run) do
        {:ok, binding} -> %{run_id: run["run_id"], eligible: true, binding: binding, reason: nil}
        {:error, reason} -> %{run_id: run["run_id"], eligible: false, binding: nil, reason: reason}
      end
    end)
  end

  @spec reconcile(Store.connection(), map()) :: {:ok, atom() | map()} | {:error, term()}
  def reconcile(store, factory) do
    Store.transaction!(store, &reconcile_transaction(&1, factory))
  end

  defp reconcile_transaction(store, factory) do
    case reserved(store) do
      %{} = record -> reconcile_record(store, record)
      nil -> if enabled?(factory), do: admit_one(store, factory), else: {:ok, :disabled}
    end
  end

  defp reserved(store) do
    Store.one!(
      store,
      """
      SELECT * FROM native_workspace_maintenance
      WHERE phase IN ('PROBING', 'ARCHIVE_PENDING', 'RESTORE_PENDING', 'RECONCILE_REQUIRED')
        AND EXISTS (SELECT 1 FROM runs WHERE runs.run_id = native_workspace_maintenance.run_id AND COALESCE(runs.execution_mode, 'LEGACY') = 'LEGACY')
        AND NOT EXISTS (SELECT 1 FROM runs AS legacy_run JOIN runs AS supervisor ON supervisor.issue_key = legacy_run.issue_key WHERE legacy_run.run_id = native_workspace_maintenance.run_id AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
      LIMIT 1
      """,
      []
    )
  end

  defp admit_one(store, factory) do
    with {:ok, route} <- ModelRouter.resolve(factory.models, "workspace-maintainer"),
         :ok <- validate_route(route) do
      Enum.reduce_while(plan(store), {:ok, :no_candidate}, &scan_candidate(store, &1, route, &2))
    end
  end

  defp validate_route(%{model_class: "fast", reasoning_effort: "low"}), do: :ok
  defp validate_route(_route), do: {:error, :maintenance_requires_fast_low_route}

  defp scan_candidate(store, candidate, route, _acc) do
    case admit_candidate(store, candidate, route) do
      {:ok, %{} = record} -> {:halt, {:ok, record}}
      {:ok, :skipped} -> {:cont, {:ok, :no_candidate}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp admit_candidate(_store, %{eligible: false}, _route), do: {:ok, :skipped}

  defp admit_candidate(store, candidate, route) do
    digest = digest(candidate.binding)
    existing = Store.one!(store, "SELECT * FROM native_workspace_maintenance WHERE run_id = ?", [candidate.run_id])

    cond do
      existing && existing["binding_sha256"] == digest ->
        {:ok, :skipped}

      existing && existing["phase"] != "AVAILABLE" ->
        {:ok, :skipped}

      true ->
        enqueue_probe(store, candidate, existing, digest, route)
    end
  end

  defp enqueue_probe(store, candidate, existing, digest, route) do
    case NativeWorktreeProbe.enqueue(store, candidate.run_id, route) do
      {:error, :request_key_conflict} -> skip_conflicting_probe(store, candidate, existing, digest)
      {:error, _reason} = error -> error
      {:ok, request} -> persist_probe(store, candidate, existing, digest, request)
    end
  end

  defp persist_probe(store, candidate, existing, digest, request) do
    now = timestamp()
    generation = if existing, do: existing["generation"] + 1, else: 1

    Store.query!(
      store,
      """
      INSERT INTO native_workspace_maintenance(run_id, generation, phase, binding_json, binding_sha256, request_key, checked_at, updated_at)
      VALUES (?, ?, 'PROBING', ?, ?, ?, ?, ?)
      ON CONFLICT(run_id) DO UPDATE SET generation = excluded.generation, phase = excluded.phase,
        binding_json = excluded.binding_json, binding_sha256 = excluded.binding_sha256,
        request_key = excluded.request_key, attachment_identity = NULL, last_error = NULL,
        checked_at = excluded.checked_at, updated_at = excluded.updated_at
      """,
      [candidate.run_id, generation, Jason.encode!(candidate.binding), digest, request["request_key"], now, now]
    )

    {:ok, Store.one!(store, "SELECT * FROM native_workspace_maintenance WHERE run_id = ?", [candidate.run_id])}
  end

  defp skip_conflicting_probe(store, candidate, existing, digest) do
    now = timestamp()
    generation = if existing, do: existing["generation"] + 1, else: 1

    Store.query!(
      store,
      """
      INSERT INTO native_workspace_maintenance(run_id, generation, phase, binding_json, binding_sha256, last_error, checked_at, updated_at)
      VALUES (?, ?, 'AVAILABLE', ?, ?, 'existing_probe_route_conflict_unverified', ?, ?)
      ON CONFLICT(run_id) DO UPDATE SET generation = excluded.generation, phase = 'AVAILABLE',
        binding_json = excluded.binding_json, binding_sha256 = excluded.binding_sha256,
        request_key = NULL, attachment_identity = NULL, last_error = excluded.last_error,
        checked_at = excluded.checked_at, updated_at = excluded.updated_at
      """,
      [candidate.run_id, generation, Jason.encode!(candidate.binding), digest, now, now]
    )

    {:ok, :skipped}
  end

  defp reconcile_record(store, %{"phase" => phase} = record) when phase in ~w(PROBING RECONCILE_REQUIRED) do
    case DesktopRequest.get(store, record["request_key"]) do
      {:ok, %{"status" => "SUCCEEDED"} = request} ->
        consume_probe(store, record, request)

      {:ok, %{"status" => status}} when status in ~w(FAILED RECONCILE_REQUIRED) ->
        update(store, record, "RECONCILE_REQUIRED", "probe_requires_reconciliation", nil)

      {:ok, _request} ->
        {:ok, :waiting}

      {:error, _reason} ->
        update(store, record, "RECONCILE_REQUIRED", "probe_request_missing", nil)
    end
  end

  defp reconcile_record(_store, _record), do: {:ok, :reconciliation_required}

  defp consume_probe(store, record, request) do
    with {:ok, run} <- RunLedger.get(store, record["run_id"]),
         {:ok, binding} <- candidate_binding(store, run, false),
         true <- digest(binding) == record["binding_sha256"],
         true <- DesktopRequest.payload_intact?(request),
         {:ok, "NATIVE_WORKTREE_PROBE"} <- NativeWorktreeProbe.operation(request),
         %{} <- Store.one!(store, "SELECT id FROM events WHERE event_type = 'NATIVE_MAINTENANCE_TARGET_EVIDENCE' AND json_extract(payload_json, '$.request_key') = ?", [record["request_key"]]),
         {:ok, %{"result" => %{"status" => status} = receipt}} <- Jason.decode(request["output_json"]),
         true <- receipt["run_id"] == run["run_id"] and receipt["candidate_sha"] == run["candidate_sha"] do
      case status do
        "UNAVAILABLE" ->
          update(store, record, "AVAILABLE", "managed_attachment_unavailable", nil)

        "AMBIGUOUS" ->
          update(store, record, "AVAILABLE", "managed_attachment_ambiguous", nil)

        "SUPPORTED" ->
          # A supported probe is not permission to archive, nor proof that restoration works.
          update(store, record, "AVAILABLE", "archive_restore_capability_not_proven", receipt["artifact_identity_key"])

        _other ->
          update(store, record, "RECONCILE_REQUIRED", "invalid_probe_receipt", nil)
      end
    else
      _other -> update(store, record, "RECONCILE_REQUIRED", "probe_binding_or_evidence_changed", nil)
    end
  end

  defp candidate_binding(store, run, require_idle \\ true) do
    with :ok <- require_legacy_issue(store, run),
         {:ok, writer} <- TaskLedger.get(store, run["run_id"] <> ":feature-writer"),
         true <- writer["status"] in ~w(COMPLETE CONSUMED) or {:error, :writer_not_terminal},
         true <- (writer["workspace"] == run["worktree"] and writer["workspace_sha"] == run["candidate_sha"]) or {:error, :writer_binding_stale},
         true <-
           Enum.all?([run["worktree"], run["candidate_sha"], run["branch"], writer["thread_id"], writer["turn_id"], writer["codex_project_id"]], &(is_binary(&1) and &1 != "")) or
             {:error, :writer_identity_incomplete},
         true <- not require_idle or not active?(store, run["run_id"]) or {:error, :run_has_active_work},
         %{} = creation <- creation(store, writer) do
      {:ok,
       Map.take(run, ~w(run_id repo_path worktree branch candidate_sha))
       |> Map.merge(Map.take(writer, ~w(task_key thread_id turn_id codex_project_id)))
       |> Map.put("creation_request", creation["request_key"])}
    else
      nil -> {:error, :native_creation_provenance_missing}
      {:error, _reason} = error -> error
    end
  end

  defp require_legacy_issue(store, run) do
    if run["execution_mode"] in [nil, "LEGACY"] and not v1_issue_owned?(store, run["issue_key"]),
      do: :ok,
      else: {:error, :run_quarantined}
  end

  defp creation(store, writer) do
    Store.one!(
      store,
      """
      SELECT request_key FROM desktop_requests
      WHERE target_kind = 'TASK' AND target_key = ? AND action = 'CREATE' AND status = 'SUCCEEDED'
        AND thread_id = ? AND verified_project_id = ? AND verified_cwd = ?
        AND json_extract(metadata_json, '$.workspace_mode') = 'CODEX_NATIVE'
      LIMIT 1
      """,
      [writer["task_key"], writer["thread_id"], writer["codex_project_id"], writer["workspace"]]
    )
  end

  defp active?(store, run_id) do
    tasks = rows(store, "SELECT status FROM factory_tasks WHERE run_id = ?", [run_id])
    requests = rows(store, "SELECT request_key, status FROM desktop_requests WHERE target_kind = 'TASK' AND target_key IN (SELECT task_key FROM factory_tasks WHERE run_id = ?)", [run_id])
    notes = Store.one!(store, "SELECT feedback_key FROM mr_feedback_notes WHERE run_id = ? AND status IN ('PENDING', 'CLAIMED', 'CHANGE_REQUEST', 'REWORKING', 'RECONCILE_REQUIRED') LIMIT 1", [run_id])
    Enum.any?(tasks, &(&1["status"] in @active_tasks)) or Enum.any?(requests, &(&1["status"] in @unresolved)) or notes != nil
  end

  defp update(store, record, phase, reason, identity) do
    now = timestamp()

    Store.query!(store, "UPDATE native_workspace_maintenance SET phase = ?, last_error = ?, attachment_identity = ?, checked_at = ?, updated_at = ? WHERE run_id = ? AND generation = ?", [
      phase,
      reason,
      identity,
      now,
      now,
      record["run_id"],
      record["generation"]
    ])

    {:ok, %{phase: phase, reason: reason}}
  end

  defp rows(store, sql, args) do
    result = Store.query!(store, sql, args)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp digest(binding), do: :crypto.hash(:sha256, Jason.encode!(binding)) |> Base.encode16(case: :lower)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
