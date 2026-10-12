# U9 post-review finalization generation join

Status: bounded source implementation authorized under the existing U9 ordinary
delivery requirement. No real Jira/GitLab/native model calls, schema, new queue,
commit, push, deployment, runtime enablement or policy widening is authorized.
The current sole Luna writer owns this repair. Reviews use immutable copies.

## Evidence and exact scope

The bundled canonical failed before direct READY rework. Both post-amendment
readiness ticks returned `ticket_jira_not_dispatchable`; state stayed MR_CREATING.
Log: `/private/tmp/symphony-u9-canonical-bundled-final-retry-60214.log`.
The test ran one case, one failure, three excluded, 99.7 seconds overall.

Before edits, the relevant code is frozen in
`/private/tmp/symphony-u9-finalization-design.xvrwFI`; all eleven source/copy
hashes matched. Manifest SHA256:
`43399b39b09e6015caf9e5351f5ad8cd4aa068954cbcdd7aa9b6b4a465fd99c6`.
Independent protocol review confirmed this design and the released-key edge case.

Source allowlist: existing TicketJiraFinalization, TicketJiraJournal, their
Scheduler recovery caller, and an existing Runner seam only if directly required.
Tests extend existing journal, worker-lifecycle, scheduler and desktop-lifecycle
fixtures. No new harness. Current Commands/admission corrections remain preserved.

## 1. Correct finalization authorization, not Jira labels

Finalization `authority/5` currently calls initial Runner.authorization and admits
ai-review only as an already-issued readback. A fresh re-review generation has no
issued journal yet, although its exact current MR and fresh verifier are qualified.

- Change private `authority/5` to `authority/6` with opts. Call the existing
  `Runner.delivery_authorization(store, run, snapshot, observed_at, opts)`.
- Thread those opts through read_issue and private validate_authority, including
  prepare, claim and finalization. Use reservation-bearing opts while owned.
- Preserve the issued-readback fallback only for exact
  `ticket_jira_not_dispatchable`. Other identity/history/proof errors propagate.
  Issued readback is never new-effect authority.
- In claim_qualified, replace the initial-only proof check with the existing
  `delivery_admission(tx, run, authority.proof, opts)`. Keep current MR receipt
  validation, fresh authorization revalidation, unchanged-row comparison and
  transactional claim immediately before each effect.
- Preserve ACTIVE controller/pilot/busy/uncertainty/reconciliation fences. Target
  ai-review labels alone must never authorize dispatch or a new Jira effect.
- Leave START_IMPLEMENTATION and general source authorization unchanged.

## 2. Bind REVIEW_READY to the current validated push generation

Use these narrow interfaces in the existing Journal, not a separate coordinator:

- `review_identity_key(run, completed_push_sha256) :: String.t()` is pure semantic
  identity. Its caller must supply the digest from validated completed proof.
- `select_review_operation(store, run_id) :: {:ok, selection} | {:error, term()}`,
  where selection contains `operation_key`, `identity_version` (1 or 2),
  `push_sha256`, `disposition` (`:new` or `:reuse`) and `row` (nil for new).
  Selection obtains current completed proof itself. Released same-generation
  inconsistency is an error, not an acquisition disposition.
- `prepare_review(store, run_id, comment_body, checkout, selection) ::
  {:ok, row} | {:error, term()}` revalidates selection and inserts/reuses only its
  exact key inside the existing transaction. Keep legacy `prepare/5` unchanged
  for START_IMPLEMENTATION and legacy tests; Finalization uses prepare_review.
- Recovery uses the same selector and exact expected recorded key. No fallback
  from arbitrary selector errors to creating a new operation.

Store `identity_version: 2` and the validated generation digest only in new v2
binding JSON; preserve old JSON bytes. Validate the row key/version against its
stored binding in both current and historical checks. Existing push_sha256 and
verifier_round comparisons remain; do not drop them to make legacy match.

The legacy semantic key omits verifier round and completed-push digest; the actual
journal binding includes them. The same candidate/contract/revision after fresh
verification therefore collides with old history. Released WorkspaceAccess keys
cannot be reacquired. Do not weaken either fence.

- Preserve `identity_key/2` legacy serialization byte-for-byte, especially
  START_IMPLEMENTATION. Add a REVIEW_READY-only versioned key constructor using
  the old semantic identity and the validated completed-push envelope digest.
  The envelope already binds the verifier round. This is semantic identity,
  never authorization.
- A current-review selector obtains/revalidates TicketPush.completed_proof, then
  chooses current v2, compatible active legacy ownership, or a new v2 generation.
  Give any public helper an adjacent typed spec. No new table or queue.
- Current v2 rows must match the exact current binding/effect pair and key. A
  pending/uncertain current request reuses the same operation. Never resend an
  uncertain effect because observation expired.
- Reuse an exact matching legacy key only with its original active MAINTENANCE
  ownership. Match full binding: candidate, contract/revision, verifier round,
  completed push and checkout—not merely old semantic fields. COMPLETE-but-held
  can confirm targets and atomically release/READY using its original generation.
- An older mismatching legacy row permits rollover only after COMPLETE, immutable
  historical integrity and exact released ownership are proven. Reuse the
  existing released_operation proof, which does not normalize the current run
  to historical state. Pending, uncertain, incomplete, corrupt or unproven history
  remains a fence. Keep old rows, receipts and released reservations unchanged.
- Matching COMPLETE/released history for the *same* delivery generation cannot
  be reopened or treated as fresh work. Release and READY are atomic; that exact
  terminal generation still in MR_CREATING needs reconciliation, not another key.
  The same rule applies to a released current v2 operation. A genuinely new
  admitted push generation gets a new reservation key.
- Journal preparation must validate the selected generation before insertion;
  bound_operation and historical-release checks must validate the correct
  legacy/v2 key and retain exact bindings, effects and receipt checks.
- Carry the selected key consistently through Finalization.finish/reconcile,
  preparation, owned access, controller-busy exclusion and recovery. Its three
  legacy REVIEW_READY recomputations must not diverge. Scheduler's recovery-key
  check must recognize the recorded supported version and exact current generation.
  START_IMPLEMENTATION's recovery identity is unchanged.

Existing comment/label targets can be reconciled from fresh readback into a new
current binding without reissuing them. Do not copy old receipt JSON into a new
generation as if freshly observed. Missing/ambiguous targets retain existing
typed errors and uncertainty behavior. A complete old row is not fresh authority.

## 3. Bounded verification and frozen acceptance

1. Focused initial and post-review finalization: unchanged initial behavior;
   fresh verifier/current MR permits re-review; stale/tampered/missing proof causes
   no effect. The issued-readback path cannot issue a second ambiguous action.
2. Same candidate/contract/revision with a real fresh push: one new v2 journal and
   reservation; original COMPLETE journal and released reservation unchanged.
3. Exact matching active legacy recovery reuses key/generation; unresolved or
   corrupt legacy blocks rollover. Same-generation released v1/v2 is not reopened.
4. Duplicate/reopen/claim-boundary recovery keeps one effect pair and exact MR.
5. Extend the existing canonical once: capture both readiness tick events; retain
   accepted-command rollback, RESERVED/START_SENT and event-seal checks. If the
   first readiness assertion fails, later direct-rework assertions did not run.

Use named focused tests and scoped specs/format/compile while editing. Do not
repeat the full repository gate. Freeze changed hashes for finite independent
review before the U9 boundary integration gate. Real native/human-input and
deployment acceptance remain separately gated; passing a local fixture is not
rollout proof.
