# U11 full quality gate PASS — October 9, 2026

Root command session 3175 is terminal, exit 0. The complete offline `make all`
passed build, formatting, public specs, strict lint, tests/coverage and Dialyzer.

- ExUnit: 1,540 tests, zero failures, six skipped; seed 885870, max_cases 16.
- Test duration: 3,416.8 seconds (179.6 asynchronous, 3,237.1 synchronous).
- Aggregate coverage: 98.67%, above user-approved 98.5%.
- Dialyzer: zero errors, skips and unnecessary skips; 5.11 seconds.
- All 463 frozen source entries matched before and after the run. The extracted
  frozen source independently matched the same manifest.

Candidate: `/private/tmp/symphony-u11-final-985.JxGXB8`.
Durable evidence:
`/Users/cgable/Repos/symphony-u11-review.ktOG3N/recovery-evidence/final-gate-985-JxGXB8`.

SHA-256:

- Source archive: `a1af0e499c17d65f5668dc6d22172325c5c35d90954ec52638a0e2a268b0e74e`.
- Full log: `79d20ceb2f7bae1fc00122ed783ad91afc47f3011e9823bacd2147f0fdf0f4f5`.
- Coverage HTML archive: `10f68ed85631b235493f4d7e9bfc8710592cca3d483ad29ebbb9c4344c249fab`.

All five tracker live-test opt-ins were zero and HEX_OFFLINE was one. Cached
dependency security advisories and support-file load-filter warnings were emitted;
they were not assessed or resolved. Locked dependencies were unchanged. Six
skipped tests are not live/native acceptance.

This supersedes the previous failed local gate, not the separate native acceptance
requirements. U11 integrated Desktop proof still requires its explicit model-turn
budget and real human/UI evidence. No native model calls, commits, pushes,
deployment, pilot enablement or real-ticket mutations occurred in this gate.
After-gate documentation updates do not change the tested runtime source.

## Independent evidence audit

`slice5_final_receipt_audit` returned PASS. It independently checked complete
raw-log progression, all 463 manifest entries against the frozen extraction and
source-archive payloads, durable-copy hashes, and the current Elixir runtime/test/
gate subset. The threshold-only difference from the prior gate is 99 to 98.5;
coverage exclusions are unchanged. Archive extras are macOS AppleDouble metadata,
not source differences. No concrete discrepancy was found.

Exit zero and environment opt-ins are direct root tool/run-status observations,
not text printed by `make`. `make all` does not independently establish a
warnings-as-errors compile flag. No native or deployment acceptance is implied.
