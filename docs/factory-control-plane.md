# Local factory control plane

This fork is incrementally adopting Symphony as the provider-neutral, local
control plane for a Jira-to-GitLab software factory. The first migration slice
adds durable coordination without replacing the existing Symphony worker loop.

## Implemented foundation

- An opt-in `factory` workflow section.
- A local SQLite control record. Jira is not used as a dispatcher lock.
- A serialized, expiring tick lease with exact dispatcher and tick identity.
- A durable run, event, and model-route ledger compatible with the earlier
  Python `factoryctl.py` schema.
- Independent specification, source-writer, and manual-validator capacity
  accounting, including decimal gigabytes of free disk per writer.
- Provider-neutral model role resolution with risk-based writer escalation.
- Jira queues that can be scoped by authenticated user across projects, with
  optional project and direct-parent epic filters.
- "all of" and "any of" label routing gates.
- Local `status`, `activate`, and `pause` operations.

The full stage graph is not yet connected. In particular, this slice does not
yet launch distinct specification, delivery, verification, or manual-validation
tasks, nor does it push a verified SHA or create a GitLab draft merge request.
Keep the controller paused until those stage handlers are installed.

## Local administration

From `elixir/`:

```bash
mise exec -- mix factory status --workflow WORKFLOW.local.md
mise exec -- mix factory activate --workflow WORKFLOW.local.md
mise exec -- mix factory pause --workflow WORKFLOW.local.md
```

The control row is created in `PAUSED` state. `activate` and `pause` fail while
an unexpired tick lease exists. An expired lease may be replaced by the exact
configured dispatcher. A controller always releases the exact acquired tick in
an `after` path.

Never run the Python dispatcher and this Elixir dispatcher as active owners of
the same scope. Sharing the SQLite database is intended for migration and
history preservation, not concurrent dispatch authority.

## Configuration

Copy `elixir/WORKFLOW.factory.example.md` to the ignored
`elixir/WORKFLOW.local.md`, then supply local paths and credentials through
environment variables. The public example contains no organization-specific
identifiers.

Factory settings are deliberately provider-neutral:

- `dispatcher_id` is a stable identity for this controller deployment.
- `scope` names the globally serialized queue.
- `maximum_specifiers`, `maximum_writers`, and `maximum_validators` are separate
  pools, so specification and validation do not consume source-writer slots.
- `writer_disk_gb` is decimal GB required for each newly admitted writer.
- `repositories` maps route keys to local repository metadata.
- `models` maps stable roles to provider-specific model IDs and reasoning
  effort. A route is resolved and recorded before a future stage task launches.

## Migration sequence

1. Run the fork with `factory.enabled: true`; it starts paused and initializes
   or upgrades the local database.
2. Verify `mix factory status` and inspect the dashboard without activating.
3. Install the stage handlers and recovery reconciliation.
4. Pause the Python dispatcher and wait for its live lease to expire or finish.
5. Activate this dispatcher and observe a single bounded tick.
6. Increase concurrency only after duplicate, interruption, and disk-pressure
   recovery tests pass.

The migration remains additive: the standard Symphony workflow behaves as
before when `factory.enabled` is false.
