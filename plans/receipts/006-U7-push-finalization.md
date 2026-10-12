# Exact push finalization and bounded remote readback

2026-10-05. Local implementation at base HEAD
`52a978818875c59ccf2758ed1b728bb23e33f631`; production V1 remains disabled.

`TicketPush.step` reconciles only the original helper/receipt after issuance.
It validates the destination and exact remote branch SHA, then atomically writes
the completion receipt, releases the exact MAINTENANCE reservation, and moves
PUSHING to MR_CREATING (or CI_PUSHING to candidate-pinned CI_MR_CREATING).
A failed release rolls back all three effects. Reopening the Store reconciles
that original operation without another push. Premature completion fields are
rejected instead of normalized.

The release boundary independently validates the current run, candidate,
contract/revision, branch and checkout, digest-derived reservation key,
execution binding and invocation, then reads the original filesystem receipt.
Cross-run binding and substituted execution fields keep ownership reserved.

Origin identity, branch validation, and remote SHA reads now use fixed Git,
controlled environment, disabled prompts, bounded transport, and owned-group
cleanup before the first reap. Signals are masked through wait/ownership clear.
Darwin zombie-only group EPERM does not bypass the bounded terminal wait.
This assumes same-user, non-elevating, non-detached transports.

Focused verification: `mise exec -- mix test
test/symphony_elixir/factory_controller_git_read_test.exs
test/symphony_elixir/factory_worktree_test.exs
test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:429` passed
28 tests, 0 failures, 21 location-excluded tests (seed 771860, 46.5 seconds).
Tests cover ambient PATH substitution through actual Worktree readback, rejected
mutations/wildcards, bounded slow transport, redirected descendants after Git
exit, exact local bare-remote push, injected transaction failure, original receipt
readback after ledger restart, and binding substitution.

Strict Credo, public specs, formatting and whitespace checks pass. Independent
read-only push-finalization review accepted the repaired scope. Scheduler
PUSHING and CI_PUSHING wiring is implemented and its first-push join accepted by
independent inspection. Normal ticks now advance the local fixture from initial
checkout through planner/writer/verifier to the exact push and MR_CREATING,
without an extra worker or a duplicate push on the subsequent deferred MR tick.

The adjacent push-helper group-cleanup concern was repaired: Darwin kqueue
observes Git exit without reaping, then the helper kills the owned group and
reaps/clears ownership under masked signals before publishing its receipt.
Independent inspection accepted the same-user, non-elevating, non-detached
transport boundary. A runtime API mismatch (`kqueue` is not itself a context
manager) failed the focused checks; `contextlib.closing` repaired it.

Final push-boundary check passed 4 tests, 0 failures, 19 location exclusions
(seed 802889, 85.4 seconds): normal-tick exact push, original receipt recovery
and injected transaction failure, SIGTERM, and redirected SSH descendants with
Git exit 128. Tests preserve uncertain ownership on failed remote push and do
not equate a failed Git status with a timeout.

Separate-VM push crash acceptance passed its three stated checkpoints; see
`006-U7-push-vm-recovery.md`. MR/CI/Jira joins and the combined ordinary
lifecycle acceptance suite remain unfinished. CI repair/new-candidate admission
also needs completed-intent rollover with retained historical receipt; the first
push join does not yet cover that lifecycle. No production branch, connector, paid native model turn,
deployment, commit, or push was used; test pushes use disposable local remotes.
