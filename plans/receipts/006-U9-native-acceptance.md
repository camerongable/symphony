# U9 native acceptance continuation

User authorized at most 12 GPT-6 Luna parent/worker/broker turns and 30 minutes
active runtime, synthetic fixtures only. Real Jira/GitLab, production, commit,
push and deployment remain out of scope. The automatic goal is still blocked
in the app; its replacement attempt failed with an unfinished-goal error.

## Runtime qualification

Installed CLI is `0.162.0-alpha.2`; the prior strict `0.160.0` identity pin
rejected it. Minimal candidate retains both exact versions, not a broad range.
Frozen baseline/candidate:
`/private/tmp/symphony-u9-runtime-version-{baseline,candidate}-20261008/`.
AppServer SHA `3fe091d3d745c34d1b64f8218b20aa09b99d0eb812ba51fbd900de09f6986f8c`;
test SHA `c6a05ff335a0861c5004a3da27b302c81945b7aeb7643f3c259ad66874d47e27`.
Finite source review PASS. Focused identity/probe tests passed 2/0, 74 excluded,
4.9 seconds; unchanged model-free sandbox driver passed 1/0, 3.0 seconds.
Root inspected actual denied write/network, isolated Git and controlled exit
artifacts at `/private/tmp/symphony-u7-native-capability.CXdv7U/`, prefix
`sandbox-defaults-runtime-version-0162-20261008-`. No inference occurred there.

## Synthetic request and native CREATE

v1 setup had an incorrect scratch-root cwd. Its local claim was never followed
by CREATE and remains preserved; it is not native acceptance or a retry target.
Fresh v2 is `/private/tmp/symphony-u9-native-acceptance-setup-v2-019fa5b7/`.
Its `broker-WORKFLOW.md` is the policy-valid issuance route; `runtime-WORKFLOW.md`
is disabled/probe-only, and `ticket-WORKFLOW.md` is read-only context. One mistaken
probe-workflow claim rejected before mutation; root read back PENDING/null claim.
Then exact broker-workflow claim succeeded before the single actual CREATE.

Request: `TC-4c1eaccdb8b24fc17c17d0295842cce07a1f855f495daddce292be242a036b91:g1:create`.
Generated args were passed unchanged: projectless, GPT-6 Luna, low reasoning.
Created chat `01a11d08-d0c4-7290-aba5-4b96abd91f07`, host `local`, title
`PPL-456 · Ticket`; cwd
`/Users/cgable/Documents/Codex/2026-10-08/factory-ticket-4c1eaccdb8b24fc17c17`.
Supported owning readback observed exact delegation/source/request envelope,
completed `list_artifacts {}`, context refresh exit 0 for the exact synthetic run,
and final `{"acknowledged":true}`. Turn
`01a11d08-d287-76e3-86d9-c5730c9bd604` completed in 16913ms.

Official full-native-history `read-ticket-turn` rejected with
`parent_native_invocation_not_observed`. Binding/completion was not forced;
request remains CREATE_UNCERTAIN. One bounded model-free diagnostic captures
actual native item shapes to identify a parser defect or unsupported capability.
Do not CREATE/send again or infer an empty attachment list from a call name.

## Remaining

Resolve exact native readback before binding this same parent. Then conduct
actual source-active and two busy-parent human-input checks under the unchanged
budget; source/owner/queued-input receipts must be real, not fabricated fixture
histories. No human test messages requested yet. Native CREATE turn count is 1/12;
conservative active-runtime charge is 3/30 minutes. U9 local 88/0 and prior
23-file frozen source acceptance remain separate from native completion.

## Readback recovered without another turn

Actual full native history contains the exact CREATE functionCallOutput with
XML-text-escaped `>` in the prompt. Wrapper comparison differed by three bytes,
not by broker/request/target identity. Minimal adapter admits exact raw and
canonical text-escaped whole wrappers; no generic decoding or partial matching.
Frozen `/private/tmp/symphony-ticket-parent-xml-escape-candidate-20261008/`:
parser `90e514ce6fca436589336cfe708bcca9d62113441b5aa347e0ddf89f63060252`;
test `47d2e0bd52fa347938f9f2e740b055d728edbc3d815baf98ffb4998054d5eb27`.
Discriminating RED2 produced native_invocation_not_observed (1/1, 0.7 seconds);
GREEN group passed raw/escaped/identity/duplicate checks (4/0, 8 excluded,
1.5 seconds). First RED attempt was only a fixture assertion error, not product
evidence. Root read both correct terminal logs; independent frozen review PASS.

Official read-ticket-turn retry observed completed exact history and returned
the machine completion unchanged. Root independently read the parent's actual
completed list_artifacts content `{"artifacts":[]}` from that same native history.
Typed record-ticket-thread succeeded, then complete recorded SUCCEEDED with
the original thread/turn and observed tool list. No source effect, rebind,
replacement chat or repeated CREATE was used. Native readback SHA
`528e1dd7618a3b1ac462d497dbd5b2601bb479b516d6132c8acb057b9f410bff`;
invocation SHA `462d28281864948470a531ef43c8736facec0a380640a0c35078f1f6bb94a775`.

User is now asked to open this single test chat and confirm it is accessible,
without sending messages yet. Non-paid source-active/busy test coordination is
being prepared using existing native-worker fixtures and this bound parent.
The human message tests remain unperformed; budget is still 1/12 turns and
3/30 conservatively charged active-runtime minutes.

## User-facing access confirmed

User opened the bound parent and reported, "It looks normal to me."
This accepts chat accessibility only, not source-active or busy-input handling.
Before those timed checks, the normal parent instructions require a bounded
correction: their global staging prohibition conflicts with the independently
collected same-turn staging receipt required for accepting a direct human answer.
The sole writer is preparing a focused regression and minimal instruction fix;
parallel read-only investigation is checking live hold/queue evidence. No further
native turn or production mutation has been issued.

Focused instruction checks passed 3/0 in 1.1 seconds (seed 12723), with an
independent frozen review accepting the per-human-turn refresh and PENDING-only
authority boundary. Artifact: `/private/tmp/symphony-u9-parent-stage-instructions-final-20261008/`.
Before native issuance, root identified one remaining operational instruction
gap: the context exposes answer artifacts but not the answer operation schema.
The bounded answer schema/detail-read guidance is being added rather than asking
the parent to guess. This is not native acceptance and uses no additional turn.

The FILE_SOURCE executor intentionally ignores overrides; no product permission
change is justified for testing. Read-only review accepts a scratch adapter hold
after the original `session_started` callback binds the real native turn, capped
at 45 seconds. Native in-progress/pending-call, owner, lease and human timestamps
still must be observed independently. The adapter is being prepared separately;
it has not been launched.

Final single-answer instruction candidate passed 3/0, 12 excluded, 1.2 seconds,
seed 337206; root read its terminal log and compared both product files to the
immutable `/private/tmp/symphony-u9-parent-stage-instructions-v3-20261008/` copy.
Independent protocol review PASS for single-answer qualification. Bound details
reads resolve declared answer values; exact answer operations are supplied without
caller question digests. This does not qualify broader rework/refinement prompt
guidance or actual native behavior. Budget remains 1/12 turns and 3/30 minutes.

## Native continuation: actual human replies, not yet accepted

Normal Scheduler/TicketCheckout admission created the synthetic source checkout
under the configured v2 workspace root, clean at
`c5b3480827d6fa212a4d01c9922d726331e9f800`. The planner attempt then failed
before native inference with `invalid_workspace_cwd/outside_workspace_root`:
runtime-WORKFLOW had omitted workspace.root. Root corrected that configuration;
the existing STALE task, RECONCILE_REQUIRED evidence and REVIEW reservation remain
protected. No stopped-worker receipt, output or recovery result was fabricated.

Presentation 3 completed in the existing parent. A bounded, independently reviewed
adapter accepts prose followed by one exact terminal acknowledgement object in
the unique final-answer item. Official readback recovered the original turn
`01a11d6d-8d29-78a1-a910-4a4230a8e78e`; typed record/complete made request 3
SUCCEEDED without another send. Frozen evidence:
`/private/tmp/symphony-u9-parent-completion-final-20261008/`, focused 3/0,
16 excluded, 1.3 seconds, seed 116263; finite adversarial review PASS.

Presentation 4 was claimed after the parent had become idle, but no send occurred.
Its FOLLOWUP_UNCERTAIN state is preserved. Post-claim issuance refused to generate
arguments; root did not bypass that refusal or blindly resend.

A real read-only parent coordination turn ran from Unix second 1791495868 to
1791495918. The first human reply began at 1791495963, after that wait completed.
Therefore this is not a busy-input timing PASS. The two actual completed reply
turns are `01a11d7b-04ae-7d22-a2fb-12bd50201404` and
`01a11d7b-d4b9-7cd1-9829-b7d7f9bdaabd`. Each read current context and staged
one pending answer; the first recovered from a failed staging invocation before
successfully staging once. Queue preservation is not inferred from sequential
turn timing.

Actual raw messages are single-backtick-wrapped `Answer Q-U9N-parent-busy-N-v2:
yes` followed by LF; staged bodies are unwrapped. Two real AppServer collections
returned the same two OBSERVED input keys and no duplicates. They are not accepted
or consumed yet. A two-file answer-only formatting adapter is being tested; it
must preserve raw body/hash/client identity/readback, require the same completed
staging receipt, and leave rework/amendment parsing strict.

Independent native history is retained in
`/private/tmp/symphony-u9-native-acceptance-setup-v2-019fa5b7/live-parent-two-human-replies.json`;
collector receipts are `coordinator-1791496443938790747.json` and
`coordinator-1791496444246606048.json` in that same scratch directory.
Actual paid native model turns: 5 (CREATE, presentation 3, coordination, two human
replies). Planner pre-start failure incurred no native inference; presentation 4
was not sent. Conservative runtime charge remains 8/30 minutes, not a measured
model-runtime claim. No real Jira/GitLab, production or new source-writing turn.

## Existing human replies accepted and applied without resending

Answer-only formatting adapter v2 is frozen at
`/private/tmp/symphony-u9-answer-wrapper-final-v2-20261008/`.
Commands SHA `ff0122841f4ce152f57663d19f14c56c874f2a673db83e5d83ea441ff4995f1a`;
tests SHA `962c3a73aa7082555334376da7b52c0f94e6201db577cd3cad27d234fa6b8fac`.
Focused six checks passed 6/0, 49 excluded, 1.1 seconds, seed 832365. Independent
frozen review PASS after a lone-backtick slicing guard corrected its one finding.
The fallback requires one answer operation, exact canonical whole-line text and
the same completed staging receipt; raw input and nonanswer authority stay strict.

Root compared live/frozen files, compiled and restarted only the idle synthetic
coordinator. Actual AppServer collection twice returned both commands ACCEPTED;
receipts `coordinator-1791497848402192708.json` and
`coordinator-1791497848759105042.json`. Supported apply_accepted twice returned both
APPLIED; each bound question is ANSWERED with true. Application receipts:
`coordinator-1791497859080100958.json` and
`coordinator-1791497859082405500.json`. Root independent SQL readback confirmed two
commands/two inputs, original raw rows byte-identical to the pre-collection
snapshot, and run still PLANNING, candidate null, implementation iteration 0.
No additional inference, new user message, source change or external effect.
The idle scratch coordinator was stopped cleanly after readback.

This proves actual direct-input acceptance/application and replay for these two
messages. It does not prove busy queue timing, source-active input, deferred
presentation or recovery of the fenced pre-start planner. Those remain open.

## Busy retry: timing proven, same-turn collector gap reproduced

User confirmed readiness and sent two separate direct messages after root's
SEND NOW cue. Root issued one read-only Luna/low coordination turn with a
120-second sleep; owning Desktop readback confirmed active before the cue.
Turn `01a11da0-3c3a-7d53-b7dc-69311c71fec2` later completed from Unix second
1791498402 to 1791498631. Owning observation captured both top-level user items
while that same turn was inProgress and the sleep had not completed:
`owning-busy-retry-human-observation.json` in the v2 scratch directory.
Final full native history is `live-busy-retry-completed.json`.

Direct messages have distinct native item/client identities:
`01a11da0-df24-7d60-911e-99e8c5bc8186` /
`1403aa30-d053-48aa-8cdb-345df05f164f`, and
`01a11da0-df28-7173-8724-576b103c58da` /
`84034e8c-5684-4428-be88-90ddbb2afa04`.
Bodies answer `Q-U9N-busy-retry-1-v3` and `Q-U9N-busy-retry-2-v3` yes.
Both commands are PENDING and questions OPEN. The chat recovered its malformed
encoded payload attempts and successfully staged both, but this is not controller
acceptance or application.

Actual collect receipt `coordinator-1791498666400075248.json` returned only the
two old APPLIED inputs; independent SQL still shows exactly two old inputs.
Current direct_input requires exactly one user item and vetoes any turn with a
delegation item. The actual native steering shape has two direct users in the
same turn as the initial coordination delegation, so neither is observed.
Independent item-level provenance investigation is in progress. Do not widen
nested/tool text into human authority, fabricate new inputs, or silently dedupe.

The second successful staging call (`exec-97920864-5361-427a-b38b-9bce009b2ced`)
uses a Python payload-encoding assignment plus a newline stage invocation;
strict staging invocation recognition may separately reject this shell wrapper.
Its stdout alone is not authority. That compatibility boundary is being reviewed
separately from the per-item collector change; neither repair is implemented yet.

Model-free separate AppServer queue snapshots returned notLoaded/empty and are
not treated as owning Desktop queue proof. The owning active observation with
both real direct user items proves arrival during the busy turn, not deferred
presentation or complete end-to-end acceptance. Actual native model turns remain
6/12 (steering messages were in the same coordination turn, not two new turns),
with conservative runtime charge 12/30 minutes. No source-active test, production,
real ticket or new source-writing operation occurred. Scratch coordinator exited
cleanly after collection. No resend requested.

## Busy steering recovery accepted against retained native history

Unit1 per-item extraction is accepted after chronological ordering was restored.
Frozen `/private/tmp/symphony-u9-multiuser-unit1-final-v2/`:
Commands `e7e2199c27ded3b0fc056ca525fe5a6e30f06b041fa7313155080447602e417f`;
tests `3dd847098dcb393bc4511c4fff2298cb613d1abd2fcc03c2634fe4a2d2ab665f`.
Real-pattern RED 1/1, seed 405115; final focused 7/0, 1.1s, seed 949880.
Independent frozen review PASS. Top-level native user items retain raw identity
and body; delegation content is excluded. Duplicate identities and ambiguous
receipt-to-user associations fail closed before admission.

Unit2 recognizes the exact static captured renderer family by decoding its one
quote token, validating original attributes and reconstructing the entire command
byte-for-byte. No shell/Python execution or heuristic repeated unescaping occurs.
Unknown renderings, unsafe tokens and altered commands remain unsupported.
Review required restoring the old single-command shell fence and constraining
run/workflow interpolation; corrected v2 independently passed.
Frozen `/private/tmp/symphony-u9-unit2-frozen-v2-20261008/`:
Commands `74819ca070673ac8d2cc53a78d0b2eecbd576bbd49df19fb7a030ff7d3067e8c`;
tests `d03d5a97787aafad6552f614cd8a3a4d0c1be7b3429a34e89604953db8991b6f`.
The literal command test byte-matches the saved native capture. Author's three
selected checks passed; root's combined nine-check group passed 9/0, 50 excluded,
1.3s, seed 313851. Formatting/diff checks passed. Producer instructions unchanged;
no assertion of universal wrapper support or producer reliability is made.

Root compared live files with the final freeze, compiled the candidate and started
only the disabled synthetic coordinator. Actual AppServer collection twice
accepted both original PENDING proposals without sending any new chat message.
Receipts in the v2 scratch directory:
`coordinator-1791502457417974375.json`,
`coordinator-1791502457661459750.json`.
Supported apply_accepted answered both original questions and set both commands
APPLIED. First/replay application receipts:
`coordinator-1791502481274445167.json`,
`coordinator-1791502482481062375.json`;
post-application collection `coordinator-1791502482796006584.json`.

Independent SQL confirmed ANSWERED/true for Q-U9N-busy-retry-1-v3 and -2-v3.
Exactly four inputs and four commands exist, including the two older answers.
The full input rows, command status/update/application receipts and event count
are identical after application replay and collection replay. Native item/client
identities match the preserved completed capture. Independently hashing the
original native bodies yields their recorded raw hashes:
`681c780bf77810387c8e7190f24122b11a14d258a01ff6753a4da59d68129445`,
`13605cff7fdf393b70ce5fd09f34662f7b9d13a640fae1ba3ab355144bf0fe74`.
Run stays PLANNING, candidate null, iteration 0; source checkout remains clean at
`c5b3480827d6fa212a4d01c9922d726331e9f800`. Coordinator exited cleanly.

Busy-turn direct-input recovery/once-only application is accepted. Source-active
input, deferred presentation and the planner/presentation recovery fences remain
open; do not call Slice4 complete. Native budget unchanged at 6/12 turns and
12/30 conservatively charged active minutes. No new native inference, real-ticket
operation, deployment, commit/push or fixture-history mutation occurred.

Global mix specs.check currently flags the existing missing @spec for
TicketPush.validate_historical_completed_preimage/2 (line80), outside the repaired
files. Record it for the final quality gate; no unrelated source edit was made.

## Final synthetic fixture prepared for the two remaining native checks

The v4 setup incorrectly pre-created its expected Desktop directory. Desktop
created the accepted parent in a suffixed directory; official native readback
rejected it with `parent_native_identity_mismatch`. Its history and uncertain
request are retained, not rewritten or resent. A separate v5 fixture now asserts
the requested directory is absent before and after reservation.

V5 parent `01a11dfb-d17f-7081-84d9-ca4101defe52` is bound at its exact requested
directory, null Project, own completed `list_artifacts {}` returning an empty
attachment list, and completed ACK true. Official record/complete read back
SUCCEEDED. Full independent native history and typed receipts are retained in
`/private/tmp/symphony-u9-native-final-v5-019fa5b7/`.

The synthetic initial state was corrected through RunLedger.update before any
worker existed, from premature PLANNING to ADMITTING_WRITER. The normal scheduler
then created and admitted the exact checkout. One real Luna planner completed and
was adopted; normal admission moved the run to WRITING. Source is still clean at
`9d09507eaaf72cbb50f4b71d40c64687e0ed48d5`, candidate null, iteration zero.
Question `Q-U9N-source-active-final-v5` is open. Source work is not launched until
the human has opened `PPL-891 · Synthetic final-v5` and confirmed readiness.

Both remaining acceptance checks are still unproven. Native turns spent are 9/12;
three remain for the real source worker, direct human answer, and final parent
presentation. No production, real-ticket, Jira/GitLab, push or deployment action
occurred. Internal planner adoption and synthetic Jira transition use the isolated
fixture only. Coordinator session 93430 is waiting for explicit source launch.

## Final native run: deferred presentation accepted; source answer incomplete

The real FILE_SOURCE worker started at `2026-10-09T00:16:00.385619Z`, with
native thread `01a11e04-4659-7280-b2a1-4413fbaaba3d`, turn
`01a11e04-4b75-70f1-876c-f0f240aba8ad`, live Codex process PID 13803 and an
unreleased SOURCE reservation. The direct human turn began at native timestamp
1791505032, inside that active worker interval. Original raw message and native
identity are preserved in one ticket_chat_inputs row.

Root supplied the wrong cue: `Yes — record this answer once while the source
worker is active.` The native raw body has a terminal LF, while the staged body
omits it. The bounded formatting adapter deliberately only admits the supported
`Answer QUESTION_KEY: value` grammar; it does not normalize arbitrary prose.
The collector therefore retains OBSERVED input and one PENDING proposal, with
the question OPEN and no application. Replay preserves those facts. Do not call
source-active answer acceptance/application PASS. This is a test-instruction
failure, not evidence that the supported answer grammar is broken; do not weaken
the production grammar or manufacture an application receipt to qualify it.

The 90-second scratch hold automatically released; the later explicit release
returned source_hold_release_not_acknowledged. That failed release is retained,
not represented as a successful synchronization. The real worker stopped at
`2026-10-09T00:17:53.890133Z`, recording CONTINUE. Independent Git diff and raw-byte
inspection confirmed only fixture.txt changed, with the exact requested append.
Its result is unadopted, candidate null, and no commit or push occurred.

Deferred request `TC-c640148e390de235b109b2e63d3e002437fef028b8e52ef573cd865bdfff2a7f:g1:presentation:6`
remained PENDING/unclaimed after fresh owning-Desktop busy evidence returned
parent_owner_not_quiet. After owning idle plus the controller's native empty-queue
guard, that same request was claimed and sent exactly once. Official full native
readback bound completed turn `01a11e08-6053-7650-8b00-da980a01f28d`, ACK true,
then typed record/complete read back SUCCEEDED. Busy/idle observations, CLI results,
typed proof and completion are retained under the v5 scratch evidence directory.

Coordinator 93430 exited cleanly with the source worker already stopped. The
native budget is exhausted at 12/12 turns; no further inference is authorized by
this bounded run. Deferred presentation is accepted; source-active supported-answer
application is the remaining native check. Slice4 is not yet fully accepted.

## Authorized two-turn retry: source-active answer and once-only application pass

The user explicitly authorized two additional Luna turns, extending the total
native budget to 14. No new parent or checkout was created. The normal scheduler
adopted the prior CONTINUE slice in the isolated repository, producing local
candidate `b1554d17db779885168ff9893da28c52b4160c6b`; no push or external action
occurred. A new question was bound to that exact candidate. The earlier failed
prose input, PENDING proposal and stale question remain intact.

The real source continuation reused internal thread
`01a11e04-4659-7280-b2a1-4413fbaaba3d`, turn
`01a11e0d-25ca-7443-bdf1-7912bfe97071`. SOURCE lease, live Codex PID 17681,
and native start were observed at `2026-10-09T00:25:40.572609Z`.
Direct human turn `01a11e0e-42f0-7d83-bc48-b8dd6b3fe59f` began at 1791505613
and completed at 1791505653. Its explicit input was
`Answer Q-U9N-source-active-final-v5-retry: yes`.
The proposal was staged at `2026-10-09T00:27:31.491307Z`, before source shutdown
at `2026-10-09T00:27:52.698842Z`. Thus both arrival and completion occurred
inside the real source activity interval; the scratch hold's automatic release
is retained honestly and not described as an explicit release acknowledgment.

Actual native collection ACCEPTED command
`TCMD-3b79d84083883fcd25f50ac84e1cf0082e0aad3e0994e92d18d153c675d0f158` from
input `TIN-2325b02fec428dc5c338bb25a7674d85befb58a188b7391b4b19dc58f2aba81f`.
Supported controller application set it APPLIED at `2026-10-09T00:28:12.842608Z`
and set only the retry question ANSWERED/true. Complete command, question, input
and worker-evidence snapshots are byte-identical after recollection/reapplication:
`retry-applied-snapshot.txt` and `retry-replay-snapshot.txt`, both SHA-256
`7e488f42103875c1a35304b46e4715555f143adb3234da7b8bde998d7857b4b9`.
The application does not launch or replay a worker. Source stays clean at the
same candidate and contains the exact single appended line. The real source
result is retained and unadopted; no extra stage was launched.

Coordinator session 31368 exited zero after the owned worker stopped. Actual
native turns are 14/14; conservative active-runtime reservation is 22/30 minutes,
not measured runtime or token usage. No real-ticket operation, Jira/GitLab call,
production mutation, deployment or push occurred. Independent final readback
confirms source-active answer acceptance, once-only application, unchanged worker
evidence, and the earlier once-only deferred presentation. Slice4 is accepted;
Slice5 and production rollout remain separate gates.
