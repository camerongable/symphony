# Symphony Elixir

### Attachment-backed source bootstrap (disabled pilot)

`factory.native_source_attachment_enabled` defaults to `false`. When explicitly
enabled for a pilot, new native delivery writers create an explicit managed
source attachment in their existing native chat. `native_source_bindings`
records the isolated control checkout separately; `runs.worktree` and
`factory_tasks.workspace` remain the authoritative source path. Setup uses the
configured fast/low `workspace-maintainer`; source FOLLOWUPs explicitly use the
saved writer allocation. Historical requests and workspaces are not migrated.

Bootstrap requires a pinned read-only command receipt, target-attested attachment
observations, and independent Git checks. Source completion requires observed
same-turn source-command cwd and file-change paths. Ambiguous creation retains
the original request for reconciliation, not a second checkout. This evidence
is not a substitute for sandbox enforcement. The pilot does not thin its control
checkout automatically, archive chats, archive sources, or reclaim caches.

Production enablement awaits workspace-write access to the attached source,
control-context recovery/retention, and a broker-driven acceptance cycle.
`factory.cleanup.native.enabled` remains disabled and capability-gated.
Disabling new attachment bootstrap does not remove existing bindings or chats;
already-bound source turns retain their recorded workspace boundary.

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

Each issue worker uses a named, non-ephemeral Codex thread. When Symphony and
the Codex desktop app use the same `CODEX_HOME`, the thread appears in the
desktop task history after its first turn and can be reopened there. Symphony
can also resume a recorded thread ID after restarting instead of creating a
replacement conversation.

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

This fork also contains an opt-in, SQLite-backed local factory control plane
for a durable Jira-to-GitLab workflow. A manually invoked `specify-work` writes
and reads back the exact authorized contract before adding `ai-ready`; delivery
then starts one writer directly, with short inline code-grounding, independent
verification, and optional Slack-coordinated manual validation as visible
Codex tasks. The controller retains Git push and draft-MR ownership.
Configuration, safety boundaries, recovery, and cutover are documented in
[Local factory control plane](../docs/factory-control-plane.md).
Manual-validation results are bound to the confirmed contract's named
non-production environment as well as its exact candidate SHA. The safety
policy is rechecked before a validator starts and before its result is used.

Install the persistent local scheduler with
`./scripts/install-local-factory-launchd`. Codex remains the operator UI; the
launchd process only supplies durable scheduling and recovery.
The launcher puts the Codex app's bundled CLI directory on `PATH` and fails
startup if `codex` is absent; an outdated bundle path otherwise makes every
Jira intake tick fail before any active ticket can advance.

The optional `desktop_broker` transport routes worker tasks and a prebound,
projectless controller task through durable Desktop requests. The broker must
read back the same task, turn, schema result, and required tool calls. Desktop
follow-ups cannot convey the app-server's issue-scoped Jira tool approvals.
The `specify-work` skill writes its manually authored, authorized contract
through the user's Jira connection; the controller validates its exact marker
before delivery. Scheduler-owned Jira reads and writes use a separate ephemeral
app-server MCP connection. Intake stores exact Jira description and
comment bytes without model reserialization. Writes check the issue, status,
and labels, skip an exact comment already present, and read the issue back.
Digest-bound factory contracts use a transport-safe literal comment envelope;
the controller rejects Jira Markdown rewrites instead of treating them as an
equivalent specification.
Automatic specification repair is bounded separately from human input: a
read-backed answer to the exact question marker resets the automatic repair
budget and resumes the existing author task, even if earlier drafts exhausted
that budget. Legacy feature-planner results receive one same-task JSON-format
repair turn; new deliveries skip the planner task, and malformed legacy output
never authorizes a second planner task.
For a pre-fix planner request with no repair budget, pause the factory and
prove its exact completed turn and task route before
`mix factory authorize-planner-repair REQUEST_KEY COMPLETED_TURN --workflow
WORKFLOW.local.md`. This records a one-shot grant without changing the request
payload. The Desktop broker claims that grant after activation and sends one
tool-free format repair to the same planner task; an uncertain claim is
reconciled, never resent.
An approval or elicitation prompt is not answered automatically; the write
fails closed for reconciliation. The visible Desktop controller task remains
the audit and GitLab-delivery interface, not the Jira data transport.

Review-feedback discovery is enabled by default for this local factory through
`factory.review_feedback`. Set `allowed_author_ids` to the numeric GitLab IDs authorized to
address `$Symphony`. The trigger is plain text, so it does not tag a GitLab user.
Reply readback resolves the authenticated GitLab account
through read-only `whoami` and requires the reply author to match it. An optional
`bot_author_id` pins that identity when the connection uses a dedicated bot account;
omit it when the existing connection posts as a human account. Each scheduler
tick reads fresh Jira state, the exact open factory MR, and all GitLab discussion
pages through a scoped, reused MCP session without a model turn. It records one
durable receipt per new authorized note body. Notes discovered on the same MR
are handled in one controller batch, while each conversational answer is read
back in its own discussion. Questions and ambiguous criticism receive an
explanation or clarifying reply, not a silent source-change classification.
Clear edit requests, including approvals that follow a concrete proposed edit,
continue through the existing writer and verifier. A replayed controller reply
can be retired only after its exact GitLab discussion marker is read back; the
same receipt then continues into source rework without reposting the reply.
Scheduler ticks reconcile a claimed controller request before polling other MRs.
Edits supersede older pending receipts, including when the mention is removed.
Any future receipt consumer must re-read the exact note and MR head immediately
before acting, since either can change after the most recent poll.
Clear source-change requests form one review-rework batch on the existing
delivery run and writer chat, pinned to the exact MR head and clean checkout.
The independent verifier checks the new candidate before the controller pushes
the existing branch; verified push readback then queues exact-thread replies.
No new planner or MR is created, and the factory does not change draft or
reviewer state. If the original native writer checkout is unavailable, rework
fails closed instead of silently creating a second source checkout. Uncertain
GitLab replies require reconciliation; the controller never blindly posts them
again.

If a Desktop controller permanently lacks a required connector, pause the
factory and broker first. After proving a replacement projectless task can
complete the connector read, and proving the old request made no required
external call, migrate the binding with `mise exec -- mix factory
replace-controller OLD_THREAD NEW_THREAD NEW_TURN FAILED_REQUEST_KEY --workflow
WORKFLOW.local.md`. This retires only the exact failed controller request and
keeps ticket worker tasks and their history intact. Archive the old controller
only after the new binding is read back.

A broker readback outage keeps future native stages in `WAITING_FOR_BROKER` so
the same completed turn can be reconciled. For a legacy run already marked
`FAILED` solely because a completed native author turn was hidden from Desktop
task history, pause both loops, prove the exact turn and request marker, then
run `mise exec -- mix factory recover-spec-readback REQUEST_KEY COMPLETED_TURN
--workflow WORKFLOW.local.md`. This reopens the same run and author for broker
completion; it does not generate a new turn or change Jira.

If a completed author draft was rejected only because it carried forward the
previous specification revision, pause dispatch and verify the latest Jira
description and exact completed Desktop turn. `mise exec -- mix factory
adopt-spec-revision REQUEST_KEY COMPLETED_TURN --workflow WORKFLOW.local.md`
binds only a unique prior-revision header to the recorded next revision and
continues with draft write/read-back and independent critique. It does not
send another author turn or write Jira itself.

Native factory writers edit and check source in their Codex worktree, then
return exact changed paths and a conventional commit message as raw structured
output. The controller validates the bound branch, parent SHA, complete path
set, and clean read-back before committing with `--no-verify`; workers do not
write protected shared Git metadata. After an approval-blocked writer turn has
ended with no edits, pause dispatch, verify that exact task and clean pinned
checkout, then use `mise exec -- mix factory recover-native-writer REQUEST_KEY
COMPLETED_TURN --workflow WORKFLOW.local.md`. This attaches the recorded branch
and reuses the same task for its next pass; a mismatched or dirty checkout fails
closed.

For a failed `REPAIRING` slice whose controller commit succeeded before the
ledger update, pause dispatch and verify the current Jira labels, completed
turn, and clean checkout. `mise exec -- mix factory adopt-repair-slice
REQUEST_KEY COMPLETED_TURN --workflow WORKFLOW.local.md` proves the commit's
parent, paths, message, branch, and SHA, then reopens the same run for
idempotent adoption and fresh verification. These recovery commands do not
change Jira labels; if a prior block write added `ai-blocked`, the controller
must restore and read back the authorized labels before activation.

If a native writer turn is interrupted, read back that exact interrupted turn
and request marker. With dispatch paused and no live lease, `mise exec -- mix
factory resume-interrupted-writer REQUEST_KEY INTERRUPTED_TURN --workflow
WORKFLOW.local.md` closes only that unresolved request and re-arms the same
task. It accepts any implementation iteration only while the run is still
writing, has no MR, and its candidate SHA is absent or equals the bound
worktree HEAD. It also verifies the task/project/worktree/branch binding and
refuses another unresolved request or moved HEAD/branch. The operator must
independently verify the interrupted turn ID; the command does not attest
Codex history by itself.

When a writer returns `BLOCKED` on a failing contract check with partial
source edits, the controller does not discard them or silently reinterpret the
contract. After proving the exact completed turn, one latest failed delivery
run, unchanged branch/HEAD, and an `ai-running` snapshot, pause dispatch and
run `mise exec -- mix factory investigate-blocked-writer REQUEST_KEY
BLOCKED_TURN --workflow WORKFLOW.local.md`. This permits one bounded
investigation in the same task and dirty checkout. It does not commit the
failed slice or override a genuine product decision.

If a completed repair writer correctly refuses controller-owned push/MR work,
pause dispatch and use `mise exec -- mix factory resume-controller-delivery
RUN_ID CANDIDATE_SHA --workflow WORKFLOW.local.md`. Recovery requires the exact
latest run and completed broker result, a clean bound branch at that SHA, an
existing draft-MR binding, and the configured CI-preflight route. It returns
the same run to controller-owned CI push, MR read-back, and fresh verification;
it neither relaunches the writer nor edits the MR itself. Record any missing
contract-required MR evidence before reactivation.

The broker generates creation arguments with `mix factory.desktop
create-thread-args REQUEST_KEY --workflow WORKFLOW.local.md` before claiming.
The returned object uses the native tool schema, including `target.projectId`
and a worktree pinned to the expected commit.

If Codex rejects a verifier CREATE with the exact `invalid arguments` result
before returning any task or client ID, the broker records the rejected tool
call. The active scheduler can requeue that same request once after checking
its rejection receipt, current verifier/candidate, repository route, and
unchanged payload. The retry budget persists across restart. Accepted or
ambiguous creation results remain in reconciliation. A second rejection is
shown as a verifier creation failure requiring correction. Paused operator
recovery remains available through `mise exec -- mix factory
resume-rejected-create REQUEST_KEY REJECTED_TOOL_CALL_ID --workflow
WORKFLOW.local.md` after exact tool-call readback.

`mix factory.pilot_report --issue PPL-9723 --workflow WORKFLOW.local.md`
reads the ledger without migrations or mutations. It reports stage and
request wall-clock durations, current handoff failures, task/request counts,
model routes, candidate/MR identity, and recovery/cleanup receipts. Token totals,
human-intervention totals, and historical disk growth are marked unavailable
when the ledger has no measurements. See [the hardening plan](docs/factory-hardening-plan.md)
for lifecycle regression and live-trial acceptance criteria.

Dashboard handoff attention uses the newest request created for each persistent
task. Updating an old recovered failure cannot override a newer healthy request.
When the controller commits a native writer slice, its candidate SHA and the
consumed writer's recorded checkout SHA advance in the same transaction, so a
later review edit can reuse that writer without stale provenance.

Delivery registration inherits risk and risk signals only from one completed
specification with the exact authorized issue, revision, digest, and Markdown.
Missing, malformed, or ambiguous metadata remains conservative `unknown`.
Externally specified contracts without structured risk metadata are unchanged;
free-text Jira descriptions cannot downgrade routing.

Native cleanup capability can be inspected with
`SymphonyElixir.Factory.NativeWorktreeProbe.enqueue(store, run_id)`; it creates
one exact-writer read-only maintenance request, not an implementation pass.
Broker completion must supply the observed artifact map as `artifact_output`
and in the completed `list_artifacts` tool receipt. Probe completion preserves
the writer's stage result, status and turn. Empty/ambiguous attachments do not
authorize cleanup. No automatic native archive/delete scheduling is enabled;
see the hardening plan's synthetic attachment/restore proof and remaining
production execution-context limitation.

The broker can record target-attested maintenance data using
`mix factory.desktop record-maintenance-evidence REQUEST_KEY --payload-base64
BASE64_JSON --workflow WORKFLOW_PATH`. The target's standalone Python emitter
writes stdout only; the broker supplies the full read-backed command frame.
Recording is immutable/idempotent and returns a machine-generated probe receipt.
Completion checks the same maintenance turn's observed `list_artifacts` call
and preserves the writer's implementation result. This is a production evidence
transport, not automatic cleanup activation or independent raw-MCP readback.

The scheduler also polls the exact issue key of a failed delivery, even when
Jira has moved it to In Dev and it is absent from the normal intake query. A
changed Jira description or human comment starts one visible `Contract Update`
task in the repository Project. New contract-only chats use the Project's local
context without creating a worktree; already-bound chats retain their checkout.
A question in that task pauses only that
ticket; the Desktop broker reads back the user's reply and the scheduler
continues the same chat. The reply is input, not authorization: the controller
still writes and reads back the new contract and passes independent review
before rearming the original writer worktree. An unchanged failed contract
does not create another task. The dashboard links to the waiting chat.

The factory creates a fresh detached Codex worktree before launching each
change verifier. The verifier runs `verify-feature-delivery` in reviewer mode
inside that checkout; it must not create another worktree or delegate again.
The Desktop broker may submit that skill's detailed verdict JSON unchanged.
Symphony checks its issue, contract revision and digest, candidate SHA, review
checkout, acceptance results, and checks before reducing it to the factory's
stage result. A `REPAIR` verdict carries its exact required repairs into the
same writer's next pass.
If a verifier turn fails authentication before producing a verdict, prove the
failed Codex turn, exact request, Project, and clean detached candidate checkout.
With dispatch paused and unleased, run `mise exec -- mix factory
resume-auth-failed-verifier REQUEST_KEY FAILED_TURN --workflow
WORKFLOW.local.md`. This closes only that request and rearms the same verifier
task without counting a code-repair round. It does not repair credentials or
attest the failed turn by itself.

If a verifier CREATE was uncertain but its exact bootstrap later completed, use
`mise exec -- mix factory recover-native-verifier-create REQUEST_KEY
BOOTSTRAP_TURN --workflow WORKFLOW.local.md` while dispatch is paused and
unleased. Recovery requires the same latest failed run, a completed bootstrap
bound to the verifier's existing thread, Project, detached clean checkout, and
candidate SHA, with no unresolved sibling request. It rearms that existing
verifier task; it never retries CREATE or changes the candidate/MR.

Native worktree creation can return a temporary client ID before its real task
ID is available. The optional `native_session_discovery_enabled` gate defaults
to `false`. When explicitly enabled, `mix factory.desktop find-thread
REQUEST_KEY --source-thread-id BROKER_THREAD_ID --workflow WORKFLOW.local.md`
scans a bounded portion of recent local and archived Codex session metadata
and returns only a candidate task ID. The broker must still verify the candidate's Project,
checkout, and completed turn through Codex before binding it. A missing or
ambiguous candidate never authorizes another create.

Worker task launch checks the route's primary repository root against the
local Codex app-server Project list. It refuses to substitute that registry's
ID when it differs from the configured desktop Project ID, before creating a
task. The two registries currently have different IDs on this host, so this
guard prevents new projectless factory tasks while the desktop-backed launch
handoff is being built. Existing task IDs and titles remain reopenable, but
their desktop sidebar grouping is unchanged.

After fixing an infrastructure failure, request one local retry of the exact
latest failed specification with `mise exec -- mix factory retry-spec PPL-1234
--workflow WORKFLOW.local.md`. This preserves the failed run and its task
history, does not edit Jira, and cannot repeat without another explicit
request. The factory refuses the command while a scheduler tick holds its
lease, or while the author task or a Desktop request is still active. When the
issue, repository, Codex Project, and checkout still match, the next
specification attempt reopens the failed run and resumes the previous author
task instead of creating a new visible task. A substantive Jira clarification
does the same without requiring `retry-spec`. A missing checkout or changed
route stops that issue for reconciliation rather than creating a replacement.
An active-writer refusal leaves that task waiting and retries the same ID after
a bounded delay; it never forks to work around ownership.
This does not bypass the desktop/app-server Project mismatch above.

For the app-server task transport, Jira mutation approval is one-shot and
issue-bound: comments require the exact body, and label changes require
`jira_update_issue` with only the exact label set computed from the current
intake snapshot. Mixed comment-and-label steps carry separate approvals. For
Desktop transport, the direct MCP writer sends only those same scoped arguments
and checks the fresh preimage and post-write read-back. An agent's PASS text
alone is never proof of a write.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- `tracker.required_any_labels` is optional. When set, an issue must have at
  least one configured label in addition to every `required_labels` entry. This
  supports queues whose mutually exclusive labels represent different workflow
  stages, such as specification and delivery.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, and `api_token`; these
  default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN` and accept `$VAR`. Optionally set
  one `project_key`, multiple `project_keys`, or direct-parent `epic_keys`. Set tracker `assignee`
  to `currentUser()` (or `me`) for Jira's authenticated user, or to an explicit account value.
  Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate JQL combines only configured project, parent, assignee, and status
  clauses. Omitting project and parent scope supports cross-project queues; ID refreshes honor the
  same optional project scope. `issue.id` is Jira's immutable ID and `issue.identifier` is the
  issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`
- When `factory.enabled` is true, the same dashboard shows controller leases, bounded capacity,
  durable runs, Codex task identities, worktree state, delivery links, and recent ledger events.
  The overview counts each current ticket once; a paused factory with a Desktop task awaiting
  broker recovery or its next stage places that ticket under Needs attention rather than Active work.
  A nonterminal run stays under Active work while controller gates run between worker turns;
  Jira queue counts only tickets without an in-progress run. Jira intake separately lists all
  tracked factory-labelled tickets, including those already in progress.
  The Desktop Broker card counts pending, claimed, and reconciliation-needed task handoffs;
  it does not measure the Codex automation heartbeat. Ordinary queued or claimed requests do
  not make the factory unhealthy, while a reconciliation-needed request is flagged in the Broker card.
  Visible worker titles use `ISSUE · Role` or `ISSUE · R# · Role`; internal request IDs remain
  in the durable ledger and task prompt rather than the sidebar title.

Bind `server.host` to `127.0.0.1` for a local-only operator surface. The factory example enables the
dashboard at `http://127.0.0.1:4000`; it does not provide authentication for a network-exposed bind.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

## Native workspace maintenance

`factory.cleanup.native.enabled` defaults to `false`. Enabling it currently fails
startup with `native_archive_restore_capability_unproven`: the actual factory
native-chat route produces a source checkout but no managed attachment identity.
Automatic archival, restoration, and native Bazel reclamation are not shipped or
enabled. The legacy cleanup route remains unchanged and excludes native runs.

The staged coordinator has separate durable lifecycle rows and a single probe
reservation, independent of writer and delivery state. `workspace-maintainer`
resolves to the configured provider's `fast` model with `low` reasoning. Ordinary
source requests retain the writer's model allocation. An unavailable or ambiguous
attachment is remembered for that exact binding without repeatedly waking a model.
Even a supported attachment receipt does not authorize archival.

`mix factory.desktop maintenance-plan --workflow /absolute/WORKFLOW.local.md`
reads candidate and lifecycle state without adding lifecycle rows, requests,
events, or external authorization. Its `eligible` flag means **probe eligibility**,
not cleanup permission. API state exposes `workspace_maintenance` separately;
untouched runs with no lifecycle row remain available for normal review rework.
Existing probe reservations reconcile even with native cleanup disabled.

The production acceptance gate remains a complete factory-route archive/restore
cycle, same-chat access, fresh external authorization, exact remote recoverability,
and isolated cache reclamation. No filesystem removal fallback or extra attachment
may be used to bypass the missing managed identity.

This project is licensed under the [Apache License 2.0](../LICENSE).
