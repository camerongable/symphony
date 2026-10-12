"""Fixed controller file transport. Input is data, never Python or shell code."""
import base64
import contextlib
import ctypes
import errno
import hashlib
import json
import os
import signal
import stat
import sys
import unicodedata

MAX_FRAME = 2_097_152
MAX_FILE = 262_144
BLOCKED = {".git", ".codex", ".agents", ".env", ".ssh", ".aws", ".config", ".factory-file-io", "node_modules", "_build", "deps"}
DIRECTORY_TAG = b"com.symphony.factory_creation"


class Rejected(Exception):
    pass


def reject(code):
    raise Rejected(code)


def blocked(part):
    folded = unicodedata.normalize("NFC", part).casefold()
    return folded in BLOCKED or folded.startswith((".env.", ".symphony-"))


def components(path, directory=False):
    if directory and path == ".":
        return []
    if not isinstance(path, str) or not 1 <= len(path.encode("utf-8")) <= 1024:
        reject("path_rejected")
    if any(char in path for char in "\x00\\\r\n"):
        reject("path_rejected")
    parts = path.split("/")
    if any(part in ("", ".", "..") or blocked(part) for part in parts):
        reject("path_rejected")
    return parts


@contextlib.contextmanager
def directory_at(root, parts):
    descriptor = os.dup(root)
    try:
        for part in parts:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def root_unchanged(root, request):
    actual = os.fstat(root)
    if (actual.st_dev, actual.st_ino) != (request["device"], request["inode"]):
        reject("root_identity_changed")
    initial = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        with directory_at(initial, request["root"].split("/")[1:]) as current_root:
            current = os.fstat(current_root)
            if (current.st_dev, current.st_ino) != (actual.st_dev, actual.st_ino):
                reject("root_identity_changed")
    finally:
        os.close(initial)


def parent_unchanged(root, parts, parent):
    with directory_at(root, parts) as current:
        before, after = os.fstat(parent), os.fstat(current)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            reject("parent_identity_changed")


def contents(parent, leaf, absent=False, text=True, linked_identity=None):
    try:
        descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        if absent:
            return None, None
        raise
    try:
        info = os.fstat(descriptor)
        linked_target = linked_identity == (info.st_dev, info.st_ino) and info.st_nlink == 2
        if not stat.S_ISREG(info.st_mode) or (info.st_nlink != 1 and not linked_target):
            reject("path_rejected")
        data = bytearray()
        while len(data) <= MAX_FILE:
            chunk = os.read(descriptor, min(65_536, MAX_FILE + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > MAX_FILE:
            reject("file_too_large")
        raw = bytes(data)
        if text:
            if b"\x00" in raw:
                reject("non_text")
            raw.decode("utf-8", errors="strict")
        return raw, stat.S_IMODE(info.st_mode)
    finally:
        os.close(descriptor)


def digest(raw):
    return "ABSENT" if raw is None else hashlib.sha256(raw).hexdigest()


def directory_nonce(descriptor, nonce=None):
    # The nonce is metadata, not a source marker that could enter a commit.
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    if nonce is not None:
        setter = system.fsetxattr
        setter.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        setter.restype = ctypes.c_int
        raw = nonce.encode("ascii")
        if setter(descriptor, DIRECTORY_TAG, raw, len(raw), 0, 2) != 0:
            reject("directory_tag_unproven")
    getter = system.fgetxattr
    getter.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    getter.restype = ctypes.c_ssize_t
    data = ctypes.create_string_buffer(64)
    size = getter(descriptor, DIRECTORY_TAG, data, 64, 0, 0)
    if size == -1 and ctypes.get_errno() == errno.ENOATTR:
        return "UNTAGGED"
    if size != 64:
        reject("directory_tag_unproven")
    tag = data.raw.decode("ascii")
    if any(char not in "0123456789abcdef" for char in tag):
        reject("directory_tag_unproven")
    return tag


def directory_digest(descriptor):
    info = os.fstat(descriptor)
    return "DIRECTORY:%d:%d:%s" % (info.st_dev, info.st_ino, directory_nonce(descriptor))


def path_digest(parent, leaf):
    try:
        descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        return "ABSENT"
    try:
        if stat.S_ISDIR(os.fstat(descriptor).st_mode):
            return directory_digest(descriptor)
    finally:
        os.close(descriptor)
    raw, _ = contents(parent, leaf, text=False)
    return digest(raw)


def replacement_bytes(request):
    args = request["arguments"]
    if request["operation"] == "replace_binary":
        encoded = args.get("content_base64")
        if not isinstance(encoded, str) or len(encoded) > 349_528:
            reject("write_rejected")
        raw = base64.b64decode(encoded, validate=True)
        if len(raw) > MAX_FILE or base64.b64encode(raw).decode("ascii") != encoded:
            reject("write_rejected")
        return raw
    new = args.get("content")
    if not isinstance(new, str) or b"\x00" in new.encode("utf-8") or len(new.encode("utf-8")) > MAX_FILE:
        reject("write_rejected")
    return new.encode("utf-8")


def record_creator(root, parent, temporary, created, request):
    if len(sys.argv) != 3 or sys.argv[1] != "--creator-binding-sha":
        reject("creator_binding_unproven")
    binding_sha = sys.argv[2]
    if len(binding_sha) != 64 or any(char not in "0123456789abcdef" for char in binding_sha):
        reject("creator_binding_unproven")
    root_info, parent_info = os.fstat(root), os.fstat(parent)
    event = {"version": 1, "event": "TEMP_CREATED", "nonce": request["nonce"], "binding_sha256": binding_sha, "pid": os.getpid(),
             "path": request["arguments"]["path"], "temporary": temporary,
             "root_device": root_info.st_dev, "root_inode": root_info.st_ino,
             "parent_device": parent_info.st_dev, "parent_inode": parent_info.st_ino,
             "device": created.st_dev, "inode": created.st_ino}
    raw = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
    sys.stdout.buffer.flush()
    header = sys.stdin.buffer.read(4)
    if len(header) != 4 or not 1 <= int.from_bytes(header, "big") <= 1024:
        reject("creator_ack_unproven")
    size = int.from_bytes(header, "big")
    reply = sys.stdin.buffer.read(size)
    if len(reply) != size or json.loads(reply) != {"version": 1, "event": "TEMP_RECORDED", "nonce": request["nonce"], "creator_sha256": hashlib.sha256(raw).hexdigest()}:
        reject("creator_ack_unproven")


def temporary_unchanged(parent, temporary, created):
    observed = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
    if (observed.st_dev, observed.st_ino) != (created.st_dev, created.st_ino) or not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
        reject("temporary_identity_changed")


def replace(root, parent, parts, leaf, request):
    args = request["arguments"]
    text = request["operation"] == "replace"
    raw, mode = contents(parent, leaf, absent=True, text=text)
    expected = args.get("expected_sha256")
    new_bytes = replacement_bytes(request)
    if digest(raw) != expected:
        reject("compare_failed")
    parent_unchanged(root, parts, parent)
    root_unchanged(root, request)
    temporary = ".symphony-" + request["nonce"]
    descriptor = None
    temporary_identity = None
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode or 0o644, dir_fd=parent)
        created = os.fstat(descriptor)
        temporary_identity = (created.st_dev, created.st_ino)
        record_creator(root, parent, temporary, created, request)
        parent_unchanged(root, parts, parent)
        root_unchanged(root, request)
        temporary_unchanged(parent, temporary, created)
        os.fchmod(descriptor, mode if mode is not None else 0o644)
        offset = 0
        while offset < len(new_bytes):
            offset += os.write(descriptor, new_bytes[offset:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        # Only factory-owned operations are serialized; arbitrary same-UID writers are not a CAS primitive.
        parent_unchanged(root, parts, parent)
        root_unchanged(root, request)
        latest, _ = contents(parent, leaf, absent=True, text=text)
        if digest(latest) != expected:
            reject("compare_failed")
        temporary_unchanged(parent, temporary, created)
        if expected == "ABSENT":
            os.link(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
            os.unlink(temporary, dir_fd=parent)
        else:
            os.rename(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
        root_unchanged(root, request)
        parent_unchanged(root, parts, parent)
        after, _ = contents(parent, leaf, text=text)
        if after != new_bytes:
            reject("write_unproven")
        return {"sha256": digest(after)}
    finally:
        if descriptor is not None:
            os.close(descriptor)
        discard_created(root, parent, parts, temporary, request, temporary_identity)


def discard_created(root, parent, parts, temporary, request, identity):
    # O_EXCL failure grants no ownership of the colliding pathname.
    if identity is None:
        return
    try:
        current = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
        if (current.st_dev, current.st_ino) == identity:
            root_unchanged(root, request)
            parent_unchanged(root, parts, parent)
            os.unlink(temporary, dir_fd=parent)
            os.fsync(parent)
    except FileNotFoundError:
        pass


def recover_temporary(root, parent, parts, leaf, request):
    args = request["arguments"]
    source_nonce = args["source_nonce"]
    identities = ("parent_device", "parent_inode", "device", "inode")
    if not isinstance(source_nonce, str) or len(source_nonce) != 64 or any(char not in "0123456789abcdef" for char in source_nonce) or any(type(args[key]) is not int or args[key] <= 0 for key in identities):
        reject("temporary_identity_unproven")
    root_unchanged(root, request)
    parent_unchanged(root, parts, parent)
    parent_info = os.fstat(parent)
    if (parent_info.st_dev, parent_info.st_ino) != (args["parent_device"], args["parent_inode"]):
        reject("temporary_parent_changed")
    temporary = ".symphony-" + source_nonce
    try:
        descriptor = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        return {"absent": True, "removed": False}
    try:
        created = os.fstat(descriptor)
        expected_identity = (args["device"], args["inode"])
        if (created.st_dev, created.st_ino) != expected_identity or not stat.S_ISREG(created.st_mode) or created.st_uid != os.geteuid() or created.st_nlink not in (1, 2):
            reject("temporary_identity_changed")
        target, _ = contents(parent, leaf, absent=True, text=False, linked_identity=expected_identity)
        if digest(target) not in (args["before_sha256"], args["after_sha256"]):
            reject("temporary_target_changed")
        if created.st_nlink == 2:
            target_info = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
            if (target_info.st_dev, target_info.st_ino) != expected_identity or digest(target) != args["after_sha256"]:
                reject("temporary_links_unproven")
        root_unchanged(root, request)
        parent_unchanged(root, parts, parent)
        observed = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
        if (observed.st_dev, observed.st_ino, observed.st_nlink) != (created.st_dev, created.st_ino, created.st_nlink):
            reject("temporary_identity_changed")
        os.unlink(temporary, dir_fd=parent)
        os.fsync(parent)
        root_unchanged(root, request)
        parent_unchanged(root, parts, parent)
        try:
            os.stat(temporary, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return {"absent": True, "removed": True}
        reject("temporary_removal_unproven")
    finally:
        os.close(descriptor)


def delete(root, parent, parts, leaf, request):
    raw, _ = contents(parent, leaf, text=False)
    if digest(raw) != request["arguments"].get("expected_sha256"):
        reject("compare_failed")
    parent_unchanged(root, parts, parent)
    root_unchanged(root, request)
    latest, _ = contents(parent, leaf, text=False)
    if digest(latest) != request["arguments"].get("expected_sha256"):
        reject("compare_failed")
    os.unlink(leaf, dir_fd=parent)
    os.fsync(parent)
    root_unchanged(root, request)
    parent_unchanged(root, parts, parent)
    after, _ = contents(parent, leaf, absent=True, text=False)
    if after is not None:
        reject("write_unproven")
    return {"sha256": "ABSENT"}


def mkdir(root, parent, parts, leaf, request):
    parent_unchanged(root, parts, parent)
    root_unchanged(root, request)
    os.mkdir(leaf, 0o755, dir_fd=parent)
    descriptor = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        directory_nonce(descriptor, request["nonce"])
        expected = directory_digest(descriptor)
        os.fsync(descriptor)
        os.fsync(parent)
        root_unchanged(root, request)
        parent_unchanged(root, parts, parent)
        if path_digest(parent, leaf) != expected:
            reject("directory_creation_unproven")
        return {"sha256": expected}
    finally:
        os.close(descriptor)


def operate(request):
    required = {"version", "nonce", "root", "device", "inode", "operation", "arguments"}
    if not isinstance(request, dict) or set(request) != required or type(request["version"]) is not int or request["version"] != 1 or not isinstance(request["arguments"], dict):
        reject("request_rejected")
    nonce = request["nonce"]
    if not isinstance(nonce, str) or len(nonce) != 64 or any(char not in "0123456789abcdef" for char in nonce):
        reject("request_rejected")
    fields = {"read": {"path"}, "read_binary": {"path"}, "list": {"path"}, "digest": {"path"}, "text_digest": {"path"}, "temporary_absent": {"path", "source_nonce"}, "temporary_recover": {"path", "source_nonce", "parent_device", "parent_inode", "device", "inode", "before_sha256", "after_sha256"}, "replace": {"path", "expected_sha256", "content"}, "replace_binary": {"path", "expected_sha256", "content_base64"}, "delete": {"path", "expected_sha256"}, "mkdir": {"path"}}
    if not isinstance(request["operation"], str) or set(request["arguments"]) != fields.get(request["operation"]):
        reject("request_rejected")
    if not isinstance(request["root"], str) or not request["root"].startswith("/"):
        reject("request_rejected")
    if any(type(request[key]) is not int or request[key] <= 0 for key in ("device", "inode")):
        reject("request_rejected")
    # Walk the absolute root too: a replaced ancestor must not silently resolve to a different tree.
    absolute = request["root"].split("/")[1:]
    if any(part in ("", ".", "..") for part in absolute):
        reject("request_rejected")
    initial = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        with directory_at(initial, absolute) as root:
            root_unchanged(root, request)
            operation = request["operation"]
            path = request["arguments"].get("path")
            parts = components(path, directory=operation == "list")
            if operation == "list":
                with directory_at(root, parts) as directory:
                    names = []
                    with os.scandir(directory) as entries:
                        for count, entry in enumerate(entries):
                            if count >= 512:
                                reject("directory_too_large")
                            if not blocked(entry.name):
                                names.append(entry.name)
                    root_unchanged(root, request)
                    parent_unchanged(root, parts, directory)
                    return {"entries": sorted(names)}
            if not parts or operation not in ("read", "read_binary", "digest", "text_digest", "temporary_absent", "temporary_recover", "replace", "replace_binary", "delete", "mkdir"):
                reject("request_rejected")
            with directory_at(root, parts[:-1]) as parent:
                if operation == "temporary_recover":
                    return recover_temporary(root, parent, parts[:-1], parts[-1], request)
                if operation == "temporary_absent":
                    source_nonce = request["arguments"]["source_nonce"]
                    if not isinstance(source_nonce, str) or len(source_nonce) != 64 or any(char not in "0123456789abcdef" for char in source_nonce):
                        reject("request_rejected")
                    try:
                        os.stat(".symphony-" + source_nonce, dir_fd=parent, follow_symlinks=False)
                        absent = False
                    except FileNotFoundError:
                        absent = True
                    root_unchanged(root, request)
                    parent_unchanged(root, parts[:-1], parent)
                    return {"absent": absent}
                if operation in ("replace", "replace_binary"):
                    return replace(root, parent, parts[:-1], parts[-1], request)
                if operation == "delete":
                    return delete(root, parent, parts[:-1], parts[-1], request)
                if operation == "mkdir":
                    return mkdir(root, parent, parts[:-1], parts[-1], request)
                if operation == "digest":
                    result = {"sha256": path_digest(parent, parts[-1])}
                    root_unchanged(root, request)
                    parent_unchanged(root, parts[:-1], parent)
                    return result
                raw, _ = contents(parent, parts[-1], absent=operation == "text_digest", text=operation in ("read", "text_digest"))
                root_unchanged(root, request)
                parent_unchanged(root, parts[:-1], parent)
                result = {"sha256": digest(raw)}
                if operation == "read":
                    result["text"] = raw.decode("utf-8")
                if operation == "read_binary":
                    result["content_base64"] = base64.b64encode(raw).decode("ascii")
                return result
    finally:
        os.close(initial)


def main():
    # Bound incomplete input; the controller must still observe the actual process exit.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(3)
    request = {}
    try:
        size_bytes = sys.stdin.buffer.read(4)
        if len(size_bytes) != 4:
            reject("frame_rejected")
        size = int.from_bytes(size_bytes, "big")
        if not 1 <= size <= MAX_FRAME:
            reject("frame_rejected")
        data = sys.stdin.buffer.read(size)
        if len(data) != size:
            reject("frame_rejected")
        parsed = json.loads(data.decode("utf-8"))
        if not isinstance(parsed, dict):
            reject("request_rejected")
        request = parsed
        result = operate(request)
        response = {"version": 1, "nonce": request["nonce"], "ok": True, "result": result}
    except Rejected as error:
        response = {"version": 1, "nonce": request.get("nonce"), "ok": False, "error": str(error)}
    except FileNotFoundError:
        response = {"version": 1, "nonce": request.get("nonce"), "ok": False, "error": "no_such_file"}
    except (OSError, UnicodeError, ValueError, TypeError, KeyError):
        response = {"version": 1, "nonce": request.get("nonce"), "ok": False, "error": "io_rejected"}
    encoded = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_FRAME:
        encoded = json.dumps({"version": 1, "nonce": request.get("nonce"), "ok": False, "error": "frame_rejected"}).encode("utf-8")
    if request.get("operation") == "temporary_recover":
        response["helper_pid"] = os.getpid()
        encoded = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(len(encoded).to_bytes(4, "big") + encoded)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
