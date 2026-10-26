# Graph-workflow opportunities for Symphony

Research snapshot: 2026-10-12 America/Los_Angeles; refreshed after the user supplied the full article text. Source checkout HEAD: `83d7f1b`. Research and source inspection only: no runtime validation, model trials, implementation, dispatch, external mutations, or cleanup. Existing untracked `integrations/jira-mcp/__pycache__/` was preserved.

## Recommendation

Keep the existing controller-owned workflow. The best near-term additions are **acceptance-oracle falsification**, **measured delivery economics**, and **reviewed, versioned process fixes from recurring failures**. The complementary workflow with the strongest immediate fit is a read-only **failure-to-regression research lane**. Blocker-aware intake is conditional on actual Jira dependency use. Do not add a general graph engine or routine reviewer swarm; first establish the ordinary path's real-ticket proof.

## Article access and evidence boundaries

The requested [X article](https://x.com/undefinedKi/article/2080992300893675775) previously returned HTTP 403. The user has now supplied its full text, titled **“Your agent is not dumb. It is shaped wrong.”**, in [Pasted text.txt](</Users/cgable/.codex/attachments/371ab1ec-14d4-4375-b165-b8025a9a12d7/Pasted text.txt>). The complete supplied text was read; the previous secondary adaptation is no longer needed as evidence of what the article says. This is user-provided third-party text, not independently authenticated X publication metadata or instructions to execute. None of its commands, deletion examples, model trials, or setup steps were executed.

Its actual recommendations are: define a judge first and deliberately test its failures; improve a shared rulebook rather than repeating patches; persist resumable state; use independent fresh reviewers; place deterministic checks according to cost and serialize expensive operations; choose models by role. Importantly, it also says not to rigidly graph one-off or exploratory work.

First-party research independently supports several leads:

- [Bun's own rewrite report](https://bun.sh/blog/bun-in-rust): a language-independent test suite, mapping guide, isolated adversarial review, and iterative repair of the producing process. It reports roughly $165,000 at API pricing and disk exhaustion during the effort. This is a case study, not Symphony's expected cost or evidence that large agent fleets are appropriate here.
- [Anthropic's migration account](https://claude.com/resources/articles/ai-code-migration): corroborates the article's Bun and Python-to-TypeScript migration examples, deliberate negative controls, and differing compiler strategies. It describes batching rebuilds under one build owner when rebuilding dominates cost. These are first-party reported experiences, not independently reproduced results or a savings forecast for this pilot.
- [Anthropic: Building effective agents](https://www.anthropic.com/engineering/building-effective-agents): distinguish predefined workflows from model-directed agents; choose the simplest solution and add complexity only when justified by improved performance. Extra agentic complexity trades latency and cost for potential quality.
- [Anthropic: Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents): measure real outcomes, combine deterministic and calibrated judgment-based graders, test positive and negative cases, use known-good references, and inspect transcripts. Start from real failures; broken graders can misrepresent capability.
- [Anthropic: Effective long-running harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents): incremental work and persistent artifacts address cross-session continuity; the article explicitly leaves the best single-/multi-agent arrangement unresolved.
- [Anthropic: Harness design for long-running apps](https://www.anthropic.com/engineering/harness-design-long-running-apps): evaluate which components are load-bearing by removing them one at a time. This argues for measured simplification, not accumulating roles by default.

Inference: the transferable value is observable, resumable, judgeable work—not the graph label or number of agents.

## Current Symphony baseline, not new ideas

The [current progress checkpoint](desktop-ticket-chat-progress.md) records one projectless Desktop parent per ticket, controller-launched role workers, and one source checkout used sequentially. The latest ordinary cutover enables all new eligible deliveries without widening queue scope, authorization, or capacity; `Required: yes` still rejects. It records configuration/admission acceptance, **not a completed real-ticket delivery**, and an unresolved remote push TLS problem. No live state was refreshed for this research.

[Plan 006](../plans/006-complete-desktop-ticket-chat.md) preserves fresh independent exact-candidate verification and separately gates required manual validation. Its October 7 scope update places tagged V1 GitLab MR-feedback work on hold. The [native maintenance section](../elixir/README.md) says automatic native archive/restore/reclamation is not shipped or enabled. Do not reinterpret these boundaries as opportunities already authorized for implementation.

SQLite remains ownership/routing authority: [Observability](../elixir/lib/symphony_elixir/factory/observability.ex) explicitly projects the same ledger/controller as dispatch rather than inferring ownership from Jira labels or processes. [TicketContext](../elixir/lib/symphony_elixir/factory/ticket_context.ex) already exposes bounded, high-water replay and uncertainty. Durable state, basic replay, dashboards, role separation, and incremental delivery are therefore existing infrastructure, not proposed additions.

## What transfers—and what must change

- **External control, durable state, fresh roles:** already the foundation of this factory. Adopt the article's properties, not another graph framework, filesystem queue, or orchestration rewrite.
- **Judge-first:** the contract and verifier already define an exit gate. The additive opportunity is proving selected checks reject bad candidates, not a second universal judge.
- **Two reviewers:** independent context is useful; two reviewers is not automatically twice the protection. Similar models can share blind spots, and another pass adds latency, false findings and adjudication. Retain the mandatory fresh verifier; trial a second risk-specific reviewer only if it catches a demonstrated class the existing gate misses. No reviewer shares an active writer checkout.
- **Rule citations:** attach an existing contract/rule identifier when applicable, but do not permit findings *only* when the rulebook explicitly prohibits the bug. Review must still report security, behavior and lifecycle defects with source evidence/reproducers. Record “missing invariant” separately; disagreement can mean different evidence or model error, not necessarily ambiguous policy. Compare findings semantically, not by exact output-string equality.
- **File existence:** an output file can be partial, stale or wrong. It is not completion. Keep SQLite state and exact run/contract/candidate-bound receipts authoritative; content digests and checks qualify artifacts. Do not replace leases with output-directory scans.
- **Check placement and build serialization:** first measure repeated cost on the same candidate. Reuse controller-owned [WorkerCheckIO](../elixir/lib/symphony_elixir/factory/worker_check_io.ex), not workers launching a daemon. Batching must not weaken the final exact-SHA gate or reuse results across changed inputs. One sequential source checkout already limits concurrent build pressure.
- **Role models:** [ModelRouter](../elixir/lib/symphony_elixir/factory/model_router.ex) already supports role/risk routing. Tune from observed cost per accepted delivery; “cheap writer, expensive reviewer” is not an untested universal optimum.
- **Never hand-patch:** too absolute for production repair. Fix a real defect when authorized, then improve the process if it recurs. Frozen Jira product intent cannot be silently rewritten to make output pass, and previous evidence must be retained—not deleted like the article's disposable examples.

## Ranked improvements to the existing delivery workflow

### 1. Falsify acceptance oracles before expensive implementation

**Benefit:** fewer false-green deliveries and less money spent implementing a contract whose checks cannot recognize failure.

**Proposal:** for suitable contracts, bind a known-good reference and one deliberately broken fixture to the declared automated check. Prove that the good reference passes and the broken case fails. This tests the test; it does not replace the fresh verifier or create another routine reviewing agent.

**Integration:** existing contract checks and exact-SHA worker/verifier evidence; [WorkerCheckIO](../elixir/lib/symphony_elixir/factory/worker_check_io.ex). Reuse current checks rather than defining another universal result schema.

**Complexity:** small for one fixture-based contract; medium as an optional contract capability. **Risks/cost:** extra check execution and maintenance; some UI/semantic requirements have no safe synthetic mutation. Never mutate production, change acceptance to accommodate an implementation, or let a grader's file-existence check substitute for behavioral correctness.

**Smallest experiment:** one disposable exact-byte or normalization task; one good input and one altered output. Authorize an offline probe separately, measure whether both sides discriminate, then decide whether contract authors need an optional reference section. No model required for this experiment.

**Status:** new bounded strengthening of existing checks, not a claim that existing tests are weak. Supported by the first-party eval guidance above.

### 2. Measure marginal handoff cost, then simplify one component at a time

**Benefit:** know which role changes actually reduce total delivery cost and operator interruption without reducing correctness.

**Proposal:** extend trial evidence with actual per-role token data when an authentic provider/client source is available, plus before/after disk usage and explicit human interventions. Preserve `UNKNOWN` otherwise. Compare completed, verifier-passing delivery—not price per model call or number of test cases.

**Integration:** existing [pilot reporting/hardening plan](../elixir/docs/factory-hardening-plan.md), [Observability](../elixir/lib/symphony_elixir/factory/observability.ex), and [ModelRouter](../elixir/lib/symphony_elixir/factory/model_router.ex). Source currently marks per-run/per-turn tokens and cost `UNKNOWN`; stage durations and model routes already exist. This is closing a stated measurement gap, not building another dashboard.

**Complexity:** small for trial records; medium for authenticated automated usage ingestion. **Risks/cost:** client usage may omit subagents/cache/tools, and turns are not tokens. Stop or alert on elapsed/request caps if needed, but do not invent dollar caps from incomplete attribution or automatically escalate models.

**Smallest experiment:** next three separately authorized ordinary deliveries: record completion, elapsed execution versus waiting, role/request count, interventions, known token totals and unknowns, disk delta. Only afterward test one role/prompt change on a matched task; retain fresh verification.

**Cost-placement follow-up:** if those records reveal repeated expensive checks, classify cheap checks versus full gates and deduplicate only identical candidate/input/check identities under the existing controller. A small recorded trace can establish duplicate work before building anything. A new shared build daemon is premature unless measured contention survives the one-writer constraint.

**Status:** existing hardening direction with an unfilled source-backed gap. First-party harness ablation guidance supports the evaluation method.

### 3. Version process fixes without creating a self-modifying rulebook

**Benefit:** stop paying for the same preventable mistake while retaining the ability to explain and roll back a behavioral change.

**Proposal:** classify recurring verifier/operator failures into a proposed process patch: evidence, affected invariant, narrow shared-skill/rule change, regression case, and rollback. Have a human approve product/policy changes; maintain one canonical shared source. Associate trial evidence with the exact approved rule/prompt version or digest so before/after outcomes remain interpretable. Do not append a sentence for every finding or regenerate every accepted output.

**Integration:** existing specification/critic and exact-contract provenance plus the shared `~/.agents/skills`/rules workflow. The recorded [hardening plan](../elixir/docs/factory-hardening-plan.md) already treats identity-bound evidence as important; this proposal adds a bounded learning practice, not new controller authority. Whether prompt/rule provenance needs any new persisted field remains to be audited before implementation.

**Complexity:** small manually; medium if automating evidence attribution. **Risks/cost:** rule bloat, overfitting one incident, propagation to unrelated services, stale queued work. Trial only the next authorized cohort, explicitly bound its versions, and preserve older records. Never change an active confirmed contract in place.

**Smallest experiment:** take one repeated, evidenced operator correction; draft a five-line rule change and one positive/negative regression. Review it without applying it, then authorize one bounded before/after trial. Reject changes that merely restate existing instructions. [Anthropic's migration account](https://claude.com/resources/articles/ai-code-migration) motivates fixing the producing process; approval and provenance are Symphony-specific safety adaptations.

### 4. Add explicit Jira blocker admission, not automatic ticket decomposition

**Benefit:** avoid starting a valid ticket before its declared prerequisite lands.

**Proposal:** normalize inward `Blocks` issue links in the factory MCP snapshot and defer *new* delivery admission until all explicit blockers are terminal. Re-read bounded blocker state each tick; unknown/missing/ambiguous dependencies defer with an honest reason. Do not interrupt an already-running writer or transfer SQLite lease authority to Jira.

**Integration:** [JiraMcpReader](../elixir/lib/symphony_elixir/factory/jira_mcp_reader.ex) currently requests no `issuelinks`; [Queue](../elixir/lib/symphony_elixir/factory/queue.ex) classifies labels/routes without dependency checks. The separate [Jira adapter](../elixir/lib/symphony_elixir/jira/client.ex) and [README](../elixir/README.md) already support blockers for generic tracker dispatch; do not confuse that with factory intake.

**Complexity:** medium. **Risks/cost:** stale links, cycles, inaccessible projects, extra Jira reads, ambiguous terminal semantics. Reuse a bounded snapshot; no planner, Jira write, or DAG runtime is needed.

**Smallest experiment:** read-only classification of a tiny recorded queue containing one blocked, one unblocked, and one unresolved-blocker ticket; compare proposed eligibility against human expectations. Implement only if real backlog links make the benefit observable.

**Status:** conditional additive factory feature; manually linked dependencies are distinct from autonomous child-ticket creation.

## Ranked complementary workflows

### 5. Failure-to-regression research lane

**Benefit:** turn repeated integration incidents into preventive checks instead of repeatedly repairing individual runs.

**Proposal:** a deterministic selector chooses one new failure signature and bounded evidence; one read-only investigator produces a causal hypothesis, minimal reproducer proposal, and missing-evidence list. Human approval converts that into a specification. Never auto-edit rules or treat an explanation as proven root cause.

**Integration:** [RunLedger](../elixir/lib/symphony_elixir/factory/run_ledger.ex), bounded [TicketContext replay](../elixir/lib/symphony_elixir/factory/ticket_context.ex), existing lifecycle tests and [hardening notes](../elixir/docs/factory-hardening-plan.md). Scheduler completion key = evidence fingerprint; unchanged failures cause no model wakeups.

**Complexity:** small as a manual lane, medium to schedule. **Risks/cost:** sensitive transcripts, recurring speculation, stale candidates; cap one incident/one short report, retain raw evidence by existing policy, store hashes/locators rather than duplicate logs.

**Smallest experiment:** one recorded failed-CREATE/recovered-parent or uncertain-push incident; return a proposed regression and evidence boundaries. Measure whether it identifies an untested case rather than re-documenting existing coverage.

### 6. Bounded migration canary lane

**Benefit:** assess whether a repetitive migration is safe and economical before committing to a large batch.

**Proposal:** freeze a mapping guide, select three representative transformations, and run the old/new behavior against the same fixtures. One sequential writer and fresh verifier; only widen after the canary exposes no unexplained differences.

**Integration:** current contract/planner/writer/verifier path. A finite per-item manifest tracks input digest, output digest, check result, and guide version; it is not a replacement controller or a cross-ticket graph engine.

**Complexity:** medium for one migration; large for a reusable batch lane. **Risks/cost:** guide changes invalidate earlier items, hidden coupling, disk/test cost, superficial compiler success. Restrict to a named repository and stable oracle; no new parallel writers by default.

**Smallest experiment:** three representative API/test-fixture transformations in a disposable repo, with identical behavioral checks. Abort if validation is weaker than the behavior being preserved. Bun's first-party report motivates canaries and shared checks, not its fleet size.

### 7. Read-only evidence reconciliation report

**Benefit:** answer “what actually finished?” without operators manually reconciling chat, ledger, Git and CI or granting a recovery action.

**Proposal:** after a state/evidence fingerprint changes, collect only configured readbacks and produce a concise agreement/disagreement report. No replay, push, label update, cleanup, or automatic recovery. Use deterministic comparisons first; ask a model only for genuinely ambiguous interpretation.

**Integration:** existing [CI collection](../elixir/lib/symphony_elixir/factory/ci_collection.ex), [TicketContext](../elixir/lib/symphony_elixir/factory/ticket_context.ex), and read-only pilot report. These readers already exist; the addition is a single bounded cross-source discrepancy artifact, not another source of state truth.

**Complexity:** small locally; medium with authenticated external readbacks. **Risks/cost:** unnecessary polling, pagination omissions, stale SHA and duplicate reports. Pin project/MR/candidate identity and an as-of timestamp; report unavailable sources explicitly.

**Smallest experiment:** one recorded delivery packet with a deliberately mismatched CI/MR SHA; prove the report flags the mismatch and takes no action. Reject the idea if the current next-action presentation already answers the operator's question adequately.

### 8. Cited research-to-contract lane

**Benefit:** gather unknown API/design constraints before asking a delivery worker to discover them expensively during implementation.

**Proposal:** a bounded read-only research ticket returns first-party citations, proven facts, alternatives, uncertainties, and a proposed experiment; it stops at a human decision rather than creating child Jira tickets or starting delivery.

**Integration:** existing specification author/critic roles and repository routing. Explicit source list, single artifact, fixed evidence window, no source checkout required; keep delivery authorization separate.

**Complexity:** small manually; medium for a reusable run kind. **Risks/cost:** stale documentation, false precision, generic reports and unbounded browsing. Cap sources/pages and output; no vector database or repo-wide context index absent demonstrated discovery failures.

**Smallest experiment:** one question currently blocking a real contract; judge whether the brief resolves it with a concrete decision and whether the critic accepts the resulting contract. This investigation demonstrates how an access failure can be resolved by user-supplied evidence while retaining a clear distinction between article claims and first-party support. Keep exploratory investigation model-directed inside a bounded evidence/decision envelope; do not predefine every research step as a rigid graph.

## Do not build yet

- A general graph DSL, recursive autonomous ticket splitting, cross-repo parent joins, or a large reviewer swarm. Existing deterministic scheduling already supplies the essential graph semantics.
- Universal double-LLM review. First try deterministic falsification and the existing fresh verifier; add a second specialist only for a measured risk gap.
- A new repo map, RAG store, or context manifest without observed retrieval failures. Agents already receive repo access and bounded controller context.
- Native cleanup bypasses, Required:yes admission, or V1 tagged GitLab feedback under this investigation. Those are separate explicitly gated/on-hold work.
- Automatic prompt/rulebook mutation from incident reports. Produce reviewed proposals; a self-modifying policy path broadens authority and can erase the distinction between spec and implementation.
- Full transcript duplication or unbounded polling. Preserve immutable locators/digests, bounded pages and meaningful-change triggers; storage and token budgets are part of correctness.

## Ordering and decision gates

Start with the next separately authorized ordinary real-ticket proof, recording #2's minimal measurements rather than adding a platform. Pilot #1 on one safely falsifiable acceptance check. Use a manual #5 investigation to propose one #3 process improvement only after a repeated failure is evidenced. Add #4 only if actual dependency links are used. #6–#8 are demand-driven lanes, not required roles for every ticket. Compare each with the existing manual process; require a concrete saved intervention or stronger detected failure before expanding.

No effort estimate here is a delivery commitment. Web sources and local files were read, but no live factory state was refreshed. Deployment health, model performance, cost savings, and successful real-ticket delivery were not demonstrated by this research.
