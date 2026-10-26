"""Restricted app-server fixture: restore only bytes obtained through file tools."""
import json
import os
import sys

trace = sys.argv[1]


def send(value):
    print(json.dumps(value), flush=True)


def call(identifier, tool, arguments):
    send({"id": identifier, "method": "item/tool/call", "params": {"threadId": "file-worker", "turnId": "file-turn", "callId": "revision-" + str(identifier), "tool": tool, "arguments": arguments}})


for line in sys.stdin:
    with open(trace, "a") as output:
        output.write(line)
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        send(json.load(open(trace + ".initialize")))
    elif method == "config/read":
        send({"id": 15, "result": json.load(open(trace + ".config"))})
    elif method == "account/read":
        send({"id": 17, "result": {"account": {"type": "chatgpt"}}})
    elif method == "mcpServerStatus/list":
        send({"id": 16, "result": {"data": [], "nextCursor": None}})
    elif method in ("thread/start", "thread/resume"):
        if method == "thread/start":
            catalog = request["params"]["dynamicTools"]
            with open(trace + ".catalog", "w") as output:
                json.dump(catalog, output)
        else:
            assert "dynamicTools" not in request["params"]
            catalog = json.load(open(trace + ".catalog"))
        assert [tool["name"] for tool in catalog] == ["repo_read", "repo_list", "repo_write", "repo_delete", "repo_mkdir", "repo_read_binary", "repo_write_binary"]
        root = os.getcwd()
        send({"id": 2, "result": {"thread": {"id": "file-worker", "cwd": root}, "cwd": root, "runtimeWorkspaceRoots": [root], "reasoningEffort": "medium", "activePermissionProfile": {"id": "symphony_ticket_file_source_v1"}, "approvalPolicy": "never", "model": "gpt-6-luna"}})
    elif method == "turn/start":
        send({"id": request["id"], "result": {"turn": {"id": "file-turn"}}})
        call(77, "repo_read_binary", {"path": ".symphony-base/fixture.txt", "offset": 0})
    elif request.get("id") == 77:
        assert request["result"]["success"] is True
        historical = json.loads(request["result"]["contentItems"][0]["text"])
        assert historical["source"] == "CONTRACT_BASE"
        assert historical["write_cas_warning"]
        assert historical["next_offset"] is None
        call(78, "repo_read_binary", {"path": "fixture.txt", "offset": 0})
    elif request.get("id") == 78:
        assert request["result"]["success"] is True
        current = json.loads(request["result"]["contentItems"][0]["text"])
        assert historical["sha256"] != current["sha256"]
        call(79, "repo_write_binary", {"path": "fixture.txt", "expected_sha256": historical["sha256"], "content_base64": historical["content_base64"]})
    elif request.get("id") == 79:
        assert request["result"]["success"] is False
        call(80, "repo_write_binary", {"path": "fixture.txt", "expected_sha256": current["sha256"], "content_base64": historical["content_base64"]})
    elif request.get("id") == 80:
        assert request["result"]["success"] is True
        send({"method": "turn/completed", "params": {"threadId": "file-worker", "turn": {"id": "file-turn", "status": "completed", "items": []}}})
    elif method == "thread/unsubscribe":
        send({"id": 6, "result": {"status": "unsubscribed"}})
