# U7 bounded Jira recovery and shared-controller fencing

Scope: ordinary ticket-chat Jira operations. No live connectors, native/model
acceptance, installation, deployment, real-repository commit/push or cleanup.
Production V1 remains disabled.

## Implemented

- `TicketJiraFinalization.reconcile` requires an issued journal and its original
  unreleased maintenance reservation. Generation, candidate, stopped delivery facts,
  full checkout/root identity and fresh MR/Jira targets are rechecked. It prepares
  no journal, acquires no reservation, claims no effect and sends no mutation.
- `Scheduler.reconcile_ticket_jira` selects one scoped operation using the normal
  delivery lock. Missing effects defer without replacement work; completed targets
  release ownership and advance READY atomically. Empty selection is quiet.
- Issued Jira operations fence shared-controller claims until exact historical
  journal/workspace-release receipts agree. Missing ownership, malformed release
  proof and current execution-mode drift retain the fence. New effect continuation
  can exclude only its own journal, never native controller requests.
- Native busy state is distinct from Jira uncertainty so recovery does not fence
  itself. Normal ticks perform bounded readback before ordinary advancement;
  recovery exceptions become class-only deferred events with rollback intact.
- Paused ticks use `TickLease.reconcile` with a fixed readback-only callback. The
  exclusive lease preserves dispatcher/tick identity, renewal and release without
  activating control. Ordinary callbacks cannot opt into paused execution.

## Verification

Final focused Jira/workspace/Desktop/control/lease/controller group: **45 passed,
0 failures**, seed 94795, 17.5 seconds. Extended scheduler/MR/Jira lifecycle:
**1 passed, 0 failures**, seed 699537, 122.5 seconds. A release-failure trigger
proves retained run/reservation/evidence; an unrelated synthetic parent advances
to one PENDING request without a native/model call. Mutation counts remain once-only.

The integration regression caught Jira uncertainty incorrectly suppressing its
own scheduler progress. Independent review found execution-mode drift could hide
issued journals and recovery exceptions could starve unrelated work. All three
were repaired and tested. No gate was weakened to obtain PASS.

Frozen read-only review accepted the recovery/lease/isolation boundary; reviewer
did not rerun tests. Public specs, focused strict Credo, format and whitespace
checks passed. This is not the unchanged full quality gate.

## Remaining acceptance

The named combined lifecycle must continue one repository/ledger/run through
normal scheduler checkout, planner, writer, verifier, push, typed synthetic broker
MR completion and Jira finalization. Existing tests prove complementary segments,
not that uninterrupted scenario. Do not substitute a cosmetic filename change
or mid-lifecycle fixture reinitialization.

Provider/broker installation, actual native lifecycle/permission evidence and
the unchanged full gate remain. Required: yes stays fenced. Slice 3 is incomplete;
Slices 4 and 5 have not been advanced or declared complete.

Reviewed base HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`; dirty work preserved.
Scheduler SHA256: `815898ac878e81bac51c39a0404b2383c8ab9fc56e67df4917a5fa3efed29026`.
TickLease SHA256: `4af145aaf54101689561980a7a9a1a32d6d7022252710a5380fb2996c8976391`.
