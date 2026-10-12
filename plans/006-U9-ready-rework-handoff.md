# U9 prerequisite: direct rework of a review-ready candidate

Scope: implement the already-required ordinary parent-chat READY_FOR_REVIEW
rework path. Not a new feature lane, engine, tagged-GitLab adapter, manual
validator, or deployment authorization. Immutable diagnosis source is
`/private/tmp/symphony-u9-rework-diagnosis.0oQPL9`; ten files remained unchanged.
The existing BLOCKED-WRITING resume guards must not be loosened.

## Sole-writer implementation sequence

1. TicketChatCommands: add exact READY rework validation/application recording
   using existing native-body, staging, payload and binding validators. Require
   current candidate/contract/chat generation and whole supported command shape;
   allow only selected bound answers, reject unrelated questions, competing
   commands/amendments and changed admitted input. Seal original writer, verifier,
   checkout, MR/push references before mutable logical task updates.
2. Scheduler: route READY commands to named ready admission; keep blocked resume
   unchanged. Use existing REVIEW_WRITING without legacy review_base_sha or
   review_feedback_json flags, which route to deferred REVIEW_PUSHING.
3. TaskLauncher: one preparation transaction revalidates command, capacity, exact
   checkout and stopped predecessors; transitions READY to REVIEW_WRITING,
   refreshes logical run:feature-writer, acquires SOURCE, reserves a fresh
   WorkerEvidence request, applies selected answers if any, and writes terminal
   application receipt. Roll back every row on failure; launch only afterward.
4. WorkspaceAccess.acquire reacquires the same released checkout, not blocked
   transfer. Require clean exact candidate HEAD, branch/root/path/Git identity,
   no unresolved file/check operations, no competing lease and the 20 GB gate.
   Unexpected held ownership fails closed. Preserve immutable old output/evidence
   before refreshing a consumed logical task. New invocation/request/turn identity
   is mandatory; thread reuse requires exact stopped/consumed proof.
5. TicketWorkerRunner: narrowly command-bound ready-rework packet with exact
   native body and sealed action reference, normal feature-writer model/effort
   and existing source restrictions. Do not use blocked-resume exemptions.
6. Preserve old candidate, completed slices, checkout, MR, push history and prior
   PASS as history. REVIEW_WRITING must not deliver based on old PASS. Existing
   source adoption commits declared edits or preserves no-edit candidate,
   increments verifier round, and enters VERIFYING; require fresh independent
   verification before any later push.
7. Prepared recovery: RESERVED reuses the recorded request; START_SENT/uncertain
   reconciles without relaunch. Historical replay validates immutable authority
   without demanding the old live run image after legitimate progress.

## Downstream joins

- Preserve candidate_handoff: TicketPush.prepare_existing supports completed-push
  rollover with historical evidence; do not erase it to make preparation pass.
- Existing-MR MR_CREATING cannot finalize against an old-candidate receipt.
  If no current-candidate delivery receipt exists, use existing CREATE_OR_REUSE
  preparation for exact original MR identity. No replacement MR or weakened
  draft/reviewer safety. Preserve normal finalization and readback guards.

## Adversarial constraints required before dispatch

The immutable-source review found the same-run seam viable, but the following
assumptions cannot be left implicit:

1. Fence CI-preflight specifically for a command-bound READY rework. Without
   legacy feedback flags, current source adoption may enter CI_PUSHING without
   incrementing verifier round. Edited and no-edit READY rework must first enter
   fresh VERIFYING even when ordinary CI-preflight is configured. Do not alter
   ordinary initial-delivery preflight policy.
2. Prove no-edit same-SHA MR reuse through completed-push rollover. MR operation
   keys currently omit verifier round, while strict reuse binds the old push
   receipt digest. A new handoff with the same candidate/contract/stage collides
   with that old key. Implement a narrowly proven same-MR/current-verification
   qualification or bounded identity rollover retaining historical requests;
   do not weaken exact-candidate or original-MR identity checks.
3. Define READY-specific fresh Jira admission through the exact accepted native
   command. READY with ai-review/In Review does not satisfy ordinary writer
   admission. Authorize READY-to-REVIEW_WRITING only with fresh bound readback;
   no temporary SQL-state rewrite or global admission loosening. Reject stale
   or expired proof and test realistic review labels/status.
4. Seal consumed writer/verifier evidence and released checkout authority before
   refreshing the logical task. Current completed_result requires live logical
   task compatibility that the refresh destroys. Historical replay validates
   immutable original snapshots, not the overwritten task. Prepared recovery
   reconstructs its sealed packet/request and rechecks HEAD/ownership before
   first launch; changed packet/input and prelaunch HEAD/owner drift reject.

These are corrections to the required path, not another engine. Implementer
must choose the smallest existing-module receipt/identity representation and
report it at the first checkpoint; ask root before adding a schema/new module.

## Concrete MR identity rollover refinement

The immutable-source follow-up recommends using the existing validated
completed_push_sha256 authority digest in a versioned MR identity. Existing
identity omits that digest even though unchanged-context checks require it.

- Preserve v1 serialization/key bytes. New v2 bindings append the digest to the
  existing ordered identity fields; derive it only from TicketPush.completed_proof.
  Its envelope already includes verifier round. Claim-receipt version is separate.
- Centralize selection for prepare/adopt/current receipt/CI qualification: qualify
  current completed push, then exact v2 reuse; if absent, inspect v1 and reuse only
  matching exact digest/context, including pending requests without mutation.
- Mismatched v1 permits v2 rollover only when that predecessor is validated and
  terminal SUCCEEDED. Pending/uncertain/reconciling/malformed predecessors reject;
  do not authorize another send from a context mismatch.
- Validate bindings and rebuild comparisons using the stored supported version;
  never rewrite legacy metadata to make it qualify. Preserve exact original MR
  iid/url/state checks, and gate retained-MR finalization on current receipt.

Focused tests: same-SHA fresh verification/push produces one distinct request but
the same MR, with duplicate/reopen reuse; exact matching v1 pending/completed reuse
has zero new request while mismatched unresolved v1 blocks; mismatched valid
terminal v1 can roll once, but corruption/replacement identity cannot. This is
source-backed design, not implemented acceptance or a new schema requirement.

## Verified post-review delivery authorization prerequisite

Completing the older post-amendment verifier exposed another required delivery
join: fresh verifier PASS leads to PUSHING, but global Runner.authorization only
uses review eligibility for REVIEW_WRITING/VERIFYING. A runtime diagnostic
confirmed exact matching authorized contract with Jira ai-review/In Dev and run
PUSHING/revision 3/verifier round 2/retained MR; initial-label eligibility rejects
it as ticket_jira_not_dispatchable. Do not normalize labels or skip the old path.

Implement a delivery-specific qualification for V1 PUSHING/MR_CREATING with a
proven retained MR. Require current delivery_facts: exact stopped/consumed
current-round verifier PASS, candidate/contract binding, existing checkout and
ownership checks. Validate MR identity against sealed original delivery/amendment/
rework history; merely non-null mutable run MR fields do not authorize this path.
Then apply existing review label/status eligibility plus identity/freshness/
ordinary-contract/blocked/spec-needed rejection. Leave ordinary authorization
and initial delivery semantics unchanged.

Use the same qualification in Scheduler's delivery authorization caller and
recompute it inside delivery_admission immediately before effects. Do not consult
an old PASS or require a current MR receipt before the new push (circularity);
historical original-MR evidence is separate from current push/MR receipt.
Existing Runner/Scheduler/Push/MrOperation/Commands receipt helpers may be minimally
extended; ask root before schema/new modules. Tests cover amended and direct-rework
delivery, missing/stale verifier proof, unproven/replacement MR and unchanged
initial/source admission. This is an in-scope U9 join correction.

## Fresh controller check after contract amendment

The old writer's completed controller check is correctly stale when revision or
contract digest changes, even if candidate SHA stays the same. A verifier PASS
is not substitute controller-check evidence. No fallback or waiver is authorized.

Existing WorkerEvidence.check_scope supports a stopped RESULT_RECORDED
change-verifier under its existing REVIEW reservation. Runner.adoption_role for
that role presently obtains verifier_receipt but does not run a fresh check.
Use that existing pre-consumption seam: for PASS, reuse a fully qualifying current
controller-check receipt, or execute existing check(request_key, git-diff-check)
before consuming the verifier/releasing its lease. Require a real completed PASS
bound to current candidate/revision/contract. Preserve ordinary non-PASS handling.
Keep fixed program/sandbox/owned-child receipt and idempotent recovery guards;
failed/uncertain check cannot deliver and reuses/reconciles the same operation.
No source writes, new model turn, check catalog expansion, synthetic receipt,
or rebinding stale physical receipts. Focused tests cover fresh amended-contract
check, matching reuse, and failed/uncertain/wrong-candidate blocking.

## Focused tests and freeze

Reuse existing command, worker, desktop lifecycle and delivery fixtures. Prove
admission drift/capacity/competing owner and late SQL failure fully roll back;
one checkout/logical task/fresh request; RESERVED reopen and uncertain no-relaunch;
edited and no-edit source completion with fresh verifier; old PASS cannot deliver;
push-history rollover and exact same MR reuse; blocked-resume regressions intact.
Start with focused exact named cases, then extend canonical U9 and run its scoped
integration group at the boundary. No new harness/hooks/schema owner, broad test
loops or live calls. Capture actual buggy bytes before correction for discriminating
RED/GREEN. Freeze touched files for independent Sol review before U9 acceptance.

Named product ownership: TicketChatCommands, Scheduler, TaskLauncher,
TicketWorkerRunner; WorkspaceAccess/WorkerEvidence/TicketPush/TicketMrOperation
only where the existing required join needs a minimal correction. Ask root before
other modules/schema. One source writer; root owns this handoff/receipts.

Offline integration does not prove native human input while busy. Those bounded
native acceptance and final commit/push/deployment gates remain separate.

## Remaining acceptance execution packet (2026-10-08)

The no-edit canonical checkpoint passes end-to-end. Reuse its existing admitted
checkout/parent/ledger rather than introducing another harness or replaying
initial setup per fault. Sole writer owns source/tests; root owns this packet.

1. At the genuine new-push barrier, prove old Journal COMPLETE/released rollover
   with unchanged old row/access bytes. Separately reject genuine pending or
   uncertain history and corrupt binding/receipt/release provenance, with no
   new operation/reservation/effect. A different digest with equal/future verifier
   round is not proven older history: reject or require reconciliation. Use API
   baseline construction; restore exact named fault injections in `after`.
2. Insert READY generation drift into the existing prepared restart block:
   capture access/task/evidence/run/application, increment only that reservation
   generation, poll once, require zero launch and unchanged authority rows,
   restore generation in `after`, and read back the exact access row. Then run
   the existing HEAD-drift and successful single-start recovery. Never mutate
   another checkout; assert admitted path == run.worktree == access canonical path.
3. After canonical final READY, stage one new native command for a declared edit.
   Extend the existing flat direct-rework fixture with its existing file-tool
   read/write pattern, one declared changed path and commit message. Require a
   changed candidate, new verifier round/PASS, new push and original-MR READY.
   Configure ordinary preflight true here to prove READY still enters fresh
   VERIFYING first, per adversarial constraint 1. Initial-delivery preflight
   behavior stays unchanged; do not waive fresh READY verification.
4. Put actual START_SENT owner loss last, after successful edited READY. Stage a
   fresh proposal/turn/item/client identity and use the existing held-resume
   server. Capture launch.pid/starter and require active_owner(task_key) equals
   launch.pid. Monitor the exact PIDs; terminate only the captured supervisor
   child, await DOWN and registry absence. If a distinct captured starter survives,
   terminate only that fixture PID and await DOWN. Do not send its continue signal
   or manufacture owner-stop/status rows. Reopen/poll with a fresh supervisor:
   same unresolved attempt, held lease, application/request, no launch/start,
   unchanged start counter. Capture the actual typed hold; null-output adoption
   may reject differently from prepared-reconstruction reconciliation.
5. Freeze final changed source and obtain finite independent acceptance review;
   run the already-specified three-file U9 boundary group once. Report failures
   and skips exactly. Native busy-parent acceptance remains a separate gate.

No extra fault permutations, schema, queue, engine, full-suite iteration, cap
extension, live calls, commit/push or rollout is authorized by this packet.

Known return contracts to preserve in caller/test patterns:

- `RunLedger.get/2`: `{:ok, run}` with string-keyed fields.
- `RunLedger.update/4`: `{:ok, %{result: "UPDATED", run: run}}`; extract `run`
  before passing it to run-identity or stage validators.
- `current_legacy_review/2`: `:ok` or `{:error, reason}`, not `{:ok, row}`.
- `Store.one!` for `SELECT COUNT(*) AS count`: `%{"count" => integer}` even
  when zero; aggregate absence is not `nil`.

A negative lineage test must distinguish the intended guard from an earlier
corruption/current-push rejection. Do not manufacture successful authority
receipts merely to reach a branch; state any unreachable fixture limitation.
Before an expensive first lifecycle run, freeze the new test/source delta for
a finite precheck of these return contracts and checkout/authority targets.
Cheap named-unit RED/GREEN remains immediate; don't repeat an unchanged group.

### Exact-request preflight qualification

The edited adoption may persist its new candidate before
`Scheduler.ticket_role_transition/4` runs. Therefore the READY exemption cannot
use `ready_rework_active?/2`'s original-candidate equality alone. Bind it to the
exact adopted worker request and validated APPLIED READY receipt, not any
historical command. Preserve ordinary initial delivery's preflight behavior.

The edited canonical configures `ci_preflight: "draft_mr"` and must first observe
changed candidate → VERIFYING with verifier round incremented, then a distinct
fresh PASS before push. A narrow initial-writer adoption regression with no READY
receipt must still enter CI_PUSHING with its verifier round unchanged. Existing
tests seeded directly in CI_PUSHING do not prove this initial adoption behavior.
