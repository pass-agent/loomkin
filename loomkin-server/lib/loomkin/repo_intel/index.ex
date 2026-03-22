defmodule Loomkin.RepoIntel.Index do
  @moduledoc "ETS-based file index for repository intelligence."

  use GenServer

  @table :loomkin_repo_index

  @skip_dirs ~w(.git _build deps node_modules .loomkin .elixir_ls)

  @keep_hidden ~w(.loomkin.toml .formatter.exs)

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Full scan of the project directory."
  def build(pid \\ __MODULE__) do
    GenServer.call(pid, :build, :infinity)
  end

  @doc "Incremental update — rescan files whose mtime changed."
  def refresh(pid \\ __MODULE__) do
    GenServer.call(pid, :refresh, :infinity)
  end

  @doc "Get metadata for a single file path."
  def lookup(path, pid \\ __MODULE__) do
    GenServer.call(pid, {:lookup, path})
  end

  @doc "List files with optional filters: :language, :pattern, :min_size, :max_size."
  def list_files(opts \\ [], pid \\ __MODULE__) do
    GenServer.call(pid, {:list_files, opts})
  end

  @doc "Summary stats about the indexed repository."
  def stats(pid \\ __MODULE__) do
    GenServer.call(pid, :stats)
  end

  @doc "Detect the programming language of a file by extension."
  def detect_language(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> :elixir
      ext when ext in [".js", ".jsx", ".mjs"] -> :javascript
      ext when ext in [".ts", ".tsx"] -> :typescript
      ".py" -> :python
      ".rb" -> :ruby
      ".rs" -> :rust
      ".go" -> :go
      ext when ext in [".md", ".markdown"] -> :markdown
      ".json" -> :json
      ".toml" -> :toml
      ".yaml" -> :yaml
      ".yml" -> :yaml
      ".html" -> :html
      ".css" -> :css
      ".scss" -> :scss
      ".sql" -> :sql
      ".sh" -> :shell
      _ -> :unknown
    end
  end

  # --- GenServer Callbacks ---

  @doc "Set the project path and trigger a full scan."
  def set_project(project_path, pid \\ __MODULE__) do
    GenServer.call(pid, {:set_project, project_path}, :infinity)
  end

  @impl true
  def init(opts) do
    project_path = Keyword.get(opts, :project_path)

    table =
      if :ets.whereis(@table) != :undefined do
        @table
      else
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      end

    state = %{table: table, project_path: project_path}

    # Auto-scan only if a project_path was explicitly provided (e.g. in tests)
    if project_path, do: do_build(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:set_project, project_path}, _from, state) do
    state = %{state | project_path: project_path}
    :ets.delete_all_objects(state.table)
    do_build(state)
    {:reply, :ok, state}
  end

  def handle_call(:build, _from, state) do
    :ets.delete_all_objects(state.table)
    do_build(state)
    {:reply, :ok, state}
  end

  def handle_call(:refresh, _from, state) do
    do_refresh(state)
    {:reply, :ok, state}
  end

  def handle_call({:lookup, path}, _from, state) do
    result =
      case :ets.lookup(state.table, path) do
        [{^path, meta}] -> {:ok, meta}
        [] -> :error
      end

    {:reply, result, state}
  end

  def handle_call({:list_files, opts}, _from, state) do
    entries = :ets.tab2list(state.table)
    filtered = apply_filters(entries, opts)
    {:reply, filtered, state}
  end

  def handle_call(:stats, _from, state) do
    entries = :ets.tab2list(state.table)

    file_entries = Enum.filter(entries, fn {_path, meta} -> meta.type == :file end)

    by_language =
      file_entries
      |> Enum.group_by(fn {_path, meta} -> meta.language end)
      |> Map.new(fn {lang, files} -> {lang, length(files)} end)

    total_size = Enum.reduce(file_entries, 0, fn {_path, meta}, acc -> acc + meta.size end)

    stats = %{
      total_files: length(file_entries),
      by_language: by_language,
      total_size: total_size
    }

    {:reply, stats, state}
  end

  # --- Private ---

  defp do_build(state) do
    root = state.project_path

    root
    |> scan_directory("")
    |> Enum.each(fn {rel_path, meta} ->
      :ets.insert(state.table, {rel_path, meta})
    end)
  end

  defp do_refresh(state) do
    root = state.project_path
    current_files = scan_directory(root, "") |> Map.new()

    # Remove deleted files
    existing_paths =
      :ets.tab2list(state.table)
      |> Enum.map(fn {path, _} -> path end)
      |> MapSet.new()

    current_paths = MapSet.new(Map.keys(current_files))

    # Delete entries no longer on disk
    MapSet.difference(existing_paths, current_paths)
    |> Enum.each(fn path -> :ets.delete(state.table, path) end)

    # Update changed or new entries
    Enum.each(current_files, fn {rel_path, meta} ->
      case :ets.lookup(state.table, rel_path) do
        [{^rel_path, old_meta}] ->
          if old_meta.mtime != meta.mtime do
            :ets.insert(state.table, {rel_path, meta})
          end

        [] ->
          :ets.insert(state.table, {rel_path, meta})
      end
    end)
  end

  defp scan_directory(root, rel_prefix) do
    abs_dir = if rel_prefix == "", do: root, else: Path.join(root, rel_prefix)

    case File.ls(abs_dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn name ->
          rel_path = if rel_prefix == "", do: name, else: Path.join(rel_prefix, name)
          abs_path = Path.join(root, rel_path)

          cond do
            skip?(name, rel_path) ->
              []

            File.dir?(abs_path) ->
              scan_directory(root, rel_path)

            true ->
              case File.stat(abs_path) do
                {:ok, stat} ->
                  meta = %{
                    mtime: stat.mtime |> NaiveDateTime.from_erl!(),
                    size: stat.size,
                    type: :file,
                    language: detect_language(rel_path)
                  }

                  [{rel_path, meta}]

                {:error, _} ->
                  []
              end
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp skip?(name, _rel_path) when name in @skip_dirs, do: true

  defp skip?(name, rel_path) do
    # Skip hidden files/dirs unless in the keep list
    String.starts_with?(name, ".") and rel_path not in @keep_hidden
  end

  defp apply_filters(entries, opts) do
    entries
    |> filter_language(Keyword.get(opts, :language))
    |> filter_pattern(Keyword.get(opts, :pattern))
    |> filter_min_size(Keyword.get(opts, :min_size))
    |> filter_max_size(Keyword.get(opts, :max_size))
    |> Enum.sort_by(fn {path, _} -> path end)
  end

  defp filter_language(entries, nil), do: entries

  defp filter_language(entries, lang) do
    Enum.filter(entries, fn {_path, meta} -> meta.language == lang end)
  end

  defp filter_pattern(entries, nil), do: entries

  defp filter_pattern(entries, pattern) do
    Enum.filter(entries, fn {path, _meta} ->
      # Use Path.wildcard match semantics via regex conversion
      pattern_matches?(path, pattern)
    end)
  end

  defp filter_min_size(entries, nil), do: entries

  defp filter_min_size(entries, min) do
    Enum.filter(entries, fn {_path, meta} -> meta.size >= min end)
  end

  defp filter_max_size(entries, nil), do: entries

  defp filter_max_size(entries, max) do
    Enum.filter(entries, fn {_path, meta} -> meta.size <= max end)
  end

  defp pattern_matches?(path, pattern) do
    # Convert glob pattern to regex
    # Handle **/ as "zero or more directories"
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("**/", "\000")
      |> String.replace("**", "\001")
      |> String.replace("*", "[^/]*")
      |> String.replace("\000", "(?:.+/)?")
      |> String.replace("\001", ".*")

    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _} -> false
    end
  end
end
