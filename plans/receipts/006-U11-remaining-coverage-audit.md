# U11 remaining coverage audit — October 9, 2026

Slice 5 is incomplete. This is a bounded search result, not a global
unreachability proof or permission to change the gate.

## Evidence

- Last full gate: 1,507 tests, one failure, six skips, 97.32%, threshold 99%.
- The corrected failing boundary and the separate static gate passed.
- Imported accepted focused exports recover 113 baseline misses; the latest
  historical-admission export adds measured TCA1608; schema-unavailability adds
  measured TCA78/2219; predecessor-byte drift adds TCA425, bringing this to 117.
- Baseline: 8,494 covered / 8,728 executable lines. With the same denominator,
  those additions imply 98.66%, approximately 30 more hits needed. This is
  arithmetic, not a new full-suite result or acceptance.
- Latest runtime/gate-input readback: 142 matching hashes, zero mismatches.
- No full run, native turn, real-ticket action, commit, push or deployment.

## Bounded independent findings

The amendment audit identified the useful missing-admission test, now reviewed
and passing. Other inspected fallbacks are fenced by earlier input/history
validation, foreign keys or producer shapes; another ordinary public corruption
route without resealing history was not established.

The MR audit rejected SQL-trigger proposals for lines 262/321/742: SQLite aborts
raise through the nested Store transaction, rather than return the error tuples
these branches consume. A concurrent same-key enqueue is a different test, not
a trigger substitute. Native session lines 200/201 need actual integration proof.

The Jira finalization/journal audit found earlier phase and prior-history guards.
Hand-manufacturing successful legacy authority to hit a line is not acceptable.
The broader inventory found no other grounded cheap packet. Its WorkerRunner 572
candidate is already covered by the accepted BLOCKED-adoption test; do not count
it again or create a duplicate driver.

Stop repeated searches over these same cheap corruption vectors. Genuine store
failure recovery, helper transport failures and grounded concurrency scenarios
remain possibilities, not accepted evidence. Do not use unsupported connector
returns, private calls, helper corruption or resealed successful history.

Subsequent bounded store-failure investigation established two schema-unavailability
cases. Both now pass together (2/0, 8.7 seconds), with frozen independent review,
real transaction rollback, during-fault full row/source preservation and fresh
read-only canonical controls. They add two measured hits, not the entire gap.

A fresh combined import confirmed 116 hits before the next packet. Omitted-line
inspection then identified TCA425: a newline-only RESERVED predecessor change
passes shape validation but cannot pass the application's byte identity check.
That case passes (1/0, 88.9 seconds), preserves all fault-time state and restores
the exact original before actual application, adding one measured hit.
Malformed supplied critic readback was not added: the exact published-receipt
comparison rejects it before the proposed target; line 1184 is a nonbinary
fallback, not the already-covered binary clause rescue at 1181.

The proposed MR742 competing-FAILED-request scenario was executed and rejected
at an earlier legitimate guard: an unclaimed typed MR cannot be failed without
its claim. Claiming moves to FOLLOWUP_UNCERTAIN; subsequent failure moves to
RECONCILE_REQUIRED, still busy. The original source-feasibility conclusion was
wrong and is retracted. Failed export is retained under `failed-attempts/`,
excluded from accepted-export imports. A separate corrected public scenario
preserves the pending peer, verifies unauthorized failure cannot mutate it,
checks outer controller-busy deferral, and reuses that exact peer (1/0, 37.2
seconds). One existing shared-helper caller also passes (1/0, 45.4 seconds).
Neither result is credited as a new baseline miss or MR742 coverage.

## Outstanding gates

1. Meaningful coverage sufficient for the unchanged aggregate 99% gate.
2. Final frozen full quality gate and source/result receipts.
3. Integrated native ordinary-path acceptance under an explicitly approved
   turn/runtime budget, actual human UI opening/response and restricted broker
   proof. The outstanding budget question is not approval.
4. Accepted candidate commit; push, disabled-first deployment and pilot enabling
   remain separate authorizations. Preserve actual scheduler/broker paused state.

No scope, coverage exclusion, threshold, rollout permission or policy changed.
