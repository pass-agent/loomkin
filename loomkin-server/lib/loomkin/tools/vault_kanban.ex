defmodule Loomkin.Tools.VaultKanban do
  @moduledoc "Agent tool for managing the vault task board (kanban)."

  use Jido.Action,
    name: "vault_kanban",
    description:
      "Manage the vault task board. Actions: add, complete, move, list, archive, search. " <>
        "Tasks track work items linked to vault entries.",
    schema: [
      vault_id: [type: :string, required: true, doc: "Vault identifier"],
      action: [
        type: :string,
        required: true,
        doc: "Action: add, complete, move, list, archive, search"
      ],
      description: [type: :string, doc: "Task description (required for 'add')"],
      assignee: [type: :string, doc: "Person assigned to the task"],
      project_tag: [type: :string, doc: "Project tag (e.g. 'tcs', 'btrw')"],
      column: [
        type: :string,
        doc: "Target column: backlog, next_up, in_progress, done (for add/move)"
      ],
      source_path: [type: :string, doc: "Vault entry path that created this task"],
      task_id: [type: :string, doc: "Task ID (required for complete, move, archive)"],
      search_term: [type: :string, doc: "Search term (for 'search' action)"],
      filter_assignee: [type: :string, doc: "Filter list by assignee"],
      filter_project: [type: :string, doc: "Filter list by project tag"],
      filter_column: [type: :string, doc: "Filter list by column"]
    ]

  import Ecto.Query
  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultKanbanItem

  @columns ~w(backlog next_up in_progress done archived)

  @impl true
  def run(params, _context) do
    vault_id = param!(params, :vault_id)
    action = param!(params, :action)

    case action do
      "add" ->
        add(vault_id, params)

      "complete" ->
        complete(vault_id, params)

      "move" ->
        move(vault_id, params)

      "list" ->
        list(vault_id, params)

      "archive" ->
        archive(vault_id)

      "search" ->
        search(vault_id, params)

      other ->
        {:error, "Unknown action: #{other}. Valid: add, complete, move, list, archive, search"}
    end
  end

  defp add(vault_id, params) do
    description = param!(params, :description)
    assignee = param(params, :assignee)
    project_tag = param(params, :project_tag)
    column = parse_column(param(params, :column)) || :backlog
    source_path = param(params, :source_path)

    %VaultKanbanItem{}
    |> VaultKanbanItem.changeset(%{
      vault_id: vault_id,
      description: description,
      assignee: assignee,
      project_tag: project_tag,
      column: column,
      source_path: source_path
    })
    |> Repo.insert()
    |> case do
      {:ok, item} ->
        {:ok,
         %{
           result:
             "Created task #{item.id}\n" <>
               "Description: #{item.description}\n" <>
               "Column: #{item.column}\n" <>
               if(item.assignee, do: "Assignee: #{item.assignee}\n", else: "") <>
               if(item.project_tag, do: "Project: #{item.project_tag}", else: "")
         }}

      {:error, changeset} ->
        {:error, "Failed to create task: #{inspect(changeset.errors)}"}
    end
  end

  defp complete(vault_id, params) do
    task_id = param!(params, :task_id)

    case get_item(vault_id, task_id) do
      nil ->
        {:error, "Task not found: #{task_id}"}

      item ->
        item
        |> VaultKanbanItem.changeset(%{column: :done, completed_at: DateTime.utc_now()})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            {:ok, %{result: "Completed: #{updated.description} (#{updated.id})"}}

          {:error, changeset} ->
            {:error, "Failed to complete task: #{inspect(changeset.errors)}"}
        end
    end
  end

  defp move(vault_id, params) do
    task_id = param!(params, :task_id)
    column = param!(params, :column)

    parsed = parse_column(column)

    if is_nil(parsed) do
      {:error, "Invalid column: #{column}. Valid: #{Enum.join(@columns, ", ")}"}
    else
      case get_item(vault_id, task_id) do
        nil ->
          {:error, "Task not found: #{task_id}"}

        item ->
          item
          |> VaultKanbanItem.changeset(%{column: parsed})
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              {:ok,
               %{result: "Moved '#{updated.description}' to #{updated.column} (#{updated.id})"}}

            {:error, changeset} ->
              {:error, "Failed to move task: #{inspect(changeset.errors)}"}
          end
      end
    end
  end

  defp list(vault_id, params) do
    filter_assignee = param(params, :filter_assignee)
    filter_project = param(params, :filter_project)
    filter_column = param(params, :filter_column)

    query =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column != :archived,
        order_by: [asc: k.column, asc: k.sort_order, asc: k.inserted_at]
      )

    query = maybe_filter_assignee(query, filter_assignee)
    query = maybe_filter_project(query, filter_project)
    query = maybe_filter_column(query, parse_column(filter_column))

    items = Repo.all(query)

    if items == [] do
      {:ok, %{result: "No tasks found."}}
    else
      formatted = format_by_column(items)
      {:ok, %{result: "#{length(items)} tasks:\n\n#{formatted}"}}
    end
  end

  defp archive(vault_id) do
    {count, _} =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column == :done
      )
      |> Repo.update_all(set: [column: :archived, updated_at: DateTime.utc_now()])

    {:ok, %{result: "Archived #{count} completed tasks."}}
  end

  defp search(vault_id, params) do
    term = param!(params, :search_term)

    items =
      from(k in VaultKanbanItem,
        where: k.vault_id == ^vault_id,
        where: k.column != :archived,
        where: fragment("similarity(?, ?) > 0.3", k.description, ^term),
        order_by: [desc: fragment("similarity(?, ?)", k.description, ^term)],
        limit: 5
      )
      |> Repo.all()

    if items == [] do
      {:ok, %{result: "No tasks matching '#{term}'"}}
    else
      formatted =
        items
        |> Enum.map(&format_item/1)
        |> Enum.join("\n")

      {:ok, %{result: "Found #{length(items)} tasks:\n#{formatted}"}}
    end
  end

  # --- Helpers ---

  defp get_item(vault_id, task_id) do
    from(k in VaultKanbanItem,
      where: k.vault_id == ^vault_id,
      where: k.id == ^task_id
    )
    |> Repo.one()
  end

  defp parse_column(nil), do: nil

  defp parse_column(col) when is_binary(col) do
    case col do
      "backlog" -> :backlog
      "next_up" -> :next_up
      "in_progress" -> :in_progress
      "done" -> :done
      "archived" -> :archived
      _ -> nil
    end
  end

  defp maybe_filter_assignee(query, nil), do: query

  defp maybe_filter_assignee(query, assignee) do
    from(k in query, where: k.assignee == ^assignee)
  end

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project) do
    from(k in query, where: k.project_tag == ^project)
  end

  defp maybe_filter_column(query, nil), do: query

  defp maybe_filter_column(query, column) do
    from(k in query, where: k.column == ^column)
  end

  defp format_by_column(items) do
    items
    |> Enum.group_by(& &1.column)
    |> Enum.sort_by(fn {col, _} -> column_order(col) end)
    |> Enum.map(fn {col, col_items} ->
      header = "## #{format_column_name(col)}"

      lines =
        col_items
        |> Enum.map(&format_item/1)
        |> Enum.join("\n")

      "#{header}\n#{lines}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_item(item) do
    assignee = if item.assignee, do: " @#{item.assignee}", else: ""
    project = if item.project_tag, do: " [#{item.project_tag}]", else: ""
    "- #{item.description}#{assignee}#{project} (#{item.id})"
  end

  defp column_order(:backlog), do: 0
  defp column_order(:next_up), do: 1
  defp column_order(:in_progress), do: 2
  defp column_order(:done), do: 3
  defp column_order(_), do: 4

  defp format_column_name(:backlog), do: "Backlog"
  defp format_column_name(:next_up), do: "Next Up"
  defp format_column_name(:in_progress), do: "In Progress"
  defp format_column_name(:done), do: "Done"
  defp format_column_name(:archived), do: "Archived"
  defp format_column_name(other), do: to_string(other)
end
