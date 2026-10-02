"""Emit a read-only source checkout receipt with target-attested attachments."""

import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys


def decode(value):
    return json.loads(base64.b64decode(value, validate=True).decode("utf-8"))


def headers(key, payload):
    if not isinstance(key, str) or not key.endswith(":bootstrap"):
        raise ValueError("invalid bootstrap key")
    if not isinstance(payload, dict) or set(payload) != {"control_cwd", "artifact_output"}:
        raise ValueError("invalid source binding input")
    if not isinstance(payload["control_cwd"], str) or not os.path.isabs(payload["control_cwd"]):
        raise ValueError("invalid control path")
    observed = payload["artifact_output"]
    if not isinstance(observed, dict) or set(observed) != {"artifacts"}:
        raise ValueError("invalid artifact output")
    if not isinstance(observed["artifacts"], list) or not all(isinstance(item, dict) for item in observed["artifacts"]):
        raise ValueError("invalid artifacts")
    with open(__file__, "rb") as source:
        digest = hashlib.sha256(source.read()).hexdigest()
    return dict(payload, request_key=key, emitter_sha256=digest,
                provenance="TARGET_ATTESTED_NATIVE_CHAT", version=1)


def verify_command(encoded):
    argv = shlex.split(base64.b64decode(encoded, validate=True).decode("utf-8"))
    if len(argv) == 3 and argv[:2] == ["/bin/zsh", "-lc"]:
        argv = shlex.split(argv[2])
    if len(argv) != 6 or argv[:3] != ["python3", "-B", __file__] or argv[4] != "--payload-base64":
        raise ValueError("unsupported source receipt command")
    return headers(argv[3], decode(argv[5]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("request_key", nargs="?")
    parser.add_argument("--payload-base64")
    parser.add_argument("--verify-command-base64")
    args = parser.parse_args()
    if args.verify_command_base64 and not args.request_key and not args.payload_base64:
        result = verify_command(args.verify_command_base64)
    elif args.request_key and args.payload_base64 and not args.verify_command_base64:
        result = headers(args.request_key, decode(args.payload_base64))
        cwd = os.path.realpath(os.getcwd())
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cwd, text=True).strip()
        if not re.fullmatch(r"[0-9a-f]{40}", head):
            raise ValueError("invalid source commit")
        result.update(source_cwd=cwd, head_sha=head)
    else:
        raise ValueError("provide one emit or command verification operation")
    print(json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, KeyError, UnicodeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
