# U7 MR read transport

The user approved ephemeral read-only connector sessions rather than a new Desktop
broker read bridge. The immutable controller receipt remains authority; the new
session supplies only transport for the existing catalog-qualified MR collector.

Implemented `AppServer.with_gitlab_read_session/2`, with GitLab-only startup and
unconditional session closure. Scheduler MR adoption opts into this route only
after a successful original result has qualified. No model turn, controller
resume/fork, source worker, live connector call, deployment or route enablement was
performed in this packet.

Fake app-server transport tests cover success, error, exception and startup failure,
actual two-call read transport and port closure. MR-only collection and ordinary/
preflight adoption regressions retain current candidate, physical checkout,
controller claim and human-state checks. Independent read-only review accepted the
source delta with no reproducible blocker.

Transport checks passed separately (2 tests, no failures); MR adoption/collector
regressions passed (18 tests, no failures, seed 706547). Specs check passed.

The adjacent MR argument formatter is implemented and independently reviewed.
Formatting validates the immutable typed request but is not issuance authority.
`TicketMrOperation.claim_followup_args/4` formats the current row and claims it
inside one transaction, returning arguments only after commit. Claimed/restarted
requests cannot reconstruct a send through this entrypoint. The existing lifecycle
test exercises trigger-aborted claims, valid exact arguments and restart rejection;
no additional fixture/model work was created. Formatter/adoption regressions passed
(6 tests, no failures, seed 214513), and the atomic claim test passed (seed 740177).

Native pending/CLI/send integration, CI/Jira joins, combined lifecycle acceptance
and the final quality gate remain pending. This receipt is local test evidence,
not supported-runtime acceptance or production readiness.
