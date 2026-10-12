# Broker completion readback and transport-loss coverage

2026-10-05. No new model turns, source delivery, or production enabling.

`read-ticket-turn --include-completion` now optionally returns the exact final-phase
acknowledgment from its already attested completed native turn. It rejects ambiguous,
malformed, wrong-digest and oversized completion output. MCP names include only
observed completed successful calls; item-level and nested-result errors reject that
call. Entire completion output is bounded at 16 KB, without evidence truncation.
This is not attachment-result, live-idle, or fresh-context proof.

CREATE explicitly requests the new parent's own supported `list_artifacts({})`
before acknowledgment; unavailable/error/worktree-attached observation requires a
false ACK. The broker must inspect the actual result independently. Projectless
identity and an observed tool name alone do not prove attachment absence.

The actual CLI exposed a workflow-scoping defect: `--workflow` loaded ledger
settings while native history access read the default tracker workflow. CLI now
scopes the explicit workflow for the operation and restores previous application
configuration in an outer `after`, including loading/execution errors.

Real read-only CLI verification against the retained synthetic fixture succeeds:
request `TC-b2d1856a1e35784b21a09b3ef46f867439cbd8be4195fec80d711588acb81124:g1:create`,
parent `01a10da0-e74a-7c82-96f4-926966b24e15`, completed turn
`01a10da0-e8d9-7b40-9cd0-0cedad422a92`, exact ACK true and actual observed
`codex_app/list_artifacts`. Native history readback SHA:
`7c0055fab54b3dd85c00a00fa8e7ffd7b8595b484e02e5d47263a215456057c7`.
No native resume/send/turn was performed.

Focused completion/chat/admission/CLI regression: **39 tests, zero failures**.
Independent frozen review accepted the completion parser fixes; the later workflow
scope repair additionally has configuration-restoration regression coverage and the
actual CLI result above. Specs, strict Credo, format and whitespace checks pass.
The workflow scope's setter is inside the outer `try`, so a setter/reload failure
also enters restoration. This is an isolated CLI boundary, not a concurrency-safe
way to retarget the workflow of a shared running service.

The genuine WorkerCheckIO outer timeout is retained. A new real ownership-loss test
transfers the actual helper Port to a separate collector, receives actual helper
data and successful exit there, and leaves the original caller silent until its
unchanged 30-second deadline. It proves RUNNING/PID/reservation retention, no receipt
adoption, no workspace release and unchanged source. **1 test, zero failures**, 32.7s.
Export: `elixir/cover/u7c-controller-outer-timeout.coverdata`; imported line-call evidence
is WorkerCheckIO line 90 = 1 and generic-error line 87 = 0. No knobs, fake helper,
runtime timeout change, coverage exclusion or threshold reduction.
Independent read-only inspection found no swallowed-callback false-positive or
remaining blocking defect in the ownership-loss test.

Canonical broker instructions are staged at
`plans/006-ticket-parent-broker-skill-update.md`, not installed live. Native context
command invocation, combined ordinary lifecycle, complete quality gate and production
acceptance remain outstanding. Slice three is not complete.
