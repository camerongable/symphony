---
tracker:
  kind: linear
  provider:
    project_slug: "symphony-0c79b11b75ea"
  required_labels: []
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. It may be a normal continuation or a retry after a failure.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the work item remains in an active state unless you are blocked by missing required access.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.
2. Only stop early for a true external blocker (missing required tools, auth, permissions, or secrets). If blocked, record it in the workpad and move the issue according to the workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If neither is present, treat that as blocked access: record it in the workpad and move the issue according to the workflow instead of asking a user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human Review`).
- `In Progress` -> implementation actively underway.
- `Human Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Human Review` -> wait and poll for decision/review updates.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `Human Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `Human Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Human Review` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Human Review`.

## Step 3: Human Review and merge handling

1. When the issue is in `Human Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Human Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Native source attachment pilot

`factory.native_source_attachment_enabled` defaults to `false`. This opt-in
bootstrap creates an attached SOURCE checkout and records its separate isolated
CONTROL checkout. It applies only to new native delivery writers; existing
requests are not migrated. Setup uses fast/low maintenance routing and source
turns retain their saved writer allocation. Keep it off in production until the
workspace-write sandbox, control-context recovery, and broker-driven lifecycle
acceptance pass. This flag does not enable archival or cache reclamation; native
cleanup remains separately disabled. See the implementation README and broker
source-bootstrap reference for command/attachment evidence requirements.

## Ticket supervisor execution-mode foundation (disabled)

`factory.ticket_supervisor` defaults to `{"enabled": false, "pilot_issue_keys": []}`.
An explicitly authorized `source_completion_confirmations` entry can admit one
read-only completion report for an already committed repair at the implementation
limit. It binds the exact run, candidate, contract, counters and consumed source
report digests; it does not reset a budget or authorize another source edit. See
the Elixir README for the confirmation and failure semantics.
An optional `schema_rejection` binds the first rejected confirmation's request,
turn, binding, evidence and native error digests plus an authorization reference.
It permits one no-edit successor only after a pre-execution schema rejection is
proven; ordinary failures and a second failed successor remain stopped.
The dashboard exposes this flag separately from `factory.enabled`; a disabled
projection performs no ledger initialization. Parent-summary status is separate
from recorded source/delivery status. Read-only `factory.ticket replay` opens an
existing current-schema ledger and returns bounded evidence/cursors, never action
execution. Unknown attributed usage and physical checkout counts remain unknown.
Keep rollout default-off until final acceptance and separately approved deployment.
Pause/disable is not an owned-worker shutdown receipt; retain reconciliation of
already-issued work and keep native-maintenance authorization separate.
Static Policy validation remains side-effect-free. When this route is enabled,
startup qualifies the actual configured runtime once in the explicit
`parent_output_root` before factory children start. Unsupported runtime or cwd
fails startup; existing per-effect and owned-worker checks remain required.
Listing/formatting/readback do not probe. This does not enable the production
configuration or replace rollout acceptance. Historical runs keep a null mode and continue using
legacy transport behavior. Disabled V1 runs are quarantined while unrelated
legacy work continues; unknown execution modes still stop the tick. Changing
global transport does not enable V1 or rewrite existing runs.

An authorized newcomer requiring unavailable manual validation is a ticket-local
admission denial, including with the valid default `manual_validation: {}`.
Missing, ambiguous or unsupported declarations and disallowed admission environments
also remain visible as fixed-code `INTAKE_BLOCKED` decisions on the exact intake
observation. They create no newcomer run, parent, request or checkout and do not
block unrelated active/queued tickets. Fresh corrected authorization is reconsidered.
This does not enable validation or alter active-validator enforcement. Unsafe policy,
missing Slack coordination, provider/runtime/configuration/internal errors, changed
observations and denial-write failures remain fatal.

The tick callback is bound to its renewing owner's lifetime without giving its
small process guard durable authority. Owner death stops callback execution but
does not release its lease, clear uncertain external operations or authorize replay;
normal expiry and exact readback remain separate recovery fences.

Parent admission inputs under this section are `parent_output_root`,
`broker_thread_id`, `ticket_cli_root` and `ticket_workflow`. The first three are
explicit and never inferred from controller identity or source directories.
An absent workflow uses the loaded workflow's absolute path; explicit null
remains invalid. Internal context options and then tick options override these
configuration values. Configuring inputs alone is not runtime acceptance.

Schema version 19 adds disabled shared-checkout reservations and exact internal
worker receipts. SOURCE ownership spans edits through controller adoption;
REVIEW pins a clean candidate or the planner's immutable pre-candidate base;
MAINTENANCE conflicts with both. An elapsed lease or missing PID never releases
the checkout. Worker model/effort are explicit, and SOURCE/REVIEW have no
controller connectors or network access. These APIs do not activate dispatch.
Mandatory live validation remains rejected on this route until its separately
authorized executor is integrated. Native acceptance must also prove background
command shutdown, not only the app-server's exit.
Until that gate passes, native SOURCE admission and retained SOURCE turns return
`worker_source_containment_unproven` before process/model side effects. This is
not a change to legacy nil-access transport or read-only REVIEW behavior.

Publication codecs and audited rejection dispositions are immutable release
resources, not configurable retry allowances. Recovery retains the rejected
invocation and requires a fresh ordinary controller tick and a distinct nonce.

Schema version 20 introduces FILE_SOURCE as a controller-executed file adapter,
not a writable process profile. Logical SOURCE ownership still spans controller
adoption. The worker process stays read-only with shell, unified execution,
delegation, hooks, apps and network disabled; its exact scoped repository tools
are explicitly supplied on startup and resume. Controller file edits are
SHA-checked, synchronous, and persist intent before writing. Lost responses
reconcile by exact-file readback; unresolved edits prevent consumption/release.
The initial adapter supports bounded text reads, single-directory listings,
replacement/new files in existing directories, and exact-hash deletion of one
regular source file, plus single-directory creation under an existing parent.
Directory creation binds a fixed macOS extended attribute to its precommitted
invocation nonce and the actual directory identity. It adds no source marker;
replay and recovery require the same inode, tag and durable child receipt.
Arbitrary commands, recursive creation and directory removal remain unsupported.
Binary read/write tools use canonical base64, retain the 262,144-byte file bound,
page reads by 8,192 raw bytes and share the same hash-checked mutation/recovery
path. Text reads still reject binary data rather than silently converting it.
Required checks and live validation are not
replaced by edit receipts. Dispatch remains disabled pending native acceptance
and controller-owned check/validation integration.
The disabled check catalog currently exposes only the controller-selected
`git-diff-check` action, not worker-provided commands. Schema-24 receipts bind
candidate/base/contract/reservation and retain actual owned-process outcomes.
An uncertain response is read back without rerunning creation. Pending or
corrupt checks prevent checkout release. There is no new workflow switch and
no build/test or live-validation action is enabled by this addition.
The disabled CI binder requires an independent numeric GitLab project pin and
exact MR/candidate/job scope. A merged-result pipeline additionally requires its
own merge commit's source-parent proof; a current MR head alone is insufficient.
The selected pipeline must match the observed MR `head_pipeline` projection;
missing visibility rejects the observation rather than silently assuming no CI.
It validates supplied data only and neither collects CI nor advances delivery.
CI-first integration must reuse the existing authorized `ci_preflight: draft_mr`
route, not infer push/MR authorization from this binder or bypass fresh review.
Controller catalog discovery requires an existing idle, caller-owned MCP
session and exact, unpaginated inventory. It cannot wake a model or authorize
calls based on advertised schemas. No Jira credential fallback or new native
dispatch route is enabled by this addition.
Native FILE_SOURCE startup and retained turns currently return
`worker_file_mutation_containment_unproven` before side effects. Adversarial
fixtures proved pathname I/O can race a parent swap. The replacement controller
backend uses a fixed descriptor-relative helper, hash-pinned outside source,
with no-follow directory traversal, physical root identity and bounded frames.
Read operations use a non-writing sandbox. Full containment remains unaccepted.

Schema version 21 retains helper invocation/exit receipts and commits a pending
marker before possible mutation. An observed exact helper exit clears that
marker; a timeout, Port close or matching file content cannot do so. Pending
helpers prevent edit replay/reconciliation and worker result consumption. Older
pending edits lacking receipts migrate to quarantine. Automatic helper shutdown
recovery and hardened controller check/validation execution are still required;
the later proven-unchanged cancellation below does not enable dispatch.

Schema 22 adds `io_invocation` and immutable `io_binding_json` to mutating edit
intent. Only a fixed controller companion may execute these edits: it verifies
the precommitted SQLite/WAL row and source reservation, uses one exclusive
invocation claim, and records an owned child exit plus bounded response before
stdout. Restart recovery reads the same journal; it never repeats a claimed
invocation. Normal and signaled exits are distinct evidence. Missing or changed
binding/claim/receipt stays quarantined. Current invocations also bind the exact
path and before/after effect digests. A stopped replace/delete attempt may be
ABORTED only after exact stop evidence, unchanged target, current program/effect
binding and absence of its deterministic `.symphony-<invocation>` temporary.
This retains SOURCE, refuses the old call and allows a new logical retry. Failed
temporary creation never authorizes deleting a pre-existing file. Unprovable
temporaries remain protected; no filename-only reclamation is added.

Replacement bytes are gated on an exact creator-event ACK. The companion checks
the helper self-PID and observes the original temp/root/parent identities before
fsyncing the raw `.creator` event and acknowledging it. After actual original
child exit, the same source reservation covers fixed cleanup of only that inode,
with current authorization and before/after target checks. Cleanup self-PID/exit
evidence is saved separately before a composite final receipt; missing creator
or cleanup evidence rejects both journal and cached readback. If the final
receipt alone is absent, complete matching artifacts may be read back without
rerunning helpers or publishing a replacement receipt. The explicit recovery
marker requires fresh status proof before cached replay/adoption. A matching
late producer receipt may replace it only after comparison; failed comparisons
retain the prior evidence. Invalid existing final receipts, unattested/replaced
files and incomplete terminal artifacts remain quarantined.
The companion is trusted controller
code, not a model worker; model sandbox permissions are unchanged. Journal
authority must not overlap any source workspace. Native admission is still
fenced until complete transport, recovery, source and check/validation acceptance.

Native checkout identity uses a fixed, environment-isolated read-only Git
inspection. It disables hooks/fsmonitor, optional locks and lazy fetch and
cannot spawn a configured clean filter to perform side effects. Local Git
repository/worktree configuration is retained; filter-dependent repositories
may be refused as dirty/error. Identity failure never falls back to ambient Git.
Controller write and credentialed remote operations are unchanged.

Schema version 17 also reserves Desktop-owned, projectless parent identities
under route `desktop_owned_ticket_chat_v1`. Identity is scoped by dispatcher,
immutable Jira issue ID and repository key, with separate run links.
Parent follow-ups may carry one complete specialist-notice ID/text pair; creation
may not. Shared shape validation does not replace linked-run ledger authentication,
immutable payload checks or exact visible-final notice readback.
Experimental owned native readers may explicitly pin private local storage roots;
they recheck directory identity and effective SQLite configuration before reading.
This has no workflow selector or worker activation; all default routes are unchanged.
JSON origin restoration preserves the original directory identities; it never
repins replacement storage. Same-reader provenance requires successful native-home
and effective-SQLite readback. Origin V2 is a storage envelope referenced by V2
worker bindings and recovery receipts, not an issuance authority or a database-content
integrity guarantee.

Set `factory.ticket_supervisor.all_eligible_tickets: true` and `enabled: true`
to select the new route for all new deliveries in the existing assignee/repository
queue, without a per-ticket pilot list. Existing execution modes are immutable;
contracts requiring manual validation remain unsupported on this route rather
than silently falling back to legacy delivery. Native cleanup stays separate.
Only the
new `TICKET_CHAT` request kind accepts a null Project; legacy TASK/CONTROLLER
requests retain their original payload hashes and Project constraints. This
foundation keeps the runtime fence: no native ticket requests can be claimed or
issued through the broker CLI yet. Readback and replay are tested offline, not
permission to dispatch real tickets or enable native worktree cleanup.

Schema version 18 adds local bounded context, digest-pinned artifact paging,
native input observations and typed staged-command receipts. The parent can
stage an interpretation while active, but only completed independent native
readback can admit it. Successful native CLI staging-frame correlation is
transport evidence; human authorization still comes from the exact direct input
and current question/contract/candidate binding. Caller-supplied origin JSON,
assistant updates and quoted artifacts are not authority. Mechanical history
reads issue no `thread/resume`, `thread/start` or `turn/start`.

Default context is at most 16 KB and prose summary at most 2 KB. Older tasks,
questions, commands, events and receipts have bounded local paging rather than
silent truncation. Accepted intents do not launch workers or change Jira;
controller application/readback remains a later gate. Presentation failures and
supersession are independent of delivery. This layer leaves the issuance fence
and native cleanup flag unchanged.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

Native cleanup is disabled by default through `factory.cleanup.native.enabled:
false`. The current native factory chat route has not passed managed-attachment
archive/restore acceptance; setting it to true is rejected at startup. The staged
`workspace-maintainer` role uses the configured fast provider model at low reasoning
and never changes the stored source writer allocation. See the implementation
README for the read-only maintenance plan and remaining activation prerequisites.

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````

## Native CI-repair boundary

`factory.prepared_push_requalifications` defaults to an empty map. A separately
authorized entry pins one exact never-issued PREPARED envelope, nonce, candidate,
specification, contract, authorization reference, and current implementation/CI
limits. Only an owned normal scheduler tick can record its immutable one-use
Schema 53 transfer; it returns without issuing and preserves all attempt counts.
This is not a generic push retry or permission to recover uncertain issuance.
See the Elixir README for the complete entry fields and workflow-change fence.

`factory.ticket_supervisor.ci_repair` is opt-in: absent or unsupported policy
performs no repair diagnosis or dispatch. `diagnosis_only_v1` records bounded,
redacted exact-pipeline findings without claiming a repair; `native_bounded_v1`
may atomically claim at most ten total code-repair attempts (or the lower configured
`factory.maximum_code_repair_rounds` cap) after fresh controller,
source/native, Jira/MR/discussion, capacity, and human-input checks.
The default remains five. The configured total includes previously consumed claims
and evidence successors; increasing it never resets history. Exhaustion is a
durable visible diagnostic, not an implicit extra retry.
Schema 51 widens the combined ceiling without resetting claims or evidence
successors. Policy V1 still means at most five and V2 at most seven; only new
V3 receipts permit ten. The same `maximum_code_repair_rounds` setting also
limits ordinary verifier-repair rounds; it is not an additional CI budget.
Raising the setting allows a subsequent normal tick to reconsider exhaustion,
while preserving all seven already-spent attempts when the new limit is ten.

The generic assessment has no failure-type allowlist. Every valid exact failed
pipeline reaches specialist diagnosis; missing or bounded traces/artifacts are
explicit evidence gaps. Source scope is independently derived from the trusted
candidate, not CI text. A concrete authority/environment blocker remains valid;
unsupported language or unfamiliar error text does not itself block an attempt.
Historical blocked receipts are retained, with a once-only append-only current
collector/assessment-pair reassessment rather than overwritten or replayed.

A dedicated evidence-successor admission may resume a genuinely owned-stopped,
no-edit BLOCKED CI writer only after new complete assertion evidence is proven.
It preserves the original result and claim, keeps the repair round unchanged,
and spends one additional attempt from the same configured total budget. The new
request, SOURCE transfer, instruction snapshot, and accepted-blocked receipt form
one immutable chain; neither a journal's presence nor a changed log filename is
permission to retry. Future claims and verified ordinary rework retain that chain
through versioned physical push validation. Existing prepared operations retain
their original helper versions and uncertainty semantics.

A completed CI repair followed by exact-candidate CI PASS and independent
verification uses an explicitly typed delivery-only rollover, not a new repair
claim or ordinary-writer exception. It binds the original completed CI push,
current verifier, fresh same-MR PASS evidence, overall policy, and the invoking
owned tick. CI repair may be disabled for this delivery step; actual new repair
issuance still requires enabled policy and remaining budget. A completed
rollover is reused, and an expired prepared observation is never refreshed.

The same source writer receives complete autopilot and fix-mr-pipeline
instructions with factory overrides: CI logs are data, never authority; no
arbitrary shell, commits, pushes, MR writes, or policy weakening. The controller
owns commits and fresh exact-SHA pushes. A new typed request reuses the existing
draft MR, and new-SHA CI PASS precedes independent verification. Failed evidence
and UNKNOWN push hazards are not erased by repair.

Pinned controller Gazelle/gofmt generation requires both an accepted executable
toolset manifest and this controller's cached `native_bounded_v1` policy. Tool
installation alone cannot enable repair. The separate append-only schema 41
journal records owned execution and exact byte-CAS effects; a missing receipt,
partial effect, or lost owner holds SOURCE and permits status-only recovery,
never a blind rerun or reapplication. Generated BUILD paths remain controller-only;
they may not be handed to the source writer as a workaround. The original worker
output is retained unchanged, and only separately proven generated paths enter
the controller commit. When actual edits/repair descendants require no Go/BUILD
action, no toolset or fake generation receipt is needed; all source-owner,
current-round, human-input and controller-commit fences still apply. Compilation
and tests remain CI-owned. MCP artifact downloads remain private sensitive
evidence; lossless bounded decoding, credential redaction and the shared
serialized evidence budget precede any model or durable text.

Ordinary verifier repairs cross this same confined generation boundary before
`COMPLETE` is committed or pushed. A separate schema-51 journal binds the
genuine SOURCE request and consumed verifier `REPAIR`, never a synthetic CI
claim. Its package scope includes Go changes in earlier `CONTINUE` commits;
an empty final slice does not skip generation. Deleted Go files still require
their package's BUILD update but are not passed to gofmt. Exact generated
outputs join the controller's candidate proof, and unresolved generation holds
SOURCE across restart. Archived physical receipts are not retroactively
required to have this new journal.

A newly admitted CI claim can carry an optional generated-only capability for
authenticated strict-dependency failures in already-allowed Go files. The
capability pins the failed-candidate source blobs and exact existing sibling
BUILD paths without extending worker permissions or changing historical packets.
Writer `COMPLETE` means source readiness, not independent acceptance. For v2
writers without controller-bound `affected_paths`, descriptive path checks are
supplemental source evidence with unique nonblank IDs and nonempty evidence;
supplied checks must be CHECKED. A focused writer may leave a boundary
UNAVAILABLE with empty paths only when the same criterion is NOT_CHECKED and its
latest carried PASS has nonempty evidence and authenticated request, output, and
candidate identity. Checked boundaries still require paths. Verifier PASS must
keep all criteria PASS, all admitted sweeps and path checks CHECKED, closures
resolved, exact candidate identity, and no required findings.

If no source fix is needed, the writer returns a genuine no-edit `COMPLETE`;
only the controller selects the bound Gazelle-only step, with no prior
`CONTINUE` slice and no changed candidate. Source-edit repairs keep their
original scope. The existing CI generation journal owns partial BUILD CAS
effects and restart reconciliation, and its finalized nonempty outputs enter
one controller commit before physical push. No extra CI attempt is consumed.
Unavailable toolset qualification omits this mechanical capability rather than
restricting general CI repair admission. New v3 generation and v11/v8 physical
helpers enforce the additive proof; archived resources are not rewritten.

Typed MR completion uses `desktop complete-ticket-mr REQUEST_KEY TURN_ID
--source-thread-id BROKER_THREAD_ID`. It reads the same bound completed native
turn, authenticates the broker delegation and observed completed MCP records,
and passes the unchanged final result to the existing strict validator. Missing,
ambiguous, pending, errored or changed evidence is a refusal, not permission to
transcribe success, start another turn or repeat a GitLab operation.

Ordinary review protocol v2 binds typed findings once, initial comprehensive
coverage, and controller-scoped follow-up closure, exact changed paths and
regression evidence. Unverified criteria remain active; omitted historical PASS
evidence retains its original request/output/candidate provenance. Optional
preferences are observations, never mandatory repairs. Late mandatory NEW
findings require a scope decision. The controller's two automatic repairs are
not reset by report changes, CI, instruction snapshots or restart.

`factory.ticket prepare-report-correction` is read-only; `apply-report-correction`
journals one explicit v1 description-index mapping in the owning service without
changing raw evidence, verdict, source or repair counters. A separately explicit
`authorize-policy-stop-repair` binds the consumed REPAIR, two-used policy stop,
mandatory finding IDs and operator scope to one ordinary-tick continuation. It
does not inherit BLOCK authority, dispatch at staging, or authorize a later
automatic repair. The implementation README defines the exact payloads.
For legacy counters beyond both configured caps, reference version 2 explicitly
binds `source_allowance` configured/prior/next implementation and combined-repair
counters plus `maximum_additional_iterations:1`. Its applied authority derives
only that exact run's next-iteration ceiling; configured WORKFLOW limits remain
unchanged. Honest CONTINUE advances the iteration and then stops, without an
automatic extra source iteration.

Native-history admission supports legacy/V1 and explicit V2 recorded worker origins;
no workflow selector or hidden-worker routing is enabled by this support.
Do not add `factory.ticket_supervisor.native_runtime`; explicit values, including
false/null, are unsupported. Updated startup, ledger-opening and rollout entrypoints
refuse unsupported retained native history before mutation. Artifact-only release
qualification is not workflow/ledger admission or deployment evidence.
