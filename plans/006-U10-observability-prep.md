# U10 bounded observability handoff

## Dispatch refinement from parallel inspection (2026-10-08)

This refinement is preparation only. U9 acceptance precedes U10 source dispatch.
Do not run a whole test file because a line selector moved: re-resolve the exact
test name and use the supported `--name-pattern` selector instead.

Parallel dispatch ownership after U9 acceptance:

- Replay writer: `ticket_context.ex`, `factory.ticket.ex` and their two sibling
  test files. Store stays unchanged unless a concrete reader defect is reproduced.
- Projection writer: `observability.ex`, `pilot_report.ex` if needed,
  `dashboard_live.ex`, and their observability/report/LiveView tests. Root owns docs.
  This writer uses existing context/synchronization APIs, so it need not wait for
  worker paging and must not edit the replay writer's files.
- Disabled/default visibility currently disappears because Observability returns
  `nil` and Presenter drops the factory field. Prefer a minimal explicit disabled
  projection in Observability, with no initialized ledger or runtime calls; verify
  the existing Presenter handles that map before choosing this seam. If a Presenter
  correction is necessary, assign its file and sibling test to the projection
  writer only. Do not add a new presentation state machine.

Existing interfaces inspected by the parallel agent and checked by root:

- `Store.start_read_only(keyword()) :: GenServer.on_start()` opens an existing
  absolute regular SQLite file using `mode: :readonly`, deferred transactions,
  then validates the reader schema. It performs no initialization or migration.
- `TicketContext.context(store, run_id)` returns the bounded identity/current
  facts and per-collection rowid high-water values. `journal/5` accepts 1..20
  records and `records/6` accepts 1..10; both preserve explicit page cursors.
- `TicketChatOutbox.synchronization/2` is a read. Never use `publish/2` in replay.
- `Mix.Tasks.Factory.Ticket.open_store/2` already uses the read-only Store for
  all actions except `stage`. Add replay to the existing task rather than
  another mutable database-opening path.

One concrete paging gap: `TicketContext.@sources` already supports `worker`
artifacts, but `@collections` omits `workers`. Root inspected the existing
`worker_evidence` table and reader-schema requirements: `request_key`, `task_key`,
`run_id`, `output_json`, status, binding and timestamps already exist. No schema
change is needed to add `"workers" => {"worker_evidence", "request_key",
"worker", "output_json"}` to the existing collection map. Generic run membership
and `collection_sizes/2` already use the collection definition. Worker rows have
`created_at` and `consumed_at`, not `updated_at`; do not invent or synthesize that
column when projecting their receipt order/observed timing. Recheck the final
frozen schema before dispatch.

Keep implementation in small ordered subunits:

1. Read-only worker-receipt paging and replay: existing TicketContext, existing
   Mix task, their sibling tests. Replay is diagnosis, never execution. Capture
   overview/high-water values and expose first bounded pages plus explicit
   continuation cursors; do not read an unlimited history or silently truncate.
   Missing/stale/symlink ledgers reject without creation. Tests compare schema,
   migrations, event/request/intent rows and model/process-call counters before
   and after. Existing output-budget and artifact-digest checks remain.
2. Projection/rendering: existing Observability/PilotReport, DashboardLive and
   sibling tests. Parent identity comes from `TicketChat.for_run`/TicketContext,
   not a writer or contract-chat task. Parent synchronization is separate from
   delivery facts. Unknown factory-role usage remains explicitly unknown;
   direct-session totals are not attributed factory usage.
3. Existing operating-model/README/WORKFLOW sections: document only proven
   behavior, default-off rollout, trusted-operator permissions, pause versus
   draining and separate native-maintenance policy. No new guide/framework.

Dashboard tests extend `extensions_test.exs`'s existing module-unique
StaticOrchestrator and `start_test_endpoint/1` fixture. Keep non-async and full
Endpoint configuration restoration. Existing actual LiveView control-plane,
paused/intake, broker and active-worker-link cases are the seam; no new listener
or production test hook is needed. Assert exact parent URL, candidate and delivery
state unchanged while summary synchronization is pending/failed, open decision
and next action, unknown usage rather than zero, and diagnostic worker visibility.
Add disabled/default visibility to that existing fixture rather than infer it
from enabled-only backend tests.

The restricted no-Mix direct-VM launch below is still unproven. A local Mix
replay PASS is not evidence that the deployed restricted broker can invoke it.
Any separate live-profile probe remains governed by its existing authority gate.

Proposed source allowlist for the later execution packet: TicketContext,
Observability, PilotReport (only if needed), `factory.ticket` task, DashboardLive;
their existing context, observability, report, task and extensions tests. Store
changes require a concrete demonstrated reader gap, not a speculative redesign.
Run named focused cases during editing; the plan's U10 batch belongs at the
unit boundary, and the full repository gate remains U11.

Read-only investigation completed 2026-10-07. This is preparation, not source
implementation, test execution or Slice 5 acceptance. Recheck seams before dispatch.

## Read-only replay

Additional parallel entrypoint investigation: no checked-in non-Mix replay
launcher is available. The ordinary Mix task crosses the established PubSub TCP
startup restriction; `mix run --no-start` is not a proven bypass, and the main
CLI starts the full application. Do not use either as a claimed restricted-broker
read-only solution. A plain runtime function with explicit database/run inputs,
invoked by a direct Elixir VM with existing compiled project/dependency beams and
only required SQLite dependencies started, is a candidate to test—not an accepted
command. Recheck the exact frozen schema and prove runtime/beam availability in
the restricted profile before documenting it as supported. No global runtime
patch, broader broker permissions or new mutable database opening path is implied.

`Mix.Tasks.Factory.Ticket` currently supports context/details/journal/records,
stage/command/synchronization, but not replay. Its `open_store/2` uses writable
Store only for stage; the other actions use `Store.start_read_only/1`.
That reader requires an existing absolute regular nonsymlink DB path, readonly
SQLite mode, the current exact migration set and required reader tables/columns. It performs
no initialization or migration. Reuse this seam; do not invent a second database
opening path or invoke outbox publish for a read.

### Direct-VM candidate from parallel launch investigation

From `elixir/`, with explicit existing ledger and run environment inputs:

```sh
ERL_LIBS="$PWD/_build/test/lib" mise exec -- elixir -e '
{:ok, _started} = Application.ensure_all_started([:crypto, :exqlite, :jason])
database = Path.expand(System.fetch_env!("SYMPHONY_LEDGER_PATH"))
run_id = System.fetch_env!("SYMPHONY_RUN_ID")
{:ok, reader} = SymphonyElixir.Factory.Store.start_read_only(database: database)
try do
  {:ok, context} = SymphonyElixir.Factory.TicketContext.context(reader, run_id)
  {:ok, synchronization} =
    SymphonyElixir.Factory.TicketChatOutbox.synchronization(reader, run_id)
  IO.inspect(%{context: context, synchronization: synchronization})
after
  GenServer.stop(reader)
end
'
```

This is a source-backed candidate, not an executed or supported command. Existing
compiled beams must match the frozen schema/source. Exqlite's app dependencies
include DBConnection and table; DBConnection includes telemetry. Do not start
`:symphony_elixir`, Mix tasks, application runtime supervisors, or outbox publish.
Verify the dependency closure, read-only nonmutation and restricted-profile
execution before claiming this bypasses the broker's observed listener failure.
The parallel investigator ran no command, build, test, ledger or live service.

Add replay help and an `execute/3` clause. Compose bounded TicketContext reads and
read-only outbox synchronization into current binding/candidate/contract, ordered
action/worker receipts, open decision, uncertainty and next action. Keep drilldown
paged rather than silently truncating evidence. Never execute the recorded actions.

Capture task/record rowid and journal event high-water values before paging, then
use those fixed cutoffs so concurrent growth cannot silently reorder a replay.
The bounded context packet is an overview (six newest tasks and four recent
decisions), not the complete history. Expose paged receipts separately and report
missing evidence explicitly. Read synchronization only; outbox publication can
advance cursors or enqueue requests and is not a read-only replay operation.

Existing fixture: `test/mix/tasks/factory_ticket_test.exs` with TicketChatFixture.
Assert schema/migration/events/requests/intents unchanged before/after, missing DB
not created, and model/process-launch counts zero. The current fixture already
covers readonly write/DDL rejection, no startup migration, symlink and stale schema
rejection. Do not claim that merely printing output proves nonmutation.

## Measurements and unknowns

`PilotReport.snapshot/2` is the existing local-ledger seam. Tasks carry role/stage,
model/status/thread/turn and timestamps; model_routes records role/model/effort,
not tokens. Run state events and request timestamps support observed intervals;
gaps remain INCOMPLETE and active/incomplete durations must be labeled separately.
Use the existing fixed-timestamp factory_pilot_report tests.

Per-run/per-turn factory token usage and cost are not currently stored. Keep them
explicitly unknown until a real attributed usage receipt exists. StatusDashboard's
direct-session token totals are explicitly separate and cannot substitute for
factory-role costs. Likewise, a ticket_checkout_intents row is not proof that a
physical checkout exists or an exact historical checkout count.

## Dashboard verification

Existing paths are `test/symphony_elixir/status_dashboard_snapshot_test.exs`,
`test/support/snapshot_support.exs` and
`test/fixtures/status_dashboard_snapshots/*.snapshot.txt`. They verify terminal
StatusDashboard output, not Phoenix dashboard_live. FactoryObservability has its
own backend projection tests. Additional parallel investigation corrected the
earlier missing-LiveView-test conclusion: `extensions_test.exs` already has real
`Phoenix.LiveViewTest` coverage, including `dashboard liveview renders and
refreshes over pubsub` (currently `:489`) and `dashboard and state api expose
the factory control plane` (`:574`). Extend those fixtures rather than building
another harness or treating the terminal snapshots as web evidence.

Concrete existing recipe: use module-unique `StaticOrchestrator`, existing
`start_test_endpoint/1` with `orchestrator`, `snapshot_timeout_ms` and a
`factory_observability` fixture callback, then `live(build_conn(), "/")` and
assert actual rendered factory fields. The helper sets `server: false` and a
test secret; module setup restores the full original global Endpoint config.
Keep cases non-async, use unique fixture data and tear down the connected view
and supervised endpoint; shared PubSub and recurring LiveView timers must not
leak. No separate listener/PubSub startup or production test hook is needed.
Select the relevant/new case through `mise exec -- mix test
test/symphony_elixir/extensions_test.exs:line`. This fixture recipe is source-backed;
new U10 assertions still require their own actual test run.

Refreshed bounded fixture inventory: the control-plane case is at `:574`, the
paused/stale-intake case at `:637`, aggregate broker/unknown-heartbeat cases at
`:771`–`:932`, and active-worker linking at `:1056`. Re-resolve names at dispatch.
These fixtures always inject `enabled: true` and do not currently inject parent
context or synchronization. Add disabled/default visibility, exact parent-link
identity, independent publication-lag state and unknown attributed-usage assertions
to the existing LiveView seam; these older tests do not establish those facts.
The paused case proves neither worker shutdown nor rollback draining.

Incremental parallel projection map: reuse `Observability.snapshot/1` and its
run/task projections, `Presenter.state_payload/3`, and
`DashboardLive.factory_dashboard/1`. `TicketContext.context/2` provides ordinary
parent identity, contract/candidate binding, verifier artifacts, CI, validation,
questions, disposition and next action. Read-only
`TicketChatOutbox.synchronization/2` provides per-parent sequence/request/failure
status; aggregate broker counts cannot substitute for this synchronization.

Link the ordinary parent from context identity through the existing chat URL
formatter; do not relabel a worker/contract-chat task as that parent. Current
`work_progress` is only the latest writer output, not completed-slice history.
Use ordered retained receipts/events with paged drilldown and explicit missing
history. Missing one findings source is not proof of no findings. Consume frozen
amendment/application receipts and trusted next-action semantics rather than
creating another status machine in the presenter.

Expose factory configuration, ordinary V1 enablement, durable pause, unresolved
requests, source ownership and cleanup separately. The current disabled-factory
projection disappears entirely; it does not prove a visible disabled state.
PAUSED does not prove stopped workers or successful draining. Existing fixtures
to extend are factory_observability, factory_ticket_context,
factory_ticket_chat_outbox and fixed-timestamp factory_pilot_report tests.

Name/add an actual Phoenix LiveView fixture when implementing web factory status;
do not use a terminal snapshot or screenshot alone as web acceptance. Show source
stage/candidate, blocker/next action, CI, validation and parent sync lag separately.
Failed presentation must not imply failed delivery. No native cleanup, required
validation or deployment authority is added by this handoff.

## Documentation handoff from parallel preparation

Reuse existing documentation, not another guide:

- `docs/factory-control-plane.md`: Operating model for scheduler/ledger authority,
  broker request handoffs/readback, and the projectless parent as operator-facing
  discussion/summary/command staging. Operator controls and dashboard/cutover
  sections own default-off and draining rollback policy.
- `elixir/README.md`: Web dashboard owns source-work facts separate from parent
  identity/publication lag, questions/next action, diagnostic worker visibility,
  and unknown attributed usage. Direct-session totals are not factory-role cost.
- `elixir/WORKFLOW.md`: disabled ticket-supervisor section owns configuration and
  default-off rollout. Keep native maintenance independent from delivery pause.
- Root README stays high-level. Reconcile existing open limitations in
  `docs/factory-pilot-hardening.md` only when the implementation/tests prove them.

Correct the early implementation README wording that parent instructions expose
only bounded reads: instructions are behavioral constraints, not OS-enforced
read-only confinement. State the trusted-operator permission trade-off explicitly.
Do not claim PAUSED means drained or invent a proven drain API; account for owned
turns and unresolved requests separately. Reuse the existing native-cleanup
default-false/recoverability notes rather than imply archival is enabled.

Document replay guarantees only after U10 source/runtime acceptance. It must read
an existing current-schema ledger without creating/migrating it, publishing,
executing old actions, or waking runtime/model services. The direct-VM candidate
above remains untested. This prose handoff performed no source edits or runtime
effects and does not resolve the acceptance prerequisites below.

## Restricted broker runtime: observed approval prerequisite

The deployed broker's status/list commands failed with `:eperm` while Mix 1.19.5
started its local TCP PubSub subscriber; the resulting outside-sandbox status
request was read back from the broker transcript. No permission changes were
made. Source inspection found no supported knob to skip that subscriber:
`Mix.Tasks.Deps.Loadpaths` starts PubSub; `--no-listeners` does not skip it.
This is an observed runtime failure, not a ticket/source approval.

Removing only the socket dependency would not prove read-only behavior: deployed
`Factory.Admin.overview` opens writable Store and initializes control, while
desktop list also initializes Store. U10 must distinguish truly read-only
inspection from mutation and verify its intended invocation under the broker's
restricted profile. A non-Mix runtime read entrypoint is a proposal, not an
implemented or tested workaround. Do not silently broaden permissions, patch
the installed Elixir runtime, or claim unattended rollout from a successful
unrestricted shell check. New live-profile tests/settings require their existing
separate authority. Use the current Store reader and recheck its exact migration
set after the active amendment writer freezes; do not reintroduce a second
schema/migration owner.
