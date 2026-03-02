defmodule LoomkinWeb.TeamActivityComponent do
  use LoomkinWeb, :live_component

  @max_events 200

  @agent_colors [
    "#818cf8",
    "#34d399",
    "#f472b6",
    "#fb923c",
    "#22d3ee",
    "#a78bfa",
    "#fbbf24",
    "#4ade80"
  ]

  @type_config %{
    tool_call: %{label: "tool", bg: "bg-violet-400/20", text: "text-violet-400"},
    message: %{label: "message", bg: "bg-gray-400/20", text: "text-gray-400"},
    decision: %{label: "decision", bg: "bg-purple-400/20", text: "text-purple-400"},
    task_complete: %{label: "done", bg: "bg-green-400/20", text: "text-green-400"},
    task_assigned: %{label: "assigned", bg: "bg-cyan-400/20", text: "text-cyan-400"},
    discovery: %{label: "discovery", bg: "bg-yellow-400/20", text: "text-yellow-400"},
    error: %{label: "error", bg: "bg-red-400/20", text: "text-red-400"},
    thinking: %{label: "thinking", bg: "bg-indigo-400/20", text: "text-indigo-400"}
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       events: [],
       agent_filter: nil,
       type_filter: MapSet.new(),
       known_agents: [],
       streaming_agents: %{},
       subscribed: false
     )}
  end

  @impl true
  def update(%{team_id: team_id} = assigns, socket) do
    if connected?(socket) && !socket.assigns[:subscribed] do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:tasks")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:decisions")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}:context")
    end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:subscribed, true)}
  end

  # --- PubSub Handlers ---

  def handle_info({:agent_status, agent_name, status}, socket) do
    type =
      case status do
        :error -> :error
        _ -> :message
      end

    content =
      case status do
        :idle -> "#{agent_name} is now idle"
        :working -> "#{agent_name} started working"
        :blocked -> "#{agent_name} is blocked"
        :error -> "#{agent_name} encountered an error"
      end

    event = build_event(type, agent_name, content)
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:context_update, from_agent, %{type: :discovery, content: content}}, socket) do
    event = build_event(:discovery, from_agent, content)
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:context_update, from_agent, payload}, socket) do
    content = Map.get(payload, :content, inspect(payload))
    event = build_event(:discovery, from_agent, content)
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:task_assigned, task_id, agent_name}, socket) do
    event = build_event(:task_assigned, agent_name, "picked up task #{task_id}")
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:task_completed, task_id, agent_name, result}, socket) do
    content =
      case result do
        result when is_binary(result) -> "completed task #{task_id}: #{result}"
        _ -> "completed task #{task_id}"
      end

    event = build_event(:task_complete, agent_name, content)
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:decision_logged, node_id, agent_name}, socket) do
    event = build_event(:decision, agent_name, "logged decision #{node_id}")
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:tool_call, agent_name, tool_name, target}, socket) do
    content = "used #{tool_name} on #{target}"
    event = build_event(:tool_call, agent_name, content)
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:agent_message, from_agent, to_agent, content}, socket) do
    event = build_event(:message, from_agent, "to #{to_agent}: #{content}")
    {:noreply, append_event(socket, event)}
  end

  def handle_info({:agent_stream_start, agent_name, _payload}, socket) do
    streaming = Map.put(socket.assigns.streaming_agents, agent_name, "")
    {:noreply, assign(socket, streaming_agents: streaming)}
  end

  def handle_info({:agent_stream_delta, agent_name, %{text: chunk}}, socket) do
    streaming =
      Map.update(
        socket.assigns.streaming_agents,
        agent_name,
        chunk,
        &(&1 <> chunk)
      )

    {:noreply, assign(socket, streaming_agents: streaming)}
  end

  def handle_info({:agent_stream_end, agent_name, _payload}, socket) do
    text = Map.get(socket.assigns.streaming_agents, agent_name, "")
    streaming = Map.delete(socket.assigns.streaming_agents, agent_name)

    socket = assign(socket, streaming_agents: streaming)

    if String.length(text) > 0 do
      event = build_event(:thinking, agent_name, text)
      {:noreply, append_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- UI Event Handlers ---

  @impl true
  def handle_event("filter_agent", %{"agent" => ""}, socket) do
    {:noreply, assign(socket, agent_filter: nil)}
  end

  def handle_event("filter_agent", %{"agent" => agent}, socket) do
    current = socket.assigns.agent_filter

    {:noreply,
     assign(socket, agent_filter: if(current == agent, do: nil, else: agent))}
  end

  def handle_event("toggle_type", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)
    filter = socket.assigns.type_filter

    new_filter =
      if MapSet.member?(filter, type) do
        MapSet.delete(filter, type)
      else
        MapSet.put(filter, type)
      end

    {:noreply, assign(socket, type_filter: new_filter)}
  end

  def handle_event("expand_event", %{"id" => id}, socket) do
    events =
      Enum.map(socket.assigns.events, fn event ->
        if event.id == id, do: Map.update(event, :expanded, true, &(!&1)), else: event
      end)

    {:noreply, assign(socket, events: events)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered_events, filtered_events(assigns))

    ~H"""
    <div class="flex flex-col h-full bg-gray-950">
      <!-- Agent Filters -->
      <div class="flex flex-wrap items-center gap-1.5 px-3 py-2 border-b border-gray-800">
        <button
          phx-click="filter_agent"
          phx-value-agent=""
          phx-target={@myself}
          class={"text-xs px-2 py-1 rounded font-medium transition #{if @agent_filter == nil, do: "bg-violet-600 text-white", else: "bg-gray-800 text-gray-400 hover:text-gray-200"}"}
        >
          All
        </button>
        <button
          :for={agent <- @known_agents}
          phx-click="filter_agent"
          phx-value-agent={agent}
          phx-target={@myself}
          class={"flex items-center gap-1.5 text-xs px-2 py-1 rounded font-medium transition #{if @agent_filter == agent, do: "bg-gray-700 text-white", else: "bg-gray-800 text-gray-400 hover:text-gray-200"}"}
        >
          <span class="w-2 h-2 rounded-full flex-shrink-0" style={"background-color: #{agent_color(agent)}"}></span>
          {agent}
        </button>
      </div>

      <!-- Type Filters -->
      <div class="flex flex-wrap items-center gap-1.5 px-3 py-1.5 border-b border-gray-800/50">
        <button
          :for={{type, config} <- type_config_list()}
          phx-click="toggle_type"
          phx-value-type={type}
          phx-target={@myself}
          class={"text-xs px-1.5 py-0.5 rounded font-medium transition #{if MapSet.size(@type_filter) > 0 && !MapSet.member?(@type_filter, type), do: "opacity-30", else: ""} #{config.bg} #{config.text}"}
        >
          {config.label}
        </button>
      </div>

      <!-- Active Streams -->
      <div
        :for={{agent_name, text} <- @streaming_agents}
        :if={text != ""}
        class="px-2 py-1.5 bg-indigo-900/20 border-b border-indigo-500/10 animate-fade-in"
      >
        <div class="flex items-center gap-2">
          <span
            class="w-2 h-2 rounded-full flex-shrink-0 animate-pulse"
            style={"background-color: #{agent_color(agent_name)}"}
          ></span>
          <span class="text-xs font-medium text-indigo-300">{agent_name}</span>
          <span class="text-xs text-indigo-400/60">thinking...</span>
        </div>
        <p class="text-xs text-gray-400 mt-1 truncate max-w-full">
          {String.slice(text, -120, 120)}
        </p>
      </div>

      <!-- Event Feed -->
      <div class="flex-1 overflow-auto" id={"activity-feed-#{@id}"} phx-hook="ScrollToBottom">
        <div class="flex flex-col gap-0.5 p-2">
          <div
            :if={@filtered_events == []}
            class="flex items-center justify-center h-32 text-gray-500 text-sm"
          >
            No activity yet
          </div>

          <div
            :for={event <- @filtered_events}
            class="flex items-start gap-2 px-2 py-1.5 rounded bg-gray-900/50 hover:bg-gray-900/80 transition"
          >
            <!-- Agent dot -->
            <span
              class="w-2 h-2 rounded-full mt-1.5 flex-shrink-0"
              style={"background-color: #{agent_color(event.agent)}"}
            >
            </span>

            <!-- Content -->
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-xs font-medium text-gray-200">{event.agent}</span>
                <span class={"text-xs px-1.5 py-0.5 rounded font-medium #{type_badge_class(event.type)}"}>
                  {type_label(event.type)}
                </span>
                <span class="text-xs text-gray-500 ml-auto flex-shrink-0">
                  {relative_time(event.timestamp)}
                </span>
              </div>
              <p class={"text-sm text-gray-300 #{if !Map.get(event, :expanded, false), do: "truncate"}"}>
                {event.content}
              </p>
              <button
                :if={String.length(event.content) > 120 && !Map.get(event, :expanded, false)}
                phx-click="expand_event"
                phx-value-id={event.id}
                phx-target={@myself}
                class="text-xs text-violet-400 hover:text-violet-300 mt-0.5"
              >
                show more
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp build_event(type, agent_name, content) do
    %{
      id: Ecto.UUID.generate(),
      type: type,
      agent: agent_name,
      content: content,
      timestamp: DateTime.utc_now(),
      expanded: false
    }
  end

  defp append_event(socket, event) do
    events = socket.assigns.events ++ [event]

    events =
      if length(events) > @max_events do
        Enum.drop(events, length(events) - @max_events)
      else
        events
      end

    known_agents =
      if event.agent in socket.assigns.known_agents do
        socket.assigns.known_agents
      else
        socket.assigns.known_agents ++ [event.agent]
      end

    assign(socket, events: events, known_agents: known_agents)
  end

  defp filtered_events(assigns) do
    events = assigns.events

    events =
      case assigns.agent_filter do
        nil -> events
        agent -> Enum.filter(events, &(&1.agent == agent))
      end

    case MapSet.size(assigns.type_filter) do
      0 -> events
      _ -> Enum.filter(events, &MapSet.member?(assigns.type_filter, &1.type))
    end
  end

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp agent_color(agent_name) do
    index = :erlang.phash2(agent_name, length(@agent_colors))
    Enum.at(@agent_colors, index)
  end

  defp type_badge_class(type) do
    case Map.get(@type_config, type) do
      %{bg: bg, text: text} -> "#{bg} #{text}"
      nil -> "bg-gray-400/20 text-gray-400"
    end
  end

  defp type_label(type) do
    case Map.get(@type_config, type) do
      %{label: label} -> label
      nil -> to_string(type)
    end
  end

  defp type_config_list do
    [
      {:tool_call, @type_config.tool_call},
      {:message, @type_config.message},
      {:decision, @type_config.decision},
      {:task_complete, @type_config.task_complete},
      {:task_assigned, @type_config.task_assigned},
      {:discovery, @type_config.discovery},
      {:error, @type_config.error},
      {:thinking, @type_config.thinking}
    ]
  end
end
