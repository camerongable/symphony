defmodule SymphonyElixir.Factory.Contract do
  @moduledoc """
  Exact Jira markers and digest binding for self-contained delivery contracts.

  The controller computes every digest. Agent-supplied hashes never authorize
  implementation.
  """

  @begin_marker "AI FACTORY CONTRACT BEGIN"
  @end_marker "AI FACTORY CONTRACT END"

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

    marker =
      "<!-- #{@begin_marker} issue=#{issue_key} revision=#{revision} sha256=#{sha256} -->"

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
    """
    #{contract.marker}
    #{contract.markdown}
    <!-- #{@end_marker} issue=#{contract.issue_key} revision=#{contract.revision} sha256=#{contract.sha256} -->
    """
    |> String.trim()
  end

  @doc "Returns the exact marker announcing a critic-approved contract for confirmation."
  @spec ready_marker(bound_contract()) :: String.t()
  def ready_marker(contract) do
    "AI FACTORY SPEC READY issue=#{contract.issue_key} revision=#{contract.revision} sha256=#{contract.sha256}"
  end

  @doc "Returns the human confirmation text required before `ai-ready`."
  @spec confirmation_marker(bound_contract()) :: String.t()
  def confirmation_marker(contract), do: "AI FACTORY CONFIRM #{contract.sha256}"

  @doc "Returns the immutable authorization record written after human confirmation."
  @spec authorization_marker(bound_contract(), String.t()) :: String.t()
  def authorization_marker(contract, confirmation_comment_id) do
    "AI FACTORY AUTHORIZED issue=#{contract.issue_key} revision=#{contract.revision} " <>
      "sha256=#{contract.sha256} confirmation_comment_id=#{confirmation_comment_id}"
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
    "AI FACTORY SPEC INPUT issue=#{issue_key} questions_sha256=#{questions_sha256}"
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

  @doc "Checks that Jira read-back contains the exact bound contract comment."
  @spec draft_read_back?(map(), bound_contract()) :: boolean()
  def draft_read_back?(snapshot, contract) do
    exact = draft_comment(contract)
    Enum.any?(comments(snapshot), &(comment_text(&1) == exact))
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

  @doc "Checks that Jira contains the exact immutable authorization record."
  @spec authorized?(map(), bound_contract()) :: boolean()
  def authorized?(snapshot, contract) do
    prefix =
      "AI FACTORY AUTHORIZED issue=#{contract.issue_key} revision=#{contract.revision} " <>
        "sha256=#{contract.sha256} confirmation_comment_id="

    Enum.any?(comments(snapshot), &String.starts_with?(String.trim(comment_text(&1)), prefix))
  end

  @doc "Extracts the newest exact contract that also has an authorization record."
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
    case Regex.run(
           ~r/^## Manual Validation\s*$.*?^- Required:\s*(yes|no)\s*$/ims,
           markdown
         ) do
      [_match, value] -> {:ok, String.downcase(value) == "yes"}
      _other -> {:error, :manual_validation_contract_missing}
    end
  end

  @doc "Reads the fixed manual-validation environment when validation is required."
  @spec manual_validation_environment(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def manual_validation_environment(markdown) do
    with {:ok, required?} <- manual_validation_required(markdown) do
      if required? do
        extract_manual_validation_environment(markdown)
      else
        {:ok, nil}
      end
    end
  end

  defp extract_manual_validation_environment(markdown) do
    case Regex.run(~r/^## Manual Validation\s*$.*?^- Environment:\s*([^\n]+)\s*$/ims, markdown) do
      [_match, environment] -> nonblank_environment(environment)
      _other -> {:error, :manual_validation_environment_missing}
    end
  end

  defp nonblank_environment(environment) do
    case String.trim(environment) do
      "" -> {:error, :manual_validation_environment_missing}
      value -> {:ok, value}
    end
  end

  @doc "Returns the next revision after all exact factory contract markers in a snapshot."
  @spec next_revision(map()) :: pos_integer()
  def next_revision(snapshot) do
    maximum =
      snapshot
      |> comments()
      |> Enum.map(&comment_text/1)
      |> Enum.flat_map(&marker_revisions/1)
      |> Enum.max(fn -> 0 end)

    maximum + 1
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
    Regex.scan(~r/#{@begin_marker} issue=\S+ revision=(\d+) sha256=[0-9a-f]{64}/, text)
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

  defp parse_draft(text, issue_key) do
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
end
