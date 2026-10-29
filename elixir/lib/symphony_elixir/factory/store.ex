defmodule SymphonyElixir.Factory.Store do
  @moduledoc """
  Durable SQLite storage for factory coordination state.

  The schema intentionally remains compatible with the original Python
  `factoryctl.py` database so the Elixir runtime can take over without losing
  leases, run ownership, or model-route history.
  """

  alias Exqlite.Result
  alias SymphonyElixir.Factory.WorkerFileIO

  @mr_presend_table """
  CREATE TABLE IF NOT EXISTS ticket_mr_presend_consumptions (
    request_key TEXT PRIMARY KEY REFERENCES ticket_mr_claims(request_key),
    claim_sha256 TEXT NOT NULL,
    payload_sha256 TEXT NOT NULL,
    broker_thread_id TEXT NOT NULL,
    native_call_id TEXT NOT NULL,
    proof_json TEXT NOT NULL,
    proof_sha256 TEXT NOT NULL,
    consumed_at TEXT NOT NULL,
    UNIQUE(broker_thread_id, native_call_id)
  )
  """

  @push_prepared_requalification_table """
  CREATE TABLE IF NOT EXISTS ticket_push_prepared_requalifications (
    authorization_key TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(run_id),
    original_nonce TEXT NOT NULL,
    original_envelope TEXT NOT NULL,
    original_sha256 TEXT NOT NULL,
    authorization_json TEXT NOT NULL,
    authorization_sha256 TEXT NOT NULL,
    proof_json TEXT NOT NULL,
    proof_sha256 TEXT NOT NULL,
    successor_nonce TEXT NOT NULL UNIQUE,
    successor_binding_json TEXT NOT NULL,
    successor_binding_sha256 TEXT NOT NULL,
    successor_reservation_key TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    UNIQUE(run_id, original_nonce)
  )
  """

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
      snapshot_json TEXT NOT NULL,
      decisions_json TEXT NOT NULL DEFAULT '{}'
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

    with :ok <- SymphonyElixir.Factory.NativeRuntimeCompatibility.check_database(database) do
      start_compatible_store(opts, database)
    end
  end

  defp start_compatible_store(opts, database) do
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

    connection_opts =
      [database: database, mode: :readonly, default_transaction_mode: :deferred, busy_timeout: Keyword.get(opts, :busy_timeout, 30_000)]
      |> Keyword.merge(Keyword.take(opts, [:name]))

    with true <- is_binary(database) and Path.type(database) == :absolute,
         {:ok, %File.Stat{type: :regular}} <- File.lstat(database),
         {:ok, %File.Stat{type: :directory}} <- File.stat(Path.dirname(database)),
         :ok <- SymphonyElixir.Factory.NativeRuntimeCompatibility.check_database(database),
         {:ok, connection} <- Exqlite.start_link(connection_opts) do
      validate_reader(connection)
    else
      {:error, reason} = error when reason in [:unsupported_native_runtime_history, :native_runtime_history_unreadable] -> error
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

    expected =
      MapSet.union(
        expected,
        MapSet.new(
          ~w(ticket_ci_repair_diagnoses ticket_ci_repair_claims ticket_ci_generation_intents ticket_ci_generation_events ticket_push_input_retirements worker_instruction_snapshots worker_instruction_task_bindings ticket_ci_repair_reassessments ticket_mr_qualifications ticket_ci_repair_evidence_successors)
        )
      )

    if mr_presend_current?(connection, versions) and
         MapSet.subset?(MapSet.new(~w(ticket_human_empty_commit_imports ticket_push_rejection_retirements ticket_ordinary_generation_intents ticket_ordinary_generation_events)), tables) and
         MapSet.subset?(expected, tables) and reader_structure_present?(connection) and
         reader_indexes_present?(connection) and recovery_triggers_present?(connection),
       do: :ok,
       else: {:error, :factory_ledger_schema_not_current}
  rescue
    Exqlite.Error -> {:error, :factory_ledger_schema_not_current}
  end

  defp reader_structure_present?(connection) do
    successor_sql = one!(connection, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_evidence_successors'")["sql"]

    reader_columns_present?(connection) and ci_claim_definition?(one!(connection, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"], :identity) and
      is_binary(successor_sql) and String.contains?(successor_sql, "attempt_index BETWEEN 2 AND 10") and String.contains?(successor_sql, "configured_limit BETWEEN 1 AND 10")
  end

  defp reader_indexes_present?(connection) do
    Enum.all?(~w(one_active_contract_amendment_per_run one_specialist_error_notice), fn name ->
      one!(connection, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", [name]) != nil
    end) and retirement_indexes_present?(connection) and rejection_indexes_present?(connection) and
      mr_qualification_indexes_present?(connection) and ci_successor_indexes_present?(connection)
  end

  defp ci_successor_indexes_present?(connection) do
    actual =
      query!(connection, "SELECT name FROM pragma_index_list('ticket_ci_repair_evidence_successors') WHERE \"unique\"=1").rows
      |> Enum.map(fn [name] -> query!(connection, "SELECT name FROM pragma_index_info(?) ORDER BY seqno", [name]).rows |> List.flatten() end)
      |> MapSet.new()

    expected = [~w(successor_key), ~w(prior_request_key), ~w(new_request_key), ~w(new_reservation_key), ~w(run_id attempt_index), ~w(claim_key evidence_content_sha256)]
    MapSet.equal?(MapSet.new(expected), actual)
  end

  defp mr_qualification_indexes_present?(connection) do
    actual =
      query!(connection, "SELECT name FROM pragma_index_list('ticket_mr_qualifications') WHERE \"unique\"=1").rows
      |> Enum.map(fn [name] -> query!(connection, "SELECT name FROM pragma_index_info(?) ORDER BY seqno", [name]).rows |> List.flatten() end)
      |> MapSet.new()

    MapSet.equal?(MapSet.new([~w(qualification_key), ~w(request_key)]), actual)
  end

  defp rejection_indexes_present?(connection) do
    actual =
      query!(connection, "SELECT name FROM pragma_index_list('ticket_push_rejection_retirements') WHERE \"unique\"=1").rows
      |> Enum.map(fn [name] -> query!(connection, "SELECT name FROM pragma_index_info(?) ORDER BY seqno", [name]).rows |> List.flatten() end)
      |> MapSet.new()

    MapSet.equal?(MapSet.new([~w(retirement_key), ~w(successor_nonce), ~w(successor_reservation_key), ~w(run_id candidate_sha code_repair_round claim_key), ~w(run_id original_nonce)]), actual)
  end

  defp retirement_indexes_present?(connection) do
    actual =
      query!(connection, "SELECT name FROM pragma_index_list('ticket_push_input_retirements') WHERE \"unique\" = 1").rows
      |> Enum.map(fn [name] -> query!(connection, "SELECT name FROM pragma_index_info(?) ORDER BY seqno", [name]).rows |> List.flatten() end)
      |> MapSet.new()

    MapSet.equal?(
      MapSet.new([
        ["retirement_key"],
        ["successor_nonce"],
        ["successor_reservation_key"],
        ["run_id", "code_repair_round"],
        ["run_id", "original_nonce"]
      ]),
      actual
    )
  end

  defp recovery_triggers_present?(connection) do
    reassessment =
      ~w(ci_reassessment_update ci_reassessment_delete ci_reassessment_schema_rollback push_rejection_update push_rejection_delete push_rejection_schema_rollback mr_qualification_update mr_qualification_delete mr_qualification_schema_rollback)

    Enum.all?(
      ~w(ci_repair_five_rounds_schema_rollback ci_successor_update ci_successor_delete ci_successor_schema_rollback ci_successor_total_budget ci_claim_total_budget ci_ten_attempt_schema_rollback ci_round_identity_schema_rollback ticket_ordinary_generation_intents_update ticket_ordinary_generation_intents_delete ticket_ordinary_generation_events_update ticket_ordinary_generation_events_delete ordinary_generation_source_hold ordinary_generation_source_delete) ++
        ~w(mr_presend_update mr_presend_delete mr_presend_schema_rollback) ++
        reassessment ++
        ~w(human_empty_import_update human_empty_import_delete human_empty_import_schema_rollback) ++
        ~w(push_unknown_run_identity push_unknown_run_delete push_unknown_event_delete push_unknown_event_update push_unknown_schema_rollback mr_actor_audit_update mr_actor_audit_delete mr_actor_schema_rollback ci_repair_diagnosis_update ci_repair_diagnosis_delete ci_repair_claim_update ci_repair_claim_delete ci_repair_schema_rollback ci_generation_intent_update ci_generation_intent_delete ci_generation_event_update ci_generation_event_delete ci_generation_schema_rollback ci_generation_source_hold ci_generation_source_delete push_input_retirement_update push_input_retirement_delete push_input_retirement_schema_rollback worker_instruction_snapshot_update worker_instruction_snapshot_delete worker_instruction_task_binding_update worker_instruction_task_binding_delete worker_instruction_snapshot_schema_rollback),
      fn name ->
        one!(connection, "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?", [name]) != nil
      end
    )
  end

  defp reader_columns_present?(connection) do
    required = %{
      "ticket_ordinary_generation_intents" => ~w(intent_key run_id verifier_request_key request_key operation binding_json binding_sha256 created_at),
      "ticket_ordinary_generation_events" => ~w(event_key intent_key event_type path predecessor_key receipt_json receipt_sha256 created_at),
      "ticket_human_empty_commit_imports" => ~w(import_key run_id request_key candidate_sha proof_json proof_sha256 created_at),
      "ticket_ci_repair_evidence_successors" =>
        ~w(successor_key run_id claim_key prior_request_key prior_successor_key attempt_index configured_limit evidence_content_sha256 evidence_json evidence_sha256 proof_json proof_sha256 new_request_key new_reservation_key created_at),
      "ticket_mr_qualifications" =>
        ~w(qualification_key request_key run_id candidate_sha contract_sha256 spec_revision stage completed_push_sha256 request_sha256 output_sha256 binding_sha256 preimage_json preimage_sha256 observation_json observation_sha256 observed_at kind),
      "ticket_push_rejection_retirements" =>
        ~w(retirement_key run_id candidate_sha code_repair_round claim_key original_nonce original_envelope original_sha256 proof_json proof_sha256 successor_nonce successor_binding_sha256 successor_reservation_key created_at),
      "ticket_ci_repair_reassessments" =>
        ~w(reassessment_key diagnosis_key collector_version original_sha256 run_id candidate_sha pipeline_id preimage_json preimage_sha256 diagnosis_json diagnosis_sha256 verdict created_at kind),
      "worker_instruction_snapshots" => ~w(binding_sha256 run_id role binding_json bundle_json bundle_sha256 created_at),
      "worker_instruction_task_bindings" => ~w(task_key prompt_sha256 instruction_binding_sha256 run_id role created_at),
      "ticket_push_input_retirements" =>
        ~w(retirement_key run_id code_repair_round original_nonce original_envelope original_sha256 proof_json proof_sha256 successor_nonce successor_binding_sha256 successor_reservation_key created_at),
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
      "ticket_mr_presend_consumptions" => ~w(request_key claim_sha256 payload_sha256 broker_thread_id native_call_id proof_json proof_sha256 consumed_at),
      "ticket_mr_actor_bindings" => ~w(request_key operation original_request_json original_request_sha256 original_payload_sha256 pinned_payload_sha256 proof_json proof_sha256 created_at),
      "events" => ~w(id run_id event_type payload_json occurred_at),
      "intake_snapshots" => ~w(scope observed_at snapshot_json decisions_json)
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
    ensure_active_run_indexes(connection)
    ensure_columns(connection, "runs", @model_run_columns)
    ensure_columns(connection, "control", @control_columns)
    ensure_columns(connection, "factory_tasks", @task_columns)
    ensure_columns(connection, "desktop_requests", @desktop_request_columns)
    ensure_columns(connection, "intake_snapshots", %{"decisions_json" => "TEXT NOT NULL DEFAULT '{}'"})
    query!(connection, "CREATE UNIQUE INDEX IF NOT EXISTS one_specialist_error_notice ON events(run_id, json_extract(payload_json, '$.notice_id')) WHERE event_type = 'SPECIALIST_ERROR_RECORDED'")

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
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (38, ?)", [iso_now()])
    migrate_push_unknown_guards(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (39, ?)", [iso_now()])
    migrate_mr_actor_bindings(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (40, ?)", [iso_now()])
    migrate_ci_repair_receipts(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (41, ?)", [iso_now()])
    migrate_push_input_retirements(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (42, ?)", [iso_now()])
    migrate_worker_instruction_snapshots(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (43, ?)", [iso_now()])
    migrate_ci_reassessments(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (44, ?)", [iso_now()])
    migrate_push_rejections(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (45, ?)", [iso_now()])
    migrate_mr_qualifications(connection)
    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version, applied_at) VALUES (46, ?)", [iso_now()])
    migrate_ci_claim_rounds(connection)
    migrate_ci_evidence_successors(connection)
    migrate_ci_seven_attempts(connection)
    migrate_human_empty_commit_imports(connection)
    migrate_ten_attempts_and_ordinary_generation(connection)
    migrate_mr_presend_consumptions(connection)
    migrate_push_prepared_requalifications(connection)
    migrate_ci_round_identity(connection)

    :ok
  end

  defp migrate_mr_presend_consumptions(connection) do
    unless one!(connection, "SELECT version FROM factory_schema_migrations WHERE version=52") do
      transaction!(connection, fn tx ->
        query!(tx, @mr_presend_table)

        install_mr_presend_triggers(tx)

        query!(tx, "INSERT OR IGNORE INTO factory_schema_migrations(version,applied_at) VALUES(52,?)", [iso_now()])
      end)
    end

    if not mr_presend_structure?(connection), do: raise("MR pre-send consumption schema invalid")
  end

  defp install_mr_presend_triggers(tx) do
    for operation <- ~w(UPDATE DELETE) do
      query!(
        tx,
        "CREATE TRIGGER IF NOT EXISTS mr_presend_#{String.downcase(operation)} BEFORE #{operation} ON ticket_mr_presend_consumptions BEGIN SELECT RAISE(ABORT,'mr_presend_immutable'); END"
      )
    end

    query!(
      tx,
      "CREATE TRIGGER IF NOT EXISTS mr_presend_schema_rollback BEFORE DELETE ON factory_schema_migrations WHEN OLD.version=52 AND EXISTS(SELECT 1 FROM ticket_mr_presend_consumptions) BEGIN SELECT RAISE(ABORT,'mr_presend_schema_required'); END"
    )
  end

  defp mr_presend_structure?(connection) do
    actual = one!(connection, "SELECT sql FROM sqlite_master WHERE type='table' AND name='ticket_mr_presend_consumptions'")
    is_map(actual) and normalize_presend_sql(actual["sql"]) == normalize_presend_sql(@mr_presend_table)
  end

  defp mr_presend_current?(connection, versions) do
    versions == Enum.map(1..54, &[&1]) and mr_presend_structure?(connection) and push_prepared_requalification_structure?(connection)
  end

  defp migrate_ci_round_identity(connection) do
    unless one!(connection, "SELECT version FROM factory_schema_migrations WHERE version=54") do
      migrate_ci_round_identity_checked(connection)
    end

    unless ci_claim_definition?(one!(connection, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"], :identity),
      do: raise("CI repair round identity schema invalid")
  end

  defp migrate_ci_round_identity_checked(%DBConnection{conn_mode: :transaction}),
    do: raise("CI round identity migration requires an outer connection checkout")

  defp migrate_ci_round_identity_checked(connection) do
    DBConnection.run(connection, fn leased ->
      original = Map.new(~w(foreign_keys legacy_alter_table), &{&1, one!(leased, "PRAGMA #{&1}")[&1]})

      try do
        query!(leased, "PRAGMA foreign_keys=OFF")
        query!(leased, "PRAGMA legacy_alter_table=ON")
        if one!(leased, "PRAGMA foreign_keys")["foreign_keys"] != 0, do: raise("CI round identity migration failed to disable foreign keys")

        transaction!(
          leased,
          fn tx ->
            unless one!(tx, "SELECT version FROM factory_schema_migrations WHERE version=54") do
              unless ci_claim_definition?(one!(tx, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"], 10),
                do: raise("CI round identity migration requires the exact prior schema")

              widen_ci_attempt_table(tx, "ticket_ci_repair_claims", [{"round BETWEEN 1 AND 10", "round >= 1"}])
              unless query!(tx, "PRAGMA foreign_key_check").rows == [], do: raise("CI round identity migration failed foreign-key validation")
              query!(tx, "INSERT INTO factory_schema_migrations(version,applied_at) VALUES(54,?)", [iso_now()])

              query!(tx, """
              CREATE TRIGGER ci_round_identity_schema_rollback BEFORE DELETE ON factory_schema_migrations
              WHEN OLD.version=54
              BEGIN SELECT RAISE(ABORT,'CI round identity schema required'); END
              """)
            end
          end,
          mode: :immediate
        )
      after
        restore_ci_claim_pragmas(connection, leased, original)
      end
    end)
  end

  defp migrate_push_prepared_requalifications(connection) do
    transaction!(connection, fn tx ->
      unless one!(tx, "SELECT version FROM factory_schema_migrations WHERE version=53") do
        query!(tx, @push_prepared_requalification_table)
        Enum.each(push_prepared_requalification_triggers(), &query!(tx, &1))
        query!(tx, "INSERT INTO factory_schema_migrations(version,applied_at) VALUES(53,?)", [iso_now()])
      end
    end)

    unless push_prepared_requalification_structure?(connection), do: raise("Prepared push requalification schema invalid")
  end

  defp push_prepared_requalification_structure?(connection) do
    actual = one!(connection, "SELECT sql FROM sqlite_master WHERE type='table' AND name='ticket_push_prepared_requalifications'")

    triggers =
      query!(
        connection,
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name IN ('push_prepared_requalification_update','push_prepared_requalification_delete','push_prepared_requalification_schema_rollback')"
      ).rows
      |> Enum.map(fn [sql] -> normalize_presend_sql(sql) end)
      |> Enum.sort()

    expected = push_prepared_requalification_triggers() |> Enum.map(&normalize_presend_sql/1) |> Enum.sort()

    is_map(actual) and
      normalize_presend_sql(actual["sql"]) == normalize_presend_sql(@push_prepared_requalification_table) and
      triggers == expected
  end

  defp push_prepared_requalification_triggers do
    Enum.map(~w(UPDATE DELETE), fn operation ->
      "CREATE TRIGGER push_prepared_requalification_#{String.downcase(operation)} BEFORE #{operation} ON ticket_push_prepared_requalifications BEGIN SELECT RAISE(ABORT,'push_prepared_requalification_immutable'); END"
    end) ++
      [
        "CREATE TRIGGER push_prepared_requalification_schema_rollback BEFORE DELETE ON factory_schema_migrations WHEN OLD.version=53 AND EXISTS(SELECT 1 FROM ticket_push_prepared_requalifications) BEGIN SELECT RAISE(ABORT,'push_prepared_requalification_schema_required'); END"
      ]
  end

  defp normalize_presend_sql(sql) do
    sql |> String.replace(~r/IF\s+NOT\s+EXISTS\s+/i, "") |> String.replace(~r/\s+/, "") |> String.trim_trailing(";")
  end

  defp migrate_ten_attempts_and_ordinary_generation(connection) do
    unless one!(connection, "SELECT version FROM factory_schema_migrations WHERE version=51") do
      migrate_ten_attempts_checked(connection)
    end
  end

  defp migrate_ten_attempts_checked(%DBConnection{conn_mode: :transaction}),
    do: raise("CI attempt migration requires an outer connection checkout")

  defp migrate_ten_attempts_checked(connection) do
    DBConnection.run(connection, fn leased ->
      original = Map.new(~w(foreign_keys legacy_alter_table), &{&1, one!(leased, "PRAGMA #{&1}")[&1]})

      try do
        query!(leased, "PRAGMA foreign_keys=OFF")
        query!(leased, "PRAGMA legacy_alter_table=ON")
        if one!(leased, "PRAGMA foreign_keys")["foreign_keys"] != 0, do: raise("CI attempt migration failed to disable foreign keys")

        transaction!(
          leased,
          fn tx ->
            if is_nil(one!(tx, "SELECT version FROM factory_schema_migrations WHERE version=51")) do
              widen_ci_attempt_table(tx, "ticket_ci_repair_claims", [{"round BETWEEN 1 AND 7", "round BETWEEN 1 AND 10"}])

              widen_ci_attempt_table(tx, "ticket_ci_repair_evidence_successors", [
                {"attempt_index BETWEEN 2 AND 7", "attempt_index BETWEEN 2 AND 10"},
                {"configured_limit BETWEEN 1 AND 7", "configured_limit BETWEEN 1 AND 10"}
              ])

              query!(tx, "DROP TRIGGER ci_claim_total_budget")

              query!(tx, """
              CREATE TRIGGER ci_claim_total_budget BEFORE INSERT ON ticket_ci_repair_claims
              WHEN (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=NEW.run_id) +
                   (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=NEW.run_id) >= 10
              BEGIN SELECT RAISE(ABORT,'CI repair attempt budget exhausted'); END
              """)

              create_ordinary_generation_journal(tx)
              unless query!(tx, "PRAGMA foreign_key_check").rows == [], do: raise("CI attempt migration failed foreign-key validation")
              query!(tx, "INSERT INTO factory_schema_migrations(version,applied_at) VALUES(51,?)", [iso_now()])

              query!(tx, """
              CREATE TRIGGER ci_ten_attempt_schema_rollback BEFORE DELETE ON factory_schema_migrations
              WHEN OLD.version=51
              BEGIN SELECT RAISE(ABORT,'CI ten-attempt schema required'); END
              """)
            end
          end,
          mode: :immediate
        )
      after
        restore_ci_claim_pragmas(connection, leased, original)
      end
    end)
  end

  defp create_ordinary_generation_journal(connection) do
    query!(connection, """
    CREATE TABLE ticket_ordinary_generation_intents (
      intent_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      verifier_request_key TEXT NOT NULL REFERENCES worker_evidence(request_key),
      request_key TEXT NOT NULL REFERENCES worker_evidence(request_key),
      operation TEXT NOT NULL CHECK(operation IN ('GAZELLE_DIFF', 'GOFMT_DIFF')),
      binding_json TEXT NOT NULL, binding_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(request_key, operation)
    )
    """)

    query!(connection, """
    CREATE TABLE ticket_ordinary_generation_events (
      event_key TEXT PRIMARY KEY,
      intent_key TEXT NOT NULL REFERENCES ticket_ordinary_generation_intents(intent_key),
      event_type TEXT NOT NULL CHECK(event_type IN ('EXECUTION_PREPARED','EXECUTION_STARTED','EXECUTION_RECEIPT','APPLY_PREPARED','APPLY_STARTED','APPLY_CREATED','APPLIED','BLOCKED','UNCERTAIN','FINALIZED')),
      path TEXT NOT NULL,
      predecessor_key TEXT REFERENCES ticket_ordinary_generation_events(event_key),
      receipt_json TEXT NOT NULL, receipt_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(intent_key, event_type, path)
    )
    """)

    for table <- ~w(ticket_ordinary_generation_intents ticket_ordinary_generation_events), action <- ~w(UPDATE DELETE) do
      query!(connection, "CREATE TRIGGER #{table}_#{String.downcase(action)} BEFORE #{action} ON #{table} BEGIN SELECT RAISE(ABORT,'ordinary_generation_receipt_immutable'); END")
    end

    query!(connection, """
    CREATE TRIGGER ordinary_generation_source_hold BEFORE UPDATE ON workspace_access
    WHEN OLD.mode='SOURCE' AND OLD.released_at IS NULL AND EXISTS (
      SELECT 1 FROM ticket_ordinary_generation_intents i WHERE i.request_key=OLD.request_key AND NOT EXISTS (
        SELECT 1 FROM ticket_ordinary_generation_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path=''
      )
    )
    BEGIN SELECT RAISE(ABORT,'ordinary_generation_source_required'); END
    """)

    query!(connection, """
    CREATE TRIGGER ordinary_generation_source_delete BEFORE DELETE ON workspace_access
    WHEN OLD.mode='SOURCE' AND EXISTS (SELECT 1 FROM ticket_ordinary_generation_intents i WHERE i.request_key=OLD.request_key)
    BEGIN SELECT RAISE(ABORT,'ordinary_generation_source_required'); END
    """)
  end

  defp migrate_human_empty_commit_imports(connection) do
    transaction!(connection, fn tx ->
      query!(tx, """
      CREATE TABLE IF NOT EXISTS ticket_human_empty_commit_imports (
        import_key TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(run_id),
        request_key TEXT NOT NULL UNIQUE REFERENCES desktop_requests(request_key),
        candidate_sha TEXT NOT NULL,
        proof_json TEXT NOT NULL,
        proof_sha256 TEXT NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(run_id, candidate_sha)
      )
      """)

      for operation <- ~w(UPDATE DELETE) do
        query!(
          tx,
          "CREATE TRIGGER IF NOT EXISTS human_empty_import_#{String.downcase(operation)} BEFORE #{operation} ON ticket_human_empty_commit_imports BEGIN SELECT RAISE(ABORT,'human_empty_import_immutable'); END"
        )
      end

      query!(tx, "INSERT OR IGNORE INTO factory_schema_migrations(version,applied_at) VALUES(50,?)", [iso_now()])

      query!(tx, """
      CREATE TRIGGER IF NOT EXISTS human_empty_import_schema_rollback BEFORE DELETE ON factory_schema_migrations
      WHEN OLD.version=50 AND EXISTS(SELECT 1 FROM ticket_human_empty_commit_imports)
      BEGIN SELECT RAISE(ABORT,'human_empty_import_history_present'); END
      """)
    end)
  end

  defp migrate_ci_evidence_successors(connection) do
    transaction!(connection, &create_ci_evidence_successors/1, mode: :immediate)
  end

  defp create_ci_evidence_successors(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_ci_repair_evidence_successors (
      successor_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      claim_key TEXT NOT NULL REFERENCES ticket_ci_repair_claims(claim_key),
      prior_request_key TEXT NOT NULL UNIQUE REFERENCES worker_evidence(request_key),
      prior_successor_key TEXT REFERENCES ticket_ci_repair_evidence_successors(successor_key),
      attempt_index INTEGER NOT NULL CHECK(attempt_index BETWEEN 2 AND 5),
      configured_limit INTEGER NOT NULL CHECK(configured_limit BETWEEN 1 AND 5),
      evidence_content_sha256 TEXT NOT NULL,
      evidence_json TEXT NOT NULL, evidence_sha256 TEXT NOT NULL,
      proof_json TEXT NOT NULL, proof_sha256 TEXT NOT NULL,
      new_request_key TEXT NOT NULL UNIQUE,
      new_reservation_key TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      UNIQUE(run_id, attempt_index), UNIQUE(claim_key, evidence_content_sha256)
    )
    """)

    for {name, operation} <- [{"ci_successor_update", "UPDATE"}, {"ci_successor_delete", "DELETE"}] do
      query!(connection, "CREATE TRIGGER IF NOT EXISTS #{name} BEFORE #{operation} ON ticket_ci_repair_evidence_successors BEGIN SELECT RAISE(ABORT,'CI evidence successor immutable'); END")
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_successor_total_budget BEFORE INSERT ON ticket_ci_repair_evidence_successors
    WHEN NEW.attempt_index != (SELECT COUNT(*)+1 FROM ticket_ci_repair_claims WHERE run_id=NEW.run_id) +
                              (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=NEW.run_id)
      OR NEW.attempt_index > NEW.configured_limit
      OR NOT EXISTS(SELECT 1 FROM ticket_ci_repair_claims WHERE claim_key=NEW.claim_key AND run_id=NEW.run_id)
    BEGIN SELECT RAISE(ABORT,'CI repair attempt budget changed'); END
    """)

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_claim_total_budget BEFORE INSERT ON ticket_ci_repair_claims
    WHEN (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=NEW.run_id) +
         (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=NEW.run_id) >= 5
    BEGIN SELECT RAISE(ABORT,'CI repair attempt budget exhausted'); END
    """)

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_successor_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version=48 AND EXISTS(SELECT 1 FROM ticket_ci_repair_evidence_successors)
    BEGIN SELECT RAISE(ABORT,'CI evidence successor schema required'); END
    """)

    query!(connection, "INSERT OR IGNORE INTO factory_schema_migrations(version,applied_at) VALUES(48,?)", [iso_now()])
  end

  defp migrate_ci_claim_rounds(connection) do
    sql = one!(connection, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"]

    unless (ci_claim_definition?(sql, 5) or ci_claim_definition?(sql, 7) or ci_claim_definition?(sql, 10) or
              (ci_claim_definition?(sql, :identity) and not is_nil(one!(connection, "SELECT version FROM factory_schema_migrations WHERE version=54")))) and
             one!(connection, "SELECT version FROM factory_schema_migrations WHERE version=47") do
      migrate_ci_claim_rounds_checked(connection)
    end
  end

  defp migrate_ci_seven_attempts(connection) do
    unless one!(connection, "SELECT version FROM factory_schema_migrations WHERE version=49") do
      migrate_ci_seven_attempts_checked(connection)
    end
  end

  defp migrate_ci_seven_attempts_checked(%DBConnection{conn_mode: :transaction}),
    do: raise("CI attempt migration requires an outer connection checkout")

  defp migrate_ci_seven_attempts_checked(connection) do
    DBConnection.run(connection, fn leased ->
      original = Map.new(~w(foreign_keys legacy_alter_table), &{&1, one!(leased, "PRAGMA #{&1}")[&1]})

      try do
        query!(leased, "PRAGMA foreign_keys=OFF")
        query!(leased, "PRAGMA legacy_alter_table=ON")
        if one!(leased, "PRAGMA foreign_keys")["foreign_keys"] != 0, do: raise("CI attempt migration failed to disable foreign keys")

        transaction!(
          leased,
          fn tx ->
            if is_nil(one!(tx, "SELECT version FROM factory_schema_migrations WHERE version=49")) do
              widen_ci_attempt_table(tx, "ticket_ci_repair_claims", [{"round BETWEEN 1 AND 5", "round BETWEEN 1 AND 7"}])

              widen_ci_attempt_table(tx, "ticket_ci_repair_evidence_successors", [
                {"attempt_index BETWEEN 2 AND 5", "attempt_index BETWEEN 2 AND 7"},
                {"configured_limit BETWEEN 1 AND 5", "configured_limit BETWEEN 1 AND 7"}
              ])

              query!(tx, "DROP TRIGGER ci_claim_total_budget")

              query!(tx, """
              CREATE TRIGGER ci_claim_total_budget BEFORE INSERT ON ticket_ci_repair_claims
              WHEN (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=NEW.run_id) +
                   (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=NEW.run_id) >= 7
              BEGIN SELECT RAISE(ABORT,'CI repair attempt budget exhausted'); END
              """)

              unless query!(tx, "PRAGMA foreign_key_check").rows == [], do: raise("CI attempt migration failed foreign-key validation")
              query!(tx, "INSERT INTO factory_schema_migrations(version,applied_at) VALUES(49,?)", [iso_now()])

              query!(tx, """
              CREATE TRIGGER ci_seven_attempt_schema_rollback BEFORE DELETE ON factory_schema_migrations
              WHEN OLD.version=49
              BEGIN SELECT RAISE(ABORT,'CI seven-attempt schema required'); END
              """)
            end
          end,
          mode: :immediate
        )
      after
        restore_ci_claim_pragmas(connection, leased, original)
      end
    end)
  end

  defp widen_ci_attempt_table(tx, table, replacements) do
    sql = one!(tx, "SELECT sql FROM sqlite_master WHERE name=?", [table])["sql"]
    before = query!(tx, "SELECT rowid,* FROM #{table} ORDER BY rowid").rows
    objects = query!(tx, "SELECT sql FROM sqlite_master WHERE tbl_name=? AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY name", [table]).rows

    widened =
      Enum.reduce(replacements, sql, fn {old, new}, current ->
        unless length(String.split(current, old)) == 2, do: raise("CI attempt migration requires the exact prior bounds")
        String.replace(current, old, new, global: false)
      end)

    create = Regex.replace(~r/\ACREATE TABLE (?:"#{table}"|#{table})/, widened, "CREATE TABLE #{table}_upgrade49")
    if create == widened, do: raise("CI attempt migration requires the exact prior table")
    query!(tx, create)
    query!(tx, "INSERT INTO #{table}_upgrade49(rowid,#{Enum.map_join(query!(tx, "PRAGMA table_info(#{table})").rows, ",", &Enum.at(&1, 1))}) SELECT rowid,* FROM #{table}")
    query!(tx, "DROP TABLE #{table}")
    query!(tx, "ALTER TABLE #{table}_upgrade49 RENAME TO #{table}")
    for [statement] <- objects, do: query!(tx, statement)
    unless query!(tx, "SELECT rowid,* FROM #{table} ORDER BY rowid").rows == before, do: raise("CI attempt migration changed receipt bytes")
  end

  defp migrate_ci_claim_rounds_checked(%DBConnection{conn_mode: :transaction}),
    do: raise("CI claim migration requires an outer connection checkout")

  defp migrate_ci_claim_rounds_checked(connection) do
    DBConnection.run(connection, fn leased ->
      original = Map.new(~w(foreign_keys legacy_alter_table), &{&1, one!(leased, "PRAGMA #{&1}")[&1]})

      try do
        query!(leased, "PRAGMA foreign_keys=OFF")
        query!(leased, "PRAGMA legacy_alter_table=ON")
        if one!(leased, "PRAGMA foreign_keys")["foreign_keys"] != 0, do: raise("CI claim migration failed to disable foreign keys")
        transaction!(leased, &rebuild_ci_claim_rounds/1, mode: :immediate)
      after
        restore_ci_claim_pragmas(connection, leased, original)
      end
    end)
  end

  defp restore_ci_claim_pragmas(connection, leased, original) do
    for {name, value} <- original, do: query!(leased, "PRAGMA #{name}=#{value}")

    for {name, value} <- original do
      if one!(leased, "PRAGMA #{name}")[name] != value, do: raise("CI claim migration failed to restore connection settings")
    end
  rescue
    error ->
      DBConnection.disconnect_all(connection, 0)
      reraise error, __STACKTRACE__
  end

  defp rebuild_ci_claim_rounds(tx) do
    sql = one!(tx, "SELECT sql FROM sqlite_master WHERE name='ticket_ci_repair_claims'")["sql"]

    unless ci_claim_definition?(sql, 5) do
      unless ci_claim_definition?(sql, 2), do: raise("CI claim migration requires the exact prior schema")
      before = query!(tx, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows
      objects = query!(tx, "SELECT sql FROM sqlite_master WHERE tbl_name='ticket_ci_repair_claims' AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY name").rows
      create = ci_claim_sql(5) |> String.replace("CREATE TABLE ticket_ci_repair_claims", "CREATE TABLE ticket_ci_repair_claims_upgrade", global: false)
      query!(tx, create)
      query!(tx, "INSERT INTO ticket_ci_repair_claims_upgrade(rowid,claim_key,diagnosis_key,run_id,round,claim_json,claim_sha256,created_at) SELECT rowid,* FROM ticket_ci_repair_claims")
      query!(tx, "DROP TABLE ticket_ci_repair_claims")
      query!(tx, "ALTER TABLE ticket_ci_repair_claims_upgrade RENAME TO ticket_ci_repair_claims")
      for [statement] <- objects, do: query!(tx, statement)
      unless query!(tx, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows == before, do: raise("CI claim migration changed receipt bytes")
    end

    unless query!(tx, "PRAGMA foreign_key_check").rows == [], do: raise("CI claim migration failed foreign-key validation")

    query!(tx, """
    CREATE TRIGGER IF NOT EXISTS ci_repair_five_rounds_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version=47 AND EXISTS(SELECT 1 FROM ticket_ci_repair_claims)
    BEGIN SELECT RAISE(ABORT,'ci_repair_five_rounds_schema_required'); END
    """)

    query!(tx, "INSERT OR IGNORE INTO factory_schema_migrations(version,applied_at) VALUES(47,?)", [iso_now()])
    :ok
  end

  defp ci_claim_definition?(sql, rounds) when is_binary(sql) do
    expected = ci_claim_sql(rounds) |> String.trim()
    String.trim(sql) in [expected, String.replace(expected, "CREATE TABLE ticket_ci_repair_claims", ~s(CREATE TABLE "ticket_ci_repair_claims"), global: false)]
  end

  defp ci_claim_definition?(_, _), do: false

  defp ci_claim_sql(:identity), do: String.replace(ci_claim_sql(10), "round BETWEEN 1 AND 10", "round >= 1", global: false)

  defp ci_claim_sql(rounds) do
    """
    CREATE TABLE ticket_ci_repair_claims (
      claim_key TEXT PRIMARY KEY,
      diagnosis_key TEXT NOT NULL UNIQUE REFERENCES ticket_ci_repair_diagnoses(diagnosis_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      round INTEGER NOT NULL CHECK(round BETWEEN 1 AND #{rounds}),
      claim_json TEXT NOT NULL, claim_sha256 TEXT NOT NULL, created_at TEXT NOT NULL,
      UNIQUE(run_id, round)
    )
    """
  end

  defp migrate_mr_qualifications(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_mr_qualifications (
      qualification_key TEXT PRIMARY KEY, request_key TEXT NOT NULL UNIQUE REFERENCES desktop_requests(request_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id), candidate_sha TEXT NOT NULL,
      contract_sha256 TEXT NOT NULL, spec_revision INTEGER NOT NULL, stage TEXT NOT NULL,
      completed_push_sha256 TEXT NOT NULL, request_sha256 TEXT NOT NULL, output_sha256 TEXT NOT NULL,
      binding_sha256 TEXT NOT NULL, preimage_json TEXT NOT NULL, preimage_sha256 TEXT NOT NULL,
      observation_json TEXT NOT NULL, observation_sha256 TEXT NOT NULL, observed_at TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind='MR_OBSERVATION_V1')
    )
    """)

    for operation <- ~w(UPDATE DELETE) do
      query!(
        connection,
        "CREATE TRIGGER IF NOT EXISTS mr_qualification_#{String.downcase(operation)} BEFORE #{operation} ON ticket_mr_qualifications BEGIN SELECT RAISE(ABORT,'mr_qualification_immutable'); END"
      )
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS mr_qualification_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version=46 AND EXISTS(SELECT 1 FROM ticket_mr_qualifications)
    BEGIN SELECT RAISE(ABORT,'mr_qualification_schema_required'); END
    """)
  end

  defp migrate_push_rejections(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_push_rejection_retirements (
      retirement_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id), candidate_sha TEXT NOT NULL,
      code_repair_round INTEGER NOT NULL, claim_key TEXT NOT NULL REFERENCES ticket_ci_repair_claims(claim_key),
      original_nonce TEXT NOT NULL, original_envelope TEXT NOT NULL, original_sha256 TEXT NOT NULL,
      proof_json TEXT NOT NULL, proof_sha256 TEXT NOT NULL,
      successor_nonce TEXT NOT NULL UNIQUE, successor_binding_sha256 TEXT NOT NULL,
      successor_reservation_key TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL,
      UNIQUE(run_id,candidate_sha,code_repair_round,claim_key), UNIQUE(run_id,original_nonce)
    )
    """)

    for operation <- ~w(UPDATE DELETE) do
      query!(
        connection,
        "CREATE TRIGGER IF NOT EXISTS push_rejection_#{String.downcase(operation)} BEFORE #{operation} ON ticket_push_rejection_retirements BEGIN SELECT RAISE(ABORT,'push_rejection_immutable'); END"
      )
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS push_rejection_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version=45 AND EXISTS(SELECT 1 FROM ticket_push_rejection_retirements)
    BEGIN SELECT RAISE(ABORT,'push_rejection_schema_required'); END
    """)
  end

  defp migrate_ci_reassessments(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_ci_repair_reassessments (
      reassessment_key TEXT PRIMARY KEY,
      diagnosis_key TEXT NOT NULL REFERENCES ticket_ci_repair_diagnoses(diagnosis_key),
      collector_version TEXT NOT NULL, original_sha256 TEXT NOT NULL,
      run_id TEXT NOT NULL REFERENCES runs(run_id), candidate_sha TEXT NOT NULL,
      pipeline_id INTEGER NOT NULL, preimage_json TEXT NOT NULL, preimage_sha256 TEXT NOT NULL,
      diagnosis_json TEXT NOT NULL, diagnosis_sha256 TEXT NOT NULL,
      verdict TEXT NOT NULL CHECK(verdict IN ('REPAIRABLE','BLOCKED')),
      created_at TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind='COLLECTOR_REASSESSMENT_V1'),
      UNIQUE(diagnosis_key, collector_version)
    )
    """)

    for operation <- ~w(UPDATE DELETE) do
      query!(
        connection,
        "CREATE TRIGGER IF NOT EXISTS ci_reassessment_#{String.downcase(operation)} BEFORE #{operation} ON ticket_ci_repair_reassessments BEGIN SELECT RAISE(ABORT,'ci_reassessment_immutable'); END"
      )
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_reassessment_schema_rollback
    BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version=44 AND EXISTS(SELECT 1 FROM ticket_ci_repair_reassessments)
    BEGIN SELECT RAISE(ABORT,'ci_reassessment_schema_rollback_forbidden'); END
    """)
  end

  defp migrate_worker_instruction_snapshots(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS worker_instruction_snapshots (
      binding_sha256 TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      role TEXT NOT NULL,
      binding_json TEXT NOT NULL,
      bundle_json TEXT NOT NULL,
      bundle_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """)

    query!(connection, """
    CREATE TABLE IF NOT EXISTS worker_instruction_task_bindings (
      task_key TEXT NOT NULL REFERENCES factory_tasks(task_key),
      prompt_sha256 TEXT NOT NULL,
      instruction_binding_sha256 TEXT NOT NULL REFERENCES worker_instruction_snapshots(binding_sha256),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      role TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY(task_key, prompt_sha256)
    )
    """)

    for {suffix, action} <- [{"update", "UPDATE"}, {"delete", "DELETE"}] do
      query!(
        connection,
        "CREATE TRIGGER IF NOT EXISTS worker_instruction_snapshot_#{suffix} BEFORE #{action} ON worker_instruction_snapshots BEGIN SELECT RAISE(ABORT, 'worker_instruction_snapshot_immutable'); END"
      )

      query!(
        connection,
        "CREATE TRIGGER IF NOT EXISTS worker_instruction_task_binding_#{suffix} BEFORE #{action} ON worker_instruction_task_bindings BEGIN SELECT RAISE(ABORT, 'worker_instruction_task_binding_immutable'); END"
      )
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS worker_instruction_snapshot_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version = 43 AND EXISTS (SELECT 1 FROM worker_instruction_snapshots)
    BEGIN SELECT RAISE(ABORT, 'worker_instruction_snapshot_schema_required'); END
    """)
  end

  defp migrate_push_input_retirements(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_push_input_retirements (
      retirement_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      code_repair_round INTEGER NOT NULL CHECK(code_repair_round >= 1),
      original_nonce TEXT NOT NULL,
      original_envelope TEXT NOT NULL,
      original_sha256 TEXT NOT NULL,
      proof_json TEXT NOT NULL,
      proof_sha256 TEXT NOT NULL,
      successor_nonce TEXT NOT NULL UNIQUE,
      successor_binding_sha256 TEXT NOT NULL,
      successor_reservation_key TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      UNIQUE(run_id, code_repair_round),
      UNIQUE(run_id, original_nonce)
    )
    """)

    for {name, operation} <- [{"push_input_retirement_update", "UPDATE"}, {"push_input_retirement_delete", "DELETE"}] do
      query!(connection, """
      CREATE TRIGGER IF NOT EXISTS #{name} BEFORE #{operation} ON ticket_push_input_retirements
      BEGIN SELECT RAISE(ABORT, 'push_input_retirement_immutable'); END
      """)
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS push_input_retirement_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version = 42 AND EXISTS (SELECT 1 FROM ticket_push_input_retirements)
    BEGIN SELECT RAISE(ABORT, 'push_input_retirement_schema_required'); END
    """)
  end

  defp migrate_ci_repair_receipts(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_ci_repair_diagnoses (
      diagnosis_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      candidate_sha TEXT NOT NULL,
      pipeline_id INTEGER NOT NULL,
      preimage_json TEXT NOT NULL, preimage_sha256 TEXT NOT NULL,
      diagnosis_json TEXT NOT NULL, diagnosis_sha256 TEXT NOT NULL,
      verdict TEXT NOT NULL CHECK(verdict IN ('REPAIRABLE', 'BLOCKED')),
      created_at TEXT NOT NULL,
      UNIQUE(run_id, candidate_sha, pipeline_id)
    )
    """)

    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_ci_repair_claims (
      claim_key TEXT PRIMARY KEY,
      diagnosis_key TEXT NOT NULL UNIQUE REFERENCES ticket_ci_repair_diagnoses(diagnosis_key),
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      round INTEGER NOT NULL CHECK(round BETWEEN 1 AND 2),
      claim_json TEXT NOT NULL, claim_sha256 TEXT NOT NULL, created_at TEXT NOT NULL,
      UNIQUE(run_id, round)
    )
    """)

    for {label, table} <- [{"diagnosis", "ticket_ci_repair_diagnoses"}, {"claim", "ticket_ci_repair_claims"}],
        {action, suffix} <- [{"UPDATE", "update"}, {"DELETE", "delete"}] do
      query!(connection, "CREATE TRIGGER IF NOT EXISTS ci_repair_#{label}_#{suffix} BEFORE #{action} ON #{table} BEGIN SELECT RAISE(ABORT, 'ci_repair_receipt_immutable'); END")
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_repair_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version = 41 AND EXISTS (SELECT 1 FROM ticket_ci_repair_diagnoses)
    BEGIN SELECT RAISE(ABORT, 'ci_repair_schema_required'); END
    """)

    migrate_ci_generation_journal(connection)
  end

  defp migrate_ci_generation_journal(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_ci_generation_intents (
      intent_key TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES runs(run_id),
      claim_key TEXT NOT NULL REFERENCES ticket_ci_repair_claims(claim_key),
      request_key TEXT NOT NULL REFERENCES worker_evidence(request_key),
      operation TEXT NOT NULL CHECK(operation IN ('GAZELLE_DIFF', 'GOFMT_DIFF')),
      binding_json TEXT NOT NULL, binding_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(request_key, operation)
    )
    """)

    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_ci_generation_events (
      event_key TEXT PRIMARY KEY,
      intent_key TEXT NOT NULL REFERENCES ticket_ci_generation_intents(intent_key),
      event_type TEXT NOT NULL CHECK(event_type IN ('EXECUTION_PREPARED','EXECUTION_STARTED','EXECUTION_RECEIPT','APPLY_PREPARED','APPLY_STARTED','APPLY_CREATED','APPLIED','BLOCKED','UNCERTAIN','FINALIZED')),
      path TEXT NOT NULL,
      predecessor_key TEXT REFERENCES ticket_ci_generation_events(event_key),
      receipt_json TEXT NOT NULL, receipt_sha256 TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(intent_key, event_type, path)
    )
    """)

    for {label, table} <- [{"intent", "ticket_ci_generation_intents"}, {"event", "ticket_ci_generation_events"}],
        {action, suffix} <- [{"UPDATE", "update"}, {"DELETE", "delete"}] do
      query!(connection, "CREATE TRIGGER IF NOT EXISTS ci_generation_#{label}_#{suffix} BEFORE #{action} ON #{table} BEGIN SELECT RAISE(ABORT, 'ci_generation_receipt_immutable'); END")
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_generation_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version = 41 AND EXISTS (SELECT 1 FROM ticket_ci_generation_intents)
    BEGIN SELECT RAISE(ABORT, 'ci_generation_schema_required'); END
    """)

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_generation_source_hold BEFORE UPDATE ON workspace_access
    WHEN OLD.mode = 'SOURCE' AND OLD.released_at IS NULL AND EXISTS (
      SELECT 1 FROM ticket_ci_generation_intents i
      WHERE i.request_key = OLD.request_key AND NOT EXISTS (
        SELECT 1 FROM ticket_ci_generation_events e
        WHERE e.intent_key = i.intent_key AND e.event_type = 'FINALIZED' AND e.path = ''
      )
    )
    BEGIN SELECT RAISE(ABORT, 'ci_generation_source_required'); END
    """)

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS ci_generation_source_delete BEFORE DELETE ON workspace_access
    WHEN OLD.mode = 'SOURCE' AND EXISTS (
      SELECT 1 FROM ticket_ci_generation_intents i WHERE i.request_key = OLD.request_key
    )
    BEGIN SELECT RAISE(ABORT, 'ci_generation_source_required'); END
    """)
  end

  defp migrate_mr_actor_bindings(connection) do
    query!(connection, """
    CREATE TABLE IF NOT EXISTS ticket_mr_actor_bindings (
      request_key TEXT PRIMARY KEY REFERENCES desktop_requests(request_key),
      operation TEXT NOT NULL CHECK(operation IN ('PREPARED','CORRECTED')),
      original_request_json TEXT NOT NULL, original_request_sha256 TEXT NOT NULL,
      original_payload_sha256 TEXT NOT NULL, pinned_payload_sha256 TEXT NOT NULL,
      proof_json TEXT NOT NULL, proof_sha256 TEXT NOT NULL, created_at TEXT NOT NULL
    )
    """)

    for {name, action} <- [{"mr_actor_audit_update", "UPDATE"}, {"mr_actor_audit_delete", "DELETE"}] do
      query!(connection, "CREATE TRIGGER IF NOT EXISTS #{name} BEFORE #{action} ON ticket_mr_actor_bindings BEGIN SELECT RAISE(ABORT, 'mr_actor_audit_immutable'); END")
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS mr_actor_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version = 40 AND EXISTS (SELECT 1 FROM ticket_mr_actor_bindings)
    BEGIN SELECT RAISE(ABORT, 'mr_actor_audit_schema_required'); END
    """)
  end

  defp migrate_push_unknown_guards(connection) do
    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS push_unknown_run_identity BEFORE UPDATE ON runs
    WHEN EXISTS (SELECT 1 FROM events WHERE run_id = OLD.run_id AND event_type = 'TICKET_PUSH_UNKNOWN_HAZARD')
      AND (NEW.run_id IS NOT OLD.run_id OR NEW.repo_key IS NOT OLD.repo_key OR NEW.repo_path IS NOT OLD.repo_path OR NEW.worktree IS NOT OLD.worktree
        OR NEW.branch IS NOT OLD.branch OR NEW.base_branch IS NOT OLD.base_branch
        OR (NEW.candidate_sha IS NOT OLD.candidate_sha AND NOT EXISTS (
          SELECT 1 FROM events lineage JOIN events hazard ON hazard.run_id = lineage.run_id
          WHERE lineage.run_id = OLD.run_id AND lineage.event_type = 'TICKET_PUSH_DESCENDANT_PROVEN'
            AND hazard.event_type = 'TICKET_PUSH_UNKNOWN_HAZARD'
            AND json_extract(lineage.payload_json, '$.hazard_sha256') = json_extract(hazard.payload_json, '$.sha256')
            AND json_extract(lineage.payload_json, '$.from_sha') IS OLD.candidate_sha
            AND json_extract(lineage.payload_json, '$.to_sha') IS NEW.candidate_sha
            AND json_extract(lineage.payload_json, '$.branch') IS OLD.branch
            AND json_extract(lineage.payload_json, '$.worktree') IS OLD.worktree
            AND json_extract(lineage.payload_json, '$.contract_sha256') IS OLD.contract_sha256
            AND json_extract(lineage.payload_json, '$.spec_revision') IS OLD.spec_revision
            AND json_extract(lineage.payload_json, '$.handoff') IS OLD.candidate_handoff)))
    BEGIN SELECT RAISE(ABORT, 'push_unknown_hazard_mutation_unproven'); END
    """)

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS push_unknown_run_delete BEFORE DELETE ON runs
    WHEN EXISTS (SELECT 1 FROM events WHERE run_id = OLD.run_id AND event_type = 'TICKET_PUSH_UNKNOWN_HAZARD')
    BEGIN SELECT RAISE(ABORT, 'push_unknown_hazard_delete_unproven'); END
    """)

    for {name, operation} <- [{"push_unknown_event_delete", "DELETE"}, {"push_unknown_event_update", "UPDATE"}] do
      query!(connection, """
      CREATE TRIGGER IF NOT EXISTS #{name} BEFORE #{operation} ON events
      WHEN OLD.event_type IN ('TICKET_PUSH_UNKNOWN_HAZARD', 'TICKET_PUSH_DESCENDANT_PROVEN')
      BEGIN SELECT RAISE(ABORT, 'push_unknown_history_immutable'); END
      """)
    end

    query!(connection, """
    CREATE TRIGGER IF NOT EXISTS push_unknown_schema_rollback BEFORE DELETE ON factory_schema_migrations
    WHEN OLD.version = 39 AND EXISTS (SELECT 1 FROM events WHERE event_type = 'TICKET_PUSH_UNKNOWN_HAZARD')
    BEGIN SELECT RAISE(ABORT, 'push_unknown_hazard_schema_required'); END
    """)
  end

  defp ensure_active_run_indexes(connection) do
    transaction!(connection, fn tx ->
      for {name, columns} <- [{"one_active_run_per_issue_kind", "issue_key, kind"}, {"one_active_factory_run_per_issue", "issue_key"}] do
        sql = "CREATE UNIQUE INDEX #{name} ON runs(#{columns}) WHERE state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED')"
        existing = one!(tx, "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [name])

        unless existing && normalize_schema_sql(existing["sql"]) == normalize_schema_sql(sql) do
          query!(tx, "DROP INDEX IF EXISTS #{name}")
          query!(tx, sql)
        end
      end
    end)

    :ok
  end

  defp normalize_schema_sql(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.trim()

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
  def transaction!(connection, fun), do: transaction!(connection, fun, [])

  @spec transaction!(connection(), (DBConnection.t() -> result), keyword()) :: result when result: var
  def transaction!(connection, fun, opts) do
    case Exqlite.transaction(connection, fun, opts) do
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
