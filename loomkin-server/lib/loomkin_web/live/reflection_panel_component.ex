defmodule LoomkinWeb.ReflectionPanelComponent do
  @moduledoc """
  Reflection panel component for the workspace context inspector.

  Shows past reflection reports, pending proposals, and a "Run Reflection" button.
  """
  use LoomkinWeb, :live_component

  alias Loomkin.Kindred.Proposals
  alias Loomkin.Kindred.Reflection.Orchestrator

  def mount(socket) do
    {:ok,
     assign(socket,
       reports: [],
       proposals: [],
       running: false,
       active_report: nil
     )}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    reports = Loomkin.Snippets.list_reflection_reports(assigns[:workspace_id], assigns[:user])
    proposals = load_proposals(assigns[:kindred_id])

    {:ok, assign(socket, reports: reports, proposals: proposals)}
  end

  def handle_event("run_reflection", _params, socket) do
    workspace_id = socket.assigns[:workspace_id]

    if workspace_id do
      # Orchestrator.run_on_demand is async — it spawns a Task and returns :ok.
      # PubSub event {:reflection_complete, ...} will notify the UI when done.
      Orchestrator.run_on_demand(workspace_id, socket.assigns[:scope])
      {:noreply, assign(socket, running: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("view_report", %{"id" => id}, socket) do
    report = Enum.find(socket.assigns.reports, &(&1.id == id))
    {:noreply, assign(socket, active_report: report)}
  end

  def handle_event("close_report", _params, socket) do
    {:noreply, assign(socket, active_report: nil)}
  end

  def handle_event("approve_proposal", %{"id" => id}, socket) do
    proposal = Proposals.get_proposal(id)

    if proposal do
      scope = socket.assigns[:scope] || %{user: socket.assigns[:user]}
      Proposals.approve_proposal(scope, proposal)
      proposals = load_proposals(socket.assigns[:kindred_id])
      {:noreply, assign(socket, proposals: proposals)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reject_proposal", %{"id" => id}, socket) do
    proposal = Proposals.get_proposal(id)

    if proposal do
      scope = socket.assigns[:scope] || %{user: socket.assigns[:user]}
      Proposals.reject_proposal(scope, proposal, "Rejected from UI")
      proposals = load_proposals(socket.assigns[:kindred_id])
      {:noreply, assign(socket, proposals: proposals)}
    else
      {:noreply, socket}
    end
  end

  defp load_proposals(nil), do: []

  defp load_proposals(kindred_id) do
    Proposals.list_proposals_for_kindred(kindred_id)
  rescue
    _ -> []
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold text-zinc-400 uppercase tracking-wider">Reflection</h3>
        <button
          phx-click="run_reflection"
          phx-target={@myself}
          disabled={@running}
          class={[
            "text-xs px-3 py-1.5 rounded-lg font-medium transition-colors",
            if(@running,
              do: "bg-zinc-700 text-zinc-500 cursor-not-allowed",
              else: "bg-violet-600 hover:bg-violet-500 text-white"
            )
          ]}
        >
          <%= if @running do %>
            Running...
          <% else %>
            Run Reflection
          <% end %>
        </button>
      </div>

      <%!-- Pending proposals --%>
      <div :if={@proposals != []} class="space-y-2">
        <h4 class="text-xs font-semibold text-amber-400">
          Pending Proposals ({length(Enum.filter(@proposals, &(&1.status == :pending)))})
        </h4>
        <div
          :for={p <- Enum.filter(@proposals, &(&1.status == :pending))}
          class="p-3 bg-amber-600/10 border border-amber-600/30 rounded-lg"
        >
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs text-amber-400">From: {p.proposed_by}</span>
            <span class="text-xs text-zinc-500">
              {Calendar.strftime(p.inserted_at, "%Y-%m-%d %H:%M")}
            </span>
          </div>
          <p class="text-sm text-zinc-300 mb-2">
            {length(Map.get(p.changes, "recommendations", []))} recommendation(s)
          </p>
          <div class="flex gap-2">
            <button
              phx-click="approve_proposal"
              phx-value-id={p.id}
              phx-target={@myself}
              class="text-xs px-2 py-1 bg-emerald-600/20 text-emerald-400 rounded hover:bg-emerald-600/30"
            >
              Approve
            </button>
            <button
              phx-click="reject_proposal"
              phx-value-id={p.id}
              phx-target={@myself}
              class="text-xs px-2 py-1 bg-red-600/20 text-red-400 rounded hover:bg-red-600/30"
            >
              Reject
            </button>
          </div>
        </div>
      </div>

      <%!-- Past reports --%>
      <div class="space-y-2">
        <h4 class="text-xs font-semibold text-zinc-500">Past Reports</h4>
        <%= if @reports == [] do %>
          <p class="text-xs text-zinc-600 py-4 text-center">No reflection reports yet</p>
        <% else %>
          <div
            :for={r <- @reports}
            phx-click="view_report"
            phx-value-id={r.id}
            phx-target={@myself}
            class="p-3 bg-zinc-900 border border-zinc-800 rounded-lg cursor-pointer hover:border-zinc-700 transition-colors"
          >
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium">{r.title}</span>
              <span class="text-xs text-zinc-500">
                {Calendar.strftime(r.inserted_at, "%m/%d %H:%M")}
              </span>
            </div>
            <div class="flex gap-2 mt-1">
              <span class="text-xs text-zinc-500">
                Confidence: {Float.round((r.content["confidence"] || 0) * 100, 0)}%
              </span>
              <span class="text-xs text-zinc-500">
                {length(r.content["recommendations"] || [])} recommendations
              </span>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Active report viewer --%>
      <div
        :if={@active_report}
        class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-8"
      >
        <div class="bg-zinc-900 border border-zinc-700 rounded-xl max-w-2xl w-full max-h-[80vh] overflow-y-auto p-6">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-semibold">{@active_report.title}</h3>
            <button
              phx-click="close_report"
              phx-target={@myself}
              class="text-zinc-400 hover:text-white text-lg"
            >
              &times;
            </button>
          </div>
          <div class="prose prose-invert prose-sm max-w-none">
            <pre class="whitespace-pre-wrap text-sm text-zinc-300">{@active_report.content["report"]}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
