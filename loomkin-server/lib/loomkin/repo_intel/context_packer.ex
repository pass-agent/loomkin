defmodule Loomkin.RepoIntel.ContextPacker do
  @moduledoc "Packs ranked file content into a token-budgeted context string."

  alias Loomkin.RepoIntel.RepoMap

  @doc """
  Pack ranked files into a context string within the given token budget.

  Ranked files is a list of `{path, meta, score}` tuples (from RepoMap.rank_files/2).
  Higher-scored files get full content, medium get symbols, lowest get just filenames.
  Token estimation: 1 token ~= 4 characters.
  """
  def pack(ranked_files, token_budget, opts \\ []) do
    project_path = Keyword.get(opts, :project_path, File.cwd!())
    char_budget = token_budget * 4

    header = "## Project Context\n\n"

    {sections, _remaining} =
      Enum.reduce_while(ranked_files, {[header], char_budget - byte_size(header)}, fn
        {path, _meta, score}, {acc, budget} when budget > 0 ->
          section = build_section(path, score, project_path, budget)
          section_size = byte_size(section)

          if section_size <= budget do
            {:cont, {[section | acc], budget - section_size}}
          else
            # Fall back to just the filename
            minimal = "### #{path}\n\n"
            min_size = byte_size(minimal)

            if min_size <= budget do
              {:cont, {[minimal | acc], budget - min_size}}
            else
              {:halt, {acc, 0}}
            end
          end

        _entry, {acc, budget} ->
          {:halt, {acc, budget}}
      end)

    sections
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # --- Private ---

  defp build_section(path, score, project_path, remaining_budget) do
    abs_path = Path.join(project_path, path)
    relevance = relevance_label(score)

    cond do
      # High relevance: include full file content
      score >= 100 ->
        build_full_section(path, abs_path, relevance, remaining_budget)

      # Medium relevance: include symbols only
      score >= 10 ->
        build_symbol_section(path, abs_path, relevance)

      # Low relevance: just the filename
      true ->
        "### #{path}\n\n"
    end
  end

  defp build_full_section(path, abs_path, relevance, budget) do
    case File.read(abs_path) do
      {:ok, content} ->
        lang = Loomkin.RepoIntel.Index.detect_language(path)
        lang_tag = if lang != :unknown, do: to_string(lang), else: ""

        section = """
        ### #{path} (relevance: #{relevance})
        ```#{lang_tag}
        #{content}
        ```

        """

        if byte_size(section) <= budget do
          section
        else
          # Too big for full content, fall back to symbols
          build_symbol_section(path, abs_path, relevance)
        end

      {:error, _} ->
        "### #{path}\n\n"
    end
  end

  defp build_symbol_section(path, abs_path, relevance) do
    symbols = RepoMap.extract_symbols(abs_path)

    if symbols != [] do
      symbol_lines =
        symbols
        |> Enum.map(fn sym -> "  #{sym.type}: #{sym.name} (line #{sym.line})" end)
        |> Enum.join("\n")

      """
      ### #{path} (relevance: #{relevance})
      #{symbol_lines}

      """
    else
      "### #{path}\n\n"
    end
  end

  defp relevance_label(score) when score >= 100, do: "high"
  defp relevance_label(score) when score >= 10, do: "medium"
  defp relevance_label(_score), do: "low"
end
