defmodule SymphonyElixir.Factory.TicketCiGeneratedScope do
  @moduledoc "Derives a separate controller-only generated-file capability; diagnostics alone never grant writer authority."
  alias SymphonyElixir.Factory.{Store, TicketCiGenerationToolset, WorkerInstructions, Worktree}
  @profile Path.expand("../../../priv/ci_generated_only_profile_v1.json", __DIR__)
  @external_resource @profile
  @profile_sha :crypto.hash(:sha256, File.read!(@profile)) |> Base.encode16(case: :lower)
  @toolset Path.expand("../../../priv/controller_generation_toolset_v1.json", __DIR__)
  @external_resource @toolset
  @toolset_sha :crypto.hash(:sha256, File.read!(@toolset)) |> Base.encode16(case: :lower)
  @toolset_identity File.read!(@toolset) |> Jason.decode!() |> Map.take(~w(repo_key gitlab_project_id))
  @refusal {:error, :ci_generated_scope_unproven}

  @spec prepare(map(), map()) :: {:ok, map() | nil} | {:error, atom()}
  def prepare(run, row) do
    with {:ok, diagnosis, preimage} <- diagnosis(run, row),
         {:ok, sources, traces} <- sources(diagnosis, preimage) do
      prepare_sources(run, row, preimage, sources, traces)
    end
  rescue
    _ -> @refusal
  end

  @spec attach(map(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def attach(packet, %{"generated_only_capability" => capability} = scope) do
    fields = ~w(run_id spec_revision contract_sha256)

    if is_map(capability) and Map.take(packet, fields) == Map.take(capability, fields) and
         capability["claim_key"] == scope["claim_key"] do
      descriptor = %{
        "version" => 1,
        "kind" => "CI_GENERATED_ONLY_PACKET_V1",
        "capability" => capability,
        "capability_sha256" => digest(Jason.encode!(capability)),
        "instructions" =>
          "Controller-only mechanical BUILD capability, not writer permission. Only a genuine no-edit COMPLETE at the exact failed candidate, with no CONTINUE lineage, can select it. Never edit BUILD or invent a source edit to trigger generation. Source edits remain governed solely by the original CI scope."
      }

      {:ok, Map.put(packet, "controller_generation_scope", descriptor)}
    else
      @refusal
    end
  end

  def attach(packet, _scope), do: {:ok, packet}

  @doc "Selects the mechanical mode only for an unchanged first completion under its admitted packet."
  @spec select(Store.connection(), map(), map(), map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def select(store, run, scope, evidence, binding, output) do
    capability = scope["generated_only_capability"]

    if is_map(capability) and output["status"] == "COMPLETE" and output["changed_paths"] == [] and
         binding["expected_sha"] == capability["failed_candidate_sha"] and
         run["implementation_iteration"] == scope["prior_run"]["implementation_iteration"] do
      select_packet(store, run, scope, evidence, binding)
    else
      {:ok, scope}
    end
  end

  defp select_packet(store, run, scope, evidence, binding) do
    with mapping when is_map(mapping) <- Store.one!(store, "SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?", [evidence["task_key"], binding["prompt_sha256"]]),
         true <- mapping["run_id"] == run["run_id"] and mapping["role"] == "feature-writer",
         snapshot when is_map(snapshot) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]]),
         true <- digest(snapshot["binding_json"]) == mapping["instruction_binding_sha256"],
         {:ok, packet} <- Jason.decode(snapshot["binding_json"]),
         {:ok, _} <- WorkerInstructions.read(store, packet, "ci-repair-writer"),
         true <-
           Map.take(packet, ~w(run_id spec_revision contract_sha256 code_repair_round implementation_iteration)) ==
             Map.take(run, ~w(run_id spec_revision contract_sha256 code_repair_round implementation_iteration)),
         true <- packet["candidate_sha"] == binding["expected_sha"] and packet["ci_repair"]["claim_key"] == scope["claim_key"],
         {:ok, expected} <- attach(Map.delete(packet, "controller_generation_scope"), scope),
         true <- packet == expected do
      proof = %{
        "version" => 1,
        "kind" => "CI_GENERATED_ONLY_EXECUTION_V1",
        "capability" => scope["generated_only_capability"],
        "instruction_binding_sha256" => mapping["instruction_binding_sha256"],
        "packet_sha256" => digest(snapshot["binding_json"]),
        "request_key" => evidence["request_key"],
        "binding_sha256" => evidence["binding_sha256"],
        "output_sha256" => evidence["output_sha256"],
        "reservation_key" => evidence["reservation_key"],
        "reservation_generation" => binding["reservation_generation"]
      }

      {:ok, Map.put(scope, "generated_only_execution", proof)}
    else
      _ -> @refusal
    end
  end

  @doc "Authorizes only outputs of the finalized mechanical journal, never the available capability alone."
  @spec completed_paths(Store.connection(), map(), map(), map()) :: {:ok, [String.t()]} | {:error, atom()}
  def completed_paths(store, run, scope, output) do
    if is_map(scope["generated_only_capability"]) and output["status"] == "COMPLETE" and output["changed_paths"] == [] do
      completed_journal(store, run, scope, output)
    else
      {:ok, []}
    end
  end

  defp completed_journal(store, run, scope, output) do
    with evidence when is_map(evidence) <-
           Store.one!(store, "SELECT * FROM worker_evidence WHERE run_id=? AND task_key=? AND status='RESULT_RECORDED' AND output_sha256=?", [
             run["run_id"],
             run["run_id"] <> ":feature-writer",
             digest(Jason.encode!(output))
           ]),
         {:ok, binding} <- Jason.decode(evidence["binding_json"]),
         {:ok, %{"generated_only_execution" => proof}} <- select(store, run, scope, evidence, binding, output),
         intent when is_map(intent) <- Store.one!(store, "SELECT * FROM ticket_ci_generation_intents WHERE request_key=? AND operation='GAZELLE_DIFF'", [evidence["request_key"]]),
         true <- digest(intent["binding_json"]) == intent["binding_sha256"] and intent["claim_key"] == scope["claim_key"],
         {:ok, saved} <- Jason.decode(intent["binding_json"]),
         true <- saved["kind"] == "CONTROLLER_CI_GENERATED_ONLY" and saved["generated_only_execution"] == proof,
         {:ok, final} <- journal_event(store, intent["intent_key"], "FINALIZED", ""),
         {:ok, execution} <- journal_event(store, intent["intent_key"], "EXECUTION_RECEIPT", ""),
         true <- final["execution_sha256"] == digest(Jason.encode!(execution)),
         paths = final["changed_paths"],
         true <- is_list(paths) and paths != [] and paths == Enum.sort(Enum.uniq(paths)) and Enum.all?(paths, &(&1 in saved["paths"])),
         true <- Enum.all?(paths, &applied_path?(store, intent["intent_key"], &1)) do
      {:ok, paths}
    else
      _ -> @refusal
    end
  end

  defp applied_path?(store, key, path) do
    with {:ok, applied} <- journal_event(store, key, "APPLIED", path),
         {:ok, prepared} <- journal_event(store, key, "APPLY_PREPARED", path),
         true <- applied["binding_json"] == Jason.encode!(prepared),
         proposal when is_map(proposal) <- prepared["proposal"],
         true <- proposal["path"] == path and digest(proposal["content"]) == proposal["after_sha256"] do
      applied["result"] == %{"path" => path, "sha256" => proposal["after_sha256"]}
    else
      _ -> false
    end
  end

  defp journal_event(store, key, type, path) do
    with row when is_map(row) <- Store.one!(store, "SELECT receipt_json,receipt_sha256 FROM ticket_ci_generation_events WHERE intent_key=? AND event_type=? AND path=?", [key, type, path]),
         true <- digest(row["receipt_json"]) == row["receipt_sha256"],
         {:ok, value} <- Jason.decode(row["receipt_json"]) do
      {:ok, value}
    else
      _ -> @refusal
    end
  end

  @doc "Rechecks immutable claim/diagnosis facts without observing files inside a ledger transaction."
  @spec authenticate(map(), map(), map() | nil) :: :ok | {:error, atom()}
  def authenticate(_run, _row, nil), do: :ok

  def authenticate(run, row, capability) do
    with {:ok, diagnosis, preimage} <- diagnosis(run, row),
         {:ok, sources, traces} <- sources(diagnosis, preimage),
         true <- sources != [],
         true <- run["repo_key"] == @toolset_identity["repo_key"] and project_id(preimage) == @toolset_identity["gitlab_project_id"],
         true <- Map.drop(capability, ~w(go_inputs build_inputs generated_paths)) == metadata(run, row, traces, %{"manifest_sha256" => @toolset_sha}),
         true <- Enum.map(capability["go_inputs"], & &1["path"]) == sources,
         true <- Enum.all?(capability["go_inputs"] ++ capability["build_inputs"], &regular_input?/1),
         builds = Enum.map(capability["build_inputs"], & &1["path"]),
         true <- builds == Enum.sort(Enum.uniq(builds)) and builds == capability["generated_paths"],
         true <- Enum.all?(builds, &(Path.basename(&1) in ~w(BUILD BUILD.bazel))),
         true <- Enum.map(builds, &Path.dirname/1) == sources |> Enum.map(&Path.dirname/1) |> Enum.uniq() |> Enum.sort() do
      :ok
    else
      _ -> @refusal
    end
  rescue
    _ -> @refusal
  end

  defp regular_input?(input) do
    Enum.sort(Map.keys(input)) == ~w(git_blob_sha mode path sha256 size) and
      input["mode"] in ~w(100644 100755) and input["size"] in 1..262_144 and
      Regex.match?(~r/\A[0-9a-f]{40}\z/, input["git_blob_sha"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, input["sha256"])
  end

  defp prepare_sources(_run, _row, _preimage, [], _traces), do: {:ok, nil}

  defp prepare_sources(run, row, preimage, sources, traces) do
    case qualified_toolset(run, preimage, TicketCiGenerationToolset.load()) do
      nil -> {:ok, nil}
      toolset -> prepare_files(run, row, sources, traces, toolset)
    end
  end

  @doc false
  @spec qualified_toolset(map(), map(), term()) :: map() | nil
  def qualified_toolset(run, preimage, {:ok, toolset}) when is_map(toolset) do
    if toolset["available"] == true and toolset["manifest_sha256"] == @toolset_sha and
         toolset["repo_key"] == run["repo_key"] and toolset["gitlab_project_id"] == project_id(preimage), do: toolset
  end

  def qualified_toolset(_, _, _), do: nil

  defp prepare_files(run, row, sources, traces, toolset) do
    with {:ok, raw} <- File.read(Application.app_dir(:symphony_elixir, "priv/ci_generated_only_profile_v1.json")),
         true <- digest(raw) == @profile_sha,
         {:ok, files} <- Worktree.generation_scope_inputs(%{"path" => run["repo_path"]}, run["worktree"], run["branch"], run["candidate_sha"], sources) do
      {:ok, files |> Map.merge(metadata(run, row, traces, toolset)) |> Map.put("generated_paths", Enum.map(files["build_inputs"], & &1["path"]))}
    else
      _ -> @refusal
    end
  end

  defp metadata(run, row, traces, toolset) do
    %{
      "version" => 1,
      "kind" => "CI_GENERATED_ONLY_V1",
      "profile_sha256" => @profile_sha,
      "toolset_manifest_sha256" => toolset["manifest_sha256"],
      "run_id" => run["run_id"],
      "repo_key" => run["repo_key"],
      "gitlab_project_id" => @toolset_identity["gitlab_project_id"],
      "spec_revision" => run["spec_revision"],
      "contract_sha256" => run["contract_sha256"],
      "failed_candidate_sha" => run["candidate_sha"],
      "pipeline_id" => row["pipeline_id"],
      "diagnosis_key" => row["diagnosis_key"],
      "diagnosis_sha256" => row["diagnosis_sha256"],
      "preimage_sha256" => row["preimage_sha256"],
      "claim_key" => "ci-claim:" <> digest(row["diagnosis_key"]),
      "traces" => traces
    }
  end

  defp diagnosis(run, row) do
    with true <- row["verdict"] == "REPAIRABLE" and row["run_id"] == run["run_id"] and row["candidate_sha"] == run["candidate_sha"],
         true <- row["pipeline_id"] == run["ci_pipeline_id"],
         true <- digest(row["diagnosis_json"]) == row["diagnosis_sha256"] and digest(row["preimage_json"]) == row["preimage_sha256"],
         {:ok, diagnosis} <- Jason.decode(row["diagnosis_json"]),
         {:ok, preimage} <- Jason.decode(row["preimage_json"]),
         true <- diagnosis["status"] == "REPAIRABLE" and diagnosis["pipeline_id"] == row["pipeline_id"],
         true <- Map.take(preimage["run"], ~w(run_id candidate_sha spec_revision contract_sha256)) == Map.take(run, ~w(run_id candidate_sha spec_revision contract_sha256)) do
      {:ok, diagnosis, preimage}
    else
      _ -> @refusal
    end
  end

  defp sources(diagnosis, preimage) do
    permitted = MapSet.intersection(MapSet.new(diagnosis["changed_paths"]), MapSet.new(diagnosis["allowed_writer_paths"]))
    project = project_id(preimage)

    result =
      Enum.reduce_while(diagnosis["logs"], {:ok, [], []}, fn entry, {:ok, paths, traces} ->
        selected =
          Regex.scan(~r{(go/src/[A-Za-z0-9_./-]+\.go): import of "[^"\r\n]+"}, entry["text"], capture: :all_but_first)
          |> List.flatten()
          |> Enum.filter(&MapSet.member?(permitted, &1))
          |> Enum.uniq()

        if selected == [],
          do: {:cont, {:ok, paths, traces}},
          else: source_trace(diagnosis, entry, project, selected, paths, traces)
      end)

    with {:ok, paths, traces} <- result,
         paths = Enum.sort(Enum.uniq(paths)),
         true <- length(paths) <= 16 do
      {:ok, paths, traces |> Enum.uniq() |> Enum.sort_by(& &1["job_id"])}
    else
      _ -> @refusal
    end
  end

  defp source_trace(diagnosis, entry, project, selected, paths, traces) do
    id = entry["job_id"]
    failed = Enum.any?(diagnosis["failed_jobs"], &(&1["id"] == id))
    available = Enum.any?(diagnosis["trace_availability"], &(&1["job_id"] == id and &1["status"] == "COMPLETE"))
    proof = Enum.filter(diagnosis["trace_provenance"], &(get_in(&1, ["arguments", "job_id"]) == to_string(id)))

    with true <- failed and available,
         [provenance] <- proof,
         true <- get_in(provenance, ["arguments", "project_id"]) == project,
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, provenance["raw_sha256"]) do
      trace = %{"job_id" => id, "log_sha256" => digest(entry["text"]), "provenance_sha256" => digest(Jason.encode!(provenance)), "source_paths" => Enum.sort(selected)}
      {:cont, {:ok, paths ++ selected, traces ++ [trace]}}
    else
      _ -> {:halt, @refusal}
    end
  end

  defp project_id(preimage) do
    case get_in(preimage, ["ci_snapshots", "mr", "project_id"]) do
      id when is_integer(id) and id > 0 -> Integer.to_string(id)
      id when is_binary(id) -> if Regex.match?(~r/\A[1-9][0-9]*\z/, id), do: id
      _ -> nil
    end
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
