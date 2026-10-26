defmodule SymphonyElixir.FactoryTicketCheckoutBudgetTest do
  use ExUnit.Case, async: true

  test "initial checkout can exceed thirty seconds but still terminates at its bounded deadline" do
    program = Application.app_dir(:symphony_elixir, "priv/ticket_checkout_executor.py")

    script = """
    import importlib.util, json, sys
    from unittest.mock import patch
    spec = importlib.util.spec_from_file_location('checkout', sys.argv[1])
    executor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(executor)

    class Stream:
        def close(self): pass
        def fileno(self): return 1

    class Child:
        pid = 999999
        stdout = Stream()
        def __init__(self): self.finished = False
        def poll(self): return 0 if self.finished else None
        def wait(self, timeout):
            self.finished = True
            return 0

    class Publisher:
        def publish(self, *args): pass

    def run(elapsed):
        with patch.object(executor, 'authorize', return_value=Child()), \\
             patch.object(executor.time, 'monotonic', side_effect=[0, elapsed, elapsed + 1]), \\
             patch.object(executor.select, 'select', return_value=([Child.stdout], [], [])), \\
             patch.object(executor.os, 'read', return_value=b''), \\
             patch.object(executor.os, 'killpg') as kill:
            raw = executor.execute({'execution_json': '{}'}, {'intent_json': '{}', 'invocation': 'fixture'}, Publisher(), None)
            return json.loads(raw)['timed_out'], kill.call_count

    assert run(30) == (False, 0), 'ordinary large checkout killed prematurely'
    assert run(601) == (True, 1), 'checkout exceeded its bounded budget'
    """

    assert {output, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, program], stderr_to_stdout: true)
    assert output == ""
  end
end
