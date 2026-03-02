defmodule Loomkin.RepoIntel.RepoMap do
  @moduledoc "Generates a repo map with symbol extraction and relevance ranking."

  alias Loomkin.RepoIntel.Index
  alias Loomkin.RepoIntel.TreeSitter

  @doc """
  Extract symbols from a source file.

  Uses tree-sitter when available for AST-based parsing, otherwise falls back
  to regex-based pattern matching.
  """
  def extract_symbols(file_path) do
    if tree_sitter_available?() do
      case TreeSitter.extract_symbols(file_path) do
        [] -> extract_symbols_regex(file_path)
        symbols -> symbols
      end
    else
      extract_symbols_regex(file_path)
    end
  end

  @doc "Check if tree-sitter based extraction is available."
  @spec tree_sitter_available?() :: boolean()
  def tree_sitter_available?, do: TreeSitter.available?()

  @doc "Extract symbols using regex only (original implementation)."
  def extract_symbols_regex(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        language = Index.detect_language(file_path)
        extract_for_language(content, language)

      {:error, _} ->
        []
    end
  end

  @doc "Rank file entries by relevance."
  def rank_files(file_entries, opts \\ []) do
    mentioned_files = Keyword.get(opts, :mentioned_files, [])
    keywords = Keyword.get(opts, :keywords, [])

    file_entries
    |> Enum.map(fn {path, meta} ->
      score = base_score(path, meta)
      score = if path in mentioned_files, do: score + 100, else: score
      score = score + keyword_bonus(path, keywords)
      {path, meta, score}
    end)
    |> Enum.sort_by(fn {_path, _meta, score} -> score end, :desc)
  end

  @doc "Generate a text repo map within a token budget."
  def generate(project_path, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    mentioned_files = Keyword.get(opts, :mentioned_files, [])
    keywords = Keyword.get(opts, :keywords, [])

    entries =
      try do
        Index.list_files()
      catch
        :exit, _ -> []
      end

    ranked =
      rank_files(entries,
        mentioned_files: mentioned_files,
        keywords: keywords
      )

    {:ok, build_map(ranked, project_path, max_tokens)}
  end

  # --- Private: symbol extraction ---

  defp extract_for_language(content, :elixir) do
    patterns = [
      {~r/^\s*defmodule\s+([\w.]+)/m, :module},
      {~r/^\s*def\s+(\w+)/m, :function},
      {~r/^\s*defp\s+(\w+)/m, :function},
      {~r/^\s*defstruct/m, :struct},
      {~r/^\s*defmacro\s+(\w+)/m, :macro}
    ]

    extract_with_patterns(content, patterns)
  end

  defp extract_for_language(content, :python) do
    patterns = [
      {~r/^class\s+(\w+)/m, :class},
      {~r/^def\s+(\w+)/m, :function}
    ]

    extract_with_patterns(content, patterns)
  end

  defp extract_for_language(content, lang) when lang in [:javascript, :typescript] do
    patterns = [
      {~r/(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)/m, :function},
      {~r/(?:export\s+)?class\s+(\w+)/m, :class},
      {~r/(?:export\s+)?const\s+(\w+)\s*=/m, :constant}
    ]

    extract_with_patterns(content, patterns)
  end

  defp extract_for_language(content, :go) do
    patterns = [
      {~r/^func\s+(?:\(\w+\s+\*?\w+\)\s+)?(\w+)/m, :function},
      {~r/^type\s+(\w+)\s+struct/m, :struct}
    ]

    extract_with_patterns(content, patterns)
  end

  defp extract_for_language(_content, _language), do: []

  defp extract_with_patterns(content, patterns) do
    lines = String.split(content, "\n")

    Enum.flat_map(patterns, fn {regex, type} ->
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_num} ->
        case Regex.run(regex, line) do
          [_full | [name | _]] ->
            [%{name: name, type: type, line: line_num}]

          [_full] when type == :struct ->
            [%{name: "defstruct", type: :struct, line: line_num}]

          _ ->
            []
        end
      end)
    end)
    |> Enum.sort_by(& &1.line)
  end

  # --- Private: ranking ---

  defp base_score(path, _meta) do
    cond do
      # Entry point / config files score higher
      String.ends_with?(path, "application.ex") -> 20
      String.ends_with?(path, "mix.exs") -> 18
      String.ends_with?(path, "router.ex") -> 15
      String.contains?(path, "lib/") -> 10
      String.contains?(path, "test/") -> 5
      true -> 1
    end
  end

  defp keyword_bonus(_path, []), do: 0

  defp keyword_bonus(path, keywords) do
    downcased = String.downcase(path)

    Enum.count(keywords, fn kw ->
      String.contains?(downcased, String.downcase(kw))
    end) * 10
  end

  # --- Private: map generation ---

  defp build_map(ranked, project_path, max_tokens) do
    char_budget = max_tokens * 4
    header = "## Project Files\n\n"

    {sections, _remaining} =
      Enum.reduce_while(ranked, {[header], char_budget - byte_size(header)}, fn
        {path, _meta, score}, {acc, budget} when budget > 0 ->
          section = build_file_section(path, score, project_path)
          section_size = byte_size(section)

          if section_size <= budget do
            {:cont, {[section | acc], budget - section_size}}
          else
            # Try a minimal entry (just the path)
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

  defp build_file_section(path, score, project_path) do
    abs_path = Path.join(project_path, path)
    relevance = relevance_label(score)

    symbols = extract_symbols(abs_path)

    if symbols != [] do
      symbol_text = format_symbols(symbols)

      """
      ### #{path} (relevance: #{relevance})
      #{symbol_text}

      """
    else
      "### #{path}\n\n"
    end
  end

  defp relevance_label(score) when score >= 100, do: "high"
  defp relevance_label(score) when score >= 10, do: "medium"
  defp relevance_label(_score), do: "low"

  defp format_symbols(symbols) do
    symbols
    |> Enum.map(fn sym ->
      case sym.type do
        :module -> "Modules: #{sym.name}"
        :class -> "Classes: #{sym.name}"
        :struct -> "Structs: #{sym.name}"
        :function -> "Functions: #{sym.name}/?"
        :macro -> "Macros: #{sym.name}/?"
        :constant -> "Constants: #{sym.name}"
        _ -> "#{sym.type}: #{sym.name}"
      end
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
