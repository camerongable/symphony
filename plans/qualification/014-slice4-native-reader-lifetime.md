# Plan014 Slice4 checkpoint

Base: `25114d5016240d1714cd96853d7b23a0cb0def1b` (accepted Slice3).
This slice changes only the AppServer native-reader interface, owner-admission
context, broker lifetime handling, narrow public tests/fixtures, and behavior docs.
TicketMrOperation, TicketMrPresendRecovery and all private helper bytes are unchanged.
No live service, schedule, SQL, product, GitLab/model operation, push or deployment
was performed. Plan022 remains separate and untouched.

## Timing and ownership contract

The warm native reader initializes before owner preadmission, whose existing slow
runtime/physical/push/history qualification ends with a real branch observation.
No timestamp-only refresh was substituted. Only the existing ephemeral admission
context retains the reader; public prepare/known-result output and SQLite do not.
It binds current Erlang owner, connected port, actual PID, canonical cwd, and exact
process-local identity. Foreign/tampered live readers deny. Closing an owned dead
port is idempotent/effect-free without an accumulating closed-handle registry.

Finalization consumes the handle, parses fresh Desktop owner evidence, retains
final physical delivery-facts equality, and collects fresh target thread/latest/
queue/version/confirmation data on that already initialized actor. It never
starts/resumes/forks a thread or starts a model turn. Collection is bounded by
min(existing20s, remaining admission lifetime). Expiry remains exactly
min(auth+60s,runtime+60s,remote+10s). Slow final physical/read work can still deny.

Warm readers remain linked to their owner. No BrokerRuntime trap_exit or generic
EXIT sink was added; unexpected abnormal failures remain fail-closed. The legacy
one-call reader explicitly retains its unlinked lifetime and shared total20s
deadline, and existing owned-worker reader behavior is unchanged. Close drains
only that reader's messages, not unrelated owner messages. Reader state/handles
are not restored after restart. Registered idle-port data/status invalidates only
its admission context. The :recover ordering and one-call path remain unchanged,
including all stable broker/source proofs.

One intentional tightening is tested: a finalize rejected during argument/request
parsing also consumes/closes an identifiable native-reader handle. The earlier
wrong-key test expected that handle to remain; it now expects empty admissions and
unavailable replay, while retaining all ledger/request equality assertions.
Contexts for :recover have no warm reader and are not changed by this cleanup.

## Red and green evidence

Commands ran from `elixir/` with
`ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec --`.

- Initial fixture diagnostic used placeholder branch/commit URLs and failed the
  existing exact GitLab branch validator. Corrected to actual candidate/branch
  URLs; no production guard was relaxed. Log `_build/mr-reader-lifetime-red.log`
  is not claimed as the timing RED.
- Public BrokerRuntime mailbox timing RED:1/1 in101.9s,159excluded,
  `_build/mr-reader-lifetime-red2.log`. Preparation succeeded, then an11s native
  initialize after fresh owner evidence caused `mr_owner_admission_expired`.
- First public GREEN:1/0 in100.5s,159excluded,
  `_build/mr-reader-lifetime-green.log`. The first target reader initialize really
  waits at least10.9s before actual get_branch; target latest/queue/confirmation
  collection follows fresh owner evidence on the same PID, with no reinitialize
  or model command. The post-owner11s initialize trap remains active in the fixture.
- Public API ownership/deadline checks:2/0 in1.7s,82excluded,
  `_build/mr-reader-api2.log`. A first assertion expected `:timeout` instead of the
  existing `:response_timeout`; only the oracle changed. Covers foreign/tampered
  readers, same-actor read, dead-reader no-reopen, idempotent close,50ms remaining
  deadline, and preservation of unrelated messages. The deliberately interrupted
  shell reply can emit a synthetic broken-pipe diagnostic.
- Full affected AppServer file at the first green revision:84/0 in135.9s,
  `_build/mr-reader-app-server.log`; affected broker/known-result/authority set
  34/0 in17.5s, `_build/mr-reader-broker.log` (build-lock contention).
- Closure matrix initially exposed parse-rejected finalize retaining a reader,
  `_build/mr-reader-matrix-red.log`,1/1 in130.8s. Narrow cleanup closes only an
  identified warm-reader context, without changing the error or :recover path.
- Next matrix reached supervisor restart and exposed orphaned unlinked readers,
  `_build/mr-reader-matrix-green.log`,1/1 in187.7s. Linked-only warm ownership fixes
  that lifecycle; no new supervising actor or caller flag mutation was introduced.
- Expanded public matrix then passed1/0 in140.5s,160excluded,
  `_build/mr-reader-matrix-green2.log`. It independently changes latest turn and
  queue AFTER prepare while updatedAt stays unchanged; both deny. It checks
  malformed/wrong/missing-key finalize, workflow change, expiry, real TERM, actual
  idle-port data, supervisor stop, kill/restart, final physical mutation, and
  preparation branch failure. Real synthetic PID and Port closure are checked,
  and the complete protected ledger projection stays unchanged for every denial.

Final frozen-source results:

- `mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
  --only mr_owner_service`:3/0 in280.2s,158excluded,
  `_build/mr-reader-owner-final.log`. These exact three cases also exercise the
  preflight/projectless route, preserved concurrent-once/replay/restart behavior,
  all old owner negatives, the genuine slow positive, and the new lifetime matrix.
- `mix test test/symphony_elixir/app_server_test.exs`:84/0 in58.9s,
  `_build/mr-reader-app-server-final.log`, including legacy one-call native reads,
  existing owned-worker and fork/Controller compatibility, and both new API cases.
- `mix test test/symphony_elixir/factory_broker_runtime_test.exs
  test/symphony_elixir/factory_broker_result_publication_test.exs
  test/symphony_elixir/factory_ticket_mr_owner_admission_test.exs`:34/0 in6.6s,
  `_build/mr-reader-broker-final.log`.
- `mix specs.check`, `mix format --check-formatted`, `git diff --check`, and
  baseline private/TicketMrOperation/TicketMrPresendRecovery preservation passed.
  Logs `_build/mr-reader-specs-final.log` and `_build/mr-reader-format-final.log`.

No lint suppression or baseline cleanup was attempted. Consolidated lint deltas,
coverage, and Dialyzer remain the separately planned combined gate, not proven by
this checkpoint. No source acknowledgement is a deployment or ticket-delivery claim.

## Omitted positional key revision

Immediate base: `69c1925d98da2bb99d99b7c11e351ce7b5169101`.
Independent review found that deleting the positional ticket key left a known warm
reader and handle live, unlike replacing the key with an unknown value. The
protected ledger was unchanged, but a corrected replay could still succeed.

The maintained public regression deletes the actual argument with
`List.delete_at(finalize, 1)`. Before the fix it failed on the live reader Port:
1/1 in92.3s,161excluded, `_build/mr-reader-omitted-key-red.log`. The change accepts
only the exact two-positional finalize shape for cleanup, then reuses the existing
known-handle, warm-reader-only close/drop logic. It does not scan arbitrary
arguments, change parsing or authorization, or affect reader-free recovery
contexts. The test checks the actual reader PID/Port closes, admissions are empty,
the complete protected ledger stays unchanged, and corrected replay is denied.

Frozen revision gates, using the command prefix above:

- `mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
  --only mr_reader_omitted_key --only mr_reader_matrix`:2/0 in163.2s,160excluded,
  `_build/mr-reader-omitted-key-green.log`. This includes the prior full failure,
  freshness, restart, and physical-observation matrix.
- `mix test test/symphony_elixir/factory_broker_runtime_test.exs
  test/symphony_elixir/factory_broker_result_publication_test.exs
  test/symphony_elixir/factory_ticket_mr_owner_admission_test.exs`:34/0 in7.3s,
  `_build/mr-reader-omitted-key-broker.log`.
- `mix test test/symphony_elixir/app_server_test.exs --only native_reader`:2/0
  in2.3s,82excluded, `_build/mr-reader-omitted-key-api.log`. The deliberately
  interrupted synthetic shell reply emitted its expected broken-pipe diagnostic.
  AppServer source remains byte-identical to the preceding full84/0 checkpoint.
- `mix specs.check` and `mix format --check-formatted`: exit0,
  `_build/mr-reader-omitted-key-specs.log` and
  `_build/mr-reader-omitted-key-format.log`. `git diff --check` passed; baseline
  private/TicketMrOperation/TicketMrPresendRecovery diffs remain empty.

This is the second bounded parse-cleanup revision; a further unresolved instance
requires a narrowed plan rather than another unreviewed patch. Combined lint,
coverage, and Dialyzer remain unproven here. No live state was changed.
