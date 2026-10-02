defmodule SymphonyElixir.Factory.MrFeedbackLedger do
  @moduledoc """
  Records qualifying MR notes before any agent or controller handles them.

  A repeat poll of the same note body is a no-op. An edited body gets a new
  key, while the original receipt remains available for audit.
  """

  alias SymphonyElixir.Factory.Store

  @doc "Records an already-authorized note at most once."
  @spec record_candidate(Store.connection(), map()) :: {:ok, :recorded | :already_recorded} | {:error, atom()}
  def record_candidate(connection, candidate) when is_map(candidate) do
    with :ok <- valid_candidate?(candidate) do
      Store.transaction!(connection, &insert_candidate(&1, candidate))
    end
  end

  defp insert_candidate(transaction, candidate) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    supersede_changed_transaction(transaction, candidate, candidate.body_sha256, now)

    Store.query!(
      transaction,
      """
      INSERT OR IGNORE INTO mr_feedback_notes (
        feedback_key, run_id, project, mr_iid, discussion_id, note_id,
        note_updated_at, author_id, body_sha256, status, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)
      """,
      [
        candidate.feedback_key,
        candidate.run_id,
        candidate.project,
        candidate.mr_iid,
        candidate.discussion_id,
        candidate.note_id,
        candidate.note_updated_at,
        candidate.author_id,
        candidate.body_sha256,
        now,
        now
      ]
    )

    if Store.one!(transaction, "SELECT changes() AS count")["count"] == 1 do
      record_discovery_event(transaction, candidate, now)
      {:ok, :recorded}
    else
      {:ok, :already_recorded}
    end
  end

  @doc "Supersedes stale receipts when an observed note was edited, even if its mention was removed."
  @spec supersede_changed(Store.connection(), String.t(), pos_integer(), String.t(), pos_integer(), String.t()) ::
          :ok | {:error, :invalid_feedback_note}
  def supersede_changed(connection, project, mr_iid, discussion_id, note_id, body)
      when is_binary(project) and is_integer(mr_iid) and mr_iid > 0 and is_binary(discussion_id) and
             is_integer(note_id) and note_id > 0 and is_binary(body) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    identity = %{project: project, mr_iid: mr_iid, discussion_id: discussion_id, note_id: note_id}
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    Store.transaction!(connection, &supersede_changed_transaction(&1, identity, digest, now))
    :ok
  end

  def supersede_changed(_connection, _project, _mr_iid, _discussion_id, _note_id, _body),
    do: {:error, :invalid_feedback_note}

  defp supersede_changed_transaction(transaction, identity, current_digest, now) do
    Store.query!(
      transaction,
      """
      UPDATE mr_feedback_notes SET status = 'SUPERSEDED', updated_at = ?
      WHERE project = ? AND mr_iid = ? AND discussion_id = ? AND note_id = ?
        AND body_sha256 != ? AND status IN ('PENDING', 'CLAIMED')
      """,
      [now, identity.project, identity.mr_iid, identity.discussion_id, identity.note_id, current_digest]
    )
  end

  @doc "Terminalizes an unclaimed receipt invalidated by fresh source readback."
  @spec dismiss(Store.connection(), String.t(), atom()) :: :ok | {:error, atom()}
  def dismiss(connection, feedback_key, reason) when is_binary(feedback_key) and is_atom(reason) do
    Store.transaction!(connection, fn transaction ->
      Store.query!(
        transaction,
        "UPDATE mr_feedback_notes SET status = 'SUPERSEDED', last_error = ?, updated_at = ? WHERE feedback_key = ? AND status = 'PENDING'",
        [Atom.to_string(reason), DateTime.utc_now() |> DateTime.to_iso8601(), feedback_key]
      )

      if Store.one!(transaction, "SELECT changes() AS count")["count"] == 1,
        do: :ok,
        else: {:error, :feedback_not_pending}
    end)
  end

  defp record_discovery_event(transaction, candidate, now) do
    Store.query!(
      transaction,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [
        now,
        "MR_FEEDBACK_DISCOVERED",
        candidate.run_id,
        Jason.encode!(Map.take(candidate, [:project, :mr_iid, :discussion_id, :note_id, :body_sha256]))
      ]
    )
  end

  @doc "Lists pending feedback receipts without returning untrusted note bodies."
  @spec pending(Store.connection()) :: [map()]
  def pending(connection) do
    connection
    |> Store.query!("SELECT * FROM mr_feedback_notes WHERE status = 'PENDING' ORDER BY created_at, feedback_key")
    |> rows_as_maps()
  end

  @doc "Returns one claimed receipt first, then the oldest pending receipt."
  @spec next(Store.connection()) :: map() | nil
  def next(connection) do
    Store.one!(
      connection,
      "SELECT * FROM mr_feedback_notes WHERE status IN ('CLAIMED', 'PENDING') ORDER BY CASE status WHEN 'CLAIMED' THEN 0 ELSE 1 END, created_at, feedback_key LIMIT 1"
    )
  end

  @doc "Returns the in-flight batch or all pending notes for the oldest MR."
  @spec next_batch(Store.connection()) :: [map()]
  def next_batch(connection) do
    case next(connection) do
      nil ->
        []

      %{"status" => "CLAIMED", "request_key" => key} ->
        connection
        |> Store.query!("SELECT * FROM mr_feedback_notes WHERE status = 'CLAIMED' AND request_key = ? ORDER BY created_at, feedback_key", [key])
        |> rows_as_maps()

      %{"run_id" => run_id, "mr_iid" => mr_iid, "reply_phase" => phase} ->
        connection
        |> Store.query!(
          "SELECT * FROM mr_feedback_notes WHERE status = 'PENDING' AND run_id = ? AND mr_iid = ? AND reply_phase = ? ORDER BY created_at, feedback_key",
          [run_id, mr_iid, phase]
        )
        |> rows_as_maps()
    end
  end

  @doc "Atomically binds every note in one MR batch to one controller request."
  @spec claim_batch(Store.connection(), [map()], String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, atom()}
  def claim_batch(connection, receipts, request_key, previous_turn_id)
      when is_list(receipts) and receipts != [] and is_binary(request_key) do
    Store.transaction!(connection, &claim_batch_transaction(&1, receipts, request_key, previous_turn_id))
  end

  defp claim_batch_transaction(transaction, receipts, request_key, previous_turn_id) do
    keys = Enum.map(receipts, & &1["feedback_key"])
    current = next_batch(transaction)

    cond do
      Enum.map(current, & &1["feedback_key"]) != keys ->
        {:error, :feedback_batch_changed}

      Enum.all?(current, &(&1["status"] == "CLAIMED" and &1["request_key"] == request_key)) ->
        {:ok, current}

      Enum.any?(current, &(&1["status"] != "PENDING")) ->
        {:error, :feedback_claim_in_progress}

      true ->
        placeholders = Enum.map_join(keys, ", ", fn _ -> "?" end)

        Store.query!(
          transaction,
          "UPDATE mr_feedback_notes SET status = 'CLAIMED', request_key = ?, controller_previous_turn_id = ?, updated_at = ? WHERE feedback_key IN (#{placeholders}) AND status = 'PENDING'",
          [request_key, previous_turn_id, DateTime.utc_now() |> DateTime.to_iso8601() | keys]
        )

        {:ok, next_batch(transaction)}
    end
  end

  @doc "Binds one pending receipt to one stable Desktop request before sending."
  @spec claim(Store.connection(), String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def claim(connection, feedback_key, request_key, previous_turn_id)
      when is_binary(feedback_key) and is_binary(request_key) do
    Store.transaction!(connection, fn transaction ->
      receipt = Store.one!(transaction, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [feedback_key])

      cond do
        is_nil(receipt) ->
          {:error, :unknown_feedback}

        receipt["status"] == "CLAIMED" and receipt["request_key"] == request_key ->
          {:ok, receipt}

        receipt["status"] != "PENDING" ->
          {:error, :feedback_not_pending}

        Store.one!(transaction, "SELECT feedback_key FROM mr_feedback_notes WHERE status = 'CLAIMED' LIMIT 1") != nil ->
          {:error, :feedback_claim_in_progress}

        true ->
          Store.query!(
            transaction,
            "UPDATE mr_feedback_notes SET status = 'CLAIMED', request_key = ?, controller_previous_turn_id = ?, updated_at = ? WHERE feedback_key = ? AND status = 'PENDING'",
            [request_key, previous_turn_id, DateTime.utc_now() |> DateTime.to_iso8601(), feedback_key]
          )

          {:ok, Store.one!(transaction, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [feedback_key])}
      end
    end)
  end

  @doc "Records one read-backed reply or a no-write decision for the bound request."
  @spec finish(Store.connection(), String.t(), String.t(), String.t(), integer() | nil, String.t() | nil) ::
          :ok | {:error, atom()}
  def finish(connection, feedback_key, request_key, outcome, reply_id \\ nil, reason \\ nil)
      when outcome in ["COMPLETE", "CHANGE_REQUEST", "RECONCILE_REQUIRED"] do
    Store.transaction!(connection, fn transaction ->
      receipt = Store.one!(transaction, "SELECT * FROM mr_feedback_notes WHERE feedback_key = ?", [feedback_key])

      if is_map(receipt) and receipt["status"] == "CLAIMED" and receipt["request_key"] == request_key do
        Store.query!(
          transaction,
          "UPDATE mr_feedback_notes SET status = ?, reply_id = ?, last_error = ?, updated_at = ? WHERE feedback_key = ? AND status = 'CLAIMED'",
          [outcome, reply_id, reason, DateTime.utc_now() |> DateTime.to_iso8601(), feedback_key]
        )

        :ok
      else
        {:error, :feedback_claim_mismatch}
      end
    end)
  end

  @doc "Records every decision from one controller batch without partial completion."
  @spec finish_batch(Store.connection(), [map()], String.t(), [map()], map()) :: :ok | {:error, atom()}
  def finish_batch(connection, receipts, request_key, results, reply_ids)
      when is_list(receipts) and is_list(results) and is_binary(request_key) and is_map(reply_ids) do
    Store.transaction!(connection, &finish_batch_transaction(&1, receipts, request_key, results, reply_ids))
  end

  defp finish_batch_transaction(transaction, receipts, request_key, results, reply_ids) do
    if batch_claimed?(transaction, receipts, request_key) and
         Enum.map(receipts, & &1["feedback_key"]) == Enum.map(results, & &1["feedback_key"]) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      Enum.each(results, &finish_batch_decision(transaction, &1, request_key, reply_ids, now))
      :ok
    else
      {:error, :feedback_batch_claim_mismatch}
    end
  end

  defp finish_batch_decision(transaction, result, request_key, reply_ids, now) do
    key = result["feedback_key"]
    status = if result["status"] == "REPLIED", do: "COMPLETE", else: "CHANGE_REQUEST"
    reply_id = Map.get(reply_ids, key)

    Store.query!(
      transaction,
      "UPDATE mr_feedback_notes SET status = ?, reply_id = ?, last_error = ?, updated_at = ? WHERE feedback_key = ? AND status = 'CLAIMED' AND request_key = ?",
      [status, reply_id, result["reason"], now, key, request_key]
    )
  end

  @doc "Quarantines one uncertain controller batch without resending replies."
  @spec reconcile_batch(Store.connection(), [map()], String.t(), String.t()) :: :ok | {:error, atom()}
  def reconcile_batch(connection, receipts, request_key, reason)
      when is_list(receipts) and is_binary(request_key) and is_binary(reason) do
    Store.transaction!(connection, &reconcile_batch_transaction(&1, receipts, request_key, reason))
  end

  defp reconcile_batch_transaction(transaction, receipts, request_key, reason) do
    if batch_claimed?(transaction, receipts, request_key) do
      Enum.each(receipts, &reconcile_batch_receipt(transaction, &1, request_key, reason))
      :ok
    else
      {:error, :feedback_batch_claim_mismatch}
    end
  end

  defp reconcile_batch_receipt(transaction, receipt, request_key, reason) do
    Store.query!(
      transaction,
      "UPDATE mr_feedback_notes SET status = 'RECONCILE_REQUIRED', last_error = ?, updated_at = ? WHERE feedback_key = ? AND status = 'CLAIMED' AND request_key = ?",
      [reason, DateTime.utc_now() |> DateTime.to_iso8601(), receipt["feedback_key"], request_key]
    )
  end

  defp batch_claimed?(connection, receipts, request_key) do
    keys = Enum.map(receipts, & &1["feedback_key"])

    Enum.all?(keys, fn key ->
      case Store.one!(connection, "SELECT status, request_key FROM mr_feedback_notes WHERE feedback_key = ?", [key]) do
        %{"status" => "CLAIMED", "request_key" => ^request_key} -> true
        _other -> false
      end
    end)
  end

  @doc "Requeues a misclassified observation for a mandatory conversational reply."
  @spec requeue_clarification(Store.connection(), String.t()) :: :ok | {:error, atom()}
  def requeue_clarification(connection, feedback_key) when is_binary(feedback_key) do
    Store.transaction!(connection, fn transaction ->
      Store.query!(
        transaction,
        "UPDATE mr_feedback_notes SET status = 'PENDING', reply_phase = 2, request_key = NULL, controller_previous_turn_id = NULL, last_error = NULL, updated_at = ? WHERE feedback_key = ? AND status = 'CHANGE_REQUEST'",
        [DateTime.utc_now() |> DateTime.to_iso8601(), feedback_key]
      )

      if Store.one!(transaction, "SELECT changes() AS count")["count"] == 1,
        do: :ok,
        else: {:error, :feedback_not_change_request}
    end)
  end

  defp rows_as_maps(%{columns: columns, rows: rows}) do
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp valid_candidate?(candidate) do
    required_strings = [:feedback_key, :run_id, :project, :discussion_id, :note_updated_at, :body_sha256]

    if Enum.all?(required_strings, &(is_binary(candidate[&1]) and String.trim(candidate[&1]) != "")) and
         is_integer(candidate[:mr_iid]) and candidate[:mr_iid] > 0 and
         is_integer(candidate[:note_id]) and candidate[:note_id] > 0 and
         is_integer(candidate[:author_id]) and candidate[:author_id] > 0 do
      :ok
    else
      {:error, :invalid_feedback_candidate}
    end
  end
end
