# Current U7 quality gate

## Authorized 99% replacement gate

October 7: user reports this replacement full gate passed. The handle has expired
(`Unknown process id 41246`) and no owned make/test process remains. Source manifest
still matches the frozen hash below; final coverage artifacts exist. This receipt
records the user-reported PASS, not fabricated terminal output or final test counts.
User authorized moving to Slice 4. No production enablement is implied.

October 6: user authorized lowering the line-coverage threshold to 99%, retaining
all other gates. `mix.exs` now sets 99; ignored modules and dependency versions are
unchanged. Replacement session `41246`, seed `987057`, is live:
`HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all`.
Follow the same handle; source is frozen. Build, format, public specs and strict
Credo pass (6,208 modules/functions); aggregate tests/coverage/Dialyzer remain pending.

Source manifest: `da88c87ca823e5e15ace77ec5fc6e55aca6a5d5f2b48218c4b1c914fd10ce29b`.
mix.exs: `3e48b5bba44f3f0dda301da6bee1698626a8aa4d0a5a60f5aac63f5bc4dde3dd`.
mix.lock and Makefile match the hashes below. No live effects, deployment or
enablement occurred. The goal API remains blocked: recreation correctly refused
an unfinished goal, and computer use cannot operate the protected Codex app.
User was directed to its documented Resume control; manual work/verification has
resumed, but automatic continuation is not claimed active without readback.

## Prior gate and subsequent fixes

October 6. Session `35911` is terminal, exit 2. Command:

`HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all`

Source remained frozen through the completed run; its fingerprint was rechecked
at exit and matches the start. No duplicate aggregate was launched.
Sorted `rg --files lib test priv` SHA256-manifest hash:
`65dd15d28224451afcd5b478fbe31b12b13a1b3667fe4bb2a2bf2c251508d4ec`.
Hash command: `LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256`.

Unchanged supporting hashes:

- mix.exs: `c7c0624df3db3c314c985d69e15e9398a61a9defbc3dcca0f7fe011d21199dcc`
- mix.lock: `828d211a3d6a44a4a3c09485c42380936142c57b272613bc84e0a572ef31ebe6`
- Makefile: `0ecad241d67d65b0bae7c0dfe33fb133679ac954c95582b8493e4b8e72d4d985`

Pre-gate focused release-boundary checks passed two tests (116028, 139.0 seconds).
The real completed Jira journal and held reservation reject missing checkout
evidence even when corrupted storage hashes are internally consistent. Exact
access remains unchanged; all modified journal fields are restored in `after`.
The missing-maintenance-run default remains a no-op without requests or records.
Independent review accepted both cases, with no fabricated ownership/release receipt.
Final formatting, public specs, strict Credo (6,206 modules/functions) and whitespace
checks pass. No production behavior was changed by this last fixture-only packet.

Setup used existing offline locked dependencies and reported their existing security
advisories; no upgrade or suppression was applied. Build, formatting, specs and
strict Credo passed. Seed 111992 completed 1,321 tests with zero failures and six
intentional live skips in 1,867.7 seconds (159.6 async, 1,708.1 sync).
Coverage is 99.32%, below the unchanged 100% threshold. `make all` stopped at
coverage, so Dialyzer did not run and Slice 3 is not accepted.

Remaining below-100% modules: TicketJiraFinalization, TicketPushIO,
ControllerGitRead, TicketCheckoutIO, TicketMrOperation, TicketCheckout,
TicketPush, TicketChat, WorkerFileTools, WorkerFileIO, TicketJiraOperation,
TicketWorkerRunner. NativeWorkspaceMaintenance, WorkspaceAccess and DesktopToolArgs
now reach 100%. Inspect this run's HTML for meaningful reachable public seams;
retain safety fallbacks rather than weakening guards to satisfy coverage.

## Post-run bounded fixes

Extended the existing parent claim/readback and outbox fixtures: a legacy-mode
binding, parent directory reused as source, and invalidated bootstrap acknowledgement
reject at public guards while retaining exact run/request evidence. Seed 111993
found one incorrect expected test error atom; corrected to the existing public
`ticket_chat_parent_not_ready`. Seed 111994 passes 27 tests in 2.2 seconds.
Independent read-only review accepted the cases and exact restoration assertions.

Standalone Dialyzer (67150) exposed two unreachable pattern arms in
`worker_runtime_home` and `check_new_parent_runtime`. Existing runtime/parent
checks passed 9/0 before the cleanup (111995, 4.9 seconds) and after (111996,
4.6 seconds). Removed only arms excluded by the callees' exact return variants;
retained all reachable rejection/error propagation. Independent review accepted.
Standalone Dialyzer (61143) now passes with zero errors/skips in 4.41 seconds;
public specs and formatting pass. This is not a replacement aggregate coverage pass.

The existing no-edit writer lifecycle now exercises actual base-ref drift after
the stopped worker result: exact CAS advances only the disposable remote-tracking
ref to the candidate, public adoption rejects `writer_candidate_mismatch`, and
the run, held reservation, stopped evidence and commit count remain unchanged.
The original ref is restored in `after`; the same scheduler request then adopts
without another worker or commit. Seed 111997 passes 1/0 in 16.7 seconds.
Strict Credo passes (6,206 modules/functions); no warning suppression was added.
Independent read-only review accepted the base-ref drift case. The combined
post-gate runtime/parent/readback/outbox/no-edit checks pass 37/0 (111998,
22.7 seconds, 114 deliberately excluded tests). This focused command is not
an aggregate or coverage acceptance claim.

The pending-comment race uses a sibling of the existing MR-adoption fixture,
not another harness. During pending-effect MR requalification the third tool-read
callback observes the exact comment body from the genuine prepared journal;
fresh Jira readback then reconciles it before any comment write. The adjacent
uncertain-comment test passes (111999, location 1036, 127.7 seconds), separately
from the new case. The traced new case (112000) failed correctly on historical
comments without IDs; the fixture now supplies the same IDs as the existing
finalization case. A syntax typo stopped 112001 before tests; corrected 112002
passes the exact new case (location 1037), 1/0 in 57.5 seconds. It asserts labels-only
mutation, exact observed comment receipt, COMPLETE journal, released reservation,
preserved candidate and unchanged writer rows. No production guard was changed.
Independent review accepted the corrected case.
Strict lint then caught the added tag dispatch pushing the existing shared
assertion helper from complexity nine to ten. Extracted only the dispatch into
`maybe_finalize_jira`; current mutually exclusive fixtures preserve their routes.
Strict Credo now passes (6,208 modules/functions), and the exact new case passes
again after extraction (112003, 1/0, 59.0 seconds). No lint suppression was added.

## Coverage-policy boundary

Independent review confirms effect-limit guards in TicketJiraOperation and
TicketJiraFinalization are unreachable on the valid route: callers start at two,
the journal validates two effects, each successful reconcile advances the first
phase to SECOND_PENDING or the second to COMPLETE, and COMPLETE matches even
with zero remaining budget. Missing observations return errors, not unchanged
successful rows. This does not justify removing the guards or fabricating data.
User input was requested on retaining the strict 100% line requirement versus
using 99% while retaining other gates. Threshold is still 100%; Slice 3 remains
unaccepted and no later slice is being implemented pending that policy decision.
