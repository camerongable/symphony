# U8b READY amendment application acceptance

Accepted locally after targeted tests and frozen independent review. One
transaction installs the exact authorized contract and snapshot, advances
READY_FOR_REVIEW to VERIFYING with a fresh verifier round, and seals the
command/amendment application receipts. Candidate, source tasks, leases, slices
and writer allocation remain unchanged. Duplicate application is historical,
not a reset of the live run; a validated inactive amendment permits a later one.

Author observed 35 application/migration tests passing before the review repair.
Review found that self-resealed historical run images could change the prior
state or applied snapshot. A public regression failed before the repair. The
repaired focused module passes 29/0; format, scoped strict Credo, Dialyzer and
diff checks pass. Root observed the corruption regression independently:
session 51202, seed 774325, one test, zero failures, 28 excluded, 1.7 seconds.
Root also observed the public-function spec check passing.

Independent re-review accepted exact prior binding, permitted-field transition
and canonical authorization-snapshot validation. Frozen fingerprints:

- Amendment: `176083e18abb69d24838f9594cbbb1cf43b291919da3f6c3eaba340e0fee4434`
- Critic/application tests: `37dae5bc56e276fde9ca7f1399ef4fef75c7cf8ed66a7f10977dc6394f9c1cb4`
- Store: `b7b842717a926f6fdba17032885c3a18ab6ae23ebf3bf83161f0fb5a63692cf7`
- Migration tests: `6bdcc5c8ebfccd4825274e0334d4ac627a0374ba34d89578d4e7548b5799ce33`

No full suite, live external effect or native acceptance was performed. BLOCKED
application and retained-predecessor rework, mixed command/polling integration,
non-PASS proposal recovery and whole-slice acceptance remain.
