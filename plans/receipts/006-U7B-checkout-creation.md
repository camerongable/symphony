# Initial checkout creation and receipt-only recovery

2026-10-05. Local Slice 3 integration; production V1 routing remains disabled.

`TicketCheckoutIO` runs one fixed controller helper, with the helper PID and exact
execution binding committed before sending execution input. The helper checks
the immutable intent, authorization age, ordinary-validation flag, parent and
bootstrap, repository/root identities and source ownership. Under SQLite's
issuance transaction it publishes an exclusive nonce claim and starts one fixed
Git worktree-add command. No fetch, reset, replacement branch, model or worker
task is part of checkout creation.

Git is confined to its fixed executable, the common Git directory and writer
parent. Hooks, fsmonitor, lazy fetch, replacement objects, network and filter
executables are not allowed. Parent creation uses nofollow directory descriptors.
The helper bounds output/time and publishes a terminal waitpid receipt before
reply. A source/contract change after committed spawn cannot revoke an already
issued Git operation, but it prevents finalization and source admission.

Recovery reads the original exclusive claim and terminal receipt only. Missing
or malformed evidence retains the ownership and capacity fence. It never uses
PID absence to infer success, nor invokes another creation. Successful Git is
insufficient on its own: physical checkout identity, clean/untracked state,
branch/SHA, current ordinary contract, parent, fresh authority, capacity and
foreign activity/ownership are checked before the atomic READY + PLANNING binding.
Pending intent fences apply to SOURCE, REVIEW and maintenance reservations;
only its own finalization admission is exempt.

Verification: **45 focused tests, zero failures** covering checkout, capacity,
workspace access, ledger migration and ticket CLI. Includes an actual isolated
BEAM killed with SIGKILL after the helper's durable receipt; reopened-ledger
recovery retains the original nonce/PID and admits no duplicate Git operation.
Foreign SOURCE/REVIEW acquisition is rejected; injected active tasks/reservations
block adoption until released. Git failure, dirty files, missing receipts,
expired authorization, insufficient capacity and changed manual-validation or
bootstrap bindings remain fenced. Independent frozen review found the foreign
ownership gap, verified its fix, and reported no remaining reproducible safety
bug. Specs, strict Credo and whitespace checks pass.

The explicit scheduler step now creates only for an unclaimed initial intent,
otherwise reconciles; after admission it returns PLANNING without launching the
planner in that call. Recovery uses the intent's pinned base rather than changed
caller input. Ordinary registration and polling are not enabled by this change.
Caller verification: lifecycle group **15 tests, zero failures**. Independent
caller review identified missing context-default propagation across later stages;
shared step normalization fixes it. The revised omitted-root/capacity-options
case passed a fresh **1 test, zero failures**, traversing checkout, planner,
writer admission and the first source slice at the same path. Independent
rereview confirms the caller finding addressed and identifies no new concrete bug.

Still required for Slice 3: complete production registration/tick routing and
runtime capability gates, native parent context-read acceptance, combined quality
gate/coverage acceptance and canonical broker-skill approval/install. A completed
checkout component is not proof that the whole slice is accepted or live.
