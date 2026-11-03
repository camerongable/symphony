defmodule SymphonyElixir.Factory.WorkspaceAccess do
  @moduledoc "Durable, exclusive checkout ownership independent of task keys and model lifetimes."

  alias SymphonyElixir.Factory.{
    Capacity,
    NativeWorkspaceMaintenance,
    RunLedger,
    Store,
    TaskLedger,
    TicketCapabilityRecovery,
    TicketChatCommands,
    TicketContractAmendment,
    Worktree
  }

  alias SymphonyElixir.Factory.{TicketChat, TicketJiraJournal, TicketPushIO, WorkerEvidence, WorkerFileIO}
  alias SymphonyElixir.Factory.TicketPushOrdinaryRejection
  alias SymphonyElixir.Factory.TicketPushPreissuanceRejection
  alias SymphonyElixir.Factory.TicketPushRequalification
  alias SymphonyElixir.PathSafety

  @fields ~w(reservation_key run_id task_key request_key mode allowed_root expected_sha)
  @active ~w(STARTING RUNNING WAITING_FOR_WRITER WAITING_FOR_BROKER)
  @typep access_result :: {:ok, map()} | {:error, term()}

  @spec acquire(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def acquire(store, attrs, opts \\ []) do
    transaction(store, fn tx -> acquire_transaction(tx, attrs, opts) end)
  end

  @doc "Observes the checkout before atomically claiming it and committing SQL-only caller state."
  @spec acquire_with(Store.connection(), map(), keyword(), (Store.connection(), map() -> term())) :: term()
  def acquire_with(%DBConnection{}, _attrs, _opts, _commit), do: {:error, :workspace_observation_inside_transaction}

  def acquire_with(store, attrs, opts, commit) do
    acquire_with_observation(store, attrs, opts, fn -> {:ok, nil} end, fn tx, access, _ -> commit.(tx, access) end)
  end

  @doc "Captures short-lived caller evidence after physical admission, outside SQLite, for the final SQL-only commit."
  @spec acquire_with_observation(Store.connection(), map(), keyword(), (-> {:ok, term()} | {:error, term()}), (Store.connection(), map(), term() -> term())) :: term()
  def acquire_with_observation(%DBConnection{}, _attrs, _opts, _observe, _commit), do: {:error, :workspace_observation_inside_transaction}

  def acquire_with_observation(store, attrs, opts, capture, commit) do
    with :ok <- valid_attrs(attrs),
         {:ok, run} <- RunLedger.get(store, attrs["run_id"]),
         {:ok, task} <- task_binding(store, attrs),
         :ok <- before_acquisition_observation(opts),
         {:ok, observed} <- observe(run, true, attrs["expected_sha"]),
         :ok <- within_root(observed.path, attrs["allowed_root"]),
         :ok <- WorkerFileIO.workspace_allowed?(store, observed.path),
         :ok <- acquisition_checkpoint(opts, :after_acquisition_observation),
         :ok <- acquisition_root_current(observed),
         {:ok, fresh} <- observe(run, true, attrs["expected_sha"]),
         true <- fresh == observed or {:error, :workspace_identity_changed},
         {:ok, physical} <- acquisition_physical_identity(observed),
         {:ok, captured} <- capture_observation(capture) do
      transaction(store, fn tx ->
        with {:ok, current} <- RunLedger.get(tx, attrs["run_id"]),
             true <- current == run or {:error, :workspace_acquisition_input_changed},
             {:ok, current_task} <- task_binding(tx, attrs),
             true <- current_task == task or {:error, :workspace_acquisition_task_changed},
             :ok <- acquisition_root_current(observed),
             :ok <- within_root(observed.path, attrs["allowed_root"]),
             {:ok, current_physical} <- acquisition_physical_identity(observed),
             true <- current_physical == physical or {:error, :workspace_identity_changed},
             {:ok, access} <- acquire_observed(tx, attrs, opts, run, task, observed) do
          commit.(tx, access, captured)
        end
      end)
    end
  end

  defp capture_observation(capture) do
    case capture.() do
      {:ok, _} = result -> result
      {:error, _} = error -> error
      _ -> {:error, :workspace_observation_invalid}
    end
  end

  if Mix.env() == :test do
    defp acquisition_checkpoint(opts, key) do
      case opts[key] do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end
    end
  else
    defp acquisition_checkpoint(_opts, _key), do: :ok
  end

  defp before_acquisition_observation(opts), do: acquisition_checkpoint(opts, :before_acquisition_observation)

  @doc "Carries actual stopped push readback into an atomic claim callback without reading a helper inside SQLite."
  @spec acquire_with_push_receipt(Store.connection(), map(), keyword(), map(), function()) :: term()
  def acquire_with_push_receipt(%DBConnection{}, _attrs, _opts, _intent, _commit), do: {:error, :workspace_observation_inside_transaction}

  def acquire_with_push_receipt(store, attrs, opts, intent, commit) do
    with {:ok, run} <- RunLedger.get(store, attrs["run_id"]),
         {:ok, current_intent} <- Jason.decode(run["candidate_handoff"] || "null"),
         true <- (current_intent == intent and intent["phase"] == "PUSH_UNCERTAIN" and intent["reservation_key"] == attrs["reservation_key"]) or {:error, :controller_push_completion_unproven},
         {:ok, raw} <- TicketPushIO.readback(intent),
         true <- TicketPushIO.receipt_valid?(raw, intent) or {:error, :controller_push_receipt_unproven} do
      acquire_with(store, attrs, opts, fn tx, access ->
        with {:ok, current} <- RunLedger.get(tx, attrs["run_id"]),
             true <- (current == run and access["generation"] == intent["reservation_generation"]) or {:error, :controller_push_completion_unproven} do
          release = fn -> release_push_observed(tx, attrs["run_id"], attrs["reservation_key"], access["generation"], access, raw) end
          commit.(tx, access, raw, release)
        end
      end)
    end
  end

  defp acquisition_root_current(observed) do
    with {:ok, path} <- PathSafety.canonicalize(observed.path),
         {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
         true <- path == observed.path and {stat.major_device, stat.inode} == {observed.root_device, observed.root_inode} do
      :ok
    else
      _ -> {:error, :workspace_root_identity_changed}
    end
  end

  defp acquisition_physical_identity(observed) do
    Enum.reduce_while([observed.path, observed.git_dir, observed.common_dir], {:ok, []}, fn path, {:ok, identities} ->
      with {:ok, ^path} <- PathSafety.canonicalize(path),
           {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path) do
        {:cont, {:ok, [{path, stat.major_device, stat.inode} | identities]}}
      else
        _ -> {:halt, {:error, :workspace_identity_changed}}
      end
    end)
  end

  defp acquire_observed(store, attrs, opts, run, task, observed) do
    case get_row(store, attrs["reservation_key"]) do
      nil ->
        insert_observed(store, attrs, opts, run, task, observed)

      row ->
        with {:ok, _} <- replay(row, attrs),
             true <- {row["canonical_path"], row["git_dir"], row["common_dir"]} == {observed.path, observed.git_dir, observed.common_dir} or {:error, :workspace_identity_changed},
             {:ok, binding} <- Jason.decode(row["binding_json"]),
             true <- same_root?(observed, binding) or {:error, :workspace_root_identity_changed},
             true <- Map.take(run, ~w(spec_revision contract_sha256 branch)) == Map.take(binding, ~w(spec_revision contract_sha256 branch)) or {:error, :workspace_input_changed},
             :ok <- admitted_sha(store, run, task, attrs),
             :ok <- checkout_intent_available(store, observed, run["branch"], nil),
             :ok <- NativeWorkspaceMaintenance.checkout_available(store, attrs["run_id"]),
             :ok <- current_task(store, row, binding),
             :ok <- current_initial_base(store, row, binding, run) do
          {:ok, row}
        end
    end
  end

  defp acquire_transaction(store, attrs, opts) do
    with :ok <- valid_attrs(attrs) do
      case get_row(store, attrs["reservation_key"]) do
        nil ->
          acquire_new(store, attrs, opts)

        row ->
          replay_current(store, row, attrs)
      end
    end
  end

  defp replay_current(store, row, attrs) do
    with {:ok, _} <- replay(row, attrs),
         {:ok, _} <- validate(store, row["reservation_key"], row["generation"]) do
      {:ok, row}
    end
  end

  defp acquire_new(store, attrs, opts) do
    with :ok <- valid_attrs(attrs),
         {:ok, run} <- RunLedger.get(store, attrs["run_id"]),
         :ok <- before_acquisition_observation(opts),
         {:ok, observed} <- observe(run, true, attrs["expected_sha"]),
         :ok <- checkout_intent_available(store, observed, run["branch"], nil),
         :ok <- within_root(observed.path, attrs["allowed_root"]),
         :ok <- WorkerFileIO.workspace_allowed?(store, observed.path),
         {:ok, task} <- task_binding(store, attrs),
         :ok <- admitted_sha(store, run, task, attrs) do
      insert_observed(store, attrs, opts, run, task, observed)
    else
      {:error, _} = error -> error
    end
  end

  defp insert_observed(store, attrs, opts, run, task, observed) do
    with :ok <- checkout_intent_available(store, observed, run["branch"], nil),
         :ok <- admitted_sha(store, run, task, attrs) do
      binding = Map.merge(attrs, Map.merge(observed, Map.take(run, ~w(spec_revision contract_sha256 candidate_sha branch))))
      binding = Map.put(binding, "prompt_sha256", (task || %{})["prompt_sha256"])
      binding = Map.put(binding, "run_state", run["state"])

      with :ok <- NativeWorkspaceMaintenance.checkout_available(store, attrs["run_id"]),
           :ok <- competing_activity(store, observed.path, attrs["task_key"]),
           :ok <- capacity(store, run, attrs["mode"], opts),
           :ok <- unowned(store, observed) do
        previous = Store.one!(store, "SELECT COALESCE(MAX(generation), 0) AS generation FROM workspace_access WHERE canonical_path = ? OR git_dir = ?", [observed.path, observed.git_dir])
        generation = previous["generation"] + 1

        Store.query!(
          store,
          "INSERT INTO workspace_access(reservation_key, run_id, task_key, request_key, mode, generation, canonical_path, git_dir, common_dir, binding_json, acquired_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            attrs["reservation_key"],
            attrs["run_id"],
            attrs["task_key"],
            attrs["request_key"],
            attrs["mode"],
            generation,
            observed.path,
            observed.git_dir,
            observed.common_dir,
            Jason.encode!(binding),
            now()
          ]
        )

        {:ok, get_row(store, attrs["reservation_key"])}
      end
    end
  end

  defp valid_attrs(attrs) when is_map(attrs) do
    if Map.keys(attrs) -- @fields == [] and attrs["mode"] in ~w(SOURCE REVIEW MAINTENANCE) and
         Enum.all?(~w(reservation_key run_id request_key allowed_root expected_sha), &(is_binary(attrs[&1]) and attrs[&1] != "")) and String.match?(attrs["expected_sha"], ~r/^[a-f0-9]{40}$/),
       do: :ok,
       else: {:error, :invalid_workspace_reservation}
  end

  defp valid_attrs(_), do: {:error, :invalid_workspace_reservation}

  defp task_binding(_store, %{"mode" => "MAINTENANCE", "task_key" => nil}), do: {:ok, nil}

  defp task_binding(store, attrs) do
    with {:ok, task} <- TaskLedger.get(store, attrs["task_key"]),
         true <- task["run_id"] == attrs["run_id"] or {:error, :workspace_task_run_mismatch} do
      {:ok, task}
    end
  end

  defp replay(%{"released_at" => released}, _attrs) when not is_nil(released), do: {:error, :workspace_reservation_already_released}

  defp replay(row, attrs) do
    binding = Jason.decode!(row["binding_json"])
    if Map.take(binding, @fields) == attrs, do: {:ok, row}, else: {:error, :workspace_reservation_conflict}
  end

  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(store, key) do
    case get_row(store, key) do
      nil -> {:error, :unknown_workspace_reservation}
      row -> {:ok, row}
    end
  end

  @doc "Rechecks held checkout authority using only ledger facts; it does not observe the filesystem."
  @spec validate_held(Store.connection(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def validate_held(store, key, generation) do
    with {:ok, row} <- get(store, key),
         true <- (row["generation"] == generation and is_nil(row["released_at"])) or {:error, :stale_workspace_reservation},
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         {:ok, run} <- RunLedger.get(store, row["run_id"]),
         :ok <- current_task(store, row, binding),
         :ok <- current_initial_base(store, row, binding, run),
         :ok <- checkout_intent_available(store, %{path: row["canonical_path"], common_dir: row["common_dir"]}, run["branch"], nil),
         true <- Map.take(run, ~w(spec_revision contract_sha256 branch)) == Map.take(binding, ~w(spec_revision contract_sha256 branch)) or {:error, :workspace_input_changed} do
      {:ok, row}
    end
  end

  @spec validate(Store.connection(), String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(store, key, generation, opts \\ []) do
    with {:ok, row} <- get(store, key),
         true <- (row["generation"] == generation and is_nil(row["released_at"])) or {:error, :stale_workspace_reservation},
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         {:ok, run} <- RunLedger.get(store, row["run_id"]),
         :ok <- current_task(store, row, binding),
         :ok <- current_initial_base(store, row, binding, run),
         expected_sha = validation_sha(row, binding, run, opts),
         {:ok, observed} <- observe(run, row["mode"] != "SOURCE" or Keyword.get(opts, :clean, false), expected_sha),
         :ok <- checkout_intent_available(store, observed, run["branch"], nil),
         :ok <- WorkerFileIO.workspace_allowed?(store, observed.path),
         true <- {observed.path, observed.git_dir, observed.common_dir} == {row["canonical_path"], row["git_dir"], row["common_dir"]} or {:error, :workspace_identity_changed},
         true <- same_root?(observed, binding) or {:error, :workspace_root_identity_changed},
         true <- Map.take(run, ~w(spec_revision contract_sha256 branch)) == Map.take(binding, ~w(spec_revision contract_sha256 branch)) or {:error, :workspace_input_changed} do
      {:ok, row}
    end
  end

  @doc false
  @spec validate_blocked_amendment_predecessor(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_blocked_amendment_predecessor(store, receipt) do
    with true <- (is_map(receipt) and receipt["application_kind"] == "BLOCKED_WRITER_HELD") or {:error, :blocked_amendment_receipt_invalid},
         {:ok, amendment} <- TicketContractAmendment.get(store, receipt["command_key"]),
         {:ok, stored_receipt} <- Jason.decode(amendment["receipt_json"]),
         true <- stored_receipt == receipt or {:error, :blocked_amendment_receipt_changed},
         {:ok, predecessor} <- Jason.decode(receipt["blocked_predecessor_json"]),
         {:ok, prior_run} <- Jason.decode(receipt["prior_run_json"]),
         {:ok, source_run} <- TicketContractAmendment.blocked_source_preimage(store, receipt["command_key"]),
         {:ok, run} <- RunLedger.get(store, receipt["run_id"]),
         :ok <- blocked_amendment_predecessor_current(store, predecessor, source_run, prior_run, run, amendment) do
      :ok
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :blocked_amendment_predecessor_unproven}
  end

  defp blocked_amendment_predecessor_current(store, predecessor, source_run, prior_run, run, amendment) do
    with evidence when is_map(evidence) <- Jason.decode!(predecessor["evidence_json"]),
         task when is_map(task) <- Jason.decode!(predecessor["task_json"]),
         access when is_map(access) <- Jason.decode!(predecessor["access_json"]),
         evidence_binding when is_map(evidence_binding) <- Jason.decode!(predecessor["binding_json"]),
         access_binding when is_map(access_binding) <- Jason.decode!(access["binding_json"]),
         true <-
           row_matches_snapshot?(store, "worker_evidence", "request_key", predecessor["request_key"], predecessor["evidence_json"], predecessor["evidence_sha256"]),
         true <- row_matches_snapshot?(store, "factory_tasks", "task_key", task["task_key"], predecessor["task_json"], predecessor["task_sha256"]),
         true <-
           row_matches_snapshot?(store, "workspace_access", "reservation_key", access["reservation_key"], predecessor["access_json"], predecessor["access_sha256"]),
         true <-
           blocked_predecessor_rows_match?(
             evidence,
             task,
             access,
             evidence_binding,
             predecessor,
             %{source_run: source_run, prior_run: prior_run, run: run, amendment: amendment}
           ),
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         :ok <- current_task(store, access, access_binding),
         :ok <- current_initial_base(store, access, access_binding, run),
         {:ok, observed} <- observe(run, false, prior_run["candidate_sha"]),
         true <- {observed.path, observed.git_dir, observed.common_dir} == {access["canonical_path"], access["git_dir"], access["common_dir"]} or {:error, :workspace_identity_changed},
         true <- same_root?(observed, access_binding) or {:error, :workspace_root_identity_changed},
         :ok <- checkout_intent_available(store, observed, run["branch"], nil),
         :ok <- WorkerFileIO.workspace_allowed?(store, observed.path),
         :ok <- blocked_checkout_head_current(access, predecessor["checkout_head_sha"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_amendment_predecessor_unproven}
    end
  end

  defp blocked_checkout_head_current(_access, nil), do: :ok

  defp blocked_checkout_head_current(access, expected) do
    case WorkerEvidence.checkout_head(access) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :blocked_amendment_checkout_head_changed}
    end
  end

  defp blocked_predecessor_rows_match?(evidence, task, access, binding, predecessor, context) do
    output = Jason.decode!(predecessor["output_json"])

    blocked_evidence_matches?(evidence, predecessor, output) and blocked_task_matches?(evidence, task, binding) and
      blocked_access_matches?(evidence, task, access, context.run, binding) and
      blocked_binding_matches?(binding, context.source_run) and
      blocked_run_matches?(context.run, context.prior_run, context.amendment) and
      output["status"] == "BLOCKED"
  rescue
    _ -> false
  end

  defp blocked_evidence_matches?(evidence, predecessor, output) do
    evidence["request_key"] == predecessor["request_key"] and evidence["status"] == "RESULT_RECORDED" and
      evidence["output_json"] == predecessor["output_json"] and evidence["output_sha256"] == predecessor["output_sha256"] and
      evidence["binding_json"] == predecessor["binding_json"] and digest(evidence["output_json"]) == evidence["output_sha256"] and
      digest(evidence["binding_json"]) == evidence["binding_sha256"] and evidence["owner_stopped_at"] != nil and
      output["status"] == "BLOCKED"
  end

  defp blocked_task_matches?(evidence, task, binding) do
    expected = %{
      "task_key" => evidence["task_key"],
      "run_id" => evidence["run_id"],
      "role" => "feature-writer",
      "stage" => "WRITING",
      "status" => "COMPLETE",
      "thread_id" => evidence["thread_id"],
      "turn_id" => evidence["turn_id"],
      "output_json" => evidence["output_json"],
      "model" => binding["model"],
      "reasoning_effort" => binding["reasoning_effort"],
      "prompt_sha256" => binding["prompt_sha256"]
    }

    Map.take(task, Map.keys(expected)) == expected
  end

  defp blocked_access_matches?(evidence, task, access, run, binding) do
    access["reservation_key"] == evidence["reservation_key"] and access["request_key"] == evidence["request_key"] and
      access["task_key"] == task["task_key"] and access["run_id"] == run["run_id"] and access["mode"] == "SOURCE" and
      is_nil(access["released_at"]) and access["generation"] == binding["reservation_generation"]
  end

  defp blocked_binding_matches?(binding, prior_run),
    do:
      (binding["expected_sha"] == prior_run["candidate_sha"] or
         (is_nil(prior_run["candidate_sha"]) and is_binary(binding["expected_sha"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, binding["expected_sha"]))) and
        binding["spec_revision"] == prior_run["spec_revision"] and binding["contract_sha256"] == prior_run["contract_sha256"]

  defp blocked_run_matches?(run, prior_run, amendment) do
    prior_run["candidate_sha"] == amendment["candidate_sha"] and run["candidate_sha"] == amendment["candidate_sha"] and
      run["state"] == "WRITING" and run["spec_revision"] >= amendment["proposed_revision"] and
      {run["repo_path"], run["worktree"], run["branch"]} == {prior_run["repo_path"], prior_run["worktree"], prior_run["branch"]}
  end

  defp row_matches_snapshot?(store, table, key_column, key, raw, sha) do
    row = Store.one!(store, "SELECT * FROM #{table} WHERE #{key_column} = ?", [key])
    is_map(row) and Jason.encode!(row) == raw and digest(raw) == sha
  end

  defp same_root?(observed, binding), do: {observed.root_device, observed.root_inode} == {binding["root_device"], binding["root_inode"]}

  defp current_initial_base(store, %{"mode" => "MAINTENANCE"}, %{"candidate_sha" => nil} = binding, run) do
    if initial_maintenance_base?(store, run, binding), do: :ok, else: {:error, :workspace_candidate_binding_mismatch}
  end

  defp current_initial_base(_store, _row, _binding, _run), do: :ok

  defp validation_sha(%{"mode" => "SOURCE"}, _binding, run, opts),
    do: if(Keyword.get(opts, :candidate_adopted, false), do: run["candidate_sha"], else: nil)

  defp validation_sha(_row, binding, _run, _opts), do: binding["expected_sha"]

  @doc "Transfers a stopped BLOCKED writer lease without releasing the dirty checkout to general admission."
  @spec transfer_blocked_source(Store.connection(), String.t(), pos_integer(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def transfer_blocked_source(store, old_key, old_generation, attrs, blocked_proof) do
    transaction(store, fn tx ->
      with :ok <- valid_attrs(attrs),
           true <- attrs["mode"] == "SOURCE" or {:error, :blocked_resume_mode_invalid},
           {:ok, old} <- get(tx, old_key),
           true <- {old["mode"], old["generation"], old["released_at"]} == {"SOURCE", old_generation, nil} or {:error, :stale_workspace_reservation},
           {:ok, evidence} <- WorkerEvidence.get(tx, old["request_key"]),
           {:ok, task} <- TaskLedger.get(tx, old["task_key"]),
           {:ok, run} <- RunLedger.get(tx, old["run_id"]),
           :ok <- blocked_resume_proof(tx, old, evidence, task, run, attrs, blocked_proof),
           :ok <- validate_blocked_resume_source(tx, old_key, old_generation, blocked_proof),
           {:ok, observed} <- observe(run, false, run["candidate_sha"]),
           true <- {observed.path, observed.git_dir, observed.common_dir} == {old["canonical_path"], old["git_dir"], old["common_dir"]} or {:error, :workspace_identity_changed},
           :ok <- within_root(observed.path, attrs["allowed_root"]),
           :ok <- WorkerFileIO.workspace_allowed?(tx, observed.path),
           :ok <- retire_blocked_source(tx, old, attrs, blocked_proof),
           {:ok, inserted} <- insert_transferred_source(tx, old, attrs, observed, task, run, blocked_proof) do
        {:ok, inserted}
      else
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Transfers only a TCAP source whose checkout and native admission were observed before this transaction."
  @spec transfer_capability_source(Store.connection(), String.t(), pos_integer(), map(), map()) :: access_result()
  def transfer_capability_source(%DBConnection{} = tx, old_key, generation, attrs, %{"operational_recovery_key" => "TCAP-" <> _} = proof) do
    with :ok <- valid_attrs(attrs),
         {:ok, verified} <- TicketCapabilityRecovery.checked(tx, proof),
         old = verified.facts.access,
         true <- old["reservation_key"] == old_key and old["generation"] == generation and is_nil(old["released_at"]),
         destination = verified.checked["destination"],
         true <- {attrs["request_key"], attrs["reservation_key"], proof["new_prompt_sha256"]} == {destination["request_key"], destination["reservation_key"], destination["prompt_sha256"]},
         {:ok, old_binding} <- Jason.decode(old["binding_json"]),
         true <- attrs["allowed_root"] == old_binding["allowed_root"] and attrs["expected_sha"] == verified.facts.run["candidate_sha"],
         :ok <- blocked_resume_proof(tx, old, verified.facts.evidence, verified.facts.task, verified.facts.run, attrs, proof),
         {:ok, observed} <- TicketCapabilityRecovery.checkout(tx, proof),
         %{"generation" => maximum} <- Store.one!(tx, "SELECT MAX(generation) AS generation FROM workspace_access WHERE canonical_path=? OR git_dir=?", [old["canonical_path"], old["git_dir"]]),
         true <- maximum == generation and destination["generation"] == generation + 1,
         :ok <- retire_blocked_source(tx, old, attrs, proof),
         {:ok, inserted} <- insert_transferred_source(tx, old, attrs, observed, verified.facts.task, verified.facts.run, proof) do
      {:ok, inserted}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_transfer_unproven}
    end
  end

  def transfer_capability_source(_, _, _, _, _), do: {:error, :capability_recovery_transaction_required}

  defp validate_blocked_resume_source(store, key, generation, %{"amendment_command_key" => command_key}) when is_binary(command_key) do
    with {:ok, receipt} <- TicketContractAmendment.blocked_predecessor_for_request(store, Store.one!(store, "SELECT request_key FROM workspace_access WHERE reservation_key = ?", [key])["request_key"]),
         true <- receipt["command_key"] == command_key or {:error, :blocked_amendment_receipt_changed},
         {:ok, access} <- get(store, key),
         true <- (access["generation"] == generation and is_nil(access["released_at"])) or {:error, :stale_workspace_reservation},
         :ok <- validate_blocked_amendment_predecessor(store, receipt) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_blocked_resume_source(store, key, generation, _proof) do
    case validate(store, key, generation) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp blocked_resume_proof(store, old, evidence, task, run, attrs, proof) do
    with {:ok, output} <- Jason.decode(evidence["output_json"] || "null"),
         {:ok, binding} <- Jason.decode(evidence["binding_json"] || "null"),
         :ok <- accepted_rework_proof(store, proof, attrs, old, evidence, output),
         :ok <- blocked_result_scope(store, evidence, output, proof, old, task),
         :ok <- blocked_task_scope(task, binding, evidence, old),
         :ok <- blocked_run_scope(store, run, binding, old, attrs, proof),
         true <- attrs_match_old?(old, proof) or {:error, :blocked_resume_reservation_mismatch} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp blocked_result_scope(store, evidence, output, proof, old, task) do
    with :ok <- blocked_result_recorded(evidence, output),
         :ok <- stopped_owner_proven(store, evidence),
         :ok <- blocked_output_intact(evidence) do
      disposition_matches_evidence(proof, evidence, task, old)
    end
  end

  defp blocked_result_recorded(evidence, output),
    do: if(output["status"] == "BLOCKED" and evidence["status"] == "RESULT_RECORDED", do: :ok, else: {:error, :blocked_resume_result_not_recorded})

  defp stopped_owner_proven(store, evidence),
    do: if(WorkerEvidence.owner_stopped?(store, evidence), do: :ok, else: {:error, :blocked_resume_owner_not_stopped})

  defp blocked_output_intact(evidence),
    do: if(digest(evidence["output_json"]) == evidence["output_sha256"], do: :ok, else: {:error, :blocked_resume_output_changed})

  defp disposition_matches_evidence(proof, evidence, task, old) do
    valid =
      proof["request_key"] == evidence["request_key"] and proof["output_sha256"] == evidence["output_sha256"] and
        proof["task_key"] == task["task_key"] and evidence["task_key"] == old["task_key"]

    if valid, do: :ok, else: {:error, :blocked_resume_disposition_mismatch}
  end

  defp blocked_task_scope(task, binding, evidence, old) do
    expected = {old["task_key"], old["run_id"], "COMPLETE", evidence["thread_id"], evidence["turn_id"], binding["prompt_sha256"]}
    actual = {task["task_key"], task["run_id"], task["status"], task["thread_id"], task["turn_id"], task["prompt_sha256"]}
    if actual == expected, do: :ok, else: {:error, :blocked_resume_task_changed}
  end

  defp blocked_run_scope(store, run, binding, old, attrs, proof) do
    cond do
      run["candidate_sha"] != binding["expected_sha"] and
          not (nil_candidate_resume?(run, proof) or initial_blocked_source?(store, run, binding, old, attrs)) ->
        {:error, :blocked_resume_candidate_changed}

      Path.expand(run["worktree"] || "") != Path.expand(old["canonical_path"] || "") ->
        {:error, :blocked_resume_worktree_changed}

      true ->
        :ok
    end
  end

  defp initial_blocked_source?(store, %{"state" => "WRITING", "candidate_sha" => nil, "implementation_iteration" => 0} = run, binding, old, attrs) do
    sha = binding["expected_sha"]
    base = Store.one!(store, "SELECT base_ref, base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])

    with {:ok, owned} when is_map(owned) <- Jason.decode(old["binding_json"] || "null"),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
         true <- is_binary(run["base_branch"]),
         true <- base == %{"base_ref" => "refs/remotes/origin/" <> run["base_branch"], "base_sha" => sha},
         true <- binding["base_sha"] == sha and owned["expected_sha"] == sha and attrs["expected_sha"] == sha,
         true <- is_nil(owned["candidate_sha"]),
         :ok <- competing_activity(store, old["canonical_path"], old["task_key"]),
         {:ok, observed} <- observe(run, false, sha) do
      {observed.path, observed.git_dir, observed.common_dir} == {old["canonical_path"], old["git_dir"], old["common_dir"]}
    else
      _ -> false
    end
  end

  defp initial_blocked_source?(_store, _run, _binding, _old, _attrs), do: false

  defp nil_candidate_resume?(run, proof) do
    is_nil(run["candidate_sha"]) and is_binary(proof["amendment_command_key"]) and
      is_binary(proof["checkout_head_sha"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, proof["checkout_head_sha"])
  end

  defp accepted_rework_proof(store, %{"operational_recovery_key" => "TCAP-" <> _} = proof, attrs, old, evidence, output) do
    with {:ok, checked} <- TicketCapabilityRecovery.checked(store, proof),
         true <- checked.facts.evidence == evidence and checked.facts.access == old and output == checked.facts.output,
         true <- attrs["request_key"] == checked.checked["destination"]["request_key"] and attrs["reservation_key"] == checked.checked["destination"]["reservation_key"],
         do: :ok,
         else: (_ -> {:error, :capability_recovery_transfer_unproven})
  end

  defp accepted_rework_proof(store, %{"operational_recovery_key" => key} = proof, attrs, old, evidence, output) when is_binary(key) do
    with :ok <- SymphonyElixir.Factory.TicketInfrastructureRecovery.preflight(store, key),
         {:ok, resume} <- SymphonyElixir.Factory.TicketInfrastructureRecovery.resume(store, evidence["request_key"]),
         true <- resume["operational_recovery_key"] == key and resume["disposition_key"] == proof["disposition_key"],
         true <- output["status"] == "BLOCKED",
         true <- attrs["request_key"] != old["request_key"] and attrs["reservation_key"] != old["reservation_key"] do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :blocked_resume_authority_unproven}
    end
  end

  defp accepted_rework_proof(store, proof, attrs, old, evidence, output) do
    command = Store.one!(store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [proof["command_key"]])
    input = if command, do: Store.one!(store, "SELECT * FROM ticket_chat_inputs WHERE input_key = ?", [command["input_key"]])
    chat = if command, do: Store.one!(store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [command["chat_key"]])
    run = if command, do: RunLedger.get(store, command["run_id"])

    disposition =
      Store.query!(store, "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'TICKET_NATIVE_WRITER_BLOCKED'", [old["run_id"]]).rows
      |> Enum.map(fn [raw] -> Jason.decode!(raw) end)
      |> Enum.find(&(&1["disposition_key"] == proof["disposition_key"]))

    with :ok <- TicketChatCommands.preflight_rework_transfer(store, proof["command_key"]),
         true <- accepted_rework_command?(command, proof, old, chat, run),
         true <- accepted_rework_input?(command, input, proof, chat),
         true <- blocked_disposition_matches?(disposition, evidence, old, output),
         true <- attrs["request_key"] != old["request_key"] and attrs["reservation_key"] != old["reservation_key"] do
      :ok
    else
      _ -> {:error, :blocked_resume_authority_unproven}
    end
  rescue
    _ -> {:error, :blocked_resume_authority_unproven}
  end

  defp accepted_rework_command?(command, proof, old, chat, {:ok, run}) when is_map(command) and is_map(chat) do
    expected_binding = %{
      "generation" => chat["generation"],
      "spec_revision" => run["spec_revision"],
      "contract_sha256" => run["contract_sha256"],
      "candidate_sha" => run["candidate_sha"]
    }

    with true <- command["status"] == "ACCEPTED" and command["run_id"] == old["run_id"],
         true <- command["input_key"] == proof["input_key"],
         {:ok, binding} <- Jason.decode(command["binding_json"]),
         true <- binding == expected_binding,
         {:ok, admission} <- Jason.decode(command["receipt_json"]),
         true <- admission["status"] == "ACCEPTED" and admission["input_key"] == command["input_key"],
         true <- TicketChatCommands.rework_payload?(Jason.decode!(command["payload_json"])) do
      true
    else
      _ -> false
    end
  end

  defp accepted_rework_command?(_command, _proof, _old, _chat, _run), do: false

  defp accepted_rework_input?(command, input, proof, chat) when is_map(command) and is_map(input) and is_map(chat) do
    rework_body_matches?(command, input, proof) and input_route_matches?(command, input, chat) and
      ((matching_resume_staging_receipt?(command, input) and command_created_during_input?(command, input)) or
         SymphonyElixir.Factory.TicketReworkRecovery.valid?(command, input, chat))
  end

  defp accepted_rework_input?(_command, _input, _proof, _chat), do: false

  defp rework_body_matches?(command, input, proof) do
    input["input_key"] == proof["input_key"] and
      input["body_sha256"] == command["body_sha256"] and digest(input["body"]) == input["body_sha256"]
  end

  defp input_route_matches?(command, input, chat) do
    input["origin"] == "NATIVE_CLIENT_INPUT" and input["chat_key"] == command["chat_key"] and
      input["thread_id"] == chat["thread_id"] and input["generation"] == chat["generation"]
  end

  defp blocked_disposition_matches?(disposition, evidence, old, output) when is_map(disposition) do
    disposition["request_key"] == evidence["request_key"] and disposition["task_key"] == old["task_key"] and
      disposition["output_sha256"] == evidence["output_sha256"] and disposition["output_json"] == evidence["output_json"] and
      disposition["reservation_key"] == old["reservation_key"] and disposition["reservation_generation"] == old["generation"] and
      output["status"] == "BLOCKED"
  end

  defp blocked_disposition_matches?(_disposition, _evidence, _old, _output), do: false

  defp matching_resume_staging_receipt?(command, input) do
    case Jason.decode(input["staging_receipts_json"] || "null") do
      {:ok, receipts} when is_map(receipts) ->
        case receipts[command["command_key"]] do
          %{"attrs" => attrs, "run_id" => run_id, "payload_sha256" => sha} ->
            staging_identity_matches?(attrs, command, input, run_id, sha)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp staging_identity_matches?(attrs, command, input, run_id, sha) do
    run_id == command["run_id"] and sha == command["payload_sha256"] and
      attrs["proposal_id"] == command["proposal_id"] and attrs["body"] == input["body"] and
      Jason.encode!(Map.take(attrs, ~w(generation spec_revision contract_sha256 candidate_sha))) == command["binding_json"] and
      original_operations_match?(attrs["operations"], command["payload_json"])
  end

  defp original_operations_match?(supplied, payload_json) do
    case Jason.decode(payload_json) do
      {:ok, operations} when is_list(operations) ->
        Jason.encode!(supplied) == Jason.encode!(Enum.map(operations, &Map.delete(&1, "question_digest")))

      _ ->
        false
    end
  end

  defp command_created_during_input?(command, input) do
    case DateTime.from_iso8601(command["created_at"] || "") do
      {:ok, time, _} ->
        created = DateTime.to_unix(time, :microsecond) / 1_000_000
        created >= input["started_at"] and created < input["completed_at"] + 1

      _ ->
        false
    end
  end

  defp attrs_match_old?(old, proof),
    do: proof["reservation_key"] == old["reservation_key"] and proof["reservation_generation"] == old["generation"]

  defp retire_blocked_source(tx, old, attrs, proof) do
    receipt =
      Jason.encode!(%{
        "kind" => "BLOCKED_SOURCE_TRANSFER",
        "old_request_key" => old["request_key"],
        "old_reservation_key" => old["reservation_key"],
        "old_generation" => old["generation"],
        "new_request_key" => attrs["request_key"],
        "new_reservation_key" => attrs["reservation_key"],
        "command_key" => proof["command_key"],
        "operational_recovery_key" => proof["operational_recovery_key"],
        "amendment_command_key" => proof["amendment_command_key"],
        "input_key" => proof["input_key"],
        "disposition_key" => proof["disposition_key"],
        "output_sha256" => proof["output_sha256"],
        "checkout_head_sha" => proof["checkout_head_sha"]
      })

    Store.query!(tx, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND generation = ? AND released_at IS NULL", [
      now(),
      receipt,
      old["reservation_key"],
      old["generation"]
    ])

    if Store.one!(tx, "SELECT changes() AS count")["count"] == 1, do: :ok, else: {:error, :stale_workspace_reservation}
  end

  defp insert_transferred_source(tx, old, attrs, observed, task, run, proof) do
    previous = Store.one!(tx, "SELECT COALESCE(MAX(generation), 0) AS generation FROM workspace_access WHERE canonical_path = ? OR git_dir = ?", [old["canonical_path"], old["git_dir"]])
    generation = previous["generation"] + 1
    old_binding = Jason.decode!(old["binding_json"])

    binding =
      old_binding
      |> Map.merge(attrs)
      |> Map.merge(Map.take(observed, ~w(path git_dir common_dir root_device root_inode)))
      |> Map.merge(Map.take(run, ~w(spec_revision contract_sha256 candidate_sha branch)))
      |> Map.put("prompt_sha256", proof["new_prompt_sha256"] || task["prompt_sha256"])

    Store.query!(
      tx,
      "INSERT INTO workspace_access(reservation_key, run_id, task_key, request_key, mode, generation, canonical_path, git_dir, common_dir, binding_json, acquired_at) VALUES (?, ?, ?, ?, 'SOURCE', ?, ?, ?, ?, ?, ?)",
      [attrs["reservation_key"], attrs["run_id"], attrs["task_key"], attrs["request_key"], generation, observed.path, observed.git_dir, observed.common_dir, Jason.encode!(binding), now()]
    )

    get(tx, attrs["reservation_key"])
  end

  @doc "Captures a stopped CI predecessor's clean checkout outside SQL; this observation grants no transfer authority."
  @spec prepare_ci_successor_source(Store.connection(), map(), map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def prepare_ci_successor_source(%DBConnection{}, _run, _old, _root), do: {:error, :workspace_observation_inside_transaction}

  def prepare_ci_successor_source(store, run, old, root) do
    with true <- old["run_id"] == run["run_id"] and old["mode"] == "SOURCE" and is_nil(old["released_at"]),
         {:ok, observed} <- observe(run, true, run["candidate_sha"]),
         true <- {observed.path, observed.git_dir, observed.common_dir} == {old["canonical_path"], old["git_dir"], old["common_dir"]},
         :ok <- within_root(observed.path, root),
         :ok <- WorkerFileIO.workspace_allowed?(store, observed.path),
         {:ok, fresh} <- observe(run, true, run["candidate_sha"]),
         true <- fresh == observed,
         {:ok, physical} <- acquisition_physical_identity(observed) do
      {:ok, %{run: run, old: old, observed: observed, physical: physical, root: root}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_source_changed}
    end
  end

  @doc "Transfers SOURCE only through a fully validated dedicated CI journal, with no Git or native calls under SQL."
  @spec transfer_ci_successor_source(Store.connection(), map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def transfer_ci_successor_source(%DBConnection{} = tx, observed, attrs, key) do
    with {:ok, entry} <- SymphonyElixir.Factory.TicketCiRepairSuccessor.journal(tx, key),
         true <- entry.proof["prior_access"] == observed.old and entry.proof["run"] == observed.run,
         true <-
           attrs["request_key"] == entry.row["new_request_key"] and attrs["reservation_key"] == entry.row["new_reservation_key"] and attrs["run_id"] == entry.row["run_id"] and
             attrs["task_key"] == observed.old["task_key"] and attrs["mode"] == "SOURCE" and attrs["expected_sha"] == observed.run["candidate_sha"],
         {:ok, current} <- RunLedger.get(tx, attrs["run_id"]),
         true <- current == observed.run,
         {:ok, old} <- get(tx, observed.old["reservation_key"]),
         true <- old == observed.old and is_nil(old["released_at"]),
         :ok <- acquisition_root_current(observed.observed),
         {:ok, physical} <- acquisition_physical_identity(observed.observed),
         true <- physical == observed.physical,
         :ok <- within_root(observed.observed.path, observed.root),
         {:ok, task} <- TaskLedger.get(tx, old["task_key"]),
         true <- task == entry.proof["prior_task"],
         {:ok, disposition} <- Jason.decode(entry.proof["disposition_event"]["payload_json"]),
         maximum = Store.one!(tx, "SELECT COALESCE(MAX(generation),0) AS generation FROM workspace_access WHERE canonical_path=? OR git_dir=?", [old["canonical_path"], old["git_dir"]]),
         transfer = %{
           "kind" => "CI_EVIDENCE_SUCCESSOR_TRANSFER_V1",
           "ci_evidence_successor_key" => key,
           "old_request_key" => entry.row["prior_request_key"],
           "old_reservation_key" => old["reservation_key"],
           "new_request_key" => attrs["request_key"],
           "new_reservation_key" => attrs["reservation_key"],
           "new_generation" => maximum["generation"] + 1,
           "disposition_key" => disposition["disposition_key"],
           "output_sha256" => entry.proof["prior_evidence"]["output_sha256"],
           "checkout_head_sha" => current["candidate_sha"]
         },
         _ <-
           Store.query!(tx, "UPDATE workspace_access SET released_at=?,release_receipt_json=? WHERE reservation_key=? AND released_at IS NULL", [now(), Jason.encode!(transfer), old["reservation_key"]]),
         {:ok, access} <- insert_transferred_source(tx, old, attrs, observed.observed, task, current, %{"new_prompt_sha256" => attrs["prompt_sha256"]}) do
      if access["generation"] == transfer["new_generation"], do: {:ok, access}, else: {:error, :ci_successor_source_generation_changed}
    else
      {:error, _} = error -> error
      _ -> {:error, :ci_successor_source_changed}
    end
  end

  def transfer_ci_successor_source(_, _, _, _), do: {:error, :ci_successor_transaction_required}

  @doc "Transfer only through an exact failed-turn quiescence authority; never ordinary release."
  @spec transfer_failed_source(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transfer_failed_source(store, old_key, proof) do
    transaction(store, fn tx ->
      with :ok <- SymphonyElixir.Factory.FailedTurnRecovery.transfer_authority(tx, proof),
           {:ok, old} <- get(tx, old_key),
           {:ok, evidence} <- WorkerEvidence.get(tx, old["request_key"]),
           true <- (digest(Jason.encode!(old)) == proof["old_access_sha256"] and digest(Jason.encode!(evidence)) == proof["old_evidence_sha256"]) or {:error, :failed_retry_binding_changed},
           {:ok, task} <- TaskLedger.get(tx, old["task_key"]),
           {:ok, run} <- RunLedger.get(tx, old["run_id"]),
           {:ok, observed} <- observe(run, false, run["candidate_sha"]),
           true <- (is_nil(old["released_at"]) and old["mode"] == "SOURCE") or {:error, :stale_workspace_reservation},
           :ok <- SymphonyElixir.Factory.FailedTurnRecovery.transfer_authority(tx, proof),
           attrs = Map.take(Jason.decode!(old["binding_json"]), @fields) |> Map.merge(%{"request_key" => proof["new_request_key"], "reservation_key" => proof["new_reservation_key"]}),
           transfer = Map.take(proof, ~w(kind recovery_key old_request_key new_request_key new_reservation_key)) do
        Store.query!(tx, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND released_at IS NULL", [now(), Jason.encode!(transfer), old_key])
        insert_transferred_source(tx, old, attrs, observed, task, run, proof)
      else
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Release is authorized by a consumed durable attempt, never by timeout or process absence."
  @spec release(Store.connection(), String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def release(store, key, generation, request_key) do
    transaction(store, fn tx ->
      with {:ok, row} <- get(tx, key),
           true <- (row["generation"] == generation and row["request_key"] == request_key) or {:error, :stale_workspace_reservation},
           evidence when is_map(evidence) <-
             Store.one!(tx, "SELECT * FROM worker_evidence WHERE request_key = ? AND reservation_key = ? AND status = 'CONSUMED' AND owner_stopped_at IS NOT NULL", [request_key, key]) do
        release_consumed(tx, row, evidence)
      else
        nil -> {:error, :workspace_completion_not_proven}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Releases only the exact completed controller push with independently read stopped-process evidence."
  @spec release_push(Store.connection(), String.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def release_push(store, run_id, key, generation) do
    transaction(store, fn tx -> release_push_transaction(tx, run_id, key, generation) end)
  end

  @doc false
  @spec release_current_push(Store.connection(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def release_current_push(store, run_id, intent, raw) do
    with {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <- binding["publication_version"] == 2 and TicketPushIO.receipt_valid?(raw, intent),
         {:ok, access} <- get(store, intent["reservation_key"]) do
      release_push_observed(store, run_id, intent["reservation_key"], intent["reservation_generation"], access, raw)
    else
      _ -> {:error, :controller_push_receipt_unproven}
    end
  end

  defp release_push_transaction(store, run_id, key, generation) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, intent} <- Jason.decode(run["candidate_handoff"] || "null"),
         true <-
           (intent["kind"] == "TICKET_PUSH" and intent["phase"] == "COMPLETED") or
             {:error, :controller_push_completion_unproven},
         true <-
           {intent["reservation_key"], intent["reservation_generation"], intent["remote_sha"]} ==
             {key, generation, run["candidate_sha"]} or {:error, :controller_push_completion_unproven},
         {:ok, access} <- validate(store, key, generation),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {run_id, "MAINTENANCE", key, nil} or {:error, :controller_push_completion_unproven},
         :ok <- push_release_binding(run, intent, access),
         {:ok, raw} <- TicketPushIO.readback(intent),
         true <-
           (raw == intent["receipt_json"] and receipt_hash(raw) == intent["receipt_sha256"] and
              TicketPushIO.receipt_valid?(raw, intent)) or {:error, :controller_push_receipt_unproven} do
      release_push_observed(store, run_id, key, generation, access, raw)
    else
      {:error, _} = error -> error
    end
  end

  defp release_push_observed(store, run_id, key, generation, observed_access, raw) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, intent} <- Jason.decode(run["candidate_handoff"] || "null"),
         true <- (intent["kind"] == "TICKET_PUSH" and intent["phase"] == "COMPLETED") or {:error, :controller_push_completion_unproven},
         true <- {intent["reservation_key"], intent["reservation_generation"], intent["remote_sha"]} == {key, generation, push_candidate(intent, run)} or {:error, :controller_push_completion_unproven},
         {:ok, access} <- get(store, key),
         true <- (access == observed_access and access["generation"] == generation and is_nil(access["released_at"])) or {:error, :stale_workspace_reservation},
         true <- {access["run_id"], access["mode"], access["request_key"], access["task_key"]} == {run_id, "MAINTENANCE", key, nil} or {:error, :controller_push_completion_unproven},
         :ok <- push_release_binding(run, intent, access),
         true <- (raw == intent["receipt_json"] and receipt_hash(raw) == intent["receipt_sha256"] and TicketPushIO.receipt_valid?(raw, intent)) or {:error, :controller_push_receipt_unproven} do
      Store.query!(store, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND released_at IS NULL", [now(), run["candidate_handoff"], key])
      get(store, key)
    end
  end

  defp push_release_binding(run, intent, access) do
    fields = ~w(run_id issue_key state repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)

    with {:ok, binding} when is_map(binding) <- Jason.decode(intent["binding_json"] || "null"),
         current? = binding["publication_version"] == 2,
         true <- run["execution_mode"] == "TICKET_SUPERVISOR_V1" and (current? or run["state"] in ~w(PUSHING CI_PUSHING)),
         {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || "null"),
         {:ok, owned} when is_map(owned) <- Jason.decode(access["binding_json"]),
         hash = receipt_hash(intent["binding_json"]),
         true <- hash == intent["binding_sha256"] and intent["reservation_key"] == "ticket-push:" <> hash,
         identity = if(current?, do: ~w(run_id issue_key repo_path worktree branch base_branch), else: fields),
         true <- Map.take(binding, identity) == Map.take(run, identity),
         true <-
           {execution["run_id"], execution["intent_json"], execution["intent_sha256"], execution["invocation"]} ==
             {run["run_id"], intent["binding_json"], hash, intent["owner_nonce"]},
         checkout when is_map(checkout) <- binding["checkout"],
         true <-
           {checkout["path"], checkout["git_dir"], checkout["common_dir"]} ==
             {access["canonical_path"], access["git_dir"], access["common_dir"]},
         true <- Map.take(checkout, ~w(root_device root_inode)) == Map.take(owned, ~w(root_device root_inode)),
         true <- owned["expected_sha"] == binding["candidate_sha"] do
      :ok
    else
      _ -> {:error, :controller_push_binding_unproven}
    end
  end

  defp push_candidate(intent, run) do
    case Jason.decode(intent["binding_json"] || "null") do
      {:ok, %{"publication_version" => 2, "candidate_sha" => sha}} -> sha
      _ -> run["candidate_sha"]
    end
  end

  defp receipt_hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  @doc "Transfers a held input-fenced reservation only within its exact append-only retirement transaction."
  @spec transfer_input_retirement(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def transfer_input_retirement(%DBConnection{} = tx, retirement, original_access, opts) do
    with saved when is_map(saved) <- Store.one!(tx, "SELECT * FROM ticket_push_input_retirements WHERE retirement_key = ?", [retirement["retirement_key"]]),
         true <- saved == retirement or {:error, :input_retirement_changed},
         {:ok, run} <- RunLedger.get(tx, saved["run_id"]),
         true <- run["candidate_handoff"] == saved["original_envelope"] or {:error, :input_retirement_envelope_changed},
         {:ok, intent} <- Jason.decode(saved["original_envelope"]),
         {:ok, access} <- get(tx, intent["reservation_key"]),
         true <- (access == original_access and is_nil(access["released_at"]) and is_nil(access["release_receipt_json"])) or {:error, :input_retirement_reservation_changed},
         true <-
           {access["run_id"], access["request_key"], access["task_key"], access["mode"], access["generation"]} ==
             {run["run_id"], intent["reservation_key"], nil, "MAINTENANCE", intent["reservation_generation"]} or {:error, :input_retirement_reservation_changed},
         true <-
           (intent["phase"] == "PUSH_UNCERTAIN" and Enum.all?(~w(helper_pid execution_json receipt_json receipt_sha256 remote_sha), &is_nil(intent[&1]))) or
             {:error, :input_retirement_issuance_unproven},
         {:ok, proof} <- Jason.decode(saved["proof_json"]),
         true <- (proof["kind"] == "INPUT_NOT_ISSUED" and receipt_hash(saved["proof_json"]) == saved["proof_sha256"]) or {:error, :input_retirement_proof_changed},
         {:ok, binding} <- Jason.decode(access["binding_json"]) do
      release = Jason.encode!(%{"kind" => "INPUT_NOT_ISSUED", "retirement_key" => saved["retirement_key"], "original_envelope" => saved["original_envelope"], "proof_sha256" => saved["proof_sha256"]})

      Store.query!(tx, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND generation = ? AND released_at IS NULL AND release_receipt_json IS NULL", [
        now(),
        release,
        access["reservation_key"],
        access["generation"]
      ])

      attrs = Map.take(binding, ~w(reservation_key run_id task_key request_key mode allowed_root expected_sha))
      attrs = Map.merge(attrs, %{"reservation_key" => saved["successor_reservation_key"], "request_key" => saved["successor_reservation_key"]})
      observed = Map.new([:path, :git_dir, :common_dir, :root_device, :root_inode], &{&1, binding[to_string(&1)]})
      insert_observed(tx, attrs, opts, run, nil, observed)
    else
      {:error, _} = error -> error
      _ -> {:error, :input_retirement_unproven}
    end
  end

  def transfer_input_retirement(_store, _retirement, _access, _opts), do: {:error, :input_retirement_transaction_required}

  @spec transfer_preissuance_rejection(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def transfer_preissuance_rejection(%DBConnection{} = tx, retirement, original_access, opts) do
    with ^retirement <- Store.one!(tx, "SELECT * FROM ticket_push_rejection_retirements WHERE retirement_key=?", [retirement["retirement_key"]]),
         :ok <- TicketPushPreissuanceRejection.validate_retirement(retirement) do
      transfer_closed_rejection(tx, retirement, original_access, opts)
    end
  end

  def transfer_preissuance_rejection(_store, _retirement, _access, _opts), do: {:error, :push_rejection_transaction_required}

  @spec transfer_ordinary_preissuance_rejection(Store.connection(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transfer_ordinary_preissuance_rejection(%DBConnection{} = tx, plan, original_access, opts) do
    with {:ok, value} <- TicketPushOrdinaryRejection.validate_record(tx, plan["record"]),
         true <- {value["run_id"], value["original_envelope"], plan["record"]["payload_json"]} == {plan["run_id"], plan["original_envelope"], plan["proof_json"]},
         true <- :crypto.hash(:sha256, Jason.encode!(original_access)) |> Base.encode16(case: :lower) == value["prior_access_sha256"],
         {:ok, original} <- Jason.decode(value["original_envelope"]),
         ref = %{
           "event_id" => plan["record"]["id"],
           "event_sha256" => :crypto.hash(:sha256, plan["proof_json"]) |> Base.encode16(case: :lower),
           "retirement_key" => value["retirement_key"],
           "original_sha256" => value["original_sha256"],
           "attempt" => 1
         },
         binding = Jason.decode!(original["binding_json"]) |> Map.put("ordinary_preissuance_retirement", ref) |> Jason.encode!(),
         true <- plan["successor_reservation_key"] == "ticket-push:" <> (:crypto.hash(:sha256, binding) |> Base.encode16(case: :lower)) do
      transfer_closed_rejection(tx, plan, original_access, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :ordinary_rejection_transfer_unproven}
    end
  end

  def transfer_ordinary_preissuance_rejection(_store, _plan, _access, _opts), do: {:error, :push_rejection_transaction_required}

  defp transfer_closed_rejection(tx, retirement, original_access, opts) do
    with {:ok, run} <- RunLedger.get(tx, retirement["run_id"]),
         true <- run["candidate_handoff"] == retirement["original_envelope"] or {:error, :push_rejection_envelope_changed},
         {:ok, intent} <- Jason.decode(retirement["original_envelope"]),
         {:ok, access} <- get(tx, intent["reservation_key"]),
         true <- access == original_access and is_nil(access["released_at"]) and is_nil(access["release_receipt_json"]),
         expected = {run["run_id"], intent["reservation_key"], nil, "MAINTENANCE", intent["reservation_generation"]},
         true <- {access["run_id"], access["request_key"], access["task_key"], access["mode"], access["generation"]} == expected,
         {:ok, binding} <- Jason.decode(access["binding_json"]) do
      changed =
        Store.query!(
          tx,
          "UPDATE workspace_access SET released_at=?,release_receipt_json=? WHERE reservation_key=? AND generation=? AND released_at IS NULL AND release_receipt_json IS NULL RETURNING reservation_key",
          [now(), retirement["proof_json"], access["reservation_key"], access["generation"]]
        ).rows

      if changed == [[access["reservation_key"]]] do
        attrs = Map.take(binding, ~w(reservation_key run_id task_key request_key mode allowed_root expected_sha))
        attrs = Map.merge(attrs, %{"reservation_key" => retirement["successor_reservation_key"], "request_key" => retirement["successor_reservation_key"]})
        observed = Map.new([:path, :git_dir, :common_dir, :root_device, :root_inode], &{&1, binding[to_string(&1)]})
        insert_observed(tx, attrs, opts, run, nil, observed)
      else
        {:error, :push_rejection_reservation_changed}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :push_rejection_transfer_unproven}
    end
  end

  @doc false
  @spec transfer_prepared_requalification(Store.connection(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transfer_prepared_requalification(%DBConnection{} = tx, row, original_access, opts) do
    with ^row <- Store.one!(tx, "SELECT * FROM ticket_push_prepared_requalifications WHERE authorization_key=?", [row["authorization_key"]]),
         :ok <- TicketPushRequalification.validate(row),
         {:ok, run} <- RunLedger.get(tx, row["run_id"]),
         true <- run["candidate_handoff"] == row["original_envelope"],
         {:ok, original} <- Jason.decode(row["original_envelope"]),
         {:ok, access} <- get(tx, original["reservation_key"]),
         true <- access == original_access and is_nil(access["released_at"]) and is_nil(access["release_receipt_json"]),
         {:ok, proof} <- Jason.decode(row["proof_json"]),
         true <- proof["original_access"] == access,
         {:ok, binding} <- Jason.decode(access["binding_json"]) do
      changed =
        Store.query!(
          tx,
          "UPDATE workspace_access SET released_at=?,release_receipt_json=? WHERE reservation_key=? AND generation=? AND released_at IS NULL AND release_receipt_json IS NULL RETURNING reservation_key",
          [now(), row["proof_json"], access["reservation_key"], access["generation"]]
        ).rows

      if changed == [[access["reservation_key"]]] do
        attrs =
          binding
          |> Map.take(~w(reservation_key run_id task_key request_key mode allowed_root expected_sha))
          |> Map.merge(%{"reservation_key" => row["successor_reservation_key"], "request_key" => row["successor_reservation_key"]})

        observed = Map.new([:path, :git_dir, :common_dir, :root_device, :root_inode], &{&1, binding[to_string(&1)]})
        insert_observed(tx, attrs, opts, run, nil, observed)
      else
        {:error, :push_requalification_access_changed}
      end
    else
      _ -> {:error, :push_requalification_transfer_unproven}
    end
  end

  def transfer_prepared_requalification(_store, _row, _access, _opts), do: {:error, :push_requalification_transaction_required}

  @spec release_unissuable_push(Store.connection(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def release_unissuable_push(store, run_id, key, generation) do
    transaction(store, fn tx ->
      with {:ok, run} <- RunLedger.get(tx, run_id),
           {:ok, intent} <- Jason.decode(run["candidate_handoff"] || "null"),
           true <-
             {intent["kind"], intent["phase"], intent["reservation_key"], intent["reservation_generation"], intent["remote_sha"]} == {"TICKET_PUSH", "UNISSUABLE", key, generation, nil} or
               {:error, :controller_push_disposition_unproven},
           {:ok, access} <- validate(tx, key, generation),
           true <- {access["run_id"], access["mode"], access["request_key"], access["task_key"]} == {run_id, "MAINTENANCE", key, nil},
           :ok <- push_release_binding(run, intent, access),
           {:ok, proof} <- TicketPushIO.unissuable_v1_proof(intent),
           true <- proof == intent["receipt_json"] and receipt_hash(proof) == intent["receipt_sha256"] do
        Store.query!(tx, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND released_at IS NULL", [now(), run["candidate_handoff"], key])
        get(tx, key)
      else
        {:error, _} = error -> error
        _ -> {:error, :controller_push_disposition_unproven}
      end
    end)
  end

  @doc "Releases only the exact complete Jira operation's maintenance checkout; it does not advance delivery."
  @spec release_jira(Store.connection(), String.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def release_jira(store, run_id, key, generation) do
    transaction(store, fn tx ->
      with {:ok, %{"phase" => "COMPLETE"}} <- TicketJiraJournal.get(tx, key),
           {:ok, journal} <- TicketJiraJournal.reconcile(tx, key, %{}),
           true <- journal["run_id"] == run_id or {:error, :jira_workspace_completion_unproven},
           {:ok, access} <- get(tx, key),
           true <- access["generation"] == generation or {:error, :stale_workspace_reservation},
           ownership = {access["run_id"], access["mode"], access["request_key"], access["task_key"]},
           true <- ownership == {run_id, "MAINTENANCE", key, nil} or {:error, :jira_workspace_completion_unproven},
           {:ok, binding} <- Jason.decode(journal["binding_json"]),
           {:ok, owned} <- Jason.decode(access["binding_json"]),
           :ok <- jira_release_binding(tx, binding, owned, access) do
        receipt = Jason.encode!(Map.take(journal, ~w(operation_key binding_sha256 effects_sha256 first_receipt_json second_receipt_json)))
        finalize_jira_release(tx, access, generation, receipt)
      else
        {:error, _} = error -> error
        _ -> {:error, :jira_workspace_completion_unproven}
      end
    end)
  end

  defp finalize_jira_release(store, %{"released_at" => nil} = access, generation, receipt) do
    with {:ok, _} <- validate(store, access["reservation_key"], generation) do
      Store.query!(store, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND released_at IS NULL", [now(), receipt, access["reservation_key"]])
      get(store, access["reservation_key"])
    end
  end

  defp finalize_jira_release(_store, access, _generation, receipt) do
    if access["release_receipt_json"] == receipt, do: {:ok, access}, else: {:error, :jira_workspace_completion_unproven}
  end

  defp jira_release_binding(store, binding, owned, access) do
    checkout = binding["checkout"]
    base = Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [access["run_id"]])
    expected = binding["candidate_sha"] || (base || %{})["base_sha"]

    valid =
      is_map(checkout) and
        {checkout["path"], checkout["git_dir"], checkout["common_dir"]} == {access["canonical_path"], access["git_dir"], access["common_dir"]} and
        Map.take(checkout, ~w(root_device root_inode)) == Map.take(owned, ~w(root_device root_inode)) and owned["expected_sha"] == expected

    if valid, do: :ok, else: {:error, :jira_workspace_binding_unproven}
  end

  defp release_consumed(_store, %{"released_at" => at} = row, _evidence) when not is_nil(at), do: {:ok, row}

  defp release_consumed(store, row, evidence) do
    with :ok <- WorkerEvidence.checks_stopped(store, row["reservation_key"]),
         {:ok, _} <- validate(store, row["reservation_key"], row["generation"], clean: true, candidate_adopted: true) do
      Store.query!(store, "UPDATE workspace_access SET released_at = ?, release_receipt_json = ? WHERE reservation_key = ? AND released_at IS NULL", [
        now(),
        Jason.encode!(Map.take(evidence, ~w(request_key binding_sha256 output_sha256 consumed_at owner_stopped_at))),
        row["reservation_key"]
      ])

      {:ok, get_row(store, row["reservation_key"])}
    end
  end

  defp observe(run, clean, expected_sha) do
    options = [clean: clean, detached: false, expected_branch: run["branch"], expected_sha: expected_sha]

    with :ok <- source_binding(run) do
      Worktree.checkout_identity(%{"path" => run["repo_path"]}, run["worktree"], options)
    end
  end

  defp source_binding(run) do
    if Enum.all?(~w(repo_path worktree branch), &is_binary(run[&1])), do: :ok, else: {:error, :workspace_binding_missing}
  end

  @doc "Validates an existing clean, inactive source checkout without reserving or changing it."
  @spec checkout_admission(Store.connection(), map(), String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def checkout_admission(store, run, expected_sha, root) do
    with {:ok, observed} <- observe(run, true, expected_sha),
         :ok <- checkout_intent_available(store, observed, run["branch"], run["run_id"]),
         :ok <- within_root(observed.path, root),
         :ok <- WorkerFileIO.workspace_allowed?(store, observed.path),
         :ok <- NativeWorkspaceMaintenance.checkout_available(store, run["run_id"]),
         :ok <- competing_activity(store, observed.path, nil),
         :ok <- unowned(store, observed) do
      {:ok, observed}
    end
  end

  defp checkout_intent_available(store, observed, branch, own_run) do
    conflict =
      Store.one!(
        store,
        "SELECT run_id FROM ticket_checkout_intents WHERE phase != 'READY' AND (canonical_path = ? OR (json_extract(binding_json, '$.repository_identity.common_path') = ? AND branch = ?)) AND (? IS NULL OR run_id != ?)",
        [observed.path, observed.common_dir, branch, own_run, own_run]
      )

    if conflict == nil, do: :ok, else: {:error, :workspace_checkout_creation_pending}
  end

  defp within_root(path, root) do
    with {:ok, canonical} <- PathSafety.canonicalize(root) do
      inside = path != canonical and String.starts_with?(path, canonical <> "/")
      if inside, do: :ok, else: {:error, :workspace_outside_allowed_root}
    end
  end

  defp unowned(store, observed) do
    if Store.one!(store, "SELECT reservation_key FROM workspace_access WHERE released_at IS NULL AND (canonical_path = ? OR git_dir = ?)", [observed.path, observed.git_dir]) == nil,
      do: :ok,
      else: {:error, :workspace_busy}
  end

  defp competing_activity(store, path, task_key) do
    result =
      Store.query!(
        store,
        "SELECT t.task_key, t.workspace, t.status FROM factory_tasks t WHERE ((t.task_key != COALESCE(?, '') AND t.status IN (#{Enum.map_join(@active, ",", fn _ -> "?" end)})) OR EXISTS (SELECT 1 FROM desktop_requests d WHERE d.target_kind = 'TASK' AND d.target_key = t.task_key AND d.status IN ('PENDING','CREATE_UNCERTAIN','FOLLOWUP_UNCERTAIN','THREAD_RECORDED','RECONCILE_REQUIRED'))) AND t.workspace IS NOT NULL",
        [task_key | @active]
      )

    active = Enum.any?(result.rows, fn [_key, workspace, _status] -> PathSafety.canonicalize(workspace) == {:ok, path} end)
    if active, do: {:error, :workspace_activity_unresolved}, else: :ok
  end

  defp admitted_sha(store, run, task, attrs) do
    expected = attrs["expected_sha"]
    candidate = run["candidate_sha"]
    candidate_matches = candidate == expected or (candidate == nil and (task || %{})["workspace_sha"] == expected)
    valid = candidate_matches or initial_maintenance_base?(store, run, attrs)
    if valid, do: :ok, else: {:error, :workspace_candidate_binding_mismatch}
  end

  defp initial_maintenance_base?(store, %{"state" => "ADMITTING_WRITER", "candidate_sha" => nil} = run, %{"mode" => "MAINTENANCE", "task_key" => nil, "expected_sha" => sha}) do
    TicketChat.ordinary_delivery_eligibility(run) == :ok and
      Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]]) == %{"base_sha" => sha}
  end

  defp initial_maintenance_base?(_store, _run, _attrs), do: false

  defp current_task(_store, %{"task_key" => nil}, _binding), do: :ok

  defp current_task(store, row, binding) do
    with {:ok, task} <- TaskLedger.get(store, row["task_key"]),
         true <- task["prompt_sha256"] == binding["prompt_sha256"] or {:error, :workspace_task_input_changed} do
      :ok
    end
  end

  defp capacity(_store, _run, mode, _opts) when mode != "SOURCE", do: :ok

  defp capacity(store, run, "SOURCE", opts), do: source_capacity(store, run, opts)

  @doc "Checks the shared source capacity budget without acquiring or releasing a checkout."
  @spec source_capacity(Store.connection(), map(), keyword()) :: :ok | {:error, term()}
  def source_capacity(store, run, opts) do
    reservations =
      Store.query!(
        store,
        "SELECT DISTINCT r.issue_key FROM workspace_access w JOIN runs r ON r.run_id = w.run_id WHERE w.mode = 'SOURCE' AND w.released_at IS NULL",
        []
      ).rows
      |> List.flatten()

    with {:ok, policy} <- Keyword.fetch(opts, :capacity_policy),
         {:ok, snapshot} <-
           Capacity.snapshot(
             store,
             policy,
             run["repo_key"],
             Keyword.take(opts, [:free_bytes]) |> Keyword.put(:exclude_writer_issue_key, run["issue_key"]) |> Keyword.put(:external_writer_issue_keys, reservations)
           ),
         true <- snapshot.available_writer_slots > 0 or {:error, :insufficient_writer_capacity} do
      :ok
    else
      :error -> {:error, :workspace_capacity_policy_missing}
      {:error, _} = error -> error
    end
  end

  defp get_row(store, key), do: Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [key])
  defp digest(value) when is_binary(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp transaction(store, fun) do
    case Exqlite.transaction(store, fn tx -> rollback_error(tx, fun.(tx)) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result
end
