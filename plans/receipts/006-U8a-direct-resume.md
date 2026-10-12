# U8a direct BLOCKED-writer recovery checkpoint

Status: local direct-recovery milestone accepted; U8N and Slice 4 remain incomplete.

## Final recovery and regression gate

The final frozen lifecycle/command pair passed in implementation-agent session
49998: 81 tests, zero failures, seed 774310, 840.8 seconds. The command was:

```sh
mise exec -- mix test \
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs \
  test/symphony_elixir/factory_ticket_chat_commands_test.exs \
  --seed 774310
```

The agent observed the terminal result; root verified the frozen test hashes and
received independent Sol test/fixture review PASS. Root did not rerun this
14-minute aggregate gate. Formatting, compilation, specifications, strict Credo,
and Dialyzer passed before this freeze. Production-file hashes below remain
unchanged; final test hashes are:

```text
factory_ticket_worker_lifecycle_test.exs e310193fe00a839099aa38acf64813d6a201cc61b427f43ec798fe8c48fd4b09
desktop_ticket_lifecycle_fixture.ex c9ef02c3cbe3e53b6664240b2a7023f7f1070b4b598e3c3b44af3c046515ca1b
```

Additional production-seam fixtures prove wrong observed session/result thread
and reused-turn rejection; START_SENT repeated polling/reopen without another
start; stale task prompt, generation, and disposition rejection; capacity denial;
and transaction rollback preserving predecessor evidence, task, held ownership,
and ACCEPTED command. A successful retry still uses the same writer thread.
The uncertain-start fixture holds the original process alive: it does not prove
eventual recovery after loss of unbound process/thread identity.

The three prior timeouts were fixture dependency errors: real Scheduler.tick reads
context.ticket_options, not the extra tick keyword list. Existing bound empty
history readers now occupy the actual caller options, including a later overwrite
in the pending-parent case. The MR native-turn failure was not reproduced in
isolation or the final pair; its historical cause remains unproven. No MR guard
was weakened. The canceled session below remains historical failed evidence,
not a retroactively passing run.

## Frozen-source evidence

Independent Sol review closed the original saved-prompt restart and old-evidence
validation findings, then identified and closed an ordinary RESERVED restart
regression. The final bounded review verified the exact frozen hashes and found
that malformed transferred-resume linkage remains fail-closed.

Root independently ran:

```sh
mise exec -- mix test \
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:429 \
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:474 \
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:497 \
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:556 \
  test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs:605 \
  --seed 774201
```

Session 93178: exit 0; five tests, zero failures, 46 excluded; 31.0 seconds.
These are local production-seam fixtures, not native Desktop acceptance.

The sole implementation agent also reported formatter, warnings-as-errors
compilation, specifications, strict Credo, and Dialyzer passing on this freeze.
Root's earlier Dialyzer session 66546 found four unreachable branches; those
were removed and the final bounded review confirmed no reachable behavior changed.
Do not represent the earlier failing result as a passing root rerun.

## Covered behavior

- Explicit native rework resumes the same writer task/thread with a distinct turn.
- Dirty tracked and untracked files reach the resumed writer; valid COMPLETE
  output follows normal adoption, checks, and controller commit gates.
- Original result evidence remains unchanged; exact transfer linkage survives
  successor consumption and candidate advancement.
- Stale candidate, corrupted old binding digest, and divergent completed-task
  output reject before transfer or rearm.
- A committed transferred RESERVED attempt reuses its exact saved prompt,
  request, and reservation after reopening SQLite; no second transfer occurs.
- Malformed application receipt prevents that recovery until exact proof returns.
- Ordinary RESERVED evidence created through WorkerEvidence.reserve uses the
  normal packet after reopening and reuses its existing request.

## Frozen hashes

```text
workspace_access.ex ae841a4069171c93e066639523aa9d672d1feb218492e680e245d9de501ac310
worker_evidence.ex 3ef3849c49927a7ba0418dc57a4aa391222598b2a91ecbefe66a9f02402d3bb2
ticket_chat_commands.ex fa07223d22b2decbda6d7b36d639c5fba73c56c11217a9086fd8aa180c197990
ticket_worker_runner.ex 5a1c378e069fc10668105640be04a53201accc39e12c4c6ef1245fbdccb95735
task_launcher.ex 7577819d29292f44cebed38022c9d7c0dd5a1419daf74146c1933f13df9c3ca2
scheduler.ex 78763a87ac67fc1584dd2eb6572fafd184c64dd5104f86590d135d9477eb5b1f
factory_ticket_worker_lifecycle_test.exs a0bbcfb8213043c23480a65427934804c753fbcbc6497196e43a413bf1044ec3
desktop_ticket_lifecycle_fixture.ex 3ac91aba78f19004286d5c79209a9c2fd000caa2ec509afd858b90c7aa7df308
```

## Remaining work at the earlier scoped checkpoint (historical)

Wrong observed-thread/reused-turn rejection and START_SENT no-reissue assertions
remain unproven. Complete the remaining bounded admission/rollback adversarial
cases before whole-recovery acceptance.

The earlier two-file lifecycle/commands suite (session 89137) was deliberately
canceled after four failures, without an aggregate summary. It remains non-green:
three native-history fixture timeouts and one MR native-turn mismatch. Resolve
them and rerun; do not dismiss them as unrelated from inspection alone.

Contract amendment, complete ordinary lifecycle/native acceptance, and Slice 5
observability/final rollout checks remain outstanding. No live provider calls,
commit, push, deployment, or production service changes occurred in this checkpoint.

## Current remaining work

Contract amendments and complete mixed answer/action application remain in U8N,
followed by U9N ordinary integration/native acceptance and Slice 5 U10/U11N.
Tagged GitLab MR feedback remains deferred. No native Desktop acceptance,
deployment, or real-ticket trial is established by this local milestone.
