# U8b automatic authorization/readback acceptance

Accepted locally after frozen independent Sol review. The v33 authorization
journal is separate from the immutable draft effect. Authorization derives from
the validated recorded critic PASS with empty arrays and exact draft/proposal
binding. Capability/runtime checks precede a one-time claim; append occurs
outside the database transaction. Uncertain outcomes read only and never resend.
Readback proves the exact contract, automatic critic task/output-digest marker,
comment identity and unchanged protected source fields. No delivery-state or
writer/lease changes occur.

Author evidence: auth/migration 31/0 before lint cleanup; focused critic/auth
24/0 afterward. Format, specs, scoped Credo, cached Dialyzer and diff checks pass.
Root observed exact authorization path: session 35215, seed 774324, one test,
zero failures, 23 excluded, 1.0 second. Reviewer verified these fingerprints:

- Store: `a4299981fdaaa5dc0a81e74b8873bd6be6e5aa8df4ec54a8c4b7a4206b67ff2f`
- Jira operation: `d9c9f2ede7c87566f9259399eacf1a3548f09915aab5860fd664a31583ac7aed`
- critic/auth tests: `bb747a03b44319f8c539db3e74a6cc81faf4ab11bbad605a23ef6e4c70ce022b`
- migration tests: `dffda7c3826c89cabd7554ec50448afc839379e48812f384306109086b44f312`

No full suite or live external calls were run. Installed-contract application,
mixed/READY command polling, complete native/skill context and full-slice
acceptance remain unproven.
