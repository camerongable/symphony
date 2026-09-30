defmodule SymphonyElixir.FactoryContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Contract

  test "binds an exact contract through draft, confirmation, and authorization markers" do
    contract = Contract.bind("PPL-123", 2, "# Delivery contract\n\n- AC-1: works\n")
    draft = Contract.draft_comment(contract)

    snapshot = %{
      "comments" => [
        %{"id" => "10", "text" => draft},
        %{"id" => "11", "text" => Contract.confirmation_marker(contract)},
        %{"id" => "12", "text" => Contract.authorization_marker(contract, "11")}
      ]
    }

    assert Contract.draft_read_back?(snapshot, contract)
    assert {:ok, %{"id" => "11"}} = Contract.confirmation(snapshot, contract)
    assert Contract.authorized?(snapshot, contract)
    assert {:ok, ^contract} = Contract.authorized_from_snapshot(snapshot, "PPL-123")
    assert Contract.next_revision(snapshot) == 3
    assert byte_size(contract.sha256) == 64
  end

  test "accepts Jira's blank-line formatting only when the decoded contract remains exact" do
    contract = Contract.bind("PPL-9723", 2, "## Ticket Delivery Contract\n\n- AC-1: preserve bytes")
    draft = Contract.draft_comment(contract)

    jira_rendered =
      draft
      |> String.replace("\n```\n|", "\n\n```\n|")
      |> String.replace("\n```\nAI FACTORY CONTRACT END", "\n```\n\nAI FACTORY CONTRACT END")

    snapshot = %{"comments" => [%{"id" => "750753", "text" => jira_rendered}]}

    assert jira_rendered != draft
    assert Contract.draft_comment_equivalent?(draft, jira_rendered, contract.issue_key)
    assert Contract.draft_read_back?(snapshot, contract)

    altered = String.replace(jira_rendered, "preserve bytes", "change bytes")
    refute Contract.draft_comment_equivalent?(draft, altered, contract.issue_key)
    refute Contract.draft_read_back?(%{"comments" => [%{"text" => altered}]}, contract)
  end

  test "an independently reviewed contract can be authorized without a human confirmation comment" do
    contract = Contract.bind("PPL-123", 1, "# Delivery contract\n\n- AC-1: works")
    critic_task_key = "run-123:specification-critic:1"
    critic_digest = String.duplicate("a", 64)
    marker = Contract.automatic_authorization_marker(contract, critic_task_key, critic_digest)

    snapshot = %{
      "comments" => [
        %{"id" => "10", "text" => Contract.draft_comment(contract)},
        %{"id" => "11", "text" => marker}
      ]
    }

    assert Contract.authorized?(snapshot, contract)
    assert {:ok, ^contract} = Contract.authorized_from_snapshot(snapshot, "PPL-123")

    assert {:ok, %{critic_task_key: ^critic_task_key, critic_output_sha256: ^critic_digest}} =
             Contract.automatic_authorization_proof(snapshot, contract)

    conflicting =
      update_in(snapshot["comments"], &(&1 ++ [%{"text" => Contract.automatic_authorization_marker(contract, "other:critic:1", critic_digest)}]))

    assert {:error, :ambiguous_automatic_authorization} = Contract.automatic_authorization_proof(conflicting, contract)
    refute Contract.authorized?(put_in(snapshot["comments"], [%{"text" => Contract.draft_comment(contract)}]), contract)
  end

  test "a manually specified contract is authorized only by its exact skill marker" do
    contract = Contract.bind("PPL-10035", 2, "## Ticket Delivery Contract\n\n- AC-1: works")
    marker = Contract.specification_skill_authorization_marker(contract)

    snapshot = %{
      "comments" => [
        %{"id" => "10", "text" => Contract.draft_comment(contract)},
        %{"id" => "11", "text" => marker}
      ]
    }

    assert Contract.authorized?(snapshot, contract)
    assert {:ok, ^contract} = Contract.authorized_from_snapshot(snapshot, "PPL-10035")

    refute Contract.authorized?(put_in(snapshot, ["comments", Access.at(1), "text"], marker <> "-edited"), contract)
    refute Contract.authorized?(put_in(snapshot["comments"], [%{"text" => marker}]), contract)
  end

  test "description revision advances the next factory draft even before a marker exists" do
    snapshot = %{"description" => "## Ticket Delivery Contract\n\n**Spec revision:** 1\n", "comments" => []}

    assert Contract.next_revision(snapshot) == 2
    assert Contract.declared_revision("**Spec revision:** 2") == {:ok, 2}
    assert Contract.declared_revision("No revision yet") == :missing
    assert Contract.declared_revision("Spec revision: 1\nSpec revision: 2") == {:error, :ambiguous_spec_revision}
  end

  test "draft revision normalization changes only one carried-forward header" do
    prior = "## Ticket Delivery Contract\n\n**Spec revision:** 5\n\nAC-1: Keep revision 5 behavior."
    expected = "## Ticket Delivery Contract\n\n**Spec revision:** 6\n\nAC-1: Keep revision 5 behavior."

    assert Contract.normalize_draft_revision(prior, 6) == {:ok, expected}
    assert Contract.normalize_draft_revision(expected, 6) == {:ok, expected}

    for invalid <- [
          "**Spec revision:** 4",
          "**Spec revision:** 7",
          "**Spec revision:** 5\n**Spec revision:** 5",
          "AC-1 mentions Spec revision: 5 but has no header"
        ] do
      assert Contract.normalize_draft_revision(invalid, 6) == {:error, :contract_revision_mismatch}
    end
  end

  test "a malformed Jira comment cannot advance a real issue's contract revision" do
    invalid_marker =
      "AI FACTORY CONTRACT BEGIN issue=PPL-10035 revision=2 sha256=#{String.duplicate("a", 64)}"

    snapshot = %{
      "key" => "PPL-10035",
      "description" => "## Ticket Delivery Contract\n\n**Spec revision:** 1",
      "comments" => [%{"text" => invalid_marker}]
    }

    assert Contract.next_revision(snapshot) == 2

    valid = Contract.bind("PPL-10035", 2, "## Ticket Delivery Contract\n\n**Spec revision:** 2")
    assert Contract.next_revision(put_in(snapshot["comments"], [%{"text" => Contract.draft_comment(valid)}])) == 3
  end

  test "specification questions survive Jira fence formatting without changing their digest" do
    questions = ["Which notice should appear?", "Should the warning remain separate?"]
    request = Contract.input_request_comment("PPL-9723", questions)

    jira_rendered =
      request
      |> String.replace("\n```\n|", "\n\n```\n|")
      |> String.replace("\n```\nReply", "\n```\n\nReply")
      |> String.replace("your answers:\nAI FACTORY", "your answers:\n\nAI FACTORY")

    assert Contract.input_request_comment_equivalent?(request, jira_rendered, "PPL-9723")

    refute Contract.input_request_comment_equivalent?(
             request,
             String.replace(jira_rendered, "warning remain separate", "warning be reused"),
             "PPL-9723"
           )
  end

  test "fails closed when contract bytes or confirmation digest drift" do
    contract = Contract.bind("PPL-123", 1, "original")

    snapshot = %{
      comments: [
        %{id: "1", text: String.replace(Contract.draft_comment(contract), "original", "changed")},
        %{id: "2", text: "AI FACTORY CONFIRM #{String.duplicate("0", 64)}"}
      ]
    }

    refute Contract.draft_read_back?(snapshot, contract)
    assert Contract.confirmation(snapshot, contract) == :missing
    refute Contract.authorized?(snapshot, contract)
  end

  test "a newer contract or edited draft invalidates the previous authorization" do
    original = Contract.bind("PPL-123", 1, "original scope")
    revised = Contract.bind("PPL-123", 2, "revised scope")

    authorized = %{
      "comments" => [
        %{"text" => Contract.draft_comment(original)},
        %{"text" => Contract.authorization_marker(original, "11")}
      ]
    }

    assert {:ok, ^original} = Contract.authorized_from_snapshot(authorized, "PPL-123")

    newer_draft = update_in(authorized["comments"], &(&1 ++ [%{"text" => Contract.draft_comment(revised)}]))
    refute Contract.authorized?(newer_draft, original)
    assert {:error, :confirmed_authorization_missing} = Contract.authorized_from_snapshot(newer_draft, "PPL-123")

    edited_draft =
      update_in(authorized["comments"], fn [draft, authorization] ->
        [%{draft | "text" => String.replace(draft["text"], "original scope", "changed scope")}, authorization]
      end)

    refute Contract.authorized?(edited_draft, original)
    assert {:error, :confirmed_authorization_missing} = Contract.authorized_from_snapshot(edited_draft, "PPL-123")
  end

  test "conflicting drafts at one revision cannot reuse an authorization" do
    original = Contract.bind("PPL-123", 1, "original scope")
    conflicting = Contract.bind("PPL-123", 1, "different scope")

    snapshot = %{
      "comments" => [
        %{"text" => Contract.draft_comment(original)},
        %{"text" => Contract.authorization_marker(original, "11")},
        %{"text" => Contract.draft_comment(conflicting)}
      ]
    }

    refute Contract.authorized?(snapshot, original)
    assert {:error, :confirmed_authorization_missing} = Contract.authorized_from_snapshot(snapshot, "PPL-123")
  end

  test "parses the mandatory manual-validation decision" do
    assert Contract.manual_validation_required("# Contract\n\n## Manual Validation\n- Required: yes\n- Environment: cpp-test") ==
             {:ok, true}

    assert Contract.manual_validation_required("## Manual Validation\n- Required: no\n- Reason: unit-testable") ==
             {:ok, false}

    assert Contract.manual_validation_required("# No decision") ==
             {:error, :manual_validation_contract_missing}

    assert Contract.manual_validation_environment("## Manual Validation\n- Required: yes\n- Environment: cpp-test") == {:ok, "cpp-test"}

    assert Contract.manual_validation_environment("## Manual Validation\n- Required: no") == {:ok, nil}

    assert Contract.manual_validation_environment("## Manual Validation\n- Required: yes") ==
             {:error, :manual_validation_environment_missing}
  end

  test "manual-validation fields cannot be borrowed from later sections" do
    assert Contract.manual_validation_required("## Manual Validation\n- Environment: cpp-test\n\n## Rollout\n- Required: no") ==
             {:error, :manual_validation_contract_missing}

    assert Contract.manual_validation_environment("## Manual Validation\n- Required: yes\n\n### Rollout\n- Environment: cpp-test") ==
             {:error, :manual_validation_environment_missing}

    assert Contract.manual_validation_required("## Manual Validation\n- Required: yes\n- Required: no") ==
             {:error, :ambiguous_manual_validation_decision}

    assert Contract.manual_validation_environment("## Manual Validation\n- Required: yes\n- Environment: cpp-test\n- Environment: cpp-dev") ==
             {:error, :ambiguous_manual_validation_environment}
  end

  test "specification answers bind to the exact question digest" do
    questions = ["Which service owns the API?", "Must old clients remain compatible?"]
    digest = Contract.questions_digest(questions)
    marker = Contract.input_marker("PPL-123", digest)

    snapshot = %{
      "comments" => [
        %{"id" => "1", "text" => marker},
        %{"id" => "2", "text" => marker <> "\nThe document service owns it. Yes, compatibility is required."}
      ]
    }

    assert {:ok, %{"id" => "2"}} = Contract.specification_input(snapshot, "PPL-123", digest)
    assert :missing = Contract.specification_input(snapshot, "PPL-123", String.duplicate("0", 64))
  end
end
