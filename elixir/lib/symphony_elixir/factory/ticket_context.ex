defmodule SymphonyElixir.Factory.TicketContext do
  @moduledoc "Bounded, read-only ticket projections with digest-pinned evidence drilldown."

  alias SymphonyElixir.Factory.{Contract, DesktopRequest, RunLedger, StageSchemas, Store}
  alias SymphonyElixir.Factory.{TaskLedger, TicketChat, TicketChatCommands, TicketChatOutbox, WorkerEvidence, WorkspaceAccess}

  @run_fields ~w(run_id issue_key repo_key repo_path kind state spec_revision contract_sha256 candidate_sha base_branch branch worktree workspace_state implementation_iteration verifier_round mr_url mr_state jira_status manual_validation_required updated_at)
  @task_fields ~w(task_key role stage status thread_id turn_id workspace workspace_sha prompt_sha256 failure_code updated_at)
  @sources %{
    "run" => {"runs", "run_id", "run_id"},
    "contract" => {"runs", "run_id", "contract_markdown"},
    "plan" => {"runs", "run_id", "plan_markdown"},
    "ci" => {"runs", "run_id", "ci_evidence_json"},
    "findings" => {"runs", "run_id", "repair_findings_json"},
    "feedback" => {"runs", "run_id", "review_feedback_json"},
    "task" => {"factory_tasks", "task_key", "output_json"},
    "task_failure" => {"factory_tasks", "task_key", "failure_code"},
    "receipt" => {"desktop_requests", "request_key", "output_json"},
    "event" => {"events", "id", "payload_json"},
    "question" => {"ticket_chat_questions", "question_key", "body"},
    "command" => {"ticket_chat_commands", "command_key", "payload_json"},
    "command_receipt" => {"ticket_chat_commands", "command_key", "receipt_json"},
    "answers" => {"ticket_chat_questions", "question_key", "answers_json"},
    "worker" => {"worker_evidence", "request_key", "output_json"}
  }
  @collections %{
    "tasks" => {"factory_tasks", "task_key", "task", "output_json"},
    "workers" => {"worker_evidence", "request_key", "worker", "output_json"},
    "questions" => {"ticket_chat_questions", "question_key", "question", "body"},
    "commands" => {"ticket_chat_commands", "command_key", "command", "payload_json"},
    "receipts" => {"desktop_requests", "request_key", "receipt", "output_json"}
  }

  @spec context(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def context(store, run_id) do
    Store.transaction!(store, &context_transaction(&1, run_id))
  end

  @doc "Keeps the complete compact status ahead of optional evidence in CLI output."
  @spec encode(map()) :: String.t()
  def encode(%{status: status} = packet), do: Jason.encode!(Jason.OrderedObject.new([{:status, status} | Map.to_list(Map.delete(packet, :status))]), pretty: true)
  def encode(packet), do: Jason.encode!(packet, pretty: true)

  @doc "Projects current dashboard fields without serializing retained delivery history."
  @spec dashboard(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def dashboard(store, run_id) do
    Store.transaction!(store, &dashboard_transaction(&1, run_id), mode: :deferred)
  end

  defp dashboard_transaction(store, run_id) do
    with {:ok, chat} <- TicketChat.for_run(store, run_id),
         {:ok, run} <- RunLedger.get(store, run_id) do
      disposition = current_writer_disposition(store, run)
      tasks = rows(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY created_at DESC, task_key DESC LIMIT 6", [run_id])

      questions =
        rows(
          store,
          "SELECT question_key, body, answers_json, binding_json, opened_at FROM ticket_chat_questions WHERE chat_key = ? AND run_id = ? AND status = 'OPEN' ORDER BY opened_at DESC LIMIT 4",
          [chat["chat_key"], run_id]
        )

      {:ok,
       %{
         status: status_summary(store, run),
         identity: Map.take(chat, ~w(chat_key scope_key issue_id issue_key repo_key generation thread_id context_sequence)),
         run: Map.take(run, @run_fields),
         tasks: Enum.map(tasks, &task_projection/1),
         open_questions: Enum.map(questions, &question_projection(&1, chat, run)),
         control_state: TicketChatCommands.control_state(store, run_id),
         ci: %{checked_at: run["ci_last_checked_at"], pipeline_url: run["ci_pipeline_url"], artifact: artifact("ci", run_id, run["ci_evidence_json"])},
         manual_validation: manual_validation(store, run),
         writer_disposition: disposition,
         next_action: next_action(run, disposition)
       }}
    end
  end

  @spec replay(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def replay(store, run_id) do
    with {:ok, packet} <- context(store, run_id),
         {:ok, synchronization} <- TicketChatOutbox.synchronization(store, run_id),
         {:ok, journal} <- journal(store, run_id, 0, packet.journal_page.high_water_id || 0, 10),
         {:ok, pages} <- replay_pages(store, run_id, packet.collections) do
      {:ok,
       %{
         context: packet,
         synchronization: synchronization,
         high_water: %{
           journal_event_id: journal.high_water_id,
           collections: Map.new(packet.collections, fn {kind, counts} -> {kind, counts["high_water"] || 0} end)
         },
         journal: journal,
         records: pages,
         uncertainty: replay_uncertainty(packet, journal, pages),
         next_action: packet.next_action
       }}
    end
  end

  defp replay_pages(store, run_id, collections) do
    Enum.reduce_while(~w(tasks workers receipts commands questions), {:ok, %{}}, fn kind, {:ok, pages} ->
      high_water = get_in(collections, [kind, "high_water"]) || 0

      case records(store, run_id, kind, 0, high_water, 10) do
        {:ok, page} -> {:cont, {:ok, Map.put(pages, kind, page)}}
        error -> {:halt, error}
      end
    end)
  end

  defp replay_uncertainty(packet, journal, pages) do
    collection_uncertainty =
      Enum.flat_map(pages, fn {kind, page} ->
        total = get_in(packet.collections, [kind, "total"]) || 0
        included = length(page.records)

        cond do
          total == 0 -> ["No #{kind} evidence is recorded."]
          page.has_more -> ["#{total - included} of #{total} #{kind} records remain beyond the first bounded page."]
          true -> []
        end
      end)

    journal_uncertainty = if journal.has_more, do: ["Additional journal events remain beyond the first bounded page."], else: []
    overview_uncertainty = if packet.journal_page.older_events, do: ["The context overview is bounded; use the fixed high-water cursor for remaining journal history."], else: []
    collection_uncertainty ++ journal_uncertainty ++ overview_uncertainty
  end

  defp context_transaction(store, run_id) do
    with {:ok, chat} <- TicketChat.for_run(store, run_id), {:ok, run} <- RunLedger.get(store, run_id) do
      bounded_packet(project(store, chat, run))
    end
  end

  defp bounded_packet(packet) do
    if byte_size(Jason.encode!(packet)) <= 16_384 and byte_size(packet.summary) <= 2048, do: {:ok, packet}, else: {:error, :context_identity_exceeds_budget}
  end

  def details(store, chat_key, ref, offset \\ 0, limit \\ 4096)

  @spec details(Store.connection(), String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def details(store, chat_key, ref, offset, limit)
      when is_binary(ref) and byte_size(ref) <= 2048 and is_integer(offset) and offset >= 0 and
             is_integer(limit) and limit in 1..8192 do
    with {:ok, token} <- decode_ref(ref),
         {:ok, raw} <- source(store, chat_key, token),
         true <- digest(raw) == token["sha256"] or {:error, :stale_artifact},
         {:ok, chunk} <- chunk(raw, offset, limit) do
      next = offset + byte_size(chunk)
      page = %{text: chunk, offset: offset, total_bytes: byte_size(raw), sha256: token["sha256"]}
      {:ok, Map.put(page, :next_offset, if(next < byte_size(raw), do: next))}
    end
  end

  def details(_store, _chat_key, _ref, _offset, _limit), do: {:error, :invalid_details_bounds}

  @spec journal(Store.connection(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def journal(store, run_id, after_id, high_water, limit)
      when is_integer(after_id) and after_id >= 0 and is_integer(high_water) and high_water >= after_id and
             is_integer(limit) and limit in 1..20 do
    with {:ok, _chat} <- TicketChat.for_run(store, run_id) do
      found = rows(store, "SELECT id, event_type, occurred_at, payload_json FROM events WHERE run_id = ? AND id > ? AND id <= ? ORDER BY id LIMIT ?", [run_id, after_id, high_water, limit + 1])
      page = Enum.take(found, limit)

      {:ok,
       %{
         events: Enum.map(page, &Map.put(Map.take(&1, ~w(id event_type occurred_at)), "artifact", artifact("event", &1["id"], &1["payload_json"]))),
         next_cursor: (List.last(page) || %{})["id"],
         has_more: length(found) > limit,
         high_water_id: high_water
       }}
    end
  end

  def journal(_store, _run_id, _after_id, _high_water, _limit), do: {:error, :invalid_journal_bounds}

  @spec records(Store.connection(), String.t(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def records(store, run_id, kind, after_row, high_water, limit)
      when is_integer(after_row) and after_row >= 0 and is_integer(high_water) and high_water >= after_row and
             is_integer(limit) and limit in 1..10 do
    with {:ok, chat} <- TicketChat.for_run(store, run_id),
         {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, {table, key, source_kind, column}} <- collection(kind) do
      found =
        rows(store, "SELECT t.rowid AS cursor, t.* FROM #{table} t WHERE #{membership(kind)} AND t.rowid > ? AND t.rowid <= ? ORDER BY t.rowid LIMIT ?", [run_id, after_row, high_water, limit + 1])

      page = Enum.take(found, limit)
      items = Enum.map(page, &record(&1, key, source_kind, column, chat, run))
      {:ok, %{records: items, has_more: length(found) > limit, next_cursor: (List.last(page) || %{})["cursor"], high_water: high_water}}
    end
  end

  def records(_store, _run_id, _kind, _after_row, _high_water, _limit), do: {:error, :invalid_record_bounds}

  defp collection(kind) do
    case Map.fetch(@collections, kind) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, :unsupported_record_collection}
    end
  end

  defp membership("receipts"), do: "t.target_kind = 'TASK' AND EXISTS (SELECT 1 FROM factory_tasks f WHERE f.task_key = t.target_key AND f.run_id = ?)"
  defp membership(_kind), do: "t.run_id = ?"

  defp record(row, key, source_kind, column, chat, run) do
    row
    |> Map.take([key | ~w(cursor status role stage created_at consumed_at updated_at thread_id turn_id payload_sha256)])
    |> Map.put("artifact", artifact(source_kind, row[key], row[column]))
    |> with_question_binding(row, source_kind, chat, run)
  end

  defp with_question_binding(record, row, "question", chat, run),
    do: Map.merge(record, question_projection(row, chat, run))

  defp with_question_binding(record, _row, _kind, _chat, _run), do: record

  defp project(store, chat, run) do
    tasks = rows(store, "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY created_at DESC, task_key DESC LIMIT 6", [run["run_id"]])
    events = rows(store, "SELECT id, event_type, occurred_at, payload_json FROM events WHERE run_id = ? AND event_type != 'TICKET_PRESENTATION_QUEUED' ORDER BY id DESC LIMIT 8", [run["run_id"]])
    writer_disposition = current_writer_disposition(store, run)

    questions =
      rows(store, "SELECT question_key, body, answers_json, binding_json, opened_at FROM ticket_chat_questions WHERE chat_key = ? AND run_id = ? AND status = 'OPEN' ORDER BY opened_at DESC LIMIT 4", [
        chat["chat_key"],
        run["run_id"]
      ])

    %{
      status: status_summary(store, run),
      identity: Map.take(chat, ~w(chat_key scope_key issue_id issue_key repo_key generation thread_id context_sequence)),
      ticket_cli: %{
        prefix: SymphonyElixir.Factory.TicketContextReader.cli_prefix(),
        instruction: "Use this deployment-aware prefix from the saved reader cwd for ticket prepare-stage, stage and details commands; do not retry bare Mix with elevated permissions."
      },
      run: Map.take(run, @run_fields),
      run_details: artifact("run", run["run_id"], run_details(run)),
      contract: %{binding: contract_binding(run), artifact: artifact("contract", run["run_id"], run["contract_markdown"])},
      plan: artifact("plan", run["run_id"], run["plan_markdown"]),
      open_questions: Enum.map(questions, &question_projection(&1, chat, run)),
      control_state: TicketChatCommands.control_state(store, run["run_id"]),
      decisions:
        rows(store, "SELECT command_key, status, receipt_json, updated_at FROM ticket_chat_commands WHERE chat_key = ? AND run_id = ? ORDER BY updated_at DESC LIMIT 4", [
          chat["chat_key"],
          run["run_id"]
        ])
        |> Enum.map(&decision_projection/1),
      tasks: Enum.map(tasks, &task_projection/1),
      latest_verifier: verifier(store, run),
      historical_verifier: historical_verifier(store, run),
      manual_validation: manual_validation(store, run),
      collections: collection_sizes(store, run),
      work_progress: progress(store, run),
      writer_disposition: writer_disposition,
      ci: %{checked_at: run["ci_last_checked_at"], pipeline_url: run["ci_pipeline_url"], artifact: artifact("ci", run["run_id"], run["ci_evidence_json"])},
      findings: artifact("findings", run["run_id"], run["repair_findings_json"]),
      feedback: artifact("feedback", run["run_id"], run["review_feedback_json"]),
      journal: Enum.map(events, &Map.put(Map.take(&1, ~w(id event_type occurred_at)), "artifact", artifact("event", &1["id"], &1["payload_json"]))),
      journal_page: %{
        high_water_id: event_high_water(store, run),
        included: length(events),
        older_events: event_count(store, run) > length(events)
      },
      next_action: next_action(run, writer_disposition),
      summary: summary(run, writer_disposition)
    }
  end

  defp decision_projection(row) do
    row
    |> Map.drop(["receipt_json"])
    |> Map.put("receipt", artifact("command_receipt", row["command_key"], row["receipt_json"]))
  end

  defp task_projection(row) do
    row
    |> Map.take(@task_fields)
    |> Map.put("failure_code", bounded_failure(row["failure_code"]))
    |> Map.put("failure", artifact("task_failure", row["task_key"], row["failure_code"]))
    |> Map.put("evidence", artifact("task", row["task_key"], row["output_json"]))
  end

  defp bounded_failure(nil), do: nil
  defp bounded_failure(raw) when byte_size(raw) <= 512, do: raw
  defp bounded_failure(raw), do: valid_prefix(raw, 509) <> "…"

  defp current_writer_disposition(store, run) do
    event =
      Store.one!(store, "SELECT id, payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED' ORDER BY id DESC LIMIT 1", [run["run_id"]])

    with %{"id" => event_id, "payload_json" => raw} <- event,
         {:ok, payload} when is_map(payload) <- Jason.decode(raw),
         true <- payload["run_binding"] == Map.take(run, ~w(run_id state spec_revision contract_sha256 candidate_sha implementation_iteration worktree branch)),
         true <- is_binary(payload["request_key"]) and is_binary(payload["output_json"]),
         true <- digest(payload["output_json"]) == payload["output_sha256"],
         {:ok, evidence} <- WorkerEvidence.get(store, payload["request_key"]),
         true <- evidence["status"] == "RESULT_RECORDED" and evidence["output_json"] == payload["output_json"] and evidence["output_sha256"] == payload["output_sha256"],
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         {:ok, task} <- TaskLedger.get(store, payload["task_key"]),
         true <- Map.take(task, ~w(task_key role stage status thread_id turn_id updated_at)) == payload["task"],
         true <- task["role"] == "feature-writer" and task["stage"] == run["state"],
         {:ok, access} <- WorkspaceAccess.get(store, payload["reservation_key"]),
         true <- access["generation"] == payload["reservation_generation"] and access["released_at"] == nil and access["request_key"] == payload["request_key"],
         {:ok, %{"status" => "BLOCKED", "blockers" => blockers}} <- Jason.decode(payload["output_json"]),
         true <- blockers == payload["blockers"] and is_binary(payload["next_action"]) do
      %{
        status: "BLOCKED",
        request_key: payload["request_key"],
        blockers: blockers,
        next_action: payload["next_action"],
        output_sha256: payload["output_sha256"],
        artifact: artifact("event", event_id, raw)
      }
    else
      _ -> nil
    end
  end

  defp question_projection(question, chat, run) do
    current = Map.take(run, ~w(spec_revision contract_sha256 candidate_sha)) |> Map.put("generation", chat["generation"])
    record = Map.take(question, ~w(question_key opened_at binding_json))

    record
    |> Map.put("body", artifact("question", question["question_key"], question["body"]))
    |> Map.put("answers", artifact("answers", question["question_key"], question["answers_json"]))
    |> Map.put("binding", if(Jason.decode(question["binding_json"]) == {:ok, current}, do: "CURRENT", else: "STALE"))
  end

  @doc "Normalizes presentation content only; authorization retains exact evidence bytes."
  @spec presentation_data(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def presentation_data(store, chat_key, packet) do
    material_value(store, chat_key, Map.drop(packet, [:journal, :journal_page, :collections]))
  end

  defp material_value(store, chat_key, %{artifact_ref: ref, kind: kind}) do
    with {:ok, token} <- decode_ref(ref),
         {:ok, raw} <- source(store, chat_key, token),
         :ok <- current_artifact(raw, token) do
      value =
        case Jason.decode(raw) do
          {:ok, value} -> value
          _ -> %{raw_sha256: digest(raw)}
        end

      {:ok, %{kind: kind, content: material_fields(value)}}
    end
  end

  defp material_value(store, chat_key, value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, &material_field(store, chat_key, &1, &2))
  end

  defp material_value(store, chat_key, value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, &material_item(store, chat_key, &1, &2))
  end

  defp material_value(_store, _chat_key, value), do: {:ok, value}

  defp current_artifact(raw, token), do: if(digest(raw) == token["sha256"], do: :ok, else: {:error, :stale_artifact})

  defp material_field(store, chat_key, {key, value}, {:ok, result}) do
    if volatile?(key) do
      {:cont, {:ok, result}}
    else
      case material_value(store, chat_key, value) do
        {:ok, material} -> {:cont, {:ok, Map.put(result, key, material)}}
        error -> {:halt, error}
      end
    end
  end

  defp material_item(store, chat_key, value, {:ok, result}) do
    case material_value(store, chat_key, value) do
      {:ok, material} -> {:cont, {:ok, result ++ [material]}}
      error -> {:halt, error}
    end
  end

  defp material_fields(value) when is_map(value) do
    value |> Enum.reject(fn {key, _} -> volatile?(key) end) |> Map.new(fn {key, value} -> {key, material_fields(value)} end)
  end

  defp material_fields(value) when is_list(value), do: Enum.map(value, &material_fields/1)
  defp material_fields(value), do: value
  defp volatile?(key), do: to_string(key) in ~w(occurred_at observed_at context_sequence updated_at updatedAt recorded_at checked_at ci_last_checked_at opened_at)

  defp contract_binding(%{"spec_revision" => revision, "contract_markdown" => markdown} = run)
       when is_integer(revision) and revision > 0 and is_binary(markdown) do
    if Contract.bind(run["issue_key"], revision, markdown).sha256 == run["contract_sha256"], do: "EXACT", else: "INVALID"
  end

  defp contract_binding(_run), do: "UNAVAILABLE"

  defp status_summary(store, run) do
    ci = decode(run["ci_evidence_json"])
    ci_exact = is_binary(run["candidate_sha"]) and ci["sha"] == run["candidate_sha"]
    review = verifier(store, run)
    review_exact = review[:current_binding] == "EXACT" and review[:candidate_sha] == run["candidate_sha"]
    publication = decode(run["candidate_handoff"])
    outcome = RunLedger.stage_outcome(store, run)
    reason = if outcome, do: outcome["reason"]

    hold =
      if is_binary(reason) do
        maintenance = reason == "verified_ci_rollover_prior_unproven"

        %{
          reason: reason,
          observed_at: outcome["observed_at"],
          action_owner: if(maintenance, do: "FACTORY_MAINTENANCE", else: "FACTORY"),
          next_action:
            if(maintenance,
              do: "Fix the factory's final publication compatibility check; do not rerun CI or request another code repair.",
              else: "The factory will retry this step. Inspect this reason if it continues without progress."
            )
        }
      end

    %{
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      run_id: run["run_id"],
      issue_key: run["issue_key"],
      state: run["state"],
      candidate_sha: run["candidate_sha"],
      updated_at: run["updated_at"],
      ci: %{
        status: if(ci_exact, do: ci["status"] || "NOT_RECORDED", else: "UNPROVEN_OR_STALE"),
        candidate_sha: ci["sha"],
        pipeline_id: ci["pipeline_id"],
        binding: if(ci_exact, do: "EXACT", else: "UNPROVEN_OR_STALE")
      },
      verifier: %{
        status: if(review_exact, do: review[:historical_status], else: "UNPROVEN_OR_STALE"),
        candidate_sha: review[:candidate_sha],
        binding: if(review_exact, do: "EXACT", else: "UNPROVEN_OR_STALE")
      },
      publication: %{phase: publication["phase"], remote_sha: publication["remote_sha"]},
      hold: hold,
      next_action:
        cond do
          hold ->
            hold.next_action

          run["state"] == "PUSHING" and ci_exact and ci["status"] == "PASS" and review_exact and review[:historical_status] == "PASS" ->
            "The factory is finalizing publication for the verified candidate; no new code repair or CI run is indicated."

          true ->
            next_action(run, %{})
        end
    }
  end

  defp verifier(store, run) do
    key = "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}"

    case Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ? AND role = 'change-verifier'", [key]) do
      nil -> %{status: "NOT_RECORDED"}
      task -> verifier_receipt(store, run, task)
    end
  end

  defp historical_verifier(store, run) do
    task =
      Store.one!(store, "SELECT * FROM factory_tasks WHERE run_id = ? AND role = 'change-verifier' AND status IN ('COMPLETE', 'CONSUMED') ORDER BY created_at DESC, rowid DESC LIMIT 1", [run["run_id"]])

    if task, do: verifier_receipt(store, run, task), else: %{status: "NOT_RECORDED"}
  end

  defp manual_validation(store, run) do
    task = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ? AND run_id = ?", [run["run_id"] <> ":manual-validator", run["run_id"]])
    output = decode((task || %{})["output_json"])

    %{
      required: run["manual_validation_required"],
      status: output["status"],
      candidate_sha: output["candidate_sha"],
      task_status: (task || %{})["status"],
      publication: "NOT_PROVEN_BY_VALIDATOR_OUTPUT",
      artifact: artifact("task", (task || %{})["task_key"], (task || %{})["output_json"])
    }
  end

  defp collection_sizes(store, run) do
    Map.new(@collections, fn {kind, {table, _key, _source, _column}} ->
      count = Store.one!(store, "SELECT COUNT(*) AS total, MAX(t.rowid) AS high_water FROM #{table} t WHERE #{membership(kind)}", [run["run_id"]])
      {kind, count}
    end)
  end

  defp verifier_receipt(store, run, task) do
    case WorkerEvidence.verifier_receipt(store, run, task) do
      {:ok, evidence} -> worker_verifier(run, task, evidence)
      {:error, _} -> desktop_verifier_receipt(store, run, task)
    end
  end

  defp worker_verifier(run, task, evidence) do
    output = decode(evidence["output_json"])

    %{
      historical_status: output["status"],
      candidate_sha: output["candidate_sha"],
      current_binding: if(contract_binding(run) == "EXACT", do: "EXACT", else: "UNPROVEN_OR_STALE"),
      task_key: task["task_key"],
      request_key: evidence["request_key"],
      recorded_at: evidence["created_at"],
      receipt: artifact("worker", evidence["request_key"], evidence["output_json"]),
      artifact: artifact("task", task["task_key"], task["output_json"])
    }
  end

  defp desktop_verifier_receipt(store, run, task) do
    receipt =
      Store.one!(
        store,
        """
        SELECT * FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND status = 'SUCCEEDED'
          AND thread_id = ? AND turn_id = ?
          AND CASE WHEN json_valid(metadata_json) THEN json_extract(metadata_json, '$.stage_prompt_sha256') END = ?
        ORDER BY created_at DESC, rowid DESC LIMIT 1
        """,
        [task["task_key"], task["thread_id"], task["turn_id"], task["prompt_sha256"]]
      )

    output = decode(task["output_json"])
    metadata = decode((receipt || %{})["metadata_json"])

    exact = exact_verdict?(run, task, receipt, output, metadata)

    %{
      historical_status: output["status"],
      candidate_sha: output["candidate_sha"],
      current_binding: if(exact, do: "EXACT", else: "UNPROVEN_OR_STALE"),
      task_key: task["task_key"],
      request_key: (receipt || %{})["request_key"],
      recorded_at: (receipt || task)["updated_at"],
      receipt: artifact("receipt", (receipt || %{})["request_key"], (receipt || %{})["output_json"]),
      artifact: artifact("task", task["task_key"], task["output_json"])
    }
  end

  defp exact_verdict?(_run, _task, nil, _output, _metadata), do: false

  defp exact_verdict?(run, task, receipt, output, metadata) do
    current = {run["candidate_sha"], run["contract_sha256"], run["spec_revision"]}
    observed = {output["candidate_sha"], metadata["contract_sha256"], metadata["spec_revision"]}

    current == observed and contract_binding(run) == "EXACT" and task["status"] in ~w(COMPLETE CONSUMED) and
      DesktopRequest.payload_intact?(receipt) and decode(receipt["output_json"])["result"] == output and
      StageSchemas.validate(output, StageSchemas.for_stage(:change_verifier)) == :ok
  end

  defp progress(store, run) do
    case Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key = ? AND run_id = ?", [run["run_id"] <> ":feature-writer", run["run_id"]]) do
      nil ->
        %{availability: "NOT_RECORDED"}

      task ->
        output = decode(task["output_json"])
        evidence = artifact("task", task["task_key"], task["output_json"])

        Map.new(~w(status summary remaining_criteria blockers checks next_slice), fn field ->
          value = output[field]
          {field, if(byte_size(Jason.encode!(value)) <= 256, do: value, else: %{omitted: true, evidence: evidence})}
        end)
    end
  end

  defp run_details(run),
    do: run |> Map.drop(~w(snapshot_json contract_markdown plan_markdown ci_evidence_json repair_findings_json review_feedback_json)) |> Jason.encode!()

  defp artifact(_kind, _id, nil), do: %{availability: "NOT_RECORDED"}

  defp artifact(kind, id, raw) do
    token = %{"kind" => kind, "id" => id, "sha256" => digest(raw)}
    ref = token |> Jason.encode!() |> Base.url_encode64(padding: false)
    availability = if kind in ~w(contract plan question task_failure) or match?({:ok, _}, Jason.decode(raw)), do: "RECORDED", else: "INVALID_JSON"
    %{artifact_ref: ref, kind: kind, sha256: token["sha256"], bytes: byte_size(raw), availability: availability}
  end

  defp decode_ref(ref) do
    with {:ok, json} <- Base.url_decode64(ref, padding: false),
         {:ok, %{"kind" => kind, "id" => id, "sha256" => sha} = token} <- Jason.decode(json),
         true <- valid_token?(kind, id, sha, token) do
      {:ok, token}
    else
      _ -> {:error, :invalid_artifact_ref}
    end
  end

  defp valid_token?(kind, id, sha, token), do: Map.has_key?(@sources, kind) and (is_binary(id) or is_integer(id)) and is_binary(sha) and map_size(token) == 3

  defp source(store, chat_key, token) do
    {table, key, column} = @sources[token["kind"]]
    row = Store.one!(store, "SELECT * FROM #{table} WHERE #{key} = ?", [token["id"]])
    run_id = source_run(store, token["kind"], row)
    query = "SELECT run_id FROM ticket_chat_runs WHERE chat_key = ? AND run_id = ?"
    member = Store.one!(store, query, [chat_key, run_id])
    present = member != nil and is_binary((row || %{})[column])
    if present, do: {:ok, source_value(token["kind"], row, column)}, else: {:error, :artifact_not_in_ticket}
  end

  defp source_value("run", row, _column), do: run_details(row)
  defp source_value(_kind, row, column), do: row[column]

  defp source_run(_store, _kind, nil), do: nil

  defp source_run(store, "receipt", %{"target_kind" => "TASK", "target_key" => key}) do
    (Store.one!(store, "SELECT run_id FROM factory_tasks WHERE task_key = ?", [key]) || %{})["run_id"]
  end

  defp source_run(_store, "receipt", _row), do: nil
  defp source_run(_store, _kind, row), do: row["run_id"]

  defp chunk(raw, offset, limit) when offset <= byte_size(raw) do
    tail = binary_part(raw, offset, byte_size(raw) - offset)

    if String.valid?(tail) do
      prefix = valid_prefix(tail, min(limit, byte_size(tail)))
      if prefix == "" and tail != "", do: {:error, :page_limit_smaller_than_character}, else: {:ok, prefix}
    else
      {:error, :offset_not_utf8_boundary}
    end
  end

  defp chunk(_raw, _offset, _limit), do: {:error, :offset_out_of_range}

  defp valid_prefix(raw, size) do
    prefix = binary_part(raw, 0, size)
    if String.valid?(prefix), do: prefix, else: valid_prefix(raw, size - 1)
  end

  defp event_count(store, run), do: Store.one!(store, "SELECT COUNT(*) AS count FROM events WHERE run_id = ? AND event_type != 'TICKET_PRESENTATION_QUEUED'", [run["run_id"]])["count"]
  defp event_high_water(store, run), do: Store.one!(store, "SELECT COALESCE(MAX(id), 0) AS high_water FROM events WHERE run_id = ?", [run["run_id"]])["high_water"]

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> value
      _ -> %{"invalid_evidence" => true}
    end
  end

  defp decode(_raw), do: %{}

  defp rows(store, sql, params) do
    %{columns: columns, rows: rows} = Store.query!(store, sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp next_action(_run, %{status: "BLOCKED", next_action: action}), do: action

  defp next_action(run, _writer_disposition) do
    case run["state"] do
      "AWAITING_CONTRACT_INPUT" -> "Await a read-backed answer to the current question; no work is authorized by this context."
      state when state in ~w(READY_FOR_REVIEW DELIVERED) -> "Review the recorded MR; source rework requires explicit admission."
      _ -> "Reconcile the recorded stage and exact evidence before admitting the next action."
    end
  end

  defp summary(run, %{status: "BLOCKED"}), do: "#{run["issue_key"]}: BLOCKED at #{run["state"]}; revision #{run["spec_revision"]}; candidate #{run["candidate_sha"] || "not recorded"}."
  defp summary(run, _writer_disposition), do: "#{run["issue_key"]}: #{run["state"]}; revision #{run["spec_revision"]}; candidate #{run["candidate_sha"] || "not recorded"}."
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
