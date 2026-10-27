# Plan 017: Own composed generation fixture ticks

## Authority and baseline

Test-only validation follow-up to016, 2026-10-26. Planned against frozen `c64615d0a572d1af76a90df0519368a25b588ff6`. User approved implementation/testing/local integration and deployment toward PPL-9881 review; no live operation belongs to this executor. Executor remains sole writer in `/private/tmp/symphony-review-contract.gTnJeO/ordinary-history-source`. Parent owns index/integration/rollout. Read applicable rules and elixir/AGENTS. Do not edit any installed files, dirty user checkout, or historical helper.

## Finding and boundary

The current regularv31 and capabilityv32 composed cases both fully passed through synthetic READY_FOR_REVIEW; genuinev30 old receipts also passed new validator/archive/readback after two read-only reopens. The protected-path case failed earlier in unrelated fixture setup: Scheduler adoption at `complete_stage/2:1327-1331`, called from6477, entered generation with a manual tick expired349s before its effect fence. Exact captured and actual lease_expires_at were21:38:54, EXECUTION_STARTED21:44:43. Helper hash matched. This is an expired static fixture, not evidence that production TickLease renewal failed.

Read these exact seams before edits:

- `elixir/test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs` `complete_stage/2`1327, `generation_owner/3`6807, `release_generation_fixture_tick`, `push_tick_fixture_state`, `install_push_tick_fixture_state`, `resume_generation_fixture_tick`7384-7405, and existing real TickLease.run pattern7247-7265.
- `generation_owner` forces enabled:true/lease_seconds:240 and optionally changes selection, but returns old context.factory. Preserve its exact local factory under a generation-specific context field; never reconstruct from context.factory.
- `test/support/ci_repair_worker_server.ex:314-320` uses process-dictionary ci_repair_fixture_store. Existing push_tick_fixture_state also transfers project/parent reader identity. Do not invent global state copying.
- `lib/symphony_elixir/factory/tick_lease.ex` owns renewal and callback lifetime. Callback executes in another process; keep worker launch/wait and ExUnit service setup outside it.

## Scope and invariants

Only lifecycle test file and this plan's results may change. No production/library/priv/config/limit/schema changes. Parent owns README. Use a dedicated selected-case opt-in (for the new product, protected-path, and existing explicit capability scenario); do not change every case with generation_root. Preserve all original semantic expectations.

1. Propagate opt-in and exact local generation-owner factory into returned context. Existing unselected fixtures retain their behavior.
2. In complete_stage, leave finish_worker and generation_native_reader in original ExUnit process. For opted-in context with generation_control, release the current manual fixture tick, capture existing push_tick_fixture_state, and use real TickLease.run with that exact factory and context.generation_control to execute ONLY final Scheduler.ticket_step. Install existing state inside callback. Preserve context.recipient. Passing returned tick as operator_tick is allowed; do NOT set ordinary_controller_tick:true.
3. Assert exactly `{:ran, {:ok, %{status: "ADOPTED", run: run}}}`. After genuine successful callback release, use existing resume_generation_fixture_tick to acquire a fresh manual identity. Do not fake callback success or release, suppress renewal failure, add a detached heartbeat, raise TTLs, or refresh captured timestamps without real operations. No mailbox relay or arbitrary process-dictionary clone.
4. Add a small public fixture ownership regression using the existing lease-fixture pattern: prove old manual tick is released, real callback observes a new owned identity, and successful return leaves a different fresh manual tick. Exercise the adoption path through the selected protected case. If on_exit/start_supervised must move into callback or more process state is needed, STOP rather than broad harness redesign.

## Verification

First finish the already-running serialized legacyregular receipt probe; never start duplicate nodes or mutate its build/receipt. Preserve its actual result. Then commit/freeze this test-only change for detached review.

Run selected lease-fixture regression, protected case, and the selected product/capability cases with all guards intact. Prefer serialized nodes; retain original fake runtime/Git/SQLite effects only. All cases must reach their full assertions. No weakening of the protected negative's unchanged journal/spool/source/HEAD checks. Run specs and scoped formatting; compare Credo to baseline657/current653, zero introduced findings.

Production source/priv hashes must be byte-identical to acceptedc646. Existing c646 artifact remains a candidate for the same production implementation; final release evidence must distinguish test-only harness commits from production hashes. Local named-file commit --no-verify, no push/merge/deployment.

## STOP

Stop for any production expiry/identity guard relaxation, whole-lifecycle callback wrapping, extra global restart/timer, unverified factory reconstruction, live ledger access, active overlapping writer, or a fresh authorization expiring inside one real MR operation. MR fixtures already read fresh observations just before adopt_result; a reproducible single-call>60s expiry is a production latency issue, not permission to rewrite timestamps or expectations. Capture bounded call entry/exit timing and stop rather than mask it. Later MR freshness hardening is separate approved plan014.

## Execution results, 2026-10-26

Status: COMPLETE for the scoped test-only correction. No production or live-ticket readiness claim follows from these fixture results.

- Before editing, the already-running legacy regular probe finished with its expected immutablev22:503 KeyError (1 test/1 failure,312.8s), after genuine ordinaryv29 publication and synthetic READY_FOR_REVIEW. Its authentic retained receipt passed newv23 archive/full-predecessor/readback checks, two read-only SQLite reopens, and history path/hash negatives. Plan016 records the exact proof identifiers; no extra legacy probe was launched.
- Selected-case opt-in is limited to the product-path, protected-path, and existing explicit capability cases. `generation_owner` preserves its exact enabled/240-second local factory in the returned context. `complete_stage` retains worker launch/wait and native fixture setup in ExUnit; only final Scheduler adoption runs in a genuine renewing TickLease callback with the existing explicit process-state transfer and original recipient. The actual ADOPTED result is asserted before a fresh manual tick is acquired.
- The public ownership regression proves that an unrelated disabled context factory is not reconstructed as authority, the old manual identity is released, the callback runs in its separately owned process with the exact control identity, and return leaves a fresh manual identity different from both previous identities. No fabricated adoption result is supplied by the composed helper.
- Initial new+existing lease fixture checks passed2/0 in90.1s. The strengthened new identity regression passed1/0 in82.6s. After the narrow test-format cleanup, exact source/test code was frozen at `86f5080abad07e468948f1c754ac92b15cceda94` for independent detached review; the critic accepted its full two-file delta with no findings before final evidence edits.
- Frozen selected command: `RETAIN_ORDINARY_GENERATION_FIXTURE=1 ERL_FLAGS='+S 4:4' mise exec -- mix test --no-compile --seed 0 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5391 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5410 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5433 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:7447`. Result: **4 tests,0 failures (154 excluded),754.9s**. All full publication, restart, exact controller-commit, protected journal/spool/source/HEAD, and ownership assertions passed. Log: `/private/tmp/symphony-review-contract.gTnJeO/owned-generation-frozen-lifecycle.log`.
- Specs and scoped formatting passed. Frozen Credo JSON `/private/tmp/symphony-review-contract.gTnJeO/owned-generation-frozen-credo.json` contains653 findings, zero added/removed against c646's653, and zero added/four removed against16ed's657 when location offsets are excluded. Existing full-gate limitations remain documented in016; coverage/Dialyzer are not claimed.
- Production/library/priv bytes remain identical to independently acceptedc646. Only the lifecycle test and plans016/017 evidence changed after that implementation. No source16 helper rewrite, freshness/TTL relaxation, extra timer/global restart, model call, external write, push, merge, deployment, or live-ledger access occurred.
