# U8a normal polling integration

Status: accepted locally after focused tests, direct-caller regressions, static
checks and independent frozen-source Sol review. Not whole Slice 4 acceptance.

Intended behavior: configured active ready-parent normal ticks collect read-only
native history, apply at most one persisted ACCEPTED answer-only command under the
current chat/run binding, and return without advancing source work in that tick.
No-command role ticks retain their prior progression; the delivery-state branch
and terminal-state selection remain unchanged. Mixed/unsupported commands stay
pending without partial effects; history replay must not starve later ticks with
already-rejected/applied inputs. Paused receipt-only recovery is unchanged.

Current evidence:

- Writer reports the production seam implemented under the existing per-run lock.
- Writer's test session 26183 is terminal: three tests, three failures. They invoked
  Scheduler.ticket_step/3 rather than the normal Scheduler.tick/2 path; the expected
  command outcomes were therefore bypassed. This is not acceptance or proof that
  the production polling seam works.
- Next action: exercise the actual public scheduler tick using existing fixtures,
  with no new test-only production entrypoint or timeout expansion. Then run
  affected checks and independent review against frozen source.

Final evidence (supersedes the failed exploratory runs above):

- Root reused the existing tick_controller fixture, retained worker options and
  corrected returned event assertions from event_type to event. No production
  shortcut was added. The diagnosing-bugs reproduction loop isolated these fixture
  defects before edits; the initial correct-public-tick run was 4/4 failures.
- Final focused run 8495, seed 112012: four tests, zero failures, 17.7 seconds
  (42 excluded). Existing cases also prove fresh admission/application in one tick
  and historical REJECTED replay permitting actual writer adoption.
- Direct callers 72756, seed 112013: command and scheduler files, 96 tests, zero
  failures, 5.9 seconds.
- Final format PASS; strict Credo 78148: 610 functions/modules, no issues;
  specs.check PASS. Final Dialyzer 29981: zero errors/skips, 4.45 seconds.
- Independent Sol bounded PASS, including final hash readback and the two added
  regression assertions. Reviewer did not rerun tests/native calls.
- Static repair only: alphabetical alias placement, remove an unreachable false
  fallback and extract the exact unchanged binding comparison into :ok/error helper.

Frozen SHA-256:

- scheduler.ex: ac06a54a951229eca8baef01c777261aba5c004a11a2c851e6268e889fa3f0a1
- ticket_chat_commands.ex: f6b6fc38aef3fcecd08df646020dc94824258bb3be2ac9181fee8c8347c98efd
- factory_ticket_worker_lifecycle_test.exs: c00ea9d4913fdd0f718a59b94e95912989d86da57c55a080c144ae81181cdd90

Tagged GitLab feedback remains deferred. Explicit same-writer recovery and contract
amendment remain separate unfinished packets. No live effects or rollout occurred.
