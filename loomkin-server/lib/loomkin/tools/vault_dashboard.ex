defmodule Loomkin.Tools.VaultDashboard do
  @moduledoc "Agent tool for generating vault dashboard summaries."

  use Jido.Action,
    name: "vault_dashboard",
    description:
      "Generate dashboard data from the vault. Types: index (full overview), " <>
        "activity (recent changes), updates_hub (checkin summaries), kanban_summary (task board stats).",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      dashboard_type: [
        type: :string,
        required: true,
        doc: "Dashboard type: index, activity, updates_hub, kanban_summary"
      ],
      days: [type: :integer, doc: "Number of days of history (default: 7)"],
      person: [type: :string, doc: "Filter by person (for updates_hub)"]
    ]

  import Ecto.Query
  import Loomkin.Tool, only: [param!: 2, param: 2, param: 3]

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultEntry
  alias Loomkin.Schemas.VaultKanbanItem

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    dashboard_type = param!(params, :dashboard_type)
    days = param(params, :days, 7)

    case dashboard_type do
      "index" ->
        index_dashboard(vault_id, days)

      "activity" ->
        activity_dashboard(vault_id, days)

      "updates_hub" ->
        updates_hub(vault_id, days, param(params, :person))

      "kanban_summary" ->
        kanban_summary(vault_id)

      other ->
        {:error,
         "Unknown dashboard type: #{other}. Valid: index, activity, updates_hub, kanban_summary"}
    end
  end

  defp index_dashboard(vault_id, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    # Count entries by type
    type_counts =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        group_by: e.entry_type,
        select: {e.entry_type, count(e.id)}
      )
      |> Repo.all()

    total = Enum.reduce(type_counts, 0, fn {_, c}, acc -> acc + c end)

    type_summary =
      type_counts
      |> Enum.sort_by(fn {_, c} -> c end, :desc)
      |> Enum.map(fn {type, c} -> "  #{type || "untyped"}: #{c}" end)
      |> Enum.join("\n")

    # Active kanban items (next_up + in_progress)
    active_items =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column in [:next_up, :in_progress],
        order_by: [asc: k.column, asc: k.sort_order]
      )
      |> Repo.all()

    active_summary =
      if active_items == [] do
        "  No active tasks"
      else
        active_items
        |> Enum.map(fn item ->
          assignee = if item.assignee, do: " @#{item.assignee}", else: ""
          "  [#{item.column}] #{item.description}#{assignee}"
        end)
        |> Enum.join("\n")
      end

    # Recent entries
    recent =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        where: e.entry_type in ["meeting", "checkin", "decision"],
        where: e.updated_at >= ^cutoff,
        order_by: [desc: e.updated_at],
        limit: 10
      )
      |> Repo.all()

    recent_summary =
      if recent == [] do
        "  No recent entries"
      else
        recent
        |> Enum.map(fn e ->
          "  #{e.entry_type}: #{e.title || e.path} (#{format_date(e.updated_at)})"
        end)
        |> Enum.join("\n")
      end

    # Completed kanban items in period
    completed =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column == :done,
        where: k.completed_at >= ^cutoff,
        order_by: [desc: k.completed_at]
      )
      |> Repo.all()

    completed_summary =
      if completed == [] do
        "  No completed tasks"
      else
        completed
        |> Enum.map(fn item ->
          "  #{item.description} (completed #{format_date(item.completed_at)})"
        end)
        |> Enum.join("\n")
      end

    result = """
    # Vault Dashboard
    Total entries: #{total}

    ## Entry Types
    #{type_summary}

    ## Active Tasks
    #{active_summary}

    ## Recent (last #{days} days)
    #{recent_summary}

    ## Completed (last #{days} days)
    #{completed_summary}
    """

    {:ok, %{result: String.trim(result)}}
  end

  defp activity_dashboard(vault_id, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    entries =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        where: e.updated_at >= ^cutoff,
        order_by: [desc: e.updated_at],
        limit: 50
      )
      |> Repo.all()

    if entries == [] do
      {:ok, %{result: "No activity in the last #{days} days."}}
    else
      by_date =
        entries
        |> Enum.group_by(fn e -> DateTime.to_date(e.updated_at) end)
        |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})

      formatted =
        by_date
        |> Enum.map(fn {date, day_entries} ->
          header = "## #{Date.to_string(date)}"

          lines =
            day_entries
            |> Enum.map(fn e ->
              "- [#{e.entry_type || "?"}] #{e.title || e.path}"
            end)
            |> Enum.join("\n")

          "#{header}\n#{lines}"
        end)
        |> Enum.join("\n\n")

      {:ok, %{result: "Activity (last #{days} days):\n\n#{formatted}"}}
    end
  end

  defp updates_hub(vault_id, days, person) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    entries =
      from(e in VaultEntry,
        where: e.vault_id == ^vault_id,
        where: e.entry_type == "checkin",
        where: e.updated_at >= ^cutoff,
        order_by: [desc: e.updated_at]
      )
      |> Repo.all()

    # Group by author from metadata
    by_author =
      entries
      |> Enum.group_by(fn e ->
        (e.metadata || %{})["author"] || "unknown"
      end)

    # Filter by person if provided
    by_author =
      if person do
        Map.filter(by_author, fn {author, _} ->
          String.downcase(author) == String.downcase(person)
        end)
      else
        by_author
      end

    if by_author == %{} do
      filter_msg = if person, do: " for #{person}", else: ""
      {:ok, %{result: "No checkins#{filter_msg} in the last #{days} days."}}
    else
      formatted =
        by_author
        |> Enum.sort_by(fn {author, _} -> author end)
        |> Enum.map(fn {author, checkins} ->
          header = "## #{author} (#{length(checkins)} checkins)"

          lines =
            checkins
            |> Enum.map(fn e ->
              "- #{e.title || e.path} (#{format_date(e.updated_at)})"
            end)
            |> Enum.join("\n")

          "#{header}\n#{lines}"
        end)
        |> Enum.join("\n\n")

      {:ok, %{result: "Updates Hub (last #{days} days):\n\n#{formatted}"}}
    end
  end

  defp kanban_summary(vault_id) do
    # Count items per column (exclude archived)
    column_counts =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column != :archived,
        group_by: k.column,
        select: {k.column, count(k.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Count items per project_tag
    project_counts =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column != :archived,
        where: not is_nil(k.project_tag),
        group_by: k.project_tag,
        select: {k.project_tag, count(k.id)}
      )
      |> Repo.all()

    # In-progress items with assignees
    in_progress =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column == :in_progress,
        order_by: [asc: k.sort_order]
      )
      |> Repo.all()

    total = column_counts |> Map.values() |> Enum.sum()

    columns_str =
      [:backlog, :next_up, :in_progress, :done]
      |> Enum.map(fn col -> "  #{format_column(col)}: #{Map.get(column_counts, col, 0)}" end)
      |> Enum.join("\n")

    projects_str =
      if project_counts == [] do
        "  No projects tagged"
      else
        project_counts
        |> Enum.sort_by(fn {_, c} -> c end, :desc)
        |> Enum.map(fn {tag, c} -> "  #{tag}: #{c}" end)
        |> Enum.join("\n")
      end

    in_progress_str =
      if in_progress == [] do
        "  None"
      else
        in_progress
        |> Enum.map(fn item ->
          assignee = if item.assignee, do: " @#{item.assignee}", else: ""
          "  - #{item.description}#{assignee}"
        end)
        |> Enum.join("\n")
      end

    result = """
    # Kanban Summary
    Total active: #{total}

    ## By Column
    #{columns_str}

    ## By Project
    #{projects_str}

    ## In Progress
    #{in_progress_str}
    """

    {:ok, %{result: String.trim(result)}}
  end

  defp format_date(nil), do: "?"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end

  defp format_column(:backlog), do: "Backlog"
  defp format_column(:next_up), do: "Next Up"
  defp format_column(:in_progress), do: "In Progress"
  defp format_column(:done), do: "Done"
  defp format_column(other), do: to_string(other)
end
