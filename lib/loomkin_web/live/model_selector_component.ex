defmodule LoomkinWeb.ModelSelectorComponent do
  use LoomkinWeb, :live_component

  def mount(socket) do
    {active, unconfigured, all} = load_providers()

    {:ok,
     assign(socket,
       open: false,
       search: "",
       custom_mode: false,
       custom_value: "",
       show_unconfigured: false,
       active_providers: active,
       unconfigured_providers: unconfigured,
       all_providers: all,
       paste_back_provider: nil,
       paste_back_error: nil,
       paste_back_submitting: false
     )}
  end

  def update(assigns, socket) do
    # Re-fetch providers when the model changes OR auth status changes
    socket = assign(socket, assigns)

    old_model = socket.assigns[:prev_model]
    new_model = assigns[:model]
    old_auth = socket.assigns[:prev_auth_version]
    new_auth = assigns[:auth_version]

    socket =
      if old_model != new_model or (new_auth != nil and old_auth != new_auth) do
        {active, unconfigured, all} = load_providers()

        assign(socket,
          prev_model: new_model,
          prev_auth_version: new_auth,
          active_providers: active,
          unconfigured_providers: unconfigured,
          all_providers: all
        )
      else
        socket
      end

    search = socket.assigns.search

    {:ok,
     assign(socket,
       filtered_providers: filtered_active(socket.assigns.active_providers, search),
       filtered_unconfigured: filtered_active(socket.assigns.unconfigured_providers, search)
     )}
  end

  defp load_providers do
    all = Loomkin.Models.all_providers_enriched()

    # Split into configured (has key/OAuth + models) and unconfigured
    {active, unconfigured} =
      Enum.split_with(all, fn {_p, _name, status, models} ->
        (match?({:set, _}, status) or match?({:oauth, :connected}, status)) and models != []
      end)

    {active, unconfigured, all}
  end

  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="ModelSelector" class="relative">
      <%!-- Trigger --%>
      <button
        type="button"
        phx-click="toggle_dropdown"
        phx-target={@myself}
        class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs press-down cursor-pointer"
        style={"border: 1px solid #{if @open, do: "var(--border-brand)", else: "var(--border-subtle)"}; color: var(--text-secondary); transition: all 150ms ease;"}
      >
        <span
          :if={assigns[:selector_mode]}
          class="text-[10px] uppercase tracking-wider mr-0.5"
          style="color: var(--text-muted);"
        >
          {if assigns[:selector_mode] == :fast, do: "Fast", else: "Thinking"}
        </span>
        <span class="truncate max-w-[140px] font-medium" style="color: var(--text-primary);">
          {current_model_label(@model, @all_providers)}
        </span>
        <svg
          class={"w-3 h-3 transition-transform duration-150 #{if @open, do: "rotate-180"}"}
          style="color: var(--text-muted);"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <%!-- Dropdown --%>
      <div
        :if={@open}
        class="absolute top-full left-0 mt-1.5 w-72 rounded-xl overflow-hidden"
        style="z-index: 9999; background: var(--surface-2); border: 1px solid var(--border-default); box-shadow: 0 20px 60px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.06);"
        phx-click-away="close_dropdown"
        phx-target={@myself}
      >
        <%!-- Search --%>
        <div class="p-2" style="border-bottom: 1px solid var(--border-subtle);">
          <div class="relative">
            <svg
              class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5"
              style="color: var(--text-muted);"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
            <input
              type="text"
              placeholder="Search models..."
              value={@search}
              phx-keyup="search_models"
              phx-target={@myself}
              id="model-search-input"
              class="w-full text-xs rounded-lg pl-8 pr-3 py-1.5 focus:outline-none"
              style="background: var(--surface-1); border: 1px solid var(--border-subtle); color: var(--text-primary); caret-color: var(--brand);"
            />
          </div>
        </div>

        <%!-- Model list --%>
        <div class="max-h-72 overflow-y-auto overscroll-contain" id="model-list">
          <%= if @filtered_providers == [] and @search != "" do %>
            <%= for {provider_atom, display_name, key_status, models} <- @filtered_unconfigured do %>
              <.provider_group
                provider_atom={provider_atom}
                display_name={display_name}
                key_status={key_status}
                models={models}
                current_model={@model}
                myself={@myself}
              />
            <% end %>
            <div
              :if={@filtered_unconfigured == []}
              class="px-4 py-6 text-center"
            >
              <p class="text-xs" style="color: var(--text-muted);">
                No models match "<span style="color: var(--text-secondary);">{@search}</span>"
              </p>
            </div>
          <% else %>
            <%= for {provider_atom, display_name, key_status, models} <- @filtered_providers do %>
              <.provider_group
                provider_atom={provider_atom}
                display_name={display_name}
                key_status={key_status}
                models={models}
                current_model={@model}
                myself={@myself}
              />
            <% end %>
          <% end %>

          <%!-- Empty state --%>
          <div :if={@active_providers == [] and @search == ""} class="px-4 py-6 text-center">
            <div class="text-2xl mb-2 opacity-50">&#128273;</div>
            <p class="text-xs font-medium" style="color: var(--text-secondary);">
              No providers configured
            </p>
            <p class="text-[11px] mt-1" style="color: var(--text-muted);">
              Add provider keys to your
              <span class="font-mono" style="color: var(--text-secondary);">.env</span>
              file or connect via OAuth
            </p>
          </div>
        </div>

        <%!-- Key warning --%>
        <.key_warning_banner model={@model} all_providers={@all_providers} myself={@myself} />

        <%!-- Unconfigured providers --%>
        <div
          :if={@unconfigured_providers != [] and @search == ""}
          style="border-top: 1px solid var(--border-subtle);"
        >
          <button
            type="button"
            phx-click="toggle_unconfigured"
            phx-target={@myself}
            class="flex items-center justify-between w-full px-3 py-1.5 text-xs transition-colors duration-150"
            style="color: var(--text-muted);"
          >
            <span class="flex items-center gap-1.5">
              <svg
                class="w-3 h-3"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              {length(@unconfigured_providers)} more
            </span>
            <svg
              class={"w-3 h-3 transition-transform duration-150 #{if @show_unconfigured, do: "rotate-180"}"}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
            </svg>
          </button>

          <div
            :if={@show_unconfigured}
            class="max-h-48 overflow-y-auto"
            style="border-top: 1px solid var(--border-subtle); background: var(--surface-0);"
          >
            <%= for {provider_atom, display_name, status, _models} <- @unconfigured_providers do %>
              <%= case status do %>
                <% {:oauth, :disconnected} -> %>
                  <div class="flex items-center justify-between px-3 py-1.5 group/setup">
                    <span class="text-[11px]" style="color: var(--text-secondary);">
                      {display_name}
                    </span>
                    <button
                      type="button"
                      phx-click="start_oauth_flow"
                      phx-value-provider={provider_atom}
                      phx-target={@myself}
                      class="text-[10px] font-medium transition-colors duration-150 cursor-pointer"
                      style="color: var(--brand); opacity: 0.7;"
                    >
                      Connect with OAuth
                    </button>
                  </div>
                <% {:missing, env_var} -> %>
                  <div class="flex items-center justify-between px-3 py-1 group/setup">
                    <span class="text-[11px]" style="color: var(--text-muted);">{display_name}</span>
                    <span
                      class="text-[10px] font-mono transition-colors duration-150"
                      style="color: var(--text-muted); opacity: 0.6;"
                    >
                      {env_var}
                    </span>
                  </div>
                <% _ -> %>
                  <div class="flex items-center justify-between px-3 py-1.5 group/setup">
                    <span class="text-[11px]" style="color: var(--text-muted);">{display_name}</span>
                  </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Custom model --%>
        <div class="p-2" style="border-top: 1px solid var(--border-subtle);">
          <%= if @custom_mode do %>
            <form phx-submit="apply_custom" phx-target={@myself} class="flex items-center gap-1.5">
              <input
                type="text"
                name="model"
                value={@custom_value}
                placeholder="provider:model-id"
                autofocus
                phx-keydown="custom_key"
                phx-target={@myself}
                class="flex-1 text-xs rounded-lg px-2.5 py-1.5 focus:outline-none font-mono"
                style="background: var(--surface-1); border: 1px solid var(--border-subtle); color: var(--text-primary); caret-color: var(--brand);"
              />
              <button
                type="submit"
                class="text-xs px-2 py-1.5 rounded-md"
                style="color: var(--text-brand);"
              >
                Use
              </button>
              <button
                type="button"
                phx-click="cancel_custom"
                phx-target={@myself}
                class="text-xs px-1.5 py-1.5 rounded-md"
                style="color: var(--text-muted);"
              >
                &times;
              </button>
            </form>
          <% else %>
            <button
              type="button"
              phx-click="enter_custom"
              phx-target={@myself}
              class="flex items-center gap-1.5 w-full px-2.5 py-1.5 text-xs rounded-lg transition-all duration-150 interactive"
              style="color: var(--text-muted);"
            >
              <svg
                class="w-3 h-3"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              Custom model...
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Paste-back Modal (for providers like Anthropic that redirect to their own domain) --%>
      <div
        :if={@paste_back_provider != nil}
        class="fixed inset-0 z-[60] flex items-center justify-center bg-black/60 backdrop-blur-sm"
        phx-click="cancel_paste"
        phx-target={@myself}
      >
        <div
          class="w-96 bg-gray-900 border border-gray-700/50 rounded-xl shadow-2xl shadow-black/50 p-5"
          phx-click-away="cancel_paste"
          phx-target={@myself}
          onclick="event.stopPropagation()"
        >
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-semibold text-gray-200">
              Connect to {provider_display_name(@paste_back_provider)}
            </h3>
            <button
              type="button"
              phx-click="cancel_paste"
              phx-target={@myself}
              class="text-gray-500 hover:text-gray-300 transition-colors duration-150"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <div class="space-y-3">
            <p class="text-xs text-gray-400">
              A new window has opened for you to sign in. After authorizing,
              you'll receive a code. Paste it below:
            </p>

            <form phx-submit="submit_paste_code" phx-target={@myself}>
              <input
                type="text"
                name="code_with_state"
                id="paste-code-input"
                placeholder="Paste the code here..."
                autocomplete="off"
                disabled={@paste_back_submitting}
                class="w-full bg-gray-800/60 border border-gray-700/50 text-gray-300 text-xs rounded-lg px-3 py-2.5 focus:outline-none focus:ring-1 focus:ring-violet-500/50 focus:border-violet-500/30 placeholder-gray-600 font-mono disabled:opacity-50"
              />

              <div
                :if={@paste_back_error}
                class="mt-2 px-2 py-1.5 bg-red-500/10 border border-red-500/20 rounded-lg"
              >
                <p class="text-[11px] text-red-400">{@paste_back_error}</p>
              </div>

              <div class="flex items-center justify-end gap-2 mt-4">
                <button
                  type="button"
                  phx-click="cancel_paste"
                  phx-target={@myself}
                  disabled={@paste_back_submitting}
                  class="text-xs text-gray-500 hover:text-gray-300 px-3 py-1.5 rounded-lg hover:bg-gray-800 transition-colors duration-150 disabled:opacity-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={@paste_back_submitting}
                  class="text-xs text-white bg-violet-600 hover:bg-violet-500 px-4 py-1.5 rounded-lg font-medium transition-colors duration-150 disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <%= if @paste_back_submitting do %>
                    Connecting...
                  <% else %>
                    Connect
                  <% end %>
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Provider Group ---

  defp provider_group(assigns) do
    ~H"""
    <div class="px-1.5 pt-2.5 pb-0.5">
      <div class="flex items-center justify-between px-1.5 mb-0.5">
        <span
          class="text-[10px] font-semibold uppercase tracking-wider"
          style="color: var(--text-muted);"
        >
          {@display_name}
        </span>
        <div class="flex items-center gap-1">
          <%= case @key_status do %>
            <% {:set, _env_var} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
                <span class="text-[10px]" style="color: rgba(52, 211, 153, 0.7);">API Key</span>
              </span>
            <% {:oauth, :connected} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full" style="background: var(--brand);"></span>
                <span class="text-[10px]" style="color: var(--brand); opacity: 0.7;">OAuth</span>
              </span>
            <% {:oauth, :disconnected} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full" style="background: var(--text-muted);"></span>
                <span class="text-[10px]" style="color: var(--text-muted);">Not connected</span>
              </span>
            <% {:missing, env_var} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-amber-400/60"></span>
                <span class="text-[10px] font-mono" style="color: rgba(251, 191, 36, 0.6);">
                  {env_var}
                </span>
              </span>
          <% end %>
        </div>
      </div>

      <%= for {label, value, context_k} <- @models do %>
        <button
          type="button"
          phx-click="select_model"
          phx-value-model={value}
          phx-target={@myself}
          class="flex items-center justify-between w-full px-1.5 py-1 rounded-md text-left transition-all duration-100 group/item interactive"
          style={
            if value == @current_model,
              do:
                "background: rgba(124, 58, 237, 0.12); box-shadow: inset 0 0 0 1px rgba(124, 58, 237, 0.2);",
              else: ""
          }
        >
          <div class="flex items-center gap-1.5 min-w-0">
            <%= if value == @current_model do %>
              <svg
                class="w-3 h-3 shrink-0"
                style="color: var(--text-brand);"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="3"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
              </svg>
            <% else %>
              <div class="w-3 h-3 shrink-0"></div>
            <% end %>
            <span
              class="text-xs truncate"
              style={
                if value == @current_model,
                  do: "color: var(--text-brand); font-weight: 500;",
                  else: "color: var(--text-secondary);"
              }
            >
              {label}
            </span>
          </div>
          <span
            :if={context_k}
            class="text-[10px] font-mono shrink-0 ml-2"
            style="color: var(--text-muted);"
          >
            {context_k}
          </span>
        </button>
      <% end %>
    </div>
    """
  end

  # --- Key Warning Banner ---

  defp key_warning_banner(assigns) do
    provider_atom = current_provider(assigns.model)

    warning =
      Enum.find_value(assigns.all_providers, fn {p, _name, status, _models} ->
        if p == provider_atom do
          case status do
            {:missing, env_var} -> {:api_key, env_var}
            {:oauth, :disconnected} -> {:oauth, p}
            _ -> nil
          end
        end
      end)

    assigns = assign(assigns, :warning, warning)

    ~H"""
    <%= case @warning do %>
      <% {:api_key, env_var} -> %>
        <div
          class="px-3 py-2"
          style="border-top: 1px solid rgba(245, 158, 11, 0.2); background: rgba(245, 158, 11, 0.05);"
        >
          <div class="flex items-start gap-2">
            <span class="text-amber-400 text-xs mt-0.5">&#9888;</span>
            <div class="text-xs">
              <p class="font-medium" style="color: rgba(252, 211, 77, 0.9);">
                <span class="font-mono text-amber-400">{env_var}</span> not found
              </p>
              <p class="mt-1" style="color: var(--text-muted);">
                Add to <span class="font-mono" style="color: var(--text-secondary);">.env</span>
                or export in shell
              </p>
            </div>
          </div>
        </div>
      <% {:oauth, provider} -> %>
        <div class="border-t border-violet-500/20 bg-violet-500/5 px-3 py-2.5">
          <div class="flex items-start gap-2">
            <span class="text-violet-400 text-xs mt-0.5">&#128279;</span>
            <div class="text-xs">
              <p class="text-violet-300/90 font-medium">
                Connect your subscription
              </p>
              <p class="text-gray-500 mt-1">
                Use your existing subscription instead of an API key.
              </p>
              <button
                type="button"
                phx-click="start_oauth_flow"
                phx-value-provider={provider}
                phx-target={@myself}
                class="inline-block mt-1.5 text-violet-400 hover:text-violet-300 font-medium transition-colors duration-150 cursor-pointer"
              >
                Connect with OAuth &rarr;
              </button>
            </div>
          </div>
        </div>
      <% _ -> %>
    <% end %>
    """
  end

  # --- Events ---

  def handle_event("toggle_dropdown", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open, search: "", show_unconfigured: false)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply,
     assign(socket, open: false, search: "", custom_mode: false, show_unconfigured: false)}
  end

  def handle_event("search_models", %{"value" => value}, socket) do
    {:noreply,
     assign(socket,
       search: value,
       filtered_providers: filtered_active(socket.assigns.active_providers, value),
       filtered_unconfigured: filtered_active(socket.assigns.unconfigured_providers, value)
     )}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    event =
      if socket.assigns[:selector_mode] == :fast, do: :change_fast_model, else: :change_model

    send(self(), {event, model})
    {:noreply, assign(socket, open: false, search: "")}
  end

  def handle_event("toggle_unconfigured", _params, socket) do
    {:noreply, assign(socket, show_unconfigured: !socket.assigns.show_unconfigured)}
  end

  def handle_event("enter_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: true, custom_value: socket.assigns.model)}
  end

  def handle_event("apply_custom", %{"model" => model}, socket) when model != "" do
    event =
      if socket.assigns[:selector_mode] == :fast, do: :change_fast_model, else: :change_model

    send(self(), {event, model})
    {:noreply, assign(socket, custom_mode: false, custom_value: "", open: false)}
  end

  def handle_event("apply_custom", _params, socket), do: {:noreply, socket}

  def handle_event("custom_key", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  def handle_event("custom_key", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  def handle_event("start_oauth_flow", %{"provider" => provider}, socket) do
    provider_atom = String.to_existing_atom(provider)
    flow_type = Loomkin.Auth.ProviderRegistry.flow_type(provider_atom)

    case flow_type do
      :paste_back ->
        # For paste-back: start the flow via OAuthServer directly, then
        # push a JS event to open the auth URL in a new window and show the modal
        redirect_uri = "#{LoomkinWeb.Endpoint.url()}/auth/#{provider}/callback"

        case Loomkin.Auth.OAuthServer.start_flow(provider_atom, redirect_uri) do
          {:ok, authorize_url, :paste_back} ->
            socket =
              socket
              |> assign(
                paste_back_provider: provider_atom,
                paste_back_error: nil,
                paste_back_submitting: false,
                open: false
              )
              |> push_event("start_paste_back_flow", %{
                authorize_url: authorize_url,
                provider: provider
              })

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply,
             assign(socket,
               paste_back_provider: provider_atom,
               paste_back_error: "Failed to start OAuth flow. Please try again.",
               paste_back_submitting: false,
               open: false
             )}
        end

      :redirect ->
        # For redirect flow: navigate to the auth controller which will redirect
        {:noreply, redirect(socket, external: "/auth/#{provider}")}
    end
  end

  def handle_event("submit_paste_code", %{"code_with_state" => code_with_state}, socket) do
    provider = socket.assigns.paste_back_provider

    if provider == nil do
      {:noreply, assign(socket, paste_back_error: "No active OAuth flow.")}
    else
      socket = assign(socket, paste_back_submitting: true, paste_back_error: nil)

      case Loomkin.Auth.OAuthServer.handle_paste(provider, String.trim(code_with_state)) do
        :ok ->
          # Success — close the modal. PubSub will notify the LiveView to refresh.
          socket =
            socket
            |> assign(
              paste_back_provider: nil,
              paste_back_error: nil,
              paste_back_submitting: false
            )
            |> push_event("paste_submit_result", %{status: "ok", message: "Connected!"})

          {:noreply, socket}

        {:error, :no_active_flow} ->
          {:noreply,
           assign(socket,
             paste_back_error: "OAuth flow expired. Please start a new flow.",
             paste_back_submitting: false
           )}

        {:error, :state_mismatch} ->
          {:noreply,
           assign(socket,
             paste_back_error: "Invalid code. Please make sure you copied the full code.",
             paste_back_submitting: false
           )}

        {:error, _reason} ->
          {:noreply,
           assign(socket,
             paste_back_error: "Connection failed. Please try again.",
             paste_back_submitting: false
           )}
      end
    end
  end

  def handle_event("submit_paste_code", _params, socket) do
    {:noreply, assign(socket, paste_back_error: "Please paste the code first.")}
  end

  def handle_event("cancel_paste", _params, socket) do
    {:noreply,
     assign(socket,
       paste_back_provider: nil,
       paste_back_error: nil,
       paste_back_submitting: false
     )}
  end

  # --- Helpers ---

  defp provider_display_name(provider_atom) when is_atom(provider_atom) do
    case Loomkin.Auth.ProviderRegistry.get(provider_atom) do
      nil -> provider_atom |> Atom.to_string() |> String.capitalize()
      entry -> entry.display_name
    end
  end

  defp current_provider(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _] ->
        try do
          String.to_existing_atom(provider)
        rescue
          ArgumentError -> nil
        end

      _ ->
        nil
    end
  end

  defp current_provider(_), do: nil

  defp current_model_label(model, providers) do
    Enum.find_value(providers, model_id_fallback(model), fn {_atom, _name, _status, models} ->
      Enum.find_value(models, fn {label, value, _ctx} ->
        if value == model, do: label
      end)
    end)
  end

  defp model_id_fallback(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, id] -> id
      _ -> model
    end
  end

  defp model_id_fallback(model), do: model

  defp filtered_active(providers, search) when search in [nil, ""], do: providers

  defp filtered_active(providers, search) do
    term = String.downcase(search)

    providers
    |> Enum.map(fn {provider_atom, display_name, key_status, models} ->
      filtered =
        Enum.filter(models, fn {label, value, _ctx} ->
          String.contains?(String.downcase(label), term) ||
            String.contains?(String.downcase(value), term)
        end)

      {provider_atom, display_name, key_status, filtered}
    end)
    |> Enum.reject(fn {_p, _n, _s, models} -> models == [] end)
  end
end
