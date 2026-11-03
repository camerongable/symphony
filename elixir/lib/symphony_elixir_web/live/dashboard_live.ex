defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Factory.Observability, as: FactoryObservability
  alias SymphonyElixirWeb.{DashboardTickets, Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @payload_refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    payload = bounded_initial_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:snapshot_observed_at, if(payload_failure(payload), do: nil, else: DateTime.utc_now()))
      |> assign(:snapshot_error, payload_failure(payload))
      |> assign(:snapshot_refresh, nil)
      |> assign(:expanded_workflows, MapSet.new())
      |> assign(:theme, "dark")
      |> assign(:ticket_filter, "ALL")

    socket =
      if connected?(socket) do
        :ok = ObservabilityPubSub.subscribe()
        schedule_runtime_tick()
        schedule_payload_refresh()
        if socket.assigns.snapshot_error, do: start_snapshot_refresh(socket), else: socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("dashboard_theme", %{"theme" => theme}, socket) when theme in ~w(dark light),
    do: {:noreply, assign(socket, :theme, theme)}

  def handle_event("dashboard_theme", _params, socket), do: {:noreply, socket}

  def handle_event("ticket_filter", %{"bucket" => bucket}, socket)
      when bucket in ~w(ALL NEEDS_ATTENTION ACTIVE QUEUED REVIEW_READY VALIDATION_PENDING),
      do: {:noreply, assign(socket, :ticket_filter, bucket)}

  def handle_event("ticket_filter", _params, socket), do: {:noreply, socket}

  def handle_event("workflow_details", %{"run_id" => id}, socket) do
    factory = socket.assigns.payload[:factory] || %{}
    tickets = DashboardTickets.project(factory).tickets
    expanded = socket.assigns.expanded_workflows

    if Enum.any?(tickets, &(&1.key == id)) do
      next = if MapSet.member?(expanded, id), do: MapSet.delete(expanded, id), else: MapSet.put(expanded, id)
      {:noreply, assign(socket, :expanded_workflows, next)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, start_snapshot_refresh(socket)}
  end

  def handle_info(:payload_refresh, socket) do
    schedule_payload_refresh()

    {:noreply, start_snapshot_refresh(socket)}
  end

  def handle_info({:snapshot_timeout, token}, %{assigns: %{snapshot_refresh: %{token: token}}} = socket) do
    {:noreply, socket |> cancel_async({:snapshot, token}) |> assign(:snapshot_refresh, nil) |> assign(:snapshot_error, "Snapshot refresh timed out; displayed data is last known, not current.")}
  end

  def handle_info({:snapshot_timeout, _token}, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:snapshot, token}, result, %{assigns: %{snapshot_refresh: %{token: token, timer: timer}}} = socket) do
    Process.cancel_timer(timer)
    socket = assign(socket, :snapshot_refresh, nil)

    case result do
      {:ok, payload} when is_map(payload) ->
        case payload_failure(payload) do
          nil -> {:noreply, socket |> assign(:payload, payload) |> assign(:snapshot_error, nil) |> assign(:snapshot_observed_at, DateTime.utc_now())}
          failure -> {:noreply, assign(socket, :snapshot_error, failure)}
        end

      _ ->
        {:noreply, assign(socket, :snapshot_error, "Snapshot refresh failed; displayed data is last known, not current.")}
    end
  end

  def handle_async({:snapshot, _token}, _result, socket), do: {:noreply, socket}

  defp start_snapshot_refresh(%{assigns: %{snapshot_refresh: nil}} = socket) do
    token = make_ref()
    timer = Process.send_after(self(), {:snapshot_timeout, token}, refresh_timeout_ms())
    socket |> assign(:snapshot_refresh, %{token: token, timer: timer}) |> start_async({:snapshot, token}, fn -> load_payload() end)
  end

  defp start_snapshot_refresh(socket), do: socket

  defp bounded_initial_payload do
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> load_payload() end)

    case Task.yield(task, refresh_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{error: %{code: "snapshot_timeout", message: "Initial snapshot unavailable; waiting for a bounded refresh."}}
    end
  end

  defp refresh_timeout_ms, do: Endpoint.config(:dashboard_refresh_timeout_ms) || 5_000
  defp payload_failure(%{error: error}), do: error.message

  defp payload_failure(%{factory: %{available: false} = factory}),
    do: if(Map.get(factory, :disabled) == true, do: nil, else: "Factory snapshot unavailable; displayed data is last known, not current.")

  defp payload_failure(_payload), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :factory_operability, if(assigns.snapshot_error, do: "unknown", else: factory_operability(assigns.payload)))

    ~H"""
    <section class="dashboard-shell" data-factory-operability={@factory_operability} data-theme={@theme}>
      <header class="dashboard-header">
        <div>
          <h1 class="hero-title">Symphony</h1>
          <p class="hero-copy">Tickets</p>
          <div class="theme-switcher" role="group" aria-label="Dashboard appearance">
            <button :for={theme <- ~w(dark light)} type="button" phx-click="dashboard_theme" phx-value-theme={theme} aria-pressed={to_string(@theme == theme)}><%= String.capitalize(theme) %></button>
          </div>
        </div>

        <div class="scheduling-indicator" aria-label="Factory scheduling control observation">
          <span class={"status-mark #{scheduling_tone(@payload, @snapshot_error)}"} aria-hidden="true"></span>
          <strong>Factory scheduling: <%= scheduling_label(@payload, @snapshot_error) %></strong>
          <small>Polling and admission control</small>
        </div>
      </header>
      <p :if={@snapshot_error} class="factory-alert factory-alert-danger" role="alert" data-snapshot-stale="true">
        Dashboard data stale: <%= @snapshot_error %>
        <a :if={is_nil(@snapshot_observed_at)} href="/">Reload dashboard</a>
      </p>
      <p :if={!@snapshot_observed_at} class="section-copy">Ticket counts unknown until a successful dashboard observation.</p>
      <p class="section-copy snapshot-caption">Snapshot observed <.local_time id="dashboard-observed-at" value={if @snapshot_observed_at, do: DateTime.to_iso8601(@snapshot_observed_at)} /></p>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="ticket-buckets" aria-label="Ticket buckets">
          <button :for={{bucket, label, count} <- ticket_buckets(@payload)} type="button" phx-click="ticket_filter" phx-value-bucket={bucket} aria-pressed={to_string(@ticket_filter == bucket)} class="ticket-bucket metric-card">
            <span><%= label %></span><strong class="numeric"><%= if @snapshot_observed_at, do: count, else: "Unknown" %></strong>
          </button>
        </section>
        <p class="queue-guide">Five queue filters classify tickets in this snapshot; they are not the seven lifecycle phases.</p>
      <% end %>

      <.factory_dashboard :if={@payload[:factory]} factory={@payload.factory} now={@now} snapshot_stale={@snapshot_error != nil} expanded_workflows={@expanded_workflows} ticket_filter={@ticket_filter}>
        <:runtime>

      <details
        :if={!@payload[:error]}
        id="runtime-diagnostics"
        class="diagnostics-panel"
        phx-hook="PersistentDisclosure"
      >
        <summary>
          <span>
            <strong>Symphony runtime diagnostics</strong>
            <small>Agent sessions, retry details, token use, and upstream rate limits.</small>
          </span>
          <span class="disclosure-label">
            <span class="disclosure-closed-label">Show runtime</span>
            <span class="disclosure-open-label">Hide runtime</span>
          </span>
        </summary>

        <div class="diagnostics-content">
          <section class="metric-grid diagnostic-metrics" aria-label="Runtime totals">
            <article class="metric-card">
              <p class="metric-label">Agent sessions</p>
              <p class="metric-value numeric"><%= @payload.counts.running %></p>
              <p class="metric-detail">Direct Symphony agent sessions.</p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Retrying</p>
              <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
              <p class="metric-detail">Waiting for another attempt.</p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Total tokens</p>
              <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
              <p class="metric-detail numeric">
                In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
              </p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Runtime</p>
              <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
              <p class="metric-detail">Completed and active sessions.</p>
            </article>
          </section>

          <section class="diagnostic-section">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          </section>

          <section class="diagnostic-section">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Direct Symphony sessions, separate from factory ticket workflows.</p>
            </div>

            <p :if={@payload.running == []} class="empty-state">No direct agent sessions.</p>
            <div class="table-wrap">
              <table :if={@payload.running != []} class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td data-label="Issue">
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <.copy_button :if={entry.session_id} value={entry.session_id} label="Copy ID" />
                      </div>
                    </td>
                    <td data-label="State">
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td data-label="Runtime / turns" class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td data-label="Codex update">
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td data-label="Tokens">
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="diagnostic-section">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Direct sessions paused for operator input or approval.</p>
            </div>

            <p :if={@payload.blocked == []} class="empty-state">No blocked sessions.</p>
            <div class="table-wrap">
              <table :if={@payload.blocked != []} class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td data-label="Issue">
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td data-label="State">
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td data-label="Blocked at" class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td data-label="Last update">
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td data-label="Error"><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="diagnostic-section">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>

            <p :if={@payload.retrying == []} class="empty-state">No issues are currently backing off.</p>
            <div class="table-wrap">
              <table :if={@payload.retrying != []} class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td data-label="Issue">
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td data-label="Attempt"><%= entry.attempt %></td>
                    <td data-label="Due at" class="mono"><%= entry.due_at || "n/a" %></td>
                    <td data-label="Error"><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </details>
        </:runtime>
      </.factory_dashboard>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), factory_observability())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp factory_observability do
    Endpoint.config(:factory_observability) || (&FactoryObservability.snapshot/0)
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  attr(:factory, :map, required: true)
  attr(:now, :any, required: true)
  attr(:snapshot_stale, :boolean, default: false)
  attr(:expanded_workflows, :any, required: true)
  attr(:ticket_filter, :string, required: true)
  slot(:runtime, required: true)

  defp factory_dashboard(assigns) do
    assigns = if assigns.snapshot_stale and assigns.factory.available, do: assign(assigns, :factory, put_in(assigns.factory, [:control, :snapshot_stale], true)), else: assigns

    factory =
      if Map.get(assigns.factory, :disabled, false) or not Map.get(assigns.factory, :available, false) do
        assigns.factory
      else
        assigns.factory
        |> update_in([:control], &Map.put_new(&1, :runtime_identity, %{}))
        |> update_in([:intake], &Map.put_new(&1, :stale, assigns.factory.control.status == "PAUSED"))
      end

    assigns =
      assigns
      |> assign(:factory, factory)
      |> assign(:shared_capacity, List.first(factory[:capacity] || []))
      |> assign(:repository_keys, repository_keys(factory[:capacity] || []))
      |> assign(:ticket_projection, DashboardTickets.project(factory))

    ~H"""
    <section class="factory-workspace">
      <%= if @factory.available do %>
        <div :if={controller_blocking_attention?(@factory.control)} class="factory-alert" role="alert">
          <strong>Scheduling handoff needs attention</strong>
          <p><%= @factory.control.handoff_attention[:reason] %></p>
          <p><%= @factory.control.handoff_attention[:next_action] %></p>
        </div>

        <div :if={broker_reconciliation_required?(@factory)} class="factory-alert" role="alert" data-broker-attention="true">
          <strong>Desktop handoff needs attention</strong>
          <p>A blocking or unclassified handoff needs reconciliation. Inspect Desktop Broker under System health and capacity; do not resend an uncertain request.</p>
        </div>

        <div :if={get_in(@factory.control, [:tick_health, :status]) == "FAILED"} class="factory-alert" role="alert">
          <strong>Last factory tick failed</strong>
          <p>Queued tickets may not advance until recovery. Last error: <%= @factory.control.tick_health.last_error %></p>
        </div>
        <div
          :if={@factory.control.controller_writer_conflict_count > 0}
          class="factory-alert factory-alert-danger"
          role="alert"
        >
          <div>
            <strong>Scheduler needs attention</strong>
            <p>
              Another Codex session owns the orchestrator task, so Jira polling has paused after
              <span class="numeric"><%= @factory.control.controller_writer_conflict_count %></span>
              attempts.
            </p>
            <p>Close or leave that task in other Codex windows. The next scheduled poll retries automatically.</p>
          </div>
          <span class="factory-alert-meta">
            Since <.local_time id="controller-conflict-since" value={@factory.control.controller_writer_conflict_since} />
          </span>
        </div>

        <section class="tickets-section runs-section" aria-labelledby="tickets-heading">
          <header class="tickets-heading">
            <div><h2 id="tickets-heading">Tickets</h2><p>Current bounded snapshot · <%= length(@ticket_projection.tickets) %> identifiable tickets · <%= length(filtered_tickets(@ticket_projection.tickets, @ticket_filter)) %> shown</p></div>
            <nav class="ticket-list-filters" aria-label="Additional ticket filters">
              <button type="button" phx-click="ticket_filter" phx-value-bucket="ALL" aria-pressed={to_string(@ticket_filter == "ALL")}>All tickets</button>
            </nav>
          </header>
          <div :if={!intake_available?(@factory)} class="factory-alert" role="alert" data-intake-unavailable="true">
            <strong>Partial ticket snapshot · intake backlog unknown</strong>
            <p :if={get_in(@factory, [:intake, :error])} class="full-text bounded-reading" tabindex="0" role="region" aria-label="Intake read failure">Jira intake history could not be read: <%= intake_read_error(@factory) %></p>
            <p :if={!get_in(@factory, [:intake, :error])}>No successful Jira intake snapshot has been recorded yet.</p>
            <p>Recorded workflows remain visible. Missing intake data does not mean there are no queued tickets.</p>
          </div>
          <p :if={intake_available?(@factory) && get_in(@factory, [:intake, :issues]) == []} class="list-note" data-intake-empty="true">The last successful poll found no factory-labelled issues. Recorded workflows may still be present.</p>
          <p class="phase-guide">Seven lifecycle phases: Intake · Specify · Build · Verify · Publish · Validate · Review. Other positions do not prove completion.</p>
          <p :if={@ticket_filter == "QUEUED"} class="list-note">Tracked intake tickets; not all are ready to start.</p>
          <div :if={@ticket_projection.diagnostics != []} class="projection-notice" role="status"><p :for={note <- @ticket_projection.diagnostics}><%= note %></p></div>
          <p :if={filtered_tickets(@ticket_projection.tickets, @ticket_filter) == []} class="empty-state"><%= if @ticket_filter in ["ALL", "QUEUED"] && !intake_available?(@factory), do: "No identifiable tickets are available in this view; the intake backlog is unknown.", else: "No tickets in #{bucket_label(@ticket_filter)} in this snapshot. Global counts are unchanged." %></p>

          <article :for={ticket <- filtered_tickets(@ticket_projection.tickets, @ticket_filter)} class="ticket-record" data-ticket-record={ticket.key} data-bucket={ticket.bucket}>
            <div class="ticket-summary workflow-summary">
              <div class="ticket-identity">
                <.issue_identifier identifier={ticket.key} url={ticket_issue_url(ticket)} />
                <span class="ticket-bucket-label"><span class={ticket_mark(ticket)} aria-hidden="true"></span><%= bucket_label(ticket.bucket) %></span>
                <h3 class="compact-text"><%= ticket_title(ticket) %></h3>
                <small><%= if ticket.run, do: "Recorded workflow", else: "Intake" %></small>
              </div>
              <div class="ticket-phase">
                <span class="field-label">Current phase</span>
                <ol class="stage-map" aria-label="Recorded current phase only; other stages are not completion evidence">
                  <li :for={stage <- ~w(Intake Specify Build Verify Publish Validate Review)} data-phase-slot={stage} aria-current={if ticket_stage(ticket) == stage, do: "step"} class={if ticket_stage(ticket) == stage, do: "current-stage"}><span class="phase-dot" aria-hidden="true"></span><span class="phase-name"><%= stage %></span></li>
                </ol>
                <p class={["current-phase-label", is_nil(ticket_stage(ticket)) && "phase-unavailable"]}><%= ticket_stage(ticket) || "Phase unavailable" %></p>
                <p><%= ticket_activity_summary(ticket) %></p>
              </div>
              <div class="ticket-action">
                <div :if={ticket.run && ticket.run[:review_stop]} class="review-stop" data-review-stop={ticket.key}>
                  <strong><%= ticket.run.review_stop.title %></strong>
                  <p><%= ticket.run.review_stop.rule %></p>
                  <small><%= if ticket.run.review_stop.recorded_ci == "PASSED", do: "CI passed for this candidate. ", else: "Passing CI is not proven in this snapshot. " %>Factory scheduling health is shown separately.</small>
                </div>
                <span class="field-label">Next step</span><strong class="compact-text"><%= ticket_action(ticket) %></strong>
                <p :if={ticket_blocker(ticket)} class="compact-text"><span class="status-mark mark-attention" aria-hidden="true"></span><%= ticket_blocker(ticket) %></p>
                <p :if={ticket.diagnostics != []}><%= Enum.join(ticket.diagnostics, " ") %></p>
                <small :if={communication_warning?(ticket)}>Communication warning recorded; not a delivery blocker.</small>
                <strong :if={(ticket_context(ticket)[:actionable_question_count] || 0) > 0} class="decision-count"><%= ticket_context(ticket).actionable_question_count %> current decision(s) need an answer</strong>
                <small :if={ticket.run && get_in(ticket, [:intake, :admission_error])}>Last-polled intake issue recorded; not current delivery authority.</small>
                <small class="responsibility"><%= ticket_responsibility(ticket) || "Action owner not recorded" %></small>
                <nav class="next-step-links" aria-label={"Next-step links for #{ticket.key}"}>
                  <div :if={ticket_suggested_prompt(ticket)} class="suggested-prompt-actions" id={ticket_dom_id(ticket.key) <> "-prompt"} phx-hook="CopySuggestedPrompt">
                    <button type="button" data-copy-suggested-prompt data-prompt-base64={Base.encode64(ticket_suggested_prompt(ticket))}>Copy suggested prompt</button>
                    <a href={ticket_chat(ticket)} class="text-link">Open ticket chat</a>
                    <small class="copy-note" role="status" aria-live="polite">Copy does not send. Open chat to paste and review.</small>
                  </div>
                  <a :if={ticket_chat(ticket) && !ticket_suggested_prompt(ticket)} href={ticket_chat(ticket)} class="text-link">Open ticket chat</a>
                  <a :if={ticket_mr(ticket)} href={ticket_mr(ticket)} class="text-link">Open MR <%= if ticket.run[:mr_iid], do: "!#{ticket.run.mr_iid}" %></a>
                </nav>
              </div>
              <div class="ticket-links">
                <.local_time id={ticket_dom_id(ticket.key) <> "-updated"} value={ticket_updated(ticket)} />
                <button type="button" class="workflow-disclosure" phx-click="workflow_details" phx-value-run_id={ticket.key} aria-expanded={to_string(MapSet.member?(@expanded_workflows, ticket.key))} aria-controls={ticket_dom_id(ticket.key)}><%= if MapSet.member?(@expanded_workflows, ticket.key), do: "Hide details", else: "Details" %></button>
              </div>
            </div>

            <section class="ticket-details" id={ticket_dom_id(ticket.key)} hidden={!MapSet.member?(@expanded_workflows, ticket.key)} aria-label={"Details for #{ticket.key}"}>
              <h3 class="compact-text"><%= ticket_title(ticket) %></h3>
              <details class="long-text-disclosure"><summary>Full ticket title</summary><div class="bounded-reading" tabindex="0" role="region" aria-label="Full ticket title"><%= ticket_title(ticket) %></div></details>
              <div class="ticket-detail-grid">
                <section class="ticket-detail-section">
                  <h4>Next action and decisions</h4>
                  <p :if={ticket.run && ticket_context(ticket)[:available] == false}>Ticket context unavailable; delivery state remains recorded separately.</p>
                  <p class="full-text bounded-reading" tabindex="0" role="region" aria-label="Full next action"><%= ticket_action(ticket) %></p>
                  <p :if={ticket_blocker(ticket)} class="full-text bounded-reading" tabindex="0" role="region" aria-label="Full recorded blocker" data-workflow-attention={ticket.key} data-intake-blocker={if is_nil(ticket.run) && intake_error(ticket), do: ticket.key}><strong><%= if ticket.run, do: humanize_factory_code(ticket_attention(ticket)[:phase] || "RECORDED_BLOCKER"), else: "Last-polled intake issue" %>:</strong> <%= ticket_blocker(ticket) %></p>
                  <p :for={note <- ticket.diagnostics}><%= note %></p>
                  <details :if={ticket.run && ticket.run[:review_stop]} class="long-text-disclosure"><summary>Recorded verification findings</summary><ol><li :for={finding <- ticket.run.review_stop.findings} class="full-text bounded-reading"><%= finding %></li></ol></details>
                  <div :for={question <- ticket_questions(ticket)} class="decision-record">
                    <strong>Decision <%= question["question_key"] %> · <%= question["binding"] %></strong>
                    <p>Question body: <%= artifact_availability(question["body"]) %> · Answer: <%= artifact_availability(question["answers"]) %></p>
                  </div>
                  <p :if={ticket.run && ticket_context(ticket)[:next_action]}><strong>Saved context guidance:</strong> <%= ticket_context(ticket)[:next_action] %></p>
                </section>

                <section class="ticket-detail-section">
                  <h4>Progress</h4>
                  <dl class="ticket-facts">
                    <div><dt>Recorded phase</dt><dd data-source-stage={ticket.key}><%= ticket_phase(ticket) %></dd></div>
                    <div><dt>Worker activity</dt><dd data-worker-execution={ticket.key}><%= ticket_activity(ticket) %></dd></div>
                    <div><dt>Recorded responsibility</dt><dd><%= ticket_responsibility(ticket) || "Owner not recorded" %></dd></div>
                    <div :if={ticket.run && ticket.run[:implementation_iteration_limit]}><dt>Implementation iterations</dt><dd data-implementation-iterations={ticket.key}><%= ticket.run[:implementation_iteration] %>/<%= ticket.run[:implementation_iteration_limit] %></dd></div>
                    <div :if={ticket.run && ticket.run[:ci_repair_attempt_limit]}><dt>CI repair attempts</dt><dd data-ci-repair-attempts={ticket.key}><%= ticket.run[:ci_repair_attempts_used] || 0 %>/<%= ticket.run[:ci_repair_attempt_limit] %> · separate budget</dd></div>
                    <div :if={ticket.run}><dt>Workspace</dt><dd><%= workspace_label(ticket.run[:workspace_state]) %></dd></div>
                    <div :if={ticket.intake}><dt>Jira status at last poll</dt><dd><%= ticket.intake[:status] || "Not recorded" %></dd></div>
                    <div :if={ticket.intake}><dt>Intake intent / routing</dt><dd><%= humanize_factory_code(ticket.intake[:classification]) %> · <%= humanize_factory_code(ticket.intake[:routing_status]) %> · <%= ticket.intake[:repo_key] || "Repository not routed" %></dd></div>
                  </dl>
                  <p class="secondary-note"><%= if @factory.intake[:stale] || @snapshot_stale, do: "Jira metadata is a stale saved snapshot.", else: "Jira metadata is from the last poll, not a fresh eligibility check." %></p>
                  <p :if={ticket.run && get_in(ticket, [:intake, :admission_error])} class="full-text"><strong>Last-polled intake issue; not current delivery authority:</strong> <%= intake_error(ticket) %></p>
                </section>

                <section class="ticket-detail-section">
                  <h4>Delivery and evidence</h4>
                  <p :if={!ticket.run}>No durable delivery record is attached to this intake ticket.</p>
                  <dl :if={ticket.run} class="ticket-facts">
                    <div><dt>Candidate commit</dt><dd data-candidate-sha={ticket.key}><%= ticket.run[:candidate_sha] || "Not recorded" %></dd></div>
                    <div><dt>Merge request</dt><dd><a :if={ticket_mr(ticket)} href={ticket_mr(ticket)}>Open draft MR</a><span :if={!ticket_mr(ticket)}>Not recorded</span></dd></div>
                    <div :if={ticket_attention(ticket)[:pipeline_url]}><dt>Current pipeline</dt><dd><a href={ticket_attention(ticket).pipeline_url}>Open pipeline</a></dd></div>
                    <div :for={job <- ticket_attention(ticket)[:failed_jobs] || []}><dt>Failed job</dt><dd><a :if={job[:url]} href={job.url}><%= job[:name] || "Open job" %></a></dd></div>
                    <div :if={ticket_context(ticket)[:ci]}><dt>CI evidence</dt><dd><%= artifact_availability(ticket_context(ticket).ci[:artifact]) %> · checked <.local_time id={ticket_dom_id(ticket.key) <> "-ci"} value={ticket_context(ticket).ci[:checked_at]} /></dd></div>
                    <div :if={ticket_context(ticket)[:validation]}><dt>Manual validation</dt><dd><%= validation_summary(ticket_context(ticket).validation) %></dd></div>
                    <div :if={ticket_context(ticket)[:source_stage]}><dt>Saved context stage</dt><dd><%= humanize_factory_code(ticket_context(ticket).source_stage) %></dd></div>
                  </dl>
                </section>

                <section class="ticket-detail-section">
                  <h4>History and diagnostics</h4>
                  <ul :if={ticket.run && (ticket.run[:tasks] || []) != []} class="recorded-task-links">
                    <li :for={task <- ticket.run[:tasks] || []}><a :if={is_binary(task[:thread_id]) && task[:thread_id] != ""} href={codex_thread_url(task.thread_id)}>Open recorded worker task</a> · <%= humanize_factory_code(task[:role]) %> · recorded <%= humanize_factory_code(task[:status]) %></li>
                  </ul>
                  <details :if={ticket.run && ticket.run[:historical_failure]} class="raw-disclosure" data-workflow-history={ticket.key}><summary>Historical repair exhaustion — superseded</summary><p><%= ticket.run.historical_failure[:reason] %></p><p><%= ticket.run.historical_failure[:evidence_at] %></p></details>
                  <div :for={signal <- ticket_signals(ticket)} class="recorded-warning"><strong><%= humanize_factory_code(signal[:source]) %> · <%= humanize_factory_code(signal[:phase]) %></strong><p><%= signal[:reason] %></p><p><%= signal[:next_action] %></p></div>
                  <details :if={ticket.run && ticket.run[:last_error]} class="raw-disclosure"><summary>Full recorded error</summary><p :if={readable_ticket_error(ticket)}><%= readable_ticket_error(ticket) %></p><pre class="full-text" tabindex="0" role="region" aria-label="Full recorded error"><%= ticket.run.last_error %></pre></details>
                  <details class="raw-disclosure"><summary>Technical IDs and complete snapshot evidence</summary><pre class="full-text" tabindex="0" role="region" aria-label="Complete snapshot evidence"><%= complete_ticket_evidence(ticket) %></pre></details>
                </section>
              </div>
            </section>
          </article>
        </section>

        <section class="operations-group" id="operations-history" aria-labelledby="operations-heading">
          <header><h2 id="operations-heading">Operations &amp; history</h2><p>Technical observations and recorded history. Ticket decisions remain above.</p></header>
        <details class="diagnostics-panel system-health" id="system-health-disclosure" phx-hook="PersistentDisclosure">
          <summary><span><strong>System health and capacity</strong><small>Factory control, last tick, broker and machine observations</small></span><span class="disclosure-label"><span class="disclosure-closed-label">Show health</span><span class="disclosure-open-label">Hide health</span></span></summary>
          <section class="poll-observation">
            <h3>Jira poll and dashboard transport</h3>
            <p>Last successful Jira poll: <.local_time id="intake-observed-at" value={@factory.intake[:observed_at]} /> · <%= if @factory.intake[:stale] || @snapshot_stale, do: "Stale saved snapshot", else: "Saved poll metadata, not current eligibility" %></p>
            <span class="status-badge status-badge-connected">Dashboard transport connected</span>
            <span class="status-badge status-badge-offline">Reconnecting</span>
            <p>Dashboard transport is not a worker heartbeat.</p>
            <p>Factory scheduling is a control observation, not ticket health. Enabled scheduling does not prove a successful tick or an active worker.</p>
          </section>
        <div class="workflow-heading secondary-heading">
          <div>
            <p class="eyebrow">Control and resources</p>
            <h2>Can the factory keep working?</h2>
          </div>
          <p>Scheduler health, shared machine limits, and the repositories available for routing.</p>
        </div>

        <section class={["control-grid", @factory[:broker] && "control-grid-with-broker"]}>
          <article class="section-card factory-controller">
            <div class="section-header">
              <div>
                <h2 class="section-title">Scheduler</h2>
                <p class="section-copy">The single local orchestrator that polls Jira and resumes ticket workflows.</p>
              </div>
              <span class={state_badge_class(factory_controller_health(@factory.control))}>
                <%= humanize_factory_code(factory_controller_health(@factory.control)) %>
              </span>
            </div>

            <p :if={get_in(@factory.control, [:tick_health, :status]) == "FAILED"} class="danger-text scheduler-tick-error">
              Last completed scheduler tick failed; queued tickets may not advance until recovery. Last error: <%= @factory.control.tick_health.last_error %>
            </p>
            <p :if={get_in(@factory.control, [:tick_observation, :status]) in ["STALE", "UNKNOWN", "IN_PROGRESS"]} class="muted" data-tick-observation="true">
              Scheduler observation: <%= humanize_factory_code(@factory.control.tick_observation.status) %>. Last completed tick status is recorded separately.
            </p>
            <details :if={get_in(@factory.control, [:handoff_attention, :category]) == "HISTORY"} data-controller-history="true">
              <summary>Recorded controller failure (terminal)</summary>
              <span><%= @factory.control.handoff_attention.recorded_phase %> · <%= @factory.control.handoff_attention.request_key %> · <%= @factory.control.handoff_attention.evidence_at || "not recorded" %></span>
              <p><%= @factory.control.handoff_attention.reason %></p>
              <p><%= @factory.control.handoff_attention.next_action %></p>
            </details>
            <div :if={controller_blocking_attention?(@factory.control)} class="detail-stack danger-text" data-controller-attention="true">
              <strong>Controller handoff: <%= humanize_factory_code(@factory.control.handoff_attention.phase) %></strong>
              <span><%= @factory.control.handoff_attention.reason %></span>
              <span><%= @factory.control.handoff_attention.next_action %></span>
              <span>Evidence: <%= @factory.control.handoff_attention.evidence_at || "not recorded" %> · <%= @factory.control.handoff_attention.request_key %></span>
            </div>

            <dl class="control-summary">
              <div>
                <dt>Last update</dt>
                <dd><.local_time id="controller-updated-at" value={@factory.control.updated_at} /></dd>
              </div>
              <div>
                <dt>Lease</dt>
                <dd><%= lease_status(@factory.control, @now) %></dd>
              </div>
              <div>
                <dt>Model</dt>
                <dd><%= @factory.control.controller_model || "n/a" %> · <%= @factory.control.controller_reasoning_effort || "n/a" %></dd>
              </div>
            </dl>

            <dl :if={@factory.control[:tick_health]} class="control-summary">
              <div>
                <dt>Last successful tick</dt>
                <dd><.local_time id="scheduler-last-success" value={@factory.control.tick_health.last_success_at} /></dd>
              </div>
              <div>
                <dt>Consecutive tick failures</dt>
                <dd><%= @factory.control.tick_health.consecutive_failures %></dd>
              </div>
            </dl>

            <div class="inline-actions controller-actions">
              <a
                :if={@factory.control.controller_thread_id && @factory.control.controller_writer_conflict_count == 0}
                class="subtle-link"
                href={codex_thread_url(@factory.control.controller_thread_id)}
              >Open orchestrator</a>
              <.copy_button
                :if={@factory.control.controller_thread_id}
                value={@factory.control.controller_thread_id}
                label="Copy task ID"
              />
            </div>

            <details
              id="scheduler-technical-details"
              class="inline-details"
              phx-hook="PersistentDisclosure"
            >
              <summary>Technical details</summary>
              <dl class="detail-grid compact-detail-grid">
                <div>
                  <dt>Task ID</dt>
                  <dd><%= @factory.control.controller_thread_id || "n/a" %></dd>
                </div>
                <div>
                  <dt>Scope / generation</dt>
                  <dd><%= @factory.control.scope %> · <%= @factory.control.generation %></dd>
                </div>
                <div>
                  <dt>Lease expires</dt>
                  <dd><.local_time id="controller-lease-expires-at" value={@factory.control.lease_expires_at} /></dd>
                </div>
                <div>
                  <dt>Writer conflicts</dt>
                  <dd><%= @factory.control.controller_writer_conflict_count %></dd>
                </div>
                <div>
                  <dt>Control server started</dt>
                  <dd><.local_time id="factory-control-server-started-at" value={@factory.control.runtime_identity[:control_server_started_at]} /></dd>
                </div>
                <div>
                  <dt>BEAM process started (runtime-derived)</dt>
                  <dd><.local_time id="factory-beam-started-at" value={@factory.control.runtime_identity[:beam_started_at]} /> · PID <%= @factory.control.runtime_identity[:os_pid] || "unknown" %></dd>
                </div>
                <div>
                  <dt>Factory BEAM artifact fingerprint</dt>
                  <dd class="mono" title={@factory.control.runtime_identity[:factory_beam_fingerprint]}>
                    <%= String.slice(@factory.control.runtime_identity[:factory_beam_fingerprint] || "", 0, 16) %>
                    · <%= @factory.control.runtime_identity[:factory_beam_module_count] || 0 %> modules
                    <span class="muted">Code-path artifact observation at control-server initialization; not deployment proof.</span>
                  </dd>
                </div>
              </dl>
            </details>
          </article>

          <article :if={@factory[:broker]} class="section-card broker-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Desktop Broker</h2>
                <p class="section-copy">Codex task handoffs in the durable request ledger. Automation heartbeat is not measured here.</p>
              </div>
              <span class={broker_badge_class(broker_request_status(@factory.broker))}>
                <%= broker_request_status(@factory.broker) %>
              </span>
            </div>

            <dl class="control-summary">
              <div>
                <dt>Pending</dt>
                <dd class="numeric"><%= @factory.broker.pending %></dd>
              </div>
              <div>
                <dt>Claimed / unverified (not worker activity)</dt>
                <dd class="numeric"><%= @factory.broker.claimed_unverified %></dd>
              </div>
              <div :if={Map.has_key?(@factory.broker, :uncertain)}>
                <dt>Outcome uncertain</dt>
                <dd class="numeric"><%= @factory.broker.uncertain %></dd>
              </div>
              <div>
                <dt>Unresolved reconciliation records (including warnings)</dt>
                <dd class="numeric"><%= @factory.broker.needs_reconciliation %></dd>
              </div>
              <div :if={Map.has_key?(@factory.broker, :blocking_attention)}>
                <dt>Blocking or unclassified handoff attention</dt>
                <dd class="numeric"><%= @factory.broker.blocking_attention %></dd>
              </div>
              <div :if={Map.has_key?(@factory.broker, :communication_warnings)}>
                <dt>Non-blocking communication warnings</dt>
                <dd class="numeric"><%= @factory.broker.communication_warnings %></dd>
              </div>
            </dl>
            <p :if={(@factory.broker[:communication_warnings] || 0) > 0} class="section-copy">Saved chat-update warnings are retained for reconciliation; they do not block ticket delivery.</p>
            <p class="section-copy broker-last-completed">
              Last completed request:
              <.local_time id="broker-last-completed-at" value={@factory.broker.last_completed_at} />
            </p>
          </article>

          <article class="section-card capacity-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Shared capacity</h2>
                <p class="section-copy">All repository routes share this machine, disk, and concurrency budget.</p>
              </div>
              <span :if={@shared_capacity} class={capacity_badge_class(capacity_health(@shared_capacity))}>
                <%= capacity_health(@shared_capacity) |> humanize_factory_code() %>
              </span>
            </div>

            <div class="table-wrap capacity-table-wrap">
              <table class="data-table responsive-table capacity-table">
                <thead>
                  <tr>
                    <th>Scope</th>
                    <th>Free disk</th>
                    <th>Writers</th>
                    <th>Specifications</th>
                    <th>Validation</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@shared_capacity}>
                    <td data-label="Scope">All repositories</td>
                    <td data-label="Free disk"><%= format_gb(@shared_capacity[:free_gb]) %></td>
                    <td data-label="Writers"><%= format_slots(@shared_capacity, :available_writer_slots, :maximum_writers) %></td>
                    <td data-label="Specifications"><%= format_slots(@shared_capacity, :available_specifier_slots, :maximum_specifiers) %></td>
                    <td data-label="Validation"><%= format_slots(@shared_capacity, :available_validator_slots, :maximum_validators) %></td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="repository-routes">
              <span>Repository routes</span>
              <ul>
                <li :for={repository <- @repository_keys}><%= repository %></li>
              </ul>
            </div>
          </article>
        </section>

        </details>

        <details
          id="factory-task-history"
          class="diagnostics-panel history-panel"
          phx-hook="PersistentDisclosure"
        >
          <summary>
            <span>
              <strong>Task history and factory events</strong>
              <small><%= @factory.counts.visible_tasks %> visible worker tasks · open chats, inspect failures, or trace ledger activity.</small>
            </span>
            <span class="disclosure-label">
              <span class="disclosure-closed-label">Show history</span>
              <span class="disclosure-open-label">Hide history</span>
            </span>
          </summary>

          <div class="diagnostics-content">
            <section class="diagnostic-section factory-task-history">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Codex tasks</h2>
                  <p class="section-copy">Persistent worker and review tasks created for ticket workflows.</p>
                </div>
                <span class="state-badge"><%= @factory.counts.visible_tasks %> visible</span>
              </div>

              <p :if={@factory.tasks == []} class="empty-state">No worker tasks recorded yet.</p>
              <div :if={@factory.tasks != []} class="table-wrap">
                <table class="data-table responsive-table factory-task-table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Role</th>
                      <th>Status</th>
                      <th>Model</th>
                      <th>Failure</th>
                      <th>Codex task</th>
                      <th>Updated</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={task <- @factory.tasks}>
                      <td data-label="Issue">
                        <strong><%= task.issue_key || "n/a" %></strong>
                      </td>
                      <td data-label="Role">
                        <div class="detail-stack">
                          <strong><%= humanize_factory_code(task.role) %></strong>
                          <span class="muted"><%= humanize_factory_code(task.stage) %></span>
                        </div>
                      </td>
                      <td data-label="Status">
                        <span class={state_badge_class(if Map.get(task, :handoff_attention), do: "NEEDS_ATTENTION", else: task.status)}>
                          <%= humanize_factory_code(if Map.get(task, :handoff_attention), do: "NEEDS_ATTENTION", else: task.status) %>
                        </span>
                      </td>
                      <td data-label="Model">
                        <div class="detail-stack">
                          <span><%= task.model || "n/a" %></span>
                          <span class="muted"><%= task.reasoning_effort || "n/a" %> effort</span>
                        </div>
                      </td>
                      <td data-label="Failure" class="task-failure">
                        <div :if={Map.get(task, :handoff_attention)} class="detail-stack danger-text">
                          <strong><%= task.handoff_attention.label %></strong>
                          <span><%= task.handoff_attention.reason %></span>
                        </div>
                        <span :if={task.failure_code && !Map.get(task, :handoff_attention)} class="danger-text"><%= task_failure_summary(task.failure_code) %></span>
                        <span :if={!task.failure_code && !Map.get(task, :handoff_attention)} class="muted">—</span>
                      </td>
                      <td data-label="Codex task">
                        <div :if={task.thread_id} class="inline-actions">
                          <a class="subtle-link" href={codex_thread_url(task.thread_id)}>Open task</a>
                          <.copy_button value={task.thread_id} label="Copy ID" />
                        </div>
                        <span :if={!task.thread_id} class="muted"><%= task_without_thread_label(task.status) %></span>
                      </td>
                      <td data-label="Updated">
                        <.local_time id={"task-#{task.task_key}-updated-at"} value={task.updated_at} />
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section class="diagnostic-section">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Recent factory events</h2>
                  <p class="section-copy">Newest state changes recorded in the durable ledger.</p>
                </div>
              </div>

              <p :if={@factory.recent_events == []} class="empty-state">No events recorded yet.</p>
              <div :if={@factory.recent_events != []} class="event-list">
                <div :for={event <- @factory.recent_events} class="event-row">
                  <span><.local_time id={"event-#{event.id}-occurred-at"} value={event.occurred_at} /></span>
                  <strong title={event.event_type}><%= event_label(event.event_type) %></strong>
                  <span><%= event.issue_key || event.run_id || "controller" %></span>
                </div>
              </div>
            </section>
          </div>
        </details>
        <%= render_slot(@runtime) %>
        </section>
      <% else %>
        <section class="error-card">
          <%= if Map.get(@factory, :disabled, false) do %>
            <h2 class="error-title">Factory disabled</h2>
            <p class="error-copy">Factory ticket workflows are disabled by configuration.</p>
            <p class="error-copy">Ordinary factory: <%= config_flag(@factory[:ordinary_factory_enabled]) %> · Ticket supervisor: <%= config_flag(@factory[:ticket_supervisor_enabled]) %> (defaults to disabled).</p>
          <% else %>
            <h2 class="error-title">Factory snapshot unavailable</h2>
            <p class="error-copy"><%= @factory.error.message %></p>
          <% end %>
        </section>
        <section class="operations-group"><header><h2>Operations &amp; history</h2></header><%= render_slot(@runtime) %></section>
      <% end %>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:value, :any, default: nil)

  defp local_time(assigns) do
    ~H"""
    <%= if is_binary(@value) && String.trim(@value) != "" do %>
      <time id={@id} datetime={@value} data-local-time={@value} phx-hook="LocalTime" title={@value}>
        <%= @value %>
      </time>
    <% else %>
      <span id={@id}>n/a</span>
    <% end %>
    """
  end

  attr(:value, :string, required: true)
  attr(:label, :string, required: true)

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      class="subtle-button"
      data-label={@label}
      data-copy={@value}
      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
    ><%= @label %></button>
    """
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active", "pass", "ready", "delivered"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["attention", "blocked", "error", "failed", "degraded", "ambiguous", "invalid", "paused"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry", "required"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp schedule_payload_refresh do
    Process.send_after(self(), :payload_refresh, @payload_refresh_ms)
  end

  defp blocking_attention?(attention) when is_map(attention), do: Map.get(attention, :blocking, true)
  defp blocking_attention?(_attention), do: false
  defp controller_blocking_attention?(control) when is_map(control), do: blocking_attention?(Map.get(control, :handoff_attention))
  defp controller_blocking_attention?(_control), do: false

  defp task_without_thread_label(status) when status in ["FAILED", "BLOCKED", "CANCELLED"],
    do: "Not created"

  defp task_without_thread_label(_status), do: "Pending"

  defp codex_thread_url(thread_id), do: "codex://threads/#{URI.encode(thread_id)}"

  defp config_flag(true), do: "enabled"
  defp config_flag(false), do: "disabled"
  defp config_flag(_value), do: "unknown"
  defp artifact_availability(%{availability: availability}), do: humanize_factory_code(availability)
  defp artifact_availability(%{"availability" => availability}), do: humanize_factory_code(availability)
  defp artifact_availability(_artifact), do: "not recorded"

  defp format_gb(value) when is_number(value), do: "#{value} GB"
  defp format_gb(_value), do: "n/a"

  defp shared_capacity(factory), do: List.first(factory[:capacity] || [])

  defp capacity_health(%{result: "PASS"}), do: "AVAILABLE"
  defp capacity_health(%{result: "INSUFFICIENT_WRITER_CAPACITY"}), do: "LIMITED"
  defp capacity_health(_capacity), do: "UNKNOWN"

  defp capacity_badge_class("AVAILABLE"), do: "state-badge state-badge-active"
  defp capacity_badge_class("LIMITED"), do: "state-badge state-badge-warning"
  defp capacity_badge_class(_health), do: "state-badge"

  defp broker_request_status(%{blocking_attention: count}) when count > 0, do: "Needs attention"
  defp broker_request_status(%{blocking_attention: 0, communication_warnings: count}) when count > 0, do: "Communication warning"

  defp broker_request_status(%{needs_reconciliation: count} = broker) when count > 0,
    do: if(Map.has_key?(broker, :blocking_attention), do: "Unknown", else: "Needs attention")

  defp broker_request_status(%{uncertain: count}) when count > 0, do: "Outcome uncertain"
  defp broker_request_status(%{claimed_unverified: count}) when count > 0, do: "Claimed"
  defp broker_request_status(%{pending: count}) when count > 0, do: "Pending"
  defp broker_request_status(_broker), do: "Unknown"

  defp broker_badge_class("Needs attention"), do: "state-badge state-badge-danger"
  defp broker_badge_class("Communication warning"), do: "state-badge state-badge-warning"
  defp broker_badge_class(_status), do: "state-badge"

  defp factory_operability(%{factory: %{available: true} = factory}) do
    cond do
      factory_controller_health(factory.control) != "ACTIVE" -> "stopped"
      broker_reconciliation_required?(factory) -> "stopped"
      broker_without_requests?(factory) -> "unknown"
      capacity_health(shared_capacity(factory)) == "AVAILABLE" -> "ready"
      capacity_health(shared_capacity(factory)) == "LIMITED" -> "limited"
      true -> "unknown"
    end
  end

  defp factory_operability(_payload), do: "unknown"

  defp broker_reconciliation_required?(%{broker: %{blocking_attention: count}}), do: count > 0
  defp broker_reconciliation_required?(%{broker: %{needs_reconciliation: count}}), do: count > 0
  defp broker_reconciliation_required?(_factory), do: false

  defp broker_without_requests?(%{broker: %{claimed_unverified: claimed, pending: pending}}),
    do: claimed == 0 and pending == 0

  defp broker_without_requests?(_factory), do: false

  defp workspace_label("MATERIALIZED"), do: "Worktree present"
  defp workspace_label("HIBERNATED"), do: "Worktree hibernated"
  defp workspace_label("CODEX_NATIVE"), do: "Codex workspace"
  defp workspace_label("UNMATERIALIZED"), do: "Not prepared"
  defp workspace_label(nil), do: "Not prepared"
  defp workspace_label(state), do: humanize_factory_code(state)

  defp format_slots(capacity, available_key, maximum_key) do
    case {capacity[available_key], capacity[maximum_key]} do
      {available, maximum} when is_integer(available) and is_integer(maximum) -> "#{available} / #{maximum}"
      _other -> "n/a"
    end
  end

  defp repository_keys(capacities) do
    capacities
    |> Enum.map(& &1[:repo_key])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp filtered_tickets(tickets, "ALL"), do: tickets
  defp filtered_tickets(tickets, bucket), do: Enum.filter(tickets, &(&1.bucket == bucket))

  defp ticket_buckets(payload) do
    overview = get_in(payload, [:factory, :overview]) || %{}

    [
      {"NEEDS_ATTENTION", "Needs attention", overview[:needs_attention] || 0},
      {"ACTIVE", "In progress", overview[:active] || 0},
      {"QUEUED", "Intake backlog", if(intake_available?(payload[:factory] || %{}), do: overview[:queued] || 0, else: "Unknown")},
      {"VALIDATION_PENDING", "Awaiting validation", validation_count(payload[:factory] || %{})},
      {"REVIEW_READY", "Ready for review", overview[:review_ready] || 0}
    ]
  end

  defp intake_available?(factory), do: get_in(factory, [:intake, :available]) == true && is_nil(get_in(factory, [:intake, :error]))

  defp intake_read_error(factory) do
    case get_in(factory, [:intake, :error]) do
      %{message: message} -> message
      error -> inspect(error)
    end
  end

  defp validation_count(factory), do: Enum.count(get_in(factory, [:overview, :by_issue]) || %{}, fn {_key, bucket} -> bucket == "VALIDATION_PENDING" end)
  defp bucket_label("ALL"), do: "all snapshot tickets"
  defp bucket_label("NEEDS_ATTENTION"), do: "Needs attention"
  defp bucket_label("ACTIVE"), do: "In progress"
  defp bucket_label("QUEUED"), do: "Intake backlog"
  defp bucket_label("REVIEW_READY"), do: "Ready for review"
  defp bucket_label("VALIDATION_PENDING"), do: "Awaiting validation"
  defp bucket_label(_bucket), do: "Unrecognized classification"

  defp ticket_dom_id(key), do: "ticket-" <> Base.url_encode64(key, padding: false)
  defp ticket_context(ticket), do: get_in(ticket, [:run, :ticket_context]) || %{}
  defp ticket_title(ticket), do: get_in(ticket, [:intake, :summary]) || get_in(ticket, [:run, :summary]) || "Title not recorded in this snapshot"
  defp ticket_issue_url(ticket), do: get_in(ticket, [:run, :issue_url]) || get_in(ticket, [:intake, :issue_url])
  defp ticket_updated(ticket), do: get_in(ticket, [:run, :updated_at]) || get_in(ticket, [:intake, :updated_at])
  defp ticket_mr(ticket), do: external_issue_url(get_in(ticket, [:run, :mr_url]))

  defp ticket_chat(ticket) do
    case ticket_context(ticket) do
      %{available: true, parent_thread_id: id} when is_binary(id) and id != "" -> codex_thread_url(id)
      _other -> nil
    end
  end

  defp ticket_questions(ticket), do: ticket_context(ticket)[:questions] || []

  defp ticket_suggested_prompt(ticket) do
    case ticket_context(ticket)[:suggested_prompt] do
      %{kind: "TICKET_CHAT_SUGGESTED_PROMPT_V1", body: body} when is_binary(body) and byte_size(body) in 1..12_288 ->
        if String.valid?(body) and String.trim(body) != "" and ticket_chat(ticket), do: body

      _ ->
        nil
    end
  end

  defp ticket_responsibility(%{run: %{review_stop: %{owner: owner}}}), do: owner

  defp ticket_responsibility(%{run: run} = ticket) when is_map(run) do
    current_question =
      ticket_context(ticket)[:available] == true and
        Enum.any?(ticket_questions(ticket), fn question ->
          is_map(question) and question["binding"] == "CURRENT" and is_binary(question["question_key"]) and question["question_key"] != ""
        end)

    cond do
      get_in(run, [:attention, :source]) == "BROKER" -> "Factory · MR handoff needs attention"
      run[:state] == "READY_FOR_REVIEW" and ticket_mr(ticket) -> "Human review"
      run[:state] == "AWAITING_CONTRACT_INPUT" and current_question -> "Human decision"
      run[:failure_code] == "CI_REPAIR_EXHAUSTED" -> "Human decision"
      get_in(run, [:attention, :phase]) == "REPAIR_QUEUED" -> "Factory · automatic CI repair"
      run[:state] == "CI_WAITING" and get_in(run, [:attention, :blocking]) != true -> "Factory · CI observation"
      run[:state] == "REPAIRING" and get_in(run, [:attention, :blocking]) != true -> "Factory · repair"
      get_in(run, [:worker_execution, :running_proven]) === true -> "Factory · recorded observation, not a current heartbeat"
      true -> nil
    end
  end

  defp ticket_responsibility(_ticket), do: nil

  defp ticket_phase(%{run: %{attention: %{phase: "REPAIR_QUEUED"}}}), do: "Queued for repair"
  defp ticket_phase(%{run: run}) when is_map(run), do: if(run[:review_stop], do: "Review stopped", else: humanize_factory_code(run[:state]))
  defp ticket_phase(%{diagnostics: [_ | _]}), do: "Current record unproven"
  defp ticket_phase(_ticket), do: "Intake observed"
  defp ticket_stage(%{run: %{attention: %{phase: "REPAIR_QUEUED"}}}), do: "Build"
  defp ticket_stage(%{run: run}) when is_map(run), do: if(run[:review_stop], do: "Verify", else: workflow_stage(run[:state]))
  defp ticket_stage(%{run_records: [_ | _]}), do: nil
  defp ticket_stage(%{intake: issue}) when is_map(issue), do: "Intake"
  defp ticket_stage(_ticket), do: nil
  defp ticket_activity(%{run: %{state: "ADMITTING_WRITER"}}), do: "Preparing the checkout and writer admission; no running worker is implied."
  defp ticket_activity(%{run: run}) when is_map(run), do: worker_execution_label(get_in(run, [:worker_execution, :status]))
  defp ticket_activity(_ticket), do: "No worker activity is established by this intake record."

  defp ticket_activity_summary(%{run: %{state: "ADMITTING_WRITER"}}), do: "Preparing to start"
  defp ticket_activity_summary(%{run: %{attention: %{phase: "REPAIR_QUEUED"}}}), do: "Repair queued · no human action needed"
  defp ticket_activity_summary(%{run: %{state: "CI_WAITING"}}), do: "Waiting for CI results"
  defp ticket_activity_summary(%{run: %{state: "REPAIRING"}}), do: "Repairing findings"

  defp ticket_activity_summary(%{run: run}) when is_map(run) do
    case get_in(run, [:worker_execution, :status]) do
      "WAITING" -> "No current worker turn recorded"
      "STOPPED" -> "Stopped / result recorded"
      "STARTING" -> "Worker admission recorded"
      "TURN_BOUND" -> "Worker turn recorded; live activity not measured"
      "RECONCILE_REQUIRED" -> "Outcome needs reconciliation"
      "NOT_APPLICABLE" -> "No source-worker activity implied"
      _other -> "Worker activity unconfirmed"
    end
  end

  defp ticket_activity_summary(_ticket), do: "No worker activity established"

  defp ticket_action(%{diagnostics: [_ | _]}), do: "Inspect the conflicting or missing snapshot records."

  defp ticket_action(%{run: run} = ticket) when is_map(run),
    do:
      run[:primary_next_action] || ticket_attention(ticket)[:next_action] ||
        if(ticket_chat(ticket), do: "Open the ticket chat for recorded guidance.", else: "Inspect the recorded delivery evidence; no ticket chat is bound.")

  defp ticket_action(%{intake: issue}) when is_map(issue) do
    cond do
      issue[:admission_error] -> "Resolve the recorded intake admission issue."
      is_nil(issue[:repo_key]) -> "Configure repository routing before work can start."
      issue[:classification] == "SPECIFICATION" -> "Specification is required before implementation."
      true -> "Await normal scheduling; the last poll does not prove current eligibility."
    end
  end

  defp ticket_action(_ticket), do: "Inspect snapshot diagnostics; current work is unproven."

  defp ticket_blocker(ticket) do
    ticket_attention(ticket)[:reason] || if(is_nil(ticket.run), do: intake_error(ticket))
  end

  defp intake_error(ticket) do
    case get_in(ticket, [:intake, :admission_error]) do
      error when is_map(error) -> Enum.join(Enum.reject([error[:code], error[:message]], &is_nil/1), ": ")
      _other -> nil
    end
  end

  defp ticket_attention(ticket) do
    attention = get_in(ticket, [:run, :attention])
    if blocking_attention?(attention), do: attention, else: get_in(ticket, [:run, :handoff_attention]) || %{}
  end

  defp ticket_signals(ticket) do
    (get_in(ticket, [:run, :attention_signals]) || [])
    |> Enum.reject(&blocking_attention?/1)
  end

  defp communication_warning?(ticket), do: ticket_signals(ticket) != []
  defp ticket_mark(%{bucket: "NEEDS_ATTENTION"}), do: "status-mark mark-attention"
  defp ticket_mark(%{bucket: "REVIEW_READY"}), do: "status-mark mark-ready"
  defp ticket_mark(_ticket), do: "status-mark mark-neutral"

  defp validation_summary(%{required: required}) when required in [false, 0], do: "Not required"
  defp validation_summary(validation), do: humanize_factory_code(validation[:status] || "UNKNOWN")

  defp complete_ticket_evidence(ticket) do
    case Jason.encode(ticket, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(ticket, pretty: true, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp readable_ticket_error(ticket) do
    error = get_in(ticket, [:run, :last_error])
    readable = task_failure_summary(error)
    if readable != error, do: readable
  end

  defp scheduling_label(_payload, error) when not is_nil(error), do: "Unknown — snapshot stale"

  defp scheduling_label(payload, _error) do
    control = get_in(payload, [:factory, :control]) || %{}

    cond do
      scheduling_attention?(control) or broker_reconciliation_required?(payload[:factory] || %{}) -> "Needs attention"
      control[:status] == "PAUSED" -> "Paused — existing work may continue"
      true -> scheduling_observation(control)
    end
  end

  defp scheduling_attention?(control) do
    controller_blocking_attention?(control) || (control[:controller_writer_conflict_count] || 0) > 0 ||
      get_in(control, [:tick_health, :status]) == "FAILED"
  end

  defp scheduling_observation(%{tick_observation: %{status: "STALE"}}), do: "Stale"
  defp scheduling_observation(%{tick_observation: %{status: "IN_PROGRESS"}}), do: "Tick in progress"
  defp scheduling_observation(%{status: "ACTIVE", tick_observation: %{status: "FRESH"}}), do: "Enabled"
  defp scheduling_observation(_control), do: "Unknown"

  defp scheduling_tone(payload, error) do
    case scheduling_label(payload, error) do
      "Enabled" -> "mark-ready"
      "Needs attention" -> "mark-attention"
      _other -> "mark-neutral"
    end
  end

  defp workflow_stage(state)
       when state in ~w(PLANNING SPECIFYING SPEC_DRAFTING CONTRACT_DISCUSSING SPEC_WRITING AWAITING_JIRA_READBACK SPEC_REVIEW CRITIQUING SPEC_READY_WRITE AWAITING_CONFIRMATION AWAITING_SPEC_INPUT AWAITING_CONTRACT_INPUT),
       do: "Specify"

  defp workflow_stage(state) when state in ~w(ADMITTING_WRITER WRITING REPAIRING REVIEW_WRITING), do: "Build"
  defp workflow_stage("VERIFYING"), do: "Verify"
  defp workflow_stage("READY_FOR_REVIEW"), do: "Review"
  defp workflow_stage(state) when state in ~w(PUSHING CI_PUSHING REVIEW_PUSHING MR_CREATING CI_MR_CREATING), do: "Publish"
  defp workflow_stage(state) when state in ~w(CI_WAITING AWAITING_VALIDATION TESTING), do: "Validate"
  defp workflow_stage(_state), do: nil

  defp worker_execution_label("WAITING"), do: "Waiting for worker; no current native turn recorded."
  defp worker_execution_label("TURN_BOUND"), do: "Native turn bound; live activity unconfirmed."
  defp worker_execution_label("STARTING"), do: "Worker admission recorded; no current native turn yet."
  defp worker_execution_label("STOPPED"), do: "Worker stopped or result recorded; not actively writing."
  defp worker_execution_label("RECONCILE_REQUIRED"), do: "Worker outcome needs reconciliation."
  defp worker_execution_label("NOT_APPLICABLE"), do: "This stage does not imply a running source worker."
  defp worker_execution_label(_), do: "Worker execution unknown; no current activity proven."

  defp summarize_error(error) when is_binary(error) do
    summary = error |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(summary) > 180 do
      String.slice(summary, 0, 177) <> "..."
    else
      summary
    end
  end

  defp summarize_error(error), do: inspect(error)

  defp task_failure_summary(error) when is_binary(error) do
    cond do
      String.contains?(error, "factory_stage_output_invalid_json") ->
        "Worker returned text instead of the required structured result."

      String.contains?(error, "factory_stage_output_not_an_object") ->
        "Worker result was valid JSON, but it was not the required object."

      String.contains?(error, "factory_stage_output_missing") ->
        "Worker finished without returning the required structured result."

      true ->
        summarize_error(error)
    end
  end

  defp task_failure_summary(error), do: summarize_error(error)

  defp event_label("RUN_REGISTERED"), do: "Workflow started"
  defp event_label("RUN_UPDATED"), do: "Workflow updated"
  defp event_label("MODEL_ROUTE_RECORDED"), do: "Model selected"
  defp event_label("WORKTREE_HIBERNATED"), do: "Workspace hibernated"
  defp event_label(event_type), do: humanize_factory_code(event_type)

  defp humanize_factory_code(nil), do: "n/a"

  defp humanize_factory_code(value) do
    string = to_string(value)

    if String.contains?(string, ["-", "_"]) or string == String.upcase(string) do
      string
      |> String.replace(~r/[-_]+/, " ")
      |> String.downcase()
      |> String.capitalize()
      |> String.replace(~r/\bCi\b/, "CI")
    else
      string
    end
  end

  defp factory_controller_health(%{snapshot_stale: true}), do: "STALE"
  defp factory_controller_health(%{status: "PAUSED"}), do: "PAUSED"
  defp factory_controller_health(%{tick_observation: %{status: "STALE"}}), do: "STALE"
  defp factory_controller_health(%{tick_observation: %{status: "UNKNOWN"}}), do: "UNKNOWN"
  defp factory_controller_health(%{tick_observation: %{status: "IN_PROGRESS"}}), do: "TICK_IN_PROGRESS"

  defp factory_controller_health(%{tick_health: %{status: "FAILED"}}), do: "ERROR"

  defp factory_controller_health(%{controller_writer_conflict_count: count}) when count > 0,
    do: "DEGRADED"

  defp factory_controller_health(%{tick_health: %{status: "UNKNOWN"}}), do: "STARTING"

  defp factory_controller_health(control), do: control.status

  defp lease_status(%{tick_id: nil}, _now), do: "Idle"

  defp lease_status(%{lease_expires_at: expires_at}, %DateTime{} = now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires, _offset} -> if DateTime.compare(expires, now) == :gt, do: "Held", else: "Expired"
      _other -> "Expired"
    end
  end

  defp lease_status(_control, _now), do: "Expired"

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
