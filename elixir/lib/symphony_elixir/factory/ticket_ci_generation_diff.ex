defmodule SymphonyElixir.Factory.TicketCiGenerationDiff do
  @moduledoc "Parses trusted generator output into exact, scoped byte-change proposals."

  @rejected {:error, :controller_generation_diff_rejected}
  @limit 1_048_576
  @line_limit 16_384
  @hunk_limit 128

  @spec plan(binary(), binary(), binary(), [binary()], map()) :: {:ok, [map()]} | {:error, atom()}
  def plan(kind, diff, root, allowed, preimages)
      when kind in ["gazelle", "gofmt"] and is_binary(diff) and is_binary(root) and
             is_list(allowed) and is_map(preimages) do
    with true <- byte_size(diff) <= @limit and String.valid?(diff),
         false <- String.contains?(diff, <<0>>),
         true <- Path.type(root) == :absolute and Path.expand(root) == root,
         true <- Enum.all?(allowed, &scoped_path?(kind, &1)),
         true <- length(allowed) <= 32 and length(Enum.uniq(allowed)) == length(allowed),
         diff_lines = lines(diff),
         true <- length(diff_lines) <= @line_limit,
         {:ok, sections} <- sections(diff_lines, kind, root, allowed, []),
         paths = Enum.map(sections, & &1.path),
         true <- length(paths) == length(Enum.uniq(paths)),
         true <- resource_limits?(sections, preimages),
         {:ok, changes} <- changes(sections, preimages),
         true <- Enum.reduce(changes, 0, &(byte_size(&1.after) + &2)) <= @limit do
      {:ok, changes}
    else
      _ -> @rejected
    end
  end

  def plan(_, _, _, _, _), do: @rejected

  @doc "Accepts creation headers only for controller-observed absent generated files."
  @spec plan_generated(binary(), binary(), [binary()], map(), [binary()]) :: {:ok, [map()]} | {:error, atom()}
  def plan_generated(diff, root, allowed, preimages, absent) when is_binary(diff) and is_list(absent) do
    with true <- byte_size(diff) <= @limit and Enum.all?(absent, &(&1 in allowed and preimages[&1] == "")),
         {:ok, normalized} <- creation_headers(lines(diff), root, absent, []) do
      plan("gazelle", IO.iodata_to_binary(normalized), root, allowed, preimages)
    else
      _ -> @rejected
    end
  end

  def plan_generated(_, _, _, _, _), do: @rejected

  defp creation_headers([], _root, _absent, result), do: {:ok, Enum.reverse(result)}

  defp creation_headers(["--- " <> old, "+++ " <> new = header | tail], root, absent, result) do
    if old |> String.trim_trailing("\n") |> String.split("\t", parts: 2) |> hd() == "/dev/null" do
      with {:ok, path} <- header_path(new, "gazelle", root, :new),
           true <- path in absent do
        creation_headers(tail, root, absent, [header, "--- " <> path <> "\n" | result])
      else
        _ -> @rejected
      end
    else
      creation_headers(tail, root, absent, [header, "--- " <> old | result])
    end
  end

  defp creation_headers([line | tail], root, absent, result), do: creation_headers(tail, root, absent, [line | result])

  @doc "Maps the fixed stdin diff label to its already-bound input, never a path suggested by output."
  @spec plan_stdin(binary(), binary(), binary(), binary()) :: {:ok, [map()]} | {:error, atom()}
  def plan_stdin(diff, root, path, before)
      when is_binary(diff) and is_binary(root) and is_binary(path) and is_binary(before) and
             byte_size(diff) <= @limit and byte_size(before) <= @limit and byte_size(path) <= 1024 and byte_size(root) <= 4096 do
    prefix = "diff <standard input>.orig <standard input>\n--- <standard input>.orig\n+++ <standard input>\n"

    cond do
      diff == "" ->
        plan("gofmt", "", root, [path], %{path => before})

      String.starts_with?(diff, prefix) ->
        mapped = "diff #{path}.orig #{path}\n--- #{path}.orig\n+++ #{path}\n" <> binary_part(diff, byte_size(prefix), byte_size(diff) - byte_size(prefix))
        plan("gofmt", mapped, root, [path], %{path => before})

      true ->
        @rejected
    end
  end

  def plan_stdin(_, _, _, _), do: @rejected

  defp lines(""), do: []
  defp lines(text), do: Regex.scan(~r/[^\n]*\n|[^\n]+\z/, text) |> List.flatten()

  defp sections([], _, _, _, result), do: {:ok, Enum.reverse(result)}

  defp sections(["diff " <> _ = command | rest], "gofmt", root, allowed, result) do
    with [_, old, new] <- String.split(String.trim_trailing(command, "\n"), " "),
         true <- old == new <> ".orig",
         ["--- " <> old_header, "+++ " <> new_header | _] <- rest,
         true <- old_header == old <> "\n" and new_header == new <> "\n" do
      section(rest, "gofmt", root, allowed, result)
    else
      _ -> @rejected
    end
  end

  defp sections(["--- " <> _ | _] = rest, "gazelle", root, allowed, result),
    do: section(rest, "gazelle", root, allowed, result)

  defp sections(_, _, _, _, _), do: @rejected

  defp section(["--- " <> old, "+++ " <> new | rest], kind, root, allowed, result) do
    with {:ok, old} <- header_path(old, kind, root, :old),
         {:ok, path} <- header_path(new, kind, root, :new),
         true <- old == path and path in allowed and scoped_path?(kind, path),
         {hunks, tail} <- Enum.split_while(rest, &(not String.starts_with?(&1, ["--- ", "diff "]))),
         true <- hunks != [] do
      sections(tail, kind, root, allowed, [%{path: path, hunks: hunks} | result])
    else
      _ -> @rejected
    end
  end

  defp section(_, _, _, _, _), do: @rejected

  defp header_path(line, kind, root, side) do
    path = line |> String.trim_trailing("\n") |> String.split("\t", parts: 2) |> hd()
    path = if kind == "gofmt" and side == :old, do: String.replace_suffix(path, ".orig", ""), else: path
    path = if String.starts_with?(path, root <> "/"), do: String.replace_prefix(path, root <> "/", ""), else: path
    if scoped_path?(kind, path), do: {:ok, path}, else: @rejected
  end

  defp scoped_path?(kind, path) when is_binary(path) do
    valid =
      path != "" and not String.starts_with?(path, "-") and Path.type(path) == :relative and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
        not String.contains?(path, ["\\", "\"", "\t", "\n", "\r", <<0>>])

    valid and
      case kind do
        "gazelle" -> Path.basename(path) in ["BUILD", "BUILD.bazel"]
        "gofmt" -> String.ends_with?(path, ".go")
      end
  end

  defp scoped_path?(_, _), do: false

  defp resource_limits?(sections, preimages) do
    hunks = Enum.reduce(sections, 0, fn section, count -> count + Enum.count(section.hunks, &String.starts_with?(&1, "@@ ")) end)

    sizes =
      Enum.reduce_while(sections, {:ok, 0}, fn section, {:ok, size} ->
        case Map.fetch(preimages, section.path) do
          {:ok, text} when is_binary(text) ->
            if byte_size(text) <= @limit and length(lines(text)) <= @line_limit,
              do: {:cont, {:ok, size + byte_size(text)}},
              else: {:halt, :rejected}

          _ ->
            {:halt, :rejected}
        end
      end)

    hunks <= @hunk_limit and match?({:ok, size} when size <= @limit, sizes)
  end

  defp changes(sections, preimages) do
    Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, result} ->
      with {:ok, before} when is_binary(before) <- Map.fetch(preimages, section.path),
           true <- byte_size(before) <= @limit and String.valid?(before),
           {:ok, after_lines} <- apply_hunks(section.hunks, lines(before), 0, []) do
        change = %{path: section.path, before: before, after: IO.iodata_to_binary(after_lines)}
        {:cont, {:ok, [change | result]}}
      else
        _ -> {:halt, @rejected}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp apply_hunks([], before, _, result), do: {:ok, result ++ before}

  defp apply_hunks([header | rest], before, consumed, result) do
    with {:ok, old_start, old_count, new_start, new_count} <- hunk_header(header),
         skip = old_start - if(old_count == 0, do: 0, else: 1) - consumed,
         true <- skip >= 0 and skip <= length(before),
         {prefix, remaining} = Enum.split(before, skip),
         true <- new_start == length(result) + skip + if(new_count == 0, do: 0, else: 1),
         {body, tail} = Enum.split_while(rest, &(not String.starts_with?(&1, "@@ "))),
         {:ok, remaining, emitted, ^old_count, ^new_count} <- hunk(body, remaining, [], 0, 0) do
      apply_hunks(tail, remaining, consumed + skip + old_count, result ++ prefix ++ emitted)
    else
      _ -> @rejected
    end
  end

  defp hunk_header(header) do
    case Regex.named_captures(~r/^@@ -(?<old_start>\d{1,7})(?:,(?<old_count>\d{1,7}))? \+(?<new_start>\d{1,7})(?:,(?<new_count>\d{1,7}))? @@[^\n]*\n$/, header) do
      %{} = fields ->
        {:ok, String.to_integer(fields["old_start"]), count(fields["old_count"]), String.to_integer(fields["new_start"]), count(fields["new_count"])}

      _ ->
        @rejected
    end
  end

  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)

  defp hunk([], before, result, old, new), do: {:ok, before, Enum.reverse(result), old, new}

  defp hunk([" " <> line | rest], [line | before], result, old, new),
    do: hunk(rest, before, [line | result], old + 1, new + 1)

  defp hunk(["-" <> line | rest], [line | before], result, old, new),
    do: hunk(rest, before, result, old + 1, new)

  defp hunk(["+" <> line | rest], before, result, old, new),
    do: hunk(rest, before, [line | result], old, new + 1)

  defp hunk(_, _, _, _, _), do: @rejected
end
