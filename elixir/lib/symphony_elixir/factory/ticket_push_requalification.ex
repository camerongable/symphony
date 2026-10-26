defmodule SymphonyElixir.Factory.TicketPushRequalification do
  @moduledoc "One-use, normal-tick requalification of an exactly authorized never-issued PREPARED push."

  alias SymphonyElixir.Config

  alias SymphonyElixir.Factory.{
    RunLedger,
    Store,
    TicketPush,
    TicketPushIO,
    TicketPushPreissuanceRejection,
    TicketPushRecovery,
    WorkerFileIO,
    WorkspaceAccess
  }

  @authorization_fields ~w(run_id original_envelope_sha256 original_nonce candidate_sha spec_revision contract_sha256 authorization_reference maximum_implementation_iterations maximum_code_repair_rounds)
  @unissued ~w(helper_pid execution_json receipt_json receipt_sha256 remote_sha)
  @intent_fields ~w(version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha)
  @columns ~w(authorization_key run_id original_nonce original_envelope original_sha256 authorization_json authorization_sha256 proof_json proof_sha256 successor_nonce successor_binding_json successor_binding_sha256 successor_reservation_key created_at)

  @doc "Consumes at most one exact configured authorization; never executes a helper in that tick."
  @spec maybe_requalify(Store.connection(), String.t(), map(), keyword()) ::
          {:ok, :not_applicable | map()} | {:error, term()}
  def maybe_requalify(%DBConnection{}, _run_id, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  def maybe_requalify(store, run_id, authorization, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, selected} <- selected_authorization(run_id) do
      case selected do
        nil -> {:ok, :not_applicable}
        {key, configured, limits} -> qualified_step(store, run, authorization, opts, key, configured, limits)
      end
    end
  end

  defp qualified_step(store, run, authorization, opts, key, configured, limits) do
    case Store.one!(store, "SELECT * FROM ticket_push_prepared_requalifications WHERE authorization_key=?", [key]) do
      nil ->
        with {:ok, tick} <- owned_tick(store, opts),
             :ok <- configuration_scope(run, configured, limits),
             raw when is_binary(raw) <- run["candidate_handoff"],
             {:ok, intent} when is_map(intent) <- Jason.decode(raw) do
          prepare(store, run, raw, intent, authorization, opts, key, configured, limits, tick)
        else
          {:error, _} = error -> error
          _ -> {:error, :push_requalification_preimage_unproven}
        end

      row ->
        consumed_disposition(store, run, row, configured, opts)
    end
  end

  defp owned_tick(store, opts) do
    with true <- opts[:ordinary_controller_tick] == true or {:error, :push_requalification_normal_tick_required},
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         :ok <- tick_scope(tick),
         do: {:ok, tick}
  end

  defp prepare(store, run, raw, intent, authorization, opts, key, configured, limits, tick) do
    with :ok <- original_scope(run, raw, intent, configured),
         {:ok, access} <- original_access(store, run, intent),
         :ok <- quiet(store, run, access),
         {:ok, first_spool} <- absent_artifacts(store, run, intent),
         identity = %{"authorization_key" => key, "original_sha256" => digest(raw), "attempt" => 1},
         owned_opts = Keyword.put(opts, :reservation, %{key: access["reservation_key"], generation: access["generation"]}),
         {:ok, plan} <- TicketPush.observe_preparation(store, run, authorization, owned_opts, raw, identity),
         :ok <- compatible_binding(intent, plan.binding, configured),
         {:ok, second_spool} <- absent_artifacts(store, run, intent),
         true <- first_spool == second_spool or {:error, :push_requalification_spool_changed},
         row = journal(key, run, raw, intent, access, configured, limits, tick, second_spool, plan),
         :ok <- validate(row) do
      attrs = plan.attrs |> Map.put("reservation_key", access["reservation_key"]) |> Map.put("request_key", access["request_key"])

      WorkspaceAccess.acquire_with(store, attrs, opts, fn tx, captured ->
        commit(tx, run, authorization, owned_opts, key, configured, limits, tick, access, captured, plan, row)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :push_requalification_preparation_unproven}
    end
  end

  defp commit(tx, run, authorization, opts, key, configured, limits, tick, access, captured, plan, row) do
    with {:ok, ^run} <- RunLedger.get(tx, run["run_id"]),
         true <- captured == access or {:error, :push_requalification_access_changed},
         {:ok, {^key, ^configured, ^limits}} <- selected_authorization(run["run_id"]),
         {:ok, ^tick} <- TicketPushRecovery.tick_binding(tx, opts),
         :ok <- tick_scope(tick),
         :ok <- quiet(tx, run, access),
         nil <-
           Store.one!(tx, "SELECT authorization_key FROM ticket_push_prepared_requalifications WHERE authorization_key=? OR (run_id=? AND original_nonce=?)", [
             key,
             run["run_id"],
             row["original_nonce"]
           ]),
         :ok <- TicketPush.recheck_preparation(tx, run, authorization, opts, plan, access) do
      placeholders = Enum.map_join(@columns, ",", fn _ -> "?" end)
      Store.query!(tx, "INSERT INTO ticket_push_prepared_requalifications VALUES (#{placeholders})", Enum.map(@columns, &row[&1]))

      with {:ok, successor} <- WorkspaceAccess.transfer_prepared_requalification(tx, row, access, opts),
           {:ok, fresh} <- TicketPush.store_preparation(tx, run, run["candidate_handoff"], plan, successor, row["successor_nonce"]),
           {:ok, updated} <- RunLedger.get(tx, run["run_id"]) do
        Store.query!(tx, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,'TICKET_PUSH_PREPARED_REQUALIFIED',?,?)", [
          row["created_at"],
          run["run_id"],
          Jason.encode!(%{"authorization_key" => key, "original_sha256" => row["original_sha256"], "successor_nonce" => fresh["owner_nonce"], "issuance" => "NOT_ISSUED"})
        ])

        {:ok, %{status: "PUSH_REQUALIFIED", run: updated, model_invoked: false}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :push_requalification_compare_and_swap_failed}
    end
  end

  defp consumed_disposition(store, run, row, configured, opts) do
    with :ok <- validate(row),
         true <- row["authorization_json"] == Jason.encode!(configured),
         {:ok, proof} <- Jason.decode(row["proof_json"]) do
      consumed_intent(store, run, row, proof, opts)
    else
      _ -> {:error, :push_requalification_consumed_lineage_changed}
    end
  end

  defp consumed_intent(store, run, row, proof, opts) do
    case Jason.decode(run["candidate_handoff"] || "null") do
      {:ok, %{"binding_json" => encoded} = intent} when is_binary(encoded) ->
        with {:ok, binding} when is_map(binding) <- Jason.decode(encoded) do
          consumed_binding(store, run, row, proof, opts, intent, binding)
        end

      {:ok, nil} ->
        completed_consumption(store, run, row)

      _ ->
        {:error, :push_requalification_consumed_lineage_changed}
    end
  end

  defp consumed_binding(store, run, row, proof, opts, intent, binding) do
    if binding["prepared_requalification"] == identity(row) do
      with :ok <- current_binding(store, run, intent, binding) do
        consumed_tick(store, run, row, proof, opts, intent)
      end
    else
      completed_consumption(store, run, row)
    end
  end

  defp consumed_tick(store, run, row, proof, opts, intent) do
    if intent["phase"] == "PREPARED" and intent["owner_nonce"] == row["successor_nonce"] do
      with {:ok, tick} <- owned_tick(store, opts) do
        if proof["tick"] == tick,
          do: {:ok, %{status: "PUSH_REQUALIFIED", run: run, model_invoked: false}},
          else: {:ok, :not_applicable}
      end
    else
      {:ok, :not_applicable}
    end
  end

  defp completed_consumption(store, run, row) do
    with {:ok, access} <- completed_access(store, row),
         true <- not is_nil(access["released_at"]) and is_binary(access["release_receipt_json"]),
         {:ok, %{"phase" => "COMPLETED"} = intent} <- Jason.decode(access["release_receipt_json"]),
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         :ok <- current_binding(store, run, intent, binding),
         true <- TicketPushIO.receipt_valid?(intent["receipt_json"], intent) do
      {:ok, :not_applicable}
    else
      _ -> {:error, :push_requalification_consumed_lineage_changed}
    end
  end

  defp completed_access(store, row) do
    expected_nonce = row["successor_nonce"]
    expected_hash = row["successor_binding_sha256"]

    with {:ok, access} <- WorkspaceAccess.get(store, row["successor_reservation_key"]) do
      case Jason.decode(access["release_receipt_json"] || "null") do
        {:ok, %{"phase" => "COMPLETED", "owner_nonce" => ^expected_nonce, "binding_sha256" => ^expected_hash}} ->
          {:ok, access}

        _ ->
          completed_retirement_access(store, row, access)
      end
    end
  end

  defp completed_retirement_access(store, row, access) do
    with {:ok, retirement} <- requalification_retirement(store, row),
         true <- access["release_receipt_json"] == retirement["proof_json"],
         {:ok, child} <- WorkspaceAccess.get(store, retirement["successor_reservation_key"]),
         {:ok, intent} <- Jason.decode(child["release_receipt_json"] || "null"),
         true <- {intent["owner_nonce"], intent["binding_sha256"]} == {retirement["successor_nonce"], retirement["successor_binding_sha256"]} do
      {:ok, child}
    else
      _ -> {:error, :push_requalification_consumed_lineage_changed}
    end
  end

  defp selected_authorization(run_id) do
    case Config.settings() do
      {:ok, %{factory: factory}} ->
        entries = factory.prepared_push_requalifications
        selected = Enum.filter(entries, fn {_key, value} -> is_map(value) and value["run_id"] == run_id end)
        limits = %{"maximum_implementation_iterations" => factory.maximum_implementation_iterations, "maximum_code_repair_rounds" => factory.maximum_code_repair_rounds}

        case selected do
          [] -> {:ok, nil}
          [{key, value}] when is_binary(key) and byte_size(key) in 1..256 -> {:ok, {key, value, limits}}
          _ -> {:error, :push_requalification_authorization_ambiguous}
        end

      _ ->
        {:error, :push_requalification_configuration_unavailable}
    end
  end

  defp tick_scope(tick) do
    case Config.settings() do
      {:ok, %{factory: factory}} ->
        if {tick["scope"], tick["dispatcher_id"]} == {factory.scope, factory.dispatcher_id},
          do: :ok,
          else: {:error, :push_requalification_controller_scope_changed}

      _ ->
        {:error, :push_requalification_configuration_unavailable}
    end
  end

  defp configuration_scope(run, configured, limits)
       when is_map(run) and is_map(configured) and is_map(limits) do
    if Enum.sort(Map.keys(configured)) == Enum.sort(@authorization_fields) and
         configured["run_id"] == run["run_id"] and configured["candidate_sha"] == run["candidate_sha"] and configured["spec_revision"] == run["spec_revision"] and
         configured["contract_sha256"] == run["contract_sha256"] and Map.take(configured, Map.keys(limits)) == limits and
         is_binary(configured["authorization_reference"]) and byte_size(configured["authorization_reference"]) in 1..1024 and
         hex?(configured["original_envelope_sha256"], 64) and hex?(configured["original_nonce"], 64) and hex?(configured["candidate_sha"], 40) and hex?(configured["contract_sha256"], 64) and
         is_integer(configured["spec_revision"]) and configured["spec_revision"] > 0 and
         is_integer(limits["maximum_implementation_iterations"]) and
         limits["maximum_implementation_iterations"] > 0 and
         is_integer(limits["maximum_code_repair_rounds"]) and limits["maximum_code_repair_rounds"] in 0..10,
       do: :ok,
       else: {:error, :push_requalification_configuration_changed}
  end

  defp configuration_scope(_run, _configured, _limits), do: {:error, :push_requalification_configuration_changed}

  defp original_scope(run, raw, intent, configured) do
    if Enum.sort(Map.keys(intent)) == Enum.sort(@intent_fields) and run["state"] in ~w(PUSHING CI_PUSHING) and intent["kind"] == "TICKET_PUSH" and intent["version"] == 1 and
         intent["phase"] == "PREPARED" and
         Enum.all?(@unissued, &is_nil(intent[&1])) and intent["owner_nonce"] == configured["original_nonce"] and digest(raw) == configured["original_envelope_sha256"] and
         is_integer(intent["reservation_generation"]) and intent["reservation_generation"] > 0 and is_binary(intent["binding_json"]) and hex?(intent["binding_sha256"], 64) and
         digest(intent["binding_json"]) == intent["binding_sha256"] and intent["reservation_key"] == "ticket-push:" <> intent["binding_sha256"],
       do: :ok,
       else: {:error, :push_requalification_original_not_unissued}
  end

  defp original_access(store, run, intent) do
    with {:ok, access} <- WorkspaceAccess.validate(store, intent["reservation_key"], intent["reservation_generation"]),
         true <-
           {access["run_id"], access["task_key"], access["request_key"], access["mode"], access["released_at"], access["release_receipt_json"]} ==
             {run["run_id"], nil, intent["reservation_key"], "MAINTENANCE", nil, nil} do
      {:ok, access}
    else
      _ -> {:error, :push_requalification_access_unproven}
    end
  end

  defp quiet(store, run, access) do
    active = Store.one!(store, "SELECT reservation_key FROM workspace_access WHERE run_id=? AND released_at IS NULL AND reservation_key!=? LIMIT 1", [run["run_id"], access["reservation_key"]])
    task = Store.one!(store, "SELECT task_key FROM factory_tasks WHERE run_id=? AND status NOT IN ('COMPLETE','CONSUMED','FAILED','STALE') LIMIT 1", [run["run_id"]])

    check =
      Store.one!(
        store,
        "SELECT c.check_key FROM controller_checks c JOIN workspace_access a ON a.reservation_key=c.reservation_key WHERE a.run_id=? AND a.released_at IS NULL AND c.phase!='COMPLETE' LIMIT 1",
        [run["run_id"]]
      )

    if is_nil(active) and is_nil(task) and is_nil(check), do: :ok, else: {:error, :push_requalification_owner_not_quiet}
  end

  defp absent_artifacts(store, run, intent) do
    with {:ok, spool} <- WorkerFileIO.controller_spool(store, run["repo_path"]),
         true <- Enum.all?(~w(.push-claim .push-receipt .push-rejection), fn suffix -> File.lstat(Path.join(spool["spool"], intent["owner_nonce"] <> suffix)) == {:error, :enoent} end) do
      {:ok, Map.take(spool, ~w(database root spool spool_device spool_inode companion_path companion_sha256))}
    else
      _ -> {:error, :push_requalification_issuance_artifact_present}
    end
  end

  defp compatible_binding(intent, fresh, configured) do
    with {:ok, previous} <- Jason.decode(intent["binding_json"]),
         true <- Map.drop(previous, ["ci_repair_policy_receipt"]) == Map.drop(fresh, ["ci_repair_policy_receipt", "prepared_requalification"]),
         true <- policy_compatible?(previous["ci_repair_policy_receipt"], fresh["ci_repair_policy_receipt"], configured) do
      :ok
    else
      _ -> {:error, :push_requalification_candidate_authority_changed}
    end
  end

  defp policy_compatible?(nil, nil, _configured), do: true

  defp policy_compatible?(old, fresh, configured) when is_map(old) and is_map(fresh) do
    fields = ~w(workflow_sha256 workflow_stat cached_policy_sha256)
    Map.drop(old, fields) == Map.drop(fresh, fields) and fresh["configured_limit"] == configured["maximum_code_repair_rounds"]
  end

  defp policy_compatible?(_, _, _), do: false

  defp journal(key, run, raw, intent, access, configured, limits, tick, spool, plan) do
    authorization = Jason.encode!(configured)
    proof = Jason.encode!(%{"version" => 1, "kind" => "NEVER_ISSUED_PREPARED_REQUALIFICATION_V1", "original_access" => access, "spool" => spool, "tick" => tick, "configured_limits" => limits})

    %{
      "authorization_key" => key,
      "run_id" => run["run_id"],
      "original_nonce" => intent["owner_nonce"],
      "original_envelope" => raw,
      "original_sha256" => digest(raw),
      "authorization_json" => authorization,
      "authorization_sha256" => digest(authorization),
      "proof_json" => proof,
      "proof_sha256" => digest(proof),
      "successor_nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      "successor_binding_json" => plan.encoded,
      "successor_binding_sha256" => digest(plan.encoded),
      "successor_reservation_key" => plan.key,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  @doc false
  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(row) do
    with true <- is_map(row) and Enum.sort(Map.keys(row)) == Enum.sort(@columns),
         true <- Enum.all?(Map.values(row), &is_binary/1),
         true <- byte_size(row["authorization_key"]) in 1..256,
         true <- byte_size(Jason.encode!(row)) <= 8_388_608,
         true <-
           Enum.all?(~w(original authorization proof successor_binding), fn prefix -> digest(row[prefix <> if(prefix == "original", do: "_envelope", else: "_json")]) == row[prefix <> "_sha256"] end),
         {:ok, authorization} when is_map(authorization) <- Jason.decode(row["authorization_json"]),
         {:ok, original} when is_map(original) <- Jason.decode(row["original_envelope"]),
         {:ok, proof} when is_map(proof) <- Jason.decode(row["proof_json"]),
         {:ok, fresh} when is_map(fresh) <- Jason.decode(row["successor_binding_json"]),
         true <- Enum.sort(Map.keys(proof)) == ~w(configured_limits kind original_access spool tick version),
         true <- proof["version"] == 1 and proof["kind"] == "NEVER_ISSUED_PREPARED_REQUALIFICATION_V1",
         true <- valid_tick?(proof["tick"]),
         :ok <- configuration_scope(fresh, authorization, proof["configured_limits"]),
         true <- original["owner_nonce"] == row["original_nonce"] and row["original_nonce"] != row["successor_nonce"] and hex?(row["successor_nonce"], 64),
         :ok <- original_scope(fresh, row["original_envelope"], original, authorization),
         access when is_map(access) <- proof["original_access"],
         true <-
           {access["run_id"], access["reservation_key"], access["generation"], access["task_key"], access["request_key"], access["mode"], access["released_at"], access["release_receipt_json"]} ==
             {row["run_id"], original["reservation_key"], original["reservation_generation"], nil, original["reservation_key"], "MAINTENANCE", nil, nil},
         true <- fresh["prepared_requalification"] == identity(row) and row["successor_reservation_key"] == "ticket-push:" <> row["successor_binding_sha256"],
         true <- authorization["run_id"] == row["run_id"] and fresh["run_id"] == row["run_id"],
         :ok <- compatible_binding(original, fresh, authorization) do
      :ok
    else
      _ -> {:error, :push_requalification_journal_unproven}
    end
  end

  @doc false
  @spec bind(Store.connection(), map(), map(), map() | nil) :: map()
  def bind(_store, _run, binding, identity) when is_map(identity), do: Map.put(binding, "prepared_requalification", identity)

  def bind(store, run, binding, nil) do
    with {:ok, intent} <- Jason.decode(run["candidate_handoff"] || "null"),
         {:ok, previous} <- Jason.decode(intent["binding_json"] || "null"),
         reference when is_map(reference) <- previous["prepared_requalification"],
         true <- Map.take(previous, ~w(candidate_sha contract_sha256 spec_revision code_repair_round)) == Map.take(binding, ~w(candidate_sha contract_sha256 spec_revision code_repair_round)),
         :ok <- current_binding(store, run, intent, previous) do
      Map.put(binding, "prepared_requalification", reference)
    else
      _ -> binding
    end
  end

  @doc false
  @spec current_binding(Store.connection(), map(), map(), map()) :: :ok | {:error, atom()}
  def current_binding(store, run, intent, binding) do
    case binding["prepared_requalification"] do
      nil ->
        if is_nil(
             Store.one!(store, "SELECT authorization_key FROM ticket_push_prepared_requalifications WHERE run_id=? AND (original_nonce=? OR successor_nonce=?) LIMIT 1", [
               run["run_id"],
               intent["owner_nonce"],
               intent["owner_nonce"]
             ])
           ),
           do: :ok,
           else: {:error, :push_requalification_lineage_changed}

      reference when is_map(reference) ->
        with row when is_map(row) <- Store.one!(store, "SELECT * FROM ticket_push_prepared_requalifications WHERE authorization_key=? AND run_id=?", [reference["authorization_key"], run["run_id"]]),
             :ok <- validate(row),
             true <- reference == identity(row),
             {:ok, original} <- Jason.decode(row["original_envelope"]),
             {:ok, proof} <- Jason.decode(row["proof_json"]),
             {:ok, retired} <- WorkspaceAccess.get(store, original["reservation_key"]),
             true <- not is_nil(retired["released_at"]) and retired["release_receipt_json"] == row["proof_json"],
             true <- Map.drop(retired, ~w(released_at release_receipt_json)) == Map.drop(proof["original_access"], ~w(released_at release_receipt_json)),
             true <-
               {intent["owner_nonce"], intent["binding_sha256"], intent["reservation_key"]} == {row["successor_nonce"], row["successor_binding_sha256"], row["successor_reservation_key"]} or
                 get_in(binding, ["verified_ci_rollover", "prior_binding_sha256"]) == row["successor_binding_sha256"] or
                 retired_successor?(store, row, intent, binding) do
          :ok
        else
          _ -> {:error, :push_requalification_lineage_changed}
        end

      _ ->
        {:error, :push_requalification_lineage_changed}
    end
  end

  defp retired_successor?(store, row, intent, binding) do
    with {:ok, retirement} <- requalification_retirement(store, row),
         {:ok, access} <- WorkspaceAccess.get(store, row["successor_reservation_key"]),
         true <- not is_nil(access["released_at"]) and access["release_receipt_json"] == retirement["proof_json"] do
      {intent["owner_nonce"], intent["binding_sha256"], intent["reservation_key"]} ==
        {retirement["successor_nonce"], retirement["successor_binding_sha256"], retirement["successor_reservation_key"]} or
        get_in(binding, ["verified_ci_rollover", "prior_binding_sha256"]) == retirement["successor_binding_sha256"]
    else
      _ -> false
    end
  end

  defp requalification_retirement(store, row) do
    with retirement when is_map(retirement) <- Store.one!(store, "SELECT * FROM ticket_push_rejection_retirements WHERE run_id=? AND original_nonce=?", [row["run_id"], row["successor_nonce"]]),
         :ok <- TicketPushPreissuanceRejection.validate_retirement(retirement),
         {:ok, original} <- Jason.decode(retirement["original_envelope"]),
         true <- original["binding_json"] == row["successor_binding_json"] and original["binding_sha256"] == row["successor_binding_sha256"],
         true <- original["reservation_key"] == row["successor_reservation_key"] and original["owner_nonce"] == row["successor_nonce"],
         {:ok, binding} <- Jason.decode(original["binding_json"]),
         expected = Map.put(binding, "preissuance_retirement", TicketPushPreissuanceRejection.identity(retirement)),
         true <- digest(Jason.encode!(expected)) == retirement["successor_binding_sha256"] do
      {:ok, retirement}
    else
      _ -> {:error, :push_requalification_lineage_changed}
    end
  end

  defp valid_tick?(tick) when is_map(tick) do
    Enum.sort(Map.keys(tick)) == ~w(dispatcher_id generation scope tick_id) and is_integer(tick["generation"]) and tick["generation"] > 0 and
      Enum.all?(~w(dispatcher_id scope tick_id), &(is_binary(tick[&1]) and byte_size(tick[&1]) in 1..1024))
  end

  defp valid_tick?(_tick), do: false
  defp identity(row), do: %{"authorization_key" => row["authorization_key"], "original_sha256" => row["original_sha256"], "attempt" => 1}
  defp hex?(value, count), do: is_binary(value) and byte_size(value) == count and String.match?(value, ~r/\A[0-9a-f]+\z/)
  defp digest(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp digest(_), do: nil
end
