import asyncio
import importlib.metadata
import json
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

import factory_provider


class FactoryProviderTest(unittest.TestCase):
    def setUp(self):
        from mcp_atlassian.servers.jira import jira_mcp

        try:
            jira_mcp.local_provider.remove_tool("update_factory_labels")
        except KeyError:
            pass

    def tearDown(self):
        from mcp_atlassian.servers.jira import jira_mcp

        try:
            jira_mcp.local_provider.remove_tool("update_factory_labels")
        except KeyError:
            pass

    def test_delta_preserves_labels_added_after_the_factory_snapshot(self):
        snapshot = {"repo-grail", "ai-running", "ai-verifying"}
        current = snapshot | {"human-added"}
        payload = factory_provider.label_update("PPL-123", ["ai-review"], ["ai-running", "ai-verifying"])
        self.assertEqual(set(payload), {"update"})
        for operation in payload["update"]["labels"]:
            if "add" in operation:
                current.add(operation["add"])
            else:
                current.discard(operation["remove"])
        self.assertEqual(current, {"repo-grail", "human-added", "ai-review"})

    def test_invalid_or_unrelated_deltas_are_rejected(self):
        invalid = [
            ("bad", ["ai-running"], []),
            ("PPL-123", ["security-exempt"], []),
            ("PPL-123", ["ai-running", "ai-review"], []),
            ("PPL-123", ["ai-review"], ["human-label"]),
            ("PPL-123", ["ai-running"], ["ai-running"]),
            ("PPL-123", ["ai-review"], ["ai-ready", "ai-ready"]),
            ("PPL-123", [], []),
            ("PPL-123", [1], []),
        ]
        for args in invalid:
            with self.subTest(args=args), self.assertRaises(ValueError):
                factory_provider.label_update(*args)

    def test_provider_version_drift_rejects_registration(self):
        with patch.object(importlib.metadata, "version", return_value="different"), self.assertRaises(RuntimeError):
            factory_provider.register_factory_labels()

    def test_actual_registration_schema_and_scope_use_one_atomic_update(self):
        from atlassian import Jira
        from mcp_atlassian.servers.jira import jira_mcp

        mutation = []
        api = Jira.__new__(Jira)
        api.put = lambda endpoint, **args: mutation.append((endpoint, args))
        fetcher = SimpleNamespace(jira=api)
        context = SimpleNamespace(request_context=SimpleNamespace(lifespan_context={"app_lifespan_context": SimpleNamespace(read_only=False)}))
        resolver = AsyncMock(return_value=fetcher)
        with patch("mcp_atlassian.servers.dependencies.get_jira_fetcher", resolver):
            handler = factory_provider.register_factory_labels()
            result = asyncio.run(handler(context, "PPL-123", ["ai-running"], ["ai-ready"]))
            self.assertEqual(json.loads(result), {"issue_key": "PPL-123", "mutation_requested": True})
            self.assertEqual(mutation, [("/rest/api/2/issue/PPL-123", {"data": {"update": {"labels": [{"add": "ai-running"}, {"remove": "ai-ready"}]}}})])

        tool = asyncio.run(jira_mcp.get_tool("update_factory_labels"))
        self.assertEqual(set(tool.parameters["properties"]), {"issue_key", "add_labels", "remove_labels"})
        self.assertEqual(tool.annotations.readOnlyHint, False)
        self.assertIn("write", tool.tags)
        from mcp_atlassian.servers.main import main_mcp

        exported = asyncio.run(main_mcp.get_tool("jira_update_factory_labels"))
        self.assertIsNotNone(exported)
        self.assertEqual(set(exported.parameters["properties"]), {"issue_key", "add_labels", "remove_labels"})

    def test_registration_never_replaces_an_existing_tool(self):
        factory_provider.register_factory_labels()
        with self.assertRaises(RuntimeError):
            factory_provider.register_factory_labels()

    def test_provider_read_only_mode_prevents_fetch_and_mutation(self):
        context = SimpleNamespace(request_context=SimpleNamespace(lifespan_context={"app_lifespan_context": SimpleNamespace(read_only=True)}))
        resolver = AsyncMock()
        with patch("mcp_atlassian.servers.dependencies.get_jira_fetcher", resolver):
            handler = factory_provider.register_factory_labels()
            with self.assertRaises(Exception):
                asyncio.run(handler(context, "PPL-123", ["ai-running"], []))
            resolver.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
