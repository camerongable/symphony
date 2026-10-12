# U7 native producer schema and bounded probe receipt

## Scope

October 6: offline locked-dependency restoration, two startup/shutdown checks,
two originally approved Luna Low turns and one explicitly approved additional
Luna Low turn. No production enablement, real-ticket actions, online dependency
downloads, upgrades, global settings, Jira/GitLab writes or source-repository
commit/push.

Scratch artifacts: `/private/tmp/symphony-u7-native-capability.CXdv7U`.

## Observed results

- CLI version 0.160.0. REVIEW and FILE_SOURCE startup/shutdown checks completed.
  Requested/effective configuration is not independent permission-denial proof.
- Turn 1: model reported write denial; fixture unchanged. Captured events lack
  independent native command/error evidence. Denial acceptance is inconclusive.
  Reported token total 45,003; input 44,839 (21,248 cached), output 164.
- Turn 2: API rejected the producer schema with `invalid_json_schema`, naming
  `next_slice` as absent from `required`. No successful source/adoption result.
  Its diagnostic tuple error also prevented retaining a complete JSON receipt.
- Turn 3: test returned from the worker runner, then the diagnostic serializer
  raised `Protocol.UndefinedError` for `DateTime`. The error occurred before saving
  the result or attempting adoption. Fixture teardown removed its local state.
  Native edit outcome and usage cannot be established from retained evidence.
  Test seed 431983; one test failed after 16.3 seconds. No retry was performed.

All three durable allocation markers remain spent. The third call is not
represented as a source capability PASS or as a repeated schema rejection.

## Implemented fix and checks

`StageSchemas.for_provider/1` requires every declared object property recursively
for producer schemas. Existing required order, types and strict schemas are
preserved. `StageRunner` sends the adapted schema while validating results against
the original durable contract, including older minimal outputs.

- Regression RED: seed 69936, one test failed because declared optional fields
  were absent from the provider-required list.
- Stage-runner group GREEN: seed 847977, 20 tests, zero failures.
- Writer/lifecycle group: seed 457434, 56 tests, zero failures; 647.3 seconds.
- Test-environment specs, focused formatting, strict Credo and diff checks passed.
- Independent read-only adversarial review found no concrete defect in the
  producer-only adapter; it is not a general-purpose strict-schema converter.
- Dev-environment specs did not qualify: restored compilation lacked
  `SymphonyElixirWeb.Router.init/1`. Do not conflate test-env specs with full build.

Scratch evidence serialization now handles timestamp structs and tuple errors.
Future attempts save primary result/evidence/Git observations before serializing
the detailed event stream. Offline regression seed 246598 passed (one test,
zero failures), without calling a model. This cannot recover the lost third-call
receipt; a further native call requires explicit user approval.

## Remaining boundary

Production V1 remains disabled. Native denial/source/adoption acceptance, staged
Jira adapter qualification and the unchanged full quality gate remain outstanding.
Latest full coverage is 98.54%, not the required 100%. Slice 3 is not complete.
