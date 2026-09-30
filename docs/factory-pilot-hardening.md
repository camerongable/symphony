# Factory pilot hardening ledger

This tracks reliability work discovered while advancing PPL-9723 and
PPL-10035. It is not a substitute for getting those two tickets through the
current pipeline. Each item remains open until its exit test passes; a locally
successful unit test does not count as a live delivery.

| Priority | Observed failure or gap | Required exit test |
| --- | --- | --- |
| P0 | A human answer arrived after three automatic spec attempts, and the controller failed PPL-9723 without using it. The repair budget now resets on a digest-bound answer. | Resume the same author task after the answer, pass independent critique, and reach an authorized contract without a new author task. Test the at-limit answer and a stale/mismatched answer. |
| P0 | An older PPL-10035 planner returned malformed final output and had no persisted format-repair budget. A one-shot grant now permits a same-task repair without altering the original request payload. | Prove the exact original turn and route, claim once, complete one schema-valid repair turn in that task, and advance to a single writer. Crash/restart after claim must reconcile rather than resend. |
| P0 | A planner followed an obsolete file-sink assumption and asked a question instead of returning the required structured plan. New planner prompts and the skill use the durable `plan_markdown` result. | Start a fresh planner request and obtain a schema-valid plan without a filesystem destination or interactive question. |
| P0 | A high-risk writer model role bypassed native worktree binding and controller branch attachment, and its sandbox then requested Git approval for the wrong branch. The role guard, controller-owned named-file commits, and exact same-task recovery are implemented locally. | Recover the existing writer without another task or approval, prove each worker slice commits through the controller and survives restart, then reach a draft MR. |
| P0 | A native writer legitimately edited source while Desktop readback was pending, but the scheduler treated that checkout as pre-launch dirty and failed its run. The in-flight guard and one-shot same-task dirty-slice recovery are implemented locally. | Resume PPL-10035 on its exact branch with the same task and preserved edits, then pass controller commit/read-back and reach a draft MR. Keep a regression for dirty-before-launch rejection. |
| P0 | Local Go generation, Bazel, and fixture checks attempted sandbox-prohibited operations and left workers waiting on approvals. Factory-mode instructions now forbid escalation, use a task-local Go cache, and stop blocked local checks. The Desktop broker cannot convey the workflow's `approval_policy: never` through its task-message tool; the Desktop-owned app-server is not externally addressable for a per-turn override. A worktree-local Codex config was not effective in an independent CLI config read and was removed; it is not proof of Desktop task policy. | Complete fresh writer passes without human approvals, prove CI verifies the blocked Gazelle/Bazel/fixture checks, and either demonstrate a supported task-scoped no-approval transport that retains native Project visibility or explicitly accept the residual Desktop approval risk. Do not globally relax Grail permissions. |
| P0 | Factory stage output has appeared in prose, with extra text, or hidden from Desktop task read-back. | Exercise valid, malformed, interrupted, and invisible-output turns for author, critic, planner, writer, and verifier. Each either advances from exact evidence or enters a named, single-task reconciliation state; none duplicate a task or external write. |
| P0 | Live repair initially reran the old native-writer guard because the long-lived Symphony LaunchAgent had not restarted after code changed. | Expose the running build identity and start time in control diagnostics, require a controlled idle-lease restart before live recovery, and prove a post-restart tick executes the new guard. Never infer that a successful local test updated the running process. |
| P0 | Recoverable author-revision and writer-slice bookkeeping mismatches were treated as terminal ticket failures, with attempted `ai-blocked` Jira writes. The two known cases now have exact-artifact recovery commands. | Classify transient protocol/read-back conflicts separately from product or provenance conflicts; reconcile the same task and side effects within a bounded retry budget. Fault-inject before/after each Jira write, Git commit, and ledger update, proving no duplicate comment, task, commit, push, or MR and no unnecessary human decision. |
| P0 | A critic-requested repair could reuse the prior specification revision even though its first draft had already been written to Jira. The repair path now proves that draft read-back and advances the target revision before another author pass. | Complete PPL-9723's revision-7 repair in the same author chat; prove every distinct digest has a distinct revision, no duplicate comment, and the critic evaluates exactly the new read-back draft. |
| P0 | Manual validation accepted a result from a different globally allowed environment than the confirmed contract named. The controller now compares the exact normalized contract environment before accepting PASS, RETRY, or REPAIR. | The wrong-but-allowed-environment regression stays red without the guard and green with it; confirm no MR evidence or `ai-review` transition occurs on mismatch. |
| P0 | A contract field under a later heading could satisfy a missing Manual Validation `Required` or `Environment`; a restarted factory could also accept PASS after validation was disabled. Parsing is now section-bound, and policy is rechecked at launch and result consumption. | Keep malformed and duplicate-field contract regressions, and config-flip tests for both pre-launch and pre-PASS paths; neither may reach `ai-review`. |
| P1 | Jira comment read-back has been briefly inconsistent immediately after a successful write. | Inject delayed visibility and prove bounded read-back retries recover the one existing comment, never issue another comment, and report a precise recovery state after the bound. |
| P1 | Native Codex Project/task association can lag task creation. | Delay Project visibility in an integration test and prove the same task eventually binds to the configured primary repository Project, or stays uncertain without creating another task. |
| P1 | A recorded but still-running Desktop turn was repeatedly prioritized ahead of a separate pending writer request. The broker now prefers actionable reconciliation and lets an unchanged in-progress turn yield. | With one in-progress recorded turn and one pending request, service the pending request exactly once while preserving the first turn for later read-back. |
| P1 | Dashboard and scheduler can disagree while a request is pending or stale. | For every durable run/request state, assert a mutually exclusive overview bucket, accurate health color, and a direct link to the one active task or exact recovery action. |
| P1 | The dashboard does not attribute complete token usage by factory role and retry, so the cost of debugging versus ticket delivery cannot be measured reliably. The active workflow also overrides the shared intake model policy. | Persist input, output, reasoning, and cached token counts per completed turn where Codex supplies them; display per-role and per-ticket totals with unknowns explicit. Assert that the live workflow's resolved routes match the intended policy. |
| P1 | The end-to-end test harness has simulated delivery, but not yet observed both pilot tickets through a real writer, CI/verification, controller push, draft MR, and applicable validation gate. | Record each live transition, exact SHA, Project/task identity, and MR read-back. Confirm no duplicate role task, reviewer assignment, merge, or production deployment. |
| P1 | Shared free disk fell to about 46.9 GB decimal during the pilots. Four failed PPL-9723 specification worktrees occupy about 12.4 GB decimal. Codex-managed worktrees total about 26.4 GB across 16 registered checkouts, including about 3.3 GB for the two active writers; Codex sessions, runtime cache, and app data are much smaller. Two Bazel bases total about 23.1 GB but belong to the live Grail checkout and an unrelated live PPL-10044 worktree, so neither is an automatic-cleanup target. | After both pilots finish, audit the provenance of the Codex worktrees, task/session history, runtime and app caches, Bazel bases, Go caches, and factory specification worktrees: distinguish storage caused by factory setup or pilot execution from unrelated work. Classify each factory-owned workspace against the ledger and Git state, authorize only inactive clean terminal remote-recoverable targets, reclaim those worktrees and their exact Bazel bases, and prove the freed capacity is reflected in the dashboard. Separately classify the remaining Codex-managed checkouts by task ownership and live state before any user-approved cleanup; never infer that all 26.4 GB is disposable. Add an automatic bounded retention/reclamation path and a regression that protects blocked, active, dirty, unpushed, manual, and live workspaces. Re-measure before and after; do not infer all machine-wide disk growth came from this factory. |
| P2 | The current dependency resolver reports security advisories for the dashboard/runtime stack. | Triage each advisory against exposure, upgrade supported versions, and rerun the full quality gate; keep this separate from ticket authorization. |

Run the live pilot first, then close the P0/P1 items with regression tests and
one final failure-injection pass. Preserve the immutable request and run ledger
when recovering a ticket; do not erase a failed attempt to make the dashboard
look green.

## Implementation pass: 2026-09-27

The following reliability fixes are implemented in the current local checkout
and covered by automated regressions. This is code/test evidence only: the
factory remains paused, no Jira or GitLab changes were made, and neither pilot
has been advanced. The live exit tests in the table above remain open.

| Fix implemented locally | Regression coverage |
| --- | --- |
| A digest-bound answer received at the specification-attempt limit resumes the same author task; invalid manual-validation evidence cannot authorize review. | `factory_contract_test.exs`, `factory_scheduler_test.exs` |
| Jira comment and label read-back retries are bounded and read-only; the original write is never repeated when visibility is delayed or missing. | `factory_jira_mcp_writer_test.exs` |
| A pending Desktop request can proceed while another turn awaits reconciliation, and an unresolved target cannot be duplicated. | `factory_desktop_request_test.exs` |
| Native-task recovery verifies the exact route and workspace identity before reusing a task; mismatches fail closed. | `factory_desktop_stage_runner_test.exs`, `factory_recovery_test.exs` |
| Terminal workspace cleanup records resumable removal checkpoints and revalidates exact identity; the scheduler attempts at most one newly authorized eligible cleanup per successful tick. | `factory_cleanup_test.exs`, `factory_scheduler_test.exs` |
| Dashboard projections distinguish current, delivered, cancelled, and stale intake states, and expose process start time plus loaded-module fingerprint. | `factory_observability_test.exs`, `extensions_test.exs`, `factory_control_test.exs` |

The disposable Codex Project probe used the Grail project and its repository
root, then sent a follow-up to the same thread; the canonical thread read-back
showed the exact valid response. The probe task was archived after the check.
It performed no repository edits or external writes. This does not substitute
for a live factory pilot or prove the end-to-end Jira-to-draft-MR path.

Repository gate on this pass: `mise exec -- make all` passed (625 tests, 0
failures, 6 skipped; Dialyzer 0 errors). The runtime was intentionally not
restarted and no scheduler/broker tick was run, so the live service has not
been proven to load this checkout.

## Model allocation TODO

- [ ] After both pilot tickets clear the pipeline, reconcile the live
  `WORKFLOW.local.md` routes with the shared factory model policy. Start by
  moving read-only intake from Sol/high to Luna/medium and ordinary feature
  writing from Sol/high to Sol/medium. Keep the specification critic and
  change verifier on strong review routes during the pilot. Evaluate
  Luna/medium on representative, well-defined implementation slices before
  making it a writer default. Compare successful completion, retries,
  latency, and measured tokens by role; update the workflow, shared policy,
  routing tests, and operator documentation together.

## Fast-lane TODO

- [ ] After the two pilots, design and test an opt-in fast lane for tickets
  with confirmed contracts. Reuse the existing writer chat and workspace
  across bounded repairs, normalize skill outputs, and retry read-backs
  without repeating external writes. Measure elapsed time, tokens, and
  completion rate against the standard path. Keep contract provenance,
  independent verification, exact-SHA delivery, and the draft-MR/human-merge
  boundary; do not make the fast lane a bypass for those gates.
