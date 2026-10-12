# U7 combined deterministic ordinary lifecycle

No live Jira/GitLab calls, paid model/native turns, deployment, installation,
real-repository commit/push or cleanup. Production remains disabled.

## Implemented and verified

The named `factory_desktop_ticket_chat_lifecycle_test.exs` now carries one run,
SQLite ledger, repository and bound projectless parent through normal ticks:
checkout admission → planner → initial Jira transition → two writer passes →
fresh verifier → push to a disposable local bare remote → MR request preparation
→ typed synthetic broker claim/completion → MR adoption → Jira review-ready.

Only initial fixture arrangement sets source/run state. There is no mid-lifecycle
reinitialization, direct stage/push shortcut or SQL run-state patch. Assertions bind
the same checkout, parent identity, candidate SHA, original pushed handoff, one
checkout intent and released reservations. The final tick changes neither the run
nor Jira effects. Jira snapshots reflect simulated transitions/comments/atomic deltas;
unrelated labels survive. Mutable parent context fields are intentionally not identity.

Existing WorkerServer and MR-guard fixtures were extracted to shared support rather
than duplicated. The old test module aliases/delegates to them; adversarial cases
remain in that module. Test support is explicitly loaded by `test_helper.exs`.

Canonical test: **1 passed, 0 failures**, seed 62926, 48.2 seconds.
The first run reached MR adoption and rejected a fixture catalog missing optional
`include_summaries`; its schema was corrected to the existing accepted reader shape.
No production gate or connector validation was weakened.

The plan's named combined integration group plus the two directly affected old
lifecycle tests passed **111 tests, 0 failures**, seed 474867, 197.4 seconds;
31 unrelated lifecycle cases were excluded by line selection. One now-unused
alias warning from extraction was subsequently removed. Format, public specs,
focused strict Credo and whitespace checks passed. Frozen independent read-only
review accepted this deterministic coverage; reviewer did not rerun tests.

## Boundaries and next gate

Parent/controller setup, role model outputs and broker completion are synthetic.
This is not native permission attestation, live MR issuance or CI-preflight native
acceptance. Actual supported runtime gating still rejects production enablement.
The canonical parent-broker skill was already installed under prior explicit
approval; readback confirmed its ticket-parent reference. The atomic Jira provider
adapter remains staged, with no configured launch-command change in this increment.

The unchanged full `make all` gate is running separately on frozen source. Its result
is not implied by this receipt. Native runtime/permission acceptance and provider
qualification remain required before Slice 3 can be declared complete. Slices 4–5
remain open, and Required: yes stays fenced.

The full gate subsequently completed: 1290 tests passed with 6 intentional skips,
but coverage 97.93% missed the unchanged 100% threshold. Dialyzer was not reached.
See `006-U7-full-quality-gate.md`; this receipt does not claim full-gate acceptance.

## Frozen test identity

```text
ebe4198fceab1f35126b14a43ef45ad8726b4df3470e38cb79487e4b1326fd4f  elixir/test/support/desktop_ticket_lifecycle_fixture.ex
782258924236960559f54f003138ba6dd27093eff09b53ea88915af6351ac8ec  elixir/test/symphony_elixir/factory_desktop_ticket_chat_lifecycle_test.exs
22f56aa0e25e10f01357411bee64e6020dc1ac76ee352aac7b29e9160958676f  elixir/test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
```
