# Plan014 Slice2 checkpoint

Base: `e21f9ea804e5aaa4c6b87de9863904ce4a40bbd4` (accepted Slice1).
This checkpoint implements only typed pre-session resume refusal. Slices3–4 remain
pending. No live factory/Grail/database operations, external push, deployment, or MR changes.

## Behavior

- `Codex.ResumeRefusal` classifies a small supported set of active-writer messages
  only when AppServer has the correlated `thread/resume` response and actual
  requested thread. A versioned JSON-safe map retains the full unchanged raw error.
- Factory `TaskLauncher.retryable_writer_conflict?/1` is typed-only. An explicitly
  named legacy helper preserves Controller and generic non-ticket waiting behavior.
  The existing explicitly enabled controller fork path is unchanged.
- WorkerEvidence records a scoped event for new typed or unclassified raw RPC
  failures. Request/task/run/input/binding/reservation generation, exact failure
  identity, and parsed-JSON refusal digest remain bound. The event is not authority
  by itself; every existing rearm predicate, zero-effect check, and cooldown remains.
- A new unclassified error cannot use old English matching, even if its text is
  identical. Historical records without the new event retain only the exact
  already-supported legacy check. No inspected failure text is parsed or evaluated.
- No helper/priv/schema/config/counter/repair-policy change. The typed observation
  is bounded at2MiB and does not increase existing transport limits.

## Evidence

Commands ran from `elixir/` with
`ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec --`:

- Primary RED: `mix test test/symphony_elixir/factory_resume_refusal_test.exs`,
 1test/1failure in0.7s: raw RPC tuple instead of typed correlated refusal.
 Log `_build/resume-refusal-red.log`.
- Minimal GREEN: same command,1/0 in0.7s (`resume-refusal-green.log`).
- Real subprocess/Store reopen/one-thread retry:4/0 in18.6s
 (`resume-refusal-roundtrip2.log`). An earlier test used a nonexistent direct
 evidence field for input SHA; corrected its oracle to the actual immutable binding,
 not production behavior. Earlier failing log retained.
- Expanded public matrix:10/0 in40.4s (`resume-refusal-matrix2.log`). Covers three
 supported wordings, opaque nested raw data, reopen, cooldown, no start/fork,
 other RPC methods, foreign response ID, port loss, unknown codes/messages,
 historical versus newly unclassified evidence, bound-session/file-effect denials,
 and event-identity mutations.
- Raw-error metadata mutation RED:1/1 in4.3s
 (`resume-refusal-identity-red.log`). Adding the parsed-JSON refusal digest closes
 that integrity gap; no retry limit or policy was relaxed.
- Final targeted regression plus both existing AppServer controller compatibility
 tests:3/0 in5.3s,89 excluded (`resume-refusal-legacy-final.log`). Exact selections:
 `factory_resume_refusal_test.exs:136`, `app_server_test.exs:1869`, and
 `app_server_test.exs:1978`. The first earlier location selection accidentally chose
 the same fork test twice; its11/0 log is retained as `resume-refusal-compatible.log`,
 not claimed as the active-controller test.
- Final `mix specs.check` and `mix format --check-formatted` passed
 (`resume-refusal-specs-final.log`, `resume-refusal-format-final.log`).

The earlier `resume-refusal-event-red.log` was a passing selection checking nil/empty
event containers; it is not claimed as RED. Scalar-container denial is included in
the final guard regression. Existing lifecycle fake refusal now returns the new
typed contract; only its matching result assertion and selection tag changed.

## Limits and next review

The full make/coverage/Dialyzer gate was not rerun for this intermediate slice.
The known pre-existing StageRunner prompt-substring failure remains untouched.
After sealing, rerun the full Slice1/Slice2/WorkerEvidence selection and the tagged
ordinary rejected-resume lifecycle against the immutable candidate. Review should
scrutinize scope binding, legacy separation, explicit controller compatibility,
event integrity, cooldown, and all no-session/no-effect predicates.

## Reviewed identity refinement (27 October 2026)

Revision base: `1aee2a1a29528ad55a28d60411d29956495460e9`.
This section supersedes the earlier claim that an event-local refusal digest
alone closes the integrity gap. Independent review found two remaining defects:

- An opaque array mutation beyond `inspect/1` limits, with its event-local digest
  recomputed, could retain the original inspected failure identity and rearm.
  RED: `_build/resume-refusal-independent-identity-red.log`,1/1 in4.0s.
- A new unclassified failure with the exact legacy English could rearm after its
  event payload became JSON null, because payload-key lookup treated it as absent.
  RED: `_build/resume-refusal-marker-red.log`,1/1 in2.8s.

The narrowed, independently design-reviewed contract now uses one shared
`ResumeRefusal.failure_identity/1` formatter. A validated typed refusal stores a
fixed `NATIVE_RESUME_REFUSAL_V1:` prefix plus SHA256 of its complete parsed JSON.
WorkerEvidence and both TaskLauncher persistence paths use that same identity;
rearming recomputes it from the event and compares it with both original current
failure fields. Untyped and historical failure identities remain exactly
`inspect(reason)`. The unchanged raw error remains in the scoped observation.

Marker discovery uses stable outer `events.run_id`, not mutable payload request
keys. Invalid JSON, null/scalar/list payloads, missing request keys, and foreign
request keys fail closed. The conservative compatibility boundary is deliberate:
only runs with no new marker can use the exact legacy path; a newer or ambiguously
scoped marker on the same run denies fallback. No new table or authority was added.

Discarded experiments remain in ignored logs: an after-raw-data digest still
failed (`resume-refusal-independent-identity-green.log`, despite its name), while
a sorted-key digest passed but was rejected as inspection-order coupling
(`resume-refusal-independent-identity-green2.log`). Neither is the sealed design.

Final frozen-source checks, with the same Elixir command prefix above:

- `mix test test/symphony_elixir/factory_completed_turn_recovery_test.exs
  test/symphony_elixir/factory_resume_refusal_test.exs
  test/symphony_elixir/factory_worker_evidence_test.exs`:42/0 in139.5s
  (11 Slice1,11 Slice2,20 WorkerEvidence).
  Log `_build/handoff-slices12-prefix-combined.log`.
- `mix test test/symphony_elixir/app_server_test.exs:1869
  test/symphony_elixir/app_server_test.exs:1978`:2/0 in1.8s,80 excluded.
  Log `_build/resume-refusal-prefix-controller.log`.
- `mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
  --only resume_refusal`:1/0 in70.5s,158 excluded.
  Log `_build/resume-refusal-prefix-lifecycle.log`. Existing compiler warnings
  reference excluded GenerationOriginRelease fixtures; no assertion failed.
- `mix specs.check`, `mix format --check-formatted`, and `git diff --check` passed.
  Logs `_build/resume-refusal-prefix-specs.log` and
  `_build/resume-refusal-prefix-format.log`.

The full quality gate remains unproven at this intermediate checkpoint. Slice1
tests prove native completion recovery and normal adoption to VERIFYING, not
physical publication. A separately identified publication validator requires
exit status zero; genuine recovered stop status7 remains unchanged and needs a
separate reviewed compatibility contract. No deployment or ticket progression
is claimed by these local checks. Slices3–4 remain unstarted.
