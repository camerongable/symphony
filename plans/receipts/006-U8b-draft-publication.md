# U8b draft publication/readback acceptance

Accepted locally after frozen independent Sol review. Migration 31 and
`TicketAmendmentJiraOperation` persist exact intent before a one-time claim;
external comment append occurs outside the transaction. Uncertain outcomes
reconcile by reads only, never a repeated write. Only validated source readback
of the exact draft/comment/preimage becomes READ_BACK. Critic preparation now
requires that persisted receipt, not supplied JSON alone. Delivery state and
writer/checkout/candidate/lease evidence remain unchanged.

Writer-observed affected tests: 57/0 before unreachable-arm type cleanup;
directly changed operation tests: 9/0 afterward. Format, strict owned-file Credo,
specs, warnings-as-errors compile, cached Dialyzer and diff checks pass. Root
observed lost-before-write regression: session 29439, seed 774321, one test,
zero failures, eight excluded. No full suite or live external calls were run.

The reviewer found no blocking defect and verified these SHA-256 values:

- Store: `571414b3f00cc7cce1e652ac3136c66a50a3da097023b69b319f3c5c5145549a`
- amendment: `d191e187551a085bcf9b0cd433fcec28aa71c96251c5474fe323bde60136b72c`
- operation: `b57064162b2e7e0b9640b7a45694634e51e2a5a442050c989ff6c561ca3f527f`
- command tests: `84950b4fa945567d9fa0baf66ba48c2b75d3d755473caf5993b1c3124c1795ce`
- operation tests: `fa7b45c18562f1815139dd3b0f75272a9184eff9d7d55e3d2c5cb71f92023021`
- migration tests: `00df98d5d192bd0ba6105c0d9114ebb0f34f1ab8dd98e420b75a315e9068b6b7`

The two-connection case is deterministic stale-observation interleaving, not a
simultaneous parallel execution test. Source-level immediate transactions/CAS
protect the one-time claim; simultaneous integration remains separate evidence.
Critic execution, authorization, amendment application and full native/skill
acceptance are not established by this packet.
