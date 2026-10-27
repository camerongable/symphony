# Plan 018: Retain the actual publishing origin across upgrades

## Status and authority

P0, scoped compatibility fix. Planned at integration `d425343`, 2026-10-26. User authorized implementation, tests, local integration and guarded deployment to get PPL-9881 moving. No external factory push/PR. Parent owns live service, schedules, qualification and plans/README; separate executor owns source in a dedicated checkout. Never edit Grail, live SQLite, old releases or receipt bytes.

Live c646 release adopted the stopped worker result and committed candidate `eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834`. State is CI_PUSHING. No new push occurred. The old COMPLETED push is for SHA `4e5c48fc2150515c4cb5ce0771f4c204b10c532c`, generation61, verifier4. Read-only `TicketPushIO.readback` fails `:ticket_push_program_changed` on both c646 and16ed; `TicketPushRequalification.current_binding` passes. Root found no ledger writes. Do not re-execute or reconstruct this historical producer.

## Evidence and intent

Actual historical producer:

- Release `/Users/cgable/Library/Application Support/ai-factory/releases/symphony-generation-handoff-cnRVdUfY-r19f`.
- Manifest `evidence/release-manifest.json`, SHA256 `1b3bbe66c469a3aea634004c6b17f77f2b4533f87a6882a48649b7f3e8587d48`, kind `FACTORY_PUSH_HANDOFF_RELEASE_V1`, schema54.
- Helper `dev/lib/symphony_elixir/priv/ticket_push_executor_v26.py`, SHA256 `67d9a0625e77f653e70aa91744ac74ec540451063f5d386860f45c66974b6aad`.
- Companion in same directory, `worker_file_companion.py`, SHA256 `87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b`.
- History `ticket_push_history_validator_v20.py`, physically present and hash-equal to the original execution. Root verified all three files' recorded hashes.
- Exact completed receipt SHA256 `743b489bf716d072bb9955f827397588e1c8451974e90c27b64b67e4394b06e1`; reservation `ticket-push:9e88cc166501c12d47d1833ce92231ea80754b9484849d57a774bafeebacf450`.

Current `TicketPushIO` selects origins17/reader17. `capability_historical_origin?` requires exact helper/companion path+hash membership. Catalog17 has12 entries, ending at r18/v24, and no r19f/v26 entry. Reader17 pins its catalog hash/version and caps12. History23 `push_program_origin` lines748–781 independently pins catalog16 and accepts external names12–20 or exact r18/v24. Merely fixing the Elixir selector cannot pass the next producer's retained-history fence.

Test gap: synthetic fixtures rebind a private catalog to one supported origin and never exercised this actual prior publisher through the next version. Preserve those adversarial tests, add exact enrollment and composed retained-history coverage. Do not generalize sibling/path trust or accept every installed release.

## Scope

Modify only `elixir/lib/symphony_elixir/factory/ticket_push_io.ex`, relevant public push/readback/codec tests, and this plan's evidence. Add immutable `elixir/priv/ticket_push_readback_origins_v18.json`, `ticket_push_status_reader_v18.py`, `ticket_push_history_validator_v24.py`, `ticket_push_executor_v33.py`, `ticket_push_executor_v34.py`. Parent maintains index. All131 existing priv files must remain byte-identical; no changes to existing readers, helpers, catalogs, histories, source-policy gates, counters, repair/review contracts, TTLs, schemas or live operations.

## Implementation

1. Read complete develop-test-first/tests/mocking, applicable rules and Elixir AGENTS. Public lib defs need adjacent specs; comments explain invariants. Use public TicketPushIO.readback/execute and history validation with real temp files/SQLite, not mocked internal calls. Existing readback fixtures `attested_fixture`, `install_forward_attestation` and exact pinned r18 test are examples. Use one vertical red/green regression, not all tests first.
2. RED the missing exact producer provenance through public status readback using synthetic physical release fixtures; separately pin the actual catalog entry's literal path/hash/manifest identity. The production entry must come from freshly verified manifest+artifact bytes, never fixture-derived constants. Do not run legacy producer code. Add negatives for sibling same-byte path, helper/companion/manifest/history mutation, invalid catalog and issuance callback: historical status must never authorize execute.
3. Add catalog18 preserving every catalog17 entry exactly, plus exactly the actual r19f/v26 RELEASE_ARTIFACT_V2 entry. No unobserved v25 entry or invented c646 publisher. Add reader18 retaining all reader17 checks and bounds, pin new catalog18 hash/version; increase entry bound only to the required13. Preserve old versions and hashes.
4. Add history24 from history23 with the pinned origin catalog/version/hash and exact new r19f/v26 attested external-origin case alongside existing retained cases; preserve physical helper/companion/history, manifest/schema, checkout, stopped ownership, receipt, archived CI, lineage and all source fences. Add helper33/34 from31/32 pointing at history24. Update shared explicit version associations33/34→24, retain31/32→23 and29/30→22. Every helper-name fence must treat33 like31 and34 like32: generated_only_commits, validate_physical_predecessor's programs map, validate_archived_ci_authority retirement subsets, CAPABILITY_HELPER_FORMAT (33 optional,34 required), and all other version membership/shape checks found by a scoped search. Test that missing generated history/retirement/capability evidence is rejected for both new helpers as applicable; do not merely assert dictionary equality. No arithmetic or filename-only authority.
5. Update TicketPushIO issuance pins to33/34+24 and status pins to18, retaining local/historical31/32 recognition. Adapt only synthetic forward fixture installation to new18 catalog/reader, without rewriting retained production artifacts. New reader recognizes33/34 hashes as well as all retained versions.
6. Prove new history24 accepts authentic retained v26 execution/predecessor and rejects changed origin/history path/hash without invoking it; prove both new regular and capability producers reach their real retained-history validation. Prefer existing dedicated public codec/readback tests, plus narrow complete publication lifecycle if not already covered by those fixtures. Tests must discriminate the catalog-missing original behavior, not just inspect text.
7. Seal candidate for independent review in a detached checkout. Parent then qualifies actual current stopped ledger with Store.start_read_only and new compiled artifact: exact old receipt raw readback/receipt_valid and reconstructed old candidate historical proof; current raw run/task/history unchanged, total_changes0, no push/thread/turn. Also run history24 archive + full physical predecessor against the authentic original receipt, not a tampered copy. Any additional actual-history rejection is a STOP, not permission to weaken it.

## Verification and git workflow

From isolated checkout/elixir using `ERL_FLAGS='+S 4:4' mise exec --` and ignored private deps/build copied from qualified source; do not compile or write old release build. Capacity PASS47.02GB, zero active factory writers at dispatch. Preserve one writer per checkout.

- Run failing new regression first, then narrow green, then `mix test test/symphony_elixir/factory_capability_codec_test.exs test/symphony_elixir/factory_ticket_push_readback_test.exs test/symphony_elixir/factory_ticket_push_v3_boundary_test.exs`; run the production-only guard separately if test mode excludes it.
- `python3 elixir/test/python/review_protocol_codec_test.py` from repo root (use actual existing invocation if it takes parameters; report it).
- Selected real ordinary/capability publication lifecycle tests and protected negative, no broad unrelated sweeps. No parallel legacy publication probes or fake receipt relabeling.
- `mix specs.check`, `mix format --check-formatted`; `make all` and direct lint if setup stops early. Existing lint653 is NOT_GREEN; compare exact findings excluding locations, no added findings. Coverage/Dialyzer not reached are limits, not PASS.
- Compare all existing priv bytes against c646. Report exact red/green commands/counts/exits, immutable artifact diff, source SHA, and limits. Named-file local `git commit --no-verify` authorized; no push/MR/service/automation/SQL writes.

Report STATUS COMPLETE/STOPPED, steps and actual results, changed files, SHA, deviations. Max two revisions for the same ambiguous finding; stop and refine instead of accumulating exceptions. Actual deployed qualification must include current retained ledger origin, not only synthetic fixtures. No successful local test is product CI or human-review readiness.
