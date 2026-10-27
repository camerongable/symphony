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
exclusive same-directory temporary creation, file sync, and atomic rename.
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
backlog rotation. No internal persistence hook or collaborator mock was added.

Intermediate diagnostics are retained: matrix2 had an uppercase synthetic hex-ID
fixture error, corrected to the public lowercase mailbox grammar; matrix4 was
stopped after a descriptor time-zone mismatch was isolated with a standalone
File.Stat probe and fixed using universal timestamps. No production guard was
relaxed. Final counts above supersede those unsuccessful runs.

Full make/coverage/Dialyzer remain deferred to the consolidated plan gate. The
known baseline StageRunner751 failure remains untouched. Separately identified
physical stop-status/publication and cross-release compatibility work is not
implemented or qualified by this slice. No ticket delivery is claimed.
