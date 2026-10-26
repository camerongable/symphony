defmodule SymphonyElixir.FactoryCiJobArtifactsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.CiJobArtifacts

  setup do
    root = Path.join(File.cwd!(), ".artifact-controller-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    source = Path.join(root, "source")
    File.mkdir!(source)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, source: source}
  end

  defmodule Connector do
    def job_artifacts("list_job_artifacts", args, _opts) do
      send(self(), {:artifact_list, args})
      {:ok, [%{"path" => "tests/password=filename-secret.log.gz", "type" => "file", "size" => 100}]}
    end

    def job_artifacts("download_job_artifacts", args, opts) do
      send(self(), {:artifact_download, args})
      path = Path.join([opts[:workspace], args["local_path"], "artifacts_job_#{args["job_id"]}.zip"])
      text = :zlib.gzip("AssertionError: actual failure\nmysql://user:db-secret@host/db\nmysql --password=cli-secret\n")
      {:ok, {_, bytes}} = :zip.create(~c"fixture.zip", [{~c"tests/password=filename-secret.log.gz", text}], [:memory])
      File.write!(path, bytes)
      if opts[:foreign_path], do: {:ok, %{"success" => true, "file_path" => path <> ".foreign"}}, else: {:ok, %{"success" => true, "file_path" => path}}
    end
  end

  defmodule DirectoryConnector do
    def job_artifacts("list_job_artifacts", args, _opts) do
      send(self(), {:directory_list, args})

      case args["path"] do
        "" -> {:ok, [%{"path" => "build-artifacts/", "type" => "directory", "mode" => "000775"}]}
        "build-artifacts" -> {:ok, [%{"path" => "build-artifacts/assertion.log.gz", "type" => "file", "mode" => "000664", "size" => 100}]}
      end
    end

    def job_artifacts("download_job_artifacts", args, opts) do
      send(self(), {:artifact_download, args})
      path = Path.join([opts[:workspace], args["local_path"], "artifacts_job_#{args["job_id"]}.zip"])
      {:ok, {_, bytes}} = :zip.create(~c"fixture.zip", [{~c"build-artifacts/assertion.log.gz", :zlib.gzip("AssertionError: nested actual failure\n")}], [:memory])
      File.write!(path, bytes)
      {:ok, %{"success" => true, "file_path" => path}}
    end
  end

  defmodule MetadataConnector do
    def job_artifacts("list_job_artifacts", args, opts) do
      send(self(), {:metadata_request, args})

      case Map.fetch!(opts[:metadata], args["path"]) do
        :unavailable ->
          {:error, :opaque_untrusted_server_error}

        {:late, files} ->
          Process.sleep(15_020)
          {:ok, files}

        files ->
          {:ok, files}
      end
    end

    def job_artifacts("download_job_artifacts", args, opts), do: DirectoryConnector.job_artifacts("download_job_artifacts", args, opts)
  end

  defmodule ProfileBundleConnector do
    def job_artifacts("list_job_artifacts", _args, _opts) do
      {:ok, [%{"path" => "build-artifacts/assertion.log.gz", "type" => "file", "size" => 100}, %{"path" => "profile.bin", "type" => "file", "size" => 17_000_000}]}
    end

    def job_artifacts("download_job_artifacts", args, opts) do
      path = Path.join([opts[:workspace], args["local_path"], "artifacts_job_#{args["job_id"]}.zip"])

      {:ok, {_, bytes}} =
        :zip.create(~c"profile.zip", [{~c"build-artifacts/assertion.log.gz", :zlib.gzip("AssertionError: nested actual failure\n")}, {~c"profile.bin", :crypto.strong_rand_bytes(17_000_000)}], [
          :memory
        ])

      true = byte_size(bytes) > 16_777_216
      File.write!(path, bytes)
      {:ok, %{"success" => true, "file_path" => path}}
    end
  end

  test "actual root directory metadata is traversed before exact-job download", ctx do
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: DirectoryConnector, workspace: ctx.root)
    assert evidence["status"] == "COMPLETE", inspect(evidence["gaps"])
    assert [%{"text" => text, "complete" => true}] = evidence["members"]
    assert text =~ "nested actual failure"
    assert_received {:directory_list, %{"project_id" => "123", "job_id" => "7", "path" => "", "recursive" => true}}
    assert_received {:directory_list, %{"project_id" => "123", "job_id" => "7", "path" => "build-artifacts", "recursive" => true}}
    assert length(evidence["provenance"]["metadata_observations"]) == 2
  end

  test "unsafe metadata never requests another path or downloads an archive", ctx do
    file = %{"path" => "test.log", "type" => "file", "size" => 1}

    cases = [
      [%{file | "path" => "../test.log"}],
      [%{file | "path" => "/test.log"}],
      [%{file | "path" => "C:/test.log"}],
      [%{file | "path" => "a\\test.log"}],
      [%{file | "path" => "a\nsecret.log"}],
      [%{file | "type" => "symlink"}],
      [Map.put(file, "mode", "120777")],
      [file, %{file | "size" => 2}],
      [file, %{file | "path" => "TEST.LOG"}],
      [%{"path" => "x/", "type" => "directory"}, %{file | "path" => "x"}]
    ]

    for files <- cases do
      [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: MetadataConnector, workspace: ctx.root, metadata: %{"" => files})
      assert evidence["status"] == "UNAVAILABLE"
      assert evidence["members"] == []
      assert evidence["gaps"] != [%{"code" => "ARTIFACT_UNAVAILABLE_OR_UNPROVEN"}]
      assert_received {:metadata_request, %{"path" => ""}}
      refute_received {:metadata_request, _}
      refute_received {:artifact_download, _}
    end
  end

  test "a bounded profile bundle above the old archive cap still yields its selected assertion log", ctx do
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: ProfileBundleConnector, workspace: ctx.root)
    assert evidence["status"] == "COMPLETE", inspect(evidence["gaps"])
    assert [%{"text" => "AssertionError: nested actual failure\n"}] = evidence["members"]
    assert evidence["provenance"]["archive_bytes"] > 16_777_216
  end

  test "directory cycles and out-of-parent responses are rejected before download", ctx do
    for child <- ["x/", "other/test.log"] do
      file = if child == "x/", do: %{"path" => child, "type" => "directory"}, else: %{"path" => child, "type" => "file", "size" => 1}
      metadata = %{"" => [%{"path" => "x/", "type" => "directory"}], "x" => [file]}
      [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: MetadataConnector, workspace: ctx.root, metadata: metadata)
      assert evidence["gaps"] == [%{"code" => "ARTIFACT_METADATA_PATH_OR_TYPE"}]
      refute_received {:artifact_download, _}
    end
  end

  test "identical recursive metadata redundancy is deduplicated without another download", ctx do
    file = %{"path" => "build-artifacts/assertion.log.gz", "type" => "file", "size" => 100}
    metadata = %{"" => [%{"path" => "build-artifacts/", "type" => "directory"}, file], "build-artifacts" => [file]}
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: MetadataConnector, workspace: ctx.root, metadata: metadata)
    assert evidence["status"] == "COMPLETE", inspect(evidence["gaps"])
    assert length(evidence["members"]) == 1
    assert_received {:artifact_download, _}
    refute_received {:artifact_download, _}
  end

  test "metadata budgets and tool gaps remain explicit evidence gaps", ctx do
    file = %{"path" => "test.log", "type" => "file", "size" => 1}

    deep =
      Enum.reduce(0..4, %{}, fn depth, acc ->
        path = Enum.join(List.duplicate("x", depth), "/")
        child = Enum.join(List.duplicate("x", depth + 1), "/")
        Map.put(acc, path, [%{"path" => child <> "/", "type" => "directory"}])
      end)

    cases = [
      {%{"" => :unavailable}, "ARTIFACT_METADATA_TOOL_UNAVAILABLE"},
      {%{"" => List.duplicate(file, 257)}, "ARTIFACT_METADATA_BUDGET"},
      {%{"" => [%{file | "size" => 67_108_865}]}, "ARTIFACT_METADATA_UNPROVEN"},
      {deep, "ARTIFACT_METADATA_BUDGET"},
      {Map.new(1..16, &{"d#{&1}", []}) |> Map.put("", Enum.map(1..16, &%{"path" => "d#{&1}/", "type" => "directory"})), "ARTIFACT_METADATA_BUDGET"},
      {%{"" => Enum.map(1..256, &%{file | "path" => String.duplicate("a", 1000) <> "#{&1}.log"})}, "ARTIFACT_METADATA_BUDGET"}
    ]

    for {metadata, code} <- cases do
      [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: MetadataConnector, workspace: ctx.root, metadata: metadata)
      assert evidence["gaps"] == [%{"code" => code}]
      refute Jason.encode!(evidence) =~ "opaque_untrusted_server_error"
      refute_received {:artifact_download, _}
    end
  end

  test "a late final metadata response cannot become complete evidence", ctx do
    metadata = %{"" => {:late, [%{"path" => "test.log", "type" => "file", "size" => 1}]}}
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: MetadataConnector, workspace: ctx.root, metadata: metadata)
    assert evidence["gaps"] == [%{"code" => "ARTIFACT_METADATA_BUDGET"}]
    refute_received {:artifact_download, _}
  end

  test "actual owned archive decoding is bound to exact MCP job and sanitized before retention", ctx do
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: Connector, workspace: ctx.root)
    assert evidence["status"] == "COMPLETE", inspect(evidence["gaps"])
    assert [%{"text" => text, "path" => path, "complete" => true}] = evidence["members"]
    assert text =~ "AssertionError: actual failure"
    refute Jason.encode!(evidence) =~ "db-secret"
    refute Jason.encode!(evidence) =~ "cli-secret"
    refute path =~ "filename-secret"
    assert evidence["provenance"]["owned_reader"]["exit_status"] == 0
    assert_received {:artifact_list, %{"project_id" => "123", "job_id" => "7", "recursive" => true}}
    assert_received {:artifact_download, %{"project_id" => "123", "job_id" => "7", "local_path" => relative}}
    assert relative =~ ~r/\A\.factory-ci-artifacts-[0-9a-f]{32}\z/
  end

  test "foreign download paths and SOURCE-contained workspaces never become artifact evidence", ctx do
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: Connector, workspace: ctx.root, foreign_path: true)
    assert evidence["status"] == "UNAVAILABLE" and evidence["members"] == []
    [evidence] = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, [%{"id" => 7}], connector: Connector, workspace: ctx.source)
    assert evidence["status"] == "UNAVAILABLE" and evidence["members"] == []
  end

  test "artifact budget retains every job as an explicit gap", ctx do
    evidence = CiJobArtifacts.collect(%{"worktree" => ctx.source}, 123, Enum.map(1..5, &%{"id" => &1}), connector: Connector, workspace: ctx.root)
    assert Enum.map(evidence, & &1["job_id"]) == Enum.to_list(1..5)
    assert Enum.all?(Enum.drop(evidence, 2), &(&1["status"] == "UNAVAILABLE"))
  end
end
