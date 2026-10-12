# Staged canonical broker update

Installed on 2026-10-05 after explicit user approval in
`/Users/cgable/.agents/skills/service-factory-desktop-requests`. The canonical
entrypoint routes to `references/ticket-parent.md`; existing TASK/CONTROLLER and
maintenance instructions remain unchanged. Independent forward-check identified
and corrected the exact `response` field and supported candidate discovery path.
This file records the staged design; the canonical reference is the operational
source of truth. Production routing remains disabled.

## Entrypoint change

Before handling any `target_kind: TICKET_CHAT`, require the exact
`desktop_owned_ticket_chat_v1` route, deterministic chat/generation/directory,
stored broker identity and immutable request marker. Read the ticket-parent
reference below instead of the TASK/CONTROLLER branches. Unknown routes remain
unclaimed. A production policy error is a stopped issuance, not permission to
invoke lower-level APIs with a hand-built enabled policy.

## Ticket-parent reference

The broker creates and presents one projectless parent. Role workers are owned
by the controller's internal worker runner; they are not new Desktop stage chats.

### CREATE

1. Generate `create-thread-args REQUEST_KEY` before claiming. Verify the returned
   projectless directory, model, effort, title, full prompt and request marker;
   use the returned argument object unchanged.
2. Claim once. Call supported `create_thread` once. A client ID or ambiguous
   result retains CREATE_UNCERTAIN. Discover/read the same accepted parent;
   never substitute Project ownership, retry CREATE, or replace the chat.
3. Read `read-ticket-turn REQUEST_KEY THREAD_ID --source-thread-id BROKER_ID
   --include-completion`. Retain its full-history provenance receipt. It binds
   the completed delegation envelope, actual null Project, exact cwd and prompt.
   This is persisted history, not an idle-state or attachment proof.
4. Prove the same parent's own empty managed-attachment observation from its
   completed supported `list_artifacts` call. Retain the native provenance receipt
   separately; the typed `record-ticket-thread` payload accepts exactly
   `request_key`, `payload_sha256`, `generation`, `thread_id`, `project_id: null`,
   `cwd`, `tool_arguments` (the generated object) and `worktree_attachments: []`.
   These facts must come from the observed parent, not the broker's own chat.
   Missing, conflicting,
   or unobservable attachments stay in reconciliation; no manufactured ownership.
5. Submit the returned `completion` object unchanged to `complete` after the
   typed parent observation is recorded. Read back SUCCEEDED. ACK is only a
   presentation receipt; source/delivery evidence remains controller-owned.

### FOLLOWUP

1. Generate `followup-args REQUEST_KEY`; verify it names the bound parent, exact
   model/effort/prompt. Read the parent's live owning-Desktop `read_thread` response.
2. Immediately submit `claim-ticket-followup REQUEST_KEY --source-thread-id
   BROKER_ID --payload-base64 OWNER_JSON`. OWNER_JSON has exactly `source:
   "codex_app/read_thread"`, `observed_at` UTC timestamp and the full structured
   owning response. The controller collects the native empty queue itself and
   requires the observation to be at most ten seconds old. Busy, queued, stale
   or unavailable observations leave the request unclaimed.
3. After this invocation's successful claim, send the previously generated
   arguments once. Interruption after claim is uncertainty, not another send.
4. Reconcile using the same full-history read command, typed parent observation
   and unchanged `completion` object. Presentation failure stays separate from
   candidate/adoption evidence and never causes worker replay.

### Recovery and boundaries

Paused/disabled mode permits only exact readback/draining of already claimed
operations. Pending parent requests remain pending. Malformed or ambiguous native
final results remain reconciliation cases; never invoke legacy format-repair
rules for a TICKET_CHAT request. The parent context reader exposes bounded reads;
it is not broker/source authority. Empty queues and unchanged material snapshots
produce no model turn.

The readback command's optional completion extraction is deterministic. It admits
one final-phase JSON acknowledgment from the attested turn, bounds its size, and
returns only observed successful MCP tool names. It cannot replace live owning
status, direct supported attachment observation, native command execution proof,
or the production acceptance gate.
