# U7 MR CLI and CI joins

Implemented locally:

- Exact missing-request preparation from the normal serialized MR tick and typed
  discovery under a supplied validated policy. Repeated ticks retain the same key;
  generic/legacy controller issuance stays separate.
- `claim-ticket-mr` direct Jira authority, plus the preferred interactive route:
  Jira first, bounded raw Desktop owner input, native latest/queue confirmation,
  atomic uncertainty, compact send arguments. No reusable authorization token.
- CI WAIT/BLOCK retain CI_WAITING. Exact PASS enters VERIFYING and increments its
  round once; current run/request/claim/physical checkout/push facts are rechecked.
- Post-CI blind verifier packets contain exact positive-pipeline candidate-bound
  PASS evidence; V1 verifier PASS goes through normal push proof rollover.
- MR adoption CAS-advances the original controller turn only when that exact prior
  turn is still current. Later controller turns are preserved.

Evidence:

- MR request/discovery regressions: 17 tests, no failures, seed 294145.
- CLI policy/fresh claim/restart regressions: 8 tests, no failures, seed 537508.
- Handshake: 4 tests, no failures, seed 719866, including a real local child process
  proving readiness before stdin, positive handoff and timeout/clean exit. No Codex
  model or live connector was used. CaptureIO exposed an OTP/StringIO binary-read
  mismatch; bounded Unicode IO.read preserves the protocol without unbounded reads.
- CI collector/MR regressions: 18 tests, no failures, seed 708939.
- Full preflight continuation test: 1 test, no failures, seed 279256, exercising
  WAIT, BLOCK, corrupt claim during reads, PASS via scheduler, packet evidence,
  duplicate-round denial, fresh verifier and exact same-candidate push rollover.
- Independent read-only reviews accepted CLI/discovery, bounded handshake, CI
  adoption, packet binding and original-turn CAS. Live timing remains unverified.
- Final grouped MR/CI/CLI/handshake regression: 29 tests, no failures, seed 66271.
  Final specs check, strict Credo and whitespace checks passed. The repository's
  full quality gate has not been rerun and is not claimed by these focused checks.

No production send, paid native/model test, real Jira/GitLab mutation, deployment,
source commit/push or cleanup occurred. Broker skill installation, Jira review-ready
join, combined lifecycle/native acceptance and the final quality gate remain.

Jira integration preparation found no durable mutation journal in the current
writer. Its repeated-call protection does not prove restart safety while a posted
comment is hidden. The next unit must persist uncertainty before each effect and
recover with complete readback, never treating an absent uncertain comment as
permission to repost. Reuse the strict reader's bounded completeness checks, not
the writer's weaker comment-count guard. The entry-side In Dev transition must
also be audited against the user's existing workflow requirement before combined
acceptance; a fixture reader returning In Dev is not proof of that transition.
