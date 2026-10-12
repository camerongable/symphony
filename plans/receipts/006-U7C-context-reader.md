# U7c context reader repair

2026-10-05. Repairs the missing callable locator found by the bounded native
parent test; no production enablement or additional model turn.

- `Store.start_read_only` opens only existing absolute regular ledgers with native
  SQLite readonly mode and deferred snapshot transactions. It checks current
  migration receipts, tables, and consumed ticket-reader columns without migration.
  Failed validation closes the newly opened connection, including exceptional paths.
- `factory.ticket` read actions use that opener; only explicit staging uses the
  writable opener. Staging remains PENDING and is not advertised by the locator.
- `TicketContextReader` validates canonical CLI/workflow paths and an explicitly
  absolute workflow database matching the connected ledger. It binds run identity
  and generates a context-only command with base64 argument transport and
  `--no-compile --no-start`.
- Scheduler parent admission requires the locator before reservation. Parent
  identity stores it immutably; CREATE and FOLLOWUP provide it. Historical nil
  binding is not silently upgraded. Missing access is reported as refresh unavailable,
  never treated as proof that an incoming snapshot is current.

Verification: five focused suites pass, **43 tests / 0 failures**; final amended CLI
schema regression separately passes **6 / 0**. Specs, strict Credo, format check,
and whitespace checks pass. Independent adversarial review found and drove fixes
for relative database resolution and transitive verifier-reader columns; final
frozen review reports no remaining concrete defect in this narrow component.

The actual no-compile/no-start CLI read against the retained disposable ledger
also exits zero and returns PROBE-7001 / run `probe`, generation 1, the exact native
parent ID, and unchanged ADMITTING_WRITER state with zero implementation iterations.
Workflow: `/private/tmp/symphony-u7c-native.jZY8Du/READ-WORKFLOW.md`.
This proves local command execution, **not its invocation from the Desktop parent**.

Next native acceptance is separately requested: one bounded Luna Low turn proving
the saved command's actual invocation and fresh output in a synthetic parent.
No full coverage gate, combined ordinary lifecycle, or production acceptance is
claimed. Slice-three and production fences remain in place.
