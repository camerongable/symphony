# U7 typed parent Desktop claim runtime admission

DesktopRequest captures the exact current request before entering SQLite. For a
TICKET_CHAT CREATE/FOLLOWUP, it verifies issuance eligibility, pending status and
any required parent guard before probing the configured runtime. CREATE uses the
existing canonical parent directory of the not-yet-created chat cwd; FOLLOWUP
uses its already-bound cwd. No caller-supplied capability flag or token is accepted.

The claim transaction requires the captured request to remain exactly unchanged,
then repeats issuance and guard validation before recording the claim and marking
it uncertain. The guard retains its original ten-second freshness window; a slow
probe cannot refresh its timestamps. Legacy/MR claims also compare their captured
request, preventing a type switch from bypassing parent qualification. Runtime
probing for typed MR requests is a separate unfinished unit.

No probe is added to listing, formatting, readback, or duplicate already-issued
claims. Unsupported runtime leaves the pending request unchanged, with no parent
claim receipt. Existing fixtures use an actual configured initialize-only process;
modules that alter process-global Workflow settings now run synchronously.

RED seed 362109: old claims admitted an unsupported parent and did not issue a
runtime RPC. GREEN seed 77014: both focused regressions passed. Caller files passed
71/0, seed 625492, before the expanded regressions. A drift fixture initially failed
its SQLite project/type constraint before reaching the intended assertion; it was
corrected to perform a schema-valid type switch. Final seven-file checks passed
74/0, seed 367934, 23.8 seconds, covering unsupported CREATE/FOLLOWUP, status/type
drift, unchanged pending rows, exactly-once claims, guard expiry during an actual
eleven-second fake probe, and probe-free listing/readback.

Independent frozen-source review accepted the admission boundary. Public specs,
strict Credo (6,169 modules/functions), formatting and whitespace checks pass.
The final private comparison was simplified to require the captured map directly,
removing an unused nil alternative; final focused parent/legacy checks passed
19/0, seed 43198, 3.3 seconds (18 unrelated parent cases excluded). No native model, live connector,
production configuration, deployment or real-ticket operation was performed.

Remaining U7 wiring: shared typed MR claim qualification outside its current outer
transaction, then supervisor/startup policy integration and aggregate acceptance.
Production remains disabled and Slice 3 remains incomplete.
