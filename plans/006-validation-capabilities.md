# Plan 006 U1 — validation capabilities and proposed contract freeze

Status: **BLOCKED**, 2026-10-04. Research is complete; feasibility acceptance is not.
This document authorizes no implementation, U3, skill/config changes, Slack writes,
deployment, database access, secret inspection, commit/push or live trial.

## Decision and boundary

| Prerequisite | Confirmed | Rejected or unproven |
| --- | --- | --- |
| Slack | Installed read/send/reaction input interfaces; cursor inputs. A bounded read was attempted against the user's supplied DM permalink. | The exact-thread and exact-timestamp reads returned no message content; this is inconclusive, not a capability PASS. Typed output, complete pagination, actor/session binding and nonce-bearing mutation/readback remain unproven. |
| Deployment | Exact DocExtract cpp-test chain and migration initializer at a named ref. | Ordinary deploy and Helm rollback as no-DDL profiles. No approved migration-free deploy/restore executable. |
| Executable contract/catalog | Current producer emits declarations only. Proposed strict format below. | User approval of producer/skill extension; approved executable service/case/fixture catalog. |
| Abort/compensation | Existing skills require own-claim release; workspace release needs consumed/stopped evidence. | Durable nonce-bound cleanup grant and validation-specific safe terminal receipt. Proposed recipe is not current authority. |

Required-validation execution must remain disabled. U2's accepted parser/candidate
hardening does not supply these capabilities. “BLOCKED” means unavailable evidence
or authority, not proof that no supported solution can exist.

Only this Markdown artifact is written. Read-only Grail research was delegated;
this author is the sole artifact writer. The research skill's primary-source
workflow was followed. Applicable shared rules and Elixir instructions were read.
No source, skills, ledger, Jira/GitLab, Slack, cluster or database was changed.
No secret/token, record/document content or private Slack content was inspected.

## Source identity and reproducibility

- Symphony authoritative checkout:
  /private/tmp/symphony-ticket-implementation.Pt2zbH/checkout.
  Branch cgable/desktop-owned-ticket-chat-v1, HEAD
  52a978818875c59ccf2758ed1b728bb23e33f631. Dirty/untracked implementation was
  preserved; current byte hashes below, not HEAD alone, pin inspected source.
  The four U2 source/test hashes matched its receipt.
- Polaris: /Users/cgable/Repos/polaris, observed clean; branch
  cgable/POL-237-polaris-documentation-system, HEAD
  f414a1685f93af00cc15ce4786e25618cbd3acdd. Reads used this immutable ref.
  Repository/catalog intent is not deployed gateway state.
- Grail: /Users/cgable/Repos/grail; owner branch cgable/trs3-codeowners,
  owner HEAD f8989875826a631cc075802656e2f980f4ac5955; six untracked user
  paths preserved. All Grail facts use local origin/master =
  8bb0b5413b81eea6769b4b90343051e714caf08f, never owner working-tree files.
  No fetch: this is a pinned local snapshot, not current remote proof.
- Canonical skill files are filesystem snapshots with hashes, not Git revisions.

Read-only command forms executed:

```sh
git branch --show-current
git rev-parse HEAD
git status --short
git show REF:FILE
git show REF:FILE | shasum -a 256
shasum -a 256 FILE
git diff --check
helm pull standard-deployment --repo https://artifactory.ti-apps.aws.grail.com/artifactory/helmcharts --version 1.7.2 --destination TEMP --untar
```

REF means the immutable SHA above; FILE is an exact evidence-table path.
During initial U1 evidence collection, no service script, Helm deployment,
kubectl, AWS, grpcurl, secret tool, production SQLite or live Slack call was
used. After the user asked us to continue work independent of Slack, one bounded
read-only `helm pull` was tried twice to obtain the exact pinned chart
dependency; both attempts failed because `artifactory.ti-apps.aws.grail.com`
could not be resolved by DNS. No chart was downloaded, and no source/config or
Helm repository state in the Grail checkout was changed. Public official-doc
reads are not capability probes. No implementation test was run for this
artifact.

## 1. Slack: supported inputs do not prove required outputs

### Tool/producer identity and exact schemas

Polaris source:
infra/terraform/modules/polaris-platform/tool-schemas/slack-mcp-tool-schema.json
at f414a1685f93af00cc15ce4786e25618cbd3acdd has 18 tools and **zero**
outputSchema entries. Combined unified-tool-catalog.json has 139 tools, its
Slack names are prefixed slack___, and those also lack outputSchema.

Current ALL_TOOLS metadata was inspected without invoking Slack. Runtime names:

- mcp__codex_apps__polaris_slack___slack_read_channel
- mcp__codex_apps__polaris_slack___slack_read_thread
- mcp__codex_apps__polaris_slack___slack_send_message
- mcp__codex_apps__polaris_slack___slack_add_reaction
- mcp__codex_apps__polaris_slack___slack_read_user_profile

Each returns generic Promise<CallToolResult>, not a typed Slack result schema.
Property names/types agree with the pinned producer. Exact input property sets
below: R required, O optional; every input is an object.

| Tool | Input properties |
| --- | --- |
| slack_read_channel | channel_id:string R; limit:integer O; cursor:string O; latest:string O; oldest:string O; response_format:string O |
| slack_read_thread | channel_id:string R; message_ts:string R; limit:integer O; cursor:string O; latest:string O; oldest:string O; response_format:string O |
| slack_send_message | channel_id:string R; message:string R; thread_ts:string O; reply_broadcast:boolean O; draft_id:string O |
| slack_add_reaction | channel_id:string R; message_ts:string R; emoji:string R |
| slack_read_user_profile | user_id:string O; include_locale:boolean O; response_format:string O |

The snapshot does not set additionalProperties:false or encode prose limit ranges
as JSON Schema constraints. Descriptions specify channel 1–100 (default 100),
thread 1–1000 (default 100), detailed/concise formats. Runtime limit is number.
The controller must enforce integer/range constraints itself.
Send is idempotentHint:false; reaction-add is idempotentHint:true. Hints are not
successful execution or readback evidence.

Send has no nonce, metadata, client_msg_id or authenticated actor argument.
Profile read defaults to current user, but promises no output schema or binding
to the credential session used by sends. Display names and skill-documented
U02N90HQLQ1 are not current authenticated-principal evidence.

```sh
git show f414a1685f93af00cc15ce4786e25618cbd3acdd:infra/terraform/modules/polaris-platform/tool-schemas/slack-mcp-tool-schema.json |
  jq '{tool_count:(.tools|length),output_schema_tools:[.tools[]|select(has("outputSchema"))|.name]}'
# {"tool_count":18,"output_schema_tools":[]}
```

Source README calls this a drift-prone hand-captured snapshot, captured
2026-07-24 from https://mcp.slack.com/mcp, without drift detection.
outputs.tf:211–233 identifies upstream/OAuth intent, not actual scopes or identity.
No locally owned upstream Slack producer implementation was identified.

Historical primary receipt, reread without repeating its live call:
/private/tmp/symphony-file-source-readonly.gcKsyW/polaris-format-final-attempt/receipt.json,
SHA-256 a302af7a2520f4446a095723298e7f5c52db463f1e85b39be43b0aa51e6d5d1b.
It records one polaris.slack___slack_read_channel on C0476K986UV, limit 1,
detailed; decoded content/0/text has messages and pagination_info as **plain
strings**, not typed fields. No message text retained; message_count null,
one tool call, zero mutations/approvals, owned process shutdown recorded.
Its probe_decoded_utc is 2026-10-04T21:14:11.775478+00:00. This is historical
scoped format evidence, not current freshness, actor proof or complete-page proof.

### Alternatives: do not assume Polaris must change

[Official Slack MCP overview](https://docs.slack.dev/ai/slack-mcp-server/)
currently lists Get reactions, absent from the inspected snapshot, and describes
Streamable HTTP plus registered-app/OAuth requirements. A catalog refresh through
an already approved authenticated client is the first alternative to investigate;
a Polaris code change is **not yet proven mandatory**.

[conversations.history](https://docs.slack.dev/reference/methods/conversations.history/)
and [conversations.replies](https://docs.slack.dev/reference/methods/conversations.replies/)
document typed messages/user/ts/cursor results.
[auth.test](https://docs.slack.dev/reference/methods/auth.test/) documents
team_id/user_id and optional bot_id.
[reactions.get](https://docs.slack.dev/reference/methods/reactions.get/) documents
reaction name/count/users; users can be incomplete but include the authenticated
reacting user. Actor absence is not proof nobody reacted.
[chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/)
documents channel/ts/message and metadata; metadata token eligibility/visibility
needs review and is not available in the installed send schema.

Direct Web API is a possible typed adapter, **not installed capability**:
app registration, approved scopes, credential custody/session binding, callable
transport and producer hashes remain unproven. No credential/API/private RPC
inspection or call occurred. KB exports/ingestion are not authenticated fresh
coordination/readback paths.

### Proposed strict controller interface — not approved or implemented

```text
identity(session) -> {:ok, Principal} | {:error, code}
history(session, channel_id, oldest, latest, cursor, limit) -> {:ok, Page} | {:error, code}
thread(session, channel_id, parent_ts, cursor, limit) -> {:ok, Page} | {:error, code}
claim(session, binding, approved_house_text) -> {:ok, SendReceipt} | {:error, code}
release_reply(session, binding, claim_ts, approved_house_text) -> {:ok, SendReceipt} | {:error, code}
release_reaction(session, binding, claim_ts, "done-check") -> {:ok, ReactionReceipt} | {:error, code}
readback(session, binding, claim_ts) -> {:ok, ClaimObservation} | {:error, code}
```

Required typed contracts:

- Principal: provider/app/team IDs, actor_user_id, optional bot_id, opaque
  credential-session binding, observed_at. Tokens excluded.
- Page: provider/tool/schema identity; channel and frozen time bounds;
  request_cursor; messages[]; next_cursor; has_more; history_limited;
  observed_at; raw_result_sha256; complete:boolean.
- Message: channel_id, ts:string, thread_ts:string|null, author_user_id,
  subtype/bot identity if present, text, edit timestamp if present, reply_count;
  reactions[{name,count,actor_user_ids,actor_list_complete}].
- SendReceipt: channel_id/ts/thread_ts, author/principal binding,
  attempt_key/action_key/controller_nonce, typed message/readback digest/time.
- ReactionReceipt: channel_id/claim_ts/emoji/authenticated actor/attempt/action
  plus independently observed readback, not a success string.

Unknown actor/type or absent required field is capability_missing; never infer
IDs from rendered prose. Timestamps are decimal strings, never floating point.
Persist nonce/action identity before SENT. Nonce must survive provider readback,
either in an approved provider-native field or an **explicitly approved visible
message convention**. Current bare house-style claim plus current send schema
does not prove this. A nonce thread reply is an additional write and alone cannot
reconcile ambiguous top-level claim creation. Do not silently alter house style.

[Official pagination rules](https://docs.slack.dev/apis/web-api/pagination/)
say short pages may have more data. Freeze window/channel/thread/principal,
follow exact cursors until typed terminal cursor/no contradictory has_more.
Require terminal-page evidence; follow every nonterminal cursor even after a
short/empty page. Do not fabricate a required empty second page when the first
page authoritatively terminates. Reject loops, malformed/missing cursor metadata,
history limitation, failed page or changed identity.

Proposed bounds: 100 messages/page, 20 pages/window, 64 KiB/page, 1 MiB/window,
5 minutes collection. Bound hit means INCOMPLETE/BLOCK, never free. Relevant
threads must also be completely observed. Slack is advisory coordination, not
an atomic cross-user lease; local one-host reservation plus fresh post-claim
contention readback is required. Ambiguous human hold blocks deployment.

Independently verify exact claim channel/ts/owner/nonce/services/environment.
Release requires both **same authenticated actor's** done-check and nonce-bound
thread reply; reaction presence/count alone is insufficient. Ambiguous send is
SENT_UNKNOWN: reconcile same action by readback, never blindly resend.

### Slack probe disposition

The user supplied one Slack permalink for their own DM and then directed us to
skip the test and continue with implementation. Two bounded read-only calls used
only that exact DM and timestamp: `slack_read_thread` returned a thread header
with no messages; `slack_read_channel` over the exact timestamp returned no
message content. No search, reply, reaction, or other Slack access occurred.
These empty responses are inconclusive, not a test PASS and not evidence that the
typed Slack capability exists. Per the user's direction, do not repeat this
probe or ask for another Slack fixture as the next step.

Do not create fixtures in U1. The no-DDL profile, approved executable action
catalog, and compensation authority remain separate unresolved prerequisites.
The manual-validation executor remains disabled until those exact contracts are
resolved. Core ticket-chat work may continue only where it does not assume this
executor or weaken its gates.

## 2. DocExtract no-DDL deploy and restoration

All Grail source below is at 8bb0b5413b81eea6769b4b90343051e714caf08f.
Commands are source excerpts, **not executed procedures**.

```text
doc-extract/scripts/deploy-to-test.sh:7–21
  [IMAGE_TAG]; deploy-service doc-extract cpp-test ${image_tag}
ops/releng/scripts/deploy-service.sh:37–51
  absent tag -> bake/push working checkout
  deploy-pods --image-tag-spec=${tag_path}=${image_tag} deployment cluster
ops/releng/scripts/deploy-pods.sh:18–53
  options only --debug, --dry-run, --image-tag-spec
  helm dependency update
  helm template --values=values-${cluster}.yaml .
  helm upgrade --install --kube-context=${kube_context}
    --values=values-${cluster}.yaml ... ${deployment} .
doc-extract/chart/values.yaml:16–25
  db-migrations init image: doc-extract
  bin/sh -c './collate_and_goose $(DB_USER) $(DB_PWD_FILE)
    $(DB_HOST):$(DB_PORT) $(DB_NAME)'
db/docker/collate_and_goose.sh:40–43
  ./goose -dir "$TEMP_MIGRATIONS_DIR" -include-missing mysql "$DB_STRING" up
ops/releng/scripts/rollback-pods.sh:7–33
  DEPLOYMENT KUBE_CONTEXT [ABSOLUTE_REVISION | RELATIVE_REVISION]
  default relative revision -1; helm rollback --kube-context=... deployment revision
```

deploy-service.shlib:16–25 produces timestamp/short-HEAD/dirty-count tags,
not a clean exact-candidate/image-digest gate. A supplied image skips baking,
**not** migrations. BUILD.bazel:37–61 bundles migrations, collate_and_goose/goose.
00033_AddJudgeModelsColumn.sql:23–34 contains ALTER TABLE and Down DROP COLUMN.
Checking only branch-added migrations cannot prove existing pending/missing
migrations won't apply. Runtime entrypoint/image contents also need audit.

Static scripts README:45–49 declares cpp-test/default, dev/default,
sandbox/default; live cluster immutable identity/namespace state is unverified.
deploy-pods provides no namespace argument, --wait, --atomic or abort trap.
Helm revision equality is not running imageID/readiness proof.

Critical dependency gap: doc-extract/chart/Chart.yaml:7–10 pins remote
standard-deployment **1.7.2** in Artifactory; checked-in
ops/helm/charts/standard-deployment/Chart.yaml identifies **1.8.1**.
Checked-in templates/_helpers.tpl:177–184 has an initializer enabled gate,
but it is NOT proof of effective 1.7.2 rendering. Actual dependency bytes/render
and all init/hook/app-startup paths remain unavailable to this profile proof.
No dependency download/install or live cluster call was performed.

Rejected as trusted pilot profiles:

- Ordinary dev/test/sandbox deploy, even with exact candidate tag: can run DDL.
- Migration baseline query plus branch-only diff: observation, not enforcement.
- rollback-pods/Helm rollback: may restart migration-capable template; does not
  restore schema or prove exact owned target and readiness.
- goose down/down-to: DDL outside unattended authority.
- Worker-only deployment: worker docs say server owns migrations; it is not a
  substitute for server validation.

### Exact proposed profile scope — separately approved cross-repo work

- Grail doc-extract/chart/values.yaml and Chart.yaml: preserve default migrations,
  pin/prove effective dependency and explicit validation-only no-migration mode.
  Do not name a guessed remote initializer template as implementation scope.
  Freeze that exact dependency source/path/hash before dispatch.
- Grail doc-extract/scripts/factory-validation-profile.sh and
  factory-validation-profile.bats (proposed new files): fixed cpp-test/default/
  doc-extract argv allowlist; exact image/render/ownership/restore verification;
  no arbitrary shell, Helm values, URL or target parameter.
- Symphony elixir/priv/factory_validation_catalog/v1.json and fixtures/
  (proposed new paths); validation_actions.ex, validation_slack.ex,
  validation_deployment.ex, validation_cases.ex under
  elixir/lib/symphony_elixir/factory/ (proposed adapters, not existing capabilities).

Proposed profile ID docextract.cpp-test.image-only@1 / restore-image@1 is NOT
approved. No executable hash exists. It must pin immutable cluster identity,
context/namespace, Deployment UID/container names, chart/dependency/render digest,
script/image/source/base/candidate digests and least-privilege authority. Render
and audit all init containers, chart hooks/Jobs, lifecycle hooks and entrypoints:
no migration/DDL path on deploy **or restore**. Prior image/config must be
compatible with the same no-DDL restore profile; arbitrary old Helm revision
cannot be restored safely by assumption. Next proof is static/render-only,
not live deploy/cluster/secret access.

```text
observe_target(attempt, profile) -> PreviousDeployment
deploy_exact(attempt, profile, verified_image_digest, expected_previous) -> DeploymentReceipt
verify_candidate(attempt, receipt) -> ImageObservation
restore_exact(attempt, compensation_grant, expected_candidate) -> RestoreReceipt
verify_restored(attempt, receipt) -> ImageObservation
```

Each returns {:ok, typed_observation} or {:error, precise_code}. Required outputs:
PreviousDeployment carries immutable target UID, resource version/generation,
exact named-container image digests, template/config digest, readiness/time.
DeploymentReceipt carries before/after identity/version/generation, candidate,
image/render/profile digests, attempt/action/claim nonce and request/result hashes.
ImageObservation compares desired image digest **and running imageID**, observed
generation/ready replicas and no migration/hook creation. RestoreReceipt carries
captured prior identity, mutation-time compare-and-set ownership preconditions,
exact restored running image/config/readiness. Secret values excluded.
No approved profile, immutable cluster mapping or safe prior-image proof is
available; these are blockers, not values for a model to choose later.

### Independent follow-up: exact Helm dependency

The local Helm executable is available, but the exact `standard-deployment`
1.7.2 package is not cached under the inspected Helm cache locations. A direct
read-only pull from the chart URL pinned in the Grail source could not resolve
the Artifactory hostname (`dial tcp: lookup artifactory.ti-apps.aws.grail.com:
no such host`). No retry through an alternate hostname, cached credential,
repository mutation or proxy was attempted. Consequently the effective 1.7.2
template/render behavior remains unproven; the checked-in 1.8.1 helper is not a
substitute. This DNS limitation is independent of Slack.

## 3. Typed executable contract and catalog

Primary current producer: Contract.manual_validation_definition/1,
contract.ex:279–439. It bounds Markdown at 1 MiB, section at 16 KiB, prose fields
at 4096 bytes, cases 1–20, syntactic services 1–8, coordinated environments.
It is not an executable catalog or safety proof. TicketWorkerRunner.packet/4
emits DECLARATIONS_ONLY; role_input/4 still rejects manual-validator with
ticket_validator_authorized_transport_required. Policy's allow_database_ddl
rejection and capability-name checks are not backend proof.

Canonical specify-work/references/ticket-contract.md emits human Manual
Validation prose. No machine block/catalog producer is present. Proposed
extension needs explicit user approval; no skill file was modified.

### Proposed v1 — approval required before U3

Retain human prose; add exactly one visible top-level
## Factory Validation Actions and one JSON fence. Reject hidden/fenced/quoted
headings, duplicate block/JSON keys, comments, unknown fields, malformed UTF-8
and trailing executable content. Required:no needs no machine plan and cannot
execute one; Required:yes without block is validation_actions_missing.

Illustration only: none of these profile/fixture IDs is approved.

```json
{
  "version": 1,
  "environment": "cpp-test",
  "services": ["doc-extract"],
  "deployment_profile": "docextract.cpp-test.image-only@1",
  "cases": [{
    "id": "MV-1",
    "case_profile": "docextract.empty-documents-request@1",
    "synthetic_fixture": "docextract.empty-request@1",
    "parameters": {},
    "expected": {}
  }],
  "teardown_profile": "docextract.cpp-test.restore-image@1"
}
```

Normative proposed schema:

- All objects additionalProperties:false; all illustrated fields required;
  version integer const 1; environment enum cpp-dev/cpp-sandbox/cpp-test,
  further narrowed by approved profile. No auto-retarget.
- Unique services 1–8, exact approved IDs and normalized human declaration match.
  Ordered unique cases 1–20, MV-[1-9][0-9]*, exact human MV order/set match.
- Profile/fixture IDs at most 128 UTF-8 bytes, exact versioned catalog lookup,
  pattern [a-z][a-z0-9.-]*@[1-9][0-9]*.
- parameters/expected are strict **profile-owned** schemas, not generic
  arbitrary JSON predicates. Empty objects only where schema requires const {}.
  No command, expression, SQL, arbitrary URL/path, credential or script field.
- Block at most 16 KiB; Markdown at most 1 MiB; depth at most 6; strings at most
  4096 bytes; parameters/expected each at most 2 KiB/16 keys. Null only where a
  profile explicitly allows it; no floats for identities/times/durations.
- Deploy/restore each at most 600 seconds; case at most 120 seconds; total
  cases at most 600 seconds; attempt at most 30 minutes. These are controller
  ceilings, not ticket-controlled knobs. Ceiling reached means abort.

ValidationPlan.compile(contract, candidate_sha, catalog) ->
{:ok, plan} | {:error, precise_code}, pure; no model/shell/connector.
Candidate is exact lowercase 40-hex current ledger/verifier SHA, never JSON input.
Bind issue/run/revision/normalized Jira-readback contract digest, candidate,
catalog/profile/fixture/source hashes. Deterministic digest: lexicographically
sorted UTF-8 JSON keys, no whitespace, array order preserved, strict integers,
duplicate keys rejected. Jira-altered machine data must fail/re-author/readback;
never hash only pre-write draft.

Fixed action sequence: claim -> observe_previous -> deploy_exact ->
verify_candidate -> run_case(each ordered case) -> restore_exact ->
verify_restored -> release. Action key hashes attempt key, plan digest, fixed
index/kind. No ticket-selected dispatch/module atom/shell. Input changes stop
forward work; old compensation obligations remain separately bound.

### Catalog source, approval and concrete case seed

Proposed elixir/priv/factory_validation_catalog/v1.json:
required version:1, source_revision, services[], deployment_profiles[],
restore_profiles[], case_profiles[], fixtures[], approvals[]; all objects strict.
Each entry pins id/version, repo/ref/SHA/path/source SHA-256, typed parameter/
predicate/result schema hashes, target/service allowlists, synthetic provenance,
timeout, no-DDL/render evidence, restore compatibility and trusted approver/source
digest. Controller-owned catalog resolves paths; tickets cannot supply them.

Grail service owner must approve deploy/restore/case/fixture safety; factory owner
approves adapters/schema/authority; source-bound human approval is required.
Scoped source search found no approved validation catalog in doc-extract,
doc-extract-worker, doc-extract-eval or go/src/grail.com/doc-extract; Symphony
factory/priv/integrations file-name search likewise found no validation/Slack
profile/catalog implementation. These are scoped absence observations, not a
global nonexistence claim. Effective executable approved catalog is **empty**.

Concrete future case seed, NOT approval/live execution:
docextract.proto.v1.DocExtractService/GetExtractionDocuments with empty request {}.
doc-extract/proto/v1/doc_extract.proto:70–74,276–280 defines RPC/request;
go/src/grail.com/doc-extract/server/grpc/extraction.go:321–326 returns
InvalidArgument “extraction_id is required” before audit defer/service access.
extraction_test.go:762–771 asserts nil response/InvalidArgument.
Auth interceptors and environment profile still require audit/approval. This
expected-error seed returns no stored documents; do not substitute ListExtractions
or unbounded record reads. Future profile should use const {} request, fixed RPC/
approved endpoint/auth context, exact code/message predicate, synthetic-only
provenance, at most 120 seconds, no database write or case teardown.
Its expected object may be a strict const approved predicate, not an invented
runtime model expectation. Fixture/RPC seed alone cannot validate arbitrary feature
requirements or supply a complete catalog.

Proposed canonical extension scope:
/Users/cgable/.agents/skills/specify-work/SKILL.md,
references/ticket-contract.md and an explicitly approved new
references/validation-actions.md if needed. No provider copies, no extra runtime
specification/planner loop or routine new approval prompt. User approval of this
extension and concrete catalog entries is still needed.

## 4. Abort/compensation grant and exact recipe

Current run-manual-validation requires exact own-claim finally release;
deploy-service defines bare claim plus done-check/thread reply.
General skill discussion of migration rollback is DDL and rejected here.
No existing inspected durable grant authorizes post-cancellation image restoration
with all identities below. This section proposes, but does not grant, authority.

Admission must persist:

```text
grant_key/run_id/attempt_key/plan_sha256
original revision/contract digest/candidate SHA
reservation_key/generation/controller_owner_id
environment/service profile + immutable cluster/namespace/resource identity
provider/app/team/authenticated actor/session/controller_claim_nonce
deploy_profile_sha256/restore_profile_sha256
allowed_cleanup = [restore_exact_previous_image, verify_restore,
  add_own_done_check, send_own_release_reply, verify_release]
cleanup_deadline/status/escalation_owner/authorization_source_digest
```

Persist nonce/action identity before claim; bind exact channel/claim ts only after
authenticated readback. After observe_previous, narrow grant to captured target
UID/resource version/exact prior image/config and candidate deployment identity.
Finalize before first deploy. Missing prior/restore compatibility proof blocks deploy.
Each mutation has durable PREPARED/SENT/OBSERVED/CONSUMED phases.

Recipe bound to the **same** original attempt/reservation/claim/action:

1. Expiry/cancellation/replaced contract/candidate or authorization drift atomically
   stops forward deploy/test work. Retain SENT_UNKNOWN journal entries and original
   cleanup grant. Normal forward expiry does not revoke pre-authorized compensation.
   Explicit cleanup revocation/deadline stops mutation and escalates with retained
   reservation; do not silently remove stale checks.
2. Stop/prove shutdown of owned actors/processes using owned-process receipts.
   TTL/socket loss/model completion/PID absence alone is insufficient. Reconcile
   in-flight action before deciding whether deploy occurred. No new worker/attempt.
3. If bounded readback proves no deploy and original prior target unchanged, skip
   restore. Otherwise require our exact candidate deployment, fresh own Slack claim
   and immutable target/profile identity; restore only captured prior image/config.
   Enforce mutation-time compare-and-set UID/version/expected template, not a racy
   earlier read. Foreign owner/UID/revision, unknown deploy/claim, missing ownership
   or changed restore identity means RECONCILE_REQUIRED, no mutation/reservation
   release. Never restore someone else's target.
4. Verify prior desired/running image/config digests and readiness, no migration/
   hooks. No schema/data rollback, arbitrary Helm revision, new candidate deploy
   or teardown inferred from prose.
5. Release only own exact channel/claim ts, same authenticated actor/nonce.
   Reconcile reaction and reply separately; reaction retry only after ownership
   readback. Never blindly resend SENT_UNKNOWN reply. Verify both own done-check
   and nonce-bound own reply before marking free. Missing proof reports exact
   claim ts for human cleanup while reservation remains held.
6. Consume validation-specific terminal receipt: original grant/action/result
   digests, owned-process stop, restore-or-no-deploy proof and Slack release proof.
   Only then release REVIEW. WorkspaceAccess.release/4 currently requires consumed
   WorkerEvidence and stopped checks; do not fabricate worker completion to bypass
   it. U4 needs an explicit compatible validation terminal-release path.

Outcomes: ABORTED_SAFE (all cleanup verified), RECONCILE_REQUIRED (uncertain remote
state/ownership), BLOCKED_AUTHORITY (missing/revoked/deadline grant). Last two retain
reservation and escalate; no source/rework starts. Cleanup retry reuses original
action identity within approved deadline/provider Retry-After, never unbounded.
Cases passing without cleanup/readback is not PASS. Slack remains advisory:
foreign takeover requires reconciliation despite general skill text that historical
cgable claims do not block.

## Evidence manifest

Hashes are exact bytes; selected dependencies only, not a full checkout snapshot.
Paths in the next table are Symphony-checkout-relative:

| Path | SHA-256 |
| --- | --- |
| plans/006-complete-desktop-ticket-chat.md | 943e6627d63466c445b8b9acddbc368f45a9c76923cdeae752cb4541b011b8f2 |
| plans/receipts/006-U2-validator-hardening.md | 186fb1ef1b6458740c44d0d603a844e613f9c76bff76487e6d674ffc7678ff53 |
| elixir/lib/symphony_elixir/factory/contract.ex | 7d92670793e8fb0d63a53a54dc02315029b6410db1f05588fa21ba35a02f5d95 |
| elixir/lib/symphony_elixir/factory/ticket_worker_runner.ex | 4184dc4284c241b8fae46279d88b1feac450fb5d2ee2b0de9b5015c6d1d49e1d |
| elixir/test/symphony_elixir/factory_contract_test.exs | aece7665949b0e0ac74ecc1418a26f6dd774b50b961cd051fce8f619caf807ee |
| elixir/test/symphony_elixir/factory_ticket_worker_runner_test.exs | 92be24cfce06f76c7fdc3d33fcc343b0473f0921d1b25612b3d2bc60a554fb1c |
| elixir/lib/symphony_elixir/factory/workspace_access.ex | a259426130358e3075956314911e13a79aaeac40273509bd24e412655506b8a7 |
| elixir/lib/symphony_elixir/factory/worker_evidence.ex | 19a2a7169befa9b03fbfda213d5f08f3447905e4e45245dc2130557f535195e1 |
| elixir/lib/symphony_elixir/factory/store.ex | 9c8af3d30775dfef59146ed17079855558f68afe91eb83bb83aac42bc8e8387d |
| elixir/lib/symphony_elixir/factory/policy.ex | c8619d4b3319f3c0262b0fe25a5bb94edaf945602818cafe3b8bb58f239f99b2 |
| elixir/lib/symphony_elixir/config/schema.ex | 7d52aa9634795d122e04bd8ff1cb8c5dda73833c231c0442fc8d63904c035cfb |

Polaris at f414a1685f93af00cc15ce4786e25618cbd3acdd.
Paths relative to infra/terraform/modules/polaris-platform/:

| Path | SHA-256 |
| --- | --- |
| tool-schemas/slack-mcp-tool-schema.json | 0bcc20a70ef1328f7518d9ce767ae7a5cb67a5acf2002f39b5f3014ad6f43b4c |
| tool-schemas/unified-tool-catalog.json | ec7e8804cbc3b3b5c539b061695cbbd8838a47fae5bd69be6c66fc20fb263cb4 |
| tool-schemas/README.md | 06306c146665ad1f89a26c4cfd6340b54e7144f8008a6296e1e0a608fbc7b7a0 |
| outputs.tf | d8c1f99cc6eaf7afb57a83239ce2d789d7022b281c8cfec4b6b8d633ef9d7f20 |

Five selected name/inputSchema stream SHA-256:
8b597b723c326613f4cc1b6f7b7bb6cb981e9f80a4aae51baf28c650b7d71457.
Producer-order jq -cS selection of read_channel/read_thread/send_message/
add_reaction/read_user_profile, projecting {name,inputSchema}. No runtime output
schema exists to hash. Official docs above are URL/date observations, not immutable
producer snapshots or native capability proof.

Grail at 8bb0b5413b81eea6769b4b90343051e714caf08f:

| Path | SHA-256 |
| --- | --- |
| doc-extract/scripts/deploy-to-test.sh | 3b47ca3bcc36a56088946b7296aeb8c5f8c9da7ee0570027f311842600dd0174 |
| ops/releng/scripts/deploy-service.sh | 8a1d7568e93e310a85a2ed64c47a69e5df2613b5eb7d2f1df44cda8997bed919 |
| ops/releng/scripts/deploy-service.shlib | c0255a0b4b95d6f75c36bcda470e142082d0c6305c295d13948d7110e157d88a |
| ops/releng/scripts/deploy-pods.sh | 94433bf808a533df0dcc82fd984b22dfab9c9d8c0ab9d8621fc521b2ab8e5b77 |
| doc-extract/chart/values.yaml | 432556dffdc8de5cb7b360f855ed25d9f4bb453d0823064f69531fa7e6c91de7 |
| doc-extract/chart/values-test.yaml | d4a2171def2ae6b17eaa7df347f51c1f73b4bc9b56322b9573b237f3c24cda40 |
| doc-extract/chart/Chart.yaml | 6e12e322a2f815cad6e4389dac44312f44ce90f790606d029c17d13b1919eec5 |
| db/docker/collate_and_goose.sh | a083e0c5030297d65dd535b1687d7af29cce148f6a6a5da3faa6206235e2b445 |
| ops/releng/scripts/rollback-pods.sh | c6a3018f4be8e4929488d3a7a316705d9728b931b5592d5700f3861d99d00f35 |
| ops/releng/scripts/show-pods-revision-history.sh | 1e35696b8e56c617264a9a4811633e1d57eafa1c93bbe3bf11a24c776ddb7997 |
| doc-extract/BUILD.bazel | 9b2cfe941f7a2b3f7a761e7ebf1a1e05bda0b560da1678a1270a1e5e9eac3443 |
| doc-extract/scripts/README.md | ea17de36774a023c2c7482d01df4ae6680554448572e3c1846b54a6847ce7d07 |
| doc-extract-worker/scripts/deploy-to-test.sh | 6a5f973cb4b935950f76e3a2cc35986708c319b19ff7d3b0c88a0c1a953e7a36 |
| doc-extract-worker/README.md | 09be8174908c590c9bca2bfb9edf95cd1641ba929b4ae84b4652903458522976 |
| go/src/grail.com/doc-extract/server/db/migrations/00033_AddJudgeModelsColumn.sql | f7cbb2f174f1e32201e26f12e763b6524ba54d0d992db4efb180508afd0ed9d8 |
| doc-extract/proto/v1/doc_extract.proto | 1cbd2a01de8962a53c1b3807a48424cbfe75ce9faf51d8a72b0a9c2fef115bb0 |
| go/src/grail.com/doc-extract/server/grpc/extraction.go | 867b144f7a66f3c7ae26955961659a39d38c619c398533b7b9518f89f1851f52 |
| go/src/grail.com/doc-extract/server/grpc/extraction_test.go | 32b9e08fd4365d081cd3ad90349fd3892d56d9fb7e313af4bceabf0f1bf49722 |
| ops/helm/charts/standard-deployment/templates/_helpers.tpl (1.8.1, NOT effective 1.7.2 proof) | ba9a6743dbc9b06f1499e1e14c618e62b1d1f283df6723ac4db3b4f27fbe1180 |
| ops/helm/charts/standard-deployment/Chart.yaml (1.8.1, NOT effective 1.7.2 proof) | 12b28855651e81da956bde80029aad660ad97a71365e885f362253402bbbe6fd |

Canonical skill snapshots, paths relative to /Users/cgable/.agents/skills/:

| Path | SHA-256 |
| --- | --- |
| run-manual-validation/SKILL.md | 55b0691f17621574ae077f00874b8de96494f2ef2221756074c2d8b47907c384 |
| run-manual-validation/references/result-contract.md | e281099a365e34f5dc173dbaed5aa190a6b08abe1aca6a711cedf3e33604e2e5 |
| deploy-service/SKILL.md | 1f9b0d5ee9fdda3675112577077d0a3ed61363191dc9dfaeb87d83eef0367d07 |
| test-service-endpoints/SKILL.md | c74ad5571655d1e8926221c6ebc4a18f27c7c49d514fa5e65c9e441d23b3fefe |
| specify-work/SKILL.md | 981a3b901750bad02b864ffe75c0ef86bcf51fe71fcd0c24fcdb9cc9fe01ae96 |
| specify-work/references/ticket-contract.md | 45999400e3eef3e51f701f48ac5c675a8e29b87694475173e60f6ffeb6e04720 |
| specify-work/references/authorization-record.md | 792b84276573a17ffa4e421736b7ac1c95954229d0c0b53db942f3d4ef4ee471 |

## Independent adversarial review

Verdict: **ACCEPTED_AS_BLOCKED** (GPT-6.1 Sol, high; fresh read-only review).
This means the U1 investigation is complete and safely gates U3; it does not mean
the missing operational capabilities are available or that implementation may
start. The reviewer confirmed the artifact hash and all 42 manifest entries,
including the selected Slack input-schema digest, pinned refs and historical
sanitized Slack receipt. No report-blocking defect was found.

The review independently confirmed that:

- Slack inputs are concrete, while typed outputs, authenticated actor/session
  binding, nonce readback and complete-pagination evidence remain unproven.
- The inspected ordinary deployment can run migrations and is not a trusted
  no-DDL deploy/restore profile. The 1.7.2 remote dependency versus 1.8.1 checked-in
  source gap blocks render proof; absence claims remain scoped, not global.
- The action schema is strict and bounded, binds candidate identity to the ledger,
  excludes arbitrary commands, and explicitly requires producer/catalog approval.
- Compensation remains bound to the original attempt, reservation, target, claim
  nonce and action; uncertainty retains the reservation and does not resume forward
  actions.
- The supplied exact-DM read returned no message content; the user directed us
  to skip further Slack testing. No capability PASS is claimed.

Remaining non-dispatch-ready items include exact exhaustive ClaimObservation
fields/error codes, effective executable/profile hashes, dependency/render proof,
and validation terminal-release implementation. These belong to later gated work,
not to a guessed U3 adapter.

Review was read-only; no live Slack, Jira/GitLab, cluster, secret, database,
source-edit or implementation action occurred.

## Stop and exact next decisions

1. Slack read probe was skipped at the user's direction after two empty responses.
   Do not retry. Typed read and write/nonce evidence remain an explicit capability
   gap for unattended manual validation.
2. Approve separate Grail no-DDL image-only profile design and dependency-source/
   render proof scope; no live cluster/secret/deploy discovery.
3. Approve canonical Specify Work machine-block/catalog extension and concrete
   source-bound service/case/fixture entries.
4. Approve compensation grant/cleanup authority and validation terminal receipt
   design; later prove restart/expiry/cancellation/owner drift/uncertain actions.

Next is a human capability/profile/format decision, not U3. Missing adapter or
profile implementation hashes cannot become a vague “implement the adapter”
dispatch packet. Keep Plan 006 gated and runtime disabled.

**U1 BLOCKED — input/catalog facts and negative no-DDL proof are pinned.
Typed Slack/nonce proof, a trusted no-DDL deploy/restore executable, approved
producer/catalog extension and durable compensation authority remain unavailable.**
