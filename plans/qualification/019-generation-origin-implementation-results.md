# Plan019 source implementation evidence

Production checkpoint: `216eadb`; final test-only checkpoint: `ae4f0bc`.

The source executor changed only the two publishing/ordinary-rejection modules, added seven immutable resources, and added scoped public/codec/lifecycle regressions. All 136 previously tracked `elixir/priv` files remain byte-identical to `43d50b5`. No product source, live ledger, service, schedule, GitLab, model/provider operation, or historical producer execution was performed by this executor. The continuous goal and delivery monitor were not resumed.

## Behavior

- Generation catalog5 retains catalog4's seven entries and adds only the supplied, verified c646/v2 tuple. Its schema and eight-entry limit are unchanged.
- Readback catalog19 retains all 13 catalog18 origins and adds only the supplied e47-r2/v34 tuple. Reader19 remains status-only for historical producers.
- Exact audit4 is byte-identical to `ppl-9881-rejection-v4.json` (`dfc045f0753fa7d7ddaa3ddd28bbfe0c00031391bef216903a75c0c48314101f`). Its three sealed historical contexts are independently validated. v3 still requires exactly two; v4 requires exactly three. Neither creates a general retry rule.
- History25 and helpers35/36 retain explicit current/historical associations and all generation, ordinary-retirement, physical-history, capability, and issuance fences.
- The cold-reviewed size-accounting refinement discounts only the second identical confirmed native response at the exact ordinary-generation observation path. Both hashes must match canonical UTF-8 bytes, including cursor and JSON type distinctions. It retains the full first response and all metadata, copies modified ancestor maps, and returns the untouched decoded journal. Existing numeric bounds and independent authority checks are unchanged.

## Red/green evidence

Meaningful red cases, each followed by a scoped green run:

1. New history25 still reading catalog4 rejected the synthetic physically attested A-to-B v2 generation journal. Selecting the pinned catalog5 made the retained and current generation tests pass (27 tests, 0 failures).
2. The public ordinary-retirement validator rejected an exact fourth record following three sealed contexts. Explicit audit4 registration and exact prefix handling made the public cases pass (4 tests, 0 failures, including coherently pinned prefix/context/version mutations and historical-row tampering).
3. `push_budget_decode` rejected a greater-than-2-MiB ordinary-generation journal containing two identical confirmed native responses at the existing remainder check. The size-only refinement made it pass without changing the returned journal or its canonical hash. The codec suite passes 10 tests, including rehashed changed content, wrong hashes/cursor, boolean-versus-integer mismatch, wrong paths/types, unrelated oversized metadata, invalid completed predecessor, absolute cap, and small legacy cases.

Initial private-test setup mistakes (`bad_name` for a temporary application path and a duplicate supervised Store ID) were corrected before relying on their results. They were not counted as behavior-reproducing red tests.

## Gates

Evidence directory: ignored `elixir/_build/generation-origin-evidence/`.

- `python3 -B elixir/test/python/test_generation_release_origins.py`: 27/0; `python-generation.log`.
- `python3 -B elixir/test/python/review_protocol_codec_test.py`: 10/0; `python-codec.log`.
- Public readback of a relocated v34 producer and explicit denial of its issuance: 1/0. Fast ordinary-audit suite: 4/0; `audit-public-lint-clean.log`.
- Final combined public suite: 102 tests/0 failures, 1 production-only case excluded, 280.5s, exit0; `public-216.log`.
- Strong composed child: actual 1 test/0 failures, 158 excluded, 350.7s. It exercised generation A's exact helper/companion tuple, B's retained33/34/history24, the greater-than-2-MiB duplicated native observation, three sealed historical rows, genuine v34 no-child rejection, CAS rollback, exactly one normal-owned retirement/PREPARED successor, repeat no-op, current36/history25 publication, fresh verification/MR progression, and protected negatives. The outer wrapper initially failed only because it expected a subprocess stdout marker that its own `System.cmd` assertion captures and discards. After removing that impossible forwarded marker, all actual outer postconditions were replayed against the same saved stdout and captured child exit0: PASS, exit0 (`outer-postconditions-replay-pass.log`). This executed the parsed wrapper's status/count/seven visible markers/physical-byte assertions; an independent recursive comparison verified all143 tracked source priv files against frozen216 before and after. The full child was not rerun after this marker-only wrapper correction.
- Separate production-dev-beam capability selector guard: 1/0, 3 excluded; `production-guard-216.log`.
- `mix specs.check` and final `mix format --check-formatted`: exit0; `specs-final.log`, `format-delivery.log`.
- `HEX_OFFLINE=1 ... make all`: exit2 during setup because the `file_system` Hex registry entry is not cached; `make-all.log`. Coverage and Dialyzer were not reached.
- Direct `mix credo --strict --format json`: exit14, 653 inherited findings. Final post-fixture `credo-final5.json` exactly matches `/private/tmp/symphony-review-contract.gTnJeO/owned-generation-frozen-credo.json` as a multiset after omitting `line_no`, `column`, `column_end`: zero added, zero removed. Earlier test-only lint findings were corrected. The final wrapper correction only removes the impossible forwarded marker from its string list.

The first combined test-mode run accidentally included the production-only guard (102 tests, 1 failure at that guard). The corrected command excludes `capability_production_only`; that guard is qualified separately against dev beams. The corrected pre-refinement run passed 101 tests/0 failures, 1 excluded, 144.8s (`public-final.log`).

The first composed upgrade fixture completed actual A generation, the real v34 no-child rejection, CAS rollback, one owned retirement and repeat no-op, but failed the post-retirement history gate (1 test/1 failure, 361.8s; `composed.log`). Source inspection found two fixture-ordering errors: selecting A only after preparation produced a forbidden A-helper/B-companion tuple; using current35/history25 for a predecessor before later synthetic audit enrollment would change that predecessor's private history hash. No production fence was relaxed. The next owned synthetic child was explicitly stopped after a read-only check confirmed its predecessor35/history25, preserving `composed-final.log`. The independently accepted correction captures preparation and execution from A; uses33/34/history24 for initial B; seeds audits1–3 before first publication; asserts those issued physical bytes remain unchanged; and selects35/36/history25 only after audit4 is sealed. The final child passed; `composed-final-reviewed.log` preserves the outer marker-only assertion failure, and `/private/var/folders/tb/_b68kb9x24qbkdcvjx7kzmlr0000gs/T/generation-push-rejection-5/child.log` preserves actual 1/0 output (SHA256 `d2b6c186bf1d9d5992da4be8f5c5bbae064886fdc9d5bb2bd64bcb4ffad389be`). Two local replay-harness setup mistakes (recursive versus top-level snapshot shape and two-argument assertion AST shape) were corrected without source changes before the successful postcondition replay; no child rerun or test backdoor was introduced.

The parent separately reported the actual untouched current publication chain, exact closed authority, and retained predecessor history as read-only PASS against the inactive `216eadb` artifact with zero writes. Those are parent-owned qualification results, not evidence of a retry, push, CI pass, verifier pass, delivery, or human review. Source verification alone does not authorize deployment.
