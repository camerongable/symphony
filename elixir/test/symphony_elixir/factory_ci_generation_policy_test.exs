defmodule SymphonyElixir.FactoryCiGenerationPolicyTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{Controller, ControlServer, Policy, Store, TicketCiRepairSuccessor}
  alias SymphonyElixir.{Config, Workflow, WorkflowStore}

  setup do
    root = Path.join(System.tmp_dir!(), "ci-generation-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, database: Path.join(root, "factory.sqlite"), name: __MODULE__.Store})

    factory = %{
      enabled: true,
      scope: "policy",
      dispatcher_id: "fixture",
      lease_seconds: 240,
      ticket_supervisor: %{"enabled" => true, "ci_repair" => "disabled", "pilot_issue_keys" => ["PPL-123"]},
      repositories: %{"grail" => %{"path" => root, "base_branch" => "master", "gitlab_project" => "fixture/project", "gitlab_project_id" => "1000", "private_token" => "never-return-this"}}
    }

    control = start_supervised!({ControlServer, store: store, factory: factory, name: nil})
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})
    %{root: root, store: store, factory: factory, control: control, supervisor: supervisor}
  end

  test "cached policy uses the genuine owner and exact store identity, not workflow reload", c do
    owner = start_supervised!({Controller, settings: %{factory: c.factory, polling: %{interval_ms: 60_000}}, store: __MODULE__.Store, control_server: c.control, task_supervisor: c.supervisor})
    assert {:ok, cached} = Controller.cached_generation_policy(c.store, "grail")
    assert cached["ci_repair"] == "disabled"
    assert {:ok, ^cached} = Controller.cached_generation_policy(__MODULE__.Store, "grail")
    refute inspect(cached) =~ "never-return-this"
    assert {:error, :controller_generation_policy_unavailable} = Controller.cached_generation_policy(c.store, "unknown")
    other = start_supervised!({Store, database: Path.join(c.root, "other.sqlite")}, id: :other_store)
    assert {:error, :controller_generation_policy_unavailable} = Controller.cached_generation_policy(other, "grail")

    previous = Workflow.workflow_file_path()
    workflow = Path.join(c.root, "reload.md")
    SymphonyElixir.TestSupport.write_workflow_file!(workflow)
    content = File.read!(workflow) |> String.replace("\n---\n", "\nfactory:\n  enabled: false\n  ticket_supervisor:\n    ci_repair: native_bounded_v1\n---\n", global: false)
    File.write!(workflow, content)
    Workflow.set_workflow_file_path(workflow)

    try do
      assert :ok = WorkflowStore.force_reload()
      assert Config.settings!().factory.ticket_supervisor["ci_repair"] == "native_bounded_v1"
      assert {:ok, ^cached} = Controller.cached_generation_policy(c.store, "grail")
      :sys.suspend(owner)

      try do
        assert {:error, :controller_generation_policy_unavailable} = Controller.cached_generation_policy(c.store, "grail")
      after
        :sys.resume(owner)
      end
    after
      if previous, do: Workflow.set_workflow_file_path(previous), else: Workflow.clear_workflow_file_path()
      WorkflowStore.force_reload()
    end
  end

  test "absent and foreign named processes cannot impersonate the module-owned controller", c do
    assert {:error, :controller_generation_policy_unavailable} = Controller.cached_generation_policy(c.store, "grail")
    start_supervised!(%{id: :foreign_controller, start: {Agent, :start_link, [fn -> %{} end, [name: Controller]]}})
    assert {:error, :controller_generation_policy_unavailable} = Controller.cached_generation_policy(c.store, "grail")
  end

  test "successor current cap binds genuine cached owner and actual immutable workflow observation", c do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(c.root)
    c = %{c | root: root}
    previous = Workflow.workflow_file_path()
    workflow = Path.join(c.root, "successor-policy.md")

    raw =
      "---\nfactory:\n  enabled: true\n  scope: policy\n  dispatcher_id: fixture\n  maximum_code_repair_rounds: 5\n  ticket_supervisor:\n    enabled: true\n    all_eligible_tickets: true\n    pilot_issue_keys: []\n    ci_repair: native_bounded_v1\n  repositories:\n    grail:\n      path: #{c.root}\n      base_branch: master\n      gitlab_project: fixture/project\n      gitlab_project_id: '1000'\n---\nFixture.\n"

    required = "  database: #{Path.join(c.root, "factory.sqlite")}\n  controller_codex_project_id: projectless\n"
    raw = String.replace(raw, "  scope: policy\n", required <> "  scope: policy\n", global: false)
    File.write!(workflow, raw)
    File.chmod!(workflow, 0o600)
    Workflow.set_workflow_file_path(workflow)
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)
    assert {:ok, loaded} = Workflow.load(workflow)
    assert {:ok, ^loaded} = Workflow.parse_content(raw)
    assert {:ok, other_bytes} = Workflow.parse_content(String.replace(raw, "maximum_code_repair_rounds: 5", "maximum_code_repair_rounds: 3"))
    assert other_bytes.config["factory"]["maximum_code_repair_rounds"] == 3
    assert loaded.config["factory"]["maximum_code_repair_rounds"] == 5
    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(loaded.config)
    start_supervised!({Controller, settings: settings, store: c.store, control_server: c.control, task_supervisor: c.supervisor})
    run = %{"repo_key" => "grail", "repo_path" => c.root, "worktree" => Path.join(c.root, "source"), "issue_key" => "PPL-123"}
    assert {:ok, receipt} = TicketCiRepairSuccessor.policy_receipt(c.store, run)
    assert receipt["configured_limit"] == 5 and receipt["effective_limit"] == 5
    assert receipt["workflow_sha256"] == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    assert receipt["workflow_stat"]["mode"] == File.stat!(workflow).mode
    assert {:error, :ci_successor_current_policy_unproven} = TicketCiRepairSuccessor.policy_receipt(c.store, Map.put(run, "repo_path", "/foreign"))
    File.write!(workflow, String.replace(raw, "maximum_code_repair_rounds: 5", "maximum_code_repair_rounds: 3"))
    assert {:error, :ci_successor_current_policy_unproven} = TicketCiRepairSuccessor.policy_receipt(c.store, run)
    File.write!(workflow, raw)
    File.chmod!(workflow, 0o666)
    assert {:error, :ci_successor_current_policy_unproven} = TicketCiRepairSuccessor.policy_receipt(c.store, run)
  end

  for {selection, expected} <- [
        {%{"enabled" => true, "all_eligible_tickets" => true, "pilot_issue_keys" => []}, true},
        {%{"enabled" => true, "pilot_issue_keys" => ["PPL-123"]}, true},
        {%{"enabled" => true, "pilot_issue_keys" => ["PPL-999"]}, false},
        {%{"enabled" => false, "all_eligible_tickets" => true}, false},
        {%{"enabled" => "true", "all_eligible_tickets" => true}, false},
        {%{"enabled" => true, "all_eligible_tickets" => "true", "pilot_issue_keys" => []}, false},
        {%{"all_eligible_tickets" => true}, false},
        {%{"enabled" => true}, false}
      ] do
    @selection selection
    @expected expected
    test "genuine cached generation selection #{inspect(selection)}", c do
      supervisor = Map.put(@selection, "ci_repair", "native_bounded_v1")
      factory = %{c.factory | ticket_supervisor: supervisor}
      owner = start_supervised!({Controller, settings: %{factory: factory, polling: %{interval_ms: 60_000}}, store: c.store, control_server: c.control, task_supervisor: c.supervisor})
      assert :proc_lib.translate_initial_call(owner) == {Controller, :init, 1}
      assert {:ok, cached} = Controller.cached_generation_policy(c.store, "grail")
      assert cached["ticket_selection"] == @selection
      assert Policy.ticket_selected?(cached["ticket_selection"], "PPL-123") == @expected
    end
  end
end
