defmodule SymphonyElixir.FactoryTicketPushV3BoundaryTest do
  use ExUnit.Case, async: true

  test "loaded companion and retained-history code are the exact hashed source, not timestamp-valid bytecode" do
    helper = Path.expand("../../priv/ticket_push_executor_v3.py", __DIR__)

    script = ~S"""
    import hashlib, importlib.util, importlib._bootstrap_external, pathlib, sys, tempfile, types
    def digest(raw): return hashlib.sha256(raw).hexdigest()
    with tempfile.TemporaryDirectory(prefix="push-v3-cache-") as root:
      root = pathlib.Path(root).resolve()
      path = root / "ticket_push_executor_v3.py"
      path.write_bytes(pathlib.Path(sys.argv[1]).read_bytes())
      helper = types.ModuleType("helper")
      helper.__file__ = str(path)
      exec(compile(path.read_bytes(), str(path), "exec"), helper.__dict__)
      def poison(name, verified, altered):
        source = root / name
        source.write_text(verified)
        cache = pathlib.Path(importlib.util.cache_from_source(str(source)))
        cache.parent.mkdir(exist_ok=True)
        code = compile(altered, str(source), "exec")
        cache.write_bytes(importlib._bootstrap_external._code_to_timestamp_pyc(
          code, int(source.stat().st_mtime), source.stat().st_size))
        return source
      source = poison("worker_file_companion.py", "VALUE='verified-source'\n", "VALUE='poisoned-cache'\n")
      execution = {"helper_sha256":digest(path.read_bytes()), "companion_path":str(source), "companion_sha256":digest(source.read_bytes())}
      assert helper.companion(execution).VALUE == "verified-source"
      source = poison("ticket_push_recovery_executor.py",
        "def worker_history(*args): raise RuntimeError('verified-source')\n",
        "def worker_history(*args): raise RuntimeError('poisoned-cache')\n")
      execution = {"history_program_path":str(source), "history_program_sha256":digest(source.read_bytes())}
      try:
        helper.retained_history(None, execution, {}, {})
        raise AssertionError("expected authentic validator call")
      except RuntimeError as error:
        assert str(error) == "verified-source"
    print("hashed_source_cases=2; poisoned_bytecode_ignored=2")
    """

    assert {"hashed_source_cases=2; poisoned_bytecode_ignored=2\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, helper], stderr_to_stdout: true)
  end

  test "only fixed preissuance denials publish rejection; arbitrary and possibly started errors stay unknown" do
    helper = Path.expand("../../priv/ticket_push_executor_v3.py", __DIR__)
    python = System.find_executable("python3") || flunk("python3 required")

    script = ~S"""
    import importlib.util, json, subprocess, sys, types
    spec = importlib.util.spec_from_file_location("helper", sys.argv[1])
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    published = []
    companion = types.SimpleNamespace(publish=lambda spool, name, raw: published.append((name, raw)))
    execution = {"intent_json":"{}", "invocation":"a" * 64}
    value = {"execution_json":json.dumps(execution), "helper_pid":0}
    children = []
    cases = [
      (ValueError("run_changed"), False, False, True),
      (RuntimeError("run_changed"), False, False, False),
      (ValueError("arbitrary-secret-error"), False, False, False),
      (ValueError("run_changed"), True, False, False),
      (ValueError("run_changed"), True, True, False)]
    for error, started, child, reject in cases:
      published.clear()
      def authorize(value, execution, binding, module, spool, owned):
        owned["issuance_started"] = started
        if child:
          owned["child"] = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
          children.append(owned["child"])
        raise error
      helper.authorize = authorize
      try:
        raw = helper.execute(value, execution, companion, None)
        assert reject
        receipt = json.loads(raw)
        assert receipt["kind"] == "PREISSUANCE_REJECTED"
        assert receipt["reason"] == "run_changed" and receipt["child_pid"] is None
        assert len(published) == 1 and published[0][0].endswith(".push-rejection")
      except Exception as actual:
        assert not reject and actual is error
        assert published == []
    assert all(child.poll() is not None for child in children)
    print("boundary_cases=5; owned_children_reaped=1")
    """

    assert {"boundary_cases=5; owned_children_reaped=1\n", 0} =
             System.cmd(python, ["-c", script, helper], stderr_to_stdout: true)
  end
end
