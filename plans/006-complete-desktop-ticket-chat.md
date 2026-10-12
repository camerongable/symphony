# Plan 006: Complete the Desktop ticket-chat route through gated implementation

> Gated implementation plan. The ordinary `Required: no` route is authorized;
> the required-manual-validation track remains separately gated.
> Implement one bounded work unit at a time and obtain independent acceptance
> before the next unit. The active goal authorizes sequential continuation through
> the ordinary local implementation slices after their tests and review pass.
> Stop for genuine user-input or new authority boundaries; this does not authorize
> commit, push, deployment, runtime enablement, or new paid native acceptance probes.

## Status and purpose

- Planned: 2026-10-04, HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`.
- Branch: `cgable/desktop-owned-ticket-chat-v1`.
- Authoritative implementation checkout:
  `/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`.
- Priority P1; overall effort L; authorization/recovery risk HIGH.
- Status: split authorized 2026-10-04. Ordinary `Required: no` implementation may
  proceed in reviewed units; this is not runtime acceptance or permission to deploy.
- Completes the ordinary ticket-chat path first. Required manual validation remains
  a separate follow-on and does not block contracts explicitly marked `Required: no`.
  Original Slices 1/2 are locally implemented foundations, not a reason to rebuild them.

The intended result is one accessible, Desktop-owned projectless chat per ticket,
one sequential source checkout per delivery run, controller-launched role workers,
fresh independent verification, and the existing scheduler as workflow authority.
The user can ask questions, answer genuine questions, amend the contract and request
MR rework through that chat. They do not manually relay worker results.

The ordinary path accepts only a digest-consistent delivery contract whose exact
manual-validation declaration is `Required: no`. Missing, malformed, stale, or
`Required: yes` declarations never fall through to the ordinary path. That path
must not launch a manual validator. The separate Required: yes follow-on still needs
real controller-owned claim/deploy/case/restore/release execution and independent
evidence; a parser, mock lifecycle, or receipt binder is not a substitute.

## Operator contract: inexpensive implementation, stronger review

| Responsibility | Proposed model | What it may do |
| --- | --- | --- |
| Bounded implementation | GPT-6 Luna, medium | Edit the authorized files for one unit; run its focused checks |
| Independent acceptance | GPT-6.1 Sol, high | Review frozen source and test quality; independently verify the unit |
| Unresolved capability/design decision | GPT-6.1 Sol, high | Resolve a named prerequisite; no speculative implementation |
| Mechanical polling/receipt collection | No model | Read durable state and authorized tool/process results |

These are assignments for implementing this plan, not changes to factory role
allocations, Desktop defaults, automations or global configuration. Verify actual
model/effort availability at dispatch; do not silently substitute a model. The
installed tool catalog currently names these models. Official guidance says
availability and supported effort depend on the client/account; `model/list` is
discovery, not proof of a successful inference request:
[app-server](https://learn.chatgpt.com/docs/app-server),
[subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).

One writer owns the implementation checkout. Reviewers receive an immutable
snapshot, not access to an active writer's checkout. Start reviewers with fresh
context: this plan, the unit, the diff, exact test artifacts and pinned source—not
the implementer's explanation as authoritative evidence.

### Standing parallelization requirement

At each dispatch and milestone, identify independent work that can proceed
concurrently. Run useful read-only future-slice investigation, test selection,
acceptance-gap mapping or documentation preparation alongside the current sole
writer; do not wait for an entire slice when these dependencies are independent.
Record each agent's bounded responsibility and return concrete findings to the
next implementer. Do not spawn redundant agents merely to keep slots occupied.

Keep one source writer per checkout. Reviews occur only after source is frozen,
or against a genuinely separate immutable snapshot, never against an active
writer's worktree. Parallel preparation cannot silently expand scope, enable
deferred GitLab feedback/manual-validation paths, run extra full suites, or
authorize live effects. Report completed milestones, remaining work and next
steps in chat. This is an ongoing execution requirement, not a one-time option.

For integration failures, read the actual terminal log and exact frozen stack
first. Check caller/callee return shapes, sealed historical projections and the
fixture's actual checkout identity before another capture-only lifecycle run.
Rerun for missing runtime facts, not fields already provable from frozen code.
Keep transition diagnostics compact (typed event, binding keys, status and SHA),
not full ticket/specification/envelope dumps. Preserve failing assertions; fix
incorrect fixture targets or duplicate waits without discarding their original
behavior checks. Bundle independently reviewed adjacent corrections into one
focused regression run when safe.

After every unit:

1. Executor returns `READY_FOR_REVIEW` or `NEEDS_DECISION`, never self-accepts.
2. Freeze named changed files and record their SHA-256 digests.
3. Reviewer checks correctness, requirements, test discrimination and scope.
4. Reviewer records `ACCEPTED`, `FIX_REQUIRED` or `NEEDS_DECISION` under `plans/`.
5. Report the result to the user. The user's 2026-10-04 authorization covers the
   ordinary Required: no track through its listed local implementation units, so do
   not re-prompt between accepted units. Stop on `FIX_REQUIRED`, `NEEDS_DECISION`, a
   new authority boundary, or before commit/push/deployment/runtime enablement.

Do not escalate Luna's model mid-unit. One bounded repair for a reproducible failure
is permitted within the same approved scope; a second failed attempt goes to the
stronger reviewer for diagnosis. An unresolved architectural choice is not a cue
to spend more implementation turns. Report elapsed time and available token usage;
do not estimate dollars from a test count or an unmeasured token total.

## Current state and drift check

HEAD alone does not describe this work: much of Slices 1–3 is dirty/untracked.
Do not create a clean worktree from HEAD and thereby discard the implementation.
Preserve the current checkout and all unrelated changes.

Run from the checkout before each unit:

```sh
git branch --show-current
git rev-parse HEAD
git status --short
shasum -a 256 -c plans/006-source.sha256
```

The checksum file pins selected critical source/tests at planning time. A mismatch
after an accepted unit is expected: the reviewer records the new baseline in that
unit's receipt. An unexplained mismatch is a STOP condition. Extend the baseline to
every additional file a unit will touch before authorizing that unit. Do not overwrite
an earlier baseline or claim these selected hashes are a complete repository snapshot.

Read repository `elixir/AGENTS.md`, `elixir/docs/logging.md` and applicable shared
rules under `/Users/cgable/.agents/rules` before acting. Every public Elixir function
needs an adjacent `@spec`; use `{:ok, value}` / `{:error, reason}` and existing
`Store.transaction!/2` patterns. Keep comments about invariants, not narration.
Canonical skills/configuration live under `/Users/cgable/.agents`, not provider copies.

### Facts verified from current source

- `factory/ticket_worker_runner.ex`: worker turns use recorded task/model identity,
  a pinned review base and `WorkspaceAccess`. `role_input` still rejects
  `manual-validator` with `:ticket_validator_authorized_transport_required`.
- `factory/worker_evidence.ex`: durable attempt/result/owned-process evidence.
  Model completion does not release SOURCE before adoption/consumption.
- `factory/workspace_access.ex`: SOURCE/REVIEW/MAINTENANCE share canonical path and
  Git-identity mutexes. REVIEW pins a clean candidate. Reuse these, not a second mutex.
- `factory/contract.ex`: `manual_validation_definition/1` reads bounded declarations.
  It is not an executable plan, authorization, synthetic-data proof or no-DDL proof.
- `TicketWorkerRunner.packet/4` adds `DECLARATIONS_ONLY` for the validator. It can
  currently emit a packet with `candidate_sha: nil`; the new regression is present
  but the implementation fix is not. Its interrupted result was not collected.
- `validation_unquoted_header/1` tracks prefix fences, not HTML comments. A complete
  commented-out section can currently yield declarations. This finding is unfixed.
- `factory/ci_collection.ex` collects current MR/pipeline/jobs/merge-parent evidence
  through an existing controller session; page 2 must be empty even after a short
  page 1. Local bindings are reread before binding a result.
- `integrations/gitlab-mcp/prepare.mjs`: guarded v3 artifact preserves `head_pipeline`
  and strict response booleans; it does not mutate installed dependencies or global MCP config.
- `factory/scheduler.ex` still rejects `TICKET_SUPERVISOR_V1` before tick side effects.
  `Policy` and Desktop issuance also retain disabled-route fences.
- `TicketChatCommands.decide/6` admits origin/readback-bound input but records
  `worker_started: false, external_changes_applied: false`. Admission is not application.
- `TicketChatOutbox.publish/2` already separates presentation from delivery and
  refuses blind replacement of claimed/uncertain requests.
- Store initializes schema migrations through version 24. Allocate the next migration
  only after checking the actual current schema; do not assume a remembered version.

Useful excerpts to match before editing:

```elixir
# TicketWorkerRunner: current unimplemented validator execution fence
defp role_input(_run, %{"role" => "manual-validator"}, _prompt, _opts),
  do: {:error, :ticket_validator_authorized_transport_required}

# Scheduler: current unconditional route fence
"TICKET_SUPERVISOR_V1" -> {:error, :ticket_supervisor_runtime_capability_unproven}

# TicketChatCommands: accepted input is still non-executing
receipt = %{status: "ACCEPTED", worker_started: false,
            external_changes_applied: false, input_key: input_key}
```

### Evidence limits, not completion claims

Recorded pre-interruption focused run: 48 tests passed; specs, strict Credo and
Dialyzer passed before the unfinished candidate regression was added. Historical
broader run: 207 tests passed plus one separate stopped-helper timeout test. These
are not new full-gate results. Last recorded full run: 1,082 tests, six live skips,
coverage 99.25% against unchanged 100%, therefore final gate FAILED.

Native file edit/resume were observed. Native CI first-page reads succeeded once,
but complete pagination/merge-parent acceptance remains unproven after a fetch
failure. Native Polaris read-channel output exposed formatted `messages` and
`pagination_info` strings, not typed claim/release fields. This proves a limitation
of the observed route, not that every possible Slack route is incapable.

## Scope and authority

In scope after unit-specific authorization: existing ticket-chat/worker/CI modules,
their tests, scheduler/task routing, broker target handling, policy/config, observability
and docs. Proposed new narrow modules are named below; their addition needs plan approval.
No general graph engine, separate scheduler or unbounded retry framework.

Path shorthand throughout this plan: `factory/name.ex` means
`elixir/lib/symphony_elixir/factory/name.ex`; a bare `factory_*_test.exs` means
`elixir/test/symphony_elixir/factory_*_test.exs`. `config/schema.ex` means
`elixir/lib/symphony_elixir/config/schema.ex`; `dashboard_live.ex` means
`elixir/lib/symphony_elixir_web/live/dashboard_live.ex`. Do not guess another package.

Out of scope: real-ticket migration/trials; changing PPL-9723/PPL-10035 or their MRs;
global Codex permissions/models; private Desktop RPC; API keys/accounts; native cleanup
enablement; unrelated worktree/cache deletion; fast-lane or review-policy redesign.

Polaris/Grail source changes and deployment are separate approvals. This document
does not grant them. Commit, push, MR writes and service deployment also require
explicit approval. Authorized commits/pushes use `--no-verify`, named-file staging
and a non-main/master branch. No such operation is part of writing this plan.

Never use the live factory ledger for fixtures:
`/Users/cgable/Library/Application Support/ai-factory/factory.sqlite`.
Use real temporary Git repositories and temporary SQLite; synthetic non-PHI/PII data only.

## Verification commands and test discipline

All `mix` commands run in `elixir/` via `mise exec --`. No dependency installation
unless a missing dependency is independently established and separately authorized.

| Check | Command | Required result |
| --- | --- | --- |
| Public specs | `mise exec -- mix specs.check` | Exit 0 |
| Format | `mise exec -- mix format --check-formatted` | Exit 0 |
| Lint | `mise exec -- mix credo --strict` | Exit 0, no findings |
| Types | `mise exec -- mix dialyzer --format short` | Exit 0, zero errors |
| Whitespace | `git diff --check` | Exit 0 |
| Provider protocol | `npm test` in `integrations/gitlab-mcp` | Exit 0; actual stdio/loopback tests pass |
| Slice/final full gate | `mise exec -- make all` | Entire command exit 0; user-authorized 99% coverage threshold preserved |

Use one focused command per changed seam during implementation. Do not run the
full suite after every edit. The user's latest instruction reserves broad/full
test runs normally for slice completion; earlier runs require a concrete
cross-cutting-risk explanation. Keep focused regressions and static checks for
intermediate packets. Full final acceptance remains required at Slice 5. A scoped
`--cover` run leaving untargeted modules
at zero is not a full-repository regression or a full-gate PASS.

For every new/changed test, record: requirement ID, public seam, failure it catches,
and why an existing fixture/test cannot cover it. Prefer extending an existing
regression or parameterizing equivalent inputs over allocating many slow processes.
Reuse `TicketWorkerFixture`, `TicketChatFixture` and real-temp-Git lifecycle patterns.
Pure parsing needs pure tests; ownership/recovery needs observable real process/Git/DB
effects. Mock only external system seams. No sleep-only health checks or tests that
merely assert the implementation's source strings.

The stronger reviewer must verify at least one discriminating regression per fix:
the buggy frozen version fails and the fixed version passes in a disposable review
copy. Never revert the user's dirty checkout to demonstrate RED. Test counts,
coverage percentage and an executor's PASS text cannot replace behavioral assertions.

## Work units and hard review stops

Dependency tracks:

- Ordinary `Required: no`: U0 → U2 → U6N → U7 → U8N → U9N → U10 → U11N.
- Required manual validation follow-on: U1 → U3 → U4 → U5 → U6. It stays gated
  until typed Slack evidence, no-DDL deployment/restore, approved action/catalog,
  and compensation contracts are resolved. Its unresolved gates do not authorize
  `Required: yes` through the ordinary path.
- U2 is already independently accepted. Keep one implementation writer per checkout;
  parallel work is read-only research/review.

### Readiness and mandatory dispatch packets

U0/U2 are immediately specified against current source. U1 is a bounded prerequisite
investigation with explicit outputs. U3–U6 are **conditional manual-validation designs**;
U7–U11 are **conditional ordinary-route designs**:
they must not be dispatched verbatim before their dependent capability contracts exist.
This is an honest readiness boundary, not permission for Luna to fill in the gaps.

Before authorizing each conditional unit, the stronger model writes a self-contained
`plans/006-Uxx-execution.md` from this design and the accepted predecessor receipts.
It must contain all of the following (absence prevents dispatch):

- Exact file allowlist, affected public/private symbols and current source excerpts.
- Exact function signatures, input/output schemas, failure/retry/abort outcomes.
- Profile producer/adapter source paths and immutable hashes from U1 where applicable.
- At most one principal behavior change plus its direct callers; split a larger unit.
- Ordered edits, exact focused commands and independently observable expected effects.
- Required positive/regression/failure tests mapped to original requirements.
- Native procedure, allowed targets, actor identities, spend ceiling and shutdown when relevant.
- Baseline snapshot, scope/authority boundaries and reviewer acceptance checklist.

The cold reviewer checks that packet before the inexpensive executor starts. Do not
accept a packet saying “implement the adapter,” “fix the relevant caller,” or “run
the appropriate tests.” These are design decisions for the stronger model to resolve.
Human stops in this plan govern construction of Symphony, not normal production
ticket slices: they do not introduce approval prompts into the factory happy path.

### U0 — Establish the handoff baseline (no new behavior)

Owner: Luna executor. Files: `plans/006-*` and a unit receipt under `plans/receipts/` only.

1. Validate checkout/branch/HEAD/checksums, record dirty/untracked paths; preserve them.
2. Confirm the interrupted test handle is absent or collect that exact handle if still
   available. Never restart a process merely because an observation timed out.
3. Run `mise exec -- mix test test/symphony_elixir/factory_contract_test.exs test/symphony_elixir/factory_ticket_worker_runner_test.exs` once to classify baseline.
4. Record the candidate-SHA regression failure separately from pre-existing failures.
   Do not fix source in U0; do not demand a false green baseline.

Reviewer acceptance: source baseline captured, known failure reproducible or explicitly
unverified, no unrelated changes, no live ticket/model/deployment effects. STOP.

### U1 — Freeze the unresolved capabilities before building the executor

Owner: stronger model; read-only capability/design work, not an open-ended Luna task.
Files: `plans/006-validation-capabilities.md` and sanitized evidence references only.

Resolve three named prerequisites, then freeze their exact interface contracts:

1. **Slack:** inspect the supported catalog/source for a machine-readable read path.
   Required fields: channel/message/thread IDs, author, timestamp, reaction actor data,
   authoritative pagination/cursor and complete-page observation. Bind writes/readback
   to the same authenticated principal and controller nonce. Preserve raw tool/schema
   identities; formatted text or inferred prose is insufficient. Do not assume a Polaris
   edit is mandatory until supported alternatives are ruled out with evidence.
2. **Deployment:** identify an exact trusted service/environment profile that cannot
   run DDL. Grail's existing DocExtract initializer uses `collate_and_goose`; ordinary
   deployment is not no-DDL proof. Pin executable/profile hashes, target cluster,
   namespace, allowed services, image verification and non-destructive restoration.
   If a chart/backend must change, present that precise cross-repo scope for approval.
3. **Executable contract:** the current fields are prose. Freeze the typed action
   representation below and the approved service/case catalog. No weak model may
   infer arbitrary shell commands, endpoints, PHI safety or expected results at runtime.
4. **Abort/compensation authority:** freeze a narrowly scoped restoration/release
   authorization at claim time, bound to the original attempt/environment/claim nonce,
   exact pre-deployment image observations and approved restore profile. Expiry,
   cancellation, replacement contract or changed candidate stops new deploy/test
   actions, but does not automatically revoke those pre-authorized compensating actions.
   Compensation cannot deploy the new candidate, modify data, roll back DDL or restore
   a target now owned by someone else. Missing ownership or changed restoration
   identity requires reconciliation while retaining the reservation. Never simply
   remove the stale-input check or strand a deployed attempt without a cleanup policy.

Recommended representation: retain human Manual Validation text and add a separately
   digest-bound `## Factory Validation Actions` JSON block generated during specification.
   It is mandatory only for required validation on the new route; legacy contracts stay
   unchanged. Proposal requires explicit approval of the contract/skill extension.
   The canonical specify-work skill can generate this in the existing grooming pass;
   do not introduce an extra runtime spec/planner loop or new routine human approval.

Example schema shape, not an approved service profile:

```json
{
  "version": 1,
  "environment": "cpp-test",
  "services": ["doc-extract"],
  "deployment_profile": "approved-profile-id",
  "cases": [{"id": "MV-1", "case_profile": "approved-case-id",
             "synthetic_fixture": "approved-fixture-id",
             "parameters": {}, "expected": {}}],
  "teardown_profile": "approved-restore-profile-id"
}
```

Candidate SHA comes from the ledger—not a contract placeholder or model-selected SHA.
Each profile has a version/hash and strict parameter/predicate schema. Freeze byte,
case/service-count, nesting and timeout limits in the capability document. Reject
unknown fields/profiles. No command, arbitrary URL, credential or file-path fields.

Verification: exact catalog/producer-schema observations and a rendered no-DDL
deployment/restore contract; fixed synthetic response examples and complete pagination
behavior. Read-only live calls need an explicit bounded probe approval, zero inference
where supported, sanitized output and owned-process shutdown. No Slack writes/deploys
for discovery. A self-authored PASS file is not native capability evidence.

Reviewer acceptance: supported interfaces and ownership are concrete; cross-repo changes
and approvals named; profile implementation/file paths frozen. If unavailable, report
the exact missing capability and STOP. Do not proceed to U3 with guessed adapters.

### U2 — Fix the two current validator defects

Owner: Luna. Files: `factory/contract.ex`, `factory/ticket_worker_runner.ex`, existing
`factory_contract_test.exs`, `factory_ticket_worker_runner_test.exs` (all under `elixir`).

1. Add a manual-validator-only exact 40-character lowercase-hex candidate guard before
   serializing its packet. Nil/invalid candidate cannot produce validator context.
   Preserve bootstrap behavior for writers and other existing roles.
2. Reject a validation heading/fields hidden by HTML comments as well as fences.
   Do not silently strip comments and thereby transform intent. Avoid accidentally
   rejecting valid closed code examples outside the section; prove the chosen supported
   Markdown subset. Do not add a broad new Markdown renderer just for this fix.
3. Extend the existing regressions, including the already-added nil-candidate assertion.
   Test commented-out heading and inline comment hiding later fields; valid real section
   and legacy `Required: no` remain accepted. Keep declarations inert.

Verify: `mise exec -- mix test test/symphony_elixir/factory_contract_test.exs test/symphony_elixir/factory_ticket_worker_runner_test.exs`; specs/format/strict Credo.
Expected exit 0; the two buggy variants fail in reviewer copies. No worker, GitLab,
Jira or deployment call; writer/run rows unchanged by packet reads. STOP.

### U3 — Implement deterministic executable validation contracts

Requires accepted U1 and U2, including approved format/catalog decisions.
Owner: Luna. Proposed narrow module `factory/validation_plan.ex`, its
`factory_validation_plan_test.exs`; `Contract`, `TicketWorkerRunner` and sibling tests.
Canonical specify-work reference/schema changes are a separately approved external
file scope; read writing-for-agents and skill-authoring instructions before that work.

Interface: `ValidationPlan.compile(contract, candidate_sha, catalog)` returns
`{:ok, plan}` or a precise error. It is pure; no models, shell or connectors.

1. Parse exactly one approved machine block from the confirmed contract; reject hidden,
   duplicate, missing, malformed or oversized blocks. Required:no needs no action plan.
2. Cross-check environment/services/case IDs against the human declaration; resolve
   exact approved profile versions and validate parameters/expected predicates.
3. Bind plan to issue/revision/contract digest/candidate/profile hashes. Serialize
   deterministically before digesting; equivalent map construction must not change identity.
4. Produce fixed action sequence: claim → record previous deployment → deploy candidate
   → verify image → run cases → restore/teardown → verify restoration → release.
   Record outcomes separately from declarations. No arbitrary action dispatch.
5. Missing machine data yields `validation_actions_missing`, not a new specification
   restart or permission to improvise. Existing runs are not silently rewritten.

Tests: valid synthetic plan, Required:no, source SHA/profile/contract change, text-vs-JSON
mismatch, unknown/action-injection fields, bounded data, unsupported environment,
unapproved fixture and deterministic digest. Reuse pure fixtures; no real Git process here.

Verify: `mise exec -- mix test test/symphony_elixir/factory_validation_plan_test.exs test/symphony_elixir/factory_contract_test.exs`; static checks. Reviewer inspects actual
compiler output and confirms no executable procedure is inferred from prose. STOP.

### U4 — Persist validation attempts and action ownership

Owner: Luna. Proposed `factory/ticket_validation.ex`, Store migration and
`factory_ticket_validation_test.exs`; narrowly extend `WorkspaceAccess` if necessary.

Proposed public signatures, to freeze in the U4 packet:
`prepare(store, run_id, compiled_plan, authorization, opts)`,
`advance(store, attempt_key, opts)`, `reconcile(store, attempt_key, opts)`,
`get(store, attempt_key)`; each returns `{:ok, attempt}` or `{:error, reason}`.
`advance` performs at most one logical action; `reconcile` reads the same uncertain
action rather than selecting a replacement. No new work queue.
Existing scheduler owns admission and ticking. Add one attempt record and ordered
action receipts, not a second delivery state machine.

Attempt binding: run ID, attempt number, revision/contract digest, candidate SHA,
verified SHA, plan/profile digests, REVIEW reservation key/generation and authorization
expiry. Enforce unique attempt/action keys. Payloads and completed receipts are immutable.

Action phases: PREPARED → SENT → COMPLETE, with RECONCILE_REQUIRED for uncertainty.
Set SENT transactionally before external execution. Receipt includes exact arguments
digest, producer/tool/process identity, raw-result digest, observed timestamps and
postcondition evidence. Do not store credentials or unbounded/raw PHI output.

1. Require current contract authorization and verified candidate before admission.
2. Reserve the existing clean source checkout under REVIEW for the attempt; no detached
   validator checkout. Prevent source/maintenance/rework until safe completion.
3. Recheck candidate, contract, authorization and generation immediately before action.
   If invalidated, enter abort/compensation from U1 rather than continue deploy/testing.
   Distinguish authorization for forward work from original bounded cleanup authority.
4. Persist results atomically; duplicates reuse exact keys, conflicts fail precisely.
5. Restart resumes the same action via readback. TTL/socket loss never proves stop.
6. Release REVIEW only after owned actors stopped and action evidence is consumed.
   Expose a validation-specific safe terminal receipt; do not fabricate worker completion
   just to satisfy the existing release interface.

Tests: temp SQLite/Git positive path, duplicate tick, concurrent source/maintenance,
stale SHA/authorization/generation, restart before/after SENT, receipt conflict and
unchanged writer/delivery rows. Include expiry, contract replacement and cancellation
after deployment: no further forward actions, exact pre-authorized restoration/release
or explicit reconciliation if ownership drifted. Use one representative real ownership fixture; table
tests cover cheap data variants without repeating process startup.

Verify: `mise exec -- mix test test/symphony_elixir/factory_ticket_validation_test.exs test/symphony_elixir/factory_workspace_access_test.exs test/symphony_elixir/factory_store_migration_test.exs`; static checks. STOP.

### U5 — Execute one fixed validation action through the controller

Requires the accepted exact backend contracts from U1; no fake production default.
Owner: Luna. Proposed `factory/validation_actions.ex`, approved adapter files and
`factory_validation_actions_test.exs`; `TicketValidation` caller only.

Split this design into four independently accepted dispatch packets:
U5a fixed local transport and dispatch; U5b typed Slack claim/readback/release;
U5c exact-image deployment/restoration; U5d synthetic case invocation/predicates.
Each is a separate user-authorized step, not four tasks for one executor turn.
Each runs `mise exec -- mix test test/symphony_elixir/factory_validation_actions_test.exs test/symphony_elixir/factory_ticket_validation_test.exs`.
External adapter paths cannot remain placeholders in the dispatch packet: U1 must
provide them and the user must approve any cross-repo implementation/deployment.

Proposed interface: `ValidationActions.execute(attempt, action, opts)` and
`ValidationActions.readback(attempt, action, opts)` return bounded controller
observations or a precise error. Dispatch uses an explicit compile-time action
allowlist; never convert ticket input into a module atom or executable name.

1. Implement the fixed profile dispatch and same-key readback, with bounded deadlines,
   output and sanitized error categories. Do not permit workers to call these actions.
2. Local subprocesses use fixed verified executables/argv, cleared or explicit environment,
   actual cwd/SHA checks and owned-child exit evidence. No shell interpolation.
3. Connector actions use exact advertised schemas/tool names and controller sessions;
   no MCP session/model fallback or broad worker tool access.
4. For Slack, read back author/thread/nonce and complete coordination state. Preserve
   existing claim/reaction protocol. An uncertain send is reconciled, never resent blindly.
5. Deployment/test uncertainty uses backend postcondition reads. Case calls need a proven
   idempotency/readback strategy; if unavailable, stop that attempt precisely rather than
   risk repeating a mutating synthetic request.
6. Test data/predicates come only from accepted case profiles. Declaration text saying
   synthetic/no migrations is never the safety check.

Tests: actual fixed local child plus a loopback/fixture external adapter; observe one
execution for duplicate requests, shutdown, uncertainty recovery, oversized/malformed
result and denied profile/target. No real Slack claim/deploy in the offline test.

Verify: `mise exec -- mix test test/symphony_elixir/factory_validation_actions_test.exs test/symphony_elixir/factory_ticket_validation_test.exs`; static checks. Reviewer confirms
the default path has a real executor, not just a mocked interface. STOP.

### U6 — Complete validation and original Slice 3 acceptance

Owner: Luna; stronger reviewer for native acceptance. Files: TicketValidation/actions,
TicketWorkerRunner, WorkerEvidence, existing/new validation lifecycle tests only.

1. Drive the entire fixed sequence, recording image digest and exact candidate association.
2. Run every declared case and assess exact predicates; retain bounded evidence per ID.
3. Always attempt authorized teardown after ordinary case failure. Restoration/release
   uncertainty keeps durable ownership and a precise reconciliation reason.
4. Fresh read-only validator assesses controller receipts for exact candidate/contract.
   Feed no writer rationale/parent history. Worker text cannot manufacture missing receipts.
5. Map result to existing PASS/RETRY/REPAIR/BLOCK semantics, preserving scheduler limits
   and Jira/MR evidence rules. Only complete, fresh exact-SHA evidence can qualify PASS.
6. Prove native CI collection's page-two and merge-parent path using guarded v3 provider,
   with existing authentication and read-only scope. A fetch failure is not PASS.
7. Complete native structured worker-result adoption/fresh-review acceptance, not merely
   the earlier file-edit canary. Reuse accepted evidence unless a changed seam invalidates it.

Offline checks: validation action/attempt tests plus existing worker/evidence/controller-CI
tests. Native checks require separately approved synthetic target, external write scope
and spending ceiling. Record exact tool/actor/process/result and independent Git/DB facts.
Mocks cannot satisfy this requirement. If no approved native validation fixture exists,
STOP and report that capability—not a generic “blocked” or a broader access workaround.

Reviewer gate: frozen adversarial review; `mise exec -- make all` exit 0; explicit
requirement/evidence matrix for original Slice 3. Inspect coverage misses by behavior:
do not add fixtures just to hit impossible private branches, lower thresholds or add
exclusions. Any dead-branch simplification needs a separate behavior-preservation review.
Mark original Slice 3 accepted only when real execution/recovery/native evidence passes.
STOP and ask before original Slice 4 begins.

Slice 3's capacity requirement is mandatory, not optional: read the complete
`ensure-factory-capacity` skill before any implementation/source-writing executor.
Do not lower its configured 20 GB budget or delete unapproved worktrees/caches.
Fixtures use synthetic capacity values; actual native writers/builds use measured
capacity. Runtime admission must preserve capacity checks before new writer,
rework and any restoration, including after restart. Waiting controllers and
read-only status requests do not consume a writer slot. Add one low-capacity
integration case proving no new writer/process is started and the candidate survives.

### U6N — Freeze the ordinary `Required: no` admission boundary

This is the only Slice 3 prerequisite for starting U7 on the ordinary path. It does
not complete original Slice 3 or approve Required: yes.

Owner: Luna; stronger-model packet review. Files are enumerated in
`plans/006-U6N-execution.md`, including only reservation fixtures and the progress doc.

1. Add one reusable eligibility check for an ordinary ticket-chat delivery run:
   kind must be `DELIVERY`, execution mode must be `TICKET_SUPERVISOR_V1`, the stored
   decision must be integer `0`, and the latest authorized contract read from the stored
   Jira snapshot must have matching issue key/id and well-shaped comments; its latest
   authorized contract must exactly match run issue, revision, SHA, and Markdown and
   parse as `Required: no`. This checks stored evidence, not live Jira freshness; U7
   retains that scheduler admission responsibility.
2. `TicketChat.reserve/3` fails closed before creating/linking chat or request state
   when any condition is missing, inconsistent, malformed, or `Required: yes`.
3. Keep specification and validation runs out of the ordinary path. Required: yes
   validation remains routed only through the legacy validated flow until its gated
   executor exists. Do not change the issuance fence in this unit.
4. Add only discriminating tests for valid no-validation admission and each failure
   class. Update ticket-chat fixtures to carry exact bound contracts. Preserve existing
   request/runtime fences and all legacy semantics.

Verify the ticket-chat suite plus the directly changed fixture consumers: commands,
context, outbox, Desktop CLI, ticket replay CLI, worker runner, worker evidence, and the
single AppServer test using the shared parent fixture. Then specs, formatting, and
`git diff --check`. Do not run
the full suite. No schema migration, scheduler dispatch, worker launch, model turn,
external call, commit, push, or deployment. STOP for frozen review before U7.

### U7 — Route the existing scheduler and broker for `Required: no` only

Owner: Luna. Files: Scheduler, TaskLauncher/StageRunner, Policy, DesktopRequest,
DesktopToolArgs, config/schema.ex, relevant sibling tests. Canonical Desktop broker
skill update is a separately approved external scope; no provider-specific copies.

Use separate packets: U7a disabled-route quarantine and isolation;
U7b worker launch/adoption; U7c parent broker issuance/presentation. The U7a
packet is `006-U7A-quarantine-execution.md`; it prevents one recognized but not
yet integrated V1 row from freezing unrelated legacy work, without mutating or
reclassifying the quarantined ticket. Relevant current seams are
`Scheduler.validate_stored_execution_modes/1`, `validate_run_transport/2`,
`launch_or_consume/5`, `stage_workspace/6`, `TaskLauncher.launch/8`,
`TicketWorkerRunner.run/5`, `DesktopToolArgs.create_thread/2` and `followup/1`.
Freeze which caller is changed in each packet; never add a second dispatcher.

U7b launch/adoption is implemented locally; its scope and verification are in
`receipts/006-U7B-worker-integration.md`. This does not enable U7c parent issuance
or production ticks, nor complete combined U7 acceptance.

The normal fixture tick now reaches exact controller push and MR_CREATING using
one source checkout and no extra worker. The push/finalization boundary, bounded
remote readback, group cleanup, focused tests and independent review are recorded
in `receipts/006-U7-push-finalization.md`. The three stated separate-VM crash
checkpoints passed; see `receipts/006-U7-push-vm-recovery.md` for exact claims and
exclusions. Completed-intent rollover for repaired candidates and same-candidate
post-CI verification is implemented and tested; see
`receipts/006-U7-push-intent-rollover.md`. MR/CI/Jira joins remain next; do not
interpret push acceptance as complete U7 or enablement.

Receipt-only readback of an original Desktop controller request is now implemented
and tested, including preservation of a later controller turn; see
`receipts/006-U7-controller-receipt-readback.md`. This does not yet authorize or
adopt an MR operation. Exact run/candidate/contract ownership and original-request
lookup remain the next MR integration step.

Exact MR binding and a controller-turn-independent semantic request key are now
implemented and tested; see `receipts/006-U7-mr-operation-binding.md`. Tagged V1
controller requests remain quarantined. Typed enqueue/issuance authorization,
original-turn lineage, receipt adoption and current remote-MR qualification remain
next; no native MR issuance or production enablement is claimed.

Typed MR preparation now uses that key for original-request lookup before context
reconstruction and queues new operations only after fresh admission, unchanged
run/control snapshots and a free controller slot. Existing-request recovery retains
persisted ordinary eligibility while avoiding new model/Jira/admission requirements;
see `receipts/006-U7-mr-request-prepare.md`. Issuance remains quarantined. Narrow
issuance/readback authorization and receipt adoption are next.

Internal typed MR claim/readback now has durable atomic claim receipts, exact
owning-Desktop/empty-queue/latest-turn observations, restart no-resend, mixed-owner
rejection, and historical request-only recording that preserves newer Control
state; see `receipts/006-U7-mr-claim-readback.md`. The latest turn is reread after
queue collection, so timestamp equality alone does not establish native lineage.
Production Policy, pending discovery and CLI/tool send integration remain fenced.
MR result adoption and the CI/Jira joins remain next, not completed by this packet.

Current-candidate MR result adoption is now implemented on the existing locked
scheduler path; see `receipts/006-U7-mr-result-adoption.md`. It qualifies the original
successful request through a required configured numeric project pin and a fresh
MR-only read on an existing controller session. Ordinary adoption records MR fields
without Jira finalization; preflight advances once to CI waiting. Native pending/
CLI/send wiring, CI/Jira joins and combined acceptance remain.

The user approved the recommended ephemeral read-only connector transport after
source inspection found no supported way to borrow the Desktop controller's live
MCP session. This supersedes the existing-session-only requirement for MR adoption
readback (not mutation authority). The scheduler now opens one short-lived GitLab
session in the bound controller directory after successful immutable result
qualification, runs only the catalog-qualified MR collector, and closes it on
success/error/exception. It does not start a model turn, resume/fork a controller,
create a source checkout, or change controller identity. Existing source-worker and
production capability fences remain unchanged. Native transport acceptance and the
combined lifecycle proof are still required; fake app-server tests are not live
acceptance. See `receipts/006-U7-mr-read-transport.md`.

Typed MR follow-up formatting and an internal atomic claim-and-return-arguments
entrypoint now have local regression coverage and independent review. A map-only
formatter is never issuance authority; the transaction re-reads the current row,
persists uncertainty, and returns arguments once after commit. CLI/pending/native
send integration remains disabled and is the next local step.

Typed MR discovery, normal-tick preparation, the policy-gated claim CLI and a
bounded stdin owner-observation handshake are now implemented locally. Jira is
read before asking the broker for fresh Desktop owner evidence; native latest/
queue facts are collected afterward. Authority remains in memory, and arguments
are returned only after atomic uncertainty. Current Policy rejects the production
CLI before readiness. The existing broker skill has not been switched to this
new path; install and live timing acceptance remain required. See
`receipts/006-U7-mr-cli-ci-joins.md` and `006-U7-mr-broker-integration.md`.

The CI_WAITING normal-tick join now adopts WAIT/BLOCK/PASS exact evidence. PASS
enters fresh verification once; that verifier receives bound CI evidence and
passes through the existing normal push rollover. No legacy cognitive CI/MR
finalizer is called. Jira finalization, combined U7/native acceptance and Slices
4–5 are not completed by these local changes.

The Jira transport and two-effect storage foundation are now implemented locally.
The staged provider adapter applies atomic bounded factory-label deltas instead
of replacing a human's current labels. A model-free owned Jira connector supports
catalog-qualified transitions and closes on return/error/exception. Schema 27
records one immutable semantic Jira operation with two ordered effects; uncertain
effects cannot be claimed again after restart. Post-claim readback, unique comment
identity and consistent preceding receipts are required. Checkout/verifier/push
metadata drift rejects the original binding rather than allowing another comment.
These are not issuance authority or scheduler integration: live `In Dev`, review-ready
finalization, reservation release/busy fencing, provider installation, combined
U7/native acceptance and Slices 4–5 remain. See
`receipts/006-U7-jira-transport-journal.md` for exact tests and review status.

The local Jira workspace gates are also implemented: read-only initial/delivery
facts remain distinct from Jira dispatch authorization; initial maintenance reserves
only the pinned base of an ordinary V1 admitting-writer run. Uncertain/partial Jira
work cannot release it, and held initial budgets survive failed/cancelled run states.
Exact complete-journal release is idempotent and can roll back with finalization.
Actual writer admission rejects a still-held maintenance reservation. The existing
normal planner/writer/verifier/push lifecycle remains covered. See
`receipts/006-U7-jira-workspace-gates.md`. The Jira effect executor and scheduler
wiring still remain; these gates alone do not perform `In Dev` or review-ready writes.

The initial Jira effect executor and existing-checkout scheduler join are now
implemented locally. Owned non-source connector scope, fresh ordinary authority,
unique current advertised transition, capability preflight, one-shot uncertainty,
direct readback and final current target checks precede transactional release/writer
admission. Already observed effects need no mutation or extra model turn. Local
tests cover lost responses before/after application, restart, blocked/reverted
target state and the normal planner/writer/verifier/push path. Review-ready Jira
executor, shared-controller busy/recovery fencing, combined native lifecycle,
provider/broker installation and final gate remain, as do Slices 4–5. See
`receipts/006-U7-jira-initial-executor.md`; this is not production enablement.

Review-ready prerequisites now include a strictly read-only adopted-MR receipt
qualification seam, retaining stopped candidate/push/native claim/route/human-state
gates without fabricating Jira dispatch authority. Actual dispatch binding still
requires authorization. Comment preflight matches the installed append tool, and
the journal accepts exact canonical Jira-reader text-only comments. Tests cover
unchanged ledger/control rows and corrupted claim, replaced checkout, candidate,
request and human MR-state changes. The review-ready executor/scheduler join is
still next, followed by shared busy/recovery fencing and combined acceptance. See
`receipts/006-U7-review-ready-prerequisites.md`; U7/Slice 3 remains incomplete.

The ordinary adopted-MR Jira finalizer is implemented and independently reviewed
at its local component boundary. Its once-only comment/label journal, fresh Jira
read after MR qualification, issued-target recovery and atomic release/READY update
are covered by the disposable Git/SQLite lifecycle. See
`receipts/006-U7-jira-review-ready-finalizer.md`. Disabled/paused scheduler draining
and shared-controller busy fences remain next; direct recovery does not establish
those capabilities. Combined/native acceptance, installation and final gates remain.

Recovery-only scheduling and shared-controller Jira fencing are now implemented
and independently reviewed. Paused ticks use an identity-bound exclusive lease
with a fixed readback callback; normal ticks distinguish native activity from Jira
uncertainty. Failed release retains ownership and does not starve an unrelated
parent handoff. See `receipts/006-U7-jira-recovery-scheduling.md`. Remaining local
acceptance is the named uninterrupted combined lifecycle, followed by installation,
native permission/lifecycle proof and the unchanged full gate. Slice 3 stays open.

The named uninterrupted deterministic lifecycle is now present and independently
reviewed. One run/ledger/repository/parent proceeds through normal scheduler ticks
to review-ready, retaining the same candidate and checkout; a final tick is quiet.
The named U7 group and two extracted-fixture callers passed 111 tests. See
`receipts/006-U7-combined-deterministic-lifecycle.md`. The canonical parent-broker
skill is already installed; atomic Jira-provider qualification and actual runtime
permission/capability acceptance still remain. Full `make all` is running separately;
its outcome and native acceptance are not inferred from deterministic tests.

1. Route only new allowlisted `desktop_owned_ticket_chat_v1` runs; keep immutable
   execution mode and legacy/null transport semantics.
2. Use existing task keys/model allocations; role work goes through TicketWorkerRunner,
   not Desktop stage chats. The broker creates/presents the one projectless parent only.
3. Parent creation uncertainty keeps the original request. One waiting parent does not
   stall unrelated tickets. No external resume/fork/takeover of the Desktop parent.
4. Replace unconditional V1 rejection only after U6N acceptance and actual supported
   route/version/parent/worker capability checks. Admit only exact `Required: no`
   deliveries. Required: yes, missing, malformed, or inconsistent validation facts
   continue to fail before effects. Unknown modes remain rejected. A user config boolean
   or report file is not a runtime permission attestation.
5. Preserve existing writer → verifier → authorized CI preflight/MR → required validation
   → review-ready transitions and exact evidence gates. No alternate push/MR authority.
   Preserve measured 20 GB admission and configured concurrency limits before every
   new writer/rework/restore; no auto-cleanup outside the existing authorized policy.
6. Keep default enabled=false. Rollback stops new admissions but permits safe readback,
   draining and reconciliation of admitted new-mode runs; no legacy reroute.

Verify each packet with its named test file and direct callers. Combined U7 gate:
`mise exec -- mix test test/symphony_elixir/factory_desktop_ticket_chat_lifecycle_test.exs test/symphony_elixir/factory_scheduler_test.exs test/symphony_elixir/factory_desktop_request_test.exs test/symphony_elixir/factory_desktop_tool_args_test.exs test/symphony_elixir/factory_stage_runner_test.exs`.
Prove default disabled, unknown-mode denial,
legacy behavior, two tickets with one pending parent, explicit stored allocations,
unproven runtime denial and no idle parent/worker turns. STOP.

### U8N — Apply admitted user commands and batch MR rework (ordinary path)

Owner: Luna. Files: TicketChatCommands, Scheduler, ContractChat, MrFeedbackConsumer/
MrFeedbackRework and existing lifecycle tests. Keep proposal staging non-authorizing.

Split U8a answer/application receipts, U8b contract amendment, U8c MR batch rework.

Scope update (2026-10-07): the user has put the tagged GitLab MR-review workflow
on hold. U8c, numbered requirements 5-6 below, and their U9/U11 MR-feedback
acceptance cases are deferred rather than completed. Keep the investigation and
legacy isolation guards; do not implement or enable a V1 MR-feedback adapter in
this rollout. Ordinary delivery/MR creation and direct ticket-chat contract recovery
remain in scope. The existing deployed legacy integration is unchanged.

Blocked-writer follow-on: current Slice 3 candidate adoption safely rejects a
schema-valid BLOCKED result without committing source or promoting a candidate,
but its active writing stage and unconsumed evidence otherwise defer indefinitely.
U8 must add a controller-owned durable disposition and honest blocker/next-action
presentation before enabling the ordinary route. Preserve exact result and dirty
edits; do not route BLOCKED through successful candidate adoption. Create a bound
question only for genuine answerable decisions and require explicit resume admission.
Clean/no-edit release requires stopped/I/O/HEAD/clean proof; dirty or ambiguous
ownership remains held. Do not borrow legacy block_run's unscoped Jira writes or
restart implementation/specification automatically. This is within the existing
U8 question/recovery scope, not authorization for another architecture.
Proposed `TicketChatCommands.apply_accepted(store, command_key, controller_context)`
returns the exact durable outcome and never re-applies an external mutation on replay.
Freeze its schema/status migration, conditional updates and external readback arguments
in U8a. Current seams to preserve: `TicketChatCommands.collect/2`, `decide/6`,
`Scheduler.maybe_admit_review_rework/2`, `MrFeedbackConsumer.process_one/2`,
`MrFeedbackRework.pending_batch/2`, `admit/4`, `complete_push/4`.

1. Consume ACCEPTED direct-origin commands once under a controller transaction; store
   APPLIED/REJECTED outcome separately. Do not conflate admission with external success.
2. Answer the exact open question/revision; reject stale or broker/quoted input.
3. Contract amendment uses existing authorized Jira write/readback/independent critique.
   Preserve checkout, candidate and completed slices; invalidate only stale evidence.
   Never restart specification or initial implementation automatically.
4. Questions read fresh context and launch no writer by themselves.
5. Group explicit source-change notes by MR/batch across ticks. Conversation requires no
   source reservation; source rework uses the same writer/checkout/MR and fresh verifier.
6. Preserve original GitLab discussion IDs, reply prefix and `$Symphony` recognition.
   Presentation/reply failure must not replay source edits or fail completed delivery.

Verify: lifecycle, ticket-command, contract-chat and MR feedback consumer/rework tests.
Combined U8 gate: `mise exec -- mix test test/symphony_elixir/factory_desktop_ticket_chat_lifecycle_test.exs test/symphony_elixir/factory_ticket_chat_commands_test.exs test/symphony_elixir/factory_contract_chat_test.exs test/symphony_elixir/factory_mr_feedback_consumer_test.exs test/symphony_elixir/factory_mr_feedback_rework_test.exs`.
Cases: question-only; answer+action; duplicate/edited/stale input; two notes per MR;
contract change after PASS; busy parent; uncertain Jira/reply mutation; restart after
admission before application. One source action per accepted logical batch. STOP.

### U9N — Prove the complete ordinary scheduler lifecycle before observability polish

Acceptance checkpoint (October 8, 2026): original Slice4 is accepted. The selected
offline integration, frozen reviews and final native busy-input/source-active/
deferred-presentation checks are recorded in `receipts/006-U9-native-acceptance.md`
and `../docs/desktop-ticket-chat-progress.md`. The final independent native receipt
is `/private/tmp/symphony-u9-native-final-v5-019fa5b7/reviewer-v5-retry-acceptance-receipt.json`.
The original execution requirements below remain for audit. Next is U10/U11N;
this checkpoint is not production rollout or the final Slice5 aggregate gate.

Parallel read-only fixture/test-selection handoff:
`006-U9N-integration-prep.md`. Its gaps are requirements still to implement and
verify, not evidence that U9N is complete.

Owner: Luna; stronger reviewer acceptance. Files: integration fixtures/tests and any
narrow caller correction identified by the integration, not an unrelated refactor.

Use one temp repository/ledger and bound parent receipt: ai-ready → writer slice →
controller adoption → fresh verifier → current CI → draft MR → review-ready → explicit
rework → fresh verifier. Exercise only `Required: no`; prove missing, malformed, and
`Required: yes` contracts are rejected before parent/worker side effects. The separate
required-validation follow-on owns Required: yes.
The explicit rework here is a directly authorized ticket-chat action, not tagged
GitLab feedback collection. Deferring U8c does not remove direct operator recovery,
contract amendment or candidate-preserving rework from the single-parent workflow.
Legacy fixture path still passes. One source checkout throughout; read-only stages
cannot mutate it; no idle model invocation or manual relay.

Inject deterministic restart barriers at stored result/pre-adoption and pending summary.
An ambiguous external result reconciles the same action; no second worker or MR creation.
Verify the parent can report current candidate, completed work, findings and next action.
Native acceptance must include real human input while a source worker is active and
two consecutive inputs while the parent is busy: preserve both, consume once, queue
the presentation and do not infer idle from a foreign cold thread read.

Verify: `mise exec -- mix test test/symphony_elixir/factory_desktop_ticket_chat_lifecycle_test.exs test/symphony_elixir/factory_full_lifecycle_test.exs test/symphony_elixir/factory_scheduler_test.exs`; reviewer checks actual state/effects.
Mark original Slice 4 accepted only after these behaviors pass. STOP.

### U10 — Expose actual status, costs and rollback (original Slice 5, part A)

Offline acceptance checkpoint (October 8, 2026): replay, projections, actual
LiveView checks, corrected frozen standards/spec reviews and existing-guide
updates pass. Root boundary batch: 45/0; selected LiveView batch: 5/0.
See `receipts/006-U10-observability-replay.md`. Plain-VM replay proof is not
restricted deployed-broker proof; that remains in U11N native acceptance.

Owner: Luna. Files: Observability/PilotReport, TicketContext/outbox, dashboard_live.ex,
their sibling tests, `elixir/lib/mix/tasks/factory.ticket.ex`, Store only if needed for
true read-only opening, README/WORKFLOW/control-plane docs.

1. Show an accessible parent-chat link, source stage/worker/candidate, CI, validation action, open question and next
   action separately from parent synchronization lag. A failed summary is not failed work.
2. Keep context ≤16 KB and summaries ≤2 KB with paged artifact drilldown, not silent loss.
3. Report measured per-role/turn token usage, unknown values explicitly, native worker
   visibility, worker/review elapsed durations and checkout count. Use observed start/end
   timestamps; label active/incomplete duration separately. Do not claim diagnostic worker threads are invisible.
4. Explain scheduler, broker and parent responsibilities and the parent's trusted-operator
   permission trade-off. Parent instructions are not an enforced read-only sandbox.
5. Document disabled/default rollout and draining rollback; keep native cleanup separate.
6. Add `mix factory.ticket replay RUN --workflow FIXTURE_WORKFLOW` as a genuinely
   read-only receipt replay/diagnosis surface, backed by `TicketContext`/bounded ledger
   reads. Output: current binding/candidate/contract, ordered action/worker receipts,
   open decision, uncertainty and next action; no execution or mutation replay.
   Existing CLI reads call `Store.start_link` and can initialize/migrate a store:
   do not assume that is read-only. Use a verified read-only connection or an existing
   store read path that performs no startup migrations/DML; reject missing DB/schema
   without creating them. Do not wake an AppServer, broker or worker for diagnosis.

Verify: context/outbox/observability/dashboard tests; rendered synthetic dashboard/status
inspection and synchronous context reads. No screenshot-only acceptance. STOP.
Focused command: `mise exec -- mix test test/mix/tasks/factory_ticket_test.exs test/symphony_elixir/factory_ticket_context_test.exs test/symphony_elixir/factory_ticket_chat_outbox_test.exs test/symphony_elixir/factory_observability_test.exs test/symphony_elixir/factory_pilot_report_test.exs`.
The U10 packet must name the existing dashboard test/helper paths before dispatch.
Use the fixture workflow/DB only; assert DB contents/schema unchanged and all model/
process-launch counters zero before/after the replay command.

### U11N — Final integrated ordinary-path acceptance and separately authorized deployment

Owner: stronger reviewer; Luna only for named fixes. Freeze all changed source first.

October 9 checkpoint: full frozen `make all` PASS, root session 3175 exit 0;
1,540 tests / zero failures / six skipped, coverage 98.67% against approved
98.5%, Dialyzer zero errors. See `receipts/006-U11-final-gate-985-pass.md`.
October 10 checkpoint: the user approved step 3. Actual human answer/replay,
same-parent bootstrap recovery, one-checkout planner/writer/controller commit,
controller restart and fresh verifier PASS were observed. Ten native turns
completed; eleven sends/worker attempts were conservatively counted against
twelve. The final presentation turn repeated refreshes and was stopped, so
integrated acceptance remains incomplete. Canonical presentation fingerprints
and an explicit one-refresh/one-summary instruction pass focused checks; the
latest instruction has no native acceptance claim. Source rework/amendment
scenarios and step 6 remain unexercised here. The earlier full gate predates
these fixes and must be refreshed on frozen source. See
`receipts/006-U11-human-and-ordinary-native-checkpoint.md`. No blind resend of
the RECONCILE_REQUIRED presentation or budget reset is authorized by this receipt.

October 11 checkpoint: exact native-history reconciliation terminally failed the
stopped presentation without changing its original proof. Controller progress
updates now render immutable as-of snapshots, while direct human commands retain
strict refresh requirements. The actual v5 parent summary passed; unchanged
publication did not call a model. Three additional Luna turns were used. Native
amendment/rework remains unrun because normal synthetic delivery preparation
encountered `ticket_push_transport_unproven` with the original push claim/receipt
absent. Do not resend that uncertain push or force the run to READY. The first
refreshed full gate stopped before tests at strict lint. A narrow behavior-preserving
refactor now passes lint and focused checks; frozen review and the corrected final
full gate remain. See `receipts/006-U11-additional-native-packet.md`.

Latest October 11 checkpoint: the completed frozen offline run measured 98.36%
coverage, 1,546 tests, one MR-guard fixture failure and six skips. The exact
test-only freshness correction passed its selected case; standalone Dialyzer
passed. The user approved 98.0%, now read back from `mix.exs`. Original nonzero
full-run exits remain retained; this is composite evidence, not a relabelled
`make all` success. A fresh bounded native fixture's genuine projectless parent
bootstrap is now `SUCCEEDED`, with empty attachments and successful actual
context execution. Initial model-free delivery preparation and native human
amendment/rework remain incomplete. See
`receipts/006-U11-fresh-amendment-packet.md`. No production action or enablement
has occurred.

1. Audit every unit's receipts against current source and original end-state requirements.
2. Run full `mise exec -- make all` once for frozen source. Report skips, dependency
   warnings and coverage accurately; fixes rerun affected checks before the final gate.
3. Obtain an explicit synthetic native acceptance budget before model turns. Proposed
   admission ceiling for approval: ≤12 total parent/worker/broker-driver turns, ≤30 minutes
   active runtime; record actual tokens. No hidden retries, upgrade or cap extension.
4. One projectless Desktop parent: real human question/answer, controller worker/result
   summary, same parent after controller restart, fresh blind review, optional validator,
   contract amendment and direct ticket-chat rework on the same source checkout. Source rework
   invalidates old PASS; demonstrate fresh exact-candidate verification. No real ticket trial.
5. Independent readback proves origin, identity, reservations, owned-process shutdown,
   exact SHA and external mutation reconciliation. Native UI opening/response is observed,
   not merely a navigation acknowledgment. Record each unsupported capability explicitly.
6. Only after separate commit/push/deployment approval deploy disabled and verify service
   health with synchronous status/context reads. Enabling a pilot is another explicit gate.
   Read and preserve the scheduler/broker's actual pre-deployment active/paused state;
   do not resume legacy work or automations as a side effect of health verification.

The user approved a 98.0% coverage threshold on October 11, 2026, replacing the
October 9 approval of 98.5%; current `mix.exs` applies 98.0%. Preserve all other
exclusions/checks and historical gate results. For the final
offline gate, explicitly disable inherited tracker live-test opt-ins:

```sh
HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 SYMPHONY_RUN_ASANA_LIVE_E2E=0 \
SYMPHONY_RUN_GITHUB_LIVE_E2E=0 SYMPHONY_RUN_GITLAB_LIVE_E2E=0 \
SYMPHONY_RUN_JIRA_LIVE_E2E=0 mise exec -- make all
```

The Makefile performs setup/dependency retrieval, escript build, formatting,
specs/Credo, coverage and then dependency retrieval/Dialyzer sequentially. An
earlier failure is not proof later checks passed; warnings-as-errors compilation
is a separate check. Existing deps/build/PLT presence does not prove offline
completeness, and this command does not authorize upgrades or implicit recovery.
Retain the full log, exit status, actual seed/test/skips/coverage and Dialyzer
outcome alongside start/end source and gate-input hashes. Live-test skips do not
prove native acceptance. Tagged GitLab feedback remains deferred.

Done for this split means the ordinary Required: no path works end-to-end with its real
proofs and Required: yes remains explicitly fenced. This does not complete the separate
required-validation follow-on. STOP if any required evidence is missing; preserve disabled
mode.

## Review receipt and operator report template

Store under `plans/receipts/006-Uxx-<snapshot-id>.md`:

```text
Unit / original slice:
Baseline HEAD + dirty-source manifest:
Frozen changed-file hashes:
Requirement IDs fulfilled:
Production behavior changed:
Tests added/extended and why:
Exact executed commands, exit status, skips and artifact paths:
Independent RED/green check:
Native/external observations versus fixture-only claims:
Unresolved findings / authority needed:
Model, reasoning, measured usage and elapsed time:
Reviewer verdict: ACCEPTED | FIX_REQUIRED | NEEDS_DECISION
Operator decision: not yet authorized | authorized next unit <id>
```

Human report after each stop: what now works, what was tested, what is still missing,
and the single next unit/decision. Do not call an unimplemented executor “done” because
its parser or binder passed. Do not continue based on an automatic goal heartbeat.

## Overall STOP conditions and maintenance notes

- Unexplained source/ownership drift, a second writer or missing temporary checkout.
- Repeated focused failure, out-of-scope change or an unresolved service/tool contract.
- Capability proof requires private RPC, global permission changes or broader worker access.
- Missing machine-readable claim/readback, synthetic-input proof, no-DDL deployment or
  safe restoration. Those are real prerequisites; present a bounded proposal, not a bypass.
- Any new work item not traceable to original Slices 3–5. Put it in a deferred list and ask.
- Native spend/turn/time admission ceiling reached; no automatic extension.

Future runtime/schema changes invalidate only the affected evidence; maintain exact
candidate/contract lineage. Keep tests mapped to invariants rather than accumulating
guards without a demonstrated failure. Cleanup and real feature trials remain separate.

## Cold plan review

GPT-6.1 Sol/high independently read the complete plan/index/manifest and original
remaining Slice 3–5 requirements. Its first review required explicit execution-packet
readiness, compensation authority, capacity checks, missing diagnostics and removal
of stale index directions. Those were incorporated. The second review accepted the
gated handoff with no residual must-fix findings. It did not certify unknown native
interfaces, backend/profile safety or runtime acceptance. See
`plans/receipts/006-plan-cold-review.md`. No implementation/test/deployment was run
as part of that review; source checksums still match the planning baseline.
