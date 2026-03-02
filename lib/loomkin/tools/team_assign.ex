defmodule Loomkin.Tools.TeamAssign do
  @moduledoc "Create and assign a task to an agent."

  use Jido.Action,
    name: "team_assign",
    description:
      "Create a new task and assign it to a specific agent. " <>
        "The task is persisted to the database and the agent is notified.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      title: [type: :string, required: true, doc: "Task title"],
      description: [type: :string, doc: "Detailed task description"],
      agent_name: [type: :string, required: true, doc: "Name of the agent to assign to"],
      priority: [type: :integer, doc: "Priority (1=highest, 5=lowest, default 3)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    title = param!(params, :title)
    description = param(params, :description)
    agent_name = param!(params, :agent_name)
    priority = param(params, :priority) || 3

    attrs = %{
      title: title,
      description: description,
      priority: priority
    }

    with {:ok, task} <- Tasks.create_task(team_id, attrs),
         {:ok, task} <- Tasks.assign_task(task.id, agent_name) do
      summary = """
      Task created and assigned:
        ID: #{task.id}
        Title: #{task.title}
        Assigned to: #{agent_name}
        Priority: #{task.priority}
        Status: #{task.status}
      """

      {:ok, %{result: String.trim(summary), task_id: task.id}}
    else
      {:error, reason} ->
        {:error, "Failed to create/assign task: #{inspect(reason)}"}
    end
  end
end
