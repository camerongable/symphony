# Current-candidate MR result adoption

2026-10-05/06. Continued U7 after durable MR claim/readback. This is a local
implementation/fixture checkpoint, not native sending or production acceptance.

## Implemented

- `TicketMrOperation.adopt_result` finds the original semantic request; unresolved
  requests wait without issuing anything. Successful requests require the exact
  immutable claim, current ordinary authorization, unchanged candidate/contract,
  current stopped push and physical checkout, configured controller scope, and
  current remote source branch SHA.
- MR bindings now require an explicit positive numeric GitLab project pin, taken
  from the configured repository route at preparation. An older unpinned binding
  is preserved and rejected; its key/metadata are not rewritten or replaced.
- `CiCollection.collect_mr` reuses read-only catalog/schema and ID normalization
  for two MR-only reads on an existing caller-owned session. It does not open a
  session or collect pipelines, jobs, commits or discussions. The exact MR ID,
  project, URL, branches, candidate and human-state fields must agree; unrelated
  head-pipeline changes are ignored for this MR-only operation.
- Reads use the immutable controller cwd, not arbitrary caller workspace options.
  The fresh MR must remain opened, draft, reviewer-free and assigned to the expected
  user. Human changes reject adoption without corrective GitLab writes.
- Final persistence rechecks the complete run/request/claim, fresh local admission,
  and the retained stopped push. It explicitly compares the newly observed physical
  checkout to the push binding; independently valid proofs are not enough.
- Ordinary adoption records only MR fields and stays `MR_CREATING` until separately
  scoped Jira finalization. CI-preflight adoption moves `CI_MR_CREATING → CI_WAITING`.
  Explicit already-`CI_WAITING` handling requires stored MR identity to agree with
  the original receipt. Identical repeated adoption makes no ledger update.
- The existing scheduler's locked MR-stage path now consumes this result. A missing
  original request reports `MR_REQUEST_PENDING`; it does not invoke the legacy
  controller finalizer, enqueue creation, or mutate Jira.

## Verification

- Final `mise exec -- mix test test/symphony_elixir/factory_ci_collection_test.exs
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:766
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:771` passed 18/0,
  seed 113631, 62.5 seconds. Normal scheduler ticks exercise ordinary record-only
  adoption and preflight CI waiting, exact repetition, preserved push/request/claim/
  writer/Control evidence, expired authorization, wrong/missing project pin,
  missing/foreign session, changed human state, stale candidate, changed claim
  during collection and physical checkout replacement.
- MR-only collector tests also prove MR-only catalog suffices, pipeline changes
  do not block it, and unsafe catalog, wrong project and changing MR state reject.
- Controller/result-readback suites plus retained typed claim and MR preparation
  lifecycle regressions passed 23/0, seed 338792, 53.9 seconds.
- The checkout-replacement regression was confirmed RED: temporarily removing
  only the final push/checkout coupling allowed wrongful `MR_ADOPTED` despite a
  changed root inode (seed 647091, 1 failing test, 28.6 seconds). The coupling was
  immediately restored and the final test run passed.
- Specs, strict Credo, formatting and whitespace checks pass. Independent frozen
  review found and verified the workspace-input and physical-identity coupling
  repairs; final verdict found no remaining blocker for this packet. Initial
  fixture/return-shape errors were repaired and are not native observations.

No paid native turn, connector call to a real service, production-ledger mutation,
deployment, commit or production push occurred. Source pushes in tests were only
to temporary local bare repositories. Internal read-only review reused existing
subagents; per-unit token usage was not separately metered.

## Frozen SHA256

- ci_collection.ex: cd89bc7f57d9f9708dc247c0a6d0d35feb99f43c8c92be315a5ab78ee8db14cd
- ticket_mr_operation.ex: 48aa35d9eee5ecf73ff53405ec30487a2430bfac0b5afc99972a1d3a244b74a7
- scheduler.ex: a967ab5e2d87e6907d5aeccfa03e79a59a323072d662fda8c3ee63d55d010b56
- factory_ci_collection_test.exs: 783d12b86ca3174fb522bef1d651be27d93c01474215871f8ea478e99de23e7c
- factory_ticket_worker_lifecycle_test.exs: 23e59d07b6c74e568da4584af137226243189ad4d083308d2ce1eeae677915d3

## Remaining

Native typed MR pending discovery/CLI/send wiring and an actual supported producer
of the existing-session read scope remain unproven. Do not fabricate a session or
replace the controller chat to satisfy the prerequisite. CI/Jira joins, disabled
draining, the combined lifecycle, native acceptance and the unchanged final quality
gate remain. Slice 3 and Slices 4/5 are not complete; production stays disabled.
