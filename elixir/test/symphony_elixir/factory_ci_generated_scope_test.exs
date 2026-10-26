defmodule SymphonyElixir.FactoryCiGeneratedScopeTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketCiGeneratedScope, TicketCiGenerationToolset, WorkerInstructions}

  @extract "go/src/grail.com/doc-extract/server/service/extract"
  @worker "go/src/grail.com/doc-extract/worker/cmd"

  test "an immutable diagnosis derives only the two import packages without rewriting its omitted BUILD scope" do
    ctx = setup_fixture(%{})

    files = %{
      (@extract <> "/accepted_execution_test.go") => "package extract\n\nimport _ \"go.uber.org/zap\"\n",
      (@worker <> "/main_test.go") => "package main\n\nimport _ \"go.uber.org/cadence/activity\"\n",
      (@extract <> "/BUILD") => "go_test(name = \"go_default_test\")\n",
      (@worker <> "/BUILD") => "go_test(name = \"go_default_test\")\n"
    }

    Enum.each(files, fn {path, bytes} ->
      File.mkdir_p!(Path.dirname(Path.join(ctx.path, path)))
      File.write!(Path.join(ctx.path, path), bytes)
    end)

    git(ctx.path, ["add", "--" | Map.keys(files)])
    git(ctx.path, ["commit", "--no-verify", "-m", "test: existing imports before CI repair"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{state: "CI_WAITING", candidate_sha: sha, ci_pipeline_id: 277})
    paths = [@extract <> "/accepted_execution_test.go", @worker <> "/main_test.go"]

    log = Enum.map_join(paths, "\n", &(&1 <> ": import of \"go.uber.org/example\""))

    diagnosis = %{
      "status" => "REPAIRABLE",
      "pipeline_id" => 277,
      "changed_paths" => paths ++ [@extract <> "/BUILD"],
      "allowed_writer_paths" => paths,
      "required_generated_paths" => [@extract <> "/BUILD"],
      "failed_jobs" => [%{"id" => 17_302_347_055}],
      "logs" => [%{"job_id" => 17_302_347_055, "text" => log}],
      "trace_availability" => [%{"job_id" => 17_302_347_055, "status" => "COMPLETE"}],
      "trace_provenance" => [%{"arguments" => %{"job_id" => "17302347055", "project_id" => "33747681"}, "raw_sha256" => String.duplicate("a", 64)}]
    }

    raw = Jason.encode!(diagnosis)
    preimage = Jason.encode!(%{"run" => run, "ci_snapshots" => %{"mr" => %{"project_id" => 33_747_681}}})

    row = %{
      "diagnosis_key" => "generated",
      "run_id" => "run",
      "candidate_sha" => sha,
      "pipeline_id" => 277,
      "verdict" => "REPAIRABLE",
      "diagnosis_json" => raw,
      "diagnosis_sha256" => digest(raw),
      "preimage_json" => preimage,
      "preimage_sha256" => digest(preimage)
    }

    assert {:ok, capability} = TicketCiGeneratedScope.prepare(run, row)
    assert capability["kind"] == "CI_GENERATED_ONLY_V1"
    assert TicketCiGeneratedScope.qualified_toolset(run, Jason.decode!(preimage), {:error, :controller_generation_toolset_unavailable}) == nil
    assert TicketCiGeneratedScope.qualified_toolset(run, Jason.decode!(preimage), {:ok, %{"available" => false}}) == nil
    assert {:ok, nil} = TicketCiGeneratedScope.prepare(Map.put(run, "repo_key", "unsupported"), row)
    assert :ok = TicketCiGeneratedScope.authenticate(run, row, capability)
    assert capability["failed_candidate_sha"] == sha
    assert capability["generated_paths"] == [@extract <> "/BUILD", @worker <> "/BUILD"]
    assert Enum.map(capability["go_inputs"], & &1["path"]) == paths
    assert Enum.all?(capability["go_inputs"] ++ capability["build_inputs"], &(byte_size(&1["sha256"]) == 64))
    assert row["diagnosis_json"] == raw
    assert Jason.decode!(raw)["required_generated_paths"] == [@extract <> "/BUILD"]
    assert git(ctx.path, ["status", "--porcelain"]) == ""

    packet = Map.take(run, ~w(run_id spec_revision contract_sha256 candidate_sha)) |> Map.put("role", "feature-writer")
    scope = %{"claim_key" => capability["claim_key"], "generated_only_capability" => capability}
    assert {:ok, attached} = TicketCiGeneratedScope.attach(packet, scope)
    assert attached["controller_generation_scope"]["capability_sha256"] == digest(Jason.encode!(capability))
    refute Map.has_key?(attached["controller_generation_scope"], "packet_sha256")
    assert {:ok, ^packet} = TicketCiGeneratedScope.attach(packet, Map.delete(scope, "generated_only_capability"))
    assert {:error, _} = TicketCiGeneratedScope.attach(Map.put(packet, "contract_sha256", String.duplicate("b", 64)), scope)

    for tampered <- [
          Map.put(capability, "claim_key", "other"),
          Map.put(capability, "generated_paths", ["third/BUILD"]),
          Map.put(capability, "traces", []),
          Map.put(capability, "failed_candidate_sha", String.duplicate("c", 40))
        ] do
      assert {:error, :ci_generated_scope_unproven} = TicketCiGeneratedScope.authenticate(run, row, tampered)
    end

    source_scope = Map.put(scope, "prior_run", run)

    for output <- [%{"status" => "CONTINUE", "changed_paths" => []}, %{"status" => "COMPLETE", "changed_paths" => paths}] do
      assert {:ok, ^source_scope} = TicketCiGeneratedScope.select(ctx.store, run, source_scope, %{}, %{"expected_sha" => sha}, output)
    end

    after_continue = Map.update!(run, "implementation_iteration", &(&1 + 1))
    assert {:ok, ^source_scope} = TicketCiGeneratedScope.select(ctx.store, after_continue, source_scope, %{}, %{"expected_sha" => sha}, %{"status" => "COMPLETE", "changed_paths" => []})

    admitted_run = Map.merge(run, %{"state" => "REPAIRING", "code_repair_round" => 1})

    admitted_packet =
      Map.merge(attached, Map.take(admitted_run, ~w(stage code_repair_round implementation_iteration)))
      |> Map.put("stage", "REPAIRING")
      |> Map.put("ci_repair", %{"claim_key" => capability["claim_key"]})

    assert {:ok, _} = WorkerInstructions.admit(ctx.store, admitted_packet, "ci-repair-writer", fixture_instructions(ctx))
    assert :ok = WorkerInstructions.bind_task(ctx.store, "writer", String.duplicate("p", 64), digest(Jason.encode!(admitted_packet)))
    binding = %{"expected_sha" => sha, "prompt_sha256" => String.duplicate("p", 64), "reservation_generation" => 1}
    evidence = %{"task_key" => "writer", "request_key" => "new-mechanical", "binding_sha256" => String.duplicate("a", 64), "output_sha256" => String.duplicate("b", 64), "reservation_key" => "source"}
    assert {:ok, selected} = TicketCiGeneratedScope.select(ctx.store, admitted_run, source_scope, evidence, binding, %{"status" => "COMPLETE", "changed_paths" => []})
    assert selected["generated_only_execution"]["capability"] == capability
    assert selected["generated_only_execution"]["packet_sha256"] == digest(Jason.encode!(admitted_packet))

    assert {:error, :ci_generated_scope_unproven} =
             TicketCiGeneratedScope.select(ctx.store, admitted_run, source_scope, evidence, Map.put(binding, "prompt_sha256", String.duplicate("f", 64)), %{
               "status" => "COMPLETE",
               "changed_paths" => []
             })

    validate_physical_capability(ctx, capability, source_scope, row, diagnosis, preimage)
    validate_native_shape(ctx, capability, source_scope, row, admitted_run, selected, binding, evidence)

    File.write!(Path.join(ctx.path, hd(paths)), "package extract\n")
    assert {:error, :ci_generated_scope_unproven} = TicketCiGeneratedScope.prepare(run, row)
    File.write!(Path.join(ctx.path, hd(paths)), files[hd(paths)])
    File.write!(Path.join(ctx.path, @worker <> "/BUILD.bazel"), "ambiguous\n")
    assert {:error, :ci_generated_scope_unproven} = TicketCiGeneratedScope.prepare(run, row)
    File.rm!(Path.join(ctx.path, @worker <> "/BUILD.bazel"))
    File.rm!(Path.join(ctx.path, @worker <> "/BUILD"))
    assert {:error, :ci_generated_scope_unproven} = TicketCiGeneratedScope.prepare(run, row)
  end

  defp digest(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  defp validate_native_shape(ctx, capability, scope, row, run, selected, binding, evidence) do
    binding =
      Map.merge(binding, Map.take(run, ~w(run_id spec_revision contract_sha256)))
      |> Map.merge(%{"mode" => "SOURCE", "role" => "feature-writer", "stage" => "REPAIRING", "input_sha256" => binding["prompt_sha256"]})

    output = %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil}
    stop = Jason.encode!(%{"transport" => "owned_app_server", "thread_id" => "synthetic-worker", "cwd" => ctx.path, "exit_status" => 0})

    worker =
      Map.merge(evidence, %{
        "run_id" => "run",
        "binding_json" => Jason.encode!(binding),
        "output_json" => Jason.encode!(output),
        "binding_sha256" => digest(Jason.encode!(binding)),
        "output_sha256" => digest(Jason.encode!(output)),
        "status" => "RESULT_RECORDED",
        "thread_id" => "synthetic-worker",
        "owner_stopped_at" => "2026-01-01T00:00:00Z",
        "owner_stop_json" => stop
      })

    claim =
      Map.merge(scope, %{
        "round" => 1,
        "diagnosis_key" => row["diagnosis_key"],
        "allowed_writer_paths" => Jason.decode!(row["diagnosis_json"])["allowed_writer_paths"],
        "required_generated_paths" => Jason.decode!(row["diagnosis_json"])["required_generated_paths"]
      })

    claim_row = %{"claim_key" => capability["claim_key"], "round" => 1, "claim_json" => Jason.encode!(claim), "claim_sha256" => digest(Jason.encode!(claim))}
    mapping = Store.one!(ctx.store, "SELECT * FROM worker_instruction_task_bindings WHERE task_key='writer'")
    snapshot = Store.one!(ctx.store, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", [mapping["instruction_binding_sha256"]])
    proof = Map.merge(selected["generated_only_execution"], Map.take(worker, ~w(binding_sha256 output_sha256)))
    {:ok, toolset} = TicketCiGenerationToolset.load()
    files = Enum.map(capability["build_inputs"], &Map.put(&1, "bytes_base64", Base.encode64(File.read!(Path.join(ctx.path, &1["path"])))))

    intent = %{
      "version" => 1,
      "kind" => "CONTROLLER_CI_GENERATED_ONLY",
      "operation" => "GAZELLE_DIFF",
      "paths" => capability["generated_paths"],
      "generated_only_execution" => proof,
      "run_preimage" => run,
      "toolset" => toolset,
      "observation" => %{"spool" => %{"root" => ctx.path}, "files" => %{"files" => files}}
    }

    intent_row = %{
      "intent_key" => "ci-generation:" <> digest(Jason.encode!([worker["request_key"], "GAZELLE_DIFF"])),
      "run_id" => "run",
      "request_key" => worker["request_key"],
      "claim_key" => capability["claim_key"]
    }

    access = %{"run_id" => "run", "task_key" => "writer", "request_key" => worker["request_key"], "generation" => 1, "mode" => "SOURCE", "canonical_path" => ctx.path, "released_at" => nil}

    rows = %{
      "ticket_ci_repair_claims" => claim_row,
      "ticket_ci_repair_diagnoses" => row,
      "worker_evidence" => worker,
      "workspace_access" => access,
      "worker_instruction_task_bindings" => mapping,
      "worker_instruction_snapshots" => snapshot
    }

    input = Path.join(ctx.root, "synthetic-native-intent.json")
    File.write!(input, Jason.encode!(%{"rows" => rows, "intent" => intent, "intent_row" => intent_row}))

    code = """
    import copy,importlib.util,json,re,sys
    spec=importlib.util.spec_from_file_location('generated',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    data=json.load(open(sys.argv[2]))
    class Cursor:
      def __init__(self,row): self.description=[(key,) for key in row]; self.row=list(row.values())
      def fetchall(self): return [self.row]
    class Connection:
      def execute(self,sql,args): return Cursor(data['rows'][re.search(r'FROM ([a-z_]+)',sql).group(1)])
    module.validate_intent(Connection(),data['intent_row'],data['intent'],check_files=True)
    bad=copy.deepcopy(data['intent']); bad['toolset']['programs']['gazelle']['sha256']='d'*64
    try: module.validate_intent(Connection(),data['intent_row'],bad)
    except ValueError: pass
    else: raise AssertionError('coherent substituted toolset admitted')
    print('PASS native-shaped synthetic intent, exact pinned toolset and substitution refusal; no effects')
    """

    assert {text, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", code, Application.app_dir(:symphony_elixir, "priv/controller_generation_executor_v3.py"), input], stderr_to_stdout: true)
    assert text =~ "PASS native-shaped synthetic intent"
  end

  defp validate_physical_capability(ctx, capability, scope, row, diagnosis, preimage) do
    input = Path.join(ctx.root, "synthetic-capability.json")

    claim =
      Map.merge(scope, %{
        "claim_key" => capability["claim_key"],
        "diagnosis_key" => row["diagnosis_key"],
        "allowed_writer_paths" => diagnosis["allowed_writer_paths"],
        "required_generated_paths" => diagnosis["required_generated_paths"]
      })

    File.write!(input, Jason.encode!([capability, claim, row, diagnosis, Jason.decode!(preimage)]))
    program = Application.app_dir(:symphony_elixir, "priv/controller_generation_executor_v3.py")

    code = """
    import importlib.util,json,sys,copy
    spec=importlib.util.spec_from_file_location('generated_scope',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    values=json.load(open(sys.argv[2])); module.validate_capability(*values)
    for field,value in [('generated_paths',['third/BUILD']),('traces',[]),('failed_candidate_sha','c'*40),('profile_sha256','d'*64)]:
      altered=copy.deepcopy(values); altered[0][field]=value
      try: module.validate_capability(*altered)
      except (ValueError,KeyError,TypeError): pass
      else: raise AssertionError(field)
    print('PASS generated-only physical capability and coherent tamper refusals; pure validation only')
    """

    assert {output, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", code, program, input], stderr_to_stdout: true)
    assert output =~ "PASS generated-only physical capability"
  end

  defp fixture_instructions(ctx) do
    root = Path.join(ctx.root, "instructions")

    for relative <-
          ~w(AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md skills/fix-mr-pipeline/SKILL.md) do
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "Synthetic complete fixture instruction: #{relative}\n")
    end

    root
  end
end
