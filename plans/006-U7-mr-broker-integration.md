# Typed V1 MR broker handoff

This is the staged route-specific reference for the existing Desktop broker skill.
It is not installed and does not authorize production issuance. The runtime Policy
gate remains authoritative. After acceptance, add a conditional pointer for exact
CONTROLLER FOLLOWUP requests with `metadata_json.delivery_operation` containing
`operation: CREATE_OR_REUSE_DRAFT_MR`; keep legacy controller handling separate.

1. Load the listed exact request. Require its immutable request marker, typed
   delivery operation, current configured controller Project/thread and resolved
   model/effort. Unknown or unlisted routes remain unclaimed.
2. Start `factory.desktop claim-ticket-mr-interactive REQUEST_KEY` with the exact
   workflow and `--source-thread-id` of this configured broker, using interactive
   stdin. A policy error stops this path; an in-memory test factory is not runtime
   authority.
3. Wait for its `OWNER_OBSERVATION_REQUIRED` JSON line. Match the exact request,
   controller and broker. No send arguments or Jira authority are in that line.
4. Read the controller through owning-Desktop `read_thread`. Preserve the actual
   raw schema-versioned response and observation timestamp. A summary, missing raw
   response, wrong identity, active turn or frozen/unreadable chat is insufficient.
   Send one JSON line on stdin with exactly `request_key`, `source_thread_id` and
   `owner`. The owner envelope contains `source: codex_app/read_thread`, its actual
   `observed_at`, and the raw `response`; do not invent or refresh observations.
5. The CLI gathers native facts and atomically claims. Use the returned exact
   `arguments` for one `send_message_to_thread` only after reading the successful
   `FOLLOWUP_UNCERTAIN` response. Validate against the callable schema. The model
   and effort come from the request; the broker's own model is not substituted.
6. If the CLI dies, times out, returns an error or loses its final response, read
   the exact request. An unchanged PENDING request may obtain wholly fresh evidence
   on a later attempt. Any issued/uncertain state is readback-only: do not reformat,
   re-claim or send it. Successful issuance records the same bound thread and exact
   completed turn/result/tool evidence through existing request readback commands.

The command reads Jira directly, enforces the original freshness deadlines, and
keeps the source checkout/candidate/contract/controller binding. It does not send
a Desktop prompt itself, start a model turn, create a writer/chat, change Jira or
GitLab, or enable the route. Before installation, acceptance must prove the actual
broker's raw owner response and stdin transport, one native send, exact result
adoption and restart/no-resend behavior. Fake child-process tests are not that
acceptance proof.
