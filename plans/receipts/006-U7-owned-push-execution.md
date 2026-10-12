# Owned push execution and terminal readback

2026-10-05. TicketPushIO now launches one fixed controller Git push through a
verified helper, with committed helper PID/execution binding before sending its
input. The exact envelope is reconstructed from the authoritative Store and
validated authorization during attachment; copied-ledger or substituted proof
fields are rejected. Execution uses the persisted intent/nonce and a protected
exclusive claim. Existing source-worker/check sandbox profiles are unchanged.

The final pre-spawn gate rechecks ordinary run identity, candidate/branch/clean
checkout, exact Git/common-directory and reservation binding, destination hash,
parent/bootstrap identity and actual payload fields, consumed exact verifier
binding/output/task identity and review base, and fresh authorization. Git output
is discarded so credential-bearing diagnostics are not persisted. Signals are
installed before admission; spawning and owned-child registration are signal
masked; post-spawn cleanup always kills/waits the owned child when necessary.
The bounded helper publishes its immutable terminal receipt before replying.
Readback reads the original claim/receipt and never invokes push again.

Verification on frozen repaired source: successful local bare-remote push,
exact SHA readback and duplicate denial plus final-gate failure tests passed 2/0
(seed 48160, 34.4 seconds). Rejection tests mutate bootstrap status/action,
verifier output/binding and reservation Git identity after attachment; remote
branch remains absent and ownership stays held. Execution-substitution tests
reject copied database and different authorization snapshots. A separate slow
local pre-receive hook test passed 1/0 (seed 909309, 14.6 seconds): termination
of the helper kills/reaps Git, records its signaled terminal status, confirms the
Git PID is absent, and reads back the identical original receipt. Strict Credo,
public specs, formatting and whitespace checks pass.

Independent read-only review identified late shutdown ownership, incomplete
final bootstrap/verifier/reservation checks, and execution-envelope substitution.
Those were repaired and reviewed; the remaining payload/action and verifier
binding refinements were also accepted. Reviewer terminology about payload_json
was corrected against the actual schema: payload consists of the captured
request fields, not a separate payload_json column.

Not yet accepted: separate-VM crash/lost-reply tests at the execution boundaries,
same-operation reconciliation/finalization, narrow reservation release, and
scheduler push/MR/CI connection. Ownership remains held after this component;
no delivery state or production flag is advanced. No production branch, external
connector or native model call was used. This is not completed Slice 3 or U7.
