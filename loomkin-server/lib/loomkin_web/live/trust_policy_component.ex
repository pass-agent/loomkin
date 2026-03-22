defmodule LoomkinWeb.TrustPolicyComponent do
  @moduledoc """
  Functional component for selecting trust policy presets.

  Renders a collapsible trust selector: a compact summary bar by default
  (one line with preset name, icon, pending count, chevron toggle) that
  expands to show the full preset buttons. Uses JS.toggle for no
  server roundtrip.
  """

  use Phoenix.Component

  attr :current_preset, :atom, required: true
  attr :pending_count, :integer, default: 0
  attr :expanded, :boolean, default: false
  attr :class, :string, default: ""

  def trust_policy_selector(assigns) do
    ~H"""
    <div class={["relative", @class]}>
      <%!-- Collapsed summary bar --%>
      <button
        :if={!@expanded}
        id="trust-summary"
        phx-click="toggle_trust_panel"
        class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs press-down cursor-pointer text-secondary border border-subtle transition-all duration-150"
      >
        <span class="text-[10px] uppercase tracking-wider mr-0.5 text-muted">Trust</span>
        <div
          class="w-1.5 h-1.5 rounded-full flex-shrink-0"
          style={"background: #{preset_color(@current_preset)};"}
        />
        <span class="font-medium text-primary">
          {preset_label(@current_preset)}
        </span>
        <span
          :if={@pending_count > 0}
          class="text-[9px] px-1.5 py-0.5 rounded-full font-semibold bg-amber-500/20 text-amber-400"
        >
          {@pending_count}
        </span>
        <svg
          class="w-3 h-3 text-muted"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <%!-- Expanded details --%>
      <div
        :if={@expanded}
        id="trust-details"
        class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs border border-brand transition-all duration-150"
      >
        <span class="text-[10px] uppercase tracking-wider mr-0.5 text-muted flex-shrink-0">
          Trust
        </span>
        <div class="flex gap-1">
          <button
            :for={preset <- [:strict, :balanced, :autonomous, :full_trust]}
            phx-click="set_trust_preset"
            phx-value-preset={preset}
            class={[
              "px-2 py-0.5 text-[10px] rounded-md transition-all",
              if(@current_preset == preset,
                do: "bg-violet-500/20 text-violet-400 border border-violet-500/30",
                else: "text-muted hover:text-secondary hover:bg-surface-3"
              )
            ]}
          >
            {preset_label(preset)}
          </button>
        </div>
        <button
          class="p-0.5 rounded interactive flex-shrink-0 text-muted"
          phx-click="toggle_trust_panel"
          title="Collapse"
        >
          <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M5 15l7-7 7 7" />
          </svg>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Returns a human-readable label for a preset name.
  """
  @spec preset_label(atom()) :: String.t()
  def preset_label(:strict), do: "Strict"
  def preset_label(:balanced), do: "Balanced"
  def preset_label(:autonomous), do: "Autonomous"
  def preset_label(:full_trust), do: "Full Trust"
  def preset_label(_), do: "Balanced"

  @doc """
  Returns a color hex string indicating the trust level.
  Green (strict/safe) through red (full trust/risky).
  """
  @spec preset_color(atom()) :: String.t()
  def preset_color(:strict), do: "#34d399"
  def preset_color(:balanced), do: "#fbbf24"
  def preset_color(:autonomous), do: "#f97316"
  def preset_color(:full_trust), do: "#ef4444"
  def preset_color(_), do: "#6b7280"
end
