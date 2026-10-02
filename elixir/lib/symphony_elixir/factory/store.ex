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
    CREATE TABLE IF NOT EXISTS native_source_bindings (
      run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
      task_key TEXT NOT NULL UNIQUE REFERENCES factory_tasks(task_key),
      thread_id TEXT NOT NULL UNIQUE,
      codex_project_id TEXT NOT NULL,
      control_workspace TEXT NOT NULL UNIQUE,
      source_workspace TEXT NOT NULL UNIQUE,
      attachment_identity TEXT NOT NULL UNIQUE,
      bootstrap_sha TEXT NOT NULL,
      bootstrap_request_key TEXT NOT NULL UNIQUE,
      bootstrap_turn_id TEXT NOT NULL,
      evidence_json TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS native_workspace_maintenance (
      run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
      generation INTEGER NOT NULL DEFAULT 0,
      phase TEXT NOT NULL DEFAULT 'AVAILABLE' CHECK(phase IN (
        'AVAILABLE', 'PROBING', 'ARCHIVE_PENDING', 'ARCHIVED', 'RESTORE_PENDING', 'RECONCILE_REQUIRED'
      )),
      binding_json TEXT NOT NULL,
      binding_sha256 TEXT NOT NULL,
      request_key TEXT,
      attachment_identity TEXT,
      authorization_json TEXT,
      authorization_at TEXT,
      cache_receipt_json TEXT,
      last_error TEXT,
      checked_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS one_native_workspace_maintenance
      ON native_workspace_maintenance((1))
      WHERE phase IN ('PROBING', 'ARCHIVE_PENDING', 'RESTORE_PENDING', 'RECONCILE_REQUIRED')
    """,
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
      controller_thread_id TEXT,
      controller_turn_id TEXT,
      controller_codex_project_id TEXT,
      controller_codex_section_id TEXT,
      controller_model_role TEXT,
      controller_model_provider TEXT,
      controller_model_class TEXT,
      controller_model TEXT,
      controller_reasoning_effort TEXT,
      controller_routing_reason TEXT,
      controller_writer_conflict_since TEXT,
      controller_writer_conflict_count INTEGER NOT NULL DEFAULT 0,
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
      ci_preflight_sha TEXT,
      ci_pipeline_id INTEGER,
      ci_pipeline_url TEXT,
      ci_evidence_json TEXT,
      ci_last_checked_at TEXT,
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
      workspace_state TEXT NOT NULL DEFAULT 'UNMATERIALIZED',
      hibernated_at TEXT,
      failure_code TEXT,
      runtime TEXT,
      model_role TEXT,
      model_provider TEXT,
      model_class TEXT,
      model TEXT,
      reasoning_effort TEXT,
      model_routing_reason TEXT,
      parent_run_id TEXT,
      snapshot_json TEXT,
      contract_markdown TEXT,
      plan_markdown TEXT,
      repair_findings_json TEXT,
      manual_validation_required INTEGER,
      implementation_iteration INTEGER NOT NULL DEFAULT 0,
      code_repair_round INTEGER NOT NULL DEFAULT 0,
      validation_repair_round INTEGER NOT NULL DEFAULT 0,
      verifier_round INTEGER NOT NULL DEFAULT 0,
      spec_comment_id TEXT,
      confirmation_comment_id TEXT,
      mr_iid INTEGER,
      last_error TEXT,
      risk TEXT,
      risk_signals_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    DROP INDEX IF EXISTS one_active_run_per_issue_kind
    """,
    """
    CREATE UNIQUE INDEX one_active_run_per_issue_kind
    ON runs(issue_key, kind)
    WHERE state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED')
    """,
    """
    DROP INDEX IF EXISTS one_active_factory_run_per_issue
    """,
    """
    CREATE UNIQUE INDEX one_active_factory_run_per_issue
    ON runs(issue_key)
    WHERE state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED')
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
    """,
    """
    CREATE TABLE IF NOT EXISTS factory_tasks (
      task_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      stage TEXT NOT NULL,
      role TEXT NOT NULL,
      status TEXT NOT NULL,
      thread_id TEXT,
      turn_id TEXT,
      model_provider TEXT NOT NULL,
      model_class TEXT NOT NULL,
      model TEXT NOT NULL,
      reasoning_effort TEXT NOT NULL,
      routing_reason TEXT NOT NULL,
      codex_project_id TEXT,
      codex_section_id TEXT,
      workspace TEXT,
      workspace_sha TEXT,
      prompt_sha256 TEXT NOT NULL,
      output_json TEXT,
      failure_code TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY(run_id) REFERENCES runs(run_id)
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS factory_tasks_by_run
    ON factory_tasks(run_id, created_at)
    """,
    """
    CREATE TABLE IF NOT EXISTS intake_snapshots (
      scope TEXT PRIMARY KEY,
      observed_at TEXT NOT NULL,
      snapshot_json TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS contract_chats (
      run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
      task_key TEXT NOT NULL REFERENCES factory_tasks(task_key),
      status TEXT NOT NULL CHECK(status IN ('WAITING', 'ANSWERED', 'CONSUMED')),
      source_sha256 TEXT NOT NULL,
      question_turn_id TEXT NOT NULL,
      question_sha256 TEXT NOT NULL,
      user_turn_id TEXT,
      user_message_id TEXT,
      user_text TEXT,
      reply_evidence_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS contract_chats_by_task
    ON contract_chats(task_key)
    """,
    """
    CREATE TABLE IF NOT EXISTS mr_feedback_notes (
      feedback_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      project TEXT NOT NULL,
      mr_iid INTEGER NOT NULL,
      discussion_id TEXT NOT NULL,
      note_id INTEGER NOT NULL,
      note_updated_at TEXT NOT NULL,
      author_id INTEGER NOT NULL,
      body_sha256 TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN (
        'PENDING', 'CLAIMED', 'COMPLETE', 'FAILED', 'SUPERSEDED',
        'CHANGE_REQUEST', 'REWORKING', 'RECONCILE_REQUIRED'
      )),
      request_key TEXT,
      controller_previous_turn_id TEXT,
      reply_id INTEGER,
      last_error TEXT,
      reply_phase INTEGER NOT NULL DEFAULT 0,
      review_batch_key TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS mr_feedback_notes_by_status
    ON mr_feedback_notes(status, created_at)
    """,
    """
    CREATE TABLE IF NOT EXISTS desktop_requests (
      request_key TEXT PRIMARY KEY,
      target_kind TEXT NOT NULL CHECK(target_kind IN ('TASK', 'CONTROLLER')),
      target_key TEXT NOT NULL,
      action TEXT NOT NULL CHECK(action IN ('CREATE', 'FOLLOWUP')),
      status TEXT NOT NULL CHECK(status IN (
        'PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN',
        'THREAD_RECORDED', 'RECONCILE_REQUIRED', 'SUCCEEDED', 'FAILED'
      )),
      payload_sha256 TEXT NOT NULL,
      codex_project_id TEXT NOT NULL,
      model TEXT NOT NULL,
      reasoning_effort TEXT NOT NULL,
      existing_thread_id TEXT,
      thread_id TEXT,
      verified_project_id TEXT,
      verified_cwd TEXT,
      verified_head_sha TEXT,
      turn_id TEXT,
      title TEXT NOT NULL,
      prompt TEXT NOT NULL,
      schema_json TEXT NOT NULL,
      cwd TEXT NOT NULL,
      branch TEXT,
      base_branch TEXT,
      metadata_json TEXT NOT NULL,
      output_json TEXT,
      failure_code TEXT,
      rejected_tool_call_id TEXT,
      claimed_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS one_unresolved_desktop_request_per_target
    ON desktop_requests(target_kind, target_key)
    WHERE status IN (
      'PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN',
      'THREAD_RECORDED', 'RECONCILE_REQUIRED'
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS planner_format_repairs (
      request_key TEXT PRIMARY KEY REFERENCES desktop_requests(request_key),
      completed_turn_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('AUTHORIZED', 'CLAIMED')),
      authorized_at TEXT NOT NULL,
      claimed_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS controller_format_repairs (
      request_key TEXT PRIMARY KEY REFERENCES desktop_requests(request_key),
      completed_turn_id TEXT NOT NULL,
      request_payload_sha256 TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('AUTHORIZED', 'CLAIMED', 'SUCCEEDED')),
      authorized_at TEXT NOT NULL,
      claimed_at TEXT,
      repair_turn_id TEXT,
      repair_output_sha256 TEXT
    )
    """
  ]

  @model_run_columns %{
    "runtime" => "TEXT",
    "model_role" => "TEXT",
    "model_provider" => "TEXT",
    "model_class" => "TEXT",
    "model" => "TEXT",
    "reasoning_effort" => "TEXT",
    "model_routing_reason" => "TEXT",
    "parent_run_id" => "TEXT",
    "snapshot_json" => "TEXT",
    "contract_markdown" => "TEXT",
    "plan_markdown" => "TEXT",
    "repair_findings_json" => "TEXT",
    "review_feedback_json" => "TEXT",
    "review_base_sha" => "TEXT",
    "manual_validation_required" => "INTEGER",
    "implementation_iteration" => "INTEGER NOT NULL DEFAULT 0",
    "code_repair_round" => "INTEGER NOT NULL DEFAULT 0",
    "validation_repair_round" => "INTEGER NOT NULL DEFAULT 0",
    "verifier_round" => "INTEGER NOT NULL DEFAULT 0",
    "spec_comment_id" => "TEXT",
    "confirmation_comment_id" => "TEXT",
    "mr_iid" => "INTEGER",
    "last_error" => "TEXT",
    "risk" => "TEXT",
    "risk_signals_json" => "TEXT",
    "workspace_state" => "TEXT NOT NULL DEFAULT 'UNMATERIALIZED'",
    "hibernated_at" => "TEXT",
    "ci_preflight_sha" => "TEXT",
    "ci_pipeline_id" => "INTEGER",
    "ci_pipeline_url" => "TEXT",
    "ci_evidence_json" => "TEXT",
    "ci_last_checked_at" => "TEXT"
  }

  @control_columns %{
    "controller_thread_id" => "TEXT",
    "controller_turn_id" => "TEXT",
    "controller_codex_project_id" => "TEXT",
    "controller_codex_section_id" => "TEXT",
    "controller_model_role" => "TEXT",
    "controller_model_provider" => "TEXT",
    "controller_model_class" => "TEXT",
    "controller_model" => "TEXT",
    "controller_reasoning_effort" => "TEXT",
    "controller_routing_reason" => "TEXT",
    "controller_writer_conflict_since" => "TEXT",
    "controller_writer_conflict_count" => "INTEGER NOT NULL DEFAULT 0"
  }

  @task_columns %{
    "codex_project_id" => "TEXT",
    "codex_section_id" => "TEXT",
    "workspace" => "TEXT",
    "workspace_sha" => "TEXT"
  }

  @desktop_request_columns %{
    "verified_project_id" => "TEXT",
    "verified_cwd" => "TEXT",
    "verified_head_sha" => "TEXT",
    "rejected_tool_call_id" => "TEXT",
    "claimed_at" => "TEXT"
  }

  @contract_chat_columns %{
    "reply_evidence_json" => "TEXT"
  }

  @mr_feedback_columns %{
    "request_key" => "TEXT",
    "controller_previous_turn_id" => "TEXT",
    "reply_id" => "INTEGER",
    "last_error" => "TEXT",
    "reply_phase" => "INTEGER NOT NULL DEFAULT 0",
    "review_batch_key" => "TEXT"
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
    ensure_columns(connection, "control", @control_columns)
    ensure_columns(connection, "factory_tasks", @task_columns)
    ensure_columns(connection, "desktop_requests", @desktop_request_columns)
    ensure_columns(connection, "contract_chats", @contract_chat_columns)
    ensure_columns(connection, "mr_feedback_notes", @mr_feedback_columns)
    migrate_mr_feedback_statuses(connection)

    query!(
      connection,
      """
      INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at)
      VALUES (1, ?), (2, ?), (3, ?), (4, ?), (5, ?), (6, ?), (7, ?), (8, ?), (9, ?), (10, ?), (11, ?), (12, ?), (13, ?), (14, ?), (15, ?)
      """,
      List.duplicate(iso_now(), 15)
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

  defp migrate_mr_feedback_statuses(connection) do
    %{"sql" => schema} = one!(connection, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'mr_feedback_notes'")

    unless Enum.all?(~w(SUPERSEDED CHANGE_REQUEST REWORKING RECONCILE_REQUIRED), &String.contains?(schema, "'#{&1}'")) do
      transaction!(connection, fn transaction ->
        query!(transaction, """
        CREATE TABLE mr_feedback_notes_upgrade (
          feedback_key TEXT PRIMARY KEY,
          run_id TEXT NOT NULL REFERENCES runs(run_id),
          project TEXT NOT NULL,
          mr_iid INTEGER NOT NULL,
          discussion_id TEXT NOT NULL,
          note_id INTEGER NOT NULL,
          note_updated_at TEXT NOT NULL,
          author_id INTEGER NOT NULL,
          body_sha256 TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN (
            'PENDING', 'CLAIMED', 'COMPLETE', 'FAILED', 'SUPERSEDED',
            'CHANGE_REQUEST', 'REWORKING', 'RECONCILE_REQUIRED'
          )),
          request_key TEXT,
          controller_previous_turn_id TEXT,
          reply_id INTEGER,
          last_error TEXT,
          reply_phase INTEGER NOT NULL DEFAULT 0,
          review_batch_key TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
        """)

        query!(transaction, """
        INSERT INTO mr_feedback_notes_upgrade (
          feedback_key, run_id, project, mr_iid, discussion_id, note_id,
          note_updated_at, author_id, body_sha256, status, request_key,
          controller_previous_turn_id, reply_id, last_error, reply_phase,
          review_batch_key, created_at, updated_at
        )
        SELECT feedback_key, run_id, project, mr_iid, discussion_id, note_id,
               note_updated_at, author_id, body_sha256, status, request_key,
               controller_previous_turn_id, reply_id, last_error, reply_phase,
               review_batch_key, created_at, updated_at
        FROM mr_feedback_notes
        """)

        query!(transaction, "DROP TABLE mr_feedback_notes")
        query!(transaction, "ALTER TABLE mr_feedback_notes_upgrade RENAME TO mr_feedback_notes")
        query!(transaction, "CREATE INDEX mr_feedback_notes_by_status ON mr_feedback_notes(status, created_at)")
      end)
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
