# U7c preparation: ticket-parent broker integration

Status (2026-10-05): native context-read acceptance passed and the canonical broker
update is installed after explicit approval; see
`receipts/006-U7C-native-context-accepted.md`. Full U7c is not complete;
production startup/registration/poll routing and combined acceptance remain fenced.
The earlier bounded native test proved transport but exposed missing context access;
that functional gap is now closed. Earlier component receipt:
`receipts/006-U7C-broker-boundary.md`.

## Context reader repair after native test

New scheduler parent admission requires explicit canonical `ticket_cli_root` and
`ticket_workflow`. The workflow must name an absolute database matching the current
ledger. The immutable parent binding retains a context-only executable locator;
CREATE and material FOLLOWUP prompts carry it. Existing nil bindings are not
silently filled. The command base64-encodes arguments and uses `mix run
--no-compile --no-start`; it advertises no staging, broker, or source actions.

Read actions of `factory.ticket` use an existing-ledger readonly connection with
deferred snapshot transactions. They never initialize/migrate a missing or stale
schema. Writable staging remains a separate pending-command action, not advertised
by the reader. Readonly mode is an SQLite enforcement boundary, not an enforced
filesystem sandbox for the trusted Desktop parent.

Five focused suites pass (43 tests, zero failures). The separately authorized
single-turn native context-read proof now passes; see the current acceptance receipt.
Transport ACK alone is insufficient; no full quality-gate or production acceptance
is claimed.

## Subsequent local broker completion work

The native reader now optionally returns a bounded, exact completed result through
`read-ticket-turn --include-completion`; the CLI's explicit workflow also scopes
native configuration and is restored after the isolated operation. Actual readback
on the retained synthetic parent succeeds without a new turn. CREATE now requests
the parent's own supported attachment read before ACK. Independent result/attachment
evidence remain distinct.

The remaining controller outer-timeout coverage gap has a real transport-ownership
loss regression: unchanged helper/runtime, 30-second deadline, retained reservation
and no adopted receipt. Imported coverage proves the outer deadline line executed.
See `receipts/006-U7C-broker-completion-readback.md`.

The canonical broker update is installed and validated. The staged design remains
in `006-ticket-parent-broker-skill-update.md`; the canonical reference is the
operational source of truth. Local production integration and the complete quality
gate must still be finished before Slice 3 acceptance.

## Broker-boundary checkpoint (2026-10-05)

- TicketChat owns issuance checks for the exact stored request, enabled allowlist,
  immutable payload/generation, all linked ordinary contracts, isolated directory
  and accepted parent for FOLLOWUP. Unbound CREATE does not require an output
  directory before the native tool has created it.
- Pending list, claim and store-backed CREATE/FOLLOWUP args share that predicate.
  Claim rereads under the existing transaction. A claimed/superseded request
  cannot authorize another send; pure map builders serialize only.
- Readback is separate: exact durable claim and linked identity remain required,
  while post-claim contract changes or disabled policy do not block draining the
  original operation. Direct recording/completion inherit this predicate, not
  only CLI. Unbound uncertain CREATE stays visible without its directory; actual
  recording still requires the safe directory and exact observation.
- CLI adds typed record-ticket-thread and followup-args. It forwards issuance
  policy only after existing startup Policy validation succeeds. That validation
  still rejects the unsupported runtime; changing enabled alone cannot bypass
  production fences. Positive issuance tests are internal component fixtures,
  not production/native capability acceptance.
- Actionable parent/legacy requests merge in creation order before the limit.
  Paged filtering prevents rejected first-page parents from hiding later work.
  Historical TASK quarantine is unchanged.
- Five focused suites pass (49/0); independent reviewer reran broker/chat tests
  (23/0). Existing worker lifecycle/runner/evidence regression passes (43/0).
  Whole strict lint, specs, format and whitespace checks pass. No full-gate
  rerun or new coverage acceptance is claimed; U7b's coverage hold remains.

Still required: originating broker/prompt and exact native accepted-turn evidence,
idle guard/claim receipts and owner-state races, canonical broker-skill wiring,
scheduler parent admission/progress publication, combined ordinary lifecycle
acceptance and coverage repair before production enablement. Retained native
feasibility evidence authorizes disabled integration only, not production.

## Subsequent provenance/presentation increment

Local origin/turn validator, full-item paginated native collector, guarded
read-ticket-turn CLI, request-specific markers and post-adoption publication are
implemented. Components are independently accepted; detailed evidence and limits
are in `receipts/006-U7C-provenance-presentation.md`. Actual read-only collection
of the existing prototype returned all 24 turns without inference. This narrows
the remaining native unknown to owning-Desktop quiet/queue guard and actual
production-marker acceptance; it does not enable the route.

## Parent followup guard increment

The read-only native queue collector and transactionally retained parent followup
guard are implemented and independently ACCEPTED; see
`receipts/006-U7C-parent-guard.md`. Owning-Desktop status is broker-attested and
separate from cold native reads. A stale/busy/queued observation never claims.
The guard recomputes empty-page evidence; arbitrary empty flags/digests reject.
Focused regression passes (52/0); independent guard/protocol checks pass (6/0).
Real read-only queue collection on the existing disposable parent also passes.
No production enablement or full U7c acceptance follows from this component.

## Front-load native unknowns

Existing-run local parent reservation/admission is now implemented and independently
ACCEPTED; see `receipts/006-U7C-parent-admission.md`. This uses explicit controller
root/broker inputs under the existing stage lock, not guessed host mapping. New
broker identity is persisted immutably through CREATE/FOLLOWUP; historical nil
binding remains nil. Source dispatch and production tick selection remain fenced.
Native current-host mapping and actual broker handoff acceptance await the bounded
test approval already requested. Do not infer approval from an automatic goal turn.

First examine retained feasibility evidence for exact projectless directoryName to
absolute cwd resolution, independently read-backed null project and no attachments,
originating broker/prompt identity, and busy-followup accepted/queued turn identity.
Missing evidence remains uncertain; never retry creation to resolve ambiguity.

## Bounded implementation scope

- ticket_chat.ex: reuse deterministic identity, reservation and proof APIs; expose
  one availability/admission predicate for the current ordinary run/generation.
- desktop_request.ex: gate list, claim and direct issuance for TICKET_CHAT. Historical
  role TASK requests remain quarantined. Allow exact bound readback during rollback.
- desktop_tool_args.ex: store-backed CREATE/FOLLOWUP generators verify immutable
  payload, binding and supported route before issuance.
- mix/tasks/factory.desktop.ex: add `record-ticket-thread REQUEST_KEY
  --payload-base64 ...` and `followup-args REQUEST_KEY`. Existing positional
  record-thread project ID is not a safe representation of null project ownership.
- ticket_chat_outbox.ex/scheduler.ex: publish material progress after evidence
  adoption. Pending presentation never becomes delivery evidence or blocks another
  ticket. Reuse transactional coalescing; claimed/uncertain payloads are immutable.
- Canonical service-factory-desktop-requests skill: explicitly add TICKET_CHAT
  CREATE/FOLLOWUP/readback branch. Do not reinterpret projectless TASK prohibitions.
  Read all applicable skill instructions before this separate canonical-skill edit.

## Broker sequence

1. Verify exact actionable route and generate complete arguments before claim.
2. Claim once, call generated tool once, retain uncertainty on queued client IDs.
3. Read back real thread, actual cwd, null project, prompt marker, origin and empty
   attachments; submit exact tool-argument observation through the CLI proof API.
4. Complete only the exact matching finished request turn and read back SUCCEEDED.
5. After interruption reconcile the same key/thread/turn. Titles, absent history or
   conflicting generations never authorize replacement CREATE or another send.
6. Followup explicitly binds existing parent and stored model/effort. Each parent's
   unresolved uniqueness fences only that parent; shared CONTROLLER uncertainty
   continues to fence shared connector operations.

## Rollback and tests

Disabled route refuses new claims/sends but permits exact already-bound readback and
supported drain/recovery. No legacy conversion, chat replacement or spec restart.
Presentation lag must not become delivery failure or source replay.

Run ticket-chat, outbox, Desktop args/request and CLI tests plus the ordinary
lifecycle test. Cover exact null-project/no-source arguments; cwd/digest/generation
and policy rejection; reserve duplicate/restart/race; CREATE/FOLLOWUP interruption
without duplicate send; CLI malformed/fabricated proof; pending parent isolation;
shared Controller uncertainty; presentation coalescing; rollback completion;
Required:yes/missing/corrupt contract denial at direct APIs and CLI.
Freeze and independently review before combined U7 acceptance/native enablement.
