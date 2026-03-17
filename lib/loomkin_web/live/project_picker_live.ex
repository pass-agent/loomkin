defmodule LoomkinWeb.ProjectPickerLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Session.Persistence

  def mount(_params, _session, socket) do
    user = socket.assigns[:current_scope] && socket.assigns.current_scope.user
    projects = Persistence.list_projects(user: user)

    socket =
      socket
      |> assign(
        page_title: "Projects",
        view: :projects,
        selected_project: nil,
        new_path: "",
        new_path_error: nil,
        fp_open: false,
        fp_dir: nil,
        fp_entries: [],
        current_user: user
      )
      |> stream(:projects, projects, dom_id: &project_dom_id/1)

    {:ok, socket}
  end

  defp project_dom_id(%{project_path: path}) do
    "project-" <> Base.url_encode64(path, padding: false)
  end

  def handle_event("select_project", %{"path" => path}, socket) do
    sessions = Persistence.list_sessions_for_project(path, user: socket.assigns[:current_user])

    socket =
      socket
      |> assign(
        view: :sessions,
        selected_project: path,
        page_title: Path.basename(path)
      )
      |> stream(:sessions, sessions, reset: true)

    {:noreply, socket}
  end

  def handle_event("back_to_projects", _params, socket) do
    projects = Persistence.list_projects(user: socket.assigns[:current_user])

    socket =
      socket
      |> assign(
        view: :projects,
        selected_project: nil,
        page_title: "Projects"
      )
      |> stream(:projects, projects, reset: true, dom_id: &project_dom_id/1)

    {:noreply, socket}
  end

  def handle_event("fp_open", _params, socket) do
    dir =
      case socket.assigns.new_path do
        "" ->
          System.user_home!()

        path ->
          expanded = Path.expand(path)
          if File.dir?(expanded), do: expanded, else: System.user_home!()
      end

    {:noreply, assign(socket, fp_open: true, fp_dir: dir, fp_entries: list_subdirs(dir))}
  end

  def handle_event("fp_close", _params, socket) do
    {:noreply, assign(socket, fp_open: false)}
  end

  def handle_event("fp_navigate", %{"dir" => dir}, socket) do
    {:noreply, assign(socket, fp_dir: dir, fp_entries: list_subdirs(dir))}
  end

  def handle_event("fp_up", _params, socket) do
    parent = Path.dirname(socket.assigns.fp_dir)

    if parent != socket.assigns.fp_dir do
      {:noreply, assign(socket, fp_dir: parent, fp_entries: list_subdirs(parent))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("fp_select", _params, socket) do
    {:noreply, assign(socket, new_path: socket.assigns.fp_dir, fp_open: false)}
  end

  def handle_event("validate_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, new_path: path, new_path_error: nil)}
  end

  def handle_event("add_project", %{"path" => path}, socket) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:noreply, assign(socket, new_path_error: "Path cannot be empty")}

      not File.dir?(Path.expand(trimmed)) ->
        {:noreply, assign(socket, new_path_error: "Directory does not exist")}

      true ->
        {:noreply,
         push_navigate(socket, to: ~p"/sessions/new?#{%{project_path: Path.expand(trimmed)}}")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 flex items-center justify-center p-8">
      <div class="w-full max-w-2xl animate-fade-in">
        <%!-- Header --%>
        <div class="text-center mb-10">
          <h1 class="text-3xl font-semibold text-white tracking-tight">Loomkin</h1>
          <p class="text-gray-400 mt-2 text-sm">Select a project to get started</p>
        </div>

        <%= if @view == :projects do %>
          <.projects_view
            projects={@streams.projects}
            new_path={@new_path}
            new_path_error={@new_path_error}
            fp_open={@fp_open}
            fp_dir={@fp_dir}
            fp_entries={@fp_entries}
          />
        <% else %>
          <.sessions_view
            sessions={@streams.sessions}
            selected_project={@selected_project}
          />
        <% end %>
      </div>
    </div>
    """
  end

  attr :projects, :any, required: true
  attr :new_path, :string, required: true
  attr :new_path_error, :string, default: nil
  attr :fp_open, :boolean, required: true
  attr :fp_dir, :string, default: nil
  attr :fp_entries, :list, required: true

  defp projects_view(assigns) do
    ~H"""
    <div>
      <%!-- Add project input --%>
      <form
        id="add-project-form"
        phx-submit="add_project"
        phx-change="validate_path"
        class="mb-6"
      >
        <div class="flex gap-3">
          <div class="relative flex-1">
            <input
              type="text"
              name="path"
              value={@new_path}
              placeholder="Enter project directory path..."
              autocomplete="off"
              class={[
                "w-full bg-surface-1 border rounded-lg px-4 py-3 pr-10 text-sm text-gray-100",
                "placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-brand/50",
                "transition-colors",
                if(@new_path_error,
                  do: "border-accent-rose/50",
                  else: "border-border-default focus:border-brand"
                )
              ]}
            />
            <button
              type="button"
              phx-click="fp_open"
              class="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300 transition-colors"
              tabindex="-1"
              title="Browse folders"
            >
              <.icon name="hero-folder-mini" class="w-4 h-4" />
            </button>
            <div :if={@fp_open} class="absolute top-full mt-1 left-0 right-0 z-50">
              <div class="fixed inset-0 z-40" phx-click="fp_close" />
              <div class="relative z-50 bg-gray-900 border border-gray-700/60 rounded-xl shadow-2xl overflow-hidden">
                <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-700/50 bg-gray-800/60">
                  <button
                    type="button"
                    phx-click="fp_up"
                    class="text-gray-400 hover:text-gray-200 transition-colors p-0.5 rounded"
                  >
                    <.icon name="hero-arrow-left-mini" class="w-3.5 h-3.5" />
                  </button>
                  <span class="text-xs text-gray-400 font-mono truncate flex-1">{@fp_dir}</span>
                  <button
                    type="button"
                    phx-click="fp_close"
                    class="text-gray-500 hover:text-gray-300 transition-colors p-0.5 rounded"
                  >
                    <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
                  </button>
                </div>
                <div class="max-h-52 overflow-y-auto py-1">
                  <p
                    :if={@fp_entries == []}
                    class="px-3 py-3 text-xs text-gray-500 italic text-center"
                  >
                    No subdirectories
                  </p>
                  <button
                    :for={entry <- @fp_entries}
                    type="button"
                    phx-click="fp_navigate"
                    phx-value-dir={Path.join(@fp_dir, entry)}
                    class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-gray-300 hover:bg-gray-800 transition-colors"
                  >
                    <.icon name="hero-folder-mini" class="w-3.5 h-3.5 text-gray-500 flex-shrink-0" />
                    {entry}
                  </button>
                </div>
                <div class="border-t border-gray-700/50 px-3 py-2">
                  <button
                    type="button"
                    phx-click="fp_select"
                    class="w-full text-xs text-center text-violet-400 hover:text-violet-300 font-medium py-1 rounded-lg hover:bg-violet-500/10 transition-colors"
                  >
                    Select this folder
                  </button>
                </div>
              </div>
            </div>
            <p :if={@new_path_error} class="text-accent-rose text-xs mt-1.5 ml-1">
              {@new_path_error}
            </p>
          </div>
          <button
            type="submit"
            class={[
              "px-5 py-3 bg-brand hover:bg-brand/80 text-white text-sm font-medium",
              "rounded-lg transition-colors shrink-0"
            ]}
          >
            New Session
          </button>
        </div>
      </form>

      <%!-- Project list --%>
      <div id="projects" phx-update="stream" class="space-y-2">
        <div class="hidden only:block text-center py-16 text-gray-500">
          <p class="text-lg">No projects yet</p>
          <p class="text-sm mt-1">Enter a directory path above to start your first session</p>
        </div>
        <button
          :for={{id, project} <- @projects}
          id={id}
          phx-click="select_project"
          phx-value-path={project.project_path}
          class={[
            "w-full text-left bg-surface-1 border border-border-subtle rounded-lg p-4",
            "hover:bg-surface-2 hover:border-border-hover transition-all group cursor-pointer"
          ]}
        >
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <h3 class="text-white font-medium text-sm group-hover:text-brand transition-colors">
                {Path.basename(project.project_path)}
              </h3>
              <p class="text-gray-500 text-xs mt-0.5 truncate font-mono">
                {project.project_path}
              </p>
            </div>
            <div class="flex items-center gap-4 shrink-0 ml-4">
              <span class="text-gray-500 text-xs">
                {project.session_count} {if project.session_count == 1,
                  do: "session",
                  else: "sessions"}
              </span>
              <span class="text-gray-600 text-xs">
                {format_relative_time(project.last_active_at)}
              </span>
              <span class={[
                "hero-chevron-right w-4 h-4 text-gray-600 group-hover:text-gray-400",
                "transition-colors"
              ]} />
            </div>
          </div>
        </button>
      </div>
    </div>
    """
  end

  attr :sessions, :any, required: true
  attr :selected_project, :string, required: true

  defp sessions_view(assigns) do
    ~H"""
    <div>
      <%!-- Back button + project name --%>
      <div class="flex items-center gap-3 mb-6">
        <button
          phx-click="back_to_projects"
          class={[
            "flex items-center gap-1.5 text-gray-400 hover:text-white text-sm",
            "transition-colors"
          ]}
        >
          <span class="hero-arrow-left w-4 h-4" /> Projects
        </button>
        <span class="text-gray-600">/</span>
        <h2 class="text-white font-medium text-sm">{Path.basename(@selected_project)}</h2>
      </div>

      <%!-- New session button --%>
      <.link
        navigate={~p"/sessions/new?#{%{project_path: @selected_project}}"}
        class={[
          "flex items-center justify-center gap-2 w-full mb-4 px-4 py-3",
          "bg-brand hover:bg-brand/80 text-white text-sm font-medium",
          "rounded-lg transition-colors"
        ]}
      >
        <span class="hero-plus w-4 h-4" /> New Session
      </.link>

      <%!-- Sessions list --%>
      <div id="sessions" phx-update="stream" class="space-y-2">
        <div class="hidden only:block text-center py-12 text-gray-500">
          <p>No sessions for this project</p>
        </div>
        <.link
          :for={{id, session} <- @sessions}
          id={id}
          navigate={~p"/sessions/#{session.id}"}
          class={[
            "block bg-surface-1 border border-border-subtle rounded-lg p-4",
            "hover:bg-surface-2 hover:border-border-hover transition-all group"
          ]}
        >
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <h3 class="text-white font-medium text-sm group-hover:text-brand transition-colors truncate">
                  {session.title || "Untitled Session"}
                </h3>
                <.status_badge status={session.status} />
              </div>
              <div class="flex items-center gap-3 mt-1">
                <span :if={session.model} class="text-gray-500 text-xs font-mono">
                  {session.model}
                </span>
                <span class="text-gray-600 text-xs">
                  {format_relative_time(session.updated_at)}
                </span>
              </div>
            </div>
            <div class="flex items-center gap-2 shrink-0 ml-4">
              <span
                :if={session.status == :active}
                class={[
                  "px-2.5 py-1 bg-brand/10 text-brand text-xs font-medium rounded",
                  "group-hover:bg-brand/20 transition-colors"
                ]}
              >
                Resume
              </span>
              <span class={[
                "hero-chevron-right w-4 h-4 text-gray-600 group-hover:text-gray-400",
                "transition-colors"
              ]} />
            </div>
          </div>
        </.link>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider",
      if(@status == :active,
        do: "bg-accent-emerald/10 text-accent-emerald",
        else: "bg-gray-700/50 text-gray-400"
      )
    ]}>
      {@status}
    </span>
    """
  end

  defp list_subdirs(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(path, &1)))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp format_relative_time(nil), do: ""

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
