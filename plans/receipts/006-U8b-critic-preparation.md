# U8b critic preparation and claim acceptance

Accepted locally after independent frozen Sol review. Migration 30 adds one
amendment-owned critic attempt and a child task under the existing delivery run.
`prepare_critic/5` binds supplied serialized post-draft Jira readback, exact
proposal, prompt/schema and configured role allocation. `claim_critic/4`
revalidates those bindings and atomically claims attempt/task once. INVOKING
cannot prepare or claim again. The installed run snapshot, contract, candidate,
writer allocation, checkout and lease remain unchanged.

Writer-observed targeted result: 48 tests, zero failures across command/migration
files. Formatting, owned-file strict Credo (98 checks), specs, warnings-as-errors
compile and cached Dialyzer (zero errors) pass. Root independently observed the
preparation/reopen/one-time-claim regression: session 33975, seed 774320, one test,
zero failures, 41 excluded. No full suite was run.

Frozen SHA-256:

- `store.ex`: `c553f3e90aa0ebed8daad851959c2b6ab8f819132d34806812d92427f083f2c5`
- `ticket_contract_amendment.ex`: `c4de7262d60a7947f619452a315fd13713e707705dc814321a7bfa13a484d062`
- command tests: `e17822d4dbb54c6994a3d63ce28424d12f4813ca4c234b2ed73e964a0f2a3622`
- migration tests: `031753c4a6492805d6ee19e28354550bd0fedeec1dd74decfcd13f2bf3a260ed`

The reviewer verified all hashes before/after and found no blocking defect in
this scope. This is not Jira publication proof or critic execution. The actual
invocation consumer must require the persisted draft-publication/readback receipt
matching these bytes, rather than trust supplied snapshot JSON alone. Native
visibility/restart and full-slice acceptance remain separate.
