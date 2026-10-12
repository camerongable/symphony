# U7c provenance and presentation increment

2026-10-05. Checkout `/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`;
branch `cgable/desktop-owned-ticket-chat-v1`, HEAD
`52a978818875c59ccf2758ed1b728bb23e33f631`.

Status: bounded provenance/collector/presentation components independently
accepted. Full U7c and the overall goal remain incomplete. No production enablement,
service configuration change, commit, push, deployment or new model turn occurred.

## Implemented

- Scheduler ticket-step publication follows launch/adoption outside the delivery
  transaction. Publication failure reports SYNC_ERROR without undoing candidate,
  iteration, task/evidence consumption or reservation release. Subsequent local
  reconciliation retries presentation even when another role cannot be admitted.
- Parent provenance requires exact native identity/cwd, explicit null Project,
  canonical originating broker ID, complete stored delegation prompt, expected
  namespace/tool, unique completed turn/item and compatible claim timestamp.
  Integer native timestamps retain SECOND precision; coarse overlap is not
  presented as strict subsecond ordering. Malformed history and duplicate identities
  cannot be ignored to manufacture uniqueness.
- Controller collection requests full-item `thread/turns/list` pagination without
  loading/resuming a chat or inference. Missing items, malformed pages, duplicate
  turns, cursor cycles and detected metadata changes reject the read. The existing
  20-second deadline and a 100-page ceiling bound collection. Legacy default reads
  are unchanged. Wrong bound targets and malformed broker IDs reject before reads.
- `factory.desktop read-ticket-turn KEY THREAD --source-thread-id BROKER` exposes
  the collector only for exact already-claimed parent readback. It does not send,
  acknowledge, attach, advance delivery or attest live idle ownership.
- New CREATE/presentation prompts store a request-specific first-line marker and
  exact final JSON acknowledgement instruction before digesting. Historical CREATE
  prompts/digests are reused unchanged. Parent completion rejects acknowledged:false
  rather than recording an unusable SUCCEEDED bootstrap/presentation.

## Evidence

- Publication SQL-trigger fault test: 1/0 in 16.1s, seed 969036; one commit,
  consumed evidence and released reservation survive publication failure. Retry
  publishes without another source turn/commit, including rejected next-role admission.
- Worker lifecycle plus parent/chat/provenance/outbox regression: 48/0 in 227.2s,
  seed 194275 (before final prompt-marker extension).
- Native protocol pagination tests plus provenance: 11/0 in 13.6s, seed 413567.
- Latest five parent/provenance/broker/outbox/CLI suites: 42/0 in 7.3s, seed 967511.
- Final acknowledgement repair regression: 39/0 in 2.4s, seed 905183.
- Final five parent/provenance/outbox/broker/CLI suites after acknowledgement and
  process-unique fixture-root repairs: 42/0 in 1.2s, seed 178928.
- Independent repaired provenance rerun: 8/0, seed 613938; final marker/collector
  extension rerun: 27/0, seed 396456. Component verdicts ACCEPTED. The final
  acknowledgement delta is independently ACCEPTED with no remaining findings.
- Final specs, whole strict lint, format and whitespace checks pass.
  No new full coverage/gate pass is claimed.
  U7b's previous enforced 100% coverage shortfall remains open.

## Actual native read, no inference

The initial read stopped before contacting native runtime because the repository's
default workflow requires a Linear token. Retried using a disposable memory-tracker
workflow at `/private/tmp/symphony-native-read.p6LN1S/WORKFLOW.md`, not service config.

Existing disposable parent `01a0fdb3-7ca5-7150-872e-c77e62dd87b0` returned:

- exact cwd `/Users/cgable/Documents/Codex/2026-10-02/symphony-ticket-probe-mczvph`;
- explicit Project null;
- PAGED_FULL, final cursor null, 24 turns, updated_at 1791153701.

Only initialize, thread/read and thread/turns/list were used. No new message,
resume, source work, chat or inference was issued. The runtime also reported ignored
global config settings; no global config edits were made or claimed fixed.

Separate supported Desktop read/list observations showed current root
`019fa5b7-27fa-7660-ab47-7c3abb867c91` ACTIVE and the old prototype notLoaded.
Those establish a useful owning-Desktop distinction; they do not by themselves
prove empty queue, atomic idle/send ownership or production-marker acknowledgement.

## Limits and next work

Equal updatedAt before/after pagination detects changes, not an atomic snapshot;
same-second changes may escape detection. Provenance receipts explicitly grant
no live-idle, attachment, bootstrap or delivery authority. Historical prototype
bootstrap replied DESKTOP_PARENT_READY, not production acknowledged:true.

Remaining U7c work: durable owning-Desktop guard/claim receipts and queued-send
recovery, parent admission in the existing scheduler, canonical broker skill and
combined ordinary lifecycle acceptance. Then continue subsequent ordinary-path
units and the final coverage/quality gate. Required:yes stays deferred. New native
model-turn trials require the explicit budget approval in U11N; no such approval
is inferred from this read-only experiment.

Official protocol reference: [OpenAI App Server documentation](https://learn.chatgpt.com/docs/app-server).
