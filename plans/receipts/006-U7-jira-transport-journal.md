# U7 Jira transport and durable-effect storage foundation

Scope: original Slice 3 Jira start/finalization prerequisite only. No deployment,
installed-provider/config changes, live Jira/GitLab calls, native/model turns,
real-repository commits/pushes or cleanup. Production V1 remains disabled.

## Implemented

- Staged `integrations/jira-mcp/factory_provider.py`, pinned to the installed
  `mcp-atlassian` 0.23.1 API. Reuses its authentication, write-access check, tool
  filters and actual Jira client. Only `ai-running`/`ai-review` add operations and
  bounded factory-label removals are permitted; no whole-field replacement.
- Existing-session catalog-qualified atomic labels, bounded transition reads and
  transition writes. Actual installed transition annotations omit `readOnlyHint`;
  omission qualifies only with explicit `destructiveHint: true`. Explicit read-only,
  nil or unproven annotations reject. Numeric transition input is a primitive; the
  later runner must independently prove the unique advertised `In Dev` target.
- Model-free owned Jira transport, closed on callback return/error/exception;
  startup failure never enters the callback.
- Schema 27 and `TicketJiraJournal`: two fixed operation/effect pairs, immutable
  semantic identity and full drift binding, transactional one-shot uncertain
  claims, fresh exact readback, historical receipt consistency. The journal neither
  mutates delivery state nor authorizes an external call or source dispatch.

## Verification

- Installed interpreter: `python -m unittest discover -s integrations/jira-mcp`:
  **6 passed**. No live calls. Tests use the actual client `update_issue` method
  with only its HTTP `put` mocked; verify exact atomic payload, mounted tool schema,
  readonly denial, version/collision rejection and concurrent-label preservation.
- Focused Elixir group: journal, store migration, Jira connector/reader/writer,
  owned connector success/error/exception and startup-failure transport tests:
  **30 passed, 0 failures**, final seed 695304, 4.2 seconds; 73 unrelated app-server tests
  excluded by explicit line selection.
- `mix specs.check`, focused strict Credo and `git diff --check`: passed.
- Initial journal run exposed an outer-pool access inside its transaction. Changed
  to the leased transaction connection; subsequent 9-test group passed. A later
  regression setup attempted a controller-owned RunLedger field update; replaced
  with explicit disposable-ledger fault injection. Neither failure was a live action.
- Independent primitive review: no must-fix findings; correctly notes this is staged
  transport, not installed/runtime acceptance.
- Independent journal review found four holes: mutable semantic key, pre-claim
  uncertainty readback, unchecked earlier receipts, malformed nonmatching comments.
  All four addressed with focused regression checks. A second review found prepare's
  replay path bypassed receipt integrity; it now uses the same current-row validation,
  with SECOND/COMPLETE corruption regressions. Final read-only re-review accepted the
  delta with no remaining must-fix. Review did not independently rerun tests.

## Still required

No scheduler uses the journal yet. Next connect caller-owned fresh Jira authorization,
exact local checkout reservation, exact stopped push/verifier/MR facts and shared busy
fencing. Only that controller path may invoke the fixed effects, release the exact
reservation and advance to `WRITING`/`READY_FOR_REVIEW`. Reconciliation of an issued
`ai-review` effect must not fabricate ordinary dispatch authorization. Initial baseline
maintenance reservation must bind the pinned base without inventing a candidate SHA.

Then prove the combined lifecycle, install the staged adapter/broker changes under
the relevant gate, run native acceptance and the final unchanged quality gate.
This packet does not complete U7 or Slice 3 and does not enable production.

## Frozen source identity

Base HEAD `52a978818875c59ccf2758ed1b728bb23e33f631` on
`cgable/desktop-owned-ticket-chat-v1`; existing dirty/untracked implementation preserved.
These hashes pin only this packet's source/tests, not the full repository:

```text
c7b5c4eed547dcec59fb4d99bfde67be771088081de89c23497a7c084ace3f91  integrations/jira-mcp/factory_provider.py
af7e03d533ef501c9d491412604d08818f63c9a254744e3c0825ea2db56c2e2b  integrations/jira-mcp/test_factory_provider.py
285bb6465ecdaa61882c5216ec878b3485e9dc1b3a9063c4d0ebe7866f7f03cc  elixir/lib/symphony_elixir/factory/ticket_jira_journal.ex
b10307e68b01a3a105e069e1994a0b73c2b9dcc4da7c64380548643df0222b26  elixir/lib/symphony_elixir/factory/jira_mcp_connector.ex
f32ee1a952ca19e38408a1d9c474acf69c770c4af727225f4a71cd21c867b25e  elixir/lib/symphony_elixir/codex/app_server.ex
7987289971d793ff3b696bc3580f90be70faad1fc81797ab77d3ee85af90a0d5  elixir/lib/symphony_elixir/factory/store.ex
58e27a3ee292a11b1cefc464cff3ff60849e4401e90e122c85702551f971fce0  elixir/test/symphony_elixir/factory_ticket_jira_journal_test.exs
d48ffbaa5c7151e1029fc0a2e5fd7b049a2ed61058502d1329d2b10cdd771d4f  elixir/test/symphony_elixir/factory_jira_mcp_connector_test.exs
80c58caae99856adce37f086342b668858e5ab4585432d1dbb18bd6ae9b8215e  elixir/test/symphony_elixir/factory_store_migration_test.exs
6e0976e870ce4ab170ebd1c9dd5e0f3a07ce4315aded3a6a866c25673f738d8a  elixir/test/symphony_elixir/app_server_test.exs
```
