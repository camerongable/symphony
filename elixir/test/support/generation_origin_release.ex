defmodule SymphonyElixir.TestSupport.GenerationOriginRelease do
  @moduledoc "Private three-release fixtures; production code and artifact files remain unchanged."
  import ExUnit.Assertions

  def boot(root, source) do
    original = Application.app_dir(:symphony_elixir)
    a = Path.join(root, "sealed-a")
    b = Path.join(root, "sealed-b")
    c = Path.join(root, "sealed-c")

    for release <- [a, b, c] do
      app = app(release)
      File.mkdir_p!(app)
      File.cp_r!(Path.join(original, "priv"), Path.join(app, "priv"), dereference_symlinks: true)
      File.cp_r!(Path.join(original, "ebin"), Path.join(app, "ebin"), dereference_symlinks: true)
    end

    manifest = %{
      "kind" => "TEST_SEALED_GENERATION_RELEASE_V1",
      "release" => a,
      "artifact" =>
        Map.new(Enum.filter(Path.wildcard(Path.join(app(a), "priv/*")), &File.regular?/1), fn path -> {"lib/symphony_elixir/priv/" <> Path.basename(path), %{"sha256" => digest(File.read!(path))}} end)
    }

    File.mkdir_p!(Path.join(a, "evidence"))
    File.write!(Path.join(a, "evidence/release-manifest.json"), Jason.encode!(manifest))
    Application.put_env(:symphony_elixir, :generation_origin_release_fixture, %{a: a, b: b, c: c, source: source})
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app(a), "ebin")))
    compile_old_io(a)
  end

  def activate_a do
    fixture = Application.fetch_env!(:symphony_elixir, :generation_origin_release_fixture)
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app(fixture.a), "ebin")))
    assert Application.app_dir(:symphony_elixir) == app(fixture.a)
    compile_old_io(fixture.a)
    assert_origin(fixture.a)
  end

  def assert_origin(release) do
    assert Application.app_dir(:symphony_elixir) == app(release)
    {:ok, priv} = SymphonyElixir.PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))
    assert priv == Path.join(app(release), "priv")
  end

  def cross_boundary do
    fixture = Application.fetch_env!(:symphony_elixir, :generation_origin_release_fixture)
    a = fixture.a
    b = fixture.b
    manifest = Path.join(a, "evidence/release-manifest.json")
    priv = Path.join(app(b), "priv")
    generation_path = Path.join(priv, "ticket_generation_origins_v1.json")
    generation = Jason.decode!(File.read!(generation_path))

    entries =
      for version <- [2, 3] do
        %{
          "kind" => "RELEASE_GENERATION_ARTIFACT_V1",
          "release_root" => a,
          "manifest_path" => manifest,
          "manifest_sha256" => digest(File.read!(manifest)),
          "manifest_kind" => "TEST_SEALED_GENERATION_RELEASE_V1",
          "helper_path" => Path.join(app(a), "priv/controller_generation_executor_v#{version}.py"),
          "helper_sha256" => digest(File.read!(Path.join(app(a), "priv/controller_generation_executor_v#{version}.py"))),
          "companion_path" => Path.join(app(a), "priv/worker_file_companion.py"),
          "companion_sha256" => digest(File.read!(Path.join(app(a), "priv/worker_file_companion.py")))
        }
      end

    File.write!(generation_path, Jason.encode!(Map.update!(generation, "entries", &(&1 ++ entries))))
    replace_digest(priv, "ticket_push_history_validator_v10.py", "GENERATION_ORIGINS_SHA = '", digest(File.read!(generation_path)))

    origins_path = Path.join(priv, "ticket_push_readback_origins_v6.json")
    origins = Jason.decode!(File.read!(origins_path))
    helper = Path.join(app(a), "priv/ticket_push_executor_v12.py")
    companion = Path.join(app(a), "priv/worker_file_companion.py")

    entry = %{
      "kind" => "RELEASE_ARTIFACT_V2",
      "release_root" => a,
      "expected_manifest_kind" => "TEST_SEALED_GENERATION_RELEASE_V1",
      "manifest_path" => manifest,
      "manifest_sha256" => digest(File.read!(manifest)),
      "helper_path" => helper,
      "helper_sha256" => digest(File.read!(helper)),
      "companion_path" => companion,
      "companion_sha256" => digest(File.read!(companion)),
      "artifact_helper_path" => helper,
      "artifact_companion_path" => companion
    }

    File.write!(origins_path, Jason.encode!(Map.update!(origins, "entries", &(&1 ++ [entry]))))
    old_hash = digest(File.read!(Path.join(app(a), "priv/ticket_push_readback_origins_v6.json")))
    new_hash = digest(File.read!(origins_path))
    replace_exact(Path.join(priv, "ticket_push_status_reader_v4.py"), old_hash, new_hash, 1)
    replace_exact(Path.join(priv, "ticket_push_history_validator_v10.py"), old_hash, new_hash, 1)
    old_origins_path = Path.join(priv, "ticket_push_readback_origins_v5.json")
    old_origins_raw = File.read!(old_origins_path)
    old_origins = Jason.decode!(old_origins_raw)
    File.write!(old_origins_path, Jason.encode!(Map.update!(old_origins, "entries", &(&1 ++ [entry]))))
    replace_exact(Path.join(priv, "ticket_push_status_reader_v3.py"), digest(old_origins_raw), digest(File.read!(old_origins_path)), 1)
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app(b), "ebin")))
    compile_old_io(b)
    assert_origin(b)
    IO.puts("GENERATION_ORIGIN_PHYSICAL_BOUNDARY_A_TO_B")
  end

  def install_audited_rejection(run, intent, raw, expected_remote) do
    fixture = Application.fetch_env!(:symphony_elixir, :generation_origin_release_fixture)
    b_priv = Path.join(app(fixture.b), "priv")
    b_manifest = Path.join(fixture.b, "evidence/release-manifest.json")
    File.mkdir_p!(Path.dirname(b_manifest))
    artifact = Map.new(Enum.filter(Path.wildcard(Path.join(b_priv, "*")), &File.regular?/1), &{"lib/symphony_elixir/priv/" <> Path.basename(&1), %{"sha256" => digest(File.read!(&1))}})
    File.write!(b_manifest, Jason.encode!(%{"kind" => "TEST_SEALED_GENERATION_RELEASE_V1", "release" => fixture.b, "artifact" => artifact}))
    priv = Path.join(app(fixture.c), "priv")
    for path <- Path.wildcard(Path.join(b_priv, "*")), File.regular?(path), do: File.cp!(path, Path.join(priv, Path.basename(path)))
    origins_path = Path.join(priv, "ticket_push_readback_origins_v6.json")
    origins_raw = File.read!(origins_path)
    origins = Jason.decode!(origins_raw)
    helper = Path.join(b_priv, "ticket_push_executor_v12.py")
    companion = Path.join(b_priv, "worker_file_companion.py")

    entry = %{
      "kind" => "RELEASE_ARTIFACT_V2",
      "release_root" => fixture.b,
      "expected_manifest_kind" => "TEST_SEALED_GENERATION_RELEASE_V1",
      "manifest_path" => b_manifest,
      "manifest_sha256" => digest(File.read!(b_manifest)),
      "helper_path" => helper,
      "helper_sha256" => digest(File.read!(helper)),
      "companion_path" => companion,
      "companion_sha256" => digest(File.read!(companion)),
      "artifact_helper_path" => helper,
      "artifact_companion_path" => companion
    }

    File.write!(origins_path, Jason.encode!(Map.update!(origins, "entries", &(&1 ++ [entry]))))
    replace_exact(Path.join(priv, "ticket_push_status_reader_v4.py"), digest(origins_raw), digest(File.read!(origins_path)), 1)
    replace_exact(Path.join(priv, "ticket_push_history_validator_v10.py"), digest(origins_raw), digest(File.read!(origins_path)), 1)
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app(fixture.c), "ebin")))
    audit_path = Path.join(priv, "ticket_push_rejection_v3.json")
    old_hash = digest(File.read!(audit_path))
    execution = Jason.decode!(intent["execution_json"])

    audit =
      Map.merge(
        Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256)),
        Map.merge(Map.take(run, ~w(run_id candidate_sha contract_sha256 code_repair_round)), %{
          "version" => 1,
          "kind" => "AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED",
          "original_nonce" => intent["owner_nonce"],
          "original_sha256" => digest(run["candidate_handoff"]),
          "execution_sha256" => digest(intent["execution_json"]),
          "helper_pid" => intent["helper_pid"],
          "rejection_sha256" => digest(raw),
          "reason" => "ci_evidence_successor_changed",
          "expected_remote_sha" => expected_remote
        })
      )

    File.write!(audit_path, Jason.encode!(audit))
    replace_exact(Path.join(priv, "ticket_push_history_validator_v10.py"), old_hash, digest(File.read!(audit_path)), 1)

    for file <- ["ticket_push_io.ex", "ticket_push_preissuance_rejection.ex"] do
      source = Path.join(fixture.source, "lib/symphony_elixir/factory/" <> file)
      filename = Path.join(app(fixture.c), "lib/symphony_elixir/factory/" <> file)
      File.mkdir_p!(Path.dirname(filename))
      Code.compile_string(File.read!(source), filename)
    end

    IO.puts("GENERATION_ORIGIN_EXACT_SYNTHETIC_AUDIT_INSTALLED")
    assert_origin(fixture.c)
    assert execution["companion_path"] == Path.join(b_priv, "worker_file_companion.py")
    refute execution["companion_path"] == Path.join(priv, "worker_file_companion.py")
    IO.puts("GENERATION_ORIGIN_PHYSICAL_BOUNDARY_B_TO_C")
  end

  defp compile_old_io(release) do
    baseline = Application.fetch_env!(:symphony_elixir, :generation_origin_release_baseline)
    source = Path.join(baseline, "elixir/lib/symphony_elixir/factory/ticket_push_io.ex")
    filename = Path.join(app(release), "lib/symphony_elixir/factory/ticket_push_io.ex")
    File.mkdir_p!(Path.dirname(filename))
    Code.compile_string(File.read!(source), filename)
  end

  defp replace_digest(priv, file, prefix, new_hash) do
    path = Path.join(priv, file)
    [_, old_hash] = Regex.run(~r/#{Regex.escape(prefix)}([0-9a-f]{64})/, File.read!(path))
    replace_exact(path, old_hash, new_hash, 1)
  end

  defp replace_exact(path, old, new, count) do
    raw = File.read!(path)
    assert length(String.split(raw, old)) - 1 == count
    changed = String.replace(raw, old, new)
    assert String.replace(changed, new, old) == raw
    File.write!(path, changed)
  end

  defp app(release), do: Path.join(release, "dev/lib/symphony_elixir")
  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
