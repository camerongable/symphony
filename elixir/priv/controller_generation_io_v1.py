"""Bounded descriptor-relative generation observations; this command never writes."""

import base64
import hashlib
import json
import os
import signal
import stat
import sys

LIMIT = 1_048_576


def identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, value.st_mode)


def components(path):
    if not isinstance(path, str) or not path or len(path.encode()) > 4096:
        raise ValueError("path")
    parts = path.split("/")
    if any(not part or part in (".", "..") or part.startswith("-")
           or "\\" in part or "\x00" in part for part in parts):
        raise ValueError("path")
    return parts


def parent_fd(root, parts):
    current = os.dup(root)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=current)
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


def read_file(root, path):
    parts = components(path)
    parent = parent_fd(root, parts)
    try:
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_size > LIMIT:
                raise ValueError("file")
            chunks = []
            size = 0
            while True:
                chunk = os.read(fd, min(65536, LIMIT + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > LIMIT:
                    raise ValueError("limit")
            data = b"".join(chunks)
            if (identity(before) != identity(os.fstat(fd))
                    or identity(before) != identity(os.stat(
                        parts[-1], dir_fd=parent, follow_symlinks=False))):
                raise ValueError("changed")
            # Rewalk every directory so a renamed ancestor cannot authenticate
            # bytes no longer reachable through the bound SOURCE path.
            current = parent_fd(root, parts)
            try:
                if identity(os.fstat(current)) != identity(os.fstat(parent)):
                    raise ValueError("parent")
            finally:
                os.close(current)
            return {"path": path, "device": before.st_dev, "inode": before.st_ino,
                    "size": size, "mtime_ns": before.st_mtime_ns,
                    "ctime_ns": before.st_ctime_ns, "mode": before.st_mode,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes_base64": base64.b64encode(data).decode("ascii")}
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def observe(root_path, paths):
    if (not isinstance(paths, list) or not 1 <= len(paths) <= 32
            or any(not isinstance(path, str) for path in paths)
            or len(set(paths)) != len(paths)
            or not os.path.isabs(root_path)
            or os.path.realpath(root_path) != root_path):
        raise ValueError("input")
    root = os.open(root_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(root)
        files = []
        size = 0
        for path in sorted(paths):
            value = read_file(root, path)
            size += value["size"]
            if size > LIMIT:
                raise ValueError("limit")
            files.append(value)
        if (identity(before) != identity(os.fstat(root))
                or identity(before) != identity(os.stat(root_path, follow_symlinks=False))):
            raise ValueError("root")
        return {"version": 1, "root_device": before.st_dev,
                "root_inode": before.st_ino, "files": files}
    finally:
        os.close(root)


def main():
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError()))
    signal.alarm(6)
    try:
        if len(sys.argv) != 4 or sys.argv[1] != "observe":
            raise ValueError("command")
        result = observe(sys.argv[2], json.loads(sys.argv[3]))
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))
        return 0
    except Exception:
        print('{"error":"GENERATION_INPUT_UNPROVEN"}')
        return 1
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
