defmodule SymphonyElixir.Factory.TicketCiGeneration do
  @moduledoc "Separate controller generation journal; unavailable confinement never creates authority."
  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.Factory.{
    Control,
    Controller,
    Policy,
    RepairObligations,
    ReviewProtocol,
    RunLedger,
    Store,
    TaskLedger,
    TicketChat,
    TicketCiGeneratedScope,
    TicketCiGenerationDiff,
    TicketCiGenerationIO,
    TicketCiGenerationToolset,
    TicketCiRepair,
    TicketMrGuard,
    TicketWorkerRunner,
    WorkerEvidence,
    WorkerFileIO,
    Worktree
  }

  @observer Path.expand("../../../priv/controller_generation_io_v1.py", __DIR__)
  @external_resource @observer
  @observer_sha :crypto.hash(:sha256, File.read!(@observer))
  @ordinary_observer Path.expand("../../../priv/controller_generation_io_v2.py", __DIR__)
  @external_resource @ordinary_observer
  @ordinary_observer_sha :crypto.hash(:sha256, File.read!(@ordinary_observer))

  @spec prepare(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(%DBConnection{}, _request_key), do: {:error, :controller_generation_observation_inside_transaction}

  def prepare(store, request_key) do
    with {:ok, context} <- context(store, request_key), do: prepare_owned(store, context)
  end

  defp prepare_owned(store, context) do
    key = context.evidence["request_key"]

    with {:ok, toolset} <- action_toolset(context),
         {:ok, observed} <- observe(store, context),
         {:ok, policy} <- Controller.cached_generation_policy(store, context.run["repo_key"]),
         true <- policy == context.policy or {:error, :controller_generation_policy_changed},
         {:ok, ^toolset} <- action_toolset(context) do
      Store.transaction!(store, fn tx ->
        with :ok <- recheck_context(tx, context),
             :ok <- TicketMrGuard.native_receipt(context.native_request, observed.native, DateTime.utc_now()),
             nil <- Store.one!(tx, "SELECT intent_key FROM #{intent_table(context)} WHERE request_key = ? LIMIT 1", [key]) do
          persist_intents(tx, context, observed, toolset)
        else
          {:error, _} = error -> error
          _ -> {:error, :controller_generation_already_prepared}
        end
      end)
    else
      {:error, _} = error -> error
    end
  end

  defp context(store, key) do
    with {:ok, evidence} <- WorkerEvidence.get(store, key),
         {:ok, run} <- RunLedger.get(store, evidence["run_id"]),
         {:ok, task} <- TaskLedger.get(store, evidence["task_key"]),
         {:ok, policy} <- Controller.cached_generation_policy(store, run["repo_key"]),
         :ok <- policy_bound(policy, run),
         {:ok, scope} when is_map(scope) <- writer_scope(store, run, key),
         {:ok, binding} <- checked_object(evidence["binding_json"], evidence["binding_sha256"]),
         {:ok, output} <- checked_object(evidence["output_json"], evidence["output_sha256"]),
         :ok <- ReviewProtocol.validate_result(store, task, binding, output),
         {:ok, scope} <- TicketCiGeneratedScope.select(store, run, scope, evidence, binding, output),
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [evidence["reservation_key"]]),
         source = Store.one!(store, "SELECT * FROM native_source_bindings WHERE run_id = ?", [run["run_id"]]),
         base when is_map(base) <- Store.one!(store, "SELECT * FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]]),
         :ok <- stopped_writer(store, run, task, evidence, binding, access, source, output),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, run["run_id"]),
         {:ok, _} <- TicketChat.ready_for_run(store, run["run_id"]),
         %{"status" => "ACTIVE"} = control <- Control.status(store, policy["scope"]),
         true <- control["dispatcher_id"] == policy["dispatcher_id"] or {:error, :controller_generation_dispatcher_changed},
         :ok <- no_pending_io(store, run["run_id"]),
         {:ok, owned_paths} <- owned_generation_paths(store, run, evidence, binding, scope),
         dirty_paths = Enum.sort(Enum.uniq(output["changed_paths"] ++ owned_paths)),
         {:ok, committed} <- repair_descendants(store, policy, run, evidence, scope, binding, output, dirty_paths),
         {:ok, scope} <- generation_paths(run, scope, output, committed),
         {:ok, actions} <- actions(scope, output, committed) do
      native_request = %{
        "existing_thread_id" => task["thread_id"],
        "cwd" => binding["policy"]["cwd"],
        "codex_project_id" => task["codex_project_id"] || "projectless",
        "metadata_json" => Jason.encode!(%{"previous_turn_id" => task["turn_id"], "delivery_operation" => %{"controller_native_cwd" => binding["policy"]["cwd"]}})
      }

      {:ok,
       %{
         run: run,
         task: task,
         evidence: evidence,
         access: access,
         source: source,
         policy: policy,
         scope: scope,
         inputs: inputs,
         control: control,
         binding: binding,
         output: output,
         dirty_paths: dirty_paths,
         native_request: native_request,
         actions: actions,
         base: base
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :controller_generation_binding_unproven}
    end
  end

  defp writer_scope(store, run, key) do
    case TicketCiRepair.effective_writer_scope(store, run, key) do
      {:ok, nil} ->
        ordinary_writer_scope(store, run, key)

      result ->
        result
    end
  end

  defp ordinary_writer_scope(store, %{"state" => "REPAIRING"} = run, key) do
    with {:ok, proof} <- RepairObligations.ordinary_generation(store, run, key) do
      {:ok, %{"ordinary_verifier_repair" => proof, "prior_run" => %{"candidate_sha" => proof["reviewed_candidate_sha"]}}}
    end
  end

  defp ordinary_writer_scope(_store, _run, _key), do: {:ok, nil}

  defp generation_paths(run, %{"ordinary_verifier_repair" => _} = scope, output, committed) do
    paths = Enum.sort(Enum.uniq(output["changed_paths"] ++ committed))
    go = Enum.filter(paths, &String.ends_with?(&1, ".go"))

    if length(paths) <= 128 and Enum.all?(paths, &TicketCiRepair.source_path?/1) do
      generated =
        go
        |> Enum.map(&Path.dirname/1)
        |> Enum.uniq()
        |> Enum.map(fn package ->
          candidates = Enum.map(~w(BUILD BUILD.bazel), &Path.join(package, &1))
          Enum.find(candidates, &File.exists?(Path.join(run["worktree"], &1))) || hd(candidates)
        end)
        |> Enum.sort()

      gofmt = Enum.filter(go, fn path -> match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(run["worktree"], path))) end)
      {:ok, scope |> Map.put("allowed_writer_paths", paths -- generated) |> Map.put("required_generated_paths", generated) |> Map.put("gofmt_paths", gofmt)}
    else
      {:error, :controller_generation_scope_unproven}
    end
  end

  defp generation_paths(_run, scope, _output, _committed), do: {:ok, scope}

  defp intent_table(%{scope: %{"ordinary_verifier_repair" => _}}), do: "ticket_ordinary_generation_intents"
  defp intent_table("ordinary-generation:" <> _), do: "ticket_ordinary_generation_intents"
  defp intent_table(_), do: "ticket_ci_generation_intents"

  defp event_table("ordinary-generation:" <> _), do: "ticket_ordinary_generation_events"
  defp event_table(_), do: "ticket_ci_generation_events"

  defp generation_version(%{scope: %{"ordinary_verifier_repair" => _}}), do: 2
  defp generation_version(%{scope: %{"generated_only_execution" => _}}), do: 3
  defp generation_version(_), do: 1

  defp repair_descendants(store, policy, run, evidence, scope, binding, output, dirty_paths) do
    case Worktree.generation_candidate_paths(
           policy["route"],
           run["worktree"],
           run["branch"],
           scope["prior_run"]["candidate_sha"],
           binding["expected_sha"],
           dirty_paths
         ) do
      {:error, :controller_generation_head_changed} ->
        with true <-
               dirty_paths != [] and
                 not is_nil(
                   Store.one!(
                     store,
                     "SELECT intent_key FROM #{intent_table(%{scope: scope})} WHERE request_key=? LIMIT 1",
                     [evidence["request_key"]]
                   )
                 ),
             :ok <- commit_ready(store, evidence["request_key"]),
             message = output["commit_message"] || "fix(#{run["issue_key"]}): repair generated CI inputs",
             {:ok, committed} <-
               Worktree.generation_committed_parent_paths(
                 policy["route"],
                 run["worktree"],
                 run["branch"],
                 scope["prior_run"]["candidate_sha"],
                 binding["expected_sha"],
                 dirty_paths,
                 message
               ),
             true <- run["candidate_sha"] in [binding["expected_sha"], committed.sha] do
          {:ok, committed.paths}
        else
          _ -> {:error, :controller_generation_head_changed}
        end

      result ->
        result
    end
  end

  defp owned_generation_paths(store, run, evidence, binding, scope) do
    context = %{scope: scope, run: run}
    found = Store.query!(store, "SELECT * FROM #{intent_table(context)} WHERE request_key=? ORDER BY operation", [evidence["request_key"]])

    if length(found.rows) <= 2 do
      reduce_generation_paths(store, context, evidence, binding, found)
    else
      {:error, :controller_generation_journal_unproven}
    end
  end

  defp reduce_generation_paths(store, context, evidence, binding, found) do
    Enum.reduce_while(found.rows, {:ok, []}, fn values, {:ok, paths} ->
      row = Map.new(Enum.zip(found.columns, values))

      case owned_generation_row(store, context, evidence, binding, row) do
        {:ok, applied_paths} -> {:cont, {:ok, paths ++ applied_paths}}
        _ -> {:halt, {:error, :controller_generation_reconcile_required}}
      end
    end)
  end

  defp owned_generation_row(store, context, evidence, binding, row) do
    %{scope: scope, run: run} = context

    with {:ok, intent} <- checked_object(row["binding_json"], row["binding_sha256"]),
         true <- row["run_id"] == run["run_id"] and intent["operation"] == row["operation"],
         true <- row["intent_key"] == intent_prefix(scope) <> digest(Jason.encode!([evidence["request_key"], row["operation"]])),
         true <- ordinary_intent?(row, intent, scope),
         true <-
           intent["run_preimage"]["candidate_sha"] == binding["expected_sha"] and
             Map.take(intent["run_preimage"], ~w(run_id spec_revision contract_sha256 code_repair_round)) == Map.take(run, ~w(run_id spec_revision contract_sha256 code_repair_round)),
         :ok <- no_uncertain_event(store, row["intent_key"]),
         {:ok, applied_paths} <- owned_apply_paths(store, context, row, intent) do
      {:ok, applied_paths}
    else
      _ -> {:error, :controller_generation_reconcile_required}
    end
  end

  defp intent_prefix(%{"ordinary_verifier_repair" => _}), do: "ordinary-generation:"
  defp intent_prefix(_), do: "ci-generation:"

  defp ordinary_intent?(row, intent, %{"ordinary_verifier_repair" => proof}) do
    intent["kind"] == "CONTROLLER_ORDINARY_GENERATION" and intent["ordinary_verifier_repair"] == proof and row["verifier_request_key"] == proof["verifier_request_key"]
  end

  defp ordinary_intent?(_row, intent, %{"generated_only_execution" => proof}),
    do: intent["kind"] == "CONTROLLER_CI_GENERATED_ONLY" and intent["generated_only_execution"] == proof

  defp ordinary_intent?(_row, intent, _scope), do: intent["kind"] == "CONTROLLER_CI_GENERATION"

  defp owned_apply_paths(store, context, row, intent) do
    result = Store.query!(store, "SELECT path,receipt_json,receipt_sha256 FROM #{event_table(row["intent_key"])} WHERE intent_key=? AND event_type='APPLY_STARTED' ORDER BY path", [row["intent_key"]])

    if length(result.rows) <= 32 do
      reduce_apply_paths(store, context, row, intent, result.rows)
    else
      {:error, :controller_generation_journal_unproven}
    end
  end

  defp reduce_apply_paths(store, context, row, intent, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [path, raw, hash], {:ok, paths} ->
      case owned_apply_path(store, context, row, intent, path, raw, hash) do
        :ok -> {:cont, {:ok, paths ++ [path]}}
        _ -> {:halt, {:error, :controller_generation_reconcile_required}}
      end
    end)
  end

  defp owned_apply_path(store, context, row, intent, path, raw, hash) do
    with true <- path in intent["paths"],
         {:ok, started} <- checked_object(raw, hash),
         prepared when is_map(prepared) <- event(store, row["intent_key"], "APPLY_PREPARED", path),
         {:ok, sealed} <- checked_object(prepared["receipt_json"], prepared["receipt_sha256"]),
         true <- started["binding_json"] == Jason.encode!(sealed),
         true <- sealed["intent_key"] == row["intent_key"] and sealed["intent_sha256"] == row["binding_sha256"] and sealed["started_type"] == "APPLY_STARTED",
         true <- sealed["proposal"]["path"] == path and digest(sealed["proposal"]["content"]) == sealed["proposal"]["after_sha256"],
         {:ok, receipt} <- owned_apply_receipt(store, row, path, sealed, started),
         true <- receipt["binding_json"] == started["binding_json"] and receipt["helper_pid"] == started["helper_pid"],
         :ok <- valid_receipt(sealed, receipt),
         {:ok, current} <- observe_files(store, context.run["worktree"], [path], generation_version(context)),
         [%{"sha256" => current_sha}] <- current["files"],
         true <- current_sha == sealed["proposal"]["after_sha256"] do
      :ok
    else
      _ -> {:error, :controller_generation_reconcile_required}
    end
  end

  defp owned_apply_receipt(store, row, path, sealed, started) do
    case event(store, row["intent_key"], "APPLIED", path) do
      nil -> TicketCiGenerationIO.status(sealed, started["helper_pid"])
      applied -> checked_object(applied["receipt_json"], applied["receipt_sha256"])
    end
  end

  defp policy_bound(policy, run) do
    route = policy["route"]

    if policy["enabled"] == true and policy["ticket_supervisor_enabled"] == true and policy["ci_repair"] == "native_bounded_v1" and
         Policy.ticket_selected?(policy["ticket_selection"], run["issue_key"]) and
         route["path"] == run["repo_path"] and route["base_branch"] == run["base_branch"] and
         Regex.match?(~r/\A[1-9][0-9]*\z/, to_string(route["gitlab_project_id"])), do: :ok, else: {:error, :controller_generation_policy_unavailable}
  end

  defp action_toolset(%{actions: []}), do: {:ok, nil}

  defp action_toolset(context) do
    with {:ok, toolset} <- TicketCiGenerationToolset.load(),
         true <- toolset["repo_key"] == context.run["repo_key"] and toolset["gitlab_project_id"] == to_string(context.policy["route"]["gitlab_project_id"]) do
      {:ok, toolset}
    else
      _ -> {:error, :controller_generation_policy_unavailable}
    end
  end

  defp stopped_writer(store, run, task, evidence, binding, access, _source, output) do
    expected = {run["run_id"], run["run_id"] <> ":feature-writer", "feature-writer", "REPAIRING", "COMPLETE", "RESULT_RECORDED", "SOURCE", nil}
    actual = {task["run_id"], task["task_key"], task["role"], task["stage"], task["status"], evidence["status"], access["mode"], access["released_at"]}

    if run["state"] == "REPAIRING" and actual == expected and WorkerEvidence.owner_stopped?(store, evidence) and
         output["status"] == "COMPLETE" and task["output_json"] == evidence["output_json"] and
         Map.take(task, ~w(thread_id turn_id)) == Map.take(evidence, ~w(thread_id turn_id)) and is_binary(task["turn_id"]) and
         binding["input_sha256"] == task["prompt_sha256"] and binding["contract_sha256"] == run["contract_sha256"] and
         Map.take(binding, ~w(task_key run_id role stage model reasoning_effort)) == Map.take(task, ~w(task_key run_id role stage model reasoning_effort)) and
         binding["spec_revision"] == run["spec_revision"] and binding["reservation_generation"] == access["generation"] and
         access["request_key"] == evidence["request_key"] and access["task_key"] == task["task_key"] and access["canonical_path"] == run["worktree"] and
         binding["policy"] == TicketWorkerRunner.policy("SOURCE", run["worktree"]),
       do: :ok,
       else: {:error, :controller_generation_writer_unproven}
  end

  defp no_pending_io(store, run_id) do
    pending =
      Store.one!(
        store,
        "SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence e ON e.request_key=op.request_key WHERE e.run_id=? AND (op.phase='PREPARED' OR op.io_pending=1) LIMIT 1",
        [run_id]
      )

    active = Store.one!(store, "SELECT task_key FROM factory_tasks WHERE run_id=? AND status IN ('STARTING','RUNNING') LIMIT 1", [run_id])
    if is_nil(pending) and is_nil(active), do: :ok, else: {:error, :controller_generation_io_pending}
  end

  defp actions(%{"generated_only_execution" => proof}, %{"changed_paths" => []}, committed) do
    paths = proof["capability"]["generated_paths"]
    if Enum.all?(committed, &(&1 in paths)), do: {:ok, [{"GAZELLE_DIFF", paths}]}, else: {:error, :controller_generation_scope_unproven}
  end

  defp actions(%{"generated_only_execution" => _}, _, _), do: {:error, :controller_generation_scope_unproven}

  defp actions(scope, output, committed) do
    paths = output["changed_paths"]
    generated = scope["required_generated_paths"]

    with true <- is_list(paths) and is_list(generated),
         true <- Enum.all?(paths, &(&1 in scope["allowed_writer_paths"])),
         go = Enum.filter(Enum.uniq(paths ++ committed), &(&1 in scope["allowed_writer_paths"] and String.ends_with?(&1, ".go"))) |> Enum.sort(),
         true <- Enum.all?(generated, &(is_binary(&1) and Path.basename(&1) in ~w(BUILD BUILD.bazel))) do
      generated = Enum.filter(generated, &(Path.dirname(&1) in Enum.map(go, fn path -> Path.dirname(path) end)))
      gofmt = if Map.has_key?(scope, "ordinary_verifier_repair"), do: Enum.filter(go, &(&1 in scope["gofmt_paths"])), else: go
      actions = Enum.reject([{"GOFMT_DIFF", gofmt}, {"GAZELLE_DIFF", Enum.sort(generated)}], fn {_operation, paths} -> paths == [] end)
      {:ok, actions}
    else
      _ -> {:error, :controller_generation_scope_unproven}
    end
  end

  defp observe(store, context) do
    run = context.run
    paths = context.dirty_paths
    all_paths = context.actions |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
    route = context.policy["route"]

    with {:ok, native_options} <- WorkerEvidence.runtime_options(context.binding, workspace: context.binding["policy"]["cwd"]),
         {:ok, tree} <- Worktree.generation_inputs(route, run["worktree"], run["branch"], context.binding["expected_sha"], paths),
         {:ok, committed} <- Worktree.generation_candidate_paths(route, run["worktree"], run["branch"], context.base["base_sha"], context.binding["expected_sha"], paths),
         true <- Enum.all?(all_paths -- generated_paths(context.scope), &(&1 in (paths ++ committed))) or {:error, :controller_generation_package_unproven},
         packages = Enum.filter(committed, &String.ends_with?(&1, ".go")) |> Enum.map(&Path.dirname/1) |> Enum.uniq(),
         generated = context.actions |> Enum.filter(&(elem(&1, 0) == "GAZELLE_DIFF")) |> Enum.flat_map(&elem(&1, 1)),
         true <-
           Enum.all?(generated, &(Path.dirname(&1) in packages or Path.dirname(&1) in Enum.map(paths, fn path -> Path.dirname(path) end) or &1 in generated_only_paths(context.scope))) or
             {:error, :controller_generation_package_unproven},
         {:ok, spool} <- WorkerFileIO.controller_spool(store, run["worktree"]),
         {:ok, files} <- observe_files(store, run["worktree"], all_paths, generation_version(context)),
         {:ok, native} <- AppServer.read_native_thread(context.task["thread_id"], Keyword.merge(native_options, include_turns: false, include_latest_turn: true, include_queue: true)),
         :ok <- TicketMrGuard.native_receipt(context.native_request, native, DateTime.utc_now()),
         {:ok, _} <- WorkerEvidence.runtime_options(context.binding, native_options),
         {:ok, ^tree} <- Worktree.generation_inputs(route, run["worktree"], run["branch"], context.binding["expected_sha"], paths),
         {:ok, ^files} <- observe_files(store, run["worktree"], all_paths, generation_version(context)) do
      {:ok, %{tree: tree, files: files, native: native, spool: spool}}
    end
  end

  defp generated_only_paths(%{"generated_only_execution" => proof}), do: proof["capability"]["generated_paths"]
  defp generated_only_paths(_), do: []
  defp generated_paths(scope), do: Enum.uniq(scope["required_generated_paths"] ++ generated_only_paths(scope))

  defp observe_files(_store, _root, [], _version), do: {:ok, nil}

  defp observe_files(store, root, paths, version) do
    with {:ok, transport} <- WorkerFileIO.controller_spool(store, root),
         {:ok, %{"version" => 1, "files" => files} = observed} <- TicketCiGenerationIO.observe(transport, paths, version),
         true <- Enum.map(files, & &1["path"]) == paths,
         true <- Enum.all?(files, &(is_integer(&1["size"]) and &1["size"] <= 262_144)) do
      {:ok, Map.delete(observed, "owned_observer_receipt")}
    else
      _ -> {:error, :controller_generation_input_unproven}
    end
  end

  defp recheck_context(tx, context) do
    with {:ok, run} <- RunLedger.get(tx, context.run["run_id"]),
         true <- run == context.run,
         {:ok, task} <- TaskLedger.get(tx, context.task["task_key"]),
         true <- task == context.task,
         {:ok, evidence} <- WorkerEvidence.get(tx, context.evidence["request_key"]),
         true <- evidence == context.evidence,
         true <- Store.one!(tx, "SELECT * FROM workspace_access WHERE reservation_key=?", [context.access["reservation_key"]]) == context.access,
         true <- Store.one!(tx, "SELECT * FROM native_source_bindings WHERE run_id=?", [run["run_id"]]) == context.source,
         true <- Store.one!(tx, "SELECT * FROM ticket_review_bases WHERE run_id=?", [run["run_id"]]) == context.base,
         {:ok, scope} <- writer_scope(tx, run, context.evidence["request_key"]),
         true <-
           scope == Map.drop(context.scope, if(Map.has_key?(scope, "ordinary_verifier_repair"), do: ~w(allowed_writer_paths required_generated_paths gofmt_paths), else: ~w(generated_only_execution))),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(tx, run["run_id"]),
         true <- inputs == context.inputs,
         current_control when is_map(current_control) <- Control.status(tx, context.policy["scope"]),
         true <-
           Map.drop(current_control, ~w(generation tick_id lease_expires_at updated_at)) == Map.drop(context.control, ~w(generation tick_id lease_expires_at updated_at)),
         :ok <- no_pending_io(tx, run["run_id"]) do
      :ok
    else
      _ -> {:error, :controller_generation_binding_changed}
    end
  end

  defp persist_intents(tx, context, observed, toolset) do
    intents =
      Enum.map(context.actions, fn {operation, paths} ->
        ordinary = Map.has_key?(context.scope, "ordinary_verifier_repair")
        key = if(ordinary, do: "ordinary-generation:", else: "ci-generation:") <> digest(Jason.encode!([context.evidence["request_key"], operation]))

        binding = %{
          "version" => 1,
          "kind" =>
            if(ordinary, do: "CONTROLLER_ORDINARY_GENERATION", else: if(Map.has_key?(context.scope, "generated_only_execution"), do: "CONTROLLER_CI_GENERATED_ONLY", else: "CONTROLLER_CI_GENERATION")),
          "operation" => operation,
          "paths" => paths,
          "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
          "ledger" => ledger_snapshot(tx, context),
          "run_preimage" => context.run,
          "policy" => context.policy,
          "toolset" => toolset,
          "observation" => %{observed | files: Map.update!(observed.files, "files", &Enum.filter(&1, fn file -> file["path"] in paths end))},
          "observer_path" => if(ordinary, do: @ordinary_observer, else: @observer),
          "observer_sha256" => Base.encode16(if(ordinary, do: @ordinary_observer_sha, else: @observer_sha), case: :lower)
        }

        binding = if ordinary, do: Map.put(binding, "ordinary_verifier_repair", context.scope["ordinary_verifier_repair"]), else: binding
        binding = if Map.has_key?(context.scope, "generated_only_execution"), do: Map.put(binding, "generated_only_execution", context.scope["generated_only_execution"]), else: binding

        raw = Jason.encode!(binding)

        Store.query!(tx, "INSERT INTO #{intent_table(context)} VALUES (?,?,?,?,?,?,?,?)", [
          key,
          context.run["run_id"],
          if(ordinary, do: context.scope["ordinary_verifier_repair"]["verifier_request_key"], else: context.scope["claim_key"]),
          context.evidence["request_key"],
          operation,
          raw,
          digest(raw),
          DateTime.utc_now() |> DateTime.to_iso8601()
        ])

        %{intent_key: key, operation: operation, binding_sha256: digest(raw)}
      end)

    {:ok, %{status: "PREPARED", intents: intents}}
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  @doc "Runs the approved generation journal before deciding whether a completed repair made progress."
  @spec complete(Store.connection(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def complete(store, request_key, _run, %{"status" => status} = output) when status != "COMPLETE" do
    with :ok <- commit_ready(store, request_key), do: {:ok, output}
  end

  def complete(store, request_key, run, output) do
    with {:ok, scope} <- writer_scope(store, run, request_key) do
      if is_nil(scope) or output["status"] != "COMPLETE" do
        with :ok <- commit_ready(store, request_key), do: {:ok, output}
      else
        with {:ok, context} <- context(store, request_key),
             :ok <- ensure_prepared(store, request_key, context),
             {:ok, paths} <- complete_intents(store, context),
             :ok <- commit_ready(store, request_key) do
          effective = Enum.sort(Enum.uniq(output["changed_paths"] ++ paths))
          message = output["commit_message"] || if(paths != [], do: "fix(#{run["issue_key"]}): repair generated CI inputs")
          {:ok, output |> Map.put("changed_paths", effective) |> Map.put("commit_message", message)}
        end
      end
    end
  end

  defp ensure_prepared(store, key, context) do
    case Store.one!(store, "SELECT intent_key FROM #{intent_table(context)} WHERE request_key=? LIMIT 1", [key]) do
      nil -> with {:ok, _} <- prepare_owned(store, context), do: :ok
      _ -> :ok
    end
  end

  defp complete_intents(store, context) do
    intents = Store.query!(store, "SELECT * FROM #{intent_table(context)} WHERE request_key=? ORDER BY operation DESC", [context.evidence["request_key"]])
    rows = Enum.map(intents.rows, &Map.new(Enum.zip(intents.columns, &1)))

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, paths} ->
      case complete_intent(store, context, row) do
        {:ok, changed} -> {:cont, {:ok, paths ++ changed}}
        error -> {:halt, error}
      end
    end)
  end

  defp complete_intent(store, context, row) do
    with {:ok, binding} <- checked_object(row["binding_json"], row["binding_sha256"]),
         {operation, paths} <- List.keyfind(context.actions, row["operation"], 0),
         true <- (binding["operation"] == operation and binding["paths"] == paths and ordinary_intent?(row, binding, context.scope)) or {:error, :controller_generation_scope_unproven} do
      case event(store, row["intent_key"], "FINALIZED", "") do
        nil ->
          with true <- binding["ledger"] == ledger_snapshot(store, context) or {:error, :controller_generation_binding_changed}, do: generate_intent(store, context, row, binding)

        final ->
          with :ok <- finalized_context(store, context, binding),
               {:ok, value} <- checked_object(final["receipt_json"], final["receipt_sha256"]),
               :ok <- finalized_bytes(store, context, row, value["changed_paths"]) do
            {:ok, value["changed_paths"]}
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :controller_generation_scope_unproven}
    end
  end

  defp finalized_context(store, context, binding) do
    current = ledger_snapshot(store, context)
    prior = binding["run_preimage"]

    if is_map(prior) and Map.drop(prior, ~w(candidate_sha updated_at)) == Map.drop(context.run, ~w(candidate_sha updated_at)) and
         Map.delete(binding["ledger"], "run") == Map.delete(current, "run"), do: :ok, else: {:error, :controller_generation_binding_changed}
  end

  defp finalized_bytes(_store, _context, _row, []), do: :ok

  defp finalized_bytes(store, context, row, paths) when is_list(paths) do
    with {:ok, current} <- observe_files(store, context.run["worktree"], paths, generation_version(context)) do
      Enum.reduce_while(current["files"], :ok, fn file, :ok ->
        with applied when is_map(applied) <- event(store, row["intent_key"], "APPLIED", file["path"]),
             {:ok, receipt} <- checked_object(applied["receipt_json"], applied["receipt_sha256"]),
             true <- receipt["result"] == %{"path" => file["path"], "sha256" => file["sha256"]} do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, :controller_generation_applied_bytes_changed}}
        end
      end)
    end
  end

  defp finalized_bytes(_, _, _, _), do: {:error, :controller_generation_journal_unproven}

  defp generate_intent(store, context, row, binding) do
    with :ok <- no_uncertain_event(store, row["intent_key"]),
         {:ok, execution} <- session(store, context, row, binding, "", nil),
         {:ok, receipt} <- execute_session(store, context, row, execution),
         {:ok, proposals} <- proposals(binding, receipt),
         :ok <- apply_proposals(store, context, row, binding, proposals),
         paths = Enum.map(proposals, & &1["path"]),
         :ok <- finalized_bytes(store, context, row, paths),
         :ok <- recheck_context(store, context),
         :ok <- append_event(store, row, "FINALIZED", "", %{"version" => 1, "changed_paths" => paths, "execution_sha256" => digest(Jason.encode!(receipt))}) do
      {:ok, paths}
    end
  end

  defp no_uncertain_event(store, key) do
    case Store.one!(store, "SELECT event_key FROM #{event_table(key)} WHERE intent_key=? AND event_type IN ('UNCERTAIN','BLOCKED') LIMIT 1", [key]) do
      nil -> :ok
      _ -> {:error, :controller_generation_reconcile_required}
    end
  end

  defp session(store, context, row, intent, path, proposal) do
    type = if is_nil(proposal), do: "EXECUTION_PREPARED", else: "APPLY_PREPARED"

    case event(store, row["intent_key"], type, path) do
      nil ->
        with {:ok, transport} <- TicketCiGenerationIO.binding(context.run["worktree"], generation_version(context)),
             {:ok, current_toolset} <- TicketCiGenerationToolset.load(),
             true <- current_toolset == intent["toolset"] or {:error, :controller_generation_toolset_changed},
             :ok <- recheck_context(store, context),
             {:ok, files} <- observe_files(store, context.run["worktree"], intent["paths"], generation_version(context)),
             true <- is_map(proposal) or files == intent["observation"]["files"] or {:error, :controller_generation_preimage_changed} do
          started_type = if is_nil(proposal), do: "EXECUTION_STARTED", else: "APPLY_STARTED"
          started_key = "ci-generation-event:" <> digest(Jason.encode!([row["intent_key"], started_type, path]))

          sealed =
            intent["observation"]["spool"]
            |> Map.merge(transport)
            |> Map.merge(%{
              "version" => 1,
              "intent_key" => row["intent_key"],
              "intent_sha256" => row["binding_sha256"],
              "run_id" => context.run["run_id"],
              "request_key" => context.evidence["request_key"],
              "scope" => context.policy["scope"],
              "ledger" => ledger_snapshot(store, context),
              "read_columns" => read_columns(store, context),
              "tick" => current_tick(store, context),
              "toolset" => intent["toolset"],
              "operation" => intent["operation"],
              "paths" => intent["paths"],
              "files" => files,
              "root_device" => files["root_device"],
              "root_inode" => files["root_inode"],
              "started_key" => started_key,
              "started_type" => started_type,
              "event_key" => "ci-generation-event:" <> digest(Jason.encode!([row["intent_key"], "APPLY_CREATED", path])),
              "proposal" => proposal
            })

          sealed = if generation_version(context) == 3, do: Map.put(sealed, "generation_version", 3), else: sealed

          with :ok <- append_event(store, row, type, path, sealed), do: {:ok, sealed}
        else
          {:error, _} = error -> error
        end

      prepared ->
        checked_object(prepared["receipt_json"], prepared["receipt_sha256"])
    end
  end

  defp current_tick(store, context), do: Control.status(store, context.policy["scope"]) |> Map.take(~w(scope tick_id dispatcher_id lease_expires_at))

  defp read_columns(store, context) do
    tables =
      ~w(runs factory_tasks worker_evidence workspace_access native_source_bindings ticket_review_bases ticket_ci_repair_claims control ticket_chat_commands ticket_chat_questions ticket_contract_amendments ticket_chats ticket_chat_runs desktop_requests ticket_chat_inputs worker_file_operations ticket_ci_generation_intents ticket_ci_generation_events)

    tables =
      if Map.has_key?(context.scope, "ordinary_verifier_repair"),
        do: tables ++ ~w(ticket_ordinary_generation_intents ticket_ordinary_generation_events worker_instruction_snapshots worker_instruction_task_bindings),
        else: tables

    tables =
      if Map.has_key?(context.scope, "generated_only_execution"),
        do: tables ++ ~w(worker_instruction_snapshots worker_instruction_task_bindings ticket_ci_repair_diagnoses ticket_ci_repair_reassessments),
        else: tables

    Map.new(tables, fn table -> {table, Store.query!(store, "PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1))} end)
  end

  defp execute_session(store, context, row, binding) do
    path = if is_map(binding["proposal"]), do: binding["proposal"]["path"], else: ""
    type = binding["started_type"]
    finished_type = if type == "APPLY_STARTED", do: "APPLIED", else: "EXECUTION_RECEIPT"

    case event(store, row["intent_key"], finished_type, path) do
      nil ->
        result =
          case event(store, row["intent_key"], type, path) do
            nil ->
              started = fn pid ->
                with :ok <- recheck_context(store, context),
                     {:ok, toolset} <- TicketCiGenerationToolset.load(),
                     true <- toolset == binding["toolset"] or {:error, :controller_generation_toolset_changed} do
                  append_event(store, row, type, path, %{"helper_pid" => pid, "binding_json" => Jason.encode!(binding)})
                end
              end

              creator = fn raw -> creator_event(store, row, binding, raw) end
              TicketCiGenerationIO.execute(binding, started, creator)

            started ->
              with {:ok, value} <- checked_object(started["receipt_json"], started["receipt_sha256"]) do
                TicketCiGenerationIO.status(binding, value["helper_pid"])
              end
          end

        case result do
          {:ok, receipt} ->
            with :ok <- valid_receipt(binding, receipt), :ok <- append_event(store, row, finished_type, path, receipt), do: {:ok, receipt}

          {:error, _} ->
            _ = append_event(store, row, "UNCERTAIN", path, %{"version" => 1, "binding_sha256" => digest(Jason.encode!(binding)), "reason" => "OWNED_RECEIPT_UNPROVEN"})
            {:error, :controller_generation_reconcile_required}
        end

      finished ->
        checked_object(finished["receipt_json"], finished["receipt_sha256"])
    end
  end

  defp valid_receipt(%{"started_type" => "EXECUTION_STARTED"}, %{"kind" => "CONTROLLER_GENERATION_EXECUTED", "results" => results}) when is_list(results), do: :ok

  defp valid_receipt(%{"proposal" => proposal}, %{"kind" => "CONTROLLER_GENERATION_APPLIED", "result" => result}) do
    expected = %{"path" => proposal["path"], "sha256" => proposal["after_sha256"]}
    if result == expected, do: :ok, else: {:error, :controller_generation_receipt_unproven}
  end

  defp valid_receipt(_, _), do: {:error, :controller_generation_receipt_unproven}

  defp creator_event(store, row, binding, raw) do
    with {:ok, creator} <- Jason.decode(raw),
         true <- Map.take(creator, ~w(path before_sha256 after_sha256)) == Map.take(binding["proposal"], ~w(path before_sha256 after_sha256)),
         true <- creator["invocation"] == binding["invocation"] and creator["intent_key"] == binding["intent_key"] and creator["event_key"] == binding["event_key"],
         started when is_map(started) <- event(store, row["intent_key"], "APPLY_STARTED", creator["path"]),
         {:ok, owner} <- checked_object(started["receipt_json"], started["receipt_sha256"]),
         true <- creator["pid"] == owner["helper_pid"] do
      append_event(store, row, "APPLY_CREATED", creator["path"], creator)
    else
      _ -> {:error, :controller_generation_creator_unproven}
    end
  end

  defp proposals(binding, receipt) do
    files = Map.new(binding["observation"]["files"]["files"], &{&1["path"], Base.decode64!(&1["bytes_base64"])})
    operation = binding["operation"]
    expected = if operation == "GOFMT_DIFF", do: binding["paths"], else: [""]

    if Enum.map(receipt["results"], & &1["path"]) == expected do
      Enum.reduce_while(receipt["results"], {:ok, []}, fn result, {:ok, acc} ->
        with {:ok, raw} <- Base.decode64(result["stdout_base64"]),
             true <- digest(raw) == result["stdout_sha256"] and result["exit_code"] in [0, 1],
             {:ok, changes} <- diff_plan(operation, raw, binding, files, result["path"]) do
          observed = Map.new(binding["observation"]["files"]["files"], &{&1["path"], &1})

          planned =
            Enum.map(
              changes,
              &%{
                "path" => &1.path,
                "before_sha256" => if(observed[&1.path]["absent"] == true, do: "ABSENT", else: digest(&1.before)),
                "after_sha256" => digest(&1.after),
                "content" => &1.after
              }
            )

          {:cont, {:ok, acc ++ planned}}
        else
          _ -> {:halt, {:error, :controller_generation_diff_rejected}}
        end
      end)
    else
      {:error, :controller_generation_receipt_unproven}
    end
  end

  defp diff_plan("GOFMT_DIFF", raw, binding, files, path), do: TicketCiGenerationDiff.plan_stdin(raw, binding["observation"]["spool"]["root"], path, files[path])

  defp diff_plan("GAZELLE_DIFF", raw, %{"kind" => "CONTROLLER_ORDINARY_GENERATION"} = binding, files, _) do
    absent = binding["observation"]["files"]["files"] |> Enum.filter(&(&1["absent"] == true)) |> Enum.map(& &1["path"])
    TicketCiGenerationDiff.plan_generated(raw, binding["observation"]["spool"]["root"], binding["paths"], files, absent)
  end

  defp diff_plan("GAZELLE_DIFF", raw, binding, files, _), do: TicketCiGenerationDiff.plan("gazelle", raw, binding["observation"]["spool"]["root"], binding["paths"], files)

  defp apply_proposals(store, context, row, binding, proposals) do
    Enum.reduce_while(proposals, :ok, fn proposal, :ok ->
      with {:ok, sealed} <- session(store, context, row, binding, proposal["path"], proposal),
           true <- sealed["proposal"] == proposal or {:error, :controller_generation_proposal_changed},
           {:ok, _} <- execute_session(store, context, row, sealed) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp event(store, key, type, path), do: Store.one!(store, "SELECT * FROM #{event_table(key)} WHERE intent_key=? AND event_type=? AND path=?", [key, type, path])

  defp append_event(store, row, type, path, value) do
    raw = Jason.encode!(value)
    key = "ci-generation-event:" <> digest(Jason.encode!([row["intent_key"], type, path]))

    Store.transaction!(store, fn tx ->
      case event(tx, row["intent_key"], type, path) do
        nil ->
          Store.query!(tx, "INSERT INTO #{event_table(row["intent_key"])} VALUES (?,?,?,?,?,?,?,?)", [
            key,
            row["intent_key"],
            type,
            path,
            nil,
            raw,
            digest(raw),
            DateTime.utc_now() |> DateTime.to_iso8601()
          ])

          :ok

        %{"receipt_json" => ^raw} ->
          :ok

        _ ->
          {:error, :controller_generation_event_changed}
      end
    end)
  end

  defp ledger_snapshot(store, context) do
    run_id = context.run["run_id"]

    queries = %{
      "run" => {"SELECT * FROM runs WHERE run_id=?", [run_id]},
      "tasks" => {"SELECT * FROM factory_tasks WHERE run_id=? ORDER BY task_key", [run_id]},
      "evidence" => {"SELECT * FROM worker_evidence WHERE run_id=? ORDER BY request_key", [run_id]},
      "access" => {"SELECT * FROM workspace_access WHERE run_id=? ORDER BY reservation_key", [run_id]},
      "source" => {"SELECT * FROM native_source_bindings WHERE run_id=?", [run_id]},
      "base" => {"SELECT * FROM ticket_review_bases WHERE run_id=?", [run_id]},
      "claims" => {"SELECT * FROM ticket_ci_repair_claims WHERE run_id=? ORDER BY round", [run_id]},
      "control" => {"SELECT * FROM control WHERE scope=?", [context.policy["scope"]]},
      "commands" => {"SELECT * FROM ticket_chat_commands WHERE run_id=? ORDER BY command_key", [run_id]},
      "questions" => {"SELECT * FROM ticket_chat_questions WHERE run_id=? ORDER BY question_key", [run_id]},
      "amendments" => {"SELECT * FROM ticket_contract_amendments WHERE run_id=? ORDER BY command_key", [run_id]},
      "parent" => {"SELECT chat.* FROM ticket_chats chat JOIN ticket_chat_runs r ON r.chat_key=chat.chat_key WHERE r.run_id=?", [run_id]},
      "bootstrap" =>
        {"SELECT request.* FROM desktop_requests request JOIN ticket_chats chat ON chat.create_request_key=request.request_key JOIN ticket_chat_runs r ON r.chat_key=chat.chat_key WHERE r.run_id=?",
         [run_id]},
      "inputs" => {"SELECT input.* FROM ticket_chat_inputs input JOIN ticket_chat_runs r ON r.chat_key=input.chat_key WHERE r.run_id=? ORDER BY input.input_key", [run_id]},
      "file_operations" => {"SELECT op.* FROM worker_file_operations op JOIN worker_evidence e ON e.request_key=op.request_key WHERE e.run_id=? ORDER BY op.call_id", [run_id]}
    }

    queries =
      if Map.has_key?(context.scope, "ordinary_verifier_repair") or Map.has_key?(context.scope, "generated_only_execution") do
        Map.merge(queries, %{
          "instruction_snapshots" => {"SELECT * FROM worker_instruction_snapshots WHERE run_id=? ORDER BY binding_sha256", [run_id]},
          "instruction_bindings" => {"SELECT * FROM worker_instruction_task_bindings WHERE run_id=? ORDER BY task_key,prompt_sha256", [run_id]}
        })
      else
        queries
      end

    Map.new(queries, fn {name, {sql, values}} ->
      result = Store.query!(store, sql, values)
      omitted = if name == "control", do: ~w(generation tick_id lease_expires_at updated_at), else: []
      columns = Enum.reject(result.columns, &(&1 in omitted))
      indexes = Enum.map(columns, &Enum.find_index(result.columns, fn column -> column == &1 end))
      rows = Enum.map(result.rows, fn row -> Enum.map(indexes, &Enum.at(row, &1)) end)
      {name, %{"columns" => columns, "sha256" => digest(Jason.encode!([columns, rows]))}}
    end)
  end

  @doc "No commit may pass unresolved generation, including after policy is disabled or the controller restarts."
  @spec commit_ready(Store.connection(), String.t()) :: :ok | {:error, atom()}
  def commit_ready(store, request_key) do
    Enum.reduce_while(~w(ticket_ci_generation ticket_ordinary_generation), :ok, fn prefix, :ok ->
      case Store.one!(
             store,
             "SELECT i.intent_key FROM #{prefix}_intents i WHERE request_key = ? AND NOT EXISTS (SELECT 1 FROM #{prefix}_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path='') LIMIT 1",
             [request_key]
           ) do
        nil -> {:cont, :ok}
        _ -> {:halt, {:error, :controller_generation_pending}}
      end
    end)
  end

  @doc "Reads durable journal identities only; it neither reruns tools nor applies proposed bytes."
  @spec readback(Store.connection(), String.t()) :: {:ok, map()} | {:error, atom()}
  def readback(store, request_key) when is_binary(request_key) do
    rows =
      Enum.flat_map(~w(ticket_ci_generation_intents ticket_ordinary_generation_intents), fn table ->
        Store.query!(store, "SELECT intent_key, binding_json, binding_sha256 FROM #{table} WHERE request_key = ? ORDER BY intent_key", [request_key]).rows
      end)

    Enum.reduce_while(rows, {:ok, []}, fn [key, raw, hash], {:ok, result} ->
      with {:ok, _} <- checked_object(raw, hash),
           {:ok, events} <- read_events(store, key) do
        {:cont, {:ok, [%{intent_key: key, binding_sha256: hash, events: events, owned_receipts: status_receipts(store, key)} | result]}}
      else
        _ -> {:halt, {:error, :controller_generation_journal_unproven}}
      end
    end)
    |> case do
      {:ok, intents} -> {:ok, %{status: if(intents == [], do: "UNAVAILABLE", else: "RECONCILE_REQUIRED"), intents: Enum.reverse(intents)}}
      error -> error
    end
  end

  def readback(_, _), do: {:error, :controller_generation_journal_unproven}

  defp status_receipts(store, key) do
    Store.query!(
      store,
      "SELECT event_type,path,receipt_json,receipt_sha256 FROM #{event_table(key)} WHERE intent_key=? AND event_type IN ('EXECUTION_STARTED','APPLY_STARTED') ORDER BY created_at,event_key",
      [key]
    ).rows
    |> Enum.map(fn [type, path, raw, hash] ->
      prepared_type = if type == "EXECUTION_STARTED", do: "EXECUTION_PREPARED", else: "APPLY_PREPARED"

      with {:ok, started} <- checked_object(raw, hash),
           prepared when is_map(prepared) <- event(store, key, prepared_type, path),
           {:ok, binding} <- checked_object(prepared["receipt_json"], prepared["receipt_sha256"]),
           true <- binding["version"] == 1 and binding["intent_key"] == key and binding["started_type"] == type,
           true <- started["binding_json"] == Jason.encode!(binding),
           {:ok, receipt} <- TicketCiGenerationIO.status(binding, started["helper_pid"]),
           :ok <- valid_receipt(binding, receipt) do
        %{type: type, path: path, status: "OWNED_RECEIPT_AVAILABLE", receipt: receipt}
      else
        _ -> %{type: type, path: path, status: "OWNED_RECEIPT_UNPROVEN"}
      end
    end)
  end

  defp read_events(store, key) do
    Store.query!(store, "SELECT event_key, event_type, path, receipt_json, receipt_sha256 FROM #{event_table(key)} WHERE intent_key = ? ORDER BY created_at, event_key", [key]).rows
    |> Enum.reduce_while({:ok, []}, fn [key, type, path, raw, hash], {:ok, result} ->
      case checked_object(raw, hash) do
        {:ok, _} -> {:cont, {:ok, [%{event_key: key, event_type: type, path: path, receipt_sha256: hash} | result]}}
        _ -> {:halt, {:error, :controller_generation_journal_unproven}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp checked_object(raw, hash) when is_binary(raw) and is_binary(hash) do
    with true <- Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == hash,
         {:ok, value} when is_map(value) <- Jason.decode(raw) do
      {:ok, value}
    else
      _ -> {:error, :controller_generation_journal_unproven}
    end
  end

  defp checked_object(_, _), do: {:error, :controller_generation_journal_unproven}
end
