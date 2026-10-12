# U11 local native-acceptance preflight

Preparation only: no native/model call, connector, real-ticket operation, service
restart, deployment, profile/configuration change or fixture dispatch occurred.

Verified local facts:

- Latest filesystem read:20,255,024 KiB available (20,741,144,576 bytes), above the
  unchanged20 GB gate. This is a point-in-time observation, not a writer reservation.
- Executable SHA:`06fd57435a719403f2efc521d7e10648a84a50e13255a87164844950e27171ec`.
- Replay task SHA:`57448f4dda268ca4dbde2b6dedd2a7d5e1578ac5c49d55191c275237bde15ea0`.
- TicketContext SHA:`db5accb4c79b2e3bd30805349e7e7fca6b5854302d6168140c99db260eee8822`.
- Store SHA:`aee10bc451a74bc2d3817b5489f88784801fc1d0636c153b116f9127e845d24f`.

- The implementation route is `/Users/cgable/Repos/symphony-ticket-chat-implementation/elixir`.
- `bin/symphony` is present and executable, built by the latest full gate. Presence
  does not prove the Mix replay task is exposed through that escript.
- The diagnostic command is `mise exec -- mix factory.ticket replay RUN --workflow FIXTURE_WORKFLOW`.
  Its non-stage actions use Store.start_read_only; it explicitly starts Exqlite,
  not the full Symphony application. Actual restricted-broker execution is still
  unproven; source inspection cannot replace launch-counter/schema-content evidence.
- No named `[profiles...]` section was found in the inspected local Codex config,
  and no named broker profile was found in the searched repository paths. This is
  not proof that Desktop lacks a restricted runtime or per-chat tool permissions.
  The actual broker's allowed command/cwd/path capabilities must be attested during
  the approved acceptance run. Global settings must not be changed to manufacture it.

The U10 plain-VM receipt is historical, not exact-current native proof. The current
TicketContext hash differs from its accepted trace; the existing Store hash agrees.
The acceptance needs a fresh synthetic workflow/ledger, actual parent opening and
response, same-parent restart/amendment/rework, fresh blind verification, and current
restricted replay with zero source/model/process launches and unchanged DB/schema.

Pending: explicit U11 model-turn/runtime budget and human/UI evidence. The proposed
ceiling remains12 total turns/30 active minutes, not an assumed permission or proven
feasibility. Quality coverage remains99% until a direct user response changes it.
