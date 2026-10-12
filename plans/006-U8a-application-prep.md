# U8a accepted-command application

Read after Slice 3 passes its full gate and acceptance audit. This packet refines
Plan 006 U8N; it does not authorize production enablement or another workstream.
Items 1-4 are accepted locally; see `receipts/006-U8a-answer-application.md`.
Item 5 is accepted locally; see `receipts/006-U8a-blocked-writer.md`.
Item 6 is accepted locally; see `receipts/006-U8a-polling.md`.
Explicit same-writer BLOCKED resume is the next packet; its handoff and independent
feasibility constraints are in `006-U8a-direct-resume-prep.md`.

## First implementation packet

1. In `TicketChatCommands`, separate admission from application. `decide/6` currently
   answers questions inside the admission transaction. Preserve its exact admission
   receipt and move the answer effect to `apply_accepted/3`.
2. Add nullable `application_receipt_json` to the command table, initialization
   migration and required reader columns. Existing status constraints already
   permit ACCEPTED, APPLIED and REJECTED; retain them.
3. Apply answer-only commands atomically. Recheck payload digest, accepted receipt,
   exact direct-origin native input, command/input link, chat/run generation and
   current binding. Each answer must match the exact OPEN question and admitted
   question digest. Conditional question updates and command ACCEPTED-to-APPLIED
   CAS, application receipt and event belong in one transaction.
4. Return the stored application outcome on replay. Reject stale accepted answers
   durably without changing the question. Leave mixed or unsupported operations
   ACCEPTED for their owning U8b/U8c implementation; do not discard them or apply
   just the supported prefix.
5. Handle a BLOCKED native writer result through a controller-owned idempotent
   disposition keyed to the original result/digest. Retain RESULT_RECORDED output,
   candidate, checkout, dirty edits and source reservation. Present blockers and
   next action without legacy `block_run`, Jira writes, a successful adoption,
   automatic questions or automatic resumption. A genuine answerable decision and
   explicit resume admission remain separate controller actions.
6. Wire collection/application into the existing normal ready-parent branch of
   `Scheduler.ticket_tick_result/4`. `TicketChatCommands.collect/2` already performs
   read-only native history admission but currently has no production caller.
   Apply only accepted answer-only commands; application alone does not authorize
   a worker launch or resume. Keep parent creation and paused receipt-only recovery
   separate. Readback failures defer safely through the existing ticket event path.
   Verify ordinary role/delivery ticks still advance when no command is present.

Source ownership is assigned per packet to one Luna writer. The first packet owned
`ticket_chat_commands.ex` and `store.ex`; the BLOCKED packet owns the narrow
`worker_evidence.ex`, `scheduler.ex` and `ticket_context.ex` seams and relevant
existing tests. Main does not edit moving source. Stronger read-only review uses
frozen source after focused checks.

## Required focused evidence

Extend existing command and worker-lifecycle fixtures, not a second harness:

- Admission leaves an answer OPEN; application answers once and records APPLIED.
- Restart/replay preserves exact admission and application receipts.
- Stale generation, revision or question digest rejects without answering.
- Unsupported mixed commands remain unconsumed, with no partial application.
- Transaction failure after the answer update rolls back the answer and outcome.
- An old schema migrates; the read-only schema check rejects missing columns.
- Normal ready-parent polling collects/applies an answer once, with no model turn;
  absent, mixed, stale or failed input readback cannot authorize source work.
- BLOCKED disposition repeats without another worker, question, commit, Jira effect
  or release; exact output, candidate/HEAD and held reservation remain unchanged.

Run the scoped command and worker-lifecycle cases, their direct callers, and the
static checks. Acceptance requires an independent frozen-source review of atomic
application, stale-input rejection and blocked-source ownership before U8b/U8c.

## Subsequent adapters

U8b reuses pure contract authorization checks but needs the accepted amendment
executor, journaled Jira write/readback and durable independent critique.
The existing ContractChat rearm mutation is FAILED-only and must not be reused for
an active blocked WRITING or READY_FOR_REVIEW run. See
`006-U8b-contract-adapter-prep.md` for the state-specific adapter gaps.
Preserve the candidate, source checkout and completed slices; invalidate stale
downstream evidence only.

U8c is deferred at the user's request (2026-10-07); this is not completed work.
The retained design reuses existing MR batching/reply semantics through a V1 adapter; existing
MrFeedbackRework explicitly excludes V1. Keep legacy restrictions intact. Accepted
explicit edit batches use the same checkout/MR, capacity admission and fresh verifier.
Conversation-only replies acquire no source reservation; presentation failure cannot
repeat source edits. These adapters may proceed independently only after U8a freezes
its application interface and receipt contract, with one writer per checkout.
