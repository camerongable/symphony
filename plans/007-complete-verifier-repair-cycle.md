# Complete retained-history verifier repair

Planned at d4d2559, 2026-10-19, plus the copied dirty source baseline. This is an isolated worktree, not a clean HEAD checkout. Preserve the baseline; do not revert or commit it.

## Intent and authority

The user authorized implementing the recommended reliability direction and deploying only after the complete cycle is proven. This executor owns implementation and tests only. No live ledger, configuration, service, schedule, external GitLab/Jira mutation, worker message, cleanup, commit or push is authorized here. The main agent owns independent review and any later rollout.

The exact live bug is historical CI successors activating TicketCiRepairSuccessor.issuance_check for ordinary verifier REPAIR. Round 6 has ordinary findings, but CI claims exist only rounds 1–5. Baseline candidate fixes that admission, validates malformed repair contexts, preserves ordinary findings on CONTINUE with extra CAS fields, adds RepairObligations advisory packets, removes overview double-counting, and stops requiring historical MR proof to equal the current controller turn. Eighty focused tests passed. These are incomplete, unactivated candidate changes.

## Scope

Only elixir/lib/symphony_elixir/factory/{ticket_ci_repair,ticket_ci_repair_successor,ticket_worker_runner,repair_obligations,scheduler,observability,ticket_push,ticket_push_io,ticket_push_preissuance_rejection,ticket_mr_operation,ticket_mr_qualification,ticket_push_worker_history,worker_instructions}.ex; dashboard_live.ex; directly related tests/support fixtures; new immutable versioned push executors/history validators and readback-origin resources if strictly necessary; docs/factory-control-plane.md and this plan. TicketMrQualification is the accepted same-MR reuse dependency found during execution review. Do not modify old versioned Python helpers. No Grail product source changes.

## Constraints

Read elixir/AGENTS.md and shared mandatory rules. One writer owns this worktree. Other agents may be working elsewhere: never revert their edits or unrelated dirty baseline. Use apply_patch for edits. Every public Elixir def needs @spec. Preserve sole SOURCE ownership, exact contract/SHA/role/turn bindings, immutable receipts, UNKNOWN/CAS history, old BLOCK results, budgets and live manual-validation policy. Never treat a worker addressed claim as verifier PASS.

## Required implementation

1. Recheck baseline patches. Historical successor presence must not force ordinary verifier repair into CI scope. Invalid JSON, unknown objects, missing expected CI claims, stale rounds and tampered claims fail closed. Reject before new effects where possible; test pending reservation/restart behavior.
2. Finish repair-context convergence: ordinary findings survive two CONTINUE slices/restart and cannot overwrite changed obligations. RepairObligations must validate exact consumed verifier provenance, retain stable finding IDs and prior reviewed candidate, survive a CI repair interlude, distinguish new/regression/unresolved findings, and preserve already-admitted packet bytes. Existing old snapshots must remain readable without host rereads. Review its new implementation for silent filtering of corrupt history.
3. Add a real lifecycle regression using factory_ticket_worker_lifecycle_test.exs native_successor_case/assert_repaired_mr fixtures: previous CI successor -> successful pipeline -> verifier REPAIR -> ordinary writer CONTINUE twice -> COMPLETE -> preflight physical push -> same MR/new exact-SHA pipeline PASS -> fresh verifier PASS -> final delivery push/rollover and review readiness where fixture supports. Include read-only reopen/restart and idempotent repeated observation. The current fixture always returns verifier PASS; add opt-in fixture mode, default unchanged.
4. Expect and correctly fix downstream assumptions: TicketCiRepair.retained_preimage rejects missing current CI claim after historical claims; TicketCiRepairSuccessor.push_context/push_policy/push_current_claim/recheck_push_context assume every CI_PUSHING repair is CI-owned; TicketPush binding and current v8 physical helper/v5 validator do too. Introduce explicit current ordinary verifier-repair context with accepted verifier REPAIR + consumed stopped SOURCE result + immutable instruction packet + exact round/contract/candidate ancestry. It must grant only preflight push, never delivery PASS. Prefer one deep validation module; do not bypass historical validation or reclassify ordinary repairs as fake CI claims. Do not spend a CI attempt for ordinary verifier repair. After new CI/verifier PASS, final rollover must validate the right context too. If physical helper changes are needed, add new versions, select only for new issuance, retain original helpers/status readback, and prove coherent tampering is rejected.
5. Finish dashboard projection tests: statuses are exclusive, communication warning is orthogonal; current admission failure shows needs attention without pretending worker returned BLOCKED; resumed attempt removes only obsolete current projection. Historical controller failures remain nonblocking only with specific accepted later progress, across later controller turns and verifier repairs; newest current unresolved request still blocks. No history deletion.
6. Regression/acceptance coverage: deterministic transition refusal does not consume endless new worker attempts; transient recovery stays bounded and uncertain writes reconcile without replay. Existing failed-turn/notice logic should be reused and tested, not wholesale rewritten. UI must show exact current primary action.

## Validation

Use PATH=/Users/cgable/.local/share/mise/shims:$PATH ERL_FLAGS='+S 4:4'. Run focused affected mix test files and the new full native lifecycle. Run mix format --check-formatted on touched Elixir files, mix specs.check, and make all at the end; report preexisting full-gate failures accurately. For this local factory fix there is no usable source CI pipeline: lifecycle tests and artifact rehearsal are required before deployment. Never claim full gates pass if lint/coverage/Dialyzer did not run.

Negative cases must cover missing/tampered current CI scope, malformed ordinary context, changed contract/candidate/round, stale writer CAS, old admitted packet bytes, wrong verifier verdict, dirty/wrong checkout, pending human input, active/unproven owner, changed physical history, duplicate reconciliation. Do not weaken protections to make fixtures pass.

## Done and handoff

All above source/test changes, full diff scope readback, exact commands/results, and remaining limits. Do not deploy. Return COMPLETE or STOPPED with files, test evidence and specific remaining work. STOP for a new required authority, live mutation, inability to preserve old receipt semantics, or an architectural choice materially beyond this bounded cycle. Do not stop merely for expected adjacent transition defects; those are explicitly in scope. No commits or pushes despite generic executor templates.
