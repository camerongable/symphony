defmodule SymphonyElixir.Factory.TicketCapabilityRecovery do
  @moduledoc "Explicit operator recovery of one stopped writer after its exact repository capability is restored."

  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.Factory.{
    Capacity,
    Control,
    DesktopStageRunner,
    JiraMcpReader,
    NativeQueueReadback,
    Policy,
    RunLedger,
    StageSchemas,
    Store,
    TaskLauncher,
    TaskLedger,
    TicketChat,
    TicketPushIO,
    TicketPushRecovery,
    TicketPushRecoveryIO,
    TicketPushWorkerHistory,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerFileIO,
    WorkspaceAccess,
    Worktree
  }

  @fields ~w(authorization_key authorization_reference authorization_body run_id request_key turn_id output_sha256 binding_sha256 candidate_sha spec_revision contract_sha256 base_sha base_paths)
  @authorized "TICKET_CAPABILITY_RECOVERY_AUTHORIZED"
  @checked "TICKET_CAPABILITY_RECOVERY_CHECKED"
  @applied "TICKET_CAPABILITY_RECOVERY_APPLIED"
  @limit 262_144

  @doc "Observes the exact proposed grant binding read-only; does not authorize recovery."
  @spec describe(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def describe(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def describe(store, input, factory, opts) do
    with :ok <- valid_input(input),
         {:ok, observed} <- observe(store, input, factory, opts) do
      binding = grant_binding(input, observed)
      {:ok, %{"binding" => binding, "binding_sha256" => json_hash(binding), "authorization_sha256" => json_hash(input), "runtime" => runtime_attestation()}}
    end
  end

  @doc "Reads actual loaded-code identity independently of ticket eligibility."
  @spec runtime_attestation() :: map()
  def runtime_attestation do
    modules = [
      __MODULE__,
      AppServer,
      SymphonyElixir.Factory.BrokerRuntime,
      SymphonyElixir.Factory.Scheduler,
      SymphonyElixir.Factory.TaskLauncher,
      WorkspaceAccess,
      WorkerEvidence,
      TicketWorkerRunner,
      TicketPushIO,
      SymphonyElixir.Factory.TicketPush,
      SymphonyElixir.Factory.TicketPushPreissuanceRejection,
      SymphonyElixir.Factory.TicketPushOrdinaryRejection,
      TicketPushRecoveryIO,
      TicketPushWorkerHistory,
      SymphonyElixir.Factory.TicketInfrastructureRecovery,
      Mix.Tasks.Factory.Ticket
    ]

    %{
      "pid" => System.pid(),
      "modules" =>
        Map.new(modules, fn module ->
          {:module, ^module} = Code.ensure_loaded(module)

          {Atom.to_string(module),
           %{
             "md5" => module.module_info(:md5) |> Base.encode16(case: :lower),
             "compile_source" => module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string(),
             "code_path" => module |> :code.which() |> to_string(),
             "loaded_path" => module |> :code.is_loaded() |> elem(1) |> to_string()
           }}
        end)
    }
  end

  @doc "Stages exact local operator authority only; never creates native human input or dispatches source work."
  @spec stage(SymphonyElixir.Factory.Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage(%DBConnection{}, _input, _factory, _opts), do: {:error, :workspace_observation_inside_transaction}

  def stage(store, input, factory, opts) do
    with true <- (is_map(input) and Enum.sort(Map.keys(input)) == Enum.sort(@fields ++ ~w(grant_id grant_sha256))) or {:error, :capability_recovery_authorization_invalid},
         :ok <- valid_input(Map.drop(input, ~w(grant_id grant_sha256))),
         true <- (text?(input["grant_id"], 128) and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, input["grant_id"]) and hex?(input["grant_sha256"], 64)) or {:error, :capability_recovery_authorization_invalid} do
      stage_requested(store, input, factory, opts)
    end
  end

  @doc "Refreshes one pending authorization under the current owned tick before dirty-source transfer."
  @spec prepare(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | :none | {:error, term()}
  def prepare(%DBConnection{}, _, _, _), do: {:error, :workspace_observation_inside_transaction}

  def prepare(store, request, factory, opts) do
    case authorization_for_request(store, request) do
      :none -> :none
      {:ok, record} -> prepare_record(store, record, factory, opts)
      error -> error
    end
  end

  @doc false
  @spec pending_resume(Store.connection(), String.t()) :: {:ok, map()} | :none | {:error, term()}
  def pending_resume(store, request) do
    with {:ok, record} <- authorization_for_request(store, request),
         {:ok, old} <- WorkerEvidence.get(store, request),
         true <- old["output_sha256"] == record.proof["authorization"]["output_sha256"] and old["binding_sha256"] == record.proof["authorization"]["binding_sha256"],
         disposition when is_map(disposition) <-
           Store.one!(store, "SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_WRITER_BLOCKED' AND json_extract(payload_json,'$.request_key')=? ORDER BY id DESC LIMIT 1", [
             old["run_id"],
             request
           ]),
         {:ok, blocked} <- Jason.decode(disposition["payload_json"]) do
      {:ok, %{"operational_recovery_key" => "TCAP-" <> digest(record.raw), "request_key" => request, "disposition_key" => blocked["disposition_key"], "thread_id" => old["thread_id"]}}
    else
      :none -> :none
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_authorization_unproven}
    end
  end

  @doc false
  @spec transferred(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def transferred(store, resume, transfer) do
    with {:ok, record} <- authorization_for_request(store, transfer["old_request_key"]),
         true <- "TCAP-" <> digest(record.raw) == resume["operational_recovery_key"],
         {:ok, checked} <- checked_record(store, resume),
         true <- checked["mode"] == "INITIAL" and checked["authorization_sha256"] == digest(record.raw),
         true <- is_nil(Store.one!(store, "SELECT id FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization_sha256')=?", [@applied, digest(record.raw)])),
         {:ok, old} <- WorkspaceAccess.get(store, transfer["old_reservation_key"]),
         {:ok, release} <- Jason.decode(old["release_receipt_json"] || "null"),
         true <- is_binary(old["released_at"]),
         true <- Map.take(release, Map.keys(transfer) -- ["new_generation"]) == Map.drop(transfer, ["new_generation"]),
         {:ok, current} <- WorkspaceAccess.get(store, transfer["new_reservation_key"]),
         true <- current["generation"] == old["generation"] + 1 and current["generation"] == transfer["new_generation"] and is_nil(current["released_at"]),
         {:ok, attempt} <- WorkerEvidence.get(store, transfer["new_request_key"]),
         true <- attempt["status"] == "RESERVED" and attempt["reservation_key"] == current["reservation_key"],
         true <-
           checked["destination"] == %{
             "request_key" => attempt["request_key"],
             "reservation_key" => current["reservation_key"],
             "generation" => current["generation"],
             "prompt_sha256" => attempt_input(attempt)
           } do
      application =
        Map.merge(transfer, %{
          "version" => 1,
          "kind" => "CAPABILITY_RECOVERY_APPLIED_V1",
          "authorization_sha256" => digest(record.raw),
          "recovery_key" => resume["operational_recovery_key"],
          "checked_event_id" => resume["checked_event_id"],
          "checked_sha256" => resume["checked_sha256"],
          "request_key" => attempt["request_key"],
          "reservation_key" => current["reservation_key"],
          "reservation_generation" => current["generation"],
          "prior_request_key" => transfer["old_request_key"],
          "release_sha256" => digest(old["release_receipt_json"]),
          "applied_at" => now()
        })

      Store.query!(store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES(?,?,?,?)", [@applied, current["run_id"], Jason.encode!(application), now()])
      {:ok, application}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_transfer_unproven}
    end
  end

  @doc false
  @spec reservation_facts(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def reservation_facts(store, resume) do
    with {:ok, record} <- authorization_for_request(store, resume["request_key"]),
         true <- resume["operational_recovery_key"] == "TCAP-" <> digest(record.raw),
         {:ok, checked} <- checked_record(store, resume),
         true <- checked["authorization_sha256"] == digest(record.raw) and checked["mode"] == "INITIAL",
         {:ok, old} <- WorkerEvidence.get(store, resume["request_key"]),
         true <- json_hash(old) == record.proof["ledger"]["evidence"],
         {:ok, binding} <- Jason.decode(old["binding_json"]),
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         true <- json_hash(run) == record.proof["ledger"]["run"],
         operations = rows(store, "SELECT rowid AS journal_rowid,* FROM worker_file_operations WHERE request_key=? ORDER BY rowid", [old["request_key"]]),
         true <- json_hash(operations) == record.proof["ledger"]["operations"],
         {:ok, prior_access} <- WorkspaceAccess.get(store, old["reservation_key"]),
         true <- is_binary(prior_access["released_at"]),
         true <- json_hash(prior_access |> Map.put("released_at", nil) |> Map.put("release_receipt_json", nil)) == record.proof["ledger"]["access"],
         {:ok, transfer} <- Jason.decode(prior_access["release_receipt_json"]),
         true <- transfer["kind"] == "BLOCKED_SOURCE_TRANSFER" and transfer["operational_recovery_key"] == resume["operational_recovery_key"],
         destination = checked["destination"],
         true <- transfer["new_request_key"] == destination["request_key"] and transfer["new_reservation_key"] == destination["reservation_key"],
         {:ok, access} <- WorkspaceAccess.get(store, destination["reservation_key"]),
         true <- access["generation"] == destination["generation"] and access["generation"] == prior_access["generation"] + 1 and is_nil(access["released_at"]),
         true <- Map.take(access, ~w(run_id task_key canonical_path git_dir common_dir)) == Map.take(prior_access, ~w(run_id task_key canonical_path git_dir common_dir)),
         true <- access["request_key"] == destination["request_key"] and access["mode"] == "SOURCE",
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         true <- task["status"] == "STARTING" and task["prompt_sha256"] == destination["prompt_sha256"] and task["thread_id"] == old["thread_id"],
         true <- Map.take(task, ~w(task_key run_id role model reasoning_effort)) == Map.take(binding, ~w(task_key run_id role model reasoning_effort)) do
      {:ok, %{record: record, checked: checked, run: run, task: task, prior: old, binding: binding, access: access}}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_reservation_unproven}
    end
  end

  @doc false
  @spec checkout(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def checkout(store, resume) do
    with {:ok, verified} <- checked(store, resume) do
      saved = verified.checked["checkout"]
      {:ok, Map.new(~w(path git_dir common_dir root_device root_inode)a, &{&1, Map.fetch!(saved, Atom.to_string(&1))})}
    end
  end

  @doc false
  @spec applied(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def applied(store, "TCAP-" <> auth_hash = key) do
    with [%{"payload_json" => raw}] <- rows(store, "SELECT payload_json FROM events WHERE event_type=? AND json_extract(payload_json,'$.recovery_key')=?", [@applied, key]),
         true <- byte_size(raw) <= @limit,
         {:ok, application} <- Jason.decode(raw),
         true <- application["version"] == 1,
         true <- application["kind"] == "CAPABILITY_RECOVERY_APPLIED_V1",
         true <- application["authorization_sha256"] == auth_hash,
         {:ok, record} <- authorization_for_request(store, application["prior_request_key"]),
         true <- digest(record.raw) == auth_hash,
         %{"payload_json" => checked_raw} <- Store.one!(store, "SELECT payload_json FROM events WHERE id=? AND event_type=?", [application["checked_event_id"], @checked]),
         true <- digest(checked_raw) == application["checked_sha256"],
         {:ok, initial} <- Jason.decode(checked_raw),
         true <- initial["mode"] == "INITIAL",
         true <- initial["authorization_sha256"] == auth_hash,
         true <- initial["ledger"] == record.proof["ledger"],
         {:ok, old} <- WorkerEvidence.get(store, application["prior_request_key"]),
         true <- old["output_sha256"] == record.proof["authorization"]["output_sha256"],
         true <- old["binding_sha256"] == record.proof["authorization"]["binding_sha256"],
         true <- WorkerEvidence.owner_stopped?(store, old),
         {:ok, access} <- WorkspaceAccess.get(store, old["reservation_key"]),
         true <- is_binary(access["released_at"]) and digest(access["release_receipt_json"]) == application["release_sha256"],
         {:ok, release} <- Jason.decode(access["release_receipt_json"]),
         true <- release["operational_recovery_key"] == key and release["new_request_key"] == application["request_key"] and release["new_reservation_key"] == application["reservation_key"],
         {:ok, next} <- WorkerEvidence.get(store, application["request_key"]),
         {:ok, next_access} <- WorkspaceAccess.get(store, application["reservation_key"]),
         true <-
           next["task_key"] == old["task_key"] and next["run_id"] == old["run_id"] and next["reservation_key"] == next_access["reservation_key"] and
             next_access["generation"] == application["reservation_generation"],
         true <-
           initial["destination"] == %{
             "request_key" => next["request_key"],
             "reservation_key" => next_access["reservation_key"],
             "generation" => next_access["generation"],
             "prompt_sha256" => attempt_input(next)
           },
         true <- digest(next["binding_json"]) == next["binding_sha256"],
         {:ok, next_binding} <- Jason.decode(next["binding_json"]),
         true <- digest(old["binding_json"]) == old["binding_sha256"],
         {:ok, old_binding} <- Jason.decode(old["binding_json"]),
         true <- WorkerEvidence.runtime_matches?(old_binding, next_binding),
         true <-
           next_binding["reservation_generation"] == next_access["generation"] and next_binding["input_sha256"] == initial["destination"]["prompt_sha256"] and
             next_binding["base_sha"] == record.proof["authorization"]["base_sha"] do
      {:ok, application}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_application_unproven}
    end
  end

  def applied(_, _), do: {:error, :capability_recovery_application_unproven}

  @doc false
  @spec prepared(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepared(store, attempt, transfer) do
    with {:ok, application} <- applied(store, transfer["operational_recovery_key"]),
         true <- application["request_key"] == attempt["request_key"] and attempt["status"] == "RESERVED",
         {:ok, record} <- authorization_for_request(store, application["prior_request_key"]),
         {:ok, old} <- WorkerEvidence.get(store, application["prior_request_key"]),
         {:ok, resume} <- pending_resume(store, old["request_key"]) do
      {:ok,
       Map.merge(resume, %{
         "prepared" => true,
         "prepared_request_key" => attempt["request_key"],
         "prepared_reservation_key" => application["reservation_key"],
         "prepared_reservation_generation" => application["reservation_generation"],
         "prepared_prompt_sha256" => attempt_input(attempt),
         "authorization_sha256" => digest(record.raw)
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_prepared_unproven}
    end
  end

  @doc false
  @spec prepared_access(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def prepared_access(store, resume) do
    with {:ok, proof} <- checked_record(store, resume),
         true <- proof["mode"] == "PREPARED",
         {:ok, record} <- authorization_for_request(store, resume["request_key"]),
         {:ok, current} <- continuation_facts(store, record, ~w(RESERVED)),
         true <- proof["ledger"] == ledger(current),
         true <- proof["destination"] == destination_for_existing(current),
         true <-
           is_nil(
             Store.one!(store, "SELECT id FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_PREPARED_ADMITTED' AND json_extract(payload_json,'$.checked_event_id')=?", [
               resume["checked_event_id"]
             ])
           ) do
      {:ok, current.next_access}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_prepared_unproven}
    end
  end

  @doc false
  @spec admit_prepared(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def admit_prepared(%DBConnection{} = store, resume) do
    with {:ok, _} <- prepared_access(store, resume),
         true <-
           is_nil(
             Store.one!(store, "SELECT id FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_PREPARED_ADMITTED' AND json_extract(payload_json,'$.checked_event_id')=?", [
               resume["checked_event_id"]
             ])
           ),
         {:ok, attempt} <- WorkerEvidence.get(store, resume["prepared_request_key"]) do
      receipt = Map.take(resume, ~w(operational_recovery_key checked_event_id checked_sha256 prepared_request_key prepared_reservation_key prepared_reservation_generation))

      Store.query!(store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES('TICKET_CAPABILITY_RECOVERY_PREPARED_ADMITTED',?,?,?)", [
        attempt["run_id"],
        Jason.encode!(receipt),
        now()
      ])

      {:ok, attempt}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_prepared_consumed}
    end
  end

  def admit_prepared(_, _), do: {:error, :capability_recovery_transaction_required}

  @doc "Reobserves the exact old result and empty queue through the newly owned actor before turn/start."
  @spec owned_session_preflight(Store.connection(), map(), map(), keyword()) :: :ok | {:error, term()}
  def owned_session_preflight(store, resume, session, opts) do
    with {:ok, record} <- authorization_for_request(store, resume["request_key"]),
         {:ok, before} <- Store.transaction!(store, &continuation_facts(&1, record, ~w(THREAD_BOUND)), mode: :deferred),
         {:ok, opts} <- WorkerEvidence.runtime_options(before.binding, opts),
         true <- before.application["recovery_key"] == resume["operational_recovery_key"],
         true <- before.next["thread_id"] == session.thread_id and session.thread_id == before.evidence["thread_id"],
         {:ok, owner} <- Jason.decode(before.next["owner_process_json"] || "null"),
         true <- owner == %{"pid" => session.metadata.codex_app_server_pid, "invocation_nonce" => session.worker_invocation},
         true <- TaskLauncher.active_owner(before.next["task_key"]) == self(),
         factory = policy_factory(before.policy) |> Map.put(:repositories, %{before.run["repo_key"] => %{"path" => before.run["repo_path"]}}),
         {:ok, observed} <- observe_continuation(store, before, factory, opts, true),
         true <- observed.files == record.proof["files"] and observed.base_blobs == record.proof["base_blobs"],
         {:ok, native} <- owned_reader(opts).read_owned_native_thread(session),
         :ok <- validate_native(before, native),
         {:ok, _} <- WorkerEvidence.runtime_options(before.binding, opts),
         {:ok, queue} <- NativeQueueReadback.read(queue_database(opts), session.thread_id),
         {:ok, checked} <- checked_record_historical(store, resume),
         true <- queue == checked["native"]["queue"],
         {:ok, ^before} <- Store.transaction!(store, &continuation_facts(&1, record, ~w(THREAD_BOUND)), mode: :deferred),
         true <- TaskLauncher.active_owner(before.next["task_key"]) == self(),
         true <- source_fresh?(observed.source_observed_at),
         {:ok, _} <- WorkerEvidence.runtime_options(before.binding, opts),
         :ok <- fresh_native_observations(native) do
      :ok
    else
      _ -> {:error, :capability_recovery_owned_preflight_failed}
    end
  end

  defp checked_record_historical(store, resume) do
    with %{"payload_json" => raw} <- Store.one!(store, "SELECT payload_json FROM events WHERE id=? AND event_type=?", [resume["checked_event_id"], @checked]),
         true <- byte_size(raw) <= @limit and digest(raw) == resume["checked_sha256"],
         {:ok, proof} <- Jason.decode(raw),
         true <- proof["kind"] == "CAPABILITY_RECOVERY_CHECKED_V1" do
      {:ok, proof}
    else
      _ -> {:error, :capability_recovery_check_unproven}
    end
  end

  defp continuation_facts(store, record, statuses) do
    key = "TCAP-" <> digest(record.raw)

    with {:ok, application} <- applied(store, key),
         {:ok, old} <- WorkerEvidence.get(store, application["prior_request_key"]),
         {:ok, binding} <- Jason.decode(old["binding_json"]),
         {:ok, output} <- Jason.decode(old["output_json"]),
         true <- json_hash(old) == record.proof["ledger"]["evidence"],
         {:ok, run} <- RunLedger.get(store, old["run_id"]),
         true <- json_hash(run) == record.proof["ledger"]["run"],
         {:ok, access} <- WorkspaceAccess.get(store, old["reservation_key"]),
         true <- json_hash(access |> Map.put("released_at", nil) |> Map.put("release_receipt_json", nil)) == record.proof["ledger"]["access"],
         {:ok, next} <- WorkerEvidence.get(store, application["request_key"]),
         true <- next["status"] in statuses and is_nil(next["turn_id"]) and is_nil(next["output_json"]) and is_nil(next["owner_stopped_at"]),
         {:ok, next_access} <- WorkspaceAccess.get(store, next["reservation_key"]),
         true <- is_nil(next_access["released_at"]),
         {:ok, task} <- TaskLedger.get(store, old["task_key"]),
         true <- task["status"] in ~w(STARTING RUNNING) and task["prompt_sha256"] == attempt_input(next) and task["thread_id"] == old["thread_id"] and task["turn_id"] == old["turn_id"],
         {:ok, next_binding} <- Jason.decode(next["binding_json"]),
         true <- digest(old["binding_json"]) == old["binding_sha256"] and digest(next["binding_json"]) == next["binding_sha256"] and WorkerEvidence.runtime_matches?(binding, next_binding),
         true <- Map.take(task, ~w(task_key run_id role stage model reasoning_effort prompt_sha256)) == Map.take(next_binding, ~w(task_key run_id role stage model reasoning_effort prompt_sha256)),
         operations = rows(store, "SELECT rowid AS journal_rowid,* FROM worker_file_operations WHERE request_key=? ORDER BY rowid", [old["request_key"]]),
         true <- json_hash(operations) == record.proof["ledger"]["operations"],
         true <- is_nil(Store.one!(store, "SELECT call_id FROM worker_file_operations WHERE request_key=? LIMIT 1", [next["request_key"]])),
         pin <- Store.one!(store, "SELECT * FROM ticket_review_bases WHERE run_id=?", [run["run_id"]]),
         true <- json_hash(pin) == record.proof["ledger"]["pin"],
         factory = policy_factory(record.proof["policy"]),
         control <- Control.status(store, factory.scope),
         true <- json_hash(Map.drop(control, ~w(generation updated_at tick_id lease_expires_at))) == record.proof["ledger"]["control"],
         :ok <- available(store, run, next, next_access, factory) do
      {:ok,
       %{
         record: record,
         run: run,
         evidence: old,
         binding: binding,
         output: output,
         access: access,
         operations: operations,
         pin: pin,
         task: task,
         next: next,
         next_access: next_access,
         application: application,
         policy: record.proof["policy"],
         control: Map.drop(control, ~w(generation updated_at tick_id lease_expires_at))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_continuation_changed}
    end
  end

  defp observe_continuation(store, before, factory, opts, owned?) do
    with :ok <- no_foreign_owner(before.next["task_key"], owned?),
         {:ok, %{result: "PASS"}} <- Capacity.snapshot(store, capacity_policy(factory), before.run["repo_key"], Keyword.put(opts, :exclude_writer_issue_key, before.run["issue_key"])),
         {:ok, jira} <- jira_authorization(store, before.run, opts),
         source_observed_at = now(),
         {:ok, root} <- Jason.decode(before.access["binding_json"]),
         {:ok, checkout} <-
           Worktree.checkout_identity(factory.repositories[before.run["repo_key"]], before.run["worktree"],
             clean: false,
             detached: false,
             expected_branch: before.run["branch"],
             expected_sha: before.run["candidate_sha"]
           ),
         true <-
           {checkout.path, checkout.git_dir, checkout.common_dir, checkout.root_device, checkout.root_inode} ==
             {before.access["canonical_path"], before.access["git_dir"], before.access["common_dir"], root["root_device"], root["root_inode"]},
         :ok <- WorkerFileIO.workspace_allowed?(store, checkout.path),
         {:ok, files} <- observe_files(before, root),
         {:ok, base_blobs} <- read_blobs(before, root, before.record.proof["authorization"]["base_sha"], before.record.proof["authorization"]["base_paths"]),
         true <- files == before.record.proof["files"] and base_blobs == before.record.proof["base_blobs"],
         {:ok, native} <- continuation_native(before, opts, owned?),
         {:ok, ^before} <- Store.transaction!(store, &continuation_facts(&1, before.record, [before.next["status"]]), mode: :deferred),
         :ok <- no_foreign_owner(before.next["task_key"], owned?) do
      result = %{files: files, base_blobs: base_blobs, checkout: checkout, jira: jira, native: native}
      {:ok, Map.put(result, :source_observed_at, source_observed_at)}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_continuation_changed}
    end
  end

  defp continuation_native(_before, _opts, true), do: {:ok, nil}
  defp continuation_native(before, opts, false), do: native_observation(before, opts)

  defp no_foreign_owner(task, owned?) do
    expected = if owned?, do: self(), else: nil
    if TaskLauncher.active_owner(task) == expected, do: :ok, else: {:error, :capability_recovery_stage_owner_active}
  end

  @doc false
  @spec superseded?(Store.connection(), map()) :: boolean()
  def superseded?(store, evidence) do
    with [%{"payload_json" => raw}] <- rows(store, "SELECT payload_json FROM events WHERE event_type=? AND json_extract(payload_json,'$.prior_request_key')=?", [@applied, evidence["request_key"]]),
         {:ok, saved} <- Jason.decode(raw),
         {:ok, ^saved} <- applied(store, saved["recovery_key"]),
         do: true,
         else: (_ -> false)
  end

  @doc false
  @spec body() :: String.t()
  def body do
    "Controller-authorized recovery of the exact recorded contract-base capability blocker, not a new human answer or product decision. Preserve every existing edit and the unchanged contract. The current permitted seven repository tools support pinned historical reads: repo_read or repo_read_binary with path .symphony-base/<relative-path> reads the immutable bound contract base. Read the current file separately before write CAS; never use a historical SHA for current-file CAS. Resolve only the exact recorded capability blocker using the bound pinned-base paths. Finish only the unchanged authorized slice and findings in blocked_writer_context and base_packet, then return a structured result. Do not use shell, push, create an MR, change the contract or reset budgets."
  end

  defp prepare_record(store, record, factory, opts) do
    case rows(store, "SELECT payload_json FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization_sha256')=?", [@applied, digest(record.raw)]) do
      [] -> prepare_initial(store, record, factory, opts)
      [_] -> prepare_existing(store, record, factory, opts)
      _ -> {:error, :capability_recovery_application_unproven}
    end
  end

  @doc "Reads the exact predecessor's admitted packet for an authorized unchanged-contract recovery."
  @spec retained_packet(Store.connection(), map(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def retained_packet(store, run, base_sha, resume) do
    with {:ok, record} <- authorization_for_request(store, resume["request_key"]),
         true <- resume["operational_recovery_key"] == "TCAP-" <> digest(record.raw),
         input = record.proof["authorization"],
         true <- Map.take(input, ~w(run_id candidate_sha spec_revision contract_sha256)) == Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256)),
         true <- input["base_sha"] == base_sha,
         {:ok, evidence} <- WorkerEvidence.get(store, input["request_key"]),
         true <- Map.take(evidence, ~w(turn_id output_sha256 binding_sha256)) == Map.take(input, ~w(turn_id output_sha256 binding_sha256)),
         true <- digest(evidence["binding_json"]) == evidence["binding_sha256"],
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         true <- binding["role"] == "feature-writer" and binding["mode"] == "SOURCE" do
      predecessor = Map.take(evidence, ~w(task_key run_id)) |> Map.merge(%{"role" => binding["role"], "prompt_sha256" => binding["prompt_sha256"]})
      TicketWorkerRunner.retained_packet(store, run["run_id"], "feature-writer", base_sha, predecessor)
    else
      _ -> {:error, :capability_recovery_retained_packet_unproven}
    end
  end

  defp prepare_initial(store, record, factory, opts) do
    with {:ok, tick} <- owned_tick(store, factory, opts),
         [] <- rows(store, "SELECT id FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization_sha256')=?", [@applied, digest(record.raw)]),
         prompt when is_binary(prompt) and byte_size(prompt) > 0 <- opts[:capability_prompt],
         {:ok, observed} <- observe(store, Map.drop(record.proof["authorization"], ~w(grant_id grant_sha256)), factory, Keyword.put(opts, :capability_tick, tick)),
         true <-
           (ledger(observed.facts) == record.proof["ledger"] and observed.files == record.proof["files"] and observed.base_blobs == record.proof["base_blobs"]) or
             {:error, :capability_recovery_authorization_changed} do
      Store.transaction!(store, &commit_initial_check(&1, record, factory, opts, observed, prompt, tick))
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_preparation_unavailable}
    end
  end

  defp commit_initial_check(tx, record, factory, opts, observed, prompt, tick) do
    with {:ok, ^tick} <- owned_tick(tx, factory, opts),
         {:ok, current} <- facts(tx, record.proof["authorization"], factory),
         true <- current == observed.facts,
         true <- unexpired_native?(observed.native),
         true <- source_fresh?(observed.source_observed_at),
         :ok <- TicketWorkerRunner.validate_authorization(current.run, observed.jira) do
      checked = %{
        "version" => 1,
        "kind" => "CAPABILITY_RECOVERY_CHECKED_V1",
        "mode" => "INITIAL",
        "authorization_sha256" => digest(record.raw),
        "tick" => tick,
        "ledger" => ledger(current),
        "checkout" => stringify(observed.checkout),
        "policy" => current.policy,
        "native" => observed.native,
        "jira" => observed.jira,
        "source_observed_at" => observed.source_observed_at,
        "observed_at" => now(),
        "expires_at" => observed.native["expires_at"],
        "destination" => destination(current, prompt)
      }

      raw = Jason.encode!(checked)
      Store.query!(tx, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES(?,?,?,?)", [@checked, current.run["run_id"], raw, now()])
      id = Store.one!(tx, "SELECT last_insert_rowid() AS id")["id"]
      {:ok, descriptor(record, current, id, raw)}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_check_changed}
    end
  end

  defp prepare_existing(store, record, factory, opts) do
    with {:ok, tick} <- owned_tick(store, factory, opts),
         {:ok, before} <- Store.transaction!(store, &continuation_facts(&1, record, ~w(RESERVED)), mode: :deferred),
         true <- before.policy == policy_snapshot(factory),
         prompt when is_binary(prompt) <- opts[:capability_prompt],
         true <- digest(prompt) == attempt_input(before.next),
         {:ok, observed} <- observe_continuation(store, before, factory, opts, false),
         {:ok, resume} <- prepared(store, before.next, before.application) do
      Store.transaction!(store, &commit_prepared_check(&1, record, factory, opts, before, observed, resume, tick))
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_prepared_unproven}
    end
  end

  defp commit_prepared_check(tx, record, factory, opts, before, observed, resume, tick) do
    with {:ok, ^tick} <- owned_tick(tx, factory, opts),
         {:ok, ^before} <- continuation_facts(tx, record, ~w(RESERVED)),
         true <- unexpired_native?(observed.native),
         true <- source_fresh?(observed.source_observed_at),
         :ok <- TicketWorkerRunner.validate_authorization(before.run, observed.jira) do
      proof = %{
        "version" => 1,
        "kind" => "CAPABILITY_RECOVERY_CHECKED_V1",
        "mode" => "PREPARED",
        "authorization_sha256" => digest(record.raw),
        "tick" => tick,
        "ledger" => ledger(before),
        "checkout" => stringify(observed.checkout),
        "policy" => before.policy,
        "native" => observed.native,
        "jira" => observed.jira,
        "source_observed_at" => observed.source_observed_at,
        "observed_at" => now(),
        "expires_at" => observed.native["expires_at"],
        "destination" => destination_for_existing(before)
      }

      raw = Jason.encode!(proof)
      Store.query!(tx, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES(?,?,?,?)", [@checked, before.run["run_id"], raw, now()])
      id = Store.one!(tx, "SELECT last_insert_rowid() AS id")["id"]
      {:ok, Map.merge(resume, %{"checked_event_id" => id, "checked_sha256" => digest(raw)})}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_prepared_changed}
    end
  end

  defp destination_for_existing(current),
    do: %{
      "request_key" => current.next["request_key"],
      "reservation_key" => current.next_access["reservation_key"],
      "generation" => current.next_access["generation"],
      "prompt_sha256" => attempt_input(current.next)
    }

  defp attempt_input(evidence) do
    with true <- digest(evidence["binding_json"]) == evidence["binding_sha256"], {:ok, binding} <- Jason.decode(evidence["binding_json"]), do: binding["input_sha256"], else: (_ -> nil)
  end

  @doc false
  @spec checked(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def checked(store, resume) do
    with {:ok, record} <- authorization_for_request(store, resume["request_key"]),
         true <- resume["operational_recovery_key"] == "TCAP-" <> digest(record.raw),
         %{"payload_json" => raw} <- Store.one!(store, "SELECT payload_json FROM events WHERE id=? AND event_type=?", [resume["checked_event_id"], @checked]),
         true <- byte_size(raw) <= @limit and digest(raw) == resume["checked_sha256"],
         {:ok, proof} <- Jason.decode(raw),
         true <- proof["version"] == 1 and proof["kind"] == "CAPABILITY_RECOVERY_CHECKED_V1" and proof["mode"] == "INITIAL" and proof["authorization_sha256"] == digest(record.raw),
         true <- fresh?(proof["observed_at"]) and unexpired_native?(proof["native"]) and source_fresh?(proof["source_observed_at"]),
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, operator_tick: proof["tick"]),
         true <- tick == proof["tick"],
         factory = policy_factory(proof["policy"]),
         {:ok, current} <- facts(store, record.proof["authorization"], factory),
         true <- ledger(current) == proof["ledger"] and ledger(current) == record.proof["ledger"],
         true <- Store.one!(store, "SELECT id FROM events WHERE event_type=? AND json_extract(payload_json,'$.checked_event_id')=?", [@applied, resume["checked_event_id"]]) == nil do
      {:ok, %{record: record, checked: proof, facts: current}}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_check_unproven}
    end
  end

  defp descriptor(record, current, id, raw) do
    disposition = Jason.decode!(current.disposition["payload_json"])

    %{
      "operational_recovery_key" => "TCAP-" <> digest(record.raw),
      "request_key" => current.evidence["request_key"],
      "disposition_key" => disposition["disposition_key"],
      "thread_id" => current.evidence["thread_id"],
      "checked_event_id" => id,
      "checked_sha256" => digest(raw)
    }
  end

  defp destination(current, prompt) do
    request = DesktopStageRunner.request_key(current.task["task_key"], current.task["turn_id"], prompt)
    %{"request_key" => request, "reservation_key" => "workspace:" <> request, "generation" => current.access["generation"] + 1, "prompt_sha256" => digest(prompt)}
  end

  defp checked_record(store, resume) do
    with %{"payload_json" => raw} <- Store.one!(store, "SELECT payload_json FROM events WHERE id=? AND event_type=?", [resume["checked_event_id"], @checked]),
         true <- byte_size(raw) <= @limit and digest(raw) == resume["checked_sha256"],
         {:ok, proof} <- Jason.decode(raw),
         true <-
           proof["version"] == 1 and proof["kind"] == "CAPABILITY_RECOVERY_CHECKED_V1" and fresh?(proof["observed_at"]) and unexpired_native?(proof["native"]) and
             source_fresh?(proof["source_observed_at"]),
         {:ok, tick} <- TicketPushRecovery.tick_binding(store, operator_tick: proof["tick"]),
         true <- tick == proof["tick"] do
      {:ok, proof}
    else
      _ -> {:error, :capability_recovery_check_unproven}
    end
  end

  defp stage_requested(store, input, factory, opts) do
    case authorization(store, input["authorization_key"]) do
      {:ok, record} -> replay(record, input)
      :none -> stage_new(store, input, factory, opts)
      error -> error
    end
  end

  defp stage_new(store, input, factory, opts) do
    authorization = Map.drop(input, ~w(grant_id grant_sha256))

    with {:ok, grant} <- read_grant(input, opts),
         {:ok, observed} <- observe(store, authorization, factory, opts),
         true <-
           (grant["authorization_sha256"] == json_hash(authorization) and grant["binding_sha256"] == json_hash(grant_binding(authorization, observed)) and
              grant["capability_blockers"] == observed.facts.output["blockers"] and grant["base_paths"] == input["base_paths"]) or {:error, :capability_recovery_grant_changed},
         {:ok, ^grant} <- read_grant(input, opts) do
      locked_stage_commit(store, input, factory, grant, observed)
    end
  end

  defp locked_stage_commit(store, input, factory, grant, observed) do
    case :global.trans({{SymphonyElixir.Factory.Scheduler, :ticket_stage, input["run_id"]}, self()}, fn -> stage_commit(store, input, factory, grant, observed) end) do
      :aborted -> {:error, :ticket_stage_lock_unavailable}
      result -> result
    end
  end

  defp stage_commit(store, input, factory, grant, observed) do
    case authorization(store, input["authorization_key"]) do
      {:ok, record} ->
        replay(record, input)

      :none ->
        Store.transaction!(store, &append_authorization(&1, input, factory, grant, observed))

      error ->
        error
    end
  end

  defp append_authorization(tx, input, factory, grant, observed) do
    with {:ok, current} <- facts(tx, input, factory),
         true <- current == observed.facts or {:error, :capability_recovery_observation_changed},
         :ok <- stage_control(tx, factory, observed.control_generation),
         :ok <- exclusive(tx, input, grant),
         :ok <- TicketWorkerRunner.validate_authorization(current.run, observed.jira),
         true <- valid_grant_time?(grant) or {:error, :capability_recovery_grant_expired},
         true <- source_fresh?(observed.source_observed_at) or {:error, :capability_recovery_source_expired},
         true <- unexpired_native?(observed.native) or {:error, :capability_recovery_native_expired} do
      proof = %{
        "version" => 1,
        "kind" => "RESTORED_BASE_READ_CAPABILITY_V1",
        "authority" => "LOCAL_OPERATOR_AUTHORIZATION",
        "authorization" => input,
        "authorization_body_sha256" => digest(input["authorization_body"]),
        "authorized_at" => now(),
        "ledger" => ledger(current),
        "policy" => current.policy,
        "files" => observed.files,
        "base_blobs" => observed.base_blobs,
        "control" => Map.take(Control.status(tx, factory.scope), ~w(scope dispatcher_id controller_thread_id controller_model controller_reasoning_effort)),
        "native" => observed.native,
        "jira" => observed.jira,
        "grant" => Map.take(grant, ~w(grant_id nonce created_at expires_at purpose capability_blockers base_paths)),
        "grant_sha256" => input["grant_sha256"]
      }

      raw = Jason.encode!(proof)

      if byte_size(raw) <= @limit do
        Store.query!(tx, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES(?,?,?,?)", [@authorized, input["run_id"], raw, now()])
        {:ok, receipt(input, raw)}
      else
        {:error, :capability_recovery_proof_limit}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_observation_changed}
    end
  end

  defp observe(store, input, factory, opts) do
    with {:ok, before} <- Store.transaction!(store, &facts(&1, input, factory), mode: :deferred),
         :ok <- no_foreign_owner(before.task["task_key"], false),
         :ok <- observation_control(store, factory, opts),
         control_generation = Control.status(store, factory.scope)["generation"],
         {:ok, %{result: "PASS"}} <- Capacity.snapshot(store, capacity_policy(factory), before.run["repo_key"], Keyword.put(opts, :exclude_writer_issue_key, before.run["issue_key"])),
         {:ok, jira} <- jira_authorization(store, before.run, opts),
         source_observed_at = now(),
         route = factory.repositories[before.run["repo_key"]],
         true <- is_map(route) and route["path"] == before.run["repo_path"],
         {:ok, checkout} <- Worktree.checkout_identity(route, before.run["worktree"], clean: false, detached: false, expected_branch: before.run["branch"], expected_sha: before.run["candidate_sha"]),
         true <- {checkout.path, checkout.git_dir, checkout.common_dir} == {before.access["canonical_path"], before.access["git_dir"], before.access["common_dir"]},
         {:ok, root} <- Jason.decode(before.access["binding_json"]),
         true <- checkout.root_device == root["root_device"] and checkout.root_inode == root["root_inode"],
         {:ok, allowed_root} <- SymphonyElixir.PathSafety.canonicalize(root["allowed_root"]),
         true <- allowed_root == root["allowed_root"] and checkout.path != allowed_root and String.starts_with?(checkout.path, allowed_root <> "/"),
         :ok <- WorkerFileIO.workspace_allowed?(store, checkout.path),
         {:ok, files} <- observe_files(before, root),
         {:ok, base_blobs} <- read_blobs(before, root, input["base_sha"], input["base_paths"]),
         {:ok, native} <- native_observation(before, opts),
         {:ok, after_read} <- Store.transaction!(store, &facts(&1, input, factory), mode: :deferred),
         true <- after_read == before or {:error, :capability_recovery_observation_changed},
         :ok <- no_foreign_owner(before.task["task_key"], false) do
      result = %{facts: before, files: files, base_blobs: base_blobs, jira: jira, native: native, checkout: checkout}
      {:ok, Map.merge(result, %{control_generation: control_generation, source_observed_at: source_observed_at})}
    else
      {:error, _, _} -> {:error, :capability_recovery_file_observation_unproven}
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_observation_unproven}
    end
  end

  defp facts(store, input, factory) do
    with true <- Map.get(factory, :enabled) == true,
         {:ok, run} <- RunLedger.get(store, input["run_id"]),
         control when is_map(control) <- Control.status(store, factory.scope),
         :ok <- TicketChat.ordinary_delivery_eligibility(run),
         true <- run["state"] in ~w(WRITING REPAIRING REVIEW_WRITING),
         true <- Map.take(input, ~w(candidate_sha spec_revision contract_sha256)) == Map.take(run, ~w(candidate_sha spec_revision contract_sha256)),
         true <- Policy.ticket_selected?(factory.ticket_supervisor, run["issue_key"]),
         {:ok, evidence} <- WorkerEvidence.get(store, input["request_key"]),
         true <- evidence["run_id"] == run["run_id"],
         true <- evidence["status"] == "RESULT_RECORDED",
         true <- is_nil(evidence["consumed_at"]),
         true <- Map.take(evidence, ~w(turn_id output_sha256 binding_sha256)) == Map.take(input, ~w(turn_id output_sha256 binding_sha256)),
         true <- digest(evidence["binding_json"]) == evidence["binding_sha256"],
         true <- digest(evidence["output_json"]) == evidence["output_sha256"],
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         {:ok, output} <- Jason.decode(evidence["output_json"]),
         :ok <- StageSchemas.validate(output, binding["schema"]),
         true <- output["status"] == "BLOCKED",
         true <- output["blockers"] != [],
         true <- binding["role"] == "feature-writer",
         true <- binding["mode"] == "SOURCE",
         true <- binding["base_sha"] == input["base_sha"],
         true <- Map.take(binding, ~w(spec_revision contract_sha256)) == Map.take(run, ~w(spec_revision contract_sha256)),
         true <- binding["expected_sha"] == run["candidate_sha"] and binding["policy"] == TicketWorkerRunner.policy("SOURCE", run["worktree"]),
         true <- WorkerEvidence.owner_stopped?(store, evidence),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         true <- task["status"] == "COMPLETE",
         true <- task["role"] == "feature-writer",
         true <- task["workspace"] == run["worktree"],
         true <- Map.take(task, ~w(thread_id turn_id output_json)) == Map.take(evidence, ~w(thread_id turn_id output_json)),
         true <- task["prompt_sha256"] == binding["input_sha256"] and task["prompt_sha256"] == binding["prompt_sha256"],
         {:ok, access} <- WorkspaceAccess.get(store, evidence["reservation_key"]),
         true <- access["released_at"] == nil and access["mode"] == "SOURCE" and access["generation"] == binding["reservation_generation"],
         true <- Map.take(access, ~w(run_id task_key request_key)) == Map.take(evidence, ~w(run_id task_key request_key)),
         {:ok, access_binding} <- Jason.decode(access["binding_json"]),
         true <- Map.take(access_binding, ~w(spec_revision contract_sha256 branch)) == Map.take(run, ~w(spec_revision contract_sha256 branch)),
         true <- access_binding["prompt_sha256"] == task["prompt_sha256"],
         pin when is_map(pin) <- Store.one!(store, "SELECT * FROM ticket_review_bases WHERE run_id=?", [run["run_id"]]),
         true <- pin["base_sha"] == input["base_sha"] and run["review_base_sha"] in [nil, input["base_sha"]],
         disposition when is_map(disposition) <-
           Store.one!(
             store,
             "SELECT id,payload_json FROM events WHERE run_id=? AND event_type='TICKET_NATIVE_WRITER_BLOCKED' AND json_extract(payload_json,'$.request_key')=? ORDER BY id DESC LIMIT 1",
             [run["run_id"], evidence["request_key"]]
           ),
         :ok <- available(store, run, evidence, access, factory),
         operations = rows(store, "SELECT rowid AS journal_rowid,* FROM worker_file_operations WHERE request_key=? ORDER BY rowid", [evidence["request_key"]]),
         true <- length(operations) in 1..128 and Enum.all?(operations, &(&1["phase"] == "APPLIED" and &1["io_pending"] == 0)) do
      {:ok,
       %{
         run: run,
         task: task,
         evidence: evidence,
         binding: binding,
         access: access,
         output: output,
         pin: pin,
         disposition: disposition,
         operations: operations,
         control: Map.drop(control, ~w(generation updated_at tick_id lease_expires_at)),
         policy: policy_snapshot(factory)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :capability_recovery_not_eligible}
    end
  end

  defp available(store, run, evidence, access, factory) do
    latest = Store.one!(store, "SELECT run_id FROM runs WHERE issue_key=? AND kind='DELIVERY' ORDER BY created_at DESC,rowid DESC LIMIT 1", [run["issue_key"]])
    others = Store.one!(store, "SELECT reservation_key FROM workspace_access WHERE canonical_path=? AND released_at IS NULL AND reservation_key!=?", [run["worktree"], access["reservation_key"]])
    pending_command = Store.one!(store, "SELECT command_key FROM ticket_chat_commands WHERE run_id=? AND status IN ('PENDING','ACCEPTED')", [run["run_id"]])
    questions = Store.one!(store, "SELECT question_key FROM ticket_chat_questions WHERE run_id=? AND status='OPEN'", [run["run_id"]])
    amendments = Store.one!(store, "SELECT command_key FROM ticket_contract_amendments WHERE run_id=? AND phase NOT IN ('APPLIED','SUPERSEDED','REJECTED')", [run["run_id"]])

    competing_recovery =
      Store.one!(store, "SELECT id FROM events WHERE event_type='TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED' AND json_extract(payload_json,'$.request_key')=?", [evidence["request_key"]])

    checks =
      Store.one!(store, "SELECT c.check_key FROM controller_checks c JOIN worker_evidence e ON e.request_key=c.worker_request_key WHERE e.run_id=? AND c.phase!='COMPLETE' LIMIT 1", [run["run_id"]])

    with true <- latest["run_id"] == run["run_id"],
         true <- is_nil(others),
         true <- is_nil(pending_command),
         true <- is_nil(questions),
         true <- is_nil(amendments),
         true <- is_nil(checks),
         true <- is_nil(competing_recovery),
         true <- Enum.all?(WorkerEvidence.pending(store, run["run_id"]), &(&1["request_key"] == evidence["request_key"])),
         true <- run["implementation_iteration"] < factory.maximum_implementation_iterations,
         true <- run["code_repair_round"] < factory.maximum_code_repair_rounds do
      :ok
    else
      _ -> {:error, :capability_recovery_admission_unavailable}
    end
  end

  defp observe_files(facts, root) do
    groups = Enum.group_by(facts.operations, & &1["path"])
    expected = Enum.sort(facts.output["changed_paths"])

    with true <- Enum.sort(Map.keys(groups)) == expected,
         {:ok, ^expected} <- Worktree.pending_source_paths(facts.access["canonical_path"]) do
      Enum.reduce_while(Enum.sort(groups), {:ok, []}, fn {path, operations}, {:ok, result} ->
        observed_group(facts, root, path, operations, result)
      end)
    else
      _ -> {:error, :capability_recovery_files_unproven}
    end
  end

  defp observed_group(facts, root, path, operations, result) do
    case observe_path(facts, root, path, operations) do
      {:ok, proof} -> {:cont, {:ok, result ++ [proof]}}
      error -> {:halt, error}
    end
  end

  defp observe_path(facts, root, path, operations) do
    with true <- Enum.all?(operations, &valid_operation?(&1, facts.access)),
         true <- Enum.all?(Enum.chunk_every(operations, 2, 1, :discard), fn [before, after_row] -> before["after_sha256"] == after_row["before_sha256"] end),
         {:ok, [anchor]} <- read_blobs(facts, root, facts.run["candidate_sha"], [path]),
         true <- anchor["sha256"] == hd(operations)["before_sha256"],
         true <- Enum.all?(operations, &physical_receipt?/1),
         {:ok, %{"sha256" => current}, _} <- WorkerFileIO.request(facts.access["canonical_path"], root, "digest", %{"path" => path}),
         true <- current == List.last(operations)["after_sha256"] do
      {:ok, %{"path" => path, "before_sha256" => anchor["sha256"], "after_sha256" => current, "operations" => Enum.map(operations, &%{"rowid" => &1["journal_rowid"], "sha256" => json_hash(&1)})}}
    else
      _ -> {:error, :capability_recovery_journal_unproven}
    end
  end

  defp valid_operation?(row, access) do
    identity = Map.take(row, ~w(request_key call_id arguments_sha256 path before_sha256 after_sha256)) |> Map.put("invocation", row["io_invocation"])

    identity =
      Map.merge(identity, %{
        "root" => access["canonical_path"],
        "generation" => access["generation"],
        "reservation_key" => access["reservation_key"],
        "run_id" => access["run_id"],
        "workspace_binding_sha256" => digest(access["binding_json"])
      })

    with {:ok, binding} <- Jason.decode(row["io_binding_json"] || "null"),
         true <- binding["operation"] in ~w(replace replace_binary),
         {:ok, receipt} <- Jason.decode(row["io_receipt_json"] || "null"),
         true <- receipt["transport"] == "owned_file_helper",
         true <- receipt["exit_status"] == 0,
         true <- receipt["termination"] == %{"kind" => "exited", "code" => 0},
         true <- is_binary(receipt["creator_json"]),
         true <- is_map(receipt["cleanup"]) do
      hex?(row["before_sha256"], 64) and hex?(row["after_sha256"], 64) and WorkerFileIO.receipt_matches_binding?(row["io_receipt_json"], row["io_binding_json"], identity)
    else
      _ -> false
    end
  end

  defp physical_receipt?(row) do
    with {:ok, binding} <- Jason.decode(row["io_binding_json"]),
         {_, _, receipt} when is_map(receipt) <- WorkerFileIO.recover_mutation(binding),
         do: Jason.encode!(receipt) == row["io_receipt_json"],
         else: (_ -> false)
  end

  defp read_blobs(facts, root, revision, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, values} ->
      args = %{
        "revision" => revision,
        "expected_sha" => facts.run["candidate_sha"],
        "branch" => facts.run["branch"],
        "git_dir" => facts.access["git_dir"],
        "common_dir" => facts.access["common_dir"],
        "path" => path,
        "binary" => true
      }

      case WorkerFileIO.request_revision(facts.access["canonical_path"], root, args) do
        {:ok, value, _} -> {:cont, {:ok, values ++ [Map.take(value, ~w(revision blob_oid mode sha256 total_bytes)) |> Map.put("path", path)]}}
        _ -> {:halt, {:error, :capability_recovery_base_unproven}}
      end
    end)
  end

  defp native_observation(facts, opts) do
    thread = facts.evidence["thread_id"]

    with {:ok, opts} <- WorkerEvidence.runtime_options(facts.binding, opts),
         options = Keyword.merge(Keyword.take(opts, [:native_runtime, :workspace]), include_turns: false, include_latest_turn: true, include_queue: true),
         {:ok, native} <- native_reader(opts).read_native_thread(thread, options),
         :ok <- validate_native(facts, native),
         {:ok, _} <- WorkerEvidence.runtime_options(facts.binding, opts),
         {:ok, queue} <- NativeQueueReadback.read(queue_database(opts), thread),
         {:ok, _} <- WorkerEvidence.runtime_options(facts.binding, opts),
         {:ok, lock} <- NativeQueueReadback.writer_unlocked(native_home(opts), thread),
         {:ok, _} <- WorkerEvidence.runtime_options(facts.binding, opts) do
      dates = [native["latest_turn_observation"]["observed_at"], native["latest_turn_observation"]["confirmation"]["observed_at"], native["queue_observation"]["observed_at"]]
      expiry = dates |> Enum.map(&(DateTime.from_iso8601(&1) |> elem(1))) |> Enum.min_by(&DateTime.to_unix(&1, :microsecond)) |> DateTime.add(10, :second) |> DateTime.to_iso8601()
      {:ok, %{"observed_at" => now(), "expires_at" => expiry, "readback_sha256" => json_hash(native), "queue" => queue, "writer_lock" => lock}}
    end
  end

  defp validate_native(facts, native) do
    latest = native["latest_turn_observation"] || %{}
    confirmed = latest["confirmation"] || %{}
    queue = native["queue_observation"] || %{}

    with true <- {native["id"], native["cwd"]} == {facts.evidence["thread_id"], facts.run["worktree"]},
         true <- get_in(native, ["status", "type"]) in ~w(idle notLoaded),
         true <- latest["mode"] == "LATEST_DESC" and latest["updated_at"] == native["updatedAt"],
         true <- latest["parameters"] == %{"threadId" => native["id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
         %{"data" => [%{"id" => turn, "status" => "completed", "error" => nil, "items" => items}]} = raw <- latest["raw_response"],
         true <- turn == facts.evidence["turn_id"] and latest["sha256"] == json_hash(raw),
         true <- get_in(confirmed, ["raw_response", "data"]) == raw["data"] and confirmed["sha256"] == json_hash(confirmed["raw_response"]),
         messages = Enum.filter(items, &(&1["type"] == "agentMessage" and &1["phase"] != "commentary")),
         %{"text" => text} <- List.last(messages),
         {:ok, output} <- Jason.decode(text),
         true <- output == facts.output,
         true <- Enum.count(messages, &native_status_message?/1) == 1,
         true <- Map.take(queue, ~w(thread_id empty_complete count_lower_bound has_more)) == %{"thread_id" => native["id"], "empty_complete" => true, "count_lower_bound" => 0, "has_more" => false},
         true <- queue["raw_response"] == %{"data" => [], "nextCursor" => nil} and queue["sha256"] == json_hash(queue["raw_response"]),
         :ok <- fresh_native_observations(native) do
      :ok
    else
      _ -> {:error, :capability_recovery_native_unproven}
    end
  end

  defp native_status_message?(%{"text" => text}) when is_binary(text), do: match?({:ok, %{"status" => _}}, Jason.decode(text))
  defp native_status_message?(_message), do: false

  defp fresh_native_observations(native) do
    dates = [
      get_in(native, ["latest_turn_observation", "observed_at"]),
      get_in(native, ["latest_turn_observation", "confirmation", "observed_at"]),
      get_in(native, ["queue_observation", "observed_at"])
    ]

    if Enum.all?(dates, &fresh?/1), do: :ok, else: {:error, :capability_recovery_native_expired}
  end

  defp ledger(facts), do: Map.new(facts, fn {key, value} -> {Atom.to_string(key), json_hash(value)} end)
  defp grant_binding(input, observed), do: %{"authorization_sha256" => json_hash(input), "ledger" => ledger(observed.facts), "files" => observed.files, "base_blobs" => observed.base_blobs}

  defp stage_control(store, factory, minimum_generation \\ 0) do
    control = Control.status(store, factory.scope)

    with true <- is_map(control),
         true <- control["status"] == "ACTIVE",
         true <- control["scope"] == factory.scope,
         true <- control["dispatcher_id"] == factory.dispatcher_id,
         true <- valid_stage_lease?(control),
         true <- is_integer(minimum_generation),
         true <- minimum_generation >= 0,
         true <- is_integer(control["generation"]),
         true <- control["generation"] >= minimum_generation,
         true <- control["controller_writer_conflict_count"] == 0 do
      :ok
    else
      _ -> {:error, :capability_recovery_control_not_idle}
    end
  end

  defp valid_stage_lease?(%{"tick_id" => nil, "lease_expires_at" => nil}), do: true

  defp valid_stage_lease?(%{"tick_id" => tick, "lease_expires_at" => expiry}) when is_binary(tick) and byte_size(tick) > 0 and is_binary(expiry) do
    case DateTime.from_iso8601(expiry || "") do
      {:ok, time, _} -> DateTime.compare(time, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp valid_stage_lease?(_), do: false

  defp exclusive(store, input, proof) do
    row =
      Store.one!(
        store,
        "SELECT id FROM events WHERE event_type IN ('TICKET_CAPABILITY_RECOVERY_AUTHORIZED','TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED') AND json_extract(payload_json,'$.request_key')=?",
        [input["request_key"]]
      )

    duplicate = Store.one!(store, "SELECT id FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization.request_key')=?", [@authorized, input["request_key"]])

    grant =
      Store.one!(
        store,
        "SELECT id FROM events WHERE event_type=? AND (json_extract(payload_json,'$.grant.grant_id')=? OR json_extract(payload_json,'$.grant_sha256')=? OR json_extract(payload_json,'$.grant.nonce')=?)",
        [
          @authorized,
          input["grant_id"],
          input["grant_sha256"],
          proof["nonce"]
        ]
      )

    case {row, duplicate, grant} do
      {nil, nil, nil} -> :ok
      _ -> {:error, :capability_recovery_authorization_conflict}
    end
  end

  defp authorization(store, key) do
    case rows(store, "SELECT id,payload_json FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization.authorization_key')=?", [@authorized, key]) do
      [] -> :none
      [%{"payload_json" => raw}] when byte_size(raw) <= @limit -> with {:ok, proof} <- Jason.decode(raw), do: {:ok, %{raw: raw, proof: proof}}
      _ -> {:error, :capability_recovery_authorization_conflict}
    end
  end

  defp authorization_for_request(store, request) do
    case rows(store, "SELECT id,payload_json FROM events WHERE event_type=? AND json_extract(payload_json,'$.authorization.request_key')=?", [@authorized, request]) do
      [] ->
        :none

      [%{"payload_json" => raw}] when byte_size(raw) <= @limit ->
        with {:ok, proof} <- Jason.decode(raw),
             true <- proof["version"] == 1 and proof["kind"] == "RESTORED_BASE_READ_CAPABILITY_V1" and proof["authority"] == "LOCAL_OPERATOR_AUTHORIZATION",
             :ok <- valid_input(Map.drop(proof["authorization"], ~w(grant_id grant_sha256))),
             true <- proof["authorization_body_sha256"] == digest(proof["authorization"]["authorization_body"]) do
          {:ok, %{raw: raw, proof: proof}}
        else
          _ -> {:error, :capability_recovery_authorization_unproven}
        end

      _ ->
        {:error, :capability_recovery_authorization_conflict}
    end
  end

  defp policy_snapshot(factory) do
    fields = ~w(enabled scope dispatcher_id maximum_implementation_iterations maximum_code_repair_rounds ticket_supervisor)a
    fields = Map.new(fields, &{Atom.to_string(&1), Map.fetch!(factory, &1)})
    Map.merge(fields, capacity_limits(factory))
  end

  defp policy_factory(policy) do
    fields = ~w(enabled scope dispatcher_id maximum_implementation_iterations maximum_code_repair_rounds ticket_supervisor writer_disk_gb maximum_writers maximum_specifiers maximum_validators)a
    Map.new(fields, &{&1, Map.fetch!(policy, Atom.to_string(&1))})
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp owned_tick(store, factory, opts) do
    with {:ok, tick} <- TicketPushRecovery.tick_binding(store, opts),
         true <- tick["scope"] == factory.scope and tick["dispatcher_id"] == factory.dispatcher_id,
         do: {:ok, tick},
         else: (_ -> {:error, :capability_recovery_tick_unproven})
  end

  defp observation_control(store, factory, opts) do
    case opts[:capability_tick] do
      nil ->
        stage_control(store, factory)

      expected ->
        with {:ok, ^expected} <- owned_tick(store, factory, operator_tick: expected), do: :ok
    end
  end

  defp jira_authorization(store, run, opts) do
    case opts[:authorization] do
      nil ->
        with {:ok, snapshot} <- jira_reader(opts).issue(run["issue_key"], workspace: opts[:workspace], store: store),
             do: TicketWorkerRunner.delivery_authorization(store, run, snapshot, DateTime.utc_now(), opts)

      authorization ->
        with :ok <- TicketWorkerRunner.validate_authorization(run, authorization), do: {:ok, authorization}
    end
  end

  defp replay(record, input), do: if(record.proof["authorization"] == input, do: {:ok, receipt(input, record.raw)}, else: {:error, :capability_recovery_authorization_conflict})
  defp receipt(input, raw), do: %{status: "CAPABILITY_RECOVERY_AUTHORIZED", authorization_key: input["authorization_key"], recovery_key: "TCAP-" <> digest(raw), authorization_sha256: digest(raw)}

  defp rows(store, sql, params) do
    %{columns: columns, rows: values} = Store.query!(store, sql, params)
    Enum.map(values, &Map.new(Enum.zip(columns, &1)))
  end

  defp capacity_policy(factory),
    do: %{
      "repositories" => factory.repositories,
      "capacity" => capacity_limits(factory)
    }

  defp capacity_limits(factory) do
    %{
      "writer_disk_gb" => Map.get(factory, :writer_disk_gb, 20),
      "maximum_writers" => Map.get(factory, :maximum_writers, 2),
      "maximum_specifiers" => Map.get(factory, :maximum_specifiers, 2),
      "maximum_validators" => Map.get(factory, :maximum_validators, 2)
    }
  end

  defp native_reader(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: AppServer, else: legacy_native_reader(opts))
  defp owned_reader(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: AppServer, else: legacy_owned_reader(opts))
  defp queue_database(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: opts[:native_queue_database], else: legacy_queue_database(opts))
  defp native_home(opts), do: if(Keyword.has_key?(opts, :native_runtime), do: opts[:native_home], else: legacy_native_home(opts))

  if Mix.env() == :test do
    defp jira_reader(opts), do: opts[:jira_reader] || JiraMcpReader
    defp legacy_native_reader(opts), do: opts[:native_reader] || AppServer
    defp legacy_owned_reader(opts), do: opts[:app_server] || AppServer
    defp legacy_queue_database(opts), do: opts[:native_queue_database] || Path.join(System.user_home!(), ".codex/queue_1.sqlite")
    defp legacy_native_home(opts), do: opts[:native_home] || Path.join(System.user_home!(), ".codex")
    defp grant_root(opts), do: opts[:grant_root] || Path.join(System.user_home!(), "Library/Application Support/ai-factory/operator-grants")
  else
    defp jira_reader(_opts), do: JiraMcpReader
    defp legacy_native_reader(_opts), do: AppServer
    defp legacy_owned_reader(_opts), do: AppServer
    defp legacy_queue_database(_opts), do: Path.join(System.user_home!(), ".codex/queue_1.sqlite")
    defp legacy_native_home(_opts), do: Path.join(System.user_home!(), ".codex")
    defp grant_root(_opts), do: Path.join(System.user_home!(), "Library/Application Support/ai-factory/operator-grants")
  end

  defp read_grant(input, opts) do
    with {raw, 0} <- System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", grant_reader(), grant_root(opts), input["grant_id"]], stderr_to_stdout: true),
         true <- byte_size(raw) <= 100_000,
         {:ok, %{"raw_base64" => encoded, "sha256" => sha}} <- Jason.decode(raw),
         true <- sha == input["grant_sha256"],
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= 65_536 and digest(bytes) == sha,
         {:ok, grant} <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(grant)) == ~w(authorization_sha256 base_paths binding_sha256 capability_blockers created_at expires_at grant_id kind nonce purpose version),
         true <- grant["version"] == 1 and grant["kind"] == "CONTRACT_BASE_CAPABILITY_OPERATOR_GRANT_V1" and grant["grant_id"] == input["grant_id"],
         true <- grant["purpose"] == "RESUME_EXACT_BASE_PREIMAGE_BLOCKED_WRITER" and grant["base_paths"] == input["base_paths"],
         true <- is_list(grant["capability_blockers"]) and grant["capability_blockers"] != [] and Enum.all?(grant["capability_blockers"], &text?(&1, 8192)),
         true <- Enum.all?(~w(nonce authorization_sha256 binding_sha256), &hex?(grant[&1], 64)),
         true <- valid_grant_time?(grant) do
      {:ok, grant}
    else
      _ -> {:error, :capability_recovery_grant_unproven}
    end
  end

  defp valid_grant_time?(%{"created_at" => created_at, "expires_at" => expires_at}) when is_binary(created_at) and is_binary(expires_at) do
    with true <- utc_grant_encoding?(created_at) and utc_grant_encoding?(expires_at),
         {:ok, created, 0} <- DateTime.from_iso8601(created_at),
         {:ok, expires, 0} <- DateTime.from_iso8601(expires_at),
         do:
           DateTime.diff(DateTime.utc_now(), created, :microsecond) in 0..900_000_000 and DateTime.compare(DateTime.utc_now(), expires) == :lt and
             DateTime.diff(expires, created, :microsecond) in 1..900_000_000,
         else: (_ -> false)
  end

  defp valid_grant_time?(_), do: false

  defp utc_grant_encoding?(value),
    do: Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|\+00:00)\z/, value)

  defp unexpired_native?(%{"expires_at" => expiry, "observed_at" => observed}) when is_binary(expiry) do
    case DateTime.from_iso8601(expiry) do
      {:ok, expires, _} -> fresh?(observed) and DateTime.compare(DateTime.utc_now(), expires) == :lt
      _ -> false
    end
  end

  defp unexpired_native?(_), do: false

  defp grant_reader do
    """
    import os,sys,stat,json,hashlib,base64,re
    root, token = sys.argv[1:]
    assert os.path.isabs(root) and os.path.realpath(root) == root
    assert re.fullmatch(r'[a-zA-Z0-9_-]{1,128}',token)
    def identity(s): return (s.st_dev,s.st_ino,s.st_mode,s.st_uid,s.st_gid,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    directory = os.open(root, os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        ds = os.fstat(directory)
        assert ds.st_uid == os.getuid() and stat.S_IMODE(ds.st_mode) == 0o700
        fd = os.open(token+'.json',os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
        try:
            before = os.fstat(fd)
            assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
            assert stat.S_IMODE(before.st_mode) == 0o600 and 0 < before.st_size <= 65536
            raw = b''
            while len(raw) <= before.st_size:
                chunk = os.read(fd,min(65537-len(raw),8192))
                if not chunk: break
                raw += chunk
            assert len(raw) == before.st_size
            assert identity(before) == identity(os.fstat(fd)) == identity(os.stat(token+'.json',dir_fd=directory,follow_symlinks=False))
            assert identity(ds) == identity(os.stat(root,follow_symlinks=False))
            print(json.dumps({'raw_base64':base64.b64encode(raw).decode(),'sha256':hashlib.sha256(raw).hexdigest()}))
        finally: os.close(fd)
    finally: os.close(directory)
    """
  end

  defp fresh?(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> DateTime.diff(DateTime.utc_now(), time, :millisecond) in 0..10_000
      _ -> false
    end
  end

  defp fresh?(_), do: false

  defp source_fresh?(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> DateTime.diff(DateTime.utc_now(), time, :millisecond) in 0..30_000
      _ -> false
    end
  end

  defp source_fresh?(_), do: false
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp json_hash(value), do: value |> Jason.encode!() |> digest()

  defp valid_input(input) when is_map(input) do
    with true <- Enum.sort(Map.keys(input)) == Enum.sort(@fields),
         true <- text?(input["authorization_key"], 128),
         true <- text?(input["authorization_reference"], 2048),
         true <- text?(input["authorization_body"], 8192),
         true <- Enum.all?(~w(run_id request_key turn_id), &text?(input[&1], 256)),
         true <- Enum.all?(~w(output_sha256 binding_sha256 contract_sha256), &hex?(input[&1], 64)),
         true <- Enum.all?(~w(candidate_sha base_sha), &hex?(input[&1], 40)),
         true <- is_integer(input["spec_revision"]),
         true <- input["spec_revision"] > 0,
         true <- is_list(input["base_paths"]),
         true <- length(input["base_paths"]) in 1..8,
         true <- Enum.uniq(input["base_paths"]) == input["base_paths"],
         true <- Enum.all?(input["base_paths"], &text?(&1, 1024)) do
      :ok
    else
      _ -> {:error, :capability_recovery_authorization_invalid}
    end
  end

  defp valid_input(_input), do: {:error, :capability_recovery_authorization_invalid}
  defp text?(value, limit), do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit
  defp hex?(value, length), do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)
end
