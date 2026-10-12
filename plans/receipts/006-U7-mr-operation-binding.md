# Exact MR operation binding and stable request identity

2026-10-05. TicketMrOperation binds ordinary MR_CREATING/CI_MR_CREATING authority
to the current candidate, contract/revision/verifier round, canonical checkout,
configured repository/base/GitLab route, parent/controller scope and project,
controller thread/directory, and the exact completed stopped push envelope.
TicketPush.completed_proof reads retained history without changing the run,
source, ownership or receipt and rejects a different current contract/candidate.

The semantic MR request key uses an explicitly ordered identity list and the
existing Desktop key algorithm, excluding the mutable latest controller turn.
It distinguishes normal and CI-preflight operations. Exact request validation
requires the complete immutable binding, payload digest, existing MR schema,
CONTROLLER/FOLLOWUP scope/project/cwd/thread and original prior-turn metadata.
The latter currently requires presence only; issuance-time lineage proof remains
next, and this packet does not claim it.

Review identified a source-directory alias geometry gap and mixed-snapshot race.
Controller geometry now canonicalizes all roots and requires a directory outside
repository/writer roots. Bind compares the push directly with captured candidate
and contract fields, verifies the current remote branch SHA, then rereads the exact
run before returning. The ordinary worker already rejects aliased repo_path, so
the alias regression tests the reusable directory boundary directly—not a proven
whole-factory bypass or a waiver of worker admission.

DesktopRequest ownership now recognizes tagged V1 controller run IDs and V1 issue
keys; these requests remain quarantined. No issuance exception, arbitrary
ControllerTask request-key override, native send, MR adoption, or fresh remote-MR
qualification has been added. Existing shared-controller busy fencing remains.

Verification: completed-push proof test passed 1/0 (seed 686248, 27.5 seconds);
initial binding plus DesktopRequest suite passed 17/0 (seed 392533, 19.3 seconds).
Final repaired MR binding test passed 1/0 (seed 303221, 21.8 seconds), including
stable key after controller advancement, mutation rejection, quarantine, alias
directory rejection, stale authorization, remote ref drift, and a late run-state
change injected by a local upload-pack wrapper. Independent read-only review
accepted the repaired binding scope.

Final binding plus DesktopRequest regression run passed 17/0 (seed 988749,
23.0 seconds), explicitly including an untagged historical controller request
for an issue now owned by V1: it remains quarantined rather than being treated
as legacy issuance authority. Strict Credo, public specs, formatting and whitespace
checks pass.

Frozen SHA256:

- `ticket_mr_operation.ex`: `9a2ecc4ef8817573571d755144c8fe99913449e0bcc50620b956e7ef23a3d622`
- `ticket_push.ex`: `96b9e1f17cced43cfd6de3409a96f39e10dabced2bd135c6a9344805bc02d93a`
- `desktop_request.ex`: `4a5225ce47a70d2b9f66962746573ccd9c637c9bfa29f462291afea8a6ad79aa`

All pushes/remote mutations use disposable local fixture repositories. Internal
read-only subagents reviewed source; no production Desktop turn, live connector,
commit, production push, deployment or production-ledger mutation was performed.
Typed enqueue/claim/readback authorization and exact-result adoption remain next;
CI/Jira joins and combined U7 acceptance remain unfinished. Production V1 remains
disabled, and historical receipts are not current remote-MR qualification.
