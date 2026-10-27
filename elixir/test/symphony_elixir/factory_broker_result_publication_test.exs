defmodule SymphonyElixir.FactoryBrokerResultPublicationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.{BrokerRuntime, Store}

  setup do
    directory = Path.join(System.tmp_dir!(), "broker-publication-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory} = SymphonyElixir.PathSafety.canonicalize(directory)
    database = Path.join(directory, "factory.sqlite")
    store = start_supervised!({Store, database: database})
    factory = %Schema.Factory{database: database}
    {:ok, root} = BrokerRuntime.root(database)
    File.mkdir_p!(root)
    trace = Path.join(directory, "execution-count")

    executor = fn _args, _store, _factory ->
      {output, 0} = System.cmd("python3", [Path.expand("../support/broker_result_executor.py", __DIR__), trace])
      {:ok, Jason.decode!(output)}
    end

    %{directory: directory, root: root, store: store, factory: factory, trace: trace, executor: executor}
  end

  test "successful result is published after a filesystem obstruction clears without executing again", ctx do
    id = String.duplicate("a", 32)
    response = Path.join(ctx.root, id <> ".response")
    pending(ctx, id)

    executor = fn _args, _store, _factory ->
      {output, 0} = System.cmd("python3", [Path.expand("../support/broker_result_executor.py", __DIR__), ctx.trace, response])
      {:ok, Jason.decode!(output)}
    end

    server = start_broker(%{ctx | executor: executor})
    :sys.get_state(server)
    assert File.read!(ctx.trace) == "executed\n"
    assert File.dir?(response)
    File.rmdir!(response)
    send(server, :poll)
    :sys.get_state(server)
    assert File.read!(response) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.read!(ctx.trace) == "executed\n"
    assert File.exists?(Path.join(ctx.root, id <> ".finished"))
  end

  test "restart republishes a committed known result and fences a reintroduced pending ID", ctx do
    id = blocked_result(ctx, "b")
    known = File.read!(Path.join(ctx.root, id <> ".known"))
    :ok = stop_supervised(BrokerRuntime)
    File.rmdir!(Path.join(ctx.root, id <> ".response"))
    pending(ctx, id)
    server = start_broker(ctx)
    :sys.get_state(server)
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.read!(Path.join(ctx.root, id <> ".known")) == known
    assert File.exists?(Path.join(ctx.root, id <> ".duplicate"))
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "an obstructed known-result commit retains its result in the existing broker owner", ctx do
    id = String.duplicate("4", 32)
    known = Path.join(ctx.root, id <> ".known")
    pending(ctx, id)
    server = start_broker(%{ctx | executor: obstructing_executor(ctx, known)})
    :sys.get_state(server)
    assert File.dir?(known)
    refute File.exists?(Path.join(ctx.root, id <> ".response"))
    File.rmdir!(known)
    send(server, :poll)
    :sys.get_state(server)
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "publication after request expiry returns only the original historical result", ctx do
    id = String.duplicate("5", 32)
    pending(ctx, id, System.system_time(:millisecond) + 200)
    server = start_broker(%{ctx | executor: obstructing_executor(ctx, Path.join(ctx.root, id <> ".response"))})
    :sys.get_state(server)
    running = Path.join(ctx.root, id <> ".running")
    request = File.read!(running)
    :ok = stop_supervised(BrokerRuntime)
    expiry = Jason.decode!(request)["expires_at"]
    Process.sleep(max(expiry - System.system_time(:millisecond) + 25, 0))
    assert expiry < System.system_time(:millisecond)
    File.rmdir!(Path.join(ctx.root, id <> ".response"))
    server = start_broker(ctx)
    :sys.get_state(server)
    assert File.read!(Path.join(ctx.root, id <> ".finished")) == request
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "unresolved publication backlog stops new execution and polling rotates past bad records", ctx do
    for number <- 1..16 do
      id = number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
      File.write!(Path.join(ctx.root, id <> ".running"), "{}")
      File.write!(Path.join(ctx.root, id <> ".known"), "null")
    end

    id = String.duplicate("6", 32)
    pending(ctx, id)
    server = start_broker(ctx)
    :sys.get_state(server)
    refute File.exists?(ctx.trace)
    assert File.exists?(Path.join(ctx.root, id <> ".pending"))
    last = String.pad_leading("10", 32, "0")
    File.rm!(Path.join(ctx.root, last <> ".known"))

    for _ <- 1..16 do
      send(server, :poll)
      :sys.get_state(server)
    end

    assert File.read!(ctx.trace) == "executed\n"
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
  end

  test "a published response survives failed finished bookkeeping and restart", ctx do
    id = String.duplicate("c", 32)
    finished = Path.join(ctx.root, id <> ".finished")
    pending(ctx, id)
    server = start_broker(%{ctx | executor: obstructing_executor(ctx, finished)})
    :sys.get_state(server)
    response = File.read!(Path.join(ctx.root, id <> ".response"))
    assert File.dir?(finished)
    :ok = stop_supervised(BrokerRuntime)
    File.rmdir!(finished)
    server = start_broker(ctx)
    :sys.get_state(server)
    assert File.read!(Path.join(ctx.root, id <> ".response")) == response
    assert File.regular?(finished)
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "publication reads the same request after its finished bookkeeping rename", ctx do
    id = String.duplicate("7", 32)
    pending(ctx, id)

    executor = fn _args, _store, _factory ->
      {output, 0} = System.cmd("python3", [Path.expand("../support/broker_result_executor.py", __DIR__), ctx.trace, Path.join(ctx.root, id <> ".running"), "finish"])
      {:ok, Jason.decode!(output)}
    end

    server = start_broker(%{ctx | executor: executor})
    :sys.get_state(server)
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.read!(ctx.trace) == "executed\n"
    assert File.regular?(Path.join(ctx.root, id <> ".finished"))
  end

  test "a crash before the known result commits stays uncertain and never executes again", ctx do
    id = String.duplicate("d", 32)
    pending(ctx, id)
    caller = self()

    executor = fn args, store, factory ->
      result = ctx.executor.(args, store, factory)
      send(caller, :external_effect_complete)

      receive do
        :release -> result
      end
    end

    server = start_broker(%{ctx | executor: executor})
    assert_receive :external_effect_complete, 2000
    File.write!(Path.join(ctx.root, id <> ".known.writing.partial"), "unfinished")
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, :killed}
    stop_supervised(BrokerRuntime)
    server = start_broker(ctx)
    :sys.get_state(server)
    assert Jason.decode!(File.read!(Path.join(ctx.root, id <> ".response"))) == %{"error" => ":broker_runtime_outcome_uncertain"}
    refute File.exists?(Path.join(ctx.root, id <> ".known"))
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "a conflicting response is never overwritten or treated as the committed known result", ctx do
    id = blocked_result(ctx, "e")
    :ok = stop_supervised(BrokerRuntime)
    response = Path.join(ctx.root, id <> ".response")
    File.rmdir!(response)
    File.write!(response, ~s({"ok":"a different result"}))
    server = start_broker(ctx)
    :sys.get_state(server)
    assert File.read!(response) == ~s({"ok":"a different result"})
    assert File.exists?(Path.join(ctx.root, id <> ".running"))
    refute File.exists?(Path.join(ctx.root, id <> ".finished"))
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "the public caller rejects a response that disagrees with the executed result", ctx do
    workflow = Path.join(ctx.directory, "WORKFLOW.md")
    File.write!(workflow, "---\nfactory:\n  database: #{ctx.factory.database}\n---\nSynthetic broker.\n")

    executor = fn _args, _store, _factory ->
      [running] = Path.wildcard(Path.join(ctx.root, "*.running"))
      response = String.replace_suffix(running, ".running", ".response")
      {output, 0} = System.cmd("python3", [Path.expand("../support/broker_result_executor.py", __DIR__), ctx.trace, response, "conflict"])
      {:ok, Jason.decode!(output)}
    end

    start_broker(%{ctx | executor: executor})
    assert {:error, :broker_runtime_response_conflict} = BrokerRuntime.call(["claim", "request", "--workflow", workflow])
    assert File.read!(ctx.trace) == "executed\n"
  end

  @tag :exclusive_publication
  test "an external contender cannot replace known or response publication with its own bytes", ctx do
    workflow = Path.join(ctx.directory, "WORKFLOW.md")
    File.write!(workflow, "---\nfactory:\n  database: #{ctx.factory.database}\n---\nSynthetic broker.\n")

    for phase <- ~w(known response) do
      marker = Path.join(ctx.directory, "contender-#{phase}")

      executor = fn args, store, factory ->
        ctx.executor.(args, store, factory)
        running = Enum.find(Path.wildcard(Path.join(ctx.root, "*.running")), &(Jason.decode!(File.read!(&1))["args"] == args))
        target = String.replace_suffix(running, ".running", "." <> phase)
        Task.start(fn -> System.cmd("python3", [Path.expand("../support/broker_result_contender.py", __DIR__), target, marker]) end)
        wait_for(marker <> ".ready")
        {:ok, String.duplicate("x", 2_000_000)}
      end

      server = start_broker(%{ctx | executor: executor})
      assert {:error, :broker_runtime_response_conflict} = BrokerRuntime.call(["claim", phase, "--workflow", workflow])
      :sys.get_state(server)
      wait_for(marker)
      target = File.read!(marker)
      assert File.read!(target) == ~s({"ok":"racing conflict"})
      assert :ok = stop_supervised(BrokerRuntime)
    end

    assert File.read!(ctx.trace) == "executed\nexecuted\n"
  end

  @tag :exclusive_publication
  test "the public caller waits for a complete transient hard-link publication", ctx do
    workflow = Path.join(ctx.directory, "WORKFLOW.md")
    File.write!(workflow, "---\nfactory:\n  database: #{ctx.factory.database}\n---\nSynthetic broker.\n")

    executor = fn _args, _store, _factory ->
      [running] = Path.wildcard(Path.join(ctx.root, "*.running"))
      {output, 0} = System.cmd("python3", [Path.expand("../support/broker_result_executor.py", __DIR__), ctx.trace, running, "linked"])
      {:ok, Jason.decode!(output)}
    end

    start_broker(%{ctx | executor: executor})
    caller = Task.async(fn -> BrokerRuntime.call(["claim", "request", "--workflow", workflow]) end)
    wait_for(ctx.trace <> ".ready")
    assert Task.yield(caller, 150) == nil
    File.write!(ctx.trace <> ".release", "release")
    assert {:ok, %{"receipt" => "external-complete"}} = Task.await(caller, 5000)
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "restart settles exact committed link residues without executing again", ctx do
    id = String.duplicate("8", 32)
    finished = Path.join(ctx.root, id <> ".finished")
    pending(ctx, id)
    server = start_broker(%{ctx | executor: obstructing_executor(ctx, finished)})
    :sys.get_state(server)
    :ok = stop_supervised(BrokerRuntime)

    for phase <- ~w(known response) do
      final = Path.join(ctx.root, id <> "." <> phase)
      File.ln!(final, final <> ".writing." <> String.duplicate("a", 16))
    end

    File.rmdir!(finished)
    server = start_broker(ctx)
    :sys.get_state(server)
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.regular?(finished)
    assert Path.wildcard(Path.join(ctx.root, "*.writing.*")) == []
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "foreign multiple and invalid link residues remain denied without unlinking", ctx do
    id = blocked_result(ctx, "9")
    :ok = stop_supervised(BrokerRuntime)
    path = Path.join(ctx.root, id <> ".known")
    original = File.read!(path)
    File.rmdir!(Path.join(ctx.root, id <> ".response"))
    first = path <> ".writing." <> String.duplicate("a", 16)
    second = path <> ".writing." <> String.duplicate("b", 16)
    foreign = Path.join(ctx.directory, "foreign-alias")

    for kind <- [:foreign, :multiple, :symlink, :invalid] do
      case kind do
        :foreign ->
          File.ln!(path, foreign)
          File.write!(first, "foreign bytes")

        :multiple ->
          File.ln!(path, first)
          File.ln!(path, second)

        :symlink ->
          File.ln!(path, foreign)
          File.ln_s!(path, first)

        :invalid ->
          File.write!(path, "null")
          File.ln!(path, first)
      end

      server = start_broker(ctx)
      :sys.get_state(server)
      assert File.exists?(first)
      if kind == :multiple, do: assert(File.exists?(second))
      refute File.exists?(Path.join(ctx.root, id <> ".response"))
      assert File.read!(ctx.trace) == "executed\n"
      :ok = stop_supervised(BrokerRuntime)
      Enum.each([first, second, foreign], &File.rm/1)
      File.write!(path, original)
    end
  end

  test "a crash at the synced exclusive known link recovers its exact bytes after reopen", ctx do
    id = String.duplicate("0", 32)
    pending(ctx, id)
    owner = self()

    edge = fn ->
      send(owner, {:known_link_committed, self()})

      receive do
        :release -> :ok
      end
    end

    server = start_broker(Map.put(ctx, :after_known_link, edge))
    assert_receive {:known_link_committed, ^server}, 2000
    known = Path.join(ctx.root, id <> ".known")
    original = File.read!(known)
    assert File.stat!(known).links == 2
    assert File.read!(ctx.trace) == "executed\n"
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, :killed}
    stop_supervised(BrokerRuntime)
    server = start_broker(ctx)
    :sys.get_state(server)
    assert File.read!(known) == original
    assert File.stat!(known).links == 1
    assert Path.wildcard(Path.join(ctx.root, "*.writing.*")) == []
    assert File.read!(Path.join(ctx.root, id <> ".response")) == ~s({"ok":{"receipt":"external-complete"}})
    assert File.regular?(Path.join(ctx.root, id <> ".finished"))
    assert File.read!(ctx.trace) == "executed\n"
  end

  test "a committed pending link is settled before one execution", ctx do
    id = String.duplicate("a", 32)
    pending(ctx, id)
    path = Path.join(ctx.root, id <> ".pending")
    temporary = path <> ".writing." <> String.duplicate("a", 16)
    File.ln!(path, temporary)
    File.chmod!(path, 0o600)
    request = File.read!(path)
    server = start_broker(ctx)
    :sys.get_state(server)
    refute File.exists?(temporary)
    assert File.read!(Path.join(ctx.root, id <> ".finished")) == request
    assert File.read!(ctx.trace) == "executed\n"
  end

  @tag :uncertainty_residue
  test "startup and polling settle only complete service uncertainty response residues", ctx do
    reasons = [:broker_runtime_outcome_uncertain, :broker_runtime_request_invalid_or_expired]
    cases = for phase <- [:startup, :poll], reason <- reasons, do: {phase, reason}

    for {{phase, reason}, index} <- Enum.with_index(cases) do
      id = Integer.to_string(index) |> String.pad_leading(32, "0")
      server = if phase == :poll, do: start_broker(ctx)
      if server, do: :sys.get_state(server)
      running = install_running(ctx, id)
      body = Jason.encode!(%{"error" => inspect(reason)})
      {response, temporary} = install_linked_response(ctx, id, body)
      refute File.exists?(Path.join(ctx.root, id <> ".known"))
      server = server || start_broker(ctx)
      send(server, :poll)
      :sys.get_state(server)
      assert File.read!(response) == body
      assert File.stat!(response).links == 1
      refute File.exists?(temporary)
      refute File.exists?(running)
      assert File.regular?(Path.join(ctx.root, id <> ".finished"))
      refute File.exists?(ctx.trace)
      :ok = stop_supervised(BrokerRuntime)
    end
  end

  @tag :uncertainty_residue
  test "linked success unknown errors and untrusted uncertainty residues remain untouched", ctx do
    variants = [
      {:success, ~s({"ok":"not an uncertainty result"})},
      {:unknown, ~s({"error":":some_other_error"})},
      {:malformed, "{broken"},
      {:shape, ~s({"error":":broker_runtime_outcome_uncertain","ok":true})},
      {:duplicate, ~s({"error":":unknown","error":":broker_runtime_outcome_uncertain"})},
      {:foreign, ~s({"error":":broker_runtime_outcome_uncertain"})},
      {:multiple, ~s({"error":":broker_runtime_outcome_uncertain"})},
      {:symlink, ~s({"error":":broker_runtime_outcome_uncertain"})}
    ]

    for {{kind, body}, index} <- Enum.with_index(variants) do
      id = Integer.to_string(index) |> String.pad_leading(32, "0")
      running = install_running(ctx, id)
      {response, temporary} = install_linked_response(ctx, id, body)
      extra = temporary <> ".foreign"

      case kind do
        :foreign ->
          File.rename!(temporary, extra)
          File.write!(temporary, "foreign bytes")

        :multiple ->
          File.ln!(response, String.replace_suffix(temporary, String.duplicate("b", 16), String.duplicate("c", 16)))

        :symlink ->
          File.rename!(temporary, extra)
          File.ln_s!(response, temporary)

        _ ->
          :ok
      end

      original_stat = File.lstat!(response)
      original_temporary = File.lstat!(temporary)
      server = start_broker(ctx)

      for _ <- 1..2 do
        send(server, :poll)
        :sys.get_state(server)
      end

      assert File.read!(response) == body
      assert File.lstat!(response).links == original_stat.links
      assert File.lstat!(temporary).type == original_temporary.type
      assert File.exists?(running)
      refute File.exists?(Path.join(ctx.root, id <> ".finished"))
      refute File.exists?(ctx.trace)
      :ok = stop_supervised(BrokerRuntime)
    end
  end

  test "corrupt known result metadata fails closed across restart", ctx do
    id = blocked_result(ctx, "f")
    :ok = stop_supervised(BrokerRuntime)
    path = Path.join(ctx.root, id <> ".known")
    original = Jason.decode!(File.read!(path))
    File.rmdir!(Path.join(ctx.root, id <> ".response"))

    variants = [
      "null",
      "[]",
      "{broken",
      String.duplicate("x", 2_800_001),
      Jason.encode!(Map.put(original, "version", 2)),
      Jason.encode!(Map.put(original, "mailbox_id", String.duplicate("0", 32))),
      Jason.encode!(Map.put(original, "database_root", ctx.directory <> "/foreign")),
      Jason.encode!(Map.put(original, "request_sha256", String.duplicate("0", 64))),
      Jason.encode!(Map.put(original, "response_sha256", String.duplicate("0", 64))),
      Jason.encode!(Map.put(original, "response_base64", "not base64")),
      Jason.encode!(original |> Map.put("response_base64", Base.encode64(~s({"ok":1,"error":"contradiction"}))) |> Map.put("response_sha256", digest(~s({"ok":1,"error":"contradiction"}))))
    ]

    for raw <- variants do
      File.write!(path, raw)
      server = start_broker(ctx)
      :sys.get_state(server)
      assert File.read!(path) == raw
      refute File.exists?(Path.join(ctx.root, id <> ".response"))
      assert File.exists?(Path.join(ctx.root, id <> ".running"))
      assert File.read!(ctx.trace) == "executed\n"
      :ok = stop_supervised(BrokerRuntime)
    end
  end

  test "linked and nonprivate known files and changed original request bytes cannot publish", ctx do
    id = blocked_result(ctx, "1")
    :ok = stop_supervised(BrokerRuntime)
    path = Path.join(ctx.root, id <> ".known")
    File.rmdir!(Path.join(ctx.root, id <> ".response"))
    saved = Path.join(ctx.directory, "known-saved")
    File.rename!(path, saved)

    for kind <- [:symlink, :hardlink, :nonprivate, :changed_request] do
      case kind do
        :symlink -> File.ln_s!(saved, path)
        :hardlink -> File.ln!(saved, path)
        _ -> File.cp!(saved, path)
      end

      File.chmod!(path, if(kind == :nonprivate, do: 0o644, else: 0o600))
      if kind == :changed_request, do: File.write!(Path.join(ctx.root, id <> ".running"), "{\"changed\":true}")
      server = start_broker(ctx)
      :sys.get_state(server)
      refute File.exists?(Path.join(ctx.root, id <> ".response"))
      assert File.read!(ctx.trace) == "executed\n"
      :ok = stop_supervised(BrokerRuntime)
      File.rm!(path)
    end
  end

  test "unserializable and escaped oversized outcomes fail explicitly without a replay", ctx do
    for {character, value} <- [{"2", self()}, {"3", String.duplicate(<<0>>, 400_000)}] do
      id = String.duplicate(character, 32)
      pending(ctx, id)

      executor = fn args, store, factory ->
        ctx.executor.(args, store, factory)
        {:ok, value}
      end

      server = start_broker(%{ctx | executor: executor})
      :sys.get_state(server)
      assert Jason.decode!(File.read!(Path.join(ctx.root, id <> ".response"))) == %{"error" => "broker_runtime_result_invalid"}
      assert File.exists?(Path.join(ctx.root, id <> ".known"))
      :ok = stop_supervised(BrokerRuntime)
    end

    assert File.read!(ctx.trace) == "executed\nexecuted\n"
  end

  defp blocked_result(ctx, character) do
    id = String.duplicate(character, 32)
    pending(ctx, id)
    server = start_broker(%{ctx | executor: obstructing_executor(ctx, Path.join(ctx.root, id <> ".response"))})
    :sys.get_state(server)
    assert File.read!(ctx.trace) == "executed\n"
    assert File.regular?(Path.join(ctx.root, id <> ".known"))
    id
  end

  defp obstructing_executor(ctx, obstruction) do
    fn _args, _store, _factory ->
      {output, 0} = System.cmd("python3", [Path.expand("../support/broker_result_executor.py", __DIR__), ctx.trace, obstruction])
      {:ok, Jason.decode!(output)}
    end
  end

  defp pending(ctx, id, expiry \\ System.system_time(:millisecond) + 50_000) do
    File.write!(Path.join(ctx.root, id <> ".pending"), Jason.encode!(%{"args" => ["claim", "request"], "expires_at" => expiry}))
  end

  defp install_running(ctx, id) do
    pending(ctx, id)
    running = Path.join(ctx.root, id <> ".running")
    File.rename!(Path.join(ctx.root, id <> ".pending"), running)
    running
  end

  defp install_linked_response(ctx, id, body) do
    response = Path.join(ctx.root, id <> ".response")
    temporary = response <> ".writing." <> String.duplicate("b", 16)
    {:ok, file} = File.open(temporary, [:write, :exclusive, :binary])
    File.chmod!(temporary, 0o600)
    :ok = IO.binwrite(file, body)
    :ok = :file.sync(file)
    :ok = File.close(file)
    File.ln!(temporary, response)
    {response, temporary}
  end

  defp start_broker(ctx),
    do:
      start_supervised!(
        Supervisor.child_spec({BrokerRuntime, factory: ctx.factory, store: ctx.store, name: nil, executor: ctx.executor, after_known_link: Map.get(ctx, :after_known_link)}, restart: :temporary)
      )

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp wait_for(path) do
    result =
      Enum.reduce_while(1..500, :timeout, fn _, _ ->
        if File.exists?(path),
          do: {:halt, :ready},
          else:
            (
              Process.sleep(10)
              {:cont, :timeout}
            )
      end)

    assert result == :ready
    assert File.exists?(path)
  end
end
