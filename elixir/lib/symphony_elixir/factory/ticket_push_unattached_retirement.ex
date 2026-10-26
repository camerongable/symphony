defmodule SymphonyElixir.Factory.TicketPushUnattachedRetirement do
  @moduledoc "Explicit retirement of audited, stopped issuers' unissued pushes; never issues input."
  import Bitwise
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketPush, TicketPushIO, TicketPushRecovery, WorkspaceAccess}
  alias SymphonyElixir.PathSafety

  @audit_path Path.expand("../../../priv/ticket_push_unattached_audit_v1.json", __DIR__)
  @external_resource @audit_path
  @audit_sha :crypto.hash(:sha256, File.read!(@audit_path)) |> Base.encode16(case: :lower)
  @preissuance_path Path.expand("../../../priv/ticket_push_preissuance_audit_v1.json", __DIR__)
  @external_resource @preissuance_path
  @preissuance_sha :crypto.hash(:sha256, File.read!(@preissuance_path)) |> Base.encode16(case: :lower)
  @publisher_path Path.expand("ticket_push.ex", __DIR__)
  @external_resource @publisher_path
  @publisher_sha :crypto.hash(:sha256, File.read!(@publisher_path)) |> Base.encode16(case: :lower)
  @event "TICKET_PUSH_UNATTACHED_RETIRED"
  @nonce_constraints ~w(input_retirement preissuance_retirement ordinary_preissuance_retirement)

  @spec prepare(Store.connection(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%DBConnection{}, _operation, _receipt, _authorization, _opts),
    do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, operation, receipt, authorization, opts), do: prepare_case(store, operation, receipt, authorization, opts, :unattached)

  @spec prepare_preissuance(Store.connection(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_preissuance(%DBConnection{}, _operation, _receipt, _authorization, _opts),
    do: {:error, :workspace_observation_inside_transaction}

  def prepare_preissuance(store, operation, receipt, authorization, opts),
    do: prepare_case(store, operation, receipt, authorization, opts, :preissuance)

  defp prepare_case(store, %{run_id: run_id, nonce: nonce} = operation, receipt, authorization, opts, retirement_case) do
    with {:ok, _} <- TicketPushRecovery.tick_binding(store, opts),
         :ok <- human_inputs_clear(store, run_id),
         {:ok, audit} <- audited_identity(retirement_case),
         :ok <- protected_history(store, audit),
         {:ok, proof} <- verify_fence(audit, receipt.path, receipt.sha256),
         {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, intent} <- validate_original(run, operation, audit),
         {:ok, rejection} <- rejection_evidence(intent, audit),
         nil <- prior_retirement(store, run_id, nonce, audit),
         {:ok, observed} <- TicketPush.recovery_observation(store, run_id, run["candidate_handoff"], authorization, opts) do
      prefix = if retirement_case == :unattached, do: "unattached-push:v1:", else: "preissuance-push:v1:"
      successor_nonce = digest(prefix <> operation.envelope_sha256 <> ":" <> receipt.sha256)
      successor = intent |> Map.put("phase", "PREPARED") |> Map.put("owner_nonce", successor_nonce)
      successor = if retirement_case == :preissuance, do: Map.merge(successor, %{"helper_pid" => nil, "execution_json" => nil}), else: successor

      plan = %{
        original: run["candidate_handoff"],
        intent: intent,
        observed: observed,
        successor: successor,
        proof: proof,
        proof_sha256: receipt.sha256,
        retirement_case: retirement_case,
        rejection: rejection
      }

      {:ok, Map.put(plan, :plan_sha256, plan_digest(plan))}
    else
      {:error, _} = error -> error
      _ -> {:error, :unattached_retirement_already_applied_or_unproven}
    end
  end

  defp validate_original(run, operation, audit) do
    envelope = run["candidate_handoff"]
    reservation = ~w(reservation_key reservation_generation)

    with true <- Map.take(run, Map.keys(audit["operation"])) == audit["operation"] or {:error, :unattached_retirement_run_changed},
         true <- operation.run_id == audit["operation"]["run_id"] or {:error, :unattached_retirement_run_changed},
         true <- digest(envelope) == operation.envelope_sha256 or {:error, :unattached_retirement_envelope_changed},
         true <- operation.envelope_sha256 == audit["original_envelope_sha256"] or {:error, :unattached_retirement_envelope_changed},
         {:ok, intent} <- Jason.decode(envelope),
         true <- intent["phase"] == "PUSH_UNCERTAIN" or {:error, :unattached_retirement_envelope_changed},
         true <- intent["owner_nonce"] == operation.nonce or {:error, :unattached_retirement_envelope_changed},
         true <- operation.nonce == audit["owner_nonce"] or {:error, :unattached_retirement_envelope_changed},
         :ok <- original_execution(intent, audit),
         true <- Map.take(intent, reservation) == Map.take(audit, reservation) or {:error, :unattached_retirement_reservation_changed},
         {:ok, binding} <- Jason.decode(intent["binding_json"]),
         true <- Enum.all?(@nonce_constraints, &(not Map.has_key?(binding, &1))) or {:error, :unattached_retirement_lineage_constrained} do
      {:ok, intent}
    end
  end

  defp original_execution(intent, %{"kind" => "AUDITED_UNATTACHED_PUSH"}) do
    if Enum.all?(~w(helper_pid execution_json receipt_json receipt_sha256 remote_sha), &is_nil(intent[&1])), do: :ok, else: {:error, :unattached_retirement_execution_bound}
  end

  defp original_execution(intent, %{"kind" => "AUDITED_PREISSUANCE_REJECTED_PUSH"} = audit) do
    if intent["helper_pid"] == audit["helper_pid"] and is_integer(intent["helper_pid"]) and
         digest(intent["execution_json"]) == audit["execution_sha256"] and
         Enum.all?(~w(receipt_json receipt_sha256 remote_sha), &is_nil(intent[&1])), do: :ok, else: {:error, :preissuance_retirement_execution_changed}
  end

  defp rejection_evidence(_intent, %{"kind" => "AUDITED_UNATTACHED_PUSH"}), do: {:ok, nil}

  defp rejection_evidence(intent, %{"kind" => "AUDITED_PREISSUANCE_REJECTED_PUSH"} = audit) do
    with {:ok, raw} <- TicketPushIO.readback(intent),
         {:ok, reason} <- TicketPushIO.rejection_reason(raw, intent),
         true <- reason == audit["rejection"]["reason"],
         :ok <- recheck_rejection(intent, raw, audit) do
      {:ok, raw}
    else
      _ -> {:error, :preissuance_retirement_rejection_unproven}
    end
  end

  defp recheck_rejection(_intent, nil, %{"kind" => "AUDITED_UNATTACHED_PUSH"}), do: :ok

  defp recheck_rejection(intent, raw, audit) do
    with {:ok, execution} <- Jason.decode(intent["execution_json"]),
         path = Path.join(execution["spool"], intent["owner_nonce"] <> ".push-rejection"),
         true <- path == audit["rejection"]["path"] and byte_size(raw) == audit["rejection"]["bytes"],
         {:ok, ^raw} <- verified_file(path, audit["rejection"]["sha256"], false),
         true <- Enum.all?(~w(.push-claim .push-receipt), &(File.lstat(Path.join(execution["spool"], intent["owner_nonce"] <> &1)) == {:error, :enoent})),
         {"", 1} <- System.cmd("/bin/ps", ["-p", Integer.to_string(audit["helper_pid"]), "-o", "pid="], stderr_to_stdout: true) do
      :ok
    else
      _ -> {:error, :preissuance_retirement_rejection_changed}
    end
  end

  @spec execute(Store.connection(), map(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(%DBConnection{}, _operation, _receipt, _plan, _authorization, _opts),
    do: {:error, :workspace_observation_inside_transaction}

  def execute(store, operation, receipt, plan_sha, authorization, opts),
    do: execute_case(store, operation, receipt, plan_sha, authorization, opts, :unattached)

  @spec execute_preissuance(Store.connection(), map(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_preissuance(%DBConnection{}, _operation, _receipt, _plan, _authorization, _opts),
    do: {:error, :workspace_observation_inside_transaction}

  def execute_preissuance(store, operation, receipt, plan_sha, authorization, opts),
    do: execute_case(store, operation, receipt, plan_sha, authorization, opts, :preissuance)

  defp execute_case(store, %{run_id: run_id} = operation, receipt, plan_sha, authorization, opts, retirement_case) do
    :global.trans({{TicketPush, run_id}, self()}, fn ->
      with {:ok, plan} <- prepare_case(store, operation, receipt, authorization, opts, retirement_case),
           true <- plan.plan_sha256 == plan_sha or {:error, :unattached_retirement_plan_changed},
           {:ok, audit} <- audited_identity(retirement_case),
           {:ok, proof} <- verify_fence(audit, receipt.path, receipt.sha256),
           true <- proof == plan.proof or {:error, :unattached_retirement_proof_changed} do
        persist_observed(store, operation, receipt, plan, audit, authorization, opts)
      end
    end)
  end

  defp persist_observed(store, operation, receipt, plan, audit, authorization, opts) do
    observed_at = System.monotonic_time(:millisecond)

    WorkspaceAccess.acquire_with(store, plan.observed.attrs, opts, fn tx, access ->
      with {:ok, _} <- TicketPushRecovery.tick_binding(tx, opts),
           :ok <- human_inputs_clear(tx, operation.run_id),
           :ok <- TicketPush.recheck_recovery_observation(tx, plan.observed, access, authorization, opts),
           nil <- prior_retirement(tx, operation.run_id, operation.nonce, audit),
           :ok <- protected_history(tx, audit),
           :ok <- recheck_fence(plan.proof, receipt.path, receipt.sha256, observed_at),
           :ok <- recheck_rejection(plan.intent, plan.rejection, audit) do
        persist_retirement(tx, operation.run_id, plan, audit)
      else
        {:error, _} = error -> error
        _ -> {:error, :unattached_retirement_already_applied_or_unproven}
      end
    end)
  end

  @doc "Checks the audited history without authorizing retirement or executing a helper."
  @spec check_protected_history(Store.connection()) :: :ok | {:error, term()}
  def check_protected_history(store) do
    with {:ok, audit} <- audited_identity(), do: protected_history(store, audit)
  end

  @spec check_preissuance_history(Store.connection()) :: :ok | {:error, term()}
  def check_preissuance_history(store) do
    with {:ok, audit} <- audited_identity(:preissuance), do: protected_history(store, audit)
  end

  @doc "Validates shutdown evidence read-only; grants no retirement or issuance authority."
  @spec verify_shutdown_fence(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_shutdown_fence(receipt, receipt_sha) do
    with {:ok, audit} <- audited_identity(), do: verify_fence(audit, receipt, receipt_sha)
  end

  @spec verify_preissuance_shutdown_fence(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_preissuance_shutdown_fence(receipt, receipt_sha) do
    with {:ok, audit} <- audited_identity(:preissuance), do: verify_fence(audit, receipt, receipt_sha)
  end

  defp protected_history(store, audit) do
    expected_sha = audit["protected_snapshot"]["sha256"]

    with {:ok, raw} <- verified_file(audit["protected_snapshot"]["path"], expected_sha, true),
         {:ok, %{"version" => 1, "kind" => "UNATTACHED_PUSH_PROTECTED_ROWS"} = expected} <- Jason.decode(raw),
         identity = audit["database_identity"],
         true <- expected["database"] == identity["path"],
         true <- Enum.any?(Store.query!(store, "PRAGMA database_list").rows, fn [_seq, name, path] -> name == "main" and path == identity["path"] end),
         {:ok, stat} <- File.lstat(identity["path"]),
         true <- stat.type == :regular and {stat.major_device, stat.inode, stat.uid} == {identity["device"], identity["inode"], identity["uid"]},
         true <- expected["run_id"] == audit["operation"]["run_id"] and expected["original_envelope_sha256"] == audit["original_envelope_sha256"],
         true <- is_map(expected["tables"]) and map_size(expected["tables"]) > 0 and Map.has_key?(expected["tables"], "runs"),
         schema = Store.query!(store, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").rows,
         true <- digest(Jason.encode!(schema)) == expected["schema_sha256"],
         true <-
           Enum.all?(expected["tables"], fn {table, saved} ->
             quoted = "\"" <> String.replace(table, "\"", "\"\"") <> "\""
             where = if table == "events", do: " WHERE id <= #{expected["event_limit"]}", else: ""
             current = Store.query!(store, "SELECT rowid,* FROM " <> quoted <> where <> " ORDER BY rowid")
             current.columns == saved["columns"] and length(current.rows) == saved["count"] and digest(Jason.encode!(current.rows)) == saved["sha256"]
           end) do
      :ok
    else
      _ -> {:error, :unattached_retirement_protected_history_changed}
    end
  end

  defp human_inputs_clear(store, run_id) do
    cond do
      Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id=? AND status IN ('PENDING','ACCEPTED') LIMIT 1", [run_id]) ->
        {:error, :unattached_retirement_pending_human_input}

      Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id=? AND phase NOT IN ('APPLIED','SUPERSEDED','REJECTED') LIMIT 1", [run_id]) ->
        {:error, :unattached_retirement_pending_amendment}

      true ->
        :ok
    end
  end

  defp recheck_fence(proof, receipt, receipt_sha, observed_at) do
    with true <- (System.monotonic_time(:millisecond) - observed_at) in 0..10_000 or {:error, :unattached_retirement_fence_expired},
         {:ok, _} <- verified_file(receipt, receipt_sha, true),
         {:ok, _} <- verified_file(proof["protected_before_path"], proof["protected_before_sha256"], true),
         {:ok, _} <- verified_file(proof["protected_after_path"], proof["protected_after_sha256"], true),
         {:ok, _} <- verified_file(proof["replacement_launcher"], proof["replacement_launcher_sha256"], false),
         {:ok, _} <- verified_file(proof["replacement_manifest"], proof["replacement_manifest_sha256"], false),
         {:ok, _} <- verified_file(proof["plist_path"], proof["plist_sha256"], false) do
      :ok
    end
  end

  defp persist_retirement(tx, run_id, plan, audit) do
    successor = Jason.encode!(plan.successor)
    rows = Store.query!(tx, "UPDATE runs SET candidate_handoff=? WHERE run_id=? AND candidate_handoff IS ? RETURNING run_id", [successor, run_id, plan.original]).rows

    if rows == [[run_id]] do
      payload = %{
        version: 1,
        original_envelope: plan.original,
        original_envelope_sha256: digest(plan.original),
        original_nonce: plan.intent["owner_nonce"],
        successor_nonce: plan.successor["owner_nonce"],
        successor_envelope_sha256: digest(successor),
        proof: plan.proof,
        proof_sha256: plan.proof_sha256,
        binding_sha256: plan.intent["binding_sha256"],
        reservation_key: plan.intent["reservation_key"],
        reservation_generation: plan.intent["reservation_generation"]
      }

      payload =
        if plan.retirement_case == :preissuance,
          do: Map.merge(payload, %{retirement_case: "PREISSUANCE_REJECTED", rejection_json: plan.rejection, rejection_sha256: digest(plan.rejection), audit_sha256: audit["_sha256"]}),
          else: payload

      Store.query!(tx, "INSERT INTO events(occurred_at,event_type,run_id,payload_json) VALUES (?,?,?,?)", [
        DateTime.to_iso8601(DateTime.utc_now()),
        retirement_event(audit),
        run_id,
        Jason.encode!(payload)
      ])

      status = if plan.retirement_case == :unattached, do: "UNATTACHED_PUSH_RETIRED", else: "PREISSUANCE_PUSH_RETIRED"
      outcome = if plan.retirement_case == :unattached, do: "INPUT_NOT_ISSUED", else: "GIT_NOT_ISSUED"
      {:ok, %{status: status, run_id: run_id, successor_nonce: plan.successor["owner_nonce"], original_outcome: outcome}}
    else
      {:error, :unattached_retirement_envelope_changed}
    end
  end

  defp retirement_event(%{"kind" => "AUDITED_UNATTACHED_PUSH"}), do: @event
  defp retirement_event(%{"kind" => "AUDITED_PREISSUANCE_REJECTED_PUSH"}), do: "TICKET_PUSH_PREISSUANCE_RETIRED"

  defp prior_retirement(store, run_id, nonce, audit) do
    Store.one!(store, "SELECT id FROM events WHERE run_id=? AND event_type=? AND json_extract(payload_json,'$.original_nonce')=? LIMIT 1", [run_id, retirement_event(audit), nonce])
  end

  defp plan_digest(plan) do
    value = %{original: plan.original, successor: plan.successor, proof_sha256: plan.proof_sha256}
    value = if plan.retirement_case == :preissuance, do: Map.merge(value, %{retirement_case: "PREISSUANCE_REJECTED", rejection_sha256: digest(plan.rejection)}), else: value
    digest(Jason.encode!(value))
  end

  defp audited_identity, do: audited_identity(:unattached)

  defp audited_identity(retirement_case) do
    {filename, expected_sha, kind} =
      case retirement_case do
        :unattached -> {"ticket_push_unattached_audit_v1.json", @audit_sha, "AUDITED_UNATTACHED_PUSH"}
        :preissuance -> {"ticket_push_preissuance_audit_v1.json", @preissuance_sha, "AUDITED_PREISSUANCE_REJECTED_PUSH"}
      end

    path = Application.app_dir(:symphony_elixir, "priv/" <> filename)

    with {:ok, path} <- PathSafety.canonicalize(path),
         {:ok, raw} <- verified_file(path, expected_sha, false),
         {:ok, %{"version" => 1, "kind" => ^kind} = audit} <- Jason.decode(raw),
         true <- Enum.all?(audit["pins"], fn {file, sha} -> match?({:ok, _}, verified_file(file, sha, false)) end) or {:error, :unattached_retirement_original_program_changed} do
      {:ok, Map.put(audit, "_sha256", expected_sha)}
    end
  end

  defp verify_fence(audit, receipt, receipt_sha) do
    proof_kind = if audit["kind"] == "AUDITED_UNATTACHED_PUSH", do: "OWNED_UNATTACHED_ISSUER_SHUTDOWN", else: "OWNED_PREISSUANCE_ISSUER_SHUTDOWN"

    with {:ok, raw} <- verified_file(receipt, receipt_sha, true),
         {:ok, proof} when is_map(proof) <- Jason.decode(raw),
         true <- (proof["version"] == 1 and proof["kind"] == proof_kind and proof["audit_sha256"] == audit["_sha256"]) or {:error, :unattached_retirement_fence_unproven},
         true <-
           (proof["replacement_launcher"] == audit["replacement_launcher"] and proof["replacement_build"] == audit["replacement_build"] and
              proof["replacement_manifest"] == audit["replacement_manifest"]) or {:error, :unattached_retirement_replacement_changed},
         true <- (proof["issuer"] == audit["issuer"] and proof["original_envelope_sha256"] == audit["original_envelope_sha256"]) or {:error, :unattached_retirement_fence_changed},
         :ok <- preserved_snapshots(audit, proof),
         {:ok, plist} <- replacement_launcher(audit, proof),
         :ok <- replacement_process(audit, proof),
         :ok <- replacement_artifact(proof, plist) do
      {:ok, proof}
    else
      {:error, _} = error -> error
      _ -> {:error, :unattached_retirement_issuer_shutdown_unproven}
    end
  end

  defp preserved_snapshots(audit, proof) do
    with {:ok, _} <- verified_file(audit["protected_snapshot"]["path"], audit["protected_snapshot"]["sha256"], true),
         true <-
           (proof["protected_before_sha256"] == proof["protected_after_sha256"] and proof["protected_before_sha256"] == audit["protected_snapshot"]["sha256"]) or
             {:error, :unattached_retirement_history_changed},
         {:ok, _} <- verified_file(proof["protected_before_path"], proof["protected_before_sha256"], true),
         {:ok, _} <- verified_file(proof["protected_after_path"], proof["protected_after_sha256"], true) do
      :ok
    end
  end

  defp replacement_launcher(audit, proof) do
    with {:ok, _} <- verified_file(proof["replacement_launcher"], proof["replacement_launcher_sha256"], false),
         {:ok, _} <- verified_file(proof["plist_path"], proof["plist_sha256"], false),
         true <- proof["plist_path"] == "/Users/cgable/Library/LaunchAgents/com.cgable.symphony-factory.plist" or {:error, :unattached_retirement_launcher_unproven},
         {plist_raw, 0} <- System.cmd("/usr/bin/plutil", ["-convert", "json", "-o", "-", proof["plist_path"]]),
         {:ok, plist} <- Jason.decode(plist_raw),
         {:ok, _} <- verified_file(audit["workflow"]["path"], audit["workflow"]["sha256"], false),
         true <-
           (plist["ProgramArguments"] == [audit["replacement_launcher"], audit["workflow"]["path"]] and plist["WorkingDirectory"] == audit["workflow"]["working_directory"]) or
             {:error, :unattached_retirement_old_launcher_enabled} do
      {:ok, plist}
    end
  end

  defp replacement_process(audit, proof) do
    with {"", 1} <- System.cmd("/bin/ps", ["-p", Integer.to_string(audit["issuer"]["pid"]), "-o", "pid="], stderr_to_stdout: true),
         {launchd, 0} <- System.cmd("/bin/launchctl", ["print", "gui/#{audit["issuer"]["uid"]}/com.cgable.symphony-factory"], stderr_to_stdout: true),
         [_, program] <- Regex.run(~r/^\s*program = (.+)$/m, launchd),
         true <- program == audit["replacement_launcher"] or {:error, :unattached_retirement_old_launcher_enabled},
         [_, service_pid] <- Regex.run(~r/^\s*pid = ([0-9]+)$/m, launchd),
         true <- (service_pid != Integer.to_string(audit["issuer"]["pid"]) and service_pid == proof["replacement_pid"]) or {:error, :unattached_retirement_replacement_changed},
         {service_start, 0} <- System.cmd("/bin/ps", ["-p", service_pid, "-o", "lstart="], stderr_to_stdout: true),
         true <- String.trim(service_start) == proof["replacement_started_at"] or {:error, :unattached_retirement_replacement_changed} do
      :ok
    end
  end

  defp replacement_artifact(proof, plist) do
    with {__MODULE__, beam, _} <- :code.get_object_code(__MODULE__),
         true <- digest(beam) == proof["retirement_beam_sha256"] or {:error, :unattached_retirement_artifact_changed},
         build = Path.expand("../..", Application.app_dir(:symphony_elixir)),
         true <-
           (proof["replacement_build"] == build and plist["EnvironmentVariables"]["MIX_BUILD_PATH"] == build and System.get_env("MIX_BUILD_PATH") == build) or
             {:error, :unattached_retirement_artifact_changed},
         :ok <- replacement_runtime(proof, build) do
      :ok
    end
  end

  defp replacement_runtime(proof, build) do
    with {:ok, raw} <- verified_file(proof["replacement_manifest"], proof["replacement_manifest_sha256"], false),
         {:ok, %{"kind" => "FACTORY_PUSH_HANDOFF_RELEASE_V1"} = manifest} <- Jason.decode(raw),
         true <- manifest["build"] == build and manifest["source_hashes"]["elixir/lib/symphony_elixir/factory/ticket_push.ex"] == @publisher_sha,
         modules = manifest["factory_modules"],
         true <- is_map(modules) and map_size(modules) > 100,
         true <-
           Enum.all?(modules, fn {name, pin} ->
             path = Path.join(build, "lib/symphony_elixir/ebin/" <> name <> ".beam")
             String.starts_with?(name, "Elixir.SymphonyElixir.Factory.") and match?({:ok, _}, verified_file(path, pin, false))
           end),
         {TicketPush, publisher, _} <- :code.get_object_code(TicketPush),
         true <- modules[Atom.to_string(TicketPush)] == digest(publisher) and modules[Atom.to_string(__MODULE__)] == proof["retirement_beam_sha256"],
         digests = modules |> Enum.sort() |> Enum.map(fn {name, sha} -> {name, Base.decode16!(sha, case: :lower)} end),
         fingerprint = digest(:erlang.term_to_binary(digests)),
         {api_raw, 0} <- System.cmd("/usr/bin/curl", ["--fail", "--silent", "--max-time", "3", "http://127.0.0.1:4000/api/v1/state"]),
         {:ok, api} <- Jason.decode(api_raw),
         runtime = get_in(api, ["factory", "control", "runtime_identity"]),
         true <- runtime["os_pid"] == proof["replacement_pid"] and runtime["factory_beam_fingerprint"] == fingerprint and runtime["factory_beam_module_count"] == map_size(modules) do
      :ok
    else
      _ -> {:error, :unattached_retirement_service_artifact_unproven}
    end
  end

  defp verified_file(path, sha, private?) when is_binary(path) and is_binary(sha) do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == path,
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size <= 16_777_216 and band(stat.mode, 0o022) == 0,
         true <- stat.uid in [0, File.stat!(System.user_home!()).uid],
         true <- not private? or band(stat.mode, 0o777) == 0o600,
         {:ok, parent} <- File.lstat(Path.dirname(path)),
         true <- not private? or (parent.type == :directory and parent.uid == stat.uid and band(parent.mode, 0o777) == 0o700),
         {:ok, raw} <- File.read(path),
         {:ok, after_read} <- File.lstat(path),
         true <- Map.take(stat, ~w(major_device inode uid size mode mtime ctime)a) == Map.take(after_read, ~w(major_device inode uid size mode mtime ctime)a),
         true <- digest(raw) == sha do
      {:ok, raw}
    else
      _ -> {:error, :unattached_retirement_pinned_file_changed}
    end
  end

  defp verified_file(_path, _sha, _private?), do: {:error, :unattached_retirement_pinned_file_changed}
  defp digest(raw) when is_binary(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
  defp digest(_raw), do: nil
end
