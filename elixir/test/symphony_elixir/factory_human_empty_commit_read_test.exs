defmodule SymphonyElixir.FactoryHumanEmptyCommitReadTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketHumanEmptyCommitRead

  setup do
    root = Path.join(System.tmp_dir!(), "empty-child-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    git(root, ["init", "-b", "feature"])
    git(root, ["config", "user.name", "Fixture"])
    git(root, ["config", "user.email", "fixture@example.invalid"])
    File.write!(Path.join(root, "fixture"), "original\n")
    git(root, ["add", "fixture"])
    git(root, ["commit", "--no-verify", "-m", "original"])
    previous = git(root, ["rev-parse", "HEAD"])
    git(root, ["commit", "--no-verify", "--allow-empty", "-m", "human empty child"])
    candidate = git(root, ["rev-parse", "HEAD"])
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, previous: previous, candidate: candidate}
  end

  test "observes an exact one-parent empty child without changing checkout or refs", context do
    before = git(context.root, ["status", "--porcelain=v1"])
    assert {:ok, proof} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, context.candidate)
    assert proof["candidate"]["parents"] == [context.previous]
    assert proof["candidate"]["tree"] == proof["previous"]["tree"]
    assert git(context.root, ["rev-parse", "HEAD"]) == context.candidate
    assert git(context.root, ["status", "--porcelain=v1"]) == before
  end

  test "changed tree is rejected", context do
    File.write!(Path.join(context.root, "fixture"), "changed\n")
    git(context.root, ["add", "fixture"])
    git(context.root, ["commit", "--no-verify", "-m", "changed tree"])
    changed = git(context.root, ["rev-parse", "HEAD"])
    assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe(context.root, context.candidate, changed)
  end

  test "equal trees do not admit a grandchild or identical commit", context do
    git(context.root, ["commit", "--no-verify", "--allow-empty", "-m", "another empty child"])
    grandchild = git(context.root, ["rev-parse", "HEAD"])

    for candidate <- [context.previous, grandchild] do
      assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, candidate)
    end
  end

  test "merge with equal tree is not a one-parent child", context do
    tree = git(context.root, ["rev-parse", "HEAD^{tree}"])
    merge = git(context.root, ["commit-tree", tree, "-p", context.previous, "-p", context.candidate, "-m", "merge"])
    assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, merge)
  end

  test "options refs invalid roots and missing objects are rejected", context do
    for candidate <- ["HEAD", "--help", "#{context.candidate}^", String.duplicate("f", 40), nil] do
      assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, candidate)
    end

    assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe("relative", context.previous, context.candidate)
  end

  test "replacement refs cannot hide a changed tree", context do
    File.write!(Path.join(context.root, "fixture"), "changed\n")
    git(context.root, ["add", "fixture"])
    git(context.root, ["commit", "--no-verify", "-m", "changed tree"])
    changed = git(context.root, ["rev-parse", "HEAD"])
    git(context.root, ["replace", changed, context.candidate])
    assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, changed)
  end

  test "repository display configuration cannot add notes to the proof", context do
    git(context.root, ["notes", "add", "-m", "not object identity", context.candidate])
    git(context.root, ["config", "log.showNotes", "true"])
    git(context.root, ["config", "log.showSignature", "true"])
    assert {:ok, _} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, context.candidate)
  end

  test "legacy grafts cannot make a grandchild appear to be the immediate child", context do
    git(context.root, ["commit", "--no-verify", "--allow-empty", "-m", "grandchild"])
    grandchild = git(context.root, ["rev-parse", "HEAD"])
    File.mkdir_p!(Path.join(context.root, ".git/info"))
    File.write!(Path.join(context.root, ".git/info/grafts"), "#{grandchild} #{context.previous}\n")
    assert {:error, :human_empty_child_objects_unproven} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, grandchild)
    assert {:ok, _} = TicketHumanEmptyCommitRead.observe(context.root, context.previous, context.candidate)
  end

  defp git(root, args) do
    {output, 0} = System.cmd("/Library/Developer/CommandLineTools/usr/bin/git", ["-C", root | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
