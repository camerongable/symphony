# U7 integrated quality gate, seed 83681

October 6. Session `1714` is terminal, interrupted with exit 130 after a proven
integration failure. Command:

`HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all`

This was not an observation timeout. The failure and its source-path cause were
read back before interrupting the already-failed gate. The owned test VM and make
process are absent afterward; no push/checkout/file/check helpers remain running.
Source was frozen throughout this run. Its sorted SHA256 manifest of
`rg --files lib test priv` hashed again:
`4c1b99757e56f658038e50be5de8557c56a139c92ccb79bfb07544bd6b4a77f5`.
The command uses `LC_ALL=C sort`, `xargs shasum -a 256`, then `shasum -a 256`.

Additional frozen hashes:

- mix.exs: `c7c0624df3db3c314c985d69e15e9398a61a9defbc3dcca0f7fe011d21199dcc`
- mix.lock: `828d211a3d6a44a4a3c09485c42380936142c57b272613bc84e0a572ef31ebe6`
- Makefile: `0ecad241d67d65b0bae7c0dfe33fb133679ac954c95582b8493e4b8e72d4d985`

Offline setup used locked cached dependencies; lockfile remains unchanged.
Dependency setup reports security advisories in existing packages. No dependency
upgrade or suppression is part of this gate. Build, format, specs and strict Credo
passed (6,202 modules/functions). Coverage tests are now running; the unchanged
100% threshold and Dialyzer remain unproven. No terminal coverage report or full
test count was produced by this interrupted run. Test discovery reports existing helper
files not matching its test-load filters; no tests/skips were modified to silence it.

Before this run, the existing push lifecycle fixture gained two real corruption
checks: a JSON-null handoff cannot prepare a push or qualify completed proof,
and ownership rows remain unchanged. Focused regression passed one test,
zero failures (905112, 35.4 seconds), plus specs/format/Credo/diff whitespace.

No aggregate PASS, Slice 3 completion or production enablement is claimed yet.
Later interaction/rework acceptance belongs to U9/U11, not a new nested-agent
architecture prerequisite. The six U7 requirements must still be audited against
the terminal gate and current component/native receipts.

Observed failure: `factory_desktop_ticket_chat_lifecycle_test.exs:25`, assertion
at line 62 expected `TICKET_REVIEW_READY` on the tick after MR-result adoption,
but received no events. Independent read-only review confirmed the same run is
advanced twice: `run_factory_tick` first performs receipt recovery, then rereads
that run through ordinary advancement. MR adoption leaves `MR_CREATING` with MR
fields, allowing Jira finalization in the same tick; the following tick is already
terminal. The fix must carry the exact selected recovery run ID and skip only that
run during ordinary advancement, including deferral/exception paths. Other runs
must remain eligible. This preserves the existing one-action-per-run-per-tick rule.

Isolated RED repeated the same lifecycle failure (83681, one test, 51.3 seconds).
The private recovery result now carries the selected run ID; public readback strips
that internal field. Ordinary advancement excludes exactly that ID for the rest
of the tick, including handled deferrals/exceptions, without changing legacy or
other-ticket advancement. The lifecycle pins MR_CREATING and only the initial
completed Jira journal on the adoption tick; the next tick finalizes review-ready.
Initial GREEN: 83682, one test, zero failures, 56.7 seconds. Extended two-ticket
fixture additionally proves deferred recovery suppresses only the selected run's
fallback, an unrelated planner still launches, and the original pending-parent
behavior remains after removal of the unproven selector fixture. Combined focused
group: 83683, two tests, zero failures, 57.5 seconds. Independent review accepted
both the production boundary and fixture; specs, formatting, strict Credo (6,203)
and whitespace pass. No guard, timeout or authority was relaxed.

Replacement frozen-source gate is running in session `72112`. Its sorted source
manifest hash is `6c3c1535cfc3357a53ba69c9c86fa81a8805e02f1f7dab8768554c7567353d4b`.
The mix.exs/mix.lock/Makefile hashes above remain unchanged. Follow this exact live
handle; do not infer an aggregate pass from the focused regressions.

Replacement session `72112` is terminal, exit 2, seed 116018. Its source manifest
still matched the frozen hash after completion. Test result: 1,320 tests, two
failures, six intentional live skips, 1,829.6 seconds (157.1 async, 1,672.5 sync).
Coverage is 99.17% against the unchanged 100% threshold. Dialyzer did not run.

Failures:

- `factory_worker_file_tools_test.exs:1033`: final-publication barrier not observed.
  Read-only triage found a nominal 2.5-second marker wait before a late publication
  callback, versus the existing 6-second operation bound. Contention is a hypothesis;
  an early owner/fixture failure or wrapper mismatch remain alternatives. An isolated
  rerun is required before changing synchronization. No timeout has been increased.
- `factory_ticket_worker_lifecycle_test.exs:996` at line 1283: active finalization
  expected an unavailable readback after label issuance but returned unobserved
  effect. Independent source review confirmed SECOND_PENDING starvation: the pure
  recovery selector repeatedly observes an unissued second effect and the new
  single-action suppression blocks ordinary issuance. Normal pre-dispatch selection
  must leave SECOND_PENDING to admitted active advancement, while explicit paused/
  disabled recovery continues readback only. Uncertain issued phases still suppress
  further action on that run during the tick.

No aggregate PASS is established. The next source changes must fix these scoped
failures and use the fresh coverage report, without widening effects, deadlines,
coverage exemptions or production authorization.
