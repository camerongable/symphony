# Typed MR request preparation and original-request reuse

2026-10-05. TicketMrOperation.prepare loads the current ordinary run and derives
the stable semantic request key before rebuilding prompts, models or controller
context. If that exact key exists, it validates and returns the original request;
corrupt or mismatched original metadata fails closed without generating another
key or replacing the request. Existing readback does not require fresh Jira,
enabled admission or model-route resolution, but still requires the persisted
authorized Required:no contract, DELIVERY/V1 mode and validation flag zero.

New preparation requires Desktop broker transport, an enabled allowlist, fresh
ordinary admission and exact stopped-push/remote proof, a known controller prior
turn and the configured orchestrator route. It reuses the existing MR prompt,
controller receipt formatter and Desktop payload builder. Optional operation
metadata is absent for legacy callers, preserving their existing payload hashes.
There is no arbitrary ControllerTask request-key override.

Before inserting into the existing queue, a transaction rechecks the complete
run and control snapshots and the global shared-controller busy fence. It does
not launch a model, change delivery/source-writer state or create another queue.
Tagged V1 controller requests remain quarantined; issuance/readback permission
exceptions and receipt adoption are still pending.

Independent read-only review found missing transport and persisted ordinary
eligibility checks. Both were repaired and accepted. The final typed lifecycle
test passed 1/0 (seed 752892, 24.1 seconds), proving disabled and app-server new
admission rejection, unrelated-controller busy rejection, one routed Luna/low
request, same original pending request after controller advancement with disabled
policy/expired proof/invalid model config/different supplied description, changed
validation rejection, and corrupt-original metadata rejection without replacement.
Existing controller/runner suites passed 21/0 (seed 261086, 7.9 seconds).
Public specs, formatting, strict Credo and whitespace checks pass.

Frozen source SHA256:

- `ticket_mr_operation.ex`: `ede52251ed5369652cae49a5861d7b8771a85d035fd2db4286a1f19a317312e0`
- `desktop_stage_runner.ex`: `22830ac8ba8e0f81ca17012ead60eec68b9afaae8c564d4497b0b458caca8ff2`
- `controller_task.ex`: `51bdcdea454aa9254bb8671df30e3a8aac541207f422fc6a0a689baa11d4964a`

All source pushes remain disposable local-fixture operations. Internal read-only
subagents reviewed source; no production Desktop turn, live connector, deployment,
commit, production push or production-ledger mutation was performed. This is not
native issuance acceptance, current remote-MR qualification or completed U7.
