# U11 restricted broker replay preparation

## October 12 acceptance checkpoint

The actual broker replay is now scoped PASS. User authorized up to twenty new
Luna runs; three were used: the broker check, independent acceptance audit, and
its follow-up inspection of the recorded permission profile. The former 17-turn
packet remains unchanged. New accounting is
`/private/tmp/u11-broker-replay.9Zuokx/luna-allowance.json`.

Completed broker turn `01a12ddf-2629-74f3-b8eb-7bd3b7b98291` ran exactly one
command, `exec-59b28c33-2ccf-4756-8ca8-4b0502171460`, in the implementation
Elixir directory and exited zero. Its native session turn_context records
GPT-6 Luna/low, approval policy on-request, workspace-write sandbox, and network
access disabled. No escalation or sandbox override was observed in the command.
Independent review checked that exact policy record, not only the output label.
This proves execution under the recorded Desktop-turn policy, not universal
OS confinement or future production command compatibility.

The script's original conservative plain-VM label was preserved verbatim.
Its raw tool output independently decoded to zero replay launch calls, no Mix
PubSub, no Symphony application startup, and unchanged database SHA. Post-run
independent hash agreed with preflight; SQLite integrity returned `ok`; candidate
and READY_FOR_REVIEW state remained unchanged. Native read_thread command output
was truncated, so its final diagnostic was separately verified in the exact
raw session tool-output record, rather than inferred from the agent's summary.
Readback: `/private/tmp/u11-broker-replay.9Zuokx/broker-command-readback.json`.

Native telemetry for that broker turn records 633,999 input tokens, including
312,064 cached input tokens, and 1,599 output tokens: 635,598 total. This is
observed token accounting, not an estimated charge or newly established price.

Independent audit found no product-code gap. It identified the literal final
`make all` requirement as still unmet by the prior individually passing checks.
The exact offline gate is now running in exec session 19338; log
`/private/tmp/u11-literal-finalgate.Qju3pQ/make-all.log`. All tracker live-test
opt-ins are explicitly disabled. Source is frozen; no new native/model turns
are being used for this local gate. Source hash before this run:
`fa1982665d7cc66e187ccfc0101890bfa57cb5fdf91207ae73010c51958fca1c`
(274 lib/test/priv files, sorted paths plus NUL-separated bytes).
Lockfile SHA: `828d211a3d6a44a4a3c09485c42380936142c57b272613bc84e0a572ef31ebe6`.
Deployment and activation retain their separate approval boundaries.

## Literal-run interruption and focused diagnosis

The redundant literal full run reported one 60-second timeout at
`factory_worker_file_tools_test.exs:549`, inside a sandboxed Git identity check.
After the user challenged the promised test scope, root ended the remaining
full run with SIGTERM to the exact owned test VM 62051. Its parent make PIDs
61936/62049 and the VM were independently observed absent afterwards. No files
or recovery evidence were deleted.

The shell's make exit was zero because the terminated BEAM returned success
and make continued to Dialyzer. This is explicitly NOT a passing full gate:
the interrupted coverage phase reported only 1,503 tests, one failure and six
skips, rather than completing the 1,560-test baseline. The timeout remains in
the preserved log. Later build/lint/static-analysis success cannot repair that
missing coverage result. The previous complete component gate remains separate
historical evidence.

Only the failing case was then run with seed 730843 and max-cases 1. It ended
with exit 2, one test/one failure/97 excluded, at the same 60-second limit,
again within Git identity validation. Log:
`/private/tmp/u11-literal-finalgate.Qju3pQ/timeout-repro-1.log`.
The first few seconds overlapped orderly shutdown of the old run; a separate
timing diagnosis runs only after the old PIDs were confirmed absent.

Luna run 4 provided read-only triage. Run 5 owns temporary tagged instrumentation
in that one test to distinguish cumulative 24-case overhead from a specific
stalled Git call; it must restore exact original source afterward. No timeout,
safety assertion or production permission has been relaxed. No further full
suite is planned; subsequent verification is scoped to the failing seam.

The measured timeout repair is now independently ACCEPTED, including the
required stronger GPT-6.1 Sol/high review. Both split tests preserve all 24 cases
and passed under the unchanged default timeout. See
`006-U11-file-safety-timeout-repair.md`. Seven of twenty new Luna runs were used;
the stronger review followed the standing Plan 006 assignment. Product source
and every other snapshot file were verified unchanged. No current full-suite
pass or deployment is claimed.

The preparation chronology below is historical.

This receipt records preparation only, not restricted-runtime acceptance.
No model turn, broker message, production mutation, permission change,
commit, deployment or activation occurred.

## Exact remaining boundary

U10/U11 requires the read-only receipt-replay diagnostic to work in the actual
Desktop broker's restricted environment. It does not require another complete
writer/verifier cycle. Ordinary native source/rework acceptance is recorded in
the fresh-amendment packet, with its explicit composite-evidence qualifications.

The existing broker is `01a0d470-1608-7be3-aa4d-a11920360efd`, titled
`FACTORY · assigned-jira-work · Desktop Broker`, projectless, observed idle.
Read-backed completed turns `01a12d8e-39df-7952-bff0-04d28c2e434c` and
`01a12d8d-4f5d-7ab2-a706-3beb688059b5` show both normal status/list commands
failed before execution: Mix 1.19.5 PubSub could not open a TCP socket (`:eperm`).
Those failures are actual broker evidence, not failure of a ticket worker.

## Model-free preflight

Prepared isolated directory `/private/tmp/u11-broker-replay.9Zuokx`.
Its SQLite database is a read-only-backup copy of the accepted synthetic ledger,
not the production ledger. Synthetic workflow uses tracker kind `memory`.

Command from the implementation Elixir directory:

```sh
/opt/homebrew/bin/mise exec -- elixir -pa '_build/dev/lib/*/ebin' \
  /private/tmp/u11-broker-replay.9Zuokx/replay.exs
```

The script invokes the existing compiled `Mix.Tasks.Factory.Ticket.run/1`
directly, with only `replay` against the copied ledger. It does not run Mix's
dependency/compiler task pipeline, change installed runtime bytes, or loosen
permissions. The first invocation with an unquoted shell glob failed before
script execution; the quoted invocation exited zero.

Observed preflight: 268 AppServer trace patterns, zero replay launch calls,
Mix.PubSub absent, Symphony application not started, main database unchanged.
Independent SQLite integrity check returned `ok`; the copied run remains
READY_FOR_REVIEW at `da5e24072df110732b5f0963ef704f6863a69f74`.
Tracing covers the caller and newly spawned descendants, not pre-existing
processes or an entire broker VM. Main-file equality does not attest every
SQLite sidecar. This plain-VM result does not substitute for the restricted test.

Database SHA-256 before/after:
`41843987c050ef5791f6791a23f68180b47143b6b6c4edd9f3f19b00a3886dbd`.
Script SHA-256:
`0bfdebdec8e0e2b5b9bc5c151a46a47f2086c576aac849efcf759f68cacabe48`.
Output: `/private/tmp/u11-broker-replay.9Zuokx/preflight.log`.

## Next bounded action

The prior native packet is exhausted at 17/17. Do not silently reset it.
Request one additional Luna/low broker turn, maximum five active minutes, using
the exact existing broker and command above. It must do no factory tick,
status/list mutation, claim, dispatch, connector call, source operation or
permission escalation. Read back its exact completed command, cwd, exit and
receipt; independently recheck the copied ledger. A sandbox rejection is a
failed acceptance with its exact reason, not permission to reroute unrestricted.
No human chat message is needed for this test. No full suite rerun is needed
unless product source changes. Deployment and activation retain their separate
approval gates.
