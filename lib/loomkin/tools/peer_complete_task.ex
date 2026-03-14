defmodule Loomkin.Tools.PeerCompleteTask do
  @moduledoc "Agent-initiated task completion."

  use Jido.Action,
    name: "peer_complete_task",
    description:
      "Mark a task as completed with a result summary and optional structured details. " <>
        "Broadcasts task_completed so the team knows the task is done.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the task to complete"],
      result: [type: :string, doc: "Result summary or output of the completed task"],
      actions_taken: [type: {:list, :string}, doc: "Concrete actions taken during the task"],
      discoveries: [type: {:list, :string}, doc: "Things learned during the task"],
      files_changed: [type: {:list, :string}, doc: "File paths created or modified"],
      decisions_made: [type: {:list, :string}, doc: "Choices made and brief rationale"],
      open_questions: [type: {:list, :string}, doc: "Unresolved issues for successor tasks"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)

    completion_attrs = %{
      result: param(params, :result) || "",
      actions_taken: param(params, :actions_taken) || [],
      discoveries: param(params, :discoveries) || [],
      files_changed: param(params, :files_changed) || [],
      decisions_made: param(params, :decisions_made) || [],
      open_questions: param(params, :open_questions) || []
    }

    # Verify the task belongs to this team before completing it
    case Tasks.get_task(task_id) do
      {:error, :not_found} ->
        {:error, "Task not found: #{task_id}"}

      {:ok, task} when task.team_id != team_id ->
        {:error, "Task #{task_id} belongs to a different team"}

      {:ok, _task} ->
        case Tasks.complete_task(task_id, completion_attrs) do
          {:ok, task} ->
            summary = """
            Task completed:
              ID: #{task.id}
              Title: #{task.title}
              Status: #{task.status}
            """

            {:ok, %{result: String.trim(summary), task_id: task.id}}

          {:error, reason} ->
            {:error, "Failed to complete task: #{inspect(reason)}"}
        end
    end
  end
end
