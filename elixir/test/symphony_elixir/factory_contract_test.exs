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
