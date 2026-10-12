defmodule SymphonyElixir.FactoryTicketAmendmentJiraOperationTest do
  use ExUnit.Case, async: false
  import SymphonyElixir.TicketChatFixture

  alias SymphonyElixir.Factory.{Contract, RunLedger, Store, TicketAmendmentJiraOperation}
  alias SymphonyElixir.Factory.{TicketChatCommands, TicketContractAmendment}

  defmodule Reader do
    def issue(issue_key, opts) do
      if opts[:mcp_session] != %{thread_id: "jira-fixture"}, do: raise("missing owned Jira session")

      reads = Process.get(:amendment_jira_reads, 0) + 1
      Process.put(:amendment_jira_reads, reads)

      if Process.get(:amendment_visible_after) == reads do
        Process.put(:amendment_jira_snapshot, Process.get(:amendment_pending_snapshot))
      end

      snapshot = Process.get(:amendment_jira_snapshot)
      if snapshot["key"] != issue_key, do: raise("foreign issue")

      if Process.get(:amendment_jira_read_error_on) == reads,
        do: {:error, :test_postwrite_readback_unavailable},
        else: {:ok, snapshot}
    end
  end

  defmodule Connector do
    alias SymphonyElixir.Factory.TicketAmendmentJiraOperation

    def validate_call("jira_add_comment", args, opts) do
      if opts[:mcp_session] != %{thread_id: "jira-fixture"}, do: raise("missing owned Jira session")
      if args != %{"issue_key" => "PPL-123", "body" => Process.get(:amendment_draft_body)}, do: raise("wrong Jira scope")

      case Process.get(:amendment_capability, :ok) do
        :ok ->
          send(self(), {:validated, args})
          maybe_reconcile_on_second_connection()
          :ok

        {:error, _} = error ->
          error
      end
    end

    defp maybe_reconcile_on_second_connection do
      if store = Process.get(:amendment_race_store) do
        Process.delete(:amendment_race_store)

        result =
          TicketAmendmentJiraOperation.publish_draft(
            store,
            Process.get(:amendment_race_command),
            Process.get(:amendment_race_context),
            Process.get(:amendment_race_opts)
          )

        Process.put(:amendment_nested_result, result)
      end
    end

    def call("jira_add_comment", args, opts) do
      if opts[:mcp_session] != %{thread_id: "jira-fixture"}, do: raise("missing owned Jira session")
      send(self(), {:jira_write, args})
      snapshot = Process.get(:amendment_jira_snapshot)
      dispatch_write_mode(Process.get(:amendment_jira_mode, :apply), args, snapshot)
    end

    defp dispatch_write_mode(mode, args, snapshot) do
      case mode do
        :lost_before_apply ->
          {:error, :timeout}

        :delayed_visibility ->
          Process.put(:amendment_pending_snapshot, append_draft(snapshot, args["body"], "draft-comment"))
          {:error, :timeout}

        :source_drift ->
          Process.put(:amendment_jira_snapshot, Map.put(snapshot, "description", "unrelated edit"))
          {:ok, %{"comment_id" => "draft-comment"}}

        :wrong_body ->
          Process.put(:amendment_jira_snapshot, append_draft(snapshot, "wrong contract draft", "draft-comment"))
          {:ok, %{"comment_id" => "draft-comment"}}

        :raise_on_write ->
          raise "injected Jira connector failure"

        :exit_on_write ->
          exit(:injected_jira_connector_exit)

        mode when mode in [:lost_after_apply, :apply] ->
          Process.put(:amendment_jira_snapshot, append_draft(snapshot, args["body"], "draft-comment"))
          if mode == :lost_after_apply, do: {:error, :timeout}, else: {:ok, %{"comment_id" => "draft-comment"}}
      end
    end

    defp append_draft(snapshot, body, id) do
      snapshot
      |> Map.update!("comments", &(&1 ++ [%{"id" => id, "text" => body}]))
      |> Map.put("updated", "2026-10-07T12:01:00Z")
    end
  end

  setup do
    ctx = setup_fixture(%{})
    runtime_fixture(ctx.root)
    source = normalized_source(ctx)
    Store.query!(ctx.store, "UPDATE runs SET snapshot_json = ? WHERE run_id = 'run'", [Jason.encode!(source)])
    {:ok, run} = RunLedger.get(ctx.store, "run")
    {:ok, ctx: ctx, source: source, run: run}
  end

  test "draft and authorization writes reject empty owned sessions before Jira access", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    protected_before = protected_rows(ctx)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])

    for invalid_session <- [%{}, %{thread_id: ""}] do
      opts = Keyword.put(operation_opts(ctx), :jira_session, fn _workspace, operation -> operation.(invalid_session) end)

      assert {:error, :amendment_jira_session_unproven} =
               TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, opts)

      assert {:error, :amendment_jira_session_unproven} =
               TicketAmendmentJiraOperation.publish_authorization(ctx.store, command["command_key"], context, critic_policy(), opts)

      assert Process.get(:amendment_jira_reads) == 0
      assert Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == nil
      assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
      assert protected_rows(ctx) == protected_before
      refute_received {:validated, _}
      refute_received {:jira_write, _}
    end
  end

  test "public draft readback reports a missing effect without mutating the reservation", %{ctx: ctx, source: source} do
    {command, _context, _body} = reserve_operation(ctx, source)
    before = protected_rows(ctx)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])

    assert {:error, :amendment_jira_effect_missing} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])

    assert Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == nil
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
    assert protected_rows(ctx) == before
    assert Process.get(:amendment_jira_reads) == 0
    refute_received {:jira_write, _}
  end

  test "first source read adopts an already-visible exact draft without connector calls", %{ctx: ctx, source: source} do
    {command, context, body} = reserve_operation(ctx, source)

    visible =
      source
      |> Map.update!("comments", &(&1 ++ [%{"id" => "first-read-draft", "text" => body}]))
      |> Map.put("updated", "2026-10-07T12:01:00Z")

    Process.put(:amendment_jira_snapshot, visible)
    protected_before = protected_rows(ctx)

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "first-read-draft"} = effect} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    assert effect["readback_json"] == Jason.encode!(visible)
    assert Process.get(:amendment_jira_reads) == 1
    assert Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == effect
    assert protected_rows(ctx) == protected_before
    refute_received {:validated, _}
    refute_received {:jira_write, _}
  end

  test "unrelated initial source drift rejects before creating a draft effect", %{ctx: ctx, source: source} do
    assert_initial_preflight_rejection(ctx, Map.put(source, "description", "initial unrelated edit"))
  end

  test "initial non-list comments reject before creating a draft effect", %{ctx: ctx, source: source} do
    assert_initial_preflight_rejection(ctx, Map.put(source, "comments", %{"unexpected" => "comment collection"}))
  end

  test "a raised connector write remains uncertain and retry never writes again", %{ctx: ctx, source: source} do
    assert_connector_failure_is_uncertain(ctx, source, :raise_on_write)
  end

  test "an exiting connector write remains uncertain and retry never writes again", %{ctx: ctx, source: source} do
    assert_connector_failure_is_uncertain(ctx, source, :exit_on_write)
  end

  test "public readback rejects null and non-object stored snapshots without repairing receipts", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    assert {:ok, original} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert_received {:validated, _}
    assert_received {:jira_write, _}
    read_count = Process.get(:amendment_jira_reads)

    for malformed <- ["[]", nil] do
      Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET readback_json = ? WHERE command_key = ?", [malformed, command["command_key"]])
      corrupted = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
      protected_before = protected_rows(ctx)
      events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows

      assert {:error, :amendment_jira_snapshot_invalid} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
      assert Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == corrupted
      assert protected_rows(ctx) == protected_before
      assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before
      assert Process.get(:amendment_jira_reads) == read_count
      refute_received {:jira_write, _}

      Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET readback_json = ? WHERE command_key = ?", [original["readback_json"], command["command_key"]])
      assert {:ok, ^original} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    end
  end

  test "exact draft comment is claimed once and a fresh source readback becomes the critic receipt", %{ctx: ctx, source: source} do
    {:ok, command} = accept_proposal(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    context = amendment_context(ctx, run)
    {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    body = Contract.draft_comment(Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"]))
    Process.put(:amendment_jira_snapshot, source)
    Process.put(:amendment_draft_body, body)
    before = protected_rows(ctx)

    assert {:ok, effect} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert effect["phase"] == "READ_BACK"
    assert effect["comment_id"] == "draft-comment"
    assert effect["draft_body"] == body
    assert effect["readback_sha256"] == digest(effect["readback_json"])
    assert {:ok, receipt} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    assert receipt["readback_json"] == effect["readback_json"]
    assert protected_rows(ctx) == before
    assert {:ok, attempt} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, receipt["readback_json"], critic_policy())
    assert attempt["snapshot_json"] == receipt["readback_json"]
    assert_received {:validated, %{"issue_key" => "PPL-123", "body" => ^body}}
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}
    assert Map.drop(protected_rows(ctx), [:tasks]) == Map.drop(before, [:tasks])
    assert {:ok, after_run} = RunLedger.get(ctx.store, "run")
    assert after_run["state"] == "READY_FOR_REVIEW"
    assert after_run["candidate_sha"] == before.run["candidate_sha"]
  end

  test "lost acknowledgement after application is read back without a second write after reopen", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_mode, :lost_after_apply)

    assert {:ok, %{"phase" => "READ_BACK"} = effect} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert effect["comment_id"] == "draft-comment"
    assert_received {:jira_write, _}
    assert Process.get(:amendment_jira_reads) == 2
    GenServer.stop(ctx.store)
    {:ok, reopened} = Store.start_link(database: ctx.database)

    try do
      assert {:ok, %{"phase" => "READ_BACK"} = replayed} =
               TicketAmendmentJiraOperation.publish_draft(
                 reopened,
                 command["command_key"],
                 context,
                 operation_opts(ctx)
               )

      assert replayed["readback_json"] == effect["readback_json"]
      refute_received {:jira_write, _}
      assert Process.get(:amendment_jira_reads) == 3
    after
      GenServer.stop(reopened)
    end
  end

  test "lost acknowledgement before application remains UNCERTAIN and never resends", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_mode, :lost_before_apply)

    assert {:error, :amendment_jira_outcome_uncertain} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    assert Store.one!(ctx.store, "SELECT phase, last_error FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == %{
             "phase" => "UNCERTAIN",
             "last_error" => "amendment_jira_draft_not_observed"
           }

    Process.put(:amendment_jira_mode, :apply)
    assert {:error, :amendment_jira_outcome_uncertain} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert_received {:jira_write, _}
    refute_received {:jira_write, _}
    assert Process.get(:amendment_jira_reads) == 3
  end

  test "post-write readback failure remains UNCERTAIN and retry reads the same draft without resending", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_read_error_on, 2)
    protected_before = protected_rows(ctx)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])

    assert {:error, :amendment_jira_readback_unavailable} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    uncertain =
      Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])

    assert uncertain["phase"] == "UNCERTAIN"
    assert uncertain["last_error"] == ":test_postwrite_readback_unavailable"
    assert Process.get(:amendment_jira_reads) == 2
    assert_received {:jira_write, %{"body" => body}}
    assert body == Process.get(:amendment_draft_body)

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "draft-comment"} = readback} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    assert readback["readback_json"] == readback["observed_json"]
    assert Process.get(:amendment_jira_reads) == 3
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
    assert protected_rows(ctx) == protected_before
    refute_received {:jira_write, _}
  end

  test "a stale PENDING observation on a second ledger connection cannot claim twice", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    {:ok, other} = Store.start_link(database: ctx.database)
    Process.delete(:amendment_nested_result)
    Process.put(:amendment_race_store, other)
    Process.put(:amendment_race_command, command["command_key"])
    Process.put(:amendment_race_context, context)
    Process.put(:amendment_race_opts, operation_opts(ctx))

    try do
      assert {:error, :amendment_jira_outcome_uncertain} =
               TicketAmendmentJiraOperation.publish_draft(
                 ctx.store,
                 command["command_key"],
                 context,
                 operation_opts(ctx)
               )

      assert {:ok, %{"phase" => "READ_BACK"}} = Process.get(:amendment_nested_result)
      assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])["phase"] == "READ_BACK"
      assert_received {:jira_write, _}
      refute_received {:jira_write, _}
    after
      GenServer.stop(other)
    end
  end

  test "delayed visibility reconciles the same uncertain effect using reads only", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_mode, :delayed_visibility)
    Process.put(:amendment_visible_after, 3)

    assert {:error, :amendment_jira_outcome_uncertain} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])["phase"] == "UNCERTAIN"
    Process.put(:amendment_jira_mode, :apply)
    assert {:ok, %{"phase" => "READ_BACK"}} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert_received {:jira_write, _}
    refute_received {:jira_write, _}
    assert Process.get(:amendment_jira_reads) == 3
  end

  test "a changed source preimage after the write stays uncertain without resending", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_mode, :source_drift)

    assert {:error, :amendment_jira_outcome_uncertain} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    assert Store.one!(ctx.store, "SELECT phase, last_error FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == %{
             "phase" => "UNCERTAIN",
             "last_error" => "amendment_jira_preimage_changed"
           }

    assert {:error, :amendment_jira_reconciliation_required} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert_received {:jira_write, _}
    refute_received {:jira_write, _}
  end

  test "a mismatched proposal comment cannot produce a critic read-back receipt", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_mode, :wrong_body)

    assert {:error, :amendment_jira_outcome_uncertain} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    assert Store.one!(ctx.store, "SELECT phase, last_error FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == %{
             "phase" => "UNCERTAIN",
             "last_error" => "amendment_jira_preimage_changed"
           }

    assert {:error, _reason} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    assert {:error, _reason} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, "wrong receipt", critic_policy())
    assert_received {:jira_write, _}
    refute_received {:jira_write, _}
  end

  test "stored read-back receipt corruption is rejected by both readback and critic preparation", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    assert {:ok, effect} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    corrupted = effect["readback_json"] <> " "
    Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET readback_json = ?, readback_sha256 = ? WHERE command_key = ?", [corrupted, digest(corrupted), command["command_key"]])

    assert {:error, _reason} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    assert {:error, _reason} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, corrupted, critic_policy())
  end

  test "capability rejection leaves a retryable PENDING intent and validates again before claim", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_capability, {:error, :missing_comment_capability})

    assert {:error, :missing_comment_capability} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert Store.one!(ctx.store, "SELECT phase FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])["phase"] == "PENDING"
    refute_received {:jira_write, _}

    Process.put(:amendment_capability, :ok)
    assert {:ok, %{"phase" => "READ_BACK"}} = TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))
    assert_received {:jira_write, _}
    assert_received {:validated, _}
  end

  test "a PENDING draft intent adopts an exact already-visible comment with reads only", %{ctx: ctx, source: source} do
    {command, context, body} = reserve_operation(ctx, source)
    Process.put(:amendment_capability, {:error, :missing_comment_capability})

    assert {:error, :missing_comment_capability} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    pending = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    assert pending["phase"] == "PENDING"
    protected_before = protected_rows(ctx)
    visible = source |> Map.update!("comments", &(&1 ++ [%{"id" => "externally-visible-draft", "text" => body}])) |> Map.put("updated", "2026-10-07T12:01:00Z")
    Process.put(:amendment_jira_snapshot, visible)
    Process.put(:amendment_capability, :ok)

    assert {:ok, %{"phase" => "READ_BACK", "comment_id" => "externally-visible-draft"} = readback} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    identity_fields =
      ~w(command_key run_id chat_key generation input_key input_sha256 prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_markdown proposed_contract_sha256 issue_key issue_id draft_body draft_body_sha256 source_preimage_json source_preimage_sha256 publication_preimage_json preflight_json preflight_sha256)

    assert Map.take(readback, identity_fields) == Map.take(pending, identity_fields)
    assert readback["readback_json"] == Jason.encode!(visible)
    assert Process.get(:amendment_jira_reads) == 2
    refute_received {:validated, _}
    refute_received {:jira_write, _}

    assert protected_rows(ctx) == protected_before
  end

  test "unrelated source drift leaves the PENDING draft intent and records only the observation", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_capability, {:error, :missing_comment_capability})

    assert {:error, :missing_comment_capability} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    pending = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    protected_before = protected_rows(ctx)
    drifted = Map.put(source, "description", "unrelated source edit")
    Process.put(:amendment_jira_snapshot, drifted)

    assert {:error, :amendment_jira_preimage_changed} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    observed = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    assert observed["phase"] == "PENDING"
    assert observed["last_error"] == "amendment_jira_preimage_changed"
    assert observed["observed_json"] == Jason.encode!(drifted)

    assert Map.take(
             observed,
             ~w(command_key run_id chat_key generation input_key input_sha256 prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_markdown proposed_contract_sha256 issue_key issue_id draft_body draft_body_sha256 source_preimage_json source_preimage_sha256 publication_preimage_json preflight_json preflight_sha256)
           ) ==
             Map.take(
               pending,
               ~w(command_key run_id chat_key generation input_key input_sha256 prior_revision prior_contract_sha256 candidate_sha proposed_revision proposed_contract_markdown proposed_contract_sha256 issue_key issue_id draft_body draft_body_sha256 source_preimage_json source_preimage_sha256 publication_preimage_json preflight_json preflight_sha256)
             )

    assert Process.get(:amendment_jira_reads) == 2
    assert protected_rows(ctx) == protected_before
    refute_received {:validated, _}
    refute_received {:jira_write, _}
    assert Store.query!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts").rows == []
  end

  test "readback rejects an isolated preflight JSON corruption without creating critic or source effects", %{ctx: ctx, source: source} do
    {command, context, _body} = reserve_operation(ctx, source)
    Process.put(:amendment_capability, {:error, :missing_comment_capability})

    assert {:error, :missing_comment_capability} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    Store.query!(ctx.store, "UPDATE ticket_amendment_jira_effects SET preflight_json = '[]' WHERE command_key = ?", [command["command_key"]])
    corrupted = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    run_before = Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'")
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    protected_before = protected_rows(ctx)
    reads_before = Process.get(:amendment_jira_reads)

    assert {:error, :amendment_jira_effect_corrupt} = TicketAmendmentJiraOperation.readback(ctx.store, command["command_key"])
    assert {:error, :amendment_jira_effect_corrupt} = TicketContractAmendment.prepare_critic(ctx.store, command["command_key"], context, "[]", critic_policy())

    assert Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == corrupted
    assert Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'") == run_before
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
    assert protected_rows(ctx) == protected_before
    assert Store.query!(ctx.store, "SELECT * FROM ticket_contract_critic_attempts").rows == []
    assert Process.get(:amendment_jira_reads) == reads_before
    refute_received {:jira_write, _}
  end

  defp assert_initial_preflight_rejection(ctx, source) do
    {command, context, _body} = reserve_operation(ctx, source)
    protected_before = protected_rows(ctx)
    amendment_before = Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]])
    events_before = Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows

    assert {:error, :amendment_jira_preimage_changed} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    assert Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]]) == nil
    assert Store.one!(ctx.store, "SELECT * FROM ticket_contract_amendments WHERE command_key = ?", [command["command_key"]]) == amendment_before
    assert protected_rows(ctx) == protected_before
    assert Store.query!(ctx.store, "SELECT * FROM events WHERE run_id = 'run' ORDER BY id").rows == events_before
    assert Process.get(:amendment_jira_reads) == 1
    refute_received {:validated, _}
    refute_received {:jira_write, _}
  end

  defp assert_connector_failure_is_uncertain(ctx, source, mode) do
    {command, context, body} = reserve_operation(ctx, source)
    Process.put(:amendment_jira_mode, mode)
    protected_before = protected_rows(ctx)

    assert {:error, :amendment_jira_outcome_uncertain} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    uncertain = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    assert uncertain["phase"] == "UNCERTAIN"
    assert uncertain["last_error"] == "amendment_jira_draft_not_observed"
    assert Process.get(:amendment_jira_reads) == 2
    assert_received {:validated, %{"issue_key" => "PPL-123", "body" => ^body}}
    assert_received {:jira_write, %{"issue_key" => "PPL-123", "body" => ^body}}

    Process.put(:amendment_jira_mode, :apply)

    assert {:error, :amendment_jira_outcome_uncertain} =
             TicketAmendmentJiraOperation.publish_draft(ctx.store, command["command_key"], context, operation_opts(ctx))

    after_retry = Store.one!(ctx.store, "SELECT * FROM ticket_amendment_jira_effects WHERE command_key = ?", [command["command_key"]])
    identity_fields = ~w(command_key run_id chat_key generation input_key input_sha256 phase draft_body draft_body_sha256 publication_preimage_json)
    assert Map.take(after_retry, identity_fields) == Map.take(uncertain, identity_fields)
    assert after_retry["last_error"] == "amendment_jira_draft_not_observed"
    assert Process.get(:amendment_jira_reads) == 3
    assert protected_rows(ctx) == protected_before
    refute_received {:jira_write, _}
  end

  defp accept_proposal(ctx) do
    markdown = "Revised contract\n\n## Manual Validation\n- Required: no"
    body = "Revise the contract:\n" <> markdown
    operations = [%{"operation" => "propose_contract_revision", "markdown" => markdown}]
    {:ok, staged} = stage(ctx, "jira-draft", body, operations)
    native = native(ctx, [body])
    assert {:ok, %{receipts: [%{"status" => "ACCEPTED"}]}} = TicketChatCommands.admit_readback(ctx.store, "run", native)
    {:ok, Store.one!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE command_key = ?", [staged["command_key"]])}
  end

  defp normalized_source(ctx) do
    run = Store.one!(ctx.store, "SELECT snapshot_json FROM runs WHERE run_id = 'run'")
    snapshot = Jason.decode!(run["snapshot_json"])

    Map.merge(snapshot, %{
      "summary" => "Existing summary",
      "description" => "Existing description",
      "status" => "In Progress",
      "labels" => ["ai-ready"],
      "assignee" => nil,
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => [],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-10-07T12:00:00Z",
      "comments" => snapshot["comments"] |> Enum.with_index(1) |> Enum.map(fn {comment, index} -> Map.put_new(comment, "id", "old-comment-#{index}") end)
    })
  end

  defp operation_opts(ctx) do
    workspace = Path.join(ctx.root, "control")
    File.mkdir_p!(workspace)

    [
      workspace: workspace,
      jira_session: fn _workspace, operation -> operation.(%{thread_id: "jira-fixture"}) end,
      jira_reader: Reader,
      jira_connector: Connector
    ]
  end

  defp reserve_operation(ctx, source) do
    {:ok, command} = accept_proposal(ctx)
    Store.query!(ctx.store, "UPDATE runs SET state = 'READY_FOR_REVIEW' WHERE run_id = 'run'")
    {:ok, run} = RunLedger.get(ctx.store, "run")
    context = amendment_context(ctx, run)
    {:ok, amendment} = TicketContractAmendment.reserve(ctx.store, command["command_key"], context)
    body = Contract.draft_comment(Contract.bind("PPL-123", amendment["proposed_revision"], amendment["proposed_contract_markdown"]))
    Process.put(:amendment_jira_snapshot, source)
    Process.put(:amendment_draft_body, body)
    Process.put(:amendment_jira_reads, 0)
    Process.put(:amendment_jira_mode, :apply)
    Process.put(:amendment_visible_after, nil)
    Process.put(:amendment_capability, :ok)
    Process.delete(:amendment_race_store)
    Process.delete(:amendment_race_command)
    Process.delete(:amendment_race_context)
    Process.delete(:amendment_race_opts)
    {command, context, body}
  end

  defp amendment_context(ctx, run) do
    chat = Store.one!(ctx.store, "SELECT * FROM ticket_chats WHERE chat_key = ?", [ctx.chat["chat_key"]])

    %{
      "chat_key" => chat["chat_key"],
      "run_id" => run["run_id"],
      "binding" => %{
        "generation" => chat["generation"],
        "spec_revision" => run["spec_revision"],
        "contract_sha256" => run["contract_sha256"],
        "candidate_sha" => run["candidate_sha"]
      }
    }
  end

  defp protected_rows(ctx) do
    %{
      run: Store.one!(ctx.store, "SELECT * FROM runs WHERE run_id = 'run'"),
      tasks: Store.query!(ctx.store, "SELECT * FROM factory_tasks WHERE run_id = 'run' ORDER BY task_key").rows,
      access: Store.query!(ctx.store, "SELECT * FROM workspace_access WHERE run_id = 'run' ORDER BY reservation_key").rows,
      commands: Store.query!(ctx.store, "SELECT * FROM ticket_chat_commands WHERE run_id = 'run' ORDER BY command_key").rows,
      requests: Store.query!(ctx.store, "SELECT * FROM desktop_requests WHERE target_kind = 'TICKET_CHAT' ORDER BY request_key").rows
    }
  end

  defp critic_policy do
    %{
      "default_provider" => "openai",
      "providers" => %{"openai" => %{"standard" => "critic-model-v1"}},
      "roles" => %{"specification-critic" => %{"provider" => "openai", "model_class" => "standard", "reasoning_effort" => "high"}}
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
