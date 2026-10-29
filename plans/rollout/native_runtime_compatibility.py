"""Read-only target-specific native-history admission for supported rollout entrypoints."""

import json
import math
import os
from pathlib import Path
import sqlite3
import hashlib
import unicodedata


class AdmissionRefused(AssertionError):
    """A target cannot safely consume the selected ledger's native history."""


NATIVE_QUIET_SCRIPT = '''
[raw] = System.argv()
%{"workflow" => workflow, "workers" => workers} = Jason.decode!(raw)
:ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow)
for %{"thread_id" => thread, "binding_json" => raw_binding, "binding_sha256" => expected} <- workers do
  true = Base.encode16(:crypto.hash(:sha256, raw_binding), case: :lower) == expected
  binding = Jason.decode!(raw_binding)
  route = if Map.has_key?(binding, "binding_version") or Map.has_key?(binding, "native_runtime") do
    2 = binding["binding_version"]
    {:ok, route} = SymphonyElixir.Factory.NativeRuntimeRoute.restore_origin(binding["native_runtime"])
    route
  end
  {home, database} = if route do
    {:ok, _} = SymphonyElixir.Factory.NativeRuntimeRoute.storage(route)
    {route.codex_home.path, Path.join(route.sqlite_home.path, "queue_1.sqlite")}
  else
    {"/Users/cgable/.codex", "/Users/cgable/.codex/queue_1.sqlite"}
  end
  {:ok, queue} = SymphonyElixir.Factory.NativeQueueReadback.read(database, thread)
  {:ok, lock} = SymphonyElixir.Factory.NativeQueueReadback.writer_unlocked(home, thread)
  true = queue["thread_id"] == thread and queue["item_count"] == 0
  true = lock["status"] in ["absent", "unlocked"]
  if route, do: ({:ok, _} = SymphonyElixir.Factory.NativeRuntimeRoute.storage(route))
end
IO.puts("NATIVE_SOURCE_QUIET")
'''


def quietness_payload(rows, workflow, manifest):
    formats = validate_manifest(manifest)
    workers = []
    seen = set()
    for thread, raw, digest in rows:
        binding = parse_binding(raw, formats)
        if type(thread) is not str or hashlib.sha256(raw.encode('utf-8')).hexdigest() != digest:
            raise AdmissionRefused('native_runtime_history_unreadable')
        origin = json.dumps(binding['native_runtime'], sort_keys=True, separators=(',', ':'), ensure_ascii=False) if 'native_runtime' in binding else None
        pair = (thread, origin)
        if pair in seen:
            continue
        seen.add(pair)
        workers.append({'thread_id': thread, 'binding_json': raw, 'binding_sha256': digest})
    return json.dumps({'workflow': str(workflow), 'workers': workers}, separators=(',', ':'), ensure_ascii=False), len(workers)


def validate_manifest(manifest):
    legacy = {'worker_binding_versions': [1], 'completion_receipt_versions': [1]}
    if type(manifest) is not dict:
        raise AdmissionRefused('unsupported_native_runtime_formats')
    value = manifest.get('native_runtime_formats', legacy)
    if (type(value) is not dict or set(value) != set(legacy) or
            any(type(value[key]) is not list or value[key] not in ([1], [1, 2]) or
                any(type(version) is not int for version in value[key]) for key in legacy)):
        raise AdmissionRefused('unsupported_native_runtime_formats')
    return {key: list(value[key]) for key in legacy}


def _reject_constant(_value):
    raise ValueError('non-finite JSON constant')


def _finite_float(raw):
    value = float(raw)
    if not math.isfinite(value):
        raise ValueError('non-finite JSON number')
    return value


def _parse_json(raw):
    if type(raw) is not str:
        raise AdmissionRefused('unsupported_native_runtime_history')
    try:
        value = json.loads(raw, parse_constant=_reject_constant, parse_float=_finite_float)
        json.dumps(value, ensure_ascii=False).encode('utf-8')
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise AdmissionRefused('unsupported_native_runtime_history') from None
    return value


def _origin_format(origin):
    if type(origin) is not dict or set(origin) != {'version', 'codex_home', 'sqlite_home'} or type(origin['version']) is not int or origin['version'] != 2:
        return False
    for name in ('codex_home', 'sqlite_home'):
        directory = origin[name]
        if type(directory) is not dict or set(directory) != {'path', 'device', 'inode', 'uid'}:
            return False
        path, device, inode, uid = (directory[key] for key in ('path', 'device', 'inode', 'uid'))
        if (type(path) is not str or not path.startswith('/') or path.startswith('//') or os.path.normpath(path) != path or
                any(unicodedata.category(character) == 'Cc' for character in path) or
                type(device) is not list or len(device) != 2 or any(type(item) is not int or item < 0 for item in device) or
                type(inode) is not int or inode <= 0 or type(uid) is not int or uid < 0):
            return False
        try:
            path.encode('utf-8')
        except UnicodeError:
            return False
    return True


def parse_binding(raw, formats):
    value = _parse_json(raw)
    if type(value) is not dict:
        raise AdmissionRefused('unsupported_native_runtime_history')
    if 'binding_version' in value or 'native_runtime' in value:
        if not (2 in formats['worker_binding_versions'] and type(value.get('binding_version')) is int and value['binding_version'] == 2 and _origin_format(value.get('native_runtime'))):
            raise AdmissionRefused('unsupported_native_runtime_history')
    return value


def _receipt_format(raw, formats):
    value = _parse_json(raw)
    if type(value) is not dict or type(value.get('version')) is not int:
        return False
    if value.get('kind') == 'NATIVE_COMPLETION_RECEIPT_V1' and value['version'] == 1:
        return 'native_runtime' not in value and 'native_runtime_sha256' not in value
    if value.get('kind') == 'NATIVE_COMPLETION_RECEIPT_V2' and value['version'] == 2 and 2 in formats['completion_receipt_versions'] and _origin_format(value.get('native_runtime')):
        digest = hashlib.sha256(json.dumps(value['native_runtime'], sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest()
        return value.get('native_runtime_sha256') == digest
    return False


def check_database(database, manifest):
    formats = validate_manifest(manifest)
    try:
        database = os.fspath(database)
    except TypeError:
        raise AdmissionRefused('native_runtime_history_unreadable') from None
    if database in (':memory:',):
        return True
    if type(database) is not str or not database or database.startswith('file:'):
        raise AdmissionRefused('native_runtime_history_unreadable')
    try:
        path = Path(database)
        try:
            path.lstat()
        except FileNotFoundError:
            return True
        connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)
    except (OSError, ValueError, TypeError, sqlite3.Error):
        raise AdmissionRefused('native_runtime_history_unreadable') from None
    try:
        connection.execute('PRAGMA query_only=ON')
        connection.execute('BEGIN')
        objects = dict(connection.execute("SELECT lower(name),type FROM sqlite_master WHERE lower(name) IN ('worker_evidence','events')"))
        tables = (
            ('worker_evidence', {'binding_json'}, 'SELECT binding_json FROM worker_evidence', False),
            ('events', {'event_type', 'payload_json'}, "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'", True),
        )
        for table, required, query, receipt in tables:
            if table not in objects:
                continue
            if objects[table] != 'table' or not required <= {row[1] for row in connection.execute('PRAGMA table_info(' + table + ')')}:
                raise AdmissionRefused('native_runtime_history_unreadable')
            for (raw,) in connection.execute(query):
                if receipt and not _receipt_format(raw, formats):
                    raise AdmissionRefused('unsupported_native_runtime_history')
                if not receipt:
                    parse_binding(raw, formats)
        return True
    except sqlite3.Error:
        raise AdmissionRefused('native_runtime_history_unreadable') from None
    finally:
        try:
            if connection.total_changes != 0:
                raise AdmissionRefused('native_runtime_admission_mutated')
        finally:
            connection.close()
