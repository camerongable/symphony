# Plan 015: Admit product Go workflow source without policy authority

## Status and baseline

P0 correctness follow-up. Planned at `16ed7bf83bdd8f93f1ca29bb95d2a6b821457f6c`, 2026-10-26. User authorized local integration/deployment only. Dependency 013 is deployed, report readiness accepted; no new product candidate exists. Worktree `/private/tmp/symphony-review-contract.gTnJeO/workflow-path-source`, branch `cgable/product-workflow-path-v1`; sole source writer is the executor. Parent owns integration, index, rollout, and live operations. Preserve other agents' work.

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
- Public ordinary-generation regressions reuse the existing composed native fixture with one destination-path parameter. They exercise product `workflow.go` through actual confined formatting/generation, Store reopen, controller commit, physical history, and publication; the paired config-path case checks refusal before observation, journal/file writes, or adoption. These runs are in progress at candidate freeze; no pass is claimed yet.
- Physical inspection: `validate_archived_ci_authority` returns from its ordinary branch before legacy `scope_extension`; `ordinary_generation` validates generation bindings without the workflow-policy blacklist. No immutable helper bytes changed.

Remaining gates and final results will be appended after detached review and test completion. No live operation, repair rerun, push, merge, worker message, or service restart was performed.
