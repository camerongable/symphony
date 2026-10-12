# U7b preparation: same-checkout worker launch and adoption

Status: U7a accepted. U7b launch/controller adoption is implemented locally;
independent component review is ACCEPTED with no remaining findings. The full suite passes,
but repository-wide acceptance remains open at the unchanged 100% coverage gate
(99.37% observed). See `receipts/006-U7B-worker-integration.md`.
Keep production V1 quarantine until U7c and the combined ordinary lifecycle gate pass.

## Implemented prerequisite checkpoint (2026-10-05)

- Exact stopped WorkerEvidence can recover the lost task result before TaskLauncher
  refreshes its output or allocation. Incomplete/conflicting/ambiguous attempts
  reject rather than launching again; COMPLETE/CONSUMED replay does not regress.
- Accepted parent readiness requires its exact observation, payload and generation
  plus a successful bootstrap acknowledgement, not just a recorded thread ID.
- Corrected a U7a integration regression: generic checkout reservation reads the
  maintenance mutex independently of cleanup-route quarantine. Cleanup admission,
  reconciliation and ensure_available remain quarantined for V1-owned issues.
- Six focused suites pass: 91 tests, zero failures. Specs, format, scoped strict
  Credo and whitespace checks pass. Independent checkpoint review is ACCEPTED;
  reviewer separately passed worker-evidence and ticket-chat tests (30/0).
  Prior U7a's eight suites also pass (185/0) after the reservation correction.

These prerequisite results are historical. The integration below supersedes the
earlier unfinished status; it does not enable V1 or implement U7c.

## Implemented full U7b integration (2026-10-05)

- TaskLauncher dispatches through TicketWorkerRunner using the run's one checkout,
  deterministic attempt/reservation keys, existing SOURCE/REVIEW admission, and
  explicit stored model/effort on recovery. No Desktop role-task request is created.
- Internal `Scheduler.ticket_step/3` launches or adopts one exact stage attempt.
  New launches require scoped controller-owned Jira readback no older than 60
  seconds. The production tick does not call this entrypoint yet.
- Planner adoption enters ADMITTING_WRITER; the existing controller still owns
  Jira/writer admission. Writer adoption reconciles exact file receipts, commits
  once, runs the approved git-diff-check, and advances only after safe adoption.
  Verifier adoption requires an exact stopped candidate/base-bound receipt.
- Final stage/task/evidence consumption and checkout release are transactional.
  Parent, contract and stage are rechecked at adoption boundaries. Lost candidate
  publication or failed release recovers the same commit/check without another
  worker turn or increment. Failed checks retain candidate and reservation.
- Ten serial lifecycle tests cover a planner, two same-thread writer passes and
  fresh blind verifier, plus capacity, authorization, saved-allocation drift,
  failed check, parent/stage races and commit/release recovery. They pass (10/0).
  Seven combined suites also pass (152/0 before the final parent-race extension).
- Full repository run: 1,139 tests, zero failures, six existing live skips in
  897.1 seconds. Build, format and whole lint pass; standalone Dialyzer passes.
  `make all` fails only at coverage (99.37% versus 100%), so the complete quality
  gate is not accepted and no production enablement is authorized by this result.

Build/test controller actions beyond the existing check catalog, parent broker
issuance/presentation and production routing are not claimed by U7b. Required:yes
validation remains deferred. No live models/connectors, deployment or enablement
are part of this checkpoint.

## Ownership and scope

One source writer. Primary files: `task_launcher.ex`, `ticket_worker_runner.ex`,
`scheduler.ex`; change `worker_evidence.ex` only if existing recovery semantics need
a demonstrated correction. Preserve LEGACY behavior, controller-only commit/push/MR
authority, stage schemas, iteration accounting and Required:yes separation.

## Front-load uncertain boundaries

1. Prove adoption recovery after worker completion before task COMPLETE persistence,
   after controller commit before candidate adoption, and after task CONSUMED before
   reservation release. Recover the same attempt without another turn or commit.
2. Require accepted parent binding, not merely a binary thread ID. U7c owns actual
   parent issuance. Configuration alone cannot attest effective tool permissions.
3. Assert FILE_SOURCE for writer and REVIEW for planner/verifier through existing
   runtime policy checks. Reject broader effective capabilities before launch.
4. Preserve saved model/effort for unfinished attempts. Router updates must not
   silently rewrite an attempt's allocation or evidence identity.

## Launch

- Validate ordinary contract, immutable route, parent readiness, current controller
  authorization and runtime capability before task/process writes.
- Reuse TicketWorkerRunner.packet/4 and bind_base/3. Keep stage/task keys and schemas.
- Bind every worker to the run's one checkout. Pin source base or review candidate.
- Resolve new allocations once; reuse saved allocations on recovery.
- Derive deterministic request/reservation keys from task, prompt digest and attempt.
- Acquire existing WorkspaceAccess SOURCE or REVIEW reservations with capacity,
  canonical path and maintenance checks. Do not create Desktop TASK requests.
- Launch TicketWorkerRunner with explicit owner, reservation, allocation and base.
  Ambiguous owner/stop/check outcomes retain the reservation for reconciliation.

## Adoption

- Require exact WorkerEvidence receipt and stopped owner before successful adoption.
- Writer: validate file-operation receipts, perform controller-owned approved checks
  and exact commit, persist candidate/task adoption, then consume/release evidence.
- Planner: adopt plan against pinned clean base without creating a candidate.
- Verifier: require verifier_receipt/3 bound to the candidate and review base before
  PASS or delivery transition. Blind review packets contain no writer history.
- Restart prefers existing completed receipts and recorded adoption. Never infer
  permission to retry from process absence or duplicate an already observed commit.

## Discriminating verification

Use task-launcher, ticket-worker-runner, worker-evidence and V1 lifecycle suites;
reuse workspace-access coverage rather than duplicate capacity/path/race tests.
Cover LEGACY unchanged/default-disabled V1; same checkout SOURCE/REVIEW exclusion;
parent/contract/SHA/policy rejection before launch; low capacity without candidate
loss; duplicate request; each adoption crash boundary; uncertain owner retained;
wrong-candidate verifier rejected; stored allocation unchanged by routing updates.
Freeze source and obtain independent review before U7c. No production enablement.
# Post-planner admission update

First-checkout prerequisite: exact pinned branch/checkout creation is now locally
implemented and independently reviewed; see
`receipts/006-U7B-pinned-checkout-primitive.md`. Durable initial admission and
receipt-only recovery are now locally implemented and independently reviewed;
see `receipts/006-U7B-checkout-creation.md`. Production registration/tick routing,
runtime acceptance and the combined gate remain outstanding.

Ordinary registration now has an atomic run/parent/request join with pre-capacity
parent validation; see `receipts/006-U7-registration-join.md`. Production inputs,
V1 poll advancement and runtime startup gating remain outstanding.

The manual WRITING state patch in the existing worker lifecycle test has been
replaced by the controller's real existing-checkout admission bridge. See
`receipts/006-U7B-writer-admission-bridge.md` for checks, frozen review and remaining
registration/materialization/tick integration. Production fences remain unchanged.
