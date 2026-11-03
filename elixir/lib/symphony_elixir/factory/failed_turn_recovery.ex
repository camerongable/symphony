defmodule SymphonyElixir.Factory.FailedTurnRecovery do
  @moduledoc """
  Exact failed-turn recovery with genuine shutdown and a bounded durable automatic lineage.
  """
  alias SymphonyElixir.Factory.{
    DesktopStageRunner,
    NativeQueueReadback,
    RunLedger,
    Store,
    TaskLauncher,
    TaskLedger,
    TicketChat,
    TicketCompletionConfirmation,
    TicketPushRecovery,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerFileIO,
    WorkerInstructions,
    WorkspaceAccess,
    Worktree
  }

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.Control

  @event "TICKET_FAILED_TURN_RECOVERY_APPLIED"
  @closed_connection_message "connection is closed because of an error, disconnect or timeout"
  @closed_connection inspect(@closed_connection_message)
  @closed_connection_exception inspect({:worker_exception, :error, inspect(%DBConnection.ConnectionError{message: @closed_connection_message, severity: :error, reason: :error})})
  @sqlite_rollback_exception inspect({:worker_exception, :error, inspect(%RuntimeError{message: "factory SQLite transaction failed: :rollback"})})
  @run_fields ~w(run_id state worktree branch candidate_sha spec_revision contract_sha256 implementation_iteration plan_markdown)

  defp native_history(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: {:ok, opts[:native_history]}, else: legacy_native_history(opts))
  defp queue_reader(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: AppServer, else: legacy_queue_reader(opts))
  defp owned_reader(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: AppServer, else: legacy_owned_reader(opts))
  defp native_home(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: opts[:native_home], else: legacy_native_home(opts))
  defp queue_database(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: opts[:native_queue_database], else: legacy_queue_database(opts))

  if Mix.env() == :test do
    defp legacy_native_history(opts) do
      if is_binary(opts[:native_history]), do: {:ok, opts[:native_history]}, else: {:error, :native_history_missing}
    end

    defp recovery_now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
    defp legacy_queue_reader(opts), do: Keyword.get(opts, :native_reader, AppServer)
    defp legacy_owned_reader(opts), do: Keyword.get(opts, :app_server, AppServer)
    defp legacy_native_home(opts), do: opts[:native_home] || get_in(opts[:native_queue] || %{}, ["writer_lock", "home"]) || Path.join(System.user_home!(), ".codex")

    defp legacy_queue_database(opts),
      do: opts[:native_queue_database] || get_in(opts[:native_queue] || %{}, ["persisted_queue", "database_path"]) || Path.join(System.user_home!(), ".codex/queue_1.sqlite")
  else
    defp legacy_native_history(_opts), do: {:ok, Path.join(System.user_home!(), ".codex/thread_history_1.sqlite")}
    defp recovery_now(_opts), do: DateTime.utc_now()
    defp legacy_queue_reader(_opts), do: AppServer
    defp legacy_owned_reader(_opts), do: AppServer
    defp legacy_native_home(_opts), do: Path.join(System.user_home!(), ".codex")
    defp legacy_queue_database(_opts), do: Path.join(System.user_home!(), ".codex/queue_1.sqlite")
  end

  @spec prepare_automatic(Store.connection(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_automatic(store, request, turn, opts \\ []) do
    prepare(store, request, turn, Keyword.put(opts, :automatic, true))
  end

  @doc "Prepares one explicitly bound no-edit confirmation successor after a proven schema rejection."
  @spec prepare_schema_confirmation(Store.connection(), String.t(), keyword()) ::
          {:ok, map()} | :none | {:error, term()}
  def prepare_schema_confirmation(store, request, opts) do
    with {:ok, old} <- WorkerEvidence.get(store, request),
         {:ok, scope} <- TicketCompletionConfirmation.schema_recovery_scope(store, old) do
      prepare_scoped_schema(store, old, scope, opts)
    else
      {:error, :completion_schema_recovery_not_authorized} -> :none
      error -> error
    end
  end

  defp prepare_scoped_schema(store, old, scope, opts) do
    with {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         true <- Map.take(tick, ~w(scope dispatcher_id)) == Map.take(scope, ~w(scope dispatcher_id)) do
      options = Keyword.merge(opts, schema_confirmation: Map.put(scope, "operator_tick", tick), automatic: false)

      with {:ok, queue} <- read_interrupted_queue(old, options),
           do: prepare(store, old["request_key"], old["turn_id"], Keyword.put(options, :native_queue, queue))
    else
      _ -> {:error, :completion_schema_tick_unproven}
    end
  end

  @doc "Explicitly recovers one proven interrupted connection-loss turn; quiescence is not an owned exit."
  @spec prepare_interrupted(Store.connection(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_interrupted(store, request, turn, opts \\ []) do
    opts = opts |> Keyword.put(:manual_interrupted, true) |> Keyword.put(:automatic, false)

    case receipt(store, "old_request_key", request) do
      nil -> prepare_interrupted_new(store, request, turn, opts)
      %{"kind" => "INTERRUPTED_TURN_QUIESCENCE", "failed_turn_id" => ^turn} -> prepare(store, request, turn, opts)
      _ -> {:error, :failed_retry_turn_changed}
    end
  end

  defp prepare_interrupted_new(store, request, turn, opts) do
    with {:ok, old} <- WorkerEvidence.get(store, request),
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         :ok <- eligible(store, old, task, run, turn, opts),
         {:ok, _} <- native_failed(old, opts),
         {:ok, queue} <- read_interrupted_queue(old, opts) do
      prepare(store, request, turn, Keyword.put(opts, :native_queue, queue))
    end
  end

  @doc "Read-only exact failed-turn and quiescence check; grants no retry or exit evidence."
  @spec check(Store.connection(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(store, request, turn, opts \\ []) do
    with {:ok, old} <- WorkerEvidence.get(store, request),
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         :ok <- eligible(store, old, task, run, turn, opts),
         binding = Jason.decode!(old["binding_json"]),
         {:ok, access} <- WorkspaceAccess.validate(store, old["reservation_key"], binding["reservation_generation"]),
         {:ok, native} <- native_failed(old, opts),
         :ok <- quiescent(store, old),
         {:ok, files} <- files(store, old, access),
         {:ok, head} <- WorkerEvidence.checkout_head(access),
         true <- recovery_head_matches?(head, run, binding),
         {:ok, base} <- TicketWorkerRunner.read_packet(store, run["run_id"], "feature-writer", binding["base_sha"]),
         true <- packet_matches?(store, old, base) do
      {:ok, %{"request_key" => request, "thread_id" => old["thread_id"], "turn_id" => turn, "head" => head, "native" => native, "files" => Enum.map(files, & &1["path"])}}
    else
      {:error, _} = error -> error
      _ -> {:error, :failed_retry_binding_changed}
    end
  end

  @spec prepare(Store.connection(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(store, request, turn, opts \\ []) do
    transaction(store, fn tx ->
      with :ok <- idle_tick(tx, opts) do
        case receipt(tx, "old_request_key", request) do
          nil -> prepare_new(tx, request, turn, opts)
          %{"failed_turn_id" => ^turn} = prior -> replay_prepared(tx, request, prior)
          _ -> {:error, :failed_retry_turn_changed}
        end
      end
    end)
  end

  defp replay_prepared(store, request, prior) do
    if superseded?(store, elem(WorkerEvidence.get(store, request), 1)), do: {:ok, prior}, else: {:error, :failed_retry_receipt_changed}
  end

  defp prepare_new(store, request, turn, opts) do
    with {:ok, old} <- WorkerEvidence.get(store, request),
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         :ok <- eligible(store, old, task, run, turn, opts),
         binding = Jason.decode!(old["binding_json"]),
         {:ok, access} <- WorkspaceAccess.validate(store, old["reservation_key"], binding["reservation_generation"]),
         {:ok, native} <- native_failed(old, opts),
         :ok <- interrupted_transfer_current(old, opts),
         {:ok, retry_policy} <- retry_policy(store, old, native, opts),
         :ok <- quiescent(store, old),
         {:ok, files} <- files(store, old, access),
         {:ok, head} <- WorkerEvidence.checkout_head(access),
         true <- recovery_head_matches?(head, run, binding) or {:error, :failed_retry_head_changed},
         {:ok, base} <- TicketWorkerRunner.read_packet(store, run["run_id"], "feature-writer", binding["base_sha"]),
         true <- packet_matches?(store, old, base) or {:error, :failed_retry_packet_changed},
         :ok <- WorkspaceAccess.source_capacity(store, run, Keyword.take(opts, [:capacity_policy, :free_bytes])) do
      proof = %{
        "kind" => recovery_kind(opts),
        "old_request_key" => request,
        "failed_turn_id" => turn,
        "old_evidence_sha256" => hash(Jason.encode!(old)),
        "old_access_sha256" => hash(Jason.encode!(access)),
        "run" => Map.take(run, @run_fields),
        "native" => native,
        "native_queue" => opts[:native_queue],
        "files" => files,
        "old_owner_process_json" => old["owner_process_json"],
        "old_task_failure_code" => task["failure_code"],
        "quiescence_is_owned_stop" => false,
        "binding_sha256" => old["binding_sha256"],
        "thread_id" => old["thread_id"],
        "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "retry_policy" => retry_policy
      }

      proof = if schema_mode?(opts), do: Map.put(proof, "schema_confirmation", opts[:schema_confirmation]), else: proof

      key = "TFER-" <> hash(request <> ":" <> turn)

      prompt =
        Jason.encode!(%{
          "base_packet" => Jason.decode!(base),
          "controller_failed_turn_recovery" => key,
          "recovery_instruction" => recovery_instruction(opts),
          "preserved_paths" => Enum.map(files, & &1["path"])
        })

      new_request = DesktopStageRunner.request_key(task["task_key"], task["turn_id"], prompt)

      proof =
        Map.merge(proof, %{"recovery_key" => key, "prompt" => prompt, "new_request_key" => new_request, "new_reservation_key" => "workspace:" <> new_request, "new_prompt_sha256" => hash(prompt)})

      with :ok <- interrupted_transfer_current(old, opts),
           _ <- persist(store, run["run_id"], "TICKET_FAILED_TURN_RECOVERY_AUTHORIZED", proof),
           {:ok, transferred} <- WorkspaceAccess.transfer_failed_source(store, access["reservation_key"], proof),
           {:ok, _} <- TaskLedger.update(store, task["task_key"], %{status: "STARTING", prompt_sha256: hash(prompt), output_json: nil, failure_code: nil}),
           :ok <- WorkerInstructions.bind_task(store, task["task_key"], hash(prompt), Jason.decode!(base)["instruction_binding_sha256"]),
           {:ok, attempt_attrs} <-
             WorkerEvidence.inherit_runtime(
               %{
                 "request_key" => new_request,
                 "task_key" => task["task_key"],
                 "reservation_key" => transferred["reservation_key"],
                 "input_sha256" => hash(prompt),
                 "owner_id" => "owner:" <> new_request,
                 "schema" => binding["schema"],
                 "policy" => binding["policy"]
               },
               binding
             ),
           {:ok, attempt} <- WorkerEvidence.reserve(store, attempt_attrs) do
        result = Map.merge(proof, %{"new_generation" => transferred["generation"], "new_binding_sha256" => attempt["binding_sha256"]})
        persist(store, run["run_id"], @event, result)
        {:ok, result}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp idle_tick(store, opts) do
    case opts[:idle_scope] do
      nil -> :ok
      scope -> if Control.status(store, scope)["tick_id"] == nil, do: :ok, else: {:error, :live_tick_lease}
    end
  end

  defp read_interrupted_queue(old, opts) do
    with {:ok, opts} <- runtime_options(old, opts), do: read_interrupted_queue_resolved(old, opts)
  end

  defp read_interrupted_queue_resolved(old, opts) do
    reader = queue_reader(opts)

    read_opts =
      Keyword.merge(Keyword.take(opts, [:native_runtime]),
        workspace: opts[:workspace] || File.cwd!(),
        include_turns: false,
        include_latest_turn: true,
        include_queue: true,
        native_history: opts[:native_history]
      )

    with {:ok, native} <- reader.read_native_thread(old["thread_id"], read_opts),
         :ok <- queue_valid?(old, native, opts),
         {:ok, _} <- runtime_options(old, opts),
         {:ok, persisted} <- NativeQueueReadback.read(queue_database(opts), old["thread_id"]),
         {:ok, _} <- runtime_options(old, opts),
         {:ok, lock} <- NativeQueueReadback.writer_unlocked(native_home(opts), old["thread_id"]),
         {:ok, _} <- runtime_options(old, opts) do
      {:ok, native |> Map.put("persisted_queue", persisted) |> Map.put("writer_lock", Map.put(lock, "home", native_home(opts)))}
    else
      {:error, _} = error -> error
    end
  end

  defp interrupted_queue_current(old, opts) do
    with {:ok, opts} <- runtime_options(old, opts), do: interrupted_queue_current_resolved(old, opts)
  end

  defp interrupted_queue_current_resolved(old, opts) do
    if guarded_mode?(opts) do
      with :ok <- queue_valid?(old, opts[:native_queue], opts),
           {:ok, current} <- NativeQueueReadback.read(queue_database(opts), old["thread_id"]),
           true <- current == opts[:native_queue]["persisted_queue"],
           {:ok, _} <- runtime_options(old, opts) do
        :ok
      else
        _ -> {:error, :interrupted_persisted_queue_unproven}
      end
    else
      :ok
    end
  end

  defp interrupted_transfer_current(old, opts) do
    with {:ok, opts} <- runtime_options(old, opts), :ok <- interrupted_queue_current(old, opts) do
      if guarded_mode?(opts) do
        with {:ok, _} <- runtime_options(old, opts),
             {:ok, lock} <- NativeQueueReadback.writer_unlocked(native_home(opts), old["thread_id"]),
             true <- Map.put(lock, "home", native_home(opts)) == opts[:native_queue]["writer_lock"],
             {:ok, _} <- runtime_options(old, opts) do
          :ok
        else
          _ -> {:error, :interrupted_native_writer_lock_unproven}
        end
      else
        :ok
      end
    end
  end

  defp queue_valid?(old, native, opts) when is_map(native) do
    binding = Jason.decode!(old["binding_json"])
    latest = native["latest_turn_observation"] || %{}
    confirmation = latest["confirmation"] || %{}
    queue = native["queue_observation"] || %{}
    params = %{"threadId" => old["thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"}

    with true <- {native["id"], native["cwd"]} == {old["thread_id"], binding["policy"]["cwd"]},
         true <- get_in(native, ["status", "type"]) in ["idle", "notLoaded", "systemError"],
         true <- is_number(native["updatedAt"]) and native["updatedAt"] == latest["updated_at"],
         true <- latest["mode"] == "LATEST_DESC" and latest["parameters"] == params,
         %{"data" => [%{"id" => turn, "status" => status, "error" => error, "items" => items}]} = raw when is_list(items) <- latest["raw_response"],
         true <- terminal_queue_turn?(old, status, error, items, opts),
         true <- Enum.all?(items, &is_map/1),
         false <- Enum.any?(items, &native_final?/1),
         true <- turn == old["turn_id"] and latest["sha256"] == json_hash(raw),
         %{"data" => data} = confirmed <- confirmation["raw_response"],
         true <- data == raw["data"] and confirmation["sha256"] == json_hash(confirmed),
         [%{"content" => content}] <- Enum.filter(items, &(&1["type"] == "userMessage")),
         true <- is_list(content) and content != [] and Enum.all?(content, &(&1["type"] == "text" and is_binary(&1["text"]))),
         true <- hash(Enum.map_join(content, & &1["text"])) == binding["input_sha256"],
         true <- Map.take(queue, ~w(thread_id empty_complete count_lower_bound has_more)) == %{"thread_id" => old["thread_id"], "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false},
         %{"data" => [], "nextCursor" => nil} = queue_raw <- queue["raw_response"],
         true <- queue["sha256"] == json_hash(queue_raw),
         true <- Enum.all?([latest["observed_at"], confirmation["observed_at"], queue["observed_at"]], &fresh_queue?/1) do
      :ok
    else
      _ -> {:error, :interrupted_native_queue_unproven}
    end
  end

  defp queue_valid?(_old, _native, _opts), do: {:error, :interrupted_native_queue_unproven}

  defp terminal_queue_turn?(old, status, error, items, opts) do
    if schema_mode?(opts),
      do: status == "failed" and old["failure_code"] == inspect({:worker_turn_error, error}) and match?([%{"type" => "userMessage"}], items),
      else: status == "interrupted" and is_nil(error)
  end

  defp native_final?(%{"type" => "agentMessage"} = item), do: item["phase"] != "commentary"
  defp native_final?(_item), do: false

  defp fresh_queue?(at) when is_binary(at) do
    with {:ok, time, _} <- DateTime.from_iso8601(at) do
      age = DateTime.diff(DateTime.utc_now(), time, :millisecond)
      age >= 0 and age <= 10_000
    else
      _ -> false
    end
  end

  defp fresh_queue?(_at), do: false
  defp json_hash(value), do: hash(Jason.encode!(value))

  defp eligible(store, old, task, run, turn, opts) do
    binding = Jason.decode!(old["binding_json"])

    with :ok <- TicketChat.ordinary_delivery_eligibility(run),
         true <- {run["execution_mode"], run["state"], task["role"], task["status"], old["status"]} == {"TICKET_SUPERVISOR_V1", recovery_stage(opts), "feature-writer", "STALE", "RECONCILE_REQUIRED"},
         :ok <- schema_scope_current(store, old, opts),
         true <- old["turn_id"] == turn and old["thread_id"] == task["thread_id"],
         true <- is_binary(old["owner_process_json"]) and old["policy_json"] == Jason.encode!(binding["policy"]),
         true <- hash(old["binding_json"]) == old["binding_sha256"],
         true <- Map.take(run, ~w(spec_revision contract_sha256)) == Map.take(binding, ~w(spec_revision contract_sha256)),
         true <- Map.take(task, ~w(role stage model reasoning_effort prompt_sha256)) == Map.take(binding, ~w(role stage model reasoning_effort prompt_sha256)),
         true <- Enum.all?(~w(item_id output_json output_sha256 consumed_at), &is_nil(old[&1])),
         true <- recovery_shutdown?(store, old, opts),
         true <- failure_matches?(old, task, opts),
         true <- opts[:automatic] == true or receipt(store, "new_request_key", old["request_key"]) == nil,
         [pending] <- WorkerEvidence.pending(store, run["run_id"]),
         true <- pending["request_key"] == old["request_key"],
         :ok <- human_clear(store, run["run_id"]),
         :ok <- WorkerEvidence.checks_stopped(store, old["reservation_key"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :failed_retry_not_eligible}
    end
  end

  defp interrupted_mode?(opts), do: opts[:manual_interrupted] == true and opts[:automatic] != true
  defp schema_mode?(opts), do: get_in(opts[:schema_confirmation] || %{}, ["kind"]) == "SOURCE_COMPLETION_SCHEMA_REJECTION_V1" and opts[:automatic] != true
  defp guarded_mode?(opts), do: interrupted_mode?(opts) or schema_mode?(opts)
  defp recovery_stage(opts), do: if(schema_mode?(opts), do: "REPAIRING", else: "WRITING")

  defp schema_scope_current(store, old, opts) do
    if schema_mode?(opts) do
      with {:ok, scope} <- TicketCompletionConfirmation.schema_recovery_scope(store, old),
           true <- scope == Map.delete(opts[:schema_confirmation], "operator_tick") do
        :ok
      else
        _ -> {:error, :completion_schema_recovery_not_authorized}
      end
    else
      :ok
    end
  end

  defp recovery_kind(opts), do: if(interrupted_mode?(opts), do: "INTERRUPTED_TURN_QUIESCENCE", else: "FAILED_TURN_QUIESCENCE")

  defp failure_matches?(old, task, opts) do
    if interrupted_mode?(opts),
      do:
        (old["failure_code"] == @closed_connection and task["failure_code"] == inspect(:worker_observation_failed)) or
          (old["failure_code"] in [@closed_connection_exception, @sqlite_rollback_exception] and task["failure_code"] == old["failure_code"]),
      else: String.starts_with?(old["failure_code"] || "", "{:worker_turn_error,") and old["failure_code"] == task["failure_code"]
  end

  defp recovery_instruction(opts) do
    if schema_mode?(opts) do
      "The prior read-only confirmation was rejected before execution because its provider response schema was incompatible. This is the single explicitly authorized schema-only successor. Inspect the unchanged candidate read-only and genuinely return COMPLETE with changed_paths [] and commit_message null, or BLOCKED. Do not edit, run tests, claim acceptance, or return CONTINUE. The controller owns all remaining validation and delivery."
    else
      ordinary_recovery_instruction(opts)
    end
  end

  defp ordinary_recovery_instruction(opts) do
    failure =
      if interrupted_mode?(opts),
        do: "The prior native turn was interrupted after a controller connection loss; no completed slice was recorded.",
        else: "The prior turn failed with provider capacity, not a product blocker."

    failure <>
      " Preserve all existing partial edits, read the current files before further edits, and finish the same slice under this unchanged contract/plan/model. Do not replay prior tool calls. This is controller recovery, not new human product input."
  end

  defp recovery_shutdown?(store, old, opts) do
    absent = is_nil(old["owner_stopped_at"]) and is_nil(old["owner_stop_json"])

    cond do
      schema_mode?(opts) -> WorkerEvidence.owner_stopped?(store, old)
      opts[:automatic] == true -> WorkerEvidence.owner_stopped?(store, old)
      interrupted_mode?(opts) -> absent or WorkerEvidence.owner_stopped?(store, old)
      true -> absent
    end
  end

  defp packet_matches?(store, old, base) do
    case receipt(store, "new_request_key", old["request_key"]) do
      nil ->
        hash(base) == Jason.decode!(old["binding_json"])["input_sha256"]

      prior ->
        {:ok, predecessor} = WorkerEvidence.get(store, prior["old_request_key"])
        superseded?(store, predecessor) and hash(prior["prompt"]) == Jason.decode!(old["binding_json"])["input_sha256"] and Jason.decode!(prior["prompt"])["base_packet"] == Jason.decode!(base)
    end
  end

  defp retry_policy(store, old, native, opts) do
    if opts[:automatic] do
      automatic_retry_policy(store, old, native, opts)
    else
      {:ok, %{"mode" => "MANUAL_ONE_SHOT", "automatic_attempt" => 0, "root_request_key" => old["request_key"]}}
    end
  end

  defp automatic_retry_policy(store, old, native, opts) do
    previous = receipt(store, "new_request_key", old["request_key"]) || %{}
    policy = previous["retry_policy"] || %{}
    count = policy["automatic_attempt"] || 0
    now = recovery_now(opts)
    completed = native["completed_at"]

    with true <- is_integer(count) and count >= 0 and count < 3,
         true <- completed <= DateTime.to_unix(now),
         due = completed + Enum.at([300, 900, 1800], count),
         true <- DateTime.to_unix(now) >= due do
      {:ok, %{"mode" => "AUTOMATIC", "automatic_attempt" => count + 1, "max_attempts" => 3, "not_before" => due, "root_request_key" => policy["root_request_key"] || old["request_key"]}}
    else
      false when count >= 3 -> {:error, :failed_retry_budget_exhausted}
      _ -> {:error, :failed_retry_cooldown}
    end
  end

  defp human_clear(store, run) do
    question = Store.one!(store, "SELECT question_key FROM ticket_chat_questions WHERE run_id = ? AND status = 'OPEN' LIMIT 1", [run])
    command = Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING','ACCEPTED') LIMIT 1", [run])
    amendment = Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND active_owner = 1 LIMIT 1", [run])
    if question == nil and command == nil and amendment == nil, do: :ok, else: {:error, :failed_retry_human_input_pending}
  end

  defp native_failed(old, opts) do
    with {:ok, opts} <- runtime_options(old, opts),
         {:ok, native} <- if(schema_mode?(opts), do: native_schema_failed(old, opts), else: native_failed_standard(old, opts)),
         {:ok, _} <- runtime_options(old, opts),
         do: {:ok, native}
  end

  defp runtime_options(old, opts) do
    with true <- hash(old["binding_json"]) == old["binding_sha256"] or {:error, :worker_evidence_corrupt},
         {:ok, binding} <- Jason.decode(old["binding_json"]),
         do: WorkerEvidence.runtime_options(binding, opts)
  end

  defp native_failed_standard(old, opts) do
    thread = old["thread_id"]

    with {:ok, history} <- native_history(opts),
         true <- File.regular?(history),
         true <- is_binary(thread) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, thread),
         {raw, 0} <-
           System.cmd(
             "/usr/bin/sqlite3",
             [
               "-readonly",
               "-json",
               history,
               "SELECT thread_id,turn_id,rollout_ordinal,status,error_json,completed_at,final_agent_item_id FROM thread_turns WHERE thread_id='#{thread}' ORDER BY rollout_ordinal DESC LIMIT 1;"
             ],
             stderr_to_stdout: true
           ),
         {:ok, [native]} <- Jason.decode(raw),
         true <- native["turn_id"] == old["turn_id"] and is_integer(native["completed_at"]) and is_nil(native["final_agent_item_id"]),
         true <- native_failure_matches?(old, native, opts) do
      {:ok, native}
    else
      _ -> {:error, :failed_retry_native_turn_unproven}
    end
  end

  defp native_schema_failed(old, opts) do
    thread = old["thread_id"]

    sql =
      "SELECT thread_id,turn_id,rollout_ordinal,status,error_json,completed_at,final_agent_item_id,rollout_end_ordinal,rollout_byte_offset,rollout_end_byte_offset,(SELECT json_group_array(json(item_json)) FROM (SELECT item_json FROM thread_items i WHERE i.thread_id=t.thread_id AND i.turn_id=t.turn_id ORDER BY rollout_ordinal)) AS schema_items_json FROM thread_turns t WHERE thread_id='#{thread}' ORDER BY rollout_ordinal DESC LIMIT 1;"

    with true <- is_binary(thread) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, thread),
         {:ok, history} <- native_history(opts),
         true <- File.regular?(history),
         {raw, 0} <- System.cmd("/usr/bin/sqlite3", ["-readonly", "-json", history, sql], stderr_to_stdout: true),
         {:ok, [native]} <- Jason.decode(raw),
         true <- native["turn_id"] == old["turn_id"] and native["status"] == "failed",
         true <- complete_schema_span?(native),
         :ok <- schema_error_matches(old, native, opts),
         true <- original_schema_input?(old, native) do
      {:ok, native}
    else
      _ -> {:error, :completion_schema_native_rejection_unproven}
    end
  end

  defp complete_schema_span?(native) do
    fields = ~w(completed_at rollout_ordinal rollout_end_ordinal rollout_byte_offset rollout_end_byte_offset)

    Enum.all?(fields, &is_integer(native[&1])) and is_nil(native["final_agent_item_id"]) and
      native["rollout_end_ordinal"] >= native["rollout_ordinal"] and
      native["rollout_end_byte_offset"] > native["rollout_byte_offset"]
  end

  defp schema_error_matches(old, native, opts) do
    with raw when is_binary(raw) <- native["error_json"],
         true <- hash(raw) == get_in(opts[:schema_confirmation], ["authorization", "native_error_sha256"]),
         {:ok, %{"message" => message} = error} when is_binary(message) <- Jason.decode(raw),
         true <- old["failure_code"] == inspect({:worker_turn_error, error}),
         {:ok, %{"status" => 400, "error" => %{"type" => "invalid_request_error", "code" => "invalid_json_schema", "param" => "text.format.schema"}}} <- Jason.decode(message) do
      :ok
    else
      _ -> {:error, :completion_schema_native_rejection_unproven}
    end
  end

  defp original_schema_input?(old, native) do
    with raw when is_binary(raw) <- native["schema_items_json"],
         {:ok, [%{"type" => "userMessage", "content" => content}]} <- Jason.decode(raw),
         true <- is_list(content) and content != [],
         true <- Enum.all?(content, &(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"]))) do
      binding = Jason.decode!(old["binding_json"])
      hash(Enum.map_join(content, & &1["text"])) == binding["input_sha256"]
    else
      _ -> false
    end
  end

  defp native_failure_matches?(old, native, opts) do
    if interrupted_mode?(opts) do
      native["status"] == "interrupted" and is_nil(native["error_json"]) and old["failure_code"] in [@closed_connection, @closed_connection_exception, @sqlite_rollback_exception]
    else
      with "failed" <- native["status"],
           {:ok, error} when is_map(error) <- Jason.decode(native["error_json"] || "null") do
        error["codexErrorInfo"] == "serverOverloaded" and old["failure_code"] == inspect({:worker_turn_error, error})
      else
        _ -> false
      end
    end
  end

  defp quiescent(store, old) do
    process = Jason.decode!(old["owner_process_json"])
    root = Jason.decode!(old["binding_json"])["policy"]["cwd"]

    with true <- TaskLauncher.active_owner(old["task_key"]) in [nil, self()],
         true <- is_binary(process["pid"]) and Regex.match?(~r/\A[0-9]+\z/, process["pid"]),
         {_raw, 1} <- System.cmd("/bin/ps", ["-p", process["pid"], "-o", "pid="], stderr_to_stdout: true),
         {"", 1} <- System.cmd("/usr/sbin/lsof", ["-w", "-a", "-d", "cwd", "+d", root, "-Fpcn"], stderr_to_stdout: true),
         nil <-
           Store.one!(
             store,
             "SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence e ON e.request_key=op.request_key WHERE e.run_id=? AND (op.io_pending=1 OR op.phase='PREPARED') LIMIT 1",
             [old["run_id"]]
           ),
         :ok <- WorkerEvidence.checks_stopped(store, old["reservation_key"]) do
      :ok
    else
      _ -> {:error, :failed_retry_owner_or_io_active}
    end
  end

  defp files(store, old, access) do
    lineage = lineage(store, old)

    operations =
      Enum.flat_map(lineage, fn evidence ->
        result = Store.query!(store, "SELECT * FROM worker_file_operations WHERE request_key = ? ORDER BY rowid", [evidence["request_key"]])
        Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
      end)

    with true <- Enum.all?(operations, &(&1["phase"] == "APPLIED" and &1["io_pending"] == 0)),
         true <-
           Enum.all?(operations, fn operation ->
             evidence = Enum.find(lineage, &(&1["request_key"] == operation["request_key"]))
             {:ok, original_access} = WorkspaceAccess.get(store, evidence["reservation_key"])
             receipt_valid?(operation, evidence, original_access)
           end),
         groups = Enum.group_by(operations, & &1["path"]),
         true <- Enum.all?(groups, &digest_chain_valid?/1),
         {:ok, pending} <- Worktree.pending_source_paths(access["canonical_path"]),
         true <- pending == Enum.sort(Map.keys(groups)),
         latest = Enum.map(groups, fn {_path, rows} -> List.last(rows) end) |> Enum.sort_by(& &1["path"]),
         :ok <- current_files(access, latest) do
      {:ok, latest}
    else
      _ -> {:error, :failed_retry_files_unproven}
    end
  end

  defp digest_chain_valid?({_path, rows}) do
    rows |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a["after_sha256"] == b["before_sha256"] end)
  end

  defp lineage(store, old) do
    case receipt(store, "new_request_key", old["request_key"]) do
      nil ->
        [old]

      prior ->
        {:ok, predecessor} = WorkerEvidence.get(store, prior["old_request_key"])
        if superseded?(store, predecessor), do: lineage(store, predecessor) ++ [old], else: raise("failed retry lineage changed")
    end
  end

  defp receipt_valid?(row, old, access) do
    with {:ok, binding} <- Jason.decode(row["io_binding_json"] || "null"),
         true <- Map.take(binding, ~w(request_key call_id path before_sha256 after_sha256)) == Map.take(row, ~w(request_key call_id path before_sha256 after_sha256)),
         true <-
           {binding["worker_thread_id"], binding["worker_turn_id"], binding["worker_binding_sha256"], binding["worker_process_sha256"], binding["reservation_key"], binding["generation"]} ==
             {old["thread_id"], old["turn_id"], old["binding_sha256"], hash(old["owner_process_json"]), access["reservation_key"], access["generation"]},
         {_, _, receipt} <- WorkerFileIO.recover_mutation(binding),
         true <- Jason.encode!(receipt) == row["io_receipt_json"] do
      true
    else
      _ -> false
    end
  end

  defp current_files(access, rows) do
    root = Jason.decode!(access["binding_json"])

    if Enum.all?(rows, fn row ->
         case WorkerFileIO.request(access["canonical_path"], root, "digest", %{"path" => row["path"]}) do
           {:ok, %{"sha256" => sha}, _} -> sha == row["after_sha256"]
           _ -> false
         end
       end), do: :ok, else: {:error, :failed_retry_bytes_changed}
  end

  @doc false
  @spec transfer_authority(Store.connection(), map()) :: :ok | {:error, term()}
  def transfer_authority(store, proof) do
    with true <- find(store, "TICKET_FAILED_TURN_RECOVERY_AUTHORIZED", "recovery_key", proof["recovery_key"]) == proof and receipt(store, "old_request_key", proof["old_request_key"]) == nil,
         {:ok, old} <- WorkerEvidence.get(store, proof["old_request_key"]),
         options = recovery_options(proof, native_queue: proof["native_queue"]),
         :ok <- schema_scope_current(store, old, options),
         :ok <- schema_tick_current(store, proof),
         :ok <- interrupted_transfer_current(old, options) do
      :ok
    else
      _ -> {:error, :failed_retry_transfer_unproven}
    end
  end

  defp schema_tick_current(store, %{"schema_confirmation" => scope}) do
    with {:ok, _} <- TicketPushRecovery.tick_binding(store, operator_tick: scope["operator_tick"]), do: :ok
  end

  defp schema_tick_current(_store, _proof), do: :ok

  defp recovery_options(proof, opts) do
    opts = Keyword.put(opts, :manual_interrupted, proof["kind"] == "INTERRUPTED_TURN_QUIESCENCE")
    if is_map(proof["schema_confirmation"]), do: Keyword.merge(opts, schema_confirmation: proof["schema_confirmation"], automatic: false), else: opts
  end

  @spec superseded?(Store.connection(), map()) :: boolean()
  def superseded?(store, old) do
    with proof when is_map(proof) <- receipt(store, "old_request_key", old["request_key"]),
         true <- Map.drop(proof, ~w(new_generation new_binding_sha256)) == find(store, "TICKET_FAILED_TURN_RECOVERY_AUTHORIZED", "recovery_key", proof["recovery_key"]),
         true <- hash(Jason.encode!(old)) == proof["old_evidence_sha256"],
         {:ok, access} <- WorkspaceAccess.get(store, old["reservation_key"]),
         true <- is_binary(access["released_at"]),
         {:ok, transfer} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- transfer == Map.take(proof, ~w(kind recovery_key old_request_key new_request_key new_reservation_key)),
         {:ok, new} <- WorkerEvidence.get(store, proof["new_request_key"]),
         true <- new["binding_sha256"] == proof["new_binding_sha256"] and hash(new["binding_json"]) == proof["new_binding_sha256"],
         true <- hash(old["binding_json"]) == old["binding_sha256"] and WorkerEvidence.runtime_matches?(Jason.decode!(old["binding_json"]), Jason.decode!(new["binding_json"])),
         {:ok, new_access} <- WorkspaceAccess.get(store, proof["new_reservation_key"]),
         true <- new_access["generation"] == proof["new_generation"] and new_access["request_key"] == new["request_key"] do
      new["run_id"] == old["run_id"] and new["task_key"] == old["task_key"] and new["reservation_key"] == proof["new_reservation_key"]
    else
      _ -> false
    end
  end

  @spec prepared(Store.connection(), String.t(), String.t()) :: {:ok, map()} | :none | {:error, term()}
  def prepared(store, run, base_prompt) do
    case Enum.find(WorkerEvidence.pending(store, run), &(&1["status"] == "RESERVED")) do
      nil ->
        :none

      attempt ->
        case receipt(store, "new_request_key", attempt["request_key"]) do
          nil ->
            :none

          proof ->
            if Jason.decode!(proof["prompt"])["base_packet"] == Jason.decode!(base_prompt), do: {:ok, proof}, else: {:error, :failed_retry_packet_changed}
        end
    end
  end

  @spec start_preflight(Store.connection(), map(), keyword()) :: :ok | {:error, term()}
  def start_preflight(store, proof, opts \\ []) do
    with {:ok, observed_opts} <- start_observation(store, proof, opts) do
      start_preflight_observed(store, proof, observed_opts)
    end
  end

  @doc "Reads interruption queue metadata before the caller checks out a database transaction."
  @spec start_observation(Store.connection(), map(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def start_observation(store, proof, opts) do
    opts = recovery_options(proof, opts)

    with {:ok, old} <- WorkerEvidence.get(store, proof["old_request_key"]),
         {:ok, opts} <- runtime_options(old, opts),
         {:ok, opts} <- fresh_interrupted_start(old, opts),
         :ok <- frozen_queue_matches(proof, opts) do
      {:ok, opts}
    end
  end

  defp frozen_queue_matches(%{"kind" => "INTERRUPTED_TURN_QUIESCENCE"} = proof, opts) do
    compare_frozen_queue(proof, opts)
  end

  defp frozen_queue_matches(%{"schema_confirmation" => %{}} = proof, opts), do: compare_frozen_queue(proof, opts)
  defp frozen_queue_matches(_proof, _opts), do: :ok

  defp compare_frozen_queue(proof, opts) do
    if Map.take(proof["native_queue"] || %{}, ~w(persisted_queue writer_lock)) == Map.take(opts[:native_queue] || %{}, ~w(persisted_queue writer_lock)),
      do: :ok,
      else: {:error, :failed_retry_start_unproven}
  end

  @doc "Rechecks interrupted recovery on its own native actor immediately before the requested turn starts."
  @spec owned_session_preflight(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def owned_session_preflight(store, proof, session, opts) do
    opts = recovery_options(proof, opts)

    with true <- guarded_mode?(opts),
         true <- receipt(store, "new_request_key", proof["new_request_key"]) == proof,
         {:ok, old} <- WorkerEvidence.get(store, proof["old_request_key"]),
         {:ok, opts} <- runtime_options(old, opts),
         reader = owned_reader(opts),
         :ok <- schema_scope_current(store, old, opts),
         true <- superseded?(store, old),
         {:ok, current} <- WorkerEvidence.get(store, proof["new_request_key"]),
         true <- current["status"] == "THREAD_BOUND" and current["thread_id"] == session.thread_id,
         true <- Jason.decode!(current["owner_process_json"]) == %{"pid" => session.metadata.codex_app_server_pid, "invocation_nonce" => session.worker_invocation},
         :ok <- human_clear(store, old["run_id"]),
         {:ok, native} <- native_failed(old, opts),
         true <- native == proof["native"],
         {:ok, observed} <- reader.read_owned_native_thread(session),
         true <- get_in(observed, ["status", "type"]) == "idle",
         :ok <- queue_valid?(old, observed, opts),
         :ok <- owned_inputs_current(store, proof, session),
         fresh = Map.put(observed, "persisted_queue", proof["native_queue"]["persisted_queue"]),
         :ok <- interrupted_queue_current(old, Keyword.put(opts, :native_queue, fresh)) do
      :ok
    else
      _ -> {:error, :interrupted_owned_session_preflight_failed}
    end
  end

  defp owned_inputs_current(store, proof, session) do
    with {:ok, run} <- RunLedger.get(store, proof["run"]["run_id"]),
         true <- Map.take(run, @run_fields) == proof["run"],
         {:ok, current} <- WorkerEvidence.get(store, proof["new_request_key"]),
         true <- current["status"] == "THREAD_BOUND" and current["thread_id"] == session.thread_id,
         {:ok, task} <- TaskLedger.get(store, current["task_key"]),
         true <- task["prompt_sha256"] == proof["new_prompt_sha256"],
         {:ok, access} <- WorkspaceAccess.validate(store, proof["new_reservation_key"], proof["new_generation"]),
         {:ok, head} <- WorkerEvidence.checkout_head(access),
         {:ok, old} <- WorkerEvidence.get(store, proof["old_request_key"]),
         true <- recovery_head_matches?(head, run, Jason.decode!(old["binding_json"])),
         {:ok, pending} <- Worktree.pending_source_paths(access["canonical_path"]),
         true <- pending == Enum.map(proof["files"], & &1["path"]),
         :ok <- current_files(access, proof["files"]),
         :ok <- human_clear(store, run["run_id"]) do
      :ok
    else
      _ -> {:error, :interrupted_owned_session_preflight_failed}
    end
  end

  defp fresh_interrupted_start(old, opts) do
    if guarded_mode?(opts) do
      case read_interrupted_queue(old, opts) do
        {:ok, queue} -> {:ok, Keyword.put(opts, :native_queue, queue)}
        {:error, _} -> {:error, :failed_retry_start_unproven}
      end
    else
      {:ok, opts}
    end
  end

  @doc "Checks the previously read queue snapshot without opening a native client inside the transaction."
  @spec start_preflight_observed(Store.connection(), map(), keyword()) :: :ok | {:error, term()}
  def start_preflight_observed(store, proof, opts) do
    opts = recovery_options(proof, opts)

    with :ok <- frozen_queue_matches(proof, opts),
         true <- receipt(store, "new_request_key", proof["new_request_key"]) == proof,
         {:ok, old} <- WorkerEvidence.get(store, proof["old_request_key"]),
         :ok <- schema_scope_current(store, old, opts),
         true <- superseded?(store, old),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         true <- Map.take(run, @run_fields) == proof["run"],
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         true <- task["thread_id"] == proof["thread_id"] and task["prompt_sha256"] == proof["new_prompt_sha256"],
         :ok <- human_clear(store, run["run_id"]),
         {:ok, native} <- native_failed(old, opts),
         true <- native == proof["native"],
         :ok <- quiescent(store, old),
         {:ok, access} <- WorkspaceAccess.validate(store, proof["new_reservation_key"], proof["new_generation"]),
         {:ok, head} <- WorkerEvidence.checkout_head(access),
         true <- recovery_head_matches?(head, run, Jason.decode!(old["binding_json"])),
         {:ok, pending} <- Worktree.pending_source_paths(access["canonical_path"]),
         true <- pending == Enum.map(proof["files"], & &1["path"]),
         :ok <- current_files(access, proof["files"]),
         :ok <- interrupted_queue_current(old, opts) do
      :ok
    else
      _ -> {:error, :failed_retry_start_unproven}
    end
  end

  defp recovery_head_matches?(head, run, binding) do
    head == binding["expected_sha"] and
      (head == run["candidate_sha"] or
         (is_nil(run["candidate_sha"]) and run["implementation_iteration"] == 0 and
            is_nil(run["candidate_handoff"]) and head == binding["base_sha"]))
  end

  defp receipt(store, field, value), do: find(store, @event, field, value)

  defp find(store, type, field, value) do
    Store.query!(store, "SELECT payload_json FROM events WHERE event_type = ? ORDER BY rowid DESC", [type]).rows |> Enum.map(fn [raw] -> Jason.decode!(raw) end) |> Enum.find(&(&1[field] == value))
  end

  defp persist(store, run, event, proof),
    do: Store.query!(store, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES(?,?,?,?)", [DateTime.to_iso8601(DateTime.utc_now()), event, run, Jason.encode!(proof)])

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp transaction(store, fun) do
    case Exqlite.transaction(
           store,
           fn tx ->
             case fun.(tx) do
               {:error, reason} -> Exqlite.rollback(tx, reason)
               value -> value
             end
           end,
           timeout: 60_000
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
