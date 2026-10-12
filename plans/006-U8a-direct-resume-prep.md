# Direct ticket-chat BLOCKED resume handoff

Read-only research, 2026-10-07; proposed implementation, not acceptance. Recheck
the exact APIs and fixtures against frozen source before writing. This is direct
operator recovery, not the deferred tagged GitLab feedback workstream.

Current resume point: the previous Luna packet made no source edits/tests and ended
with a model-capacity error. Its retry was stopped for a fresh bounded-context
handoff; no replacement writer was admitted because the unchanged 20 GB gate
failed (18.15 GB, then 18.08 GB free). The configured capacity/cleanup ledger
returned zero runs, so no policy-qualified cleanup target was available there.
No files/workspaces/caches were removed, and scheduler/broker state was unchanged.
Recheck capacity before admitting a writer; preserve the accepted polling packet.

Canonical authority is a standalone ACCEPTED native `request_rework` operation
whose actual input body is bound into the resumed prompt. An `answer_question`
alone never authorizes source work. Do not add an automatic confirmation question
or reinterpret answered questions as resume authority.

## Existing functions must not be repurposed

`WorkerEvidence.consume/2` requires exact consumed task identity, clean reservation,
adopted HEAD/candidate and then releases ownership. It cannot clear a BLOCKED result
with unfinished dirty edits. Evidence rows have unique reservation keys. An active
canonical source path/git directory cannot acquire another overlapping owner.

The task launcher currently treats every non-CONSUMED evidence row as pending.
Its ordinary new-pass/resume path is designed for CONSUMED evidence. General terminal
retry or legacy FAILED recovery guards must not be weakened to get around this.

## Bounded proposed handoff

1. Require an explicit accepted native command bound to the exact BLOCKED
   disposition, request/output digest, current run/task/candidate and source lease.
2. Prove the prior owner stopped, current path/root/git identity and HEAD/candidate,
   and unchanged lease generation immediately before admission. Preserve dirty bytes.
3. In one immediate transaction transfer the SOURCE owner to a new attempt/reservation
   generation for the same path/task/run, with an exact transfer receipt. Retire the
   old active lease and insert the new owner atomically, with no externally visible
   ownership gap. Do not use the generic clean-release API as proof of this handoff.
4. Retain the original RESULT_RECORDED evidence/output/digest unchanged as historical
   audit. Create new attempt evidence/request under the new reservation; do not reuse
   the old unique reservation key, overwrite its output or delete it.
5. Rearm the same stable writer task/thread with the explicit decision and blocked
   context. Preserve run candidate/checkout/branch and completed slices. Only the
   exact disposition/accepted-resume/transfer linkage may remove the prior blocked
   attempt from normal pending selection.
6. Keep existing source adoption, commit and verification gates for the new result.
   Resume admission itself performs no commit, check, Jira mutation or candidate
   promotion. Replay/uncertainty reconciles the same transfer and request.

Expected production seams: a narrowly guarded WorkspaceAccess transfer operation;
task-launcher pending/historical evidence selection and explicit blocked-resume gate;
TicketWorkerRunner same-thread resume proof. No new writer, checkout or legacy retry
behavior is authorized by this handoff.

## Existing-fixture verification

Use factory_ticket_worker_lifecycle and its real repository fixture. Check the
current BLOCKED preservation test before adding redundant cases: the accepted
packet already proves dirty/untracked bytes and repeated-tick nonadvancement.
For resume, prove one atomic transfer and same task/thread/path/candidate, unchanged
historical output/digest, dirty edits visible to the resumed writer, and no candidate
adoption until a valid new result. Stale output/candidate/task/lease, an unstopped
owner, duplicate admission, and crash boundaries must not transfer or launch twice.

This research did not inspect moving polling source or execute tests/native calls.

## Adversarial feasibility review

Independent Sol read-only review found the transfer feasible with the existing
indexes; it did not execute tests or native calls. Implement these constraints:

- Retire the old active lease before inserting the distinct new lease, within one
  immediate transaction. Both active-path/git indexes reject insert-first order.
  Keep monotonically increasing generation and the original row/transfer receipt.
  Generic acquire is not suitable: it requires a clean, unowned checkout.
- Exclude retained BLOCKED evidence from pending selection only through exact
  accepted-command/transfer/new-request supersession proof, never a broad status
  or released-reservation filter.
- Validate the old stopped result before stable-task rearm changes its prompt/model
  binding and clears output. Historical evidence must not be revalidated against
  the newly bound task; preserve its original exact proof in the transfer receipt.
- Same-thread resume requires observed session/result thread identity equal to the
  predecessor and a distinct new turn. Merely passing resume_thread_id is not proof;
  do not fall back to fresh chat creation.
- Preserve FILE_SOURCE policy and authorized role/model, unchanged HEAD/root/path/git
  identity and dirty bytes. The actual prompt digest must bind the explicit decision
  and blocked context. Inherited edits remain in truthful changed-path reporting.
- Commit transfer, rearm and durable new-attempt identity before spawn. Recovery
  reuses that exact reservation/request. START_SENT/uncertain transport reconciles;
  old request replay cannot reacquire the retired lease or spawn another attempt.

If durable supersession or same-thread observation cannot be proven, keep the
BLOCKED disposition and ownership and reject resume. Do not substitute cleanup,
consume/release/reacquire, a new writer or a new checkout as apparent success.

## Uncertain-start investigation outcome

The existing TaskLauncher pending-result rejection is fail-closed waiting, not by
itself a new BLOCKED-resume obstacle. A live original invocation can bind thread,
owned process and turn, then record its exact result and stop receipt under the
same request. For already-bound uncertainty, WorkerEvidence.reconcile_completed/5
accepts only the same owner/thread/turn/item/schema/pin and valid stop proof.

StageRunner invokes on_session_ready before run_structured_turn; AppServer invokes
on_thread_created while completing thread opening. Persisted native history can
be read without resume/model turns, including paged history with version checks.
None of this permits inferring idle from a foreign cold read or guessing identity.

An unbound START_SENT crash without durable thread/turn/process identity remains
a generic uncertainty boundary. Keep the exact new attempt and ownership waiting
or reconciliation-required; never reset/reissue it or claim automatic eventual
recovery from guessed history. Prove safe RESERVED pre-spawn restart, zero duplicate
start under pending uncertainty and normal adoption after exact bound/stopped
evidence arrives. Report the unbound limitation explicitly in combined acceptance.
