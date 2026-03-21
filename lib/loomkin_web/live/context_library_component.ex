defmodule LoomkinWeb.ContextLibraryComponent do
  @moduledoc """
  Context Library — master-detail inspector for context keepers.

  Left panel: sortable, filterable keeper list using LiveView streams.
  Right panel: inspector with full metadata, staleness visualization,
  message preview, and actions.

  Receives real-time updates via send_update from WorkspaceLive.
  """

  use LoomkinWeb, :live_component

  alias Loomkin.Teams.ContextKeeper
  alias Loomkin.Teams.ContextRetrieval

  @staleness_colors %{
    fresh: {"bg-emerald-400", "text-emerald-400", "emerald"},
    warm: {"bg-yellow-400", "text-yellow-400", "yellow"},
    stale: {"bg-orange-400", "text-orange-400", "orange"},
    expired: {"bg-red-400", "text-red-400", "red"}
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       keepers: [],
       selected_keeper: nil,
       selected_detail: nil,
       sort_by: :last_accessed_at,
       sort_dir: :desc,
       filter_status: :active,
       filter_staleness: :all,
       filter_agent: :all,
       search_query: "",
       messages_expanded: false,
       known_agents: []
     )
     |> stream(:keeper_rows, [])}
  end

  @impl true
  def update(%{reload: true} = assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :reload))
    {:ok, load_keepers(socket)}
  end

  def update(%{team_id: team_id} = assigns, socket) do
    prev_team_id = socket.assigns[:team_id]

    socket = assign(socket, assigns)

    if prev_team_id != team_id do
      {:ok, load_keepers(socket)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # -- Events --

  @valid_sort_fields ~w(topic source_agent token_count created_at last_accessed_at access_count staleness confidence)

  @impl true
  def handle_event("sort", %{"field" => field}, socket)
      when field in @valid_sort_fields do
    field_atom = String.to_existing_atom(field)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == field_atom do
        {field_atom, toggle_dir(socket.assigns.sort_dir)}
      else
        {field_atom, :desc}
      end

    socket =
      socket
      |> assign(sort_by: sort_by, sort_dir: sort_dir)
      |> restream_keepers()

    {:noreply, socket}
  end

  def handle_event("select_keeper", %{"id" => id}, socket) do
    detail = fetch_keeper_detail(socket.assigns.team_id, id)

    {:noreply,
     assign(socket,
       selected_keeper: id,
       selected_detail: detail,
       messages_expanded: false
     )}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, assign(socket, selected_keeper: nil, selected_detail: nil)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(filter_status: String.to_existing_atom(status))
     |> load_keepers()}
  end

  @valid_staleness_filters ~w(all fresh warm stale expired)

  def handle_event("filter_staleness", %{"state" => state}, socket)
      when state in @valid_staleness_filters do
    {:noreply,
     socket
     |> assign(filter_staleness: String.to_existing_atom(state))
     |> restream_keepers()}
  end

  def handle_event("filter_agent", %{"agent" => agent}, socket) do
    filter = if agent == "all", do: :all, else: agent

    {:noreply,
     socket
     |> assign(filter_agent: filter)
     |> restream_keepers()}
  end

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply,
     socket
     |> assign(search_query: query)
     |> restream_keepers()}
  end

  def handle_event("toggle_messages", _params, socket) do
    {:noreply, assign(socket, messages_expanded: !socket.assigns.messages_expanded)}
  end

  def handle_event("refresh_keeper", %{"id" => id}, socket) do
    detail = fetch_keeper_detail(socket.assigns.team_id, id)
    {:noreply, socket |> assign(selected_detail: detail) |> load_keepers()}
  end

  def handle_event("archive_keeper", %{"id" => id}, socket) do
    # Archive: mark as archived in DB, then stop the process
    import Ecto.Query
    alias Loomkin.Schemas.ContextKeeper, as: KeeperSchema

    KeeperSchema
    |> where([k], k.id == ^id)
    |> Loomkin.Repo.update_all(set: [status: "archived"])

    case Registry.lookup(Loomkin.Keepers.Registry, {socket.assigns.team_id, id}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    {:noreply,
     socket
     |> assign(selected_keeper: nil, selected_detail: nil)
     |> load_keepers()}
  end

  def handle_event("delete_keeper", %{"id" => id}, socket) do
    # Delete: remove from DB entirely, then stop the process
    import Ecto.Query
    alias Loomkin.Schemas.ContextKeeper, as: KeeperSchema

    case Registry.lookup(Loomkin.Keepers.Registry, {socket.assigns.team_id, id}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    KeeperSchema
    |> where([k], k.id == ^id)
    |> Loomkin.Repo.delete_all()

    {:noreply,
     socket
     |> assign(selected_keeper: nil, selected_detail: nil)
     |> load_keepers()}
  end

  # Signal handlers removed — LiveComponents share the parent process.
  # WorkspaceLive forwards keeper events via send_update/2.

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div id="context-library" class="flex flex-col h-full">
      <%!-- Header + filters --%>
      <div class="flex-shrink-0 border-b border-subtle">
        <div class="flex items-center gap-2 px-3 py-2">
          <div class="flex items-center gap-1.5">
            <span class="hero-circle-stack-mini inline-block w-3.5 h-3.5 text-violet-400" />
            <span class="text-[11px] font-semibold text-secondary uppercase tracking-wider">
              Context Library
            </span>
          </div>
          <span class="text-[10px] text-muted tabular-nums ml-auto">
            {length(@keepers)} keepers
          </span>
        </div>

        <%!-- Search --%>
        <div class="px-3 pb-2">
          <div class="relative">
            <span class="hero-magnifying-glass-mini absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-muted" />
            <input
              type="text"
              placeholder="Search topic, agent, id..."
              value={@search_query}
              phx-keyup="search"
              phx-debounce="300"
              phx-target={@myself}
              class={[
                "w-full pl-7 pr-2 py-1.5 text-[11px] rounded-md bg-surface-2 border border-subtle",
                "text-secondary placeholder-zinc-600 focus:outline-none focus:border-violet-500/40",
                "transition-colors"
              ]}
            />
          </div>
        </div>

        <%!-- Filter row --%>
        <div class="flex items-center gap-1.5 px-3 pb-2 overflow-x-auto">
          <%!-- Status filter --%>
          <.filter_pill
            label="Active"
            active={@filter_status == :active}
            phx-click="filter_status"
            phx-value-status="active"
            phx-target={@myself}
          />
          <.filter_pill
            label="Archived"
            active={@filter_status == :archived}
            phx-click="filter_status"
            phx-value-status="archived"
            phx-target={@myself}
          />
          <.filter_pill
            label="All"
            active={@filter_status == :all}
            phx-click="filter_status"
            phx-value-status="all"
            phx-target={@myself}
          />

          <span class="w-px h-3 bg-zinc-700 mx-0.5" />

          <%!-- Staleness filter --%>
          <.filter_pill
            :for={state <- [:all, :fresh, :warm, :stale, :expired]}
            label={staleness_filter_label(state)}
            active={@filter_staleness == state}
            phx-click="filter_staleness"
            phx-value-state={state}
            phx-target={@myself}
          />

          <%!-- Agent filter --%>
          <%= if @known_agents != [] do %>
            <span class="w-px h-3 bg-zinc-700 mx-0.5" />
            <select
              phx-change="filter_agent"
              phx-target={@myself}
              name="agent"
              class={[
                "text-[10px] bg-surface-2 border border-subtle rounded-md px-1.5 py-1",
                "text-muted focus:outline-none focus:border-violet-500/40"
              ]}
            >
              <option value="all" selected={@filter_agent == :all}>All agents</option>
              <option :for={agent <- @known_agents} value={agent} selected={@filter_agent == agent}>
                {agent}
              </option>
            </select>
          <% end %>
        </div>
      </div>

      <%!-- Content: list + inspector --%>
      <div class="flex-1 flex min-h-0">
        <%!-- Left: keeper list --%>
        <div class={[
          "flex flex-col min-h-0 overflow-hidden transition-all duration-200",
          if(@selected_keeper, do: "w-1/2 border-r border-subtle", else: "w-full")
        ]}>
          <%!-- Column headers --%>
          <div class="flex items-center gap-1 px-2 py-1.5 text-[9px] font-medium text-muted uppercase tracking-wider border-b border-subtle flex-shrink-0 bg-surface-1">
            <.sort_header
              field="topic"
              label="Topic"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="flex-1 min-w-0"
              myself={@myself}
            />
            <.sort_header
              field="source_agent"
              label="Agent"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="w-16 text-right"
              myself={@myself}
            />
            <.sort_header
              field="token_count"
              label="Size"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="w-10 text-right"
              myself={@myself}
            />
            <.sort_header
              field="staleness"
              label="State"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="w-12 text-center"
              myself={@myself}
            />
            <.sort_header
              field="access_count"
              label="Hits"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="w-8 text-right"
              myself={@myself}
            />
            <.sort_header
              field="confidence"
              label="Conf"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="w-10 text-right"
              myself={@myself}
            />
          </div>

          <%!-- Rows --%>
          <div id="keeper-rows" phx-update="stream" class="flex-1 overflow-y-auto">
            <%!-- Empty state (visible only when stream has no children) --%>
            <div class="hidden only:flex flex-col items-center justify-center p-6">
              <div class="w-8 h-8 rounded-lg bg-violet-500/10 flex items-center justify-center mb-2">
                <span class="hero-circle-stack-mini inline-block w-4 h-4 text-violet-400" />
              </div>
              <p class="text-[11px] text-muted text-center">No keepers match filters</p>
            </div>
            <div
              :for={{dom_id, keeper} <- @streams.keeper_rows}
              id={dom_id}
              phx-click="select_keeper"
              phx-value-id={keeper.id}
              phx-target={@myself}
              class={[
                "flex items-center gap-1 px-2 py-1.5 cursor-pointer transition-colors duration-100",
                "border-b border-subtle/50 hover:bg-surface-2",
                @selected_keeper == keeper.id && "bg-violet-500/10 border-l-2 border-l-violet-500"
              ]}
            >
              <div class="flex-1 min-w-0">
                <span class="text-[11px] text-secondary truncate block" title={keeper.topic}>
                  {truncate(keeper.topic, 40)}
                </span>
              </div>
              <span
                class="w-16 text-[10px] text-muted truncate text-right"
                title={keeper.source_agent}
              >
                {truncate(keeper.source_agent, 10)}
              </span>
              <span class="w-10 text-[10px] text-muted tabular-nums text-right">
                {format_tokens(keeper.token_count)}
              </span>
              <div class="w-12 flex justify-center">
                <.staleness_badge state={keeper.staleness_state} score={keeper.staleness} />
              </div>
              <span class="w-8 text-[10px] text-muted tabular-nums text-right">
                {keeper.access_count}
              </span>
              <span class={[
                "w-10 text-[10px] tabular-nums text-right font-medium",
                confidence_color(keeper.confidence)
              ]}>
                {format_pct(keeper.confidence)}
              </span>
            </div>
          </div>

          <%!-- No-keepers-at-all state (no keepers loaded from source) --%>
          <div :if={@keepers == []} class="flex-1 flex flex-col items-center justify-center p-6">
            <div class="w-8 h-8 rounded-lg bg-violet-500/10 flex items-center justify-center mb-2">
              <span class="hero-circle-stack-mini inline-block w-4 h-4 text-violet-400" />
            </div>
            <p class="text-[11px] text-muted text-center">No context keepers found</p>
            <p class="text-[10px] text-zinc-600 text-center mt-1">
              Keepers are created when agents store context
            </p>
          </div>
        </div>

        <%!-- Right: inspector --%>
        <div
          :if={@selected_keeper && @selected_detail}
          class="w-1/2 flex flex-col min-h-0 overflow-y-auto bg-surface-0"
        >
          <.keeper_inspector
            detail={@selected_detail}
            messages_expanded={@messages_expanded}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  # -- Sub-components --

  defp filter_pill(assigns) do
    assigns =
      assign_new(assigns, :rest, fn -> assigns_to_attributes(assigns, [:label, :active]) end)

    ~H"""
    <button
      class={[
        "px-2 py-0.5 text-[10px] font-medium rounded-full transition-colors duration-150",
        if(@active,
          do: "bg-violet-500/20 text-violet-300 border border-violet-500/30",
          else: "text-muted hover:text-secondary hover:bg-surface-2 border border-transparent"
        )
      ]}
      {@rest}
    >
      {@label}
    </button>
    """
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :class, :string, default: ""
  attr :myself, :any, required: true

  defp sort_header(assigns) do
    active = assigns.sort_by == String.to_existing_atom(assigns.field)
    assigns = assign(assigns, :active, active)

    ~H"""
    <button
      phx-click="sort"
      phx-value-field={@field}
      phx-target={@myself}
      class={[
        "flex items-center gap-0.5 interactive transition-colors",
        @class,
        if(@active, do: "text-violet-400", else: "hover:text-zinc-400")
      ]}
    >
      <span>{@label}</span>
      <span :if={@active} class="text-[8px]">
        {if @sort_dir == :asc, do: raw("&#9650;"), else: raw("&#9660;")}
      </span>
    </button>
    """
  end

  defp staleness_badge(assigns) do
    {bg, _text, _name} =
      Map.get(@staleness_colors, assigns.state, {"bg-zinc-500", "text-zinc-400", "zinc"})

    assigns = assign(assigns, :bg, bg)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[9px] font-medium",
        staleness_badge_class(@state)
      ]}
      title={"Staleness: #{@score}/100 (#{@state})"}
    >
      <span class={["w-1.5 h-1.5 rounded-full", @bg]} />
      {@state}
    </span>
    """
  end

  defp keeper_inspector(assigns) do
    detail = assigns.detail

    staleness_factors = %{
      time: compute_factor_pct(detail[:created_at], :time),
      access: compute_factor_pct(detail[:last_accessed_at], :access),
      relevance: round((1.0 - min(detail[:relevance_score] || 0.0, 1.0)) * 100),
      confidence:
        compute_confidence_factor_pct(detail[:success_count] || 0, detail[:miss_count] || 0)
    }

    messages = detail[:messages] || []
    preview_messages = if assigns.messages_expanded, do: messages, else: Enum.take(messages, 2)

    assigns =
      assigns
      |> assign(:staleness_factors, staleness_factors)
      |> assign(:messages, messages)
      |> assign(:preview_messages, preview_messages)
      |> assign(:total_messages, length(messages))

    ~H"""
    <div class="flex flex-col">
      <%!-- Inspector header --%>
      <div class="flex items-center gap-2 px-3 py-2 border-b border-subtle bg-surface-1 flex-shrink-0">
        <span class="hero-eye-mini inline-block w-3.5 h-3.5 text-violet-400" />
        <span class="text-[11px] font-semibold text-secondary truncate flex-1">
          {@detail.topic}
        </span>
        <button
          phx-click="close_inspector"
          phx-target={@myself}
          class="interactive p-1 rounded-md text-muted hover:text-secondary"
        >
          <.icon name="hero-x-mark-mini" class="w-3 h-3" />
        </button>
      </div>

      <div class="p-3 space-y-3">
        <%!-- Metadata grid --%>
        <div class="grid grid-cols-2 gap-x-3 gap-y-1.5">
          <.meta_row label="ID" value={truncate(@detail.id, 20)} mono />
          <.meta_row label="Source" value={@detail.source_agent} />
          <.meta_row label="Tokens" value={format_number(@detail.token_count)} mono />
          <.meta_row label="Queries" value={to_string(@detail.access_count || 0)} mono />
          <.meta_row label="Created" value={format_relative(@detail.created_at)} />
          <.meta_row label="Last Access" value={format_relative(@detail.last_accessed_at)} />
          <.meta_row label="Last Agent" value={@detail.last_agent_name || "none"} />
          <.meta_row label="Confidence" value={format_pct(@detail.confidence)} />
          <.meta_row
            label="Success/Miss"
            value={"#{@detail.success_count || 0}/#{@detail.miss_count || 0}"}
            mono
          />
          <.meta_row label="Staleness" value={"#{@detail.staleness}/100"} mono />
        </div>

        <%!-- Staleness breakdown --%>
        <div class="rounded-lg bg-surface-1 border border-subtle p-2.5">
          <span class="text-[10px] font-medium text-muted uppercase tracking-wider block mb-2">
            Staleness Factors
          </span>
          <div class="space-y-1.5">
            <.staleness_factor_bar label="Time" pct={@staleness_factors.time} color="bg-blue-400" />
            <.staleness_factor_bar
              label="Access"
              pct={@staleness_factors.access}
              color="bg-amber-400"
            />
            <.staleness_factor_bar
              label="Relevance"
              pct={@staleness_factors.relevance}
              color="bg-violet-400"
            />
            <.staleness_factor_bar
              label="Confidence"
              pct={@staleness_factors.confidence}
              color="bg-emerald-400"
            />
          </div>
        </div>

        <%!-- Retrieval histogram --%>
        <%= if @detail.retrieval_mode_histogram && @detail.retrieval_mode_histogram != %{} do %>
          <div class="rounded-lg bg-surface-1 border border-subtle p-2.5">
            <span class="text-[10px] font-medium text-muted uppercase tracking-wider block mb-2">
              Retrieval Modes
            </span>
            <div class="flex items-center gap-2">
              <span
                :for={{mode, count} <- @detail.retrieval_mode_histogram}
                class="text-[10px] px-1.5 py-0.5 rounded bg-surface-2 text-secondary"
              >
                {mode}: <span class="font-mono text-violet-300">{count}</span>
              </span>
            </div>
          </div>
        <% end %>

        <%!-- Message preview --%>
        <div class="rounded-lg bg-surface-1 border border-subtle p-2.5">
          <div class="flex items-center justify-between mb-2">
            <span class="text-[10px] font-medium text-muted uppercase tracking-wider">
              Messages ({@total_messages})
            </span>
            <button
              :if={@total_messages > 2}
              phx-click="toggle_messages"
              phx-target={@myself}
              class="text-[10px] text-violet-400 interactive hover:text-violet-300"
            >
              {if @messages_expanded, do: "Collapse", else: "Show all"}
            </button>
          </div>
          <div class="space-y-1.5 max-h-48 overflow-y-auto">
            <div
              :for={msg <- @preview_messages}
              class="text-[10px] leading-relaxed border-l-2 border-zinc-700 pl-2 py-0.5"
            >
              <span class={[
                "font-medium uppercase text-[9px] tracking-wider",
                message_role_color(msg)
              ]}>
                {message_role(msg)}
              </span>
              <p class="text-secondary mt-0.5 break-words">
                {truncate(message_content(msg), 200)}
              </p>
            </div>
            <p :if={@preview_messages == []} class="text-[10px] text-muted italic">
              No messages stored
            </p>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex items-center gap-2 pt-1">
          <.action_button
            label="Refresh"
            icon="hero-arrow-path-mini"
            phx-click="refresh_keeper"
            phx-value-id={@detail.id}
            phx-target={@myself}
          />
          <.action_button
            label="Archive"
            icon="hero-archive-box-mini"
            phx-click="archive_keeper"
            phx-value-id={@detail.id}
            phx-target={@myself}
            confirm="Archive this keeper?"
          />
          <.action_button
            label="Delete"
            icon="hero-trash-mini"
            phx-click="delete_keeper"
            phx-value-id={@detail.id}
            phx-target={@myself}
            color="text-red-400 hover:bg-red-500/10"
            confirm="Permanently delete this keeper?"
          />
          <button
            id={"copy-keeper-#{@detail.id}"}
            phx-hook="CopyToClipboard"
            data-copy-text={@detail.id}
            class={[
              "flex items-center gap-1 px-2 py-1 text-[10px] font-medium rounded-md",
              "transition-colors interactive text-muted hover:bg-surface-2 ml-auto"
            ]}
          >
            <.icon name="hero-clipboard-mini" class="w-3 h-3" />
            <span>Copy ID</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp meta_row(assigns) do
    assigns = assign_new(assigns, :mono, fn -> false end)

    ~H"""
    <div class="flex items-baseline gap-1.5">
      <span class="text-[9px] text-muted uppercase tracking-wider w-16 flex-shrink-0">{@label}</span>
      <span
        class={[
          "text-[10px] text-secondary truncate",
          @mono && "font-mono"
        ]}
        title={@value}
      >
        {@value}
      </span>
    </div>
    """
  end

  defp staleness_factor_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-[9px] text-muted w-14 flex-shrink-0">{@label}</span>
      <div class="flex-1 h-1.5 bg-surface-3 rounded-full overflow-hidden">
        <div
          class={["h-full rounded-full transition-all duration-500", @color]}
          style={"width: #{min(@pct, 100)}%"}
        />
      </div>
      <span class="text-[9px] text-muted tabular-nums w-6 text-right">{@pct}%</span>
    </div>
    """
  end

  defp action_button(assigns) do
    assigns =
      assigns
      |> assign_new(:color, fn -> "text-muted hover:bg-surface-2" end)
      |> assign_new(:class, fn -> "" end)
      |> assign_new(:confirm, fn -> nil end)
      |> assign_new(:rest, fn ->
        assigns_to_attributes(assigns, [:label, :icon, :color, :class, :confirm])
      end)

    ~H"""
    <button
      class={[
        "flex items-center gap-1 px-2 py-1 text-[10px] font-medium rounded-md transition-colors interactive",
        @color,
        @class
      ]}
      data-confirm={@confirm}
      {@rest}
    >
      <.icon name={@icon} class="w-3 h-3" />
      <span>{@label}</span>
    </button>
    """
  end

  # -- Data loading --

  defp load_keepers(socket) do
    team_id = socket.assigns.team_id

    keepers =
      if team_id do
        raw_keepers = ContextRetrieval.list_keepers(team_id)

        details =
          raw_keepers
          |> Task.async_stream(
            fn k -> {k.id, fetch_keeper_detail(team_id, k.id)} end,
            timeout: :timer.seconds(5),
            on_timeout: :kill_task
          )
          |> Enum.reduce(%{}, fn
            {:ok, {id, detail}}, acc -> Map.put(acc, id, detail)
            _, acc -> acc
          end)

        Enum.map(raw_keepers, fn k ->
          detail = Map.get(details, k.id)

          %{
            id: k.id,
            topic: k.topic,
            source_agent: k.source_agent,
            token_count: k.token_count,
            staleness: k.staleness,
            staleness_state: k.staleness_state,
            access_count: detail[:access_count] || 0,
            confidence: detail[:confidence] || 0.5,
            created_at: detail[:created_at],
            last_accessed_at: detail[:last_accessed_at],
            pid: k.pid
          }
        end)
      else
        []
      end

    known_agents =
      keepers
      |> Enum.map(& &1.source_agent)
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(keepers: keepers, known_agents: known_agents)
    |> restream_keepers()
  end

  defp restream_keepers(socket) do
    filtered = apply_filters(socket.assigns.keepers, socket.assigns)
    sorted = apply_sort(filtered, socket.assigns.sort_by, socket.assigns.sort_dir)
    stream(socket, :keeper_rows, sorted, reset: true)
  end

  defp apply_filters(keepers, assigns) do
    keepers
    |> filter_by_search(assigns.search_query)
    |> filter_by_staleness(assigns.filter_staleness)
    |> filter_by_agent(assigns.filter_agent)
  end

  defp filter_by_search(keepers, ""), do: keepers

  defp filter_by_search(keepers, query) do
    q = String.downcase(query)

    Enum.filter(keepers, fn k ->
      String.contains?(String.downcase(k.topic), q) ||
        String.contains?(String.downcase(k.source_agent), q) ||
        String.contains?(String.downcase(k.id), q)
    end)
  end

  defp filter_by_staleness(keepers, :all), do: keepers

  defp filter_by_staleness(keepers, state) do
    Enum.filter(keepers, &(&1.staleness_state == state))
  end

  defp filter_by_agent(keepers, :all), do: keepers

  defp filter_by_agent(keepers, agent) do
    Enum.filter(keepers, &(&1.source_agent == agent))
  end

  defp apply_sort(keepers, field, dir) do
    Enum.sort_by(keepers, &sort_key(&1, field), sort_comparator(dir))
  end

  defp sort_key(k, :topic), do: String.downcase(k.topic)
  defp sort_key(k, :source_agent), do: String.downcase(k.source_agent)
  defp sort_key(k, :token_count), do: k.token_count
  defp sort_key(k, :staleness), do: k.staleness
  defp sort_key(k, :access_count), do: k.access_count
  defp sort_key(k, :confidence), do: k.confidence

  defp sort_key(k, :created_at) do
    case k.created_at do
      %DateTime{} = dt -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp sort_key(k, :last_accessed_at) do
    case k.last_accessed_at do
      %DateTime{} = dt -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp sort_key(k, _), do: k.id

  defp sort_comparator(:asc), do: :asc
  defp sort_comparator(:desc), do: :desc

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp fetch_keeper_detail(team_id, id) do
    case Registry.lookup(Loomkin.Keepers.Registry, {team_id, id}) do
      [{pid, _}] ->
        try do
          state = ContextKeeper.get_state(pid)
          staleness = ContextKeeper.compute_staleness(state)
          Map.put(state, :staleness, staleness)
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

      [] ->
        nil
    end
  end

  # -- Formatting helpers --

  defp truncate(nil, _max), do: ""

  defp truncate(s, max) when is_binary(s),
    do: if(String.length(s) <= max, do: s, else: String.slice(s, 0, max) <> "...")

  defp truncate(_, _max), do: ""

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}k"

  defp format_tokens(n) when is_number(n), do: to_string(trunc(n))
  defp format_tokens(_), do: "0"

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_number(n), do: to_string(trunc(n))
  defp format_number(_), do: "0"

  defp format_pct(nil), do: "--"
  defp format_pct(f) when is_float(f), do: "#{round(f * 100)}%"
  defp format_pct(i) when is_integer(i), do: "#{i}%"
  defp format_pct(_), do: "--"

  defp format_relative(nil), do: "never"

  defp format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp format_relative(_), do: "unknown"

  defp confidence_color(c) when is_number(c) and c >= 0.7, do: "text-emerald-400"
  defp confidence_color(c) when is_number(c) and c >= 0.4, do: "text-yellow-400"
  defp confidence_color(c) when is_number(c), do: "text-red-400"
  defp confidence_color(_), do: "text-muted"

  defp staleness_badge_class(:fresh), do: "bg-emerald-500/10 text-emerald-400"
  defp staleness_badge_class(:warm), do: "bg-yellow-500/10 text-yellow-400"
  defp staleness_badge_class(:stale), do: "bg-orange-500/10 text-orange-400"
  defp staleness_badge_class(:expired), do: "bg-red-500/10 text-red-400"
  defp staleness_badge_class(_), do: "bg-zinc-500/10 text-muted"

  defp staleness_filter_label(:all), do: "Any"
  defp staleness_filter_label(:fresh), do: "Fresh"
  defp staleness_filter_label(:warm), do: "Warm"
  defp staleness_filter_label(:stale), do: "Stale"
  defp staleness_filter_label(:expired), do: "Expired"

  defp message_role(%{role: role}), do: to_string(role)
  defp message_role(%{"role" => role}), do: to_string(role)
  defp message_role(_), do: "unknown"

  defp message_content(%{content: c}) when is_binary(c), do: c
  defp message_content(%{"content" => c}) when is_binary(c), do: c
  defp message_content(_), do: ""

  defp message_role_color(msg) do
    case message_role(msg) do
      "system" -> "text-violet-400"
      "user" -> "text-blue-400"
      "assistant" -> "text-emerald-400"
      _ -> "text-muted"
    end
  end

  defp compute_factor_pct(nil, :access), do: 100

  defp compute_factor_pct(dt, :time) do
    case dt do
      %DateTime{} ->
        hours = DateTime.diff(DateTime.utc_now(), dt, :second) / 3600.0
        min(round(hours * 5 / 25 * 100), 100)

      _ ->
        0
    end
  end

  defp compute_factor_pct(dt, :access) do
    case dt do
      %DateTime{} ->
        hours = DateTime.diff(DateTime.utc_now(), dt, :second) / 3600.0
        min(round(hours / 12.0 * 100), 100)

      _ ->
        100
    end
  end

  defp compute_confidence_factor_pct(success, miss) do
    total = success + miss

    if total == 0 do
      52
    else
      round(miss / total * 100)
    end
  end
end
