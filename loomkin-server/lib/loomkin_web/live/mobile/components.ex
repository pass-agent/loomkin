defmodule LoomkinWeb.Mobile.Components do
  @moduledoc "Shared functional components for mobile views."

  use Phoenix.Component

  attr :role, :atom, required: true
  attr :content, :string, required: true
  attr :agent_name, :string, default: nil
  attr :timestamp, :any, default: nil

  def message_bubble(assigns) do
    ~H"""
    <div class={[
      "flex",
      if(@role == :user, do: "justify-end", else: "justify-start")
    ]}>
      <div class={[
        "max-w-[85%] rounded-2xl px-4 py-2.5",
        if(@role == :user,
          do: "bg-violet-600 text-white rounded-br-md",
          else: "bg-gray-800 text-gray-100 rounded-bl-md"
        )
      ]}>
        <p
          :if={@agent_name && @role == :assistant}
          class="text-[10px] text-violet-300 font-medium mb-0.5"
        >
          {@agent_name}
        </p>
        <div class="text-sm whitespace-pre-wrap break-words">{@content}</div>
        <p
          :if={@timestamp}
          class={[
            "text-[10px] mt-1",
            if(@role == :user, do: "text-violet-200/60", else: "text-gray-500")
          ]}
        >
          {format_time(@timestamp)}
        </p>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :tool_name, :string, default: nil

  def status_indicator(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-2 px-3 py-1.5 text-xs",
      status_color(@status)
    ]}>
      <span :if={@status in [:thinking, :streaming, :tool_running]} class="relative flex h-2 w-2">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-current opacity-75" />
        <span class="relative inline-flex rounded-full h-2 w-2 bg-current" />
      </span>
      <span :if={@status == :idle} class="h-2 w-2 rounded-full bg-current" />
      <span>{status_text(@status, @tool_name)}</span>
    </div>
    """
  end

  defp status_color(:idle), do: "text-gray-500"
  defp status_color(:thinking), do: "text-amber-400"
  defp status_color(:streaming), do: "text-violet-400"
  defp status_color(:tool_running), do: "text-cyan-400"
  defp status_color(_), do: "text-gray-500"

  defp status_text(:idle, _), do: "Idle"
  defp status_text(:thinking, _), do: "Thinking..."
  defp status_text(:streaming, _), do: "Responding..."
  defp status_text(:tool_running, nil), do: "Running tool..."
  defp status_text(:tool_running, name), do: "Running: #{name}"
  defp status_text(_, _), do: ""

  attr :permissions, :list, required: true
  attr :session_id, :string, required: true

  def approval_banner(assigns) do
    ~H"""
    <div
      :for={perm <- @permissions}
      id={"approval-#{perm.id}"}
      class="bg-amber-950/80 border-t border-amber-500/30 px-4 py-3"
    >
      <div class="flex items-center gap-2 mb-2">
        <span class="text-amber-400 text-xs font-semibold">Permission Required</span>
        <span :if={perm[:agent_name]} class="text-amber-500/60 text-xs">
          ({perm.agent_name})
        </span>
      </div>
      <p class="text-white text-sm font-mono truncate mb-0.5">{perm.tool_name}</p>
      <p :if={perm[:tool_path]} class="text-gray-400 text-xs font-mono truncate mb-3">
        {perm.tool_path}
      </p>
      <div class="flex gap-3">
        <button
          id={"approve-#{perm.id}"}
          phx-click="approve_tool"
          phx-value-id={perm.id}
          class="flex-1 py-3 bg-emerald-600 hover:bg-emerald-500 active:bg-emerald-700 text-white text-sm font-medium rounded-xl transition-colors"
        >
          Approve
        </button>
        <button
          id={"deny-#{perm.id}"}
          phx-click="deny_tool"
          phx-value-id={perm.id}
          class="flex-1 py-3 bg-gray-700 hover:bg-gray-600 active:bg-gray-800 text-white text-sm font-medium rounded-xl transition-colors"
        >
          Deny
        </button>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: ""

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M")
  end
end
