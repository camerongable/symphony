# Durable typed MR claim and historical readback

2026-10-05. Continued U7 from fresh-request preflight. This packet implements the
internal claim/readback boundary; it does not enable native sending or production.

## Implemented

- Schema 26 adds `ticket_mr_claims` alongside the existing request queue. One
  receipt pins the immutable payload, operation binding, original prior turn,
  owning broker observations and claim timestamp. Receipt insertion and transition
  to FOLLOWUP_UNCERTAIN are one SQLite transaction. No new queue is introduced.
- Typed claims require fresh ordinary admission, completed push/current remote
  facts, the original controller lineage, and no competing unresolved controller
  request across scopes. Any feedback-note ownership rejects this MR route.
- The project-controller guard requires the exact owning-Desktop quiet status,
  project/thread/directory, complete empty queue and original latest completed
  native turn. AppServer reads only the latest descending page, rereads it after
  queue collection, compares exact turn data, and checks history identity/version.
  This avoids relying on timestamp precision or fetching the complete chat.
- Claimed requests are never rearmed or granted send permission after restart.
  Reconciliation uses bounded pages and immutable claim proof, without fresh Jira,
  enabled admission, model resolution, or current controller-turn prerequisites.
- Claim existence remains a quarantine owner even if routing metadata or the run's
  execution mode changes. Corrupt/missing proof never falls back to legacy routing.
- Thread/result readback validates exact immutable request evidence and affects
  only the original request. It does not overwrite newer Control model, effort or
  turn, mutate writer rows, or advance delivery. Existing turn/schema/tool-call
  checks and idempotent completion remain in force.

## Verification

- Final typed MR lifecycle: `mix test
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:748` passed 1/0,
  seed 307279, 22.8 seconds. Real temporary Git repositories and a local bare
  remote exercise writer/verifier/push preparation, followed by mocked native
  guard evidence, claim rollback, restart/no-resend, competing controller,
  mixed ownership, corrupt receipt/metadata, changed routing, historical
  completion and unchanged writer/run/Control rows.
- Desktop request + parent-guard regression files and existing MR preparation
  lifecycle passed 22/0, seed 773731, 26.7 seconds. This preceded the final
  exact-turn confirmation tightening; the new claim lifecycle was rerun afterward.
- Final guard + exact latest-turn queue-race collector test passed 3/0,
  seed 714087, 1.7 seconds. Cases include a new human turn under an unchanged
  timestamp and stable exact-turn confirmation.
- Schema migration and remaining latest-turn collector tests passed 5/0,
  seed 732046, 2.0 seconds. Read-only access rejects unmigrated schema 25;
  repeated initialization preserves its old migration receipt.
- Specs, strict Credo on changed source, formatting and whitespace checks pass.
  Initial test-fixture defects (broker bound on the wrong fixture row and wrong
  Store reader API) were corrected; they are not native capability observations.
- Independent frozen source review identified and verified repairs for native
  lineage, mixed ownership and the post-queue race. Final verdict: no remaining
  blocker in this disabled/internal packet, not native acceptance.

No paid native turn, live connector call, production ledger change, deployment,
commit or production push occurred. All Git push activity was fixture-local.

## Frozen source SHA256

- ticket_mr_operation.ex: 8aaca85ef269886cd9ba3f908f5911d5f79e75e426eebdb0476409a005926dff
- ticket_mr_guard.ex: 17191f1fa7670fd6e348730202ef7069964d4eee0ccd54333a3f516e7fdef8d2
- desktop_request.ex: b6bdd619daf0ed7d8cb9e16d0e3f0496c37922ebf6356a7dfee7b9c069d6a2a3
- store.ex: 8611242a92e26e7fecb0fd4e060af89fa6f36e5d7ddc1db5b77d84ded34d05d3
- app_server.ex: 1aaed87a06b58d2884313c14301aec0dcfff4388d491fbcfce2b92d7dcf35f87

## Remaining U7

CLI does not yet supply typed MR claim authority, pending discovery still excludes
these requests, and DesktopToolArgs has no typed CONTROLLER-MR send branch. Keep
that production fence until the supported runtime boundary is integrated/proven.
Next join: receipt-only MR-result adoption bound to current candidate and remote
facts, without replaying issuance or invoking the legacy finalizer's immediate
Jira mutation. CI/Jira joins, the combined lifecycle acceptance, native acceptance
and the unchanged final quality gate remain. Slices 4/5 are not complete.
