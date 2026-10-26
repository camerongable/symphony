defmodule SymphonyElixir.FactoryWorkerInstructionsTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketWorkerFixture
  alias SymphonyElixir.Factory.{Prompt, RunLedger, Store, TaskLedger, TicketWorkerRunner}
  alias SymphonyElixir.Factory.{WorkerEvidence, WorkerInstructions, WorkspaceAccess}

  setup :setup_fixture

  test "required skills and every shared rule are read completely in stable order", ctx do
    root = fixture_instructions(ctx)
    File.rm!(Path.join(root, "rules/additional.md"))
    File.write!(Path.join(root, "rules/new-rule.mdc"), "An additional shared rule\n")
    File.write!(Path.join(root, "rules/not-an-instruction.txt"), "Do not include me")
    assert {:ok, instructions} = WorkerInstructions.load(root)
    assert Enum.map(instructions, & &1["path"]) == Enum.sort(Enum.map(instructions, & &1["path"]))
    assert length(instructions) == 8
    for instruction <- instructions, do: assert(instruction["content"] == File.read!(instruction["path"]))
    refute Enum.any?(instructions, &String.ends_with?(&1["path"], ".txt"))
  end

  test "missing malformed and oversized required instructions fail before worker launch", ctx do
    root = fixture_instructions(ctx)
    path = Path.join(root, "skills/draft-feature-cycle/SKILL.md")

    for content <- [<<255>>, "", String.duplicate("x", 65_537)] do
      File.write!(path, content)
      assert {:error, _} = WorkerInstructions.load(root)
    end

    File.rm!(path)
    assert {:error, {:worker_instruction_unavailable, "skills/draft-feature-cycle/SKILL.md"}} = WorkerInstructions.load(root)
    assert {:error, :worker_instruction_rules_unavailable} = WorkerInstructions.load(Path.join(root, "absent"))
  end

  @bundles %{
    "feature-planner" => ~w(skills/plan-feature/SKILL.md skills/onboard-service/SKILL.md),
    "feature-writer" => ~w(skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md),
    "ci-repair-writer" => ~w(skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md skills/fix-mr-pipeline/SKILL.md),
    "change-verifier" => ~w(skills/verify-feature-delivery/SKILL.md skills/verify-feature-delivery/references/verdict-contract.md skills/review-code/references/review-criteria.md),
    "manual-validator" => ~w(skills/review-code/references/review-criteria.md)
  }

  test "new CI instruction bundles explain genuine generated-only completion without granting writer authority", ctx do
    root = fixture_instructions(ctx)
    binding = %{"run_id" => "run", "role" => "feature-writer", "generated_only_guidance_test" => true}
    assert {:ok, bundle} = WorkerInstructions.admit(ctx.store, binding, "ci-repair-writer", root)
    assert bundle["instruction_delivery"] =~ "genuine no-edit COMPLETE"
    assert bundle["instruction_delivery"] =~ "Never edit BUILD, request shell privileges, or claim generated outputs yourself"
    assert {:ok, ^bundle} = WorkerInstructions.read(ctx.store, binding, "ci-repair-writer")
  end

  test "serialized role packets contain full current skills and required references with restricted adapters", ctx do
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)

    for role <- ~w(feature-planner feature-writer change-verifier) do
      assert {:ok, packet} = TicketWorkerRunner.packet(ctx.store, "run", role, ctx.sha)
      decoded = Jason.decode!(packet)

      for relative <- @bundles[role] do
        instruction = Enum.find(decoded["shared_instructions"], &(&1["relative_path"] == relative))
        assert instruction["content"] == File.read!(Path.join(System.user_home!(), ".agents/" <> relative))
        assert instruction["sha256"] == sha(instruction["content"])
      end

      assert decoded["instruction_delivery"] =~ "No connectors, delegation"
      assert decoded["instruction_snapshot_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, ^packet} = TicketWorkerRunner.read_packet(ctx.store, "run", role, ctx.sha)
    end

    {:ok, verifier} = TicketWorkerRunner.read_packet(ctx.store, "run", "change-verifier", ctx.sha)
    assert Jason.decode!(verifier)["instruction_delivery"] =~ "mode: reviewer"
    assert Jason.decode!(verifier)["instruction_delivery"] =~ "transport adapter"
  end

  test "each required file fails closed while new markdown rules and CI without either autopilot are supported", ctx do
    root = fixture_instructions(ctx)

    for {role, relatives} <- @bundles do
      assert {:ok, instructions} = WorkerInstructions.load(root, role)
      assert Enum.any?(instructions, &(&1["relative_path"] == "rules/additional.md"))
      refute Enum.any?(instructions, &String.contains?(&1["path"], "autopilot"))

      for relative <- relatives ++ ["AGENTS.md", "rules/comment-discipline.mdc"] do
        path = Path.join(root, relative)
        content = File.read!(path)
        File.rm!(path)
        assert {:error, {:worker_instruction_unavailable, ^relative}} = WorkerInstructions.load(root, role)
        File.write!(path, content)
      end
    end
  end

  test "snapshot survives skill edits deletion and database reopen and read never admits missing material", ctx do
    root = fixture_instructions(ctx)
    binding = %{"run_id" => "run", "role" => "feature-writer", "candidate_sha" => ctx.sha}
    assert {:error, :worker_instruction_snapshot_missing} = WorkerInstructions.read(ctx.store, binding, "feature-writer")
    assert {:ok, bundle} = WorkerInstructions.admit(ctx.store, binding, "feature-writer", root)
    File.write!(Path.join(root, "skills/draft-feature-cycle/SKILL.md"), "changed instructions")
    assert {:ok, ^bundle} = WorkerInstructions.admit(ctx.store, binding, "feature-writer", root)
    File.rm_rf!(root)
    assert {:ok, ^bundle} = WorkerInstructions.read(ctx.store, binding, "feature-writer")
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})
    assert {:ok, ^bundle} = WorkerInstructions.read(reopened, binding, "feature-writer")
    {:ok, reader} = Store.start_read_only(database: ctx.database)
    assert {:ok, ^bundle} = WorkerInstructions.read(reader, binding, "feature-writer")
    GenServer.stop(reader)
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_instruction_snapshots")["count"] == 1
    assert {:error, :worker_instruction_snapshot_missing} = WorkerInstructions.read(reopened, Map.put(binding, "candidate_sha", String.duplicate("b", 40)), "feature-writer")
    assert Store.one!(reopened, "SELECT COUNT(*) AS count FROM worker_instruction_snapshots")["count"] == 1
  end

  test "admission uses first committed bytes when callers have different files", ctx do
    root = fixture_instructions(ctx)
    other = Path.join(ctx.root, "other-instructions")
    File.cp_r!(root, other)
    File.write!(Path.join(other, "skills/plan-feature/SKILL.md"), "different contender")
    binding = %{"run_id" => "run", "role" => "feature-planner"}
    contender = start_supervised!({Store, database: ctx.database}, id: :contender)
    callers = for {store, path} <- [{ctx.store, root}, {contender, other}], do: Task.async(fn -> WorkerInstructions.admit(store, binding, "feature-planner", path) end)
    assert [{:ok, first}, {:ok, second}] = Enum.map(callers, &Task.await(&1, 5_000))
    assert first == second
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_instruction_snapshots")["count"] == 1
  end

  test "native packet readback uses admitted bytes after instruction root deletion and writer restart", ctx do
    root = fixture_instructions(ctx)
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:ok, original} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    binding = original |> Jason.decode!() |> Map.drop(~w(shared_instructions instruction_delivery instruction_snapshot_sha256 instruction_binding_sha256)) |> Map.put("implementation_iteration", 7)
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{implementation_iteration: 7})
    assert {:ok, bundle} = WorkerInstructions.admit(ctx.store, binding, "feature-writer", root)
    expected = Jason.encode!(Map.merge(binding, bundle))
    File.rm_rf!(root)
    stop_supervised!(Store)
    reopened = start_supervised!({Store, database: ctx.database})
    assert {:ok, ^expected} = TicketWorkerRunner.read_packet(reopened, "run", "feature-writer", ctx.sha)
    assert {:ok, ^expected} = TicketWorkerRunner.packet(reopened, "run", "feature-writer", ctx.sha)
  end

  test "append-only storage and integrity validation reject snapshot tampering", ctx do
    root = fixture_instructions(ctx)
    binding = %{"run_id" => "run", "role" => "feature-planner"}
    assert {:ok, _} = WorkerInstructions.admit(ctx.store, binding, "feature-planner", root)

    for sql <- ["UPDATE worker_instruction_snapshots SET bundle_json = '{}'", "DELETE FROM worker_instruction_snapshots", "DELETE FROM factory_schema_migrations WHERE version = 43"] do
      assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql) end
    end

    Store.query!(ctx.store, "DROP TRIGGER worker_instruction_snapshot_update")
    Store.query!(ctx.store, "UPDATE worker_instruction_snapshots SET bundle_json = '{}' ")
    assert {:error, :worker_instruction_snapshot_invalid} = WorkerInstructions.read(ctx.store, binding, "feature-planner")
    assert {:error, :worker_instruction_snapshot_invalid} = WorkerInstructions.admit(ctx.store, binding, "feature-planner", root)
  end

  test "old issued task cannot be retrofitted by admission or readback", ctx do
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    Store.query!(ctx.store, "UPDATE factory_tasks SET prompt_sha256 = ?, thread_id = 'old-worker', status = 'RUNNING' WHERE task_key = 'writer'", [String.duplicate("a", 64)])
    assert {:error, :worker_instruction_snapshot_not_admitted} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert {:error, :worker_instruction_snapshot_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS count FROM worker_instruction_snapshots")["count"] == 0
  end

  for instruction_role <- ~w(feature-writer ci-repair-writer) do
    test "retained #{instruction_role} packets preserve guidance through prepared prompt replacement without new admission", ctx do
      root = fixture_instructions(ctx)
      if unquote(instruction_role) == "ci-repair-writer", do: prepare_ci_repair(ctx)
      assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
      assert {:ok, current} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)

      binding =
        current
        |> Jason.decode!()
        |> Map.drop(~w(shared_instructions instruction_delivery instruction_snapshot_sha256 instruction_binding_sha256))
        |> Map.put("tools", "Previously admitted seven-tool guidance")

      assert {:ok, bundle} = WorkerInstructions.admit(ctx.store, binding, unquote(instruction_role), root)
      expected = Jason.encode!(Map.merge(binding, bundle))
      previous_prompt = sha(Jason.encode!(%{"base_packet" => Jason.decode!(expected), "recovery" => "previous authorized wrapper"}))
      {:ok, predecessor} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: previous_prompt})
      assert :ok = WorkerInstructions.bind_task(ctx.store, "writer", previous_prompt, bundle["instruction_binding_sha256"])
      snapshots = Store.query!(ctx.store, "SELECT * FROM worker_instruction_snapshots").rows
      File.rm_rf!(root)
      {:ok, reader} = Store.start_read_only(database: ctx.database)

      assert {:ok, ^expected} = TicketWorkerRunner.retained_packet(reader, "run", "feature-writer", ctx.sha, predecessor)
      {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: sha("prepared replacement")})
      assert {:ok, ^expected} = TicketWorkerRunner.retained_packet(reader, "run", "feature-writer", ctx.sha, predecessor)
      assert Store.query!(ctx.store, "SELECT * FROM worker_instruction_snapshots").rows == snapshots

      for changed <- [Map.put(predecessor, "run_id", "foreign"), Map.put(predecessor, "role", "feature-planner"), Map.put(predecessor, "prompt_sha256", sha("missing"))] do
        assert {:error, _} = TicketWorkerRunner.retained_packet(reader, "run", "feature-writer", ctx.sha, changed)
      end

      {:ok, run} = RunLedger.get(ctx.store, "run")
      {:ok, _} = RunLedger.update(ctx.store, "run", %{implementation_iteration: run["implementation_iteration"] + 1})
      assert {:error, _} = TicketWorkerRunner.retained_packet(reader, "run", "feature-writer", ctx.sha, predecessor)
      {:ok, _} = RunLedger.update(ctx.store, "run", %{implementation_iteration: run["implementation_iteration"]})
      assert {:ok, ^expected} = TicketWorkerRunner.retained_packet(reader, "run", "feature-writer", ctx.sha, predecessor)
      GenServer.stop(reader)
    end
  end

  test "current failed reserved admission stays blocked while noncurrent historical evidence remains untouched", ctx do
    root = fixture_instructions(ctx)
    bind_parent(ctx)
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:ok, prompt} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: sha(prompt)})
    assert {:ok, _} = WorkspaceAccess.acquire(ctx.store, attrs(ctx), opts(ctx))

    assert {:ok, _} =
             WorkerEvidence.reserve(ctx.store, %{
               "request_key" => "reservation:request",
               "task_key" => "writer",
               "reservation_key" => "reservation",
               "input_sha256" => sha(prompt),
               "owner_id" => "fixture-owner",
               "schema" => %{},
               "policy" => %{}
             })

    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "FAILED"})
    binding = %{"run_id" => "run", "role" => "feature-writer", "implementation_iteration" => 2}
    before = Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows
    assert {:error, :worker_instruction_snapshot_not_admitted} = WorkerInstructions.admit(ctx.store, binding, "feature-writer", root)
    {:ok, _} = TaskLedger.update(ctx.store, "writer", %{status: "CONSUMED", prompt_sha256: String.duplicate("b", 64)})
    assert {:ok, _} = WorkerInstructions.admit(ctx.store, binding, "feature-writer", root)
    assert Store.query!(ctx.store, "SELECT * FROM worker_evidence").rows == before
  end

  test "task mappings pin wrappers atomically and inheritance rejects missing changed or wrong bindings", ctx do
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:ok, packet} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    decoded = Jason.decode!(packet)
    binding = Map.drop(decoded, ~w(shared_instructions instruction_delivery instruction_snapshot_sha256 instruction_binding_sha256))
    wrapper_sha = sha(Jason.encode!(%{"base_packet" => decoded, "explicit_rework" => "authorized data"}))
    {:ok, task} = TaskLedger.update(ctx.store, "writer", %{prompt_sha256: wrapper_sha})
    key = decoded["instruction_binding_sha256"]
    expected = Map.take(binding, ~w(run_id role base_sha candidate_sha spec_revision contract_sha256))
    changed = Map.merge(binding, %{"spec_revision" => 2, "contract_sha256" => String.duplicate("b", 64)})

    assert {:error, :worker_instruction_inheritance_unproven} = WorkerInstructions.inherit(ctx.store, changed, "feature-writer", task, expected)
    assert :ok = Store.transaction!(ctx.store, &WorkerInstructions.bind_task(&1, "writer", wrapper_sha, key))
    mappings = Store.query!(ctx.store, "SELECT * FROM worker_instruction_task_bindings").rows
    assert :ok = WorkerInstructions.bind_task(ctx.store, "writer", wrapper_sha, key)
    assert Store.query!(ctx.store, "SELECT * FROM worker_instruction_task_bindings").rows == mappings

    for invalid <- [Map.put(task, "run_id", "another-run"), Map.put(task, "role", "feature-planner"), Map.put(task, "prompt_sha256", nil), Map.put(task, "prompt_sha256", String.duplicate("c", 64))] do
      assert {:error, :worker_instruction_inheritance_unproven} = WorkerInstructions.inherit(ctx.store, changed, "feature-writer", invalid, expected)
    end

    assert {:error, :worker_instruction_inheritance_unproven} = WorkerInstructions.inherit(ctx.store, changed, "feature-writer", task, Map.put(expected, "contract_sha256", String.duplicate("c", 64)))
    assert {:error, :worker_instruction_inheritance_unproven} = WorkerInstructions.inherit(ctx.store, changed, "change-verifier", task, expected)
    assert {:ok, inherited} = WorkerInstructions.inherit(ctx.store, changed, "feature-writer", task, expected)
    assert inherited["shared_instructions"] == decoded["shared_instructions"]
    assert inherited["instruction_snapshot_sha256"] == decoded["instruction_snapshot_sha256"]
    refute inherited["instruction_binding_sha256"] == key

    for sql <- ["UPDATE worker_instruction_task_bindings SET role = 'feature-planner'", "DELETE FROM worker_instruction_task_bindings"] do
      assert_raise Exqlite.Error, fn -> Store.query!(ctx.store, sql) end
    end

    Store.query!(ctx.store, "DROP TRIGGER worker_instruction_snapshot_update")
    Store.query!(ctx.store, "UPDATE worker_instruction_snapshots SET binding_json = '{}' WHERE binding_sha256 = ?", [key])
    assert {:error, :worker_instruction_inheritance_unproven} = WorkerInstructions.inherit(ctx.store, Map.put(changed, "spec_revision", 3), "feature-writer", task, expected)
  end

  test "recomputed outer digest cannot hide missing duplicate malformed or oversized instruction records", ctx do
    root = fixture_instructions(ctx)
    binding = %{"run_id" => "run", "role" => "feature-planner"}
    {:ok, original} = WorkerInstructions.admit(ctx.store, binding, "feature-planner", root)
    original = Map.drop(original, ~w(instruction_snapshot_sha256 instruction_binding_sha256))
    [first | rest] = original["shared_instructions"]
    Store.query!(ctx.store, "DROP TRIGGER worker_instruction_snapshot_update")

    variants = [
      rest,
      [first, first | rest],
      [Map.put(first, "sha256", String.duplicate("a", 64)) | rest],
      [%{first | "content" => nil} | rest],
      [%{first | "content" => String.duplicate("x", 65_537), "sha256" => sha(String.duplicate("x", 65_537))} | rest],
      Enum.map(original["shared_instructions"], &Map.merge(&1, %{"content" => String.duplicate("x", 60_000), "sha256" => sha(String.duplicate("x", 60_000))}))
    ]

    for instructions <- variants do
      json = Jason.encode!(Map.put(original, "shared_instructions", instructions))
      Store.query!(ctx.store, "UPDATE worker_instruction_snapshots SET bundle_json = ?, bundle_sha256 = ?", [json, sha(json)])
      assert {:error, :worker_instruction_snapshot_invalid} = WorkerInstructions.read(ctx.store, binding, "feature-planner")
    end
  end

  test "valid candidate and pipeline changes and every round require their own admission", ctx do
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:ok, original} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    File.write!(Path.join(ctx.path, "fixture.txt"), "candidate\n")
    git(ctx.path, ["add", "fixture.txt"])
    git(ctx.path, ["commit", "--no-verify", "-m", "candidate"])
    candidate = git(ctx.path, ["rev-parse", "HEAD"]) |> String.trim()
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{candidate_sha: candidate})
    assert {:error, :worker_instruction_snapshot_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert {:ok, current} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    refute current == original

    for field <- [:code_repair_round, :validation_repair_round, :verifier_round] do
      assert {:ok, _} = RunLedger.update(ctx.store, "run", %{field => 1})
      assert {:error, :worker_instruction_snapshot_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "change-verifier", ctx.sha)
      assert {:ok, _} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    end

    for pipeline <- [1, 2] do
      evidence = %{"status" => "PASS", "sha" => candidate, "pipeline_id" => pipeline}
      assert {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_evidence_json: Jason.encode!(evidence), ci_preflight_sha: candidate, ci_pipeline_id: pipeline})
      assert {:error, :worker_instruction_snapshot_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "change-verifier", ctx.sha)
      assert {:ok, packet} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
      assert Jason.decode!(packet)["ci_evidence"] == evidence
    end
  end

  test "current contract base candidate and exact CI remain live checks rather than cached packet authority", ctx do
    assert {:ok, _} = TicketWorkerRunner.bind_base(ctx.store, "run", ctx.sha)
    assert {:ok, original} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{implementation_iteration: 1})
    assert {:error, :worker_instruction_snapshot_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "feature-writer", ctx.sha)
    assert {:ok, next} = TicketWorkerRunner.packet(ctx.store, "run", "feature-writer", ctx.sha)
    refute next == original
    assert {:error, :ticket_review_base_missing} = TicketWorkerRunner.read_packet(ctx.store, "run", "feature-writer", String.duplicate("b", 40))
    assert {:ok, _} = RunLedger.update(ctx.store, "run", %{ci_evidence_json: Jason.encode!(%{"status" => "PASS", "sha" => String.duplicate("b", 40), "pipeline_id" => 1})})
    assert {:error, :ticket_verifier_ci_evidence_mismatch} = TicketWorkerRunner.packet(ctx.store, "run", "change-verifier", ctx.sha)
    Store.query!(ctx.store, "UPDATE runs SET contract_sha256 = ? WHERE run_id = 'run'", [String.duplicate("c", 64)])
    assert {:error, _} = TicketWorkerRunner.read_packet(ctx.store, "run", "feature-writer", ctx.sha)
  end

  test "legacy review prompt embeds the same criteria and compact output adapter without relaxing manual validation" do
    prompt = Prompt.change_verifier(%{}, "contract", "digest", String.duplicate("a", 40), "master")
    assert prompt =~ "complete embedded shared review criteria"
    assert prompt =~ "verdict -> status"
    assert prompt =~ "review-criteria.md"
    assert prompt =~ "verdict-contract.md"
    assert prompt =~ "exact-SHA manual validation"
    assert prompt =~ "release-pinned bytes, not host skill-file rereads"
    resources = Prompt.__info__(:attributes) |> Keyword.get_values(:external_resource) |> inspect()
    for reference <- ~w(verify-feature-delivery/SKILL.md verdict-contract.md review-criteria.md), do: assert(resources =~ reference)
  end

  test "schema 42 gains only empty instruction storage and preserves existing rows and hazard triggers", ctx do
    for name <-
          ~w(worker_instruction_snapshot_update worker_instruction_snapshot_delete worker_instruction_task_binding_update worker_instruction_task_binding_delete worker_instruction_snapshot_schema_rollback),
        do: Store.query!(ctx.store, "DROP TRIGGER #{name}")

    Store.query!(ctx.store, "DROP TABLE worker_instruction_task_bindings")
    Store.query!(ctx.store, "DROP TABLE worker_instruction_snapshots")
    Store.query!(ctx.store, "DELETE FROM factory_schema_migrations WHERE version = 43")
    tables = Store.query!(ctx.store, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").rows |> List.flatten()
    before = Map.new(tables, &{&1, Store.query!(ctx.store, "SELECT * FROM #{&1}").rows})
    triggers = Store.query!(ctx.store, "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name").rows
    assert {:error, :factory_ledger_schema_not_current} = Store.start_read_only(database: ctx.database)
    assert :ok = Store.initialize(ctx.store)

    for {table, rows} <- before, table != "factory_schema_migrations" do
      assert Store.query!(ctx.store, "SELECT * FROM #{table}").rows == rows
    end

    assert Enum.all?(triggers, &(&1 in Store.query!(ctx.store, "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'").rows))
    assert Store.query!(ctx.store, "SELECT * FROM worker_instruction_snapshots").rows == []
    schema = Store.query!(ctx.store, "SELECT name, sql FROM sqlite_master ORDER BY name").rows
    assert :ok = Store.initialize(ctx.store)
    assert Store.query!(ctx.store, "SELECT name, sql FROM sqlite_master ORDER BY name").rows == schema
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    GenServer.stop(reader)
  end

  defp prepare_ci_repair(ctx) do
    {:ok, %{run: prior}} = RunLedger.update(ctx.store, "run", %{state: "REPAIRING", code_repair_round: 1, repair_findings_json: ~s({"kind":"TICKET_CI_REPAIR","claim_key":"claim"})})
    diagnosis = Jason.encode!(%{"status" => "REPAIRABLE", "logs" => [], "findings" => []})
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES ('diagnosis', 'run', ?, 99, '{}', ?, ?, ?, 'REPAIRABLE', 'now')", [ctx.sha, sha("{}"), diagnosis, sha(diagnosis)])

    claim = %{
      "kind" => "TICKET_CI_REPAIR",
      "claim_key" => "claim",
      "diagnosis_key" => "diagnosis",
      "round" => 1,
      "prior_run" => prior,
      "source_task" => Store.one!(ctx.store, "SELECT * FROM factory_tasks WHERE task_key='writer'"),
      "allowed_writer_paths" => ["fixture.txt"],
      "required_generated_paths" => []
    }

    encoded = Jason.encode!(claim)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('claim', 'diagnosis', 'run', 1, ?, ?, 'now')", [encoded, sha(encoded)])
  end

  defp fixture_instructions(ctx) do
    root = Path.join(ctx.root, "instructions")
    common = ~w(AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc rules/additional.md)

    for relative <- Enum.uniq(common ++ Enum.flat_map(@bundles, fn {_role, paths} -> paths end)) do
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "Complete fixture instructions: #{relative}\n")
    end

    root
  end

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
