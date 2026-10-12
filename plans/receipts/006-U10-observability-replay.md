# U10 offline observability and read-only replay acceptance

Completed October 8, 2026; production remains unchanged and the ordinary route
remains default-off. Restricted deployed-broker execution is not claimed.

## Replay

`TicketContext.replay/2` and `factory.ticket replay` expose bounded context,
synchronization, fixed journal/collection high-waters, continuation cursors and
explicit missing evidence. Worker pages retain actual creation/consumption fields.
Read-only opening rejects missing, symlinked and incomplete-schema ledgers without
creation, migration or repair. Review found a missing consumed_at schema guard;
root reproduced it on a disposable copy, the guard/regression were corrected.

Final replay freeze: `/private/tmp/symphony-u10-replay-final.WnqUFL`.
Store SHA aee10bc451a74bc2d3817b5489f88784801fc1d0636c153b116f9127e845d24f;
Context SHA 3e1e149d9075c8c4d2ff8222a6db19a903aca92266679d359ed56ee8a7b5d6f5.
The exact final frozen Store/Context were compiled into a plain VM probe. Trace
covered 268 AppServer functions and external open_port calls: zero during replay,
one for a separate positive control. Valid/incomplete database hashes stayed
unchanged, incomplete schema was rejected, and Mix/Symphony did not start.
Evidence: `/private/tmp/symphony-u10-runtime-preflight-20261008/trace-replay.exs`
and `read-only-probe-receipt.json`. This is not a broker-profile acceptance claim.

## Projection and rendering

Disabled factory and ordinary-route flags are explicit without ledger startup.
Recent/current runs are unioned before once-per-run context enrichment. Legacy or
unavailable parent context remains run-local and does not crash rendering.
Exact parent links, candidate, CI evidence, validation, current/stale question
metadata, trusted next action and parent synchronization are separate facts.
Unknown attributed tokens/cost and physical checkout counts remain unknown;
recorded task lifecycle intervals and checkout intents are labeled honestly.

Final projection freeze: `/private/tmp/symphony-u10-projection-final.hPvc0y`.
Independent standards/spec reviews PASS after correcting disabled-return docs and
SQLite 0/1 validation rendering. Actual LiveView cases pin the integer contract,
sync PENDING→FAILED stability, unavailable parent, disabled state and worker link.
The existing missing TicketPush public @spec was fixed without behavior change.

## Verification

Author focused replay/guard and projection/report/render cases passed. Root's
specified five-file U10 boundary batch passed 45 tests, zero failures, 2.1 seconds,
seed 912236. Root's selected actual LiveView batch passed five tests, zero failures,
24 excluded, 0.5 seconds, seed 859335. Formatting, public specs and diff checks pass.
No full repository suite was used while editing. Operating-model, permissions,
diagnosis and pause-versus-drain documentation were updated in existing guides.

## Remaining gates

U11N: frozen aggregate audit, one full quality gate, separately budgeted integrated
native acceptance including intended restricted diagnostics, and separately
authorized disabled deployment/health readback. Do not enable production, restart
real tickets, turn on native cleanup, or revive tagged GitLab feedback from U10.
