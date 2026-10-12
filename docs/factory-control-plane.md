# Local Jira-to-GitLab factory control plane

This fork adds an opt-in, local software-factory controller to Symphony. Codex
remains the operator interface: every long-lived cognitive stage runs in a
named, persistent Codex task that can be reopened and debugged in the desktop
app. Symphony supplies the durable graph, leases, capacity limits, recovery,
and exact delivery boundaries behind those tasks.

The standard upstream Symphony loop is unchanged when `factory.enabled` is
false.

### Desktop-owned ticket route (default off)

With the separately gated `factory.ticket_supervisor` route, an ordinary
`Required: no` ticket has one projectless Desktop parent and one source checkout.
The scheduler owns leases, role admission, source adoption and external writes.
Internal planner/writer/verifier workers return exact receipts to that controller;
their diagnostic threads do not replace the operator's parent chat. The Desktop
broker only creates or updates the parent and reads back those handoffs. It is
not the Jira poller or the source worker.

Chat with the parent to inspect the candidate, findings or next action and to
stage explicit answers/rework. A bounded answer uses `Answer QUESTION_KEY: value`
with the current declared value. The controller independently admits the native
input; a model's acknowledgment or staged PENDING proposal is not authority.
Parent instructions are behavioral constraints, not an enforced read-only OS
sandbox. This route deliberately trusts the operator-facing chat's permissions.
The legacy stage graph below remains applicable to legacy runs.

The dashboard/API show source progress separately from parent synchronization.
An unavailable parent context does not change delivery facts, and a stale
question is retained as history rather than counted as a current decision.
Read-only `factory.ticket replay` exposes bounded evidence and fixed cursors,
without executing actions, initializing a database or waking a model. Usage
without an attributed receipt is unknown, not zero; task lifecycle wall time
and recorded checkout intents do not establish active model time or physical
checkout counts.

Keep rollout default-off until the final acceptance gates and separate deployment
approval. Pausing admission is not proof of draining: verify owned-turn shutdown
and unresolved handoffs independently. Disabling the ordinary route quarantines
its advancement without rebinding runs or enabling legacy dispatch. Retain
readback and diagnosis for already-issued effects; do not resend uncertain work
as a rollback tactic. Native workspace maintenance remains separately disabled
and capability-gated; this route does not enable cleanup or archival.

## Operating model

One bounded controller tick performs this sequence:

1. Acquire and renew a serialized lease in local SQLite.
2. Reconcile existing local runs and Codex tasks before considering new work.
3. Query Jira for factory-labelled issues assigned to `currentUser()` in
   `READY` or `TO DO`, with optional project and direct-parent filters.
4. Prove a repository route from the issue's labels and configured route.
5. Resume the issue's durable graph or admit a new run when its capacity pool
   and safety checks allow it.
6. Persist every state transition, task/thread identity, model route, commit,
   merge request, and terminal result in SQLite.
7. Release the exact lease in an `after` path.

The controller owns Jira writes, final Git push, GitLab draft-MR creation or
update, and read-back. Child tasks receive provenanced snapshots and return
structured results; they do not need Jira or GitLab credentials. The factory
never merges, undrafts, assigns reviewers, manages human review, or deploys to
production.

## Durable stage graph

### Specification

The pilot's reliability and model-routing follow-ups are tracked in
[Factory pilot hardening ledger](factory-pilot-hardening.md).

- A persistent specification-author task produces or refines a self-contained
  Jira delivery contract.
- A failed specification retains a resumable author's checkout. A local retry
  or substantive Jira clarification reopens the same run and author task only
  after active turns and Desktop requests settle; route changes and missing
  checkouts require reconciliation instead of another task. When a terminal
  app-server failure is retried after an explicit switch to native Desktop
  tasks, the old run remains history and one new native run is created; the
  old task is never rebound across transports.
- A completed draft is accepted only for the Jira input used to produce it.
  Material changes during authoring trigger another pass on the same task;
  changes during independent review block stale acceptance.
- Missing information is returned as a digest-bound question set. The same task
  resumes only after an exact, human-authored Jira response marker is present.
  That answer starts a fresh bounded automatic drafting/review cycle; reaching
  the previous cycle's repair limit does not reject a newly answered question.
- The controller writes the candidate contract to Jira and reads the exact
  marker back before continuing. Factory comments use a transport-safe
  hex-encoded issue identity and a fenced literal contract; Jira's Markdown
  conversion must return the exact bytes before authorization.
- A fresh, detached specification critic reviews controller-authored
  `spec-needed` contracts. A manually invoked `specify-work` run writes the
  digest-bound `mode=specify-work` marker and `ai-ready` after exact read-back;
  the controller validates that marker without repeating authorship or critique.
- In the default `auto_after_critic` mode, an independent PASS with no findings
  or questions authorizes the exact read-backed revision automatically. The
  controller records the critic task and output digest in Jira, adds `ai-ready`,
  and reads the result back. `human_confirmation` remains an explicit optional
  mode; unresolved decisions always require a human answer.
- A newer contract revision, conflicting draft at the same revision, or edit to
  the authorized draft invalidates the prior authorization. Reauthorize only
  through the same exact-readback path that produced the new revision.
- A failed In Dev delivery is reconciled by exact Jira issue key outside the
  ordinary READY/TO DO queue. A changed description or human comment creates
  one repository-Project contract-update chat linked to the failed run. New
  contract-only chats use the Project locally without a worktree; an existing
  checkout-backed chat keeps its recorded route. User
  replies are read back by the Desktop broker and resumed in that same chat;
  they never directly authorize source edits. The new contract must be written
  and read back, independently reviewed, and authorized before the existing
  writer is rearmed. Unchanged input remains failed without another chat.
- If that exact contract rearm is interrupted by an In Dev scope check or by
  uncommitted edits from its own writer, the controller may resume the same run,
  task, worktree, branch, and candidate commit. It first proves the authorized
  contract and rearm event, checks that no other work is active, and validates
  the original workspace. If the interruption added `ai-blocked`, the controller
  removes only that label with Jira read-back before resuming. It does not
  repeat specification, create a replacement writer, or discard writer edits.

### Delivery

- New runs move from validated `ai-ready` directly to writer admission. The
  writer treats the confirmed contract as its plan, targets five minutes to
  ground it in code, and allows at most ten for genuinely complex work. Existing
  runs already in `PLANNING` resume their recorded planner task.
- One persistent source writer owns one branch and one worktree. New branches
  use `cgable/<JIRA-KEY>-<short-kebab-description>` from the configured
  `branch_prefix`. The writer performs bounded `draft-feature-cycle` passes,
  returning exact changed paths for each coherent slice. The controller stages
  those named paths and commits with `--no-verify` after a branch, parent-SHA,
  and path-set read-back. On restart it adopts only the exact matching commit.
- A fresh, detached change verifier gates the exact candidate SHA. At most two
  non-PASS code-repair rounds return to the same writer.
- Only after verifier `PASS` does the controller push that exact reachable SHA
  with `--no-verify`, create or reuse one reviewer-free draft MR, and read back
  its source branch, target branch, SHA, draft state, reviewer state, and URL.

### Manual validation

The confirmed contract declares whether manual validation is required. When it
is, it must also fix the non-production environment, services, cases, expected
results, synthetic data, evidence, and safe teardown. The `Required` and
`Environment` fields must occur exactly once within that section; a matching
field under a later heading cannot supply a missing decision.

The controller keeps the issue in `ai-testing` and resumes one persistent
manual-validator task against the exact pushed SHA. The task must hold its own
Slack service/environment claim through deployment, testing, teardown, and
confirmed release. The controller rejects a validation result from any
environment other than the one named in the exact confirmed contract, even if
that environment is otherwise allowed. It rechecks the live safety policy
before launching a validator and before accepting its result, including after
a restart or configuration change. Staging, production, database DDL, and
migration rollback are forbidden. A repair returns to the sole writer, requires a fresh independent
verification, reuses the same MR, and is bounded to two validation repair
rounds. Only validation `PASS` may attach structured evidence to that MR and
move the issue to `ai-review`.

## Queue and repository routing

The default local queue is deliberately cross-project:

```text
assignee = currentUser()
status in (READY, TO DO)
factory label present
```

Project and epic values are optional additional filters. Every issue must also
prove exactly one repository route. For the initial Grail route that proof is
the `repo-grail` label plus the configured local path, base branch, Codex
project, and GitLab project. Unmapped or ambiguous issues remain untouched and
are reported as `ROUTING_REQUIRED`.

For a bounded pilot, set `factory.queue.issue_keys` to an exact list such as
`[PPL-9723]`. The controller still requires the configured assignee, statuses,
and factory label. Leave the list empty for normal cross-project intake.

## Capacity and cleanup

Specification, source-writing, and manual-validation tasks use independent
capacity pools. The initial limits are two of each, but each new source writer
also requires 20 decimal GB of currently free disk. This means the actual
writer count may be lower than the configured count when local storage cannot
safely support another worktree and Bazel output base.

If capacity is short, cleanup is allowed only after a fresh external-state
check authorizes an exact factory run and issue. Automatic cleanup is limited
to factory-owned, inactive, clean, remote-recoverable terminal worktrees and
their associated Bazel bases. Active, blocked, dirty, unpushed, manual, and
live-workspace state is never removed. If the disk requirement is still not
met, the issue stays unclaimed.

The Jira `In Review` workflow transition can authorize cleanup; an `ai-review`
label alone cannot. This policy does not cover Codex-managed auxiliary worktrees,
which require their own lifecycle handling.

After the controller has pushed and read back an independently verified SHA,
an allowed inactive run may hibernate: Symphony removes only the clean writer
worktree and its Bazel base while retaining the exact named local branch, remote
branch, Jira/MR state, run ledger, and visible Codex task. An authorized repair
rehydrates that same branch and SHA into a worktree before resuming the sole
writer. Dirty, unpushed, active, blocked, manual, or identity-mismatched state
is never hibernated.

## Models and visible Codex tasks

The workflow maps stable roles to an exact provider, model, model class, and
reasoning effort. The controller resolves and records the route immediately
before every task creation or resumed turn; it fails closed if the runtime
cannot honor that route. A high-risk feature writer may use a separate route.

The local GPT-6 policy maps `fast` to `gpt-6-luna` for scoped exploration and
failure triage. Tool-backed Jira intake now uses Sol at high effort because it
must preserve a potentially long issue snapshot exactly; the write-capable
`orchestrator` also remains on Sol at high effort. Both `balanced` and `deep` map to `gpt-6-sol`:
Sol replaces the former Terra route for source writing and manual validation,
while per-role reasoning effort and high-risk escalation continue to
distinguish work. The controller, specification, and independent review also
use Sol.
These are routing defaults, not a guarantee that every ticket invokes an
explorer or triager. The legacy Python control CLI retains matching model IDs
for manual compatibility, but the running LaunchAgent reads
`WORKFLOW.local.md`.

Persistent roles include the specification author, feature writer, and manual
validator. Fresh detached tasks are used for controller-authored specification
critique and change verification so writers do not grade their own work. Legacy
planner records remain readable. Every task record includes its Codex thread ID,
name, role, prompt digest,
model route, Codex Project ID, status, and latest activity. A shared
`CODEX_HOME` alone does not prove that a standalone app-server process can
write to a task owned by the Codex desktop. The factory does not launch a new
task or fork when that resume is refused.

The opt-in `task_transport: desktop_broker` stages worker and controller requests
in the local SQLite ledger. The controller must be prebound to one proven
projectless Desktop task; the broker never creates a replacement controller.
Desktop follow-ups do not carry app-server issue-scoped Jira approvals. The
controller instead uses an ephemeral app-server MCP connection for exact
issue-scoped Jira comments and label sets. It reads the issue before and after
each mutation, rejects stale status or labels, and never answers approval or elicitation
requests automatically. Any unproven outcome fails closed for reconciliation;
read-only intake remains in the visible controller task. A request key
is stable across controller restarts; an issued create or follow-up remains
uncertain until a native Codex task read-back binds the exact task and Project.
The broker must return a new completed turn ID, structured output, and required
tool-call evidence. A replayed turn or mismatched Project is rejected. The
broker cannot atomically commit a Codex send and a local SQLite update. If it
stops in that narrow handoff window, it searches for the exact request marker
in the bound task; ambiguous or absent readback remains an operator-recovery
state, never an automatic duplicate send or replacement task. The shared
`service-factory-desktop-requests` skill defines the Codex-side broker tick;
it must run separately from the local Symphony scheduler tick. A malformed
result may receive only the request's persisted `format_repair_attempts`
same-task repair turns. A checkout-backed Project task first receives a
read-only workspace-bootstrap prompt. A new contract-only Project chat starts
with its contract prompt and no checkout bootstrap. A pre-fix planner with no budget may
receive one operator-authorized repair grant keyed to its immutable request;
the broker claims it durably before sending and reconciles an uncertain send
instead of issuing another turn. After a verified native stage follow-up,
the request success and its task result are written in the same SQLite
transaction. A restart can consume that result without submitting another
turn. The bootstrap create does not complete the task; it must first prove and
bind the checkout. The task checks only its path and HEAD; the broker checks
worktree registration, cleanliness, and the pinned SHA so Git LFS need not
write shared metadata from the worker sandbox. Existing request successes
from before this atomic handoff
are reconciled against the task's thread, Project, prompt, and prior turn
before the next scheduler tick. A late worker callback cannot downgrade a
completed or consumed task.

Codex may initially return only a `clientThreadId` for that worktree create.
With explicit local opt-in, `native_session_discovery_enabled` allows a bounded
read of recent Codex session metadata to locate one candidate real task ID by
the exact request marker and broker thread ID. This is not Project proof: the
broker must independently read the task through Codex, confirm its Project ID
and registered checkout at the pinned SHA, and then bind it. Missing,
ambiguous, truncated, or mismatched evidence leaves the request uncertain.
The filename's host-local timestamp only narrows the scan; the session header's
UTC timestamp is authoritative, so a timezone offset cannot hide an otherwise
matching task.
After the broker reads back the task's Project and checkout, the controller
checks that the checkout is a registered, clean worktree in the configured
repository at the pinned SHA. It then sends the actual stage prompt as a
follow-up to that same task. An interrupted bootstrap retains its durable
create request; it must be reconciled rather than issued again. A missing or
wrong checkout blocks resumption instead of falling back to the repository's
primary directory. A terminal request that failed before claim can receive a
new attempt-bound key on an authorized specification retry; claimed or uncertain
requests never do. Source writers also require an exact factory branch in
that verified checkout before their first implementation turn. Once enabled,
the scheduled Codex orchestrator would service requests while the independent
local Symphony process runs the tick; making the orchestrator synchronously run
the tick and service its own queue would deadlock on Jira intake. This broker
path remains opt-in and is not the active local workflow until native task
creation, worktree handoff, and connector policy are verified end to end.

Within a delivery run, bounded writer passes reuse one task. For the legacy
app-server transport, a failed specification run's explicitly requested retry
also reuses its earlier author thread when the issue, repository, and Codex
Project match. The desktop-broker transport does not inherit an old thread
across runs without a newly verified native workspace binding. The local
launcher refuses to silently rebind an existing task to a different role,
repository, or Project. Legacy archived tasks whose checkout is gone or whose
Project binding is absent remain history; the native transport does not
silently adopt them. Only a terminal failed specification with an explicit
local retry or changed Jira input can start a replacement native run, after
checking the repository route and absence of active turns or requests. Other
old tasks require operator reconciliation. If Codex reports an active writer, the task
enters `WAITING_FOR_WRITER` and a later scheduler
tick retries the same ID after a 60-second minimum delay. Live local workers
are registered by task key, so a controller restart cannot launch a second
turn while the first worker is still running. These safeguards do not yet prove
the full desktop-backed lifecycle, so the live factory remains paused.

Every enabled factory configuration names the controller route (`projectless`
for a prebound Desktop controller), and every repository route names the existing repository-linked Codex Project
intended to own its worker tasks. Symphony binds local app-server Project
metadata when it creates, resumes, or recovers a task, even though the working
directory is an isolated factory worktree when that stage needs a pinned
checkout. A contract-only discussion uses the Project's local context and
has no task worktree. It does not create a Project per
Jira issue or a separate factory Project. Task names are ticket-first:
`PPL-123 · Feature Writer` for persistent roles and
`PPL-123 · R1 · Change Verifier` for fresh review rounds. A native CREATE
inserts a stable `F-<request fingerprint>` before the role so a pending
worktree setup can be recovered by exact-title search without confusing it
with an older task. The role stays last for scanning Jira work in the sidebar.

For app-server worker tasks, Symphony checks the configured repository's canonical
primary root against `project/list` in the local `codex app-server` registry
before creating a task. A repository listed only as a secondary root is not a
match. A missing or ambiguous root, or an app-server ID that differs from the
configured desktop Project ID, stops the task before creation. This prevents
substituting a different project ID and incorrectly reporting sidebar grouping.
In Desktop mode the controller is separately bound to a verified projectless
task; the app-server Project registry does not decide its identity. Existing
projectless task history is not moved by this route.

The persistent controller task is the only task that requires Jira and GitLab
MCP servers. In app-server mode Symphony waits for every configured
`controller_required_mcp_servers` entry to report `ready`; in Desktop mode the
broker requires connector-backed tool-call evidence from the completed turn.
A startup failure or timeout fails closed. Normal workers remain connector-independent. On clean
shutdown Symphony confirms `thread/unsubscribe`. An active-writer conflict does
not create another visible task. Symphony retains the existing controller
identity and fails closed until the conflict is resolved or an operator performs
an explicit, read-backed recovery. It does not automatically fork or archive
the controller. The legacy `controller_writer_stale_minutes` setting remains
accepted for configuration compatibility but does not trigger a replacement
task; `stale_task_minutes` still protects feature workers from premature
recovery.

Manual validators are the exception to connector-independent workers. When
live validation is enabled, its policy must declare at least one required app
or MCP server. Symphony reads Codex's committed installed-app snapshot after
creating the validation task and starts the turn only when every required app
is enabled and callable. The local policy binds this gate to the Slack provider
used for environment claims, so missing or disconnected Slack access blocks
validation before deployment begins.

## Configuration and administration

Copy `elixir/WORKFLOW.factory.example.md` to the ignored
`elixir/WORKFLOW.local.md`. The checked-in example contains no local identifiers
or credentials. Startup validates the complete factory policy, including queue,
repository routes, controller and route-specific Codex Project identities,
model roles, cleanup roots, and manual-validation safety; an enabled factory
refuses to start with an incomplete policy.

From `elixir/`:

```bash
mise exec -- mix factory status --workflow WORKFLOW.local.md
mise exec -- mix factory activate --workflow WORKFLOW.local.md
mise exec -- mix factory pause --workflow WORKFLOW.local.md
```

`status` reads the local control record together with durable runs and task
records, including their reopenable Codex thread IDs. The control row starts in
`PAUSED`. Activation and pausing fail while an unexpired tick lease exists.

When a Desktop controller has a proven no-tool-call connector failure, an
operator can migrate to one read-backed projectless controller without
restarting ticket tasks. Pause the dispatcher and broker, prove the new task's
connector call, then run `mix factory replace-controller OLD_THREAD NEW_THREAD
NEW_TURN FAILED_REQUEST_KEY --workflow WORKFLOW.local.md`. The command requires
paused, unleased control and the exact sole unresolved controller request; it
retires that request and records the replacement atomically. Archive the old
task only after reading back the new binding.

Native stages remain `WAITING_FOR_BROKER` while a completed turn needs exact
readback; an ambiguous broker request is not a terminal ticket failure. For a
legacy specification already marked `FAILED` by that condition, the paused
operator can use `mix factory recover-spec-readback REQUEST_KEY COMPLETED_TURN
--workflow WORKFLOW.local.md` after proving the session marker and completed
turn. It restores only the same author and run to await broker completion, with
no new task or Jira write.

A completed author that copied the prior Jira description's revision can be
adopted without another turn using `mix factory adopt-spec-revision REQUEST_KEY
COMPLETED_TURN --workflow WORKFLOW.local.md`. With paused, unleased control,
it proves the exact completed request and latest failed run, changes only the
unique carried-forward header before digest binding, and resumes at the
draft-write/read-back gate. A different or ambiguous revision is not adopted.
If the independent critic requests a repair after the draft comment was read
back, that comment remains historical evidence. The controller advances to the
next revision before resuming the same author; it never overwrites the old
digest or writes different draft bytes under the same revision.

A high-risk writer uses the same stable `:feature-writer` task identity as an
ordinary writer; its model role does not alter worktree binding or branch
attachment. If an earlier writer turn ended without edits after a Git approval
was rejected, pause dispatch and read back the completed Codex turn, task ID,
Project, clean pinned checkout, and recorded branch. Then `mix factory
recover-native-writer REQUEST_KEY COMPLETED_TURN --workflow WORKFLOW.local.md`
closes only the exact malformed-output request, attaches that branch, and
restores the same task for one new pass. The run and task remain failed or
waiting when any route or checkout proof differs.

If a repair writer's controller commit succeeded but the subsequent ledger
update failed, `mix factory adopt-repair-slice REQUEST_KEY COMPLETED_TURN
--workflow WORKFLOW.local.md` proves the clean branch and exact commit against
the saved parent, paths, and message. It reopens the same completed turn for
idempotent adoption and a new independent verifier. Before activation, read
back Jira labels and restore the authorized active labels only if the failed
run's block write actually changed them; the local recovery command does not
write Jira.

If a writer turn is interrupted, do not create a replacement task or discard
partial source edits. Read back the exact interrupted turn and request marker,
pause dispatch with no tick lease, and use `mix factory
resume-interrupted-writer REQUEST_KEY INTERRUPTED_TURN --workflow
WORKFLOW.local.md`. This one-shot path accepts any implementation iteration
only for the latest `WRITING` run with no MR, and when the saved candidate SHA
is absent or equals the worktree HEAD. It also requires the exact task, Project,
worktree, branch, previous-turn binding, and no other unresolved request. It
preserves partial source files and re-arms the same task; the operator must
verify the interrupted turn ID from Codex before invoking it.

An acceptance-check failure in a writer's own uncommitted slice is not a
successful implementation candidate. One operator-reviewed recovery can
preserve the exact dirty native checkout and rearm the same writer task:
`mix factory investigate-blocked-writer REQUEST_KEY BLOCKED_TURN --workflow
WORKFLOW.local.md`. It requires a paused, unleased controller, exact latest
run/request/turn binding, the unchanged branch and candidate SHA, an
`ai-running` snapshot, and remaining implementation passes. It is one-shot;
it neither weakens the confirmed contract nor commits failed source.

The controller first gives each fresh change-verifier task its own detached
Codex worktree at the candidate SHA. The verifier uses reviewer mode in that
checkout, not controller mode, and must not create a second review worktree.
The broker can reconcile the skill's detailed verdict from the completed turn
without another verifier turn. Symphony validates its provenance, acceptance
results, and checks, then maps `REPAIR` findings to the existing writer's next
bounded pass.
If the bound verifier turn fails with `CODEX_AUTHENTICATION_FAILED` before a
verdict, independently prove its failed turn ID and exact task/Project/checkout
binding. Pause dispatch and require an idle lease, then run `mix factory
resume-auth-failed-verifier REQUEST_KEY FAILED_TURN --workflow
WORKFLOW.local.md`. This one-shot recovery records the failed request and
retries in the same verifier task without spending a code-repair round; it
never supplies or changes credentials.

For an interactive foreground run:

```bash
./scripts/run-local-factory ./WORKFLOW.local.md
```

The same command can be installed as a macOS `launchd` job for a persistent
local controller. The configured poll cadence decides when the graph wakes;
Codex remains the UI for inspecting and continuing the individual tasks.
The launch script resolves the bundled Codex CLI from the current app layout
before starting the service and fails fast if it is missing. After a Codex app
update, verify a new intake snapshot rather than treating a healthy dashboard
HTTP response as proof that the scheduler can launch `codex app-server`.

The optional Phoenix dashboard is factory-aware when `factory.enabled` is true.
It reads the controller and bounded recent history directly from the local
SQLite ledger, including leases, stage capacity, runs, Codex task IDs, workspace
hibernation, delivery links, and recent events. Configure `server.host` as
`127.0.0.1` and `server.port` as `4000` for a local-only operator view at
`http://127.0.0.1:4000`; the dashboard has no authentication boundary of its own.

Install or refresh the checked-in user service from `elixir/`:

```bash
./scripts/install-local-factory-launchd
launchctl print "gui/${UID}/com.cgable.symphony-factory"
```

The installer renders the example plist into `~/Library/LaunchAgents`, starts
it immediately, and writes stdout/stderr beneath
`~/Library/Logs/ai-factory`. Keep the SQLite controller `PAUSED` during install
and inspection; the service may be running without admitting work.

## Recovery

The graph commits durable state before crossing an external boundary. On every
tick it reconciles existing runs before dispatching new work, re-reads active
issues even when they fall out of the main query, resumes recorded Codex thread
IDs, replaces stale local processes, and revalidates authorization before
delivery or validation. SHA, contract, question, Jira-write, and MR-readback
markers are digest-bound so a stale or ambiguous observation fails closed.

## Cutover from the Python pilot

1. Keep the Elixir controller paused while its configuration, tests, and live
   read-only connector probe are verified.
2. Pause the old Codex heartbeat/Python dispatcher and wait for its exact lease
   to finish. Do not run both controllers as active owners of the same scope.
3. Install/start Symphony against the shared SQLite ledger in paused mode and
   inspect both `launchctl print` and `mix factory status` for recovered runs
   and tasks.
4. Activate Symphony and observe one bounded pilot tick against an explicitly
   prepared factory-labelled ticket.
5. Verify the visible Codex task history, Jira state, exact Git SHA, draft MR,
   and any required validation evidence before enabling the persistent local
   schedule.
6. Retire the old dispatcher only after the pilot and recovery checks pass.
