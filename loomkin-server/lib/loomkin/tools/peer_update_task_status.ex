defmodule Loomkin.Tools.PeerUpdateTaskStatus do
  @moduledoc "Agent-initiated task status transition to readiness states."

  use Jido.Action,
    name: "peer_update_task_status",
    description:
      "Transition a task to a readiness state: ready_for_review, blocked, or partially_complete. " <>
        "Use this to signal progress or blockers to the team.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the task to update"],
      new_status: [
        type: :string,
        required: true,
        doc: "New status: ready_for_review, blocked, or partially_complete"
      ],
      reason: [type: :string, doc: "Reason or summary for the status change"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @valid_statuses ~w(ready_for_review blocked partially_complete)

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    new_status = param!(params, :new_status)
    reason = param(params, :reason) || ""

    if new_status not in @valid_statuses do
      {:error,
       "Invalid status: #{new_status}. Must be one of: #{Enum.join(@valid_statuses, ", ")}"}
    else
      case Tasks.get_task(task_id) do
        {:error, :not_found} ->
          {:error, "Task not found: #{task_id}"}

        {:ok, task} when task.team_id != team_id ->
          {:error, "Task #{task_id} belongs to a different team"}

        {:ok, _task} ->
          do_transition(task_id, new_status, reason)
      end
    end
  end

  defp do_transition(task_id, "ready_for_review", summary) do
    case Tasks.mark_ready_for_review(task_id, summary) do
      {:ok, task} ->
        {:ok,
         %{
           result: "Task #{task.id} (#{task.title}) marked as ready for review",
           task_id: task.id
         }}

      {:error, :invalid_transition} ->
        {:error, "Task must be in_progress to mark as ready_for_review"}

      {:error, reason} ->
        {:error, "Failed to update task: #{inspect(reason)}"}
    end
  end

  defp do_transition(task_id, "blocked", reason) do
    case Tasks.mark_blocked(task_id, reason) do
      {:ok, task} ->
        {:ok, %{result: "Task #{task.id} (#{task.title}) marked as blocked", task_id: task.id}}

      {:error, :invalid_transition} ->
        {:error, "Task must be assigned or in_progress to mark as blocked"}

      {:error, reason} ->
        {:error, "Failed to update task: #{inspect(reason)}"}
    end
  end

  defp do_transition(task_id, "partially_complete", partial_result) do
    case Tasks.mark_partially_complete(task_id, partial_result) do
      {:ok, task} ->
        {:ok,
         %{
           result: "Task #{task.id} (#{task.title}) marked as partially complete",
           task_id: task.id
         }}

      {:error, :invalid_transition} ->
        {:error, "Task must be in_progress to mark as partially_complete"}

      {:error, reason} ->
        {:error, "Failed to update task: #{inspect(reason)}"}
    end
  end
end
