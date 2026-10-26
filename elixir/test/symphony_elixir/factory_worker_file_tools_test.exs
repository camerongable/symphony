defmodule SymphonyElixir.FactoryWorkerFileToolsTest do
  # Native helper deadlines must not compete with unrelated process-heavy modules.
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{RunLedger, Store, TaskLedger, TicketWorkerRunner}
  alias SymphonyElixir.Factory.{WorkerEvidence, WorkerFileIO, WorkerFileTools, WorkspaceAccess}
  setup :setup_fixture

  @tag :file_revision
  test "base reads ignore dirty checkout bytes and cannot supply current write CAS", ctx do
    pin_base(ctx)
    File.write!(Path.join(ctx.path, "fixture.txt"), "candidate\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "candidate"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    Store.query!(ctx.store, "UPDATE factory_tasks SET workspace_sha=? WHERE task_key='writer'", [sha])
    cap = prepare(%{ctx | sha: sha})
    File.write!(Path.join(ctx.path, "fixture.txt"), "dirty\n")
    File.write!(Path.join(ctx.path, "other.txt"), "keep\n")
    assert %{"success" => true} = result = revision(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => 1})
    historical = decoded(result)
    assert historical["text"] == "base\n"
    assert historical["revision"] == ctx.sha
    assert historical["sha256"] == digest("base\n")
    assert historical["mode"] == "100644"
    assert %{"success" => false} = call(cap, "repo_write", edit(historical["sha256"], historical["text"]), identity("repo_write", "stale"))
    current = read(cap) |> decoded()
    assert %{"success" => true} = call(cap, "repo_write", edit(current["sha256"], historical["text"]), identity("repo_write", "restore"))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert File.read!(Path.join(ctx.path, "other.txt")) == "keep\n"
  end

  @tag :file_revision
  test "revision tools reject caller revisions, absent pins and foreign persisted bases", ctx do
    cap = prepare(ctx)
    args = %{"path" => "fixture.txt", "start_line" => 1}
    assert %{"success" => false} = revision(cap, "repo_read", args)

    for revision <- [ctx.sha, "HEAD", "master", "HEAD:fixture.txt", String.slice(ctx.sha, 0, 8)] do
      assert %{"success" => false} = revision(cap, "repo_read", Map.put(args, "revision", revision))
    end

    pin_base(ctx)
    assert %{"success" => false} = revision(cap, "repo_read", args)
  end

  @tag :file_revision
  test "revision reads retain active owner, native identity and release fences", ctx do
    pin_base(ctx)
    cap = prepare(ctx)
    args = %{"path" => "fixture.txt", "start_line" => 1}
    assert %{"success" => true} = revision(cap, "repo_read", args)
    assert %{"success" => false} = revision(cap, "repo_read", args, %{identity("repo_read") | "turnId" => "foreign"})
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha=? WHERE run_id='run'", [String.duplicate("a", 40)])
    assert %{"success" => false} = revision(cap, "repo_read", args)
    Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha=? WHERE run_id='run'", [ctx.sha])
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at='stopped' WHERE request_key=?", [cap.key])
    assert %{"success" => false} = revision(cap, "repo_read", args)
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at=NULL WHERE request_key=?", [cap.key])
    Store.query!(ctx.store, "UPDATE workspace_access SET released_at='released' WHERE reservation_key='reservation'")
    assert %{"success" => false} = revision(cap, "repo_read", args)
  end

  @tag :file_revision
  test "revision binary pages preserve exact bytes and reject nonregular or oversized blobs", ctx do
    bytes = <<0, 255, 13, 10>> <> String.duplicate("é", 5_000)
    limit = String.duplicate("a", 262_144)
    oversized = String.duplicate("b", 262_145)

    for {path, raw} <- [{"binary", bytes}, {"limit", limit}, {"oversized", oversized}, {"utf8", "é\r\nlast\n"}] do
      File.write!(Path.join(ctx.path, path), raw)
    end

    File.ln_s!("fixture.txt", Path.join(ctx.path, "link"))
    git(ctx.path, ["add", "."])
    git(ctx.path, ["commit", "--no-verify", "-m", "binary bases"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    Store.query!(ctx.store, "UPDATE factory_tasks SET workspace_sha=? WHERE task_key='writer'", [sha])
    pin_base(%{ctx | sha: sha})
    cap = prepare(%{ctx | sha: sha})
    pages = for offset <- [0, 8_192], do: revision(cap, "repo_read_binary", %{"path" => "binary", "offset" => offset}) |> decoded()
    assert Enum.map_join(pages, &Base.decode64!(&1["content_base64"])) == bytes
    assert hd(pages)["next_offset"] == 8_192
    assert List.last(pages)["next_offset"] == nil
    assert %{"success" => true} = revision(cap, "repo_read_binary", %{"path" => "limit", "offset" => 262_144})
    assert %{"success" => true} = text = revision(cap, "repo_read", %{"path" => "utf8", "start_line" => 1})
    assert decoded(text)["text"] == "é\r\nlast\n"

    for path <- ["binary", "oversized", "link", "missing", ".", "../fixture.txt", ".git/config", ".env", "a/../fixture.txt"] do
      assert %{"success" => false} = revision(cap, "repo_read", %{"path" => path, "start_line" => 1})
    end

    assert %{"success" => false} = revision(cap, "repo_read_binary", %{"path" => "oversized", "offset" => 0})
  end

  defp pin_base(ctx), do: Store.query!(ctx.store, "INSERT INTO ticket_review_bases VALUES ('run','refs/remotes/origin/master',?,'now')", [ctx.sha])

  @tag :file_revision
  test "virtual base namespace never falls back to disk or admits mutation or prefix aliases", ctx do
    pin_base(ctx)
    cap = prepare(ctx)
    shadow = Path.join(ctx.path, ".symphony-base")
    File.mkdir!(shadow)
    File.write!(Path.join(shadow, "physical-only"), "not historical\n")
    File.write!(Path.join(shadow, "fixture.txt"), "not base\n")
    assert %{"success" => true} = historical = revision(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => 1})
    assert decoded(historical)["text"] == "base\n"
    assert decoded(historical)["source"] == "CONTRACT_BASE"
    assert decoded(historical)["write_cas_warning"] =~ "never use this historical SHA"
    assert %{"success" => false} = revision(cap, "repo_read", %{"path" => "physical-only", "start_line" => 1})
    File.rename!(shadow, shadow <> ".retained")
    File.ln_s!(ctx.repo, shadow)
    assert %{"success" => true} = revision(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => 1})
    assert %{"success" => false} = revision(cap, "repo_read", %{"path" => "physical-only", "start_line" => 1})

    for path <- [
          ".symphony-base",
          ".SYMPHONY-base/fixture.txt",
          ".symphony-basé/fixture.txt",
          ".symphony-base//fixture.txt",
          ".symphony-base/.symphony-base/fixture.txt",
          ".symphony-base/../fixture.txt",
          ".symphony-base//absolute",
          ".symphony-base/a\\b",
          ".symphony-base/a\n",
          ".symphony-base/a\0",
          ".symphony-base/.git/config"
        ] do
      assert %{"success" => false} = call(cap, "repo_read", %{"path" => path, "start_line" => 1})
    end

    lookalike = Path.join(ctx.path, ".ｓymphony-base")
    File.mkdir!(lookalike)
    File.write!(Path.join(lookalike, "fixture.txt"), "ordinary lookalike\n")
    assert %{"success" => true} = ordinary = call(cap, "repo_read", %{"path" => ".ｓymphony-base/fixture.txt", "start_line" => 1})
    assert decoded(ordinary)["text"] == "ordinary lookalike\n"
    refute Map.has_key?(decoded(ordinary), "source")

    for {tool, args} <- [
          {"repo_write", edit("ABSENT", "forbidden", ".symphony-base/new")},
          {"repo_write_binary", %{"path" => ".symphony-base/new", "expected_sha256" => "ABSENT", "content_base64" => "eA=="}},
          {"repo_delete", %{"path" => ".symphony-base/fixture.txt", "expected_sha256" => digest("base\n")}},
          {"repo_mkdir", %{"path" => ".symphony-base/new"}},
          {"repo_list", %{"path" => ".symphony-base/"}}
        ] do
      assert %{"success" => false} = call(cap, tool, args)
    end

    assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == []
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  for drift <- ~w(turn generation base stopped root spec contract branch prompt) do
    @tag :file_revision
    @revision_drift drift
    test "post-I/O #{@revision_drift} drift cannot return historical bytes", ctx do
      pin_base(ctx)
      cap = prepare(ctx)
      hook = {SymphonyElixir.Factory.Worktree, :before_identity_command}
      Process.put(:revision_head_reads, 0)
      on_exit(fn -> Process.delete(hook) end)

      Process.put(hook, fn
        ["rev-parse", "HEAD"] ->
          count = Process.get(:revision_head_reads) + 1
          Process.put(:revision_head_reads, count)

          target = if @revision_drift in ~w(spec contract branch prompt), do: 6, else: 5

          if count == target do
            case @revision_drift do
              "turn" ->
                Store.query!(ctx.store, "UPDATE worker_evidence SET turn_id='foreign' WHERE request_key=?", [cap.key])

              "generation" ->
                Store.query!(ctx.store, "UPDATE workspace_access SET generation=generation+1 WHERE reservation_key='reservation'")

              "base" ->
                Store.query!(ctx.store, "UPDATE ticket_review_bases SET base_sha=? WHERE run_id='run'", [String.duplicate("a", 40)])

              "stopped" ->
                Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at='stopped' WHERE request_key=?", [cap.key])

              "root" ->
                File.rename!(ctx.path, ctx.path <> ".retained")
                File.mkdir!(ctx.path)

              "spec" ->
                Store.query!(ctx.store, "UPDATE runs SET spec_revision=spec_revision+1 WHERE run_id='run'")

              "contract" ->
                Store.query!(ctx.store, "UPDATE runs SET contract_sha256=? WHERE run_id='run'", [String.duplicate("a", 64)])

              "branch" ->
                Store.query!(ctx.store, "UPDATE runs SET branch='cgable/foreign' WHERE run_id='run'")

              "prompt" ->
                Store.query!(ctx.store, "UPDATE factory_tasks SET prompt_sha256=? WHERE task_key='writer'", [String.duplicate("a", 64)])
            end
          end

        _ ->
          :ok
      end)

      assert %{"success" => false} = revision(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => 1})
      assert Process.get(:revision_head_reads) >= 5
      if @revision_drift in ~w(spec contract branch prompt), do: assert(Process.get(:revision_head_reads) >= 6)
      Process.delete(hook)
      path = if @revision_drift == "root", do: ctx.path <> ".retained", else: ctx.path
      assert File.read!(Path.join(path, "fixture.txt")) == "base\n"
      assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == []
    end
  end

  @tag :file_revision_compatibility
  test "original seven-tool policy and stopped physical receipts remain unchanged and reconcilable", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    old_tools = WorkerFileTools.tool_specs()
    assert Enum.map(old_tools, & &1["name"]) == ~w(repo_read repo_list repo_write repo_delete repo_mkdir repo_read_binary repo_write_binary)
    old_sha = old_tools |> Jason.encode!() |> digest()
    assert old_sha == "44f58a614a4437a56c277c24b295d0cd8d529b3c197c9a820dda7dd7516a135e"
    {:ok, evidence} = WorkerEvidence.get(ctx.store, cap.key)
    assert get_in(Jason.decode!(evidence["binding_json"]), ["policy", "file_tools_sha256"]) == old_sha
    Store.query!(ctx.store, "UPDATE worker_evidence SET owner_stopped_at='stopped' WHERE request_key=?", [cap.key])
    original = Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == original
    {:ok, after_readback} = WorkerEvidence.get(ctx.store, cap.key)
    assert after_readback["binding_json"] == evidence["binding_json"]
    assert after_readback["binding_sha256"] == evidence["binding_sha256"]
    assert %{"success" => false} = revision(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => 1})
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  @tag :file_revision
  test "revision text refuses long or escaped output rather than returning an ambiguous prefix", ctx do
    lines = Enum.map_join(1..101, "\n", &Integer.to_string/1)
    long = String.duplicate("x", 16_385)
    escaped = String.duplicate("\t", 9_000)

    for {name, content} <- [{"long", long}, {"escaped", escaped}, {"lines", lines}] do
      File.write!(Path.join(ctx.path, name), content)
    end

    git(ctx.path, ["add", "."])
    git(ctx.path, ["commit", "--no-verify", "-m", "page limits"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    Store.query!(ctx.store, "UPDATE factory_tasks SET workspace_sha=? WHERE task_key='writer'", [sha])
    pin_base(%{ctx | sha: sha})
    cap = prepare(%{ctx | sha: sha})

    for path <- ~w(long escaped) do
      assert %{"success" => false} = revision(cap, "repo_read", %{"path" => path, "start_line" => 1})
      assert %{"success" => true} = revision(cap, "repo_read_binary", %{"path" => path, "offset" => 0})
    end

    assert %{"success" => true} = first = revision(cap, "repo_read", %{"path" => "lines", "start_line" => 1})
    assert decoded(first)["next_line"] == 101
    assert %{"success" => true} = last = revision(cap, "repo_read", %{"path" => "lines", "start_line" => 101})
    assert decoded(last)["text"] == "101"
    assert decoded(last)["next_line"] == nil
  end

  test "CI repair rejects out-of-scope mutations before journaling or dispatch", ctx do
    cap = prepare(ctx)
    {:ok, %{run: prior}} = RunLedger.update(ctx.store, "run", %{state: "REPAIRING", code_repair_round: 1, repair_findings_json: ~s({"kind":"TICKET_CI_REPAIR","claim_key":"ci-claim"})})
    assert %{"success" => false} = missing = call(cap, "repo_write", edit(digest("base\n")))
    assert decoded(missing)["error"] == ":ci_repair_scope_unproven"
    assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == []

    claim = %{
      "kind" => "TICKET_CI_REPAIR",
      "claim_key" => "ci-claim",
      "round" => 1,
      "prior_run" => prior,
      "source_task" => Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key='writer'"),
      "allowed_writer_paths" => ["fixture.txt"],
      "required_generated_paths" => ["BUILD"]
    }

    raw = Jason.encode!(claim)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES ('ci-diagnosis', 'run', ?, 99, '{}', ?, '{}', ?, 'REPAIRABLE', 'now')", [ctx.sha, digest("{}"), digest("{}")])
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('ci-claim', 'ci-diagnosis', 'run', 1, ?, ?, 'now')", [raw, digest(raw)])
    {:ok, _} = RunLedger.update(ctx.store, "run", %{code_repair_round: 2})
    assert %{"success" => false} = wrong_round = call(cap, "repo_write", edit(digest("base\n")))
    assert decoded(wrong_round)["error"] == ":ci_repair_scope_unproven"
    assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == []
    {:ok, _} = RunLedger.update(ctx.store, "run", %{code_repair_round: 1})

    for {tool, args} <- [
          {"repo_write", edit("ABSENT", "unsafe\n", "other.go")},
          {"repo_write", edit("ABSENT", "unsafe\n", ".gitlab-ci.yml")},
          {"repo_write", edit("ABSENT", "unsafe\n", "BUILD")},
          {"repo_delete", %{"path" => "other.go", "expected_sha256" => digest("x")}},
          {"repo_mkdir", %{"path" => "new-dir"}},
          {"repo_mkdir", %{"path" => "fixture.txt"}},
          {"repo_write_binary", %{"path" => "fixture.txt", "expected_sha256" => digest("base\n"), "content_base64" => Base.encode64("unsafe")}},
          {"repo_write_binary", %{"path" => "binary", "expected_sha256" => "ABSENT", "content_base64" => Base.encode64("unsafe")}}
        ] do
      assert %{"success" => false} = result = call(cap, tool, args)
      assert decoded(result)["error"] == ":ci_repair_path_not_authorized"
      assert Store.query!(ctx.store, "SELECT * FROM worker_file_operations").rows == []
    end

    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  defp starting(ctx) do
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)

    {:ok, _} =
      WorkerEvidence.reserve(ctx.store, %{
        "request_key" => "reservation:request",
        "task_key" => "writer",
        "reservation_key" => "reservation",
        "input_sha256" => String.duplicate("p", 64),
        "owner_id" => "owner",
        "schema" => %{},
        "policy" => policy
      })

    {:ok, cap} = WorkerFileTools.bind(ctx.store, "reservation:request", "owner")
    {:ok, _} = WorkerEvidence.mark_start_sent(ctx.store, cap.key)
    assert :ok = WorkerFileTools.preflight(cap, ctx.path)
    cap
  end

  defp prepare(ctx) do
    cap = starting(ctx)
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, cap.key, "worker", policy)
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, cap.key, process_receipt())
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, cap.key, "worker", "turn")
    cap
  end

  test "turn admission binds the current thread, owned process and model before any edit", ctx do
    cap = starting(ctx)
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, cap.key, "worker", policy)
    {:ok, _} = WorkerEvidence.bind_owner_process(ctx.store, cap.key, process_receipt())

    session = %{
      workspace: ctx.path,
      thread_id: "worker",
      worker_policy: policy,
      model: "gpt-6-luna",
      reasoning_effort: "medium",
      dynamic_tool_binding: %{tool_specs: WorkerFileTools.tool_specs()},
      metadata: %{codex_app_server_pid: "fixture"},
      worker_invocation: String.duplicate("a", 64)
    }

    assert :ok = WorkerFileTools.turn_preflight(cap, session)
    changed_tools = %{session | dynamic_tool_binding: %{tool_specs: []}}
    assert {:error, :file_worker_tool_contract_changed} = WorkerFileTools.turn_preflight(cap, changed_tools)
    assert {:error, :file_worker_identity_mismatch} = WorkerFileTools.turn_preflight(cap, %{session | thread_id: "other"})
    changed_invocation = %{session | worker_invocation: String.duplicate("b", 64)}
    assert {:error, :file_worker_process_mismatch} = WorkerFileTools.turn_preflight(cap, changed_invocation)
    assert {:error, :file_worker_inputs_changed} = WorkerFileTools.turn_preflight(cap, %{session | model: "other"})
    {:ok, _} = WorkerEvidence.bind_turn(ctx.store, cap.key, "worker", "turn")
    assert {:error, :file_worker_not_starting} = WorkerFileTools.turn_preflight(cap, session)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "missing and malformed owner-process records cannot admit a turn", ctx do
    cap = starting(ctx)
    policy = TicketWorkerRunner.policy("SOURCE", ctx.path)
    {:ok, _} = WorkerEvidence.bind_thread(ctx.store, cap.key, "worker", policy)
    session = %{workspace: ctx.path, thread_id: "worker", metadata: %{codex_app_server_pid: "fixture"}}

    for raw <- [nil, "not-json", "null", "[]"] do
      Store.query!(ctx.store, "UPDATE worker_evidence SET owner_process_json = ? WHERE request_key = ?", [raw, cap.key])
      assert {:error, :file_worker_process_unbound} = WorkerFileTools.turn_preflight(cap, session)
    end

    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  defp identity(tool, call \\ "call"), do: %{"threadId" => "worker", "turnId" => "turn", "callId" => call, "tool" => tool}
  defp call(cap, tool, args, id \\ nil), do: WorkerFileTools.execute(cap, tool, args, id || identity(tool))
  defp revision(cap, tool, args, id \\ nil), do: call(cap, tool, Map.update!(args, "path", &(".symphony-base/" <> &1)), id)
  defp decoded(%{"contentItems" => [%{"text" => text}]}), do: Jason.decode!(text)
  defp read(cap, path \\ "fixture.txt"), do: call(cap, "repo_read", %{"path" => path, "start_line" => 1})
  defp edit(hash, content \\ "edited\n", path \\ "fixture.txt"), do: %{"path" => path, "expected_sha256" => hash, "content" => content}
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp await_marker(path, owner, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("companion publication barrier was not observed before the owner deadline")

      true ->
        case Task.yield(owner, 10) do
          nil -> await_marker(path, owner, deadline)
          result -> flunk("companion owner finished before its publication barrier: #{inspect(result, limit: 10, printable_limit: 200)}")
        end
    end
  end

  test "actual reads, bounded listings, CAS edits and duplicate requests preserve controller authority", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = result = read(cap)
    assert decoded(result)["text"] == "base\n"
    assert decoded(call(cap, "repo_list", %{"path" => "."}))["entries"] == ["fixture.txt"]
    args = edit(decoded(result)["sha256"])
    assert %{"success" => true} = response = call(cap, "repo_write", args)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    assert call(cap, "repo_write", args) == response
    assert decoded(response)["sha256"] == digest("edited\n")
    assert %{"success" => false} = call(cap, "repo_write", edit(decoded(result)["sha256"], "different"))
    assert %{"success" => false} = call(cap, "repo_write", args, identity("repo_write", "second"))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_file_operations")["count"] == 1
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)

    assert Enum.map(WorkerFileTools.tool_specs(), & &1["name"]) ==
             ~w(repo_read repo_list repo_write repo_delete repo_mkdir repo_read_binary repo_write_binary)
  end

  test "a real failed reader cannot report success or grant source authority", ctx do
    cap = prepare(ctx)
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    fixture = Path.expand("../support/file_io_reader_fault.py", __DIR__)
    transport = %{path: fixture, sha256: digest(File.read!(fixture)), failure: "nonzero"}
    binding = Jason.decode!(access["binding_json"])
    assert {:error, :file_io_response_unproven, %{"exit_status" => 23}} = WorkerFileIO.request(ctx.path, binding, "read", %{"path" => "fixture.txt"}, transport)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert %{"success" => true} = read(cap)
  end

  for kind <- ~w(request status spool), failure <- ~w(truncated malformed scalar overflow deadline) do
    @reader_kind kind
    @reader_failure failure
    test "an actual #{@reader_failure} #{@reader_kind} transport cannot authorize work", ctx do
      cap = prepare(ctx)
      {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
      fixture = Path.expand("../support/file_io_reader_fault.py", __DIR__)
      transport = %{path: fixture, sha256: digest(File.read!(fixture)), failure: @reader_failure}

      result =
        case @reader_kind do
          "request" ->
            WorkerFileIO.request(ctx.path, Jason.decode!(access["binding_json"]), "read", %{"path" => "fixture.txt"}, transport)

          "status" ->
            assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n"), "base\n"))
            row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
            WorkerFileIO.recover_mutation(Jason.decode!(row["io_binding_json"]), transport)

          "spool" ->
            WorkerFileIO.workspace_allowed?(ctx.store, ctx.path, transport)
        end

      assert elem(result, 0) == :error
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      assert %{"success" => true} = read(cap)
    end
  end

  test "reader fixture selection is hash-pinned, outside source, and strictly negative", ctx do
    cap = prepare(ctx)
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    fixture = Path.expand("../support/file_io_reader_fault.py", __DIR__)
    transport = %{path: fixture, sha256: digest(File.read!(fixture)), failure: "nonzero"}
    binding = Jason.decode!(access["binding_json"])
    args = %{"path" => "fixture.txt"}
    assert {:error, :file_io_fixture_rejected} = WorkerFileIO.request(ctx.path, binding, "read", args, :invalid)
    assert {:error, :file_io_fixture_rejected} = WorkerFileIO.request(ctx.path, binding, "read", args, %{transport | failure: "success"})
    assert {:error, :file_io_fixture_changed} = WorkerFileIO.request(ctx.path, binding, "read", args, %{transport | sha256: String.duplicate("0", 64)})
    source_fixture = Path.join(ctx.path, "reader.py")
    File.cp!(fixture, source_fixture)
    assert {:error, :file_io_fixture_in_source} = WorkerFileIO.request(ctx.path, binding, "read", args, %{transport | path: source_fixture})
    assert %{"success" => true} = read(cap)
  end

  test "receipt validation rejects malformed containers, creator fields, cleanup and exits", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    valid = Jason.decode!(row["io_receipt_json"])
    assert WorkerFileIO.receipt_matches?(row["io_receipt_json"], row["arguments_sha256"])

    for bad <- [nil, 1, "null", "[]", "{", Jason.encode!(Map.delete(valid, "creator_json"))] do
      refute WorkerFileIO.receipt_matches?(bad, row["arguments_sha256"])
    end

    for bad <- [
          valid |> Map.put("creator_json", "[") |> Map.put("creator_sha256", digest("[")),
          valid |> Map.put("creator_json", "[]") |> Map.put("creator_sha256", digest("[]")),
          Map.put(valid, "cleanup", nil),
          Map.put(valid, "termination", %{"kind" => "exited", "code" => 256})
        ] do
      refute WorkerFileIO.receipt_matches?(Jason.encode!(bad), row["arguments_sha256"])
    end

    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    {:ok, _, reader} = WorkerFileIO.request(ctx.path, Jason.decode!(access["binding_json"]), "read", %{"path" => "fixture.txt"})
    assert WorkerFileIO.receipt_matches?(Jason.encode!(reader), reader["arguments_sha256"])
    assert {:error, :file_io_cancellation_binding_unproven} = WorkerFileIO.confirm_no_temporary(nil, nil)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "spool admission rejects missing roots and oversized source authority", ctx do
    cap = prepare(ctx)
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    missing = Path.join(ctx.root, "missing")
    assert {:error, :file_io_program_boundary_unproven} = WorkerFileIO.request(missing, Jason.decode!(access["binding_json"]), "read", %{"path" => "fixture.txt"})
    assert {:error, :file_io_spool_boundary_unproven} = WorkerFileIO.workspace_allowed?(ctx.store, missing)
    Store.query!(ctx.store, "UPDATE runs SET repo_path = ?", [String.duplicate("x", 2_097_152)])
    assert {:error, :file_io_frame_rejected} = WorkerFileIO.prepare_mutation(ctx.store, access, edit(digest("base\n")), %{"request_key" => cap.key})
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "an in-memory ledger cannot authorize a persistent file mutation", ctx do
    cap = prepare(ctx)
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    memory = start_supervised!(Supervisor.child_spec({Store, database: ":memory:"}, id: :memory_store))
    assert :ok = WorkerFileIO.workspace_allowed?(memory, ctx.path)
    assert {:error, :file_io_persistent_store_required} = WorkerFileIO.prepare_mutation(memory, access, edit(digest("base\n")), %{"request_key" => cap.key})
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "an unresolvable persistent ledger cannot admit the source workspace", ctx do
    directory = Path.join(ctx.root, "unresolvable-controller")
    retained = Path.join(ctx.root, "retained-controller")
    File.mkdir!(directory)
    database = Path.join(directory, "ledger.sqlite")
    store = start_supervised!(Supervisor.child_spec({Store, database: database}, id: :unresolvable_store))
    assert :ok = WorkerFileIO.workspace_allowed?(store, ctx.path)
    File.rename!(directory, retained)

    try do
      File.write!(directory, "not a directory")
      assert {:error, _} = error = SymphonyElixir.PathSafety.canonicalize(database)
      assert WorkerFileIO.workspace_allowed?(store, ctx.path) == error
    after
      File.rm!(directory)
      File.rename!(retained, directory)
    end

    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "a killed deletion helper aborts without needing replacement-temp authority", ctx do
    fixture = Path.expand("../support/file_io_signaled_child.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = %{"path" => "fixture.txt", "expected_sha256" => digest("base\n")}
    assert %{"success" => false} = call(cap, "repo_delete", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    assert row["phase"] == "ABORTED"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "the default companion dispatch recovers the same undispatched invocation", ctx do
    fixture = Path.expand("../support/file_io_transport_fault.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = edit("ABSENT", "created\n", "nonzero")
    assert %{"success" => false} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    assert {:ok, %{"sha256" => sha}, _} = WorkerFileIO.dispatch_mutation(binding, args)
    assert sha == digest("created\n")
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert File.read!(Path.join(ctx.path, "nonzero")) == "created\n"
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_file_operations")["count"] == 1
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a missing packaged reader returns a tool failure without changing the checkout", ctx do
    _cap = prepare(ctx)
    runtime = Path.join(ctx.root, "runtime/symphony_elixir")
    File.mkdir_p!(Path.join(runtime, "priv"))
    File.cp_r!(Path.expand("_build/test/lib/symphony_elixir/ebin"), Path.join(runtime, "ebin"))
    File.cp!(Path.expand("priv/worker_file_io.py"), Path.join(runtime, "priv/worker_file_io.py"))
    File.cp!(Path.expand("priv/worker_file_companion.py"), Path.join(runtime, "priv/worker_file_companion.py"))
    libraries = Path.expand("_build/test/lib")
    paths = Path.wildcard(Path.join(libraries, "*/ebin")) |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "symphony_elixir"))
    args = Enum.flat_map(paths ++ [Path.join(runtime, "ebin")], &["-pa", &1])
    script = Path.expand("../support/file_io_missing_asset.exs", __DIR__)
    {output, 0} = System.cmd(System.find_executable("elixir"), args ++ [script, ctx.database, runtime], stderr_to_stdout: true)
    evidence = output |> String.trim() |> Jason.decode!()
    assert evidence["helper"] == Path.join(runtime, "priv/worker_file_io.py")
    assert evidence["result"]["success"] == false
    assert decoded(evidence["result"])["error"] == ":enoent"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "recovery rejects corrupt primary payloads even when sidecars remain consistent", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    receipt_path = Path.join(binding["spool"], binding["invocation"] <> ".receipt")
    terminal_path = Path.join(binding["spool"], binding["invocation"] <> ".terminal")
    original = File.read!(receipt_path) |> Jason.decode!()

    for corrupted <- [Map.put(original, "version", 2), Map.put(original, "output_base64", "not base64!")] do
      File.write!(receipt_path, Jason.encode!(corrupted))
      File.write!(terminal_path, Jason.encode!(Map.delete(corrupted, "cleanup")))
      assert {:error, :file_io_receipt_rejected} = WorkerFileIO.recover_mutation(binding)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    end

    File.write!(receipt_path, Jason.encode!(original))
    File.write!(terminal_path, Jason.encode!(Map.delete(original, "cleanup")))
    assert {:ok, _, _} = WorkerFileIO.recover_mutation(binding)
  end

  test "a non-test runtime rejects every reader override before launching its fixture", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    libraries = Path.expand("_build/dev/lib")
    paths = Path.wildcard(Path.join(libraries, "*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1])
    script = Path.expand("../support/file_io_production_override.exs", __DIR__)
    fixture = Path.expand("../support/file_io_reader_fault.py", __DIR__)
    {output, 0} = System.cmd(System.find_executable("elixir"), args ++ [script, ctx.database, ctx.path, row["io_binding_json"], fixture], stderr_to_stdout: true)
    results = output |> String.trim() |> Jason.decode!()
    assert results["request"] == "{:error, :file_io_fixture_rejected}"
    assert results["status"] == "{:error, :file_io_fixture_rejected}"
    assert results["spool"] == "{:error, :file_io_spool_boundary_unproven}"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "creation is restricted to an existing source directory, and preserves mode on replacements", ctx do
    cap = prepare(ctx)
    File.chmod!(Path.join(ctx.path, "fixture.txt"), 0o755)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    assert Bitwise.band(File.stat!(Path.join(ctx.path, "fixture.txt")).mode, 0o777) == 0o755
    assert %{"success" => true} = call(cap, "repo_write", edit("ABSENT", "new\n", "new.txt"), identity("repo_write", "new"))
    assert File.read!(Path.join(ctx.path, "new.txt")) == "new\n"
    assert %{"success" => false} = call(cap, "repo_write", edit("ABSENT", "new", "missing/new.txt"), identity("repo_write", "missing"))
    assert %{"success" => false} = call(cap, "repo_read", %{"path" => ".", "start_line" => 1})
    assert %{"success" => false} = call(cap, "repo_list", %{"path" => "fixture.txt"})
    File.mkdir!(Path.join(ctx.path, "directory"))
    assert %{"success" => false} = read(cap, "directory")
  end

  test "source deletion requires the exact contents and is replayable without deleting a replacement", ctx do
    cap = prepare(ctx)
    args = %{"path" => "fixture.txt", "expected_sha256" => digest("base\n")}
    assert %{"success" => true} = response = call(cap, "repo_delete", args)
    assert decoded(response) == %{"path" => "fixture.txt", "sha256" => "ABSENT", "status" => "APPLIED"}
    assert decoded(call(cap, "repo_list", %{"path" => "."}))["entries"] == []
    assert call(cap, "repo_delete", args) == response
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => true} = call(cap, "repo_write", edit("ABSENT", "replacement\n"), identity("repo_write", "replacement"))
    assert %{"success" => false} = call(cap, "repo_delete", args)
    assert decoded(read(cap))["text"] == "replacement\n"
  end

  test "deletion rejects stale contents, directories, control paths and linked outside data", ctx do
    cap = prepare(ctx)
    outside = Path.join(ctx.root, "secret")
    File.write!(outside, "private\n")
    File.ln_s!(outside, Path.join(ctx.path, "link"))
    File.ln!(outside, Path.join(ctx.path, "hardlink"))
    File.mkdir!(Path.join(ctx.path, "directory"))
    File.write!(Path.join(ctx.path, "directory/keep.txt"), "keep\n")

    for {path, expected} <- [
          {"fixture.txt", digest("stale\n")},
          {"fixture.txt", "ABSENT"},
          {"directory", digest("keep\n")},
          {"../secret", digest("private\n")},
          {"link", digest("private\n")},
          {"hardlink", digest("private\n")},
          {".git", digest("private\n")},
          {".FACTORY-FILE-IO/claim", digest("private\n")}
        ] do
      assert %{"success" => false} = call(cap, "repo_delete", %{"path" => path, "expected_sha256" => expected})
    end

    assert decoded(read(cap))["text"] == "base\n"
    assert File.read!(outside) == "private\n"
    assert File.read!(Path.join(ctx.path, "directory/keep.txt")) == "keep\n"
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")

    assert {:error, :file_io_committed_mutation_required} =
             WorkerFileIO.request(ctx.path, Jason.decode!(access["binding_json"]), "delete", %{"path" => "fixture.txt", "expected_sha256" => digest("base\n")})
  end

  test "directory creation permits nested source files without adding tracked marker files", ctx do
    cap = prepare(ctx)
    args = %{"path" => "new"}
    assert %{"success" => true} = response = call(cap, "repo_mkdir", args)
    assert decoded(response) == %{"path" => "new", "status" => "APPLIED"}
    assert decoded(call(cap, "repo_list", args))["entries"] == []
    assert call(cap, "repo_mkdir", args) == response
    assert %{"success" => true} = call(cap, "repo_mkdir", %{"path" => "new/nested"}, identity("repo_mkdir", "nested"))
    assert %{"success" => true} = call(cap, "repo_write", edit("ABSENT", "nested source\n", "new/nested/source.txt"), identity("repo_write", "source"))
    assert decoded(read(cap, "new/nested/source.txt"))["text"] == "nested source\n"
    assert git(ctx.path, ["status", "--porcelain", "--untracked-files=all"]) == "?? new/nested/source.txt\n"
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "directory creation refuses existing, missing-parent, symlink and control targets", ctx do
    cap = prepare(ctx)
    outside = Path.join(ctx.root, "outside")
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(ctx.path, "linked"))
    File.mkdir!(Path.join(ctx.path, "existing"))

    for path <- ["existing", "missing/child", "linked/child", ".", "../outside/child", ".git/new", ".Codex/new", ".FACTORY-FILE-IO/new"] do
      assert %{"success" => false} = call(cap, "repo_mkdir", %{"path" => path})
    end

    assert File.ls!(outside) == []
    assert decoded(call(cap, "repo_list", %{"path" => "existing"}))["entries"] == []
  end

  test "binary source fixtures can be created, inspected and deleted without text conversion", ctx do
    cap = prepare(ctx)
    args = %{"path" => "fixture.bin", "expected_sha256" => "ABSENT", "content_base64" => "iVBORw0KGgoA/w=="}
    assert %{"success" => true} = written = call(cap, "repo_write_binary", args)
    assert File.read!(Path.join(ctx.path, "fixture.bin")) == <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255>>
    assert %{"success" => true} = inspected = call(cap, "repo_read_binary", %{"path" => "fixture.bin", "offset" => 0})
    assert decoded(inspected)["content_base64"] == "iVBORw0KGgoA/w=="
    assert decoded(inspected)["sha256"] == decoded(written)["sha256"]
    assert decoded(inspected)["next_offset"] == nil
    assert %{"success" => false} = read(cap, "fixture.bin")
    assert %{"success" => true} = call(cap, "repo_delete", %{"path" => "fixture.bin", "expected_sha256" => decoded(inspected)["sha256"]}, identity("repo_delete", "delete-binary"))
    assert decoded(call(cap, "repo_list", %{"path" => "."}))["entries"] == ["fixture.txt"]
  end

  test "text writes cannot convert an existing binary fixture implicitly", ctx do
    cap = prepare(ctx)
    File.write!(Path.join(ctx.path, "fixture.bin"), <<0, 255>>)
    inspected = decoded(call(cap, "repo_read_binary", %{"path" => "fixture.bin", "offset" => 0}))
    assert %{"success" => false} = call(cap, "repo_write", edit(inspected["sha256"], "converted text\n", "fixture.bin"))
    assert File.read!(Path.join(ctx.path, "fixture.bin")) == <<0, 255>>
    args = %{"path" => "fixture.bin", "expected_sha256" => inspected["sha256"], "content_base64" => "AAE="}
    assert %{"success" => true} = call(cap, "repo_write_binary", args)
    assert File.read!(Path.join(ctx.path, "fixture.bin")) == <<0, 1>>
  end

  test "binary pages and replacements enforce byte bounds, canonical encoding and exact content checks", ctx do
    cap = prepare(ctx)
    raw = :binary.copy(<<0, 255>>, 10_000)
    File.write!(Path.join(ctx.path, "fixture.bin"), raw)
    first = decoded(call(cap, "repo_read_binary", %{"path" => "fixture.bin", "offset" => 0}))
    assert first["next_offset"] == 8_192 and first["total_bytes"] == 20_000
    assert Base.decode64!(first["content_base64"]) == :binary.copy(<<0, 255>>, 4_096)
    last = decoded(call(cap, "repo_read_binary", %{"path" => "fixture.bin", "offset" => 16_384}))
    assert last["next_offset"] == nil
    assert Base.decode64!(last["content_base64"]) == :binary.copy(<<0, 255>>, 1_808)

    for offset <- [-1, 20_001, 262_145, "0"] do
      assert %{"success" => false} = call(cap, "repo_read_binary", %{"path" => "fixture.bin", "offset" => offset})
    end

    for encoded <- ["%%%", "YQ", "YQ==\n", "YR==", Base.encode64(:binary.copy(<<0>>, 262_145))] do
      args = %{"path" => "fixture.bin", "expected_sha256" => first["sha256"], "content_base64" => encoded}
      assert %{"success" => false} = call(cap, "repo_write_binary", args)
    end

    stale = %{"path" => "fixture.bin", "expected_sha256" => digest("stale"), "content_base64" => "AAE="}
    assert %{"success" => false} = call(cap, "repo_write_binary", stale)
    assert File.read!(Path.join(ctx.path, "fixture.bin")) == raw
    args = %{stale | "expected_sha256" => first["sha256"]}
    assert %{"success" => true} = response = call(cap, "repo_write_binary", args)
    assert call(cap, "repo_write_binary", args) == response
    assert File.read!(Path.join(ctx.path, "fixture.bin")) == <<0, 1>>
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "removed historical checkouts and repositories do not prevent a current source edit", ctx do
    old_paths =
      for state <- ["DELIVERED", "AWAITING_VALIDATION"] do
        old_path = Path.join(ctx.root, "workspaces/removed-#{state}")
        register(ctx, "old-#{state}", "PPL-124", "writer-#{state}", old_path)
        {:ok, _} = TaskLedger.update(ctx.store, "writer-#{state}", %{status: "COMPLETE"})
        {:ok, _} = RunLedger.update(ctx.store, "old-#{state}", %{state: state, workspace_state: "HIBERNATED", repo_path: Path.join(ctx.root, "removed-repo")})
        old_path
      end

    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED'")
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    for path <- old_paths, do: refute(File.exists?(path))
  end

  test "missing active roots and symlink roots are not mistaken for removed historical workspaces", ctx do
    other_path = Path.join(ctx.root, "workspaces/missing-active")
    register(ctx, "other-run", "PPL-124", "other-writer", other_path)
    cap = prepare(ctx)
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    {:ok, _} = TaskLedger.update(ctx.store, "other-writer", %{status: "COMPLETE"})
    {:ok, _} = RunLedger.update(ctx.store, "other-run", %{state: "DELIVERED"})
    File.ln_s!(ctx.path, other_path)
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "controller spool files stay unreadable through both worker and fixed-helper entrypoints", ctx do
    cap = prepare(ctx)
    private = Path.join(ctx.path, ".factory-file-io")
    File.mkdir!(private)
    File.write!(Path.join(private, "claim"), "private receipt\n")
    {:ok, access} = WorkspaceAccess.get(ctx.store, "reservation")
    binding = Jason.decode!(access["binding_json"])

    for path <- [".factory-file-io/claim", ".FACTORY-FILE-IO/claim"] do
      assert %{"success" => false} = read(cap, path)
      assert %{"success" => false} = call(cap, "repo_write", edit("ABSENT", "hacked", path))
      assert {:error, {:file_io_rejected, "path_rejected"}, _} = WorkerFileIO.request(ctx.path, binding, "read", %{"path" => path})
    end

    assert decoded(call(cap, "repo_list", %{"path" => "."}))["entries"] == ["fixture.txt"]
    assert File.read!(Path.join(private, "claim")) == "private receipt\n"
  end

  test "a case-aliased source root cannot contain the fixed controller program" do
    helper = Application.app_dir(:symphony_elixir, "priv/worker_file_io.py")
    {:ok, directory} = SymphonyElixir.PathSafety.canonicalize(Path.dirname(helper))
    alias_path = Path.join(Path.dirname(directory), String.upcase(Path.basename(directory)))
    stat = File.stat!(alias_path)
    assert stat.inode == File.stat!(directory).inode
    binding = %{"root_device" => stat.major_device, "root_inode" => stat.inode}
    assert {:error, :file_io_helper_in_source} = WorkerFileIO.request(alias_path, binding, "read", %{"path" => "worker_file_io.py"})
  end

  test "an existing permissive spool is rejected without silently repairing its permissions", ctx do
    cap = prepare(ctx)
    spool = Path.join(ctx.root, ".factory-file-io")
    File.mkdir!(spool)
    File.chmod!(spool, 0o755)
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    assert Bitwise.band(File.stat!(spool).mode, 0o777) == 0o755
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    File.chmod!(spool, 0o700)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    assert Bitwise.band(File.stat!(spool).mode, 0o777) == 0o700
  end

  for operation <- [:read, :write] do
    test "#{operation} rejects traversal, control files, links and nonregular targets without exposing or changing outside data", ctx do
      cap = prepare(ctx)
      outside = Path.join(ctx.root, "secret")
      File.write!(outside, "private\n")
      File.ln_s!(outside, Path.join(ctx.path, "link"))
      File.ln!(outside, Path.join(ctx.path, "hardlink"))
      File.ln_s!(ctx.root, Path.join(ctx.path, "linked-directory"))

      for path <- [
            "../secret",
            outside,
            ".git",
            ".GIT",
            ".Codex/config",
            ".ENV",
            "NODE_MODULES/source",
            ".git/config",
            ".env",
            ".env.local",
            ".codex/config",
            "a/../fixture.txt",
            "a//b",
            "./fixture.txt",
            "link",
            "hardlink",
            "linked-directory/secret",
            "fixture.txt/child",
            "a\\b",
            "a\n",
            <<0>>,
            "",
            <<255>>,
            12
          ] do
        result =
          case unquote(operation) do
            :read -> read(cap, path)
            :write -> call(cap, "repo_write", edit("ABSENT", "hacked", path))
          end

        assert %{"success" => false} = result
      end

      assert File.read!(outside) == "private\n"
      assert File.read!(Path.join(ctx.path, ".git")) =~ "gitdir:"
    end
  end

  test "schema, tool namespace and native request identities fail closed", ctx do
    cap = prepare(ctx)
    args = %{"path" => "fixture.txt", "start_line" => 1}

    for {tool, input, id} <- [
          {"shell", %{"command" => "true"}, identity("shell")},
          {"repo_read", "bad", identity("repo_read")},
          {"repo_read", Map.put(args, "command", "true"), identity("repo_read")},
          {"repo_read", args, %{}},
          {"repo_read", args, Map.put(identity("repo_read"), "namespace", "controller")},
          {"repo_read", args, Map.put(identity("repo_read"), "tool", "other")},
          {"repo_read", args, Map.put(identity("repo_read"), "threadId", "parent")},
          {"repo_read", args, Map.put(identity("repo_read"), "turnId", "old")},
          {"repo_read", args, Map.put(identity("repo_read"), "callId", "")},
          {"repo_read", args, nil}
        ] do
      assert %{"success" => false} = WorkerFileTools.execute(cap, tool, input, id)
    end

    for expected <- [nil, "BAD", String.duplicate("f", 65)] do
      assert %{"success" => false} = call(cap, "repo_write", edit(expected))
    end

    for content <- [nil, <<255>>, "abc" <> <<0>>, String.duplicate("x", 262_145)] do
      assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n"), content))
    end

    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
  end

  test "authority is rechecked after every input or reservation change and after turn completion", ctx do
    cap = prepare(ctx)
    assert {:error, :file_worker_owner_mismatch} = WorkerFileTools.bind(ctx.store, cap.key, "other")
    assert {:error, :file_worker_capability_required} = WorkerFileTools.preflight(nil, ctx.path)
    assert {:error, :file_worker_not_starting} = WorkerFileTools.preflight(cap, ctx.path)
    assert %{"success" => false} = read(%{cap | owner: "other"})
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{model: "other"})
    assert %{"success" => false} = read(cap)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{model: "gpt-6-luna"})
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [String.duplicate("a", 40)])
    assert %{"success" => false} = read(cap)
    Store.query!(ctx.store, "UPDATE runs SET candidate_sha = ? WHERE run_id = 'run'", [ctx.sha])
    Store.query!(ctx.store, "UPDATE workspace_access SET generation = generation + 1")
    assert %{"success" => false} = read(cap)
    Store.query!(ctx.store, "UPDATE workspace_access SET generation = generation - 1")
    Store.query!(ctx.store, "UPDATE worker_evidence SET status = 'RECONCILE_REQUIRED'")
    assert %{"success" => false} = read(cap)
    Store.query!(ctx.store, "UPDATE worker_evidence SET status = 'TURN_BOUND', binding_json = '{}'")
    assert %{"success" => false} = read(cap)
    assert {:error, :file_worker_binding_corrupt} = WorkerFileTools.bind(ctx.store, cap.key, "owner")
  end

  test "read bounds, pagination and nontext rejection are deterministic", ctx do
    cap = prepare(ctx)
    path = Path.join(ctx.path, "fixture.txt")
    File.write!(path, Enum.map_join(1..220, "\n", &"line #{&1}"))
    page = decoded(read(cap))
    assert page["next_line"] == 101
    last = decoded(call(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => 201}))
    assert last["next_line"] == nil and last["text"] =~ "line 220"
    for line <- [0, -1, 221, "1", 262_145], do: assert(%{"success" => false} = call(cap, "repo_read", %{"path" => "fixture.txt", "start_line" => line}))

    for raw <- [String.duplicate("x", 262_145), String.duplicate("x", 20_000), <<255>>, <<0>>] do
      File.write!(path, raw)
      assert %{"success" => false} = read(cap)
      assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    end

    assert %{"success" => false} = read(cap, "missing")
    File.mkdir!(Path.join(ctx.path, "large"))
    for i <- 1..513, do: File.write!(Path.join([ctx.path, "large", "#{i}"]), "")
    assert %{"success" => false} = call(cap, "repo_list", %{"path" => "large"})
    File.mkdir!(Path.join(ctx.path, "wide"))
    for i <- 1..100, do: File.write!(Path.join([ctx.path, "wide", String.duplicate("x", 200) <> "#{i}"]), "")
    assert %{"success" => false} = call(cap, "repo_list", %{"path" => "wide"})
  end

  test "a lost response replays only the same exact operation after restart, never repeats a changed edit", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED'")
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED'")
    reopened = start_supervised!({Store, database: ctx.database}, id: :reopened)

    try do
      assert %{"success" => true} = call(%{cap | store: reopened}, "repo_write", args)
    after
      stop_supervised!(:reopened)
    end

    File.write!(Path.join(ctx.path, "fixture.txt"), "third-party edit\n")
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "third-party edit\n"
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED'")
    assert {:error, :file_worker_edit_reconciliation_required} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", edit("ABSENT", "new", "another.txt"), identity("repo_write", "next"))
    refute File.exists?(Path.join(ctx.path, "another.txt"))
  end

  test "unresolved disk outcome blocks result consumption and reservation release", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    Store.query!(ctx.store, "UPDATE worker_file_operations SET io_pending = 1, io_binding_json = NULL, io_invocation = NULL")
    {:ok, _} = WorkerEvidence.record_result(ctx.store, cap.key, %{thread_id: "worker", turn_id: "turn", item_id: "final", output: %{}})
    {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, cap.key, "owner", stop_receipt(ctx))
    assert {:error, :worker_file_edits_unreconciled} = WorkerEvidence.consume(ctx.store, cap.key)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0")
    assert {:error, :worker_file_edits_unreconciled} = WorkerEvidence.consume(ctx.store, cap.key)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert %{"success" => false} = read(cap)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "review permissions and changed source HEAD never acquire file writer capabilities", ctx do
    cap = prepare(ctx)
    git(ctx.path, ["commit", "--allow-empty", "--no-verify", "-m", "outside change"])
    assert %{"success" => false} = read(cap)
    {:ok, evidence} = WorkerEvidence.get(ctx.store, cap.key)
    binding = Jason.decode!(evidence["binding_json"]) |> Map.put("policy", TicketWorkerRunner.policy("REVIEW", ctx.path)) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE worker_evidence SET binding_json = ?, binding_sha256 = ?", [binding, digest(binding)])
    assert {:error, :file_worker_policy_required} = WorkerFileTools.bind(ctx.store, cap.key, "owner")
    assert {:error, :file_worker_policy_required} = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "a replacement checkout at the same pathname never inherits an active file capability", ctx do
    cap = prepare(ctx)
    git_file = File.read!(Path.join(ctx.path, ".git"))
    retained = ctx.path <> "-retained"
    File.rename!(ctx.path, retained)
    File.mkdir!(ctx.path)
    File.write!(Path.join(ctx.path, ".git"), git_file)
    File.write!(Path.join(ctx.path, "fixture.txt"), "base\n")
    assert %{"success" => false} = read(cap)
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert File.read!(Path.join(retained, "fixture.txt")) == "base\n"
  end

  test "UTF-8 source filenames and content remain usable without interpreting text as commands", ctx do
    cap = prepare(ctx)
    path = "résumé.txt"
    content = "literal $(touch outside)\n你好\n"
    assert %{"success" => true} = call(cap, "repo_write", edit("ABSENT", content, path))
    assert %{"success" => true} = result = read(cap, path)
    assert decoded(result)["text"] == content
    assert decoded(call(cap, "repo_list", %{"path" => "."}))["entries"] == ["fixture.txt", path]
    refute File.exists?(Path.join(ctx.path, "outside"))
  end

  test "an unproven helper exit prevents replay and reconciliation even when target bytes match", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 1, io_receipt_json = NULL, io_binding_json = NULL, io_invocation = NULL")
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    assert %{"success" => false} = call(cap, "repo_write", edit("ABSENT", "another", "another.txt"), identity("repo_write", "next"))
    refute File.exists?(Path.join(ctx.path, "another.txt"))
  end

  test "upgrading historical pending edits never invents a helper stop receipt", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_binding_json = NULL, io_invocation = NULL")
    Store.query!(ctx.store, "ALTER TABLE worker_file_operations DROP COLUMN io_pending")
    Store.query!(ctx.store, "ALTER TABLE worker_file_operations DROP COLUMN io_receipt_json")
    assert :ok = Store.initialize(ctx.store)
    assert :ok = Store.initialize(ctx.store)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    reopened = start_supervised!({Store, database: ctx.database}, id: :upgraded)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(reopened, cap.key)
  end

  test "a partial upgrade cannot make a pending edit without a receipt reconcilable", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_receipt_json = NULL, io_binding_json = NULL, io_invocation = NULL")
    assert :ok = Store.initialize(ctx.store)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "a historical exit receipt without its exact invocation binding stays quarantined after upgrade", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    legacy = row["io_receipt_json"] |> Jason.decode!() |> Map.drop(~w(termination binding_sha256)) |> Jason.encode!()
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_binding_json = NULL, io_invocation = NULL, io_receipt_json = ?", [legacy])
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert :ok = Store.initialize(ctx.store)
    reopened = start_supervised!({Store, database: ctx.database}, id: :historical_receipt)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(reopened, cap.key)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "valid-looking receipts cannot authorize a changed binding or a substituted invocation", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])

    for {field, value} <- [{"profile_sha256", String.duplicate("f", 64)}, {"run_id", "other-run"}, {"generation", 2}, {"invocation", String.duplicate("a", 64)}] do
      changed = Jason.encode!(Map.put(binding, field, value))
      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_binding_json = ?", [changed])
      assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert :ok = Store.initialize(ctx.store)
      assert {:error, _} = WorkerFileTools.reconcile(ctx.store, cap.key)
    end

    Store.query!(ctx.store, "UPDATE worker_file_operations SET io_pending = 0, io_binding_json = ?, io_invocation = ?", [row["io_binding_json"], String.duplicate("b", 64)])
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "malformed pending invocation bindings stay quarantined without crashing recovery", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)

    for binding <- [nil, "{", "[]", "null", "\"string\""] do
      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 1, io_binding_json = ?", [binding])
      assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert :ok = Store.initialize(ctx.store)
    end

    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "malformed or another operation's exit receipt never authorizes recovery", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    raw = row["io_receipt_json"]
    receipt = Jason.decode!(raw)

    invalid = [
      nil,
      "{",
      "[]",
      Jason.encode!(Map.put(receipt, "arguments_sha256", String.duplicate("a", 64))),
      Jason.encode!(Map.put(receipt, "exit_status", "0")),
      Jason.encode!(Map.put(receipt, "nonce", "bad"))
    ]

    for evidence <- invalid do
      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_receipt_json = ?, io_binding_json = NULL, io_invocation = NULL", [evidence])
      assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert :ok = Store.initialize(ctx.store)
      assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    end

    Store.query!(ctx.store, "UPDATE worker_file_operations SET io_pending = 0, io_receipt_json = ?, io_binding_json = ?, io_invocation = ?", [raw, row["io_binding_json"], row["io_invocation"]])
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "a pre-existing invocation temporary is never removed by a failed source edit", ctx do
    fixture = Path.expand("../support/file_io_late_start.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    owner = Task.async(fn -> call(cap, "repo_write", edit(digest("base\n"))) end)

    try do
      assert wait_for_file(Path.join(ctx.root, "dispatch-withheld"), System.monotonic_time(:millisecond) + 6_000)
      row = Store.one!(ctx.store, "SELECT io_invocation FROM worker_file_operations")
      collision = Path.join(ctx.path, ".symphony-" <> row["io_invocation"])
      File.write!(collision, "unrelated temporary\n")
      File.write!(Path.join(ctx.root, "dispatch-release"), "release\n")
      assert %{"success" => false} = Task.await(owner, 10_000)
      assert File.read!(collision) == "unrelated temporary\n"
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    after
      File.write!(Path.join(ctx.root, "dispatch-release"), "release\n")
      Task.shutdown(owner, :brutal_kill)
    end
  end

  test "a proven stopped unchanged edit can be cancelled and retried as a new call", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    File.chmod!(ctx.path, 0o500)

    try do
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert decoded(call(cap, "repo_write", args))["error"] == ":file_worker_operation_aborted"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      File.chmod!(ctx.path, 0o755)
      assert %{"success" => true} = call(cap, "repo_write", args, identity("repo_write", "retry"))
      assert decoded(read(cap))["text"] == "edited\n"
    after
      File.chmod!(ctx.path, 0o755)
    end
  end

  test "recovery rejects altered effect metadata even when another file has the expected bytes", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    File.write!(Path.join(ctx.path, "other.txt"), "edited\n")
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', path = 'other.txt'")
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    assert File.read!(Path.join(ctx.path, "other.txt")) == "edited\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a rejected transport cannot mutate source or release its pending source reservation", ctx do
    cap = prepare(ctx) |> Map.put(:file_io_transport, :invalid)
    args = edit(digest("base\n"))
    assert %{"success" => false} = response = call(cap, "repo_write", args)
    assert decoded(response)["error"] == ":file_io_fixture_rejected"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  for failure <- ~w(nonzero truncated overflow deadline) do
    @failure failure
    test "an actual #{@failure} companion transport remains quarantined without a receipt", ctx do
      fixture = Path.expand("../support/file_io_transport_fault.py", __DIR__)
      cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
      args = edit("ABSENT", "never written\n", @failure)

      assert %{"success" => false} = call(cap, "repo_write", args)
      assert File.read!(Path.join(ctx.root, "fault-started")) == @failure
      refute File.exists?(Path.join(ctx.path, @failure))
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert %{"success" => false} = call(Map.delete(cap, :file_io_transport), "repo_write", edit(digest("base\n")), identity("repo_write", "another"))
      operation = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
      assert operation["phase"] == "PREPARED"
      assert operation["io_pending"] == 1
      assert operation["io_receipt_json"] == nil
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    end
  end

  test "malformed durable child receipts quarantine recovery without crashing or rewriting source", ctx do
    cap = prepare(ctx)
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    receipt_path = Path.join(binding["spool"], binding["invocation"] <> ".receipt")
    original = File.read!(receipt_path)
    record = Jason.decode!(original)

    for corrupted <- [
          Map.put(record, "version", 2),
          Map.delete(record, "pid"),
          Map.put(record, "pid", -1),
          Map.put(record, "termination", %{"kind" => "unknown", "code" => 0}),
          Map.put(record, "termination", %{"kind" => "exited", "code" => 256}),
          Map.put(record, "output_base64", "not base64!")
        ] do
      File.write!(receipt_path, Jason.encode!(corrupted))
      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 1, io_receipt_json = NULL")
      assert {:error, _} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    end

    File.write!(receipt_path, original)
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => true} = call(cap, "repo_write", args)
  end

  test "a stopped helper records its exact temporary creator before source bytes may be written", ctx do
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    observed = ctx.root |> Path.join("creator-stop-observed") |> File.read!() |> Jason.decode!()
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    receipt = Jason.decode!(row["io_receipt_json"])
    creator = Jason.decode!(receipt["creator_json"])
    binding = Jason.decode!(row["io_binding_json"])

    assert receipt["termination"] == %{"kind" => "signaled", "signal" => 9}
    assert receipt["pid"] == observed["pid"]
    assert receipt["creator_sha256"] == digest(receipt["creator_json"])
    assert creator["binding_sha256"] == digest(row["io_binding_json"])
    assert creator["nonce"] == row["io_invocation"]
    assert creator["pid"] == receipt["pid"]
    assert creator["path"] == "fixture.txt"
    assert creator["temporary"] == ".symphony-" <> row["io_invocation"]
    assert {creator["device"], creator["inode"]} == {observed["device"], observed["inode"]}
    assert {creator["root_device"], creator["root_inode"]} == {binding["root_device"], binding["root_inode"]}
    assert observed["bytes"] == 0
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    refute File.exists?(Path.join(ctx.path, creator["temporary"]))
    assert row["phase"] == "ABORTED"
    assert receipt["cleanup"]["termination"] == %{"kind" => "exited", "code" => 0}
    assert receipt["cleanup"]["helper_pid"] == receipt["cleanup"]["pid"]
    assert receipt["cleanup"]["original_pid"] == receipt["pid"]
    assert receipt["cleanup"]["creator_sha256"] == receipt["creator_sha256"]
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    assert %{"success" => true} = call(Map.delete(cap, :file_io_transport), "repo_write", edit(digest("base\n")), identity("repo_write", "retry"))
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "completed helper artifacts recover a killed companion without publishing or rerunning the edit", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-loss")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    receipt_path = Path.join(binding["spool"], binding["invocation"] <> ".receipt")
    observed = ctx.root |> Path.join("companion-stop-observed") |> File.read!() |> Jason.decode!()
    paths = Map.new(~w(claim creator terminal cleanup), &{&1, Path.join(binding["spool"], binding["invocation"] <> "." <> &1)})
    artifacts = Map.new(paths, fn {name, path} -> {name, File.read!(path)} end)
    refute File.exists?(receipt_path)

    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    recovered = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    receipt = Jason.decode!(recovered["io_receipt_json"])
    assert recovered["phase"] == "ABORTED"
    assert recovered["io_pending"] == 0
    assert receipt["recovery"]["kind"] == "COMPLETE_ARTIFACTS"
    assert receipt["pid"] == observed["primary_pid"]
    assert receipt["cleanup"]["pid"] == observed["cleanup_pid"]
    assert receipt["termination"] == %{"kind" => "signaled", "signal" => 9}
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    refute File.exists?(receipt_path)
    assert Map.new(paths, fn {name, path} -> {name, File.read!(path)} end) == artifacts
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "a completed edit survives final-publication loss and replays without another helper", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-loss-applied")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = edit(digest("base\n"))
    assert %{"success" => true} = result = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    receipt = Jason.decode!(row["io_receipt_json"])
    assert row["phase"] == "APPLIED"
    assert receipt["termination"] == %{"kind" => "exited", "code" => 0}
    assert receipt["recovery"]["kind"] == "COMPLETE_ARTIFACTS"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    assert call(cap, "repo_write", args) == result
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_file_operations")["count"] == 1
    refute File.exists?(Path.join(binding["spool"], binding["invocation"] <> ".receipt"))
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "cached artifact recovery accepts the same producer's later final publication", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-barrier")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    deadline = System.monotonic_time(:millisecond) + 10_000
    owner = Task.async(fn -> call(cap, "repo_write", edit(digest("base\n"))) end)
    release = Path.join(ctx.root, "companion-release")

    recovered =
      try do
        :ok = await_marker(Path.join(ctx.root, "companion-stop-observed"), owner, deadline)
        assert Task.yield(owner, 0) == nil
        row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
        binding = Jason.decode!(row["io_binding_json"])
        refute File.exists?(Path.join(binding["spool"], binding["invocation"] <> ".receipt"))
        assert {:ok, _, receipt} = WorkerFileIO.recover_mutation(binding)
        assert receipt["recovery"]["kind"] == "COMPLETE_ARTIFACTS"
        receipt
      after
        File.write!(release, "release")
      end

    assert %{"success" => true} = Task.await(owner, max(deadline - System.monotonic_time(:millisecond), 0))
    completed = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(completed["io_binding_json"])

    for name <- ~w(terminal cleanup) do
      path = Path.join(binding["spool"], binding["invocation"] <> "." <> name)
      raw = File.read!(path)
      equivalent = raw |> Jason.decode!() |> Jason.encode!(pretty: true)
      refute equivalent == raw
      File.write!(path, equivalent)
    end

    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_receipt_json = ?", [Jason.encode!(recovered)])
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    assert row["phase"] == "APPLIED"
    refute Map.has_key?(Jason.decode!(row["io_receipt_json"]), "recovery")
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "replay cannot adopt an after-state from cached artifacts that no longer exist", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-loss-applied")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    path = Path.join(binding["spool"], binding["invocation"] <> ".cleanup")
    original = File.read!(path)
    File.rm!(path)
    Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0")
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert Store.one!(ctx.store, "SELECT phase FROM worker_file_operations")["phase"] == "PREPARED"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    File.write!(path, original)
    assert %{"success" => true} = call(cap, "repo_write", args)
  end

  test "complete-artifact recovery refuses missing or corrupt sidecars even after caching", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-loss")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])

    for location <- ~w(journal cached), name <- ~w(claim creator terminal cleanup), fault <- ~w(missing corrupt) do
      path = Path.join(binding["spool"], binding["invocation"] <> "." <> name)
      original = File.read!(path)
      if fault == "missing", do: File.rm!(path), else: File.write!(path, "{}")
      pending = if location == "journal", do: 1, else: 0
      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = ?, io_receipt_json = ?", [pending, row["io_receipt_json"]])
      assert {:error, _} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert Store.one!(ctx.store, "SELECT phase FROM worker_file_operations")["phase"] == "PREPARED"
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      File.write!(path, original)
    end

    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "cached recovery markers must retain their exact schema", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-loss-applied")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = edit(digest("base\n"))
    assert %{"success" => true} = call(cap, "repo_write", args)
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    receipt = Jason.decode!(row["io_receipt_json"])
    marker = receipt["recovery"]

    for corrupt <- [
          Map.put(marker, "kind", "PUBLISHED"),
          Map.put(marker, "extra", true),
          Map.delete(marker, "kind"),
          Map.put(marker, "kind", nil),
          "COMPLETE_ARTIFACTS"
        ] do
      raw = receipt |> Map.put("recovery", corrupt) |> Jason.encode!()
      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_receipt_json = ?", [raw])
      assert {:error, _} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert Store.one!(ctx.store, "SELECT io_receipt_json FROM worker_file_operations")["io_receipt_json"] == raw
      assert %{"success" => false} = call(cap, "repo_write", args)
      assert Store.one!(ctx.store, "SELECT phase FROM worker_file_operations")["phase"] == "PREPARED"
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    end

    Store.query!(ctx.store, "UPDATE worker_file_operations SET io_receipt_json = ?", [row["io_receipt_json"]])
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "an existing invalid final receipt cannot fall back to complete helper artifacts", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "receipt-loss")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    receipt = Path.join(binding["spool"], binding["invocation"] <> ".receipt")
    terminal = Path.join(binding["spool"], binding["invocation"] <> ".terminal")

    for fault <- ~w(malformed symlink hardlink directory) do
      case fault do
        "malformed" -> File.write!(receipt, "{")
        "symlink" -> File.ln_s!("missing-receipt-target", receipt)
        "hardlink" -> File.ln!(terminal, receipt)
        "directory" -> File.mkdir!(receipt)
      end

      Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 1, io_receipt_json = NULL")
      assert {:error, _} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      if fault == "directory", do: File.rmdir!(receipt), else: File.rm!(receipt)
    end

    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "an existing creator sidecar cannot be omitted from the actual terminal receipt", ctx do
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    receipt_path = Path.join(binding["spool"], binding["invocation"] <> ".receipt")
    original = File.read!(receipt_path)
    record = original |> Jason.decode!() |> Map.drop(~w(creator_json creator_sha256))
    File.write!(receipt_path, Jason.encode!(record))
    Store.query!(ctx.store, "UPDATE worker_file_operations SET io_pending = 1, io_receipt_json = NULL")

    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    refute File.exists?(Path.join(ctx.path, ".symphony-" <> binding["invocation"]))
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")

    File.write!(receipt_path, original)
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "attested temporary cleanup preserves a replacement inode and keeps source quarantined", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "replacement")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    observed = ctx.root |> Path.join("creator-stop-observed") |> File.read!() |> Jason.decode!()
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    temporary = Path.join(ctx.path, ".symphony-" <> row["io_invocation"])

    assert observed["replacement_inode"] != observed["inode"]
    assert File.stat!(temporary).inode == observed["replacement_inode"]
    assert File.stat!(temporary <> ".preserved").inode == observed["inode"]
    assert File.read!(temporary) == "unrelated replacement\n"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:error, :file_io_temporary_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert row["phase"] == "PREPARED"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert %{"success" => false} = call(Map.delete(cap, :file_io_transport), "repo_write", edit(digest("base\n")), identity("repo_write", "retry"))
  end

  for location <- ~w(journal cached) do
    @location location
    test "cleanup proof cannot be omitted from an actual #{@location} creator receipt", ctx do
      fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
      cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
      assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
      row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
      binding = Jason.decode!(row["io_binding_json"])

      if @location == "journal" do
        path = Path.join(binding["spool"], binding["invocation"] <> ".receipt")
        corrupted = path |> File.read!() |> Jason.decode!() |> Map.delete("cleanup")
        File.write!(path, Jason.encode!(corrupted))
        Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 1, io_receipt_json = NULL")
      else
        corrupted = row["io_receipt_json"] |> Jason.decode!() |> Map.delete("cleanup") |> Jason.encode!()
        Store.query!(ctx.store, "UPDATE worker_file_operations SET phase = 'PREPARED', io_pending = 0, io_receipt_json = ?", [corrupted])
      end

      assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      assert Store.one!(ctx.store, "SELECT phase FROM worker_file_operations")["phase"] == "PREPARED"
    end
  end

  test "a creator PID mismatch never authorizes cleanup or source retry", ctx do
    File.write!(Path.join(ctx.root, "creator-stop-mode"), "pid-mismatch")
    fixture = Path.expand("../support/file_io_creator_stop.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    assert %{"success" => false} = call(cap, "repo_write", edit(digest("base\n")))
    row = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    binding = Jason.decode!(row["io_binding_json"])
    refute File.exists?(Path.join(binding["spool"], binding["invocation"] <> ".receipt"))
    refute File.exists?(Path.join(binding["spool"], binding["invocation"] <> ".creator"))
    assert row["io_pending"] == 1
    assert row["io_receipt_json"] == nil
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:error, :file_worker_helper_exit_unproven} = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "an actually signaled source helper records its signal without inventing an exit code", ctx do
    fixture = Path.expand("../support/file_io_signaled_child.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = edit(digest("base\n"))
    assert %{"success" => false} = call(cap, "repo_write", args)
    operation = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    receipt = Jason.decode!(operation["io_receipt_json"])
    assert receipt["termination"] == %{"kind" => "signaled", "signal" => 9}
    assert receipt["exit_status"] == nil
    assert is_integer(receipt["pid"]) and receipt["pid"] > 0
    assert operation["phase"] == "ABORTED"
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
    assert decoded(call(cap, "repo_write", args))["error"] == ":file_worker_operation_aborted"
    normal = Map.delete(cap, :file_io_transport)
    assert %{"success" => true} = call(normal, "repo_write", args, identity("repo_write", "retry"))
  end

  test "a hard-killed controller VM recovers the completed mutation without repeating the mutation", ctx do
    cap = prepare(ctx)
    support = Path.expand("../support", __DIR__)
    elixir = System.find_executable("elixir")
    libraries = Path.expand("_build/test/lib")
    driver = Path.join(support, "file_io_controller.exs")
    transport = Path.join(support, "file_io_lost_reply.py")
    harness = Path.join(support, "file_io_vm_crash.py")

    try do
      {output, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", harness, elixir, libraries, driver, ctx.database, transport])
      observed = Jason.decode!(output)
      assert observed["observed_terminal_helper"] == true, observed["output"]
      assert observed["executing_vm_pid"] == observed["controller_pid"]
      assert observed["controller_returncode"] == -9
      reopened = start_supervised!({Store, database: ctx.database}, id: :recovered_vm)
      assert :ok = WorkerFileTools.reconcile(reopened, cap.key)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
      assert %{"success" => true} = call(%{cap | store: reopened}, "repo_write", edit(digest("base\n")))
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(reopened, "reservation")
    after
      File.write!(Path.join(ctx.root, "reply-release"), "release\n")
    end
  end

  test "a dead callback recovers the same completed edit from durable child exit evidence", ctx do
    fixture = Path.expand("../support/file_io_lost_reply.py", __DIR__)
    transport = %{path: fixture, sha256: digest(File.read!(fixture))}
    cap = prepare(ctx) |> Map.put(:file_io_transport, transport)
    args = edit(digest("base\n"))
    {:ok, owner} = Task.start(fn -> call(cap, "repo_write", args) end)
    marker = Path.join(ctx.root, "reply-withheld")

    try do
      assert wait_for_file(marker, System.monotonic_time(:millisecond) + 6_000)
      reference = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^reference, :process, ^owner, _}, 1_000
      reopened = start_supervised!({Store, database: ctx.database}, id: :recovered_callback)
      assert :ok = WorkerFileTools.reconcile(reopened, cap.key)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
      assert %{"success" => true} = call(%{cap | store: reopened}, "repo_write", args)
    after
      File.write!(Path.join(ctx.root, "reply-release"), "release\n")
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  test "a completed deletion survives callback loss and refuses a replacement during recovery", ctx do
    fixture = Path.expand("../support/file_io_lost_reply.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = %{"path" => "fixture.txt", "expected_sha256" => digest("base\n")}
    {:ok, owner} = Task.start(fn -> call(cap, "repo_delete", args) end)

    try do
      assert wait_for_file(Path.join(ctx.root, "reply-withheld"), System.monotonic_time(:millisecond) + 6_000)
      reference = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^reference, :process, ^owner, _}, 1_000
      reopened = start_supervised!({Store, database: ctx.database}, id: :recovered_deletion)
      path = Path.join(ctx.path, "fixture.txt")
      File.write!(path, "replacement\n")
      assert {:error, :file_worker_edit_reconciliation_required} = WorkerFileTools.reconcile(reopened, cap.key)
      assert File.read!(path) == "replacement\n"
      File.rm!(path)
      assert :ok = WorkerFileTools.reconcile(reopened, cap.key)
      assert %{"success" => true} = call(%{cap | store: reopened}, "repo_delete", args)
      assert decoded(call(%{cap | store: reopened}, "repo_list", %{"path" => "."}))["entries"] == []
    after
      File.write!(Path.join(ctx.root, "reply-release"), "release\n")
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  test "directory recovery requires the original tagged inode, not a replacement with copied metadata", ctx do
    fixture = Path.expand("../support/file_io_lost_reply.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = %{"path" => "new"}
    {:ok, owner} = Task.start(fn -> call(cap, "repo_mkdir", args) end)

    try do
      assert wait_for_file(Path.join(ctx.root, "reply-withheld"), System.monotonic_time(:millisecond) + 6_000)
      reference = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^reference, :process, ^owner, _}, 1_000
      reopened = start_supervised!({Store, database: ctx.database}, id: :recovered_directory)
      path = Path.join(ctx.path, "new")
      saved = Path.join(ctx.root, "saved-directory")
      File.rename!(path, saved)
      File.mkdir!(path)
      {nonce, 0} = System.cmd("/usr/bin/xattr", ["-p", "com.symphony.factory_creation", saved])
      {"", 0} = System.cmd("/usr/bin/xattr", ["-w", "com.symphony.factory_creation", String.trim(nonce), path])
      assert {:error, :file_worker_edit_reconciliation_required} = WorkerFileTools.reconcile(reopened, cap.key)
      assert %{"success" => false} = call(%{cap | store: reopened}, "repo_mkdir", args)
      File.rmdir!(path)
      File.rename!(saved, path)
      assert :ok = WorkerFileTools.reconcile(reopened, cap.key)
      assert %{"success" => true} = call(%{cap | store: reopened}, "repo_mkdir", args)
      assert decoded(call(%{cap | store: reopened}, "repo_list", args))["entries"] == []
      assert git(ctx.path, ["status", "--porcelain", "--untracked-files=all"]) == ""
    after
      File.write!(Path.join(ctx.root, "reply-release"), "release\n")
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  test "binary edits recover after callback death without replaying the source mutation", ctx do
    fixture = Path.expand("../support/file_io_lost_reply.py", __DIR__)
    cap = prepare(ctx) |> Map.put(:file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = %{"path" => "fixture.bin", "expected_sha256" => "ABSENT", "content_base64" => "AP8="}
    {:ok, owner} = Task.start(fn -> call(cap, "repo_write_binary", args) end)

    try do
      assert wait_for_file(Path.join(ctx.root, "reply-withheld"), System.monotonic_time(:millisecond) + 6_000)
      reference = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^reference, :process, ^owner, _}, 1_000
      reopened = start_supervised!({Store, database: ctx.database}, id: :recovered_binary)
      assert :ok = WorkerFileTools.reconcile(reopened, cap.key)
      assert %{"success" => true} = call(%{cap | store: reopened}, "repo_write_binary", args)
      assert File.read!(Path.join(ctx.path, "fixture.bin")) == <<0, 255>>
      assert decoded(call(%{cap | store: reopened}, "repo_read_binary", %{"path" => "fixture.bin", "offset" => 0}))["content_base64"] == "AP8="
    after
      File.write!(Path.join(ctx.root, "reply-release"), "release\n")
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  test "a delayed helper cannot apply a stale contract after its controller callback dies", ctx do
    cap = delayed_edit(ctx, fn _cap -> {:ok, _} = RunLedger.update(ctx.store, "run", %{spec_revision: 2}) end, {:error, :workspace_input_changed})
    assert {:error, :workspace_input_changed} = WorkerFileTools.reconcile(ctx.store, cap.key)
  end

  test "a delayed helper cannot inherit another worker owner's authority", ctx do
    delayed_edit(ctx, fn cap -> Store.query!(ctx.store, "UPDATE worker_evidence SET owner_id = 'different-owner' WHERE request_key = ?", [cap.key]) end)
  end

  for kind <- [:candidate, :task_input, :turn, :head] do
    test "a delayed helper rejects changed #{kind} before editing source", ctx do
      expected = if unquote(kind) == :task_input, do: {:error, :workspace_task_input_changed}, else: :ok
      delayed_edit(ctx, &late_drift(ctx, &1, unquote(kind)), expected)
    end
  end

  test "an initial writer uses its bootstrap SHA before a candidate is adopted", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  for state <- ["REVIEW_WRITING", "REPAIRING"] do
    test "a #{state} writer uses its existing candidate and guarded file transport", ctx do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{state: unquote(state)})
      cap = prepare(ctx)
      assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
    end
  end

  test "a completed worker cannot start a delayed source edit", ctx do
    delayed_edit(ctx, fn cap ->
      {:ok, _} = WorkerEvidence.record_result(ctx.store, cap.key, %{thread_id: "worker", turn_id: "turn", item_id: "final", output: %{}})
      {:ok, _} = WorkerEvidence.record_owner_stopped(ctx.store, cap.key, "owner", stop_receipt(ctx))
    end)
  end

  test "a proven busy refusal cancels the original attempt and permits a new logical edit", ctx do
    fixture = Path.expand("../support/file_io_db_busy.py", __DIR__)
    transport = %{path: fixture, sha256: digest(File.read!(fixture))}
    cap = prepare(ctx) |> Map.put(:file_io_transport, transport)
    args = edit(digest("base\n"))
    assert %{"success" => false} = call(cap, "repo_write", args)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => false} = call(cap, "repo_write", args)
    available = Map.delete(cap, :file_io_transport)
    assert %{"success" => true} = call(available, "repo_write", args, identity("repo_write", "retry"))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "edited\n"
  end

  test "upgrading the old phase constraint preserves evidence and permits proven cancellation", ctx do
    cap = prepare(ctx)
    assert %{"success" => true} = call(cap, "repo_write", edit(digest("base\n")))
    original = Store.one!(ctx.store, "SELECT * FROM worker_file_operations")
    schema = Store.one!(ctx.store, "SELECT sql FROM sqlite_master WHERE name = 'worker_file_operations'")["sql"]
    legacy = schema |> String.replace(", 'ABORTED'", "") |> String.replace("'PREPARED', 'APPLIED'", "'PREPARED','APPLIED'")

    Store.transaction!(ctx.store, fn tx ->
      Store.query!(tx, "ALTER TABLE worker_file_operations RENAME TO saved_operations")
      Store.query!(tx, legacy)
      Store.query!(tx, "INSERT INTO worker_file_operations SELECT * FROM saved_operations")
      Store.query!(tx, "DROP TABLE saved_operations")
    end)

    assert :ok = Store.initialize(ctx.store)
    assert Store.one!(ctx.store, "SELECT * FROM worker_file_operations") == original
    fixture = Path.expand("../support/file_io_db_busy.py", __DIR__)
    busy = Map.put(cap, :file_io_transport, %{path: fixture, sha256: digest(File.read!(fixture))})
    args = edit(digest("edited\n"), "next\n")
    assert %{"success" => false} = call(busy, "repo_write", args, identity("repo_write", "busy"))
    assert :ok = WorkerFileTools.reconcile(ctx.store, cap.key)
    assert %{"success" => true} = call(cap, "repo_write", args, identity("repo_write", "next"))
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "next\n"
  end

  defp late_drift(ctx, _cap, :candidate), do: RunLedger.update(ctx.store, "run", %{candidate_sha: String.duplicate("a", 40)})
  defp late_drift(ctx, _cap, :task_input), do: TaskLedger.update(ctx.store, "writer", %{prompt_sha256: String.duplicate("x", 64)})
  defp late_drift(ctx, cap, :turn), do: Store.query!(ctx.store, "UPDATE worker_evidence SET turn_id = 'different-turn' WHERE request_key = ?", [cap.key])
  defp late_drift(ctx, _cap, :head), do: git(ctx.path, ["commit", "--allow-empty", "--no-verify", "-m", "outside HEAD change"])

  defp delayed_edit(ctx, mutate, expected_reconciliation \\ :ok) do
    fixture = Path.expand("../support/file_io_late_start.py", __DIR__)
    transport = %{path: fixture, sha256: digest(File.read!(fixture))}
    cap = prepare(ctx) |> Map.put(:file_io_transport, transport)
    {:ok, owner} = Task.start(fn -> call(cap, "repo_write", edit(digest("base\n"))) end)
    marker = Path.join(ctx.root, "dispatch-withheld")

    try do
      assert wait_for_file(marker, System.monotonic_time(:millisecond) + 6_000)
      reference = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^reference, :process, ^owner, _}, 1_000
      mutate.(cap)
      File.write!(Path.join(ctx.root, "dispatch-release"), "release\n")
      completed = Path.join(ctx.root, "dispatch-finished")
      assert wait_for_file(completed, System.monotonic_time(:millisecond) + 8_000)
      assert File.read!(Path.join(ctx.path, "fixture.txt")) == "base\n"
      assert Jason.decode!(File.read!(completed))["exit_status"] == 0
      operation = Store.one!(ctx.store, "SELECT io_binding_json FROM worker_file_operations")
      binding = Jason.decode!(operation["io_binding_json"])
      assert {:error, {:file_io_not_started, "authorization_changed"}, %{"disposition" => "NO_SPAWN"}} = WorkerFileIO.recover_mutation(binding)
      assert WorkerFileTools.reconcile(ctx.store, cap.key) == expected_reconciliation
      assert {:ok, %{"released_at" => nil}} = WorkspaceAccess.get(ctx.store, "reservation")
      cap
    after
      File.write!(Path.join(ctx.root, "dispatch-release"), "release\n")
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end
  end

  defp wait_for_file(path, deadline) do
    cond do
      File.exists?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        wait_for_file(path, deadline)
    end
  end
end
