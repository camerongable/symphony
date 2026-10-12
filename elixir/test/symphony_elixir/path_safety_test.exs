defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PathSafety

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-path-safety-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, canonical_root} = PathSafety.canonicalize(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, canonical_root: canonical_root}
  end

  test "cyclic symlink targets return the canonicalize ELOOP result", %{root: root} do
    self_link = Path.join(root, "self-link")
    assert :ok = File.ln_s(self_link, self_link)

    first_link = Path.join(root, "first-link")
    second_link = Path.join(root, "second-link")
    assert :ok = File.ln_s(second_link, first_link)
    assert :ok = File.ln_s(first_link, second_link)

    expanding_link = Path.join(root, "expanding-link")
    assert :ok = File.ln_s(Path.join(expanding_link, "child"), expanding_link)

    paths = [self_link, first_link, expanding_link]
    results = Enum.map(paths, &{&1, canonicalize_bounded(&1)})
    expected = Enum.map(paths, &{&1, {:error, {:path_canonicalize_failed, Path.expand(&1), :eloop}}})

    assert results == expected
  end

  test "relative, absolute, and repeated finite symlink aliases canonicalize", %{root: root, canonical_root: canonical_root} do
    target = Path.join(root, "target")
    File.mkdir_p!(target)

    relative_link = Path.join(root, "relative-link")
    assert :ok = File.ln_s("target", relative_link)
    absolute_link = Path.join(root, "absolute-link")
    assert :ok = File.ln_s(target, absolute_link)

    repeated_link = Path.join(root, "repeated-link")
    assert :ok = File.ln_s(".", repeated_link)
    repeated_path = Path.join([repeated_link, "repeated-link", "missing-tail", "file"])

    canonical_target = Path.join(canonical_root, "target")
    assert {:ok, ^canonical_target} = PathSafety.canonicalize(relative_link)
    assert {:ok, ^canonical_target} = PathSafety.canonicalize(absolute_link)
    repeated_expected = Path.join(canonical_root, "missing-tail/file")
    assert {:ok, ^repeated_expected} = PathSafety.canonicalize(repeated_path)
  end

  test "dangling tails, file targets, and nested target aliases preserve path semantics", %{
    root: root,
    canonical_root: canonical_root
  } do
    dangling = Path.join(root, "dangling")
    assert :ok = File.ln_s("missing-target", dangling)
    dangling_expected = Path.join(canonical_root, "missing-target/tail")
    assert {:ok, ^dangling_expected} = PathSafety.canonicalize(Path.join(dangling, "tail"))

    file_target = Path.join(root, "plain-file")
    File.write!(file_target, "file")
    file_link = Path.join(root, "file-link")
    assert :ok = File.ln_s("plain-file", file_link)
    file_child = Path.join(file_link, "child")
    assert {:error, {:path_canonicalize_failed, ^file_child, :enotdir}} = PathSafety.canonicalize(file_child)

    alias_link = Path.join(root, "alias-link")
    assert :ok = File.ln_s(".", alias_link)
    subdirectory = Path.join(root, "subdirectory")
    File.mkdir_p!(subdirectory)
    assert :ok = File.ln_s("../alias-link", Path.join(subdirectory, "alias-link"))
    nested_link = Path.join(root, "nested-link")
    assert :ok = File.ln_s("alias-link/subdirectory", nested_link)

    nested_expected = Path.join(canonical_root, "missing-file")

    assert {:ok, ^nested_expected} =
             PathSafety.canonicalize(Path.join([nested_link, "alias-link", "missing-file"]))
  end

  defp canonicalize_bounded(path) do
    task = Task.async(fn -> PathSafety.canonicalize(path) end)

    case Task.yield(task, 2_000) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:task_exit, reason}

      nil ->
        Task.shutdown(task, :brutal_kill)
        refute Process.alive?(task.pid)
        :did_not_return
    end
  end
end
