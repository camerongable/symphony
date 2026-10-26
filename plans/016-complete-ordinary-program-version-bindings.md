# Plan 016: Complete ordinary push program bindings without rewriting history

## Authority, baseline and ownership

P0 correctness follow-up to plans013 and015, 2026-10-26. User authorizes local integration/deployment and interventions toward PPL-9881 human review, not external factory PR/push. Plan015 real confined generation, restart and exact controller commit passed, but its composed publication regression stopped on an actual current-version omission. No live push or new product candidate has occurred. Live ticket is still REPAIRING on4e5c48fc2150515c4cb5ce0771f4c204b10c532c with its original stopped COMPLETE output.

Scoped production baseline is16ed7bf83bdd8f93f1ca29bb95d2a6b821457f6c; TicketPushIO and priv bytes must remain identical to that baseline before execution. Executor worktree `/private/tmp/symphony-review-contract.gTnJeO/ordinary-history-source` will be created from local integration including final015. One executor owns it. Parent owns index/integration/rollout/live operations. Never edit either dirty development checkout or installed release. Read elixir/AGENTS and applicable shared rules completely. Preserve other writers.

## Exact finding and semantics

Read these sources yourself before editing:

- `elixir/priv/ticket_push_history_validator_v22.py:483-510`: ordinary `validate_archived_ci_authority` accepts executor names throughv29/v30, but `history_name` dictionary at503 ends atv27/v28. Passing a valid current v29 ordinary execution raises KeyError after generation succeeds. Caller438 uses this path for retained performed push evidence; this is a retained-history compatibility bug, not proof that the live ticket attempted a new push.
- `elixir/priv/ticket_push_executor_v29.py:154-160` andv30 counterpart bind the exactv22 history program. They cannot be repointed in place because persisted receipts pin bytes.
- `elixir/lib/symphony_elixir/factory/ticket_push_io.ex`: external-resource pins147-160, recognized current/historical helper paths, `large_payload_program`, `history_program`, readback reader/origin pins, `local_capability?`, `helper_name` defaults. Preserve every old program path and digest while selecting new programs only for new operations.
- `elixir/priv/ticket_push_status_reader_v16.py:17-38` pins origins and current+retained issuer hashes; `ticket_push_readback_origins_v16.json` retains release origins. Add new physical versions without dropping old ones or executing old receipt programs.
- `elixir/test/python/review_protocol_codec_test.py` exercises writer-readiness/report strictness and physical-program pin parity. `factory_capability_codec_test.exs`, `factory_ticket_push_readback_test.exs` and `factory_ticket_push_v3_boundary_test.exs` exercise public current/retained codecs.
- `factory_ticket_worker_lifecycle_test.exs`: plan015 product workflow test, protected negative, existing ordinary capability recovery scenario; `assert_ordinary_physical_negatives` calls the exact failing method with a real SQLite/binding/execution proof. Keep this discriminating composition, do not remove it to make tests pass.

## Scope

New immutable physical files ONLY: `ticket_push_history_validator_v23.py` fromv22, `ticket_push_executor_v31.py`/v32 fromv29/v30, `ticket_push_status_reader_v17.py` fromv16, `ticket_push_readback_origins_v17.json` fromv16 (all under elixir/priv).

Other allowed edits: TicketPushIO; focused tests listed above; minimal current-version expectation updates in lifecycle tests only where the operation actually selects the new current program; this plan's evidence. Parent maintains plans/README. No unrelated harness redesign.

Out of scope: changing any existing priv byte, report schema/semantics, source path policy beyond accepted015, repair limits/counters, workflow/config, source worker output/history, ledger writes, old receipts, automatic reruns, scheduler/lease/auth freshness, MR state, real GitLab/network/push, service deployment by executor, workstream014. No unknown program acceptance, version arithmetic guesses, digest bypass, new TTL, or blanket compatibility allowlist.

## Steps and invariants

1. Confirm clean isolated branch and scoped baseline bytes. Read develop-test-first completely. Preserve plan015 RED traceback as actual composed evidence: v22 dictionaryKeyError forv29. Add a quick program-binding regression alongside existing codec tests so future current issuer selection cannot silently diverge from ordinary-history lookup. It must cover both current regular and capability issuers plus retainedv29/v30 and unknown/mismatched programs, using literal expected identities/digests or actual public producer outputs—not a test that recomputes the same incomplete mapping. This supplements, never replaces, the real composed publication test.
2. Add v23, preserving v22 logic except completing explicit program/history associations: v29/v30→v22, newv31/v32→v23, all older mappings unchanged. Centralize this lookup within the new validator enough to prevent its ordinary acceptance list and lookup keys drifting. Keep retirement and capability distinctions; do not infer all versions have the same authority. Missing/unknown mappings reject fail-closed, not success and not broad fallback. Addv31/v32 to relevant current-version behavior lists with the same semantics asv29/v30; audit all occurrences rather than blind replacement of unrelated older-version logic.
3. Addv31/v32 executors usingv23. Add reader/originsv17 and compiled TicketPushIO selection/pins for new issuances, retaining all older paths/digests/readbacks includingv29/v30. Existing physical helpers must remain byte-for-byte immutable. Preserve all origin entries; do not invent a historical release attestation. Parent's read-only inventory found zero persisted16ed-origin strings as of21:00UTC; parent repeats inventory before cutover and adds an explicit attestation only if genuinely required by persisted evidence.
4. Run fast Python codec/parity and public Elixir push/readback tests. Re-run the plan015 workflow composed publication and protected-path regression plus one existing ordinary capability/restart publication scenario. They must reach their full success assertions, not just generation. Store reopen and retained-history validation are required. Test real local Git/SQLite/OTP; fake only external runtime/GitLab boundaries. No model or external operations. Include retainedv29/v30 ordinary history proof under new validator and mismatched history path/hash rejection. If the real composed fixture cannot produce a retained v29/v30 receipt without editing old helpers, stop and describe the narrowest fixture extension; do not drop compatibility coverage.
5. Verify formatting/specs and full quality gate, compare exact16ed Credo baseline657 using `/private/tmp/symphony-review-contract.gTnJeO/workflow-baseline-credo.json` (exit14). No introduced lint findings; coverage/dialyzer only claimed when actually run. Audit all old priv hashes against baseline. Commit locally named files with --no-verify, neverpush/merge. Freeze an early complete candidate for detached independent adversarial review before running the longest composed tests; no source edits during review.

## Commands and done criteria

Use mise, ERL_FLAGS='+S 4:4', private warm deps/build copies from16ed installed source/artifact (paths in015). Never compile installed files.

- `python3 -m unittest discover -s test/python -p review_protocol_codec_test.py` =>0failures, including new binding matrix.
- `mix test test/symphony_elixir/factory_capability_codec_test.exs test/symphony_elixir/factory_ticket_push_readback_test.exs test/symphony_elixir/factory_ticket_push_v3_boundary_test.exs` =>0failures.
- `mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:<plan015-positive> ...:<plan015-negative> ...:<existing-explicit-capability-scenario>` => all selected success; selectors obtained from current source, no stale line guesses. Explicit fixture booleans from015 must remain.
- `mix specs.check`, scoped `mix format --check-formatted`, `make all` and exact Credo multiset delta; honest limits if existing657 stops fullgate.
- `git diff --name-status <baseline>` includes only allowed source/tests/new programs/plans; every baseline priv file hash unchanged, all historic origin entries retained, new programs/pins agree.

## STOP / maintenance

Stop for scope drift, active overlapping writer, capacity<20GB, any proposed old-helper/ledger/report rewrite, unknown old physical authority, new lint not narrowly fixable, mismatched release origin, inability to prove ordinary publication/readback after reopen, or need to weaken identity/authorization. Report exact evidence, do not improvise a live bypass. This plan fixes explicit immutable-program associations; future physical versions require both fast producer/consumer parity and a real ordinary+capability composed publication regression before local rollout.
