# U7c broker-boundary receipt

2026-10-05. Branch `cgable/desktop-owned-ticket-chat-v1`, base HEAD
`52a978818875c59ccf2758ed1b728bb23e33f631`, checkout
`/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`.

Status: bounded local broker component independently ACCEPTED. Full U7c,
whole-branch acceptance and production enablement are not complete.

## Changes and boundaries

Parent pending/claim/store-backed args share TicketChat issuance authorization:
exact current request, immutable payload/generation, explicit enabled allowlist,
linked ordinary contracts and isolated parent route. FOLLOWUP requires accepted
bootstrap. Claim rereads transactionally; superseded/claimed keys cannot send.

Readback separately permits rollback drain without applying changed contract
eligibility as a new-send gate. Durable claim and linked identity are still
required at the authoritative recording API, which completion also uses.
Unbound CREATE remains reconcilable without an output directory; actual proof
recording still inspects the safe directory. No repeated create or source work.

Typed CLI adds `record-ticket-thread` and store-backed `followup-args`. Loaded
policy is forwarded only after startup Policy accepts it. Policy still rejects
enabled ticket runtime, and production tick retains U7a quarantine. Positive
issuance uses internal test fixtures only. Existing uncertain parent requests
can drain through CLI while disabled. Historical TASK quarantine is preserved.

Actionable legacy/parent requests merge by creation order before the limit;
paged filtering skips rejected parent rows without hiding later eligible rows.
Existing outbox coalescing keeps claimed payloads immutable and reports lag
without altering delivery evidence.

## Verification

- `mise exec -- mix test` on ticket-chat, parent-broker, outbox, Desktop request
  and Desktop CLI suites: 49 tests, zero failures, seed 834983, 5.1 seconds.
- Existing worker lifecycle, runner and evidence suites: 43 tests, zero failures,
  seed 938334, 111.6 seconds (23.7 async, 87.8 sync).
- Independent reviewer reran parent-broker and ticket-chat suites: 23 tests,
  zero failures, seed 39859, 1.7 seconds; repaired-source verdict ACCEPTED.
- Public specs, whole strict Credo (203 files, no issues), whole format and
  whitespace checks pass. Runtime hashes match the review snapshot below.
- No full `make all` or coverage rerun for this component. Previous U7b full
  suite passed 1,139 tests but failed its unchanged 100% gate at 99.37%.
  That coverage hold is not waived or claimed resolved.

Tests cover actual durable claim, exact rollback CLI proof and completion,
post-claim contract change, missing claim evidence, deleted run link preventing
completion, invalid attachment observation, stale/coalesced args, immutable
claimed presentation, one-item queue fairness and production config bypass denial.

## Reviewed SHA-256

- ticket_chat.ex: `72a587ef4aedb15e3d4473cf7e36900391656acb5e98b72b3300d0a4e55c92f7`
- desktop_request.ex: `4a495d9fe730046cbacfd9f917dbf93e5626c2333c1e7d0b343d34f0237ab8b0`
- desktop_tool_args.ex: `0cf70a235939dc3a0852737f497c02136ea9143ebfde2d6482783cf034de572e`
- factory.desktop.ex: `53af0aa414c576993078aaa55cece818071eaa38fd57d347b33358dc9bd541ae`

## Remaining U7c work

Native broker origin/prompt and accepted-turn provenance, production-shaped idle
guard/claim receipts and owner-state races, canonical broker skill, scheduler
parent admission/progress publication and combined lifecycle acceptance remain.
Retained feasibility receipt explicitly says
`PROCEED_TO_DISABLED_PRODUCTION_INTEGRATION`, with production enablement false;
it does not prove current production safety. Coverage repair is required before
branch handoff. No live model calls, native chats, Jira/GitLab changes, config
changes, skill edits, service restart, commit, push or deployment occurred.
