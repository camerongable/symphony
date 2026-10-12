# Native context acceptance preflight

2026-10-05. Read-backed local preparation; no new model turn or production change.

The retained parent `01a10da0-e74a-7c82-96f4-926966b24e15` is idle according to
the owning Desktop read. Its last completed turn still reports the missing
context reader; that historical ACK is not functional acceptance.

The retained disposable ledger exists at
`/private/tmp/symphony-u7c-native.jZY8Du/factory.sqlite`. Initial SQLite CLI
failure did not establish absence. The actual application readonly reader
rejected its schema 24 as stale, as intended.

Backed up the isolated ledger to `factory.before-v25.sqlite` without overwriting
an existing backup, then applied the current Store initializer to that fixture
only. Schema is now 25 and readonly admission passes. Compared run ID, execution
mode, state, candidate, revision, contract hash and checkout, plus parent chat key,
thread ID, generation, original creation request and reader binding, before and
after migration: all unchanged. Historical nil reader binding was not filled in.

The actual `mix run --no-compile --no-start` ticket-context command exits zero
against the retained READ-WORKFLOW.md. Readback identifies PROBE-7001/run probe,
the exact parent ID, generation 1, ADMITTING_WRITER, zero implementation iterations
and no worker tasks. This is local executable proof, not native-parent invocation.

Still gated: one separately approved bounded Luna Low native turn to execute
the repaired context command; separately approved canonical broker-skill install;
then production registration/poll routing and the combined Slice 3 acceptance
gate. Plan U7 explicitly prohibits removing the unconditional runtime fence before
actual parent/worker capability acceptance. Do not turn the configuration flag on
or use hand-built enabled policy to bypass that prerequisite.
