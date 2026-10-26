defmodule ReviewReportReleaseBootGuard do
  @moduledoc false

  def load(manifest_path, manifest_sha) do
    nil = Process.whereis(SymphonyElixir.Factory.ControlServer)
    raw = File.read!(manifest_path)
    true = sha(raw) == manifest_sha
    manifest = Jason.decode!(raw)
    "FACTORY_REVIEW_REPORT_RELEASE_V1" = manifest["kind"]
    build = manifest["build"]
    true = System.get_env("MIX_BUILD_PATH") == build
    app = Path.join(build, "lib/symphony_elixir")
    true = Application.app_dir(:symphony_elixir) == app

    for {relative, expected} <- manifest["source_hashes"] do
      true = sha(File.read!(Path.join(manifest["source_root"], relative))) == expected
    end

    for {relative, expected} <- manifest["artifact"] do
      true = sha(File.read!(Path.join(build, relative))) == expected["sha256"]
    end

    expected_paths = Enum.map(manifest["compiled_origins"], &Path.join(build, &1["path"])) |> Enum.sort()
    true = Enum.sort(Path.wildcard(Path.join(app, "ebin/*.beam"))) == expected_paths

    for origin <- manifest["compiled_origins"] do
      path = Path.join(build, origin["path"])
      bytes = File.read!(path)
      true = sha(bytes) == manifest["artifact"][origin["path"]]["sha256"]
      {:ok, {module, md5}} = :beam_lib.md5(bytes)
      true = Atom.to_string(module) == origin["module"]
      source = Path.join(manifest["source_root"], origin["source"])
      {:ok, {^module, [compile_info: info]}} = :beam_lib.chunks(bytes, [:compile_info])
      true = to_string(info[:source]) == source
      true = manifest["source_hashes"][origin["source"]] == sha(File.read!(source))

      case :code.is_loaded(module) do
        false -> {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bytes)
        {:file, loaded_path} -> true = to_string(loaded_path) == path
      end

      true = module.module_info(:md5) == md5
      true = to_string(module.module_info(:compile)[:source]) == source
      {:file, loaded_path} = :code.is_loaded(module)
      true = to_string(loaded_path) == path
    end

    factories = Enum.filter(manifest["compiled_origins"], &String.starts_with?(&1["module"], "Elixir.SymphonyElixir.Factory."))
    true = length(factories) == map_size(manifest["factory_modules"])

    digests = for origin <- Enum.sort_by(factories, & &1["module"]) do
      name = origin["module"]
      module = String.to_existing_atom(name)
      {^module, object, path} = :code.get_object_code(module)
      true = to_string(path) == Path.join(build, origin["path"])
      true = sha(object) == manifest["factory_modules"][name]
      {name, :crypto.hash(:sha256, object)}
    end

    loaded_factories = :code.all_loaded()
      |> Enum.map(fn {module, _path} -> Atom.to_string(module) end)
      |> Enum.filter(&String.starts_with?(&1, "Elixir.SymphonyElixir.Factory."))
      |> Enum.sort()
    true = loaded_factories == Enum.sort(Map.keys(manifest["factory_modules"]))
    true = sha(:erlang.term_to_binary(digests)) == manifest["factory_beam_fingerprint"]
    nil = Process.whereis(SymphonyElixir.Factory.ControlServer)
    :ok
  end

  defp sha(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
