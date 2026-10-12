# U7 review-ready readback diagnosis

The live full gate, seed 101810/session 20744, reproduced the existing lifecycle
case at line 862 exceeding its 180-second test limit. The captured stack was in
`TicketPushIO.collect/3`, reached through `TicketJiraFinalization.prepare/8`'s
transactional MR receipt validation during same-operation Jira reconciliation.

Independent read-only review confirmed repeated immutable stopped-push proof work:
MR qualification calls `bind_admitted` before and after the current MR read;
transactional validation calls it again. Each binding calls `completed_proof`,
which reads the same original filesystem stopped receipt. Successful reconciliation
then repeats the sequence at finalization: six reads, two inside SQLite transactions.
A fresh two-effect finalization can perform twelve such reads. Each binding also
performs fresh origin and remote-SHA work.

This call graph proves duplication, not why an individual helper might stall.
Post-terminal diagnosis must measure the existing narrow lifecycle case and its
actual public readback calls before changing source. Do not enlarge the 180-second
test timeout, change helper deadlines, or weaken ownership/freshness gates.

Candidate optimization under adversarial review: collect the exact stopped-file
proof once per MR qualification outside SQLite and carry envelope/receipt bytes,
digests, invocation, and released-reservation identity. Revalidate exact current
handoff/lease equality and candidate/binding/schema invariants in the transaction.
Keep fresh origin, remote candidate SHA, and MR reads outside it, including post-MR
checks. No caller-supplied cache boolean, skip flag, or durable permission token.
This is not yet an implementation or accepted change.

## Adversarial review outcome

A second independent read-only review accepts call-local exact proof transfer in
principle. Authenticity originates in `WorkspaceAccess.release_push/4`, which
validated the stopped helper and wrote the completed envelope as the released
reservation's receipt. Source-worker file tools cannot write that ledger or spool.

Before each transactional use, reread the current run and released reservation.
Compare full handoff bytes/digest, current candidate/contract, receipt bytes/digest
and schema, helper/execution/invocation bindings, reservation key/generation/owner,
released state, and exact release receipt. Reject substitutions or stale captures.
Acquire a fresh filesystem proof for every new qualification/reconciliation call;
never deserialize a prior call's proof or accept an opts skip flag.

The carried proof attests historical termination, not continuing filesystem
availability. This does not authorize spool cleanup: existing cleanup protections
remain unchanged, and the next qualification still requires physical readback.
Preserve live origin/remote/MR/Jira/checkout checks at their current pre/post points
outside SQLite. Reusing the proof must not claim a passed runtime performance test.

Post-terminal implementation sequence: measure the existing narrow red-capable
lifecycle case, extract ledger-only proof revalidation without changing existing
`completed_proof/2` behavior, carry its exact proof through the two MR bindings and
transaction validation, prove changed envelope/lease/candidate/contract rejection,
and verify the existing recovery lifecycle plus actual readback count. Keep source
frozen while full gate session 20744 remains live.

## First source unit implemented

The full gate is terminal: 1,301 tests, three failures, six skips; 99.12% coverage,
exit 2. The unchanged narrow review-ready recovery case subsequently passed in
isolation, seed 187449, with a measured case duration of 130,101 ms (132.2 seconds
including setup). This is close to its 180-second limit and is not an aggregate fix.
The other two aggregate failures passed together with unchanged deadlines, seed
540700, 2/0 in 12.8 seconds.

`TicketPush.completed_proof/2` retains original filesystem/origin verification and
now captures the exact full run, released access row, intent/binding, envelope bytes
and digest. New `validate_completed_proof/3` performs only current ledger reads and
exact schema/hash/binding/candidate comparisons. Historical rollover still uses
its original filesystem verification and historical-versus-current distinction.
No MR consumer reuses this proof yet; no speed improvement is claimed.

The existing push/restart case was extended with changed proof-field, released-row,
and contract-revision rejection. RED: missing validator, seed 556758, 1 failure.
GREEN: seed 835988, 1/0 in 33.3 seconds. After tightening the version/kind pattern,
the push/restart and CI history rollover cases passed together: seed 292984,
2/0 in 72.4 seconds. Public specs and whitespace checks passed. Independent frozen
source review accepted this extraction unit with no blocking findings.

Next: carry this exact call-local proof through MR qualification and transactional
validation, asserting one actual stopped-file read per qualification. Preserve all
fresh external/candidate checks; do not broaden this unit into cached authority or
cleanup changes. Runtime startup qualification, the remaining aggregate failures,
100% full-gate acceptance, and later slices remain outstanding.

Strict Credo initially reported one overlong proof-construction line. It was split
into equivalent map construction/puts; targeted formatting, whitespace and strict
Credo then passed (6,146 modules/functions checked). No gate suppression or behavior
change was used to resolve that finding.

## MR proof reuse implemented and reviewed

MR qualification now captures one actual stopped-file proof and carries it in its
internal qualified receipt. The post-MR and transaction binding checks validate
that exact proof against current ledger ownership; origin, checkout/verifier facts,
remote candidate SHA, MR freshness/human state, and request bindings remain checked.
No global proof cache, supplied skip option, persisted permission flag, or cleanup
policy change was added. Other MR/push callers still collect their own proof.

The existing read-only receipt case uses OTP call-count tracing of the real public
`TicketPushIO.readback/1`. RED seed 145214: actual count 2 versus required 1. GREEN
seed 212059: 1/0 in 47.1 seconds; count remains 1 through qualification and an actual
Exqlite transaction validation, and a changed proof digest is rejected. Existing
checkout/candidate/request/human-MR mutation checks remain in that same case.
Independent frozen-delta review accepted the reuse with no findings. Public specs,
strict Credo (6,148 modules/functions), and whitespace checks passed.

The original recovery lifecycle passed, seed 544462, case duration 130,835 ms
(135.2 seconds including setup), versus 130,101 ms before the change. There is no
measured elapsed-time improvement. The count reduction is proven; it is not a
claimed fix for the aggregate 180-second failure. Some fresh filesystem/Git checks
still occur inside transactions. A further change must be justified by boundary
timings, not by assuming stopped-receipt reads dominate.
