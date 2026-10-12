defmodule SymphonyElixir.Factory.Store do
  @moduledoc """
  Durable SQLite storage for factory coordination state.

  The schema intentionally remains compatible with the original Python
  `factoryctl.py` database so the Elixir runtime can take over without losing
  leases, run ownership, or model-route history.
  """

  alias Exqlite.Result
  alias SymphonyElixir.Factory.WorkerFileIO

  @schema_statements [
    """
    CREATE TABLE IF NOT EXISTS ticket_jira_effects (
      operation_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      operation TEXT NOT NULL CHECK(operation IN ('START_IMPLEMENTATION', 'REVIEW_READY')),
      binding_json TEXT NOT NULL,
      binding_sha256 TEXT NOT NULL,
      effects_json TEXT NOT NULL,
      effects_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('FIRST_PENDING', 'FIRST_UNCERTAIN', 'SECOND_PENDING', 'SECOND_UNCERTAIN', 'COMPLETE')),
      first_receipt_json TEXT,
      second_receipt_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_checkout_intents (
      run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
      canonical_path TEXT NOT NULL UNIQUE,
      repo_path TEXT NOT NULL,
      branch TEXT NOT NULL,
      binding_json TEXT NOT NULL,
      binding_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('PREPARED', 'MUTATING_UNCERTAIN', 'READY', 'RECONCILE_REQUIRED')),
      owner_nonce TEXT,
      helper_pid INTEGER,
      execution_json TEXT,
      receipt_json TEXT,
      last_error TEXT,
      UNIQUE(repo_path, branch)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS controller_checks (
      check_key TEXT PRIMARY KEY,
      worker_request_key TEXT NOT NULL REFERENCES worker_evidence(request_key),
      reservation_key TEXT NOT NULL REFERENCES workspace_access(reservation_key),
      binding_json TEXT NOT NULL,
      binding_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('PREPARED', 'RUNNING', 'COMPLETE', 'RECONCILE_REQUIRED')),
      helper_pid INTEGER,
      receipt_json TEXT,
      receipt_sha256 TEXT,
      error TEXT
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS one_active_controller_check ON controller_checks(reservation_key) WHERE phase != 'COMPLETE'",
    """
    CREATE TABLE IF NOT EXISTS worker_file_operations (
      request_key TEXT NOT NULL REFERENCES worker_evidence(request_key),
      call_id TEXT NOT NULL,
      arguments_sha256 TEXT NOT NULL,
      path TEXT NOT NULL,
      before_sha256 TEXT NOT NULL,
      after_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('PREPARED', 'APPLIED', 'ABORTED')),
      io_pending INTEGER NOT NULL DEFAULT 0 CHECK(io_pending IN (0, 1)),
      io_receipt_json TEXT,
      io_invocation TEXT,
      io_binding_json TEXT,
      PRIMARY KEY(request_key, call_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_review_bases (
      run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
      base_ref TEXT NOT NULL,
      base_sha TEXT NOT NULL,
      bound_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS workspace_access (
      reservation_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      task_key TEXT REFERENCES factory_tasks(task_key),
      request_key TEXT NOT NULL,
      mode TEXT NOT NULL CHECK(mode IN ('SOURCE', 'REVIEW', 'MAINTENANCE')),
      generation INTEGER NOT NULL,
      canonical_path TEXT NOT NULL,
      git_dir TEXT NOT NULL,
      common_dir TEXT NOT NULL,
      binding_json TEXT NOT NULL,
      acquired_at TEXT NOT NULL,
      released_at TEXT,
      release_receipt_json TEXT
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS one_workspace_path_owner ON workspace_access(canonical_path) WHERE released_at IS NULL",
    "CREATE UNIQUE INDEX IF NOT EXISTS one_workspace_git_owner ON workspace_access(git_dir) WHERE released_at IS NULL",
    """
    CREATE TABLE IF NOT EXISTS worker_evidence (
      request_key TEXT PRIMARY KEY,
      task_key TEXT NOT NULL REFERENCES factory_tasks(task_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      reservation_key TEXT NOT NULL UNIQUE REFERENCES workspace_access(reservation_key),
      binding_json TEXT NOT NULL,
      binding_sha256 TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('RESERVED', 'START_SENT', 'THREAD_BOUND', 'TURN_BOUND', 'RESULT_RECORDED', 'CONSUMED', 'RECONCILE_REQUIRED')),
      thread_id TEXT,
      turn_id TEXT,
      item_id TEXT,
      output_json TEXT,
      output_sha256 TEXT,
      policy_json TEXT,
      owner_id TEXT NOT NULL,
      owner_process_json TEXT,
      owner_stopped_at TEXT,
      owner_stop_json TEXT,
      failure_code TEXT,
      created_at TEXT NOT NULL,
      consumed_at TEXT
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS one_worker_turn_receipt ON worker_evidence(thread_id, turn_id) WHERE turn_id IS NOT NULL",
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
      execution_mode TEXT,
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
      target_kind TEXT NOT NULL CHECK(target_kind IN ('TASK', 'CONTROLLER', 'TICKET_CHAT')),
      target_key TEXT NOT NULL,
      action TEXT NOT NULL CHECK(action IN ('CREATE', 'FOLLOWUP')),
      status TEXT NOT NULL CHECK(status IN (
        'PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN',
        'THREAD_RECORDED', 'RECONCILE_REQUIRED', 'SUCCEEDED', 'FAILED', 'SUPERSEDED'
      )),
      payload_sha256 TEXT NOT NULL,
      codex_project_id TEXT CHECK(
        (target_kind = 'TICKET_CHAT' AND codex_project_id IS NULL) OR
        (target_kind IN ('TASK', 'CONTROLLER') AND codex_project_id IS NOT NULL)
      ),
      model TEXT NOT NULL,
      reasoning_effort TEXT NOT NULL,
      existing_thread_id TEXT,
      thread_id TEXT,
      verified_project_id TEXT,
      verified_cwd TEXT,
      verified_head_sha TEXT,
      target_observation_json TEXT,
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
      superseded_by TEXT,
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
    CREATE TABLE IF NOT EXISTS ticket_chats (
      chat_key TEXT PRIMARY KEY,
      scope_key TEXT NOT NULL,
      issue_id TEXT NOT NULL,
      issue_key TEXT NOT NULL,
      repo_key TEXT NOT NULL,
      route TEXT NOT NULL CHECK(route = 'desktop_owned_ticket_chat_v1'),
      generation INTEGER NOT NULL CHECK(generation > 0),
      create_request_key TEXT NOT NULL UNIQUE,
      directory_name TEXT NOT NULL UNIQUE,
      cwd TEXT NOT NULL UNIQUE,
      model TEXT NOT NULL,
      reasoning_effort TEXT NOT NULL,
      broker_thread_id TEXT,
      thread_id TEXT UNIQUE,
      observation_json TEXT,
      context_sequence INTEGER NOT NULL DEFAULT 0,
      presentation_sha256 TEXT,
      presentation_request_key TEXT,
      presentation_event_id INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(scope_key, issue_id, repo_key)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_chat_runs (
      run_id TEXT PRIMARY KEY REFERENCES runs(run_id),
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_parent_claims (
      request_key TEXT PRIMARY KEY REFERENCES desktop_requests(request_key),
      receipt_json TEXT NOT NULL,
      claimed_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_mr_claims (
      request_key TEXT PRIMARY KEY REFERENCES desktop_requests(request_key),
      receipt_json TEXT NOT NULL,
      receipt_sha256 TEXT NOT NULL,
      claimed_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_chat_questions (
      question_key TEXT PRIMARY KEY,
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      binding_json TEXT NOT NULL,
      body TEXT NOT NULL,
      answers_json TEXT NOT NULL,
      opened_at REAL NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('OPEN', 'ANSWERED', 'INVALIDATED')),
      answer_json TEXT,
      input_key TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_chat_inputs (
      input_key TEXT PRIMARY KEY,
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      generation INTEGER NOT NULL,
      thread_id TEXT NOT NULL,
      turn_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      client_id TEXT NOT NULL,
      body TEXT NOT NULL,
      body_sha256 TEXT NOT NULL,
      started_at REAL NOT NULL,
      completed_at REAL NOT NULL,
      staging_receipts_json TEXT NOT NULL,
      readback_sha256 TEXT NOT NULL,
      origin TEXT NOT NULL CHECK(origin = 'NATIVE_CLIENT_INPUT'),
      observed_at TEXT NOT NULL,
      UNIQUE(chat_key, generation, turn_id, item_id),
      UNIQUE(chat_key, generation, client_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_chat_commands (
      command_key TEXT PRIMARY KEY,
      proposal_id TEXT NOT NULL,
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      binding_json TEXT NOT NULL,
      body_sha256 TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('PENDING', 'ACCEPTED', 'APPLIED', 'REJECTED')),
      input_key TEXT UNIQUE REFERENCES ticket_chat_inputs(input_key),
      receipt_json TEXT,
      application_receipt_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_chat_answer_recoveries (
      recovery_key TEXT PRIMARY KEY,
      predecessor_command_key TEXT NOT NULL UNIQUE REFERENCES ticket_chat_commands(command_key),
      input_key TEXT NOT NULL UNIQUE REFERENCES ticket_chat_inputs(input_key),
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      question_key TEXT NOT NULL REFERENCES ticket_chat_questions(question_key),
      question_preimage_json TEXT NOT NULL,
      answer_json TEXT NOT NULL,
      proof_json TEXT NOT NULL,
      proof_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_contract_amendments (
      command_key TEXT PRIMARY KEY REFERENCES ticket_chat_commands(command_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      generation INTEGER NOT NULL,
      active_owner INTEGER NOT NULL DEFAULT 1 CHECK(active_owner IN (0, 1)),
      phase TEXT NOT NULL CHECK(phase IN ('RESERVED', 'APPLIED', 'SUPERSEDED')),
      prior_binding_json TEXT NOT NULL,
      prior_revision INTEGER NOT NULL,
      prior_contract_markdown TEXT NOT NULL,
      prior_contract_sha256 TEXT NOT NULL,
      proposed_revision INTEGER NOT NULL,
      proposed_contract_markdown TEXT NOT NULL,
      proposed_contract_sha256 TEXT NOT NULL,
      candidate_sha TEXT NOT NULL,
      input_key TEXT NOT NULL REFERENCES ticket_chat_inputs(input_key),
      input_sha256 TEXT NOT NULL,
      readback_sha256 TEXT NOT NULL,
      admission_sha256 TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL,
      predecessor_json TEXT,
      supersession_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      last_error TEXT,
      receipt_json TEXT,
      application_receipt_sha256 TEXT
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS one_active_contract_amendment_per_run ON ticket_contract_amendments(run_id) WHERE active_owner = 1",
    """
    CREATE TABLE IF NOT EXISTS ticket_contract_amendment_supersessions (
      predecessor_command_key TEXT PRIMARY KEY REFERENCES ticket_contract_amendments(command_key),
      successor_command_key TEXT NOT NULL UNIQUE REFERENCES ticket_contract_amendments(command_key),
      link_json TEXT NOT NULL,
      link_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_contract_critic_attempts (
      command_key TEXT PRIMARY KEY REFERENCES ticket_contract_amendments(command_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      task_key TEXT NOT NULL UNIQUE REFERENCES factory_tasks(task_key),
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      generation INTEGER NOT NULL,
      input_key TEXT NOT NULL REFERENCES ticket_chat_inputs(input_key),
      input_sha256 TEXT NOT NULL,
      draft_comment_id TEXT NOT NULL,
      prior_revision INTEGER NOT NULL,
      prior_contract_sha256 TEXT NOT NULL,
      candidate_sha TEXT NOT NULL,
      proposed_revision INTEGER NOT NULL,
      proposed_contract_sha256 TEXT NOT NULL,
      prompt TEXT NOT NULL,
      prompt_sha256 TEXT NOT NULL,
      schema_json TEXT NOT NULL,
      schema_sha256 TEXT NOT NULL,
      snapshot_json TEXT NOT NULL,
      snapshot_sha256 TEXT NOT NULL,
      route_json TEXT NOT NULL,
      route_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('PREPARED', 'INVOKING', 'RESULT_RECORDED', 'RECONCILE_REQUIRED')),
      worker_thread_id TEXT,
      worker_turn_id TEXT,
      worker_item_id TEXT,
      worker_policy_json TEXT,
      owner_pid TEXT,
      invocation_nonce TEXT,
      owner_cwd TEXT,
      owner_stop_json TEXT,
      result_json TEXT,
      result_sha256 TEXT,
      last_observation_json TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_amendment_jira_effects (
      command_key TEXT PRIMARY KEY REFERENCES ticket_contract_amendments(command_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      generation INTEGER NOT NULL,
      input_key TEXT NOT NULL REFERENCES ticket_chat_inputs(input_key),
      input_sha256 TEXT NOT NULL,
      prior_revision INTEGER NOT NULL,
      prior_contract_sha256 TEXT NOT NULL,
      candidate_sha TEXT NOT NULL,
      proposed_revision INTEGER NOT NULL,
      proposed_contract_markdown TEXT NOT NULL,
      proposed_contract_sha256 TEXT NOT NULL,
      issue_key TEXT NOT NULL,
      issue_id TEXT NOT NULL,
      draft_body TEXT NOT NULL,
      draft_body_sha256 TEXT NOT NULL,
      source_preimage_json TEXT NOT NULL,
      source_preimage_sha256 TEXT NOT NULL,
      publication_preimage_json TEXT,
      preflight_json TEXT NOT NULL,
      preflight_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('PENDING', 'UNCERTAIN', 'READ_BACK')),
      claimed_at TEXT,
      observed_json TEXT,
      observed_sha256 TEXT,
      readback_json TEXT,
      readback_sha256 TEXT,
      comment_id TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ticket_amendment_authorization_effects (
      command_key TEXT PRIMARY KEY REFERENCES ticket_contract_amendments(command_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      chat_key TEXT NOT NULL REFERENCES ticket_chats(chat_key),
      generation INTEGER NOT NULL,
      input_key TEXT NOT NULL REFERENCES ticket_chat_inputs(input_key),
      input_sha256 TEXT NOT NULL,
      prior_revision INTEGER NOT NULL,
      prior_contract_sha256 TEXT NOT NULL,
      candidate_sha TEXT NOT NULL,
      proposed_revision INTEGER NOT NULL,
      proposed_contract_markdown TEXT NOT NULL,
      proposed_contract_sha256 TEXT NOT NULL,
      issue_key TEXT NOT NULL,
      issue_id TEXT NOT NULL,
      critic_task_key TEXT NOT NULL,
      critic_result_sha256 TEXT NOT NULL,
      critic_output_sha256 TEXT NOT NULL,
      draft_comment_id TEXT NOT NULL,
      draft_readback_json TEXT NOT NULL,
      draft_readback_sha256 TEXT NOT NULL,
      authorization_body TEXT NOT NULL,
      authorization_body_sha256 TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('PENDING', 'UNCERTAIN', 'READ_BACK')),
      claimed_at TEXT,
      observed_json TEXT,
      observed_sha256 TEXT,
      readback_json TEXT,
      readback_sha256 TEXT,
      comment_id TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
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
    "execution_mode" => "TEXT",
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
    "superseded_by" => "TEXT",
    "target_observation_json" => "TEXT",
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

  @doc "Opens an existing factory ledger without initialization or migrations."
  @spec start_read_only(keyword()) :: GenServer.on_start()
  def start_read_only(opts) do
    database = Keyword.fetch!(opts, :database)

    with true <- is_binary(database) and Path.type(database) == :absolute,
         {:ok, %File.Stat{type: :regular}} <- File.lstat(database),
         {:ok, %File.Stat{type: :directory}} <- File.stat(Path.dirname(database)),
         {:ok, connection} <- Exqlite.start_link(database: database, mode: :readonly, default_transaction_mode: :deferred, busy_timeout: Keyword.get(opts, :busy_timeout, 30_000)) do
      validate_reader(connection)
    else
      _ -> {:error, :existing_factory_ledger_required}
    end
  end

  defp validate_reader(connection) do
    case read_only_schema(connection) do
      :ok ->
        {:ok, connection}

      error ->
        stop_reader(connection)
        error
    end
  rescue
    error ->
      stop_reader(connection)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      stop_reader(connection)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp stop_reader(connection) do
    if Process.alive?(connection), do: GenServer.stop(connection)
  end

  defp read_only_schema(connection) do
    versions = query!(connection, "SELECT version FROM factory_schema_migrations ORDER BY version").rows
    tables = query!(connection, "SELECT name FROM sqlite_master WHERE type = 'table'").rows |> List.flatten() |> MapSet.new()

    expected =
      @schema_statements
      |> Enum.flat_map(fn statement ->
        case Regex.run(~r/CREATE TABLE IF NOT EXISTS (\w+)/, statement) do
          [_, table] -> [table]
          _ -> []
        end
      end)
      |> MapSet.new()

    if versions == Enum.map(1..37, &[&1]) and MapSet.subset?(expected, tables) and reader_columns_present?(connection) and
         reader_indexes_present?(connection),
       do: :ok,
       else: {:error, :factory_ledger_schema_not_current}
  rescue
    Exqlite.Error -> {:error, :factory_ledger_schema_not_current}
  end

  defp reader_indexes_present?(connection) do
    one!(connection, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'one_active_contract_amendment_per_run'") != nil
  end

  defp reader_columns_present?(connection) do
    required = %{
      "runs" =>
        ~w(run_id issue_key repo_key repo_path kind state contract_markdown snapshot_json plan_markdown candidate_sha ci_evidence_json repair_findings_json review_feedback_json updated_at) ++
          Map.keys(@model_run_columns),
      "ticket_chats" => ~w(chat_key scope_key issue_id issue_key repo_key generation thread_id context_sequence presentation_request_key),
      "ticket_chat_runs" => ~w(chat_key run_id),
      "ticket_chat_questions" => ~w(question_key chat_key run_id status body answers_json binding_json opened_at),
      "ticket_chat_commands" => ~w(command_key chat_key run_id status payload_json receipt_json application_receipt_json updated_at),
      "ticket_chat_answer_recoveries" => ~w(recovery_key predecessor_command_key input_key chat_key run_id question_key question_preimage_json answer_json proof_json proof_sha256 created_at),
      "ticket_contract_amendments" =>
        ~w(command_key run_id chat_key generation active_owner phase prior_binding_json prior_revision prior_contract_markdown prior_contract_sha256 proposed_revision proposed_contract_markdown proposed_contract_sha256 candidate_sha input_key input_sha256 readback_sha256 admission_sha256 payload_sha256 predecessor_json supersession_json created_at updated_at last_error receipt_json application_receipt_sha256),
      "ticket_contract_amendment_supersessions" => ~w(predecessor_command_key successor_command_key link_json link_sha256 created_at),
      "ticket_contract_critic_attempts" =>
        ~w(command_key run_id task_key chat_key generation input_key input_sha256 draft_comment_id prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_sha256 prompt prompt_sha256 schema_json schema_sha256 snapshot_json snapshot_sha256 route_json route_sha256 phase worker_thread_id worker_turn_id worker_item_id worker_policy_json owner_pid invocation_nonce owner_cwd owner_stop_json result_json result_sha256 last_observation_json last_error created_at updated_at),
      "ticket_amendment_jira_effects" =>
        ~w(command_key run_id chat_key generation input_key input_sha256 prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_markdown proposed_contract_sha256 issue_key issue_id draft_body draft_body_sha256 source_preimage_json source_preimage_sha256 publication_preimage_json preflight_json preflight_sha256 phase claimed_at observed_json observed_sha256 readback_json readback_sha256 comment_id last_error created_at updated_at),
      "ticket_amendment_authorization_effects" =>
        ~w(command_key run_id chat_key generation input_key input_sha256 prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_markdown proposed_contract_sha256 issue_key issue_id critic_task_key critic_result_sha256 critic_output_sha256 draft_comment_id draft_readback_json draft_readback_sha256 authorization_body authorization_body_sha256 phase claimed_at observed_json observed_sha256 readback_json readback_sha256 comment_id last_error created_at updated_at),
      "factory_tasks" => ~w(task_key run_id role stage status thread_id turn_id prompt_sha256 output_json created_at updated_at) ++ Map.keys(@task_columns),
      "desktop_requests" => ~w(request_key target_kind target_key status failure_code output_json thread_id turn_id metadata_json created_at) ++ Map.keys(@desktop_request_columns),
      "worker_evidence" =>
        ~w(request_key task_key run_id thread_id turn_id created_at consumed_at output_json binding_json binding_sha256 output_sha256 status owner_stopped_at owner_stop_json owner_process_json reservation_key),
      "workspace_access" => ~w(reservation_key canonical_path),
      "ticket_review_bases" => ~w(run_id base_sha),
      "ticket_checkout_intents" => ~w(run_id canonical_path repo_path branch binding_json binding_sha256 phase owner_nonce helper_pid execution_json receipt_json last_error),
      "ticket_mr_claims" => ~w(request_key receipt_json receipt_sha256 claimed_at),
      "events" => ~w(id run_id event_type payload_json occurred_at)
    }

    Enum.all?(required, fn {table, columns} ->
      existing = query!(connection, "PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new()
      MapSet.subset?(MapSet.new(columns), existing)
    end)
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

    ensure_columns(connection, "ticket_chats", %{
      "broker_thread_id" => "TEXT",
      "context_reader_json" => "TEXT",
      "presentation_sha256" => "TEXT",
      "presentation_request_key" => "TEXT",
      "presentation_event_id" => "INTEGER NOT NULL DEFAULT 0"
    })

    ensure_columns(connection, "ticket_chat_inputs", %{"completed_at" => "REAL", "staging_receipts_json" => "TEXT"})
    ensure_columns(connection, "ticket_chat_commands", %{"proposal_id" => "TEXT", "application_receipt_json" => "TEXT"})
    ensure_columns(connection, "ticket_amendment_jira_effects", %{"publication_preimage_json" => "TEXT"})
    query!(connection, "UPDATE ticket_amendment_jira_effects SET publication_preimage_json = source_preimage_json WHERE publication_preimage_json IS NULL")
    ensure_columns(connection, "worker_evidence", %{"owner_stop_json" => "TEXT", "owner_process_json" => "TEXT"})
    ensure_columns(connection, "worker_file_operations", %{"io_invocation" => "TEXT", "io_binding_json" => "TEXT"})
    ensure_columns(connection, "ticket_checkout_intents", %{"helper_pid" => "INTEGER", "execution_json" => "TEXT"})
    migrate_file_io_receipts(connection)
    migrate_file_operation_phases(connection)
    query!(connection, "CREATE UNIQUE INDEX IF NOT EXISTS one_file_io_invocation ON worker_file_operations(io_invocation) WHERE io_invocation IS NOT NULL")
    ensure_columns(connection, "contract_chats", @contract_chat_columns)
    ensure_columns(connection, "mr_feedback_notes", @mr_feedback_columns)
    migrate_desktop_ticket_targets(connection)
    migrate_mr_feedback_statuses(connection)
    migrate_ticket_critic_attempts(connection)
    migrate_ticket_contract_amendment_lifecycle(connection)
    migrate_ticket_contract_amendment_supersessions(connection)
    ensure_columns(connection, "ticket_contract_amendments", %{"supersession_json" => "TEXT"})
    migrate_nullable_amendment_candidates(connection)

    query!(
      connection,
      """
      INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at)
      VALUES (1, ?), (2, ?), (3, ?), (4, ?), (5, ?), (6, ?), (7, ?), (8, ?), (9, ?), (10, ?), (11, ?), (12, ?), (13, ?), (14, ?), (15, ?), (16, ?), (17, ?), (18, ?), (19, ?), (20, ?), (21, ?), (22, ?), (23, ?), (24, ?)
      """,
      List.duplicate(iso_now(), 24)
    )

    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (25, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (26, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (27, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (28, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (29, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (30, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (31, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (32, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (33, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (34, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (35, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (36, ?)", [iso_now()])
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (37, ?)", [iso_now()])

    :ok
  end

  defp migrate_nullable_amendment_candidates(connection) do
    tables = ~w(ticket_contract_amendments ticket_contract_critic_attempts ticket_amendment_jira_effects ticket_amendment_authorization_effects)
    schemas = Map.new(tables, &{&1, one!(connection, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [&1])})

    if Enum.any?(schemas, fn {_table, schema} -> is_map(schema) and String.contains?(schema["sql"], "candidate_sha TEXT NOT NULL") end) do
      DBConnection.run(connection, fn leased ->
        original_foreign_keys = one!(leased, "PRAGMA foreign_keys")["foreign_keys"]
        original_legacy_alter_table = one!(leased, "PRAGMA legacy_alter_table")["legacy_alter_table"]
        query!(leased, "PRAGMA foreign_keys = OFF")
        query!(leased, "PRAGMA legacy_alter_table = ON")

        try do
          transaction!(leased, fn tx ->
            Enum.each(tables, fn table ->
              schema = one!(tx, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])
              upgrade = table <> "_nullable_candidate_upgrade"
              create = Regex.replace(~r/CREATE TABLE "?#{table}"?/, schema["sql"], "CREATE TABLE #{upgrade}")
              create = String.replace(create, "candidate_sha TEXT NOT NULL", "candidate_sha TEXT")
              columns = query!(tx, "PRAGMA table_info(#{table})").rows |> Enum.map(&Enum.at(&1, 1))
              names = Enum.join(columns, ", ")
              query!(tx, create)
              query!(tx, "INSERT INTO #{upgrade}(#{names}) SELECT #{names} FROM #{table}")
              query!(tx, "DROP TABLE #{table}")
              query!(tx, "ALTER TABLE #{upgrade} RENAME TO #{table}")
            end)

            query!(tx, "CREATE UNIQUE INDEX one_active_contract_amendment_per_run ON ticket_contract_amendments(run_id) WHERE active_owner = 1")
            if query!(tx, "PRAGMA foreign_key_check").rows != [], do: raise("nullable amendment candidate migration failed foreign-key validation")
            :ok
          end)
        after
          query!(leased, "PRAGMA legacy_alter_table = #{original_legacy_alter_table}")
          query!(leased, "PRAGMA foreign_keys = #{original_foreign_keys}")
        end
      end)
    end
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

  defp migrate_file_io_receipts(connection) do
    ensure_columns(connection, "worker_file_operations", %{"io_pending" => "INTEGER NOT NULL DEFAULT 0 CHECK(io_pending IN (0, 1))", "io_receipt_json" => "TEXT"})
    rows = query!(connection, "SELECT request_key, call_id, arguments_sha256, io_receipt_json, io_binding_json, io_invocation FROM worker_file_operations WHERE phase = 'PREPARED'").rows

    Enum.each(rows, fn [key, call, hash, receipt, binding, invocation] ->
      identity = %{"request_key" => key, "call_id" => call, "arguments_sha256" => hash, "invocation" => invocation}

      unless WorkerFileIO.receipt_matches_binding?(receipt, binding, identity) do
        query!(connection, "UPDATE worker_file_operations SET io_pending = 1 WHERE request_key = ? AND call_id = ?", [key, call])
      end
    end)
  end

  defp migrate_file_operation_phases(connection) do
    %{"sql" => schema} = one!(connection, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'worker_file_operations'")

    unless String.contains?(schema, "'ABORTED'") do
      transaction!(connection, fn tx ->
        indexes = query!(tx, "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'worker_file_operations' AND sql IS NOT NULL").rows
        query!(tx, upgraded_file_operation_schema(schema))
        query!(tx, "INSERT INTO worker_file_operations_upgrade SELECT * FROM worker_file_operations")
        query!(tx, "DROP TABLE worker_file_operations")
        query!(tx, "ALTER TABLE worker_file_operations_upgrade RENAME TO worker_file_operations")
        Enum.each(indexes, &query!(tx, hd(&1)))
      end)
    end
  end

  defp upgraded_file_operation_schema(schema) do
    phase = ~r/CHECK\s*\(\s*phase\s+IN\s*\(\s*'PREPARED'\s*,\s*'APPLIED'\s*\)\s*\)/i
    unless Regex.match?(phase, schema), do: raise("unsupported worker file operation phase constraint")
    renamed = String.replace(schema, "worker_file_operations", "worker_file_operations_upgrade", global: false)
    Regex.replace(phase, renamed, "CHECK(phase IN ('PREPARED', 'APPLIED', 'ABORTED'))")
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

  defp migrate_ticket_critic_attempts(connection) do
    schema =
      query!(
        connection,
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ticket_contract_critic_attempts'"
      )

    case schema.rows do
      [[sql]] when is_binary(sql) ->
        if String.contains?(sql, "RESULT_RECORDED") do
          :ok
        else
          migrate_ticket_critic_attempts_v32(connection)
        end

      _ ->
        :ok
    end
  end

  defp migrate_ticket_critic_attempts_v32(connection) do
    old_table = "ticket_contract_critic_attempts_v31"

    create_statement =
      Enum.find(@schema_statements, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS ticket_contract_critic_attempts"))
      |> String.replace("CREATE TABLE IF NOT EXISTS ticket_contract_critic_attempts", "CREATE TABLE ticket_contract_critic_attempts")

    transaction!(connection, fn tx ->
      query!(tx, "ALTER TABLE ticket_contract_critic_attempts RENAME TO #{old_table}")
      query!(tx, create_statement)

      query!(
        tx,
        """
        INSERT INTO ticket_contract_critic_attempts(
          command_key, run_id, task_key, chat_key, generation, input_key, input_sha256,
          draft_comment_id, prior_revision, prior_contract_sha256, candidate_sha,
          proposed_revision, proposed_contract_sha256, prompt, prompt_sha256,
          schema_json, schema_sha256, snapshot_json, snapshot_sha256, route_json,
          route_sha256, phase, created_at, updated_at
        )
        SELECT command_key, run_id, task_key, chat_key, generation, input_key, input_sha256,
          draft_comment_id, prior_revision, prior_contract_sha256, candidate_sha,
          proposed_revision, proposed_contract_sha256, prompt, prompt_sha256,
          schema_json, schema_sha256, snapshot_json, snapshot_sha256, route_json,
          route_sha256, phase, created_at, updated_at
        FROM #{old_table}
        """
      )

      query!(tx, "DROP TABLE #{old_table}")
      :ok
    end)
  end

  defp migrate_ticket_contract_amendment_lifecycle(connection) do
    schema = one!(connection, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ticket_contract_amendments'")

    if is_map(schema) and String.contains?(schema["sql"], "'APPLIED'") do
      :ok
    else
      migrate_ticket_contract_amendment_lifecycle_v34(connection)
    end
  end

  defp migrate_ticket_contract_amendment_lifecycle_v34(connection) do
    create_statement =
      Enum.find(@schema_statements, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS ticket_contract_amendments"))
      |> String.replace("CREATE TABLE IF NOT EXISTS ticket_contract_amendments", "CREATE TABLE ticket_contract_amendments_upgrade")

    DBConnection.run(connection, fn leased ->
      query!(leased, "PRAGMA foreign_keys = OFF")
      query!(leased, "PRAGMA legacy_alter_table = ON")

      try do
        transaction!(leased, fn tx ->
          query!(tx, create_statement)

          query!(
            tx,
            """
            INSERT INTO ticket_contract_amendments_upgrade(
              command_key, run_id, chat_key, generation, active_owner, phase, prior_binding_json,
              prior_revision, prior_contract_markdown, prior_contract_sha256, proposed_revision,
              proposed_contract_markdown, proposed_contract_sha256, candidate_sha, input_key,
              input_sha256, readback_sha256, admission_sha256, payload_sha256, predecessor_json,
              created_at, updated_at, last_error, receipt_json, application_receipt_sha256
            )
            SELECT command_key, run_id, chat_key, generation, active_owner, phase, prior_binding_json,
              prior_revision, prior_contract_markdown, prior_contract_sha256, proposed_revision,
              proposed_contract_markdown, proposed_contract_sha256, candidate_sha, input_key,
              input_sha256, readback_sha256, admission_sha256, payload_sha256, predecessor_json,
              created_at, updated_at, last_error, receipt_json, NULL
            FROM ticket_contract_amendments
            """
          )

          query!(tx, "DROP TABLE ticket_contract_amendments")
          query!(tx, "ALTER TABLE ticket_contract_amendments_upgrade RENAME TO ticket_contract_amendments")
          query!(tx, "CREATE UNIQUE INDEX one_active_contract_amendment_per_run ON ticket_contract_amendments(run_id) WHERE active_owner = 1")
          :ok
        end)
      after
        query!(leased, "PRAGMA legacy_alter_table = OFF")
        query!(leased, "PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp migrate_ticket_contract_amendment_supersessions(connection) do
    schema = one!(connection, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ticket_contract_amendments'")

    unless is_map(schema) and String.contains?(schema["sql"], "'SUPERSEDED'") do
      create_statement =
        Enum.find(@schema_statements, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS ticket_contract_amendments"))
        |> String.replace("CREATE TABLE IF NOT EXISTS ticket_contract_amendments", "CREATE TABLE ticket_contract_amendments_upgrade")

      supersession_column =
        query!(connection, "PRAGMA table_info(ticket_contract_amendments)").rows
        |> Enum.any?(&(Enum.at(&1, 1) == "supersession_json"))

      supersession_select = if supersession_column, do: "supersession_json", else: "NULL"

      DBConnection.run(connection, fn leased ->
        original_foreign_keys = one!(leased, "PRAGMA foreign_keys")["foreign_keys"]
        original_legacy_alter_table = one!(leased, "PRAGMA legacy_alter_table")["legacy_alter_table"]
        query!(leased, "PRAGMA foreign_keys = OFF")
        query!(leased, "PRAGMA legacy_alter_table = ON")

        try do
          transaction!(leased, fn tx ->
            query!(tx, create_statement)

            query!(
              tx,
              """
              INSERT INTO ticket_contract_amendments_upgrade(
                command_key, run_id, chat_key, generation, active_owner, phase, prior_binding_json,
                prior_revision, prior_contract_markdown, prior_contract_sha256, proposed_revision,
                proposed_contract_markdown, proposed_contract_sha256, candidate_sha, input_key,
                input_sha256, readback_sha256, admission_sha256, payload_sha256, predecessor_json, supersession_json,
                created_at, updated_at, last_error, receipt_json, application_receipt_sha256
              )
              SELECT command_key, run_id, chat_key, generation, active_owner, phase, prior_binding_json,
                prior_revision, prior_contract_markdown, prior_contract_sha256, proposed_revision,
                proposed_contract_markdown, proposed_contract_sha256, candidate_sha, input_key,
                input_sha256, readback_sha256, admission_sha256, payload_sha256, predecessor_json, #{supersession_select},
                created_at, updated_at, last_error, receipt_json, application_receipt_sha256
              FROM ticket_contract_amendments
              """
            )

            query!(tx, "DROP TABLE ticket_contract_amendments")
            query!(tx, "ALTER TABLE ticket_contract_amendments_upgrade RENAME TO ticket_contract_amendments")
            query!(tx, "CREATE UNIQUE INDEX one_active_contract_amendment_per_run ON ticket_contract_amendments(run_id) WHERE active_owner = 1")

            if query!(tx, "PRAGMA foreign_key_check").rows != [] do
              raise "contract amendment migration failed foreign-key validation"
            end

            :ok
          end)
        after
          query!(leased, "PRAGMA legacy_alter_table = #{original_legacy_alter_table}")
          query!(leased, "PRAGMA foreign_keys = #{original_foreign_keys}")
        end
      end)
    end
  end

  defp migrate_desktop_ticket_targets(connection) do
    schema = one!(connection, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'desktop_requests'")["sql"]

    unless String.contains?(schema, "target_kind = 'TICKET_CHAT' AND codex_project_id IS NULL") and String.contains?(schema, "'SUPERSEDED'") do
      # SQLite's parent-table rebuild requires one leased connection with FKs restored before release.
      DBConnection.run(connection, fn leased ->
        query!(leased, "PRAGMA foreign_keys = OFF")

        try do
          if one!(leased, "PRAGMA foreign_keys")["foreign_keys"] != 0 do
            raise "desktop request migration requires an outer connection checkout"
          end

          transaction!(leased, &rebuild_desktop_requests/1)
        after
          query!(leased, "PRAGMA foreign_keys = ON")
        end
      end)
    end
  end

  defp rebuild_desktop_requests(transaction) do
    objects =
      query!(transaction, "SELECT sql FROM sqlite_master WHERE tbl_name = 'desktop_requests' AND type IN ('index', 'trigger') AND sql IS NOT NULL")

    columns =
      query!(transaction, "PRAGMA table_info(desktop_requests)").rows
      |> Enum.map_join(", ", fn [_cid, name | _rest] -> "\"#{String.replace(name, "\"", "\"\"")}\"" end)

    definition = Enum.find(@schema_statements, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS desktop_requests ("))
    query!(transaction, String.replace(definition, "IF NOT EXISTS desktop_requests", "desktop_requests_upgrade"))
    query!(transaction, "INSERT INTO desktop_requests_upgrade (#{columns}) SELECT #{columns} FROM desktop_requests")
    query!(transaction, "DROP TABLE desktop_requests")
    query!(transaction, "ALTER TABLE desktop_requests_upgrade RENAME TO desktop_requests")
    Enum.each(objects.rows, fn [sql] -> query!(transaction, sql) end)

    if query!(transaction, "PRAGMA foreign_key_check").rows != [] do
      raise "desktop request migration failed foreign-key validation"
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
