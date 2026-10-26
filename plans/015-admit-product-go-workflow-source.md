# Plan 015: Admit product Go workflow source without policy authority

## Status and baseline

P0 correctness follow-up. Planned at `16ed7bf83bdd8f93f1ca29bb95d2a6b821457f6c`, 2026-10-26. User authorized local integration/deployment only. Dependency 013 is deployed, report readiness accepted; no new product candidate exists. Worktree `/private/tmp/symphony-review-contract.gTnJeO/workflow-path-source`, branch `cgable/product-workflow-path-v1`; sole source writer is the executor. Parent owns integration, index, rollout, and live operations. Preserve other agents' work.

Execution status: **STOPPED** at the immutable ordinary publication-history gate. Source classification and real ordinary generation/restart/controller-commit behavior are proven; publication is not proven. No historical helper was edited.

## Why this matters

The stopped COMPLETE PPL-9881 repair cannot enter ordinary controller generation: `controller_generation_scope_unproven`. `TicketCiRepair.source_path?` rejects the legitimate `go/src/grail.com/workflows/docextract/workflow.go` while accepting sibling `contracts.go` and `activities.go`. Existing prefix exemption removes the protected `workflows` directory, but `policy_file?` still matches the basename against the broad `/workflow` substring. Correct this classification; do not rerun the repair or reinterpret its report.

## Current state

Read `elixir/AGENTS.md`, shared applicable rules, and these files before editing:

- `elixir/lib/symphony_elixir/factory/ticket_ci_repair.ex:659-679`: relative path/control-character/segment checks, exact Grail prefix exception, policy filename/lock/substrings guard.
- `elixir/lib/symphony_elixir/factory/ticket_ci_generation.ex` and its direct controller caller: inspect where `source_path?` produces `controller_generation_scope_unproven` before writing the public regression.
- `elixir/test/symphony_elixir/factory_ticket_ci_repair_test.exs:280-325`: public `assess/3` exact changed-path and protected policy tests.
- `elixir/test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5310-5460,7710-7750`: ordinary Go generation, native repair, restart, physical history and publication fixture. `test/support/ci_repair_worker_server.ex` owns the external native fixture. Use a small parameter if necessary; do not refactor the whole harness.
- `elixir/priv/ticket_push_history_validator_v22.py:948-967`: similarly named legacy `scope_extension` validates explicitly authorized two-Go-file out-of-MR CI extensions, not ordinary verifier-repair generation. Trace callers to prove it is not a gate for this current path. Do not rewrite immutable helpers or expand legacy extension authority incidentally.

## Scope

In scope: `ticket_ci_repair.ex`; its focused test file; one ordinary generation/controller public regression in lifecycle or ordinary generation tests; minimal fixture parameter in `test/support/ci_repair_worker_server.ex` if needed; this plan's results. Parent maintains plans/README.md. No other source edits without stop/report.

Out of scope: Grail source, live ledger/history, worker output, budgets, scheduler policy, MR/push commands, authorization freshness, existing immutable priv bytes, new automated retries, broad policy redesign, plan014. This fix grants path classification only, never filesystem or push authority.

## Required behavior

1. Exact product prefix `go/src/grail.com/workflows/` plus `.go` suffix permits workflow-named Go product source (including workflow.go and workflow_test.go), subject to ALL existing path safety and protected segment/filename checks. Do not allow another prefix or non-Go workflow policy through this exception.
2. Preserve `/policy` and `/config/` denials, actual protected directories even nested within the prefix, policy basenames and locks, traversal/absolute/control/backslash invalidity. Preserve non-product `/workflow` rejection. Match existing case sensitivity for the trusted prefix; uppercase alias must not expand it.
3. Public `assess/3` returns legitimate source paths and excludes policy paths. Ordinary controller generation must admit the product workflow.go path, perform its normal owned formatting/generation, persist evidence across Store reopen, and reach the existing success boundary. Assert exact path is in generation intent/evidence, not only a private predicate. Retain paired policy negative proving it stops before generation observation/execution/writes or adoption; earlier read-only Git lineage inspection is expected. No real GitLab/network or model work.
4. Actual six-path stopped repair vector must all pass source classification; changed paths/source/output remain unmodified. Existing verifier/report acceptance stays unchanged.

## Git workflow and steps

Verify clean branch and drift against full actual 16ed HEAD before edits. Use named staging, local `git commit --no-verify`; never push, merge, restart service, message workers, or mutate live state. Follow comment discipline, public specs, existing patterns. Read develop-test-first skill completely and implement vertical RED/GREEN.

1. Add focused public source/policy regression; show RED caused by workflow.go rejection, not missing tools. Include exact prefix, nested protected paths, mixed case, prefix lookalikes, non-Go workflow config, invalid paths and suffix traps. Avoid exhaustive unrelated fuzz framework.
2. Apply smallest production fix that preserves checks above. Public tests GREEN.
3. Add/run one real Store/controller ordinary Go generation regression for product workflow.go and the paired protected-path denial. Reuse existing fixture; stop if it requires broad fixture redesign. Restart/reopen evidence must remain valid. Inspect whether any physical helper independently gates this ordinary path; if yes, STOP with exact evidence rather than editing historical helper bytes.
4. Run affected suites, specs, formatting, full quality gate. Baseline has known lint failures (16ed inherited 654 findings vs C66 649); report exact new-vs-baseline limitations, no unrelated cleanup. Compile/test only in disposable worktree with copied ignored deps/build caches or isolated paths, never installed artifacts/dirty user checkouts. Record commands/results, local commit and full scope.

## Commands and done criteria

From elixir, with mise environment available:

- `mix test test/symphony_elixir/factory_ticket_ci_repair_test.exs test/symphony_elixir/factory_ticket_ci_generation_test.exs` => zero failures.
- `mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:<new-regression-line>` => zero failures; also selected existing ordinary Go restart/publication test at baseline5318, adjusted for insertion. If a smaller public ordinary-generation fixture proves the whole gate without publication, document why and retain one existing composed publication test.
- `mix specs.check` and `mix format --check-formatted` scoped changed files => exit0.
- `make all` => run/report actual result, coverage/dialyzer only if actually reached. Do not claim full gate green from targeted tests.
- `git diff --name-only <actual16edHEAD>..HEAD` within scope, and all `elixir/priv` files byte-identical to baseline.

## STOP and maintenance

STOP for overlapping source writer, drift in scoped production file, less than20GB capacity, active live worker, required scope broadening, immutable helper semantic mismatch on the ordinary path, or inability to reproduce public guard failure. Report facts without unsafe live recovery. This classifier is shared with CI diagnosis; future policy exceptions require both public source classification and controller generation negative coverage, not a blanket basename allowlist.

## Execution evidence

Candidate prepared in the named disposable worktree at the exact baseline. The only pre-existing change was this supplied plan. Installed dependencies and the dev build were copied from the immutable 16ed source snapshot/release into this worktree; no installed artifacts were compiled or modified.

- RED: `ERL_FLAGS='+S 4:4' mise exec -- mix test test/symphony_elixir/factory_ticket_ci_repair_test.exs:309` ran one public assessment test and failed because `workflow.go` and `workflow_test.go` were absent from the returned source paths.
- GREEN: the same assessment test selected at line298 passed (1 test, 0 failures), including all six stopped-repair source paths and protected/invalid path cases.
- Source classification now exempts only the exact product prefix with a `.go` suffix, removes only that trusted prefix's protected segment, and retains policy filenames, locks, nested protected segments, and `/policy` and `/config/` denial.
- Public ordinary-generation regressions reuse the existing composed native fixture with one destination-path parameter. The product `workflow.go` path passed actual confined formatting/generation, Store reopen, replay without re-execution, and exact controller commit/adoption to `CI_PUSHING`. The paired nested config-path negative passed refusal before generation observation, journal/file writes, or adoption, including unchanged source bytes and observation spool.
- Physical inspection: `validate_archived_ci_authority` returns from its ordinary branch before legacy `scope_extension`; `ordinary_generation` validates generation bindings without the workflow-policy blacklist. No immutable helper bytes changed.

### Final validation and stop evidence

- The first two new lifecycle runs failed before generation because the existing fixture uses strict boolean `and` on missing capability/operator tags. Only the new cases received explicit `false` tags. The initially selected existing operator case was interrupted through its owned test handle; it is not reported as a failure or pass.
- Bounded corrected command: `ERL_FLAGS='+S 4:4' mise exec -- mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5377 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5395 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:5420` => 3 tests, 2 failures, 730.0 seconds. The protected-path negative passed. Product-path and existing capability-recovery cases both passed generation/restart/exact commit, then failed the same immutable publication gate.
- Exact stop: existing `assert_ordinary_physical_negatives/4` calls `validate_archived_ci_authority` in `elixir/priv/ticket_push_history_validator_v22.py`; its ordinary-branch history map at line503 ends with executor v28 although the preceding allowlist includes v29/v30. The product case raised `KeyError: 'ticket_push_executor_v29.py'`; the existing capability case raised `KeyError: 'ticket_push_executor_v30.py'`. See `/private/tmp/symphony-review-contract.gTnJeO/workflow-path-fixed-lifecycle.log`. Parent owns any separately authorized versioned-helper follow-up.
- After the bounded run terminated, only two approved lint cleanups were made: extract the exact product-prefix/Go predicate privately, and wrap the protected-case dispatch. Final focused repair/generation suites passed again: 23 tests, 0 failures. `mix specs.check` passed; changed-file `mix format --check-formatted` passed. The full composed cases were not blindly rerun after this behavior-preserving extraction; their result applies to the prior identical classifier behavior.
- `ERL_FLAGS='+S 4:4' mise exec -- make all` fetched existing dependencies, built the local escript, passed full formatting/spec checks, then exited2 at Credo with659 findings. Coverage and Dialyzer were not reached. The independently measured exact16ed baseline is657, not the earlier654 note; the two new findings were the complexity and long-line issues cleaned up above. Final Credo comparison is recorded below.
- Final `ERL_FLAGS='+S 4:4' mise exec -- mix credo --strict --format json` exited14 with657 findings. Its multiset of filename/check/scope/message/trigger exactly matches the detached16ed baseline: zero added or removed findings. Evidence: `workflow-path-credo-final.json` and `workflow-baseline-credo.json` in the parent temporary evidence directory.
- Scope audit: only the classifier, focused assessment test, lifecycle regression, minimal fixture parameter, and this plan changed. All `elixir/priv` bytes remain identical to16ed. All builds/tests ran against disposable copies; no installed files, live ledger, worker output, source candidate, service, or external system was mutated.

Local candidate commits: `c3b071bbe4dca5059d432bfb0a1b3b20d9d6f0c8` (classifier/tests/plan) and `ab89419552576b04610ae59a60a0b221929763a1` (explicit new-test flags), followed by the final lint/results commit. Independent detached static review accepted the initial classifier candidate; parent controls final review and integration. No push or merge was performed.
