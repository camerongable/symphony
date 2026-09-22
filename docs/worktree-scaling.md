# Scaling workspaces for the local Jira-to-Codex factory

Status: implemented for the one-host pilot, researched and updated 2026-09-22

## Decision

Keep Git worktrees as the factory's source-isolation primitive. Scale them by
separating **durable ticket state** from **disposable local materialization**:

- Durable state is the Jira key, factory run ID, retained local ticket branch,
  read-back remote branch, exact candidate SHA, merge request, and visible
  Codex task/thread identity recorded by the controller.
- Materialized state is the writer or detached stage worktree, its Bazel output
  base and server, and any optional container used to execute commands.

Use one factory-owned, non-writing Git anchor clone per repository route and
attach one writer worktree per active ticket plus short-lived detached
worktrees for independent verification or validation. Give every concurrently
active materialization its own Bazel output base, but share a bounded Bazel disk
action cache and repository-download cache across the repository. Remove
detached stage worktrees immediately after their stage; remove a writer only
after the controller has proved it clean, inactive, exact-SHA, and remotely
recoverable.

Do **not** reuse branches by switching one checkout under concurrent agents, do
not use `git clone --shared`/alternates for ticket clones, and do not adopt a
container or VM per ticket as the default on this one-host trusted pilot.
Containers should be an opt-in execution profile for dependency or risk
isolation. MicroVMs belong to a later multi-tenant or Linux-worker design.

This is an evolution of the current fork, not a replacement. The fork already
implements a sole writer worktree, exact-SHA detached reviewers, guarded cleanup,
and visible persistent Codex tasks; see
[factory-control-plane.md](factory-control-plane.md),
[worktree.ex](../elixir/lib/symphony_elixir/factory/worktree.ex), and
[cleanup.ex](../elixir/lib/symphony_elixir/factory/cleanup.ex).

## Why this boundary scales

Git worktrees are designed to attach multiple working directories to one
repository. Linked worktrees share the repository while keeping per-worktree
state such as `HEAD` and the index separate, and Git explicitly supports a
detached throwaway worktree for testing without disturbing development
([Git `worktree`](https://git-scm.com/docs/git-worktree)). This avoids
duplicating the Git object database, while still giving each writer an
independent index and filesystem tree.

That boundary matches current coding-agent practice. The Codex app organizes
parallel agents in visible project threads and uses worktrees so agents can
work on the same repository without touching the user's local Git state
([OpenAI, *Introducing the Codex app*](https://openai.com/index/introducing-the-codex-app/)).
OpenAI's agent-first engineering team made its application bootable once per
worktree and tore down each worktree's ephemeral observability stack when the
task finished
([OpenAI, *Harness engineering*](https://openai.com/index/harness-engineering/)).
Anthropic's current Claude Code guidance likewise recommends isolated worktree
checkouts for parallel sessions whose edits must not collide, and recommends a
fresh context for independent review
([Anthropic, *Best practices for Claude Code*](https://code.claude.com/docs/en/best-practices#run-multiple-claude-sessions)).

Codex-managed worktrees also provide a useful precedent for a parked
materialization: the desktop app protects in-progress, pinned, and permanent
worktrees from automatic cleanup, snapshots a managed worktree before deletion,
and can restore it when its chat is reopened
([OpenAI Codex worktree documentation](https://learn.chatgpt.com/docs/environments/git-worktrees#worktree-cleanup)).
Symphony cannot rely on that product-specific snapshot mechanism for its own
CLI-created linked worktrees. Its equivalent must be the controller's recorded
and read-back remote SHA plus deterministic rehydration.

Upstream Symphony requires deterministic per-issue workspaces, preserves them
across runs, constrains the agent cwd to the issue workspace, and deliberately
leaves VCS population policy to the implementation
([Symphony specification at researched revision](https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md#9-workspace-management-and-safety)).
The proposed materialization lifecycle preserves those identity and cwd
invariants while allowing the local fork to reclaim storage sooner than an
always-materialized design.

## Comparison

| Pattern | Parallel correctness | Storage behavior | Security boundary | Fit for this controller |
| --- | --- | --- | --- | --- |
| Linked worktree per active ticket | Independent working directory, `HEAD`, and index; shared repository and refs ([Git](https://git-scm.com/docs/git-worktree)) | One shared Git object store, but one checked-out tree and build-output set per ticket | Filesystem separation, not a hostile-code sandbox | **Best default** |
| Reuse one checkout and switch branches | A branch switch rewrites the index and working tree; Git refuses conflicting local changes unless asked to merge or discard them ([Git](https://git-scm.com/docs/git-switch)) | Lowest checkout count | None; all tasks touch the same files | Serial emergency mode only; incompatible with concurrent durable tasks |
| Independent normal clone per ticket | Independent repository and working tree | Own object store and refs; a same-filesystem local clone may initially hardlink objects, but lifecycle and later fetch/repack state diverge ([Git `clone`](https://git-scm.com/docs/git-clone)) | Still only filesystem/process permissions | Useful inside a container or on another host, but unnecessarily expensive locally |
| Clone using `--shared` or `--reference` | Independent index/worktree with borrowed objects | Saves object storage, but borrower integrity depends on the source object store | No added execution isolation | Avoid: Git warns that source pruning can corrupt borrowers; `--dissociate` restores independence by copying required objects ([Git `clone`](https://git-scm.com/docs/git-clone)) |
| Container per ticket | Independent process/package namespace; source still needs a clone or mount | Read-only image layers can be shared, while each container has a unique writable layer ([Docker storage](https://docs.docker.com/engine/storage/)); checkouts and build outputs still need storage | Stronger than a worktree only when mounts, credentials, and network are scoped ([Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)) | Optional high-risk or reproducibility profile, not the default |
| VM or microVM per ticket | Full guest boundary and independent filesystem | Adds guest-image, memory, startup, and cache-management machinery | Hardware-virtualization boundary ([Firecracker](https://firecracker-microvm.github.io/)) | Defer until untrusted or multi-tenant execution justifies it |

The single-checkout option is especially poor for visible long-lived Codex
tasks: a resumed thread can correctly remember its ticket yet wake into a
working directory that another task has switched to a different branch. A
global checkout lock could make that safe, but it would serialize all source
work and turn task duration into lock duration. It is capacity reduction, not
scaling.

Linked worktrees already provide the safe form of shared Git object storage.
If the factory should stop depending on a developer's checkout, create one
factory-owned anchor clone per route and never run an agent in it. The current
implementation expects a non-bare top-level repository and
`refs/remotes/origin/*`, so a non-writing normal clone is the lowest-risk first
step. A bare anchor can also own linked worktrees
([Git `worktree`](https://git-scm.com/docs/git-worktree)), but removing the anchor's one
checkout would not reduce the per-ticket source trees or Bazel outputs, and it
would require adapting the current repository validation and ref layout. It
should not be the first optimization.

## Bazel: share results, not live output bases

Bazel derives its default output base from a hash of the workspace-root path,
so distinct worktree paths naturally receive distinct output bases
([Bazel output-directory layout](https://bazel.build/remote/output-directories)).
Bazel starts one persistent server per output base, and recommends distinct
output bases when concurrent workflows need independent server state
([Bazel iteration-speed guidance](https://bazel.build/advanced/performance/iteration-speed)).
Each server handles at most one invocation at a time, so concurrent clients on
one output base block or fail fast
([Bazel client/server implementation](https://bazel.build/run/client-server)).
Therefore the factory must never point two live tickets at one output base;
doing so would trade disk for serialization and cross-workflow analysis-cache
churn.

The scalable arrangement is:

```text
factory repository anchor
└── shared Git object database

factory cache root
├── bazel-disk-cache/<repo>          shared, size/age bounded
├── bazel-repository-cache           shared downloaded dependencies
└── bazel-output/<ticket>-<run>-<stage>  exclusive to one live materialization
```

Bazel explicitly documents its filesystem disk cache as useful across branches
and multiple workspaces. Since Bazel 7.4 it can garbage-collect that cache by
configured maximum size and age
([Bazel remote caching](https://bazel.build/remote/caching#disk-cache)). Its
repository cache avoids repeated external downloads across workspaces and is
configurable with `--repository_cache`
([Bazel command-line reference](https://bazel.build/reference/command-line-reference#flag--repository_cache)).

For the pilot:

1. Assign an explicit output base to each writer and detached stage. Include
   repository, Jira key, run ID, stage, and attempt/round in its controller
   identity. Never reuse it while the prior owner is active.
2. Configure one disk action cache per repository route, not per ticket. Bound
   it by size and age when the repository's Bazel version supports the current
   GC flags. A poisoned cache must be removable as one unit; Bazel notes that
   cached outputs are addressed by names and hashes rather than by originating
   build ([Bazel remote caching](https://bazel.build/remote/caching#delete-content-from-the-remote-cache)).
3. Configure one repository-download cache for the host, with its own budget.
4. On detached verifier/validator completion, stop its Bazel server and reclaim
   its exact output base. On writer de-materialization, reclaim only the output
   base derived from that recorded worktree path. Preserve the shared caches.
5. Retain a free-space floor and per-writer admission budget even after cache
   sharing. Cache hits reduce expected bytes; they do not make checkout,
   sandbox, logs, or cache-miss growth free.

Containers do not eliminate this distinction. Bazel documents that ephemeral
Docker runs lose the server's in-memory incremental state even when a shared
cache is available
([Bazel remote caching, known issues](https://bazel.build/remote/caching#known-issues)).
A container profile should therefore use a persistent per-materialization
output volume for the duration of a run and a separately bounded shared cache
volume.

## Containers and VMs are policy layers, not workspace substitutes

A worktree prevents two writers from editing one working directory; it does
not confine processes, credentials, or network access. OS sandboxing or a
container/VM addresses that different problem. Anthropic describes effective
agent sandboxing as requiring both filesystem and network boundaries, and its
cloud design keeps Git credentials outside the sandbox behind a proxy that can
restrict pushes to the configured branch
([Anthropic, *Claude Code sandboxing*](https://www.anthropic.com/engineering/claude-code-sandboxing)).

For this macOS one-host pilot, preserve Codex's scoped workspace sandbox as the
default and add a container only for a route or ticket risk class that needs a
reproducible Linux toolchain or stronger process isolation. Docker Desktop runs
containers in a Linux VM, while bind-mounted host directories retain their host
permissions
([Docker Desktop for Mac permissions](https://docs.docker.com/desktop/setup/install/mac-permission-requirements/)).
Docker also warns that bind mounts are writable by default and can modify the
host filesystem
([Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)).
Consequently, merely bind-mounting a factory worktree is not a complete
security boundary. Mount only the exact workspace and required caches, keep
controller/Jira/GitLab credentials outside, and mediate Git writes through the
controller.

If a container must own Git, use an independent clone inside the container and
a factory-owned upstream or scoped Git proxy rather than exposing the shared
worktree anchor. Anthropic's 16-agent compiler experiment used a bare upstream,
one Docker container and clone per agent, and push/pull synchronization; the
authors also report frequent merge conflicts and label the harness an early
prototype
([Anthropic, *Building a C compiler with a team of parallel Claudes*](https://www.anthropic.com/engineering/building-c-compiler)).
That is useful evidence for disposable hostile or homogeneous workers, not a
reason to replace Symphony's one-writer-per-ticket branch ownership.

MicroVMs are appropriate when hardware-virtualization isolation and tenant
density dominate local simplicity. Firecracker uses Linux KVM and supports
Linux hosts and guests, so it is not a direct runtime for the current macOS
host
([Firecracker](https://firecracker-microvm.github.io/)). A future Linux worker
pool could revisit it without changing the durable ticket/task/branch model.

Task persistence and task visibility are also distinct. App Server's
`thread/list` defaults to interactive `cli` and `vscode` sources; callers must
explicitly include the `appServer` source kind to list controller-created
threads
([OpenAI Codex App Server](https://developers.openai.com/codex/app-server/#list-threads-with-pagination--filters)).
The factory should therefore prove repository-Project assignment and desktop
visibility by readback/integration test. A persisted thread ID alone is not
sufficient evidence that an operator can find the task.

## Target lifecycle

The controller should treat a workspace as a lease on a materialization, not as
the identity of the work:

1. **Admit.** Resolve the Jira ticket to one repository route, stable branch,
   base SHA, run ID, and repository-linked Codex Project. Persist those before
   starting an agent.
2. **Materialize writer.** Fetch the anchor, create or validate the one linked
   writer worktree, assign its exclusive Bazel output base, and bind the
   persistent feature-writer Codex task to that cwd. Never attach a second
   writer to the branch.
3. **Checkpoint locally.** The writer leaves coherent commits. Under current
   factory policy, the writer worktree remains the durability boundary until
   an independent verifier passes and the controller pushes the exact SHA.
4. **Verify independently.** Create a detached worktree at the exact candidate
   SHA with a fresh Codex task/context and its own Bazel output base. Remove
   both after the result has been durably recorded. This follows the independent
   reviewer pattern rather than asking a writer to grade its own work
   ([Anthropic best practices](https://code.claude.com/docs/en/best-practices#run-multiple-claude-sessions)).
5. **Publish.** Only the controller pushes the exact verified SHA to the stable
   ticket branch and reads the remote SHA back, preserving the existing
   delivery boundary.
6. **De-materialize.** Once policy allows the published run to park, prove the
   worktree is registered, clean, on the recorded branch and SHA, has no active
   task, and is recoverable from an exact read-back remote branch. Then remove
   the worktree and its exact output base while retaining the local branch at
   the same SHA. Keep the Codex task/thread and controller ledger.
7. **Rehydrate.** If a validation repair or authorized resume is required,
   fetch the remote branch, recreate the writer worktree at the recorded SHA,
   allocate a new exclusive output base, and resume the same visible Codex
   task. Re-run independent verification after any new commit. A remote branch
   is durable only after its ref and required objects have actually been
   transferred ([Git `push`](https://git-scm.com/docs/git-push)).

### Hibernation and source-branch loss

In this design, **hibernate** means park the execution materialization, not the
ticket or MR: stop the task's local processes and Bazel server, record the exact
SHA and task identity, remove the clean writer worktree and its exclusive Bazel
output base, and keep enough durable Git state to recreate that worktree later.
The Codex task, Jira state, factory ledger, draft MR, and shared repository/cache
state remain.

Closing an MR does not itself erase the MR record; GitLab preserves its comments
and pipelines. GitLab 19.1 added an explicit `Delete source branch` choice when
closing an unmerged MR, while projects can separately default source-branch
deletion after merge
([GitLab merge requests](https://docs.gitlab.com/user/project/merge_requests/),
[GitLab project settings](https://docs.gitlab.com/user/project/settings/)).
The factory cannot prevent a human or administrator from closing an MR and
choosing deletion, so an open remote branch is not a sufficient hibernation
backup.

The pilot now enables hibernation after the controller has pushed and read back
the exact verified SHA and the run reaches an allowed state. Before removing a
writer, it proves the worktree is factory-owned, inactive, registered, clean,
on the recorded branch and candidate SHA, has no unpushed commits, is outside
the live workspace, and has an exact matching remote branch. It then removes
the worktree, prunes its registration, retains and verifies the named local
branch, reclaims that worktree's Bazel base, and records `HIBERNATED` plus a
timestamp in the SQLite ledger.

Rehydration first fetches the base and source refs when present, rejects any
local/remote disagreement, recreates the same named branch in the deterministic
writer path, and requires its `HEAD` to equal the recorded candidate SHA before
the writer resumes. If a human deletes the remote source branch later, the
retained local branch still recovers the exact commit on this host and the
controller can republish it during an authorized repair. A closed MR remains
ambiguous human intent and must not be silently reopened.

This is a one-host durability design, not an off-host backup. Losing the local
Git object store at the same time as the remote source branch loses the only
remaining commit copy. A later multi-host phase may add verified bundles or an
independent archival ref, but the pilot does not need either to reclaim normal
worktree and Bazel storage safely.

There is one important limitation: with the current "push only after verifier
PASS" rule, an unverified or dirty writer is not disposable. Deleting it would
destroy the only copy of work. The safest near-term scaling path keeps such a
writer local and preserves the current fail-closed cleanup rules. If pre-PASS
eviction later becomes necessary, it requires an explicit policy change:
controller-mediated checkpoint pushes of clean commits to a quarantined ticket
ref, exact-SHA readback, and mandatory re-verification after rehydration. It
must not be smuggled in as a cleanup optimization.

## Migration path

### Phase 0: measure without changing ownership

- Record bytes for each worktree, Bazel output base, shared/download cache, and
  other route-specific generated state.
- Record materialization time, cache-hit rate, build time, and peak free space.
- Add invariants to status output: branch owner, worktree path, output-base
  owner, exact SHA, remote recoverability, and active Codex thread ID.

Exit when the fixed 20 GB writer reservation in
[WORKFLOW.factory.example.md](../elixir/WORKFLOW.factory.example.md) can be
compared with observed high-water marks rather than guessed away.

### Phase 1: split Bazel storage

- Preserve all current worktrees and cleanup behavior.
- Make each active writer/verifier/validator output base explicit and exclusive.
- Add the bounded per-repository disk action cache and host repository cache.
- Teach cleanup to stop the exact Bazel server and delete only the recorded
  materialization output base; never delete the shared cache as part of normal
  ticket cleanup.
- Run parallel-build and cache-poison/recovery tests before raising writer
  concurrency.

This phase attacks the likely large duplicated state without changing Git or
delivery authorization.

### Phase 2: introduce the factory-owned repository anchor

- Bootstrap a clean, non-writing anchor clone for each repository route and
  validate its remote URL and base ref.
- Route only new runs to it. Let active worktrees attached to the existing
  checkout finish; do not move or reparent them.
- Preserve one writer lease per branch and use porcelain worktree inventory for
  reconciliation; Git documents porcelain output as stable for scripts
  ([Git `worktree`](https://git-scm.com/docs/git-worktree)).
- After the last legacy run terminates, keep the human checkout outside all
  factory cleanup roots.

### Phase 3: make verified workspaces rehydratable

- Add an explicit `MATERIALIZED`/`PARKED` field and recorded output-base
  identity; do not infer materialization from a path string alone.
- Permit de-materialization only after the existing fresh external-state,
  cleanliness, inactivity, exact-SHA, and remote-recoverability gates pass.
- Recreate from the remote ticket branch and assert its SHA before resuming the
  existing Codex thread.
- Prefer least-recently-used eligible verified workspaces when capacity is
  short. Dirty, unpushed, active, blocked, ambiguous, or manually owned
  workspaces remain ineligible.

### Phase 4: add isolation profiles only where justified

- Keep `host-sandboxed-worktree` as the default.
- Add `container-clone` for routes that require a Linux toolchain or stronger
  process isolation, with controller-mediated credentials and separate cache
  volumes.
- Consider remote Linux workers or microVMs only after a threat model or host
  saturation shows that storage/cache work is insufficient.

## Acceptance criteria for the scaling change

- Two active ticket writers can build concurrently without sharing a branch,
  worktree, index, Bazel output base, or persistent Bazel server.
- Both can hit the same bounded disk action cache without either owning it.
- A verifier sees exactly the recorded candidate SHA and cannot mutate the
  writer worktree.
- Killing and restarting Symphony reconciles the durable run, visible Codex
  task, branch, SHA, materialization, and output-base owner without dispatching
  a duplicate writer.
- Controller-created tasks are read back with the `appServer` source kind and
  proven visible under the configured repository Codex Project before a writer
  is considered successfully launched.
- Cleanup cannot remove dirty, unpushed, active, blocked, ambiguous, human, or
  live-workspace state.
- A verified, pushed, parked writer can be rehydrated at the exact SHA and its
  existing persistent Codex task can continue in the new materialization.
- Cache corruption can be isolated by dropping the shared action cache without
  deleting source worktrees or durable controller state.
- Raising writer concurrency is gated by CPU, memory, and free-space floors as
  well as configured count; it is not justified solely by reduced average disk
  use.

## Bottom line

The scalable unit is not "one permanent checkout per Jira ticket" and not "one
checkout that changes branches." It is **one durable ticket/branch/task identity
with at most one leased writer materialization at a time**. Linked worktrees
provide the cheapest correct local Git isolation, shared bounded Bazel caches
reuse build results without coupling live server state, and the controller's
exact-SHA and remote-recovery gates decide when local state is truly disposable.
