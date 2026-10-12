# U7 rollback scope audit

October 6. Read-only audit while full quality gate session `3509` remains live;
source is frozen. This receipt does not establish Slice 3 acceptance.

Plan 006 U7 item 6 requires rollback to stop new admissions while retaining safe
readback, draining and reconciliation of admitted V1 runs, without legacy rerouting.

Current evidence:

- `Scheduler.reconcile_ticket_jira_context/1` selects only `REVIEW_READY` journals
  for `MR_CREATING` runs; its query does not select `START_IMPLEMENTATION` journals.
- The existing disabled-normal-tick worker lifecycle regression intentionally
  leaves stopped result evidence `RESULT_RECORDED`, with the run still `WRITING`.
- Read-only independent audit found no equivalent disabled/paused scheduler
  selection for issued checkout/push outcomes and completed MR adoption.

Stopped worker result retention is already durable reconciliation without candidate
promotion; it is not itself a missing drain behavior. The narrower missing boundary
is automatic selection/readback of the other already-issued operations. Item 6
remains open.
The next implementation must distinguish readback of the original issued action
from a new source commit/check, writer turn, push, MR creation or Jira mutation.
In particular, normal writer candidate adoption is not automatically a permissible
rollback operation: it may commit source and cannot simply be reused as readback.

Independent follow-up identified the safe boundaries:

- Worker results remain `RESULT_RECORDED` with proven owned stop, unchanged
  candidate and retained source reservation. Do not require `CONSUMED`.
- Checkout reconciliation may adopt an exact issued checkout receipt; never call
  checkout creation from the recovery selector.
- Push reconciliation must read only the existing `PUSH_UNCERTAIN` receipt and
  remote evidence; exclude preparation, claim, execution and rollover.
- MR reconciliation may adopt the existing successful claim, but must not enqueue
  or prepare another request.
- `START_IMPLEMENTATION` reconciliation observes issued Jira effects. An unissued
  second effect remains pending; completion must not admit a writer.

Use existing disabled-worker and checkout/push/MR restart fixtures for the bounded
regressions. Do not add a new lifecycle harness or change the one-ticket-chat
architecture. Wait for session `3509` to terminate before changing source.

Implementation seams verified against current source:

- Paused admission uses `TickLease`'s fixed recovery callback into
  `Scheduler.reconcile_ticket_jira/2`; normal ticks call the same private selector.
  Extend this recovery route rather than introducing another dispatcher.
- `TicketCheckout.reconcile/4` already reads the original terminal receipt and
  admits its exact checkout without creation. Keep its existing binding and
  capacity checks; do not bypass them for rollback.
- `TicketPush.step/4` is not readback-only: its `prepare` path can prepare a new
  operation after a completed push, and `execute_once` can execute a prepared one.
  Extract an explicitly receipt-only entrypoint which accepts only the original
  uncertain invocation and shares its exact completion validation.
- `TicketMrOperation.adopt_result/5` is already receipt adoption only. Use it
  directly; do not use the scheduler's ordinary unknown-request fallback to
  `TicketMrOperation.prepare/7`.
- `TicketJiraOperation.start_implementation/3` can apply pending effects and its
  finalizer calls `admit_writer`; it is unsuitable for rollback. Add a distinct
  reconciliation entrypoint using the existing bound journal, original reservation,
  fresh readback and exact checkout facts. No pending-effect apply or writer admit.

Existing regression anchors: checkout restart and missing-terminal-receipt tests;
initial Jira lost-result/restart test; push once-only/crash tests; MR original-claim
adoption tests; paused REVIEW_READY recovery tests. Strengthen their controller
join assertions instead of adding synthetic success flags or a second fixture stack.

## Push receipt-only primitive

`TicketPush.reconcile/4` now accepts only an existing `PUSH_UNCERTAIN` envelope,
uses the same per-run lock and exact binding/receipt/remote/ownership validation,
and shares completion logic without preparation, execution or rollover. Shared
finalization validates the current existing envelope instead of calling `prepare`.
A missing current envelope returns `ticket_push_intent_changed` before JSON decode.

The existing once-only push/restart test was extended, not replaced by a new
harness: nil/prepared envelopes reject without issuance; release failure preserves
the uncertain operation; restart adopts its original receipt; completed replay
rejects without changing the run or reservation rows. RED: missing entrypoint,
one failure, seed 481102, 27.8 seconds. GREEN: one test, zero failures, 69.6 seconds.
Adjacent repaired-candidate and CI-preflight push-history tests: two tests,
zero failures, seed 481103, 121.8 seconds. After the defensive envelope guard,
the focused regression passed again: one test, zero failures, seed 481104,
66.8 seconds. Specs, formatting, strict Credo and diff whitespace passed before
the guard; final formatting/diff checks also passed. The guard adds no public API.

Independent review accepted receipt-only ownership/execution boundaries and found
the missing-envelope exception risk, which the guard addresses. The exact concurrent
envelope-clearing race has not been independently exercised; do not claim that
specific failure-injection acceptance. Scheduler recovery selection, initial Jira
receipt-only entrypoint and whole Slice 3 acceptance remain outstanding.

## Initial Jira receipt-only primitive

`TicketJiraOperation.reconcile/3` now validates the existing issued
`START_IMPLEMENTATION` journal and its original maintenance ownership. It opens
the canonical non-source controller session, observes the fixed effect pair through
fresh issue reads, and releases only the complete exact reservation. It does not
prepare or claim effects, call mutation tools, acquire another reservation, probe
the runtime, enforce a new writer admission, or change the run to `WRITING`.
Released completion replay rechecks fresh target state and the original release
receipt; changed target state stays fenced.

Existing regressions were extended: no journal/unissued journal rejection; lost
acknowledgement across restart without replay; observed first effect with absent
second effect remains `SECOND_PENDING`; unchanged runtime trace, task rows and run;
release-trigger rollback; completion while writer capacity is unavailable; exact
released-row replay; fresh target loss prevents release. RED: two missing-entrypoint
failures, seed 551011, 6.7 seconds. Initial GREEN: two tests, zero failures,
37.8 seconds. Full affected module: twelve tests, zero failures, seed 551012,
76.1 seconds. After lint-only helper extraction/wrapping, final focused checks:
two tests, zero failures, seed 551013, 24.7 seconds. Final specs, formatting and
strict Credo passed (6,185 modules/functions, no issues).

Independent review accepted the original-ownership and no-new-effect boundaries.
Scheduler paused/disabled selection and the whole Slice 3/full-coverage acceptance
remain outstanding; neither primitive alone proves automatic rollback draining.

## Bounded initial Jira scheduler join and parallel coverage

The existing paused-tick Jira recovery entrypoint now selects issued initial
operations as well as review-ready operations, skips released ownership and records
attempts in the existing event ledger. Least-recent-attempt ordering is bound to the
selected operation key; it changes no run, task or ownership fields.

Under the per-run lock, dispatch rechecks the exact selected run, semantic journal
key, ready parent and parent scope. The stale-history regression first exposed
reconciliation of the wrong current journal (seed 772103, one failure, 6.2 seconds).
After the binding correction, two focused tests passed (772104, 13.7 seconds).
The regression demonstrates unchanged ownership after historical rejection and
fair selection using a newly opened connection to the persisted SQLite database.
It is not a full scheduler/runtime restart or injected scope-change race test.

Parallel Luna coverage preparation supplied two meaningful public-boundary tests:
path occupation between checkout reservation and claim, and unencodable filesystem
path rejection with caller-owned Port cleanup. Main applied them as the sole writer
because current measured capacity permits one writer (34.77 GB free). No additional
implementation worktrees, native model probes or production effects were created.
The combined affected modules passed 44 tests, zero failures (seed 772106,
52.7 seconds). Sol 6.1 independent review found no blocking issue in this increment.
Specs, formatting, strict Credo and whitespace checks pass after a lint-only local
options variable. The existing review-ready lifecycle regression passed as session
99403, seed 772107: one test, zero failures, 136.5 seconds.

Fixed remaining U7 rollback/acceptance checklist (existing scope, no new features):

- [x] Push receipt-only primitive and original push-history regressions.
- [x] Initial Jira receipt-only primitive and original ownership/target regressions.
- [x] Initial Jira bounded scheduler join, exact selected-key binding and persistent
  attempt ordering; bounded independent review.
- [x] Verify the existing review-ready recovery lifecycle remains green.
- [ ] Join issued checkout, push and successful MR receipts into bounded paused/
  disabled recovery; never prepare, claim, execute or launch replacement work.
- [ ] Verify the completed recovery selection against existing restart, ownership,
  disabled/paused and legacy regressions; independent review on frozen source.
- [ ] Resolve remaining meaningful coverage gaps and retain defensive guards;
  current full coverage verdict remains 98.97%, not a pass.
- [ ] Run one final unchanged full quality gate on integrated frozen source and
  complete the original Slice 3 requirements audit before starting Slice 4.

## Issued checkout scheduler join

Checkout candidates now share the same one-item, scope-bound, least-recent-attempt
selector as Jira operations. Only owned uncertain/reconcile-required initial
intents are selected; prepared/unowned intents are skipped. Dispatch validates the
selected run, original binding digest/nonce and parent scope, reads fresh Jira
authorization, and calls only `TicketCheckout.reconcile` with its original base pin.
It never creates, claims, executes or launches a planner/writer.

Existing initial-checkout lifecycle regressions were extended: prepared skip;
real helper completion followed by a reopened SQLite connection and disabled-policy
readback despite changed caller base; unchanged invocation/PID/execution; quiet
completed replay; missing receipt preserves the original owner, unmaterialized run,
runtime trace and no task launches. RED: two failures (903101, 4.2 seconds).
Initial GREEN: two tests (903102, 5.0 seconds); adjacent group: 31 tests, zero
failures (903103, 58.2 seconds).

Independent Sol 6.1 review identified a real nonce drift gap during Jira read.
The existing regression reproduced admission for the substituted owner (903104,
one failure, 4.0 seconds). Direct receipt-field substitutions independently failed
to reject (903105, one failure, 1.5 seconds). Scheduler now supplies its captured
intent as an optional restriction checked before primitive readback; receipt
validation independently binds execution invocation/run/intent bytes/digest to the
intent. Both cases passed (903106, two tests, 4.0 seconds). Independent review
confirmed the gap closed with no authority widening.

Final adjacent group passed 30 tests (903107, 55.4 seconds); its line filter did
not include the missing-receipt lifecycle case after lines shifted. The two exact
recovery regressions were therefore rerun at their current lines: two tests,
zero failures (903108, 8.2 seconds). Final specs, formatting and strict Credo pass
(6,195 modules/functions, no issues). These are bounded component/join results,
not a full scheduler/runtime restart or overall Slice 3 acceptance.

Checkout recovery join is complete at this boundary. Push and MR selector joins,
remaining meaningful coverage, final integrated gate and original scope audit
remain pending. Parallel Luna preparation for the push join is available; no
additional source writer/worktree or production effect was started.

## Push scheduler join

The bounded recovery selector now includes only valid uncertain push envelopes,
with persistent attempt ordering keyed to their original binding hash and nonce.
Dispatch pins the captured raw envelope before fresh Jira readback; envelope drift
rejects without releasing ownership. Recovery calls only `TicketPush.reconcile`.
CI preflight remains dependent on its configured route and does not replace the
fresh verifier gate for final delivery.

Strengthening the shared checkout receipt validator exposed a push schema mismatch:
push stores its run identity in the immutable binding, not at the intent top level.
`TicketPushIO` now explicitly adapts that identity before shared validation. Malformed
bindings reject; execution identity checks remain intact. This was a real regression,
not an expected red result for the selector.

Selector RED: seed 905102, one failure, 28.5 seconds. Ordinary recovery GREEN:
905103, one test, 34.3 seconds; fresh-Jira drift extension: 905104, one test,
33.1 seconds; configured CI-preflight recovery: 905105, one test, 26.3 seconds.
After formatting-only fixes the affected push/CI/checkout group passed 19 tests,
zero failures (905106, 78.4 seconds). Specs, formatting, strict Credo (6,199
modules/functions) and diff whitespace passed. Independent Sol 6.1 review found
no blocking issue in the selector, identity adapter, original receipt adoption or
existing CI/fresh-verifier boundary. No native/model/production action occurred.

MR-result selection, remaining meaningful coverage, final integrated gate and
original scope audit remain incomplete. These focused results do not establish
Slice 3 acceptance or a new aggregate coverage result.

## MR-result scheduler join

The same bounded recovery selector now screens successful typed controller MR
follow-ups against the current run, stage, candidate, revision and parent scope.
Malformed metadata is normalized only for selection; full request/claim/binding
qualification remains in `TicketMrOperation.adopt_result`. Already-adopted or partial
MR fields are excluded. The selected request key is checked before remote reads;
dispatch calls only adoption, with no prepare/enqueue fallback or Jira finalization.

Existing adoption fixtures now exercise paused, V1-disabled recovery for ordinary,
CI-preflight and subsequent review-ready finalization. They retain exact candidate,
request, claim and task evidence and unchanged paused control, then restore active
test control for existing downstream assertions. Added fault cases prove an older
copied request cannot replace the deterministic original, and mutation of the
captured request during remote readback leaves MR fields unadopted. Restoring the
original row permits successful recovery without a replacement request.

RED missing selector: 905107, one failure, 35.0 seconds. Initial GREEN ordinary and
preflight: 905108, two tests, 104.0 seconds. The first expanded run was stopped upon
finding assertion-format/old-mailbox mistakes. A subsequent fixture failure
(905110, 41.3 seconds) and independent review exposed historical-copy ordering;
an explicitly older synthetic timestamp now deterministically exercises rejection.
No production guard or deadline changed. Final three-variant group: 905111,
three tests, zero failures, 237.2 seconds. Public specs, formatting, strict Credo
(6,202 modules/functions) and diff whitespace pass. Independent review accepted
the production boundary and final fault fixture; no native/live/production actions
were performed.

Initial Jira, checkout, push and MR receipt-only selector joins are complete at
their bounded component boundary. Stopped source results remain retained rather
than promoted while paused. Remaining meaningful coverage, final integrated gate
and original scope audit are still required for Slice 3 acceptance.
