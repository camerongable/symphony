# Post-planner writer admission bridge

2026-10-05. Internal ordinary-route integration, not production enablement.

The previous worker lifecycle test manually patched ADMITTING_WRITER to WRITING
after planner adoption. Scheduler now calls the controller-owned
`TicketWorkerRunner.admit_writer/4` instead. The transaction requires the exact
current ordinary run/state, ready parent, pinned base, existing clean registered
checkout at the expected branch/SHA, allowed root, maintenance availability,
absence of competing activity/ownership, and shared source capacity. Fresh Jira
authorization is validated immediately before updating state, not discarded after
the initial read. Admission allocates no task, checkout, reservation, or model turn.

WorkspaceAccess exposes the existing capacity predicate and a checkout-admission
projection built from its existing identity/inactivity predicates. Actual worker
acquisition still rechecks and exclusively reserves those facts before source work.

The existing planner → resumed writer slices → blind verifier integration now uses
the actual admission bridge, with no manual WRITING patch. It proves one checkout,
two writer commits, resumed writer identity, exact adoption, no Desktop stage TASK
requests, released role reservations, and a final PUSHING state. Denial tests cover
blocked Jira, insufficient capacity, wrong root and expired authorization, retaining
candidate/run/source and starting no worker. An expired proof is supplied to the
same production admission API, without sleeping or weakening a clock bound.

Verification: focused lifecycle and WorkspaceAccess group **18 tests, 0 failures**
(45.4 seconds); specs and strict Credo pass. Initial test exposed a response-wrapper
mistake; both implementation and assertion now extract the raw RunLedger run.
Independent frozen review accepted the repaired bridge with no remaining concrete
finding. Native calls and remote writes were not performed.

Remaining: initial authorized V1 registration and first checkout materialization,
parent/worker composition in normal ticks after native acceptance, canonical broker
installation, combined acceptance and full quality gate. Existing Policy and active-run
SQL quarantine remain unchanged. This receipt does not complete Slice 3.
