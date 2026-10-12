# Exact-current CI provider artifact

The configured `@zereight/mcp-gitlab` 2.1.68 MR response schema strips
`head_pipeline`. A list of pipelines is not a replacement for that selector.
This private, exact-version integration preserves its typed optional/nullable
pipeline projection and enforces native booleans for MR `draft` and job
`allow_failure`, without enabling GraphQL, raw REST fallback, or write tools.
Malformed string/null booleans are rejected rather than coerced into evidence.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
npm test
```

The lockfile pins dependencies. `prepare.mjs` checks the upstream version and
schema, executable build and dependency-tree hashes before generating a separate
artifact; it does not edit the installed
dependency, shared npm cache, or Desktop configuration. Existing differing
artifacts are rejected, not overwritten. The returned `.generated-guard-v3/build/index.js`
is the process-local launch target for acceptance. Normal configured authentication
remains caller-owned; never put credentials in this directory or arguments.

The real stdio MCP test uses only dummy credentials and a loopback mock GitLab.
It checks selector, explicit null, absent evidence, malformed selector, unknown
field stripping, strict delivery-relevant booleans, exact GET scope, and child
shutdown. Input and unrelated response schemas remain unchanged. This is not evidence of
live GitLab permissions, pipeline shape, source parents, or production deployment.
Do not change the user's global MCP configuration as part of this build.

The Elixir collector requires an existing idle controller-owned MCP session,
validates advertised read-only argument schemas, caps jobs at 100, and makes at
most seven catalog/tool reads including pagination and MR reread. It never
retries, mutates GitLab, or opens a model thread. Missing selector is an explicit
capability error, not WAIT. Known positive IDs are normalized; booleans and SHAs
are never inferred or normalized. Local candidate/contract bindings are reread
after network collection; delivery adoption remains a controller responsibility.

Protocol references: [official app-server MCP methods](https://learn.chatgpt.com/docs/app-server)
and [GitLab MR current-pipeline fields](https://docs.gitlab.com/api/merge_requests/).
Installed-version schemas and actual read receipts remain the runtime authority;
these documents alone do not prove local permissions or successful collection.
