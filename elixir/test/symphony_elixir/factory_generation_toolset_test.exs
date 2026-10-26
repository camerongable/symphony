defmodule SymphonyElixir.FactoryGenerationToolsetTest do
  use ExUnit.Case, async: true

  test "the actual compile-pinned loader denies missing and modified gate resources before execution" do
    root = Path.join(System.tmp_dir!(), "generation-toolset-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)

    reference = fn name, bytes ->
      path = Path.join(root, name)
      File.write!(path, bytes)
      %{"path" => path, "sha256" => hash(bytes)}
    end

    gate = reference.("gate", "fixture gate\n")
    shim = reference.("shim", "fixture shim\n")
    profile = reference.("profile", "fixture profile\n")
    gazelle = reference.("gazelle", "fixture gazelle\n")
    gofmt = reference.("gofmt", "fixture gofmt\n")

    config =
      reference.(
        "config",
        Jason.encode!(%{
          "gazelle_flags" => ~w(fix -repo_root=. -build_file_name=BUILD,BUILD.bazel -build_tags=bazel -r_generate_rules=true -r_roclets=namespace,rd -mode=diff),
          "gofmt_flags" => ["-d"],
          "languages" => ~w(visibility proto go r)
        })
      )

    checks =
      ~w(actual_gazelle_diff actual_gazelle_unchanged actual_gofmt_diff actual_gofmt_unchanged outside_read symlink_escape source_write network fork child_exec self_exec extra_fd missing_gate modified_gate)

    proof =
      reference.(
        "proof",
        Jason.encode!(%{
          "version" => 1,
          "protocol" => "CI_GENERATION_GATE_V1",
          "repo_key" => "fixture",
          "gitlab_project_id" => "1000",
          "programs" => %{"gazelle" => gazelle["sha256"], "gofmt" => gofmt["sha256"]},
          "gate_sha256" => gate["sha256"],
          "shim_sha256" => shim["sha256"],
          "profile_sha256" => profile["sha256"],
          "config_sha256" => config["sha256"],
          "checks" => Map.new(checks, &{&1, "PASS"})
        })
      )

    manifest = Path.join(root, "manifest.json")

    File.write!(
      manifest,
      Jason.encode!(%{
        "version" => 1,
        "available" => true,
        "protocol" => "CI_GENERATION_GATE_V1",
        "repo_key" => "fixture",
        "gitlab_project_id" => "1000",
        "gate" => gate,
        "shim" => shim,
        "profile" => profile,
        "config" => config,
        "proof" => proof,
        "programs" => %{"gazelle" => gazelle, "gofmt" => gofmt}
      })
    )

    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    source = File.read!(Path.expand("../../lib/symphony_elixir/factory/ticket_ci_generation_toolset.ex", __DIR__))

    source =
      source
      |> String.replace("defmodule SymphonyElixir.Factory.TicketCiGenerationToolset do", "defmodule #{inspect(module)} do")
      |> String.replace(~s|@manifest Path.expand("../../../priv/controller_generation_toolset_v1.json", __DIR__)|, "@manifest #{inspect(manifest)}")

    Code.compile_string(source)

    assert {:ok, _} = apply(module, :load, [])
    File.rename!(gate["path"], gate["path"] <> ".saved")
    assert {:error, :ci_repair_generator_unavailable} = apply(module, :load, [])
    File.rename!(gate["path"] <> ".saved", gate["path"])
    File.write!(gate["path"], "modified fixture gate\n")
    assert {:error, :ci_repair_generator_unavailable} = apply(module, :load, [])
    File.write!(gate["path"], "fixture gate\n")
    assert {:ok, _} = apply(module, :load, [])
    File.write!(manifest, "{}")
    assert {:error, :ci_repair_generator_unavailable} = apply(module, :load, [])
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
