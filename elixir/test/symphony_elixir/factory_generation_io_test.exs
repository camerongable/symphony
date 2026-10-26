defmodule SymphonyElixir.FactoryGenerationIOTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../../priv/controller_generation_io_v1.py", __DIR__)
  @generation_fixture_available match?({:ok, %{"gitlab_project_id" => "1000"}}, SymphonyElixir.Factory.TicketCiGenerationToolset.load())

  setup do
    root = Path.join(System.tmp_dir!(), "generation-io-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "pkg"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    %{root: root}
  end

  test "descriptor-relative observations retain exact bytes and never change source", %{root: root} do
    path = Path.join(root, "pkg/file.go")
    File.write!(path, "package test\n")
    assert {raw, 0} = observe(root, ["pkg/file.go"])
    assert {:ok, %{"version" => 1, "files" => [file]}} = Jason.decode(raw)
    assert file["path"] == "pkg/file.go"
    assert Base.decode64!(file["bytes_base64"]) == "package test\n"
    assert file["sha256"] == digest("package test\n")
    assert is_integer(file["inode"])
    assert File.read!(path) == "package test\n"
    File.write!(path, "package changed\n")
    assert {changed, 0} = observe(root, ["pkg/file.go"])
    refute Jason.decode!(changed) == Jason.decode!(raw)
  end

  test "symlink components, nonregular inputs, traversal and aggregate limits fail closed", %{root: root} do
    File.write!(Path.join(root, "pkg/file.go"), "package test\n")
    File.ln_s!("/etc/passwd", Path.join(root, "pkg/escape.go"))
    File.ln_s!(Path.join(root, "pkg"), Path.join(root, "linked"))
    File.write!(Path.join(root, "pkg/huge.go"), :binary.copy("x", 1_048_577))

    for paths <- [["pkg/escape.go"], ["linked/file.go"], ["pkg"], ["../etc/passwd"], ["pkg/-flag"], ["pkg/huge.go"], ["pkg/file.go", "pkg/file.go"]] do
      assert {raw, 1} = observe(root, paths)
      assert Jason.decode!(raw) == %{"error" => "GENERATION_INPUT_UNPROVEN"}
      refute raw =~ "root:"
    end
  end

  @tag external_toolset: true, skip: not @generation_fixture_available
  test "simultaneously readable Gazelle stdout is buffered before the separately delivered READY frame", %{root: root} do
    {:ok, toolset} = SymphonyElixir.Factory.TicketCiGenerationToolset.load()
    File.write!(Path.join(root, "job.go"), "package job\nvar x=1\n")
    File.write!(Path.join(root, "go.mod"), "module example.invalid/job\n\ngo 1.27\n")
    File.write!(Path.join(root, "WORKSPACE"), "")
    File.write!(Path.join(root, "BUILD"), "")
    helper = Path.expand("../../priv/controller_generation_executor_v1.py", __DIR__)

    script = ~S"""
    import json,pathlib,selectors,sys,tempfile,time,types
    path=pathlib.Path(sys.argv[1]).resolve();m=types.ModuleType("generation");m.__file__=str(path)
    exec(compile(path.read_bytes(),str(path),"exec"),m.__dict__)
    root=sys.argv[2];toolset=json.loads(sys.argv[3]);original=selectors.DefaultSelector
    state={"configured":False,"forced":False};write=m.os.write
    def config_write(fd,raw):
      if root.encode() in raw: state["configured"]=True
      return write(fd,raw)
    m.os.write=config_write
    class Reordered:
      def __init__(self): self.inner=original();self.registered=[]
      def register(self,fd,events): self.registered.append(fd);return self.inner.register(fd,events)
      def unregister(self,fd): return self.inner.unregister(fd)
      def get_map(self): return self.inner.get_map()
      def close(self): return self.inner.close()
      def select(self,timeout):
        found=self.inner.select(timeout)
        if state["configured"] and not state["forced"]:
          pending={key.fd:(key,event) for key,event in found};deadline=time.monotonic()+1
          while self.registered[0] not in pending and time.monotonic()<deadline:
            for key,event in self.inner.select(.01): pending[key.fd]=(key,event)
            time.sleep(.001)
          if self.registered[0] in pending and self.registered[2] in pending:
            state["forced"]=True
            return sorted(pending.values(),key=lambda item:0 if item[0].fd==self.registered[0] else 1)
        return found
    m.selectors.DefaultSelector=Reordered
    with tempfile.TemporaryDirectory(prefix="generation-reorder-empty-") as bootstrap:
      receipt=m.tool_diff({"toolset":toolset,"operation":"GAZELLE_DIFF","root":root,"paths":["BUILD"]},"",b"",bootstrap,lambda:None)
    assert state["forced"]
    assert receipt["exit_code"]==1 and receipt["pid"]>0
    assert pathlib.Path(root,"BUILD").read_bytes()==b""
    print("stdout_before_READY_delivery=PROVEN; actual_gazelle=PASS; source_write=ABSENT")
    """

    assert {"stdout_before_READY_delivery=PROVEN; actual_gazelle=PASS; source_write=ABSENT\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, helper, root, Jason.encode!(toolset)], stderr_to_stdout: true)
  end

  defp observe(root, paths) do
    System.cmd(System.find_executable("python3"), [@helper, "observe", root, Jason.encode!(paths)], stderr_to_stdout: true)
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
