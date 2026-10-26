defmodule SymphonyElixir.FactoryGenerationOriginLifecycleTest do
  use ExUnit.Case, async: false

  @tag generation_origin_recovery: true, timeout: 1_800_000
  test "sealed release transition preserves generation journals and retires one exact rejected push" do
    run_child("push_origin_recovery_child")
  end

  @tag generation_origin_fixture: true, timeout: 180_000
  test "child selects its physical artifact before native dispatch" do
    output = run_child("push_origin_fixture")
    assert output =~ "GENERATION_ORIGIN_BEFORE_FIRST_DISPATCH_PRIVATE_A"
  end

  defp run_child(selector) do
    root = Path.join(System.tmp_dir!(), "generation-origin-child-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    source = Path.expand("../..", __DIR__)
    baseline = "/Users/cgable/Library/Application Support/ai-factory/source-snapshots/symphony-push-budget-dd26f8683c53"
    before = Map.new(Path.wildcard(Path.join(source, "priv/*")), &{&1, if(File.regular?(&1), do: File.read!(&1))})

    script = """
    Mix.start()
    Code.require_file(#{inspect(Path.join(source, "test/support/generation_origin_release.ex"))})
    Application.put_env(:symphony_elixir,:generation_origin_release_baseline,#{inspect(baseline)})
    Mix.Project.in_project(:symphony_elixir,#{inspect(source)},fn _ ->
      Mix.Task.run("loadconfig")
      SymphonyElixir.TestSupport.GenerationOriginRelease.boot(#{inspect(root)},#{inspect(source)})
      Mix.Tasks.Test.run(["--no-compile","--no-deps-check","test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs","--only",#{inspect(selector)},"--seed","0","--trace"])
    end)
    """

    paths = Enum.map(:code.get_path(), &List.to_string/1) |> Enum.filter(&(Path.type(&1) == :absolute))

    {output, status} =
      System.cmd(System.find_executable("elixir"), Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"PYTHONDONTWRITEBYTECODE", "1"}, {"RETAIN_PUSH_PACKET_FIXTURE", "1"}]
      )

    File.write!(Path.join(root, "child.log"), output)
    IO.puts("retained cross-release child: #{root}")
    assert status == 0, output

    if selector == "push_origin_recovery_child" do
      assert output =~ "GENERATION_ORIGIN_PHYSICAL_BOUNDARY_A_TO_B"
      assert output =~ "GENERATION_ORIGIN_EXACT_SYNTHETIC_AUDIT_INSTALLED"
      assert output =~ "GENERATION_ORIGIN_PHYSICAL_BOUNDARY_B_TO_C"
    end

    assert output =~ "1 test, 0 failures"
    for {path, bytes} <- before, do: assert(if(File.regular?(path), do: File.read!(path)) == bytes)
    output
  end
end
