# U11 bounded read-only Journal coverage audit

Independent read-only reviewer: slice5_final_receipt_audit. No files/tests/fixtures
were changed by the reviewer, and no native or external calls were made.

Question: can a genuine Store.start_read_only connection to an intact existing
fixture DB exercise currently missed public Journal write-error/recovery branches,
without corrupting or resealing authoritative rows?

Result: no defensible remaining-line packet found. Actual public APIs are prepare/5,
prepare_review/5, claim/2 and reconcile/3. The read-only connection can perform the
eligibility/history reads, but Journal writes use Store.query! and the transaction
wrapper does not rescue denied-write exceptions. SQLite denial therefore does not
produce the typed validation/history errors consumed by the remaining red branches.
The actual write sites and transaction error arm were already covered in the full
gate; a legitimate denial/nonmutation test would add confidence, not established
coverage gain. No such extra test was added.

The route was not recorded as previously attempted in the frozen audit. This result
rules out this specific proposal; it is not proof that all other uncovered lines
are impossible to exercise. Fresh aggregate evidence remains 8,612/8,728 lines,
98.67%, with 28 further hits needed for the unchanged 99% threshold.

User coverage-policy choice remains pending. Integrated native acceptance still
requires its explicit budget and real human/UI evidence; this audit grants neither.
