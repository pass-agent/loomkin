defmodule LoomkinWeb.CommandPaletteComponent do
  use LoomkinWeb, :live_component

  def update(%{toggle: true}, socket) do
    if socket.assigns[:command_palette_open] do
      {:ok,
       assign(socket,
         command_palette_open: false,
         command_palette_query: "",
         command_palette_results: []
       )}
    else
      results = build_palette_results(socket, "")
      {:ok, assign(socket, command_palette_open: true, command_palette_results: results)}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:command_palette_open, fn -> false end)
      |> assign_new(:command_palette_query, fn -> "" end)
      |> assign_new(:command_palette_results, fn -> [] end)
      |> assign_new(:agents, fn -> [] end)

    {:ok, socket}
  end

  def handle_event("keyboard_shortcut", %{"key" => "command_palette"}, socket) do
    if socket.assigns.command_palette_open do
      {:noreply,
       assign(socket,
         command_palette_open: false,
         command_palette_query: "",
         command_palette_results: []
       )}
    else
      results = build_palette_results(socket, "")
      {:noreply, assign(socket, command_palette_open: true, command_palette_results: results)}
    end
  end

  def handle_event("palette_search", %{"value" => query}, socket) do
    results = build_palette_results(socket, query)
    {:noreply, assign(socket, command_palette_query: query, command_palette_results: results)}
  end

  def handle_event("palette_select", %{"type" => type, "value" => value}, socket) do
    send(self(), {:command_palette_action, type, value})

    {:noreply,
     assign(socket,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  def handle_event("close_command_palette", _params, socket) do
    {:noreply,
     assign(socket,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_results: []
     )}
  end

  def render(assigns) do
    ~H"""
    <div id={"#{@id}-wrapper"}>
      <div
        :if={@command_palette_open}
        class="fixed inset-0 z-50 flex items-start justify-center pt-[15vh]"
        phx-click="close_command_palette"
        phx-target={@myself}
      >
        <div class="fixed inset-0 bg-black/60" aria-hidden="true" />
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Command palette"
          class="relative w-full max-w-lg card-elevated overflow-hidden"
          style="box-shadow: 0 16px 64px rgba(0,0,0,0.6), 0 0 0 1px var(--border-default);"
          phx-click-away="close_command_palette"
          phx-target={@myself}
          phx-hook="CommandPalette"
          id="command-palette"
        >
          <div class="flex items-center gap-2 px-4 py-3 border-b border-subtle">
            <svg
              class="w-4 h-4 flex-shrink-0 text-muted"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
            <input
              type="text"
              id="command-palette-input"
              aria-label="Search agents, tabs, and actions"
              placeholder="Search agents, tabs, actions..."
              value={@command_palette_query}
              phx-keyup="palette_search"
              phx-target={@myself}
              name="query"
              class="flex-1 bg-transparent text-sm outline-none text-primary caret-brand"
              autocomplete="off"
              phx-debounce="100"
            />
            <kbd class="px-1.5 py-0.5 text-[10px] font-mono rounded bg-surface-2 text-muted">
              Esc
            </kbd>
          </div>

          <div class="max-h-72 overflow-y-auto py-1">
            <div
              :if={@command_palette_results == []}
              class="px-4 py-6 text-center text-sm text-muted"
            >
              No results found
            </div>
            <button
              :for={item <- @command_palette_results}
              data-palette-item
              phx-click="palette_select"
              phx-target={@myself}
              phx-value-type={item.type}
              phx-value-value={item.value}
              class="flex items-center justify-between w-full px-4 py-2 text-left text-sm transition-colors interactive"
            >
              <div class="flex items-center gap-2 min-w-0">
                <span class={palette_icon_class(item.type)} />
                <span class="truncate text-secondary">{item.label}</span>
              </div>
              <span class="text-xs flex-shrink-0 ml-2 text-muted">
                {item.detail}
              </span>
            </button>
          </div>

          <div class="flex items-center gap-4 px-4 py-2 text-[10px] border-t border-subtle text-muted opacity-70">
            <span>
              <kbd class="px-1 py-0.5 rounded font-mono bg-surface-2">↑↓</kbd> navigate
            </span>
            <span>
              <kbd class="px-1 py-0.5 rounded font-mono bg-surface-2">
                Enter
              </kbd>
              select
            </span>
            <span>
              <kbd class="px-1 py-0.5 rounded font-mono bg-surface-2">Esc</kbd> close
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp build_palette_results(socket, query) do
    q = String.downcase(String.trim(query))

    agents =
      (socket.assigns[:agents] || [])
      |> Enum.map(fn a ->
        %{type: :agent, label: a[:name] || "unknown", detail: "Agent", value: a[:name] || ""}
      end)

    tabs =
      Enum.map([:files, :diff, :graph], fn tab ->
        %{
          type: :tab,
          label: Atom.to_string(tab),
          detail: "Inspector Tab",
          value: Atom.to_string(tab)
        }
      end)

    sub_tabs =
      Enum.map([:activity, :cost, :graph], fn tab ->
        %{
          type: :sub_tab,
          label: Atom.to_string(tab),
          detail: "Kin Sub-tab",
          value: Atom.to_string(tab)
        }
      end)

    actions = [
      %{
        type: :action,
        label: "Toggle Mode (Solo/Mission Control)",
        detail: "Action",
        value: "toggle_mode"
      },
      %{type: :action, label: "Switch Project", detail: "Action", value: "switch_project"},
      %{type: :action, label: "Focus Input", detail: "Action", value: "focus_input"},
      %{
        type: :action,
        label: "Refresh Channel Bindings",
        detail: "Channels",
        value: "refresh_channels"
      }
    ]

    all = agents ++ tabs ++ sub_tabs ++ actions

    if q == "" do
      all
    else
      Enum.filter(all, fn item ->
        String.contains?(String.downcase(item.label), q) ||
          String.contains?(String.downcase(item.detail), q)
      end)
    end
  end

  defp palette_icon_class(:agent), do: "w-2 h-2 rounded-full bg-violet-400"
  defp palette_icon_class(:tab), do: "w-2 h-2 rounded-sm bg-blue-400"
  defp palette_icon_class(:sub_tab), do: "w-2 h-2 rounded-sm bg-emerald-400"
  defp palette_icon_class(:action), do: "w-2 h-2 rounded-full bg-amber-400"
  defp palette_icon_class(_), do: "w-2 h-2 rounded-full bg-gray-400"
end
