# MR fresh-request preflight and human-state preservation

2026-10-05. Continued U7 from typed MR request preparation. Added the read-only
`TicketMrOperation.check_new_request` seam. It validates the original intact
request, exact typed binding and required readback calls, Desktop transport and
enabled allowlist, fresh ordinary authorization and completed-push/remote facts,
and the original controller prior turn. It rereads the complete request and
controller snapshot before returning. A pending request with any claim, output,
thread, turn or native observation is rejected as already issued.

This is preflight only: it does not claim, send, change a run, issue a permission
token, or lift quarantine. Future claim must repeat authoritative checks inside
its transaction, record durable claim evidence, and obtain fresh owning-Desktop
idle/empty-queue observations. Interrupted claims must never be rearmed. The
production runtime-capability rejection remains unchanged.

The shared MR prompt now requires existing-MR readback before mutation, blocks
ready/reviewer-assigned/closed/merged or ambiguous MRs without replacement, and
requires full draft title, draft flag and empty reviewers together on every
already-reviewer-free draft update. These are prompt requirements, not a proof
that native GitLab mutation behavior has passed acceptance.

Independent read-only review accepted the change and the small shared admission
helper extraction. Initial strict Credo found complexity/line-width issues;
extraction removed them without changing policy. Specs, strict Credo, formatting
and git diff whitespace checks pass. The targeted MR lifecycle test initially
passed 1/0, seed 807841, 25.9 seconds; the final post-extraction run passed 1/0,
seed 759800, 26.1 seconds. No native paid turn, production connector call, deployment, commit or
remote production push occurred.

Frozen source SHA256:

- ticket_mr_operation.ex: e154cab4522497b98900e59078d9b3fafaaefacc5b628acf2fc5612d07a77c7e
- prompt.ex: 06c638e563d249b1850901e8aaa21b2dfe44ee8feb550f99cff2316fc9d1117c
- factory_ticket_worker_lifecycle_test.exs: c9fef07e6c1d7a18c3446fb12c64a99ecfaba6b7394401074a8fcc17f39892ad

Next: durable typed MR claim receipt and request-only native readback, preserving
newer controller state. Then result adoption separate from Jira mutation. Slice
3 remains incomplete; Slices 4/5 and final runtime acceptance remain pending.
