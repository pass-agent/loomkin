defmodule LoomkinWeb.FileTreeComponent do
  @moduledoc "LiveComponent for a project file browser with expand/collapse tree."

  use LoomkinWeb, :live_component

  @skip_dirs ~w(.git _build deps node_modules .loomkin .elixir_ls)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       tree: [],
       full_tree: [],
       expanded_dirs: MapSet.new(),
       filter: "",
       file_count: 0,
       total_size: 0,
       loading: false,
       scan_task: nil
     )}
  end

  @impl true
  def update(%{__async_result__: {scanned_path, tree, file_count, total_size}}, socket) do
    # Only apply results if they match the current project_path (guards against stale scans)
    if scanned_path == socket.assigns[:project_path] do
      filtered_tree =
        case socket.assigns.filter do
          "" -> tree
          f -> filter_tree(tree, String.downcase(f))
        end

      {:ok,
       assign(socket,
         tree: filtered_tree,
         full_tree: tree,
         file_count: file_count,
         total_size: total_size,
         loading: false,
         scan_task: nil
       )}
    else
      # Stale result from a previous path — discard
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    previous_path = socket.assigns[:project_path]
    previous_version = socket.assigns[:version]
    socket = assign(socket, assigns)

    project_path = assigns[:project_path]
    version = assigns[:version]

    path_changed = project_path && project_path != "" && project_path != previous_path
    version_changed = version && version != previous_version

    if path_changed || version_changed do
      socket = cancel_scan(socket)
      {:ok, start_async_scan(socket, project_path || previous_path)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("toggle_dir", %{"path" => path}, socket) do
    expanded = socket.assigns.expanded_dirs

    expanded =
      if MapSet.member?(expanded, path) do
        MapSet.delete(expanded, path)
      else
        MapSet.put(expanded, path)
      end

    {:noreply, assign(socket, expanded_dirs: expanded)}
  end

  def handle_event("select_file", %{"path" => path}, socket) do
    send(self(), {:select_file, path})
    {:noreply, socket}
  end

  def handle_event("filter", %{"filter" => value}, socket) do
    filtered_tree =
      case value do
        "" -> socket.assigns.full_tree
        f -> filter_tree(socket.assigns.full_tree, String.downcase(f))
      end

    {:noreply, assign(socket, filter: value, tree: filtered_tree)}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, assign(socket, filter: "", tree: socket.assigns.full_tree)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-gray-950 text-gray-100">
      <div class="px-3 py-2.5 border-b border-gray-800">
        <h3 class="text-[10px] font-semibold text-gray-500 uppercase tracking-widest mb-2">
          Explorer
        </h3>
        <div class="relative">
          <.icon
            name="hero-magnifying-glass-mini"
            class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-500"
          />
          <form phx-change="filter" phx-target={@myself} phx-submit="filter">
            <input
              type="text"
              name="filter"
              aria-label="Filter files"
              placeholder="Filter files..."
              value={@filter}
              class="w-full pl-8 pr-8 py-1.5 text-xs bg-gray-800/60 border border-gray-700/50 rounded-lg text-gray-200 placeholder-gray-600 focus:outline-none focus:ring-2 focus:ring-violet-500/30 focus:border-violet-500/50 transition-shadow"
              autocomplete="off"
              phx-debounce="200"
            />
          </form>
          <button
            :if={@filter != ""}
            phx-click="clear_filter"
            phx-target={@myself}
            class="absolute right-2 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300 transition-colors"
          >
            <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto px-1 py-1 text-sm font-mono">
        <%= if @loading do %>
          <div class="flex items-center justify-center gap-2 px-3 py-6">
            <div class="w-4 h-4 border-2 border-violet-500/30 border-t-violet-400 rounded-full animate-spin">
            </div>
            <span class="text-gray-500 text-xs">Scanning files...</span>
          </div>
        <% else %>
          <%= if @tree == [] do %>
            <p class="px-3 py-4 text-gray-500 text-center text-xs">No files indexed</p>
          <% else %>
            <.tree_entries entries={@tree} expanded_dirs={@expanded_dirs} depth={0} myself={@myself} />
          <% end %>
        <% end %>
      </div>

      <div class="px-3 py-2 border-t border-gray-800">
        <div class="flex items-center gap-2 text-[10px] text-gray-600">
          <.icon name="hero-document-text-mini" class="w-3 h-3" />
          <span>{@file_count} files</span>
          <span class="text-gray-700">&middot;</span>
          <span>{format_size(@total_size)}</span>
        </div>
      </div>
    </div>
    """
  end

  defp tree_entries(assigns) do
    ~H"""
    <div>
      <div :for={entry <- @entries}>
        <%= if entry.type == :dir do %>
          <div
            class="flex items-center gap-1.5 px-1.5 py-1 rounded-md cursor-pointer hover:bg-gray-800/60 select-none group transition-colors duration-150"
            style={"padding-left: #{@depth * 16 + 4}px"}
            phx-click="toggle_dir"
            phx-value-path={entry.path}
            phx-target={@myself}
          >
            <span class={"text-gray-500 w-3.5 text-center text-[10px] chevron-rotate " <> if(MapSet.member?(@expanded_dirs, entry.path), do: "expanded", else: "")}>
              &#9654;
            </span>
            <.icon
              name="hero-folder-mini"
              class={"w-3.5 h-3.5 flex-shrink-0 transition-colors " <> if(MapSet.member?(@expanded_dirs, entry.path), do: "text-violet-400", else: "text-violet-500/60 group-hover:text-violet-400")}
            />
            <span class="text-gray-300 group-hover:text-gray-200 text-xs transition-colors">
              {entry.name}
            </span>
          </div>
          <%= if MapSet.member?(@expanded_dirs, entry.path) do %>
            <.tree_entries
              entries={entry.children}
              expanded_dirs={@expanded_dirs}
              depth={@depth + 1}
              myself={@myself}
            />
          <% end %>
        <% else %>
          <div
            class="flex items-center gap-1.5 px-1.5 py-1 rounded-md cursor-pointer hover:bg-violet-500/5 select-none group transition-colors duration-150"
            style={"padding-left: #{@depth * 16 + 20}px"}
            phx-click="select_file"
            phx-value-path={entry.path}
            phx-target={@myself}
          >
            <span class={"w-1.5 h-1.5 rounded-full flex-shrink-0 " <> file_dot_color(entry.name)} />
            <span class={"text-xs transition-colors group-hover:text-gray-200 " <> file_color(entry.name)}>
              {entry.name}
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Async scanning ---

  defp start_async_scan(socket, project_path) do
    component_id = socket.assigns.id
    parent_pid = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
        {tree, file_count, total_size} = build_tree(project_path)

        send_update(parent_pid, __MODULE__,
          id: component_id,
          __async_result__: {project_path, tree, file_count, total_size}
        )
      end)

    assign(socket, loading: true, scan_task: pid)
  end

  defp cancel_scan(%{assigns: %{scan_task: pid}} = socket) when is_pid(pid) do
    Process.exit(pid, :kill)
    assign(socket, scan_task: nil, loading: false)
  end

  defp cancel_scan(socket), do: socket

  # --- Tree building ---

  defp build_tree(project_path) do
    entries = scan_dir(project_path, "")
    {file_count, total_size} = count_stats(entries)
    sorted = sort_entries(entries)
    {sorted, file_count, total_size}
  end

  defp scan_dir(root, rel_prefix) do
    abs_dir = if rel_prefix == "", do: root, else: Path.join(root, rel_prefix)

    case File.ls(abs_dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&skip?/1)
        |> Enum.map(fn name ->
          rel_path = if rel_prefix == "", do: name, else: Path.join(rel_prefix, name)
          abs_path = Path.join(root, rel_path)

          if File.dir?(abs_path) do
            children = scan_dir(root, rel_path)
            %{name: name, path: rel_path, type: :dir, children: sort_entries(children), size: 0}
          else
            size =
              case File.stat(abs_path) do
                {:ok, %{size: s}} -> s
                _ -> 0
              end

            %{name: name, path: rel_path, type: :file, children: [], size: size}
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp sort_entries(entries) do
    Enum.sort_by(entries, fn e -> {if(e.type == :dir, do: 0, else: 1), e.name} end)
  end

  defp count_stats(entries) do
    Enum.reduce(entries, {0, 0}, fn entry, {count, size} ->
      case entry.type do
        :dir ->
          {child_count, child_size} = count_stats(entry.children)
          {count + child_count, size + child_size}

        :file ->
          {count + 1, size + entry.size}
      end
    end)
  end

  defp skip?(name) when name in @skip_dirs, do: true
  defp skip?(<<".", _::binary>>), do: true
  defp skip?(_), do: false

  # --- Filtering ---

  defp filter_tree(entries, query) do
    entries
    |> Enum.map(fn entry ->
      case entry.type do
        :dir ->
          filtered_children = filter_tree(entry.children, query)

          if filtered_children != [] or String.contains?(String.downcase(entry.name), query) do
            %{entry | children: filtered_children}
          else
            nil
          end

        :file ->
          if String.contains?(String.downcase(entry.name), query) do
            entry
          else
            nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # --- File color by extension ---

  defp file_color(name) do
    ext = Path.extname(name)

    case ext do
      e when e in [".ex", ".exs"] -> "text-violet-400"
      e when e in [".js", ".jsx", ".mjs", ".ts", ".tsx"] -> "text-yellow-400"
      e when e in [".md", ".markdown"] -> "text-gray-400"
      e when e in [".json", ".toml", ".yaml", ".yml"] -> "text-green-400"
      e when e in [".html", ".heex"] -> "text-orange-400"
      e when e in [".css", ".scss"] -> "text-blue-400"
      _ -> "text-gray-400"
    end
  end

  defp file_dot_color(name) do
    ext = Path.extname(name)

    case ext do
      e when e in [".ex", ".exs"] -> "bg-violet-400"
      e when e in [".js", ".jsx", ".mjs", ".ts", ".tsx"] -> "bg-yellow-400"
      e when e in [".md", ".markdown"] -> "bg-gray-500"
      e when e in [".json", ".toml", ".yaml", ".yml"] -> "bg-green-400"
      e when e in [".html", ".heex"] -> "bg-orange-400"
      e when e in [".css", ".scss"] -> "bg-blue-400"
      _ -> "bg-gray-500"
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
