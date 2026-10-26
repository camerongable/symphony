defmodule SymphonyElixir.FactoryForwardPushRejectionLifecycleTest do
  use ExUnit.Case, async: false

  @tag timeout: 1_800_000
  test "private publisher retires only the audited current rejection after two closed historical contexts" do
    root = Path.join(System.tmp_dir!(), "forward-push-rejection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    source = Path.expand("../..", __DIR__)
    before = Map.new(Path.wildcard(Path.join(source, "priv/*")), &{&1, if(File.regular?(&1), do: File.read!(&1))})

    script = """
    Mix.start()
    Code.require_file(#{inspect(Path.join(source, "test/support/ordinary_push_rejection_fixture.ex"))})
    Code.require_file(#{inspect(Path.join(source, "test/support/forward_push_rejection_fixture.ex"))})
    Mix.Project.in_project(:symphony_elixir,#{inspect(source)},fn _ ->
      Mix.Task.run("loadconfig")
      SymphonyElixir.TestSupport.ForwardPushRejectionFixture.boot(#{inspect(root)},#{inspect(source)})
      Mix.Tasks.Test.run(["--no-compile","--no-deps-check","test/symphony_elixir/factory_ticket_worker_lifecycle_test.exs","--only","forward_push_rejection_child","--seed","0","--trace"])
    end)
    """

    paths = Enum.map(:code.get_path(), &List.to_string/1) |> Enum.filter(&(Path.type(&1) == :absolute))

    {output, status} =
      System.cmd(System.find_executable("elixir"), Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script], stderr_to_stdout: true, env: [{"MIX_ENV", "test"}, {"PYTHONDONTWRITEBYTECODE", "1"}])

    File.write!(Path.join(root, "child.log"), output)
    IO.puts("forward ordinary rejection child: #{root}")
    assert status == 0, output
    assert output =~ "FORWARD_REJECTION_CANONICAL_FRESH_NONCE_NO_REPLAY"
    assert output =~ "1 test, 0 failures"
    for {path, bytes} <- before, do: assert(if(File.regular?(path), do: File.read!(path)) == bytes)
  end
end
