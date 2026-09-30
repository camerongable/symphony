defmodule SymphonyElixir.Factory.ContractChat do
  @moduledoc """
  Tracks one bounded user conversation about a changed delivery contract.

  Jira remains the contract authority. Chat replies are untrusted input until a
  revised contract is written, read back, and independently reviewed.
  """

  alias SymphonyElixir.Factory.{Contract, RunLedger, Store, TaskLedger}

  @factory_comment_prefixes [
    "AI factory blocked:",
    "AI FACTORY SPEC INPUT REQUIRED",
    "AI FACTORY SPEC READY",
    "AI FACTORY AUTHORIZED",
    "AI FACTORY CONTRACT BEGIN",
    "<!-- AI FACTORY CONTRACT BEGIN"
  ]
  @rearmed_status_failure inspect({:jira_status_left_factory_scope, "In Dev"})
  @rearmed_dirty_failure ":worktree_dirty"
  @contract_rearm_marker "CONTRACT_REVISION_REARMED"

  @doc "Hashes Jira fields that can express a user contract revision."
  @spec source_sha256(map()) :: String.t()
  def source_sha256(snapshot) when is_map(snapshot) do
    comments =
      snapshot
      |> value("comments", [])
      |> List.wrap()
      |> Enum.map(&comment_text/1)
      |> Enum.map(&normalize_text/1)
      |> Enum.reject(&factory_comment?/1)
      |> Enum.sort()

    %{
      "key" => value(snapshot, "key"),
      "summary" => normalize_text(value(snapshot, "summary")),
      "description" => normalize_text(value(snapshot, "description")),
      "comments" => comments
    }
    |> Jason.encode!()
    |> digest()
  end

  @doc "Reports whether Jira user input differs from the failed run's last snapshot."
  @spec changed?(map(), map()) :: boolean()
  def changed?(%{"snapshot_json" => old_json}, current) when is_binary(old_json) do
    case Jason.decode(old_json) do
      {:ok, old} when is_map(old) -> source_sha256(old) != source_sha256(current)
      _other -> false
    end
  end

  def changed?(_run, _current), do: false

  @doc "Rearms the existing writer after a newer Jira contract is authorized."
  @spec rearm_delivery(Store.connection(), module(), map(), map(), Contract.bound_contract(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def rearm_delivery(connection, worktree, failed, snapshot, contract, manual_required) do
    task_key = "#{failed["run_id"]}:feature-writer"

    with {:ok, task} <- TaskLedger.get(connection, task_key),
         :ok <- validate_writer_workspace(worktree, failed, task) do
      Store.transaction!(connection, fn transaction ->
        rearm_delivery_transaction(transaction, failed, task_key, snapshot, contract, manual_required)
      end)
    end
  end

  defp rearm_delivery_transaction(transaction, failed, task_key, snapshot, contract, manual_required) do
    current = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [failed["run_id"]])
    {:ok, current_task} = TaskLedger.get(transaction, task_key)

    with :ok <- validate_rearm(transaction, current, current_task, snapshot, contract),
         timestamp <- now() do
      Store.query!(
        transaction,
        """
        UPDATE runs SET state = 'WRITING', spec_revision = ?, contract_sha256 = ?,
          contract_markdown = ?, manual_validation_required = ?, snapshot_json = ?,
          attempt = attempt + 1, failure_code = NULL, last_error = NULL,
          repair_findings_json = '[]', updated_at = ? WHERE run_id = ? AND state = 'FAILED'
        """,
        [contract.revision, contract.sha256, contract.markdown, if(manual_required, do: 1, else: 0), Jason.encode!(snapshot), timestamp, current["run_id"]]
      )

      Store.query!(
        transaction,
        "UPDATE factory_tasks SET status = 'CONSUMED', failure_code = ?, updated_at = ? WHERE task_key = ? AND status IN ('COMPLETE', 'CONSUMED')",
        [@contract_rearm_marker, timestamp, task_key]
      )

      Store.query!(
        transaction,
        "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
        [
          timestamp,
          "DELIVERY_CONTRACT_REARMED",
          current["run_id"],
          Jason.encode!(%{old_contract_sha256: current["contract_sha256"], new_contract_sha256: contract.sha256, prior_failure: current["failure_code"], writer_task_key: task_key})
        ]
      )

      RunLedger.get(transaction, current["run_id"])
    end
  end

  @doc "Identifies an interrupted contract rearm that can reuse its original writer."
  @spec recoverable_rearm_interruption?(map()) :: boolean()
  def recoverable_rearm_interruption?(%{
        "kind" => "DELIVERY",
        "state" => "CANCELLED",
        "failure_code" => @rearmed_status_failure
      }),
      do: true

  def recoverable_rearm_interruption?(%{
        "kind" => "DELIVERY",
        "state" => "FAILED",
        "failure_code" => @rearmed_dirty_failure
      }),
      do: true

  def recoverable_rearm_interruption?(_run), do: false

  @doc "Proves that a factory-blocked interruption still belongs to the same authorized writer."
  @spec verify_interrupted_rearm(Store.connection(), module(), map(), map()) :: :ok | {:error, term()}
  def verify_interrupted_rearm(connection, worktree, interrupted, snapshot) do
    task_key = "#{interrupted["run_id"]}:feature-writer"

    with true <- recoverable_rearm_interruption?(interrupted) or {:error, :interrupted_rearm_unproven},
         {:ok, contract} <- Contract.authorized_from_snapshot(snapshot, interrupted["issue_key"]),
         {:ok, task} <- TaskLedger.get(connection, task_key),
         :ok <- validate_writer_workspace(worktree, interrupted, task),
         :ok <- validate_interrupted_rearm(connection, interrupted, task, snapshot, contract, true) do
      :ok
    else
      _other -> {:error, :interrupted_rearm_unproven}
    end
  end

  @doc "Resumes an interrupted contract rearm with its original writer, branch, and commit."
  @spec resume_interrupted_rearm(Store.connection(), module(), map(), map()) :: {:ok, map()} | {:error, term()}
  def resume_interrupted_rearm(connection, worktree, interrupted, snapshot) do
    task_key = "#{interrupted["run_id"]}:feature-writer"

    with true <- recoverable_rearm_interruption?(interrupted) or {:error, :interrupted_rearm_unproven},
         {:ok, contract} <- Contract.authorized_from_snapshot(snapshot, interrupted["issue_key"]),
         {:ok, task} <- TaskLedger.get(connection, task_key),
         :ok <- validate_writer_workspace(worktree, interrupted, task) do
      Store.transaction!(connection, fn transaction ->
        resume_interrupted_rearm_transaction(transaction, interrupted, task_key, snapshot, contract)
      end)
    else
      _other -> {:error, :interrupted_rearm_unproven}
    end
  end

  defp resume_interrupted_rearm_transaction(transaction, interrupted, task_key, snapshot, contract) do
    run = Store.one!(transaction, "SELECT * FROM runs WHERE run_id = ?", [interrupted["run_id"]])
    task = Store.one!(transaction, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key])

    with :ok <- validate_interrupted_rearm(transaction, run, task, snapshot, contract) do
      timestamp = now()

      Store.query!(
        transaction,
        "UPDATE runs SET state = 'WRITING', snapshot_json = ?, failure_code = NULL, last_error = NULL, updated_at = ? WHERE run_id = ? AND state IN ('CANCELLED', 'FAILED')",
        [Jason.encode!(snapshot), timestamp, run["run_id"]]
      )

      Store.query!(
        transaction,
        "UPDATE factory_tasks SET failure_code = ?, updated_at = ? WHERE task_key = ? AND status = 'CONSUMED'",
        [@contract_rearm_marker, timestamp, task_key]
      )

      Store.query!(
        transaction,
        "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
        [timestamp, "DELIVERY_REARM_INTERRUPTION_RECOVERED", run["run_id"], Jason.encode!(%{task_key: task_key})]
      )

      RunLedger.get(transaction, run["run_id"])
    end
  end

  defp validate_interrupted_rearm(connection, run, task, snapshot, contract, allow_factory_blocked \\ false) do
    latest_delivery =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? AND kind = 'DELIVERY' ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [run["issue_key"]]
      )

    active =
      Store.one!(
        connection,
        "SELECT run_id FROM runs WHERE issue_key = ? AND run_id != ? AND state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') LIMIT 1",
        [run["issue_key"], run["run_id"]]
      )

    unresolved =
      Store.one!(
        connection,
        "SELECT COUNT(*) AS count FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')",
        [task["task_key"]]
      )

    rearm =
      Store.one!(
        connection,
        "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'DELIVERY_CONTRACT_REARMED' ORDER BY id DESC LIMIT 1",
        [run["run_id"]]
      )

    valid? =
      interrupted_rearm_run_valid?(run, latest_delivery, active, unresolved, rearm) and
        interrupted_rearm_task_valid?(run, task) and
        interrupted_rearm_contract_valid?(run, snapshot, contract, allow_factory_blocked)

    if valid?, do: :ok, else: {:error, :interrupted_rearm_unproven}
  end

  defp interrupted_rearm_run_valid?(run, latest_delivery, active, unresolved, rearm) do
    recoverable_rearm_interruption?(run) and rearm_event_matches?(rearm, run["contract_sha256"]) and
      run["runtime"] == "codex-desktop-broker" and is_map(latest_delivery) and
      latest_delivery["run_id"] == run["run_id"] and is_nil(active) and unresolved["count"] == 0
  end

  defp rearm_event_matches?(%{"payload_json" => json}, digest) do
    case Jason.decode(json) do
      {:ok, %{"new_contract_sha256" => ^digest}} -> true
      _other -> false
    end
  end

  defp rearm_event_matches?(_rearm, _digest), do: false

  defp interrupted_rearm_task_valid?(run, task) do
    task["run_id"] == run["run_id"] and TaskLedger.source_writer?(task) and
      task["status"] in ["COMPLETE", "CONSUMED"] and present?(run["candidate_sha"]) and present?(run["worktree"])
  end

  defp interrupted_rearm_contract_valid?(run, snapshot, contract, allow_factory_blocked) do
    run["spec_revision"] == contract.revision and run["contract_sha256"] == contract.sha256 and
      run["contract_markdown"] == contract.markdown and Contract.authorized?(snapshot, contract) and
      interrupted_rearm_snapshot_valid?(snapshot, allow_factory_blocked)
  end

  defp interrupted_rearm_snapshot_valid?(snapshot, allow_factory_blocked) do
    String.upcase(to_string(snapshot["status"])) == "IN DEV" and
      "ai-ready" in (snapshot["labels"] || []) and
      (allow_factory_blocked or "ai-blocked" not in (snapshot["labels"] || []))
  end

  defp validate_writer_workspace(worktree, %{"runtime" => "codex-desktop-broker"} = run, task) do
    with true <-
           (TaskLedger.source_writer?(task) and task["run_id"] == run["run_id"]) or
             {:error, :contract_writer_task_mismatch},
         true <-
           (present?(run["worktree"]) and present?(run["candidate_sha"]) and
              task["workspace"] == run["worktree"]) or
             {:error, :contract_writer_workspace_missing},
         {:ok, %{path: path, sha: sha}} <-
           worktree.validate_native(
             %{"path" => run["repo_path"]},
             run["worktree"],
             expected_branch: run["branch"],
             expected_sha: run["candidate_sha"],
             clean: false,
             detached: false
           ),
         true <-
           (path == run["worktree"] and sha == run["candidate_sha"]) or
             {:error, :contract_writer_workspace_changed} do
      :ok
    end
  end

  defp validate_writer_workspace(_worktree, run, task) do
    if TaskLedger.source_writer?(task) and task["run_id"] == run["run_id"],
      do: :ok,
      else: {:error, :contract_writer_task_mismatch}
  end

  defp validate_rearm(connection, %{"kind" => "DELIVERY", "state" => "FAILED"} = run, task, snapshot, contract) do
    unresolved =
      Store.one!(
        connection,
        """
        SELECT COUNT(*) AS count FROM desktop_requests
        WHERE target_kind = 'TASK' AND target_key = ?
          AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED')
        """,
        [task["task_key"]]
      )

    active =
      Store.one!(
        connection,
        """
        SELECT run_id FROM runs WHERE issue_key = ? AND run_id != ?
          AND state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') LIMIT 1
        """,
        [run["issue_key"], run["run_id"]]
      )

    cond do
      contract.issue_key != run["issue_key"] or contract.revision <= run["spec_revision"] or
          contract.sha256 == run["contract_sha256"] ->
        {:error, :contract_revision_not_newer}

      not Contract.authorized?(snapshot, contract) ->
        {:error, :contract_revision_not_authorized}

      task["status"] not in ["COMPLETE", "CONSUMED"] ->
        {:error, :contract_writer_task_not_terminal}

      unresolved["count"] != 0 or not is_nil(active) ->
        {:error, :contract_writer_still_active}

      true ->
        :ok
    end
  end

  defp validate_rearm(_connection, _run, _task, _snapshot, _contract), do: {:error, :contract_delivery_not_failed}

  @doc "Records the question bound to an exact task turn and Jira source digest."
  @spec wait(Store.connection(), map(), map(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def wait(connection, run, task, questions) when is_list(questions) do
    Store.transaction!(connection, fn transaction ->
      wait_transaction(transaction, run, task, questions)
    end)
  end

  defp wait_transaction(transaction, run, task, questions) do
    with true <- run["state"] == "CONTRACT_DISCUSSING" or {:error, :contract_chat_run_changed},
         true <-
           (task["run_id"] == run["run_id"] and task["status"] == "COMPLETE") or
             {:error, :contract_chat_task_changed},
         true <-
           (present?(task["thread_id"]) and present?(task["turn_id"])) or
             {:error, :contract_chat_task_unbound},
         true <-
           (questions != [] and Enum.all?(questions, &present?/1)) or
             {:error, :contract_chat_question_missing},
         {:ok, snapshot} <- Jason.decode(run["snapshot_json"]),
         source_sha <- source_sha256(snapshot),
         question_sha <- Contract.questions_digest(questions),
         timestamp <- now() do
      Store.query!(
        transaction,
        """
        INSERT INTO contract_chats(run_id, task_key, status, source_sha256, question_turn_id,
          question_sha256, created_at, updated_at)
        VALUES (?, ?, 'WAITING', ?, ?, ?, ?, ?)
        ON CONFLICT(run_id) DO UPDATE SET
          status = 'WAITING', source_sha256 = excluded.source_sha256,
          question_turn_id = excluded.question_turn_id, question_sha256 = excluded.question_sha256,
          user_turn_id = NULL, user_message_id = NULL, user_text = NULL,
          updated_at = excluded.updated_at
        """,
        [run["run_id"], task["task_key"], source_sha, task["turn_id"], question_sha, timestamp, timestamp]
      )

      with {:ok, _task} <- TaskLedger.update(transaction, task["task_key"], %{status: "WAITING_FOR_USER"}),
           {:ok, _run} <-
             RunLedger.update(transaction, run["run_id"], %{
               state: "AWAITING_CONTRACT_INPUT",
               repair_findings_json: Jason.encode!(questions)
             }) do
        {:ok, %{task_key: task["task_key"], question_sha256: question_sha}}
      end
    end
  end

  @doc "Lists only completed contract questions whose bound chats await a user reply."
  @spec waiting(Store.connection()) :: [map()]
  def waiting(connection) do
    result =
      Store.query!(
        connection,
        """
        SELECT c.run_id, c.task_key, r.issue_key, t.thread_id, t.codex_project_id,
               t.model, t.reasoning_effort, c.question_turn_id, c.question_sha256
        FROM contract_chats c
        JOIN runs r ON r.run_id = c.run_id
        JOIN factory_tasks t ON t.task_key = c.task_key
        WHERE c.status = 'WAITING' AND r.state = 'AWAITING_CONTRACT_INPUT'
          AND t.status = 'WAITING_FOR_USER' AND t.thread_id IS NOT NULL
        ORDER BY c.updated_at ASC
        """,
        []
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  @doc "Checks that the question still describes the current Jira input."
  @spec question_source_current?(Store.connection(), String.t(), map()) :: boolean()
  def question_source_current?(connection, run_id, snapshot) do
    case Store.one!(connection, "SELECT source_sha256, status FROM contract_chats WHERE run_id = ?", [run_id]) do
      %{"status" => "WAITING", "source_sha256" => digest} -> digest == source_sha256(snapshot)
      _other -> false
    end
  end

  @doc "Reopens the same contract chat when Jira changes after its question."
  @spec invalidate_question(Store.connection(), String.t()) :: :ok | {:error, term()}
  def invalidate_question(connection, run_id) do
    Store.transaction!(connection, fn transaction ->
      chat = Store.one!(transaction, "SELECT * FROM contract_chats WHERE run_id = ?", [run_id])

      with %{"status" => "WAITING"} <- chat,
           {:ok, %{"state" => "AWAITING_CONTRACT_INPUT"}} <- RunLedger.get(transaction, run_id),
           {:ok, _task} <-
             TaskLedger.update(transaction, chat["task_key"], %{
               status: "RETRY_PENDING",
               output_json: nil
             }),
           {:ok, _run} <- RunLedger.update(transaction, run_id, %{state: "CONTRACT_DISCUSSING"}) do
        Store.query!(
          transaction,
          "UPDATE contract_chats SET status = 'CONSUMED', updated_at = ? WHERE run_id = ? AND status = 'WAITING'",
          [now(), run_id]
        )

        :ok
      else
        _other -> {:error, :contract_chat_question_changed}
      end
    end)
  end

  @doc "Records one read-backed user turn without sending or repeating a Codex request."
  @spec record_user_reply(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_user_reply(connection, task_key, attrs) when is_binary(task_key) and is_map(attrs) do
    attrs = stringify_keys(attrs)

    Store.transaction!(connection, fn transaction ->
      record_user_reply_transaction(transaction, task_key, attrs)
    end)
  end

  defp record_user_reply_transaction(transaction, task_key, attrs) do
    chat = Store.one!(transaction, "SELECT * FROM contract_chats WHERE task_key = ?", [task_key])

    with %{} <- chat,
         {:ok, run} <- RunLedger.get(transaction, chat["run_id"]),
         {:ok, task} <- TaskLedger.get(transaction, task_key),
         {:ok, reply_evidence} <- validate_reply_binding(chat, task, attrs) do
      if chat["status"] in ["ANSWERED", "CONSUMED"] do
        already_recorded_reply(chat, run, task_key, attrs, reply_evidence)
      else
        record_new_reply(transaction, chat, run, task, attrs, reply_evidence)
      end
    else
      nil -> {:error, :contract_chat_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp already_recorded_reply(chat, run, task_key, attrs, reply_evidence) do
    if chat["user_turn_id"] == attrs["user_turn_id"] and
         chat["user_message_id"] == attrs["user_message_id"] and
         chat["user_text"] == attrs["text"] and
         chat["reply_evidence_json"] == Jason.encode!(reply_evidence) do
      {:ok, %{result: "CONTRACT_CHAT_REPLY_ALREADY_RECORDED", task_key: task_key, run_id: run["run_id"]}}
    else
      {:error, :contract_chat_reply_conflict}
    end
  end

  defp record_new_reply(transaction, chat, run, task, attrs, reply_evidence) do
    task_key = task["task_key"]

    with :ok <- validate_reply(chat, run, task),
         {:ok, _task} <-
           TaskLedger.update(transaction, task_key, %{
             status: "RETRY_PENDING",
             turn_id: attrs["user_turn_id"]
           }),
         {:ok, _run} <-
           RunLedger.update(transaction, run["run_id"], %{
             state: "CONTRACT_DISCUSSING",
             last_input_marker: attrs["user_message_id"]
           }) do
      Store.query!(
        transaction,
        """
        UPDATE contract_chats SET status = 'ANSWERED', user_turn_id = ?, user_message_id = ?,
          user_text = ?, reply_evidence_json = ?, updated_at = ?
        WHERE task_key = ? AND status = 'WAITING'
        """,
        [
          attrs["user_turn_id"],
          attrs["user_message_id"],
          attrs["text"],
          Jason.encode!(reply_evidence),
          now(),
          task_key
        ]
      )

      Store.query!(
        transaction,
        "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
        [
          now(),
          "CONTRACT_CHAT_REPLY_RECORDED",
          run["run_id"],
          Jason.encode!(%{
            task_key: task_key,
            user_message_id: attrs["user_message_id"],
            reply_evidence: reply_evidence
          })
        ]
      )

      {:ok, %{result: "CONTRACT_CHAT_REPLY_RECORDED", task_key: task_key, run_id: run["run_id"]}}
    end
  end

  @doc "Returns the exact recorded reply for the next factory follow-up."
  @spec reply(Store.connection(), String.t()) :: String.t() | nil
  def reply(connection, run_id) do
    case Store.one!(connection, "SELECT user_text FROM contract_chats WHERE run_id = ? AND status = 'ANSWERED'", [run_id]) do
      %{"user_text" => text} -> text
      _other -> nil
    end
  end

  @doc "Retires a reply only after the contract-author follow-up is consumed."
  @spec consume_reply(Store.connection(), String.t()) :: :ok
  def consume_reply(connection, run_id) do
    Store.query!(
      connection,
      "UPDATE contract_chats SET status = 'CONSUMED', updated_at = ? WHERE run_id = ? AND status = 'ANSWERED'",
      [now(), run_id]
    )

    :ok
  end

  defp validate_reply(chat, run, task) do
    with true <-
           (chat["status"] == "WAITING" and run["state"] == "AWAITING_CONTRACT_INPUT") or
             {:error, :contract_chat_not_waiting},
         true <-
           (task["status"] == "WAITING_FOR_USER" and task["run_id"] == run["run_id"]) or
             {:error, :contract_chat_task_changed},
         {:ok, snapshot} <- Jason.decode(run["snapshot_json"]),
         true <- source_sha256(snapshot) == chat["source_sha256"] or {:error, :contract_chat_jira_changed} do
      :ok
    end
  end

  defp validate_reply_binding(chat, task, attrs) do
    with true <-
           (attrs["thread_id"] == task["thread_id"] and
              attrs["codex_project_id"] == task["codex_project_id"] and
              attrs["question_turn_id"] == chat["question_turn_id"]) or
             {:error, :contract_chat_binding_mismatch},
         true <-
           (present?(attrs["user_turn_id"]) and attrs["user_turn_id"] != chat["question_turn_id"] and
              present?(attrs["user_message_id"]) and present?(attrs["text"])) or
             {:error, :contract_chat_reply_missing},
         true <- byte_size(attrs["text"]) <= 100_000 or {:error, :contract_chat_reply_too_large} do
      reply_evidence(attrs)
    end
  end

  defp reply_evidence(%{"reply_transport" => "delegated"} = attrs) do
    valid? =
      present?(attrs["source_thread_id"]) and attrs["source_thread_id"] != attrs["thread_id"] and
        present?(attrs["source_turn_id"]) and present?(attrs["source_user_message_id"]) and
        attrs["source_user_message_id"] == attrs["user_message_id"] and
        present?(attrs["delegation_item_id"])

    if valid? do
      {:ok,
       %{
         transport: "delegated",
         source_thread_id: attrs["source_thread_id"],
         source_turn_id: attrs["source_turn_id"],
         source_user_message_id: attrs["source_user_message_id"],
         delegation_item_id: attrs["delegation_item_id"]
       }}
    else
      {:error, :contract_chat_delegation_evidence_missing}
    end
  end

  defp reply_evidence(_attrs), do: {:ok, %{transport: "direct"}}

  defp factory_comment?(text), do: Enum.any?(@factory_comment_prefixes, &String.starts_with?(String.trim(text), &1))
  defp comment_text(comment) when is_map(comment), do: value(comment, "text") || value(comment, "body") || ""
  defp comment_text(text) when is_binary(text), do: text
  defp comment_text(_other), do: ""
  defp normalize_text(text) when is_binary(text), do: text |> String.replace("\r\n", "\n") |> String.trim()
  defp normalize_text(_other), do: ""
  defp value(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, String.to_atom(key), default))
  defp digest(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
