defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Factory.Observability, as: FactoryObservability
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @payload_refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      schedule_payload_refresh()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  def handle_info(:payload_refresh, socket) do
    schedule_payload_refresh()

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :factory_operability, factory_operability(assigns.payload))

    ~H"""
    <section class="dashboard-shell" data-factory-operability={@factory_operability}>
      <header class="dashboard-header">
        <div>
          <p class="eyebrow">Symphony</p>
          <h1 class="hero-title">Software factory</h1>
          <p class="hero-copy">
            Follow Jira work from intake through agent execution, verification, and a draft merge request.
          </p>
        </div>

        <div class="status-cluster" aria-label="Dashboard status">
          <span class="status-badge status-badge-connected">
            <span class="status-badge-dot"></span>
            Dashboard connected
          </span>
          <span class="status-badge status-badge-offline">
            <span class="status-badge-dot"></span>
            Reconnecting
          </span>
          <span
            :if={@payload[:factory] && @payload.factory.available}
            class={state_badge_class(factory_controller_health(@payload.factory.control))}
          >
            Scheduler <%= String.downcase(factory_controller_health(@payload.factory.control)) %>
          </span>
          <span
            :if={@payload[:factory] && @payload.factory.available && @payload.factory[:broker]}
            class={broker_badge_class(broker_request_status(@payload.factory.broker))}
            title="Desktop request state only; the Codex automation heartbeat is not verified here."
          >
            <%= broker_status_label(broker_request_status(@payload.factory.broker)) %>
          </span>
          <span
            :if={@payload[:factory] && @payload.factory.available}
            class={capacity_badge_class(capacity_health(shared_capacity(@payload.factory)))}
            title="Availability for one more source-writing task; specification and validation slots are listed below."
          >
            Writer capacity <%= String.downcase(capacity_health(shared_capacity(@payload.factory))) %>
          </span>
        </div>
      </header>

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
        <section class="metric-grid overview-grid" aria-label="Factory overview">
          <article class="metric-card">
            <p class="metric-label">Active work</p>
            <p class="metric-value numeric"><%= active_work_count(@payload) %></p>
            <p class="metric-detail"><%= active_work_detail(@payload) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Jira queue</p>
            <p class="metric-value numeric"><%= factory_intake_count(@payload) %></p>
            <p class="metric-detail">Eligible tickets waiting for a worker.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Ready for review</p>
            <p class="metric-value numeric"><%= factory_review_ready(@payload) %></p>
            <p class="metric-detail">Draft merge requests ready for a human.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Needs attention</p>
            <p class="metric-value numeric"><%= attention_count(@payload) %></p>
            <p class="metric-detail"><%= attention_detail(@payload) %></p>
          </article>
        </section>
      <% end %>

      <.factory_dashboard :if={@payload[:factory]} factory={@payload.factory} now={@now} />

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
            <span class="disclosure-closed-label">Show details</span>
            <span class="disclosure-open-label">Hide details</span>
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

  defp factory_dashboard(assigns) do
    factory =
      assigns.factory
      |> update_in([:control], &Map.put_new(&1, :runtime_identity, %{}))
      |> update_in([:intake], &Map.put_new(&1, :stale, assigns.factory.control.status == "PAUSED"))

    assigns =
      assigns
      |> assign(:factory, factory)
      |> assign(:shared_capacity, List.first(factory[:capacity] || []))
      |> assign(:repository_keys, repository_keys(factory[:capacity] || []))
      |> assign(:current_runs, current_runs(factory[:runs] || []))

    ~H"""
    <section class="factory-workspace">
      <%= if @factory.available do %>
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

        <div class="workflow-heading">
          <div>
            <p class="eyebrow">Work</p>
            <h2>From Jira to review</h2>
          </div>
          <p>Tickets enter through Jira, become durable workflows, and finish as draft merge requests.</p>
        </div>

        <section class="section-card primary-section intake-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Jira intake</h2>
              <p class="section-copy">
                Factory-labelled tickets from the last successful Jira poll, including work already in progress.
                <span :if={@factory.intake.observed_at} class="snapshot-note">
                  Snapshot taken <.local_time id="intake-observed-at" value={@factory.intake.observed_at} />
                </span>
              </p>
              <p :if={@factory.intake.stale} class="section-copy factory-inline-error" data-intake-stale="true">
                Stale snapshot: polling is paused, so this saved intake may no longer match Jira.
              </p>
            </div>
            <span class="state-badge">
              <%= if @factory.intake.available, do: "#{@factory.intake.count} tracked", else: "Awaiting poll" %>
            </span>
          </div>

          <p :if={@factory.intake.error} class="factory-inline-error">
            Jira intake history could not be read: <%= @factory.intake.error.message %>
          </p>
          <p :if={!@factory.intake.available && !@factory.intake.error} class="empty-state">
            No successful Jira intake snapshot has been recorded yet.
          </p>
          <p :if={@factory.intake.available && @factory.intake.issues == []} class="empty-state">
            The last successful poll found no factory-labelled issues.
          </p>

          <div :if={@factory.intake.issues != []} class="table-wrap">
            <table class="data-table responsive-table factory-intake-table">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Ticket</th>
                  <th>Intent</th>
                  <th>Routing</th>
                  <th>Updated</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={issue <- @factory.intake.issues}>
                  <td data-label="Issue"><.issue_identifier identifier={issue.issue_key} url={issue.issue_url} /></td>
                  <td data-label="Ticket">
                    <div class="detail-stack factory-intake-summary">
                      <strong><%= issue.summary %></strong>
                      <span class="muted"><%= Enum.join(issue.labels, " · ") %></span>
                    </div>
                  </td>
                  <td data-label="Intent">
                    <div class="detail-stack">
                      <strong class="table-value"><%= humanize_factory_code(issue.classification) %></strong>
                      <span class="muted"><%= issue.status %> · <%= humanize_factory_code(issue.local_state) %></span>
                    </div>
                  </td>
                  <td data-label="Routing">
                    <div class="detail-stack">
                      <strong class="table-value"><%= issue.repo_key || humanize_factory_code(issue.routing_status) %></strong>
                      <span :if={issue.repo_key} class="muted"><%= humanize_factory_code(issue.routing_status) %></span>
                    </div>
                  </td>
                  <td data-label="Updated">
                    <.local_time id={"intake-#{issue.issue_key}-updated-at"} value={issue.updated_at} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card primary-section runs-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Ticket workflows</h2>
              <p class="section-copy">Durable work currently moving through specification, implementation, verification, and delivery.</p>
            </div>
            <span class="state-badge"><%= counted(length(@current_runs), "ticket") %></span>
          </div>

          <p :if={@current_runs == []} class="empty-state">No ticket workflows recorded yet.</p>
          <div :if={@current_runs != []} class="table-wrap">
            <table class="data-table responsive-table factory-runs-table">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Progress</th>
                  <th>Workspace</th>
                  <th>Delivery</th>
                  <th>Updated</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @current_runs}>
                  <td data-label="Issue"><.issue_identifier identifier={run.issue_key} url={run.issue_url} /></td>
                  <td data-label="Progress">
                    <div class="detail-stack">
                      <strong class={[
                        "ticket-status",
                        ticket_lifecycle(@factory, run) == "NEEDS_ATTENTION" && "danger-text"
                      ]}>
                        <%= humanize_factory_code(ticket_lifecycle(@factory, run)) %>
                      </strong>
                      <span class="muted">
                        <%= humanize_factory_code(run.state) %> · <%= humanize_factory_code(run.kind) %> · <%= run.repo_key || "Unrouted" %>
                      </span>
                      <a
                        :if={active_task_thread_id(run) && !contract_chat_thread_id(run)}
                        class="subtle-link"
                        href={codex_thread_url(active_task_thread_id(run))}
                      >Open active task</a>
                      <a
                        :if={contract_chat_thread_id(run)}
                        class="subtle-link"
                        href={codex_thread_url(contract_chat_thread_id(run))}
                      >Open contract chat</a>
                      <span :if={run.state == "AWAITING_CONTRACT_INPUT"} class="muted">
                        Answer the question in that Codex chat to continue this ticket.
                      </span>
                      <span :if={run.last_error} class="danger-text"><%= task_failure_summary(run.last_error) %></span>
                    </div>
                  </td>
                  <td data-label="Workspace">
                    <div class="detail-stack">
                      <strong class="table-value" title={"Recorded workspace state: #{run.workspace_state || "UNMATERIALIZED"}"}>
                        <%= workspace_label(run.workspace_state) %>
                      </strong>
                      <span :if={run.branch} class="muted"><%= run.branch %></span>
                      <span :if={run.candidate_sha} class="muted"><%= short_sha(run.candidate_sha) %></span>
                    </div>
                  </td>
                  <td data-label="Delivery">
                    <a :if={run.mr_url} class="subtle-link" href={run.mr_url} target="_blank" rel="noopener noreferrer">
                      Open MR <%= if run.mr_iid, do: "!#{run.mr_iid}", else: "" %>
                    </a>
                    <span :if={!run.mr_url} class="muted">Draft MR not created</span>
                  </td>
                  <td data-label="Updated">
                    <.local_time id={"run-#{run.run_id}-updated-at"} value={run.updated_at} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
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
                  <dt>Process started</dt>
                  <dd><.local_time id="factory-process-started-at" value={@factory.control.runtime_identity[:process_started_at]} /></dd>
                </div>
                <div>
                  <dt>Factory BEAM fingerprint</dt>
                  <dd class="mono" title={@factory.control.runtime_identity[:factory_beam_fingerprint]}>
                    <%= String.slice(@factory.control.runtime_identity[:factory_beam_fingerprint] || "", 0, 16) %>
                    · <%= @factory.control.runtime_identity[:factory_beam_module_count] || 0 %> modules
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
                <dt>Claimed</dt>
                <dd class="numeric"><%= @factory.broker.claimed_unverified %></dd>
              </div>
              <div>
                <dt>Needs reconciliation</dt>
                <dd class="numeric"><%= @factory.broker.needs_reconciliation %></dd>
              </div>
            </dl>
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
                        <span class={state_badge_class(task.status)}><%= humanize_factory_code(task.status) %></span>
                      </td>
                      <td data-label="Model">
                        <div class="detail-stack">
                          <span><%= task.model || "n/a" %></span>
                          <span class="muted"><%= task.reasoning_effort || "n/a" %> effort</span>
                        </div>
                      </td>
                      <td data-label="Failure" class="task-failure">
                        <span :if={task.failure_code} class="danger-text"><%= task_failure_summary(task.failure_code) %></span>
                        <span :if={!task.failure_code} class="muted">—</span>
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
      <% else %>
        <section class="error-card">
          <h2 class="error-title">Factory snapshot unavailable</h2>
          <p class="error-copy"><%= @factory.error.message %></p>
        </section>
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

  defp active_work_count(%{factory: %{available: true, overview: %{active: count}}}) when is_integer(count),
    do: count

  defp active_work_count(_payload), do: 0

  defp active_work_detail(payload) do
    counted(active_work_count(payload), "active ticket")
  end

  defp factory_intake_count(%{factory: %{available: true, overview: %{queued: count}}}) when is_integer(count),
    do: count

  defp factory_intake_count(_payload), do: 0

  defp factory_review_ready(%{factory: %{available: true, overview: %{review_ready: count}}})
       when is_integer(count),
       do: count

  defp factory_review_ready(_payload), do: 0

  defp attention_count(%{factory: %{available: true, overview: %{needs_attention: count}}})
       when is_integer(count),
       do: count

  defp attention_count(_payload), do: 0

  defp attention_detail(payload) do
    case attention_count(payload) do
      1 -> "1 ticket needs attention"
      count -> "#{count} tickets need attention"
    end
  end

  defp counted(1, singular), do: "1 #{singular}"
  defp counted(count, singular), do: "#{count} #{singular}s"

  defp task_without_thread_label(status) when status in ["FAILED", "BLOCKED", "CANCELLED"],
    do: "Not created"

  defp task_without_thread_label(_status), do: "Pending"

  defp codex_thread_url(thread_id), do: "codex://threads/#{URI.encode(thread_id)}"

  defp short_sha(nil), do: "n/a"
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  defp format_gb(value) when is_number(value), do: "#{value} GB"
  defp format_gb(_value), do: "n/a"

  defp shared_capacity(factory), do: List.first(factory[:capacity] || [])

  defp capacity_health(%{result: "PASS"}), do: "AVAILABLE"
  defp capacity_health(%{result: "INSUFFICIENT_WRITER_CAPACITY"}), do: "LIMITED"
  defp capacity_health(_capacity), do: "UNKNOWN"

  defp capacity_badge_class("AVAILABLE"), do: "state-badge state-badge-active"
  defp capacity_badge_class("LIMITED"), do: "state-badge state-badge-warning"
  defp capacity_badge_class(_health), do: "state-badge"

  defp broker_request_status(%{needs_reconciliation: count}) when count > 0, do: "Needs attention"
  defp broker_request_status(%{claimed_unverified: count}) when count > 0, do: "Claimed"
  defp broker_request_status(%{pending: count}) when count > 0, do: "Pending"
  defp broker_request_status(_broker), do: "Unknown"

  defp broker_badge_class("Needs attention"), do: "state-badge state-badge-danger"
  defp broker_badge_class(_status), do: "state-badge"

  defp broker_status_label("Needs attention"), do: "Broker needs attention"
  defp broker_status_label("Claimed"), do: "Broker request claimed"
  defp broker_status_label("Pending"), do: "Broker requests pending"
  defp broker_status_label(_status), do: "Broker status unknown"

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

  defp current_runs(runs) do
    runs
    |> Enum.uniq_by(& &1.issue_key)
    |> Enum.reject(&(&1.state in ["DELIVERED", "CANCELLED"]))
  end

  defp active_task_thread_id(%{tasks: tasks}) when is_list(tasks) do
    tasks
    |> Enum.find(&(&1.status in ["STARTING", "RUNNING"] && is_binary(&1.thread_id)))
    |> case do
      nil -> nil
      task -> task.thread_id
    end
  end

  defp active_task_thread_id(_run), do: nil

  defp contract_chat_thread_id(%{tasks: tasks}) when is_list(tasks) do
    tasks
    |> Enum.find(&(&1.stage == "CONTRACT_DISCUSSING" && is_binary(&1.thread_id)))
    |> case do
      nil -> nil
      task -> task.thread_id
    end
  end

  defp contract_chat_thread_id(_run), do: nil

  defp ticket_lifecycle(%{overview: %{by_issue: by_issue}}, run) when is_map(by_issue) do
    Map.get(by_issue, run.issue_key, run.state)
  end

  defp ticket_lifecycle(_factory, run), do: run.state

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

  defp factory_controller_health(%{controller_writer_conflict_count: count}) when count > 0,
    do: "DEGRADED"

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
