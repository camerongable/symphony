# U11 focused test-synchronization corrections

The terminal full gate failed three cases; unchanged-source same-seed isolation
passed all three. This alone did not establish flakiness or an incident root cause.

Test-only changes:

- PathSafety keeps exact ELOOP results and bounded kill/dead checks, with a local
  two-second termination backstop instead of a 250 ms scheduler observation budget.
- Native bootstrap observes requests against a monotonic four-second bound taken
  from its existing runner option. Terminal runner results/exits fail explicitly.
  Final Task.await and every source-binding/allocation assertion remain intact.
- The custom-args fake Codex responds to methods rather than input-line numbers;
  initialized is a notification, not a request. Exact incoming-method order is now
  asserted, alongside unchanged argument, approval and sandbox assertions.

Independent frozen reviews PASS. Named formatting and diff checks PASS. No product
timeouts, source logic, coverage exclusions or threshold changed.

Original exact fake probe at `/private/tmp/u11-core-protocol.zvXqcE` received only
initialize(id1) and initialized(no id), yet emitted id2. The semantic check exited 1.
Original fake SHA: `792eb85c263cac68681dd09066c7fb253ecd6d8f6e046bb2f9c97b5a0b290ed9`.
Corrected exact fake passed the same check, exit 0, with no id2 response.
Corrected SHA: `113f4601f1d44e0b5dec9eaa071d89ffdc3d6dd2c7e18a21cf6e58262604fa74`.
This proves a fixture protocol defect; the deleted full-run trace prevents claiming
it proves the captured timeout mechanism.

Frozen source hashes:

- PathSafety test: `20cf17cb2961770bf886e81130ffad7e7b3ba88692d2383f27f636e322924c01`
- Native binding test after lint extraction: `f9a1dc3d4b2e228270480fe84a62f00f20b3ccde6b4bc9e9a5462060f08a672e`
- Core test: `8f10557e24e8a70ca532f0bdf8e4eb83cbcce8763ae45348257bd7b53e3fa84f`

Root session63036 terminal exit0: the exact three selectors with coverage export,
seed118553 and normal max_cases16 passed 3/0, 61excluded, 3.0seconds. Export:
`elixir/cover/u11-synchronization-regression.coverdata`; log:
`/private/tmp/symphony-u11-post-lint-gate.6mvICy/synchronization-regression.log`.
Export mode does not establish aggregate coverage or final quality-gate acceptance.
The original full-gate HTML was archived before this export run.

Strict lint initially rejected the nested poller (session80221, exit8). Its
Task.yield branch was extracted without changing order or behavior. Frozen
independent review PASS; session71128 strict lint PASS, zero findings. The final
native case was rerun separately against the corrected helper: session23159
terminal exit0, 1/0, 6excluded, 1.6seconds. Its log is
`native-sync-final.log` in the full-gate candidate directory.

Separate Dialyzer session86075 passed, exit0, zero errors/skips/unnecessary skips.
The full make-all command itself did not reach Dialyzer.

Fresh full coverage audit: 8,612/8,728 executable lines hit, 116missed, 98.67%.
At least8,640 hits are needed for99%, a gap of28. The bounded read-only audit did not
identify another defensible public-boundary packet under current constraints.
No metric-driven production change or fabricated ownership was introduced.

Slice5 remains incomplete. No commit, push, deployment, real-ticket mutation or
native model turn occurred in this packet.
