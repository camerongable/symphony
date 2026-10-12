defmodule SymphonyElixir.FactoryJiraMcpConnectorTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.JiraMcpConnector

  defmodule AppServer do
    def mcp_tool_catalog_in_session(session, server) do
      send(self(), {:catalog, session, server})
      Process.get(:catalog)
    end

    def call_mcp_tool_in_session(session, server, tool, args) do
      send(self(), {:tool, session, server, tool, args})
      Process.get(:response)
    end

    def call_mcp_tool(_workspace, _server, _tool, _args), do: raise("unexpected fallback session")
  end

  defp options, do: [workspace: "/controller", app_server: AppServer, mcp_session: %{thread_id: "owned"}]
  defp delta, do: %{"issue_key" => "PPL-123", "add_labels" => ["ai-review"], "remove_labels" => ["ai-running"]}

  defp atomic_tool do
    %{
      "annotations" => %{"readOnlyHint" => false},
      "inputSchema" => %{
        "type" => "object",
        "required" => ~w(issue_key add_labels remove_labels),
        "properties" => %{
          "issue_key" => %{"type" => "string"},
          "add_labels" => %{"type" => "array", "items" => %{"type" => "string"}},
          "remove_labels" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    }
  end

  test "atomic label calls use only the existing session and acknowledged exact issue" do
    Process.put(:catalog, {:ok, %{"jira_update_factory_labels" => atomic_tool()}})
    Process.put(:response, {:ok, %{"structuredContent" => %{"issue_key" => "PPL-123", "mutation_requested" => true}}})
    assert {:ok, %{"mutation_requested" => true}} = JiraMcpConnector.call("jira_update_factory_labels", delta(), options())
    assert_received {:catalog, %{thread_id: "owned"}, "Jira"}
    assert_received {:tool, %{thread_id: "owned"}, "Jira", "jira_update_factory_labels", args}
    assert args == delta()
    assert {:error, :jira_catalog_session_required} = JiraMcpConnector.call("jira_update_factory_labels", delta(), Keyword.delete(options(), :mcp_session))
    Process.put(:response, {:ok, %{"structuredContent" => %{"issue_key" => "PPL-999", "mutation_requested" => true}}})
    assert {:error, :jira_factory_labels_unproven} = JiraMcpConnector.call("jira_update_factory_labels", delta(), options())
  end

  test "mutation preflight qualifies capability but performs no tool call" do
    Process.put(:catalog, {:ok, %{"jira_update_factory_labels" => atomic_tool()}})
    assert :ok = JiraMcpConnector.validate_call("jira_update_factory_labels", delta(), options())
    assert {:error, :invalid_jira_factory_label_delta} = JiraMcpConnector.validate_call("jira_update_factory_labels", Map.put(delta(), "fields", %{}), options())
    assert {:error, :jira_catalog_session_required} = JiraMcpConnector.validate_call("jira_update_factory_labels", delta(), Keyword.delete(options(), :mcp_session))
    Process.put(:catalog, {:ok, %{}})
    args = %{"issue_key" => "PPL-123", "transition_id" => "11"}
    assert {:error, :jira_transition_catalog_unproven} = JiraMcpConnector.validate_call("jira_transition_issue", args, options())
    invalid = Map.put(args, "transition_id", nil)
    assert {:error, :jira_transition_unproven} = JiraMcpConnector.validate_call("jira_transition_issue", invalid, options())
    assert {:error, :jira_tool_not_allowed} = JiraMcpConnector.validate_call("arbitrary", %{}, options())
    refute_received {:tool, _, _, _, _}
  end

  test "missing, unsafe and malformed atomic schemas reject before mutation" do
    tool = atomic_tool()

    for bad <- [
          nil,
          Map.put(tool, "inputSchema", nil),
          put_in(tool, ["inputSchema", "properties"], []),
          put_in(tool, ["inputSchema", "required"], "wrong"),
          put_in(tool, ["annotations", "readOnlyHint"], true),
          put_in(tool, ["inputSchema", "properties", "add_labels"], "wrong")
        ] do
      Process.put(:catalog, {:ok, %{"jira_update_factory_labels" => bad}})
      assert {:error, :jira_atomic_labels_capability_unavailable} = JiraMcpConnector.call("jira_update_factory_labels", delta(), options())
    end

    Process.put(:catalog, {:ok, []})
    assert {:error, :jira_catalog_unproven} = JiraMcpConnector.catalog(options())
    refute_received {:tool, _, _, _, _}
  end

  test "installed append-comment schema qualifies only bounded fixed issue/body arguments without a mutation" do
    tool = %{
      "annotations" => %{"title" => "Add Comment", "destructiveHint" => false},
      "inputSchema" => %{
        "type" => "object",
        "required" => ~w(issue_key body),
        "properties" => %{"issue_key" => %{"type" => "string"}, "body" => %{"type" => "string"}, "visibility" => %{}, "public" => %{}}
      }
    }

    args = %{"issue_key" => "PPL-123", "body" => "Symphony: draft MR ready for review."}
    Process.put(:catalog, {:ok, %{"jira_add_comment" => tool}})
    assert :ok = JiraMcpConnector.validate_call("jira_add_comment", args, options())

    for invalid <- [Map.put(args, "public", true), Map.put(args, "visibility", "group"), Map.put(args, "body", ""), Map.put(args, "body", String.duplicate("x", 65_537))] do
      assert {:error, :invalid_jira_factory_comment} = JiraMcpConnector.validate_call("jira_add_comment", invalid, options())
    end

    for annotation <- [%{}, %{"destructiveHint" => true}, %{"destructiveHint" => false, "readOnlyHint" => true}, %{"destructiveHint" => false, "readOnlyHint" => nil}] do
      Process.put(:catalog, {:ok, %{"jira_add_comment" => Map.put(tool, "annotations", annotation)}})
      assert {:error, :jira_comment_catalog_unproven} = JiraMcpConnector.validate_call("jira_add_comment", args, options())
    end

    refute_received {:tool, _, _, _, _}
  end

  test "factory label scope cannot update arbitrary fields, labels or issue paths" do
    for args <- [
          Map.put(delta(), "fields", %{}),
          Map.put(delta(), "issue_key", "../PPL-123"),
          Map.put(delta(), "add_labels", ["ai-review", "ai-running"]),
          Map.put(delta(), "remove_labels", ["human-label"]),
          Map.put(delta(), "remove_labels", ["ai-running", "ai-running"]),
          Map.put(delta(), "add_labels", nil)
        ] do
      assert {:error, :invalid_jira_factory_label_delta} = JiraMcpConnector.call("jira_update_factory_labels", args, options())
    end

    refute_received {:catalog, _, _}
    refute_received {:tool, _, _, _, _}
  end

  test "available transitions are bounded reads with no fallback or unrelated list tool" do
    tool = %{"annotations" => %{"readOnlyHint" => true}, "inputSchema" => %{"type" => "object", "required" => ["issue_key"], "properties" => %{"issue_key" => %{"type" => "string"}}}}
    Process.put(:catalog, {:ok, %{"jira_get_transitions" => tool}})
    values = [%{"id" => "11", "to_status" => "In Dev"}]
    Process.put(:response, {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(values)}]}})
    assert {:ok, ^values} = JiraMcpConnector.call_list("jira_get_transitions", %{"issue_key" => "PPL-123"}, options())
    assert_received {:tool, _, "Jira", "jira_get_transitions", %{"issue_key" => "PPL-123"}}
    assert {:error, :jira_catalog_session_required} = JiraMcpConnector.call_list("jira_get_transitions", %{"issue_key" => "PPL-123"}, Keyword.delete(options(), :mcp_session))
    assert {:error, :jira_tool_not_allowed} = JiraMcpConnector.call_list("arbitrary", %{}, options())
    Process.put(:response, {:ok, %{"structuredContent" => List.duplicate(hd(values), 101)}})
    assert {:error, :jira_transitions_unproven} = JiraMcpConnector.call_list("jira_get_transitions", %{"issue_key" => "PPL-123"}, options())
    Process.put(:response, {:ok, %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 1_048_577)}]}})
    assert {:error, :jira_tool_result_too_large} = JiraMcpConnector.call_list("jira_get_transitions", %{"issue_key" => "PPL-123"}, options())
  end

  test "status transition permits only the observed numeric ID and no extra mutation fields" do
    tool = %{
      "annotations" => %{"readOnlyHint" => false},
      "inputSchema" => %{"type" => "object", "required" => ~w(issue_key transition_id), "properties" => %{"issue_key" => %{"type" => "string"}, "transition_id" => %{"type" => "string"}}}
    }

    Process.put(:catalog, {:ok, %{"jira_transition_issue" => tool}})
    Process.put(:response, {:ok, %{"content" => []}})
    args = %{"issue_key" => "PPL-123", "transition_id" => "11"}
    assert {:ok, %{}} = JiraMcpConnector.call("jira_transition_issue", args, options())
    assert_received {:tool, _, "Jira", "jira_transition_issue", ^args}
    installed = Map.put(tool, "annotations", %{"title" => "Transition Issue", "destructiveHint" => true})
    Process.put(:catalog, {:ok, %{"jira_transition_issue" => installed}})
    assert {:ok, %{}} = JiraMcpConnector.call("jira_transition_issue", args, options())
    assert_received {:tool, _, "Jira", "jira_transition_issue", ^args}

    for annotations <- [%{}, %{"destructiveHint" => false}, %{"readOnlyHint" => true, "destructiveHint" => true}, %{"readOnlyHint" => nil, "destructiveHint" => true}] do
      Process.put(:catalog, {:ok, %{"jira_transition_issue" => Map.put(tool, "annotations", annotations)}})
      assert {:error, :jira_transition_catalog_unproven} = JiraMcpConnector.call("jira_transition_issue", args, options())
    end

    assert {:error, :jira_transition_unproven} = JiraMcpConnector.call("jira_transition_issue", Map.put(args, "comment", "unapproved"), options())
    assert {:error, :jira_transition_unproven} = JiraMcpConnector.call("jira_transition_issue", Map.put(args, "transition_id", "guessed"), options())
    Process.put(:catalog, {:ok, %{"jira_transition_issue" => nil}})
    assert {:error, :jira_transition_catalog_unproven} = JiraMcpConnector.call("jira_transition_issue", args, options())
    refute_received {:tool, _, _, _, _}
  end
end
