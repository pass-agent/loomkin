defmodule Loomkin.Tools.PeerDiscardTentative do
  @moduledoc "Agent-initiated discard of a tentative speculative result."

  use Jido.Action,
    name: "peer_discard_tentative",
    description:
      "Manually discard a tentatively completed speculative task. " <>
        "Optionally re-queues the task for non-speculative execution.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      task_id: [type: :string, required: true, doc: "ID of the tentative task to discard"],
      requeue: [type: :boolean, doc: "If true, re-queue the task as pending for normal execution"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.Tasks

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    task_id = param!(params, :task_id)
    requeue = param(params, :requeue) || false

    case Tasks.get_task(task_id) do
      {:error, :not_found} ->
        {:error, "Task not found: #{task_id}"}

      {:ok, task} when task.team_id != team_id ->
        {:error, "Task #{task_id} belongs to a different team"}

      {:ok, _task} ->
        case Tasks.discard_tentative(task_id, requeue: requeue) do
          {:ok, task} ->
            action = if requeue, do: "discarded and re-queued", else: "discarded"

            {:ok,
             %{
               result: "Task #{task.id} (#{task.title}) #{action}",
               task_id: task.id
             }}

          {:error, :invalid_transition} ->
            {:error,
             "Task must be in completed_tentative or pending_speculative status to discard"}

          {:error, reason} ->
            {:error, "Failed to discard tentative task: #{inspect(reason)}"}
        end
    end
  end
end
