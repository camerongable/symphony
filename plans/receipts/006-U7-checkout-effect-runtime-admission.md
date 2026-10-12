# U7 new-checkout and pending-Jira-effect runtime admission

Scheduler qualifies the configured runtime in the bound projectless parent cwd
before a missing or unowned PREPARED initial checkout can be claimed. The captured
run is checked again inside TicketCheckout's reservation transaction. Changing the
run during initialization returns `ticket_checkout_run_changed` without claiming
an intent. Issued checkout intents retain their original receipt-only reconcile
path and never launch this probe.

TicketJiraOperation qualifies the runtime immediately before claiming a pending
Jira mutation. It then rereads Jira authority and rechecks the exact advertised
transition before its existing transaction verifies the current run, journal and
checkout. Unsupported runtime leaves an unissued pending journal/reservation for
recovery; it does not send a mutation or admit a writer. Already-observed targets
and uncertain-result readback do not invoke the pending-mutation probe. Actual
worker turns still require their separate same-process initialization/profile gate.

RED seed 748746: both new unsupported-runtime checks failed because the old code
created a checkout/admitted a writer. GREEN seed 704616: both checks passed.
Checkout, Jira and selected lifecycle checks passed 31/0, seed 863468, 62.6 seconds
(34 unrelated lifecycle cases excluded), on the first Jira revision. The final Jira
file passed 12/0, seed 232423, 29.5 seconds, after refreshing post-probe authority.
An actual initialize-marker regression proves a newly observed human ai-blocked
label prevents the pending mutation. Existing restart tests additionally compare
runtime trace bytes to prove uncertain readback does not launch another probe.
The checkout drift regression changes SQLite from the actual fake process before
reply, proving both outside-transaction probing and exact-run revalidation.

Independent frozen-source review accepted the final new-checkout/new-effect gates.
Specs, strict Credo (6,166 modules/functions), formatting and whitespace checks pass.
Normal synthetic lifecycle checks completed in session 75213, seed 611404:
2/0, 91.2 seconds (37 unrelated worker-lifecycle cases excluded). This covers normal
ticks through planner/writer/verifier and the combined synthetic review-ready path.
No real-ticket, connector, deploy or model call
was made by these tests. Production remains disabled. Startup, typed Desktop
claims and full Slice 3 acceptance remain unfinished.
