# U11 exact-current plain-VM replay preflight

This refresh supersedes the historical U10 source fingerprint for plain-VM
preflight only. It does not establish restricted-broker or native acceptance.

Frozen input/evidence: `/private/tmp/u11-current-replay.aoL1GC`, copied durably to
`/Users/cgable/Repos/symphony-u11-review.ktOG3N/recovery-evidence/current-replay-aoL1GC`.
The accepted earlier trace harness was reused against exact-current Store and
TicketContext, with copied synthetic valid/incomplete ledgers via SQLite read-only
backup. No live factory ledger, source checkout or chat was mutated.

Source SHA-256:

- Store: `aee10bc451a74bc2d3817b5489f88784801fc1d0636c153b116f9127e845d24f`
- TicketContext: `db5accb4c79b2e3bd30805349e7e7fca6b5854302d6168140c99db260eee8822`
- Final harness: `d582239b88925f6e5b9aa9b853cf6af2332f69d6be4e507e51771617255034c9`

Root final session27253 exit0. Command: plain `mise exec -- elixir` with the
implementation's compiled dependency paths, not `mix run`. The harness explicitly
compiled the frozen modules; expected redefinition warnings were emitted.

Assertions/results:268 AppServer function trace matches, one open_port match;
zero replay launch calls; separate `/usr/bin/true` positive control produced one
launch call. Valid and incomplete fixture databases remained byte-identical;
incomplete schema was rejected. Three retained worker records were read. Context
serialized size10,343bytes, below16,384. Mix and Symphony applications did not start.
Trace delivery barriers were used before both event collections.

Valid ledger SHA before/after:
`5d565eb6c6264931459ae9a632cf11d933f1206bc8336bb8bbfdaa937dbce01f`.
Incomplete ledger SHA before/after:
`b657031dfb458b7efb32a8206f8268cd604469677c921fe7390bd1ac69ee1dc8`.

Independent read-only evidence review PASS. Both fixtures passed SQLite integrity
checks and had migrations1–36; the incomplete fixture lacked consumed_at. Limits:
tracing covers the caller and new descendants, not pre-existing processes or the
entire VM. Hash assertions cover main DB files, not WAL/SHM sidecars (the inspected
WALs were empty). Three workers is reported, not separately asserted. Other
supporting BEAM modules were not individually fingerprinted in this packet.

No model turn, native call, connector call, real-ticket action, deployment, commit
or push occurred. This is bounded plain-VM evidence, not native acceptance.
Coverage99%, full quality acceptance and budgeted actual native/UI proof remain open.
