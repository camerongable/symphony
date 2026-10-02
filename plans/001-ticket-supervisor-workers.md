# Plan 001: Introduce one ticket chat with bounded role workers

> Executor instructions: This is a gated implementation plan. Finish step 1A
> before the disabled foundation. Step 1B and full integration acceptance are
> required before admitting work or enabling the new transport. A missing capability is a
> concrete result, not permission to invent an API or quietly weaken review.
> Run each verification command; update `plans/README.md` after each accepted
> slice. No production ticket migration or feature implementation is authorized
> by this plan alone.
>
> Drift check: from `/Users/cgable/Repos/symphony`, run
> `git diff --stat bc7c28c5f7d79f37cfaf0d2c3ea873f758147863..HEAD -- elixir/lib elixir/test elixir/README.md elixir/WORKFLOW.md`.
> Compare changed symbols to the excerpts below. Inspect unstaged changes too.
> Resolve overlap with the owner before editing; never revert another writer.

## Status

- Priority: P1
- Effort: L; capability proof first, then independently verified slices.
- Risk: HIGH at runtime provenance and shared-checkout boundaries.
- Category: architecture / migration / reliability.
- Planned at: `bc7c28c5f7d79f37cfaf0d2c3ea873f758147863`, 2026-10-01.
- State: adversarial review and source investigation complete; disabled implementation authorized.
- Depends on: step 1A for foundation; step 1B for execution admission, not completion of native archival.

## Outcome and why

The user should have one stable place to ask questions, answer contract questions,
and follow a ticket. Specialized workers still do implementation and independent
review, but their identities are execution details, not separate user-owned chats
with a newly allocated checkout for each role. One source checkout is reused
sequentially across writing, repair, verification, and review feedback.

The change targets real coupling: stage identity currently also determines chat,
bootstrap, checkout, and permission routing. It does not promise fewer code bugs,
automatic cleanup, or lower tokens simply because workers become subagents.
Retain exact-candidate gates and measure the resulting handoffs, waits, token
usage, and allocations before extending the pilot.

## User-visible workflow and authority

| Step | Ticket chat | Worker and context | Checkout and authority |
| --- | --- | --- | --- |
| Intake | Created once, then reused for this ticket/route | None for mechanical admission | SQLite scheduler admits authorized work; no source writes |
| `spec-needed`, when actually requested | Shows concise questions/results | Author and fresh critic, only when needed | Contract operations remain controller-owned; no source checkout required |
| `ai-ready` | Receives delivery objective | Writer does bounded planning and implementation | Allocate one isolated source checkout; skip author/critic/planner as today |
| Additional slices or repair | Same chat summarizes real progress | One writer at a time; continuation may reuse its worker if supported | Same branch/checkout and preserved candidate; no restart from scratch |
| Candidate review | Same chat receives the verdict | New blind verifier for every candidate/round | Writer stopped; same clean checkout frozen at the exact SHA; source read-only |
| Delivery / CI wait | Shows actual CI/MR state | No model just to poll waiting CI | Existing controller pushes/creates or updates MR under existing policy |
| Required live validation | Same chat receives evidence/outcome | Validator only if the confirmed contract requires it | Exact pushed SHA; existing non-production/Slack/synthetic-data rules |
| GitLab question | Same chat can coordinate the explanation | No writer unless there is an explicit edit request | Reply in original discussion; no checkout restoration for conversation |
| GitLab edit batch | Same chat receives the whole authorized batch | Same-run writer, then a fresh verifier | Same checkout/branch/MR; no respecification or new planner |
| Idle / awaiting user | Accessible, no recurring thinking turn | No idle worker or model wake | Durable ledger and ordinary scheduler reads only |

"Blind" means no implementer or supervisor conversation, plan narrative, prior
verdict, or claimed success in the verifier input. Supply the confirmed contract,
revision/digest, exact candidate, immutable review base SHA, relevant authorized
feedback, and independently observed CI/check evidence. Source and repository
instructions are still visible. This is independent review, not a claim of
cryptographic isolation from all information an author could place in code.

The selected execution architecture is **factory-launched workers** using the
supported app-server interface, reporting to the one ticket chat. A native
parent-child relationship is not a requirement. This avoids relying on inherited
parent permissions to give the writer more access than the supervisor, and avoids
a parent model turn merely to spawn every role. Keep native parent delegation
outside this implementation; do not add two production transports at once.

"One chat" means one stable user-owned ticket conversation. Independent workers
still have internal execution/thread IDs and inspectable evidence; do not promise
that the Codex client cannot surface their activity. Prove client visibility and
restart behavior before claiming the UI footprint has been reduced.

The ticket supervisor is not the existing scope-wide factory controller. The
deterministic scheduler and SQLite remain the only delivery-routing authority.
The supervisor may request a bounded job and present a result; it cannot mint
authorization, override a verdict, commit/push, change labels/status, or manufacture
provider receipts. Existing controller-owned mutations remain controller-owned.

### Enforced principal matrix

| Principal | Source access | Allowed coordination/mutations |
| --- | --- | --- |
| Ticket parent | Read-only, no source checkout allocation | Questions and summaries; typed work requests validated by controller; no unrestricted delegation or connector mutations |
| Writer worker | Workspace-write only to its reserved source and approved outputs | Edits named candidate paths; no push/MR/Jira operations |
| Fresh verifier | Source and Git metadata read-only; only approved external output paths writable if needed | Code/contract review and exact check receipts; no delegation or connector writes |
| Validator | Source read-only; separately authorized test/deploy capabilities | Existing non-production validation scope only |
| Factory controller | Guarded source commit/push and scoped connectors | Sole owner of ledger transitions, source admission, commit/adoption and delivery |
| Desktop broker | No feature-source edits | Exact parent CREATE/FOLLOWUP and readback only |

The workspace guard is not a sandbox. Enforce parent and worker policy at the
supported runtime boundary and deny unneeded mutating connectors/dynamic tools.
Parent source tools and spontaneous delegation cannot bypass REVIEW ownership.
If a Desktop-bound parent cannot retain these restrictions, do not start it in
production and do not treat a prompt as a substitute.

### Adversarial findings investigated before implementation

A fresh reviewer challenged the complete initial plan. Source reads confirmed:

- **Dependency cycle:** full controller/worker restart proof required primitives
  that later steps had not built. Corrected to offline characterization, disabled
  foundation, bounded primitive runtime proof, then integration acceptance.
- **Parent privilege bypass:** StageRunner lacks per-role policy plumbing and
  AppServer currently loads global policies. Corrected with the principal matrix
  and factory-launched workers; native delegation is not the chosen authority seam.
- **Mode persistence:** RunLedger's fixed insert/update allowlists would drop a
  new execution field. Added its API/tests and immutable recorded-mode semantics.
- **Review context leak:** the full Jira snapshot can contain old conversations.
  Added an allowlisted packet and pinned review-base SHA instead of full snapshot.
- **Early event loss:** `handle_response/5` at app_server.ex:1730-1746 drops
  notifications before the expected response. Characterization now covers buffering
  before `turn/start` returns as well as later thread/turn correlation.
- **Release gap:** source ownership must span result recording, Git commit/adoption
  and ledger consumption. Worker completion alone does not release the checkout.

These are design/parser risks established by source inspection, not a claim that
all six have occurred in live ticket runs. Native-cleanup restrictions remain valid.

## Investigation: established facts and remaining proof

Source inspection and two independent read-only investigations were performed
against the checkpoint. No source implementation, paid runtime experiment, live
ticket mutation, deployment, or test suite was run in this planning turn.

1. `factory_tasks` provides the canonical stage `task_key`, thread, and turn.
   `runs.task_id` is overloaded: TaskLauncher writes a task key during preparation,
   then a thread ID on start. Do not use it as a ticket supervisor identity.
2. Both current transports create durable role threads. Native nonwriters are
   expected to have separate clean detached worktrees. Shared review must be an
   explicit new mode, not a weakening of that legacy mode.
3. The existing `ai-ready` path already goes directly to writer admission. This
   redesign must not reintroduce a planner or specification pass.
4. The installed CLI is `codex-cli 0.159.2`. Its generated experimental schema has
   `collabAgentToolCall` items with `senderThreadId`, `receiverThreadIds`, `id`,
   `status`, and `agentsStates`. This is observable collaboration evidence, not
   a client-side spawn RPC. `ClientRequest.json` has no dedicated spawn-agent
   request. Native delegation is a parent model tool interaction.
5. `ThreadForkParams.excludeTurns` and `ThreadResumeParams.excludeTurns` mean
   omission of turns from the returned response. They do not prove a fresh model
   context. `multiAgentMode` is deprecated/ignored in the installed start schema.
6. The current AppServer completion parser and StageRunner output collector do
   not correlate all events with expected thread/turn identity. Child event
   interleaving would be unsafe if delivered to that stream. Actual native event
   fanout has not been proven; this is not a claim of an observed production bug.
7. Desktop creation arguments do not expose role-specific sandbox/cwd overrides.
   A reviewer prompt, or a default in a custom agent file, is not permission proof.
8. Native archive/restore production acceptance remains incomplete. The current
   native-cleanup flag is rejected if enabled. Do not bypass it for this redesign.

Official references checked on 2026-10-01:

- [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents):
  parent-driven delegation, child activity, model selection, and inherited/live
  permission controls. Documentation does not establish our restart acceptance.
- [Codex app-server](https://learn.chatgpt.com/docs/app-server): version-specific
  schema generation, thread/turn lifecycle, stored-thread readback and resume.

Regenerate the local schema during step 1. Do not implement from a documentation
example when the installed callable interface disagrees.

## Current state excerpts and seams

All paths below are relative to `/Users/cgable/Repos/symphony/elixir`.

`factory/task_launcher.ex:94-143,238-247` binds a role task and changes the
overloaded active-task field:

```elixir
task_key: task_key,
run_id: run["run_id"],
stage: stage,
role: route.resolved_role,
thread_id: reusable_thread_id,
# Later in on_thread_started:
RunLedger.update(store, launch.run["run_id"], %{task_id: thread_id})
```

`factory/desktop_stage_runner.ex:27-37` supplies existing durable transport keys:

```elixir
[target_key, previous_turn_id || "FIRST", prompt]
|> Enum.join("\u0000")
|> then(&:crypto.hash(:sha256, &1))
|> Base.encode16(case: :lower)
```

`factory/desktop_request.ex:588-594` enforces legacy native checkout policy:

```elixir
expected_branch: native_expected_branch(request, task, run),
clean: not TaskLedger.source_writer?(task) or request["action"] == "CREATE",
detached: request["action"] == "CREATE" or not TaskLedger.source_writer?(task)
```

`factory/scheduler.ex:2241-2261` creates a fresh verifier task per round:

```elixir
task_key = "#{run["run_id"]}:change-verifier:#{run["verifier_round"]}"
# stage_spec retains:
role: "change-verifier",
persistent?: false,
expected_sha: expected_sha
```

`factory/scheduler.ex:2992-3049` transactionally consumes a native writer result,
commits its exact named paths through the controller, updates candidate/iteration,
and advances to CI preflight or verification. Preserve this single owner.

`codex/app_server.ex:1163-1165` currently ends a turn on any completion event;
`factory/stage_runner.ex:153-159` collects any non-commentary agent message.
These must not consume another worker's report under the new mode.

`factory/mr_feedback_rework.ex:261-307` checks maintenance reservation and current
writer/candidate inside its admission transaction. Its pending-batch queries at
116-142 currently expect scope-controller ownership. Preserve legacy recipients
while introducing ticket-chat recipient provenance.

`factory/native_workspace_maintenance.ex:182-188` explicitly says supported
attachment probing is not archive/restore authorization. Native runs remain
excluded from legacy filesystem deletion.

Match `Store.transaction!/2`, `TaskLedger.update_if_current/5`, strict
`StageSchemas`, and existing `{:ok, value}` / `{:error, reason}` conventions.
Tests should follow the temporary SQLite/real Git fixtures in
`test/symphony_elixir/factory_full_lifecycle_test.exs` and
`factory_desktop_stage_runner_test.exs`; use fake providers only at external
seams, not fake ledger transitions.

## Scope and boundaries

Allowed implementation files, only as needed by the numbered slices:

- Existing: `lib/symphony_elixir/config/schema.ex`, `codex/app_server.ex`,
  `factory/{store,task_ledger,task_launcher,desktop_request,desktop_stage_runner,desktop_tool_args,stage_runner,stage_schemas,prompt,scheduler,recovery,model_router,policy,contract_chat,mr_feedback_consumer,mr_feedback_rework,native_workspace_maintenance,observability,pilot_report}.ex`.
- Also `factory/run_ledger.ex` and `test/symphony_elixir/factory_run_ledger_test.exs`
  for immutable run-mode persistence; `factory_store_migration_test.exs` for upgrade.
- New: `factory/{ticket_chat,ticket_worker_runner,worker_evidence,workspace_access}.ex`.
  Do not add a general-purpose graph framework or a second worker queue.
- CLI: `lib/mix/tasks/factory.desktop.ex` for generated arguments/evidence
  receipts; optional `factory.ticket_pilot.ex` for the isolated acceptance harness.
- UI: `lib/symphony_elixir_web/live/dashboard_live.ex` for ticket-chat/worker links
  and execution/attention projection, not a visual redesign.
- Tests: sibling tests for those modules; new
  `factory_ticket_chat_test.exs`, `factory_ticket_worker_runner_test.exs`,
  `factory_worker_evidence_test.exs`, `factory_workspace_access_test.exs`, and
  `factory_ticket_supervisor_lifecycle_test.exs`.
- Docs: `README.md`, `WORKFLOW.md`, root `README.md`,
  `../docs/factory-control-plane.md`, `../SPEC.md` only if required for consistency,
  and this plan/index.
- Canonical external instructions: update
  `/Users/cgable/.agents/skills/service-factory-desktop-requests/SKILL.md` with a
  narrowly routed `references/ticket-workers.md`; add an explicit supervised
  shared-review mode to `/Users/cgable/.agents/skills/verify-feature-delivery/SKILL.md`
  and its verdict reference. Preserve legacy detached mode. Read those files
  fully before editing. Use the skill-authoring rules, no provider-specific copies.
  Archive/version their prior contents separately before changing them; the source
  checkpoint does not contain these external files.

Out of scope: Grail/Polaris feature source, live ledger edits, historical chat
replacement/archival, global Codex configuration, new Jira contracts/tickets,
model allocation redesign, reviewer policy relaxation, global cache sweeps,
native archive enablement, GitLab webhook infrastructure, and private Codex RPCs.

## Commands and Git workflow

Run implementation checks from `/Users/cgable/Repos/symphony/elixir`:

| Purpose | Command | Expected result |
| --- | --- | --- |
| Scoped tests | `mise exec -- mix test <test paths named in each step>` | Exit 0, no failures |
| Public specs | `mise exec -- mix specs.check` | Exit 0 |
| Formatting check | `mise exec -- mix format --check-formatted` | Exit 0 |
| Whitespace | `git diff --check` | Exit 0 |
| Final quality gate | `mise exec -- make all` | Build, format, strict lint, configured coverage, Dialyzer pass |

The previous implementation gate was recorded as 816 tests, zero failures,
six skipped and 100% configured coverage. Many legacy modules are excluded from
that coverage denominator: do not interpret 100% as full workflow acceptance.
Do not rerun paid/live E2E automatically. Implement focused tests per slice;
follow the repository gate rather than running Grail/Bazel package sweeps.

Keep a dedicated feature branch, preserve unrelated changes, and stage named
files only. User-authorized commits use `git commit --no-verify`; no push or MR
creation without explicit authorization. The checkpoint commit is not a deployed
database rollback; future rollback preserves additive records and reconciles them.

## Steps

### 1A. Characterize the installed protocol offline

First add offline protocol fixtures in `app_server_test.exs` and a test-only
ticket lifecycle harness. Generate schemas without calling a model:

```sh
task_schema_dir=$(mktemp -d /tmp/symphony-ticket-schema.XXXXXX)
codex --version
codex app-server generate-json-schema --experimental --out "$task_schema_dir"
```

Characterize parent/child correlation and installed callable schemas. Buffer early
events while awaiting `turn/start` so matching output/completion is not discarded;
wrong-thread/turn messages must never terminate the current turn. A native
parent is created/followed up through the Desktop broker, never resumed by an
unrelated app-server process or silently forked. Inventory actual parent
delegation tools before attempting them; tool names in a schema do not prove
the target chat has them. Native delegation is not required by the selected route.
Test-only harness files may use disposable Git repositories, bare remotes and
SQLite databases. They must not access the live workflow/database, restart the
service, bypass production guards, or report fake-provider behavior as runtime proof.

**Verify:** `mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/factory_desktop_stage_runner_test.exs`
→ characterization fixtures pass with parent/child interleaving, early output,
completion/failure/cancellation before response and duplicate terminal events.
Default-off identity/reservation implementation can follow this offline gate.

### 1B. Prove isolated runtime primitives before execution admission

After disabled foundation/policy plumbing exists, use the installed supported
runtime against one disposable fixture. Worker processes are launched by the
factory, not by a parent model tool. A fresh verifier uses `thread/start`, never
fork/resume of parent or writer. Do not assume an in-memory/ephemeral worker can
resume after process death; choose and record persistence semantics from readback.

An isolated synthetic test, after authorization to execute the plan, must prove:

- Exactly one user-owned parent chat, unchanged Project/route, and one source
  checkout; no primary-repository source execution.
- Writer worker performs one test-owned change under its effective policy. The
  disposable harness records the change and establishes a clean pinned candidate
  for the verifier; production controller commit/adoption acceptance is in step 8.
- A fresh verifier cannot read a unique parent/writer-only context canary. Check
  actual new-thread inputs/history, not just whether the worker repeats the canary.
- Effective verifier access rejects an inert tracked/untracked source-canary
  write, while any permitted build outputs are outside source; no broader access
  is granted. The source HEAD/ref/status remain identical before/after review.
- Worker ID, role/model/effort, input digest, explicit parent linkage, actual cwd,
  terminal output and result item are independently readable by the broker.
- Closing/reopening the isolated harness/runtime demonstrates whether worker
  history/results can be read back. Transactional job restart/consumption is tested
  after its implementation, in step 8. Never restart the live service for this probe.
- The parent returns while idle; no autonomous goal/heartbeat keeps spending.

Bound the synthetic proof to one fixture, at most six parent turns and four
worker launches. Stop at that bound and report precise outcomes. This is a
feasibility budget, not permission to keep retrying an uncertain spawn. No real
tickets, push, MR, archive, restore, or filesystem cleanup for the proof.

If fresh-context controls, permission enforcement, parent policy, worker result
readback or restart identity cannot be proven, record the exact gap. Disabled
foundation can remain; do not silently choose another runtime or enable admission.

**Verify:** retain synthetic protocol frames, effective policies, direct worker
reports and independent Git checks. Execution admission requires every criterion
above. Full commit/adoption/restart integration acceptance follows steps 2-7;
it is not a prerequisite to writing their default-off foundation.

### 2. Separate ticket conversation identity from execution records

Add default-off `factory.ticket_supervisor.enabled` and an empty
`pilot_issue_keys` allowlist in Config/Policy. Save execution mode on new runs;
changing configuration does not reinterpret an existing run or request.
Use `execution_mode` with `LEGACY` (including null on historical rows) and
`TICKET_SUPERVISOR_V1`. RunLedger registration persists it; updates cannot change
it, including mixed updates with state. Add validation/readback and migration tests.
Until runtime acceptance exists, enabling the flag must fail startup with a
specific capability-unproven error rather than create partially supervised work.
Foundation commit stores metadata only and dispatches no new-mode jobs.
Scheduler must reject any recorded `TICKET_SUPERVISOR_V1` run at its existing
transport-validation boundary until the runner exists, even if inserted through
a test/admin path. Do not let unsupported metadata fall through to legacy launch.

Add a `ticket_chats` mapping through Store: opaque `chat_key`, issue/repository
route and Project, exact parent thread/creation request, created timestamp.
One mapping per ticket plus repository route/Project; never infer it from title
or `runs.task_id`. Link specification, delivery, validation and contract-discussion
runs explicitly to this mapping when the mode is selected. Keep lifecycle state
in `runs`; the mapping contains no parallel WRITING/VERIFYING state machine.

Retain existing per-stage `factory_tasks` and writer task-key semantics. Add
immutable `ticket_worker_attempts` records for each bounded invocation: attempt
key, task/run/chat key, parent thread/turn, role route, prompt/input digest,
revision/contract digest, candidate or parent SHA, workspace identity, generation,
child thread/turn/result-item IDs, outcome and evidence. Keep earlier receipts
when a persistent writer task gets another pass.

Register the ticket supervisor as a normal `TASK` target with a stable key owned
by its recorded initial run; ticket/run links permit later runs to reuse it.
Extend supervisor target validation explicitly rather than rewriting legacy task
provenance. A worker is not a second `create_thread` request. No new queue is needed.

Use one deterministic attempt key from task, authorized input event, prompt digest,
revision/digest and expected SHA. Duplicate ticks return the same reservation.
Generation changes are explicit after proven termination, not wall-clock expiry.
Migrations are additive/idempotent and leave old rows/request hashes unchanged.
Audit every scheduler `native_transport?` branch and `validate_run_transport/2`;
recorded supervised routing must not use the mutable global transport flag.
Keep legacy-null interpretation unchanged; test legacy and supervised metadata
coexisting through flag disablement and restart before implementing dispatch.

**Verify:** `mise exec -- mix test test/symphony_elixir/factory_store_migration_test.exs test/symphony_elixir/factory_ticket_chat_test.exs test/symphony_elixir/factory_desktop_request_test.exs`
→ same parent survives run-kind changes/restart, duplicate initialization succeeds,
wrong Project/title-only matching is rejected, legacy rows and hashes are unchanged.

### 3. Admit exclusive source/review/maintenance capabilities

Implement `WorkspaceAccess` as a transactional guard, not a lifecycle engine.
Key it by canonical source path plus verified repository identity; HEAD is checked
as a precondition, not included in the mutex key. Otherwise two different SHAs
could acquire ownership of the same directory.

Use a small reservation table with workspace identity, run/task/attempt/request,
capability (`SOURCE`, `REVIEW`, `MAINTENANCE`), generation and acquired/released
timestamps. A partial unique index permits only one unreleased owner per checkout.
Ownership is never released just because a lease timestamp elapsed. SOURCE is held
through worker completion, receipt recording, controller commit/adoption and
transactional candidate/task consumption; only then may matching generation release.
Crash after Git commit but before ledger update retains SOURCE for exact adoption.
Completion,
crash recovery, maintenance admission and review-feedback admission consult the
same guard, within their existing Store transactions.

Also prevent a SOURCE reservation while any existing source task/request, native
turn or unresolved maintenance owns that checkout. REVIEW needs no live writer,
clean status including untracked files, expected branch and frozen exact candidate.
Missing checkout is an availability/recovery reason, not a new bootstrap. Writer
capacity checks remain mandatory before new writing/rework; idle parent chat and
CI wait do not count as active source workers.

**Verify:** `mise exec -- mix test test/symphony_elixir/factory_workspace_access_test.exs test/symphony_elixir/factory_native_workspace_maintenance_test.exs test/symphony_elixir/factory_mr_feedback_rework_test.exs`
→ distinct task keys, symlink aliases, competing restore/probe and duplicate ticks
cannot acquire concurrent capabilities; ambiguity/restart retains ownership;
confirmed completion releases only its matching generation.

### 4. Transport bounded workers and consume their actual results

`TicketWorkerRunner` is selected by TaskLauncher only for recorded supervisor-mode
runs. The scheduler starts the reserved worker using the supported app-server
thread/turn interface; the parent does not need a thinking turn to launch it.
DesktopStageRunner/Request handle parent CREATE/FOLLOWUP and meaningful summaries
with existing uncertain-write semantics. Add typed runtime policy plumbing to
StageRunner/AppServer; parent/verifier do not inherit the writer's sandbox.
The broker reference describes conversation/readback, not unrestricted delegation.

Apply ModelRouter's saved role/model/effort explicitly to each worker. Use a
fast/low `ticket-supervisor` role for mechanical coordination and short summaries;
never let a custom-agent default silently replace the writer/verifier allocation.
Do not change the scope-wide broker or controller models here.

Allow the writer to choose coherent implementation slices within existing budgets.
Do not add a planner turn for `ai-ready`. A worker can ask a substantive question,
but a machine schema-repair operation cannot restart source work or external writes.

`WorkerEvidence` validates provider-observed worker execution identity, explicit
durable parent linkage, exact worker result and current attempt/input/workspace generation before storing
the role output. Parent paraphrases cannot count as verifier PASS. If the selected
interface does not persist a freshness/permission field, retain actual new-thread invocation
and execution evidence from step 1; do not invent that field as proof.

Correlate events with expected thread AND turn in AppServer and StageRunner.
Child output/completion cannot overwrite or terminate parent output. Unknown or
missing ownership under the supervised mode is reconciliation, not acceptance.
Persist a completion receipt before presenting/summarizing it; duplicate receipt
is idempotent, changed bytes for the same identity are rejected.

**Verify:** `mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/factory_ticket_worker_runner_test.exs test/symphony_elixir/factory_worker_evidence_test.exs test/symphony_elixir/factory_desktop_tool_args_test.exs`
→ wrong-parent/wrong-turn/replayed/stale-contract results fail; interleaved child
events cannot complete the parent; one uncertainty keeps one request and worker;
the effective saved role allocation is read back rather than inferred.

### 5. Reuse the source checkout for blind review and optional validation

Introduce explicit `TICKET_SOURCE` and `TICKET_FROZEN_REVIEW` workspace modes.
Validate allowed route, checkout ownership and guard generation in these modes.
Do not relax legacy `CODEX_NATIVE` detached checks or call its bootstrap for a
reviewer. Keep `runs.worktree` and the canonical feature-writer binding on the
same authoritative source path throughout supervised delivery.

Update scheduler workspace selection/removal: a supervised reader uses the
frozen source path; stage cleanup never removes that path. Preserve writer
commit/consume transactions, CI-preflight exception, verifier rounds, REPAIR/BLOCK
handling, and controller-owned push/MR stages.

Update verifier prompt and canonical verifier skill with the new explicit mode.
Old standalone/detached behavior remains unchanged. Build the verifier packet
from ledger-authorized inputs, not the supervisor summary or writer transcript.
Resolve the base to an immutable SHA. A new/repaired candidate always gets a
new blind verifier worker; no reuse of the prior verifier's conversation.

Use a strict allowlisted review packet with exactly: `issue_key`, `run_id`,
`attempt_key`, `spec_revision`, `contract_sha256`, `contract_markdown`,
`candidate_sha`, `review_base_sha`, `workspace_identity`, `reservation_generation`,
`authorized_feedback` (current note IDs/body digests/bodies only), and
`observed_checks` (provider receipts bound to that SHA). Exclude full snapshot,
Jira comment history, plan, implementer claims, parent summaries and prior verdicts.
Store the resolved base SHA in the attempt before launch; compare the reported
base to that value, never to a newly moving remote branch. Insert context canaries
in prohibited fields and assert they are absent from actual provider inputs.

Before review, prove writer termination and exact clean SHA/ref. During review,
enforce source read-only with the mechanism proven in step 1. After review,
recheck SHA/ref/cleanliness before accepting PASS. Post-review checks detect
drift; they are not a replacement for preventing writes during review. Checks
needing writable output use only isolated approved temporary/cache paths or
exact-SHA CI evidence. Do not grant repository write access to make a check run.

For a required validator, preserve its own role and evidence gates. Resolve a
parent delivery path through explicit run links, not a new source clone. Use
approved external build/deployment outputs; source modifications are not allowed.
If a contract requires capabilities incompatible with shared read-only source,
stop with the exact capability gap instead of creating an extra checkout silently.

**Verify:** `mise exec -- mix test test/symphony_elixir/factory_scheduler_test.exs test/symphony_elixir/factory_ticket_supervisor_lifecycle_test.exs test/symphony_elixir/factory_workspace_access_test.exs`
→ two writer passes, repair and fresh verification use one source path; native
legacy readers remain detached; branch/SHA/untracked drift blocks delivery;
required validation cannot be skipped and no reader removes the source checkout.

### 6. Route questions and MR feedback through the ticket chat

Adapt ContractChat and broker question receipts to resolve the existing ticket
chat, retaining exact question/user-message/turn provenance. A chat answer is not
automatically an authorized revised contract. Keep Jira write/readback, explicit
confirmation policy and fresh critic checks where the current contract-update
path requires them. Successful rearm retains the completed branch/candidate and
writer history; it does not erase progress or restart specification arbitrarily.

For MR feedback, retain batch-by-MR and explicit-edit classification. Conversation
replies go to the original GitLab discussion; edit batches reopen the existing
delivery run and use the same supervisor/source checkout/MR. Support both old
scope-controller recipient provenance and new ticket-TASK recipient provenance
in MrFeedbackConsumer/Rework queries. Never reinterpret unresolved old receipts.

User input arriving during review queues safely. It does not launch a concurrent
writer or mutate the contract for a running verifier. Do not automatically resend
an ambiguous source turn, create a replacement parent, or fabricate approval.

**Verify:** `mise exec -- mix test test/symphony_elixir/factory_contract_chat_test.exs test/symphony_elixir/factory_mr_feedback_consumer_test.exs test/symphony_elixir/factory_mr_feedback_rework_test.exs test/symphony_elixir/factory_recovery_test.exs`
→ questions/answers stay in the parent; full feedback batch preserves contract,
iterations, checkout and MR; conversations create no writer; stale input and
legacy unresolved receipts remain protected.

### 7. Make idling cheap and recovery inspectable

Supervisor turns are event-driven: admitted source job, bound worker completion,
actual user input or substantive feedback. Waiting on CI, missing capacity or
unchanged ledger state never wakes a model merely to say "still waiting".
Cap a mechanical supervisor turn to one reserved job/summary, not an infinite
run-until-done goal. Ordinary scheduler ticks can continue read-only reconciliation.

Recovery first reads the original parent/child request. Running child means wait;
completed child means ingest its exact receipt; uncertain spawn means reconcile
the same intent, not create again. A confirmed stopped writer with no terminal
receipt preserves dirty source and needs bounded same-checkout reconciliation
before a replacement attempt. Read-only retries can create a fresh worker only
after termination is proven and expected candidate/input remain current.

Observability links to the ticket chat and lists bounded worker attempts as
inspectable details. The dashboard state comes from runs/requests, not parent
prose. Show current stage, actual worker/wait, exact failure/recovery reason, and
candidate. Keep raw logs outside the long-lived parent; cap summaries at 2 KB.

Extend PilotReport using actually observed usage events where available:
parent/worker tokens, model route, execution versus wait time, worker count,
source checkout count and bytes. Missing usage is `unavailable`, never zero.
Set measurable pilot limits: one user-owned ticket chat, one source checkout,
zero model turns across twenty unchanged scheduler ticks, no duplicate external
write, no manual technical handoff repair.

**Verify:** `mise exec -- mix test test/symphony_elixir/factory_recovery_test.exs test/symphony_elixir/factory_observability_test.exs test/symphony_elixir/factory_pilot_report_test.exs test/symphony_elixir/factory_ticket_supervisor_lifecycle_test.exs`
→ crash injection at reservation/spawn/result/commit/consumption boundaries keeps
identities and dirty source, twenty no-op ticks launch nothing, UI and report
match ledger without treating missing usage as free work.

### 8. Gate rollout, preserve rollback and keep cleanup separate

First deploy disabled after authorized commit/push/restart and final gates.
Enable only one explicitly approved new pilot ticket/fixture after step 1 passes.
Do not migrate PPL-9723/PPL-10035 or historical role chats automatically. Future
eligible tickets may switch to default only after the pilot's acceptance record
is reviewed; existing recorded-mode runs drain under their original transport.

Use a real temporary Git repo/bare remote with fake Jira/GitLab seams for final
offline lifecycle acceptance: direct `ai-ready`, two source passes, fresh verifier,
CI wait/transient retry, one MR, optional validation, batched review edit and
restart at each boundary. Measure allocation rather than inferring it from names.
Obtain a read-only adversarial review of frozen implementation before live enablement.

Disabling supervisor admission prevents new supervised runs, but reconciliation
of admitted jobs, questions, restoration and receipts continues under their
recorded mode. Do not downgrade a running supervisor run to legacy per-role
bootstrap. Retain additive schema and durable evidence when rolling back code;
if older code cannot safely read admitted records, disable admissions and drain
with the compatible build instead of checking out the old commit on a live DB.

Native archival stays disabled. One source checkout per new run materially
reduces per-role allocations; it does not prove that the remaining checkout can
be removed while the chat stays usable. That acceptance remains a separate work
item. Preserve existing archive/restoration prerequisites and Bazel ownership
rules; never classify a native checkout as legacy-owned to reclaim it.

**Verify:** `mise exec -- make all` and `git diff --check` → all gates pass;
the offline acceptance harness confirms one source checkout and exact-SHA
delivery. Authorized deployment must confirm service health synchronously via
the existing factory API/status command, then read back recorded pilot mode.

## Acceptance checklist

- [ ] Step 1 proves the installed transport; uncertainty is documented, not hidden.
- [ ] One stable user-owned chat spans specification/delivery/feedback for the
  same ticket and repository route; actual child activity remains inspectable.
- [ ] `ai-ready` still omits specification/critic/planner passes.
- [ ] One source checkout is allocated and retained across writer slices, repair,
  verification and feedback; no source work occurs in a primary/control checkout.
- [ ] Fresh verifier worker receives only the allowed packet and has enforced
  read-only source access; controller cannot substitute a summary for PASS.
- [ ] SOURCE/REVIEW/MAINTENANCE mutual exclusion survives restart and uncertainty.
- [ ] Exact contract/candidate/generation mismatch fails; legacy modes are unchanged.
- [ ] One existing lifecycle owner consumes receipts and commits/pushes/drafts.
- [ ] Waiting/no-op ticks cause no parent/worker model turns.
- [ ] Questions and GitLab batches preserve provenance, same-run progress and MR.
- [ ] Tests per slice, frozen adversarial review, final gates and bounded synthetic
  acceptance pass; live pilot is explicitly distinguished from offline tests.
- [ ] Cleanup remains gated separately; no chats or historical worktrees deleted.
- [ ] Rollback keeps in-flight supervised jobs recoverable and old tickets untouched.

## STOP conditions and next actions

- Installed tools cannot expose fresh-context spawn or enforced review permissions:
  stop after step 1; report the failed requirement and the supported headless-worker
  alternative, not another attachment workaround or repeated native retries.
- The selected factory-launched runtime cannot enforce the principal matrix or
  expose durable worker readback: stop admission at step 1B, preserve the disabled
  foundation and report that specific gap. Do not replace it with native delegation.
- Parent/child completion cannot be read back independently: retain the same
  uncertain intent/reservation; do not accept parent-attested PASS or replace chats.
- A reviewer needs write permission to source: use exact CI/approved output paths
  if sufficient; otherwise report the capability mismatch for a deliberate decision.
- Exact source ownership, route, checkout/SHA or authorization is ambiguous:
  preserve it and produce a precise reason, never normalize it to qualify.
- A slice needs an out-of-scope change, changes an old request hash, or its
  verification fails twice: stop and update this plan with the owner.

## Maintenance notes

Keep supervisor/tool policy separate from worker allocations. Scrutinize parent
history inheritance, result correlation, workspace mutex release, and any change
that makes READ_ONLY rely only on instructions. New transport work should consume
the same scheduler results instead of forking state transitions. Preserve the
legacy detached verifier route until supervised review has runtime acceptance.
Report storage savings as measured checkout/cache bytes, with Git metadata and
recovery snapshots separately accounted for. A cleaner UI is not proof of fewer
checkouts, cheaper execution, or safely implemented cleanup.
