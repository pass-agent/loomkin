defmodule Loomkin.Tools.PeerConfirmTentative do
  @moduledoc "Agent-initiated confirmation of a tentative speculative result."

  use Jido.Action,
    name: "peer_confirm_tentative",
    description:
      "Manually confirm a tentatively completed speculative task. " <>
        "Transitions the task from completed_tentative to completed.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the tentative task to confirm"]
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
        case Tasks.confirm_tentative(task_id) do
          {:ok, task} ->
            {:ok,
             %{
               result: "Task #{task.id} (#{task.title}) confirmed as completed",
               task_id: task.id
             }}

          {:error, :invalid_transition} ->
            {:error, "Task must be in completed_tentative status to confirm"}

          {:error, reason} ->
            {:error, "Failed to confirm tentative task: #{inspect(reason)}"}
        end
    end
  end
end
