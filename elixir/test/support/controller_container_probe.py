"""Zero-inference containment evidence only; not a Grail build/test executor."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import uuid

DOCKER = "/usr/local/bin/docker"
OWNER = "symphony-controller-check-fixture"


def command(*arguments):
    result = subprocess.run([DOCKER, *arguments], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError("docker command failed: " + arguments[0] + ": " + result.stderr[:1024])
    return result.stdout.strip()


def inspect_container(identifier):
    rows = json.loads(command("inspect", identifier))
    if len(rows) != 1:
        raise RuntimeError("ambiguous container identity")
    return rows[0]


def exact_container(row, identifier, image, nonce, source, output):
    labels = row["Config"]["Labels"]
    host = row["HostConfig"]
    mounts = {item["Destination"]: item for item in row["Mounts"]}
    if row["Id"] != identifier or row["Image"] != image:
        raise RuntimeError("container identity changed")
    if labels.get("factory.fixture.owner") != OWNER or labels.get("factory.fixture.nonce") != nonce:
        raise RuntimeError("container provenance changed")
    if host["NetworkMode"] != "none" or host["PidMode"] or host["Privileged"] or not host["ReadonlyRootfs"]:
        raise RuntimeError("container isolation changed")
    if host["CapDrop"] != ["ALL"] or "no-new-privileges" not in host["SecurityOpt"]:
        raise RuntimeError("container privilege changed")
    if host["PidsLimit"] != 32 or host["Memory"] != 67_108_864 or host["NanoCpus"] != 500_000_000:
        raise RuntimeError("container resource limits changed")
    if row["Config"]["User"] != "65534:65534" or set(mounts) != {"/source", "/outputs"}:
        raise RuntimeError("container user or mounts changed")
    for destination, path, writable in (("/source", source, False), ("/outputs", output, True)):
        mount = mounts[destination]
        if mount["Type"] != "bind" or pathlib.Path(mount["Source"]) != path or mount["RW"] != writable:
            raise RuntimeError("container mount changed")


def run_case(image, root, source, script, detached=False):
    nonce = uuid.uuid4().hex
    name = "symphony-check-probe-" + nonce
    output = root / nonce
    output.mkdir(mode=0o777)
    output.chmod(0o777)
    identifier = None
    removed = False
    try:
        identifier = command("create", "--pull=never", "--name", name,
            "--label", "factory.fixture.owner=" + OWNER, "--label", "factory.fixture.nonce=" + nonce,
            "--network=none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
            "--pids-limit=32", "--memory=64m", "--cpus=0.5", "--restart=no", "--user=65534:65534",
            "--log-driver=local", "--log-opt=max-size=1m", "--log-opt=max-file=1",
            "--mount", "type=bind,source=" + str(source) + ",target=/source,readonly",
            "--mount", "type=bind,source=" + str(output) + ",target=/outputs",
            "--entrypoint=/bin/sh", image, "-c", script)
        row = inspect_container(identifier)
        exact_container(row, identifier, image, nonce, source, output)
        if row["State"]["Status"] != "created":
            raise RuntimeError("unexpected pre-start state")
        command("start", identifier)
        if detached:
            marker = output / "escape"
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            if not marker.exists():
                raise RuntimeError("detached-child positive control did not run")
            first = marker.read_text()
            time.sleep(0.2)
            if marker.read_text() == first:
                raise RuntimeError("detached child was not continuously active")
            command("kill", "--signal=KILL", identifier)
        exit_code = int(command("wait", identifier))
        terminal = inspect_container(identifier)
        exact_container(terminal, identifier, image, nonce, source, output)
        state = terminal["State"]
        if state["Status"] != "exited" or state["Running"] or state["Pid"] != 0 or state["ExitCode"] != exit_code:
            raise RuntimeError("container termination unproven")
        if detached:
            stopped = marker.read_bytes()
            time.sleep(0.3)
            if marker.read_bytes() != stopped or exit_code != 137:
                raise RuntimeError("detached descendant survived")
        logs = command("logs", identifier)
        evidence = {"container_id": identifier, "name": name, "nonce": nonce, "image_id": image,
            "exit_code": exit_code, "pid": state["Pid"], "status": state["Status"],
            "network_mode": terminal["HostConfig"]["NetworkMode"], "source_read_only": True,
            "detached_child_stopped": detached, "logs": logs[:2048]}
        command("rm", identifier)
        removed = True
        return evidence
    finally:
        if identifier is not None and not removed:
            row = inspect_container(identifier)
            exact_container(row, identifier, image, nonce, source, output)
            if row["State"]["Running"]:
                command("kill", "--signal=KILL", identifier)
                command("wait", identifier)
                row = inspect_container(identifier)
            if row["State"]["Pid"] != 0 or row["State"]["Running"]:
                raise RuntimeError("retain fixture: container stop unproven at " + str(root))
            command("rm", identifier)


def main():
    endpoint = command("context", "inspect", "--format", "{{.Endpoints.docker.Host}}")
    if not endpoint.startswith("unix://"):
        raise RuntimeError("local Docker endpoint required")
    image_rows = json.loads(command("image", "inspect", "curlimages/curl:latest"))
    if len(image_rows) != 1:
        raise RuntimeError("cached image not unique")
    image = image_rows[0]["Id"]
    root = pathlib.Path(tempfile.mkdtemp(prefix="symphony-container-fixture-")).resolve()
    source = root / "source"
    source.mkdir(mode=0o777)
    source.chmod(0o777)
    fixture = source / "fixture.txt"
    fixture.write_text("unchanged source\n")
    fixture.chmod(0o666)
    complete = False
    try:
        readonly = run_case(image, root, source,
            'if printf changed > /source/fixture.txt 2>/outputs/write-error; then exit 41; fi; '
            'test ! -e /var/run/docker.sock || exit 42; '
            'test ! -e /Users || exit 43; '
            'test "$(wc -l < /proc/net/route)" -eq 1 || exit 44; '
            'printf allowed > /outputs/control; cat /outputs/write-error')
        if readonly["exit_code"] != 0 or fixture.read_text() != "unchanged source\n":
            raise RuntimeError("read-only source or namespace control failed")
        detached = run_case(image, root, source,
            "setsid /bin/sh -c 'n=0; while :; do n=$((n+1)); printf \"%s\\n\" \"$n\" > /outputs/escape; sleep 0.05; done' </dev/null >/dev/null 2>&1 & "
            "while [ ! -e /outputs/escape ]; do sleep 0.05; done; printf armed; sleep 30", True)
        print(json.dumps({"fixture_root": str(root), "docker_server_version": command("version", "--format", "{{.Server.Version}}"),
            "cached_image_id": image, "cached_repo_digests": image_rows[0]["RepoDigests"], "read_only_case": readonly,
            "detached_child_case": detached, "production_acceptance": False}, sort_keys=True))
        complete = True
    finally:
        if complete:
            shutil.rmtree(root)
        else:
            print(json.dumps({"retained_fixture_root": str(root), "production_acceptance": False}))


if __name__ == "__main__":
    main()
