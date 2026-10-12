# Ticket parent configuration wiring

2026-10-05. Scheduler dependencies now propagate explicit parent_output_root,
broker_thread_id, ticket_cli_root and ticket_workflow from ticket_supervisor
configuration. An absent workflow defaults to the loaded absolute workflow;
explicit null remains invalid. Context options then tick options override the
configuration. No parent root, broker identity or CLI root is guessed.

Verification: Scheduler and parent-admission suites passed 76 tests, zero
failures (seed 450204). Normal configuration-only tick proves exact reader
ledger, workflow, root and broker binding with no source launches. Explicit-null
workflow fails before run/chat creation. Whole strict Credo and specs checks
passed. Independent read-only review found no issues with precedence, binding,
legacy behavior or the preserved startup fence.

Production V1 remains disabled. Normal V1 advancement, actual runtime capability
acceptance and the combined lifecycle/final quality gates remain outstanding.
