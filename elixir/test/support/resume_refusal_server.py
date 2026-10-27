"""Synthetic correlated resume refusal with no session or turn side effects."""
import json
import os
import sys

trace = sys.argv[1]


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    with open(trace, "a") as output:
        output.write(line)
    method = request.get("method")
    identifier = request.get("id")
    rejected_method = open(trace + ".method").read() if os.path.exists(trace + ".method") else "thread/resume"
    if method == rejected_method and (method != "thread/resume" or not os.path.exists(trace + ".allow")):
        if os.path.exists(trace + ".exit"):
            sys.exit(17)
        reply_id = identifier + 100 if os.path.exists(trace + ".foreign-id") else identifier
        send({"id": reply_id, "error": json.load(open(trace + ".error"))})
    elif method == "initialize":
        initialized = json.load(open(trace + ".initialize")) if os.path.exists(trace + ".initialize") else {}
        send({"id": identifier, "result": initialized})
    elif method == "config/read":
        send({"id": identifier, "result": json.load(open(trace + ".config"))})
    elif method == "account/read":
        send({"id": identifier, "result": {"account": {"type": "chatgpt"}}})
    elif method == "mcpServerStatus/list":
        send({"id": identifier, "result": {"data": [], "nextCursor": None}})
    elif method == "thread/resume":
        if os.path.exists(trace + ".allow"):
            root = os.getcwd()
            thread = request["params"]["threadId"]
            send({"id": identifier, "result": {"thread": {"id": thread, "cwd": root}, "cwd": root, "runtimeWorkspaceRoots": [root], "reasoningEffort": "medium", "activePermissionProfile": {"id": "symphony_ticket_file_source_v1"}, "approvalPolicy": "never", "model": "gpt-6-luna"}})
        else:
            sys.exit(18)
    elif method == "turn/start":
        send({"id": identifier, "result": {"turn": {"id": "resumed-turn"}}})
        output = {"status": "COMPLETE", "changed_paths": [], "commit_message": None, "blockers": [], "checks": []}
        item = {"id": "resumed-final", "type": "agentMessage", "phase": "final_answer", "text": json.dumps(output)}
        send({"method": "item/completed", "params": {"threadId": "existing-thread", "turnId": "resumed-turn", "item": item}})
        send({"method": "turn/completed", "params": {"threadId": "existing-thread", "turn": {"id": "resumed-turn", "status": "completed", "items": [item]}}})
    elif method == "thread/unsubscribe":
        send({"id": identifier, "result": {"status": "unsubscribed"}})
