# U7 file-tool timing gate

Source remains frozen during full `make all`, exec session 46496, seed 897146.
Observed failures so far are four cases in FactoryWorkerFileToolsTest: callback
barrier at line 1301, delayed-dispatch barrier at line 1414, traversal at line 523,
and substituted binding at line 768. Barrier guards remain six seconds and the
test timeout remains 60 seconds. Do not weaken them or claim the full gate passed.

Focused 523/1301 run: seed 146304, 2 tests/2 failures, 77.6 seconds. It reproduced
the failures while the full suite was concurrently running, so it does not isolate
host load. Failures occur during native Git/spool work or before fault markers;
none proves an unauthorized file edit.

Scratch `file_timing_test.exs` reuses the real fixture/capability/reservation and
the exact lost-reply transport. Seed 569814, 1/0, 7.6 seconds. Measured workspace
validation 390,360 microseconds, spool observation 145,018 microseconds. The
callback returned success/APPLIED with the expected fixture digest and retained
reply-withheld marker in 5,916 ms, including the deliberate three-second withholding.
No product source, operation timeout, permissions or coverage threshold changed.

Ranked hypotheses: shared-host process/filesystem contention; excessive repeated
authorization; fault fixture exiting before its marker. Measured standalone native
Python/Git startup is fast, but successful callback total is near its deadline and
does not prove isolated traversal performance. Independent read-only timing review
recommends changing only this process-heavy test module from async:true to false
after the existing full run becomes terminal. This preserves actual guards and
serializes it against other async modules. If isolated cases still fail, diagnose
the exact operation instead of increasing deadlines. This is a proposal, not an
implemented/verified fix.

The same full run reached terminal exit 2 after 2,100.8 seconds: 1,300 tests,
four timing failures, six intentional skips; coverage 98.93% against unchanged
100%. Build, format, specs and lint passed; Dialyzer was not reached. Existing
dependency advisories remain, with locked versions unchanged. Reports now describe
that frozen baseline, not subsequent edits.

After terminal output, only FactoryWorkerFileToolsTest was changed to async:false,
with a short explanation of native deadline isolation. No case/assertion, actual
six-second helper/marker guard, 60-second per-test guard, product permissions or
coverage setting changed. The four previously failing cases are being checked first.

The scoped command selected seven cases including the four failures. All seven
passed after isolation: seed 877722, 94.0 seconds, 90 excluded. This supports test
scheduling as a contributor but is not a new full-gate result or an assertion that
the underlying file operation is fast. No further deadline change is warranted.

## Fresh aggregate, seed 101810 (still running)

The fresh gate reproduced a different failure in the existing
FactoryFileWorkerTransportTest case at line 20: the otherwise bound read-only
worker turn returned `{:error, :turn_timeout}`. This fixture is already synchronous;
changing its async mode is not a fix. Its workflow sets the entire model/tool turn
to 5,000 ms, while one file helper alone has a 5,000 ms response bound plus separate
identity/spool/authorization work. The case checks transport/edit correctness, not
a five-second performance contract. Current host load averages were 20.51/17.74/14.56.

Ranked hypotheses for a post-terminal focused check:

1. Whole-turn fixture budget expires during valid bounded controller work. Predict:
   a measured successful callback exceeds five seconds while all operation guards
   pass, and aligning only the fixture turn budget to the composed operation bounds
   allows the exact same edit/receipt assertions to finish.
2. Shared-host scheduling/filesystem contention dominates. Predict: the unchanged
   case passes in isolation and takes longer under the aggregate; timing boundaries
   identify delayed native startup/readback rather than wrong bytes or ownership.
3. Callback/response progression is broken. Predict: the trace never records a
   successful tool reply or completion even with an appropriate whole-turn budget.

Do not change production deadlines, fixture assertions, or safety guards on this
evidence alone. The current full gate remains live in session 20744; wait for its
terminal result before the focused reproduction or source edits.

This aggregate is terminal: 1,301 tests, three failures, six skips; 1,971.2 seconds,
coverage 99.12%, exit 2. In addition to the turn timeout above, lifecycle line 862
exceeded 180 seconds in repeated stopped-push readback, and cached-artifact recovery
line 1033 did not observe `companion-stop-observed`. The marker test was already
synchronous. The next command selects only the transport line 20 and marker line
1033 with their unchanged assertions/deadlines; no aggregate rerun was started.
