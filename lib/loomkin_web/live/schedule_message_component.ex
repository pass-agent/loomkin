defmodule LoomkinWeb.ScheduleMessageComponent do
  @moduledoc """
  Popover component for scheduling a message to be sent to an agent or team
  after a delay. Shows quick-pick delay buttons, custom time input,
  and a list of currently scheduled messages with countdown timers.
  """

  use Phoenix.Component

  import LoomkinWeb.CoreComponents, only: [icon: 1]

  @delay_options [
    {5, "5m"},
    {10, "10m"},
    {15, "15m"},
    {20, "20m"},
    {30, "30m"},
    {60, "1h"}
  ]

  attr :target_agent, :string, default: nil
  attr :content, :string, default: ""
  attr :delay_minutes, :integer, default: 5
  attr :scheduled_messages, :list, default: []

  def schedule_popover(assigns) do
    delivery_time = DateTime.add(DateTime.utc_now(), assigns.delay_minutes * 60, :second)

    assigns =
      assigns
      |> Phoenix.Component.assign(:delay_options, @delay_options)
      |> Phoenix.Component.assign(:delivery_time, delivery_time)

    ~H"""
    <div
      id={"schedule-popover-#{@target_agent || "team"}"}
      class="absolute bottom-full right-0 mb-2 w-80 z-50 animate-scale-in bg-surface-1 border border-subtle rounded-xl shadow-surface-lg"
      phx-click-away="close_scheduler"
    >
      <%!-- Header --%>
      <div class="flex items-center gap-2 px-4 py-3 border-b border-subtle">
        <.icon name="hero-clock-mini" class="w-4 h-4 text-amber-400" />
        <span class="text-sm font-medium text-primary">
          Schedule Message
        </span>
        <div class="flex-1"></div>
        <button
          phx-click="close_scheduler"
          class="p-1 rounded-md interactive text-muted"
        >
          <.icon name="hero-x-mark-mini" class="w-3.5 h-3.5" />
        </button>
      </div>

      <div class="p-4">
        <%!-- Target display --%>
        <div class="flex items-center gap-2 mb-3">
          <span class="text-[10px] font-medium uppercase tracking-wider text-muted">
            To
          </span>
          <span class="text-xs font-medium text-brand">
            {if @target_agent, do: @target_agent, else: "Team"}
          </span>
        </div>

        <%!-- Message preview / editor --%>
        <form phx-submit="schedule_message" id={"schedule-form-#{@target_agent || "team"}"}>
          <input
            :if={@target_agent}
            type="hidden"
            name="target_agent"
            value={@target_agent}
          />

          <textarea
            name="content"
            rows="2"
            placeholder="Message content..."
            class="w-full rounded-lg px-3 py-2 text-xs resize-none focus:outline-none mb-3 bg-surface-0 border border-subtle text-primary caret-brand"
          >{@content}</textarea>

          <%!-- Quick delay buttons --%>
          <div class="flex flex-wrap gap-1.5 mb-3">
            <button
              :for={{minutes, label} <- @delay_options}
              type="button"
              phx-click="set_schedule_delay"
              phx-value-minutes={minutes}
              class={[
                "px-2.5 py-1 text-[11px] font-medium rounded-full transition-all duration-200 cursor-pointer",
                if(@delay_minutes == minutes,
                  do: "bg-amber-500/20 text-amber-300 border border-amber-500/40",
                  else: "text-muted border border-transparent hover:bg-surface-3"
                )
              ]}
              style={unless(@delay_minutes == minutes, do: "border-color: var(--border-subtle);")}
            >
              {label}
            </button>
          </div>

          <%!-- Delivery time preview --%>
          <div class="flex items-center gap-2 mb-4">
            <.icon name="hero-arrow-right-mini" class="w-3 h-3 text-muted" />
            <span class="text-[11px] text-secondary">
              Will send at
            </span>
            <span
              id={"delivery-time-#{@target_agent || "team"}"}
              class="text-[11px] font-medium text-amber-400"
              phx-hook="LocalTime"
              data-utc-time={DateTime.to_iso8601(@delivery_time)}
              data-format="time"
            >
              {format_delivery_time(@delivery_time)}
            </span>
          </div>

          <input type="hidden" name="delay_minutes" value={@delay_minutes} />

          <%!-- Action buttons --%>
          <div class="flex gap-2 justify-end">
            <button
              type="button"
              phx-click="close_scheduler"
              class="text-xs px-3 py-1.5 rounded-lg interactive text-muted border border-subtle"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="text-xs px-3 py-1.5 rounded-lg font-medium text-white bg-brand"
            >
              Schedule
            </button>
          </div>
        </form>
      </div>

      <%!-- Scheduled messages list --%>
      <div
        :if={@scheduled_messages != []}
        class="border-t border-subtle"
      >
        <div class="px-4 py-2">
          <span class="text-[10px] font-medium uppercase tracking-wider text-muted">
            Scheduled ({length(@scheduled_messages)})
          </span>
        </div>
        <div class="max-h-40 overflow-auto">
          <div
            :for={msg <- @scheduled_messages}
            class="group/sched px-4 py-2.5 flex items-start gap-2 border-t border-subtle"
          >
            <.icon name="hero-clock-mini" class="w-3.5 h-3.5 text-amber-400/60 flex-shrink-0 mt-0.5" />
            <div class="flex-1 min-w-0">
              <p class="text-xs truncate text-secondary">
                {msg.content}
              </p>
              <div class="flex items-center gap-2 mt-0.5">
                <span class="text-[10px] text-muted">
                  {Map.get(msg, :target_agent) || "Team"}
                </span>
                <span
                  id={"countdown-#{msg.id}"}
                  class="text-[10px] text-amber-400"
                  phx-hook="LocalTime"
                  data-utc-time={DateTime.to_iso8601(msg.deliver_at)}
                  data-format="countdown"
                >
                  {scheduled_countdown(msg.deliver_at)}
                </span>
              </div>
            </div>
            <button
              phx-click="cancel_scheduled"
              phx-value-id={msg.id}
              class="flex-shrink-0 p-1 rounded-md opacity-0 group-hover/sched:opacity-100 transition-opacity interactive text-red-400/60 hover:text-red-400"
              title="Cancel"
            >
              <.icon name="hero-x-mark-mini" class="w-3 h-3" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp format_delivery_time(dt) do
    Calendar.strftime(dt, "%I:%M %p")
  end

  defp scheduled_countdown(nil), do: ""

  defp scheduled_countdown(deliver_at) do
    diff = DateTime.diff(deliver_at, DateTime.utc_now(), :second)

    cond do
      diff <= 0 -> "delivering..."
      diff < 60 -> "in #{diff}s"
      diff < 3600 -> "in #{div(diff, 60)}m"
      true -> "in #{div(diff, 3600)}h #{rem(div(diff, 60), 60)}m"
    end
  end
end
