# U8b atomic answers plus explicit rework

Status: atomic answers-plus-rework unit accepted locally. No whole-Slice-4/U9
acceptance or rollout is claimed.

## Final local acceptance

Final seven-file manifest: `006-U8b-mixed-rework-final.sha256`. Root and both
reviewers matched all hashes; only Commands and lifecycle test changed in the
lint repair. Both finite re-reviews returned PASS: extracted staging/schema
predicates preserve guards, snapshot map preserves every prior assertion,
mixed historical authority/tamper fences and old singleton compatibility remain.
Author final named critical regressions seed 639785 passed exit 0, 2/0,
22.0 seconds; compile warnings/specs/format/diff and corrected repeated-path
Credo passed without findings. Credo reports inspecting 237 files even with
path filters; do not claim exactly seven physical files were analyzed.

Independent repaired GREEN and exact saved-source RED/fix/GREEN evidence is
recorded below. Style-only final changes were reviewed for equivalence and
rerun against affected regressions. No broad suite, live action, staged changes
or delivery mutation occurred. Proceed to answers-plus-contract unit, not U9
or full Slice-4 acceptance yet.

## Repaired review and independent runtime checkpoint

Repaired seven-file freeze `006-U8b-mixed-rework-repaired.sha256` matched root
and both re-reviewers before/after. Protocol and integration returned bounded
PASS on authority, legacy singleton, mixed restart/tamper, normal-poll rejection
and atomic rollback. Source writer completed/stopped. Author lifecycle seed
103793 passed 5/0, 31.3 seconds, exit 0; command preflight seed 295305 passed
1/0, 0.7 seconds, exit 0; warnings-as-errors compile/specs/format/diff passed.

Root fixed candidate session 99360 seed 102644 passed the exact named mixed
tamper/restart and legacy singleton regressions: exit 0, 2/0, 59 excluded,
21.0 seconds. In disposable copy
`/private/tmp/symphony-mixed-rework-exact-red.wAcNMt/elixir`, new test bytes on
exact saved buggy production core failed both intended assertions (session
30426, seed 461347, exit 2, 2 failures, 59 excluded, 14.5 seconds): legacy
singleton refused, tampered mixed proof unexpectedly launched. Applying ONLY
the actual Commands source delta through apply_patch made all repaired hashes
match and restored GREEN (session 27623, seed 907663, exit 0, 2/0,
59 excluded, 21.7 seconds). Saved original candidate remains untouched.

Acceptance is still pending lint repair: root Credo session 36347 exited 12
with five new long test lines, test-helper arity 12, two complex Commands helpers
and nested staging helper. The comma-separated include filter unexpectedly
inspected 237 files; do not claim that run was seven-file scoped. Findings are
all in this changed packet. Re-run with repeated --files-included flags.
No suppressions, broad refactor or extra full suite is authorized.

Separately, older recovery-fault discrimination completed four labeled
RECONSTRUCTED BEHAVIOR variants, each baseline GREEN / specific runtime RED /
exact restored GREEN, seed 647280. Full artifact
`/private/tmp/symphony-recovery-discrimination.cOaQk4/RESULTS.md` SHA256
`bbf48a0142422bc03a97fa1e8eafcb3d6353972b35f93436843d50069f1b3e4f`
was read and independently hashed by root. These are not historical exact-byte
replay; propagation variant proves missing HEAD detection only, not former
fallback reproduction. No main/saved candidate source was changed.

## Frozen identity and evidence

Seven-file manifest: `006-U8b-mixed-rework.sha256`, independently matched by root
and both reviewers before/after inspection. Source writer stopped for review.
Author reported three focused worker cases (3/0, 25.8 seconds), one command
preflight case (1/0, 0.6 seconds), specs, scoped format and diff PASS. Exact initial
seeds/handles were not supplied; these are author reports, not independent runtime
acceptance. The main worktree remains inherited dirty/untracked and unstaged.

Root retained an exact independent copy of this candidate at
`/private/tmp/symphony-mixed-rework-red.1Iw0Gf/elixir`, verifying all seven hashes.
Keep it unchanged for later regression RED against new tests; never edit the
live candidate to manufacture RED. No real ticket/service/native action ran.

Root verified that this isolated copy can execute the existing selected mixed
success case: session 74758, seed 647280, exit 0, 1 test, 0 failures,
57 excluded, 14.9 seconds. Trace selected the intended named case. This is a
baseline viability check, not prepared-replay regression acceptance; new fixed
tests will be used for RED against the retained buggy production code.

## Frozen review: protocol authority

Reviewer `mixed_rework_protocol_review` returned REPAIR:

1. `TicketChatCommands.validate_rework_replay/2` (frozen lines 326-345) loads input
   by key but does not validate native body, staging, admission or original
   binding. Proof covers only input key and question digests; per-operation
   question_digest is not compared against the recomputed answered row. Changing
   input.body alone, or changing operation digest and recomputing payload_sha256,
   can still validate. TaskLauncher uses this path before a RESERVED start.
2. Prepared mixed replay is untested: frozen lifecycle case 1501 is singleton.
   Add mixed reopen success once and exact tamper rejection for input body,
   payload digest, answer value and question proof, with zero launch/effects.

Initial ordering/outer transaction are sound on inspection: all-answer preflight
precedes SOURCE transfer; answer CAS and terminal receipt share TaskLauncher’s
transaction. Initial digest stripping is paired with full payload recomputation.
The defect is prepared replay. Repair historical linkage without requiring OPEN
questions/current live binding and without answering/transferring again.

## Frozen review: integration and discrimination

Reviewer `mixed_rework_integration_review` returned incomplete acceptance:

- Normal-poll mixed success and SQL-abort rollback are real mixed cases; the
  fixture uses restricted file tools, not fake Git commits/state normalization.
- Stale second-answer test (command case 511) is preflight-only and does not
  prove zero TaskLauncher/source effects. Capacity/generation (lifecycle 1446),
  candidate drift (1424), and prepared reopen (1501) remain singleton-only.
  Extend shared fixtures with mixed variants and explicit owner/HEAD rejection.
- Rollback snapshots must include all successor access rows, run/slice changes,
  question/task/evidence rows and checkout/index bytes, not merely predecessor
  access and evidence count.
- Legacy compatibility: replay unconditionally requires answered_question_keys
  and answer_proof_sha256, which old singleton receipts lack. Permit only the
  exact legacy singleton shape under original authority; mixed commands missing
  proof must never fall through. New-format singleton replay is not old-receipt
  compatibility evidence.

Use the existing fixtures/parameterized cases, not a new harness or broad suite.
Preserve standalone/answer-only and nil/HEAD/original-binding behavior. No model,
native or other external effects occur during these local proofs.

## Next checkpoint

Sole Luna writer resumed these finite repairs after capacity PASS at 32.91 GB
against the unchanged 20 GB gate. Return exact named test traces/seeds/counts/
exits and scoped statics, freeze, then re-review. Record selectors for RED on the
retained exact buggy source and GREEN on fixed source. No later unit until this
unit is accepted.
