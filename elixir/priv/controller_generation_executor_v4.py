"""One append-only retry of an interrupted, confined read-only CI preview."""
import hashlib
import json
import pathlib
import types

ENGINE_SHA = "7e6c9b72d084431a5db4fbf3263ad4be0f8d8aa5582132a7e365e5c56c788c42"
PENDING_SQL = "SELECT event_key FROM ticket_ci_generation_events WHERE intent_key=? AND event_type IN ('BLOCKED','UNCERTAIN') LIMIT 1"


def require(value):
    if not value:
        raise ValueError("generation_preview_retry_unproven")


def checked(connection, key):
    cursor = connection.execute("SELECT * FROM ticket_ci_generation_events WHERE event_key=?", (key,))
    rows = cursor.fetchall()
    require(len(rows) == 1)
    row = dict(zip([value[0] for value in cursor.description], rows[0]))
    require(hashlib.sha256(row["receipt_json"].encode()).hexdigest() == row["receipt_sha256"])
    return row, json.loads(row["receipt_json"])


def validate_retry(connection, binding):
    retry = binding.get("preview_retry")
    require(binding.get("generation_version") == 4 and isinstance(retry, dict))
    require(set(retry) == set("execution_path original_uncertain_key original_uncertain_sha256 original_started_key original_started_sha256".split()))
    require(retry["execution_path"] == "preview-retry:1" and binding["operation"] in ("GOFMT_DIFF", "GAZELLE_DIFF"))
    uncertain, failure = checked(connection, retry["original_uncertain_key"])
    started, owner = checked(connection, retry["original_started_key"])
    require(uncertain["receipt_sha256"] == retry["original_uncertain_sha256"] and started["receipt_sha256"] == retry["original_started_sha256"])
    require(uncertain["intent_key"] == started["intent_key"] == binding["intent_key"])
    require(uncertain["event_type"] == "UNCERTAIN" and started["event_type"] == "EXECUTION_STARTED" and uncertain["path"] == started["path"] == "")
    original = json.loads(owner["binding_json"])
    require(failure["reason"] == "OWNED_RECEIPT_UNPROVEN" and failure["binding_sha256"] == hashlib.sha256(owner["binding_json"].encode()).hexdigest())
    require(original["started_type"] == "EXECUTION_STARTED" and original["proposal"] is None and original.get("generation_version") in (None, 1))
    for field in ("intent_key", "intent_sha256", "root", "root_device", "root_inode", "request_key", "run_id", "operation", "paths", "toolset"):
        require(original[field] == binding[field])
    pending = connection.execute("SELECT event_key FROM ticket_ci_generation_events WHERE intent_key=? AND event_type IN ('BLOCKED','UNCERTAIN')", (binding["intent_key"],)).fetchall()
    require(pending == [(uncertain["event_key"],)])
    cursor = connection.execute("SELECT event_key FROM ticket_ci_generation_events WHERE intent_key=? AND event_type='EXECUTION_RECEIPT' AND path=?", (binding["intent_key"], retry["execution_path"]))
    receipt_key = cursor.fetchone()
    if binding["started_type"] == "EXECUTION_STARTED":
        require(binding["execution_path"] == retry["execution_path"] and binding["proposal"] is None)
        types = connection.execute("SELECT event_type FROM ticket_ci_generation_events WHERE intent_key=?", (binding["intent_key"],)).fetchall()
        require(not any(row[0].startswith("APPL") for row in types))
    else:
        require(binding["started_type"] == "APPLY_STARTED" and receipt_key is not None)
    if receipt_key is not None:
        row, receipt = checked(connection, receipt_key[0])
        fresh = json.loads(receipt["binding_json"])
        fresh_owner, actual = checked(connection, fresh["started_key"])
        require(row["intent_key"] == fresh_owner["intent_key"] == binding["intent_key"])
        require(fresh_owner["event_type"] == "EXECUTION_STARTED" and fresh_owner["path"] == retry["execution_path"])
        require(actual["binding_json"] == receipt["binding_json"] and actual["helper_pid"] == receipt["helper_pid"])
        require(fresh["preview_retry"] == retry and fresh["generation_version"] == 4 and fresh["started_type"] == "EXECUTION_STARTED")
        require(receipt["kind"] == "CONTROLLER_GENERATION_EXECUTED" and isinstance(receipt["results"], list))


class ResolvedPreviewConnection:
    def __init__(self, connection):
        self.connection = connection

    def execute(self, sql, parameters=()):
        if sql == PENDING_SQL:
            return self.connection.execute("SELECT event_key FROM ticket_ci_generation_events WHERE 0")
        return self.connection.execute(sql, parameters)


def engine():
    path = pathlib.Path(__file__).resolve().with_name("controller_generation_executor_v1.py")
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == ENGINE_SHA)
    module = types.ModuleType("retry_confined_engine")
    module.__file__ = __file__
    exec(compile(raw, str(path), "exec", dont_inherit=True, optimize=0), module.__dict__)
    original = module.ledger_fence

    def fence(connection, binding):
        validate_retry(connection, binding)
        original(ResolvedPreviewConnection(connection), binding)

    module.ledger_fence = fence
    return module


if __name__ == "__main__":
    try:
        engine().main()
    except Exception:
        raise SystemExit(1) from None
