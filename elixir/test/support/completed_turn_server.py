"""Synthetic app-server: commit one final result, then lose its terminal acknowledgement."""
import json
import os
import sys
import time

trace = sys.argv[1]
read_count = 0
turn_list_count = 0


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    with open(trace, "a") as output:
        output.write(line)
    method = request.get("method")
    identifier = request.get("id")
    if method == "initialize":
        send({"id": identifier, "result": json.load(open(trace + ".initialize"))})
    elif method == "config/read":
        send({"id": identifier, "result": json.load(open(trace + ".config"))})
    elif method == "account/read":
        send({"id": identifier, "result": {"account": {"type": "chatgpt"}}})
    elif method == "mcpServerStatus/list":
        send({"id": identifier, "result": {"data": [], "nextCursor": None}})
    elif method in ("thread/start", "thread/resume"):
        root = os.getcwd()
        send({"id": identifier, "result": {"thread": {"id": "completed-worker", "cwd": root}, "cwd": root, "runtimeWorkspaceRoots": [root], "reasoningEffort": "medium", "activePermissionProfile": {"id": "symphony_ticket_file_source_v1"}, "approvalPolicy": "never", "model": "gpt-6-luna"}})
    elif method == "turn/start":
        item = {"id": "completed-final", "type": "agentMessage", "phase": "final_answer", "text": json.dumps({"status": "COMPLETE", "changed_paths": [], "commit_message": None, "blockers": [], "checks": []})}
        state = {"id": "completed-worker", "cwd": os.getcwd(), "status": {"type": "idle"}, "updatedAt": 1, "turns": [{"id": "completed-turn", "status": "completed", "error": None, "items": [item]}]}
        if os.path.exists(trace + ".native-status"):
            state["status"] = json.load(open(trace + ".native-status"))
        with open(trace + ".state", "w") as output:
            json.dump(state, output)
        send({"id": identifier, "result": {"turn": {"id": "completed-turn"}}})
        send({"method": "item/completed", "params": {"threadId": "completed-worker", "turnId": "completed-turn", "item": item}})
        sys.exit(7)
    elif method == "thread/read":
        read_count += 1
        if os.path.exists(trace + ".deny-read"):
            send({"id": identifier, "error": {"code": -32600, "message": "native read unavailable"}})
        else:
            state = json.load(open(trace + ".state"))
            if os.path.exists(trace + ".version-drift") and read_count > 1:
                state["updatedAt"] += 1
            send({"id": identifier, "result": {"thread": state}})
    elif method == "thread/turns/list":
        turn_list_count += 1
        state = json.load(open(trace + ".state"))
        if os.path.exists(trace + ".barrier"):
            with open(trace + ".ready", "w") as output:
                output.write("native read reached")
            deadline = time.monotonic() + 5
            while not os.path.exists(trace + ".release") and time.monotonic() < deadline:
                time.sleep(0.01)
        if os.path.exists(trace + ".confirmation-drift") and turn_list_count > 1:
            state["turns"][0]["items"] = []
        send({"id": identifier, "result": {"data": state["turns"], "nextCursor": None}})
    elif method == "thread/queue/list":
        queued = [{"id": "pending"}] if os.path.exists(trace + ".queued") else []
        send({"id": identifier, "result": {"data": queued, "nextCursor": None}})
    elif method == "thread/unsubscribe":
        send({"id": identifier, "result": {"status": "unsubscribed"}})
