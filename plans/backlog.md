# Factory backlog

Reconciled November 3, 2026. This is the active work list; numbered implementation
plans retain their historical acceptance evidence, not the current queue.

## Current low-risk batch

- **Quality gates — formatting fixed locally; remaining debt measured:** build,
  formatting, and public specs pass. The full gate stops at strict lint: 238
  refactoring opportunities, 360 readability issues, and 291 design suggestions
  across 367 files. Coverage and Dialyzer were not reached. Broad refactoring or
  dependency upgrades require a separate bounded slice, not a formatting cleanup.
  Syntax-normalized comparison proves the two formatting edits do not change code.
- **Storage maintenance — awaiting exact-path approval:** archive closed launchd
  stdout during a quiet maintenance boundary and review additional historical
  release/snapshot candidates. The earlier approved 55-release batch is already
  removed. No additional deletion is approved by this entry.
- **Backlog/index reconciliation — complete locally:** distinguish current work
  from historical and superseded plans; deployment is not implied.

## Planned, not started

### Automated factory disk reclamation (high priority)

The factory should maintain usable disk headroom without repeatedly asking the
user to clean up manually. Automate bounded maintenance of factory-owned storage:
logs, unreferenced releases/source snapshots, and eligible terminal worktrees with
their per-worktree build outputs. Reuse the existing narrow cleanup policy where
possible; do not build another handoff state machine or model-driven monitor.

Before implementation, agree the deletion scope, retained diagnostics, rollback
copies, and operating thresholds. Preserve active/dirty work, unique unpushed
changes, ledger/history/receipts, live processes, required helper origins, and
recovery/audit evidence. Global Go, Ollama, uv, and unrelated caches stay excluded.
Provide a dry-run view, recorded reclamation outcomes, and a clear reason when
space cannot safely be reclaimed. Run maintenance without delaying or interrupting
active ticket work. This entry authorizes planning only, not implementation,
scheduling, lowering the 20 GB admission gate, or additional deletion.

### Other work

- **Handoff latency:** use the deployed read-only reports to identify expensive
  waits before changing scheduling. Exact historical queue/execution separation
  is unavailable; do not treat reservation duration as execution time.
- **Repository-route readiness:** freshly verify that every advertised route is
  usable, including the previously reported POL route. Not yet accepted as fixed.
- **UI polish:** address concrete presentation confusion without changing state
  transitions or workflow authority.
- **Quality debt:** triage the recorded strict-lint findings into bounded,
  behavior-preserving slices; then establish coverage/Dialyzer baselines. Existing
  dependency advisories also need a separately reviewed update plan, not an
  opportunistic version bump during ticket delivery.
- **Required non-production manual validation:** separate implementation and live
  acceptance remain necessary; ordinary ticket delivery does not prove it.
- **Native chat/workspace archive and restore:** historical experiments are not
  production cleanup authorization. Keep deferred until separately scoped.

## Completed or superseded — do not restart as new projects

- One master chat per ticket with isolated specialist workers: deployed; retain
  compatibility with existing recorded workers rather than migrating them.
- Dashboard redesign and current status reporting: deployed. The November 3
  operations release `5d830ab` adds shared Factory/You next-action wording and
  read-only latency/storage reports; it does not enable automatic cleanup.
- Review/repair limit and report robustness: deployed; no new review-loop rewrite.
- Shared generation/recovery (Plan 020) and completed-publication compatibility:
  deployed. PPL-10240 reached Ready for review on unchanged commit `20b8f6da`.
- Plans 002 and 006's ordinary-delivery foundation are carried forward by the
  current implementation. Only separately named unfinished acceptance remains.
- Plan 009's old receipt-reader incident is historical and superseded by later
  publication/readback work. Do not replay its old push or treat its old size cap
  as a current blocker without reproducing it against the deployed version.
