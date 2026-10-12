# Plan 006 U0 — handoff baseline

Status: READY_FOR_REVIEW (baseline only; no source behavior changed)

## Checkout and source pins

- Branch: `cgable/desktop-owned-ticket-chat-v1`
- HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`
- `plans/006-source.sha256`: all 16 listed files verified `OK`.
- Dirty and untracked changes were present before this receipt. Exact observed
  `git status --short` output (including this receipt as the sole U0-created path):

  ```text
   M README.md
   M elixir/README.md
   M elixir/WORKFLOW.md
   M elixir/lib/mix/tasks/factory.desktop.ex
   M elixir/lib/symphony_elixir/codex/app_server.ex
   M elixir/lib/symphony_elixir/factory/contract.ex
   M elixir/lib/symphony_elixir/factory/desktop_request.ex
   M elixir/lib/symphony_elixir/factory/desktop_tool_args.ex
   M elixir/lib/symphony_elixir/factory/gitlab_mcp_connector.ex
   M elixir/lib/symphony_elixir/factory/stage_runner.ex
   M elixir/lib/symphony_elixir/factory/store.ex
   M elixir/lib/symphony_elixir/factory/worktree.ex
   M elixir/test/mix/tasks/factory_desktop_test.exs
   M elixir/test/symphony_elixir/app_server_test.exs
   M elixir/test/symphony_elixir/core_test.exs
   M elixir/test/symphony_elixir/factory_contract_test.exs
   M elixir/test/symphony_elixir/factory_gitlab_mcp_connector_test.exs
   M elixir/test/symphony_elixir/factory_store_migration_test.exs
   M elixir/test/test_helper.exs
   M plans/README.md
  ?? docs/desktop-ticket-chat-progress.md
  ?? elixir/lib/mix/tasks/factory.ticket.ex
  ?? elixir/lib/symphony_elixir/factory/ci_collection.ex
  ?? elixir/lib/symphony_elixir/factory/controller_ci.ex
  ?? elixir/lib/symphony_elixir/factory/ticket_chat.ex
  ?? elixir/lib/symphony_elixir/factory/ticket_chat_commands.ex
  ?? elixir/lib/symphony_elixir/factory/ticket_chat_outbox.ex
  ?? elixir/lib/symphony_elixir/factory/ticket_context.ex
  ?? elixir/lib/symphony_elixir/factory/ticket_worker_runner.ex
  ?? elixir/lib/symphony_elixir/factory/worker_check_io.ex
  ?? elixir/lib/symphony_elixir/factory/worker_evidence.ex
  ?? elixir/lib/symphony_elixir/factory/worker_file_io.ex
  ?? elixir/lib/symphony_elixir/factory/worker_file_tools.ex
  ?? elixir/lib/symphony_elixir/factory/workspace_access.ex
  ?? elixir/priv/worker_check_executor.py
  ?? elixir/priv/worker_file_companion.py
  ?? elixir/priv/worker_file_io.py
  ?? elixir/test/mix/tasks/factory_ticket_test.exs
  ?? elixir/test/support/controller_container_probe.py
  ?? elixir/test/support/file_io_controller.exs
  ?? elixir/test/support/file_io_creator_stop.py
  ?? elixir/test/support/file_io_db_busy.py
  ?? elixir/test/support/file_io_late_start.py
  ?? elixir/test/support/file_io_lost_reply.py
  ?? elixir/test/support/file_io_missing_asset.exs
  ?? elixir/test/support/file_io_production_override.exs
  ?? elixir/test/support/file_io_reader_fault.py
  ?? elixir/test/support/file_io_signaled_child.py
  ?? elixir/test/support/file_io_transport_fault.py
  ?? elixir/test/support/file_io_vm_crash.py
  ?? elixir/test/support/ticket_chat_fixture.ex
  ?? elixir/test/support/ticket_worker_fixture.ex
  ?? elixir/test/support/workspace_identity_controller.exs
  ?? elixir/test/symphony_elixir/factory_ci_collection_test.exs
  ?? elixir/test/symphony_elixir/factory_controller_checks_test.exs
  ?? elixir/test/symphony_elixir/factory_controller_ci_test.exs
  ?? elixir/test/symphony_elixir/factory_file_worker_transport_test.exs
  ?? elixir/test/symphony_elixir/factory_ticket_chat_commands_test.exs
  ?? elixir/test/symphony_elixir/factory_ticket_chat_migration_test.exs
  ?? elixir/test/symphony_elixir/factory_ticket_chat_outbox_test.exs
  ?? elixir/test/symphony_elixir/factory_ticket_chat_test.exs
  ?? elixir/test/symphony_elixir/factory_ticket_context_test.exs
  ?? elixir/test/symphony_elixir/factory_ticket_worker_runner_test.exs
  ?? elixir/test/symphony_elixir/factory_worker_evidence_test.exs
  ?? elixir/test/symphony_elixir/factory_worker_file_tools_test.exs
  ?? elixir/test/symphony_elixir/factory_workspace_access_test.exs
  ?? integrations/
  ?? plans/006-complete-desktop-ticket-chat.md
  ?? plans/006-source.sha256
  ?? plans/receipts/
  ```

  None were staged, reverted, or otherwise rewritten. Relevant existing files include
  `elixir/lib/symphony_elixir/factory/contract.ex`,
  `elixir/lib/symphony_elixir/factory/ticket_worker_runner.ex`, and their focused
  test files. The receipt file itself is U0's only new path.
- No active handle for the earlier interrupted test was available to collect. Rather
  than restart that process, U0 ran its single prescribed focused command once and
  collected that exact process to completion (session 13991).

## Focused baseline

Command, from `elixir/`:

```text
mise exec -- mix test test/symphony_elixir/factory_contract_test.exs test/symphony_elixir/factory_ticket_worker_runner_test.exs
```

Result: 36 tests, 1 failure, exit 2, 24.3 seconds.

The sole failure is the known candidate-SHA regression at
`factory_ticket_worker_runner_test.exs:119–120`: after setting `candidate_sha` to
`nil`, `TicketWorkerRunner.packet/4` returns `{:ok, ...}` with `"candidate_sha":null`
instead of `{:error, :manual_validation_candidate_missing}`. This is reproducible
and belongs to U2; U0 made no source fix. No other focused test failed.

## Scope and side effects

- Source/test files unchanged by U0.
- No worker, Jira, GitLab, Slack, deployment, or production-ledger operation.
- No changes to delivery/run/writer rows.
- No commit, push, or deploy.

Reviewer checklist: verify branch/HEAD/checksum evidence, confirm this records rather
than masks the single baseline failure, and confirm no source changes were made by U0.
