# U8a BLOCKED writer disposition

Status: accepted locally after focused checks, type check and independent frozen
Sol review. This is a bounded packet, not whole-U8a or Slice 4 acceptance.

## Behavior

`WorkerEvidence.completed_result/2` proves an exact stopped result without adopting
the task. Scheduler intercepts native feature-writer BLOCKED before successful
candidate adoption, and records a bound disposition using the per-run lock and an
immediate transaction. Replay preserves the raw result/digest, run, task,
candidate, dirty/untracked source and held reservation without another worker,
question, commit, Jira effect or release. TicketContext only projects a disposition
whose binding remains current. Normal polling and explicit resume remain separate
unfinished work. No U8c, provider mutation or native probe was performed.

## Evidence

- Writer-reported focused group: 26 tests, zero failures, covering WorkerEvidence,
  normal successful writer, BLOCKED lifecycle and TicketContext.
- Writer-reported final post-guard regression: session 32707, three targeted tests,
  zero failures. Final formatter, strict Credo (623 functions, no issues), and
  specs.check passed.
- Main readback matched all five writer freeze hashes.
- Main Dialyzer 22257 found one unreachable `false` fallback in the scheduler
  transaction. Main removed that branch only; explicit rejection predicates remain.
- Main Dialyzer 74166: PASS, zero errors/skips, 4.58 seconds. Scheduler format PASS.
- Main final focused regression 29529, seed 112009: PASS, three tests, zero
  failures (55 excluded), 7.8 seconds.
- Independent Sol review: bounded PASS. Reviewer checked final production hashes,
  pre-adoption interception, exact COMPLETE evidence compatibility, immediate
  transaction idempotence and stale context rejection; no concrete blocker found.
  Reviewer did not independently rerun tests or make native calls.

## Frozen SHA-256

| File | SHA-256 |
| --- | --- |
| worker_evidence.ex | 54173b05f61767303faaae7a25b5c790d845459d77a6b673fddb28dd7c4d9f69 |
| scheduler.ex | 0de4e53474cd2da743d88264236882ad59106b64d9587c3dd3d90c427681d56e |
| ticket_context.ex | fa87452c4069b7738c1e2a4a682041ea72642ea57860182b574bd0bd3d93a2ad |
| factory_worker_evidence_test.exs | eae56bf54cdab6fa6ee52e8cab592dabaa1b425ab33913f5413aa3621c116773 |
| factory_ticket_worker_lifecycle_test.exs | 20589567d6d752b88e526447825f0b7651c021e80148f2a3f75ef122956efeef |
