defmodule LoomkinWeb.ModelSelectorComponent do
  use LoomkinWeb, :live_component

  def update(assigns, socket) do
    all_providers = Loomkin.Models.all_providers_enriched()

    # Split into configured (has key + models) and unconfigured
    {active, unconfigured} =
      Enum.split_with(all_providers, fn {_p, _name, status, models} ->
        match?({:set, _}, status) and models != []
      end)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       active_providers: active,
       unconfigured_providers: unconfigured,
       all_providers: all_providers,
       custom_mode: false,
       custom_value: "",
       open: false,
       search: "",
       show_unconfigured: false
     )}
  end

  def render(assigns) do
    ~H"""
    <div id="model-selector" phx-hook="ModelSelector" class="relative">
      <%!-- Trigger Button --%>
      <button
        type="button"
        phx-click="toggle_dropdown"
        phx-target={@myself}
        class="flex items-center gap-2 px-3 py-1.5 bg-gray-800/80 border border-gray-700/50 rounded-lg text-sm text-gray-300 hover:bg-gray-800 hover:border-violet-500/30 hover:shadow-lg hover:shadow-violet-500/5 transition-all duration-200 cursor-pointer group"
      >
        <span class="truncate max-w-[180px] text-gray-200 group-hover:text-gray-100">
          {current_model_label(@model, @all_providers)}
        </span>
        <svg
          class={"w-3.5 h-3.5 text-gray-500 transition-transform duration-200 #{if @open, do: "rotate-180"}"}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <%!-- Dropdown Panel --%>
      <div
        :if={@open}
        class="absolute top-full left-0 mt-2 w-80 bg-gray-900/95 backdrop-blur-sm border border-gray-700/50 rounded-xl shadow-2xl shadow-black/50 z-50 overflow-hidden"
        phx-click-away="close_dropdown"
        phx-target={@myself}
      >
        <%!-- Search Input --%>
        <div class="p-2 border-b border-gray-800/80">
          <div class="relative">
            <svg
              class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-500"
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
              class="w-full bg-gray-800/60 border border-gray-700/50 text-gray-300 text-xs rounded-lg pl-8 pr-3 py-2 focus:outline-none focus:ring-1 focus:ring-violet-500/50 focus:border-violet-500/30 placeholder-gray-600"
            />
          </div>
        </div>

        <%!-- Active Providers (with keys + models) --%>
        <div class="max-h-72 overflow-y-auto overscroll-contain" id="model-list">
          <%= if filtered_active(@active_providers, @search) == [] and @search != "" do %>
            <%!-- Search across all providers when filtering --%>
            <%= for {provider_atom, display_name, key_status, models} <- filtered_active(@unconfigured_providers, @search) do %>
              <.provider_group
                provider_atom={provider_atom}
                display_name={display_name}
                key_status={key_status}
                models={models}
                current_model={@model}
                myself={@myself}
              />
            <% end %>
            <div :if={filtered_active(@unconfigured_providers, @search) == []} class="px-4 py-6 text-center">
              <p class="text-xs text-gray-500">No models match "<span class="text-gray-400">{@search}</span>"</p>
            </div>
          <% else %>
            <%= for {provider_atom, display_name, key_status, models} <- filtered_active(@active_providers, @search) do %>
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

          <%!-- Empty state when no providers configured --%>
          <div :if={@active_providers == [] and @search == ""} class="px-4 py-6 text-center">
            <div class="text-2xl mb-2">🔑</div>
            <p class="text-xs text-gray-400 font-medium">No API keys configured</p>
            <p class="text-[11px] text-gray-600 mt-1">
              Add provider keys to your <span class="font-mono text-gray-500">.env</span> file to get started
            </p>
          </div>
        </div>

        <%!-- API Key Warning Banner --%>
        <.key_warning_banner model={@model} all_providers={@all_providers} />

        <%!-- Unconfigured Providers (collapsible) --%>
        <div :if={@unconfigured_providers != [] and @search == ""} class="border-t border-gray-800/80">
          <button
            type="button"
            phx-click="toggle_unconfigured"
            phx-target={@myself}
            class="flex items-center justify-between w-full px-3 py-2 text-xs text-gray-500 hover:text-gray-400 transition-colors duration-150"
          >
            <span class="flex items-center gap-1.5">
              <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              {length(@unconfigured_providers)} more providers available
            </span>
            <svg
              class={"w-3 h-3 transition-transform duration-200 #{if @show_unconfigured, do: "rotate-180"}"}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
            </svg>
          </button>

          <div :if={@show_unconfigured} class="max-h-48 overflow-y-auto border-t border-gray-800/50 bg-gray-950/50">
            <%= for {_provider_atom, display_name, {:missing, env_var}, _models} <- @unconfigured_providers do %>
              <div class="flex items-center justify-between px-3 py-1.5 group/setup">
                <span class="text-[11px] text-gray-600">{display_name}</span>
                <span class="text-[10px] text-gray-700 font-mono group-hover/setup:text-amber-500/70 transition-colors duration-150">
                  {env_var}
                </span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Custom Model Section --%>
        <div class="border-t border-gray-800/80 p-2">
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
                class="flex-1 bg-gray-800/60 border border-gray-700/50 text-gray-300 text-xs rounded-lg px-2.5 py-1.5 focus:outline-none focus:ring-1 focus:ring-violet-500/50 font-mono placeholder-gray-600"
              />
              <button
                type="submit"
                class="text-xs text-violet-400 hover:text-violet-300 px-2 py-1.5 rounded-md hover:bg-violet-500/10 transition-colors duration-150"
              >
                Use
              </button>
              <button
                type="button"
                phx-click="cancel_custom"
                phx-target={@myself}
                class="text-xs text-gray-500 hover:text-gray-300 px-1.5 py-1.5 rounded-md hover:bg-gray-800 transition-colors duration-150"
              >
                &times;
              </button>
            </form>
          <% else %>
            <button
              type="button"
              phx-click="enter_custom"
              phx-target={@myself}
              class="flex items-center gap-1.5 w-full px-2.5 py-1.5 text-xs text-gray-500 hover:text-gray-300 rounded-lg hover:bg-gray-800/60 transition-all duration-150"
            >
              <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              Use custom model...
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # --- Provider Group Component ---

  defp provider_group(assigns) do
    ~H"""
    <div class="px-2 pt-3 pb-1">
      <%!-- Provider Header --%>
      <div class="flex items-center justify-between px-2 mb-1">
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">{@display_name}</span>
        </div>
        <div class="flex items-center gap-1.5">
          <%= case @key_status do %>
            <% {:set, _env_var} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
                <span class="text-[10px] text-emerald-400/70">Connected</span>
              </span>
            <% {:missing, env_var} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-amber-400/60"></span>
                <span class="text-[10px] text-amber-400/60 font-mono">{env_var}</span>
              </span>
          <% end %>
        </div>
      </div>

      <%!-- Models --%>
      <%= for {label, value, context_k} <- @models do %>
        <button
          type="button"
          phx-click="select_model"
          phx-value-model={value}
          phx-target={@myself}
          class={"flex items-center justify-between w-full px-2 py-1.5 rounded-lg text-left transition-all duration-150 group/item #{if value == @current_model, do: "bg-violet-500/15 ring-1 ring-violet-500/25", else: "hover:bg-gray-800/80"}"}
        >
          <div class="flex items-center gap-2 min-w-0">
            <%= if value == @current_model do %>
              <svg
                class="w-3 h-3 text-violet-400 shrink-0"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="3"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M5 13l4 4L19 7"
                />
              </svg>
            <% else %>
              <div class="w-3 h-3 shrink-0"></div>
            <% end %>
            <span class={"text-xs truncate #{if value == @current_model, do: "text-violet-300 font-medium", else: "text-gray-300 group-hover/item:text-gray-100"}"}>
              {label}
            </span>
          </div>
          <span
            :if={context_k}
            class="text-[10px] text-gray-600 font-mono shrink-0 ml-2"
          >
            {context_k}
          </span>
        </button>
      <% end %>
    </div>
    """
  end

  # --- Key Warning Banner Component ---

  defp key_warning_banner(assigns) do
    provider_atom = current_provider(assigns.model)

    warning =
      Enum.find_value(assigns.all_providers, fn {p, _name, status, _models} ->
        if p == provider_atom do
          case status do
            {:missing, env_var} -> env_var
            _ -> nil
          end
        end
      end)

    assigns = assign(assigns, :warning_env_var, warning)

    ~H"""
    <div
      :if={@warning_env_var}
      class="border-t border-amber-500/20 bg-amber-500/5 px-3 py-2.5"
    >
      <div class="flex items-start gap-2">
        <span class="text-amber-400 text-xs mt-0.5">&#9888;</span>
        <div class="text-xs">
          <p class="text-amber-300/90 font-medium">
            <span class="font-mono text-amber-400">{@warning_env_var}</span> not found
          </p>
          <p class="text-gray-500 mt-1">
            Add to your <span class="font-mono text-gray-400">.env</span> file or export in your shell:
          </p>
          <p class="font-mono text-gray-400 mt-1 text-[11px] select-all">
            export {@warning_env_var}=sk-...
          </p>
        </div>
      </div>
    </div>
    """
  end

  # --- Events ---

  def handle_event("toggle_dropdown", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open, search: "", show_unconfigured: false)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply, assign(socket, open: false, search: "", custom_mode: false, show_unconfigured: false)}
  end

  def handle_event("search_models", %{"value" => value}, socket) do
    {:noreply, assign(socket, search: value)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    send(self(), {:change_model, model})
    {:noreply, assign(socket, open: false, search: "")}
  end

  def handle_event("toggle_unconfigured", _params, socket) do
    {:noreply, assign(socket, show_unconfigured: !socket.assigns.show_unconfigured)}
  end

  def handle_event("enter_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: true, custom_value: socket.assigns.model)}
  end

  def handle_event("apply_custom", %{"model" => model}, socket) when model != "" do
    send(self(), {:change_model, model})
    {:noreply, assign(socket, custom_mode: false, custom_value: "", open: false)}
  end

  def handle_event("apply_custom", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("custom_key", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  def handle_event("custom_key", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  # --- Helpers ---

  defp current_provider(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _] -> String.to_atom(provider)
      _ -> nil
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

  defp filtered_active(providers, search) when search in [nil, ""] do
    providers
  end

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
