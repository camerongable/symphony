# U7 initial Jira effect executor and scheduler join

Scope: original Slice 3 initial `In Dev`/`ai-running` handoff. No live Jira/GitLab
calls, native/model turns, provider/config installation, deployment, real-repo
commit/push or cleanup. Production V1 remains disabled.

## Implemented

- `TicketJiraOperation.start_implementation` owns a model-free Jira connector in a
  canonical existing non-source directory; scheduler supplies the proven parent cwd.
  Source/repository aliases, missing checkout and malformed sessions reject before
  any connector read or journal/reservation mutation. Jira provider overrides are
  distinct from source-worker app-server options.
- Fresh exact ordinary contract authority and pinned writer facts/capacity precede
  preparation. A unique advertised `In Dev` transition is checked again before its
  claim; fixed mutation capability preflight issues no tool. Existing In Dev is
  recorded as an observation-only transition, without manufacturing an ID.
- Prepared journal and maintenance reservation share a transaction. Each new effect
  claims uncertainty before sending, then independently reads back its actual issue
  outcome. A lost acknowledgement after application can complete; an unobserved
  uncertain effect never resends across restart. Other incomplete semantic operations
  on the run remain fenced.
- Final fresh read proves both exact target effects, not only general dispatch
  labels. Complete-journal release and actual writer admission commit together;
  admission alone launches no source worker and does not invent a candidate SHA.
- Existing-checkout ADMITTING_WRITER ticks call this executor. Initial checkout
  creation remains its existing separate path. No legacy cognitive Jira finalizer
  is called and no new model allocation/poll interval is introduced.

## Verification and review

Nine focused executor tests use real temporary Git/SQLite and a synthetic external
connector: bounded positive handoff, source aliases, missing source/session, lost
results before/after application, restart/delayed visibility, already-observed no-op,
ambiguous transition/missing capability, human block and final target reversion.
The existing real-fixture normal lifecycle is included in the grouped check.
Connector preflight also proves no tool mutation is issued during capability checks.
Final group: **28 passed, 0 failures**, seed 939187, 53.3 seconds, with 31 unrelated
lifecycle tests excluded by explicit line selection. Public spec check, focused
strict Credo, scoped format and diff checks passed. No full quality gate was run.

```sh
mise exec -- mix test test/symphony_elixir/factory_ticket_jira_operation_test.exs test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:407 test/symphony_elixir/factory_ticket_jira_journal_test.exs test/symphony_elixir/factory_jira_mcp_connector_test.exs test/symphony_elixir/factory_ticket_jira_workspace_test.exs
```

Early independent read-only review caught finalization accepting To Do/ai-ready
after historical completion. It now requires both current target effects. Review
also required physical non-source cwd proof; source alias tests were added. Last
review noted missing-checkout direct-call robustness, now guarded. Frozen re-review
found no remaining must-fix; reviewer did not rerun tests.

Compilation caught two illegal map accesses in guards; these were replaced by
pattern-bound values. The first normal-hook test exposed a missing supplied store
in the synthetic reader; the executor now explicitly owns its store option. No
check was weakened and no live action occurred during these failures.

## Still required

Review-ready Jira finalization must qualify original stopped push/verifier/current
MR facts and reconcile issued ai-review readback without treating it as ordinary
dispatch authority. Shared-controller busy fencing, required combined lifecycle,
actual provider/broker installation and native acceptance remain. Full unchanged
quality gate remains. U7/Slice 3 and Slices 4–5 are not complete.

## Frozen source

Base HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`, branch
`cgable/desktop-owned-ticket-chat-v1`; existing dirty/untracked implementation preserved.

```text
bab7e8e2cbac32149e10b23330b7391ee6f13c4edcff03b9e4f7b13665f38b59  elixir/lib/symphony_elixir/factory/ticket_jira_operation.ex
9363e757ae88d862f2f20615cb4690b2c2773dacb4ec5c97635641fef9db595f  elixir/lib/symphony_elixir/factory/ticket_jira_journal.ex
338b94d5b4509ae5555a88b37b45faf09a66824bc8ee3cbd14c8030026e78db6  elixir/lib/symphony_elixir/factory/jira_mcp_connector.ex
0f74c4ce096c771246e0b280d16ff38da9715681be01905638104d9573ca6ff4  elixir/lib/symphony_elixir/factory/scheduler.ex
8ce12c63c2c42128f74d6fa67e16167266895746bcf9052b511701dad72a51e2  elixir/test/symphony_elixir/factory_ticket_jira_operation_test.exs
f5c21fc9f5d536e856bb28b4d1729974ef2ed64abcae0c38541db5088f79faeb  elixir/test/symphony_elixir/factory_jira_mcp_connector_test.exs
a1fc2bbfdab76c0681bbb49b61c21aeabe824a84f1462e7c2c9a0fb56c420da0  elixir/test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
```
