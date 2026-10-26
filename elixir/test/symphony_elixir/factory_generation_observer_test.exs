defmodule SymphonyElixir.FactoryGenerationObserverTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketCiGenerationIO

  setup do
    root = Path.join(System.tmp_dir!(), "generation-observer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "source"))
    File.mkdir_p!(Path.join(root, "spool"))
    File.chmod!(Path.join(root, "spool"), 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    stat = File.stat!(Path.join(root, "spool"))
    %{root: root, transport: %{"root" => Path.join(root, "source"), "spool" => Path.join(root, "spool"), "spool_device" => stat.major_device, "spool_inode" => stat.inode}}
  end

  test "observer retains its real owned child status and bounded output receipt", c do
    File.write!(Path.join(c.transport["root"], "job.go"), "package job\n")
    assert {:ok, observed} = TicketCiGenerationIO.observe(c.transport, ["job.go"])
    receipt = observed["owned_observer_receipt"]
    assert receipt["termination"] == %{"kind" => "exited", "code" => 0}
    assert is_integer(receipt["pid"]) and receipt["pid"] > 0
    assert Jason.decode!(File.read!(Path.join(c.transport["spool"], receipt["invocation"] <> ".generation-observation"))) == receipt
  end

  @tag timeout: 15_000
  test "ordinary observer attests absent BUILD only and refuses absent Go or symlink input", c do
    File.mkdir_p!(Path.join(c.transport["root"], "pkg"))
    assert {:ok, observed} = TicketCiGenerationIO.observe(c.transport, ["pkg/BUILD"], 2)
    assert [%{"path" => "pkg/BUILD", "sha256" => "ABSENT", "bytes_base64" => "", "absent" => true}] = Enum.map(observed["files"], &Map.take(&1, ~w(path sha256 bytes_base64 absent)))
    assert {:error, :controller_generation_observer_unproven} = TicketCiGenerationIO.observe(c.transport, ["pkg/absent.go"], 2)
    File.ln_s!(Path.join(c.root, "outside"), Path.join(c.transport["root"], "pkg/BUILD"))
    assert {:error, :controller_generation_observer_unproven} = TicketCiGenerationIO.observe(c.transport, ["pkg/BUILD"], 2)
  end

  @tag timeout: 15_000
  test "an observer ignoring its own alarm is killed and actually reaped by the outer absolute deadline", c do
    observer = Path.join(c.root, "hang.py")
    File.write!(observer, "import signal,time\nsignal.signal(signal.SIGALRM,signal.SIG_IGN)\nsignal.alarm(1)\nwhile True: time.sleep(0.01)\n")
    source_path = Path.expand("../../lib/symphony_elixir/factory/ticket_ci_generation_io.ex", __DIR__)
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    source = File.read!(source_path)

    source =
      source
      |> String.replace("defmodule SymphonyElixir.Factory.TicketCiGenerationIO do", "defmodule #{inspect(module)} do")
      |> String.replace(~s|@observer Path.expand("../../../priv/controller_generation_io_v1.py", __DIR__)|, "@observer #{inspect(observer)}")
      |> String.replace(~s|Application.app_dir(:symphony_elixir, "priv/controller_generation_io_v1.py")|, inspect(observer))

    Code.compile_string(source, source_path)
    started = System.monotonic_time(:millisecond)
    assert {:error, :controller_generation_observer_unproven} = apply(module, :observe, [c.transport, ["job.go"]])
    assert System.monotonic_time(:millisecond) - started < 10_000
    [name] = File.ls!(c.transport["spool"])
    receipt = Jason.decode!(File.read!(Path.join(c.transport["spool"], name)))
    assert receipt["termination"]["kind"] == "killed_and_reaped"
    assert receipt["termination"]["exit_status"] != 0
    {_output, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(receipt["pid"])], stderr_to_stdout: true)
    assert status != 0
  end
end
