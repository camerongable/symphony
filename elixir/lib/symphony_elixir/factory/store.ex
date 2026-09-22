defmodule SymphonyElixir.Factory.Store do
  @moduledoc """
  Durable SQLite storage for factory coordination state.

  The schema intentionally remains compatible with the original Python
  `factoryctl.py` database so the Elixir runtime can take over without losing
  leases, run ownership, or model-route history.
  """

  alias Exqlite.Result

  @schema_statements [
    """
    CREATE TABLE IF NOT EXISTS factory_schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS control (
      scope TEXT PRIMARY KEY,
      status TEXT NOT NULL CHECK(status IN ('ACTIVE', 'PAUSED')),
      dispatcher_id TEXT NOT NULL,
      generation INTEGER NOT NULL DEFAULT 0,
      tick_id TEXT,
      lease_expires_at TEXT,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS runs (
      run_id TEXT PRIMARY KEY,
      issue_key TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('SPECIFICATION', 'DELIVERY', 'VALIDATION')),
      state TEXT NOT NULL,
      dispatcher_id TEXT,
      spec_revision INTEGER,
      contract_sha256 TEXT,
      repo_key TEXT,
      repo_path TEXT,
      base_branch TEXT,
      worktree TEXT,
      branch TEXT,
      candidate_sha TEXT,
      candidate_handoff TEXT,
      attempt INTEGER NOT NULL DEFAULT 1,
      validation_attempt INTEGER NOT NULL DEFAULT 0,
      slack_claim_ts TEXT,
      last_input_marker TEXT,
      task_id TEXT,
      mr_url TEXT,
      jira_status TEXT,
      mr_state TEXT,
      factory_owned INTEGER NOT NULL DEFAULT 1 CHECK(factory_owned IN (0, 1)),
      cleanup_authorized INTEGER NOT NULL DEFAULT 0 CHECK(cleanup_authorized IN (0, 1)),
      cleanup_authorized_at TEXT,
      cleaned_at TEXT,
      failure_code TEXT,
      runtime TEXT,
      model_role TEXT,
      model_provider TEXT,
      model_class TEXT,
      model TEXT,
      reasoning_effort TEXT,
      model_routing_reason TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS one_active_run_per_issue_kind
    ON runs(issue_key, kind)
    WHERE state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'CANCELLED', 'FAILED')
    """,
    """
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      occurred_at TEXT NOT NULL,
      event_type TEXT NOT NULL,
      run_id TEXT,
      payload_json TEXT NOT NULL,
      FOREIGN KEY(run_id) REFERENCES runs(run_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS model_routes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      occurred_at TEXT NOT NULL,
      run_id TEXT NOT NULL,
      task_id TEXT,
      usage_context TEXT NOT NULL,
      requested_role TEXT NOT NULL,
      resolved_role TEXT NOT NULL,
      provider TEXT NOT NULL,
      model_class TEXT NOT NULL,
      model TEXT NOT NULL,
      reasoning_effort TEXT NOT NULL,
      routing_reason TEXT NOT NULL,
      FOREIGN KEY(run_id) REFERENCES runs(run_id)
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS model_routes_by_run
    ON model_routes(run_id, occurred_at)
    """
  ]

  @model_run_columns %{
    "runtime" => "TEXT",
    "model_role" => "TEXT",
    "model_provider" => "TEXT",
    "model_class" => "TEXT",
    "model" => "TEXT",
    "reasoning_effort" => "TEXT",
    "model_routing_reason" => "TEXT"
  }

  @type connection :: DBConnection.conn()

  @doc """
  Starts a SQLite connection and initializes the compatible factory schema.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    database = Keyword.fetch!(opts, :database)
    ensure_database_parent(database)

    connection_opts = [
      database: database,
      busy_timeout: Keyword.get(opts, :busy_timeout, 30_000),
      default_transaction_mode: :immediate,
      foreign_keys: :on,
      journal_mode: journal_mode(database)
    ]

    connection_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> Keyword.put(connection_opts, :name, name)
        :error -> connection_opts
      end

    with {:ok, connection} <- Exqlite.start_link(connection_opts),
         :ok <- initialize(connection) do
      {:ok, connection}
    end
  end

  @doc """
  Returns a child specification suitable for a supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :name, __MODULE__)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Applies all idempotent schema statements.
  """
  @spec initialize(connection()) :: :ok
  def initialize(connection) do
    Enum.each(@schema_statements, &query!(connection, &1))
    ensure_columns(connection, "runs", @model_run_columns)

    query!(
      connection,
      "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (1, ?), (2, ?)",
      [iso_now(), iso_now()]
    )

    :ok
  end

  @doc """
  Executes a SQL statement and returns its result.
  """
  @spec query!(connection(), iodata(), list()) :: Result.t()
  def query!(connection, statement, params \\ []) do
    Exqlite.query!(connection, statement, params)
  end

  @doc """
  Executes a query expected to return at most one row as a string-keyed map.
  """
  @spec one!(connection(), iodata(), list()) :: map() | nil
  def one!(connection, statement, params \\ []) do
    case query!(connection, statement, params) do
      %Result{columns: columns, rows: [row]} -> Map.new(Enum.zip(columns, row))
      %Result{rows: []} -> nil
    end
  end

  @doc """
  Runs a function inside an immediate SQLite transaction.
  """
  @spec transaction!(connection(), (DBConnection.t() -> result)) :: result when result: var
  def transaction!(connection, fun) do
    case Exqlite.transaction(connection, fun) do
      {:ok, result} -> result
      {:error, reason} -> raise "factory SQLite transaction failed: #{inspect(reason)}"
    end
  end

  defp ensure_database_parent(database) when database in [":memory:", :memory], do: :ok

  defp ensure_database_parent(database) do
    database
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  defp journal_mode(database) when database in [":memory:", :memory], do: :memory
  defp journal_mode(_database), do: :wal

  defp ensure_columns(connection, table, columns) do
    existing =
      connection
      |> query!("PRAGMA table_info(#{table})")
      |> Map.fetch!(:rows)
      |> Enum.map(fn [_cid, name | _rest] -> name end)
      |> MapSet.new()

    Enum.each(columns, fn {name, definition} ->
      unless MapSet.member?(existing, name) do
        query!(connection, "ALTER TABLE #{table} ADD COLUMN #{name} #{definition}")
      end
    end)
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
