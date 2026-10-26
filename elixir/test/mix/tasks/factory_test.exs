defmodule Mix.Tasks.FactoryTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Factory.Store

  defmodule ObservingShell do
    def info(_message) do
      send(self(), {:factory_runtime, Workflow.workflow_file_path(), Config.settings!().factory.database})
      if Process.get(:factory_shell_fail), do: raise("fixture action failure")
      :ok
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "factory-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.fetch_env(:symphony_elixir, :workflow_file_path)
    shell = Mix.shell()
    prior = Path.join(root, "prior.md")
    selected = Path.join(root, "selected.md")
    database = Path.join(root, "factory.sqlite")
    File.write!(prior, "---\ntracker:\n  kind: memory\nfactory:\n  database: #{Path.join(root, "other.sqlite")}\n---\n")

    File.write!(
      selected,
      "---\ntracker:\n  kind: memory\nfactory:\n  enabled: true\n  controller_codex_project_id: fixture-project\n  dispatcher_id: fixture-dispatcher\n  database: #{database}\n---\n"
    )

    start_supervised!({Store, database: database})
    Workflow.set_workflow_file_path(prior)
    Mix.shell(ObservingShell)

    on_exit(fn ->
      Mix.shell(shell)

      case previous do
        {:ok, path} -> Workflow.set_workflow_file_path(path)
        :error -> Workflow.clear_workflow_file_path()
      end

      File.rm_rf!(root)
    end)

    %{prior: prior, selected: selected, database: database}
  end

  test "explicit workflow supplies native runtime settings during the command and restores prior settings", ctx do
    Mix.Tasks.Factory.run(["status", "--workflow", ctx.selected])
    assert_received {:factory_runtime, path, database}
    assert path == ctx.selected and database == ctx.database
    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == {:ok, ctx.prior}
    assert Config.settings!().factory.database == Path.join(Path.dirname(ctx.prior), "other.sqlite")
  end

  test "workflow binding is restored after action failure and invalid configuration", ctx do
    Process.put(:factory_shell_fail, true)
    assert_raise RuntimeError, "fixture action failure", fn -> Mix.Tasks.Factory.run(["status", "--workflow", ctx.selected]) end
    assert_received {:factory_runtime, path, _}
    assert path == ctx.selected
    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == {:ok, ctx.prior}
    assert_raise Mix.Error, ~r/Unable to load factory workflow/, fn -> Mix.Tasks.Factory.run(["status", "--workflow", ctx.selected <> ".missing"]) end
    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == {:ok, ctx.prior}
  end

  test "an initially unset workflow binding remains unset after the command", ctx do
    Workflow.clear_workflow_file_path()
    Mix.Tasks.Factory.run(["status", "--workflow", ctx.selected])
    assert_received {:factory_runtime, path, database}
    assert {path, database} == {ctx.selected, ctx.database}
    assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == :error
  end

  test "explicit CAS commands reject a wrong nonce before native or remote observation", ctx do
    for action <- ["prepare-push-cas", "execute-push-cas", "reconcile-push-cas"] do
      assert_raise Mix.Error, ~r/unknown_run/, fn ->
        Mix.Tasks.Factory.run([action, "missing-run", String.duplicate("a", 64), "--workflow", ctx.selected])
      end

      assert Application.fetch_env(:symphony_elixir, :workflow_file_path) == {:ok, ctx.prior}
    end
  end
end
