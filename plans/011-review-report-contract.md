# Plan 011: Make factory review reports robust and repair reviews convergent

## Status and authority

- Local implementation candidate: typed v2 admission, scoped closure/provenance,
  deterministic once-only v1 correction, versioned physical publication codecs,
  and exact operator policy-stop continuation are implemented. The composed
  correction-at-two-used -> consumed REPAIR policy stop -> public operator
  authorization -> owned-tick continuation/restart -> writer adoption -> physical
  v21 ordinary-publication proof -> another honest REPAIR stop test passes.
  Independent final review, final quality-gate disposition, local integration,
  deployment, and live ticket recovery remain parent-owned gates; this status
  does not claim PPL-9881 is PASS or human-review-ready.
- The actual legacy-counter regression now proves ordinary SOURCE admission at
  implementation 26/configured 25 and combined repair 12/configured 10, with an
  exact versioned operator allowance for next 27/13. COMPLETE publication and
  honest CONTINUE-to-cap denial both pass, including reopened result adoption
  and exact counter-binding negatives. No new journal or result schema is added.
- Priority: P0; effort: L; risk: MED–HIGH.
- User authorized implementation, local integration/merge, deployment, and intervention to get PPL-9881 moving; do not publish a GitHub PR or push externally.
- Dependencies: the deployed R20 baseline, not the dirty development checkout.
- Planned at: development ancestry `d4d2559b497a92c1f21382559419bf6db55ba029`, 2026-10-26. This ancestry alone does NOT identify deployed source.
- Authoritative baseline: `/Users/cgable/Library/Application Support/ai-factory/source-snapshots/symphony-ci-pass-overlay-cnRVdUfY-r20`.
- Baseline manifest: `/Users/cgable/Library/Application Support/ai-factory/releases/symphony-ci-pass-overlay-cnRVdUfY-r20/evidence/overlay-manifest.json`, SHA256 `cb6e49358a07192ed847893990a327f450f4d6c2c6a6955d8f89cbf777810801`.
- Installed module fingerprint: `279f7ab2d9ed171d682efb94bd357a18941dd98b784f58ccc3ea62e9d9400d5b`, 119 modules, SQLite schema 54.
- This is workstream 1 only. Scheduler ownership/intake isolation and transport/MR timing fixes are workstreams 2/3 and must wait until PPL-9881 actually advances.

## Why

Deployment is held for the actual legacy-counter gap: PPL-9881 is at implementation
iteration 26 with configured maximum 25, and combined repair round 12 with maximum
10. The previously tested operator continuation did not grant SOURCE admission
past the implementation cap. Add a new explicit policy-stop authorization version
binding configured/current/next counters 25/26/27 and 10/12/13, automatic repairs
used 2, and exactly one implementation iteration. Keep configured limits and prior counters
unchanged. Derive only the exact run's effective next-iteration limit from that
applied receipt at native admission; use the existing instruction/task/reservation
and worker evidence bindings as the admission ledger. Existing independently
authorized same-iteration infrastructure recovery remains separate; never replay
ambiguous source effects. Honest CONTINUE remains
admissible evidence and advances the counter to 27, where another source turn is
denied. Preserve old authorization versions and independently validate archived
pre-26/post-27 evidence in physical publication. Required regression: public CLI
stage -> owned tick apply -> ordinary SOURCE admission at those actual counters ->
writer adoption -> reopened SQLite -> physical publication -> second admission
denied. This is bounded authority under outcome 7, not a global policy reset.

CI passed for candidate `4e5c48fc2150515c4cb5ce0771f4c204b10c532c`, MR !47818, pipeline 2987402948. Verifier 5 finished with REPAIR, closing all seven previous findings and identifying a remaining asynchronous logging leak. Its complete report was rejected because a detailed top-level finding and its shorter classification description were not exactly equal. A read-only diagnostic proved changing only that duplicated description in memory passes the existing validator. Nothing was persisted or adopted.

Current exact verifier request is `desktop:b996c85fd59f267cb7ee029cac2f25f2e56e245de90f3945d6e8526a1b6c38bc`, run `ab5ab1fe-32cc-48c1-985e-3c3800adcfa2`. Never change this original output, admitted instructions, digest, verdict or native history. Never turn REPAIR into PASS. No live ledger edits, SQL repair, native worker dispatch, schedule changes, service activation or source-ticket edits are authorized to the executor.

## Current interfaces and defects

- `elixir/lib/symphony_elixir/factory/review_protocol.ex`: attach emits version 1; all rounds request the full contract sweep. `consistent_result?` compares duplicated finding prose exactly. `validate` collapses all failures to one error. `valid_unresolved?` confuses authenticated obligations with repairs-used accounting. `decision` owns normal two-repair policy.
- `stage_schemas.ex`, `worker_instructions.ex`: native findings are strings and the role adapter flattens risks/repairs into findings/checks; optional observations have no independent disposition.
- `repair_obligations.ex`: retains immutable prior instruction packets and authenticates ordinary repair history, including publication preflight.
- `ticket_worker_runner.ex`: adoption validates exact schema/role/turn/candidate and stopped ownership. Writer completion is not verification acceptance.
- `stage_runner.ex:82`: owned workers have zero report-format repair attempts; semantic report rejection occurs later at adoption.
- `scheduler.ex:1099`: adoption/policy/transition join; preserve its single transactional owner. Do not change its lease/intake behavior in this slice.
- `ticket_verifier_repair.ex`: existing operator grant supports exact consumed BLOCK; do not misrepresent a REPAIR result as BLOCK to reuse it.
- Python publication codecs under `elixir/priv/` independently validate retained review/repair proofs. Preserve old codec/helper bytes; version any necessary new codec and register only the new version.

## Required outcomes

1. New admissions use a versioned typed report with one authoritative record per finding: stable ID, description, classification, required-repair vs observation disposition, and acceptance-criterion or established safety-invariant basis. Summaries/legacy projections are deterministic; no fuzzy matching or model-maintained duplicate prose.
2. Optional observations survive a PASS but never become required writer obligations. Serious security/privacy/contract defects remain blocking regardless of a missing literal AC identifier. No severity-based automatic downgrading.
3. Initial verification is comprehensive. After a repair, the controller binds focused closure/affected-execution-path/regression scope in the admission. It must not require invented full-review claims for unchanged areas; preserve provenance for any carried evidence. Late serious out-of-scope findings cause explicit escalation, not silent PASS or an automatic broadened repair. New original-scope misses must not silently restart unrestricted review.
4. Keep at most two automatic product repairs per contract lineage, preserved across CI/restart and observation/report changes. The controller owns the limit. Record honest non-PASS reports before independently deciding admission/stop. Validate unresolved closures against authenticated prior obligations rather than the automatic counter alone.
5. Return precise validation diagnostics while preserving caller compatibility. Missing IDs, stale candidate/contract, invalid provenance and contradictory verdicts still fail closed.
6. Provide at most one durable, bounded report-only correction for eligible stopped rejected reports, independent of source-repair budget. Preserve the original raw result and its provenance; prohibit source edits, external actions, new evidence claims and verdict laundering. Prefer deterministic correction when an explicit unambiguous mapping suffices; otherwise use a tightly constrained correction mechanism. Never silently rewrite admitted v1 evidence or globally relax old schemas. Public admission and adoption must actually exercise this path, not just a helper with no caller.
7. Existing admitted v1/legacy packets, history, publication receipts and uncertain records remain readable and immutable. Current PPL-9881 needs a supported exact-report reconciliation path; correcting its format alone does not authorize exceeding the two-repair policy. Surface the remaining policy stop honestly. Propose a narrowly bound operator continuation only if existing authority cannot represent it; no global limit reset.
8. Update root README, SPEC and relevant Elixir README/WORKFLOW documentation for changed contracts; no dashboard redesign.

## Test seams already approved by the user

- Public review/report admission and validation: realistic differing prose/order, typed IDs, observations, genuine missing evidence, stale SHA/contract, contradictory verdicts, known prior obligations and BLOCK-derived obligations.
- Ordinary controller/scheduler adoption and recovery: initial review -> repair -> scoped follow-up -> second repair -> PASS/explicit stop; reopened SQLite; no third automatic repair; report-only correction once, original history unchanged, no new source tools/model rerun of implementation.
- Publication compatibility: retained v1 physical/protocol proofs remain accepted or precisely rejected as before; typed new proofs work through the real public adoption/codec seam.

Use red -> green vertical slices. Existing examples: `factory_review_protocol_test.exs`, `factory_ticket_worker_runner_test.exs`, `factory_ticket_worker_lifecycle_test.exs`, `factory_verifier_repair_test.exs`, `test/python/review_protocol_codec_test.py`. Test real SQLite/OTP interfaces; mock only external provider I/O. Do not assert an internal helper was called instead of asserting observable adoption/stop.

## Scope

Own the review/report modules above, any small new factory report module required by that interface, narrowly required adoption/caller integration, new versioned publication codec when necessary, their tests, and their documentation. No workstream 2/3 fixes, product Grail source, cleanup, config/budget weakening, transport blanket retry, MR mutation, automation change or deployment.

## Bootstrap and Git workflow

The sole executor owns `/private/tmp/symphony-review-contract.gTnJeO/source`, branch `cgable/review-report-contract-v2`. It is a new Git worktree initially at the development ancestry. Copy the pinned deployed snapshot into THIS worktree only, excluding `.git`, `deps`, `_build`, `bin`, `log`, `logs`, `cover`, `__pycache__`. This is a mechanical baseline import, not implementation. Preserve this plan. Verify all manifest source hashes, and stop if tracked executable source outside the snapshot would accidentally enter the deployed artifact.

Commit the named deployed-baseline file set with `git commit --no-verify`; record that SHA and create local integration branch `cgable/factory-reviewed-integration-20261026` at it, without touching either existing dirty checkout. Then implement only the required slice in separate commits. Named-file staging only; never git add -A or git add .; never force/reset/clean. No push. Parent will independently review and perform the user-authorized local merge/deployment.

## Commands and verification

- Runtime: `/opt/homebrew/bin/mise exec --` selects Elixir 1.19/OTP28. Use isolated build/dependency copies; never write installed build/deps or start the real factory from tests.
- Dependencies exist at the installed R19f source (read its compact manifest `source_root`) and at `/Users/cgable/Repos/symphony-ticket-chat-implementation/elixir/deps`. Clone/copy them to the isolated tree. Test build is separate from deployed `dev`.
- In `elixir/`: `ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec -- mix test test/symphony_elixir/factory_review_protocol_test.exs` (first narrow red/green); then the affected public lifecycle tests and Python codec tests.
- `mix specs.check`, formatter check on touched files, and repository `make all` before handoff. The user explicitly requires tests before local deployment and repository AGENTS requires full gates; this is not a routine Grail push/CI cycle. Record baseline lint issues separately; do not refactor unrelated lint. Prior full gates had pre-existing lint failures, so do not claim coverage/dialyzer if the gate stops before them.
- Before completion: exact baseline/candidate SHAs, named diff, tests/commands/results including failures, and explicit limits.

## Stop conditions

Report (do not work around) a changed deployed manifest/source, needing to rewrite old evidence/codecs, a proposed safety bypass, inability to prohibit source effects during correction, needing an unapproved workstream 2/3 change, or a scope expansion beyond review/report semantics and its direct callers. A failed narrow test may be debugged and corrected; two failed fix attempts on the same ambiguous condition require a report before further expansion.

## Maintenance

Schema producers, controller validators, history consumers and Python publication codecs must agree on versioned semantics. Keep exact identity and provenance strict; prose is presentation. A report accepted for adoption is not product PASS. Explicit operator exceptions remain separately journaled and must not masquerade as a new normal allowance.
