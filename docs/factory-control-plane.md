# Local Jira-to-GitLab factory control plane

This fork adds an opt-in, local software-factory controller to Symphony. Codex
remains the operator interface: every long-lived cognitive stage runs in a
named, persistent Codex task that can be reopened and debugged in the desktop
app. Symphony supplies the durable graph, leases, capacity limits, recovery,
and exact delivery boundaries behind those tasks.

The standard upstream Symphony loop is unchanged when `factory.enabled` is
false.

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

- A persistent specification-author task produces or refines a self-contained
  Jira delivery contract.
- Missing information is returned as a digest-bound question set. The same task
  resumes only after an exact, human-authored Jira response marker is present.
- The controller writes the candidate contract to Jira and reads the exact
  marker back before continuing.
- A fresh, detached specification critic independently reviews the exact
  candidate.
- Human confirmation is required before the controller records the confirmed
  authorization and adds `ai-ready`.

### Delivery

- A detached feature-planner task grounds the confirmed contract in a clean
  checkout of the configured repository.
- One persistent source writer owns one branch and one worktree. New branches
  use `cgable/<JIRA-KEY>-<short-kebab-description>` from the configured
  `branch_prefix`. The writer performs bounded `draft-feature-cycle` passes,
  leaving coherent incremental commits.
- A fresh, detached change verifier gates the exact candidate SHA. At most two
  non-PASS code-repair rounds return to the same writer.
- Only after verifier `PASS` does the controller push that exact reachable SHA
  with `--no-verify`, create or reuse one reviewer-free draft MR, and read back
  its source branch, target branch, SHA, draft state, reviewer state, and URL.

### Manual validation

The confirmed contract declares whether manual validation is required. When it
is, it must also fix the non-production environment, services, cases, expected
results, synthetic data, evidence, and safe teardown.

The controller keeps the issue in `ai-testing` and resumes one persistent
manual-validator task against the exact pushed SHA. The task must hold its own
Slack service/environment claim through deployment, testing, teardown, and
confirmed release. Staging, production, database DDL, and migration rollback
are forbidden. A repair returns to the sole writer, requires a fresh independent
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

Persistent roles include the specification author, feature writer, and manual
validator. Fresh detached tasks are used for the feature planner,
specification critic, and change verifier so writers do not grade their own
work. Every task record includes its Codex thread ID, name, role, prompt digest,
model route, Codex Project ID, status, and latest activity. Because Symphony and
the Codex desktop app share `CODEX_HOME`, these named tasks remain visible and
reopenable in the Codex task history after Symphony restarts.

Every enabled factory configuration names a Codex Project for its controller,
and every repository route names the existing repository-linked Codex Project
that owns its worker tasks. Symphony supplies that exact repository Project
identity when it creates a durable ticket task and reasserts it when it resumes
or recovers one, even though the actual working directory is an isolated
factory worktree. It does not create a Project per Jira issue or a separate
factory Project. Task names are stable and ticket-first: `PPL-123 · Feature
Writer` for persistent roles and `PPL-123 · R1 · Change Verifier` for fresh
review rounds. The role remains the final title component so all work for one
Jira key is easy to scan and search inside its repository Project.

The configured Project values are durable IDs returned by the same local
`codex app-server` registry that Symphony uses. A desktop integration may expose
different UI-facing aliases, so copying an ID from another API without reading
it back through app-server is not sufficient. Task launch fails closed when
app-server cannot honor the repository Project assignment; it never silently
falls back to an unassigned worker task.

The persistent controller task is the only task that requires Jira and GitLab
MCP servers. Before its first turn, Symphony waits for every configured
`controller_required_mcp_servers` entry to report `ready`; a startup failure or
timeout fails closed. Normal workers remain connector-independent. On clean
shutdown Symphony confirms `thread/unsubscribe`. An active-writer conflict does
not immediately create another visible task. Symphony records the first
conflict and retries the same controller on later ticks. Only after the conflict
has remained continuously blocked for `stale_task_minutes`, and a fresh
`thread/read` proves the task is inactive, may the controller fork its durable
history. The replacement identity is persisted before the superseded task is
archived, so recovery leaves one visible controller and preserves the old task
in the archive.

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

For an interactive foreground run:

```bash
./scripts/run-local-factory ./WORKFLOW.local.md
```

The same command can be installed as a macOS `launchd` job for a persistent
local controller. The configured poll cadence decides when the graph wakes;
Codex remains the UI for inspecting and continuing the individual tasks.

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
