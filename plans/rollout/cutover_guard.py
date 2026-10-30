"""Local cutover primitives; the importing release adapter supplies admission checks."""

from contextlib import closing, contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = None
OLD_PID = OLD_START = OLD_FINGERPRINT = None
DB = Path('/Users/cgable/Documents/Codex/factory-state/factory.sqlite')
PLIST = Path('/Users/cgable/Library/LaunchAgents/com.cgable.symphony-factory.plist')
WORKFLOW = Path('/Users/cgable/Repos/symphony/elixir/WORKFLOW.local.md')
BROKER = Path('/Users/cgable/.codex/automations/reconcile-ppl-project-fusion-doc-extract/automation.toml')
MONITOR = Path('/Users/cgable/.codex/automations/monitor-ppl-9881-delivery/automation.toml')
SERVICE = 'gui/505/com.cgable.symphony-factory'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(name):
    assert Path(name).name == name
    path = ROOT / name
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= 32_000_000
    return json.loads(path.read_bytes())


def save(name, value):
    assert Path(name).name == name
    raw = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    fd = os.open(ROOT / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(ROOT, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def save_equal(name, value):
    if (ROOT / name).exists():
        assert load(name) == value
    else:
        save(name, value)


def command(args, timeout=15):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()


def api():
    with urllib.request.urlopen('http://127.0.0.1:4000/api/v1/state', timeout=5) as response:
        raw = response.read(4_194_305)
    assert len(raw) <= 4_194_304
    return json.loads(raw)


def unbound(*_args):
    raise RuntimeError('cutover admission callback is not bound')


readonly = qualified = candidate = configuration = old_binding = native_quiet = protected = restore_check = native_runtime_admit = original_pins = unbound


def identity(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True, timeout=3)
    if result.returncode == 1 and not result.stdout.strip():
        return None
    assert result.returncode == 0 and result.stdout.strip()
    return result.stdout.strip()


def quiet():
    with readonly() as db:
        assert tuple(db.execute("SELECT status,tick_id,lease_expires_at FROM control WHERE scope='assigned-jira-work'").fetchone()) in (('ACTIVE', None, None), ('PAUSED', None, None))
        assert db.execute("SELECT COUNT(*) FROM factory_tasks WHERE status IN ('STARTING','RUNNING','WAITING_FOR_WRITER','WAITING_FOR_BROKER')").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM worker_file_operations WHERE phase='PREPARED' OR io_pending=1").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM controller_checks WHERE phase IN ('PREPARED','RUNNING')").fetchone()[0] == 0
        owners = db.execute('SELECT owner_process_json FROM worker_evidence WHERE owner_stopped_at IS NULL').fetchall()
    for (raw,) in owners:
        assert identity(json.loads(raw)['pid']) is None


def absent():
    process = subprocess.run(['/bin/ps', '-p', str(OLD_PID), '-o', 'pid='], capture_output=True, text=True, timeout=3)
    assert process.returncode == 1 and not process.stdout.strip()
    result = subprocess.run(['/bin/launchctl', 'print', SERVICE], capture_output=True, text=True, timeout=5)
    assert result.returncode != 0
    try:
        api()
    except urllib.error.HTTPError:
        raise AssertionError('an HTTP listener still responds')
    except urllib.error.URLError as error:
        assert isinstance(error.reason, ConnectionRefusedError) or (isinstance(error.reason, OSError) and error.reason.errno == errno.ECONNREFUSED)
    else:
        raise AssertionError('the factory API still responds')


def await_absent():
    deadline = time.monotonic() + 45
    while True:
        try:
            absent()
            return
        except AssertionError:
            assert time.monotonic() < deadline, 'exact issuer/service/API absence is unproven'
            time.sleep(0.1)


@contextmanager
def locked_gate(prefix):
    gate = Path(str(prefix) + '.gate')
    assert gate.is_file() and not gate.is_symlink()
    with gate.open('r+b') as stream:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                assert time.monotonic() < deadline, 'guardian gate busy'
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def stopped_issuer():
    assert identity(OLD_PID) == OLD_START
    return 'T' in command(['/bin/ps', '-p', OLD_PID, '-o', 'stat='])


def stop():
    assert not (ROOT / 'stop-intent.json').exists()
    _value, _manifest, audit = qualified()
    captured = load('captured.json')
    old_binding(True)
    quiet()
    native_quiet()
    protected(audit)
    assert configuration() == captured['configuration'] and sha(PLIST) == captured['plist_sha256']
    assert identity(OLD_PID) == OLD_START
    nonce = secrets.token_hex(32)
    binding = {'nonce': nonce, 'old_pid': int(OLD_PID), 'process_start_identity': OLD_START}
    prefix = ROOT / ('watchdog-' + nonce)
    parent = os.getpid()
    parent_start = identity(parent)
    guardian = subprocess.Popen([sys.executable, '-I', '-B', str(ROOT / 'thaw_guardian.py'), str(ROOT), nonce, OLD_PID, OLD_START, str(parent), parent_start], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    armed_name = 'watchdog-' + nonce + '.armed.json'
    deadline = time.monotonic() + 5
    while not (ROOT / armed_name).exists():
        assert guardian.poll() is None and time.monotonic() < deadline
        time.sleep(0.05)
    armed = load(armed_name)
    assert all(armed.get(key) == value for key, value in binding.items()) and armed['guardian_pid'] == guardian.pid
    assert armed['deadline_monotonic'] - time.monotonic() > 30
    issued_name = 'watchdog-' + nonce + '.bootout-issued.json'
    try:
        with locked_gate(prefix):
            assert not Path(str(prefix) + '.decision.json').exists()
            assert identity(OLD_PID) == OLD_START
            save('stop-intent.json', {**binding, 'attempts': 1, 'plist_sha256': sha(PLIST)})
            os.kill(int(OLD_PID), signal.SIGSTOP)
            freeze_deadline = time.monotonic() + 3
            while not stopped_issuer():
                assert time.monotonic() < freeze_deadline
                time.sleep(0.05)
            quiet()
            native_quiet()
            protected(audit)
            assert configuration() == captured['configuration'] and sha(PLIST) == captured['plist_sha256']
            native_runtime_admit('stop')
            assert identity(OLD_PID) == OLD_START and stopped_issuer()
            save(issued_name, binding)
            command(['/bin/launchctl', 'bootout', SERVICE], timeout=15)
    except BaseException:
        if not (ROOT / issued_name).exists():
            if identity(OLD_PID) == OLD_START and stopped_issuer():
                os.kill(int(OLD_PID), signal.SIGCONT)
            save_equal('watchdog-' + nonce + '.cancelled.json', binding)
        if (ROOT / issued_name).exists() or Path(str(prefix) + '.cancelled.json').exists():
            guardian.wait(timeout=3)
        raise
    try:
        await_absent()
        finish_stop()
    finally:
        guardian.wait(timeout=3)


def logical_digest(db):
    digest = hashlib.sha256()
    for line in db.iterdump():
        digest.update(line.encode())
        digest.update(b'\n')
    return digest.hexdigest()


def finish_stop():
    intent = load('stop-intent.json')
    assert intent['old_pid'] == int(OLD_PID) and intent['process_start_identity'] == OLD_START
    marker = load('watchdog-' + intent['nonce'] + '.bootout-issued.json')
    assert marker == {key: intent[key] for key in ('nonce', 'old_pid', 'process_start_identity')}
    await_absent()
    quiet()
    _value, _manifest, audit = candidate()
    protected(audit)
    backup = ROOT / 'before-cutover.sqlite'
    if not (ROOT / 'stopped.json').exists():
        if not backup.exists():
            fd, path = tempfile.mkstemp(prefix='before-cutover-' + intent['nonce'] + '-', suffix='.sqlite', dir=ROOT)
            os.close(fd)
            staging = Path(path)
            with readonly() as source, closing(sqlite3.connect(staging)) as destination:
                source.backup(destination)
                assert destination.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
                assert logical_digest(source) == logical_digest(destination)
            with staging.open('rb') as stream:
                os.fsync(stream.fileno())
            try:
                os.link(staging, backup)
            except FileExistsError:
                pass
        metadata = backup.lstat()
        assert stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and not backup.is_symlink()
        # Only this closed backup is immutable; the live ledger still needs WAL reads.
        with readonly() as source, closing(sqlite3.connect(backup.as_uri() + '?mode=ro&immutable=1', uri=True)) as verified:
            assert verified.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
            assert logical_digest(source) == logical_digest(verified)
        protected(audit)
        save('stopped.json', {'result': 'EXACT_ISSUER_STOPPED', 'old_pid': OLD_PID, 'old_start': OLD_START, 'nonce': intent['nonce'], 'backup_sha256': sha(backup), 'guard_ledger_row_writes': 0})
    else:
        saved = load('stopped.json')
        assert saved['result'] == 'EXACT_ISSUER_STOPPED' and saved['backup_sha256'] == sha(backup)
    print('EXACT_ISSUER_STOPPED_WITH_READ_ONLY_BACKUP')


def restore_original():
    restore_check()
    captured = load('captured.json')
    assert sha(PLIST) == captured['plist_sha256'] and configuration() == captured['configuration']
    assert not (ROOT / 'restore-intent.json').exists()
    save('restore-intent.json', {'original_plist_sha256': sha(PLIST), 'attempts': 1})
    command(['/bin/launchctl', 'bootstrap', 'gui/505', str(PLIST)], timeout=15)
    deadline = time.monotonic() + 45
    while True:
        try:
            runtime = api()['factory']['control']['runtime_identity']
            break
        except urllib.error.URLError:
            assert time.monotonic() < deadline
            time.sleep(0.1)
    assert runtime['factory_beam_fingerprint'] == OLD_FINGERPRINT
    launchd = command(['/bin/launchctl', 'print', SERVICE])
    assert re.search(r'^\s*pid = ' + re.escape(runtime['os_pid']) + r'$', launchd, re.M)
    protected(load('cutover-audit.json'))
    save('restored.json', {'result': 'ORIGINAL_SERVICE_RESTORED', 'runtime_identity': runtime, 'guard_ledger_row_writes': 0})
