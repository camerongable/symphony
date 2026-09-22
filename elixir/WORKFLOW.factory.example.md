---
tracker:
  kind: jira
  provider:
    base_url: $JIRA_BASE_URL
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
  assignee: currentUser()
  required_any_labels:
    - ai-spec-needed
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
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
factory:
  enabled: true
  database: ~/Library/Application Support/symphony/factory.sqlite
  scope: assigned-jira-work
  dispatcher_id: replace-with-a-stable-uuid
  lease_seconds: 240
  maximum_specifiers: 2
  maximum_writers: 2
  maximum_validators: 2
  writer_disk_gb: 15
  repositories:
    example:
      path: /absolute/path/to/repository
      base_branch: main
  models:
    default_provider: codex
    providers:
      codex:
        fast: gpt-5.6-luna
        standard: gpt-5.6-terra
        strong: gpt-5.6-sol
    roles:
      specification-author:
        provider: codex
        model_class: standard
        reasoning_effort: high
      specification-critic:
        provider: codex
        model_class: strong
        reasoning_effort: high
      feature-writer:
        provider: codex
        model_class: standard
        reasoning_effort: high
      high-risk-feature-writer:
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
      high_risk_role: high-risk-feature-writer
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
