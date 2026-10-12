# U8b normal scheduler amendment consumer

Status: accepted locally after focused tests, scoped static checks and frozen
protocol re-review of the repaired source. This is not Slice 4 acceptance or rollout proof.

## Required behavior and observed checks

The normal scheduler consumes the existing durable amendment phases, including
READY commands and explicitly corrected non-PASS proposals. It preserves the
run/candidate/checkout and stored writer allocation. Critic and external calls
remain outside database transactions; uncertainty reads back the same operation.

Worker-reported terminal focused cases after the final refactor:

- `factory_desktop_ticket_chat_lifecycle_test.exs:43`, seed 442063: 1 test,
  0 failures, 52.7 seconds. READY proposal draft becomes UNCERTAIN without a
  critic; stop/reopen the same database, reconcile the same draft, record one
  BLOCK, then duplicate polling adds no Jira write or critic invocation. An
  explicit corrected proposal applies; the next tick starts fresh verification.
- The same file `:160`, seed 369176: 1/0, 39.8 seconds. A real CONTINUE slice
  establishes a candidate before the later BLOCKED writer. Amendment application
  retains the exact active SOURCE access row, checkout and candidate; the next
  idle tick does not resume source or repeat critique.
- The same file `:233`, seed 262885: 1/0, 10.7 seconds. Diagnostic limitation
  case: first-writer BLOCKED has no candidate; polling must not invent one.
  This does NOT prove candidate-less recovery. That correction is required before
  whole-Slice-4 acceptance and is specified in `../006-U8b-contract-adapter-prep.md`.

Final scoped gates reported PASS: `mix compile --warnings-as-errors`,
`mix specs.check`, format check of the four files, strict Credo diff against HEAD
limited to those files (zero issues), and scoped `git diff --check`. Commands
were run through `mise exec`. No full suite or live native/Jira/GitLab effects
were used for these cases.

## Freeze

HEAD remains `52a978818875c59ccf2758ed1b728bb23e33f631`; dirty/untracked work was
preserved and no commit was made. Root independently read back these SHA-256s:

| File under `elixir/` | SHA-256 |
| --- | --- |
| `lib/symphony_elixir/factory/scheduler.ex` | `3f9ea0da1b59d50d818c317fd55950dfbf97c392a1de0b167a2d528d8a589033` |
| `lib/symphony_elixir/factory/ticket_worker_runner.ex` | `2cc029bcc942f0a996cea20e8090775e404dd7bd9cf56b43abf0e9cf288b3652` |
| `test/support/desktop_ticket_lifecycle_fixture.ex` | `b2ee002a7f835f2390b446794e64d84f2c6f9715d0ffab565b22449b273e7189` |
| `test/symphony_elixir/factory_desktop_ticket_chat_lifecycle_test.exs` | `81664e13521156d3f0056bac4aea52c098e20fe1dd610bd32cc46f5c11b191bf` |

## Acceptance boundary

Repair-stage focused result: worker-reported handle 35011, seed 432401,
`factory_desktop_ticket_chat_lifecycle_test.exs:43`, 1 test, 0 failures,
53.8 seconds. A corrected PASS survives uncertain authorization and Store
stop/reopen; one authorization write and two total critics (initial BLOCK plus
corrected PASS, no replay invocation) are observed, with retained candidate and
checkout and next-tick verification. Separate pre-authorization restart proof,
final scoped statics and replacement freeze are still being collected. The hash
table above describes the first review, not the in-progress repaired source.

The distinct pre-authorization boundary now passed in the same selected case:
seed 811825, 1/0, 53.3 seconds. Existing public APIs persist a RESULT_RECORDED
PASS with zero authorization-effect rows; Store stops/reopens before any
authorization call. Normal ticks then perform one authorization write, recover
UNCERTAIN readback across a second reopen, and apply without another critic or
authorization call. No production hook or new harness was introduced. Final
statics/replacement freeze and independent re-review remain pending.

Replacement freeze: final scoped compile/spec/format/strict-Credo/diff checks
reported PASS. Root independently read these repaired SHA-256s before requesting
protocol re-review; HEAD and the worker-runner hash remain unchanged:

- Scheduler: `efe69b1a731790537b4641662a7a990cc8d855bed1653470b76f739084f85114`.
- Lifecycle fixture: `f108308e5d01e175533f60697b65a2bc4e17f44d39ae8edc263c59eba831f325`.
- Lifecycle test: `ebbadf58f1e6d29fa0777d670f2873ebf68875dad3926afea07475c4c1667b9c`.

The source writer is complete and source remains frozen for that re-review.

Protocol re-review returned bounded PASS on the replacement hashes. It traced
validated existing-attempt reuse, missing-only preparation, stored-result replay,
fail-closed INVOKING/RECONCILE_REQUIRED, and both restart barriers. Root read back
the same repaired hashes before that verdict. Review performed no tests/builds or
external effects; the selected test runs remain worker-reported terminal evidence.
No concrete remaining defect was found within the repaired scheduler packet.

Frozen safety review returned bounded PASS with all four hashes unchanged.
Protocol review found a concrete blocker: the scheduler unconditionally calls
`prepare_critic`, which accepts absent/PREPARED attempts but rejects an already
RESULT_RECORDED critic. A stored PASS cannot therefore resume interrupted
authorization/application. The existing uncertain-draft and non-PASS tests did
not cover this post-PASS boundary. Repair normal phase advancement without
loosening critic identity/provenance, and prove stored PASS plus uncertain
authorization survives reopen with exactly one critic and authorization write.
Also prove restart immediately after PASS and before authorization. Re-run only
affected focused cases/static checks, then refreeze and obtain protocol re-review.

Independent review must confirm normal READY selection, explicit correction
selection, stable non-PASS presentation, held ownership, no initial writer restart,
and exact readback/replay. Fresh verifier dispatch may accept the review Jira
label only in its authorized verifier route; ordinary WRITING admission must not
gain that authority. Existing direct answer/rework paths remain unchanged.

Remaining after this packet: candidate-less first-writer amendment/resume,
atomic mixed commands, U9 ordinary/native acceptance, then Slice 5 U10/U11.
Production remains disabled/unproven; no commit, push or deployment is claimed.
