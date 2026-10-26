# Local CI-first candidate

Status: review candidate, NOT deployed and NOT complete for all five repositories.
Immutable source baseline: `/private/tmp/admission-blocker-review.BZQTRk`.
Candidate: `/private/tmp/ci-default-candidate.ErxhPR`.

Source changes: configuration Schema, Policy, new CiPolicy, CiCollection,
ControllerCi, Scheduler, Prompt and five adjacent test files plus one selected
Scheduler regression. No TicketPush or WorkspaceAccess changes.
Baseline and candidate hashes are recorded in `artifacts/source-hashes.tsv`.
Apply only reviewed named patches; active checkout changes are not included.

The schema default is `draft_mr`; omitted repository settings inherit it.
Explicit validated `verification_first` retains old ordering. Unknown repository
policy denies admission before push. Applicable emitted hard jobs plus repository
anchors are required; optional allow-failure jobs are informational, NOT certified
or elevated by this CI gate. Contract-required additional evidence is still the
independent verifier/manual-validation responsibility and is never waived.

Collector completeness requires page 1 with per_page 100/include_retried false,
empty page 2 and unchanged MR/head-pipeline brackets. Proof is bound to project,
pipeline ID/SHA and job count. More than 100 jobs still blocks. Exact merge-result
commit/source-parent proof is preserved; source and pipeline SHA may differ.

Capability limitations: PrePost conditional selectors cannot be safely observed
by this collector; its default CI-first admission is denied before mutation and
the staged configuration explicitly selects verification_first. PrePost anchors
are represented including all four structural unit-test shard names; CI-first
PASS is not claimed. Legacy non-ticket runtime lacks deterministic collection;
CI_PUSHING denies before remote mutation, requiring explicit verification_first.
No live workflow, config, canonical rule/skill, native DB, service or remote was
changed. Shared-policy patch targets only canonical `.agents` paths and the
canonical Symphony workflow; provider copies are never created.

Standalone authorization, verifier-before-push behavior, draft/reviewer safety,
source ownership and manual validation requirements remain unchanged.

Validation: focused 63 tests plus specs.check; all builds/cache writes use
MIX_ENV=test and `/private/tmp/ci-default-candidate.ErxhPR/build-focused`.
Formatting checks only touched files. No broad full suite or live integration.
Policy startup fixture required explicit verification_first for its fake unknown
repository, app_server transport field, and ReadStore child expectation already
present in baseline Supervisor; these are adjacent test-only fixture corrections.
Dialyzer and full-suite validation remain deferred; this is not a delivery PASS.
