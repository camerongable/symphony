# U8a first packet: accepted answer application

October 7. Accepted locally after independent Sol review; whole U8a and Slice 4
are not complete. No live effects, native model calls, commits, pushes, deployment
or production enablement were performed.

## Implemented boundary

`TicketChatCommands.decide/6` records admission without answering a question.
`apply_accepted(store, command_key, controller_context)` applies answer-only commands
atomically after checking native input linkage/provenance, payload and staging
evidence, current binding, and every open question/value/digest. Conditional question
updates, ACCEPTED-to-APPLIED CAS, the separate application receipt and its event share
one immediate transaction. Admission receipts remain unchanged.

Controller context is the exact projection:
`%{"chat_key" => key, "run_id" => id, "binding" => binding}` where binding contains
generation, spec_revision, contract_sha256 and candidate_sha. Mixed commands remain
ACCEPTED without partial answer effects; later adapters own them. Stale accepted
answers reject durably. Terminal replay validates the stored outcome instead of
reapplying or trusting corrupt receipts.

Store migration 28 adds nullable application_receipt_json, preserves populated
legacy rows, and makes read-only schema validation require the new version/column.

## Evidence and repairs

Luna's first 123-test packet exposed two independent-review findings: terminal
receipt validation and malformed JSON shape handling. Repairs added multi-answer
atomicity, independent binding/question drift, corruption, stable replay/event and
populated legacy-row cases. A subsequent digest type-guard finding was fixed and
tested for integer/null digests with matching payload hashes. Sol accepted the
repaired source, including admission-only rejected replay.

Main's combined run 112005 found a test-only restart race: GenServer.stop on the
fixture's permanently supervised Store restarted a migrator while a second one
opened. stop_supervised! now removes that child before reopen; unchanged migration
assertions pass. Sol accepted the ownership correction. The same 48-test group
passes 112006 (1.2 seconds).

Standalone Dialyzer exposed two unreachable query!-result/nil comparisons; its
short formatter initially threw on the warning kind. Raw diagnostics named both
lines. Removed only those comparisons, retaining SQL updates, changes()==1, CAS
and rollback. Sol accepted reachable-behavior equivalence; no warnings were hidden.

Final combined command/Store migration/chat migration/chat/outbox/scheduler/CLI/
context group passes 146/0 (112008, 7.8 seconds). Standalone Dialyzer passes with
zero errors/skips (62001, 7.49 seconds); strict Credo passes (6,245 functions/modules).
Formatting, public specs and whitespace checks pass. No whole Slice 4 coverage or
native acceptance result is claimed.

Frozen SHA256:

- commands: f8e7f977fa407d062a5430c815dc6251fdbcf7d997f42e52b06f36edfa154057
- Store: 8bdcc053b1d330db5e367862c536cb86aca6334a82f71d36b29d26fe91b12c6a
- command tests: 1b1a310fd060f919a7f8975666c4601e8871c3e4c25314492ef462d1d463ac57
- Store migration tests: ef12436bcf903e925e3d5f14e6ddb17d82b2f044be4bf446ffe13047536e9f6c

## Next bounded packet

Add the native BLOCKED disposition and normal polling collection/application wiring.
Blocked output needs a read-only stopped-result validation seam before adoption:
current adoption calls adopt_completed and may mark the task COMPLETE before
rejecting BLOCKED. Retain original result, candidate, dirty edits and source
reservation; require explicit resume for source work. Keep contract amendments,
MR rework, U9 native acceptance and U10/U11 separate.
