import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { prepare, treeDigest } from './prepare.mjs';

test('provider reuse checks the whole executable tree, not a forgeable receipt', t => {
  const root = fileURLToPath(new URL('.', import.meta.url));
  const fixture = mkdtempSync(resolve(root, '.generated-tamper-'));
  t.after(() => rmSync(fixture, { recursive: true }));
  const output = resolve(fixture, 'artifact');
  const entry = prepare(output);
  assert.equal(prepare(output), entry);
  const alias = resolve(fixture, 'alias');
  symlinkSync(output, alias);
  assert.throws(() => prepare(alias), /real directory/);
  assert.throws(() => prepare(resolve(alias, 'nested')), /canonical parent/);
  const original = readFileSync(entry);
  writeFileSync(entry, Buffer.concat([original, Buffer.from('\n// unexpected executable edit\n')]));
  assert.throws(() => prepare(output), /refusing overwrite/);
  const receiptPath = resolve(output, 'receipt.json');
  const receipt = JSON.parse(readFileSync(receiptPath, 'utf8'));
  receipt.generated_build_sha256 = treeDigest(resolve(output, 'build'));
  writeFileSync(receiptPath, JSON.stringify(receipt));
  assert.throws(() => prepare(output), /refusing overwrite/);
  const external = resolve(fixture, 'external');
  writeFileSync(external, 'synthetic');
  symlinkSync(external, resolve(output, 'build/external-link'));
  assert.throws(() => treeDigest(resolve(output, 'build')), /External dependency symlink rejected/);
});

test('actual MCP jobs read rejects coerced allow-failure booleans', { timeout: 20000 }, async () => {
  let body;
  const requests = [];
  const server = createServer((request, response) => {
    requests.push([request.method, request.url]);
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(body));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const client = new Client({ name: 'symphony-job-regression', version: '0.0.1' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [prepare()],
    env: {
      PATH: process.env.PATH,
      GITLAB_API_URL: `http://127.0.0.1:${server.address().port}/api/v4`,
      GITLAB_PERSONAL_ACCESS_TOKEN: 'synthetic-test-only',
      GITLAB_DISABLE_VERSION_CHECK: 'true',
      GITLAB_PERMISSION_MODE: 'readonly',
      GITLAB_TOOLS: 'list_pipeline_jobs',
    },
    stderr: 'pipe',
  });
  let pid;
  try {
    await client.connect(transport);
    pid = transport.pid;
    for (const value of [false, true, 'false', 'true', null]) {
      body = [{
        id: 100, name: 'bazel', status: 'failed', stage: 'test',
        ref: 'refs/merge-requests/42/head', tag: false,
        created_at: '2026-10-04T00:00:00Z', allow_failure: value,
        pipeline: { id: 99, project_id: 33747681, status: 'failed', ref: 'refs/merge-requests/42/head', sha: 'a'.repeat(40) },
      }];
      const call = () => client.callTool({ name: 'list_pipeline_jobs', arguments: { project_id: '33747681', pipeline_id: '99', page: 1, per_page: 100, include_retried: false } });
      if (typeof value !== 'boolean') {
        await assert.rejects(call(), /allow_failure/);
      } else {
        const response = await call();
        assert.notEqual(response.isError, true);
        const result = JSON.parse(response.content[0].text);
        assert.equal(result[0].allow_failure, value);
      }
    }
    assert.equal(requests.length, 5);
    for (const [method, path] of requests) {
      assert.equal(method, 'GET');
      assert.equal(path, '/api/v4/projects/33747681/pipelines/99/jobs?include_retried=false&page=1&per_page=100');
    }
  } finally {
    await client.close();
    await new Promise(resolve => server.close(resolve));
    if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  }
});

test('actual MCP MR read preserves selector/null/absence and rejects malformed evidence', { timeout: 20000 }, async () => {
  const selector = { id: 99, project_id: 33747681, sha: 'a'.repeat(40), ref: 'refs/merge-requests/42/head', source: 'merge_request_event', status: 'success', web_url: 'https://gitlab.invalid/pipelines/99' };
  let body;
  const requests = [];
  const server = createServer((request, response) => {
    requests.push([request.method, request.url]);
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(body));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const client = new Client({ name: 'symphony-provider-regression', version: '0.0.1' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [prepare()],
    env: {
      PATH: process.env.PATH,
      GITLAB_API_URL: `http://127.0.0.1:${server.address().port}/api/v4`,
      GITLAB_PERSONAL_ACCESS_TOKEN: 'synthetic-test-only',
      GITLAB_DISABLE_VERSION_CHECK: 'true',
      GITLAB_PERMISSION_MODE: 'readonly',
      GITLAB_TOOLS: 'get_merge_request',
    },
    stderr: 'pipe',
  });
  let pid;
  try {
    await client.connect(transport);
    pid = transport.pid;
    assert.ok(Number.isInteger(pid) && pid > 0);
    const catalog = await client.listTools();
    assert.ok(catalog.tools.some(tool => tool.name === 'get_merge_request'));
    assert.ok(catalog.tools.every(tool => tool.annotations?.readOnlyHint === true));
    for (const scenario of ['selector', 'null', 'absent', 'malformed', 'draft-native-false', 'draft-string-false', 'draft-string-true', 'draft-null']) {
      body = {
        id: 42, iid: 42, project_id: 33747681, title: 'Synthetic MR', description: '',
        state: 'opened', author: { id: 1, name: 'Synthetic', username: 'synthetic', avatar_url: null, web_url: 'https://gitlab.invalid/users/1' },
        source_branch: 'fixture', target_branch: 'master', web_url: 'https://gitlab.invalid/mr/42',
        created_at: '2026-10-04T00:00:00Z', updated_at: '2026-10-04T00:00:00Z', merged_at: null, closed_at: null, merge_commit_sha: null,
        sha: selector.sha, draft: true, reviewers: [], unrelated_secret: 'must-be-stripped',
      };
      if (scenario !== 'absent') body.head_pipeline = scenario === 'null' ? null : scenario === 'malformed' ? 'not-a-pipeline' : selector;
      if (scenario.startsWith('draft-')) body.draft = scenario === 'draft-native-false' ? false : scenario === 'draft-null' ? null : scenario.endsWith('false') ? 'false' : 'true';
      const call = () => client.callTool({ name: 'get_merge_request', arguments: { project_id: '33747681', merge_request_iid: '42', include_summaries: false } });
      if (scenario === 'malformed') {
        await assert.rejects(call(), /head_pipeline/);
      } else if (scenario.startsWith('draft-') && scenario !== 'draft-native-false') {
        await assert.rejects(call(), /draft/);
      } else {
        const response = await call();
        assert.notEqual(response.isError, true);
        const result = JSON.parse(response.content[0].text);
        assert.equal(Object.hasOwn(result, 'unrelated_secret'), false);
        assert.equal(Object.hasOwn(result, 'head_pipeline'), scenario !== 'absent');
        assert.equal(result.draft, scenario !== 'draft-native-false');
        if (scenario === 'selector') assert.deepEqual(result.head_pipeline, { ...selector, id: '99', project_id: '33747681' });
        if (scenario === 'null') assert.equal(result.head_pipeline, null);
      }
    }
    assert.equal(requests.length, 8);
    for (const [method, path] of requests) {
      assert.equal(method, 'GET');
      assert.equal(path, '/api/v4/projects/33747681/merge_requests/42?include_diverged_commits_count=true');
    }
  } finally {
    await client.close();
    await new Promise(resolve => server.close(resolve));
    if (pid) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  }
});
