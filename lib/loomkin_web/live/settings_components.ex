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
  attr :has_errors, :boolean, default: false
  slot :inner_block, required: true

  def settings_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-6xl mx-auto px-6 py-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-violet-400">Settings</h1>
            <p class="text-sm text-gray-500 mt-1">
              Configure agent behavior, budgets, and safety controls
            </p>
          </div>
          <a href="/" class="text-sm text-violet-400 hover:text-violet-300">
            Back to Workspace
          </a>
        </div>

        <div class="flex gap-6">
          <%!-- Sidebar tabs --%>
          <nav class="w-48 flex-shrink-0">
            <div class="sticky top-6 space-y-1">
              <button
                :for={tab <- @tabs}
                phx-click="switch_tab"
                phx-value-tab={tab}
                class={[
                  "w-full text-left px-3 py-2 rounded-md text-sm transition-colors",
                  if(@active_tab == tab,
                    do: "bg-violet-500/20 text-violet-300 font-medium",
                    else: "text-gray-400 hover:text-gray-200 hover:bg-gray-800/50"
                  )
                ]}
              >
                {tab}
              </button>
            </div>
          </nav>

          <%!-- Main content --%>
          <div class="flex-1 min-w-0">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>

      <%!-- Sticky save bar --%>
      <div
        :if={@dirty_count > 0}
        class="fixed bottom-0 left-0 right-0 bg-gray-900/95 border-t border-gray-800 backdrop-blur-sm"
      >
        <div class="max-w-6xl mx-auto px-6 py-3 flex items-center justify-between">
          <span class="text-sm text-gray-400">
            {if @dirty_count == 1,
              do: "1 setting changed",
              else: "#{@dirty_count} settings changed"}
          </span>
          <div class="flex items-center gap-3">
            <button
              phx-click="discard_changes"
              class="px-3 py-1.5 text-sm text-gray-400 hover:text-gray-200 transition-colors"
            >
              Discard
            </button>
            <button
              phx-click="save_settings"
              disabled={@has_errors}
              class={[
                "px-4 py-1.5 text-sm font-medium rounded-md transition-colors",
                if(@has_errors,
                  do: "bg-gray-700 text-gray-500 cursor-not-allowed",
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
  attr :dirty, :map, required: true
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
  attr :dirty, :map, required: true
  attr :errors, :map, required: true

  def settings_section(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg">
      <div class="px-5 py-3 border-b border-gray-800 flex items-center justify-between">
        <h3 class="text-sm font-semibold text-gray-200">{@section}</h3>
        <button
          :if={section_has_dirty?(@settings, @dirty)}
          phx-click="reset_section"
          phx-value-section={@section}
          class="text-xs text-gray-500 hover:text-gray-300 transition-colors"
        >
          Reset to defaults
        </button>
      </div>
      <div class="divide-y divide-gray-800/50">
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
    <div class="px-5 py-4 flex items-start gap-6">
      <%!-- Label & description --%>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class={[
            "text-sm font-medium",
            if(@dirty, do: "text-violet-300", else: "text-gray-200")
          ]}>
            {@setting.label}
          </span>
          <span
            :if={@setting.applies_to_new}
            class="px-1.5 py-0.5 text-[10px] font-medium rounded bg-amber-500/10 text-amber-400 border border-amber-500/20"
          >
            applies to new teams
          </span>
          <%!-- Why change tooltip --%>
          <div class="relative group">
            <button class="text-gray-600 hover:text-gray-400 transition-colors" type="button">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </button>
            <div class="absolute left-0 bottom-full mb-2 w-64 p-2 text-xs text-gray-300 bg-gray-800 border border-gray-700 rounded-md shadow-lg opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all z-10">
              {@setting.why_change}
            </div>
          </div>
        </div>
        <p class="text-xs text-gray-500 mt-0.5 leading-relaxed">{@setting.description}</p>
        <p :if={@error} class="text-xs text-red-400 mt-1">{@error}</p>
      </div>

      <%!-- Input + reset --%>
      <div class="flex items-center gap-2 flex-shrink-0">
        <.setting_input setting={@setting} value={@value} key_string={@key_string} error={@error} />
        <button
          :if={@dirty}
          phx-click="reset_setting"
          phx-value-key={@key_string}
          class="text-gray-600 hover:text-gray-400 transition-colors"
          title="Reset to default"
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
      phx-click="update_setting"
      phx-value-key={@key_string}
      phx-value-value={to_string(!@value)}
      class={[
        "relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none",
        if(@value, do: "bg-violet-500", else: "bg-gray-700")
      ]}
      role="switch"
      aria-checked={to_string(@value)}
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
      phx-change="update_setting"
      name={@key_string}
      class={[
        "bg-gray-800 border rounded-md px-3 py-1.5 text-sm text-gray-200 focus:outline-none focus:ring-1 focus:ring-violet-500 w-44",
        if(@error, do: "border-red-500", else: "border-gray-700")
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
      <span class="text-sm text-gray-500">$</span>
      <input
        type="number"
        name={@key_string}
        value={@value}
        step={@setting.step || 0.01}
        min={elem_or_nil(@setting.range, 0)}
        max={elem_or_nil(@setting.range, 1)}
        phx-change="update_setting"
        phx-debounce="300"
        class={[
          "bg-gray-800 border rounded-md px-3 py-1.5 text-sm text-gray-200 w-28 focus:outline-none focus:ring-1 focus:ring-violet-500",
          if(@error, do: "border-red-500", else: "border-gray-700")
        ]}
      />
    </div>
    """
  end

  def setting_input(%{setting: %{type: :duration}} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <input
        type="number"
        name={@key_string}
        value={@value}
        step={@setting.step || 1000}
        min={elem_or_nil(@setting.range, 0)}
        max={elem_or_nil(@setting.range, 1)}
        phx-change="update_setting"
        phx-debounce="300"
        class={[
          "bg-gray-800 border rounded-md px-3 py-1.5 text-sm text-gray-200 w-28 focus:outline-none focus:ring-1 focus:ring-violet-500",
          if(@error, do: "border-red-500", else: "border-gray-700")
        ]}
      />
      <span
        :if={@setting.unit}
        class="text-xs text-gray-500 bg-gray-800 border border-gray-700 rounded px-1.5 py-1"
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
        type="number"
        name={@key_string}
        value={@value}
        step={@setting.step || 1}
        min={elem_or_nil(@setting.range, 0)}
        max={elem_or_nil(@setting.range, 1)}
        phx-change="update_setting"
        phx-debounce="300"
        class={[
          "bg-gray-800 border rounded-md px-3 py-1.5 text-sm text-gray-200 w-28 focus:outline-none focus:ring-1 focus:ring-violet-500",
          if(@error, do: "border-red-500", else: "border-gray-700")
        ]}
      />
      <span
        :if={@setting.unit}
        class="text-xs text-gray-500 bg-gray-800 border border-gray-700 rounded px-1.5 py-1"
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
          class="inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-gray-800 border border-gray-700 text-gray-300"
        >
          {tag}
          <button
            phx-click="remove_tag"
            phx-value-key={@key_string}
            phx-value-tag={tag}
            class="text-gray-500 hover:text-red-400 transition-colors"
            type="button"
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
      <form phx-submit="add_tag" class="flex gap-1">
        <input type="hidden" name="key" value={@key_string} />
        <input
          type="text"
          name="tag"
          placeholder="Add..."
          class="bg-gray-800 border border-gray-700 rounded-md px-2 py-1 text-xs text-gray-200 w-32 focus:outline-none focus:ring-1 focus:ring-violet-500"
        />
        <button
          type="submit"
          class="px-2 py-1 text-xs text-gray-400 hover:text-violet-300 bg-gray-800 border border-gray-700 rounded-md transition-colors"
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
