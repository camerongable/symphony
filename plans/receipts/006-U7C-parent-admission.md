# U7c existing-run parent admission

Status: implemented locally and independently ACCEPTED. Production is
still disabled. This is not full U7c, Slice 3 or native runtime acceptance.

## Scope

`Scheduler.ticket_parent_step/3` uses the existing ticket-stage lock and delegates
identity/reservation to TicketChat. For an eligible ordinary V1 run and explicitly
allowlisted policy, it requires a caller-bound canonical existing projectless
output root and broker UUID. It resolves the configured `orchestrator-intake`
model separately from writers, reserves/reuses the deterministic projectless
CREATE, and returns PARENT_PENDING or PARENT_READY with the stored request status.

It does not call native tools, launch a source worker, allocate a checkout, update
the run, restart specification, or select V1 work in production ticks. Existing
register_delivery, active-run selection and startup Policy fences are unchanged.
Caller options are controller inputs for this disabled component, not proof of
the actual native host mapping. That proof remains the requested bounded native
test's purpose.

An optional `broker_thread_id` is stored immutably with new parent identities and
included in their CREATE/FOLLOWUP payload metadata. Argument generation validates
the optional field; native provenance and followup guards reject a different
broker. Historical rows stay NULL and their old payloads are unchanged. Admission
does not fill missing historical binding or retarget a parent to a different root.

## Verification

- Nine focused parent, argument-builder, migration and CLI suites: 59 tests,
  zero failures, seed 190607, 5.3 seconds.
- Concurrent duplicate calls and store reopen retain exactly one CREATE.
- Creation uncertainty does not produce a replacement; exact typed observed
  bootstrap/ACK becomes ready. New presentations retain the immutable broker.
- Missing/relative/absent root, missing/malformed broker, disabled/disallowed
  policy and an ineligible manual-validation flag reject before reservation.
- Run/candidate fields and source tasks/evidence/reservations remain unchanged.
- Whole strict lint, formatting, public specs and whitespace checks pass.
- Independent admission/guard/provenance rerun: 18 tests, zero failures,
  seed 422461, 1.7 seconds. Frozen component review ACCEPTED; no source edits or
  native/remote calls by the reviewer. Full coverage hold remains unchanged.

## Remaining integration

Prove the current supported projectless directory mapping and real broker/native
envelopes before turning caller inputs into production configuration. Wire the
canonical broker and actual source-checkout admission before opening scheduler
intake. Preserve one source checkout, existing capacity gates and independent
verification. Combined lifecycle/native acceptance and the unchanged full quality
gate are still required; no production enablement is claimed here.
