# Implementation plans

Generated on 2026-10-01. These are implementation handoffs, not statements that
the proposed runtime has passed acceptance. Read each plan completely, retain
the existing safety boundaries, and execute its gates in order.

## Execution order and status

| Plan | Title | Priority | Effort | Depends on | Status |
| --- | --- | --- | --- | --- | --- |
| [001](001-ticket-supervisor-workers.md) | Introduce one ticket chat with bounded role workers | P1 | L | Historical foundation | REJECTED as active ownership design; retain accepted foundations, do not rerun |
| [002](002-correlate-worker-turn-events.md) | Preserve and correlate exact worker-turn events | P1 | M | Historical committed foundation | IN PROGRESS — foundation exists; current runtime acceptance belongs to 006 |
| [006](006-complete-desktop-ticket-chat.md) | Complete ordinary Desktop ticket-chat integration; gate required manual validation separately | P1 | L | Current dirty Slices 1–3 and capability gates | IN PROGRESS — ordinary `Required: no` path authorized; Required: yes remains gated |
| [007](007-complete-verifier-repair-cycle.md) | Complete retained-history verifier repair and current-status reporting | P0 | L | Copied deployed-source baseline and 80 passing focused checks | DONE — scoped local deployment00:50UTC20Oct; three packaged cases and independent preservation accepted; full quality limits remain |
| [008](008-complete-mr-receipts-and-ten-attempts.md) | Complete typed MR receipts, ten total attempts and ordinary generated-build handoff | P0 | L | Deployed007 scoped fix | DONE — scoped local deployment20Oct07:35UTC; preserved7spent, normal8thSOURCEgen39/native activity independently verified; ticket repair/CI/delivery not yet proven; existing full-quality limits remain |
| [009](009-bound-push-receipt-readback.md) | Recover bounded push receipts without repeating issuance | P0 | M | Deployed008 | IN PROGRESS — actual push remote-confirmed;262236byte receipt exceeds old262144 reader cap; new bounded readonly recovery candidate required |
| [011](011-review-report-contract.md) | Make reports robust and bound repair review | P0 | L | Frozen deployed R20 baseline | DONE — local C66 deployment26Oct18:11UTC;100 artifact tests; preserved schema/history; PPL-9881 new SOURCE activity proven; full lint gate limited |
| [012](012-isolate-scheduler-failures.md) | Isolate intake rejections and tick callback lifetime | P1 | M | Deployed011/C66 | DONE — deployed16ed26Oct19:43UTC with013; 355 artifact tests PASS; schema/history preserved; full quality limits remain |
| [013](013-separate-writer-readiness-from-verifier-acceptance.md) | Separate writer readiness from verifier acceptance | P0 | M | Deployed011/C66 | DONE — deployed16ed26Oct19:43UTC; exact stopped report accepted; ordinary generation subsequently exposed separate product-workflow path denial; no product adoption yet |
| [015](015-admit-product-go-workflow-source.md) | Admit product Go workflow source without policy authority | P0 | S | Deployed013/16ed | DONE — c646 deployed27Oct03:12UTC; actual completed repair consumed and commit eb9c67f0 adopted on normal tick; no product push yet |
| [016](016-complete-ordinary-program-version-bindings.md) | Complete ordinary push program bindings without rewriting history | P0 | M | Final015 source | DONE — c646 deployed27Oct03:12UTC; 91 packaged tests/four authentic synthetic receipt replays passed; history/schema preserved; actual prior publisher enrollment omission now isolated in018; full quality limits remain |
| [017](017-own-composed-generation-fixture-ticks.md) | Give composed generation fixtures their real renewing owner | P0 | S | Frozen016 production | DONE — test-only86f accepted and integrated04712e9; final composed4/0 including both publication paths, protected-path denial and owner identity; production/config/priv bytes unchanged |
| [018](018-retain-the-actual-publishing-origin.md) | Retain exact actual publisher provenance across upgrades | P0 | M | Deployed016/c646 | DONE — e47-r2 deployed27Oct03:47UTC; actual retained v26 receipt and full predecessor accepted read-only; 95 packaged checks passed; current generation provenance exposed separate019 before Git started |
| [019](019-preserve-generation-origin-and-close-exact-rejection.md) | Preserve the complete publication chain across releases | P0 | M | Deployed018/e47-r2 | IN PROGRESS — frozen216eadb SOURCE_ACCEPT_ONLY; new inactive artifact passes actual current whole chain, exact closed authority and retained physical history read-only; packaged/stronger composed gates pending; live3930 unchanged |

Plan 006 was added on 2026-10-04 at HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`.
Its checksum manifest also pins selected dirty/untracked source: HEAD alone is insufficient.
It carries forward the Desktop-owned-parent decision from the external historical plan
`/Users/cgable/Repos/symphony/plans/005-desktop-owned-ticket-chat.md`; the new handoff
is self-contained and does not require that external path to exist for execution.
No original Slice 3/4/5 completion or deployment is claimed by this index update.

Source rollback checkpoint: `bc7c28c5f7d79f37cfaf0d2c3ea873f758147863`
on `cgable/factory-control-plane`. This commit preserves the current Symphony
repository implementation. It does not back up the live SQLite ledger, runtime
settings, Codex chat history, or canonical skills outside this repository.

## Dependency notes

- Historical Plan 001 characterized the protocol and built the disabled foundation.
  Runtime permissions, worker readback and restart acceptance must pass before
  admitting work or enabling the new route. This avoids requiring a complete
  system before building the primitives needed to test it.
- Do not dispatch historical Plan 002 again for rejected Plan 001. Its committed
  event-correlation foundation is reused by 006; its tests cannot satisfy native acceptance.
- Plan 006 was the original ordinary-ticket handoff; later plans retain and harden
  that foundation. The ordinary path proceeds through U6N and
  U7–U11; the Required: yes manual-validation executor remains a separate U1/U3–U6
  gated follow-on. Each implementation unit is independently reviewed; production
  routing stays disabled pending its own acceptance and deployment authorization.
- The older `elixir/docs/factory-hardening-plan.md` remains the record of completed
  reliability work and unfinished native-cleanup acceptance. Plan 001 proposes a
  different execution boundary; it neither marks native cleanup complete nor
  enables archive/restore.
- Existing tickets and unresolved Desktop requests keep their recorded transport.
  Do not migrate them as a side effect of implementing this plan.

## Findings considered and rejected

- Use the parent chat's recollection as the workflow state: rejected; SQLite owns
  authorization, candidate identity, reservations, and delivery transitions.
- Rename every role chat to the same title: rejected; this keeps the same creation,
  workspace, permission, and recovery boundaries underneath.
- Switch the parent to the verifier model and ask it to review: rejected; a fresh
  independent worker must produce the verdict.
- Use `thread/fork` with `excludeTurns: true` as blind review: rejected; the local
  schema describes response hydration, not removal of inherited model context.
- Assume a custom read-only agent setting overrides every parent permission mode:
  rejected; effective runtime enforcement needs an actual proof.
- Add a new supervisor-owned delivery state machine or an idle model heartbeat:
  rejected; retain the existing scheduler and wake only for actionable events.
- Delete stage checkouts or archive chats to demonstrate savings: rejected; this
  plan allocates fewer checkouts for new runs, without destructive migration.
