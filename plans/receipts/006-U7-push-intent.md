# Durable once-only controller push intent

2026-10-05. TicketPush prepares an immutable versioned envelope in the existing
candidate_handoff field and atomically acquires one MAINTENANCE checkout lease.
It binds run/candidate/contract/revision/stage, parent and verifier evidence,
physical checkout identity and destination hash. Existing preparation reuses the
exact owned reservation rather than requiring an unowned checkout again.

Claim compares and swaps the original stored envelope from PREPARED to
PUSH_UNCERTAIN. Repeated claims fail, including after reopening the ledger.
Reservation key derives from the binding digest, and request identity must match
that key. Generation, ownership, expected SHA/root and physical identity are
checked through existing WorkspaceAccess validation. Malformed or changed
envelopes fail without normalization or releasing the lease. Generic RunLedger
updates cannot change V1 candidate_handoff, including mixed-field updates;
legacy updates remain compatible.

Verification: focused real-Git lifecycle plus RunLedger suites passed 18 tests,
zero failures (seed 836943, 35.8 seconds). Covers a completed writer/verifier,
duplicate prepare/claim, ledger restart, one retained lease, no remote branch
creation, malformed nonce/digest/phase/extra keys/reservation key, unchanged
corrupt input, changed destination rejection, and legacy field compatibility.
Earlier base lifecycle passed 1/0 (seed 543227), extended corruption/destination
case passed 1/0 (seed 477195). Independent read-only review accepted the intent
boundary and the reservation-identity refinement. Specs, strict Credo and
whitespace checks pass for this checkpoint.

This module performs no push and releases no ownership. It is not connected to
production scheduler delivery yet. Durable owned-process execution/stop evidence,
same-operation readback, narrow controller release and MR/CI joins remain next.
No production enablement, native model turn, external network mutation, push,
deployment or cleanup occurred. Combined U7 and final quality acceptance remain
outstanding; this is not completed Slice 3.
