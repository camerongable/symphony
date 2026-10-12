# U8b first packet: durable contract-amendment reservation

This packet is implementation, not native acceptance. The local U8a recovery
gate is green. Preserve its production behavior and final regression evidence.

## Purpose and fixed scope

Reserve one durable amendment record for an exact accepted native proposal before
any model invocation or Jira write. This is the missing persistence prerequisite,
not authorization to run the critic or change the installed contract yet.

Owner: one GPT-6 Luna Medium writer. Independent frozen-source review: Sol 6.1
Medium. Source ownership: Store, a new TicketContractAmendment module, the smallest
shared TicketChatCommands input-validation seam, and existing command/migration
fixtures. No Scheduler dispatch, role transport, source rearm, external writes,
native calls, model-allocation changes, or legacy guard changes in this packet.

Read the U8b preparation correction first: another visible Desktop critic CREATE
is not the selected route. Future independent critique must report through the
existing ticket parent without another source checkout.

## Implementation order

1. Inspect the accepted-command validation already owned by TicketChatCommands.
   Reuse that owner for immutable receipt/input/proposal linkage. If a public
   read-only validation function is necessary, extract the existing checks without
   changing answer-only application or direct-rework behavior. Do not duplicate
   the native provenance validator in the new module.
2. Add the next Store migration and its read-only schema requirements. Introduce
   one table keyed uniquely by command_key, with run/chat identity, lifecycle
   generation, phase, exact prior binding, proposed contract revision/Markdown/SHA,
   immutable admission/input references, timestamps, and a nullable error/receipt
   envelope for later guarded progress. Reuse the command payload rather than
   accepting separately supplied Markdown. Record the installed contract preimage
   needed to prove the later transition belongs to this amendment.
3. Implement reserve(store, command_key, controller_context) and get(store,
   command_key). Reserve in one immediate transaction using its callback connection.
   A new row is RESERVED. A duplicate returns the same exact row only if every
   immutable identity/digest matches; conflicting or malformed identity fails
   closed without overwriting it. Do not add a generic mutable progress API until
   its first actual phase consumer is implemented.
4. Reserve only a singleton propose_contract_revision operation from an ACCEPTED
   direct-origin command, bound to the current V1 DELIVERY run, parent generation,
   installed revision/contract SHA, candidate, and native input. Validate the
   proposal with existing Contract parsing/binding APIs; the ordinary route admits
   only exact Required:no. Reject missing/malformed/Required:yes before inserting.
5. Initially admit the plan's two state-specific cases: READY_FOR_REVIEW, or WRITING
   with an exact retained stopped BLOCKED disposition. Use the existing validated
   stopped-result seam for the latter and retain its predecessor references in the
   record. A running/ambiguous writer is not amendment application authority.
   Reservation is planning evidence only, not fresh external authorization.
6. Leave the accepted command, installed contract, run state/candidate, writer row,
   completed slices, result evidence, source reservation, questions, and outbox
   unchanged. Mixed operations remain wholly deferred, not partly applied. They
   still require complete application in the later U8b packet.

The later executor must recheck current identities/facts before effects. It must
preserve a provable predecessor across contract revision changes rather than
calling the old completed-result validator against an already-mutated run and
discovering that its old contract no longer matches. This packet stores the exact
preimage/reference; it does not weaken that validator or implement the handoff.

## Tests and verification

Use existing real SQLite/Git and command fixtures, not a new transport harness.
Add cases for exact READY and stopped-BLOCKED reservations; duplicate and two-
connection race; ledger reopen with identical record; stale input/run/chat/candidate
or contract binding; corrupted admission/input/payload digest; unsupported mixed
operations; and missing/malformed/Required:yes validation. Assert all protected
rows/bytes remain unchanged and no task, request, model, or external action starts.

Cover fresh and existing-database migration, preservation of previous data, and
read-only opening without schema mutation. Freeze actual schema/API details in
the receipt; do not invent a migration version before checking current Store.

Run the new tests plus directly affected command/migration tests first. Then
formatter, warnings-as-errors compile, specs, strict Credo, and Dialyzer. Stop
edits, capture hashes/commands/results, and obtain independent review. This packet
does not replace the later full U8 gate or native acceptance.

## Next packets (not implemented here)

Independent restricted critic attempt/result binding; journaled Jira intent and
readback; state-specific candidate-preserving amendment application; complete
mixed answer/action handling; combined U8/U9 integration. Keep delivery and
maintenance state separate. Native UI visibility and transport proof require
separately authorized acceptance rather than claims from loopback fixtures.
