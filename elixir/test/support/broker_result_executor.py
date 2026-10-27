import json
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("a") as trace:
    trace.write("executed\n")
if len(sys.argv) > 3 and sys.argv[3] == "finish":
    running = pathlib.Path(sys.argv[2])
    running.rename(running.with_suffix(".finished"))
elif len(sys.argv) > 3 and sys.argv[3] == "conflict":
    pathlib.Path(sys.argv[2]).write_text('{"ok":"conflicting outcome"}')
elif len(sys.argv) > 2:
    pathlib.Path(sys.argv[2]).mkdir()
print(json.dumps({"receipt": "external-complete"}, separators=(",", ":")))
