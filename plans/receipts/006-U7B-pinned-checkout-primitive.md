# Pinned first-checkout primitive

2026-10-05. `Worktree.writer_path/3` provides the deterministic path without
mutation. `ensure_writer_pinned/4` creates a fresh branch/checkout at an exact
commit, or verifies only that exact clean registered checkout. Existing branch
collisions, protected/base branches, path aliases and dirty reuse reject without
reset, deletion, branch suffixing or base refresh. Legacy ensure_writer is unchanged.

Pinned operations use fixed CLT Git, sanitized environment/configuration, disabled
hooks and replacement objects, and the [documented no-lazy-fetch option](https://git-scm.com/docs/git#Documentation/git.txt---no-lazy-fetch).
Exact commit object type is checked before creation; annotated tags reject.

Verification: Worktree suite **20 tests, 0 failures**; additional hook-sentinel
positive case **1/0**. Tests include advanced-base/pinned-SHA preservation, clean
reuse, dirty-file retention, branch/root denial, tag rejection without residual
branch/path, and a separate actual Mix process with redirected Git environment
that leaves the foreign repository untouched. Specs, strict Credo, format and
whitespace checks pass. Independent frozen review reports both discovered defects
repaired and no remaining concrete primitive blocker.

This is a low-level controller primitive, **not** a durable admission coordinator.
It does not attest absence of late Git effects after controller crash, prevent a
concurrent human replacing directory ancestors, or authorize source/model work.
Initial admission still needs immutable intent, exclusive mutation ownership,
capacity/fresh-authority checks, crash readback and atomic finalization before
PLANNING. Production and normal-tick route fences remain unchanged.
