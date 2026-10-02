# Plan 002: Preserve and correlate exact worker-turn events

## Executor instructions and baseline

Implement this bounded foundation for plan 001; do not build the ticket runtime
yet. Baseline is `eeb35f137bab759b9960db0e3af265c03fd5c13b`, 2026-10-01.
Root repo: `/Users/cgable/Repos/symphony`; commands run in its `elixir` directory.
Priority P1, effort M, risk MED. No external runtime proof is claimed here.

Drift check: `git diff --stat eeb35f137bab759b9960db0e3af265c03fd5c13b..HEAD -- elixir/lib/symphony_elixir/codex/app_server.ex elixir/lib/symphony_elixir/factory/stage_runner.ex elixir/test/symphony_elixir/app_server_test.exs elixir/test/symphony_elixir/factory_stage_runner_test.exs`.
Confirm code excerpts below still match before editing. Use an isolated worktree,
preserve unrelated edits, and stage only named files. Do not deploy or push.

## Why

AppServer accepts any terminal turn event and drops notifications while waiting
for `turn/start` to respond. StageRunner collects any non-commentary agent message.
That is unsafe as a foundation for workers with multiple observable thread IDs.
Fix it in an explicit strict event mode while retaining the old fixture/API mode
until a new transport selects strict behavior. Do not assume native child fanout
has already happened in production.

## Scope

Only modify/create:

- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/factory/stage_runner.ex`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/factory_stage_runner_test.exs`

Root maintains the plans/index. No schemas, factory DB, scheduler, policy,
canonical skills, configuration files, external connectors or feature code edits.
No dependency upgrades. New public functions need adjacent `@spec`.

## Current seams

- `AppServer.run_turn/4` starts a turn, learns its ID, emits `session_started`,
  then calls `await_turn_completion/4` (approximately lines 184-270).
- `handle_response/5` at approximately 1730-1746 records MCP startup messages
  but otherwise discards notifications while awaiting a request response.
- `handle_incoming/6` at approximately 1163-1189 accepts any `turn/completed`,
  `turn/failed` or `turn/cancelled`, independent of thread/turn IDs.
- `StageRunner.run/5` filters session options (approximately lines 33-52).
  `maybe_collect_output/2` at 153-159 stores any non-commentary agentMessage.
- App-server fixtures in `app_server_test.exs` include fake terminal messages
  without IDs. They must continue passing in legacy/default mode; do not make
  strict mode accept missing identities just to satisfy those fixtures.

Installed 0.159.2 protocol schemas were generated in a temporary directory.
The official repeatable command is:

```sh
task_schema_dir=$(mktemp -d /tmp/symphony-ticket-schema.XXXXXX)
codex app-server generate-json-schema --experimental --out "$task_schema_dir"
```

Turn-completed notifications identify `params.threadId` and `params.turn.id`;
item notifications identify `params.threadId` and `params.turnId`. Inspect the
generated schemas for cancellation/failure and RPC tool-request shapes instead
of inventing fields. No model is invoked by schema generation.

## Steps

### 1. Characterize ordering and ownership with offline fixtures

Follow existing temporary fake-codex executable/test harness. Add focused cases:
matching output/completion before the turn-start response; wrong-child completion
before/after response; wrong turn on the correct thread; matching terminal error;
missing IDs; duplicate terminal messages; commentary must not become final output.
Record actual shapes in fixture JSON and isolate each fake process/trace.

Verify: `mise exec -- mix test test/symphony_elixir/app_server_test.exs`.
The new regression cases should fail on the unmodified parser for the intended
reason (wrong completion accepted or early matching notification lost).

### 2. Add explicit exact-turn event mode and bounded early buffering

Accept `event_scope: :exact_turn` or `:legacy` (default) for the runner's invocation.
Reject unsupported values; do not silently turn them into legacy. Thread identity
comes from the opened session; turn identity comes from the actual start response.
No public arbitrary parent IDs or thread forks are needed.

In strict mode, retain observable turn/item notifications received while awaiting
the turn-start response, emit `session_started` first, then replay retained frames
through the normal completion loop with the now-known exact identity. Put an
explicit finite bound on buffered frames/bytes and fail with a named error on
overflow. Clear invocation-owned buffers on success, timeout, port exit and error;
no frame may leak into a subsequent turn/session. Keep MCP startup handling intact.

Once identity is known, only matching thread AND turn events may contribute
output or terminate the turn. Unrelated events cannot reset the turn deadline
indefinitely; the strict turn has an absolute monotonic deadline. Missing identity
in a scope-bearing terminal/item event is a precise protocol error, not PASS.

Review incoming tool/approval request handling too: wrong-scope or unbound
requests in strict mode cannot execute DynamicTool or auto-approve a mutation.
Use existing denial/error machinery with protocol-supported fields. If safe
request attribution is unsupported, return a named error; do not execute it.

Verify: focused AppServer tests pass, including bounded-buffer overflow, cleanup
after errors, wrong-scope mutation refusal and absolute deadline under noisy events.
Use short fake deadlines; no long real sleeps or model/provider calls.

### 3. Keep StageRunner collection scoped to the same execution

Forward the strict option through StageRunner and the actual AppServer turn call.
Bind the collector to the opened session plus `session_started` turn identity.
Output and required-tool-call collection must reject/ignore another worker's
events, not merely filter terminal completion. Matching early events replay after
the collector has its scope. Collector error/missing identity is not success.
Preserve current schema parsing/format-repair behavior without rerunning tools.

Verify: `mise exec -- mix test test/symphony_elixir/factory_stage_runner_test.exs`.
Add tests proving foreign output cannot overwrite a valid verdict, foreign tool
calls cannot satisfy required evidence, matching early output survives and all
legacy tests still pass. Do not weaken structured result schemas.

### 4. Verify and hand off

Run:

```sh
mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/factory_stage_runner_test.exs test/symphony_elixir/factory_desktop_stage_runner_test.exs
mise exec -- mix specs.check
mise exec -- mix format --check-formatted
git diff --check
```

Expected: exit 0, no failed tests/spec violations/format or whitespace errors.
Inspect all new assertions; passing tests must prove identity and result bytes,
not just PID existence or that an error occurred. Source changed only in scope.
After read-only review, the root may approve a separately requested next slice.

## Done and STOP

Done means strict fixtures reject foreign/unbound output and mutations, preserve
early matching events, bound buffer/time, clear per-invocation state, and leave
legacy behavior unchanged. It is not parent/worker runtime acceptance.

Stop if protocol shapes conflict with generated schemas, the change requires
out-of-scope source, a check fails twice, or you cannot safely bind tool requests.
Report the exact unsupported boundary; never grant broader permissions or invent
a private API. Do not deploy, push, run paid/live tests, create Codex chats,
touch the live ledger, or edit the original checkout.
