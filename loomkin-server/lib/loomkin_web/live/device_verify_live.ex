defmodule LoomkinWeb.DeviceVerifyLive do
  use LoomkinWeb, :live_view

  alias Loomkin.DeviceAuth

  def mount(params, _session, socket) do
    user_code = params["user_code"] || ""

    {:ok,
     assign(socket,
       page_title: "authorize device",
       user_code: user_code,
       device_code: nil,
       client_id: nil,
       scope: nil,
       state: :input
     )}
  end

  def handle_params(params, _uri, socket) do
    if params["user_code"] && socket.assigns.state == :input do
      {:noreply, socket |> assign(user_code: params["user_code"]) |> lookup_code()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("lookup", %{"user_code" => user_code}, socket) do
    {:noreply, socket |> assign(user_code: user_code) |> lookup_code()}
  end

  def handle_event("approve", _params, socket) do
    user_id = socket.assigns.current_scope.user.id

    case DeviceAuth.approve_device_code(socket.assigns.user_code, user_id) do
      {:ok, _dc} ->
        {:noreply, assign(socket, state: :approved)}

      {:error, _reason} ->
        {:noreply, assign(socket, state: :error)}
    end
  end

  def handle_event("deny", _params, socket) do
    case DeviceAuth.deny_device_code(socket.assigns.user_code) do
      {:ok, _dc} ->
        {:noreply, assign(socket, state: :denied)}

      {:error, _reason} ->
        {:noreply, assign(socket, state: :error)}
    end
  end

  defp lookup_code(socket) do
    case DeviceAuth.lookup_by_user_code(socket.assigns.user_code) do
      {:ok, dc} ->
        assign(socket,
          device_code: dc,
          client_id: dc.client_id,
          scope: dc.scope,
          state: :confirm
        )

      {:error, :not_found} ->
        assign(socket, state: :not_found)
    end
  end

  def render(assigns) do
    ~H"""
    <div
      class="loom-home min-h-screen relative overflow-hidden flex items-center justify-center"
      style="background: var(--surface-0);"
    >
      <%!-- Thread background --%>
      <svg class="absolute inset-0 w-full h-full" preserveAspectRatio="none" aria-hidden="true">
        <line
          x1="0%"
          y1="30%"
          x2="100%"
          y2="45%"
          stroke="var(--brand)"
          stroke-width="0.5"
          opacity="0.05"
          class="loom-thread-1"
        />
        <line
          x1="0%"
          y1="60%"
          x2="100%"
          y2="35%"
          stroke="var(--accent-amber)"
          stroke-width="0.5"
          opacity="0.04"
          class="loom-thread-2"
        />
        <line
          x1="0%"
          y1="75%"
          x2="100%"
          y2="55%"
          stroke="var(--accent-cyan)"
          stroke-width="0.3"
          opacity="0.03"
          class="loom-thread-3"
        />
      </svg>

      <div
        class="relative z-10 w-full max-w-xs px-5"
        style="animation: fadeUp 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;"
      >
        <%!-- Owl + title --%>
        <div class="text-center mb-12">
          <svg width="40" height="40" viewBox="0 0 32 32" fill="none" class="mx-auto mb-3">
            <path
              d="M16 3C9.5 3 5.5 7.5 5.5 13.5c0 3.5 1.5 6.5 3.5 8.5C11 24 13 26 16 26s5-2 7-4c2-2 3.5-5 3.5-8.5C26.5 7.5 22.5 3 16 3z"
              fill="var(--surface-1)"
              stroke="var(--brand)"
              stroke-width="1"
            />
            <path
              d="M11 5.5L9.5 2.5M21 5.5l1.5-3"
              stroke="var(--brand)"
              stroke-width="1.2"
              stroke-linecap="round"
            />
            <circle
              cx="12"
              cy="13"
              r="3.5"
              fill="var(--surface-0)"
              stroke="var(--accent-amber)"
              stroke-width="0.8"
            />
            <circle cx="12.3" cy="12.7" r="1.5" fill="var(--accent-amber)" />
            <circle
              cx="20"
              cy="13"
              r="3.5"
              fill="var(--surface-0)"
              stroke="var(--accent-amber)"
              stroke-width="0.8"
            />
            <circle cx="20.3" cy="12.7" r="1.5" fill="var(--accent-amber)" />
            <path
              d="M15 17l1 1.5 1-1.5"
              stroke="var(--accent-peach)"
              stroke-width="1"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <p
            class="font-mono text-[10px] tracking-[0.2em] uppercase"
            style="color: var(--text-muted);"
          >
            authorize device
          </p>
        </div>

        <%!-- Input state: enter code --%>
        <%= if @state == :input do %>
          <form id="device-code-form" phx-submit="lookup">
            <div class="space-y-5">
              <div>
                <label
                  for="user-code-input"
                  class="block text-[10px] font-mono uppercase tracking-widest mb-1"
                  style="color: var(--text-muted);"
                >
                  device code
                </label>
                <input
                  type="text"
                  id="user-code-input"
                  name="user_code"
                  value={@user_code}
                  autocomplete="off"
                  spellcheck="false"
                  required
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  class="w-full bg-transparent border-0 border-b px-0 py-2 text-sm font-mono outline-none focus:ring-0 text-center tracking-[0.3em] uppercase"
                  style="color: var(--text-primary); border-color: var(--border-default); caret-color: var(--brand);"
                  placeholder="XXXX-XXXX"
                />
              </div>
              <button type="submit" id="lookup-btn" class="loom-btn loom-btn-solid w-full">
                look up
              </button>
            </div>
          </form>
        <% end %>

        <%!-- Confirm state: approve or deny --%>
        <%= if @state == :confirm do %>
          <div class="space-y-6">
            <div
              class="py-3 px-4 text-[11px] font-mono"
              style="background: var(--surface-1); border: 1px solid var(--border-subtle); border-radius: 4px;"
            >
              <div class="flex justify-between mb-2">
                <span style="color: var(--text-muted);">client</span>
                <span style="color: var(--text-primary);">{@client_id}</span>
              </div>
              <div class="flex justify-between mb-2">
                <span style="color: var(--text-muted);">scope</span>
                <span style="color: var(--text-primary);">{@scope}</span>
              </div>
              <div class="flex justify-between">
                <span style="color: var(--text-muted);">code</span>
                <span style="color: var(--accent-amber); letter-spacing: 0.15em;">{@user_code}</span>
              </div>
            </div>
            <p
              class="text-[10px] font-mono text-center"
              style="color: var(--text-muted);"
            >
              grant this device access to your vaults?
            </p>
            <div class="flex gap-2">
              <button
                id="approve-btn"
                phx-click="approve"
                class="loom-btn loom-btn-solid flex-1"
              >
                approve
              </button>
              <button
                id="deny-btn"
                phx-click="deny"
                class="loom-btn loom-btn-ghost flex-1"
              >
                deny
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Not found --%>
        <%= if @state == :not_found do %>
          <div class="text-center space-y-4">
            <p class="text-sm font-mono" style="color: var(--accent-peach);">
              code not found or expired
            </p>
            <button
              phx-click={Phoenix.LiveView.JS.patch(~p"/device")}
              class="loom-btn loom-btn-outline w-full"
            >
              try again
            </button>
          </div>
        <% end %>

        <%!-- Approved --%>
        <%= if @state == :approved do %>
          <div class="text-center space-y-4">
            <p class="text-sm font-mono" style="color: var(--accent-emerald);">
              device authorized
            </p>
            <p class="text-[10px] font-mono" style="color: var(--text-muted);">
              you can close this page and return to your terminal
            </p>
          </div>
        <% end %>

        <%!-- Denied --%>
        <%= if @state == :denied do %>
          <div class="text-center space-y-4">
            <p class="text-sm font-mono" style="color: var(--accent-peach);">
              device denied
            </p>
            <p class="text-[10px] font-mono" style="color: var(--text-muted);">
              the device will not be granted access
            </p>
          </div>
        <% end %>

        <%!-- Error --%>
        <%= if @state == :error do %>
          <div class="text-center space-y-4">
            <p class="text-sm font-mono" style="color: var(--accent-peach);">
              something went wrong
            </p>
            <button
              phx-click={Phoenix.LiveView.JS.patch(~p"/device")}
              class="loom-btn loom-btn-outline w-full"
            >
              try again
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
