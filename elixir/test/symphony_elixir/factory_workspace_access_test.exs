defmodule SymphonyElixir.FactoryWorkspaceAccessTest do
  use ExUnit.Case, async: true
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{DesktopRequest, RunLedger, Store, TaskLedger, WorkspaceAccess}
  setup :setup_fixture

  test "late observation follows both checkout inspections and leaves the database responsive", ctx do
    caller = self()

    options =
      Keyword.put(opts(ctx), :after_acquisition_observation, fn ->
        send(caller, :checkout_observed)
        :ok
      end)

    proof = %{token: make_ref()}

    capture = fn ->
      assert_received :checkout_observed
      reader = Task.async(fn -> Store.one!(ctx.store, "SELECT 1 AS responsive") end)
      assert Task.await(reader, 1_000) == %{"responsive" => 1}
      send(caller, :captured)
      {:ok, proof}
    end

    assert {:ok, row} =
             WorkspaceAccess.acquire_with_observation(ctx.store, attrs(ctx), options, capture, fn tx, access, captured ->
               assert %DBConnection{} = tx
               assert captured == proof
               assert_received :captured
               refute_received :captured
               {:ok, access}
             end)

    assert {:ok, ^row} = WorkspaceAccess.get(ctx.store, row["reservation_key"])
  end

  test "late observation refusal cannot acquire or call the SQL commit", ctx do
    assert {:error, :source_not_quiet} =
             WorkspaceAccess.acquire_with_observation(ctx.store, attrs(ctx), opts(ctx), fn -> {:error, :source_not_quiet} end, fn _, _, _ -> flunk("observer refusal committed") end)

    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "late observation is not called for dirty checkout or outer transactions", ctx do
    capture = fn -> flunk("invalid physical admission observed native state") end
    commit = fn _, _, _ -> flunk("invalid admission committed") end

    assert {:error, :workspace_observation_inside_transaction} =
             Store.transaction!(ctx.store, fn tx -> WorkspaceAccess.acquire_with_observation(tx, attrs(ctx), opts(ctx), capture, commit) end)

    File.write!(Path.join(ctx.path, "fixture.txt"), "changed\n")
    assert {:error, :worktree_dirty} = WorkspaceAccess.acquire_with_observation(ctx.store, attrs(ctx), opts(ctx), capture, commit)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "late observation cannot hide task changes", ctx do
    capture = fn ->
      {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: String.duplicate("q", 64)})
      {:ok, :observed}
    end

    assert {:error, :workspace_acquisition_task_changed} =
             WorkspaceAccess.acquire_with_observation(ctx.store, attrs(ctx), opts(ctx), capture, fn _, _, _ -> flunk("changed task committed") end)

    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "late observation cannot hide physical root replacement", ctx do
    capture = fn ->
      File.rename!(ctx.path, ctx.path <> "-original")
      File.mkdir!(ctx.path)
      {:ok, :observed}
    end

    assert {:error, :workspace_root_identity_changed} =
             WorkspaceAccess.acquire_with_observation(ctx.store, attrs(ctx), opts(ctx), capture, fn _, _, _ -> flunk("replaced root committed") end)

    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "malformed late observation cannot acquire or commit", ctx do
    assert {:error, :workspace_observation_invalid} =
             WorkspaceAccess.acquire_with_observation(ctx.store, attrs(ctx), opts(ctx), fn -> :ok end, fn _, _, _ -> flunk("malformed proof committed") end)

    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "slow real checkout admission does not retain SQLite checkout and rolls back caller failure", ctx do
    parent = self()

    observer = fn ->
      send(parent, {:observing, self()})
      receive do: (:continue -> :ok)
    end

    claim =
      Task.async(fn ->
        WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), Keyword.put(opts(ctx), :before_acquisition_observation, observer), fn _tx, _access ->
          {:error, :caller_rejected}
        end)
      end)

    assert_receive {:observing, observer_pid}, 1_000
    reader = Task.async(fn -> Store.one!(ctx.store, "SELECT 1 AS responsive") end)
    responsive = Task.yield(reader, 1_000)
    send(observer_pid, :continue)
    assert Task.await(claim, 15_000) == {:error, :caller_rejected}
    assert responsive == {:ok, %{"responsive" => 1}}
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "observed acquisition denies changed input and task preimages", ctx do
    for {change, reason} <- [
          {fn -> RunLedger.update(ctx.store, "run", %{spec_revision: 2}) end, :workspace_acquisition_input_changed},
          {fn -> TaskLedger.update(ctx.store, "writer", %{prompt_sha256: String.duplicate("q", 64)}) end, :workspace_acquisition_task_changed}
        ] do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{spec_revision: 1})
      {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: String.duplicate("p", 64)})

      options =
        Keyword.put(opts(ctx), :after_acquisition_observation, fn ->
          change.()
          :ok
        end)

      assert {:error, ^reason} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), options, fn _, _ -> flunk("stale claim committed") end)
      assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
    end
  end

  test "observed acquisition rejects outer transactions and preserves exclusive generation", ctx do
    assert {:error, :workspace_observation_inside_transaction} =
             Store.transaction!(ctx.store, fn tx -> WorkspaceAccess.acquire_with(tx, attrs(ctx), opts(ctx), fn _, row -> {:ok, row} end) end)

    claims =
      for n <- 1..2 do
        Task.async(fn -> WorkspaceAccess.acquire_with(ctx.store, attrs(ctx, "SOURCE", "observed-#{n}"), opts(ctx), fn _, row -> {:ok, row} end) end)
      end

    results = Enum.map(claims, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :workspace_busy})) == 1
  end

  test "observed acquisition replay rejects changed acquired immutable inputs", ctx do
    commit = fn _, row -> {:ok, row} end
    assert {:ok, original} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), opts(ctx), commit)
    assert {:ok, ^original} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), opts(ctx), commit)
    {:ok, run} = RunLedger.get(ctx.store, "run")

    for {field, changed, reason} <- [
          {:spec_revision, 2, :workspace_input_changed},
          {:contract_sha256, String.duplicate("f", 64), :workspace_input_changed},
          {:candidate_sha, String.duplicate("f", 40), :workspace_candidate_binding_mismatch}
        ] do
      {:ok, _} = RunLedger.update(ctx.store, "run", %{field => changed})
      assert {:error, ^reason} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), opts(ctx), commit)
      {:ok, _} = RunLedger.update(ctx.store, "run", %{field => run[Atom.to_string(field)]})
    end

    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: String.duplicate("q", 64)})
    assert {:error, :workspace_task_input_changed} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), opts(ctx), commit)
    assert {:ok, ^original} = WorkspaceAccess.get(ctx.store, original["reservation_key"])
  end

  test "observed acquisition retains real clean HEAD checks", ctx do
    options =
      Keyword.put(opts(ctx), :before_acquisition_observation, fn ->
        File.write!(Path.join(ctx.path, "fixture.txt"), "changed\n")
        :ok
      end)

    assert {:error, :worktree_dirty} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), options, fn _, _ -> flunk("dirty claim committed") end)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "observed acquisition rejects HEAD changes after its first actual observation", ctx do
    options =
      Keyword.put(opts(ctx), :after_acquisition_observation, fn ->
        File.write!(Path.join(ctx.path, "fixture.txt"), "new head\n")
        git(ctx.path, ["add", "fixture.txt"])
        git(ctx.path, ["commit", "--no-verify", "-m", "changed head"])
        :ok
      end)

    assert {:error, _} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), options, fn _, _ -> flunk("changed HEAD committed") end)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "observed acquisition denies physical root replacement after actual Git proof", ctx do
    options =
      Keyword.put(opts(ctx), :after_acquisition_observation, fn ->
        File.rename!(ctx.path, ctx.path <> "-original")
        File.mkdir!(ctx.path)
        :ok
      end)

    assert {:error, :workspace_root_identity_changed} = WorkspaceAccess.acquire_with(ctx.store, attrs(ctx), options, fn _, _ -> flunk("replaced root committed") end)
    assert Store.one!(ctx.store, "SELECT * FROM workspace_access") == nil
  end

  test "review admission does not execute repository filesystem-monitor programs", ctx do
    marker = Path.join(ctx.root, "fsmonitor-executed")
    monitor = Path.join(ctx.root, "monitor")
    File.write!(monitor, "#!/bin/sh\nprintf ran >> '#{marker}'\nprintf 'fixture\\0'\n")
    File.chmod!(monitor, 0o700)
    git(ctx.repo, ["config", "core.fsmonitor", monitor])

    result = isolated_review(ctx, [])

    assert result["acquired"]["canonical_path"] == ctx.path
    assert result["validated"] == result["acquired"]
    refute File.exists?(marker)
  end

  test "review ignores inherited Git repository selectors and executable search paths", ctx do
    marker = Path.join(ctx.root, "ambient-git-executed")
    programs = Path.join(ctx.root, "programs")
    File.mkdir!(programs)
    wrapper = Path.join(programs, "git")
    File.write!(wrapper, "#!/bin/sh\nprintf ran >> '#{marker}'\nexec /Library/Developer/CommandLineTools/usr/bin/git \"$@\"\n")
    File.chmod!(wrapper, 0o700)

    environment = [
      {"PATH", programs <> ":" <> System.get_env("PATH")},
      {"GIT_DIR", Path.join(ctx.root, "not-a-repository")},
      {"GIT_WORK_TREE", ctx.repo},
      {"GIT_COMMON_DIR", Path.join(ctx.root, "wrong-common")},
      {"GIT_INDEX_FILE", Path.join(ctx.root, "wrong-index")},
      {"GIT_OBJECT_DIRECTORY", Path.join(ctx.root, "wrong-objects")},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "core.worktree"},
      {"GIT_CONFIG_VALUE_0", ctx.repo}
    ]

    result = isolated_review(ctx, environment)

    assert result["acquired"]["canonical_path"] == ctx.path
    assert result["validated"] == result["acquired"]
    refute File.exists?(marker)
    refute File.exists?(Path.join(ctx.root, "wrong-index"))
  end

  test "review identity cannot run a configured clean filter to modify files", ctx do
    marker = Path.join(ctx.root, "filter-executed")
    filter = Path.join(ctx.root, "filter")
    File.write!(filter, "#!/bin/sh\nprintf ran >> '#{marker}'\n/bin/cat\n")
    File.chmod!(filter, 0o700)
    File.write!(Path.join(ctx.path, ".gitattributes"), "fixture.txt filter=fixture\n")
    git(ctx.path, ["add", ".gitattributes"])
    git(ctx.path, ["commit", "--no-verify", "-m", "filter fixture"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: sha})
    git(ctx.repo, ["config", "filter.fixture.clean", filter])
    File.write!(Path.join(ctx.path, "fixture.txt"), "diff\n")
    File.touch!(Path.join(ctx.path, "fixture.txt"), System.os_time(:second) + 2)
    fixture = %{ctx | sha: sha}

    assert %{"error" => _reason} = isolated_review(fixture, [])
    refute File.exists?(marker)
    assert File.read!(Path.join(ctx.path, "fixture.txt")) == "diff\n"
  end

  test "future workspaces cannot overlap the controller's private file receipt authority", ctx do
    nested = Path.join(ctx.root, ".factory-file-io/source")
    git(ctx.repo, ["worktree", "add", "-b", "cgable/spool", nested, "HEAD"])
    register(ctx, "spool-run", "PPL-124", "spool-writer", nested, "cgable/spool")
    candidate = attrs(ctx) |> Map.merge(%{"run_id" => "spool-run", "task_key" => "spool-writer", "allowed_root" => ctx.root})
    assert {:error, :workspace_overlaps_controller_spool} = WorkspaceAccess.acquire(ctx.store, candidate, opts(ctx))
  end

  test "case aliases cannot hide a controller spool inside the source checkout", ctx do
    alias_path = Path.join(ctx.root, "workspaces/SOURCE")
    assert File.stat!(alias_path).inode == File.stat!(ctx.path).inode
    File.write!(Path.join(ctx.repo, ".git/info/exclude"), "factory.sqlite*\n")
    database = Path.join(alias_path, "factory.sqlite")
    store = start_supervised!({Store, database: database}, id: :case_alias_store)
    fixture = %{ctx | store: store, database: database}
    register(fixture, "run", "PPL-123", "writer")
    candidate = attrs(fixture)
    assert {:error, :workspace_overlaps_controller_spool} = WorkspaceAccess.acquire(store, candidate, opts(fixture))
    refute File.exists?(Path.join(alias_path, ".factory-file-io"))
  end

  test "aliases and other task/run keys cannot acquire a held checkout", ctx do
    assert {:ok, row} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    assert {:ok, ^row} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    assert {:error, :workspace_reservation_conflict} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx), "mode", "REVIEW"), opts(ctx))
    assert {:error, :workspace_busy} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "REVIEW", "review"), opts(ctx))
    alias_path = Path.join(ctx.root, "alias")
    File.ln_s!(ctx.path, alias_path)
    register(ctx, "other", "PPL-124", "other-writer", alias_path)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "COMPLETE"})
    other = attrs(ctx, "SOURCE", "other") |> Map.merge(%{"run_id" => "other", "task_key" => "other-writer"})
    assert {:error, :workspace_busy} = WorkspaceAccess.acquire(ctx.store, other, opts(ctx))
    assert {:ok, ^row} = WorkspaceAccess.get(ctx.store, "reservation")
  end

  test "dirty and wrong-SHA review, primary checkout, low capacity and invalid bindings reject", ctx do
    assert {:error, :insufficient_writer_capacity} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx, 19_999_999_999))
    assert {:error, :workspace_capacity_policy_missing} = WorkspaceAccess.acquire(ctx.store, attrs(ctx))
    assert {:error, :invalid_workspace_reservation} = WorkspaceAccess.acquire(ctx.store, %{})
    assert {:error, :invalid_workspace_reservation} = WorkspaceAccess.acquire(ctx.store, "bad")
    assert {:error, :workspace_outside_allowed_root} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx), "allowed_root", ctx.repo), opts(ctx))
    assert {:error, :unknown_task} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx), "task_key", "missing"), opts(ctx))
    assert {:error, :unknown_run} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx), "run_id", "missing"), opts(ctx))
    assert {:error, _} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx, "REVIEW"), "expected_sha", String.duplicate("a", 40)))
    File.write!(Path.join(ctx.path, "untracked"), "keep")
    assert {:error, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "REVIEW"))
    File.rm!(Path.join(ctx.path, "untracked"))
    {:ok, _} = RunLedger.update(ctx.store, "run", %{worktree: ctx.repo})
    assert {:error, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
  end

  test "model completion and elapsed time never release SOURCE; commit crash preserves ownership", ctx do
    {:ok, row} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    File.write!(Path.join(ctx.path, "fixture.txt"), "changed\n")
    assert {:ok, ^row} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "controller slice"])
    assert {:ok, ^row} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    assert {:error, :workspace_completion_not_proven} = WorkspaceAccess.release(ctx.store, "reservation", 1, "reservation:request")
    assert {:error, :stale_workspace_reservation} = WorkspaceAccess.validate(ctx.store, "reservation", 2)
    assert {:error, :stale_workspace_reservation} = WorkspaceAccess.release(ctx.store, "reservation", 2, "reservation:request")
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})
    assert {:ok, ^row} = WorkspaceAccess.get(reopened, "reservation")
    assert {:error, :workspace_completion_not_proven} = WorkspaceAccess.release(reopened, "reservation", 1, "reservation:request")
    {:ok, _} = RunLedger.update(reopened, "run", %{spec_revision: 2})
    assert {:error, :workspace_input_changed} = WorkspaceAccess.validate(reopened, "reservation", 1)
  end

  test "review pins clean SHA and excludes maintenance and source, regardless of persistent chat", ctx do
    {:ok, row} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "REVIEW"))
    assert {:ok, ^row} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    assert {:error, :workspace_busy} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "source"), opts(ctx))
    maintenance = attrs(ctx, "MAINTENANCE", "maintenance") |> Map.put("task_key", nil)
    assert {:error, :workspace_activity_unresolved} = WorkspaceAccess.acquire(ctx.store, maintenance)
    File.write!(Path.join(ctx.path, "fixture.txt"), "external edit")
    assert {:error, _} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    assert {:error, :unknown_workspace_reservation} = WorkspaceAccess.get(ctx.store, "missing")
  end

  test "another active task or uncertain broker attempt prevents first admission", ctx do
    register(ctx, "other", "PPL-124", "other", ctx.path)
    assert {:error, :workspace_activity_unresolved} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    {:ok, _} = TaskLedger.update(ctx.store, "other", %{status: "COMPLETE"})
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
  end

  test "parallel admissions serialize, and different worktrees share only the repository", ctx do
    results = Enum.map(1..2, fn n -> Task.async(fn -> WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "claim-#{n}"), opts(ctx)) end) end) |> Enum.map(&Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :workspace_busy})) == 1
    second = Path.join(ctx.root, "workspaces/second")
    git(ctx.repo, ["worktree", "add", "-b", "cgable/second", second, "HEAD"])
    register(ctx, "other", "PPL-124", "other", second, "cgable/second")
    other = attrs(ctx, "SOURCE", "second") |> Map.merge(%{"run_id" => "other", "task_key" => "other"})
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, other, opts(ctx))
  end

  test "initial source can bind bootstrap SHA, but a review cannot bless an unadopted commit", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: nil})
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    File.write!(Path.join(ctx.path, "fixture.txt"), "new\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "unadopted"])
    sha = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: ctx.sha})
    assert {:error, :workspace_candidate_binding_mismatch} = WorkspaceAccess.acquire(ctx.store, Map.put(attrs(ctx, "REVIEW", "review"), "expected_sha", sha))
  end

  test "changing task input invalidates the reservation before an attempt can reserve it", ctx do
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: "new-prompt"})
    assert {:error, :workspace_task_input_changed} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    assert {:error, :workspace_task_input_changed} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
  end

  test "the same persistent task's old uncertain Desktop request is not exempted", ctx do
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{codex_project_id: "project"})

    {:ok, request} =
      DesktopRequest.enqueue(ctx.store, %{
        request_key: "old",
        target_kind: "TASK",
        target_key: "writer",
        action: "CREATE",
        codex_project_id: "project",
        model: "gpt-6-luna",
        reasoning_effort: "medium",
        title: "Old writer",
        prompt: "Old",
        schema: %{},
        cwd: ctx.path,
        metadata: %{}
      })

    Store.query!(ctx.store, "UPDATE desktop_requests SET status = 'CREATE_UNCERTAIN' WHERE request_key = ?", [request["request_key"]])
    assert {:error, :workspace_activity_unresolved} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))
  end

  test "reservations participate in transactional capacity before run state reports writing", ctx do
    {:ok, _} = RunLedger.update(ctx.store, "run", %{state: "QUEUED"})
    limited = opts(ctx) |> Keyword.update!(:capacity_policy, &put_in(&1, ["capacity", "maximum_writers"], 1))
    {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), limited)
    path = Path.join(ctx.root, "workspaces/second")
    git(ctx.repo, ["worktree", "add", "-b", "cgable/second", path, "HEAD"])
    register(ctx, "other", "PPL-124", "other", path, "cgable/second")
    {:ok, _} = RunLedger.update(ctx.store, "other", %{state: "QUEUED"})
    other = attrs(ctx, "SOURCE", "other") |> Map.merge(%{"run_id" => "other", "task_key" => "other"})
    assert {:error, :insufficient_writer_capacity} = WorkspaceAccess.acquire(ctx.store, other, limited)
  end

  test "maintenance owns the same mutex and a missing source is not silently released", ctx do
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "COMPLETE"})
    maintenance = attrs(ctx, "MAINTENANCE") |> Map.put("task_key", nil)
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, maintenance)
    assert {:ok, _} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    assert {:error, :workspace_busy} = WorkspaceAccess.acquire(ctx.store, attrs(ctx, "SOURCE", "source"), opts(ctx))
    git(ctx.repo, ["worktree", "move", ctx.path, Path.join(ctx.root, "workspaces/moved")])
    assert {:error, _} = WorkspaceAccess.validate(ctx.store, "reservation", 1)
    assert {:error, :workspace_completion_not_proven} = WorkspaceAccess.release(ctx.store, "reservation", 1, "reservation:request")
  end

  defp isolated_review(ctx, environment) do
    libraries = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])
    driver = Path.expand("test/support/workspace_identity_controller.exs")
    payload = attrs(ctx, "REVIEW") |> Jason.encode!() |> Base.encode64()
    arguments = ["--erl", "+S 2"] ++ libraries ++ [driver, ctx.database, payload]
    {output, status} = System.cmd(System.find_executable("elixir"), arguments, env: environment, stderr_to_stdout: true)
    assert status == 0, output
    Jason.decode!(String.trim(output))
  end
end
