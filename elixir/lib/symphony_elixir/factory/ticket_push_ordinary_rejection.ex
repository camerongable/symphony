defmodule SymphonyElixir.Factory.TicketPushOrdinaryRejection do
  @moduledoc "Audited ordinary-verifier rejection retirement without inventing a CI claim."
  alias SymphonyElixir.Factory.{
    RunLedger,
    Store,
    TicketPush,
    TicketPushIO,
    TicketPushRecovery,
    WorkspaceAccess,
    Worktree
  }

  @event "TICKET_ORDINARY_PUSH_REJECTION_RETIRED"
  @kind "AUDITED_V15_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"
  @resource Path.expand("../../../priv/ticket_push_ordinary_rejection_v1.json", __DIR__)
  @external_resource @resource
  @resource_sha :crypto.hash(:sha256, File.read!(@resource)) |> Base.encode16(case: :lower)
  @successor_kind "AUDITED_V16_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"
  @successor_resource Path.expand("../../../priv/ticket_push_ordinary_rejection_v2.json", __DIR__)
  @external_resource @successor_resource
  @successor_resource_sha :crypto.hash(:sha256, File.read!(@successor_resource)) |> Base.encode16(case: :lower)
  @forward_kind "AUDITED_V24_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"
  @forward_resource Path.expand("../../../priv/ticket_push_ordinary_rejection_v3.json", __DIR__)
  @external_resource @forward_resource
  @forward_resource_sha :crypto.hash(:sha256, File.read!(@forward_resource)) |> Base.encode16(case: :lower)
  @audit_resources [
    {"ticket_push_ordinary_rejection_v1.json", @resource_sha, 1, @kind},
    {"ticket_push_ordinary_rejection_v2.json", @successor_resource_sha, 2, @successor_kind},
    {"ticket_push_ordinary_rejection_v3.json", @forward_resource_sha, 3, @forward_kind}
  ]
  @audit_count length(@audit_resources)
  @direct_status_audits Enum.filter(@audit_resources, fn {_name, _sha, version, _kind} -> version in [1, 2] end)
  @context_fields ~w(state candidate_sha code_repair_round verifier_round spec_revision contract_sha256)

  defp audit(original_sha) do
    with {:ok, values} <- read_audits(),
         [value] <- Enum.filter(values, &(&1["original_sha256"] == original_sha)) do
      {:ok, value}
    else
      _ -> {:error, :ordinary_rejection_audit_changed}
    end
  end

  defp read_audits do
    Enum.reduce_while(@audit_resources, {:ok, []}, fn {name, expected, version, kind}, {:ok, values} ->
      with {:ok, raw} <- File.read(Application.app_dir(:symphony_elixir, "priv/" <> name)),
           true <- hash(raw) == expected,
           {:ok, %{"version" => ^version, "kind" => ^kind} = value} <- Jason.decode(raw) do
        {:cont, {:ok, values ++ [Map.put(value, "audit_sha256", expected)]}}
      else
        _ -> {:halt, {:error, :ordinary_rejection_audit_changed}}
      end
    end)
  end

  @spec eligible?(map()) :: boolean()
  def eligible?(run) do
    case audit(hash(run["candidate_handoff"])) do
      {:ok, audit} ->
        run["state"] == "CI_PUSHING" and
          Map.take(run, ~w(run_id candidate_sha contract_sha256 code_repair_round)) == Map.take(audit, ~w(run_id candidate_sha contract_sha256 code_repair_round)) and
          hash(run["candidate_handoff"]) == audit["original_sha256"]

      _ ->
        false
    end
  end

  @spec status_execution?(map()) :: boolean()
  def status_execution?(execution) do
    Enum.any?(@direct_status_audits, fn {resource, _sha, _version, _kind} ->
      with {:ok, raw} <- File.read(Application.app_dir(:symphony_elixir, "priv/" <> resource)),
           {:ok, value} <- Jason.decode(raw),
           {:ok, audit} <- audit(value["original_sha256"]) do
        hash(Jason.encode!(execution)) == audit["execution_sha256"] and
          Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256)) == Map.take(audit, ~w(helper_path helper_sha256 companion_path companion_sha256))
      else
        _ -> false
      end
    end)
  end

  @spec closed_authority(map(), map()) :: {:ok, map()} | {:error, term()}
  def closed_authority(run, intent) do
    with true <- eligible?(run),
         {:ok, audit} <- audit(hash(run["candidate_handoff"])),
         true <- {intent["helper_pid"], intent["owner_nonce"]} == {audit["helper_pid"], audit["original_nonce"]},
         true <- hash(intent["execution_json"]) == audit["execution_sha256"],
         {:ok, raw} <- TicketPushIO.readback(intent),
         {:ok, reason} <- TicketPushIO.rejection_reason(raw, intent),
         true <- reason == audit["reason"] and hash(raw) == audit["rejection_sha256"],
         {"", 1} <- System.cmd("/bin/ps", ["-p", Integer.to_string(audit["helper_pid"]), "-o", "pid="], stderr_to_stdout: true),
         {:ok, remote} <- Worktree.read_remote_branch(%{"path" => run["repo_path"]}, run["branch"]),
         true <- remote == audit["expected_remote_sha"] do
      {:ok, %{"kind" => audit["kind"], "audit_sha256" => audit["audit_sha256"], "rejection_json" => raw, "rejection_sha256" => hash(raw)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ordinary_rejection_authority_unproven}
    end
  end

  @spec rearm(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def rearm(%DBConnection{}, _run_id, _authorization, _opts), do: {:error, :workspace_observation_inside_transaction}

  def rearm(store, run_id, authorization, opts) do
    with true <- opts[:ordinary_controller_tick] == true or {:error, :push_rejection_normal_tick_required},
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, observed} <- TicketPush.recovery_observation(store, run_id, run["candidate_handoff"], authorization, opts),
         {:ok, proof} <- closed_authority(observed.run, observed.intent),
         {:ok, audit} <- audit(hash(observed.run["candidate_handoff"])),
         :ok <- ordinary_binding(observed.binding, audit),
         {:ok, _preflight} <- TicketPushIO.prepare(store, observed.intent, authorization, opts),
         {:ok, ^proof} <- closed_authority(observed.run, observed.intent) do
      commit(store, observed, proof, tick, authorization, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :ordinary_rejection_preimage_changed}
    end
  end

  defp ordinary_binding(binding, audit) do
    with %{"kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1"} = ordinary <- binding["ordinary_verifier_repair"],
         true <- not Map.has_key?(binding, "ci_repair") and binding["ordinary_preissuance_retirement"] == audit["prior_retirement_ref"],
         true <- hash(Jason.encode!(ordinary)) == audit["ordinary_verifier_repair_sha256"] do
      if is_nil(audit["current_context"]) or Map.take(binding, @context_fields) == audit["current_context"],
        do: :ok,
        else: {:error, :ordinary_rejection_lineage_changed}
    else
      _ -> {:error, :ordinary_rejection_lineage_changed}
    end
  end

  defp commit(store, observed, proof, tick, authorization, opts) do
    WorkspaceAccess.acquire_with(store, observed.attrs, opts, fn tx, access ->
      with {:ok, ^tick} <- TicketPushRecovery.tick_binding(tx, opts),
           :ok <- TicketPush.recheck_recovery_observation(tx, observed, access, authorization, opts),
           {:ok, audit} <- audit(hash(observed.run["candidate_handoff"])),
           :ok <- prior_records(tx, observed.run["run_id"], audit),
           nil <- Store.one!(tx, "SELECT retirement_key FROM ticket_push_rejection_retirements WHERE run_id=? AND original_nonce=?", [observed.run["run_id"], observed.intent["owner_nonce"]]) do
        append_successor(tx, observed, access, proof, tick, opts)
      else
        {:error, _} = error -> error
        _ -> {:error, :ordinary_rejection_preimage_changed}
      end
    end)
  end

  defp prior_records(store, run_id, audit) do
    validate_prefix(store, records(store, run_id), audit)
  end

  defp append_successor(tx, observed, access, proof, tick, opts) do
    original = observed.run["candidate_handoff"]
    key = "ordinary-push-rejection:" <> hash(original <> proof["rejection_sha256"])

    value = %{
      "version" => 1,
      "kind" => "ORDINARY_PUSH_REJECTION_RETIREMENT_V1",
      "run_id" => observed.run["run_id"],
      "retirement_key" => key,
      "original_envelope" => original,
      "original_sha256" => hash(original),
      "original_nonce" => observed.intent["owner_nonce"],
      "proof" => proof,
      "tick" => tick,
      "prior_access_sha256" => hash(Jason.encode!(access)),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    raw = Jason.encode!(value)
    [[id]] = Store.query!(tx, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES(?,?,?,?) RETURNING id", [@event, value["run_id"], raw, value["created_at"]]).rows
    record = %{"id" => id, "payload_json" => raw}
    ref = identity(record, value)
    binding = Map.put(observed.binding, "ordinary_preissuance_retirement", ref) |> Jason.encode!()
    nonce = hash(key <> ":successor:1")
    plan = %{"run_id" => value["run_id"], "original_envelope" => original, "proof_json" => raw, "successor_reservation_key" => "ticket-push:" <> hash(binding), "record" => record}

    with {:ok, successor} <- WorkspaceAccess.transfer_ordinary_preissuance_rejection(tx, plan, access, opts),
         intent =
           Map.merge(observed.intent, %{
             "phase" => "PREPARED",
             "owner_nonce" => nonce,
             "binding_json" => binding,
             "binding_sha256" => hash(binding),
             "reservation_key" => successor["reservation_key"],
             "reservation_generation" => successor["generation"],
             "helper_pid" => nil,
             "execution_json" => nil
           }),
         [[_]] <- Store.query!(tx, "UPDATE runs SET candidate_handoff=? WHERE run_id=? AND candidate_handoff=? RETURNING run_id", [Jason.encode!(intent), value["run_id"], original]).rows do
      {:ok, %{status: "PUSH_REJECTION_RETIRED", run_id: value["run_id"], successor_nonce: nonce}}
    else
      {:error, _} = error -> error
      _ -> {:error, :ordinary_rejection_preimage_changed}
    end
  end

  defp records(store, run_id) do
    result = Store.query!(store, "SELECT id,payload_json FROM events WHERE run_id=? AND event_type=? ORDER BY id", [run_id, @event])
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp identity(record, value),
    do: %{"event_id" => record["id"], "event_sha256" => hash(record["payload_json"]), "retirement_key" => value["retirement_key"], "original_sha256" => value["original_sha256"], "attempt" => 1}

  @spec validate_record(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def validate_record(store, record) do
    with true <- byte_size(record["payload_json"]) <= 1_048_576,
         {:ok, value} <- Jason.decode(record["payload_json"]),
         {:ok, audit} <- audit(value["original_sha256"]),
         captured = records(store, audit["run_id"]),
         true <- length(captured) in 1..@audit_count and record in captured,
         prefix = Enum.take_while(captured, &(&1["id"] < record["id"])),
         :ok <- validate_prefix(store, prefix, audit),
         true <- value["version"] == 1 and value["kind"] == "ORDINARY_PUSH_REJECTION_RETIREMENT_V1" and value["run_id"] == audit["run_id"],
         true <- value["original_sha256"] == audit["original_sha256"] and hash(value["original_envelope"]) == audit["original_sha256"],
         {:ok, original} <- Jason.decode(value["original_envelope"]),
         true <- original["phase"] == "PUSH_UNCERTAIN" and original["owner_nonce"] == audit["original_nonce"] and value["original_nonce"] == audit["original_nonce"],
         true <- original["helper_pid"] == audit["helper_pid"] and hash(original["execution_json"]) == audit["execution_sha256"],
         true <- Enum.all?(~w(receipt_json receipt_sha256 remote_sha), &is_nil(original[&1])),
         proof = value["proof"],
         true <- proof["kind"] == audit["kind"] and proof["audit_sha256"] == audit["audit_sha256"],
         true <- proof["rejection_sha256"] == audit["rejection_sha256"],
         true <- hash(proof["rejection_json"]) == audit["rejection_sha256"],
         {:ok, rejected} <- Jason.decode(proof["rejection_json"]),
         true <-
           rejected == %{
             "version" => 1,
             "kind" => "PREISSUANCE_REJECTED",
             "execution_json" => original["execution_json"],
             "helper_pid" => original["helper_pid"],
             "child_pid" => nil,
             "reason" => audit["reason"]
           },
         true <- value["retirement_key"] == "ordinary-push-rejection:" <> hash(value["original_envelope"] <> audit["rejection_sha256"]),
         {:ok, binding} <- Jason.decode(original["binding_json"]),
         :ok <- ordinary_binding(binding, audit) do
      {:ok, value}
    else
      _ -> {:error, :ordinary_rejection_lineage_changed}
    end
  end

  defp validate_prefix(store, prefix, audit) do
    case audit["closed_prior_retirements"] do
      nil -> validate_linked_prefix(store, prefix, audit["prior_retirement_ref"])
      sealed when is_list(sealed) -> validate_closed_prefix(store, prefix, audit, sealed)
      _ -> {:error, :ordinary_rejection_lineage_changed}
    end
  end

  defp validate_closed_prefix(store, prefix, audit, sealed) do
    with true <- audit["version"] == 3 and audit["kind"] == @forward_kind and is_nil(audit["prior_retirement_ref"]),
         true <- length(prefix) == 2 and length(sealed) == 2,
         {:ok, values} <- validated_records(store, prefix),
         true <- Enum.zip_with(prefix, values, &identity/2) == sealed,
         context when is_map(context) <- audit["current_context"],
         true <- Enum.sort(Map.keys(context)) == Enum.sort(@context_fields),
         true <- Enum.all?(values, &different_context?(&1, context)) do
      :ok
    else
      _ -> {:error, :ordinary_rejection_lineage_changed}
    end
  end

  defp validated_records(store, captured) do
    Enum.reduce_while(captured, {:ok, []}, fn record, {:ok, values} ->
      case validate_record(store, record) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp different_context?(value, context) do
    with {:ok, original} <- Jason.decode(value["original_envelope"]),
         {:ok, previous} <- Jason.decode(original["binding_json"]) do
      Map.take(previous, @context_fields) != Map.take(context, @context_fields)
    else
      _ -> false
    end
  end

  defp validate_linked_prefix(_store, [], nil), do: :ok

  defp validate_linked_prefix(store, [record], ref) when is_map(ref) do
    with {:ok, value} <- validate_record(store, record),
         true <- identity(record, value) == ref do
      :ok
    else
      _ -> {:error, :ordinary_rejection_lineage_changed}
    end
  end

  defp validate_linked_prefix(_store, _records, _ref), do: {:error, :ordinary_rejection_lineage_changed}

  @spec bind(Store.connection(), map(), map()) :: map()
  def bind(store, run, binding) do
    Enum.reduce(records(store, run["run_id"]), binding, fn record, current ->
      with {:ok, value} <- validate_record(store, record),
           {:ok, original} <- Jason.decode(value["original_envelope"]),
           true <- Jason.decode!(original["binding_json"]) == current do
        Map.put(current, "ordinary_preissuance_retirement", identity(record, value))
      else
        _ -> current
      end
    end)
  end

  @spec current(Store.connection(), map(), map(), map()) :: :ok | {:error, term()}
  def current(store, run, intent, binding) do
    case {records(store, run["run_id"]), binding["ordinary_preissuance_retirement"]} do
      {[], nil} ->
        :ok

      {captured, ref} when is_map(ref) and length(captured) in 1..@audit_count ->
        record = List.last(captured)

        with {:ok, value} <- validate_record(store, record),
             true <- identity(record, value) == ref,
             {:ok, original} <- Jason.decode(value["original_envelope"]),
             {:ok, previous} <- Jason.decode(original["binding_json"]),
             true <- Map.put(previous, "ordinary_preissuance_retirement", ref) == binding,
             true <- bind(store, run, Map.delete(binding, "ordinary_preissuance_retirement")) == binding,
             true <- hash(Jason.encode!(binding)) == intent["binding_sha256"],
             true <- intent["owner_nonce"] == hash(value["retirement_key"] <> ":successor:1"),
             {:ok, access} <- WorkspaceAccess.get(store, original["reservation_key"]),
             true <- not is_nil(access["released_at"]) and access["release_receipt_json"] == record["payload_json"],
             true <- hash(Jason.encode!(%{access | "released_at" => nil, "release_receipt_json" => nil})) == value["prior_access_sha256"] do
          :ok
        else
          _ -> {:error, :ordinary_rejection_lineage_changed}
        end

      {captured, nil} when length(captured) in 1..@audit_count ->
        with {:ok, values} <- validated_records(store, captured),
             true <- Enum.all?(values, &different_context?(&1, run)) do
          :ok
        else
          _ -> {:error, :ordinary_rejection_lineage_changed}
        end

      _ ->
        {:error, :ordinary_rejection_lineage_changed}
    end
  end

  defp hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp hash(_), do: nil
end
