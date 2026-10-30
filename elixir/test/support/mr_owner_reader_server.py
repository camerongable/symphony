import atexit
import json
import os
import pathlib
import signal
import sys
import time
import threading

config = json.loads(pathlib.Path(sys.argv[1]).read_text())


def phase():
    return pathlib.Path(config["phase"]).read_text()


def record(event, **fields):
    with pathlib.Path(config["trace"]).open("a") as trace:
        trace.write(json.dumps({"event": event, "pid": os.getpid(), "phase": phase(), **fields}) + "\n")


def reply(request, value):
    print(json.dumps({"id": request["id"], "result": value}), flush=True)


def overridden(name, original):
    path = pathlib.Path(config[name])
    return json.loads(path.read_text()) if path.exists() else original


def terminate(_signal, _frame):
    sys.exit(0)


signal.signal(signal.SIGTERM, terminate)
atexit.register(lambda: record("closed"))


def emit_idle():
    while True:
        if pathlib.Path(config["idle_file"]).exists():
            try:
                notification = json.loads(pathlib.Path(config["idle_file"]).read_text())
            except ValueError:
                print(pathlib.Path(config["idle_file"]).read_text(), flush=True)
                record("idle_emitted", method=None)
                return
            print(json.dumps(notification), flush=True)
            record("idle_emitted", method=notification.get("method"))
            return
        time.sleep(0.01)


threading.Thread(target=emit_idle, daemon=True).start()
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    params = request.get("params", {})
    thread = params.get("threadId")
    record("rpc", method=method, thread=thread, tool=params.get("tool"))
    if method == "initialize":
        delay = config["delays"].get(phase(), 0)
        if phase() == "prepare" and config.get("slow_first_initialize"):
            try:
                pathlib.Path(config["slow_first_initialize"]).open("x").close()
                delay = 11
            except FileExistsError:
                pass
        started = time.monotonic()
        time.sleep(delay)
        reply(request, config["initialize"])
        record("initialized", elapsed_ms=int((time.monotonic() - started) * 1000))
    elif method == "initialized":
        pass
    elif method == "thread/start":
        reply(request, {"thread": {"id": "fixture-jira-reader"}})
        for name in ("Jira", "GitLab"):
            print(json.dumps({"method": "mcpServer/startupStatus/updated", "params": {"name": name, "status": "ready"}}), flush=True)
    elif method == "mcpServerStatus/list":
        reply(request, config["catalog"])
    elif method == "mcpServer/tool/call":
        value = overridden("branch_file", config["branch"]) if params.get("tool") == "get_branch" else config["snapshot"]
        reply(request, {"structuredContent": value})
    elif method == "thread/read":
        native = config["broker_native"] if thread == config["broker"] else config["native"]
        reply(request, {"thread": native})
    elif method == "thread/turns/list":
        latest = config["broker_latest"] if thread == config["broker"] else overridden("latest_file", config["latest"])
        reply(request, latest)
    elif method == "thread/queue/list":
        reply(request, overridden("queue_file", {"data": [], "nextCursor": None}))
    elif method == "thread/unsubscribe":
        reply(request, {})
    else:
        print(json.dumps({"id": request.get("id"), "error": {"code": -32601, "message": "unexpected synthetic method"}}), flush=True)
