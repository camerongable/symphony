# Receipt-only controller recovery primitive

2026-10-05. Existing Desktop requests can now be read by their original exact key
without enqueueing, waiting, calling native tools, reporting a thread, or updating
the shared controller turn.

DesktopStageRunner.read_request_result checks immutable payload integrity, exact
stored schema, stored plus caller-added tool requirements, terminal status and
receipt shape. It strips both thread callbacks. Pending/uncertain/failed requests
return immediately; malformed or NULL terminal output returns an error rather
than raising. ControllerTask.read_request_result additionally requires a
CONTROLLER/FOLLOWUP request in the configured scope and project, then returns
its output without recalculating model routing or overwriting a newer control
turn.

Focused runner/controller suites passed 21 tests, 0 failures (seed 471029,
7.8 seconds). Tests compare all request rows before and after readback, suppress
both callbacks, enforce extra caller requirements and reject attempts to drop
stored requirements, schema substitution, corrupt payload and malformed/NULL
output. The controller fixture advances to a later turn, reads the original
receipt, and proves both the later control row and queue remain unchanged;
wrong scope/project are rejected. Public specs pass. Independent read-only
review accepted the primitive and wrapper after the NULL-output repair.
After shortening test expressions without changing assertions, the final readback
regression passed 1/0 (seed 334406, 0.5 seconds); strict Credo and whitespace
checks are clean.

Frozen source SHA256:

- `desktop_stage_runner.ex`: `89faa5a6204dbece1558c9e0dfe2d2a39b800539b05bae5fc3b1e23c090dd080`
- `controller_task.ex`: `45cd866fb19479d11613bde066a7b94c2634b1e4df1e1915d7d76a2922042489`

This is a required recovery primitive, not the completed MR join. The caller must
still prove operation ownership, exact current run/candidate/contract, original
controller-thread/turn binding and remote MR authority. Native MR issuance is
not enabled by this API; production V1 remains disabled. Internal read-only
subagents reviewed source; no production Desktop turn, live connector operation,
commit, push, deployment or production-ledger mutation was dispatched.
