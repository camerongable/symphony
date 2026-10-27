import pathlib
import sys
import time

target = pathlib.Path(sys.argv[1])
marker = pathlib.Path(sys.argv[2])
pathlib.Path(str(marker) + ".ready").write_text("ready")
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    if any(target.parent.glob(target.name + ".writing.*")):
        target.write_text('{"ok":"racing conflict"}')
        marker.write_text(str(target))
        break
