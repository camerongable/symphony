# Exact-candidate controller delivery admission

2026-10-05. TicketWorkerRunner.delivery_admission checks an unchanged ordinary
run, ready parent, fresh exact Jira authorization, delivery phase and candidate,
then the existing clean/inactive checkout admission. Worker evidence must all be
consumed; file operations must be reconciled; all recorded controller checks must
be complete with valid helper receipts. A PASS controller check must additionally
bind this exact candidate, run, contract and revision.

Final delivery requires the current round's consumed verifier task and immutable
consumed verifier receipt with PASS for this candidate. Explicit route-authorized
CI preflight does not require that later verifier; CI_MR_CREATING and CI_WAITING
do require their already-pushed ci_preflight_sha to equal the current candidate.
CI_PUSHING precedes that pin. Scheduler's deferred post-role handoff now invokes
this gate, using the tick's reader and workspace root.

This is a point-in-time admission check, not a durable operation receipt or a
permission token. The next controller-operation packet must invoke it immediately
before the exact action, retain serialized ownership, and reconcile any ambiguous
external result without creating a new operation. Actual push/MR/CI handlers are
not joined yet. Production enablement remains rejected.

Verification: the real temporary-Git normal-tick lifecycle passed 1 test, zero
failures (seed 360733, 28.7 seconds). It exercises checkout, planner, two writer
passes, verifier and then admission; rejects expired authorization, missing/wrong
root, unconsumed worker evidence, nonconsumed verifier and an untracked file;
checks explicit pre-verifier CI authorization and stale/exact preflight pins;
rejects a different unchecked candidate. Earlier lifecycle seed 998973 and the
preflight-extension seed 997048 also passed. Whole strict Credo, public specs and
whitespace checks passed. Independent read-only review accepted the original
gate and both pin/check refinements; no concrete defect was found.

No production dispatch, external connector call, native model turn, source
commit outside temporary test repositories, push, deployment or cleanup occurred.
Combined U7 acceptance and the final complete quality gate remain outstanding.
