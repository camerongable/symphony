# U7 ordinary Jira review-ready finalization

Scope: the exact ordinary `Required: no` adopted-MR handoff. No live Jira/GitLab
calls, model/native turns, deployment, installation, real-repository commit/push,
or cleanup. Production V1 remains disabled.

## Implemented

- `TicketJiraFinalization.finish` qualifies the original adopted MR, stopped
  candidate checkout, verifier, push, and immutable request/claim. It owns a
  non-source Jira session and an exact maintenance reservation.
- The fixed journal records a concise Symphony MR/candidate/next-step comment,
  then the atomic `ai-review` label delta. Claims precede calls; uncertain effects
  are read back rather than resent. Existing unrelated labels are preserved.
- Jira is refreshed after MR collection before each claim and finalization.
  New effects require enabled/allowlisted Desktop routing and ACTIVE control.
  Already-issued `ai-review` evidence permits reconciliation, not new dispatch.
- Exact current comment/labels, MR receipt, source ownership, and candidate gates
  precede atomic reservation release and `READY_FOR_REVIEW`. Writer rows,
  candidate SHA, pushed handoff, and MR identity remain unchanged.
- The adopted-MR `MR_CREATING` scheduler branch uses this finalizer before ordinary
  source authorization, avoiding rejection solely because its own issued label
  update has already reached `ai-review`.

## Verification

Extended disposable Git/SQLite lifecycle: **1 passed, 0 failures**, seed 217941,
92.2 seconds. It covers lost comment response before application, late readback,
restart, applied labels with failed readback, paused/disabled issued recovery,
wrong allowlist, unissued target labels, and human label changes during MR reads.
Every connector is test-local; pushes use a disposable local bare remote.

Journal/workspace/connector group: **20 passed, 0 failures**, seed 877169,
8.0 seconds. Public specs, focused format and strict Credo passed.

Independent frozen read-only review accepted this component after checking fresh
Jira reads, new-write gating, immutable delivery bindings and atomic release.
The reviewer did not rerun tests. The subsequent test-only scheduler integration
passed **1 test, 0 failures**, seed 215838, 84.1 seconds: the normal adopted-MR
branch issued the label once, retained `SECOND_UNCERTAIN` after failed readback,
and paused/disabled direct recovery completed with no additional mutations.

```sh
mise exec -- mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:865
mise exec -- mix test test/symphony_elixir/factory_ticket_jira_journal_test.exs test/symphony_elixir/factory_ticket_jira_workspace_test.exs test/symphony_elixir/factory_jira_mcp_connector_test.exs
```

The first scheduler-test setup incorrectly reused a fixture initializer that
rebound the already-created parent, causing a unique-request constraint failure.
The test now builds the scheduler context without changing existing evidence.
This was a harness error, not a runtime mutation or relaxed production gate.
The next run reached the intended scheduler finalizer and retained uncertainty,
but the assertion expected an error name without its existing atom prefix. That
assertion was corrected to the scheduler's actual `:jira_readback_unavailable`
representation; no implementation behavior was changed.

## Remaining work

Disabled/paused normal recovery scheduling and shared-controller busy fencing
remain a separate packet. Direct finalizer recovery is not proof that normal
scheduler ticks drain quarantined work. The recovery-only entrypoint must create
no journal/reservation, claim no effect, send no mutation, preserve the original
ownership, and retain lease serialization while control stays paused.

Combined lifecycle/native acceptance, provider/broker installation and the unchanged
full quality gate remain. This is not complete U7/Slice 3 or route enablement;
Slices 4 and 5 still remain.

## Reviewed implementation identity

Base HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`, branch
`cgable/desktop-owned-ticket-chat-v1`; unrelated dirty work preserved.

```text
1af311b8ba990707958922a584a0e081f54bc5cf0b4de1c167be94eda645fcc6  elixir/lib/symphony_elixir/factory/ticket_jira_finalization.ex
30cc7eb65cf99c0bf5a0edc08c7303d369f176d57154b010268d3c7db70dfc78  elixir/lib/symphony_elixir/factory/ticket_jira_journal.ex
7972da70024d74a2de4469c0aff0397aeda49fd98591bcc699a409be87260ac5  elixir/lib/symphony_elixir/factory/ticket_mr_operation.ex
048af361a29b49805f9cdf66236b445a7802915374fd5fdf0bf9d3e8480f7db3  elixir/lib/symphony_elixir/factory/scheduler.ex
```
