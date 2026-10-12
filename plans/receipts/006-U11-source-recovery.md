# U11 source recovery

User authorized relocation and restoration of missing files on 2026-10-09.

- Previous checkout: `/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`.
- Registered permanent checkout: `/Users/cgable/Repos/symphony-ticket-chat-implementation`.
- Branch: `cgable/desktop-owned-ticket-chat-v1`.
- HEAD unchanged: `52a978818875c59ccf2758ed1b728bb23e33f631`.
- Supported `git worktree move` preserved the checkout and existing edits.
- Restored exactly 35 absent files from
  `/private/tmp/symphony-u11-gate-after-static.vWDjFv/source.tar`.
- Independently rehashed all 456 files in the pre-run source manifest: all match.
- No existing source files were overwritten; no production or tracker changes.

The prior full gate remains failed: 1,507 tests, one failure, six skipped,
97.32% coverage against the unchanged 99% requirement. Separate Dialyzer passed.

The database-reopen test directly stopped its supervised Store, allowing the
permanent supervisor to restart it while the test opened a second initializer.
The test now stops and reopens through ExUnit supervision, preserving all replay
assertions and production behavior. The first generic patch matched different
reopen cases for its start and stop substitutions; a passing focused test did
not prove the intended pair was corrected. Actual-source review exposed this,
and explicit contextual patches completed all three supervised reopen cases.
Independent current-byte review passed all three and the new genuine-input
pre-application replay/transfer rejection test. The corrected commands-file
boundary passed with seed 131537: 72 tests, zero failures in 5.9 seconds.
An additional malformed-input case removes clientId entirely, rather than
setting it to nil, to exercise the missing-key rejection boundary.
`git diff --check` passed; no tracked deletions remain.

Conditional commit authorization is recorded, but this receipt does not claim
the whole dirty implementation is ready to commit or that Slice 5 is accepted.

## First post-recovery bounded coverage batch

- Commands-file boundary: 72 tests, zero failures, seed 131537, 5.9 seconds.
- Genuine accepted commands cannot replay before application; answer-only input
  cannot authorize a writer transfer. Protected database state remains unchanged.
- Malformed native input with an absent clientId key rejects without mutations.
- Two selected amendment checks passed in 3.1 seconds: default critic source-cwd
  overlap rejection before dispatch, and correction rejection without a critic.
- The amendment-file boundary passed: 48 tests, zero failures, seed 131537,
  35.4 seconds. Independent frozen review is pending.
- The source-cwd fixture initially lacked its directory and correctly returned
  cwd-invalid; creating the synthetic directory exercises the intended overlap.
- Frozen review copies: `/Users/cgable/Repos/symphony-u11-review.ktOG3N`.
- Commands SHA256: `cd78271aff18db2a1d3e9ced9c6469e06fcfaae43894bd69a8af849ddd1da625`.
- Amendment test SHA256: `69f57b7b4b8acd485db5df459bf8893d80207bdeb8d48948be7ece6c88b4beea`.

These focused passes do not establish full-suite coverage or Slice 5 acceptance.
The previous full-gate coverage remains 97.32%; no threshold changes were made.

## Reviewed bounded recovery batches

The additional four amendment tests passed their selected run (4/0, 3.5 seconds)
and final file boundary (52/0, 30.6 seconds). Independent frozen review passed.
Final amendment-test SHA256:
`1c4e2dfc9b6b25038d4ccb9877acd78bb34816c345c13c66abdaf68f499aa773`.
The final export is `elixir/cover/u11-amendment-recovery-final.coverdata`;
the earlier `u11-amendment-recovery` export represents an intermediate draft
and must not be counted as final coverage. One noncoverage attempt was stopped
before completion to switch to the export run; it was not a completed failure.

Measured intersections with the last full-gate missed-line set:

- TicketChatCommands: 501, 655, 818, 1359 (four).
- TicketAmendmentCritic: 10, 53, 111 (three).
- TicketContractAmendment: 75, 1131, 1136, 2305, 2388, 2399, 2411, 2416, 2420 (nine).
- TicketJiraJournal: 56, 272, 292, 304 (four).

Twenty additional distinct baseline misses were exercised. These are focused
measurements, not proof that the whole final suite meets 99%. Runtime/gate-input
integrity check covered 141 manifest files and found zero changes.

Journal ownership/idempotence selected cases passed independently: versioned
ownership test 1/0 in 30.5 seconds; legacy preparation replay test 1/0 in 81.7
seconds, seed 131537. An initially requested second location was outside its
test; the output correctly showed one selected test, and the legacy case was
then run at its actual location. Formatter and diff checks passed. Independent
frozen review passed the exact source delta.

Frozen journal test:
`/Users/cgable/Repos/symphony-u11-review.ktOG3N/journal_ownership_test.exs`, SHA256
`44e4bdcfbdb52013f78740b48912fc374719b26eeb94b5e0679deff15aa25c5e`.

The exact pre-run backup, source manifest, full-gate log/result and work order
were copied into `/Users/cgable/Repos/symphony-u11-review.ktOG3N/recovery-evidence`.
Both backup copies have SHA256
`595c0be1b7af7610b3cb37c2a740f6e4c6800ff41f2b99c5938c75d9e0e0bf77`.
Historical paths remain unchanged in their original receipts.

Next: same-candidate legacy review rollover, authentic READY replay/live-row
drift, and the independently prepared amendment/command boundary batches.
No commit, push, deployment, model turn or real-ticket mutation occurred.

## Subsequent reviewed batches

Same-candidate rollover passed 1/0 in 87.3 seconds and its frozen review passed;
Journal baseline hits 126,177,178,179,181,182,184 were independently measured.
The READY replay drift lifecycle passed 1/0 in 329.4 seconds, frozen review PASS;
Commands baseline hits 536,547,627 were independently measured. Both processes
are terminal. Durable results are in the evidence folder's
`rollover-and-replay-results.md`.

The next amendment file passed 53/0 in 32.3 seconds, frozen review PASS, adding
1142,1147,1181,1483,1486. Reserved-owner commands passed 73/0 in 8.2 seconds,
frozen review PASS, adding 167,217,234,259,897. See
`amendment-and-owner-results.md` in the evidence folder for hashes and trial errors.

The Jira-operation file passed selected new cases 8/0 in 1.8 seconds and its
boundary 21/0 in 6.3 seconds. Final source/frozen SHA256:
`29601a60e99bed2067973949a0533a7e0d5da60b51579a346e31f34dbd9912e9`.
Independent frozen review passed. Root independently imported its export and
confirmed ten baseline hits: 21,43,60,503,505,791,793,810,836,840.
Raise/exit initially reused the same command and therefore replayed UNCERTAIN;
fresh ExUnit setup for each case now proves each actual attempted write and
read-only retry. No effect was reset or successful receipt manufactured.
Optional authorization-missing-effect coverage was intentionally not claimed.

Recovery total: 50 distinct previously missed lines exercised in focused exports.
The last full-gate aggregate remains 97.32%; final 99% acceptance is unproven.
The next prepared work is blocked-resume replay and WorkspaceAccess boundaries.
No commit, push, deployment or real-ticket mutation occurred in these batches.

## Blocked-resume replay and historical amendment reads

Blocked-resume final frozen/live source SHA256:
`e53bc7789730dc6cd06d28c044f303f17d59044b8fd43a29118e7c4611129c5e`.
Final trace verified exact test titles at lines 1484 and 1790; 2/0 in 26.3
seconds, 71 excluded, seed 131537. The initial duplicate-helper warning was
removed. Earlier line selectors missed the extended replay test; those exports
are not acceptance evidence. Only
`u11-blocked-replay-recovery-events-final.coverdata` is the accepted export.
Independent frozen review passed; root imported it and confirmed new baseline
hits 654,703,728,744,870. Line 663 is not claimed.

Historical amendment final source SHA256:
`0871d82282e8be7a5dd2ff3c4c7ec0883a7ce3413914667789e715287f9f376d`.
Selected trace confirmed the superseded-BLOCK and READY authorization cases,
2/0 in 7.6 seconds. File boundary passed 53/0 in 34.7 seconds. Frozen review
passed. The three historical fault probes use an actual transaction rollback:
no rows are reconstructed and no successful hashes are recomputed. Admission
receipt restoration also returns to exact captured state. Root independently
confirmed new baseline hits 1570,1593,1731,1774 from its coverage export.

Focused recovery total is now 59 distinct last-full-gate misses. The full-gate
percentage and 99% acceptance remain unproven. Current durable snapshots/results
are under `/Users/cgable/Repos/symphony-u11-review.ktOG3N`. No full suite, production
code change, commit, push, deployment or real-ticket action occurred.

## Held-amendment workspace ownership

Final source/frozen SHA256:
`4437b347b42f816c94fbeb40a447f8075c53a389ebe5220864319f43fa2c9b81`.
Exact traced existing held-amendment/reopen test at line 487 passed 1/0 in
83.5 seconds; 72 cases excluded. Formatting/diff and frozen review passed.
Root independently imported `u11-workspace-ownership-recovery-prooffix.coverdata`
and confirmed new baseline WorkspaceAccess hits 159,193,194,316.

Earlier two runs failed on fixture assumptions: missing checkout_head_sha on a
non-nil-candidate predecessor, then nil input_key from stale PENDING stage output.
The final test uses actual Git HEAD and the freshly admitted command row.
Failed exports are not acceptance evidence. Synthetic branch drift restores in
after without force; ledger, source, index and HEAD controls are preserved.
Old held ownership is rejected after genuine transfer and after reopening.

Line 203 was not claimed: the authentic nil-candidate receipt lives in the
separate first-writer amendment fixture. Line 445's earlier success-path gain
prediction was withdrawn after measured successful transfer left it red; its
input-key equality is already proved by preceding command validation/atomic
lookup. Do not force the earlier guard or change coverage policy to reach it.

Focused recovery total is now 63 distinct baseline misses. Native acceptance,
aggregate final gate, commits and rollout remain unclaimed.

## Nil-candidate checkout HEAD drift

The existing first-writer amendment case at line 947 passed its exact selected
trace: 1 test, zero failures, three excluded, 62.2 seconds. Frozen/live SHA256:
`08d416c09b90a90ca9029d43c98077e8a13f64d59b06b29725c2219adfdb9f83`.
Independent frozen standards/behavior review passed. Root independently imported
`u11-workspace-ownership-checkout-head.coverdata`: WorkspaceAccess lines 201/202/203
have calls 5/4/1; line 203 is one new baseline miss exercised.

The test uses its authentic nil-candidate held receipt and existing HEAD tree,
not the staged tree. It CAS-advances the same expected branch to a synthetic
same-tree child, asserts exact checkout-head rejection and preserved protected
ledger rows/index/staged/source/untracked bytes, then CAS-restores in `after`.
Positive validation and the original explicit-resume continuation remain.
There is no branch switch, force/reset, receipt rewriting or scheduler tick
during drift. Durable frozen source is `workspace_checkout_head_test.exs` in
the evidence folder. No full suite, runtime edit or external action occurred.

The accepted focused-export union was independently rechecked before this
case and confirmed 63 baseline hits; this case raises the distinct total to 64.
This is not full-suite aggregate acceptance. The next packets are remaining
public worker/checkout and finalization boundaries, prepared in parallel.

## Checkout ownership failures and historical push rejection

Two selected cases at lines 142/182 passed their final trace: 2 tests, zero
failures, 17 excluded, 1.9 seconds. Terminal exec session: 44498. Frozen/live
SHA256: `b26dd07ae7d308a3c9f41b1e76366ee1b1324a50fb72bbd321372d6b962cc431`.
Frozen independent behavior/standards review passed. Root independently imported
`u11-ticket-checkout-ownership-recovery-final.coverdata` and confirmed one call
each on Checkout 36/48 and Push 92/93. These are four new baseline hits.

Public checkout creation rejects a helper inside the proposed workspace root
without writing to compiled priv or creating its proposed checkout. A scoped
ignored helper-PID update rolls back startup acknowledgment; reconciliation
returns execution-unproven, retaining the same uncertain-operation fence even
after the trigger is removed. Protected ledger rows, run and source/index bytes
remain unchanged. Historical push validation rejects genuine nil history and
a call-local malformed handoff without mutating or inventing successful history.

The first selected run failed only on a redundant empty-events assertion:
the fixture already has setup events. Final exact pre/post snapshot equality
preserves the no-new-events requirement. The earlier export is not acceptance.
Durable frozen source is `checkout_ownership_test.exs` in the evidence folder.
Focused recovery total: 68 distinct baseline misses. No full gate or external
action occurred; aggregate acceptance and native/rollout gates remain open.

## Command grammar and historical interpretation

Exact selected trace at lines 45/88/788/1552 passed 4 tests, zero failures,
71 excluded, 1.5 seconds. Terminal exec session: 49952. Persistent log:
`recovery-evidence/u11-chat-commands-bounded-final.log` in the durable evidence
folder. Frozen/live SHA256:
`73afdd0e48fa4a84a6670663af881d3f9f53fa60637a1cd761a5816a2c8ae927`.
Frozen behavior/standards review passed against the most recent accepted
reserved-owner snapshot, not the older incomplete preparation copy.

Root independently imported `u11-chat-commands-bounded-final.coverdata`:
Commands 1459/1523/1837 and WorkerRunner 190/219 each have one call. Unsupported
three-line staging wrappers and inner Python byte escapes are parsed only,
never executed. Three real open questions with a staged three-answer revision
cannot authorize a native body containing four answers: the complete proposal
is rejected, preserving questions/run/amendment/source ownership. A genuine
applied answer-only command has no retained review history; only its persisted
payload is then corrupted, rejection preserves exact post-fault state, and
`after` restoration returns to the intact positive control. No hashes or
successful receipts are manufactured.

Focused distinct baseline recovery total: 73. Whole-suite coverage remains
unproven; no full gate, commit, push, deployment or external mutation occurred.

## Capacity admission stopped before the next packet

After the reviewed command packet released source ownership, the next fresh
shared-volume check returned `INSUFFICIENT_WRITER_CAPACITY`: 18,921,197,568 free
bytes (18.92 GB decimal), zero admissible writer slots under the unchanged
20 GB budget. This is shared-volume/global-ledger evidence, not a Symphony
factory route or lease; no route was invented. `factoryctl.py list-runs` returns
an empty list, so the automatic ownership policy offers no qualifying cleanup
target. No files, caches, snapshots or worktrees were removed.

The next source packet is prepared, not executed: existing worker-lifecycle
fixtures group finalization ownership/persistence faults (130/214), legacy
journal identity/ownership (133/172/263), reused reservation mismatch (Runner
113), malformed remote MR/read outage (288/232), and genuine blocked-history
and caller identity rejection (Runner184/Evidence101). Preserve the existing
authentic workflow continuations and transactional fault restoration; use only
selected named cases and frozen review, not a full lifecycle-file sweep.

Read-only clause audit corrected misleading coverage predictions: Commands
838 is an unreachable helper-return fallback, 947 is gated by an earlier equal
input binding, and 1714 is fenced by the persisted body type. The proposed
non-OPEN-question path for 1139 must also survive the earlier OPEN-only parser
before it can be considered a valid test. No duplicate tests or exclusions were
added for those claims. Further source admission requires capacity recovery.

## Grouped worker/finalization recovery under the authorized storage exception

The user authorized a Slice 5-only storage exception on October 9. The configured
20 GB policy was not changed, no real-ticket claims were admitted, and no cleanup
was performed. User cleanup subsequently restored normal admission; the latest
check passes at 35.95 GB decimal with one shared writer slot available.

Final frozen/live SHA256:
`3ea4579e3e55ee544f18001229713ddbd59880136f4bf992aaa5e5ee514b4e4c`.
Independent frozen behavior/standards review passed against the previous held
workspace-ownership snapshot. Durable source: `worker_finalization_recovery_test.exs`.

Selected evidence, retained in the durable recovery-evidence folder:

- Initial five-title command: 5 tests, 4 failures, 349.7 seconds. Only the mixed
  blocked-rework case at line 1291 passed (17.97 seconds). Its unchanged body
  supplies the Runner184 rejection evidence; this is not acceptance of the failed
  command or coverage from its other four cases.
- Four-failure retry: 4 tests, 1 failure, 366.4 seconds. Three passed, while the
  finalization fixture still reused expired authority before project-pin checks.
- First finalization-only retry: 1 failure, 103.5 seconds. The new phase-limit
  probe ran before original zero-journal assertions, exposing a work-order
  ordering error. The probe was relocated; no assertion was weakened and no
  pending intent or history row was deleted.
- Finalization exact-state run: 1 test, zero failures, 72 excluded, 430.5 seconds;
  test duration 419.9 seconds under the unchanged 450-second limit. A later edit
  only removed an unused pure `Process.get` binding; frozen review confirmed
  source equivalence. Log: `symphony-u11-finalization-exact-state.log`.
- Exact-final shared-helper validation: selectors 3022/3027/4481, 3 tests, zero
  failures, 70 excluded, 290.8 seconds. Log:
  `symphony-u11-mr-lifecycle-sharedhelper-final.log`. No broader rerun occurred.

Fresh authorization is generated by the existing Jira-reading public helper at
the actual action boundary. Intentional expired-authority negatives remain;
runtime expiry and guard policy are unchanged. One original native-turn mismatch
is not attributed to a proven cause: the later legacy runs passed, but the failed
run did not capture guard-age evidence. Do not claim its root cause is fixed.

The phase-limit probe reuses the actual FIRST_PENDING intent and maintenance
owner, denies only phase persistence, preserves exact journal/access/run/source
state, and restores its trigger and fixture observations. It precedes the normal
FIRST_UNCERTAIN continuation only after all original zero-effect negatives.
Ownership drift is explicitly injected inside the scoped Jira callback after
qualification, not described as an authorized release; exact restoration and
no additional side effects are asserted. Legacy identity/binding faults use
transactional rollback. Remote-MR shape and CI-read failures preserve ledger state.

Root imported the raw exports and measured nine additional baseline lines:
Finalization130/214, Journal133/172/263, Runner113/184, MR232/288. Evidence101 remains
zero: the call-local task-key mismatch exercises a later conjunct, so the earlier
predicted gain was withdrawn. The caller-identity rejection test is retained.
Focused distinct recovery total: 82. Full-suite 99% acceptance is still unproven.
No full gate, native/model turn, commit, push, deployment or real-ticket action
occurred. The next prepared packet is amendment Jira claim/readback persistence
denial and missing authorization effect/timestamp recovery through public APIs.

## Amendment Jira persistence and malformed readback recovery

Final consolidated six-selector trace at lines 1591/1640/1693/1749/1808/1843
passed: 6 tests, zero failures, 53 excluded, 12.7 seconds. Terminal session77148.
Final frozen/live SHA256:
`fc4eda9a78fd2e3451f4c4b6f380e5b1742343bd10aa7333439533b8d376a100`.
Independent frozen behavior/standards review passed. Durable source is
`critic_jira_persistence_recovery_test.exs`; log is
`recovery-evidence/symphony-u11-critic-six-jira-faults-final.log`.
Root imported its export and confirmed one call each on JiraOperation
80/276/324/381/652/678: six additional distinct baseline misses.

Genuine public amendment/critic/publication APIs establish pending effects.
The second-amendment setup explicitly advances unsealed fixture run state after
actual first application; it does not prove an intervening verifier execution
or a complete production delivery cycle. No successful receipt is constructed
or resealed. Scoped phase-update denial triggers are removed in `after`.
Claim failures preserve PENDING and cause no new connector write. Readback
persistence failures retain the one actual comment, then retry reads/adopts
without another write. Missing authorization-effect readback creates nothing.
The authorization-only timestamp fault appends the exact expected comment,
sets only `updated` to nil, records uncertainty without accepting readback, and
recovers after only that timestamp is restored. Protected state comparisons
retain all columns and intentional observation bookkeeping.

The two existing baseline cases passed 2/0 in 4.6 seconds. Initial six-case run
had four assertion failures (raw tuples compared to a row map). The four-case
retry had two failures (human proposal body compared to generated Jira comment).
Only those assertion representations were corrected; subsequent draft cases
passed, then the complete final six-case matrix passed against the exact final
SHA. Earlier failed prefixes are not acceptance evidence.

Focused distinct recovery total: 88. No runtime edit, full file/suite gate,
native/model turn, commit, push, deployment or real-ticket action occurred.
Full-suite 99% and native integrated acceptance remain unproven. The prepared
next public-boundary work includes stopped-writer transfer/replay ownership and
the small worker-admission/blocked-adoption cases; do not force unreachable
private guards or change coverage exclusions.

## Worker admission and stopped blocked-result adoption

Exact selected trace at lines 162/188 passed 2 tests, zero failures, 32 excluded,
7.8 seconds. Frozen/live SHA256:
`715659d7b8232ab34c99cfe90f0d40b4623149cada364e25b34a1a65a7dc6a97`.
Independent frozen review passed. Durable source: `runner_admission_blocked_test.exs`;
log: `recovery-evidence/symphony-u11-worker-runner-boundaries-final.log`.
Root imported the final export and measured one call each at Runner271/572.

Malformed supplied reservation is tested through public admission facts, not
the wrapper that strips that option. Genuine prepared parent/base/access state,
full protected rows, HEAD and source/index remain unchanged; no worker starts.
The BLOCKED output follows actual fixture session, turn and stop callbacks with
the native writer schema. Adoption returns the exact blocked error, permits the
legitimate task COMPLETE transition, retains RESULT_RECORDED evidence and held
access, and leaves run/candidate/HEAD/source unchanged without a commit or
controller-check evidence.

Initial attempts failed before execution on an unbound pin, then on comparing
a result tuple to the actual run map. Only test snapshot binding was corrected;
final consolidated evidence is green. No runtime/policy change, full suite,
native/model turn, external mutation or commit occurred. Focused distinct
baseline recovery total: 90; aggregate 99% remains unproven.

## Stopped-source transfer and replay fault matrix

The exact final four selectors at 487/1319/1831/2005 passed: four tests, zero
failures, 69 excluded, 118.7 seconds. Terminal session 55874; final frozen/live
SHA256 `884687a88a9e2d8d5746435bb52d92314500d99f57dce5e36ea9c714a836ef8b`.
Frozen adversarial preflight passed. Durable source:
`stopped_source_fault_recovery_test.exs`; log/export:
`recovery-evidence/u11-lifecycle-fault-probes-final.{log,coverdata}`.

Root independently measured WorkspaceAccess323/337/411/461 (1/3/1/1 calls),
Amendment1967, Commands663 and WorkerEvidence101 (one call each). These seven
additional distinct baseline misses bring focused recovery to 97; aggregate
99% acceptance is still unproven. The previously accepted export union was
rechecked at 90, and its four missing durable copies were preserved alongside
the other accepted exports. No earlier failed export is included.

The ordinary non-amended fixture uses a genuine blocked disposition, accepted
input and public resume packet to derive its transfer binding. Successful
positive controls roll back the complete transfer. Negative calls use the
public API's own transaction: invalid input and missing disposition preserve
canonical state, malformed event JSON preserves post-fault state and is restored
exactly in `after`, and a same-HEAD branch mismatch restores the original branch
without force. Source/index/HEAD and complete protected rows remain intact.
Other genuine fixtures reject an array predecessor-release receipt, a changed
supersession request and a non-null singleton answer proof; explicit rollback
preserves the genuine receipts and their positive controls.

Preflight first corrected a linked-worktree `.git/index` path to use its actual
Git directory. Initial four-selector execution passed three cases but failed
the ordinary case when an inner API rollback invalidated its caller-owned
transaction before snapshotting. Only that test harness was corrected; the
final consolidated run proves all four on exact final source. A used underscore
binding was renamed before that run. The intermediate preflight path was
overwritten, so it is not claimed as retained byte-for-byte evidence; final
distinct frozen artifacts are preserved. No runtime/gate policy edit, full
suite, model/native turn, external mutation, commit, push or deployment occurred.

## Proposal-only delimiter boundary

Selected Commands test at line 788 passed: one test, zero failures, 75 excluded,
1.6 seconds; terminal session 84211. Frozen/live SHA256:
`b748ad32fb279f21d48aa548ba644e201aca20157667d2efc647ed1fac15045f`.
Durable source: `proposal_only_grammar_test.exs`; log/export:
`recovery-evidence/u11-proposal-only-command.{log,coverdata}`.
Root independently measured Commands1818 once; focused distinct recovery is 98.
Runtime/gate integrity separately matched all 142 selected manifest files.

The public admission consumes genuine staged proposal/native readback. A body
beginning at the exact delimiter has no preceding answer section and no current
question; its stored rejection is `no_current_question` with worker-start false.
Run, questions, tasks, evidence, access, amendments and other commands remain
unchanged; the expected rejection/input/event observations are retained.
Frozen review caught a nonexistent top-level receipt flag before execution;
the corrected assertion reads the exact returned and persisted `receipt_json`.
The final delta was independently checked before the single passing run. No
full file/suite, runtime or gate edit, model turn or external action occurred.

## Applied amendment preimage corruption

The existing genuine READY/APPLIED case at line 2211 passes: one test, zero
failures, 3.6 seconds; terminal session 67037. Frozen/live SHA256:
`ee2b29786f0391ce443af592dbc0c5095dfb78f028ee6939735a38fc763dc0e9`.
Durable source: `amendment_preimage_fault_test.exs`; log/export:
`recovery-evidence/u11-amendment-preimage-probes.{log,coverdata}`.
Frozen independent behavior preflight passed; root verified the final one-line
snapshot strengthening before execution. Root independently measured TCA1509
and TCA1806 once each. Distinct focused recovery is 100, not aggregate 99% proof.

Two separate outer transactions mutate only existing unsealed amendment fields.
Appending a newline preserves decoded prior-binding semantics but fails the
authentic application receipt's byte-exact preimage. The actual non-STRICT
SQLite schema admits text in prior_revision without a schema change; revision
arithmetic fails closed. Public get rejects both with invalid_contract_amendment
and leaves complete post-fault rows unchanged. Explicit rollback restores the
exact canonical row and positive APPLIED read after each probe. The snapshot
includes the entire Desktop request queue, not only its parent rows. Receipts,
hashes, critic history and authorization evidence are never resealed.

A worker-side mix run measurement attempt failed at application startup due
to missing LINEAR_API_TOKEN; no credentials/configuration were changed. Root
used a plain Elixir VM and cover.import instead, without starting Symphony.
No additional test, runtime/gate edit, full suite, native/model turn, external
mutation, commit, push or deployment occurred.

## Jira implementation-handoff bounded persistence recovery

Selected JiraOperation case at line 214 passes: one test, zero failures,
12 excluded, 4.9 seconds; terminal session 92008. Frozen/live SHA256:
`2a4c6424ab8e67b277170af0ad7b071d2f14760a3cf924979755d0a2b4f0216b`.
Durable source: `jira_effect_limit_recovery_test.exs`; log/export:
`recovery-evidence/u11-jira-effect-limit-recovery.{log,coverdata}`.
Independent frozen preflight passed after correcting a nonexistent input-table
run_id column; root verified that exact one-line fix before execution.
Root independently imported the final export and measured two calls at
TicketJiraOperation232.
Focused distinct recovery is 101; whole-suite 99% remains unproven.

The fixture already observes In Dev and ai-running. An exact run/operation/
phase-scoped RAISE(IGNORE) trigger denies FIRST_PENDING to SECOND_PENDING only.
The public handoff stops at ticket_jira_effect_limit, performs no connector
mutation, and preserves run/tasks/evidence/source/index while retaining a real
pending journal with nil receipts and maintenance ownership. A second attempt
matches the complete retained-state snapshot. Trigger cleanup in after restores
normal persistence; the positive retry completes the journal, releases access
and admits WRITING without creating source work or repeating a Jira mutation.
No runtime/gate edit, full suite, native/model turn or real external action.

## Mixed READY rework and typed MR authority boundaries

The existing ordinary Desktop lifecycle at line 105 passes: one test, zero
failures, three excluded, 298.9 seconds; terminal session 10934. Frozen/live
SHA256 `0a0aeb9110ca6d9a5f5ccbcc4c67359847897f88925838f3376da73bc9ff9d84`.
Durable source: `mixed_ready_rework_test.exs`; log/export:
`recovery-evidence/u11-mixed-ready-rework-final.{log,coverdata}`.
Independent frozen behavior review passed. Root verified the final test-only
capacity adapter against the reviewed design. Commands404 measured twice.

One real OPEN question is staged/admitted with answer-plus-rework input. Full
question rows join the existing capacity/event rollback and replay snapshots.
The question remains OPEN/unanswered through both deferred attempts, then the
genuine APPLIED transfer receipt contains its exact key, 64-hex answer proof and
accepted input. Public replay succeeds while worker evidence is still RESERVED;
all prior restart, START_SENT, single-start, drift and no-replay assertions remain.

The first selected attempt exited 2 after 7.6 seconds at preexisting initial
intake capacity, before the extension; that failed export is not accepted.
The supported per-tick cleanup dependency now selects a test-local adapter for
this driver only. It delegates real Cleanup.ensure_capacity with default
synthetic free_bytes=50 GB and delegates other callbacks unchanged. The actual
20 GB policy, global/runtime configuration, existing explicit 19,999,999,999-byte
READY rejection and 600-second timeout are unchanged. This is hermetic fixture
capacity, not proof of actual host capacity or an exception for real delivery.
An initial work order named the wrong lifecycle file; the writer made no edits
there and root verified the module/file before changing ownership.

The existing typed MR claim case at line 4051 passes: one test, zero failures,
72 excluded, 50.2 seconds; terminal session 40896. Frozen/live SHA256
`d0d4df92db00746e915acead4235c6b12fb748cf83998277e1f315c8a50d9b57`.
Durable source: `typed_mr_authority_fault_test.exs`; log/export:
`recovery-evidence/u11-typed-mr-negative-probes.{log,coverdata}`.
Frozen independent preflight passed; root measured MR377/676/850 once each.
The real map guard preserves broker identity but omits owner/native proof;
route-path drift is call-local; exact control removal is transactionally rolled
back. Full queue/claim/control/ledger/source/index/HEAD comparisons and canonical
positive binding remain. Unsupported bare Jira-reader results were excluded,
not manufactured to reach another fallback. The genuine prepared authorization
remained valid; no timestamp or stored authority was rewritten.

Root reimported the complete accepted export set and confirmed 105 distinct
baseline hits. Neither these focused exports nor successful fixture reads prove
whole-suite 99% or integrated native acceptance. No full suite, production
runtime/gate change, native/model turn, real external mutation, commit or push.

## Amendment corruption across genuine supersession and held-source history

Two selected existing cases at critic428 and worker487 passed together:
two tests, zero failures, 130 excluded, 92.5 seconds; terminal session6550.
The held-source driver took 73.99 seconds. Frozen/live critic SHA256:
`941a6e63ec74a5133a46a51a9c05454fdddb2bca063eb90cc04d0876515156be`;
worker SHA256:
`a07b9e8a6173db43eeeebcafd05322e74d68c7fe7a74f3c6f3426eb95b14d045`.
Independent frozen preflight passed. Durable sources:
`amendment_corruption_chain_test.exs`, `held_amendment_corruption_test.exs`;
log/export: `recovery-evidence/u11-tca-final.{log,coverdata}`.
Root independently measured TCA201/1543/1559/1924/1992/2073/2371 once each.
Focused distinct recovery is 112; whole-suite 99% and native acceptance remain
unproven.

Each probe alters only one existing unsealed field and asserts exact public
rejection, complete post-fault state preservation and canonical restoration.
The RESERVED input's body drifts without changing its digest. Genuine incoming
supersession pointers receive unsupported object keys in RESERVED/SUPERSEDED
states. Held-source event references receive an object event ID, ancestry loses
its APPLIED parent, a genuine child's revision metadata becomes an array, and
the actual leaf r4 transfer receipt loses its amendment key. Public ancestry
failure is invalid_contract_amendment, not the inner ancestry error.
All original continuation assertions remain. Path existence/type protects the
authentically absent source path; real source/index/HEAD/branch observations
protect held-source faults. The three unsupported-bind paths actually preserved
queryable state, exact restoration and positive controls; no assertion was skipped
or weakened. Successful receipt hashes, event payloads and authority were not
rewritten.

An ownership checkpoint initially misattributed the writer's A2371 edit as
preexisting. Root verified session metadata and successful exec
call_HhSpsM8dqlwul70t3kAC8IK4 at 2026-10-09T19:56:23Z; it was the same assigned
writer's authorized patch. Edits were paused until this evidence resolved the
boundary; no external edit was overwritten or silently accepted. Final frozen
files are distinct and their source hashes match the executed command.
No runtime/gate edit, full suite, native/model turn, real external operation,
commit, push, deployment or cleanup occurred.

## Nil-candidate retained-head mismatch

The existing first-writer-amendment Desktop case at line 995 passes:
one test, zero failures, three excluded, 48.1 seconds; terminal session12175.
Frozen/live SHA256:
`ff224564c0aac082532cb5fef72ec9e612dae58f3d2123b682d0f02f75bdd146`.
Durable source: `nil_candidate_retained_head_test.exs`; log/export:
`recovery-evidence/u11-first-writer-head-mismatch.{log,coverdata}`.
Independent behavior preflight passed; root reviewed the exact frozen delta
before execution and independently measured TCA2144. Focused distinct recovery
is 113; full-suite 99% acceptance remains unproven.

The genuine nil-candidate held receipt captures an observed checkout HEAD.
Only unsealed amendment.predecessor_json.checkout_head_sha changes to the real
older stopped-access expected_sha, already proven different. Public get rejects
without modifying complete ledger rows or HEAD/ref/status/index/staged/tracked/
untracked bytes. Exact original JSON and canonical APPLIED/held/WorkspaceAccess
controls are restored in after. Original physical HEAD drift and read-only
continuation remain intact. This registered fixture keeps its existing injected
ticket capacity; the ordinary-driver Cleanup adapter was not broadened.
No runtime/gate edit, full suite, native/model turn, real external mutation,
commit, push, deployment or cleanup occurred.

## Historical missing admission receipt

The existing stopped-BLOCK supersession case at line 428 passes: one test,
zero failures, 58 excluded, 8.0 seconds. Exact frozen/live SHA256:
`d6ecfa487a66e75b046b98d5706613407b65310bc57ea32651be7b7a1f544548`.
Durable source: `historical_admission_null_test.exs`; log and export:
`recovery-evidence/u11-historical-admission-null.{log,coverdata}`.
Root independently measured TCA1608 with one call; accepted focused baseline
recovery is now 114 lines. This is not aggregate 99% acceptance.

Only the actual SUPERSEDED predecessor command admission receipt is temporarily
NULL. Its unchanged input digest, supersession and outgoing rejection evidence
reach the historical identity check, which fails closed. Independent frozen
preflight required full successor/command/input/source preservation in addition
to the existing historical snapshot; those checks were added before execution.
All loop vectors now compare full ledger and checkout state during rejection
and after explicit rollback, retaining canonical predecessor/successor controls.
Checkout paths are captured before the transaction; ledger snapshots separately
protect their exact bindings. No history or hashes are resealed.
No runtime/gate edit, full suite, native/model turn, real external mutation,
commit, push, deployment or cleanup occurred.

## Schema-unavailability recovery

Two existing drivers pass together: stopped non-PASS supersession at line 428
and READY_FOR_REVIEW authorization at line 2421. Result: two tests, zero failures,
57 excluded, 8.7 seconds. Exact frozen/live SHA256:
`bdcd580a18b3c74cca642cbffa29f42e5c00ce26ebeaf6936acaf18f691c9075`.
Durable source: `schema_unavailability_recovery_test.exs`; log/export:
`recovery-evidence/u11-schema-unavailability-recovery.{log,coverdata}`.
Root independently measured TCA78 and TCA2219, one call each; accepted focused
baseline recovery is now 116. Aggregate 99% acceptance remains unproven.

After genuine canonical positive controls, each case starts one explicitly owned
unsupervised connection to the existing fixture database. A real transaction
temporarily renames only the respective amendment/authority table; the public
read rejects with the exact documented error. All actual table rows, catalog,
and checkout state are compared during rejection before rollback. Health queries
succeed, explicit rollback restores original schema/data, only the dedicated
connection is stopped, and a fresh read-only connection verifies exact canonical
state and positive public outputs. No FK bypass, replacement schema, successful
receipt resealing or stopped supervised store is used.

Independent frozen preflight caught missing during-fault preservation in the
first candidate; the exact executed revision fixes that weakness. Root also
confirmed named-file formatting. Full suite, production runtime/gate edits,
native/model calls, real-ticket operations, commits, pushes, deployment and
cleanup were not performed.

## Held predecessor byte identity

Existing held-amendment lifecycle at line 487 passes: one test, zero failures,
72 excluded, 88.9 seconds (case 75.05 seconds). Exact frozen/live SHA256:
`6d0919e3c0fb460e2e64a3ee2be1c8be69db25b7e33de2748946703fd6c44db5`.
Durable source: `blocked_predecessor_byte_drift_test.exs`; log/export:
`recovery-evidence/u11-blocked-predecessor-byte-drift.{log,coverdata}`.
Root independently measured TCA425 with one call; focused baseline recovery
is now 117, not aggregate 99% acceptance.

After genuine authorization and terminal-write rollback, only the RESERVED
predecessor JSON gains a newline. The public getter remains valid, but application
returns `:amendment_predecessor_changed` before consuming authority. Full ledger,
source, index, HEAD, branch and untrimmed porcelain status are unchanged during
rejection. Exact original bytes are restored in after; complete canonical rows
and exact getter output recover before the unchanged successful held application
and remaining lifecycle. No outer transaction is used because application owns
its rollback. No admission, receipt or hash is rewritten.

Independent frozen review required the explicit raw-status checks; the final
executed revision includes them. Root confirmed named-file formatting and source
hash after execution. No runtime/gate edit, full suite, native/model turn,
real-ticket action, commit, push, deployment or cleanup occurred.

## Concurrent MR preparation preserves pending ownership

New isolated public-protocol test at line 4483 passes: one test, zero failures,
73 excluded, 37.2 seconds (case 23.57 seconds). Existing MR-claim test at line
4625 passes unchanged: one test, zero failures, 73 excluded, 45.4 seconds.
Exact frozen/live lifecycle SHA256:
`4d7572b90c0ea8793ce2c1e09b896378c885c26d86eeb1e74e71ed27ec101cdf`.
Durable source: `concurrent_mr_pending_peer_test.exs`; logs/exports:
`recovery-evidence/u11-concurrent-mr-pending-peer.{log,coverdata}` and
`recovery-evidence/u11-mr-preparation-helper-regression.{log,coverdata}`.
Combined accepted focused import remains 117 recovered baseline lines, not 99%
aggregate acceptance. The original 742 hypothesis is not counted.

One real temporary Git upload-pack barrier allows a second public prepare while
the first is outside the transaction. The inner creates one authentic PENDING
controller request. Unclaimed public failure returns `:ticket_mr_claim_unproven`
without mutation. The outer then returns `:ticket_mr_controller_busy`; retry
returns the exact existing peer, with no duplicate, claim, task or source change.
Full affected ledger and source/index/HEAD/ref/status snapshots bracket the
rejection and retry. Status is read with `--no-optional-locks`. Config restoration
and task cleanup are bounded; production and fixture deadlines are unchanged.
Only pre-request setup was extracted from the existing helper, preserving its
call order and return modes; the existing claim regression confirms that flow.

The initial failed-attempt test wrongly expected public failure to create FAILED
from an unclaimed MR. Actual guard rejection disproved that hypothesis. Public
claim makes FOLLOWUP_UNCERTAIN, and subsequent failure is RECONCILE_REQUIRED,
still busy. No DB mutation or ownership fabrication was used to force FAILED.
The corrected test names and assertions reflect the real protocol explicitly,
not a production change to satisfy the original expectation. Initial failure
log/export remain in `recovery-evidence/failed-attempts/` and are not accepted.
Frozen review also corrected the controller/scope row filter and observational
index-refresh risk before the final successful run. No runtime/gate change,
full suite, native/model call, real-ticket operation, commit, push or deployment.
