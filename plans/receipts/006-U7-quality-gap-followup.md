# U7 quality-gap follow-up

Slice 3 remains incomplete and production V1 remains disabled. No native probe,
external mutation, deployment, commit, or push was performed in this packet.

## Changes and evidence

- Removed six fallback branches proven unreachable by Dialyzer's inferred callee
  return types: Jira operation/finalization reservation reads, Jira journal lookup,
  MR request lookup, parent guard error propagation, and push-release propagation.
  All reachable success and rejection branches remain intact. Independent read-only
  review accepted this change.
- Added negative journal tests for invalid stage/checkout/comment boundaries,
  malformed readbacks, and hash-consistent malformed stored JSON. Added parent-guard
  cases for malformed timestamps and metadata, asserting the request remains pending.
- Independent review found that hash-consistent empty/truncated effect lists could
  previously be claimed. Journal claim/reconciliation now reconstructs and compares
  the exact operation-specific two-effect pair. Historical release-fence proof uses
  the same check against its immutable binding. Tests reject empty, truncated,
  reordered and altered-label pairs without claims or phase advancement. Independent
  read-only review accepted the fix.

## Completed checks

- Targeted lifecycle wrong-stage/missing-run plus journal group: 9 tests, zero
  failures (seed 807398).
- Expanded journal group: 10 tests, zero failures (seed 15858).
- Review-ready finalization/recovery lifecycle: 1 test, zero failures, 122 seconds
  (seed 302821; before the later effect-pair validation change).
- Jira operation, parent guard and workspace-access group: 30 tests, zero failures
  (seed 12041; before the later effect-pair validation change).
- Expanded parent guard group: 5 tests, zero failures (seed 758101).
- Effect-pair regression plus Jira operation group: 19 tests, zero failures
  (seed 599001).
- Journal and Desktop request/fence regression group: 26 tests, zero failures
  (seed 482156), after the historical release-proof validation change.
- Parent evidence group: 11 tests, zero failures (seed 481454). Added directly
  exercised, correctly hashed malformed request envelopes, unsupported target/action,
  malformed secondary items, and fractional-second claim ordering. The first run
  exposed a test setup error (modified payload without updating its hash); corrected
  the synthetic envelope rather than bypassing production payload validation.
- Checkout Git-failure receipt case: 1 test, zero failures (seed 936030). Expanded
  assertions reject nonbinary/oversized receipts, nonterminal or extra-field
  termination records, mismatched output hashes, invalid base64 and invalid child PID.
- MR wrong-stage/incomplete-authority rejection case: 1 test, zero failures
  (seed 70756), with unchanged run, request, reservation and claim tables.
- MR adoption plus checkout failure checks: 2 tests, zero failures (seed 128380).
  The original failed MR request is rejected without connector access or run changes;
  noncanonical/invalid project pins and out-of-range termination values are rejected.
- Push ownership/restart case: 1 test, zero failures (seed 361690), including bounded
  optional SSH-agent forwarding and restoration of the original test environment.
- Dialyzer after the effect-pair change: zero errors, zero skipped warnings.
- Public specs, strict Credo, full formatting check and git diff whitespace check
  passed after the source changes.

These checks do not establish updated full-suite coverage. The previous full gate
remains a failure at 97.93% against 100%; actual native permission acceptance and
staged Jira adapter qualification still remain outstanding.

## Updated full gate in progress

Started one `SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all` run after the focused
follow-ups. The live GitLab/Jira/GitHub/Asana E2E switches were confirmed unset.
Build, full formatting, public specs and strict Credo passed. Coverage is running
with seed 45700 under exec session 52590. Follow that same session; a timeout is
not permission to restart it. Source and tests are frozen until terminal output.
No coverage or full-gate pass is claimed yet. Existing dependency security
advisories were reported by setup; no dependency versions were changed.

The same run subsequently finished with exit 2: 1295 tests, zero failures, six
intentional live skips, 1454.6 seconds; coverage 98.54% against 100%. Build, format,
specs and lint passed. Dialyzer was not reached by `make all` (its separate passing
run is recorded above). Coverage increased from 97.93%, but this is still a failed
full gate, not Slice 3 acceptance. The generated `cover/*.html` reports now reflect
this frozen source, superseding the earlier report for further gap selection.

Post-report bounded simplification: independent pre-change review established that
`TicketParentGuard.generation/1` cannot receive nonbinary metadata after the preceding
broker check, and `TicketParentEvidence.matching_items/3` cannot receive a malformed
turn after complete-history validation. Removed only those two unreachable private
fallbacks; public functions/signatures and reachable rejection branches are unchanged.
Before-change parent tests passed 16/0 (seed 318130). After-change parent plus journal
tests passed 26/0 (seed 603957). Expanded the existing malformed-journal test to reject
empty comment bodies and an invalid numeric transition ID despite consistent hashes,
without advancing or claiming the operation. This is not updated full-suite coverage.

Next reachable lifecycle gap: implemented a synthetic no-edit writer outcome in the
existing shared WorkerServer fixture and one lifecycle test proving a resumed writer's
COMPLETE with no changed paths preserves the existing candidate, creates no additional
commit, advances to VERIFYING and releases source ownership. Requirement: U7 exact
candidate handoff across resumed writer passes. The existing two-edit lifecycle did not
exercise this distinct completion path; its process/Git/ledger fixture is reused rather
than adding another harness. Extended the existing ordinary-admission test to reject
non-map runs and absent snapshot JSON before any parent/request writes. Both selected
tests passed (seed 113865, 2/0, 15.3 seconds). The first no-edit test run caught a fixture
setup error: the default fixture already had a candidate, so the setup was corrected to
establish a first real candidate before its resumed no-edit pass. No product-source
change was needed for this behavior.

Initial-Jira recovery gap: added one existing-fixture test where a competing writer
consumes capacity after the label mutation. The final admission transaction rolls
back, preserving the original ADMITTING_WRITER row and unreleased maintenance owner
while the journal retains completed external evidence. Once capacity is restored,
the same operation admits without another transition/label call, task creation or
generation change. This exercises U7 admission capacity and crash/retry separation;
earlier tests covered rejection before effects, not after effects. Single case passed
1/0 (seed 316865). Extended existing no-mutation tests to reject absent controller
cwd and a fresh status regression after an already-In-Dev effect was recorded; a
nil transition ID cannot be issued or claimed. Full initial-Jira file passed 10/0
(seed 840694, 25.5 seconds). Strict Credo, full formatting and whitespace checks pass.
No product-source changes, live calls or full-gate rerun in this packet.

Parent public-boundary checks: extended existing tests to prove omitted options
keep followup issuance disabled, invalid thread IDs fail before history access,
and successful text-valued native MCP results remain representable in the bounded
acknowledgement receipt. No new test process or native call was introduced. Parent
guard/evidence files passed 16/0 (seed 949089, 0.6 seconds).

Checkout transport failure: extended the existing missing-terminal-receipt case
with a startup callback exception before helper input is sent. The public executor
returns transport-unproven; reconciliation retains the same ownership nonce and
never creates/adopts a checkout or another creation attempt. Requirement: U7 failed
initial checkout transport must not be mistaken for safe replay/admission. This
reuses the existing temporary Git/ledger fixture. Passed 1/0 (seed 439624, 0.9 seconds).
No product-source changes or full-gate rerun; latest whole coverage remains 98.54%.

Frozen changed-file hashes:

```text
9b8b70509bd1a8bfade25afe7db30d168061ae457139a6caeffdb53d3f53bbef ticket_jira_journal.ex
2b0cf1ef93d2fcd227f2ab443654f9b50a2845573d3672b6e99e6c9c302c30c3 ticket_jira_finalization.ex
cfe33def368cfa44e4d1a9a11e435e17735e45e5ae68e6f9e89c4a4efceb2fc2 factory_ticket_worker_lifecycle_test.exs
e4513cdfc93d2b25f1563a7889863e22bc87544b5b359dc100eb945a40240f45 factory_ticket_jira_journal_test.exs
76bac52e2766799f415cb5519a6c059265646c54a2c8625e8f49942189b3b8d1 factory_ticket_parent_evidence_test.exs
3b2992d91771e339e8b7533da181f3bbb0db5bab2ee2daac1e14b97fbeed88e1 factory_ticket_parent_guard_test.exs
defae7a295b61abf5d46a6b3ea02e4273d26fda76954743fcc7800729b084175 factory_ticket_checkout_test.exs
```

### October 6: public stdin and default-disabled issuance boundaries

Reviewed the existing full report rather than rerunning the whole suite. Many
reported private transport branches remain unqualified; the earlier report is
stale for subsequent edits and is not evidence of a new full-gate pass.

- Added one in-process handshake test using a process-local standard Erlang IO
  fixture for unavailable and nonresponding stdin. Public `observe/3` must return
  the precise error, and monitoring proves its owned reader terminates. The group
  leader is restored and fixture device stopped in `after`. The existing real CLI
  stdin test remains. Whole handshake file passed 5/0 (seed 841782, 1.5 seconds).
  Requirement: U7 owner-observation failures cannot authorize issuance or leave an
  unbounded reader. The previous real CLI coverage ran in a separate VM and did
  not exercise these branches in the parent coverage process. No model/native call.
- Extended the existing parent-admission fixture to call followup formatting with
  omitted policy options, assert `ticket_chat_runtime_not_integrated`, and compare
  the exact pending request before its existing explicitly authorized success case.
  Whole admission file passed 6/0 (seed 336629, 0.7 seconds). Requirement: U7 parent
  issuance must remain disabled by default; rejection must preserve durable state.
- Independent read-only review accepted both test additions. Formatting, strict
  Credo and whitespace checks passed. No product-source or policy changes occurred.

Current test hashes for these additions:

```text
270f0c884ce0d37fb9e2e38892dcb154005aac2af60aed7d339474443b007a4a factory_desktop_mr_handshake_test.exs
ca09fe1fa71baf305953e19e16ad70bad09567fe488d494780582730721e280f factory_ticket_parent_admission_test.exs
```

Native allowance remains exhausted (three spent allocation markers). A new approval
request is pending; no further call was made. Slice 3 is not accepted and production
V1 remains disabled. Native edit/adoption, permission evidence and full-gate
acceptance still cannot be replaced by these offline boundary tests.

### October 6: native acceptance and refreshed quality evidence

The subsequent user authorization removed the per-call Luna approval requirement.
Native source/resume/fresh-review and model-free provider checks are recorded in
`006-U7-native-lifecycle-acceptance.md`; no real ticket, deployment, installed
provider switch or production enablement occurred. The user clarified that one
main interaction chat plus controller-launched specialist workers reporting back
is acceptable. Native child nesting is not an additional acceptance prerequisite.

The refreshed frozen full gate (seed 897146, terminal session 46496) finished with
1,300 tests, four file-tool timing failures, six intentional skips, 2,100.8 seconds,
98.93% coverage against unchanged 100%. Build, format, public specs and strict
Credo passed; Dialyzer was not reached by that gate. No passing aggregate is claimed.
Fresh cover reports replace the preceding 98.54% inventory.

After terminal output, only the process-heavy file-tool test module was made
synchronous. Its seven selected cases, including the four failures, pass 7/0,
seed 877722, 94.0 seconds, with six-second/native and 60-second/test guards intact.
See `006-U7-file-tool-timing.md` for the measured contention evidence and limits.

Remaining real public-boundary assertions were added to existing fixtures:
missing observed-base inputs and exact named-ref success; missing persisted base
refuses writer admission without ownership/evidence changes, with public base
restoration; malformed delivery reservation refuses admission; a real owned push
helper's startup-publication callback failure preserves the exact original uncertain
intent, denies re-claim and leaves the remote branch absent. No product source
change, private port injection or test-only transport bypass was introduced.

- Base/admission cases: 2/0, seed 425877, 3.9 seconds.
- Ordinary tick/delivery gates: 1/0, seed 412155, 43.0 seconds.
- Push restart/publication failure: 1/0, seed 432650, 32.5 seconds.
- Independent frozen test review accepted the substantive safety assertions.
- Specs, strict Credo, formatting and whitespace checks pass.

Outer fixed-transport rescue/deadline/frame guards remain intact. Their uncovered
lines are not established dead by Dialyzer and must not be removed to make coverage
green. Focused test passes are not a new full-gate measurement. Slice 3 stays open.

Final static follow-up after those assertions: separate current Dialyzer passed
with zero errors/skips in 49.64 seconds. Strict Credo caught one overlong assertion
line in the callback test; its identical callback was assigned to a named variable,
and formatting/strict Credo/whitespace checks subsequently passed.

One additional safety case drives an actual schema-valid BLOCKED worker result
through the existing shared fake server and public candidate-adoption boundary.
It proves `ticket_writer_blocked`, exact post-launch run equality, retained
RESULT_RECORDED evidence, no controller checks, no commit and original bytes/HEAD.
Passed 1/0, seed 499925, 9.9 seconds; independent frozen review accepted it.
Initial seed 758622 failed only because the baseline preceded legal launch model/
task bookkeeping; capture now occurs after launch and before adoption, retaining
the full-map equality assertion. All declared producer fields are supplied.

Read-only exploration identified incomplete blocked-result disposition in V1:
the safe refusal currently leaves an active writing stage and repeatedly deferred
unconsumed result, with no bound open question. Plan006 U8 now explicitly requires
a durable honest blocker/next action, safe dirty ownership and explicit resume
admission. This test proves the candidate safety boundary, not that future
question handling is implemented. No broad architecture or production change.
