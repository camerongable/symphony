# U7 next packet: controller delivery join

Read-only preparation, 2026-10-05. This is remaining U7 implementation, not a new
delivery authority or a production enablement decision.

Reuse only the existing controller delivery transitions for PUSHING, CI_PUSHING,
MR_CREATING, CI_MR_CREATING and CI_WAITING. Do not route V1 through legacy
advance_run or cognitive launchers. Preserve current parent/ordinary eligibility,
fresh Jira authorization, immutable contract/candidate binding and ticket lock.

Before push/controller issuance, independently prove clean canonical checkout,
branch/HEAD/candidate agreement, no conflicting workspace ownership and no
unconsumed worker/file/check operations. Final delivery requires the consumed
verifier PASS for this exact candidate and round. Explicitly authorized CI
preflight is pre-verifier and must not incorrectly require that later PASS.

Controller operation recovery must join existing exact requests, including run,
contract, candidate, operation and previous-controller-turn identity. Existing
shared-controller uncertainty remains fenced. Do not retry an uncertain external
mutation or issue a second Jira blocked-comment operation merely because a
delivery operation returned uncertain. No broad DesktopRequest quarantine
relaxation. Reload run state after CI_PUSHING persists ci_preflight_sha.

For V1 CI_WAITING, use TicketWorkerRunner.collect_ci and ControllerCi transport
validation before the established CI consumer. The old prompt-only receipt gate
does not prove current head_pipeline, all job pages or merge-parent binding.
CI PASS returns to V1 VERIFYING; repair returns to V1 REPAIRING.

Required packet checks: exact PASS through controller push/MR/Jira review-ready;
CI preflight/PASS/repair; stale bindings, dirty/live source and unfinished evidence
deny all external effects; interrupted exact-request readback and controller busy
states retain no-duplicate behavior; wrong/current pipeline and merge parents,
pagination and required-job ambiguity fail closed. Production Policy's enabled
startup rejection remains until complete runtime acceptance.

## Push recovery boundary, investigated before execution

The existing unused `runs.candidate_handoff` column can hold a versioned immutable
push envelope; a second queue/table is not needed merely for storage. Dedicated
compare-and-swap transitions must own it instead of generic RunLedger updates.
Reserve the exact checkout as MAINTENANCE together with the intent, before issuing
the once-only push. Replay validates that owned reservation; it must not rerun
the unowned checkout-admission gate and mistake workspace_busy for a release cue.

System.cmd completion is not durable process evidence after a controller crash.
Use the existing owned helper/receipt transport pattern for a bounded controller
push invocation. Persist original invocation/program/input identity and wait/reap
receipt before independent remote readback can finalize/release. Missing or
ambiguous stop proof retains ownership; remote SHA alone never releases it or
authorizes another push. Add a narrowly typed controller receipt release path;
the worker-evidence-only generic release remains unchanged. Do not weaken the
read-only source worker or check executor profiles to support controller network IO.

Implemented first primitives: Worktree.read_remote_branch reads an exact valid
feature branch with no fetch or local-ref mutation. Worktree.origin_identity
requires one identical effective writer-push/repository-read destination and
returns its SHA-256 only, not credentials. Pin that identity and recheck at
issuance/readback. Real local-bare Git tests pass; actual once-only push intent,
owned-process receipt, reservation release and scheduler transitions remain next.
