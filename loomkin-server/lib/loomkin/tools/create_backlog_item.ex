defmodule Loomkin.Tools.CreateBacklogItem do
  @moduledoc """
  Agent tool for creating backlog items.

  Allows agents (especially the concierge) to add work items to the
  persistent backlog. Items survive restarts and can be queried later.
  """

  use Jido.Action,
    name: "create_backlog_item",
    description:
      "Add an item to the persistent backlog/roadmap. Items survive restarts and are " <>
        "queryable by all agents. Use for planned work, ideas, bugs, or improvements " <>
        "that should be tracked beyond the current session.",
    schema: [
      title: [type: :string, required: true, doc: "Short title for the backlog item"],
      description: [type: :string, doc: "Detailed description of the work"],
      priority: [
        type: :string,
        doc: "Priority 1-5 (1=critical/do-now, 2=high, 3=medium, 4=low, 5=someday)"
      ],
      status: [
        type: :string,
        doc: "Initial status: todo (default), icebox, in_progress"
      ],
      category: [type: :string, doc: "Category grouping (e.g. 'ui', 'infra', 'bugfix')"],
      epic: [type: :string, doc: "Epic name for roadmap grouping (e.g. 'workspace-overhaul')"],
      tags: [type: {:list, :string}, doc: "List of tags for filtering"],
      scope_estimate: [
        type: :string,
        doc: "Estimated scope: quick (~1-3 files), session (~4-15 files), campaign (15+ files)"
      ],
      depends_on_id: [type: :string, doc: "ID of another backlog item this depends on"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Backlog

  @valid_statuses ~w(todo icebox in_progress)
  @valid_scopes ~w(quick session campaign)

  @impl true
  def run(params, context) do
    title = param!(params, :title)

    status = param(params, :status) || "todo"

    unless status in @valid_statuses do
      return_error(
        "Invalid status '#{status}'. Must be one of: #{Enum.join(@valid_statuses, ", ")}"
      )
    end

    scope = param(params, :scope_estimate) || "session"

    unless scope in @valid_scopes do
      return_error(
        "Invalid scope_estimate '#{scope}'. Must be one of: #{Enum.join(@valid_scopes, ", ")}"
      )
    end

    tags = param(params, :tags)
    tags = if is_list(tags), do: tags, else: []

    attrs = %{
      title: title,
      description: param(params, :description),
      priority: parse_int(param(params, :priority), 3),
      status: String.to_existing_atom(status),
      category: param(params, :category),
      epic: param(params, :epic),
      tags: tags,
      scope_estimate: String.to_existing_atom(scope),
      depends_on_id: param(params, :depends_on_id),
      created_by: param(context, :agent_name) || "unknown"
    }

    case Backlog.create_item(attrs) do
      {:ok, item} ->
        {:ok,
         %{
           result:
             """
             Backlog item created:
               ID: #{item.id}
               Title: #{item.title}
               Priority: #{item.priority}
               Status: #{item.status}
               Category: #{item.category || "none"}
               Epic: #{item.epic || "none"}
               Scope: #{item.scope_estimate}
             """
             |> String.trim()
         }}

      {:error, changeset} ->
        {:error, "Failed to create backlog item: #{inspect(changeset.errors)}"}
    end
  end

  defp return_error(msg), do: {:error, msg}

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
