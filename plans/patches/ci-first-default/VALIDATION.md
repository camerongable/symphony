# Supplemental isolated validation

Frozen source and policy patches remain byte-identical:

- source.patch: 620e5f9258d90857dce62719eb020d3110aceed824ceca6d41e40422575edae9
- shared-policy.patch: a2f05fe54006185599f9a674252408608c3ba9e03de06710f3907fda0c7b1b32

Dialyzer PASS: total errors 0, skipped 0, unnecessary skips 0; 6.05 seconds.
Command: MIX_ENV=dev, MIX_BUILD_PATH=/private/tmp/ci-default-dialyzer.zP30tL/build,
mix dialyzer --no-compile --no-check --format short. This reused a read-only copy
of the known OTP 28.5 / Elixir 1.19.5 dependency PLT, digest
a9d751dc28ba656cd895b2171c8b198a822343d26380ca4ee2c6d384a3aa3af9.
No PLT freshness/rebuild claim is made: --no-check was deliberate isolation.
The initial attempt compiled the candidate successfully but stopped before
analysis because the copied PLT was one directory below the effective build root.
The authorized setup correction copied that exact PLT to the expected isolated
path; no repeat compile or large rebuild was run.

Manual-validation-required ticket contracts are not supported by the unchanged
ticket helper route. Existing admission denies them before irreversible issuance:
Scheduler calls ticket_authorization before TicketPush.step; TicketWorkerRunner
authorization and delivery_ledger_facts both require
TicketChat.ordinary_delivery_eligibility. That function requires the stored
manual_validation_required flag to equal integer 0 and independently parses the
confirmed contract to require manual validation false. TicketPush.prepare_new
calls delivery_admission before intent/reservation writes; its issuance recheck
also repeats delivery ledger facts. Therefore the helper's unchanged requirement
for manual_validation_required == 0 is matched before push claim. This does not
claim manual-required ticket execution works; existing unsupported-route denial
and contract manual-validation obligations are preserved.

No helper, active checkout, canonical policy/config, service, native DB or remote
was modified. Source remains a patch-only review candidate, not deployed.
