# Initial checkout reservation and single claim

2026-10-05. Local Slice 3 component, not production enablement.

Schema 25 adds one immutable initial checkout intent per delivery run. Reservation
binds the run, ready parent, pinned base, canonical repository/root, filesystem
identities and common Git directory. Capacity-policy repository must match.
Source-contained roots, existing paths, conflicting common-repository branches
and another unfinished intent for the issue reject before base-pin/intent writes.

Pending intents hold a concurrency slot and one configured disk budget until
READY. Measured free bytes remain unchanged in reporting; replay excludes its own
budget during admission. Reconciliation/uncertain phases retain the hold.

Claim uses transactional UPDATE RETURNING with an immutable binding digest and
one owner nonce. Duplicate claims/restarts do not authorize another mutation.
Authorization is revalidated before writes; rejected transactions roll back the
base pin and intent. This component does not execute Git or launch a model.

Verification: checkout/capacity/migration focused group **14 tests, 0 failures**;
Worktree and ticket CLI regression group **20 tests, 0 failures**. Specs check
passes. Final independent rereview confirms the common-directory fix; the final
lint rerun also corrected a test-only missing alias.
Independent initial frozen review accepted CAS, identity, rollback and budget
logic, finding the common-directory collision now fixed with a dedicated test.

Remaining: controller-owned Git execution and process receipt; atomic checkout
finalization into PLANNING; crash/uncertain readback without blind retry; scheduler
registration/tick integration; combined Slice 3 gate and native parent context
acceptance. Production V1 routing and existing tickets remain untouched.
