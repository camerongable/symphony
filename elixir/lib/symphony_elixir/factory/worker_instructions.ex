defmodule SymphonyElixir.Factory.WorkerInstructions do
  @moduledoc "Pins complete shared role instructions at the native packet boundary."

  alias SymphonyElixir.Factory.{Store, TaskLedger}

  @common ~w(AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc)
  @writer ~w(skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md)
  @roles %{
    "feature-planner" => ~w(skills/plan-feature/SKILL.md skills/onboard-service/SKILL.md),
    "feature-writer" => @writer,
    "ci-repair-writer" => @writer ++ ~w(skills/fix-mr-pipeline/SKILL.md),
    "change-verifier" => ~w(skills/verify-feature-delivery/SKILL.md skills/verify-feature-delivery/references/verdict-contract.md skills/review-code/references/review-criteria.md),
    "manual-validator" => ~w(skills/review-code/references/review-criteria.md)
  }
  @max_file_bytes 65_536
  @max_bundle_bytes 262_144

  @spec load(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load(root \\ Path.join(System.user_home!(), ".agents")), do: load(root, "feature-writer")

  @spec load(Path.t(), String.t() | :ordinary | :ci_repair) :: {:ok, [map()]} | {:error, term()}
  def load(root, :ordinary), do: load(root, "feature-writer")
  def load(root, :ci_repair), do: load(root, "ci-repair-writer")

  def load(root, role) when is_map_key(@roles, role) do
    case File.ls(Path.join(root, "rules")) do
      {:ok, rules} ->
        paths = @common ++ Map.fetch!(@roles, role) ++ Enum.map(Enum.filter(rules, &String.ends_with?(&1, [".mdc", ".md"])), &Path.join("rules", &1))
        collect_instructions(root, paths)

      _ ->
        {:error, :worker_instruction_rules_unavailable}
    end
  end

  defp collect_instructions(root, paths) do
    Enum.reduce_while(Enum.sort(Enum.uniq(paths)), {:ok, []}, fn relative, {:ok, instructions} ->
      case read_instruction(root, relative) do
        {:ok, instruction} -> {:cont, {:ok, instructions ++ [instruction]}}
        error -> {:halt, error}
      end
    end)
    |> bounded_bundle()
  end

  defp read_instruction(root, relative) do
    path = Path.join(root, relative)

    case File.read(path) do
      {:ok, content} when byte_size(content) in 1..@max_file_bytes ->
        if String.valid?(content),
          do: {:ok, %{"path" => path, "relative_path" => relative, "content" => content, "sha256" => digest(content)}},
          else: {:error, {:worker_instruction_invalid, relative}}

      _ ->
        {:error, {:worker_instruction_unavailable, relative}}
    end
  end

  @spec admit(Store.connection(), map(), String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def admit(store, binding, role, root) do
    Store.transaction!(store, &admit_snapshot(&1, binding, role, root))
  end

  defp admit_snapshot(store, binding, role, root) do
    case read(store, binding, role) do
      {:error, :worker_instruction_snapshot_missing} -> create_snapshot(store, binding, role, root)
      result -> result
    end
  end

  defp create_snapshot(store, binding, role, root) do
    with :ok <- unissued_admission(store, binding),
         {:ok, instructions} <- load(root, role) do
      persist_snapshot(store, binding, role, Jason.encode!(%{"shared_instructions" => instructions, "instruction_delivery" => delivery(role)}))
    end
  end

  @doc "Copies prior admitted bytes for a separately validated amendment; does not authorize a worker turn."
  @spec inherit(Store.connection(), map(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def inherit(store, binding, role, prior_task, expected) do
    Store.transaction!(store, fn tx ->
      with {:ok, mapping} <- task_binding(tx, prior_task),
           prior_key = mapping["instruction_binding_sha256"],
           row when is_map(row) <- Store.one!(tx, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256 = ?", [prior_key]),
           true <- digest(row["binding_json"]) == prior_key,
           {:ok, prior_binding} when is_map(prior_binding) <- Jason.decode(row["binding_json"]),
           true <- Map.take(prior_binding, Map.keys(expected)) == expected,
           true <- row["run_id"] == binding["run_id"] and row["role"] == role,
           {:ok, _} <- validate_snapshot(row, row["binding_json"], role) do
        persist_snapshot(tx, binding, role, row["bundle_json"])
      else
        _ -> {:error, :worker_instruction_inheritance_unproven}
      end
    end)
  end

  @doc "Pins an exact prepared task prompt to its already admitted base packet within the caller's transaction."
  @spec bind_task(Store.connection(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def bind_task(store, task_key, prompt_sha, key) do
    with {:ok, task} <- TaskLedger.get(store, task_key),
         true <- task["prompt_sha256"] == prompt_sha,
         row when is_map(row) <- Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256 = ?", [key]),
         true <- row["run_id"] == task["run_id"],
         true <- digest(row["binding_json"]) == key,
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         true <- binding["role"] == task["role"],
         {:ok, _} <- validate_snapshot(row, row["binding_json"], row["role"]) do
      persist_task_binding(store, task, key)
    else
      _ -> {:error, :worker_instruction_task_binding_unproven}
    end
  end

  @spec task_binding(Store.connection(), map()) :: {:ok, map()} | {:error, term()}
  def task_binding(store, task) do
    expected_run = task["run_id"]
    expected_role = task["role"]

    case Store.one!(store, "SELECT * FROM worker_instruction_task_bindings WHERE task_key = ? AND prompt_sha256 = ?", [task["task_key"], task["prompt_sha256"]]) do
      %{"run_id" => ^expected_run, "role" => ^expected_role} = row -> {:ok, row}
      _ -> {:error, :worker_instruction_task_binding_unproven}
    end
  end

  defp persist_task_binding(store, task, key) do
    case task_binding(store, task) do
      {:ok, %{"instruction_binding_sha256" => ^key}} ->
        :ok

      {:ok, _} ->
        {:error, :worker_instruction_task_binding_changed}

      {:error, _} ->
        Store.query!(store, "INSERT INTO worker_instruction_task_bindings VALUES (?, ?, ?, ?, ?, ?)", [
          task["task_key"],
          task["prompt_sha256"],
          key,
          task["run_id"],
          task["role"],
          DateTime.utc_now() |> DateTime.to_iso8601()
        ])

        :ok
    end
  end

  defp persist_snapshot(store, binding, role, json) do
    binding_json = Jason.encode!(binding)

    Store.query!(store, "INSERT INTO worker_instruction_snapshots(binding_sha256, run_id, role, binding_json, bundle_json, bundle_sha256, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", [
      digest(binding_json),
      binding["run_id"],
      role,
      binding_json,
      json,
      digest(json),
      DateTime.utc_now() |> DateTime.to_iso8601()
    ])

    read(store, binding, role)
  end

  defp unissued_admission(store, binding) do
    active =
      Store.query!(store, "SELECT prompt_sha256, thread_id, turn_id FROM factory_tasks WHERE run_id = ? AND role = ? AND status NOT IN ('CONSUMED', 'FAILED', 'STALE')", [
        binding["run_id"],
        binding["role"]
      ]).rows

    pending =
      Store.one!(
        store,
        """
        SELECT COUNT(*) AS count FROM worker_evidence evidence
        JOIN factory_tasks task ON task.task_key = evidence.task_key
        WHERE evidence.run_id = ? AND task.role = ? AND evidence.status != 'CONSUMED'
          AND CASE WHEN json_valid(evidence.binding_json)
            THEN json_extract(evidence.binding_json, '$.prompt_sha256') = task.prompt_sha256
            ELSE task.status != 'CONSUMED' END
        """,
        [binding["run_id"], binding["role"]]
      )["count"]

    if pending > 0 or Enum.any?(active, fn [sha, thread, turn] -> is_binary(thread) or is_binary(turn) or (is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)) end),
      do: {:error, :worker_instruction_snapshot_not_admitted},
      else: :ok
  end

  @spec read(Store.connection(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(store, binding, role) do
    binding_json = Jason.encode!(binding)

    case Store.one!(store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256 = ?", [digest(binding_json)]) do
      nil -> {:error, :worker_instruction_snapshot_missing}
      row -> validate_snapshot(row, binding_json, role)
    end
  end

  defp validate_snapshot(row, binding_json, role) do
    with true <- row["binding_json"] == binding_json and row["role"] == role,
         true <- digest(row["bundle_json"]) == row["bundle_sha256"],
         {:ok, %{"shared_instructions" => instructions, "instruction_delivery" => adapter} = bundle} <- Jason.decode(row["bundle_json"]),
         true <- is_binary(adapter) and adapter != "" and is_list(instructions),
         {:ok, _} <- bounded_bundle({:ok, instructions}),
         true <- Enum.all?(instructions, &valid_instruction?/1),
         paths = Enum.map(instructions, & &1["relative_path"]),
         true <- length(paths) == length(Enum.uniq(paths)),
         true <- Enum.all?(@common ++ Map.fetch!(@roles, role), &(&1 in paths)) do
      {:ok, Map.merge(bundle, %{"instruction_snapshot_sha256" => row["bundle_sha256"], "instruction_binding_sha256" => digest(binding_json)})}
    else
      _ -> {:error, :worker_instruction_snapshot_invalid}
    end
  rescue
    _ -> {:error, :worker_instruction_snapshot_invalid}
  end

  defp valid_instruction?(%{"path" => path, "relative_path" => relative, "content" => content, "sha256" => sha}) do
    is_binary(path) and is_binary(relative) and is_binary(content) and byte_size(content) in 1..@max_file_bytes and String.valid?(content) and digest(content) == sha
  end

  defp valid_instruction?(_), do: false

  defp delivery(role) do
    common =
      "Read every supplied instruction in full. These complete controller-supplied shared files and their SHA-256 digests are immutable for this admission; do not re-read host skill files. Inspect repository-local instructions using your permitted repository tools. The explicit role, restricted tools, controller-supplied evidence and supplied structured output schema override unavailable or broader skill actions. No connectors, delegation, permission escalation, Git writes, commits, pushes, MR management or Jira writes. Report unavailable checks as NOT_RUN; never fabricate evidence. The controller owns all delivery actions. "

    common <>
      case role do
        "feature-planner" ->
          "Use plan-feature factory mode and proportionate onboard-service context gathering. Return the full plan only in plan_markdown; do not write a state file or source, launch another agent, or reauthorize the confirmed contract."

        "feature-writer" ->
          "Use draft-feature-cycle factory mode and select-tests. Perform one bounded source increment with the supplied repository tools; return declared paths and a controller commit message, never commit yourself. Advisory self-review is not independent verification. When review_protocol is supplied, complete its structured review_report using the admitted schema. Sweep the demonstrated failure family across the confirmed scope, including sibling callers, public entry points and error/fallback paths. Closure claims require code/check evidence for every supplied finding ID; these are proposals for the independent reviewer, not final closure. The report candidate_sha is the exact input checkout SHA, before any controller commit."

        "ci-repair-writer" ->
          "Use one bounded draft-feature-cycle repair with select-tests. fix-mr-pipeline is diagnostic reference only: the controller has already selected and bound the MR/SHA/pipeline/jobs and supplied logs. Diagnose only that evidence; do not discover MRs, call GitLab, retry pipelines, push or enter an MR maintenance loop. Infrastructure, unavailable logs, unrelated failures or changed evidence require BLOCKED, not speculative source edits. If controller_generation_scope supplies an authenticated generated-only BUILD dependency capability, no source or cosmetic edit is required to activate it. If no additional source fix is needed, return a genuine no-edit COMPLETE; the controller executes its bound generation step. Never edit BUILD, request shell privileges, or claim generated outputs yourself. Source repairs remain governed by the original CI writer scope."

        "change-verifier" ->
          "Use verify-feature-delivery mode: reviewer, directly and independently; never invoke controller mode or another reviewer. Source is read-only. Apply the complete shared review criteria and verdict-contract semantics to the exact candidate/base/confirmed contract. The supplied native schema is the transport adapter: verdict becomes status, head_sha becomes candidate_sha; risks, required repairs and manual-plan readiness remain in findings/checks. When review_protocol is supplied, acceptance coverage, prior finding closure and boundary sweeps belong in its structured review_report. Review the whole contract before returning a consolidated finding list. The controller alone enforces its repair budget: fixable code findings remain REPAIR regardless of review count; BLOCK requires a genuine contract, human-decision or environment reason. Legacy packets without review_protocol retain their original verdict rules. Return exactly one schema-conforming JSON object, no extra verdict object or prose. PASS requires every criterion evidenced, exact contract identity, no blocking risks or source changes, and a ready manual-validation plan when required; it does not prove live validation."

        "manual-validator" ->
          "Apply the shared review criteria to evidence quality without repeating code verification. Follow only the confirmed manual-validation plan at the exact candidate SHA through the separately authorized validation transport. Native source-only tools do not authorize deployment or connectors. Preserve synthetic-data, non-production, claim and teardown proofs; missing authority or evidence is BLOCK, never PASS."
      end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp bounded_bundle({:ok, instructions}) do
    if Enum.sum(Enum.map(instructions, &byte_size(&1["content"]))) <= @max_bundle_bytes,
      do: {:ok, instructions},
      else: {:error, :worker_instruction_bundle_too_large}
  end

  defp bounded_bundle(error), do: error
end
