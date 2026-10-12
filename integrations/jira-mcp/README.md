# Atomic factory-label adapter

The installed `mcp-atlassian` 0.23.1 update tool replaces the complete label field.
A second preimage read cannot prevent losing a human label added between that read
and the update. This staged adapter registers one narrowly scoped
`jira_update_factory_labels` tool, using Jira's atomic label add/remove operations.
It accepts one factory state addition (`ai-running` or `ai-review`) and only the
approved factory-label removals. It cannot replace labels, change a description,
assign a reviewer or write an unrelated field.

Run checks with the already-installed provider's Python interpreter:

```sh
/Users/cgable/.local/share/uv/tools/mcp-atlassian/bin/python -m unittest discover -s integrations/jira-mcp
```

The launch artifact is `factory_provider.py` under that same interpreter. It uses
the existing provider CLI, authentication, read-only guard and tool filters. It
does not edit the installed package, shared caches or Codex configuration. Provider
version changes fail closed and require requalification. Deployment is not enabled
by these source changes: advertise/check the actual schema and prove the native
session before switching the factory's process-local connector command.

The return value acknowledges a request only. The controller's durable journal and
complete Jira readback must independently establish success; neither a tool reply
nor an absent uncertain comment authorizes a repeated mutation. Local tests use
synthetic issue keys and mocked clients, never Jira credentials or live calls.

The stdio qualification tests additionally launch the actual staged executable
with synthetic credentials and an ephemeral loopback Jira fixture. They check
the advertised schema, tool filtering, exact atomic HTTP payload, invalid-delta
rejection and read-only exclusion. Provider update checks are disabled in those
test subprocesses. This qualifies the provider protocol locally, not its native
Codex session or production connector configuration.

Protocol reference: [Jira issue update operations](https://developer.atlassian.com/server/jira/platform/updating-an-issue-via-the-jira-rest-apis-6848604/).
