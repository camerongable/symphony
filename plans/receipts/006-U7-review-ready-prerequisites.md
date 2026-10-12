# U7 review-ready MR qualification and comment compatibility

Scope: original Slice 3 review-ready finalization prerequisites. No live connectors,
native/model turns, installation/config changes, deployment, real-repo commit/push
or cleanup. Production V1 remains disabled.

## Implemented

- Read-only `TicketMrOperation.current_delivery_receipt` qualifies an already
  adopted ordinary MR against the original successful immutable native claim/result,
  current stopped exact-candidate checkout/verifier/push, configured repository/
  project/controller identity, remote branch and two-read MR human state. Request,
  local facts and binding are checked again after external collection.
- Shared binding construction extracted without relaxing actual `bind_current`:
  actual issuance still requires `delivery_admission` and fresh Jira authorization.
  The new read-only path neither grants dispatch nor mutates any ledger/control row.
- Conservative `observed_at` precedes MR reads; `qualified_at` is separate. Neither
  timestamp is permanent mutation authority.
- Comment journal accepts exact normalized Jira-reader `text` (legacy body still
  supported). Every comment must remain well-formed, with one exact match/ID;
  malformed normalized text cannot fall back to a legacy body.
- Pure comment preflight matches locally read installed `mcp-atlassian` 0.23.1
  schema: required string issue_key/body, destructiveHint false, readOnlyHint absent
  or false. Fixed issue/body only; public/visibility overrides and unsafe schemas
  reject before a tool call. Installed provider/catalog/config not modified.

## Verification

The existing ordinary MR lifecycle now checks unchanged run/task/request/claim/
control/access/evidence/event rows, while proving ai-review cannot authorize normal
dispatch. It exercises human MR-state change, claim corruption, checkout replacement,
candidate change and request mutation during remote reads. Preflight lifecycle remains
included to verify dispatch-binding extraction preserves its existing CI joins.

Focused normalized-comment/provider group: **23 passed, 0 failures**, seed 946835.
Extended ordinary lifecycle: **1 passed, 0 failures**, seed 865573, 40.6 seconds.
Final combined ordinary/preflight/comment group: **25 passed, 0 failures**, seed
73657, 91.0 seconds; 30 unrelated lifecycle tests excluded by line selection.
Public spec check, focused strict Credo and diff checks passed.

```sh
mise exec -- mix test test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:817 test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:822 test/symphony_elixir/factory_jira_mcp_connector_test.exs test/symphony_elixir/factory_ticket_jira_journal_test.exs test/symphony_elixir/factory_jira_mcp_reader_test.exs
```

Initial test setup incorrectly used boolean negation on a missing optional tag;
fixed to explicit true comparison. A later assertion incorrectly compared raw
string IDs to normalized numeric MR IDs; corrected to the documented normalized
identity without removing any expected MR fields. No live actions occurred.

Independent frozen read-only review found no authority blocker. It requested
conservative MR timing and the claim/checkout/candidate/unchanged-row regressions;
these were added. Follow-on canonical-comment/append-schema review found no blocker.
Reviewer did not rerun tests.

## Remaining work

The review-ready Jira executor and scheduler finalization are still not wired. They
must consult this exact current MR qualification, retain the maintenance reservation,
claim/comment/readback/label/readback without duplicate uncertain writes, and allow
issued ai-review reconciliation without manufacturing ordinary source authorization.
Fresh target facts and exact release/state update belong in the final transaction.
Shared-controller busy/recovery fencing, combined lifecycle/native acceptance,
installation and full unchanged quality gate remain. Slices 4–5 remain.

## Frozen source identity

Base HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`, branch
`cgable/desktop-owned-ticket-chat-v1`; unrelated dirty/untracked work preserved.

```text
db6ab45e8c6cbb4a3357fd7870908cd164095e9bf23cd4ad3e1170736a5df740  elixir/lib/symphony_elixir/factory/ticket_mr_operation.ex
9535df0409c9ccce2a42f5f47e6f74586c08270650a5e2ecf54fcfa2cc4cd4da  elixir/lib/symphony_elixir/factory/ticket_jira_journal.ex
40a07dd9e7ecf6b449f7200cba154828590acf6d8da661e02cfbb37431be6899  elixir/lib/symphony_elixir/factory/jira_mcp_connector.ex
1e1467fd3b9bff585e1f1a7f40c04616aaa5cf49aad9438b0436b9223a2205b2  elixir/test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs
c450798f05e37e4675b2708696b9820e138f14d3056ce0ede8ec847a0b4b6684  elixir/test/symphony_elixir/factory_ticket_jira_journal_test.exs
18a848324e5ca30ff63510b19c87deb5413a4e17758af995809d5c8077e535f8  elixir/test/symphony_elixir/factory_jira_mcp_connector_test.exs
```
