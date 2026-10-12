defmodule SymphonyElixir.Factory.DesktopStageRunner do
  @moduledoc """
  Runs a factory stage through a durable Codex Desktop request.

  The Desktop broker, not this process, owns native task creation and follow-up.
  An interrupted caller waits on the same request key, so an uncertain external
  call is reconciled before any new task or turn can be issued.
  """

  alias SymphonyElixir.Factory.{DesktopRequest, ModelRouter, NativeSourceBinding, RunLedger}
  alias SymphonyElixir.Factory.{StageSchemas, Store, TaskLedger, Worktree}
  alias SymphonyElixir.Tracker.Issue

  @default_poll_ms 500
  @default_wait_ms 30 * 60 * 1_000

  @bootstrap_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["status"],
    "properties" => %{"status" => %{"type" => "string", "enum" => ["WORKSPACE_READY"]}}
  }

  @type result :: %{thread_id: String.t(), turn_id: String.t(), output: map()}

  @doc "Derives a retry-stable request key from the prior completed turn."
  @spec request_key(String.t(), String.t() | nil, String.t()) :: String.t()
  def request_key(target_key, previous_turn_id, prompt) do
    digest =
      [target_key, previous_turn_id || "FIRST", prompt]
      |> Enum.join("\u0000")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "desktop:" <> digest
  end

  @doc "Reads an existing terminal receipt without enqueueing, waiting or invoking callbacks."
  @spec read_request_result(Store.connection(), String.t(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def read_request_result(store, request_key, schema, opts \\ []) do
    with {:ok, request} <- DesktopRequest.get(store, request_key),
         true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt},
         {:ok, stored_schema} <- Jason.decode(request["schema_json"]),
         true <- stored_schema == schema or {:error, :desktop_result_schema_mismatch},
         {:ok, metadata} when is_map(metadata) <- Jason.decode(request["metadata_json"]),
         required = Map.get(metadata, "required_tool_calls", []),
         supplied = Keyword.get(opts, :required_tool_calls, []),
         true <- (is_list(required) and is_list(supplied)) or {:error, :invalid_required_tool_calls} do
      options = opts |> Keyword.drop([:on_thread_started, :on_thread_created]) |> Keyword.put(:required_tool_calls, required ++ supplied)
      read_result_status(request, schema, options)
    else
      {:error, _} = error -> error
      _ -> {:error, :desktop_result_incomplete}
    end
  end

  defp read_result_status(%{"status" => "SUCCEEDED"} = request, schema, opts), do: verified_result(request, schema, opts, nil)

  defp read_result_status(%{"status" => "FAILED", "failure_code" => reason}, _schema, _opts),
    do: {:error, {:desktop_request_failed, reason}}

  defp read_result_status(request, _schema, _opts),
    do: {:error, {:desktop_request_pending, request["status"], request["request_key"]}}

  @doc "Enqueues and waits for one native task turn with an exact stable request key."
  @spec run(Path.t(), Issue.t(), String.t(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(workspace, %Issue{}, prompt, schema, opts)
      when is_binary(workspace) and is_binary(prompt) and is_map(schema) do
    with {:ok, opts} <- resolve_native_turn(prompt, opts) do
      if native_bootstrap?(opts) do
        run_native_bootstrap(workspace, prompt, schema, opts)
      else
        run_request(workspace, prompt, schema, opts)
      end
    end
  end

  defp resolve_native_turn(prompt, opts) do
    if Keyword.get(opts, :workspace_mode) in ["CODEX_NATIVE", "CODEX_PROJECT_LOCAL"] and
         Keyword.get(opts, :target_kind) == "TASK" do
      resolve_native_task_turn(prompt, opts)
    else
      {:ok, opts}
    end
  end

  defp resolve_native_task_turn(prompt, opts) do
    with {:ok, task} <- TaskLedger.get(Keyword.fetch!(opts, :store), Keyword.fetch!(opts, :target_key)),
         :ok <- require_native_turn_route(task, opts) do
      bind_native_turn(prompt, opts, task)
    end
  end

  defp bind_native_turn(prompt, opts, %{"turn_id" => nil} = task) do
    with {:ok, key} <- retry_key_if_terminal(prompt, opts, task, Keyword.fetch!(opts, :request_key)) do
      {:ok, Keyword.put(opts, :request_key, key)}
    end
  end

  defp bind_native_turn(prompt, opts, task) do
    base_key = request_key(task["task_key"], task["turn_id"], prompt)

    with {:ok, key} <- retry_key_if_terminal(prompt, opts, task, base_key) do
      {:ok,
       opts
       |> Keyword.put(:previous_turn_id, task["turn_id"])
       |> Keyword.put(:resume_thread_id, task["thread_id"])
       |> Keyword.put(:request_key, key)}
    end
  end

  defp retry_key_if_terminal(prompt, opts, %{"role" => "specification-author"} = task, base_key) do
    store = Keyword.fetch!(opts, :store)

    with {:ok, run} <- RunLedger.get(store, task["run_id"]) do
      if run["attempt"] > 1 and terminal_failed_request?(store, base_key) do
        {:ok, request_key(task["task_key"], "retry:#{run["attempt"]}:#{task["turn_id"] || "FIRST"}", prompt)}
      else
        {:ok, base_key}
      end
    end
  end

  defp retry_key_if_terminal(_prompt, _opts, _task, base_key), do: {:ok, base_key}

  defp terminal_failed_request?(store, base_key) do
    Enum.any?([base_key, bootstrap_request_key(base_key)], fn key ->
      match?({:ok, %{"status" => "FAILED", "claimed_at" => nil}}, DesktopRequest.get(store, key))
    end)
  end

  defp require_native_turn_route(task, opts) do
    supplied_turn = Keyword.get(opts, :previous_turn_id)
    supplied_thread = Keyword.get(opts, :resume_thread_id)

    cond do
      present?(supplied_turn) and supplied_turn != task["turn_id"] ->
        {:error, :native_turn_route_mismatch}

      present?(supplied_thread) and supplied_thread != task["thread_id"] ->
        {:error, :native_thread_route_mismatch}

      present?(task["turn_id"]) and not present?(task["thread_id"]) ->
        {:error, :native_thread_route_missing}

      true ->
        :ok
    end
  end

  defp native_bootstrap?(opts) do
    Keyword.get(opts, :workspace_mode) == "CODEX_NATIVE" and is_nil(Keyword.get(opts, :previous_turn_id))
  end

  defp run_native_bootstrap(workspace, prompt, schema, opts) do
    store = Keyword.fetch!(opts, :store)
    target_key = Keyword.fetch!(opts, :target_key)
    bootstrap_key = bootstrap_request_key(Keyword.fetch!(opts, :request_key))

    with {:ok, bootstrap_key} <- ensure_bootstrap(store, workspace, bootstrap_key, opts),
         {:ok, result} <-
           await(
             store,
             bootstrap_key,
             @bootstrap_schema,
             Keyword.put(opts, :required_tool_calls, []),
             System.monotonic_time(:millisecond),
             nil
           ),
         {:ok, request} <- DesktopRequest.get(store, bootstrap_key),
         {:ok, task} <- TaskLedger.get(store, target_key),
         :ok <- require_bootstrap_binding(request, task, result),
         :ok <- require_no_prior_stage_request(store, target_key, Keyword.fetch!(opts, :request_key)),
         :ok <- prepare_native_writer(store, task, request),
         followup_opts <-
           opts
           |> Keyword.put(:resume_thread_id, result.thread_id)
           |> Keyword.put(:previous_turn_id, result.turn_id) do
      run_request(request["verified_cwd"], prompt, schema, followup_opts)
    else
      {:error, _reason} = error -> error
    end
  end

  defp ensure_bootstrap(store, workspace, bootstrap_key, opts) do
    case DesktopRequest.get(store, bootstrap_key) do
      {:ok, request} ->
        with :ok <- require_reusable_bootstrap(store, request, opts) do
          {:ok, bootstrap_key}
        end

      {:error, :unknown_request} ->
        reuse_or_enqueue_bootstrap(store, workspace, bootstrap_key, opts)
    end
  end

  defp reuse_or_enqueue_bootstrap(store, workspace, bootstrap_key, opts) do
    target_key = Keyword.fetch!(opts, :target_key)

    case Store.query!(
           store,
           "SELECT request_key FROM desktop_requests WHERE target_kind = ? AND target_key = ? AND action = 'CREATE' AND NOT (status = 'FAILED' AND claimed_at IS NULL) LIMIT 2",
           [Keyword.fetch!(opts, :target_kind), target_key]
         ).rows do
      [] ->
        enqueue_bootstrap(store, workspace, bootstrap_key, opts)

      [[existing_key]] ->
        with {:ok, request} <- DesktopRequest.get(store, existing_key),
             :ok <- require_reusable_bootstrap(store, request, opts) do
          {:ok, existing_key}
        end

      _multiple ->
        {:error, :native_bootstrap_ambiguous}
    end
  end

  defp require_reusable_bootstrap(store, request, opts) do
    with true <- DesktopRequest.payload_intact?(request) or {:error, :request_payload_corrupt},
         {:ok, metadata} <- Jason.decode(request["metadata_json"]),
         {:ok, task} <- TaskLedger.get(store, Keyword.fetch!(opts, :target_key)),
         {:ok, run} <- RunLedger.get(store, task["run_id"]),
         :ok <- require_bootstrap_route(store, request, run, task, opts),
         :ok <- require_bootstrap_metadata(metadata, opts) do
      require_bootstrap_claim_state(request, task)
    end
  end

  defp require_bootstrap_route(store, request, run, task, opts) do
    expected = bootstrap_route_fields(request, opts)

    route_matches =
      present?(run["repo_path"]) and
        String.ends_with?(request["request_key"], ":bootstrap") and
        request["cwd"] == Path.expand(run["repo_path"]) and
        Map.take(request, Map.keys(expected)) == expected

    branch_matches = request["branch"] == Keyword.get(opts, :branch)

    cond do
      not route_matches ->
        {:error, {:native_bootstrap_route_mismatch, route_mismatches(request, expected, run, opts)}}

      branch_matches ->
        :ok

      recovered_writer_branch?(store, request, run, task, opts) ->
        :ok

      true ->
        {:error, {:native_bootstrap_route_mismatch, [:branch_recovery_binding]}}
    end
  end

  defp bootstrap_route_fields(request, opts) do
    allocation =
      if NativeSourceBinding.bootstrap?(request),
        do: Jason.decode!(request["metadata_json"])["bootstrap_model_route"],
        else: %{"model" => Keyword.fetch!(opts, :model), "reasoning_effort" => Keyword.fetch!(opts, :reasoning_effort)}

    Map.merge(Map.take(allocation, ~w(model reasoning_effort)), %{
      "action" => "CREATE",
      "codex_project_id" => Keyword.fetch!(opts, :project_id),
      "base_branch" => Keyword.get(opts, :base_branch)
    })
  end

  defp route_mismatches(request, expected, run, opts) do
    request_mismatches =
      Enum.reject(Map.keys(expected), &(Map.get(request, &1) == Map.get(expected, &1)))

    run_mismatches =
      if present?(run["repo_path"]) and request["cwd"] == Path.expand(run["repo_path"]),
        do: [],
        else: [:cwd]

    branch_mismatches =
      if request["branch"] == Keyword.get(opts, :branch), do: [], else: [:branch]

    request_mismatches ++ run_mismatches ++ branch_mismatches
  end

  defp recovered_writer_branch?(store, request, run, task, opts) do
    with true <- request["status"] == "SUCCEEDED",
         true <- run["state"] == "WRITING",
         true <- task["status"] in ["RETRY_PENDING", "STARTING"] and is_nil(task["turn_id"]),
         true <- TaskLedger.source_writer?(task),
         true <- task["run_id"] == run["run_id"],
         true <- task["codex_project_id"] == Keyword.get(opts, :project_id),
         true <- task["model"] == Keyword.get(opts, :model),
         true <- task["reasoning_effort"] == Keyword.get(opts, :reasoning_effort),
         true <- run["base_branch"] == Keyword.get(opts, :base_branch),
         true <- request["thread_id"] == task["thread_id"],
         true <- request["verified_cwd"] == task["workspace"],
         true <- request["verified_head_sha"] == task["workspace_sha"],
         true <- branch_recovery_binding?(store, request, run, task, opts) do
      true
    else
      _other -> false
    end
  end

  defp branch_recovery_binding?(store, request, run, task, opts) do
    branch_mismatch_recovery_binding?(store, request, run, task, opts) or
      bootstrap_recovery_binding?(store, request, run, task, opts)
  end

  defp branch_mismatch_recovery_binding?(store, request, run, task, opts) do
    recovery =
      Store.one!(
        store,
        "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'NATIVE_BRANCH_MISMATCH_RECOVERED' ORDER BY occurred_at DESC, rowid DESC LIMIT 1",
        [run["run_id"]]
      )

    with %{"payload_json" => payload_json} <- recovery,
         {:ok, details} when is_map(details) <- Jason.decode(payload_json),
         true <- details["run_id"] == run["run_id"],
         true <- details["task_key"] == task["task_key"],
         true <- details["previous_branch"] == request["branch"],
         true <- details["reused_thread_id"] == task["thread_id"],
         true <- details["new_branch"] == run["branch"],
         true <- details["new_branch"] == Keyword.get(opts, :branch),
         true <- is_binary(details["previous_branch"]) do
      true
    else
      _other -> false
    end
  end

  defp bootstrap_recovery_binding?(store, request, run, task, opts) do
    recovery =
      Store.one!(
        store,
        "SELECT payload_json FROM events WHERE run_id = ? AND event_type = 'NATIVE_BOOTSTRAP_RECOVERED' ORDER BY occurred_at DESC, rowid DESC LIMIT 1",
        [run["run_id"]]
      )

    with %{"payload_json" => payload_json} <- recovery,
         {:ok, details} when is_map(details) <- Jason.decode(payload_json),
         true <- details["request_key"] == request["request_key"],
         true <- details["completed_turn_id"] == request["turn_id"],
         true <- details["task_key"] == task["task_key"],
         true <- details["branch"] == run["branch"],
         true <- details["branch"] == Keyword.get(opts, :branch),
         true <- request["branch"] != details["branch"],
         true <- details["workspace_sha"] == request["verified_head_sha"],
         true <- details["workspace_sha"] == task["workspace_sha"] do
      true
    else
      _other -> false
    end
  end

  defp require_bootstrap_metadata(metadata, opts) do
    expected = %{
      "workspace_mode" => "CODEX_NATIVE",
      "expected_sha" => Keyword.get(opts, :expected_sha),
      "issue_key" => Keyword.fetch!(opts, :issue_key)
    }

    if Map.take(metadata, Map.keys(expected)) == expected,
      do: :ok,
      else: {:error, :native_bootstrap_route_mismatch}
  end

  defp require_bootstrap_claim_state(%{"status" => "PENDING"}, %{"thread_id" => thread_id}) do
    if present?(thread_id), do: {:error, :native_bootstrap_route_mismatch}, else: :ok
  end

  defp require_bootstrap_claim_state(_request, _task), do: :ok

  defp require_no_prior_stage_request(store, target_key, request_key) do
    case Store.query!(
           store,
           "SELECT request_key FROM desktop_requests WHERE target_kind = 'TASK' AND target_key = ? AND action = 'FOLLOWUP' AND NOT (status = 'FAILED' AND claimed_at IS NULL) AND request_key != ? LIMIT 1",
           [target_key, request_key]
         ).rows do
      [] -> :ok
      _existing -> {:error, :native_stage_already_submitted}
    end
  end

  defp enqueue_bootstrap(store, workspace, bootstrap_key, opts) do
    if present?(Keyword.get(opts, :resume_thread_id)) do
      {:error, :native_bootstrap_missing_for_existing_thread}
    else
      enqueue_bootstrap_request(store, workspace, bootstrap_key, opts)
    end
  end

  defp enqueue_bootstrap_request(store, workspace, bootstrap_key, opts) do
    with {:ok, opts} <- bootstrap_options(store, opts) do
      enqueue_bootstrap_with_route(store, workspace, bootstrap_key, opts)
    end
  end

  defp bootstrap_options(store, opts) do
    with {:ok, task} <- TaskLedger.get(store, Keyword.fetch!(opts, :target_key)) do
      if Keyword.get(opts, :native_source_attachment_enabled, false) and TaskLedger.source_writer?(task) do
        attachment_bootstrap_options(opts)
      else
        {:ok, opts}
      end
    end
  end

  defp attachment_bootstrap_options(opts) do
    with {:ok, route} <- ModelRouter.resolve(Keyword.fetch!(opts, :model_policy), "workspace-maintainer"),
         true <-
           (route.model_class == "fast" and route.reasoning_effort == "low") or
             {:error, :native_source_requires_fast_low_route} do
      {:ok,
       opts |> Keyword.put(:native_source_bootstrap, true) |> Keyword.put(:bootstrap_model_route, route) |> Keyword.put(:model, route.model) |> Keyword.put(:reasoning_effort, route.reasoning_effort)}
    end
  end

  defp enqueue_bootstrap_with_route(store, workspace, bootstrap_key, opts) do
    prompt = """
    Factory workspace bootstrap ID: #{bootstrap_key}

    This is a read-only checkout verification turn. Check the checkout path with
    `pwd` and the current commit with `git rev-parse HEAD`. Do not run `git status`
    or Git LFS commands: they may write to protected shared Git metadata. The
    broker independently verifies cleanliness and the pinned commit. Do not edit
    files, commit, create a branch, contact Jira or GitLab, or begin ticket work.
    Report only {\"status\":\"WORKSPACE_READY\"} after checking the checkout.
    """

    prompt = if Keyword.get(opts, :native_source_bootstrap), do: attachment_bootstrap_prompt(bootstrap_key, opts), else: prompt
    attrs = request_attrs(workspace, prompt, @bootstrap_schema, opts, bootstrap_key, nil)

    case DesktopRequest.enqueue(store, attrs) do
      {:ok, _request} -> {:ok, bootstrap_key}
      {:error, _reason} = error -> error
    end
  end

  defp attachment_bootstrap_prompt(key, opts) do
    """
    Factory workspace bootstrap ID: #{key}
    This is mechanical source-workspace setup, not feature implementation.
    The initial native checkout is the CONTROL context. Read its absolute pwd and HEAD.
    Keep the primary repository and CONTROL checkout unchanged. Call the supported
    create_worktree tool ONCE in this chat with allowAsync:true and
    ref:#{Keyword.fetch!(opts, :expected_sha)}. Reconcile a queued/uncertain result
    by readback; never create another worktree. Call list_artifacts and retain its
    exact returned object. Require one matching active managed source attachment
    whose payload.sourceCwd is CONTROL. Do not manufacture attachment identity.
    Run this read-only emitter with explicit workdir set to the new SOURCE root:
    python3 -B #{NativeSourceBinding.emitter_path()} #{key} --payload-base64 BASE64_JSON
    Encode {"control_cwd":CONTROL,"artifact_output":RAW_LIST_ARTIFACTS_OBJECT}.
    It emits actual source cwd/HEAD with target-attested attachment evidence.
    Do not begin ticket work, commit, push, create branches, archive, restore, or
    thin the CONTROL checkout. No permission escalation or approval request.
    If setup cannot be proven, report the exact failure without replacing the chat.
    Otherwise report only {"status":"WORKSPACE_READY"}.
    """
  end

  defp require_bootstrap_binding(request, task, result) do
    if request["verified_cwd"] == task["workspace"] and
         request["verified_head_sha"] == task["workspace_sha"] and
         request["thread_id"] == task["thread_id"] and
         request["thread_id"] == result.thread_id and present?(request["verified_cwd"]) do
      :ok
    else
      {:error, :native_bootstrap_binding_mismatch}
    end
  end

  defp prepare_native_writer(store, task, request) do
    if TaskLedger.source_writer?(task) do
      with {:ok, run} <- RunLedger.get(store, task["run_id"]),
           :ok <- require_writer_route(run),
           {:ok, _workspace} <-
             Worktree.attach_native_branch(
               %{"path" => run["repo_path"]},
               request["verified_cwd"],
               run["branch"],
               request["verified_head_sha"]
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp require_writer_route(%{"repo_path" => repo, "branch" => branch}) do
    if present?(repo) and present?(branch), do: :ok, else: {:error, :native_writer_route_missing}
  end

  defp require_writer_route(_run), do: {:error, :native_writer_route_missing}

  defp bootstrap_request_key(request_key), do: request_key <> ":bootstrap"

  defp run_request(workspace, prompt, schema, opts) do
    store = Keyword.fetch!(opts, :store)
    request_key = Keyword.fetch!(opts, :request_key)
    thread_id = Keyword.get(opts, :resume_thread_id)
    attrs = request_attrs(workspace, prompt, schema, opts, request_key, thread_id)

    with {:ok, _request} <- DesktopRequest.enqueue(store, attrs) do
      await(store, request_key, schema, opts, System.monotonic_time(:millisecond), nil)
    end
  end

  @doc "Builds the normal Desktop payload without enqueueing or issuing a turn."
  @spec request_attrs(Path.t(), String.t(), map(), keyword(), String.t(), String.t() | nil) :: map()
  def request_attrs(workspace, prompt, schema, opts, request_key, thread_id) do
    binding = if present?(thread_id), do: NativeSourceBinding.get(Keyword.fetch!(opts, :store), Keyword.fetch!(opts, :target_key))
    stage_prompt_digest = :sha256 |> :crypto.hash(prompt) |> Base.encode16(case: :lower)
    prompt = source_bound_prompt(prompt, binding)

    attrs = %{
      request_key: request_key,
      target_kind: Keyword.fetch!(opts, :target_kind),
      target_key: Keyword.fetch!(opts, :target_key),
      action: if(present?(thread_id), do: "FOLLOWUP", else: "CREATE"),
      codex_project_id: Keyword.fetch!(opts, :project_id),
      model: Keyword.fetch!(opts, :model),
      reasoning_effort: Keyword.fetch!(opts, :reasoning_effort),
      title: Keyword.fetch!(opts, :thread_name),
      prompt: "Factory request ID: #{request_key}\n\n" <> prompt,
      cwd: Path.expand(workspace),
      existing_thread_id: thread_id,
      schema: schema,
      branch: Keyword.get(opts, :branch),
      base_branch: Keyword.get(opts, :base_branch),
      metadata: %{
        "issue_key" => Keyword.fetch!(opts, :issue_key),
        "display_title" => Keyword.fetch!(opts, :thread_name),
        "workspace_mode" => Keyword.get(opts, :workspace_mode),
        "stage_prompt_sha256" => stage_prompt_digest,
        "expected_sha" => Keyword.get(opts, :expected_sha),
        "previous_turn_id" => Keyword.get(opts, :previous_turn_id),
        "format_repair_attempts" => Keyword.get(opts, :format_repair_attempts, 0),
        "required_tool_calls" =>
          if(request_key == bootstrap_request_key(Keyword.fetch!(opts, :request_key)),
            do: [],
            else: Keyword.get(opts, :required_tool_calls, [])
          ),
        "required_apps" => Keyword.get(opts, :required_apps, []),
        "required_mcp_servers" => Keyword.get(opts, :required_mcp_servers, []),
        "approval_policy" => Keyword.get(opts, :approval_policy),
        "allowed_mcp_tool_approvals" => Keyword.get(opts, :allowed_mcp_tool_approvals, [])
      }
    }

    metadata =
      if Keyword.get(opts, :native_source_bootstrap) do
        Map.merge(attrs.metadata, %{
          "native_source_bootstrap" => true,
          "bootstrap_model_route" => Keyword.fetch!(opts, :bootstrap_model_route),
          "source_emitter_sha256" => NativeSourceBinding.emitter_sha256()
        })
      else
        attrs.metadata
      end

    metadata = if binding, do: Map.put(metadata, "control_workspace", binding["control_workspace"]), else: metadata
    metadata = if Keyword.has_key?(opts, :delivery_operation), do: Map.put(metadata, "delivery_operation", opts[:delivery_operation]), else: metadata
    %{attrs | metadata: metadata}
  end

  defp source_bound_prompt(prompt, nil), do: prompt

  defp source_bound_prompt(prompt, binding) do
    prompt <>
      "\n\nWorkspace boundary: SOURCE is #{binding["source_workspace"]}; " <>
      "CONTROL is #{binding["control_workspace"]}. All source commands must explicitly use SOURCE workdir; " <>
      "all file edits must use absolute SOURCE paths. Never edit CONTROL or the primary checkout. " <>
      "Do not create another worktree, escalate permissions, or archive this chat."
  end

  defp await(store, request_key, schema, opts, started_at, reported_thread_id) do
    case DesktopRequest.get(store, request_key) do
      {:ok, %{"status" => "SUCCEEDED"} = request} ->
        verified_result(request, schema, opts, reported_thread_id)

      {:ok, %{"status" => "FAILED", "failure_code" => reason}} ->
        {:error, {:desktop_request_failed, reason}}

      {:ok, %{"status" => "RECONCILE_REQUIRED"} = request} ->
        {:error, {:desktop_request_reconciliation_required, request["failure_code"]}}

      {:ok, request} ->
        reported_thread_id = maybe_report_thread(request, opts, reported_thread_id)

        elapsed = System.monotonic_time(:millisecond) - started_at

        if elapsed >= Keyword.get(opts, :wait_timeout_ms, @default_wait_ms) do
          {:error, {:desktop_request_pending, request["status"], request_key}}
        else
          Process.sleep(Keyword.get(opts, :poll_ms, @default_poll_ms))
          await(store, request_key, schema, opts, started_at, reported_thread_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verified_result(%{"output_json" => raw} = request, schema, opts, reported_thread_id) when is_binary(raw) do
    with {:ok, %{"result" => output, "completed_tool_calls" => calls}} <-
           Jason.decode(raw),
         true <- is_map(output) and is_list(calls),
         :ok <- StageSchemas.validate(output, schema),
         :ok <- verify_tool_calls(Keyword.get(opts, :required_tool_calls, []), calls),
         true <- present?(request["thread_id"]) and present?(request["turn_id"]) do
      maybe_report_thread(request, opts, reported_thread_id)
      {:ok, %{thread_id: request["thread_id"], turn_id: request["turn_id"], output: output}}
    else
      false -> {:error, :desktop_result_incomplete}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :desktop_result_incomplete}
    end
  end

  defp verified_result(_request, _schema, _opts, _reported_thread_id), do: {:error, :desktop_result_incomplete}

  defp verify_tool_calls(required, calls) do
    missing =
      Enum.reject(required, fn required_call ->
        Enum.any?(calls, fn actual ->
          same?(field(actual, :tool), field(required_call, :tool)) and
            (is_nil(field(required_call, :server)) or
               same?(field(actual, :server), field(required_call, :server))) and
            field(actual, :status) == "completed" and field(actual, :isError) != true and
            is_nil(field(actual, :error))
        end)
      end)

    if missing == [], do: :ok, else: {:error, {:required_tool_calls_missing, missing}}
  end

  defp maybe_report_thread(%{"thread_id" => thread_id}, opts, reported_thread_id)
       when is_binary(thread_id) and thread_id != reported_thread_id do
    callback = Keyword.get(opts, :on_thread_started, Keyword.get(opts, :on_thread_created))
    if is_function(callback, 1), do: callback.(thread_id)
    thread_id
  end

  defp maybe_report_thread(_request, _opts, reported_thread_id), do: reported_thread_id

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_value, _key), do: nil
  defp same?(left, right) when is_binary(left) and is_binary(right), do: String.downcase(left) == String.downcase(right)
  defp same?(_left, _right), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
