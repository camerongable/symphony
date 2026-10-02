defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(issue_ids) do
      send(self(), {:fetch_issues_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Second prompt",
      poll_interval_ms: 45_000
    )

    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    good_settings = Config.settings!()
    assert good_settings.polling.interval_ms == 45_000

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    File.write!(
      Workflow.workflow_file_path(),
      "---\npolling:\n  interval_ms: nope\n---\nTyped-invalid prompt\n"
    )

    assert {:error, {:invalid_workflow_config, message}} = WorkflowStore.force_reload()
    assert message =~ "polling.interval_ms"
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      prompt: "Semantic-invalid prompt"
    )

    assert {:error, :missing_linear_project_slug} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, :missing_linear_project_slug} = Config.validate!()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, settings} = WorkflowStore.settings()
    assert settings.polling.interval_ms == 30_000
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.settings()

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    assert :ok = GenServer.stop(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    assert :ok = WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_ids(["issue-1"])

    binding = SymphonyElixir.Tracker.bind_agent_tools()
    assert binding.adapter == Memory
    assert binding.tool_specs == []
    assert binding.secret_environment_names == []

    assert SymphonyElixir.Tracker.execute_bound_agent_tool(binding, "not_a_memory_tool", %{})[
             "success"
           ] == false

    assert {:error, {:unsupported_tracker_kind, "future-tracker"}} =
             SymphonyElixir.Tracker.adapter_for_kind("future-tracker")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
    assert SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"]
  end

  test "linear adapter delegates reads and advertises its native agent tool" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issues_by_ids(["issue-1"])
    assert_receive {:fetch_issues_by_ids_called, ["issue-1"]}

    assert [%{"name" => "linear_graphql"}] = Adapter.agent_tool_specs()
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|

    assert html =~
             ~r|<link rel="icon" type="image/png" sizes="128x128" href="/favicon\.png\?v=[0-9a-f]{12}">|

    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-connected"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-connected"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "font-family: -apple-system"
    assert dashboard_css =~ ".responsive-table td::before"
    refute dashboard_css =~ "Sohne"

    dashboard_js = response(get(build_conn(), "/dashboard.js"), 200)
    assert dashboard_js =~ "PersistentDisclosure"
    assert dashboard_js =~ "this.el.open = this.wasOpen"

    favicon_conn = get(build_conn(), "/favicon.png")
    assert response(favicon_conn, 200) == File.read!("priv/static/favicon.png")
    assert Plug.Conn.get_resp_header(favicon_conn, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Software factory"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-HTTP")
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="Open MT-HTTP in the issue tracker")
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Reconnecting"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-connected"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "dashboard and state api expose the factory control plane" do
    orchestrator_name = Module.concat(__MODULE__, :FactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: &factory_dashboard_snapshot/0
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "From Jira to review"
    assert html =~ "Scheduler needs attention"
    assert html =~ "Jira intake"
    assert html =~ "last successful Jira poll"
    assert html =~ "1 tracked"
    assert html =~ "PPL-9723"
    assert html =~ "Detect visually hidden text"
    assert html =~ "Specification"
    assert html =~ "repo-grail"
    assert html =~ "PPL-123"
    assert html =~ "cgable/PPL-123-dashboard"
    assert html =~ "Change Verifier"
    refute html =~ "Open orchestrator"
    assert html =~ "45.0 GB"
    assert html =~ "Workspace hibernated"
    assert html =~ "WORKTREE_HIBERNATED"
    assert html =~ "1 visible worker tasks"

    document = Floki.parse_document!(html)
    capacity = Floki.find(document, ".capacity-card")
    assert length(Floki.find(capacity, "tbody tr")) == 1
    assert Floki.text(capacity, sep: " ") =~ "All repositories"
    assert Floki.text(capacity, sep: " ") =~ "grail"
    assert Floki.text(capacity, sep: " ") =~ "polaris"
    assert Floki.text(Floki.find(document, ".status-cluster"), sep: " ") =~ "Writer capacity available"
    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="stopped"])) != []

    workflows = Floki.find(document, ".runs-section")
    assert length(Floki.find(workflows, "tbody tr")) == 1
    refute Floki.text(workflows, sep: " ") =~ "stale failure from a previous attempt"
    assert Floki.find(workflows, ~s(td[data-label="Progress"] .state-badge)) == []
    assert Floki.text(Floki.find(workflows, ~s(td[data-label="Workspace"])), sep: " ") =~ "Worktree hibernated"

    task_history = Floki.find(document, ".factory-task-history")

    assert Floki.find(task_history, ~s(th)) |> Enum.map(&Floki.text/1) ==
             ["Issue", "Role", "Status", "Model", "Failure", "Codex task", "Updated"]

    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["factory"]["control"]["status"] == "ACTIVE"
    assert state["factory"]["control"]["controller_writer_conflict_count"] == 2
    assert state["factory"]["intake"]["count"] == 1
    assert state["factory"]["counts"]["hibernated"] == 1
    assert hd(state["factory"]["tasks"])["thread_id"] == "thread-verifier"
  end

  test "paused dashboard identifies Jira intake as a saved snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :PausedFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :status], "PAUSED")
      |> put_in([:intake, :stale], true)
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Dashboard connected"
    assert html =~ "Stale snapshot: polling is paused, so this saved intake may no longer match Jira."
    assert html =~ "Factory BEAM fingerprint"

    document = Floki.parse_document!(html)
    intake = Floki.find(document, ".intake-section")
    intent = Floki.find(intake, ~s(td[data-label="Intent"]))
    routing = Floki.find(intake, ~s(td[data-label="Routing"]))

    assert Floki.text(Floki.find(document, ".status-cluster .state-badge-danger")) =~ "Scheduler paused"
    assert Floki.text(Floki.find(document, ".status-cluster .state-badge-active")) =~ "Writer capacity available"

    assert document
           |> Floki.find(".factory-controller .section-header > .state-badge-danger")
           |> Floki.text()
           |> String.trim() == "Paused"

    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="stopped"])) != []
    assert Floki.find(intake, ".section-header > .state-badge-active") == []
    assert Floki.find(intake, ".snapshot-note time") != []
    assert Floki.find(intent, ".state-badge") == []
    assert Floki.find(routing, ".state-badge") == []
    assert Floki.find(intent, ".table-value") != []
    assert Floki.find(routing, ".table-value") != []
    refute html =~ ~r|</time>\s*\.|s

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ".status-badge-connected"
    assert dashboard_css =~ ".status-badge-connected .status-badge-dot {\n  background: var(--accent);"
    assert dashboard_css =~ ".status-badge-offline .status-badge-dot {\n  background: var(--muted);"

    [_, connected_badge] = Regex.run(~r/\.status-badge-connected\s*\{([^}]*)\}/s, dashboard_css)
    refute connected_badge =~ "background:"
    refute connected_badge =~ "color:"
    assert dashboard_css =~ ~s(data-factory-operability="ready")
    assert dashboard_css =~ ~s(data-factory-operability="stopped")
  end

  test "dashboard distinguishes writer capacity, workspace, and failed task details" do
    orchestrator_name = Module.concat(__MODULE__, :LimitedFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)
      |> put_in([:capacity, Access.at(0), :result], "INSUFFICIENT_WRITER_CAPACITY")
      |> put_in([:runs, Access.at(0), :workspace_state], "MATERIALIZED")
      |> put_in([:tasks, Access.at(0), :status], "FAILED")
      |> put_in([:tasks, Access.at(0), :failure_code], "factory_stage_output_invalid_json")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="limited"])) != []
    assert Floki.text(Floki.find(document, ".status-cluster .state-badge-active")) =~ "Scheduler active"
    assert Floki.text(Floki.find(document, ".status-cluster .state-badge-warning")) =~ "Writer capacity limited"
    assert Floki.text(Floki.find(document, ".capacity-card .state-badge-warning")) =~ "Limited"

    assert Floki.text(Floki.find(document, ~s(.runs-section td[data-label="Workspace"])), sep: " ") =~
             "Worktree present"

    task_history = Floki.find(document, ".factory-task-history")
    assert Floki.text(Floki.find(task_history, ~s(td[data-label="Status"]))) =~ "Failed"

    assert Floki.text(Floki.find(task_history, ~s(td[data-label="Model"])), sep: " ") =~
             "gpt-5.6-sol high effort"

    assert Floki.text(Floki.find(task_history, ~s(td[data-label="Failure"]))) =~
             "Worker returned text instead of the required structured result."
  end

  test "dashboard uses ready tint only when scheduling and writer capacity are available" do
    orchestrator_name = Module.concat(__MODULE__, :ReadyFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert Floki.find(Floki.parse_document!(html), ~s(.dashboard-shell[data-factory-operability="ready"])) != []
  end

  test "dashboard reports Desktop Broker request state separately from scheduler health" do
    orchestrator_name = Module.concat(__MODULE__, :BrokerFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)
      |> Map.put(:broker, %{
        pending: 2,
        claimed_unverified: 0,
        needs_reconciliation: 0,
        last_completed_at: "2026-09-24T12:00:00Z"
      })

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    assert Floki.text(Floki.find(document, ".status-cluster"), sep: " ") =~ "Scheduler active"
    assert Floki.text(Floki.find(document, ".status-cluster"), sep: " ") =~ "Broker requests pending"
    assert Floki.find(document, ".status-cluster .state-badge-active") |> Floki.text() =~ "Scheduler active"
    assert Floki.find(document, ".status-cluster .state-badge-danger") == []

    broker = Floki.find(document, ".broker-card")
    assert Floki.text(broker, sep: " ") =~ "Desktop Broker"
    assert Floki.text(broker, sep: " ") =~ "Automation heartbeat is not measured here"
    assert Floki.text(broker, sep: " ") =~ "Pending 2"
    assert Floki.text(broker, sep: " ") =~ "Claimed 0"
    assert Floki.text(broker, sep: " ") =~ "Needs reconciliation 0"
    assert Floki.find(document, ".control-grid-with-broker .capacity-card") != []
    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="ready"])) != []

    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["factory"]["broker"]["pending"] == 2
  end

  test "dashboard does not mark an unverified Desktop Broker heartbeat healthy" do
    orchestrator_name = Module.concat(__MODULE__, :UnknownBrokerFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)
      |> Map.put(:broker, %{
        pending: 0,
        claimed_unverified: 0,
        needs_reconciliation: 0,
        last_completed_at: nil
      })

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    assert Floki.text(Floki.find(document, ".broker-card .section-header > .state-badge")) =~ "Unknown"
    assert Floki.find(document, ".broker-card .section-header > .state-badge-active") == []
    assert Floki.text(Floki.find(document, ".status-cluster"), sep: " ") =~ "Broker status unknown"
    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="unknown"])) != []
  end

  test "dashboard treats one claimed Desktop request as neutral in-flight work" do
    orchestrator_name = Module.concat(__MODULE__, :ClaimedBrokerFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)
      |> Map.put(:broker, %{
        pending: 0,
        claimed_unverified: 1,
        needs_reconciliation: 0,
        last_completed_at: nil
      })

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    assert Floki.text(Floki.find(document, ".status-cluster .state-badge"), sep: " ") =~
             "Broker request claimed"

    assert Floki.find(document, ".status-cluster .state-badge-warning") == []
    assert Floki.find(document, ".broker-card .section-header > .state-badge-warning") == []

    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="ready"])) != []
  end

  test "dashboard flags Desktop requests requiring reconciliation independently of a running scheduler" do
    orchestrator_name = Module.concat(__MODULE__, :ReconcileBrokerFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :controller_writer_conflict_since], nil)
      |> Map.put(:broker, %{
        pending: 1,
        claimed_unverified: 1,
        needs_reconciliation: 1,
        last_completed_at: nil
      })

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    assert Floki.text(Floki.find(document, ".status-cluster"), sep: " ") =~ "Scheduler active"

    assert Floki.text(Floki.find(document, ".status-cluster .state-badge-danger")) =~
             "Broker needs attention"

    assert Floki.text(Floki.find(document, ".broker-card .section-header > .state-badge-danger")) =~
             "Needs attention"

    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="stopped"])) != []
  end

  test "dashboard summary does not count a queued ticket as active without a running task" do
    orchestrator_name = Module.concat(__MODULE__, :FactorySummaryOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: Map.put(static_snapshot(), :running, []),
        refresh: :unavailable
      )

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:counts, :in_progress], 1)
      |> put_in([:counts, :review_ready], 0)
      |> put_in([:overview], %{
        active: 0,
        queued: 1,
        review_ready: 0,
        needs_attention: 0,
        by_issue: %{"PPL-9723" => "QUEUED"}
      })
      |> put_in([:runs, Access.at(0), :issue_key], "PPL-9723")
      |> put_in([:runs, Access.at(0), :state], "SPEC_DRAFTING")
      |> put_in([:tasks, Access.at(0), :issue_key], "PPL-9723")
      |> put_in([:tasks, Access.at(0), :status], "FAILED")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    summary_cards =
      html
      |> Floki.parse_document!()
      |> Floki.find(".metric-card")

    active_text =
      summary_cards
      |> Enum.find(&(Floki.text(&1, sep: " ") =~ "Active work"))
      |> Floki.text(sep: " ")

    queue_text =
      summary_cards
      |> Enum.find(&(Floki.text(&1, sep: " ") =~ "Jira queue"))
      |> Floki.text(sep: " ")

    assert active_text =~ "Active work 0"
    assert active_text =~ "0 active tickets"
    assert queue_text =~ "Jira queue 1"

    workflow =
      html
      |> Floki.parse_document!()
      |> Floki.find(".runs-section")
      |> Floki.text(sep: " ")

    assert workflow =~ "Queued"
    assert workflow =~ "Spec drafting · Delivery · grail"
  end

  test "dashboard shows rejected verifier creation in the exclusive needs-attention bucket" do
    orchestrator_name = Module.concat(__MODULE__, :FactoryBlockedSummaryOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    factory_snapshot =
      put_in(factory_dashboard_snapshot().overview, %{
        active: 0,
        queued: 0,
        review_ready: 0,
        needs_attention: 1,
        by_issue: %{"PPL-123" => "NEEDS_ATTENTION"}
      })

    handoff = %{
      label: "Verifier creation failed",
      reason: "Desktop rejected the creation arguments. Correct them and recover this same request.",
      request_key: "run-1:change-verifier:3:create"
    }

    run = factory_snapshot.runs |> hd() |> Map.merge(%{state: "VERIFYING", handoff_attention: handoff})
    task = factory_snapshot.tasks |> hd() |> Map.merge(%{status: "WAITING_FOR_BROKER", thread_id: nil, handoff_attention: handoff})
    factory_snapshot = %{factory_snapshot | runs: [run], tasks: [task]}

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    attention_card =
      html
      |> Floki.parse_document!()
      |> Floki.find(".metric-card")
      |> Enum.find(&(Floki.text(&1, sep: " ") =~ "Needs attention"))

    attention_text = Floki.text(attention_card, sep: " ")
    assert attention_text =~ "Needs attention 1"
    assert attention_text =~ "1 ticket needs attention"

    workflow = html |> Floki.parse_document!() |> Floki.find(".factory-runs-table") |> Floki.text(sep: " ")
    assert workflow =~ "Needs attention"
    assert workflow =~ "Verifier creation failed"
    assert workflow =~ "Correct them and recover this same request"
    assert workflow =~ handoff.request_key
    refute workflow =~ "Active"

    task_failure = html |> Floki.parse_document!() |> Floki.find(".task-failure") |> Floki.text(sep: " ")
    assert task_failure =~ "Verifier creation failed"
  end

  test "active ticket workflow links to its current Codex task" do
    orchestrator_name = Module.concat(__MODULE__, :ActiveFactoryTaskOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: Map.put(static_snapshot(), :running, []),
        refresh: :unavailable
      )

    active_task = %{
      (factory_dashboard_snapshot().tasks
       |> hd())
      | issue_key: "PPL-123",
        status: "RUNNING",
        thread_id: "thread-active"
    }

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:tasks], [active_task])
      |> put_in([:runs, Access.at(0), :tasks], [active_task])
      |> put_in([:runs, Access.at(0), :state], "SPEC_DRAFTING")
      |> put_in([:overview], %{
        active: 1,
        queued: 1,
        review_ready: 0,
        needs_attention: 0,
        by_issue: %{"PPL-123" => "ACTIVE", "PPL-9723" => "QUEUED"}
      })

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Open active task"
    assert html =~ ~s(href="codex://threads/thread-active")

    workflow =
      html
      |> Floki.parse_document!()
      |> Floki.find(".runs-section")
      |> Floki.text(sep: " ")

    assert workflow =~ "Active"
    assert workflow =~ "Spec drafting · Delivery · grail"
  end

  test "failed factory tasks explain the failure and are not shown as pending" do
    orchestrator_name = Module.concat(__MODULE__, :FailedFactoryTaskOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    failed_task = %{
      (factory_dashboard_snapshot().tasks
       |> hd())
      | status: "FAILED",
        thread_id: nil,
        failure_code: "project not found: project-grail"
    }

    factory_snapshot = put_in(factory_dashboard_snapshot().tasks, [failed_task])

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    task_history =
      html
      |> Floki.parse_document!()
      |> Floki.find(".factory-task-history")
      |> Floki.text(sep: " ")

    assert task_history =~ "project not found: project-grail"
    assert task_history =~ "Not created"
    refute task_history =~ "Pending"
  end

  test "factory task failures translate structured-output errors for operators" do
    orchestrator_name = Module.concat(__MODULE__, :InvalidFactoryOutputOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    failed_task = %{
      (factory_dashboard_snapshot().tasks
       |> hd())
      | status: "FAILED",
        failure_code: ~s({:factory_stage_output_invalid_json, %Jason.DecodeError{position: 0, data: "plain text"}})
    }

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:tasks], [failed_task])
      |> put_in([:runs, Access.at(0), :last_error], failed_task.failure_code)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    task_history =
      html
      |> Floki.parse_document!()
      |> Floki.find(".factory-task-history")
      |> Floki.text(sep: " ")

    assert task_history =~ "Worker returned text instead of the required structured result."
    refute task_history =~ "Jason.DecodeError"

    workflow =
      html
      |> Floki.parse_document!()
      |> Floki.find(".runs-section")
      |> Floki.text(sep: " ")

    assert workflow =~ "Worker returned text instead of the required structured result."
    refute workflow =~ "Jason.DecodeError"
  end

  test "controller lease distinguishes an expired tick from a live held lease" do
    orchestrator_name = Module.concat(__MODULE__, :ExpiredFactoryLeaseOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    expired_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

    factory_snapshot =
      factory_dashboard_snapshot()
      |> put_in([:control, :tick_id], "expired-tick")
      |> put_in([:control, :lease_expires_at], expired_at)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    controller_text =
      html
      |> Floki.parse_document!()
      |> Floki.find(".factory-controller")
      |> Floki.text(sep: " ")

    assert controller_text =~ "Lease Expired"
    refute controller_text =~ "Lease Held"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp factory_dashboard_snapshot do
    %{
      enabled: true,
      available: true,
      control: %{
        status: "ACTIVE",
        scope: "assigned-jira-work",
        dispatcher_id: "dispatcher",
        generation: 12,
        tick_id: nil,
        lease_expires_at: nil,
        updated_at: "2026-09-22T20:00:00Z",
        controller_thread_id: "thread-controller",
        controller_turn_id: "turn-controller",
        controller_codex_project_id: "project-factory",
        controller_model: "gpt-5.6-terra",
        controller_reasoning_effort: "medium",
        controller_writer_conflict_since: "2026-09-22T20:00:00Z",
        controller_writer_conflict_count: 2,
        runtime_identity: %{
          process_started_at: "2026-09-22T20:00:00Z",
          factory_beam_fingerprint: String.duplicate("a", 64),
          factory_beam_module_count: 12
        }
      },
      counts: %{
        total_runs: 1,
        in_progress: 0,
        review_ready: 1,
        blocked: 0,
        hibernated: 1,
        visible_tasks: 1,
        by_state: %{"READY_FOR_REVIEW" => 1}
      },
      overview: %{
        active: 0,
        queued: 1,
        review_ready: 1,
        needs_attention: 0,
        by_issue: %{
          "PPL-9723" => "QUEUED",
          "PPL-123" => "REVIEW_READY"
        }
      },
      intake: %{
        available: true,
        stale: false,
        observed_at: "2026-09-22T20:01:00Z",
        count: 1,
        error: nil,
        issues: [
          %{
            issue_key: "PPL-9723",
            issue_url: "https://jira.example/PPL-9723",
            summary: "Detect visually hidden text in PDFs for indirect injection",
            status: "To Do",
            labels: ["repo-grail", "spec-needed"],
            project_key: "PPL",
            updated_at: "2026-09-22T19:59:00Z",
            classification: "SPECIFICATION",
            routing_status: "ROUTED",
            repo_key: "repo-grail",
            local_state: "QUEUED"
          }
        ]
      },
      capacity: [
        %{
          repo_key: "grail",
          free_gb: 45.0,
          available_writer_slots: 2,
          maximum_writers: 2,
          available_specifier_slots: 2,
          maximum_specifiers: 2,
          available_validator_slots: 2,
          maximum_validators: 2,
          result: "PASS"
        },
        %{
          repo_key: "polaris",
          free_gb: 45.0,
          available_writer_slots: 2,
          maximum_writers: 2,
          available_specifier_slots: 2,
          maximum_specifiers: 2,
          available_validator_slots: 2,
          maximum_validators: 2,
          result: "PASS"
        }
      ],
      runs: [
        %{
          run_id: "run-1",
          issue_key: "PPL-123",
          issue_url: "https://jira.example/PPL-123",
          kind: "DELIVERY",
          state: "READY_FOR_REVIEW",
          repo_key: "grail",
          branch: "cgable/PPL-123-dashboard",
          worktree: "/tmp/PPL-123",
          workspace_state: "HIBERNATED",
          hibernated_at: "2026-09-22T19:59:00Z",
          candidate_sha: String.duplicate("a", 40),
          mr_url: "https://gitlab.example/merge_requests/123",
          mr_iid: 123,
          model: "gpt-5.6-sol",
          reasoning_effort: "high",
          implementation_iteration: 2,
          code_repair_round: 0,
          validation_repair_round: 0,
          last_error: nil,
          updated_at: "2026-09-22T20:00:00Z",
          tasks: []
        },
        %{
          run_id: "run-old",
          issue_key: "PPL-123",
          issue_url: "https://jira.example/PPL-123",
          kind: "DELIVERY",
          state: "FAILED",
          repo_key: "grail",
          branch: "cgable/PPL-123-dashboard",
          worktree: nil,
          workspace_state: "HIBERNATED",
          hibernated_at: "2026-09-22T18:59:00Z",
          candidate_sha: nil,
          mr_url: nil,
          mr_iid: nil,
          model: "gpt-5.6-sol",
          reasoning_effort: "high",
          implementation_iteration: 1,
          code_repair_round: 0,
          validation_repair_round: 0,
          last_error: "stale failure from a previous attempt",
          updated_at: "2026-09-22T19:00:00Z",
          tasks: []
        }
      ],
      tasks: [
        %{
          task_key: "run-1:change-verifier:1",
          run_id: "run-1",
          issue_key: "PPL-123",
          stage: "VERIFYING",
          role: "Change Verifier",
          status: "COMPLETED",
          thread_id: "thread-verifier",
          turn_id: "turn-verifier",
          codex_project_id: "project-grail",
          model: "gpt-5.6-sol",
          reasoning_effort: "high",
          failure_code: nil,
          updated_at: "2026-09-22T19:58:00Z"
        }
      ],
      recent_events: [
        %{
          id: 1,
          occurred_at: "2026-09-22T19:59:00Z",
          event_type: "WORKTREE_HIBERNATED",
          run_id: "run-1",
          issue_key: "PPL-123"
        }
      ]
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
