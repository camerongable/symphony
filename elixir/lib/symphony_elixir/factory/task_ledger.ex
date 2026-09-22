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
    reasoning_effort routing_reason codex_project_id codex_section_id prompt_sha256 output_json failure_code
  )

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
            nil,
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
               prompt_sha256, codex_project_id, codex_section_id, thread_id, turn_id, output_json, failure_code,
               created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
