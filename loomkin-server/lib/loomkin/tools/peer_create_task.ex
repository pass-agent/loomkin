defmodule Loomkin.Tools.PeerCreateTask do
  @moduledoc "Agent-initiated task creation."

  use Jido.Action,
    name: "peer_create_task",
    description:
      "Create a new task for the team. The task is persisted and broadcast " <>
        "so other agents (or the lead) can pick it up. Optionally add a " <>
        "dependency on another task in the same call.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      title: [type: :string, required: true, doc: "Task title"],
      description: [type: :string, doc: "Task description"],
      priority: [type: :integer, doc: "Priority (1=highest, 5=lowest, default 3)"],
      depends_on_id: [type: :string, doc: "Optional task ID this new task depends on"],
      dep_type: [
        type: :string,
        doc:
          "Dependency type when depends_on_id is set: blocks (default), informs, or requires_output"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    title = param!(params, :title)
    description = param(params, :description)
    priority = param(params, :priority) || 3
    depends_on_id = param(params, :depends_on_id)
    dep_type_str = param(params, :dep_type) || "blocks"

    attrs = %{title: title, description: description, priority: priority}

    with {:ok, task} <- Tasks.create_task(team_id, attrs),
         :ok <- maybe_add_dependency(task.id, depends_on_id, dep_type_str) do
      dep_info =
        if depends_on_id, do: "\n  Depends on: #{depends_on_id} (#{dep_type_str})", else: ""

      summary = """
      Task created:
        ID: #{task.id}
        Title: #{task.title}
        Priority: #{task.priority}
        Status: #{task.status}#{dep_info}
      """

      {:ok, %{result: String.trim(summary), task_id: task.id}}
    else
      {:error, reason} ->
        {:error, "Failed to create task: #{inspect(reason)}"}
    end
  end

  defp maybe_add_dependency(_task_id, nil, _dep_type), do: :ok

  defp maybe_add_dependency(task_id, depends_on_id, dep_type_str) do
    dep_type = String.to_existing_atom(dep_type_str)

    case Tasks.add_dependency(task_id, depends_on_id, dep_type) do
      {:ok, _dep} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
