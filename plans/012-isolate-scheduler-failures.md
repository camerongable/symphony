# Plan 012: Isolate ticket intake failures and bind tick callback lifetime

## Status and authority

- Local implementation and targeted verification completed; parent-owned integration/deployment and final independent acceptance remain separate.
- Priority P1; effort M; risk MED; category correctness and lifecycle tests.
- Planned at `c66c33993735bbcfb80018296b4e247413749d61`, 2026-10-26.
- Depends on plan 011, deployed and independently qualified. PPL-9881 resumed through the ordinary controller and demonstrated tool activity on its newly bound SOURCE turn.
- The user approved this second workstream, followed by handoff recovery. Local integration/deployment is authorized; no external push or pull request is authorized.
- Executor owns `/private/tmp/symphony-review-contract.gTnJeO/scheduler-source`, branch `cgable/scheduler-isolation-v1`. Other agents and a real ticket writer exist: do not revert their changes or touch their worktrees.
- Parent maintains `plans/README.md`. Executor may update this plan's status but must not edit the index.

## Drift check and baseline

Run `git diff --stat c66c33993735bbcfb80018296b4e247413749d61..HEAD -- elixir/lib/symphony_elixir/factory/tick_lease.ex elixir/lib/symphony_elixir/factory/scheduler.ex elixir/lib/symphony_elixir/factory/intake_ledger.ex` before writing. It must initially be empty.

The actual deployed source is `/Users/cgable/Library/Application Support/ai-factory/source-snapshots/symphony-review-report-c66c339`, manifest `/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-c66c339/evidence/release-manifest.json`, SHA256 `cce0e5b38f355ff425bbfc9b6be2e4dcaf2b191e0ed0932b4f05288367d13e24`. Schema is 54. Do not bootstrap from either dirty development checkout. This new Git worktree already contains the correct committed baseline.

Read `elixir/AGENTS.md`, applicable `/Users/cgable/.agents/rules`, `develop-test-first` (including tests/mocking references), and relevant `design-codebase` guidance before implementation. Use actual OTP processes and a temporary SQLite Store. Mock only external Jira/runtime/provider boundaries, not internal Scheduler/Control collaborators.

## Why

An inadmissible new ticket currently can prevent unrelated active tickets from advancing. Separately, the function executing a leased tick is merely monitored by the process renewing its lease: killing that owner can leave the callback executing until after a replacement lease starts. Fix these two existing owners without a new scheduler, alignment job, durable authority journal, or background model wake.

## Current state and intent

- `tick_lease.ex:76-95` uses `spawn_monitor` to execute the callback, sends a returned/raised envelope to the caller, and renews only in that caller's receive loop. `run_controlled/3` releases the exact tick in its `after`. On renewal loss it kills the callback and drains its monitor, then returns `{:ran, {:error, {:tick_lease_lost, reason}}}`.
- `controller.ex:177-193` starts that renewing caller under Task.Supervisor; Controller monitors it. Controller restart alone need not kill a still-renewing supervised owner and must not be mistaken for the orphan-callback race.
- `scheduler.ex:1493-1505` requires `reconcile_intake` to succeed before legacy and ordinary active-run advancement. `reconcile_intake` halts its reducer on an error (`1908-1924`).
- `register_delivery` parses the authorized manual-validation declaration, validates its policy and selected ticket route, then prepares/registers admission (`2330-2409`). Missing declaration alone already becomes an exact-observation local denial; other errors fall through to `{:delivery_registration_failed, reason}`.
- `IntakeLedger.record_blocked/5` and `valid_decisions?/1` currently support only `manual_validation_contract_missing` (`intake_ledger.ex:83-111`). The record requires the exact saved observation and snapshot; preserve that binding and transaction behavior.
- Disabled/default manual capability is valid configuration: `Policy.validate/1` accepts it. A newly queued contract requiring it can be rejected locally without enabling anything. Existing active-validator tests already isolate this feature disablement to the affected run.
- Public observability projects validated intake decisions as `INTAKE_BLOCKED`; no dashboard redesign is required.

Existing examples: `factory_tick_lease_test.exs` uses real Store/ControlServer and renewal-loss tests; `factory_scheduler_test.exs:2501-2537` covers the existing missing-declaration exception and good new intake. It does not prove active-run progress under other local rejections. Tests at `2377-2382` currently expect unsupported V1 manual validation to fail the entire tick; change that expectation as an intentional behavioral fix, not by deleting coverage.

Public `def` functions in lib need adjacent `@spec`. Match existing result tuples and safety terminology. Comments explain invariants, not step narration. Never rewrite review/report protocol, historical receipts, budgets, or the deployed Python helpers in this workstream.

## Agreed test seams

The user's approved factory-flow acceptance suite includes mixed queues, restart and normal progression. Exercise these existing public boundaries:

1. `TickLease.run/3` with real OTP owner/callback processes and ControlServer, including abrupt parent death, actual lease expiry/replacement and durable uncertain operation state.
2. `Scheduler.tick/2` with mixed intake and an already-active ordinary ticket; observe RunLedger/IntakeLedger/Observability public results, not calls to a private classifier.
3. A real Controller `reconcile_now/1` path where useful for ownership and tick-health integration. Do not substitute direct `handle_info` calls or assert only that an internal method was invoked.

## Scope

In scope:
- `elixir/lib/symphony_elixir/factory/tick_lease.ex`
- `elixir/lib/symphony_elixir/factory/scheduler.ex`, only intake admission classification and direct local helper integration
- `elixir/lib/symphony_elixir/factory/intake_ledger.ex`
- `elixir/test/symphony_elixir/factory_tick_lease_test.exs`
- `elixir/test/symphony_elixir/factory_scheduler_test.exs`
- Narrow additions to `factory_controller_health_test.exs`, a dedicated scheduler-isolation test file, or test support only when needed for a real public seam; no broad harness refactor.
- Root `README.md`, `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, and this plan for changed behavior.

Out of scope: Controller scheduling policy, Control/ControlServer lease generations or expiry/release rules, schema/migrations, production configuration, source/ticket work, cleanup, transport/MR recovery, report schemas/correction/repair authority, new generic error frameworks, UI layout, live fault injection, SQL writes to the real ledger, manual ticks, native specialist messages/polling, services or automations.

## Steps: red, green, then independent checkpoint

### 1. Prove and fix the callback orphan

Write one failing public regression first: activate real temporary control, enter `TickLease.run` in a test-owned process, have its callback report its PID and wait on a barrier, kill the renewing owner, and require callback DOWN before sending the old barrier. No stable effect from the dead callback is permitted. Preserve the durable lease rather than clearing it to make replacement work.

Keep existing returned/raised envelopes, parent monitor-only behavior, exact release on handled errors and renewal loss. A naive link would make intentional callback `:kill` kill the caller before its normal loss/release path; do not do that and do not blanket-change the caller's `trap_exit` flag.

A grounded minimal option is a tiny idle owner-monitor guard spawned and linked inside the callback before arbitrary `fun`: capture caller/callback PIDs, install both monitors, consume an already-queued owner DOWN before arming, and acknowledge with a unique reference/PID before the callback proceeds. Owner DOWN of any reason kills the callback with `:kill`; callback DOWN ends the guard normally. The guard performs no DB/control/network work. Another equally small existing-OTP design is acceptable only if it preserves all those lifecycle/error semantics. It is not another durable lease owner.

Then prove actual lease expiry/replacement, a callback holding a real SQLite transaction, startup/arming owner-death boundary, ordinary callback completion, unexpected callback death, and the existing renewal-loss/raise/paused-recovery cases. Use barriers/monitors rather than arbitrary long sleeps. A small consistent lease may expire naturally in tests; do not rewrite its row.

An already-issued synthetic TicketJiraJournal claim must remain uncertain and unclaimable after owner death/reopen. Terminating a callback does not prove cancellation of an external effect. Only existing exact readback may reconcile it.

Seal one coherent commit and give the parent its SHA for early independent review before expanding the second slice.

### 2. Prove and fix ticket-local intake isolation

Start with literal valid default `factory.manual_validation = %{}`. Queue an authorized Required: yes newcomer plus an already-active Required: no ordinary V1 ticket with consumable synthetic evidence. Through `Scheduler.tick/2`, require a visible bounded denial for the newcomer, zero newcomer run/parent/request/workspace admission effects, and same-tick advancement of the existing ticket. Exercise both queue orders.

Add only an explicit bounded classification at the admission-producing owner. Preserve current ordering and fatal safety checks; do not catch all delivery-registration failures. Local reasons allowed in this slice:

- Existing `manual_validation_contract_missing`.
- `ambiguous_manual_validation_section`, `ambiguous_manual_validation_decision`, `ambiguous_manual_validation_environment`, `manual_validation_environment_missing`, `manual_validation_format_unsupported`.
- `ticket_manual_validation_not_supported` and `manual_validation_disabled` (capability mismatch for a newly admitted ticket, not feature activation).
- The admission-stage `{:manual_validation_environment_not_allowed, environment}` and `production_validation_forbidden` as fixed safe decision codes/messages, never interpolation of the untrusted environment string.

Keep `unsafe_manual_validation_policy`, `slack_coordination_required`, provider/queue/active-snapshot failure, invalid stored execution mode, incomplete route, broken broker/model/context-reader/output root, unsupported runtime, unknown/internal errors, ledger failures and `intake_observation_changed` fatal. Do not broaden manual-validation execution or authorize production/DDL. Keep existing active-run validation enforcement unchanged.

Extend IntakeLedger's bounded mapping/read validation without migrating or rewriting historical snapshots. A failed denial write must propagate, not masquerade as successful isolation. Observe the denial through `Observability.snapshot`. Corrected, freshly authorized content must become admissible on a later observation; no sticky rejection from the old snapshot.

Add public negative controls for global provider/runtime/configuration failure and real synthetic ledger-write failure. They must still fail the tick and retain FAILED tick-health behavior. Retain existing rollback, routing, capacity and no-admission-effects cases.

### 3. Freeze, verify, and hand off

Do not edit source or priv files under active tests whose identities are pinned. Stop the owned test process before a required repair; seal a new checkpoint and rerun the affected seam. Keep source changes narrow, no unrelated lint refactor.

Commands from `elixir/` using `/opt/homebrew/bin/mise exec --` and `ERL_FLAGS='+S 4:4'`:

- `mix test test/symphony_elixir/factory_tick_lease_test.exs`
- `mix test test/symphony_elixir/factory_scheduler_test.exs test/symphony_elixir/factory_controller_health_test.exs` (include a new dedicated file if created)
- `mix test test/symphony_elixir/factory_ticket_jira_journal_test.exs test/symphony_elixir/factory_ticket_jira_operation_test.exs test/symphony_elixir/factory_desktop_request_test.exs`
- `mix specs.check`; `mix format --check-formatted`; `make all`

Use only isolated ignored build/dependency directories. Warm dependencies exist at the deployed C66 source's `elixir/deps`; do not mutate that snapshot/build. No installs into user trees or network/model integration tests.

The deployed baseline already has 649 Credo findings (605 older plus 44 from plan 011); full coverage/dialyzer were not reached. Record new deltas relative to C66, exact command exits and limits. Never call the full gate green if lint stops it. All targeted functional tests and public specs/format checks must pass.

Git: named-file staging only, coherent commits with `git commit --no-verify`; no push/MR. Parent explicitly owns local integration and deployment. All 117 retained legacy priv files must stay unchanged.

## Done criteria

- Parent death stops blocked callback; replacement starts only after legitimate lease expiry with a distinct tick identity; prior issued uncertainty is preserved.
- Normal return, raised callback, unexpected callback termination, renewal failure, paused recovery, timeout and exact release behaviors remain correct.
- Each supported ticket-local denial is visible and has no admission effects; unrelated active and valid queued tickets progress through the public tick.
- Changed observation and global provider/config/runtime/ledger failures still reject; corrected exact-authorized content re-admits.
- Targeted tests, format and specs pass; full-gate limits are recorded honestly; diff scope is clean and complete docs are updated.
- Report final SHA, commands/counts/logs, baseline/new lint delta and any deviations. A test or source pass is not live deployment proof.

## STOP conditions

Stop and report before improvising if this needs another lease owner/journal, global exception swallowing, a parent trap-exit policy change, schema/config/repair-budget changes, clearing uncertain records or expired leases, active-worker interference, or out-of-scope source. An error not explicitly classified above stays fatal. After two unsuccessful fixes of the same ambiguous condition, report the evidence and seek a narrowed plan. No source worker may push, dispatch a ticket, restart the service or modify schedules.

## Maintenance

Callback lifetime and durable operation uncertainty solve different problems; keep both fences. New Contract errors need a deliberate local/global decision and safe message mapping, not a prefix match. This workstream does not recover completed native turns, republish broker responses, change error classification or refresh MR admission observations; those belong to the next approved workstream.

## Local execution evidence

Base: `70fa2a422b0b289618b4b84f6734d0de70ad5add`; early lease checkpoint:
`931872fd802d78247d14edb6cff9f4a29d655e49` (independent early critic accepted).
Logs are outside source at `/private/tmp/symphony-review-contract.gTnJeO/scheduler-evidence`.

- Lease regression: red 1/1 failure at missing callback DOWN after owner death; green 1/0. Final full lease suite: 26 tests, 0 failures, exit 0, including natural expiry/replacement, real transaction rollback, startup death, exact release, and issued uncertainty after reopen.
- Default-disabled mixed queues: red 2/2 failures at `manual_validation_disabled`; green 2/0 with real recorded worker evidence consumed and the active ordinary run advanced to VERIFYING in both orders. The eight additional denial mappings were red 8/8, then green 8/0.
- Final scheduler/controller-health/isolation group: 98 tests, 0 failures, exit 0. This includes actual Controller `reconcile_now` with synthetic local Jira/runtime transport for provider, runtime, queue and denial-write failures; each retains exact FAILED health. Changed observation and unsafe-policy/Slack errors remain fatal. Corrected authorized content re-admits.
- Journal/operation/Desktop-request regression group: 44 tests, 0 failures, exit 0.
- `mix specs.check`, `mix format --check-formatted`, and independent `mix build`: exit 0. A second formatting pass was needed for the lease test's anonymous-function arguments, then the lease suite was rerun. An existing runtime-trace assertion was narrowed from total line count to exactly one initialize and only initialize/initialized messages, retaining the exact one-probe assertion.
- `HEX_OFFLINE=1 make all`: exit 2 during setup, because the local Hex registry does not cache `file_system`; no network/cache/install workaround was attempted. Direct `mix lint` and JSON Credo: exit 14. Full coverage and dialyzer were NOT REACHED.
- Credo normalized filename/check/message multiset: C66 649, current 652, +3/-0 (two new isolation-test line-length findings and one scheduler-test alias-use finding). Exact comparison is `credo-delta.json`; no unrelated lint refactor was made.
- All product/priv source stayed frozen during the pinned test runs. `elixir/priv` has no diff from C66; no schema/configuration changes, external writes, service actions or other-worktree edits occurred. The source/test results are not deployment proof.
