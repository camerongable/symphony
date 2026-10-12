# U11 native checkpoint — October 10, 2026

Status: partial acceptance, not Slice 5 completion. Synthetic fixture only;
no real-ticket, remote push, Jira/GitLab or deployment action.

## Passed

- Actual human opened and answered parent `01a12788-1be6-7cb2-b364-1c27c481d38a`.
  `Q-U11-chat-access` is ANSWERED with JSON boolean true. The original native
  input and rejected string-value proposal remain byte-identical. The derived
  recovery and replay have exactly one question effect and event.
- Genuine false CREATE result remains FAILED. One deterministic guarded
  recovery FOLLOWUP checked its own empty attachment inventory and exact saved
  context locator. Readiness became PARENT_READY in the same projectless chat;
  the original CREATE/chat proof was retained.
- Controller admitted one checkout, adopted a Luna read-only planner, restarted,
  admitted a restricted FILE_SOURCE writer and committed candidate
  `6bbc2c5a241b08d097d3d64f314686e45e64adbd`. The writer reused its worker thread
  for a second readback pass. No additional source checkout was created.
- Fresh read-only verifier PASS matches that candidate and supplied base
  `790903a4fa45a3df4a2db66950b4fcbc48e85f81`. Controller adopted the verdict and
  reached PUSHING; the harness intentionally forbids delivery transports.
- Independent Git/raw-byte checks show a clean feature branch, exactly one
  added line in fixture.txt and file SHA256
  `942ac1e648f96ef96737f48de57350fe484b784cd60bfee01da550f715d2e03b`.
- A parent presentation refreshed context and displayed worker/verifier progress.

## Failed final presentation acceptance

Presentation 14 repeatedly refreshed and summarized without ending. A scoped
controller stop instruction ended the owned turn
`01a128d5-fc3e-7271-a22c-69938a56b61f` after 239312 ms with acknowledged=false.
Owning Desktop readback confirmed idle. Its request is RECONCILE_REQUIRED with
`NATIVE_PRESENTATION_REFRESH_LOOP_STOPPED`; delivery and source evidence were
unchanged. Do not reinterpret the stop result as success or blindly resend.

The reproduction also showed equivalent JSON values with different serialized
bytes, yielding unnecessary presentation fingerprints. Canonical map-key hashing
now preserves scalar types, list order and map/list distinctions. Independent
process checks agree on the fingerprint and coalesce unchanged data. The
one-refresh/one-summary prompt correction is statically tested, not native-proven.

Bounded trace review found one incoming presentation followed by repeated
model-issued refresh calls. It found no new mid-turn human message or automatic
tool-hook trigger. The stop steer was the only later injected action. Model-level
self-repetition is the best-supported diagnosis; the precise internal trigger
is unknown. A pending feature state is not itself a failed presentation, and
the new instruction must not imply that it is.

## Verification and scope

Final recovery packet: 122 focused tests and 71 scheduler tests passed, with
independent frozen reviews. Final outbox correction: seven focused tests passed.
Public specs check and formatting passed after the final prompt-only correction.
Its frozen instruction review also passed, without a native recovery claim.
The earlier 1540-test/98.67% full gate predates these edits and must not
be presented as acceptance of current source. No additional full suite ran here.

Ten distinct native turns completed (six parent, four worker). Eleven sends plus
worker attempts were counted conservatively, including the stop steer within an
existing turn. The twelve-turn ceiling was not reset across controller restarts.
No native turn is still running. Implementation-agent work is separate from
these native acceptance counts; provider token totals are not prices or credits.

The temporary driver had two non-product errors: an incomplete Scheduler.tick
context and tuple serialization in fake-Jira receipts. The driver now exercises
the existing run through Scheduler.ticket_step and restores recorded fake-Jira
state. Those crashes are not production scheduler/recovery acceptance evidence.

## Evidence

Root: `/private/tmp/symphony-u11-native.SOtC1Z`.

- `human-answer-recovered-receipt.json`
- `bootstrap-recovery-accepted.json`
- `u11-coordinator-evidence-1791685835799631023-6466.json`
- `summary-completion-1791686145256805083.json`
- `stopped-presentation-receipt.json`
- `recovery-native-1791686733635344209.json`
- Recovery source freeze `/private/tmp/u11-recovery-final.CcSP1U`.
- Final bounded outbox source freeze `/private/tmp/u11-summary-bounded.eixnQ0`;
  source SHA256 `3090b982797ed12c9f59f07c65d8ca148f4b2afa6e6b30f43706b97fb3184835`.

Remaining: bounded presentation completion and reconciliation; native amendment/
direct-chat rework acceptance not exercised by the access-only answer; refreshed
frozen quality gate; then separately authorized disabled deployment and pilot.
Historical native proof and unexercised scenarios remain distinct.
