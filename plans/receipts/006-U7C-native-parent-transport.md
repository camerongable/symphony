# U7c bounded native parent test

2026-10-05: two GPT-6 Luna Low turns, one disposable projectless parent, no
source checkout, Jira/GitLab mutation, production configuration, or worker launch.

Fixture ledger: `/private/tmp/symphony-u7c-native.jZY8Du/factory.sqlite`.
Parent: `01a10da0-e74a-7c82-96f4-926966b24e15`.
Actual cwd: `/Users/cgable/Documents/Codex/2026-10-05/factory-ticket-b2d1856a1e35784b21a0`.
Broker: `019fa5b7-27fa-7660-ab47-7c3abb867c91`.

## Proven transport

- CREATE completed in turn `01a10da0-e8d9-7b40-9cd0-0cedad422a92`.
  Full paged native readback verified exact request marker, delegation source,
  immutable prompt, cwd, null project, and final `{"acknowledged":true}`.
- The parent's supported `list_artifacts` returned an empty attachment list.
- FOLLOWUP used fresh owning-Desktop idle observation and independently collected
  empty native queue. Its claim/guard receipt was persisted before the single send.
- FOLLOWUP completed in the same parent in turn
  `01a10da4-080d-7763-86f6-9f1bea576bba`. Full readback bound the exact prompt and
  delegation source; the transport receipt became SUCCEEDED.
- Replay claim returned `ticket_chat_request_already_issued`; unchanged publication
  returned UNCHANGED with `model_invoked: false`.

Creation readback SHA256:
`8032ebb5f36e0762bedb423a4ba6d0268cda63005a240f206e3b05bc84495a2e`.
Followup readback SHA256:
`7c0055fab54b3dd85c00a00fa8e7ffd7b8595b484e02e5d47263a215456057c7`.

## Failed functional requirement

The presentation asks the parent to refresh `factory.ticket` context, but supplies
no callable endpoint or executable locator. The parent explicitly reported this
gap after read-only resource/template discovery, then acknowledged only the
incoming snapshot. ACK proves receipt, **not a durable-context refresh**.

No further native turns are authorized by this bounded test after that first
failed requirement. Implement and test the read-only context access boundary
before another native acceptance run. Production remains disabled; this result
does not complete U7c or slice three.
