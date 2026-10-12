# U8b explicit rework after a held amendment

Accepted locally after focused tests and frozen independent Sol 6.1 Medium
review/re-review. Explicit native rework uses the same writer thread and source
checkout under the installed contract. Preparation, lease transfer, successor
reservation and command application are transactional; invocation follows commit.
Saved normal feature-writer model/effort remain explicit, not critic allocation.
The amendment link is retained in application and lease-transfer receipts.

Author observed three selected regressions passing (54 excluded, 53.3 seconds,
seed 503308): amended rework/history, ordinary same-thread rework, and stale
disposition/capacity/rollback. Root independently observed the amended case on
the initial frozen source: session 12454, seed 774329, 1/0, 35.1 seconds.

Independent review found missing actual retained-row JSON digest checks in the
post-transfer historical path. The new existing-fixture regression reproduced
that defect, then passed after the repair (author: seed 77432935, RED 1/1,
GREEN 1/0). Re-review accepted hashing all three retained row images against
the original reservation before held or transferred validation. Outer receipt
resealing cannot bypass that anchor. Valid historical replay remains accepted.
Root verified final fingerprints; no redundant post-helper test rerun occurred.

Format, public-function specs, warnings-as-errors compilation, scoped strict
Credo and diff checks pass in author evidence. No full suite, deployment or live
provider/Jira/GitLab effect was performed.

Frozen SHA-256:

- Amendment: `ae1de6813b050fd529d931ed89d5996b48e7ababf0e90d2c26f3a60d17057334`
- Workspace access: `5e0f16be6f2684fb7d4b24ed2ea165047aa6f807837c04254668787aba77bb6f`
- Launcher: `608ebfc5ebe3f08db2809e332dc5f3b066dcd13af7e48019f257e21c92cff81a`
- Scheduler: `a9b0e1ba4af8192d7693c0b6f986c1cceffc4f73244ea0e5879bb18d61afdbe1`
- Commands: `c8f5fb8979e69bf02a358b3b50d1d6725c354cb311f0b52c958b472163846377`
- Lifecycle tests: `5699265848250f9a5fb022269e20ca19f0fd0d73f33ce64b9c887262909cc22f`

Repeated held amendments, non-PASS corrected proposals, mixed commands,
scheduler publication/critic joins and whole-Slice-4/native acceptance remain.
