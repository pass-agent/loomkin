defmodule Loomkin.RepoIntel.TreeSitter do
  @moduledoc """
  Tree-sitter based symbol extraction.

  Uses the `tree-sitter` CLI when available for AST-based parsing,
  falling back to enhanced regex patterns when not.

  Supports: Elixir, JavaScript, TypeScript, Python, Ruby, Go, Rust.
  """

  @ets_table :loomkin_tree_sitter_cache

  @doc "Check if tree-sitter CLI is available on the system."
  @spec available?() :: boolean()
  def available? do
    case System.find_executable("tree-sitter") do
      nil -> false
      _path -> true
    end
  end

  @doc "Initialize the ETS cache table."
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Extract symbols from a file using tree-sitter (or enhanced regex fallback).

  Returns a list of symbol maps: `%{name, type, line, signature}`.
  Results are cached by file path and mtime.
  """
  @spec extract_symbols(String.t()) :: [map()]
  def extract_symbols(file_path) do
    case cached_symbols(file_path) do
      {:ok, symbols} ->
        symbols

      :miss ->
        symbols = do_extract(file_path)
        cache_symbols(file_path, symbols)
        symbols
    end
  end

  @doc "Clear the symbol cache."
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
    end

    :ok
  end

  @doc "Extract symbols using tree-sitter CLI for a given file."
  @spec extract_with_cli(String.t(), atom()) :: [map()]
  def extract_with_cli(file_path, language) do
    query = query_for_language(language)

    if query do
      run_tree_sitter_query(file_path, language, query)
    else
      []
    end
  end

  @doc "Extract symbols using enhanced regex patterns."
  @spec extract_with_regex(String.t(), atom()) :: [map()]
  def extract_with_regex(file_path, language) do
    case File.read(file_path) do
      {:ok, content} ->
        enhanced_extract(content, language)

      {:error, _} ->
        []
    end
  end

  # --- Private: dispatch ---

  defp do_extract(file_path) do
    language = Loomkin.RepoIntel.Index.detect_language(file_path)

    cond do
      language == :unknown ->
        []

      available?() ->
        case extract_with_cli(file_path, language) do
          [] -> extract_with_regex(file_path, language)
          symbols -> symbols
        end

      true ->
        extract_with_regex(file_path, language)
    end
  end

  # --- Private: tree-sitter CLI ---

  defp query_for_language(:elixir) do
    """
    (call target: (identifier) @keyword
      (arguments (alias) @name)
      (#match? @keyword "^(defmodule|defprotocol|defimpl)$"))

    (call target: (identifier) @keyword
      (arguments (call target: (identifier) @name))
      (#match? @keyword "^(def|defp|defmacro|defmacrop|defguard|defguardp)$"))

    (call target: (identifier) @keyword
      (#match? @keyword "^defstruct$"))

    (call target: (identifier) @keyword
      (arguments (binary_operator left: (call target: (identifier) @name)))
      (#match? @keyword "^@(type|typep|opaque|spec|callback)$"))
    """
  end

  defp query_for_language(:python) do
    """
    (class_definition name: (identifier) @name) @class
    (function_definition name: (identifier) @name) @function
    (decorated_definition definition: (function_definition name: (identifier) @name)) @decorated
    """
  end

  defp query_for_language(lang) when lang in [:javascript, :typescript] do
    """
    (function_declaration name: (identifier) @name) @function
    (class_declaration name: (identifier) @name) @class
    (method_definition name: (property_identifier) @name) @method
    (export_statement declaration: (function_declaration name: (identifier) @name)) @export_func
    (export_statement declaration: (class_declaration name: (identifier) @name)) @export_class
    (lexical_declaration (variable_declarator name: (identifier) @name)) @const
    (interface_declaration name: (type_identifier) @name) @interface
    (type_alias_declaration name: (type_identifier) @name) @type_alias
    """
  end

  defp query_for_language(:go) do
    """
    (function_declaration name: (identifier) @name) @function
    (method_declaration name: (field_identifier) @name) @method
    (type_declaration (type_spec name: (type_identifier) @name)) @type
    """
  end

  defp query_for_language(:rust) do
    """
    (function_item name: (identifier) @name) @function
    (struct_item name: (type_identifier) @name) @struct
    (enum_item name: (type_identifier) @name) @enum
    (trait_item name: (type_identifier) @name) @trait
    (impl_item type: (type_identifier) @name) @impl
    """
  end

  defp query_for_language(:ruby) do
    """
    (class name: (constant) @name) @class
    (module name: (constant) @name) @module
    (method name: (identifier) @name) @method
    (singleton_method name: (identifier) @name) @singleton_method
    """
  end

  defp query_for_language(_), do: nil

  defp ts_language_name(:javascript), do: "javascript"
  defp ts_language_name(:typescript), do: "typescript"
  defp ts_language_name(:elixir), do: "elixir"
  defp ts_language_name(:python), do: "python"
  defp ts_language_name(:go), do: "go"
  defp ts_language_name(:rust), do: "rust"
  defp ts_language_name(:ruby), do: "ruby"
  defp ts_language_name(_), do: nil

  defp run_tree_sitter_query(file_path, language, query) do
    lang_name = ts_language_name(language)
    unless lang_name, do: throw(:unsupported)

    # Write query to a temp file
    query_file = Path.join(System.tmp_dir!(), "loom_ts_query_#{:erlang.phash2(query)}.scm")
    File.write!(query_file, query)

    args = ["query", "--captures", query_file, file_path]

    case System.cmd("tree-sitter", args, stderr_to_stdout: true, env: []) do
      {output, 0} ->
        parse_query_output(output, language)

      {_output, _code} ->
        []
    end
  catch
    :unsupported -> []
  after
    # Cleanup is best-effort; temp files are cleaned by OS anyway
    :ok
  end

  defp parse_query_output(output, language) do
    output
    |> String.split("\n")
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [capture_line, content_line | _] ->
        case parse_capture(capture_line, content_line, language) do
          nil -> []
          symbol -> [symbol]
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(fn s -> {s.name, s.line} end)
    |> Enum.sort_by(& &1.line)
  end

  defp parse_capture(capture_line, content_line, _language) do
    # Capture format: "  pattern: N\n    name: <row>,<col> - <row>,<col>"
    # or "    name @capture_name\n      <row>:<col> - <row>:<col>"
    with [_, name] <- Regex.run(~r/@(\w+)/, capture_line),
         content = String.trim(content_line),
         {line, symbol_name} <- extract_line_and_name(content) do
      type = capture_name_to_type(name)

      if type do
        %{name: symbol_name, type: type, line: line, signature: nil}
      end
    else
      _ -> nil
    end
  end

  defp extract_line_and_name(content) do
    case Regex.run(~r/(\d+):(\d+)\s*-\s*\d+:\d+\s*(.*)/, content) do
      [_, row, _col, text] ->
        {String.to_integer(row) + 1, String.trim(text)}

      _ ->
        nil
    end
  end

  defp capture_name_to_type("name"), do: nil
  defp capture_name_to_type("keyword"), do: nil
  defp capture_name_to_type("class"), do: :class
  defp capture_name_to_type("function"), do: :function
  defp capture_name_to_type("method"), do: :function
  defp capture_name_to_type("decorated"), do: :function
  defp capture_name_to_type("export_func"), do: :function
  defp capture_name_to_type("export_class"), do: :class
  defp capture_name_to_type("const"), do: :constant
  defp capture_name_to_type("interface"), do: :interface
  defp capture_name_to_type("type_alias"), do: :type
  defp capture_name_to_type("type"), do: :type
  defp capture_name_to_type("struct"), do: :struct
  defp capture_name_to_type("enum"), do: :enum
  defp capture_name_to_type("trait"), do: :trait
  defp capture_name_to_type("impl"), do: :impl
  defp capture_name_to_type("module"), do: :module
  defp capture_name_to_type("singleton_method"), do: :function
  defp capture_name_to_type(_), do: nil

  # --- Enhanced regex extraction ---

  defp enhanced_extract(content, :elixir) do
    lines = String.split(content, "\n")

    patterns = [
      {~r/^\s*defmodule\s+([\w.]+)/m, :module, &extract_name/1},
      {~r/^\s*defprotocol\s+([\w.]+)/m, :protocol, &extract_name/1},
      {~r/^\s*defimpl\s+([\w.]+)/m, :impl, &extract_name/1},
      {~r/^\s*def\s+(\w+[?!]?)\s*(\([^)]*\))?/m, :function, &extract_signature/1},
      {~r/^\s*defp\s+(\w+[?!]?)\s*(\([^)]*\))?/m, :function, &extract_signature/1},
      {~r/^\s*defmacro\s+(\w+[?!]?)\s*(\([^)]*\))?/m, :macro, &extract_signature/1},
      {~r/^\s*defmacrop\s+(\w+[?!]?)\s*(\([^)]*\))?/m, :macro, &extract_signature/1},
      {~r/^\s*defguard\s+(\w+[?!]?)\s*(\([^)]*\))?/m, :guard, &extract_signature/1},
      {~r/^\s*defstruct\s/m, :struct, fn _ -> {"defstruct", nil} end},
      {~r/^\s*defdelegate\s+(\w+[?!]?)/m, :function, &extract_name/1},
      {~r/^\s*@type\s+(\w+)/m, :type, &extract_name/1},
      {~r/^\s*@typep\s+(\w+)/m, :type, &extract_name/1},
      {~r/^\s*@opaque\s+(\w+)/m, :type, &extract_name/1},
      {~r/^\s*@callback\s+(\w+)/m, :callback, &extract_name/1},
      {~r/^\s*@spec\s+(\w+[?!]?)\s*(\([^)]*\))?/m, :spec, &extract_signature/1}
    ]

    extract_with_enhanced_patterns(lines, patterns)
  end

  defp enhanced_extract(content, :python) do
    lines = String.split(content, "\n")

    patterns = [
      {~r/^class\s+(\w+)(?:\([^)]*\))?/m, :class, &extract_name/1},
      {~r/^\s*def\s+(\w+)\s*(\([^)]*\))?/m, :function, &extract_signature/1},
      {~r/^\s*async\s+def\s+(\w+)\s*(\([^)]*\))?/m, :function, &extract_signature/1},
      {~r/^(\w+)\s*(?::\s*\w+)?\s*=\s*(?!.*def\b)/m, :constant, &extract_name/1}
    ]

    extract_with_enhanced_patterns(lines, patterns)
  end

  defp enhanced_extract(content, lang) when lang in [:javascript, :typescript] do
    lines = String.split(content, "\n")

    patterns = [
      {~r/(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)\s*(\([^)]*\))?/m, :function,
       &extract_signature/1},
      {~r/(?:export\s+)?class\s+(\w+)/m, :class, &extract_name/1},
      {~r/(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=/m, :constant, &extract_name/1},
      {~r/(?:export\s+)?interface\s+(\w+)/m, :interface, &extract_name/1},
      {~r/(?:export\s+)?type\s+(\w+)\s*=/m, :type, &extract_name/1},
      {~r/(?:export\s+)?enum\s+(\w+)/m, :enum, &extract_name/1},
      {~r/^\s*(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{/m, :function, &extract_name/1},
      {~r/^\s*(?:static\s+)?(?:async\s+)?(?:get|set)\s+(\w+)/m, :function, &extract_name/1}
    ]

    extract_with_enhanced_patterns(lines, patterns)
  end

  defp enhanced_extract(content, :go) do
    lines = String.split(content, "\n")

    patterns = [
      {~r/^func\s+(\w+)\s*(\([^)]*\))?/m, :function, &extract_signature/1},
      {~r/^func\s+\(\w+\s+\*?(\w+)\)\s+(\w+)\s*(\([^)]*\))?/m, :function,
       fn captures ->
         case captures do
           [_, recv, name | _] -> {"#{recv}.#{name}", nil}
           _ -> extract_name(captures)
         end
       end},
      {~r/^type\s+(\w+)\s+struct/m, :struct, &extract_name/1},
      {~r/^type\s+(\w+)\s+interface/m, :interface, &extract_name/1},
      {~r/^type\s+(\w+)\s+/m, :type, &extract_name/1},
      {~r/^package\s+(\w+)/m, :module, &extract_name/1}
    ]

    extract_with_enhanced_patterns(lines, patterns)
  end

  defp enhanced_extract(content, :rust) do
    lines = String.split(content, "\n")

    patterns = [
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?fn\s+(\w+)\s*(<[^>]*>)?\s*(\([^)]*\))?/m, :function,
       &extract_signature/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)/m, :struct, &extract_name/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)/m, :enum, &extract_name/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)/m, :trait, &extract_name/1},
      {~r/^\s*impl(?:<[^>]*>)?\s+(\w+)/m, :impl, &extract_name/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?type\s+(\w+)/m, :type, &extract_name/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)/m, :module, &extract_name/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?const\s+(\w+)/m, :constant, &extract_name/1},
      {~r/^\s*(?:pub(?:\([^)]*\))?\s+)?static\s+(\w+)/m, :constant, &extract_name/1}
    ]

    extract_with_enhanced_patterns(lines, patterns)
  end

  defp enhanced_extract(content, :ruby) do
    lines = String.split(content, "\n")

    patterns = [
      {~r/^\s*class\s+(\w+(?:::\w+)*)/m, :class, &extract_name/1},
      {~r/^\s*module\s+(\w+(?:::\w+)*)/m, :module, &extract_name/1},
      {~r/^\s*def\s+(\w+[?!=]?)\s*(\([^)]*\))?/m, :function, &extract_signature/1},
      {~r/^\s*def\s+self\.(\w+[?!=]?)\s*(\([^)]*\))?/m, :function,
       fn captures ->
         case captures do
           [_, name | _] -> {"self.#{name}", nil}
           _ -> extract_name(captures)
         end
       end},
      {~r/^\s*attr_(?:reader|writer|accessor)\s+:(\w+)/m, :attribute, &extract_name/1},
      {~r/^\s*(\w+)\s*=\s*Struct\.new/m, :struct, &extract_name/1}
    ]

    extract_with_enhanced_patterns(lines, patterns)
  end

  defp enhanced_extract(_content, _language), do: []

  defp extract_with_enhanced_patterns(lines, patterns) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      Enum.flat_map(patterns, fn {regex, type, extractor} ->
        case Regex.run(regex, line) do
          nil ->
            []

          captures ->
            {name, signature} = extractor.(captures)

            if name do
              [%{name: name, type: type, line: line_num, signature: signature}]
            else
              []
            end
        end
      end)
    end)
    |> Enum.uniq_by(fn s -> {s.name, s.type, s.line} end)
    |> Enum.sort_by(& &1.line)
  end

  defp extract_name([_, name | _]), do: {name, nil}
  defp extract_name(_), do: {nil, nil}

  defp extract_signature([_, name | rest]) do
    sig =
      case rest do
        [params | _] when is_binary(params) and params != "" ->
          String.trim(name <> params)

        _ ->
          nil
      end

    {name, sig}
  end

  defp extract_signature(captures), do: extract_name(captures)

  # --- Private: caching ---

  defp cached_symbols(file_path) do
    if :ets.whereis(@ets_table) == :undefined do
      :miss
    else
      case :ets.lookup(@ets_table, file_path) do
        [{^file_path, {mtime, symbols}}] ->
          case File.stat(file_path) do
            {:ok, %{mtime: ^mtime}} -> {:ok, symbols}
            _ -> :miss
          end

        [] ->
          :miss
      end
    end
  end

  defp cache_symbols(file_path, symbols) do
    if :ets.whereis(@ets_table) != :undefined do
      case File.stat(file_path) do
        {:ok, %{mtime: mtime}} ->
          :ets.insert(@ets_table, {file_path, {mtime, symbols}})

        _ ->
          :ok
      end
    end
  end
end
