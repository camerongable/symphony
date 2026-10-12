# Push destination and exact remote readback primitives

2026-10-05. Worktree.read_remote_branch reads one validated feature branch with
ls-remote --refs. It does not fetch, push, change local refs, source or checkouts.
Missing, ambiguous or invalid remote output stays a readback error. Exact push
readback uses this same primitive; SHA parsing requires lowercase 40-hex commits.

Worktree.origin_identity compares the effective writer push URLs with repository
read URLs. Exactly one identical destination is required. Only its SHA-256 is
returned; credential-bearing URLs are not stored or exposed in the result.
Multiple or mismatched destinations fail closed.
Relative local and unsupported helper URLs are rejected: equal strings can name
different repositories from the primary and deeper linked-checkout directories.

Verification: the final Worktree suite passed 23 tests, zero failures (seed
436485, 72.3 seconds), including the existing exact-push regression. New local-bare Git
test independently checks refs, source status and worktree inventory unchanged
after readback; rejects missing, glob and protected targets. Destination checks
reject mismatches/multiple URLs and verify credential redaction without making
external network requests. The additional destination-class table passed 1/0
(seed 227269, 3.9 seconds): HTTPS, SSH, SCP, absolute file/local paths are admitted;
relative file/local paths and ext helpers are rejected. Independent read-only
review found the relative-destination defect; the linked-writer regression and
rejection fix were accepted. Specs, strict Credo and whitespace checks pass.

No production push, external connector, deployment or native model turn occurred.
These primitives do not prove stopped execution after a crash. The investigated
remaining boundary requires an immutable push intent, retained exact reservation
and a durable owned-process receipt, then independent remote readback. Remote
SHA alone is not permission to release or repeat a push.
