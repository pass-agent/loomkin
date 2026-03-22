defmodule Loomkin.Tools.PeerResumeTask do
  @moduledoc "Agent-initiated task resumption from partially complete state."

  use Jido.Action,
    name: "peer_resume_task",
    description:
      "Resume a partially complete task, transitioning it back to in_progress. " <>
        "The agent can continue where it left off with partial result context preserved.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the task to resume"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)

    case Tasks.get_task(task_id) do
      {:error, :not_found} ->
        {:error, "Task not found: #{task_id}"}

      {:ok, task} when task.team_id != team_id ->
        {:error, "Task #{task_id} belongs to a different team"}

      {:ok, _task} ->
        case Tasks.resume_task(task_id) do
          {:ok, task} ->
            partial_context =
              if task.partial_results do
                "\nPartial results: #{inspect(task.partial_results)}"
              else
                ""
              end

            {:ok,
             %{
               result:
                 "Task #{task.id} (#{task.title}) resumed from partially complete" <>
                   partial_context,
               task_id: task.id
             }}

          {:error, :invalid_transition} ->
            {:error, "Task must be partially_complete to resume"}

          {:error, reason} ->
            {:error, "Failed to resume task: #{inspect(reason)}"}
        end
    end
  end
end
