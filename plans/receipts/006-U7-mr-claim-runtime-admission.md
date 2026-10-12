# U7 shared typed MR Desktop claim admission

Both generic DesktopRequest claims and TicketMrOperation argument-returning claims
now use `DesktopRequest.claim_mr_followup/4`. The old outer transaction in
TicketMrOperation is removed. The shared boundary captures the exact request/run,
preflights binding, authority and guard, probes the configured runtime outside
SQLite, and reads fresh Jira authority afterward. A supplied pre-probe authority
is not reused to send work. Request/run drift fails before commit.

One transaction formats exact arguments, rechecks the captured run/request and
existing claim receipt/guard/controller/ownership facts, records the immutable
claim and marks the request uncertain. Arguments are returned only after commit.
Duplicate and historical readback paths do not probe or issue another request.
No runtime-qualified flag, cached token or separate queue was introduced.

RED seed 708929: the old generic entrypoint admitted an unsupported runtime.
The corrected claim test initially exposed a reused fixture guard aging across
negative attempts; the positive retry now collects a new fixture observation.
The production ten-second guard deadline was not changed. GREEN seed 521872:
1/0, 32.5 seconds, including trigger rollback, ownership/controller conflicts,
both unsupported-runtime entrypoints, exactly-once arguments and restart readback.
After equivalent lint-driven helper extraction, claim plus post-probe Jira-block
regressions passed 2/0, seed 856557, 53.3 seconds. A real initialize marker proves
the fake Jira reader observes ai-blocked after the probe, not only beforehand.

The final drift, normal review-ready lifecycle and legacy DesktopRequest group
passed 18/0, seed 549823, 76.9 seconds (39 unrelated lifecycle cases excluded).
The fake process changes request, run or controller state through independent
SQLite access during initialization; no uncertain claim is recorded. Independent
frozen-source review accepted the shared boundary. Public specs, strict Credo
(6,173 modules/functions), formatting and whitespace checks pass. No live Jira,
GitLab, model turn, deployment, global setting or real ticket was changed.

Remaining U7 integration: pure static Policy replacement plus one Supervisor startup
probe from the supplied settings, default-disabled/rollback checks, then aggregate
acceptance. Runtime probes must not move into Policy or list/idle/readback paths.
Current rollback quarantines advancement while retaining readback; this receipt
does not claim automatic draining, Slice 3 completion or production enablement.
