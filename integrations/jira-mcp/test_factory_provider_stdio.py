import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


class FactoryProviderStdioTest(unittest.TestCase):
    def setUp(self):
        self.requests = []
        requests = self.requests

        class JiraFixture(BaseHTTPRequestHandler):
            def do_PUT(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, body))
                self.send_response(204)
                self.end_headers()

            def do_GET(self):
                requests.append((self.path, None))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"version":"9.0.0","deploymentType":"Server"}')

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), JiraFixture)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.scratch = tempfile.TemporaryDirectory(prefix="symphony-jira-provider-")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.scratch.cleanup()

    def parameters(self, read_only=False):
        return StdioServerParameters(
            command=sys.executable,
            args=[str(Path(__file__).with_name("factory_provider.py").resolve()), "--transport", "stdio"],
            cwd=self.scratch.name,
            env={
                "JIRA_URL": f"http://127.0.0.1:{self.server.server_port}",
                "JIRA_USERNAME": "fixture@example.test",
                "JIRA_API_TOKEN": "synthetic-fixture-token",
                "JIRA_PERSONAL_TOKEN": "",
                "CONFLUENCE_URL": "",
                "ENABLED_TOOLS": "jira_update_factory_labels",
                "READ_ONLY_MODE": str(read_only).lower(),
                "LOG_LEVEL": "ERROR",
                "TOOLSETS": "all",
                "FASTMCP_CHECK_FOR_UPDATES": "off",
                "HTTP_PROXY": "",
                "HTTPS_PROXY": "",
                "ALL_PROXY": "",
                "NO_PROXY": "127.0.0.1",
            },
        )

    def test_stdio_catalog_and_atomic_write_reach_only_the_synthetic_jira(self):
        async def check():
            async with stdio_client(self.parameters()) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    await session.initialize()
                    catalog = await session.list_tools()
                    self.assertEqual([tool.name for tool in catalog.tools], ["jira_update_factory_labels"])
                    tool = catalog.tools[0]
                    self.assertEqual(set(tool.inputSchema["properties"]), {"issue_key", "add_labels", "remove_labels"})
                    self.assertEqual(set(tool.inputSchema["required"]), {"issue_key", "add_labels", "remove_labels"})
                    self.assertEqual(tool.inputSchema["properties"]["issue_key"]["type"], "string")
                    for name in ("add_labels", "remove_labels"):
                        self.assertEqual(tool.inputSchema["properties"][name]["type"], "array")
                        self.assertEqual(tool.inputSchema["properties"][name]["items"], {"type": "string"})
                    self.assertFalse(tool.annotations.readOnlyHint)
                    self.assertTrue(tool.annotations.destructiveHint)
                    self.assertEqual(self.requests, [])
                    arguments = {"issue_key": "PPL-123", "add_labels": ["ai-review"], "remove_labels": ["ai-running"]}
                    result = await session.call_tool(tool.name, arguments)
                    self.assertFalse(result.isError)
                    self.assertEqual(json.loads(result.content[0].text), {"issue_key": "PPL-123", "mutation_requested": True})
                    self.assertEqual(self.requests, [("/rest/api/2/issue/PPL-123", {"update": {"labels": [{"add": "ai-review"}, {"remove": "ai-running"}]}})])
                    arguments["add_labels"] = ["human-label"]
                    rejected = await session.call_tool(tool.name, arguments)
                    self.assertTrue(rejected.isError)
                    self.assertEqual(len(self.requests), 1)

        asyncio.run(asyncio.wait_for(check(), timeout=30))

    def test_stdio_read_only_mode_excludes_the_mutation_tool_without_http(self):
        async def check():
            async with stdio_client(self.parameters(read_only=True)) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    await session.initialize()
                    catalog = await session.list_tools()
                    self.assertEqual(catalog.tools, [])
                    result = await session.call_tool("jira_update_factory_labels", {
                        "issue_key": "PPL-123", "add_labels": ["ai-running"], "remove_labels": [],
                    })
                    self.assertTrue(result.isError)
                    self.assertEqual(self.requests, [])

        asyncio.run(asyncio.wait_for(check(), timeout=30))
