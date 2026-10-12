# Separate-controller VM push recovery

2026-10-05. Production V1 stays disabled. This acceptance uses disposable local
repositories and the existing fixture VM killer, not production chats or paid
native turns.

The real TicketPush driver is stopped at three checkpoints: inside the issuance
callback before attaching execution; after successful attachment but before
returning input to the helper; and after independently validating the original
terminal receipt but before finalization. The fixture runner observes the actual
BEAM PID, sends SIGKILL, and reaps that BEAM. Its historical
`observed_terminal_helper` field means only a live-VM marker was observed in the
two pre-input cases; neither case claims Git was already running.

After reopening Store and obtaining fresh fixture authorization, both pre-input
cases retain the exact uncertain envelope and active reservation across repeated
reconciliation attempts. Neither starts a push. The receipt case transitions to
MR_CREATING using the original immutable binding, reservation key/generation,
nonce, helper PID, execution, receipt bytes and receipt hash, then releases its
reservation. Source, HEAD, task rows and worker evidence do not change.

The local receive-pack wrapper counts actual push transport invocations, including
up-to-date pushes, rather than only ref changes or receive hooks. Recovery records
exactly one invocation in the completed case and none in the two unissued cases.

Independent inspection found that the after-attachment marker could be emitted
without checking successful attachment. The driver now requires `{:ok, _}`, and
the tests explicitly require a positive PID and execution binding in both attached
cases. The VM runner also preserves HOME so bounded Git-origin reads have the
normal host-home context; its original PATH/LANG-only environment rejected origin
admission before reaching any checkpoint.

Focused command: `mise exec -- mix test
test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:713`.
Result: 3 tests, 0 failures, 23 location exclusions; seed 425533, 47.2 seconds.
Strict Credo, formatting, public specs and whitespace checks pass.

The existing checkout VM-crash test still passes with the shared runner update:
`mise exec -- mix test test/symphony_elixir/factory_ticket_checkout_test.exs:177`,
1 test, 0 failures, 15 location exclusions (seed 300189, 2.4 seconds).

Frozen SHA256 values:

- `priv/ticket_push_executor.py`: `455102866c2b0264aa1e894d1a665999b88dfdccab842b02f22ee5977c73d29e`
- `priv/controller_git_read.py`: `3e79c359af4ae36b89931400f36c8b8cd266dbeb6ae538215d40862e8edc7c70`
- `test/support/push_controller.exs`: `ee576c7f90deda6e2aa0b12df67916a5557a0c3cc902c1f824f399db96d13d88`
- `test/support/file_io_vm_crash.py`: `97704052aaa6986144659a73d1b15e6e78c38fef35f7aaf00619677891cb1625`

This proves lost-controller recovery at the stated boundaries, not VM death
during an active remote Git transfer, deliberate detached/elevated transports,
MR creation recovery, or full ordinary-route acceptance. Completed-intent rollover
for CI repair remains next, followed by MR/CI/Jira joins. Slice 3 and U7 are not
complete and no runtime enablement is authorized by this receipt.
