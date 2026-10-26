defmodule SymphonyElixir.Factory.TicketCompletionConfirmation do
  @moduledoc "One exact no-edit confirmation after an adopted continuation; never another repair budget."
  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.{FailedTurnRecovery, Policy, ReviewProtocol, RunLedger, StageSchemas, Store}
  alias SymphonyElixir.Factory.{WorkerCheckIO, WorkerEvidence, WorkerInstructions}

  @identity ~w(run_id candidate_sha spec_revision contract_sha256 verifier_round code_repair_round implementation_iteration)
  @fields @identity ++ ~w(version prior_request_key prior_binding_sha256 prior_output_sha256 authorization_reference)
  @rejection_fields ~w(request_key turn_id binding_sha256 evidence_sha256 native_error_sha256 authorization_reference)
  @instruction "This is one controller-authorized completion confirmation, not another implementation pass. Inspect the existing candidate and prior report using read-only tools. Do not edit, delete or create files. If source work is complete, return COMPLETE with changed_paths [] and commit_message null, recording unrun controller checks honestly. Otherwise return BLOCKED with the concrete reason. Never return CONTINUE or claim tests or independent acceptance passed."

  @spec valid_policy?(term()) :: boolean()
  def valid_policy?(entries) when is_map(entries) do
    Enum.all?(entries, fn {key, entry} -> valid_entry?(key, entry) end)
  end

  def valid_policy?(_), do: false

  defp valid_entry?(key, entry) when is_binary(key) and is_map(entry) do
    Enum.sort(Map.keys(Map.delete(entry, "schema_rejection"))) == Enum.sort(@fields) and valid_rejection?(entry["schema_rejection"]) and
      entry["version"] == 1 and entry["run_id"] == key and
      valid_identity_types?(entry) and
      valid_hash?(entry["candidate_sha"], 40) and Enum.all?(~w(contract_sha256 prior_binding_sha256 prior_output_sha256), &valid_hash?(entry[&1], 64))
  end

  defp valid_entry?(_, _), do: false

  defp valid_rejection?(nil), do: true

  defp valid_rejection?(entry) when is_map(entry) do
    Enum.sort(Map.keys(entry)) == Enum.sort(@rejection_fields) and
      Enum.all?(~w(request_key turn_id authorization_reference), &(is_binary(entry[&1]) and String.trim(entry[&1]) != "")) and
      Enum.all?(~w(binding_sha256 evidence_sha256 native_error_sha256), &valid_hash?(entry[&1], 64))
  end

  defp valid_rejection?(_), do: false

  defp valid_identity_types?(entry) do
    Enum.all?(~w(run_id prior_request_key authorization_reference), &(is_binary(entry[&1]) and String.trim(entry[&1]) != "")) and
      Enum.all?(~w(spec_revision verifier_round code_repair_round implementation_iteration), &(is_integer(entry[&1]) and entry[&1] >= 0))
  end

  defp valid_hash?(value, length), do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  @spec authorization(Store.connection(), map(), map()) :: map() | nil
  def authorization(store, run, factory) do
    policy = Map.get(factory, :ticket_supervisor, %{})
    entries = if is_map(policy), do: Map.get(policy, "source_completion_confirmations", %{})
    entry = if is_map(entries), do: entries[run["run_id"]]

    with true <- valid_policy?(entries) and is_map(entry),
         true <- run["execution_mode"] == "TICKET_SUPERVISOR_V1" and run["state"] == "REPAIRING",
         true <- run["implementation_iteration"] == Map.get(factory, :maximum_implementation_iterations),
         true <- Map.take(entry, @identity) == Map.take(run, @identity),
         {:ok, prior} <- consumed_source(store, run, entry),
         marker = entry |> Map.delete("schema_rejection") |> Map.put("instructions", @instruction),
         true <- one_attempt?(store, prior, marker, entry["schema_rejection"]) do
      marker
    else
      _ -> nil
    end
  end

  @doc "Checks explicit schema-only successor authority; does not transfer, launch, or rewrite evidence."
  @spec schema_recovery_scope(Store.connection(), map()) :: {:ok, map()} | {:error, atom()}
  def schema_recovery_scope(store, old) do
    factory = Config.settings!().factory
    entry = get_in(factory.ticket_supervisor, ["source_completion_confirmations", old["run_id"]])

    with true <- is_map(entry) and valid_entry?(old["run_id"], entry),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         true <- factory.enabled and Policy.ticket_selected?(factory.ticket_supervisor, run["issue_key"]),
         true <- run["state"] == "REPAIRING" and run["execution_mode"] == "TICKET_SUPERVISOR_V1",
         true <- run["implementation_iteration"] == factory.maximum_implementation_iterations,
         true <- Map.take(entry, @identity) == Map.take(run, @identity),
         {:ok, prior} <- consumed_source(store, run, entry),
         %{"request_key" => first} <- Store.one!(store, "SELECT request_key FROM worker_evidence WHERE task_key=? AND rowid>? ORDER BY rowid LIMIT 1", [prior["task_key"], prior["evidence_rowid"]]),
         true <- first == old["request_key"],
         marker = entry |> Map.delete("schema_rejection") |> Map.put("instructions", @instruction),
         true <- rejected_attempt?(store, old["request_key"], marker, prior, entry["schema_rejection"]) do
      {:ok,
       %{
         "kind" => "SOURCE_COMPLETION_SCHEMA_REJECTION_V1",
         "authorization" => entry["schema_rejection"],
         "completion_marker_sha256" => digest(Jason.encode!(marker)),
         "scope" => factory.scope,
         "dispatcher_id" => factory.dispatcher_id
       }}
    else
      _ -> {:error, :completion_schema_recovery_not_authorized}
    end
  end

  @spec attach(Store.connection(), map()) :: map()
  def attach(store, %{"role" => "feature-writer"} = packet) do
    with {:ok, run} <- RunLedger.get(store, packet["run_id"]),
         true <- Map.take(packet, @identity) == Map.take(run, @identity),
         marker when is_map(marker) <- authorization(store, run, Config.settings!().factory) do
      Map.put(packet, "completion_confirmation", marker)
    else
      _ -> packet
    end
  end

  def attach(_store, packet), do: packet

  @spec validate_prompt(map() | nil, String.t()) :: :ok | {:error, atom()}
  def validate_prompt(nil, _prompt), do: :ok

  def validate_prompt(marker, prompt) do
    with {:ok, packet} <- Jason.decode(prompt),
         packet = confirmation_packet(packet),
         true <- packet["completion_confirmation"] == marker do
      :ok
    else
      _ -> {:error, :completion_confirmation_prompt_changed}
    end
  end

  defp confirmation_packet(%{"controller_failed_turn_recovery" => "TFER-" <> _, "base_packet" => packet}), do: packet
  defp confirmation_packet(packet), do: packet

  @spec schema(map(), map()) :: map()
  def schema(%{"completion_confirmation" => %{"version" => 1}, "role" => "feature-writer"}, schema) do
    schema
    |> put_in(["properties", "status", "enum"], ~w(COMPLETE BLOCKED))
    |> put_in(["properties", "changed_paths", "enum"], [[]])
    |> put_in(["properties", "commit_message", "enum"], [nil])
  end

  def schema(_packet, schema), do: schema

  @spec authorize_mutation(map()) :: :ok | {:error, atom()}
  def authorize_mutation(evidence) do
    case Jason.decode(evidence["binding_json"]) do
      {:ok, binding} ->
        if get_in(binding, ["schema", "properties", "changed_paths", "enum"]) == [[]],
          do: {:error, :completion_confirmation_read_only},
          else: :ok

      _ ->
        {:error, :completion_evidence_changed}
    end
  end

  defp consumed_source(store, run, entry) do
    with row when is_map(row) <- Store.one!(store, "SELECT rowid AS evidence_rowid,* FROM worker_evidence WHERE request_key=?", [entry["prior_request_key"]]),
         true <- row["status"] == "CONSUMED" and row["run_id"] == run["run_id"],
         true <- row["binding_sha256"] == entry["prior_binding_sha256"] and row["output_sha256"] == entry["prior_output_sha256"],
         {:ok, binding} <- checked(row, "binding"),
         {:ok, %{"status" => "CONTINUE", "blockers" => []} = output} <- checked(row, "output"),
         true <- binding["role"] == "feature-writer" and binding["stage"] == "REPAIRING" and binding["mode"] == "SOURCE",
         true <- Map.take(binding, ~w(run_id spec_revision contract_sha256)) == Map.take(run, ~w(run_id spec_revision contract_sha256)),
         true <- WorkerEvidence.owner_stopped?(store, row),
         :ok <- released_source(store, row),
         {:ok, %{"review_protocol" => %{"version" => 1}} = packet} <- archived_packet(store, row, binding),
         true <- predecessor_scope?(packet, run, binding),
         :ok <- ReviewProtocol.validate(packet, binding, output),
         true <- candidate_checked?(store, row, run) do
      {:ok, row}
    else
      _ -> {:error, :completion_predecessor_unproven}
    end
  end

  defp predecessor_scope?(packet, run, binding) do
    fields = ~w(run_id spec_revision contract_sha256 verifier_round code_repair_round)

    Map.take(packet, fields) == Map.take(run, fields) and is_integer(packet["implementation_iteration"]) and
      packet["implementation_iteration"] + 1 == run["implementation_iteration"] and packet["candidate_sha"] == binding["expected_sha"]
  end

  defp released_source(store, row) do
    fields = ~w(request_key binding_sha256 output_sha256 consumed_at owner_stopped_at)

    with access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [row["reservation_key"]]),
         true <- access["mode"] == "SOURCE" and access["request_key"] == row["request_key"] and is_binary(access["released_at"]),
         {:ok, receipt} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- receipt == Map.take(row, fields) and is_binary(row["consumed_at"]) do
      :ok
    else
      _ -> {:error, :completion_source_not_released}
    end
  end

  defp candidate_checked?(store, prior, run) do
    with row when is_map(row) <- Store.one!(store, "SELECT * FROM controller_checks WHERE worker_request_key=? AND phase='COMPLETE'", [prior["request_key"]]),
         {:ok, binding} <- checked(row, "binding"),
         {:ok, %{"result" => "PASS", "candidate_sha" => sha}} <- checked(row, "receipt"),
         true <- row["reservation_key"] == prior["reservation_key"],
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key=?", [prior["reservation_key"]]),
         true <- check_source_binding?(binding, prior, access, run),
         true <- WorkerCheckIO.receipt_valid?(row["receipt_json"], binding, row["helper_pid"]) do
      sha == run["candidate_sha"] and binding["candidate_sha"] == sha and binding["run_id"] == run["run_id"] and binding["action"] == "git-diff-check"
    else
      _ -> false
    end
  end

  defp check_source_binding?(binding, prior, access, run) do
    expected =
      Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256))
      |> Map.merge(%{
        "worker_request_key" => prior["request_key"],
        "worker_binding_sha256" => prior["binding_sha256"],
        "worker_output_sha256" => prior["output_sha256"],
        "worker_stop_sha256" => digest(prior["owner_stop_json"]),
        "reservation_key" => prior["reservation_key"],
        "generation" => access["generation"],
        "workspace_binding_sha256" => digest(access["binding_json"])
      })

    Map.take(binding, Map.keys(expected)) == expected
  end

  defp archived_packet(store, evidence, binding) do
    with mapping when is_map(mapping) <- Store.one!(store, "SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?", [evidence["task_key"], binding["prompt_sha256"]]),
         row when is_map(row) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         {:ok, packet} <- checked(row, "binding"),
         {:ok, _} <- WorkerInstructions.read(store, packet, "feature-writer") do
      {:ok, packet}
    else
      _ -> {:error, :completion_instruction_unproven}
    end
  end

  defp one_attempt?(store, prior, marker, rejection) do
    rows = Store.query!(store, "SELECT request_key FROM worker_evidence WHERE task_key=? AND rowid>? ORDER BY rowid", [prior["task_key"], prior["evidence_rowid"]]).rows

    case rows do
      [] -> true
      [[key]] -> own_attempt?(store, key, marker, prior) or rejected_attempt?(store, key, marker, prior, rejection)
      [[old], [new]] -> schema_successor?(store, old, new, marker, prior, rejection)
      _ -> false
    end
  end

  defp schema_successor?(store, old, new, marker, prior, rejection) do
    with true <- rejected_attempt?(store, old, marker, prior, rejection),
         {:ok, evidence} <- WorkerEvidence.get(store, old),
         true <- FailedTurnRecovery.superseded?(store, evidence),
         event when is_map(event) <-
           Store.one!(store, "SELECT payload_json FROM events WHERE event_type='TICKET_FAILED_TURN_RECOVERY_APPLIED' AND run_id=? AND json_extract(payload_json,'$.old_request_key')=?", [
             prior["run_id"],
             old
           ]),
         {:ok, proof} <- Jason.decode(event["payload_json"]),
         true <- proof["new_request_key"] == new and get_in(proof, ["schema_confirmation", "authorization"]) == rejection do
      own_attempt?(store, new, marker, prior)
    else
      _ -> false
    end
  end

  defp rejected_attempt?(store, key, marker, prior, %{"request_key" => key} = rejection) do
    with {:ok, old} <- WorkerEvidence.get(store, key),
         true <- old["status"] == "RECONCILE_REQUIRED" and old["turn_id"] == rejection["turn_id"],
         true <- digest(Jason.encode!(old)) == rejection["evidence_sha256"] and old["binding_sha256"] == rejection["binding_sha256"],
         true <- old["thread_id"] == prior["thread_id"] and WorkerEvidence.owner_stopped?(store, old),
         true <- Enum.all?(~w(output_json output_sha256 item_id consumed_at), &is_nil(old[&1])),
         nil <- Store.one!(store, "SELECT call_id FROM worker_file_operations WHERE request_key=? LIMIT 1", [key]),
         {:ok, binding} <- checked(old, "binding"),
         {:ok, packet} <- archived_packet(store, old, binding),
         true <- packet["completion_confirmation"] == marker and Map.take(packet, @identity) == Map.take(marker, @identity),
         true <- binding["expected_sha"] == marker["candidate_sha"] and binding["mode"] == "SOURCE" and binding["role"] == "feature-writer" do
      binding["schema"] == ReviewProtocol.schema(packet, StageSchemas.for_stage(:native_feature_writer))
    else
      _ -> false
    end
  end

  defp rejected_attempt?(_, _, _, _, _), do: false

  defp own_attempt?(store, key, marker, prior) do
    with row when is_map(row) <- Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [key]),
         true <- active_attempt?(row),
         true <- is_nil(row["thread_id"]) or row["thread_id"] == prior["thread_id"],
         {:ok, binding} <- checked(row, "binding"),
         {:ok, packet} <- archived_packet(store, row, binding),
         true <- packet["completion_confirmation"] == marker and Map.take(packet, @identity) == Map.take(marker, @identity),
         true <- binding["expected_sha"] == marker["candidate_sha"] do
      binding["schema"] == ReviewProtocol.schema(packet, StageSchemas.for_stage(:native_feature_writer))
    else
      _ -> false
    end
  end

  defp active_attempt?(%{"status" => "RESULT_RECORDED"} = row) do
    case checked(row, "output") do
      {:ok, %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil}} -> true
      _ -> false
    end
  end

  defp active_attempt?(row), do: row["status"] in ~w(RESERVED START_SENT THREAD_BOUND TURN_BOUND)

  defp checked(row, name) do
    raw = row[name <> "_json"]
    if is_binary(raw) and digest(raw) == row[name <> "_sha256"], do: Jason.decode(raw), else: {:error, :completion_evidence_changed}
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
