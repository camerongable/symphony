defmodule SymphonyElixir.FactoryDesktopMrHandshakeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias SymphonyElixir.Factory.DesktopMrHandshake

  defp owner do
    %{"source" => "codex_app/read_thread", "observed_at" => DateTime.to_iso8601(DateTime.utc_now()), "response" => %{"schemaVersion" => 1, "thread" => %{"id" => "controller"}}}
  end

  defp frame, do: %{"request_key" => "request", "source_thread_id" => "broker", "owner" => owner()}

  test "bounded observation handoff emits only correlation and preserves raw owner input" do
    frame = frame()
    request = %{"request_key" => "request", "existing_thread_id" => "controller"}

    output =
      capture_io(Jason.encode!(frame) <> "\n", fn ->
        assert {:ok, raw} = DesktopMrHandshake.observe(request, "broker")
        assert raw == frame["owner"]
      end)

    assert Jason.decode!(output) == %{"status" => "OWNER_OBSERVATION_REQUIRED", "request_key" => "request", "controller_thread_id" => "controller", "source_thread_id" => "broker"}
  end

  test "owner frames reject malformed, foreign, oversized or extra authority inputs" do
    for input <- [
          "not-json",
          "[]",
          String.duplicate("x", 65_537),
          Jason.encode!(Map.put(frame(), "request_key", "foreign")),
          Jason.encode!(Map.put(frame(), "source_thread_id", "foreign")),
          Jason.encode!(Map.put(frame(), "authorization", %{}))
        ] do
      assert {:error, :mr_owner_input_invalid} = DesktopMrHandshake.parse(input, "request", "broker")
    end
  end

  test "bounded stdin rejects EOF and oversized input without accepting a partial observation" do
    request = %{"request_key" => "request", "existing_thread_id" => "controller"}
    capture_io("", fn -> assert {:error, :mr_owner_input_eof} = DesktopMrHandshake.observe(request, "broker") end)

    capture_io(String.duplicate("x", 65_537), fn ->
      assert {:error, :mr_owner_input_too_large} = DesktopMrHandshake.observe(request, "broker")
    end)
  end

  test "real CLI stdin transport emits readiness before input and terminates on timeout" do
    for mode <- [:reply, :timeout] do
      paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

      expression =
        "result = SymphonyElixir.Factory.DesktopMrHandshake.observe(%{\"request_key\" => \"request\", \"existing_thread_id\" => \"controller\"}, \"broker\", 500); IO.puts(Jason.encode!(%{result: inspect(result)}))"

      port = Port.open({:spawn_executable, System.find_executable("elixir")}, [:binary, :exit_status, args: ["--erl", "+S 2:2"] ++ paths ++ ["-e", expression]])

      try do
        {ready, pending} = line(port, "")
        assert Jason.decode!(ready)["status"] == "OWNER_OBSERVATION_REQUIRED"
        assert pending == ""
        if mode == :reply, do: Port.command(port, Jason.encode!(frame()) <> "\n")
        {result, _rest} = line(port, pending)
        outcome = Jason.decode!(result)["result"]
        if mode == :reply, do: assert(outcome =~ "{:ok,"), else: assert(outcome == "{:error, :mr_owner_input_timeout}")
        assert_receive {^port, {:exit_status, 0}}, 5_000
      after
        if :erlang.port_info(port) != :undefined, do: Port.close(port)
      end
    end
  end

  test "unavailable or nonresponding stdin releases its reader without accepting owner evidence" do
    request = %{"request_key" => "request", "existing_thread_id" => "controller"}
    owner = self()
    original = Process.group_leader()

    for {mode, error} <- [unavailable: :mr_owner_input_unavailable, timeout: :mr_owner_input_timeout] do
      device = spawn(fn -> input_device(owner, mode) end)

      try do
        Process.group_leader(self(), device)
        assert {:error, ^error} = DesktopMrHandshake.observe(request, "broker", 100)
        assert_receive {:reader_started, reader}
        monitor = Process.monitor(reader)
        assert_receive {:DOWN, ^monitor, :process, ^reader, _reason}
      after
        Process.group_leader(self(), original)
        Process.exit(device, :kill)
      end
    end
  end

  defp input_device(owner, mode) do
    receive do
      {:io_request, from, reply, {:get_chars, _encoding, _prompt, _count}} ->
        send(owner, {:reader_started, from})
        if mode == :unavailable, do: send(from, {:io_reply, reply, {:error, :eio}})
        input_device(owner, mode)

      {:io_request, from, reply, _output} ->
        send(from, {:io_reply, reply, :ok})
        input_device(owner, mode)
    end
  end

  defp line(port, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        {line, rest}

      [_pending] ->
        receive do
          {^port, {:data, bytes}} -> line(port, buffer <> bytes)
          {^port, {:exit_status, status}} -> flunk("stdin fixture exited before response: #{status}")
        after
          10_000 -> flunk("stdin fixture response timed out")
        end
    end
  end
end
