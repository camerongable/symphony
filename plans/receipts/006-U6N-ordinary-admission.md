# Plan 006 U6N receipt — ordinary `Required: no` admission

## Scope and baseline

- Result: `ACCEPTED` as a local implementation unit; not delivery-verifier PASS.
- Checkout: `/private/tmp/symphony-ticket-implementation.Pt2zbH/checkout`
- Branch: `cgable/desktop-owned-ticket-chat-v1`
- Base HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`
- Runtime issuance, scheduler routing, policy enablement, commit, push and deploy remain unchanged/not performed.
- Pre-edit hashes for the eight-file U6N packet matched before implementation; see `006-U6N-execution.md`.

## Implemented boundary

`TicketChat.reserve/3` admits only a DELIVERY run in `TICKET_SUPERVISOR_V1` whose
persisted validation flag is exactly integer `0`, whose stored snapshot has matching
Jira key and issue ID and well-shaped comments, and whose internally authorized
contract exactly matches the run's issue, revision, SHA-256 and Markdown and parses
as `Required: no`. Malformed or inconsistent evidence rejects before parent identity,
run link or Desktop request writes. This verifies persisted consistency only; it does
not establish live Jira freshness or prove snapshot origin. U7 owns fresh scheduler
admission. Required: yes, absent and malformed declarations, legacy rows and
non-delivery kinds remain outside the ordinary path.

## Changed-file snapshot after implementation

| File | SHA-256 |
| --- | --- |
| `elixir/lib/symphony_elixir/factory/ticket_chat.ex` | `bede256f36f179fdd4e4bd9ad7ba244dac0648cc08e4d178fe430deaf9e332a3` |
| `elixir/test/symphony_elixir/factory_ticket_chat_test.exs` | `9ec06e690a1dfaad7c43432ba245a162f1705d2e03aa9a197175f96d41f796f7` |
| `elixir/test/symphony_elixir/factory_ticket_chat_commands_test.exs` | `6b3fe83da50365b27f18a4ab9abdd09f086d6e35d017dcd36227746e40ea78a3` |
| `elixir/test/support/ticket_chat_fixture.ex` | `1d068c9b36c0425a8b4f6791be0bd18bdabf2e467205d5dfae3153a32fb0869d` |
| `elixir/test/support/ticket_worker_fixture.ex` | `544926c3268d6750109d01f87e8ca014bd3ae5d4942b87e764e923412939992d` |
| `elixir/test/mix/tasks/factory_desktop_test.exs` | `c096b8e4245e85ae04b303c0d1221703268efcc35634b663acd9d0ff3a72bd43` |
| `docs/desktop-ticket-chat-progress.md` | `091daa5949be2c8531ea1da15bb405d91b4205476eda02f84a5b4e79ead8c0cb` |

## Verification

- Direct consumer test command:
  `mise exec -- mix test test/symphony_elixir/factory_ticket_chat_test.exs test/symphony_elixir/factory_ticket_chat_commands_test.exs test/mix/tasks/factory_desktop_test.exs test/mix/tasks/factory_ticket_test.exs test/symphony_elixir/factory_worker_evidence_test.exs test/symphony_elixir/factory_ticket_context_test.exs test/symphony_elixir/factory_ticket_chat_outbox_test.exs test/symphony_elixir/factory_ticket_worker_runner_test.exs test/symphony_elixir/app_server_test.exs`
- Result: 143 tests, 0 failures (55.3 seconds).
- `git diff --check`: passed.
- Independent frozen local review: ACCEPTED, no code defect found. Reviewer separately passed ticket-chat tests (15/0), direct consumers (63/0), AppServer parent fixture (1/0), `mix specs.check`, format check, and whitespace check; hashes stayed unchanged during review.
- Formal `verify-feature-delivery` outcome: BLOCK because no confirmed Jira contract revision/digest and no committed base-to-head candidate were provided. This is an evidence/packaging limitation, not an implementation finding.
- Full suite and runtime/native end-to-end acceptance were not run. No external calls or mutations occurred.

## Next

Proceed to U7a only after freezing and reviewing its own bounded packet. Keep the
runtime default disabled and do not commit, push, deploy or enable it.
