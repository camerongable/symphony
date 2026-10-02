# Implementation plans

Generated on 2026-10-01. These are implementation handoffs, not statements that
the proposed runtime has passed acceptance. Read each plan completely, retain
the existing safety boundaries, and execute its gates in order.

## Execution order and status

| Plan | Title | Priority | Effort | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| [001](001-ticket-supervisor-workers.md) | Introduce one ticket chat with bounded role workers | P1 | L | Offline foundation before runtime acceptance | IN PROGRESS — adversarial review completed; disabled foundation next |
| [002](002-correlate-worker-turn-events.md) | Preserve and correlate exact worker-turn events | P1 | M | Source/protocol investigation complete | IN PROGRESS — isolated executor next |

Source rollback checkpoint: `bc7c28c5f7d79f37cfaf0d2c3ea873f758147863`
on `cgable/factory-control-plane`. This commit preserves the current Symphony
repository implementation. It does not back up the live SQLite ledger, runtime
settings, Codex chat history, or canonical skills outside this repository.

## Dependency notes

- Plan 001 first characterizes the protocol and builds the disabled foundation.
  Runtime permissions, worker readback and restart acceptance must pass before
  admitting work or enabling the new route. This avoids requiring a complete
  system before building the primitives needed to test it.
- Execute bounded plan 002 first for plan 001's offline protocol foundation;
  its tests cannot satisfy the later real-runtime acceptance gate.
- The older `elixir/docs/factory-hardening-plan.md` remains the record of completed
  reliability work and unfinished native-cleanup acceptance. Plan 001 proposes a
  different execution boundary; it neither marks native cleanup complete nor
  enables archive/restore.
- Existing tickets and unresolved Desktop requests keep their recorded transport.
  Do not migrate them as a side effect of implementing this plan.

## Findings considered and rejected

- Use the parent chat's recollection as the workflow state: rejected; SQLite owns
  authorization, candidate identity, reservations, and delivery transitions.
- Rename every role chat to the same title: rejected; this keeps the same creation,
  workspace, permission, and recovery boundaries underneath.
- Switch the parent to the verifier model and ask it to review: rejected; a fresh
  independent worker must produce the verdict.
- Use `thread/fork` with `excludeTurns: true` as blind review: rejected; the local
  schema describes response hydration, not removal of inherited model context.
- Assume a custom read-only agent setting overrides every parent permission mode:
  rejected; effective runtime enforcement needs an actual proof.
- Add a new supervisor-owned delivery state machine or an idle model heartbeat:
  rejected; retain the existing scheduler and wake only for actionable events.
- Delete stage checkouts or archive chats to demonstrate savings: rejected; this
  plan allocates fewer checkouts for new runs, without destructive migration.
