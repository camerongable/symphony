# Completed push history and next-candidate admission

2026-10-05. TicketPush now handles a COMPLETED envelope by proving its retained
history, then independently admitting the current candidate. It never clears or
replaces PREPARED/PUSH_UNCERTAIN during rollover and never clears push history
during writer adoption.

Historical proof includes the exact released MAINTENANCE row, run/key/generation,
byte-exact release_receipt_json, binding/hash/key derivation, execution/nonce,
historical checkout and candidate, unchanged repository/branch/destination, and
independent original terminal-receipt readback/hash. Current admission requires
fresh authorization and current verification/check/source ownership gates. The
physical checkout must still match. A distinct derived key acquires the new
reservation; the completed envelope is replaced by a direct CAS in the same
transaction. Historical release receipts remain in existing durable storage;
there is no schema migration or added history table.

The same candidate can progress from authorized CI preflight to a fresh verifier
PASS and ordinary delivery: phase/verifier evidence produces a distinct intent.
An identical completed binding cannot acquire its already-released reservation.
A repaired candidate uses its own evidence, nonce, reservation and receipt.

Independent read-only review accepted the boundary. Initial focused checks passed
2 tests, 0 failures, 26 location exclusions (seed 387375, 56.0 seconds), covering
real repaired-candidate push, retained history, corrupt/missing release receipts,
expired authorization, transactional replacement failure, same-candidate CI
preflight and rejection before fresh verifier PASS. Strict Credo, public specs
and whitespace checks pass.

Additional assertions for identical binding, unreleased historical ownership,
dirty source and candidate drift during an uncertain push passed with the original
once-only restart/reconciliation case: 2 tests, 0 failures, 26 location exclusions
(seed 946264, 62.6 seconds). Formatting and whitespace checks also pass. Frozen
`lib/symphony_elixir/factory/ticket_push.ex` SHA256:
`b6b9032fb3123129a4ffbae100758e891d83efcab3d2340235794cba87edb5a0`.

No production branch, paid/native agent turn, external connector, deployment,
commit, or real remote push was used. MR/CI/Jira connection and combined U7
acceptance remain unfinished; production routing stays disabled.
