defmodule SymphonyElixir.Factory.TicketCheckout do
  @moduledoc "Durable initial checkout reservation, one owned creation, and receipt-only recovery."
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChat, TicketCheckoutIO, TicketWorkerRunner}
  alias SymphonyElixir.Factory.{WorkspaceAccess, Worktree}
  alias SymphonyElixir.PathSafety

  @run_fields ~w(run_id issue_key execution_mode repo_key repo_path base_branch branch spec_revision contract_sha256 manual_validation_required)

  @spec reserve(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reserve(store, run_id, authorization, opts) do
    case Exqlite.transaction(store, &rollback_error(&1, reserve_transaction(&1, run_id, authorization, opts))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result

  @doc "Starts one new checkout invocation; uncertain outcomes are recovered only by readback."
  @spec create(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(store, run_id, authorization, opts) do
    with {:ok, intent} <- claim(store, run_id, authorization, opts) do
      create_claimed(store, intent, authorization, opts)
    end
  end

  defp create_claimed(store, intent, authorization, opts) do
    case TicketCheckoutIO.prepare(store, intent, authorization) do
      {:ok, execution} ->
        started = &start_helper(store, intent, authorization, opts, &1, &2)
        TicketCheckoutIO.execute(execution, started)
        reconcile(store, intent["run_id"], authorization, opts)

      {:error, reason} ->
        problem(store, intent, reason)
    end
  end

  defp start_helper(store, intent, authorization, opts, pid, execution) do
    operation = fn tx ->
      result = start_helper_transaction(tx, intent, authorization, opts, pid, execution)
      rollback_error(tx, result)
    end

    case Exqlite.transaction(store, operation) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_helper_transaction(store, intent, authorization, opts, pid, execution) do
    with {:ok, current} <- reserve_transaction(store, intent["run_id"], authorization, opts),
         true <- current == intent or {:error, :ticket_checkout_intent_changed} do
      row =
        Store.query!(
          store,
          "UPDATE ticket_checkout_intents SET helper_pid = ?, execution_json = ? WHERE run_id = ? AND phase = 'MUTATING_UNCERTAIN' AND owner_nonce = ? AND helper_pid IS NULL RETURNING run_id",
          [pid, execution, intent["run_id"], intent["owner_nonce"]]
        )

      if row.rows == [[intent["run_id"]]], do: get(store, intent["run_id"]), else: {:error, :ticket_checkout_already_started}
    end
  end

  @doc "Reads the original terminal receipt and atomically admits only its exact clean checkout."
  @spec reconcile(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, run_id, authorization, opts) do
    with {:ok, intent} <- get(store, run_id),
         true <-
           is_nil(opts[:expected_intent]) or intent == opts[:expected_intent] or
             {:error, :ticket_checkout_intent_changed} do
      reconcile_intent(store, intent, authorization, opts)
    end
  end

  @doc "Admits a repaired initial checkout after a proven timeout; never reissues creation."
  @spec recover_materialization(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_materialization(store, run_id, authorization, opts) do
    with {:ok, intent} <- get(store, run_id),
         true <- intent["phase"] == "RECONCILE_REQUIRED" or {:error, :ticket_checkout_recovery_not_admitted},
         {:ok, raw} <- TicketCheckoutIO.readback(intent),
         true <- TicketCheckoutIO.receipt_valid?(raw, intent) or {:error, :ticket_checkout_receipt_unproven},
         receipt <- Jason.decode!(raw),
         true <-
           (receipt["timed_out"] == true and receipt["overflow"] == false and receipt["termination"] == %{"kind" => "signaled", "signal" => 9}) or
             {:error, :ticket_checkout_timeout_unproven},
         :ok <- inactive_process(intent["helper_pid"]),
         :ok <- inactive_process(receipt["child_pid"]) do
      finalize(store, intent, raw, authorization, opts, true)
    end
  end

  defp inactive_process(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 1} -> :ok
      _ -> {:error, :ticket_checkout_process_not_proven_inactive}
    end
  end

  defp inactive_process(_pid), do: {:error, :ticket_checkout_process_not_proven_inactive}

  defp reconcile_intent(store, %{"phase" => "READY"} = intent, _authorization, _opts) do
    with {:ok, run} <- RunLedger.get(store, intent["run_id"]),
         true <- (run["worktree"] == intent["canonical_path"] and run["branch"] == intent["branch"]) or {:error, :ticket_checkout_intent_changed} do
      {:ok, %{status: "CHECKOUT_ALREADY_AVAILABLE", run: run, model_invoked: false}}
    end
  end

  defp reconcile_intent(store, intent, authorization, opts) do
    result =
      with {:ok, raw} <- TicketCheckoutIO.readback(intent),
           true <- TicketCheckoutIO.receipt_valid?(raw, intent) or {:error, :ticket_checkout_receipt_unproven} do
        finalize(store, intent, raw, authorization, opts)
      end

    case result do
      {:error, reason} -> problem(store, intent, reason)
      success -> success
    end
  end

  defp problem(store, intent, reason) do
    Store.query!(store, "UPDATE ticket_checkout_intents SET phase = 'RECONCILE_REQUIRED', last_error = ? WHERE run_id = ? AND phase != 'READY' AND owner_nonce IS ?", [
      inspect(reason),
      intent["run_id"],
      intent["owner_nonce"]
    ])

    {:error, reason}
  end

  defp finalize(store, intent, raw, authorization, opts, recovered \\ false) do
    case Exqlite.transaction(
           store,
           fn tx ->
             rollback_error(tx, finalize_transaction(tx, intent, raw, authorization, opts, recovered))
           end,
           timeout: 60_000
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_transaction(store, intent, raw, authorization, opts, recovered) do
    receipt = Jason.decode!(raw)
    binding = Jason.decode!(intent["binding_json"])

    with {:ok, current} <- get(store, intent["run_id"]),
         true <- current == intent or {:error, :ticket_checkout_intent_changed},
         true <- successful?(receipt) or recovered or {:error, :ticket_checkout_git_failed},
         {:ok, run} <- RunLedger.get(store, intent["run_id"]),
         :ok <- finalization_binding(store, run, binding, authorization, opts),
         {:ok, checkout} <- checkout_admission(store, run, binding),
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization),
         {:ok, %{run: admitted}} <- RunLedger.update(store, run["run_id"], %{state: "PLANNING", worktree: checkout.path, workspace_state: "MATERIALIZED"}) do
      Store.query!(store, "UPDATE ticket_checkout_intents SET phase = 'READY', receipt_json = ?, last_error = NULL WHERE run_id = ?", [raw, intent["run_id"]])

      if recovered do
        receipt_sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
        payload = Jason.encode!(%{binding_sha256: intent["binding_sha256"], original_receipt_sha256: receipt_sha, base_sha: binding["base_sha"]})

        Store.query!(store, "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, 'TICKET_CHECKOUT_MATERIALIZATION_RECOVERED', ?, ?)", [
          DateTime.to_iso8601(DateTime.utc_now()),
          intent["run_id"],
          payload
        ])
      end

      {:ok, %{status: "CHECKOUT_ADMITTED", run: admitted, model_invoked: false}}
    end
  end

  defp successful?(receipt),
    do: receipt["termination"] == %{"kind" => "exited", "code" => 0} and not receipt["timed_out"] and not receipt["overflow"]

  defp checkout_admission(store, run, binding) do
    source = Map.put(run, "worktree", binding["path"])
    WorkspaceAccess.checkout_admission(store, source, binding["base_sha"], binding["workspace_root"])
  end

  defp finalization_binding(store, run, captured, authorization, opts) do
    with :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, chat} <- TicketChat.ready_for_run(store, run["run_id"]),
         true <- initial?(store, run) or {:error, :ticket_checkout_not_initial},
         {:ok, current} <- binding(store, run, chat, opts),
         true <- current == captured or {:error, :ticket_checkout_intent_changed},
         :ok <- WorkspaceAccess.source_capacity(store, run, opts) do
      TicketWorkerRunner.validate_authorization(run, authorization)
    end
  end

  @doc "Claims one prepared intent once; an uncertain claim never authorizes a retry."
  @spec claim(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(store, run_id, authorization, opts) do
    case Exqlite.transaction(store, &rollback_error(&1, claim_transaction(&1, run_id, authorization, opts))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_transaction(store, run_id, authorization, opts) do
    with {:ok, intent} <- reserve_transaction(store, run_id, authorization, opts),
         true <- (intent["phase"] == "PREPARED" and is_nil(intent["owner_nonce"])) or {:error, :ticket_checkout_already_claimed},
         {:error, :enoent} <- File.lstat(intent["canonical_path"]),
         {:ok, run} <- RunLedger.get(store, run_id),
         :ok <- WorkspaceAccess.source_capacity(store, run, opts),
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization) do
      nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      result =
        Store.query!(
          store,
          "UPDATE ticket_checkout_intents SET phase = 'MUTATING_UNCERTAIN', owner_nonce = ? WHERE run_id = ? AND phase = 'PREPARED' AND owner_nonce IS NULL AND binding_sha256 = ? RETURNING run_id",
          [
            nonce,
            run_id,
            intent["binding_sha256"]
          ]
        )

      if result.rows == [[run_id]], do: get(store, run_id), else: {:error, :ticket_checkout_already_claimed}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_checkout_path_or_branch_owned}
    end
  end

  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, atom()}
  def get(store, run_id) do
    case Store.one!(store, "SELECT * FROM ticket_checkout_intents WHERE run_id = ?", [run_id]) do
      nil -> {:error, :ticket_checkout_intent_missing}
      row -> {:ok, row}
    end
  end

  defp reserve_transaction(store, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         true <- is_nil(opts[:expected_run]) or run == opts[:expected_run] or {:error, :ticket_checkout_run_changed},
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         {:ok, chat} <- TicketChat.ready_for_run(store, run_id),
         true <- parent_matches?(run, chat) or {:error, :ticket_checkout_parent_mismatch},
         true <- initial?(store, run) or {:error, :ticket_checkout_not_initial},
         {:ok, binding} <- binding(store, run, chat, opts),
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization) do
      reserve_binding(store, run, binding, authorization, opts)
    end
  end

  defp reserve_binding(store, run, binding, authorization, opts) do
    json = Jason.encode!(binding)
    digest = hash(json)

    case get(store, run["run_id"]) do
      {:ok, row} ->
        if row["binding_json"] == json and row["binding_sha256"] == digest,
          do: {:ok, row},
          else: {:error, :ticket_checkout_intent_changed}

      {:error, :ticket_checkout_intent_missing} ->
        prepare(store, run, binding, json, digest, authorization, opts)
    end
  end

  defp initial?(store, run) do
    run["state"] == "ADMITTING_WRITER" and is_nil(run["worktree"]) and is_nil(run["candidate_sha"]) and
      Store.one!(store, "SELECT task_key FROM factory_tasks WHERE run_id = ? LIMIT 1", [run["run_id"]]) == nil and
      Store.one!(store, "SELECT reservation_key FROM workspace_access WHERE run_id = ? AND released_at IS NULL LIMIT 1", [run["run_id"]]) == nil
  end

  defp binding(store, run, chat, opts) do
    root = opts[:workspace_root]
    sha = opts[:base_sha]

    with true <- is_binary(root) and Path.type(root) == :absolute,
         {:ok, ^root} <- PathSafety.canonicalize(root),
         {:ok, %File.Stat{type: :directory} = root_stat} <- File.stat(root),
         {:ok, repo} <- PathSafety.canonicalize(run["repo_path"]),
         configured_repo when is_binary(configured_repo) <- get_in(opts[:capacity_policy], ["repositories", run["repo_key"], "path"]),
         {:ok, ^repo} <- PathSafety.canonicalize(configured_repo),
         {:ok, %File.Stat{type: :directory} = repo_stat} <- File.stat(repo),
         {:ok, repository_identity} <- Worktree.repository_identity(repo),
         bootstrap when is_map(bootstrap) <- Store.one!(store, "SELECT * FROM desktop_requests WHERE request_key = ?", [chat["create_request_key"]]),
         true <- root != repo and not String.starts_with?(root, repo <> "/"),
         true <- root_stat.major_device == repo_stat.major_device,
         true <- is_binary(sha) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha),
         true <- is_binary(run["branch"]) and run["branch"] not in ["main", "master", run["base_branch"]],
         route = %{"workspace_root" => root},
         path = Worktree.writer_path(route, run["issue_key"], run["run_id"]),
         {:ok, ^path} <- PathSafety.canonicalize(path) do
      {:ok,
       %{
         "run" => Map.take(run, @run_fields),
         "parent" => Map.take(chat, ~w(chat_key generation thread_id create_request_key)),
         "bootstrap" =>
           Map.take(
             bootstrap,
             ~w(target_kind target_key action status payload_json payload_sha256 metadata_json output_json target_observation_json thread_id turn_id verified_cwd verified_project_id)
           ),
         "repo_path" => repo,
         "repo_device" => repo_stat.major_device,
         "repo_inode" => repo_stat.inode,
         "repository_identity" => repository_identity,
         "workspace_root" => root,
         "root_device" => root_stat.major_device,
         "root_inode" => root_stat.inode,
         "path" => path,
         "base_sha" => sha
       }}
    else
      _ -> {:error, :ticket_checkout_binding_unproven}
    end
  end

  defp parent_matches?(run, chat) do
    case Jason.decode(run["snapshot_json"] || "") do
      {:ok, snapshot} -> {run["issue_key"], run["repo_key"], snapshot["id"]} == {chat["issue_key"], chat["repo_key"], chat["issue_id"]}
      _ -> false
    end
  end

  defp prepare(store, run, binding, json, digest, authorization, opts) do
    with {:error, :enoent} <- File.lstat(binding["path"]),
         nil <-
           Store.one!(
             store,
             "SELECT i.run_id FROM ticket_checkout_intents i JOIN runs r ON r.run_id = i.run_id WHERE i.canonical_path = ? OR ((i.repo_path = ? OR json_extract(i.binding_json, '$.repository_identity.common_path') = ?) AND i.branch = ?) OR (r.issue_key = ? AND i.phase != 'READY')",
             [binding["path"], binding["repo_path"], binding["repository_identity"]["common_path"], run["branch"], run["issue_key"]]
           ),
         :ok <- WorkspaceAccess.source_capacity(store, run, opts),
         {:ok, _} <- TicketWorkerRunner.bind_base(store, run["run_id"], binding["base_sha"]),
         :ok <- TicketWorkerRunner.validate_authorization(run, authorization) do
      Store.query!(store, "INSERT INTO ticket_checkout_intents(run_id, canonical_path, repo_path, branch, binding_json, binding_sha256, phase) VALUES (?, ?, ?, ?, ?, ?, 'PREPARED')", [
        run["run_id"],
        binding["path"],
        binding["repo_path"],
        run["branch"],
        json,
        digest
      ])

      get(store, run["run_id"])
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_checkout_path_or_branch_owned}
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
