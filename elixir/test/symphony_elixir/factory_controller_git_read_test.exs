defmodule SymphonyElixir.FactoryControllerGitReadTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.ControllerGitRead

  setup do
    root = Path.join(System.tmp_dir!(), "controller-git-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_, 0} = git(root, ["init"])
    {_, 0} = git(root, ["remote", "add", "origin", "ssh://fixture.invalid/repository.git"])
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "rejects source-changing commands and remote wildcard readback", %{root: root} do
    for arguments <- [["push", "origin", "HEAD"], ["ls-remote", "--refs", "origin", "refs/heads/*"], ["ls-remote", "--refs", "origin", "refs/heads/fixture", "extra"]] do
      assert {:error, _} = ControllerGitRead.run(root, arguments)
    end
  end

  test "an unencodable filesystem path fails closed and releases its owned port" do
    owned_ports = fn -> Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, self()})) |> Enum.sort() end
    before = owned_ports.()
    assert {:error, :controller_git_read_unproven} = ControllerGitRead.run(<<255>>, ["remote", "get-url", "--all", "origin"])
    assert owned_ports.() == before
  end

  test "fixed Git is independent of an ambient PATH substitute", %{root: root} do
    substitute = Path.join(root, "git")
    marker = Path.join(root, "substitute-invoked")
    File.write!(substitute, "#!/bin/sh\n/usr/bin/touch '#{marker}'\nprintf 'forged\\n'\n")
    File.chmod!(substitute, 0o700)
    helper = Application.app_dir(:symphony_elixir, "priv/controller_git_read.py")

    input =
      Jason.encode!(%{
        "root" => root,
        "arguments" => ["remote", "get-url", "--all", "origin"],
        "environment" => %{"HOME" => System.user_home!(), "PATH" => root, "LC_ALL" => "C", "GIT_TERMINAL_PROMPT" => "0"}
      })

    port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, args: Enum.map(["-I", "-S", "-B", helper], &String.to_charlist/1)])

    try do
      Port.command(port, <<byte_size(input)::unsigned-big-32, input::binary>>)
      assert_receive {^port, {:data, raw}}, 5_000
      assert Jason.decode!(raw) == %{"status" => "PASS", "output" => "ssh://fixture.invalid/repository.git\n"}
      assert_receive {^port, {:exit_status, 0}}, 5_000
    after
      if Port.info(port), do: Port.close(port)
    end

    code = "IO.inspect(SymphonyElixir.Factory.Worktree.read_remote_branch(%{\"path\" => #{inspect(root)}}, \"bad*\"))"

    {output, 0} =
      System.cmd(System.find_executable("mix"), ["run", "--no-compile", "--no-start", "-e", code], env: [{"MIX_ENV", "test"}, {"PATH", root <> ":" <> System.get_env("PATH")}], stderr_to_stdout: true)

    assert output =~ ":native_branch_invalid"
    refute File.exists?(marker)
  end

  test "slow transport is bounded and its child is reaped", %{root: root} do
    pid_file = Path.join(root, "transport.pid")
    transport = Path.join(root, "transport")
    File.write!(transport, "#!/bin/sh\necho $$ > '#{pid_file}'\nexec /bin/sleep 60\n")
    File.chmod!(transport, 0o700)
    {_, 0} = git(root, ["config", "core.sshCommand", transport])
    start = System.monotonic_time(:millisecond)
    assert {:error, :controller_git_read_timeout} = ControllerGitRead.run(root, ["ls-remote", "--refs", "origin", "refs/heads/fixture"])
    assert System.monotonic_time(:millisecond) - start < 15_000
    pid = File.read!(pid_file) |> String.trim()
    {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "exited transport cannot leave redirected descendants alive", %{root: root} do
    pid_file = Path.join(root, "descendants.pid")
    transport = Path.join(root, "transport")
    File.write!(transport, "#!/bin/sh\n/bin/sleep 60 </dev/null >/dev/null 2>&1 &\necho $! >> '#{pid_file}'\nexit 1\n")
    File.chmod!(transport, 0o700)
    {_, 0} = git(root, ["config", "core.sshCommand", transport])
    assert {:error, :controller_git_read_failed} = ControllerGitRead.run(root, ["ls-remote", "--refs", "origin", "refs/heads/fixture"])

    for pid <- String.split(File.read!(pid_file), "\n", trim: true) do
      {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end
  end

  defp git(root, arguments),
    do: System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", root | arguments], stderr_to_stdout: true)
end
