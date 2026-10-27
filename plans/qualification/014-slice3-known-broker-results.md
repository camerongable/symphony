# Plan014 Slice3 checkpoint

Base: `21b05d879fb7d8171fcfb738750e7ee89b280438` (accepted Slice2).
Only the broker's result publication/recovery owner changes. Slice4 is unstarted.
No live factory/Grail/SQL, broker schedule, model, policy, push, MR, or deployment
operation was performed. All historical private helper bytes remain unchanged.

## Preserved result contract

One versioned immutable `.known` envelope binds the mailbox ID, canonical database
root, original request-byte digest, and exact serialized response-byte digest.
Response bytes are base64 encoded, not reparsed/reserialized during recovery.
The broker stores that envelope before publishing `.response`, using restrictive
exclusive same-directory temporary creation, file sync, and exclusive hard-link
commit followed by temporary unlink (the independently reviewed revision below).
Process restart is covered; host power-loss durability is explicitly not claimed
because the existing running/response/finished lifecycle lacks directory sync.

Successful operation results remain bounded in the existing owner's memory if
their disk commit is obstructed. Polling retries only publication/bookkeeping,
never execution. Known records also fence duplicate pending IDs. A crash before
known-result commit remains uncertain, and partial temporaries do not prove a
result. Restart never restores in-memory owner-admission handles. Publication of
an expired request's known bytes is historical output, not renewed authority.

The encoded response limit remains2MiB, including JSON escaping. The base64
envelope limit is2,800,000bytes. At most16 unpublished in-memory envelopes are
retained;16 unresolved running mailboxes stop new execution. Startup processes at
most16, then each250ms poll retries at most one, rotating past denied records.
Directory enumeration retains the existing O(mailbox-name-count) cost; no history
cleanup or new generic journal was introduced.

Files must be regular, single-linked, and owned by the mailbox owner. Known files
must be owner-private. The bounded reader checks opened descriptor identity before
reading at most limit+1 bytes and rechecks the path afterward. Foreign-UID mutation
is enforced in source but not separately exercised with elevated ownership changes.
Linked/nonregular/conflicting responses now fail closed and remain untouched;
the previous test expecting replacement of a symlink was intentionally updated.
The public caller also compares exact response bytes with the saved known result.
Request readback tolerates the running-to-finished rename only by validating the
same original request bytes in the new location.

## Red/green evidence

All commands ran from `elixir/` with
`ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec --`.

- Primary RED: external Python executor records its effect, then creates an actual
  `.response` directory. Removing it and polling left the result stranded:1/1 in0.1s,
  `_build/broker-result-red2.log`. The earlier red.log obstructed before execution
  and hit the existing duplicate fence; it is not claimed as behavioral RED.
- First GREEN: same real filesystem obstruction/removal publishes original bytes
  and finishes bookkeeping with one execution:1/0 in0.1s,
  `_build/broker-result-green.log`.
- Public caller RED: a disagreeing response was returned as success:1/1 in0.6s,
  `_build/broker-result-caller-red.log`. Exact known-byte validation now denies it.
- Existing owner lifecycle exposed a genuine readback race while `.running` moved
  to `.finished`:1/1 in117.7s, `_build/broker-result-owner-lifecycle.log`.
  A deterministic real external rename regression also failed1/1 in0.3s,
  `_build/broker-result-finished-race-red.log`; exact request-byte fallback fixes it.
- Final focused command:
  `mix test test/symphony_elixir/factory_broker_result_publication_test.exs
  test/symphony_elixir/factory_broker_runtime_test.exs
  test/symphony_elixir/factory_ticket_mr_owner_admission_test.exs`
  passed26/0 in2.3s (13new,12existing broker,1owner authority).
  Log `_build/broker-result-matrix6.log`.
- Existing composed owner command:
  `mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
  --only mr_owner_service` passed1/0 in170.5s,158excluded.
  Log `_build/broker-result-owner-lifecycle2.log`. This includes actual preparation,
  restart/lost handle denial, and controller command execution; existing warnings
  concern excluded GenerationOriginRelease fixture functions.
- `mix specs.check`, `mix format --check-formatted`, and `git diff --check` passed.
  Logs `_build/broker-result-specs-final.log` and
  `_build/broker-result-format-final.log`.

The public matrix covers restart before/after known commit, response-present
bookkeeping failure, conflicts, duplicate pending IDs, invalid version/digest/ID/
root/shape/size, malformed JSON, links/private permissions, changed request bytes,
escaped oversized/unserializable output, expired historical output, and bounded
backlog rotation. This initial checkpoint used no internal persistence hook or
collaborator mock; the separately approved revision adds the single edge below.

Intermediate diagnostics are retained: matrix2 had an uppercase synthetic hex-ID
fixture error, corrected to the public lowercase mailbox grammar; matrix4 was
stopped after a descriptor time-zone mismatch was isolated with a standalone
File.Stat probe and fixed using universal timestamps. No production guard was
relaxed. Final counts above supersede those unsuccessful runs.

Full make/coverage/Dialyzer remain deferred to the consolidated plan gate. The
known baseline StageRunner751 failure remains untouched. Separately identified
physical stop-status/publication and cross-release compatibility work is not
implemented or qualified by this slice. No ticket delivery is claimed.

## Independent-review revision: exclusive publication

Revision base: `3fe3497cbd8857a53dd4bb7107e851c59d8ad6c9`.
The earlier absence check plus replace-capable rename was not atomic exclusion.
Independent review's real Python contender installed a disagreeing final response
after `.response.writing.*` appeared, and the broker overwrote it. The revision
replaces final publication with `File.ln(temporary, final)`, which atomically refuses
an existing destination; successful final link is the complete synced-byte commit
point. Temporary unlink follows. Pending publication uses the same primitive, and
an already-unlinked temporary is successful idempotent completion, not failure.

The public reader never accepts a two-link record: it waits. The broker owner may
unlink only one uniquely named `final.writing.[0-9a-f]{16}` temporary when final
and temporary are regular, private, exactly two-linked files with the same inode,
owner, mode, size, and stable metadata. It validates bounded complete record bytes
against the request/known response and rechecks both paths before unlink. Unknown,
foreign, symlinked, malformed, or multiply aliased files remain denied and are not
removed. No additional outcome journal or authorization capability was added.

One optional internal `start_link` test callback, `after_known_link`, exists only
at the synced exclusive-known-link edge. It has no config, CLI, environment, or
serialized route. A filesystem-only watcher can select an overwrite contender but
cannot reliably stop an Erlang process in the link-to-unlink interval. The bounded
callback lets the real mailbox test kill that process at the precise edge, reopen
without the callback, recover exact bytes, and prove one external effect. This is
the sole persistence-edge hook; ordinary tests use actual filesystem barriers.

The expiry test now waits relative to the stored expiry, if still in the future,
and proves expiration before recovery. It no longer assumes the external operation
must complete inside200ms.

- Public competing-writer plus transient-link RED:2/2 in1.4s,
  `_build/broker-result-exclusive-red.log`. Both known and response destinations
  are exercised by the final matrix; conflicting original bytes remain unchanged.
- Revised matrix:32/0 in4.4s, `_build/broker-result-exclusive-final.log`.
  It includes all26 earlier checks, both external contender phases, transient
  public readback, actual crash after exclusive link/reopen, exact residual
  bookkeeping, pending-link settlement, and foreign/multiple/invalid/symlink
  no-unlink negatives.
- Exact independent critic reproduction rerun against the revised source:1/0
  in0.6s, `_build/broker-result-critic-race-green.log`. The external review script
  was read and executed without modifying its checkout or evidence.

- Existing owner lifecycle frozen-source rerun:1/0 in175.3s,158excluded,
  `_build/broker-result-exclusive-owner.log`.
- Final `mix specs.check`, `mix format --check-formatted`, `git diff --check`, and
  private-helper preservation check passed. Logs
  `_build/broker-result-exclusive-specs.log` and
  `_build/broker-result-exclusive-format.log`.

Process-restart-only durability, inherited directory enumeration cost,
foreign-UID test limitation, unchanged private bytes, and deferred consolidated
full quality gate remain as above. Slice4 remains unstarted.
