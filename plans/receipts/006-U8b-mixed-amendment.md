# Atomic answers plus contract amendment

Status: ACCEPTED locally after the bounded repair and two independent re-reviews.
This does not accept the full Slice 4 lifecycle or runtime rollout. Initial freeze is in
`006-U8b-mixed-amendment.sha256`; every file matched before/after both reviews.

## Executed focused evidence

- Author final command selection: seed 39854, 4 tests, 0 failures, 40 excluded,
  exit 0; log `/private/tmp/symphony-u8b-answer-amendment-red/command-tests.log`.
- Author final amendment selection: seed 39855, 3 tests, 0 failures, 31 excluded,
  exit 0; log `/private/tmp/symphony-u8b-answer-amendment-red/amendment-tests.log`.
- Root independently ran the exact named mixed authorized-application case on
  the frozen candidate: session 46336, seed 39856, 1 test, 0 failures,
  33 excluded, exit 0. This existing positive case does not prove the gaps below.
- Author reports compile warnings-as-errors, specs, scoped format, strict Credo
  and diff check passed; Credo still inspected 237 files despite repeated filters.

## Finite repair findings

Protocol review found whole-body indentation/control guards run before splitting
the mixed contract command. Valid literal indented Markdown is rejected. Apply
authorization guards only to the answer prefix for this explicit mixed format;
preserve the Markdown suffix byte-for-byte and legacy singleton behavior.

Both independent reviews require discriminating mixed scenarios using existing
fixtures: 1–3 answers and malformed/duplicate/excess/order/delimiter rejection;
literal indented/fenced Markdown and exact newlines; selected answers remain OPEN
through non-PASS and uncertain Jira authorization; final selected-question or
chat/run-binding drift rejection; full protected-row rollback and preservation
of candidate, checkout, iterations, tasks, access and evidence on success.
Retain reopen/progression replay and test immutable native/payload/answer/proof
tampering. These are requirements of this unit, not new product scope or a new
harness. Legacy singleton cases remain intact.

Source remains frozen until the sole writer receives this bounded repair. Root
retains the actual five-file buggy bytes before repair for exact regression
discrimination; a transient parser compiler-error snapshot is not product RED
evidence. No commit, push, live effects or native acceptance was performed.

## Repair checkpoint (not accepted)

The sole writer reproduced the exact indentation defect before repair: seed
60001, exit 2, one selected test/one failure with
`quoted_code_not_authorization`. Mixed authorization guards now inspect only the
answer prefix; legacy singleton guards remain unchanged. The bounded grammar
selection passed: seed 60004, three tests/zero failures, 43 excluded, exit 0;
log `/private/tmp/symphony-u8b-answer-amendment-red/grammar-tests.log`.
It covers one/two/three answers, literal fenced/indented suffix bytes and extra
literal delimiter, plus malformed/order/duplicate/excess/extra-rework rejection.
Remaining repair evidence: mixed non-PASS/uncertainty, final binding/question
drift, full protected-row rollback/preservation and historical-proof tampering.
No freeze or independent re-review acceptance is implied by this checkpoint.

## Repaired acceptance

The five-file repaired freeze is `006-U8b-mixed-amendment-repaired.sha256`.
Root and both independent reviewers verified all five hashes before/after.
Protocol and integration/test-quality reviews both returned bounded PASS for
the finite original findings; singleton behavior remains intact.

- Final author grammar selection: seed 60009, 6/0, 40 excluded, exit 0;
  `final-grammar-tests.log` in the artifact directory above.
- Final author amendment selection: seed 60010, 5/0, 31 excluded, exit 0;
  `final-amendment-tests.log` in that directory.
- Root independent repaired grammar plus mixed application selection: session
  22927, seed 60011, 2/0, 80 excluded, exit 0. Exact selected names were
  `answer followed by exact contract delimiter preserves literal indented markdown bytes`
  and `mixed authorized amendment closes selected answer atomically`.
- Final static log SHA256:
  `20f4d09f2d2b511edffa1e4be64c502ed231b246dc9fb540d4b601c519209d0e`.
  Compile warnings-as-errors, specs, format, strict Credo and diff check passed.
  Credo inspected 237 files despite path filters; no findings.

RED seed 60001 is tool-attested, not a persisted raw logfile. Exact buggy bytes
remain at `/private/tmp/symphony-mixed-amendment-buggy.odwet0`.
Protected checkout assertions prove ledger invariants, not filesystem bytes or
native/live integration. U9 owns complete intake/lifecycle and source identity
integration proof. No full suite, commit, push, deployment or native turn was run.
