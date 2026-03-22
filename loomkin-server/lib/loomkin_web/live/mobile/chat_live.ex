defmodule LoomkinWeb.Mobile.ChatLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Relay.Server.DaemonChannel
  alias Loomkin.Repo
  alias Loomkin.Session.Persistence

  import LoomkinWeb.Mobile.Components
  import LoomkinWeb.Mobile.Layout

  def mount(%{"id" => session_id}, _session, socket) do
    user = socket.assigns[:current_scope] && socket.assigns.current_scope.user

    case Persistence.get_session(session_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/m")}

      session ->
        if user && session.user_id != nil && session.user_id != user.id do
          {:ok,
           socket
           |> put_flash(:error, "Not authorized")
           |> push_navigate(to: ~p"/m")}
        else
          workspace =
            if session.workspace_id, do: Repo.get(Loomkin.Workspace, session.workspace_id)

          socket =
            socket
            |> assign(
              page_title: session.title || "Chat",
              session: session,
              session_id: session.id,
              workspace_id: session.workspace_id,
              workspace: workspace,
              user: user,
              status: :idle,
              streaming_content: "",
              current_tool: nil,
              pending_permissions: [],
              input_text: ""
            )
            |> stream(:messages, [], dom_id: &"msg-#{&1.id}")

          socket =
            if connected?(socket) do
              messages = Persistence.load_messages(session_id)

              socket = stream(socket, :messages, messages, reset: true)

              # Subscribe to relay events if workspace exists
              if session.workspace_id do
                Phoenix.PubSub.subscribe(Loomkin.PubSub, "relay:events:#{session.workspace_id}")
              end

              socket
            else
              socket
            end

          {:ok, socket}
        end
    end
  end

  # --- Relay events ---

  def handle_info({:relay_event, %Event{} = event}, socket) do
    if event.session_id == socket.assigns.session_id do
      handle_relay_event(event.event_type, event.data, socket)
    else
      {:noreply, socket}
    end
  end

  # Catch-all for other messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- User events ---

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    trimmed = String.trim(text)

    if socket.assigns.workspace_id do
      # Relay mode — send to daemon via command
      command = %Command{
        request_id: Ecto.UUID.generate(),
        action: "send_message",
        workspace_id: socket.assigns.workspace_id,
        session_id: socket.assigns.session_id,
        payload: %{"content" => trimmed}
      }

      user = socket.assigns.user

      Task.start(fn ->
        DaemonChannel.send_command(user.id, socket.assigns.workspace_id, command)
      end)
    end

    # Optimistic UI: show the user message immediately
    user_msg = %{
      id: Ecto.UUID.generate(),
      role: :user,
      content: trimmed,
      inserted_at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> stream_insert(:messages, user_msg)
     |> assign(input_text: "", status: :thinking)
     |> push_event("scroll-bottom", %{})
     |> push_event("clear-input", %{})}
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns.workspace_id do
      command = %Command{
        request_id: Ecto.UUID.generate(),
        action: "cancel",
        workspace_id: socket.assigns.workspace_id,
        session_id: socket.assigns.session_id,
        payload: %{}
      }

      user = socket.assigns.user

      Task.start(fn ->
        DaemonChannel.send_command(user.id, socket.assigns.workspace_id, command)
      end)
    end

    {:noreply, assign(socket, status: :idle, streaming_content: "")}
  end

  def handle_event("approve_tool", %{"id" => perm_id}, socket) do
    {perm, remaining} = pop_permission(socket.assigns.pending_permissions, perm_id)

    if perm && socket.assigns.workspace_id do
      command = %Command{
        request_id: Ecto.UUID.generate(),
        action: "approve_tool",
        workspace_id: socket.assigns.workspace_id,
        session_id: socket.assigns.session_id,
        payload: %{"tool_name" => perm.tool_name, "tool_path" => perm[:tool_path]}
      }

      user = socket.assigns.user

      Task.start(fn ->
        DaemonChannel.send_command(user.id, socket.assigns.workspace_id, command)
      end)
    end

    {:noreply, assign(socket, pending_permissions: remaining)}
  end

  def handle_event("deny_tool", %{"id" => perm_id}, socket) do
    {perm, remaining} = pop_permission(socket.assigns.pending_permissions, perm_id)

    if perm && socket.assigns.workspace_id do
      command = %Command{
        request_id: Ecto.UUID.generate(),
        action: "deny_tool",
        workspace_id: socket.assigns.workspace_id,
        session_id: socket.assigns.session_id,
        payload: %{"tool_name" => perm.tool_name, "reason" => "denied from mobile"}
      }

      user = socket.assigns.user

      Task.start(fn ->
        DaemonChannel.send_command(user.id, socket.assigns.workspace_id, command)
      end)
    end

    {:noreply, assign(socket, pending_permissions: remaining)}
  end

  # --- Render ---

  def render(assigns) do
    back_path =
      if assigns.workspace do
        ~p"/m/workspaces/#{assigns.workspace.id}"
      else
        ~p"/m"
      end

    assigns = assign(assigns, :back_path, back_path)

    ~H"""
    <.mobile_layout page_title={@session.title || "Chat"} back_path={@back_path}>
      <div class="flex flex-col" style="height: calc(100vh - 52px);">
        <%!-- Status bar --%>
        <.status_indicator status={@status} tool_name={@current_tool} />

        <%!-- Messages --%>
        <div
          id="chat-messages"
          phx-update="stream"
          phx-hook="ScrollBottom"
          class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
        >
          <div class="hidden only:block text-center py-20">
            <p class="text-gray-500 text-sm">No messages yet</p>
            <p class="text-gray-600 text-xs mt-1">Send a message to start.</p>
          </div>
          <div :for={{id, msg} <- @streams.messages} id={id}>
            <.message_bubble
              role={msg.role}
              content={msg.content}
              timestamp={msg[:inserted_at]}
            />
          </div>
        </div>

        <%!-- Streaming preview --%>
        <div
          :if={@streaming_content != ""}
          class="px-4 pb-2"
        >
          <div class="bg-gray-800 rounded-2xl rounded-bl-md px-4 py-2.5 max-w-[85%]">
            <div class="text-sm text-gray-100 whitespace-pre-wrap break-words">
              {@streaming_content}<span class="inline-block w-1.5 h-4 bg-violet-400 animate-pulse ml-0.5 align-text-bottom" />
            </div>
          </div>
        </div>

        <%!-- Approval banners --%>
        <.approval_banner
          :if={@pending_permissions != []}
          permissions={@pending_permissions}
          session_id={@session_id}
        />

        <%!-- Input bar --%>
        <div class="border-t border-gray-800 bg-gray-900 px-4 py-3">
          <form
            id="chat-form"
            phx-submit="send_message"
            class="flex items-end gap-2"
          >
            <textarea
              name="text"
              id="chat-input"
              rows="1"
              placeholder="Message..."
              autocomplete="off"
              phx-hook="AutoResize"
              class={[
                "flex-1 bg-gray-800 border border-gray-700 rounded-xl px-4 py-2.5 text-sm text-white",
                "placeholder-gray-500 focus:outline-none focus:border-violet-500 resize-none",
                "max-h-32 overflow-y-auto"
              ]}
            />
            <%= if @status in [:thinking, :streaming, :tool_running] do %>
              <button
                type="button"
                phx-click="cancel"
                class="shrink-0 w-10 h-10 flex items-center justify-center rounded-xl bg-red-600/20 text-red-400 active:bg-red-600/40 transition-colors"
                id="cancel-btn"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  class="w-5 h-5"
                >
                  <path d="M5.75 3a.75.75 0 00-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 00.75-.75V3.75A.75.75 0 007.25 3h-1.5zM12.75 3a.75.75 0 00-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 00.75-.75V3.75a.75.75 0 00-.75-.75h-1.5z" />
                </svg>
              </button>
            <% else %>
              <button
                type="submit"
                class="shrink-0 w-10 h-10 flex items-center justify-center rounded-xl bg-violet-600 text-white active:bg-violet-700 transition-colors"
                id="send-btn"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  class="w-5 h-5"
                >
                  <path d="M3.105 2.289a.75.75 0 00-.826.95l1.414 4.925A1.5 1.5 0 005.135 9.25H13.5a.75.75 0 010 1.5H5.135a1.5 1.5 0 00-1.442 1.086l-1.414 4.926a.75.75 0 00.826.95 28.896 28.896 0 0015.293-7.154.75.75 0 000-1.115A28.897 28.897 0 003.105 2.289z" />
                </svg>
              </button>
            <% end %>
          </form>
        </div>
      </div>
    </.mobile_layout>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
      export default {
        mounted() {
          this.scrollToBottom()
          this.observer = new MutationObserver(() => this.scrollToBottom())
          this.observer.observe(this.el, { childList: true, subtree: true })
          this.handleEvent("scroll-bottom", () => this.scrollToBottom())
        },
        scrollToBottom() {
          this.el.scrollTop = this.el.scrollHeight
        },
        destroyed() {
          if (this.observer) this.observer.disconnect()
        }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoResize">
      export default {
        mounted() {
          this.el.addEventListener("input", () => this.resize())
          this.handleEvent("clear-input", () => {
            this.el.value = ""
            this.resize()
          })
        },
        resize() {
          this.el.style.height = "auto"
          this.el.style.height = Math.min(this.el.scrollHeight, 128) + "px"
        }
      }
    </script>
    """
  end

  # --- Relay event handlers ---

  defp handle_relay_event("agent.stream.start", _data, socket) do
    {:noreply, assign(socket, status: :streaming, streaming_content: "")}
  end

  defp handle_relay_event("agent.stream.delta", data, socket) do
    chunk = data["text"] || data["content"] || ""
    {:noreply, assign(socket, streaming_content: socket.assigns.streaming_content <> chunk)}
  end

  defp handle_relay_event("agent.stream.end", _data, socket) do
    {:noreply, assign(socket, status: :idle, streaming_content: "")}
  end

  defp handle_relay_event("session.new_message", data, socket) do
    msg = build_message_from_data(data)
    {:noreply, stream_insert(socket, :messages, msg)}
  end

  defp handle_relay_event("session.status_changed", data, socket) do
    status =
      case data["status"] do
        "thinking" -> :thinking
        "streaming" -> :streaming
        "tool_running" -> :tool_running
        _ -> :idle
      end

    {:noreply, assign(socket, status: status, current_tool: data["tool_name"])}
  end

  defp handle_relay_event("team.permission.request", data, socket) do
    perm = %{
      id: data["request_id"] || Ecto.UUID.generate(),
      tool_name: data["tool_name"],
      tool_path: data["tool_path"],
      agent_name: data["agent_name"]
    }

    {:noreply, assign(socket, pending_permissions: socket.assigns.pending_permissions ++ [perm])}
  end

  defp handle_relay_event("approval.requested", data, socket) do
    handle_relay_event("team.permission.request", data, socket)
  end

  defp handle_relay_event("team.permission.resolved", data, socket) do
    permissions =
      Enum.reject(socket.assigns.pending_permissions, &(&1.id == data["request_id"]))

    {:noreply, assign(socket, pending_permissions: permissions)}
  end

  defp handle_relay_event("approval.resolved", data, socket) do
    handle_relay_event("team.permission.resolved", data, socket)
  end

  defp handle_relay_event("session.cancelled", _data, socket) do
    {:noreply, assign(socket, status: :idle, streaming_content: "")}
  end

  defp handle_relay_event(_type, _data, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp pop_permission(permissions, id) do
    case Enum.split_with(permissions, &(&1.id == id)) do
      {[perm], remaining} -> {perm, remaining}
      {[], remaining} -> {nil, remaining}
    end
  end

  defp build_message_from_data(data) do
    role =
      case data["role"] do
        "user" -> :user
        "assistant" -> :assistant
        _ -> :assistant
      end

    %{
      id: data["id"] || Ecto.UUID.generate(),
      role: role,
      content: data["content"] || "",
      inserted_at: DateTime.utc_now()
    }
  end
end
