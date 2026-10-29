defmodule SymphonyElixir.FactoryNativeRuntimeRouteTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Factory.NativeRuntimeRoute

  @tag :native_worker_binding
  test "origin format validation is pure and does not require retained directories to still exist" do
    origin = %{
      "version" => 2,
      "codex_home" => %{"path" => "/nonexistent-retained-codex-origin", "device" => [1, 2], "inode" => 3, "uid" => 0},
      "sqlite_home" => %{"path" => "/nonexistent-retained-sqlite-origin", "device" => [1, 2], "inode" => 4, "uid" => 0}
    }

    assert :ok = NativeRuntimeRoute.validate_origin_format(origin)

    for bad <- [
          Map.put(origin, "version", 2.0),
          Map.put(origin, "extra", false),
          put_in(origin, ["codex_home", "uid"], true),
          put_in(origin, ["sqlite_home", "device"], [1]),
          put_in(origin, ["codex_home", "path"], "relative"),
          put_in(origin, ["codex_home", "path"], "/private/../different"),
          put_in(origin, ["sqlite_home", "path"], "/control\u0085")
        ] do
      assert {:error, :native_runtime_origin_invalid} = NativeRuntimeRoute.validate_origin_format(bad)
    end
  end

  @tag :durable_origin
  test "durable origins strictly preserve independent filesystem identity and canonical paths" do
    with_private_route(fn ctx ->
      assert {:ok, route} = NativeRuntimeRoute.validate(ctx.descriptor)
      assert {:ok, envelope} = NativeRuntimeRoute.origin(route)

      for key <- ["codex_home", "sqlite_home"] do
        stat = File.stat!(ctx.descriptor[key])
        assert envelope[key] == %{"path" => ctx.descriptor[key], "device" => [stat.major_device, stat.minor_device], "inode" => stat.inode, "uid" => stat.uid}
      end

      assert envelope["version"] === 2

      for bad <- [nil, [], "origin", %{}, Map.put(envelope, "extra", nil)] ++ Enum.map([nil, false, true, 1, 2.0, "2", 3], &Map.put(envelope, "version", &1)) do
        assert {:error, :native_runtime_origin_invalid} = NativeRuntimeRoute.restore_origin(bad)
      end

      for key <- ["codex_home", "sqlite_home"] do
        directory = envelope[key]
        malformed = [nil, [], "path", %{}, Map.put(directory, "extra", nil), Map.delete(directory, "uid")]

        malformed =
          malformed ++
            for {field, values} <- [
                  {"device", [nil, [], [1], [1, 2, 3], [-1, 2], [1.0, 2], [true, 2], [1, "2"]]},
                  {"inode", [nil, false, 0, -1, 1.0, "1"]},
                  {"uid", [nil, true, -1, 1.0, "1"]},
                  {"path", [nil, false, "", "relative", <<255>>, directory["path"] <> "/."]}
                ],
                value <- values,
                do: Map.put(directory, field, value)

        for bad <- malformed do
          assert {:error, :native_runtime_origin_invalid} = NativeRuntimeRoute.restore_origin(Map.put(envelope, key, bad))
        end

        for {field, changed} <- [{"device", [0, 0]}, {"inode", directory["inode"] + 1}, {"uid", directory["uid"] + 1}] do
          assert {:error, :native_runtime_storage_changed} = NativeRuntimeRoute.restore_origin(put_in(envelope, [key, field], changed))
        end

        alias_path = directory["path"] <> "-alias"
        File.ln_s!(directory["path"], alias_path)
        assert {:ok, ^route} = NativeRuntimeRoute.validate(Map.put(ctx.descriptor, key, alias_path))
        assert {:error, :native_runtime_origin_invalid} = NativeRuntimeRoute.restore_origin(put_in(envelope, [key, "path"], alias_path))
      end
    end)
  end

  @tag :durable_origin
  test "a JSON-roundtripped origin restores the same directories and refuses replacement at either path" do
    with_private_route(fn ctx ->
      assert {:ok, route} = NativeRuntimeRoute.validate(ctx.descriptor)
      assert {:ok, envelope} = apply(NativeRuntimeRoute, :origin, [route])
      saved = envelope |> Jason.encode!() |> Jason.decode!()
      assert {:ok, restored} = apply(NativeRuntimeRoute, :restore_origin, [saved])
      assert restored === route
      assert {:ok, ^route} = NativeRuntimeRoute.validate(restored)

      for key <- ["codex_home", "sqlite_home"] do
        path = ctx.descriptor[key]
        File.rename!(path, path <> "-original")
        assert {:error, :native_runtime_storage_unsafe} = NativeRuntimeRoute.restore_origin(saved)
        File.mkdir!(path)
        File.chmod!(path, 0o700)
        assert {:error, :native_runtime_storage_changed} = apply(NativeRuntimeRoute, :restore_origin, [saved])
        assert {:error, :native_runtime_storage_changed} = apply(NativeRuntimeRoute, :origin, [restored])
        assert {:ok, _replacement} = NativeRuntimeRoute.validate(ctx.descriptor)
        File.rename!(path, path <> "-replacement")
        File.rename!(path <> "-original", path)
      end
    end)
  end

  for kind <- [:workspace, :source] do
    @tag :route_policy_regression
    test "configured #{kind} roots retain strict protection when they are also broad roots" do
      with_private_route(fn ctx ->
        for broad <- [System.tmp_dir!(), "/"] do
          write_workflow_file!(Workflow.workflow_file_path(), workspace_root: if(unquote(kind) == :workspace, do: broad, else: ctx.workspace))

          if unquote(kind) == :source do
            path = Workflow.workflow_file_path()
            factory = "\nfactory:\n  repositories:\n    synthetic:\n      path: #{Jason.encode!(broad)}\n      base_branch: master\n---\n"
            File.write!(path, String.replace(File.read!(path), "\n---\n", factory, global: false))
            :ok = SymphonyElixir.WorkflowStore.force_reload()
          end

          assert {:error, :native_runtime_storage_unsafe} = NativeRuntimeRoute.validate(ctx.descriptor)
        end
      end)
    end
  end

  @tag :route_policy_regression
  test "existing private directories containing Unicode controls are refused" do
    with_private_route(fn ctx ->
      control = Path.join(ctx.root, "control-\u0085")
      File.mkdir!(control)
      File.chmod!(control, 0o700)
      assert {:error, :native_runtime_storage_unsafe} = NativeRuntimeRoute.validate(Map.put(ctx.descriptor, "codex_home", control))
    end)
  end

  test "route validation refuses malformed descriptors, unsafe roots and changed directory identity" do
    root = Path.join(System.tmp_dir!(), "route-refusal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace)
    codex = Path.join(root, "codex")
    sqlite = Path.join(root, "sqlite")
    for path <- [codex, sqlite], do: File.mkdir!(path)
    for path <- [codex, sqlite, workspace], do: File.chmod!(path, 0o700)
    descriptor = %{"version" => 1, "codex_home" => codex, "sqlite_home" => sqlite}

    for value <- [nil, [], "route", %{}, Map.put(descriptor, "extra", true), Map.put(descriptor, "version", 2), Map.put(descriptor, "version", 1.0), Map.put(descriptor, "version", "1")] do
      assert {:error, :native_runtime_route_invalid} = NativeRuntimeRoute.validate(value)
    end

    file = Path.join(root, "file")
    File.write!(file, "not a directory")
    alias_path = Path.join(root, "home-alias")
    File.ln_s!(System.user_home!(), alias_path)

    for path <- [nil, 42, "", "relative", codex <> "\n", codex <> <<0>>, <<255>>, "/", System.user_home!(), "/tmp", System.tmp_dir!(), alias_path, workspace, root, file, Path.join(root, "missing")] do
      assert {:error, :native_runtime_storage_unsafe} = NativeRuntimeRoute.validate(Map.put(descriptor, "codex_home", path))
    end

    assert {:ok, route} = NativeRuntimeRoute.validate(descriptor)
    File.chmod!(sqlite, 0o755)
    assert {:error, :native_runtime_storage_unsafe} = NativeRuntimeRoute.storage(route)
    File.chmod!(sqlite, 0o700)
    assert {:ok, _} = NativeRuntimeRoute.storage(route)
    assert {:error, :native_runtime_storage_changed} = NativeRuntimeRoute.storage(%{route | sqlite_home: Map.update!(route.sqlite_home, :uid, &(&1 + 1))})
    File.rename!(sqlite, sqlite <> "-old")
    File.mkdir!(sqlite)
    File.chmod!(sqlite, 0o700)
    assert {:error, :native_runtime_storage_changed} = NativeRuntimeRoute.storage(route)

    workflow = Workflow.workflow_file_path()
    content = File.read!(workflow)
    factory = "\nfactory:\n  repositories:\n    synthetic:\n      path: #{Jason.encode!(codex)}\n      base_branch: master\n---\n"
    File.write!(workflow, String.replace(content, "\n---\n", factory, global: false))
    :ok = SymphonyElixir.WorkflowStore.force_reload()
    assert {:error, :native_runtime_storage_unsafe} = NativeRuntimeRoute.validate(descriptor)
  end

  @tag :native_route_red
  test "an explicit private storage route returns child-only environment and a SQLite override" do
    root = Path.join(System.tmp_dir!(), "native-route-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    workspace = Path.join(root, "workspace")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace)

    for leaf <- ["codex", "sqlite"] do
      path = Path.join(root, leaf)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end

    {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(root)
    descriptor = %{"version" => 1, "codex_home" => Path.join(canonical, "codex"), "sqlite_home" => Path.join(canonical, "sqlite")}
    before = Map.take(System.get_env(), ~w(HOME CODEX_HOME CODEX_SQLITE_HOME))
    assert {:ok, route} = NativeRuntimeRoute.validate(descriptor)
    assert {:ok, storage} = NativeRuntimeRoute.storage(route)
    assert storage.codex_home == descriptor["codex_home"]
    assert storage.sqlite_home == descriptor["sqlite_home"]
    assert storage.env == [{~c"CODEX_HOME", String.to_charlist(storage.codex_home)}, {~c"CODEX_SQLITE_HOME", String.to_charlist(storage.sqlite_home)}]
    assert storage.overrides == ["sqlite_home=" <> Jason.encode!(storage.sqlite_home)]
    assert Map.take(System.get_env(), ~w(HOME CODEX_HOME CODEX_SQLITE_HOME)) == before
  end

  defp with_private_route(callback) do
    root = Path.join(System.tmp_dir!(), "route-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    workspace = Path.join(root, "workspace")
    File.mkdir!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace)
    descriptor = %{"version" => 1, "codex_home" => Path.join(root, "codex"), "sqlite_home" => Path.join(root, "sqlite")}

    for path <- [descriptor["codex_home"], descriptor["sqlite_home"]] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    callback.(%{root: root, workspace: workspace, descriptor: descriptor})
  end
end
