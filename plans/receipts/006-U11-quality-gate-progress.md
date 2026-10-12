# U11N quality-gate progress — not acceptance

## Frozen gate and exact results

Implementation checkout: `/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`.
Baseline HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`.
Inherited dirty/untracked changes were preserved. No commit, push, deployment,
native model turn, real-ticket action or tracker mutation occurred.

First invocation stopped at strict lint before tests. Its log is
`/private/tmp/symphony-u11-finalgate.y7hopv/make-all-first.log`.
Behavior-preserving private-helper extractions and mechanical style corrections
passed focused checks and independent frozen delta reviews. No lint rules,
coverage exclusions, product guards, public APIs or dependency versions were relaxed.

The next invocation ran the full tests with all tracker live-test opt-ins disabled:

```sh
HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 SYMPHONY_RUN_ASANA_LIVE_E2E=0 \
SYMPHONY_RUN_GITHUB_LIVE_E2E=0 SYMPHONY_RUN_GITLAB_LIVE_E2E=0 \
SYMPHONY_RUN_JIRA_LIVE_E2E=0 mise exec -- make all
```

Artifact directory: `/private/tmp/symphony-u11-final-retry.NW9LAG`.
Its `source-before.sha256` manifest digest is
`d8fd1998ea25b4da6e457c374ccf7bcfd3284be1ffa9afc0432708c162cd1acf`.
The 453 before/after source-file hashes are identical.
`make-all-final.log`, copied HTML coverage and `gate-result.json` retain readback.

- Build, formatting, public specs and strict Credo: PASS.
- Tests: 1,467; failures: 5; skips: 6; seed: 63974.
- Test elapsed: 3,007.3 seconds (167.9 async, 2,839.4 sync).
- Coverage: 95.59%; unchanged required threshold: 99%.
- Gate exit: 2. Dialyzer: NOT RUN.
- Cached Hex security advisories were reported for unchanged locked dependencies.
  Nine support fixtures triggered load/ignore-filter warnings. This was not a
  dependency-security audit or permission to upgrade.

The exact frozen Store/Context plain-VM replay probe also passed: 268 AppServer
trace patterns, zero replay launches, one positive-control launch, unchanged
valid/incomplete ledgers, incomplete-schema rejection, three worker records,
and no Mix/Symphony application startup. See `read-only-probe.log` in the same
artifact directory. This is not restricted deployed-broker acceptance.

## Five failure corrections

Frozen corrected candidate:
`/private/tmp/symphony-u11-failure-fixes.IKfnlH/source`.
Manifest digest:
`4146fd14df29dc7930cd85844cf144dd937393f33a273cb418c6e4902be9c2ba`.

1. Legacy migration fixture now matches the quoted SQLite table name and current
   phase CHECK before constructing its RESERVED-only predecessor. Production
   migration code is unchanged; read-only nonmutation and preserved-row assertions remain.
2. Pilot-report expectation pins existing “Not stored per run or turn” wording.
3. Parent-broker expectation pins the existing exact JSON acknowledgement instruction.
4. Retained preflight MR history selects the existing CI_MR_CREATING identity for
   CI_WAITING. Ordinary selection and all push/request/binding/ownership/readback/
   result-schema/original-MR checks remain unchanged; no request is manufactured.
5. Only the named multi-stage uncertain-finalization test has a finite 450,000ms
   budget. Its previous healthy duration exceeded the 180,000ms module budget.
   Module/global and product worker/Git-read timeouts remain unchanged; no trace mode.

Writer-reported focused results: three quick cases 3/0 in 0.9s; ordinary plus
preflight MR adoption 2/0 in 146.1s; uncertain finalization 1/0 in 293.1s.
Formatting and strict lint pass. Independent frozen behavioral and fixture
reviews both returned PASS. These are not a new full-gate or coverage result.

## Focused coverage hardening

The first four finite batches added public-route rejection, replay and transaction
checks without changing production safety gates, coverage policy or dependencies:

- A: 74 tests/0 failures, 55.6s. Transport/replay checks; corrected frozen review
  preserves distinct foreign-session and cwd rejection cases.
- B: 108/0, 31.7s. Command/amendment replay, corruption and rollback checks;
  independent frozen reviews PASS.
- C: 88/0, 82.9s. Worker/Jira/critic rejection checks; review required restoring
  valid CI bindings before each isolated mutation. Corrected delta reviews PASS.
- D: affected lifecycle exports 2/0 in 96.3s and 1/0 in 26.0s. Unissued MR
  metadata, retained CI_WAITING output and held-amendment receipts reject precisely.
  Review required exact run-row comparisons after each metadata rejection; corrected
  case 1/0 in 26.5s. Final independent corrected review PASS.

Exports and diagnostic summaries are retained in
`/private/tmp/symphony-u11-final-retry.NW9LAG`. On unchanged production modules,
their union hits 70 previously missed baseline lines. This is not a fresh
aggregate coverage result. MR-operation line alignment changed with its production
fix and is excluded from that count; the estimated preflight recovery remains
unmeasured. A/C/D exports precede their final assertion-only review corrections.

Batch D frozen correction:
`/private/tmp/symphony-u11-batch-d-review.OCe5hZ/lifecycle-corrected.exs`, SHA-256
`9693c3ba766c8ddfd2439882b6b649fade8800054413ae9f941169e879bfef35`.
Its `{}` resumed-history corruption checks generic classification rejection,
not blocked-specific replay validation. The same-candidate later-verifier/push
legacy path is skipped with current genuine helpers, not proven unreachable.

### Batch E and READY-transfer regression

Four new command-test cases cover ignored terminal-command writes, transactional
mixed-answer rollback, genuine typed text/integer replay, invalid READY transfer,
and non-admitted amendment states. Initial frozen review required genuine typed
questions and full protected-row comparisons; the corrected delta passed.

The new empty-map transfer vector reproduced a production `BadBooleanError` at
the READY-transfer strict `or` boundary. The reservation predicate had returned
nil for missing identifiers. It now returns explicit booleans without changing
accepted truthy identity semantics or generation/history/digest/binding checks.
Empty, partial, nil and false records must reject with the exact existing error
and leave questions, commands and all protected state unchanged.

Final four-case export: 4/0, 1.3s. An intermediate export failed because the typed
question trigger retained its old Boolean-question key; that failure is retained
in the run transcript, not counted as a pass. Final trigger targets the actual
integer question. Independent production and corrected-test reviews PASS.
Root boundary check: all 71 command-file tests passed, 5.8s, seed 130827; log:
`/private/tmp/symphony-u11-batch-e-review.uXB3WF/commands-boundary.log`.
Exports `u11-batch-e-fixed` and `u11-batch-e-boundary` are retained with the other
gate artifacts. Formatting, specs, strict lint and diff checks pass.

Frozen source SHA-256:
`9fe9e05ef784dcb45b5ec58670ad7ea292f30ebb68515dba5b739cf72fedfbc8`.
Frozen test SHA-256:
`70a6bf7605883135a53574c3f0032376f53711ed7b376314c6af53c097b554ed`.
The pre-fix E export hit seven distinct old command misses. After the production
predicate change, counters need exact-source interpretation; no fresh aggregate
coverage or full-gate pass is claimed.

### Batch F and path-cycle regression

Five critic groups now check route-drift/prepared-result replay, default
reconciliation and stale-controller rejection, recorded owner-path corruption,
atomic successor-insertion failure and orphan-task rejection without replacement.
All use genuine public histories and isolated mutations. Independent frozen
behavior review PASS; no successful sealed history was fabricated.

The first five-case run passed four cases but timed out on a self-referencing
owner-CWD symlink. This was a real PathSafety recursion bug, not an unreachable
fixture. The temporary finite-alias replacement was not counted as a pass.
Direct regressions reproduced nonreturn for self, mutual and expanding link
cycles using owned tasks bounded to 250ms and killed before each assertion.

PathSafety now tracks only the active target-resolution chain, retaining ancestor
markers while resolving a target and restoring the caller's chain before its
original suffix. Cycles return the existing wrapped `:eloop` shape. Finite repeated
aliases, nested/relative/absolute targets, dangling tails and `:enotdir` preserve
their existing behavior. Early design and final frozen reviews PASS.

Writer focused results: three direct tests 3/0 in 0.09s; combined direct plus
five critic cases 8/0 in 4.3s. Root full affected-file boundary: 50/0 in 29.3s,
seed 58932. Persisted log:
`/private/tmp/symphony-u11-batch-f-review.Bo8wEX/boundary.log`.
Exports `u11-path-safety`, `u11-batch-f` and `u11-batch-f-boundary` are retained
under the original quality-gate artifact directory. Formatting, specs, strict
lint and diff checks pass. The F export hits eight additional distinct old
amendment misses; this is diagnostic, not a fresh aggregate coverage result.

Frozen SHA-256s in `/private/tmp/symphony-u11-batch-f-review.Bo8wEX`:

- `path_safety.ex`: `20b39ca505df6553c8bf7a93ae5f2daa1ed91ba5011042d5d3df755e0ba726fa`.
- `path_safety_test.exs`: `5664ff4d5b00e82ec290e3bc746d9ef8a359618769307e4cbce187f96b9fbc4b`.
- `critic_test.exs`: `2bc4311f786ee39d424368e7062004da7fd1ba101242e71d8495377a0ba34c74`.

Source/test hashes remained identical after the root boundary run. No real model,
tracker mutation, commit, push, deployment or policy change occurred. The goal
API now reports ACTIVE; the previous Blocked state no longer prevents automatic
continuation.

## Separate static-gate acceptance after focused hardening

Artifact root: `/private/tmp/symphony-u11-static-check.1EXRBr`.
The first standalone Dialyzer invocation used the existing up-to-date PLT and
returned 38 warnings (exit 2, 6.0s). Its original source manifests compare
byte-identically before/after the check. Locked dependencies and gate inputs
remain unchanged; no ignored-warning filter was introduced.

A genuine correction-admission regression found incorrect authorization-effect
classification. Both gates matched nil in their failure arm although an existing
SQLite effect is a map. They now return the existing precise
`amendment_authorization_effect_exists` error, preserving all protected rows and
retaining the no-effect successful reservation control. Focused red/green 1/0,
2.8s; `phase1-authorization-guard.log` retains the writer's verification note.

Private MapSet annotations alone did not resolve the opaque warnings. Frozen
review also rejected a charlist-only target annotation because read_link_all
supports binary filenames. The corrected implementation accepts both and uses
ordinary maps only for private visited-key membership; collections never escape
or persist. Membership, cycle guards, active-target scope and ancestry checks are
unchanged. Both corrected frozen reviews PASS; eight focused cases pass.

The remaining 32 warned clauses were independently proved redundant through
actual public return shapes. Pre-edit baseline: seven selected lifecycle cases
pass in 2.6s. Post-edit boundary: writer-reported 133/0 in 54.0s; public function
headers unchanged. Final frozen review caught two additional deletions outside
the approved list, including a real bare-false WorkspaceAccess rejection. Root
restored both extras. The corrected eight-file delta now contains only the 32
approved removals, with all real validation/error branches preserved; both
corrected frozen reviews PASS.

Final corrected read-backed checks:

- Dialyzer: exit 0, errors 0, skips 0, 5.73s; `dialyzer-restored-guards.log`.
- Root affected-file tests: 26/0, 17.0s, seed 396689;
  `restored-guards-tests.log`.
- Fresh forced compilation with warnings-as-errors: exit 0, 129 files;
  `compile-final-warnings-as-errors.log`.
- Formatting/specs/strict lint/diff checks pass. Full repository gate still pending.

`phase2-corrected/` and `phase2-corrected.sha256` retain the final runtime delta;
the rejected intermediate remains in `phase2-final/`. The broader source
manifest before this receipt update has digest
`45c2d7ee202c112ab8b35e21a966bf835d54e0ad47960006b18b2ae5beb93673`.
Intermediate 36/32/3-warning attempts remain recorded, not counted as passes.
No source safety predicates, coverage threshold/exclusions, dependencies, real
models, tracker state, commits, pushes or deployment settings were changed.

## Remaining

Parallel read-only mapping found 381 red executable lines across 17 modules.
The existing preflight case had failed before its WAIT/BLOCK/PASS helper, missing
about 34 lines; do not duplicate it. Remaining meaningful tests must use public
APIs and existing fixtures, assert precise rejection/idempotence/no duplicate
effects and unchanged protected rows, and avoid fabricated sealed histories or
private fallback coverage tricks. Red-line counts are not guaranteed gains.

The bounded first test work order is retained at
`/private/tmp/symphony-u11-final-retry.NW9LAG/coverage-work-order.md`.
Use one writer per checkout and parallel frozen review/preparation. Focused
checks during editing; no full suite per case. Preserve the 99% threshold and
all existing exclusions. Freeze and independently review additions before the
next final gate. Required:yes validation and tagged GitLab feedback remain deferred.

After offline acceptance, integrated native acceptance still needs its explicit
turn/runtime budget, real human UI observations and actual restricted-broker
diagnostic proof. Commit/push/disabled deployment and pilot enablement remain
separate approval gates. The automatic goal card was previously Blocked;
implementation continued manually until the current API read confirmed ACTIVE.
