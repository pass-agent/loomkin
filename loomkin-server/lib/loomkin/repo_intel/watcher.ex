defmodule Loomkin.RepoIntel.Watcher do
  @moduledoc """
  Watches project files for changes and auto-refreshes the ETS index.

  Uses the `file_system` library to receive OS-level file change notifications.
  Debounces rapid changes (collects events for 200ms before processing).
  Respects .gitignore patterns by skipping ignored paths.
  """

  use GenServer

  @debounce_ms 200

  @skip_dirs ~w(.git _build deps node_modules .loomkin .elixir_ls)

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start watching a project directory."
  def watch(project_path, pid \\ __MODULE__) do
    GenServer.call(pid, {:watch, project_path})
  end

  @doc "Stop watching the current directory."
  def unwatch(pid \\ __MODULE__) do
    GenServer.call(pid, :unwatch)
  end

  @doc "Get the current watcher status."
  def status(pid \\ __MODULE__) do
    GenServer.call(pid, :status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Loomkin.Signals.subscribe("system.config.loaded")

    state = %{
      project_path: nil,
      watcher_pid: nil,
      pending_changes: MapSet.new(),
      debounce_ref: nil,
      gitignore_patterns: []
    }

    if project_path = Keyword.get(opts, :project_path) do
      {:ok, state, {:continue, {:start_watching, project_path}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue({:start_watching, project_path}, state) do
    {:noreply, do_watch(state, project_path)}
  end

  @impl true
  def handle_call({:watch, project_path}, _from, state) do
    state = stop_watcher(state)
    state = do_watch(state, project_path)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:unwatch, _from, state) do
    {:reply, :ok, stop_watcher(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      watching: state.watcher_pid != nil,
      project_path: state.project_path,
      pending_changes: MapSet.size(state.pending_changes)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    rel_path = Path.relative_to(path, state.project_path)

    if should_process?(rel_path, state.gitignore_patterns) do
      change = classify_event(events, path)
      state = %{state | pending_changes: MapSet.put(state.pending_changes, {rel_path, change})}
      state = schedule_debounce(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, %{state | watcher_pid: nil}}
  end

  @impl true
  def handle_info(:process_changes, state) do
    changes = state.pending_changes

    if MapSet.size(changes) > 0 do
      process_changes(changes, state.project_path)

      signal = Loomkin.Signals.System.RepoUpdated.new!(%{}, subject: state.project_path)
      Loomkin.Signals.publish(%{signal | data: %{files: MapSet.to_list(changes)}})
    end

    {:noreply, %{state | pending_changes: MapSet.new(), debounce_ref: nil}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state), do: handle_info(sig, state)

  def handle_info(%Jido.Signal{type: "system.config.loaded", data: config}, state) do
    watch_enabled = get_in(config, [:repo, :watch_enabled])

    if watch_enabled != false do
      project_path = config[:project_path] || state.project_path

      if project_path && state.watcher_pid == nil do
        {:noreply, do_watch(state, project_path)}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    stop_watcher(state)
    :ok
  end

  # --- Private ---

  defp do_watch(state, project_path) do
    gitignore_patterns = load_gitignore(project_path)

    case FileSystem.start_link(dirs: [project_path]) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)

        %{
          state
          | project_path: project_path,
            watcher_pid: watcher_pid,
            gitignore_patterns: gitignore_patterns
        }

      {:error, _reason} ->
        %{state | project_path: project_path, gitignore_patterns: gitignore_patterns}

      :ignore ->
        %{state | project_path: project_path, gitignore_patterns: gitignore_patterns}
    end
  end

  defp stop_watcher(%{watcher_pid: nil} = state), do: state

  defp stop_watcher(%{watcher_pid: pid} = state) do
    GenServer.stop(pid, :normal)
    %{state | watcher_pid: nil}
  rescue
    _ -> %{state | watcher_pid: nil}
  end

  defp schedule_debounce(%{debounce_ref: nil} = state) do
    ref = Process.send_after(self(), :process_changes, @debounce_ms)
    %{state | debounce_ref: ref}
  end

  defp schedule_debounce(state), do: state

  defp classify_event(events, path) do
    cond do
      :removed in events or :deleted in events -> :deleted
      :renamed in events -> if File.exists?(path), do: :modified, else: :deleted
      :created in events -> :created
      :modified in events -> :modified
      true -> :modified
    end
  end

  defp should_process?(rel_path, gitignore_patterns) do
    parts = Path.split(rel_path)

    not Enum.any?(parts, &(&1 in @skip_dirs)) and
      not Enum.any?(parts, fn part ->
        String.starts_with?(part, ".") and part not in ~w(.loomkin.toml .formatter.exs .gitignore)
      end) and
      not gitignored?(rel_path, gitignore_patterns)
  end

  defp process_changes(changes, project_path) do
    index_pid = GenServer.whereis(Loomkin.RepoIntel.Index)
    if index_pid == nil, do: throw(:no_index)

    Enum.each(changes, fn {rel_path, change_type} ->
      case change_type do
        :deleted ->
          # Remove from ETS directly (public table)
          :ets.delete(:loomkin_repo_index, rel_path)

        type when type in [:created, :modified] ->
          abs_path = Path.join(project_path, rel_path)

          case File.stat(abs_path) do
            {:ok, stat} ->
              meta = %{
                mtime: stat.mtime |> NaiveDateTime.from_erl!(),
                size: stat.size,
                type: :file,
                language: Loomkin.RepoIntel.Index.detect_language(rel_path)
              }

              :ets.insert(:loomkin_repo_index, {rel_path, meta})

            {:error, _} ->
              :ets.delete(:loomkin_repo_index, rel_path)
          end
      end
    end)

    # Invalidate repo map cache if available
    if Code.ensure_loaded?(Loomkin.RepoIntel.RepoMap) &&
         function_exported?(Loomkin.RepoIntel.RepoMap, :invalidate_cache, 0) do
      apply(Loomkin.RepoIntel.RepoMap, :invalidate_cache, [])
    end
  catch
    :no_index ->
      :ok
  end

  # --- Gitignore parsing ---

  defp load_gitignore(project_path) do
    gitignore_path = Path.join(project_path, ".gitignore")

    case File.read(gitignore_path) do
      {:ok, content} -> parse_gitignore(content)
      {:error, _} -> []
    end
  end

  @doc false
  def parse_gitignore(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "#") end)
    |> Enum.map(&compile_gitignore_pattern/1)
    |> Enum.reject(&is_nil/1)
  end

  defp compile_gitignore_pattern(pattern) do
    # Strip trailing slash (directory indicator — we treat files and dirs the same)
    pattern = String.trim_trailing(pattern, "/")

    # Convert gitignore glob to regex
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("**/", "\000")
      |> String.replace("**", "\001")
      |> String.replace("*", "[^/]*")
      |> String.replace("?", "[^/]")
      |> String.replace("\000", "(?:.+/)?")
      |> String.replace("\001", ".*")

    # If pattern doesn't start with /, it matches anywhere in the path
    regex_str =
      if String.starts_with?(pattern, "/") do
        "^" <> String.trim_leading(regex_str, "/") <> "(?:/|$)"
      else
        "(?:^|/)" <> regex_str <> "(?:/|$)"
      end

    case Regex.compile(regex_str) do
      {:ok, regex} -> regex
      {:error, _} -> nil
    end
  end

  defp gitignored?(_rel_path, []), do: false

  defp gitignored?(rel_path, patterns) do
    Enum.any?(patterns, fn regex -> Regex.match?(regex, rel_path) end)
  end
end
