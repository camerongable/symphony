# Factory reliability plan

## Outcome and scope

An authorized Jira contract reaches one draft MR without manual handoff repair.
Review feedback resumes the same writer, receives independent verification of
the resulting commit, updates that MR, and receives a reply in its original
GitLab thread. A restart must preserve request, chat, branch, candidate, and MR
identity. Reclaiming storage must preserve recoverability and protect active or
unpublished work.

This plan hardens the existing workflow. An `ai-ready` ticket already enters
`ADMITTING_WRITER` directly; it does not require a new specification or planner
chat. Keep that route and the independent verifier. Model allocation changes,
new feature scope, and a general-purpose graph redesign are outside this plan.

## 1. Generate broker arguments and recover definitive rejections

Implementation:

- `factory/desktop_tool_args.ex` generates the exact `create_thread` argument
  object from an intact durable request. `projectId` belongs under `target`;
  native checkout creation uses the full expected SHA.
- `mix factory.desktop create-thread-args REQUEST_KEY` is read-only. The broker
  skill consumes this object before claiming, checks the available callable
  schema, and submits it verbatim.
- `Recovery.retry_rejected_native_create/3` permits one automatic retry only
  for an unbound current native verifier with an exact pre-creation rejection
  event. Require unchanged payload, task/run/project/repository/candidate
  identity, reachable candidate, and no competing creation or unresolved
  request. Persist the retry event, including its original rejected call ID.
- The scheduler continues past ineligible rejected requests and recovers at
  most one eligible request per tick. A repeated rejection remains actionable
  recovery; accepted creations and ambiguous timeouts are never reissued.
- Verifier report normalization preserves completed tool calls and the actual
  verdict. A resolved base SHA is accepted only after bound-checkout proof and
  a read-only Git merge-base check. Wrong candidates, contracts, bases, or
  required validation evidence remain rejected; a repair report never becomes
  a pass through format adaptation.

Verification:

- Builder and CLI tests prove exact keys, native/local routes, pinned SHA,
  payload-integrity checks, and malformed/unsupported argument rejection.
- Recovery tests prove missing/mismatched rejection proof fails, paused
  dispatch prevents automatic retry, the same request/task are reused, and a
  second rejection remains blocked after reopening SQLite.
- The native lifecycle harness injects a rejected verifier bootstrap before
  continuing delivery, proving scheduler invocation rather than only testing
  the recovery helper.
- Live PPL-9723 recovery uses its existing round-3 request, verifies the exact
  project/checkout/commit, completes bootstrap, and confirms the actual review
  turn starts. Creating another round or redoing implementation is not recovery.
- A real temporary-Git report test proves the resolved-base/tool-evidence
  adaptation and rejects a mismatched base. The live verifier's completed
  report is recorded on the same request without another review turn.

## 2. Present stalled handoffs accurately

Implementation: derive attention from the current task's durable unresolved
Desktop request in `factory/observability.ex`, then render it in
`dashboard_live.ex`. A rejected verifier creation displays "Verifier creation
failed", the reason, and the same request key. A healthy controller must not
mask a stalled task. Overview counts and the workflow row must agree.

Verification: projection and rendered LiveView tests cover definitive rejection,
ambiguous creation, normal pending work, consumed historical failures, and
same-request recovery clearing attention. Normal pending or running work remains
active; absence of a chat ID alone does not prove creation failed.

## 3. Prove the complete native lifecycle

Use `test/symphony_elixir/factory_full_lifecycle_test.exs` and its real temporary
Git repository and bare remote. Add fixtures only at external provider seams;
exercise the actual scheduler, ledgers, task launcher, commits, and checkout
validation.

Required scenarios:

1. Authorized `ai-ready` intake selects the default writer directly, with no
   specification or planner task. Two implementation passes retain one writer
   chat. A supported model payload passes `DesktopToolArgs`.
2. Close/reopen SQLite after writer completion but before consumption. Preserve
   exact request keys, thread/turn IDs, result bytes, and candidate. The old
   completed result must not be mistaken for the new review-edit pass.
3. Verifier runs on the exact detached candidate. A definitive creation
   rejection is retried once on the same request. An older invalid candidate
   cannot starve a later eligible rejection.
4. Push to the temporary remote only after the configured gate. Repeated ticks
   retain one MR and do not replay an ambiguous provider write.
5. Resume a completed review-feedback batch on the existing writer, increment
   verifier round, and update the same MR. Check identity after restart between
   verifier completion and result consumption.
6. Combine denied approval and retry-eligible CI failure with subsequent
   recovery. Unrelated tickets must remain dispatchable; the failed ticket
   cannot bypass exact-candidate verification.

Existing unit tests already cover several individual failures. Add integration
assertions only where these component combinations are not already proved;
passing isolated tests is not end-to-end Desktop/GitLab evidence.

## 4. Measure trials without inventing usage

`mix factory.pilot_report --issue ISSUE --workflow WORKFLOW.local.md` reads
SQLite with a read-only connection and does not initialize/migrate it. Report
stage/request elapsed wall-clock time, waits, task/create/follow-up counts,
models, candidate/MR identity, latest unresolved request, recovery events, and
cleanup/hibernation receipts. Distinguish waiting from agent execution time.

Tests prove missing databases are not created and history/schema receipts are
not modified. Stage history can be incomplete for older runs; report missing
measurements explicitly. Token usage, human-intervention totals, and historical
disk growth are unavailable until a reliable source exists. For new live trials,
record actual interventions and capacity before/after in a trial record.

## 5. Verify storage lifecycle and recovery

Preserve current deletion gates: exact owned workspace identity, inactive task,
clean checkout, remote-recoverable candidate, configured Jira/MR/run eligibility,
fresh authorization, and protected main/live/unpublished paths. The local
policy already includes Jira `In Review`; do not silently broaden allowed
states or classify a native managed checkout as a legacy factory-owned one.

Extend the existing real temporary-worktree cleanup tests through the scheduler
seam where feasible. Exercise authorization readback, cleanup receipt,
synthetic Bazel reclamation, SQLite restart, and exact branch/candidate
rehydration. Prove dirty, active, and unpublished work is untouched, and reclaim
only until the configured 20 GB writer gate is satisfied.

Native Codex-managed cleanup requires its supported attachment/archive/restore
mechanism and independently proven ownership. Legacy filesystem cleanup tests
do not prove that path. Before any live native cleanup trial, verify that the
chat remains accessible and work can be restored from the retained snapshot or
remote branch. If that interface cannot meet the requirement, document it as an
explicit limitation rather than pretending automatic cleanup is complete.

## 6. Live acceptance trials

Run three small, genuinely authorized features through the default `ai-ready`
route. Include a real GitLab review edit and one restart at a handoff boundary.
For each, retain the report and actual before/after capacity measurements.

Acceptance:

- Zero manual handoff repair; questions concern product decisions only.
- No duplicate writer/chat/MR or repeated ambiguous external write.
- Independent verifier and required CI/validation evidence identify the exact
  pushed SHA. Review feedback completes in the original GitLab thread.
- Final dashboard state matches the ledger and MR.
- Checkout/cache growth is accounted for; eligible cleanup is observed, and
  reopening restores the intended branch/candidate.

The agent can execute, observe, and measure these trials. The user supplies real
feature intent and human review judgment. Do not manufacture Jira tickets or
approval replies to obtain a green trial. PPL-9723 review rework is the current
live handoff trial, not proof that a new ticket completed without intervention.

## Separate follow-up: review rigor and end-to-end latency

After the hardening/cleanup work and before deciding further review-policy
changes, investigate why small, specified changes require repeated review and
repair passes. Measure agent execution versus queue/tick waits, duplicated
checks, finding severity, repeated findings, and controller-owned evidence
requirements incorrectly returned as writer repairs. Compare simpler review
policies with the current workflow using observed failures, not assumptions.
Propose faster defaults and bounded escalation options with their tradeoffs.
Do not change existing verification gates as part of this deferred workstream.
Real-feature acceptance trials follow completion of the current to-dos and
production cleanup integration, as requested by the user.

## Verification and rollout

Run focused tests for each slice, then the repository's integrated gate once
the combined changes stop moving. Validate `mix specs.check` and formatting;
the full repository gate is `make all`. Restart the local service with the
checked source and read back its running state, dashboard projection, and next
scheduler/broker progression. Commit/push only under the user's applicable
authorization. Report completed changes, remaining scenarios, and live-trial
results separately.

## Execution record: 2026-10-01

Implemented generated creation arguments, one proof-bound automatic verifier
creation retry, stalled-request dashboard projection, rollback error
normalization, verifier report adaptation, durable rework state events, and the
read-only pilot report. Updated the shared broker skill to use generated
arguments. Local service restarted with the checked source.

New integration evidence covers direct `ai-ready` writer admission, SQLite
restart before consumption, schema-valid CREATE payloads, same-request rejected
creation recovery, exact-candidate detached verification, single-MR delivery,
and real temporary-worktree cleanup/restart/rehydration. Combined checks:
770 tests, zero failures, six skipped; configured coverage gate 100%; formatting,
lint/spec checks and Dialyzer passed. Live PPL-9723 round 3 completed and its
unchanged REPAIR report was recorded and consumed; the same writer is queued
for the inherited-font repair.

The follow-up batch corrects attention to use the newest created request per
persistent task, rather than a recovered historical failure. It also advances
the consumed native writer's checkout SHA atomically with the committed run
candidate. The genuine review roundtrip regression failed before this SHA fix.

The combined lifecycle matrix now exercises same-writer review rework, fresh
verification, same-MR updates, and reopening SQLite between verifier completion
and consumption. Another scenario combines a reported denied approval,
unrelated-ticket dispatch, explicit proof-bound recovery, CI repair on the same
writer, and exact new-candidate CI and detached verification. Denial is not an
automatic permission grant. Real temporary-worktree cleanup/restart/rehydration
checks remain separate from native Codex cleanup evidence.

Delivery registration now inherits typed risk/signals only from a unique
completed specification matching the exact authorized issue, revision, digest,
and Markdown. Twenty table-driven cases cover malformed, absent, conflicting,
and mismatched metadata. External specify-work contracts without a structured
authoritative risk field still route conservatively; no model allocations were
changed by this hardening batch.

Combined follow-up validation: `make all` passed with 773 tests, zero failures,
six skipped, and 100% configured coverage. Formatting, specs, lint, build, and
Dialyzer passed; independent read-only review found no blockers in this batch.
The dependency resolver still reports existing dependency security advisories;
this batch does not upgrade dependencies or constitute a security audit.

Remaining evidence: three uninterrupted real feature trials, real capacity
measurements, and native managed-worktree archival/restoration. A read-only
synthetic probe successfully resumed a chat whose old checkout was absent, but
its artifact list was empty: this proves missing-cwd chat execution, not an
archiveable attachment or restore/rework. The chat's prior archived state was
restored afterward. Automatic native deletion remains disabled; the next proof
must use an exactly identified managed attachment and supported archive/restore
tools, preserve chat access, and rebind the intended branch/candidate. The
temporary Git tests do not replace those live checks.

### Native cleanup proof: 2026-10-01 follow-up

The new Local Polaris synthetic chat `01a0f8d3-dd3d-7ea2-b2dd-f74d52169fc1`
created one supported managed attachment at
`/Users/cgable/.codex/worktrees/synthetic-cleanup-proof/polaris`, pinned to
`35214f7f24d7f5f3bac5631b7ecf9fcd472dc2cd`. Its allocated checkout size was
32,480 KiB. Supported archive removed the source while retaining the attachment
as `archived_worktree`; the same open chat accepted a subsequent message.
Restore returned the original candidate with a clean detached HEAD. A second
cycle verified that the unchanged synthetic branch could be explicitly
reattached after restore, then archived again. The final source path is absent,
the recovery attachment remains, and the chat is still open.

This proves tool-managed attachments in a Local chat, not existing factory
`create_thread(environment: worktree)` ownership. The Local chat's command cwd
remained `/Users/cgable/Repos/polaris`; attaching/restoring did not move it into
the managed checkout. The earlier absent-cwd chat still cannot create a worktree
and has no attachment. Production bootstrap/ownership and source execution
context must be proved separately before enabling native automatic archival.

Read-only capability groundwork adds `NativeWorktreeProbe.enqueue(store,
run_id)` and deterministic `receipt(request, observed_artifacts_map)`. Only
broker-observed artifact evidence can support a receipt; missing attachments
are `UNAVAILABLE` and duplicates are `AMBIGUOUS`. Maintenance completion leaves
the original writer row unchanged and is excluded from implementation-stage
backfill. It does not enqueue automatically, authorize deletion, or reclaim
Bazel state. The eight focused regressions cover provenance, restart, unchanged
writer data, ambiguous/missing evidence, and unsupported operations.

The existing completion CLI accepts top-level `artifact_output` containing the
raw artifact map. The completed `list_artifacts` tool receipt carries the same
map as its `output`; `output.result` is the deterministic bound probe receipt.
Final prose alone is not attachment proof.

Initial storage scan in this follow-up: 18,489,464 KiB free; measured Codex worktrees
22,615,796 KiB, Bazel cache 361,968 KiB, and legacy factory worktrees zero.
A later scan measured 21,005,680 KiB of Codex worktrees, with large Grail
checkouts around 1,610,408 KiB each. Other work was running throughout; changes
in global free space or totals cannot be attributed solely to this 32,480 KiB
synthetic checkout. These are current allocated-size measurements, not per-ticket
historical growth or proof of successful production automatic cleanup.

The probe currently inherits its writer's model/effort; it is not scheduled
automatically. A future scheduled cleanup path must select an inexpensive
maintenance route rather than multiplying high-risk writer-model turns.
Independent review also caught malformed tool entries raising instead of
rejecting and maintenance requests distorting implementation attention. Added
regressions reject malformed evidence without writer/request mutations and
exclude maintenance requests from both failure selection and request shadowing.

Final follow-up gate: `make all` passed with 782 tests, zero failures, six
skipped, and 100% configured coverage. Specs, formatting, lint, build and
Dialyzer passed. Independent review confirmed both discovered regressions fixed.
This is not completion of production native cleanup or the three real-feature
acceptance trials.

### Production integration, first slice: evidence transport

Cross-chat `read_thread(includeOutputs: true)` exposes completed native MCP
calls but not their raw results. It does expose command execution frames and
stdout. The target now captures `list_artifacts` and runs the standalone
`scripts/emit-maintenance-evidence.py` emitter with `python3 -B`. It writes only
stdout, not files, network state, or the controller database. The broker records
the observed envelope and full command frame with
`mix factory.desktop record-maintenance-evidence REQUEST_KEY
--payload-base64 BASE64_JSON --workflow WORKFLOW_PATH`.

Recording binds the exact request, chat, candidate, Project, checkout, prior
implementation turn, distinct completed maintenance turn, emitter invocation
and script digest. Evidence is immutable and idempotent; conflicting replays
fail closed. Completion revalidates those bindings and the completed same-turn
`list_artifacts` call. Both operations preserve the writer row. Recording
returns a machine-generated receipt, avoiding a target-model receipt-formatting
pass. The shared broker skill now documents this branch.

This evidence is explicitly `TARGET_ATTESTED_NATIVE_CHAT`, transported through
`BROKER_OBSERVED_COMMAND_STDOUT`; it is not independently observed raw MCP
output or deletion authorization. A supported synthetic chat trial emitted
protocol version 1 from the exact restored managed checkout. Cross-chat readback
proved completed turn `01a0f925-adb1-7773-a510-db825305400e`, command item
`exec-6e462d70-ddd9-4b93-bacb-0ea491630ce2`, exit code zero and untruncated
stdout. The synthetic request was deliberately unregistered: no production
ledger entry or ticket was changed. The source was archived again afterward,
with the same chat open and a recoverable attachment retained.

Still to implement before activation: fresh external cleanup authorization and
bounded probe admission; archive/restore coordination together; exact archived
identity and source-absence proof before Bazel reclamation; restore and branch
reattachment before review rework; inexpensive maintenance routing; and actual
factory attachment/execution-context proof. Existing native runs with missing
attachments or stale writer/candidate bindings remain protected. Real-feature
trials wait until the current to-dos and production cleanup integration finish.

Transport slice validation: `make all` passed on the final source with 788
tests, zero failures, six skipped and 100% configured coverage. Formatting,
specs, lint, build and Dialyzer passed. Independent review confirmed immutable
evidence cannot be bypassed by direct caller output on emitter-pinned requests
and malformed nested payloads reject without mutation. The earlier full run
also exposed an existing retry-test timing flake; its two assertions now check
the exact delay against the scheduling interval rather than observation time,
with no change to production retry policy. The two focused cases and independent
test review passed. This slice does not enable automatic archive/delete.

### Production native cleanup foundation: capability gate failed

The actual factory creation/bootstrap route was tested with Project
`0c602f12-ad80-4185-a90a-4269fbe4020a`, chat
`01a0f953-ef63-7570-ba62-7dee51e20fa7`, checkout
`/Users/cgable/.codex/worktrees/a686/polaris`, and exact candidate
`f414a1685f93af00cc15ce4786e25618cbd3acdd`. Completed bootstrap turn
`01a0f953-f27f-7381-a9be-9a17cd5c6dd0` proved clean detached source at the
expected execution directory. Follow-up turn
`01a0f956-6028-71f3-9679-954504566db4` completed `list_artifacts` and emitter
command `exec-4a3be6e2-4329-42fb-8355-dee078cc2eaa` in that checkout; its
untruncated, exit-zero stdout retained `TARGET_ATTESTED_NATIVE_CHAT` evidence
with `artifacts: []`. A valid native source checkout is not an archiveable
managed attachment. The synthetic source's 32,548 KiB is retained: no fallback
attachment, replacement chat, source deletion, archive, or restore was attempted.
The marker used for stdout was deliberately unregistered; no live ledger was
modified for the fixture.

Shipped locally: separate durable probe lifecycle/reservation rows, one bounded
admission, configured fast/low workspace-maintainer route, read-only
`factory.desktop maintenance-plan`, distinct API projection, unchanged writer
allocations, exact creation/binding checks, and transaction-held review-rework
exclusion. Successful unavailable/ambiguous probes release the reservation and
are remembered without repeated model wakeups. New MR notes do not invalidate a
completed read-only probe; broker recovery of the same uncertain request remains
consumable while disabled. Immutable pre-upgrade probe route conflicts are
remembered as skipped rather than recreated or allowed to starve other runs.

Not shipped or enabled: fresh external cleanup authorization, native archive and
restore transport, same-chat restoration/branch reattachment, writer-capacity
restoration gate, or exact native Bazel reclamation. `native.enabled` defaults
false and setting it true fails startup with
`native_archive_restore_capability_unproven`. Future lifecycle phase names in the
table are reserved schema vocabulary, not implemented destructive transitions.
Automatic archival must remain off until the actual factory-created route proves
both archive and restoration with a supported attachment identity.

Foundation validation: 809 tests passed, zero failures and six skipped;
configured coverage is 100%, including both native maintenance modules. Build,
format check, public specs, lint and Dialyzer passed. The gate first exposed
style issues and four untested error/reconciliation lines; these were corrected
with narrow tests, without exclusions or relaxed coverage thresholds. Independent
adversarial review found and verified fixes for feedback arriving during a probe,
same-request broker recovery after reconciliation, and immutable pre-upgrade
probe model-route conflicts. No commit, push, native archive, or cache removal
was performed by this implementation slice.

Disabled local rollout restarted `com.cgable.symphony-factory` and created the
empty maintenance table through normal startup migration. The read-only
`maintenance-plan` reported `ARCHIVE_RESTORE_NOT_PROVEN`, authorization
`NOT_REQUESTED`, and skipped the existing delivery because its writer binding
is stale. Runs/tasks/requests/events remained at 16/33/115/1424 before and after
the dry-run; no maintenance request or lifecycle row was created. Initial HTTP
readbacks timed out; a subsequent bounded API readback reported factory
`available: true`. Database queue timeouts were observed before and after the
restart, so this readback is not evidence that the tick-timeout issue is fixed.
Native archival remains disabled; production archive/restore acceptance was not
attempted because the synthetic factory attachment prerequisite failed.

### Revised remaining-cleanup plan: prove an actionable workspace binding first

Keep real-feature trials and other TODOs excluded. Preserve open chats, exact
candidate recovery, remote-recoverability checks, protected primary checkouts,
and the disabled production archive gate. Do not treat a Git path as a supported
Codex archive identity.

1. Reuse the isolated native synthetic chat. Test supported handoff once after
   verifying an idle chat and clean equal-SHA primary/synthetic checkouts. Record
   any refusal; do not erase an unknown composer draft or retry ambiguously.
2. Test an explicit managed source attachment in that same isolated native chat.
   Keep its original bootstrap checkout unchanged as the control context, and
   independently prove the new source checkout's attachment identity, repository,
   SHA, branch, and cleanliness. This separates actual source-command cwd from
   chat cwd; it does not permit using the primary repository as a writer context.
3. Prove source execution using explicit command cwd and an inert, test-owned
   patch confined to the managed source path; remove that patch and prove both
   the source and bootstrap are clean and the primary branch/HEAD unchanged.
   Record tool/command frames, not just a model's final explanation.
4. Archive only the exact supported synthetic source attachment. Prove source
   absence, retained archived identity, and a still-accessible chat. Restore that
   same attachment and prove exact clean candidate and explicit source-command
   execution again. Keep control-context retention and its storage footprint
   explicit; this is not yet proof of one physical checkout per chat.
5. If the proof succeeds, implement a separate attachment-backed bootstrap mode
   with distinct control/source bindings. Require actual source execution proof,
   one writer per source checkout, and unchanged control/primary state. Then
   implement fresh authorization, archive/restore together, exact cache cleanup,
   and rollback against that proven mode. Existing unproven native runs remain
   protected; no automatic migration or additional writer checkout is assumed.
6. If a supported attachment-backed route cannot satisfy execution/recovery,
   report the exact remaining capability gap. Controller-owned Git removal and
   restoration is a separate destructive-boundary change requiring explicit
   approval, not a silent fallback. Do not add more dormant archive states while
   the execution/recovery route remains unproven.

Acceptance before production activation: same chat; exact supported attachment;
no source work in primary/control checkout; branch/SHA/cleanliness preserved;
archive then restore then bounded source operation; absence-before-exact-Bazel
reclaim; restart/uncertain-result recovery; independent review and quality gate.

### Revised binding proof results and next implementation slice

Supported handoff of synthetic chat `01a0f953-ef63-7570-ba62-7dee51e20fa7`
was refused for pending composer state. Primary branch, HEAD, and cleanliness
were unchanged; no composer content was cleared and no unsupported UI bypass
was used.

An explicit managed attachment in the same isolated native chat succeeded:
source `/Users/cgable/.codex/worktrees/synthetic-managed-source-20261001/polaris`,
control `/Users/cgable/.codex/worktrees/a686/polaris`, candidate
`f414a1685f93af00cc15ce4786e25618cbd3acdd`, source branch
`symphony/synthetic-managed-source-20261001`. Creation turn
`01a0f987-3cca-70e2-a173-4e5605e836d4` observed the registered attachment.
Source-operation turn `01a0f988-c605-75b3-a131-cfffbeaa0dee` contains completed
command frames with explicit source cwd and file-change frames confined to the
test-owned source sentinel, which was subsequently removed.

Archive turn `01a0f98b-3f24-71f1-a419-e10a4288efa0` called the supported
archive tool once; its queued result was reconciled by archived attachment and
independent source absence. Restore turn
`01a0f98e-8448-7992-a9da-cc49312bc21b` restored the exact source in the same
chat, reattached the unchanged branch without force, and completed another
source-only test patch/read/remove cycle. Primary and control remained clean at
the original SHA. Final archive turn
`01a0f99f-b7f5-72c0-a526-0f2e15c7c25d` again left the source absent and
recoverable, with the chat open.

The control checkout was then made sparse with supported Git commands,
retaining `/AGENTS.md`, `/CLAUDE.md`, and `/.codex/`. Its checked-out directory
fell from 32,548 KiB to 12 KiB, excluding separate Git metadata and retained
snapshots. Common Git configuration digest, primary branch/HEAD, and primary
cleanliness were unchanged. Read-only turn
`01a0f9a3-427d-7933-8c90-64d34b425efd` proved the same chat still executes
and sees the recoverable source attachment after thinning.

This proves a functional control/source separation, not unrestricted production
activation or one physical worktree total. The fixture's effective profile was
`danger-full-access` with approval `never`; no permission settings were changed.
It does not prove this route works under the intended production sandbox.

Next bounded code slice: an opt-in attachment-backed writer bootstrap, keeping
legacy native creation unchanged. Persist distinct control/source bindings and
attachment provenance; use one authoritative source checkout and require actual
source-command cwd/file-change path proof. Mechanical bootstrap uses fast/low
maintenance routing without overwriting writer allocation. Tests must reject
primary/control source writes, stale or ambiguous attachments, mismatched
candidate/repository, duplicate creation after uncertain results, and unproven
execution. Keep this mode disabled for production until the actual sandbox,
control-context retention/recovery, and broker-driven bootstrap are verified.
Then complete fresh cleanup authorization, archive/restore coordination, exact
cache reclamation and restart recovery against this binding; do not migrate
existing ticket workstreams automatically.

### Attachment-backed bootstrap integration slice

Added default-off `factory.native_source_attachment_enabled` for new native
delivery writers. Mechanical CREATE bootstrap routes to configured fast/low
workspace-maintainer, creates one managed SOURCE attachment in the isolated
native chat, and emits a pinned read-only receipt from SOURCE. The new immutable
`native_source_bindings` table retains CONTROL, SOURCE, Project/chat identity,
attachment root, pinned SHA, request/turn, and target-attested evidence. Writer
and run workspace fields point to SOURCE; saved writer allocations are unchanged.
Subsequent source requests explicitly apply normal writer model/effort, append
the workspace boundary, and require same-turn observed source execution evidence.
The broker's canonical skill now routes this opt-in branch to its own reference.

This slice does not thin CONTROL automatically, enable cleanup, migrate old
workstreams, or prove the production sandbox. Next acceptance remains an isolated
broker-driven bootstrap under the intended workspace-write profile and proof of
control-context recovery/retention. Archive/restore authorization and cache
reclamation remain subsequent work, with native archival disabled.

Integration verification: 816 tests passed, zero failures, six skipped, and
100% configured coverage. Build, formatting, public specs, strict lint and
Dialyzer passed. Independent review found two defects before rollout: retrying
after binding changed the CREATE payload, and accepted source execution evidence
was not retained. Both are fixed and regression-tested; frozen-source recheck
passed. Creation attempts include failed/uncertain attempts in the uniqueness
check; source paths are absolute/canonical and overlapping bindings reject.

Local rollout restarted the service with source-attachment pilot and native
cleanup both disabled. Synchronous API readback reported factory available and
ACTIVE; the source-binding table remained empty. No ticket workspaces were
migrated, chats archived, or caches reclaimed. Changes remain local, uncommitted
and unpushed. The remaining production sandbox and lifecycle acceptance gates
are not implied by this source-level PASS.

### Desktop sandbox acceptance preflight

Read-only preflight reused synthetic chat
`01a0f953-ef63-7570-ba62-7dee51e20fa7`. A temporary CONTROL-local config requested
`workspace-write`, approval `never`, network disabled, and only its exact SOURCE
path as an additional writable root. No global configuration was changed.
Completed turn `01a0f9e4-ff1a-7072-ab21-0497836416b1` executed command
`exec-25536a8a-99fd-4313-afc8-bef7eed325be` at the expected CONTROL path and SHA.
Its effective turn context still reported `danger-full-access` and permission
profile `disabled`. The scoped config therefore did not select the intended
sandbox; a successful read-only command is not sandbox acceptance.

The temporary config was removed. No source restore/create/archive, ticket
mutation, or production pilot activation was attempted. Available Desktop
create/follow-up tools expose no sandbox/profile selector. Remaining action is
to select workspace-write for this synthetic chat using the Desktop permissions
control, then independently read back the effective profile and finish the
isolated source-access/broker acceptance cycle. Do not change global permission
defaults, substitute a separate CLI session as Desktop proof, or declare this
preflight a production acceptance PASS.
