defmodule SymphonyElixir.Factory.NativeWorktreeProbe do
  @moduledoc "Read-only, request-owned managed-worktree capability receipts."

  alias SymphonyElixir.Factory.{DesktopRequest, RunLedger, StageSchemas, Store, TaskLedger, Worktree}
  alias SymphonyElixir.Factory.NativeMaintenanceEvidence

  @operation "NATIVE_WORKTREE_PROBE"
  @eligible_states ~w(READY_FOR_REVIEW DELIVERED AWAITING_VALIDATION)

  @spec enqueue(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def enqueue(store, run_id), do: enqueue(store, run_id, nil)

  @spec enqueue(Store.connection(), String.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def enqueue(store, run_id, route) do
    with :ok <- maintenance_route(route),
         {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, writer} <- TaskLedger.get(store, run_id <> ":feature-writer"),
         :ok <- eligible(run, writer) do
      key = request_key(run, writer)

      DesktopRequest.enqueue(store, %{
        request_key: key,
        target_kind: "TASK",
        target_key: writer["task_key"],
        action: "FOLLOWUP",
        existing_thread_id: writer["thread_id"],
        codex_project_id: writer["codex_project_id"],
        model: if(route, do: route.model, else: writer["model"]),
        reasoning_effort: if(route, do: route.reasoning_effort, else: writer["reasoning_effort"]),
        title: "#{run["issue_key"]}: managed worktree capability probe",
        prompt: probe_prompt(key, run, writer),
        cwd: writer["workspace"],
        branch: run["branch"],
        base_branch: run["base_branch"],
        schema: StageSchemas.for_stage(:native_worktree_probe),
        metadata:
          %{
            "maintenance_operation" => @operation,
            "workspace_mode" => "CODEX_NATIVE",
            "run_id" => run_id,
            "repo_path" => run["repo_path"],
            "candidate_sha" => run["candidate_sha"],
            "expected_sha" => run["candidate_sha"],
            "previous_turn_id" => writer["turn_id"],
            "emitter_sha256" => NativeMaintenanceEvidence.emitter_sha256()
          }
          |> maybe_route(route)
      })
    end
  end

  defp maintenance_route(nil), do: :ok
  defp maintenance_route(%{resolved_role: "workspace-maintainer", model_class: "fast", reasoning_effort: "low"}), do: :ok
  defp maintenance_route(_route), do: {:error, :maintenance_requires_fast_low_route}

  defp maybe_route(metadata, nil), do: metadata
  defp maybe_route(metadata, route), do: Map.put(metadata, "maintenance_model_route", Map.take(route, [:model, :reasoning_effort, :resolved_role]))

  defp probe_prompt(key, run, writer) do
    headers = %{
      "binding" => %{
        "run_id" => run["run_id"],
        "task_key" => writer["task_key"],
        "thread_id" => writer["thread_id"],
        "writer_turn_id" => writer["turn_id"],
        "codex_project_id" => writer["codex_project_id"],
        "worktree" => writer["workspace"],
        "candidate_sha" => run["candidate_sha"],
        "source_cwd" => run["repo_path"]
      },
      "tool" => "mcp__codex_app__list_artifacts"
    }

    encoded = headers |> Jason.encode!() |> Base.encode64()

    "Factory request ID: #{key}\n\nRead-only maintenance. Call actual list_artifacts in this bound chat exactly once. " <>
      "Capture its returned object, not a paraphrase. Decode these binding/tool input headers: #{encoded}. " <>
      "Add artifact_output with the captured raw return, encode that JSON as base64, and run only " <>
      "python3 -B #{NativeMaintenanceEvidence.emitter_path()} #{key} --payload-base64 BASE64_JSON. " <>
      "This emits target-attested evidence on stdout without writing files or the factory ledger. " <>
      "Do not claim, record, or complete a Desktop request; do not write source, archive, restore, delete, " <>
      "commit, or contact Jira/GitLab. Emit the captured evidence and acknowledge completion; do not reconstruct a semantic receipt. " <>
      "The broker separately reads the completed command/tool frame and records evidence. " <>
      "Attachment absence or SUPPORTED capability never authorizes cleanup."
  end

  @spec operation(map()) :: {:ok, String.t() | nil} | {:error, atom()}
  def operation(request) do
    case Jason.decode(request["metadata_json"] || "{}") do
      {:ok, metadata} when is_map(metadata) ->
        case Map.fetch(metadata, "maintenance_operation") do
          :error -> {:ok, nil}
          {:ok, @operation} -> {:ok, @operation}
          _other -> {:error, :unsupported_maintenance_operation}
        end

      _other ->
        {:error, :invalid_maintenance_metadata}
    end
  end

  @spec validate_request(Store.connection(), map()) :: :ok | {:error, term()}
  def validate_request(store, request) do
    with {:ok, op} <- operation(request) do
      cond do
        op ->
          validate_probe_request(store, request)

        probe_schema?(request) ->
          {:error, :maintenance_operation_missing}

        true ->
          :ok
      end
    end
  end

  @spec record(Store.connection(), map(), String.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def record(store, request, thread_id, proof) do
    with :ok <- validate_probe_request(store, request),
         true <- thread_id == request["existing_thread_id"] or {:error, :maintenance_thread_mismatch},
         {:ok, workspace} <- checkout(store, request),
         true <- proof_matches?(proof, workspace) or {:error, :maintenance_checkout_proof_missing} do
      {:ok, workspace}
    end
  end

  @spec validate_completion(Store.connection(), map(), map()) :: :ok | {:error, term()}
  def validate_completion(store, request, attrs) do
    with {:ok, op} <- operation(request) do
      if op, do: validate_probe_completion(store, request, attrs), else: :ok
    end
  end

  @spec receipt(map(), map()) :: {:ok, map()} | {:error, atom()}
  def receipt(request, %{"artifacts" => artifacts} = observed) when is_list(artifacts) do
    if Map.keys(observed) == ["artifacts"] and Enum.all?(artifacts, &is_map/1) do
      active = Enum.filter(artifacts, &(is_map(&1) and &1["attachmentType"] == "worktree"))
      matching = Enum.filter(active, &artifact_matches?(&1, request))
      {status, artifact, reason} = disposition(active, matching)
      metadata = Jason.decode!(request["metadata_json"])

      {:ok,
       %{
         "status" => status,
         "run_id" => metadata["run_id"],
         "task_key" => request["target_key"],
         "thread_id" => request["existing_thread_id"],
         "writer_turn_id" => metadata["previous_turn_id"],
         "worktree" => request["cwd"],
         "candidate_sha" => metadata["candidate_sha"],
         "source_cwd" => metadata["repo_path"],
         "artifact_id" => artifact && artifact["id"],
         "artifact_identity_key" => artifact && artifact["identityKey"],
         "reason" => reason
       }}
    else
      {:error, :invalid_artifact_observation}
    end
  end

  def receipt(_request, _observed), do: {:error, :invalid_artifact_observation}

  defp validate_probe_request(store, request) do
    with {:ok, @operation} <- operation(request),
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, writer} <- TaskLedger.get(store, request["target_key"]),
         {:ok, run} <- RunLedger.get(store, writer["run_id"]),
         :ok <- eligible(run, writer),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- schema == StageSchemas.for_stage(:native_worktree_probe) or {:error, :unsupported_maintenance_schema},
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt},
         true <- request_bound?(request, metadata, run, writer) or {:error, :maintenance_binding_changed} do
      :ok
    else
      {:ok, _other} -> {:error, :unsupported_maintenance_operation}
      {:error, _reason} = error -> error
    end
  end

  defp eligible(run, writer) do
    if run["factory_owned"] == 0 and run["workspace_state"] == "CODEX_NATIVE" and
         run["state"] in @eligible_states and writer["status"] in ~w(COMPLETE CONSUMED) and
         TaskLedger.source_writer?(writer) and writer["workspace"] == run["worktree"] and
         writer["workspace_sha"] == run["candidate_sha"] and
         Enum.all?([writer["turn_id"], writer["thread_id"], writer["workspace"], run["candidate_sha"]], &present?/1),
       do: :ok,
       else: {:error, :maintenance_writer_not_eligible}
  end

  defp request_bound?(request, metadata, run, writer) do
    expected_request = %{
      "request_key" => request_key(run, writer),
      "target_kind" => "TASK",
      "action" => "FOLLOWUP",
      "existing_thread_id" => writer["thread_id"],
      "codex_project_id" => writer["codex_project_id"],
      "model" => get_in(metadata, ["maintenance_model_route", "model"]) || writer["model"],
      "reasoning_effort" => get_in(metadata, ["maintenance_model_route", "reasoning_effort"]) || writer["reasoning_effort"],
      "cwd" => writer["workspace"],
      "branch" => run["branch"],
      "base_branch" => run["base_branch"]
    }

    expected_metadata = %{
      "run_id" => run["run_id"],
      "candidate_sha" => run["candidate_sha"],
      "expected_sha" => run["candidate_sha"],
      "repo_path" => run["repo_path"],
      "previous_turn_id" => writer["turn_id"],
      "workspace_mode" => "CODEX_NATIVE"
    }

    Map.take(request, Map.keys(expected_request)) == expected_request and
      Map.take(metadata, Map.keys(expected_metadata)) == expected_metadata and
      String.starts_with?(request["prompt"], "Factory request ID: #{request["request_key"]}\n\n")
  end

  defp request_key(run, writer) do
    digest =
      [run["run_id"], writer["task_key"], writer["thread_id"], writer["workspace"], run["candidate_sha"], writer["turn_id"]]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "desktop:maintenance:#{digest}:native-worktree-probe"
  end

  defp checkout(store, request) do
    {:ok, writer} = TaskLedger.get(store, request["target_key"])
    {:ok, run} = RunLedger.get(store, writer["run_id"])
    opts = [clean: false, detached: false, expected_branch: run["branch"], expected_sha: run["candidate_sha"]]
    Worktree.validate_native(%{"path" => run["repo_path"]}, request["cwd"], opts)
  end

  defp proof_matches?(proof, workspace) when is_map(proof) do
    (proof["cwd"] || proof[:cwd]) == workspace.path and (proof["head_sha"] || proof[:head_sha]) == workspace.sha
  end

  defp proof_matches?(_proof, _workspace), do: false

  defp validate_probe_completion(store, request, attrs) do
    with :ok <- validate_probe_request(store, request),
         {:ok, workspace} <- checkout(store, request),
         true <-
           (request["verified_cwd"] == workspace.path and request["verified_head_sha"] == workspace.sha) or
             {:error, :maintenance_checkout_binding_changed},
         true <- observed_artifact_call?(attrs) or {:error, :artifact_tool_observation_missing},
         {:ok, expected} <- receipt(request, attrs["artifact_output"]),
         true <- attrs["output"]["result"] == expected or {:error, :maintenance_receipt_mismatch} do
      :ok
    end
  end

  defp observed_artifact_call?(attrs) do
    calls = attrs["output"]["completed_tool_calls"]
    if Enum.all?(calls, &is_map/1), do: matching_artifact_call?(calls, attrs["artifact_output"]), else: false
  end

  defp matching_artifact_call?(calls, artifact_output) do
    case Enum.filter(calls, &(&1["tool"] == "mcp__codex_app__list_artifacts")) do
      [%{"status" => "completed", "output" => output} = call] ->
        call["isError"] != true and is_nil(call["error"]) and output == artifact_output

      _other ->
        false
    end
  end

  defp artifact_matches?(artifact, request) do
    payload = artifact["payload"]
    metadata = Jason.decode!(request["metadata_json"])

    is_map(payload) and present?(artifact["id"]) and artifact["identityKey"] == request["cwd"] and
      payload["root"] == request["cwd"] and payload["workspaceRoot"] == request["cwd"] and
      payload["sourceCwd"] == metadata["repo_path"]
  end

  defp probe_schema?(request), do: Jason.decode(request["schema_json"] || "{}") == {:ok, StageSchemas.for_stage(:native_worktree_probe)}

  defp disposition([], []), do: {"UNAVAILABLE", nil, "No active managed worktree attachment was observed."}
  defp disposition([artifact], [artifact]), do: {"SUPPORTED", artifact, "One exact active managed worktree attachment was observed."}
  defp disposition(_active, _matching), do: {"AMBIGUOUS", nil, "Active managed worktree attachments do not uniquely match the bound checkout."}
  defp present?(value), do: is_binary(value) and value != ""
end
