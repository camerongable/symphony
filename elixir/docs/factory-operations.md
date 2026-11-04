# Factory operations without changing handoffs

These reports are read-only, manual commands. They do not add a scheduled job,
change dispatch, retry a request, or write to the ledger.

## Find where time went

From `elixir/`:

```sh
python3 -B scripts/factory-operations.py latency \
  --ledger /Users/cgable/Documents/Codex/factory-state/factory.sqlite \
  --issue PPL-10240
```

The report separates recorded stage duration from stopped-result adoption delay.
Reservation-to-stop includes worker preparation, execution, and recovery; it is
not execution time. Exact queue and execution durations are unknown in historical
records and remain `null`, rather than being inferred from a thread ID. Stage
duration includes infrastructure holds and retries. Time in Review is not a
factory processing delay. The report selects the latest recorded run for an issue.

## Plan storage maintenance

```sh
python3 -B scripts/factory-operations.py storage-plan \
  --factory-root '/Users/cgable/Library/Application Support/ai-factory' \
  --logs-root /Users/cgable/Library/Logs/ai-factory
```

The report lists exact release/snapshot paths and checks the live stdout size and
open process owners. It is an inventory, not a deletion list. No apply mode exists.
Missing owner evidence is unknown, not proof that a file is closed.

Application diagnostics already use OTP rotating logs: 10 MiB × 5 files under
`log/symphony.log*`. Launchd stdout is a separate capture and has no hard cap.

Proposed retention policy:

- Request maintenance when stdout reaches 256 MiB. Retain seven closed segments,
  within a 2 GiB budget, plus compressed history for 30 days within 2 GiB.
- Keep the active release/source pair and two known-good rollback pairs. Preserve
  every ledger/helper/process/recovery-pinned copy regardless of age.
- Unpinned failed builds older than seven days and successful builds older than
  30 days may be proposed for removal. Keep manifests and rollout evidence.
- Incident archives override budgets until separately reviewed. Exceeding a budget
  requests maintenance; it never triggers deletion or a restart.

Before any removal, approve an exact list after checking the current runtime,
rollback chain, all ledger/helper bindings, live processes, and audit/recovery
references. Directory age or newest-N sorting is not sufficient. Source snapshots,
worker worktrees, receipts, and other caches are not implicitly approved.

### Initial stdout archive at an approved maintenance boundary

The current large stdout file must remain intact until a quiet rollout is approved.
Stop the exact service through the guarded rollout procedure, confirm no process
holds `/Users/cgable/Library/Logs/ai-factory/symphony-factory.stdout.log`, then rename
it into the `archive/` directory before normal restart creates a new stdout file.
Compress only the closed archive. Approve the dated destination path before acting;
never overwrite an existing archive. Preserve the initial historical archive until
its diagnostic coverage has been reviewed.

Do not rename the file while live: launchd keeps writing to the old inode.
Do not copytruncate: it can lose or duplicate writes. A true automatic stdout cap
needs a different capture mechanism; it is deliberately outside this low-risk batch.

## Keep the publication regression

`test/symphony_elixir/factory_completed_publication_test.exs` is the reusable
regression for a completed push followed by a later verifier PASS on the same
content. It covers ordinary and CI-preflight publication, preserves the original
receipt through restart/readback, and rejects changed content. The MR publication
test additionally covers Review and human-requested rework. Extend these existing
public-boundary fixtures for future incidents instead of adding another handoff
protocol or qualification gate.
