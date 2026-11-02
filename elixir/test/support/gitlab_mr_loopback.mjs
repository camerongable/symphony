// Test-only external protocol fixture: no production endpoint or credentials.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [mode, configPath] = process.argv.slice(2);
const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
const collection = '/api/v4/projects/33747681/merge_requests';

if (mode === 'gitlab') {
  const state = { requests: [], posts: 0, violations: [], mr: null };
  const save = () => writeFileSync(cfg.statePath, JSON.stringify(state));
  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    const url = new URL(request.url, 'http://127.0.0.1');
    state.requests.push({ method: request.method, path: request.url, body });
    try {
      assert.equal(request.headers.authorization, 'Bearer synthetic-test-only');
      let result;
      if (request.method === 'GET' && url.pathname === collection) {
        assert.equal(url.searchParams.get('source_branch'), cfg.sourceBranch);
        assert.equal(url.searchParams.get('target_branch'), 'master');
        assert.equal(url.searchParams.get('state'), 'all');
        assert.equal(url.searchParams.get('scope'), 'all');
        assert.equal(url.searchParams.get('per_page'), '100');
        assert.equal(url.searchParams.get('page'), '1');
        result = state.mr ? [state.mr] : [];
      } else if (request.method === 'POST' && url.pathname === collection) {
        state.posts++;
        assert.equal(state.posts, 1, 'publication must never resend a lost acknowledgement');
        const submitted = JSON.parse(body);
        assert.equal(submitted.draft, true);
        assert.equal(submitted.source_branch, cfg.sourceBranch);
        assert.equal(submitted.target_branch, 'master');
        assert.equal(submitted.remove_source_branch, false);
        assert.deepEqual(submitted.assignee_ids, [11599766]);
        assert.deepEqual(submitted.reviewer_ids, []);
        state.mr = {
          id: 42, iid: 42, project_id: 33747681, ...submitted,
          author: { id: 1, username: 'synthetic', name: 'Synthetic' },
          assignees: [{ id: 11599766, username: 'cgable', name: 'Synthetic' }], reviewers: [],
          state: 'opened', sha: cfg.sha,
          web_url: 'https://gitlab.com/grailbio/grail/-/merge_requests/42',
          created_at: '2026-11-02T00:00:00Z', updated_at: '2026-11-02T00:00:00Z',
          merged_at: null, closed_at: null, merge_commit_sha: null,
          should_remove_source_branch: false, force_remove_source_branch: false
        };
        result = state.mr;
      } else if (request.method === 'GET' && url.pathname === `${collection}/42`) {
        assert.equal(url.searchParams.get('include_diverged_commits_count'), 'true');
        assert.ok(state.mr);
        result = state.mr;
      } else {
        throw new Error(`Unexpected HTTP request ${request.method} ${request.url}`);
      }
      save();
      response.writeHead(request.method === 'POST' ? 201 : 200, { 'content-type': 'application/json' });
      response.end(JSON.stringify(result));
    } catch (error) {
      state.violations.push(error.message);
      save();
      response.writeHead(400, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: error.message }));
    }
  });
  save();
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  process.stdout.write(JSON.stringify({ port: server.address().port }) + '\n');
  process.stdin.once('data', () => server.close(() => process.exit(0)));
} else if (mode === 'bridge') {
  const provider = '/Users/cgable/.npm/_npx/e6e384d7d1d112a9/node_modules/@zereight/mcp-gitlab';
  assert.equal(createHash('sha256').update(readFileSync(`${provider}/build/schemas.js`)).digest('hex'), '1d8e1a935d53edc56662bfcc5221e5a1092cf50310150eea5591e52810f27fd4');
  assert.match(cfg.apiUrl, /^http:\/\/127\.0\.0\.1:\d+\/api\/v4$/);
  const sdk = resolve(provider, '../../@modelcontextprotocol/sdk/dist/esm');
  const { Client } = await import(pathToFileURL(`${sdk}/client/index.js`));
  const { StdioClientTransport } = await import(pathToFileURL(`${sdk}/client/stdio.js`));
  const allowed = new Set(['list_merge_requests', 'get_merge_request', 'create_merge_request']);
  const client = new Client({ name: 'symphony-publication-fixture', version: '0.0.1' });
  const transport = new StdioClientTransport({
    command: process.execPath, args: [`${provider}/build/index.js`], cwd: cfg.root,
    env: {
      PATH: process.env.PATH, HOME: cfg.root, GITLAB_API_URL: cfg.apiUrl,
      GITLAB_PERSONAL_ACCESS_TOKEN: 'synthetic-test-only', GITLAB_USE_OAUTH: 'false',
      GITLAB_DISABLE_VERSION_CHECK: 'true', GITLAB_PERMISSION_MODE: 'modify',
      GITLAB_TOOLS: [...allowed].join(','),
      GITLAB_DENIED_TOOLS_REGEX: '^(?!(list_merge_requests|get_merge_request|create_merge_request)$).*'
    }, stderr: 'pipe'
  });
  transport.stderr.on('data', data => appendFileSync(cfg.stderrPath, data));
  const emit = value => new Promise(done => process.stdout.write(JSON.stringify(value) + '\n', done));
  const close = async () => { try { await client.close(); } catch {} };
  process.stdout.on('error', async () => { await close(); process.exit(0); });
  process.on('SIGTERM', async () => { await close(); process.exit(143); });
  try {
    for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
      appendFileSync(process.env.SYMP_TEST_CODEx_TRACE, `JSON:${line}\n`);
      const request = JSON.parse(line);
      if (request.method === 'initialized') continue;
      try {
        let result;
        switch (request.method) {
          case 'thread/start':
            await client.connect(transport);
            appendFileSync(cfg.pidsPath, `${transport.pid}\n`);
            await emit({ id: request.id, result: { thread: { id: 'publication-connector' } } });
            await emit({ method: 'mcpServer/startupStatus/updated', params: { name: 'GitLab', status: 'ready' } });
            continue;
          case 'mcpServerStatus/list': {
            const catalog = await client.listTools();
            assert.ok(!catalog.nextCursor);
            result = { data: [{ name: 'GitLab', tools: Object.fromEntries(catalog.tools.map(tool => [tool.name, tool])), toolsError: null }], nextCursor: null };
            break;
          }
          case 'mcpServer/tool/call': {
            const { server, tool, arguments: args } = request.params;
            assert.equal(server, 'GitLab');
            assert.ok(allowed.has(tool));
            result = await client.callTool({ name: tool, arguments: args });
            if (tool === 'create_merge_request' && !result.isError) {
              await close();
              process.exit(7);
            }
            break;
          }
          case 'thread/unsubscribe': await close(); result = {}; break;
          default: throw new Error(`Unexpected AppServer method ${request.method}`);
        }
        await emit({ id: request.id, result });
      } catch (error) {
        appendFileSync(cfg.stderrPath, `${request.method}: ${error.stack}\n`);
        await emit({ id: request.id, error: { code: -32000, message: error.message } });
      }
    }
  } finally { await close(); }
} else {
  throw new Error('Unknown fixture mode');
}
