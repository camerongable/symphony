# U7c parent followup guard increment

Status: implemented locally and independently ACCEPTED. Full U7c and
ordinary production acceptance remain incomplete. Production remains disabled.

## What changed

- Native `thread/queue/list` is read-only and bounded to one page of ten entries.
  A missing/malformed cursor is not an empty queue. A nonempty or partial page
  does not authorize a send. The raw page is transiently retained so the guard
  derives emptiness and recomputes its digest. SQL retains bounded facts/digests,
  not queue message text.
- Queue checks can request thread summary only (`include_turns: false`), avoiding
  repeated full-history reads on every presentation attempt. Native history still
  never proves owning-Desktop idle status.
- Parent FOLLOWUP claim requires a broker-attested `codex_app/read_thread` result
  naming the exact local Codex parent/cwd with idle or notLoaded status, plus the
  exact projectless native identity and proven-empty queue. Both observations must
  be no more than ten seconds old and cannot be future dated.
- `ticket_parent_claims` records request/payload/generation, broker identity,
  owning-tool observation digest/time, queue digest/time, guard time and claim time
  in the same SQLite transaction as the uncertain claim. A second claim cannot
  resend, and rollback readback does not require obtaining a new idle observation.
- `TicketChat.claim_followup` collects the queue itself before the transactional
  claim; `claim-ticket-followup` exposes this existing request operation in the CLI.
  Ordinary `claim` cannot bypass the required parent FOLLOWUP proof. Legacy and
  CREATE behavior are unchanged.

## Verification to date

- Focused protocol/parent/CLI/migration/outbox regression: 52 tests, zero failures,
  68 unrelated protocol cases excluded; seed 328925, 3.3 seconds.
- Real read-only native queue read on existing disposable parent
  `01a0fdb3-7ca5-7150-872e-c77e62dd87b0` returned the expected projectless cwd and
  empty complete queue at `2026-10-05T19:01:09.543267Z`; digest
  `4b354292101b152063e0a3d6a598c46f71284f9bfa1daf9cd9257c1fd23069f6`.
  No model turn, creation, resume, message, source action or service change occurred.
  Summary-only live readback also passed at `2026-10-05T19:04:31.766402Z`, with the
  same exact parent/cwd/project and queue digest. Native response retained a turns
  field despite requesting includeTurns=false; no absent-field claim is made.
- Final repaired regression: 52 tests, zero failures, seed 74576, 7.1 seconds.
  Independent guard/protocol rerun: six tests, zero failures, seed 686895, 2.2 seconds.
  Reviewer ACCEPTED after the raw-response/digest repair.
- Whole strict lint and public specs check passed after final refactoring.
- Whole-repository coverage hold from U7b remains. Focused tests are not full-gate
  acceptance, native ownership proof, or route enablement.

## Deliberate boundaries

The owner observation is explicitly broker-attested tool evidence, not independent
cryptographic ownership proof. Persisted/cold AppServer status is never used in
its place. A human may start a turn after the observations; the once-only claim
remains uncertain until exact completed delegation readback. This does not claim
an atomic native idle lease, or automatically resend on a race. Final combined
acceptance must exercise that race and native queue preservation.

Known-broker routing, canonical skill integration, scheduler parent admission,
combined native acceptance and final coverage/quality gates remain pending. No
automatic worker launch, delivery state mutation, production permission or changed
global configuration follows from this increment.
