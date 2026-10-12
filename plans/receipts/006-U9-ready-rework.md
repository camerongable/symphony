# Review-ready direct rework prerequisite

Status: IN_PROGRESS. This is the required missing U9 path, not accepted source
or full Slice 4. Implementation handoff and adversarial constraints are in
`../006-U9-ready-rework-handoff.md`. Sole writer: `ready_rework_implementation`,
GPT-6 Luna medium. Existing-module/record design only; no schema/new engine.

## First admission checkpoint

Author reports exact named case
`READY_FOR_REVIEW direct rework admission is bound to one accepted native command`
passed with seed 133966: 1 test, 0 failures, 46 excluded. The first tag selector
selected zero cases and proves nothing. At this checkpoint Commands validation
and Runner ready-Jira/packet scaffolds exist; Scheduler/Launcher routing and
recovery still require implementation. Admission-only PASS does not accept those.

An unintended whole-file run reported a reservation-race assertion failure in
`different accepted proposals racing for one run leave one owner and both commands intact`.
Seed 133966; expected conflict count 1 versus observed 0. Raw output was truncated
and no logfile persisted. It is unresolved, not proven pre-existing or unrelated.
Do not silently ignore it or repair it speculatively. Root retained an observational
four-file snapshot `/private/tmp/symphony-u9-race-triage.JYQXQu`; it is not attested
as the exact failing runtime image. Reproduce the exact named race on frozen source
before diagnosis/acceptance; no active-writer test or broad repeat loop is implied.

Root subsequently reproduced the exact count mismatch in an older isolated copy
`/private/tmp/symphony-mixed-rework-exact-red.wAcNMt/elixir`, not the current
writer's candidate: named race, seed 133966, session 85182, exit 2, 1/1,
42 excluded, 0.6 seconds. Commands hash in that copy is
`8b83690171ac7a0104af93494021cb01e1053409c1b2fab4f5b3e0cae970383c`;
Amendment hash `3e84382ef84fe71e8aac99be0e4fe7ae45e5f2ea3a8307681c5d7cbc534a79de`.
This proves the symptom exists in older source, not current regression absence.
Read-only `reservation_race_triage` is assigned one exact repeat and finite
caller/invariant diagnosis there, without editing or inspecting the active checkout.

One exact isolated diagnostic resolved the return values: session 20974,
seed 133966, 1/1, 42 excluded, 0.7 seconds, exit 2. Winner is a RESERVED owner;
loser is `{:error, :amendment_jira_effect_missing}`, consistent with an independent
proposal entering correction/supersession proof handling. Root added only a
temporary assertion message in the older test, then restored exact test SHA
`a80a1c9a5db31e0b7fd69e3ff79dfaa89f13b7de29cf2de9b017cf4b82dd373a`;
the DEBUG tag is absent. No product source or active checkout was changed.
The triager is mapping a finite reservation-branch correction; keep genuine
non-PASS correction proof and uncertain-owner fences intact. Current-candidate
verification and repair remain outstanding, not waived by this older-copy proof.

Finite triage handoff: the failure originates in
TicketChatCommands.proposal_revision, before Amendment.reserve's conflict branch.
A different accepted proposal asks correction_revision of an active RESERVED
owner with no Jira effect and gets amendment_jira_effect_missing. For that
expected pre-publication reservation case, report amendment_reservation_conflict;
do not widen accepted proposals, swallow other proof/uncertainty errors, or weaken
the race assertion. Keep complete stopped non-PASS supersession working and
retain precise failures for invalid/PASS/uncertain correction evidence. Reproduce
on the current frozen candidate before this separate small repair, then run the
race plus those two existing correction regressions. No source repair done yet.

Author pre-fix bytes are at `/private/tmp/symphony-u9-rework-before/`; immutable
design baseline is `/private/tmp/symphony-u9-rework-diagnosis.0oQPL9`.
No independent acceptance, commit, push, deployment or paid native call occurred.

## Transaction/launch checkpoint: verifier failure before rework

Author wired Commands/Runner/Scheduler/Launcher preparation, but canonical
seed 60214 failed before its new ready-rework assertions. Raw log
`/private/tmp/symphony-u9-rework-transaction-60214.log`: 1/1, 3 excluded,
113.9 seconds. The post-amendment verifier round 2 returned
`factory_stage_output_schema_mismatch`; success-only mailbox matching masked it
until timeout. This is not a passing source-action transaction test.

The prior accepted fixture case stopped after this verifier's launch, not its
completion. Cause was not initially attributable to old/new code. Actual worker
JSON/schema was not retained before fixture teardown; manual validation of a
synthetic four-field fixture literal is not runtime evidence.

The writer froze product/fixture edits. Root retained a twelve-file immutable
snapshot `/private/tmp/symphony-u9-verifier-diagnosis.JK8LxU`. Strong read-only
review found the amended verifier call uses critic_context, which installs
CriticServer; that server emits a three-field critic map, whereas WorkerServer
and the selected verifier schema use four verifier fields. This is strong source
evidence, not captured actual emission. A sole-writer existing-fixture mailbox
probe is authorized to record the exact module/schema/output before teardown,
then correct only role-specific test context if confirmed. Match typed task
completion before asserting success; no schema loosening, increased timeout,
new harness, permanent hook, or product-routing workaround.

First probe attempt ended before verifier capture because the newly extended
test read the closed pre-reopen ctx.store (52.8 seconds, 1/1). It captured no
actual packet/schema/output and is not schema-cause proof. The writer corrected
the continuation to the current reopened store and reran the same named case;
temporary environment/probes must be removed after capture. Product files remain
unchanged during this diagnostic phase.

Second probe captured the actual emitter/schema mismatch in
`/private/tmp/symphony-u9-verifier-probe-60214.log`: VERIFYING, revision 3,
verifier round 2, candidate `40c3fdfb6e526428c7495cc8ca9db3f06462883b`;
CriticServer/critic-fixture/critic-turn emitted status/findings/required_questions
against a verifier schema requiring status/candidate_sha/findings/checks.
This confirms wrong role-specific test context. The writer changed only that
verifier call to ordinary context, retained reopened-store correctness and
critic context for critic calls, removed all temporary probes/environment/IO,
and restored support fixture SHA to its exact checkpoint value. Product files
stayed frozen. The exact post-fix run uses
`/private/tmp/symphony-u9-rework-green-60214.log`; passing evidence is still pending.

That run completed the amended verifier but failed the next delivery tick with
ticket_jira_not_dispatchable (1/1, 3 excluded, 55.0 seconds). A second existing-test
diagnostic captured fresh synthetic Jira ai-review/In Dev, an exactly matching
authorized contract digest, and run PUSHING/spec revision 3/verifier round 2/
retained opened MR/no legacy review flags. The same tick deferred (55.6 seconds,
1/1, 3 excluded), log
`/private/tmp/symphony-u9-post-amendment-push-diagnostic-60214.log`.
Strong immutable review traced Scheduler delivery authorization to Runner's
initial-label fallback for PUSHING. A narrowly proven post-review delivery
authorization helper is now specified in the U9 handoff; ordinary intake/source
authorization, freshness and original-MR/current-verifier proof remain mandatory.
No label normalization, schema bypass or passing transaction claim was made.

## Early immutable-scaffold findings

Parallel adversarial review of the frozen diagnostic snapshot found two concrete
implemented defects (not a full acceptance or broad coverage audit):

- Launcher matched :ok from WorkerEvidence.owner_stopped?, whose public function
  returns boolean. Valid true therefore rejects ready preparation. Keep the
  stopped-owner requirement, correct its typed match and test valid preparation.
- Ready command validation/terminal recording checks ACCEPTED-list uniqueness
  but lacks unrelated OPEN questions, competing PENDING commands and active
  amendment-owner fences. Add the exact selected-answer exemption and these
  preparation/terminal checks inside the existing rollback transaction.

All thirteen immutable source hashes stayed unchanged during review; no active
checkout inspection or tests. The sole writer received these finite required
repairs before its next long canonical run, with focused no-launch/rollback
cases required. Known unfinished downstream joins were deliberately excluded.

## Mandatory-check and default-fixture corrections

The next completed canonical failed candidate_check_unproven after 56.0 seconds:
prior source controller check binds the old contract/revision, correctly stale
after amendment. A proposed verifier-only fallback was removed before acceptance;
mandatory controller evidence remains unchanged. A later run was interrupted on
the explicit diagnostic freeze request and has no terminal test verdict.

Current frozen Runner SHA after removing that fallback is
`e8c50abbb4a17799bbf1b04b0446edbdc624348a55e692214edf78087a9415cb`.
Root inspected the existing API: WorkerEvidence.check_scope admits stopped
RESULT_RECORDED change-verifier evidence under REVIEW ownership before consumption.
The sole writer is authorized to use that real fixed git-diff-check mechanism in
verifier adoption when no exact current candidate/revision/contract check exists,
not waive/rebind it. Failed/uncertain checks block delivery and retain same-operation
reconciliation. Focused tests and complete U9 proof remain required.

Earlier frozen-fixture review missed a real optional-flag regression: strict
`not context[:unregistered]` raises for missing nil. The sole writer corrected
it to register unless the flag is exactly true, removed an explicit-false tag
workaround, and reports default plus explicit opt-out 2 tests/0 failures (6.4s),
then existing legacy MR adoption 1 test/0 failures (51.1s). These repair results
supersede the earlier unsupported default-compatibility assertion; final hashes,
exact selectors/logs and independent review remain to collect.

## Fresh controller-check focused results (not accepted U9)

Author implemented the existing controlled check before verifier consumption in
Runner.adoption_role. PASS requires exact current candidate/revision/contract
binding, a real completed PASS receipt and stopped check ownership; non-PASS
verifier handling is unchanged. No verifier-only fallback remains.
Four focused cases passed: 4 tests, 0 failures, 20 excluded, 13.3 seconds;
`/private/tmp/symphony-u9-verifier-check-focused-60214-final4.log`.
They exercise fresh amended-contract execution/reuse, actual whitespace failure,
uncertain RUNNING check and wrong-candidate binding tampering, with blocked
consumption/release for failures. Root read the terminal summary. Canonical
integration, remaining direct-rework/MR joins, full frozen review and scoped
slice gate remain outstanding; no native or rollout acceptance is inferred.

The subsequent exact canonical ran one test/one failure (3 excluded, 66.1 seconds) after getting
past amended-contract controller check and push. MR preparation then deferred
unknown_request instead of preparing the current request. Raw log:
`/private/tmp/symphony-u9-canonical-60214-final2.log`.
The already-reviewed versioned completed-push MR identity/compatibility correction
is now explicitly proceeding in TicketMrOperation. Matching legacy requests remain
untouched; only validated terminal old history can roll to a new current envelope.
Expected missing-current-request preparation must not mask corrupt or uncertain
history. Focused identity/reuse tests precede another long canonical run.

First focused v2 binding case passed: one test, zero failures, 62 excluded,
34.3 seconds overall (28.7 seconds in the selected test body), log
`/private/tmp/symphony-u9-mr-v2-binding-focused-60214-retry.log`.
It asserts legacy v1 bind/key availability, a distinct new v2 request bound to
completed_push_sha256, and repeated preparation reuse. Root read the terminal
summary. Matching/unresolved legacy compatibility, complete canonical rework,
negative state matrix and frozen acceptance remain outstanding; this is not
MR integration or U9 acceptance.

The expanded MR compatibility case passed one test, zero failures, 62 excluded,
35.8 seconds overall; `/private/tmp/symphony-u9-mr-v1-compat-focused-60214.log`.
Root read the summary. It adds matching pending-v1 reuse without mutation and
mismatched pending-v1 rejection without creating a v2 request. Terminal-SUCCEEDED
rollover and complete lifecycle proof still remain.

The following canonical run reached retained-MR finalization too early:
one test, one failure, three excluded, 67.8 seconds overall;
`/private/tmp/symphony-u9-canonical-60214-v2final.log`.
The observed deferred reason was `ticket_mr_recorded_receipt_unproven`.
The sole writer is correcting the already-scoped Scheduler join: qualify the
current delivery's MR operation before Jira finalization, prepare only on exact
missing-current-request evidence, and preserve unresolved/corrupt-history fences.
Independent acceptance-gap mapping proceeds in parallel using docs and the prior
immutable snapshot, not the active writer's checkout.

The next canonical run failed at the initial review-ready assertion, before
amendment or direct rework: one test, one failure, three excluded, 40.0 seconds;
`/private/tmp/symphony-u9-canonical-60214-v2scheduler.log`.
The event was `ticket_delivery_mr_history_unproven` at test line 150. This is a
regression in the new Scheduler join, not proof that the fixture needs fabricated
post-review history. Initial current-MR receipt qualification must remain distinct
from post-review historical authorization. The immutable review snapshot is
`/private/tmp/symphony-u9-mr-v2-review.tt4jY3`, with matching source-before,
source-after and copied hashes in `sha256-manifest.txt`. Independent protocol
review is inspecting that copy in parallel; no canonical retry was launched.

Finite frozen review returned FIX_REQUIRED and confirmed the initial-delivery
regression. Scheduler must try ordinary fresh authorization first; only exact
`ticket_jira_not_dispatchable` may enter the guarded post-review fallback. The
current-MR operation still must be qualified before finalization. The reviewer
also identified a concrete error-swallowing defect: corrupt applicable READY
rework history must not fall back to older amendment history as if absent.
The sole writer received these two bounded corrections and focused regressions.
MR v1 serialization preservation, push-bound v2 identity and unresolved-v1
fencing were source-supported in this snapshot, not blanket U9 acceptance.
All eight copied digests matched before and after review; no active-checkout
inspection, live calls or review-time edits occurred.

Initial-MR focused test first failed on an old `unknown_request` expectation after
intentional candidate drift; current proof selection rejects earlier with
`ticket_push_current_candidate_unproven`. The exact negative expectation was
updated, retaining rejection/no-effect assertions. Logs:
`/private/tmp/symphony-u9-initial-mr-authorization-focused-60214.log`
(one test, one failure, 62 excluded, 44.0 seconds) and
`/private/tmp/symphony-u9-initial-mr-authorization-focused-60214-retry.log`
(one test, one failure, 62 excluded, 44.5 seconds).

The retry passed initial authorization and MR readback, then exposed a genuine
recovery regression: copied stale v2 request was silently absent from recovery
selection. Independent frozen review found the MR_RESULT SQL still filters
`delivery_operation.version = 1`. The sole writer must accept typed versions
1 and 2 while preserving all existing scope/binding/status filters and exact
expected-request-key validation. Existing stale-copy rejection assertions remain
unchanged; no rewriting the copied row to v1 or relaxing rejection is authorized.
The other focused history/rollover work proceeds in parallel with diagnosis.

Focused initial-MR recovery case now passed with the typed v2 SQL selection fix:
one test, zero failures, 62 excluded, 62.4 seconds overall;
`/private/tmp/symphony-u9-initial-mr-authorization-focused-60214-v2sql.log`.
Root read the terminal summary; author handle 7210 completed. Existing stale-copy
`ticket_mr_request_changed` rejection remains intact, with initial ordinary
authorization/admission, current receipt/readback and MR identity guards exercised.
This closes the focused initial-generation regression, not complete U9 acceptance.
Remaining post-review corruption/rollover and canonical rework proof proceed;
U10 exact interface/dispatch preparation runs in parallel on untouched U10 modules.

Corrupt applicable READY-history focused regression passed: one test, zero
failures, 50 excluded, 0.8 seconds overall;
`/private/tmp/symphony-u9-corrupt-ready-history-focused-60214-rerun.log`.
Root read the terminal summary. The earlier bare `mix` invocation exited 127
before testing and is not a verdict. Root verified the configured runtime through
`mise which mix` (Elixir 1.19.5-otp-28, Erlang 28.5); subsequent tests use the
existing `mise exec` route without runtime upgrades or settings changes.
Terminal legacy MR rollover and the complete canonical rework remain unproven.

The attempted terminal-v1 focused fixture was rejected at fresh issuance:
one test, one failure, 63 excluded, 25.3 seconds;
`/private/tmp/symphony-u9-terminal-v1-rollover-focused-60214.log`.
It substituted an old completed-push digest against the current push, so claim
returned `ticket_mr_request_binding_mismatch`. This is the intended fence, not
a product defect; no waiver or manufactured terminal claim is authorized.
The required replacement proof uses a valid matching v1 request issued/completed
on its actual prior push, preserved across real direct no-edit rework and a fresh
verifier/push of the same candidate/contract/revision. Only then does the changed
completed-push digest discriminate same-key v1-to-v2 rollover. A different
revision/candidate alone changes the legacy key and cannot substitute for this
specific proof. Reuse the existing lifecycle fixture, not a new harness.

The valid-history canonical ran one test, one failure, three excluded, 77.0
seconds; `/private/tmp/symphony-u9-canonical-v1-to-v2-60214.log` (handle 62689
completed). It failed during the first post-amendment broker MR claim, before
legacy issuance/rework: `ticket_jira_not_dispatchable` at test line 322.
Root inspected the prior immutable MR source: `read_claim_authorization/5`
still invokes initial `Runner.authorization/3` directly, unlike the repaired
Scheduler delivery path. Treat this as an uncorrected product caller join,
not permission to change fixture Jira labels. The sole writer is correcting
ordinary-first/exact-not-dispatchable guarded fallback and retaining fresh
candidate/check/original-MR-history proof. The existing delivery authorization
seam can centralize that policy for both callers; source authorization remains
unchanged. No successful legacy rollover is inferred from this failed run.

Subsequent same-selector runs remain failures, not acceptance:

- Auth-seam run: 37.7 seconds, fixture expected optional `delivery_review`
  explicitly false where ordinary proof correctly omits it; corrected known
  initial/post-review helper expectations without general MR-presence inference.
- Auth retry: 78.8 seconds, `mr_guard_native_turn_mismatch`; shared fixture used
  hard-coded original turn rather than the request's current native turn.
- Native-guard retry: 79.8 seconds, `turn_replayed`; helper reused completion
  turn ID across requests. Request-specific synthetic IDs are required; native
  turn uniqueness must remain enforced.

Logs are `/private/tmp/symphony-u9-canonical-v1-to-v2-authfix-60214.log`,
`/private/tmp/symphony-u9-canonical-v1-to-v2-authfix-retry-60214.log` and
`/private/tmp/symphony-u9-canonical-v1-to-v2-nativeguard-60214.log`.

Fresh Sol 6.1 medium admission review of immutable
`/private/tmp/symphony-u9-ready-review.P7CR3P` found one required replay defect:
`prior_run_json` plus recomputed adjacent digest can alter historical MR/contract/
branch authority without comparing the original independently recorded APPLIED
event or immutable command binding. The writer must seal replay against the
original event receipt and command run/candidate/revision/contract identity,
preserving legitimate replay after later run progress. A focused recomputed-digest
tamper test precedes another canonical run. Existing transactional admission,
competing-work fences and access structure received bounded provisional PASS;
READY-specific restart/uncertain/no-launch/rollback evidence remains to collect.
All 17 copied hashes stayed unchanged during review. The review excluded changing
authorization/delivery joins and is not overall U9 acceptance.

The replay-sealed canonical ran one test, one failure, three excluded, 101.8
seconds; `/private/tmp/symphony-u9-canonical-v1-to-v2-sealed-60214.log`, handle
8120 completed. Root subsequently matched raw stack line 324 to the immutable
test source: it failed at `ready_after_amendment`, immediately after the first
post-amendment legacy v1 MR completion, before direct rework begins at line 327.
The author's earlier report that this run traversed direct rework/fresh push/v2
was incorrect, and root's corresponding chat update is withdrawn. Neither the
direct-rework replay-seal test nor the v1-to-v2 rollover assertions executed.
State remained MR_CREATING, not READY; that transition's tick events were
discarded and the precise deferred reason is not yet proven. Capture typed
events at both readiness transitions; do not speculate or waive either assertion.

Frozen delta `e0xQok` replay-seal review returned bounded source PASS, and all
18 hashes remained unchanged. Add an MR-only recomputed-digest tamper mutant:
the existing combined contract/branch/MR mutation rejects at command binding
before independently exercising the original APPLIED-event seal.

Protocol review of the same frozen delta returned one FIX_REQUIRED:
`ready_rework_kind` treats legitimate BLOCKED_WRITER_RESUMED history as READY
because both contain `request_rework`. Introduce a disjoint validated historical
BLOCKED branch; malformed/unclassified or corrupt READY history must still fail
closed. Central ordinary-first fresh authorization, current-MR qualification,
typed v1/v2 recovery and unissued legacy fixture replacement received finite
source-supported approval, not complete U9 acceptance. The writer will bundle
these named corrections and final-event capture before another canonical run.

The bundled retry captured the actual post-amendment error: both readiness ticks
returned `ticket_jira_not_dispatchable`, before direct rework. One test, one
failure, three excluded, 99.7 seconds overall;
`/private/tmp/symphony-u9-canonical-bundled-final-retry-60214.log`.
Root source inspection and independent frozen review identified the remaining
Finalization initial-only authorization and same-push-generation Journal identity
joins. The approved exact packet is `../006-U9-finalization-handoff.md`.
It preserves legacy START_IMPLEMENTATION bytes and uncertainty/history fences,
uses central current-MR-proved delivery authorization, and adds REVIEW_READY-only
current-push identity/reservations without rewriting old released records.
Same-generation terminal/released state inconsistency is reconciliation, never
new acquisition. No real Jira mutation or deployment was performed.

Frozen prerequisite source: `/private/tmp/symphony-u9-finalization-design.xvrwFI`,
eleven matching hashes, manifest
`43399b39b09e6015caf9e5351f5ad8cd4aa068954cbcdd7aa9b6b4a465fd99c6`.
Independent test-selector prep runs on the frozen existing test snapshot
`/private/tmp/symphony-u9-journal-tests-review.15243.` while the sole writer
implements the bounded product join. The current product diff is not yet frozen
or accepted; compile warnings are being repaired before focused tests.

The bounded Finalization/Journal generation join now compiles with warnings as
errors and passes scoped SpecsCheck (author-reported; final static log collection
still required). Focused versioned identity test passed: one test, zero failures,
64 excluded, 27.1 seconds overall;
`/private/tmp/symphony-u9-journal-v2-focused-60214-retry.log`.
Root read the terminal summary. It is selector/identity evidence using actual
retained push proof, not independent MR qualification or complete delivery proof.

Existing uncertain-finalization recovery case ran one test, one failure, 64
excluded, 65.5 seconds; `/private/tmp/symphony-u9-finalization-focused-60214.log`.
The first failing assertion expected `ticket_jira_operation_missing` for no
journal; the new selector returned `ticket_jira_recovery_unissued`. The writer is
preserving the original no-journal error contract and rerunning that same case.
Later recovery/canonical assertions did not execute and are not inferred green.

Further focused recovery repairs preserve the existing rejection assertions:
exact stale-reservation propagation; active same-generation MAINTENANCE options
shared by delivery admission/authorization and MR readback; genuine absent review
history distinct from corruption; eager malformed-checkout rejection retained
with its established `jira_workspace_binding_unproven` error.
The interrupted owned test 44501 has no verdict; root explicitly stopped that
known-incomplete candidate, not any service/broker. No test was restarted merely
because observation expired.

The shared-admission recovery run reached both effect readbacks and aborted
release checks, then failed inside malformed-checkout validation before the
trigger was removed or READY recovery ran: one test, one failure, 64 excluded,
232.1 seconds; `/private/tmp/symphony-u9-finalization-focused-60214-shared-admission.log`.
The author's claim of READY release for that run was withdrawn after root matched
the exact stack against frozen lines 3132–3138. The final release remains unproven.

Paired pre-review amendment history case now passed: one test, zero failures,
64 excluded, 73.4 seconds; `/private/tmp/symphony-u9-pre-review-amendment-history-focused-60214.log`.
Root read the terminal summary. It checks genuine nil-MR history as absence and
corrupted receipt as hard error. Frozen current candidate:
`/private/tmp/symphony-u9-finalization-ready-candidate.an2EJE/`, manifest included.
Finite delta review and the same focused recovery test 22493 proceed in parallel;
`/private/tmp/symphony-u9-finalization-focused-60214-readycandidate.log`.
Complete recovery, canonical READY rework and U9 boundary gates remain incomplete.

Finalization recovery now passed on that reviewed frozen candidate: one selected
test, zero failures, 64 excluded, 277.6 seconds; log
`/private/tmp/symphony-u9-finalization-focused-60214-readycandidate.log`.
Root read the terminal summary. Independent finite delta review returned PASS
with all ten frozen hashes unchanged (manifest
`1d4cfd38145eff78fd48df9bfeb31a7bae74756dc27d29082a9de548bbef021c`).
This proves the selected uncertain-comment/issued-label recovery case, not the
complete direct READY rework path. The single bundled canonical is in progress
in `/private/tmp/symphony-u9-ready-rework-canonical-60214-final.log`; observation
handle lookup failed, but the writer independently confirmed live shell PID
85439 and beam PID 85447. No duplicate test was started. A read-only acceptance
gap audit runs in parallel; U9/Slice 4 remains unaccepted.

That canonical subsequently terminated: one test, one failure, three excluded,
138.5 seconds. Root read the terminal stack at lifecycle test line 415: the
direct READY command remained ACCEPTED after the nil-supervisor preparation
attempt, where APPLIED was required. The first post-amendment READY transition,
low-capacity deferral and terminal-event rollback assertions preceded this
failure; later RESERVED reopen, START_SENT and same-SHA rollover assertions did
not execute. The sole writer is diagnosing the exact preparation result without
weakening the assertion or restarting the earlier live process.

Parallel acceptance-gap audit bounded the remaining local gate to Journal/MR
legacy-v2 reuse/rollover and corruption fences; READY generation/owner drift,
uncertain no-relaunch and rollback including model allocations; reservation race
and correction distinctions; then frozen review and the specified three-file
U9 boundary test group. Extra fault permutations and broad coverage sweeps are
not required before this gate. Native busy-parent/human-input acceptance remains
separate and unproven.

The parallel reviewer refined that list against immutable current Journal and
lifecycle copies at `/private/tmp/symphony-u9-journal-gap.dDsni2/`. Existing
versioned-identity and finalization tests already cover v2 active reuse,
uncertain/reopen, single external effect, held release rollback and eventual
release. Do not add another v2 recovery pipeline. Remaining Journal assertions
are exact active/COMPLETE-held legacy reuse, current-generation released v1/v2
rejection, older intact released legacy rollover with unresolved/corrupt
predecessor fences at the genuine canonical push barrier, and a byte-pinned
START_IMPLEMENTATION identity in its existing unit test.

Diagnostic-only canonical delta retains the failing APPLIED assertion, exposes
its exact preparation result/run state and extends protected rollback rows with
`model_routes`. Its immutable copy is
`/private/tmp/symphony-u9-canonical-diagnostic-delta.lmXuJh/`.
One same-selector diagnostic rerun is in progress at
`/private/tmp/symphony-u9-ready-rework-canonical-60214-diagnostic.log`; no product
fix has been guessed and no full suite was started.

The diagnostic rerun terminated at the same barrier (1 test, 1 failure,
3 excluded, 139.1 seconds). Its ExUnit pattern-assignment argument raised
MatchError before the custom message rendered, so it did not disclose the
preparation event. The next test-only correction checks status before
destructuring and retains the actual tick result in the diagnostic. This is
not product acceptance or evidence of a new causal error; no product guard is
being changed without that error. The earlier protected-row assertions,
now including model routes, preceded the failure.

The result-capture rerun exposed the exact failure: Scheduler returned
`TICKET_DEFERRED` with `:factory_task_route_mismatch`, no launches, while the
run remained READY_FOR_REVIEW and the direct command remained ACCEPTED.
Terminal result: one test, one failure, three excluded, 138.5 seconds;
`/private/tmp/symphony-u9-ready-rework-canonical-60214-cause.log`.
Root read the captured tick and terminal assertion. The sole writer is tracing
the current rework/task-route binding; historical model-route/delivery evidence
must not be rewritten to qualify a new turn.

Source diagnosis located the mismatch in
`TaskLauncher.prepare_ready_rework_transaction/2`: the existing consumed writer
is loaded but the placement assignment was hard-coded to nil project/section,
then rejected against the task's recorded non-nil project. Independent protocol
review of immutable four-file snapshot
`/private/tmp/symphony-u9-route-review.A7uhWx/` approved preserving the existing
task placement for this same-task rework, keeping route validation and normal
writer model selection intact. It also requires consistent launch-option and
ledger placement, and atomic rejection of explicit conflicting placement.
The sole writer owns that bounded correction and focused regressions; no
runtime PASS for the correction is inferred yet.

Independent post-patch review of
`/private/tmp/symphony-u9-ready-route-delta.KsZukk/` returned FIX_REQUIRED:
preserving assignment in `prepare_task` alone leaves caller project/section in
`worker_opts`, which `run_task` passes to the provider. The bounded correction
must preserve placement in both ledger and invocation options, reject explicit
non-nil conflicting caller placement atomically and keep normal model routing
unchanged. Requested regressions distinguish retained non-nil placement, nil
placement and conflicting project/section. No acceptance is inferred from
compilation or a lifecycle that does not assert invocation placement.

Final bounded routing delta now has independent source PASS on immutable
`/private/tmp/symphony-u9-ready-route-final.8uFYbv/` (12 matching pairs,
manifest `5195e4b1eacba45d29219f63704a1a704b53ff071a28857d07c36ca6b9c4ff91`).
The assignment guard runs before mutation, rejects conflicting caller placement,
and feeds the same retained project/section into task refresh and invocation
options. Model routing and existing route validation remain unchanged.
Focused guard test passed: one test, zero failures, seven excluded, 0.2 seconds,
seed 60214; `/private/tmp/symphony-u9-ready-route-guard-60214.log`.
Root read the terminal summary. This accepts the finite guard behavior, not
the full direct READY rework lifecycle; the same canonical is next.

The corrected-placement canonical still terminated with
`:factory_task_route_mismatch` (one test, one failure, three excluded,
138.4 seconds; `/private/tmp/symphony-u9-ready-rework-canonical-60214-route-fix.log`).
Root read the terminal result. The placement delta is independently valid but
is not established as the causal repair for this lifecycle. That typed error
also occurs in the pre-transaction existing-task run/role guard. A bounded
temporary diagnostic will record both comparisons in one run, then be removed;
no typed-error or ownership assertion is loosened. Later rework assertions
remain unexecuted.

Guard-capture run terminated with the same error (1 test, 1 failure,
3 excluded, 138.8 seconds;
`/private/tmp/symphony-u9-ready-rework-route-capture-60214.log`).
Retained task readback shows logical role `feature-writer`, nil project/section
and CONSUMED status. No ready-rework-gated guard probe printed. Thus neither
the originally assumed non-nil placement mismatch nor a different retained
logical role is established as this fixture's cause. The next diagnostic must
capture actual failing entry/guard tuples without assuming the READY option
has already reached that path. Product fences remain unchanged, and temporary
probes must be removed before frozen acceptance.

Parallel frozen caller review proves explicit READY dispatch inserts the
`ready_rework` map before `TaskLauncher.launch` and retains those options.
Generic stage launch is a distinct path and gets READY context only from a
recovered prompt descriptor. The next diagnostic captures both failure-site
tuples unconditionally and correlates task key/state/stage/options with loaded
module location. Typed error returns stay unchanged; no ticket prompt/body is
dumped. No model/role change is justified by the current evidence.

Unconditional route capture proved the actual comparison failure:
`validate_task_route` received a run with nil `run_id`, while the loaded task
and launch entry shared the correct run ID and matching logical role/placement.
The loaded beam path was the expected implementation checkout. Terminal result:
one test, one failure, three excluded, 161.1 seconds;
`/private/tmp/symphony-u9-ready-rework-route-instrumented-60214.log`.
Root read the exact tuples and terminal result. The sole writer will remove all
probes and reload the complete durable run inside the existing transaction after
its state update, before task preparation. No identity guard is weakened and
no caller-supplied partial map is treated as full run authority.

Root verified the precise update contract in `RunLedger.update_run`: it returns
`{:ok, %{result: "UPDATED", run: get!(transaction, run_id)}}`. The caller had
passed that wrapper to task preparation rather than its read-backed run row.
Correcting the local handoff does not require changing RunLedger's interface or
relaxing task identity, placement, model or ownership checks.

The wrapper-only correction is now independently source-reviewed PASS on
`/private/tmp/symphony-u9-ready-run-wrapper-fix.DHx0uE/`; all twelve hashes
matched, manifest
`4cc49b3ff692cb12dcaf0a4f4677d4973c8f9c1a3514e37939de4b8f1a19b93d`.
Launcher SHA `f6d2480de1ec3ed7fc23607dc1ad08e5edcf8d1598be11dd6b7ca81600a0792d`.
The existing update result is destructured to its actual read-backed run row.
Admission/capacity/predecessor and outer rollback checks stay unchanged; all
temporary probes are removed. Same-selector regression is live at
`/private/tmp/symphony-u9-ready-rework-canonical-60214-run-wrapper-fix.log`.
Root independently observed shell PID 36921 and beam PID 36929. Source PASS
does not establish runtime lifecycle acceptance.

Wrapper-fix canonical progressed through APPLIED/RESERVED preparation and
database reopen, then failed its real checkout HEAD-drift rejection:
`head_drift_attempt` returned a launched writer instead of no launches.
Terminal: 1 test, 1 failure, 3 excluded, 168.7 seconds; lifecycle line 456;
`/private/tmp/symphony-u9-ready-rework-canonical-60214-run-wrapper-fix.log`.
Root matched the actual terminal stack to the frozen test. This demonstrates
the prior wrapper failure is cleared but does not accept the cycle: prepared
READY recovery must recheck actual HEAD against the exact reserved candidate
before launch. Independent frozen prelaunch analysis and the sole writer's
bounded correction proceed in parallel; later START_SENT/rollover/release
assertions remain unproven.

Independent frozen analysis and writer diagnosis agree: prepared READY reuse
called `WorkspaceAccess.validate(clean: true)` without `candidate_adopted: true`.
For SOURCE mode, the default validates cleanliness but supplies no HEAD SHA,
so an empty committed change is not rejected. The existing candidate-adopted
option pins the current candidate, already matched to the sealed READY receipt
earlier in this path. Apply that option only to prepared READY reuse; do not
change the global SOURCE default, because ordinary writers legitimately change
HEAD before candidate adoption. Existing generation/request/attempt checks
remain, and the current canonical HEAD-drift assertion is the regression.

HEAD-fence delta frozen at
`/private/tmp/symphony-u9-ready-head-fence-delta.2CUoLY/manifest.md`;
same named canonical is running at
`/private/tmp/symphony-u9-ready-rework-canonical-60214-head-fence.log`.
Finite review runs in parallel. Adjacent read-only check found prepared reuse
still omits the accepted retained-placement guard/option propagation applied
to initial READY preparation. Writer independently confirmed this omission;
after the current execution terminates, reuse must validate the existing
assignment and pass it into invocation options too. Do not edit the running
candidate or infer non-nil placement recovery from this nil-placement fixture.

The one-option HEAD-fence canonical still failed at line 456: one test, one
failure, three excluded, 162.8 seconds. Root read the terminal assertion;
the restarted tick still reported one launched writer. Source review PASS
established the option's intended semantics, not that this recovery invocation
reached the modified seam. Next bounded diagnostic records actual recovered
descriptor/selected branch and validation result before further SHA fixes.
The zsh wrapper printed no valid ACTUAL_MIX_EXIT, so its zero tool exit does not
override ExUnit's one-failure verdict; future captures must use correct
pipefail/exit-code handling. No duplicate execution is authorized by that
wrapper issue.

Parallel frozen review found a concrete fixture-target error to resolve before
claiming a product recovery bypass: the admitted checkout is local `path` at
line 88, while the new rollback HEAD snapshots and drift injection/restoration
use unchanged setup `ctx.path` (lines 370, 383, 401, 432–435, 463, 466).
Root read the frozen admission and these exact references; `ctx` is rebound
only for run ID/store, not source path. Capture both checkout identities and
HEADs, then target the proven admitted source in this test. The prior claim
that a real source-HEAD drift launched a writer is not established until the
test's filesystem target is correct. Preserve the rejection assertion and do
not change another product guard to accommodate a wrong-target injection.

The writer independently confirmed the wrong-target references. The owned
diagnostic was deliberately stopped after recording that restart forwarded
`ready_rework.prepared: true`; it has no terminal test verdict and is not a
timeout-triggered restart. Correct all new source HEAD snapshots/injection/
restoration to the proven admitted checkout and assert reservation identity
before mutation. Bundle the already identified prepared-placement propagation
correction before the next same-selector run, avoiding separate lifecycle
runs for these adjacent fixes. No real checkout or service is reset/stopped.

Combined correction is frozen at
`/private/tmp/symphony-u9-ready-head-placement-delta.qktyid/manifest.md`.
Independent finite source review PASS; all 12 pairs unchanged, manifest
`fbd5110c3efdeeb335246f051c36e8c6dc728a550de2b0132ffbdc5f080d1c86`.
Prepared reuse validates/propagates retained placement; all candidate/request/
generation/RESERVED/HEAD and START_SENT fences remain. The corrected fixture
asserts admitted path == run.worktree == reservation canonical_path before
mutating that actual source HEAD, restores its captured branch/SHA in `after`,
and reads HEAD back. Temporary probes removed. Same-selector runtime regression
is live at `/private/tmp/symphony-u9-ready-rework-canonical-60214-admitted-head.log`;
no runtime PASS is inferred from source review.

Corrected-target canonical terminated at a later duplicate mailbox assertion:
1 test, 1 failure, 3 excluded, 184.4 seconds; lifecycle line 535;
`/private/tmp/symphony-u9-ready-rework-canonical-60214-admitted-head.log`.
Root read terminal and frozen lines 480–555: actual-source HEAD rejection and
restoration, held START_SENT reopen/no-relaunch, exact same-thread start/finish
and start-count-one assertions preceded the failure. Lines 506–508 consumed
the events; the second receive at 535 waited for those same events again.
Removing only that duplicate block is justified; original proofs and later
fresh verifier/push/READY assertions remain. This is test repair, not another
product fix or complete lifecycle acceptance.

Test-only correction frozen at
`/private/tmp/symphony-u9-ready-head-placement-final-delta.PpbXvc/manifest.md`;
lifecycle test SHA `d6f4d3c782952e0ecd5429ece4bfe1e99ddbf1c50588c2026b43a511e415ec89`.
Product hashes unchanged from qktyid. Finite review and single same-selector
canonical proceed in parallel at
`/private/tmp/symphony-u9-ready-rework-canonical-60214-final-delta.log`.

That canonical terminated at the next controller adoption boundary:
1 test, 1 failure, 3 excluded, 174.7 seconds; lifecycle line 536.
After exact same-thread writer completion, the next tick returned no launches
but run state remained REVIEW_WRITING rather than VERIFYING. Root read the
terminal stack and frozen assertion; no complete lifecycle PASS is claimed.
The sole writer will capture compact tick events/task/evidence outcome before
changing product behavior. Independent frozen completion/adoption trace runs
in parallel; giant candidate-handoff dumps are not a useful diagnostic.

Frozen adoption trace confirms the V1 completion seam exists: recorded worker
adoption reconciles file operations, pins the no-edit candidate, requires the
controller diff check, then transactionally transitions/consumes/releases.
Source START/FINISH is not controller adoption proof. The compact diagnostic
must expose the exact deferred reason and current evidence/check status.
Separate review noted a V1/legacy READY-preflight policy discrepancy; it is not
the observed unchanged-state cause. Do not automatically add a READY preflight
exemption: the approved handoff requires configured preflight to be honored.
Resolve that discrepancy against the contract only after the actual adoption
failure is identified, without changing unrelated policy speculatively.

Root source inspection found a concrete no-edit fixture/packet mismatch:
`TicketWorkerRunner.ready_rework_packet/3` inserts `direct_ticket_rework` into
the flat decoded base packet, leaving `role` at top level. The fixture's
direct-rework output clause instead matches a nested `base_packet.role`.
That intended no-edit clause cannot match the actual packet; the ordinary
source-slice fallback writes/declaratively lists `fixture.txt`, potentially
identical to its existing `second` content. Correct the fixture dispatch shape,
not Worktree's exact path equality. Preserve blocked-wrapper and ordinary
writer clauses and require runtime confirmation on the real packet afterward.

The output-capture execution actually reached terminal before the writer's
planned stop; it is not an interrupted/no-verdict run. Root read its result:
1 test, 1 failure, 3 excluded, 200.0 seconds, exact output COMPLETE with
`changed_paths: ["fixture.txt"]` and `feat(PPL-123): second slice`, deferred
`native_slice_paths_mismatch`; review_base_sha nil.
Log `/private/tmp/symphony-u9-ready-rework-canonical-60214-output-capture.log`.
This confirms the fallback fixture output. The matcher alone now targets the
actual flat role/direct_ticket_rework shape; product comparisons unchanged.
Frozen delta `/private/tmp/symphony-u9-ready-rework-flat-fixture-delta.QHKVCb/manifest.md`;
finite source review and same-selector regression proceed in parallel.

Finite fixture-only review PASS; four hashes unchanged, manifest
`450706865c46d45ca5c09dfbeed401037d9b89f7a156836a88db7795204bf149`.
Corrected flat-packet canonical then terminated later at push preparation:
1 test, 1 failure, 3 excluded, 211.8 seconds; actual exit 2; lifecycle line 568;
`/private/tmp/symphony-u9-ready-rework-canonical-60214-flat-fixture.log`.
Exact event: TICKET_DEFERRED `ticket_push_history_unproven`, no push completion.
Root read the terminal assertion. Direct READY admission, actual checkout
restart/HEAD drift handling, same-thread one-start recovery and fresh verifier
preceded this failure; full retained-MR READY return remains unproven.
The next bounded correction must qualify the new verified round while keeping
historical push evidence unchanged—not clearing or copying old receipts.

Independent frozen trace identified the exact missing historical identity:
READY predecessor's `prior_run` projection omits `issue_key`, `repo_path`,
`base_branch` and `mr_state`. Historical push validation requires the first
three; original MR identity requires the fourth. The amendment path retained
them, explaining why that earlier cycle worked. Seal these original fields
only when preparing new READY rework. Strict comparisons, old receipt bytes,
push generation and source/release provenance stay unchanged. Do not add push
v2 or fill historical missing fields from mutable current run data.
Static comparator/producer evidence is sufficient to dispatch this bounded
fix; another capture-only whole lifecycle is unnecessary.

Four-field producer correction applied and frozen at
`/private/tmp/symphony-u9-ready-final-source-delta.Ej9FH1/manifest.md`;
13 exact source/copy pairs. Author reports compile/scoped specs pass; finite
review and same canonical run are next/in parallel. Old receipt bytes and
history comparisons remain unchanged. The execution plan now explicitly
requires checking return/projection contracts and actual fixture identity
before rerunning solely for diagnostic information already in frozen code.

Finite four-field seal review PASS; 13 matching pairs, manifest
`1e44c509c540dcae29ba4bf5d7e664c1cc2b0f639b3af19b0d94bb0f89d5f25f`.
Required historical Push/MR fields are now sealed in original preparation;
existing digest/application-event origin proof covers the expanded snapshot.
No old receipt or strict history comparator changed. Same-selector regression
is live at `/private/tmp/symphony-u9-ready-rework-canonical-60214-prior-proof-seal.log`.
Do not infer complete no-edit rollover or retained-MR READY acceptance before
the terminal result.

Full named offline no-edit canonical now PASSED: seed 60214, 1 test,
0 failures, 3 excluded, 288.0 seconds, actual exit 0. Root read the terminal
summary and frozen final assertions: same candidate with a new push envelope,
MR v2 bound to that envelope, a distinct request from retained legacy v1, and
final READY_FOR_REVIEW on the original MR. Root independently hashed all 13
current/frozen pairs after completion: all match, no mismatches.
This accepts the named no-edit lifecycle checkpoint, not every U9 requirement.

Three existing focused compatibility checks also passed on current source:
unresolved old-v1 MR/different digest rejection, repaired-candidate new exact
push, and v2 journal identity/active reuse. 3 tests, 0 failures, 62 excluded,
103.2 seconds, exit 0;
`/private/tmp/symphony-u9-ready-journal-mr-matrix-60214.log`.
Root read its terminal summary. Remaining legacy journal negative/release
matrix, READY generation/owner-loss, edited direct READY, reservation race,
frozen review and scoped boundary gate remain. Native busy-parent acceptance
and Slice 5/final rollout are separate. No completion claim for Slice 4.

Current-candidate reservation classification reproduced RED with the exact
missing-Jira-effect error, then passed after a bounded producer-side distinction:
only a validated same-run RESERVED active owner with no Jira-effect row reports
reservation conflict. Existing effect/history cases keep correction proof logic.
Post-fix logged group includes the original true concurrent race, not just a
sequential substitute: 2 tests, 0 failures, 50 excluded, 1.0 seconds, exit 0;
`/private/tmp/symphony-u9-current-proposal-race-60214.log`.
Existing stopped non-PASS, uncertain/invoking/reconciling/authorized and
nonqualifying PASS correction distinctions: 3/0, 33 excluded, 7.3 seconds,
exit 0; `/private/tmp/symphony-u9-ready-correction-distinction-60214.log`.
Root read both logged terminal summaries. Frozen finite review packet:
`/private/tmp/symphony-u9-current-proposal-race-review.VnETSv/manifest.md`.
Legacy Journal matrix and remaining READY recovery/edited path follow; no
new full suite or harness is authorized for this checkpoint.

Finite reservation-race review PASS: all five hashes unchanged, manifest
`219ef16b42c603c40dce662496537ce48137c6a1817a17305ee87dbe824c8217`.
Invalid/corrupt owners propagate errors; foreign/nonmatching owners and
existing-effect cases preserve original correction/uncertainty checks.
Original concurrent race assertions remain intact. This bounded checkpoint
is accepted locally; remaining U9 gates and final quality acceptance remain.

Remaining legacy/v2 Journal release tests initially failed before selection
with `ticket_jira_stage_not_admitted`: prepared MR setup had no recorded URL.
They did not exercise the intended guards. The fixture now uses existing
`assert_mr_adoption` synthetic request claim/complete/readback rather than
manually seeding MR identity. Their scope is Journal identity and maintenance
ownership/release, not live external-delivery authority. Focused run 54179
is in progress; no acceptance inferred from setup repair.

Parallel preparation finished the next exact barriers: READY generation drift
inside the existing prepared recovery block; edited READY after the current
canonical end-state; terminal actual START_SENT owner loss last, using captured
owned PIDs and registry absence, with no fabricated death/status evidence.
These reuse existing fixtures and keep runtime/capacity limits unchanged.

After genuine synthetic MR readback, the legacy test reached the intended
guard and failed `ticket_jira_legacy_review_ownership_unproven`; explicit
reservation/request/generation tuple assertion passed. Static producer/caller
inspection identified a return-shape error: `current_legacy_review/2` succeeds
with `:ok`, while `current_legacy_reuse/3` matched `{:ok, _}`. Correct only that
match, preserving all ownership validation. The v2 released-current selector
rejection is its actual `stale_workspace_reservation` error, not a downstream
prepare failure; legacy current-release rejection is distinct.

Focused group now PASSED after correcting only that producer/caller match:
3 tests, 0 failures, 74 excluded, 152.5 seconds; seed 60214;
`/private/tmp/symphony-u9-ready-legacy-journal-held-60214-pattern-fix.log`.
Root read the terminal summary and executed names. Group includes byte-pinned
START_IMPLEMENTATION identity, matching active legacy REVIEW_READY held reuse
and real completion/release/current-generation rejection, and corresponding
v2 release rejection. It does not prove older-generation rollover or unresolved/
corrupt predecessor rejection, which remain at the real push barrier.
Finite source review is next; no full U9/Slice 4 acceptance claimed.

Distinct final candidate run also passed: 3/0, 74 excluded, 153.1 seconds,
exit 0; `/private/tmp/symphony-u9-ready-legacy-journal-held-60214-final.log`.
Root read this terminal result separately from the earlier pattern-fix log.
No active handle remains. Final 9-file review packet:
`/private/tmp/symphony-u9-legacy-journal-review.tiCbCC/manifest.md`.
Do not repeat the identical group without a candidate change. Finite review
runs alongside remaining older-generation matrix preparation.

Finite current-generation legacy review PASS: all 9 hashes unchanged, manifest
`0b2fc0a6c10ba62548a2b3152891d66eee8b1eb4a3b1ba82f3f8793ffc0cfb3f`.
Only the helper success-pattern match changes production behavior; original
binding/ownership/released-key validation remains. Tests use real synthetic
MR adoption and public claim/reconcile/release, not fabricated authority rows.
This checkpoint is accepted locally. Older-generation valid released rollover,
genuine pending/uncertain predecessor and separate corruption cases remain;
new operation/reservation/effect counts must stay unchanged on rejection.

Parallel old-generation source review found no additional return-shape defect.
It identified a bounded v2/legacy lineage asymmetry: v2 prior history currently
accepts different-push COMPLETE/released rows without the lower verifier-round
condition required for legacy terminal history. Pin equal/future-round rejection
at the shared genuine push barrier, not with another complete setup.

Correction to the earlier preflight interpretation in this receipt: rereading
`006-U9-ready-rework-handoff.md` adversarial constraint 1 proves READY rework must
first enter fresh VERIFYING even when ordinary initial-delivery preflight is
configured. The earlier instruction not to add a READY exemption was mistaken;
ordinary initial preflight remains unchanged. Include configured-preflight READY
coverage in the edited case and preserve fresh verification. The exact remaining
recovery/edited/owner-loss execution packet is now saved in that handoff document.

Older-generation Journal tests now pass: valid genuinely released legacy
predecessor to real new push/v2 selection with corruption rejection (1/0,
68 excluded, 99.9 seconds;
`/private/tmp/symphony-u9-old-legacy-rollover-60214-rerun.log`), and genuine
FIRST_PENDING predecessor rejection (1/0, 68 excluded, 97.0 seconds;
`/private/tmp/symphony-u9-old-legacy-unresolved-60214-rerun.log`).
The latter's first failure was a test COUNT expectation (map, not nil), not a
product verdict; after correction root read its actual terminal PASS.
Frozen packet `/private/tmp/symphony-u9-old-journal-matrix-review/`:
Journal `0614d30c6a73c26eb11d736f25057de2a4e337d8d5d885dbbd4726aa07a968aa`,
lifecycle `de7dd0ccf42f53b25a2333ec91bfb249ad7cfd97379ef71da59e4777850612be`.
Strict lower-round history guard is present; no fully intact equal/future
authority can be produced by supported API without forging/corrupting proof.
Runtime coverage of that impossible setup is not claimed. Finite independent
review will check the guard and legitimate v2 behavior before acceptance.

Finite old-matrix review returned source PASS for the lower-round guard and
confirmed genuine legacy completion/release/new push, unchanged old rows,
corruption/pending rejection and zero new ownership/effects. Runtime matrix
acceptance is partial: natural older v2 COMPLETE/released to new v2 selection
still needs execution. Close that in the already planned edited canonical
using its no-edit READY v2 predecessor. Do not manufacture both completed v1
and v2 histories in one generation solely to reach a test branch. Capture
original v2 row/access and prove unchanged bytes after the edited real push.

Paired ordinary initial-preflight regression now passes: 1 test, 0 failures,
69 excluded, 17.6 seconds; seed 60214; log
`/private/tmp/symphony-u9-initial-preflight-60214-rerun.log`.
Root read the terminal summary and selected test name. This proves configured
initial writer adoption still enters CI_PUSHING without a verifier-round
increment; the preflight SHA is correctly absent before the push itself.
The first assertion expected that later SHA too early and was corrected.
Edited READY routing and the combined recovery delta still await frozen review
and execution; this narrow PASS does not accept them.

Combined six-file pre-execution freeze:
`/private/tmp/symphony-u9-final-ready-lifecycle-delta-60214/`.
Root and both finite reviewers verified producer hashes. Review is FIX_REQUIRED,
not acceptance: READY preflight compares the receipt's old candidate to the
post-adoption new candidate; use the exact request's immutable expected_sha.
Tests also use unsupported rework phrases, expect a reconstruction error from
the START_SENT adoption route, and fail to distinguish generation drift from
simultaneous HEAD drift. Sole writer is correcting only these named defects.

Timeout clarification: prior selected-test trace was 284391 milliseconds, not
merely 288-second whole-command time. Installed Mix test documentation explicitly
states trace mode ignores test timeouts and uses infinity. Root authorized a
600000ms timeout tag for this single expanded integration case, run without
trace, preserving module defaults and the product's 180-second worker timeout.
No product timeout or capacity gate changed. The long combined case has not run.

Corrected six-file freeze:
`/private/tmp/symphony-u9-final-ready-lifecycle-delta-corrected-60214/`.
Scheduler `226c2007635b2ec935aaa267c32d080b6ded00031360a163dc75aa228e3d61b7`;
canonical `e32aee4138ca241c5f98a0bb0dde2a8fbbd26e61e69d41655088b60e6eede3ec`;
other four files match the rejected freeze's hashes. Both finite reviewers
verified unchanged hashes and returned bounded source PASS for named fixes.
Root authorized one canonical execution without trace, seed 60214. This review
is pre-execution only; runtime acceptance and the scoped U9 batch remain pending.

Expanded canonical is terminal: 1 test, 1 failure, 3 excluded, 237.3 seconds;
seed 60214; `/private/tmp/symphony-u9-ready-expanded-canonical-60214.log`.
Root read actual output and frozen line 713: edited native `admit_readback`
returns an atom-keyed OBSERVED receipt, not an ACCEPTED command receipt.
This fails before edited source launch; neither edited routing nor terminal
owner loss has run. Prior portions reaching this barrier are not whole-case
acceptance. Sole writer will correct the exact staging/readback association,
retain this freeze/log, and obtain a finite precheck before another long run.

Independent frozen triage identifies a fixture association defect:
`TicketChatFixture.native/2` selects oldest matching body digest, so repeated
supported wording embeds the previous proposal's staging receipt despite fresh
native turn/item/client IDs. Production correctly requires a current PENDING
proposal's exact receipt/time window. Keep those guards. Prefer an explicit
command-key selection in the existing fixture for the edited/owner-loss inputs,
preserving its default and exact replay behavior. Add a cheap repeated-body
regression proving second-command acceptance, duplicate replay and unchanged
first command before another complete lifecycle run.

Explicit repeated-body fixture correction is frozen at
`/private/tmp/symphony-u9-repeated-body-fix-review-60214/`:
helper `868b71d0a52ec503a76daa081dcfaf0da4ffe31d7c3a60916006843cbe669e21`;
command test `899d309c1cb0aff5b194b0ddf959eb5cd37e6754173f2ab916f90e49c70ad37d`;
canonical `95e90e89f3dd378d934692bb040ea580392626aa6f1b466991919202106502ac`.
The native helper's three-argument overload selects the exact command/chat/body;
its two-argument default remains unchanged. Both new canonical inputs name the
staged command explicitly and bind their accepted input key. Cheap repeated-body
regression passed 1 test, 0 failures, 52 excluded, 1.0 second, seed 60214;
`/private/tmp/symphony-u9-repeated-rework-fixture-60214-rerun.log`.
Root read the terminal log and frozen helper. Finite precheck is pending; no
new full canonical or U9 batch acceptance yet.

Finite helper precheck found canonical lacks `ctx.chat`, unlike the cheap
fixture. Caller-only correction passes both current parent and cwd at edited
and owner-loss native readback construction. Frozen canonical:
`/private/tmp/symphony-u9-repeated-body-callers-review-60214/`, SHA
`b65d277023f003a5e4f247616e0bfcaab0fe6d2b3944cae38bdee5e6890fdd44`.
Root checked actual lines/hash; finite reviewer returned PASS for this defect.
Helper and cheap regression are unchanged. One same-selector canonical rerun
is now authorized without trace, retaining the single-test 600-second limit.

Repeated-body canonical rerun is terminal: 1 test, 1 failure, 3 excluded,
331.5 seconds; seed 60214;
`/private/tmp/symphony-u9-ready-expanded-canonical-60214-rerun.log`.
Root read the terminal output: line 810 at owner-loss expects a typed hold,
but actual scheduler detail is `{:ticket_step_exception, FunctionClauseError}`.
The test reached the terminal owner-loss fault after its edited-cycle assertions;
that prefix is not full canonical acceptance. No relaunch or wider permission
fix is authorized. Existing Runner adoption decodes START_SENT missing output
to nil then calls map-only StageSchemas.validate before the intended not-ready
guard. Sole writer is adding a cheap real START_SENT adoption RED/GREEN and a
minimal existing-seam typed guard, preserving malformed completed-output checks.

Typed-hold regression produced actual RED (1/1, 1.7 seconds) at the nil/schema
clause and GREEN (1/0, 24 excluded, 1.6 seconds), seed 60214. Logs:
`/private/tmp/symphony-u9-start-sent-null-output-red-60214-rerun.log` and
`/private/tmp/symphony-u9-start-sent-null-output-green-60214.log`.
Root read both terminal results and frozen implementation. Nil unfinished
START_SENT/THREAD_BOUND/TURN_BOUND returns worker_not_ready_for_consumption;
maps retain schema/adoption checks, other nonmaps reject worker_output_invalid.
Frozen `/private/tmp/symphony-u9-start-sent-typed-hold-review-60214/`:
Runner `895a42e8e3397d5e9290d394207ec0febef6d5e6010344031f23f4f15f6eb880`;
test `4ed26f01bf5bdd8f8c69c43f23809ec7d153e4ab5d196b3f000ac33c3167615d`;
canonical unchanged `b65d277023f003a5e4f247616e0bfcaab0fe6d2b3944cae38bdee5e6890fdd44`.
Finite review PASS for the named guard. Same canonical retry is now live in
worker-owned session 89073, log
`/private/tmp/symphony-u9-ready-expanded-canonical-60214-final.log`.
Do not restart on observation expiry; runtime acceptance still pending.

Expanded canonical now PASSED: 1 test, 0 failures, 3 excluded, 324.6 seconds;
seed 60214; `/private/tmp/symphony-u9-ready-expanded-canonical-60214-final.log`.
Root read terminal output and frozen final assertions, confirming exact
START_SENT owner loss/reopen typed hold, unchanged durable rows, no registry
owner and no duplicate start. Same test includes edited READY fresh VERIFYING
with configured preflight, new candidate/PASS/push and retained MR, natural
old-v2 history preservation, and isolated generation drift.
Combined 23-file frozen review returned bounded source PASS; manifest
`/private/tmp/symphony-u9-final-acceptance-snapshot-60214/manifest.md`, digest
`a80f2f2ff9f6da22a1318cc9ab3d17c10bf27a1ca9247cc3843b3caec5a9fc19`.
Root authorized the specified three-file U9 boundary batch once, without trace,
seed 60214, with source frozen. Batch and native acceptance remain pending.

The three-file offline U9 boundary now PASSED: 88 tests, 0 failures,
486.4 seconds, seed 60214, no trace, no exclusions reported in terminal summary;
`/private/tmp/symphony-u9-three-file-boundary-60214.log`.
Root read terminal output and confirmed the process is no longer live. Source
stayed frozen. This accepts the local U9 implementation/integration checkpoint,
not native human-input behavior, rollout or the whole goal.

Remaining Slice 4 gate is the plan's real native busy-parent/human-input test.
Root requested its separate ceiling of 12 total Luna parent/worker/broker turns
and 30 minutes active runtime, with synthetic external services and no real
ticket writes. While approval is pending, sole writer is preparing non-paid
execution setup only, reusing existing native fixtures and parent/broker APIs.
No native chat, model turn or live external mutation is yet authorized here.

Post-boundary root audit recomputed all 23 manifest entries against both current
checkout and frozen snapshot: 23/23 pairs match, zero drift, shasum exit 0.
The 88-test result and combined source review therefore still describe the exact
current accepted local candidate while native preparation is non-paid/read-only.

Non-paid native preparation is complete. Reusable real-worker driver is
`/private/tmp/symphony-u7-native-capability.CXdv7U/lifecycle_test.exs`; its parent
and Jira are synthetic, so it is not human-input acceptance. Existing APIs own
CREATE (`Scheduler.ticket_parent_step`, `DesktopToolArgs.create_thread`), exact
acknowledgement (`DesktopRequest.record_ticket_thread/complete`), parent guard
and native queue reads (`TicketChat.claim_followup`, `TicketParentGuard.receipt`),
and real human-input collection (`TicketChatCommands.collect`). No new product
queue/module or architecture is indicated. Source-active ownership is observable
through SOURCE workspace access plus TaskLauncher.active_owner.

The missing acceptance input is a real projectless Desktop parent and actual
owner/input evidence, followed by the required human messages. No model-free
fixture can substitute for them. No code changes or native calls were made in
preparation. The separate bounded budget approval remains unanswered after three
consecutive goal turns; no remaining safe preparation can satisfy this gate.
The goal is awaiting that approval/human test, not code repair or a new plan.

User subsequently authorized the bounded native test and resumed work: ceiling
12 total GPT-6 Luna parent/worker/broker turns, 30 minutes active runtime,
synthetic fixtures only. Root services actual Desktop handoffs/readback; worker
prepares only the exact synthetic request/fixture until explicitly dispatched.
No real-ticket, production, push or deployment authorization is added.

Automatic-goal state remains blocked in the app: get_goal confirms it, and the
single explicitly requested create_goal restart attempt was rejected because
the existing goal is unfinished. No objective was replaced or marked complete.
The status tool cannot resume goals. Computer Use also denies Codex-app access,
so root did not bypass that restriction. Authorized work proceeds in this turn;
user's app Resume control is required for automatic continuation.
