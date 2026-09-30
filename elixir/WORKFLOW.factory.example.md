---
tracker:
  kind: jira
  provider:
    base_url: $JIRA_BASE_URL
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
  assignee: currentUser()
  required_any_labels:
    - spec-needed
    - ai-ready
    - ai-running
    - ai-testing
  active_states:
    - READY
    - TO DO
  terminal_states:
    - Done
    - Closed
    - Cancelled
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
agent:
  max_concurrent_agents: 6
  max_turns: 20
codex:
  command: codex app-server
  read_timeout_ms: 60000
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
server:
  host: 127.0.0.1
  port: 4000
observability:
  dashboard_enabled: true
factory:
  enabled: true
  database: ~/Library/Application Support/symphony/factory.sqlite
  scope: assigned-jira-work
  dispatcher_id: replace-with-a-stable-uuid
  controller_codex_project_id: replace-with-a-codex-project-id # use projectless for a prebound Desktop controller
  task_transport: app_server # desktop_broker routes workers and a prebound controller through the Desktop broker
  native_session_discovery_enabled: false # opt in only after approving local Codex session metadata scanning
  branch_prefix: your-gitlab-username
  lease_seconds: 240
  controller_required_mcp_servers:
    - Jira
    - GitLab
  controller_mcp_startup_timeout_ms: 60000
  maximum_specifiers: 2
  specification_authorization_mode: auto_after_critic # independent critic PASS authorizes complete contracts
  maximum_writers: 2
  maximum_validators: 2
  writer_disk_gb: 20
  maximum_implementation_iterations: 8
  maximum_code_repair_rounds: 2
  maximum_validation_repair_rounds: 2
  controller_writer_stale_minutes: 15
  stale_task_minutes: 90
  queue:
    assignee: currentUser()
    projects: []
    epics: []
    issue_keys: [] # optional exact-key allowlist for a bounded pilot
    statuses:
      - READY
      - TO DO
    factory_labels:
      - spec-needed
      - needs-decision
      - ai-ready
      - ai-running
      - ai-verifying
      - ai-testing
      - ai-review
      - ai-blocked
  cleanup:
    enabled: true
    authorization_max_age_minutes: 60
    allowed_jira_statuses:
      - DONE
      - IN TESTING
      - TESTING
      - IN REVIEW
    allowed_mr_states:
      - merged
    allowed_run_states:
      - READY_FOR_REVIEW
      - DELIVERED
    allowed_worktree_roots:
      - ~/code/symphony-workspaces
  hibernation:
    enabled: true
    allowed_run_states:
      - AWAITING_VALIDATION
      - READY_FOR_REVIEW
      - TESTING
    reclaim_script: /absolute/path/to/reclaim-disk-space/scripts/reclaim.py
  manual_validation:
    enabled: true
    required_apps:
      - replace-with-slack-provider-app-id
    required_mcp_servers: []
    startup_timeout_ms: 60000
    allowed_environments:
      - cpp-dev
      - cpp-sandbox
      - cpp-test
    require_slack_coordination: true
    allow_production: false
    allow_database_ddl: false
  repositories:
    example:
      codex_project_id: replace-with-a-codex-project-id
      path: /absolute/path/to/repository
      base_branch: main
      gitlab_project: group/repository
      route_labels:
        - repo-example
  models:
    default_provider: codex
    providers:
      codex:
        fast: gpt-6-luna
        standard: gpt-6.1-sol
        strong: gpt-6.1-sol
    roles:
      orchestrator:
        provider: codex
        model_class: standard
        reasoning_effort: medium
      orchestrator-intake:
        provider: codex
        model_class: fast
        reasoning_effort: medium
      specification-author:
        provider: codex
        model_class: fast
        reasoning_effort: high
      specification-critic:
        provider: codex
        model_class: strong
        reasoning_effort: high
      feature-planner:
        provider: codex
        model_class: fast
        reasoning_effort: high
      feature-writer:
        provider: codex
        model_class: standard
        reasoning_effort: medium
      feature-writer-high-risk:
        provider: codex
        model_class: strong
        reasoning_effort: xhigh
      change-verifier:
        provider: codex
        model_class: strong
        reasoning_effort: xhigh
      manual-validator:
        provider: codex
        model_class: standard
        reasoning_effort: medium
      explorer:
        provider: codex
        model_class: fast
        reasoning_effort: medium
      failure-triager:
        provider: codex
        model_class: fast
        reasoning_effort: medium
    delivery_routing:
      default_role: feature-writer
      high_risk_role: feature-writer-high-risk
      unknown_risk_is_high: true
      high_risk_values:
        - high
        - critical
      high_risk_signals:
        - database-migration
        - security-boundary
        - production-impact
---

You are operating one bounded factory task for Jira issue
`{{ issue.identifier }}`. Follow the confirmed Jira contract and the factory
stage instructions supplied by the controller. Do not push, create or update a
merge request, merge, deploy to production, or manage human review. Stop closed
when the required stage capability or provenanced input is missing.
