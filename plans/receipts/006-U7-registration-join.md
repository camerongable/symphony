# Ordinary delivery registration join

2026-10-05. Local registration integration; Policy's enabled-runtime rejection,
U7a polling quarantine and default disabled configuration remain unchanged.

The normal register_delivery seam selects V1 only for enabled, allowlisted
ticket-supervisor issues using Desktop transport. Existing authorization, risk,
repository, branch, snapshot and capacity semantics remain. Selected V1 runs
persist immutable execution_mode, controller-owned source ownership/runtime,
ADMITTING_WRITER, exact contract and ordinary validation requirement. Parent
allocation is orchestrator-intake and does not overwrite writer allocation.

Parent inputs are preflighted before capacity can authorize cleanup. The shared
TicketChat preflight validates identity, broker UUID, reader, source/Git directory
boundary and actual Desktop creation model/effort arguments. It renders request
arguments through the same creation_attrs implementation used by reservation.
Reservation revalidates after the run insert. Run, registration event, parent,
link and CREATE request commit in one transaction; returned and raised parent
failures roll everything back. No native/model/source turn occurs here.

Internal ticket_options carries explicit parent_output_root, broker_thread_id,
ticket_cli_root and ticket_workflow. The subsequent parent-input wiring receipt
records configuration propagation through normal ticks; do not infer values from
the shared controller thread ID or treat complete inputs as startup acceptance.

Verification: Scheduler, TicketChat and parent-admission suites **93 tests,
zero failures** (seed 206559). Covers one parent/run, duplicate ticks, exact
contract/ownership/model facts, no source effects, required-validation and reader
denial, parent insertion rollback, invalid broker/model/source-root rejection
before any capacity call, and disabled/nonallowlisted Legacy behavior.
Independent frozen review found incomplete pre-capacity validation; shared
preflight repairs it and rereview confirms that finding closed. A minor public
API validation-order issue was subsequently fixed with a dedicated missing-field
test. Whole strict Credo/specs and formatting/whitespace checks are run for this
checkpoint, not the final repository coverage gate.

Still required: configure rollout-specific parent/context inputs, route V1 advancement
through normal bounded ticks with rollback/draining semantics, replace the
startup fence only with actual runtime capability checks, then run combined U7
acceptance and the complete quality gate. Slice 3 is not complete or enabled.
