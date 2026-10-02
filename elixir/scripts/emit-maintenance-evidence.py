"""Emit target-attested native probe evidence without filesystem or ledger writes."""

import argparse
import base64
import hashlib
import json
import re
import shlex
import sys

BINDING_FIELDS = {
    "run_id", "task_key", "thread_id", "writer_turn_id", "codex_project_id",
    "worktree", "candidate_sha", "source_cwd",
}
TOOL = "mcp__codex_app__list_artifacts"
PROVENANCE = "TARGET_ATTESTED_NATIVE_CHAT"


def decode_payload(value):
    return json.loads(base64.b64decode(value, validate=True).decode("utf-8"))


def envelope(request_key, payload):
    if not re.fullmatch(r"desktop:maintenance:[0-9a-f]{64}:native-worktree-probe", request_key):
        raise ValueError("invalid request marker")
    if not isinstance(payload, dict) or set(payload) != {"binding", "tool", "artifact_output"}:
        raise ValueError("invalid maintenance input")
    binding = payload["binding"]
    if not isinstance(binding, dict) or set(binding) != BINDING_FIELDS:
        raise ValueError("invalid binding fields")
    if not all(isinstance(value, str) and value for value in binding.values()):
        raise ValueError("incomplete binding")
    if binding["task_key"] != binding["run_id"] + ":feature-writer":
        raise ValueError("writer identity mismatch")
    if not re.fullmatch(r"[0-9a-f]{40}", binding["candidate_sha"]):
        raise ValueError("invalid candidate")
    if not all(binding[key].startswith("/") for key in ("worktree", "source_cwd")):
        raise ValueError("checkout paths must be absolute")
    if payload["tool"] != TOOL:
        raise ValueError("unsupported tool")
    observed = payload["artifact_output"]
    if not isinstance(observed, dict) or set(observed) != {"artifacts"}:
        raise ValueError("invalid artifact output")
    if not isinstance(observed["artifacts"], list) or not all(isinstance(item, dict) for item in observed["artifacts"]):
        raise ValueError("invalid artifacts")
    with open(__file__, "rb") as source:
        producer_sha256 = hashlib.sha256(source.read()).hexdigest()
    return dict(payload, version=1, provenance=PROVENANCE, request_key=request_key, emitter_sha256=producer_sha256)


def verify_command(encoded):
    command = base64.b64decode(encoded, validate=True).decode("utf-8")
    argv = shlex.split(command)
    if len(argv) == 3 and argv[:2] == ["/bin/zsh", "-lc"]:
        argv = shlex.split(argv[2])
    if len(argv) != 6 or argv[:3] != ["python3", "-B", __file__] or argv[4] != "--payload-base64":
        raise ValueError("unsupported emitter command")
    return envelope(argv[3], decode_payload(argv[5]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("request_key", nargs="?")
    parser.add_argument("--payload-base64")
    parser.add_argument("--verify-command-base64")
    args = parser.parse_args()
    if args.verify_command_base64 and not args.request_key and not args.payload_base64:
        result = verify_command(args.verify_command_base64)
    elif args.request_key and args.payload_base64 and not args.verify_command_base64:
        result = envelope(args.request_key, decode_payload(args.payload_base64))
    else:
        raise ValueError("provide one bounded emit or command verification operation")
    print(json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, KeyError, UnicodeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
