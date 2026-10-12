# U9N ordinary integration acceptance preparation

Read-only parallel investigation; no tests or live calls executed. This maps
existing fixtures for the future sole writer, not current candidate acceptance.

## Existing proof and gaps

- `factory_desktop_ticket_chat_lifecycle_test.exs`: "one uninterrupted ordinary
  run reaches review-ready through normal ticks and synthetic broker readback"
  proves the ordinary writer/adoption/verifier/draft-MR path, stable parent and
  checkout, and duplicate final tick. It seeds ADMITTING_WRITER, returns no Jira
  search results, exposes only MR readback, and ends before direct rework. Thus
  it does not prove ai-ready intake, current CI, or direct-chat recovery.
- `factory_full_lifecycle_test.exs`: "authorized ai-ready work uses the default
  writer and survives SQLite reopen before verifier dispatch" proves legacy
  intake, reopen/pre-adoption, verifier and MR deduplication. Its rework uses
  tagged GitLab feedback; preserve it as legacy regression, not V1 direct-chat
  acceptance. That feedback feature remains deferred.
- Existing worker lifecycle cases prove held-amendment resume, same-thread
  recovery, RESERVED/START_SENT restart handling, uncertain finalization,
  presentation-failure isolation, and post-commit adoption. Admission tests
  fence missing/malformed/Required:yes contracts, but not a complete scheduler
  intake with parent/worker/effect counters.

Historical receipts document local checks; they do not prove that today's
evolving candidate passes. The replacement 99% Slice-3 gate was accepted from
the user's reported PASS, not independently reproduced terminal output.

## Minimal implementation sequence

1. Extend the existing `DesktopTicketLifecycleFixture` and canonical ordinary
   case; do not create another harness. Configure Jira search/intake and bound
   native history, and drive direct accepted recovery through normal ticks.
2. Carry the same ledger, parent, checkout, writer, completed-slice history and
   MR through exact current-CI qualification and direct rework followed by a
   distinct fresh verifier. Reuse existing CI/preflight behavior with only the
   necessary fixture responses.
3. Add stored-result/pre-adoption and pending-presentation restart barriers.
   Assert immutable evidence, no extra source invocation and no duplicate MR.
4. Count parent, worker and external effects at missing/malformed/Required:yes
   scheduler intake fences. Read-only stages must preserve source HEAD/status.
5. Prove parent context includes candidate, completed work, findings and next
   action. Synthetic local proof does not replace native input acceptance.

## Native acceptance boundary

Still required: real human input during an active writer, then two inputs while
the parent is busy; preserve both, consume once and queue presentation. Never
infer idle from a foreign cold-thread read. Prior writer/verifier/context-read
receipts do not establish these cases. Obtain explicit bounded native-turn/input
authority before running them; no real Jira/GitLab actions are implied.

## Refreshed fixture handoff

Parallel read-only preparation confirmed the following seams; re-resolve exact
test names after the amendment source freeze rather than trust these line offsets.

- `factory_scheduler_test.exs:2329` is the existing V1 `ai-ready` registration
  case; its helper is at 2483. It ends at `ADMITTING_WRITER`, before source work.
- Its `Required: yes`/reader-failure fence at 2378 counts delivery, parent and
  request absence. Extend the same fixture to missing/malformed contracts and
  task/workspace/checkout/event plus worker/Jira effect absence. Preserve the
  disabled/not-allowlisted legacy registration case at 2467.
- The canonical desktop lifecycle setup currently registers a dummy WRITING
  task, binds the parent, and directly overwrites the run to ADMITTING_WRITER.
  Make that existing setup optionally omit these seeded records and feed the
  authorized Jira snapshot through normal scheduler intake instead.
- Reuse the legacy full-lifecycle stored-result/reopen barrier at 707, but place
  it in the V1 direct-parent lifecycle. Assert no replacement writer or checkout.
- Add a pending parent-summary restart barrier before synthetic broker completion;
  assert the same request/sequence survives without another source invocation.
- Reuse exact-candidate CI response fields from the scheduler preflight case at
  2845. That seeded CI_PUSHING test is not combined lifecycle acceptance.

The agent performed no tests, builds, native turns, live calls or source edits.
Process-dictionary native-history fixtures are deterministic offline evidence,
not proof of real human input while a native parent or writer is busy.

## Test selection after source freeze

Use exact case names rather than stale line offsets while iterating. First run
the extended canonical ordinary case. Then select the affected restart/admission
cases above. At Slice-4 acceptance, run the plan's desktop lifecycle, full
lifecycle and scheduler integration group. Do not repeatedly run that group for
mechanical cleanup or use the legacy feedback case to claim direct recovery.
