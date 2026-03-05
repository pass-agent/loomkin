defmodule Loomkin.Tools.TeamSmartAssign do
  @moduledoc "Auto-assign a task to the best available agent based on capabilities and load."

  use Jido.Action,
    name: "team_smart_assign",
    description:
      "Automatically assign a task to the best available agent. " <>
        "Uses capability tracking to pick the agent most skilled at the task type, " <>
        "falling back to the least-loaded idle agent.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the task to assign"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)

    case Tasks.smart_assign(team_id, task_id) do
      {:ok, task, reason} ->
        summary = """
        Task smart-assigned:
          ID: #{task.id}
          Title: #{task.title}
          Assigned to: #{task.owner}
          Reason: #{reason}
        """

        {:ok,
         %{result: String.trim(summary), task_id: task.id, agent: task.owner, reason: reason}}

      {:error, :no_idle_agents} ->
        {:error, "No idle agents available for assignment"}

      {:error, :not_found} ->
        {:error, "Task not found"}

      {:error, reason} ->
        {:error, "Failed to smart-assign task: #{inspect(reason)}"}
    end
  end
end
