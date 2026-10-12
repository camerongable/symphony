# Local quality repairs while native acceptance approval is pending

Status: bounded changes independently ACCEPTED. Whole U7c/Slice 3/native acceptance
and the unchanged full repository quality gate remain incomplete.

## Controller transport

Added one malformed-frame test using the actual current-process-owned port and
recorded helper PID. A truncated length-prefixed frame plus successful exit must
remain unproven/RUNNING, with no completed receipt or source reservation release.
Source remains unchanged and the owned helper is independently absent afterward.
Injection confirmation is asserted outside the rescued callback; this repairs the
false-positive path identified by independent review.

The existing stopped-helper case was reused, not duplicated. Two targeted tests
passed (seed 768295, 32.4 seconds). The repaired malformed-frame case passed with
exported coverage (seed 985397, three seconds); decoder fallback line 95 records
one actual call. Independent repaired-test review ACCEPTED.

The outer transport timeout at WorkerCheckIO line 90 still records zero calls.
The stopped-helper case exercised the other-port-message failure branch instead.
Do not call this timeout coverage complete or add runtime timeout knobs solely to
satisfy a metric. Full coverage remains a hold.

## Worker admission and dead private branches

Added characterization of missing/malformed Jira dispatch fields and decoded
non-object authorization, and of unsupported stored-role rejection before schema
or adoption. The latter preserves task/run/evidence/checks/reservation state.

Removed only the unreachable private adoption_schema/adoption_role fallback
clauses: admitted_stage rejects all other roles before either helper and the task
map retains that checked role. All public definitions remain byte-for-byte
unchanged. No public API or supported-role behavior changed.

- Before removal: runner suite 20 tests, zero failures, seed 917332, 27.6 seconds.
- After removal: same suite 20 tests, zero failures, seed 816307, 31.2 seconds;
  exported coverage retained separately.
- Independent unsupported-role rerun: one test, zero failures, seed 552827,
  1.8 seconds. Bounded cleanup review ACCEPTED.
- Public specs, whole strict lint, formatting and whitespace checks pass.

## Boundary

Follow-up: the remaining test line-length finding was repaired without changing
behavior. Fresh whole strict lint, format-check and whitespace checks pass. Native
test approval is still unanswered; the current integration checkpoint cannot
proceed to real parent creation/handoff without that explicit authorization.

No native model turns, chat creation, remote action, production configuration,
commit, push or deployment occurred. Current host-root/native broker acceptance
still awaits the previously requested three-turn/ten-minute explicit budget.
Generated narrow coverdata is diagnostic evidence only, not a full-gate report.
The complete objective remains unchanged.
