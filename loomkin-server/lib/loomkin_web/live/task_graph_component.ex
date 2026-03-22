defmodule LoomkinWeb.TaskGraphComponent do
  @moduledoc "LiveComponent for interactive SVG task dependency graph visualization."

  use LoomkinWeb, :live_component

  alias Loomkin.Teams.Tasks

  @node_width 140
  @node_height 60
  @layer_gap 120
  @node_gap 180

  @status_colors %{
    pending: {"#9ca3af", "#374151"},
    assigned: {"#60a5fa", "#1e3a5f"},
    in_progress: {"#fbbf24", "#78350f"},
    completed: {"#4ade80", "#166534"},
    failed: {"#f87171", "#7f1d1d"},
    blocked: {"#fb923c", "#7c2d12"}
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       tasks: [],
       deps: [],
       positioned: [],
       edges: [],
       selected_node: nil,
       critical_path_edges: MapSet.new(),
       refresh_ref: nil,
       svg_width: 800,
       svg_height: 400
     )}
  end

  @impl true
  def update(assigns, socket) do
    prev_team_id = socket.assigns[:team_id]
    prev_refresh_ref = socket.assigns[:refresh_ref]

    socket = assign(socket, assigns)

    team_id = socket.assigns[:team_id]
    refresh_ref = socket.assigns[:refresh_ref]

    # Support test overrides
    tasks_override = socket.assigns[:tasks_override]
    deps_override = socket.assigns[:deps_override]
    selected_node_id = socket.assigns[:selected_node_id]

    cond do
      tasks_override != nil ->
        do_load_from_overrides(socket, tasks_override, deps_override || [], selected_node_id)

      team_id != prev_team_id ->
        do_load_graph(socket, team_id)

      refresh_ref != nil and refresh_ref != prev_refresh_ref ->
        do_load_graph(socket, team_id)

      true ->
        {:ok, socket}
    end
  end

  defp do_load_from_overrides(socket, tasks, deps, selected_node_id) do
    {positioned, edges, critical_path_edges, svg_w, svg_h} =
      compute_layout(tasks, deps)

    selected_node =
      if selected_node_id do
        Enum.find(tasks, &(&1.id == selected_node_id))
      end

    {:ok,
     assign(socket,
       tasks: tasks,
       deps: deps,
       positioned: positioned,
       edges: edges,
       critical_path_edges: critical_path_edges,
       selected_node: selected_node,
       svg_width: max(svg_w, 400),
       svg_height: max(svg_h, 200)
     )}
  end

  defp do_load_graph(socket, team_id) do
    {tasks, deps} =
      if is_binary(team_id) do
        try do
          Tasks.list_with_deps(team_id)
        rescue
          _ -> {[], []}
        end
      else
        {[], []}
      end

    {positioned, edges, critical_path_edges, svg_w, svg_h} =
      compute_layout(tasks, deps)

    {:ok,
     assign(socket,
       tasks: tasks,
       deps: deps,
       positioned: positioned,
       edges: edges,
       critical_path_edges: critical_path_edges,
       selected_node: nil,
       svg_width: max(svg_w, 400),
       svg_height: max(svg_h, 200)
     )}
  end

  defp compute_layout(tasks, deps) do
    positioned = layout_tasks(tasks, deps)
    critical_path_edges = compute_critical_path(tasks, deps)

    edges =
      Enum.map(deps, fn dep ->
        from_pos = Enum.find(positioned, fn p -> p.node.id == dep.depends_on_id end)
        to_pos = Enum.find(positioned, fn p -> p.node.id == dep.task_id end)

        %{
          dep: dep,
          from_pos: from_pos,
          to_pos: to_pos
        }
      end)
      |> Enum.filter(fn e -> e.from_pos != nil and e.to_pos != nil end)

    {svg_w, svg_h} = compute_svg_dimensions(positioned)
    {positioned, edges, critical_path_edges, svg_w, svg_h}
  end

  # --- Layout ---

  defp layout_tasks(tasks, deps) do
    depths = compute_depths(tasks, deps)

    tasks
    |> Enum.group_by(fn t -> Map.get(depths, t.id, 0) end)
    |> Enum.sort_by(fn {layer, _} -> layer end)
    |> Enum.flat_map(fn {layer, layer_tasks} ->
      layer_tasks
      |> Enum.with_index()
      |> Enum.map(fn {task, x_idx} ->
        %{
          node: task,
          x: 40 + x_idx * @node_gap,
          y: 40 + layer * @layer_gap
        }
      end)
    end)
  end

  defp compute_depths(tasks, deps) do
    blocking_deps =
      Enum.filter(deps, fn d -> d.dep_type == :blocks end)

    # Build adjacency: depends_on_id -> [task_id] (dependency points to dependent)
    # For depth computation: tasks with no blocking deps are roots (depth 0)
    # A task's depth = max(depth of blocking dependencies) + 1

    dep_map =
      Enum.reduce(blocking_deps, %{}, fn d, acc ->
        Map.update(acc, d.task_id, [d.depends_on_id], &[d.depends_on_id | &1])
      end)

    task_ids = Enum.map(tasks, & &1.id)

    # Iterative depth computation
    initial_depths =
      Enum.into(task_ids, %{}, fn id ->
        if Map.has_key?(dep_map, id) do
          {id, nil}
        else
          {id, 0}
        end
      end)

    resolve_depths(initial_depths, dep_map, 0)
  end

  defp resolve_depths(depths, dep_map, iteration) when iteration < 100 do
    unresolved = Enum.filter(depths, fn {_id, d} -> is_nil(d) end)

    if unresolved == [] do
      depths
    else
      updated =
        Enum.reduce(unresolved, depths, fn {id, _}, acc ->
          dep_ids = Map.get(dep_map, id, [])
          dep_depths = Enum.map(dep_ids, fn did -> Map.get(acc, did) end)

          if Enum.all?(dep_depths, &(not is_nil(&1))) do
            max_dep = Enum.max(dep_depths, fn -> 0 end)
            Map.put(acc, id, max_dep + 1)
          else
            acc
          end
        end)

      if updated == depths do
        # Circular or unresolvable -- assign remaining to layer 0
        Enum.reduce(unresolved, depths, fn {id, _}, acc ->
          Map.put(acc, id, 0)
        end)
      else
        resolve_depths(updated, dep_map, iteration + 1)
      end
    end
  end

  defp resolve_depths(depths, _dep_map, _iteration), do: depths

  # --- Critical Path ---

  defp compute_critical_path(tasks, deps) do
    incomplete_ids =
      tasks
      |> Enum.reject(fn t -> t.status in [:completed, :failed] end)
      |> MapSet.new(& &1.id)

    blocking_deps =
      Enum.filter(deps, fn d ->
        d.dep_type == :blocks and
          MapSet.member?(incomplete_ids, d.task_id) and
          MapSet.member?(incomplete_ids, d.depends_on_id)
      end)

    if blocking_deps == [] do
      MapSet.new()
    else
      # Build adjacency: depends_on -> [task_id]
      adj =
        Enum.reduce(blocking_deps, %{}, fn d, acc ->
          Map.update(acc, d.depends_on_id, [d.task_id], &[d.task_id | &1])
        end)

      # Find roots: incomplete tasks with no incoming blocking deps among incomplete set
      has_incoming =
        blocking_deps
        |> Enum.map(& &1.task_id)
        |> MapSet.new()

      roots =
        incomplete_ids
        |> MapSet.difference(has_incoming)
        |> MapSet.to_list()

      # DFS from each root, find longest path
      {_max_len, path_edges, _memo} =
        Enum.reduce(roots, {0, [], %{}}, fn root, {best_len, best_edges, memo} ->
          {len, edges, memo} = dfs_longest_path(root, adj, memo)

          if len > best_len do
            {len, edges, memo}
          else
            {best_len, best_edges, memo}
          end
        end)

      MapSet.new(path_edges)
    end
  end

  defp dfs_longest_path(node, adj, memo) do
    case Map.get(memo, node) do
      nil ->
        children = Map.get(adj, node, [])

        if children == [] do
          memo = Map.put(memo, node, {0, []})
          {0, [], memo}
        else
          {best, memo} =
            Enum.reduce(children, {{0, []}, memo}, fn child, {{best_len, best_edges}, memo} ->
              {child_len, child_edges, memo} = dfs_longest_path(child, adj, memo)
              candidate = {child_len + 1, [{node, child} | child_edges]}

              if child_len + 1 > best_len do
                {candidate, memo}
              else
                {{best_len, best_edges}, memo}
              end
            end)

          {len, edges} = best
          memo = Map.put(memo, node, {len, edges})
          {len, edges, memo}
        end

      {len, edges} ->
        {len, edges, memo}
    end
  end

  defp compute_svg_dimensions(positioned) do
    if positioned == [] do
      {400, 200}
    else
      max_x = Enum.max_by(positioned, & &1.x) |> Map.get(:x)
      max_y = Enum.max_by(positioned, & &1.y) |> Map.get(:y)
      {max_x + @node_width + 60, max_y + @node_height + 60}
    end
  end

  # --- Events ---

  @impl true
  def handle_event("select_node", %{"id" => node_id}, socket) do
    selected =
      if socket.assigns.selected_node && socket.assigns.selected_node.id == node_id do
        nil
      else
        Enum.find(socket.assigns.tasks, &(&1.id == node_id))
      end

    {:noreply, assign(socket, selected_node: selected)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_node: nil)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-gray-950 text-gray-100">
      <div class="px-3 py-2.5 border-b border-gray-800">
        <h3 class="text-[10px] font-semibold text-gray-500 uppercase tracking-widest">
          Task Graph
        </h3>
      </div>

      <div class="flex-1 overflow-auto relative">
        <%= if @tasks == [] do %>
          <div class="flex flex-col items-center justify-center h-full px-6 text-center">
            <div class="w-12 h-12 rounded-full bg-gray-800/60 flex items-center justify-center mb-3">
              <.icon name="hero-queue-list" class="w-6 h-6 text-gray-600" />
            </div>
            <p class="text-gray-400 text-sm font-medium mb-1">No tasks yet</p>
            <p class="text-gray-600 text-xs max-w-xs leading-relaxed">
              The task graph shows task dependencies and progress as agents work through the plan.
            </p>
          </div>
        <% else %>
          <svg
            width={@svg_width}
            height={@svg_height}
            viewBox={"0 0 #{@svg_width} #{@svg_height}"}
            class="block"
          >
            <defs>
              <marker
                id="task-arrowhead"
                markerWidth="8"
                markerHeight="6"
                refX="8"
                refY="3"
                orient="auto"
              >
                <polygon points="0 0, 8 3, 0 6" fill="#6b7280" />
              </marker>
              <marker
                id="task-arrowhead-critical"
                markerWidth="8"
                markerHeight="6"
                refX="8"
                refY="3"
                orient="auto"
              >
                <polygon points="0 0, 8 3, 0 6" fill="#f59e0b" />
              </marker>
            </defs>

            <%!-- Edges --%>
            <.task_edge
              :for={edge <- @edges}
              edge={edge}
              critical_path_edges={@critical_path_edges}
            />

            <%!-- Nodes --%>
            <.task_node
              :for={pos <- @positioned}
              pos={pos}
              selected={@selected_node && @selected_node.id == pos.node.id}
              myself={@myself}
            />
          </svg>

          <%!-- Status legend --%>
          <div class="px-3 py-2 border-t border-gray-800/50 flex flex-wrap gap-x-3 gap-y-1.5">
            <span class="text-[10px] text-gray-600 uppercase tracking-wider mr-1">Status:</span>
            <div
              :for={
                {status, label} <- [
                  {:pending, "Pending"},
                  {:assigned, "Assigned"},
                  {:in_progress, "In Progress"},
                  {:completed, "Completed"},
                  {:failed, "Failed"}
                ]
              }
              class="flex items-center gap-1.5"
            >
              <span
                class="inline-block w-2.5 h-2.5 rounded-full"
                style={"background-color: #{status_stroke(status)}"}
              />
              <span class="text-[10px] text-gray-500">{label}</span>
            </div>
          </div>

          <%!-- Detail panel --%>
          <.task_detail
            :if={@selected_node}
            node={@selected_node}
            deps={@deps}
            tasks={@tasks}
            myself={@myself}
          />
        <% end %>
      </div>
    </div>
    """
  end

  # --- SVG Sub-components ---

  defp task_node(assigns) do
    node = assigns.pos.node
    x = assigns.pos.x
    y = assigns.pos.y

    {fill, stroke} = status_colors(node.status)
    tooltip = if node.owner, do: "#{node.title} (#{node.owner})", else: node.title

    assigns =
      assigns
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:fill, fill)
      |> assign(:stroke, stroke)
      |> assign(:node, node)
      |> assign(:tooltip, tooltip)
      |> assign(:w, @node_width)
      |> assign(:h, @node_height)

    ~H"""
    <g
      phx-click="select_node"
      phx-value-id={@node.id}
      phx-target={@myself}
      class="cursor-pointer"
      role="button"
      tabindex="0"
    >
      <title>{@tooltip}</title>
      <rect
        x={@x}
        y={@y}
        width={@w}
        height={@h}
        rx="8"
        fill={@fill}
        stroke={@stroke}
        stroke-width={if @selected, do: "3", else: "1.5"}
      />
      <%!-- Status dot --%>
      <circle cx={@x + 14} cy={@y + 18} r="4" fill={@stroke} />
      <%!-- Title --%>
      <text
        x={@x + 24}
        y={@y + 22}
        fill="#e5e7eb"
        font-size="11"
        font-weight="600"
      >
        {truncate_text(@node.title, 14)}
      </text>
      <%!-- Agent name --%>
      <text
        :if={@node.owner}
        x={@x + @w / 2}
        y={@y + 42}
        text-anchor="middle"
        fill={@stroke}
        font-size="9"
      >
        {@node.owner}
      </text>
      <%!-- Status label --%>
      <text
        x={@x + @w / 2}
        y={@y + 54}
        text-anchor="middle"
        fill="#6b7280"
        font-size="8"
      >
        {format_status(@node.status)}
      </text>
    </g>
    """
  end

  defp task_edge(assigns) do
    edge = assigns.edge
    from_pos = edge.from_pos
    to_pos = edge.to_pos
    dep = edge.dep

    x1 = from_pos.x + @node_width / 2
    y1 = from_pos.y + @node_height
    x2 = to_pos.x + @node_width / 2
    y2 = to_pos.y

    mid_y = (y1 + y2) / 2
    path_d = "M#{x1},#{y1} C#{x1},#{mid_y} #{x2},#{mid_y} #{x2},#{y2}"

    is_critical =
      MapSet.member?(assigns.critical_path_edges, {dep.depends_on_id, dep.task_id})

    dash =
      if dep.dep_type == :informs, do: "6,4", else: nil

    {stroke_color, stroke_w, marker} =
      if is_critical do
        {"#f59e0b", "3", "task-arrowhead-critical"}
      else
        {"#6b7280", "1.5", "task-arrowhead"}
      end

    assigns =
      assigns
      |> assign(:path_d, path_d)
      |> assign(:stroke_color, stroke_color)
      |> assign(:stroke_w, stroke_w)
      |> assign(:marker, marker)
      |> assign(:dash, dash)

    ~H"""
    <path
      d={@path_d}
      fill="none"
      stroke={@stroke_color}
      stroke-width={@stroke_w}
      stroke-dasharray={@dash}
      marker-end={"url(##{@marker})"}
    />
    """
  end

  defp task_detail(assigns) do
    node = assigns.node

    dep_titles =
      assigns.deps
      |> Enum.filter(fn d -> d.task_id == node.id end)
      |> Enum.map(fn d ->
        dep_task = Enum.find(assigns.tasks, &(&1.id == d.depends_on_id))
        %{title: if(dep_task, do: dep_task.title, else: "unknown"), dep_type: d.dep_type}
      end)

    assigns = assign(assigns, :dep_titles, dep_titles)

    ~H"""
    <div class="absolute top-2 right-2 w-72 bg-gray-900 border border-gray-700/50 rounded-xl shadow-2xl z-20 overflow-hidden animate-scale-in">
      <div class="flex items-center justify-between px-3 py-2.5 border-b border-gray-800 bg-gray-900/80">
        <span class="text-sm font-semibold text-gray-200 truncate">{@node.title}</span>
        <button
          phx-click="close_detail"
          phx-target={@myself}
          class="text-gray-500 hover:text-gray-300 ml-2 p-0.5 rounded hover:bg-gray-800 transition-colors"
        >
          <.icon name="hero-x-mark-mini" class="w-4 h-4" />
        </button>
      </div>

      <div class="px-3 py-3 space-y-2.5 text-xs max-h-64 overflow-y-auto">
        <div class="flex gap-2">
          <span class="text-gray-500">Status:</span>
          <span class={status_text_class(@node.status)}>{format_status(@node.status)}</span>
        </div>
        <div :if={@node.owner} class="flex gap-2">
          <span class="text-gray-500">Agent:</span>
          <span class="text-gray-300">{@node.owner}</span>
        </div>
        <div :if={@node.description} class="pt-1">
          <span class="text-gray-500 block mb-1">Description:</span>
          <p class="text-gray-400 leading-relaxed">{@node.description}</p>
        </div>
        <div :if={@dep_titles != []} class="pt-1">
          <span class="text-gray-500 block mb-1">Dependencies:</span>
          <div :for={dep <- @dep_titles} class="flex items-center gap-1 text-gray-400 py-0.5">
            <span class={dep_type_class(dep.dep_type)}>{Atom.to_string(dep.dep_type)}</span>
            <span>&rarr;</span>
            <span>{dep.title}</span>
          </div>
        </div>
        <div :if={@node.result} class="pt-1">
          <span class="text-gray-500 block mb-1">Result:</span>
          <p class="text-gray-400 leading-relaxed">{@node.result}</p>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp status_colors(status) do
    case Map.get(@status_colors, status) do
      {stroke, fill} -> {fill, stroke}
      nil -> {"#1f2937", "#6b7280"}
    end
  end

  defp status_stroke(status) do
    case Map.get(@status_colors, status) do
      {stroke, _fill} -> stroke
      nil -> "#6b7280"
    end
  end

  defp status_text_class(:pending), do: "text-gray-400"
  defp status_text_class(:assigned), do: "text-blue-400"
  defp status_text_class(:in_progress), do: "text-amber-400"
  defp status_text_class(:completed), do: "text-green-400"
  defp status_text_class(:failed), do: "text-red-400"
  defp status_text_class(_), do: "text-gray-400"

  defp dep_type_class(:blocks), do: "text-orange-400"
  defp dep_type_class(:informs), do: "text-blue-400"
  defp dep_type_class(_), do: "text-gray-500"

  defp format_status(:in_progress), do: "in progress"
  defp format_status(status), do: Atom.to_string(status)

  defp truncate_text(nil, _), do: ""

  defp truncate_text(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 1) <> "..."
    else
      text
    end
  end
end
