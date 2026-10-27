defmodule SymphonyElixir.FactoryTicketPushReadbackTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{Store, TicketPushIO}
  alias SymphonyElixir.PathSafety

  test "the status catalog retains every prior origin and the last publishing release" do
    priv = Path.expand("../../priv", __DIR__)
    prior = Jason.decode!(File.read!(Path.join(priv, "ticket_push_readback_origins_v12.json")))
    current = Jason.decode!(File.read!(Path.join(priv, "ticket_push_readback_origins_v13.json")))
    assert current["version"] == 13
    assert Enum.take(current["entries"], length(prior["entries"])) == prior["entries"]
    assert length(current["entries"]) == length(prior["entries"]) + 1
    entry = List.last(current["entries"])
    assert entry["kind"] == "RELEASE_ARTIFACT_V2"
    assert entry["manifest_sha256"] == "c0e9743ccf622377f9e1725f86925ac8a9f13ac056ee106065e14429bfb579f6"
    assert entry["helper_sha256"] == "1c2a6a62c99dde9668853ec22f80c7c2dfd4ee769beb85356aacd7451e5f021f"
    assert entry["helper_path"] == entry["artifact_helper_path"]
    assert entry["companion_path"] == entry["artifact_companion_path"]
    assert entry["helper_path"] == Path.join(entry["release_root"], "dev/lib/symphony_elixir/priv/ticket_push_executor_v19.py")
  end

  test "the current catalog retains every prior origin and pins the latest publishing release", context do
    previous = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v13.json")))
    current = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v14.json")))
    assert current["version"] == 14
    assert Enum.drop(current["entries"], -1) == previous["entries"]
    entry = List.last(current["entries"])
    assert entry["kind"] == "RELEASE_ARTIFACT_V2"
    assert entry["release_root"] == "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-generation-handoff-cnRVdUfY-r8"
    assert entry["manifest_sha256"] == "d017b744592f177eebe5781f88e78308bedd483c0f71a99bf05b39386937ff0a"
    assert entry["helper_sha256"] == "2a5ef26d16c6235ce818e2fcfd8591e369b17ef49bd087eb479a93adf8ed8d16"
    assert entry["helper_path"] == Path.join(entry["release_root"], "dev/lib/symphony_elixir/priv/ticket_push_executor_v20.py")
    assert entry["artifact_helper_path"] == entry["helper_path"]
    assert entry["artifact_companion_path"] == entry["companion_path"]
  end

  test "the forward status catalog retains the exact last rejected publisher", context do
    previous = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v14.json")))
    current = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v15.json")))
    assert current["version"] == 15
    assert Enum.drop(current["entries"], -1) == previous["entries"]
    entry = List.last(current["entries"])
    assert entry["manifest_sha256"] == "9264afddf4769e8bb4b475c7e3bcce1430d347e13d3ddb8e10f85d56105511e1"
    assert entry["helper_path"] == Path.join(entry["release_root"], "dev/lib/symphony_elixir/priv/ticket_push_executor_v24.py")
  end

  test "writer readiness status catalog preserves every historical origin", context do
    previous = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v15.json")))
    current = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v16.json")))
    assert current["version"] == 16
    assert current["entries"] == previous["entries"]
  end

  test "ordinary bindings status catalog preserves every historical origin", context do
    previous = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v16.json")))
    current = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v17.json")))
    assert current["version"] == 17
    assert current["entries"] == previous["entries"]
  end

  test "the next catalog retains and authenticates the actual last publisher", context do
    previous = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v17.json")))
    current = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v18.json")))
    assert current["version"] == 18
    assert Enum.drop(current["entries"], -1) == previous["entries"]
    entry = List.last(current["entries"])
    release = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-generation-handoff-cnRVdUfY-r19f"
    assert entry["kind"] == "RELEASE_ARTIFACT_V2"
    assert entry["release_root"] == release
    assert entry["manifest_path"] == release <> "/evidence/release-manifest.json"
    assert entry["manifest_sha256"] == "1b3bbe66c469a3aea634004c6b17f77f2b4533f87a6882a48649b7f3e8587d48"
    assert entry["expected_manifest_kind"] == "FACTORY_PUSH_HANDOFF_RELEASE_V1"
    assert entry["helper_path"] == release <> "/dev/lib/symphony_elixir/priv/ticket_push_executor_v26.py"
    assert entry["helper_sha256"] == "67d9a0625e77f653e70aa91744ac74ec540451063f5d386860f45c66974b6aad"
    assert entry["companion_path"] == release <> "/dev/lib/symphony_elixir/priv/worker_file_companion.py"
    assert entry["companion_sha256"] == "87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b"
    assert entry["artifact_helper_path"] == entry["helper_path"]
    assert entry["artifact_companion_path"] == entry["companion_path"]
  end

  test "the current catalog enrolls only the exact rejected v34 release", context do
    prior = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v18.json")))
    current = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v19.json")))
    assert current["version"] == 19
    assert Enum.drop(current["entries"], -1) == prior["entries"]
    entry = List.last(current["entries"])
    release = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-e47cce2-r2"
    assert entry["kind"] == "RELEASE_ARTIFACT_V2"
    assert entry["release_root"] == release
    assert entry["expected_manifest_kind"] == "FACTORY_REVIEW_REPORT_RELEASE_V1"
    assert entry["manifest_path"] == release <> "/evidence/release-manifest.json"
    assert entry["manifest_sha256"] == "bef269d33f281ea679b9050f7e0cbe5f54f0ab4b30dc4790ee8709cf1b05cda3"
    assert entry["helper_path"] == release <> "/dev/lib/symphony_elixir/priv/ticket_push_executor_v34.py"
    assert entry["helper_sha256"] == "d706fab220dae8a8bd90523a94cd8bc9b3a42bd5fa99af881cc073f66157a733"
    assert entry["companion_path"] == release <> "/dev/lib/symphony_elixir/priv/worker_file_companion.py"
    assert entry["companion_sha256"] == "87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b"
    assert entry["helper_path"] == entry["artifact_helper_path"]
    assert entry["companion_path"] == entry["artifact_companion_path"]
  end

  @tag attested_readback: :retained_publisher_capability
  test "the rejected v34 publisher remains readable after relocation without issuance", context do
    {intent, receipt} = recorded(context, context.attested.name, context.attested.recorded_priv)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("v34 historical origin granted issuance") end)
    assert spool_bytes(context.spool) == before
  end

  @tag attested_readback: :forward_capability
  test "a publisher enrolled only by the new catalog remains status-only", context do
    fixture = context.attested
    old_catalog = Path.join(fixture.runtime_priv, "ticket_push_readback_origins_v17.json")
    File.cp!(Path.expand("../../priv/ticket_push_readback_origins_v17.json", __DIR__), old_catalog)
    {intent, receipt} = recorded(context, fixture.name, fixture.recorded_priv)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("historical origin granted issuance") end)
    assert spool_bytes(context.spool) == before
  end

  @tag attested_readback: :capability_prior_history
  test "the next push history validator accepts the pinned predecessor but not a sibling or changed program", context do
    {intent, receipt} = recorded(context, context.attested.name, context.attested.recorded_priv)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("retained origin granted issuance") end)
    assert spool_bytes(context.spool) == before

    script = ~S'''
    import importlib.util,json,pathlib,sys
    local=pathlib.Path(sys.argv[1])
    spec=importlib.util.spec_from_file_location('history',local/'ticket_push_history_validator_v18.py')
    history=importlib.util.module_from_spec(spec); spec.loader.exec_module(history)
    entry=json.loads((local/'ticket_push_readback_origins_v14.json').read_bytes())['entries'][-1]
    execution={key:entry[key] for key in ('helper_path','helper_sha256','companion_path','companion_sha256')}
    execution['history_program_sha256']=history.sha((local/'ticket_push_history_validator_v16.py').read_bytes())
    history.push_program_origin(execution,local)
    for key,replacement in (('helper_path',str(pathlib.Path(execution['helper_path']).parent/'unregistered'/pathlib.Path(execution['helper_path']).name)),('helper_sha256','0'*64),('companion_sha256','0'*64),('history_program_sha256','0'*64)):
        try: history.push_program_origin(dict(execution,**{key:replacement}),local)
        except (ValueError,KeyError,TypeError): continue
        raise AssertionError('unregistered predecessor accepted: '+key)
    print('PINNED_PREDECESSOR_HISTORY_STATUS_ONLY_PASS')
    '''

    assert {"PINNED_PREDECESSOR_HISTORY_STATUS_ONLY_PASS\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, context.attested.runtime_priv], stderr_to_stdout: true)
  end

  test "the publication catalog retains every origin and adds only the completed v36 release", context do
    old = Jason.decode!(File.read!(Path.join(context.priv, "ticket_push_readback_origins_v19.json")))
    raw = File.read!(Path.join(context.priv, "ticket_push_readback_origins_v20.json"))
    current = Jason.decode!(raw)
    assert byte_size(raw) <= 65_536
    assert current["version"] == 20 and length(current["entries"]) == 15
    assert Enum.drop(current["entries"], -1) == old["entries"]
    assert length(Enum.uniq_by(current["entries"], & &1["helper_path"])) == 15
    root = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-216eadb"
    helper = root <> "/dev/lib/symphony_elixir/priv/ticket_push_executor_v36.py"
    companion = root <> "/dev/lib/symphony_elixir/priv/worker_file_companion.py"

    assert List.last(current["entries"]) == %{
             "kind" => "RELEASE_ARTIFACT_V2",
             "release_root" => root,
             "manifest_path" => root <> "/evidence/release-manifest.json",
             "manifest_sha256" => "8119af4273e08dd17442790236bbcacecb884e3e8997dc99ba36a2159093af65",
             "expected_manifest_kind" => "FACTORY_REVIEW_REPORT_RELEASE_V1",
             "helper_path" => helper,
             "artifact_helper_path" => helper,
             "helper_sha256" => "7c023c0e853aaea8a809280cd7c67f5182a85cc2199cdb5d074786c938083238",
             "companion_path" => companion,
             "artifact_companion_path" => companion,
             "companion_sha256" => "87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b"
           }
  end

  @tag attested_readback: :completed_publication_relocation
  test "a completed publisher stays readable after the current runtime relocates", context do
    fixture = context.attested
    {intent, receipt} = recorded(context, fixture.name, fixture.recorded_priv)
    assert context.module.receipt_valid?(receipt, intent)
    producer_app = Path.dirname(fixture.recorded_priv)
    File.cp_r!(Path.join(Path.dirname(fixture.runtime_priv), "ebin"), Path.join(producer_app, "ebin"))
    runtime_ebin = String.to_charlist(Path.join(Path.dirname(fixture.runtime_priv), "ebin"))
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(producer_app, "ebin")))

    try do
      assert {:ok, ^receipt} = TicketPushIO.readback(intent)
    after
      true = :code.replace_path(:symphony_elixir, runtime_ebin)
    end

    before = spool_bytes(context.spool)
    origin = Map.new(Path.wildcard(Path.join(fixture.recorded_priv, "*")), &{&1, File.read!(&1)})
    digest = hash(receipt)

    try do
      assert {:ok, ^receipt} = context.module.readback(intent)
      assert context.module.receipt_valid?(receipt, intent)
      assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("historical completion granted issuance") end)
    after
      assert spool_bytes(context.spool) == before
      assert File.read!(Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt")) == receipt
      assert hash(File.read!(Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt"))) == digest
      for {path, raw} <- origin, do: assert(File.read!(path) == raw)
    end
  end

  setup tags do
    {:ok, temporary} = PathSafety.canonicalize(System.tmp_dir!())
    base = Path.join(temporary, "push-readback-#{System.unique_integer([:positive])}")
    origin = Path.join(base, "origin")
    priv = Path.join(origin, "priv")
    File.mkdir_p!(priv)

    for path <- Path.wildcard(Path.expand("../../priv/*", __DIR__)), File.regular?(path) do
      File.cp!(path, Path.join(priv, Path.basename(path)))
    end

    historical = if tags[:readback_provenance], do: historical_fixture(base, priv, tags[:readback_provenance])
    attested = if tags[:attested_readback], do: attested_fixture(base, priv, tags[:attested_readback])
    bounded = if tags[:bounded_readback], do: attested_fixture(base, priv, :bounded)

    source = Path.expand("../../lib/symphony_elixir/factory/ticket_push_io.ex", __DIR__)
    module = Module.concat(__MODULE__, "Pinned#{System.unique_integer([:positive])}")
    filename = Path.join(origin, "lib/symphony_elixir/factory/ticket_push_io.ex")
    File.mkdir_p!(Path.dirname(filename))
    text = String.replace(File.read!(source), "defmodule SymphonyElixir.Factory.TicketPushIO do", "defmodule #{inspect(module)} do", global: false)
    Code.compile_string(text, filename)

    root = Path.join(base, "source")
    spool = Path.join(base, ".factory-file-io")
    File.mkdir_p!(root)
    File.mkdir_p!(spool)
    File.chmod!(spool, 0o700)
    database = Path.join(base, "factory.sqlite")
    start_supervised!({Store, database: database})

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      priv: priv,
      module: module,
      root: root,
      spool: spool,
      database: database,
      historical: historical,
      attested: attested,
      bounded: bounded
    }
  end

  for kind <- [
        :source,
        :release,
        :large_current,
        :large_previous,
        :large_legacy,
        :capability_current,
        :ordinary_acknowledged,
        :review_ordinary,
        :review_capability,
        :forward_ordinary,
        :forward_capability,
        :writer_readiness_ordinary,
        :writer_readiness_capability,
        :ordinary_bindings,
        :ordinary_bindings_capability,
        :retained_publisher_ordinary,
        :retained_publisher_capability,
        :generation_publisher_ordinary,
        :generation_publisher_capability,
        :publication_compat_ordinary,
        :publication_compat_capability,
        :typed_ordinary,
        :typed_capability,
        :capability_legacy_v20,
        :capability_legacy_v19,
        :capability_legacy_v18,
        :capability_legacy_v17,
        :capability_previous,
        :capability_retained
      ] do
    @tag attested_readback: kind
    test "attested #{kind} receipt survives physical copied priv without issuing children or rewriting evidence", context do
      fixture = context.attested
      {intent, receipt} = recorded(context, fixture.name, fixture.recorded_priv)
      before = spool_bytes(context.spool)
      database_before = File.read!(context.database)
      claim = Path.join(context.spool, intent["owner_nonce"] <> ".push-claim")
      receipt_path = Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt")
      if fixture.kind == :source, do: File.rm_rf!(fixture.recorded_priv)
      refute File.exists?(fixture.proof_path)
      assert {:ok, ^receipt} = context.module.readback(intent)
      assert context.module.receipt_valid?(receipt, intent)
      assert {:ok, ^receipt} = context.module.readback(intent)
      assert spool_bytes(context.spool) == before
      assert File.read!(context.database) == database_before
      assert {:error, :ticket_push_transport_unproven} = context.module.readback(change(intent, "intent_sha256", String.duplicate("0", 64)))
      assert {:error, :ticket_push_transport_unproven} = context.module.readback(Map.put(intent, "helper_pid", 101))

      for raw <- [Jason.encode!(Map.put(Jason.decode!(receipt), "output_sha256", String.duplicate("0", 64))), Jason.encode!(Map.put(Jason.decode!(receipt), "extra", true))] do
        File.write!(receipt_path, raw)
        assert {:error, :ticket_push_transport_unproven} = context.module.readback(intent)
      end

      File.write!(receipt_path, receipt)
      assert {:ok, ^receipt} = context.module.readback(intent)

      for path <- [claim, receipt_path] do
        raw = File.read!(path)
        File.rename!(path, path <> ".saved")
        assert {:error, :ticket_push_transport_unproven} = context.module.readback(intent)
        File.rename!(path <> ".saved", path)
        File.write!(path, "{}")
        assert {:error, :ticket_push_transport_unproven} = context.module.readback(intent)
        File.write!(path, raw)
      end

      assert {:ok, ^receipt} = context.module.readback(intent)
      assert spool_bytes(context.spool) == before
      assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("attestation issued a child") end)

      for path <- [fixture.manifest, Path.join(fixture.artifact_priv, fixture.name), Path.join(fixture.runtime_priv, fixture.name), Path.join(fixture.runtime_priv, "worker_file_companion.py")] do
        bytes = File.read!(path)
        File.write!(path, bytes <> "\nchanged")
        assert {:error, _} = context.module.readback(intent)
        File.write!(path, bytes)
        assert {:ok, ^receipt} = context.module.readback(intent)
      end

      sibling = Path.join(context.base, "unregistered")
      File.mkdir_p!(sibling)
      for name <- [fixture.name, "worker_file_companion.py"], do: File.cp!(Path.join(fixture.runtime_priv, name), Path.join(sibling, name))
      rebound = intent |> change("helper_path", Path.join(sibling, fixture.name)) |> change("companion_path", Path.join(sibling, "worker_file_companion.py"))
      assert {:error, :ticket_push_program_changed} = context.module.readback(rebound)
      File.write!(claim, "changed")
      assert {:error, :ticket_push_transport_unproven} = context.module.readback(intent)
      File.write!(claim, intent["execution_json"])
      assert {:ok, ^receipt} = context.module.readback(intent)
      assert spool_bytes(context.spool) == before
    end
  end

  test "current v11 reads an incident-sized terminal receipt above the old shared checkout bound", context do
    {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    {intent, raw} = recorded(context, "ticket_push_executor_v11.py", priv)
    {intent, receipt} = incident_shape(intent, raw)
    execution = intent["execution_json"]
    assert byte_size(execution) == 244_044
    assert byte_size(receipt) == 262_236
    assert context.module.receipt_valid?(receipt, intent)
    File.write!(Path.join(context.spool, intent["owner_nonce"] <> ".push-claim"), execution)
    File.write!(Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt"), receipt)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert spool_bytes(context.spool) == before
  end

  test "local capability readback accepts exact canonical paths and denies identical siblings", context do
    {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))

    for name <-
          ~w(ticket_push_executor_v15.py ticket_push_executor_v16.py ticket_push_executor_v17.py ticket_push_executor_v18.py ticket_push_executor_v19.py ticket_push_executor_v20.py ticket_push_executor_v21.py ticket_push_executor_v22.py ticket_push_executor_v23.py ticket_push_executor_v24.py) do
      {intent, receipt} = recorded(context, name, priv)
      assert {:ok, ^receipt} = context.module.readback(intent)
      sibling = Path.join(context.base, "unregistered-local-" <> name)
      File.mkdir_p!(sibling)
      for file <- [name, "worker_file_companion.py"], do: File.cp!(Path.join(priv, file), Path.join(sibling, file))
      rebound = intent |> change("helper_path", Path.join(sibling, name)) |> change("companion_path", Path.join(sibling, "worker_file_companion.py"))
      assert {:error, :ticket_push_program_changed} = context.module.readback(rebound)
    end
  end

  test "retained R14 v17 origin stays readable and history-authenticated without executing its helper", context do
    catalog = Jason.decode!(File.read!(Application.app_dir(:symphony_elixir, "priv/ticket_push_readback_origins_v11.json")))
    entry = Enum.find(catalog["entries"], &String.ends_with?(&1["helper_path"], "/ticket_push_executor_v17.py"))
    {intent, receipt} = recorded(context, "ticket_push_executor_v17.py", Path.dirname(entry["helper_path"]))
    before = spool_bytes(context.spool)
    database_before = File.read!(context.database)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    assert spool_bytes(context.spool) == before
    assert File.read!(context.database) == database_before

    script = ~S"""
    import hashlib,importlib.util,json,pathlib,sys
    local=pathlib.Path(sys.argv[1]).resolve(strict=True); sha=lambda raw:hashlib.sha256(raw).hexdigest()
    entry=next(e for e in json.loads((local/'ticket_push_readback_origins_v11.json').read_text())['entries'] if e['helper_path'].endswith('/ticket_push_executor_v17.py'))
    execution={key:entry[key] for key in ('helper_path','helper_sha256','companion_path','companion_sha256')}
    execution['history_program_path']=str(pathlib.Path(execution['helper_path']).with_name('ticket_push_history_validator_v14.py'))
    execution['history_program_sha256']=sha(pathlib.Path(execution['history_program_path']).read_bytes())
    spec=importlib.util.spec_from_file_location('new_history',local/'ticket_push_history_validator_v15.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.push_program_origin(execution,local)
    current=dict(execution)
    current.update(helper_path=str(local/'ticket_push_executor_v18.py'),helper_sha256=sha((local/'ticket_push_executor_v18.py').read_bytes()),companion_path=str(local/'worker_file_companion.py'),history_program_path=str(local/'ticket_push_history_validator_v15.py'),history_program_sha256=sha((local/'ticket_push_history_validator_v15.py').read_bytes()))
    module.push_program_origin(current,local)
    assert (local/'ticket_push_executor_v18.py').read_text()==(local/'ticket_push_executor_v17.py').read_text().replace('ticket_push_history_validator_v14.py','ticket_push_history_validator_v15.py')
    for key in ('helper_sha256','companion_sha256','history_program_sha256'):
        wrong=dict(execution,**{key:'0'*64})
        try:module.push_program_origin(wrong,local)
        except (ValueError,KeyError,TypeError):continue
        raise AssertionError('mutated retained origin accepted')
    print('retained-v17-history-PASS-no-helper-execution')
    """

    assert {"retained-v17-history-PASS-no-helper-execution\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv")], stderr_to_stdout: true)
  end

  @tag :external_v16_archive
  test "external retained v16 origin authenticates the manifest history and exact tuple", context do
    script = ~S"""
    import hashlib,importlib.util,json,pathlib,shutil,sys
    local=pathlib.Path(sys.argv[1]).resolve(strict=True); base=pathlib.Path(sys.argv[2]); sha=lambda raw:hashlib.sha256(raw).hexdigest()
    def load(path):
        spec=importlib.util.spec_from_file_location('archive_origin',path); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
    catalog=json.loads((local/'ticket_push_readback_origins_v10.json').read_text())
    entry=next(value for value in catalog['entries'] if value['helper_path'].endswith('ticket_push_executor_v16.py'))
    original={key:entry[key] for key in ('helper_path','helper_sha256','companion_path','companion_sha256')}
    original['history_program_path']=str(pathlib.Path(original['helper_path']).with_name('ticket_push_history_validator_v13.py'))
    original['history_program_sha256']=sha(pathlib.Path(original['history_program_path']).read_bytes())
    assert pathlib.Path(original['helper_path']).parent!=local
    load(local/'ticket_push_history_validator_v14.py').push_program_origin(original,local)
    private=base/'private-current'; private.mkdir()
    for path in local.iterdir():
        if path.is_file():shutil.copy2(path,private/path.name)
    root=base/'external-release'; artifact=root/'dev/lib/symphony_elixir/priv';artifact.mkdir(parents=True)
    for key in ('helper_path','companion_path','history_program_path'):shutil.copy2(original[key],artifact/pathlib.Path(original[key]).name)
    manifest_path=root/'evidence/release-manifest.json';manifest_path.parent.mkdir()
    artifact_map={'lib/symphony_elixir/priv/'+path.name:{'sha256':sha(path.read_bytes())} for path in artifact.iterdir()}
    manifest_path.write_text(json.dumps({'release':str(root),'kind':entry['expected_manifest_kind'],'artifact':artifact_map}))
    copied=dict(entry)
    for key,value in copied.items():
        if isinstance(value,str):copied[key]=value.replace(entry['release_root'],str(root))
    copied['manifest_sha256']=sha(manifest_path.read_bytes())
    raw=json.dumps({'version':10,'entries':[copied]},separators=(',',':'))
    (private/'ticket_push_readback_origins_v10.json').write_text(raw)
    history=private/'ticket_push_history_validator_v14.py';text=history.read_text(); assert text.count('c14521ff0fa82970c464d6f96791e0282ab2fbdb65b9872474ba5bbf76b9f099')==1
    history.write_text(text.replace('c14521ff0fa82970c464d6f96791e0282ab2fbdb65b9872474ba5bbf76b9f099',sha(raw.encode())))
    module=load(history); execution=dict(original)
    for key in ('helper_path','companion_path','history_program_path'):execution[key]=str(artifact/pathlib.Path(execution[key]).name)
    def reject(value):
        try:module.push_program_origin(value,private)
        except (ValueError,KeyError,TypeError):return
        raise AssertionError('unregistered archive origin accepted')
    module.push_program_origin(execution,private)
    for path in [manifest_path]+list(artifact.iterdir()):
        before=path.read_bytes();path.write_bytes(before+b'changed');reject(execution);path.write_bytes(before);module.push_program_origin(execution,private)
    for key in ('helper_sha256','companion_sha256','history_program_sha256'):reject(dict(execution,**{key:'0'*64}))
    sibling=base/'identical-unregistered';shutil.copytree(artifact,sibling)
    reject(dict(execution,helper_path=str(sibling/pathlib.Path(execution['helper_path']).name),companion_path=str(sibling/'worker_file_companion.py')))
    print('external-v16-origin-PASS-no-issued-receipt')
    """

    assert {"external-v16-origin-PASS-no-issued-receipt\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv"), context.base], stderr_to_stdout: true)
  end

  test "current push request admission and receipt frames have independent one and four MiB bounds", context do
    for token <- ["x", "\"", "\\", "é", "😀", <<127>>], offset <- [-1, 0, 1] do
      seed = %{"payload" => String.duplicate(token, 1000), "padding" => ""}
      base = byte_size(Jason.encode!(%{"execution_json" => Jason.encode!(seed), "helper_pid" => 9_223_372_036_854_775_807}))
      execution = Map.put(seed, "padding", String.duplicate("x", 1_048_576 + offset - base))
      assert context.module.transport_admissible?(execution) == offset <= 0
    end

    seed = %{"payload" => String.duplicate(<<127>>, 650_000), "padding" => ""}
    response_size = python_response_size(seed)

    for offset <- [-1, 0, 1] do
      execution = Map.put(seed, "padding", String.duplicate("x", 4_194_304 + offset - response_size))
      assert python_response_size(execution) == 4_194_304 + offset
      assert context.module.transport_admissible?(execution) == offset <= 0
    end

    for size <- [4_194_303, 4_194_304] do
      raw = String.duplicate("x", size)
      assert {:ok, ^raw} = context.module.receipt_frame(<<size::32, raw::binary>>)
    end

    oversized = <<4_194_305::32, String.duplicate("x", 4_194_305)::binary>>

    for frame <- [<<0::32>>, <<4::32, "123">>, <<2::32, "123">>, <<1::32, "x", 1::32, "x">>, oversized] do
      assert {:error, :ticket_push_transport_unproven} = context.module.receipt_frame(frame)
    end
  end

  test "bounded push validation retains strict terminal keys types and output bounds", context do
    {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    {intent, raw} = recorded(context, "ticket_push_executor_v11.py", priv)
    receipt = Jason.decode!(raw)

    for changed <- [
          Map.put(receipt, "helper_pid", 100.0),
          Map.put(receipt, "child_pid", 0),
          Map.put(receipt, "version", 1.0),
          Map.put(receipt, "overflow", 0),
          Map.put(receipt, "timed_out", "false"),
          Map.put(receipt, "termination", %{"kind" => "signaled", "signal" => 9.0}),
          Map.put(receipt, "termination", %{"kind" => "exited", "code" => 256}),
          Map.put(receipt, "termination", %{"kind" => "exited", "code" => 0, "extra" => true}),
          receipt |> Map.put("output_base64", Base.encode64(String.duplicate("x", 65_537))) |> Map.put("output_sha256", hash(String.duplicate("x", 65_537))),
          Map.put(receipt, "extra", true)
        ] do
      refute context.module.receipt_valid?(Jason.encode!(changed), intent)
    end

    exact = raw <> String.duplicate(" ", 1_048_576 - byte_size(raw))
    assert context.module.receipt_valid?(exact, intent)
    refute context.module.receipt_valid?(exact <> " ", intent)
  end

  test "v12 readback preserves exact large receipt bytes while v11 retains its historical cap", context do
    {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    {intent, raw} = recorded(context, "ticket_push_executor_v12.py", priv)
    execution = Jason.decode!(intent["execution_json"]) |> Map.put("padding", String.duplicate("x", 600_000))
    intent = Map.put(intent, "execution_json", Jason.encode!(execution))
    receipt = Jason.decode!(raw) |> Map.put("execution_json", intent["execution_json"]) |> Jason.encode!()
    assert context.module.execution_size_valid?(intent["execution_json"])
    assert context.module.transport_admissible?(execution)
    claim = Path.join(context.spool, intent["owner_nonce"] <> ".push-claim")
    target = Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt")
    File.write!(claim, intent["execution_json"])

    for size <- [4_194_303, 4_194_304] do
      exact = receipt <> String.duplicate(" ", size - byte_size(receipt))
      File.write!(target, exact)
      before = spool_bytes(context.spool)
      assert context.module.receipt_valid?(exact, intent)
      assert {:ok, ^exact} = context.module.readback(intent)
      assert spool_bytes(context.spool) == before
    end

    oversized = receipt <> String.duplicate(" ", 4_194_305 - byte_size(receipt))
    File.write!(target, oversized)
    refute context.module.receipt_valid?(oversized, intent)
    assert {:error, _} = context.module.readback(intent)
    refute context.module.execution_size_valid?(Jason.encode!(Map.put(execution, "helper_sha256", hash(File.read!(Path.join(priv, "ticket_push_executor_v11.py"))))))

    {legacy, legacy_receipt} = recorded(context, "ticket_push_executor_v11.py", priv)
    refute context.module.receipt_valid?(legacy_receipt <> String.duplicate(" ", 1_048_577 - byte_size(legacy_receipt)), legacy)
  end

  for name <- ~w(ticket_push_executor_v12.py ticket_push_executor_v13.py ticket_push_executor_v14.py) do
    @tag push_origin_status: true
    test "current reader retains large exact preissuance rejection for #{name} without issuance", context do
      name = unquote(name)
      {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
      {intent, _} = recorded(context, name, priv)
      claim = Path.join(context.spool, intent["owner_nonce"] <> ".push-claim")
      receipt = Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt")
      File.rm!(claim)
      File.rm!(receipt)
      execution = Jason.decode!(intent["execution_json"]) |> Map.put("padding", String.duplicate("x", 270_000))
      intent = Map.put(intent, "execution_json", Jason.encode!(execution))

      raw =
        Jason.encode!(%{
          "version" => 1,
          "kind" => "PREISSUANCE_REJECTED",
          "execution_json" => intent["execution_json"],
          "helper_pid" => intent["helper_pid"],
          "child_pid" => nil,
          "reason" => "ci_evidence_successor_changed"
        })

      assert byte_size(raw) > 262_144
      File.write!(Path.join(context.spool, intent["owner_nonce"] <> ".push-rejection"), raw)
      before = spool_bytes(context.spool)
      assert {:ok, ^raw} = context.module.readback(intent)
      assert {:ok, "ci_evidence_successor_changed"} = context.module.rejection_reason(raw, intent)
      assert spool_bytes(context.spool) == before
      refute File.exists?(claim)
      refute File.exists?(receipt)
      refute context.module.rejection_reason(raw, Map.put(intent, "helper_pid", -1)) == {:ok, "ci_evidence_successor_changed"}
    end
  end

  test "v12 framed CLI refuses oversize escaping or trailing frames before companion or issuance", context do
    helper = Path.join(context.priv, "ticket_push_executor_v12.py")

    script = ~S"""
    import json,subprocess,sys
    helper=sys.argv[1]
    def wire(execution):
      return json.dumps({'execution_json':json.dumps(execution,separators=(',',':'),ensure_ascii=False),'helper_pid':9223372036854775807},separators=(',',':'),ensure_ascii=False).encode()
    def run(raw,declared=None):
      framed=(len(raw) if declared is None else declared).to_bytes(4,'big')+raw
      result=subprocess.run([sys.executable,'-I','-S','-B',helper,'--execute'],input=framed,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=3)
      assert result.returncode != 0 and not result.stdout
      return result.stderr.decode()
    for token in ['x','"','\\','é','😀','\x7f']:
      seed={'invocation':'a'*64,'payload':token*1000,'padding':''}
      baseline=len(wire(seed))
      for offset in [-1,0,1]:
        value=dict(seed,padding='x'*(1048576+offset-baseline))
        error=run(wire(value))
        assert ('companion_path' in error) if offset<=0 else ('frame_rejected' in error)
    assert 'packet_rejected' in run(wire({'invocation':'a'*64,'payload':'\x7f'*700000}))
    raw=wire({'invocation':'a'*64})
    for framed,declared in [(raw[:-1],len(raw)),(raw+b'x',len(raw)),(raw,0)]:
      assert 'frame_rejected' in run(framed,declared)
    print('request_cases=18; receipt_expansion=1; frame_refusals=3; issued_children=0')
    """

    assert {"request_cases=18; receipt_expansion=1; frame_refusals=3; issued_children=0\n", 0} =
             System.cmd(System.find_executable("python3"), ["-I", "-S", "-B", "-c", script, helper], stderr_to_stdout: true)
  end

  test "bounded current preissuance rejection returns authentic bytes without a claim or child", context do
    {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    {intent, _} = recorded(context, "ticket_push_executor_v11.py", priv)
    for suffix <- [".push-claim", ".push-receipt"], do: File.rm!(Path.join(context.spool, intent["owner_nonce"] <> suffix))

    raw =
      Jason.encode!(%{
        "version" => 1,
        "kind" => "PREISSUANCE_REJECTED",
        "execution_json" => intent["execution_json"],
        "helper_pid" => intent["helper_pid"],
        "child_pid" => nil,
        "reason" => "candidate_changed"
      })

    exact = raw <> String.duplicate(" ", 1_048_576 - byte_size(raw))
    path = Path.join(context.spool, intent["owner_nonce"] <> ".push-rejection")
    File.write!(path, exact)
    before = spool_bytes(context.spool)
    assert {:ok, ^exact} = context.module.readback(intent)
    assert {:ok, "candidate_changed"} = context.module.rejection_reason(exact, intent)
    assert spool_bytes(context.spool) == before
    assert {:error, :ticket_push_rejection_unproven} = context.module.rejection_reason(exact <> " ", intent)
    File.write!(path, exact <> " ")
    assert {:error, _} = context.module.readback(intent)
  end

  @tag bounded_readback: true
  test "v2 status-only reader authenticates historical v11 and exact oversized bytes in physical copied priv", context do
    fixture = context.bounded
    {intent, raw} = recorded(context, fixture.name, fixture.recorded_priv)
    {intent, receipt} = incident_shape(intent, raw)
    claim = Path.join(context.spool, intent["owner_nonce"] <> ".push-claim")
    target = Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt")
    File.write!(claim, intent["execution_json"])
    File.write!(target, receipt)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert spool_bytes(context.spool) == before
    assert {:error, _} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("historical readback issued a child") end)
    assert spool_bytes(context.spool) == before
    assert {:error, _} = context.module.readback(Map.put(intent, "helper_pid", 99))
    assert {:error, _} = context.module.readback(change(intent, "invocation", String.duplicate("f", 64)))

    for path <- [claim, target, fixture.manifest, Path.join(fixture.artifact_priv, fixture.name), Path.join(fixture.artifact_priv, "worker_file_companion.py")] do
      original = File.read!(path)
      File.write!(path, original <> "changed")
      assert {:error, _} = context.module.readback(intent)
      File.write!(path, original)
      File.rename!(path, path <> ".saved")
      assert {:error, _} = context.module.readback(intent)
      File.ln_s!(path <> ".saved", path)
      assert {:error, _} = context.module.readback(intent)
      File.rm!(path)
      File.rename!(path <> ".saved", path)
      assert {:ok, ^receipt} = context.module.readback(intent)
    end

    exact = receipt <> String.duplicate(" ", 1_048_576 - byte_size(receipt))
    File.write!(target, exact)
    assert {:ok, ^exact} = context.module.readback(intent)
    File.write!(target, exact <> " ")
    assert {:error, _} = context.module.readback(intent)
    File.write!(target, receipt)
    sibling = Path.join(context.base, "unregistered-v11")
    File.mkdir_p!(sibling)
    for name <- [fixture.name, "worker_file_companion.py"], do: File.cp!(Path.join(fixture.artifact_priv, name), Path.join(sibling, name))
    rebound = intent |> change("helper_path", Path.join(sibling, fixture.name)) |> change("companion_path", Path.join(sibling, "worker_file_companion.py"))
    assert {:error, _} = context.module.readback(rebound)
    assert spool_bytes(context.spool) == before
    reader = Path.join(fixture.runtime_priv, "ticket_push_status_reader_v2.py")
    {message, code} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", reader, "--execute"], stderr_to_stdout: true)
    assert code != 0 and message =~ "mode_rejected"
    assert spool_bytes(context.spool) == before
  end

  for attack <- [:proof_hash, :source_root, :source_hash, :artifact_mapping] do
    @tag attested_readback: attack
    test "coherently pinned attestation still rejects #{attack}", context do
      {intent, _} = recorded(context, context.attested.name, context.attested.recorded_priv)
      assert {:error, :ticket_push_transport_unproven} = context.module.readback(intent)
    end
  end

  defp spool_bytes(path), do: Map.new(File.ls!(path), &{&1, File.read!(Path.join(path, &1))})

  defp attested_fixture(base, priv, kind) do
    {name, release?, version, reader_name} = attestation_kind(kind)

    release = Path.join(base, "attested-release")
    artifact_priv = Path.join(release, "dev/lib/symphony_elixir/priv")
    source = Path.join(base, "retired-source")
    recorded_priv = if release?, do: artifact_priv, else: Path.join(source, "elixir/priv")

    files = attested_files(priv, kind, name)

    for directory <- Enum.uniq([artifact_priv, recorded_priv]) do
      File.mkdir_p!(directory)
      for file <- files, do: File.cp!(Path.join(priv, file), Path.join(directory, file))
    end

    inputs = Map.new([name, "worker_file_companion.py"], &{"elixir/priv/" <> &1, hash(File.read!(Path.join(priv, &1)))})
    proof = %{"kind" => "EMPTY_CHILD_PRIVATE_COMPILE_V1", "source_root" => source, "source_prepost_equal" => true, "old_artifact_unchanged" => true, "exit_code" => 0, "inputs" => inputs}
    proof = if kind == :source_root, do: Map.put(proof, "source_root", source <> "-substituted"), else: proof
    proof = if kind == :source_hash, do: put_in(proof, ["inputs", "elixir/priv/" <> name], String.duplicate("0", 64)), else: proof
    raw_proof = Jason.encode!(proof)
    artifact = Map.new(files, &{"lib/symphony_elixir/priv/" <> &1, %{"sha256" => hash(File.read!(Path.join(priv, &1)))}})
    artifact = if kind == :artifact_mapping, do: Map.delete(artifact, "lib/symphony_elixir/priv/" <> name), else: artifact
    proof_path = Path.join(base, "absent-temporary-compile-proof.json")

    manifest = %{
      "release" => release,
      "source" => Map.new(inputs, fn {key, value} -> {key, %{"sha256" => value}} end),
      "artifact" => artifact,
      "compile_proof_sha256" => if(kind == :proof_hash, do: String.duplicate("0", 64), else: hash(raw_proof)),
      "compile_proof_path" => proof_path
    }

    sealed = kind in [:capability_prior_history, :completed_publication_relocation]
    manifest = if sealed, do: Map.merge(manifest, %{"kind" => "TEST_SEALED_RELEASE", "release" => release}), else: manifest
    manifest_path = if sealed, do: Path.join(release, "evidence/release-manifest.json"), else: Path.join(release, "manifest.json")
    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, Jason.encode!(manifest))

    entry = %{
      "kind" => if(release?, do: "RELEASE_ARTIFACT_V1", else: "COMPILED_SOURCE_V1"),
      "manifest_path" => manifest_path,
      "manifest_sha256" => hash(File.read!(manifest_path)),
      "helper_path" => Path.join(recorded_priv, name),
      "helper_sha256" => inputs["elixir/priv/" <> name],
      "companion_path" => Path.join(recorded_priv, "worker_file_companion.py"),
      "companion_sha256" => inputs["elixir/priv/worker_file_companion.py"],
      "artifact_helper_path" => Path.join(artifact_priv, name),
      "artifact_companion_path" => Path.join(artifact_priv, "worker_file_companion.py")
    }

    entry = if release?, do: entry, else: Map.put(entry, "compile_proof_raw", raw_proof)
    entry = if sealed, do: Map.merge(entry, %{"kind" => "RELEASE_ARTIFACT_V2", "release_root" => release, "expected_manifest_kind" => manifest["kind"]}), else: entry
    resource = Jason.encode!(%{"version" => version, "entries" => [entry]})
    resource_path = Path.join(priv, "ticket_push_readback_origins_v#{version}.json")
    File.write!(resource_path, resource)
    reader = Path.join(priv, reader_name)

    if attested_reader_available?(reader, kind) do
      File.write!(reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(reader), "ORIGINS_SHA256 = \"#{hash(resource)}\""))
    end

    install_forward_attestation(priv, entry, version)

    if kind == :capability_prior_history do
      history = Path.join(priv, "ticket_push_history_validator_v18.py")
      original = File.read!(Path.expand("../../priv/ticket_push_readback_origins_v14.json", __DIR__))
      File.write!(history, String.replace(File.read!(history), hash(original), hash(resource)))
    end

    original_ebin = Application.app_dir(:symphony_elixir, "ebin") |> String.to_charlist()
    runtime = Path.join(base, "runtime/lib/symphony_elixir")
    runtime_priv = Path.join(runtime, "priv")
    File.mkdir_p!(runtime)
    File.cp_r!(priv, runtime_priv)
    File.mkdir_p!(Path.join(runtime, "ebin"))
    for path <- Path.wildcard(Path.join(to_string(original_ebin), "*")), do: File.cp!(path, Path.join(runtime, "ebin/" <> Path.basename(path)))
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(runtime, "ebin")))
    on_exit(fn -> true = :code.replace_path(:symphony_elixir, original_ebin) end)
    %{name: name, kind: kind, recorded_priv: recorded_priv, artifact_priv: artifact_priv, runtime_priv: runtime_priv, manifest: manifest_path, proof_path: proof_path}
  end

  defp attested_reader_available?(reader, kind), do: kind != :completed_publication_relocation or File.exists?(reader)

  defp install_forward_attestation(priv, entry, version) when version in [14, 15, 16, 17, 18, 19] do
    forward = Jason.encode!(%{"version" => 15, "entries" => [entry]})
    File.write!(Path.join(priv, "ticket_push_readback_origins_v15.json"), forward)

    for name <- ~w(ticket_push_status_reader_v14.py ticket_push_status_reader_v15.py) do
      next_reader = Path.join(priv, name)
      File.write!(next_reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(next_reader), "ORIGINS_SHA256 = \"#{hash(forward)}\""))
    end

    latest = Jason.encode!(%{"version" => 16, "entries" => [entry]})
    File.write!(Path.join(priv, "ticket_push_readback_origins_v16.json"), latest)
    next_reader = Path.join(priv, "ticket_push_status_reader_v16.py")
    File.write!(next_reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(next_reader), "ORIGINS_SHA256 = \"#{hash(latest)}\""))

    current = Jason.encode!(%{"version" => 17, "entries" => [entry]})
    File.write!(Path.join(priv, "ticket_push_readback_origins_v17.json"), current)
    current_reader = Path.join(priv, "ticket_push_status_reader_v17.py")
    File.write!(current_reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(current_reader), "ORIGINS_SHA256 = \"#{hash(current)}\""))

    retained = Jason.encode!(%{"version" => 18, "entries" => [entry]})
    File.write!(Path.join(priv, "ticket_push_readback_origins_v18.json"), retained)
    retained_reader = Path.join(priv, "ticket_push_status_reader_v18.py")
    File.write!(retained_reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(retained_reader), "ORIGINS_SHA256 = \"#{hash(retained)}\""))

    generation = Jason.encode!(%{"version" => 19, "entries" => [entry]})
    File.write!(Path.join(priv, "ticket_push_readback_origins_v19.json"), generation)
    generation_reader = Path.join(priv, "ticket_push_status_reader_v19.py")
    File.write!(generation_reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(generation_reader), "ORIGINS_SHA256 = \"#{hash(generation)}\""))

    publication = Jason.encode!(%{"version" => 20, "entries" => [entry]})
    File.write!(Path.join(priv, "ticket_push_readback_origins_v20.json"), publication)
    publication_reader = Path.join(priv, "ticket_push_status_reader_v20.py")
    File.write!(publication_reader, Regex.replace(~r/ORIGINS_SHA256 = "[0-9a-f]{64}"/, File.read!(publication_reader), "ORIGINS_SHA256 = \"#{hash(publication)}\""))
  end

  defp install_forward_attestation(_priv, _entry, _version), do: :ok

  defp attested_files(priv, :completed_publication_relocation, _name),
    do: Path.wildcard(Path.join(priv, "*")) |> Enum.filter(&File.regular?/1) |> Enum.map(&Path.basename/1)

  defp attested_files(_priv, :capability_prior_history, name), do: [name, "worker_file_companion.py", "ticket_push_history_validator_v16.py"]
  defp attested_files(_priv, _kind, name), do: [name, "worker_file_companion.py"]

  defp attestation_kind(:bounded), do: {"ticket_push_executor_v11.py", true, 4, "ticket_push_status_reader_v2.py"}
  defp attestation_kind(:completed_publication_relocation), do: {"ticket_push_executor_v36.py", true, 20, "ticket_push_status_reader_v20.py"}
  defp attestation_kind(:publication_compat_ordinary), do: {"ticket_push_executor_v37.py", true, 20, "ticket_push_status_reader_v20.py"}
  defp attestation_kind(:publication_compat_capability), do: {"ticket_push_executor_v38.py", true, 20, "ticket_push_status_reader_v20.py"}
  defp attestation_kind(:ordinary_bindings), do: {"ticket_push_executor_v31.py", true, 17, "ticket_push_status_reader_v17.py"}
  defp attestation_kind(:ordinary_bindings_capability), do: {"ticket_push_executor_v32.py", true, 17, "ticket_push_status_reader_v17.py"}
  defp attestation_kind(:retained_publisher_ordinary), do: {"ticket_push_executor_v33.py", true, 18, "ticket_push_status_reader_v18.py"}
  defp attestation_kind(:retained_publisher_capability), do: {"ticket_push_executor_v34.py", true, 18, "ticket_push_status_reader_v18.py"}
  defp attestation_kind(:generation_publisher_ordinary), do: {"ticket_push_executor_v35.py", true, 19, "ticket_push_status_reader_v19.py"}
  defp attestation_kind(:generation_publisher_capability), do: {"ticket_push_executor_v36.py", true, 19, "ticket_push_status_reader_v19.py"}
  defp attestation_kind(:forward_ordinary), do: {"ticket_push_executor_v25.py", true, 15, "ticket_push_status_reader_v14.py"}
  defp attestation_kind(:writer_readiness_ordinary), do: {"ticket_push_executor_v29.py", true, 16, "ticket_push_status_reader_v16.py"}
  defp attestation_kind(:writer_readiness_capability), do: {"ticket_push_executor_v30.py", true, 16, "ticket_push_status_reader_v16.py"}
  defp attestation_kind(:typed_ordinary), do: {"ticket_push_executor_v27.py", true, 16, "ticket_push_status_reader_v16.py"}
  defp attestation_kind(:typed_capability), do: {"ticket_push_executor_v28.py", true, 16, "ticket_push_status_reader_v16.py"}
  defp attestation_kind(:forward_capability), do: {"ticket_push_executor_v26.py", true, 15, "ticket_push_status_reader_v14.py"}
  defp attestation_kind(:review_ordinary), do: {"ticket_push_executor_v23.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:review_capability), do: {"ticket_push_executor_v24.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_current), do: {"ticket_push_executor_v21.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:ordinary_acknowledged), do: {"ticket_push_executor_v22.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_legacy_v20), do: {"ticket_push_executor_v20.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_prior_history), do: {"ticket_push_executor_v19.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_legacy_v19), do: {"ticket_push_executor_v19.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_legacy_v18), do: {"ticket_push_executor_v18.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_legacy_v17), do: {"ticket_push_executor_v17.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_previous), do: {"ticket_push_executor_v16.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:capability_retained), do: {"ticket_push_executor_v15.py", true, 14, "ticket_push_status_reader_v13.py"}
  defp attestation_kind(:large_current), do: {"ticket_push_executor_v14.py", true, 7, "ticket_push_status_reader_v5.py"}
  defp attestation_kind(:large_previous), do: {"ticket_push_executor_v12.py", true, 7, "ticket_push_status_reader_v5.py"}
  defp attestation_kind(:large_legacy), do: {"ticket_push_executor_v11.py", true, 7, "ticket_push_status_reader_v5.py"}
  defp attestation_kind(:release), do: {"ticket_push_executor_v8.py", true, 2, "ticket_push_status_reader_v1.py"}
  defp attestation_kind(_kind), do: {"ticket_push_executor_v3.py", false, 2, "ticket_push_status_reader_v1.py"}

  @tag readback_provenance: :valid
  test "compile-pinned accepted prior release is status-only across relocation", context do
    {intent, receipt} = recorded(context, "ticket_push_executor_v4.py", context.historical)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    execution = Jason.decode!(intent["execution_json"])
    assert {:error, :ticket_push_program_changed} = context.module.execute(execution, fn _, _ -> flunk("status provenance granted execute authority") end)
  end

  @tag readback_provenance: :valid
  test "accepted provenance still requires actual manifest, helper and companion bytes outside SOURCE", context do
    {intent, receipt} = recorded(context, "ticket_push_executor_v4.py", context.historical)
    release = context.historical |> Path.dirname() |> Path.dirname() |> Path.dirname()
    paths = [Path.join(release, "manifest.json"), Path.join(context.historical, "ticket_push_executor_v4.py"), Path.join(context.historical, "worker_file_companion.py")]

    for path <- paths do
      raw = File.read!(path)
      File.write!(path, raw <> "\nchanged\n")
      assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
      File.write!(path, raw)
      assert {:ok, ^receipt} = context.module.readback(intent)
    end

    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "root", release))
    manifest = hd(paths)
    File.rename!(manifest, manifest <> ".saved")
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
  end

  @tag readback_provenance: :legacy
  test "accepted prior legacy loader retains source-cache rejection", context do
    {intent, receipt} = recorded(context, "ticket_push_executor_v2.py", context.historical)
    assert {:ok, ^receipt} = context.module.readback(intent)
    cache = Path.join(context.historical, "worker_file_companion.pyc")
    File.write!(cache, "untrusted cache")
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
  end

  for attack <- [
        :version,
        :float_version,
        :extra_key,
        :duplicate,
        :too_many,
        :missing_entry,
        :manifest_hash,
        :helper_hash,
        :companion_hash,
        :manifest_mapping
      ] do
    @tag readback_provenance: attack
    test "historical provenance denies #{attack} without weakening current origin", context do
      {intent, _} = recorded(context, "ticket_push_executor_v4.py", context.historical)
      assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
      {current, receipt} = recorded(context, "ticket_push_executor_v3.py")
      assert {:ok, ^receipt} = context.module.readback(current)
    end
  end

  test "actual accepted v4 materialized release remains readable without execution", context do
    priv = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-push-reassessment-v4-Qz6Uesin/dev/lib/symphony_elixir/priv"
    {intent, receipt} = recorded(context, "ticket_push_executor_v4.py", priv)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
  end

  test "actual accepted session v5 release remains readable without execution", context do
    priv = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-ci-session-v1-0ea20948ab/dev/lib/symphony_elixir/priv"
    {intent, receipt} = recorded(context, "ticket_push_executor_v5.py", priv)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    execution = Jason.decode!(intent["execution_json"])
    assert {:error, :ticket_push_program_changed} = context.module.execute(execution, fn _, _ -> flunk("status provenance granted execute authority") end)
  end

  test "accepted seven-attempt v6 release remains status-only after relocation", context do
    priv = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-ci-seven-v1-dce616fc81/dev/lib/symphony_elixir/priv"
    {intent, receipt} = recorded(context, "ticket_push_executor_v6.py", priv)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    execution = Jason.decode!(intent["execution_json"])
    assert {:error, :ticket_push_program_changed} = context.module.execute(execution, fn _, _ -> flunk("historical import provenance granted execution") end)
  end

  test "exact retained verifier-repair v9 release remains status-only after relocation", context do
    priv = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-verifier-repair-v1-49bc06715d/dev/lib/symphony_elixir/priv"
    {intent, receipt} = recorded(context, "ticket_push_executor_v9.py", priv)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    assert spool_bytes(context.spool) == before
    assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("v9 readback granted new issuance") end)
  end

  test "exact deployed dashboard v11 origin remains status-only through the new reader", context do
    priv = "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-dashboard-alignment-6ff7cfd9fe5d/dev/lib/symphony_elixir/priv"
    {intent, receipt} = recorded(context, "ticket_push_executor_v11.py", priv)
    before = spool_bytes(context.spool)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
    assert spool_bytes(context.spool) == before
    assert {:error, :ticket_push_program_changed} = context.module.execute(Jason.decode!(intent["execution_json"]), fn _, _ -> flunk("old origin granted issuance") end)
  end

  @tag readback_provenance: :ordinary_layout
  test "new v3 ordinary origin rejects changed manifest and identical unregistered paths", context do
    {intent, receipt} = recorded(context, "ticket_push_executor_v9.py", context.historical)
    assert {:ok, ^receipt} = context.module.readback(intent)
    path = Path.join(context.base, "accepted-release/manifest.json")
    raw = File.read!(path)
    File.write!(path, raw <> "\n")
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
    File.write!(path, raw)
    sibling = Path.join(context.base, "unregistered-v9")
    File.mkdir_p!(sibling)
    for name <- ~w(ticket_push_executor_v9.py worker_file_companion.py), do: File.cp!(Path.join(context.historical, name), Path.join(sibling, name))
    rebound = intent |> change("helper_path", Path.join(sibling, "ticket_push_executor_v9.py")) |> change("companion_path", Path.join(sibling, "worker_file_companion.py"))
    assert {:error, :ticket_push_program_changed} = context.module.readback(rebound)
  end

  @tag readback_provenance: :dev_layout
  test "accepted dev layout still rejects manifest tampering and identical sibling helpers", context do
    {intent, receipt} = recorded(context, "ticket_push_executor_v5.py", context.historical)
    assert {:ok, ^receipt} = context.module.readback(intent)
    release = Path.join(context.base, "accepted-release")
    manifest = Path.join(release, "manifest.json")
    raw = File.read!(manifest)
    File.write!(manifest, raw <> "\n")
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
    File.write!(manifest, raw)
    sibling = Path.join(context.base, "identical-sibling")
    File.mkdir!(sibling)
    for name <- ~w(ticket_push_executor_v5.py worker_file_companion.py), do: File.cp!(Path.join(context.historical, name), Path.join(sibling, name))
    rebound = intent |> change("helper_path", Path.join(sibling, "ticket_push_executor_v5.py")) |> change("companion_path", Path.join(sibling, "worker_file_companion.py"))
    assert {:error, :ticket_push_program_changed} = context.module.readback(rebound)
    execution = Jason.decode!(intent["execution_json"])
    assert {:error, :ticket_push_program_changed} = context.module.execute(execution, fn _, _ -> flunk("dev layout granted execution authority") end)
  end

  test "current canonical v3 artifact remains an allowed status origin", context do
    {:ok, priv} = PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    {intent, receipt} = recorded(context, "ticket_push_executor_v3.py", priv)
    assert {:ok, ^receipt} = context.module.readback(intent)
    assert context.module.receipt_valid?(receipt, intent)
  end

  for name <- [
        "ticket_push_executor.py",
        "ticket_push_executor_v2.py",
        "ticket_push_executor_v3.py",
        "ticket_push_executor_v4.py",
        "ticket_push_executor_v5.py",
        "ticket_push_executor_v6.py",
        "ticket_push_executor_v7.py",
        "ticket_push_executor_v8.py",
        "ticket_push_executor_v9.py",
        "ticket_push_executor_v10.py",
        "ticket_push_executor_v11.py"
      ] do
    @name name
    test "framed status reads exact compile-origin receipt for #{@name}", context do
      priv = if @name == "ticket_push_executor_v11.py", do: elem(PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv")), 1)
      {intent, receipt} = recorded(context, @name, priv)
      assert {:ok, ^receipt} = context.module.readback(intent)
      assert context.module.receipt_valid?(receipt, intent)
      assert File.read!(Path.join(context.spool, intent["owner_nonce"] <> ".push-receipt")) == receipt
    end
  end

  test "v5 status receipt rejects malformed stderr fields and unknown extras", context do
    {intent, raw} = recorded(context, "ticket_push_executor_v5.py")
    receipt = Jason.decode!(raw)
    assert context.module.receipt_valid?(raw, intent)

    for changed <- [
          Map.delete(receipt, "stderr_code"),
          Map.put(receipt, "stderr_code", "UNPROVEN"),
          Map.put(receipt, "stderr_bytes", 16_385),
          Map.put(receipt, "stderr_bytes", true),
          Map.put(receipt, "stderr_sha256", "invalid"),
          Map.put(receipt, "unreviewed", true)
        ] do
      refute context.module.receipt_valid?(Jason.encode!(changed), intent)
    end
  end

  test "identical copies, fake releases, noncanonical aliases, and SOURCE paths are not admitted", context do
    {intent, _receipt} = recorded(context)
    execution = Jason.decode!(intent["execution_json"])
    original = execution["helper_path"]
    copy = Path.join(context.base, "sibling-release/priv/ticket_push_executor_v2.py")
    File.mkdir_p!(Path.dirname(copy))
    File.cp!(original, copy)
    alias_path = Path.join(context.base, "alias.py")
    File.ln_s!(original, alias_path)
    source_path = Path.join(context.root, "ticket_push_executor_v2.py")
    File.cp!(original, source_path)

    for path <- [copy, alias_path, Path.dirname(original) <> "/./" <> Path.basename(original), source_path] do
      assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "helper_path", path))
    end

    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "root", Path.dirname(original)))
    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "helper_sha256", String.duplicate("0", 64)))
  end

  test "companion path, canonical identity, and compile-time contents are mandatory", context do
    {intent, _receipt} = recorded(context)
    companion = Path.join(context.priv, "worker_file_companion.py")
    raw = File.read!(companion)
    copy = Path.join(context.base, "worker_file_companion.py")
    File.write!(copy, raw)
    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "companion_path", copy))
    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "companion_sha256", String.duplicate("0", 64)))
    File.write!(companion, raw <> "\n# altered\n")
    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "companion_sha256", hash(File.read!(companion))))
    File.rm!(companion)
    File.ln_s!(copy, companion)
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
  end

  test "changed or missing compile-origin helper cannot be replaced by recorded caller hashes", context do
    {intent, _receipt} = recorded(context)
    helper = Path.join(context.priv, "ticket_push_executor_v2.py")
    File.write!(helper, File.read!(helper) <> "\n# altered\n")
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
    assert {:error, :ticket_push_program_changed} = context.module.readback(change(intent, "helper_sha256", hash(File.read!(helper))))
    File.rm!(helper)
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
  end

  test "legacy loaders deny possible bytecode while v3 uses verified source", context do
    cache = Path.join(context.priv, "__pycache__/worker_file_companion.cpython-39.pyc")
    File.mkdir_p!(Path.dirname(cache))
    File.write!(cache, "untrusted bytecode")

    for name <- ["ticket_push_executor.py", "ticket_push_executor_v2.py"] do
      {intent, _receipt} = recorded(context, name)
      assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
    end

    {intent, receipt} = recorded(context, "ticket_push_executor_v3.py")
    assert {:ok, ^receipt} = context.module.readback(intent)
    File.rm!(cache)
    File.write!(Path.join(context.priv, "worker_file_companion.pyc"), "legacy bytecode")
    {intent, _receipt} = recorded(context)
    assert {:error, :ticket_push_program_changed} = context.module.readback(intent)
  end

  test "historical execution is rejected before callback or helper process", context do
    {intent, _receipt} = recorded(context)
    execution = Jason.decode!(intent["execution_json"])
    callback = fn _, _ -> flunk("historical execution must not be started") end
    assert {:error, :ticket_push_program_changed} = context.module.execute(execution, callback)
  end

  test "receipt remains exactly bound to recorded intent, candidate, nonce, pid and output", context do
    {intent, receipt} = recorded(context)
    assert context.module.receipt_valid?(receipt, intent)

    for changed <- [Map.put(intent, "owner_nonce", String.duplicate("b", 64)), Map.put(intent, "helper_pid", 101), Map.put(intent, "binding_sha256", String.duplicate("0", 64))] do
      refute context.module.receipt_valid?(receipt, changed)
    end

    binding = intent["binding_json"] |> Jason.decode!() |> Map.put("candidate_sha", String.duplicate("2", 40)) |> Jason.encode!()
    refute context.module.receipt_valid?(receipt, Map.merge(intent, %{"binding_json" => binding, "binding_sha256" => hash(binding)}))
    wrong = receipt |> Jason.decode!() |> Map.put("output_sha256", String.duplicate("0", 64)) |> Jason.encode!()
    refute context.module.receipt_valid?(wrong, intent)
    File.write!(Path.join(context.spool, intent["owner_nonce"] <> ".push-claim"), "wrong intent")
    assert {:error, :ticket_push_transport_unproven} = context.module.readback(intent)
  end

  defp recorded(context, name \\ "ticket_push_executor_v2.py", priv \\ nil) do
    helper = Path.join(priv || context.priv, name)
    companion = Path.join(priv || context.priv, "worker_file_companion.py")
    stat = File.stat!(context.spool)
    nonce = hash(name)
    binding = Jason.encode!(%{"run_id" => "synthetic-run", "candidate_sha" => String.duplicate("1", 40)})

    execution = %{
      "root" => context.root,
      "database" => context.database,
      "spool" => context.spool,
      "spool_device" => stat.major_device,
      "spool_inode" => stat.inode,
      "helper_path" => helper,
      "helper_sha256" => hash(File.read!(helper)),
      "companion_path" => companion,
      "companion_sha256" => hash(File.read!(companion)),
      "run_id" => "synthetic-run",
      "invocation" => nonce,
      "intent_json" => binding,
      "intent_sha256" => hash(binding)
    }

    encoded = Jason.encode!(execution)

    receipt = %{
      "version" => 1,
      "execution_json" => encoded,
      "helper_pid" => 100,
      "child_pid" => 200,
      "termination" => %{"kind" => "exited", "code" => 0},
      "timed_out" => false,
      "overflow" => false,
      "output_base64" => "",
      "output_sha256" => hash("")
    }

    receipt =
      if name not in ~w(ticket_push_executor.py ticket_push_executor_v2.py),
        do: Map.merge(receipt, %{"stderr_code" => "GIT_EXIT_ZERO", "stderr_bytes" => 0, "stderr_sha256" => hash("")}),
        else: receipt

    raw = Jason.encode!(receipt)
    File.write!(Path.join(context.spool, nonce <> ".push-claim"), encoded)
    File.write!(Path.join(context.spool, nonce <> ".push-receipt"), raw)
    {%{"execution_json" => encoded, "helper_pid" => 100, "owner_nonce" => nonce, "binding_json" => binding, "binding_sha256" => hash(binding)}, raw}
  end

  defp incident_shape(intent, raw) do
    base = Jason.decode!(intent["execution_json"]) |> Map.put("padding", "")
    padding_bytes = 244_044 - byte_size(Jason.encode!(base))

    receipt =
      Jason.decode!(raw)
      |> Map.put("helper_pid", 3514)
      |> Map.put("child_pid", 3670)
      |> Map.put("termination", %{"kind" => "signaled", "signal" => 9})
      |> Map.put("timed_out", true)
      |> Map.put("stderr_code", "GIT_EXIT_NONZERO")

    ascii = base |> Map.put("padding", String.duplicate("x", padding_bytes)) |> Jason.encode!()
    excess = 262_236 - byte_size(Jason.encode!(Map.put(receipt, "execution_json", ascii)))
    assert rem(excess, 2) == 0
    quotes = div(excess, 2)
    execution = base |> Map.put("padding", String.duplicate("\"", quotes) <> String.duplicate("x", padding_bytes - 2 * quotes)) |> Jason.encode!()
    {intent |> Map.put("execution_json", execution) |> Map.put("helper_pid", 3514), Jason.encode!(Map.put(receipt, "execution_json", execution))}
  end

  defp python_response_size(execution) do
    script = ~S"""
    import json,sys
    execution=json.loads(sys.argv[1]); encoded=json.dumps(execution,separators=(',',':'),ensure_ascii=False)
    pid=9223372036854775807
    terminal={'version':1,'execution_json':encoded,'helper_pid':pid,'child_pid':pid,
      'termination':{'kind':'signaled','signal':64},'timed_out':False,'overflow':False,
      'output_base64':'A'*87384,'output_sha256':'f'*64,'stderr_code':'AUTHENTICATION_DENIED',
      'stderr_bytes':16384,'stderr_sha256':'f'*64}
    rejection={'version':1,'kind':'PREISSUANCE_REJECTED','execution_json':encoded,'helper_pid':pid,'child_pid':None,'reason':'x'*80}
    print(max(len(json.dumps(item,separators=(',',':')).encode()) for item in (terminal,rejection)))
    """

    {size, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Jason.encode!(execution)])
    size |> String.trim() |> String.to_integer()
  end

  defp change(intent, key, value) do
    execution = intent["execution_json"] |> Jason.decode!() |> Map.put(key, value) |> Jason.encode!()
    Map.put(intent, "execution_json", execution)
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp historical_fixture(base, origin, attack) do
    release = Path.join(base, "accepted-release")
    build = if attack in [:dev_layout, :ordinary_layout], do: Path.join(release, "dev"), else: release
    priv = Path.join(build, "lib/symphony_elixir/priv")
    File.mkdir_p!(priv)

    helper =
      case attack do
        :legacy -> "ticket_push_executor_v2.py"
        :dev_layout -> "ticket_push_executor_v5.py"
        :ordinary_layout -> "ticket_push_executor_v9.py"
        _ -> "ticket_push_executor_v4.py"
      end

    names = [helper, "worker_file_companion.py"]
    for name <- names, do: File.cp!(Path.join(origin, name), Path.join(priv, name))
    artifact = Map.new(names, &{"lib/symphony_elixir/priv/" <> &1, %{"sha256" => hash(File.read!(Path.join(priv, &1)))}})
    artifact = if attack == :manifest_mapping, do: Map.put(artifact, "lib/symphony_elixir/priv/ticket_push_executor_v4.py", %{"sha256" => String.duplicate("0", 64)}), else: artifact
    manifest = Path.join(release, "manifest.json")
    File.write!(manifest, Jason.encode!(%{"release" => release, "artifact" => artifact}))

    entry = %{
      "manifest_path" => manifest,
      "manifest_sha256" => hash(File.read!(manifest)),
      "helper_path" => Path.join(priv, hd(names)),
      "helper_sha256" => hash(File.read!(Path.join(priv, hd(names)))),
      "companion_path" => Path.join(priv, List.last(names)),
      "companion_sha256" => hash(File.read!(Path.join(priv, List.last(names))))
    }

    entry = altered_provenance_entry(entry, attack)
    resource = %{"version" => provenance_version(attack), "entries" => provenance_entries(entry, attack)}
    name = if attack == :ordinary_layout, do: "ticket_push_readback_origins_v3.json", else: "ticket_push_readback_origins_v1.json"
    File.write!(Path.join(origin, name), Jason.encode!(resource))
    priv
  end

  defp altered_provenance_entry(entry, attack) do
    case attack do
      :manifest_hash -> Map.put(entry, "manifest_sha256", String.duplicate("0", 64))
      :helper_hash -> Map.put(entry, "helper_sha256", String.duplicate("0", 64))
      :companion_hash -> Map.put(entry, "companion_sha256", String.duplicate("0", 64))
      :extra_key -> Map.put(entry, "caller_approved", true)
      _ -> entry
    end
  end

  defp provenance_entries(entry, attack) do
    case attack do
      :duplicate -> [entry, entry]
      :too_many -> List.duplicate(entry, 9)
      :missing_entry -> []
      _ -> [entry]
    end
  end

  defp provenance_version(attack) do
    case attack do
      :version -> 2
      :float_version -> 1.0
      _ -> 1
    end
  end
end
