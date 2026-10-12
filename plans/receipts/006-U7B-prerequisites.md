# U7b prerequisite checkpoint

2026-10-05. Local checkout:
`/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`.
Branch `cgable/desktop-owned-ticket-chat-v1`; HEAD remains
`52a978818875c59ccf2758ed1b728bb23e33f631`. No commit or external mutation.

## Accepted work

- Lost task-result recovery adopts the exact stopped WorkerEvidence transactionally
  before TaskLauncher refreshes allocation/input/output or launches another turn.
- Incomplete, corrupt, conflicting or ambiguous evidence rejects without overwriting
  task state. COMPLETE/CONSUMED replay stays terminal. Checkout release remains
  owned by the existing exact controller-adoption/consume boundary.
- Worker admission requires the accepted projectless parent observation, exact
  payload/metadata/generation/cwd and successful acknowledged bootstrap turn.
- Generic checkout reservation checks maintenance phase independently of cleanup
  eligibility. U7a cleanup/scheduler quarantine remains intact. This fixes the
  cross-module regression found by running downstream worker/access suites.

## Evidence

Red baseline: worker/runner/launcher suites 36 tests, 25 failures from the U7a
maintenance guard. New recovery tests failed before adopt_completed existed.
New unacknowledged-parent test failed because the worker actually launched.

Final six relevant suites (worker_evidence, ticket_worker_runner, task_launcher,
native_workspace_maintenance, workspace_access, ticket_chat): 91 tests, zero
failures, seed 958650, 33.5 seconds. Prior eight U7a suites: 185 tests, zero
failures, seed 947365, 12.2 seconds. Public specs, repository format check,
strict Credo on six source modules and whitespace checks passed.

Independent read-only review: ACCEPTED for prerequisites only. Worker-evidence
and ticket-chat suites independently rerun (30/0), frozen source hashes unchanged.
No full suite, live runtime, Jira/GitLab or deployment acceptance claimed.

Key frozen hashes:

| Module | SHA-256 |
| --- | --- |
| worker_evidence.ex | 4cadb0cf674dc7c73e7d9bc0ad95caf90ac850bc5ca060c7ae1326f0b5ce15c7 |
| task_launcher.ex | 27b595a60cebf012c3578b7cb3749c9e1a97d658950d23883ac6ea133b3346ae |
| ticket_chat.ex | a284881044d32a1c7dab64dd9e0859e6453c123150c6f06ca8c765bc16a89f15 |

## Remaining U7b

Implement new-worker dispatch and deterministic reservations/attempt allocations,
then scheduler evidence adoption, controller checks/commit recovery and exact
verifier gate. Keep U7a production quarantine until U7c and combined acceptance.
Current recovery still requires the current role policy to resolve; it does not
overwrite stored model/effort when that policy's model or reasoning changes.
Account for missing/changed role policy during the remaining allocation wiring.
