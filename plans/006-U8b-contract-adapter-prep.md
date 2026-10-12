# U8b contract amendment adapter: bounded research handoff

## Current mixed-rework repair packet

Atomic answers/rework is accepted locally after prepared authority/replay,
legacy receipt and mixed rejection repairs, exact saved-buggy RED/fixed GREEN,
scoped statics and frozen reviews. Initial green checks alone were not acceptance.
Evidence and retained snapshots are in `receipts/006-U8b-mixed-rework.md`.
Preserve its canonical answer/native proofs when implementing the following unit;
keep one source writer and freeze before review.

## Following answer-plus-amendment unit: concrete application map

Parallel read-only preparation identified these current seams; recheck after
mixed-rework acceptance before changing them:

- `TicketContractAmendment.reserve/3` and `apply_authorized/4` own reservation
  and final install/replay. Final revalidation, conditional run install and
  application receipt share the existing Exqlite transaction.
- `no_competing_current_work/2` currently requires zero OPEN questions. Permit
  only the exact questions answered by the admitted mixed command; unrelated
  OPEN questions still reject final install. Do not answer them early merely
  to make this guard pass.
- `valid_payload_proposal?/2` currently permits a singleton proposal. Keep that
  historical shape valid and recognize the complete specified mixed shape,
  not a supported proposal prefix within arbitrary operations.
- Jira `publish_draft/4`, `readback/2`, `publish_authorization/5` and
  `readback_authorization/4`, plus `TicketAmendmentCritic.execute/6`, remain
  unchanged effect boundaries. Questions stay OPEN through draft uncertainty,
  non-PASS and incomplete/uncertain authorization.
- At final install, validate selected OPEN rows against the ORIGINAL run/chat
  binding. Question CAS, run CAS and terminal receipts share one transaction;
  a later failed write rolls back both answers and contract install.
- Question storage already has binding/body/answer schema/opened timestamp,
  status, answer_json and input_key. No question migration is required merely
  to record answers. The existing protected-row snapshot omits questions: add
  a mixed-only answer-application proof bound to native input/payload and
  original rows, keeping singleton receipt shape compatible. APPLIED replay
  verifies immutable answered history without applying again or requiring
  the old live run image.

Reuse Jira draft (`:102`), critic BLOCK (`:145`), qualifying authorization
(`:886`), READY install (`:1168`), terminal rollback (`:1281`) and historical
replay (`:1219`) cases; re-resolve names/lines after edits. Keep parsing/native
admission checks separate from authorized-install proof. No new harness or
extra slow processes are implied.

The nil-recovery manifest does NOT list the Jira-operation test or Jira/critic
modules. Their observed source is preparation, not manifest-pinned acceptance.
Its `4f069a...` entry is the Store migration test, not the Jira-operation test;
do not infer drift from comparing different paths. Freeze all actual inputs
for this later unit independently.

## Required first-writer blocked recovery gap

This finite prerequisite is accepted locally; see
`receipts/006-U8b-first-blocked-amendment.md` and its final manifest. Preserve
its nil/HEAD/original-binding distinctions in the remaining mixed-command work.

Normal polling found that a stopped first writer can retain SOURCE ownership
with `run.candidate_sha == nil`. Existing amendment storage and hash validation
reject that reservation. This is an ordinary contract-recovery case, not a reason
to invent an adopted candidate, restart specification/implementation, or drop the
case from acceptance. Plan a bounded correction that preserves the exact nil
run binding while independently proving the stopped writer's checkout HEAD and
retained evidence. Recheck schema migration, SQL conditional-null comparison,
critic/journal binding, application/history validation and prepared resume against
that distinction. Existing-candidate recovery must remain unchanged. Keep the
real normal-tick regression; do not substitute out-of-band run SHA assignment.
Implement/review this correction after the current scheduler packet is frozen,
before whole-Slice-4 acceptance.

The bounded investigation identified these concrete changes to verify after freeze:

1. Distinguish adopted `candidate_sha` (still nil) from retained
   `checkout_head_sha`. Measure HEAD without cleaning/resetting dirty source;
   reservation-time access `expected_sha` is not necessarily current HEAD.
   Put the separate HEAD in immutable predecessor/application proof rather than
   treating it as an adopted candidate. Existing `predecessor_json` can carry it;
   its exact-shape validator must evolve compatibly for historical receipts.
2. Add the next migration after schema 35. Permit nullable candidate only in
   amendment, critic-attempt, draft-effect and authorization-effect tables while
   preserving rows, FK references, indexes and receipts. Update exact reader
   migration/schema expectations. Reuse the proved leased-connection rebuild
   strategy; test populated upgrade, failure rollback and read-only opening.
3. Restrict the nil case to WRITING with independently validated stopped BLOCKED
   evidence and a separate valid HEAD. READY still requires an adopted candidate.
   Preserve nil exactly in critic/effect/run-binding identity and all history;
   audit validators and both run-install CAS statements (`candidate_sha = ?`
   cannot match nil; use null-safe comparison without broadening other guards).
4. Correct amendment-specific SOURCE transfer and prepared resume: prove nil
   candidate plus the recorded HEAD, remeasure HEAD before transfer, and pass that
   HEAD as resume `expected_sha` without changing the run candidate. On historical
   reopen/replay, validate immutable predecessor/receipt proof instead of demanding
   old live HEAD after subsequent authorized source progress. Do not loosen ordinary
   WorkspaceAccess or existing adopted-candidate comparisons globally.
5. Extend existing reservation/critic/Jira/application fixtures, migration fixtures,
   and the real polling/held-resume case. Prove nil remains nil, dirty stopped evidence
   is retained, no initial writer is recreated, resume reuses the existing writer,
   changed HEAD is rejected before transfer, and adopted-candidate history still
   passes. Run changed focused cases then freeze for independent review.

This is a finite recovery correction before mixed-command implementation; it is
not authorization for a new state machine, extra checkout or automatic resume.

Independent plan critique adds these acceptance constraints to the same fixtures,
not a new test framework:

- Preserve three distinct values: original stopped task/access `expected_sha`,
  measured checkout HEAD, and nil adopted candidate. Test different original/HEAD
  values; only the amendment-bound successor may use measured HEAD as expected SHA.
- HEAD is not a digest of dirty edits. Include staged, unstaged and untracked
  first-writer edits and compare index/bytes before amendment and resume. Never
  clean/reset to qualify. Use retained-workspace evidence for any same-HEAD content
  check; do not pretend HEAD alone proves it.
- Retaining dirty data is not permission to bypass the controller's slice commit
  checks. Mixed staged/unstaged/untracked data must retain its existing rejection;
  workers cannot manufacture commits. Prove successful normal-poll adoption with
  a valid declared-path slice separately if needed. Candidate remains nil through
  amendment/preparation, then becomes the real controller-committed SHA on adoption;
  nil in VERIFYING is not successful completion evidence.
- Seal measured HEAD with exact stopped task/result/access/lease identity and
  conditionally revalidate ownership at reservation and transfer. Owner/lease drift
  must produce zero install, transfer or successor writes.
- Keep disjoint historical receipt shapes: legacy adopted-candidate proof remains
  valid unchanged; nil-candidate proof requires sealed HEAD plus stopped-WRITING
  authority. Missing/corrupt HEAD cannot fall through to the legacy branch.
- Nullable fields do not replace exact amendment/critic/effect validation (NULL
  can bypass matching constraints). Migration tests preserve dependent rows,
  indexes/version and original connection FK setting, with FK check before success.
  Rollback must never fabricate candidate hashes for valid nil rows.
- Separate historical terminal replay from launch authorization. Replay after
  authorized successor progress uses immutable history; an unstarted prepared
  successor still proves its recorded HEAD and ownership before launch. Pin crash
  after preparation, pre-launch drift and later-progress reopen with no duplicate
  transfer/writer or inferred candidate adoption.

First-writer correction fixture selection (parallel read-only handoff; re-resolve
line selectors after freeze):

- `factory_ticket_amendment_critic_test.exs`: extend the populated version-35
  rebuild test (currently `:364`) for the next four-table migration; it already
  contains amendment, critic, draft and authorization rows. Retain exact-turn
  critic, READY application, APPLIED-history replay and terminal-write rollback
  cases (currently `:755`, `:1077`, `:1128`, `:1190`) for unchanged old behavior.
- `factory_ticket_amendment_jira_operation_test.exs`: extend draft/readback nil
  identity (`:102`), retain reopen/reconciliation (`:131`) and source-preimage
  fencing (`:218`); reuse `accept_proposal`, `reserve_operation`,
  `amendment_context` and `protected_rows` rather than building another fixture.
- `factory_ticket_worker_lifecycle_test.exs`: extend the amendment-specific
  held-resume/reopen case (`:477`) and prepared resume (`:1435`) only after
  current source freeze. The real normal-poll case remains necessary.
- Lower-level initial-source bootstrap (`factory_workspace_access_test.exs:167`)
  and completed-result inspection (`factory_worker_evidence_test.exs:136`) can
  prove isolated bindings, not stopped-first-writer amendment or resume behavior.
- Use the existing populated amendment migration fixture, not unrelated
  request-table `factory_ticket_chat_migration_test.exs`. Update exact Store
  reader/version expectations where the new migration requires them.

Run affected selected cases through `mise exec -- mix test path:line` (or current
name selector), not the full suite during iteration. Logical nullable-storage
checks must never stand in for actual stopped-SOURCE/poll/resume evidence.

## Next mixed-command test packet

Selected explicit answer-plus-contract grammar for the next unit (not yet
implemented): one to three existing valid answer lines, optionally one blank
line, then the exact standalone separator
`--- FACTORY CONTRACT REVISION ---` followed by a newline and nonempty contract
Markdown. Resolve answers with existing question rules; require distinct resolved
question keys. Example:

```text
Answer Q-17: yes
Answer Q-18: 3

--- FACTORY CONTRACT REVISION ---
## Contract
Updated scope.
```

Emit exactly ordered answers followed by one proposal (maximum four operations).
Recognize the separator only after the answer preamble; preserve all subsequent
Markdown byte-for-byte for native/payload comparison. Command-looking lines and
further separators in that Markdown are literal, never source actions. Apply
existing revision-header normalization only later, after proving the original
raw native/payload binding. Preserve singleton formats unchanged. Rework in the
answer preamble, reversed operations, duplicate answers, malformed/empty sections,
missing/wrong delimiter or a staged extra rework operation reject the whole body;
do not consume a valid answer prefix. Answer-plus-rework retains its distinct
existing grammar. Contract-plus-rework is not authorized by this new format.

Extend existing native admission/replay and unsupported mixed-proposal prefix
cases. Pin exact leading/trailing contract newlines and literal command text,
plus wrong delimiter/order/tampered extra-operation rejection. Parser acceptance
alone does not establish atomic question/amendment application.

Parallel read-only test selection identified existing cases in
`elixir/test/symphony_elixir/factory_ticket_chat_commands_test.exs` to extend:

- `active-turn staging waits for direct completed input and consumes a question plus request exactly once`:
  prove answers and same-candidate rework transfer commit together, or neither does.
- `multiple answers apply only after every question remains current`:
  valid first answer plus invalid second answer yields zero answer/transfer/task/effect changes.
- `candidate drift after acceptance rejects without answering`:
  assert mixed commands also create no transfer or source effects after drift.
- `answer-only application and replay survive a database reopen`:
  extend to one mixed terminal receipt and one successor across reopen/replay.
- `a crash after an answer update rolls back the application but retains accepted input`:
  reuse its transaction-failure pattern for combined answer/action rollback.
- `accepted direct proposal reserves once without changing protected ticket state`:
  add answer-plus-amendment; keep the question OPEN through draft, non-PASS and
  incomplete authorization, closing only with final atomic authorized install.

Reuse existing amendment and Jira-operation fixtures; do not create a new harness.
Select the changed cases by final test name/line during iteration. Normal polling
and held-resume integration depend on the scheduler packet being frozen. Command
tests alone cannot prove those paths. This checklist is preparation, not passing
coverage or permission to apply a supported prefix of a mixed command.

Next implementation seam to verify after the scheduler freeze:
`TaskLauncher.create_blocked_resume/2` performs SOURCE transfer, task preparation
and `WorkerEvidence.reserve/2`, then calls
`TicketChatCommands.record_rework_transfer/3` inside its preparation transaction.
The latter currently requires a singleton rework payload. For mixed answers and
rework, validate every answer against the original question/run binding before
that transfer; persist answer updates and the existing transfer receipt in the
same transaction. Do not answer first via a separate `apply_accepted/3` call.
Prepared-resume replay must prove the same whole-command receipt, rather than
re-answering questions or manufacturing another successor. This is an identified
seam, not a claim that its rollback or replay behavior has been implemented.

The parallel stable-seam investigation confirmed that
`TaskLauncher.prepare_ticket_task/1` owns the outer `Exqlite.transaction` and
rolls back any preparation error. The mixed recorder must use that connection,
not open a nested command transaction. Add a command-owned preflight after
stopped-predecessor proof and before SOURCE transfer: reparse the exact admitted
native body, compare the ordered payload, and validate every answer against the
original chat/run/question binding. Do not trust caller-supplied question rows.
Keep the legacy singleton path and permit only the defined answer(s)-then-rework
shape for the mixed path.

At the terminal recorder, revalidate the accepted command and use conditional
OPEN-to-ANSWERED updates tied to its original input. A failed answer update,
transfer, task/evidence write or receipt/event write must roll back the entire
outer transaction. Preserve `BLOCKED_WRITER_RESUMED` and its existing
predecessor/successor fields. Add only necessary answer-proof linkage.
`reuse_prepared_blocked_resume/2` must validate that linkage against persisted
ANSWERED rows and reuse the recorded request; it must not apply answers or
transfer again. Pin both pre-transfer failure and final-recorder rollback in
existing fixtures. These are implementation requirements awaiting source tests.

Status: read-only preparation, not implementation or acceptance. Source was
inspected by the parallel contract-adapter agent on 2026-10-07. Recheck relevant
guards against the frozen U8a packet before implementation.

## Preserve the existing recovery boundary

`ContractChat.rearm_delivery/6` is a FAILED DELIVERY recovery path. It requires a
newer authorized contract, a terminal writer, no unresolved writer requests and
no competing active run. It increments the attempt, consumes the previous writer
and changes the run to WRITING. Do not loosen that guard to accept an active
blocked WRITING run or READY_FOR_REVIEW run.

The interrupted-rearm helpers recover a previously journaled rearm only. They
are not a general contract-update interface. Reusable pure checks include
`ContractChat.source_sha256/1`, `changed?/2`, and snapshot-contained authorization
checks in `Contract`. The existing writer-workspace check is private and coupled
to legacy rearm validation.

## Minimal missing adapter capabilities

Final mixed-command integration must also address these frozen-source findings:

- `apply_accepted/3` applies answers only; scheduler dispatch recognizes singleton
  rework only. Keep mixed input as one logical command, at most one source action,
  with no supported prefix applied independently.
- Native answer-plus-rework grammar exists. Contract grammar currently anchors
  `Revise the contract:` at the beginning and treats the remainder as Markdown;
  answer-plus-contract needs an explicit unambiguous grammar and native-frame
  linkage tests, not merely accepting a staged mixed JSON payload.
- Apply answers in the same blocked-resume transaction for answer-plus-rework.
  For amendments, keep questions OPEN until final proven local application, then
  atomically apply answers/install the contract/record the terminal receipt.
  Validate old question bindings before changing the installed revision.
- Preserve the `BLOCKED_WRITER_RESUMED` predecessor/successor receipt shape used
  by WorkerEvidence, TicketWorkerRunner and prepared-resume recovery. Do not call
  old-contract completed-result validation after mutating the run binding.
- READY_FOR_REVIEW currently bypasses ticket command collection via delivery
  join handling. The frozen scheduler investigation identified three guards:
  `advance_ticket_runs/3` SQL excludes READY, `ticket_tick_result/4` routes READY
  to delivery joins, and `ticket_ready_parent_locked/3` repeats the allowed-state
  restriction. Correct all three narrowly; do not leave READY amendment support
  reachable only by directly calling reservation APIs.

Use existing command/native and stopped-writer lifecycle fixtures. Pin no partial
answer while publication is pending, final atomic mixed completion, stale-question
rollback, one same-thread successor on replay/reopen, and normal READY polling.
Tagged GitLab MR feedback remains deferred, but direct mixed commands do not.

Parallel stable-fixture preparation: ordinary `TicketContext.question_projection`
compares the exact generation/revision/contract/candidate binding and exposes
digest-pinned body/schema artifacts. Do not substitute legacy
`Contract.questions_digest/1` for the ordinary command question digest. Reuse
`TicketChatFixture.stage/4` and `native/2`; duplicate tests must replay the same
native object, not regenerate timestamps/identities. Its idle `parent_guard/1`
cannot stand in for busy-parent proof.

Accepted-API grammar refresh: answers parse one line at a time, keyed as
`Answer <question-key>: <phrase>` or unkeyed only for exactly one eligible
question. `Rework: current candidate` is admitted only after at least one answer;
the singleton rework grammar is unchanged. The ordinary question digest covers
canonical JSON of body, answers schema, opened timestamp and binding; application
also requires OPEN status/current binding and opening before input start.
`apply_accepted` still applies answer-only operations, and
`record_rework_transfer` still requires singleton rework. Their mixed atomic
completion therefore remains unfinished, not implicitly supported.

`Revise the contract:\n` at the beginning consumes the entire remainder as
Markdown; amendment validation still requires a singleton proposal. Mixed
answer/proposal staging JSON alone is not native authority. A combined format
must introduce an explicit bounded section boundary and preserve exact raw
body/payload provenance before revision normalization. Do not infer a supported
action from a prefix or strip apparent commands out of arbitrary Markdown.
Proposal-plus-rework remains safely unsupported unless an explicit whole-command
format and atomic application are implemented; no partial source action is allowed.

Pin rollback for an invalid second answer, stale candidate, insufficient writer
capacity and a failed transaction: zero applied answers and zero source transfer
or launch. Answer-plus-amendment must leave questions OPEN during uncertainty,
non-PASS critique and incomplete authorization, then reject body/schema/binding
drift at final application. Contract-plus-rework must not fall back to a source
action after an unsupported or failed amendment. Resolve exact mixed ordering,
question digests and original-versus-installed bindings from frozen source after
corrected-proposal work; this preparation does not accept those active interfaces.

Normal-poll adapter handoff: `tick` reaches `advance_ticket_run/3` and
`ticket_ready_parent_step/3` under the existing per-run lock. The latter reloads
binding, collects native history and calls `apply_or_advance_ticket/4`, which
currently selects the oldest ACCEPTED command and recognizes singleton rework
only. Fixture injections must enter `context.ticket_options`; top-level tick
keywords alone do not reach this path. Reuse its current Jira reader, existing
control workspace and configured critic policy, preserving stored writer routes.

After API freeze, consume existing durable amendment phases in order:
reservation, draft readback, critic preparation/execution, authorization
readback, application. Critic execution owns its claim; do not claim twice.
Resolve uncertain/invoking work by readback first, without resending mutations
or starting another critic. Recorded non-PASS is stable until an explicit
qualified correction; answer-only cannot bypass it. Keep model/external calls
outside DB transactions. No command on an unchanged READY run is idle, not an
initial writer launch. Reuse normal-tick and held-writer fixtures to prove all
three READY guards, oldest-owner correction, phase-boundary reopen, zero blind
retry and unchanged idle invocation counters. Signatures and terminal states
must be revalidated against the corrected-proposal writer's frozen API.

1. Bind an accepted command to its exact native input, current ticket generation,
   revision, candidate and proposed contract text. Unsupported or mixed commands
   must not apply a supported prefix.
2. Persist an external-effect intent before any Jira write. Fresh issue/preimage
   checks and exact comment readback may reuse `JiraMcpWriter`; uncertain outcomes
   reconcile the same operation, never blindly repeat the mutation. External calls
   occur outside database transactions.
3. Support an independent, durably bound contract critique without creating a new
   SPECIFICATION run or attaching another checkout. The current V1 worker role
   gate/packet/schema only permits planner, writer and verifier. A bare
   `StageRunner.run/5` call does not establish durable task/evidence ownership.
4. Add a V1 state-specific amendment application path for the retained BLOCKED
   WRITING result and for READY_FOR_REVIEW. Preserve the same candidate, checkout
   and completed slices; invalidate only evidence made stale by the amendment.
   Do not invoke the FAILED-only mutation as an adapter shortcut.
5. Persist the terminal application receipt only after exact write/readback,
   critique and authorization have been proven. Recovery resumes those recorded
   boundaries without restarting specification or initial implementation.

## Verification to implement with the adapter

### State-specific application seams from frozen-source preparation

Capture `WorkerEvidence.completed_result/2` and exact task/evidence/access/run
preimage before installation. `WorkspaceAccess.validate/4` and
`TaskLauncher.create_blocked_resume/2` independently compare the old contract;
capturing a stopped result alone does not make their post-install checks pass.
Use a narrowly amendment-bound predecessor path, not a temporary old-run rewrite
or a weakened ordinary validator. Preserve stopped-owner, digest, root/Git/HEAD,
task scope and lease checks; only prove the old-contract-to-authorized-successor
comparison through the durable amendment receipt.

- BLOCKED amendment alone keeps candidate, checkout, slices, old task/result and
  held SOURCE lease. The scheduler must recognize its retained disposition rather
  than calling old evidence validation against the new revision every idle tick.
  Do not consume/transfer it or start source work merely to suppress that error.
- Explicit rework validates that predecessor and prepares the same writer under
  the new contract in one transaction. Preserve `BLOCKED_WRITER_RESUMED` receipt
  predecessor/successor fields used by existing supersession/restart joins, adding
  amendment linkage. Reapply the normal feature-writer allocation, not the critic's.
- READY_FOR_REVIEW retains candidate/checkout/slices and old evidence as history,
  increments verifier round and transitions to VERIFYING. Admit no planner or
  initial writer. READY is filtered by outer `advance_ticket_runs/3` as well as
  inner delivery joins; its bounded command intake needs both seams addressed.
- Fresh PASS then follows the same-candidate push/MR receipt joins. Tests must
  prove no replacement MR or repeated prior remote effect under the new revision.

Terminal application needs sealed at-apply pre/postimages and immutable proof
references. APPLIED replay must remain readable after legitimate state, snapshot,
allocation, verification and candidate progress without resetting the live run or
requiring it equal the old application image. Live admission checks stay strict.
Once active_owner is released, reservation must admit a later amendment while
validating historical terminal records; a valid inactive record is not a permanent
one-amendment-per-run lock, and a corrupted inactive record must not be ignored.

Extend existing stopped-disposition, transferred same-thread resume, rollback,
RESERVED/START_SENT reopening, exact stopped verifier and CI-preflight regressions.
Keep FAILED-only `ContractChat.rearm_delivery/6` unchanged.

Use the existing command, contract and contract-chat fixtures. Cover exact-input
binding; duplicate/restart replay; uncertain Jira mutation readback; stale
authorization/candidate; blocked active-run amendments; post-PASS amendments;
and fresh independent critique. Confirm no new source writer or checkout is
created merely to answer a question or draft a contract.

This handoff authorizes neither live provider calls nor changes to legacy guards.
Tagged GitLab MR feedback is separately deferred by the user.

## Jira effect scope: preserve the ticket description

### Corrected proposals after a recorded non-PASS

Do not leave a BLOCK/REPAIR amendment permanently owning the oldest accepted
command. A later explicit native corrected proposal may supersede it only after
validating the stopped recorded nonauthorizing critic, exact draft readback,
both native inputs and unchanged installed delivery binding. No authorization
effect may exist; INVOKING, uncertain effects and reconciliation-required
attempts cannot be superseded. Answers alone are not replacement authority.

Seal predecessor/successor input, proposal, draft and critic references in one
transaction that releases the old owner, terminally rejects its command and
reserves the successor. Preserve every old admission/result/effect receipt.
Replay must validate historical linkage rather than alter the installed run.

Revision and publication baseline need explicit predecessor linkage: installed
r1 plus failed published r2 requires corrected r3, obtained from fresh source,
not installed revision plus one. Publish against the sealed predecessor draft
readback while retaining r1 as the delivery preimage. Do not temporarily rewrite
the run or accept arbitrary intervening source changes. Extend existing command,
amendment and Jira fixtures for replay, rollback, competing replacements and
normal-polling starvation. This is an implementation requirement, not acceptance
evidence; the successor path is not implemented yet.

The read-only seam investigation identifies two existing hard-coded assumptions
to replace narrowly: `TicketChatCommands.proposed_contract/3` uses the installed
revision plus one, and `TicketAmendmentJiraOperation.effect_binding/4` with
`validate_effect/3` uses the installed run snapshot as the publication baseline.
Keep installed-contract validation intact. A corrected successor needs a
separately sealed failed-draft baseline and `Contract.next_revision/1` from its
fresh, exact readback; it must not borrow the held-writer predecessor field.

The existing partial unique amendment-owner index provides the transaction
fence. Extend the journal's terminal lifecycle only as needed, and update its
read-only schema acceptance alongside migrations. The existing canonical critic,
native input, draft and authorization validators remain authoritative. Admission
must reject any predecessor authorization-effect row, not merely a completed
authorization. Preserve all historical records and seal the ownership-transfer
link so replay validates it without changing the installed run. Ordinary polling
must be able to select the explicit correction despite the oldest non-PASS
command; answer-only input is not a correction.

Use the existing command, critic and Jira-operation fixtures to prove revision
selection, publication baseline, stopped BLOCK/REPAIR, uncertain/invoking fences,
authorization-row rejection, competing corrections, rollback and historical
link corruption. This seam map is preparation, not implementation or acceptance.

Migration prerequisite from a parallel generic in-memory SQLite 3.50.4
experiment: rebuilding a populated parent CHECK constraint requires preserving
all columns/constraints/indices and child foreign-key targets. The documented
create-new/copy/drop-old/rename/index sequence succeeded with foreign-key
enforcement disabled on that connection before BEGIN and restored afterward;
an injected unique-owner failure rolled back schema and rows. Disabling foreign
keys inside an existing transaction was a no-op. Merely deferring foreign keys
failed at COMMIT despite an empty precommit check. See SQLite's generalized
ALTER TABLE procedure. These are generic findings, not Exqlite/Store acceptance;
the actual migration must prove populated upgrade, child integrity, rollback and
restoration of its original connection setting in the existing repository fixture.

`Contract.authorized_from_snapshot/2` extracts exact digest-bound draft contracts
from Jira comments. The amendment can therefore reuse the existing contract
publication convention: a newer exact draft comment followed, only after bound
critic PASS, by its automatic authorization comment. Do not add description
replacement as a prerequisite; no atomic remote description compare-and-swap
capability has been proven, and this workflow need not overwrite user prose.

Freeze the fresh source observation and require description/summary/user-comment
preimages to remain unchanged, allowing only this amendment's recorded factory
comment additions. Each effect needs a durable intent and one-time claim before
the external call, followed by exact readback. A restarted uncertain claim reads
only; an invisible target does not authorize another write. `JiraMcpWriter`'s
within-call readback retries are useful, but do not themselves prove durable
cross-restart deduplication. Keep `TicketJiraJournal`'s existing fixed operation
guards intact; the amendment owns its own effect receipts.

Acceptance requires `Contract.authorized_from_snapshot/2` to return exactly the
proposed issue/revision/Markdown/SHA and exact Required:no, with the critic proof
bound to the recorded attempt. Do not mutate delivery state while publication
is partial or uncertain, and do not rely on the old contract remaining latest
after a newer draft has been published. Use the retained predecessor/preimage.

## Crash-boundary refinement for the next implementation

Keep critic attempts amendment-owned, not pretend Desktop CREATE requests.
The Desktop request queue requires project/worktree creation identities and is
not a transport-neutral queue. Register the critic under the existing delivery
run without overwriting its writer/task/model allocation fields.

Prefer a small lifecycle: PREPARED, INVOKING, RESULT_RECORDED, and
RECONCILE_REQUIRED. Thread/turn identities are durable evidence fields, not extra
workflow phases. Commit an exact compare-and-swap to INVOKING before the provider
call. Only PREPARED can invoke; reopening INVOKING must never launch or resume a
replacement. Synchronous identity callbacks must abort on persistence failure,
not return ignored error tuples. The immutable proposal/preimage stays separate
from mutable critic progress.

Record exact prompt/schema/allocation/snapshot binding before invocation, and
output/thread/turn/item/policy/owned-stop evidence before result adoption. A
complete recorded receipt can replay; missing owned-stop proof cannot be inferred
from an idle thread or missing PID. Only exact PASS with empty findings/questions
can authorize the proposal; other critic outcomes remain durable and visible.

Existing native readback uses a fresh process and persisted history. Ephemeral
history availability after process loss is not proven. An unavailable history
must retain the attempt and require reconciliation, not switch to a new visible
critic chat or repeat the uncertain invocation. Native acceptance must prove this
boundary separately before production enablement.

Use existing command/SQLite/task fixtures for duplicate claims, reopen before
launch, crash after claim with zero relaunch, callback failures, stale bindings,
exact replay, mismatched stop/results, and unchanged writer/candidate/lease rows.
Add the missing focused StageRunner owned-REVIEW receipt assertion before wiring
the critic consumer. Run these affected tests and static checks; defer the full
suite until the slice boundary.

## Transport correction: preserve one visible ticket chat

The earlier project-local Desktop CREATE recommendation is withdrawn: it would
create another visible critic chat. A FOLLOWUP in the parent is also not evidence
of independent critique. The user accepts isolated role workers reporting through
Symphony to the existing parent; a native collaboration parent-link is not itself
required.

Existing `StageRunner.run/5` with `include_evidence: true` returns structured output,
thread/turn/item identity, policy, and an owned-process stop receipt. AppServer's
restricted `REVIEW` route supports a read-only control workspace without a source
checkout, no connectors/network, and no interactive approvals. This is an existing
independent execution seam, not yet a complete amendment adapter.

StageRunner does not currently forward `ephemeral`, although AppServer supports
the option. Chat visibility, uncertain-result recovery, and exact durable
amendment/task/result linkage still require implementation and acceptance proof.
Do not claim native behavior from local fixtures or introduce an extra visible
chat as a substitute for that proof. No new native model calls were authorized by
this preparation.

## Next bounded packet: durable critic transport

Parallel read-only preparation identified these concrete seams; no code or tests
were changed by that investigation:

- Reuse `StageSchemas.for_stage(:specification_critic)`,
  `Prompt.specification_critic/3` and the existing `ModelRouter.resolve/3` role
  allocation. Do not overwrite stored writer allocations.
- Investigate the existing restricted, independent StageRunner route above before
  implementing the adapter. Existing task/request persistence can retain identity,
  but DesktopStageRunner project-local CREATE is not the selected transport.
- Add a narrowly gated V1 amendment-critic branch in TaskLauncher, bound to the
  accepted command and amendment under the existing delivery run. Do not expand
  the source-worker role allowlist or create worker_evidence/workspace_access
  records for this no-checkout critic.
- Durable attempt metadata must bind run/issue, command and admitted input/digests, chat
  generation, prior revision/contract SHA, candidate, proposed revision/SHA and
  source snapshot digest. Existing request payload hashing then covers the binding.
- Amendment results need a specifically bound validation path. Preserve the
  legacy specification-critic normalizer, which assumes an installed SPECIFICATION
  run contract. Only exact bound PASS with empty findings/questions may authorize.
- Reconcile the same durable task/request on restart or uncertainty; do not create
  a second critic or repeat an uncertain Jira effect.

Use existing task-launcher, structured-stage and request fixtures to prove
the exact V1 gate, configured allocation, no-checkout transport, deterministic
attempt identity and mismatched-input/candidate/revision rejection. Connect these
receipts to amendment command tests only when its executor is implemented. This
packet alone does not prove the complete contract-amendment workflow or live
single-parent interaction.

## Durable amendment progress prerequisite

The immutable accepted command retains the proposed Markdown and native-input
binding. Its `application_receipt_json` is a terminal outcome, not a mutable
progress journal. Existing events preserve history but have no unique
command/effect key or phase CAS; they cannot alone arbitrate retries safely.

TicketJiraJournal is constrained to START_IMPLEMENTATION and REVIEW_READY and
must not be generalized by weakening those guards. U8b needs a command-keyed
durable progress/ownership seam for external-write intent, exact readback,
critic-attempt linkage, and state-specific application. Freeze that schema and
recovery contract before source implementation. External calls remain outside
database transactions; uncertainty retries readback, not an unproven write.
