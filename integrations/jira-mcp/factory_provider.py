"""Add one issue-scoped atomic factory-label tool to the existing Jira provider."""

import asyncio
import importlib.metadata
import json
import re
from typing import Annotated

from fastmcp import Context
from pydantic import Field

SUPPORTED_PROVIDER_VERSION = "0.23.1"
ADD_LABELS = frozenset({"ai-running", "ai-review"})
REMOVE_LABELS = frozenset({"ai-ready", "ai-running", "ai-verifying"})


def label_update(issue_key, add_labels, remove_labels):
    if not isinstance(issue_key, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*-[1-9][0-9]*", issue_key):
        raise ValueError("Invalid factory issue key")
    if not isinstance(add_labels, list) or not isinstance(remove_labels, list):
        raise ValueError("Factory labels must be lists")
    if not all(isinstance(label, str) for label in add_labels + remove_labels):
        raise ValueError("Factory labels must be strings")
    adds, removes = set(add_labels), set(remove_labels)
    if (
        len(add_labels) != 1
        or not adds <= ADD_LABELS
        or len(removes) != len(remove_labels)
        or not removes <= REMOVE_LABELS
        or adds & removes
    ):
        raise ValueError("Unsupported factory label delta")
    if adds == {"ai-running"} and not removes <= {"ai-ready", "ai-verifying"}:
        raise ValueError("Unsupported implementation label delta")
    operations = [{"add": label} for label in sorted(adds)]
    operations.extend({"remove": label} for label in sorted(removes))
    return {"update": {"labels": operations}}


def register_factory_labels():
    if importlib.metadata.version("mcp-atlassian") != SUPPORTED_PROVIDER_VERSION:
        raise RuntimeError("Unsupported mcp-atlassian version; requalify the factory adapter")

    from mcp_atlassian.servers.dependencies import get_jira_fetcher
    from mcp_atlassian.servers.jira import jira_mcp
    from mcp_atlassian.utils.decorators import check_write_access

    if asyncio.run(jira_mcp.get_tool("update_factory_labels")) is not None:
        raise RuntimeError("Factory label tool already registered; refusing replacement")

    @check_write_access
    async def update_factory_labels(
        ctx: Context,
        issue_key: Annotated[str, Field(pattern=r"^[A-Z][A-Z0-9_]*-[1-9][0-9]*$")],
        add_labels: Annotated[list[str], Field(min_length=1, max_length=1)],
        remove_labels: Annotated[list[str], Field(max_length=3)],
    ) -> str:
        payload = label_update(issue_key, add_labels, remove_labels)
        fetcher = await get_jira_fetcher(ctx)
        # Whole-field replacement can erase a concurrent human label. Jira applies
        # these add/remove operations to its current label set in one request.
        fetcher.jira.update_issue(issue_key=issue_key, update=payload)
        return json.dumps({"issue_key": issue_key, "mutation_requested": True})

    jira_mcp.tool(
        name="update_factory_labels",
        tags={"jira", "write", "toolset:jira_issues"},
        annotations={"title": "Update Factory Labels", "readOnlyHint": False, "destructiveHint": True},
    )(update_factory_labels)
    return update_factory_labels


def main():
    register_factory_labels()
    from mcp_atlassian import main as provider_main

    provider_main()


if __name__ == "__main__":
    main()
