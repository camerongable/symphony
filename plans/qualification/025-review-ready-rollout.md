# READY-only rollout tool preparation

## Result and boundary

Offline tools checkpoint `e603df7` is prepared for independent review, not
deployment. It starts from accepted combined source
`4f58e6a86396bb76a57fca6cdeb519a91749afb2` on branch
`cgable/review-ready-rollout-20261027`. No verified Jira belongs to this factory
tooling change, so its conventional commit deliberately has no product-ticket
scope. Parent owns final integration, artifact qualification, and service control.

Plan023 and these reviewed tools must first be combined in one clean, accepted
source commit. No release was built and neither new qualifier was run against
the live ledger during this preparation. Offline test success is not artifact,
cutover, CI, verifier, delivery, or human-review acceptance.

## Completed-ticket preservation

The new adapter pins original216 source/manifest/launcher/boot guard, PID94962 and
its start identity, fingerprint, schema54, and original plist preimage. It accepts
only the entire pinned READY_FOR_REVIEW run, completed envelope and387927-byte
receipt, pipeline2992785001, verifier6, repair13, iteration27, MR47818, NULLerror,
and released generation67. The whole-row digest uses sorted compact Python JSON
with `ensure_ascii=True`; it must not be interchanged with the earlier UTF8
`ensure_ascii=False` digest. Exact pins are in the new adapter and canonical025.

All old protected rows and the complete schema are frozen. Only control,
tick_health, intake_snapshots and sqlite_sequence are excluded from timer-sensitive
row equality. There are no worker-consumption exceptions. No new protected rows
or events are currently authorized, including normal-looking tick events. Any
append stops the guard for explicit attribution; the guard never erases it or
automatically rolls back advanced state.

The broker mailbox quiet gate examines names/stat metadata only. It accepts owned
non-symlink regular files in complete32-lowerhex `.finished`/`.response` pairs in
an owned0700 directory, captures the name-set digest, and rejects unresolved,
unknown, linked, foreign-owned or newly changed entries. It never reads response
bodies or removes anything. Native source queues/locks and real ledger
writer/check/IO ownership must independently remain quiet.

Historical qualification authenticates the recorded rollover predecessor and its
released access, then validates history26's full physical predecessor, retained
generation authority, immutable source-parent4e5→published-eb9 Gitdiff and generated
blob hashes, and historical verifier/CI evidence. It does not rerun issuance-only
freshness, worker_history or verified_rollover. The human's newer clean branchHEAD
is measured before/after and preserved, not reset or required to equal eb9. This
does not qualify CI/delivery for the human's later master-integration commits.

## Offline validation

Run from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s plans/rollout -p test_review_ready_rollout_tools.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s plans/rollout -p test_rollout_tools.py
git diff --check
```

Observed final logs under the isolated checkout's ignored
`elixir/_build/plan025-tools-evidence/`:

| Gate | Actual result | LogSHA256 |
| --- | --- | --- |
| New offline tools |13tests,0failures,0.284s; exit0|e8518c30a59034a2a879cb6d94cc54cd8fd4b6b30e5da83956bdb853c928a1ed|
| Historical tools unchanged |13tests,0failures,0.279s; exit0|1ee44bafe69f58cc35a45d67043958902feb37af1e8725399415d67c69f27dc1|

The unchanged legacy suite still emits its pre-existing unclosed-fixture SQLite
ResourceWarnings. New fixtures explicitly close their connections. Tests cover
typed ticket/envelope/receipt/access/schema guards, missing or changed approval,
source/artifact identity and inventories, required test categories and actual log
hashes, two public/historical proof records, every protected old row and uncertainty,
new-row refusal, stale process/start/service, active writer/check/IO, mailbox states,
two-field plist/preimage/mode preservation, original216-only rollback, and refusal
when a replacement process may still exist. Only process-control subprocess results
are mocked; temporary SQLite, artifact, plist and mailbox files are real.

Test-first results were retained in the task transcript: the first new-tool test
failed because its new module did not yet exist, then passed after the exact READY
guard was introduced. Additional approval/runtime/rollback seams first failed as
missing APIs, then passed. One artifact fixture initially failed because macOS
temporary paths resolved through `/private`; resolving fixture roots corrected
that fixture without weakening path identity.

One early quiet-boundary test accidentally used the real mailbox default path
while its database was temporary. It read filenames/stat metadata only: no bodies,
live SQLite, process control, service action, qualification, or write occurred.
The route now requires an explicit mailbox argument, and the quiet closure passes
the configured constant explicitly; the final tests use the temporary mailbox.
No other new bound defaults reach live paths in the tests.

Python syntax compilation and Elixir `Code.string_to_quoted!` passed. The initial
Elixir parse command from the repository root failed because mise's Elixir config
is in `elixir/`; rerunning from that directory succeeded without building anything:

```sh
cd elixir
ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec -- elixir -e 'Code.string_to_quoted!(File.read!("../plans/rollout/qualify_review_ready_publication.exs")); IO.puts("ELIXIR_SYNTAX_PASS")'
```

All148 private files (143 retained plus five022 additions) match base4f58 exactly.
Historical review_cutover.py and test_rollout_tools.py match their base bytes.
Builder changes only BASE, BASE_SHA and BASELINE_COMMIT. No production source,
configuration, schema, policy, budget or private program changed.

Full make/all, coverage and Dialyzer were not run for this plans-only preparation.
The known inherited653-finding lint baseline is not a full-green quality gate;
final combined023 must separately prove zero additions against it. There is no
coverage or Dialyzer PASS claim here.

## Future exact command contract — not executed

After source/tool acceptance and final clean merge, the builder CLI is unchanged:

```sh
python3 plans/rollout/build_review_release.py --worktree ABS_FINAL_CLEAN_WORKTREE --commit EXACT_ACCEPTED_SHA --name UNIQUE_SYMPHONY_REVIEW_REPORT_NAME --evidence NEW_ABSOLUTE_EVIDENCE_DIRECTORY
```

Its result is BUILT_NOT_ACTIVATED. It retains strict source/dependency/artifact
inventories, forced compile, all app-module origins, factory fingerprint, previous
manifest and all private identities. No overlay or hot replacement is supported.

For each qualifier, arguments are exactly: absolute accepted manifest path, exact
manifestSHA256, new absolute evidence-output path. There is no database/path/mode
environment override or alternative live-write CLI. Execute the scripts from the
accepted artifact's source snapshot, using only its packaged modules:

```sh
cd ABS_PACKAGED_SOURCE/elixir
ERL_FLAGS='+S 4:4' PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/mise exec -- elixir -pa 'ABS_PACKAGED_BUILD/lib/*/ebin' ABS_PACKAGED_SOURCE/plans/rollout/qualify_review_ready_publication.exs ABS_MANIFEST EXACT_MANIFEST_SHA NEW_ABS_PUBLIC_JSON
python3 -I -B ABS_PACKAGED_SOURCE/plans/rollout/qualify_review_ready_publication_history.py ABS_MANIFEST EXACT_MANIFEST_SHA NEW_ABS_HISTORY_JSON
```

The public proof opens/closes Store.start_read_only twice, sets query_only, requires
exact receipt bytes plus receipt_valid?, completed_proof and validate_completed_proof,
and compares entire protected history and humanHEAD. The companion independently
opens/closes mode=ro/query_only twice and revalidates the authenticated historical
chain against actual immutable Gitobjects. All total_changes values must remain0.
Neither starts the factory application or creates a runtime/model thread.

## Acceptance files

All files are independently reviewed evidence, not placeholders fabricated by the
tool. `rollout-approved.json` must bind exact source/manifest, adapter/guardian hashes
and SHA256 of every required file. Required files are candidate.json, validation.json,
source-approved.json, review-acceptance.json, cold-boot.json, runtime-preflight.json,
public-completed-qualification.json, historical-completed-qualification.json,
service.original.plist, cutover-audit.json and audited-protected.json.

validation.json binds source commit, manifest and fingerprint. Its `tests` array
must contain positive-count, zero-failure/zero-exit command results and real log
hashes for both source and artifact environments, covering completed-recovery,
refusal, readback, broker, appserver, owner and composed categories. This does not
pin a historically obsolete single composed-test count. It also requires unchanged
private resources and honest quality_limits: baseline653, added0, and coverage/
Dialyzer NOT_REACHED. Any stronger reached quality result needs explicit evidence
and a reviewed contract update rather than silently changing those fields.

source-approved.json and review-acceptance.json must ACCEPT the final exact source;
the former explicitly accepts014/022/023/025-tools and the latter also binds the
artifact manifest. Cold-boot and fresh runtime-preflight must bind the same artifact
and record zero chats/turns; runtime preflight is initialization-only, signed-runtime
verified, completed within300seconds. New public/history evidence must match every
fixed receipt/envelope/candidate pin and two closed read-only opens.

## Parent-only cutover

Root first reviews the exact artifact/evidence, then pauses only the broker through
supported app controls. It preserves the broker's full fields/one-minute schedule
and leaves scheduler configuration, paused monitor and paused goal unchanged.
The CLI retains the old operation/evidence shape, but uses the new READY-only file:

```sh
python3 plans/rollout/review_ready_cutover.py capture ABS_EVIDENCE_DIRECTORY
python3 plans/rollout/review_ready_cutover.py stop ABS_EVIDENCE_DIRECTORY
python3 plans/rollout/review_ready_cutover.py finish-stop ABS_EVIDENCE_DIRECTORY
python3 plans/rollout/review_ready_cutover.py start ABS_EVIDENCE_DIRECTORY
python3 plans/rollout/review_ready_cutover.py finish-start ABS_EVIDENCE_DIRECTORY
```

`stop` already invokes finish-stop; `start` already invokes finish-start. Explicit
finish operations are read-only reconciliation of an interrupted operation, not
permission to repeat bootout/bootstrap. Existing exclusive intent files prevent
another start/stop attempt. The pinned guardian uses exact PID/start identity;
the pinned old main and stale workflow/ticket/runtime acceptance are never invoked.

Capture/protected checks bind DB device/inode/uid, complete schema, all old rows,
full READY run and mailbox name-set. Guards recheck before freeze, after exact
SIGSTOP, before bootstrap, and after startup. Original plist replacement compares
exact preimage and changes only ProgramArguments[0] and MIX_BUILD_PATH, preserving
other fields and mode. Post-start must repeat packaged public/historical proof.
Root must then inspect the actual dashboard and restore the broker's exact fields.

Rollback operations are `restore-check` and `restore-original` with the same evidence
directory. They require issuer/launchd/API and replacement process absence,
unchanged schema/all protected rows/READY state, the separately hash-verified full
original216 release, and exact original or two-field replacement plist. They restore
original plist bytes and original216 only; never SQLite backup or history. Alive
replacement, unknown ownership, unreviewed append or any advanced state means STOP
and a manual report, not automatic restoration or guessed authority.
