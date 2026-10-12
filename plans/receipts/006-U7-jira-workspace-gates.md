# U7 Jira workspace gates and read-only delivery facts

Scope: Slice 3 local prerequisites for the already-implemented two-effect journal.
No live connector/model/native turns, installed configuration changes, deployment,
real-repository commits/pushes or cleanup. Production capability gate remains closed.

## Implemented

- Extracted read-only initial writer facts and stopped exact-candidate delivery facts.
  Actual writer admission still requires fresh Jira proof and configured capacity,
  and cannot use the new facts' owned-maintenance shortcut. Ordinary delivery
  admission still requires fresh authorization; `ai-review` readback is not one.
- Initial MAINTENANCE accepts a nil candidate only for exact ordinary V1
  `ADMITTING_WRITER`, with a persisted immutable review-base SHA. Revalidation also
  checks that pin. No candidate is manufactured or writer allocation changed.
- Exact COMPLETE journal release checks receipt consistency, operation/reservation
  key, generation, run, maintenance mode, nil task, physical checkout identity and
  expected SHA. Partial/uncertain operations do not release. Exact repeated release
  is idempotent; release rolls back with failed controller finalization.
- Initial maintenance retains configured writer disk/concurrency budget from its
  immutable acquisition identity until release, including FAILED/CANCELLED states.
  Malformed binding is conservatively counted, not silently dropped.

## Tests and review

New five-test workspace packet uses real temporary Git repositories and SQLite.
It covers unchanged facts/rows, missing/expired admission authority, held mutex and
budget, uncertainty/restart/partial completion, exact release, unsupported initial
gates and base, base drift, transaction rollback, dirty source, failed/cancelled
budget retention and malformed binding.

Existing normal lifecycle test now proves delivery facts leave run/task/reservation/
worker/event rows unchanged and `ai-review` cannot authorize ordinary delivery.
The existing planner → writer → verifier → fixture-only exact push lifecycle is
included, not substituted by a mock-only proof.

Final focused command:

```sh
mise exec -- mix test test/symphony_elixir/factory_ticket_jira_workspace_test.exs test/symphony_elixir/factory_workspace_access_test.exs test/symphony_elixir/factory_capacity_test.exs test/symphony_elixir/factory_ticket_checkout_test.exs test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:406
```

**43 passed, 0 failures**, seed 608702, 50.7 seconds; 31 unrelated lifecycle tests
excluded by explicit line selection. Public spec check, focused strict Credo, scoped
format check and `git diff --check` all passed. No full quality gate was run, so
this does not establish U7/Slice 3 acceptance. Initial focused workspace failures
were fixture table/API misuse and a partial-release error expectation; they were
corrected without weakening the checks or relaxing immutable run fields.

Independent read-only review found a mutable-state capacity hole. Accounting was
changed to immutable reservation identity and terminal/malformed-state regressions
added. Re-review accepted the fix with no remaining finding in the reviewed delta;
reviewer did not rerun tests.

## Still required

Wire the deterministic Jira executor into the scheduler. Before each new effect it
must prove current external authorization, exact checkout/journal reservation and
catalog-qualified tool arguments. Initial `In Dev` transition must use the unique
advertised target; finalization must use stopped push/verifier/current MR evidence.
Issued effects reconcile by readback only. Exact target `ai-review` readback must not
fabricate source-dispatch permission. Shared busy fencing, final transaction and
normal-tick end-to-end coverage remain. Provider/broker installation, native
acceptance and final quality gate remain separately gated.

## Frozen source identity

Base HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`, branch
`cgable/desktop-owned-ticket-chat-v1`; dirty/untracked prior implementation preserved.

```text
c395df7b2cb2f2ef850b4c18694024acdd8f8b262150f48914b910f94994df88  elixir/lib/symphony_elixir/factory/ticket_worker_runner.ex
cfd644567d2c94e111d23840e11827db8520a41efd3927a50371fd25be7478a4  elixir/lib/symphony_elixir/factory/workspace_access.ex
42adac86cea4248099ceb4925159b61ea0a35a4569aa3d1558e7f35ad5a38971  elixir/lib/symphony_elixir/factory/capacity.ex
05fddf4a74265857feff8bfb2d263c73b8fa8953a7ec6ad63b9f61825f5b6f6c  elixir/test/symphony_elixir/factory_ticket_jira_workspace_test.exs
a69ef0a3fdd9b0e0975be9496d76fc65f657b7dc93ad7464a570fa88e3001915  elixir/test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
```
