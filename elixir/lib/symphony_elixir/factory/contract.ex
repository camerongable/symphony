defmodule SymphonyElixir.Factory.Contract do
  @moduledoc """
  Exact Jira markers and digest binding for self-contained delivery contracts.

  Authorization markers are accepted only when their digest matches the exact
  contract payload read back from Jira.
  """

  @begin_marker "AI FACTORY CONTRACT BEGIN"
  @end_marker "AI FACTORY CONTRACT END"
  @validation_fields [
    {"Environment", "environment"},
    {"Services", "services"},
    {"Setup and deploy", "setup_and_deploy"},
    {"Test data", "test_data"},
    {"Evidence", "evidence"},
    {"Teardown", "teardown"},
    {"Database migrations", "database_migrations"}
  ]

  @type bound_contract :: %{
          issue_key: String.t(),
          revision: pos_integer(),
          sha256: String.t(),
          markdown: String.t(),
          marker: String.t()
        }

  @doc "Binds exact Markdown bytes to an issue and monotonically increasing revision."
  @spec bind(String.t(), pos_integer(), String.t()) :: bound_contract()
  def bind(issue_key, revision, markdown)
      when is_binary(issue_key) and is_integer(revision) and revision > 0 and is_binary(markdown) do
    normalized = String.trim(markdown)
    sha256 = digest(normalized)

    marker = "#{@begin_marker} issue-hex=#{issue_hex(issue_key)} revision=#{revision} sha256=#{sha256}"

    %{
      issue_key: issue_key,
      revision: revision,
      sha256: sha256,
      markdown: normalized,
      marker: marker
    }
  end

  @doc "Returns a Jira comment containing the exact digest-bound draft contract."
  @spec draft_comment(bound_contract()) :: String.t()
  def draft_comment(contract) do
    literal =
      contract.markdown
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", &"| #{&1}")

    """
    #{contract.marker}
    ```
    #{literal}
    ```
    #{@end_marker} issue-hex=#{issue_hex(contract.issue_key)} revision=#{contract.revision} sha256=#{contract.sha256}
    """
    |> String.trim()
  end

  @doc "Returns the exact marker announcing a critic-approved contract for confirmation."
  @spec ready_marker(bound_contract()) :: String.t()
  def ready_marker(contract) do
    "AI FACTORY SPEC READY issue-hex=#{issue_hex(contract.issue_key)} revision=#{contract.revision} sha256=#{contract.sha256}"
  end

  @doc "Returns the human confirmation text required before `ai-ready`."
  @spec confirmation_marker(bound_contract()) :: String.t()
  def confirmation_marker(contract), do: "AI FACTORY CONFIRM #{contract.sha256}"

  @doc "Returns the immutable authorization record written after human confirmation."
  @spec authorization_marker(bound_contract(), String.t()) :: String.t()
  def authorization_marker(contract, confirmation_comment_id) do
    "AI FACTORY AUTHORIZED issue-hex=#{issue_hex(contract.issue_key)} revision=#{contract.revision} " <>
      "sha256=#{contract.sha256} confirmation-comment-id=#{confirmation_comment_id}"
  end

  @doc "Returns the audit marker for authorization by an independent critic PASS."
  @spec automatic_authorization_marker(bound_contract(), String.t(), String.t()) :: String.t()
  def automatic_authorization_marker(contract, critic_task_key, critic_output_sha256) do
    "AI FACTORY AUTHORIZED issue-hex=#{issue_hex(contract.issue_key)} revision=#{contract.revision} " <>
      "sha256=#{contract.sha256} mode=automatic critic-task-key=#{critic_task_key} " <>
      "critic-output-sha256=#{critic_output_sha256}"
  end

  @doc "Returns the authorization marker for a contract written by the interactive specify-work skill."
  @spec specification_skill_authorization_marker(bound_contract()) :: String.t()
  def specification_skill_authorization_marker(contract) do
    "AI FACTORY AUTHORIZED issue-hex=#{issue_hex(contract.issue_key)} revision=#{contract.revision} " <>
      "sha256=#{contract.sha256} mode=specify-work"
  end

  @doc "Extracts the unique automatic-authorization critic proof for this exact contract."
  @spec automatic_authorization_proof(map(), bound_contract()) :: {:ok, map()} | :none | {:error, atom()}
  def automatic_authorization_proof(snapshot, contract) do
    prefix = authorization_prefix_pattern(contract) <> "mode=automatic critic-task-key="

    pattern = ~r/\A#{prefix}([A-Za-z0-9:._-]+) critic-output-sha256=([0-9a-f]{64})\z/

    proofs =
      snapshot
      |> comments()
      |> Enum.flat_map(fn comment ->
        case Regex.run(pattern, String.trim(comment_text(comment))) do
          [_marker, task_key, digest] -> [%{critic_task_key: task_key, critic_output_sha256: digest}]
          _other -> []
        end
      end)
      |> Enum.uniq()

    case proofs do
      [] -> :none
      [proof] -> {:ok, proof}
      _many -> {:error, :ambiguous_automatic_authorization}
    end
  end

  @doc "Returns the stable digest for a set of unanswered specification questions."
  @spec questions_digest([String.t()]) :: String.t()
  def questions_digest(questions) when is_list(questions) do
    questions
    |> Enum.map(&String.trim/1)
    |> Jason.encode!()
    |> digest()
  end

  @doc "Returns the exact prefix a human uses to answer specification questions."
  @spec input_marker(String.t(), String.t()) :: String.t()
  def input_marker(issue_key, questions_sha256) do
    "AI FACTORY SPEC INPUT issue-hex=#{issue_hex(issue_key)} questions-sha256=#{questions_sha256}"
  end

  @doc "Formats a digest-bound question request without Jira-autolinkable issue keys."
  @spec input_request_comment(String.t(), [String.t()]) :: String.t()
  def input_request_comment(issue_key, questions) when is_binary(issue_key) and is_list(questions) do
    digest = questions_digest(questions)

    literal =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {question, index} -> "| #{index}. #{question}" end)

    """
    AI FACTORY SPEC INPUT REQUIRED issue-hex=#{issue_hex(issue_key)} questions-sha256=#{digest}
    ```
    #{literal}
    ```
    Reply in one Jira comment beginning with this exact first line, followed by your answers:
    #{input_marker(issue_key, digest)}
    """
    |> String.trim()
  end

  @doc "Proves the same exact questions despite Jira's blank-line fence formatting."
  @spec input_request_comment_equivalent?(String.t(), String.t(), String.t()) :: boolean()
  def input_request_comment_equivalent?(expected, actual, issue_key)
      when is_binary(expected) and is_binary(actual) and is_binary(issue_key) do
    case parse_input_request(expected, issue_key) do
      nil -> expected == actual
      request -> parse_input_request(actual, issue_key) == request
    end
  end

  @doc "Finds a non-empty human answer bound to the exact specification questions."
  @spec specification_input(map(), String.t(), String.t()) :: {:ok, map()} | :missing
  def specification_input(snapshot, issue_key, questions_sha256) do
    marker = input_marker(issue_key, questions_sha256)

    case Enum.find(comments(snapshot), fn comment ->
           text = String.trim(comment_text(comment))
           String.starts_with?(text, marker <> "\n") and String.trim_leading(text, marker <> "\n") != ""
         end) do
      nil -> :missing
      comment -> {:ok, comment}
    end
  end

  @doc "Checks that Jira read-back contains the exact digest-bound contract payload."
  @spec draft_read_back?(map(), bound_contract()) :: boolean()
  def draft_read_back?(snapshot, contract) do
    Enum.any?(comments(snapshot), &(parse_draft(comment_text(&1), contract.issue_key) == contract))
  end

  @doc "Allows Jira to reformat the draft wrapper without changing the contract payload."
  @spec draft_comment_equivalent?(String.t(), String.t(), String.t()) :: boolean()
  def draft_comment_equivalent?(expected, actual, issue_key)
      when is_binary(expected) and is_binary(actual) and is_binary(issue_key) do
    case parse_draft(expected, issue_key) do
      nil -> expected == actual
      contract -> parse_draft(actual, issue_key) == contract
    end
  end

  @doc "Finds an exact human confirmation comment for the bound digest."
  @spec confirmation(map(), bound_contract()) :: {:ok, map()} | :missing
  def confirmation(snapshot, contract) do
    marker = confirmation_marker(contract)

    case Enum.find(comments(snapshot), &(String.trim(comment_text(&1)) == marker)) do
      nil -> :missing
      comment -> {:ok, comment}
    end
  end

  @doc "Checks that Jira still contains and authorizes the latest exact contract."
  @spec authorized?(map(), bound_contract()) :: boolean()
  def authorized?(snapshot, contract) do
    prefix = authorization_prefix_pattern(contract)

    human_marker = ~r/\A#{prefix}confirmation[-_]comment[-_]id=[A-Za-z0-9-]+\z/

    automatic_marker =
      ~r/\A#{prefix}mode=automatic critic-task-key=[A-Za-z0-9:._-]+ critic-output-sha256=[0-9a-f]{64}\z/

    specification_skill_marker = ~r/\A#{prefix}mode=specify-work\z/

    draft_read_back?(snapshot, contract) and next_revision(snapshot) == contract.revision + 1 and
      unique_revision_digest?(snapshot, contract) and
      Enum.any?(comments(snapshot), fn comment ->
        text = String.trim(comment_text(comment))

        Regex.match?(human_marker, text) or Regex.match?(automatic_marker, text) or
          Regex.match?(specification_skill_marker, text)
      end)
  end

  @doc "Extracts the latest exact contract only when its authorization is current."
  @spec authorized_from_snapshot(map(), String.t()) :: {:ok, bound_contract()} | {:error, term()}
  def authorized_from_snapshot(snapshot, issue_key) do
    snapshot
    |> comments()
    |> Enum.flat_map(&(parse_draft(comment_text(&1), issue_key) |> List.wrap()))
    |> Enum.filter(&authorized?(snapshot, &1))
    |> Enum.sort_by(& &1.revision, :desc)
    |> case do
      [contract | _rest] -> {:ok, contract}
      [] -> {:error, :confirmed_authorization_missing}
    end
  end

  @doc "Reads the required yes/no value from the contract's Manual Validation section."
  @spec manual_validation_required(String.t()) :: {:ok, boolean()} | {:error, term()}
  def manual_validation_required(markdown) do
    with :ok <- validation_unquoted_header(markdown),
         {:ok, section} <- manual_validation_section(markdown) do
      case Regex.scan(~r/^- Required:[ \t]*(.*)$/im, section) do
        [[_match, value]] -> manual_validation_decision(value)
        [] -> {:error, :manual_validation_contract_missing}
        _many -> {:error, :ambiguous_manual_validation_decision}
      end
    end
  end

  @doc "Reads the fixed manual-validation environment when validation is required."
  @spec manual_validation_environment(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def manual_validation_environment(markdown) do
    case manual_validation_required(markdown) do
      {:ok, true} ->
        with {:ok, section} <- manual_validation_section(markdown) do
          extract_manual_validation_environment(section)
        end

      {:ok, false} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Reads bounded validation declarations as data, never executable actions or live evidence."
  @spec manual_validation_definition(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def manual_validation_definition(markdown) when is_binary(markdown) and byte_size(markdown) <= 1_048_576 do
    if String.valid?(markdown) do
      case manual_validation_required(markdown) do
        {:ok, false} -> {:ok, nil}
        {:ok, true} -> validation_definition(markdown)
        {:error, _} = error -> error
      end
    else
      {:error, :manual_validation_markdown_invalid}
    end
  end

  def manual_validation_definition(_markdown), do: {:error, :manual_validation_markdown_invalid}

  defp validation_unquoted_header(markdown) do
    case Regex.run(~r/^## Manual Validation[ \t]*\r?$/im, markdown, return: :index) do
      [{offset, _length}] ->
        prefix = binary_part(markdown, 0, offset)
        fence = prefix |> String.split("\n") |> Enum.reduce(nil, &validation_fence/2)

        with true <- is_nil(fence) or {:error, :manual_validation_format_unsupported},
             :ok <- validation_comment_prefix(prefix),
             {:ok, section} <- manual_validation_section(markdown) do
          validation_comment_section(section)
        end

      _ ->
        {:error, :manual_validation_contract_missing}
    end
  end

  defp validation_fence(line, fence) do
    case Regex.run(~r/\A {0,3}(`{3,}|~{3,})([^\r\n]*)\r?\z/, line) do
      [_, marker, _tail] when is_nil(fence) ->
        {String.first(marker), byte_size(marker)}

      [_, marker, tail] ->
        {character, length} = fence
        if String.first(marker) == character and byte_size(marker) >= length and String.trim(tail) == "", do: nil, else: fence

      _ ->
        fence
    end
  end

  defp validation_comment_prefix(prefix) do
    case prefix |> String.split("\n") |> Enum.reduce({nil, false, false}, &validation_prefix_line/2) do
      {nil, false, false} -> :ok
      _ -> {:error, :manual_validation_format_unsupported}
    end
  end

  defp validation_prefix_line(_line, {fence, comment_open, true}), do: {fence, comment_open, true}

  defp validation_prefix_line(line, {fence, comment_open, false}) when not is_nil(fence),
    do: {validation_fence(line, fence), comment_open, false}

  defp validation_prefix_line(line, {nil, true, false}), do: validation_prefix_comment_line(line, true)

  defp validation_prefix_line(line, {nil, false, false}) do
    case validation_fence(line, nil) do
      {_, _} = fence -> {fence, false, false}
      nil -> validation_prefix_comment_line(line, false)
    end
  end

  defp validation_prefix_comment_line(line, comment_open) do
    case validation_comment_tokens(line, comment_open) do
      {:ok, next_open} -> {nil, next_open, false}
      {:error, _} -> {nil, comment_open, true}
    end
  end

  defp validation_comment_section(section) do
    if Regex.match?(~r/<!--|-->/, section), do: {:error, :manual_validation_format_unsupported}, else: :ok
  end

  defp validation_comment_tokens(line, comment_open) do
    Regex.scan(~r/<!--|-->/, line)
    |> Enum.reduce_while({:ok, comment_open}, fn [token], {:ok, open} ->
      case {open, token} do
        {false, "<!--"} -> {:cont, {:ok, true}}
        {true, "-->"} -> {:cont, {:ok, false}}
        _ -> {:halt, {:error, :manual_validation_format_unsupported}}
      end
    end)
  end

  defp validation_definition(markdown) do
    with {:ok, section} <- manual_validation_section(markdown),
         true <- byte_size(section) <= 16_384 or {:error, :manual_validation_definition_too_large},
         :ok <- validation_format(section),
         {:ok, fields} <- validation_fields(section),
         true <- fields["environment"] in ~w(cpp-dev cpp-sandbox cpp-test) or {:error, :manual_validation_environment_not_supported},
         {:ok, cases} <- validation_cases(section),
         {:ok, services} <- validation_services(fields["services"]) do
      {:ok, fields |> Map.put("services", services) |> Map.put("cases", cases)}
    end
  end

  defp validation_format(section) do
    labels = ["Required", "Cases" | Enum.map(@validation_fields, &elem(&1, 0))] |> Enum.map_join("|", &Regex.escape/1)
    field = ~r/\A- (?:#{labels}):[^\r\n]*\r?\z/i
    case_line = ~r/\A- MV-[1-9][0-9]{0,8}:[^\r\n]*\r?\z/
    lines = String.split(section, "\n")

    if Enum.all?(lines, &(String.trim(&1) == "" or Regex.match?(field, &1) or Regex.match?(case_line, &1))),
      do: :ok,
      else: {:error, :manual_validation_format_unsupported}
  end

  defp validation_fields(section) do
    Enum.reduce_while(@validation_fields, {:ok, %{}}, fn {label, key}, {:ok, result} ->
      case validation_field(section, label) do
        {:ok, value} -> {:cont, {:ok, Map.put(result, key, value)}}
        _ -> {:halt, {:error, {:manual_validation_field_invalid, key}}}
      end
    end)
  end

  defp validation_field(section, label) do
    case Regex.scan(~r/^- #{Regex.escape(label)}:[ \t]*(.*)$/im, section) do
      [[_, value]] ->
        trimmed = String.trim(value)
        if bounded_declaration?(trimmed), do: {:ok, trimmed}, else: :invalid

      _ ->
        :invalid
    end
  end

  defp validation_cases(section) do
    cases =
      Regex.scan(~r/^- (MV-[1-9][0-9]*):[ \t]*(.*)$/m, section)
      |> Enum.map(fn [_, id, expectation] -> %{"id" => id, "expectation" => String.trim(expectation)} end)

    ids = Enum.map(cases, & &1["id"])

    if length(cases) in 1..20 and Enum.uniq(ids) == ids and Enum.all?(cases, &bounded_declaration?(&1["expectation"])) and validation_case_references?(section, ids),
      do: {:ok, cases},
      else: {:error, :manual_validation_cases_invalid}
  end

  defp validation_case_references?(section, ids) do
    case Regex.scan(~r/^- Cases:[ \t]*(.*)$/im, section) do
      [] -> true
      [[_, value]] -> value |> String.split(",") |> Enum.map(&String.trim/1) |> Kernel.==(ids)
      _ -> false
    end
  end

  defp validation_services(value) do
    services = value |> String.split(",") |> Enum.map(&String.trim/1)

    if length(services) in 1..8 and Enum.uniq(services) == services and Enum.all?(services, &Regex.match?(~r/\A[a-z][a-z0-9-]{0,63}\z/, &1)),
      do: {:ok, services},
      else: {:error, :manual_validation_services_invalid}
  end

  defp bounded_declaration?(value), do: byte_size(value) in 1..4096 and not String.contains?(value, <<0>>)

  defp manual_validation_section(markdown) when is_binary(markdown) do
    case Regex.scan(~r/^## Manual Validation[ \t]*\r?$\r?\n?(.*?)(?=^#+[ \t]+\S|\z)/ims, markdown) do
      [[_match, section]] -> {:ok, section}
      [] -> {:error, :manual_validation_contract_missing}
      _many -> {:error, :ambiguous_manual_validation_section}
    end
  end

  defp manual_validation_decision(value) do
    case value |> String.trim() |> String.downcase() do
      "yes" -> {:ok, true}
      "no" -> {:ok, false}
      _other -> {:error, :manual_validation_contract_missing}
    end
  end

  defp extract_manual_validation_environment(section) do
    case Regex.scan(~r/^- Environment:[ \t]*(.*)$/im, section) do
      [[_match, environment]] -> nonblank_environment(environment)
      [] -> {:error, :manual_validation_environment_missing}
      _many -> {:error, :ambiguous_manual_validation_environment}
    end
  end

  defp nonblank_environment(environment) do
    case String.trim(environment) do
      "" -> {:error, :manual_validation_environment_missing}
      value -> {:ok, value}
    end
  end

  @doc "Returns the next revision after the description and exact factory contract markers."
  @spec next_revision(map()) :: pos_integer()
  def next_revision(snapshot) do
    issue_key = Map.get(snapshot, "key") || Map.get(snapshot, :key)

    marker_revisions =
      snapshot
      |> comments()
      |> Enum.map(&comment_text/1)
      |> Enum.flat_map(&comment_revisions(&1, issue_key))

    description = Map.get(snapshot, "description") || Map.get(snapshot, :description) || ""
    revisions = marker_revisions ++ declared_revisions(description)
    maximum = Enum.max(revisions, fn -> 0 end)

    maximum + 1
  end

  @doc "Reads a unique declared specification revision from Markdown."
  @spec declared_revision(String.t()) :: {:ok, pos_integer()} | :missing | {:error, atom()}
  def declared_revision(markdown) when is_binary(markdown) do
    case Enum.uniq(declared_revisions(markdown)) do
      [] -> :missing
      [revision] -> {:ok, revision}
      _many -> {:error, :ambiguous_spec_revision}
    end
  end

  @doc "Canonicalizes a single carried-forward revision header before binding a new draft."
  @spec normalize_draft_revision(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_draft_revision(markdown, target_revision) when is_binary(markdown) and target_revision > 0 do
    declarations = Regex.scan(~r/Spec revision:\*{0,2}[ \t]*(\d+)/i, markdown)

    case declarations do
      [] ->
        {:ok, markdown}

      [[_match, revision]] ->
        normalize_single_revision(markdown, revision, target_revision)

      _other ->
        {:error, :contract_revision_mismatch}
    end
  end

  defp normalize_single_revision(markdown, revision, target_revision) do
    if revision == Integer.to_string(target_revision),
      do: {:ok, markdown},
      else: normalize_previous_revision_header(markdown, revision, target_revision)
  end

  defp normalize_previous_revision_header(markdown, revision, target_revision) do
    header = ~r/^([ \t]*(?:\*\*)?Spec revision:\*{0,2}[ \t]*)(\d+)([ \t]*)$/im

    if revision == Integer.to_string(target_revision - 1) and
         match?([[_line, _prefix, ^revision, _suffix]], Regex.scan(header, markdown)) do
      {:ok,
       Regex.replace(header, markdown, fn _line, prefix, _old, suffix ->
         "#{prefix}#{target_revision}#{suffix}"
       end)}
    else
      {:error, :contract_revision_mismatch}
    end
  end

  @doc "Computes a lowercase SHA-256 digest for exact normalized contract bytes."
  @spec digest(String.t()) :: String.t()
  def digest(markdown) when is_binary(markdown) do
    markdown
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp marker_revisions(text) do
    Regex.scan(~r/#{@begin_marker} (?:issue-hex=[0-9a-fA-F]+|issue=\S+) revision=(\d+) sha256=[0-9a-f]{64}/, text)
    |> Enum.flat_map(fn
      [_match, revision] ->
        case Integer.parse(revision) do
          {value, ""} -> [value]
          _other -> []
        end

      _other ->
        []
    end)
  end

  defp comment_revisions(text, issue_key) when is_binary(issue_key) and issue_key != "" do
    case parse_draft(text, issue_key) do
      %{revision: revision} -> [revision]
      nil -> []
    end
  end

  defp comment_revisions(text, _issue_key), do: marker_revisions(text)

  defp declared_revisions(markdown) when is_binary(markdown) do
    Regex.scan(~r/Spec revision:\*{0,2}\s*(\d+)/i, markdown)
    |> Enum.map(fn [_match, revision] -> String.to_integer(revision) end)
    |> Enum.filter(&(&1 > 0))
  end

  defp unique_revision_digest?(snapshot, contract) do
    issue = Regex.escape(contract.issue_key)
    hex = issue_hex(contract.issue_key)

    markers = [
      ~r/#{@begin_marker} issue-hex=(?i:#{hex}) revision=#{contract.revision} sha256=([0-9a-f]{64})/,
      ~r/#{@begin_marker} issue=#{issue} revision=#{contract.revision} sha256=([0-9a-f]{64})/
    ]

    digests =
      snapshot
      |> comments()
      |> Enum.flat_map(fn comment -> Enum.flat_map(markers, &Regex.scan(&1, comment_text(comment))) end)
      |> Enum.map(fn [_match, digest] -> digest end)
      |> Enum.uniq()

    digests == [contract.sha256]
  end

  defp parse_draft(text, issue_key) do
    hex = issue_hex(issue_key)

    regex =
      ~r/\A#{@begin_marker} issue-hex=(?i:#{hex}) revision=(\d+) sha256=([0-9a-f]{64})\n(?:[ \t]*\n)*```\n(.*?)\n```\n(?:[ \t]*\n)*#{@end_marker} issue-hex=(?i:#{hex}) revision=\1 sha256=\2\z/ms

    case Regex.run(regex, text) do
      [_match, revision_text, sha256, literal] ->
        with {revision, ""} <- Integer.parse(revision_text),
             {:ok, normalized} <- decode_literal(literal),
             true <- digest(normalized) == sha256 do
          %{
            issue_key: issue_key,
            revision: revision,
            sha256: sha256,
            markdown: normalized,
            marker: "#{@begin_marker} issue-hex=#{hex} revision=#{revision} sha256=#{sha256}"
          }
        else
          _other -> nil
        end

      _other ->
        parse_legacy_draft(text, issue_key)
    end
  end

  defp decode_literal(literal) do
    lines = String.split(literal, "\n", trim: false)

    if Enum.all?(lines, &String.starts_with?(&1, "| ")) do
      {:ok, lines |> Enum.map_join("\n", &String.replace_prefix(&1, "| ", "")) |> String.trim()}
    else
      {:error, :invalid_contract_literal}
    end
  end

  defp parse_input_request(text, issue_key) do
    hex = issue_hex(issue_key)

    regex =
      ~r/\AAI FACTORY SPEC INPUT REQUIRED issue-hex=#{hex} questions-sha256=([0-9a-f]{64})\n(?:[ \t]*\n)*```\n(.*?)\n```\n(?:[ \t]*\n)*Reply in one Jira comment beginning with this exact first line, followed by your answers:\n(?:[ \t]*\n)*AI FACTORY SPEC INPUT issue-hex=#{hex} questions-sha256=\1\z/ms

    case Regex.run(regex, text) do
      [_match, digest, literal] ->
        with {:ok, numbered} <- decode_literal(literal),
             {:ok, questions} <- decode_numbered_questions(numbered),
             true <- questions_digest(questions) == digest do
          %{digest: digest, questions: questions}
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp decode_numbered_questions(numbered) do
    questions = String.split(numbered, "\n")

    parsed =
      questions
      |> Enum.with_index(1)
      |> Enum.map(fn {line, index} -> parse_numbered_question(line, index) end)

    if parsed != [] and Enum.all?(parsed, &is_binary/1), do: {:ok, parsed}, else: {:error, :invalid_questions}
  end

  defp parse_numbered_question(line, index) do
    case Regex.run(~r/^(\d+)\. (.+)$/, line) do
      [_match, number_text, question] -> if(number_text == Integer.to_string(index), do: question)
      _other -> nil
    end
  end

  defp parse_legacy_draft(text, issue_key) do
    escaped_issue = Regex.escape(issue_key)

    regex =
      ~r/<!-- #{@begin_marker} issue=#{escaped_issue} revision=(\d+) sha256=([0-9a-f]{64}) -->\s*\n(.*?)\n<!-- #{@end_marker} issue=#{escaped_issue} revision=\1 sha256=\2 -->/ms

    case Regex.run(regex, text) do
      [_match, revision_text, sha256, markdown] ->
        with {revision, ""} <- Integer.parse(revision_text),
             normalized <- String.trim(markdown),
             true <- digest(normalized) == sha256 do
          %{
            issue_key: issue_key,
            revision: revision,
            sha256: sha256,
            markdown: normalized,
            marker: "<!-- #{@begin_marker} issue=#{issue_key} revision=#{revision} sha256=#{sha256} -->"
          }
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp comments(snapshot) do
    Map.get(snapshot, "comments") || Map.get(snapshot, :comments) || []
  end

  defp comment_text(comment) when is_map(comment) do
    Map.get(comment, "text") || Map.get(comment, :text) || ""
  end

  defp comment_text(_comment), do: ""

  defp authorization_prefix_pattern(contract) do
    "AI FACTORY AUTHORIZED issue-hex=(?i:#{issue_hex(contract.issue_key)}) " <>
      "revision=#{contract.revision} sha256=#{contract.sha256} "
  end

  defp issue_hex(issue_key), do: Base.encode16(issue_key, case: :upper)
end
