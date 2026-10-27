# Plan023 source qualification

Base: `4f58e6a86396bb76a57fca6cdeb519a91749afb2`, the accepted-source merge
of014 and022. Scope is exactly the thirteen Elixir paths approved in plan023,
plus this report. No private resources, public exports, configuration, schema,
repair limits, or live factory/product state changed. No push or deployment ran.

## Preserved behavior

- Aliases and literal layout retain their original values. Recovery splits the
  stopped-binding prefix and final-message parsing without changing check/SQL
  order, malformed-input short-circuiting, errors, or atomic preimage validation.
- Worker result handling remains under the original rescue. It records the
  genuine transport failure before reconciliation and returns the original error
  when exact native completion is unproven.
- Broker request reads remain before the dispatch rescue/catch. Duplicate checks
  short-circuit in their original order. Expiry retains both clock reads in their
  original order. Serialization and remembering results remain outside that rescue.
- Publication retains chmod, write, sync, exclusive link, callback, temporary
  unlink, close, and failed-result cleanup order. Response and uncertainty helpers
  return the same error/nonboolean values; redundant-with removal does not coerce
  success. The test poll consumes ready/timeout and retains its final file check.
- Owner preparation groups only already captured values. Finalization uses an
  equivalent implicit after, closing the same context on every original outcome.
  Physical/native/owner observations, recovery ordering, and deadlines are unchanged.

## Incremental green checks

Commands ran from `elixir/` with `ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec --`.
Every step also passed specs, formatting, and the complete recorded public-export
comparison before the next source edit. Logs use the following `_build/` prefixes:

| Step | Covering result | Log prefix |
| --- | --- | --- |
| Aliases |128/0,249.4s |cleanup-alias |
| Broker dispatch |34/0,5.5s |cleanup-broker-dispatch |
| Matching response |34/0,4.9s |cleanup-broker-response |
| Uncertainty response |21/0,5.1s |cleanup-broker-uncertain |
| Exclusive publication |21/0,4.7s |cleanup-broker-commit |
| Redundant with/poll result |34/0,4.9s |cleanup-broker-normalize |
| Recovery snapshot |13/0,127.8s |cleanup-recovery-snapshot |
| Final output validation |13/0,137.5s |cleanup-recovery-output |
| Broker predicates |34/0,4.6s |cleanup-broker-predicates |
| Worker result handler |13/0,53.0s,11excluded |cleanup-worker-result |
| Captured owner inputs |1/0,105.7s,162excluded |cleanup-owner-context |
| Reader/literal layout |API2/0,1.8s,82excluded; matrix1/0,147.5s,162excluded |cleanup-reader-layout |

The final implicit-after change was followed by the full frozen checks below,
with no further production/test source changes.

## Final frozen checks

Mix commands additionally used `HEX_OFFLINE=1`. Exact commands, log digests, and
results are recorded in `_build/cleanup-final-results.json`.

- Recovery, WorkerEvidence, ResumeRefusal, all three broker/owner files, and full
  AppServer:162/0 in381.1s, `_build/cleanup-final-core.log`.
- Lifecycle `--only mr_owner_service`:4/0 in414.0s,159excluded,
  `_build/cleanup-final-owner.log`. This includes the slow positive, complete
  failure/lifetime matrix, exact omitted-key denial, and existing owner checks.
- Lifecycle `--only native_publication_completion`:1/0 in455.2s,162excluded,
  `_build/cleanup-final-publication.log`.
- Full `factory_ticket_push_readback_test.exs`:97/0 in291.0s,
  `_build/cleanup-final-readback.log`.
- Python `review_protocol_codec_test.py`:16/0 in2.328s,
  `_build/cleanup-final-codec.log`.
- Both preserved independent publication reproductions passed1/0 each,3.3s and
  1.2s, `_build/cleanup-final-publish-race.log` and
  `_build/cleanup-final-uncertain-residue.log`.
- Specs, format check, diff check, public-export comparison, and all148 private
  byte/mode checks passed. All194 modules/1502 public functions are unchanged;
  export JSON SHA256 remains
  `ee18e166981cacb75809c07c376be55dc539f53ca3169cd8fdde796f11046a7e`.

## Exact lint and quality limits

Normal-directory `mix credo --strict --format json` exited14 with650 findings.
The authenticated6384 baseline has653. The exact finding multiset excludes only
line_no, column, and column_end: **zero added, three removed**. Filename, check,
message, scope, trigger, priority, category, and multiplicity remain significant.
The third baseline removal is the existing broker service148-character expiry
line naturally removed by the approved predicate extraction, not separate legacy
cleanup. No suppression, filter, threshold, or lint/formatter configuration changed.

- Baseline SHA256: `bf806060628a5183dddda558324fe92ed706b57562ca96b3600d2a2161759a94`.
- Final Credo JSON SHA256: `bae13fc2fe135777c6329d3ee67f22f9ed825d07bd55c3c00d4d87a92b887aac`.
- Exact delta: `_build/cleanup-final-lint-delta.json`, SHA256
  `85ec5b6fe5a1bd492287b3a4e0a43308ab7b489dc119d12c8eca74b2c24c9e17`.
- Frozen Elixir source patch SHA256:
  `b9e4972f2a5d9a23981a7c54571542c47fb35f0bbdb707f28a1d8df1bd28a460`.

`make all` exited2 at `mix setup`: offline Hex lacks the cached registry entry
for `file_system`. Build, lint, coverage, and Dialyzer were not reached through
that command; direct lint/spec/format and selected tests above are separate proof.
Coverage, Dialyzer, and full-suite health remain unproven. Existing lifecycle
fixture warnings were retained, and the unrelated baseline StageRunner assertion
was neither edited nor suppressed. This is a source checkpoint awaiting detached
review, not deployment or a claim about the real ticket's current state.
