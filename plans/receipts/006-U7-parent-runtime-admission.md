# U7 new-parent runtime admission

The direct scheduler parent entrypoint now prepares and preflights the complete
ordinary-contract, model, reader, route, broker and directory binding before a
no-model runtime probe. Existing run-to-parent bindings skip the probe. A new
reservation compares the full captured run inside its SQLite transaction and
rejects drift as `ticket_parent_run_changed`; the ordinary eligibility and path
checks remain transactional. The optional expected-run argument to TicketChat's
storage primitive adds a restriction, not runtime authority or a bypass token.

Initial registration probes in preflight, outside SQLite and before capacity
cleanup/admission. Its registration transaction calls private prepare/reserve
helpers only, not the public probing entrypoint. Parent insertion failure still
rolls back the run, request and registration event together. Policy's unconditional
enabled-route rejection and production default-disabled settings remain unchanged.

The configured fake executable receives actual initialize RPCs; no injected
authorizing callback is used. Tests cover:

- Supported runtime: one probe across duplicate calls, concurrency and reopening.
- Unsupported runtime: no run, parent, link or request mutation.
- A separate SQLite process changing the run during initialization: no reservation.
- Registration: an independent SQLite insert from the fake process succeeds,
  proving the probe is outside the reservation transaction; the next tick does
  not probe again.
- Unsupported registration: no delivery, parent, request, worker or Jira mutation.
- Existing rollback, reader/model/directory failures, legacy behavior and pending
  parent isolation remain covered.

Evidence: parent admission file 8/0, seed 118877, 2.9 seconds. Scheduler and
TicketChat files plus the selected pending-parent lifecycle case passed 90/0,
seed 291521, 13.4 seconds (36 unrelated lifecycle tests excluded). Final expanded
registration checks plus parent file passed 10/0, seed 723935, 4.9 seconds
(69 unrelated scheduler tests excluded). Public specs and strict Credo passed;
one fixture line-length warning was corrected by an equivalent multiline branch.
Independent frozen-source review accepted the source boundary without running
tests or native calls.

This is the parent reservation/registration portion only. Supervisor startup,
new checkout/first-writer admission, typed Desktop claims, and aggregate acceptance
remain unfinished; neither production enablement nor Slice 3 completion is claimed.
