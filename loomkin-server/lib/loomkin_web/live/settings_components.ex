defmodule LoomkinWeb.SettingsComponents do
  @moduledoc """
  Functional components for the Settings page.

  All rendering is data-driven from the `Settings.Registry` — no
  hardcoded form fields in these templates.
  """

  use Phoenix.Component

  alias Loomkin.Settings.Registry

  attr :active_tab, :string, required: true
  attr :tabs, :list, required: true
  attr :dirty_count, :integer, default: 0
  attr :dirty_tabs, :any, default: MapSet.new()
  attr :has_errors, :boolean, default: false
  slot :inner_block, required: true

  def settings_layout(assigns) do
    ~H"""
    <div
      class={["min-h-screen bg-surface-0 text-primary", @dirty_count > 0 && "pb-16"]}
      phx-window-keydown="keydown"
    >
      <div class="max-w-6xl mx-auto px-6 py-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-brand">Settings</h1>
            <p class="text-sm text-muted mt-1">
              Configure agent behavior, budgets, and safety controls
            </p>
          </div>
          <.link navigate="/" class="text-sm text-brand hover:text-violet-300">
            Back to Workspace
          </.link>
        </div>

        <div class="flex gap-6">
          <%!-- Sidebar tabs --%>
          <nav class="w-48 flex-shrink-0" role="tablist" aria-label="Settings categories">
            <div class="sticky top-6 space-y-1">
              <button
                :for={tab <- @tabs}
                phx-click="switch_tab"
                phx-value-tab={tab}
                role="tab"
                aria-selected={to_string(@active_tab == tab)}
                aria-controls="settings-tabpanel"
                tabindex={if(@active_tab == tab, do: "0", else: "-1")}
                class={[
                  "w-full text-left px-3 py-2 rounded-md text-sm transition-colors flex items-center gap-2",
                  if(@active_tab == tab,
                    do: "bg-violet-500/20 text-violet-300 font-medium",
                    else: "text-secondary hover:text-primary hover:bg-surface-2/50"
                  )
                ]}
              >
                {tab}
                <span
                  :if={MapSet.member?(@dirty_tabs, tab)}
                  class="w-1.5 h-1.5 rounded-full bg-violet-400 flex-shrink-0"
                  aria-label="has unsaved changes"
                />
              </button>
            </div>
          </nav>

          <%!-- Main content --%>
          <div
            class="flex-1 min-w-0 animate-fade-in"
            role="tabpanel"
            id="settings-tabpanel"
            aria-labelledby={"tab-#{@active_tab}"}
          >
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>

      <%!-- Sticky save bar --%>
      <div
        :if={@dirty_count > 0}
        class="fixed bottom-0 left-0 right-0 glass settings-bar-enter z-10"
      >
        <div class="max-w-6xl mx-auto px-6 py-3 flex items-center justify-between">
          <span class="text-sm text-secondary">
            {if @dirty_count == 1,
              do: "1 setting changed",
              else: "#{@dirty_count} settings changed"}
          </span>
          <div class="flex items-center gap-3">
            <button
              phx-click="discard_changes"
              class="px-3 py-1.5 text-sm text-secondary hover:text-primary transition-colors"
            >
              Discard
            </button>
            <button
              phx-click="save_settings"
              disabled={@has_errors}
              class={[
                "px-4 py-1.5 text-sm font-medium rounded-md transition-colors press-down",
                if(@has_errors,
                  do: "bg-surface-3 text-muted cursor-not-allowed",
                  else: "bg-violet-600 text-white hover:bg-violet-500"
                )
              ]}
            >
              Save changes
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :tab, :string, required: true
  attr :sections, :map, required: true
  attr :values, :map, required: true
  attr :dirty, :any, required: true
  attr :errors, :map, required: true

  def settings_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <.settings_section
        :for={{section_name, settings} <- sorted_sections(@sections)}
        section={section_name}
        settings={settings}
        values={@values}
        dirty={@dirty}
        errors={@errors}
      />
    </div>
    """
  end

  attr :section, :string, required: true
  attr :settings, :list, required: true
  attr :values, :map, required: true
  attr :dirty, :any, required: true
  attr :errors, :map, required: true

  def settings_section(assigns) do
    ~H"""
    <div class="card">
      <div class="px-5 py-3 border-b border-subtle flex items-center justify-between">
        <h3 class="text-sm font-semibold text-primary">{@section}</h3>
        <button
          :if={section_has_dirty?(@settings, @dirty)}
          phx-click="reset_section"
          phx-value-section={@section}
          aria-label={"Reset all #{@section} settings to defaults"}
          class="text-xs text-muted hover:text-secondary transition-colors"
        >
          Reset to defaults
        </button>
      </div>
      <div class="divide-y divide-[var(--border-subtle)]">
        <.setting_row
          :for={setting <- @settings}
          setting={setting}
          value={Map.get(@values, Registry.key_string(setting.key))}
          dirty={MapSet.member?(@dirty, Registry.key_string(setting.key))}
          error={Map.get(@errors, Registry.key_string(setting.key))}
        />
      </div>
    </div>
    """
  end

  attr :setting, Loomkin.Settings.Setting, required: true
  attr :value, :any, required: true
  attr :dirty, :boolean, default: false
  attr :error, :string, default: nil

  def setting_row(assigns) do
    assigns = assign(assigns, :key_string, Registry.key_string(assigns.setting.key))

    ~H"""
    <div class="px-5 py-4 flex items-start gap-6 hover:bg-surface-1/50 transition-colors">
      <%!-- Label & description --%>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <label
            for={"input-#{@key_string}"}
            class={[
              "text-sm font-medium cursor-pointer",
              if(@dirty, do: "text-violet-300", else: "text-primary")
            ]}
          >
            {@setting.label}
          </label>
          <span
            :if={@setting.applies_to_new}
            class="badge-warning"
          >
            applies to new teams
          </span>
          <%!-- Why change tooltip --%>
          <div class="relative group">
            <button
              class="text-muted hover:text-secondary transition-colors"
              type="button"
              aria-label="More info"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </button>
            <div class="absolute left-0 bottom-full mb-2 w-64 p-2 text-xs text-secondary bg-surface-3 border border-default rounded-md shadow-lg opacity-0 invisible group-hover:opacity-100 group-hover:visible group-focus-within:opacity-100 group-focus-within:visible transition-all z-10">
              {@setting.why_change}
            </div>
          </div>
        </div>
        <p class="text-xs text-muted mt-0.5 leading-relaxed">{@setting.description}</p>
        <p
          :if={@error}
          id={"error-#{@key_string}"}
          class="text-xs text-red-400 mt-1"
          role="alert"
        >
          {@error}
        </p>
      </div>

      <%!-- Input + reset --%>
      <div class="flex items-center gap-2 flex-shrink-0">
        <.setting_input setting={@setting} value={@value} key_string={@key_string} error={@error} />
        <button
          :if={@dirty}
          phx-click="reset_setting"
          phx-value-key={@key_string}
          class="text-muted hover:text-secondary transition-colors"
          title="Reset to default"
          aria-label={"Reset #{@setting.label} to default"}
        >
          <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
            />
          </svg>
        </button>
      </div>
    </div>
    """
  end

  attr :setting, Loomkin.Settings.Setting, required: true
  attr :value, :any, required: true
  attr :key_string, :string, required: true
  attr :error, :string, default: nil

  def setting_input(%{setting: %{type: :toggle}} = assigns) do
    ~H"""
    <button
      id={"input-#{@key_string}"}
      phx-click="update_setting"
      phx-value-key={@key_string}
      phx-value-value={to_string(!@value)}
      class={[
        "relative inline-flex h-6 w-11 items-center rounded-full transition-colors cursor-pointer",
        "focus:outline-none focus:ring-2 focus:ring-violet-500/50 focus:ring-offset-2 focus:ring-offset-[var(--surface-0)]",
        if(@value, do: "bg-violet-500", else: "bg-surface-3")
      ]}
      role="switch"
      aria-checked={to_string(@value)}
      aria-label={@setting.label}
    >
      <span class={[
        "inline-block h-4 w-4 transform rounded-full bg-white transition-transform",
        if(@value, do: "translate-x-6", else: "translate-x-1")
      ]}>
      </span>
    </button>
    """
  end

  def setting_input(%{setting: %{type: :select}} = assigns) do
    ~H"""
    <select
      id={"input-#{@key_string}"}
      phx-change="update_setting"
      name={@key_string}
      aria-invalid={to_string(@error != nil)}
      aria-describedby={@error && "error-#{@key_string}"}
      class={[
        "bg-surface-2 border rounded-md px-3 py-1.5 text-sm text-primary focus:outline-none focus:ring-1 focus:ring-violet-500 w-44",
        if(@error, do: "border-red-500", else: "border-default")
      ]}
    >
      <option
        :for={opt <- @setting.options}
        value={opt}
        selected={to_string(@value) == opt}
      >
        {opt}
      </option>
    </select>
    """
  end

  def setting_input(%{setting: %{type: :currency}} = assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <span class="text-sm text-muted">$</span>
      <input
        id={"input-#{@key_string}"}
        type="number"
        name={@key_string}
        value={@value}
        step={@setting.step || 0.01}
        min={elem_or_nil(@setting.range, 0)}
        max={elem_or_nil(@setting.range, 1)}
        phx-change="update_setting"
        phx-debounce="300"
        aria-invalid={to_string(@error != nil)}
        aria-describedby={@error && "error-#{@key_string}"}
        class={[
          "bg-surface-2 border rounded-md px-3 py-1.5 text-sm text-primary w-28 focus:outline-none focus:ring-1 focus:ring-violet-500",
          if(@error, do: "border-red-500", else: "border-default")
        ]}
      />
    </div>
    """
  end

  def setting_input(%{setting: %{type: :duration}} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <input
        id={"input-#{@key_string}"}
        type="number"
        name={@key_string}
        value={@value}
        step={@setting.step || 1000}
        min={elem_or_nil(@setting.range, 0)}
        max={elem_or_nil(@setting.range, 1)}
        phx-change="update_setting"
        phx-debounce="300"
        aria-invalid={to_string(@error != nil)}
        aria-describedby={@error && "error-#{@key_string}"}
        class={[
          "bg-surface-2 border rounded-md px-3 py-1.5 text-sm text-primary w-28 focus:outline-none focus:ring-1 focus:ring-violet-500",
          if(@error, do: "border-red-500", else: "border-default")
        ]}
      />
      <span
        :if={@setting.unit}
        class="text-xs text-muted bg-surface-2 border border-default rounded px-1.5 py-1"
      >
        {@setting.unit}
      </span>
    </div>
    """
  end

  def setting_input(%{setting: %{type: :number}} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <input
        id={"input-#{@key_string}"}
        type="number"
        name={@key_string}
        value={@value}
        step={@setting.step || 1}
        min={elem_or_nil(@setting.range, 0)}
        max={elem_or_nil(@setting.range, 1)}
        phx-change="update_setting"
        phx-debounce="300"
        aria-invalid={to_string(@error != nil)}
        aria-describedby={@error && "error-#{@key_string}"}
        class={[
          "bg-surface-2 border rounded-md px-3 py-1.5 text-sm text-primary w-28 focus:outline-none focus:ring-1 focus:ring-violet-500",
          if(@error, do: "border-red-500", else: "border-default")
        ]}
      />
      <span
        :if={@setting.unit}
        class="text-xs text-muted bg-surface-2 border border-default rounded px-1.5 py-1"
      >
        {@setting.unit}
      </span>
    </div>
    """
  end

  def setting_input(%{setting: %{type: :tag_list}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex flex-wrap gap-1 max-w-xs">
        <span
          :for={tag <- @value || []}
          class="inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-surface-2 border border-default text-secondary"
        >
          {tag}
          <button
            phx-click="remove_tag"
            phx-value-key={@key_string}
            phx-value-tag={tag}
            class="text-muted hover:text-red-400 transition-colors"
            type="button"
            aria-label={"Remove #{tag}"}
          >
            <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </span>
      </div>
      <form id={"add-tag-#{@key_string}"} phx-submit="add_tag" class="flex gap-1">
        <input type="hidden" name="key" value={@key_string} />
        <input
          id={"input-#{@key_string}"}
          type="text"
          name="tag"
          placeholder="Add..."
          class="bg-surface-2 border border-default rounded-md px-2 py-1 text-xs text-primary w-32 focus:outline-none focus:ring-1 focus:ring-violet-500"
        />
        <button
          type="submit"
          class="px-2 py-1 text-xs text-secondary hover:text-violet-300 bg-surface-2 border border-default rounded-md transition-colors"
        >
          +
        </button>
      </form>
    </div>
    """
  end

  # --- Helpers ---

  defp sorted_sections(sections) do
    Enum.sort_by(sections, fn {name, _settings} -> name end)
  end

  defp section_has_dirty?(settings, dirty) do
    Enum.any?(settings, fn s -> MapSet.member?(dirty, Registry.key_string(s.key)) end)
  end

  defp elem_or_nil(nil, _index), do: nil
  defp elem_or_nil(tuple, index), do: elem(tuple, index)
end
