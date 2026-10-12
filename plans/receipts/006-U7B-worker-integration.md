# U7b worker launch/adoption receipt

Date: 2026-10-05. Checkout:
`/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`.
Branch: `cgable/desktop-owned-ticket-chat-v1`.
Base HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`.

Status: implemented locally; independent U7b component review ACCEPTED, with no
remaining safety/code findings. Whole-branch delivery verdict: REPAIR for coverage.
The full suite passes, but full repository quality acceptance is not achieved:
the unchanged 100% coverage gate fails at 99.37%. No production
enablement, live model/connector call, commit, push or deployment is claimed.

## Implemented boundaries

- Internal `Scheduler.ticket_step/3`, not production `tick`, launches/adopts one
  exact ordinary stage. V1 production ownership remains quarantined by U7a.
- Fresh controller readback is scoped to run/issue/revision/contract, expires
  after 60 seconds, and rejects blocked labels/status before new launch.
- TaskLauncher preserves unfinished allocation even if current routing changes
  or disappears. Same checkout, deterministic request/reservation and existing
  SOURCE/REVIEW mutex/capacity admission; no Desktop role-task request.
- Planner consumption enters ADMITTING_WRITER, not a new Jira/writer admission
  bypass. The lifecycle fixture explicitly represents that controller transition.
- Writer adoption reconciles exact file evidence, rechecks parent and run, adopts
  one exact controller commit, persists the candidate, then runs approved
  git-diff-check. Failed/ambiguous checks hold candidate and reservation.
- Verifier consumption requires stopped exact candidate/base-bound evidence.
  Final task/evidence/stage consumption and checkout release are atomic, with
  final parent/contract/stage revalidation.
- Crashes after commit or before release recover the same candidate/check and
  do not repeat a turn, commit or iteration. No force reset or replacement writer.

## Verification

- Seven combined focused suites: 152 tests, zero failures, seed 256136.
  This precedes the final parent-invalidation test.
- Final serial lifecycle suite: 10 tests, zero failures, seed 316914, 88.5s.
  Covers planner, two same-thread writer passes and fresh blind verifier;
  capacity rollback, stopped evidence/task recovery, stored allocation drift,
  authorization rejection, failed check, commit publication loss, release rollback,
  stale stage/parent and parent invalidation between commit and finalization.
- Independent reviewer reran the final parent-invalidation test: 1/0 in 9.5s,
  with frozen runtime/test hashes unchanged. No remaining source blocker.
- Public specs, format, whole strict lint (202 files), whitespace checks and
  standalone Dialyzer passed. Full `make all` completed with exit 2 at coverage;
  its build, format, lint and test execution passed. It did not proceed to its
  Dialyzer stage; the separately recorded Dialyzer pass is not a whole-gate pass.
- Full test run: 1,139 tests, zero failures, six existing live skips; seed 385669,
  897.1 seconds (698.0s async, 199.1s sync). Coverage total: 99.37% versus 100%.
  Below-threshold modules: TicketWorkerRunner 95.26%, WorkerCheckIO 96.61%,
  MrFeedbackLedger 97.14%, TicketChat 98.34%, ControllerCi 98.78%,
  NativeWorkspaceMaintenance 98.91%, WorkerFileIO 98.93%, WorkerFileTools 99.26%.
  These gaps are not silently classified as pre-existing or waived. This result
  proves test success, not full branch acceptance or production readiness.
- Final independent review distinguishes functional U7b acceptance from the
  repository-wide coverage hold. No deployment/enablement or branch-ready claim.
- Full-gate rerun command: `ELIXIR_ERL_OPTIONS='+S 4' make all MIX='mise exec -- mix'`.
  The unchanged coverage threshold is 100%. Four schedulers bound test concurrency
  to eight cases. No tests or coverage requirements were skipped or lowered.
- Earlier interrupted full runs are not acceptance evidence. Repairs were a
  serial/bounded lifecycle fixture, globally unique temporary fixture directories,
  existing style warnings, and one statically unreachable TicketChat else pattern.
  Dependency security-advisory warnings remain outside this slice.

## Frozen runtime/test SHA-256

| File | SHA-256 |
| --- | --- |
| `task_launcher.ex` | `20b94250782c886afa07c76ef40bb9ef06e3de35dd6e9c1b8850de254d9996dc` |
| `ticket_worker_runner.ex` | `a621cebcc53288c135b07e5269e4959da32313680764b9fa76992646bc0d7872` |
| `scheduler.ex` | `ef4dcfbd18a3d6eb98800593b18eee8943db7adf2d2416ad7f4f8c42c9cba7ef` |
| `ticket_chat.ex` | `e611ac3f688e162c274d77f822ab47952653696b6ba780b62d2713e18db8df51` |
| `worker_evidence.ex` | `4cadb0cf674dc7c73e7d9bc0ad95caf90ac850bc5ca060c7ae1326f0b5ce15c7` |
| `factory_ticket_worker_lifecycle_test.exs` | `1c38a6a72ba585f50d534440f934a0270709d586b3f7378fd24c993e50eb7fd5` |

## Remaining outside U7b

U7c parent broker issuance/presentation and production dispatch, combined ordinary
route acceptance, build/test check-catalog extensions, and Required:yes validation
are not completed by this receipt. No existing production ticket was dispatched.
