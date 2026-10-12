# U8b amendment reservation acceptance

Local reservation packet accepted; critic execution, Jira effects and amendment
application are not yet implemented. Native acceptance remains separate.

Migration 29 adds a command-keyed amendment journal. Reservation validates the
accepted native singleton proposal and current binding inside one immediate
transaction. A partial unique index and lifecycle validation permit one active
amendment per run without limiting the run to one amendment ever. Replay and
getter validation bind exact normalized proposal bytes and digest, not merely a
self-consistent record checksum. No delivery/writer/lease state is changed.

Independent frozen Sol review accepted the final packet after ownership,
transaction-boundary, migration-preservation and getter-integrity findings were
fixed. The writer reported 38 command tests passing and formatting, compile,
specs, strict Credo and Dialyzer passing. Root separately observed targeted
inactive-owner, association-drift and populated-v28 migration checks: session
80107, seed 774312, three tests, zero failures. Root observed getter regression:
session 35757, seed 774313, one test, zero failures (37 excluded).

Frozen production SHA-256 fingerprints:

- `store.ex`: `754940a38b521c6b95a416109020d28b1e7dca79dbfbf828f66d898634eb7629`
- `ticket_chat_commands.ex`: `a353b68b8dd96086c5f09c92fa8fb2cb12092acef55558e29b2153d584476481`
- `ticket_contract_amendment.ex`: `297c01bbc124741d81fc89c31701d234c471a9c2e94af57fd41ac6f811befc82`

Following the user's test-frequency instruction, the full suite is deferred to
the slice boundary. These targeted results do not establish whole Slice 4 or
deployed/native acceptance.
