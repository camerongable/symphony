# U7 runtime identity observation

The installed CLI's generated `v1/InitializeResponse.json` requires `userAgent`,
`platformFamily`, `platformOs`, and `codexHome`. It does not expose a separate
server-version field.

A fresh no-model stdio initialization of the exact installed executable
`/Applications/ChatGPT.localized/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`
returned:

```json
{"userAgent":"symphony-runtime-probe/0.160.0 (Mac OS 26.6.2; arm64) dumb (symphony-runtime-probe; 0.1.0)","platformFamily":"unix","platformOs":"macos"}
```

The client sent only `initialize`, closed stdin, terminated the owned process,
and waited for its exit. No thread creation, model turn, connector call, source
operation, global configuration change, or production admission occurred.

This establishes an observable runtime version/platform boundary. It does not
attest permission containment, Desktop ownership, parent idleness, connector
availability, or source-task admission. Existing fresh operation-bound checks
must remain authoritative for those facts.

The U7 audit identified a remaining implementation requirement: replace the
unconditional enabled-route rejection with actual supported-runtime qualification
while retaining default-disabled configuration and the separate rollout gate.
The runtime-check contract is under independent read-only review. This receipt
is not an enablement token or substitute for implementing that check.

Independent resolver review confirms the observed version is embedded in a
user-agent string, not a dedicated protocol-version field. Its format is not a
stable documented semver contract: unknown format/version must fail closed and
require requalification. Scope the new check to V1; legacy initialization remains
compatible. Qualify the actual configured process, not a different executable or
stored probe report. Keep parent readiness and worker effective-policy/catalog
checks at their existing per-run/per-operation boundaries.

Next source unit: preserve initialization response for the V1 path, reject missing
or malformed required runtime fields and unsupported version/platform, and wire
qualification at each controller entrypoint before V1 effects. Tests must prove
unknown-runtime denial, supported-runtime qualification, no model turn, legacy
compatibility, and that qualification does not bypass parent/worker safety checks.
Startup qualification must not enable production configuration or admit the U8
blocked-writer/rework paths before their separate implementation and acceptance.

## Frozen next implementation unit

Keep `Policy.validate/1` pure and its present unconditional enabled-route denial
while admission wiring is incomplete. Its broker callers run more than once per
listing/claim; spawning probes there would add unnecessary idle work.

First implement the same-process compatibility guard for FILE_SOURCE and REVIEW
initialization. Reuse the actual `initialize` response, reject before thread creation
and model execution, and leave generic/legacy initialization unchanged. Validate
required field types, supported macOS/Unix platform, expected canonical Codex home,
and the observed 0.160.0 user-agent pattern. Reject unknown versions/forms with a
specific compatibility reason. Do not interpret version matching as sandbox proof.

Use the existing fake worker server for supported/malformed/version cases. Assert
the observed requests stop before `thread/start`/`thread/resume`/`turn/start` on
rejection, and preserve existing effective-profile/config/account/catalog checks
on the supported case. Run its focused callers, then frozen adversarial review.

Subsequent admission wiring must cover supervisor startup, typed broker parent/MR
claims, direct scheduler ticks/parent/worker steps, and actual worker initialization.
Readback-only reconciliation and historical receipts remain usable during rollback.
Do not invent a supplied capability boolean, receipt-token cache, or new queue.
The separate no-model startup check must not be repeated for idle/list ticks.
Removing the unconditional policy denial remains gated on consistent caller
admission and the remaining acceptance checks, not this first worker-only unit.

## Owned-worker gate implemented

V1 FILE_SOURCE/REVIEW initialization now qualifies the actual response on the same
owned port used for subsequent configuration/account/thread operations. It requires
binary runtime identity fields, exact Unix/macOS platform, the observed delimited
`symphony-orchestrator/0.160.0 (` prefix (at most 2,048 bytes), and absolute canonical
Codex home matching the current environment/default. It rejects before `initialized`
and thread creation; failure closes the owned port. Generic initialization remains
unchanged. Existing effective-policy, model, effort, cwd, roots, account and catalog
checks remain required.

RED seed 436690: the old code admitted a REVIEW worker with an empty initialization
identity. The corrected fixture supplies all later responses, so this was not a
timeout caused by a missing fake catalog. GREEN seed 162718: six focused tests pass,
including the seven-row malformed/unsupported REVIEW table, supported REVIEW, and
FILE_SOURCE startup/version-denial checks. The two complete affected files passed
79/0, seed 802297, in 68.9 seconds. Following lint-driven equivalent helper extraction,
the final focused group passed 6/0, seed 777786, in 18.3 seconds. Public specs, strict
Credo (6,155 modules/functions), and whitespace checks passed. Independent frozen
review accepted both the original check and equivalent final helper extraction.

Fresh installed-runtime probe `sandbox-defaults-runtime-init-20261006` passed 1/0,
seed 20668, in 2.4 seconds. The real 0.160.0 REVIEW worker passed initialization and
effective-policy checks; actual default-profile commands demonstrated write/network
denial and controlled Git reads. No model turn or per-command permission override
was used. The captured stopped receipt records exit 0 for owned PID 55501 and
thread `01a11281-cd36-7df3-b873-3bc192324317`; issued evidence records model_turns 0.
Raw records remain under `/private/tmp/symphony-u7-native-capability.CXdv7U`.
This bounded native REVIEW result does not prove a new complete FILE_SOURCE lifecycle,
Desktop interaction/restart acceptance, or production enablement.

U7 item 4 is still incomplete: consistent startup/broker/direct-scheduler admission
must be wired without per-idle-turn probing or supplied capability flags. The pure
Policy rejection and default-disabled production configuration remain unchanged.

## No-model runtime primitive and owned shutdown

`AppServer.check_ticket_runtime/1` now starts the configured process in a canonical
existing directory and sends only `initialize`. It clamps an inherited deadline,
restores the caller's deadline, and returns no transferable admission token. No
thread, model turn, or connector operation is requested.

An adversarial review found that closing the Erlang port alone did not prove OS
termination. The strengthened existing test failed (seed 597428) because no TERM
receipt existed. The primitive now captures its owned PID, normalizes initialization
exceptions, rejects cached/queued spontaneous exits, signals the same owned process,
and awaits its exit status before returning. Shutdown uncertainty fails closed;
the ordinary worker shutdown implementation is unchanged. The fixture checks both
TERM observation and disappearance of the exact PID on supported/rejected identities,
plus early exit and valid-response-then-exit cases (status 0 and 1).

Final focused regression: 1/0, seed 74207, 3.1 seconds. The affected files passed
80/0, seed 686752, 67.5 seconds, on the preceding shutdown revision; that suite was
already running when the final spontaneous-exit check was added. The final check is
covered by the focused regression, not claimed as a fresh full-file result. Public
spec checks, strict Credo (6,161 modules/functions), and whitespace checks pass.
Independent frozen-source review accepted the final shutdown delta; no concrete
blocker remains in this primitive. The reviewer did not run tests or native calls.

Fresh installed-runtime fixture `sandbox-defaults-runtime-stop-final-20261006`
passed 1/0, seed 928507, 1.9 seconds, after the final source change. It called this
primitive before the existing native REVIEW sandbox checks; real default-profile
write/network denial and controlled Git reads still passed. The separate runtime
receipt reports model_turns 0. Evidence remains in the existing synthetic scratch
directory. This does not prove startup/broker/scheduler wiring or production rollout.
