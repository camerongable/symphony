defmodule SymphonyElixir.Factory.TaskLedger do
  @moduledoc """
  Durable identities for the visible Codex tasks belonging to a factory run.

  A run may own several tasks: specification author, critic, planner, writer,
  one or more fresh verifiers, and an optional manual validator. The thread ID
  stored here is the identity the Codex desktop can reopen.
  """

  alias SymphonyElixir.Factory.Store

  @required_fields ~w(
    task_key run_id stage role status model_provider model_class model
    reasoning_effort routing_reason prompt_sha256
  )

  @updatable_fields ~w(
    stage role status thread_id turn_id model_provider model_class model
    reasoning_effort routing_reason codex_project_id codex_section_id workspace workspace_sha
    prompt_sha256 output_json failure_code
  )

  @doc "Identifies the source writer independently of its risk-based model role."
  @spec source_writer?(map()) :: boolean()
  def source_writer?(%{"run_id" => run_id, "task_key" => task_key})
      when is_binary(run_id) and is_binary(task_key),
      do: task_key == run_id <> ":feature-writer"

  def source_writer?(_task), do: false

  @doc "Registers a task before its Codex thread is launched."
  @spec register(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register(connection, attrs, opts \\ []) do
    normalized = stringify_keys(attrs)

    with :ok <- require_fields(normalized, @required_fields) do
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()

      values =
        Enum.map(
          @required_fields,
          &Map.fetch!(normalized, &1)
        ) ++
          [
            Map.get(normalized, "codex_project_id"),
            Map.get(normalized, "codex_section_id"),
            Map.get(normalized, "workspace"),
            Map.get(normalized, "workspace_sha"),
            Map.get(normalized, "thread_id"),
            nil,
            nil,
            nil,
            now,
            now
          ]

      case Exqlite.query(
             connection,
             """
             INSERT INTO factory_tasks(
               task_key, run_id, stage, role, status, model_provider,
               model_class, model, reasoning_effort, routing_reason,
               prompt_sha256, codex_project_id, codex_section_id, workspace, workspace_sha,
               thread_id, turn_id, output_json, failure_code,
               created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             values
           ) do
        {:ok, _result} -> {:ok, get!(connection, normalized["task_key"])}
        {:error, error} -> {:error, {:task_register_failed, error}}
      end
    end
  end

  @doc "Updates runtime identity or terminal output for a task."
  @spec update(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(connection, task_key, attrs, opts \\ []) do
    updates = attrs |> stringify_keys() |> Map.take(@updatable_fields)

    if map_size(updates) == 0 do
      {:error, :no_task_fields}
    else
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()
      updates = Map.put(updates, "updated_at", now)
      columns = @updatable_fields |> Enum.filter(&Map.has_key?(updates, &1)) |> Kernel.++(["updated_at"])
      assignments = Enum.map_join(columns, ", ", &"#{&1} = ?")
      values = Enum.map(columns, &Map.fetch!(updates, &1)) ++ [task_key]

      case get(connection, task_key) do
        {:ok, _task} ->
          Store.query!(
            connection,
            "UPDATE factory_tasks SET #{assignments} WHERE task_key = ?",
            values
          )

          {:ok, get!(connection, task_key)}

        {:error, :unknown_task} ->
          {:error, :unknown_task}
      end
    end
  end

  @doc "Updates a task only while the same prompt and an allowed state still own it."
  @spec update_if_current(Store.connection(), String.t(), String.t(), [String.t()], map()) ::
          {:ok, map()} | {:skipped, map()} | {:error, term()}
  def update_if_current(connection, task_key, prompt_sha256, statuses, attrs)
      when is_binary(prompt_sha256) and is_list(statuses) and statuses != [] do
    updates = attrs |> stringify_keys() |> Map.take(@updatable_fields)

    if map_size(updates) == 0 do
      {:error, :no_task_fields}
    else
      updates = Map.put(updates, "updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
      columns = @updatable_fields |> Enum.filter(&Map.has_key?(updates, &1)) |> Kernel.++(["updated_at"])
      assignments = Enum.map_join(columns, ", ", &"#{&1} = ?")
      placeholders = Enum.map_join(statuses, ", ", fn _ -> "?" end)
      values = Enum.map(columns, &Map.fetch!(updates, &1)) ++ [task_key, prompt_sha256 | statuses]

      result =
        Store.query!(
          connection,
          "UPDATE factory_tasks SET #{assignments} WHERE task_key = ? AND prompt_sha256 = ? AND status IN (#{placeholders}) RETURNING task_key",
          values
        )

      case get(connection, task_key) do
        {:ok, task} when result.num_rows == 1 -> {:ok, task}
        {:ok, task} -> {:skipped, task}
        {:error, :unknown_task} = error -> error
      end
    end
  end

  @doc "Returns a task by stable task key."
  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, :unknown_task}
  def get(connection, task_key) do
    case Store.one!(connection, "SELECT * FROM factory_tasks WHERE task_key = ?", [task_key]) do
      nil -> {:error, :unknown_task}
      task -> {:ok, task}
    end
  end

  @doc "Lists all visible task identities for a run in creation order."
  @spec list_for_run(Store.connection(), String.t()) :: [map()]
  def list_for_run(connection, run_id) do
    result =
      Store.query!(
        connection,
        "SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY created_at ASC, task_key ASC",
        [run_id]
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  @doc "Finds the latest reusable specification-author thread for the same issue and repository route."
  @spec reusable_specification_thread(Store.connection(), String.t(), String.t(), String.t()) ::
          String.t() | nil
  def reusable_specification_thread(connection, issue_key, repo_path, codex_project_id) do
    case Store.one!(
           connection,
           """
           SELECT task.thread_id
           FROM factory_tasks AS task
           JOIN runs AS run ON run.run_id = task.run_id
           WHERE run.issue_key = ?
             AND run.kind = 'SPECIFICATION'
             AND run.repo_path = ?
             AND task.role = 'specification-author'
             AND task.codex_project_id = ?
             AND task.status IN ('COMPLETE', 'CONSUMED', 'FAILED', 'STALE')
             AND task.thread_id IS NOT NULL
           ORDER BY task.updated_at DESC, task.created_at DESC
           LIMIT 1
           """,
           [issue_key, repo_path, codex_project_id]
         ) do
      %{"thread_id" => thread_id} when is_binary(thread_id) and thread_id != "" -> thread_id
      _other -> nil
    end
  end

  @doc "Lists the most recently updated visible task records with a bounded result size."
  @spec list_recent(Store.connection(), pos_integer()) :: [map()]
  def list_recent(connection, limit \\ 100) when is_integer(limit) and limit > 0 do
    result =
      Store.query!(
        connection,
        "SELECT * FROM factory_tasks ORDER BY updated_at DESC, task_key ASC LIMIT ?",
        [limit]
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp get!(connection, task_key) do
    {:ok, task} = get(connection, task_key)
    task
  end

  defp require_fields(attrs, fields) do
    missing = Enum.reject(fields, &present?(Map.get(attrs, &1)))
    if missing == [], do: :ok, else: {:error, {:missing_task_fields, missing}}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
