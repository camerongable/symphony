# U8b first-writer blocked amendment recovery

Status: first-writer recovery packet accepted locally. Focused author checks,
scoped statics, root independent executions and all three bounded frozen reviews
passed. No whole-Slice-4/U9 acceptance or rollout is claimed.

## Local acceptance

Final manifest: `006-U8b-first-blocked-final.sha256`. Only the amendment critic
test changed after the repaired freeze; all eleven other hashes are unchanged.
Root verified all twelve final hashes before and after independent migration
execution. The migration-only correction adds stale-v35 readonly rejection with
full nonmutation and complete version/applied_at receipt preservation; author
seed 776780 passed 1/0, and root exact-named execution session 36743, seed 702919
passed exit 0, 1 test, 0 failures, 32 excluded, 3.4 seconds. Migration frozen
re-review returned bounded PASS on both additions. Unchanged recovery-proof and
polling frozen PASS verdicts remain bound to the other identical files.

Root independent nil run session 43338, seed 162460 passed exit 0, 2 tests,
0 failures, 2 excluded, 79.2 seconds, with actual trace names and unchanged
hashes. All five author cases and scoped compile/specs/format/Credo/diff checks
are retained below. This accepts the finite nil recovery, normal-poll adoption,
ordinary compatibility and migration packet only. Mixed commands and U9 remain.

## Repaired frozen checkpoint

The following checkpoint records the review/repair chronology, now resolved.

Root independently matched all twelve hashes in
`006-U8b-first-blocked-repaired.sha256`; HEAD remains
`52a978818875c59ccf2758ed1b728bb23e33f631` on
`cgable/desktop-owned-ticket-chat-v1`. Sole source writer completed/stopped.
All five focused author cases and compile/specs/scoped format/Credo/diff checks
passed. Root is independently running only the two critical nil recovery cases
by actual test-name regex, session 43338, seed 162460: terminal exit 0,
2 tests, 0 failures, 2 excluded, 79.2 seconds. Trace names match both intended
cases. All twelve hashes still match after this run.

Three parallel reviews all rechecked identical source hashes:

- Recovery proof: bounded PASS for ordinary compatibility, sealed nil HEAD
  application/transfer, prepared launch fencing and immutable historical replay.
- Polling: bounded PASS for reciprocal-transfer-aware held routing, strict
  normal adoption and no direct fixture fallback or COMPLETE filtering.
- Migration: no runtime defect found; add readonly rejection/nonmutation while
  schema is exactly v35, and include `applied_at` in full receipt preservation
  snapshots on success and rollback. These are test corrections, not a user
  blocker or authorization to expand scope.

Finish the root frozen run before reopening source edits. Then repair only the
migration fixture, rerun that selected case, refresh the freeze and obtain its
bounded re-review. Preserve the two unchanged production-scope PASS verdicts by
hash identity. Mixed commands remain unstarted.

## Intermediate review correction

The intermediate freeze failed review. Root independently ran the exact frozen
nil case `factory_desktop_ticket_chat_lifecycle_test.exs:293 --trace`, seed
558352 (session 86580): 1 test, 1 failure, 2 excluded, 29.6 seconds. It selects
the intended test by name and fails decoding nonexistent
`sealed_predecessor["access_json"]` at line 348. Reported `:292` runs cannot
prove this frozen `:293` case; previous nil PASS claims below are author reports,
not accepted evidence for the frozen version. Re-resolve selectors and retain
trace names for repairs.

Frozen reviews identified these concrete repairs:

- Ordinary blocked resume uses a missing strict `checkout_head_sha` key.
- Application encoding drops sealed HEAD; nil resume can fall back to the wrong
  base, and pre-transfer validation can miss HEAD drift.
- Prepared-but-unstarted nil resume does not revalidate HEAD before launch.
- Historical installed HELD routing starves a fresh resumed COMPLETE result;
  the direct-ticket-step fallback masks the normal-poll failure.
- Migration fixture retains version 36 and uses a v34 parent shape, so it does
  not prove the claimed genuine v35 upgrade or complete rollback evidence.

All review hashes matched. Review performed no tests/builds or external effects;
the root's single named reproduction is the executed evidence above. The sole
writer has resumed these finite repairs and the remaining nil-specific cases.
There is no packet acceptance, and mixed-command implementation has not started.

Detailed bounded requirements and plan critique:
`../006-U8b-contract-adapter-prep.md`, first-writer recovery section.

## Evidence collected

- Amended held-resume/history `factory_ticket_worker_lifecycle_test.exs:477
  --trace`, seed 68080: author reports intended test, 1 test, 0 failures,
  73.1 seconds. Normal polling consumes current COMPLETE and emits TICKET_ADOPTED
  without direct `Scheduler.ticket_step` fallback. Same thread, no duplicate
  writer/transfer, exact result CONSUMED before the fixture's later READY seed.
  This uses a nonnil predecessor; the separate `:481` case proves positive
  nil-candidate adoption. Scoped statics, fresh freeze and review remain.

- After the shared fixture correction, exact mixed-index nil recovery case
  `:293 --trace`, seed 868318: author reports intended test, 1 test, 0 failures,
  37.8 seconds. The fixture uses its dirty-path read-only branch; staged-change
  adoption remains fail-closed and all retained bytes/index remain intact. This
  is a focused regression rerun, not a whole-suite or final acceptance claim.

- Corrected positive nil-amend replay `:481 --trace`, seed 434004: author
  reports intended case, 1 test, 0 failures, 42.4 seconds. Reopen launches the
  next verifier through WorkerServer and collects `{:ok, _}`; no duplicate
  TICKET_ADOPTED/writer, same exact CONSUMED request and committed candidate.
  This resolves the wrong fake app_server selection. It remains focused fixture
  evidence, not live independent verification or whole U9/Slice-4 acceptance.

- Parallel read-only fixture investigation resolved the verifier anomaly: the
  positive case reused `critic_context` on its replay tick, so a change-verifier
  launch received CriticServer's specification-critic shape (including
  required_questions, missing candidate_sha/checks). Scheduler supplies the
  correct verifier schema; existing WorkerServer already returns that shape.
  Select WorkerServer for the verifier replay, collect/assert its actual result,
  and rerun before final freeze. No production verifier change is indicated.
  This source-backed finding is not executed verifier acceptance.

- Exact valid-unstaged nil-amendment case `:481 --trace`, seed 895117:
  author reports intended test, 1 test, 0 failures, 42.2 seconds. Candidate
  stays nil through amendment/preparation; supported repo_write produces the
  declared unstaged slice; normal polling emits TICKET_ADOPTED, controller
  commits real nonnil HEAD, and the canonical application request is CONSUMED.
  Reopen launches only the next verifier with no duplicate source/adoption and
  preserves candidate/evidence. No fake worker Git staging/commit. This proves
  adoption/replay, not verifier PASS or U9 acceptance; the separate fake verifier
  schema anomaly remains under bounded investigation.

- Positive nil-amendment case `:481`, seed 244749: author reports same-thread
  sealed-HEAD resume, permitted repo-write slice, actual controller commit,
  TICKET_ADOPTED, nonnil candidate HEAD and exact request CONSUMED. Reopen
  legitimately starts a fresh verifier, not another writer. Its fake output
  returns `:factory_stage_output_schema_mismatch`; the success-only fixture wait
  then times out. Correct replay assertions to forbid duplicate source/adoption
  while permitting fresh verification, and collect its actual terminal result.
  This run is failed evidence, not positive-case or verifier acceptance. Parallel
  read-only investigation is resolving the fake output/envelope versus real schema.

- Minimal valid-unstaged nil-amendment adoption case `:481 --trace`, seed
  219928: author reports real normal-poll TICKET_ADOPTED and VERIFYING with
  the controller-committed nonnil HEAD, followed by reopen assertions, then a
  fixture failure reading nonexistent `launch.request_key`. Launch exposes a
  task key, not that field. Bind the test to the rework command's exact durable
  application-receipt request key; no latest-row inference is needed. Rerun
  before claiming this case passed.

- Genuine v35 migration selector `factory_ticket_amendment_critic_test.exs:364
  --trace`, seed 75583: author reports the intended case, 1 test, 0 failures,
  2.9 seconds. Starting receipts are exactly 1..35; the parent retains
  SUPERSEDED/supersession_json and a native-correction-generated successor link.
  All four starting candidates are NOT NULL. Tests compare complete populated
  parent/child/link rows, indexes, receipts and FK/legacy pragma settings after
  upgrade and induced-FK rollback. Independent frozen review must verify this
  assertion scope before accepting the migration evidence.

- Ordinary no-amendment rework regression `factory_ticket_worker_lifecycle_test.exs:1155
  --trace`, seed 412316: author reports the intended named case, 1 test,
  0 failures, 13.8 seconds. Same-thread resume has no missing-key exception;
  normal polling adopts its valid unstaged/untracked declared slice and consumes
  exactly once. This does not substitute for amended nil-candidate adoption.

- Exact nil retention/recovery case `:293 --trace`, seed 331810: 1 test,
  0 failures, 38.4 seconds. Author reports original binding SHA A differs from
  measured HEAD B; candidate stays nil through application and preparation;
  same-thread resume occurs once; crash/reopen and owner-generation/HEAD drift
  reject before native start without task/evidence/access mutation. Index and
  dirty/untracked bytes remain intact. COMPLETE adoption of this mixed-index
  state deliberately fails closed at the existing staged-change gate, retaining
  nil candidate. No fake worker Git staging/commit remains. This is bounded
  recovery/retention evidence, not positive COMPLETE adoption or packet acceptance.
  Remaining: normal-poll valid-slice adoption/history, ordinary resume, genuine
  v35 migration/rollback, statics, new freeze and independent review.

- Repair rerun selected the exact intended nil case with `:293 --trace`, seed
  770784, and exposed an incorrect access-row lookup. The initial interpretation
  was nil original expected SHA; later binding inspection disproved that: this
  value lives inside `binding_json`, not at the row's top level. Preserve that
  immutable original binding; never manufacture a value to satisfy the fixture.
- Subsequent exact nil selection, seed 12388: 1 failure, 2 excluded, 32.0
  seconds, with `:blocked_resume_expected_sha_unproven` before SOURCE transfer.
  The application receipt contains the sealed HEAD; the writer is tracing its
  normal scheduler-to-launcher propagation without base/options fallback.
  This is current failed evidence, not packet acceptance.
- Next exact nil run, seed 350552, passed the previous resume-preparation
  rejection and reached the deliberate post-preparation crash: the absent task
  supervisor leaves durable reserved evidence and a STARTING task. Its HEAD-drift
  fixture then failed creating a synthetic commit. Initial missing-parent
  diagnosis was refined to untrimmed Git command output: newline-bearing IDs
  were passed to commit-tree. The writer corrected only that synthetic setup,
  not production HEAD checks, and started rerun handle 37185. This run is not
  a PASS or acceptance.
- Handle 37185 terminal, intended nil case seed 37115: 1 failure, 2 excluded,
  34.1 seconds. Durable preparation and prelaunch HEAD-drift rejection were
  reached. Restoring HEAD then failed `:blocked_resume_checkout_head_unproven`:
  TaskLauncher reads expected SHA at the top level although WorkspaceAccess
  stores it in `binding_json`. The sole writer is fixing this exact lookup and
  rerunning the named case; acceptance is still pending.
- Exact nil run seed 788671 reached the three-value assertion, which repeated
  the same top-level-field mistake. Binding inspection confirms a nonnil
  original expected SHA, independently measured different HEAD, and nil adopted
  candidate. TaskLauncher and fixture now read the canonical binding value;
  a new exact rerun is in progress. This failed run is not acceptance.
- Exact nil run seed 516968: 1 failure, 2 excluded, 36.4 seconds. It reaches
  normal-poll COMPLETE adoption but fails `:native_slice_pre_staged_changes`:
  the synthetic worker reports COMPLETE while retaining mixed staged, unstaged
  and untracked changes. Keep that production rejection. Workers must not
  manufacture commits; a valid completed slice must pass the controller's
  existing declared-path commit protocol. Retained dirty-data proof and valid
  adoption proof must not be conflated. On genuine adoption, the nil candidate
  becomes the independently observed committed HEAD; expecting nil in VERIFYING
  would mask an invalid transition.

- Worker reported warnings-as-errors compilation PASS.
- Initial real polling case handle 97000 passed (1/0, 40.3 seconds): an amendment
  preserves nil adopted candidate and records separate checkout HEAD. This fixture
  explicitly seeds the full fake Jira snapshot before native proposal staging;
  it is not U9 proof of live intake/current-snapshot refresh.
- Updated selected run handle 56836, seed 294572: 2 tests, 0 failures,
  32.7 seconds. The polling case additionally compares Git status, index/staged
  bytes, unstaged bytes and untracked bytes before/after amendment. The migration
  case asserts nullable candidate columns, indexes/version and read-only opening.
- Strengthened migration case `factory_ticket_amendment_critic_test.exs:364`,
  seed 13160: 1/0. Worker reports all four NOT NULL starting tables are asserted,
  populated upgrade preserves rows/FKs/indexes/version 36, and an induced child-FK
  failure restores exact DDL and original FK setting. Source freeze/review still
  must confirm these assertions cover the real migration path.
- Existing adopted-candidate/history selector
  `factory_ticket_worker_lifecycle_test.exs:477`, seed 339074: failed at the later
  scheduler step near line 959. Parallel read-only triage obtained the terminal
  stack but only a generic Store transaction rollback, not the failing typed gate.
  The failure remains required work; no pre-existing/baseline claim is supported.
- Nil resume handle 17110, seed 489605: 1/1, 32.5 seconds. The admitted
  standalone `Rework the current candidate` reaches transfer but fails
  `:blocked_resume_authority_unproven`. Root confirmed an actual semantic
  mismatch: command parsing accepts both normalized standalone forms, while
  `WorkspaceAccess.rework_body_matches?/3` requires one literal Please sentence.
  Correct the shared singleton predicate without weakening native input/hash/
  command proof; do not merely choose the one phrase that passes the old guard.
- Subsequent nil resume reached the worker and recorded the precise failure
  `resumed ticket worker opened a different thread`. Worker traced a real caller
  omission: TaskLauncher placed `resume_thread_id` on the Launch struct, while
  `run_child` supplies `launch.opts` and TicketWorkerRunner reads that keyword.
  The writer has added the validated existing thread ID to both new-resume and
  prepared-reuse options; the same-thread invariant is unchanged. Focused runtime
  and adopted-history regression results are still pending.
- Nil polling/resume handle 30284, seed 711658: 1/0, 35.7 seconds. Worker
  confirms the selected `:292` case applies the nil-candidate amendment, preserves
  staged/unstaged/untracked data, resumes the persisted task/thread and binds the
  successor SOURCE expected SHA to measured HEAD while candidate remains nil.
  Earlier false-match failures were traced to fixture body/content assumptions,
  not a loosened runtime policy; temporary diagnostics were removed.
- Adopted-history diagnostic handle 76061, seed 708854 found the precise gate:
  `WorkerEvidence.completed_result` returns `:worker_inputs_changed` because an
  old RESULT_RECORDED blocked witness binds revision 4 while current run binds
  revision 5; role/stage/prompt/model match. Correct pending selection only for
  the exact predecessor fully validated by a durable APPLIED
  `BLOCKED_WRITER_HELD` receipt. Preserve old evidence; missing/corrupt history
  stays fail-closed and `current_inputs` must remain strict. This repair is pending.
- Further diagnostics refined that classification: the failing request is not
  the amendment's blocked predecessor; its output is COMPLETE with no matching
  rework-transfer/predecessor receipt. The fixture directly seeds READY after
  resumed completion while this evidence remains RESULT_RECORDED. A speculative
  COMPLETE exclusion based only on an applied contract bridge was removed: it
  could discard unadopted work. Require actual controller adoption/consumption
  before seeding READY, and verify normal polling does not let a fulfilled blocked
  witness starve the current completed result. This boundary is not resolved yet.

## Still required

Intermediate source freeze is recorded in
`006-U8b-first-blocked-intermediate.sha256` (paths relative to `elixir/`).
Root independently matched all twelve hashes; writer stopped editing. Latest
selected nil case with distinct original expected SHA and measured HEAD passed
seed 865707 (1/0, 40.2 seconds). Migration plus nil selection passed seed 736847
(2/0, 41.7 seconds); adopted-history case passed seed 46028 (1/0, 67.0 seconds)
after requiring actual adoption/CONSUMED before synthetic READY. Scoped compile,
specs, format, strict Credo (zero issues) and diff checks reported PASS. This is
an intermediate review checkpoint, not acceptance: review must trace the
normal-poll versus direct-ticket-step consumption discrepancy, and nil-specific
prepared-crash/reopen, pre-transfer HEAD/owner drift and later-progress historical
replay still lack proof.

- Prove genuine populated version-35 starting DDL is NOT NULL in all four tables,
  then migrate/reopen with rows, foreign keys and indexes preserved. Verify
  version-36 failure rollback restores all four definitions and connection FK
  settings. Fresh-v36 child tables plus an old parent are not equivalent evidence.
- Nil-candidate explicit same-writer SOURCE resume, preparation crash/reopen,
  ownership/HEAD drift rejection, historical replay after authorized progress,
  and retained dirty content. Existing adopted-candidate resume alone is not proof.
- Existing adopted-candidate/READY and historical receipt regressions, exact
  nil/HEAD/original-expected-SHA distinctions, scoped statics, frozen source and
  independent review.

Use existing migration, amendment, Jira and worker lifecycle fixtures. No full
suite, new harness, production hook, live connector/native effect, commit/push or
deployment is authorized or claimed by this receipt.
