# Plan 006 U2 — validator packet and declaration hardening

Status: READY_FOR_INDEPENDENT_REVIEW; implementation only, not Slice 3 acceptance.

## Frozen source

Branch `cgable/desktop-owned-ticket-chat-v1`; HEAD remains
`52a978818875c59ccf2758ed1b728bb23e33f631`.

| File | SHA-256 |
| --- | --- |
| `elixir/lib/symphony_elixir/factory/contract.ex` | `7d92670793e8fb0d63a53a54dc02315029b6410db1f05588fa21ba35a02f5d95` |
| `elixir/lib/symphony_elixir/factory/ticket_worker_runner.ex` | `4184dc4284c241b8fae46279d88b1feac450fb5d2ee2b0de9b5015c6d1d49e1d` |
| `elixir/test/symphony_elixir/factory_contract_test.exs` | `aece7665949b0e0ac74ecc1418a26f6dd774b50b961cd051fce8f619caf807ee` |
| `elixir/test/symphony_elixir/factory_ticket_worker_runner_test.exs` | `92be24cfce06f76c7fdc3d33fcc343b0473f0921d1b25612b3d2bc60a554fb1c` |

The two source/test files with untracked status were already untracked in U0; the
other two were already dirty. No unrelated working changes were staged, reset or
reverted. This unit adds only the two source fixes, two focused HTML-comment tests,
and assertions in the existing candidate regression.

## Behavior changed

1. Before base ancestry/packet serialization, only `manual-validator` now requires a
   candidate SHA matching exactly 40 lowercase hexadecimal characters. Nil returns
   `:manual_validation_candidate_missing`; malformed values return
   `:manual_validation_candidate_invalid`. Other roles preserve their prior behavior;
   the regression proves a writer packet can still carry a nil candidate.
2. Manual-validation readers now reject comment-hidden headings/declarations instead
   of treating HTML-comment content as contract data. Prefix scanning ignores comment
   delimiters inside closed fenced examples, accepts ordinary closed comments before
   the section, and rejects unmatched/nested delimiters. Any HTML-comment delimiter
   inside the parsed validation section is unsupported. The same guard is used by
   `manual_validation_required/1`, so scheduler/recovery callers cannot skip required
   validation based on a commented-out `Required: no` declaration.
3. No Markdown renderer, contract format, role policy beyond the candidate guard,
   worker launch, delivery state, Jira/GitLab, or deployment behavior was changed.

## Discriminating tests

| Regression | Public seam | Buggy behavior observed before fix | Fixed behavior asserted |
| --- | --- | --- | --- |
| Nil/malformed validator candidate | `TicketWorkerRunner.packet/4` | Nil produced a serialized packet with `candidate_sha: null`; the new regression failed. | Nil and malformed shape/uppercase/nonhex/short values return precise errors; writer still accepts nil. |
| Entire section commented out | `Contract.manual_validation_required/1`, `manual_validation_definition/1` | Hidden `Required: yes` was accepted and parsed declarations were returned, including `database_migrations: "none -->"`. | Both readers reject with `manual_validation_format_unsupported`. |
| Comment opens in one field and hides later fields | Same public contract readers | Hidden teardown/database fields were returned as declarations. | Both readers reject the section. |
| Compatibility | Same public contract readers | N/A | `Required: no`, closed comments before the section, and comment-looking text in a closed fence remain accepted. |

## Test-first evidence and checks

Red evidence: the focused baseline recorded in U0 failed the nil-candidate assertion;
the candidate regression also failed by receiving a packet containing `null`. Each
HTML-comment regression independently failed before the parser fix: the hidden section
and hidden later fields were accepted as `{:ok, definition}`. A further direct-reader
regression showed `manual_validation_required/1` returned `{:ok, true}` for the fully
commented section. These tests were not weakened to obtain green.

Green/static checks from `elixir/`:

```text
mise exec -- mix test test/symphony_elixir/factory_contract_test.exs test/symphony_elixir/factory_ticket_worker_runner_test.exs
38 tests, 0 failures

mise exec -- mix specs.check
exit 0; all public functions have @spec or exemption

mise exec -- mix format --check-formatted
exit 0

mise exec -- mix credo --strict
exit 0; 5,346 functions checked, no findings

git diff --check
exit 0
```

Earlier intermediate Credo findings in the U2 draft were corrected before this freeze;
the result above is the final strict-Credo run. Full `make all`, Dialyzer and the live
validation/controller acceptance were not run and are not claimed.

## Boundaries and reviewer request

No worker/model turn, external connector, Jira, GitLab, Slack, production ledger,
deployment, commit or push was performed. Review this exact four-file hash set against
U2 requirements. In a disposable review copy, independently verify at least one buggy
baseline fails and the frozen fix passes for each behavior. Pay particular attention
to HTML-comment state across fences, closed comments before the section, duplicate or
unmatched delimiters, and the public `manual_validation_required/1` callers.

Reviewer verdict required: `ACCEPTED`, `FIX_REQUIRED`, or `NEEDS_DECISION`. No U3 or
other implementation unit is authorized by this receipt.

## Independent review result

Verdict: **ACCEPTED** (GPT-6.1 Sol, high; fresh read-only review).

- Four frozen hashes matched before and after review.
- In a disposable copy, the U0 source made the three focused regressions fail;
  restoring the frozen implementation made all three pass.
- Additional adversarial parser cases: U0 produced 4 failures out of 5; frozen source
  passed all 5, including hidden `Required: no`, nested/unmatched delimiters, ordinary
  closed comments, fenced literal delimiters, and optional-validation compatibility.
- Frozen focused suites: 38 tests, 0 failures. Specs, formatting, strict Credo and
  whitespace checks all exited 0.
- Reviewer confirmed scheduler/recovery callers propagate validation parse errors
  before state changes. No U3, live operation, full gate, commit or push.
- Bounded parser limitation: an unpaired fence-looking line inside an HTML comment
  remains unsupported (also unsupported in U0 definition parsing); both public
  readers fail closed consistently. This is not a full Markdown parser.

Review snapshot: `/private/tmp/symphony-u2-independent-review.Tz915S/elixir`.
