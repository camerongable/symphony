# Symphony Elixir

Completed-turn recovery reads native history without starting a thread or model
turn, only after a recognized timeout/port-exit failure and genuine original stop.
It requires the bound latest completed turn, an explicit nil error, one identified
final-answer item, stable native version/confirmation, and an empty complete queue.
The transient parsed observation is bounded at 2MiB; the durable event stores only
safe identity/status metadata and parsed-JSON digests, not reasoning or tool history.
The full prepared run/task/evidence/reservation snapshot is checked again in the
same rollback transaction as the event and result. Original stop bytes and time
are preserved. A committed duplicate is read back without another native read;
the scheduler still performs normal exact-candidate checks and adoption.

New ordinary worker resume refusals are typed at the correlated `thread/resume`
response, before a session is bound. The versioned observation retains the exact
requested thread and raw error, bound to the current request/task/input/reservation.
Only supported active-writer refusals can rearm after the existing cooldown and
all no-session/no-effect guards. Newly observed unclassified RPC errors cannot
fall back to historical English matching. One shared persisted identity formatter
uses a fixed versioned prefix and the SHA256 of the complete structured refusal,
independently of inspection limits, map printing order, or diagnostic prose.
Rearming recomputes that identity and compares it with both original stored failures. The
legacy fallback is limited to runs with no new resume-failure marker. A malformed
or differently scoped marker on the same run fails closed rather than looking
absent. Already-stored unmixed exact legacy failures remain readable. Explicit
non-factory controller forking/waiting behavior is unchanged.

Capability recovery reuses the stopped predecessor's immutable admitted packet and
shared-instruction bytes. It revalidates all current packet facts except tool
guidance, which is supplied by the recovery wrapper; it does not admit a replacement
instruction snapshot. Prepared restart resolves the predecessor's evidence-bound
prompt rather than the mutable current task prompt. The read-only
`factory-broker ticket inspect-capability-runtime` operation reports loaded-code
identity independently of whether the ticket remains eligible for recovery.

### Disabled ticket-parent context integration

The internal `ticket_parent_step` requires absolute, canonical `ticket_cli_root`
and `ticket_workflow` locators in addition to its output root and broker identity.
The workflow database must be absolute and match the connected ledger. These
locators are immutable for an existing parent; historical missing bindings are
not automatically upgraded. Generated parent instructions direct the chat to the
bounded context reader and command staging. These are behavioral instructions,
not an OS-enforced read-only sandbox: the parent is a trusted operator interface.
Controller admission still requires independently read native input and receipts.

New controller pushes use the versioned V14 transport: a complete framed request
is bounded at 1 MiB and its terminal receipt at 4 MiB. Admission accounts for UTF-8,
nested JSON escaping, and Python ASCII escaping before any claim or child input.
All safety evidence remains present. V11 history and V5 status readback apply these
bounds only to V12/V13/V14 push execution/receipt envelopes; historical versions retain
their existing limits and cannot gain new issuance authority from readback.
Completed V12/V13/V14 envelopes are separately bounded at 12 MiB. Diagnosis/reassessment,
CI claim, successor, ordinary-generation, and authorized empty-child import journals account for these
copies only at fixed documented run/preimage paths; every other byte retains the
2 MiB budget. Size projections use digest/length markers internally but never
replace stored evidence or its hashes. Absolute encoded ceilings are 2 MiB plus
four envelope copies for diagnosis rows, six for successor proofs, and two for
preimage/claim/import/ordinary-generation objects, accounting for nested JSON escaping.
Ordinary generation discounts only an authenticated completed push at
`run_preimage.candidate_handoff`, never arbitrary journal content. The recorded
binding bytes and SHA remain unchanged, including after a service upgrade.
For ordinary generation only, the typed repair proof distinguishes the reviewed
push candidate from a newer local source parent. Size qualification authenticates
the former while preserving the latter; the full validator still independently
matches the saved proof against consumed verifier and writer evidence.

Historical generation authority is separate from the current push artifact.
Finalized ordinary V2 and generated-only V3 journals may name only the current
artifact or exact canonical helper/companion pairs in the versioned generation
origin catalog. Each historical pair is authenticated by immutable release
manifest bytes and artifact digests; same-byte unregistered paths remain invalid.
Historical generation helpers are read, never executed, by this validation.
One exact audited V12 preissuance rejection can use the existing schema-53
retirement journal. The old envelope, requalification journal, rejection and
reservation remain unchanged; the controller records one linked child nonce
before a later owned tick may issue. Unknown outcomes and other rejected nonces
do not gain retry authority.

CI repair budgets count immutable claims and evidence successors, not the broader
repair-round number shared with verifier repairs. Schema 54 permits positive round
identities above ten while retaining the ten-total-attempt trigger and configured
limits. Startup migration preserves existing rowids, receipt bytes, foreign keys,
and immutability guards; a higher round identity does not grant another attempt.

An operator may authorize one never-issued `PREPARED` push through
`factory.prepared_push_requalifications`, keyed by a unique authorization key.
The value pins `run_id`, `original_envelope_sha256`, `original_nonce`,
`candidate_sha`, `spec_revision`, `contract_sha256`, `authorization_reference`,
`maximum_implementation_iterations`, and `maximum_code_repair_rounds`.
Only a normal owned scheduler tick can consume it, after fresh ordinary delivery
checks and proof that the old nonce has no issuance artifacts. Schema 53 retains
the original envelope and reservation disposition in an immutable one-use journal.
That tick records `PUSH_REQUALIFIED` without issuing; a later tick may execute the
fresh nonce. It never resets or spends implementation/CI counters. Consumed entries
cannot mint another nonce and do not constrain genuinely later candidates. Removing
an entry is not required for historical readback, but changing workflow bytes while
the fresh push is pending can invalidate its ordinary current-policy fence.

`mix factory.ticket` read actions open an existing current-schema SQLite ledger
readonly and never create or migrate it. `stage` remains a separate writable
proposal operation and grants no execution authority. Native read-command
acceptance and the complete quality gate remain required before enabling this
ticket-parent route.

### Explicit repair of a blocked verifier result

New ordinary native writer/verifier admissions with numbered `AC-<number>`
criteria carry a versioned `review_protocol`. Their result must include complete,
candidate-bound criterion coverage, boundary sweeps, and independent closure of
every prior finding ID. Writers inspect the whole failure family within the
contract; verifiers consolidate the full review before returning findings. These
structured claims improve auditability but do not prove that no defect remains.
For source writers, COMPLETE means the implementation is ready for controller
formatting, generation, CI, and independent verification. Tests the writer cannot
execute remain NOT_CHECKED with explicit source evidence; that alone does not
require CONTINUE. Classified writer observations are retained but cannot close
independent findings. Stopped report rejections are projected read-only from the
exact current receipt, with a factory-owned recovery action rather than a generic
waiting message. Consumption or changed task identity removes that projection.

Version-2 writers without an `affected_paths` key may supply descriptive source
checks with unique nonblank IDs and nonempty evidence. COMPLETE requires these
checks CHECKED; they do not imply bound verifier coverage. Only focused writers
may retain an UNAVAILABLE boundary with empty paths, paired with a NOT_CHECKED
criterion and authenticated latest historical PASS evidence for that criterion.
No prior PASS, missing provenance, or a comprehensive scope permits that exception.
Independent verifier PASS remains strict: all criteria PASS, admitted boundaries
and path checks CHECKED, resolved closures, exact candidate, and no required finding.
New physical publication uses validator v26 and executors v37/v38; reader v20
retains historical helper identities, including the exact completed216/v36
release origin, without modifying retained programs or granting old issuers
new execution authority.

An explicitly configured `ticket_supervisor.source_completion_confirmations`
entry may authorize one read-only confirmation at the exhausted implementation
limit. It binds the exact run, candidate, contract, counters, and consumed
CONTINUE receipt. The new request cannot mutate source or return CONTINUE; it
must genuinely return no-edit COMPLETE or BLOCKED. Failure alone does not grant a
replacement request. Normal controller generation, CI, and independent
verification remain required. The global implementation and repair limits do
not change; successful confirmation may advance the recorded iteration once
beyond the unchanged limit. Removing the entry prevents new admission without
invalidating immutable completed evidence.

An exact optional `schema_rejection` authorization may permit one report-only
successor after a provider rejects that confirmation's response schema before
execution. It binds the failed request, turn, binding, complete evidence digest,
native error digest, and operator authorization. Complete native history must
contain only the original user input, with no output or tool activity; source
must be unchanged and clean, ownership stopped, and the native queue empty.
The existing failed-turn transfer journal preserves the failed row and all
budgets. Preparation and start recheck the scope, history and queue; successor
failure cannot grant another request. This is not an automatic retry policy.

Provider response schemas are a separate wire representation. The controller
retains its canonical admission/result schema; the wire adapter requires every
declared property and represents an empty-array constraint as `maxItems: 0`.
These restrictions narrow provider output without changing the controller's
no-edit authorization or accepting a previously invalid result. Only the known
positive-schema subset is adapted; schemas containing unsupported keywords are
retained unchanged.

The controller permits at most two automatic verification repairs after the
initial review and stops earlier when a prior finding remains unresolved.
Fresh instruction snapshots, CI repairs, ticks, and restarts do not reset that
contract lineage's count. A factual `REPAIR` stays `REPAIR`: a separate policy
decision and version-2 terminal receipt explain why automatic work stopped.
Decision recording, result consumption, and ownership release are atomic.
The dashboard shows the rule, recorded attempt count, requester responsibility,
and exact-candidate CI status separately from factory scheduling health.

Already admitted instruction snapshots and legacy result schemas are preserved.
Historical `BLOCK` results that explicitly report the old two-non-PASS rule are
labelled as legacy reviewer-reported stops, not new controller policy decisions.
Policy stops are deliberate terminal records, not retry requests; the legacy
authorization command below accepts only an exact preserved `BLOCK` and cannot
silently override the new limit or turn a policy-stopped `REPAIR` into `BLOCK`.

Version-2 reports author findings once in `review_report.findings`, with `id`,
`description`, `classification` (`NEW`, `REGRESSION`, `UNRESOLVED`), `disposition`
(`REQUIRED_REPAIR`, `OBSERVATION`), and `basis.kind/reference`. The controller
derives legacy presentation and required writer obligations; the native model
does not duplicate top-level finding prose. Required bases are an admitted
`ACCEPTANCE_CRITERION`, authenticated `PRIOR_FINDING`, or established
`SAFETY_INVARIANT` (`PRIVACY`, `SECURITY`, `CONTRACT_INTEGRITY`, `EXACT_IDENTITY`).
Only `PREFERENCE` records may be observations, including on PASS.

Initial `review_scope` is comprehensive. Focused follow-ups retain every prior
closure, all previously unverified/non-PASS criteria, the exact registered
checkout's committed delta, per-path checks, and affected-path regression
requirements. Omitted criteria require authenticated historical PASS provenance;
they are not new inspection claims. Legacy missing coverage is rechecked. Late
NEW mandatory findings cause `LATE_FINDING_ESCALATION`; they do not silently
broaden the repair loop. Unknown IDs, changed provenance and contradictory
verdicts remain fail-closed with specific diagnostics.

### Report-only correction and policy-stop continuation

For an exact stopped rejected v1 verifier report, prepare a deterministic mapping:

```sh
mix factory.ticket prepare-report-correction RUN --workflow WORKFLOW.md --payload-base64 BASE64_JSON
mix factory.ticket apply-report-correction RUN --workflow WORKFLOW.md --payload-base64 BASE64_JSON
```

Prepare accepts exactly `run_id`, `request_key`, `binding_sha256`,
`output_sha256`, and `mapping`. Mapping is an explicit complete bijection such as
`[{"classification_index":0,"finding_index":0}]`; no fuzzy or positional guess is
made. Apply accepts those same fields plus the returned `projection_sha256` and
an explicit operator `authorization_reference`. The only transformation replaces
duplicated classification descriptions with the explicitly selected original
finding descriptions. It must make the entire admitted v1 validator pass without
changing verdict, evidence, identities, coverage or closures. Missing evidence,
invalid identity, changed state and ambiguous mappings remain ineligible.

Prepare is read-only. Apply runs in the existing controller through BrokerRuntime
and writes one event, not worker/task JSON. It invokes no model/source worker,
inspection, source tools, Git or external actions and spends no product repair.
Ordinary scheduler adoption authenticates that projection while retaining the
original raw result and its receipt hashes. Correction of REPAIR is not PASS.

If adoption then records `REPAIR_LIMIT` at exactly two used automatic repairs,
an explicit operator may stage one exact continuation:

```sh
mix factory.ticket authorize-policy-stop-repair RUN --workflow WORKFLOW.md --payload-base64 BASE64_JSON
```

The payload contains the ordinary authorization fields listed below plus
`review_policy_stop`: `version:1`, `automatic_repairs_used:2`, exact
`policy_event_id`/`policy_sha256`, and the ordered `required_finding_ids` from the
preserved report. The operator body and `repair_instructions` explicitly bound
that one repair. A new version-3 authorization and separate application receipt
preserve the REPAIR verdict, exact terminal/policy events and original digests.
Fresh Jira, capacity, clean checkout, ownership release, no conflicting work and
the ordinary owned tick still gate application. Stage never dispatches. Apply
advances one combined repair round, retaining configured/effective limits and
automatic two used. Another REPAIR stops again; nothing grants a third automatic
repair. Old BLOCK authorization versions and physical programs are unchanged.
If both legacy counters already exceed configured limits, use
`review_policy_stop.version:2` and include this exact `source_allowance` shape
(these numbers illustrate the current 26/25 and 12/10 case):

```json
{"configured_implementation_limit":25,"prior_implementation_iteration":26,"next_implementation_iteration":27,"configured_code_repair_limit":10,"prior_code_repair_round":12,"next_code_repair_round":13,"maximum_additional_iterations":1}
```

The version-4 `REVIEW_POLICY_STOP_CONTINUATION_V2` authorization records configured
25/10 separately from effective 27/13. The same authenticated applied receipt
derives the exact REPAIRING run's source-iteration ceiling; no WORKFLOW setting or
prior counter changes. The existing instruction snapshot, request, SOURCE
reservation and immutable evidence bind the admitted writer. COMPLETE and honest
CONTINUE both advance implementation 26 to 27; CONTINUE remains non-complete and
another source iteration is denied. Existing independently authorized
same-iteration infrastructure recovery is separate and does not grant iteration
28 or permission to replay ambiguous source actions. Physical publication proves
the writer packet's pre-26 and adopted run's post-27 counters independently.
New physical history codec v21, push helpers v27/v28 and status reader v15 admit
the new proofs; retained v1 and legacy histories keep their original codecs.

A valid stopped native verifier `BLOCK` (or over-budget `REPAIR`) is adopted
atomically as terminal `FAILED`, retaining its raw verdict, consuming the result,
and releasing REVIEW ownership. Normal ticks do not retry it or create a new run.

An explicitly approved repair of an exact `BLOCK` can be staged with
`mix factory.ticket authorize-verifier-repair RUN --workflow WORKFLOW.md
--payload-base64 BASE64_JSON`. The strict payload contains `authorization_key`,
`run_id`, `candidate_sha`, `spec_revision`, `contract_sha256`,
`verifier_request_key`, `verifier_output_sha256`, `authorization_reference`,
`authorization_body`, and `repair_instructions`. The operator reference/body are
audited local approval, not a fabricated native parent message.

Staging requires the same controller identity and ACTIVE, unleased control both
before observation and at the authorization transaction. Completed normal ticks
may advance only generation and update time during Jira observation. A completed
pause/resume is also acceptable if control is again ACTIVE and idle with every
other field unchanged: staging records approval, not SOURCE authority. A live
lease, regressing generation or changed controller identity/conflict still refuses.
Staging and normal owned application read Jira from the controller workspace, not
the source repository or writer checkout.

The service returns `VERIFIER_REPAIR_AUTHORIZED` without changing the run or
dispatching. A normal owned tick requalifies the exact stopped/consumed verdict,
released ownership, current Jira/checkout/capacity and existing budgets, then
atomically records `VERIFIER_REPAIR_APPLIED` and enters `REPAIRING` with one repair
round spent. Only a later normal tick may launch SOURCE; implementation counters
advance through the usual worker path. Same approval replay cannot spend twice.
Original finding IDs and `BLOCK` remain intact. Version-2 ordinary repair proof
binds both events through generation, push and archived history; bare `BLOCK`
does not grant repair authority and delivery still requires fresh verifier `PASS`.

For BLOCK authorizations, a single additional repair beyond the combined historical budget requires an
explicit `ticket_supervisor.verifier_repair_budget_exceptions` entry keyed by the
approval's `authorization_key`, as well as the normal operator approval command.
The entry exactly binds `kind: ONE_VERIFIER_REPAIR`, run/candidate/contract,
verifier request/output/round, approval reference, configured limit, and prior
and next repair rounds. The next round must be precisely prior plus one. It
waives neither capacity nor implementation limits, grants no automatic later
repair, and never resets counters or changes the global limit. A version-2
authorization retains both configured and effective limits in immutable events;
after application, historical readback does not depend on retaining the config.
Successor push/history codecs independently validate this exception and support
both legacy prose-derived and admitted receipt/index-derived finding IDs. Older
helper files and completed receipts remain unchanged.

### Ticket status and read-only diagnosis

An operator may authorize one retry of an exactly failed `serverOverloaded`
FILE_SOURCE writer with `mix factory recover-failed-writer REQUEST_KEY FAILED_TURN
--workflow WORKFLOW.local.md`. This is not automatic backoff. It rejects a live
tick lease, changed inputs/HEAD/files, pending human input, live source owner or
unreconciled IO. Read-only native stored history must prove the same latest failed
turn with no final result. The failed attempt remains intact; an atomic, separately
recorded quiescence transfer admits one new request/generation in the same native
thread and checkout. Quiescence is not a fabricated owned shutdown receipt.
Recovery of the retry itself is intentionally refused; future bounded automatic
recovery is tracked in the pilot hardening backlog. Deploy the controller changes
at a proven idle boundary before applying this command.

The dashboard separates the operator-facing ticket parent from diagnostic role
workers and separates parent-summary synchronization from delivery state. A failed
summary does not invalidate the recorded candidate or verifier result. Disabled
factory and disabled ordinary-ticket routing are visible configuration states,
not proof that existing workers have stopped.

Current operation failures and uncertain handoffs take precedence over the
source-stage label. The dashboard retains all current attention signals, including
presentation-only warnings, rather than treating a healthy scheduler as healthy
delivery. A timed-out refresh retains visibly stale last-good data; a failed
initial read reports unknown counts. Runtime identity distinguishes control-server
initialization from the BEAM process start. Neither a fingerprint nor a WebSocket
connection establishes deployment or freshness.

Workflow progress is not worker liveness: current execution is projected from the
canonical task and latest exact worker evidence, even when task history is hidden.
A consumed result is waiting, not running; a bound turn is explicitly unconfirmed
live activity. Terminal generic controller failures remain recorded history,
while unresolved handoffs and current delivery failures remain attention items.
Implementation iterations and CI repair attempts are distinct budgets. Tick
observation expires after the larger of three poll intervals or one lease, without
changing the recorded last tick result. Ledger projection uses a deferred read
snapshot; controller and disk-capacity observations are timestamped separately.

MR handoff and CI polling verify the exact configured GitLab branch through the
read-only MCP connector, bracketed around the MR reads on one owned or supplied
session. The effective push/read origin must still match the completed push and
the configured GitLab host/project. No Git network fallback is used. Owned
sessions close before admission transactions, with no MCP/network observation
under SQL. MR receipt validation and initial Jira finalization recheck captured
delivery ledger facts; unchanged legacy/CI local checkout checks remain. Existing
issued receipts remain historical evidence, not permission to replay a request.

The explicit `TICKET_PUSH_CAS_RECOVERY` path recovers only the same immutable
candidate from an audited uncertain push. It retains the original outcome as
UNKNOWN, uses a new nonce and a genuinely recorded new child outcome, and requires
exact remote-SHA convergence before advancing delivery. It does not manufacture
the old helper's shutdown or retry the original intent. Retained uncertainty
continues to fence branch deletion/reset, identity retargeting and candidate
rollback. Versioned migration 39 adds those durable guards; historical run data
must remain unchanged at activation. The maximum is three explicit recovery
attempts, not automatic retry. The prospective ordinary-v2 descendant-push
limitation and HTTP state-read timeout remain separately tracked in
[`factory-pilot-hardening.md`](../docs/factory-pilot-hardening.md#unknown-push-recovery-and-truthful-dashboard--2026-10-13).

Blocker-only activation uses a reviewed prebuilt artifact through explicit
`MIX_BUILD_PATH` at a verified controller-idle boundary. The launcher denies a
missing compiled application instead of silently compiling another checkout.
This does not authorize restarting Desktop, changing source ownership, applying
the local CI-default patches, or replaying an uncertain remote operation.

From `elixir/`, inspect an existing ledger without replaying actions:

```sh
mise exec -- mix factory.ticket replay RUN_ID --workflow WORKFLOW.local.md
```

Replay reports current binding, candidate, questions, next action, synchronization
and bounded journal/receipt pages. Follow the returned fixed high-water cursors
with `journal` or `records`; inspect digest-pinned artifacts with `details`.
Missing, symlinked or incomplete-schema ledgers reject without initialization or
repair. Replay never publishes a summary or executes a recorded action. The
underlying `TicketContext.replay/2` is callable without Mix; its plain-VM check
does not prove execution under a deployed broker's restricted profile.

Factory-role tokens and cost remain explicitly unknown where no attributed
receipt exists. Direct-session totals are not factory-role usage. Reported task
lifecycle intervals are recorded wall time, not active model time. Recorded
checkout intents are not physical or historical checkout counts.

`Scheduler.ticket_parent_step/3` is a disabled-integration entrypoint for an existing
ordinary V1 run. It accepts explicit controller `parent_output_root` and
`broker_thread_id` bindings, reserves/reuses one parent, and returns pending/ready
without invoking a model or source worker. New parent identities retain the broker
immutably; historical missing bindings remain missing. These options do not prove
native capability or enable production. Evidence:
`../plans/receipts/006-U7C-parent-admission.md`.

Disabled ticket-parent integration now includes `claim-ticket-followup REQUEST_KEY
--source-thread-id BROKER_THREAD_ID --payload-base64 OWNER_OBSERVATION`. The owner
observation is an object containing `source: "codex_app/read_thread"`, ISO-8601
`observed_at`, and the unmodified owning-Desktop `response`. The controller reads
the native queue without a model turn, requires fresh quiet owner and empty queue
facts, and transactionally retains the guard receipt with the uncertain claim.
This command does not enable the production route; changing only its config boolean
still fails startup capability validation. See
`../plans/receipts/006-U7C-parent-guard.md` for evidence and remaining acceptance.

### Attachment-backed source bootstrap (disabled pilot)

`factory.native_source_attachment_enabled` defaults to `false`. When explicitly
enabled for a pilot, new native delivery writers create an explicit managed
source attachment in their existing native chat. `native_source_bindings`
records the isolated control checkout separately; `runs.worktree` and
`factory_tasks.workspace` remain the authoritative source path. Setup uses the
configured fast/low `workspace-maintainer`; source FOLLOWUPs explicitly use the
saved writer allocation. Historical requests and workspaces are not migrated.

Bootstrap requires a pinned read-only command receipt, target-attested attachment
observations, and independent Git checks. Source completion requires observed
same-turn source-command cwd and file-change paths. Ambiguous creation retains
the original request for reconciliation, not a second checkout. This evidence
is not a substitute for sandbox enforcement. The pilot does not thin its control
checkout automatically, archive chats, archive sources, or reclaim caches.

Production enablement awaits workspace-write access to the attached source,
control-context recovery/retention, and a broker-driven acceptance cycle.
`factory.cleanup.native.enabled` remains disabled and capability-gated.
Disabling new attachment bootstrap does not remove existing bindings or chats;
already-bound source turns retain their recorded workspace boundary.

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

Each issue worker uses a named, non-ephemeral Codex thread. When Symphony and
the Codex desktop app use the same `CODEX_HOME`, the thread appears in the
desktop task history after its first turn and can be reopened there. Symphony
can also resume a recorded thread ID after restarting instead of creating a
replacement conversation.

Local app-server protocol responses are read only from stdout. Diagnostic stderr
is inherited by the parent process, not merged into JSON frames or a bounded,
redacted diagnostic capture. The SSH transport is unchanged.

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

This fork also contains an opt-in, SQLite-backed local factory control plane
for a durable Jira-to-GitLab workflow. A manually invoked `specify-work` writes
and reads back the exact authorized contract before adding `ai-ready`; delivery
then starts one writer directly, with short inline code-grounding, independent
verification, and optional Slack-coordinated manual validation as visible
Codex tasks. The controller retains Git push and draft-MR ownership.
Configuration, safety boundaries, recovery, and cutover are documented in
[Local factory control plane](../docs/factory-control-plane.md).

The `factory.ticket_supervisor` setting remains default-off:
`{"enabled": false, "pilot_issue_keys": []}`. New run registrations record an
immutable execution mode, while historical rows remain `NULL` and continue to
follow the legacy route. Set `all_eligible_tickets: true` together with `enabled: true`
to select this route for every new ticket within the existing queue. This does not
bypass authorization, capacity, runtime, or Required:no eligibility, and does not
migrate historical runs. Omission preserves pilot-list behavior; disabling
`enabled` stops new admission while retaining recovery readback.
Static Policy validation checks configuration shape without
spawning a process. Enabled startup qualifies the actual configured CLI once in the
explicit canonical `parent_output_root` before storage/controller children start;
unsupported runtime or cwd stops startup with a typed error. Per-effect claims and
owned worker sessions retain their own checks. Listing, formatting and readback do
not probe. This checkout has not enabled production or completed rollout acceptance.
The exact accepted CLI versions include `0.163.0-alpha.10.2`,
`0.163.0-alpha.11`, `0.163.0-alpha.11.1`, `0.163.0-alpha.11.2`, and
`0.164.0-alpha.11.1`.
Runtime rollout requires qualification against the exact installed binary;
version acceptance alone does not establish successful qualification. Checks cover
initialize-only admission, restricted FILE_SOURCE/REVIEW startup, a harmless
synthetic turn, and persisted-thread resume. These do not prove model tool-use
containment or same-ledger worker recovery. Version acceptance does not bypass canonical
home, OS, effective policy, workspace, account, or connector-inventory checks and
does not establish model tool-use containment.
Disabled V1 runs are quarantined without stopping unrelated
legacy work; unknown execution modes remain rejected.

Parent admission reads `parent_output_root`, `broker_thread_id`, `ticket_cli_root`
and `ticket_workflow` from `factory.ticket_supervisor`. Only an absent workflow
defaults to the loaded workflow's absolute path; explicit null values are not
replaced. Internal context options, then tick options, override configuration.
Parent, broker and CLI roots are never inferred. These inputs do not enable the
runtime or replace its acceptance gate.

Internal V1 MR requests pin a positive `repositories.*.gitlab_project_id` at
preparation. Adoption qualifies the original successful request against fresh
read-only GitLab data. The scheduler owns a short-lived ephemeral GitLab connector
session outside the source checkout, without a model turn or controller resume.
The reader is transport only: the original request still pins its controller and
candidate. Supplied-session callers retain the controller-bound read seam.
Adoption never resends MR creation or performs Jira finalization.
Unpinned historical requests remain intact and rejected rather than being
silently rewritten. Ordinary adoption records MR identity only; CI preflight
adoption advances to `CI_WAITING`. Native send wiring and runtime
acceptance are still pending, and this does not enable the route.

The internal V1 scheduler prepares an exact typed MR request after the completed
push. Broker discovery requires the validated factory policy; discovery is not
claim authority. `factory.desktop claim-ticket-mr-interactive` reads Jira directly,
retains authorization only in its CLI process, and emits one
`OWNER_OBSERVATION_REQUIRED` JSON line. Submit one correlated owning-Desktop
observation on stdin; the command then reads native latest-turn/queue facts and
returns compact send arguments only after an atomic uncertain claim. Input is
bounded to 64 KiB and 40 seconds. Existing ten-second guard and sixty-second Jira
freshness checks remain unchanged. A lost final reply requires readback, not a new
claim. Production policy still rejects this route before readiness or connectors.

V1 preflight CI reads are catalog-qualified and model-free. WAIT/BLOCK retain
`CI_WAITING`; an exact PASS atomically enters `VERIFYING` and increments its round
once. A passing retry also supersedes a recognized current CI-repair exhaustion
error. Historical failures and consumed repair attempts remain unchanged, and
unrelated errors are retained. The fresh blind verifier receives candidate-bound
CI evidence, then PASS proceeds through normal exact push proof rollover. This is
local integration, not live connector acceptance or Jira review-ready finalization.

Schema 46 adds immutable MR observation qualifications for a completed controller
`BLOCK` that reports only the prior CI-repair candidate SHA. The original request,
result, and native turn stay unchanged. Normal adoption can qualify the same MR
only after a fresh read proves the current pushed candidate and unchanged route,
draft, reviewer, assignee, and source-removal policy. Current authorization, human
input, and active tick lease are rechecked before the qualification and adoption
are committed together. Retained-history and CI readers use that exact
qualification after restart; a `BLOCK` alone remains unusable. This capability
does not create a new MR request, trigger CI, or establish successful delivery.

Schema 27 adds a two-effect V1 Jira journal. Initial implementation records the
observed `In Dev` transition and factory-label delta; finalization records the
exact candidate/MR comment and `ai-review` delta. The journal itself is storage
infrastructure: only the initial scheduler hook described below currently uses it;
review-ready finalization is not wired. Journal claims alone do not authorize
external writes or source work. The same semantic operation cannot acquire another
comment claim after checkout, verifier or push-metadata drift. Uncertain effects
require fresh post-claim issue readback; complete receipts remain readable without
applying today's freshness deadline to historical evidence.

The staged `integrations/jira-mcp` launch adapter adds only bounded factory-label
add/remove operations to the existing authenticated provider, avoiding whole-label
replacement. It is not installed or enabled. The model-free Jira controller session
owns and closes its transport, including error paths. Connector acknowledgements
are not mutation completion proof. Review-ready effect wiring, shared recovery
fencing, actual provider installation and native acceptance remain required before
live use.

The local Jira-maintenance prerequisites separate read-only writer/delivery facts
from actual admission. Inspecting these facts grants no dispatch authority; ordinary
delivery admission still rejects `ai-review` labels. Actual writer admission cannot
use a held maintenance reservation to bypass checkout exclusivity. Initial
maintenance may reserve the immutable pinned base only for an ordinary V1
`ADMITTING_WRITER` run, without inventing a candidate SHA. Its disk/concurrency
budget stays held through failed/cancelled states until explicit release.
`release_jira` accepts only the exact complete journal and matching generation,
checkout identity and receipts. It does not change delivery status. Release and the
later local state update must share the controller's final transaction.

The internal V1 existing-checkout `ADMITTING_WRITER` tick now uses
`TicketJiraOperation.start_implementation`. Its owned model-free connector runs in
the proven non-source ticket-parent directory. Fresh authority, a unique advertised
`In Dev` transition and current tool capability precede each one-shot effect claim.
Lost responses are reconciled by direct issue readback, never blind resend. Already
`In Dev`/`ai-running` issues require no mutation. A fresh final read must still prove
both target effects before complete-journal release and writer admission commit
together. This hook does not launch the writer or complete Jira review-ready
finalization, and remains behind the disabled production V1 capability gate.

`TicketMrOperation.current_delivery_receipt` provides read-only qualification for
the adopted ordinary MR: original successful claim/result, current stopped
checkout/push, configured route and exact remote MR/human state are rechecked.
It does not require or grant Jira dispatch authorization, does not replay MR
creation and leaves ledger/control rows unchanged. Its MR observation timestamp
is conservative (before collection), separate from qualification completion.
Finalization still must independently prove fresh external authority.
Jira comment preflight matches the installed issue/body append tool; visibility
and public overrides are prohibited. Exact comment receipts accept the Jira
reader's normalized `text` field as well as legacy `body`. These prerequisites do
not yet wire review-ready Jira effects or advance the dashboard state.

The Desktop-owned ticket-chat identity slice adds schema version 17, a dedicated
`TICKET_CHAT` request target, and immutable parent/run mappings. Only that target
permits an explicitly null Project. An uncertain creation retains its original
request and generation; it never creates a replacement parent. Creation readback
requires the exact request hash, tool arguments, dedicated non-source directory,
null Project and no worktree attachments. Presentation receipts do not update
writer allocations, candidates, source bindings or delivery status.

This is storage/readback infrastructure, not an enabled runtime. Ticket requests
are excluded from the executable pending list; direct claim, stored argument
issuance and broker CLI mutations reject them with
`ticket_chat_runtime_not_integrated`. Read-only `show` remains available. The
new route still needs scheduler and broker integration, validation transport and
integrated acceptance before enabling; toggling the setting alone cannot bypass
the fence. No existing runs or chats are migrated automatically.

The U7c internal broker boundary now uses `TicketChat.authorize_issuance/3` for
exact enabled/allowlisted ordinary parent requests. Pending lists, transactional
claims and store-backed CREATE/FOLLOWUP arguments share it. Pure map builders
serialize only; they do not authorize sending. CLI adds `followup-args` and typed
`record-ticket-thread --payload-base64`, but forwards issuance policy only after
startup policy validation. That validation still rejects runtime enablement, so
production pending parents remain excluded. Exact already-claimed operations
can drain after disabling; direct API recording/completion also requires the
durable claim and linked identity. An absent output directory or accepted turn
does not authorize retrying uncertain CREATE. Native origin, busy guard/claim
and combined route acceptance remain outstanding.

`factory.desktop read-ticket-turn REQUEST_KEY THREAD_ID --source-thread-id BROKER_ID`
collects exact claimed-parent provenance. Its native reader uses optional full-item
turn pagination without resuming the parent. Missing items, cursor cycles, duplicate
identities, uninspectable history and detected metadata changes reject readback.
Receipt timestamps preserve native precision. The collector returns evidence facts,
not bootstrap acknowledgement, attachment proof or live ownership permission.
Equal metadata versions are change detection, not an atomic idle snapshot.
New parent prompts carry the exact request-key marker and final JSON acknowledgement
instruction; false acknowledgements cannot mark parent requests successful.

Internal ticket-step progress publication is outside delivery adoption. A failed
presentation does not roll back a commit or consumed worker receipt; subsequent
reconciliation retries only material publication, including after another role's
admission rejects. Production admission remains quarantined pending the owning
Desktop guard and combined acceptance gate.

The internal app-server also rejects native SOURCE startup and retained SOURCE
turns with `worker_source_containment_unproven`, before a subprocess or model
turn can begin. A detached-child fixture proved that native PID exit alone does
not contain all source writers. REVIEW and legacy nil-access sessions retain
their existing behavior; the new route cannot use these as a writer fallback.

Schema version 20 adds durable FILE_SOURCE edit receipts. The internal writer
runner keeps a logical SOURCE reservation, but its native process is read-only.
Only synchronous controller tools `repo_list`, `repo_read`, `repo_write`,
`repo_delete`, `repo_mkdir`, `repo_read_binary` and `repo_write_binary`
can inspect/edit its exact checkout. Writes require the full-file SHA-256 (or
`ABSENT` for a new file in an existing directory), bounded UTF-8 contents, and
the current request/thread/turn/reservation generation. Symlinks, hardlinks,
control paths, connectors, shell tools and permission escalation are denied.
Read paths prefixed with exact ASCII `.symphony-base/` resolve only the immutable contract-base SHA already bound to the
current worker and persisted review base; callers cannot select a Git revision.
This virtual namespace is available only through `repo_read` and `repo_read_binary`;
all writes and listings continue to reject it. It never falls back to a physical
directory, and preserves the exact original seven-tool catalog and policy hash
for retained native threads. It reads regular Git blobs through a fixed, bounded, read-only helper, without
fetching or changing the checkout. UTF-8 reads page by line; binary reads return
canonical base64 pages. Both retain the 256 KiB file and 16 KiB response limits.
Long or heavily escaped text pages fail closed; use binary pages for exact bytes.
Historical hashes identify preimages, not the current file: restoring one still
requires a current-file read and its exact write-CAS hash. Other dirty files are
not touched. Stopped or superseded worker capabilities cannot call these tools.
The controller alone runs approved checks and adopts a candidate; workers must
report unrun checks, not claim them passed. Single-file deletion requires the
exact current content hash, shares the durable mutation journal, and cannot
recursively remove directories. `repo_mkdir` creates one directory beneath an
existing parent and records its invocation nonce in a fixed macOS extended
attribute, not a Git-visible marker file. Recovery requires the original
directory device/inode, creation nonce and exact durable child receipt;
replacement directories are not adopted, even with copied attributes. Attribute
or receipt failures retain reconciliation rather than permitting a new mutation.
Binary fixtures use canonical base64 instead of UTF-8 conversion, with the same
262,144-byte file limit and exact-content mutation journal. Binary reads return
at most 8,192 raw bytes per page with a full-file hash and next byte offset.

An uncertain edit retains its PREPARED receipt and reservation. Call
`WorkerFileTools.reconcile/2` to read back the exact resulting file; it never
rewrites the file, recreates a task, or releases a reservation. Unproven outcomes
stay pending and prevent result consumption. Required validation and production
dispatch integration remain incomplete; all production ticket-chat issuance
fences remain unchanged.

The internal `Scheduler.ticket_step/3` component now launches and adopts ordinary
(`Required: no`) role workers sequentially in the same checkout. It is not called
by production scheduler ticks. New launches require controller-owned Jira
readback bound to the exact run/contract and no older than 60 seconds. Unfinished
attempts retain their stored model/effort and exact reservation. Planner adoption
enters ADMITTING_WRITER, leaving Jira/writer admission to the existing controller.
Writer adoption commits once and recovers that same commit/check after a crash;
final stage/task/evidence consumption and checkout release are transactional.
Failed checks or uncertain receipts retain ownership. Verifier adoption requires
the exact stopped candidate/base-bound receipt. Parent broker issuance and the
combined production acceptance gate remain U7c work; this component does not
authorize enabling the new route.

Schema version 24 adds controller check receipts. `TicketWorkerRunner.check/3`
currently accepts only `git-diff-check`: fixed CLT Git arguments compare pinned
commit objects with external diff/textconv, hooks and fsmonitor disabled. The
child has a read-only, network/fork-denying sandbox and a cleared environment.
Admission and completion bind the stopped worker, contract, clean candidate,
base and active reservation. The fixed controller helper commits an exclusive
claim and fsyncs actual child-exit/output evidence before replying. Restart
reads that exact receipt; missing or corrupt evidence never starts another
command or releases source. Definite pre-launch rejections remain retryable.
Successful whitespace checks are not tests or verifier PASS. Build/test actions,
required live validation and native acceptance remain incomplete.
`TicketWorkerRunner.ci_binding/4` validates supplied GitLab snapshots against
an independently configured numeric project ID and the current candidate.
Merged-result pipelines must prove the candidate as their source parent;
duplicate jobs, contradictory required-job states and mismatched bindings are
rejected. Missing pipelines return WAIT without changing delivery state.
Selected pipelines must also match the MR's `head_pipeline`; an old success
for the same source SHA is not sufficient, and missing pipeline visibility is
not silently converted into WAIT.
This pure data check is not connector provenance, a CI collector or permission
to push. The next integration reuses the existing explicitly authorized
CI-preflight route; a new local container build platform is not required.
`AppServer.mcp_tool_catalog_in_session/2` and `GitLabMcpConnector.catalog/1`
read advertised schemas only on an existing idle, caller-owned controller
session. Discovery rejects restricted workers, foreign ports, failed or
ambiguous inventory and pagination. It starts no model turn and grants no new
tool-call permission. Schemas are not authenticated CI evidence. Connector
failure must remain explicit; Jira tracker credentials must never be used as
an implicit GitLab REST fallback.
Adversarial review reproduced a parent-directory swap escaping the prototype's
pathname checks. Native FILE_SOURCE startup and retained turns therefore return
`worker_file_mutation_containment_unproven` before process/model side effects.
The prototype is exercised only in private fixture tests. Descriptor-relative
no-follow I/O is now integrated through a fixed, hash-pinned helper outside the
source checkout. On this macOS pilot it runs with a cleared environment and OS
sandbox; read operations have no filesystem-write permission. Root device/inode
and ancestor-directory identity are checked. Bounded UTF-8 files, modes and exact
compare-and-swap results are tested in temporary repositories.

Schema version 21 records controller helper exit receipts separately from edit
intent. Before a possible mutation the pending marker is committed. Only an
observed exit clears it; closing a Port or seeing matching bytes does not.
Unknown helper exits prevent replay, reconciliation and result consumption.
Historical pending edits without this evidence remain quarantined on migration.
The receipt binds the PID, invocation nonce, helper/input digest and exit status.
This is not a complete timeout or controller-crash recovery mechanism. Exact
helper shutdown/recovery, orphan-temporary cleanup and hardened controller
check execution remain unfinished. No passing fixture
test removes the native acceptance fence.

Schema version 22 binds each mutating helper invocation before launch. A fixed,
hash-pinned controller companion checks that exact committed row through normal
read-only SQLite/WAL access, durably claims the invocation once, owns/waits for
the sandboxed child, and publishes its bounded response and exact termination
before replying. It cannot receive a model-selected executable or profile.
Private journal files live beside the ledger outside all registered source
roots; future workspace admission rejects that directory. Journal readback uses
no-follow directory/file descriptors. Direct helper replacement is rejected;
only bounded reads/listings/digests and temporary-absence inspection retain the
non-writing direct helper route. New bindings also attest path and before/after
effect digests; replay/recovery cannot substitute another file with equal bytes.

An offline public repository-tool test kills the callback after the real child
receipt is stored, reopens the ledger, and recovers the same edit. Signal exits
are recorded distinctly from normal exit codes. A compile-test-only, hash-checked
external relay exercises lost replies; production rejects such overrides.
An isolated fixture BEAM is also killed and reaped after the actual companion
publishes its receipt; a new ledger connection recovers the same mutation.
Another test kills and reaps the real sandboxed child before input, recording
SIGKILL with a null exit code, not an invented exit 137.

Replacement temporaries are `.symphony-<invocation>` in the target parent. The
helper removes only the dev/inode it actually created after rechecking root and
parent; an O_EXCL collision grants no deletion authority. After bound terminal
evidence, an unchanged replace/delete operation may become ABORTED only with
matching current program/effect binding and absence of the replacement temporary.
Source ownership is retained, old call IDs remain refused, and a new call may
retry. Unattested temporaries, unknown exits, changed metadata and old programs
remain quarantined. This does not reclaim orphan temporaries by filename alone.

Before writing replacement bytes, the helper emits a bounded `TEMP_CREATED`
frame and waits for an exact nonce/raw-event-digest ACK. The companion checks
the helper's self-PID against its owned process, independently observes the
root/parent/temp identities, and fsync-publishes the exact `.creator` bytes before
ACK. It records the original actual wait result in `.terminal`, rechecks current
authorization under the same source reservation, and invokes only fixed
`temporary_recover` code. That operation may unlink only the recorded inode at
the original parent/root when the target has the original before/after digest;
a two-link inode additionally requires the target to be that same inode with
the expected after digest. There is no model-visible cleanup tool.

Cleanup's self-PID and actual exit are durably recorded in `.cleanup` before
the final composite `.receipt`. Status and cached receipt validation reject
missing, mismatched, borrowed or malformed creator/cleanup evidence. A killed
attested helper can therefore clean its own orphan and abort safely; a substituted
inode remains protected. If only final publication is lost, read-only status
can assemble the complete matching claim/creator/terminal/cleanup records with
an explicit `COMPLETE_ARTIFACTS` marker. Marked cached records require fresh
readback before replay or reconciliation; a later matching producer receipt can
replace that marker. Existing invalid final receipts never trigger fallback,
and rejected comparisons do not replace cached evidence. A crash before creator
attestation or before both terminal records still quarantines the operation.
These receipts do not solve
every companion-death/deadline window, native effective permissions or arbitrary
same-UID races.
Dispatch and archive/restore remain disabled pending the remaining acceptance.

Native checkout admission and identity rechecks now use fixed CommandLineTools
Git with a cleared environment, isolated system/global config, disabled hooks,
fsmonitor, optional locks and lazy fetch. A read-only Seatbelt profile allows
only that Git executable, denies subprocess creation and prevents file/network
side effects. Local repository format/worktree configuration remains readable.
Repositories requiring external clean filters may fail closed during validation;
this is not permission to fall back to ambient Git. Legacy controller commit,
push, fetch and authenticated remote operations retain their existing runner.
This identity hardening does not implement the separate build/check executor.

Schema version 18 adds staged commands, stable questions and immutable native
input observations. `mix factory.ticket context RUN --workflow WORKFLOW.md`
reads a <=16 KB projection with a <=2 KB summary. `details`, `journal` and
`records` provide bounded, ticket-scoped drilldown with exact content digests and
explicit collection counts. A stale artifact reports `stale_artifact`; refresh
context rather than treating newer bytes as the older evidence.

`stage` accepts a strict base64 JSON proposal while the parent is active and
returns `PENDING`. The controller's mechanical native reader initializes and
calls `thread/read` only; it never resumes the parent or starts a generation.
Admission requires completed direct client input, fresh projectless identity,
exact body and question/contract/candidate bindings, and the successful staging
receipt in that same native turn. Broker/delegated messages, quoted commands,
edited native items and stale questions cannot authorize actions.
New recorded invocations use the exact `./scripts/factory-broker ticket stage RUN`
launcher from the saved reader's cwd, with literal base64 proposal and absolute
workflow arguments matching the staged record. The ticket launcher reads the
canonical deployed LaunchAgent, refuses conflicting inherited build paths, and
never falls back to the cwd's local build. Context projection verifies the
canonical executable launcher bytes. Previously saved locators and successful
legacy `mix factory.ticket` staging receipts remain valid historical evidence;
their bytes are not rewritten.
Use the execution tool's working-directory option; shell chains, expansions,
echoed receipts and marker comments are not supported staging evidence.

For explicit contract revisions and candidate rework, `./scripts/factory-broker ticket
prepare-stage RUN --workflow WORKFLOW.md` prepares the literal staging command
from the bound parent's latest unclosed, single direct-human input. Persisted
app-server history may label an owning-Desktop turn interrupted before completion;
this does not prove live activity or authorize admission. It opens the
existing ledger read-only, preserves the message bytes, and returns
`PREPARED_ONLY` with `staged: false`. Execute the returned `stage_command`
unchanged from its returned `cwd`; do not retype the message or JSON. Staging
still returns only `PENDING`, and the controller still requires the completed
turn's exact native body and successful stage receipt before acceptance.
Stale/completed turns, multiple user items, delegation, foreign routes, changed
bindings, unsupported prose and unsupported shell locators fail closed. Earlier
failed inputs and proposals are never repaired or rebound by preparation.

Questions permit controller-defined phrase aliases, bounded text as answer data,
or bounded integers. Explicit `Answer QUESTION_KEY: ...` disambiguates questions;
`Rework: current candidate` can accompany an answer. Standalone rework and
`Revise the contract:\n...` express intents, not immediate source/Jira permission.
Unsupported prose gets a precise rejection rather than an inferred action.
`ACCEPTED` does not mean `APPLIED`; external adoption/readback belongs to the
controller integration. Existing source identity, slices and candidate remain
unchanged by these APIs. Old verifier PASS receipts lacking current contract
provenance remain historical/unproven, never retroactively certified current.

Material summaries use the existing Desktop request outbox. Only its own
unclaimed pending presentation can be superseded, atomically with a new immutable
request/hash. Uncertain requests remain unchanged and expose synchronization lag.
The parent presentation does not change delivery status or writer allocations.
Controller presentations render a timestamped, immutable as-of snapshot; the
parent does not refresh it or claim current-at-render freshness. ACK proves only
receipt of that presentation. Direct human answers, contract revisions and rework
commands still require a successful same-turn context refresh before staging.
Timestamp-only polling advances a local event cursor without enqueuing a model
turn. Presentation hashing normalizes volatile evidence timestamps only;
authorization always uses original bytes. A failed unchanged presentation reports
`SYNC_FAILED`, not a healthy unchanged state, and is not blindly resent.

Manual-validation results are bound to the confirmed contract's named
non-production environment as well as its exact candidate SHA. The safety
policy is rechecked before a validator starts and before its result is used.

Install the persistent local scheduler with
`./scripts/install-local-factory-launchd`. Codex remains the operator UI; the
launchd process only supplies durable scheduling and recovery.
The launcher puts the Codex app's bundled CLI directory on `PATH` and fails
startup if `codex` is absent; an outdated bundle path otherwise makes every
Jira intake tick fail before any active ticket can advance.

The optional `desktop_broker` transport routes worker tasks and a prebound,
projectless controller task through durable Desktop requests. The broker must
read back the same task, turn, schema result, and required tool calls. Desktop
follow-ups cannot convey the app-server's issue-scoped Jira tool approvals.
The `specify-work` skill writes its manually authored, authorized contract
through the user's Jira connection; the controller validates its exact marker
before delivery. Scheduler-owned Jira reads and writes use a separate ephemeral
app-server MCP connection. Intake stores exact Jira description and
comment bytes without model reserialization. Writes check the issue, status,
and labels, skip an exact comment already present, and read the issue back.
Digest-bound factory contracts use a transport-safe literal comment envelope;
the controller rejects Jira Markdown rewrites instead of treating them as an
equivalent specification.
Automatic specification repair is bounded separately from human input: a
read-backed answer to the exact question marker resets the automatic repair
budget and resumes the existing author task, even if earlier drafts exhausted
that budget. Legacy feature-planner results receive one same-task JSON-format
repair turn; new deliveries skip the planner task, and malformed legacy output
never authorizes a second planner task.
For a pre-fix planner request with no repair budget, pause the factory and
prove its exact completed turn and task route before
`mix factory authorize-planner-repair REQUEST_KEY COMPLETED_TURN --workflow
WORKFLOW.local.md`. This records a one-shot grant without changing the request
payload. The Desktop broker claims that grant after activation and sends one
tool-free format repair to the same planner task; an uncertain claim is
reconciled, never resent.
An approval or elicitation prompt is not answered automatically; the write
fails closed for reconciliation. The visible Desktop controller task remains
the audit and GitLab-delivery interface, not the Jira data transport.

Review-feedback discovery is enabled by default for this local factory through
`factory.review_feedback`. Set `allowed_author_ids` to the numeric GitLab IDs authorized to
address `$Symphony`. The trigger is plain text, so it does not tag a GitLab user.
Reply readback resolves the authenticated GitLab account
through read-only `whoami` and requires the reply author to match it. An optional
`bot_author_id` pins that identity when the connection uses a dedicated bot account;
omit it when the existing connection posts as a human account. Each scheduler
tick reads fresh Jira state, the exact open factory MR, and all GitLab discussion
pages through a scoped, reused MCP session without a model turn. It records one
durable receipt per new authorized note body. Notes discovered on the same MR
are handled in one controller batch, while each conversational answer is read
back in its own discussion. Questions and ambiguous criticism receive an
explanation or clarifying reply, not a silent source-change classification.
Clear edit requests, including approvals that follow a concrete proposed edit,
continue through the existing writer and verifier. A replayed controller reply
can be retired only after its exact GitLab discussion marker is read back; the
same receipt then continues into source rework without reposting the reply.
Scheduler ticks reconcile a claimed controller request before polling other MRs.
Edits supersede older pending receipts, including when the mention is removed.
Any future receipt consumer must re-read the exact note and MR head immediately
before acting, since either can change after the most recent poll.
Clear source-change requests form one review-rework batch on the existing
delivery run and writer chat, pinned to the exact MR head and clean checkout.
The independent verifier checks the new candidate before the controller pushes
the existing branch; verified push readback then queues exact-thread replies.
No new planner or MR is created, and the factory does not change draft or
reviewer state. If the original native writer checkout is unavailable, rework
fails closed instead of silently creating a second source checkout. Uncertain
GitLab replies require reconciliation; the controller never blindly posts them
again.

If a Desktop controller permanently lacks a required connector, pause the
factory and broker first. After proving a replacement projectless task can
complete the connector read, and proving the old request made no required
external call, migrate the binding with `mise exec -- mix factory
replace-controller OLD_THREAD NEW_THREAD NEW_TURN FAILED_REQUEST_KEY --workflow
WORKFLOW.local.md`. This retires only the exact failed controller request and
keeps ticket worker tasks and their history intact. Archive the old controller
only after the new binding is read back.

A broker readback outage keeps future native stages in `WAITING_FOR_BROKER` so
the same completed turn can be reconciled. For a legacy run already marked
`FAILED` solely because a completed native author turn was hidden from Desktop
task history, pause both loops, prove the exact turn and request marker, then
run `mise exec -- mix factory recover-spec-readback REQUEST_KEY COMPLETED_TURN
--workflow WORKFLOW.local.md`. This reopens the same run and author for broker
completion; it does not generate a new turn or change Jira.

If a completed author draft was rejected only because it carried forward the
previous specification revision, pause dispatch and verify the latest Jira
description and exact completed Desktop turn. `mise exec -- mix factory
adopt-spec-revision REQUEST_KEY COMPLETED_TURN --workflow WORKFLOW.local.md`
binds only a unique prior-revision header to the recorded next revision and
continues with draft write/read-back and independent critique. It does not
send another author turn or write Jira itself.

Native factory writers edit and check source in their Codex worktree, then
return exact changed paths and a conventional commit message as raw structured
output. The controller validates the bound branch, parent SHA, complete path
set, and clean read-back before committing with `--no-verify`; workers do not
write protected shared Git metadata. After an approval-blocked writer turn has
ended with no edits, pause dispatch, verify that exact task and clean pinned
checkout, then use `mise exec -- mix factory recover-native-writer REQUEST_KEY
COMPLETED_TURN --workflow WORKFLOW.local.md`. This attaches the recorded branch
and reuses the same task for its next pass; a mismatched or dirty checkout fails
closed.

For a failed `REPAIRING` slice whose controller commit succeeded before the
ledger update, pause dispatch and verify the current Jira labels, completed
turn, and clean checkout. `mise exec -- mix factory adopt-repair-slice
REQUEST_KEY COMPLETED_TURN --workflow WORKFLOW.local.md` proves the commit's
parent, paths, message, branch, and SHA, then reopens the same run for
idempotent adoption and fresh verification. These recovery commands do not
change Jira labels; if a prior block write added `ai-blocked`, the controller
must restore and read back the authorized labels before activation.

If a native writer turn is interrupted, read back that exact interrupted turn
and request marker. With dispatch paused and no live lease, `mise exec -- mix
factory resume-interrupted-writer REQUEST_KEY INTERRUPTED_TURN --workflow
WORKFLOW.local.md` closes only that unresolved request and re-arms the same
task. It accepts any implementation iteration only while the run is still
writing, has no MR, and its candidate SHA is absent or equals the bound
worktree HEAD. It also verifies the task/project/worktree/branch binding and
refuses another unresolved request or moved HEAD/branch. The operator must
independently verify the interrupted turn ID; the command does not attest
Codex history by itself.

Priority hardening (activated in the local pilot on October 13) retains genuine worker shutdown
receipts on native errors and exceptions. Proven model-capacity failures can
receive at most three exact-bound automatic retries after 5/15/30 minute
cooldowns. The controller preserves the original thread, model, contract, plan,
candidate and applied file receipts; changed evidence, active ownership, pending
human input and ambiguous starts deny recovery. Historical quiescence recovery
does not become a fabricated owned-exit receipt.

For a service-owned writer interrupted by the exact recorded controller
connection-loss error, use `mise exec -- mix factory recover-interrupted-writer
REQUEST_KEY INTERRUPTED_TURN --workflow WORKFLOW.local.md` only after proving
the latest terminal native turn. This separate manual path checks persisted
history and an empty, version-stable native input queue outside ledger
transactions, then atomically preserves the candidate, contract, plan, model
and journaled partial bytes while transferring source ownership to one new
attempt. Launch rechecks the proof. Active source-cwd holders, queued human
input, uncertain completion, changed bytes and missing evidence deny recovery;
no owned-stop receipt is invented and a second interruption is not silently
rearmed. This does not authorize direct worker messages or a Desktop restart.
The corrected interrupted path uses the existing sole-controller ownership
contract, not a new global native queue-CAS requirement. It validates the
persisted queue schema and revision, proves the native writer lock is free
before transfer, and requires an exact same-owned-session preflight immediately
before `turn/start`. Queue readback is not a cross-server atomic dispatch receipt;
direct specialist input remains prohibited. A Desktop-held exclusive lock or
unexplained source-cwd holder still denies recovery. Never delete native locks
or fabricate shutdown receipts to bypass those guards.

Every captured specialist error has a durable deduplicated parent notice. The
notice requires independently read-back final text, not an acknowledgment-only
result. An uncertain parent presentation remains a delivery obstruction and is
never blindly resent. These changes do not authorize deployment or prove visible
delivery in the live ticket chat.

When a writer returns `BLOCKED` on a failing contract check with partial
source edits, the controller does not discard them or silently reinterpret the
contract. After proving the exact completed turn, one latest failed delivery
run, unchanged branch/HEAD, and an `ai-running` snapshot, pause dispatch and
run `mise exec -- mix factory investigate-blocked-writer REQUEST_KEY
BLOCKED_TURN --workflow WORKFLOW.local.md`. This permits one bounded
investigation in the same task and dirty checkout. It does not commit the
failed slice or override a genuine product decision.

For a stopped `FILE_SOURCE` writer whose exact contract-base capability has
since been restored, the owning service also supports
`factory-broker ticket inspect-capability-recovery RUN --payload-base64 PAYLOAD
--workflow WORKFLOW` and `authorize-capability-recovery` with the same binding
plus `grant_id` and `grant_sha256`. Inspection is read-only. Authorization
requires an independently reviewed, one-use local operator grant in the fixed
service-owned `operator-grants` directory; the CLI cannot create grants. The
grant pins the request, output, contract/base, exact raw journal rows and dirty
bytes, approved base paths, and operator approval excerpt/reference. It records
`LOCAL_OPERATOR_AUTHORIZATION`, not a native parent message or machine-proven
cause. Grant and directory permissions are `0600` and `0700`, with canonical,
owned, no-follow, single-link reads. Grants expire within fifteen minutes.

Staging appends authority only, while current controller identity is `ACTIVE`
with either no lease or a well-formed unexpired lease. It does not clear a
blocker or launch work. External Jira, capacity, checkout, file and native
observations precede a short locked ledger comparison. The normal owned tick
must freshly qualify and consume a one-transition `CHECKED` proof before
transferring the dirty reservation. Repeated APPLIED writes are checked in
rowid chronology, including every physical receipt and final per-path bytes;
unknown, partial and unsupported file histories are refused. Restart of an
already reserved continuation requires fresh observations without another
transfer, request or counter increment. The actual owned actor refreshes queue,
result, owner and timestamp evidence again immediately before sending a turn.
Native queue observations are not a SQLite compare-and-swap over the client.

Old results and file receipts remain immutable. The seven-tool catalog and all
budgets remain unchanged; source generation, commit, push, CI and independent
verification stay controller-owned. This route relies on the current fixed
check catalog and restricted worker profiles, not Unix permissions isolating
arbitrary same-user code. Do not run unconfined candidate-authored code while a
grant is live. An absent/expired grant, drift, new input, foreign owner or
uncertain issuance stops recovery; do not manufacture parent input or retry
with a second authorization to bypass those guards.

New pushes whose retained lineage contains a validated capability transfer use
the additive V26 issuer/V20 history codec. Other new pushes use V25/V20;
archived programs and receipt bytes are never rewritten. Archived capability
authority validates the service-created AUTHORIZED attestation, exact recorded
file-receipt structure and ordered raw-row hashes, INITIAL CHECKED and APPLIED
crosslinks, and one-generation transfer. It does not reread a retired spool,
require the grant to remain live, or compare later source edits to old bytes.
Grant timestamps retain their authenticated bytes; the capability codec accepts
UTC `Z` and `+00:00` representations without widening historical timestamp rules.
The two exact audited V15/V16 ordinary-verifier rejections may be retired by normal
owned ticks only after stopped-helper, absent-issuance and remote-preimage checks.
Each hash-linked event preserves its envelope and rejection, atomically releases
MAINTENANCE and prepares a separate nonce without consuming a repair attempt or
inventing a CI claim. The second audit pins the exact first event; live validation
requires the complete two-event prefix. A separate V24 rejection audit may seal
that fully validated prefix after the workflow advances to a different context;
it permits one new retirement, not replay of either historical attempt. Unregistered
retirements remain forbidden. This is not a general retry allowance.
Historical generation and push artifacts require exact
manifest-root and file-hash catalog entries across service replacement.
Issuance requires a later fresh qualification. Event producers
are append-only and consumers enforce cardinality and raw hashes; this journal
does not add database-level immutability to the general events table.
The older remote-CAS recovery executor refuses this new lineage; ordinary
current-issuer readback remains available, while any further unknown-outcome
intervention requires a separately reviewed supported recovery path.

If a completed repair writer correctly refuses controller-owned push/MR work,
pause dispatch and use `mise exec -- mix factory resume-controller-delivery
RUN_ID CANDIDATE_SHA --workflow WORKFLOW.local.md`. Recovery requires the exact
latest run and completed broker result, a clean bound branch at that SHA, an
existing draft-MR binding, and the configured CI-preflight route. It returns
the same run to controller-owned CI push, MR read-back, and fresh verification;
it neither relaunches the writer nor edits the MR itself. Record any missing
contract-required MR evidence before reactivation.

The broker generates creation arguments with `mix factory.desktop
create-thread-args REQUEST_KEY --workflow WORKFLOW.local.md` before claiming.
The returned object uses the native tool schema, including `target.projectId`
and a worktree pinned to the expected commit.

If Codex rejects a verifier CREATE with the exact `invalid arguments` result
before returning any task or client ID, the broker records the rejected tool
call. The active scheduler can requeue that same request once after checking
its rejection receipt, current verifier/candidate, repository route, and
unchanged payload. The retry budget persists across restart. Accepted or
ambiguous creation results remain in reconciliation. A second rejection is
shown as a verifier creation failure requiring correction. Paused operator
recovery remains available through `mise exec -- mix factory
resume-rejected-create REQUEST_KEY REJECTED_TOOL_CALL_ID --workflow
WORKFLOW.local.md` after exact tool-call readback.

`mix factory.pilot_report --issue PPL-9723 --workflow WORKFLOW.local.md`
reads the ledger without migrations or mutations. It reports stage and
request wall-clock durations, current handoff failures, task/request counts,
model routes, candidate/MR identity, and recovery/cleanup receipts. Token totals,
human-intervention totals, and historical disk growth are marked unavailable
when the ledger has no measurements. See [the hardening plan](docs/factory-hardening-plan.md)
for lifecycle regression and live-trial acceptance criteria.

Dashboard handoff attention uses the newest request created for each persistent
task. Updating an old recovered failure cannot override a newer healthy request.
When the controller commits a native writer slice, its candidate SHA and the
consumed writer's recorded checkout SHA advance in the same transaction, so a
later review edit can reuse that writer without stale provenance.

Delivery registration inherits risk and risk signals only from one completed
specification with the exact authorized issue, revision, digest, and Markdown.
Missing, malformed, or ambiguous metadata remains conservative `unknown`.
Externally specified contracts without structured risk metadata are unchanged;
free-text Jira descriptions cannot downgrade routing.

Native cleanup capability can be inspected with
`SymphonyElixir.Factory.NativeWorktreeProbe.enqueue(store, run_id)`; it creates
one exact-writer read-only maintenance request, not an implementation pass.
Broker completion must supply the observed artifact map as `artifact_output`
and in the completed `list_artifacts` tool receipt. Probe completion preserves
the writer's stage result, status and turn. Empty/ambiguous attachments do not
authorize cleanup. No automatic native archive/delete scheduling is enabled;
see the hardening plan's synthetic attachment/restore proof and remaining
production execution-context limitation.

The broker can record target-attested maintenance data using
`mix factory.desktop record-maintenance-evidence REQUEST_KEY --payload-base64
BASE64_JSON --workflow WORKFLOW_PATH`. The target's standalone Python emitter
writes stdout only; the broker supplies the full read-backed command frame.
Recording is immutable/idempotent and returns a machine-generated probe receipt.
Completion checks the same maintenance turn's observed `list_artifacts` call
and preserves the writer's implementation result. This is a production evidence
transport, not automatic cleanup activation or independent raw-MCP readback.

The scheduler also polls the exact issue key of a failed delivery, even when
Jira has moved it to In Dev and it is absent from the normal intake query. A
changed Jira description or human comment starts one visible `Contract Update`
task in the repository Project. New contract-only chats use the Project's local
context without creating a worktree; already-bound chats retain their checkout.
A question in that task pauses only that
ticket; the Desktop broker reads back the user's reply and the scheduler
continues the same chat. The reply is input, not authorization: the controller
still writes and reads back the new contract and passes independent review
before rearming the original writer worktree. An unchanged failed contract
does not create another task. The dashboard links to the waiting chat.

The factory creates a fresh detached Codex worktree before launching each
change verifier. The verifier runs `verify-feature-delivery` in reviewer mode
inside that checkout; it must not create another worktree or delegate again.
The Desktop broker may submit that skill's detailed verdict JSON unchanged.
Symphony checks its issue, contract revision and digest, candidate SHA, review
checkout, acceptance results, and checks before reducing it to the factory's
stage result. A `REPAIR` verdict carries its exact required repairs into the
same writer's next pass.
If a verifier turn fails authentication before producing a verdict, prove the
failed Codex turn, exact request, Project, and clean detached candidate checkout.
With dispatch paused and unleased, run `mise exec -- mix factory
resume-auth-failed-verifier REQUEST_KEY FAILED_TURN --workflow
WORKFLOW.local.md`. This closes only that request and rearms the same verifier
task without counting a code-repair round. It does not repair credentials or
attest the failed turn by itself.

If a verifier CREATE was uncertain but its exact bootstrap later completed, use
`mise exec -- mix factory recover-native-verifier-create REQUEST_KEY
BOOTSTRAP_TURN --workflow WORKFLOW.local.md` while dispatch is paused and
unleased. Recovery requires the same latest failed run, a completed bootstrap
bound to the verifier's existing thread, Project, detached clean checkout, and
candidate SHA, with no unresolved sibling request. It rearms that existing
verifier task; it never retries CREATE or changes the candidate/MR.

Native worktree creation can return a temporary client ID before its real task
ID is available. The optional `native_session_discovery_enabled` gate defaults
to `false`. When explicitly enabled, `mix factory.desktop find-thread
REQUEST_KEY --source-thread-id BROKER_THREAD_ID --workflow WORKFLOW.local.md`
scans a bounded portion of recent local and archived Codex session metadata
and returns only a candidate task ID. The broker must still verify the candidate's Project,
checkout, and completed turn through Codex before binding it. A missing or
ambiguous candidate never authorizes another create.

Worker task launch checks the route's primary repository root against the
local Codex app-server Project list. It refuses to substitute that registry's
ID when it differs from the configured desktop Project ID, before creating a
task. The two registries currently have different IDs on this host, so this
guard prevents new projectless factory tasks while the desktop-backed launch
handoff is being built. Existing task IDs and titles remain reopenable, but
their desktop sidebar grouping is unchanged.

After fixing an infrastructure failure, request one local retry of the exact
latest failed specification with `mise exec -- mix factory retry-spec PPL-1234
--workflow WORKFLOW.local.md`. This preserves the failed run and its task
history, does not edit Jira, and cannot repeat without another explicit
request. The factory refuses the command while a scheduler tick holds its
lease, or while the author task or a Desktop request is still active. When the
issue, repository, Codex Project, and checkout still match, the next
specification attempt reopens the failed run and resumes the previous author
task instead of creating a new visible task. A substantive Jira clarification
does the same without requiring `retry-spec`. A missing checkout or changed
route stops that issue for reconciliation rather than creating a replacement.
An active-writer refusal leaves that task waiting and retries the same ID after
a bounded delay; it never forks to work around ownership.
This does not bypass the desktop/app-server Project mismatch above.

For the app-server task transport, Jira mutation approval is one-shot and
issue-bound: comments require the exact body, and label changes require
`jira_update_issue` with only the exact label set computed from the current
intake snapshot. Mixed comment-and-label steps carry separate approvals. For
Desktop transport, the direct MCP writer sends only those same scoped arguments
and checks the fresh preimage and post-write read-back. An agent's PASS text
alone is never proof of a write.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- `tracker.required_any_labels` is optional. When set, an issue must have at
  least one configured label in addition to every `required_labels` entry. This
  supports queues whose mutually exclusive labels represent different workflow
  stages, such as specification and delivery.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, and `api_token`; these
  default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN` and accept `$VAR`. Optionally set
  one `project_key`, multiple `project_keys`, or direct-parent `epic_keys`. Set tracker `assignee`
  to `currentUser()` (or `me`) for Jira's authenticated user, or to an explicit account value.
  Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate JQL combines only configured project, parent, assignee, and status
  clauses. Omitting project and parent scope supports cross-project queues; ID refreshes honor the
  same optional project scope. `issue.id` is Jira's immutable ID and `issue.identifier` is the
  issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

Workflow titles fall back to the matching saved Jira snapshot when the ticket is
absent from intake. Dark surfaces stay neutral; labeled indicators convey health.

Schema v38 stores controller-owned intake rejection decisions separately from
the observed Jira snapshot. Missing, ambiguous or unsupported manual-validation
declarations, disabled/unsupported selected capability, and forbidden admission
environments show `INTAKE_BLOCKED` with fixed safe reasons without starving queued
or active work. The next snapshot clears stale decisions and permits correction.
Global policy, provider, runtime, routing and ledger errors still fail the tick;
denial persistence requires the exact saved observation. No migration is needed.

Leased callbacks stop if their renewing owner dies, including while waiting in a
SQLite transaction. The callback's guard owns no lease and changes no caller exit
policy. Abrupt death leaves the durable lease to expire normally; stopping local
execution never clears issued-operation uncertainty or authorizes replay.

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`
- When `factory.enabled` is true, the same dashboard shows controller leases, bounded capacity,
  durable runs, Codex task identities, worktree state, delivery links, and recent ledger events.
  The overview counts each current ticket once; a paused factory with a Desktop task awaiting
  broker recovery or its next stage places that ticket under Needs attention rather than Active work.
  A nonterminal run stays under Active work while controller gates run between worker turns;
  Jira queue counts only tickets without an in-progress run. Jira intake separately lists all
  tracked factory-labelled tickets, including those already in progress.
  The Desktop Broker card counts pending, claimed, and reconciliation-needed task handoffs;
  it does not measure the Codex automation heartbeat. Ordinary queued or claimed requests do
  not make the factory unhealthy, while a reconciliation-needed request is flagged in the Broker card.
  Visible worker titles use `ISSUE · Role` or `ISSUE · R# · Role`; internal request IDs remain
  in the durable ledger and task prompt rather than the sidebar title.

Bind `server.host` to `127.0.0.1` for a local-only operator surface. The factory example enables the
dashboard at `http://127.0.0.1:4000`; it does not provide authentication for a network-exposed bind.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

## Native workspace maintenance

`factory.cleanup.native.enabled` defaults to `false`. Enabling it currently fails
startup with `native_archive_restore_capability_unproven`: the actual factory
native-chat route produces a source checkout but no managed attachment identity.
Automatic archival, restoration, and native Bazel reclamation are not shipped or
enabled. The legacy cleanup route remains unchanged and excludes native runs.

The staged coordinator has separate durable lifecycle rows and a single probe
reservation, independent of writer and delivery state. `workspace-maintainer`
resolves to the configured provider's `fast` model with `low` reasoning. Ordinary
source requests retain the writer's model allocation. An unavailable or ambiguous
attachment is remembered for that exact binding without repeatedly waking a model.
Even a supported attachment receipt does not authorize archival.

`mix factory.desktop maintenance-plan --workflow /absolute/WORKFLOW.local.md`
reads candidate and lifecycle state without adding lifecycle rows, requests,
events, or external authorization. Its `eligible` flag means **probe eligibility**,
not cleanup permission. API state exposes `workspace_maintenance` separately;
untouched runs with no lifecycle row remain available for normal review rework.
Existing probe reservations reconcile even with native cleanup disabled.

The production acceptance gate remains a complete factory-route archive/restore
cycle, same-chat access, fresh external authorization, exact remote recoverability,
and isolated cache reclamation. No filesystem removal fallback or extra attachment
may be used to bypass the missing managed identity.

## Native CI-repair policy

`factory.ticket_supervisor.ci_repair` is absent by default. Missing, disabled, or
unsupported policy does no repair-log collection, diagnosis persistence, or model
dispatch. The local implementation recognizes `diagnosis_only_v1` (bounded,
immutable diagnosis only) and `native_bounded_v1` (a separately admitted repair
claim, at most seven total code-repair attempts, respecting a lower configured cap;
the default remains five).
Schema 47 preserves existing immutable receipt bytes and references while raising
the claim-table bound from two to five; it does not reset rounds already consumed.
This is not deployment or enablement
evidence for any running factory.

Every exactly bound failed pipeline is offered to the same repair specialist;
there is no supported-failure-type list. Assertion, formatting, unfamiliar
language, infrastructure and instruction-looking log text are all diagnostic
data, not permission. Fresh MR/discussion, Jira, source-owner, native queue,
controller, capacity and human-input proofs still gate admission. Editable paths
come from the trusted committed candidate, never log filenames; agent, Git,
CI/policy/configuration paths stay protected and BUILD stays controller-owned.
Missing, malformed, oversized or inaccessible traces/artifacts are explicit
evidence gaps, not an unsupported-failure verdict. The specialist may report a
concrete inability to fix an authorization or environment problem. No-op output
never fabricates progress, CI PASS, a commit, or a push.

Diagnosis refresh and claim admission validate both complete CI snapshots against
the same candidate and project. Their comparison ignores only a change between
boolean values of a present job `runner.active` field: that is current runner
availability, not completed-job evidence. Field presence and every other raw
field remain exact, including ownership, review, pipeline and complete job data.
The original snapshots, receipt hashes and transactional preimages are retained
unchanged; this exception neither spends a retry nor relaxes freshness or safety
gates.

The collector retains all failed-job identities, fetching at most four complete
trace streams and two artifact archives per assessment. Artifact metadata and
downloads use the existing authenticated GitLab MCP session only, into private
controller directories outside SOURCE. Metadata walks are bounded to16 exact-job
requests, depth4,256 entries and256KiB metadata;
directory-only listings are followed explicitly, never treated as file evidence.
Unsafe paths, duplicate/colliding names and symlink/special entries become
stage-specific evidence gaps. The collector version advances only future
unclaimed assessments; an active claim retains its original evidence bytes.
The pinned read-only decoder bounds ZIP
central-directory allocation, members, decompression, output and time; it never
extracts files or interprets their contents. Only CRC/EOF-verified UTF-8 text is
eligible evidence. Credentials in text and filenames are redacted before durable
or model use. Combined serialized diagnosis is limited to256KiB; reductions
retain head/tail data, hashes and explicit partial/gap markers. Complete journal
rows retain the 2 MiB non-push budget. Only authenticated completed V12 push
copies use the separate fixed-path accounting described above; legacy helpers
retain their old bounds. Authority preimages are never truncated. Private
downloaded ZIPs remain sensitive local diagnostic evidence.

New generic assessments append once beside historical blocked diagnoses.
The legacy reassessment `collector_version` column now holds the canonical
ordered-pair identity of the true collector and assessment versions, both also
present in hashed diagnosis/preimage payloads. Effective selection uses only the
current pair; old claims resolve their exact original row/hash independently.
Exhaustion records the total cycles used, actual configured limit and current
assessment in durable visible run diagnostics. The configured total includes earlier
claims and evidence successors; increasing it never resets consumed attempts.
Schema 49 preserves existing rows, rowids, foreign keys, and immutable receipts
while widening the physical ceiling to seven. The global configuration may be
temporarily raised to seven and restored to five without erasing history.

Schema 50 adds an immutable human-empty-commit import journal. Explicit operator
recovery can reconcile an exact one-parent, identical-tree child of a completed
CI evidence-successor push while its old MR request is wholly unissued. Raw Git
objects, checkout identity, remote branch, GitLab MR, stopped source ownership,
contract, inputs and controller identity must agree across closing observations.
The original push, checks, worker results and request payload remain unchanged;
only that unissued request is terminally retired in the same transaction as the
import. An imported-object envelope is not a factory push or verifier result.
It clears current CI applicability and requires exact-current MR/CI readback.
Subsequent repairs retain the normal total attempt budget and genuine native
writer/controller checks. Versioned push executor v7 and history validator v4
independently verify the import journal and original physical provenance before
a later push; older helper bytes remain available for status-only readback.
Caller-provided prepared maps cannot invoke the mutation path. A claim race,
changed remote/MR, busy native owner or failed preimage comparison rejects the
import without retiring the request. This path does not resume any monitor or
change scheduler, broker, repair-budget or GitLab policy configuration.

An explicit operator `factory.ci_repair_scope_extensions` entry may authorize two
literal Go source paths for one exact run, contract, failed candidate and immutable
repair claim. It is captured in a versioned policy receipt on a newly admitted
request, never retroactively added to the stopped request or old claim. Current
owned workflow and cached policy must still match at writes, generation and push;
policy replacement revokes further use without invalidating archived receipts.
The capability expires on a different repair claim. CI logs cannot grant it, and
binary, generated, Git, agent and policy files remain outside writer authority.

Schema 48 adds an immutable evidence-successor journal for an exactly stopped,
no-edit BLOCKED CI writer when genuinely new, complete assertion-log content
becomes available. A fresh admission retains the original result, claim, round,
and blocked event, transfers SOURCE to one new request, and spends one of the
same configured total attempts. Renamed or recombined old content does not qualify.
Fresh policy, capacity, Jira, MR, input, owner, and lease checks remain mandatory;
a restart reads the existing admission rather than dispatching it again.
Successor preparation and delivery-rollover reads own one bounded GitLab read
session when the scheduler supplies none, using only its authoritative controller
workspace. Initial and closing CI reads share that session with review and
artifact reads; it closes before admission or dispatch. A supplied session stays
owned by its caller. Catalog, transaction, policy, capacity, and lease denials
remain fail-closed and do not spend an attempt.

Runs with this history use the versioned v5 push executor and v2 history validator.
They authenticate every dedicated transfer and subsequent same-attempt CONTINUE
slice through immutable instructions, owned stops, controller checks, and release
receipts. Later CI claims retain that history; ordinary verified rework does not
require CI repair to remain enabled. Historical helpers and already prepared push
intents are not upgraded. Dashboard total-attempt usage is separate from the
unchanged repair-round counter. These source capabilities do not establish live
deployment or successful ticket delivery.

After exact-candidate CI PASS and the next independent verifier PASS, a typed
delivery-only rollover may prepare a new v5 push intent for that same candidate.
It authenticates the original completed CI push, released checkout, current
verifier instructions and receipt, fresh same-MR PASS observation, and the actual
invoking tick lease. It spends no repair attempt and may finish with CI repair
disabled, including a zero repair cap. The observation expires after 60 seconds;
an expired intent is not refreshed or replayed. A completed rollover is reused
without another nonce or push. Ordinary rework still needs its own writer and
independent verifier.

Descendant repairs create fresh push and typed MR-request identities while
retaining the same draft MR and reviewers. Historical CAS proof is observed
outside SQL and revalidated against exact ledger bindings inside issuance
transactions. Old uncertain outcomes and their branch-retention hazards remain
recorded. A new SHA needs fresh CI evidence before a verifier can run.
New projectless MR requests separately pin the freshly observed native previous
turn and the ledger controller anchor in their immutable preparation audit.
Owner admission preserves both pins; result adoption advances only the captured
ledger anchor. Later unrelated controller activity is not permission to rewrite
an existing request or relax native queue, identity, or freshness checks.

The v4 physical push helper resolves only the immutable reassessment pinned by
the current repair claim; it does not select a later row or overwrite a blocked
diagnosis. Schema45 journals one exact audited v3 preissuance rejection and its
separate successor under a fresh ordinary tick. That narrowly qualified
authority-closed proof is not a generic retry or owned-exit receipt. Read-only
and paused reconciliation cannot prepare successors. Existing reconciliation
may converge a genuinely stopped timed-out push when the exact destination SHA
is observed, while preserving its real termination receipt rather than claiming
exit zero or replaying its nonce.

Applicable Go/BUILD controller generation uses an execution-pinned, independently qualified Gazelle
and gofmt toolset. An unavailable or modified toolset fails closed with
`ci_repair_generator_unavailable`; installing its resources does not enable the
controller's cached CI-repair policy. The schema 41 append-only journal binds
each owned execution and per-file byte-CAS replacement to the stopped FILE_SOURCE
writer, held SOURCE reservation, current tick, repair round, and human-input
snapshot. Unknown or partial effects hold SOURCE and forbid a new execution or
automatic reapplication. Restart readback reads the original invocation only,
including while policy or toolset availability is disabled. Non-Go repairs with
no applicable actions do not load that toolset or create fake generation
receipts, but retain the stopped-writer, exact source/round/input and commit
fences. Formatting considers actual edits and committed repair descendants,
not every unrelated Go file in the original candidate.

The original worker output remains immutable. Separately receipted formatting
and generated BUILD paths are united only for the controller's exact commit;
real generated changes count as progress even when the writer reported no edits.
Generation never grants arbitrary shell, Bazel, goimports, candidate-controlled
executables, or local product compile/test authority. Compilation and tests remain
CI-owned. Changes require a reviewed build and guarded deployment before a live
controller can use them.

## Shared role instruction admission

Native planner, writer and verifier packets embed complete role-specific shared
skills and applicable rules, including the verifier verdict contract and shared
review criteria. The explicit restricted role and structured schema take
precedence over broader actions described by a skill. Verification remains
independent and source-read-only; only the controller commits, pushes or manages
MRs. Code-verification PASS never replaces required exact-SHA manual validation.

`TicketWorkerRunner.packet/4` admits instruction bytes once for the exact dynamic
packet. Schema 43 adds append-only `worker_instruction_snapshots`; its binding
includes run, role, stage, iterations/repair rounds, candidate/base/contract,
plan and current CI/manual evidence. `read_packet/4` revalidates those facts and
uses stored instruction bytes without reading host skills or writing storage.
Task launch, preflight and failed-turn recovery use this read-only path. Shared
file edits or deletion cannot change an admitted turn or start another pass.
Missing/corrupt material fails closed. Pre-upgrade in-flight tasks without a
snapshot cannot be silently re-admitted from today's files.

An append-only `worker_instruction_task_bindings` data table links the exact
task key and full prompt digest (including any rework/recovery wrapper) to its
instruction snapshot. It is written in the existing task-prepare transaction,
before a worker starts; a prepared replay with a missing link fails closed.
No existing task row or historical receipt shape is changed. An explicitly
authorized held contract amendment can inherit the captured predecessor's exact
instruction bytes through its validated ancestry and task binding, never from
today's host files. The ordinary rework, source-lease and candidate gates still
own all permission to resume work; instruction metadata grants none.

CI repair embeds bounded `fix-mr-pipeline` diagnosis guidance using only the
controller's exact failure evidence. Neither `autopilot` nor `autopilot-mr` is a
worker dependency; no connector, retry or MR-maintenance authority is added.
Legacy/Desktop verification and manual-validation prompts embed the same review
criteria in their persisted prompts while retaining their own output contracts.
Those legacy references are complete release-pinned compilation inputs, tracked
as external resources with content digests; polling never reopens host skill
files. Updating them for a new legacy task requires a reviewed rebuild. Native
new admissions may read newer shared files, but existing snapshots remain fixed.

This integration is release-prepared, not deployment proof. Before rollout,
inspect active tasks, worker receipts and reservations; do not interrupt an
admitted old worker. After an authorized versioned rollout, read back the actual
compiled identity and planner/verifier/CI-repair packets and their snapshot
digests. Retain the unchanged shared `autopilot` compatibility copy until that
runtime evidence proves there is no dependency. Source tests alone do not
authorize its removal or establish deployed parity.

### Controller push publication and recovery

Ordinary publishing keeps its intent `PREPARED` throughout expensive history and
checkout preparation. The controller then rereads Jira, completes both physical
checkout observations, and observes the stopped source worker outside SQLite.
The transaction rechecks that exact native evidence immediately before saving
`PUSH_UNCERTAIN` with the helper PID and exact
execution bytes. Only then may the helper receive input. Jira authorization
remains limited to 60 seconds and native observations to 10 seconds; an expired
observation before publication leaves preparation retryable, not issued.
Rejected native guards log bounded evidence ages and identity-match flags, never
native messages or tool payloads.

Publication and recovery deferrals are durable, operation-scoped events. A
successful scheduler tick does not prove that a ticket advanced. The dashboard
distinguishes deferred preparation from an uncertain issued push and retains
the recorded reason across restarts.

Both ordinary and capability-recovery pushes allow Git five minutes to finish
the remote exchange. The controller's 370-second execution transport window also
allows bounded authorization/history preparation and receipt delivery; status
reads retain their separate 35-second limit. Caller loss, termination and output
overflow still stop and reap the owned process group. The scheduler rereads Jira
before finalization as well as issuance; neither authorization TTL is extended.
Callers without a refresh reader defer an expired finalization for a later
freshly authorized reconciliation, never a second push.

A stopped push with exact destination-branch readback is once-only branch
publication evidence, even when its retained receipt records a timeout or
nonzero exit. It is not proof of Git acknowledgement, MR synchronization, CI
success or independent verification. MR adoption still requires the exact
candidate SHA; stale MR references never authorize another push or acceptance
of an older pipeline. Versioned programs and the previous publishing release's
read-only receipt origin remain retained across rollout.

A completed native worker whose terminal acknowledgement was lost may retain a
genuine nonzero owned stop. Publication accepts that stop only with one exact
`NATIVE_COMPLETION_RECEIPT_V1` event atomically recorded with its recovered result.
The bounded event contains identity, original failure/stop, output digests and
safe native-read metadata, never raw native bodies. Physical validation binds
the worker's own immutable binding and access generation, including consumed
historical workers when a task has since been reused. Observation freshness is
checked at the original event; adoption must precede its authenticated consumption
or successor-disposition horizon. Missing, duplicate, foreign or altered proof
cannot waive a nonzero stop, authorize another turn, or issue another push.

The explicit `prepare-unattached-push-retirement` and
`execute-unattached-push-retirement` controller commands apply only to the
release-pinned legacy incident. They require an owned operator tick, fresh Jira
authorization, unchanged protected ledger history, and verified shutdown of the
original issuer with a qualified replacement service. They preserve the original
envelope and proof in an audit event, then atomically rotate its nonce without
changing its candidate, binding, reservation, or budgets. They do not push. Missing
execution metadata or a missing receipt alone never authorizes retirement.

The separate `prepare-preissuance-push-retirement` and
`execute-preissuance-push-retirement` commands cover one compile-pinned rejected
execution, not arbitrary uncertain pushes. They additionally authenticate the
exact rejection and execution bytes, an absent helper, and the absence of any Git
claim or receipt. After the same issuer shutdown and replacement checks, they
archive both original records verbatim and rearm the unchanged reservation once.
The recorded outcome is `GIT_NOT_ISSUED`: helper input arrived, but Git did not run.
Neither command retries a helper or changes the earlier unattached operation.

This project is licensed under the [Apache License 2.0](../LICENSE).

