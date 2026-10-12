# U7 full gate, seed 554420

October 6. Session `3509` is terminal, exit 2. Command:

`HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all`

Formatting, public specs and strict Credo passed before coverage. Dependencies
were resolved from the existing cache without lockfile changes. Source remained
frozen throughout the run.

Coverage tests: 1,318 tests, one failure, six intentional live skips;
2,039.3 seconds (155.4 async, 1,883.9 sync). Total coverage 98.97% against the
unchanged 100% threshold. The gate stopped at coverage; Dialyzer did not run.

Failure: `factory_ticket_worker_lifecycle_test.exs:1413`, typed MR claim/restart
test. At line 1468 its database-trigger rollback assertion expected `Exqlite.Error`
with `fixture claim failure`, but nothing was raised. The assertion does not show
the returned early-rejection reason. The test reuses one ten-second guard across
several prior negative attempts; stale fixture evidence is the leading hypothesis,
not a proven production claim failure. Isolate the case, preserve expiry policy,
and acquire fresh fixture evidence at the rollback assertion boundary.

This run supersedes earlier full-gate results but does not pass Slice 3. Existing
native component receipts and focused tests do not override this verdict. The
separate U7 rollback scope audit also remains an open requirement.

Isolated diagnosis, same seed: one failure in 55.0 seconds. A diagnostic assertion
then exposed `{:error, :mr_guard_native_turn_mismatch}` in 51.6 seconds. Native
latest-turn validation maps its ten-second freshness failures to that reason.
Reacquiring fixture guard evidence at the rollback boundary produced one test,
zero failures in 60.9 seconds. Independent review accepted the correction and
identified the same timing dependency before the stale-owner assertion; fresh
synthetic native observations there preserve the deliberate stale owner timestamp.
The final semantic test delta passed one test, zero failures in 72.3 seconds.
Production expiration windows, authority and runtime deadlines are unchanged.
This focused PASS is not a replacement full-gate or coverage PASS.
