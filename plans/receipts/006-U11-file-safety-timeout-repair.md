# U11 file-safety timeout repair — ACCEPTED

Scope: one test-only correction. No production code, permissions, deadlines,
source-worker policy or acceptance threshold changed. No further full suite ran.

## Reproduction and measured cause

The combined test selected at line 549 timed out at the default 60 seconds in
the redundant literal gate and in the isolated seed-730843 reproduction.
Temporary instrumentation measured 24 successful reads and 23 successful writes
before interruption: 57.898367 seconds from first path start to final read end.
The individual operations took roughly 1.05–1.51 seconds. An isolated final
integer-path diagnostic passed in 5.4 seconds. This supports cumulative test
work exhausting its budget; it does not prove that every possible Git subprocess
is free of intermittent stalls. The subset diagnostic was never used as full
security coverage.

All temporary instrumentation was removed. Before repair, the restored test
SHA-256 was `e43e55bb4b4ed5783c866af7c64f0fb787a5ea78327cb7c7c00bc61d52fc3dcc`.

## Correction and verification

The combined loop is split into generated read/write tests. Both retain all
24 original paths, denial assertions, secret/symlink/hardlink/directory fixtures,
outside-content checks and `.git` checks. The default 60-second limit is retained.

Exact focused command, with all live tracker test opt-ins explicitly disabled:

```sh
HEX_OFFLINE=1 SYMPHONY_RUN_LIVE_E2E=0 SYMPHONY_RUN_ASANA_LIVE_E2E=0 \
SYMPHONY_RUN_GITHUB_LIVE_E2E=0 SYMPHONY_RUN_GITLAB_LIVE_E2E=0 \
SYMPHONY_RUN_JIRA_LIVE_E2E=0 /opt/homebrew/bin/mise exec -- mix test \
  test/symphony_elixir/factory_worker_file_tools_test.exs:550 \
  --seed 730843 --max-cases 1
```

Exit zero: two tests, zero failures, 97 excluded, 62.2 seconds total. Both
generated tests were selected; this is all 48 operation/path checks, not a subset.
Formatting check passed. Strict Credo passed 69 checks on 240 files, despite the
files-included argument; do not characterize that lint invocation as one-file-only.

Luna independently reviewed the frozen test artifact. The stronger acceptance
review required by Plan 006 used GPT-6.1 Sol/high and returned ACCEPTED. Its
scope was the frozen test-only split, not deployment or a fresh full-suite gate.

Frozen test SHA-256:
`eacecf6574542dbc797b9d73ad7902442d0f677b55f28a9f6bf82727a8d46ab5`.
Artifacts/logs: `/private/tmp/u11-literal-finalgate.Qju3pQ/`.

## Source-scope proof and limits

Reconstructing the old test in an isolated artifact reproduced its exact old
SHA. Replacing only this test's bytes in the current sorted lib/test/priv hash
reproduced the pre-literal-run baseline:
`fa1982665d7cc66e187ccfc0101890bfa57cb5fdf91207ae73010c51958fca1c`.
Thus all other files in the 274-file snapshot are unchanged. Current aggregate:
`36681b3f12bcf7c91a22f8ecd8d170e8b016b558b246084cc79db2945cf856c1`.
Lockfile remains `828d211a3d6a44a4a3c09485c42380936142c57b272613bc84e0a572ef31ebe6`.

The previous complete component gate remains 1,560 tests/zero failures/six skips,
98.32% coverage, plus passing format/lint/Dialyzer/build. Current verification is
that baseline plus this focused accepted correction, not a post-split full run.
The interrupted literal attempt reported 1,503 tests/one failure/six skips; its
eventual shell exit zero is not a successful full gate. Preserve that history.

The new allowance used seven of twenty Luna runs. The final stronger review was
separately routed under the standing Plan 006 model assignment. No additional
native probes, real-ticket actions, commit, push, deployment or enablement occurred.

## Release boundary readback

Read-only release inventory confirmed branch `cgable/desktop-owned-ticket-chat-v1`
and unchanged HEAD `52a978818875c59ccf2758ed1b728bb23e33f631`. At inspection there
were 65 tracked changes and 110 untracked paths, all preserved and unstaged.
Built escript SHA: `6f843e5766f82b60042e771e66298ed8f28dd31bb0c3a589099dd8ae65c048d0`.
The lockfile and frozen repaired test hashes still agree with this receipt.

Plan 006 U11N step 6 explicitly requires separate commit/push/deployment approval,
deployment disabled, synchronous health/context reads, and preservation of the
actual pre-deployment scheduler/broker state. Activation is another gate. The
twenty-run Luna test allowance does not override that release boundary. No
further local source fix or native probe is identified here; no release action
has been performed or represented as complete. A literal post-repair full gate
is not certified by the composite evidence above.
