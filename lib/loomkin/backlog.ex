defmodule Loomkin.Backlog do
  @moduledoc """
  Context module for the persistent backlog/roadmap system.

  Provides CRUD operations, querying, and prioritization for backlog items.
  Designed to be the primary interface for agents (via tools) and the
  concierge (via LiveView) to manage planned work.

  ## Query Patterns

  - `list_actionable/1` — todo + in_progress items sorted by priority (concierge's main view)
  - `list_by_epic/1` — roadmap view grouped by epic
  - `list_by_status/1` — filter by lifecycle state
  - `search/1` — full-text search across title + description
  - `get_summary/0` — counts by status for dashboard display
  """

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.BacklogItem

  # ── CRUD ────────────────────────────────────────────────────────────

  @doc "Create a new backlog item."
  def create_item(attrs) when is_map(attrs) do
    %BacklogItem{}
    |> BacklogItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get a backlog item by ID."
  def get_item(id) when is_binary(id) do
    case Repo.get(BacklogItem, id) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  @doc "Get a backlog item by ID, raising if not found."
  def get_item!(id) when is_binary(id) do
    Repo.get!(BacklogItem, id)
  end

  @doc "Update a backlog item."
  def update_item(%BacklogItem{} = item, attrs) do
    item
    |> BacklogItem.changeset(attrs)
    |> Repo.update()
  end

  def update_item(id, attrs) when is_binary(id) do
    case get_item(id) do
      {:ok, item} -> update_item(item, attrs)
      error -> error
    end
  end

  @doc "Delete a backlog item."
  def delete_item(%BacklogItem{} = item) do
    Repo.delete(item)
  end

  def delete_item(id) when is_binary(id) do
    case get_item(id) do
      {:ok, item} -> delete_item(item)
      error -> error
    end
  end

  # ── Queries ─────────────────────────────────────────────────────────

  @doc """
  List actionable items — todo and in_progress, sorted by priority then sort_order.
  This is the concierge's primary view: "what should we work on?"
  """
  def list_actionable(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)

    BacklogItem
    |> where([b], b.status in [:todo, :in_progress])
    |> maybe_scope_workspace(workspace_id)
    |> order_by([b], asc: b.priority, asc: b.sort_order, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List items by status."
  def list_by_status(status, opts \\ []) when is_atom(status) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)

    BacklogItem
    |> where([b], b.status == ^status)
    |> maybe_scope_workspace(workspace_id)
    |> order_by([b], asc: b.priority, asc: b.sort_order, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List items grouped by epic."
  def list_by_epic(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    BacklogItem
    |> where([b], b.status in [:todo, :in_progress, :blocked])
    |> where([b], not is_nil(b.epic))
    |> maybe_scope_workspace(workspace_id)
    |> order_by([b], asc: b.epic, asc: b.priority, asc: b.sort_order)
    |> Repo.all()
    |> Enum.group_by(& &1.epic)
  end

  @doc "List items by category."
  def list_by_category(category, opts \\ []) when is_binary(category) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)

    BacklogItem
    |> where([b], b.category == ^category)
    |> maybe_scope_workspace(workspace_id)
    |> order_by([b], asc: b.priority, asc: b.sort_order, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List items assigned to a specific team."
  def list_by_team(team_id, opts \\ []) when is_binary(team_id) do
    limit = Keyword.get(opts, :limit, 50)

    BacklogItem
    |> where([b], b.assigned_team == ^team_id)
    |> order_by([b], asc: b.priority, asc: b.sort_order, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Search backlog items by title or description."
  def search(term, opts \\ []) when is_binary(term) do
    limit = Keyword.get(opts, :limit, 20)
    workspace_id = Keyword.get(opts, :workspace_id)
    pattern = "%#{term}%"

    BacklogItem
    |> where([b], ilike(b.title, ^pattern) or ilike(b.description, ^pattern))
    |> maybe_scope_workspace(workspace_id)
    |> order_by([b], asc: b.priority, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get a summary of backlog counts by status.
  Returns a map like %{todo: 5, in_progress: 2, done: 12, ...}
  """
  def get_summary(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    BacklogItem
    |> maybe_scope_workspace(workspace_id)
    |> group_by([b], b.status)
    |> select([b], {b.status, count(b.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ── Status Transitions ─────────────────────────────────────────────

  @doc "Move an item to in_progress status."
  def start_item(id) when is_binary(id) do
    update_item(id, %{status: :in_progress})
  end

  @doc "Mark an item as done with an optional result."
  def complete_item(id, result \\ nil) when is_binary(id) do
    attrs = %{status: :done}
    attrs = if result, do: Map.put(attrs, :result, result), else: attrs
    update_item(id, attrs)
  end

  @doc "Mark an item as blocked."
  def block_item(id) when is_binary(id) do
    update_item(id, %{status: :blocked})
  end

  @doc "Cancel an item."
  def cancel_item(id) when is_binary(id) do
    update_item(id, %{status: :cancelled})
  end

  @doc "Send an item to the icebox."
  def icebox_item(id) when is_binary(id) do
    update_item(id, %{status: :icebox})
  end

  # ── Prioritization ─────────────────────────────────────────────────

  @doc "Reprioritize an item (1=critical, 5=someday)."
  def reprioritize(id, priority) when is_binary(id) and priority in 1..5 do
    update_item(id, %{priority: priority})
  end

  # ── Migration from Decision Graph ──────────────────────────────────

  @doc """
  Import active goals from the decision graph as backlog items.
  Useful for one-time migration from the old system.
  """
  def import_from_decision_graph(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    active_goals =
      Loomkin.Schemas.DecisionNode
      |> where([n], n.node_type == :goal and n.status == :active)
      |> Repo.all()

    results =
      Enum.map(active_goals, fn node ->
        attrs = %{
          title: node.title,
          description: node.description,
          status: :todo,
          priority: confidence_to_priority(node.confidence),
          category: "imported",
          created_by: node.agent_name || "system",
          decision_node_id: node.id,
          workspace_id: workspace_id
        }

        create_item(attrs)
      end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.count(results, &match?({:error, _}, &1))

    {:ok, %{imported: successes, failed: failures, total: length(active_goals)}}
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp maybe_scope_workspace(query, nil), do: query

  defp maybe_scope_workspace(query, workspace_id) do
    where(query, [b], b.workspace_id == ^workspace_id)
  end

  # Map decision graph confidence (0-100) to backlog priority (1-5)
  defp confidence_to_priority(nil), do: 3
  defp confidence_to_priority(c) when c >= 90, do: 1
  defp confidence_to_priority(c) when c >= 70, do: 2
  defp confidence_to_priority(c) when c >= 50, do: 3
  defp confidence_to_priority(c) when c >= 30, do: 4
  defp confidence_to_priority(_), do: 5
end
