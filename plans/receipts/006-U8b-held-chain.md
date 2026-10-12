# U8b held amendment lineage: local acceptance

## Scope

Preserve the original stopped SOURCE preimage through repeated held amendments;
validate descendant native input, contract, critic and authorization evidence;
preserve historical getters/replay across READY and fresh stopped-writer
transitions without recursive proof loops or an ambient validation bypass.

## Evidence

- Author observed the selected existing lifecycle case pass: seed `503308`,
  session `4345`, 1 test / 0 failures, 69.0 seconds. It exercises held r2/r3/r4,
  resume/reopen, public READY r5 application and a Scheduler-created fresh
  stopped SOURCE followed by held r6. Corrupting r4 critic evidence or r6
  owner-stop evidence rejects the oldest receipt; restoration recovers it.
  Historical application replay leaves protected rows unchanged.
- Author observed touched formatting, specs, warnings-as-errors compilation,
  strict Credo and diff checks pass. No full suite was run for this packet.
- Frozen Sol 6.1 medium review returned bounded PASS. It checked proof reuse,
  fresh ownership validation, recursion termination and lifecycle compatibility,
  including fresh stopped-source progression without a READY amendment. It ran
  no tests or external calls. Root independently read back the frozen hashes.

Frozen files:

- `ticket_contract_amendment.ex`:
  `7195499916fa2ad7c3b91d60866cbfc0ff5f60321a27b97735baceb954269d84`
- `factory_ticket_worker_lifecycle_test.exs`:
  `aef7ce884bab8d4b294af3dcd74b195992e3c2a0d653f53ea5131c5c06a574d9`
- HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`.

## Limits and next step

READY/WRITING fixture setup is local, not end-to-end delivery/finalization proof.
This accepts only the held-lineage packet, not Slice 4 or native rollout. No
commit, push, deployment, real-ticket mutation or permission change occurred.
Next: corrected non-PASS proposals, mixed commands, scheduler integration and
whole-Slice-4 acceptance; Slice 5 remains afterward.
