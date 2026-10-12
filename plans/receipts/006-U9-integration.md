# U9 ordinary integration

Status: IN_PROGRESS, not Slice 4 acceptance. Sole writer extends the existing
desktop lifecycle fixture from real ai-ready scheduler intake. Starting source
bindings are pinned in `006-U9-start.sha256`; preserve inherited dirty changes.

## Baseline evidence

Existing canonical case `one uninterrupted ordinary run reaches review-ready
through normal ticks and synthetic broker readback` passed with seed 60202:
1 test, 0 failures, 3 excluded, 52.7 seconds, exit 0. Raw log:
`/private/tmp/symphony-u9n-integration/canonical.log`.
Root read back the named terminal summary. This old case starts from seeded
admission, so it does not prove real ai-ready intake or complete direct rework.
An earlier seed 60201 logging wrapper lacked its output directory and returned
pipeline exit 1 despite a test 1/0 summary; it is not product failure or a clean
logged gate. Use the correctly captured seed 60202 baseline above.

## Remaining acceptance

Actual intake through the stable parent/checkout, adopted writer, fresh verifier,
exact CI, draft MR/readback, review-ready, direct rework and fresh verification;
stored-result/pre-adoption and pending-summary reopen barriers; missing/malformed/
Required:yes side-effect fences; legacy compatibility; independent frozen review
and scoped integration gate. Native busy-parent/human input is not proved by
offline fabricated transcripts and still has its separate authority boundary.
No real ticket, commit, push, deployment or native acceptance was run here.

## Intake-extension checkpoint

The optional unregistered fixture and configured Jira search now reach actual
scheduler registration. Initial failures exposed missing fixture route labels and
the required orchestrator-intake model policy, not a demonstrated product defect.
Root read seed 60207's precise assertion failure in
`/private/tmp/symphony-u9n-integration/intake-canonical.log`: actual registered
state ADMITTING_WRITER versus the test's expected PLANNING, 1 test/1 failure.
The ordinary route intentionally admits a writer directly; correct the fixture
assertion rather than add a planner or normalize SQL state. Parent-create
readback and the subsequent lifecycle still require proof. This checkpoint is
failure/diagnostic evidence, not a passing U9 gate.

Seed 60210 reached normal parent CREATE/readback, writer, verification, push and
MR preparation, then failed `mr_guard_broker_mismatch` in the synthetic broker
handoff. Raw log `intake-canonical-60210.log` records 1/1, 3 excluded, 35.0 seconds,
exit 2. Existing `DesktopTicketLifecycleFixture.mr_guard/1` supplies the older hardcoded broker
identity instead of the configured broker used by the fresh parent. A narrow
fixture-identity correction is authorized, preserving its legacy default and all
product guard checks. The initial report misattributed this helper to
TicketChatFixture; the actual helper is in the already-assigned desktop fixture.
No new harness or product authority bypass is authorized.

Author reports seeds 60211/60212 reached READY_FOR_REVIEW, then exposed remaining
fixture-only hardcoded `run` lookups and native `stage run` command strings.
Use the scheduler-issued UUID consistently, preserving legacy fixture defaults.
TicketChatFixture's pre-edit hash is now in `006-U9-start.sha256` for that narrow
dynamic-run-ID extension. No complete passing intake-driven gate is claimed yet.

## Intake-driven canonical PASS (partial U9)

Seed 60214 passed: 1/0, 3 excluded, 52.2 seconds, exit 0. Raw log
`/private/tmp/symphony-u9n-integration/intake-canonical-60214.log`; root read the
named terminal summary. It now starts without seeded run/task/chat records,
registers through Jira search and Scheduler.tick, binds the parent through its
CREATE request/readback, and follows writer/verifier/push/MR and existing amendment
recovery using the actual UUID. This is not complete U9 acceptance.

The required review-ready direct rework path is a real remaining product gap:
Scheduler routes request_rework only to stopped-BLOCKED WRITING recovery and
TaskLauncher has no ready-run source rework API. Do not omit this requirement or
claim the old contract-amendment path proves it. A bounded stronger design
diagnosis is reviewing only the immutable seven-file snapshot
`/private/tmp/symphony-u9-rework-diagnosis.0oQPL9` before a named existing-module
extension. The sole writer continues independent intake-fence/restart fixtures;
product files remain untouched until that handoff. Native acceptance remains
separate; no new engine, tagged-MR adapter, live effects or authority bypass.

## Frozen fixture checkpoint and prerequisite dispatch

Canonical intake/restart seed 60217 passed: 1/0, 3 excluded, 53.2 seconds,
exit 0, `intake-canonical-60217.log`. Required/malformed/read-failure intake fence
seed 60302 passed: 1/0, 70 excluded, 1.7 seconds, exit 0,
`intake-fences-60302.log`. Author scoped statics passed. Five-file fixture freeze
is `006-U9-fixture-checkpoint.sha256`; root matched all five and retained immutable
review copy `/private/tmp/symphony-u9-fixture-review.O84Mzd`.

The diagnosis and adversarial prerequisite review confirmed the missing ready
rework seam and four finite constraints, now in
`../006-U9-ready-rework-handoff.md`: fresh verification despite preflight,
same-SHA MR receipt collision, explicit fresh READY Jira authority, and immutable
predecessor/recovery binding. Fresh Luna medium sole writer
`ready_rework_implementation` started at capacity PASS 32.45 GB. It validated
fixture/amendment baselines and proposes existing records/receipts only, no new
schema/module. A reviewer checks the immutable fixture checkpoint concurrently;
no reviewer accesses the active writer checkout. Full U9/Slide 4 is not accepted.

Independent static review returned finite PASS for the frozen offline fixture
checkpoint: no seeded/normalized delivery rows; ordinary parent request APIs;
stored result/evidence survive pre-adoption reopen without relaunch; exact pending
summary request survives reopen; missing/malformed/Required:yes/reader failure
fences and opt-in fixture-default compatibility are asserted. All five immutable
snapshot hashes matched before/after. Synthetic persisted parent/broker readback
is not an actual native tool invocation. This does not accept ready rework or
the full U9/native busy-input requirements.
