# Plan014 Slice1 checkpoint

Base: `6384f964c7ee6f17dfb16f4acf34f4898becbc19`.
Only completed-native-turn recovery is implemented here; slices2–4 remain pending.
No deployment, live database/API/model operation, external push, or MR mutation.

## Evidence

From this checkout's `elixir/`, using `ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec --`:

- RED: `mix test test/symphony_elixir/factory_completed_turn_recovery_test.exs`
  failed1/1, expected recovered result versus actual `{:error, {:port_exit, 7}}`.
  Log `_build/completed-turn-red.log`.
- Final expanded regression: same command passed8/0 in51.0s.
  Log `_build/completed-turn-matrix.log`. The matrix includes18 malformed/foreign/
  incomplete/oversized native variants and9 durable stop/input/generation cases.
- `mix specs.check` passed. Log `_build/completed-turn-specs.log`.
- `mix format --check-formatted` passed after named-file formatting.
  Log `_build/completed-turn-format.log`.
- `git diff --check` passed; no `elixir/priv` modification.

The8/0 regression preceded whitespace-only named-file formatting. Neighboring
suites and independent review will use the sealed commit; no full quality-green
claim is made. Existing inherited lint/dependency/coverage/Dialyzer limits remain
unretested at this intermediate checkpoint.

## Behavior and tradeoffs

- The real synthetic app-server persists a completed exact turn, emits its final
  item, then exits7 before terminal acknowledgement. The public worker recovers
  without another thread/turn; failed native read leaves the stopped attempt pending.
- A reopened scheduler recovers and normally adopts the same candidate toVERIFYING.
  The fixture needs a prior candidate commit: a base-only no-edit completion was
  correctly rejected by ordinary admission; no production guard was weakened.
- Committed readback is idempotent: one event, unchanged output/stop bytes and stop
  timestamp, and no additional native read. Uncommitted retries must read again.
- An actual SQLite result-write abort rolls back both the event and result.
- An external native-read barrier permits a concurrent durable-state change;
  compare-and-swap rejects it without result or proof event.
- The transient parsed native observation has a2MiB bound. The event retains only
  safe identity/status/observation metadata and parsed-JSON hashes, not native
  reasoning/tool/user-input contents. This does not enlarge any existing cap.
- Existing trusted same-invocation `/5` reconciliation remains compatible; native
  recovery passes a private prepared snapshot rechecked inside its existing rollback
  transaction. No CLI accepts native proof as execution authority.

Remaining Slice1 review should scrutinize input/owner identity, transaction lifetime,
committed readback, event privacy, compatibility, and absence of execution replay.

## Robustness revision

Malformed native status RED at the exact selected test failed1/1 with an
`Access.get/3` exception (`_build/completed-turn-status-red2.log`). The first
line-filter invocation selected an adjacent passing test instead; its log remains
`completed-turn-status-red.log` and is not claimed as RED.

Added explicit map-container and fallible parsed-JSON-encoding checks, not a broad
catch-to-success. Three malformed-observation tests passed3/0 with8 excluded in30.3s
(`completed-turn-status-green.log`). This covers six real subprocess status shapes,
the immediate/scheduler denial path retaining the original stopped failure, and
24 malformed container/timestamp variants through the existing native-reader seam
after an actual AppServer read. The latter is defensive adapter parsing coverage,
not a separate live-native acceptance claim.

The pinned neighboring run at the first checkpoint completed54tests/1failure in75.7s
(`completed-turn-neighbors.log`). The failure is an existing StageRunner assertion
atline751 rejecting the substring `controller mode`, now present in its embedded
complete skill reference. Slice1 does not change prompt generation or that assertion;
independent baseline provenance is pending. No test or host skill was suppressed.
