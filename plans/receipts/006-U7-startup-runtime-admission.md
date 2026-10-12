# U7 startup runtime admission and static Policy

Policy now validates ticket-supervisor configuration shape without the old blanket
enabled-route rejection. It never spawns a runtime or performs connector/model work.
Default configuration remains enabled=false. Supervisor startup first validates the
complete static policy, then probes once only for an enabled ticket route, using
explicit parent_output_root from the supplied factory settings. Outer/nested string
and atom keys use the same precedence as Policy. No workspace is inferred from
global controller/source identity, and no runtime-qualified flag/token is accepted.

Unsupported runtime or cwd stops startup before Store/Control/Controller children.
The real OTP startup test exposed the preexisting invalid Supervisor callback
return `{:stop, reason}`. Its replacement explicitly exits with
`{:invalid_factory_policy, reason}`, producing the tested typed start_link error.
Static review had missed that callback-contract issue; actual execution caught it.

Evidence: initial RED seed 704749, three failures against the old rejection.
Initial callback-level GREEN 14/0, seed 804029. Actual linked startup reproduced
the callback bug; final startup/static/CLI caller group passed 26/0, seed 810815,
2.7 seconds, after correcting the failure contract and trapping the expected linked
exit in the isolated test process. Tests cover supported string/atom/mixed policies,
unsupported initialize, missing cwd, no storage/name after failed start, disabled
factory/route, and repeated side-effect-free Policy checks. The old CLI blanket-gate
expectation now asserts its actual incomplete-policy rejection before mutation.

Independent review accepted the final error-contract correction, explicitly noting
its earlier static miss. Specs, strict lint, formatting and whitespace checks pass.
The plan's exact named five-file U7 integration group passed 112/0, seed 914254,
57.5 seconds. No production setting, service restart, live connector, real ticket or
model turn was changed. Rollback retains readback and quarantines advancement;
this unit does not claim automatic V1 draining or U11 rollout acceptance.

The source/config documentation now describes these actual gates rather than a
blanket rejection. Full aggregate quality acceptance remains required before
Slice 3 completion and continuation to Slice 4.

Fresh unchanged aggregate gate launched with cached-dependency transport only:
`HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 mise exec -- make all`. Session 3509 is live,
coverage-test seed 554420. Setup/build, formatting, public specs and strict lint
have passed; coverage and Dialyzer are not yet claimed. Dependency resolution
reported cached advisory warnings but left versions unchanged; mix.lock has no
diff. Source stays frozen until this exact handle is terminal. An observation
timeout is not a reason to restart it.
