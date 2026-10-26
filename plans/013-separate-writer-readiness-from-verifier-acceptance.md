# Plan 013: Separate writer readiness from verifier acceptance

## Status, authority, and baseline

- P0, effort M, risk MED; correctness follow-up to deployed plan 011. This interrupts workstream ordering only to unblock the exact returned PPL-9881 repair; plan 012 continues independently.
- Planned at `c66c33993735bbcfb80018296b4e247413749d61`, 2026-10-26. User authorized implementation, testing, local integration/deployment, and bounded ticket interventions. No external push/PR.
- Sole executor worktree `/private/tmp/symphony-review-contract.gTnJeO/writer-report-source`, branch `cgable/writer-report-handoff-v1`. Other writers exist; preserve their files. Parent owns index, integration, rollout, and live operations.
- Drift check: `git diff --stat c66c33993735bbcfb80018296b4e247413749d61..HEAD -- elixir/lib/symphony_elixir/factory/review_report.ex elixir/lib/symphony_elixir/factory/review_protocol.ex elixir/lib/symphony_elixir/factory/worktree.ex` must initially be empty.
- Installed C66 manifest `/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-c66c339/evidence/release-manifest.json`, SHA256 `cce0e5b38f355ff425bbfc9b6be2e4dcaf2b191e0ed0932b4f05288367d13e24`, schema54. Warm deps are in the corresponding source-snapshots directory. Never compile or edit the installed artifact or either dirty development checkout.

## Why and exact current failure

The real SOURCE worker stopped with COMPLETE and six changed source paths. It explicitly reports tests NOT_RUN and unchanged criteria as historical, not newly inspected. Adoption rejects `review_report_affected_paths_incomplete`; after that, the same raw report also fails empty unavailable-boundary paths and all-CHECKED verdict rules. No product commit or verification has occurred. Do not rerun the writer, modify its report/history, fabricate inspection evidence, or spend another repair.

Read-only live identity for a regression/qualification (not mutation): run `ab5ab1fe-32cc-48c1-985e-3c3800adcfa2`; request `desktop:11b288b43e59ae80afdfc26b01e1bcf2f2d297249cc54e8f0d0af98829629c5a`; candidate `4e5c48fc2150515c4cb5ce0771f4c204b10c532c`; exact stopped turn `01a1796f-4ffd-74e1-9bfe-9fdbf19e1e57`. Database `/Users/cgable/Documents/Codex/factory-state/factory.sqlite` is strictly read-only to executor.

## Current state, inspected by parent

- `review_report.ex:12`: row IDs are free text when controller IDs are empty. Writer admissions have no `affected_paths` key, but validation at 53-57 insists on an exactly empty list. The worker therefore supplied schema-valid descriptive check IDs that cannot pass adoption.
- `review_report.ex:58-63` requires nonempty paths even for honest UNAVAILABLE boundary rows. `verdict?/3` at 139-144 permits writer criteria NOT_CHECKED but requires every boundary CHECKED. This conflates a source-ready proposal with verifier acceptance.
- `review_protocol.ex:73-98` binds actual changed paths only for change-verifier; its writer instruction says COMPLETE is ready for controller checks and unrun tests must remain NOT_CHECKED. `validate_result/4` authenticates stored admission and carried origins before calling report validation.
- Actual writer FOCUSED scope contains all eleven criteria because older untyped finding bases are conservatively retained. Its unavailable rows AC-1/2/6/10/11 each have an authenticated prior PASS; remaining paths, including failed AC-9, are CHECKED with source evidence. Do not narrow or rewrite this admitted scope.
- `elixir/priv/ticket_push_history_validator_v21.py:1769-1811` independently mirrors the same rules. Current ordinary executors v27/v28 and status reader v15 pin it. `ticket_push_io.ex:144,459-462,538-539` owns physical helper/digest selection; Worktree is its public caller. All retained helpers are immutable; add successor versions instead of editing any existing priv bytes.
- Existing tests in `factory_review_protocol_test.exs:316` exercise writer NOT_CHECKED only through v1, hiding this v2 divergence. Real worker adoption/publication composition is in `factory_ticket_worker_runner_test.exs` and `factory_verifier_repair_test.exs`.

## Required semantics

Keep protocol2/admitted schema bytes and old v1 semantics unchanged; this corrects interpretation of schema-admissible writer evidence, not report projection or evidence replacement.

1. For feature-writer only, when `review_scope` has NO `affected_paths` key, `affected_path_checks` are supplemental descriptive source checks: unique nonblank IDs, nonempty textual evidence, schema-valid statuses. They are not controller-bound path coverage or verifier acceptance. COMPLETE still requires these supplied checks CHECKED. If paths ARE explicitly bound, retain exact coverage. Change-verifier exact bound coverage remains unchanged, including the empty-list case; never treat unknown verifier IDs as supplemental.
2. A FOCUSED feature-writer COMPLETE may honestly retain UNAVAILABLE boundary rows with empty paths ONLY when its same-ID criterion is NOT_CHECKED, evidence is nonempty, and the latest carried criterion is a genuine PASS with nonempty evidence and complete request/output/candidate identity. Public adoption must authenticate those origins exactly as before. No carried FAIL/NOT_CHECKED/missing criterion qualifies, no prior PASS may be fabricated, and COMPREHENSIVE/no-history admissions retain CHECKED requirements. CHECKED boundaries still require nonempty source-path evidence. Do not allow PASS+UNAVAILABLE, FAIL criteria, explicit blockers, or unresolved closures to claim completion. Preserve the existing instruction that writer findings are observations rather than verifier findings or acceptance; do not add an unrelated blanket finding-empty predicate to writer COMPLETE.
3. COMPLETE remains source readiness only. No output conversion to PASS, no carried-origin rewrite, no external mutation, no lost closure/finding/candidate binding. Independent verifier PASS still requires all criteria PASS, all admitted sweeps/checks CHECKED, all closures resolved, exact candidate, and no mandatory finding.
4. Mirror these exact rules in a NEW immutable physical validator/helper chain. Existing helpers and their digests remain readable/unchanged. All direct production callers select successor helpers only for new physical publication as existing versioning conventions require; historical receipts keep original versions.
5. Previously accepted C66/v1/v2 reports remain valid and all established safety negatives remain rejected. The exact real raw writer report must pass authenticated read-only validation after the fix, unchanged; that is not product acceptance. Normal owned-tick adoption must be covered by a synthetic real Store test, then physical publication validation from reopened ledger with the successor codec.

## Agreed test seams and steps

Read complete `develop-test-first` and its tests/mocking references, `elixir/AGENTS.md`, applicable shared rules. User already approved public report validation, ordinary controller adoption/restart, and physical publication seams. Public defs require adjacent specs; use why-only comments and existing tuples; no broad lint refactor.

1. RED a realistic v2 focused writer report with supplemental descriptive checks, NOT_CHECKED criteria, and honestly unavailable unchanged prior-PASS boundaries. Use existing public ReviewProtocol interface, then smallest role-specific fix. Add discriminating negatives for duplicate/blank IDs/evidence, bound/missing verifier paths, COMPREHENSIVE UNAVAILABLE, carried FAIL/missing evidence/identity, NOT_CHECKED without prior PASS, PASS+UNAVAILABLE, stale candidate/schema, unresolved closures, and verifier PASS with mandatory findings. Preserve v1 behavior and C66-admissible writer findings as non-acceptance observations; a writer row alone must not introduce a new historical publication rejection.
2. Prove authenticated ordinary adoption/reopen with real temporary Store and exact stopped worker evidence, not only a pure helper. Tampered carried output digest/origin must fail. Writer raw output/task/instruction bytes remain identical; operator receipt/counters stay separate. Use the existing actual-cap operator composition fixture if practical; no third product repair/new model turn. Run Python counterpart matrix and actual physical publication at that seam; add versioned validator/helpers and Worktree registrations with pinned digests. Never modify current priv v21/v27/v28/v15 bytes.
3. Read-only live-history qualifier runs the new `ReviewProtocol.validate_result` on the exact stored task/evidence/context using a readonly SQLite connection and temporary check process; record raw/binding digests and zero ledger writes/native turns/pushes. Parent owns scripts under plans/rollout; executor may add a narrow qualification script under this plan's scope, but must not invoke service mutations.
4. Freeze coherent commits, update README/SPEC/Elixir README/WORKFLOW with source-ready vs verifier evidence semantics and plan status. Parent independently reviews and reruns gates, then safely deploys. Do not leave active source tests while modifying pinned files.

## Scope and commands

In scope: ReviewReport, narrowly required ReviewProtocol writer instructions/validation integration, TicketPushIO helper/digest selection and only directly necessary Worktree caller integration; new versioned physical validator/executors/status-reader/origins (follow existing v21/v27/v28/v15 pattern); review protocol, worker runner, verifier repair, TicketPushIO boundary, and Python codec tests; root README/SPEC, Elixir README/WORKFLOW; this plan; a small read-only qualification script under `plans/rollout/` if needed. Parent owns plans/README. No scheduler/tick/intake (plan012), transport/MR recovery(workstream3), product source, budgets/policy/config/schema, new correction journal or live operations.

From elixir with `ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec --`:
- `mix test test/symphony_elixir/factory_review_protocol_test.exs` must pass, including red-before-green evidence.
- `mix test test/symphony_elixir/factory_ticket_worker_runner_test.exs test/symphony_elixir/factory_verifier_repair_test.exs` must pass, including composed adoption/publication.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test/python -p review_protocol_codec_test.py` must pass.
- `mix specs.check`; `mix format --check-formatted`; `make all`. Baseline C66 has649Credo; record exact new delta, no claim coverage/dialyzer when lint stops.

Use isolated ignored build/deps only. Named staging, coherent `git commit --no-verify`, no push/MR. Report finalSHA, red/green commands/counts/exits/logs, exact helper retention, live qualifier results and full gate limits.

## STOP and maintenance

Stop for drift, needing raw report/instruction/history rewrites, accepting missing carried provenance, broad verifier relaxation, another product repair/model turn, budget reset, touching plan012/transport code, migration, or live mutation. Two failed attempts at the same ambiguous condition require a narrowed plan. Keep role-specific readiness separate from acceptance across both languages; new statuses must have one explicit interpretation, not prose guessing.
