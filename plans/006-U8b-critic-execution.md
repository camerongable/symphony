# U8b critic execution and durable result handoff

Implement after the preparation/claim packet passes frozen review. This packet
must connect actual isolated execution, not treat a journal reservation as a
completed critique. No new visible chat, run, checkout, Desktop request, or source
lease. Live/native acceptance and production enablement remain separate.

## Inputs and sequence

The prepared attempt must bind the persisted post-publication Jira readback of
the exact proposed draft, not the installed run's older snapshot plus proposal.
Preserve that old run snapshot as predecessor evidence. Publication belongs to
the amendment effect journal; do not fabricate a readback or mutate the installed
contract merely to pass admission. The consumer must match the prepared snapshot
to the recorded draft effect/readback receipt before invocation.

Use the existing StageRunner owned-session route. Atomically claim PREPARED to
INVOKING before the call. Supply stored prompt/schema/model/effort, exact-turn
collection, `include_evidence: true`, `worker_access: "REVIEW"`, `ephemeral: true`
and zero format repairs. No project routing, resume/fork, connectors, required
apps, allowed approvals or dynamic tools. Use an existing canonical read-only
control workspace; do not allocate a source checkout.

## Durable boundaries

1. `on_session_ready`: synchronously persist exact thread, REVIEW policy and owner
   PID/invocation nonce before turn execution. Reject the visible parent thread.
2. `on_message` session-started event: synchronously persist the exact matching
   thread/turn. Callback failure raises so StageRunner stops its owned session;
   returning an ignored error tuple is not sufficient.
3. On return: validate stored immutable input/prompt/schema/allocation bindings,
   matching thread/turn/nonempty item, structured output and owned-stop receipt.
   Persist the receipt and task output atomically as RESULT_RECORDED. Do not
   complete amendment application or overwrite writer/run allocation fields.
4. Accept exact replay; reject conflicting replay. Schema-valid REPAIR/BLOCK is
   retained but non-authorizing. PASS qualifies only with empty findings/questions
   and all exact bindings; automatic Jira authorization is a later effect.

The owner-stop receipt must match the stored owner and policy: transport
`owned_app_server`, thread, PID, 64-hex invocation nonce, integer exit status and
canonical cwd. A missing PID or idle thread cannot recreate that receipt.

After INVOKING, restart never invokes/resumes a replacement. Replay a complete
recorded receipt or reconcile the same attempt. Missing result/history/stop proof
is RECONCILE_REQUIRED with retained observations. Ephemeral history persistence
is not proven by fixtures; do not silently switch to a visible durable critic.
An overlapping caller that observes INVOKING must not mutate the phase while the
first caller can still record callbacks/result. Return pending/unproven status
without a second invocation; explicit terminal failure can record reconciliation.

## Verification

Reuse existing StageRunner fake and real SQLite command/task fixtures. Cover
callback ordering and persistence failure before turn, parent-thread rejection,
wrong thread/turn/item/policy/model/PID/nonce/cwd, invalid schema, nonempty PASS
findings, exact/conflicting result replay, REPAIR/BLOCK retention, reopen with
recorded result and uncertain invocation with zero new calls. Assert unchanged
candidate, checkout, slices, writer/task allocation, source lease and installed
contract. Keep single-writer ownership and freeze before independent Sol review.
Run targeted affected tests and static checks; full suite at slice completion.
