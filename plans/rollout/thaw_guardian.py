"""Bounded thaw for one exact frozen issuer; never restart a service."""
import json
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

def identity(pid):
    value = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True, timeout=3)
    return value.stdout.strip() if value.returncode == 0 else None

def guarded_thaw(pid, expected_start):
    for _attempt in range(3):
        try:
            if identity(pid) != expected_start:
                return 'ISSUER_GONE_OR_CHANGED'
            result = subprocess.run(['/bin/ps','-p',str(pid),'-o','stat='],capture_output=True,text=True,timeout=3)
            if result.returncode == 0 and 'T' in result.stdout and identity(pid) == expected_start:
                os.kill(pid,signal.SIGCONT)
                return 'EXACT_ISSUER_THAWED'
            return 'NOT_STOPPED'
        except (OSError,subprocess.TimeoutExpired):
            time.sleep(0.1)
    return 'IDENTITY_UNPROVEN_MANUAL_AUDIT_REQUIRED'

def marker_result(prefix, binding):
    for suffix in ['.bootout-issued.json','.cancelled.json']:
        path=Path(str(prefix)+suffix)
        if path.is_file() and not path.is_symlink():
            try:
                value=json.loads(path.read_text())
            except (OSError,ValueError):
                return 'MARKER_UNPROVEN_MANUAL_AUDIT_REQUIRED'
            if all(value.get(key)==expected for key,expected in binding.items()):
                return 'BOOTOUT_COMMITTED_NO_THAW_MANUAL_AUDIT_IF_NEEDED' if suffix=='.bootout-issued.json' else 'DISARMED_EXACT_RECEIPT'
            return 'MARKER_BINDING_CHANGED_MANUAL_AUDIT_REQUIRED'
    return None

def finalize(prefix, binding, pid, expected_start):
    with Path(str(prefix)+'.gate').open('a+b') as gate:
        deadline=time.monotonic()+5
        while True:
            try:
                fcntl.flock(gate,fcntl.LOCK_EX|fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic()>=deadline:return 'GATE_BUSY_MANUAL_AUDIT_REQUIRED'
                time.sleep(0.05)
        result=marker_result(prefix,binding)
        if result:return result
        with Path(str(prefix)+'.decision.json').open('x') as stream:
            json.dump(binding,stream)
            stream.flush()
            os.fsync(stream.fileno())
        return guarded_thaw(pid,expected_start)

def run(root, nonce, pid, expected_start, parent, parent_start):
    prefix = root / ('watchdog-' + nonce)
    binding = {'nonce': nonce, 'old_pid': pid, 'process_start_identity': expected_start}
    def save(suffix, data):
        with Path(str(prefix) + suffix).open('x') as stream:
            json.dump({**binding, **data}, stream, sort_keys=True)
    deadline = time.monotonic() + 120
    with Path(str(prefix)+'.gate').open('xb'):
        os.chmod(Path(str(prefix)+'.gate'),0o600)
    save('.armed.json', {'guardian_pid': os.getpid(),'deadline_monotonic':deadline})
    while time.monotonic() < deadline:
        try:
            result=marker_result(prefix,binding)
            if result:
                save('.done.json',{'result':result})
                return
            if identity(pid) != expected_start:
                save('.done.json',{'result':'ISSUER_GONE_OR_CHANGED'})
                return
            if identity(parent) != parent_start:
                break
        except (OSError,ValueError,subprocess.TimeoutExpired):
            pass
        time.sleep(0.25)
    save('.done.json',{'result':finalize(prefix,binding,pid,expected_start)})

if __name__ == '__main__':
    run(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), sys.argv[6])
