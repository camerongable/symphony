defmodule SymphonyElixir.FactoryContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Contract

  test "marker case tolerance never rewrites modern or legacy contract payloads before digest checking" do
    payload = "## Ticket Delivery Contract\nAI FACTORY AUTHORIZED issue-hex=ab revision=1 sha256=example"
    original = Contract.bind("PPL-9881", 3, payload)
    altered = Contract.bind("PPL-9881", 3, String.replace(payload, "issue-hex=ab", "issue-hex=AB"))

    legacy = """
    <!-- AI FACTORY CONTRACT BEGIN issue=PPL-9881 revision=3 sha256=#{original.sha256} -->
    #{payload}
    <!-- AI FACTORY CONTRACT END issue=PPL-9881 revision=3 sha256=#{original.sha256} -->
    """

    for draft <- [Contract.draft_comment(original), legacy] do
      authorization = Contract.specification_skill_authorization_marker(original)
      snapshot = %{"comments" => [%{"text" => draft}, %{"text" => authorization}]}
      assert {:ok, decoded} = Contract.authorized_from_snapshot(snapshot, "PPL-9881")
      assert decoded.markdown == payload
      assert decoded.sha256 == original.sha256

      tampered = String.replace(draft, original.sha256, altered.sha256)
      forged_marker = Contract.specification_skill_authorization_marker(altered)
      forged = %{"comments" => [%{"text" => tampered}, %{"text" => forged_marker}]}
      assert {:error, :confirmed_authorization_missing} = Contract.authorized_from_snapshot(forged, "PPL-9881")
    end
  end

  test "hexadecimal issue-marker casing does not change contract authorization or payload integrity" do
    contract = Contract.bind("PPL-9881", 3, "## Ticket Delivery Contract\n\n- Preserve accepted inputs")
    canonical = "issue-hex=" <> Base.encode16("PPL-9881")

    for hex <- ["50504c2d39383831", "50504C2d39383831", "50504C2D39383831"] do
      draft = String.replace(Contract.draft_comment(contract), canonical, "issue-hex=" <> hex)

      authorization =
        contract |> Contract.specification_skill_authorization_marker() |> String.replace(canonical, "issue-hex=" <> hex)

      snapshot = %{"comments" => [%{"text" => draft}, %{"text" => authorization}]}

      assert {:ok, ^contract} = Contract.authorized_from_snapshot(snapshot, "PPL-9881")
      assert Contract.draft_comment_equivalent?(Contract.draft_comment(contract), draft, "PPL-9881")
      assert {:error, :confirmed_authorization_missing} = Contract.authorized_from_snapshot(snapshot, "PPL-9882")
      altered_draft = String.replace(draft, "Preserve accepted inputs", "Changed inputs")
      changed = put_in(snapshot, ["comments"], [%{"text" => altered_draft}, %{"text" => authorization}])
      assert {:error, :confirmed_authorization_missing} = Contract.authorized_from_snapshot(changed, "PPL-9881")
    end
  end

  @validation_markdown """
  ## Manual Validation
  - Required: yes
  - MV-1: Submit a synthetic vote; expect two agreeing judges.
  - MV-2: Repeat without an override; expect the configured threshold.
  - Environment: cpp-test
  - Services: doc-extract, doc-extract-worker
  - Setup and deploy: Deploy the exact candidate using the approved controller action.
  - Test data: Synthetic non-PHI/PII fixture with cleanup identifier fixture-1.
  - Evidence: Keep the response and exact deployed image digest.
  - Teardown: Restore the previously observed images.
  - Database migrations: none
  ### Rollout
  - Services: not part of validation
  """

  test "required validation retains the exact declared cases and procedure without granting execution" do
    assert {:ok, definition} = Contract.manual_validation_definition(@validation_markdown)

    assert definition == %{
             "environment" => "cpp-test",
             "services" => ["doc-extract", "doc-extract-worker"],
             "cases" => [
               %{"id" => "MV-1", "expectation" => "Submit a synthetic vote; expect two agreeing judges."},
               %{"id" => "MV-2", "expectation" => "Repeat without an override; expect the configured threshold."}
             ],
             "setup_and_deploy" => "Deploy the exact candidate using the approved controller action.",
             "test_data" => "Synthetic non-PHI/PII fixture with cleanup identifier fixture-1.",
             "evidence" => "Keep the response and exact deployed image digest.",
             "teardown" => "Restore the previously observed images.",
             "database_migrations" => "none"
           }
  end

  test "ambiguous, hidden or incomplete required validation cannot yield partial declarations" do
    invalid = [
      String.replace(@validation_markdown, "- Services: doc-extract, doc-extract-worker", "- Services: doc-extract\n- services: doc-extract-worker"),
      String.replace(@validation_markdown, "- Evidence: Keep the response and exact deployed image digest.", "- Evidence: \r"),
      String.replace(@validation_markdown, "- MV-2:", "- MV-01:"),
      String.replace(@validation_markdown, "- MV-2:", "- MV-1:"),
      String.replace(@validation_markdown, "- MV-1:", "- MV-0:"),
      String.replace(@validation_markdown, "- MV-2:", "- MV-foo:"),
      String.replace(@validation_markdown, "- Services:", "  - Services:"),
      String.replace(@validation_markdown, "- Test data:", "```\n- Test data:"),
      String.replace(@validation_markdown, "- Teardown:", "    continue a prior declaration\n- Teardown:"),
      "```markdown\n" <> @validation_markdown <> "```\n",
      "~~~~markdown\n" <> @validation_markdown <> "~~~~\n",
      String.replace(@validation_markdown, "- Required: yes", "- Required: yes\n- Unknown action: deploy somewhere else")
    ]

    for markdown <- invalid do
      assert {:error, _} = Contract.manual_validation_definition(markdown)
    end
  end

  test "rejects a required validation section hidden inside an HTML comment" do
    commented = "<!--\n" <> String.trim(@validation_markdown)
    commented = String.replace(commented, "- Database migrations: none", "- Database migrations: none -->")

    assert {:error, :manual_validation_format_unsupported} = Contract.manual_validation_required(commented)
    assert {:error, _} = Contract.manual_validation_definition(commented)
  end

  test "rejects HTML comments that hide later validation fields" do
    commented =
      @validation_markdown
      |> String.replace("- Evidence: Keep the response and exact deployed image digest.", "- Evidence: Keep the response and exact deployed image digest. <!--")
      |> String.replace("- Database migrations: none", "- Database migrations: none -->")

    assert {:error, :manual_validation_format_unsupported} = Contract.manual_validation_required(commented)
    assert {:error, _} = Contract.manual_validation_definition(commented)
  end

  test "validation declarations bound environments, services and payload sizes before compilation" do
    for environment <- ["production", "cpp-prod", "staging", "cpp-test; deploy elsewhere"] do
      markdown = String.replace(@validation_markdown, "- Environment: cpp-test", "- Environment: #{environment}")
      assert {:error, :manual_validation_environment_not_supported} = Contract.manual_validation_definition(markdown)
    end

    for services <- ["", "doc-extract,", "doc-extract, doc-extract", "../doc-extract", "--help", "doc extract", String.duplicate("a", 65)] do
      markdown = String.replace(@validation_markdown, "doc-extract, doc-extract-worker", services)
      assert {:error, _} = Contract.manual_validation_definition(markdown)
    end

    oversized = String.replace(@validation_markdown, "Keep the response and exact deployed image digest.", String.duplicate("a", 4097))
    assert {:error, {:manual_validation_field_invalid, "evidence"}} = Contract.manual_validation_definition(oversized)
    oversized_section = String.replace(@validation_markdown, "### Rollout", String.duplicate("\n", 16_385) <> "### Rollout")
    assert {:error, :manual_validation_definition_too_large} = Contract.manual_validation_definition(oversized_section)
  end

  test "explicit case references must match the actual declarations, without requiring contiguous numbering" do
    markdown = String.replace(@validation_markdown, "- MV-2:", "- MV-7:")
    referenced = String.replace(markdown, "- Required: yes", "- Required: yes\n- Cases: MV-1, MV-7")
    assert {:ok, definition} = Contract.manual_validation_definition(referenced)
    assert Enum.map(definition["cases"], & &1["id"]) == ["MV-1", "MV-7"]

    for value <- ["MV-1, MV-2", "MV-7, MV-1", "MV-1, MV-7, MV-7", ""] do
      changed = String.replace(referenced, "- Cases: MV-1, MV-7", "- Cases: #{value}")
      assert {:error, :manual_validation_cases_invalid} = Contract.manual_validation_definition(changed)
    end
  end

  test "optional validation preserves the legacy skip while malformed required input never compiles" do
    assert {:ok, nil} = Contract.manual_validation_definition("## Manual Validation\n- Required: no\n- Reason: unit tests suffice")

    for markdown <- [nil, <<255>>, String.duplicate("a", 1_048_577), "no declaration", "## Manual Validation\n- Required: perhaps", "## Manual Validation\n- Required: no\n- Required: yes"] do
      assert {:error, _} = Contract.manual_validation_definition(markdown)
    end

    for environment <- ["cpp-dev", "cpp-sandbox", "cpp-test"] do
      changed = String.replace(@validation_markdown, "cpp-test", environment)
      assert {:ok, %{"environment" => ^environment}} = Contract.manual_validation_definition(changed)
    end

    for label <- ["Environment", "Services", "Setup and deploy", "Test data", "Evidence", "Teardown", "Database migrations"] do
      absent = Regex.replace(~r/^- #{Regex.escape(label)}:.*\n/m, @validation_markdown, "")
      assert {:error, _} = Contract.manual_validation_definition(absent)
    end

    without_cases = Regex.replace(~r/^- MV-[0-9]+:.*\n/m, @validation_markdown, "")
    assert {:error, :manual_validation_cases_invalid} = Contract.manual_validation_definition(without_cases)
    blank_case = String.replace(@validation_markdown, "Submit a synthetic vote; expect two agreeing judges.", "")
    assert {:error, :manual_validation_cases_invalid} = Contract.manual_validation_definition(blank_case)
    nul_case = String.replace(@validation_markdown, "Submit a synthetic vote; expect two agreeing judges.", <<0>>)
    assert {:error, :manual_validation_cases_invalid} = Contract.manual_validation_definition(nul_case)
    assert {:ok, _} = Contract.manual_validation_definition(String.replace(@validation_markdown, "\n", "\r\n"))
    prefix = "<!-- example -->\n## Examples\n````text\n```\n~~~~\n<!-- a literal HTML-comment example -->\n````\n"
    assert {:ok, _} = Contract.manual_validation_definition(prefix <> @validation_markdown)
  end

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
