# Plan 006 U6N — ordinary `Required: no` chat eligibility

## Scope

Authorize only an exact DELIVERY run with `TICKET_SUPERVISOR_V1`, stored
`manual_validation_required = 0`, and the latest authorized contract recovered from
the stored Jira snapshot exactly matching the run's issue, revision, SHA, and Markdown
and parsing to `Required: no`. `TicketChat.reserve/3` rejects every other case before
any chat/run/request write. `Contract.authorized_from_snapshot/2` proves marker and
draft consistency within a supplied snapshot; this unit also checks the snapshot issue
key/id. It does not refresh Jira or independently prove where the snapshot came from.
The caller provenance/fresh-snapshot requirement belongs to U7 scheduler integration.

This packet does not remove the issuance fence in `DesktopRequest`, change scheduler
transport validation, launch a worker, enable runtime routing, or change Required: yes
behavior. The scheduler is currently the trusted run constructor; U6N validates its
persisted evidence at the reservation boundary. U7 must preserve fresh Jira admission
and call U6N only with the scheduler-owned run.

## Files and symbols

- `elixir/lib/symphony_elixir/factory/ticket_chat.ex`
  - `TicketChat.reserve/3`, `reserve_transaction/3`, `validate_run/2`
  - new public predicate `ordinary_delivery_eligibility/1`, with adjacent `@spec`
- `elixir/test/symphony_elixir/factory_ticket_chat_test.exs`
  - existing `register_run/4` fixture and targeted admission/rejection cases
- `elixir/test/symphony_elixir/factory_ticket_chat_commands_test.exs`
  - one fixture expectation now asserts parsed no-validation intent, not obsolete prose
- `elixir/test/support/ticket_chat_fixture.ex`
- `elixir/test/support/ticket_worker_fixture.ex`
- `elixir/test/mix/tasks/factory_desktop_test.exs`
  - shared reservation fixtures must provide an exact `Required: no` contract
- `elixir/test/mix/tasks/factory_ticket_test.exs`
- `elixir/test/symphony_elixir/factory_worker_evidence_test.exs`
- `docs/desktop-ticket-chat-progress.md`
  - record the ordinary-only boundary and explicitly deferred validation track

Frozen pre-edit SHA-256 for this unit (the broader Plan 006 manifest does not cover
these dirty/untracked reservation files):

| File | SHA-256 |
| --- | --- |
| `elixir/lib/symphony_elixir/factory/ticket_chat.ex` | `5a3885568230577a05e16f94fe072c1e1a62ab4de56c4f4507465287b1ce090a` |
| `elixir/test/symphony_elixir/factory_ticket_chat_test.exs` | `29fade4359c3bc9504352e615fe8ea7e3d6b1c6462620a91f2927c3233283c1a` |
| `elixir/test/symphony_elixir/factory_ticket_chat_commands_test.exs` | `9e62a43715dcd96e8bec2756c9f90ff091b52155bbe5c59d007475e102e484a4` |
| `elixir/test/support/ticket_chat_fixture.ex` | `8b148d14f5720d413e8adb0560d40ac6b8b5014dc26fe01988bf8e9052388c03` |
| `elixir/test/support/ticket_worker_fixture.ex` | `6fe004859b155944cf1ff75199d4219c6853f5c12e58e7c31127394f547bef83` |
| `elixir/test/mix/tasks/factory_desktop_test.exs` | `17ef409c6969c24c5a90d43c11c33f5f824dc69f996be208730b1eed7477e58b` |
| `elixir/test/mix/tasks/factory_ticket_test.exs` | `62d4fbd4a9ee04f76eaf3bb1f95702164f2989d58cddc20ecd305ec670f46b9b` |
| `elixir/test/symphony_elixir/factory_worker_evidence_test.exs` | `eac2f0b08001da74f0ff7b0760ae07e48bb55f77f5dc2c9979f24224204d0802` |
| `docs/desktop-ticket-chat-progress.md` | `271fee87480573bcdacfb30e1a1a7f01b8033fc1e81dfd1e90b4f49c8d309bdc` |

No other files, schema migration, UI, policy, scheduler, broker, or external connector.

## Behavior contract

`ordinary_delivery_eligibility(run)` returns `:ok` only when all are true:

1. `kind == "DELIVERY"` and `execution_mode == "TICKET_SUPERVISOR_V1"`.
2. `manual_validation_required == 0` exactly; `nil`, `1`, booleans, or other values
   are not coerced to false.
3. Decode `snapshot_json` as a map with `key == run.issue_key`, `id == requested issue_id`,
   and a list-valued `comments`. Require every comment entry to be a map with a binary
   `text` field. Reject malformed shapes before invoking Contract APIs so malformed
   persisted data cannot raise through `Regex`/`String` functions or become empty input.
4. `Contract.authorized_from_snapshot(snapshot, issue_key)` must return a contract whose
   issue key, revision, SHA, and normalized Markdown equal the corresponding run fields.
   This checks marker/draft consistency inside the persisted scheduler snapshot and
   catches detectable stale issue/revision rows. It is not a live Jira freshness check.
5. `Contract.manual_validation_required(authorized.markdown) == {:ok, false}`.

Every failure returns a stable tagged error. `TicketChat.reserve/3` propagates it before
reserving identity, linking the run, or enqueueing a Desktop request. The ticket chat
must not be mistaken for an execution approval: the existing runtime fence remains.
Repository tests using shared parent fixtures must use bound no-validation DELIVERY
runs; no production fixture may omit the explicit decision.

## Test plan

Extend the existing ticket-chat regression and shared fixtures to cover:

- valid digest-bound `Required: no` delivery is eligible and can reserve;
- `Required: yes`, absent/malformed decision, mismatched persisted decision, missing or
  marker/digest-inconsistent authorization, malformed snapshot and malformed comment
  payloads, stale SHA/revision/issue, wrong snapshot identity, wrong run kind, and
  legacy/unknown execution mode reject;
- every rejected reserve leaves `ticket_chats`, `ticket_chat_runs`, and
  `desktop_requests` empty;
- already-existing disabled-issuance assertion still rejects `DesktopRequest.claim/2`.
- shared command/context/worker fixtures still build a valid no-validation parent.
- run the changed fixture consumers: ticket-chat commands/context/outbox, Desktop CLI,
  ticket replay CLI, worker runner, worker evidence, and one AppServer test that boots
  a parent.

Use a small fixture helper that creates bound contract text and derives its digest once.
Do not duplicate larger test scaffolding. Test exact public outcomes and DB effects, not
implementation source strings.

Run only these focused tests:

```sh
cd elixir && mise exec -- mix test test/symphony_elixir/factory_ticket_chat_test.exs
```

Also run the directly changed fixture consumers: `factory_ticket_chat_commands_test.exs`,
`factory_ticket_context_test.exs`, `factory_ticket_chat_outbox_test.exs`,
`mix/tasks/factory_desktop_test.exs`, `mix/tasks/factory_ticket_test.exs`,
`factory_ticket_worker_runner_test.exs`, and `factory_worker_evidence_test.exs`; run
the single AppServer parent-fixture test by its test name/line. Do not broaden into
unrelated scheduler or service suites.

Then `mise exec -- mix specs.check`, `mise exec -- mix format --check-formatted`, and
`git diff --check`. No full suite in this unit.

## Safety and stop conditions

- Production/default `ticket_supervisor.enabled` remains false; no startup policy change.
- Required: yes, missing, malformed, legacy, or stale-contract runs stay fenced.
- No scheduler tick, model turn, broker issuance, live ledger, Jira/GitLab/Slack call,
  commit, push, or deploy.
- If existing legitimate callers rely on SPECIFICATION or VALIDATION reservations,
  stop and report the exact caller; do not silently broaden the eligibility predicate.

Reviewer acceptance: frozen diff; independently confirm predicate conditions, pre-write
rejection, no-validation-only boundary, and no change to issuance/runtime fences. No U7
or later source implementation is included in this unit.
