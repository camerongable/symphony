defmodule SymphonyElixir.Factory.TicketCiGenerationToolset do
  @moduledoc "Execution-pinned controller toolset; caller options cannot grant generation capability."
  alias SymphonyElixir.PathSafety

  @manifest Path.expand("../../../priv/controller_generation_toolset_v1.json", __DIR__)
  @external_resource @manifest
  @manifest_sha :crypto.hash(:sha256, File.read!(@manifest))
  @unavailable {:error, :ci_repair_generator_unavailable}
  @protocol "CI_GENERATION_GATE_V1"
  @checks ~w(actual_gazelle_diff actual_gazelle_unchanged actual_gofmt_diff actual_gofmt_unchanged outside_read symlink_escape source_write network fork child_exec self_exec extra_fd missing_gate modified_gate)
  @gazelle_flags ~w(fix -repo_root=. -build_file_name=BUILD,BUILD.bazel -build_tags=bazel -r_generate_rules=true -r_roclets=namespace,rd -mode=diff)

  @spec load() :: {:ok, map()} | {:error, atom()}
  def load do
    with {:ok, stat} <- File.lstat(@manifest),
         true <- stat.type == :regular,
         {:ok, @manifest} <- PathSafety.canonicalize(@manifest),
         {:ok, raw} <- File.read(@manifest),
         true <- :crypto.hash(:sha256, raw) == @manifest_sha,
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw) do
      validate(manifest)
    else
      _ -> @unavailable
    end
  end

  defp validate(%{"version" => 1, "available" => false} = manifest) when map_size(manifest) == 2, do: @unavailable

  defp validate(%{"version" => 1, "available" => true, "protocol" => @protocol} = manifest) do
    with true <- Enum.sort(Map.keys(manifest)) == ~w(available config gate gitlab_project_id profile programs proof protocol repo_key shim version),
         true <- is_binary(manifest["repo_key"]) and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, manifest["repo_key"]),
         true <- is_binary(manifest["gitlab_project_id"]) and Regex.match?(~r/\A[1-9][0-9]*\z/, manifest["gitlab_project_id"]),
         %{"gazelle" => gazelle, "gofmt" => gofmt} = programs when map_size(programs) == 2 <- manifest["programs"],
         {:ok, gazelle} <- reference(gazelle, 67_108_864),
         {:ok, gofmt} <- reference(gofmt, 67_108_864),
         {:ok, gate} <- reference(manifest["gate"], 2_097_152),
         {:ok, shim} <- reference(manifest["shim"], 2_097_152),
         {:ok, profile} <- reference(manifest["profile"], 262_144),
         {:ok, config} <- reference(manifest["config"], 262_144),
         {:ok, proof} <- reference(manifest["proof"], 262_144),
         :ok <- config(config),
         :ok <- proof(proof, %{gazelle: gazelle, gofmt: gofmt, gate: gate, shim: shim, profile: profile, config: config}, manifest) do
      {:ok, Map.put(manifest, "manifest_sha256", Base.encode16(@manifest_sha, case: :lower))}
    else
      _ -> @unavailable
    end
  end

  defp validate(_manifest), do: @unavailable

  defp reference(%{"path" => path, "sha256" => hash} = ref, limit) when map_size(ref) == 2 and is_binary(path) and is_binary(hash) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
         true <- Path.type(path) == :absolute,
         {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size > 0 and stat.size <= limit,
         {:ok, bytes} <- File.read(path),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash do
      {:ok, ref}
    else
      _ -> @unavailable
    end
  end

  defp reference(_, _), do: @unavailable

  defp config(ref) do
    expected = %{"gazelle_flags" => @gazelle_flags, "gofmt_flags" => ["-d"], "languages" => ~w(visibility proto go r)}
    with {:ok, ^expected} <- object(ref), do: :ok
  end

  defp proof(ref, programs, manifest) do
    expected = %{
      "version" => 1,
      "protocol" => @protocol,
      "repo_key" => manifest["repo_key"],
      "gitlab_project_id" => manifest["gitlab_project_id"],
      "programs" => %{"gazelle" => programs.gazelle["sha256"], "gofmt" => programs.gofmt["sha256"]},
      "gate_sha256" => programs.gate["sha256"],
      "shim_sha256" => programs.shim["sha256"],
      "profile_sha256" => programs.profile["sha256"],
      "config_sha256" => programs.config["sha256"],
      "checks" => Map.new(@checks, &{&1, "PASS"})
    }

    with {:ok, ^expected} <- object(ref), do: :ok
  end

  defp object(ref) do
    with {:ok, raw} <- File.read(ref["path"]),
         true <- Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == ref["sha256"],
         {:ok, value} when is_map(value) <- Jason.decode(raw) do
      {:ok, value}
    else
      _ -> @unavailable
    end
  end
end
