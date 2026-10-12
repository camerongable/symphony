# U7 offline provider qualification and restored build

## Scope and results

October 6 continuation after exhausting the authorized native model-call budget.
No further native call, real ticket, live Jira/GitLab request, installed-provider
modification, deployment or production enablement occurred.

- `mise exec -- mix compile --force`: exit 0, rebuilding all 126 local source
  modules. This cleared the missing `Router.init/1` error in the restored dev build.
- `mise exec -- mix specs.check`: exit 0 in the normal development environment.
- Staged Jira provider's existing unit checks: 6 passed.
- Added two actual stdio protocol checks with MCP `ClientSession`, the installed
  provider interpreter and an ephemeral loopback HTTP fixture. Explicit synthetic
  credentials, scratch cwd, disabled proxies/update checks and tool filters isolate
  them from the user's Jira account. Read-only mode advertises no mutation tool;
  attempted calls fail without HTTP. Writable mode advertises the exact connector
  schema, sends one atomic label delta, returns the bounded acknowledgement, and
  rejects an unrelated-label delta without another HTTP request.
- Combined provider group: 8 passed in 3.462 seconds. The intermediate run failed
  on a test configuration value: FastMCP accepts update-check mode `off`, not
  boolean `false`. Corrected only the subprocess setting, then reran successfully.
- Independent adversarial review accepted the local protocol qualification and
  fixture isolation. This is not native Codex session/production qualification.

## Public-boundary checks

Extended existing fixtures, without another harness or new product behavior:

1. Malformed CI jobs (`nil`/string) are rejected as `invalid_ci_snapshots` before
   lower-level job binding; run remains in CI_WAITING. The initial assertion used
   the lower-level error and failed, revealing the earlier public guard. Corrected
   the expectation rather than bypassing validation or adding a private test seam.
2. Wrong-request feedback completion returns `feedback_claim_mismatch`, preserving
   the exact claimed row. Its legitimate owner can still finish successfully.
3. Positive integer and string GitLab project pins yield the exact same MR binding.

Selected three-case run seed 160390: MR binding and feedback cases passed; the CI
expectation failed as described. Corrected full CI/feedback groups seed 842869:
26 passed, zero failures, 2.5 seconds. No product bug is claimed for these checks.
Independent review accepted the tests and determined the non-map private
`ControllerCi.job_bound?/2` fallback is unreachable behind `containers?/2`.

Removed only that private fallback after the green baseline and independent
reachability review. Public `bind/3` signatures and early malformed-data rejection
are unchanged. The same CI/feedback groups passed afterward: seed 337908, 26/0,
2.8 seconds. Dev specs and Dialyzer passed before and after (zero errors/skips);
full formatting, strict Credo and diff checks passed. This is behavior-preserving
dead-code removal, not a permission-policy change or coverage-threshold adjustment.

## Remaining acceptance

Native permission/edit/adoption evidence remains unproven and cannot be replaced
by these provider tests. Another model call needs explicit approval. The unchanged
full gate still has latest measured coverage 98.54%; no new full-gate pass is
claimed. Production V1 stays disabled, Required: yes stays fenced, and Slice 3 is
not complete. Slices 4 and 5 remain later implementation/acceptance work.
