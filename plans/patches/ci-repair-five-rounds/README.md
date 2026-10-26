# Five total CI repair rounds (unapplied)

This patch changes only `factory.maximum_code_repair_rounds` from two to five.
It has not been applied to the live workflow. Activate it only with independently
reviewed schema47-capable framework bytes and a guarded migration/readback.

Five is the total lifetime round cap for a run, not five additional attempts.
Existing rounds and immutable claims remain consumed. A lower configured cap
still wins. This policy-only patch does not broaden a classifier or rewrite any
immutable diagnosis. Generic all-failure assessment is a separate reviewed source
change: it appends a new versioned assessment beside an old `UNSUPPORTED_FAILURE`
receipt before a normal claim. Raising the cap alone cannot do that. The broader
source, protected-scope, evidence, migration and rollout gates remain required.
