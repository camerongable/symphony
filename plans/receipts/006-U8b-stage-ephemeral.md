# U8b restricted-stage option acceptance

The narrow `StageRunner` option packet passed independent frozen Sol review.
It forwards explicitly supplied `ephemeral` to AppServer; omission retains the
existing durable default, and resume/approval values remain unchanged.

The implementation agent observed 21 StageRunner tests with zero failures,
affected-file formatting, specs and diff checks passing. Root read back the
patch and matching fingerprints rather than rerunning the test module.
Root corrected the reviewer's documentation-only nit afterward; no behavior
changed. Current source fingerprint is
`f7579e3c0d986984aef375e681ebf49239f693b0680e72278f399a194495be7e`;
reviewed test fingerprint was
`24fe0495be16bee8a01efecd96a0a4089ab9d76387e1296fa8e4bce1128b2d43`.

This does not prove native visibility, ephemeral restart history, or a complete
amendment critic. A focused owned-REVIEW receipt test is assigned separately;
durable amendment attempt preparation/claim is the next implementation packet.
No full suite, provider invocation, deployment or production enablement occurred.

## Owned REVIEW receipt regression follow-up

Four tests now pin exact structured output and thread/turn/item/policy/owned-stop
receipt, unproven-stop rejection retaining observed evidence, turn mismatch
rejection, and owned-session stop when the downstream callback raises. They reuse
the existing fake and actual StageRunner branches. The author observed 25 tests,
zero failures, formatting and diff checks passing. Independent frozen Sol review
accepted their assertion strength without rerunning them. Source remains at the
fingerprint above; final test fingerprint is
`f02152e459206faaed99447359357074798c58b77a36635985103c72d1090cf2`.
These tests establish local receipt behavior, not native process-stop or history
persistence proof.
