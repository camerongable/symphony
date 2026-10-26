defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint
  @disabled_factory_projection %{
    "available" => false,
    "capacity" => [],
    "counts" => %{
      "blocked" => 0,
      "by_state" => %{},
      "hibernated" => 0,
      "in_progress" => 0,
      "review_ready" => 0,
      "total_runs" => 0,
      "visible_tasks" => 0
    },
    "current_runs" => [],
    "disabled" => true,
    "enabled" => false,
    "error" => nil,
    "intake" => %{"available" => false, "count" => 0, "error" => nil, "issues" => [], "observed_at" => nil},
    "ordinary_factory_enabled" => false,
    "overview" => %{
      "active" => 0,
      "by_issue" => %{},
      "communication_attention" => 0,
      "delivery_blocked" => 0,
      "needs_attention" => 0,
      "queued" => 0,
      "review_ready" => 0
    },
    "recent_events" => [],
    "runs" => [],
    "tasks" => [],
    "ticket_supervisor_enabled" => false
  }

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
             "factory" => @disabled_factory_projection,
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
               "factory" => @disabled_factory_projection,
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
               "factory" => @disabled_factory_projection,
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
    assert html =~ "Symphony"
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
    assert html =~ "Factory scheduling: Unknown"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "scheduling-indicator"
    refute html =~ "status-cluster"

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

  test "dashboard stays usable when a factory snapshot is temporarily unavailable" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableFactoryDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot(), refresh: :unavailable)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> %{enabled: true, available: false, error: %{code: "factory_snapshot_unavailable", message: "Temporarily unavailable"}} end
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Symphony"
    send(view.pid, :payload_refresh)
    assert render(view) =~ "Symphony"
  end

  @tag unified_tickets: true
  test "unified tickets preserve classifications while filters, expansion and theme survive refresh" do
    name = Module.concat(__MODULE__, :UnifiedDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    {:ok, state} = Agent.start_link(fn -> unified_dashboard_snapshot() end)
    start_test_endpoint(orchestrator: name, factory_observability: fn -> Agent.get(state, & &1) end)
    {:ok, view, html} = live(build_conn(), "/")
    assert length(Floki.find(Floki.parse_document!(html), "[data-ticket-record]")) == 7
    assert has_element?(view, ".scheduling-indicator", "Factory scheduling: Enabled")
    assert has_element?(view, "[data-ticket-record='PPL-1'] [data-copy-suggested-prompt]")
    refute has_element?(view, "[data-ticket-record='PPL-5'] [data-copy-suggested-prompt]")
    refute has_element?(view, "[data-ticket-record='PPL-7'] [data-copy-suggested-prompt]")
    assert has_element?(view, "[data-ticket-record='PPL-1']", "Worker stopped")
    assert has_element?(view, "[data-ticket-record='PPL-3']", "Communication warning")
    refute has_element?(view, "#jira-intake-disclosure")
    assert has_element?(view, "#system-health-disclosure > .poll-observation")
    assert has_element?(view, "#runtime-diagnostics > .diagnostics-content")
    assert has_element?(view, "#factory-task-history > .diagnostics-content")
    css = response(get(build_conn(), "/dashboard.css"), 200)
    assert css =~ ~r/\.system-health > \.poll-observation,[^{]*\{ margin: 24px; \}/
    assert css =~ ~r/\.system-health > \.poll-observation,[^{]*\{ margin: 16px; \}/

    totals = html |> Floki.parse_document!() |> Floki.find(".ticket-buckets") |> Floki.text()
    render_click(view, "ticket_filter", %{"bucket" => "ACTIVE"})
    assert has_element?(view, "[data-ticket-record='PPL-5']")
    refute has_element?(view, "[data-ticket-record='PPL-1']")
    render_click(view, "workflow_details", %{"run_id" => "PPL-5"})
    render_click(view, "dashboard_theme", %{"theme" => "light"})
    send(view.pid, :observability_updated)
    assert_eventually(fn -> has_element?(view, "button[phx-value-bucket='ACTIVE'][aria-pressed='true']") end)
    assert has_element?(view, ".ticket-details:not([hidden])", "Progress")
    assert has_element?(view, ".dashboard-shell[data-theme='light']")
    assert render(view) |> Floki.parse_document!() |> Floki.find(".ticket-buckets") |> Floki.text() == totals

    Agent.update(state, fn _ -> %{available: false, enabled: true} end)
    send(view.pid, :observability_updated)
    assert_eventually(fn -> has_element?(view, "[data-snapshot-stale='true']") end)
    assert has_element?(view, "[data-ticket-record='PPL-5']")
    assert has_element?(view, ".scheduling-indicator", "Unknown")
    assert has_element?(view, ".ticket-details:not([hidden])")
  end

  @tag unified_tickets: true
  test "intake is last-polled metadata, validation is disjoint, and selected empty is explicit" do
    name = Module.concat(__MODULE__, :IntakeDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    {:ok, state} = Agent.start_link(fn -> put_in(unified_dashboard_snapshot(), [:intake, :stale], true) end)
    reader = fn -> Agent.get(state, & &1) end
    start_test_endpoint(orchestrator: name, factory_observability: reader)
    {:ok, view, _html} = live(build_conn(), "/")
    render_click(view, "ticket_filter", %{"bucket" => "QUEUED"})
    assert has_element?(view, "[data-ticket-record='PPL-2']", "Specification is required")
    assert has_element?(view, "[data-ticket-record='PPL-2']", "Intake observed")
    refute has_element?(view, "[data-ticket-record='PPL-2'] a[href^='codex:']")
    render_click(view, "workflow_details", %{"run_id" => "PPL-2"})
    assert has_element?(view, ".ticket-details:not([hidden])", "stale saved snapshot")
    render_click(view, "ticket_filter", %{"bucket" => "VALIDATION_PENDING"})
    assert has_element?(view, "[data-ticket-record='PPL-4']")
    refute has_element?(view, "[data-ticket-record='PPL-3']")
    render_click(view, "ticket_filter", %{"bucket" => "invented"})
    assert has_element?(view, "[data-ticket-record='PPL-4']")

    Agent.update(state, fn fixture ->
      fixture
      |> put_in([:overview, :by_issue, "PPL-4"], "ACTIVE")
      |> put_in([:overview, :active], 2)
      |> put_in([:overview, :validation_pending], 0)
      |> Map.update!(:current_runs, fn runs ->
        Enum.map(runs, fn run -> if run.issue_key == "PPL-4", do: %{run | state: "WRITING"}, else: run end)
      end)
    end)

    send(view.pid, :observability_updated)
    assert_eventually(fn -> has_element?(view, ".empty-state", "No tickets in Awaiting validation") end)
    refute has_element?(view, "[data-ticket-record]")
    assert has_element?(view, ".ticket-bucket[phx-value-bucket='ACTIVE']", "2")
  end

  @tag unified_tickets: true
  test "stress fixture keeps full text and errors escaped in explicit readable diagnostics" do
    name = Module.concat(__MODULE__, :StressDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot(:stress)
    start_test_endpoint(orchestrator: name, factory_observability: fn -> fixture end)
    {:ok, view, html} = live(build_conn(), "/")
    render_click(view, "workflow_details", %{"run_id" => "PPL-1"})
    [run | _] = fixture.current_runs
    document = render(view) |> Floki.parse_document!()
    assert Floki.find(document, ".ticket-details") |> Floki.text() =~ run.last_error
    assert Floki.find(document, ".ticket-details") |> Floki.text() =~ run.primary_next_action
    refute html =~ "<script>alert"
    refute has_element?(view, "a[href^='javascript:']")
    assert has_element?(view, ".raw-disclosure summary", "Full recorded error")
    assert has_element?(view, ".ticket-detail-section", "Not required")
    refute render(view) =~ "Not required · Not proven"
  end

  @tag unified_tickets: true
  test "intake errors and decisions stay visible while ambiguous workflows never highlight intake" do
    name = Module.concat(__MODULE__, :AmbiguousDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot()
    [run | _] = fixture.current_runs
    runs = fixture.current_runs ++ [%{run | state: "WRITING"}]

    runs =
      Enum.map(runs, fn current ->
        if current.issue_key == "PPL-5", do: put_in(current, [:ticket_context, :actionable_question_count], 2), else: current
      end)

    issues =
      Enum.map(fixture.intake.issues, fn issue ->
        if issue.issue_key == "PPL-2", do: Map.put(issue, :admission_error, %{code: "manual_validation_contract_missing", message: "Define the required manual validation contract."}), else: issue
      end)

    fixture = %{fixture | current_runs: runs, intake: %{fixture.intake | issues: issues}}
    start_test_endpoint(orchestrator: name, factory_observability: fn -> fixture end)
    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "[data-ticket-record='PPL-1']", "Current record unproven")
    refute has_element?(view, "[data-ticket-record='PPL-1'] .stage-map [aria-current]")
    assert has_element?(view, "[data-ticket-record='PPL-1'] .phase-unavailable", "Phase unavailable")
    refute has_element?(view, "[data-ticket-record='PPL-1'] a[href^='codex:']")
    assert has_element?(view, "[data-ticket-record='PPL-2']", "manual_validation_contract_missing")
    assert has_element?(view, "[data-ticket-record='PPL-5'] .decision-count", "2 current decision")
    render_click(view, "workflow_details", %{"run_id" => "PPL-2"})
    assert has_element?(view, ".ticket-details:not([hidden])", "Last-polled intake issue")
    assert has_element?(view, ".ticket-details:not([hidden])", "Define the required manual validation contract.")
  end

  @tag unified_tickets: true
  test "intake read failure never-polled and successful empty remain distinct without hiding workflows" do
    name = Module.concat(__MODULE__, :PartialIntakeDashboardOrchestrator)
    {:ok, _} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot()
    {:ok, state} = Agent.start_link(fn -> fixture end)
    start_test_endpoint(orchestrator: name, factory_observability: fn -> Agent.get(state, & &1) end)
    {:ok, view, _html} = live(build_conn(), "/")

    for {available, error, message, unknown} <- [
          {false, %{code: "intake_unavailable", message: "Intake read failed"}, "Intake read failed", true},
          {false, nil, "No successful Jira intake snapshot", true},
          {true, nil, "last successful poll found no factory-labelled issues", false}
        ] do
      changed = %{fixture | intake: %{fixture.intake | available: available, error: error, observed_at: nil, issues: []}}
      Agent.update(state, fn _ -> changed end)
      send(view.pid, :observability_updated)
      document = view |> render_async() |> Floki.parse_document!()
      assert Floki.find(document, ".tickets-section") |> Floki.text() =~ message
      queued = Floki.find(document, ".ticket-bucket[phx-value-bucket='QUEUED']") |> Floki.text()
      assert String.contains?(queued, "Unknown") == unknown
      assert has_element?(view, "[data-ticket-record='PPL-1']")
      assert has_element?(view, "[data-ticket-record='PPL-1'] .responsibility", "Action owner not recorded")
      assert has_element?(view, ".ticket-bucket[phx-value-bucket='REVIEW_READY']", "1")
      assert has_element?(view, "[data-intake-unavailable]") == unknown
    end
  end

  @tag unified_tickets: true
  test "seven fixed phase slots keep condition and navigation separate from phase evidence" do
    name = Module.concat(__MODULE__, :SevenPhaseDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot()
    [base | _] = fixture.current_runs

    states = [
      {"SPECIFYING", "Specify"},
      {"PLANNING", "Specify"},
      {"SPEC_DRAFTING", "Specify"},
      {"CONTRACT_DISCUSSING", "Specify"},
      {"SPEC_WRITING", "Specify"},
      {"AWAITING_JIRA_READBACK", "Specify"},
      {"SPEC_REVIEW", "Specify"},
      {"CRITIQUING", "Specify"},
      {"SPEC_READY_WRITE", "Specify"},
      {"AWAITING_CONFIRMATION", "Specify"},
      {"AWAITING_SPEC_INPUT", "Specify"},
      {"AWAITING_CONTRACT_INPUT", "Specify"},
      {"WRITING", "Build"},
      {"VERIFYING", "Verify"},
      {"PUSHING", "Publish"},
      {"CI_PUSHING", "Publish"},
      {"MR_CREATING", "Publish"},
      {"CI_MR_CREATING", "Publish"},
      {"CI_WAITING", "Validate"},
      {"AWAITING_VALIDATION", "Validate"},
      {"READY_FOR_REVIEW", "Review"},
      {"FAILED", nil},
      {"DELIVERED", nil},
      {"UNRECOGNIZED", nil}
    ]

    runs = Enum.map(states, fn {state, _phase} -> %{base | issue_key: "PHASE-#{state}", state: state} end)
    memberships = Map.new(runs, &{&1.issue_key, "ACTIVE"}) |> Map.put("PPL-2", "QUEUED")
    fixture = %{fixture | current_runs: runs, overview: %{fixture.overview | by_issue: memberships}}
    start_test_endpoint(orchestrator: name, factory_observability: fn -> fixture end)
    {:ok, view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)

    for {state, phase} <- states do
      selector = "[data-ticket-record='PHASE-#{state}']"
      slots = Floki.find(document, selector <> " .stage-map > li")
      assert Enum.map(slots, &(Floki.attribute(&1, "data-phase-slot") |> hd())) == ~w(Intake Specify Build Verify Publish Validate Review)
      current = Floki.find(document, selector <> " .stage-map [aria-current='step']")
      assert length(current) == if(phase, do: 1, else: 0)
      if phase, do: assert(Floki.text(hd(current)) == phase), else: assert(has_element?(view, selector <> " .phase-unavailable", "Phase unavailable"))
      assert has_element?(view, selector <> " .ticket-action a", "Open ticket chat")
      assert has_element?(view, selector <> " .ticket-action a", "Open MR")
      refute has_element?(view, selector <> " .ticket-links a")

      if state == "READY_FOR_REVIEW",
        do: assert(has_element?(view, selector <> " .responsibility", "Human review")),
        else: assert(has_element?(view, selector <> " .responsibility", "Action owner not recorded"))

      assert has_element?(view, selector <> " .ticket-phase", "Stopped / result recorded")
    end

    assert has_element?(view, "[data-ticket-record='PPL-2'] .stage-map [aria-current='step']", "Intake")
    assert has_element?(view, ".phase-guide", "Other positions do not prove completion")
  end

  @tag unified_tickets: true
  test "responsibility uses exact structured evidence and unknown ownership stays explicit" do
    name = Module.concat(__MODULE__, :ResponsibilityDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot()
    [base | _] = fixture.current_runs
    current = Map.put(base.ticket_context, :questions, [%{"question_key" => "question-1", "binding" => "CURRENT", "body" => "Choose", "answers" => "Yes"}])
    stale = Map.put(base.ticket_context, :questions, [%{"question_key" => "question-1", "binding" => "STALE", "body" => "Choose", "answers" => "Yes"}])

    runs = [
      %{base | issue_key: "OWNER-REVIEW", state: "READY_FOR_REVIEW"},
      %{base | issue_key: "OWNER-NO-MR", state: "READY_FOR_REVIEW", mr_url: nil},
      %{base | issue_key: "OWNER-QUESTION", state: "AWAITING_CONTRACT_INPUT", ticket_context: current},
      %{base | issue_key: "OWNER-STALE", state: "AWAITING_CONTRACT_INPUT", ticket_context: stale},
      %{base | issue_key: "OWNER-WRONG-STAGE", state: "REPAIRING", ticket_context: current},
      %{base | issue_key: "OWNER-FACTORY", state: "WRITING", worker_execution: %{status: "TURN_BOUND", running_proven: true}},
      %{base | issue_key: "OWNER-STRING", state: "WRITING", worker_execution: %{status: "TURN_BOUND", running_proven: "true"}},
      %{base | issue_key: "OWNER-PROSE", state: "FAILED", primary_next_action: "Human review; factory is running now."}
    ]

    fixture = %{fixture | current_runs: runs, overview: %{fixture.overview | by_issue: Map.new(runs, &{&1.issue_key, "NEEDS_ATTENTION"})}}
    start_test_endpoint(orchestrator: name, factory_observability: fn -> fixture end)
    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "[data-ticket-record='OWNER-REVIEW'] .responsibility", "Human review")
    assert has_element?(view, "[data-ticket-record='OWNER-QUESTION'] .responsibility", "Human decision")
    assert has_element?(view, "[data-ticket-record='OWNER-FACTORY'] .responsibility", "Factory · recorded observation, not a current heartbeat")

    for key <- ~w(OWNER-NO-MR OWNER-STALE OWNER-WRONG-STAGE OWNER-STRING OWNER-PROSE) do
      assert has_element?(view, "[data-ticket-record='#{key}'] .responsibility", "Action owner not recorded")
    end

    render_click(view, "workflow_details", %{"run_id" => "OWNER-PROSE"})
    assert has_element?(view, "[data-ticket-record='OWNER-PROSE'] .ticket-details", "Owner not recorded")
  end

  @tag unified_tickets: true
  test "queue filters remain five categories while seven phases and collapsed operations stay distinct" do
    name = Module.concat(__MODULE__, :CompactQueueDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot(:blocked)
    start_test_endpoint(orchestrator: name, factory_observability: fn -> fixture end)
    {:ok, view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    assert length(Floki.find(document, ".ticket-buckets .ticket-bucket")) == 5
    assert Enum.map(Floki.find(document, ".ticket-buckets .ticket-bucket"), &(Floki.attribute(&1, "phx-value-bucket") |> hd())) == ~w(NEEDS_ATTENTION ACTIVE QUEUED VALIDATION_PENDING REVIEW_READY)
    assert has_element?(view, ".queue-guide", "Five queue filters")
    assert has_element?(view, ".phase-guide", "Seven lifecycle phases")
    assert has_element?(view, "#operations-history #system-health-disclosure > summary small", "Factory control, last tick, broker and machine observations")
    assert has_element?(view, "#operations-history #system-health-disclosure .disclosure-closed-label", "Show health")
    assert has_element?(view, "#operations-history #factory-task-history .disclosure-closed-label", "Show history")
    assert has_element?(view, "#operations-history #runtime-diagnostics .disclosure-closed-label", "Show runtime")
    assert Floki.find(document, "#operations-history details[open]") == []
    assert has_element?(view, ".factory-alert", "Scheduling handoff needs attention")
    refute has_element?(view, "#operations-history .factory-alert")
    assert has_element?(view, ".current-phase-label", "Build")
  end

  @tag unified_tickets: true
  test "copy suggested prompt is available only for explicit typed metadata paired with a chat" do
    name = Module.concat(__MODULE__, :SuggestedPromptDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = unified_dashboard_snapshot()
    [base | _] = fixture.current_runs
    prompt = "Rework the current candidate.\r\n"
    typed = Map.put(base.ticket_context, :suggested_prompt, %{kind: "TICKET_CHAT_SUGGESTED_PROMPT_V1", body: prompt})
    wrong = Map.put(base.ticket_context, :suggested_prompt, %{kind: "FREE_TEXT", body: prompt})
    no_chat = Map.put(typed, :parent_thread_id, nil)

    runs = [
      %{base | issue_key: "PROMPT-TYPED", ticket_context: typed},
      %{base | issue_key: "PROMPT-WRONG", ticket_context: wrong},
      %{base | issue_key: "PROMPT-NO-CHAT", ticket_context: no_chat},
      %{base | issue_key: "PROMPT-PROSE", primary_next_action: prompt, ticket_context: Map.delete(base.ticket_context, :suggested_prompt)}
    ]

    fixture = %{fixture | current_runs: runs, overview: %{fixture.overview | by_issue: Map.new(runs, &{&1.issue_key, "NEEDS_ATTENTION"})}}
    start_test_endpoint(orchestrator: name, factory_observability: fn -> fixture end)
    {:ok, view, html} = live(build_conn(), "/")
    [button] = Floki.find(Floki.parse_document!(html), "[data-ticket-record='PROMPT-TYPED'] [data-copy-suggested-prompt]")
    assert Floki.attribute(button, "data-prompt-base64") == [Base.encode64(prompt)]
    assert has_element?(view, "[data-ticket-record='PROMPT-TYPED'] .suggested-prompt-actions a", "Open ticket chat")
    assert has_element?(view, "[data-ticket-record='PROMPT-TYPED'] .copy-note", "Copy does not send")
    for key <- ~w(PROMPT-WRONG PROMPT-NO-CHAT PROMPT-PROSE), do: refute(has_element?(view, "[data-ticket-record='#{key}'] [data-copy-suggested-prompt]"))
  end

  @tag unified_tickets: true
  test "export synthetic unified fixture renders without a factory store or live endpoint" do
    name = Module.concat(__MODULE__, :ExportDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    {:ok, mode} = Agent.start_link(fn -> :mixed end)
    start_test_endpoint(orchestrator: name, factory_observability: fn -> unified_dashboard_snapshot(Agent.get(mode, & &1)) end)
    {:ok, view, _html} = live(build_conn(), "/")

    for sample <- [:mixed, :stress, :blocked, :unknown, :stale] do
      Agent.update(mode, fn _ -> sample end)
      send(view.pid, :observability_updated)

      assert_eventually(fn ->
        case sample do
          :stress -> has_element?(view, "[data-ticket-record='PPL-1'] h3", "Very long")
          :blocked -> has_element?(view, ".scheduling-indicator", "Needs attention")
          :unknown -> has_element?(view, ".scheduling-indicator", "Unknown")
          :stale -> has_element?(view, ".scheduling-indicator", "Stale")
          :mixed -> has_element?(view, "[data-ticket-record='PPL-1'] h3", "Restore versioned")
        end
      end)

      if output = System.get_env("SYMPHONY_SYNTHETIC_PREVIEW_OUTPUT") do
        File.write!(Path.join(output, "#{sample}-rendered.html"), render(view))
      end
    end
  end

  @tag dashboard_preview: true
  test "ticket summary keeps details closed, links independent, and expansion through refresh" do
    name = Module.concat(__MODULE__, :CompactDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)

    start_test_endpoint(orchestrator: name, factory_observability: &factory_dashboard_snapshot/0)
    {:ok, view, html} = live(build_conn(), "/")
    assert has_element?(view, "#ticket-UFBMLTEyMw[hidden]")
    assert has_element?(view, ~s(button[aria-controls="ticket-UFBMLTEyMw"][aria-expanded="false"]))
    assert has_element?(view, ~s([data-ticket-record="PPL-123"] .stage-map [aria-current="step"]), "Review")
    assert length(Floki.find(Floki.parse_document!(html), "[data-ticket-record='PPL-123'] .stage-map [aria-current]")) == 1
    assert has_element?(view, ".workflow-summary a[href='codex://threads/parent-ticket']:not([phx-click])")
    refute has_element?(view, "#jira-intake-disclosure")
    assert has_element?(view, "#system-health-disclosure:not([open])")

    view |> element("[data-ticket-record='PPL-123'] .workflow-disclosure") |> render_click()
    refute has_element?(view, "#ticket-UFBMLTEyMw[hidden]")
    send(view.pid, :observability_updated)
    assert_eventually(fn -> has_element?(view, ~s(button[aria-expanded="true"])) end)
    refute has_element?(view, "#ticket-UFBMLTEyMw[hidden]")
    render_click(view, "workflow_details", %{"run_id" => "foreign"})
    assert has_element?(view, ~s(button[aria-expanded="true"]))

    render_click(view, "dashboard_theme", %{"theme" => "light"})
    assert has_element?(view, ~s(.dashboard-shell[data-theme="light"]))
    assert has_element?(view, ~s(button[phx-value-theme="light"][aria-pressed="true"]))
    send(view.pid, :observability_updated)
    assert_eventually(fn -> has_element?(view, ~s(.dashboard-shell[data-theme="light"])) end)
    render_click(view, "dashboard_theme", %{"theme" => "forged"})
    assert has_element?(view, ~s(.dashboard-shell[data-theme="light"]))
    render_click(view, "dashboard_theme", %{"theme" => "dark"})
    assert has_element?(view, ~s(.dashboard-shell[data-theme="dark"]))

    if output = System.get_env("SYMPHONY_SYNTHETIC_PREVIEW_OUTPUT") do
      view |> element("[data-ticket-record='PPL-123'] .workflow-disclosure") |> render_click()
      File.write!(Path.join(output, "rendered.html"), render(view))
    end
  end

  @tag dashboard_preview: true
  test "unknown stage never paints inferred completion" do
    name = Module.concat(__MODULE__, :UnknownStageDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    factory = factory_dashboard_snapshot()
    [run | _] = factory.runs
    factory = %{factory | current_runs: [%{run | state: "UNRECOGNIZED_STAGE"}]}
    start_test_endpoint(orchestrator: name, factory_observability: fn -> factory end)
    {:ok, view, _html} = live(build_conn(), "/")
    refute has_element?(view, "[data-ticket-record='PPL-123'] .stage-map [aria-current]")
    assert has_element?(view, ".phase-unavailable", "Phase unavailable")
  end

  @tag dashboard_preview: true
  test "blocked repair exposes its recorded blocker and next action without opening diagnostics" do
    name = Module.concat(__MODULE__, :BlockedRepairDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    factory = factory_dashboard_snapshot()
    [run | _] = factory.runs

    run =
      run
      |> Map.put(:state, "REPAIRING")
      |> Map.put(:summary, "Restore versioned extraction logging and remove unrelated workflow changes")
      |> Map.put(:attention, %{
        blocking: true,
        source: "WORKER",
        phase: "BLOCKED",
        reason: "Recorded source result is blocked; no worker is running.",
        next_action: "Resolve the recorded findings in the ticket chat.",
        evidence_at: "2026-09-22T20:00:00Z",
        request_key: "sample-worker"
      })
      |> Map.put(:primary_next_action, "Resolve the recorded findings in the ticket chat.")
      |> Map.put(:worker_execution, %{status: "STOPPED", turn_id: nil, reason: "Recorded result; owner stopped."})

    context = %{
      run.ticket_context
      | source_stage: "REPAIRING",
        candidate_sha: run.candidate_sha,
        next_action: run.primary_next_action,
        validation: %{required: false, status: "NOT_REQUIRED", publication: "NOT_PROVEN_BY_VALIDATOR_OUTPUT"}
    }

    run = %{run | ticket_context: context}

    factory = %{factory | current_runs: [run], control: %{factory.control | controller_writer_conflict_count: 0}}

    overview = %{
      active: 0,
      queued: 1,
      review_ready: 0,
      needs_attention: 1,
      delivery_blocked: 1,
      by_issue: %{"PPL-123" => "NEEDS_ATTENTION"}
    }

    factory = put_in(factory, [:overview], overview)
    start_test_endpoint(orchestrator: name, factory_observability: fn -> factory end)
    {:ok, view, html} = live(build_conn(), "/")
    assert has_element?(view, "#ticket-UFBMLTEyMw[hidden]")
    assert has_element?(view, ".workflow-summary", "Recorded source result is blocked")
    assert has_element?(view, ".workflow-summary", "Resolve the recorded findings")
    assert has_element?(view, ".workflow-summary", "Stopped / result recorded")
    assert has_element?(view, ".workflow-summary .stage-map [aria-current='step']", "Build")
    summary = html |> Floki.parse_document!() |> Floki.find(".workflow-summary") |> Floki.text()
    refute summary =~ String.duplicate("a", 40)
    refute html =~ "Review the draft merge request."
    assert has_element?(view, "[data-source-stage='PPL-123']", "Repairing")

    if output = System.get_env("SYMPHONY_SYNTHETIC_PREVIEW_OUTPUT") do
      File.write!(Path.join(output, "blocked-rendered.html"), render(view))
    end
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
    assert html =~ "Tickets"
    assert html =~ "Scheduler needs attention"
    assert html =~ "Intake backlog"
    assert html =~ "last poll"
    assert html =~ "2 identifiable tickets"
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
    assert html =~ "Open ticket chat"
    assert html =~ "Saved context stage"
    assert html =~ "attributed_usage"
    assert html =~ "Manual validation"
    refute html =~ "Not required · Not proven"
    assert html =~ "codex://threads/parent-ticket"

    document = Floki.parse_document!(html)
    capacity = Floki.find(document, ".capacity-card")
    assert length(Floki.find(capacity, "tbody tr")) == 1
    assert Floki.text(capacity, sep: " ") =~ "All repositories"
    assert Floki.text(capacity, sep: " ") =~ "grail"
    assert Floki.text(capacity, sep: " ") =~ "polaris"
    assert Floki.text(Floki.find(document, ".capacity-card"), sep: " ") =~ "Available"
    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="stopped"])) != []

    workflows = Floki.find(document, ".runs-section")
    assert length(Floki.find(workflows, ".workflow-summary")) == 2
    refute Floki.text(workflows, sep: " ") =~ "stale failure from a previous attempt"
    assert Floki.find(workflows, ~s(td[data-label="Progress"] .state-badge)) == []
    assert Floki.text(Floki.find(workflows, ".ticket-facts"), sep: " ") =~ "Worktree hibernated"

    task_history = Floki.find(document, ".factory-task-history")

    assert Floki.find(task_history, ~s(th)) |> Enum.map(&Floki.text/1) ==
             ["Issue", "Role", "Status", "Model", "Failure", "Codex task", "Updated"]

    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["factory"]["control"]["status"] == "ACTIVE"
    assert state["factory"]["control"]["controller_writer_conflict_count"] == 2
    assert state["factory"]["intake"]["count"] == 1
    assert state["factory"]["counts"]["hibernated"] == 1
    assert hd(state["factory"]["tasks"])["thread_id"] == "thread-verifier"
    [projected_run | _] = state["factory"]["runs"]
    assert projected_run["ticket_context"]["codex_thread_url"] == "codex://threads/parent-ticket"
    assert projected_run["ticket_context"]["candidate_sha"] == String.duplicate("b", 40)
    assert projected_run["ticket_context"]["synchronization"]["status"] == "PENDING"
  end

  test "dashboard makes the disabled factory distinct from an unavailable snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :DisabledFactoryDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn ->
        %{
          enabled: false,
          ordinary_factory_enabled: false,
          ticket_supervisor_enabled: false,
          disabled: true,
          available: false,
          error: nil,
          runs: [],
          current_runs: [],
          tasks: [],
          recent_events: [],
          counts: %{},
          overview: %{},
          intake: %{},
          capacity: []
        }
      end
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Factory disabled"
    assert html =~ "Ordinary factory: disabled · Ticket supervisor: disabled (defaults to disabled)."
    refute html =~ "Factory snapshot unavailable"
    state = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state["factory"]["disabled"]
    refute state["factory"]["enabled"]
    refute state["factory"]["ordinary_factory_enabled"]
    refute state["factory"]["ticket_supervisor_enabled"]
  end

  test "parent synchronization lag does not change candidate or delivery facts" do
    orchestrator_name = Module.concat(__MODULE__, :TicketParentSyncOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot(), refresh: :unavailable)

    sync_status = start_supervised!({Agent, fn -> "PENDING" end})

    ticket_context = %{
      available: true,
      parent_thread_id: "parent-ticket",
      codex_thread_url: "codex://threads/parent-ticket",
      source_stage: "VERIFYING",
      candidate_sha: String.duplicate("b", 40),
      contract_revision: "r4",
      ci: %{checked_at: "2026-10-08T12:00:00Z", artifact: %{availability: "AVAILABLE"}},
      validation: %{required: 0, status: "PASSED", publication: "NOT_PROVEN_BY_VALIDATOR_OUTPUT"},
      questions: [%{"question_key" => "q1", "binding" => "CURRENT", "body" => %{availability: "AVAILABLE"}, "answers" => %{availability: "NOT_RECORDED"}}],
      actionable_question_count: 1,
      next_action: "Review the draft merge request.",
      attributed_usage: %{status: "UNKNOWN", tokens: nil, cost: nil},
      synchronization: %{status: "PENDING", request: %{"status" => "PENDING"}}
    }

    factory_snapshot = put_in(factory_dashboard_snapshot(), [:current_runs, Access.at(0), :ticket_context], ticket_context)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn ->
        status = Agent.get(sync_status, & &1)
        put_in(factory_snapshot, [:current_runs, Access.at(0), :ticket_context, :synchronization, :status], status)
      end
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Open ticket chat"
    assert html =~ "codex://threads/parent-ticket"
    assert Floki.text(Floki.find(Floki.parse_document!(html), ".raw-disclosure")) =~ "PENDING"
    assert html =~ String.duplicate("b", 40)
    assert html =~ "2026-10-08T12:00:00Z"
    assert html =~ "Manual validation"
    assert html =~ "1 current decision(s) need an answer"
    assert html =~ "Decision q1 · CURRENT"
    assert html =~ "attributed_usage"
    state_before = json_response(get(build_conn(), "/api/v1/state"), 200)["factory"]["current_runs"] |> hd() |> Map.fetch!("ticket_context")
    assert state_before["candidate_sha"] == String.duplicate("b", 40)
    assert state_before["source_stage"] == "VERIFYING"
    assert state_before["next_action"] == "Review the draft merge request."
    assert state_before["synchronization"]["status"] == "PENDING"
    assert state_before["validation"]["required"] == 0

    Agent.update(sync_status, fn _ -> "FAILED" end)
    SymphonyElixir.StatusDashboard.notify_update()
    assert_eventually(fn -> render(view) |> Floki.parse_document!() |> Floki.find(".raw-disclosure") |> Floki.text() =~ "FAILED" end)

    state_after = json_response(get(build_conn(), "/api/v1/state"), 200)["factory"]["current_runs"] |> hd() |> Map.fetch!("ticket_context")
    assert state_after["synchronization"]["status"] == "FAILED"

    assert Map.take(state_after, ["candidate_sha", "source_stage", "next_action", "ci", "validation"]) ==
             Map.take(state_before, ["candidate_sha", "source_stage", "next_action", "ci", "validation"])
  end

  test "dashboard reports a run-local missing parent context without failing delivery rendering" do
    orchestrator_name = Module.concat(__MODULE__, :MissingTicketParentOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot(), refresh: :unavailable)

    missing_context = %{
      available: false,
      error: "ticket parent not bound",
      parent_thread_id: nil,
      source_stage: "READY_FOR_REVIEW",
      next_action: nil,
      questions: [],
      synchronization: %{status: "UNKNOWN"}
    }

    factory_snapshot = put_in(factory_dashboard_snapshot(), [:current_runs, Access.at(0), :ticket_context], missing_context)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50,
      factory_observability: fn -> factory_snapshot end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "ticket parent not bound"
    assert html =~ "Open MR"
    refute html =~ "Open ticket chat"
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

    assert html =~ "Dashboard transport connected"
    assert html =~ "Jira metadata is a stale saved snapshot."
    assert html =~ "Factory BEAM artifact fingerprint"

    document = Floki.parse_document!(html)
    intake = Floki.find(document, "[data-ticket-record='PPL-9723']")
    assert Floki.text(Floki.find(document, ".scheduling-indicator")) =~ "Paused — existing work may continue"
    assert Floki.find(document, ".scheduling-indicator .mark-ready") == []
    assert Floki.text(Floki.find(document, ".capacity-card")) =~ "Available"

    assert document
           |> Floki.find(".factory-controller .section-header > .state-badge-danger")
           |> Floki.text()
           |> String.trim() == "Paused"

    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="stopped"])) != []
    assert Floki.find(intake, ".state-badge-active") == []
    assert Floki.find(document, ".poll-observation time") != []
    assert Floki.text(Floki.find(intake, ".ticket-facts")) =~ "Specification"
    assert Floki.text(Floki.find(intake, ".ticket-facts")) =~ "repo-grail"
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

  test "saved blocked intake is rendered with its exact controller rejection in dashboard and API" do
    alias SymphonyElixir.Factory.{ControlServer, IntakeLedger, Observability, Store}
    database = Path.join(System.tmp_dir!(), "blocked-intake-ui-#{System.unique_integer([:positive])}.sqlite")
    store = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)

    factory = %{
      enabled: true,
      scope: "blocked-intake-ui",
      dispatcher_id: "ui-test",
      lease_seconds: 240,
      repositories: %{"grail" => %{"path" => "/tmp/grail", "base_branch" => "main", "route_labels" => ["repo-grail"]}}
    }

    control = start_supervised!({ControlServer, store: store, factory: factory, name: nil})
    snapshot = %{"key" => "PPL-264", "summary" => "Invalid contract", "status" => "To Do", "labels" => ["ai-ready", "repo-grail"]}
    assert {:ok, saved} = IntakeLedger.replace(store, factory.scope, [snapshot])
    assert :ok = IntakeLedger.record_blocked(store, factory.scope, snapshot, saved.observed_at, :manual_validation_contract_missing)
    projection = Observability.snapshot(settings: %{factory: factory}, store: store, control_server: control)
    assert projection.available
    fixture = factory_dashboard_snapshot() |> Map.put(:intake, projection.intake) |> Map.put(:overview, projection.overview)
    name = Module.concat(__MODULE__, :BlockedIntakeDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, factory_observability: fn -> fixture end)
    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    blocker = Floki.find(document, ~s([data-intake-blocker="PPL-264"]))
    assert Floki.text(blocker) =~ "manual_validation_contract_missing"
    assert Floki.text(blocker) =~ "must explicitly declare"
    assert Floki.text(Floki.find(document, "[data-ticket-record='PPL-264']")) =~ "Needs attention"
    payload = get(build_conn(), "/api/v1/state") |> json_response(200)
    assert [%{"local_state" => "INTAKE_BLOCKED", "admission_error" => %{"code" => "manual_validation_contract_missing"}}] = payload["factory"]["intake"]["issues"]
    assert payload["factory"]["overview"]["needs_attention"] == 1
  end

  test "scheduler tick failure overrides active service status in the dashboard and API" do
    name = Module.concat(__MODULE__, :FailedTickDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)

    health = %{
      status: "FAILED",
      last_error: "UndefinedFunctionError",
      consecutive_failures: 3,
      last_success_at: nil,
      last_started_at: nil,
      last_completed_at: nil
    }

    factory =
      factory_dashboard_snapshot()
      |> put_in([:control, :status], "ACTIVE")
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :tick_health], health)

    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, factory_observability: fn -> factory end)
    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    assert Floki.text(Floki.find(document, ".scheduling-indicator")) =~ "Needs attention"
    assert Floki.text(Floki.find(document, ".scheduler-tick-error")) =~ "queued tickets may not advance"
    assert html =~ "Last successful tick"
    assert html =~ "Consecutive tick failures"
    refute Floki.text(Floki.find(document, ".scheduling-indicator")) =~ "Factory scheduling: Enabled"
    payload = get(build_conn(), "/api/v1/state") |> json_response(200)
    assert payload["factory"]["control"]["tick_health"]["status"] == "FAILED"
    assert payload["factory"]["control"]["status"] == "ACTIVE"
  end

  test "workflow uncertainty stays visible while scheduler health remains healthy" do
    name = Module.concat(__MODULE__, :UncertainOperationDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    fixture = factory_dashboard_snapshot()
    base = hd(fixture.runs)

    attention = %{
      source: "PUSH",
      phase: "PUSH_UNCERTAIN",
      request_key: "push-exact",
      reason: "Push outcome is not confirmed.",
      evidence_at: "2026-10-13T20:00:00Z",
      next_action: "Reconcile the existing push before retrying."
    }

    run = Map.merge(base, %{issue_key: "PPL-9881", state: "CI_PUSHING", attention: attention})

    factory =
      fixture
      |> Map.put(:runs, [run])
      |> Map.put(:current_runs, [run])
      |> Map.put(:overview, %{active: 0, queued: 0, review_ready: 0, needs_attention: 1, by_issue: %{"PPL-9881" => "NEEDS_ATTENTION"}})
      |> put_in([:control, :status], "ACTIVE")
      |> put_in([:control, :controller_writer_conflict_count], 0)
      |> put_in([:control, :tick_health], %{status: "HEALTHY", consecutive_failures: 0, last_error: nil, last_success_at: "2026-10-13T23:59:00Z"})
      |> put_in([:control, :handoff_attention], %{
        source: "CONTROLLER",
        phase: "FAILED",
        request_key: "controller-exact",
        reason: "provider_quota_exceeded",
        evidence_at: "2026-10-13T23:58:00Z",
        next_action: "Reconcile the existing controller handoff."
      })

    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, factory_observability: fn -> factory end)
    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    progress = Floki.find(document, ~s([data-workflow-attention="PPL-9881"])) |> Floki.text(sep: " ")
    assert progress =~ "Push uncertain"
    assert progress =~ "not confirmed"
    assert html =~ "Reconcile the existing push"
    assert Floki.find(document, ".raw-disclosure") |> Floki.text() =~ "2026-10-13T20:00:00Z"
    assert Floki.find(document, ".raw-disclosure") |> Floki.text() =~ "push-exact"
    assert Floki.find(document, ".ticket-bucket-label") |> Floki.text() =~ "Needs attention"
    assert Floki.find(document, ".scheduling-indicator") |> Floki.text() =~ "Needs attention"
    assert Floki.find(document, "[data-controller-attention]") |> Floki.text() =~ "provider_quota_exceeded"
    assert Floki.find(document, "[role='alert']") |> Floki.text() =~ "Scheduling handoff needs attention"
    assert html =~ "BEAM process started (runtime-derived)"
    assert html =~ "Control server started"
    assert html =~ "not deployment proof"
    payload = get(build_conn(), "/api/v1/state") |> json_response(200)
    assert payload["factory"]["overview"]["needs_attention"] == 1
    assert hd(payload["factory"]["current_runs"])["attention"]["phase"] == "PUSH_UNCERTAIN"
  end

  @tag dashboard_truth: true
  test "repair stage and waiting execution are separate from terminal controller history and stale ticks" do
    name = Module.concat(__MODULE__, :TruthfulExecutionDashboard)
    {:ok, _} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    factory = factory_dashboard_snapshot()

    run =
      hd(factory.runs)
      |> Map.merge(%{
        state: "REPAIRING",
        implementation_iteration: 20,
        implementation_iteration_limit: 20,
        ci_repair_attempts_used: 9,
        ci_repair_attempt_limit: 10,
        worker_execution: %{status: "WAITING", thread_id: nil, turn_id: nil}
      })

    history = %{
      phase: "FAILED",
      recorded_phase: "FAILED",
      category: "HISTORY",
      blocking: false,
      request_key: "old-failed",
      reason: "Original terminal error",
      evidence_at: nil,
      next_action: "Not proof of recovery; do not resend."
    }

    factory = factory |> Map.put(:runs, [run]) |> Map.put(:current_runs, [run]) |> put_in([:control, :handoff_attention], history)
    factory = put_in(factory, [:control, :tick_observation], %{status: "STALE"})
    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, factory_observability: fn -> factory end)
    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    assert Floki.find(document, "[data-source-stage]") |> Floki.text() =~ "Repairing"
    assert Floki.find(document, "[data-implementation-iterations]") |> Floki.text() =~ "20/20"
    assert Floki.find(document, "[data-ci-repair-attempts]") |> Floki.text() =~ "9/10"
    assert Floki.find(document, "[data-worker-execution]") |> Floki.text() =~ "Waiting for worker; no current native turn recorded"
    assert Floki.find(document, "[data-controller-history]") |> Floki.text() =~ "Original terminal error"
    assert Floki.find(document, "[data-controller-attention]") == []
    assert Floki.find(document, "[data-tick-observation]") |> Floki.text() =~ "Stale"
    payload = get(build_conn(), "/api/v1/state") |> json_response(200)
    assert hd(payload["factory"]["current_runs"])["worker_execution"]["status"] == "WAITING"
    assert payload["factory"]["control"]["handoff_attention"]["phase"] == "FAILED"
  end

  test "ready delivery and current parent synchronization attention coexist in API and visible counters" do
    alias SymphonyElixir.Factory.{ControlServer, Observability, RunLedger, Store}
    database = Path.join(System.tmp_dir!(), "dashboard-parent-ready-#{System.unique_integer([:positive])}.sqlite")
    store = start_supervised!({Store, database: database})
    on_exit(fn -> File.rm(database) end)
    factory = %{enabled: true, scope: "fixture-parent-ready", dispatcher_id: "fixture", lease_seconds: 240, repositories: %{}}
    control = start_supervised!({ControlServer, store: store, factory: factory, name: nil})

    {:ok, _} =
      RunLedger.register(store, %{
        run_id: "ready-parent",
        issue_key: "PPL-9881",
        kind: "DELIVERY",
        state: "READY_FOR_REVIEW",
        repo_key: "grail",
        mr_url: "https://gitlab.example/group/repo/-/merge_requests/1"
      })

    Store.query!(
      store,
      "INSERT INTO ticket_chats(chat_key,scope_key,issue_id,issue_key,repo_key,route,generation,create_request_key,directory_name,cwd,model,reasoning_effort,context_sequence,presentation_request_key,created_at,updated_at) VALUES ('ready-chat','fixture-parent-ready','issue','PPL-9881','grail','desktop_owned_ticket_chat_v1',1,'create-exact','fixture-ready-parent','/fixture/parent','gpt-6-sol','high',1,'ready-notice','2026-10-13T20:00:00Z','2026-10-13T20:00:00Z')"
    )

    Store.query!(store, "INSERT INTO ticket_chat_runs(run_id,chat_key,created_at) VALUES ('ready-parent','ready-chat','2026-10-13T20:00:00Z')")
    Store.query!(store, "UPDATE ticket_chats SET thread_id = 'parent-thread' WHERE chat_key = 'ready-chat'")

    chat = Store.one!(store, "SELECT * FROM ticket_chats WHERE chat_key = 'ready-chat'")

    assert {:ok, _} =
             SymphonyElixir.Factory.DesktopRequest.enqueue(store, %{
               request_key: "ready-notice",
               target_kind: "TICKET_CHAT",
               target_key: "ready-chat",
               action: "FOLLOWUP",
               codex_project_id: nil,
               model: "gpt-6-sol",
               reasoning_effort: "high",
               existing_thread_id: "parent-thread",
               title: "fixture",
               prompt: "Controller-observed AS-OF presentation only; not human input or source authority.",
               schema: %{type: "object", properties: %{acknowledged: %{type: "boolean"}}, required: ["acknowledged"], additionalProperties: false},
               cwd: "/fixture/parent",
               metadata: SymphonyElixir.Factory.TicketChat.request_metadata(chat)
             })

    Store.query!(
      store,
      "UPDATE desktop_requests SET status = 'FOLLOWUP_UNCERTAIN', claimed_at = '2026-10-13T20:00:00Z', created_at = '2026-10-13T20:00:00Z', updated_at = '2026-10-13T20:00:00Z' WHERE request_key = 'ready-notice'"
    )

    projection = Observability.snapshot(settings: %{factory: factory}, store: store, control_server: control, now: ~U[2026-10-14 00:00:00Z])
    assert projection.overview.review_ready == 1
    assert projection.overview.needs_attention == 0
    name = Module.concat(__MODULE__, :ReadyParentDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    projection_state = start_supervised!({Agent, fn -> projection end})
    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, factory_observability: fn -> Agent.get(projection_state, & &1) end)
    {:ok, view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    assert Floki.find(document, ".ticket-bucket-label") |> Floki.text() =~ "Ready for review"
    assert html =~ "Communication warning recorded; not a delivery blocker."
    counters = Floki.find(document, ".ticket-buckets .ticket-bucket") |> Enum.map(&Floki.text(&1, sep: " "))
    assert Enum.any?(counters, &String.contains?(&1, "Ready for review 1"))
    assert Enum.any?(counters, &String.contains?(&1, "Needs attention 0"))
    payload = get(build_conn(), "/api/v1/state") |> json_response(200)
    assert payload["factory"]["overview"]["review_ready"] == 1
    assert payload["factory"]["overview"]["needs_attention"] == 0
    assert payload["factory"]["overview"]["delivery_blocked"] == 0
    assert payload["factory"]["overview"]["communication_attention"] == 1
    assert Floki.find(document, "[data-workflow-secondary]") |> Enum.all?(fn {_tag, attributes, _children} -> not Enum.any?(attributes, fn {key, _} -> key == "open" end) end)
    assert Floki.find(document, ".ticket-action") |> Floki.text() =~ "Review the recorded draft MR"

    sha = String.duplicate("a", 40)

    evidence = %{
      "status" => "BLOCK",
      "sha" => sha,
      "iid" => 1,
      "mr_url" => "https://gitlab.example/group/repo/-/merge_requests/1",
      "pipeline_id" => 99,
      "pipeline_sha" => sha,
      "pipeline_ref" => "refs/merge-requests/1/head",
      "pipeline_source" => "merge_request_event",
      "pipeline_url" => "https://gitlab.example/group/repo/-/pipelines/99",
      "source_binding" => %{"kind" => "HEAD", "candidate_sha" => sha},
      "failed_jobs" => [%{"name" => "bazel", "status" => "failed", "web_url" => "https://gitlab.example/group/repo/-/jobs/100"}]
    }

    {:ok, _} =
      RunLedger.update(store, "ready-parent", %{
        state: "CI_WAITING",
        candidate_sha: sha,
        ci_preflight_sha: sha,
        ci_pipeline_id: 99,
        ci_pipeline_url: evidence["pipeline_url"],
        mr_iid: 1,
        ci_evidence_json: Jason.encode!(evidence)
      })

    blocked = Observability.snapshot(settings: %{factory: factory}, store: store, control_server: control, now: ~U[2026-10-14 00:00:00Z])
    Agent.update(projection_state, fn _ -> blocked end)
    send(view.pid, :payload_refresh)
    blocked_document = view |> render_async() |> Floki.parse_document!()
    assert Floki.find(blocked_document, ".ticket-details a") |> Floki.attribute("href") |> Enum.member?(evidence["pipeline_url"])
    assert Floki.find(blocked_document, ".ticket-details a") |> Floki.attribute("href") |> Enum.member?("https://gitlab.example/group/repo/-/jobs/100")
    assert Floki.find(blocked_document, ".ticket-action") |> Floki.text() =~ "independent verification remains gated"
    assert Floki.find(blocked_document, "[data-source-stage]") |> Floki.text() =~ "CI waiting"
    assert Floki.find(blocked_document, ".recorded-warning") |> Floki.text() =~ "Followup uncertain"
    projected_attempts = Map.update!(blocked, :current_runs, fn runs -> Enum.map(runs, &Map.merge(&1, %{ci_repair_attempts_used: 4, ci_repair_attempt_limit: 5, code_repair_round: 3})) end)
    Agent.update(projection_state, fn _ -> projected_attempts end)
    send(view.pid, :payload_refresh)
    attempts_document = view |> render_async() |> Floki.parse_document!()
    assert Floki.find(attempts_document, "[data-ci-repair-attempts]") |> Floki.text() =~ "4/5"
  end

  test "a hung dashboard refresh times out without overlap, marks last good data stale and recovers" do
    name = Module.concat(__MODULE__, :HungDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)
    mode = start_supervised!({Agent, fn -> :healthy end})
    parent = self()
    fixture = factory_dashboard_snapshot() |> put_in([:control, :status], "ACTIVE") |> put_in([:control, :controller_writer_conflict_count], 0)

    reader = fn ->
      if Agent.get(mode, & &1) == :blocked do
        send(parent, {:snapshot_reader_started, self()})

        receive do
          :release -> fixture
        end
      else
        fixture
      end
    end

    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, dashboard_refresh_timeout_ms: 75, factory_observability: reader)
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "dashboard-observed-at"
    Agent.update(mode, fn _ -> :blocked end)
    send(view.pid, :payload_refresh)
    assert_receive {:snapshot_reader_started, reader_pid}
    send(view.pid, :observability_updated)
    refute_receive {:snapshot_reader_started, _}, 100
    stale = render(view)
    assert stale =~ "Dashboard data stale"
    assert stale =~ "last known, not current"
    assert stale =~ "Unknown — snapshot stale"
    refute Process.alive?(reader_pid)
    assert Process.alive?(view.pid)
    state = :sys.get_state(view.pid)
    assert {:noreply, unchanged} = SymphonyElixirWeb.DashboardLive.handle_async({:snapshot, make_ref()}, {:ok, %{error: %{message: "old result"}}}, state.socket)
    assert unchanged == state.socket
    Agent.update(mode, fn _ -> :healthy end)
    send(view.pid, :payload_refresh)
    recovered = render_async(view)
    refute recovered =~ "Dashboard data stale"
    assert recovered =~ "Factory scheduling: Enabled"
  end

  test "an initial hung snapshot shows unknown counts without claiming healthy scheduler data" do
    name = Module.concat(__MODULE__, :InitialHungDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: static_snapshot(), refresh: :unavailable)

    start_test_endpoint(
      orchestrator: name,
      snapshot_timeout_ms: 50,
      dashboard_refresh_timeout_ms: 25,
      factory_observability: fn ->
        receive do
          :release -> nil
        end
      end
    )

    {:ok, view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    assert Floki.find(document, ".overview-grid .metric-value") == []
    assert html =~ "Ticket counts unknown"
    assert html =~ "Dashboard data stale"
    refute html =~ "Factory scheduling: Enabled"
    assert Process.alive?(view.pid)
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
      |> put_in([:current_runs, Access.at(0), :workspace_state], "MATERIALIZED")
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
    assert Floki.text(Floki.find(document, ".scheduling-indicator")) =~ "Factory scheduling: Enabled"
    assert Floki.find(document, ".scheduling-indicator .mark-ready") != []
    assert Floki.text(Floki.find(document, ".capacity-card .state-badge-warning")) =~ "Limited"

    assert Floki.text(Floki.find(document, ".ticket-facts"), sep: " ") =~
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

    assert Floki.text(Floki.find(document, ".scheduling-indicator"), sep: " ") =~ "Factory scheduling: Enabled"
    assert Floki.text(Floki.find(document, ".broker-card"), sep: " ") =~ "Pending"
    assert Floki.find(document, ".scheduling-indicator .mark-ready") != []
    assert Floki.find(document, ".scheduling-indicator .mark-attention") == []

    broker = Floki.find(document, ".broker-card")
    assert Floki.text(broker, sep: " ") =~ "Desktop Broker"
    assert Floki.text(broker, sep: " ") =~ "Automation heartbeat is not measured here"
    assert Floki.text(broker, sep: " ") =~ "Pending 2"
    assert Floki.text(broker, sep: " ") =~ "Claimed / unverified (not worker activity) 0"
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
    assert Floki.text(Floki.find(document, ".broker-card"), sep: " ") =~ "Unknown"
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

    assert Floki.text(Floki.find(document, ".broker-card .state-badge"), sep: " ") =~ "Claimed"

    assert Floki.find(document, ".scheduling-indicator .mark-attention") == []
    assert Floki.find(document, ".broker-card .section-header > .state-badge-warning") == []

    assert Floki.find(document, ~s(.dashboard-shell[data-factory-operability="ready"])) != []
  end

  test "dashboard separates superseded exhaustion and uncertain handoff outcomes from active failures" do
    orchestrator_name = Module.concat(__MODULE__, :HistoricalFactoryDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot(), refresh: :unavailable)

    snapshot =
      factory_dashboard_snapshot()
      |> Map.put(:broker, %{pending: 0, claimed_unverified: 1, uncertain: 1, awaiting_result: 0, needs_reconciliation: 0, last_completed_at: nil})
      |> Map.update!(:current_runs, fn runs ->
        Enum.map(runs, &Map.put(&1, :historical_failure, %{reason: "Prior five-attempt exhaustion", evidence_at: "2026-10-01T00:00:00Z"}))
      end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50, factory_observability: fn -> snapshot end)
    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    assert Floki.text(Floki.find(document, ".broker-card"), sep: " ") =~ "Outcome uncertain"
    refute Floki.text(Floki.find(document, ".broker-card .state-badge"), sep: " ") =~ "Claimed"
    history = Floki.find(document, ~s(details[data-workflow-history="PPL-123"]))
    assert Floki.text(history, sep: " ") =~ "Historical repair exhaustion — superseded"
    assert Floki.text(history, sep: " ") =~ "Prior five-attempt exhaustion"
    assert Floki.attribute(history, "open") == []
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

    assert Floki.text(Floki.find(document, ".scheduling-indicator"), sep: " ") =~ "Factory scheduling: Enabled"

    assert Floki.text(Floki.find(document, ".broker-card .state-badge-danger")) =~ "Needs attention"

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
      |> put_in([:current_runs, Access.at(0), :issue_key], "PPL-9723")
      |> put_in([:current_runs, Access.at(0), :state], "SPEC_DRAFTING")
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
      |> Enum.find(&(Floki.text(&1, sep: " ") =~ "In progress"))
      |> Floki.text(sep: " ")

    queue_text =
      summary_cards
      |> Enum.find(&(Floki.text(&1, sep: " ") =~ "Intake backlog"))
      |> Floki.text(sep: " ")

    assert active_text =~ "In progress 0"
    refute active_text =~ "running"
    assert queue_text =~ "Intake backlog 1"

    workflow =
      html
      |> Floki.parse_document!()
      |> Floki.find(".runs-section")
      |> Floki.text(sep: " ")

    assert workflow =~ "Intake backlog"
    assert workflow =~ "Spec drafting"
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
    factory_snapshot = %{factory_snapshot | current_runs: [run], tasks: [task]}

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
    refute attention_text =~ "running"

    workflow = html |> Floki.parse_document!() |> Floki.find(".tickets-section") |> Floki.text(sep: " ")
    assert workflow =~ "Needs attention"
    assert workflow =~ "Verifier creation failed"
    assert workflow =~ "Correct them and recover this same request"
    assert workflow =~ handoff.request_key
    refute workflow =~ "Active"

    task_failure = html |> Floki.parse_document!() |> Floki.find(".task-failure") |> Floki.text(sep: " ")
    assert task_failure =~ "Verifier creation failed"
  end

  @tag review_stop_ui: true
  test "dashboard separates a review policy stop from factory health and preserves ticket actions" do
    name = Module.concat(__MODULE__, :ReviewPolicyStopOrchestrator)
    {:ok, _} = StaticOrchestrator.start_link(name: name, snapshot: Map.put(static_snapshot(), :running, []), refresh: :unavailable)

    stop = %{
      kind: "REVIEW_POLICY",
      title: "Verification repair limit reached",
      rule: "At most two repairs after the initial review",
      explanation: "2/2 repair attempts used.",
      recorded_ci: "PASSED",
      owner: "Requester decision",
      findings: ["RPC <handler> still exposes a value"],
      next_action: "Review the findings in the ticket chat. Automatic repair is stopped."
    }

    snapshot = factory_dashboard_snapshot()

    run =
      hd(snapshot.current_runs)
      |> Map.merge(%{
        state: "FAILED",
        review_stop: stop,
        primary_next_action: stop.next_action,
        blocking_attention: %{reason: stop.explanation, next_action: stop.next_action},
        delivery_health: "NEEDS_ATTENTION"
      })

    by_issue = %{"PPL-123" => "NEEDS_ATTENTION", "PPL-9723" => "QUEUED"}
    overview = %{active: 0, queued: 1, review_ready: 0, needs_attention: 1, by_issue: by_issue}
    snapshot = %{snapshot | current_runs: [run], overview: overview}
    start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50, factory_observability: fn -> snapshot end)
    {:ok, _view, html} = live(build_conn(), "/")
    document = Floki.parse_document!(html)
    callout = document |> Floki.find("[data-review-stop]") |> Floki.text(sep: " ")
    assert callout =~ stop.title
    assert callout =~ stop.rule
    assert callout =~ "CI passed for this candidate"
    assert callout =~ "Factory scheduling health is shown separately"
    row = document |> Floki.find(".tickets-section") |> Floki.text(sep: " ")
    assert row =~ "Review stopped"
    assert row =~ "Verify"
    assert row =~ "Requester decision"
    assert row =~ "Open ticket chat"
    assert row =~ "Recorded verification findings"
    assert html =~ "RPC &lt;handler&gt; still exposes a value"
    refute html =~ "RPC <handler>"
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
      |> put_in([:current_runs, Access.at(0), :tasks], [active_task])
      |> put_in([:current_runs, Access.at(0), :state], "SPEC_DRAFTING")
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

    assert html =~ "Open recorded worker task"
    assert html =~ ~s(href="codex://threads/thread-active")

    workflow =
      html
      |> Floki.parse_document!()
      |> Floki.find(".runs-section")
      |> Floki.text(sep: " ")

    assert workflow =~ "In progress"
    assert workflow =~ "Spec drafting"
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
      |> put_in([:current_runs, Access.at(0), :last_error], failed_task.failure_code)

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
    assert html |> Floki.parse_document!() |> Floki.find(".raw-disclosure pre") |> Floki.text() =~ failed_task.failure_code
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

  defp unified_dashboard_snapshot(sample \\ :mixed) do
    base = factory_dashboard_snapshot()
    [original | _] = base.runs

    context = %{
      original.ticket_context
      | source_stage: "REPAIRING",
        candidate_sha: original.candidate_sha,
        next_action: "Saved guidance; inspect the current next action.",
        validation: %{required: false, status: "NOT_REQUIRED", publication: "NOT_PROVEN_BY_VALIDATOR_OUTPUT"}
    }

    error = if sample == :stress, do: String.duplicate("Long raw diagnostic <script>alert('escaped')</script> Ω\n", 210), else: "Recorded worker stopped without completing the requested change."

    action =
      if sample == :stress,
        do: "Very long next action " <> String.duplicate("unbroken-url-segment", 25) <> "\nResolve every recorded finding.",
        else: "Resolve the recorded findings through the ticket chat."

    stopped =
      Map.merge(original, %{
        issue_key: "PPL-1",
        run_id: "run-1",
        state: "REPAIRING",
        summary: "Restore versioned extraction logging",
        primary_next_action: action,
        worker_execution: %{status: "STOPPED", turn_id: nil},
        last_error: error,
        ticket_context: Map.put(context, :suggested_prompt, %{kind: "TICKET_CHAT_SUGGESTED_PROMPT_V1", body: "Rework the current candidate."}),
        attention: %{blocking: true, reason: "Recorded source result is blocked; no worker is running."},
        attention_signals: []
      })

    ready =
      Map.merge(original, %{
        issue_key: "PPL-3",
        run_id: "run-3",
        primary_next_action: "Review the draft merge request.",
        worker_execution: %{status: "NOT_APPLICABLE", turn_id: nil},
        attention_signals: [
          %{
            source: "PARENT_SYNC",
            phase: "PENDING",
            blocking: false,
            category: "COMMUNICATION",
            reason: "Ticket presentation update is pending.",
            next_action: "Open the ticket chat for durable context."
          }
        ]
      })

    validation = Map.merge(ready, %{issue_key: "PPL-4", run_id: "run-4", state: "AWAITING_VALIDATION", primary_next_action: "Complete the recorded manual validation.", attention_signals: []})

    active =
      Map.merge(stopped, %{
        issue_key: "PPL-5",
        run_id: "run-5",
        state: "WRITING",
        primary_next_action: "Wait for the current native turn result.",
        ticket_context: context,
        worker_execution: %{status: "TURN_BOUND", turn_id: "sample-turn"},
        attention: nil,
        last_error: nil
      })

    failed = Map.merge(stopped, %{issue_key: "PPL-7", run_id: "run-7", state: "FAILED", ticket_context: context, summary: "Run-only terminal record retained by overview membership"})
    title = if sample == :stress, do: "Very long title " <> String.duplicate("Natural language and unbroken_token_", 18), else: "Restore versioned extraction logging"

    issue = %{
      issue_key: "PPL-1",
      issue_url: "https://jira.example/PPL-1",
      summary: title,
      status: "To Do",
      classification: "DELIVERY",
      routing_status: "ROUTED",
      repo_key: "grail",
      updated_at: "2026-09-22T20:00:00Z"
    }

    intake = %{
      base.intake
      | stale: true,
        count: 3,
        issues: [
          issue,
          %{issue | issue_key: "PPL-2", summary: "Specify the next extraction contract", classification: "SPECIFICATION"},
          %{issue | issue_key: "PPL-6", summary: "Repository routing needs a decision", routing_status: "UNROUTED", repo_key: nil}
        ]
    }

    buckets = %{
      "PPL-1" => "NEEDS_ATTENTION",
      "PPL-2" => "QUEUED",
      "PPL-3" => "REVIEW_READY",
      "PPL-4" => "VALIDATION_PENDING",
      "PPL-5" => "ACTIVE",
      "PPL-6" => "NEEDS_ATTENTION",
      "PPL-7" => "NEEDS_ATTENTION"
    }

    control = preview_control(base.control, sample)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    historical = now |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
    polled = now |> DateTime.add(if(sample in [:stale, :unknown], do: -3600, else: -30), :second) |> DateTime.to_iso8601()

    runs =
      Enum.map([stopped, ready, validation, active, failed], fn run ->
        context = %{run.ticket_context | parent_thread_id: "sample-parent-#{run.issue_key}", codex_thread_url: "codex://threads/sample-parent-#{run.issue_key}"}
        %{run | issue_url: "https://jira.example/#{run.issue_key}", ticket_context: context}
      end)

    intake = %{intake | issues: Enum.map(intake.issues, &Map.put(&1, :issue_url, "https://jira.example/#{&1.issue_key}"))}

    overview = %{active: 1, queued: 1, review_ready: 1, needs_attention: 3, validation_pending: 1, by_issue: buckets}

    %{base | runs: [failed, original], intake: intake, control: control, overview: overview}
    |> Map.put(:current_runs, runs)
    |> preview_timestamps(historical)
    |> put_in([:intake, :observed_at], polled)
    |> put_in([:intake, :stale], sample in [:stale, :unknown])
    |> Map.put(:capacity, if(sample == :unknown, do: [], else: base.capacity))
  end

  defp preview_control(control, sample) do
    observation =
      case sample do
        :unknown -> "UNKNOWN"
        :stale -> "STALE"
        _other -> "FRESH"
      end

    control = Map.merge(control, %{controller_writer_conflict_count: 0, tick_observation: %{status: observation}})

    if sample == :blocked,
      do:
        Map.put(control, :handoff_attention, %{
          blocking: true,
          category: "CURRENT",
          phase: "RECONCILE_REQUIRED",
          evidence_at: "2026-09-22T20:00:00Z",
          request_key: "sample-controller-request",
          reason: "A current controller handoff requires reconciliation.",
          next_action: "Inspect the recorded controller request before new scheduling."
        }),
      else: control
  end

  defp preview_timestamps(value, timestamp) when is_map(value), do: Map.new(value, fn {key, item} -> {key, preview_timestamps(item, timestamp)} end)
  defp preview_timestamps(value, timestamp) when is_list(value), do: Enum.map(value, &preview_timestamps(&1, timestamp))
  defp preview_timestamps("2026-09-22T" <> _rest, timestamp), do: timestamp
  defp preview_timestamps(value, _timestamp), do: value

  defp factory_dashboard_snapshot do
    snapshot = %{
      enabled: true,
      available: true,
      control: %{
        status: "ACTIVE",
        scope: "assigned-jira-work",
        dispatcher_id: "dispatcher",
        generation: 12,
        tick_observation: %{status: "FRESH"},
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
          tasks: [],
          ticket_context: %{
            available: true,
            parent_thread_id: "parent-ticket",
            codex_thread_url: "codex://threads/parent-ticket",
            source_stage: "READY_FOR_REVIEW",
            candidate_sha: String.duplicate("b", 40),
            contract_revision: "r3",
            ci: %{checked_at: "2026-09-22T19:59:00Z", artifact: %{availability: "AVAILABLE"}},
            validation: %{required: 1, status: "NOT_REQUIRED", publication: "NOT_PROVEN_BY_VALIDATOR_OUTPUT"},
            questions: [%{"question_key" => "q1", "binding" => "STALE", "body" => %{availability: "AVAILABLE"}, "answers" => %{availability: "NOT_RECORDED"}}],
            actionable_question_count: 0,
            next_action: "Review the draft merge request.",
            worker_tasks: [],
            attributed_usage: %{status: "UNKNOWN", tokens: nil, cost: nil},
            synchronization: %{status: "PENDING", request: %{"status" => "PENDING"}}
          }
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

    Map.put(snapshot, :current_runs, [hd(snapshot.runs)])
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
