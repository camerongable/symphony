# Ordinary V1 normal tick join

2026-10-05. A separate bounded V1 advancement phase follows legacy advancement.
Only enabled, allowlisted internal contexts use it; production Policy's startup
capability rejection and default disabled setting are unchanged. Legacy issue
selectors, cleanup, maintenance and feedback quarantine remain unchanged.

Each selected run executes one parent, checkout/admission or role lifecycle
action per tick. Exact role launches are returned in the existing controller
launch accumulator. Pending parent creation reuses its original request. Returned
errors and per-run exceptions retain previous launches/events and defer that run
without preventing subsequent runs. Exception diagnostics retain the class only.

Initial checkout reads an existing remote-tracking base when no immutable pin
or explicit base is present. It never fetches or moves refs; checkout admission
independently validates and stores the exact base. Existing intents retain their
original pin across recovery. The tick's reader reaches fresh Jira admission;
an omitted connector resolves to the existing connector rather than explicit nil.

Verification: scheduler and worker lifecycle suites passed 87 tests, zero
failures (seed 682355, 148.8 seconds). These prove normal tick checkout creation,
planner adoption, writer admission, two same-thread writer slices and blind
verification using one checkout, with delivery explicitly deferred afterward.
The subsequent adoption-exception retry test passed 1/0 (seed 291934), and the
two-ticket pending-parent test passed 1/0 (seed 755680). The latter proves another
ticket's planner launch proceeds and repeated ticks retain exactly one parent
CREATE request. Specs, strict Credo and whitespace checks passed. Independent
read-only review identified the exception boundary; the repair was accepted.

Disabled ticks remain inert, including unconsumed completed evidence. Safe
draining/readback still requires its separate integration packet. Post-verifier
controller delivery/CI/MR joins, runtime capability acceptance, the named combined
U7 lifecycle suite and final full quality gate remain outstanding. No production
enablement, commit, push, deployment or paid native model turn occurred here.
