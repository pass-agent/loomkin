defmodule Loomkin.Tools.PeerCreateTask do
  @moduledoc "Agent-initiated task creation."

  use Jido.Action,
    name: "peer_create_task",
    description:
      "Create a new task for the team. The task is persisted and broadcast " <>
        "so other agents (or the lead) can pick it up.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      title: [type: :string, required: true, doc: "Task title"],
      description: [type: :string, doc: "Task description"],
      priority: [type: :integer, doc: "Priority (1=highest, 5=lowest, default 3)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    title = param!(params, :title)
    description = param(params, :description)
    priority = param(params, :priority) || 3

    attrs = %{title: title, description: description, priority: priority}

    case Tasks.create_task(team_id, attrs) do
      {:ok, task} ->
        summary = """
        Task created:
          ID: #{task.id}
          Title: #{task.title}
          Priority: #{task.priority}
          Status: #{task.status}
        """

        {:ok, %{result: String.trim(summary), task_id: task.id}}

      {:error, reason} ->
        {:error, "Failed to create task: #{inspect(reason)}"}
    end
  end
end
