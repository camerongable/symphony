# Plan 006 U7a packet — isolate disabled ticket-supervisor rows

## Goal

Let a scheduler tick continue serving unrelated LEGACY work when the database
contains a recognized `TICKET_SUPERVISOR_V1` row, while treating every V1 ticket
and its factory-owned work state as inert until the complete new route is integrated.
This does not enable V1, create a parent chat, or start any workers.

The safest definition of “inert” for this packet is: no changes to the V1 run,
factory tasks, desktop requests, lifecycle events, feedback receipts, cleanup
authorization/worktree, rearm state, or validation children. Refreshing the
scope-level intake observation cache from the current read-only Jira search is
allowed; it is not execution evidence or a run mutation. Never write Jira for a
quarantined issue. Exclusively V1 proven-unissued feedback/controller requests and
separate ticket-parent requests do not block LEGACY Controller work; uncertain,
possibly-issued or mixed-owner requests on the shared Controller thread still do.

## Frozen base and exact ownership

- Checkout: `/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`
- Branch: `cgable/desktop-owned-ticket-chat-v1`
- Base HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`
- Sole writer: main-thread Sol after the user-requested model switch. The prior
  Luna writer is stopped; its partial repair was handed off and reverified.
- Allowed source files: `scheduler.ex`, `desktop_request.ex`,
  `native_workspace_maintenance.ex`, `mr_feedback_ledger.ex`,
  `mr_feedback_consumer.ex`, `mr_feedback_poller.ex`, `mr_feedback_rework.ex`,
  and `cleanup.ex` under `elixir/lib/symphony_elixir/factory/`.
- Allowed tests: `factory_scheduler_test.exs`, `factory_mr_feedback_test.exs`,
  `factory_mr_feedback_poll_test.exs`, `factory_mr_feedback_consumer_test.exs`,
  `factory_mr_feedback_rework_test.exs`, `factory_cleanup_test.exs`,
  `factory_desktop_request_test.exs`, and
  `factory_native_workspace_maintenance_test.exs` under
  `elixir/test/symphony_elixir/`.
- No schema/config change, controller/broker issuance, task launcher, worker,
  GitLab/Jira mutation, capability fence removal, route enablement, commit,
  push, deploy, or unrelated refactor.
- Preserve all other dirty and untracked user work. No second writer.

Pre-edit SHA-256 (each must match immediately before editing):

| File | SHA-256 |
| --- | --- |
| `elixir/lib/symphony_elixir/factory/scheduler.ex` | `209a7e0803359f87ff1502ec2f6b9e4736ce05ec6565f8c0f3cd7e8c8bfc774d` |
| `elixir/lib/symphony_elixir/factory/mr_feedback_ledger.ex` | `6582fb393245453474349b5ac0ebc29d10c75c3baaab915fc48e6565221171fd` |
| `elixir/lib/symphony_elixir/factory/mr_feedback_poller.ex` | `2f0c48840de80a3b26a5a18dfa84057bf0d6c93b61b4d45f9aa47b7ed0f51e5f` |
| `elixir/lib/symphony_elixir/factory/mr_feedback_rework.ex` | `f169d20578d2d0219ce2c483bdc2124ddde5f09918e00c47fef34490cb122f50` |
| `elixir/lib/symphony_elixir/factory/cleanup.ex` | `ec6e257f1be3fb2ece55e33a42522854355aa446b48c2e82e11861db2338bd0c` |
| `elixir/lib/symphony_elixir/factory/desktop_request.ex` | `2834296480f5d3ba45e8ed0f21b74051ef5d3722c83e131f6a0f65aa0a1195eb` |
| `elixir/lib/symphony_elixir/factory/native_workspace_maintenance.ex` | `f5cb1d498356d8eb46700189d20c61e78e3f649adde774659fe4dd08cc0bb41e` |
| `elixir/lib/symphony_elixir/factory/mr_feedback_consumer.ex` | `60f026eb2cdb3cc122f64b383b3ae1feb9d42f54d41b94a0aa0ee673851d3b5f` |
| `elixir/test/symphony_elixir/factory_scheduler_test.exs` | `5adde8a8bf442a27f3e6959b771bc126865db85d0a3bf48b94ae68d641414077` |
| `elixir/test/symphony_elixir/factory_mr_feedback_test.exs` | `36e038ed6acae8592da5e397eafd12be43d3ae2241af71f804602c07cbf0ee75` |
| `elixir/test/symphony_elixir/factory_mr_feedback_poll_test.exs` | `d3477cf2b089c8806bf15af0fd7a52fbc7e559a6c31efe0ef978ded6dca9f8c6` |
| `elixir/test/symphony_elixir/factory_mr_feedback_consumer_test.exs` | `5187c6b49e3772cac899c0788c35cce64e13462c9b4b5c7768b66ba6dc1223f0` |
| `elixir/test/symphony_elixir/factory_mr_feedback_rework_test.exs` | `980fa5699ff403931a625da36dc5fc23c793a599ebc6fc204ad9acc33feb774a` |
| `elixir/test/symphony_elixir/factory_cleanup_test.exs` | `21a1da56c11d095f653a26fed94c42f8bd81bae4ed7d95e70a30dbeb462edba5` |
| `elixir/test/symphony_elixir/factory_desktop_request_test.exs` | `48f335cadd15636ebc37bbaa270dec92cd2b71d5519143f48792fed6366b797d` |
| `elixir/test/symphony_elixir/factory_native_workspace_maintenance_test.exs` | `a92490309b920bc62214f446c3c3a7dd07a09b2e9b38e8ea1613d4f12476503e` |

## Required behavior

1. Keep unknown non-null execution modes fail-closed. Historical `NULL` remains
   LEGACY, as it does today. A recognized V1 row no longer aborts the complete
   scheduler tick solely because its runtime is not integrated.
2. Skip V1 runs before any run advancement, snapshot reconciliation/rearm,
   contract-discussion registration, validation-child registration, cleanup
   candidate authorization, verifier-create recovery, stale-task termination,
   native request result reconciliation, or workspace-maintenance admission and
   record reconciliation. Quarantine every run for the issue before selecting an
   older LEGACY run; do not rearm an old LEGACY run for an issue now owned by V1.
   Legacy rows retain their exact prior transitions.
3. A V1 run's feedback is never polled, claimed, consumed, dismissed, superseded,
   or reworked. Filter the batch selector and guard feedback mutation entrypoints
   (`record_candidate`, `dismiss`, finish/reconcile/requeue operations and rework
   completion/quarantine) against the stored run mode; a LEGACY MR observation must
   not supersede a V1 receipt with the same discussion/note identity. Preserve
   same-mode duplicate and in-flight protections for LEGACY records.
4. An exclusively V1, proven-unissued `PENDING` feedback/controller request with no
   thread/turn observation must not block LEGACY work, and must be unclaimable by
   the broker so that the state cannot race into an active turn. Keep the
   shared-controller busy fence for `CREATE_UNCERTAIN`, `FOLLOWUP_UNCERTAIN`,
   `THREAD_RECORDED`, `RECONCILE_REQUIRED`, any request with observed thread/turn
   evidence, mixed V1/LEGACY ownership, and any unresolved request whose run
   ownership is ambiguous: the same Controller thread may already have an active
   turn. Never classify uncertainty as unissued merely to let another issue proceed.
   A separate `TICKET_CHAT` request targets the ticket parent, not the shared
   Controller thread, and must not by itself block LEGACY Controller work.
5. Preserve V1 rows with no fallback: do not change their mode/state, fabricate a
   legacy run for their issue, or relabel/clear their Jira labels. Do not create a
   ticket chat or start a model turn.
6. The existing all-effects fence remains for unknown modes. The scheduler setting
   and issuance/runtime denial for enabled supervisor remain unchanged.

## Tests and verification

Replace/split the broad global V1-fence test rather than deleting its safety
assertions. Cover:

- V1 active runs before and after a LEGACY run in creation order; one unrelated
  LEGACY item advances while V1 run/task/request/events/evidence stay byte-for-byte
  unchanged.
- V1 snapshots changed in Jira do not update/rearm the run, start contract
  discussion/validation, mutate Jira labels, or trigger V1 writer/reviewer launches.
- Stale V1 tasks are not killed or marked stale. Rejected verifier creates are not
  retried for V1. Terminal FAILED/CANCELLED V1 runs are not rearmed or cleaned.
- Unissued V1 feedback is not consumed; unissued `PENDING` work does not block an
  unrelated LEGACY feedback batch and cannot be broker-claimed. Ambiguous,
  possibly-issued, mixed-owner, or unproven V1 controller requests still hold the
  shared-thread fence; separately routed ticket-parent requests do not. Poll, claim,
  rework and cleanup selectors never return V1 data. A direct attempt to
  claim/admit/mutate V1 feedback is rejected without receipt/run mutation, including
  a same-note identity collision across LEGACY and V1.
- V1 native success/readback requests and existing workspace-maintenance lifecycle
  records are not reconciled or advanced; no V1 maintenance request is enqueued.
- A proven-unissued V1 controller request cannot be claimed by Desktop. A
  `FOLLOWUP_UNCERTAIN` V1 request continues to hold the shared-controller busy
  fence, while a `TICKET_CHAT` parent request does not.
- Mixed historical rows for the same Jira key do not revive the older LEGACY run.
  Historical `NULL` execution mode still follows LEGACY behavior; unknown string
  modes remain fail-closed.
- V1 rows retain their existing writer-capacity reservation; the unrelated LEGACY
  progress test must provision enough capacity rather than treating quarantine as
  freeing a writer slot.
- The `TICKET_SUPERVISOR_V1` route stays disabled; unknown mode still halts before
  all existing scheduler side effects.
- Existing feedback batching/replay, legacy cleanup, and legacy rearm tests continue
  to pass unchanged.

Run focused tests for the eight named test files, then `mise exec -- mix specs.check`,
`mise exec -- mix format --check-formatted`, strict Credo on changed modules, and
`git diff --check`. Report each command and result. Do not run the full suite.

## Review and handoff

After implementation, freeze changed-file hashes and provide the test transcript.
An independent GPT-6.1 Sol/high reviewer checks the exact diff, especially every
mutation/selection path for V1-associated rows. Only ACCEPTED allows continuing to
U7b; FIX_REQUIRED/NEEDS_DECISION stops. Local acceptance is not a production
capability proof and does not authorize runtime enablement.
