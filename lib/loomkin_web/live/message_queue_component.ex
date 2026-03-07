defmodule LoomkinWeb.MessageQueueComponent do
  @moduledoc """
  LiveComponent slide-out drawer for an agent's pending message queue.
  Manages selection and editing state internally. Delegates agent
  operations (edit, delete, squash, reorder) to the parent LiveView
  via `send(self(), {:queue_action, ...})`.
  """

  use LoomkinWeb, :live_component

  import LoomkinWeb.CoreComponents, only: [icon: 1]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, selected_ids: MapSet.new(), editing_id: nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # --- Internal UI events ---

  @impl true
  def handle_event("close_queue_drawer", _params, socket) do
    send(self(), {:queue_action, :close_drawer})
    {:noreply, assign(socket, selected_ids: MapSet.new(), editing_id: nil)}
  end

  def handle_event("toggle_queue_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    selected =
      if MapSet.member?(selected, id) do
        MapSet.delete(selected, id)
      else
        MapSet.put(selected, id)
      end

    {:noreply, assign(socket, selected_ids: selected)}
  end

  def handle_event("deselect_all_queued", _params, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  def handle_event("start_queued_edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_id: id)}
  end

  def handle_event("cancel_queued_edit", _params, socket) do
    {:noreply, assign(socket, editing_id: nil)}
  end

  # --- Delegated agent operations ---

  def handle_event(
        "save_queued_edit",
        %{"message_id" => id, "content" => content},
        socket
      ) do
    send(
      self(),
      {:queue_action, :save_edit, socket.assigns.agent_name, socket.assigns.team_id,
       %{id: id, content: content}}
    )

    {:noreply, assign(socket, editing_id: nil)}
  end

  def handle_event("delete_queued", %{"id" => id}, socket) do
    send(self(), {:queue_action, :delete, socket.assigns.agent_name, socket.assigns.team_id, id})
    {:noreply, socket}
  end

  def handle_event("delete_selected_queued", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)

    send(
      self(),
      {:queue_action, :delete_selected, socket.assigns.agent_name, socket.assigns.team_id, ids}
    )

    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  def handle_event("squash_queued", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    send(self(), {:queue_action, :squash, socket.assigns.agent_name, socket.assigns.team_id, ids})
    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  def handle_event("reorder_queue", %{"ids" => ordered_ids}, socket) do
    send(
      self(),
      {:queue_action, :reorder, socket.assigns.agent_name, socket.assigns.team_id, ordered_ids}
    )

    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    selected_count = MapSet.size(assigns.selected_ids)
    assigns = assign(assigns, :selected_count, selected_count)

    ~H"""
    <div
      id={"queue-drawer-#{@agent_name}"}
      class="fixed inset-y-0 right-0 z-50 w-80 flex flex-col animate-slide-in-right bg-surface-1 border-l border-subtle shadow-surface-lg"
      phx-click-away="close_queue_drawer"
      phx-target={@myself}
    >
      <%!-- Header --%>
      <div class="flex items-center gap-2 px-4 py-3 flex-shrink-0 border-b border-subtle">
        <.icon name="hero-queue-list-mini" class="w-4 h-4 text-indigo-400" />
        <span class="text-sm font-medium text-primary">
          {@agent_name}
        </span>
        <span class="text-[10px] px-1.5 py-0.5 rounded-full font-medium bg-indigo-500/15 text-indigo-400">
          {length(@queue)} queued
        </span>
        <div class="flex-1"></div>
        <button
          phx-click="close_queue_drawer"
          phx-target={@myself}
          class="p-1 rounded-md interactive text-muted"
          title="Close"
        >
          <.icon name="hero-x-mark-mini" class="w-4 h-4" />
        </button>
      </div>

      <%!-- Multi-select toolbar --%>
      <div
        :if={@selected_count > 0}
        class="flex items-center gap-2 px-4 py-2 flex-shrink-0 border-b border-subtle bg-brand-subtle"
      >
        <span class="text-xs font-medium text-brand">
          {@selected_count} selected
        </span>
        <div class="flex-1"></div>
        <button
          phx-click="squash_queued"
          phx-target={@myself}
          class="text-[11px] px-2 py-1 rounded-md font-medium text-indigo-300 bg-indigo-500/15 hover:bg-indigo-500/25 transition-colors"
        >
          Squash
        </button>
        <button
          phx-click="delete_selected_queued"
          phx-target={@myself}
          class="text-[11px] px-2 py-1 rounded-md font-medium text-red-300 bg-red-500/15 hover:bg-red-500/25 transition-colors"
        >
          Delete
        </button>
        <button
          phx-click="deselect_all_queued"
          phx-target={@myself}
          class="text-[11px] px-2 py-1 rounded-md font-medium interactive text-muted"
        >
          Clear
        </button>
      </div>

      <%!-- Queue list --%>
      <div
        id={"queue-list-#{@agent_name}"}
        class="flex-1 overflow-auto"
        phx-hook="SortableQueue"
        phx-update="ignore"
        phx-target={@myself}
        data-agent={@agent_name}
      >
        <%= if @queue == [] do %>
          <div class="flex flex-col items-center justify-center py-12 gap-3">
            <.icon name="hero-inbox-mini" class="w-8 h-8 text-zinc-600" />
            <span class="text-xs text-muted">No messages queued</span>
          </div>
        <% else %>
          <div
            :for={msg <- @queue}
            id={"queue-item-#{msg.id}"}
            class="group/item px-4 py-3 cursor-default border-b border-subtle"
            data-id={msg.id}
          >
            <%= if @editing_id == msg.id do %>
              <%!-- Inline editor --%>
              <form
                phx-submit="save_queued_edit"
                phx-target={@myself}
                id={"queue-edit-form-#{msg.id}"}
                class="flex flex-col gap-2"
              >
                <input type="hidden" name="message_id" value={msg.id} />
                <textarea
                  name="content"
                  rows="3"
                  class="w-full rounded-lg px-3 py-2 text-xs resize-none focus:outline-none bg-surface-0 border border-brand text-primary caret-brand"
                  autofocus
                  id={"queue-edit-#{msg.id}"}
                >{msg.content}</textarea>
                <div class="flex gap-1.5 justify-end">
                  <button
                    type="button"
                    phx-click="cancel_queued_edit"
                    phx-target={@myself}
                    class="text-[11px] px-2.5 py-1 rounded-md interactive text-muted border border-subtle"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="text-[11px] px-2.5 py-1 rounded-md font-medium text-white bg-brand"
                  >
                    Save
                  </button>
                </div>
              </form>
            <% else %>
              <div class="flex items-start gap-2">
                <%!-- Drag handle --%>
                <span class="flex-shrink-0 mt-0.5 cursor-grab opacity-0 group-hover/item:opacity-40 transition-opacity drag-handle">
                  <.icon name="hero-bars-3-mini" class="w-3.5 h-3.5 text-muted" />
                </span>

                <%!-- Checkbox --%>
                <input
                  type="checkbox"
                  checked={MapSet.member?(@selected_ids, msg.id)}
                  phx-click="toggle_queue_select"
                  phx-target={@myself}
                  phx-value-id={msg.id}
                  class="flex-shrink-0 mt-0.5 w-3.5 h-3.5 rounded border-zinc-600 bg-zinc-800 text-indigo-500 focus:ring-0 focus:ring-offset-0 cursor-pointer"
                />

                <div class="flex-1 min-w-0">
                  <%!-- Priority + source badges --%>
                  <div class="flex items-center gap-1.5 mb-1">
                    <span class={[
                      "w-1.5 h-1.5 rounded-full flex-shrink-0",
                      priority_dot_class(msg.priority)
                    ]}>
                    </span>
                    <span class={[
                      "text-[10px] px-1.5 py-0.5 rounded font-medium",
                      source_badge_class(msg.source)
                    ]}>
                      {msg.source}
                    </span>
                    <span
                      id={"queue-time-#{msg.id}"}
                      class="text-[10px] text-muted ml-auto flex-shrink-0"
                      phx-hook="LocalTime"
                      data-utc-time={if(msg.queued_at, do: DateTime.to_iso8601(msg.queued_at))}
                      data-format="relative"
                    >
                    </span>
                  </div>

                  <%!-- Content preview --%>
                  <p class="text-xs leading-relaxed line-clamp-2 text-secondary">
                    {msg.content}
                  </p>
                </div>

                <%!-- Action buttons --%>
                <div class="flex items-center gap-0.5 flex-shrink-0 opacity-0 group-hover/item:opacity-100 transition-opacity">
                  <button
                    phx-click="start_queued_edit"
                    phx-target={@myself}
                    phx-value-id={msg.id}
                    title="Edit"
                    class="p-1 rounded-md interactive text-muted"
                  >
                    <.icon name="hero-pencil-mini" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    phx-click="delete_queued"
                    phx-target={@myself}
                    phx-value-id={msg.id}
                    title="Delete"
                    class="p-1 rounded-md interactive text-red-400/60 hover:text-red-400"
                  >
                    <.icon name="hero-trash-mini" class="w-3.5 h-3.5" />
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp priority_dot_class(:urgent), do: "bg-red-400"
  defp priority_dot_class(:high), do: "bg-amber-400"
  defp priority_dot_class(_), do: "bg-zinc-500"

  defp source_badge_class(:user), do: "bg-blue-500/15 text-blue-400"
  defp source_badge_class(:system), do: "bg-purple-500/15 text-purple-400"
  defp source_badge_class(:peer), do: "bg-green-500/15 text-green-400"
  defp source_badge_class(:scheduled), do: "bg-amber-500/15 text-amber-400"
  defp source_badge_class(_), do: "bg-zinc-500/15 text-zinc-400"
end
