defmodule SymphonyElixir.Factory.MrFeedbackRework do
  @moduledoc """
  Reopens a review-ready delivery on its existing writer for one verified MR batch.

  External Jira, MR, note, and workspace evidence is checked before the ledger
  transition. The transaction binds the exact source SHA and all feedback keys.
  """

  alias SymphonyElixir.Factory.{MrFeedback, NativeWorkspaceMaintenance, RunLedger, Store}

  @doc "Returns the oldest unhandled source-change batch for one review-ready run."
  @spec pending_batch(Store.connection(), String.t()) :: [map()]
  def pending_batch(store, controller_scope) when is_binary(controller_scope) do
    case Store.one!(store, pending_batch_sql(), [controller_scope, controller_scope]) do
      nil ->
        []

      %{"run_id" => run_id} ->
        result = Store.query!(store, pending_batch_for_run_sql(), [run_id, controller_scope, controller_scope])
        Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    end
  end

  @doc "Identifies a non-imperative note that must receive a conversational reply."
  @spec ambiguous_receipt([map()], [map()]) :: map() | nil
  def ambiguous_receipt(receipts, discussions) do
    Enum.find(receipts, fn receipt ->
      discussion = Enum.find(discussions, &(&1["id"] == receipt["discussion_id"]))
      note = if is_map(discussion), do: Enum.find(discussion["notes"], &(&1["id"] == receipt["note_id"]))

      is_map(note) and not edit_intent?(note["body"], discussion["notes"], note["id"])
    end)
  end

  @doc "Atomically admits one verified set of source-change notes for review rework."
  @spec admit(Store.connection(), map(), [map()], map()) :: {:ok, String.t()} | {:error, atom()}
  def admit(store, run, receipts, evidence) when is_list(receipts) and receipts != [] do
    %{
      route: route,
      jira: jira,
      mr: mr,
      discussions: discussions,
      verified_writer_sha: verified_writer_sha,
      allowed_authors: allowed_authors,
      bot_id: bot_id
    } = evidence

    controller_scope = Map.get(evidence, :controller_scope)

    with true <- (run["execution_mode"] in [nil, "LEGACY"] and not v1_issue_owned?(store, run["issue_key"])) or {:error, :run_quarantined},
         true <- (run["kind"] == "DELIVERY" and run["state"] == "READY_FOR_REVIEW") or {:error, :delivery_not_review_ready},
         true <- run["candidate_sha"] == verified_writer_sha or {:error, :review_writer_head_mismatch},
         :ok <- MrFeedback.eligible?(run, route, jira, mr),
         {:ok, notes} <- verified_notes(run, receipts, route, jira, mr, discussions, allowed_authors, bot_id) do
      batch_key = batch_key(receipts, verified_writer_sha)
      persist_admission(store, run, receipts, notes, batch_key, controller_scope)
    end
  end

  @doc "After exact push and MR readback, requeues the batch for thread replies."
  @spec complete_push(Store.connection(), String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def complete_push(store, run_id, batch_key, candidate_sha)
      when is_binary(run_id) and is_binary(batch_key) and is_binary(candidate_sha) do
    Store.transaction!(store, fn transaction ->
      run = Store.one!(transaction, "SELECT state, candidate_sha, review_feedback_json, execution_mode, issue_key FROM runs WHERE run_id = ?", [run_id])

      receipts =
        Store.query!(transaction, "SELECT feedback_key FROM mr_feedback_notes WHERE run_id = ? AND review_batch_key = ? AND status = 'REWORKING' ORDER BY created_at, feedback_key", [run_id, batch_key])

      with %{"state" => "REVIEW_PUSHING", "candidate_sha" => ^candidate_sha, "review_feedback_json" => json, "execution_mode" => mode, "issue_key" => issue_key} <- run,
           true <- mode in [nil, "LEGACY"] and not v1_issue_owned?(transaction, issue_key),
           {:ok, notes} when is_list(notes) <- Jason.decode(json),
           keys <- Enum.map(notes, & &1["feedback_key"]),
           true <- keys != [] and Enum.sort(keys) == Enum.sort(Enum.map(receipts.rows, &hd/1)) do
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        {:ok, _updated_run} = RunLedger.update(transaction, run_id, %{state: "READY_FOR_REVIEW"})

        Store.query!(
          transaction,
          "UPDATE mr_feedback_notes SET status = 'PENDING', reply_phase = 1, request_key = NULL, controller_previous_turn_id = NULL, reply_id = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND review_batch_key = ? AND status = 'REWORKING'",
          [now, run_id, batch_key]
        )

        :ok
      else
        _other -> {:error, :review_push_binding_changed}
      end
    end)
  end

  @doc "Stops unsafe review rework while retaining its local candidate for inspection."
  @spec quarantine(Store.connection(), String.t(), String.t(), atom()) :: :ok | {:error, atom()}
  def quarantine(store, run_id, batch_key, reason)
      when is_binary(run_id) and is_binary(batch_key) and is_atom(reason) do
    Store.transaction!(store, fn transaction ->
      run = Store.one!(transaction, "SELECT state, execution_mode, issue_key FROM runs WHERE run_id = ?", [run_id])

      if is_map(run) and run["state"] == "REVIEW_PUSHING" and run["execution_mode"] in [nil, "LEGACY"] and
           not v1_issue_owned?(transaction, run["issue_key"]) do
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        code = Atom.to_string(reason)

        {:ok, _updated_run} = RunLedger.update(transaction, run_id, %{state: "FAILED", failure_code: code, last_error: code})

        Store.query!(
          transaction,
          "UPDATE mr_feedback_notes SET status = 'RECONCILE_REQUIRED', last_error = ?, updated_at = ? WHERE run_id = ? AND review_batch_key = ? AND status = 'REWORKING'",
          [code, now, run_id, batch_key]
        )

        :ok
      else
        {:error, :review_run_changed}
      end
    end)
  end

  defp pending_batch_sql do
    """
    SELECT note.run_id
    FROM mr_feedback_notes AS note
    LEFT JOIN desktop_requests AS request ON request.request_key = note.request_key
    JOIN runs AS run ON run.run_id = note.run_id
    WHERE COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY'
      AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
      AND ((note.status = 'CHANGE_REQUEST' AND request.target_key = ?)
      OR (note.status = 'RECONCILE_REQUIRED' AND note.reply_phase = 2
        AND instr(note.last_error, 'FOLLOWUP_TURN_REPLAYED') > 0
        AND request.status = 'RECONCILE_REQUIRED' AND request.failure_code = 'FOLLOWUP_TURN_REPLAYED'
        AND request.target_kind = 'CONTROLLER' AND request.action = 'FOLLOWUP' AND request.target_key = ?))
    ORDER BY note.created_at, note.feedback_key LIMIT 1
    """
  end

  defp pending_batch_for_run_sql do
    """
    SELECT note.*
    FROM mr_feedback_notes AS note
    LEFT JOIN desktop_requests AS request ON request.request_key = note.request_key
    JOIN runs AS run ON run.run_id = note.run_id
    WHERE note.run_id = ? AND COALESCE(run.execution_mode, 'LEGACY') = 'LEGACY'
      AND NOT EXISTS (SELECT 1 FROM runs AS supervisor WHERE supervisor.issue_key = run.issue_key AND supervisor.execution_mode = 'TICKET_SUPERVISOR_V1')
      AND ((note.status = 'CHANGE_REQUEST' AND request.target_key = ?)
      OR (note.status = 'RECONCILE_REQUIRED' AND note.reply_phase = 2
        AND instr(note.last_error, 'FOLLOWUP_TURN_REPLAYED') > 0
        AND request.status = 'RECONCILE_REQUIRED' AND request.failure_code = 'FOLLOWUP_TURN_REPLAYED'
        AND request.target_kind = 'CONTROLLER' AND request.action = 'FOLLOWUP' AND request.target_key = ?))
    ORDER BY note.created_at, note.feedback_key
    """
  end

  defp edit_intent?(body, discussion_notes, note_id) do
    MrFeedback.explicit_edit_request?(body) or
      MrFeedback.approves_proposed_edit?(body, discussion_notes, note_id)
  end

  @doc "Confirms every batched source note is unchanged before push or reply."
  @spec source_notes_match?(map(), [map()]) :: boolean()
  def source_notes_match?(run, discussions) when is_list(discussions) do
    case Jason.decode(run["review_feedback_json"] || "") do
      {:ok, notes} when is_list(notes) and notes != [] ->
        Enum.all?(notes, &source_note_matches?(&1, discussions))

      _other ->
        false
    end
  end

  defp source_note_matches?(stored, discussions) do
    discussion = Enum.find(discussions, &(&1["id"] == stored["discussion_id"]))
    note = if is_map(discussion), do: Enum.find(discussion["notes"], &(&1["id"] == stored["note_id"]))

    if is_map(note) and is_binary(note["body"]) do
      digest = :crypto.hash(:sha256, note["body"]) |> Base.encode16(case: :lower)

      note["updated_at"] == stored["note_updated_at"] and
        get_in(note, ["author", "id"]) == stored["author_id"] and digest == stored["body_sha256"]
    else
      false
    end
  end

  defp verified_notes(run, receipts, route, jira, mr, discussions, allowed_authors, bot_id) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, notes} ->
      case verified_note(run, receipt, route, jira, mr, discussions, allowed_authors, bot_id) do
        {:ok, verified} -> {:cont, {:ok, [verified | notes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      error -> error
    end
  end

  defp verified_note(run, receipt, route, jira, mr, discussions, allowed_authors, bot_id) do
    discussion = Enum.find(discussions, &(&1["id"] == receipt["discussion_id"]))
    note = if is_map(discussion), do: Enum.find(discussion["notes"], &(&1["id"] == receipt["note_id"]))

    with :ok <- matching_receipt?(run, receipt, note),
         {:ok, candidate} <- MrFeedback.candidate(run, route, jira, mr, discussion, note, allowed_authors, bot_id),
         true <- candidate.feedback_key == receipt["feedback_key"] or {:error, :feedback_source_changed},
         :ok <- replayed_reply_readback(receipt, discussion),
         true <- edit_intent?(note["body"], discussion["notes"], note["id"]) or {:error, :feedback_needs_clarification} do
      {:ok,
       %{
         "feedback_key" => receipt["feedback_key"],
         "discussion_id" => receipt["discussion_id"],
         "note_id" => receipt["note_id"],
         "note_updated_at" => receipt["note_updated_at"],
         "author_id" => receipt["author_id"],
         "body_sha256" => receipt["body_sha256"],
         "body" => note["body"]
       }}
    end
  end

  defp matching_receipt?(run, receipt, note) do
    cond do
      receipt["run_id"] != run["run_id"] or not eligible_receipt_status?(receipt) ->
        {:error, :feedback_batch_changed}

      not is_map(note) or note["updated_at"] != receipt["note_updated_at"] ->
        {:error, :feedback_source_changed}

      true ->
        :ok
    end
  end

  defp eligible_receipt_status?(%{"status" => "CHANGE_REQUEST"}), do: true

  defp eligible_receipt_status?(receipt) do
    recoverable_replayed_receipt?(receipt)
  end

  defp recoverable_replayed_receipt?(receipt) do
    receipt["status"] == "RECONCILE_REQUIRED" and receipt["reply_phase"] == 2 and
      is_binary(receipt["request_key"]) and is_binary(receipt["last_error"]) and
      String.contains?(receipt["last_error"], "FOLLOWUP_TURN_REPLAYED")
  end

  defp replayed_reply_readback(%{"status" => "RECONCILE_REQUIRED"} = receipt, discussion) do
    marker = "<!-- symphony-feedback:#{receipt["feedback_key"]} -->"

    replies =
      Enum.filter(discussion["notes"], &(is_binary(&1["body"]) and String.contains?(&1["body"], marker)))

    case replies do
      [%{"body" => body}] when is_binary(body) ->
        if String.starts_with?(body, "Symphony: "), do: :ok, else: {:error, :replayed_controller_reply_not_read_back}

      _other ->
        {:error, :replayed_controller_reply_not_read_back}
    end
  end

  defp replayed_reply_readback(_receipt, _discussion), do: :ok

  defp persist_admission(store, run, receipts, notes, batch_key, controller_scope) do
    case Exqlite.transaction(store, fn transaction ->
           persist_admission_transaction(transaction, run, receipts, notes, batch_key, controller_scope)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_admission_transaction(transaction, run, receipts, notes, batch_key, controller_scope) do
    current = Store.one!(transaction, "SELECT state, candidate_sha, worktree, execution_mode, issue_key FROM runs WHERE run_id = ?", [run["run_id"]])
    writer_key = "#{run["run_id"]}:feature-writer"
    writer = Store.one!(transaction, "SELECT status, workspace, workspace_sha, thread_id FROM factory_tasks WHERE task_key = ?", [writer_key])

    cond do
      current["execution_mode"] not in [nil, "LEGACY"] or v1_issue_owned?(transaction, current["issue_key"]) ->
        {:error, :run_quarantined}

      NativeWorkspaceMaintenance.ensure_available(transaction, run["run_id"]) != :ok ->
        {:error, :native_workspace_maintenance_reserved}

      Map.take(current, ["state", "candidate_sha", "worktree"]) != %{"state" => "READY_FOR_REVIEW", "candidate_sha" => run["candidate_sha"], "worktree" => run["worktree"]} ->
        {:error, :review_run_changed}

      not reusable_writer?(writer, run) ->
        {:error, :review_writer_unavailable}

      not receipts_current?(transaction, receipts, controller_scope) ->
        {:error, :feedback_batch_changed}

      true ->
        write_admission(transaction, run, receipts, notes, batch_key, writer_key, controller_scope)
    end
  end

  defp v1_issue_owned?(store, issue_key) do
    Store.one!(store, "SELECT run_id FROM runs WHERE issue_key = ? AND execution_mode = 'TICKET_SUPERVISOR_V1' LIMIT 1", [issue_key]) != nil
  end

  defp write_admission(transaction, run, receipts, notes, batch_key, writer_key, controller_scope) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    result =
      case retire_replayed_feedback_requests(transaction, receipts, now, controller_scope) do
        :ok -> mark_reworking(transaction, receipts, batch_key, now)
        {:error, _reason} = error -> error
      end

    case result do
      :ok ->
        {:ok, _updated_run} =
          RunLedger.update(transaction, run["run_id"], %{
            state: "REVIEW_WRITING",
            review_base_sha: run["candidate_sha"],
            review_feedback_json: Jason.encode!(notes),
            repair_findings_json: "[]"
          })

        Store.query!(
          transaction,
          "UPDATE factory_tasks SET status = 'RETRY_PENDING', output_json = NULL, failure_code = NULL, updated_at = ? WHERE task_key = ?",
          [now, writer_key]
        )

        {:ok, batch_key}

      {:error, reason} ->
        Exqlite.rollback(transaction, reason)
    end
  end

  defp retire_replayed_feedback_requests(transaction, receipts, now, controller_scope) do
    receipts
    |> Enum.filter(&recoverable_replayed_receipt?/1)
    |> Enum.map(& &1["request_key"])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn request_key, :ok ->
      Store.query!(
        transaction,
        "UPDATE desktop_requests SET status = 'FAILED', failure_code = 'FOLLOWUP_REPLY_READ_BACK_BEFORE_REWORK', updated_at = ? WHERE request_key = ? AND status = 'RECONCILE_REQUIRED' AND target_kind = 'CONTROLLER' AND target_key = ? AND action = 'FOLLOWUP' AND failure_code = 'FOLLOWUP_TURN_REPLAYED'",
        [now, request_key, controller_scope]
      )

      if Store.one!(transaction, "SELECT changes() AS count")["count"] == 1,
        do: {:cont, :ok},
        else: {:halt, {:error, :replayed_controller_request_changed}}
    end)
  end

  defp mark_reworking(transaction, receipts, batch_key, now) do
    Enum.reduce_while(receipts, :ok, fn receipt, :ok ->
      Store.query!(
        transaction,
        "UPDATE mr_feedback_notes SET status = 'REWORKING', review_batch_key = ?, updated_at = ? WHERE feedback_key = ? AND run_id = ? AND ((status = 'CHANGE_REQUEST') OR (status = 'RECONCILE_REQUIRED' AND reply_phase = 2 AND request_key = ? AND instr(last_error, 'FOLLOWUP_TURN_REPLAYED') > 0))",
        [batch_key, now, receipt["feedback_key"], receipt["run_id"], receipt["request_key"]]
      )

      if Store.one!(transaction, "SELECT changes() AS count")["count"] == 1,
        do: {:cont, :ok},
        else: {:halt, {:error, :feedback_batch_changed}}
    end)
  end

  defp reusable_writer?(%{"status" => status, "workspace" => path, "workspace_sha" => sha, "thread_id" => thread}, run)
       when status in ["COMPLETE", "CONSUMED"] do
    is_binary(thread) and thread != "" and path == run["worktree"] and sha == run["candidate_sha"]
  end

  defp reusable_writer?(_writer, _run), do: false

  defp receipts_current?(connection, receipts, controller_scope) do
    Enum.all?(receipts, fn receipt ->
      case Store.one!(connection, "SELECT status, run_id, body_sha256, reply_phase, request_key, last_error FROM mr_feedback_notes WHERE feedback_key = ?", [receipt["feedback_key"]]) do
        %{"status" => status, "run_id" => run_id, "body_sha256" => body_sha256} = current
        when status == "CHANGE_REQUEST" or status == "RECONCILE_REQUIRED" ->
          run_id == receipt["run_id"] and body_sha256 == receipt["body_sha256"] and
            current_receipt_binding?(connection, receipt, current, controller_scope)

        _other ->
          false
      end
    end)
  end

  defp current_receipt_binding?(_connection, %{"status" => "CHANGE_REQUEST"}, %{"status" => "CHANGE_REQUEST"}, _scope), do: true

  defp current_receipt_binding?(connection, receipt, %{"status" => "RECONCILE_REQUIRED"} = current, controller_scope) do
    recoverable_replayed_receipt?(Map.merge(receipt, current)) and
      current["request_key"] == receipt["request_key"] and
      case Store.one!(connection, "SELECT status, failure_code, target_kind, target_key, action FROM desktop_requests WHERE request_key = ?", [receipt["request_key"]]) do
        %{"status" => "RECONCILE_REQUIRED", "failure_code" => "FOLLOWUP_TURN_REPLAYED", "target_kind" => "CONTROLLER", "target_key" => ^controller_scope, "action" => "FOLLOWUP"} -> true
        _other -> false
      end
  end

  defp current_receipt_binding?(_connection, _receipt, _current, _scope), do: false

  defp batch_key(receipts, sha) do
    [sha | Enum.map(receipts, & &1["feedback_key"])]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
