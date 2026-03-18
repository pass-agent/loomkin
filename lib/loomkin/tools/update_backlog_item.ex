defmodule Loomkin.Tools.UpdateBacklogItem do
  @moduledoc """
  Agent tool for updating backlog item status, priority, or details.

  Common operations:
  - Move an item to in_progress when starting work
  - Mark done when completed
  - Reprioritize based on new information
  - Block/unblock items
  - Add results or notes
  """

  use Jido.Action,
    name: "update_backlog_item",
    description:
      "Update a backlog item's status, priority, or other fields. " <>
        "Use to track progress on planned work, reprioritize, or mark items done.",
    schema: [
      item_id: [type: :string, required: true, doc: "ID of the backlog item to update"],
      status: [
        type: :string,
        doc: "New status: todo, in_progress, done, blocked, cancelled, icebox"
      ],
      priority: [type: :string, doc: "New priority 1-5"],
      result: [type: :string, doc: "Result summary (typically set when marking done)"],
      assigned_to: [type: :string, doc: "Agent name to assign this item to"],
      assigned_team: [type: :string, doc: "Team ID to assign this item to"],
      description: [type: :string, doc: "Updated description"],
      category: [type: :string, doc: "Updated category"],
      epic: [type: :string, doc: "Updated epic"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Backlog

  @valid_statuses ~w(todo in_progress done blocked cancelled icebox)

  @impl true
  def run(params, _context) do
    item_id = param!(params, :item_id)

    # Build attrs from provided params (only include non-nil values)
    attrs =
      %{}
      |> maybe_put(:status, param(params, :status), &validate_status/1)
      |> maybe_put_parsed_int(:priority, param(params, :priority))
      |> maybe_put_raw(:result, param(params, :result))
      |> maybe_put_raw(:assigned_to, param(params, :assigned_to))
      |> maybe_put_raw(:assigned_team, param(params, :assigned_team))
      |> maybe_put_raw(:description, param(params, :description))
      |> maybe_put_raw(:category, param(params, :category))
      |> maybe_put_raw(:epic, param(params, :epic))

    if map_size(attrs) == 0 do
      {:error,
       "No fields to update. Provide at least one of: status, priority, result, assigned_to, assigned_team, description, category, epic"}
    else
      case Backlog.update_item(item_id, attrs) do
        {:ok, item} ->
          changes = Enum.map_join(Map.keys(attrs), ", ", &to_string/1)

          {:ok,
           %{
             result:
               """
               Backlog item updated (#{changes}):
                 ID: #{item.id}
                 Title: #{item.title}
                 Status: #{item.status}
                 Priority: #{item.priority}
               """
               |> String.trim()
           }}

        {:error, :not_found} ->
          {:error, "Backlog item not found: #{item_id}"}

        {:error, changeset} ->
          {:error, "Failed to update backlog item: #{inspect(changeset.errors)}"}
      end
    end
  end

  defp validate_status(status_str) when is_binary(status_str) do
    if status_str in @valid_statuses do
      {:ok, String.to_existing_atom(status_str)}
    else
      {:error,
       "Invalid status '#{status_str}'. Must be one of: #{Enum.join(@valid_statuses, ", ")}"}
    end
  end

  defp maybe_put(attrs, _key, nil, _validator), do: attrs

  defp maybe_put(attrs, key, value, validator) do
    case validator.(value) do
      {:ok, validated} -> Map.put(attrs, key, validated)
      {:error, _msg} -> attrs
    end
  end

  defp maybe_put_raw(attrs, _key, nil), do: attrs
  defp maybe_put_raw(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_put_parsed_int(attrs, _key, nil), do: attrs
  defp maybe_put_parsed_int(attrs, key, val) when is_integer(val), do: Map.put(attrs, key, val)

  defp maybe_put_parsed_int(attrs, key, val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> Map.put(attrs, key, n)
      :error -> attrs
    end
  end

  defp maybe_put_parsed_int(attrs, _key, _), do: attrs
end
