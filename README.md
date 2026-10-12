# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

The local Jira factory keeps source-writing and exact-commit review in isolated
worktrees; contract-only conversations can stay in their repository Project
without allocating a worktree.

A default-off ticket-chat route reserves one projectless Desktop parent per
ticket and repository route, separately from delivery workers. Enabled startup
qualifies the configured runtime before factory children start; individual claims
and worker sessions retain their own fresh checks. This is not production rollout
approval, and the deployed route remains disabled; existing factory runs are unchanged.
Its local context/inbox layer now supports bounded evidence drilldown and staged,
read-backed commands; staging alone never starts work or changes Jira.
Controller updates display an immutable as-of snapshot; direct human commands
still refresh their binding before staging. Presentation ACKs are not delivery
or source-authorization evidence.
Explicit contract revisions and candidate rework can use a read-only native-input
payload preparer, avoiding model transcription while retaining exact completed-turn
and staging-receipt checks. Preparation is not acceptance or permission to work.
The disabled worker layer now reserves one checkout sequentially, binds each
result to its exact role/turn/candidate and owned-process receipt, and supports
same-invocation reconciliation. Required live validation and native shutdown
acceptance remain gates before dispatch integration or enablement.
Native SOURCE startup and retained SOURCE turns now fail before side effects
until containment is proved; read-only review and legacy transport are unchanged.
The disabled FILE_SOURCE adapter instead keeps the worker process read-only and
serves bounded repository reads, hash-checked edits and single-file deletion through controller-owned
tools. Durable edit intent supports readback after lost responses; this is not
native end-to-end acceptance or permission to dispatch real tickets.
Native FILE_SOURCE admission and retained turns are also fenced. Its controller
tools now use a hash-pinned, sandboxed descriptor-relative helper with physical
checkout identity checks. Unproven helper exits quarantine the edit rather than
permitting replay or release. Full shutdown/recovery and controller checks still
require acceptance before workers may use this route.
The disabled controller check catalog now supports one fixed tree-to-tree Git
whitespace check. Candidate-bound, owned-process receipts persist outside source
before reply; recovery reads the same invocation and unresolved checks retain
checkout ownership. This does not yet provide build/test or live-validation
execution, and does not enable native dispatch.
The next test-evidence route reuses authorized GitLab CI preflight rather than
provisioning a new local build environment. A pure CI binder now rejects stale
merge-result evidence unless its source parent is the exact candidate. It does
not fetch CI, attest connector provenance, or authorize a push or draft MR.
Current-pipeline identity is pinned to the MR's observed `head_pipeline`, not
merely a matching source SHA. Controller schema discovery uses an existing
idle MCP session, without waking a model or granting tool invocation access.
Schema 22 adds a fixed controller companion: mutating invocation bindings commit
before launch, child-exit evidence persists before reply, and recovery reads the
same claimed invocation without launching another writer. Controller callback
loss and an actual fixture controller-VM crash are tested offline. A proven
stopped edit can be cancelled only with unchanged source and no invocation
temporary; ownership remains reserved and only a new logical call can retry.
Attested orphan temporaries can now be reclaimed through a fixed helper after
the original writer's actual exit, while the same source reservation remains
held. Original and cleanup helper self-PIDs and durable receipts are checked;
replacement files and unproven ownership stay protected. Full crash/fault and
native acceptance remain unfinished.
Native checkout identity inspection now uses fixed, environment-isolated Git
under a read-only OS profile; configured filters cannot perform side effects.
Controller commit/push/fetch behavior is unchanged. This does not yet implement
the separate build/check or live-validation executors.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
