# U7 native ordinary lifecycle evidence

October 6 continuation. The user authorized additional GPT-6 Luna acceptance
calls without per-call questions. Each attempt retains a spent marker; uncertain
operations are not replayed. This supersedes the earlier pending-call-approval
note, not the production capability gate.

## Scope and observed failures

All source writes were disposable synthetic fixtures. No real ticket, live
Jira/GitLab action, deployment, global configuration change or repository push
occurred. Native sessions use the existing authenticated CLI, version 0.160.0.

- Source attempt 4 passed: guarded read/CAS edit and controller commit, but not
  the complete scheduler lifecycle.
- Lifecycle 5 rejected missing writer commit intent. The packet now specifies
  conventional commit intent for edited slices; nullable no-edit/BLOCKED output
  remains supported. Regression and independent review passed.
- Lifecycle 6 passed two writer turns, same thread/checkout, then fresh review.
  The verifier manually isolated Git configuration; controller-check receipts
  were not exported by that harness version. It is limited evidence.
- Denial attempts 7/8 lacked command-level evidence. Model-reported denial is
  not treated as permission acceptance.
- Model-free sandbox probes 9/10 observed OS-denied writes; 10 additionally
  proved network denial against a live loopback listener with controller
  connections before/after. No per-command policy override was supplied.
- Lifecycle 11 correctly blocked review because ambient Git attempted to read
  inaccessible global configuration. Both writer passes were retained. This
  prompted the REVIEW-only environment fix below, not broader access.

## Scoped Git fix

REVIEW sessions use core environment inheritance and explicit Git configuration
isolation, disable optional locks/lazy fetch/replacement refs/fsmonitor/hooks,
and direct read-only packets to CommandLineTools Git by absolute path. FILE_SOURCE
remains no-shell with guarded file tools. Writer allocation and independent
review context do not change. No user Git settings are modified.

- Absolute-Git packet regression RED: seed 766444, 1 failure.
- Focused packet/config GREEN: seed 422722, 2 tests, 0 failures.
- Independent frozen-source review found no blocker.
- Sandbox 12: seed 777098, 1 test, 0 failures, 1.9 seconds. Actual server commands
  prove bare non-login Git resolution, isolated global configuration and login
  shell absolute-Git inspection; OS filesystem/network denials still hold.

## Native lifecycle 13

Seed 25435, 1 test, 0 failures, 68.5 seconds. Actual Scheduler/TaskLauncher/
TicketWorkerRunner and native sessions, with synthetic Jira/parent fixtures:

- One writer thread resumed for two separate turns, CONTINUE then COMPLETE.
- Controller checks and owned process-stop receipts retained for both passes.
- Fresh independent verifier inspected the pinned candidate with native commands.
- All three worker evidence records became CONSUMED.
- One clean source checkout progressed WRITING → VERIFYING → PUSHING.
- Candidate `e03ca33dc80ba3377a76e6c946e26e7d624d882c`; only `fixture.txt` changed,
  with exact bytes `final\n`.
- Independent bare bundle clone at
  `/private/tmp/symphony-u7-final-bundle.ET55KN/repo.git` reproduced SHA/content.

Raw artifacts: `/private/tmp/symphony-u7-native-capability.CXdv7U/lifecycle-13-*`
and `sandbox-defaults-12-*`. No push or MR was attempted. This does not prove a
native Desktop parent, live Jira integration, or complete production acceptance.

## Remaining gates

Native Jira provider qualification also passed: probe 4, seed 935880, 1 test,
0 failures, 7.2 seconds, zero model turns. The owned native controller session
advertised the staged atomic-label schema/annotations, invoked exactly one atomic
PUT against the ephemeral loopback Jira fixture, and closed its owned port. Raw
`jira-native-4-*` artifacts preserve catalog, arguments, acknowledgement and
independent HTTP observation. Probes 1/2 failed because the test-support default
approval map uses an unsupported `reject` variant; the synthetic workflow was
corrected to explicit `never`. Probe 3 passed before adding the stop receipt.
No installed provider/configuration or real Jira state changed. This proves the
staged native connector route, not live rollout/readback or full Jira lifecycle.
Independent evidence review found no blocker for that bounded transport claim;
the HTTP fixture acknowledges a PUT but does not apply/read back real Jira state.
Actual permissions, concurrent-label behavior and journal restart completion are
not claimed from this probe. Those distinctions remain explicit acceptance gates.

Lifecycle 13 reported cumulative writer-thread usage of 180,396 tokens (179,843
input, 148,992 cached input, 553 output) and verifier usage of 51,474 tokens
(51,022 input, 24,320 cached input, 452 output). Totals include repeated input
within each thread; do not sum interim usage notifications or estimate dollars.

Affected regression files passed 94/0 (seed 59894, 69.8 seconds). Specs, strict
Credo and whitespace checks passed. Independent raw lifecycle review recomputed
both controller receipt/binding hashes and accepted the bounded evidence.

The unchanged full quality gate remains. One
`SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all` is running, seed 897146, exec
session 46496. Follow the same process; do not start a duplicate. Latest terminal
full coverage is still 98.54%
against required 100%; it has not been remeasured after these changes. Production
V1 stays disabled and Slice 3 is not declared complete.

## Native CI reader qualification

Model-free GitLab probe 4 passed 1/0, seed 386205, 7.2 seconds. It launches the
existing guarded v3 provider with synthetic credentials and a local fixture, then
uses the real owned AppServer read session from an outside-source controller cwd
and `TicketWorkerRunner.collect_ci` through its normal schema/decoding/binding path.

The four-tool catalog is read-only. Exact GET scope covers MR 42/project 33747681,
pipeline 99, job pages 1 and 2, the exact merge commit, and the final MR reread.
Real disposable Git target/candidate/merge objects supply the SHAs. PASS binds the
candidate as the merge's second parent and one successful non-allow-failure Bazel
job. Nonempty page 2 rejects with `ci_jobs_limit_or_shape`; substituted source
parent rejects with `ci_merge_source_unproven`. The unchanged RunLedger assertion
and owned-port stop both pass. Raw artifacts: `gitlab-native-4-*` in the same
scratch evidence directory. Independent evidence review accepted this bounded claim.

Earlier attempts remain spent: probe 1 discovered that GITLAB_TOOLS is additive
to enabled toolsets, not an exclusive filter. A process-local denial filter now
restricts the test to four readers. Probes 2/3 exposed a fixture assertion comparing
RunLedger.update's wrapper to a get row and fixture shutdown ordering. Those test
errors were corrected; no product gates or provider package were changed.

This proves native collection/typed-parent/pagination behavior with synthetic CI,
not actual CI success, live GitLab permissions or installed production configuration.
The harness has no run_turn invocation, but does not export a complete native RPC
trace or independent descendant-process shutdown proof. Do not broaden the claim.
